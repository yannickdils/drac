# =============================================================================
# detect-drift.ps1
# Stage 4a: Compare deployed Azure state with IaC code to detect config drift.
# Idempotent: generates a fresh drift report on each run.
# Fault-tolerant: individual comparison errors are recorded, not fatal.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScanDir,
    [Parameter(Mandatory)] [string] $ExportDir,
    [Parameter(Mandatory)] [string] $ReviewDir,
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $PrId,
    [Parameter(Mandatory)] [string] $PrSourceBranch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$null      = New-Item -ItemType Directory -Force -Path $OutputDir
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "============================================================"
Write-Host "STAGE 4a: Configuration Drift Detection"
Write-Host "  PR ID: $PrId   Run ID: $RunId"
Write-Host "============================================================"

$AllResourcesFile = Join-Path $ScanDir "all-resources.json"
if (-not (Test-Path $AllResourcesFile)) { Write-Error "all-resources.json not found"; exit 1 }
$AllResources = Get-Content $AllResourcesFile -Raw | ConvertFrom-Json

# ── Collect IaC resource declarations from the repo ──────────────────────────
Write-Host "INFO: Scanning repository IaC files in $RepoRoot"

$CodeResources = [System.Collections.Generic.List[hashtable]]::new()

# Bicep files
Get-ChildItem -Path $RepoRoot -Recurse -Include "*.bicep" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.git' } |
    ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        foreach ($m in [regex]::Matches($content, "name:\s*['\`"]([^'\`"\[\$\n]{2,})['\`"]")) {
            $CodeResources.Add(@{ name = $m.Groups[1].Value.Trim(); source = "bicep"; file = $_.FullName })
        }
    }

# ARM JSON files
Get-ChildItem -Path $RepoRoot -Recurse -Include "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.git' -and $_.FullName -match '(arm|template|deploy)' } |
    Select-Object -First 100 |
    ForEach-Object {
        try {
            $tpl = Get-Content $_.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($r in $tpl.resources) {
                if ($r.name -and $r.name -notmatch '^\[') {
                    $CodeResources.Add(@{ name = $r.name; source = "arm"; file = $_.FullName })
                }
            }
        } catch {}
    }

# PowerShell files
Get-ChildItem -Path $RepoRoot -Recurse -Include "*.ps1","*.psm1" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.git' } |
    ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        foreach ($m in [regex]::Matches($content, '-Name\s+["\x27]([^"'\x27\n]{2,})["\x27]')) {
            $CodeResources.Add(@{ name = $m.Groups[1].Value.Trim(); source = "powershell"; file = $_.FullName })
        }
    }

# Deduplicate by name
$UniqueCode = $CodeResources | Sort-Object { $_.name } | Group-Object { $_.name } | ForEach-Object { $_.Group[0] }
Write-Host "INFO: Extracted $($UniqueCode.Count) resource declarations from code"

# ── Exclusion list (system-managed resources) ─────────────────────────────────
$ExcludePatterns = @("^NetworkWatcher","^DefaultResourceGroup","^cloud-shell","^AzureBackupRG")

# ── Drift items ───────────────────────────────────────────────────────────────
$DriftItems          = [System.Collections.Generic.List[object]]::new()
$DeployedInCode      = 0
$DeployedNotInCode   = 0
$CodeNotDeployed     = 0

# 1. Resources in Azure NOT in code
foreach ($Resource in $AllResources) {
    $RName = $Resource.name
    $RType = $Resource.type

    # Skip system resources
    $skip = $false
    foreach ($pat in $ExcludePatterns) { if ($RName -match $pat) { $skip = $true; break } }
    if ($skip) { continue }
    if ($RType -like "*extensions*") { continue }

    $InCode = @($UniqueCode | Where-Object { $_.name.ToLower() -eq $RName.ToLower() }).Count
    if ($InCode -eq 0) {
        $DeployedNotInCode++
        $DriftItems.Add([ordered]@{
            driftType      = "deployed-not-in-code"
            severity       = "warning"
            resourceName   = $RName
            resourceType   = $RType
            location       = $Resource.location
            resourceGroup  = $Resource.resourceGroup
            subscriptionId = $Resource.subscriptionId
            description    = "Resource exists in Azure but has no corresponding IaC definition"
            recommendation = "Add IaC definition or mark as manually managed"
        })
    } else {
        $DeployedInCode++
    }
}

# 2. Resources in code NOT deployed in Azure
foreach ($CodeRes in $UniqueCode) {
    $Found = @($AllResources | Where-Object { $_.name -and $_.name.ToLower() -eq $CodeRes.name.ToLower() }).Count
    if ($Found -eq 0) {
        $CodeNotDeployed++
        $DriftItems.Add([ordered]@{
            driftType      = "in-code-not-deployed"
            severity       = "critical"
            resourceName   = $CodeRes.name
            source         = $CodeRes.source
            file           = $CodeRes.file
            description    = "IaC defines this resource but it is not found in any Azure subscription"
            recommendation = "Deploy the resource or remove the IaC definition if obsolete"
        })
    }
}

# 3. Check deployment match report for PR-level gaps
$MatchReport = Join-Path $ReviewDir "deployment-match-report.json"
if (Test-Path $MatchReport) {
    $Report = Get-Content $MatchReport -Raw | ConvertFrom-Json
    foreach ($Result in $Report.results) {
        if ($Result.status -eq "partially-deployed") {
            $DriftItems.Add([ordered]@{
                driftType   = "partial-deployment"
                severity    = "critical"
                file        = $Result.path
                status      = $Result.status
                description = "PR file contains resources that are only partially deployed to Azure"
                recommendation = "Ensure all resources in the changed file are fully deployed before merging"
            })
        }
        if ($Result.category -notin @("not-iac","other") -and
            $Result.status -in @("not-deployed","no-resources-extracted")) {
            $DriftItems.Add([ordered]@{
                driftType   = "pr-change-not-deployed"
                severity    = "critical"
                file        = $Result.path
                category    = $Result.category
                description = "This PR modifies an IaC file, but no matching deployed resources were found in Azure"
                recommendation = "Deploy the changes to Azure before merging, or verify resource naming conventions"
            })
        }
    }
}

$TotalDrift    = $DriftItems.Count
$CriticalDrift = ($DriftItems | Where-Object { $_.severity -eq "critical" }).Count
$WarningDrift  = ($DriftItems | Where-Object { $_.severity -eq "warning"  }).Count

[ordered]@{
    runId        = $RunId
    prId         = $PrId
    sourceBranch = $PrSourceBranch
    timestamp    = $Timestamp
    summary      = [ordered]@{
        totalDriftItems    = $TotalDrift
        critical           = $CriticalDrift
        warnings           = $WarningDrift
        deployedAndInCode  = $DeployedInCode
        deployedNotInCode  = $DeployedNotInCode
        inCodeNotDeployed  = $CodeNotDeployed
    }
    driftItems = $DriftItems
} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDir "drift-report.json") -Encoding UTF8

Write-Host ""
Write-Host "DRIFT DETECTION COMPLETE"
Write-Host "  Total: $TotalDrift  Critical: $CriticalDrift  Warnings: $WarningDrift"
Write-Host "  Matched (code+Azure): $DeployedInCode"
