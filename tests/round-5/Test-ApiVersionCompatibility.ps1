#Requires -Version 7.2
# =============================================================================
# tests/round-5/Test-ApiVersionCompatibility.ps1
# Round 5 §R5.8 / E3 — DR API-version compatibility check.
#
# Exercises Test-ApiVersionCompatibility.ps1 with -DryRun + a synthesised
# provider fixture to prove:
#   1. Compatible apiVersion → status=compatible
#   2. Incompatible apiVersion → status=incompatible + suggested = latest GA
#   3. Type's `locations` excludes DR region → status=notAvailable
#   4. Type missing from provider fixture → status=notChecked + reason=typeNotFoundInProvider
#   5. Idempotency: identical inputs → identical output (modulo `checkedAt`)
#   6. Nested child resource (Microsoft.Sql/servers/databases) is checked
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/dr/Test-ApiVersionCompatibility.ps1'
$Failures   = [System.Collections.Generic.List[string]]::new()

function Assert-True  { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $Failures.Add("[FAIL] $Msg — expected '$Expected' got '$Actual'") } }

Assert-True (Test-Path $ScriptPath) "Test-ApiVersionCompatibility.ps1 must exist"

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper creates an isolated temp directory under $env:TEMP; never mutates system state outside the harness.')]
    [CmdletBinding()]
    param()
    $Dir = Join-Path $env:TEMP "draac-apiver-$([System.Guid]::NewGuid().ToString('N'))"
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

