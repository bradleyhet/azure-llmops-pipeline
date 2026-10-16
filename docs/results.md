# Eval results

One row per eval run over HTTP against a deployed revision, appended by `eval-report`
(the two rollback-drill rows and the first prod row below were written by hand from the `verify-canary` job summaries)
(`pipeline/src/llmops_pipeline/report.py`) and committed by the workflow that ran it. The
nightly run covers the full tier against whichever dev revision holds traffic. Thresholds
are in `pipeline/src/llmops_pipeline/parse_results.py`.

| Date (UTC) | Environment | Revision | Tier | Cases | Pass rate | p50 ms | p95 ms | Cost per case USD | Run |
|---|---|---|---|---|---|---|---|---|---|
| 2026-09-23 11:08 | dev | `corella-assistant--82e9fb0` (rollback drill, bad `SUT_MODEL`; deactivated, traffic never left `--5083634`) | smoke | 30 | 20.0% (6/30, 24 provider errors) | 251 | 748 | 0.00000 | [35852147952](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35852147952) |
| 2026-09-23 11:19 | dev | `corella-assistant--5bb27e1` (revert of the drill; promoted) | smoke | 30 | 100.0% (30/30) | 1350 | 2835 | 0.00039 | [35853071238](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35853071238) |
| 2026-09-23 21:16 | dev | corella-assistant--5bb27e1 | full | 95 | 93.7% (89/95) | 1409 | 2684 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35920803635) |
| 2026-09-24 03:19 | prod | `corella-assistant--cdd893a` (first prod release, tag `v0.1.0`; promoted) | smoke | 30 | 100.0% (30/30) | 1664 | 3150 | 0.00039 | [35950368110](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35950368110) |
| 2026-09-24 04:00 | dev | corella-assistant--aee1cc0 | full | 95 | 51.6% (47/91, 4 known excluded) | 232 | 2337 | 0.00017 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/35953524490) |
| 2026-09-24 21:17 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1366 | 2892 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36060053108) |
| 2026-09-25 21:15 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1481 | 2750 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36190097152) |
| 2026-09-26 20:47 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1352 | 3385 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36270501983) |
| 2026-09-27 21:02 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1387 | 2584 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36350004870) |
| 2026-09-28 23:02 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1438 | 2601 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36495504121) |
| 2026-09-29 22:02 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1423 | 2619 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36636629236) |
| 2026-09-30 21:59 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1421 | 2723 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36782565433) |
| 2026-10-01 22:29 | dev | corella-assistant--97220c2 | full | 95 | 98.9% (90/91, 4 known excluded) | 1417 | 2635 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/36934858925) |
| 2026-10-02 21:58 | dev | corella-assistant--97220c2 | full | 95 | 100.0% (91/91, 4 known excluded) | 1413 | 2647 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37069490224) |
| 2026-10-03 20:43 | dev | corella-assistant--97220c2 | full | 95 | 98.9% (90/91, 4 known excluded) | 1365 | 2623 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37152370986) |
| 2026-10-04 21:00 | dev | corella-assistant--97220c2 | full | 95 | 98.9% (90/91, 4 known excluded) | 1571 | 2886 | 0.00039 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37234065937) |
| 2026-10-05 23:53 | dev | corella-assistant--97220c2 | full | 95 | 98.9% (90/91, 4 known excluded) | 1642 | 3066 | 0.00040 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37390599261) |
| 2026-10-06 22:28 | dev | corella-assistant--97220c2 | full | 95 | 68.1% (62/91, 4 known excluded) | 1271 | 2504 | 0.00027 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37540401688) |
| 2026-10-07 22:52 | dev | corella-assistant--97220c2 | full | 95 | 33.0% (30/91, 4 known excluded) | 432 | 3148 | 0.00010 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37698582006) |
| 2026-10-08 23:02 | dev | corella-assistant--97220c2 | full | 95 | 18.7% (17/91, 4 known excluded) | 398 | 2542 | 0.00005 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37856909562) |
| 2026-10-09 22:24 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 406 | 2391 | 0.00003 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/37998761028) |
| 2026-10-10 21:17 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 224 | 1351 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38086881642) |
| 2026-10-11 21:37 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 208 | 830 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38176960095) |
| 2026-10-13 00:15 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 207 | 1239 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38326164202) |
| 2026-10-13 22:24 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 234 | 1306 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38477290294) |
| 2026-10-14 21:22 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 221 | 843 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38639487581) |
| 2026-10-15 21:02 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 181 | 722 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38806420027) |
| 2026-10-16 20:38 | dev | corella-assistant--97220c2 | full | 95 | 15.4% (14/91, 4 known excluded) | 195 | 875 | 0.00000 | [run](https://github.com/bradleyhet/azure-llmops-pipeline/actions/runs/38963316966) |
