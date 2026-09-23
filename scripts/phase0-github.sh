#!/usr/bin/env bash
# Phase 0, GitHub side. Idempotent. Run after scripts/phase0-azure.sh and after
# the repo exists (gh repo create bradleyhet/azure-llmops-pipeline --public).
#
# Creates environments dev and prod (prod requires Brad's review), sets the
# Azure identity variables on each, and sets OPENROUTER_API_KEY as an
# environment secret for the eval jobs. The runtime copy of that key lives in
# Key Vault, seeded in Phase 2, never here.
set -euo pipefail

REPO="${REPO:-bradleyhet/azure-llmops-pipeline}"
APP_NAME="${APP_NAME:-gh-azure-llmops-pipeline}"
KEY_SOURCE="${KEY_SOURCE:-K:/MyGithub/LLM_Eval/.env}"

APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
[ -n "$APP_ID" ] || { echo "app $APP_NAME not found; run scripts/phase0-azure.sh first" >&2; exit 1; }

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  OPENROUTER_API_KEY=$(grep -E '^OPENROUTER_API_KEY=' "$KEY_SOURCE" | cut -d= -f2- | tr -d '\r')
fi
[ -n "$OPENROUTER_API_KEY" ] || { echo "OPENROUTER_API_KEY not set and not found in $KEY_SOURCE" >&2; exit 1; }

ME=$(gh api user --jq .id)

echo "== Environments"
gh api -X PUT "repos/$REPO/environments/dev" --silent
echo "dev"
gh api -X PUT "repos/$REPO/environments/prod" --silent \
  --input - <<JSON
{"reviewers":[{"type":"User","id":$ME}]}
JSON
echo "prod (required reviewer: $(gh api user --jq .login))"

echo "== Variables and secrets"
for env in dev prod; do
  gh variable set AZURE_CLIENT_ID       --repo "$REPO" --env "$env" --body "$APP_ID"
  gh variable set AZURE_TENANT_ID       --repo "$REPO" --env "$env" --body "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --env "$env" --body "$SUB_ID"
  gh variable set AZURE_RG              --repo "$REPO" --env "$env" --body "rg-llmops-$env"
  gh secret   set OPENROUTER_API_KEY    --repo "$REPO" --env "$env" --body "$OPENROUTER_API_KEY"
  echo "$env configured"
done

echo
echo "Note: prod points at rg-llmops-prod, which Phase 4 creates. Until then"
echo "only the dev login check will pass."
echo
echo "Verify: gh workflow run azure-login-check.yml -f environment=dev && sleep 5 && gh run watch"
