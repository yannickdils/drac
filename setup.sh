#!/usr/bin/env bash
# =============================================================================
# setup.sh
# Bootstrap script: creates the ADO variable group and registers the pipeline
# using the Azure DevOps REST API (v7.1).
#
# Usage:
#   export ADO_ORG="https://dev.azure.com/my-org"
#   export ADO_PROJECT="my-project"
#   export ADO_PAT="<personal-access-token>"
#   ./setup.sh
#
# The PAT needs: Variable Groups (Read & Manage), Build (Read & Execute)
# =============================================================================
set -euo pipefail

: "${ADO_ORG:?Must set ADO_ORG, e.g. https://dev.azure.com/my-org}"
: "${ADO_PROJECT:?Must set ADO_PROJECT}"
: "${ADO_PAT:?Must set ADO_PAT}"

ADO_API_VERSION="7.1"
ENCODED_PAT=$(printf '%s' ":${ADO_PAT}" | base64 -w 0)
AUTH_HEADER="Authorization: Basic ${ENCODED_PAT}"
CONTENT_HEADER="Content-Type: application/json"
PROJECT_ENC=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$ADO_PROJECT")

echo "========================================================"
echo "Azure Compliance Pipeline — Bootstrap Setup"
echo "  Org:     ${ADO_ORG}"
echo "  Project: ${ADO_PROJECT}"
echo "========================================================"

# ── 1. Create variable group ─────────────────────────────────────────────────
echo ""
echo "Step 1: Creating variable group 'azure-compliance-pipeline-secrets'..."

VG_PAYLOAD=$(cat <<'EOF'
{
  "name": "azure-compliance-pipeline-secrets",
  "type": "Vsts",
  "variables": {
    "AZURE_SERVICE_CONNECTION": { "value": "REPLACE_ME", "isSecret": false },
    "AZURE_TENANT_ID":          { "value": "REPLACE_ME", "isSecret": false },
    "AZURE_SUBSCRIPTION_IDS":   { "value": "ALL",        "isSecret": false },
    "MANAGEMENT_GROUP_ID":      { "value": "none",       "isSecret": false },
    "drTargetRegion":           { "value": "northeurope","isSecret": false },
    "drVnetAddressPrefix":      { "value": "10.1.0.0/16","isSecret": false },
    "drSubnetAddressPrefix":    { "value": "10.1.0.0/24","isSecret": false },
    "drNamingPrefix":           { "value": "dr-",        "isSecret": false }
  }
}
EOF
)

VG_RESPONSE=$(curl -sS -X POST \
  "${ADO_ORG}/${PROJECT_ENC}/_apis/distributedtask/variablegroups?api-version=${ADO_API_VERSION}" \
  -H "$AUTH_HEADER" \
  -H "$CONTENT_HEADER" \
  -d "$VG_PAYLOAD")

VG_ID=$(echo "$VG_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','ERROR'))")

if [[ "$VG_ID" == "ERROR" ]]; then
  echo "  WARN: Variable group may already exist or creation failed."
  echo "  Response: $VG_RESPONSE"
  # Try to get existing ID
  VG_LIST=$(curl -sS \
    "${ADO_ORG}/${PROJECT_ENC}/_apis/distributedtask/variablegroups?groupName=azure-compliance-pipeline-secrets&api-version=${ADO_API_VERSION}" \
    -H "$AUTH_HEADER")
  VG_ID=$(echo "$VG_LIST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['value'][0]['id'] if d.get('count',0)>0 else 'NOT_FOUND')")
  echo "  Existing variable group ID: ${VG_ID}"
else
  echo "  ✅ Variable group created with ID: ${VG_ID}"
fi