# Default fixture covering the common cases:
function New-StandardFixture {
    param([string] $Path)
    $f = [ordered]@{
        'Microsoft.Network' = @{
            resourceTypes = @(
                @{ resourceType = 'virtualNetworks'
                   apiVersions  = @('2024-05-01','2024-01-01','2023-09-01')
                   locations    = @('North Europe','West Europe') }
            )
        }
        'Microsoft.Storage' = @{
            resourceTypes = @(
                @{ resourceType = 'storageAccounts'
                   apiVersions  = @('2024-01-01','2023-05-01','2023-04-01-preview')
                   locations    = @('North Europe','West Europe') }
            )
        }
        'Microsoft.Sql' = @{
            resourceTypes = @(
                @{ resourceType = 'servers'
                   apiVersions  = @('2024-05-01-preview','2023-08-01','2023-05-01-preview')
                   locations    = @('North Europe','West Europe') },
                @{ resourceType = 'servers/databases'
                   apiVersions  = @('2023-08-01','2023-05-01-preview')
                   locations    = @('North Europe','West Europe') }
            )
        }
        'Microsoft.Compute' = @{
            resourceTypes = @(
                @{ resourceType = 'virtualMachines'
                   apiVersions  = @('2024-07-01','2024-03-01')
                   locations    = @('West Europe') }
            )
        }
    }
    $f | ConvertTo-Json -Depth 10 | Set-Content $Path -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 — Compatible apiVersion
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── apiver: compatible ──"
$T1 = New-TempDir
try {
    $TplDir = Join-Path $T1 'rg-anchor-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{ type = 'Microsoft.Network/virtualNetworks'; apiVersion = '2024-05-01'; name = 'vnet1' }
    )
    $Fixture = Join-Path $T1 'providers.json'
    New-StandardFixture -Path $Fixture
    $Out = Join-Path $T1 'compat.json'
    & $ScriptPath -DrConfigDir $T1 -DrRegion 'northeurope' -OutputFile $Out -DryRun -FixtureProvidersFile $Fixture 2>$null

    Assert-True (Test-Path $Out) "compat.json must be written"
    if (Test-Path $Out) {
        $r = Get-Content $Out -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.compatible   "compatible = 1"
        Assert-Equal 0 $r.summary.incompatible "incompatible = 0"
    }
}
finally { Remove-Item $T1 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 — Incompatible apiVersion → suggested = latest GA
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── apiver: incompatible → suggested ──"
$T2 = New-TempDir
try {
    $TplDir = Join-Path $T2 'rg-anchor-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2018-07-01'; name = 'oldacc' }
    )
    $Fixture = Join-Path $T2 'providers.json'
    New-StandardFixture -Path $Fixture
    $Out = Join-Path $T2 'compat.json'
    & $ScriptPath -DrConfigDir $T2 -DrRegion 'northeurope' -OutputFile $Out -DryRun -FixtureProvidersFile $Fixture 2>$null

    if (Test-Path $Out) {
        $r = Get-Content $Out -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.incompatible "incompatible = 1"
        $row = @($r.results | Where-Object { $_.status -eq 'incompatible' })[0]
        Assert-Equal '2024-01-01' $row.suggestedApiVersion "suggested must be latest GA (2024-01-01)"
    } else {
        $Failures.Add("[FAIL] compat.json not written for incompatible test")
    }
}
finally { Remove-Item $T2 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 — Region not in `locations` → notAvailable
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── apiver: notAvailable (region mismatch) ──"
$T3 = New-TempDir
try {
    $TplDir = Join-Path $T3 'rg-vm-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{ type = 'Microsoft.Compute/virtualMachines'; apiVersion = '2024-07-01'; name = 'vm-app' }
    )
    $Fixture = Join-Path $T3 'providers.json'
    New-StandardFixture -Path $Fixture   # virtualMachines: locations = West Europe only
    $Out = Join-Path $T3 'compat.json'
    & $ScriptPath -DrConfigDir $T3 -DrRegion 'northeurope' -OutputFile $Out -DryRun -FixtureProvidersFile $Fixture 2>$null

    if (Test-Path $Out) {
        $r = Get-Content $Out -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.notAvailable "notAvailable = 1"
        Assert-Equal 0 $r.summary.compatible   "compatible = 0"
    } else {
        $Failures.Add("[FAIL] compat.json not written for region-mismatch test")
    }
}
finally { Remove-Item $T3 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 4 — Type not found in provider → notChecked + reason
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── apiver: notChecked (type not in provider) ──"
$T4 = New-TempDir
try {
    $TplDir = Join-Path $T4 'rg-foo-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{ type = 'Microsoft.Foo/bars'; apiVersion = '2024-01-01'; name = 'foo1' }
    )
    $Fixture = Join-Path $T4 'providers.json'
    New-StandardFixture -Path $Fixture
    $Out = Join-Path $T4 'compat.json'
    & $ScriptPath -DrConfigDir $T4 -DrRegion 'northeurope' -OutputFile $Out -DryRun -FixtureProvidersFile $Fixture 2>$null

    if (Test-Path $Out) {
        $r = Get-Content $Out -Raw | ConvertFrom-Json
        Assert-Equal 1 $r.summary.notChecked "notChecked = 1"
        $row = @($r.results | Where-Object { $_.status -eq 'notChecked' })[0]
        Assert-True ($row.reason -match 'providerLookupFailed|typeNotFoundInProvider') "reason must reflect provider lookup gap"
    } else {
        $Failures.Add("[FAIL] compat.json not written for not-found test")
    }
}
finally { Remove-Item $T4 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 5 — Idempotency
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── apiver: idempotency ──"
$T5 = New-TempDir
try {
    $TplDir = Join-Path $T5 'rg-anchor-dr'
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{ type = 'Microsoft.Network/virtualNetworks'; apiVersion = '2024-05-01'; name = 'vnet1' }
    )
    $Fixture = Join-Path $T5 'providers.json'
    New-StandardFixture -Path $Fixture
    $Out1 = Join-Path $T5 'r1.json'
    $Out2 = Join-Path $T5 'r2.json'
    & $ScriptPath -DrConfigDir $T5 -DrRegion 'northeurope' -OutputFile $Out1 -DryRun -FixtureProvidersFile $Fixture 2>$null
    & $ScriptPath -DrConfigDir $T5 -DrRegion 'northeurope' -OutputFile $Out2 -DryRun -FixtureProvidersFile $Fixture 2>$null

    if ((Test-Path $Out1) -and (Test-Path $Out2)) {
        $r1 = Get-Content $Out1 -Raw | ConvertFrom-Json
        $r2 = Get-Content $Out2 -Raw | ConvertFrom-Json
        $j1 = $r1.summary | ConvertTo-Json -Depth 5 -Compress
        $j2 = $r2.summary | ConvertTo-Json -Depth 5 -Compress
        Assert-Equal $j1 $j2 "summary must match across runs"
    } else {
        $Failures.Add("[FAIL] idempotency: missing output")
    }
}
finally { Remove-Item $T5 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
# Test 6 — Nested child resource is checked
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── apiver: nested child resource ──"
$T6 = New-TempDir
try {
    $TplDir = Join-Path $T6 'rg-sql-dr'
    # SQL server with nested database
    Set-Template -Dir $TplDir -Resources @(
        [ordered]@{
            type       = 'Microsoft.Sql/servers'
            apiVersion = '2023-08-01'
            name       = 'sqlsrv01'
            resources  = @(
                [ordered]@{
                    type       = 'databases'
                    apiVersion = '2023-08-01'
                    name       = 'db01'
                }
            )
        }
    )
    $Fixture = Join-Path $T6 'providers.json'
    New-StandardFixture -Path $Fixture
    $Out = Join-Path $T6 'compat.json'
    & $ScriptPath -DrConfigDir $T6 -DrRegion 'northeurope' -OutputFile $Out -DryRun -FixtureProvidersFile $Fixture 2>$null

    if (Test-Path $Out) {
        $r = Get-Content $Out -Raw | ConvertFrom-Json
        # Note: 'Microsoft.Sql/servers' uses 2023-08-01 — supported list has '2024-05-01-preview','2023-08-01' (GA),'2023-05-01-preview'
        # Should be compatible.
        $serversRow = @($r.results | Where-Object { $_.resource.type -eq 'Microsoft.Sql/servers' })
        $dbRow = @($r.results | Where-Object { $_.resource.type -eq 'Microsoft.Sql/servers/databases' })
        Assert-True ($serversRow.Count -eq 1) "servers row appears"
        Assert-True ($dbRow.Count -eq 1)      "nested servers/databases row appears"
        Assert-Equal 'compatible' $serversRow[0].status "servers should be compatible"
        Assert-Equal 'compatible' $dbRow[0].status     "databases should be compatible"
    } else {
        $Failures.Add("[FAIL] compat.json not written for nested-resource test")
    }
}
finally { Remove-Item $T6 -Recurse -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────────────────────
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { Write-Host $f }
    exit 1
}
Write-Host "Test-ApiVersionCompatibility: all assertions passed."
exit 0
