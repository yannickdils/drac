// =============================================================================
// bicep/modules/dr-keyvault.bicep
// Resource family : Microsoft.KeyVault/vaults
// Replication     : Soft-delete + purge protection (Azure Key Vault is
//                   regional; secret/key/cert content does NOT replicate
//                   automatically). The DR vault is a SEPARATE vault in the
//                   DR region; secrets are reconciled on a schedule by the
//                   Function App in `dr-keyvault-sync.bicep` (R4.4) which
//                   reads from primary and writes to DR. This module only
//                   provisions the DR vault with the safety properties Brief
//                   §R4.1 requires.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults (looked up 2026-05-06)
//
// Notes:
//   - `enableSoftDelete` is implicit (always-on, irreversibly true) on
//      `Microsoft.KeyVault/vaults` API ≥ 2019-09-01. We set it explicitly to
//      `true` for clarity.
//   - `enablePurgeProtection: true` is mandatory for the DR vault. Once set,
//      it cannot be turned off. The brief §R4.1 lists this as the
//      replication-mode marker.
//   - The DR vault is created with RBAC authorization (not access policies) by
//      default — modern Azure pattern. The Sync Function (R4.4) is granted
//      `Key Vault Secrets Officer` separately by the orchestrator.
// =============================================================================

metadata dr = {
  mode: 'softDeletePurgeProtection'
  family: 'Microsoft.KeyVault/vaults'
  description: 'DR vault with soft-delete + purge-protection. Secrets sync handled by R4.4 (dr-keyvault-sync.bicep).'
}

@description('DR Key Vault name. Globally unique, 3–24 chars, lowercase alphanumeric + hyphens.')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Workload tag value (recorded in tags.draac-workload).')
param workload string

@description('Primary region (informational; recorded in metadata).')
param primaryRegion string

@description('DR region where the vault is created.')
param drLocation string

@description('Azure tenant id used by the vault.')
param tenantId string = subscription().tenantId

@description('Vault SKU. `standard` for most workloads; `premium` is HSM-backed.')
@allowed([
  'standard'
  'premium'
])
param skuName string = 'standard'

@description('Soft-delete retention in days. Brief recommends 90.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Use RBAC instead of access policies for data-plane permissions. Modern default.')
param enableRbacAuthorization bool = true

@description('Allow Azure Resource Manager to read secrets at deployment time.')
param enabledForTemplateDeployment bool = false

@description('Allow Azure Disk Encryption to retrieve secrets.')
param enabledForDiskEncryption bool = false

@description('Allow Azure VMs to retrieve secrets stored as certificates.')
param enabledForDeployment bool = false

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: vaultName
  location: drLocation
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: skuName
    }
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: true
    enableRbacAuthorization: enableRbacAuthorization
    enabledForTemplateDeployment: enabledForTemplateDeployment
    enabledForDiskEncryption: enabledForDiskEncryption
    enabledForDeployment: enabledForDeployment
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    accessPolicies: []
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
    'draac-dr-mode': 'softDeletePurgeProtection'
    'draac-dr-primary-region': primaryRegion
    'draac-dr-region': drLocation
  }
}

output drMetadata object = {
  mode: 'softDeletePurgeProtection'
  family: 'Microsoft.KeyVault/vaults'
  primaryRegion: primaryRegion
  drRegion: drLocation
  vaultName: vaultName
  softDeleteRetentionInDays: softDeleteRetentionInDays
  purgeProtectionEnabled: true
  rbacEnabled: enableRbacAuthorization
}

@description('Vault DNS endpoint (clients connect here; auth via tenantId + RBAC).')
output drEndpoint string = vault.properties.vaultUri

@description('Vault resource id.')
output vaultId string = vault.id

@description('Vault name.')
output vaultNameOut string = vault.name
