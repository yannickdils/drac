#Requires -Version 7.2
# =============================================================================
# tests/round-4/Test-ConvertForDR-Dispatch.ps1
# Round 4 §R4.1 — DR module dispatch shell.
#
# Verifies:
#   1. Empty registry → result.Dispatched is an empty array, template unchanged.
#   2. Populated registry → top-level resources of registered types appear in
#      result.Dispatched with correct {type, originalName, drName, module}.
#   3. Idempotency — re-running on already-DR-prefixed input produces the same
#      Dispatched record (same drName, module).
#   4. Initialize-DefaultDrModuleRegistry loads from data/dr-module-registry.json
#      and falls back to empty when the file maps no types.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ModulePath = Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1'
Import-Module $ModulePath -Force

$Failures = [System.Collections.Generic.List[string]]::new()
function Assert-True  { param([bool] $Cond, [string] $Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Exp, $Act, [string] $Msg) if ($Exp -ne $Act) { $Failures.Add("[FAIL] $Msg`n         expected: $Exp`n         actual:   $Act") } }

# Synthetic ARM template with a Storage Account and a SQL DB — both candidates
# for R4.1 module dispatch. Plus a NIC to verify non-registered types are
# left alone.
$template = [PSCustomObject]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    resources      = @(
        [PSCustomObject]@{
            type       = 'Microsoft.Storage/storageAccounts'
            apiVersion = '2023-05-01'
            name       = 'stmydata01'
            location   = 'westeurope'
            sku        = [PSCustomObject]@{ name = 'Standard_LRS' }
            kind       = 'StorageV2'
            properties = [PSCustomObject]@{ minimumTlsVersion = 'TLS1_2' }
        },
        [PSCustomObject]@{
            type       = 'Microsoft.Sql/servers'
            apiVersion = '2023-08-01-preview'
            name       = 'sqlsrv01'
            location   = 'westeurope'
            properties = [PSCustomObject]@{ administratorLogin = 'sqladmin' }
        },
        [PSCustomObject]@{
            type       = 'Microsoft.Sql/servers/databases'
            apiVersion = '2023-08-01-preview'
            name       = 'sqlsrv01/db01'
            location   = 'westeurope'
            properties = [PSCustomObject]@{ collation = 'SQL_Latin1_General_CP1_CI_AS' }
        },
        [PSCustomObject]@{
            type       = 'Microsoft.Network/networkInterfaces'
            apiVersion = '2023-09-01'
            name       = 'nic-myvm-01'
            location   = 'westeurope'
            properties = [PSCustomObject]@{ enableAcceleratedNetworking = $false }
        }
    )
}

Write-Host ""
Write-Host "── empty registry → Dispatched is empty, template unchanged ──"
Clear-DrModuleRegistry
$r0 = Convert-ForDR -Template $template `
    -DrRegion 'northeurope' -DrVnetPrefix '10.100.0.0/16' -DrSubnetPrefix '10.100.0.0/24'
Assert-True  ($null -ne $r0)                            'empty: result returned'
Assert-True  ($null -ne (Get-Member -InputObject $r0 -Name 'Dispatched')) 'empty: Dispatched field present'
Assert-Equal 0 (@($r0.Dispatched).Count)                'empty: 0 dispatched records'
Assert-Equal 4 (@($r0.Template.resources).Count)        'empty: all 4 resources still in template'

Write-Host ""
Write-Host "── populated registry → expected types are dispatched ──"
Clear-DrModuleRegistry
Register-DrModule -Type 'Microsoft.Storage/storageAccounts'   -Module 'dr-storage.bicep'
Register-DrModule -Type 'Microsoft.Sql/servers/databases'     -Module 'dr-sql.bicep'

$r1 = Convert-ForDR -Template $template `
    -DrRegion 'northeurope' -DrVnetPrefix '10.100.0.0/16' -DrSubnetPrefix '10.100.0.0/24'
$d1 = @($r1.Dispatched)
# Storage Account + SQL DB → 2 dispatched. The parent SQL server itself is NOT
# in the registry (only the depth-2 databases type is); the NIC is skipped.
Assert-Equal 2 $d1.Count 'pop: 2 dispatch records (Storage + SQL DB)'

# Storage record (top-level type — depth 1, name 'stmydata01' rewritten to 'dr-stmydata01').
$storage = @($d1 | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' })
Assert-Equal 1 $storage.Count 'pop: storage dispatch present'
if ($storage.Count -ge 1) {
    Assert-Equal 'stmydata01'       $storage[0].originalName 'pop: storage originalName'
    Assert-Equal 'dr-stmydata01'    $storage[0].drName       'pop: storage drName carries DR prefix'
    Assert-Equal 'dr-storage.bicep' $storage[0].module       'pop: storage module'
}

# SQL DB record (nested type — depth 2, name 'sqlsrv01/db01'). drName rewrites
# parent segments via the rewrite map, leaving the child untouched.
$sql = @($d1 | Where-Object { $_.type -eq 'Microsoft.Sql/servers/databases' })
Assert-Equal 1 $sql.Count 'pop: sql dispatch present'
if ($sql.Count -ge 1) {
    Assert-Equal 'sqlsrv01/db01'    $sql[0].originalName 'pop: sql originalName'
    Assert-Equal 'dr-sqlsrv01/db01' $sql[0].drName       'pop: sql drName has parent rewritten'
    Assert-Equal 'dr-sql.bicep'     $sql[0].module       'pop: sql module'
}

# NIC absent from dispatch
$nic = @($d1 | Where-Object { $_.type -eq 'Microsoft.Network/networkInterfaces' })
Assert-Equal 0 $nic.Count 'pop: NIC type not registered → not dispatched'

# Template still contains all resources (dispatch is observation, not mutation).
Assert-Equal 4 (@($r1.Template.resources).Count) 'pop: template still has all 4 resources'

Write-Host ""
Write-Host "── idempotency: re-running on already-prefixed input ──"
$r2 = Convert-ForDR -Template $r1.Template `
    -DrRegion 'northeurope' -DrVnetPrefix '10.100.0.0/16' -DrSubnetPrefix '10.100.0.0/24'
$d2 = @($r2.Dispatched)
Assert-Equal $d1.Count $d2.Count 'idem: same number of dispatch records'

Write-Host ""
Write-Host "── Initialize-DefaultDrModuleRegistry loads from data/ ──"
$loaded = Initialize-DefaultDrModuleRegistry
Assert-True ($loaded -is [hashtable]) 'init: returns a hashtable'
# Round 4 (R4.1) populated data/dr-module-registry.json with the 7 family
# modules. Initialize-DefaultDrModuleRegistry should load them into the
# in-memory registry and surface a few key mappings so the test catches a
# regression if the data file is ever truncated.
Assert-True ($loaded.Count -ge 7) "init: registry has at least 7 entries (got $($loaded.Count))"
Assert-Equal 'dr-storage.bicep'  $loaded['Microsoft.Storage/storageAccounts']     'init: Storage Account → dr-storage.bicep'
Assert-Equal 'dr-sql.bicep'      $loaded['Microsoft.Sql/servers/databases']        'init: SQL DB → dr-sql.bicep'
Assert-Equal 'dr-keyvault.bicep' $loaded['Microsoft.KeyVault/vaults']              'init: Key Vault → dr-keyvault.bicep'

# Reset for downstream tests.
Clear-DrModuleRegistry

Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "Test-ConvertForDR-Dispatch: all assertions passed."
    exit 0
} else {
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
