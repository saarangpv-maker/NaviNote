// Cloud banknote recognition (hybrid recognition prototype, approved
// 2026-10-09): one photo, recognised by its overall visual appearance with
// printed text only as supporting evidence. The image is never stored
// (store: false) or logged. Results are proposals: the app decides, using
// thresholds measured on real test photos — never this model's own words.
import { z } from "zod";
import type OpenAI from "openai";
import { zodTextFormat } from "openai/helpers/zod";
import { CURRENCIES } from "./schema.ts";

export const APPROVED_VALUES: Record<(typeof CURRENCIES)[number], readonly number[]> = {
  AED: [5, 10, 20, 50, 100, 200, 500, 1000],
  USD: [1, 2, 5, 10, 20, 50, 100],
  KES: [50, 100, 200, 500, 1000],
};

export const BANKNOTE_LIMITS = {
  /** Request body: a downscaled JPEG as base64, plus a little JSON. */
  bodyBytes: 2_000_000,
  imageBase64Chars: 1_900_000,
  evidenceItems: 5,
  evidenceChars: 100,
} as const;

const id = z.uuid();

export const BanknoteRequestSchema = z.strictObject({
  requestId: id,
  sessionId: id,
  installId: id,
  /// The person turned on image uploads. The app sends nothing otherwise.
  consent: z.literal(true),
  purpose: z.enum(["currencyReading", "paymentNote", "returnedNote", "evaluation"]),
  /// "appearance": the model is told not to use printed numerals at all.
  /// The app reads each note both ways and requires agreement (measured
  /// 2026-10-11, Documentation/BANKNOTE_EVAL.md).
  mode: z.enum(["appearance", "withText"]),
  /// The transaction's confirmed currency, if any (never a guess).
  expectedCurrency: z.enum(CURRENCIES).nullable(),
  image: z.strictObject({
    mimeType: z.literal("image/jpeg"),
    base64: z.string().min(100).max(BANKNOTE_LIMITS.imageBase64Chars).regex(/^[A-Za-z0-9+/]+={0,2}$/u),
  }),
});
export type BanknoteRequest = z.infer<typeof BanknoteRequestSchema>;

/// What the model must return (strict Structured Output).
export const BanknoteOutputSchema = z.strictObject({
  isBanknote: z.boolean(),
  currency: z.enum([...CURRENCIES, "unknown"]),
  denomination: z.number().int().nullable(),
  side: z.enum(["front", "back", "unknown"]),
  /// Short visual reasons: colours, portraits/illustrations, patterns, layout.
  evidence: z.array(z.string()),
  /// Whether legible printed value text or numerals were used.
  usedPrintedValue: z.boolean(),
  uncertainty: z.enum(["low", "medium", "high"]),
});
export type BanknoteOutput = z.infer<typeof BanknoteOutputSchema>;

export interface BanknoteResponse extends BanknoteOutput {
  requestId: string;
  sessionId: string;
  method: "cloudVision";
}

export type BanknoteRejection = "schema" | "inconsistent" | "unapproved_value" | "evidence" | "note_authenticity";

const AUTHENTICITY = /\b(genuine|counterfeit|fake|forged|forgery|authentic)\b/iu;

/// Second check (after the strict schema): the value must be a real note of
/// that currency, the fields must agree, and the evidence must be short and
/// never about authenticity.
export function validateBanknoteOutput(
  raw: unknown,
  request: BanknoteRequest,
): { ok: true; response: BanknoteResponse } | { ok: false; reason: BanknoteRejection } {
  const parsed = BanknoteOutputSchema.safeParse(raw);
  if (!parsed.success) return { ok: false, reason: "schema" };
  const output = parsed.data;
  if (!output.isBanknote || output.currency === "unknown") {
    if (output.denomination !== null) return { ok: false, reason: "inconsistent" };
  } else if (output.denomination !== null && !APPROVED_VALUES[output.currency].includes(output.denomination)) {
    return { ok: false, reason: "unapproved_value" };
  }
  if (
    output.evidence.length > BANKNOTE_LIMITS.evidenceItems ||
    output.evidence.some((item) => item.trim() === "" || item.length > BANKNOTE_LIMITS.evidenceChars)
  ) {
    return { ok: false, reason: "evidence" };
  }
  if (output.evidence.some((item) => AUTHENTICITY.test(item))) return { ok: false, reason: "note_authenticity" };
  return {
    ok: true,
    response: {
      requestId: request.requestId,
      sessionId: request.sessionId,
      method: "cloudVision",
      ...output,
      evidence: output.evidence.map((item) => item.trim()),
    },
  };
}

