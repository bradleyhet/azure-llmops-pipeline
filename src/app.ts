/**
 * The HTTP surface of the assistant as a plain `fetch` handler, with every dependency
 * injected. `src/server.ts` wires it to the environment and Bun.serve; the tests call
 * `app.fetch(new Request(...))` directly with a scripted LLM and no port.
 *
 * Routes
 *   GET  /healthz   liveness, 200 while the process is up
 *   GET  /readyz    readiness, 200 once the corpus is indexed and a model client exists
 *   GET  /version   build identity (git sha, build time, Container Apps revision, model)
 *   POST /ask       { query, customerId, history? } -> AskResponse
 *
 * One JSON log line per request goes to stdout for Log Analytics. The query text is not
 * logged; only its cost, tokens, latency, guardrail outcome and the revision that served it.
 */
import { z } from "zod";
import { answer, type AnswerResult, type BlockedBy, type ToolTrace } from "./assistant/answer.js";
import type { LlmClient, Usage } from "./assistant/openrouter.js";
import type { CustomerStore } from "./fixtures/customers.js";
import type { Retriever } from "./retrieval/retriever.js";

export interface RetrievedHit {
  id: string;
  score: number;
  normalisedScore: number;
}

/** Wire shape of a `/ask` reply. `src/eval/http-transform.ts` maps it to the promptfoo provider shape. */
export interface AskResponse {
  answer: string;
  /** Retrieved chunk texts followed by tool outputs: everything the answer may be grounded in. */
  context: string[];
  retrieved: RetrievedHit[];
  toolCalls: ToolTrace[];
  blockedBy: BlockedBy;
  blockedReason: string | null;
  rounds: number;
  usage: Usage;
  cost: number;
  latencyMs: number;
  model: string;
  customerId: string;
  revision: string;
}

export interface VersionInfo {
  service: string;
  gitSha: string;
  buildTime: string;
  /** Container Apps revision name, or "local" outside Azure. */
  revision: string;
  model: string;
}

export interface AppConfig {
  retriever: Retriever;
  store: CustomerStore;
  /** `null` means no model credential was available; `/readyz` reports 503 and `/ask` 503. */
  llm: LlmClient | null;
  model: string;
  retrieval: { k: number; minScore: number };
  maxToolRounds: number;
  maxTokens?: number;
  version: VersionInfo;
  /** Structured log sink; defaults to one JSON line per call on stdout. */
  log?: (entry: Record<string, unknown>) => void;
  /** Clock, injectable for tests. */
  now?: () => number;
}

export interface App {
  fetch(req: Request): Promise<Response>;
  readonly ready: boolean;
}

const historyMessage = z.object({ role: z.string(), content: z.unknown() });

const askSchema = z.object({
  query: z.string().min(1, "query must not be empty").max(4000, "query is too long"),
  customerId: z.string().min(1, "customerId is required").max(64),
  history: z.array(historyMessage).max(20, "history is too long").optional(),
});

export type AskRequest = z.infer<typeof askSchema>;

/**
 * `history` may arrive as an array, as a JSON string (promptfoo templates every body value
 * as a string), or as an empty string meaning absent. Normalise before validation.
 */
function normaliseHistory(raw: unknown): unknown {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (typeof raw === "string") {
    try {
      return JSON.parse(raw) as unknown;
    } catch {
      return raw; // let the schema reject it with a clear message
    }
  }
  return raw;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}

export function toAskResponse(result: AnswerResult, customerId: string, revision: string): AskResponse {
  return {
    answer: result.answer,
    context: result.context,
    retrieved: result.retrieved.map((c) => ({ id: c.id, score: c.score, normalisedScore: c.normalisedScore })),
    toolCalls: result.toolCalls,
    blockedBy: result.blockedBy,
    blockedReason: result.blockedReason,
    rounds: result.rounds,
    usage: result.usage,
    cost: result.cost,
    latencyMs: result.latencyMs,
    model: result.model,
    customerId,
    revision,
  };
}

export function createApp(config: AppConfig): App {
  const log = config.log ?? ((entry) => console.log(JSON.stringify(entry)));
  const now = config.now ?? Date.now;
  const revision = config.version.revision;

  async function handleAsk(req: Request): Promise<{ res: Response; extra: Record<string, unknown> }> {
    let raw: unknown;
    try {
      raw = await req.json();
    } catch {
      return { res: json(400, { error: "body must be JSON" }), extra: {} };
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      return { res: json(400, { error: "body must be a JSON object" }), extra: {} };
    }
    const candidate = { ...(raw as Record<string, unknown>), history: normaliseHistory((raw as Record<string, unknown>).history) };
    if (candidate.history === undefined) delete candidate.history;
    const parsed = askSchema.safeParse(candidate);
    if (!parsed.success) {
      const issues = parsed.error.issues.map((i) => ({ path: i.path.join("."), message: i.message }));
      return { res: json(400, { error: "invalid request", issues }), extra: { issues: issues.length } };
    }
    if (!config.llm) {
      return { res: json(503, { error: "model client not configured" }), extra: {} };
    }

    const { query, customerId, history } = parsed.data;
    let result: AnswerResult;
    try {
      result = await answer(
        query,
        { customerId, ...(history ? { history } : {}) },
        {
          retriever: config.retriever,
          llm: config.llm,
          store: config.store,
          model: config.model,
          retrieval: config.retrieval,
          maxToolRounds: config.maxToolRounds,
          ...(config.maxTokens !== undefined ? { maxTokens: config.maxTokens } : {}),
        },
      );
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      return { res: json(502, { error: "upstream model error", detail }), extra: { customerId, error: detail } };
    }

    const body = toAskResponse(result, customerId, revision);
    return {
      res: json(200, body),
      extra: {
        customerId,
        model: result.model,
        blockedBy: result.blockedBy,
        rounds: result.rounds,
        toolCalls: result.toolCalls.length,
        promptTokens: result.usage.promptTokens,
        completionTokens: result.usage.completionTokens,
        cost: result.cost,
        modelLatencyMs: result.latencyMs,
      },
    };
  }

  return {
    get ready() {
      return config.llm !== null;
    },
    async fetch(req: Request): Promise<Response> {
      const started = now();
      const url = new URL(req.url);
      const path = url.pathname;
      let res: Response;
      let extra: Record<string, unknown> = {};

      if (req.method === "GET" && path === "/healthz") {
        res = json(200, { status: "ok" });
      } else if (req.method === "GET" && path === "/readyz") {
        res = config.llm
          ? json(200, { status: "ready", revision })
          : json(503, { status: "not-ready", reason: "OPENROUTER_API_KEY is not set", revision });
      } else if (req.method === "GET" && path === "/version") {
        res = json(200, config.version);
      } else if (req.method === "POST" && path === "/ask") {
        ({ res, extra } = await handleAsk(req));
      } else if (path === "/ask") {
        res = json(405, { error: "use POST" });
      } else {
        res = json(404, { error: "not found" });
      }

      if (path !== "/healthz" && path !== "/readyz") {
        log({ ts: new Date(started).toISOString(), method: req.method, path, status: res.status, latencyMs: now() - started, revision, ...extra });
      }
      return res;
    },
  };
}
