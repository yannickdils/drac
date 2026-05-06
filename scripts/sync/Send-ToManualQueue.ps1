#Requires -Version 7.2
# =============================================================================
# scripts/sync/Send-ToManualQueue.ps1
# Stage 8 (Round 3.4): Manual reconciliation queue for portal changes whose
# `bicep decompile` output was dirty (warnings or non-zero exit). Invoked by
# Sync-PortalChange.ps1 (R3.3) when an automated round-trip is unsafe.
#
# Behavior:
#   1. Persist the original ARM JSON to
#      `_reports/sync/manual-queue/<resource-id-hash>.json` so the reviewer
#      always has the input that confused bicep decompile.
#   2. Search for an already-open `portal-sync-manual` issue keyed by the same
#      <resource-id-hash>. If found, log and exit 0 (idempotent).
#   3. Otherwise create a `portal-sync-manual` issue via `gh issue create`,
#      assigned to $Change.changedBy when that value looks like a GitHub
#      username, otherwise unassigned (mentioned in body instead).
#   4. Append an entry to `_reports/sync/manual-queue-summary.json` (read-merge-
#      write so multiple invocations within the same run aggregate cleanly).
#
# Resource ID hash:
#   12 hex chars = first 6 bytes of SHA-256 over $targetResourceId.ToLowerInvariant().
#   This MUST match the hash R3.3 uses for branch naming so the manual-queue
#   file and the auto-PR branch are correlated by a single token.
#
# `gh` references:
#   gh issue create:
#     https://cli.github.com/manual/gh_issue_create
#   gh issue list (search filter):
#     https://cli.github.com/manual/gh_issue_list
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [PSCustomObject] $Change,
    [Parameter(Mandatory)] [string]         $ArmJsonPath,
    [Parameter(Mandatory)] [string]         $RepoFull,
    [Parameter(Mandatory)] [string]         $OutputDir,

    [string] $DecompileWarnings = '',

    # Test seam: skips `gh issue create` and `gh issue list` so the script can
    # be exercised without GitHub credentials. ARM JSON snapshot + summary
    # entry are still produced.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    <#
    .SYNOPSIS
    Strict-mode-safe property existence check (matches the helper in
    scripts/lib/ConvertForDR.psm1). PSObject.Properties[name] returns $null
    when the property is missing AND when the property bag is empty, so this
    works in both cases without tripping Set-StrictMode -Version Latest.
    #>
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ChangeField {
    <#
    .SYNOPSIS
    Returns $Change.<Name> when present, otherwise $Default. Keeps the body-
    template substitutions resilient against partially-populated entries.
    #>
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Source,
        [Parameter(Mandatory)] [string]         $Name,
        $Default = ''
    )
    if (Test-HasProperty $Source $Name) {
        $v = $Source.PSObject.Properties[$Name].Value
        if ($null -eq $v) { return $Default }
        return $v
    }
    return $Default
}

function Get-ResourceIdHash {
    <#
    .SYNOPSIS
    Deterministic 12-hex-char fingerprint of an Azure resource ID, used to
    key the manual-queue file and (per R3.3) the auto-PR branch name.
    Produces 12 hex chars = first 6 bytes of SHA-256 over the lowercase ID.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ResourceId)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResourceId.ToLowerInvariant())
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return -join ($hash[0..5] | ForEach-Object { $_.ToString('x2') })
}

function Test-IsGitHubUsername {
    <#
    .SYNOPSIS
    Returns $true when $Value looks like a plausible GitHub login: 1-39 chars,
    alphanumeric or single hyphens, no leading/trailing hyphen, no '@'. Email
    addresses, AAD UPNs, GUIDs etc. all return $false (so the issue is left
    unassigned and the user is mentioned in the body instead).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Contains('@')) { return $false }
    return ($Value -match '^(?!-)(?!.*--)[A-Za-z0-9-]{1,39}(?<!-)$')
}

function ConvertTo-PortalUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ResourceId)
    return "https://portal.azure.com/#@/resource$ResourceId"
}

function Read-ArmJsonForBody {
    <#
    .SYNOPSIS
    Reads $ArmJsonPath and returns its content trimmed to the first
    $MaxLines lines. Returns a marker string when the file is missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $MaxLines = 200
    )
    if (-not (Test-Path $Path)) {
        return "_(ARM JSON not found at: $Path)_"
    }
    $lines = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -le $MaxLines) {
        return ($lines -join "`n")
    }
    $head = $lines[0..($MaxLines - 1)] -join "`n"
    return "$head`n... (truncated; full template at $Path)"
}

