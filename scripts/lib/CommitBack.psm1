#Requires -Version 7.2
# =============================================================================
# scripts/lib/CommitBack.psm1
#
# Shared helper for "commit-back" steps that push generated artefacts to a PR
# branch. Centralises the GitHub-Actions / Azure-DevOps git auth pattern so
# multiple callers (commit-drift-readme.ps1, check-dr-coverage.ps1, …) do not
# duplicate the credential wiring.
#
# Idempotent: Push-Branch -Files @() or "no diff" → no-op exit-style return.
# Fault-tolerant: never throws on push failure; surfaces success via $false.
# =============================================================================

# ── Internal: configure git auth based on environment ────────────────────────
function Set-CommitBackAuth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Configures git client state for the current run; the system is the worker checkout, not a user-facing resource. ShouldProcess would interfere with non-interactive CI use.')]
    [CmdletBinding()]
    param()

    if ($env:GITHUB_TOKEN) {
        Write-Host "INFO: Detected GitHub Actions — using GITHUB_TOKEN"
        $AuthorName  = if ($env:GIT_AUTHOR_NAME)  { $env:GIT_AUTHOR_NAME  } else { "DRaaC Pipeline" }
        $AuthorEmail = if ($env:GIT_AUTHOR_EMAIL) { $env:GIT_AUTHOR_EMAIL } else { "draac-pipeline@github-actions.local" }
        git config user.name  $AuthorName
        git config user.email $AuthorEmail

        # Embed token into remote URL.
        $RemoteUrl = (git remote get-url origin) -replace "https://[^@]*@", "https://"
        $AuthUrl   = $RemoteUrl -replace "https://", "https://x-access-token:$($env:GITHUB_TOKEN)@"
        git remote set-url origin $AuthUrl
        return $true
    }
    elseif ($env:AZURE_DEVOPS_EXT_PAT) {
        Write-Host "INFO: Detected Azure DevOps — using System.AccessToken"
        git config user.name  "DRaaC Pipeline"
        git config user.email "draac-pipeline@devops.local"
        $EncodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_EXT_PAT)"))
        git config http.extraheader "Authorization: Basic $EncodedPat"
        return $true
    }

    Write-Warning "No auth token found (GITHUB_TOKEN or AZURE_DEVOPS_EXT_PAT) — push will likely fail"
    return $false
}

# ── Public: Push-Branch ──────────────────────────────────────────────────────
function Push-Branch {
    <#
    .SYNOPSIS
    Stages, commits, and pushes a set of files to a PR branch.

    .DESCRIPTION
    Wraps the platform-aware git auth dance so callers do not duplicate it.
    Idempotent: if `git diff --cached` reports no changes after staging, the
    function returns $true without creating a commit. Push uses
    --force-with-lease to be safe on concurrent updates.

    .PARAMETER RepoRoot
    Path to the repository checkout.

    .PARAMETER Branch
    PR branch name (refs/heads/ prefix is stripped).

    .PARAMETER RunId
    Pipeline run identifier — embedded in the commit message for traceability.

    .PARAMETER Files
    Files to stage. Paths are passed verbatim to `git add`; relative paths are
    resolved against $RepoRoot.

    .PARAMETER Message
    Commit message. `[skip ci]` is appended automatically when not present
    so the commit-back does not retrigger the same workflow.

    .PARAMETER MaxRetries
    Number of push attempts (defaults to 3). Each retry rebases first.

    .OUTPUTS
    [bool] — $true on success or no-op, $false on persistent push failure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates the remote branch by design; the function IS the side effect. ShouldProcess would interfere with non-interactive CI use, and the operation is already gated by an explicit caller decision.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]   $RepoRoot,
        [Parameter(Mandatory)] [string]   $Branch,
        [Parameter(Mandatory)] [string]   $RunId,
        [Parameter(Mandatory)] [string[]] $Files,
        [Parameter(Mandatory)] [string]   $Message,
        [int] $MaxRetries = 3
    )

    if (-not (Test-Path $RepoRoot)) {
        Write-Warning "Push-Branch: RepoRoot '$RepoRoot' not found — skipping"
        return $false
    }

    if (-not $Files -or $Files.Count -eq 0) {
        Write-Host "INFO: Push-Branch — no files supplied, skipping"
        return $true
    }

    $resolvedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Files) {
        if (-not $f) { continue }
        $candidate = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $RepoRoot $f }
        if (Test-Path $candidate) { $resolvedFiles.Add($candidate) }
    }
    if ($resolvedFiles.Count -eq 0) {
        Write-Host "INFO: Push-Branch — none of the requested files exist on disk, skipping"
        return $true
    }

    Push-Location $RepoRoot
    try {
        $null = Set-CommitBackAuth

        $cleanBranch = $Branch -replace '^refs/heads/', ''

        git fetch origin $cleanBranch 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Push-Branch: could not fetch branch $cleanBranch — aborting"
            return $false
        }

        git checkout $cleanBranch 2>$null
        if ($LASTEXITCODE -ne 0) {
            git checkout -b $cleanBranch "origin/$cleanBranch" 2>$null
        }
        git pull origin $cleanBranch --rebase 2>$null

        foreach ($f in $resolvedFiles) { git add -- $f }

        git diff --cached --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "INFO: Push-Branch — nothing to commit (already clean)"
            return $true
        }

        $commitMessage = $Message
        if ($commitMessage -notmatch '\[skip ci\]') {
            $commitMessage = "$commitMessage [run=$RunId] [skip ci]"
        }
        git commit -m $commitMessage
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Push-Branch: git commit failed"
            return $false
        }

        for ($i = 1; $i -le $MaxRetries; $i++) {
            git push origin "HEAD:$cleanBranch" --force-with-lease 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "SUCCESS: Push-Branch — push succeeded (attempt $i)"
                return $true
            }
            Write-Warning "Push-Branch: push attempt $i failed"
            if ($i -lt $MaxRetries) {
                git pull origin $cleanBranch --rebase 2>$null
                Start-Sleep -Seconds 5
            }
        }

        Write-Warning "Push-Branch: all $MaxRetries push attempts failed"
        return $false
    }
    finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Push-Branch
