// Corella assistant on Azure Container Apps: one resource group per environment.
//
//   az deployment group create -g rg-llmops-dev -f infra/main.bicep -p infra/dev.bicepparam
//
// First deploy of an environment runs with deployApp=false so the Key Vault exists before the
// one manual step that types the OpenRouter key into it:
//   az keyvault secret set --vault-name <kv> -n openrouter-api-key --value ...
// Every later deploy (including from the pipeline) uses deployApp=true.
targetScope = 'resourceGroup'

@description('Environment name, used in resource names and tags.')
@allowed(['dev', 'prod'])
param environmentName string

@description('Region for every resource. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Container App name. Also names the managed identity (id-<appName>).')
param appName string = 'corella-assistant'

@description('Full image reference, e.g. ghcr.io/bradleyhet/corella-assistant:<sha>. The pipeline reads the currently deployed image before each infra deploy so this never drifts.')
param image string

@description('OpenRouter model id the assistant uses as the system under test.')
param sutModel string = 'google/gemini-2.5-flash'

@description('Git sha baked into the running revision and returned by GET /version.')
param gitSha string = 'dev'

@description('Revision that receives 100 percent of traffic. Empty pins traffic to the latest revision, which is only right when a single revision exists; the pipeline always passes the current revision so a canary can start at zero.')
param activeRevisionName string = ''

@description('Suffix of the revision this deploy creates (the pipeline passes the short git sha). Empty lets Container Apps pick one.')
param revisionSuffix string = ''

@minValue(0)
param minReplicas int = 0

@minValue(1)
param maxReplicas int = 2

@description('Key Vault purge protection. Off for dev so the group can be deleted and recreated; on for prod.')
param purgeProtection bool = false

@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Log Analytics daily ingestion cap in GB, as a string such as 0.2. Normal traffic writes well under 1 MB a day; the cap only matters under a flood of requests.')
param logDailyQuotaGb string = '0.2'

@description('Monthly budget for the resource group, in the billing currency.')
@minValue(1)
param budgetAmount int = 20

@description('Address the budget alerts go to. Empty skips the budget; the pipeline passes the BUDGET_EMAIL environment variable so no address is committed.')
param budgetEmail string = ''

@description('Set false on the very first deploy of an environment, before the Key Vault secret exists.')
param deployApp bool = true

param tags object = {
  project: 'azure-llmops-pipeline'
  environment: environmentName
  managedBy: 'bicep'
}

// Key Vault names are global and at most 24 characters; a short hash of the group id keeps them unique.
var suffix = take(uniqueString(resourceGroup().id), 6)
var keyVaultName = 'kv-llmops-${environmentName}-${suffix}'
var secretName = 'openrouter-api-key'

module logging 'modules/logging.bicep' = {
  name: 'logging'
  params: {
    name: 'log-llmops-${environmentName}'
    location: location
    retentionDays: logRetentionDays
    dailyQuotaGb: logDailyQuotaGb
    tags: tags
  }
}

module budget 'modules/budget.bicep' = if (!empty(budgetEmail)) {
  name: 'budget'
  params: {
    name: 'budget-llmops-${environmentName}'
    amount: budgetAmount
    contactEmails: [budgetEmail]
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    name: 'id-${appName}'
    location: location
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    purgeProtection: purgeProtection
    readerPrincipalId: identity.outputs.principalId
    tags: tags
  }
}

module environment 'modules/environment.bicep' = {
  name: 'environment'
  params: {
    name: 'cae-llmops-${environmentName}'
    location: location
    workspaceName: logging.outputs.name
    tags: tags
  }
}

module app 'modules/app.bicep' = if (deployApp) {
  name: 'app'
  params: {
    name: appName
    location: location
    environmentId: environment.outputs.id
    identityId: identity.outputs.id
    keyVaultSecretUri: '${keyVault.outputs.vaultUri}secrets/${secretName}'
    image: image
    sutModel: sutModel
    gitSha: gitSha
    activeRevisionName: activeRevisionName
    revisionSuffix: revisionSuffix
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    tags: tags
  }
}

output keyVaultName string = keyVault.outputs.name
output secretName string = secretName
output identityPrincipalId string = identity.outputs.principalId
output environmentDefaultDomain string = environment.outputs.defaultDomain
output logAnalyticsWorkspaceId string = logging.outputs.id
output appFqdn string = deployApp ? app!.outputs.fqdn : ''
output appLatestRevision string = deployApp ? app!.outputs.latestRevisionName : ''
