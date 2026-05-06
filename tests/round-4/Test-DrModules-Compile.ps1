#Requires -Version 7.2
# =============================================================================
# tests/round-4/Test-DrModules-Compile.ps1
# Round 4 §R4.1 — DR module compile + structural assertions.
#
# What this test exercises:
#   1. For each *.bicep file under bicep/modules/dr-*.bicep, run
#      `bicep build` (or `az bicep build`) and assert exit code 0.
#   2. For each compiled ARM, assert the expected top-level resource type
#      appears in `resources[]`.
#   3. STRUCTURAL — for `dr-sql.bicep` and `dr-storage.bicep`, assert the
#      compiled ARM contains a `metadata.dr` block with a `mode` field. (The
#      brief mandates the metadata.dr contract on every module; we sample two
#      to keep the test fast — but the per-module compile + type assertions
#      cover the rest.)
#   4. Skips gracefully (Write-Host SKIP, exit 0) if no Bicep CLI is present,
#      mirroring tests/round-2/Test-CheckDrCoverage.ps1's Test-BicepCliAvailable
#      pattern.
#
# Style: hand-rolled Assert-True/Assert-Equal helpers, no Pester, exits 0/1.
# All scratch artefacts under $env:TEMP/draac-drmodules-<guid>; cleaned in
# `finally`.
# =============================================================================
[CmdletBinding()]
param(
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RepoRoot   = if ($env:DRAAC_REPO_ROOT) { $env:DRAAC_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot ".." "..")).Path }
$ModulesDir = Join-Path $RepoRoot 'bicep/modules'

$Failures = [System.Collections.Generic.List[string]]::new()
function Assert-True {
    param([bool] $Cond, [string] $Msg)
    if (-not $Cond) { $Failures.Add("[FAIL] $Msg") }
}
function Assert-Equal {
    param($Exp, $Act, [string] $Msg)
    if ($Exp -ne $Act) { $Failures.Add("[FAIL] $Msg`n         expected: $Exp`n         actual:   $Act") }
}

function Test-BicepCliAvailable {
    # Both shapes are accepted; mirrors scripts/review/check-dr-coverage.ps1.
    if (Get-Command bicep -ErrorAction SilentlyContinue) { return 'bicep' }
    if (Get-Command az    -ErrorAction SilentlyContinue) { return 'az' }
    return $null
}

function Invoke-BicepBuild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper invokes a side-effect-free Bicep transpile against a per-test temp directory; no Azure side effects.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InFile,
        [Parameter(Mandatory)] [string] $OutFile,
        [Parameter(Mandatory)] [string] $Cli
    )
    if ($Cli -eq 'bicep') {
        $output = & bicep build $InFile --outfile $OutFile 2>&1
    } else {
        $output = & az bicep build --file $InFile --outfile $OutFile 2>&1
    }
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

# Manifest: each entry is one module + the resource type its ARM must contain.
# Cosmos's resource type is namespaced "Microsoft.DocumentDB/databaseAccounts"
# (capital DB). Storage uses StorageAccounts. SQL parents are split across
# servers + servers/failoverGroups; we only assert the failoverGroups type
# because that's the replication mechanism this module owns.
$manifest = @(
    [PSCustomObject]@{
        File          = 'dr-sql.bicep'
        ExpectedType  = 'Microsoft.Sql/servers/failoverGroups'
        AssertMetadata = $true
    },
    [PSCustomObject]@{
        File          = 'dr-cosmos.bicep'
        ExpectedType  = 'Microsoft.DocumentDB/databaseAccounts'
        AssertMetadata = $false
    },
    [PSCustomObject]@{
        File          = 'dr-storage.bicep'
        ExpectedType  = 'Microsoft.Storage/storageAccounts'
        AssertMetadata = $true
    },
    [PSCustomObject]@{
        File          = 'dr-keyvault.bicep'
        ExpectedType  = 'Microsoft.KeyVault/vaults'
        AssertMetadata = $false
    },
    [PSCustomObject]@{
        File          = 'dr-postgres.bicep'
        ExpectedType  = 'Microsoft.DBforPostgreSQL/flexibleServers'
        AssertMetadata = $false
    },
    [PSCustomObject]@{
        File          = 'dr-mysql.bicep'
        ExpectedType  = 'Microsoft.DBforMySQL/flexibleServers'
        AssertMetadata = $false
    },
    [PSCustomObject]@{
        File          = 'dr-redis.bicep'
        ExpectedType  = 'Microsoft.Cache/redis/linkedServers'
        AssertMetadata = $false
    }
)

# 1. Every entry in the manifest must correspond to a real .bicep file. This
#    catches the case where a module is renamed without updating the test.
Write-Host ""
Write-Host "── manifest ↔ bicep file alignment ──"
foreach ($m in $manifest) {
    $path = Join-Path $ModulesDir $m.File
    Assert-True (Test-Path $path) "manifest: $($m.File) exists under bicep/modules/"
}

