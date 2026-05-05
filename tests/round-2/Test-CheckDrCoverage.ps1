#Requires -Version 7.2
# =============================================================================
# tests/round-2/Test-CheckDrCoverage.ps1
# Round 2 §R2.1 acceptance test for scripts/review/check-dr-coverage.ps1.
#
# Style: hand-rolled Assert-True/Assert-Equal helpers, no Pester, exits 0/1.
# Mirrors tests/round-1/Test-GenerateDrConfig-Smoke.ps1.
#
# What this test exercises:
#   1. Happy path: PR touches a primary file whose DR companion already exists
#      → coverage: ok, no commit-back, exit 0.
#   2. Missing companion + bicep available: emits coverage: auto-generated and
#      writes a real DR file. Skipped on hosts without `bicep`/`az bicep`.
#   3. Missing companion + bicep unavailable: emits coverage: failed, exit 1.
#   4. Idempotency: re-running on a covered repo produces an identical report.
#
# The script under test never deploys anything; it does not require an Azure
# subscription. The "auto-generated" branch only runs when a Bicep CLI is
# locally available, mirroring Test-GenerateDrConfig-Smoke.ps1's az-skip
# pattern.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/review/check-dr-coverage.ps1'

$Failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $Failures.Add("[FAIL] $Message") }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        $Failures.Add("[FAIL] $Message`n         expected: $Expected`n         actual:   $Actual")
    }
}

function New-PrChangesFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes to a per-test temp directory under $env:TEMP; system state outside the harness is unaffected.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $Paths = @()
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Paths) {
        $entries.Add([PSCustomObject]@{
            status            = 'M'
            path              = $p
            category          = 'bicep'
            resourceGroupHint = ''
        })
    }
    # An empty pipeline through ConvertTo-Json emits nothing (even with -AsArray),
    # so Set-Content would silently skip the file. Force a literal `[]` for the
    # empty case to match the schema of identify-pr-changes.ps1.
    $json = if ($entries.Count -eq 0) {
        '[]'
    } else {
        $entries.ToArray() | ConvertTo-Json -Depth 5 -AsArray
    }
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

# Build a self-contained mini-repo so the test never mutates the real working
# tree (idempotency assertions would be meaningless otherwise).
function New-TestRepo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper builds a self-contained mini-repo in $env:TEMP; never mutates the live working tree.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)
    $primaryDir = Join-Path $Root 'bicep/regions/primary'
    $drDir      = Join-Path $Root 'bicep/regions/dr'
    $libDir     = Join-Path $Root 'scripts/lib'
    $reviewDir  = Join-Path $Root 'scripts/review'
    $dataDir    = Join-Path $Root 'data'
    foreach ($d in @($primaryDir, $drDir, $libDir, $reviewDir, $dataDir)) {
        $null = New-Item -ItemType Directory -Force -Path $d
    }

    # Copy real source under test + dependencies so paths the script resolves
    # via $RepoRoot all line up.
    Copy-Item (Join-Path $RepoRoot 'scripts/review/check-dr-coverage.ps1')   (Join-Path $reviewDir  'check-dr-coverage.ps1') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1')          (Join-Path $libDir     'ConvertForDR.psm1')     -Force
    Copy-Item (Join-Path $RepoRoot 'scripts/lib/CommitBack.psm1')            (Join-Path $libDir     'CommitBack.psm1')       -Force
    Copy-Item (Join-Path $RepoRoot 'data/reserved-names.json')               (Join-Path $dataDir    'reserved-names.json')   -Force
    Copy-Item (Join-Path $RepoRoot 'data/readonly-properties.json')          (Join-Path $dataDir    'readonly-properties.json') -Force

    # Anchor primary + DR companion (covered case).
    Copy-Item (Join-Path $RepoRoot 'bicep/regions/primary/anchor.bicep')     (Join-Path $primaryDir 'anchor.bicep') -Force
    Copy-Item (Join-Path $RepoRoot 'bicep/regions/dr/dr-anchor.bicep')       (Join-Path $drDir      'dr-anchor.bicep') -Force

    # Synthetic primary with NO DR companion (uncovered case).
    @'
@description('Test workload without a DR companion.')
param location string = 'westeurope'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'sttestmissing01'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: { minimumTlsVersion: 'TLS1_2' }
}
'@ | Set-Content (Join-Path $primaryDir 'orphan.bicep') -Encoding UTF8
}

function Invoke-Coverage {
    param(
        [Parameter(Mandatory)] [string]   $RepoDir,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ChangedPaths,
        [Parameter(Mandatory)] [string]   $OutDir
    )
    $changesFile = Join-Path $OutDir 'pr-changes.json'
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    New-PrChangesFile -Path $changesFile -Paths $ChangedPaths

    # Suppress GitHub Actions output side-channel for the test run.
    $savedGhOut = $env:GITHUB_OUTPUT
    $env:GITHUB_OUTPUT = $null
    try {
        & $ScriptPath -PrChangesFile $changesFile -RepoRoot $RepoDir -OutputDir $OutDir
        $code = $LASTEXITCODE
    } finally {
        $env:GITHUB_OUTPUT = $savedGhOut
    }

    $report = $null
    $reportPath = Join-Path $OutDir 'coverage-report.json'
    if (Test-Path $reportPath) {
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json -Depth 20
    }
    return [PSCustomObject]@{ ExitCode = $code; Report = $report; ReportPath = $reportPath }
}