export function banknoteInstructions(ignorePrintedValue: boolean): string {
  return `You identify banknotes in a photo for NaviNote, an app for blind and visually impaired people. Supported: UAE dirham (AED: 5, 10, 20, 50, 100, 200, 500, 1000), US dollar (USD: 1, 2, 5, 10, 20, 50, 100), Kenyan shilling (KES: 50, 100, 200, 500, 1000). Coins are not supported.

Identify the note from its overall visual appearance: colour scheme, portraits and illustrations, patterns, security-thread and watermark areas, layout and size proportions. ${ignorePrintedValue
    ? "Do NOT read or use any printed numerals or value words, even if visible: decide from appearance alone, and set usedPrintedValue to false."
    : "Printed numerals and value words are supporting evidence only; set usedPrintedValue to true only if you could read them and they informed the answer."}

Rules:
- If there is no single banknote clearly in view, set isBanknote false, currency "unknown", denomination null.
- If you are not sure of the denomination, set denomination null and uncertainty "high". Never guess.
- uncertainty: "low" only when several independent visual features agree; "medium" when they mostly agree; "high" otherwise.
- evidence: up to 5 short phrases naming the visual features you relied on.
- Never say or imply whether a note is genuine, real, fake or counterfeit.`;
}

export type BanknoteModelResult =
  | { kind: "output"; output: unknown; inputTokens: number | null; outputTokens: number | null }
  | { kind: "refusal" }
  | { kind: "incomplete" };

export interface BanknoteModel {
  recognise(args: {
    instructions: string;
    imageBase64: string;
    expectedCurrency: string | null;
    signal: AbortSignal;
    timeoutMs: number;
  }): Promise<BanknoteModelResult>;
}

/// Room for the model's reasoning plus the answer: at 400, hard photos (folded,
/// hand-held) came back incomplete in the 2026-10-11 evaluation.
export const BANKNOTE_MAX_OUTPUT_TOKENS = 2000;

export class OpenAIBanknoteModel implements BanknoteModel {
  readonly #client: Pick<OpenAI, "responses">;
  readonly #model: string;

  constructor(client: Pick<OpenAI, "responses">, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async recognise(args: {
    instructions: string;
    imageBase64: string;
    expectedCurrency: string | null;
    signal: AbortSignal;
    timeoutMs: number;
  }): Promise<BanknoteModelResult> {
    const hint = args.expectedCurrency === null
      ? "The transaction currency is not confirmed."
      : `The transaction is in ${args.expectedCurrency}; still report what you actually see.`;
    const response = await this.#client.responses.parse(
      {
        model: this.#model,
        instructions: args.instructions,
        input: [
          {
            role: "user",
            content: [
              { type: "input_text", text: `Identify the banknote in this photo. ${hint}` },
              { type: "input_image", image_url: `data:image/jpeg;base64,${args.imageBase64}`, detail: "auto" },
            ],
          },
        ],
        text: { format: zodTextFormat(BanknoteOutputSchema, "banknote_reading") },
        store: false,
        max_output_tokens: BANKNOTE_MAX_OUTPUT_TOKENS,
      },
      { signal: args.signal, timeout: args.timeoutMs, maxRetries: 0 },
    );
    if (response.status === "incomplete") return { kind: "incomplete" };
    const refused = response.output.some(
      (item) => item.type === "message" && item.content.some((part) => part.type === "refusal"),
    );
    if (refused) return { kind: "refusal" };
    return {
      kind: "output",
      output: response.output_parsed,
      inputTokens: response.usage?.input_tokens ?? null,
      outputTokens: response.usage?.output_tokens ?? null,
    };
  }
}
