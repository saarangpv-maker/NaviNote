// One Astra request, from parsed JSON to a safe outcome. No HTTP here, so
// every rule is unit-testable with a mocked model.
import type { IncomingHttpHeaders } from "node:http";
import type { ClientAttestationVerifier } from "./attestation.ts";
import type { Config } from "./config.ts";
import type { Limits } from "./limits.ts";
import type { Category } from "./log.ts";
import type { AstraModel } from "./model.ts";
import {
  banknoteInstructions,
  BanknoteRequestSchema,
  validateBanknoteOutput,
  type BanknoteModel,
  type BanknoteResponse,
} from "./banknote.ts";
import { buildInput, INSTRUCTIONS } from "./prompt.ts";
import { AstraRequestSchema, type AstraResponse } from "./schema.ts";
import { validateModelOutput } from "./validation.ts";

export interface Deps {
  config: Config;
  model: AstraModel;
  limits: Limits;
  attestation: ClientAttestationVerifier;
  /** Cloud banknote recognition; absent when not configured. */
  banknoteModel?: BanknoteModel;
}

export interface Outcome {
  status: number;
  body: AstraResponse | BanknoteResponse | { error: Category };
  category: Category;
  detail?: string;
  requestId?: string;
  retryAfterSeconds?: number;
  inputTokens?: number;
  outputTokens?: number;
}

export const STATUS: Record<Category, number> = {
  ok: 200,
  invalid_request: 400,
  payload_too_large: 413,
  unsupported_media_type: 415,
  not_found: 404,
  method_not_allowed: 405,
  rate_limited: 429,
  disabled: 503,
  capacity: 503,
  timeout: 504,
  cancelled: 499,
  refused: 502,
  invalid_model_output: 502,
  upstream_error: 502,
  internal_error: 500,
};

/// A fixed, generic error. Never a message, stack, prompt or model text.
export function failure(category: Exclude<Category, "ok">, extra: Partial<Outcome> = {}): Outcome {
  return { status: STATUS[category], body: { error: category }, category, ...extra };
}

export async function handleAstra(
  body: unknown,
  meta: { address: string; headers: IncomingHttpHeaders; signal: AbortSignal },
  deps: Deps,
): Promise<Outcome> {
  const { config, limits } = deps;
  if (!config.enabled) return failure("disabled");

  const parsed = AstraRequestSchema.safeParse(body);
  if (!parsed.success) return failure("invalid_request");
  const request = parsed.data;
  const ids = { requestId: request.requestId };

  // Production boundary for App Attest. Today it always reports
  // "not_implemented" and nothing is enforced (see attestation.ts).
  const attestation = await deps.attestation.verify(meta.headers);
  if (attestation.status === "rejected") return failure("invalid_request", { ...ids, detail: "attestation" });

  for (const limiter of [
    limits.perAddress.take(meta.address),
    limits.perInstall.take(request.installId),
    limits.perInstallDaily.take(request.installId),
  ]) {
    if (!limiter.allowed) return failure("rate_limited", { ...ids, retryAfterSeconds: limiter.retryAfterSeconds });
  }
  if (!limits.daily.take()) return failure("capacity", ids);

  // Timeout and client cancellation both abort the model call.
  const controller = new AbortController();
  // An object, not a `let`, so the checks after `await` read the value the
  // timer set.
  const deadline = { passed: false };
  const timer = setTimeout(() => {
    deadline.passed = true;
    controller.abort();
  }, config.modelTimeoutMs);
  const cancel = () => {
    controller.abort();
  };
  meta.signal.addEventListener("abort", cancel, { once: true });

  try {
    const result = await deps.model.respond({
      instructions: INSTRUCTIONS,
      input: buildInput(request),
      signal: controller.signal,
      timeoutMs: config.modelTimeoutMs,
    });
    if (deadline.passed) return failure("timeout", ids);
    if (meta.signal.aborted) return failure("cancelled", ids);
    switch (result.kind) {
      case "refusal":
        return failure("refused", ids);
      case "incomplete":
        return failure("invalid_model_output", { ...ids, detail: "incomplete" });
      case "output": {
        const tokens = {
          ...(result.inputTokens === null ? {} : { inputTokens: result.inputTokens }),
          ...(result.outputTokens === null ? {} : { outputTokens: result.outputTokens }),
        };
        const validated = validateModelOutput(result.output, request);
        if (!validated.ok) return failure("invalid_model_output", { ...ids, ...tokens, detail: validated.reason });
        return { status: 200, body: validated.response, category: "ok", ...ids, ...tokens };
      }
    }
  } catch {
    // The error itself is never surfaced: it could contain request data.
    if (deadline.passed) return failure("timeout", ids);
    if (meta.signal.aborted) return failure("cancelled", ids);
    return failure("upstream_error", ids);
  } finally {
    clearTimeout(timer);
    meta.signal.removeEventListener("abort", cancel);
  }
}

