// =============================================================================
// bicep/modules/dr-keyvault-sync-drrole.bicep
// Round 4 §R4.4 — sub-module for the cross-RG role assignment on the DR
// Key Vault.
//
// Why this exists.
// `Microsoft.Authorization/roleAssignments` resources can only be deployed to
// the resource group that contains the target resource. The parent module
// `dr-keyvault-sync.bicep` deploys the Function App in the primary RG; the
// DR Key Vault lives in the DR region's RG. Bicep raises BCP139 when an
// inline role-assignment declaration references a cross-RG `existing`
// resource. The supported pattern is to wrap the cross-RG resources in a
// sub-module deployed via `module ... scope: resourceGroup(<sub>, <rg>)`.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults
// (looked up 2026-05-06)
//
// Idempotency: `name: guid(scope, principal, role)` — re-running upserts.
// =============================================================================

@description('Name of the DR Key Vault (no slashes). Must already exist in the resource group this sub-module deploys to.')
@minLength(3)
@maxLength(24)
param drKeyVaultName string

@description('Principal id (object id) of the Function App managed identity to grant.')
param principalId string

@description('Built-in role definition GUID (e.g. Key Vault Secrets Officer = b86a8fe4-44ce-4948-aee5-eccb2c155cd7).')
param roleDefinitionGuid string

@description('Description shown in the portal for the role assignment.')
param assignmentDescription string = 'DRaaC: granted by dr-keyvault-sync module.'

resource drVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: drKeyVaultName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(drVault.id, principalId, roleDefinitionGuid)
  scope: drVault
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionGuid)
    description: assignmentDescription
  }
}

output assignmentId string = roleAssignment.id
output drVaultId string = drVault.id
