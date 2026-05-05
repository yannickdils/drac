// Anchor workload — primary region.
// Minimal Storage Account that establishes the bicep/regions/{primary,dr}/ convention.
// Deployed by .github/workflows/dr-deploy.yml on push to main.

@description('Primary region for the anchor workload.')
param location string = 'westeurope'

@description('Resource name suffix. Deterministic per subscription.')
param nameSuffix string = take(uniqueString(subscription().id, 'draac-anchor'), 6)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stdraacanchor${nameSuffix}'
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
    'draac-role': 'primary'
    'draac-workload': 'anchor'
  }
}

output storageAccountName string = storage.name
output storageAccountId string = storage.id
