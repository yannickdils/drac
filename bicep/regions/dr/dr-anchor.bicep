// Anchor workload — DR region. AUTO-GENERATED COMPANION TO primary/anchor.bicep.
// Re-run scripts/review/check-dr-coverage.ps1 to refresh after primary changes.

@description('DR region for the anchor workload.')
param location string = 'northeurope'

@description('Resource name suffix. Deterministic per subscription.')
param nameSuffix string = take(uniqueString(subscription().id, 'draac-anchor'), 6)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'drstdraacanchor${nameSuffix}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
  tags: {
    draac: 'true'
    'draac-role': 'dr'
    'draac-workload': 'anchor'
  }
}

output storageAccountName string = storage.name
output storageAccountId string = storage.id
