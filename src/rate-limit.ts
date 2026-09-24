/**
 * In-memory request limits for `POST /ask`, per replica. Two counters, both fixed windows:
 *
 *   per client, per minute   slows one caller down; keyed on the client address
 *   whole replica, per UTC day   bounds what the replica can spend on the model, whoever calls
 *
 * The daily count is the cost ceiling: with `maxReplicas` replicas the model can be called at
 * most `maxReplicas * perDay` times a day. State lives in the process and resets on restart,
 * which is fine for a bound that only has to be approximately right.
 */

export interface RateLimitConfig {
  /** Requests one client may make per minute. 0 turns the check off. */
  perClientPerMinute: number;
  /** Model-bound requests this replica accepts per UTC day. 0 turns the check off. */
  perDay: number;
}

export type LimitOutcome = { ok: true } | { ok: false; limit: "client" | "daily"; retryAfterSeconds: number };

const MINUTE = 60_000;
const DAY = 86_400_000;

export interface RateLimiter {
  /** Counts one request from `client` against the per-minute window. */
  checkClient(client: string, now: number): LimitOutcome;
  /** Counts one model-bound request against the daily window. */
  checkDaily(now: number): LimitOutcome;
}

export function createRateLimiter(config: RateLimitConfig): RateLimiter {
  let minuteStart = 0;
  let perClient = new Map<string, number>();
  let dayStart = 0;
  let dayCount = 0;

  return {
    checkClient(client, now) {
      if (config.perClientPerMinute <= 0) return { ok: true };
      const window = now - (now % MINUTE);
      if (window !== minuteStart) {
        // A new window drops every old key, so the map never outgrows one minute of clients.
        minuteStart = window;
        perClient = new Map();
      }
      const count = (perClient.get(client) ?? 0) + 1;
      perClient.set(client, count);
      if (count <= config.perClientPerMinute) return { ok: true };
      return { ok: false, limit: "client", retryAfterSeconds: Math.ceil((window + MINUTE - now) / 1000) };
    },
    checkDaily(now) {
      if (config.perDay <= 0) return { ok: true };
      const window = now - (now % DAY);
      if (window !== dayStart) {
        dayStart = window;
        dayCount = 0;
      }
      if (dayCount >= config.perDay) {
        return { ok: false, limit: "daily", retryAfterSeconds: Math.ceil((window + DAY - now) / 1000) };
      }
      dayCount += 1;
      return { ok: true };
    },
  };
}

/**
 * The caller's address as Container Apps ingress reports it. Envoy appends the address it
 * accepted the connection from to `X-Forwarded-For`, so the last entry is the one a caller
 * cannot forge; anything to its left is whatever the caller sent. Without the header (local
 * runs, tests) every request shares one key.
 */
export function clientKey(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for");
  if (!forwarded) return "unknown";
  const last = forwarded.split(",").at(-1)?.trim();
  return last || "unknown";
}
