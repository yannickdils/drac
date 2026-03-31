#!/usr/bin/env bash
# =============================================================================
# generate-dr-config.sh
# Stage 5a: Generate DR-ready Bicep templates for secondary region.
# Transforms ARM exports:
#   - Updates location to DR region
#   - Rewrites VNet/subnet address spaces
#   - Applies DR naming prefix
#   - Rewrites resource references for DR context
# Idempotent: re-running produces identical output given the same inputs.
# Fault-tolerant: per-resource-group failures are logged but do not stop the run.
# =============================================================================
set -euo pipefail

EXPORT_DIR=""
OUTPUT_DIR=""
DR_REGION=""
DR_VNET_PREFIX=""
DR_SUBNET_PREFIX=""
DR_NAMING_PREFIX="dr-"
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-dir)         EXPORT_DIR="$2";         shift 2 ;;
    --output-dir)         OUTPUT_DIR="$2";         shift 2 ;;
    --dr-region)          DR_REGION="$2";          shift 2 ;;
    --dr-vnet-prefix)     DR_VNET_PREFIX="$2";     shift 2 ;;
    --dr-subnet-prefix)   DR_SUBNET_PREFIX="$2";   shift 2 ;;
    --dr-naming-prefix)   DR_NAMING_PREFIX="$2";   shift 2 ;;
    --run-id)             RUN_ID="$2";             shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$DR_REGION"      ]] && { echo "ERROR: --dr-region is required";        exit 1; }
[[ -z "$DR_VNET_PREFIX" ]] && { echo "ERROR: --dr-vnet-prefix is required";   exit 1; }
[[ -z "$DR_SUBNET_PREFIX" ]] && { echo "ERROR: --dr-subnet-prefix is required"; exit 1; }

mkdir -p "${OUTPUT_DIR}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_DISPLAY=$(date -u +"%Y-%m-%d")
PROCESSED=0
FAILED=0

echo "============================================================"
echo "STAGE 5a: Generate DR Configuration"
echo "  DR Region:        ${DR_REGION}"
echo "  VNet Prefix:      ${DR_VNET_PREFIX}"
echo "  Subnet Prefix:    ${DR_SUBNET_PREFIX}"
echo "  Naming Prefix:    ${DR_NAMING_PREFIX}"
echo "  Run ID:           ${RUN_ID}"
echo "============================================================"

# ── Helper: derive subnet space from VNet prefix ──────────────────────────────
# Given 10.1.0.0/16 → first subnet = 10.1.0.0/24 (use provided DR_SUBNET_PREFIX)
calc_subnet_addresses() {
  local vnet_prefix="$1"
  # Return the user-specified DR subnet prefix
  echo "$DR_SUBNET_PREFIX"
}