echo ""
echo "  ⚠️  ACTION REQUIRED: Update the following variables in the ADO Library:"
echo "     AZURE_SERVICE_CONNECTION → your ADO service connection name"
echo "     AZURE_TENANT_ID          → your Azure tenant ID"
echo "     AZURE_SUBSCRIPTION_IDS   → comma-separated subscription IDs or ALL"
echo "     drTargetRegion           → DR target region"
echo "     drVnetAddressPrefix      → DR VNet CIDR"
echo "     drSubnetAddressPrefix    → DR subnet CIDR"
echo ""
echo "     URL: ${ADO_ORG}/${ADO_PROJECT}/_library?itemType=VariableGroups"

# ── 2. Get repository ID ──────────────────────────────────────────────────────
echo ""
echo "Step 2: Fetching repository ID..."

REPOS=$(curl -sS \
  "${ADO_ORG}/${PROJECT_ENC}/_apis/git/repositories?api-version=${ADO_API_VERSION}" \
  -H "$AUTH_HEADER")

REPO_COUNT=$(echo "$REPOS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))")
echo "  Found ${REPO_COUNT} repository(ies)"

if [[ "$REPO_COUNT" -eq 1 ]]; then
  REPO_ID=$(echo "$REPOS" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'][0]['id'])")
  REPO_NAME=$(echo "$REPOS" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'][0]['name'])")
  echo "  Using repository: ${REPO_NAME} (${REPO_ID})"
else
  echo "  Multiple repos found. Set REPO_NAME and re-run, or create pipeline manually."
  echo "$REPOS" | python3 -c "import sys,json; [print('  -', r['name'], r['id']) for r in json.load(sys.stdin).get('value',[])]"
  REPO_ID="REPLACE_WITH_REPO_ID"
  REPO_NAME="REPLACE_WITH_REPO_NAME"
fi

# ── 3. Create pipeline definition ─────────────────────────────────────────────
echo ""
echo "Step 3: Creating pipeline definition..."

PIPELINE_PAYLOAD=$(python3 -c "
import json
payload = {
  'name': 'PR Compliance — Azure Deployment Validation',
  'folder': '\\\\compliance',
  'configuration': {
    'type': 'yaml',
    'path': '/.azure/pipelines/pr-compliance.yml',
    'repository': {
      'id': '${REPO_ID}',
      'name': '${REPO_NAME}',
      'type': 'azureReposGit'
    }
  }
}
print(json.dumps(payload))
")

PIPELINE_RESPONSE=$(curl -sS -X POST \
  "${ADO_ORG}/${PROJECT_ENC}/_apis/pipelines?api-version=${ADO_API_VERSION}" \
  -H "$AUTH_HEADER" \
  -H "$CONTENT_HEADER" \
  -d "$PIPELINE_PAYLOAD")

PIPELINE_ID=$(echo "$PIPELINE_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','ERROR'))")

if [[ "$PIPELINE_ID" == "ERROR" ]]; then
  echo "  WARN: Pipeline creation may have failed. Create manually:"
  echo "  URL: ${ADO_ORG}/${ADO_PROJECT}/_build"
  echo "  Path: .azure/pipelines/pr-compliance.yml"
else
  echo "  ✅ Pipeline created with ID: ${PIPELINE_ID}"
  echo "  URL: ${ADO_ORG}/${ADO_PROJECT}/_build?definitionId=${PIPELINE_ID}"
fi

# ── 4. Configure branch policy (informational) ────────────────────────────────
echo ""
echo "Step 4: Branch policy setup (manual step)"
echo ""
echo "  To require this pipeline as a PR gate on 'main':"
echo "  1. Go to: ${ADO_ORG}/${ADO_PROJECT}/_settings/repositories"
echo "  2. Select your repo → Policies → Branch Policies → main"
echo "  3. Add Build Validation → Select 'PR Compliance' pipeline"
echo "  4. Set to Required"
echo ""
echo "========================================================"
echo "SETUP COMPLETE"
echo ""
echo "Next steps:"
echo "  1. Update variable group values at:"
echo "     ${ADO_ORG}/${ADO_PROJECT}/_library?itemType=VariableGroups"
echo "  2. Configure branch policy (Step 4 above)"
echo "  3. Create a test PR to main to verify the pipeline runs"
echo "========================================================"
