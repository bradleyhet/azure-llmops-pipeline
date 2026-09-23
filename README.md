# Azure LLMOps Pipeline

A reusable GitHub Actions pipeline that ships a TypeScript RAG assistant
(the Corella Bank assistant from [llm-eval-harness](https://github.com/bradleyhet/llm-eval-harness))
to Azure Container Apps, with:

- secrets in Azure Key Vault, read by a user-assigned managed identity
- GitHub-to-Entra OIDC federation, so no Azure credential is stored in GitHub
- automated security scans on every push (gitleaks, CodeQL, dependency audit, Checkov, Trivy)
- a promptfoo evaluation gate before any image is built
- a canary revision at zero traffic, scored by a Python verifier, promoted only on threshold pass
- one `workflow_call` workflow consumed by both a dev and a prod caller

## Status

| Phase | State |
|---|---|
| 0. Azure foundation and identity | Done. Federated login proven by `azure-login-check.yml`. |
| 1. HTTP service and container | Done. See below. |
| 2. Infrastructure as code (Bicep) | Done. Dev environment live, key resolved from Key Vault by managed identity. |
| 3. Reusable pipeline, scans, scored canary | Next |
| 4. Prod environment and rollback drill | |
| 5. Observability and README | |

## The service

`src/server.ts` serves the assistant on `0.0.0.0:8080`:

| Route | Purpose |
|---|---|
| `GET /healthz` | liveness, always 200 while the process is up |
| `GET /readyz` | 200 once the corpus is indexed and a model credential exists, else 503 |
| `GET /version` | git sha, build time, Container Apps revision, model |
| `POST /ask` | `{ query, customerId, history? }` to a grounded answer with context, retrieval hits, tool trace, guardrail outcome, tokens, cost and latency |

Every request writes one JSON line to stdout for Log Analytics. The query text is never
logged; the line carries status, latency, cost, tokens, model, guardrail outcome and the
revision that served it.

The same test rows run two ways:

- `promptfooconfig.yaml` calls `answer()` in-process. This is the pull-request gate; no
  deployment needed.
- `promptfooconfig.http.yaml` posts to `${ASSISTANT_URL}/ask`. This is what the canary
  verifier and the nightly run use. `src/eval/http-transform.ts` reshapes the wire body into
  the in-process provider's output, and a unit test asserts the two agree field for field.

### Run it locally

```bash
bun install
bun run test            # 93 unit tests, no network
cp .env.example .env    # add your OpenRouter key
bun run start           # http://localhost:8080

curl -s -X POST localhost:8080/ask -H 'content-type: application/json' \
  -d '{"query":"What is the card replacement fee?","customerId":"cust_001"}'

docker build -t corella-assistant .
docker run -p 8080:8080 -e OPENROUTER_API_KEY=$OPENROUTER_API_KEY corella-assistant

ASSISTANT_URL=http://localhost:8080 bun run eval:smoke:http
```

### Phase 1 results (2026-09-23, local container)

| Check | Result |
|---|---|
| Unit tests | 93 passed in 6 files |
| Smoke tier over HTTP | 30 of 30 passed |
| Latency p50 / p95 | 1.28 s / 2.60 s |
| Cost per case (system under test) | 0.00038 USD, 0.0115 USD for the tier |
| Image size | 79.7 MB (`oven/bun:1-slim` pinned by digest, Debian packages upgraded, non-root) |
| Trivy, HIGH and CRITICAL with a fix available | 0 |
| Trivy, HIGH and CRITICAL with no upstream fix | 43, all in Debian base packages; the pipeline runs Trivy with `--ignore-unfixed` |

## Infrastructure

`infra/main.bicep` (resource-group scope) deploys, per environment:

| Module | Resource | Notes |
|---|---|---|
| `logging` | Log Analytics workspace | PerGB2018, 30 days dev, 90 prod |
| `identity` | User-assigned managed identity | the only principal that can read the secret |
| `keyvault` | Key Vault, RBAC authorisation | soft delete on; purge protection is a parameter; Secrets User role bound to the identity inside the template |
| `environment` | Container Apps managed environment | consumption plan, logs to the workspace |
| `app` | Container App, Multiple revisions mode | ingress 8080, scale 0 to 2, probes on `/healthz` and `/readyz`, secret is a `keyVaultUrl` reference resolved by the identity |

The OpenRouter key is written to the vault once by hand (`scripts/phase2-seed-secret.sh`).
The app definition stores only the vault URL:

```json
{ "name": "openrouter-api-key",
  "keyVaultUrl": "https://kv-llmops-dev-m3ucqv.vault.azure.net/secrets/openrouter-api-key",
  "identity": ".../userAssignedIdentities/id-corella-assistant" }
```

### Phase 2 results (2026-09-23, rg-llmops-dev)

| Check | Result |
|---|---|
| `az deployment group what-if` | four creates, as designed |
| Checkov on `infra/` | 0 failed, 4 suppressed on the vault with reasons in the file |
| `GET /readyz` on the Azure FQDN | 200, revision `corella-assistant--nvixkmu` |
| `POST /ask` from the internet | grounded answer, 2.1 s, 0.0005 USD |
| Key value anywhere in `az containerapp show` output | no |
| Container console log | one JSON line per request, no query text |

## What this does not show

No model training, no Azure Machine Learning, no AKS, no Azure DevOps. Container Apps is
not Kubernetes. The corpus and customers are fictional.
