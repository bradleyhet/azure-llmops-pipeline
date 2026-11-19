import { readFileSync } from "node:fs";
import { getAnswer, getRawOutput, type AssertionContext, type GradingResult } from "./shared.js";

/**
 * Faithfulness by majority vote. promptfoo's context-faithfulness asks the judge once, and at
 * temperature 0 the judge still changes its mind: on 2026-11-19 the same correct answer to gr-001
 * was rejected in 7 of 12 back-to-back replays, then 22 of 24 ten minutes later (README,
 * Methodology). One wrong "No" on a three-claim answer scores 0.67 against the 0.7 threshold, so
 * a single verdict could fail a correct answer and, with one other miss, the 0.95 gate.
 *
 * This assertion runs promptfoo's own matcher an odd number of times and takes the median score.
 * Each vote is the full two-step check (extract the claims, then judge each against the context)
 * with the same overridden prompts and the same judge as before.
 *
 * The votes must bypass promptfoo's response cache. The three requests are identical, so with
 * the cache on the first reply is stored and handed back for the other two: three copies of one
 * verdict, which is no vote at all (measured: every triple identical with the cache on, mixed
 * triples such as 0.67, 1.00, 1.00 with it bypassed).
 */

export type FaithfulnessMatcher = (
  query: string,
  output: string,
  context: string,
  threshold: number,
  grading: { provider?: unknown; rubricPrompt: [string, string] },
) => Promise<{ pass: boolean; score: number; reason: string }>;

const DEFAULT_VOTES = 3;
const DEFAULT_THRESHOLD = 0.7;
const PROMPT_FILES = ["evals/assertions/faithfulness-longform.txt", "evals/assertions/faithfulness-nli.txt"] as const;

/** The middle value. Callers pass an odd number of scores. */
export function median(scores: readonly number[]): number {
  const sorted = [...scores].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] ?? 0;
}

/**
 * The retrieved chunks, joined as the old `contextTransform` joined them. The test-level
 * `transform: output.answer` has already replaced `providerResponse.output` with the answer
 * string, so the { answer, context, trace } object is read from where promptfoo keeps the
 * untransformed output.
 */
function getContextText(output: unknown, context: AssertionContext | undefined): string {
  const raw = context?.providerResponse?.providerTransformedOutput ?? getRawOutput(output, context);
  const chunks = raw && typeof raw === "object" ? (raw as { context?: unknown }).context : undefined;
  return Array.isArray(chunks) ? chunks.map(String).join("\n\n") : "";
}

/** promptfoo resolves assertion paths from the working directory, so the prompts are read the same way. */
function loadPrompts(): [string, string] {
  return [readFileSync(PROMPT_FILES[0], "utf8"), readFileSync(PROMPT_FILES[1], "utf8")];
}

/** Runs one vote so that it cannot share a cached reply with another. */
export type VoteRunner = <T>(vote: () => Promise<T>) => Promise<T>;

const runDirectly: VoteRunner = (vote) => vote();

export function makeFaithfulMajority(matcher: FaithfulnessMatcher, prompts?: [string, string], runVote: VoteRunner = runDirectly) {
  return async function faithfulMajority(output: unknown, context?: AssertionContext): Promise<GradingResult> {
    const votes = Number(context?.config?.votes ?? DEFAULT_VOTES);
    const threshold = Number(context?.config?.threshold ?? DEFAULT_THRESHOLD);
    if (!Number.isInteger(votes) || votes < 1 || votes % 2 === 0) {
      throw new Error(`faithful-majority needs an odd number of votes, got ${String(context?.config?.votes)}`);
    }

    const contextText = getContextText(output, context);
    if (contextText === "") return { pass: false, score: 0, reason: "Faithfulness not judged: the response carries no context" };

    const grading = { provider: context?.test?.options?.provider, rubricPrompt: prompts ?? loadPrompts() };
    const query = String(context?.vars?.query ?? "");
    const answer = getAnswer(output, context);

    const errors: string[] = [];
    const scores = await Promise.all(
      Array.from({ length: votes }, async () => {
        try {
          return (await runVote(() => matcher(query, answer, contextText, threshold, grading))).score;
        } catch (error) {
          // A vote the judge could not deliver is a vote against, never a reason to skip the check.
          errors.push(error instanceof Error ? error.message : String(error));
          return 0;
        }
      }),
    );

    const score = median(scores);
    const pass = score >= threshold;
    const detail = errors.length > 0 ? `; ${errors.length} vote(s) errored: ${errors.join("; ")}` : "";
    return {
      pass,
      score,
      reason: `Faithfulness median ${score.toFixed(2)} of ${votes} votes (${scores.map((s) => s.toFixed(2)).join(", ")}) is ${pass ? ">=" : "<"} ${threshold}${detail}`,
    };
  };
}

export default async function faithfulMajority(output: unknown, context?: AssertionContext): Promise<GradingResult> {
  // Imported here, not at the top: unit tests inject a scripted matcher and never load promptfoo.
  const { assertions, cache } = await import("promptfoo");
  const uncached: VoteRunner = (vote) => cache.withCacheEnabled(false, vote);
  return makeFaithfulMajority(assertions.matchesContextFaithfulness as unknown as FaithfulnessMatcher, undefined, uncached)(output, context);
}
