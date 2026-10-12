// Backend validation of the model's output (the second of three checks:
// strict schema at the model, this, then Swift in the app).
import { hasNoControlCharacters, LIMITS, ModelOutputSchema, type AstraContext, type AstraRequest, type AstraResponse } from "./schema.ts";

export type OutputRejection =
  | "schema"
  | "inconsistent_type"
  | "wrong_type_for_kind"
  | "text_too_long"
  | "unprovided_amount"
  | "note_authenticity"
  | "control_characters";

export type OutputValidation =
  | { ok: true; response: AstraResponse }
  | { ok: false; reason: OutputRejection };

/// Number words are refused outright so an amount can't slip past the
/// digit check ("twenty dirhams"). "one" is allowed: "one at a time".
const NUMBER_WORDS =
  /\b(zero|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|half|quarter)\b/iu;

/// Every way an amount from the context may be written: "17", "17.35",
/// "35" (cents), "17.00".
export function allowedNumbers(context: AstraContext): Set<string> {
  const allowed = new Set<string>();
  for (const value of [context.total, context.paid, context.expectedChange, context.receivedTotal]) {
    if (value === null) continue;
    const major = Math.floor(value / 100);
    const minor = value % 100;
    const cents = minor.toString().padStart(2, "0");
    allowed.add(major.toString());
    allowed.add(`${major}.${cents}`);
    if (minor > 0) {
      allowed.add(minor.toString());
      allowed.add(cents);
    }
  }
  return allowed;
}

/// True when `text` states only amounts the app sent. Grouping commas are
/// ignored ("1,000" = "1000").
export function mentionsOnlyProvidedAmounts(text: string, context: AstraContext): boolean {
  if (NUMBER_WORDS.test(text)) return false;
  const allowed = allowedNumbers(context);
  const numbers = text.match(/\d[\d,]*(?:\.\d+)?/gu) ?? [];
  return numbers.every((raw) => allowed.has(raw.replaceAll(",", "").replace(/\.$/u, "")));
}

/// Words that make a nearby number a money amount.
const MONEY_WORDS = new Set([
  "aed", "usd", "kes", "dirham", "dirhams", "dhs", "dh", "dollar", "dollars", "shilling", "shillings",
  "ksh", "kshs", "cent", "cents", "fils", "money", "change", "total", "paid", "pay", "price", "cost",
]);
const NUMBER_WORD_SET = new Set(
  "zero two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million half quarter".split(" "),
);

/// For general answers: ordinary numbers are fine ("you have two hands"),
/// but a number next to a money word or symbol must be one of the amounts
/// the app sent, and money may not be written in words ("twenty dollars").
export function mentionsOnlyProvidedMoney(text: string, context: AstraContext): boolean {
  const allowed = allowedNumbers(context);
  const tokens = text.match(/\$|\d[\d,]*(?:\.\d+)?|[A-Za-z]+/gu) ?? [];
  const isMoney = (index: number) => {
    const token = tokens[index]?.toLowerCase();
    return token !== undefined && (token === "$" || MONEY_WORDS.has(token));
  };
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index] ?? "";
    const nearMoney = [index - 2, index - 1, index + 1, index + 2].some(isMoney);
    if (!nearMoney) continue;
    if (/^\d/u.test(token) && !allowed.has(token.replaceAll(",", "").replace(/\.$/u, ""))) return false;
    if (NUMBER_WORD_SET.has(token.toLowerCase())) return false;
  }
  return true;
}

/// NaviNote never says whether a note is genuine; neither does Astra.
const AUTHENTICITY = /\b(genuine|counterfeit|fake|forged|forgery|authentic|real or fake)\b/iu;

export function validateModelOutput(raw: unknown, request: AstraRequest): OutputValidation {
  const parsed = ModelOutputSchema.safeParse(raw);
  if (!parsed.success) return { ok: false, reason: "schema" };
  const output = parsed.data;

  switch (output.type) {
    case "intent":
      if (output.intent === null) return { ok: false, reason: "inconsistent_type" };
      break;
    case "answer":
      if (output.intent !== null || output.text === null || output.text.trim() === "") {
        return { ok: false, reason: "inconsistent_type" };
      }
      break;
    case "general":
      if (output.intent !== null || output.text === null || output.text.trim() === "") {
        return { ok: false, reason: "inconsistent_type" };
      }
      break;
    case "unsupported":
      if (output.intent !== null) return { ok: false, reason: "inconsistent_type" };
      break;
  }
  // Interpreting a command yields an action or nothing, never prose.
  if (request.kind === "interpretCommand" && (output.type === "answer" || output.type === "general")) {
    return { ok: false, reason: "wrong_type_for_kind" };
  }

  const text = output.text?.trim() ?? null;
  if (text !== null) {
    if (text.length > LIMITS.replyChars) return { ok: false, reason: "text_too_long" };
    if (!hasNoControlCharacters(text, false)) return { ok: false, reason: "control_characters" };
    if (AUTHENTICITY.test(text)) return { ok: false, reason: "note_authenticity" };
    // Transaction answers may state only NaviNote's amounts; general
    // answers may use ordinary numbers but no unprovided money.
    const amountsOK = output.type === "general"
      ? mentionsOnlyProvidedMoney(text, request.context)
      : mentionsOnlyProvidedAmounts(text, request.context);
    if (!amountsOK) return { ok: false, reason: "unprovided_amount" };
  }

  return {
    ok: true,
    response: {
      requestId: request.requestId,
      sessionId: request.sessionId,
      type: output.type,
      intent: output.intent,
      text: text === "" ? null : text,
    },
  };
}
