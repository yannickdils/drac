#Requires -Version 7.2
# =============================================================================
# tests/round-5/Test-SkuAvailability.ps1
# Round 5 §R5.7 / E2 — DR SKU availability check.
#
# Exercises Test-SkuAvailability.ps1 with -DryRun + a synthesised fixture to
# prove:
#   1. Happy path — VM, App Service Plan, SQL DB all available
#   2. Unavailable VM SKU triggers `unavailable` + non-null suggested substitute
#   3. Unsupported type → `notChecked` with `reason=unsupportedTypeForSkuCheck`
#   4. Idempotency: identical inputs → identical output (modulo `checkedAt`)
#
# Style: hand-rolled Assert helpers (Pester-free). Scratch artefacts under
# $env:TEMP/draac-sku-<guid>; cleaned in `finally`.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/dr/Test-SkuAvailability.ps1'
$Failures   = [System.Collections.Generic.List[string]]::new()

function Assert-True  { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $Failures.Add("[FAIL] $Msg — expected '$Expected' got '$Actual'") } }

Assert-True (Test-Path $ScriptPath) "Test-SkuAvailability.ps1 must exist"

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper creates an isolated temp directory under $env:TEMP; never mutates system state outside the harness.')]
    [CmdletBinding()]
    param()
    $Dir = Join-Path $env:TEMP "draac-sku-$([System.Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Force -Path $Dir
    return $Dir
}

