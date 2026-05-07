// =============================================================================
// bicep/modules/dr-postgres.bicep
// Resource family : Microsoft.DBforPostgreSQL/flexibleServers
// Replication     : Read replica (createMode = 'Replica') in the DR region.
//                   The replica is bootstrapped from the primary's resource id
//                   and stays in sync via Postgres logical replication. On
//                   disaster, the replica is promoted (manually, or via
//                   `Test-DRHealth`'s recovery action) to a standalone primary.
//                   Brief §R4.1.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.dbforpostgresql/flexibleservers (looked up 2026-05-06)
//
// Notes:
//   - The replica MUST be in a different region from the primary AND in a
//      compatible SKU tier (Burstable replicas are not supported as of
//      2024-08-01 — the brief defers SKU validation to PSRule).
//   - The primary's `replicationRole` should already be `Primary` (default).
//   - The replica's admin login + password fields are NOT used (replicas
//      inherit credentials from the primary) but the API still requires them
//      to be present — we leave them at empty strings, which the API tolerates
//      for createMode=Replica.
// =============================================================================

metadata dr = {
  mode: 'readReplica'
  family: 'Microsoft.DBforPostgreSQL/flexibleServers'
  description: 'PostgreSQL flexible-server read replica in the DR region. Promote on failover.'
}

@description('Replica server name (DR region). 3–63 chars, lowercase alphanumeric + hyphens.')
@minLength(3)
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

@description('SKU name for the replica. Should match or exceed the primary tier (Standard_D2s_v3 is the typical default).')
param skuName string = 'Standard_D2s_v3'

@description('SKU tier. Burstable replicas are not supported; use GeneralPurpose or MemoryOptimized.')
@allowed([
  'GeneralPurpose'
  'MemoryOptimized'
])
param skuTier string = 'GeneralPurpose'

@description('PostgreSQL major version. Should match the primary.')
@allowed([
  '11'
  '12'
  '13'
  '14'
  '15'
  '16'
  '17'
])
param postgresVersion string = '16'

@description('Storage size in GB. Must be at least as large as the primary.')
@minValue(32)
param storageSizeGB int = 128

resource replica 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: replicaName
  location: drLocation
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    createMode: 'Replica'
    sourceServerResourceId: sourceServerResourceId
    version: postgresVersion
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
  family: 'Microsoft.DBforPostgreSQL/flexibleServers'
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
