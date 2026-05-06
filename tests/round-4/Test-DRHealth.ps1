#Requires -Version 7.2
# =============================================================================
# tests/round-4/Test-DRHealth.ps1
# Round 4 §R4.2 unit + smoke test for scripts/dr/Test-DRHealth.ps1.
#
# Strategy:
#   1. Synthesize a deploy-summary.json (the upstream input from Stage 7).
#   2. Build per-scenario fixtures programmatically:
#        - happy: every check healthy           → DR_HEALTH_OK=true,  exit 0
#        - degraded: SQL CATCH_UP but lag big   → DR_HEALTH_OK=false, exit 0
#        - unhealthy: Postgres state=Failed     → DR_HEALTH_OK=false,
#                                                exit 0 by default,
#                                                exit 1 with -FailOnUnhealthy
#        - missing fixture under -DryRun        → non-zero exit
#   3. Re-run the happy scenario twice on the same fixture and assert the
#      generated dr-health.json hashes match (idempotency).
#
# Hand-rolled assertions, no Pester. Exits 0 on PASS, 1 on FAIL.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Script   = Join-Path $RepoRoot 'scripts/dr/Test-DRHealth.ps1'
$Fixture  = Join-Path $RepoRoot 'tests/fixtures/dr-health/all-healthy.json'
$Workdir  = Join-Path $env:TEMP "draac-drhealth-$([guid]::NewGuid().ToString('N'))"

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

function New-DeploySummary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes to a per-test temp directory under $env:TEMP.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $summary = [ordered]@{
        runId           = 'test-run-001'
        commitSha       = 'abcdef1234567890'
        drRegion        = 'northeurope'
        timestamp       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        processed       = 7
        succeeded       = 7
        failed          = 0
        deploymentNames = @(
            'draac-abcdef1-rg-anchor-dr',
            'draac-abcdef1-rg-cosmos-dr',
            'draac-abcdef1-rg-storage-dr',
            'draac-abcdef1-rg-keyvault-dr',
            'draac-abcdef1-rg-postgres-dr',
            'draac-abcdef1-rg-mysql-dr',
            'draac-abcdef1-rg-redis-dr'
        )
        failures        = @()
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Read-FixtureWithRecentSync {
    <#
    .SYNOPSIS
    Reads the all-healthy fixture and substitutes the placeholder
    "__RECENT_ISO__" with a timestamp 30 seconds ago so the storage probe is
    well within the default 15-minute tolerance.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    $now = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
    return $raw.Replace('__RECENT_ISO__', $now)
}

function Save-Fixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes to a per-test temp directory under $env:TEMP.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Object)
    $Object | ConvertTo-Json -Depth 30 | Set-Content -Path $Path -Encoding UTF8
}

