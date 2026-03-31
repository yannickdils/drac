# =============================================================================
# generate-dr-config.ps1
# Stage 5a: Generate DR-ready Bicep templates for a secondary region.
# Transforms exported ARM templates: location, VNet CIDR, naming prefix.
# Idempotent: same inputs always produce same outputs.
# Fault-tolerant: per-RG failures are tracked individually.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ExportDir,
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $DrRegion,
    [Parameter(Mandatory)] [string] $DrVnetPrefix,
    [Parameter(Mandatory)] [string] $DrSubnetPrefix,
    [string] $DrNamingPrefix = "dr-",
    [Parameter(Mandatory)] [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$null        = New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "arm")
$null        = New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "bicep")
$Timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$DateDisplay = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$Processed   = 0
$Failed      = 0

Write-Host "============================================================"
Write-Host "STAGE 5a: Generate DR Configuration"
Write-Host "  DR Region:     $DrRegion"
Write-Host "  VNet Prefix:   $DrVnetPrefix"
Write-Host "  Subnet Prefix: $DrSubnetPrefix"
Write-Host "  Name Prefix:   $DrNamingPrefix"
Write-Host "  Run ID:        $RunId"
Write-Host "============================================================"

# ── Recursive ARM template transformation ─────────────────────────────────────
function ConvertTo-DrTemplate {
    param($Node)

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $Props = $Node.PSObject.Properties
        $New   = [PSCustomObject]@{}
        foreach ($P in $Props) {
            $Val = switch ($P.Name) {
                "location"        { $DrRegion }
                "addressPrefixes" { @($DrVnetPrefix) }
                "addressPrefix"   { $DrSubnetPrefix }
                "name" {
                    if ($P.Value -is [string] -and -not $P.Value.StartsWith($DrNamingPrefix) -and
                        $P.Value -notmatch '^\[' -and $P.Value.Length -gt 1) {
                        "$DrNamingPrefix$($P.Value)"
                    } else { $P.Value }
                }
                default { ConvertTo-DrTemplate $P.Value }
            }
            $New | Add-Member -NotePropertyName $P.Name -NotePropertyValue $Val
        }
        return $New
    } elseif ($Node -is [array]) {
        return @($Node | ForEach-Object { ConvertTo-DrTemplate $_ })
    } else {
        return $Node
    }
}

# ── Process one resource group ────────────────────────────────────────────────
function Export-DrResourceGroup {
    param([string]$SubId, [string]$SrcRg, [string]$TplFile)

    $DrRg    = "$DrNamingPrefix$SrcRg"
    $OutDir  = Join-Path $OutputDir "arm" $SubId $DrRg
    $null    = New-Item -ItemType Directory -Force -Path $OutDir

    Write-Host "  Transforming: $SrcRg -> $DrRg ($DrRegion)"

    try {
        $Template    = Get-Content $TplFile -Raw | ConvertFrom-Json
        $DrTemplate  = ConvertTo-DrTemplate $Template

        # Add DR metadata parameter
        if (-not $DrTemplate.parameters) { $DrTemplate | Add-Member -NotePropertyName "parameters" -NotePropertyValue ([PSCustomObject]@{}) }
        $DrTemplate.parameters | Add-Member -NotePropertyName "drRegion" -NotePropertyValue ([PSCustomObject]@{
            type         = "string"
            defaultValue = $DrRegion
            metadata     = [PSCustomObject]@{ description = "Disaster recovery target region" }
        }) -Force

        # Save ARM
        $DrTemplate | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $OutDir "template.json") -Encoding UTF8

        # Parameters file
        [PSCustomObject]@{
            '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
            contentVersion = "1.0.0.0"
            parameters     = [PSCustomObject]@{
                location            = [PSCustomObject]@{ value = $DrRegion }
                resourceGroupName   = [PSCustomObject]@{ value = $DrRg }
                vnetAddressPrefix   = [PSCustomObject]@{ value = $DrVnetPrefix }
                subnetAddressPrefix = [PSCustomObject]@{ value = $DrSubnetPrefix }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir "parameters.json") -Encoding UTF8

        # Bicep decompile
        $BicepDir = Join-Path $OutputDir "bicep" $SubId $DrRg
        $null = New-Item -ItemType Directory -Force -Path $BicepDir
        az bicep decompile --file (Join-Path $OutDir "template.json") --outdir $BicepDir 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  INFO: Bicep decompile skipped for DR $DrRg" }

        # Deploy script
        $DeployScript = @"
#!/usr/bin/env pwsh
# Auto-generated DR deployment script - $DrRg in $DrRegion
# Generated: $DateDisplay | Run: $RunId
param([switch]`$Deploy)

`$SubscriptionId = '$SubId'
`$DrRg           = '$DrRg'
`$DrRegion       = '$DrRegion'

Write-Host "DR Deployment: `$DrRg -> `$DrRegion"

az group create --name `$DrRg --location `$DrRegion --subscription `$SubscriptionId ``
    --tags environment=dr source-rg=$SrcRg generated-by=draac-pipeline

az deployment group what-if ``
    --resource-group `$DrRg --template-file template.json ``
    --parameters parameters.json --subscription `$SubscriptionId

if (`$Deploy) {
    az deployment group create ``
        --resource-group `$DrRg --template-file template.json ``
        --parameters parameters.json --subscription `$SubscriptionId --mode Incremental
}
"@
        $DeployScript | Set-Content (Join-Path $OutDir "deploy-dr.ps1") -Encoding UTF8

        # Metadata
        [ordered]@{
            subscriptionId    = $SubId
            sourceResourceGroup = $SrcRg
            drResourceGroup   = $DrRg
            drRegion          = $DrRegion
            generatedAt       = $Timestamp
        } | ConvertTo-Json | Set-Content (Join-Path $OutDir "dr-metadata.json") -Encoding UTF8

        return $true
    } catch {
        Write-Warning "  DR transform failed for $SrcRg`: $_"
        return $false
    }
}

