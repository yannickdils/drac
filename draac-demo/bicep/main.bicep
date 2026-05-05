// Primary region Storage Account for DRaaC demo.
// Deployed by .github/workflows/deploy.yml on push to main.

@description('Primary region. Hardcoded for demo simplicity.')
param location string = 'westeurope'

@description('Resource name suffix. Deterministic per subscription.')
param nameSuffix string = take(uniqueString(subscription().id, 'draac-demo'), 6)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stdraacdemo${nameSuffix}'
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
    'draac-demo': 'true'
    'draac-role': 'primary'
  }
}

output storageAccountName string = storage.name
output storageAccountId string = storage.id
