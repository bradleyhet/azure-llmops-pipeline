# pipeline

Python tooling the GitHub Actions pipeline runs; the assistant itself stays TypeScript.

| Command | Used by | Does |
|---|---|---|
| `verify-revision` | `verify-canary`, nightly | polls a revision's own URL until `/readyz` answers from the expected revision, then checks `/version` carries the expected git sha |
| `parse-results` | eval gate, canary, nightly | scores a promptfoo results file: pass rate, p50 and p95 latency, cost per case; writes the table to the step summary; non-zero exit on a threshold breach |
| `eval-report` | nightly | appends one row to `docs/results.md` |

```bash
uv sync --locked
uv run ruff check . && uv run ruff format --check .
uv run pytest
uv run parse-results ../results/smoke-http.json --label "local smoke"
```

Thresholds (defaults in `parse_results.py`): pass rate at or above 0.95, p95 latency at or
below 4000 ms, mean cost per case at or below 0.01 USD. `tests/fixtures/smoke.json` is a
trimmed copy of a real smoke-tier run so the scorer is tested without the network.
