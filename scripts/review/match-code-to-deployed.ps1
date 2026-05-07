#Requires -Version 7.2
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

# ── Extract resource name+type objects from Bicep (compile-then-match) ────────
function Get-BicepResourceName([string]$File) {
    if (-not (Test-Path $File)) { return @() }

    # Try compile path first — most accurate
    $azCmd = Get-Command 'az' -ErrorAction SilentlyContinue
    if ($azCmd) {
        try {
            $armJson = az bicep build --stdout --file $File 2>$null
            if ($LASTEXITCODE -eq 0 -and $armJson) {
                $tpl = $armJson | ConvertFrom-Json -ErrorAction Stop
                $compiledEntries = @(
                    $tpl.resources |
                        Where-Object { $_.name -and $_.name -notmatch '^\[' } |
                        Select-Object -Property name, type
                )
                # Regex fallback only for resources with ARM-expression names (runtime-only)
                $regexEntries = @()
                if ($tpl.resources | Where-Object { $_.name -match '^\[' }) {
                    $src = Get-Content $File -Raw
                    foreach ($m in [regex]::Matches($src, 'name:\s*[\x27\x22]([^\x27\x22\[$\n]+)[\x27\x22]')) {
                        $regexEntries += [PSCustomObject]@{ name = $m.Groups[1].Value.Trim(); type = '' }
                    }
                }
                return @($compiledEntries + $regexEntries)
            }
        } catch { Write-Verbose "bicep build failed for ${File}: $_" }
    }

    # Regex fallback (no bicep CLI or compile failed)
    $src     = Get-Content $File -Raw
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($src, 'name:\s*[\x27\x22]([^\x27\x22\[$\n]+)[\x27\x22]')) {
        $entries.Add([PSCustomObject]@{ name = $m.Groups[1].Value.Trim(); type = '' })
    }
    return $entries.ToArray()
}

# ── Extract resource name+type objects from ARM JSON ──────────────────────────
function Get-ArmResourceName([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    try {
        $tpl = Get-Content $File -Raw | ConvertFrom-Json
        return @(
            $tpl.resources |
                Where-Object { $_.name -and $_.name -notmatch '^\[' } |
                Select-Object -Property name, type
        )
    } catch { return @() }
}

# ── Extract resource name objects from PowerShell (type unknown) ──────────────
function Get-PsResourceName([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    $src     = Get-Content $File -Raw
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($src, '-Name\s+"([^"]+)"')) {
        $entries.Add([PSCustomObject]@{ name = $m.Groups[1].Value.Trim(); type = '' })
    }
    foreach ($m in [regex]::Matches($src, "-Name\s+'([^']+)'")) {
        $entries.Add([PSCustomObject]@{ name = $m.Groups[1].Value.Trim(); type = '' })
    }
    return $entries.ToArray()
}

# ── Find a resource in the scan by (name, type) tuple ────────────────────────
# When `$Type` is non-empty, requires exact type match (no name-only fallback).
# When `$Type` is empty, uses name-only matching (type unavailable from code).
function Find-InScan([string]$Name, [string]$Type = '') {
    if ($Type) {
        # Strict tuple match — type must also agree
        return ,@($AllResources | Where-Object {
            $_.name -and $_.name.ToLower() -eq $Name.ToLower() -and
            $_.type -and $_.type.ToLower() -eq $Type.ToLower()
        })
    }
    # Name-only match when no type info is available from code extraction
    return ,@($AllResources | Where-Object { $_.name -and $_.name.ToLower() -eq $Name.ToLower() })
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

    $ResourceEntries = @(switch ($Category) {
        'bicep'        { Get-BicepResourceName $Path }
        'arm-template' { Get-ArmResourceName   $Path }
        'powershell'   { Get-PsResourceName    $Path }
        default        { }
    })

    if ($Category -eq 'other' -or ($Category -notin @('bicep','arm-template','powershell','config-json'))) {
        $NotIaC++
        $Results.Add([ordered]@{
            path = $Path; category = $Category; status = 'not-iac'
            deploymentVerified = $null; resources = @()
        })
        continue
    }

    $FileResults = [System.Collections.Generic.List[object]]::new()
    $AllFound    = $true
    $AnyFound    = $false

    foreach ($ResEntry in $ResourceEntries) {
        $ResName = if ($ResEntry -is [string]) { $ResEntry } else { $ResEntry.name }
        $ResType = if ($ResEntry -is [string]) { '' }         else { "$($ResEntry.type)" }
        $ResName = $ResName.Trim()
        if (-not $ResName) { continue }

        $FoundResources = Find-InScan $ResName $ResType
        if ($FoundResources.Count -gt 0) {
            $AnyFound = $true
            $FileResults.Add([ordered]@{ name = $ResName; type = $ResType; foundInAzure = $true;  details = $FoundResources[0] })
        } else {
            $AllFound = $false
            $FileResults.Add([ordered]@{ name = $ResName; type = $ResType; foundInAzure = $false; details = $null })
        }
    }

    if ($FileResults.Count -eq 0) {
        $Unmatched++
        $Status = 'no-resources-extracted'
    } elseif ($AllFound) {
        $Matched++
        $Status = 'all-deployed'
    } elseif ($AnyFound) {
        $Unmatched++
        $Status = 'partially-deployed'
    } else {
        $Unmatched++
        $Status = 'not-deployed'
    }

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
    [math]::Floor($Matched / ($Matched + $Unmatched) * 100).ToString() + '%'
} else { 'N/A' }

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
} | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutputDir 'deployment-match-report.json') -Encoding UTF8

Write-Host "REVIEW COMPLETE  Matched: $Matched  Unmatched: $Unmatched  Non-IaC: $NotIaC"
