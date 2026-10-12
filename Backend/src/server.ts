// HTTP transport: routes, content type, body-size limit, JSON parsing,
// cancellation on disconnect, safe headers and one safe log line per
// request. All Astra rules live in handler.ts.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { failure, handleAstra, handleBanknote, type Deps, type Outcome } from "./handler.ts";
import { BANKNOTE_LIMITS } from "./banknote.ts";
import type { Logger } from "./log.ts";
import { LIMITS } from "./schema.ts";

class BodyTooLarge extends Error {}

/// Reads the body up to `limit` bytes. Past the limit it keeps reading but
/// discards, so the client reliably receives the 413 instead of a reset
/// connection; past a hard cap (4× the limit) it gives up on the socket.
function readBody(request: IncomingMessage, limit: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let tooLarge = Number(request.headers["content-length"] ?? "0") > limit;
    request.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > limit) tooLarge = true;
      if (size > limit * 4) {
        request.destroy();
        reject(new BodyTooLarge());
        return;
      }
      if (!tooLarge) chunks.push(chunk);
    });
    request.on("end", () => {
      if (tooLarge) reject(new BodyTooLarge());
      else resolve(Buffer.concat(chunks).toString("utf8"));
    });
    request.on("error", reject);
  });
}

function send(response: ServerResponse, outcome: Outcome, closeConnection = false): void {
  if (response.writableEnded || response.destroyed) return;
  const headers: Record<string, string> = {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  };
  if (outcome.retryAfterSeconds !== undefined) headers["retry-after"] = outcome.retryAfterSeconds.toString();
  if (closeConnection) headers["connection"] = "close";
  response.writeHead(outcome.status, headers);
  response.end(JSON.stringify(outcome.body));
}

export function createAstraServer(deps: Deps, log: Logger): Server {
  const server = createServer((request, response) => {
    const started = performance.now();
    const controller = new AbortController();
    response.on("close", () => {
      if (!response.writableFinished) controller.abort();
    });

    const finish = (outcome: Outcome, closeConnection = false) => {
      send(response, outcome, closeConnection);
      log({
        event: "request",
        status: outcome.status,
        category: outcome.category,
        ms: performance.now() - started,
        ...(outcome.requestId === undefined ? {} : { requestId: outcome.requestId }),
        ...(outcome.detail === undefined ? {} : { detail: outcome.detail }),
        ...(outcome.inputTokens === undefined ? {} : { inputTokens: outcome.inputTokens }),
        ...(outcome.outputTokens === undefined ? {} : { outputTokens: outcome.outputTokens }),
      });
    };

    const path = (request.url ?? "/").split("?")[0];
    void (async () => {
      if (path === "/healthz") {
        if (request.method !== "GET") { finish(failure("method_not_allowed")); return; }
        response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        response.end(JSON.stringify({ status: "ok" }));
        return;
      }
      const routes: Record<string, { limit: number; handle: typeof handleAstra }> = {
        "/v1/astra": { limit: LIMITS.bodyBytes, handle: handleAstra },
        "/v1/banknote": { limit: BANKNOTE_LIMITS.bodyBytes, handle: handleBanknote },
      };
      const route = path === undefined ? undefined : routes[path];
      if (route === undefined) { finish(failure("not_found")); return; }
      if (request.method !== "POST") { finish(failure("method_not_allowed")); return; }
      if (!(request.headers["content-type"] ?? "").toLowerCase().startsWith("application/json")) {
        finish(failure("unsupported_media_type"), true);
        return;
      }

      let body: unknown;
      try {
        body = JSON.parse(await readBody(request, route.limit));
      } catch (error) {
        finish(failure(error instanceof BodyTooLarge ? "payload_too_large" : "invalid_request"), true);
        return;
      }

      const address = request.socket.remoteAddress ?? "unknown";
      finish(await route.handle(body, { address, headers: request.headers, signal: controller.signal }, deps));
    })().catch(() => {
      finish(failure("internal_error"));
    });
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  return server;
}