# ── Transform a single ARM template for DR ────────────────────────────────────
transform_arm_to_dr() {
  local src_template="$1"
  local src_sub="$2"
  local src_rg="$3"
  local dr_rg="${DR_NAMING_PREFIX}${src_rg}"
  local out_dir="${OUTPUT_DIR}/arm/${src_sub}/${dr_rg}"

  mkdir -p "$out_dir"

  echo "  Transforming: ${src_rg} → ${dr_rg} (${DR_REGION})"

  # Read template
  local template
  template=$(cat "$src_template" 2>/dev/null) || {
    echo "  WARN: Could not read ${src_template}, skipping"
    return 1
  }

  # ── Apply transformations using jq ────────────────────────────────────────
  local dr_template
  dr_template=$(echo "$template" | jq \
    --arg drRegion "$DR_REGION" \
    --arg drVnet "$DR_VNET_PREFIX" \
    --arg drSubnet "$DR_SUBNET_PREFIX" \
    --arg prefix "$DR_NAMING_PREFIX" \
    --arg srcRg "$src_rg" \
    --arg drRg "$dr_rg" \
    '
    # Recursively walk and apply transformations
    def transform:
      if type == "object" then
        . as $obj |
        reduce ($obj | keys[]) as $k (
          {};
          . + {
            ($k): (
              if $k == "location" then $drRegion
              elif $k == "addressPrefixes" then [$drVnet]
              elif $k == "addressPrefix" then $drSubnet
              elif $k == "name" then (
                # Prefix resource names, avoid double-prefixing
                if ($obj[$k] | type) == "string" and ($obj[$k] | startswith($prefix) | not)
                then $prefix + $obj[$k]
                else $obj[$k]
                end
              )
              else ($obj[$k] | transform)
              end
            )
          }
        )
      elif type == "array" then map(transform)
      else .
      end;

    # Transform resources array
    if .resources then
      .resources = [
        .resources[] |
        transform |
        # Update resource group references
        if .properties?.targetResourceGroup then
          .properties.targetResourceGroup = $drRg
        else .
        end
      ]
    else .
    end |

    # Add DR metadata comment in parameters
    .parameters += {
      "drMetadata": {
        "type": "string",
        "defaultValue": ("DR configuration for " + $srcRg + " → " + $drRg),
        "metadata": { "description": "Auto-generated DR configuration" }
      },
      "drRegion": {
        "type": "string",
        "defaultValue": $drRegion,
        "metadata": { "description": "Disaster recovery target region" }
      }
    }
    ') || {
    echo "  WARN: jq transformation failed for ${src_rg}"
    return 1
  }

  echo "$dr_template" > "${out_dir}/template.json"

  # ── Generate Bicep version ──────────────────────────────────────────────────
  local bicep_dir="${OUTPUT_DIR}/bicep/${src_sub}/${dr_rg}"
  mkdir -p "$bicep_dir"

  az bicep decompile --file "${out_dir}/template.json" --outdir "$bicep_dir" 2>/dev/null || {
    echo "  INFO: Bicep decompile skipped for DR ${dr_rg}"
  }

  # ── Generate DR parameters file ────────────────────────────────────────────
  jq -n \
    --arg drRegion "$DR_REGION" \
    --arg drRg "$dr_rg" \
    --arg drVnet "$DR_VNET_PREFIX" \
    --arg drSubnet "$DR_SUBNET_PREFIX" \
    '{
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
      "contentVersion": "1.0.0.0",
      "parameters": {
        "location": { "value": $drRegion },
        "resourceGroupName": { "value": $drRg },
        "vnetAddressPrefix": { "value": $drVnet },
        "subnetAddressPrefix": { "value": $drSubnet }
      }
    }' > "${out_dir}/parameters.json"

  # ── Generate deployment script ──────────────────────────────────────────────
  cat > "${out_dir}/deploy-dr.sh" << DEPLOY_SCRIPT
#!/usr/bin/env bash
# Auto-generated DR deployment script — ${dr_rg} in ${DR_REGION}
# Generated: ${DATE_DISPLAY} | Run: ${RUN_ID}
set -euo pipefail

SUBSCRIPTION_ID="${src_sub}"
DR_RG="${dr_rg}"
DR_REGION="${DR_REGION}"

echo "Deploying DR configuration: \${DR_RG} → \${DR_REGION}"

# Create resource group (idempotent)
az group create \\
  --name "\${DR_RG}" \\
  --location "\${DR_REGION}" \\
  --subscription "\${SUBSCRIPTION_ID}" \\
  --tags environment=dr source-rg=${src_rg} generated-by=compliance-pipeline

# What-if first
az deployment group what-if \\
  --resource-group "\${DR_RG}" \\
  --template-file template.json \\
  --parameters parameters.json \\
  --subscription "\${SUBSCRIPTION_ID}"

# Uncomment to deploy:
# az deployment group create \\
#   --resource-group "\${DR_RG}" \\
#   --template-file template.json \\
#   --parameters parameters.json \\
#   --subscription "\${SUBSCRIPTION_ID}" \\
#   --mode Incremental
DEPLOY_SCRIPT
  chmod +x "${out_dir}/deploy-dr.sh"

  # ── Metadata ──────────────────────────────────────────────────────────────
  jq -n \
    --arg sub "$src_sub" \
    --arg srcRg "$src_rg" \
    --arg drRg "$dr_rg" \
    --arg drRegion "$DR_REGION" \
    --arg ts "$TIMESTAMP" \
    '{
      subscriptionId: $sub,
      sourceResourceGroup: $srcRg,
      drResourceGroup: $drRg,
      drRegion: $drRegion,
      generatedAt: $ts
    }' > "${out_dir}/dr-metadata.json"

  return 0
}

