#!/usr/bin/env bash
# =============================================================================
# export-arm-templates.sh
# Stage 2a: Export ARM templates per resource group using REST API
# ARM API version: 2021-04-01
# Idempotent: skips already-exported resource groups.
# Fault-tolerant: failed exports are logged and skipped.
# =============================================================================
set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
SCAN_DIR=""
ARM_API_VERSION="2021-04-01"
OUTPUT_DIR=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan-dir)          SCAN_DIR="$2";          shift 2 ;;
    --arm-api-version)   ARM_API_VERSION="$2";   shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";        shift 2 ;;
    --run-id)            RUN_ID="$2";            shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$SCAN_DIR" ]]   && { echo "ERROR: --scan-dir is required";   exit 1; }
[[ -z "$OUTPUT_DIR" ]] && { echo "ERROR: --output-dir is required"; exit 1; }

mkdir -p "${OUTPUT_DIR}/arm-templates"
mkdir -p "${OUTPUT_DIR}/bicep-templates"

FAILED_RGS=()
EXPORTED_COUNT=0
SKIPPED_COUNT=0

echo "============================================================"
echo "STAGE 2a: Export ARM Templates"
echo "  ARM API: ${ARM_API_VERSION}"
echo "  Run ID: ${RUN_ID}"
echo "============================================================"

# ── Export one resource group ─────────────────────────────────────────────────
export_resource_group() {
  local sub_id="$1"
  local rg_name="$2"
  local out_dir="${OUTPUT_DIR}/arm-templates/${sub_id}/${rg_name}"

  # Idempotency: skip if already exported in this run
  if [[ -f "${out_dir}/template.json" ]]; then
    echo "  SKIP (already exported): ${rg_name}"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi

  mkdir -p "$out_dir"

  echo "  Exporting: ${rg_name} (sub: ${sub_id})"

  # Export via ARM REST API (POST /exportTemplate)
  local response
  response=$(az rest \
    --method POST \
    --uri "https://management.azure.com/subscriptions/${sub_id}/resourcegroups/${rg_name}/exportTemplate?api-version=${ARM_API_VERSION}" \
    --body '{"resources":["*"],"options":"IncludeParameterDefaultValue,IncludeComments,SkipResourceNameParameterization"}' \
    --output json 2>/dev/null) || {
    echo "  WARN: Export failed for ${rg_name}, continuing"
    FAILED_RGS+=("${sub_id}/${rg_name}")
    return 0
  }

  # Handle long-running operation (202 with Location header → poll)
  local status
  status=$(echo "$response" | jq -r '.status // "Succeeded"')
  if [[ "$status" == "Running" || "$status" == "Accepted" ]]; then
    echo "  INFO: Export is async for ${rg_name}, polling..."
    local location
    location=$(echo "$response" | jq -r '.properties.templateLink // empty' 2>/dev/null || echo "")
    if [[ -n "$location" ]]; then
      sleep 10
      response=$(az rest --method GET --uri "$location" --output json 2>/dev/null) || true
    fi
  fi

  # Save ARM template
  echo "$response" | jq '.template // .' > "${out_dir}/template.json"

  # Save errors/warnings if any
  local errors
  errors=$(echo "$response" | jq '.error // null')
  if [[ "$errors" != "null" ]]; then
    echo "$errors" > "${out_dir}/export-errors.json"
    echo "  WARN: Partial export for ${rg_name} — see export-errors.json"
  fi

  # Save resource list from the scan for cross-reference
  local rg_resources
  rg_resources=$(jq --arg rg "${rg_name,,}" --arg sub "$sub_id" \
    '[.[] | select((.resourceGroup | ascii_downcase) == $rg and .subscriptionId == $sub)]' \
    "${SCAN_DIR}/all-resources.json" 2>/dev/null || echo "[]")
  echo "$rg_resources" > "${out_dir}/resources.json"

  # Attempt decompile to Bicep
  local bicep_out="${OUTPUT_DIR}/bicep-templates/${sub_id}/${rg_name}"
  mkdir -p "$bicep_out"
  az bicep decompile --file "${out_dir}/template.json" --outdir "$bicep_out" 2>/dev/null || {
    echo "  INFO: Bicep decompile skipped for ${rg_name} (non-critical)"
  }

  # Save subscription metadata
  jq -n \
    --arg sub "$sub_id" \
    --arg rg "$rg_name" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{ subscriptionId: $sub, resourceGroup: $rg, exportedAt: $ts }' \
    > "${out_dir}/metadata.json"

  EXPORTED_COUNT=$((EXPORTED_COUNT + 1))
}

# ── Process all resource groups from scan ─────────────────────────────────────
RG_FILE="${SCAN_DIR}/resource-groups.json"
if [[ ! -f "$RG_FILE" ]]; then
  echo "ERROR: resource-groups.json not found in ${SCAN_DIR}"
  exit 1
fi

TOTAL_RGS=$(jq 'length' "$RG_FILE")
echo "INFO: Processing ${TOTAL_RGS} resource groups"

# Read resource groups and export each
while IFS= read -r rg_json; do
  sub_id=$(echo "$rg_json" | jq -r '.subscriptionId')
  rg_name=$(echo "$rg_json" | jq -r '.name')

  [[ -z "$sub_id" || -z "$rg_name" ]] && continue

  # Switch subscription context for the export call
  az account set --subscription "$sub_id" 2>/dev/null || {
    echo "  WARN: Could not switch to subscription ${sub_id}, skipping ${rg_name}"
    FAILED_RGS+=("${sub_id}/${rg_name}")
    continue
  }

  export_resource_group "$sub_id" "$rg_name"
done < <(jq -c '.[]' "$RG_FILE")

# ── Build index of all exported templates ─────────────────────────────────────
find "${OUTPUT_DIR}/arm-templates" -name "metadata.json" -exec cat {} \; | \
  jq -s '.' > "${OUTPUT_DIR}/export-index.json"

# ── Summary ───────────────────────────────────────────────────────────────────
FAILED_COUNT=${#FAILED_RGS[@]}
jq -n \
  --arg runId "$RUN_ID" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson exported "$EXPORTED_COUNT" \
  --argjson skipped "$SKIPPED_COUNT" \
  --argjson failed "$FAILED_COUNT" \
  --argjson total "$TOTAL_RGS" \
  --argjson failedList "$(printf '%s\n' "${FAILED_RGS[@]}" | jq -R . | jq -s .)" \
  '{
    runId: $runId,
    timestamp: $ts,
    totalResourceGroups: $total,
    exported: $exported,
    skipped: $skipped,
    failed: $failed,
    failedResourceGroups: $failedList
  }' > "${OUTPUT_DIR}/export-summary.json"

echo ""
echo "============================================================"
echo "EXPORT COMPLETE"
echo "  Total RGs:  ${TOTAL_RGS}"
echo "  Exported:   ${EXPORTED_COUNT}"
echo "  Skipped:    ${SKIPPED_COUNT}"
echo "  Failed:     ${FAILED_COUNT}"
echo "============================================================"

# Non-zero exit only if ALL exports failed
if [[ $EXPORTED_COUNT -eq 0 && $TOTAL_RGS -gt 0 ]]; then
  echo "ERROR: All exports failed"
  exit 1
fi
