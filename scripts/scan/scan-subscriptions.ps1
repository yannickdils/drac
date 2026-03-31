#Requires -Version 7.2
# =============================================================================
# scan-subscriptions.ps1
# Stage 1: Scan all Azure subscriptions using Azure Resource Graph API 2024-04-01
# Idempotent: re-runs produce identical output directory structure.
# Fault-tolerant: individual query failures are logged, not fatal.
# =============================================================================
[CmdletBinding()]
param(
    [string] $ApiVersion      = "2024-04-01",
    [string] $SubscriptionIds = "",
    [string] $ManagementGroup = "",
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScanDir   = Join-Path $OutputDir "scan"
$null      = New-Item -ItemType Directory -Force -Path $ScanDir
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "============================================================"
Write-Host "STAGE 1: Azure Subscription Scan"
Write-Host "  Resource Graph API: $ApiVersion"
Write-Host "  Run ID:             $RunId"
Write-Host "  Output:             $ScanDir"
Write-Host "============================================================"

# ── Resolve subscriptions ─────────────────────────────────────────────────────
function Resolve-Subscriptions {
    if ($ManagementGroup -and $ManagementGroup -ne "none") {
        Write-Host "INFO: Querying subscriptions in management group: $ManagementGroup"
        try {
            $mg = az account management-group show --name $ManagementGroup --expand --recurse --output json 2>$null | ConvertFrom-Json
            $subs = $mg.children | Where-Object { $_.type -like "*/subscriptions" } | Select-Object -ExpandProperty name
            if ($subs) { return $subs }
        } catch { Write-Warning "Management group query failed — falling back to account list" }
    }
    if ($SubscriptionIds -and $SubscriptionIds -ne "ALL") {
        return ($SubscriptionIds -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    Write-Host "INFO: Fetching all accessible subscriptions"
    return (az account list --query "[?state=='Enabled'].id" --output tsv 2>$null) -split "`n" | Where-Object { $_.Trim() }
}

$Subscriptions = @(Resolve-Subscriptions)
$SubCount      = $Subscriptions.Count
Write-Host "INFO: Found $SubCount subscription(s) to scan"
$Subscriptions | Set-Content (Join-Path $ScanDir "subscriptions.txt") -Encoding UTF8

# ── Paginated Resource Graph query ────────────────────────────────────────────
function Invoke-ResourceGraphQuery {
    param([string]$Query, [string]$OutputFile)

    $AllResults = [System.Collections.Generic.List[object]]::new()
    $SkipToken  = $null
    $Page       = 0
    $Uri        = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=$ApiVersion"

    do {
        $Page++
        Write-Host "  Page $Page..."

        $Options = [ordered]@{ '$top' = 1000; resultFormat = "objectArray" }
        if ($SkipToken) { $Options['$skipToken'] = $SkipToken }

        $Body = if ($ManagementGroup -and $ManagementGroup -ne "none") {
            [ordered]@{ managementGroups = @($ManagementGroup); query = $Query; options = $Options }
        } else {
            [ordered]@{ subscriptions = $Subscriptions; query = $Query; options = $Options }
        }

        try {
            $Response  = az rest --method POST --uri $Uri --body ($Body | ConvertTo-Json -Depth 10 -Compress) --output json 2>$null | ConvertFrom-Json
            if ($Response.data) { $AllResults.AddRange([object[]]$Response.data) }
            $SkipToken = $Response.'$skipToken'
        } catch {
            Write-Warning "Resource Graph query failed on page $Page — stopping pagination: $_"
            break
        }
    } while ($SkipToken)

    $AllResults | ConvertTo-Json -Depth 20 | Set-Content $OutputFile -Encoding UTF8
    Write-Host "INFO: Query returned $($AllResults.Count) records -> $OutputFile"
}

# ── Execute all scans ─────────────────────────────────────────────────────────
$Queries = [ordered]@{
    "all-resources"       = "Resources | project id, name, type, location, resourceGroup, subscriptionId, tags, kind, sku, properties | order by type asc"
    "vnets"               = "Resources | where type =~ 'Microsoft.Network/virtualNetworks' | project id, name, resourceGroup, subscriptionId, location, addressSpace=properties.addressSpace, subnets=properties.subnets, tags"
    "nsgs"                = "Resources | where type =~ 'Microsoft.Network/networkSecurityGroups' | project id, name, resourceGroup, subscriptionId, location, securityRules=properties.securityRules, tags"
    "compute"             = "Resources | where type in~ ('Microsoft.Compute/virtualMachines','Microsoft.Compute/virtualMachineScaleSets','Microsoft.ContainerService/managedClusters','Microsoft.Web/sites','Microsoft.Web/serverFarms') | project id, name, type, resourceGroup, subscriptionId, location, sku, properties, tags"
    "storage-databases"   = "Resources | where type in~ ('Microsoft.Storage/storageAccounts','Microsoft.Sql/servers','Microsoft.Sql/servers/databases','Microsoft.DocumentDB/databaseAccounts','Microsoft.DBforPostgreSQL/flexibleServers','Microsoft.DBforMySQL/flexibleServers','Microsoft.Cache/Redis') | project id, name, type, resourceGroup, subscriptionId, location, sku, kind, properties, tags"
    "security"            = "Resources | where type in~ ('Microsoft.KeyVault/vaults','Microsoft.ManagedIdentity/userAssignedIdentities') | project id, name, type, resourceGroup, subscriptionId, location, properties, tags"
    "rbac"                = "AuthorizationResources | where type =~ 'microsoft.authorization/roleassignments' | project id, name, roleDefinitionId=properties.roleDefinitionId, principalId=properties.principalId, principalType=properties.principalType, scope=properties.scope, subscriptionId"
    "policies"            = "PolicyResources | where type =~ 'microsoft.authorization/policyassignments' | project id, name, displayName=properties.displayName, policyDefinitionId=properties.policyDefinitionId, scope=properties.scope, parameters=properties.parameters"
    "resource-groups"     = "ResourceContainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | project id, name, location, subscriptionId, tags, managedBy"
    "networking-advanced" = "Resources | where type in~ ('Microsoft.Network/applicationGateways','Microsoft.Network/loadBalancers','Microsoft.Network/publicIPAddresses','Microsoft.Network/privateDnsZones','Microsoft.Network/dnszones') | project id, name, type, resourceGroup, subscriptionId, location, sku, properties, tags"
}

foreach ($Key in $Queries.Keys) {
    Invoke-ResourceGraphQuery -Query $Queries[$Key] -OutputFile (Join-Path $ScanDir "$Key.json")
}

# ── Summary ───────────────────────────────────────────────────────────────────
$TotalResources = (Get-Content (Join-Path $ScanDir "all-resources.json") -Raw | ConvertFrom-Json).Count

[ordered]@{
    runId                = $RunId
    timestamp            = $Timestamp
    apiVersion           = $ApiVersion
    subscriptionsScanned = $SubCount
    totalResourcesFound  = $TotalResources
    status               = "completed"
} | ConvertTo-Json | Set-Content (Join-Path $ScanDir "scan-summary.json") -Encoding UTF8

Write-Host ""
Write-Host "SCAN COMPLETE — Subscriptions: $SubCount  Resources: $TotalResources"
