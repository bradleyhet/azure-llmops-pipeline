import json
from pathlib import Path

from llmops_pipeline.parse_results import main as parse_main
from llmops_pipeline.report import HEADER, append_row, main


def test_creates_file_then_appends(tmp_path: Path, smoke_path: Path) -> None:
    metrics = tmp_path / "metrics.json"
    assert parse_main([str(smoke_path), "--summary", "", "--metrics-out", str(metrics)]) == 0
    out = tmp_path / "docs" / "results.md"
    args = [
        "--metrics",
        str(metrics),
        "--out",
        str(out),
        "--environment",
        "dev",
        "--tier",
        "smoke",
        "--run-url",
        "https://example.test/runs/1",
        "--date",
        "2026-09-23 18:00",
    ]
    assert main(args) == 0
    text = out.read_text(encoding="utf-8")
    assert text.startswith("# Eval results")
    assert HEADER in text
    row = "| 2026-09-23 18:00 | dev | local | smoke | 30 | 100.0% (30/30) | 1277 | 2595 |"
    assert text.count(row) == 1
    assert "[run](https://example.test/runs/1)" in text

    assert main(args) == 0
    assert out.read_text(encoding="utf-8").count("| 2026-09-23 18:00 |") == 2


def test_append_adds_header_to_a_file_without_one(tmp_path: Path) -> None:
    out = tmp_path / "results.md"
    out.write_text("# Notes\n\nhand-written intro", encoding="utf-8")
    append_row(out, "| a | b |")
    lines = out.read_text(encoding="utf-8").splitlines()
    assert lines[-3] == HEADER
    assert lines[-1] == "| a | b |"


def test_bad_metrics_file_exits_2(tmp_path: Path) -> None:
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"metrics": {"cases": "x"}}), encoding="utf-8")
    assert main(["--metrics", str(bad), "--environment", "dev", "--tier", "full"]) == 2
    missing = str(tmp_path / "nope")
    assert main(["--metrics", missing, "--environment", "dev", "--tier", "full"]) == 2


def test_row_shows_known_failures_excluded(tmp_path: Path) -> None:
    metrics = tmp_path / "metrics.json"
    metrics.write_text(
        json.dumps(
            {
                "metrics": {
                    "cases": 95,
                    "known_failures": 4,
                    "passed": 90,
                    "failed": 1,
                    "errors": 0,
                    "pass_rate": 90 / 91,
                    "p50_latency_ms": 1409,
                    "p95_latency_ms": 2684,
                    "mean_cost_usd": 0.0004,
                    "total_cost_usd": 0.038,
                    "revisions": ["corella-assistant--abc"],
                    "tiers": ["full", "smoke"],
                }
            }
        ),
        encoding="utf-8",
    )
    out = tmp_path / "results.md"
    args = ["--metrics", str(metrics), "--out", str(out), "--environment", "dev", "--tier", "full"]
    assert main([*args, "--date", "2026-09-25 18:00"]) == 0
    row = "| 95 | 98.9% (90/91, 4 known excluded) | 1409 | 2684 |"
    assert row in out.read_text(encoding="utf-8")
