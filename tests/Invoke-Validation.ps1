#Requires -Version 7.2
# =============================================================================
# tests/Invoke-Validation.ps1
# Single-entry test runner for the DRaaC implementation rounds.
# Walks tests/round-N/ and runs each *.Test-*.ps1 against fixtures.
# Idempotent: re-runs produce identical pass/fail summaries for identical input.
# Fault-tolerant: a failing test in one round does not stop other rounds.
# =============================================================================
[CmdletBinding()]
param(
    [string[]] $Round           = @("1","2","3","4","5"),
    [switch]   $UpdateSnapshots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$TestsRoot   = $PSScriptRoot
$Results     = [System.Collections.Generic.List[object]]::new()
$StartedAt   = Get-Date

Write-Host "============================================================"
Write-Host "DRaaC validation harness"
Write-Host "  Repo root:   $RepoRoot"
Write-Host "  Rounds:      $($Round -join ', ')"
Write-Host "  Snapshots:   $(if ($UpdateSnapshots) { 'UPDATE' } else { 'COMPARE' })"
Write-Host "============================================================"

foreach ($r in $Round) {
    $dir = Join-Path $TestsRoot "round-$r"
    if (-not (Test-Path $dir)) {
        Write-Host "  Round $r — no tests directory, skipping."
        continue
    }

    $tests = Get-ChildItem -Path $dir -Filter "Test-*.ps1" -File -ErrorAction SilentlyContinue
    if (-not $tests) {
        Write-Host "  Round $r — directory exists but contains no Test-*.ps1 files."
        continue
    }

    foreach ($t in $tests) {
        Write-Host ""
        Write-Host "── Round $r › $($t.Name) ──"
        $testStart = Get-Date
        try {
            $env:DRAAC_REPO_ROOT       = $RepoRoot
            $env:DRAAC_TESTS_ROOT      = $TestsRoot
            $env:DRAAC_UPDATE_SNAPSHOT = if ($UpdateSnapshots) { "1" } else { "0" }

            & $t.FullName
            $exit = $LASTEXITCODE
            if ($null -eq $exit) { $exit = 0 }
        }
        catch {
            Write-Warning "  Test threw: $_"
            $exit = 99
        }
        finally {
            $env:DRAAC_REPO_ROOT       = $null
            $env:DRAAC_TESTS_ROOT      = $null
            $env:DRAAC_UPDATE_SNAPSHOT = $null
        }

        $Results.Add([PSCustomObject]@{
            Round    = $r
            Test     = $t.Name
            ExitCode = $exit
            Status   = if ($exit -eq 0) { "PASS" } else { "FAIL" }
            Duration = "{0:F2}s" -f ((Get-Date) - $testStart).TotalSeconds
        })
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "Summary"
Write-Host "============================================================"
if ($Results.Count -eq 0) {
    Write-Host "  (no tests executed)"
} else {
    $Results | Format-Table -AutoSize | Out-String | Write-Host
}

$failed = @($Results | Where-Object { $_.Status -eq "FAIL" })
$totalDuration = (Get-Date) - $StartedAt
Write-Host ("Total: {0}  Pass: {1}  Fail: {2}  Elapsed: {3:F1}s" -f `
    $Results.Count, ($Results.Count - $failed.Count), $failed.Count, $totalDuration.TotalSeconds)

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
