// Cloud banknote recognition: request validation, output validation,
// limits, privacy-safe logging. Mocked model: no key, no network.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  banknoteInstructions,
  BanknoteRequestSchema,
  validateBanknoteOutput,
  type BanknoteModel,
  type BanknoteModelResult,
} from "../src/banknote.ts";
import { handleBanknote } from "../src/handler.ts";
import { DailyCap, standardLimits } from "../src/limits.ts";
import { deps, MockModel, noSignal, startServer } from "./helpers.ts";

const IMAGE = "/9j/" + "A".repeat(400); // Not a real JPEG; the mock never looks.

function banknoteRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    requestId: "11111111-1111-4111-8111-111111111111",
    sessionId: "22222222-2222-4222-8222-222222222222",
    installId: "33333333-3333-4333-8333-333333333333",
    consent: true,
    purpose: "currencyReading",
    mode: "withText",
    expectedCurrency: null,
    image: { mimeType: "image/jpeg", base64: IMAGE },
    ...overrides,
  };
}

const goodOutput = {
  isBanknote: true,
  currency: "AED",
  denomination: 50,
  side: "front",
  evidence: ["purple colour scheme", "falcon illustration"],
  usedPrintedValue: false,
  uncertainty: "low",
};

class MockBanknoteModel implements BanknoteModel {
  calls: { instructions: string; expectedCurrency: string | null }[] = [];
  private readonly result: BanknoteModelResult;
  constructor(result: BanknoteModelResult = { kind: "output", output: goodOutput, inputTokens: 900, outputTokens: 60 }) {
    this.result = result;
  }
  recognise(args: { instructions: string; expectedCurrency: string | null }): Promise<BanknoteModelResult> {
    this.calls.push({ instructions: args.instructions, expectedCurrency: args.expectedCurrency });
    return Promise.resolve(this.result);
  }
}

const meta = { address: "127.0.0.1", headers: {}, signal: noSignal };
const request = BanknoteRequestSchema.parse(banknoteRequest());

describe("banknote request validation", () => {
  it("requires explicit consent", () => {
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ consent: false })).success, false);
    assert.equal(BanknoteRequestSchema.safeParse({ ...banknoteRequest(), consent: undefined }).success, false);
  });
  it("accepts only base64 JPEG of bounded size", () => {
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ image: { mimeType: "image/png", base64: IMAGE } })).success, false);
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ image: { mimeType: "image/jpeg", base64: "not base64!" + IMAGE } })).success, false);
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ image: { mimeType: "image/jpeg", base64: "A".repeat(1_900_001) } })).success, false);
  });
  it("requires a known mode", () => {
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ mode: "guess" })).success, false);
    assert.equal(BanknoteRequestSchema.safeParse({ ...banknoteRequest(), mode: undefined }).success, false);
  });
  it("rejects unknown fields and currencies", () => {
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ extra: 1 })).success, false);
    assert.equal(BanknoteRequestSchema.safeParse(banknoteRequest({ expectedCurrency: "EUR" })).success, false);
  });
});

describe("banknote output validation", () => {
  it("accepts a real note value and adds IDs and the method", () => {
    const result = validateBanknoteOutput(goodOutput, request);
    assert.ok(result.ok);
    assert.equal(result.response.method, "cloudVision");
    assert.equal(result.response.requestId, request.requestId);
    assert.equal(result.response.denomination, 50);
  });
  const bad: [string, Record<string, unknown>, string][] = [
    ["a value that isn't an AED note", { denomination: 25 }, "unapproved_value"],
    ["a USD value for AED", { denomination: 2 }, "unapproved_value"],
    ["a denomination with unknown currency", { currency: "unknown", denomination: 10 }, "inconsistent"],
    ["a denomination for a non-note", { isBanknote: false, denomination: 10 }, "inconsistent"],
    ["too much evidence", { evidence: ["a", "b", "c", "d", "e", "f"] }, "evidence"],
    ["empty evidence item", { evidence: [" "] }, "evidence"],
    ["authenticity claims", { evidence: ["looks genuine"] }, "note_authenticity"],
    ["a fractional denomination", { denomination: 10.5 }, "schema"],
    ["extra fields", { confidencePercent: 97 }, "schema"],
  ];
  for (const [name, change, reason] of bad) {
    it(`rejects ${name}`, () => {
      assert.deepEqual(validateBanknoteOutput({ ...goodOutput, ...change }, request), { ok: false, reason });
    });
  }
  it("allows 'not sure': no denomination with high uncertainty", () => {
    assert.equal(validateBanknoteOutput({ ...goodOutput, denomination: null, uncertainty: "high" }, request).ok, true);
  });
});

