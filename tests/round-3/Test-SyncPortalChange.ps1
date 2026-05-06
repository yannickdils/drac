#Requires -Version 7.2
# =============================================================================
# tests/round-3/Test-SyncPortalChange.ps1
# Round 3 §R3.3 acceptance test for scripts/sync/Sync-PortalChange.ps1.
#
# Strategy (no real Azure, no real GitHub):
#   1. Build a self-contained mini-repo under $env:TEMP that contains:
#        - scripts/sync/Sync-PortalChange.ps1     (copied from RepoRoot)
#        - scripts/sync/Send-ToManualQueue.ps1    (stub that just logs args)
#        - scripts/lib/ConvertForDR.psm1          (copied)
#        - scripts/lib/CommitBack.psm1            (copied)
#        - data/{reserved-names,readonly-properties}.json (copied)
#        - bicep/regions/{primary,dr}/            (created empty)
#   2. Compose a portal-changes.json with two entries: a clean Storage-account
#      change and a "dirty" Network/virtualNetworks change. The dirty branch
#      is exercised by setting DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS so the
#      decompile helper returns Success=$false WITHOUT a real bicep CLI.
#   3. Run with -DryRun and assert:
#        - sync-summary.json exists with the right counts
#        - pr-opened branch name follows the documented stable format
#        - manual-queued count == 1 and the dirty resource is the one queued
#        - DR companion file landed FLAT under bicep/regions/dr/
#        - Primary file landed under bicep/regions/primary/<rg>/
#   4. Re-run with the same input and assert:
#        - branch names are byte-identical (idempotent hashing)
#        - aggregate counts unchanged
#   5. Set DRAAC_SYNC_FORCE_EXISTING_PRS to the clean entry's branch and
#      re-run; assert the clean entry now flips to disposition=skipped.
#   6. Unit-test the helpers (Get-TypeSlug, Get-ResourceIdHash, Format-PrBody,
#      Test-LooksLikeGitHubUser) by extracting them from the source file.
#
# Exits 0 on PASS, 1 on FAIL.
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ScriptPath = Join-Path $RepoRoot 'scripts/sync/Sync-PortalChange.ps1'

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

function Assert-Match {
    param([string] $Pattern, [string] $Value, [string] $Message)
    if ($Value -notmatch $Pattern) {
        $Failures.Add("[FAIL] $Message`n         pattern: $Pattern`n         value:   $Value")
    }
}

# ── Mini-repo scaffold ───────────────────────────────────────────────────────

function New-MiniRepo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes to a per-test temp directory under $env:TEMP; system state outside the harness is unaffected.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)

    $dirs = @(
        'scripts/sync', 'scripts/lib', 'data',
        'bicep/regions/primary', 'bicep/regions/dr',
        'tests/fixtures/portal-changes'
    )
    foreach ($d in $dirs) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) }

    Copy-Item (Join-Path $RepoRoot 'scripts/sync/Sync-PortalChange.ps1') (Join-Path $Root 'scripts/sync/Sync-PortalChange.ps1') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1')      (Join-Path $Root 'scripts/lib/ConvertForDR.psm1')      -Force
    Copy-Item (Join-Path $RepoRoot 'scripts/lib/CommitBack.psm1')        (Join-Path $Root 'scripts/lib/CommitBack.psm1')        -Force
    Copy-Item (Join-Path $RepoRoot 'data/reserved-names.json')           (Join-Path $Root 'data/reserved-names.json')           -Force
    Copy-Item (Join-Path $RepoRoot 'data/readonly-properties.json')      (Join-Path $Root 'data/readonly-properties.json')      -Force

    # Stub Send-ToManualQueue.ps1: writes a JSON breadcrumb under $OutputDir
    # so the test can assert the script was invoked with the expected change.
    # (Only used when -DryRun is OFF; DryRun in Sync-PortalChange short-circuits
    # before actually running this stub. We write it anyway to prove the path
    # is wired and to keep PSScriptAnalyzer happy if anyone exercises it.)
    $stubBody = @'
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [PSCustomObject] $Change,
    [Parameter(Mandatory)] [string]         $ArmJsonPath,
    [Parameter(Mandatory)] [string]         $RepoFull,
    [Parameter(Mandatory)] [string]         $OutputDir,
    [Parameter(Mandatory)] [string]         $DecompileWarnings,
    [switch] $DryRun
)
Set-StrictMode -Version Latest
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$entry = [ordered]@{
    targetResourceId  = $Change.targetResourceId
    armJsonPath       = $ArmJsonPath
    repoFull          = $RepoFull
    dryRun            = $DryRun.IsPresent
    decompileWarnings = $DecompileWarnings
    timestamp         = (Get-Date).ToUniversalTime().ToString('o')
}
$entry | ConvertTo-Json -Depth 5 | Add-Content -Path (Join-Path $OutputDir 'manual-queue.log') -Encoding UTF8
exit 0
'@
    Set-Content -Path (Join-Path $Root 'scripts/sync/Send-ToManualQueue.ps1') -Value $stubBody -Encoding UTF8
}

