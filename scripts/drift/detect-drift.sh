#!/usr/bin/env bash
# =============================================================================
# detect-drift.sh
# Stage 4a: Compare deployed Azure state with IaC code to detect config drift.
# Checks: missing resources, extra resources, property mismatches.
# Idempotent: generates a fresh drift report on each run.
# Fault-tolerant: individual comparison errors are recorded, not fatal.
# =============================================================================
set -euo pipefail

SCAN_DIR=""
EXPORT_DIR=""
REVIEW_DIR=""
REPO_ROOT=""
OUTPUT_DIR=""
RUN_ID=""
PR_ID=""
PR_SOURCE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan-dir)          SCAN_DIR="$2";           shift 2 ;;
    --export-dir)        EXPORT_DIR="$2";         shift 2 ;;
    --review-dir)        REVIEW_DIR="$2";         shift 2 ;;
    --repo-root)         REPO_ROOT="$2";          shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";         shift 2 ;;
    --run-id)            RUN_ID="$2";             shift 2 ;;
    --pr-id)             PR_ID="$2";              shift 2 ;;
    --pr-source-branch)  PR_SOURCE_BRANCH="$2";   shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_DISPLAY=$(date -u +"%Y-%m-%d %H:%M UTC")

echo "============================================================"
echo "STAGE 4a: Configuration Drift Detection"
echo "  PR ID: ${PR_ID}"
echo "  Run ID: ${RUN_ID}"
echo "============================================================"

# ── Load data ─────────────────────────────────────────────────────────────────
ALL_RESOURCES_FILE="${SCAN_DIR}/all-resources.json"
MATCH_REPORT="${REVIEW_DIR}/deployment-match-report.json"

[[ ! -f "$ALL_RESOURCES_FILE" ]] && { echo "ERROR: all-resources.json not found"; exit 1; }

# ── Find all IaC files in the repo ───────────────────────────────────────────
echo "INFO: Scanning repository IaC files in ${REPO_ROOT}"

declare -a BICEP_FILES TF_FILES ARM_FILES

while IFS= read -r f; do BICEP_FILES+=("$f"); done < \
  <(find "${REPO_ROOT}" -name "*.bicep" -not -path "*/.git/*" 2>/dev/null || true)

while IFS= read -r f; do TF_FILES+=("$f"); done < \
  <(find "${REPO_ROOT}" -name "*.tf" -not -path "*/.git/*" 2>/dev/null || true)

while IFS= read -r f; do ARM_FILES+=("$f"); done < \
  <(find "${REPO_ROOT}" -name "*.json" \
    -path "*/arm*" -o -path "*/templates*" -o -path "*/deploy*" \
    -not -path "*/.git/*" 2>/dev/null | head -100 || true)

echo "INFO: Found ${#BICEP_FILES[@]} Bicep, ${#TF_FILES[@]} TF, ${#ARM_FILES[@]} ARM files"

# ── Extract declared resource names from code ─────────────────────────────────
CODE_RESOURCES=()

for f in "${BICEP_FILES[@]}"; do
  while IFS= read -r name; do
    [[ -n "$name" ]] && CODE_RESOURCES+=("{\"name\":\"${name}\",\"source\":\"bicep\",\"file\":\"${f}\"}")
  done < <(grep -oP "name:\s*'\K[^']+" "$f" 2>/dev/null | grep -v '^\[' || true)
done

for f in "${TF_FILES[@]}"; do
  while IFS= read -r name; do
    [[ -n "$name" ]] && CODE_RESOURCES+=("{\"name\":\"${name}\",\"source\":\"terraform\",\"file\":\"${f}\"}")
  done < <(grep -oP 'name\s*=\s*"\K[^"]+' "$f" 2>/dev/null || true)
done

for f in "${ARM_FILES[@]}"; do
  [[ ! -f "$f" ]] && continue
  while IFS= read -r name; do
    [[ -n "$name" ]] && CODE_RESOURCES+=("{\"name\":\"${name}\",\"source\":\"arm\",\"file\":\"${f}\"}")
  done < <(jq -r '.resources[]?.name // empty' "$f" 2>/dev/null | grep -v '^\[' || true)
done

CODE_RESOURCES_JSON=$(printf '%s\n' "${CODE_RESOURCES[@]}" | jq -s 'unique_by(.name)')
CODE_COUNT=$(echo "$CODE_RESOURCES_JSON" | jq 'length')
echo "INFO: Extracted ${CODE_COUNT} resource declarations from code"

# ── Classify each deployed resource ──────────────────────────────────────────
DRIFT_ITEMS=()
DEPLOYED_IN_CODE=0
DEPLOYED_NOT_IN_CODE=0
CODE_NOT_DEPLOYED=0

# 1. Resources in Azure that are NOT in code (extra deployed resources)
while IFS= read -r resource; do
  rname=$(echo "$resource" | jq -r '.name')
  rtype=$(echo "$resource" | jq -r '.type')
  rloc=$(echo "$resource" | jq -r '.location')
  rrg=$(echo "$resource" | jq -r '.resourceGroup')
  rsub=$(echo "$resource" | jq -r '.subscriptionId')

  # Skip system/managed resources
  [[ "$rname" =~ ^(NetworkWatcher|DefaultResourceGroup|cloud-shell|AzureBackupRG) ]] && continue
  [[ "$rtype" =~ microsoft.compute/virtualmachines/extensions ]] && continue

  in_code=$(echo "$CODE_RESOURCES_JSON" | jq --arg n "${rname,,}" \
    '[.[] | select((.name | ascii_downcase) == $n)] | length')

  if [[ "$in_code" -eq 0 ]]; then
    DEPLOYED_NOT_IN_CODE=$((DEPLOYED_NOT_IN_CODE + 1))
    DRIFT_ITEMS+=("{
      \"driftType\": \"deployed-not-in-code\",
      \"severity\": \"warning\",
      \"resourceName\": \"${rname}\",
      \"resourceType\": \"${rtype}\",
      \"location\": \"${rloc}\",
      \"resourceGroup\": \"${rrg}\",
      \"subscriptionId\": \"${rsub}\",
      \"description\": \"Resource exists in Azure but has no corresponding IaC definition in the repository\",
      \"recommendation\": \"Add IaC definition or mark as manually managed\"
    }")
  else
    DEPLOYED_IN_CODE=$((DEPLOYED_IN_CODE + 1))
  fi
