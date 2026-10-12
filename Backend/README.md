# NaviNote Astra backend

One small service in front of the OpenAI Responses API. The iPhone app
talks only to this service; the OpenAI API key exists only here, in the
server's environment.

- `POST /v1/astra`: interpret one unrecognised command, or answer an Ask
  NaviNote question — about the transaction (`answer`) or, as an
  accessibility companion, any other topic (`general`, approved 2026-10-09). Strict request validation → rate limits →
  OpenAI Responses API (`gpt-6-astra`, strict Structured Output,
  `store: false`, 300 output tokens, 8 s timeout, no retries) → output
  validation → a reply with the request's IDs.
- `GET /healthz`: liveness.


## Commands

Requires Node.js 24 or later (it runs the TypeScript directly; no build step).

```bash
npm ci                # install exact locked dependencies
npm run lint          # ESLint, typescript-eslint strict type-checked rules
npm run typecheck     # tsc --noEmit, strict configuration
npm test              # unit, contract and security tests (mocked OpenAI; no key, no network)
npm run secret-scan   # scans every file Git would commit; checks .env is ignored
npm run check         # all four
npm start             # runs the server, loading Backend/.env if present
```

## Configuration

Copy `.env.example` to `.env` and fill it in **yourself**. `.env` is
git-ignored and must never be committed, pasted into chat, or shared.

| Variable | Default | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | (none) | Restricted key from the NaviNote OpenAI project. Required when enabled. |
| `ASTRA_MODEL` | `gpt-6-astra` | Model for the Responses API |
| `ASTRA_ENABLED` | `true` | Emergency off switch: `false` refuses every request (503 `disabled`) |
| `ASTRA_DAILY_CAP` | `300` | Maximum requests per UTC day, all clients |
| `ASTRA_HOST` | `127.0.0.1` | `0.0.0.0` only for iPhone testing on your own Wi-Fi |
| `ASTRA_PORT` | `8787` | |
| `ASTRA_REQUIRE_APP_ATTEST` | `false` | App Attest isn't implemented; `true` makes the server refuse to start |

## Limits and safeguards

| | |
|---|---|
| Body size | 4 KB (413) |
| Transcript / instruction | 300 characters each |
| Per install | 20 requests / 10 min, 200 / day (429 + `Retry-After`) |
| Per network address | 60 requests / 10 min |
| Whole service | `ASTRA_DAILY_CAP` per UTC day (503 `capacity`) |
| Model call | 8 s timeout, aborted if the app disconnects, no retries |
| Spend | 300 output tokens per call, daily cap, off switch, plus the OpenAI project's budget limit |

Rate limits are in memory in one process. Behind several instances each
would count separately; a shared store is needed before scaling out.

## Errors

Every error is a fixed body, `{"error": "<category>"}`: `invalid_request`,
`payload_too_large`, `unsupported_media_type`, `not_found`,
`method_not_allowed`, `rate_limited`, `disabled`, `capacity`, `timeout`,
`refused`, `invalid_model_output`, `upstream_error`, `internal_error`.
Never a message, stack trace, prompt or model text.

## Logging

One JSON line per request with only: time, event, request ID (if it's a
UUID), HTTP status, category, a short classification such as
`unprovided_amount`, duration and token counts. **Never** transcripts,
amounts, context, prompts, model output, headers or keys. `console` is
banned by lint; `src/log.ts` has no field any of those could go in.

## Testing from an iPhone (development only)

1. Set `ASTRA_HOST=0.0.0.0` in `.env` and run `npm start`.
2. Build NaviNote (Debug) with the Mac's local address, for example:
   `NAVINOTE_ASTRA_BASE_URL=http://<your-mac>.local:8787`
   (passed to `xcodebuild`; nothing about your Mac is committed).
3. On the iPhone, allow NaviNote to find devices on the local network, then
   turn on **Settings → Astra language help**.

Debug builds allow plain HTTP only to local addresses
(`NSAllowsLocalNetworking`, in `Config/NaviNote-Debug.plist`). Release builds
have no such exception and accept only an HTTPS backend URL.

## App Attest (production requirement — not implemented)

Before any public release, only genuine NaviNote installs should be able to
call the backend. The design, using Apple's App Attest (DeviceCheck; no
secret in the app):

1. `GET /v1/attest/challenge` → a one-time random challenge.
2. The app creates an App Attest key (`DCAppAttestService.generateKey`),
   attests it against the challenge, and sends the attestation to
   `POST /v1/attest/register`. The server verifies it against Apple's App
   Attest root certificate, the app ID (team ID + `com.saarangvibin.navinote`)
   and the challenge, then stores the key ID and public key.
3. Every `/v1/astra` request carries an assertion over a hash of the body
   (headers `X-NaviNote-Key-Id`, `X-NaviNote-Assertion`). The server checks
   the signature and that the counter increased.

The boundary is already in the request path: `src/attestation.ts` defines
`ClientAttestationVerifier`, and `handler.ts` calls it for every request.
Today's verifier returns `not_implemented` and enforces nothing. Setting
`ASTRA_REQUIRE_APP_ATTEST=true` makes the server refuse to start, so
attestation can never look active before it's been implemented and tested.
