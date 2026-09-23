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

REPO="${REPO:-bradleyhet/azure-llmops-pipeline}"
APP_NAME="${APP_NAME:-gh-azure-llmops-pipeline}"
RG="${RG:-rg-llmops-dev}"
LOCATION="${LOCATION:-australiaeast}"
ENVIRONMENTS="${ENVIRONMENTS:-dev prod}"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Subscription: $(az account show --query name -o tsv) ($SUB_ID)"

echo "== Resource providers"
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.KeyVault Microsoft.ManagedIdentity; do
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv)
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
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "created app $APP_ID"
else
  echo "app exists $APP_ID"
fi

SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)
if [ -z "$SP_ID" ]; then
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo "created service principal $SP_ID"
else
  echo "service principal exists $SP_ID"
fi

echo "== Federated credentials (GitHub OIDC, no client secret)"
for env in $ENVIRONMENTS; do
  name="github-$env"
  subject="repo:$REPO:environment:$env"
  existing=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='$name'].subject" -o tsv)
  if [ -z "$existing" ]; then
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"description\": \"GitHub Actions, environment $env\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
    echo "created $name -> $subject"
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