# ── Process all exported resource groups ──────────────────────────────────────
$IndexFile = Join-Path $ExportDir "export-index.json"
if (-not (Test-Path $IndexFile)) { Write-Error "export-index.json not found"; exit 1 }
$Index = Get-Content $IndexFile -Raw | ConvertFrom-Json

foreach ($Entry in $Index) {
    $SubId   = $Entry.subscriptionId
    $RgName  = $Entry.resourceGroup
    $TplFile = Join-Path $ExportDir "arm-templates" $SubId $RgName "template.json"

    if (-not (Test-Path $TplFile)) { Write-Host "  SKIP: No template for $RgName"; continue }

    if (Export-DrResourceGroup -SubId $SubId -SrcRg $RgName -TplFile $TplFile) {
        $Processed++
    } else {
        $Failed++
    }
}

# DR index
Get-ChildItem (Join-Path $OutputDir "arm") -Recurse -Filter "dr-metadata.json" |
    ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
    ConvertTo-Json -Depth 5 |
    Set-Content (Join-Path $OutputDir "dr-index.json") -Encoding UTF8

# DR README
$DrRgCount = (Get-Content (Join-Path $OutputDir "dr-index.json") -Raw | ConvertFrom-Json).Count
@"
# Disaster Recovery Configuration

> **Generated:** $DateDisplay  
> **Pipeline Run:** ``$RunId``  
> **Target Region:** ``$DrRegion``

## Overview

This directory contains auto-generated DR configurations for **$DrRgCount** resource group(s).
Each subfolder contains:

- ``template.json`` — ARM template adapted for the DR region
- ``parameters.json`` — DR-specific parameter values
- ``deploy-dr.ps1`` — PowerShell deployment script (what-if by default; pass -Deploy to activate)
- ``dr-metadata.json`` — Transformation metadata

## Network Configuration

| Parameter | Value |
|---|---|
| DR Region | ``$DrRegion`` |
| VNet Address Space | ``$DrVnetPrefix`` |
| Subnet Prefix | ``$DrSubnetPrefix`` |
| Naming Convention | Resources prefixed with ``$DrNamingPrefix`` |

## ⚠️ Manual Review Required

- Secrets are **not included** — inject via Key Vault or pipeline secrets
- Review private endpoint configurations for the DR region
- Update DNS records and Traffic Manager after DR deployment
- Verify hub-spoke topology is replicated

---
_Auto-generated. Do not edit manually._
"@ | Set-Content (Join-Path $OutputDir "DR-README.md") -Encoding UTF8

[ordered]@{
    runId     = $RunId
    timestamp = $Timestamp
    drRegion  = $DrRegion
    processed = $Processed
    failed    = $Failed
} | ConvertTo-Json | Set-Content (Join-Path $OutputDir "dr-summary.json") -Encoding UTF8

Write-Host ""
Write-Host "DR GENERATION COMPLETE  Processed: $Processed  Failed: $Failed  Region: $DrRegion"
