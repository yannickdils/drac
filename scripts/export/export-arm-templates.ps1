#Requires -Version 7.2
# =============================================================================
# export-arm-templates.ps1
# Stage 2a: Export ARM templates per resource group. ARM API 2021-04-01.
# Idempotent: skips already-exported resource groups in the same run.
# Fault-tolerant: per-RG failures are logged and skipped, not fatal.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScanDir,
    [string] $ArmApiVersion = "2021-04-01",
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$null      = New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "arm-templates")
$null      = New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "bicep-templates")
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$FailedRGs = [System.Collections.Generic.List[string]]::new()
$Exported  = 0
$Skipped   = 0

Write-Host "============================================================"
Write-Host "STAGE 2a: Export ARM Templates"
Write-Host "  ARM API: $ArmApiVersion  Run ID: $RunId"
Write-Host "============================================================"

$RgFile = Join-Path $ScanDir "resource-groups.json"
if (-not (Test-Path $RgFile)) { Write-Error "resource-groups.json not found in $ScanDir"; exit 1 }

$ResourceGroups = Get-Content $RgFile -Raw | ConvertFrom-Json
Write-Host "INFO: Processing $($ResourceGroups.Count) resource groups"

foreach ($Rg in $ResourceGroups) {
    $SubId  = $Rg.subscriptionId
    $RgName = $Rg.name
    if (-not $SubId -or -not $RgName) { continue }

    $OutDir = Join-Path $OutputDir "arm-templates" $SubId $RgName
    $TplFile = Join-Path $OutDir "template.json"

    # Idempotency: skip if already exported
    if (Test-Path $TplFile) {
        Write-Host "  SKIP (already exported): $RgName"
        $Skipped++
        continue
    }

    $null = New-Item -ItemType Directory -Force -Path $OutDir
    Write-Host "  Exporting: $RgName (sub: $SubId)"

    # Set subscription context
    $null = az account set --subscription $SubId 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Could not set subscription $SubId — skipping $RgName"
        $FailedRGs.Add("$SubId/$RgName"); continue
    }

    # Export via ARM REST API
    $Uri  = "https://management.azure.com/subscriptions/$SubId/resourcegroups/$RgName/exportTemplate?api-version=$ArmApiVersion"
    $Body = '{"resources":["*"],"options":"IncludeParameterDefaultValue,IncludeComments,SkipResourceNameParameterization"}'

    try {
        $Response = az rest --method POST --uri $Uri --body $Body --output json 2>$null | ConvertFrom-Json
    } catch {
        Write-Warning "  Export failed for $RgName — $_ "
        $FailedRGs.Add("$SubId/$RgName"); continue
    }

    # Save template
    ($Response.template ?? $Response) | ConvertTo-Json -Depth 30 | Set-Content $TplFile -Encoding UTF8

    # Save export errors if any
    if ($Response.error) {
        $Response.error | ConvertTo-Json | Set-Content (Join-Path $OutDir "export-errors.json") -Encoding UTF8
        Write-Warning "  Partial export for $RgName — see export-errors.json"
    }

    # Save resource list from scan for cross-reference
    $AllResources = Get-Content (Join-Path $ScanDir "all-resources.json") -Raw | ConvertFrom-Json
    $RgResources  = $AllResources | Where-Object {
        $_.resourceGroup -and $_.resourceGroup.ToLower() -eq $RgName.ToLower() -and $_.subscriptionId -eq $SubId
    }
    $RgResources | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutDir "resources.json") -Encoding UTF8

    # Attempt Bicep decompile (best-effort)
    $BicepDir = Join-Path $OutputDir "bicep-templates" $SubId $RgName
    $null = New-Item -ItemType Directory -Force -Path $BicepDir
    az bicep decompile --file $TplFile --outdir $BicepDir 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "  INFO: Bicep decompile skipped for $RgName (non-critical)" }

    # Metadata
    [ordered]@{ subscriptionId = $SubId; resourceGroup = $RgName; exportedAt = $Timestamp } |
        ConvertTo-Json | Set-Content (Join-Path $OutDir "metadata.json") -Encoding UTF8

    $Exported++
}

# Build index of all exported templates
Get-ChildItem (Join-Path $OutputDir "arm-templates") -Recurse -Filter "metadata.json" |
    ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
    ConvertTo-Json -Depth 5 |
    Set-Content (Join-Path $OutputDir "export-index.json") -Encoding UTF8

# Summary
[ordered]@{
    runId                = $RunId
    timestamp            = $Timestamp
    totalResourceGroups  = $ResourceGroups.Count
    exported             = $Exported
    skipped              = $Skipped
    failed               = $FailedRGs.Count
    failedResourceGroups = $FailedRGs
} | ConvertTo-Json | Set-Content (Join-Path $OutputDir "export-summary.json") -Encoding UTF8

Write-Host ""
Write-Host "EXPORT COMPLETE  Total: $($ResourceGroups.Count)  Exported: $Exported  Skipped: $Skipped  Failed: $($FailedRGs.Count)"

if ($Exported -eq 0 -and $ResourceGroups.Count -gt 0) {
    Write-Error "All exports failed"; exit 1
}
