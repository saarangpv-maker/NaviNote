# NaviNote Audio (Phase 4)

`AudioCoordinator` (`NaviNote/Services/Audio/AudioCoordinator.swift`) is the
single owner of the audio session, speech recognition and speech output.
Nothing else in the app touches AVAudioSession, SFSpeechRecognizer,
AVAudioEngine or AVSpeechSynthesizer.

## Boundaries

| Protocol | Live implementation | Test fake |
|---|---|---|
| `AudioSessionControlling` | `SystemAudioSession` (AVAudioSession + notifications) | `FakeAudioSession` |
| `SpeechPermissionProviding` | `SystemSpeechPermissions` (AVAudioApplication, SFSpeechRecognizer) | `FakePermissions` |
| `SpeechRecognizing` | `SystemSpeechRecognizer` (SFSpeechRecognizer + AVAudioEngine) | `FakeRecognizer` |
| `SpeechSynthesizing` | `SystemSpeechSynthesizer` (AVSpeechSynthesizer) | `FakeSynthesizer` |
| `AccessibilityStatusProviding` | `SystemAccessibilityStatus` (UIAccessibility) | `FakeAccessibility` |

Timing (settling delays, limits, watchdog) is injected via `AudioTiming`;
tests use zero delays.

## States

`idle` · `requestingPermission` · `listening` · `processing` · `speaking` ·
`paused` · `interrupted` · `permissionDenied(microphone | speechRecognition)` ·
`unavailable(reason)` · `recovering`

## Rules and where they are enforced

| Rule | Mechanism |
|---|---|
| Push-to-talk only | Listening starts only in `talkPressed()`. Nothing at launch, after speech, after an interruption or on returning to the foreground. |
| Separate permissions | Microphone first, then speech recognition; each checked and requested on its own. Restricted is reported differently from denied. |
| Stop recognition before speaking | The speech queue cancels any listening (and any attempt still asking for permission), waits `afterListeningBeforeSpeaking`, then configures the session. |
| One session preparation per message | `activateForSpeaking()` once per queued message; chunks are spoken without reconfiguring. |
| Predictable queue | Messages in order; each split into sentences by `SpeechChunker` (decimals like 12.50 kept intact). A screen change drops pending, now-stale messages. |
| Final results only | `.partial` updates `partialTranscript` (display only); only `.final` reaches `onFinalTranscript`. |
| Ignore what's heard while speaking | Starting speech tears down recognition and invalidates its request; later recognizer events are ignored. |
| No duplicate tasks | `talkPressed()` ignores presses while starting/processing; the recognizer contract refuses a second start; each final is delivered once. |
| Request ID + generation on every result | Each listening session has a `RequestID` and the coordinator's `SessionGeneration`; every recognizer event is checked against both. `cancelAll()` (workflow cancel/reset/finish), backgrounding and media-services reset bump the generation. |
| Lifecycle | Background: stop listening and speech, deactivate, `paused`. Inactive (call banner, Control Center): close the microphone. Active: `paused` → `idle`, never listens. |
| Interruptions | Began: stop everything, `interrupted`. Ended: `recovering` → `idle`. Nothing resumes automatically. |
| Route changes | Old output removed (headphones/Bluetooth disconnected): stop speech and listening, `paused`, so amounts aren't played aloud. Other changes: no action. |
| Private Bluetooth audio | No `.defaultToSpeaker`, no route overrides. Speech: `.playback` / `.spokenAudio` / `.duckOthers`. Listening: `.record` / `.measurement` / `.allowBluetoothHFP`. |
| Never store audio or transcripts | Buffers go straight to the recognizer. Logs record only transcript length. Recognition is on-device only; if unsupported, voice is unavailable (no server fallback). |
| End of speech | After recognised words, `endOfSpeechSilence` (1.2 s) without a new partial result closes the microphone, as if Talk were pressed again. Silence before any words never ends listening. Partials still never act; the command comes only from the final result. Device finding 2026-10-08: without it, a command waited for a second Talk press or the 15 s limit. Physical-device-tested 2026-10-08. |
| Interruptions | Only pause if NaviNote was listening or speaking. While paused, **Talk is a retry**; if a call still holds the audio it says so and stays paused. Returning to the app clears a pause iOS never ended. Under VoiceOver, an announcement never resets paused / denied / unavailable. Device finding 2026-10-08: turning VoiceOver on arrived as an interruption with no end and disabled Talk. Physical-device-tested and VoiceOver-tested 2026-10-09. |
| Timeouts | Listening closes after `listeningLimit` (15 s); the final result gets `finishGrace` (2 s); each spoken chunk has a length-based watchdog. |
| Button and typed alternatives | Every command can be typed (`TypeCommandView`) through the same `VoiceCommandRouter`, and every workflow step has a button. |

