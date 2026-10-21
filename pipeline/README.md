# pipeline

Python tooling the GitHub Actions pipeline runs; the assistant itself stays TypeScript.

| Command | Used by | Does |
|---|---|---|
| `verify-revision` | `verify-canary`, weekly full run | polls a revision's own URL until `/readyz` answers from the expected revision, then checks `/version` carries the expected git sha |
| `parse-results` | eval gate, canary, weekly full run | scores a promptfoo results file: pass rate, p50 and p95 latency, cost per case; writes the table to the step summary; non-zero exit on a threshold breach |
| `eval-report` | weekly full run | appends one row to `docs/results.md` |

```bash
uv sync --locked
uv run ruff check . && uv run ruff format --check .
uv run pytest
uv run parse-results ../results/smoke-http.json --label "local smoke"
```

Thresholds (defaults in `parse_results.py`): pass rate at or above 0.95, p50 latency at or
below 2500 ms, p95 latency at or below 10000 ms, mean cost per case at or below 0.01 USD.
Rows marked `known_failure: true` are left out of the pass rate and listed apart; one that
passes is flagged so the marker can be removed. p50 catches a slowdown across every case;
p95 is loose because over 30 cases it is the second-slowest call, so one slow upstream model
response would otherwise fail a deploy. `tests/fixtures/smoke.json` is a
trimmed copy of a real smoke-tier run so the scorer is tested without the network.
