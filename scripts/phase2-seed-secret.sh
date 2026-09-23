#!/usr/bin/env bash
# Phase 2, the one manual step: put the OpenRouter key into the environment's Key Vault.
#
#   bash scripts/phase2-seed-secret.sh            # dev
#   RG=rg-llmops-prod bash scripts/phase2-seed-secret.sh
#
# Grants the signed-in user Key Vault Secrets Officer on the vault (RBAC mode means even the
# subscription owner has no data-plane rights by default), writes the secret, and verifies it
# by id only. The value is read from KEY_SOURCE (default: the LLM_Eval .env) or the
# OPENROUTER_API_KEY environment variable, and is never printed.
set -euo pipefail
export MSYS_NO_PATHCONV=1

RG="${RG:-rg-llmops-dev}"
SECRET_NAME="${SECRET_NAME:-openrouter-api-key}"
KEY_SOURCE="${KEY_SOURCE:-K:/MyGithub/LLM_Eval/.env}"

KV=$(az keyvault list -g "$RG" --query '[0].name' -o tsv | tr -d '\r')
[ -n "$KV" ] || { echo "no Key Vault in $RG; deploy infra/main.bicep first" >&2; exit 1; }
KV_ID=$(az keyvault show -n "$KV" --query id -o tsv | tr -d '\r')
ME=$(az ad signed-in-user show --query id -o tsv | tr -d '\r')

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  OPENROUTER_API_KEY=$(grep -E '^OPENROUTER_API_KEY=' "$KEY_SOURCE" | cut -d= -f2- | tr -d '\r')
fi
[ -n "$OPENROUTER_API_KEY" ] || { echo "OPENROUTER_API_KEY not set and not found in $KEY_SOURCE" >&2; exit 1; }

echo "== Key Vault Secrets Officer for the signed-in user on $KV"
az role assignment create \
  --assignee-object-id "$ME" \
  --assignee-principal-type User \
  --role "Key Vault Secrets Officer" \
  --scope "$KV_ID" \
  --output none
# RBAC propagation to the data plane can lag by up to a minute or two.
for attempt in $(seq 1 12); do
  if az keyvault secret list --vault-name "$KV" --output none 2>/dev/null; then break; fi
  echo "waiting for role propagation ($attempt)"; sleep 10
done

echo "== Writing $SECRET_NAME"
az keyvault secret set --vault-name "$KV" --name "$SECRET_NAME" --value "$OPENROUTER_API_KEY" --query id -o tsv | tr -d '\r'

echo "== Verify (id only)"
az keyvault secret show --vault-name "$KV" --name "$SECRET_NAME" --query '{id:id, enabled:attributes.enabled, updated:attributes.updated}' -o table
