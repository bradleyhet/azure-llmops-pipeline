"""Score a promptfoo results file against the pipeline thresholds.

Reads the JSON that ``promptfoo eval -o results/<name>.json`` writes, computes pass rate,
latency percentiles and cost per case over the test rows, compares them with the thresholds,
writes a markdown table (appended to ``$GITHUB_STEP_SUMMARY`` when that is set) and exits
non-zero on any breach. The same scorer runs on the in-process eval gate, the canary and the
weekly full run, so all three are judged by one rule.

Rows marked ``known_failure: true`` in their metadata are documented gaps, not regressions:
they are left out of the pass rate and listed apart, and one that starts passing is flagged
so the marker gets removed. Latency is gated twice. p50 catches a slowdown that touches
every case; p95 is loose because over 30 cases it is the second-slowest call, and one slow
model response upstream should not fail a deploy.

Exit codes: 0 all thresholds met, 1 at least one breached, 2 the file could not be scored.
"""

import argparse
import json
import math
import os
import sys
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field


class Thresholds(BaseModel):
    """Limits a run must meet. The defaults are the canary gate."""

    min_pass_rate: float = Field(default=0.95, ge=0, le=1)
    max_p50_latency_ms: float = Field(default=2500, gt=0)
    max_p95_latency_ms: float = Field(default=10000, gt=0)
    max_mean_cost_usd: float = Field(default=0.01, gt=0)


class CaseResult(BaseModel):
    """One promptfoo test row, reduced to what the scorer and the summary need."""

    id: str
    category: str
    tier: str
    success: bool
    error: bool
    known_failure: bool = False
    latency_ms: float
    cost_usd: float
    blocked_by: str | None = None
    revision: str | None = None
    reason: str = ""


class Metrics(BaseModel):
    cases: int
    #: Rows marked known_failure; excluded from passed, failed and pass_rate.
    known_failures: int = 0
    #: Known-failure rows that passed this run, so their marker can be removed.
    known_failures_passing: list[str] = Field(default_factory=list)
    passed: int
    failed: int
    errors: int
    pass_rate: float
    p50_latency_ms: float
    p95_latency_ms: float
    mean_cost_usd: float
    total_cost_usd: float
    revisions: list[str]
    tiers: list[str]
    eval_id: str | None = None
    timestamp: str | None = None


class Breach(BaseModel):
    metric: str
    actual: float
    limit: float
    rule: str


class Verdict(BaseModel):
    label: str
    metrics: Metrics
    thresholds: Thresholds
    breaches: list[Breach]
    failed_cases: list[CaseResult]

    @property
    def passed(self) -> bool:
        return not self.breaches


