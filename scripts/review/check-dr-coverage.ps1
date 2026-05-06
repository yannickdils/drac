#Requires -Version 7.2
# =============================================================================
# scripts/review/check-dr-coverage.ps1
# Round 2 §R2.1 — DR coverage gate.
#
# For every PR-changed Bicep file under bicep/regions/primary/, verifies that
# a matching DR companion exists at bicep/regions/dr/dr-<workload>.bicep.
# When a companion is missing, attempts to auto-generate it by:
#   1. `bicep build` on the primary file -> compiled ARM JSON.
#   2. Convert-ForDR on the compiled ARM (scripts/lib/ConvertForDR.psm1).
#   3. `bicep decompile` on the transformed ARM -> DR Bicep file.
# Auto-generated files are committed back to the PR branch via the shared
# scripts/lib/CommitBack.psm1 helper (which is also used by
# scripts/drift/commit-drift-readme.ps1).
#
# Idempotent: re-running on a fully-covered repo produces an unchanged report.
# Fault-tolerant: per-file generation failures are recorded as
#                 "coverage: failed" and do not abort the run.
#
# Outputs:
#   _reports/coverage/coverage-report.json
#   GitHub Actions output DR_COVERAGE_OK=true|false
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PrChangesFile,
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $OutputDir,

    # DR transform parameters — defaulted from environment variables for
    # parity with the rest of the pipeline; explicit args win.
    [string] $DrRegion       = $(if ($env:DR_TARGET_REGION)         { $env:DR_TARGET_REGION }         else { 'northeurope' }),
    [string] $DrVnetPrefix   = $(if ($env:DR_VNET_ADDRESS_PREFIX)   { $env:DR_VNET_ADDRESS_PREFIX }   else { '10.100.0.0/16' }),
    [string] $DrSubnetPrefix = $(if ($env:DR_SUBNET_ADDRESS_PREFIX) { $env:DR_SUBNET_ADDRESS_PREFIX } else { '10.100.0.0/24' }),
    [string] $DrNamingPrefix = $(if ($env:DR_NAMING_PREFIX)         { $env:DR_NAMING_PREFIX }         else { 'dr-' }),

    # Commit-back controls. When -CommitBack is not set the script only
    # produces the report and is read-only on the working tree.
    [switch] $CommitBack,
    [string] $PrBranch,
    [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Paths and module loading ─────────────────────────────────────────────────
$RepoRoot   = (Resolve-Path $RepoRoot).Path
$PrimaryDir = Join-Path $RepoRoot 'bicep/regions/primary'
$DrDir      = Join-Path $RepoRoot 'bicep/regions/dr'

$ConvertModule    = Join-Path $RepoRoot 'scripts/lib/ConvertForDR.psm1'
$CommitBackModule = Join-Path $RepoRoot 'scripts/lib/CommitBack.psm1'

if (-not (Test-Path $ConvertModule)) {
    Write-Error "Required module not found: $ConvertModule"
    exit 2
}
Import-Module $ConvertModule -Force

$null = New-Item -ItemType Directory -Force -Path $OutputDir
$ReportFile = Join-Path $OutputDir 'coverage-report.json'

Write-Host "============================================================"
Write-Host "STAGE 3b: DR Coverage Gate"
Write-Host "  PR changes:  $PrChangesFile"
Write-Host "  Primary dir: $PrimaryDir"
Write-Host "  DR dir:      $DrDir"
Write-Host "  Output:      $OutputDir"
Write-Host "============================================================"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Strict-mode-safe property accessor — see Round 1 ConvertForDR.psm1 rationale.
function Test-HasProperty {
    param($Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -isnot [System.Management.Automation.PSObject] -and `
        $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ChangedPrimaryBicepPath {
    param([Parameter(Mandatory)] [string] $ChangesFile)

    if (-not (Test-Path $ChangesFile)) {
        Write-Warning "PR changes file not found: $ChangesFile — treating as empty change set"
        return @()
    }

    $raw = Get-Content $ChangesFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $parsed = $raw | ConvertFrom-Json -Depth 10

    # ConvertFrom-Json unwraps a single-element top-level JSON array into a bare
    # PSCustomObject, so we must detect three cases:
    #   1. multi-item array  → already enumerable
    #   2. single-item array → unwrapped to one PSCustomObject with `path`
    #   3. wrapped object    → has a `changes` property holding the array
    $items = if ($parsed -is [System.Collections.IList]) {
        @($parsed)
    } elseif ($parsed -is [System.Management.Automation.PSCustomObject] -and (Test-HasProperty $parsed 'changes')) {
        @($parsed.changes)
    } elseif ($parsed -is [System.Management.Automation.PSCustomObject] -and (Test-HasProperty $parsed 'path')) {
        @($parsed)
    } else {
        @()
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $items) {
        if (-not (Test-HasProperty $entry 'path')) { continue }
        $p = $entry.path
        if ($p -isnot [string] -or [string]::IsNullOrEmpty($p)) { continue }
        # Normalise to forward slashes for cross-platform comparison.
        $norm = $p -replace '\\', '/'
        if ($norm -match '(?i)^bicep/regions/primary/.+\.bicep$') {
            $paths.Add($norm)
        }
    }
    return @($paths.ToArray() | Sort-Object -Unique)
}

function Get-DrCompanionPath {
    param([Parameter(Mandatory)] [string] $PrimaryPath)
    # Convention: bicep/regions/primary/foo.bicep ↔ bicep/regions/dr/dr-foo.bicep
    $leaf = [System.IO.Path]::GetFileName($PrimaryPath)
    if ($leaf.StartsWith('dr-')) { return "bicep/regions/dr/$leaf" }
    return "bicep/regions/dr/dr-$leaf"
}

# ── R4.3 — Front Door coverage extension ────────────────────────────────────
# A workload that exposes any of these resource types is "public-facing" and
# the brief mandates a Front Door reference (`dr-traffic.bicep`) on the DR
# companion. The coverage gate fails if the companion exists but does not
# reference the traffic module.

$script:PublicFacingTypes = @(
    'Microsoft.Web/sites',
    'Microsoft.ContainerService/managedClusters',
    'Microsoft.Network/applicationGateways'
)

function Test-IsPublicFacingPrimary {
    <#
    .SYNOPSIS Returns $true when the primary Bicep file declares any of the public-facing types.
    .NOTES Text inspection of the source — sufficient because Bicep type strings
           appear literally in `resource X 'Microsoft.Foo/bar@version' = { ... }`
           declarations. Cheaper than compiling the file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $PrimaryFullPath)

    if (-not (Test-Path $PrimaryFullPath)) { return $false }
    $content = Get-Content -Raw -Path $PrimaryFullPath -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return $false }
    foreach ($t in $script:PublicFacingTypes) {
        # Match the type token followed by `@version` (declaration form) — avoids
        # false positives from comments or string literals that mention the type.
        $pattern = [regex]::Escape($t) + "@"
        if ([regex]::IsMatch($content, $pattern)) { return $true }
    }
    return $false
}

function Test-DrCompanionReferencesTraffic {
    <#
    .SYNOPSIS Returns $true when the DR companion Bicep references dr-traffic.bicep.
    .NOTES Matches both `module ... '../modules/dr-traffic.bicep'` and the
           hypothetical relative form. Bicep imports are quoted so a simple
           substring search is unambiguous.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $DrFullPath)

    if (-not (Test-Path $DrFullPath)) { return $false }
    $content = Get-Content -Raw -Path $DrFullPath -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return $false }
    return ($content -match "dr-traffic\.bicep")
}

function Test-BicepCliAvailable {
    # Both the standalone `bicep` and `az bicep` shapes are accepted.
    if (Get-Command bicep -ErrorAction SilentlyContinue) { return 'bicep' }
    if (Get-Command az     -ErrorAction SilentlyContinue) { return 'az' }
    return $null
}

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory)] [string] $InFile,
        [Parameter(Mandatory)] [string] $OutFile,
        [Parameter(Mandatory)] [string] $Cli
    )
    if ($Cli -eq 'bicep') {
        & bicep build $InFile --outfile $OutFile 2>&1 | Out-Null
    } else {
        & az bicep build --file $InFile --outfile $OutFile 2>&1 | Out-Null
    }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-BicepDecompile {
    param(
        [Parameter(Mandatory)] [string] $InFile,
        [Parameter(Mandatory)] [string] $OutFile,
        [Parameter(Mandatory)] [string] $Cli
    )
    $outDir = [System.IO.Path]::GetDirectoryName($OutFile)
    if ($Cli -eq 'bicep') {
        & bicep decompile $InFile --outdir $outDir 2>&1 | Out-Null
    } else {
        & az bicep decompile --file $InFile --outdir $outDir 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { return $false }

    # Decompile produces a file named after the ARM file's stem; rename to the
    # exact target filename so the convention holds.
    $stem      = [System.IO.Path]::GetFileNameWithoutExtension($InFile)
    $produced  = Join-Path $outDir "$stem.bicep"
    if ((Test-Path $produced) -and ($produced -ne $OutFile)) {
        Move-Item -Force -Path $produced -Destination $OutFile
    }
    return (Test-Path $OutFile)
}

function Invoke-AutoGenerateDrCompanion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PrimaryFullPath,
        [Parameter(Mandatory)] [string] $DrFullPath,
        [Parameter(Mandatory)] [string] $WorkDir,
        [Parameter(Mandatory)] [string] $TargetDrRegion,
        [Parameter(Mandatory)] [string] $TargetDrVnetPrefix,
        [Parameter(Mandatory)] [string] $TargetDrSubnetPrefix,
        [Parameter(Mandatory)] [string] $TargetDrNamingPrefix
    )

    $cli = Test-BicepCliAvailable
    if (-not $cli) {
        return [PSCustomObject]@{ Success = $false; Reason = 'bicep CLI not available (no `bicep` or `az` on PATH)' }
    }

    $null = New-Item -ItemType Directory -Force -Path $WorkDir
    $primaryArm     = Join-Path $WorkDir 'primary.json'
    $transformedArm = Join-Path $WorkDir 'dr.json'

    if (-not (Invoke-BicepBuild -InFile $PrimaryFullPath -OutFile $primaryArm -Cli $cli)) {
        return [PSCustomObject]@{ Success = $false; Reason = 'bicep build failed' }
    }

    try {
        $template = Get-Content $primaryArm -Raw | ConvertFrom-Json -Depth 50
    } catch {
        return [PSCustomObject]@{ Success = $false; Reason = "ARM parse failed: $_" }
    }

    try {
        $result = Convert-ForDR -Template $template `
            -DrRegion       $TargetDrRegion `
            -DrVnetPrefix   $TargetDrVnetPrefix `
            -DrSubnetPrefix $TargetDrSubnetPrefix `
            -DrNamingPrefix $TargetDrNamingPrefix
    } catch {
        return [PSCustomObject]@{ Success = $false; Reason = "Convert-ForDR failed: $_" }
    }

    try {
        $result.Template | ConvertTo-Json -Depth 30 | Set-Content $transformedArm -Encoding UTF8
    } catch {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not write transformed ARM: $_" }
    }

    $null = New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($DrFullPath))
    if (-not (Invoke-BicepDecompile -InFile $transformedArm -OutFile $DrFullPath -Cli $cli)) {
        return [PSCustomObject]@{ Success = $false; Reason = 'bicep decompile failed' }
    }

    return [PSCustomObject]@{ Success = $true; Reason = 'auto-generated' }
}

# ── Main flow ────────────────────────────────────────────────────────────────

# Wrap with @(...) so the caller always gets a real array — Get-ChangedPrimaryBicepPath
# can return nothing (empty change set), which PowerShell unwraps to $null otherwise.
$changedPrimaries = @(Get-ChangedPrimaryBicepPath -ChangesFile $PrChangesFile)
Write-Host "INFO: $($changedPrimaries.Count) primary Bicep file(s) changed in PR"

$results       = [System.Collections.Generic.List[object]]::new()
$autoGenerated = [System.Collections.Generic.List[string]]::new()
$anyFailed     = $false

foreach ($rel in $changedPrimaries) {
    $primaryFull = Join-Path $RepoRoot $rel
    if (-not (Test-Path $primaryFull)) {
        # File was deleted in the PR — companions are intentionally orphaned.
        $results.Add([PSCustomObject]@{
            primary  = $rel
            dr       = $null
            coverage = 'ok'
            reason   = 'primary file deleted in PR — no companion required'
        })
        Write-Host "  - $rel : deleted, skipping"
        continue
    }

    $drRel  = Get-DrCompanionPath -PrimaryPath $rel
    $drFull = Join-Path $RepoRoot $drRel

    if (Test-Path $drFull) {
        # R4.3: public-facing workloads must reference dr-traffic.bicep.
        if ((Test-IsPublicFacingPrimary -PrimaryFullPath $primaryFull) -and `
            -not (Test-DrCompanionReferencesTraffic -DrFullPath $drFull)) {
            $anyFailed = $true
            $results.Add([PSCustomObject]@{
                primary  = $rel
                dr       = $drRel
                coverage = 'failed'
                reason   = 'public-facing workload must reference bicep/modules/dr-traffic.bicep (R4.3)'
            })
            Write-Warning "  ! $rel : public-facing workload missing dr-traffic.bicep reference in $drRel"
            continue
        }

        $results.Add([PSCustomObject]@{
            primary  = $rel
            dr       = $drRel
            coverage = 'ok'
            reason   = 'DR companion already exists'
        })
        Write-Host "  + $rel : ok (companion present)"
        continue
    }

    Write-Host "  ! $rel : missing DR companion ($drRel) — attempting auto-generation"
    $workDir = Join-Path $OutputDir ('work-' + [System.IO.Path]::GetFileNameWithoutExtension($rel))
    $gen = Invoke-AutoGenerateDrCompanion `
        -PrimaryFullPath      $primaryFull `
        -DrFullPath           $drFull `
        -WorkDir              $workDir `
        -TargetDrRegion       $DrRegion `
        -TargetDrVnetPrefix   $DrVnetPrefix `
        -TargetDrSubnetPrefix $DrSubnetPrefix `
        -TargetDrNamingPrefix $DrNamingPrefix

    if ($gen.Success) {
        # R4.3: even after auto-generation, public-facing workloads need a
        # manual edit to reference dr-traffic.bicep. The auto-gen path can't
        # synthesise that — fail loudly with a remediation hint.
        if ((Test-IsPublicFacingPrimary -PrimaryFullPath $primaryFull) -and `
            -not (Test-DrCompanionReferencesTraffic -DrFullPath $drFull)) {
            $anyFailed = $true
            $results.Add([PSCustomObject]@{
                primary  = $rel
                dr       = $drRel
                coverage = 'failed'
                reason   = 'auto-generated companion is missing dr-traffic.bicep reference; add `module traffic ''../../modules/dr-traffic.bicep'' = { ... }` to the DR file (R4.3)'
            })
            Write-Warning "    -> auto-generated companion needs manual dr-traffic.bicep wiring: $drRel"
        }
        else {
            $results.Add([PSCustomObject]@{
                primary  = $rel
                dr       = $drRel
                coverage = 'auto-generated'
                reason   = $gen.Reason
            })
            $autoGenerated.Add($drRel)
            Write-Host "    -> auto-generated: $drRel"
        }
    } else {
        $anyFailed = $true
        $results.Add([PSCustomObject]@{
            primary  = $rel
            dr       = $drRel
            coverage = 'failed'
            reason   = $gen.Reason
        })
        Write-Warning "    -> failed: $($gen.Reason)"
    }
}

