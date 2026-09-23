/**
 * Process entry point: read the environment, index the corpus once, serve on 0.0.0.0:PORT.
 *
 *   OPENROUTER_API_KEY   required for /ask; without it the app starts but /readyz is 503
 *   SUT_MODEL            OpenRouter model id (default google/gemini-2.5-flash)
 *   PORT                 default 8080
 *   GIT_SHA, BUILD_TIME  injected at image build
 *   CONTAINER_APP_REVISION  set by Azure Container Apps
 */
import { createApp } from "./app.js";
import { createOpenRouterClient } from "./assistant/openrouter.js";
import { createFixtureStore } from "./fixtures/customers.js";
import { loadCorpus } from "./retrieval/chunk.js";
import { createBm25Retriever } from "./retrieval/retriever.js";

const port = Number(process.env.PORT ?? 8080);
const model = process.env.SUT_MODEL ?? "google/gemini-2.5-flash";
const apiKey = process.env.OPENROUTER_API_KEY;
const corpusDir = process.env.CORPUS_DIR ?? "corpus";

const chunks = loadCorpus(corpusDir);
const app = createApp({
  retriever: createBm25Retriever(chunks),
  store: createFixtureStore(),
  llm: apiKey ? createOpenRouterClient({ apiKey, title: "corella-assistant" }) : null,
  model,
  retrieval: { k: 6, minScore: 0 },
  maxToolRounds: 3,
  maxTokens: 600,
  version: {
    service: "corella-assistant",
    gitSha: process.env.GIT_SHA ?? "dev",
    buildTime: process.env.BUILD_TIME ?? "unknown",
    revision: process.env.CONTAINER_APP_REVISION ?? "local",
    model,
  },
});

Bun.serve({ port, hostname: "0.0.0.0", fetch: app.fetch });

console.log(
  JSON.stringify({
    ts: new Date().toISOString(),
    event: "listening",
    port,
    chunks: chunks.length,
    ready: app.ready,
    model,
    revision: process.env.CONTAINER_APP_REVISION ?? "local",
  }),
);
