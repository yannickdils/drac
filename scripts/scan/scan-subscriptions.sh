#!/usr/bin/env bash
# =============================================================================
# scan-subscriptions.sh
# Stage 1: Scan all Azure subscriptions using Azure Resource Graph API v2024-04-01
# Idempotent: re-runs produce the same output directory structure.
# Fault-tolerant: individual subscription failures are logged, not fatal.
# =============================================================================
set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
API_VERSION="2024-04-01"
SUBSCRIPTION_IDS=""
MANAGEMENT_GROUP=""
OUTPUT_DIR=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-version)       API_VERSION="$2";       shift 2 ;;
    --subscription-ids)  SUBSCRIPTION_IDS="$2";  shift 2 ;;
    --management-group)  MANAGEMENT_GROUP="$2";  shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";        shift 2 ;;
    --run-id)            RUN_ID="$2";            shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$OUTPUT_DIR" ]] && { echo "ERROR: --output-dir is required"; exit 1; }

SCAN_DIR="${OUTPUT_DIR}/scan"
mkdir -p "${SCAN_DIR}"

echo "============================================================"
echo "STAGE 1: Azure Subscription Scan"
echo "  Resource Graph API: ${API_VERSION}"
echo "  Run ID: ${RUN_ID}"
echo "  Output: ${SCAN_DIR}"
echo "============================================================"

# ── Resolve subscriptions ─────────────────────────────────────────────────────
resolve_subscriptions() {
  if [[ -n "$MANAGEMENT_GROUP" && "$MANAGEMENT_GROUP" != "none" ]]; then
    echo "INFO: Querying subscriptions in management group: ${MANAGEMENT_GROUP}"
    az account management-group show \
      --name "${MANAGEMENT_GROUP}" \
      --expand \
      --recurse \
      --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'].name" \
      --output tsv 2>/dev/null || \
    az account list --query "[].id" --output tsv
  elif [[ -n "$SUBSCRIPTION_IDS" && "$SUBSCRIPTION_IDS" != "ALL" ]]; then
    echo "$SUBSCRIPTION_IDS" | tr ',' '\n' | tr -d ' '
  else
    echo "INFO: Fetching all accessible subscriptions"
    az account list --query "[?state=='Enabled'].id" --output tsv
  fi
}

SUBSCRIPTIONS=$(resolve_subscriptions)
SUB_COUNT=$(echo "$SUBSCRIPTIONS" | grep -c '[a-z0-9]' || echo "0")
echo "INFO: Found ${SUB_COUNT} subscription(s) to scan"

# Persist subscription list for downstream stages
echo "$SUBSCRIPTIONS" > "${SCAN_DIR}/subscriptions.txt"

# ── Build Resource Graph query body ──────────────────────────────────────────
build_query_body() {
  local query="$1"
  local skip_token="${2:-}"
  local sub_array

  # Build JSON array of subscription IDs
  sub_array=$(echo "$SUBSCRIPTIONS" | jq -R . | jq -s .)

  if [[ -n "$MANAGEMENT_GROUP" && "$MANAGEMENT_GROUP" != "none" ]]; then
    jq -n \
      --argjson subs "$sub_array" \
      --arg mg "$MANAGEMENT_GROUP" \
      --arg q "$query" \
      --arg st "$skip_token" \
      '{
        managementGroups: [$mg],
        query: $q,
        options: { "$top": 1000, resultFormat: "objectArray" }
      } + if $st != "" then { options: { "$skipToken": $st, "$top": 1000, resultFormat: "objectArray" } } else {} end'
  else
    jq -n \
      --argjson subs "$sub_array" \
      --arg q "$query" \
      --arg st "$skip_token" \
      '{
        subscriptions: $subs,
        query: $q,
        options: { "$top": 1000, resultFormat: "objectArray" }
      } + if $st != "" then { options: { "$skipToken": $st, "$top": 1000, resultFormat: "objectArray" } } else {} end'
  fi
}

# ── Paginated Resource Graph query ────────────────────────────────────────────
run_resource_graph_query() {
  local query="$1"
  local output_file="$2"
  local all_results="[]"
  local skip_token=""
  local page=0

  echo "INFO: Running Resource Graph query (paginated)"

  while true; do
    page=$((page + 1))
    echo "  Page ${page}..."

    local body
    body=$(build_query_body "$query" "$skip_token")

    local response
    response=$(az rest \
      --method POST \
      --uri "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=${API_VERSION}" \
      --body "$body" \
      --output json 2>/dev/null) || {
      echo "WARN: Resource Graph query failed on page ${page}, skipping"
      break
    }

    local page_data
    page_data=$(echo "$response" | jq '.data // []')
    all_results=$(echo "$all_results $page_data" | jq -s 'add')

    skip_token=$(echo "$response" | jq -r '."$skipToken" // ""')
    [[ -z "$skip_token" || "$skip_token" == "null" ]] && break
  done

  echo "$all_results" > "$output_file"
  local count
  count=$(echo "$all_results" | jq 'length')
  echo "INFO: Query returned ${count} records → ${output_file}"
}

