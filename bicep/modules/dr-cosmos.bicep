// =============================================================================
// bicep/modules/dr-cosmos.bicep
// Resource family : Microsoft.DocumentDB/databaseAccounts
// Replication     : Multi-region writes + automatic failover. The module
//                   provisions a single Cosmos DB account that lists BOTH the
//                   primary region and the DR region in `locations[]`, with
//                   `enableAutomaticFailover: true` and (optionally)
//                   `enableMultipleWriteLocations: true`. Brief §R4.1.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.documentdb/databaseaccounts (looked up 2026-05-06)
//
// Notes:
//   - Cosmos uses ONE account that spans regions, not a primary+companion pair.
//      For DR, that account is configured (or reconfigured) here. The
//      `Convert-ForDR` dispatch records this module against the primary
//      account's resource type so the DR PR includes the multi-region config.
//   - The `metadata.dr` block at the top of this file is preserved in the
//      compiled ARM so Test-DRHealth can read the replication contract.
// =============================================================================

metadata dr = {
  mode: 'multiRegion'
  family: 'Microsoft.DocumentDB/databaseAccounts'
  description: 'Multi-region Cosmos DB account with automatic failover and (optional) multi-region writes.'
}

@description('Cosmos DB account name. Must be globally unique, lowercase, 3–44 chars.')
@minLength(3)
@maxLength(44)
param accountName string

@description('Workload tag value (recorded in tags.draac-workload).')
param workload string

@description('Primary write region (e.g. westeurope). Receives priority 0.')
param primaryRegion string

@description('DR (failover) region (e.g. northeurope). Receives priority 1.')
param drRegion string

@description('Enable multi-region writes (active-active). Default false (single-write with automatic failover) — flip to true for the strongest write availability.')
param enableMultipleWriteLocations bool = false

@description('Database account API kind. GlobalDocumentDB = Core (SQL) API.')
@allowed([
  'GlobalDocumentDB'
  'MongoDB'
  'Parse'
])
param accountKind string = 'GlobalDocumentDB'

@description('Default consistency level. Brief defers to caller; Session is the typical recommended default.')
@allowed([
  'Eventual'
  'Session'
  'BoundedStaleness'
  'Strong'
  'ConsistentPrefix'
])
param consistencyLevel string = 'Session'

@description('Bounded-staleness max staleness prefix (only used when consistencyLevel = BoundedStaleness).')
@minValue(10)
param maxStalenessPrefix int = 100000

@description('Bounded-staleness max interval seconds (only used when consistencyLevel = BoundedStaleness).')
@minValue(5)
param maxIntervalInSeconds int = 300

@description('Backup policy type. Continuous enables PITR; Periodic is the legacy default.')
@allowed([
  'Continuous'
  'Periodic'
])
param backupPolicyType string = 'Continuous'

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: accountName
  location: primaryRegion
  kind: accountKind
  properties: {
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: true
    enableMultipleWriteLocations: enableMultipleWriteLocations
    consistencyPolicy: {
      defaultConsistencyLevel: consistencyLevel
      maxStalenessPrefix: maxStalenessPrefix
      maxIntervalInSeconds: maxIntervalInSeconds
    }
    locations: [
      {
        locationName: primaryRegion
        failoverPriority: 0
        isZoneRedundant: false
      }
      {
        locationName: drRegion
        failoverPriority: 1
        isZoneRedundant: false
      }
    ]
    backupPolicy: {
      type: backupPolicyType
    }
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: 'Tls12'
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
    'draac-dr-mode': 'multiRegion'
    'draac-dr-primary-region': primaryRegion
    'draac-dr-region': drRegion
  }
}

output drMetadata object = {
  mode: 'multiRegion'
  family: 'Microsoft.DocumentDB/databaseAccounts'
  primaryRegion: primaryRegion
  drRegion: drRegion
  accountName: accountName
  multipleWriteLocations: enableMultipleWriteLocations
  automaticFailover: true
}

@description('Primary write endpoint for the Cosmos DB account.')
output drEndpoint string = account.properties.documentEndpoint

@description('Account resource id.')
output accountId string = account.id

@description('Account name.')
output accountNameOut string = account.name
