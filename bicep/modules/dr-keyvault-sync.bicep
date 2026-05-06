// =============================================================================
// bicep/modules/dr-keyvault-sync.bicep
// Resource family : Microsoft.KeyVault/vaults (sync runbook for replicated KVs)
// Replication     : Active push from primary KV to DR KV via an Event Grid
//                   subscription on Microsoft.KeyVault.SecretNewVersionCreated
//                   that triggers a PowerShell-runtime Function App. The DR
//                   vault itself is provisioned by `dr-keyvault.bicep` (R4.1);
//                   this module wires the sync plane that closes the gap left
//                   by Key Vault being a regional service. Brief §R4.4.
//
// API refs (looked up 2026-05-06):
//   Microsoft.Web/serverfarms                          : 2025-03-01
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.web/serverfarms
//   Microsoft.Web/sites                                : 2025-03-01
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.web/sites
//   Microsoft.Storage/storageAccounts                  : 2025-08-01
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/storageaccounts
//   Microsoft.Insights/components                      : 2020-02-02
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/components
//   Microsoft.ManagedIdentity/userAssignedIdentities   : 2024-11-30
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/userassignedidentities
//   Microsoft.EventGrid/systemTopics                   : 2025-02-15
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.eventgrid/systemtopics
//   Microsoft.EventGrid/systemTopics/eventSubscriptions: 2025-02-15
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.eventgrid/systemtopics/eventsubscriptions
//   Microsoft.Authorization/roleAssignments            : 2022-04-01
//     https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
//
// What this module provisions in the PRIMARY region:
//   1. A user-assigned managed identity that owns the read+write surface.
//   2. A Linux Y1 (Consumption) App Service Plan (PowerShell 7.4 runtime).
//   3. A Storage account that backs the Function App (required by AzureWebJobs).
//   4. An Application Insights component for the Function App.
//   5. The Function App (kind: 'functionapp,linux') with a system-assigned MI
//      AND the user-assigned MI attached, configured with PowerShell 7.4 and
//      the DR_KEYVAULT_NAME app setting that the run.ps1 script reads.
//   6. Role assignments scoped to the two vaults:
//        - 'Key Vault Secrets User'    on the primary vault   -> read.
//        - 'Key Vault Secrets Officer' on the DR vault        -> write.
//   7. An Event Grid system topic on the primary vault (`Microsoft.KeyVault.vaults`)
//      and a child eventSubscription that filters
//      `Microsoft.KeyVault.SecretNewVersionCreated` and dispatches to the
//      Function App via the AzureFunction endpoint type.
//
// Notes:
//   - The DR vault is in a different region (DR), so its `id` is passed in;
//      the role assignment is created here as a child of the primary RG and
//      scopes itself to the DR vault id (`scope: drVaultExisting`). The DR
//      vault is referenced as `existing` to keep this module deployable to a
//      single resource group while still surfacing the role assignment.
//   - Storage account naming follows the project's deterministic pattern:
//      `st<workloadHash>kvsync` truncated to <=24 chars, lowercase alphanumeric.
//   - The Function App MI principal id is exposed as an output so downstream
//      callers can layer on additional role assignments (e.g. Storage Blob
//      Data Contributor) without re-reading the deployed resource.
//   - PSScriptAnalyzer / PSRule expectations: HTTPS-only, TLS 1.2+, public
//      network access on (Function App requires inbound from Event Grid IPs);
//      caller can layer Private Endpoints + access restrictions on top.
// =============================================================================

metadata dr = {
  mode: 'replicatedWithSyncRunbook'
  family: 'Microsoft.KeyVault/vaults'
  description: 'Push-replicate primary KV secret versions to a DR KV via an Event-Grid-triggered Azure Function (PowerShell 7.4).'
  loop: 'EventGrid -> FunctionApp -> Az.KeyVault Set-AzKeyVaultSecret on DR vault'
}

@description('Primary region for the Function App + storage + AppInsights. Must match the primary KV region.')
param location string

