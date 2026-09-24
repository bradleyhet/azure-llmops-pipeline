using './main.bicep'

// The pipeline sets IMAGE, GIT_SHA, ACTIVE_REVISION and REVISION_SUFFIX in the job environment before deploying.
// Run by hand, the defaults deploy the main tag and let traffic follow the latest revision.
param environmentName = 'dev'
param image = readEnvironmentVariable('IMAGE', 'ghcr.io/bradleyhet/corella-assistant:main')
param gitSha = readEnvironmentVariable('GIT_SHA', 'dev')
param activeRevisionName = readEnvironmentVariable('ACTIVE_REVISION', '')
param revisionSuffix = readEnvironmentVariable('REVISION_SUFFIX', '')
param deployApp = bool(readEnvironmentVariable('DEPLOY_APP', 'true'))
param budgetEmail = readEnvironmentVariable('BUDGET_EMAIL', '')
param minReplicas = 0
param maxReplicas = 2
param purgeProtection = false
param logRetentionDays = 30
