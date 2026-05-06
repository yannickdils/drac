#Requires -Version 7.2
# =============================================================================
# tests/round-3/Test-SendToManualQueue.ps1
# Round 3.4 unit + integration test for scripts/sync/Send-ToManualQueue.ps1.
#
# Strategy:
#   1. Build a synthetic $Change object plus an ARM JSON fixture in a temp dir
#      and run the script with -DryRun so it never invokes `gh`.
#   2. Assert:
#        - The manual-queue file is created at <OutputDir>/manual-queue/<hash>.json
#        - <hash> is the deterministic 12-hex-char fingerprint of the lowercase
#          targetResourceId (independently re-computed in this test).
#        - The summary file is a JSON array containing a `skipped-dry-run` entry.
#        - The exit code is 0.
#   3. Re-run with the same change and assert:
#        - Hash is stable (idempotent path naming).
#        - Summary now has TWO entries (the script appends, doesn't replace).
#   4. Helper unit tests:
#        - Get-ResourceIdHash matches a hand-computed expected for a known ID.
#        - Test-IsGitHubUsername accepts/rejects the expected forms.
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$Script   = Join-Path $RepoRoot 'scripts/sync/Send-ToManualQueue.ps1'
$Workdir  = Join-Path $env:TEMP "draac-manual-queue-test-$([guid]::NewGuid().ToString('N'))"
$OutDir   = Join-Path $Workdir 'sync'
$ArmPath  = Join-Path $Workdir 'arm.json'

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

function Get-ExpectedHash {
    param([Parameter(Mandatory)] [string] $ResourceId)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResourceId.ToLowerInvariant())
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try   { $hash = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return -join ($hash[0..5] | ForEach-Object { $_.ToString('x2') })
}