def percentile(values: list[float], p: float) -> float:
    """Nearest-rank percentile of ``values`` for ``p`` in [0, 100]; 0 for no values."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, math.ceil(p / 100 * len(ordered)))
    return float(ordered[rank - 1])


def load_results(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict) or not isinstance(data.get("results"), dict):
        raise ValueError(f"{path} is not a promptfoo results file: no top-level results object")
    if not isinstance(data["results"].get("results"), list):
        raise ValueError(f"{path} is not a promptfoo results file: results.results is not a list")
    return data


def extract_case(row: dict[str, Any]) -> CaseResult:
    meta = (row.get("testCase") or {}).get("metadata") or {}
    response_meta = (row.get("response") or {}).get("metadata") or {}
    grading = row.get("gradingResult") or {}
    error = row.get("error")
    reason = str(error or grading.get("reason") or "")
    # promptfoo also fills `error` when an assertion fails; failureReason tells them apart
    # (1 assertion failed, 2 the call itself errored). Older files may not carry it.
    failure_reason = row.get("failureReason")
    errored = failure_reason == 2 or (failure_reason != 1 and bool(error))
    return CaseResult(
        id=str(meta.get("id") or row.get("id") or f"row-{row.get('testIdx', '?')}"),
        category=str(meta.get("category") or "unknown"),
        tier=str(meta.get("tier") or "unknown"),
        success=bool(row.get("success")),
        error=errored,
        known_failure=meta.get("known_failure") is True,
        latency_ms=float(row.get("latencyMs") or 0),
        cost_usd=float(row.get("cost") or 0),
        blocked_by=response_meta.get("blockedBy"),
        revision=response_meta.get("revision"),
        reason=" ".join(reason.split())[:300],
    )


def compute_metrics(
    cases: list[CaseResult], *, eval_id: str | None = None, timestamp: str | None = None
) -> Metrics:
    n = len(cases)
    gated = [c for c in cases if not c.known_failure]
    known = [c for c in cases if c.known_failure]
    passed = sum(1 for c in gated if c.success)
    errors = sum(1 for c in cases if c.error)
    # Every row was a real request, so latency and cost count all of them.
    latencies = [c.latency_ms for c in cases]
    total_cost = sum(c.cost_usd for c in cases)
    return Metrics(
        cases=n,
        known_failures=len(known),
        known_failures_passing=[c.id for c in known if c.success],
        passed=passed,
        failed=len(gated) - passed,
        errors=errors,
        pass_rate=(passed / len(gated)) if gated else 0.0,
        p50_latency_ms=percentile(latencies, 50),
        p95_latency_ms=percentile(latencies, 95),
        mean_cost_usd=(total_cost / n) if n else 0.0,
        total_cost_usd=total_cost,
        revisions=sorted({c.revision for c in cases if c.revision}),
        tiers=sorted({c.tier for c in cases}),
        eval_id=eval_id,
        timestamp=timestamp,
    )


def evaluate(
    cases: list[CaseResult],
    thresholds: Thresholds,
    label: str,
    *,
    eval_id: str | None = None,
    timestamp: str | None = None,
) -> Verdict:
    metrics = compute_metrics(cases, eval_id=eval_id, timestamp=timestamp)
    breaches: list[Breach] = []
    if metrics.pass_rate < thresholds.min_pass_rate:
        breaches.append(
            Breach(
                metric="pass_rate",
                actual=metrics.pass_rate,
                limit=thresholds.min_pass_rate,
                rule="at or above",
            )
        )
    if metrics.p50_latency_ms > thresholds.max_p50_latency_ms:
        breaches.append(
            Breach(
                metric="p50_latency_ms",
                actual=metrics.p50_latency_ms,
                limit=thresholds.max_p50_latency_ms,
                rule="at or below",
            )
        )
    if metrics.p95_latency_ms > thresholds.max_p95_latency_ms:
        breaches.append(
            Breach(
                metric="p95_latency_ms",
                actual=metrics.p95_latency_ms,
                limit=thresholds.max_p95_latency_ms,
                rule="at or below",
            )
        )
    if metrics.mean_cost_usd > thresholds.max_mean_cost_usd:
        breaches.append(
            Breach(
                metric="mean_cost_usd",
                actual=metrics.mean_cost_usd,
                limit=thresholds.max_mean_cost_usd,
                rule="at or below",
            )
        )
    return Verdict(
        label=label,
        metrics=metrics,
        thresholds=thresholds,
        breaches=breaches,
        failed_cases=[c for c in cases if not c.success and not c.known_failure],
    )


def _mark(ok: bool) -> str:
    return "pass" if ok else "**FAIL**"


def render_markdown(verdict: Verdict) -> str:
    m, t = verdict.metrics, verdict.thresholds
    breached = {b.metric for b in verdict.breaches}
    gated = m.cases - m.known_failures
    known_note = f", {m.known_failures} known failures excluded" if m.known_failures else ""
    lines = [
        f"### {verdict.label}",
        "",
        "| Metric | Value | Threshold | Result |",
        "|---|---|---|---|",
        f"| Cases | {m.cases} ({', '.join(m.tiers) or 'no tier'}) | | |",
        f"| Pass rate | {m.pass_rate:.1%} ({m.passed}/{gated}{known_note}) "
        f"| at or above {t.min_pass_rate:.0%} | {_mark('pass_rate' not in breached)} |",
        f"| p50 latency | {m.p50_latency_ms:.0f} ms | at or below {t.max_p50_latency_ms:.0f} ms "
        f"| {_mark('p50_latency_ms' not in breached)} |",
        f"| p95 latency | {m.p95_latency_ms:.0f} ms | at or below {t.max_p95_latency_ms:.0f} ms "
        f"| {_mark('p95_latency_ms' not in breached)} |",
        f"| Cost per case | {m.mean_cost_usd:.5f} USD | at or below {t.max_mean_cost_usd:.3f} USD "
        f"| {_mark('mean_cost_usd' not in breached)} |",
        f"| Total cost | {m.total_cost_usd:.4f} USD | | |",
        f"| Errors | {m.errors} | | |",
        f"| Revision | {', '.join(m.revisions) or 'unknown'} | | |",
        "",
    ]
    if verdict.passed:
        lines.append("**Result: pass. Every threshold met.**")
    else:
        names = ", ".join(b.metric for b in verdict.breaches)
        lines.append(f"**Result: FAIL. {len(verdict.breaches)} threshold(s) breached: {names}.**")
    if verdict.failed_cases:
        lines += [
            "",
            "| Failed case | Category | Blocked by | Reason |",
            "|---|---|---|---|",
        ]
        for c in verdict.failed_cases:
            reason = c.reason.replace("|", "\\|")[:160]
            lines.append(f"| {c.id} | {c.category} | {c.blocked_by or ''} | {reason} |")
    if m.known_failures_passing:
        lines += [
            "",
            "Known failures that passed this run (remove `known_failure` if it holds): "
            + ", ".join(m.known_failures_passing),
        ]
    lines.append("")
    return "\n".join(lines)


def _write_github_output(path: str, verdict: Verdict) -> None:
    m = verdict.metrics
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"passed={'true' if verdict.passed else 'false'}\n")
        fh.write(f"pass_rate={m.pass_rate:.4f}\n")
        fh.write(f"p50_latency_ms={m.p50_latency_ms:.0f}\n")
        fh.write(f"p95_latency_ms={m.p95_latency_ms:.0f}\n")
        fh.write(f"mean_cost_usd={m.mean_cost_usd:.6f}\n")
        fh.write(f"cases={m.cases}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="parse-results", description="Score a promptfoo results file against thresholds."
    )
    parser.add_argument("results", help="promptfoo JSON output (promptfoo eval -o <file>)")
    parser.add_argument("--label", default="Eval results", help="heading for the summary table")
    defaults = Thresholds()
    parser.add_argument("--min-pass-rate", type=float, default=defaults.min_pass_rate)
    parser.add_argument("--max-p50-ms", type=float, default=defaults.max_p50_latency_ms)
    parser.add_argument("--max-p95-ms", type=float, default=defaults.max_p95_latency_ms)
    parser.add_argument("--max-mean-cost", type=float, default=defaults.max_mean_cost_usd)
    parser.add_argument(
        "--summary",
        default=os.environ.get("GITHUB_STEP_SUMMARY"),
        help="markdown file to append the table to (default: $GITHUB_STEP_SUMMARY)",
    )
    parser.add_argument(
        "--metrics-out", help="write the verdict (metrics, thresholds, breaches) as JSON"
    )
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="file to append passed=, pass_rate=, p95_latency_ms=, mean_cost_usd= lines to",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        data = load_results(Path(args.results))
    except (OSError, ValueError) as exc:
        print(f"parse-results: {exc}", file=sys.stderr)
        return 2
    rows = data["results"]["results"]
    cases = [extract_case(r) for r in rows if isinstance(r, dict)]
    thresholds = Thresholds(
        min_pass_rate=args.min_pass_rate,
        max_p50_latency_ms=args.max_p50_ms,
        max_p95_latency_ms=args.max_p95_ms,
        max_mean_cost_usd=args.max_mean_cost,
    )
    verdict = evaluate(
        cases,
        thresholds,
        args.label,
        eval_id=data.get("evalId"),
        timestamp=data["results"].get("timestamp"),
    )
    markdown = render_markdown(verdict)
    print(markdown)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(markdown + "\n")
    if args.metrics_out:
        Path(args.metrics_out).write_text(
            verdict.model_dump_json(indent=2) + "\n", encoding="utf-8"
        )
    if args.github_output:
        _write_github_output(args.github_output, verdict)
    if not cases:
        print("parse-results: the file holds no test rows", file=sys.stderr)
        return 2
    return 0 if verdict.passed else 1


if __name__ == "__main__":
    sys.exit(main())
