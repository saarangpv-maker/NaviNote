// HTTP contract, against the real server with a mocked model: exact
// response shape, status codes, headers and limits the app relies on.
import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { deps, MockModel, post, startServer, validRequest, type Running } from "./helpers.ts";

describe("HTTP contract", () => {
  let server: Running;
  before(async () => {
    server = await startServer(deps(new MockModel({ output: { type: "intent", intent: "scan", text: "Starting the camera." } })));
  });
  after(async () => {
    await server.close();
  });

  it("POST /v1/astra returns exactly the documented fields", async () => {
    const response = await post(server.url, validRequest());
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(response.headers.get("cache-control"), "no-store");
    const body = (await response.json()) as Record<string, unknown>;
    assert.deepEqual(Object.keys(body).sort(), ["intent", "requestId", "sessionId", "text", "type"]);
    assert.deepEqual(body, {
      requestId: "11111111-1111-4111-8111-111111111111",
      sessionId: "22222222-2222-4222-8222-222222222222",
      type: "intent",
      intent: "scan",
      text: "Starting the camera.",
    });
  });

  it("errors are a fixed shape: { error: category }", async () => {
    const response = await post(server.url, { hello: "world" });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: "invalid_request" });
  });

  it("rejects bodies over 4 KB", async () => {
    const response = await post(server.url, JSON.stringify({ padding: "x".repeat(5000) }));
    assert.equal(response.status, 413);
    assert.deepEqual(await response.json(), { error: "payload_too_large" });
  });

  it("rejects malformed JSON", async () => {
    const response = await post(server.url, "{not json");
    assert.deepEqual([response.status, await response.json()], [400, { error: "invalid_request" }]);
  });

  it("requires a JSON content type", async () => {
    const response = await post(server.url, validRequest(), { "content-type": "text/plain" });
    assert.deepEqual([response.status, await response.json()], [415, { error: "unsupported_media_type" }]);
  });

  it("only allows POST on /v1/astra and GET on /healthz", async () => {
    const get = await fetch(`${server.url}/v1/astra`);
    assert.deepEqual([get.status, await get.json()], [405, { error: "method_not_allowed" }]);
    const missing = await fetch(`${server.url}/v1/other`, { method: "POST" });
    assert.deepEqual([missing.status, await missing.json()], [404, { error: "not_found" }]);
    const health = await fetch(`${server.url}/healthz`);
    assert.deepEqual([health.status, await health.json()], [200, { status: "ok" }]);
  });

  it("sends Retry-After when rate-limited", async () => {
    const limited = await startServer(deps(new MockModel(), { config: { dailyCap: 1000 } }));
    try {
      let last: Response | undefined;
      for (let i = 0; i < 21; i += 1) last = await post(limited.url, validRequest());
      assert.ok(last);
      assert.equal(last.status, 429);
      assert.ok(Number(last.headers.get("retry-after")) >= 1);
    } finally {
      await limited.close();
    }
  });
});
