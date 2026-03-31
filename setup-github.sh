#!/usr/bin/env bash
# =============================================================================
# setup-github.sh
# Bootstrap script for GitHub Actions:
#   1. Creates an Azure AD App Registration
#   2. Configures OIDC federated credentials for GitHub Actions
#   3. Assigns required Azure roles to the app
#   4. Sets GitHub repository secrets via the gh CLI
#
# Prerequisites:
#   - Azure CLI logged in: az login
#   - GitHub CLI logged in: gh auth login
#   - Target repo set via GITHUB_REPO env var
#
# Usage:
#   export GITHUB_REPO="your-org/your-repo"
#   export AZURE_SUBSCRIPTION_IDS="sub-id-1,sub-id-2"
#   export DR_TARGET_REGION="northeurope"
#   export DR_VNET_ADDRESS_PREFIX="10.1.0.0/16"
#   export DR_SUBNET_ADDRESS_PREFIX="10.1.0.0/24"
#   ./setup-github.sh
# =============================================================================
set -euo pipefail

: "${GITHUB_REPO:?Must set GITHUB_REPO, e.g. your-org/your-repo}"
: "${AZURE_SUBSCRIPTION_IDS:?Must set AZURE_SUBSCRIPTION_IDS}"
: "${DR_TARGET_REGION:?Must set DR_TARGET_REGION}"
: "${DR_VNET_ADDRESS_PREFIX:?Must set DR_VNET_ADDRESS_PREFIX}"
: "${DR_SUBNET_ADDRESS_PREFIX:?Must set DR_SUBNET_ADDRESS_PREFIX}"

APP_NAME="draac-pipeline-${GITHUB_REPO//\//-}"
DR_NAMING_PREFIX="${DR_NAMING_PREFIX:-dr-}"

echo "========================================================"
echo "DRaaC — GitHub Actions Bootstrap Setup"
echo "  Repo:    ${GITHUB_REPO}"
echo "  App:     ${APP_NAME}"
echo "========================================================"

# ── 1. Get tenant and primary subscription ────────────────────────────────────
echo ""
echo "Step 1: Resolving Azure context..."
TENANT_ID=$(az account show --query tenantId -o tsv)
PRIMARY_SUB=$(echo "$AZURE_SUBSCRIPTION_IDS" | cut -d',' -f1 | tr -d ' ')
echo "  Tenant: ${TENANT_ID}"
echo "  Primary subscription: ${PRIMARY_SUB}"

# ── 2. Create App Registration ────────────────────────────────────────────────
echo ""
echo "Step 2: Creating App Registration '${APP_NAME}'..."

EXISTING_APP_ID=$(az ad app list \
  --display-name "$APP_NAME" \
  --query "[0].appId" -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING_APP_ID" && "$EXISTING_APP_ID" != "None" ]]; then
  echo "  INFO: App Registration already exists — reusing (ID: ${EXISTING_APP_ID})"
  APP_ID="$EXISTING_APP_ID"
else
  APP_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --query appId -o tsv)
  echo "  ✅ Created App Registration (Client ID: ${APP_ID})"
fi

# Create service principal if it doesn't exist
SP_EXISTS=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || echo "")
if [[ -z "$SP_EXISTS" ]]; then
  az ad sp create --id "$APP_ID" --query id -o tsv > /dev/null
  echo "  ✅ Created Service Principal"
else
  echo "  INFO: Service Principal already exists"
fi

# ── 3. Configure OIDC Federated Credentials ───────────────────────────────────
echo ""
echo "Step 3: Configuring OIDC federated credentials..."

REPO_OWNER="${GITHUB_REPO%%/*}"
REPO_NAME="${GITHUB_REPO##*/}"

# Federated credential for pull_request events
PR_CRED_NAME="github-pr-${REPO_NAME}"
EXISTING_CRED=$(az ad app federated-credential list \
  --id "$APP_ID" \
  --query "[?name=='${PR_CRED_NAME}'].name" -o tsv 2>/dev/null || echo "")

if [[ -z "$EXISTING_CRED" ]]; then
  az ad app federated-credential create \
    --id "$APP_ID" \
    --parameters "{
      \"name\": \"${PR_CRED_NAME}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"repo:${GITHUB_REPO}:pull_request\",
      \"description\": \"DRaaC pipeline PR trigger for ${GITHUB_REPO}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" > /dev/null
  echo "  ✅ Created pull_request OIDC credential"
else
  echo "  INFO: pull_request OIDC credential already exists"
fi

# Federated credential for main branch push (optional, for branch-based runs)
MAIN_CRED_NAME="github-main-${REPO_NAME}"
EXISTING_MAIN_CRED=$(az ad app federated-credential list \
  --id "$APP_ID" \
  --query "[?name=='${MAIN_CRED_NAME}'].name" -o tsv 2>/dev/null || echo "")

