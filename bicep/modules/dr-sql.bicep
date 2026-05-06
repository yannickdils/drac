// =============================================================================
// bicep/modules/dr-sql.bicep
// Resource family : Microsoft.Sql/servers/databases
// Replication     : Failover group (active geo-replication) with automatic
//                   failover policy. The DR companion provisions a partner
//                   server in the DR region and a failover group that ties the
//                   primary DB to the DR partner. Brief §R4.1.
//
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.sql/servers/databases (looked up 2026-05-06)
// API ref: https://learn.microsoft.com/en-us/azure/templates/microsoft.sql/servers/failovergroups (looked up 2026-05-06)
//
// What this module provisions in the DR region:
//   1. A partner SQL server (matches the primary's admin login + version).
//   2. A failover group on the primary server that lists the primary DB and
//      points the partner endpoint at the DR server.
//
// Notes:
//   - The primary server + database are NOT created by this module. Pass the
//      primary server resource id and database name in via parameters; the
//      module attaches a failover group as an extension of the primary.
//   - Caller must ensure the primary database SKU supports geo-replication
//      (S0 and below cannot enrol — the brief defers SKU validation to PSRule).
//   - The `metadata.dr` block at the top of this file is preserved verbatim
//      in the compiled ARM so downstream tooling (Test-DRHealth) can read the
//      replication contract from the deployed template.
// =============================================================================

metadata dr = {
  mode: 'failoverGroup'
  family: 'Microsoft.Sql/servers/databases'
  description: 'Active geo-replication via Azure SQL failover group with automatic failover policy.'
}

@description('DR region for the partner SQL server.')
param drLocation string

@description('Workload tag value (recorded in tags.draac-workload). Must match the primary workload.')
param workload string

@description('Resource name of the primary SQL server (e.g. sql-primary-abc).')
param primaryServerName string

@description('Resource id of the primary SQL server.')
param primaryServerId string

@description('Name of the primary database that should join the failover group.')
param primaryDatabaseName string

@description('Resource id of the primary database (used in failoverGroup.properties.databases).')
param primaryDatabaseId string

@description('Administrator login for the partner server. Match the primary or use a managed identity.')
param administratorLogin string

@description('Administrator login password for the partner server. Pass via secure parameter.')
@secure()
param administratorLoginPassword string

@description('Failover group name. Must be globally unique within Azure SQL.')
param failoverGroupName string = 'fg-${workload}-${uniqueString(primaryServerId)}'

@description('Partner (DR) server name. Will be created in the DR region.')
param drServerName string = '${primaryServerName}-dr'

@description('SQL engine version. Default 12.0 matches modern Azure SQL.')
param sqlVersion string = '12.0'

@description('Grace period (minutes) before automatic failover is attempted. Brief §R4.1: automatic failover policy.')
@minValue(1)
param failoverGracePeriodMinutes int = 60

@description('Read-only endpoint failover policy. Disabled keeps reads on the primary unless explicitly redirected.')
@allowed([
  'Enabled'
  'Disabled'
])
param readOnlyFailoverPolicy string = 'Disabled'

@description('Primary region (informational; recorded in metadata.dr).')
param primaryRegion string

resource drServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: drServerName
  location: drLocation
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    version: sqlVersion
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
  }
}

// Failover group is parented to the PRIMARY server (Azure SQL convention) and
// references the partner server via partnerServers[].id. It is therefore
// declared as an existing-resource reference so this module can be deployed
// against the primary server's resource group with `existing` semantics.
resource primaryServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: primaryServerName
}

resource failoverGroup 'Microsoft.Sql/servers/failoverGroups@2023-08-01' = {
  parent: primaryServer
  name: failoverGroupName
  properties: {
    readWriteEndpoint: {
      failoverPolicy: 'Automatic'
      failoverWithDataLossGracePeriodMinutes: failoverGracePeriodMinutes
    }
    readOnlyEndpoint: {
      failoverPolicy: readOnlyFailoverPolicy
    }
    partnerServers: [
      {
        id: drServer.id
      }
    ]
    databases: [
      primaryDatabaseId
    ]
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': workload
    // Mode/region context recorded as a tag (Bicep does not allow `metadata`
    // on resource declarations — the metadata.dr block on this module's
    // exported "metadata.dr" output makes the contract programmatically
    // discoverable from compiled ARM).
    'draac-dr-mode': 'failoverGroup'
    'draac-dr-primary-region': primaryRegion
    'draac-dr-region': drLocation
    'draac-dr-primary-database': primaryDatabaseName
  }
}

// metadata.dr — replication-mode contract for downstream tooling
// (check-dr-coverage, Test-DRHealth). Surfaced as an output so it lands in
// the compiled ARM and can be inspected via `az deployment group show`.
output drMetadata object = {
  mode: 'failoverGroup'
  family: 'Microsoft.Sql/servers/databases'
  primaryRegion: primaryRegion
  drRegion: drLocation
  primaryServer: primaryServerName
  drServer: drServerName
  failoverGroup: failoverGroupName
  failoverGracePeriodMinutes: failoverGracePeriodMinutes
}

@description('Read-write endpoint for the failover group (clients connect here; Azure routes to the active server).')
output drEndpoint string = '${failoverGroupName}${environment().suffixes.sqlServerHostname}'

@description('Read-only endpoint for the failover group (used when readOnlyFailoverPolicy=Enabled).')
output drReadOnlyEndpoint string = '${failoverGroupName}.secondary${environment().suffixes.sqlServerHostname}'

@description('Resource id of the partner server in the DR region.')
output drServerId string = drServer.id

@description('Resource id of the failover group.')
output failoverGroupId string = failoverGroup.id