# ── Execute scans ─────────────────────────────────────────────────────────────

# 1. All resources overview
run_resource_graph_query \
  "Resources | project id, name, type, location, resourceGroup, subscriptionId, tags, kind, sku, properties | order by type asc" \
  "${SCAN_DIR}/all-resources.json"

# 2. Virtual networks & subnets (critical for DR)
run_resource_graph_query \
  "Resources
  | where type =~ 'Microsoft.Network/virtualNetworks'
  | project id, name, resourceGroup, subscriptionId, location,
    addressSpace=properties.addressSpace,
    subnets=properties.subnets,
    dhcpOptions=properties.dhcpOptions,
    enableDdosProtection=properties.enableDdosProtection,
    tags" \
  "${SCAN_DIR}/vnets.json"

# 3. Network Security Groups
run_resource_graph_query \
  "Resources
  | where type =~ 'Microsoft.Network/networkSecurityGroups'
  | project id, name, resourceGroup, subscriptionId, location,
    securityRules=properties.securityRules,
    defaultSecurityRules=properties.defaultSecurityRules,
    tags" \
  "${SCAN_DIR}/nsgs.json"

# 4. Compute resources
run_resource_graph_query \
  "Resources
  | where type in~ ('Microsoft.Compute/virtualMachines',
                    'Microsoft.Compute/virtualMachineScaleSets',
                    'Microsoft.ContainerService/managedClusters',
                    'Microsoft.Web/sites',
                    'Microsoft.Web/serverFarms')
  | project id, name, type, resourceGroup, subscriptionId, location,
    sku, properties, tags" \
  "${SCAN_DIR}/compute.json"

# 5. Storage & databases
run_resource_graph_query \
  "Resources
  | where type in~ ('Microsoft.Storage/storageAccounts',
                    'Microsoft.Sql/servers',
                    'Microsoft.Sql/servers/databases',
                    'Microsoft.DocumentDB/databaseAccounts',
                    'Microsoft.DBforPostgreSQL/flexibleServers',
                    'Microsoft.DBforMySQL/flexibleServers',
                    'Microsoft.Cache/Redis')
  | project id, name, type, resourceGroup, subscriptionId, location,
    sku, kind, properties, tags" \
  "${SCAN_DIR}/storage-databases.json"

# 6. Key Vaults & security
run_resource_graph_query \
  "Resources
  | where type in~ ('Microsoft.KeyVault/vaults',
                    'Microsoft.ManagedIdentity/userAssignedIdentities')
  | project id, name, type, resourceGroup, subscriptionId, location, properties, tags" \
  "${SCAN_DIR}/security.json"

# 7. Role assignments (RBAC)
run_resource_graph_query \
  "AuthorizationResources
  | where type =~ 'microsoft.authorization/roleassignments'
  | project id, name, roleDefinitionId=properties.roleDefinitionId,
    principalId=properties.principalId,
    principalType=properties.principalType,
    scope=properties.scope,
    subscriptionId" \
  "${SCAN_DIR}/rbac.json"

# 8. Policy assignments
run_resource_graph_query \
  "PolicyResources
  | where type =~ 'microsoft.authorization/policyassignments'
  | project id, name, displayName=properties.displayName,
    policyDefinitionId=properties.policyDefinitionId,
    scope=properties.scope,
    parameters=properties.parameters" \
  "${SCAN_DIR}/policies.json"

# 9. Resource groups with metadata
run_resource_graph_query \
  "ResourceContainers
  | where type =~ 'microsoft.resources/subscriptions/resourcegroups'
  | project id, name, location, subscriptionId, tags, managedBy" \
  "${SCAN_DIR}/resource-groups.json"

# 10. Application Gateways & Load Balancers
run_resource_graph_query \
  "Resources
  | where type in~ ('Microsoft.Network/applicationGateways',
                    'Microsoft.Network/loadBalancers',
                    'Microsoft.Network/publicIPAddresses',
                    'Microsoft.Network/privateDnsZones',
                    'Microsoft.Network/dnszones')
  | project id, name, type, resourceGroup, subscriptionId, location,
    sku, properties, tags" \
  "${SCAN_DIR}/networking-advanced.json"

# ── Summary metadata ──────────────────────────────────────────────────────────
TOTAL_RESOURCES=$(jq 'length' "${SCAN_DIR}/all-resources.json")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg runId "$RUN_ID" \
  --arg ts "$TIMESTAMP" \
  --arg apiVer "$API_VERSION" \
  --argjson subCount "$SUB_COUNT" \
  --argjson totalRes "$TOTAL_RESOURCES" \
  '{
    runId: $runId,
    timestamp: $ts,
    apiVersion: $apiVer,
    subscriptionsScanned: $subCount,
    totalResourcesFound: $totalRes,
    status: "completed"
  }' > "${SCAN_DIR}/scan-summary.json"

echo ""
echo "============================================================"
echo "SCAN COMPLETE"
echo "  Subscriptions: ${SUB_COUNT}"
echo "  Total resources: ${TOTAL_RESOURCES}"
echo "  Output: ${SCAN_DIR}"
echo "============================================================"
