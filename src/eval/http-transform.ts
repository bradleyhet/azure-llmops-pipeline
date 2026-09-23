/**
 * promptfoo `transformResponse` for the HTTP provider (promptfooconfig.http.yaml).
 *
 * Maps one `/ask` response body onto the same { output, tokenUsage, cost, metadata } the
 * in-process provider returns, so the assertion files in evals/ need no HTTP-specific copy.
 * tests/app.test.ts asserts the two paths agree for the same answer.
 */
import type { AskResponse } from "../app.js";

export default function transform(json: unknown): Record<string, unknown> {
  const body = json as AskResponse | null;
  if (!body || typeof body !== "object" || typeof body.answer !== "string") {
    return { error: `unexpected /ask response: ${JSON.stringify(json).slice(0, 200)}` };
  }
  const retrievedIds = body.retrieved.map((h) => h.id);
  return {
    output: {
      answer: body.answer,
      context: body.context,
      trace: { toolCalls: body.toolCalls, retrievedIds, blockedBy: body.blockedBy },
    },
    tokenUsage: {
      total: body.usage.totalTokens,
      prompt: body.usage.promptTokens,
      completion: body.usage.completionTokens,
    },
    cost: body.cost,
    metadata: {
      mode: "answer",
      retriever: "bm25",
      blockedBy: body.blockedBy,
      blockedReason: body.blockedReason,
      toolCalls: body.toolCalls,
      retrievedIds,
      hits: body.retrieved,
      rounds: body.rounds,
      latencyMs: body.latencyMs,
      model: body.model,
      customerId: body.customerId,
      revision: body.revision,
    },
  };
}