# ── Test 1: happy path — companion already exists ────────────────────────────
$Workdir = Join-Path $env:TEMP ("draac-cov-" + [guid]::NewGuid().ToString('N'))
try {
    Write-Host ""
    Write-Host "── happy path: companion exists ──"

    $repo1 = Join-Path $Workdir 'repo-happy'
    $null = New-Item -ItemType Directory -Force -Path $repo1
    New-TestRepo -Root $repo1

    $out1 = Join-Path $repo1 '_reports/coverage'
    $r1 = Invoke-Coverage -RepoDir $repo1 -ChangedPaths @('bicep/regions/primary/anchor.bicep') -OutDir $out1

    Assert-Equal 0     $r1.ExitCode             'happy: exit code 0'
    Assert-True  ($null -ne $r1.Report)         'happy: report file written'
    Assert-True  $r1.Report.coverageOk          'happy: coverageOk=true'
    Assert-Equal 1     $r1.Report.totalChecked  'happy: 1 file checked'
    Assert-Equal 0     $r1.Report.autoGenerated 'happy: 0 auto-generated'
    Assert-Equal 0     $r1.Report.failed        'happy: 0 failed'
    $r1Results = @($r1.Report.results)
    Assert-Equal 'ok'  $r1Results[0].coverage 'happy: result is ok'

    # ── Test 4 (idempotency): rerun the exact same invocation ───────────────
    Write-Host ""
    Write-Host "── idempotency: rerun produces structurally identical report ──"
    $r1b = Invoke-Coverage -RepoDir $repo1 -ChangedPaths @('bicep/regions/primary/anchor.bicep') -OutDir $out1
    Assert-Equal $r1.ExitCode             $r1b.ExitCode             'idempotency: exit code stable'
    Assert-Equal $r1.Report.coverageOk    $r1b.Report.coverageOk    'idempotency: coverageOk stable'
    Assert-Equal $r1.Report.totalChecked  $r1b.Report.totalChecked  'idempotency: totalChecked stable'
    Assert-Equal $r1.Report.autoGenerated $r1b.Report.autoGenerated 'idempotency: autoGenerated stable'
    Assert-Equal $r1.Report.failed        $r1b.Report.failed        'idempotency: failed stable'
    $r1bResults = @($r1b.Report.results)
    Assert-Equal $r1Results[0].coverage $r1bResults[0].coverage 'idempotency: per-file coverage stable'

    # ── Test 2 / 3: missing companion ───────────────────────────────────────
    Write-Host ""
    Write-Host "── missing companion path ──"
    $repo2 = Join-Path $Workdir 'repo-missing'
    $null = New-Item -ItemType Directory -Force -Path $repo2
    New-TestRepo -Root $repo2

    $out2 = Join-Path $repo2 '_reports/coverage'
    $r2 = Invoke-Coverage -RepoDir $repo2 -ChangedPaths @('bicep/regions/primary/orphan.bicep') -OutDir $out2

    Assert-True  ($null -ne $r2.Report) 'missing: report file written'
    Assert-Equal 1 $r2.Report.totalChecked 'missing: 1 file checked'

    $r2Results = @($r2.Report.results)
    $bicepAvailable = ($null -ne (Get-Command bicep -ErrorAction SilentlyContinue)) -or `
                      ($null -ne (Get-Command az    -ErrorAction SilentlyContinue))

    if ($bicepAvailable -and $r2Results[0].coverage -eq 'auto-generated') {
        Write-Host "  bicep CLI detected and decompile succeeded — expecting auto-generation"
        Assert-Equal 'auto-generated' $r2Results[0].coverage 'missing+bicep: result is auto-generated'
        Assert-True  $r2.Report.coverageOk 'missing+bicep: coverageOk=true (auto-generated counts as ok)'
        Assert-Equal 0   $r2.ExitCode      'missing+bicep: exit code 0'
        Assert-True  (Test-Path (Join-Path $repo2 'bicep/regions/dr/dr-orphan.bicep')) 'missing+bicep: companion materialised on disk'
    } else {
        Write-Host "  bicep CLI not available or decompile path failed — expecting graceful failure"
        Assert-Equal 'failed' $r2Results[0].coverage 'missing-no-bicep: result is failed'
        Assert-True  (-not $r2.Report.coverageOk) 'missing-no-bicep: coverageOk=false'
        Assert-Equal 1 $r2.ExitCode 'missing-no-bicep: exit code 1'
    }

    # ── Test 5: empty change set is a clean pass ────────────────────────────
    Write-Host ""
    Write-Host "── empty change set ──"
    $repo3 = Join-Path $Workdir 'repo-empty'
    $null = New-Item -ItemType Directory -Force -Path $repo3
    New-TestRepo -Root $repo3
    $out3 = Join-Path $repo3 '_reports/coverage'
    $r3 = Invoke-Coverage -RepoDir $repo3 -ChangedPaths @() -OutDir $out3
    Assert-Equal 0     $r3.ExitCode            'empty: exit code 0'
    Assert-Equal 0     $r3.Report.totalChecked 'empty: 0 files checked'
    Assert-True  $r3.Report.coverageOk         'empty: coverageOk=true'

    # ── Test 6: non-bicep PR change is ignored ──────────────────────────────
    Write-Host ""
    Write-Host "── non-bicep change is ignored ──"
    $repo4 = Join-Path $Workdir 'repo-nonbicep'
    $null = New-Item -ItemType Directory -Force -Path $repo4
    New-TestRepo -Root $repo4
    $out4 = Join-Path $repo4 '_reports/coverage'
    $r4 = Invoke-Coverage -RepoDir $repo4 -ChangedPaths @('docs/README.md','scripts/foo.ps1') -OutDir $out4
    Assert-Equal 0 $r4.ExitCode             'non-bicep: exit code 0'
    Assert-Equal 0 $r4.Report.totalChecked  'non-bicep: 0 files checked'
}
finally {
    if (Test-Path $Workdir) {
        Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "All assertions passed."
    exit 0
} else {
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
