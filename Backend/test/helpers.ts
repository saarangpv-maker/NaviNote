// Test doubles: a mocked model, a fixed config, and a server on an
// ephemeral port. No API key, no network.
import type { AddressInfo } from "node:net";
import { notImplementedVerifier, type ClientAttestationVerifier } from "../src/attestation.ts";
import type { Config } from "../src/config.ts";
import type { Deps } from "../src/handler.ts";
import { standardLimits, type Limits } from "../src/limits.ts";
import { createLogger, type Logger } from "../src/log.ts";
import type { AstraModel, ModelResult } from "../src/model.ts";
import { createAstraServer } from "../src/server.ts";

export const testConfig: Config = {
  model: "gpt-6-astra",
  enabled: true,
  dailyCap: 1000,
  host: "127.0.0.1",
  port: 0,
  modelTimeoutMs: 200,
  imageDailyCap: 1000,
  imageTimeoutMs: 200,
};

export const baseContext = {
  currency: "USD",
  total: 1735,
  paid: null,
  expectedChange: null,
  receivedTotal: null,
  lastInstruction: "Scan the receipt or payment terminal, or enter the total yourself.",
};

export function validRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    requestId: "11111111-1111-4111-8111-111111111111",
    sessionId: "22222222-2222-4222-8222-222222222222",
    installId: "33333333-3333-4333-8333-333333333333",
    kind: "interpretCommand",
    screen: "acquiringTotal",
    transcript: "could you say that one more time",
    context: { ...baseContext },
    ...overrides,
  };
}

/// A model that returns `output`, or behaves as `behaviour` says.
type Behaviour = { output: unknown } | { result: ModelResult } | { throws: Error } | { hang: true };

export class MockModel implements AstraModel {
  calls: { instructions: string; input: string; timeoutMs: number }[] = [];
  private readonly behaviour: Behaviour;

  constructor(behaviour: Behaviour = { output: { type: "intent", intent: "repeat", text: null } }) {
    this.behaviour = behaviour;
  }

  respond(args: { instructions: string; input: string; signal: AbortSignal; timeoutMs: number }): Promise<ModelResult> {
    this.calls.push({ instructions: args.instructions, input: args.input, timeoutMs: args.timeoutMs });
    const b = this.behaviour;
    if ("output" in b) return Promise.resolve({ kind: "output", output: b.output, inputTokens: 120, outputTokens: 12 });
    if ("result" in b) return Promise.resolve(b.result);
    if ("throws" in b) return Promise.reject(b.throws);
    // Hangs until aborted, like a slow upstream honouring AbortSignal.
    return new Promise((_, reject) => {
      args.signal.addEventListener("abort", () => {
        reject(new Error("aborted"));
      });
    });
  }
}

export function deps(
  model: AstraModel,
  options: { config?: Partial<Config>; limits?: Limits; attestation?: ClientAttestationVerifier } = {},
): Deps {
  const config = { ...testConfig, ...options.config };
  return {
    config,
    model,
    limits: options.limits ?? standardLimits(config.dailyCap),
    attestation: options.attestation ?? notImplementedVerifier,
  };
}

export const noSignal = new AbortController().signal;

export interface Running {
  url: string;
  lines: string[];
  close: () => Promise<void>;
}

/// Starts the real HTTP server with the given deps, capturing log lines.
export async function startServer(serverDeps: Deps): Promise<Running> {
  const lines: string[] = [];
  const log: Logger = createLogger((line) => lines.push(line));
  const server = createAstraServer(serverDeps, log);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    lines,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => {
          resolve();
        });
      }),
  };
}

export function post(url: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return fetch(`${url}/v1/astra`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}
