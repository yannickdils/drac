#Requires -Version 7.2
# =============================================================================
# scripts/sync/Sync-PortalChange.ps1
# Round 3 §R3.3 — per-change reverse-engineering pipeline.
#
# For every entry in the portal-changes.json produced by Find-PortalChanges.ps1
# (R3.2), this script:
#   1. Pulls the live ARM JSON via `az resource show --ids <id>`.
#   2. Wraps it in a minimal deployment template and writes it to
#      _reports/sync/work-<short-hash>/primary.json.
#   3. Decompiles the wrapped ARM with `az bicep decompile`, treating any
#      stderr warning OR non-zero exit as a "dirty" decompile.
#   4. On clean decompile, moves the resulting .bicep into
#      bicep/regions/primary/<rg>/<type-slug>-<name>.bicep.
#   5. Runs Convert-ForDR (scripts/lib/ConvertForDR.psm1) to derive the DR
#      companion ARM, decompiles that to Bicep, and places it at
#      bicep/regions/dr/dr-<type-slug>-<name>.bicep (FLAT — same convention
#      as Round 2's DR coverage gate).
#   6. Branches: portal-sync/<yyyyMMdd>-<short-hash>. Stable per resource +
#      date so re-runs do not duplicate branches.
#   7. Commits + pushes via scripts/lib/CommitBack.psm1's Push-Branch.
#   8. Opens a PR via `gh pr create`, but first checks `gh pr list --search`
#      so re-runs detect existing open PRs and skip duplicate creation.
#
# A dirty decompile (warnings or non-zero exit) skips steps 5-8 and instead
# invokes scripts/sync/Send-ToManualQueue.ps1 (R3.4 agent owns).
#
# Per-change failures are recorded in _reports/sync/sync-summary.json with a
# disposition of pr-opened | manual-queued | skipped | failed; the loop
# continues regardless.
#
# Test seams:
#   -DryRun                                — no az / gh / git side effects.
#   $env:DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS — semicolon-separated resource IDs
#                                           that should pretend the decompile
#                                           emitted warnings (used by the
#                                           round-3 test to exercise the dirty
#                                           branch without a real bicep CLI).
#   $env:DRAAC_SYNC_FORCE_EXISTING_PRS     — semicolon-separated branch names
#                                           or resource IDs that should be
#                                           treated as already having an open
#                                           PR (used to test idempotency).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ChangesFile,
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $RepoFull,
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId,

    [string] $DrRegion       = $(if ($env:DR_TARGET_REGION)         { $env:DR_TARGET_REGION }         else { 'northeurope' }),
    [string] $DrVnetPrefix   = $(if ($env:DR_VNET_ADDRESS_PREFIX)   { $env:DR_VNET_ADDRESS_PREFIX }   else { '10.100.0.0/16' }),
    [string] $DrSubnetPrefix = $(if ($env:DR_SUBNET_ADDRESS_PREFIX) { $env:DR_SUBNET_ADDRESS_PREFIX } else { '10.100.0.0/24' }),
    [string] $DrNamingPrefix = $(if ($env:DR_NAMING_PREFIX)         { $env:DR_NAMING_PREFIX }         else { 'dr-' }),

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Paths and module loading ─────────────────────────────────────────────────

$RepoRoot         = (Resolve-Path $RepoRoot).Path
$ConvertModule    = Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1'
$CommitBackModule = Join-Path $RepoRoot 'scripts/lib/CommitBack.psm1'
$ManualQueueScript = Join-Path $RepoRoot 'scripts/sync/Send-ToManualQueue.ps1'

if (-not (Test-Path $ConvertModule)) {
    Write-Error "Required module not found: $ConvertModule"
    exit 2
}
Import-Module $ConvertModule -Force

$null = New-Item -ItemType Directory -Force -Path $OutputDir
$SummaryFile = Join-Path $OutputDir 'sync-summary.json'