## VoiceOver policy

- **VoiceOver running:** NaviNote's synthesizer never speaks. Messages
  reach VoiceOver two ways:
  - *New screen:* VoiceOver focus moves to the screen's message
    ("NaviNote says: …"), which VoiceOver reads (`announcesViaVoiceOverFocus`).
  - *Same-screen updates and Repeat:* an announcement posted about 0.4 s after
    the tap, so VoiceOver has finished handling the button. Updates are queued
    behind VoiceOver's current speech; Repeat is not.
- **VoiceOver off:** messages are spoken by NaviNote's voice (if "Speak
  messages" is on in Settings).
- **Status changes at runtime** are observed. If VoiceOver turns on while
  NaviNote is speaking, NaviNote stops at once.
- Identical messages within one second are delivered once. Repeat is never
  suppressed.
- An announcement while listening closes the microphone first, so VoiceOver
  isn't captured as a command.

## Voice commands

`VoiceCommandRouter` (pure, deterministic) maps phrases to candidate actions;
the store sends the first one the state machine permits. Examples: "start
checkout", "read currency", "verify change", "repeat", "help", "yes", "no",
"scan again", "remove last note", "done", "cancel". Amounts are not
interpreted yet (checkout screens, Phase 8). Unknown phrases get a spoken
"didn't understand" — no AI is involved.

## Verification status

| Area | Status |
|---|---|
| Coordinator rules above | unit-tested with fakes |
| Command routing, store integration | unit-tested; typed commands UI-tested |
| Live AVAudioSession / SFSpeechRecognizer / AVAudioEngine / AVSpeechSynthesizer / VoiceOver wrappers | statically verified (compile with Swift 6 strict concurrency) — **not yet physical-device-tested** |
| Settling delays and watchdog values | **not yet verified** on a device |

The audio system must not be described as working until it has been tested
on a real iPhone.

## Known issue: speech-framework runtime warning

In the iOS 26.5 simulator, UI tests that make NaviNote speak report
"[Internal] Thread running at User-interactive quality-of-service class
waiting on a lower QoS thread … priority inversions". It was isolated
experimentally with the Repeat UI test:

| Variant | Warnings |
|---|---|
| `AVSpeechSynthesizer.speak` disabled, audio session still activated | 0 |
| Audio session disabled, speech on | 1 |
| Plain utterance (no explicit voice, no assistive-technology settings) | 1 |
| Synthesizer driven from the main thread | 1 |
| Synthesizer driven from a background serial queue | 1 |

The wait happens inside Apple's speech framework whenever it speaks, so it is
not fixable in NaviNote's code short of removing speech. Audio-session
configuration was moved off the main thread (those calls do block), which
remains. Whether the warning also occurs on a physical iPhone is item 17 of
the checklist below. Build warnings are zero.

## Physical-iPhone validation checklist

Record the iPhone model, iOS version and pass/fail for each.

1. **First Talk** — Press Talk: microphone prompt, then speech-recognition
   prompt, in that order. Nothing is requested before the first Talk press.
