#Requires -Version 7.2
# =============================================================================
# scripts/scan/Compare-AgainstBaseline.ps1
# Stage 9b (Round 5 §R5.6 / E1): Slow-drift detection.
#
# Pulls the most recent baseline snapshot from the storage account written by
# `.github/workflows/baseline-snapshot.yml`, diffs it against the current
# scan, and writes `slow-drift.json` capturing items that have appeared,
# disappeared, or changed since the baseline was taken.
#
# "Slow drift" is the gradual divergence that compounds over weeks of small
# portal edits, manual fixes, and undeclared resources. Stage-4 drift looks
# at the current snapshot only; this script anchors against history.
#
# Idempotent: identical inputs (same baseline, same current scan) produce
# identical output JSON modulo the `checkedAt` and `baseline.fetchedAt`
# timestamps. Re-runs are safe.
#
# Fault-tolerant: if no baseline yet exists (first run), emits an empty
# slow-drift report (`summary.total = 0`) and exits 0. Per-resource read
# failures are logged and skipped; the script never aborts mid-run.
#
# Test seam: `-DryRun -FixtureBaselineDir <path>` skips every `az` call and
# uses local files only. The fixture dir mirrors the layout that would be
# downloaded from blob storage (e.g. `<dir>/all-resources.json`).
#
# Read-only-property changes (etag, provisioningState, lastModifiedTime,
# creationTime) are NOT counted as `changed`. The list mirrors the global
# read-only set in `data/readonly-properties.json`.
#
# Azure CLI references:
#   az storage blob download:
#     https://learn.microsoft.com/cli/azure/storage/blob#az-storage-blob-download
#   az storage blob list:
#     https://learn.microsoft.com/cli/azure/storage/blob#az-storage-blob-list
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CurrentScanDir,
    [Parameter(Mandatory)] [string] $OutputFile,

    [string] $StorageAccount = $env:DRAAC_BASELINE_STORAGE_ACCOUNT,
    [string] $Container      = "draac-baseline",

    # When set, skip every `az` invocation and use $FixtureBaselineDir for inputs.
    [switch] $DryRun,

    # Local directory simulating a downloaded baseline (used with -DryRun).
    # Expected to contain `all-resources.json` from a prior scan.
    [string] $FixtureBaselineDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Test-HasProperty {
    <#
    .SYNOPSIS
    Strict-mode-safe property existence check.
    #>
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    <#
    .SYNOPSIS
    Strict-mode-safe property accessor; returns $null when missing.
    Wraps array values with the leading-comma idiom to defeat single-element
    pipeline unwrap.
    #>
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if (-not (Test-HasProperty -Object $Object -Name $Name)) { return $null }
    $val = $Object.PSObject.Properties[$Name].Value
    if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
        return , $val
    }
    return $val
}

# Properties that change with every Azure operation. Excluded from the
# `changed` comparison so portal touches that don't actually mutate config
# don't pollute the slow-drift signal. Mirrors data/readonly-properties.json.
$Script:GlobalReadOnly = @(
    'provisioningState', 'etag', 'createdDate',
    'lastModifiedTime', 'creationTime'
)

function Remove-ReadOnlyProperties {
    <#
    .SYNOPSIS
    Returns a clone of $Resource with global read-only fields stripped from
    `properties` and tag values normalised. Inputs are not mutated.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function: returns a transformed clone, no side effects.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Plural in name reflects the contract: strips a known SET of read-only properties; mirrors the equivalent helper in scripts/lib/ConvertForDR.psm1.')]
    [CmdletBinding()]
    param($Resource)

    if ($null -eq $Resource) { return $null }

    # Round-trip via JSON to detach from the original object graph.
    $clone = $Resource | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30

    if (Test-HasProperty -Object $clone -Name 'properties') {
        $props = $clone.properties
        if ($null -ne $props -and $props -is [System.Management.Automation.PSCustomObject]) {
            foreach ($name in $Script:GlobalReadOnly) {
                if (Test-HasProperty -Object $props -Name $name) {
                    $props.PSObject.Properties.Remove($name)
                }
            }
        }
    }

    return $clone
}

function Get-ResourceFingerprint {
    <#
    .SYNOPSIS
    Stable JSON-text fingerprint of a resource, with read-only properties
    stripped, used to detect "real" changes between baseline and current.
    #>
    param($Resource)
    $clean = Remove-ReadOnlyProperties -Resource $Resource
    return ($clean | ConvertTo-Json -Depth 30 -Compress)
}