Write-Host "============================================================"
Write-Host "STAGE R3.3: Portal-Drift Reverse-Engineering Sync"
Write-Host "  Changes file:  $ChangesFile"
Write-Host "  Repo root:     $RepoRoot"
Write-Host "  Repo full:     $RepoFull"
Write-Host "  Output dir:    $OutputDir"
Write-Host "  Run id:        $RunId"
Write-Host "  DryRun:        $($DryRun.IsPresent)"
Write-Host "============================================================"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    # Strict-mode-safe property existence check (mirrors ConvertForDR.psm1).
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-TypeSlug {
    <#
    .SYNOPSIS
    Stable, filename-safe slug derived from an ARM resource type.

    .EXAMPLE
    Get-TypeSlug -Type 'Microsoft.Network/virtualNetworks'
    # → 'microsoft-network-virtualnetworks'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Type)
    $slug = $Type.ToLowerInvariant()
    $slug = $slug -replace '[/.]', '-'
    $slug = $slug -replace '[^a-z0-9-]', '-'
    $slug = $slug -replace '-+', '-'
    $slug = $slug.Trim('-')
    return $slug
}

function Get-ResourceIdHash {
    <#
    .SYNOPSIS
    First 12 hex characters of SHA-256(resourceId). Stable per resource,
    short enough to embed in branch names and work-directory paths.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResourceId,
        [int] $Length = 12
    )
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResourceId.ToLowerInvariant())
        $hash  = $sha.ComputeHash($bytes)
        $hex   = -join ($hash | ForEach-Object { $_.ToString('x2') })
        return $hex.Substring(0, [Math]::Min($Length, $hex.Length))
    }
    finally {
        $sha.Dispose()
    }
}

function Get-PortalUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ResourceId)
    return "https://portal.azure.com/#@/resource$ResourceId"
}

function Test-LooksLikeGitHubUser {
    # Heuristic — `changedBy` from Resource Graph is usually a UPN
    # (`alice@contoso.com`) which is not a GitHub login. Only treat the value
    # as a reviewer handle if it contains no '@' and matches the conservative
    # GitHub username shape.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    if ($Candidate.Contains('@')) { return $false }
    return ($Candidate -match '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$')
}

function Read-PortalChanges {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns a list of portal-change records; plural noun matches the contract.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path $Path)) {
        Write-Warning "Changes file not found: $Path — treating as empty"
        return @()
    }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $parsed = $raw | ConvertFrom-Json -Depth 30
    if ($parsed -is [System.Collections.IList]) { return @($parsed) }
    if ($parsed -is [System.Management.Automation.PSCustomObject] -and (Test-HasProperty $parsed 'changes')) {
        return @($parsed.changes)
    }
    return @($parsed)
}

function Invoke-AzResourceShow {
    <#
    .SYNOPSIS
    Calls `az resource show --ids <id>` and returns the raw JSON string. Honors
    -DryRun by returning a synthetic but plausible ARM JSON for the resource.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [switch] $DryRun
    )
    if ($DryRun) {
        $name = if (Test-HasProperty $Change 'resourceName')   { $Change.resourceName }   else { 'unknown' }
        $type = if (Test-HasProperty $Change 'targetResourceType') { $Change.targetResourceType } else { 'Microsoft.Storage/storageAccounts' }
        $id   = if (Test-HasProperty $Change 'targetResourceId') { $Change.targetResourceId } else { '/subscriptions/x/resourceGroups/y/providers/x/y' }
        $synthetic = [ordered]@{
            id         = $id
            name       = $name
            type       = $type
            location   = 'westeurope'
            apiVersion = '2023-01-01'
            sku        = @{ name = 'Standard_LRS' }
            kind       = 'StorageV2'
            properties = @{
                minimumTlsVersion        = 'TLS1_2'
                supportsHttpsTrafficOnly = $true
                allowBlobPublicAccess    = $false
            }
            tags       = @{
                'draac-portal-sync' = 'true'
            }
        }
        return ($synthetic | ConvertTo-Json -Depth 30)
    }

    $output = & az resource show --ids $Change.targetResourceId --output json 2>&1
    $exit   = $LASTEXITCODE
    if ($exit -ne 0) {
        throw "az resource show failed (exit=$exit): $($output | Out-String)"
    }
    return ($output | Out-String)
}

