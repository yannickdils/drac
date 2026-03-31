#!/usr/bin/env bash
# =============================================================================
# validate-dr-config.sh
# Stage 5b: Run az deployment what-if validation on generated DR templates.
# Non-fatal: validation errors are reported but do not block the PR.
# Idempotent: what-if is always read-only.
# =============================================================================
set -euo pipefail

DR_DIR=""
DR_REGION=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dr-dir)     DR_DIR="$2";     shift 2 ;;
    --dr-region)  DR_REGION="$2";  shift 2 ;;
    --run-id)     RUN_ID="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

echo "============================================================"
echo "STAGE 5b: Validate DR Configuration (what-if)"
echo "  DR Region: ${DR_REGION}"
echo "  Run ID:    ${RUN_ID}"
echo "============================================================"

VALIDATION_RESULTS=()
PASS=0
FAIL=0

while IFS= read -r metadata_file; do
  sub_id=$(jq -r '.subscriptionId' "$metadata_file")
  dr_rg=$(jq -r '.drResourceGroup' "$metadata_file")
  template_file="$(dirname "$metadata_file")/template.json"
  params_file="$(dirname "$metadata_file")/parameters.json"

  [[ ! -f "$template_file" ]] && continue

  echo "  Validating: ${dr_rg} (sub: ${sub_id})"

  # Attempt validation (non-fatal)
  validation_output=$(az deployment group validate \
    --resource-group "$dr_rg" \
    --template-file "$template_file" \
    --parameters "$params_file" \
    --subscription "$sub_id" \
    --output json 2>&1) || validation_output="$validation_output"

  validation_ok=$(echo "$validation_output" | jq -r '.properties.provisioningState // "Failed"' 2>/dev/null || echo "Failed")

  if [[ "$validation_ok" == "Succeeded" || "$validation_ok" == "Accepted" ]]; then
    PASS=$((PASS + 1))
    VALIDATION_RESULTS+=("{\"resourceGroup\":\"${dr_rg}\",\"status\":\"valid\",\"error\":null}")
  else
    FAIL=$((FAIL + 1))
    error_msg=$(echo "$validation_output" | jq -r '.error.message // "Unknown validation error"' 2>/dev/null || echo "Parse error")
    VALIDATION_RESULTS+=("{\"resourceGroup\":\"${dr_rg}\",\"status\":\"invalid\",\"error\":\"${error_msg}\"}")
    echo "  WARN: Validation failed for ${dr_rg}: ${error_msg}"
  fi
done < <(find "${DR_DIR}" -name "dr-metadata.json")

RESULTS_JSON=$(printf '%s\n' "${VALIDATION_RESULTS[@]}" | jq -s '.')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg runId "$RUN_ID" \
  --arg ts "$TIMESTAMP" \
  --argjson pass "$PASS" \
  --argjson fail "$FAIL" \
  --argjson results "$RESULTS_JSON" \
  '{
    runId: $runId,
    timestamp: $ts,
    validationSummary: { passed: $pass, failed: $fail },
    results: $results
  }' > "${DR_DIR}/dr-validation-report.json"

echo ""
echo "============================================================"
echo "DR VALIDATION COMPLETE"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL} (non-fatal — review DR templates)"
echo "============================================================"
