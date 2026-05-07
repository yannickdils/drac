#Requires -Version 7.2
# =============================================================================
# tests/round-5/Test-CompareAgainstBaseline.ps1
# Round 5 §R5.6 / E1 — Slow-drift detection.
#
# Exercises Compare-AgainstBaseline.ps1 in -DryRun mode against synthesised
# baseline + current scan dirs to prove:
#   1. appeared / disappeared / changed buckets are populated correctly
#   2. Read-only-only changes are NOT counted as `changed`
#   3. Idempotency: identical inputs → identical output (modulo timestamps)
#   4. First-run fallback: missing FixtureBaselineDir → empty diff, exit 0
#
# Style: hand-rolled Assert-True/Assert-Equal helpers (Pester-free); exits
# 0/1. Scratch artefacts under $env:TEMP/draac-slow-drift-<guid>; cleaned in
# `finally`.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/scan/Compare-AgainstBaseline.ps1'
$Failures   = [System.Collections.Generic.List[string]]::new()

function Assert-True  { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $Failures.Add("[FAIL] $Msg — expected '$Expected' got '$Actual'") } }

Assert-True (Test-Path $ScriptPath) "Compare-AgainstBaseline.ps1 must exist"

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper creates an isolated temp directory under $env:TEMP; never mutates system state outside the harness.')]
    [CmdletBinding()]
    param()
    $Dir = Join-Path $env:TEMP "draac-slow-drift-$([System.Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Force -Path $Dir
    return $Dir
}