@description('Workload tag value (recorded in tags.draac-workload). Drives deterministic naming.')
@minLength(1)
@maxLength(20)
param workloadName string

@description('Name of the primary Key Vault (must already exist; referenced here for role assignment + system topic).')
param primaryKeyVaultName string

@description('Resource id of the primary Key Vault. Required to scope the Key Vault Secrets User role assignment.')
param primaryKeyVaultId string

@description('Resource id of the DR Key Vault (deployed in the DR region by dr-keyvault.bicep). Used to scope the Secrets Officer role assignment.')
param drKeyVaultId string

@description('Optional resource tags merged with the standard draac/draac-role/draac-workload tags.')
param tags object = {}

// ── Deterministic names ───────────────────────────────────────────────────────
// Suffix is derived from the primary KV id so re-runs against the same primary
// produce identical Function App, plan, storage, and identity names.
var nameSuffix = take(uniqueString(primaryKeyVaultId, 'kvsync'), 6)

var planName        = 'plan-${workloadName}-kvsync-${nameSuffix}'
var functionAppName = 'func-${workloadName}-kvsync-${nameSuffix}'
var miName          = 'id-${workloadName}-kvsync-${nameSuffix}'
var appInsightsName = 'appi-${workloadName}-kvsync-${nameSuffix}'
// Storage names: 3..24 chars, lowercase alphanumeric only. Strip dashes from the
// workload name and clamp.
var storageNameRaw  = toLower(replace('st${workloadName}kvsync${nameSuffix}', '-', ''))
var storageName     = take(storageNameRaw, 24)

var systemTopicName = 'evgt-${primaryKeyVaultName}-secrets'
var eventSubName    = 'evs-${workloadName}-kvsync'

// Built-in role definition ids (constants — Azure-wide).
var roleSecretsUser    = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
var roleSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' // Key Vault Secrets Officer

var standardTags = {
  draac: 'true'
  'draac-role': 'secrets-sync'
  'draac-workload': workloadName
}
var mergedTags = union(standardTags, tags)

// ── User-assigned managed identity ────────────────────────────────────────────
resource syncIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: miName
  location: location
  tags: mergedTags
}

// ── Storage backing the Function App ──────────────────────────────────────────
// BCP334 false positive: storageName is `st<workloadName>kvsync<6char>` after
// `replace('-','')` and `take(_,24)`. With workloadName @minLength(1), the
// minimum length is provably 14 chars (≥ Storage's 3-char floor) — Bicep's
// analyzer just can't see through the take/replace/string-interpolation chain.
#disable-next-line BCP334
resource storage 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    allowSharedKeyAccess: true // Functions consumption host requires the conn string
  }
  tags: mergedTags
}

// ── Application Insights ──────────────────────────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    IngestionMode: 'ApplicationInsights'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
  tags: mergedTags
}

// ── Linux consumption plan (Y1) ───────────────────────────────────────────────
// Y1 supports PowerShell 7.4 + Event Grid triggers. The brief explicitly
// permits this combination.
resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // reserved=true => Linux
  }
  tags: mergedTags
}

// ── Function App (PowerShell 7.4 on Linux) ────────────────────────────────────
resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${syncIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled' // Event Grid pushes events from Azure backbone
    keyVaultReferenceIdentity: syncIdentity.id
    siteConfig: {
      // Linux Function App: linuxFxVersion drives the runtime image. The
      // Windows-only `powerShellVersion` property is intentionally omitted to
      // avoid conflicting hints to the host. PowerShell 7.4 is the current
      // long-term supported runtime for Functions v4.
      linuxFxVersion: 'PowerShell|7.4'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      use32BitWorkerProcess: false
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: '7.4'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'PRIMARY_KEYVAULT_NAME'
          value: primaryKeyVaultName
        }
        {
          name: 'DR_KEYVAULT_NAME'
          value: last(split(drKeyVaultId, '/'))
        }
        {
          name: 'DRAAC_SYNC_USER_ASSIGNED_MI_CLIENT_ID'
          value: syncIdentity.properties.clientId
        }
      ]
    }
  }
  tags: mergedTags
}