function Get-ResourceMap {
    <#
    .SYNOPSIS
    Reads `all-resources.json` from a directory and returns a hashtable
    keyed by lowercase resource id. Returns an empty hashtable if missing.
    #>
    param([Parameter(Mandatory)] [string] $Dir)

    $map = @{}
    $path = Join-Path $Dir 'all-resources.json'
    if (-not (Test-Path $path)) { return $map }
    try {
        $rows = Get-Content $path -Raw | ConvertFrom-Json -Depth 30
        if ($null -eq $rows) { return $map }
        foreach ($r in @($rows)) {
            if (-not (Test-HasProperty -Object $r -Name 'id')) { continue }
            $id = [string]$r.id
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $map[$id.ToLowerInvariant()] = $r
        }
    }
    catch {
        Write-Warning "Failed to read $path : $_"
    }
    return $map
}

function Invoke-Az {
    <#
    .SYNOPSIS
    Thin wrapper over `az` returning stdout text. Throws on non-zero exit.
    DryRun never reaches this.
    #>
    param([Parameter(Mandatory)] [string[]] $ArgumentList)

    $output = & az @ArgumentList 2>&1
    $exit   = $LASTEXITCODE
    $joined = ($output | Out-String)
    if ($exit -ne 0) {
        throw "az $($ArgumentList -join ' ') failed (exit $exit): $joined"
    }
    return $joined
}

