/**
 * promptfoo custom provider for the in-process eval gate (loaded under Node via
 * `file://src/eval/provider.ts`). Runs the same `answer()` the HTTP service runs, with no
 * server in between, so a pull request can be gated before any image exists.
 *
 * Output is { answer, context, trace }: assertions `transform: output.answer`, RAG graders
 * `contextTransform` the context array, and the javascript assertions read `metadata`.
 * The HTTP provider (promptfooconfig.http.yaml) reproduces this exact shape from the
 * `/ask` response through src/eval/http-transform.ts, so every test row runs unchanged
 * against either.
 *
 * Only `node:` APIs are used here: promptfoo executes this file with Node, not Bun.
 */
import { resolve } from "node:path";
import { answer, type AnswerResult } from "../assistant/answer.js";
import { createOpenRouterClient, type LlmClient } from "../assistant/openrouter.js";
import { createFixtureStore } from "../fixtures/customers.js";
import { loadCorpus } from "../retrieval/chunk.js";
import { createBm25Retriever, type Retriever } from "../retrieval/retriever.js";

export interface ProviderConfig {
  model?: string;
  corpusDir?: string;
  retrieval?: { k?: number; minScore?: number };
  maxToolRounds?: number;
  temperature?: number;
  maxTokens?: number;
}

interface CallContext {
  vars?: Record<string, unknown>;
}

export interface ProviderResponse {
  output?: unknown;
  error?: string;
  tokenUsage?: { total: number; prompt: number; completion: number };
  cost?: number;
  metadata?: Record<string, unknown>;
}

const retrievers = new Map<string, Retriever>();
function getRetriever(corpusDir: string): Retriever {
  const dir = resolve(corpusDir);
  let r = retrievers.get(dir);
  if (!r) {
    r = createBm25Retriever(loadCorpus(dir));
    retrievers.set(dir, r);
  }
  return r;
}

let llmSingleton: LlmClient | undefined;
function getLlm(): LlmClient {
  if (!llmSingleton) {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) throw new Error("OPENROUTER_API_KEY is not set");
    llmSingleton = createOpenRouterClient({ apiKey, title: "corella-assistant-eval" });
  }
  return llmSingleton;
}

const store = createFixtureStore();

export function parseHistory(raw: unknown): Array<{ role: string; content: unknown }> | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (typeof raw === "string") {
    try {
      return JSON.parse(raw) as Array<{ role: string; content: unknown }>;
    } catch {
      return [{ role: "user", content: raw }];
    }
  }
  return raw as Array<{ role: string; content: unknown }>;
}

/** The promptfoo-facing view of an answer. Shared with the HTTP transform so both paths agree field for field. */
export function toProviderResponse(result: AnswerResult, extra: { retriever: string; customerId: string }): ProviderResponse {
  const retrievedIds = result.retrieved.map((c) => c.id);
  return {
    output: {
      answer: result.answer,
      context: result.context,
      trace: { toolCalls: result.toolCalls, retrievedIds, blockedBy: result.blockedBy },
    },
    tokenUsage: {
      total: result.usage.totalTokens,
      prompt: result.usage.promptTokens,
      completion: result.usage.completionTokens,
    },
    cost: result.cost,
    metadata: {
      mode: "answer",
      retriever: extra.retriever,
      blockedBy: result.blockedBy,
      blockedReason: result.blockedReason,
      toolCalls: result.toolCalls,
      retrievedIds,
      hits: result.retrieved.map((c) => ({ id: c.id, score: c.score, normalisedScore: c.normalisedScore })),
      rounds: result.rounds,
      latencyMs: result.latencyMs,
      model: result.model,
      customerId: extra.customerId,
    },
  };
}

export default class CorellaAssistantProvider {
  private readonly providerId: string;
  private readonly config: ProviderConfig;

  constructor(options: { id?: string; config?: ProviderConfig } = {}) {
    this.config = options.config ?? {};
    this.providerId = options.id ?? "corella-assistant:in-process";
  }

  id(): string {
    return this.providerId;
  }

  async callApi(prompt: string, context?: CallContext): Promise<ProviderResponse> {
    const vars = context?.vars ?? {};
    const query = typeof vars.query === "string" && vars.query.length > 0 ? vars.query : prompt;
    const customerId = typeof vars.customerId === "string" ? vars.customerId : "cust_001";
    const retriever = getRetriever(this.config.corpusDir ?? "corpus");
    const k = this.config.retrieval?.k ?? 6;
    const minScore = this.config.retrieval?.minScore ?? 0;
    const model = this.config.model ?? process.env.SUT_MODEL ?? "google/gemini-2.5-flash";
    const history = parseHistory(vars.history);

    let result: AnswerResult;
    try {
      result = await answer(
        query,
        { customerId, ...(history ? { history } : {}) },
        {
          retriever,
          llm: getLlm(),
          store,
          model,
          retrieval: { k, minScore },
          maxToolRounds: this.config.maxToolRounds ?? 3,
          temperature: this.config.temperature ?? 0,
          ...(this.config.maxTokens !== undefined ? { maxTokens: this.config.maxTokens } : {}),
        },
      );
    } catch (err) {
      return { error: err instanceof Error ? err.message : String(err) };
    }
    return toProviderResponse(result, { retriever: retriever.name, customerId });
  }
}
