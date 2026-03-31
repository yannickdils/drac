#!/usr/bin/env bash
# =============================================================================
# identify-pr-changes.sh
# Stage 3a: Identify files changed in the current PR compared to target branch.
# Outputs a structured JSON list of changed paths + their categories.
# Idempotent: same git diff = same output.
# =============================================================================
set -euo pipefail

BASE_COMMIT=""
HEAD_COMMIT=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-commit)   BASE_COMMIT="$2";   shift 2 ;;
    --head-commit)   HEAD_COMMIT="$2";   shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2";    shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"

echo "============================================================"
echo "STAGE 3a: Identify PR Changes"
echo "  Base: ${BASE_COMMIT}"
echo "  Head: ${HEAD_COMMIT}"
echo "============================================================"

# Normalise branch ref
BASE_REF="origin/${BASE_COMMIT#refs/heads/}"
HEAD_REF="${HEAD_COMMIT}"

git fetch --all --quiet 2>/dev/null || true

# ── Get changed files with their status ──────────────────────────────────────
DIFF_OUTPUT=$(git diff --name-status "${BASE_REF}...${HEAD_REF}" 2>/dev/null || \
              git diff --name-status HEAD~1 2>/dev/null || echo "")

if [[ -z "$DIFF_OUTPUT" ]]; then
  echo "WARN: Could not compute diff, treating all IaC files as changed"
  DIFF_OUTPUT=$(find . \
    \( -name "*.bicep" -o -name "*.json" -o -name "*.tf" -o -name "*.yaml" -o -name "*.yml" \) \
    -not -path "./.git/*" \
    -not -path "./node_modules/*" | \
    sed 's/^/M\t/')
fi

# ── Categorise each changed file ──────────────────────────────────────────────
categorize_file() {
  local path="$1"
  local lpath="${path,,}"

  # Infrastructure-as-Code categories
  if [[ "$lpath" =~ \.bicep$ ]]; then             echo "bicep"
  elif [[ "$lpath" =~ \.tf$ ]]; then              echo "terraform"
  elif [[ "$lpath" =~ arm|template.*\.json$ ]];   then echo "arm-template"
  elif [[ "$lpath" =~ pipeline.*\.(yml|yaml)$ ]]; then echo "pipeline"
  elif [[ "$lpath" =~ manifest.*\.(yml|yaml)$ ]]; then echo "k8s-manifest"
  elif [[ "$lpath" =~ helm/ ]];                   then echo "helm"
  elif [[ "$lpath" =~ dockerfile ]];              then echo "dockerfile"
  elif [[ "$lpath" =~ \.json$ ]];                 then echo "config-json"
  elif [[ "$lpath" =~ \.(ps1|sh|bash)$ ]];        then echo "script"
  else                                                  echo "other"
  fi
}

# Extract resource group hints from file paths
extract_rg_hint() {
  local path="$1"
  # Common patterns: rg-name/, resourcegroups/rg-name/, environments/rg-name/
  echo "$path" | grep -oP '(?:rg[-_][a-z0-9\-]+|resourcegroup[s]?/[^/]+|environments/[^/]+)' \
    | head -1 | sed 's|.*/||' || echo ""
}

# Build JSON array of changed files
changes_json="["
first=true
while IFS=$'\t' read -r status filepath; do
  [[ -z "$filepath" ]] && continue
  [[ "$status" == "D" ]] && continue  # Skip deleted files for deployment check

  category=$(categorize_file "$filepath")
  rg_hint=$(extract_rg_hint "$filepath")

  if [[ "$first" == "true" ]]; then first=false; else changes_json+=","; fi
  changes_json+=$(jq -n \
    --arg s "$status" \
    --arg f "$filepath" \
    --arg c "$category" \
    --arg rg "$rg_hint" \
    '{ status: $s, path: $f, category: $c, resourceGroupHint: $rg }')
done <<< "$DIFF_OUTPUT"
changes_json+="]"

echo "$changes_json" | jq '.' > "${OUTPUT_DIR}/pr-changes.json"

TOTAL_CHANGES=$(echo "$changes_json" | jq 'length')
IaC_CHANGES=$(echo "$changes_json" | jq '[.[] | select(.category != "other")] | length')

echo "INFO: ${TOTAL_CHANGES} files changed (${IaC_CHANGES} IaC-related)"

# ── Write summary ─────────────────────────────────────────────────────────────
jq -n \
  --arg base "$BASE_COMMIT" \
  --arg head "$HEAD_COMMIT" \
  --argjson total "$TOTAL_CHANGES" \
  --argjson iac "$IaC_CHANGES" \
  --argjson changes "$changes_json" \
  '{
    baseCommit: $base,
    headCommit: $head,
    totalChanged: $total,
    iacRelatedChanged: $iac,
    changes: $changes
  }' > "${OUTPUT_DIR}/pr-changes-summary.json"

echo ""
echo "============================================================"
echo "PR CHANGES IDENTIFIED: ${TOTAL_CHANGES} files (${IaC_CHANGES} IaC)"
echo "============================================================"