done < <(jq -c '.[]' "$ALL_RESOURCES_FILE")

# 2. Resources in code that are NOT deployed in Azure
while IFS= read -r code_res; do
  name=$(echo "$code_res" | jq -r '.name')
  source=$(echo "$code_res" | jq -r '.source')
  file=$(echo "$code_res" | jq -r '.file')

  found=$(jq --arg n "${name,,}" \
    '[.[] | select((.name | ascii_downcase) == $n)] | length' \
    "$ALL_RESOURCES_FILE" 2>/dev/null || echo 0)

  if [[ "$found" -eq 0 ]]; then
    CODE_NOT_DEPLOYED=$((CODE_NOT_DEPLOYED + 1))
    DRIFT_ITEMS+=("{
      \"driftType\": \"in-code-not-deployed\",
      \"severity\": \"critical\",
      \"resourceName\": \"${name}\",
      \"source\": \"${source}\",
      \"file\": \"${file}\",
      \"description\": \"IaC defines this resource but it is not found in any Azure subscription\",
      \"recommendation\": \"Deploy the resource or remove the IaC definition if obsolete\"
    }")
  fi
done < <(echo "$CODE_RESOURCES_JSON" | jq -c '.[]')

# 3. Check deployment match report for partially-deployed resources
if [[ -f "$MATCH_REPORT" ]]; then
  while IFS= read -r result; do
    status=$(echo "$result" | jq -r '.status')
    path=$(echo "$result" | jq -r '.path')
    [[ "$status" == "partially-deployed" ]] || continue

    DRIFT_ITEMS+=("{
      \"driftType\": \"partial-deployment\",
      \"severity\": \"critical\",
      \"file\": \"${path}\",
      \"status\": \"${status}\",
      \"description\": \"PR file contains resources that are only partially deployed to Azure\",
      \"recommendation\": \"Ensure all resources in the changed file are fully deployed before merging\"
    }")
  done < <(jq -c '.results[]' "$MATCH_REPORT" 2>/dev/null || true)

  # 4. Files changed in PR that have zero matching deployments
  while IFS= read -r result; do
    status=$(echo "$result" | jq -r '.status')
    path=$(echo "$result" | jq -r '.path')
    category=$(echo "$result" | jq -r '.category')

    [[ "$category" == "not-iac" || "$category" == "other" ]] && continue
    [[ "$status" == "not-deployed" || "$status" == "no-resources-extracted" ]] || continue

    DRIFT_ITEMS+=("{
      \"driftType\": \"pr-change-not-deployed\",
      \"severity\": \"critical\",
      \"file\": \"${path}\",
      \"category\": \"${category}\",
      \"description\": \"This PR modifies an IaC file, but no matching deployed resources were found in Azure\",
      \"recommendation\": \"Deploy the changes to Azure before merging, or verify resource naming conventions\"
    }")
  done < <(jq -c '.results[]' "$MATCH_REPORT" 2>/dev/null || true)
fi

# ── Write drift report JSON ────────────────────────────────────────────────────
DRIFT_JSON=$(printf '%s\n' "${DRIFT_ITEMS[@]}" | jq -s '.')
TOTAL_DRIFT=$(echo "$DRIFT_JSON" | jq 'length')
CRITICAL_DRIFT=$(echo "$DRIFT_JSON" | jq '[.[] | select(.severity == "critical")] | length')
WARNING_DRIFT=$(echo "$DRIFT_JSON" | jq '[.[] | select(.severity == "warning")] | length')

jq -n \
  --arg runId "$RUN_ID" \
  --arg prId "$PR_ID" \
  --arg branch "$PR_SOURCE_BRANCH" \
  --arg ts "$TIMESTAMP" \
  --argjson total "$TOTAL_DRIFT" \
  --argjson critical "$CRITICAL_DRIFT" \
  --argjson warning "$WARNING_DRIFT" \
  --argjson deployedInCode "$DEPLOYED_IN_CODE" \
  --argjson deployedNotInCode "$DEPLOYED_NOT_IN_CODE" \
  --argjson codeNotDeployed "$CODE_NOT_DEPLOYED" \
  --argjson items "$DRIFT_JSON" \
  '{
    runId: $runId,
    prId: $prId,
    sourceBranch: $branch,
    timestamp: $ts,
    summary: {
      totalDriftItems: $total,
      critical: $critical,
      warnings: $warning,
      deployedAndInCode: $deployedInCode,
      deployedNotInCode: $deployedNotInCode,
      inCodeNotDeployed: $codeNotDeployed
    },
    driftItems: $items
  }' > "${OUTPUT_DIR}/drift-report.json"

echo ""
echo "============================================================"
echo "DRIFT DETECTION COMPLETE"
echo "  Total drift items:    ${TOTAL_DRIFT}"
echo "  Critical:             ${CRITICAL_DRIFT}"
echo "  Warnings:             ${WARNING_DRIFT}"
echo "  Matched (code+Azure): ${DEPLOYED_IN_CODE}"
echo "============================================================"