function ConvertTo-WrappedTemplate {
    <#
    .SYNOPSIS
    Wraps a single ARM resource JSON document in a minimal deployment template.
    Strips fields that the Resource Graph view of `az resource show` returns
    that bicep decompile rejects (id, apiVersion fields are handled correctly,
    but `id` at the resource level is read-only and confuses decompile).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ResourceJson)

    $resource = $ResourceJson | ConvertFrom-Json -Depth 50

    # az resource show returns the resource itself, not wrapped. If the caller
    # already passed a deployment template, just use its first resource.
    if (Test-HasProperty $resource 'resources') {
        $first = @($resource.resources)[0]
        if ($first) { $resource = $first }
    }

    # Drop top-level `id` (read-only and not allowed in templates).
    if (Test-HasProperty $resource 'id') {
        $resource.PSObject.Properties.Remove('id')
    }
    # Ensure apiVersion is present — az resource show uses `apiVersion` already.
    if (-not (Test-HasProperty $resource 'apiVersion')) {
        $resource | Add-Member -MemberType NoteProperty -Name apiVersion -Value '2023-01-01' -Force
    }

    $wrapped = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        'contentVersion' = '1.0.0.0'
        'resources'    = @($resource)
    }
    return ($wrapped | ConvertTo-Json -Depth 50)
}

function Test-BicepCliAvailable {
    if (Get-Command bicep -ErrorAction SilentlyContinue) { return 'bicep' }
    if (Get-Command az    -ErrorAction SilentlyContinue) { return 'az' }
    return $null
}

function Invoke-DecompileToBicep {
    <#
    .SYNOPSIS
    Decompiles a wrapped ARM template via `az bicep decompile`. Returns a
    PSCustomObject with three properties:
      - Success      : $true if exit code is 0 AND no warnings were emitted
      - ProducedFile : absolute path to the .bicep file (when found)
      - Warnings     : captured stderr/stdout warning text (always a string)

    Honors -DryRun by writing a stub .bicep file and returning Success=$true,
    UNLESS the caller-supplied $ForceDirty flag is set, in which case it
    returns Success=$false with synthetic warning text — used by the test to
    exercise the dirty-decompile branch without a real CLI.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $InFile,
        [Parameter(Mandatory)] [string] $OutDir,
        [switch] $DryRun,
        [switch] $ForceDirty
    )

    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $stem      = [System.IO.Path]::GetFileNameWithoutExtension($InFile)
    $produced  = Join-Path $OutDir "$stem.bicep"

    if ($DryRun) {
        if ($ForceDirty) {
            return [PSCustomObject]@{
                Success      = $false
                ProducedFile = $null
                Warnings     = "WARNING: simulated dirty decompile for dry-run test seam"
            }
        }
        # Synthesize a plausible .bicep file so downstream Move-Item succeeds.
        Set-Content -Path $produced -Value "// dry-run synthetic decompile of $stem`n" -Encoding UTF8
        return [PSCustomObject]@{
            Success      = $true
            ProducedFile = $produced
            Warnings     = ''
        }
    }

    $cli = Test-BicepCliAvailable
    if (-not $cli) {
        return [PSCustomObject]@{
            Success      = $false
            ProducedFile = $null
            Warnings     = 'bicep CLI not available (no `bicep` or `az` on PATH)'
        }
    }

    $stderrFile = Join-Path $OutDir "decompile-$stem.stderr.log"
    $stdoutFile = Join-Path $OutDir "decompile-$stem.stdout.log"

    $proc = if ($cli -eq 'bicep') {
        Start-Process -FilePath 'bicep' -ArgumentList @('decompile', $InFile, '--outdir', $OutDir) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardError  $stderrFile `
            -RedirectStandardOutput $stdoutFile
    } else {
        Start-Process -FilePath 'az' -ArgumentList @('bicep', 'decompile', '--file', $InFile, '--outdir', $OutDir) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardError  $stderrFile `
            -RedirectStandardOutput $stdoutFile
    }
    $exit = if ($proc) { $proc.ExitCode } else { 1 }
    $stderrText = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { '' }
    $stdoutText = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { '' }
    $combined   = "$stderrText`n$stdoutText"

    # Treat any "WARNING" / "Warning" line as a dirty decompile.
    $hasWarning = ($combined -match '(?im)^\s*(warning|warn)\b' -or $combined -match '(?i)\bWARNING\b')

    if ($exit -ne 0 -or $hasWarning) {
        return [PSCustomObject]@{
            Success      = $false
            ProducedFile = (Test-Path $produced) ? $produced : $null
            Warnings     = $combined.Trim()
        }
    }

    return [PSCustomObject]@{
        Success      = (Test-Path $produced)
        ProducedFile = (Test-Path $produced) ? $produced : $null
        Warnings     = ''
    }
}

