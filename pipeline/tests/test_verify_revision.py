import json

import httpx
import pytest

from llmops_pipeline.verify_revision import check_version, main, wait_ready

BASE = "https://corella-assistant--abc1234.example.azurecontainerapps.io"


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def make_client(responses: list[httpx.Response | Exception], version: dict) -> httpx.Client:
    calls = {"readyz": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/version":
            return httpx.Response(200, json=version)
        assert request.url.path == "/readyz"
        idx = min(calls["readyz"], len(responses) - 1)
        calls["readyz"] += 1
        item = responses[idx]
        if isinstance(item, Exception):
            raise item
        return item

    return httpx.Client(transport=httpx.MockTransport(handler), base_url=BASE)


def test_waits_through_scale_from_zero_then_matches_revision() -> None:
    client = make_client(
        [
            httpx.ConnectTimeout("cold start"),
            httpx.Response(
                503, json={"status": "not-ready", "revision": "corella-assistant--abc1234"}
            ),
            httpx.Response(200, json={"status": "ready", "revision": "corella-assistant--abc1234"}),
        ],
        {"gitSha": "abc1234def"},
    )
    clock = FakeClock()
    state = wait_ready(
        client,
        BASE,
        expect_revision="corella-assistant--abc1234",
        timeout_s=60,
        interval_s=5,
        clock=clock,
        sleep=clock.sleep,
    )
    assert state.revision == "corella-assistant--abc1234"
    assert clock.now == 10  # two sleeps before the third attempt answered


def test_wrong_revision_keeps_polling_until_timeout() -> None:
    client = make_client(
        [httpx.Response(200, json={"status": "ready", "revision": "corella-assistant--old"})],
        {},
    )
    clock = FakeClock()
    with pytest.raises(TimeoutError, match="as corella-assistant--new"):
        wait_ready(
            client,
            BASE,
            expect_revision="corella-assistant--new",
            timeout_s=30,
            interval_s=10,
            clock=clock,
            sleep=clock.sleep,
        )
    assert clock.now >= 30


def test_check_version_prefix_match_and_mismatch() -> None:
    client = make_client([], {"gitSha": "abc1234def5678", "revision": "x"})
    assert check_version(client, BASE, "abc1234")["gitSha"] == "abc1234def5678"
    assert check_version(client, BASE, None)["gitSha"] == "abc1234def5678"
    with pytest.raises(ValueError, match="expected 'ffffff'"):
        check_version(client, BASE, "ffffff")


def test_main_exit_codes(capsys: pytest.CaptureFixture[str]) -> None:
    ok = make_client(
        [httpx.Response(200, json={"status": "ready", "revision": "r1"})], {"gitSha": "deadbeef"}
    )
    clock = FakeClock()
    args = ["--url", BASE, "--expect-revision", "r1", "--expect-sha", "deadbeef", "--timeout", "5"]
    assert main(args, client=ok, clock=clock, sleep=clock.sleep) == 0
    printed = json.loads(capsys.readouterr().out.strip())
    assert printed == {"revision": "r1", "version": {"gitSha": "deadbeef"}}

    wrong_sha = make_client(
        [httpx.Response(200, json={"status": "ready", "revision": "r1"})], {"gitSha": "0000000"}
    )
    assert main(args, client=wrong_sha, clock=clock, sleep=clock.sleep) == 1

    never = make_client([httpx.Response(503, json={"status": "not-ready"})], {})
    assert main(args, client=never, clock=clock, sleep=clock.sleep) == 1
