#Requires -Version 7.2
# =============================================================================
# tests/round-1/Test-ConvertForDR.ps1
# Asserts the structural correctness of Convert-ForDR for the five Round 1
# fixtures. Exits 0 on PASS, 1 on FAIL.
#
# What this test does NOT do:
#   - Live `az deployment group validate` (deferred per IMPLEMENTATION-LOG.md)
#   - Snapshot diffing (snapshots can be added once the module stabilises)
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ModulePath = Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1'
$FixturesDir = Join-Path $RepoRoot 'tests/fixtures/exports'

Import-Module $ModulePath -Force

# Test fixtures share the same DR transform parameters.
$DrRegion       = 'northeurope'
$DrVnetPrefix   = '10.100.0.0/16'
$DrSubnetPrefix = '10.100.0.0/24'
$DrNamingPrefix = 'dr-'

# Load reserved names — Convert-ForDR will load them itself if not provided,
# but the test asserts behaviour explicitly so we pass them in.
$reservedNamesFile = Join-Path $RepoRoot 'data/reserved-names.json'
$reservedJson = Get-Content $reservedNamesFile -Raw | ConvertFrom-Json
$ReservedNames = @($reservedJson.subnetNames) + @($reservedJson.fixedResourceNames)

$Failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        $Failures.Add("[FAIL] $Message`n         expected: $Expected`n         actual:   $Actual")
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $Failures.Add("[FAIL] $Message") }
}

function Assert-False {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { $Failures.Add("[FAIL] $Message") }
}

function Get-ResourceList {
    param([Parameter(Mandatory)] [PSCustomObject] $Template, [string] $Type)
    $items = @($Template.resources | Where-Object {
        $_ -is [System.Management.Automation.PSCustomObject] -and (-not $Type -or $_.type -eq $Type)
    })
    return $items
}