function Test-PrAlreadyOpen {
    <#
    .SYNOPSIS
    Uses `gh pr list --search "<title>" --state open` to detect a duplicate.
    Returns $true when a PR with the exact title already exists open.

    Honors -DryRun by consulting $env:DRAAC_SYNC_FORCE_EXISTING_PRS instead.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $RepoFull,
        [Parameter(Mandatory)] [string] $Branch,
        [switch] $DryRun
    )
    if ($DryRun) {
        $forced = $env:DRAAC_SYNC_FORCE_EXISTING_PRS
        if ([string]::IsNullOrWhiteSpace($forced)) { return $false }
        $tokens = $forced.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
        foreach ($t in $tokens) {
            if ($t -eq $Branch -or $t -eq $Title) { return $true }
        }
        return $false
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "gh CLI not on PATH — cannot check for existing PR; assuming none"
        return $false
    }

    $output = & gh pr list --repo $RepoFull --state open --search $Title --json number,title,headRefName 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
    try {
        $items = $output | ConvertFrom-Json -Depth 5
    } catch {
        return $false
    }
    foreach ($item in @($items)) {
        if ((Test-HasProperty $item 'title') -and $item.title -eq $Title) { return $true }
        if ((Test-HasProperty $item 'headRefName') -and $item.headRefName -eq $Branch) { return $true }
    }
    return $false
}