function Set-Template {
    param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [object[]] $Resources)
    $null = New-Item -ItemType Directory -Force -Path $Dir
    $tpl = [ordered]@{
        '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        resources      = @($Resources)
    }
    $tpl | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $Dir 'template.json') -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 — Happy path: 3 resources, all available
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── sku: happy path (all available) ──"
$T1 = New-TempDir
try {
    $TplDir = Join-Path $T1 'rg-anchor-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{
            type = 'Microsoft.Compute/virtualMachines'
            name = 'vm-app1'
            sku  = [ordered]@{ name = 'Standard_D2s_v3' }
        },
        [ordered]@{
            type = 'Microsoft.Web/serverfarms'
            name = 'plan-app1'
            sku  = [ordered]@{ name = 'P1v3'; tier = 'PremiumV3' }
        },
        [ordered]@{
            type = 'Microsoft.Sql/servers/databases'
            name = 'sqlsrv01/db01'
            sku  = [ordered]@{ name = 'S0'; tier = 'Standard' }
        }
    )

    $Fixture = Join-Path $T1 'skus.json'
    @{
        vmSkus         = @{ northeurope = @( @{ name = 'Standard_D2s_v3'; available = $true } ) }
        appserviceSkus = @{ P1v3 = @('northeurope','westeurope') }
        sqlEditions    = @{ northeurope = @( @{ name = 'Standard'; available = $true } ) }
    } | ConvertTo-Json -Depth 10 | Set-Content $Fixture -Encoding UTF8

    $OutFile = Join-Path $T1 'sku-availability.json'
    & $ScriptPath -DrConfigDir $T1 -DrRegion 'northeurope' -OutputFile $OutFile `
        -DryRun -FixtureSkusFile $Fixture 2>$null

    Assert-True (Test-Path $OutFile) "sku-availability.json must be written"
    if (Test-Path $OutFile) {
        $r = Get-Content $OutFile -Raw | ConvertFrom-Json
        Assert-Equal 3 $r.summary.checked     "checked = 3"
        Assert-Equal 3 $r.summary.available   "available = 3"
        Assert-Equal 0 $r.summary.unavailable "unavailable = 0"
        Assert-Equal 0 $r.summary.notChecked  "notChecked = 0"
    }
}
finally { Remove-Item $T1 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 — Unavailable VM SKU: suggested substitute non-null
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── sku: unavailable VM SKU triggers substitute ──"
$T2 = New-TempDir
try {
    $TplDir = Join-Path $T2 'rg-monster-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{
            type = 'Microsoft.Compute/virtualMachines'
            name = 'vm-monster'
            sku  = [ordered]@{ name = 'Standard_D64s_v5' }
        }
    )

    $Fixture = Join-Path $T2 'skus.json'
    @{
        vmSkus         = @{ northeurope = @( @{ name = 'Standard_D2s_v3'; available = $true } ) }
        appserviceSkus = @{}
        sqlEditions    = @{ northeurope = @() }
    } | ConvertTo-Json -Depth 10 | Set-Content $Fixture -Encoding UTF8

    $OutFile = Join-Path $T2 'sku-availability.json'
    & $ScriptPath -DrConfigDir $T2 -DrRegion 'northeurope' -OutputFile $OutFile `
        -DryRun -FixtureSkusFile $Fixture 2>$null

    Assert-True (Test-Path $OutFile) "sku-availability.json must be written"
    if (Test-Path $OutFile) {
        $r = Get-Content $OutFile -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.unavailable "exactly 1 unavailable"
        $row = @($r.results | Where-Object { $_.status -eq 'unavailable' })[0]
        Assert-True ($null -ne $row.suggestedSubstitute) "suggestedSubstitute must be non-null"
        Assert-True ($row.suggestedSubstitute -match '^Standard_D\d+s_v5$') "substitute must match D<n>s_v5 family"
    }
}
finally { Remove-Item $T2 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 — Unsupported type → `notChecked` with reason
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── sku: unsupported type → notChecked ──"
$T3 = New-TempDir
try {
    $TplDir = Join-Path $T3 'rg-net-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{
            type = 'Microsoft.Network/networkInterfaces'
            name = 'nic1'
            sku  = [ordered]@{ name = 'Basic' }
        }
    )

    $Fixture = Join-Path $T3 'skus.json'
    @{ vmSkus = @{}; appserviceSkus = @{}; sqlEditions = @{} } |
        ConvertTo-Json | Set-Content $Fixture -Encoding UTF8

    $OutFile = Join-Path $T3 'sku-availability.json'
    & $ScriptPath -DrConfigDir $T3 -DrRegion 'northeurope' -OutputFile $OutFile `
        -DryRun -FixtureSkusFile $Fixture 2>$null

    if (Test-Path $OutFile) {
        $r = Get-Content $OutFile -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.notChecked "notChecked = 1"
        $row = @($r.results | Where-Object { $_.status -eq 'notChecked' })[0]
        Assert-Equal 'unsupportedTypeForSkuCheck' $row.reason "reason must be unsupportedTypeForSkuCheck"
    } else {
        $Failures.Add("[FAIL] sku-availability.json not written for unsupported-type test")
    }
}
finally { Remove-Item $T3 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 4 — Idempotency
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── sku: idempotency ──"
$T4 = New-TempDir
try {
    $TplDir = Join-Path $T4 'rg-anchor-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{
            type = 'Microsoft.Compute/virtualMachines'
            name = 'vm-app1'
            sku  = [ordered]@{ name = 'Standard_D2s_v3' }
        }
    )
    $Fixture = Join-Path $T4 'skus.json'
    @{
        vmSkus         = @{ northeurope = @( @{ name = 'Standard_D2s_v3'; available = $true } ) }
        appserviceSkus = @{}
        sqlEditions    = @{}
    } | ConvertTo-Json -Depth 10 | Set-Content $Fixture -Encoding UTF8

    $Out1 = Join-Path $T4 'r1.json'
    $Out2 = Join-Path $T4 'r2.json'
    & $ScriptPath -DrConfigDir $T4 -DrRegion 'northeurope' -OutputFile $Out1 -DryRun -FixtureSkusFile $Fixture 2>$null
    & $ScriptPath -DrConfigDir $T4 -DrRegion 'northeurope' -OutputFile $Out2 -DryRun -FixtureSkusFile $Fixture 2>$null

    if ((Test-Path $Out1) -and (Test-Path $Out2)) {
        $r1 = Get-Content $Out1 -Raw | ConvertFrom-Json
        $r2 = Get-Content $Out2 -Raw | ConvertFrom-Json
        $j1 = $r1.summary | ConvertTo-Json -Depth 5 -Compress
        $j2 = $r2.summary | ConvertTo-Json -Depth 5 -Compress
        Assert-Equal $j1 $j2 "summary must match across runs"
        Assert-Equal $r1.results.Count $r2.results.Count "results count must match across runs"
    } else {
        $Failures.Add("[FAIL] idempotency: missing output")
    }
}
finally { Remove-Item $T4 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { Write-Host $f }
    exit 1
}
Write-Host "Test-SkuAvailability: all assertions passed."
exit 0
