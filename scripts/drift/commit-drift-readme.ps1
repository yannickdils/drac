#Requires -Version 7.2
# =============================================================================
# commit-drift-readme.ps1
# Stage 4c: Commit CONFIGURATION-DRIFT.md back to the PR branch.
# Supports Azure DevOps (System.AccessToken) and GitHub (GITHUB_TOKEN).
# Idempotent: uses --force-with-lease via Push-Branch; skips if file unchanged.
# Fault-tolerant: push failures are non-fatal.
#
# CLI parameter contract is preserved for backward compatibility with
# .azure/pipelines and .github/workflows. The auth/push body has been moved
# into scripts/lib/CommitBack.psm1 and is shared with check-dr-coverage.ps1.
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $PrBranch,
    [Parameter(Mandatory)] [string] $RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$DriftFile = Join-Path $RepoRoot "CONFIGURATION-DRIFT.md"

if (-not (Test-Path $DriftFile)) {
    Write-Host "INFO: CONFIGURATION-DRIFT.md not found — nothing to commit"
    exit 0
}

$ModulePath = Join-Path $PSScriptRoot ".." "lib" "CommitBack.psm1"
Import-Module $ModulePath -Force

$ok = Push-Branch `
    -RepoRoot $RepoRoot `
    -Branch   $PrBranch `
    -RunId    $RunId `
    -Files    @($DriftFile) `
    -Message  "chore(draac): update CONFIGURATION-DRIFT.md"

if ($ok) {
    Write-Host "SUCCESS: commit-drift-readme completed"
} else {
    Write-Warning "commit-drift-readme: push did not complete — file is in the artifact but not in the repo"
}

exit 0   # Non-fatal — keep parity with prior behaviour.