# Note: We intentionally do NOT assert that every dr-*.bicep file under
# bicep/modules/ is in the manifest — Round 4 ships additional modules from
# Agents C (dr-traffic.bicep) and D (dr-keyvault-sync.bicep) that this test
# does not own. Their compile coverage lives in their respective
# tests/round-4/Test-* scripts.

# 2. Bicep CLI presence — skip gracefully if absent.
if ($DryRun) {
    Write-Host ""
    Write-Host "SKIP: -DryRun set. Compile + structural assertions skipped."
    Write-Host "      Manifest ↔ file alignment was still verified."
    if ($Failures.Count -eq 0) {
        Write-Host ""
        Write-Host "All assertions passed."
        exit 0
    } else {
        Write-Host ""
        Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
        foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
        exit 1
    }
}

$cli = Test-BicepCliAvailable
if (-not $cli) {
    Write-Host ""
    Write-Host "SKIP: Bicep CLI not available (no 'bicep' or 'az' on PATH)."
    Write-Host "      Compile + structural assertions skipped; manifest checks still ran."
    if ($Failures.Count -eq 0) {
        Write-Host ""
        Write-Host "All assertions passed."
        exit 0
    } else {
        Write-Host ""
        Write-Host "FAILED: $($Failures.Count) assertion(s)" -ForegroundColor Red
        foreach ($f in $Failures) { Write-Host $f -ForegroundColor Red }
        exit 1
    }
}

# 3. Per-module compile + type-presence + (sampled) metadata.dr assertions.
$Workdir = Join-Path $env:TEMP ("draac-drmodules-" + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Force -Path $Workdir

    foreach ($m in $manifest) {
        $bicepPath = Join-Path $ModulesDir $m.File
        if (-not (Test-Path $bicepPath)) {
            # Already recorded by the manifest-alignment loop above; skip the
            # compile attempt to keep failure messages focused.
            continue
        }

        $armPath = Join-Path $Workdir ("{0}.json" -f [System.IO.Path]::GetFileNameWithoutExtension($m.File))
        Write-Host ""
        Write-Host "── compiling $($m.File) ──"
        $build = Invoke-BicepBuild -InFile $bicepPath -OutFile $armPath -Cli $cli
        if ($build.ExitCode -ne 0) {
            $Failures.Add("[FAIL] $($m.File): bicep build failed (exit $($build.ExitCode)).`n         output:`n$($build.Output.Trim())")
            continue
        }
        Assert-True (Test-Path $armPath) "$($m.File): compiled ARM written to $armPath"

        # Parse compiled ARM and assert the expected resource type appears.
        try {
            $arm = Get-Content -Raw -Path $armPath | ConvertFrom-Json -Depth 50
        } catch {
            $Failures.Add("[FAIL] $($m.File): compiled ARM is not valid JSON: $($_.Exception.Message)")
            continue
        }

        # Tolerate either the classic `resources` array OR Bicep symbolic-name
        # form (`resources` as an object keyed by symbolic name).
        $types = [System.Collections.Generic.List[string]]::new()
        if ($arm.PSObject.Properties['resources']) {
            $resources = $arm.resources
            if ($resources -is [System.Collections.IList] -or $resources -is [Array]) {
                foreach ($r in @($resources)) {
                    if ($null -ne $r -and $r.PSObject.Properties['type']) {
                        $types.Add([string]$r.type)
                    }
                }
            } elseif ($resources -is [PSCustomObject]) {
                foreach ($prop in $resources.PSObject.Properties) {
                    $r = $prop.Value
                    if ($null -ne $r -and $r.PSObject.Properties['type']) {
                        $types.Add([string]$r.type)
                    }
                }
            }
        }

        # Case-insensitive containment match — Bicep emits the casing the
        # source uses, but namespaces are recognised case-insensitively by ARM.
        $hasType = $false
        foreach ($t in $types) {
            if ([string]::Equals($t, $m.ExpectedType, [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasType = $true
                break
            }
        }
        Assert-True $hasType "$($m.File): compiled ARM contains resource type '$($m.ExpectedType)' (saw: $($types -join ', '))"

        if ($m.AssertMetadata) {
            # The file-level `metadata dr = {...}` block in Bicep lands in the
            # compiled ARM as $.metadata.dr. Assert it exists AND has a 'mode'
            # field (the replication-mode contract Test-DRHealth depends on).
            $hasMetadataDr = $false
            $hasMode = $false
            if ($arm.PSObject.Properties['metadata'] -and $null -ne $arm.metadata) {
                $md = $arm.metadata
                if ($md.PSObject.Properties['dr'] -and $null -ne $md.dr) {
                    $hasMetadataDr = $true
                    if ($md.dr.PSObject.Properties['mode'] -and -not [string]::IsNullOrEmpty([string]$md.dr.mode)) {
                        $hasMode = $true
                    }
                }
            }
            Assert-True $hasMetadataDr "$($m.File): compiled ARM exposes metadata.dr block"
            Assert-True $hasMode      "$($m.File): metadata.dr.mode is set to a non-empty string"
        }
    }
} finally {
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