function Get-LatestBaselinePrefix {
    <#
    .SYNOPSIS
    Reads `latest.txt` from the storage container and returns the trimmed
    prefix string. Returns $null if the blob is missing (first run).
    #>
    param([string] $Account, [string] $Cont)

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("draac-latest-" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    try {
        Invoke-Az -ArgumentList @(
            'storage', 'blob', 'download',
            '--account-name', $Account,
            '--container-name', $Cont,
            '--name', 'latest.txt',
            '--file', $tmp,
            '--auth-mode', 'login',
            '--no-progress'
        ) | Out-Null
    }
    catch {
        Write-Warning "No baseline yet (couldn't fetch latest.txt): $_"
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        return $null
    }
    if (-not (Test-Path $tmp)) { return $null }
    $prefix = (Get-Content $tmp -Raw -ErrorAction SilentlyContinue)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($null -eq $prefix) { return $null }
    return $prefix.Trim()
}

function Get-BaselineDir {
    <#
    .SYNOPSIS
    Downloads every blob under <prefix>/ into a fresh temp dir and returns
    the directory path. Caller is responsible for cleanup.
    #>
    param([string] $Account, [string] $Cont, [string] $Prefix)

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("draac-baseline-" + [System.Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $dir

    Invoke-Az -ArgumentList @(
        'storage', 'blob', 'download-batch',
        '--account-name', $Account,
        '--source', $Cont,
        '--pattern', "$Prefix/*",
        '--destination', $dir,
        '--auth-mode', 'login',
        '--no-progress'
    ) | Out-Null

    # download-batch preserves the prefix; flatten to <dir>/all-resources.json.
    $nested = Join-Path $dir $Prefix
    if (Test-Path $nested) {
        Get-ChildItem -Path $nested -File | ForEach-Object {
            $dest = Join-Path $dir $_.Name
            Move-Item -Path $_.FullName -Destination $dest -Force
        }
        Remove-Item $nested -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $dir
}

# ── Banner ───────────────────────────────────────────────────────────────────

Write-Host "============================================================"
Write-Host "STAGE 9b: Compare against baseline (slow drift)"
Write-Host "  Current scan dir: $CurrentScanDir"
Write-Host "  Output:           $OutputFile"
Write-Host "  DryRun:           $DryRun"
if ($DryRun) {
    Write-Host "  FixtureBaseline:  $FixtureBaselineDir"
} else {
    Write-Host "  Storage account:  $StorageAccount"
    Write-Host "  Container:        $Container"
}
Write-Host "============================================================"

# ── Resolve baseline ─────────────────────────────────────────────────────────

$baselineDir = $null
$baselinePrefix = $null
$baselineFetchedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$cleanupDir = $null

try {
    if ($DryRun) {
        if (-not $FixtureBaselineDir) {
            Write-Warning "-DryRun set without -FixtureBaselineDir — treating baseline as empty (first-run scenario)."
            $baselineDir = $null
        }
        elseif (-not (Test-Path $FixtureBaselineDir)) {
            Write-Warning "FixtureBaselineDir not found: $FixtureBaselineDir — treating as empty baseline."
            $baselineDir = $null
        }
        else {
            $baselineDir = $FixtureBaselineDir
            $baselinePrefix = "(fixture)"
        }
    }
    else {
        if (-not $StorageAccount) {
            Write-Warning "No -StorageAccount and no \$env:DRAAC_BASELINE_STORAGE_ACCOUNT — treating baseline as empty."
        }
        else {
            $baselinePrefix = Get-LatestBaselinePrefix -Account $StorageAccount -Cont $Container
            if ($baselinePrefix) {
                Write-Host "INFO: Latest baseline prefix: $baselinePrefix"
                $baselineDir = Get-BaselineDir -Account $StorageAccount -Cont $Container -Prefix $baselinePrefix
                $cleanupDir  = $baselineDir
            }
            else {
                Write-Host "INFO: No baseline yet — first-run scenario."
            }
        }
    }

    # ── Build maps ───────────────────────────────────────────────────────────

    $currentMap  = Get-ResourceMap -Dir $CurrentScanDir
    $baselineMap = if ($baselineDir) { Get-ResourceMap -Dir $baselineDir } else { @{} }

    Write-Host "  Baseline resources: $($baselineMap.Count)"
    Write-Host "  Current resources:  $($currentMap.Count)"

    # ── Diff ─────────────────────────────────────────────────────────────────

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($key in $currentMap.Keys) {
        if (-not $baselineMap.ContainsKey($key)) {
            $cur = $currentMap[$key]
            $items.Add([ordered]@{
                id            = (Get-PropertyValue -Object $cur -Name 'id')
                type          = (Get-PropertyValue -Object $cur -Name 'type')
                name          = (Get-PropertyValue -Object $cur -Name 'name')
                resourceGroup = (Get-PropertyValue -Object $cur -Name 'resourceGroup')
                category      = 'appeared'
                details       = [ordered]@{ note = "Resource present in current scan but absent from baseline." }
            }) | Out-Null
        }
    }

    foreach ($key in $baselineMap.Keys) {
        if (-not $currentMap.ContainsKey($key)) {
            $base = $baselineMap[$key]
            $items.Add([ordered]@{
                id            = (Get-PropertyValue -Object $base -Name 'id')
                type          = (Get-PropertyValue -Object $base -Name 'type')
                name          = (Get-PropertyValue -Object $base -Name 'name')
                resourceGroup = (Get-PropertyValue -Object $base -Name 'resourceGroup')
                category      = 'disappeared'
                details       = [ordered]@{ note = "Resource present in baseline but absent from current scan." }
            }) | Out-Null
        }
    }

    foreach ($key in $currentMap.Keys) {
        if (-not $baselineMap.ContainsKey($key)) { continue }
        $cur  = $currentMap[$key]
        $base = $baselineMap[$key]
        $curPrint  = Get-ResourceFingerprint -Resource $cur
        $basePrint = Get-ResourceFingerprint -Resource $base
        if ($curPrint -ne $basePrint) {
            $items.Add([ordered]@{
                id            = (Get-PropertyValue -Object $cur -Name 'id')
                type          = (Get-PropertyValue -Object $cur -Name 'type')
                name          = (Get-PropertyValue -Object $cur -Name 'name')
                resourceGroup = (Get-PropertyValue -Object $cur -Name 'resourceGroup')
                category      = 'changed'
                details       = [ordered]@{
                    note            = "Resource configuration differs from baseline (read-only properties ignored)."
                    fingerprintSize = @{ baseline = $basePrint.Length; current = $curPrint.Length }
                }
            }) | Out-Null
        }
    }

    $appeared    = @($items | Where-Object { $_.category -eq 'appeared' }).Count
    $disappeared = @($items | Where-Object { $_.category -eq 'disappeared' }).Count
    $changed     = @($items | Where-Object { $_.category -eq 'changed' }).Count

    $checkedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $report = [ordered]@{
        baseline = [ordered]@{
            prefix     = $baselinePrefix
            fetchedAt  = $baselineFetchedAt
            available  = ($null -ne $baselineDir)
        }
        current  = [ordered]@{
            scanDir   = $CurrentScanDir
            scannedAt = $checkedAt
        }
        summary  = [ordered]@{
            appeared    = $appeared
            disappeared = $disappeared
            changed     = $changed
            total       = $items.Count
        }
        items = @($items)
    }

    # Ensure output dir exists.
    $outDir = Split-Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path $outDir)) {
        $null = New-Item -ItemType Directory -Force -Path $outDir
    }

    $report | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputFile -Encoding UTF8

    Write-Host ""
    Write-Host "SLOW DRIFT COMPLETE  Total: $($items.Count)  Appeared: $appeared  Disappeared: $disappeared  Changed: $changed"
    Write-Host "  Report: $OutputFile"

    if ($env:GITHUB_OUTPUT) {
        $okStr = if ($items.Count -eq 0) { 'true' } else { 'false' }
        Add-Content -Path $env:GITHUB_OUTPUT -Value ("SLOW_DRIFT_OK={0}" -f $okStr)
        Add-Content -Path $env:GITHUB_OUTPUT -Value ("SLOW_DRIFT_TOTAL={0}" -f $items.Count)
    }
}
finally {
    if ($cleanupDir -and (Test-Path $cleanupDir)) {
        Remove-Item $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
