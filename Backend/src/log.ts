// Privacy-aware logging. Only these fields can be written, and each is a
// safe type: a validated request ID, a status category, timing, token
// counts. Transcripts, amounts, prompts, model output, headers and keys
// have no field to go in.
export type Category =
  | "ok"
  | "invalid_request"
  | "payload_too_large"
  | "unsupported_media_type"
  | "not_found"
  | "method_not_allowed"
  | "rate_limited"
  | "disabled"
  | "capacity"
  | "timeout"
  | "cancelled"
  | "refused"
  | "invalid_model_output"
  | "upstream_error"
  | "internal_error";

export interface LogEntry {
  event: "request" | "startup" | "shutdown";
  requestId?: string;
  status?: number;
  category?: Category;
  /** A classification such as "schema" or "unprovided_amount"; never a message. */
  detail?: string;
  ms?: number;
  inputTokens?: number;
  outputTokens?: number;
}

export type Logger = (entry: LogEntry) => void;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const DETAIL = /^[a-z_]{1,40}$/u;

/// A request ID is logged only if it is a UUID; anything else might be
/// attacker-chosen text.
export function safeRequestId(value: unknown): string {
  return typeof value === "string" && UUID.test(value) ? value.toLowerCase() : "invalid";
}

export function createLogger(write: (line: string) => void = (line) => process.stdout.write(line)): Logger {
  return (entry) => {
    const safe: LogEntry = { event: entry.event };
    if (entry.requestId !== undefined) safe.requestId = safeRequestId(entry.requestId);
    if (entry.status !== undefined) safe.status = entry.status;
    if (entry.category !== undefined) safe.category = entry.category;
    if (entry.detail !== undefined && DETAIL.test(entry.detail)) safe.detail = entry.detail;
    if (entry.ms !== undefined) safe.ms = Math.round(entry.ms);
    if (entry.inputTokens !== undefined) safe.inputTokens = entry.inputTokens;
    if (entry.outputTokens !== undefined) safe.outputTokens = entry.outputTokens;
    write(`${JSON.stringify({ time: new Date().toISOString(), ...safe })}\n`);
  };
}