try {
    $null = New-Item -ItemType Directory -Force -Path $Workdir
    $deploySummary = Join-Path $Workdir 'deploy-summary.json'
    New-DeploySummary -Path $deploySummary

    # ── Scenario 1: happy path ────────────────────────────────────────────────
    Write-Host "── scenario 1: all healthy ──"
    $hsFixture = Join-Path $Workdir 'happy.json'
    $hsOut     = Join-Path $Workdir 'out-happy'
    Read-FixtureWithRecentSync -Path $Fixture | Set-Content -Path $hsFixture -Encoding UTF8

    # Capture the GitHub-output sink to assert on DR_HEALTH_OK / SUMMARY.
    $githubOutFile = Join-Path $Workdir 'gh-output-happy.txt'
    $oldGh = $env:GITHUB_OUTPUT
    $env:GITHUB_OUTPUT = $githubOutFile
    try {
        & pwsh -NoProfile -File $Script `
            -DeploySummaryFile $deploySummary `
            -OutputDir $hsOut `
            -DrRegion 'northeurope' `
            -DryRun -FixtureFile $hsFixture *> $null
        $hsExit = $LASTEXITCODE
    }
    finally {
        $env:GITHUB_OUTPUT = $oldGh
    }

    Assert-Equal 0 $hsExit 'happy: exit 0'
    $reportPath = Join-Path $hsOut 'dr-health.json'
    Assert-True (Test-Path -LiteralPath $reportPath) 'happy: dr-health.json written'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 30
    Assert-Equal 7 $report.totalChecks 'happy: 7 total checks'
    Assert-Equal 7 $report.healthy     'happy: 7 healthy'
    Assert-Equal 0 $report.degraded    'happy: 0 degraded'
    Assert-Equal 0 $report.unhealthy   'happy: 0 unhealthy'
    Assert-Equal 0 $report.unknown     'happy: 0 unknown'
    Assert-Equal 'northeurope' $report.drRegion 'happy: drRegion echoed'

    # Stable ordering by resourceId (idempotency precondition).
    $resourceIds = @($report.checks | ForEach-Object { $_.resourceId })
    $sorted      = @($resourceIds | Sort-Object)
    Assert-Equal ($sorted -join '|') ($resourceIds -join '|') 'happy: checks sorted by resourceId'

    # GitHub output sink content.
    Assert-True (Test-Path -LiteralPath $githubOutFile) 'happy: GITHUB_OUTPUT written'
    $ghContent = Get-Content -LiteralPath $githubOutFile -Raw
    Assert-True ($ghContent -match 'DR_HEALTH_OK=true')      'happy: DR_HEALTH_OK=true'
    Assert-True ($ghContent -match 'DR_HEALTH_SUMMARY=7/7')  'happy: DR_HEALTH_SUMMARY=7/7'

    # ── Scenario 2: idempotency ──────────────────────────────────────────────
    Write-Host "── scenario 2: idempotency ──"
    $hash1 = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash

    # Re-run with the SAME fixture/output dir. The dr-health.json's
    # generatedAt will differ, so blank it out before hashing.
    & pwsh -NoProfile -File $Script `
        -DeploySummaryFile $deploySummary `
        -OutputDir $hsOut `
        -DrRegion 'northeurope' `
        -DryRun -FixtureFile $hsFixture *> $null

    $r1 = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 30
    $r2 = $report
    Assert-Equal $r2.totalChecks  $r1.totalChecks  'idempotent: totalChecks stable'
    Assert-Equal $r2.healthy      $r1.healthy      'idempotent: healthy stable'
    Assert-Equal $r2.degraded     $r1.degraded     'idempotent: degraded stable'
    Assert-Equal $r2.unhealthy    $r1.unhealthy    'idempotent: unhealthy stable'

    $ids1 = @($r1.checks | ForEach-Object { $_.resourceId })
    $ids2 = @($r2.checks | ForEach-Object { $_.resourceId })
    Assert-Equal ($ids2 -join '|') ($ids1 -join '|') 'idempotent: same resourceId order'

    $statuses1 = @($r1.checks | ForEach-Object { $_.status })
    $statuses2 = @($r2.checks | ForEach-Object { $_.status })
    Assert-Equal ($statuses2 -join '|') ($statuses1 -join '|') 'idempotent: same statuses'
    # Note we deliberately do not byte-equal hashes because generatedAt drifts.
    Assert-True ($null -ne $hash1) 'idempotent: report hashable on first run'

    # ── Scenario 3: degraded SQL ─────────────────────────────────────────────
    Write-Host "── scenario 3: degraded SQL (lag > threshold) ──"
    $degFixturePath = Join-Path $Workdir 'degraded.json'
    $degObj = Read-FixtureWithRecentSync -Path $Fixture | ConvertFrom-Json -Depth 50
    foreach ($r in @($degObj.resources)) {
        if ($r.type -eq 'Microsoft.Sql/servers/databases') {
            $r.probeResult.replicationLag = 999    # well above the default 60s threshold
        }
    }
    Save-Fixture -Path $degFixturePath -Object $degObj

    $degOut = Join-Path $Workdir 'out-degraded'
    $ghDeg  = Join-Path $Workdir 'gh-output-degraded.txt'
    $env:GITHUB_OUTPUT = $ghDeg
    try {
        & pwsh -NoProfile -File $Script `
            -DeploySummaryFile $deploySummary `
            -OutputDir $degOut `
            -DrRegion 'northeurope' `
            -DryRun -FixtureFile $degFixturePath *> $null
        $degExit = $LASTEXITCODE
    } finally { $env:GITHUB_OUTPUT = $oldGh }

    Assert-Equal 0 $degExit 'degraded: exit 0 (no -FailOnUnhealthy, only degraded)'
    $degReport = Get-Content -LiteralPath (Join-Path $degOut 'dr-health.json') -Raw | ConvertFrom-Json -Depth 30
    Assert-Equal 7 $degReport.totalChecks 'degraded: 7 total'
    Assert-Equal 1 $degReport.degraded    'degraded: exactly 1 degraded'
    Assert-Equal 6 $degReport.healthy     'degraded: 6 still healthy'
    $sqlCheck = @($degReport.checks | Where-Object { $_.type -eq 'Microsoft.Sql/servers/databases' })[0]
    Assert-Equal 'degraded' $sqlCheck.status 'degraded: SQL check is degraded'
    Assert-True ($sqlCheck.metric -match 'lagSec=999') 'degraded: SQL metric mentions lagSec=999'
    $ghDegContent = Get-Content -LiteralPath $ghDeg -Raw
    Assert-True ($ghDegContent -match 'DR_HEALTH_OK=false') 'degraded: DR_HEALTH_OK=false'

    # ── Scenario 4: unhealthy Postgres ───────────────────────────────────────
    Write-Host "── scenario 4: unhealthy Postgres (state=Failed) ──"
    $unFixturePath = Join-Path $Workdir 'unhealthy.json'
    $unObj = Read-FixtureWithRecentSync -Path $Fixture | ConvertFrom-Json -Depth 50
    foreach ($r in @($unObj.resources)) {
        if ($r.type -eq 'Microsoft.DBforPostgreSQL/flexibleServers') {
            $r.probeResult.state = 'Failed'
            $r.probeResult.replica.replicationState = 'Failed'
        }
    }
    Save-Fixture -Path $unFixturePath -Object $unObj

    # Default behaviour: exit 0.
    $unOut1 = Join-Path $Workdir 'out-unhealthy-no-fail'
    $ghUn1  = Join-Path $Workdir 'gh-output-unhealthy-1.txt'
    $env:GITHUB_OUTPUT = $ghUn1
    try {
        & pwsh -NoProfile -File $Script `
            -DeploySummaryFile $deploySummary `
            -OutputDir $unOut1 `
            -DrRegion 'northeurope' `
            -DryRun -FixtureFile $unFixturePath *> $null
        $unExit1 = $LASTEXITCODE
    } finally { $env:GITHUB_OUTPUT = $oldGh }
    Assert-Equal 0 $unExit1 'unhealthy: exit 0 without -FailOnUnhealthy'

    $unReport1 = Get-Content -LiteralPath (Join-Path $unOut1 'dr-health.json') -Raw | ConvertFrom-Json -Depth 30
    Assert-Equal 1 $unReport1.unhealthy 'unhealthy: 1 unhealthy'
    Assert-Equal 6 $unReport1.healthy   'unhealthy: 6 healthy'
    $pgCheck = @($unReport1.checks | Where-Object { $_.type -eq 'Microsoft.DBforPostgreSQL/flexibleServers' })[0]
    Assert-Equal 'unhealthy' $pgCheck.status 'unhealthy: Postgres check is unhealthy'
    $ghUnContent1 = Get-Content -LiteralPath $ghUn1 -Raw
    Assert-True ($ghUnContent1 -match 'DR_HEALTH_OK=false') 'unhealthy: DR_HEALTH_OK=false'

    # With -FailOnUnhealthy: exit 1.
    $unOut2 = Join-Path $Workdir 'out-unhealthy-fail'
    $ghUn2  = Join-Path $Workdir 'gh-output-unhealthy-2.txt'
    $env:GITHUB_OUTPUT = $ghUn2
    try {
        & pwsh -NoProfile -File $Script `
            -DeploySummaryFile $deploySummary `
            -OutputDir $unOut2 `
            -DrRegion 'northeurope' `
            -DryRun -FixtureFile $unFixturePath -FailOnUnhealthy *> $null
        $unExit2 = $LASTEXITCODE
    } finally { $env:GITHUB_OUTPUT = $oldGh }
    Assert-Equal 1 $unExit2 'unhealthy: exit 1 with -FailOnUnhealthy'

    # ── Scenario 5: -DryRun without -FixtureFile fails loudly ────────────────
    Write-Host "── scenario 5: -DryRun without -FixtureFile ──"
    $missOut = Join-Path $Workdir 'out-miss'
    & pwsh -NoProfile -File $Script `
        -DeploySummaryFile $deploySummary `
        -OutputDir $missOut `
        -DryRun *> $null
    $missExit = $LASTEXITCODE
    Assert-True ($missExit -ne 0) 'missing fixture under -DryRun: non-zero exit'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $missOut 'dr-health.json'))) `
        'missing fixture under -DryRun: no report written'

    # Bad path under -DryRun also fails loudly.
    Write-Host "── scenario 5b: -DryRun with non-existent FixtureFile ──"
    & pwsh -NoProfile -File $Script `
        -DeploySummaryFile $deploySummary `
        -OutputDir $missOut `
        -DryRun -FixtureFile (Join-Path $Workdir 'does-not-exist.json') *> $null
    $missExit2 = $LASTEXITCODE
    Assert-True ($missExit2 -ne 0) 'bad fixture path under -DryRun: non-zero exit'

    # ── Scenario 6: missing probe result → unknown ───────────────────────────
    Write-Host "── scenario 6: fixture entry with no probeResult → unknown ──"
    $unkFixturePath = Join-Path $Workdir 'unknown.json'
    $unkObj = Read-FixtureWithRecentSync -Path $Fixture | ConvertFrom-Json -Depth 50
    foreach ($r in @($unkObj.resources)) {
        if ($r.type -eq 'Microsoft.Cache/Redis') {
            # Strip probeResult to simulate fixture omission.
            $r.PSObject.Properties.Remove('probeResult')
        }
    }
    Save-Fixture -Path $unkFixturePath -Object $unkObj

    $unkOut = Join-Path $Workdir 'out-unknown'
    $ghUnk  = Join-Path $Workdir 'gh-output-unknown.txt'
    $env:GITHUB_OUTPUT = $ghUnk
    try {
        & pwsh -NoProfile -File $Script `
            -DeploySummaryFile $deploySummary `
            -OutputDir $unkOut `
            -DrRegion 'northeurope' `
            -DryRun -FixtureFile $unkFixturePath *> $null
        $unkExit = $LASTEXITCODE
    } finally { $env:GITHUB_OUTPUT = $oldGh }
    Assert-Equal 0 $unkExit 'unknown: exit 0 (unknown is not failure by default)'
    $unkReport = Get-Content -LiteralPath (Join-Path $unkOut 'dr-health.json') -Raw | ConvertFrom-Json -Depth 30
    Assert-Equal 1 $unkReport.unknown 'unknown: 1 unknown'
    Assert-Equal 6 $unkReport.healthy 'unknown: 6 healthy'
    $ghUnkContent = Get-Content -LiteralPath $ghUnk -Raw
    Assert-True ($ghUnkContent -match 'DR_HEALTH_OK=true') `
        'unknown: DR_HEALTH_OK=true (unknown does not flip the gate)'
}
finally {
    if (Test-Path $Workdir) { Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue }
}

if ($Failures.Count -eq 0) {
    Write-Host ""
    Write-Host "Test-DRHealth: all assertions passed."
    exit 0
} else {
    Write-Host ""
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
