#Requires -Version 7.2
# =============================================================================
# export-arm-templates.ps1
# Stage 2a: Export ARM templates per resource group. ARM API 2021-04-01.
# Idempotent: skips already-exported resource groups in the same run.
# Fault-tolerant: per-RG failures are logged and skipped, not fatal.
#
# Large-RG path (R5.1/C1):
#   Resource groups with >150 resources are dispatched to
#   Export-LargeResourceGroup.ps1 which enumerates via Resource Graph
#   and fetches each resource individually.
#
# Unsupported-types reporting (R5.2/C2):
#   After export, scan all-resources.json for types listed in
#   data/unsupported-types.json. Log them to unsupported-resources.json
#   and write unsupported-summary.json consumed by post-pr-comment*.ps1.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScanDir,
    [string] $ArmApiVersion = "2021-04-01",
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId,
    [int]    $LargeRgThreshold = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = $PSScriptRoot
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir ".." "..")).Path

$null      = New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "arm-templates")
$null      = New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir "bicep-templates")
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$FailedRGs = [System.Collections.Generic.List[string]]::new()
$Exported  = 0
$LargeRgExported = 0
$Skipped   = 0

Write-Host "============================================================"
Write-Host "STAGE 2a: Export ARM Templates"
Write-Host "  ARM API: $ArmApiVersion  Run ID: $RunId"
Write-Host "  Large-RG threshold: $LargeRgThreshold resources"
Write-Host "============================================================"

$RgFile = Join-Path $ScanDir "resource-groups.json"
if (-not (Test-Path $RgFile)) { Write-Error "resource-groups.json not found in $ScanDir"; exit 1 }

$ResourceGroups = Get-Content $RgFile -Raw | ConvertFrom-Json
Write-Host "INFO: Processing $($ResourceGroups.Count) resource groups"

# Pre-load all-resources for per-RG counts and unsupported-type cross-reference
$AllResourcesFile = Join-Path $ScanDir "all-resources.json"
$AllResources = if (Test-Path $AllResourcesFile) {
    Get-Content $AllResourcesFile -Raw | ConvertFrom-Json
} else { @() }

# Index resource counts per "subscriptionId/resourceGroup" for the large-RG dispatch
$RgResourceCounts = @{}
foreach ($Res in $AllResources) {
    if (-not $Res.subscriptionId -or -not $Res.resourceGroup) { continue }
    $Key = "$($Res.subscriptionId)/$($Res.resourceGroup.ToLower())"
    $RgResourceCounts[$Key] = ($RgResourceCounts[$Key] ?? 0) + 1
}