2. **Deny each permission** (reset via Settings › NaviNote): the status shows
   the right one, Open Settings works, Type still works.
3. **Push-to-talk** — Say "start checkout": partial words appear, the command
   runs only after you stop or pause. Press Talk mid-sentence to stop.
4. **No self-hearing** — Press Talk while NaviNote is speaking: speech stops,
   then listening starts, and NaviNote's own voice isn't recognized.
5. **Multi-sentence speech** — Trigger a long message: sentences in order,
   none cut off, no audio glitch or error between sentences (the prototype's
   `-50` error).
6. **Speaker vs receiver** — With no headphones, check where speech plays
   and that it's loud enough.
7. **AirPods / Bluetooth** — Speech plays only in the headphones; Talk uses
   the headset microphone; disconnecting mid-message stops speech (nothing
   plays aloud) and shows "Voice paused".
8. **Wired headphones** (if available) — same as 7.
9. **Phone call / Siri / alarm** during speech and during listening:
   `interrupted`, then back to idle; nothing restarts on its own.
10. **Background / foreground** during speech and during listening:
    everything stops; returning never listens automatically.
11. **Music app playing** — NaviNote ducks it while speaking and releases it
    afterwards.
12. **VoiceOver on** — Messages are read once, by VoiceOver only; Talk works
    with a double-tap; VoiceOver's own speech isn't captured as a command.
13. **VoiceOver toggled mid-message** (triple-click shortcut): NaviNote's
    voice stops immediately, VoiceOver takes over.
14. **Silent switch on** — Speech still plays (`.playback`).
15. **Airplane mode** — Recognition still works (it is on-device only).
16. **Repeated use** — 20 Talk / speak cycles: no stuck state, no crash.
17. **Xcode runtime issues** — Run from Xcode on the iPhone, speak a few
    messages, and note whether the "priority inversion" runtime warning
    appears in the Issue navigator.

## Physical-device findings

### 2026-09-24 — iPhone 17 Pro Max, iOS 27.0 (24A437), AirPods Pro 3

| Test | Result |
|---|---|
| E. Siri during use, then Talk | Crashed at first; no crash after the fix below — **pass** |
| D. AirPods put in the case, then Talk | Crashed at first; no crash after the fix below, listening works through AirPods — **pass** |
| F. VoiceOver | Messages not spoken at first; after the fix below, messages are read out — **pass** |

**Crash:** `SIGABRT` from an Objective-C exception in
`AVAudioNode.installTap(onBus:bufferSize:format:block:)`, called from
`SystemSpeechRecognizer.start()` on the first Talk press after the audio
route changed (crash reports `NaviNote-2026-09-24-164602.ips` and
`-164735.ips`, pulled with `xcrun devicectl`).

**Cause:** one `AVAudioEngine` was reused for the app's lifetime. After a
route change it still held the previous microphone's format, and installing a
tap with a format that no longer matches the hardware raises an exception.

**Fix:** a new engine for every listening session, created after the session
is configured; the tap format is checked against the hardware format before
installing (a mismatch reports "microphone unavailable" instead of crashing);
`AVAudioEngineConfigurationChange` ends a listening session cleanly if the
route changes mid-listen. The next Talk press always starts fresh.

**Crash retest (same device):** no crash after Siri or after putting the
AirPods in the case; listening works through the AirPods — pass.

**VoiceOver: messages not spoken.** VoiceOver read buttons, but NaviNote's
messages were silent. Messages were posted during the button activation (and
screen changes as a `.screenChanged` notification with a string), which
VoiceOver discards while it handles the tap and moves focus. Now screen
changes move VoiceOver focus to the new screen's message, and updates/Repeat
are posted after a short delay.

**VoiceOver retest (same device):** messages are read out — pass.

Still to run on the device: the rest of checklist sections A–H, including
"no double speech", VoiceOver toggled mid-message, and the Xcode
priority-inversion check (item 17).
