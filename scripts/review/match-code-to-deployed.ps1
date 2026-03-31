# =============================================================================
# match-code-to-deployed.ps1
# Stage 3b: Match PR code changes to deployed Azure resources.
# Idempotent: deterministic matching logic.
# Fault-tolerant: unmatched resources are reported, not fatal.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PrChangesFile,
    [Parameter(Mandatory)] [string] $ScanDir,
    [Parameter(Mandatory)] [string] $ExportDir,
    [Parameter(Mandatory)] [string] $OutputDir,
    [Parameter(Mandatory)] [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$null      = New-Item -ItemType Directory -Force -Path $OutputDir
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "============================================================"
Write-Host "STAGE 3b: Match Code Changes to Deployed Resources"
Write-Host "  Run ID: $RunId"
Write-Host "============================================================"

$AllResourcesFile = Join-Path $ScanDir "all-resources.json"
if (-not (Test-Path $AllResourcesFile)) { Write-Error "all-resources.json not found"; exit 1 }
if (-not (Test-Path $PrChangesFile))    { Write-Error "pr-changes.json not found";    exit 1 }

$AllResources = Get-Content $AllResourcesFile -Raw | ConvertFrom-Json
$Changes      = Get-Content $PrChangesFile    -Raw | ConvertFrom-Json

# ── Extract resource names from Bicep ────────────────────────────────────────
function Get-BicepResourceNames([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    $content = Get-Content $File -Raw
    $names   = [System.Collections.Generic.List[string]]::new()
    # name: 'literal'  or  name: "literal"
    foreach ($m in [regex]::Matches($content, "name:\s*['\`"]([^'\`"\[\$\n]+)['\`"]")) {
        $names.Add($m.Groups[1].Value.Trim())
    }
    return $names
}

# ── Extract resource names from ARM JSON ──────────────────────────────────────
function Get-ArmResourceNames([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    try {
        $tpl = Get-Content $File -Raw | ConvertFrom-Json
        return $tpl.resources | Where-Object { $_.name -and $_.name -notmatch '^\[' } |
               Select-Object -ExpandProperty name
    } catch { return @() }
}

# ── Extract resource names from PowerShell ───────────────────────────────────
function Get-PsResourceNames([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    $content = Get-Content $File -Raw
    $names   = [System.Collections.Generic.List[string]]::new()
    # -Name "value"  or  -ResourceGroupName "value"  etc.
    foreach ($m in [regex]::Matches($content, '-Name\s+"([^"]+)"')) {
        $names.Add($m.Groups[1].Value.Trim())
    }
    foreach ($m in [regex]::Matches($content, "-Name\s+'([^']+)'")) {
        $names.Add($m.Groups[1].Value.Trim())
    }
    return $names
}

# ── Check if a resource name exists in the scan ───────────────────────────────
function Find-InScan([string]$Name) {
    return @($AllResources | Where-Object { $_.name -and $_.name.ToLower() -eq $Name.ToLower() })
}

# ── Process each change ───────────────────────────────────────────────────────
$Results   = [System.Collections.Generic.List[object]]::new()
$Matched   = 0
$Unmatched = 0
$NotIaC    = 0

foreach ($Change in $Changes) {
    $Path     = $Change.path
    $Category = $Change.category
    $RgHint   = $Change.resourceGroupHint

    $ResourceNames = switch ($Category) {
        "bicep"        { Get-BicepResourceNames $Path }
        "arm-template" { Get-ArmResourceNames   $Path }
        "powershell"   { Get-PsResourceNames     $Path }
        default        { @() }
    }

    if ($Category -eq "other" -or ($Category -notin @("bicep","arm-template","powershell","config-json"))) {
        $NotIaC++
        $Results.Add([ordered]@{
            path = $Path; category = $Category; status = "not-iac"
            deploymentVerified = $null; resources = @()
        })
        continue
    }

    $FileResults = [System.Collections.Generic.List[object]]::new()
    $AllFound    = $true
    $AnyFound    = $false

    foreach ($Name in $ResourceNames) {
        $Name = $Name.Trim()
        if (-not $Name) { continue }
        $Matches = Find-InScan $Name
        if ($Matches.Count -gt 0) {
            $AnyFound = $true
            $FileResults.Add([ordered]@{ name = $Name; foundInAzure = $true;  details = $Matches[0] })
        } else {
            $AllFound = $false
            $FileResults.Add([ordered]@{ name = $Name; foundInAzure = $false; details = $null })
        }
    }

    $Status = if ($FileResults.Count -eq 0) { "no-resources-extracted"; $Unmatched++ }
              elseif ($AllFound)             { "all-deployed";            $Matched++   }
              elseif ($AnyFound)             { "partially-deployed";      $Unmatched++ }
              else                           { "not-deployed";             $Unmatched++ }

    $Results.Add([ordered]@{
        path               = $Path
        category           = $Category
        status             = $Status
        deploymentVerified = $AnyFound
        resourceGroupHint  = $RgHint
        resources          = $FileResults
    })
}

$Coverage = if (($Matched + $Unmatched) -gt 0) {
    [math]::Floor($Matched / ($Matched + $Unmatched) * 100).ToString() + "%"
} else { "N/A" }

[ordered]@{
    runId     = $RunId
    timestamp = $Timestamp
    summary   = [ordered]@{
        matched            = $Matched
        unmatched          = $Unmatched
        notIacFiles        = $NotIaC
        deploymentCoverage = $Coverage
    }
    results = $Results
} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDir "deployment-match-report.json") -Encoding UTF8

Write-Host "REVIEW COMPLETE  Matched: $Matched  Unmatched: $Unmatched  Non-IaC: $NotIaC"
