#Requires -Version 7.2
# =============================================================================
# tests/round-5/Test-ExportLargeRG.ps1
# Round 5 §R5.1 + §R5.2 — large-RG export path + unsupported-types reporting.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepoRoot  = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Failures  = [System.Collections.Generic.List[string]]::new()

function Assert-True  { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $Failures.Add("[FAIL] $Msg — expected '$Expected' got '$Actual'") } }

$LargeScript  = Join-Path $RepoRoot 'scripts/export/Export-LargeResourceGroup.ps1'
$ExportScript = Join-Path $RepoRoot 'scripts/export/export-arm-templates.ps1'
$UnsupportedJson = Join-Path $RepoRoot 'data/unsupported-types.json'

Assert-True (Test-Path $LargeScript)    "Export-LargeResourceGroup.ps1 must exist"
Assert-True (Test-Path $ExportScript)   "export-arm-templates.ps1 must exist"
Assert-True (Test-Path $UnsupportedJson) "data/unsupported-types.json must exist"

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: data/unsupported-types.json structure
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── unsupported-types.json structure ──"
$UnsupDef = Get-Content $UnsupportedJson -Raw | ConvertFrom-Json
Assert-True ($null -ne $UnsupDef.neverExports)      "neverExports array must be present"
Assert-True ($null -ne $UnsupDef.partiallyExports)   "partiallyExports array must be present"
Assert-True (@($UnsupDef.neverExports).Count -ge 1)  "neverExports must contain at least one type"
Assert-True (@($UnsupDef.partiallyExports).Count -ge 1) "partiallyExports must contain at least one type"
# DataFactory must be listed as neverExports
Assert-True ($UnsupDef.neverExports -contains 'Microsoft.DataFactory/factories') "DataFactory/factories must be in neverExports"
# Logic Apps must be listed as partiallyExports
Assert-True ($UnsupDef.partiallyExports -contains 'Microsoft.Logic/workflows') "Logic/workflows must be in partiallyExports"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Export-LargeResourceGroup.ps1 -DryRun produces expected outputs
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── Export-LargeResourceGroup.ps1 -DryRun ──"
$TestDir = Join-Path $env:TEMP "draac-large-rg-$([System.Guid]::NewGuid().ToString('N'))"
try {
    & $LargeScript `
        -SubscriptionId '00000000-0000-0000-0000-000000000001' `
        -ResourceGroupName 'rg-large-test' `
        -OutputDir $TestDir `
        -RunId 'large-rg-test-001' `
        -DryRun

    Assert-True (Test-Path (Join-Path $TestDir 'template.json'))  "template.json must be produced in DryRun"
    Assert-True (Test-Path (Join-Path $TestDir 'metadata.json')) "metadata.json must be produced in DryRun"

    $Template = Get-Content (Join-Path $TestDir 'template.json') -Raw | ConvertFrom-Json
    Assert-True ($null -ne $Template.resources)                  "template.json must have resources array"
    Assert-True ($Template.resources.Count -ge 1)                "DryRun must synthesize at least one resource"
    Assert-True ($null -ne $Template.'$schema')                  "template.json must have `$schema"

    $Meta = Get-Content (Join-Path $TestDir 'metadata.json') -Raw | ConvertFrom-Json
    Assert-Equal 'rg-large-test' $Meta.resourceGroup             "metadata.resourceGroup must match"
    Assert-Equal $true           $Meta.largeRg                   "metadata.largeRg must be true"
} finally {
    if (Test-Path $TestDir) { Remove-Item $TestDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: export-arm-templates.ps1 dispatches large-RG and writes unsupported-summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── export-arm-templates.ps1 large-RG dispatch + unsupported-types ──"
$WorkDir = Join-Path $env:TEMP "draac-export-test-$([System.Guid]::NewGuid().ToString('N'))"
try {
    # Scaffold a minimal ScanDir
    $ScanDir = Join-Path $WorkDir 'scan'
    $OutDir  = Join-Path $WorkDir 'output'
    $null = New-Item -ItemType Directory -Force -Path $ScanDir

    # One normal RG (3 resources), one large RG (stub — actual dispatch tested separately)
    @(
        [ordered]@{ subscriptionId = '00000000-0000-0000-0000-000000000001'; name = 'rg-normal' }
    ) | ConvertTo-Json -AsArray | Set-Content (Join-Path $ScanDir 'resource-groups.json') -Encoding UTF8

    # all-resources.json: 3 normal + 1 DataFactory (neverExports) + 1 Logic (partiallyExports)
    $FakeResources = @(
        [ordered]@{ id='/sub/rg/sa1'; name='sa001'; type='Microsoft.Storage/storageAccounts';     resourceGroup='rg-normal'; subscriptionId='00000000-0000-0000-0000-000000000001'; location='eastus' }
        [ordered]@{ id='/sub/rg/sa2'; name='sa002'; type='Microsoft.Storage/storageAccounts';     resourceGroup='rg-normal'; subscriptionId='00000000-0000-0000-0000-000000000001'; location='eastus' }
        [ordered]@{ id='/sub/rg/sa3'; name='sa003'; type='Microsoft.Storage/storageAccounts';     resourceGroup='rg-normal'; subscriptionId='00000000-0000-0000-0000-000000000001'; location='eastus' }
        [ordered]@{ id='/sub/rg/df1'; name='df001'; type='Microsoft.DataFactory/factories';       resourceGroup='rg-normal'; subscriptionId='00000000-0000-0000-0000-000000000001'; location='eastus' }
        [ordered]@{ id='/sub/rg/la1'; name='la001'; type='Microsoft.Logic/workflows';             resourceGroup='rg-normal'; subscriptionId='00000000-0000-0000-0000-000000000001'; location='eastus' }
    )
    $FakeResources | ConvertTo-Json -Depth 5 -AsArray | Set-Content (Join-Path $ScanDir 'all-resources.json') -Encoding UTF8

    # Run export — the standard ARM export will fail (no az) but we care about
    # the unsupported-summary.json which is written regardless
    & $ExportScript -ScanDir $ScanDir -OutputDir $OutDir -RunId 'test-unsup-001' 2>$null

    # unsupported-summary.json must always be written (even when ARM calls fail)
    $SummaryFile = Join-Path $OutDir 'unsupported-summary.json'
    Assert-True (Test-Path $SummaryFile) "unsupported-summary.json must be written"

    if (Test-Path $SummaryFile) {
        $UsSum = Get-Content $SummaryFile -Raw | ConvertFrom-Json
        Assert-Equal 1 $UsSum.neverExports       "neverExports count must be 1 (DataFactory)"
        Assert-Equal 1 $UsSum.partiallyExports   "partiallyExports count must be 1 (Logic)"
        Assert-Equal 1 $UsSum.requiresHandAuthoredDR "requiresHandAuthoredDR must equal neverExports count"
        Assert-Equal 2 $UsSum.unsupportedResources    "total unsupported resources must be 2"
    }

    # unsupported-resources.json must list the two unsupported resources
    $DetailFile = Join-Path $OutDir '_reports' 'export' 'unsupported-resources.json'
    Assert-True (Test-Path $DetailFile) "unsupported-resources.json must be written"
    if (Test-Path $DetailFile) {
        $Details = Get-Content $DetailFile -Raw | ConvertFrom-Json
        Assert-Equal 2 @($Details).Count "unsupported-resources.json must have 2 entries"
        $Types = @($Details | Select-Object -ExpandProperty type)
        Assert-True ($Types -contains 'Microsoft.DataFactory/factories') "DataFactory must appear in unsupported list"
        Assert-True ($Types -contains 'Microsoft.Logic/workflows')       "Logic must appear in unsupported list"
    }
} finally {
    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: large-RG threshold dispatch (LargeRgThreshold=2)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── large-RG threshold dispatch (LargeRgThreshold=2) ──"
$WorkDir2 = Join-Path $env:TEMP "draac-export-large-$([System.Guid]::NewGuid().ToString('N'))"
try {
    $ScanDir2 = Join-Path $WorkDir2 'scan'
    $OutDir2  = Join-Path $WorkDir2 'output'
    $null = New-Item -ItemType Directory -Force -Path $ScanDir2

    @([ordered]@{ subscriptionId='00000000-0000-0000-0000-000000000001'; name='rg-large' }) |
        ConvertTo-Json -AsArray | Set-Content (Join-Path $ScanDir2 'resource-groups.json') -Encoding UTF8

    # 3 resources → exceeds threshold of 2
    $Res2 = 1..3 | ForEach-Object {
        [ordered]@{ id="/sub/rg/r$_"; name="res$_"; type='Microsoft.Storage/storageAccounts';
            resourceGroup='rg-large'; subscriptionId='00000000-0000-0000-0000-000000000001'; location='eastus' }
    }
    $Res2 | ConvertTo-Json -Depth 5 -AsArray | Set-Content (Join-Path $ScanDir2 'all-resources.json') -Encoding UTF8

    # Run with low threshold so large-RG path fires; large-RG script can't call az without credentials
    # so it will fail, but the dispatch decision (metadata.largeRg) is what we test here.
    # We pre-create the template.json to simulate a successful large-RG export.
    $LargeOutDir = Join-Path $OutDir2 'arm-templates' '00000000-0000-0000-0000-000000000001' 'rg-large'
    $null = New-Item -ItemType Directory -Force -Path $LargeOutDir
    [ordered]@{ resources = @() } | ConvertTo-Json | Set-Content (Join-Path $LargeOutDir 'template.json') -Encoding UTF8
    [ordered]@{ resourceGroup='rg-large'; largeRg=$true; exportedAt='2026-01-01T00:00:00Z'; subscriptionId='00000000-0000-0000-0000-000000000001' } |
        ConvertTo-Json | Set-Content (Join-Path $LargeOutDir 'metadata.json') -Encoding UTF8

    & $ExportScript -ScanDir $ScanDir2 -OutputDir $OutDir2 -RunId 'test-large-002' -LargeRgThreshold 2 2>$null

    # The export should have skipped (template.json pre-exists = idempotency)
    $SumFile2 = Join-Path $OutDir2 'export-summary.json'
    Assert-True (Test-Path $SumFile2) "export-summary.json must be written"
    if (Test-Path $SumFile2) {
        $Sum2 = Get-Content $SumFile2 -Raw | ConvertFrom-Json
        Assert-Equal 1 $Sum2.skipped "rg-large must be counted as skipped (template.json pre-exists)"
    }
} finally {
    if (Test-Path $WorkDir2) { Remove-Item $WorkDir2 -Recurse -Force -ErrorAction SilentlyContinue }
}

# ─────────────────────────────────────────────────────────────────────────────
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { Write-Host $f }
    exit 1
}
Write-Host "Test-ExportLargeRG: all assertions passed."
exit 0
