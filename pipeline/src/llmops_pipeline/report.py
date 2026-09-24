"""Append one row per eval run to ``docs/results.md``.

    eval-report --metrics results/full-metrics.json --out docs/results.md \\
        --environment dev --tier full --run-url https://github.com/.../actions/runs/123

``--metrics`` is the JSON that ``parse-results --metrics-out`` wrote. The nightly workflow
commits the updated file, so the table is a record of every run, never edited by hand.
"""

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

from .parse_results import Metrics

HEADER = (
    "| Date (UTC) | Environment | Revision | Tier | Cases | Pass rate | p50 ms | p95 ms "
    "| Cost per case USD | Run |"
)
SEPARATOR = "|---|---|---|---|---|---|---|---|---|---|"
INTRO = """# Eval results

One row per eval run over HTTP against a deployed revision, appended by `eval-report`
(`pipeline/src/llmops_pipeline/report.py`) and committed by the workflow that ran it. The
nightly run covers the full tier against whichever dev revision holds traffic. Thresholds
are in `pipeline/src/llmops_pipeline/parse_results.py`.

"""


def format_row(metrics: Metrics, *, environment: str, tier: str, run_url: str, date: str) -> str:
    revision = ", ".join(metrics.revisions) or "unknown"
    run = f"[run]({run_url})" if run_url else ""
    gated = metrics.cases - metrics.known_failures
    known = f", {metrics.known_failures} known excluded" if metrics.known_failures else ""
    return (
        f"| {date} | {environment} | {revision} | {tier} | {metrics.cases} "
        f"| {metrics.pass_rate:.1%} ({metrics.passed}/{gated}{known}) "
        f"| {metrics.p50_latency_ms:.0f} | {metrics.p95_latency_ms:.0f} "
        f"| {metrics.mean_cost_usd:.5f} | {run} |"
    )


def append_row(path: Path, row: str) -> None:
    """Add ``row`` under the table, creating the file with its intro and header if needed."""
    if path.exists():
        text = path.read_text(encoding="utf-8")
        if HEADER not in text:
            text = text.rstrip("\n") + "\n\n" + HEADER + "\n" + SEPARATOR + "\n"
        elif not text.endswith("\n"):
            text += "\n"
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        text = INTRO + HEADER + "\n" + SEPARATOR + "\n"
    path.write_text(text + row + "\n", encoding="utf-8")


def load_metrics(path: Path) -> Metrics:
    data = json.loads(path.read_text(encoding="utf-8"))
    payload = data.get("metrics", data) if isinstance(data, dict) else data
    return Metrics.model_validate(payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="eval-report", description="Append a results row.")
    parser.add_argument("--metrics", required=True, help="JSON from parse-results --metrics-out")
    parser.add_argument("--out", default="docs/results.md")
    parser.add_argument("--environment", required=True)
    parser.add_argument("--tier", required=True, help="tier label for the row, e.g. full")
    parser.add_argument("--run-url", default="")
    parser.add_argument(
        "--date",
        default=datetime.now(UTC).strftime("%Y-%m-%d %H:%M"),
        help="row timestamp, default now in UTC",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        metrics = load_metrics(Path(args.metrics))
    except (OSError, ValueError) as exc:
        print(f"eval-report: {exc}", file=sys.stderr)
        return 2
    row = format_row(
        metrics,
        environment=args.environment,
        tier=args.tier,
        run_url=args.run_url,
        date=args.date,
    )
    append_row(Path(args.out), row)
    print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
