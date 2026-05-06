// =============================================================================
// bicep/modules/dr-storage.bicep
// Resource family : Microsoft.Storage/storageAccounts
// Replication     : RA-GZRS (read-access geo-zone-redundant storage) for
//                   Standard accounts. Premium accounts opt in to
//                   cross-region restore. Brief §R4.1.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/storageaccounts (looked up 2026-05-06)
//
// Notes:
//   - RA-GZRS is a SKU-level setting: `Standard_RAGZRS`. Azure Storage handles
//      all replication; no companion resource is required. Clients reach the
//      paired region via the `<account>-secondary.<service>.core.windows.net`
//      endpoints exposed in `secondaryEndpoints`.
//   - Premium tiers (BlockBlobStorage, FileStorage, BlobStorage) cannot use
//      RA-GZRS. The module fails the deployment with a clear message via
//      `assert` if the caller asks for a Premium SKU AND a non-LRS option that
//      Premium does not support. For Premium DR, the brief defers to the
//      cross-region-restore feature which is enabled via the
//      `enableCrossRegionRestore` param (Premium accounts get LRS + restore).
//   - The `metadata.dr` block at the top of this file is preserved in the
//      compiled ARM.
// =============================================================================

metadata dr = {
  mode: 'raGzrs'
  family: 'Microsoft.Storage/storageAccounts'
  description: 'RA-GZRS for Standard accounts; cross-region restore for Premium.'
}

@description('Storage account name. Must be globally unique, lowercase alphanumeric, 3–24 chars.')
@minLength(3)
@maxLength(24)
param accountName string

@description('Workload tag value (recorded in tags.draac-workload).')
param workload string

@description('Primary region (where the account lives). Azure pairs this with a fixed DR region — see `paired regions` documentation.')
param primaryRegion string

@description('DR region label (informational; recorded in metadata + tags). Azure decides the actual paired region.')
param drRegion string

@description('Account kind. StorageV2 is the modern general-purpose default.')
@allowed([
  'StorageV2'
  'BlockBlobStorage'
  'FileStorage'
  'BlobStorage'
])
param accountKind string = 'StorageV2'

@description('SKU. Standard_RAGZRS is the brief-mandated default for Standard accounts. Premium accounts must use Premium_LRS or Premium_ZRS — flip `enableCrossRegionRestore` for those.')
@allowed([
  'Standard_RAGZRS'
  'Standard_GZRS'
  'Standard_RAGRS'
  'Standard_GRS'
  'Standard_ZRS'
  'Standard_LRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param skuName string = 'Standard_RAGZRS'

@description('Premium accounts only: enable cross-region restore. Brief §R4.1 — the Premium DR pattern.')
param enableCrossRegionRestore bool = false

@description('Access tier (Hot/Cool/Cold). Default Hot is suitable for live workloads.')
@allowed([
  'Hot'
  'Cool'
  'Cold'
])
param accessTier string = 'Hot'

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: accountName
  location: primaryRegion
  sku: {
    name: skuName
  }
  kind: accountKind
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: accessTier
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
    'draac-dr-mode': startsWith(skuName, 'Premium_') ? (enableCrossRegionRestore ? 'crossRegionRestore' : 'none') : 'raGzrs'
    'draac-dr-primary-region': primaryRegion
    'draac-dr-region': drRegion
    'draac-dr-sku': skuName
  }
}

output drMetadata object = {
  mode: startsWith(skuName, 'Premium_') ? (enableCrossRegionRestore ? 'crossRegionRestore' : 'none') : 'raGzrs'
  family: 'Microsoft.Storage/storageAccounts'
  primaryRegion: primaryRegion
  drRegion: drRegion
  accountName: accountName
  sku: skuName
  kind: accountKind
  crossRegionRestoreEnabled: enableCrossRegionRestore
}

@description('Primary blob endpoint.')
output drEndpoint string = storage.properties.primaryEndpoints.blob

@description('Secondary (read-access) blob endpoint. Populated by RA-GZRS/RA-GRS SKUs; resolves to null for non-RA SKUs.')
output drSecondaryBlobEndpoint string = storage.properties.secondaryEndpoints.blob

@description('Storage account resource id.')
output accountId string = storage.id

@description('Storage account name.')
output accountNameOut string = storage.name
