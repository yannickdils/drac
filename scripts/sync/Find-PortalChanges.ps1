#Requires -Version 7.2
# =============================================================================
# scripts/sync/Find-PortalChanges.ps1
# Round 3.2: Detect manual portal changes via Azure Resource Graph.
#
# Strategy:
#   1. Query the `resourcechanges` table over the last $LookbackHours window.
#      The result set is then filtered + coalesced by `targetResourceId`.
#   2. Filter rules:
#        - readonly-only changes are skipped (every changedProperty is in
#          data/readonly-properties.json's `global` list).
#        - System-managed resources are skipped by name pattern
#          (NetworkWatcher*, DefaultResourceGroup*, cloud-shell*, AzureBackupRG*).
#          Match against the resource's name OR its containing RG.
#   3. Coalesce: multiple changes to the same `targetResourceId` collapse into
#      one entry holding the latest timestamp's snapshot.
#
# Outputs (all under $OutputDir):
#   portal-changes.json          — kept entries (each with skipReason: $null)
#   portal-changes-skipped.json  — filtered-out entries with skipReason set
#   portal-changes-summary.json  — run id + counters + skip-reason breakdown
#
# Test seam:
#   -DryRun + -FixtureFile <path> bypasses the `az graph query` call and runs
#   the same filter/coalesce pipeline against a hand-rolled JSON fixture.
#
# Idempotency:
#   Running twice on the same fixture produces byte-identical output (entries
#   are sorted by timestamp then targetResourceId before serialisation).
#
# Fault tolerance:
#   A single malformed change record is logged + counted as `malformed` and
#   skipped; the run continues.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId,
    [int]    $LookbackHours = 24,
    [switch] $DryRun,
    [string] $FixtureFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Constants ────────────────────────────────────────────────────────────────

# System-managed resource name prefixes we never want to sync. These match
# against either the resource name itself or the resource group it lives in.
$Script:SystemManagedPatterns = @(
    'NetworkWatcher*',
    'DefaultResourceGroup*',
    'cloud-shell*',
    'AzureBackupRG*'
)

# Resource Graph KQL submitted to `az graph query`. The mostly-hand-written
# query asks for changes over the last N hours and projects the per-record
# fields the rest of the pipeline expects. `properties.changedProperties` is
# kept as a bag and flattened during normalisation so we can support both the
# Resource Graph "key/value/propertyChangeType" shape and a simpler
# "list of property paths" fixture shape.
$Script:KqlTemplate = @'
resourcechanges
| where properties.changeAttributes.timestamp > ago({0}h)
| extend targetResourceId    = tolower(tostring(properties.targetResourceId))
| extend targetResourceType  = tostring(properties.targetResourceType)
| extend changeType          = tostring(properties.changeType)
| extend changeTimestamp     = todatetime(properties.changeAttributes.timestamp)
| extend changedBy           = tostring(properties.changeAttributes.changedBy)
| extend changedProperties   = properties.changes
| project
    targetResourceId,
    targetResourceType,
    subscriptionId,
    resourceGroup,
    name,
    changeType,
    changeTimestamp,
    changedBy,
    changedProperties
| order by changeTimestamp desc
'@

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    # Strict-mode-safe property existence check (mirrors ConvertForDR.psm1
    # lines 23-44). The PSObject.Properties[name] indexer returns $null when
    # the property is missing AND when the property collection is empty,
    # so it works in both cases without requiring `.Count` or `.Name`
    # projection (both of which throw under Set-StrictMode -Version Latest).
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    # Strict-mode-safe property accessor with a default fallback.
    # Uses the , (comma) operator on arrays to defeat PowerShell's pipeline
    # auto-unwrap of single-element arrays — without this, a property whose
    # value is `["provisioningState"]` would emerge from this function as the
    # bare string `"provisioningState"`, making downstream IEnumerable checks
    # silently fall through.
    param($Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if (Test-HasProperty $Object $Name) {
        $val = $Object.$Name
        if ($val -is [System.Array] -or $val -is [System.Collections.IList]) {
            return ,$val
        }
        return $val
    }
    return $Default
}

