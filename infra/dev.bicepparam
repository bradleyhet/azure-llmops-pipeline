using './main.bicep'

// The pipeline sets IMAGE, GIT_SHA, ACTIVE_REVISION and REVISION_SUFFIX in the job environment before deploying.
// Run by hand, the defaults deploy the main tag and let traffic follow the latest revision.
param environmentName = 'dev'
param image = readEnvironmentVariable('IMAGE', 'ghcr.io/bradleyhet/corella-assistant:main')
param gitSha = readEnvironmentVariable('GIT_SHA', 'dev')
param activeRevisionName = readEnvironmentVariable('ACTIVE_REVISION', '')
param revisionSuffix = readEnvironmentVariable('REVISION_SUFFIX', '')
param deployApp = bool(readEnvironmentVariable('DEPLOY_APP', 'true'))
param minReplicas = 0
param maxReplicas = 2
param purgeProtection = false
param logRetentionDays = 30
// Rollback drill: a model id OpenRouter does not serve. The in-process eval gate does not read
// this file, so the image builds and the canary deploys; the HTTP verify must fail and traffic
// must stay on the current revision. Reverted by the next commit.
param sutModel = 'google/gemini-2.5-flash-drill-does-not-exist'
