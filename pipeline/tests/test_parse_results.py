import json
from pathlib import Path

import pytest

from llmops_pipeline.parse_results import (
    Thresholds,
    compute_metrics,
    evaluate,
    extract_case,
    main,
    percentile,
    render_markdown,
)


def cases_from(data: dict) -> list:
    return [extract_case(r) for r in data["results"]["results"]]


def test_percentile_nearest_rank() -> None:
    values = [float(v) for v in range(1, 11)]
    assert percentile(values, 50) == 5
    assert percentile(values, 95) == 10
    assert percentile(values, 0) == 1
    assert percentile([], 95) == 0


def test_fixture_metrics_match_the_real_run(smoke_data: dict) -> None:
    metrics = compute_metrics(cases_from(smoke_data), eval_id=smoke_data["evalId"])
    assert metrics.cases == 30
    assert metrics.passed == 30
    assert metrics.failed == 0
    assert metrics.errors == 0
    assert metrics.pass_rate == 1.0
    # Values promptfoo reported for this run on 2026-09-23 (README, Phase 1 results).
    assert metrics.p50_latency_ms == 1277
    assert metrics.p95_latency_ms == 2595
    assert 0.0003 < metrics.mean_cost_usd < 0.0005
    assert metrics.total_cost_usd == pytest.approx(0.0115, abs=0.0005)
    assert metrics.revisions == ["local"]
    assert metrics.tiers == ["smoke"]
    assert metrics.eval_id == "eval-qKK-2026-09-23T08:28:11"


def test_extract_case_reads_guardrail_outcome(smoke_data: dict) -> None:
    blocked = [c for c in cases_from(smoke_data) if c.blocked_by]
    assert blocked, "the smoke tier includes guardrail cases"
    assert {c.blocked_by for c in blocked} <= {"input-guard", "role-validation"}
    # The input guard also fires on one tools case that carries an injection payload.
    assert {c.category for c in blocked} == {"guardrails", "tools"}


def test_default_thresholds_pass_on_the_fixture(smoke_data: dict) -> None:
    verdict = evaluate(cases_from(smoke_data), Thresholds(), "fixture")
    assert verdict.passed
    assert verdict.breaches == []
    assert verdict.failed_cases == []


def test_each_threshold_breaches_independently(smoke_data: dict) -> None:
    cases = cases_from(smoke_data)
    tight_latency = evaluate(cases, Thresholds(max_p95_latency_ms=2000), "l")
    assert [b.metric for b in tight_latency.breaches] == ["p95_latency_ms"]
    tight_cost = evaluate(cases, Thresholds(max_mean_cost_usd=0.0001), "c")
    assert [b.metric for b in tight_cost.breaches] == ["mean_cost_usd"]


def test_failures_lower_pass_rate_and_are_listed(smoke_data: dict) -> None:
    rows = smoke_data["results"]["results"]
    for row in rows[:3]:
        row["success"] = False
        row["gradingResult"]["reason"] = "answer contradicted | the corpus"
    rows[3]["error"] = "provider timeout"
    rows[3]["success"] = False
    verdict = evaluate(cases_from(smoke_data), Thresholds(), "broken")
    assert verdict.metrics.passed == 26
    assert verdict.metrics.errors == 1
    assert verdict.metrics.pass_rate == pytest.approx(26 / 30)
    assert [b.metric for b in verdict.breaches] == ["pass_rate"]
    assert len(verdict.failed_cases) == 4
    md = render_markdown(verdict)
    assert "**FAIL**" in md
    assert "Result: FAIL. 1 threshold(s) breached: pass_rate." in md
    assert "| gr-001 | grounded |" in md
    assert "answer contradicted \\| the corpus" in md
    assert "provider timeout" in md


def test_markdown_table_shape(smoke_data: dict) -> None:
    md = render_markdown(evaluate(cases_from(smoke_data), Thresholds(), "Canary abc"))
    assert md.startswith("### Canary abc\n")
    assert "| Pass rate | 100.0% (30/30) | at or above 95% | pass |" in md
    assert "| p95 latency | 2595 ms | at or below 4000 ms | pass |" in md
    assert "**Result: pass. Every threshold met.**" in md
    assert "Failed case" not in md


def test_cli_writes_summary_metrics_and_outputs(smoke_path: Path, tmp_path: Path) -> None:
    summary = tmp_path / "summary.md"
    metrics_out = tmp_path / "metrics.json"
    gh_out = tmp_path / "output.txt"
    code = main(
        [
            str(smoke_path),
            "--label",
            "CLI",
            "--summary",
            str(summary),
            "--metrics-out",
            str(metrics_out),
            "--github-output",
            str(gh_out),
        ]
    )
    assert code == 0
    assert summary.read_text(encoding="utf-8").startswith("### CLI\n")
    saved = json.loads(metrics_out.read_text(encoding="utf-8"))
    assert saved["metrics"]["cases"] == 30
    assert saved["breaches"] == []
    outputs = dict(line.split("=", 1) for line in gh_out.read_text().splitlines())
    assert outputs["passed"] == "true"
    assert outputs["p95_latency_ms"] == "2595"


def test_cli_exit_codes(smoke_path: Path, tmp_path: Path) -> None:
    assert main([str(smoke_path), "--max-p95-ms", "1000", "--summary", ""]) == 1
    empty = tmp_path / "empty.json"
    empty.write_text(json.dumps({"results": {"results": []}}), encoding="utf-8")
    assert main([str(empty), "--summary", ""]) == 2
    bogus = tmp_path / "bogus.json"
    bogus.write_text("[]", encoding="utf-8")
    assert main([str(bogus), "--summary", ""]) == 2
    assert main([str(tmp_path / "missing.json"), "--summary", ""]) == 2
