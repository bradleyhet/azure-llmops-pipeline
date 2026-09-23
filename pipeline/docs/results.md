# Eval results

One row per eval run over HTTP against a deployed revision, appended by `eval-report`
(`pipeline/src/llmops_pipeline/report.py`) and committed by the workflow that ran it. The
nightly run covers the full tier against whichever dev revision holds traffic. Thresholds
are in `pipeline/src/llmops_pipeline/parse_results.py`.

| Date (UTC) | Environment | Revision | Tier | Cases | Pass rate | p50 ms | p95 ms | Cost per case USD | Run |
|---|---|---|---|---|---|---|---|---|---|