function New-PortalSyncPr {
    <#
    .SYNOPSIS
    Creates a PR via `gh pr create`. Honors -DryRun by logging only.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The function IS the side effect; ShouldProcess would interfere with non-interactive CI use.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $RepoFull,
        [Parameter(Mandatory)] [string] $Branch,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Body,
        [string]   $Reviewer,
        [string[]] $Labels  = @('portal-sync'),
        [switch]   $DryRun
    )
    if ($DryRun) {
        Write-Host "  DryRun: gh pr create --repo $RepoFull --head $Branch --title `"$Title`" (labels: $($Labels -join ',') reviewer: $Reviewer)"
        return $true
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "gh CLI not on PATH — cannot open PR for $Branch"
        return $false
    }

    $ghArgs = @(
        'pr', 'create',
        '--repo',  $RepoFull,
        '--head',  $Branch,
        '--title', $Title,
        '--body',  $Body
    )
    foreach ($l in $Labels) { $ghArgs += @('--label', $l) }
    if ($Reviewer) { $ghArgs += @('--reviewer', $Reviewer) }

    & gh @ghArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gh pr create failed for $Branch"
        return $false
    }
    return $true
}

function Format-PrBody {
    <#
    .SYNOPSIS
    Builds the markdown body for the portal-sync PR.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [Parameter(Mandatory)] [string]         $PrimaryRel,
        [Parameter(Mandatory)] [string]         $DrRel,
        [Parameter(Mandatory)] [string]         $RunId
    )
    $changedBy = if (Test-HasProperty $Change 'changedBy') { $Change.changedBy } else { 'unknown' }
    $portalUrl = Get-PortalUrl -ResourceId $Change.targetResourceId

    $propsList = @()
    if ((Test-HasProperty $Change 'changedProperties') -and $Change.changedProperties) {
        $propsList = @($Change.changedProperties)
    }
    $propsMd = if ($propsList.Count -eq 0) {
        '_(none reported)_'
    } else {
        ($propsList | ForEach-Object { "- ``$_``" }) -join "`n"
    }

    $changedAt = if (Test-HasProperty $Change 'timestamp') { $Change.timestamp } else { '(unknown)' }
    $changeType = if (Test-HasProperty $Change 'changeType') { $Change.changeType } else { '(unknown)' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("## Portal-drift reverse-engineering sync")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Reconciles a change made directly in the Azure portal back into IaC.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Resource:** ``$($Change.targetResourceId)``")
    [void]$sb.AppendLine("**Type:** ``$($Change.targetResourceType)``")
    [void]$sb.AppendLine("**Changed by:** $changedBy")
    [void]$sb.AppendLine("**Change type:** $changeType")
    [void]$sb.AppendLine("**Changed at:** $changedAt")
    [void]$sb.AppendLine("**Run id:** ``$RunId``")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("[Open in Azure portal]($portalUrl)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### Changed properties")
    [void]$sb.AppendLine($propsMd)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### Files updated")
    [void]$sb.AppendLine("- Primary: ``$PrimaryRel``")
    [void]$sb.AppendLine("- DR companion: ``$DrRel``")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### Reviewer checklist")
    [void]$sb.AppendLine("- [ ] The decompiled Bicep correctly reflects the portal-side change")
    [void]$sb.AppendLine("- [ ] The DR companion is a sound counterpart (region, naming, address space)")
    [void]$sb.AppendLine("- [ ] No secrets or read-only ARM properties leaked into the committed Bicep")
    [void]$sb.AppendLine("- [ ] Matching workload tags / role tags are preserved")
    [void]$sb.AppendLine("- [ ] Resource was intended to be portal-managed; if not, also discuss policy")
    return $sb.ToString()
}

function Invoke-ManualQueue {
    <#
    .SYNOPSIS
    Invokes scripts/sync/Send-ToManualQueue.ps1 (R3.4 agent owns) per the
    contract documented in the brief. Defensively passes optional args; the
    R3.4 author can ignore unknown ones.

    DryRun mode skips the actual invocation and just logs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to another script; the side effect lives there. ShouldProcess would interfere with CI use.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [Parameter(Mandatory)] [string]         $ArmJsonPath,
        [Parameter(Mandatory)] [string]         $RepoFull,
        [Parameter(Mandatory)] [string]         $OutputDir,
        [Parameter(Mandatory)] [string]         $DecompileWarnings,
        [Parameter(Mandatory)] [string]         $ScriptPath,
        [switch] $DryRun
    )
    if ($DryRun) {
        Write-Host "  DryRun: would invoke Send-ToManualQueue for $($Change.targetResourceId)"
        Write-Host "          warnings: $($DecompileWarnings.Substring(0, [Math]::Min(120, $DecompileWarnings.Length)))..."
        return $true
    }
    if (-not (Test-Path $ScriptPath)) {
        Write-Warning "Send-ToManualQueue.ps1 not found at $ScriptPath — recording as failed"
        return $false
    }
    try {
        & $ScriptPath `
            -Change             $Change `
            -ArmJsonPath        $ArmJsonPath `
            -RepoFull           $RepoFull `
            -OutputDir          $OutputDir `
            -DecompileWarnings  $DecompileWarnings `
            -DryRun:$DryRun
        return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
    } catch {
        Write-Warning "Send-ToManualQueue threw: $_"
        return $false
    }
}