// ── Existing-vault reference (primary, same RG) ───────────────────────────────
resource primaryVaultExisting 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: primaryKeyVaultName
}

// Parse <subId>/<rg> from the DR vault id so the cross-RG sub-module knows
// where to deploy. drKeyVaultId looks like:
//   /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>
var drIdSegments    = split(drKeyVaultId, '/')
var drSubscriptionId = drIdSegments[2]
var drResourceGroupName = drIdSegments[4]
var drVaultName     = last(drIdSegments)

// ── Role assignments ──────────────────────────────────────────────────────────
// Primary side: same RG as this module, declarable inline.
// guid() uses stable inputs so re-runs upsert the same assignment.
resource raPrimaryRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(primaryKeyVaultId, functionApp.id, roleSecretsUser)
  scope: primaryVaultExisting
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSecretsUser)
    description: 'DRaaC: Function App reads new secret versions from the primary vault.'
  }
}

// DR side: the DR vault lives in another RG, so the role assignment must be
// deployed to that RG. Bicep enforces this at compile time (BCP139). The
// sub-module scope: resourceGroup(<sub>, <rg>) target satisfies the rule.
module raDrWrite 'dr-keyvault-sync-drrole.bicep' = {
  name: 'dr-kvsync-drrole-${workloadName}'
  scope: resourceGroup(drSubscriptionId, drResourceGroupName)
  params: {
    drKeyVaultName:        drVaultName
    principalId:           functionApp.identity.principalId
    roleDefinitionGuid:    roleSecretsOfficer
    assignmentDescription: 'DRaaC: Function App writes secret versions to the DR vault.'
  }
}

// ── Event Grid system topic on the primary KV ─────────────────────────────────
// `Microsoft.KeyVault.vaults` is the Event Grid topicType for Key Vault. The
// system topic must live in the same region as the primary vault; we deploy it
// alongside the Function App in the primary region.
resource systemTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' = {
  name: systemTopicName
  location: location
  properties: {
    source: primaryKeyVaultId
    topicType: 'Microsoft.KeyVault.vaults'
  }
  tags: mergedTags
}

resource eventSub 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: systemTopic
  name: eventSubName
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        // Function endpoint: <functionAppId>/functions/Sync-KeyVaultSecrets
        // The Function name must match the folder under the wwwroot that hosts
        // run.ps1 + function.json (deployed out-of-band by the operator).
        resourceId: '${functionApp.id}/functions/Sync-KeyVaultSecrets'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.KeyVault.SecretNewVersionCreated'
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Resource id of the Function App that runs the sync.')
output functionAppId string = functionApp.id

@description('System-assigned MI principal id of the Function App. Useful for layering additional role assignments.')
output functionAppPrincipalId string = functionApp.identity.principalId

@description('Resource id of the App Insights component used by the Function App.')
output appInsightsId string = appInsights.id

@description('Resource id of the user-assigned managed identity attached to the Function App.')
output userAssignedIdentityId string = syncIdentity.id

@description('Client id of the user-assigned managed identity (used by run.ps1 to obtain a token).')
output userAssignedIdentityClientId string = syncIdentity.properties.clientId

@description('Resource id of the Event Grid system topic on the primary vault.')
output systemTopicId string = systemTopic.id

@description('Default-host hostname of the Function App. Operators can use this to test connectivity.')
output functionAppDefaultHost string = functionApp.properties.defaultHostName

@description('DR contract metadata (mirrors metadata.dr above; surfaced in compiled ARM for Test-DRHealth).')
output drMetadata object = {
  mode: 'replicatedWithSyncRunbook'
  family: 'Microsoft.KeyVault/vaults'
  primaryRegion: location
  primaryVault: primaryKeyVaultName
  drVaultId: drKeyVaultId
  functionApp: functionAppName
  systemTopic: systemTopicName
  eventSubscription: eventSubName
  trigger: 'Microsoft.KeyVault.SecretNewVersionCreated'
}
