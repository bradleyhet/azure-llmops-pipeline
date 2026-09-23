using './main.bicep'

// Prod: purge protection on, one more replica, longer log retention. Same template as dev.
param environmentName = 'prod'
param image = readEnvironmentVariable('IMAGE', 'ghcr.io/bradleyhet/corella-assistant:main')
param gitSha = readEnvironmentVariable('GIT_SHA', 'dev')
param activeRevisionName = readEnvironmentVariable('ACTIVE_REVISION', '')
param deployApp = bool(readEnvironmentVariable('DEPLOY_APP', 'true'))
param minReplicas = 0
param maxReplicas = 3
param purgeProtection = true
param logRetentionDays = 90
