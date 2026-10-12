# NaviNote Security and Privacy

## Principles

1. **The app holds no secrets.** There is no API key, token or credential in
   Swift source, Info.plist, asset catalogs, bundled resources, Keychain,
   committed `.xcconfig` files, tests, UI-test configuration or logs.
2. **On-device first.** Camera frames, OCR text and audio never leave the
   device. Only when the person turns on **Astra language help** (off by
   default) is a minimal text context sent to the NaviNote backend: the
   unrecognised words, the screen name and the transaction's *confirmed*
   amounts (Phase 10, approved 2026-09-26).
3. **Nothing is persisted by default.** No transaction history, no
   conversation history, no images, no audio. The only persisted data is
   device-local preferences (for example "Haptic feedback on").
4. **Model output is untrusted.** Astra replies are validated three times:
   the model's strict Structured Output schema, the backend, and Swift
   (`AstraResponseValidator`). They can only *propose* an allowlisted,
   non-financial intent, which the state machine applies only if valid
   (like a button press). Astra never confirms, rejects, enters, calculates
   or changes an amount; a reply stating an amount the app didn't send is
   discarded.

## Secrets

| Location | Allowed? |
|---|---|
| Swift source, tests, UI tests | **No** |
| Info.plist, asset catalog, resources | **No** |
| Committed `.xcconfig` | **No** |
| iOS Keychain (for the OpenAI key) | **No** — the key never reaches the device |
| Backend environment (`Backend/.env`, git-ignored) / host secret store | **Yes** — the only place |

`.gitignore` excludes `.env*` (except `Backend/.env.example`, which has no
values), `Secrets.xcconfig`, `*.secret.xcconfig`, signing keys and
provisioning profiles as a second line of defence.

Before each checkpoint, run the secret scan (no dependencies). It scans
every file Git would commit, fails on key-like strings, fails if any `.env`
is tracked, and fails if `Backend/.env` is not ignored:

```bash
node scripts/secret-scan.mjs
```

For a Release build, also run `scripts/check-release-app.sh <NaviNote.app>`.
It checks the bundle has no App Transport Security exception, no
local-network usage description, no non-HTTPS backend URL, and passes the
secret scan. Development hosts are also searched for in the executable, but
Swift stores strings of 15 bytes or fewer inline, so that search can only
catch longer strings; the Debug-only host check is compiled out of Release
by `#if DEBUG`.

## Note photos (online note check, prototype)

Approved 2026-10-09: images may leave the iPhone **only** for Read
Currency's "Check note online", only with **Settings → Send note photos**
on (off by default) and a button press. One downscaled JPEG, in memory
only, to the NaviNote backend (`/v1/banknote`: consent required, 2 MB
limit, its own daily cap), sent to OpenAI with `store: false`, never
stored or logged. Text scanning always stays on the device.

## Astra (Phase 10)

- **Off by default** (Settings → Astra language help). With it off, not set
  up, unreachable, timed out, rate-limited or invalid, NaviNote says "Sorry,
  I didn't understand" exactly as before; every feature works with buttons
  and local voice commands.
- Since 2026-10-09 Astra is also an accessibility companion: Ask NaviNote
  questions on **any topic** may be sent (only when Astra is on). General
  answers are labelled, may not state unprovided money, give financial
  advice, or discuss whether a note is genuine.
- The app sends: request ID, a per-session ID (new after cancel/finish), a
  random per-install ID (rate limiting only; not a device identifier), the
  screen name, the unrecognised words (≤ 300 characters), and confirmed
  currency / total / paid / change expected / change received, plus the last
  instruction only if it mentions no unconfirmed amount. Never images,
  audio, OCR text, proposals or history.
- Transport: an ephemeral `URLSession` (no cache, cookies or credentials),
  10 s timeout, cancelled on reset. Release accepts only HTTPS; Debug also
  allows plain HTTP to local addresses via `Config/NaviNote-Debug.plist`
  (`NSAllowsLocalNetworking`), which Release does not include.
- `Log.astra` records outcome categories only (`reply: intent`,
  `request failed: timeout`), never words, context or replies.
- The backend's safeguards (limits, logging, errors, App Attest design) are
  in [Backend/README.md](../Backend/README.md). **App Attest is designed but
  not implemented**; it is a production requirement.

## Logging

- Use `Log.*` (`NaviNote/Core/Logging/Log.swift`), which wraps `OSLog`.
- State-machine phase names and action kinds may be logged publicly.
- Amounts, currencies tied to a transaction, transcripts, recognised text and
  identifiers are logged with `privacy: .private` (redacted outside a
  debugger).
- Never log images, audio buffers or full OCR text. `print` is not used,
  except by `ScanDiagnostics`: **Debug builds only** (compiled out of
  Release), off unless the developer launches with
  `NAVINOTE_SCAN_DIAGNOSTICS=1`, printed to the attached console only (not
  OSLog, not persisted). It prints keyword hits and numbers, not text. The
  separate `NAVINOTE_SCAN_DIAGNOSTICS_TEXT=1` switch prints recognized text
  with serial-length digit runs masked, and is for the developer's own
  device and notes only.

## Permissions

Permissions are added only with the feature that needs them.

| Key | Added | Wording |
|---|---|---|
| `NSMicrophoneUsageDescription` | Phase 4 | "NaviNote listens only while you press Talk, so you can control it by voice. Audio is never saved." |
| `NSSpeechRecognitionUsageDescription` | Phase 4 | "NaviNote turns what you say after pressing Talk into commands. Recordings are not kept." |
| `NSCameraUsageDescription` | Phase 5 | "NaviNote uses the camera, only while you scan, to read totals and banknotes. Images stay on your iPhone and are never saved." |

No permission is requested at launch. Microphone and speech recognition are
requested on the first Talk press; the camera on the first Scan press, and
only if the device has a camera.

## Camera data

- Frames are recognized on the device with Vision and discarded; they are
  never written to disk, logged or uploaded.
- Recognized text is never logged or stored; only counts are logged.

## Voice data

- Audio buffers go directly from the microphone to the speech recognizer;
  nothing is written to disk.
- Recognition is **on-device only** (`requiresOnDeviceRecognition = true`).
  If a device can't recognize speech locally, voice is reported unavailable
  and buttons/Type are used instead. Audio is never sent to a server.
- Transcripts are never logged; only their length is.
- Transcripts are not stored or sent to any NaviNote service.

## Things NaviNote must never claim

- That a banknote is genuine or counterfeit.
- That a result is guaranteed to be financially correct.
- That a mobile or card payment succeeded.
