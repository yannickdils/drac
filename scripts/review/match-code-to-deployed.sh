#!/usr/bin/env bash
# =============================================================================
# match-code-to-deployed.sh
# Stage 3b: Match PR code changes to deployed Azure resources.
# Checks if resources defined in changed IaC files exist in Azure.
# Idempotent: deterministic matching logic.
# Fault-tolerant: unmatched resources are reported but do not fail the build.
# =============================================================================
set -euo pipefail

PR_CHANGES_FILE=""
SCAN_DIR=""
EXPORT_DIR=""
OUTPUT_DIR=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-changes-file)   PR_CHANGES_FILE="$2";   shift 2 ;;
    --scan-dir)          SCAN_DIR="$2";           shift 2 ;;
    --export-dir)        EXPORT_DIR="$2";         shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";         shift 2 ;;
    --run-id)            RUN_ID="$2";             shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"

echo "============================================================"
echo "STAGE 3b: Match Code Changes to Deployed Resources"
echo "  Run ID: ${RUN_ID}"
echo "============================================================"

ALL_RESOURCES_FILE="${SCAN_DIR}/all-resources.json"
[[ ! -f "$ALL_RESOURCES_FILE" ]] && { echo "ERROR: all-resources.json not found"; exit 1; }
[[ ! -f "$PR_CHANGES_FILE" ]]    && { echo "ERROR: pr-changes.json not found"; exit 1; }

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Extract resource names from a Bicep file ──────────────────────────────────
extract_bicep_resource_names() {
  local file="$1"
  [[ ! -f "$file" ]] && return
  # Extract resource symbolic names and their types
  grep -oP "resource\s+\K[a-zA-Z0-9_]+(?=\s+'[^']+'" "$file" 2>/dev/null || true
  # Also extract name properties
  grep -oP "name:\s+'\K[^']+" "$file" 2>/dev/null || true
  grep -oP "name:\s+\"\K[^\"]+" "$file" 2>/dev/null || true
}

# ── Extract resource names from an ARM template ───────────────────────────────
extract_arm_resource_names() {
  local file="$1"
  [[ ! -f "$file" ]] && return
  jq -r '.resources[]?.name // empty' "$file" 2>/dev/null | \
    grep -v '^\[' || true  # Skip parameterised names for now
}

# ── Check if a resource name exists in the scan ───────────────────────────────
find_in_scan() {
  local name="$1"
  jq --arg n "${name,,}" \
    '[.[] | select((.name | ascii_downcase) == $n)] | length' \
    "$ALL_RESOURCES_FILE" 2>/dev/null || echo 0
}

# ── Process each changed IaC file ─────────────────────────────────────────────
results=()
MATCHED=0
UNMATCHED=0
NOT_IAC=0

while IFS= read -r change; do
  path=$(echo "$change" | jq -r '.path')
  category=$(echo "$change" | jq -r '.category')
  rg_hint=$(echo "$change" | jq -r '.resourceGroupHint')

  case "$category" in
    bicep)
      resource_names=$(extract_bicep_resource_names "$path")
      ;;
    arm-template)
      resource_names=$(extract_arm_resource_names "$path")
      ;;
    terraform)
      resource_names=$(grep -oP 'name\s*=\s*"\K[^"]+' "$path" 2>/dev/null || true)
      ;;
    *)
      NOT_IAC=$((NOT_IAC + 1))
      results+=("{\"path\":\"${path}\",\"category\":\"${category}\",\"status\":\"not-iac\",\"deploymentVerified\":null,\"resources\":[]}")
      continue
      ;;
  esac

  # Match each extracted resource name against scan results
  file_results=()
  all_found=true
  any_found=false

  while IFS= read -r res_name; do
    [[ -z "$res_name" ]] && continue
    found=$(find_in_scan "$res_name")
    if [[ "$found" -gt 0 ]]; then
      any_found=true
      # Get first match details
      match_detail=$(jq --arg n "${res_name,,}" \
        '[.[] | select((.name | ascii_downcase) == $n)] | first' \
        "$ALL_RESOURCES_FILE" 2>/dev/null || echo '{}')
      file_results+=("{\"name\":\"${res_name}\",\"foundInAzure\":true,\"details\":${match_detail}}")
    else
      all_found=false
      file_results+=("{\"name\":\"${res_name}\",\"foundInAzure\":false,\"details\":null}")
    fi
  done <<< "$resource_names"

  # Determine deployment status
  if [[ ${#file_results[@]} -eq 0 ]]; then
    status="no-resources-extracted"
    UNMATCHED=$((UNMATCHED + 1))
  elif [[ "$all_found" == "true" ]]; then
    status="all-deployed"
    MATCHED=$((MATCHED + 1))
  elif [[ "$any_found" == "true" ]]; then
    status="partially-deployed"
    UNMATCHED=$((UNMATCHED + 1))
  else
    status="not-deployed"
    UNMATCHED=$((UNMATCHED + 1))
  fi

  res_array=$(printf '%s\n' "${file_results[@]}" | jq -s '.')
  results+=("{\"path\":\"${path}\",\"category\":\"${category}\",\"status\":\"${status}\",\"deploymentVerified\":${any_found},\"resourceGroupHint\":\"${rg_hint}\",\"resources\":${res_array}}")

done < <(jq -c '.[]' "$PR_CHANGES_FILE")

# ── Write output ──────────────────────────────────────────────────────────────
RESULTS_JSON=$(printf '%s\n' "${results[@]}" | jq -s '.')

jq -n \
  --arg runId "$RUN_ID" \
  --arg ts "$TIMESTAMP" \
  --argjson matched "$MATCHED" \
  --argjson unmatched "$UNMATCHED" \
  --argjson notIac "$NOT_IAC" \
  --argjson results "$RESULTS_JSON" \
  '{
    runId: $runId,
    timestamp: $ts,
    summary: {
      matched: $matched,
      unmatched: $unmatched,
      notIacFiles: $notIac,
      deploymentCoverage: (if ($matched + $unmatched) > 0 then ($matched / ($matched + $unmatched) * 100 | floor | tostring) + "%" else "N/A" end)
    },
    results: $results
  }' > "${OUTPUT_DIR}/deployment-match-report.json"

echo ""
echo "============================================================"
echo "REVIEW COMPLETE"
echo "  Matched (deployed):   ${MATCHED}"
echo "  Unmatched (not found): ${UNMATCHED}"
echo "  Non-IaC files:        ${NOT_IAC}"
echo "============================================================"
