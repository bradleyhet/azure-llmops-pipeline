import { describe, expect, it } from "vitest";
import { clientKey, createRateLimiter } from "../src/rate-limit.js";

const T0 = Date.UTC(2026, 8, 24, 3, 0, 10); // 10 s into a minute

describe("per-client limit", () => {
  it("allows the limit, refuses the next with the seconds left in the minute, and keys by client", () => {
    const limiter = createRateLimiter({ perClientPerMinute: 2, perDay: 0 });
    expect(limiter.checkClient("a", T0)).toEqual({ ok: true });
    expect(limiter.checkClient("a", T0)).toEqual({ ok: true });
    expect(limiter.checkClient("a", T0)).toEqual({ ok: false, limit: "client", retryAfterSeconds: 50 });
    expect(limiter.checkClient("b", T0)).toEqual({ ok: true });
  });

  it("starts a fresh count in the next minute", () => {
    const limiter = createRateLimiter({ perClientPerMinute: 1, perDay: 0 });
    expect(limiter.checkClient("a", T0).ok).toBe(true);
    expect(limiter.checkClient("a", T0).ok).toBe(false);
    expect(limiter.checkClient("a", T0 + 50_000).ok).toBe(true);
  });

  it("is off at 0", () => {
    const limiter = createRateLimiter({ perClientPerMinute: 0, perDay: 0 });
    for (let i = 0; i < 100; i++) expect(limiter.checkClient("a", T0).ok).toBe(true);
  });
});

describe("daily limit", () => {
  it("refuses once the day's count is spent and resets at UTC midnight", () => {
    const limiter = createRateLimiter({ perClientPerMinute: 0, perDay: 2 });
    expect(limiter.checkDaily(T0).ok).toBe(true);
    expect(limiter.checkDaily(T0).ok).toBe(true);
    const refused = limiter.checkDaily(T0);
    expect(refused).toMatchObject({ ok: false, limit: "daily" });
    // 03:00:10 UTC leaves 20 h 59 min 50 s to midnight.
    expect(refused.ok ? 0 : refused.retryAfterSeconds).toBe(75_590);
    expect(limiter.checkDaily(Date.UTC(2026, 8, 25, 0, 0, 1)).ok).toBe(true);
  });
});

describe("clientKey", () => {
  const req = (xff?: string) => new Request("http://test/ask", xff ? { headers: { "x-forwarded-for": xff } } : {});

  it("takes the last X-Forwarded-For entry, the one the ingress appended", () => {
    expect(clientKey(req("1.1.1.1, 203.0.113.9"))).toBe("203.0.113.9");
    expect(clientKey(req("203.0.113.9"))).toBe("203.0.113.9");
  });

  it("falls back to one shared key without the header", () => {
    expect(clientKey(req())).toBe("unknown");
    expect(clientKey(req(" "))).toBe("unknown");
  });
});
