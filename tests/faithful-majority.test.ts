import { describe, expect, it } from "vitest";
import { makeFaithfulMajority, median, type FaithfulnessMatcher } from "../evals/assertions/faithful-majority.js";
import type { AssertionContext } from "../evals/assertions/shared.js";

const PROMPTS: [string, string] = ["extract claims", "check claims"];

/** A matcher that returns the given scores in call order and records what it was called with. */
function scripted(scores: Array<number | Error>) {
  const calls: Array<{ query: string; output: string; context: string; threshold: number; grading: unknown }> = [];
  let next = 0;
  const matcher: FaithfulnessMatcher = async (query, output, context, threshold, grading) => {
    calls.push({ query, output, context, threshold, grading });
    const value = scores[next++];
    if (value === undefined) throw new Error("matcher called more often than scripted");
    if (value instanceof Error) throw value;
    return { pass: value >= threshold, score: value, reason: `Faithfulness ${value.toFixed(2)}` };
  };
  return { matcher, calls };
}

function context(overrides: Partial<AssertionContext> = {}): AssertionContext {
  return {
    vars: { query: "How much is the monthly fee?" },
    providerResponse: { output: { answer: "The fee is $5.", context: ["chunk one", "chunk two"] } },
    ...overrides,
  };
}

describe("median", () => {
  it("returns the middle score of an odd number of votes", () => {
    expect(median([1, 0.67, 1])).toBe(1);
    expect(median([0.67, 1, 0.67])).toBe(0.67);
    expect(median([0.5])).toBe(0.5);
  });

  it("does not reorder the caller's array", () => {
    const votes = [1, 0, 0.5];
    median(votes);
    expect(votes).toEqual([1, 0, 0.5]);
  });
});

describe("faithful-majority assertion", () => {
  it("passes when one vote of three wrongly rejects a faithful answer", async () => {
    const { matcher, calls } = scripted([1, 0.67, 1]);
    const outcome = await makeFaithfulMajority(matcher, PROMPTS)("The fee is $5.", context());
    expect(outcome.pass).toBe(true);
    expect(outcome.score).toBe(1);
    expect(calls).toHaveLength(3);
    expect(outcome.reason).toContain("1.00, 0.67, 1.00");
  });

  it("fails when two votes of three reject the answer", async () => {
    const { matcher } = scripted([0.67, 1, 0.67]);
    const outcome = await makeFaithfulMajority(matcher, PROMPTS)("The fee is $9.", context());
    expect(outcome.pass).toBe(false);
    expect(outcome.score).toBe(0.67);
  });

  it("counts a vote that throws as a rejection", async () => {
    const { matcher } = scripted([1, new Error("judge timed out"), 0.5]);
    const outcome = await makeFaithfulMajority(matcher, PROMPTS)("The fee is $5.", context());
    expect(outcome.pass).toBe(false);
    expect(outcome.score).toBe(0.5);
    expect(outcome.reason).toContain("judge timed out");
  });

  it("gives the judge the question, the answer, the joined context and both prompts", async () => {
    const { matcher, calls } = scripted([1, 1, 1]);
    const provider = { text: { id: "openrouter:openai/gpt-4.1-mini" } };
    await makeFaithfulMajority(matcher, PROMPTS)("The fee is $5.", context({ test: { options: { provider } } }));
    expect(calls[0]).toEqual({
      query: "How much is the monthly fee?",
      output: "The fee is $5.",
      context: "chunk one\n\nchunk two",
      threshold: 0.7,
      grading: { provider, rubricPrompt: PROMPTS },
    });
  });

  it("reads the context from the untransformed output when promptfoo has reduced the output to the answer", async () => {
    const { matcher, calls } = scripted([1, 1, 1]);
    const providerResponse = {
      output: "The fee is $5.",
      providerTransformedOutput: { answer: "The fee is $5.", context: ["raw one", "raw two"] },
    };
    const outcome = await makeFaithfulMajority(matcher, PROMPTS)("The fee is $5.", context({ providerResponse }));
    expect(outcome.pass).toBe(true);
    expect(calls[0]?.context).toBe("raw one\n\nraw two");
    expect(calls[0]?.output).toBe("The fee is $5.");
  });

  it("runs every vote through the vote runner, which is where the cache is bypassed", async () => {
    const { matcher, calls } = scripted([1, 1, 1]);
    let wrapped = 0;
    const runVote = <T>(vote: () => Promise<T>): Promise<T> => {
      wrapped++;
      return vote();
    };
    await makeFaithfulMajority(matcher, PROMPTS, runVote)("The fee is $5.", context());
    expect(wrapped).toBe(3);
    expect(calls).toHaveLength(3);
  });

  it("takes the number of votes and the threshold from the assertion config", async () => {
    const { matcher, calls } = scripted([0.6, 0.6, 0.6, 0.6, 0.6]);
    const outcome = await makeFaithfulMajority(matcher, PROMPTS)("answer", context({ config: { votes: 5, threshold: 0.5 } }));
    expect(calls).toHaveLength(5);
    expect(calls[0]?.threshold).toBe(0.5);
    expect(outcome.pass).toBe(true);
  });

  it("refuses an even number of votes, which has no middle", async () => {
    const { matcher } = scripted([]);
    await expect(makeFaithfulMajority(matcher, PROMPTS)("answer", context({ config: { votes: 4 } }))).rejects.toThrow(/odd/);
  });

  it("fails without calling the judge when the response carries no context", async () => {
    const { matcher, calls } = scripted([]);
    const outcome = await makeFaithfulMajority(matcher, PROMPTS)("answer", context({ providerResponse: { output: { answer: "answer" } } }));
    expect(outcome.pass).toBe(false);
    expect(calls).toHaveLength(0);
  });
});