function Invoke-Transform {
    param([string] $FixtureName)
    $path = Join-Path $FixturesDir $FixtureName 'template.json'
    if (-not (Test-Path $path)) { throw "Fixture not found: $path" }
    $tpl = Get-Content $path -Raw | ConvertFrom-Json -Depth 50
    return Convert-ForDR -Template $tpl `
        -DrRegion $DrRegion `
        -DrVnetPrefix $DrVnetPrefix `
        -DrSubnetPrefix $DrSubnetPrefix `
        -DrNamingPrefix $DrNamingPrefix `
        -ReservedNames $ReservedNames
}

# ── simple-rg ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "── simple-rg ──"
$result = Invoke-Transform 'simple-rg'
$tpl = $result.Template
$storage = (Get-ResourceList -Template $tpl -Type 'Microsoft.Storage/storageAccounts')[0]
$nsg     = (Get-ResourceList -Template $tpl -Type 'Microsoft.Network/networkSecurityGroups')[0]
Assert-Equal 'dr-stgsimple001'   $storage.name 'simple-rg: storage name prefixed'
Assert-Equal 'dr-nsg-simple-001' $nsg.name     'simple-rg: NSG name prefixed'
Assert-Equal $DrRegion           $storage.location 'simple-rg: storage location is DR region'
Assert-Equal $DrRegion           $nsg.location     'simple-rg: NSG location is DR region'
$rule = $nsg.properties.securityRules[0]
Assert-Equal 'AllowVnetInBound'  $rule.name 'simple-rg: NSG rule name NOT prefixed (nested, no type field)'
Assert-Equal 'VirtualNetwork'    $rule.properties.sourceAddressPrefix      'simple-rg: NSG rule source prefix unchanged'
Assert-Equal 'VirtualNetwork'    $rule.properties.destinationAddressPrefix 'simple-rg: NSG rule dest prefix unchanged'

# ── gateway-subnet-rg ─────────────────────────────────────────────────────────
Write-Host "── gateway-subnet-rg ──"
$result = Invoke-Transform 'gateway-subnet-rg'
$tpl = $result.Template
$vnet = (Get-ResourceList -Template $tpl -Type 'Microsoft.Network/virtualNetworks')[0]
Assert-Equal 'dr-vnet-gateway' $vnet.name 'gateway-subnet-rg: VNet name prefixed'
Assert-Equal $DrRegion         $vnet.location 'gateway-subnet-rg: VNet location is DR region'
$subnetNames = @($vnet.properties.subnets | ForEach-Object { $_.name })
foreach ($expected in @('GatewaySubnet','AzureFirewallSubnet','AzureBastionSubnet','RouteServerSubnet','snet-workload')) {
    Assert-True ($subnetNames -contains $expected) "gateway-subnet-rg: subnet '$expected' name preserved (B1)"
}
# VNet address space rewritten
$prefixes = @($vnet.properties.addressSpace.addressPrefixes)
Assert-Equal 1              $prefixes.Count 'gateway-subnet-rg: address space reduced to single DR prefix'
Assert-Equal $DrVnetPrefix  $prefixes[0]    'gateway-subnet-rg: address space prefix is DR prefix'
# Reserved subnets keep original /27, /26 etc; only snet-workload (non-reserved) gets DR subnet prefix.
$gwSubnet = $vnet.properties.subnets | Where-Object { $_.name -eq 'GatewaySubnet' }
Assert-Equal '10.0.255.0/27' $gwSubnet.properties.addressPrefix 'gateway-subnet-rg: GatewaySubnet addressPrefix UNCHANGED (B1+B3)'
$workloadSubnet = $vnet.properties.subnets | Where-Object { $_.name -eq 'snet-workload' }
Assert-Equal $DrSubnetPrefix $workloadSubnet.properties.addressPrefix 'gateway-subnet-rg: first non-reserved subnet rewritten to DR prefix'

# ── peered-vnet-rg ────────────────────────────────────────────────────────────
Write-Host "── peered-vnet-rg ──"
$result = Invoke-Transform 'peered-vnet-rg'
$tpl = $result.Template

$vnetHub = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.name -eq 'dr-vnet-hub' }
$vnetSpoke = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.name -eq 'dr-vnet-spoke' }
$peering = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' }
$rt = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Network/routeTables' }

Assert-True ($null -ne $vnetHub)   'peered-vnet-rg: dr-vnet-hub exists after transform'
Assert-True ($null -ne $vnetSpoke) 'peered-vnet-rg: dr-vnet-spoke exists after transform'
Assert-True ($null -ne $peering)   'peered-vnet-rg: peering resource exists after transform'
Assert-True ($null -ne $rt)        'peered-vnet-rg: route table exists after transform'

# Peering name: parent segment must be rewritten (B1 nested-type handling).
Assert-Equal 'dr-vnet-hub/peer-to-spoke' $peering.name 'peered-vnet-rg: peering name parent segment rewritten'

# B2: dependsOn rewritten to DR resourceId expressions.
$spokeDeps = @($vnetSpoke.dependsOn)
Assert-True ($spokeDeps -contains "[resourceId('Microsoft.Network/virtualNetworks', 'dr-vnet-hub')]") `
    'peered-vnet-rg: spoke dependsOn references dr-vnet-hub (B2)'
$peeringDeps = @($peering.dependsOn)
Assert-True ($peeringDeps -contains "[resourceId('Microsoft.Network/virtualNetworks', 'dr-vnet-hub')]") `
    'peered-vnet-rg: peering dependsOn references dr-vnet-hub (B2)'
Assert-True ($peeringDeps -contains "[resourceId('Microsoft.Network/virtualNetworks', 'dr-vnet-spoke')]") `
    'peered-vnet-rg: peering dependsOn references dr-vnet-spoke (B2)'

# B2: peering remoteVirtualNetwork.id rewritten.
Assert-Equal "[resourceId('Microsoft.Network/virtualNetworks', 'dr-vnet-spoke')]" `
    $peering.properties.remoteVirtualNetwork.id `
    'peered-vnet-rg: peering remoteVirtualNetwork.id rewritten to DR name (B2)'

# B3: peering remoteAddressSpace.addressPrefixes UNCHANGED (peering subtree off-limits).
Assert-Equal '10.20.0.0/16' $peering.properties.remoteAddressSpace.addressPrefixes[0] `
    'peered-vnet-rg: peering remoteAddressSpace UNCHANGED (B3 — peerings excluded)'

# B3: route table route addressPrefix UNCHANGED.
Assert-Equal '10.10.0.0/16' $rt.properties.routes[0].properties.addressPrefix `
    'peered-vnet-rg: route table route addressPrefix UNCHANGED (B3 — routes excluded)'

# B3: VNet address spaces rewritten.
Assert-Equal $DrVnetPrefix $vnetHub.properties.addressSpace.addressPrefixes[0] `
    'peered-vnet-rg: hub VNet address space rewritten'
Assert-Equal $DrVnetPrefix $vnetSpoke.properties.addressSpace.addressPrefixes[0] `
    'peered-vnet-rg: spoke VNet address space rewritten'

# ── multi-prefix-vnet-rg ──────────────────────────────────────────────────────
Write-Host "── multi-prefix-vnet-rg ──"
$result = Invoke-Transform 'multi-prefix-vnet-rg'
$tpl = $result.Template
$flags = $result.Flags
$vnet = (Get-ResourceList -Template $tpl -Type 'Microsoft.Network/virtualNetworks')[0]
$prefixes = @($vnet.properties.addressSpace.addressPrefixes)
Assert-Equal 1              $prefixes.Count 'multi-prefix-vnet-rg: only first prefix kept'
Assert-Equal $DrVnetPrefix  $prefixes[0]    'multi-prefix-vnet-rg: first prefix is DR prefix'
$multiFlag = @($flags.requiresMultiPrefixDR)
Assert-True ($multiFlag.Count -ge 1) 'multi-prefix-vnet-rg: requiresMultiPrefixDR flag set'
$entry = $multiFlag[0]
Assert-Equal 'dr-vnet-multi' $entry.vnet 'multi-prefix-vnet-rg: flag identifies the VNet'
$multiSubnetFlag = @($flags.requiresMultiSubnetDR)
Assert-True ($multiSubnetFlag.Count -ge 1) 'multi-prefix-vnet-rg: requiresMultiSubnetDR flag set (2 subnets)'

# ── readonly-props-rg ─────────────────────────────────────────────────────────
Write-Host "── readonly-props-rg ──"
$result = Invoke-Transform 'readonly-props-rg'
$tpl = $result.Template
$storage = (Get-ResourceList -Template $tpl -Type 'Microsoft.Storage/storageAccounts')[0]
$site    = (Get-ResourceList -Template $tpl -Type 'Microsoft.Web/sites')[0]
$ident   = (Get-ResourceList -Template $tpl -Type 'Microsoft.ManagedIdentity/userAssignedIdentities')[0]

# Storage: global + per-type stripping.
$storageProps = $storage.properties.PSObject.Properties | ForEach-Object Name
foreach ($k in @('provisioningState','creationTime','primaryEndpoints','secondaryEndpoints','primaryLocation','statusOfPrimary')) {
    Assert-False ($storageProps -contains $k) "readonly-props-rg: storage '$k' stripped"
}
Assert-True ($storageProps -contains 'accessTier')               'readonly-props-rg: storage accessTier kept'
Assert-True ($storageProps -contains 'supportsHttpsTrafficOnly') 'readonly-props-rg: storage supportsHttpsTrafficOnly kept'

# Web/sites: per-type + global (etag) stripping.
$siteProps = $site.properties.PSObject.Properties | ForEach-Object Name
foreach ($k in @('outboundIpAddresses','possibleOutboundIpAddresses','defaultHostName','inboundIpAddress','etag')) {
    Assert-False ($siteProps -contains $k) "readonly-props-rg: web/site '$k' stripped"
}
Assert-True ($siteProps -contains 'serverFarmId') 'readonly-props-rg: serverFarmId kept'

# ManagedIdentity: per-type stripping leaves an empty properties object.
$identProps = $ident.properties.PSObject.Properties | ForEach-Object Name
foreach ($k in @('principalId','clientId','tenantId')) {
    Assert-False ($identProps -contains $k) "readonly-props-rg: identity '$k' stripped"
}
Assert-Equal 'dr-stgreadonly001'  $storage.name 'readonly-props-rg: storage name prefixed'
Assert-Equal 'dr-app-readonly-001' $site.name   'readonly-props-rg: web/site name prefixed'
Assert-Equal 'dr-id-readonly-001' $ident.name   'readonly-props-rg: identity name prefixed'

# ── Idempotency: Convert-ForDR on its own output should not double-prefix ─────
Write-Host "── idempotency check ──"
$first  = Invoke-Transform 'simple-rg'
$twice  = Convert-ForDR -Template $first.Template -DrRegion $DrRegion `
    -DrVnetPrefix $DrVnetPrefix -DrSubnetPrefix $DrSubnetPrefix `
    -DrNamingPrefix $DrNamingPrefix -ReservedNames $ReservedNames
$storage1 = (Get-ResourceList -Template $first.Template -Type 'Microsoft.Storage/storageAccounts')[0]
$storage2 = (Get-ResourceList -Template $twice.Template -Type 'Microsoft.Storage/storageAccounts')[0]
Assert-Equal $storage1.name $storage2.name 'idempotency: re-running does not double-prefix'

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "All assertions passed."
    exit 0
} else {
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