$coverageOk = -not $anyFailed

$report = [ordered]@{
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    repoRoot       = $RepoRoot
    drRegion       = $DrRegion
    drNamingPrefix = $DrNamingPrefix
    coverageOk     = $coverageOk
    totalChecked   = $results.Count
    autoGenerated  = $autoGenerated.Count
    failed         = @($results | Where-Object { $_.coverage -eq 'failed' }).Count
    results        = $results
}
$report | ConvertTo-Json -Depth 30 | Set-Content $ReportFile -Encoding UTF8

# ── GitHub Actions output ────────────────────────────────────────────────────
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("DR_COVERAGE_OK=" + ($coverageOk.ToString().ToLower())) -Encoding UTF8
}

# ── Commit-back of auto-generated companions ─────────────────────────────────
if ($CommitBack -and $autoGenerated.Count -gt 0) {
    if (-not (Test-Path $CommitBackModule)) {
        Write-Warning "CommitBack module missing: $CommitBackModule — skipping commit-back"
    }
    elseif (-not $PrBranch) {
        Write-Warning "Commit-back requested but -PrBranch not provided — skipping"
    }
    else {
        Import-Module $CommitBackModule -Force
        $effectiveRunId = if ($RunId) { $RunId } else { 'unknown' }
        $absFiles = $autoGenerated | ForEach-Object { Join-Path $RepoRoot $_ }
        $null = Push-Branch `
            -RepoRoot $RepoRoot `
            -Branch   $PrBranch `
            -RunId    $effectiveRunId `
            -Files    $absFiles `
            -Message  "chore(draac): auto-generate DR companions"
    }
}

# ── Console summary ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "DR COVERAGE: ok=$coverageOk  checked=$($results.Count)  auto-generated=$($autoGenerated.Count)  failed=$($report.failed)"
Write-Host "  Report: $ReportFile"

if ($coverageOk) { exit 0 } else { exit 1 }