try {
    $null = New-Item -ItemType Directory -Force -Path $Workdir
    $null = New-Item -ItemType Directory -Force -Path $OutDir

    $resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-foo/providers/Microsoft.Network/virtualNetworks/vnet-x'
    $expectedHash = Get-ExpectedHash -ResourceId $resourceId

    # Synthetic ARM JSON fixture (mimics the wrapped template Sync-PortalChange
    # would have produced before bicep decompile bailed).
    $armBody = @{
        '$schema'        = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion   = '1.0.0.0'
        resources        = @(
            @{
                type       = 'Microsoft.Network/virtualNetworks'
                apiVersion = '2023-09-01'
                name       = 'vnet-x'
                location   = 'westeurope'
                properties = @{
                    addressSpace = @{ addressPrefixes = @('10.0.0.0/16') }
                }
            }
        )
    } | ConvertTo-Json -Depth 30
    Set-Content -Path $ArmPath -Value $armBody -Encoding UTF8

    $change = [PSCustomObject]@{
        targetResourceId   = $resourceId
        targetResourceType = 'Microsoft.Network/virtualNetworks'
        subscriptionId     = '00000000-0000-0000-0000-000000000000'
        resourceGroupName  = 'rg-foo'
        resourceName       = 'vnet-x'
        changeType         = 'Update'
        changedBy          = 'alice@example.com'
        timestamp          = '2026-05-04T12:34:56Z'
        changedProperties  = @('properties.addressSpace.addressPrefixes')
    }

    # ── 1. First DryRun call ─────────────────────────────────────────────────
    Write-Host "── Send-ToManualQueue.ps1 -DryRun (first call) ──"
    & $Script `
        -Change $change `
        -ArmJsonPath $ArmPath `
        -RepoFull 'tunecom/drac' `
        -OutputDir $OutDir `
        -DecompileWarnings 'WARN: could not decompile resource because property X is read-only' `
        -DryRun | Out-Null
    $firstExit = $LASTEXITCODE

    Assert-Equal 0 $firstExit 'first dry-run exits 0'

    $expectedManualPath = Join-Path $OutDir "manual-queue/$expectedHash.json"
    Assert-True (Test-Path $expectedManualPath) "manual-queue file written at <hash>.json ($expectedHash)"

    $summaryPath = Join-Path $OutDir 'manual-queue-summary.json'
    Assert-True (Test-Path $summaryPath) 'manual-queue-summary.json exists'

    $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
    $summaryArr = @($summary)
    Assert-Equal 1 $summaryArr.Count 'summary contains exactly one entry after first call'
    Assert-Equal $expectedHash       $summaryArr[0].resourceIdHash   'summary hash matches expected'
    Assert-Equal $resourceId         $summaryArr[0].targetResourceId 'summary resource ID matches input'
    Assert-Equal 'skipped-dry-run'   $summaryArr[0].outcome          'summary outcome is skipped-dry-run'
    Assert-Equal "_reports/sync/manual-queue/$expectedHash.json" $summaryArr[0].manualQueuePath `
        'summary manualQueuePath uses _reports/sync prefix'

    # The manual-queue file should be a verbatim copy of the ARM JSON.
    $copied = Get-Content $expectedManualPath -Raw
    Assert-True ($copied.Contains('"vnet-x"')) 'manual-queue file content matches ARM source (vnet-x marker)'

    # ── 2. Second DryRun call: same change, hash stable, summary appended ────
    Write-Host "── Send-ToManualQueue.ps1 -DryRun (second call, same change) ──"
    & $Script `
        -Change $change `
        -ArmJsonPath $ArmPath `
        -RepoFull 'tunecom/drac' `
        -OutputDir $OutDir `
        -DryRun | Out-Null
    $secondExit = $LASTEXITCODE

    Assert-Equal 0 $secondExit 'second dry-run exits 0'

    $summary2    = Get-Content $summaryPath -Raw | ConvertFrom-Json
    $summary2Arr = @($summary2)
    Assert-Equal 2 $summary2Arr.Count 'summary contains two entries after second call'
    Assert-Equal $expectedHash $summary2Arr[1].resourceIdHash 'second entry hash matches first (idempotent)'
    Assert-Equal 'skipped-dry-run' $summary2Arr[1].outcome    'second entry outcome is skipped-dry-run'

    # Same path, no duplicates with .1.json suffixes etc.
    $hashFiles = @(Get-ChildItem -Path (Join-Path $OutDir 'manual-queue') -Filter '*.json' -File)
    Assert-Equal 1 $hashFiles.Count 'only one file in manual-queue dir (re-runs overwrite, do not duplicate)'

    # ── 3. Hash determinism: hand-computed value for a fixed resource ID ─────
    # Pre-computed externally (matches the helper used inside the script):
    #   first 6 bytes of SHA-256 over the lowercase ID.
    Write-Host "── helper unit tests ──"

    # Hand-compute the expected hash for an unrelated ID and assert the script's
    # logic matches when we feed that ID through it as well.
    $altId   = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/RG-Bar/providers/Microsoft.Storage/storageAccounts/saTest'
    $altHash = Get-ExpectedHash -ResourceId $altId
    Assert-Equal 12 $altHash.Length 'expected hash is 12 hex chars'
    Assert-True ($altHash -match '^[0-9a-f]{12}$') 'expected hash is lowercase hex'

    # Run the script against the alt ID and assert it picks the same hash.
    $altChange = [PSCustomObject]@{
        targetResourceId   = $altId
        targetResourceType = 'Microsoft.Storage/storageAccounts'
        subscriptionId     = '11111111-1111-1111-1111-111111111111'
        resourceGroupName  = 'RG-Bar'
        resourceName       = 'saTest'
        changeType         = 'Update'
        changedBy          = 'octocat'
        timestamp          = '2026-05-04T13:00:00Z'
        changedProperties  = @('tags.foo')
    }
    $altOut = Join-Path $Workdir 'alt-out'
    & $Script `
        -Change $altChange `
        -ArmJsonPath $ArmPath `
        -RepoFull 'tunecom/drac' `
        -OutputDir $altOut `
        -DryRun | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'alt-id dry-run exits 0'
    $altManualPath = Join-Path $altOut "manual-queue/$altHash.json"
    Assert-True (Test-Path $altManualPath) "script computes the same hash as the test ($altHash)"

    # ── 4. Re-export helpers from the script source for direct unit testing ──
    # The script runs to completion at dot-source time, so we extract individual
    # helpers via balanced-brace text matching (same trick as Test-DeployDrRegion).
    $src = Get-Content $Script -Raw

    function Export-FunctionFromSource {
        param([string]$Source, [string]$FunctionName)
        $pattern = "(?s)function\s+$([regex]::Escape($FunctionName))\s*\{"
        $m = [regex]::Match($Source, $pattern)
        if (-not $m.Success) { throw "Function $FunctionName not found in source." }
        $i = $m.Index + $m.Length - 1
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
        Export-FunctionFromSource -Source $src -FunctionName 'Get-ResourceIdHash'
        Export-FunctionFromSource -Source $src -FunctionName 'Test-IsGitHubUsername'
        Export-FunctionFromSource -Source $src -FunctionName 'Test-HasProperty'
    ) -join "`n`n"

    $sb = [scriptblock]::Create($helpers)
    . $sb

    Assert-Equal $expectedHash (Get-ResourceIdHash -ResourceId $resourceId) 'Get-ResourceIdHash matches hand-computed value'
    Assert-Equal (Get-ResourceIdHash -ResourceId $resourceId) `
                 (Get-ResourceIdHash -ResourceId $resourceId.ToUpperInvariant()) `
                 'Get-ResourceIdHash is case-insensitive on input (lowercases internally)'

    Assert-True  (Test-IsGitHubUsername 'octocat')             'octocat is a username'
    Assert-True  (Test-IsGitHubUsername 'octo-cat-99')         'octo-cat-99 is a username'
    Assert-True  (-not (Test-IsGitHubUsername 'alice@example.com'))      'email is rejected'
    Assert-True  (-not (Test-IsGitHubUsername ''))                       'empty string is rejected'
    Assert-True  (-not (Test-IsGitHubUsername '-leading-hyphen'))        'leading hyphen is rejected'
    Assert-True  (-not (Test-IsGitHubUsername 'trailing-hyphen-'))       'trailing hyphen is rejected'
    Assert-True  (-not (Test-IsGitHubUsername 'has--double--hyphens'))   'consecutive hyphens are rejected'
    Assert-True  (-not (Test-IsGitHubUsername ('x' * 40)))               '40-char value is rejected (limit is 39)'
}
finally {
    if (Test-Path $Workdir) { Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue }
}

if ($Failures.Count -eq 0) {
    Write-Host ""
    Write-Host "Test-SendToManualQueue: all assertions passed."
    exit 0
} else {
    Write-Host ""
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
