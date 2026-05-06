#Requires -Version 7.2
# =============================================================================
# tests/round-3/Test-FindPortalChanges.ps1
# Round 3.2 unit/smoke test for scripts/sync/Find-PortalChanges.ps1.
#
# Strategy:
#   The script's -DryRun + -FixtureFile seam lets us run the entire pipeline
#   (normalise -> coalesce -> filter -> emit) against hand-rolled JSON fixtures
#   without any az CLI dependency. We use two fixtures:
#
#     fixtures/portal-changes/mixed.json
#       Mix of: 3 changes against the same vnet (coalescing case),
#       a readonly-only storage account (skip-by-readonly),
#       a NetworkWatcher_westeurope (skip-by-name),
#       an AzureBackupRG_* RG entry (skip-by-rg-name),
#       and one plain Web/sites change (kept).
#
#     fixtures/portal-changes/malformed.json
#       One good row + one row missing targetResourceId — the latter must be
#       counted as `malformed` and not crash the run.
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Script   = Join-Path $RepoRoot 'scripts/sync/Find-PortalChanges.ps1'
$FixtureRoot = Join-Path $RepoRoot 'tests/fixtures/portal-changes'

$Failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $Failures.Add("[FAIL] $Message") }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        $Failures.Add("[FAIL] $Message`n         expected: $Expected`n         actual:   $Actual")
    }
}

function New-Workdir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper that creates a temp dir; ShouldProcess would clutter the assertion log.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $w = Join-Path $env:TEMP "draac-find-portal-test-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Force -Path $w
    return $w
}

$Workdirs = [System.Collections.Generic.List[string]]::new()

