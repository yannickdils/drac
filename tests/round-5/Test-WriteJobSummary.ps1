#Requires -Version 7.2
# =============================================================================
# tests/round-5/Test-WriteJobSummary.ps1
# Round 5 §E1-E3 — write-job-summary.ps1 reporting polish.
#
# Verifies that the updated summary script:
#  - Emits DR health status, checks-passed, and requires-hand-authored-DR rows
#  - Emits an Overall Severity row in the Drift section
#  - Works when optional $ExportDir is omitted (defaults to empty string → no unsupported-summary.json)
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepoRoot    = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$SummaryScript = Join-Path $RepoRoot 'scripts/report/write-job-summary.ps1'
$Failures      = [System.Collections.Generic.List[string]]::new()

function Assert-True  { param([bool]$Cond, [string]$Msg) if (-not $Cond) { $Failures.Add("[FAIL] $Msg") } }
function Assert-Equal { param($Expected, $Actual, [string]$Msg) if ($Expected -ne $Actual) { $Failures.Add("[FAIL] $Msg — expected '$Expected' got '$Actual'") } }

Assert-True (Test-Path $SummaryScript) "write-job-summary.ps1 must exist"

function New-TempDir {
    $Dir = Join-Path $env:TEMP "draac-summary-$([System.Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Force -Path $Dir
    return $Dir
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 — Full report: DR health + DriftSeverity + RequiresHandAuthoredDR
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── write-job-summary: full report with DrHealth + unsupported-types ──"
$T1 = New-TempDir
try {
    $ScanDir   = Join-Path $T1 'scan'
    $ReviewDir = Join-Path $T1 'review'
    $DriftDir  = Join-Path $T1 'drift'
    $DrDir     = Join-Path $T1 'dr'
    $ExportDir = Join-Path $T1 'export'
    $null = New-Item -ItemType Directory -Force -Path $ScanDir, $ReviewDir, $DriftDir, $DrDir, $ExportDir

    # Scan summary
    [ordered]@{ subscriptionsScanned = 2; totalResourcesFound = 150 } |
        ConvertTo-Json | Set-Content (Join-Path $ScanDir 'scan-summary.json') -Encoding UTF8

    # Match report
    [ordered]@{ summary = [ordered]@{ matched=10; unmatched=2; deploymentCoverage='83%' }; results=@() } |
        ConvertTo-Json | Set-Content (Join-Path $ReviewDir 'deployment-match-report.json') -Encoding UTF8

    # Drift report with 2 critical
    [ordered]@{ summary = [ordered]@{ totalDriftItems=3; critical=2; warnings=1 }; driftItems=@() } |
        ConvertTo-Json | Set-Content (Join-Path $DriftDir 'drift-report.json') -Encoding UTF8

    # DR summary
    [ordered]@{ drRegion = 'westus'; processed = 12 } |
        ConvertTo-Json | Set-Content (Join-Path $DrDir 'dr-summary.json') -Encoding UTF8

    # DR validation
    [ordered]@{ validationSummary = [ordered]@{ passed=11; failed=1 } } |
        ConvertTo-Json | Set-Content (Join-Path $DrDir 'dr-validation-report.json') -Encoding UTF8

    # DR health report  (key E1 + E2 fields)
    [ordered]@{
        summary = [ordered]@{ status='healthy'; totalChecks=5; passed=5 }
        checks  = @()
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $DrDir 'dr-health-report.json') -Encoding UTF8

    # Unsupported summary (key E3 field)
    [ordered]@{ neverExports=2; partiallyExports=1; requiresHandAuthoredDR=2; unsupportedResources=3 } |
        ConvertTo-Json | Set-Content (Join-Path $ExportDir 'unsupported-summary.json') -Encoding UTF8

    $SummaryOut = Join-Path $T1 'step-summary.md'
    & $SummaryScript `
        -ScanDir $ScanDir -ReviewDir $ReviewDir -DriftDir $DriftDir `
        -DrDir $DrDir -SummaryFile $SummaryOut -ExportDir $ExportDir 2>$null

    Assert-True (Test-Path $SummaryOut) "step-summary.md must be written"

    if (Test-Path $SummaryOut) {
        $Md = Get-Content $SummaryOut -Raw

        # DriftSeverity row
        Assert-True ($Md -match 'Overall Severity') "Summary must contain 'Overall Severity' row"
        Assert-True ($Md -match 'critical')          "DriftSeverity must be 'critical' (2 critical items)"

        # DR health rows (E1 + E2)
        Assert-True ($Md -match 'DR health status') "Summary must contain 'DR health status' row"
        Assert-True ($Md -match 'healthy')           "DrHealthStatus must be 'healthy'"
        Assert-True ($Md -match 'Health checks passed') "Summary must contain 'Health checks passed' row"
        Assert-True ($Md -match '5 / 5')             "Health checks passed must show '5 / 5'"

        # Requires hand-authored DR (E3)
        Assert-True ($Md -match 'Requires hand-authored DR') "Summary must contain 'Requires hand-authored DR' row"
        Assert-True ($Md -match '\b2\b')             "RequiresHandAuthoredDR count (2) must appear in summary"
    }
} finally {
    Remove-Item $T1 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 — ExportDir omitted: no unsupported-summary → RequiresHandAuthoredDR = 0
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── write-job-summary: ExportDir omitted → RequiresHandAuthoredDR defaults to 0 ──"
$T2 = New-TempDir
try {
    $ScanDir   = Join-Path $T2 'scan'
    $ReviewDir = Join-Path $T2 'review'
    $DriftDir  = Join-Path $T2 'drift'
    $DrDir     = Join-Path $T2 'dr'
    $null = New-Item -ItemType Directory -Force -Path $ScanDir, $ReviewDir, $DriftDir, $DrDir

    [ordered]@{ subscriptionsScanned = 1; totalResourcesFound = 5 } |
        ConvertTo-Json | Set-Content (Join-Path $ScanDir 'scan-summary.json') -Encoding UTF8

    [ordered]@{ summary = [ordered]@{ matched=2; unmatched=0; deploymentCoverage='100%' }; results=@() } |
        ConvertTo-Json | Set-Content (Join-Path $ReviewDir 'deployment-match-report.json') -Encoding UTF8

    [ordered]@{ summary = [ordered]@{ totalDriftItems=0; critical=0; warnings=0 }; driftItems=@() } |
        ConvertTo-Json | Set-Content (Join-Path $DriftDir 'drift-report.json') -Encoding UTF8

    [ordered]@{ drRegion = 'westus'; processed = 2 } |
        ConvertTo-Json | Set-Content (Join-Path $DrDir 'dr-summary.json') -Encoding UTF8

    [ordered]@{ validationSummary = [ordered]@{ passed=2; failed=0 } } |
        ConvertTo-Json | Set-Content (Join-Path $DrDir 'dr-validation-report.json') -Encoding UTF8

    $SummaryOut = Join-Path $T2 'step-summary.md'
    # Note: no -ExportDir parameter
    & $SummaryScript `
        -ScanDir $ScanDir -ReviewDir $ReviewDir -DriftDir $DriftDir `
        -DrDir $DrDir -SummaryFile $SummaryOut 2>$null

    Assert-True (Test-Path $SummaryOut) "step-summary.md must be written even without ExportDir"

    if (Test-Path $SummaryOut) {
        $Md = Get-Content $SummaryOut -Raw
        Assert-True ($Md -match 'Overall Severity') "Drift severity row must always appear"
        Assert-True ($Md -match '\bok\b')            "DriftSeverity must be 'ok' when no critical/warning"
        Assert-True ($Md -match 'Requires hand-authored DR') "Requires-hand-authored-DR row must always appear"
        Assert-True ($Md -match '\| Requires hand-authored DR \| 0 \|') "RequiresHandAuthoredDR must be 0 when no ExportDir"
    }
} finally {
    Remove-Item $T2 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 — DriftSeverity: warnings only → 'warning'
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "── write-job-summary: warnings-only drift → severity = warning ──"
$T3 = New-TempDir
try {
    $ScanDir   = Join-Path $T3 'scan'
    $ReviewDir = Join-Path $T3 'review'
    $DriftDir  = Join-Path $T3 'drift'
    $DrDir     = Join-Path $T3 'dr'
    $null = New-Item -ItemType Directory -Force -Path $ScanDir, $ReviewDir, $DriftDir, $DrDir

    [ordered]@{ subscriptionsScanned = 1; totalResourcesFound = 10 } |
        ConvertTo-Json | Set-Content (Join-Path $ScanDir 'scan-summary.json') -Encoding UTF8

    [ordered]@{ summary = [ordered]@{ matched=5; unmatched=1; deploymentCoverage='83%' }; results=@() } |
        ConvertTo-Json | Set-Content (Join-Path $ReviewDir 'deployment-match-report.json') -Encoding UTF8

    # Drift: 0 critical, 3 warnings
    [ordered]@{ summary = [ordered]@{ totalDriftItems=3; critical=0; warnings=3 }; driftItems=@() } |
        ConvertTo-Json | Set-Content (Join-Path $DriftDir 'drift-report.json') -Encoding UTF8

    [ordered]@{ drRegion = 'eastus2'; processed = 5 } |
        ConvertTo-Json | Set-Content (Join-Path $DrDir 'dr-summary.json') -Encoding UTF8

    [ordered]@{ validationSummary = [ordered]@{ passed=5; failed=0 } } |
        ConvertTo-Json | Set-Content (Join-Path $DrDir 'dr-validation-report.json') -Encoding UTF8

    $SummaryOut = Join-Path $T3 'step-summary.md'
    & $SummaryScript `
        -ScanDir $ScanDir -ReviewDir $ReviewDir -DriftDir $DriftDir `
        -DrDir $DrDir -SummaryFile $SummaryOut 2>$null

    if (Test-Path $SummaryOut) {
        $Md = Get-Content $SummaryOut -Raw
        Assert-True ($Md -match 'warning') "DriftSeverity must be 'warning' when only warnings present"
    } else {
        $Failures.Add("[FAIL] step-summary.md not written in Test 3")
    }
} finally {
    Remove-Item $T3 -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
if ($Failures.Count -gt 0) {
    foreach ($f in $Failures) { Write-Host $f }
    exit 1
}
Write-Host "Test-WriteJobSummary: all assertions passed."
exit 0