/// One banknote photo (hybrid recognition prototype). Same limits, switch
/// and safe failures as Astra text requests, plus a daily photo cap. The
/// image is never logged or stored.
export async function handleBanknote(
  body: unknown,
  meta: { address: string; headers: IncomingHttpHeaders; signal: AbortSignal },
  deps: Deps,
): Promise<Outcome> {
  const { config, limits } = deps;
  if (!config.enabled || deps.banknoteModel === undefined) return failure("disabled");

  const parsed = BanknoteRequestSchema.safeParse(body);
  if (!parsed.success) return failure("invalid_request");
  const request = parsed.data;
  const ids = { requestId: request.requestId };

  const attestation = await deps.attestation.verify(meta.headers);
  if (attestation.status === "rejected") return failure("invalid_request", { ...ids, detail: "attestation" });

  for (const limiter of [
    limits.perAddress.take(meta.address),
    limits.perInstall.take(request.installId),
    limits.perInstallDaily.take(request.installId),
  ]) {
    if (!limiter.allowed) return failure("rate_limited", { ...ids, retryAfterSeconds: limiter.retryAfterSeconds });
  }
  if (!limits.imageDaily.take() || !limits.daily.take()) return failure("capacity", ids);

  const controller = new AbortController();
  const deadline = { passed: false };
  const timer = setTimeout(() => {
    deadline.passed = true;
    controller.abort();
  }, config.imageTimeoutMs);
  const cancel = () => {
    controller.abort();
  };
  meta.signal.addEventListener("abort", cancel, { once: true });

  try {
    const result = await deps.banknoteModel.recognise({
      instructions: banknoteInstructions(request.mode === "appearance"),
      imageBase64: request.image.base64,
      expectedCurrency: request.expectedCurrency,
      signal: controller.signal,
      timeoutMs: config.imageTimeoutMs,
    });
    if (deadline.passed) return failure("timeout", ids);
    if (meta.signal.aborted) return failure("cancelled", ids);
    switch (result.kind) {
      case "refusal":
        return failure("refused", ids);
      case "incomplete":
        return failure("invalid_model_output", { ...ids, detail: "incomplete" });
      case "output": {
        const tokens = {
          ...(result.inputTokens === null ? {} : { inputTokens: result.inputTokens }),
          ...(result.outputTokens === null ? {} : { outputTokens: result.outputTokens }),
        };
        const validated = validateBanknoteOutput(result.output, request);
        if (!validated.ok) return failure("invalid_model_output", { ...ids, ...tokens, detail: validated.reason });
        return { status: 200, body: validated.response, category: "ok", ...ids, ...tokens };
      }
    }
  } catch {
    if (deadline.passed) return failure("timeout", ids);
    if (meta.signal.aborted) return failure("cancelled", ids);
    return failure("upstream_error", ids);
  } finally {
    clearTimeout(timer);
    meta.signal.removeEventListener("abort", cancel);
  }
}
