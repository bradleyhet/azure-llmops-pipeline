# Eval results

One row per eval run over HTTP against a deployed revision, appended by `eval-report`
(the two rollback-drill rows below were written by hand from the `verify-canary` job summaries)
(`pipeline/src/llmops_pipeline/report.py`) and committed by the workflow that ran it. The
nightly run covers the full tier against whichever dev revision holds traffic. Thresholds
are in `pipeline/src/llmops_pipeline/parse_results.py`.

| Date (UTC) | Environment | Revision | Tier | Cases | Pass rate | p50 ms | p95 ms | Cost per case USD | Run |
|---|---|---|---|---|---|---|---|---|---|
| 2026-09-23 11:08 | dev | `corella-assistant--82e9fb0` (rollback drill, bad `SUT_MODEL`; deactivated, traffic never left `--5083634`) | smoke | 30 | 20.0% (6/30, 24 provider errors) | 251 | 748 | 0.00000 | [35852147952](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35852147952) |
| 2026-09-23 11:19 | dev | `corella-assistant--5bb27e1` (revert of the drill; promoted) | smoke | 30 | 100.0% (30/30) | 1350 | 2835 | 0.00039 | [35853071238](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35853071238) |
