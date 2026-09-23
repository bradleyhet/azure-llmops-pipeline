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

Status: Phase 0 (Azure foundation and identity) in progress.
