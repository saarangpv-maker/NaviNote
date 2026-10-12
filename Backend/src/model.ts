// The one place that talks to OpenAI: the Responses API with a strict
// Structured Output, store: false, capped output, a timeout and no
// retries. Tests replace `AstraModel` with a mock; no key or network.
import type OpenAI from "openai";
import { zodTextFormat } from "openai/helpers/zod";
import { ModelOutputSchema } from "./schema.ts";

export type ModelResult =
  | { kind: "output"; output: unknown; inputTokens: number | null; outputTokens: number | null }
  | { kind: "refusal" }
  | { kind: "incomplete" };

export interface AstraModel {
  respond(args: { instructions: string; input: string; signal: AbortSignal; timeoutMs: number }): Promise<ModelResult>;
}

/// The subset of the OpenAI client this adapter uses, so tests can check
/// the exact parameters without a network call.
export type ResponsesClient = Pick<OpenAI, "responses">;

export const MAX_OUTPUT_TOKENS = 300;

export class OpenAIAstraModel implements AstraModel {
  readonly #client: ResponsesClient;
  readonly #model: string;

  constructor(client: ResponsesClient, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async respond(args: { instructions: string; input: string; signal: AbortSignal; timeoutMs: number }): Promise<ModelResult> {
    const response = await this.#client.responses.parse(
      {
        model: this.#model,
        instructions: args.instructions,
        input: args.input,
        text: { format: zodTextFormat(ModelOutputSchema, "astra_reply") },
        store: false,
        max_output_tokens: MAX_OUTPUT_TOKENS,
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
