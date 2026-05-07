// =============================================================================
// bicep/modules/dr-mysql.bicep
// Resource family : Microsoft.DBforMySQL/flexibleServers
// Replication     : Read replica (createMode = 'Replica') in the DR region.
//                   On disaster, the replica is promoted (Stop replication +
//                   set replicationRole=None) to a standalone primary. Brief
//                   §R4.1.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.dbformysql/flexibleservers (looked up 2026-05-06)
//
// Notes:
//   - Burstable-tier replicas are not supported; the param `skuTier` is
//      restricted to GeneralPurpose / MemoryOptimized.
//   - Storage size on the replica must be >= the primary at creation.
//   - The `metadata.dr` block at the top of this file is preserved in the
//      compiled ARM.
// =============================================================================

metadata dr = {
  mode: 'readReplica'
  family: 'Microsoft.DBforMySQL/flexibleServers'
  description: 'MySQL flexible-server read replica in the DR region. Promote on failover.'
}

@description('Replica server name (DR region). 1–63 chars, lowercase alphanumeric + hyphens.')
@minLength(1)
@maxLength(63)
param replicaName string

@description('Workload tag value (recorded in tags.draac-workload).')
param workload string

@description('Resource id of the primary server (sourceServerResourceId).')
param sourceServerResourceId string

@description('Primary region (informational; recorded in metadata).')
param primaryRegion string

@description('DR region where the replica is created.')
param drLocation string

@description('SKU name for the replica. Should match or exceed the primary tier.')
param skuName string = 'Standard_D2ds_v4'

@description('SKU tier. Burstable replicas are not supported.')
@allowed([
  'GeneralPurpose'
  'MemoryOptimized'
])
param skuTier string = 'GeneralPurpose'

@description('MySQL major version. Should match the primary.')
@allowed([
  '5.7'
  '8.0.21'
  '8.4'
])
param mysqlVersion string = '8.0.21'

@description('Storage size in GB. Must be at least as large as the primary.')
@minValue(20)
param storageSizeGB int = 128

resource replica 'Microsoft.DBforMySQL/flexibleServers@2024-12-30' = {
  name: replicaName
  location: drLocation
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    createMode: 'Replica'
    sourceServerResourceId: sourceServerResourceId
    version: mysqlVersion
    storage: {
      storageSizeGB: storageSizeGB
    }
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
    'draac-dr-mode': 'readReplica'
    'draac-dr-primary-region': primaryRegion
    'draac-dr-region': drLocation
  }
}

output drMetadata object = {
  mode: 'readReplica'
  family: 'Microsoft.DBforMySQL/flexibleServers'
  primaryRegion: primaryRegion
  drRegion: drLocation
  replicaName: replicaName
  sourceServerResourceId: sourceServerResourceId
  skuName: skuName
  skuTier: skuTier
}

@description('FQDN of the replica server. Use for read-only queries until promotion; promote on failover.')
output drEndpoint string = replica.properties.fullyQualifiedDomainName

@description('Replica resource id.')
output replicaId string = replica.id

@description('Replica server name.')
output replicaNameOut string = replica.name
