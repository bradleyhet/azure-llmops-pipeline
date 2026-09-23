// Key Vault with RBAC authorisation (no access policies). The OpenRouter key is written once,
// by hand, with `az keyvault secret set`; nothing in this repo or in GitHub ever holds it.
// The app's managed identity gets Key Vault Secrets User on the vault, which is the least role
// that can read a secret value and is what a Container Apps `keyVaultUrl` secret reference needs.
param name string
param location string
param purgeProtection bool
@description('Object id of the managed identity that may read secrets.')
param readerPrincipalId string
param tags object

// Built-in role: Key Vault Secrets User
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  // checkov:skip=CKV_AZURE_189: The consumption-plan Container Apps environment has no VNet, so the Key Vault reference is resolved over the public endpoint with RBAC and TLS. A private endpoint needs a VNet-integrated environment, out of scope for this build.
  // checkov:skip=CKV_AZURE_109: Same reason. The environment's outbound IPs are not stable enough to allow-list on the consumption plan, so defaultAction stays Allow and access is controlled by RBAC (one role assignment, one principal).
  // checkov:skip=CKV_AZURE_110: Purge protection is a parameter. On in prod.bicepparam; off in dev so rg-llmops-dev can be deleted and recreated without a 90-day wait.
  // checkov:skip=CKV_AZURE_42: Soft delete is on everywhere; recoverability beyond that follows the purge protection parameter above.
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Purge protection cannot be set to false explicitly; omit it to leave it off.
    enablePurgeProtection: purgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, readerPrincipalId, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = vault.name
output id string = vault.id
output vaultUri string = vault.properties.vaultUri
