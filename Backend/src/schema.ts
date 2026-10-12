// The Astra contract: what the app may send, what the model may return,
// and what the backend returns. Everything is closed: unknown fields,
// unknown enum values and oversized strings are rejected.
import { z } from "zod";

export const CURRENCIES = ["AED", "USD", "KES"] as const;

/// Non-financial actions Astra may *propose*. The app maps each to a
/// NaviNote action and its state machine decides whether it applies.
/// Nothing here confirms, rejects, enters or changes an amount.
export const INTENTS = [
  "repeat",
  "help",
  "scan",
  "stopScan",
  "cancel",
  "startCheckout",
  "startReadingCurrency",
  "startVerifyChange",
  "removeLastNote",
] as const;

export const KINDS = ["interpretCommand", "askQuestion", "explainScreen"] as const;

/// The app's state-machine phase names (`NaviNoteState.Phase.logName`).
export const SCREENS = [
  "home",
  "checkoutIntroduction",
  "acquiringTotal",
  "confirmingTotal",
  "acquiringPaymentNote",
  "confirmingPaymentNote",
  "showingExpectedChange",
  "settingExpectedChange",
  "confirmingExpectedChange",
  "collectingReturnedChange",
  "confirmingReturnedNote",
  "exactChange",
  "shortChange",
  "excessiveChange",
  "unresolvedChange",
  "readingCurrency",
  "askingNaviNote",
  "recoverableError",
  "permissionDenied",
] as const;

export const LIMITS = {
  bodyBytes: 4096,
  transcriptChars: 300,
  instructionChars: 300,
  replyChars: 400,
  /** Minor units: 1,000,000 in major units. */
  maxAmount: 100_000_000,
} as const;

const id = z.uuid();
const amount = z.number().int().min(0).max(LIMITS.maxAmount).nullable();
/// True unless `value` has control characters other than tab, line feed
/// and carriage return.
export function hasNoControlCharacters(value: string, allowLineBreaks = true): boolean {
  for (const character of value) {
    const code = character.codePointAt(0) ?? 0;
    const lineBreak = code === 0x09 || code === 0x0a || code === 0x0d;
    if ((code < 0x20 && !(allowLineBreaks && lineBreak)) || code === 0x7f) return false;
  }
  return true;
}
const noControlCharacters = (value: string) => hasNoControlCharacters(value);

export const AstraContextSchema = z
  .strictObject({
    currency: z.enum(CURRENCIES).nullable(),
    total: amount,
    paid: amount,
    expectedChange: amount,
    receivedTotal: amount,
    lastInstruction: z.string().max(LIMITS.instructionChars).refine(noControlCharacters).nullable(),
  })
  .refine(
    (context) =>
      context.currency !== null ||
      [context.total, context.paid, context.expectedChange, context.receivedTotal].every((value) => value === null),
    { message: "amounts need a currency" },
  );

export const AstraRequestSchema = z.strictObject({
  requestId: id,
  sessionId: id,
  installId: id,
  kind: z.enum(KINDS),
  screen: z.enum(SCREENS),
  transcript: z.string().trim().min(1).max(LIMITS.transcriptChars).refine(noControlCharacters),
  context: AstraContextSchema,
});

export type AstraRequest = z.infer<typeof AstraRequestSchema>;
export type AstraContext = z.infer<typeof AstraContextSchema>;
export type AstraIntent = (typeof INTENTS)[number];

/// What the model must return (strict Structured Output). The backend adds
/// the request and session IDs; the model never sees or echoes them.
/// `answer`: about this transaction or NaviNote. `general`: any other
/// topic (accessibility companion, approved 2026-10-09), labelled as such
/// in the app.
export const ModelOutputSchema = z.strictObject({
  type: z.enum(["intent", "answer", "general", "unsupported"]),
  intent: z.enum(INTENTS).nullable(),
  text: z.string().nullable(),
});

export type ModelOutput = z.infer<typeof ModelOutputSchema>;

/// What the backend returns to the app.
export interface AstraResponse {
  requestId: string;
  sessionId: string;
  type: ModelOutput["type"];
  intent: AstraIntent | null;
  text: string | null;
}