function Read-ReadOnlyGlobalList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Read-only file accessor; ShouldProcess would be misleading.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns a list; plural is the natural noun here.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )
    $path = Join-Path $RepoRoot 'data/readonly-properties.json'
    if (-not (Test-Path $path)) {
        Write-Warning "  readonly-properties.json not found at $path — skip-by-readonly disabled."
        return @()
    }
    $obj = Get-Content $path -Raw | ConvertFrom-Json
    if ((Test-HasProperty $obj 'global') -and $obj.global) {
        return @($obj.global)
    }
    return @()
}

function Test-MatchesAnyPattern {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]   $Value,
        [string[]] $Patterns
    )
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    foreach ($p in $Patterns) {
        if ($Value -like $p) { return $true }
    }
    return $false
}

function ConvertTo-PropertyPathList {
    <#
    .SYNOPSIS
    Normalises the `changedProperties` field into a flat string[] of property
    paths.

    .DESCRIPTION
    Resource Graph emits `properties.changes` as a property bag whose keys are
    property paths and whose values are { propertyChangeType, previousValue,
    newValue } objects. Test fixtures often use the simpler "list of strings"
    shape directly. This helper accepts both and always returns a sorted
    string[].
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Returns a list of property paths; "PathList" is the natural noun.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param($ChangedProperties)

    if ($null -eq $ChangedProperties) { return @() }

    # Already a list/array of strings.
    if ($ChangedProperties -is [System.Collections.IEnumerable] -and `
        $ChangedProperties -isnot [string]) {
        $items = @($ChangedProperties)
        if ($items.Count -eq 0) { return @() }
        if ($items[0] -is [string]) {
            return @($items | Sort-Object -Unique)
        }
        # List of objects with a `name`/`path`/`property` field.
        $names = foreach ($it in $items) {
            if ($it -is [string]) { $it }
            elseif (Test-HasProperty $it 'path')     { [string]$it.path }
            elseif (Test-HasProperty $it 'name')     { [string]$it.name }
            elseif (Test-HasProperty $it 'property') { [string]$it.property }
            else { $null }
        }
        return @($names | Where-Object { $_ } | Sort-Object -Unique)
    }

    # PSCustomObject — treat property names as the paths.
    if ($ChangedProperties -is [System.Management.Automation.PSCustomObject]) {
        $names = foreach ($p in $ChangedProperties.PSObject.Properties) { $p.Name }
        return @($names | Where-Object { $_ } | Sort-Object -Unique)
    }

    return @()
}

function Get-ResourceGroupFromId {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $ResourceId)
    if ([string]::IsNullOrEmpty($ResourceId)) { return $null }
    if ($ResourceId -match '/resourceGroups/([^/]+)') {
        return $Matches[1]
    }
    return $null
}

function Get-ResourceNameFromId {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $ResourceId)
    if ([string]::IsNullOrEmpty($ResourceId)) { return $null }
    $segments = $ResourceId.TrimEnd('/').Split('/')
    if ($segments.Count -lt 1) { return $null }
    return $segments[-1]
}

function Get-ResourceTypeFromId {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $ResourceId)
    if ([string]::IsNullOrEmpty($ResourceId)) { return $null }
    if ($ResourceId -match '/providers/([^/]+/[^/]+(?:/[^/]+)*)/[^/]+$') {
        $tail = $Matches[1]
        # Strip trailing /<name>/<subtype>/<name>... — we want provider/type only.
        $parts = $tail.Split('/')
        if ($parts.Count -ge 2) {
            $namespace = $parts[0]
            $typeParts = @()
            for ($i = 1; $i -lt $parts.Count; $i += 2) {
                $typeParts += $parts[$i]
            }
            return ("{0}/{1}" -f $namespace, ($typeParts -join '/'))
        }
    }
    return $null
}

function ConvertTo-NormalisedChange {
    <#
    .SYNOPSIS
    Normalises a raw Resource Graph row (or fixture row) into the canonical
    portal-change record shape.

    .DESCRIPTION
    Returns $null on a malformed row. Callers count $null returns as
    "malformed" and continue.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Row
    )
    try {
        $targetResourceId = [string](Get-PropertyValue $Row 'targetResourceId')
        if ([string]::IsNullOrEmpty($targetResourceId)) {
            # Some fixtures put the id in `id` instead.
            $targetResourceId = [string](Get-PropertyValue $Row 'id')
        }
        if ([string]::IsNullOrEmpty($targetResourceId)) { return $null }

        $rgFromId   = Get-ResourceGroupFromId -ResourceId $targetResourceId
        $nameFromId = Get-ResourceNameFromId  -ResourceId $targetResourceId
        $typeFromId = Get-ResourceTypeFromId  -ResourceId $targetResourceId

        $subId = [string](Get-PropertyValue $Row 'subscriptionId')
        if ([string]::IsNullOrEmpty($subId) -and $targetResourceId -match '/subscriptions/([^/]+)') {
            $subId = $Matches[1]
        }

        $rgName = [string](Get-PropertyValue $Row 'resourceGroupName')
        if ([string]::IsNullOrEmpty($rgName)) { $rgName = [string](Get-PropertyValue $Row 'resourceGroup') }
        if ([string]::IsNullOrEmpty($rgName)) { $rgName = $rgFromId }

        $resourceName = [string](Get-PropertyValue $Row 'resourceName')
        if ([string]::IsNullOrEmpty($resourceName)) { $resourceName = [string](Get-PropertyValue $Row 'name') }
        if ([string]::IsNullOrEmpty($resourceName)) { $resourceName = $nameFromId }

        $resourceType = [string](Get-PropertyValue $Row 'targetResourceType')
        if ([string]::IsNullOrEmpty($resourceType)) { $resourceType = [string](Get-PropertyValue $Row 'type') }
        if ([string]::IsNullOrEmpty($resourceType)) { $resourceType = $typeFromId }

        $changeType  = [string](Get-PropertyValue $Row 'changeType' 'Update')
        $changedBy   = [string](Get-PropertyValue $Row 'changedBy')
        $tsRaw       = Get-PropertyValue $Row 'timestamp'
        if ($null -eq $tsRaw) { $tsRaw = Get-PropertyValue $Row 'changeTimestamp' }
        $timestamp   = ConvertTo-IsoTimestamp -Value $tsRaw

        $changed = ConvertTo-PropertyPathList -ChangedProperties (Get-PropertyValue $Row 'changedProperties')

        return [PSCustomObject]@{
            targetResourceId   = $targetResourceId
            targetResourceType = $resourceType
            subscriptionId     = $subId
            resourceGroupName  = $rgName
            resourceName       = $resourceName
            changeType         = $changeType
            changedBy          = $changedBy
            timestamp          = $timestamp
            changedProperties  = $changed
            skipReason         = $null
        }
    }
    catch {
        Write-Warning "  malformed change record skipped: $_"
        return $null
    }
}

function ConvertTo-IsoTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
                [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
            return $parsed.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        return $Value
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    return [string]$Value
}

function Get-SkipReason {
    <#
    .SYNOPSIS
    Returns the skip reason for a normalised change, or $null if it should be
    kept.

    .DESCRIPTION
    Skip rules (in priority order):
      1. system-managed name match — resource name OR rg name matches one of
         the SystemManagedPatterns.
      2. readonly-only — every entry in changedProperties (after stripping the
         leading `properties.` segment) is in the global readonly skip list.
         An empty changedProperties list is NOT considered readonly-only;
         we keep those (Create/Delete events frequently have no per-property
         diff and the operator still wants to see them).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Change,
        [Parameter(Mandatory)] [string[]]       $ReadOnlyGlobals,
        [Parameter(Mandatory)] [string[]]       $SystemPatterns
    )

    if (Test-MatchesAnyPattern -Value $Change.resourceName      -Patterns $SystemPatterns) {
        return "system-managed-name:$($Change.resourceName)"
    }
    if (Test-MatchesAnyPattern -Value $Change.resourceGroupName -Patterns $SystemPatterns) {
        return "system-managed-rg:$($Change.resourceGroupName)"
    }

    $changed = @($Change.changedProperties)
    if ($changed.Count -gt 0 -and $ReadOnlyGlobals.Count -gt 0) {
        $allReadOnly = $true
        foreach ($path in $changed) {
            $leaf = $path
            # Strip a single leading "properties." prefix so paths like
            # "properties.provisioningState" match against the bare global
            # list. Anything deeper (e.g. "properties.subnets[0].properties.foo")
            # never matches and forces a keep.
            if ($leaf -is [string] -and $leaf.StartsWith('properties.')) {
                $leaf = $leaf.Substring('properties.'.Length)
            }
            if ($ReadOnlyGlobals -notcontains $leaf) { $allReadOnly = $false; break }
        }
        if ($allReadOnly) { return "readonly-only" }
    }

    return $null
}

function Group-ChangesByResourceId {
    <#
    .SYNOPSIS
    Coalesce multiple changes against the same `targetResourceId` into one
    entry, keeping the row with the latest `timestamp`.

    .DESCRIPTION
    Ties (equal timestamps) are broken deterministically by stable input
    order — earlier entries lose to later ones in the input stream, which
    matches the descending-timestamp KQL ordering.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Group-ChangesByResourceId operates on a collection; plural is intentional.')]
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]] $Changes
    )
    $byId = [ordered]@{}
    foreach ($c in $Changes) {
        $key = [string]$c.targetResourceId
        if (-not $byId.Contains($key)) {
            $byId[$key] = $c
            continue
        }
        $existing = $byId[$key]
        $a = $existing.timestamp
        $b = $c.timestamp
        $aDate = [DateTime]::MinValue; $bDate = [DateTime]::MinValue
        $aOk = ($a -is [string]) -and [DateTime]::TryParse($a, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
            [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$aDate)
        $bOk = ($b -is [string]) -and [DateTime]::TryParse($b, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
            [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$bDate)
        if ($aOk -and $bOk) {
            if ($bDate -gt $aDate) { $byId[$key] = $c }
        }
        elseif ($bOk -and -not $aOk) {
            $byId[$key] = $c
        }
        # else: keep the existing entry (deterministic).
    }
    return @($byId.Values)
}

function Invoke-ResourceGraphQuery {
    <#
    .SYNOPSIS
    Runs the KQL against the live `az graph query` CLI and returns the parsed
    result list.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Kql
    )
    $args1 = @(
        'graph', 'query',
        '--graph-query', $Kql,
        '--first', '1000',
        '--output', 'json'
    )
    $raw = & az @args1 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        throw "az graph query failed with exit ${exit}: $($raw | Out-String)"
    }
    $joined = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return @() }
    $parsed = $joined | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    if (Test-HasProperty $parsed 'data') { return @($parsed.data) }
    if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        return @($parsed)
    }
    return @($parsed)
}

# ── Main ─────────────────────────────────────────────────────────────────────

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$null = New-Item -ItemType Directory -Force -Path $OutputDir

Write-Host "============================================================"
Write-Host "STAGE 8 (R3.2): Find Portal Changes"
Write-Host "  Run ID:         $RunId"
Write-Host "  Lookback hours: $LookbackHours"
Write-Host "  Output dir:     $OutputDir"
Write-Host "  DryRun:         $($DryRun.IsPresent)"
if ($DryRun) { Write-Host "  Fixture file:   $FixtureFile" }
Write-Host "============================================================"

# 1. Acquire the raw rows (live or fixture).
$rawRows = @()
if ($DryRun) {
    if ([string]::IsNullOrEmpty($FixtureFile)) {
        throw "-DryRun requires -FixtureFile <path>."
    }
    if (-not (Test-Path $FixtureFile)) {
        throw "Fixture file not found: $FixtureFile"
    }
    Write-Host "  Loading fixture: $FixtureFile"
    $rawRaw = Get-Content $FixtureFile -Raw | ConvertFrom-Json
    if ($null -eq $rawRaw) {
        $rawRows = @()
    }
    elseif ($rawRaw -is [System.Collections.IEnumerable] -and $rawRaw -isnot [string]) {
        $rawRows = @($rawRaw)
    }
    else {
        $rawRows = @($rawRaw)
    }
} else {
    $kql = $Script:KqlTemplate -f $LookbackHours
    Write-Host "  Submitting KQL ($($kql.Length) chars) to az graph query..."
    $rawRows = @(Invoke-ResourceGraphQuery -Kql $kql)
}

Write-Host "  Raw rows received: $($rawRows.Count)"

# 2. Normalise + count malformed rows.
$normalised = [System.Collections.Generic.List[PSCustomObject]]::new()
$malformed = 0
foreach ($row in $rawRows) {
    $n = ConvertTo-NormalisedChange -Row $row
    if ($null -eq $n) { $malformed++; continue }
    $normalised.Add($n)
}
Write-Host "  Normalised rows:   $($normalised.Count)  (malformed skipped: $malformed)"

# 3. Coalesce by targetResourceId BEFORE applying skip rules. Coalescing first
#    means a kept-resource's "latest" snapshot drives the keep/skip decision,
#    matching the operator's mental model ("did the resource still need a
#    sync, considering its most recent change?").
$coalesced = @(Group-ChangesByResourceId -Changes (@($normalised)))
Write-Host "  After coalescing:  $($coalesced.Count)"

# 4. Apply skip rules.
$readOnlyGlobals = Read-ReadOnlyGlobalList -RepoRoot $RepoRoot
$kept    = [System.Collections.Generic.List[PSCustomObject]]::new()
$skipped = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($c in $coalesced) {
    $reason = Get-SkipReason -Change $c -ReadOnlyGlobals $readOnlyGlobals -SystemPatterns $Script:SystemManagedPatterns
    if ($null -ne $reason) {
        $c.skipReason = $reason
        $skipped.Add($c)
    } else {
        $kept.Add($c)
    }
}

# 5. Stable sort for byte-identical output across re-runs.
$keptSorted    = @($kept    | Sort-Object -Property timestamp, targetResourceId)
$skippedSorted = @($skipped | Sort-Object -Property timestamp, targetResourceId)

# 6. Write outputs.
$keptPath    = Join-Path $OutputDir 'portal-changes.json'
$skippedPath = Join-Path $OutputDir 'portal-changes-skipped.json'
$summaryPath = Join-Path $OutputDir 'portal-changes-summary.json'

# Pipeline form (NOT -InputObject): with -InputObject, ConvertTo-Json sees the
# whole array as ONE input object and -AsArray then wraps it again, producing a
# nested `[[…]]` JSON. Piping each entry separately + -AsArray yields a single
# top-level array even for 0 items.
($keptSorted    | ConvertTo-Json -Depth 30 -AsArray) | Set-Content $keptPath    -Encoding UTF8
($skippedSorted | ConvertTo-Json -Depth 30 -AsArray) | Set-Content $skippedPath -Encoding UTF8

# Skip-reason breakdown — prefix-grouped so unique-per-resource reasons don't
# explode the histogram.
$breakdown = [ordered]@{}
foreach ($s in $skippedSorted) {
    $r = [string]$s.skipReason
    $bucket = if ($r -match '^([^:]+):') { $Matches[1] } else { $r }
    if (-not $breakdown.Contains($bucket)) { $breakdown[$bucket] = 0 }
    $breakdown[$bucket]++
}

$summary = [ordered]@{
    runId         = $RunId
    timestamp     = $Timestamp
    lookbackHours = $LookbackHours
    dryRun        = [bool]$DryRun.IsPresent
    totalSeen     = $rawRows.Count
    malformed     = $malformed
    afterCoalesce = $coalesced.Count
    totalKept     = $keptSorted.Count
    totalSkipped  = $skippedSorted.Count
    skipBreakdown = $breakdown
}
$summary | ConvertTo-Json -Depth 30 | Set-Content $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "PORTAL CHANGES  Seen: $($rawRows.Count)  Kept: $($keptSorted.Count)  Skipped: $($skippedSorted.Count)  Malformed: $malformed"
Write-Host "  $keptPath"
Write-Host "  $skippedPath"
Write-Host "  $summaryPath"