if [[ -z "$EXISTING_MAIN_CRED" ]]; then
  az ad app federated-credential create \
    --id "$APP_ID" \
    --parameters "{
      \"name\": \"${MAIN_CRED_NAME}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"repo:${GITHUB_REPO}:ref:refs/heads/main\",
      \"description\": \"DRaaC pipeline main branch for ${GITHUB_REPO}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" > /dev/null
  echo "  ✅ Created main branch OIDC credential"
else
  echo "  INFO: main branch OIDC credential already exists"
fi

# ── 4. Assign Azure Roles (idempotent) ────────────────────────────────────────
echo ""
echo "Step 4: Assigning Azure roles..."

assign_role_if_missing() {
  local role="$1"
  local scope="$2"
  local existing
  existing=$(az role assignment list \
    --assignee "$APP_ID" \
    --role "$role" \
    --scope "$scope" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")

  if [[ -z "$existing" || "$existing" == "None" ]]; then
    az role assignment create \
      --assignee "$APP_ID" \
      --role "$role" \
      --scope "$scope" \
      --output none
    echo "  ✅ Assigned '${role}' on ${scope}"
  else
    echo "  INFO: '${role}' already assigned on ${scope}"
  fi
}

# Reader on each subscription (for scan and export)
IFS=',' read -ra SUBS <<< "$AZURE_SUBSCRIPTION_IDS"
for sub in "${SUBS[@]}"; do
  sub=$(echo "$sub" | tr -d ' ')
  [[ "$sub" == "ALL" ]] && continue
  assign_role_if_missing "Reader" "/subscriptions/${sub}"
done

# If ALL subscriptions, assign at tenant root (requires elevated permissions)
if [[ "$AZURE_SUBSCRIPTION_IDS" == "ALL" ]]; then
  echo "  INFO: AZURE_SUBSCRIPTION_IDS=ALL — manually assign Reader at management group or tenant level"
fi

# Contributor on DR subscription for what-if validation
if [[ -n "${DR_SUBSCRIPTION_ID:-}" ]]; then
  assign_role_if_missing "Contributor" "/subscriptions/${DR_SUBSCRIPTION_ID}"
else
  # Default: contributor on first subscription for validation
  assign_role_if_missing "Contributor" "/subscriptions/${PRIMARY_SUB}"
fi

# ── 5. Set GitHub Repository Secrets ─────────────────────────────────────────
echo ""
echo "Step 5: Setting GitHub repository secrets..."

set_secret() {
  local name="$1"
  local value="$2"
  echo "$value" | gh secret set "$name" --repo "$GITHUB_REPO"
  echo "  ✅ Secret set: ${name}"
}

set_secret "AZURE_CLIENT_ID"           "$APP_ID"
set_secret "AZURE_TENANT_ID"           "$TENANT_ID"
set_secret "AZURE_SUBSCRIPTION_ID"     "$PRIMARY_SUB"
set_secret "AZURE_SUBSCRIPTION_IDS"    "$AZURE_SUBSCRIPTION_IDS"
set_secret "DR_TARGET_REGION"          "$DR_TARGET_REGION"
set_secret "DR_VNET_ADDRESS_PREFIX"    "$DR_VNET_ADDRESS_PREFIX"
set_secret "DR_SUBNET_ADDRESS_PREFIX"  "$DR_SUBNET_ADDRESS_PREFIX"
set_secret "DR_NAMING_PREFIX"          "$DR_NAMING_PREFIX"

if [[ -n "${MANAGEMENT_GROUP_ID:-}" ]]; then
  set_secret "MANAGEMENT_GROUP_ID" "$MANAGEMENT_GROUP_ID"
fi

# ── 6. Configure branch protection ───────────────────────────────────────────
echo ""
echo "Step 6: Configuring branch protection on 'main'..."

gh api "repos/${GITHUB_REPO}/branches/main/protection" \
  --method PUT \
  --field required_status_checks='{"strict":true,"contexts":["1 · Scan Azure Subscriptions","2 · Export & Document Environment","3 · Review Code vs Deployed State","4 · Configuration Drift Detection","5 · Generate DR Configuration","6 · Final Report & PR Annotation"]}' \
  --field enforce_admins=false \
  --field required_pull_request_reviews='{"required_approving_review_count":1}' \
  --field restrictions=null \
  2>/dev/null && echo "  ✅ Branch protection configured" || \
  echo "  INFO: Branch protection update skipped (may need admin rights or branch doesn't exist yet)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo "GITHUB SETUP COMPLETE"
echo ""
echo "  App Registration (Client ID): ${APP_ID}"
echo "  Tenant ID:                    ${TENANT_ID}"
echo "  Repository:                   ${GITHUB_REPO}"
echo ""
echo "Next steps:"
echo "  1. Copy .github/workflows/pr-compliance.yml to your repo (already done if running from repo root)"
echo "  2. Open a PR against main to trigger the first DRaaC run"
echo "  3. View the Actions run at: https://github.com/${GITHUB_REPO}/actions"
echo "========================================================"
