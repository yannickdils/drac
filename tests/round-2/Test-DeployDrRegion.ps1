#Requires -Version 7.2
# =============================================================================
# tests/round-2/Test-DeployDrRegion.ps1
# Round 2.2 smoke + unit test for scripts/dr/deploy-dr-region.ps1.
#
# Strategy:
#   1. Build a synthetic bicep/regions/dr/ tree containing two dr-*.bicep files.
#   2. Run the deploy script with -DryRun so it never touches Azure, and assert
#      the deterministic deployment names + summary structure.
#   3. Dot-source the script's helpers via a scoped re-exec block to test
#      Get-DrWorkloadName, Get-DeterministicDeploymentName, and the
#      Invoke-AzWithRetry throttling backoff path with a stubbed `az` shadow.
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Script   = Join-Path $RepoRoot 'scripts/dr/deploy-dr-region.ps1'
$Workdir  = Join-Path $env:TEMP "draac-deploy-test-$([guid]::NewGuid().ToString('N'))"
$BicepDir = Join-Path $Workdir 'bicep'
$OutDir   = Join-Path $Workdir 'deploy'

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

try {
    # ── Setup synthetic bicep/regions/dr tree ────────────────────────────────
    $null = New-Item -ItemType Directory -Force -Path $BicepDir
    @(
        @{ name = 'dr-anchor.bicep';   body = "param location string = 'northeurope'`noutput ok bool = true`n" },
        @{ name = 'dr-payments.bicep'; body = "param location string = 'northeurope'`noutput ok bool = true`n" }
    ) | ForEach-Object {
        Set-Content -Path (Join-Path $BicepDir $_.name) -Value $_.body -Encoding UTF8
    }

    # ── 1. End-to-end DryRun run ──────────────────────────────────────────────
    Write-Host "── deploy-dr-region.ps1 -DryRun ──"
    & $Script `
        -BicepDir $BicepDir `
        -DrRegion 'northeurope' `
        -CommitSha 'abcdef1234567890' `
        -RunId 'test-run-001' `
        -OutputDir $OutDir `
        -DryRun | Out-Null

    Assert-True (Test-Path (Join-Path $OutDir 'deploy-summary.json')) 'dry-run: deploy-summary.json exists'
    Assert-True (Test-Path (Join-Path $OutDir 'failures.json'))       'dry-run: failures.json exists'
    Assert-True (Test-Path (Join-Path $OutDir 'whatif-rg-anchor-dr.json'))   'dry-run: whatif-rg-anchor-dr.json exists'
    Assert-True (Test-Path (Join-Path $OutDir 'whatif-rg-payments-dr.json')) 'dry-run: whatif-rg-payments-dr.json exists'

    $summary = Get-Content (Join-Path $OutDir 'deploy-summary.json') -Raw | ConvertFrom-Json
    Assert-Equal 2  $summary.processed 'summary.processed == 2'
    Assert-Equal 2  $summary.succeeded 'summary.succeeded == 2'
    Assert-Equal 0  $summary.failed    'summary.failed == 0'
    Assert-Equal 'test-run-001'        $summary.runId     'summary.runId echoed'
    Assert-Equal 'abcdef1234567890'    $summary.commitSha 'summary.commitSha echoed'
    Assert-Equal 'northeurope'         $summary.drRegion  'summary.drRegion echoed'

    $names = @($summary.deploymentNames)
    Assert-Equal 2 $names.Count 'two deployment names recorded'
    Assert-True ($names -contains 'draac-abcdef1-rg-anchor-dr')   'deterministic name for anchor'
    Assert-True ($names -contains 'draac-abcdef1-rg-payments-dr') 'deterministic name for payments'

    # Idempotency: re-running with the same SHA + same templates produces the
    # same deployment names. (Azure-side dedupe is what actually makes the
    # apply phase a no-op, but the local contract is "names are stable".)
    Write-Host "── re-run for idempotency ──"
    & $Script `
        -BicepDir $BicepDir `
        -DrRegion 'northeurope' `
        -CommitSha 'abcdef1234567890' `
        -RunId 'test-run-002' `
        -OutputDir $OutDir `
        -DryRun | Out-Null
    $summary2 = Get-Content (Join-Path $OutDir 'deploy-summary.json') -Raw | ConvertFrom-Json
    $names2   = @($summary2.deploymentNames | Sort-Object)
    Assert-Equal (($names | Sort-Object) -join ',') ($names2 -join ',') 'idempotent: deployment names stable across runs'

    # ── 2. Helper unit tests via dot-source in a guarded scope ───────────────
    # The script is parameterised on Mandatory inputs and runs to completion at
    # dot-source time, so we carve out the helpers by parsing them out of the
    # source file. This keeps the test pure-PowerShell with no extra deps.
    Write-Host "── helper unit tests ──"
    $src = Get-Content $Script -Raw

    function Export-FunctionFromSource {
        param([string]$Source, [string]$FunctionName)
        # Match: `function Name {` ... balanced-brace body.
        $pattern = "(?s)function\s+$([regex]::Escape($FunctionName))\s*\{"
        $m = [regex]::Match($Source, $pattern)
        if (-not $m.Success) { throw "Function $FunctionName not found in source." }
        $i = $m.Index + $m.Length - 1   # position of opening brace
        $depth = 1
        $j = $i + 1
        while ($j -lt $Source.Length -and $depth -gt 0) {
            $c = $Source[$j]
            if ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth-- }
            $j++
        }
        return $Source.Substring($m.Index, $j - $m.Index)
    }

    $helpers = @(
        Export-FunctionFromSource -Source $src -FunctionName 'Get-DrWorkloadName'
        Export-FunctionFromSource -Source $src -FunctionName 'Get-DeterministicDeploymentName'
        Export-FunctionFromSource -Source $src -FunctionName 'Invoke-AzWithRetry'
        Export-FunctionFromSource -Source $src -FunctionName 'Invoke-AzCommand'
    ) -join "`n`n"

    # Evaluate helpers inside a child script-block scope.
    $sb = [scriptblock]::Create($helpers)
    . $sb

    # Get-DrWorkloadName
    Assert-Equal 'anchor'   (Get-DrWorkloadName -FileName 'dr-anchor.bicep')   'workload from dr-anchor.bicep'
    Assert-Equal 'payments' (Get-DrWorkloadName -FileName 'dr-payments.bicep') 'workload from dr-payments.bicep'
    Assert-Equal 'multi-word' (Get-DrWorkloadName -FileName 'dr-multi-word.bicep') 'workload preserves dashes'

    $caught = $false
    try { Get-DrWorkloadName -FileName 'primary.bicep' | Out-Null }
    catch { $caught = $true }
    Assert-True $caught 'Get-DrWorkloadName rejects non-dr filenames'

    # Get-DeterministicDeploymentName
    Assert-Equal 'draac-abcdef1-rg-anchor-dr' (Get-DeterministicDeploymentName -CommitSha 'abcdef1234567890' -Workload 'anchor') `
        'deployment name format'
    $shortCaught = $false
    try { Get-DeterministicDeploymentName -CommitSha 'abc' -Workload 'anchor' | Out-Null }
    catch { $shortCaught = $true }
    Assert-True $shortCaught 'rejects short commit SHA'

    # Invoke-AzWithRetry — happy path: returns immediately.
    $callCount = 0
    $result = Invoke-AzWithRetry -Operation 'unit-happy' -ScriptBlock {
        $script:callCount++
        return 'ok'
    } -BackoffSeconds @(0, 0, 0, 0)
    Assert-Equal 'ok' $result 'retry helper returns happy-path value'
    Assert-Equal 1 $callCount 'retry helper does not retry on success'

    # Invoke-AzWithRetry — throttle then succeed.
    $script:throttleAttempts = 0
    $result2 = Invoke-AzWithRetry -Operation 'unit-throttle-recover' -ScriptBlock {
        $script:throttleAttempts++
        if ($script:throttleAttempts -lt 3) {
            throw "ThrottlingException: 429 Too Many Requests"
        }
        return 'recovered'
    } -BackoffSeconds @(0, 0, 0, 0)
    Assert-Equal 'recovered' $result2 'retry helper recovers after throttling'
    Assert-Equal 3 $script:throttleAttempts 'retry helper retries on throttle'

    # Invoke-AzWithRetry — non-throttle errors do not retry.
    $script:hardFailAttempts = 0
    $caughtHard = $false
    try {
        Invoke-AzWithRetry -Operation 'unit-hard-fail' -ScriptBlock {
            $script:hardFailAttempts++
            throw "BadRequest: invalid template"
        } -BackoffSeconds @(0, 0, 0, 0) | Out-Null
    } catch {
        $caughtHard = $true
    }
    Assert-True $caughtHard 'retry helper propagates non-throttle errors'
    Assert-Equal 1 $script:hardFailAttempts 'retry helper does not retry on hard failure'

    # Invoke-AzWithRetry — exhaust backoff sequence on persistent throttling.
    $script:persistentAttempts = 0
    $caughtPersist = $false
    try {
        Invoke-AzWithRetry -Operation 'unit-persistent-throttle' -ScriptBlock {
            $script:persistentAttempts++
            throw "ThrottlingException: 429"
        } -BackoffSeconds @(0, 0) | Out-Null
    } catch {
        $caughtPersist = $true
    }
    Assert-True $caughtPersist 'retry helper rethrows after exhausting backoff'
    # backoff length 2 -> initial try + 2 retries = 3 attempts.
    Assert-Equal 3 $script:persistentAttempts 'retry helper attempts initial + N retries'
}
finally {
    if (Test-Path $Workdir) { Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue }
}

if ($Failures.Count -eq 0) {
    Write-Host ""
    Write-Host "Test-DeployDrRegion: all assertions passed."
    exit 0
} else {
    Write-Host ""
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
