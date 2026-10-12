// Request validation and output validation (the backend's two gates).
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AstraRequestSchema, ModelOutputSchema, type AstraRequest } from "../src/schema.ts";
import { allowedNumbers, mentionsOnlyProvidedAmounts, mentionsOnlyProvidedMoney, validateModelOutput } from "../src/validation.ts";
import { baseContext, validRequest } from "./helpers.ts";

const request = AstraRequestSchema.parse(validRequest());

function ask(overrides: Partial<AstraRequest["context"]> = {}, kind: AstraRequest["kind"] = "askQuestion"): AstraRequest {
  return { ...request, kind, context: { ...request.context, ...overrides } };
}

describe("request validation", () => {
  it("accepts a well-formed request", () => {
    assert.equal(AstraRequestSchema.safeParse(validRequest()).success, true);
  });

  const invalid: [string, Record<string, unknown>][] = [
    ["an unknown field", { extra: true }],
    ["a malformed request ID", { requestId: "abc" }],
    ["an unknown kind", { kind: "chat" }],
    ["an unknown screen", { screen: "settings" }],
    ["an empty transcript", { transcript: "   " }],
    ["a transcript over 300 characters", { transcript: "a".repeat(301) }],
    ["control characters", { transcript: "hi\u0007" }],
    ["an unknown context field", { context: { ...baseContext, creditCard: "4111" } }],
    ["amounts without a currency", { context: { ...baseContext, currency: null } }],
    ["a fractional amount", { context: { ...baseContext, total: 17.35 } }],
    ["a negative amount", { context: { ...baseContext, total: -1 } }],
    ["an implausible amount", { context: { ...baseContext, total: 100_000_001 } }],
    ["an unsupported currency", { context: { ...baseContext, currency: "EUR" } }],
  ];
  for (const [name, overrides] of invalid) {
    it(`rejects ${name}`, () => {
      assert.equal(AstraRequestSchema.safeParse(validRequest(overrides)).success, false);
    });
  }
});

describe("model output schema", () => {
  it("rejects intents outside the allowlist", () => {
    for (const intent of ["confirmTotal", "rejectTotal", "enterAmount", "pay", "confirm"]) {
      assert.equal(ModelOutputSchema.safeParse({ type: "intent", intent, text: null }).success, false, intent);
    }
  });
  it("rejects extra fields", () => {
    assert.equal(ModelOutputSchema.safeParse({ type: "unsupported", intent: null, text: null, amount: 5 }).success, false);
  });
});

describe("output validation", () => {
  it("accepts an allowlisted intent and adds the request's IDs", () => {
    const result = validateModelOutput({ type: "intent", intent: "repeat", text: null }, request);
    assert.deepEqual(result, {
      ok: true,
      response: { requestId: request.requestId, sessionId: request.sessionId, type: "intent", intent: "repeat", text: null },
    });
  });

  const cases: [string, unknown, AstraRequest, string][] = [
    ["not an object", "repeat", request, "schema"],
    ["intent type without an intent", { type: "intent", intent: null, text: null }, request, "inconsistent_type"],
    ["unsupported with an intent", { type: "unsupported", intent: "scan", text: null }, request, "inconsistent_type"],
    ["answer with an intent", { type: "answer", intent: "scan", text: "Scanning." }, ask(), "inconsistent_type"],
    ["an empty answer", { type: "answer", intent: null, text: "  " }, ask(), "inconsistent_type"],
    ["prose for a command", { type: "answer", intent: null, text: "Sure." }, request, "wrong_type_for_kind"],
    ["overlong text", { type: "answer", intent: null, text: "a".repeat(401) }, ask(), "text_too_long"],
    ["control characters", { type: "answer", intent: null, text: "ok\u0000" }, ask(), "control_characters"],
    ["an invented amount", { type: "answer", intent: null, text: "Your change is 2.65 USD." }, ask(), "unprovided_amount"],
    ["an amount in words", { type: "answer", intent: null, text: "You paid twenty dollars." }, ask(), "unprovided_amount"],
  ];
  for (const [name, output, req, reason] of cases) {
    it(`rejects ${name}`, () => {
      assert.deepEqual(validateModelOutput(output, req), { ok: false, reason });
    });
  }

  it("allows amounts that were provided, in any written form", () => {
    const context = ask({ total: 1735, paid: 2000, expectedChange: 265 }).context;
    assert.equal(mentionsOnlyProvidedAmounts("The total is 17.35 USD; you paid 20.", context), true);
    assert.equal(mentionsOnlyProvidedAmounts("Change: 2 dollars and 65 cents.", context), true);
    assert.equal(mentionsOnlyProvidedAmounts("Change: 3 dollars.", context), false);
    assert.equal(mentionsOnlyProvidedAmounts("Add one note at a time.", context), true);
  });

  it("builds allowed numbers from minor units", () => {
    assert.deepEqual([...allowedNumbers(ask({ total: 1000_00, paid: null, expectedChange: 5, receivedTotal: null }).context)].sort(),
      ["0", "0.05", "05", "1000", "1000.00", "5"].sort());
  });
});

describe("general answers (accessibility companion, approved 2026-10-09)", () => {
  const question = ask({ total: 1735, paid: 2000, expectedChange: 265 });

  it("accepts small talk and general knowledge for questions", () => {
    const result = validateModelOutput({ type: "general", intent: null, text: "I'm doing well, thanks for asking! How can I help?" }, question);
    assert.equal(result.ok, true);
    const facts = validateModelOutput({ type: "general", intent: null, text: "Most people have 2 hands and 10 fingers." }, question);
    assert.equal(facts.ok, true, "Ordinary numbers are fine in general answers");
  });

  it("never for commands", () => {
    assert.deepEqual(validateModelOutput({ type: "general", intent: null, text: "Hi!" }, request), { ok: false, reason: "wrong_type_for_kind" });
  });

  it("still refuses unprovided money, in digits or words", () => {
    for (const text of ["That costs about 40 dollars.", "You should get $5 back.", "Twenty dirhams is a lot.", "Your change is 3 USD."]) {
      assert.deepEqual(validateModelOutput({ type: "general", intent: null, text }, question), { ok: false, reason: "unprovided_amount" }, text);
    }
    assert.equal(validateModelOutput({ type: "general", intent: null, text: "NaviNote says your change is 2.65 USD." }, question).ok, true);
  });

  it("never discusses whether a note is genuine", () => {
    for (const text of ["That note looks genuine.", "Here is how to spot a counterfeit."]) {
      assert.deepEqual(validateModelOutput({ type: "general", intent: null, text }, question), { ok: false, reason: "note_authenticity" }, text);
    }
  });

  it("money guard looks only near money words and symbols", () => {
    const context = question.context;
    assert.equal(mentionsOnlyProvidedMoney("It's 25 degrees and 3 o'clock somewhere.", context), true);
    assert.equal(mentionsOnlyProvidedMoney("Paid 20 dollars.", context), true);
    assert.equal(mentionsOnlyProvidedMoney("Paid 21 dollars.", context), false);
    assert.equal(mentionsOnlyProvidedMoney("fifty dollars", context), false);
  });
});