foreach ($Rg in $ResourceGroups) {
    $SubId  = $Rg.subscriptionId
    $RgName = $Rg.name
    if (-not $SubId -or -not $RgName) { continue }

    $OutDir  = Join-Path $OutputDir "arm-templates" $SubId $RgName
    $TplFile = Join-Path $OutDir "template.json"

    # Idempotency: skip if already exported
    if (Test-Path $TplFile) {
        Write-Host "  SKIP (already exported): $RgName"
        $Skipped++
        continue
    }

    $null = New-Item -ItemType Directory -Force -Path $OutDir

    # ── Large-RG dispatch ──────────────────────────────────────────────────────
    $RgKey      = "$SubId/$($RgName.ToLower())"
    $RgResCount = $RgResourceCounts[$RgKey] ?? 0

    if ($RgResCount -gt $LargeRgThreshold) {
        Write-Host "  LARGE-RG ($RgResCount resources > $LargeRgThreshold): $RgName — dispatching to Export-LargeResourceGroup.ps1"
        $LargeScript = Join-Path $ScriptDir "Export-LargeResourceGroup.ps1"
        & $LargeScript `
            -SubscriptionId $SubId `
            -ResourceGroupName $RgName `
            -OutputDir $OutDir `
            -RunId $RunId `
            -ArmApiVersion $ArmApiVersion
        if ($LASTEXITCODE -eq 0 -and (Test-Path $TplFile)) {
            $LargeRgExported++
        } else {
            Write-Warning "  Large-RG export failed for $RgName"
            $FailedRGs.Add("$SubId/$RgName")
        }
        continue
    }

    # ── Standard ARM export ────────────────────────────────────────────────────
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
    $RgResources = $AllResources | Where-Object {
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

# ── Build index of all exported templates ─────────────────────────────────────
Get-ChildItem (Join-Path $OutputDir "arm-templates") -Recurse -Filter "metadata.json" |
    ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
    ConvertTo-Json -Depth 5 |
    Set-Content (Join-Path $OutputDir "export-index.json") -Encoding UTF8

# ── Unsupported-types cross-reference (R5.2/C2) ───────────────────────────────
$UnsupportedFile = Join-Path $RepoRoot "data" "unsupported-types.json"
$NeverExportTypes = @()
$PartialExportTypes = @()
if (Test-Path $UnsupportedFile) {
    $UnsupportedDef  = Get-Content $UnsupportedFile -Raw | ConvertFrom-Json
    $NeverExportTypes   = @($UnsupportedDef.neverExports   | Where-Object { $_ -and $_ -ne '_comment' })
    $PartialExportTypes = @($UnsupportedDef.partiallyExports | Where-Object { $_ })
}

$UnsupportedResources = [System.Collections.Generic.List[object]]::new()
foreach ($Res in $AllResources) {
    if (-not $Res.type) { continue }
    $ExportClass = if ($NeverExportTypes   -contains $Res.type) { "neverExports"      }
                   elseif ($PartialExportTypes -contains $Res.type) { "partiallyExports" }
                   else { $null }
    if ($ExportClass) {
        $UnsupportedResources.Add([ordered]@{
            id             = $Res.id
            name           = $Res.name
            type           = $Res.type
            resourceGroup  = $Res.resourceGroup
            subscriptionId = $Res.subscriptionId
            exportClass    = $ExportClass
        })
    }
}

$NeverCount   = @($UnsupportedResources | Where-Object { $_.exportClass -eq "neverExports"      }).Count
$PartialCount = @($UnsupportedResources | Where-Object { $_.exportClass -eq "partiallyExports" }).Count

$ReportsDir = Join-Path $OutputDir "_reports" "export"
$null = New-Item -ItemType Directory -Force -Path $ReportsDir

$UnsupportedResources | ConvertTo-Json -Depth 10 -AsArray |
    Set-Content (Join-Path $ReportsDir "unsupported-resources.json") -Encoding UTF8

[ordered]@{
    runId                = $RunId
    timestamp            = $Timestamp
    neverExports         = $NeverCount
    partiallyExports     = $PartialCount
    requiresHandAuthoredDR = $NeverCount
    unsupportedResources = $UnsupportedResources.Count
} | ConvertTo-Json | Set-Content (Join-Path $OutputDir "unsupported-summary.json") -Encoding UTF8

if ($UnsupportedResources.Count -gt 0) {
    Write-Host ""
    Write-Host "UNSUPPORTED TYPES  neverExports: $NeverCount  partiallyExports: $PartialCount"
    Write-Host "  Details: $(Join-Path $ReportsDir 'unsupported-resources.json')"
}

# ── Export summary ─────────────────────────────────────────────────────────────
$TotalExported = $Exported + $LargeRgExported
[ordered]@{
    runId                = $RunId
    timestamp            = $Timestamp
    totalResourceGroups  = $ResourceGroups.Count
    exported             = $Exported
    exportedLargeRg      = $LargeRgExported
    skipped              = $Skipped
    failed               = $FailedRGs.Count
    failedResourceGroups = $FailedRGs
} | ConvertTo-Json | Set-Content (Join-Path $OutputDir "export-summary.json") -Encoding UTF8

Write-Host ""
Write-Host "EXPORT COMPLETE  Total: $($ResourceGroups.Count)  Exported: $TotalExported  Skipped: $Skipped  Failed: $($FailedRGs.Count)"

if ($TotalExported -eq 0 -and $ResourceGroups.Count -gt 0) {
    Write-Error "All exports failed"; exit 1
}
