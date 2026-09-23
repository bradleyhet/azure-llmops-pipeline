// User-assigned managed identity the Container App runs as. It is the only principal that
// can read the OpenRouter secret from Key Vault (see keyvault.bicep).
param name string
param location string
param tags object

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

output id string = identity.id
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