# ── Process all exported resource groups ──────────────────────────────────────
EXPORT_INDEX="${EXPORT_DIR}/export-index.json"
[[ ! -f "$EXPORT_INDEX" ]] && { echo "ERROR: export-index.json not found"; exit 1; }

while IFS= read -r entry; do
  sub_id=$(echo "$entry" | jq -r '.subscriptionId')
  rg_name=$(echo "$entry" | jq -r '.resourceGroup')
  template_file="${EXPORT_DIR}/arm-templates/${sub_id}/${rg_name}/template.json"

  [[ ! -f "$template_file" ]] && { echo "  SKIP: No template for ${rg_name}"; continue; }

  if transform_arm_to_dr "$template_file" "$sub_id" "$rg_name"; then
    PROCESSED=$((PROCESSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done < <(jq -c '.[]' "$EXPORT_INDEX")

# ── DR index ──────────────────────────────────────────────────────────────────
find "${OUTPUT_DIR}" -name "dr-metadata.json" -exec cat {} \; | \
  jq -s '.' > "${OUTPUT_DIR}/dr-index.json"

# ── DR README ─────────────────────────────────────────────────────────────────
DR_RG_COUNT=$(jq 'length' "${OUTPUT_DIR}/dr-index.json")

cat > "${OUTPUT_DIR}/DR-README.md" << DRREADME
# Disaster Recovery Configuration

> **Generated:** ${DATE_DISPLAY}  
> **Pipeline Run:** \`${RUN_ID}\`  
> **Target Region:** \`${DR_REGION}\`

## Overview

This directory contains auto-generated DR configurations for **${DR_RG_COUNT}** resource group(s).
Each subfolder contains:

- \`template.json\` — ARM template adapted for the DR region
- \`parameters.json\` — DR-specific parameter values  
- \`deploy-dr.sh\` — Automated deployment script (what-if enabled by default)
- \`dr-metadata.json\` — Transformation metadata

## Network Configuration

| Parameter | Value |
|---|---|
| DR Region | \`${DR_REGION}\` |
| VNet Address Space | \`${DR_VNET_PREFIX}\` |
| Subnet Address Prefix | \`${DR_SUBNET_PREFIX}\` |
| Naming Convention | Resources prefixed with \`${DR_NAMING_PREFIX}\` |

## Deployment Steps

1. Review the \`what-if\` output by running \`deploy-dr.sh\`
2. Uncomment the deploy command in \`deploy-dr.sh\`
3. Validate connectivity and failover routes post-deployment
4. Test application layer connectivity

## ⚠️ Manual Review Required

- Passwords and secrets are **not included** — inject via Key Vault or pipeline secrets
- Review private endpoint configurations for the DR region
- Update DNS records and Traffic Manager profiles after DR deployment
- Verify peering / hub-spoke topology is replicated

---
_This file is auto-generated. Do not edit manually._
DRREADME

jq -n \
  --arg runId "$RUN_ID" \
  --arg ts "$TIMESTAMP" \
  --arg drRegion "$DR_REGION" \
  --argjson processed "$PROCESSED" \
  --argjson failed "$FAILED" \
  '{
    runId: $runId,
    timestamp: $ts,
    drRegion: $drRegion,
    processed: $processed,
    failed: $failed
  }' > "${OUTPUT_DIR}/dr-summary.json"

echo ""
echo "============================================================"
echo "DR GENERATION COMPLETE"
echo "  Processed: ${PROCESSED} resource groups"
echo "  Failed:    ${FAILED}"
echo "  Region:    ${DR_REGION}"
echo "============================================================"
