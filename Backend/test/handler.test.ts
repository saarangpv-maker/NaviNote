// The request pipeline with a mocked model: limits, switch, timeout,
// cancellation, refusals and safe failures.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { handleAstra } from "../src/handler.ts";
import { DailyCap, SlidingWindowLimiter, standardLimits } from "../src/limits.ts";
import { INSTRUCTIONS } from "../src/prompt.ts";
import { deps, MockModel, noSignal, validRequest } from "./helpers.ts";

const meta = { address: "127.0.0.1", headers: {}, signal: noSignal };

describe("handler", () => {
  it("returns a validated intent with the request's IDs", async () => {
    const outcome = await handleAstra(validRequest(), meta, deps(new MockModel()));
    assert.equal(outcome.status, 200);
    assert.deepEqual(outcome.body, {
      requestId: "11111111-1111-4111-8111-111111111111",
      sessionId: "22222222-2222-4222-8222-222222222222",
      type: "intent",
      intent: "repeat",
      text: null,
    });
  });

  it("sends only confirmed facts and the transcript to the model — no IDs", async () => {
    const model = new MockModel();
    await handleAstra(validRequest(), meta, deps(model));
    const call = model.calls[0];
    assert.ok(call);
    assert.equal(call.instructions, INSTRUCTIONS);
    assert.match(call.input, /Confirmed total: 17\.35 USD/u);
    assert.match(call.input, /"could you say that one more time"/u);
    for (const id of ["11111111", "22222222", "33333333"]) assert.equal(call.input.includes(id), false);
  });

  it("refuses everything when switched off, without calling the model", async () => {
    const model = new MockModel();
    const outcome = await handleAstra(validRequest(), meta, deps(model, { config: { enabled: false } }));
    assert.deepEqual([outcome.status, outcome.body], [503, { error: "disabled" }]);
    assert.equal(model.calls.length, 0);
  });

  it("rejects invalid requests without calling the model", async () => {
    const model = new MockModel();
    const outcome = await handleAstra({ ...validRequest(), kind: "chat" }, meta, deps(model));
    assert.deepEqual([outcome.status, outcome.body], [400, { error: "invalid_request" }]);
    assert.equal(model.calls.length, 0);
  });

  it("rate-limits per install", async () => {
    const limits = standardLimits(1000);
    limits.perInstall = new SlidingWindowLimiter({ limit: 2, windowMs: 60_000 });
    const d = deps(new MockModel(), { limits });
    assert.equal((await handleAstra(validRequest(), meta, d)).status, 200);
    assert.equal((await handleAstra(validRequest(), meta, d)).status, 200);
    const limited = await handleAstra(validRequest(), meta, d);
    assert.deepEqual([limited.status, limited.body], [429, { error: "rate_limited" }]);
    assert.ok((limited.retryAfterSeconds ?? 0) >= 1);
    // A different install is unaffected.
    const other = await handleAstra(validRequest({ installId: "44444444-4444-4444-8444-444444444444" }), meta, d);
    assert.equal(other.status, 200);
  });

  it("rate-limits per address", async () => {
    const limits = standardLimits(1000);
    limits.perAddress = new SlidingWindowLimiter({ limit: 1, windowMs: 60_000 });
    const d = deps(new MockModel(), { limits });
    await handleAstra(validRequest(), meta, d);
    const other = validRequest({ installId: "44444444-4444-4444-8444-444444444444" });
    assert.equal((await handleAstra(other, meta, d)).status, 429);
  });

  it("stops at the daily cap", async () => {
    const limits = standardLimits(1000);
    limits.daily = new DailyCap(1);
    const model = new MockModel();
    const d = deps(model, { limits });
    assert.equal((await handleAstra(validRequest(), meta, d)).status, 200);
    const capped = await handleAstra(validRequest(), meta, d);
    assert.deepEqual([capped.status, capped.body], [503, { error: "capacity" }]);
    assert.equal(model.calls.length, 1);
  });

  it("times out a slow model", async () => {
    const outcome = await handleAstra(validRequest(), meta, deps(new MockModel({ hang: true }), { config: { modelTimeoutMs: 50 } }));
    assert.deepEqual([outcome.status, outcome.body], [504, { error: "timeout" }]);
  });

  it("aborts the model call when the client goes away", async () => {
    const client = new AbortController();
    const pending = handleAstra(validRequest(), { ...meta, signal: client.signal }, deps(new MockModel({ hang: true }), { config: { modelTimeoutMs: 5000 } }));
    setTimeout(() => {
      client.abort();
    }, 20);
    const outcome = await pending;
    assert.equal(outcome.category, "cancelled");
  });

  it("reports refusals, incomplete and invalid output as safe errors", async () => {
    const refused = await handleAstra(validRequest(), meta, deps(new MockModel({ result: { kind: "refusal" } })));
    assert.deepEqual([refused.status, refused.body], [502, { error: "refused" }]);
    const incomplete = await handleAstra(validRequest(), meta, deps(new MockModel({ result: { kind: "incomplete" } })));
    assert.deepEqual([incomplete.status, incomplete.body], [502, { error: "invalid_model_output" }]);
    const invalid = await handleAstra(validRequest(), meta, deps(new MockModel({ output: { type: "intent", intent: "confirmTotal", text: null } })));
    assert.deepEqual([invalid.status, invalid.body, invalid.detail], [502, { error: "invalid_model_output" }, "schema"]);
  });

  it("never surfaces an upstream error's message", async () => {
    const outcome = await handleAstra(validRequest(), meta, deps(new MockModel({ throws: new Error("401 Incorrect API key sk-live-abc") })));
    assert.deepEqual([outcome.status, outcome.body], [502, { error: "upstream_error" }]);
    assert.equal(JSON.stringify(outcome).includes("sk-live"), false);
  });

  it("refuses when an attestation verifier rejects the client", async () => {
    const outcome = await handleAstra(validRequest(), meta, deps(new MockModel(), {
      attestation: { verify: () => Promise.resolve({ status: "rejected" }) },
    }));
    assert.equal(outcome.status, 400);
  });
});

describe("limits", () => {
  it("sliding window frees capacity as time passes", () => {
    let now = 0;
    const limiter = new SlidingWindowLimiter({ limit: 1, windowMs: 1000, now: () => now });
    assert.equal(limiter.take("a").allowed, true);
    assert.equal(limiter.take("a").allowed, false);
    now = 1001;
    assert.equal(limiter.take("a").allowed, true);
  });

  it("bounds the number of tracked keys", () => {
    const limiter = new SlidingWindowLimiter({ limit: 1, windowMs: 1000, maxKeys: 2, now: () => 0 });
    limiter.take("a");
    limiter.take("b");
    limiter.take("c");
    // "a" was evicted, so it is allowed again.
    assert.equal(limiter.take("a").allowed, true);
  });

  it("daily cap resets on a new UTC day", () => {
    let now = Date.UTC(2026, 8, 26, 23, 59);
    const cap = new DailyCap(1, () => now);
    assert.equal(cap.take(), true);
    assert.equal(cap.take(), false);
    now = Date.UTC(2026, 8, 27, 0, 1);
    assert.equal(cap.take(), true);
  });
});