try {
    # ── 1. Mixed fixture: end-to-end pipeline ────────────────────────────────
    Write-Host "── Find-PortalChanges -DryRun  (mixed fixture) ──"
    $mixedFixture = Join-Path $FixtureRoot 'mixed.json'
    Assert-True (Test-Path $mixedFixture) 'mixed.json fixture exists on disk'

    $w1 = New-Workdir; $Workdirs.Add($w1)
    & $Script `
        -OutputDir $w1 `
        -RunId 'r3-2-mixed-001' `
        -LookbackHours 24 `
        -DryRun `
        -FixtureFile $mixedFixture | Out-Null

    $keptPath    = Join-Path $w1 'portal-changes.json'
    $skippedPath = Join-Path $w1 'portal-changes-skipped.json'
    $summaryPath = Join-Path $w1 'portal-changes-summary.json'

    Assert-True (Test-Path $keptPath)    'portal-changes.json written'
    Assert-True (Test-Path $skippedPath) 'portal-changes-skipped.json written'
    Assert-True (Test-Path $summaryPath) 'portal-changes-summary.json written'

    $kept    = @(Get-Content $keptPath    -Raw | ConvertFrom-Json)
    $skipped = @(Get-Content $skippedPath -Raw | ConvertFrom-Json)
    $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json

    # Mixed fixture has 7 raw rows. After coalescing the 3 vnet-x rows into 1
    # we have 5 unique resources. Two are skipped (NetworkWatcher_*, AzureBackupRG_*),
    # one is skipped-by-readonly (storage account, only `provisioningState`),
    # which leaves 2 kept (vnet-x and app-public).
    Assert-Equal 7  $summary.totalSeen      'summary.totalSeen == 7'
    Assert-Equal 5  $summary.afterCoalesce  'summary.afterCoalesce == 5  (3 vnet-x rows collapsed to 1)'
    Assert-Equal 2  $summary.totalKept      'summary.totalKept == 2'
    Assert-Equal 3  $summary.totalSkipped   'summary.totalSkipped == 3'
    Assert-Equal 'r3-2-mixed-001' $summary.runId 'summary.runId echoed'

    # Coalescing: vnet-x must appear exactly once with the LATEST timestamp.
    # Note: PS 7.5+ ConvertFrom-Json auto-converts ISO 8601 strings to [DateTime].
    # Normalise both sides to ISO before compare so the assertion is version-portable.
    $vnetEntries = @($kept | Where-Object { $_.resourceName -eq 'vnet-x' })
    Assert-Equal 1 $vnetEntries.Count 'vnet-x coalesced to a single kept entry'
    if ($vnetEntries.Count -eq 1) {
        $tsActual = if ($vnetEntries[0].timestamp -is [DateTime]) {
            $vnetEntries[0].timestamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } else {
            [string]$vnetEntries[0].timestamp
        }
        Assert-Equal '2026-05-04T12:34:56Z' $tsActual                    'vnet-x kept latest timestamp'
        Assert-Equal 'bob@example.com'      $vnetEntries[0].changedBy   'vnet-x kept latest changedBy'
    }

    # Skip-by-name: NetworkWatcher_westeurope appears in the SKIPPED list.
    $nwSkipped = @($skipped | Where-Object { $_.resourceName -eq 'NetworkWatcher_westeurope' })
    Assert-Equal 1 $nwSkipped.Count 'NetworkWatcher_westeurope is in skipped list'
    if ($nwSkipped.Count -eq 1) {
        Assert-True ([string]$nwSkipped[0].skipReason -like 'system-managed-*') `
            'NetworkWatcher skip reason is system-managed-*'
    }
    # ...and is NOT in the kept list.
    $nwKept = @($kept | Where-Object { $_.resourceName -eq 'NetworkWatcher_westeurope' })
    Assert-Equal 0 $nwKept.Count 'NetworkWatcher_westeurope is NOT in kept list'

    # Skip-by-rg-name: AzureBackupRG_westeurope_1 entry is skipped.
    $backup = @($skipped | Where-Object { $_.resourceGroupName -eq 'AzureBackupRG_westeurope_1' })
    Assert-Equal 1 $backup.Count 'AzureBackupRG_* RG entry is skipped'

    # Skip-by-readonly: the storage account whose only changedProperty is
    # `provisioningState` (in data/readonly-properties.json's global list).
    $stRow = @($skipped | Where-Object { $_.resourceName -eq 'staccounted' })
    Assert-Equal 1 $stRow.Count 'storage account with only provisioningState is skipped'
    if ($stRow.Count -eq 1) {
        Assert-Equal 'readonly-only' $stRow[0].skipReason 'skip reason is readonly-only'
    }
    # ...and the kept list never carries a non-null skipReason.
    $keptWithReason = @($kept | Where-Object { $null -ne $_.skipReason })
    Assert-Equal 0 $keptWithReason.Count 'every kept entry has skipReason: null'

    # ── 2. Idempotency: same fixture -> byte-identical portal-changes.json ──
    Write-Host "── idempotency: re-run with the same fixture ──"
    $w2 = New-Workdir; $Workdirs.Add($w2)
    & $Script `
        -OutputDir $w2 `
        -RunId 'r3-2-mixed-002' `
        -LookbackHours 24 `
        -DryRun `
        -FixtureFile $mixedFixture | Out-Null

    $h1 = Get-FileHash -Path (Join-Path $w1 'portal-changes.json')         -Algorithm SHA256
    $h2 = Get-FileHash -Path (Join-Path $w2 'portal-changes.json')         -Algorithm SHA256
    Assert-Equal $h1.Hash $h2.Hash 'portal-changes.json is byte-identical across runs'

    $hs1 = Get-FileHash -Path (Join-Path $w1 'portal-changes-skipped.json') -Algorithm SHA256
    $hs2 = Get-FileHash -Path (Join-Path $w2 'portal-changes-skipped.json') -Algorithm SHA256
    Assert-Equal $hs1.Hash $hs2.Hash 'portal-changes-skipped.json is byte-identical across runs'

    # ── 3. Malformed-record fault tolerance ─────────────────────────────────
    Write-Host "── malformed fixture: bad row counted, not fatal ──"
    $malformedFixture = Join-Path $FixtureRoot 'malformed.json'
    Assert-True (Test-Path $malformedFixture) 'malformed.json fixture exists on disk'

    $w3 = New-Workdir; $Workdirs.Add($w3)
    & $Script `
        -OutputDir $w3 `
        -RunId 'r3-2-malformed-001' `
        -LookbackHours 24 `
        -DryRun `
        -FixtureFile $malformedFixture | Out-Null

    $sumM = Get-Content (Join-Path $w3 'portal-changes-summary.json') -Raw | ConvertFrom-Json
    Assert-Equal 2 $sumM.totalSeen 'malformed run sees both rows'
    Assert-Equal 1 $sumM.malformed 'malformed row is counted'
    Assert-Equal 1 $sumM.totalKept 'one good row is kept'

    # ── 4. -DryRun without -FixtureFile must throw ──────────────────────────
    Write-Host "── -DryRun without -FixtureFile rejects ──"
    $w4 = New-Workdir; $Workdirs.Add($w4)
    $rejected = $false
    try {
        & $Script -OutputDir $w4 -RunId 'r3-2-no-fixture' -DryRun | Out-Null
        if ($LASTEXITCODE -ne 0) { $rejected = $true }
    }
    catch { $rejected = $true }
    # The script throws via the dot-sourced child's terminating error.
    # If the call returns without an exception we still expect no output files.
    if (-not $rejected) {
        $rejected = -not (Test-Path (Join-Path $w4 'portal-changes.json'))
    }
    Assert-True $rejected '-DryRun without -FixtureFile does not silently produce output'
}
finally {
    foreach ($w in $Workdirs) {
        if (Test-Path $w) { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue }
    }
}

if ($Failures.Count -eq 0) {
    Write-Host ""
    Write-Host "Test-FindPortalChanges: all assertions passed."
    exit 0
} else {
    Write-Host ""
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
