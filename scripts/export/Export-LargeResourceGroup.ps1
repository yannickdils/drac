#Requires -Version 7.2
# =============================================================================
# Export-LargeResourceGroup.ps1
# Stage 2a (large-RG path): Export individual resources for a single resource
# group that exceeds the ARM template-export limit (~150 resources).
#
# Strategy:
#   1. Enumerate all resource IDs in the RG via Azure Resource Graph.
#   2. Fetch each resource's current state via `az resource show --ids` in batches.
#   3. Assemble a pseudo-ARM-template JSON structure matching the shape produced
#      by export-arm-templates.ps1 so downstream stages need no divergence.
#
# API versions:
#   Resource Graph  2024-04-01  https://learn.microsoft.com/en-us/rest/api/azureresourcegraph/
#   ARM resource    2021-04-01  https://learn.microsoft.com/en-us/rest/api/resources/resources/get-by-id
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId,
    [string]  $ArmApiVersion = "2021-04-01",
    [int]     $BatchSize     = 50,
    [switch]  $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$null = New-Item -ItemType Directory -Force -Path $OutputDir

Write-Host "============================================================"
Write-Host "STAGE 2a (large-RG): Export Large Resource Group"
Write-Host "  Subscription: $SubscriptionId"
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Batch size: $BatchSize  Run ID: $RunId"
if ($DryRun) { Write-Host "  DryRun: True" }
Write-Host "============================================================"

# ── Step 1: enumerate resource IDs via Resource Graph ─────────────────────────
$AllIds   = [System.Collections.Generic.List[string]]::new()
$SkipToken = $null

do {
    if ($DryRun) {
        # Synthetic IDs for test seam
        $AllIds.Add("/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/dryrunsa001")
        $AllIds.Add("/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/dryrun-vnet")
        $SkipToken = $null
        break
    }

    $Query = "resources | where resourceGroup =~ '$ResourceGroupName' and subscriptionId =~ '$SubscriptionId' | project id | order by id asc"
    $GraphBody = [ordered]@{
        query         = $Query
        subscriptions = @($SubscriptionId)
    }
    if ($SkipToken) { $GraphBody["\$skipToken"] = $SkipToken }

    try {
        $GraphUri  = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01"
        $GraphResp = az rest --method POST --uri $GraphUri `
            --body ($GraphBody | ConvertTo-Json -Compress) `
            --output json 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $GraphResp) {
            Write-Warning "Resource Graph query failed — falling back to az resource list"
            $ListResp = az resource list --resource-group $ResourceGroupName --subscription $SubscriptionId --output json 2>$null | ConvertFrom-Json
            if ($ListResp) { $ListResp | ForEach-Object { $AllIds.Add($_.id) } }
            $SkipToken = $null
            break
        }
        $GraphResp.data | ForEach-Object { $AllIds.Add($_.id) }
        $SkipToken = $GraphResp.'$skipToken'
    } catch {
        Write-Warning "Resource Graph exception: $_ — falling back to az resource list"
        $ListResp = az resource list --resource-group $ResourceGroupName --subscription $SubscriptionId --output json 2>$null | ConvertFrom-Json
        if ($ListResp) { $ListResp | ForEach-Object { $AllIds.Add($_.id) } }
        $SkipToken = $null
        break
    }
} while ($SkipToken)

Write-Host "INFO: Found $($AllIds.Count) resource IDs in $ResourceGroupName"

# ── Step 2: fetch each resource in batches ────────────────────────────────────
$Resources    = [System.Collections.Generic.List[object]]::new()
$FailedIds    = [System.Collections.Generic.List[string]]::new()
$TotalBatches = [math]::Ceiling($AllIds.Count / $BatchSize)
$BatchNum     = 0

for ($i = 0; $i -lt $AllIds.Count; $i += $BatchSize) {
    $BatchNum++
    $Batch = $AllIds[$i .. [math]::Min($i + $BatchSize - 1, $AllIds.Count - 1)]
    Write-Host "  Batch $BatchNum / $TotalBatches  ($($Batch.Count) resources)"

    foreach ($Id in $Batch) {
        if ($DryRun) {
            # Synthesize a minimal resource object
            $TypeParts  = ($Id -split '/providers/')[1] -split '/'
            $TypeNs     = $TypeParts[0]
            $TypeName   = $TypeParts[1]
            $ResName    = $TypeParts[2]
            $Resources.Add([ordered]@{
                id         = $Id
                name       = $ResName
                type       = "$TypeNs/$TypeName"
                location   = "eastus"
                properties = @{}
            })
            continue
        }

        try {
            $Resource = az resource show --ids $Id `
                --api-version $ArmApiVersion `
                --output json 2>$null | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or -not $Resource) {
                # Retry without explicit api-version (resource type may require its own)
                $Resource = az resource show --ids $Id --output json 2>$null | ConvertFrom-Json
            }
            if ($Resource) {
                $Resources.Add($Resource)
            } else {
                Write-Warning "  SKIP: could not fetch $Id"
                $FailedIds.Add($Id)
            }
        } catch {
            Write-Warning "  ERROR fetching ${Id}: $_"
            $FailedIds.Add($Id)
        }
    }
}

# ── Step 3: assemble pseudo-ARM-template ──────────────────────────────────────
# Shape matches what export-arm-templates.ps1 produces so downstream is identical.
$Template = [ordered]@{
    '$schema'        = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion   = "1.0.0.0"
    parameters       = [ordered]@{}
    variables        = [ordered]@{}
    resources        = @($Resources | ForEach-Object {
        [ordered]@{
            type       = $_.type
            apiVersion = $ArmApiVersion
            name       = $_.name
            location   = if ($_.location) { $_.location } else { "eastus" }
            properties = if ($_.properties) { $_.properties } else { [ordered]@{} }
        }
    })
    metadata         = [ordered]@{
        _generator         = "large-rg-export"
        resourceGroup      = $ResourceGroupName
        subscriptionId     = $SubscriptionId
        exportedAt         = $Timestamp
        totalResources     = $AllIds.Count
        fetchedResources   = $Resources.Count
        failedResources    = $FailedIds.Count
    }
}

$Template | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDir "template.json") -Encoding UTF8

# Metadata file (same shape as normal export)
[ordered]@{
    subscriptionId = $SubscriptionId
    resourceGroup  = $ResourceGroupName
    exportedAt     = $Timestamp
    largeRg        = $true
    totalResources = $AllIds.Count
    fetched        = $Resources.Count
    failed         = $FailedIds.Count
} | ConvertTo-Json | Set-Content (Join-Path $OutputDir "metadata.json") -Encoding UTF8

if ($FailedIds.Count -gt 0) {
    , $FailedIds | ConvertTo-Json -AsArray | Set-Content (Join-Path $OutputDir "failed-ids.json") -Encoding UTF8
    Write-Warning "  $($FailedIds.Count) resource(s) could not be fetched — see failed-ids.json"
}

Write-Host ""
Write-Host "LARGE-RG EXPORT COMPLETE"
Write-Host "  Total IDs: $($AllIds.Count)  Fetched: $($Resources.Count)  Failed: $($FailedIds.Count)"
Write-Host "  Output: $OutputDir"

if ($Resources.Count -eq 0 -and $AllIds.Count -gt 0) {
    Write-Error "No resources could be fetched from $ResourceGroupName"; exit 1
}
