#Requires -Version 7.2
# =============================================================================
# tests/round-1/Test-GenerateDrConfig-Smoke.ps1
# Smoke test for the full generate-dr-config.ps1 wrapper after the Round 1
# rewire. Builds a synthetic ExportDir from existing fixtures, runs the script,
# and asserts the expected output files exist with sane content.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Fixtures   = Join-Path $RepoRoot 'tests/fixtures/exports'
$Workdir    = Join-Path $env:TEMP "draac-smoke-$([guid]::NewGuid().ToString('N'))"
$ExportDir  = Join-Path $Workdir 'export'
$OutputDir  = Join-Path $Workdir 'dr'
$SubId      = '00000000-0000-0000-0000-000000000000'

$Failures = [System.Collections.Generic.List[string]]::new()
function Assert-True { param([bool]$c, [string]$msg) if (-not $c) { $Failures.Add("[FAIL] $msg") } }

try {
    # Build an ExportDir matching what export-arm-templates.ps1 would emit.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $ExportDir "arm-templates" $SubId)
    $rgs = @('simple-rg','peered-vnet-rg')   # subset is enough for smoke
    $indexEntries = @()
    foreach ($rg in $rgs) {
        $rgDir = Join-Path $ExportDir "arm-templates" $SubId $rg
        $null = New-Item -ItemType Directory -Force -Path $rgDir
        Copy-Item (Join-Path $Fixtures $rg 'template.json') (Join-Path $rgDir 'template.json')
        $indexEntries += [PSCustomObject]@{ subscriptionId = $SubId; resourceGroup = $rg }
    }
    $indexEntries | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ExportDir 'export-index.json') -Encoding UTF8

    # Invoke the rewired generate-dr-config.ps1.
    & (Join-Path $RepoRoot 'scripts/dr/generate-dr-config.ps1') `
        -ExportDir $ExportDir `
        -OutputDir $OutputDir `
        -DrRegion 'northeurope' `
        -DrVnetPrefix '10.100.0.0/16' `
        -DrSubnetPrefix '10.100.0.0/24' `
        -RunId 'smoke-test-001' | Out-Null

    # Assert summary + index + flags exist.
    Assert-True (Test-Path (Join-Path $OutputDir 'dr-summary.json')) 'smoke: dr-summary.json exists'
    Assert-True (Test-Path (Join-Path $OutputDir 'dr-index.json'))   'smoke: dr-index.json exists'
    Assert-True (Test-Path (Join-Path $OutputDir 'flags.json'))      'smoke: flags.json exists'
    Assert-True (Test-Path (Join-Path $OutputDir 'DR-README.md'))    'smoke: DR-README.md exists'

    # Assert per-RG outputs.
    foreach ($rg in $rgs) {
        $drRg  = "dr-$rg"
        $rgOut = Join-Path $OutputDir "arm" $SubId $drRg
        Assert-True (Test-Path (Join-Path $rgOut 'template.json'))   "smoke: $drRg template.json exists"
        Assert-True (Test-Path (Join-Path $rgOut 'parameters.json')) "smoke: $drRg parameters.json exists"
        Assert-True (Test-Path (Join-Path $rgOut 'deploy-dr.ps1'))   "smoke: $drRg deploy-dr.ps1 exists"
        Assert-True (Test-Path (Join-Path $rgOut 'dr-metadata.json'))"smoke: $drRg dr-metadata.json exists"

        # Sanity: the transformed template includes the DR-prefixed RG resources.
        $tpl = Get-Content (Join-Path $rgOut 'template.json') -Raw | ConvertFrom-Json -Depth 50
        $names = @($tpl.resources | ForEach-Object { $_.name })
        $hasDrName = $false
        foreach ($n in $names) {
            if ($n -is [string] -and $n.StartsWith('dr-')) { $hasDrName = $true; break }
        }
        Assert-True $hasDrName "smoke: $drRg template contains at least one dr- prefixed resource name"
    }

    $summary = Get-Content (Join-Path $OutputDir 'dr-summary.json') -Raw | ConvertFrom-Json
    Assert-True ($summary.processed -eq $rgs.Count) "smoke: summary.processed == $($rgs.Count)"
    Assert-True ($summary.failed    -eq 0)          'smoke: summary.failed == 0'
    Assert-True ($summary.transform -eq 'ConvertForDR.psm1') 'smoke: summary.transform identifies the module'

    # Round 4 §R4.1 dispatch consumer assertions:
    # simple-rg fixture has a Microsoft.Storage/storageAccounts (registered family),
    # so it must produce a dispatched-modules Bicep file and a non-empty dispatched array.
    Assert-True ($null -ne $summary.PSObject.Properties['totalDispatched']) "smoke: summary has totalDispatched field"
    Assert-True ($summary.totalDispatched -ge 1) "smoke: at least one dispatched resource (storage in simple-rg)"

    $simpleDrRg     = 'dr-simple-rg'
    $simpleDispatch = Join-Path $OutputDir "arm" $SubId $simpleDrRg "$simpleDrRg-dispatched-modules.bicep"
    Assert-True (Test-Path $simpleDispatch) "smoke: $simpleDrRg-dispatched-modules.bicep exists"
    if (Test-Path $simpleDispatch) {
        $bicep = Get-Content $simpleDispatch -Raw
        Assert-True ($bicep -match "module .+'\.\./\.\./modules/dr-storage\.bicep'") "smoke: dispatched bicep references dr-storage.bicep at canonical path"
        Assert-True ($bicep -match 'targetScope = ''resourceGroup''') "smoke: dispatched bicep declares resourceGroup scope"
        Assert-True ($bicep -match 'TODO:') "smoke: dispatched bicep contains TODO markers for operator review"
    }

    $metaPath = Join-Path $OutputDir "arm" $SubId $simpleDrRg 'dr-metadata.json'
    if (Test-Path $metaPath) {
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        Assert-True ($null -ne $meta.PSObject.Properties['dispatched']) "smoke: dr-metadata.json has dispatched array"
        Assert-True (@($meta.dispatched).Count -ge 1) "smoke: dr-metadata.json dispatched array non-empty for simple-rg"
    }

    # peered-vnet-rg has no registered-family resources — must NOT produce a dispatched bicep file.
    $peeredDrRg     = 'dr-peered-vnet-rg'
    $peeredDispatch = Join-Path $OutputDir "arm" $SubId $peeredDrRg "$peeredDrRg-dispatched-modules.bicep"
    Assert-True (-not (Test-Path $peeredDispatch)) "smoke: peered-vnet-rg has no registered families → no dispatched bicep emitted"
}
finally {
    if (Test-Path $Workdir) { Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue }
}

if ($Failures.Count -eq 0) {
    Write-Host "smoke: all assertions passed."
    exit 0
} else {
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