function Get-DirtyResourceIdSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns a set of identifiers; plural noun reflects the contract.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param()
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($env:DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS)) {
        foreach ($id in $env:DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
            [void]$set.Add($id.Trim())
        }
    }
    return $set
}

function Invoke-CommitAndPush {
    <#
    .SYNOPSIS
    Wraps Push-Branch from CommitBack.psm1 with a -DryRun shortcut.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The function IS the side effect; ShouldProcess would interfere with non-interactive CI use.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]   $RepoRoot,
        [Parameter(Mandatory)] [string]   $Branch,
        [Parameter(Mandatory)] [string]   $RunId,
        [Parameter(Mandatory)] [string[]] $Files,
        [Parameter(Mandatory)] [string]   $Message,
        [switch] $DryRun
    )
    if ($DryRun) {
        Write-Host "  DryRun: would push $($Files.Count) file(s) to branch $Branch"
        foreach ($f in $Files) { Write-Host "          + $f" }
        return $true
    }
    if (-not (Test-Path $CommitBackModule)) {
        Write-Warning "CommitBack module missing: $CommitBackModule"
        return $false
    }
    Import-Module $CommitBackModule -Force
    return [bool] (Push-Branch -RepoRoot $RepoRoot -Branch $Branch -RunId $RunId -Files $Files -Message $Message)
}

# ── Per-change pipeline ──────────────────────────────────────────────────────