function New-IssueBody {
    <#
    .SYNOPSIS
    Renders the markdown body for the manual-queue issue per the §R3.4 template.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure transform — builds a markdown string from input fields, no system-state side effects.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [Parameter(Mandatory)] [string]         $ManualQueueRelPath,
        [Parameter(Mandatory)] [string]         $RunId,
        [Parameter(Mandatory)] [string]         $ArmJsonInline,
        [string] $DecompileWarnings = '',
        [bool]   $MentionChangedBy  = $false
    )

    $targetResourceId   = [string](Get-ChangeField -Source $Change -Name 'targetResourceId'   -Default '')
    $targetResourceType = [string](Get-ChangeField -Source $Change -Name 'targetResourceType' -Default '')
    $resourceGroupName  = [string](Get-ChangeField -Source $Change -Name 'resourceGroupName'  -Default '')
    $subscriptionId     = [string](Get-ChangeField -Source $Change -Name 'subscriptionId'     -Default '')
    $changeType         = [string](Get-ChangeField -Source $Change -Name 'changeType'         -Default '')
    $changedBy          = [string](Get-ChangeField -Source $Change -Name 'changedBy'          -Default '')
    $timestamp          = [string](Get-ChangeField -Source $Change -Name 'timestamp'          -Default '')

    $changedProps = @()
    if (Test-HasProperty $Change 'changedProperties') {
        $cp = $Change.PSObject.Properties['changedProperties'].Value
        if ($null -ne $cp) { $changedProps = @($cp) }
    }
    $changedPropsBlock = if ($changedProps.Count -gt 0) {
        "``````$([Environment]::NewLine)" + (($changedProps | ForEach-Object { "- $_" }) -join "`n") + "$([Environment]::NewLine)``````"
    } else {
        '_(none reported)_'
    }

    $portalUrl = if ($targetResourceId) { ConvertTo-PortalUrl -ResourceId $targetResourceId } else { '' }
    $portalLine = if ($portalUrl) { "- **Azure Portal:** [open in portal]($portalUrl)" } else { '' }

    $warningsBlock = if ([string]::IsNullOrWhiteSpace($DecompileWarnings)) {
        "_(no stderr captured from bicep decompile)_"
    } else {
        "``````$([Environment]::NewLine)$DecompileWarnings$([Environment]::NewLine)``````"
    }

    $mention = ''
    if ($MentionChangedBy -and -not [string]::IsNullOrWhiteSpace($changedBy)) {
        $mention = "$([Environment]::NewLine)_Original change attributed to: ``$changedBy``._"
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## DRaaC Portal Sync — Manual Reconciliation Required')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('A change was detected in the Azure Portal that **could not be auto-decompiled to clean Bicep**. Reconcile this change manually before the next portal-sync run.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('### Resource')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- **ID:** ``$targetResourceId``")
    [void]$sb.AppendLine("- **Type:** ``$targetResourceType``")
    [void]$sb.AppendLine("- **Resource group:** ``$resourceGroupName``")
    [void]$sb.AppendLine("- **Subscription:** ``$subscriptionId``")
    if ($portalLine) { [void]$sb.AppendLine($portalLine) }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('### Change')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- **Type:** ``$changeType``")
    [void]$sb.AppendLine("- **Made by:** ``$changedBy``")
    [void]$sb.AppendLine("- **At:** ``$timestamp``")
    [void]$sb.AppendLine('- **Properties:**')
    [void]$sb.AppendLine($changedPropsBlock)
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('### Decompile warnings')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine($warningsBlock)
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('### ARM JSON')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("The original ARM template is captured at ``$ManualQueueRelPath`` (run id ``$RunId``). Inline:")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('<details>')
    [void]$sb.AppendLine('<summary>show ARM JSON</summary>')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('```json')
    [void]$sb.AppendLine($ArmJsonInline)
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('</details>')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('### Reviewer checklist')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('- [ ] Hand-author `bicep/regions/primary/<rg>/<resource-name>.bicep` from the ARM JSON above.')
    [void]$sb.AppendLine('- [ ] Run `pwsh scripts/review/check-dr-coverage.ps1 -PrChangesFile <pr-changes> -RepoRoot <repo>` to auto-generate the DR companion.')
    [void]$sb.AppendLine('- [ ] Open a PR and merge.')
    [void]$sb.AppendLine('- [ ] Close this issue.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_Generated by ``Send-ToManualQueue.ps1`` for run ``$RunId``._")
    if ($mention) { [void]$sb.AppendLine($mention) }

    return $sb.ToString()
}

function New-IssueTitle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure transform — builds the issue title string, no system-state side effects.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [Parameter(Mandatory)] [string]         $ResourceIdHash
    )
    $rt   = [string](Get-ChangeField -Source $Change -Name 'targetResourceType' -Default 'unknown-type')
    $name = [string](Get-ChangeField -Source $Change -Name 'resourceName'       -Default 'unknown-name')
    $rg   = [string](Get-ChangeField -Source $Change -Name 'resourceGroupName'  -Default 'unknown-rg')
    return "[portal-sync-manual] $rt/$name in $rg ($ResourceIdHash)"
}

