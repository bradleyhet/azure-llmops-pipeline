#!/usr/bin/env bash
# Phase 0, Azure side. Idempotent. Run after `az login`.
#
# Creates: resource providers, resource group, Entra app registration with a
# service principal, one GitHub OIDC federated credential per environment, and
# Contributor + RBAC Administrator on the resource group only.
#
# Prints the values the GitHub side needs (scripts/phase0-github.sh reads them
# from the same az queries, so nothing has to be copied by hand).
set -euo pipefail
# Git Bash on Windows rewrites arguments starting with / into Windows paths,
# which mangles Azure resource ids such as /subscriptions/... Disable that.
export MSYS_NO_PATHCONV=1

REPO="${REPO:-bradleyhet/azure-llmops-pipeline}"
APP_NAME="${APP_NAME:-gh-azure-llmops-pipeline}"
RG="${RG:-rg-llmops-dev}"
LOCATION="${LOCATION:-australiaeast}"
ENVIRONMENTS="${ENVIRONMENTS:-dev prod}"

SUB_ID=$(az account show --query id -o tsv | tr -d '\r')
TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '\r')
echo "Subscription: $(az account show --query name -o tsv | tr -d '\r') ($SUB_ID)"

echo "== Resource providers"
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.KeyVault Microsoft.ManagedIdentity; do
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv | tr -d '\r')
  if [ "$state" != "Registered" ]; then
    echo "registering $ns"
    az provider register --namespace "$ns" --wait
  else
    echo "$ns already registered"
  fi
done

echo "== Resource group $RG in $LOCATION"
az group create --name "$RG" --location "$LOCATION" --output none

echo "== App registration $APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv | tr -d '\r')
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv | tr -d '\r')
  echo "created app $APP_ID"
else
  echo "app exists $APP_ID"
fi

SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv | tr -d '\r')
if [ -z "$SP_ID" ]; then
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv | tr -d '\r')
  echo "created service principal $SP_ID"
else
  echo "service principal exists $SP_ID"
fi

echo "== Federated credentials (GitHub OIDC, no client secret)"
# GitHub embeds the owner id and repo id in the OIDC subject claim, so the
# subject must read repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<env>.
# The ids never change even if the repo is renamed, which is the point.
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
OWNER_ID=$(gh api "users/$OWNER" --jq .id | tr -d '')
REPO_ID=$(gh api "repos/$REPO" --jq .id | tr -d '')
[ -n "$OWNER_ID" ] && [ -n "$REPO_ID" ] || { echo "could not resolve GitHub ids for $REPO; does the repo exist?" >&2; exit 1; }
for env in $ENVIRONMENTS; do
  name="github-$env"
  subject="repo:$OWNER@$OWNER_ID/$REPO_NAME@$REPO_ID:environment:$env"
  existing=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name'].subject" -o tsv | tr -d '\r')
  if [ -z "$existing" ]; then
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"description\": \"GitHub Actions, environment $env\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
    echo "created $name -> $subject"
  elif [ "$existing" != "$subject" ]; then
    az ad app federated-credential update --id "$APP_ID" --federated-credential-id "$name" --parameters "{
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"description\": \"GitHub Actions, environment $env\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
    echo "updated $name -> $subject (was $existing)"
  else
    echo "$name exists -> $existing"
  fi
done

echo "== Role assignments scoped to $RG only"
SCOPE="/subscriptions/$SUB_ID/resourceGroups/$RG"
for role in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create \
    --assignee-object-id "$SP_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" \
    --scope "$SCOPE" \
    --output none
  echo "$role on $SCOPE"
done

cat <<SUMMARY

Done. Values for GitHub (scripts/phase0-github.sh reads these itself):
  AZURE_CLIENT_ID       $APP_ID
  AZURE_TENANT_ID       $TENANT_ID
  AZURE_SUBSCRIPTION_ID $SUB_ID
  AZURE_RG              $RG
SUMMARY
