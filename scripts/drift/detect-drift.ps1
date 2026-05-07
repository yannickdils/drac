#Requires -Version 7.2
# =============================================================================
# detect-drift.ps1
# Stage 4a: Compare deployed Azure state with IaC code to detect config drift.
# Idempotent: generates a fresh drift report on each run.
# Fault-tolerant: individual comparison errors are recorded, not fatal.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScanDir,
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

# Bicep files — try compile-then-match, fall back to regex
$bicepPattern = 'name:\s*[\x27\x22]([^\x27\x22\[\$\n]{2,})[\x27\x22]'
Get-ChildItem -Path $RepoRoot -Recurse -Include "*.bicep" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.git' } |
    ForEach-Object {
        $bicepFile = $_
        $compiled  = $false
        $azCmd     = Get-Command 'az' -ErrorAction SilentlyContinue
        if ($azCmd) {
            try {
                $armJson = az bicep build --stdout --file $bicepFile.FullName 2>$null
                if ($LASTEXITCODE -eq 0 -and $armJson) {
                    $tpl = $armJson | ConvertFrom-Json -ErrorAction Stop
                    foreach ($r in $tpl.resources) {
                        if ($r.name -and $r.name -notmatch '^\[') {
                            $rType = if ($r.PSObject.Properties['type']) { "$($r.type)" } else { '' }
                            $CodeResources.Add(@{ name = $r.name; type = $rType; source = 'bicep'; file = $bicepFile.FullName })
                        }
                    }
                    $compiled = $true
                }
            } catch { Write-Verbose "bicep build failed for $($bicepFile.FullName): $_" }
        }
        if (-not $compiled) {
            $src = Get-Content $bicepFile.FullName -Raw
            foreach ($m in [regex]::Matches($src, $bicepPattern)) {
                $CodeResources.Add(@{ name = $m.Groups[1].Value.Trim(); type = ''; source = 'bicep'; file = $bicepFile.FullName })
            }
        }
    }

# ARM JSON files
Get-ChildItem -Path $RepoRoot -Recurse -Include "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.git' -and $_.FullName -match '(arm|template|deploy)' } |
    Select-Object -First 100 |
    ForEach-Object {
        $armFile = $_
        try {
            $tpl = Get-Content $armFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($tpl.PSObject.Properties['resources']) {
                foreach ($r in $tpl.resources) {
                    if ($r.name -and $r.name -notmatch '^\[') {
                        $rType = if ($r.PSObject.Properties['type']) { "$($r.type)" } else { '' }
                        $CodeResources.Add(@{ name = $r.name; type = $rType; source = 'arm'; file = $armFile.FullName })
                    }
                }
            }
        } catch { Write-Verbose "Skipping $($armFile.FullName): $_" }
    }

# PowerShell files
$psPattern = '-Name\s+[\x27\x22]([^\x27\x22\n]{2,})[\x27\x22]'
Get-ChildItem -Path $RepoRoot -Recurse -Include "*.ps1","*.psm1" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.git' } |
    ForEach-Object {
        $psFile  = $_
        $src2    = Get-Content $psFile.FullName -Raw
        foreach ($m in [regex]::Matches($src2, $psPattern)) {
            $CodeResources.Add(@{ name = $m.Groups[1].Value.Trim(); type = ''; source = 'powershell'; file = $psFile.FullName })
        }
    }

# Deduplicate by (name, type) tuple
$UniqueCode = $CodeResources |
    Sort-Object   { "$($_['name'])|$($_['type'])" } |
    Group-Object  { "$($_['name'].ToLower())|$($_['type'].ToLower())" } |
    ForEach-Object { $_.Group[0] }
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
    $RType = if ($Resource.PSObject.Properties['type']) { "$($Resource.type)" } else { '' }

    $skip = $false
    foreach ($pat in $ExcludePatterns) { if ($RName -match $pat) { $skip = $true; break } }
    if ($skip) { continue }
    if ($RType -like "*extensions*") { continue }

    # Match by (name, type) — if code entry has no type, name-only is sufficient
    $InCode = @($UniqueCode | Where-Object {
        $_['name'].ToLower() -eq $RName.ToLower() -and
        ($_['type'] -eq '' -or $_['type'].ToLower() -eq $RType.ToLower())
    }).Count
    if ($InCode -eq 0) {
        $DeployedNotInCode++
        $DriftItems.Add([ordered]@{
            driftType      = "deployed-not-in-code"
            severity       = "warning"
            resourceName   = $RName
            resourceType   = $RType
            location       = if ($Resource.PSObject.Properties['location']) { $Resource.location } else { '' }
            resourceGroup  = if ($Resource.PSObject.Properties['resourceGroup']) { $Resource.resourceGroup } else { '' }
            subscriptionId = if ($Resource.PSObject.Properties['subscriptionId']) { $Resource.subscriptionId } else { '' }
            description    = "Resource exists in Azure but has no corresponding IaC definition"
            recommendation = "Add IaC definition or mark as manually managed"
        })
    } else {
        $DeployedInCode++
    }
}

# 2. Resources in code NOT deployed in Azure
foreach ($CodeRes in $UniqueCode) {
    $Found = @($AllResources | Where-Object {
        $_.name -and $_.name.ToLower() -eq $CodeRes['name'].ToLower() -and
        ($CodeRes['type'] -eq '' -or ($_.type -and $_.type.ToLower() -eq $CodeRes['type'].ToLower()))
    }).Count
    if ($Found -eq 0) {
        $CodeNotDeployed++
        $DriftItems.Add([ordered]@{
            driftType      = "in-code-not-deployed"
            severity       = "critical"
            resourceName   = $CodeRes['name']
            source         = $CodeRes['source']
            file           = $CodeRes['file']
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
} | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutputDir "drift-report.json") -Encoding UTF8

Write-Host ""
Write-Host "DRIFT DETECTION COMPLETE"
Write-Host "  Total: $TotalDrift  Critical: $CriticalDrift  Warnings: $WarningDrift"
Write-Host "  Matched (code+Azure): $DeployedInCode"