function Find-ExistingManualIssue {
    <#
    .SYNOPSIS
    Looks for an open `portal-sync-manual` issue whose title or body contains
    the resource ID hash. Returns the issue number on hit, otherwise $null.
    Failures (auth, network, gh missing) return $null so the caller can fall
    through to creation rather than throwing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'RepoFull is referenced inside the closure-captured argument list.')]
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter(Mandatory)] [string] $RepoFull,
        [Parameter(Mandatory)] [string] $ResourceIdHash
    )
    try {
        $argList = @(
            'issue', 'list',
            '--repo',   $RepoFull,
            '--label',  'portal-sync-manual',
            '--search', $ResourceIdHash,
            '--state',  'open',
            '--json',   'number,title'
        )
        $stdout = & gh @argList 2>&1
        $exit   = $LASTEXITCODE
        if ($exit -ne 0) {
            Write-Host "  gh issue list returned exit $exit; treating as no-match."
            return $null
        }
        $joined = ($stdout | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
        $items = $joined | ConvertFrom-Json -ErrorAction Stop
        $arr   = @($items)
        if ($arr.Count -eq 0) { return $null }
        return [int]$arr[0].number
    }
    catch {
        Write-Host "  gh issue list lookup failed: $_ — proceeding as if no match."
        return $null
    }
}

function Send-ManualIssue {
    <#
    .SYNOPSIS
    Creates the manual-queue issue. Returns the new issue number on success
    or $null on failure (failure is logged but never thrown — the caller
    records `outcome=failed` in the summary).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Side effect is bounded to issue creation in $RepoFull which is the explicit purpose of the function.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'Parameters are referenced inside the closure-captured argument list.')]
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter(Mandatory)] [string] $RepoFull,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Body,
        [string]   $Assignee = ''
    )

    # `gh issue create` consumes the body via stdin when --body-file=- is set,
    # which avoids quoting nightmares for multi-line markdown.
    $argList = @(
        'issue', 'create',
        '--repo',      $RepoFull,
        '--label',     'portal-sync-manual',
        '--title',     $Title,
        '--body-file', '-'
    )
    if (-not [string]::IsNullOrWhiteSpace($Assignee)) {
        $argList += @('--assignee', $Assignee)
    }

    try {
        $stdout = $Body | & gh @argList 2>&1
        $exit   = $LASTEXITCODE
        if ($exit -ne 0) {
            Write-Warning "  gh issue create failed (exit $exit): $($stdout | Out-String)"
            return $null
        }
        # gh prints the issue URL on success: https://github.com/owner/repo/issues/<n>
        $line = (($stdout | Out-String) -split "`r?`n" | Where-Object { $_ -match '/issues/\d+' } | Select-Object -First 1)
        if ($line -and ($line -match '/issues/(\d+)')) {
            return [int]$Matches[1]
        }
        Write-Host "  gh issue create succeeded but no issue number could be parsed from output."
        return $null
    }
    catch {
        Write-Warning "  gh issue create threw: $_"
        return $null
    }
}

function Write-ManualQueueSummary {
    <#
    .SYNOPSIS
    Read-merge-write of `_reports/sync/manual-queue-summary.json`. Each call
    appends one entry; if the file already contains a list, the new entry is
    merged in. The summary is rewritten as a JSON array on every invocation.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Side effect is bounded to writing the summary file in OutputDir which is the explicit purpose of the function.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]         $SummaryPath,
        [Parameter(Mandatory)] [PSCustomObject] $Entry
    )

    $entries = @()
    if (Test-Path $SummaryPath) {
        try {
            $raw = Get-Content $SummaryPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $existing = $raw | ConvertFrom-Json -ErrorAction Stop
                $entries = @($existing)
            }
        }
        catch {
            Write-Warning "  Could not parse existing summary at $SummaryPath ($_); rewriting."
            $entries = @()
        }
    }
    $entries += $Entry

    ConvertTo-Json -InputObject @($entries) -Depth 30 -AsArray |
        Set-Content -Path $SummaryPath -Encoding UTF8
}

# ── Main ─────────────────────────────────────────────────────────────────────

$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$RunId     = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { "local-$([guid]::NewGuid().ToString('N').Substring(0,8))" }

