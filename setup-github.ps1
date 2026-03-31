#Requires -Version 7.2
# =============================================================================
# setup-github.ps1
# Bootstrap script for GitHub Actions:
#   1. Creates an Azure AD App Registration
#   2. Configures OIDC federated credentials for GitHub Actions
#   3. Assigns required Azure roles to the app
#   4. Sets GitHub repository secrets via the gh CLI
#
# Prerequisites:
#   - Azure CLI logged in:  az login
#   - GitHub CLI logged in: gh auth login
#
# Usage:
#   $env:GITHUB_REPO              = "your-org/your-repo"
#   $env:AZURE_SUBSCRIPTION_IDS   = "sub-id-1,sub-id-2"
#   $env:DR_TARGET_REGION         = "northeurope"
#   $env:DR_VNET_ADDRESS_PREFIX   = "10.1.0.0/16"
#   $env:DR_SUBNET_ADDRESS_PREFIX = "10.1.0.0/24"
#   ./setup-github.ps1
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GitHubRepo           = $env:GITHUB_REPO              ?? (Read-Host "GITHUB_REPO (e.g. your-org/your-repo)")
$SubscriptionIds      = $env:AZURE_SUBSCRIPTION_IDS   ?? (Read-Host "AZURE_SUBSCRIPTION_IDS (comma-separated or ALL)")
$DrTargetRegion       = $env:DR_TARGET_REGION         ?? (Read-Host "DR_TARGET_REGION (e.g. northeurope)")
$DrVnetPrefix         = $env:DR_VNET_ADDRESS_PREFIX   ?? (Read-Host "DR_VNET_ADDRESS_PREFIX (e.g. 10.1.0.0/16)")
$DrSubnetPrefix       = $env:DR_SUBNET_ADDRESS_PREFIX ?? (Read-Host "DR_SUBNET_ADDRESS_PREFIX (e.g. 10.1.0.0/24)")
$DrNamingPrefix       = $env:DR_NAMING_PREFIX         ?? "dr-"
$DrSubscriptionId     = $env:DR_SUBSCRIPTION_ID       ?? ""
$ManagementGroupId    = $env:MANAGEMENT_GROUP_ID      ?? ""

$AppName    = "draac-pipeline-$($GitHubRepo -replace '/', '-')"
$RepoOwner  = $GitHubRepo.Split('/')[0]
$RepoName   = $GitHubRepo.Split('/')[1]

Write-Host "========================================================"
Write-Host "DRaaC — GitHub Actions Bootstrap Setup"
Write-Host "  Repo: $GitHubRepo"
Write-Host "  App:  $AppName"
Write-Host "========================================================"

# ── Helper: idempotent role assignment ───────────────────────────────────────
function Set-RoleIfMissing {
    param([string]$Role, [string]$Scope, [string]$AppId)

    $existing = az role assignment list `
        --assignee $AppId --role $Role --scope $Scope `
        --query "[0].id" --output tsv 2>$null

    if ($existing -and $existing -ne "None") {
        Write-Host "  INFO: '$Role' already assigned on $Scope"
    } else {
        az role assignment create --assignee $AppId --role $Role --scope $Scope --output none 2>$null
        Write-Host "  ✅ Assigned '$Role' on $Scope"
    }
}

# ── 1. Resolve Azure context ──────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 1: Resolving Azure context..."

$TenantId   = az account show --query tenantId --output tsv
$PrimarySub = ($SubscriptionIds -split ",")[0].Trim()
if ($PrimarySub -eq "ALL") {
    $PrimarySub = az account show --query id --output tsv
}

Write-Host "  Tenant:               $TenantId"
Write-Host "  Primary subscription: $PrimarySub"

# ── 2. Create App Registration ────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 2: Creating App Registration '$AppName'..."

$ExistingAppId = az ad app list --display-name $AppName --query "[0].appId" --output tsv 2>$null

if ($ExistingAppId -and $ExistingAppId -ne "None") {
    Write-Host "  INFO: App Registration already exists — reusing (ID: $ExistingAppId)"
    $AppId = $ExistingAppId
} else {
    $AppId = az ad app create --display-name $AppName --query appId --output tsv
    Write-Host "  ✅ Created App Registration (Client ID: $AppId)"
}

# Create service principal if missing
$SpExists = az ad sp show --id $AppId --query id --output tsv 2>$null
if (-not $SpExists -or $SpExists -eq "None") {
    az ad sp create --id $AppId --output none 2>$null
    Write-Host "  ✅ Created Service Principal"
} else {
    Write-Host "  INFO: Service Principal already exists"
}

# ── 3. Configure OIDC Federated Credentials ───────────────────────────────────
Write-Host ""
Write-Host "Step 3: Configuring OIDC federated credentials..."