function Invoke-OnePortalChange {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The function IS the side effect; ShouldProcess would interfere with non-interactive CI use.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [Parameter(Mandatory)] [hashtable]      $Context
    )

    $resourceId = if (Test-HasProperty $Change 'targetResourceId') { $Change.targetResourceId } else { $null }
    if (-not $resourceId) {
        return [PSCustomObject]@{
            disposition = 'skipped'
            reason      = 'missing targetResourceId'
            resourceId  = $null
            branch      = $null
        }
    }

    $resourceName = if (Test-HasProperty $Change 'resourceName') { $Change.resourceName } else { 'unknown' }
    $resourceType = if (Test-HasProperty $Change 'targetResourceType') { $Change.targetResourceType } else { 'unknown' }
    $rg           = if (Test-HasProperty $Change 'resourceGroupName') { $Change.resourceGroupName } else { 'unknown-rg' }
    $hash         = Get-ResourceIdHash -ResourceId $resourceId
    $typeSlug     = Get-TypeSlug -Type $resourceType
    $datestamp    = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
    $branch       = "portal-sync/$datestamp-$hash"
    $title        = "[portal-sync] Reconcile portal change to $resourceName"

    Write-Host ""
    Write-Host "── $resourceId ──"
    Write-Host "  hash=$hash  type-slug=$typeSlug  branch=$branch"

    $workDir = Join-Path $Context.OutputDir "work-$hash"
    $null    = New-Item -ItemType Directory -Force -Path $workDir
    $primaryArm = Join-Path $workDir 'primary.json'
    $drArm      = Join-Path $workDir 'dr.json'

    # Idempotency check: bail early if a PR is already open with the exact title.
    if (Test-PrAlreadyOpen -Title $title -RepoFull $Context.RepoFull -Branch $branch -DryRun:$Context.DryRun) {
        Write-Host "  PR with this title is already open — skipping (idempotent no-op)"
        return [PSCustomObject]@{
            disposition = 'skipped'
            reason      = 'duplicate-pr-open'
            resourceId  = $resourceId
            branch      = $branch
            title       = $title
        }
    }

    # 1. az resource show (or synthetic).
    $rawJson = $null
    try {
        $rawJson = Invoke-AzResourceShow -Change $Change -DryRun:$Context.DryRun
    } catch {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = "az resource show failed: $_"
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    # 2. Wrap and persist primary.json.
    try {
        $wrapped = ConvertTo-WrappedTemplate -ResourceJson $rawJson
        Set-Content -Path $primaryArm -Value $wrapped -Encoding UTF8
    } catch {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = "wrap-template failed: $_"
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    # 3. Decompile primary → primary.bicep.
    $forceDirty = $Context.DirtyIds.Contains($resourceId)
    $primaryDecompile = Invoke-DecompileToBicep `
        -InFile $primaryArm `
        -OutDir $workDir `
        -DryRun:$Context.DryRun `
        -ForceDirty:$forceDirty

    if (-not $primaryDecompile.Success) {
        Write-Warning "  Dirty primary decompile — sending to manual queue"
        $queued = Invoke-ManualQueue `
            -Change            $Change `
            -ArmJsonPath       $primaryArm `
            -RepoFull          $Context.RepoFull `
            -OutputDir         $Context.OutputDir `
            -DecompileWarnings $primaryDecompile.Warnings `
            -ScriptPath        $Context.ManualQueueScript `
            -DryRun:$Context.DryRun
        return [PSCustomObject]@{
            disposition = ($queued ? 'manual-queued' : 'failed')
            reason      = ($queued ? 'dirty primary decompile — manual queue invoked' : 'dirty primary decompile and manual queue invocation failed')
            resourceId  = $resourceId
            branch      = $branch
            warnings    = $primaryDecompile.Warnings
        }
    }

    # 4. Move the decompiled primary into bicep/regions/primary/<rg>/<type-slug>-<name>.bicep.
    $primaryRel = "bicep/regions/primary/$rg/$typeSlug-$resourceName.bicep"
    $primaryDest = Join-Path $Context.RepoRoot $primaryRel
    $null = New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($primaryDest))
    try {
        Move-Item -Force -Path $primaryDecompile.ProducedFile -Destination $primaryDest
    } catch {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = "could not place primary bicep: $_"
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    # 5. Convert-ForDR.
    try {
        $template = Get-Content $primaryArm -Raw | ConvertFrom-Json -Depth 50
        $drResult = Convert-ForDR -Template $template `
            -DrRegion       $Context.DrRegion `
            -DrVnetPrefix   $Context.DrVnetPrefix `
            -DrSubnetPrefix $Context.DrSubnetPrefix `
            -DrNamingPrefix $Context.DrNamingPrefix
        $drResult.Template | ConvertTo-Json -Depth 30 | Set-Content $drArm -Encoding UTF8
    } catch {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = "Convert-ForDR failed: $_"
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    # 6. Decompile DR ARM.
    $drDecompile = Invoke-DecompileToBicep `
        -InFile $drArm `
        -OutDir $workDir `
        -DryRun:$Context.DryRun `
        -ForceDirty:$forceDirty

    if (-not $drDecompile.Success) {
        Write-Warning "  Dirty DR decompile — sending to manual queue"
        $queued = Invoke-ManualQueue `
            -Change            $Change `
            -ArmJsonPath       $drArm `
            -RepoFull          $Context.RepoFull `
            -OutputDir         $Context.OutputDir `
            -DecompileWarnings $drDecompile.Warnings `
            -ScriptPath        $Context.ManualQueueScript `
            -DryRun:$Context.DryRun
        return [PSCustomObject]@{
            disposition = ($queued ? 'manual-queued' : 'failed')
            reason      = ($queued ? 'dirty DR decompile — manual queue invoked' : 'dirty DR decompile and manual queue invocation failed')
            resourceId  = $resourceId
            branch      = $branch
            warnings    = $drDecompile.Warnings
        }
    }

    # 7. Place DR companion FLAT under bicep/regions/dr/.
    $drRel  = "bicep/regions/dr/dr-$typeSlug-$resourceName.bicep"
    $drDest = Join-Path $Context.RepoRoot $drRel
    $null = New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($drDest))
    try {
        Move-Item -Force -Path $drDecompile.ProducedFile -Destination $drDest
    } catch {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = "could not place dr bicep: $_"
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    # 8. Commit + push branch.
    $pushed = Invoke-CommitAndPush `
        -RepoRoot $Context.RepoRoot `
        -Branch   $branch `
        -RunId    $Context.RunId `
        -Files    @($primaryDest, $drDest) `
        -Message  "chore(draac): portal-sync $resourceName" `
        -DryRun:$Context.DryRun
    if (-not $pushed) {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = 'push failed'
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    # 9. PR creation.
    $changedBy = if (Test-HasProperty $Change 'changedBy') { $Change.changedBy } else { '' }
    $reviewer  = if (Test-LooksLikeGitHubUser -Candidate $changedBy) { $changedBy } else { $null }
    $body = Format-PrBody -Change $Change -PrimaryRel $primaryRel -DrRel $drRel -RunId $Context.RunId
    $opened = New-PortalSyncPr `
        -RepoFull $Context.RepoFull `
        -Branch   $branch `
        -Title    $title `
        -Body     $body `
        -Reviewer $reviewer `
        -DryRun:$Context.DryRun

    if (-not $opened) {
        return [PSCustomObject]@{
            disposition = 'failed'
            reason      = 'gh pr create failed'
            resourceId  = $resourceId
            branch      = $branch
        }
    }

    return [PSCustomObject]@{
        disposition = 'pr-opened'
        reason      = 'success'
        resourceId  = $resourceId
        branch      = $branch
        title       = $title
        primary     = $primaryRel
        dr          = $drRel
        reviewer    = $reviewer
    }
}

# ── Main loop ────────────────────────────────────────────────────────────────

$Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$changes   = @(Read-PortalChanges -Path $ChangesFile)
Write-Host "INFO: $($changes.Count) portal change(s) to process"

$context = @{
    RepoRoot           = $RepoRoot
    RepoFull           = $RepoFull
    OutputDir          = $OutputDir
    RunId              = $RunId
    DrRegion           = $DrRegion
    DrVnetPrefix       = $DrVnetPrefix
    DrSubnetPrefix     = $DrSubnetPrefix
    DrNamingPrefix     = $DrNamingPrefix
    DryRun             = $DryRun.IsPresent
    DirtyIds           = (Get-DirtyResourceIdSet)
    ManualQueueScript  = $ManualQueueScript
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($change in $changes) {
    try {
        $r = Invoke-OnePortalChange -Change $change -Context $context
    } catch {
        $r = [PSCustomObject]@{
            disposition = 'failed'
            reason      = "uncaught: $_"
            resourceId  = (Test-HasProperty $change 'targetResourceId') ? $change.targetResourceId : $null
            branch      = $null
        }
    }
    $results.Add($r)
}

# ── Aggregate counts ─────────────────────────────────────────────────────────

$counts = [ordered]@{
    'pr-opened'     = @($results | Where-Object { $_.disposition -eq 'pr-opened' }).Count
    'manual-queued' = @($results | Where-Object { $_.disposition -eq 'manual-queued' }).Count
    'skipped'       = @($results | Where-Object { $_.disposition -eq 'skipped' }).Count
    'failed'        = @($results | Where-Object { $_.disposition -eq 'failed' }).Count
}

$summary = [ordered]@{
    runId        = $RunId
    timestamp    = $Timestamp
    repoFull     = $RepoFull
    drRegion     = $DrRegion
    totalChanges = $changes.Count
    counts       = $counts
    results      = $results
}
$summary | ConvertTo-Json -Depth 30 | Set-Content $SummaryFile -Encoding UTF8

Write-Host ""
Write-Host "PORTAL-SYNC COMPLETE  total=$($changes.Count)  pr-opened=$($counts.'pr-opened')  manual-queued=$($counts.'manual-queued')  skipped=$($counts.'skipped')  failed=$($counts.'failed')"
Write-Host "  Summary: $SummaryFile"

if ($counts.'failed' -gt 0) { exit 1 } else { exit 0 }