if (-not (Test-HasProperty $Change 'targetResourceId')) {
    throw "Send-ToManualQueue: \$Change is missing required property 'targetResourceId'."
}
$TargetResourceId = [string]$Change.PSObject.Properties['targetResourceId'].Value
if ([string]::IsNullOrWhiteSpace($TargetResourceId)) {
    throw "Send-ToManualQueue: \$Change.targetResourceId is empty."
}

$ResourceIdHash = Get-ResourceIdHash -ResourceId $TargetResourceId

$ManualQueueDir = Join-Path $OutputDir 'manual-queue'
$null = New-Item -ItemType Directory -Force -Path $ManualQueueDir
$ManualQueuePath = Join-Path $ManualQueueDir "$ResourceIdHash.json"

# Project-relative path used inside the issue body so reviewers can browse to
# the artifact in the repo without bringing along the test workdir prefix.
$ManualQueueRelPath = "_reports/sync/manual-queue/$ResourceIdHash.json"

Write-Host "============================================================"
Write-Host "STAGE 8: Manual-queue handoff"
Write-Host "  Repo:           $RepoFull"
Write-Host "  Resource:       $TargetResourceId"
Write-Host "  Hash:           $ResourceIdHash"
Write-Host "  Manual queue:   $ManualQueuePath"
Write-Host "  Output dir:     $OutputDir"
Write-Host "  DryRun:         $($DryRun.IsPresent)"
Write-Host "============================================================"

# 1. Snapshot the ARM JSON. Copy by content so the artifact lives inside the
#    repo's _reports tree even when the source is in a temp workdir.
if (Test-Path $ArmJsonPath) {
    Copy-Item -Path $ArmJsonPath -Destination $ManualQueuePath -Force
} else {
    Write-Warning "  ArmJsonPath not found: $ArmJsonPath — writing placeholder."
    "{ `"_warning`": `"ARM JSON missing at submit time: $ArmJsonPath`" }" |
        Set-Content -Path $ManualQueuePath -Encoding UTF8
}

# 2. Build the issue title + body.
$ChangedBy            = [string](Get-ChangeField -Source $Change -Name 'changedBy' -Default '')
$ChangedByIsUserLogin = Test-IsGitHubUsername -Value $ChangedBy
$Assignee             = if ($ChangedByIsUserLogin) { $ChangedBy } else { '' }
$MentionChangedBy     = -not $ChangedByIsUserLogin

$ArmInline   = Read-ArmJsonForBody -Path $ManualQueuePath -MaxLines 200
$IssueTitle  = New-IssueTitle -Change $Change -ResourceIdHash $ResourceIdHash
$IssueBody   = New-IssueBody -Change $Change `
    -ManualQueueRelPath $ManualQueueRelPath -RunId $RunId `
    -ArmJsonInline $ArmInline -DecompileWarnings $DecompileWarnings `
    -MentionChangedBy $MentionChangedBy

# 3. Outcome decision tree.
$Outcome     = 'failed'
$IssueNumber = $null

if ($DryRun) {
    Write-Host "  DryRun: skipping gh issue list / gh issue create."
    $Outcome = 'skipped-dry-run'
}
else {
    $existing = Find-ExistingManualIssue -RepoFull $RepoFull -ResourceIdHash $ResourceIdHash
    if ($null -ne $existing) {
        Write-Host "  manual-queue issue already open: #$existing"
        $Outcome     = 'issue-already-open'
        $IssueNumber = [int]$existing
    }
    else {
        $created = Send-ManualIssue -RepoFull $RepoFull -Title $IssueTitle -Body $IssueBody -Assignee $Assignee
        if ($null -ne $created) {
            Write-Host "  created manual-queue issue #$created"
            $Outcome     = 'issue-created'
            $IssueNumber = [int]$created
        }
        else {
            Write-Warning "  manual-queue issue creation failed; recording 'failed' in summary."
            $Outcome = 'failed'
        }
    }
}

# 4. Append to summary.
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$SummaryPath = Join-Path $OutputDir 'manual-queue-summary.json'
$Entry = [PSCustomObject][ordered]@{
    resourceIdHash    = $ResourceIdHash
    targetResourceId  = $TargetResourceId
    outcome           = $Outcome
    issueNumber       = $IssueNumber
    manualQueuePath   = $ManualQueueRelPath
    runId             = $RunId
    timestamp         = $Timestamp
}
Write-ManualQueueSummary -SummaryPath $SummaryPath -Entry $Entry

# 5. Exit code: 0 for any non-failed outcome (idempotency wins), non-zero on
#    real failure so the caller can surface it without throwing.
if ($Outcome -eq 'failed') {
    Write-Warning "Send-ToManualQueue: outcome=failed for $TargetResourceId"
    exit 1
}

Write-Host "Send-ToManualQueue: outcome=$Outcome  hash=$ResourceIdHash  summary=$SummaryPath"
exit 0
