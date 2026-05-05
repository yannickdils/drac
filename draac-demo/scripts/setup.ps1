#Requires -Version 7.2
<#
.SYNOPSIS
    One-time setup for the DRaaC demo. Creates an Azure AD app registration,
    configures OIDC federation for GitHub Actions, assigns Contributor on the
    current subscription, and sets the three required repository secrets.
.PREREQUISITES
    - az login (with Owner or User Access Administrator on the target subscription)
    - gh auth login
    - Run from the repo root
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoFull   # owner/repo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==> DRaaC Demo Setup"
Write-Host "    Repo: $RepoFull"
Write-Host ""

# 1. Get current Azure context
$tenantId = az account show --query tenantId -o tsv
$subId    = az account show --query id -o tsv
Write-Host "    Tenant:       $tenantId"
Write-Host "    Subscription: $subId"

# 2. Create or reuse app registration
$appName = "draac-demo-$($RepoFull -replace '/', '-')"
$existingAppId = az ad app list --display-name $appName --query "[0].appId" -o tsv

if ($existingAppId) {
    $appId = $existingAppId
    Write-Host "==> Reusing app registration: $appId"
} else {
    $appId = az ad app create --display-name $appName --query appId -o tsv
    az ad sp create --id $appId --output none
    Write-Host "==> Created app registration: $appId"
}

# 3. Federated credentials for PR and main
$repoName  = $RepoFull.Split('/')[1]

foreach ($scenario in @(
    @{ Name = 'pr';   Subject = "repo:${RepoFull}:pull_request" },
    @{ Name = 'main'; Subject = "repo:${RepoFull}:ref:refs/heads/main" }
)) {
    $credName = "gh-$($scenario.Name)-$repoName"
    $existing = az ad app federated-credential list --id $appId --query "[?name=='$credName'].name" -o tsv
    if ($existing) {
        Write-Host "==> Federated credential exists: $credName"
        continue
    }
    $payload = @{
        name      = $credName
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $scenario.Subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    az ad app federated-credential create --id $appId --parameters $payload --output none
    Write-Host "==> Created federated credential: $credName"
}

# 4. Role assignment
$existingRole = az role assignment list --assignee $appId --role Contributor --scope "/subscriptions/$subId" --query "[0].id" -o tsv
if ($existingRole) {
    Write-Host "==> Contributor role already assigned"
} else {
    az role assignment create --assignee $appId --role Contributor --scope "/subscriptions/$subId" --output none
    Write-Host "==> Assigned Contributor on /subscriptions/$subId"
    Write-Host "    Waiting 30s for role propagation..."
    Start-Sleep -Seconds 30
}

# 5. GitHub repo secrets
$appId    | gh secret set AZURE_CLIENT_ID       --repo $RepoFull
$tenantId | gh secret set AZURE_TENANT_ID       --repo $RepoFull
$subId    | gh secret set AZURE_SUBSCRIPTION_ID --repo $RepoFull
Write-Host "==> Set repository secrets"

Write-Host ""
Write-Host "==> Setup complete."
Write-Host "    Next: open a PR to main, then merge it."