function Set-FederatedCredential {
    param([string]$CredName, [string]$Subject, [string]$Description)

    $existing = az ad app federated-credential list `
        --id $AppId --query "[?name=='$CredName'].name" --output tsv 2>$null

    if ($existing) {
        Write-Host "  INFO: OIDC credential '$CredName' already exists"
        return
    }

    $credPayload = @{
        name        = $CredName
        issuer      = "https://token.actions.githubusercontent.com"
        subject     = $Subject
        description = $Description
        audiences   = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress

    az ad app federated-credential create --id $AppId --parameters $credPayload --output none 2>$null
    Write-Host "  ✅ Created OIDC credential: $CredName"
}

Set-FederatedCredential `
    -CredName    "github-pr-$RepoName" `
    -Subject     "repo:$GitHubRepo`:pull_request" `
    -Description "DRaaC pipeline PR trigger for $GitHubRepo"

Set-FederatedCredential `
    -CredName    "github-main-$RepoName" `
    -Subject     "repo:$GitHubRepo`:ref:refs/heads/main" `
    -Description "DRaaC pipeline main branch for $GitHubRepo"

# ── 4. Assign Azure Roles ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 4: Assigning Azure roles..."

if ($SubscriptionIds -eq "ALL") {
    Write-Host "  INFO: AZURE_SUBSCRIPTION_IDS=ALL — manually assign Reader at management group or tenant level"
} else {
    ($SubscriptionIds -split ",") | ForEach-Object {
        $sub = $_.Trim()
        if ($sub) { Set-RoleIfMissing -Role "Reader" -Scope "/subscriptions/$sub" -AppId $AppId }
    }
}

$drSub = if ($DrSubscriptionId) { $DrSubscriptionId } else { $PrimarySub }
Set-RoleIfMissing -Role "Contributor" -Scope "/subscriptions/$drSub" -AppId $AppId

# ── 5. Set GitHub Repository Secrets ─────────────────────────────────────────
Write-Host ""
Write-Host "Step 5: Setting GitHub repository secrets..."

function Set-GitHubSecret {
    param([string]$Name, [string]$Value)
    $Value | gh secret set $Name --repo $GitHubRepo
    Write-Host "  ✅ Secret set: $Name"
}

Set-GitHubSecret "AZURE_CLIENT_ID"           $AppId
Set-GitHubSecret "AZURE_TENANT_ID"           $TenantId
Set-GitHubSecret "AZURE_SUBSCRIPTION_ID"     $PrimarySub
Set-GitHubSecret "AZURE_SUBSCRIPTION_IDS"    $SubscriptionIds
Set-GitHubSecret "DR_TARGET_REGION"          $DrTargetRegion
Set-GitHubSecret "DR_VNET_ADDRESS_PREFIX"    $DrVnetPrefix
Set-GitHubSecret "DR_SUBNET_ADDRESS_PREFIX"  $DrSubnetPrefix
Set-GitHubSecret "DR_NAMING_PREFIX"          $DrNamingPrefix

if ($ManagementGroupId) {
    Set-GitHubSecret "MANAGEMENT_GROUP_ID" $ManagementGroupId
}

# ── 6. Configure branch protection ───────────────────────────────────────────
Write-Host ""
Write-Host "Step 6: Configuring branch protection on 'main'..."

$branchProtection = @{
    required_status_checks = @{
        strict   = $true
        contexts = @(
            "1 · Scan Azure Subscriptions"
            "2 · Export & Document Environment"
            "3 · Review Code vs Deployed State"
            "4 · Configuration Drift Detection"
            "5 · Generate DR Configuration"
            "6 · Final Report & PR Annotation"
        )
    }
    enforce_admins                  = $false
    required_pull_request_reviews   = @{ required_approving_review_count = 1 }
    restrictions                    = $null
} | ConvertTo-Json -Depth 5 -Compress

try {
    $branchProtection | gh api "repos/$GitHubRepo/branches/main/protection" --method PUT --input - | Out-Null
    Write-Host "  ✅ Branch protection configured"
} catch {
    Write-Warning "Branch protection update skipped (may need admin rights or branch doesn't exist yet): $_"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================================"
Write-Host "GITHUB SETUP COMPLETE"
Write-Host ""
Write-Host "  App Registration (Client ID): $AppId"
Write-Host "  Tenant ID:                    $TenantId"
Write-Host "  Repository:                   $GitHubRepo"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Ensure .github/workflows/pr-compliance.yml is committed to your repo"
Write-Host "  2. Open a PR against main to trigger the first DRaaC run"
Write-Host "  3. View Actions at: https://github.com/$GitHubRepo/actions"
Write-Host "========================================================"
