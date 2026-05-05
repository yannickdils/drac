#Requires -Version 7.2
# =============================================================================
# scripts/dr/deploy-dr-region.ps1
# Stage 7 (Round 2.2): Deploy every dr-<workload>.bicep under bicep/regions/dr/
# to its conventional resource group rg-<workload>-dr in the DR region.
#
# Resource group convention:
#   bicep/regions/dr/dr-<workload>.bicep -> rg-<workload>-dr
#   <workload> derived from the filename ("dr-anchor.bicep" -> "anchor").
#
# Deterministic deployment names:
#   draac-<sha7>-rg-<workload>-dr
#   Re-runs with the same commit SHA + same template are no-ops; Azure dedupes
#   deployments by name within a resource group.
#
# Per-RG fault tolerance: a failure in one workload is logged to
# _reports/deploy/failures.json and the run continues with the next file.
#
# Throttling retry: HTTP 429 / ThrottlingException is retried with exponential
# backoff (5s, 15s, 45s, 135s) before being logged as a permanent failure.
#
# Test-DRHealth post-deploy verification is deferred to Round 4.2 — there is a
# placeholder comment below where its invocation will land.
#
# Azure CLI references (latest at time of writing):
#   az group create:
#     https://learn.microsoft.com/cli/azure/group#az-group-create
#   az deployment group what-if:
#     https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-what-if
#   az deployment group create:
#     https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-create
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BicepDir,
    [Parameter(Mandatory)] [string] $DrRegion,
    [Parameter(Mandatory)] [string] $CommitSha,
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $OutputDir,

    # Test seam: in DryRun mode the script never invokes az and instead emits
    # synthetic success records. The Round 2 harness uses this so it can run
    # without a real Azure subscription.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-DrWorkloadName {
    <#
    .SYNOPSIS
    Derives the <workload> token from a `dr-<workload>.bicep` filename.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $FileName
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($base -notmatch '^dr-(.+)$') {
        throw "Filename '$FileName' does not match the dr-<workload>.bicep convention."
    }
    return $Matches[1]
}

function Get-DeterministicDeploymentName {
    <#
    .SYNOPSIS
    Builds the deterministic deployment name `draac-<sha7>-rg-<workload>-dr`.
    Azure deployment names are limited to 64 characters; this format stays
    well under that for any realistic workload name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $CommitSha,
        [Parameter(Mandatory)] [string] $Workload
    )
    if ($CommitSha.Length -lt 7) {
        throw "CommitSha '$CommitSha' is too short; need at least 7 characters."
    }
    $sha7 = $CommitSha.Substring(0, 7)
    return "draac-$sha7-rg-$Workload-dr"
}

function Invoke-AzWithRetry {
    <#
    .SYNOPSIS
    Invokes a script block (which calls `az ...`) with exponential-backoff
    retries on HTTP 429 / ThrottlingException. After the configured backoff
    sequence is exhausted, the last error is rethrown.

    .PARAMETER ScriptBlock
    The script block to invoke. It is expected to call `az` and either return
    its stdout or throw. The block is responsible for inspecting $LASTEXITCODE
    and converting non-zero exits + throttling output into terminating errors
    (see the Invoke-AzCommand helper below).

    .PARAMETER Operation
    Free-text label used in progress logging.

    .PARAMETER BackoffSeconds
    Override the default backoff sequence (5,15,45,135). Tests pass a short
    sequence so the throttling path can be exercised in milliseconds.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'Operation is referenced inside the closure-captured catch block via $Operation; the analyzer does not see closure use.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory)] [string]      $Operation,
        [int[]]                              $BackoffSeconds = @(5, 15, 45, 135)
    )

    $attempt = 0
    $maxAttempts = $BackoffSeconds.Count + 1   # initial try + N retries
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $msg = "$_"
            $isThrottle = ($msg -match 'ThrottlingException' -or $msg -match '\b429\b' -or $msg -match 'Too Many Requests')
            if (-not $isThrottle -or $attempt -ge $maxAttempts) {
                throw
            }
            $wait = $BackoffSeconds[$attempt - 1]
            Write-Host "  THROTTLED ($Operation) — sleep ${wait}s (attempt $attempt/$maxAttempts)"
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-AzCommand {
    <#
    .SYNOPSIS
    Thin wrapper around `az` that captures stdout+stderr, inspects
    $LASTEXITCODE, and converts non-zero exits into terminating errors so
    Invoke-AzWithRetry can detect throttling.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList
    )
    $output = & az @ArgumentList 2>&1
    $exit   = $LASTEXITCODE
    $joined = ($output | Out-String)
    if ($exit -ne 0) {
        throw "az $($ArgumentList -join ' ') failed with exit $exit`: $joined"
    }
    return $joined
}

function New-DrResourceGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The Azure side is idempotent (az group create is upsert); ShouldProcess would be noisy without value.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Location,
        [Parameter(Mandatory)] [string] $Workload,
        [Parameter(Mandatory)] [string] $RunId
    )
    $argList = @(
        'group', 'create',
        '--name', $ResourceGroup,
        '--location', $Location,
        '--tags',
            "draac=true",
            "draac-role=dr",
            "draac-workload=$Workload",
            "draac-run-id=$RunId",
        '--output', 'json'
    )
    Invoke-AzWithRetry -Operation "group create $ResourceGroup" -ScriptBlock {
        Invoke-AzCommand -ArgumentList $argList | Out-Null
    }
}

