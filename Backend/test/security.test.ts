// Security properties: nothing sensitive reaches logs or responses, the
// OpenAI call uses the approved settings, and configuration fails closed.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { loadConfig, ConfigError } from "../src/config.ts";
import { createLogger } from "../src/log.ts";
import { MAX_OUTPUT_TOKENS, OpenAIAstraModel, type ResponsesClient } from "../src/model.ts";
import { deps, MockModel, post, startServer, validRequest } from "./helpers.ts";

const FAKE_KEY = "sk-proj-TESTONLY-not-a-real-key-0000000000"; // Fake; "TESTONLY" marks it for the secret scan.
const SENSITIVE = [
  "could you say that one more time", // transcript
  "17.35", "1735", // amounts
  "Scan the receipt", // last instruction
  "Bearer", FAKE_KEY, "sk-", // authorization / key material
  "You are Astra", // prompt
  "Starting", // model output text
];

describe("privacy-aware logging", () => {
  it("logs only safe fields for successful and failed requests", async () => {
    const server = await startServer(deps(new MockModel({ output: { type: "intent", intent: "scan", text: "Starting." } })));
    try {
      const headers = { authorization: `Bearer ${FAKE_KEY}` };
      await post(server.url, validRequest(), headers);
      await post(server.url, { ...validRequest(), transcript: "x".repeat(400) }, headers);
      await post(server.url, "{broken json 17.35", headers);
      assert.equal(server.lines.length, 3);
      for (const line of server.lines) {
        for (const secret of SENSITIVE) assert.equal(line.includes(secret), false, `log contains ${secret}: ${line}`);
        const keys = Object.keys(JSON.parse(line) as object);
        for (const key of keys) {
          assert.ok(["time", "event", "requestId", "status", "category", "detail", "ms", "inputTokens", "outputTokens"].includes(key), key);
        }
      }
    } finally {
      await server.close();
    }
  });

  it("drops attacker-chosen request IDs and free-text details", () => {
    const lines: string[] = [];
    const log = createLogger((line) => lines.push(line));
    log({ event: "request", requestId: "my transcript is here", detail: "Your change is 5 USD" });
    const entry = JSON.parse(lines[0] ?? "{}") as Record<string, unknown>;
    assert.equal(entry["requestId"], "invalid");
    assert.equal(entry["detail"], undefined);
  });
});

describe("responses never leak internals", () => {
  it("an upstream failure carrying the key returns only a category", async () => {
    const server = await startServer(deps(new MockModel({ throws: new Error(`Incorrect API key provided: ${FAKE_KEY}`) })));
    try {
      const response = await post(server.url, validRequest());
      const text = await response.text();
      assert.equal(text, JSON.stringify({ error: "upstream_error" }));
      for (const line of server.lines) assert.equal(line.includes(FAKE_KEY), false);
    } finally {
      await server.close();
    }
  });
});

describe("OpenAI call settings", () => {
  it("uses the Responses API with a strict schema, store: false, capped output, timeout and no retries", async () => {
    let captured: { body: Record<string, unknown>; options: Record<string, unknown> } | undefined;
    const client = {
      responses: {
        parse: (body: Record<string, unknown>, options: Record<string, unknown>) => {
          captured = { body, options };
          return Promise.resolve({
            status: "completed",
            output: [],
            output_parsed: { type: "intent", intent: "repeat", text: null },
            usage: { input_tokens: 10, output_tokens: 5 },
          });
        },
      },
    } as unknown as ResponsesClient;
    const model = new OpenAIAstraModel(client, "gpt-6-astra");
    const signal = new AbortController().signal;
    const result = await model.respond({ instructions: "i", input: "x", signal, timeoutMs: 8000 });

    assert.deepEqual(result, { kind: "output", output: { type: "intent", intent: "repeat", text: null }, inputTokens: 10, outputTokens: 5 });
    assert.ok(captured);
    assert.equal(captured.body["model"], "gpt-6-astra");
    assert.equal(captured.body["store"], false);
    assert.equal(captured.body["max_output_tokens"], MAX_OUTPUT_TOKENS);
    const format = (captured.body["text"] as { format: { type: string; strict: boolean; schema: { additionalProperties: boolean } } }).format;
    assert.equal(format.type, "json_schema");
    assert.equal(format.strict, true);
    assert.equal(format.schema.additionalProperties, false);
    assert.equal(captured.options["signal"], signal);
    assert.equal(captured.options["timeout"], 8000);
    assert.equal(captured.options["maxRetries"], 0);
  });

  it("maps refusals and incomplete responses", async () => {
    const reply = (response: unknown) =>
      new OpenAIAstraModel({ responses: { parse: () => Promise.resolve(response) } } as unknown as ResponsesClient, "m");
    const args = { instructions: "", input: "", signal: new AbortController().signal, timeoutMs: 1 };
    const refused = await reply({ status: "completed", output: [{ type: "message", content: [{ type: "refusal", refusal: "no" }] }], output_parsed: null }).respond(args);
    assert.deepEqual(refused, { kind: "refusal" });
    const incomplete = await reply({ status: "incomplete", output: [], output_parsed: null }).respond(args);
    assert.deepEqual(incomplete, { kind: "incomplete" });
  });
});

describe("configuration fails closed", () => {
  it("refuses to start enabled without a key", () => {
    assert.throws(() => loadConfig({}), ConfigError);
  });

  it("starts disabled without a key", () => {
    const { config, apiKey } = loadConfig({ ASTRA_ENABLED: "false" });
    assert.equal(config.enabled, false);
    assert.equal(apiKey, null);
  });

  it("refuses to pretend App Attest is enforced", () => {
    assert.throws(() => loadConfig({ OPENAI_API_KEY: FAKE_KEY, ASTRA_REQUIRE_APP_ATTEST: "true" }), /not implemented/u);
  });

  it("keeps the key out of the config object and out of error messages", () => {
    const { config, apiKey } = loadConfig({ OPENAI_API_KEY: FAKE_KEY, ASTRA_MODEL: "gpt-6-astra" });
    assert.equal(apiKey, FAKE_KEY);
    assert.equal(JSON.stringify(config).includes("sk-"), false);
    try {
      loadConfig({ OPENAI_API_KEY: FAKE_KEY, ASTRA_PORT: "not-a-port" });
      assert.fail("expected a ConfigError");
    } catch (error) {
      assert.ok(error instanceof ConfigError);
      assert.equal(error.message.includes(FAKE_KEY), false);
      assert.match(error.message, /ASTRA_PORT/u);
    }
  });

  it("defaults to the approved model, localhost and a daily cap", () => {
    const { config } = loadConfig({ OPENAI_API_KEY: FAKE_KEY });
    assert.deepEqual([config.model, config.host, config.enabled, config.dailyCap], ["gpt-6-astra", "127.0.0.1", true, 300]);
  });
});
