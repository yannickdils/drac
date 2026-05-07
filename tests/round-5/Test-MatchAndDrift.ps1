#Requires -Version 7.2
# =============================================================================
# tests/round-5/Test-MatchAndDrift.ps1
# Round 5 §R5.3 + §R5.4 — compile-then-match and (name,type) tuple tests.
#
# Set A: match-code-to-deployed.ps1
#   A1 — ARM fixture with matching type → status "all-deployed"
#   A2 — ARM fixture where name matches but type does NOT → status "not-deployed"
#
# Set B: detect-drift.ps1
#   B1 — bicep regex-fallback (no az CLI) + scan match → 0 drift items
#   B2 — scan resource with no code match → 1 deployed-not-in-code drift item
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot    = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$MatchScript = Join-Path $RepoRoot 'scripts/review/match-code-to-deployed.ps1'
$DriftScript = Join-Path $RepoRoot 'scripts/drift/detect-drift.ps1'

$Failures = [System.Collections.Generic.List[string]]::new()
function Assert-True  { param([bool] $Cond, [string] $Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Exp, $Act, [string] $Msg) if ($Exp -ne $Act) { $Failures.Add("[FAIL] $Msg`n         expected: $Exp`n         actual:   $Act") } }

# ---------------------------------------------------------------------------
# SET A — match-code-to-deployed.ps1
# ---------------------------------------------------------------------------
$TmpA = Join-Path $env:TEMP "draac-match-$([guid]::NewGuid().ToString('N'))"
try {
    $ScanDirA   = Join-Path $TmpA 'scan'
    $IaCDirA    = Join-Path $TmpA 'iac'
    $OutDirA1   = Join-Path $TmpA 'out1'
    $OutDirA2   = Join-Path $TmpA 'out2'
    foreach ($d in @($ScanDirA, $IaCDirA, $OutDirA1, $OutDirA2)) {
        $null = New-Item -ItemType Directory -Force -Path $d
    }

    # Synthetic scan: two resources
    @(
        @{ name = 'storage-prod'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'rg-prod'; subscriptionId = 'sub1'; location = 'westeurope' }
        @{ name = 'kv-prod';     type = 'Microsoft.KeyVault/vaults';         resourceGroup = 'rg-prod'; subscriptionId = 'sub1'; location = 'westeurope' }
    ) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -Path (Join-Path $ScanDirA 'all-resources.json') -Encoding UTF8

    # A1: ARM template with correct type → should match ─────────────────────
    $ArmFileA1 = Join-Path $IaCDirA 'storage.json'
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources      = @(
            [ordered]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2023-05-01'; name = 'storage-prod'; location = '[resourceGroup().location]' }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $ArmFileA1 -Encoding UTF8

    @([ordered]@{ path = $ArmFileA1; category = 'arm-template'; resourceGroupHint = 'rg-prod' }) |
        ConvertTo-Json -Depth 5 -AsArray | Set-Content -Path (Join-Path $TmpA 'changes-a1.json') -Encoding UTF8

    & $MatchScript -PrChangesFile (Join-Path $TmpA 'changes-a1.json') -ScanDir $ScanDirA -OutputDir $OutDirA1 -RunId 'test-a1'

    $RptA1 = Join-Path $OutDirA1 'deployment-match-report.json'
    Assert-True (Test-Path $RptA1) 'A1: deployment-match-report.json created'
    if (Test-Path $RptA1) {
        $rpt = Get-Content $RptA1 -Raw | ConvertFrom-Json
        Assert-Equal 1   $rpt.summary.matched   'A1: summary.matched = 1'
        Assert-Equal 0   $rpt.summary.unmatched 'A1: summary.unmatched = 0'
        Assert-Equal 'all-deployed' $rpt.results[0].status 'A1: status = all-deployed'
    }

    # A2: ARM template with WRONG type (Compute/VM) — tuple mismatch ─────────
    $ArmFileA2 = Join-Path $IaCDirA 'vm.json'
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources      = @(
            [ordered]@{ type = 'Microsoft.Compute/virtualMachines'; apiVersion = '2024-03-01'; name = 'storage-prod'; location = '[resourceGroup().location]' }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $ArmFileA2 -Encoding UTF8

    @([ordered]@{ path = $ArmFileA2; category = 'arm-template'; resourceGroupHint = 'rg-prod' }) |
        ConvertTo-Json -Depth 5 -AsArray | Set-Content -Path (Join-Path $TmpA 'changes-a2.json') -Encoding UTF8

    & $MatchScript -PrChangesFile (Join-Path $TmpA 'changes-a2.json') -ScanDir $ScanDirA -OutputDir $OutDirA2 -RunId 'test-a2'

    $RptA2 = Join-Path $OutDirA2 'deployment-match-report.json'
    Assert-True (Test-Path $RptA2) 'A2: deployment-match-report.json created'
    if (Test-Path $RptA2) {
        $rpt2 = Get-Content $RptA2 -Raw | ConvertFrom-Json
        # Name matches but type (Compute/VM) differs from scan (Storage) → not-deployed
        Assert-Equal 'not-deployed' $rpt2.results[0].status 'A2: tuple-mismatch → status = not-deployed'
        Assert-Equal 0 $rpt2.summary.matched 'A2: matched = 0 on type mismatch'
    }

} finally {
    Remove-Item -Path $TmpA -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# SET B — detect-drift.ps1
# ---------------------------------------------------------------------------
$TmpB = Join-Path $env:TEMP "draac-drift-$([guid]::NewGuid().ToString('N'))"
try {
    $ScanDirB1   = Join-Path $TmpB 'scan1'
    $ReviewDirB1 = Join-Path $TmpB 'review1'
    $OutDirB1    = Join-Path $TmpB 'out1'
    $RepoB1      = Join-Path $TmpB 'repo1'
    $BicepDirB1  = Join-Path $RepoB1 'infra'
    $ScanDirB2   = Join-Path $TmpB 'scan2'
    $ReviewDirB2 = Join-Path $TmpB 'review2'
    $OutDirB2    = Join-Path $TmpB 'out2'
    $RepoB2      = Join-Path $TmpB 'repo2'
    foreach ($d in @($ScanDirB1, $ReviewDirB1, $OutDirB1, $RepoB1, $BicepDirB1,
                      $ScanDirB2, $ReviewDirB2, $OutDirB2, $RepoB2)) {
        $null = New-Item -ItemType Directory -Force -Path $d
    }

    # B1: resource in Azure + bicep regex fallback (no az CLI) → 0 drift ─────
    @([ordered]@{ name = 'storage-prod'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'rg-prod'; subscriptionId = 'sub1'; location = 'westeurope' }) |
        ConvertTo-Json -Depth 5 -AsArray | Set-Content -Path (Join-Path $ScanDirB1 'all-resources.json') -Encoding UTF8

    # Bicep file — name present, no az CLI so regex fallback gives type=''
    # Keep flat structure to avoid sub-properties like sku.name matching the name: regex
    @"
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'storage-prod'
  location: 'westeurope'
  kind: 'StorageV2'
}
"@ | Set-Content -Path (Join-Path $BicepDirB1 'storage.bicep') -Encoding UTF8

    & $DriftScript -ScanDir $ScanDirB1 -ReviewDir $ReviewDirB1 -RepoRoot $RepoB1 `
        -OutputDir $OutDirB1 -RunId 'test-b1' -PrId 'pr-001' -PrSourceBranch 'feature/test'

    $DriftRptB1 = Join-Path $OutDirB1 'drift-report.json'
    Assert-True (Test-Path $DriftRptB1) 'B1: drift-report.json created'
    if (Test-Path $DriftRptB1) {
        $drpt = Get-Content $DriftRptB1 -Raw | ConvertFrom-Json
        # Regex fallback gives type=''; name-only match finds storage-prod in Azure → 0 drift
        Assert-Equal 0 $drpt.summary.totalDriftItems 'B1: 0 drift (storage-prod matches via name-only fallback)'
    }

    # B2: orphaned resource in Azure (no code match) → 1 deployed-not-in-code ─
    @([ordered]@{ name = 'orphaned-vm'; type = 'Microsoft.Compute/virtualMachines'; resourceGroup = 'rg-prod'; subscriptionId = 'sub1'; location = 'westeurope' }) |
        ConvertTo-Json -Depth 5 -AsArray | Set-Content -Path (Join-Path $ScanDirB2 'all-resources.json') -Encoding UTF8
    # Empty repo — no IaC files

    & $DriftScript -ScanDir $ScanDirB2 -ReviewDir $ReviewDirB2 -RepoRoot $RepoB2 `
        -OutputDir $OutDirB2 -RunId 'test-b2' -PrId 'pr-002' -PrSourceBranch 'feature/test'

    $DriftRptB2 = Join-Path $OutDirB2 'drift-report.json'
    Assert-True (Test-Path $DriftRptB2) 'B2: drift-report.json created'
    if (Test-Path $DriftRptB2) {
        $drpt2 = Get-Content $DriftRptB2 -Raw | ConvertFrom-Json
        Assert-Equal 1 $drpt2.summary.totalDriftItems 'B2: 1 drift item (orphaned-vm not in code)'
        Assert-Equal 'deployed-not-in-code' $drpt2.driftItems[0].driftType 'B2: driftType = deployed-not-in-code'
        Assert-Equal 'orphaned-vm'          $drpt2.driftItems[0].resourceName 'B2: resourceName = orphaned-vm'
    }

} finally {
    Remove-Item -Path $TmpB -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { Write-Host $f }
    exit 1
}
Write-Host "Test-MatchAndDrift: all assertions passed."
exit 0