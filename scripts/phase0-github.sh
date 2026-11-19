#!/usr/bin/env bash
# Phase 0, GitHub side. Idempotent. Run after scripts/phase0-azure.sh and after
# the repo exists (gh repo create bradleyhet/azure-llmops-pipeline --public).
#
# Creates environments dev and prod (prod requires Brad's review) and sets on
# each the AZURE_RG variable plus four or five secrets: the three Azure
# identifiers, OPENROUTER_API_KEY for the eval jobs and, when BUDGET_EMAIL is
# set in the shell, the budget alert address. The identifiers are not
# credentials, but GitHub prints variables in run logs and masks secrets, and
# the logs of a public repo are public. The runtime copy of the OpenRouter key
# lives in Key Vault, seeded in Phase 2, never here.
set -euo pipefail
# Git Bash on Windows rewrites arguments starting with / into Windows paths,
# which mangles Azure resource ids such as /subscriptions/... Disable that.
export MSYS_NO_PATHCONV=1

REPO="${REPO:-bradleyhet/azure-llmops-pipeline}"
APP_NAME="${APP_NAME:-gh-azure-llmops-pipeline}"
KEY_SOURCE="${KEY_SOURCE:-K:/MyGithub/LLM_Eval/.env}"

APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv | tr -d '\r')
SUB_ID=$(az account show --query id -o tsv | tr -d '\r')
TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '\r')
[ -n "$APP_ID" ] || { echo "app $APP_NAME not found; run scripts/phase0-azure.sh first" >&2; exit 1; }

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  OPENROUTER_API_KEY=$(grep -E '^OPENROUTER_API_KEY=' "$KEY_SOURCE" | cut -d= -f2- | tr -d '\r')
fi
[ -n "$OPENROUTER_API_KEY" ] || { echo "OPENROUTER_API_KEY not set and not found in $KEY_SOURCE" >&2; exit 1; }

ME=$(gh api user --jq .id | tr -d '\r')

echo "== Environments"
gh api -X PUT "repos/$REPO/environments/dev" --silent
echo "dev"
# Required reviewers are a deployment protection rule. GitHub offers them on
# public repos for every plan, but on private repos only with Pro or Team, so
# fall back to a plain environment and say so.
if gh api -X PUT "repos/$REPO/environments/prod" --silent --input - <<JSON 2>/dev/null
{"reviewers":[{"type":"User","id":$ME}]}
JSON
then
  echo "prod (required reviewer: $(gh api user --jq .login | tr -d '\r'))"
else
  gh api -X PUT "repos/$REPO/environments/prod" --silent
  echo "prod (no required reviewer: protection rules need a public repo or GitHub Pro on this plan)"
fi

echo "== Variables and secrets"
for env in dev prod; do
  gh variable set AZURE_RG              --repo "$REPO" --env "$env" --body "rg-llmops-$env"
  gh secret   set AZURE_CLIENT_ID       --repo "$REPO" --env "$env" --body "$APP_ID"
  gh secret   set AZURE_TENANT_ID       --repo "$REPO" --env "$env" --body "$TENANT_ID"
  gh secret   set AZURE_SUBSCRIPTION_ID --repo "$REPO" --env "$env" --body "$SUB_ID"
  gh secret   set OPENROUTER_API_KEY    --repo "$REPO" --env "$env" --body "$OPENROUTER_API_KEY"
  if [ -n "${BUDGET_EMAIL:-}" ]; then
    gh secret set BUDGET_EMAIL          --repo "$REPO" --env "$env" --body "$BUDGET_EMAIL"
  else
    echo "BUDGET_EMAIL not set in the shell: $env gets no budget secret, so the deploy skips the budget"
  fi
  echo "$env configured"
done

echo
echo "Note: prod points at rg-llmops-prod, which Phase 4 creates. Until then"
echo "only the dev login check will pass."
echo
echo "Verify: gh workflow run azure-login-check.yml -f environment=dev && sleep 5 && gh run watch"
