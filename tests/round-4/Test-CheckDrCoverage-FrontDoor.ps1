#Requires -Version 7.2
# =============================================================================
# tests/round-4/Test-CheckDrCoverage-FrontDoor.ps1
# Round 4 §R4.3 — public-facing-workload Front Door gate.
#
# Scenarios:
#   1. Public-facing primary (Microsoft.Web/sites) with a DR companion that
#      DOES reference dr-traffic.bicep → coverage ok.
#   2. Same primary with a DR companion that does NOT reference
#      dr-traffic.bicep → coverage failed, exit 1.
#   3. Non-public-facing primary (Storage Account) with a companion that
#      doesn't reference dr-traffic.bicep → coverage ok (gate is a no-op).
#
# All scenarios use a self-contained mini-repo per New-TestRepo so the live
# working tree is never mutated.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/review/check-dr-coverage.ps1'

$Failures = [System.Collections.Generic.List[string]]::new()
function Assert-True  { param([bool] $Cond, [string] $Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Exp, $Act, [string] $Msg) if ($Exp -ne $Act) { $Failures.Add("[FAIL] $Msg`n         expected: $Exp`n         actual:   $Act") } }

function New-PrChangesFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes to a per-test temp directory under $env:TEMP; system state outside the harness is unaffected.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [string[]] $Paths = @())
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Paths) {
        $entries.Add([PSCustomObject]@{
            status = 'M'; path = $p; category = 'bicep'; resourceGroupHint = ''
        })
    }
    $json = if ($entries.Count -eq 0) { '[]' } else { $entries.ToArray() | ConvertTo-Json -Depth 5 -AsArray }
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function New-TestRepo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper builds a self-contained mini-repo in $env:TEMP; never mutates the live working tree.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)

    $primaryDir = Join-Path $Root 'bicep/regions/primary'
    $drDir      = Join-Path $Root 'bicep/regions/dr'
    $modulesDir = Join-Path $Root 'bicep/modules'
    $libDir     = Join-Path $Root 'scripts/lib'
    $reviewDir  = Join-Path $Root 'scripts/review'
    $dataDir    = Join-Path $Root 'data'
    foreach ($d in @($primaryDir, $drDir, $modulesDir, $libDir, $reviewDir, $dataDir)) {
        $null = New-Item -ItemType Directory -Force -Path $d
    }

    Copy-Item (Join-Path $RepoRoot 'scripts/review/check-dr-coverage.ps1') (Join-Path $reviewDir 'check-dr-coverage.ps1') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1')        (Join-Path $libDir    'ConvertForDR.psm1')     -Force
    Copy-Item (Join-Path $RepoRoot 'scripts/lib/CommitBack.psm1')          (Join-Path $libDir    'CommitBack.psm1')       -Force
    Copy-Item (Join-Path $RepoRoot 'data/reserved-names.json')             (Join-Path $dataDir   'reserved-names.json')   -Force
    Copy-Item (Join-Path $RepoRoot 'data/readonly-properties.json')        (Join-Path $dataDir   'readonly-properties.json') -Force
    if (Test-Path (Join-Path $RepoRoot 'data/dr-module-registry.json')) {
        Copy-Item (Join-Path $RepoRoot 'data/dr-module-registry.json')     (Join-Path $dataDir   'dr-module-registry.json') -Force
    }

    # Public-facing primary: a Microsoft.Web/sites declaration.
    @'
@description('Public-facing app — primary region.')
param location string = 'westeurope'
param appServicePlanId string

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: 'app-public-01'
  location: location
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
  }
}

output siteId string = site.id
'@ | Set-Content (Join-Path $primaryDir 'app-public.bicep') -Encoding UTF8

    # Non-public-facing primary: a plain Storage Account.
    @'
@description('Non-public workload — primary region.')
param location string = 'westeurope'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stnopublic01'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: { minimumTlsVersion: 'TLS1_2' }
}
'@ | Set-Content (Join-Path $primaryDir 'storage-only.bicep') -Encoding UTF8

    # DR companion that DOES reference dr-traffic.bicep.
    @'
@description('Public-facing DR — references the Front Door traffic module.')
param location string = 'northeurope'
param appServicePlanId string

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: 'app-public-01-dr'
  location: location
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
  }
}

module traffic '../modules/dr-traffic.bicep' = {
  name: 'dr-traffic'
  params: {
    primaryHostname: 'app-public-01.azurewebsites.net'
    drHostname: site.properties.defaultHostName
  }
}
'@ | Set-Content (Join-Path $drDir 'dr-app-public-with-traffic.bicep') -Encoding UTF8

    # DR companion that DOES NOT reference dr-traffic.bicep.
    @'
@description('Public-facing DR companion — MISSING the Front Door reference (gate should fail).')
param location string = 'northeurope'
param appServicePlanId string

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: 'app-public-02-dr'
  location: location
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
  }
}
'@ | Set-Content (Join-Path $drDir 'dr-app-public-without-traffic.bicep') -Encoding UTF8

    # Non-public-facing companion (no Front Door needed).
    @'
