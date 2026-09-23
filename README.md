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
| 3. Reusable pipeline, scans, scored canary | Done. Push to `main` produced canary `corella-assistant--323fcec` at 0 percent, verified 30 of 30 over HTTP, promoted to 100. |
| 4. Prod environment and rollback drill | Next |
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

## Pipeline

`.github/workflows/reusable-ai-service.yml` is one `workflow_call` workflow. `assistant-dev.yml`
runs it on every pull request (no deploy) and on every push to `main` (deploy to
`rg-llmops-dev`); `assistant-prod.yml` runs the same file on a `v*` tag against
`rg-llmops-prod`. `nightly.yml` runs the full tier over HTTP against dev and appends a row to
[`docs/results.md`](docs/results.md). The Python side lives in [`pipeline/`](pipeline/README.md).

| Stage | What runs | Fails on |
|---|---|---|
| quality | eslint, tsc, vitest (93 tests); ruff and pytest over `pipeline/` (16 tests) | anything |
| secrets-scan | gitleaks over the history; `.gitleaks.toml` allowlists the fake keys the output-guard tests feed to `filterOutput` | any leak |
| codeql | JavaScript/TypeScript and Python | runs once the repository is public (private repositories need Advanced Security) |
| dependency-audit | `bun audit` at high; `pip-audit` over the uv lockfile | any high or critical with a fix; two `extract-zip` advisories are ignored by id (dev-only, reached through promptfoo, no fixed release, not in the image) |
| iac-scan | Checkov on `infra/`, bicep framework | any failed check |
| eval-gate | promptfoo smoke tier in-process, 30 cases, responses cached on config, evals, src and corpus | pass rate under 0.95, p95 over 4 s, cost per case over 0.01 USD |
| build | buildx to `ghcr.io/bradleyhet/corella-assistant:<sha>` with SBOM and provenance attestations; Trivy HIGH and CRITICAL with `--ignore-unfixed`; the `:main` tag is applied only after the scan | any fixable HIGH or CRITICAL |
| deploy | `az deployment group what-if`, then `create` with the new image, `revisionSuffix` set to the short sha and traffic pinned to the revision that already holds it, so the new revision starts at 0 percent | deployment error, or a revision not named `corella-assistant--<sha>` |
| verify-canary | `verify-revision` polls `https://corella-assistant--<sha>.<env>/readyz` and checks `/version`; promptfoo smoke tier over HTTP at that URL; `parse-results` applies the same thresholds as the gate and writes the table to the job summary | thresholds |
| promote | `az containerapp ingress traffic set <new>=100`, previous revision deactivated, app FQDN checked to answer from the new revision | |
| rollback | on a verify failure the new revision is deactivated; traffic was never moved | |

Azure login is `azure/login` with the federated credential. `gh secret list` shows only
`OPENROUTER_API_KEY`, which the eval jobs need on the runner.

### Phase 3 results (2026-09-23, [run 35849205060](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35849205060))

| Check | Result |
|---|---|
| Eval gate, in-process | 30 of 30; p50 0.78 s, p95 1.82 s; 0.00039 USD per case |
| Canary `corella-assistant--323fcec` on its own URL | 30 of 30; p50 1.36 s, p95 2.61 s; 0.00039 USD per case, 0.0116 USD for the tier |
| Traffic while it was verified | `corella-assistant--nvixkmu` 100, canary 0 |
| After promote | one active revision, `corella-assistant--323fcec` at 100; the app FQDN reports it from `/readyz` |
| Trivy on the image | 0 HIGH or CRITICAL with a fix |
| Checkov on `infra/` | 1 passed, 0 failed, 4 skipped with the reason beside each skip |
| gitleaks | no leaks across 13 commits |
| Push to promoted, wall clock | 8 min 34 s |
| Azure credential stored in GitHub | none |

Three things it took to get here, kept because they are what an interviewer asks about:

- GHCR refused the workflow token with `permission_denied: write_package` until the package
  granted the repository the Write role under Manage Actions access. A package first pushed
  with a personal token is not linked to any repository.
- A skipped job (CodeQL on a private repository) makes GitHub's implicit `success()` false
  for every job downstream of it, so every job below `build` names the `needs.*.result` it
  wants and adds `!cancelled()`.
- gitleaks scans only the pushed commits on `push` but the whole history on
  `workflow_dispatch`, which is how it found the fake keys in the guardrail tests.

## What this does not show

No model training, no Azure Machine Learning, no AKS, no Azure DevOps. Container Apps is
not Kubernetes. The corpus and customers are fictional.