function New-ChangesFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper writes a small JSON fixture inside the per-test temp tree.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $entries = @(
        [ordered]@{
            targetResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-clean-001/providers/Microsoft.Storage/storageAccounts/stcleansync001'
            targetResourceType = 'Microsoft.Storage/storageAccounts'
            subscriptionId     = '00000000-0000-0000-0000-000000000001'
            resourceGroupName  = 'rg-clean-001'
            resourceName       = 'stcleansync001'
            changeType         = 'Update'
            changedBy          = 'alice@example.com'
            timestamp          = '2026-05-04T12:34:56Z'
            changedProperties  = @('properties.tags.foo')
            skipReason         = $null
        },
        [ordered]@{
            targetResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-dirty-002/providers/Microsoft.Network/virtualNetworks/vnet-dirty-002'
            targetResourceType = 'Microsoft.Network/virtualNetworks'
            subscriptionId     = '00000000-0000-0000-0000-000000000001'
            resourceGroupName  = 'rg-dirty-002'
            resourceName       = 'vnet-dirty-002'
            changeType         = 'Update'
            changedBy          = 'octocat'
            timestamp          = '2026-05-04T13:00:00Z'
            changedProperties  = @('properties.addressSpace.addressPrefixes')
            skipReason         = $null
        }
    )
    $json = $entries | ConvertTo-Json -Depth 10 -AsArray
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

# ── Setup ────────────────────────────────────────────────────────────────────

$Workdir = Join-Path $env:TEMP "draac-sync-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Force -Path $Workdir
$MiniRepo  = Join-Path $Workdir 'repo'
$OutDir    = Join-Path $MiniRepo '_reports/sync'
$Changes   = Join-Path $MiniRepo 'tests/fixtures/portal-changes/portal-changes.json'