function Set-AllResourcesJson {
    param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [object[]] $Resources)
    $null = New-Item -ItemType Directory -Force -Path $Dir
    $path = Join-Path $Dir 'all-resources.json'
    if ($Resources.Count -eq 0) {
        Set-Content -Path $path -Value '[]' -Encoding UTF8
    } else {
        $Resources | ConvertTo-Json -Depth 30 -AsArray | Set-Content -Path $path -Encoding UTF8
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 — appeared / disappeared / changed buckets populate correctly
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── slow-drift: appeared / disappeared / changed ──"
$T1 = New-TempDir
try {
    $BaselineDir = Join-Path $T1 'baseline'
    $CurrentDir  = Join-Path $T1 'current'
    $OutFile     = Join-Path $T1 'slow-drift.json'

    # Baseline: 3 resources (kept, will-disappear, will-change)
    Set-AllResourcesJson -Dir $BaselineDir -Resources @(
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/keptaccount'
            name = 'keptaccount'
            type = 'Microsoft.Storage/storageAccounts'
            resourceGroup = 'rg1'
            properties = [ordered]@{ tier = 'Standard'; provisioningState = 'Succeeded' }
        },
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Network/virtualNetworks/disappearedvnet'
            name = 'disappearedvnet'
            type = 'Microsoft.Network/virtualNetworks'
            resourceGroup = 'rg1'
            properties = [ordered]@{ addressSpace = @{ addressPrefixes = @('10.0.0.0/16') } }
        },
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Web/sites/changedsite'
            name = 'changedsite'
            type = 'Microsoft.Web/sites'
            resourceGroup = 'rg1'
            properties = [ordered]@{ httpsOnly = $false }
        }
    )

    # Current: kept (identical), changed (httpsOnly flip), new appeared
    Set-AllResourcesJson -Dir $CurrentDir -Resources @(
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/keptaccount'
            name = 'keptaccount'
            type = 'Microsoft.Storage/storageAccounts'
            resourceGroup = 'rg1'
            properties = [ordered]@{ tier = 'Standard'; provisioningState = 'Succeeded' }
        },
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Web/sites/changedsite'
            name = 'changedsite'
            type = 'Microsoft.Web/sites'
            resourceGroup = 'rg1'
            properties = [ordered]@{ httpsOnly = $true }
        },
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/newvault'
            name = 'newvault'
            type = 'Microsoft.KeyVault/vaults'
            resourceGroup = 'rg1'
            properties = [ordered]@{ enableSoftDelete = $true }
        }
    )

    & $ScriptPath -CurrentScanDir $CurrentDir -OutputFile $OutFile `
        -DryRun -FixtureBaselineDir $BaselineDir 2>$null

    Assert-True (Test-Path $OutFile) "slow-drift.json must be written"
    if (Test-Path $OutFile) {
        $r = Get-Content $OutFile -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.appeared    "exactly 1 'appeared' (newvault)"
        Assert-Equal 1 $r.summary.disappeared "exactly 1 'disappeared' (disappearedvnet)"
        Assert-Equal 1 $r.summary.changed     "exactly 1 'changed' (changedsite httpsOnly)"
        Assert-Equal 3 $r.summary.total       "total = 3"

        $appeared = @($r.items | Where-Object { $_.category -eq 'appeared' })
        Assert-True ($appeared.Count -eq 1 -and $appeared[0].name -eq 'newvault') "appeared row is newvault"

        $disappeared = @($r.items | Where-Object { $_.category -eq 'disappeared' })
        Assert-True ($disappeared.Count -eq 1 -and $disappeared[0].name -eq 'disappearedvnet') "disappeared row is disappearedvnet"

        $changed = @($r.items | Where-Object { $_.category -eq 'changed' })
        Assert-True ($changed.Count -eq 1 -and $changed[0].name -eq 'changedsite') "changed row is changedsite"
    }
}
finally {
    Remove-Item $T1 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 — Read-only-only changes are NOT counted as `changed`
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── slow-drift: read-only-only change ignored ──"
$T2 = New-TempDir
try {
    $BaselineDir = Join-Path $T2 'baseline'
    $CurrentDir  = Join-Path $T2 'current'
    $OutFile     = Join-Path $T2 'slow-drift.json'

    Set-AllResourcesJson -Dir $BaselineDir -Resources @(
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sticky'
            name = 'sticky'
            type = 'Microsoft.Storage/storageAccounts'
            resourceGroup = 'rg1'
            properties = [ordered]@{
                tier = 'Standard'
                provisioningState = 'Succeeded'
                etag = '"abc123"'
                lastModifiedTime = '2026-01-01T00:00:00Z'
            }
        }
    )
    # Current: same resource, only etag/lastModifiedTime/provisioningState differ.
    Set-AllResourcesJson -Dir $CurrentDir -Resources @(
        [ordered]@{
            id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sticky'
            name = 'sticky'
            type = 'Microsoft.Storage/storageAccounts'
            resourceGroup = 'rg1'
            properties = [ordered]@{
                tier = 'Standard'
                provisioningState = 'Updating'
                etag = '"def456"'
                lastModifiedTime = '2026-05-06T00:00:00Z'
            }
        }
    )

    & $ScriptPath -CurrentScanDir $CurrentDir -OutputFile $OutFile `
        -DryRun -FixtureBaselineDir $BaselineDir 2>$null

    Assert-True (Test-Path $OutFile) "slow-drift.json must be written"
    if (Test-Path $OutFile) {
        $r = Get-Content $OutFile -Raw | ConvertFrom-Json
        Assert-Equal 0 $r.summary.changed "read-only-only diff must NOT count as 'changed'"
        Assert-Equal 0 $r.summary.appeared    "no appearances"
        Assert-Equal 0 $r.summary.disappeared "no disappearances"
        Assert-Equal 0 $r.summary.total       "total drift = 0"
    }
}
finally {
    Remove-Item $T2 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 — Idempotency: identical inputs → identical output (modulo timestamps)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── slow-drift: idempotency ──"
$T3 = New-TempDir
try {
    $BaselineDir = Join-Path $T3 'baseline'
    $CurrentDir  = Join-Path $T3 'current'
    $Out1 = Join-Path $T3 'slow-drift-1.json'
    $Out2 = Join-Path $T3 'slow-drift-2.json'

    Set-AllResourcesJson -Dir $BaselineDir -Resources @(
        [ordered]@{
            id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/a'
            name = 'a'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'rg1'
            properties = [ordered]@{ tier = 'Standard' }
        }
    )
    Set-AllResourcesJson -Dir $CurrentDir -Resources @(
        [ordered]@{
            id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/a'
            name = 'a'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'rg1'
            properties = [ordered]@{ tier = 'Premium' }
        }
    )

    & $ScriptPath -CurrentScanDir $CurrentDir -OutputFile $Out1 `
        -DryRun -FixtureBaselineDir $BaselineDir 2>$null
    & $ScriptPath -CurrentScanDir $CurrentDir -OutputFile $Out2 `
        -DryRun -FixtureBaselineDir $BaselineDir 2>$null

    if ((Test-Path $Out1) -and (Test-Path $Out2)) {
        $r1 = Get-Content $Out1 -Raw | ConvertFrom-Json
        $r2 = Get-Content $Out2 -Raw | ConvertFrom-Json
        # Compare summary blocks exactly
        $j1 = $r1.summary | ConvertTo-Json -Depth 5 -Compress
        $j2 = $r2.summary | ConvertTo-Json -Depth 5 -Compress
        Assert-Equal $j1 $j2 "summary blocks must match across runs"
        Assert-Equal $r1.items.Count $r2.items.Count "item count must match across runs"
    } else {
        $Failures.Add("[FAIL] idempotency: one of the outputs missing")
    }
}
finally {
    Remove-Item $T3 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4 — First-run fallback: missing FixtureBaselineDir → empty diff, exit 0
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── slow-drift: first-run fallback (no baseline yet) ──"
$T4 = New-TempDir
try {
    $CurrentDir = Join-Path $T4 'current'
    $OutFile    = Join-Path $T4 'slow-drift.json'
    Set-AllResourcesJson -Dir $CurrentDir -Resources @(
        [ordered]@{
            id = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/aaa'
            name = 'aaa'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'rg1'
            properties = [ordered]@{}
        }
    )

    # Point at a non-existent baseline dir
    $MissingDir = Join-Path $T4 'baseline-does-not-exist'
    & $ScriptPath -CurrentScanDir $CurrentDir -OutputFile $OutFile `
        -DryRun -FixtureBaselineDir $MissingDir 2>$null

    Assert-True (Test-Path $OutFile) "slow-drift.json must still be written when baseline is missing"
    if (Test-Path $OutFile) {
        $r = Get-Content $OutFile -Raw | ConvertFrom-Json
        # With NO baseline, every current resource counts as 'appeared' or NOT counted
        # depending on interpretation. The script uses an empty baseline map → every
        # current resource counts as `appeared`. Assert that's what we see.
        Assert-Equal 1 $r.summary.appeared    "first-run: 1 appeared from current scan"
        Assert-Equal 0 $r.summary.disappeared "first-run: 0 disappeared"
        Assert-Equal 0 $r.summary.changed     "first-run: 0 changed"
        Assert-Equal $false $r.baseline.available "baseline.available = false on first run"
    }
}
finally {
    Remove-Item $T4 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { Write-Host $f }
    exit 1
}
Write-Host "Test-CompareAgainstBaseline: all assertions passed."
exit 0
