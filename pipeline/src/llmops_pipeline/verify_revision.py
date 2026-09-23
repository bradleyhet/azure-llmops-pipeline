"""Wait until a Container Apps revision answers ready on its own URL.

    verify-revision --url https://corella-assistant--abc1234.<env-domain> \\
        --expect-revision corella-assistant--abc1234 --expect-sha <git sha> --timeout 600

Polls ``GET /readyz`` until it returns 200 with ``{"status": "ready"}`` from the expected
revision (a new revision scales from zero, so the first answer can take ten seconds or more),
then reads ``GET /version`` and checks the git sha the image was built from. Exit 0 when the
revision is ready and matches, 1 on timeout or mismatch.
"""

import argparse
import json
import sys
import time
from collections.abc import Callable
from typing import Any

import httpx
from pydantic import BaseModel


class ReadyState(BaseModel):
    status: str = "unknown"
    revision: str | None = None
    reason: str | None = None


def _log(message: str) -> None:
    print(f"verify-revision: {message}", file=sys.stderr, flush=True)


def _parse_ready(response: httpx.Response) -> ReadyState:
    try:
        body = response.json()
    except ValueError:
        return ReadyState(status=f"non-json ({response.text[:60]!r})")
    if not isinstance(body, dict):
        return ReadyState(status="non-object")
    return ReadyState(
        status=str(body.get("status", "unknown")),
        revision=body.get("revision"),
        reason=body.get("reason"),
    )


def wait_ready(
    client: httpx.Client,
    base_url: str,
    *,
    expect_revision: str | None,
    timeout_s: float,
    interval_s: float,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> ReadyState:
    """Poll ``/readyz`` until ready from ``expect_revision``; raise TimeoutError otherwise."""
    deadline = clock() + timeout_s
    attempt = 0
    url = f"{base_url.rstrip('/')}/readyz"
    while True:
        attempt += 1
        try:
            response = client.get(url, timeout=30)
            state = _parse_ready(response)
            revision_ok = expect_revision is None or state.revision == expect_revision
            _log(
                f"attempt {attempt}: HTTP {response.status_code} status={state.status} "
                f"revision={state.revision}"
            )
            if response.status_code == 200 and state.status == "ready" and revision_ok:
                return state
        except httpx.HTTPError as exc:
            _log(f"attempt {attempt}: {type(exc).__name__}: {exc}")
        if clock() >= deadline:
            wanted = f" as {expect_revision}" if expect_revision else ""
            raise TimeoutError(
                f"{url} did not answer ready{wanted} within {timeout_s:.0f}s ({attempt} attempts)"
            )
        sleep(interval_s)


def check_version(client: httpx.Client, base_url: str, expect_sha: str | None) -> dict[str, Any]:
    """Read ``/version``; when ``expect_sha`` is given, the reported gitSha must match it."""
    response = client.get(f"{base_url.rstrip('/')}/version", timeout=30)
    response.raise_for_status()
    info = response.json()
    if not isinstance(info, dict):
        raise ValueError(f"/version returned {type(info).__name__}, expected an object")
    got = str(info.get("gitSha") or "")
    if expect_sha:
        short = expect_sha[:7]
        if not got or not (got.startswith(short) or short.startswith(got)):
            raise ValueError(f"/version reports gitSha {got!r}, expected {expect_sha!r}")
    return info


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="verify-revision", description="Wait for a revision to be ready on its own URL."
    )
    parser.add_argument("--url", required=True, help="revision base URL, no trailing path")
    parser.add_argument("--expect-revision", help="revision name /readyz must report")
    parser.add_argument("--expect-sha", help="git sha /version must report (prefix match)")
    parser.add_argument("--timeout", type=float, default=600, help="seconds to keep polling")
    parser.add_argument("--interval", type=float, default=10, help="seconds between polls")
    return parser


def main(
    argv: list[str] | None = None,
    *,
    client: httpx.Client | None = None,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    args = build_parser().parse_args(argv)
    own_client = client is None
    client = client or httpx.Client(follow_redirects=False)
    try:
        state = wait_ready(
            client,
            args.url,
            expect_revision=args.expect_revision,
            timeout_s=args.timeout,
            interval_s=args.interval,
            clock=clock,
            sleep=sleep,
        )
        info = check_version(client, args.url, args.expect_sha)
    except (TimeoutError, ValueError, httpx.HTTPError) as exc:
        _log(f"FAILED: {exc}")
        return 1
    finally:
        if own_client:
            client.close()
    _log(f"ready: revision={state.revision} gitSha={info.get('gitSha')}")
    print(json.dumps({"revision": state.revision, "version": info}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