try {
    New-MiniRepo -Root $MiniRepo
    New-ChangesFile -Path $Changes

    $miniScript = Join-Path $MiniRepo 'scripts/sync/Sync-PortalChange.ps1'
    Assert-True (Test-Path $miniScript) 'mini-repo script copy exists'

    $cleanResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-clean-001/providers/Microsoft.Storage/storageAccounts/stcleansync001'
    $dirtyResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-dirty-002/providers/Microsoft.Network/virtualNetworks/vnet-dirty-002'

    # ── Run #1: clean + dirty ────────────────────────────────────────────────
    Write-Host ""
    Write-Host "── Run #1: one clean + one dirty ──"
    $env:DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS = $dirtyResourceId
    $env:DRAAC_SYNC_FORCE_EXISTING_PRS       = $null

    & $miniScript `
        -ChangesFile $Changes `
        -RepoRoot    $MiniRepo `
        -RepoFull    'tunecom/draac' `
        -OutputDir   $OutDir `
        -RunId       'sync-test-001' `
        -DryRun | Out-Null

    Assert-True (Test-Path (Join-Path $OutDir 'sync-summary.json')) 'sync-summary.json exists after run #1'
    $summary1 = Get-Content (Join-Path $OutDir 'sync-summary.json') -Raw | ConvertFrom-Json
    Assert-Equal 2 $summary1.totalChanges 'run #1: totalChanges == 2'
    Assert-Equal 1 $summary1.counts.'pr-opened'     'run #1: one pr-opened'
    Assert-Equal 1 $summary1.counts.'manual-queued' 'run #1: one manual-queued'
    Assert-Equal 0 $summary1.counts.'skipped'       'run #1: zero skipped'
    Assert-Equal 0 $summary1.counts.'failed'        'run #1: zero failed'

    $cleanResult = @($summary1.results) | Where-Object { $_.resourceId -eq $cleanResourceId } | Select-Object -First 1
    $dirtyResult = @($summary1.results) | Where-Object { $_.resourceId -eq $dirtyResourceId } | Select-Object -First 1
    Assert-True ($null -ne $cleanResult) 'run #1: clean change present in results'
    Assert-True ($null -ne $dirtyResult) 'run #1: dirty change present in results'
    Assert-Equal 'pr-opened'     $cleanResult.disposition 'run #1: clean change disposition is pr-opened'
    Assert-Equal 'manual-queued' $dirtyResult.disposition 'run #1: dirty change disposition is manual-queued'

    Assert-Match '^portal-sync/\d{8}-[0-9a-f]{12}$' $cleanResult.branch 'run #1: clean branch matches portal-sync/<date>-<hash12>'
    Assert-Match '^portal-sync/\d{8}-[0-9a-f]{12}$' $dirtyResult.branch 'run #1: dirty branch matches portal-sync/<date>-<hash12>'
    Assert-True ($cleanResult.branch -ne $dirtyResult.branch) 'run #1: clean and dirty branches differ'

    # Resource Graph users with @ are NOT GitHub usernames; reviewer must be null.
    Assert-True ([string]::IsNullOrEmpty($cleanResult.reviewer)) 'run #1: alice@example.com is not a GitHub login → no reviewer assigned'

    # File placement assertions on the clean change.
    $primaryRel = $cleanResult.primary
    $drRel      = $cleanResult.dr
    Assert-Match 'bicep/regions/primary/rg-clean-001/microsoft-storage-storageaccounts-stcleansync001\.bicep' $primaryRel 'run #1: primary path follows convention'
    Assert-Match 'bicep/regions/dr/dr-microsoft-storage-storageaccounts-stcleansync001\.bicep' $drRel              'run #1: dr path is FLAT under bicep/regions/dr/'
    Assert-True (Test-Path (Join-Path $MiniRepo $primaryRel)) 'run #1: primary bicep file landed on disk'
    Assert-True (Test-Path (Join-Path $MiniRepo $drRel))      'run #1: dr bicep file landed on disk'

    # ── Run #2: idempotency ──────────────────────────────────────────────────
    Write-Host ""
    Write-Host "── Run #2: idempotency (same input → same branch names) ──"
    & $miniScript `
        -ChangesFile $Changes `
        -RepoRoot    $MiniRepo `
        -RepoFull    'tunecom/draac' `
        -OutputDir   $OutDir `
        -RunId       'sync-test-002' `
        -DryRun | Out-Null

    $summary2 = Get-Content (Join-Path $OutDir 'sync-summary.json') -Raw | ConvertFrom-Json
    Assert-Equal $summary1.counts.'pr-opened'     $summary2.counts.'pr-opened'     'run #2: pr-opened count stable'
    Assert-Equal $summary1.counts.'manual-queued' $summary2.counts.'manual-queued' 'run #2: manual-queued count stable'
    Assert-Equal $summary1.counts.'failed'        $summary2.counts.'failed'        'run #2: failed count stable'

    $cleanResult2 = @($summary2.results) | Where-Object { $_.resourceId -eq $cleanResourceId } | Select-Object -First 1
    $dirtyResult2 = @($summary2.results) | Where-Object { $_.resourceId -eq $dirtyResourceId } | Select-Object -First 1
    Assert-Equal $cleanResult.branch $cleanResult2.branch 'run #2: clean branch name stable across runs'
    Assert-Equal $dirtyResult.branch $dirtyResult2.branch 'run #2: dirty branch name stable across runs'

    # ── Run #3: existing-PR short-circuit ────────────────────────────────────
    Write-Host ""
    Write-Host "── Run #3: forced-existing-PR → skipped ──"
    $env:DRAAC_SYNC_FORCE_EXISTING_PRS = $cleanResult.branch
    & $miniScript `
        -ChangesFile $Changes `
        -RepoRoot    $MiniRepo `
        -RepoFull    'tunecom/draac' `
        -OutputDir   $OutDir `
        -RunId       'sync-test-003' `
        -DryRun | Out-Null
    $env:DRAAC_SYNC_FORCE_EXISTING_PRS = $null

    $summary3 = Get-Content (Join-Path $OutDir 'sync-summary.json') -Raw | ConvertFrom-Json
    $cleanResult3 = @($summary3.results) | Where-Object { $_.resourceId -eq $cleanResourceId } | Select-Object -First 1
    Assert-Equal 'skipped' $cleanResult3.disposition 'run #3: clean change is now skipped (PR already open)'
    Assert-Equal 'duplicate-pr-open' $cleanResult3.reason 'run #3: skip reason recorded'
    Assert-True ($summary3.counts.'skipped' -ge 1) 'run #3: at least one skipped'

    # Branch name must still match the original (skip path uses the same hash).
    Assert-Equal $cleanResult.branch $cleanResult3.branch 'run #3: branch name still stable on skip path'

    # ── Helper unit tests ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "── helper unit tests ──"
    $src = Get-Content $ScriptPath -Raw

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
        Export-FunctionFromSource -Source $src -FunctionName 'Get-TypeSlug'
        Export-FunctionFromSource -Source $src -FunctionName 'Get-ResourceIdHash'
        Export-FunctionFromSource -Source $src -FunctionName 'Get-PortalUrl'
        Export-FunctionFromSource -Source $src -FunctionName 'Test-LooksLikeGitHubUser'
    ) -join "`n`n"
    $sb = [scriptblock]::Create($helpers)
    . $sb

    Assert-Equal 'microsoft-network-virtualnetworks'   (Get-TypeSlug -Type 'Microsoft.Network/virtualNetworks')   'slug: virtualNetworks'
    Assert-Equal 'microsoft-storage-storageaccounts'   (Get-TypeSlug -Type 'Microsoft.Storage/storageAccounts')   'slug: storageAccounts'
    Assert-Equal 'microsoft-network-virtualnetworks-subnets' (Get-TypeSlug -Type 'Microsoft.Network/virtualNetworks/subnets') 'slug: nested type'

    $h1 = Get-ResourceIdHash -ResourceId '/subscriptions/x/y'
    $h2 = Get-ResourceIdHash -ResourceId '/subscriptions/x/y'
    $h3 = Get-ResourceIdHash -ResourceId '/subscriptions/x/Y'   # case-insensitive stability
    $h4 = Get-ResourceIdHash -ResourceId '/subscriptions/x/z'
    Assert-Equal 12 $h1.Length 'hash is 12 hex chars by default'
    Assert-Match '^[0-9a-f]{12}$' $h1 'hash is hexadecimal'
    Assert-Equal $h1 $h2 'hash is deterministic'
    Assert-Equal $h1 $h3 'hash is case-insensitive on resource id'
    Assert-True ($h1 -ne $h4) 'hash differs for different ids'

    Assert-Equal 'https://portal.azure.com/#@/resource/subscriptions/x/y' (Get-PortalUrl -ResourceId '/subscriptions/x/y') 'portal url format'

    Assert-True  (Test-LooksLikeGitHubUser -Candidate 'octocat')           'github-user: simple'
    Assert-True  (Test-LooksLikeGitHubUser -Candidate 'gh-user-1')         'github-user: with dashes'
    Assert-True  (-not (Test-LooksLikeGitHubUser -Candidate 'alice@x.com')) 'github-user: rejects emails'
    Assert-True  (-not (Test-LooksLikeGitHubUser -Candidate ''))            'github-user: rejects empty'
    Assert-True  (-not (Test-LooksLikeGitHubUser -Candidate '-bad'))        'github-user: rejects leading dash'
    Assert-True  (-not (Test-LooksLikeGitHubUser -Candidate 'has spaces'))  'github-user: rejects spaces'
}
finally {
    if (Test-Path $Workdir) {
        Remove-Item -Recurse -Force $Workdir -ErrorAction SilentlyContinue
    }
    $env:DRAAC_SYNC_FORCE_DIRTY_RESOURCE_IDS = $null
    $env:DRAAC_SYNC_FORCE_EXISTING_PRS       = $null
}

if ($Failures.Count -eq 0) {
    Write-Host ""
    Write-Host "Test-SyncPortalChange: all assertions passed."
    exit 0
} else {
    Write-Host ""
    Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
    exit 1
}