@description('Non-public DR companion.')
param location string = 'northeurope'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'drstnopublic01'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: { minimumTlsVersion: 'TLS1_2' }
}
'@ | Set-Content (Join-Path $drDir 'dr-storage-only.bicep') -Encoding UTF8
}

function Invoke-Coverage {
    param(
        [Parameter(Mandatory)] [string]   $RepoDir,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ChangedPaths,
        [Parameter(Mandatory)] [string]   $OutDir
    )
    $changesFile = Join-Path $OutDir 'pr-changes.json'
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    New-PrChangesFile -Path $changesFile -Paths $ChangedPaths

    $savedGhOut = $env:GITHUB_OUTPUT
    $env:GITHUB_OUTPUT = $null
    try {
        & $ScriptPath -PrChangesFile $changesFile -RepoRoot $RepoDir -OutputDir $OutDir
        $code = $LASTEXITCODE
    } finally {
        $env:GITHUB_OUTPUT = $savedGhOut
    }
    $report = $null
    $reportPath = Join-Path $OutDir 'coverage-report.json'
    if (Test-Path $reportPath) {
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json -Depth 20
    }
    return [PSCustomObject]@{ ExitCode = $code; Report = $report }
}

# Each test sub-case wires the changed primary's filename to the matching DR
# companion via a one-off rename, so we don't have to invent multiple primary
# files. Cleanest way: copy the companion to the expected dr-<primary>.bicep
# name before running the gate.

$Workdir = Join-Path $env:TEMP ("draac-r4-fd-" + [guid]::NewGuid().ToString('N'))
try {
    # ── Scenario 1: public-facing + companion references dr-traffic.bicep ────
    Write-Host ""
    Write-Host "── public-facing primary + companion references dr-traffic.bicep ──"
    $repo1 = Join-Path $Workdir 'repo1'
    $null = New-Item -ItemType Directory -Force -Path $repo1
    New-TestRepo -Root $repo1
    Copy-Item (Join-Path $repo1 'bicep/regions/dr/dr-app-public-with-traffic.bicep') `
              (Join-Path $repo1 'bicep/regions/dr/dr-app-public.bicep') -Force

    $r1 = Invoke-Coverage -RepoDir $repo1 `
        -ChangedPaths @('bicep/regions/primary/app-public.bicep') `
        -OutDir (Join-Path $repo1 '_reports/coverage')
    Assert-Equal 0 $r1.ExitCode 'with-traffic: exit 0'
    Assert-True  $r1.Report.coverageOk 'with-traffic: coverageOk=true'
    $res1 = @($r1.Report.results)
    Assert-Equal 'ok' $res1[0].coverage 'with-traffic: result is ok'

    # ── Scenario 2: public-facing + companion missing dr-traffic.bicep ───────
    Write-Host ""
    Write-Host "── public-facing primary + companion MISSING dr-traffic.bicep ──"
    $repo2 = Join-Path $Workdir 'repo2'
    $null = New-Item -ItemType Directory -Force -Path $repo2
    New-TestRepo -Root $repo2
    Copy-Item (Join-Path $repo2 'bicep/regions/dr/dr-app-public-without-traffic.bicep') `
              (Join-Path $repo2 'bicep/regions/dr/dr-app-public.bicep') -Force

    $r2 = Invoke-Coverage -RepoDir $repo2 `
        -ChangedPaths @('bicep/regions/primary/app-public.bicep') `
        -OutDir (Join-Path $repo2 '_reports/coverage')
    Assert-Equal 1 $r2.ExitCode 'without-traffic: exit 1'
    Assert-True  (-not $r2.Report.coverageOk) 'without-traffic: coverageOk=false'
    $res2 = @($r2.Report.results)
    Assert-Equal 'failed' $res2[0].coverage 'without-traffic: coverage=failed'
    Assert-True  ($res2[0].reason -match 'dr-traffic\.bicep') 'without-traffic: reason mentions dr-traffic.bicep'

    # ── Scenario 3: non-public-facing primary → gate is a no-op ──────────────
    Write-Host ""
    Write-Host "── non-public-facing primary (Storage) → gate is a no-op ──"
    $repo3 = Join-Path $Workdir 'repo3'
    $null = New-Item -ItemType Directory -Force -Path $repo3
    New-TestRepo -Root $repo3

    $r3 = Invoke-Coverage -RepoDir $repo3 `
        -ChangedPaths @('bicep/regions/primary/storage-only.bicep') `
        -OutDir (Join-Path $repo3 '_reports/coverage')
    Assert-Equal 0 $r3.ExitCode 'non-public: exit 0'
    Assert-True  $r3.Report.coverageOk 'non-public: coverageOk=true'
    $res3 = @($r3.Report.results)
    Assert-Equal 'ok' $res3[0].coverage 'non-public: result is ok (Storage doesn''t need Front Door)'
}
finally {
    if (Test-Path $Workdir) {
        Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "Test-CheckDrCoverage-FrontDoor: all assertions passed."
    exit 0
} else {
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
