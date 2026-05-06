// =============================================================================
// bicep/modules/dr-redis.bicep
// Resource family : Microsoft.Cache/Redis
// Replication     : Geo-replication via Microsoft.Cache/redis/linkedServers.
//                   The DR cache is created in the DR region (Premium only)
//                   and then linked to the primary cache as a Secondary. Brief
//                   §R4.1: PREMIUM TIER ONLY — fail loudly if the caller
//                   passes a non-Premium SKU.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cache/redis (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.cache/redis/linkedservers (looked up 2026-05-06)
//
// Notes:
//   - Geo-replication uses the linkedServers child resource. The Secondary is
//      declared as a child of the PRIMARY cache (Microsoft.Cache convention).
//   - This module is intended to be deployed to the PRIMARY cache's resource
//      group (the linkedServer child must live alongside its parent). The DR
//      cache itself is created in `drLocation` regardless of the deployment
//      RG. If primary + DR live in different RGs, deploy this module against
//      the primary RG.
//   - The DR cache itself MUST be Premium. The Premium-only constraint is
//      enforced via a parameter `@allowed` decorator on `skuName` AND
//      `skuFamily`. If a caller bypasses the allowed list (e.g. via az CLI
//      override) the linkedServers resource will fail to create with a clear
//      Azure-side error.
//   - Once linked, the secondary becomes read-only. Failover requires
//      unlinking (deleting the linkedServer resource) and reconfiguring the
//      former secondary as the new primary — handled by Test-DRHealth's
//      recovery action, not here.
// =============================================================================

metadata dr = {
  mode: 'geoReplication'
  family: 'Microsoft.Cache/Redis'
  description: 'Premium Redis cache with geo-replication via Microsoft.Cache/redis/linkedServers. PREMIUM-TIER ONLY.'
}

@description('DR Redis cache name. 1–63 chars, alphanumeric + hyphens.')
@minLength(1)
@maxLength(63)
param drCacheName string

@description('Workload tag value (recorded in tags.draac-workload).')
param workload string

@description('Primary region (informational; recorded in metadata).')
param primaryRegion string

@description('DR region where the secondary cache is created.')
param drLocation string

@description('Resource name of the primary cache. Used to parent the linkedServers resource.')
param primaryCacheName string

@description('Resource id of the primary cache. Recorded in metadata; the linkedServers child resource is parented to it via name lookup.')
param primaryCacheId string

@description('Premium SKU only. Brief §R4.1: geo-replication is Premium-tier-only — fail loudly otherwise.')
@allowed([
  'Premium'
])
param skuName string = 'Premium'

@description('Premium-family identifier. Always P for geo-replication.')
@allowed([
  'P'
])
param skuFamily string = 'P'

@description('Capacity. Premium valid values: 1 (P1), 2 (P2), 3 (P3), 4 (P4), 5 (P5).')
@allowed([
  1
  2
  3
  4
  5
])
param skuCapacity int = 1

@description('Linked-server resource name (visible inside the primary). Defaults to the DR cache name.')
param linkedServerName string = drCacheName

resource drCache 'Microsoft.Cache/redis@2024-11-01' = {
  name: drCacheName
  location: drLocation
  properties: {
    sku: {
      name: skuName
      family: skuFamily
      capacity: skuCapacity
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
    'draac-dr-mode': 'geoReplication'
    'draac-dr-primary-region': primaryRegion
    'draac-dr-region': drLocation
  }
}

// Reference the existing primary cache so the linkedServers child resource
// can be parented to it. The primary cache must already exist in another
// resource group / region; this module does NOT create it.
resource primaryCache 'Microsoft.Cache/redis@2024-11-01' existing = {
  name: primaryCacheName
}

resource linkedServer 'Microsoft.Cache/redis/linkedServers@2024-11-01' = {
  parent: primaryCache
  name: linkedServerName
  properties: {
    linkedRedisCacheId: drCache.id
    linkedRedisCacheLocation: drLocation
    serverRole: 'Secondary'
  }
}

output drMetadata object = {
  mode: 'geoReplication'
  family: 'Microsoft.Cache/Redis'
  primaryRegion: primaryRegion
  drRegion: drLocation
  primaryCache: primaryCacheName
  drCache: drCacheName
  linkedServer: linkedServerName
  skuName: skuName
  skuFamily: skuFamily
  skuCapacity: skuCapacity
  premiumOnly: true
}

@description('Hostname of the DR cache (port 6380, TLS).')
output drEndpoint string = drCache.properties.hostName

@description('DR cache resource id.')
output drCacheId string = drCache.id

@description('LinkedServer resource id.')
output linkedServerId string = linkedServer.id

@description('Primary cache id (echoed for callers that pipe outputs into Test-DRHealth).')
output primaryCacheIdOut string = primaryCacheId
