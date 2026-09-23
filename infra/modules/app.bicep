// The Container App. Multiple-revision mode so the pipeline can add a revision at zero traffic,
// score it, then move traffic. The OpenRouter key is a Key Vault reference resolved by the
// user-assigned identity: `az containerapp show` prints the vault URL, never the value.
param name string
param location string
param environmentId string
param identityId string
@description('Full URI of the secret, e.g. https://kv-....vault.azure.net/secrets/openrouter-api-key')
param keyVaultSecretUri string
param image string
param sutModel string
param gitSha string
param activeRevisionName string
@description('Suffix for the revision this template creates, e.g. the short git sha; the revision is named <app>--<suffix>. Empty lets Container Apps generate one.')
param revisionSuffix string = ''
param minReplicas int
param maxReplicas int
param tags object

var port = 8080
var secretName = 'openrouter-api-key'

// With one revision (first deploy) traffic follows the latest. Once the pipeline manages
// revisions it pins traffic to a named revision so a new one starts at zero.
var latestTraffic = [
  {
    latestRevision: true
    weight: 100
  }
]
var pinnedTraffic = [
  {
    revisionName: activeRevisionName
    weight: 100
  }
]
var traffic = empty(activeRevisionName) ? latestTraffic : pinnedTraffic

// The pipeline names each revision after the short git sha so the canary URL is predictable.
var baseTemplate = {
  containers: [
    {
      name: 'assistant'
      image: image
      resources: {
        cpu: json('0.25')
        memory: '0.5Gi'
      }
      env: [
        {
          name: 'OPENROUTER_API_KEY'
          secretRef: secretName
        }
        {
          name: 'SUT_MODEL'
          value: sutModel
        }
        {
          name: 'GIT_SHA'
          value: gitSha
        }
        {
          name: 'PORT'
          value: string(port)
        }
      ]
      probes: [
        {
          type: 'Startup'
          httpGet: {
            path: '/healthz'
            port: port
          }
          initialDelaySeconds: 2
          periodSeconds: 3
          failureThreshold: 10
        }
        {
          type: 'Liveness'
          httpGet: {
            path: '/healthz'
            port: port
          }
          periodSeconds: 10
          failureThreshold: 3
        }
        {
          type: 'Readiness'
          httpGet: {
            path: '/readyz'
            port: port
          }
          periodSeconds: 5
          failureThreshold: 3
        }
      ]
    }
  ]
  scale: {
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    rules: [
      {
        name: 'http-concurrency'
        http: {
          metadata: {
            concurrentRequests: '20'
          }
        }
      }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Multiple'
      ingress: {
        external: true
        targetPort: port
        transport: 'auto'
        allowInsecure: false
        traffic: traffic
      }
      secrets: [
        {
          name: secretName
          keyVaultUrl: keyVaultSecretUri
          identity: identityId
        }
      ]
    }
    template: union(baseTemplate, empty(revisionSuffix) ? {} : { revisionSuffix: revisionSuffix })
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output latestRevisionName string = app.properties.latestRevisionName
output id string = app.id