function Invoke-DrWhatIf {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $DeploymentName,
        [Parameter(Mandatory)] [string] $DrRegion
    )
    $argList = @(
        'deployment', 'group', 'what-if',
        '--resource-group', $ResourceGroup,
        '--name', $DeploymentName,
        '--template-file', $TemplateFile,
        '--parameters', "location=$DrRegion",
        '--no-pretty-print',
        '--output', 'json'
    )
    return (Invoke-AzWithRetry -Operation "what-if $ResourceGroup" -ScriptBlock {
        Invoke-AzCommand -ArgumentList $argList
    })
}

function Invoke-DrDeployment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Deterministic deployment name + Azure-side dedupe makes this idempotent; ShouldProcess adds no safety here.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $DeploymentName,
        [Parameter(Mandatory)] [string] $DrRegion
    )
    $argList = @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroup,
        '--name', $DeploymentName,
        '--template-file', $TemplateFile,
        '--parameters', "location=$DrRegion",
        '--mode', 'Incremental',
        '--output', 'json'
    )
    return (Invoke-AzWithRetry -Operation "deploy $ResourceGroup" -ScriptBlock {
        Invoke-AzCommand -ArgumentList $argList
    })
}

# ── Main ─────────────────────────────────────────────────────────────────────

$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

if (-not (Test-Path $BicepDir)) {
    throw "BicepDir does not exist: $BicepDir"
}

$null = New-Item -ItemType Directory -Force -Path $OutputDir

Write-Host "============================================================"
Write-Host "STAGE 7: Deploy DR Region"
Write-Host "  Bicep Dir:   $BicepDir"
Write-Host "  DR Region:   $DrRegion"
Write-Host "  Commit SHA:  $CommitSha"
Write-Host "  Run ID:      $RunId"
Write-Host "  Output Dir:  $OutputDir"
Write-Host "  DryRun:      $($DryRun.IsPresent)"
Write-Host "============================================================"

$BicepFiles = @(Get-ChildItem -Path $BicepDir -Filter 'dr-*.bicep' -File -ErrorAction SilentlyContinue)
if ($BicepFiles.Count -eq 0) {
    Write-Host "  No dr-*.bicep files found under $BicepDir — nothing to deploy."
}

$Processed       = 0
$Succeeded       = 0
$Failed          = 0
$DeploymentNames = [System.Collections.Generic.List[string]]::new()
$Failures        = [System.Collections.Generic.List[object]]::new()

foreach ($file in $BicepFiles) {
    $Processed++
    $workload    = $null
    $rg          = $null
    $deployName  = $null
    try {
        $workload   = Get-DrWorkloadName -FileName $file.Name
        $rg         = "rg-$workload-dr"
        $deployName = Get-DeterministicDeploymentName -CommitSha $CommitSha -Workload $workload

        Write-Host ""
        Write-Host "── $($file.Name) -> $rg / $deployName ──"

        if ($DryRun) {
            Write-Host "  DryRun: skipping az group create / what-if / deploy"
            $whatIfPath = Join-Path $OutputDir "whatif-$rg.json"
            '{"status":"dry-run","resourceGroup":"' + $rg + '"}' | Set-Content $whatIfPath -Encoding UTF8
            $DeploymentNames.Add($deployName)
            $Succeeded++
            continue
        }

        # 1. Resource group (idempotent).
        New-DrResourceGroup -ResourceGroup $rg -Location $DrRegion -Workload $workload -RunId $RunId

        # 2. What-if first; persist to _reports/deploy/whatif-<rg>.json.
        $whatIf = Invoke-DrWhatIf -ResourceGroup $rg -TemplateFile $file.FullName `
            -DeploymentName $deployName -DrRegion $DrRegion
        $whatIfPath = Join-Path $OutputDir "whatif-$rg.json"
        $whatIf | Set-Content $whatIfPath -Encoding UTF8

        # 3. Deploy with the same deployment name -> Azure dedupes on re-run.
        $deployResult = Invoke-DrDeployment -ResourceGroup $rg -TemplateFile $file.FullName `
            -DeploymentName $deployName -DrRegion $DrRegion
        $deployPath = Join-Path $OutputDir "deploy-$rg.json"
        $deployResult | Set-Content $deployPath -Encoding UTF8

        # 4. Test-DRHealth invocation point — deferred to Round 4.2.
        #    When it lands, call:
        #      & (Join-Path $PSScriptRoot 'Test-DRHealth.ps1') -ResourceGroup $rg -DrRegion $DrRegion
        #    and merge its result into the deploy-summary.

        $DeploymentNames.Add($deployName)
        $Succeeded++
    }
    catch {
        $Failed++
        $entry = [ordered]@{
            file           = $file.Name
            workload       = $workload
            resourceGroup  = $rg
            deploymentName = $deployName
            error          = "$_"
            timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $Failures.Add([PSCustomObject]$entry)
        Write-Warning "  FAILED $($file.Name): $_"
        # Per-RG fault tolerance: continue with the next file.
        continue
    }
}

# ── Output: failures + summary ───────────────────────────────────────────────

$failuresPath = Join-Path $OutputDir 'failures.json'
# Force array form so an empty list still emits valid JSON ("[]") rather than nothing.
ConvertTo-Json -InputObject @($Failures) -Depth 30 -AsArray |
    Set-Content $failuresPath -Encoding UTF8

$summary = [ordered]@{
    runId           = $RunId
    commitSha       = $CommitSha
    drRegion        = $DrRegion
    timestamp       = $Timestamp
    processed       = $Processed
    succeeded       = $Succeeded
    failed          = $Failed
    deploymentNames = @($DeploymentNames)
    failures        = @($Failures)
}
$summaryPath = Join-Path $OutputDir 'deploy-summary.json'
$summary | ConvertTo-Json -Depth 30 | Set-Content $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "DR DEPLOY COMPLETE  Processed: $Processed  Succeeded: $Succeeded  Failed: $Failed"
Write-Host "  Summary: $summaryPath"
