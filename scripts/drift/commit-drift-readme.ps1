# =============================================================================
# commit-drift-readme.ps1
# Stage 4c: Commit CONFIGURATION-DRIFT.md back to the PR branch.
# Supports Azure DevOps (System.AccessToken) and GitHub (GITHUB_TOKEN).
# Idempotent: uses --force-with-lease; skips if file unchanged.
# Fault-tolerant: push failures are non-fatal.
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

$Branch = $PrBranch -replace '^refs/heads/', ''

# ── Detect platform and configure git auth ────────────────────────────────────
function Set-GitAuth {
    if ($env:GITHUB_TOKEN) {
        Write-Host "INFO: Detected GitHub Actions — using GITHUB_TOKEN"
        $AuthorName  = if ($env:GIT_AUTHOR_NAME)  { $env:GIT_AUTHOR_NAME  } else { "DRaaC Pipeline" }
        $AuthorEmail = if ($env:GIT_AUTHOR_EMAIL) { $env:GIT_AUTHOR_EMAIL } else { "draac-pipeline@github-actions.local" }
        git config user.name  $AuthorName
        git config user.email $AuthorEmail

        # Embed token into remote URL
        $RemoteUrl = (git remote get-url origin) -replace "https://[^@]*@", "https://"
        $AuthUrl   = $RemoteUrl -replace "https://", "https://x-access-token:$($env:GITHUB_TOKEN)@"
        git remote set-url origin $AuthUrl
    } elseif ($env:AZURE_DEVOPS_EXT_PAT) {
        Write-Host "INFO: Detected Azure DevOps — using System.AccessToken"
        git config user.name  "DRaaC Pipeline"
        git config user.email "draac-pipeline@devops.local"
        $EncodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_EXT_PAT)"))
        git config http.extraheader "Authorization: Basic $EncodedPat"
    } else {
        Write-Warning "No auth token found (GITHUB_TOKEN or AZURE_DEVOPS_EXT_PAT) — push will likely fail"
    }
}

Set-GitAuth

# Fetch and checkout PR branch
git fetch origin $Branch 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not fetch branch $Branch — aborting commit"
    exit 0
}

git checkout $Branch 2>$null
if ($LASTEXITCODE -ne 0) {
    git checkout -b $Branch "origin/$Branch" 2>$null
}
git pull origin $Branch --rebase 2>$null

# Stage the file
git add $DriftFile

$DiffResult = git diff --cached --quiet 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "INFO: CONFIGURATION-DRIFT.md unchanged — nothing to commit"
    exit 0
}

git commit -m "chore(draac): update CONFIGURATION-DRIFT.md [run=$RunId] [skip ci]"

# Push with retry
$MaxRetries = 3
for ($i = 1; $i -le $MaxRetries; $i++) {
    git push origin "HEAD:$Branch" --force-with-lease 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: CONFIGURATION-DRIFT.md committed (attempt $i)"
        exit 0
    }
    Write-Warning "Push attempt $i failed"
    if ($i -lt $MaxRetries) {
        git pull origin $Branch --rebase 2>$null
        Start-Sleep -Seconds 5
    }
}

Write-Warning "All push attempts failed — CONFIGURATION-DRIFT.md is in the artifact but not in the repo"
exit 0   # Non-fatal
