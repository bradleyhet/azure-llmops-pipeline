// Log Analytics workspace. Container Apps console and system logs land here as
// ContainerAppConsoleLogs_CL and ContainerAppSystemLogs_CL.
param name string
param location string
param retentionDays int
@description('Daily ingestion cap in GB, as a string because Bicep has no decimal literals. Ingestion stops for the rest of the UTC day once it is reached.')
param dailyQuotaGb string
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    workspaceCapping: {
      dailyQuotaGb: json(dailyQuotaGb)
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output id string = workspace.id
output name string = workspace.name
output customerId string = workspace.properties.customerId