describe("banknote handler", () => {
  it("returns the validated reading", async () => {
    const model = new MockBanknoteModel();
    const outcome = await handleBanknote(banknoteRequest(), meta, { ...deps(new MockModel()), banknoteModel: model });
    assert.equal(outcome.status, 200);
    assert.equal((outcome.body as { denomination: number }).denomination, 50);
    assert.equal(model.calls[0]?.expectedCurrency, null);
  });
  it("is disabled when not configured or switched off", async () => {
    assert.equal((await handleBanknote(banknoteRequest(), meta, deps(new MockModel()))).status, 503);
    const off = { ...deps(new MockModel(), { config: { enabled: false } }), banknoteModel: new MockBanknoteModel() };
    assert.equal((await handleBanknote(banknoteRequest(), meta, off)).status, 503);
  });
  it("stops at the daily photo cap", async () => {
    const limits = standardLimits(1000);
    limits.imageDaily = new DailyCap(1);
    const d = { ...deps(new MockModel(), { limits }), banknoteModel: new MockBanknoteModel() };
    assert.equal((await handleBanknote(banknoteRequest(), meta, d)).status, 200);
    const capped = await handleBanknote(banknoteRequest(), meta, d);
    assert.deepEqual([capped.status, capped.body], [503, { error: "capacity" }]);
  });
  it("appearance mode tells the model to ignore printed values", async () => {
    const model = new MockBanknoteModel();
    await handleBanknote(banknoteRequest({ mode: "appearance" }), meta, { ...deps(new MockModel()), banknoteModel: model });
    assert.match(model.calls[0]?.instructions ?? "", /Do NOT read or use any printed numerals/u);
    assert.doesNotMatch(banknoteInstructions(false), /Do NOT read/u);
  });
  it("reports invalid model output safely", async () => {
    const model = new MockBanknoteModel({ kind: "output", output: { ...goodOutput, denomination: 25 }, inputTokens: 1, outputTokens: 1 });
    const outcome = await handleBanknote(banknoteRequest(), meta, { ...deps(new MockModel()), banknoteModel: model });
    assert.deepEqual([outcome.status, outcome.body, outcome.detail], [502, { error: "invalid_model_output" }, "unapproved_value"]);
  });
});

describe("banknote HTTP contract and privacy", () => {
  it("serves /v1/banknote, accepts photos up to 2 MB, and never logs the image", async () => {
    const server = await startServer({ ...deps(new MockModel()), banknoteModel: new MockBanknoteModel() });
    try {
      const response = await fetch(`${server.url}/v1/banknote`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(banknoteRequest({ image: { mimeType: "image/jpeg", base64: "A".repeat(1_000_000) } })),
      });
      assert.equal(response.status, 200);
      const tooBig = await fetch(`${server.url}/v1/banknote`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(banknoteRequest({ image: { mimeType: "image/jpeg", base64: "A".repeat(2_100_000) } })),
      });
      assert.equal(tooBig.status, 413);
      for (const line of server.lines) {
        assert.equal(line.includes("AAAAAAAA"), false, "image data in the log");
        assert.equal(line.includes("falcon"), false, "model evidence in the log");
      }
    } finally {
      await server.close();
    }
  });
});
