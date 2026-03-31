#!/usr/bin/env bash
# =============================================================================
# commit-drift-readme.sh
# Stage 4c: Commit CONFIGURATION-DRIFT.md update back to the PR branch.
# Supports both Azure DevOps (System.AccessToken) and GitHub (GITHUB_TOKEN).
# Idempotent: uses --force-with-lease to avoid clobbering concurrent updates.
# Fault-tolerant: push failures are non-fatal; artifact is always published.
# =============================================================================
set -euo pipefail

REPO_ROOT=""
PR_BRANCH=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)    REPO_ROOT="$2";   shift 2 ;;
    --pr-branch)    PR_BRANCH="$2";   shift 2 ;;
    --run-id)       RUN_ID="$2";      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

DRIFT_FILE="${REPO_ROOT}/CONFIGURATION-DRIFT.md"

if [[ ! -f "$DRIFT_FILE" ]]; then
  echo "INFO: CONFIGURATION-DRIFT.md not found, nothing to commit"
  exit 0
fi

BRANCH="${PR_BRANCH#refs/heads/}"

# ── Detect platform and configure git auth ───────────────────────────────────
configure_git_auth() {
  # GitHub Actions — GITHUB_TOKEN is set automatically
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "INFO: Detected GitHub Actions — using GITHUB_TOKEN for auth"
    local author_name="${GIT_AUTHOR_NAME:-DRaaC Pipeline}"
    local author_email="${GIT_AUTHOR_EMAIL:-draac-pipeline@github-actions.local}"
    git config user.name  "$author_name"
    git config user.email "$author_email"

    # Configure the remote URL to embed the token
    local repo_url
    repo_url=$(git remote get-url origin)
    # Strip any existing credentials from the URL
    repo_url=$(echo "$repo_url" | sed 's|https://[^@]*@|https://|')
    # Embed token: https://x-access-token:<token>@github.com/...
    local auth_url="${repo_url/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
    git remote set-url origin "$auth_url"
    return 0
  fi

  # Azure DevOps — AZURE_DEVOPS_EXT_PAT is the System.AccessToken
  if [[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]]; then
    echo "INFO: Detected Azure DevOps — using System.AccessToken for auth"
    git config user.name  "Azure Compliance Pipeline"
    git config user.email "azure-compliance-pipeline@devops.local"
    local encoded_pat
    encoded_pat=$(printf '%s' ":${AZURE_DEVOPS_EXT_PAT}" | base64 -w 0)
    git config http.extraheader "Authorization: Basic ${encoded_pat}"
    return 0
  fi

  echo "WARN: No auth token found (GITHUB_TOKEN or AZURE_DEVOPS_EXT_PAT). Push will likely fail."
}

configure_git_auth

# ── Fetch latest state of PR branch ──────────────────────────────────────────
git fetch origin "${BRANCH}" 2>/dev/null || {
  echo "WARN: Could not fetch branch ${BRANCH}, aborting commit"
  exit 0
}

git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" "origin/${BRANCH}"
git pull origin "${BRANCH}" --rebase 2>/dev/null || true

# ── Stage and commit ──────────────────────────────────────────────────────────
git add "${DRIFT_FILE}"

if git diff --cached --quiet; then
  echo "INFO: CONFIGURATION-DRIFT.md unchanged, nothing to commit"
  exit 0
fi

git commit -m "chore(draac): update CONFIGURATION-DRIFT.md [run=${RUN_ID}] [skip ci]"

# ── Push with retry (fault-tolerant) ─────────────────────────────────────────
MAX_RETRIES=3
for attempt in $(seq 1 $MAX_RETRIES); do
  if git push origin "HEAD:${BRANCH}" --force-with-lease; then
    echo "SUCCESS: CONFIGURATION-DRIFT.md committed and pushed (attempt ${attempt})"
    break
  else
    echo "WARN: Push attempt ${attempt} failed"
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      echo "      Rebasing and retrying in 5s..."
      git pull origin "${BRANCH}" --rebase 2>/dev/null || true
      sleep 5
    else
      echo "ERROR: All push attempts failed — CONFIGURATION-DRIFT.md is in the artifact but not committed to the PR branch"
      # Non-fatal: the artifact is still published for review
      exit 0
    fi
  fi
done
