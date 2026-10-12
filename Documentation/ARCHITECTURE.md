# NaviNote Architecture

## Platform decisions

| Decision | Choice | Why |
|---|---|---|
| Language / UI | Swift 6 language mode, SwiftUI app lifecycle | Native, strict concurrency checking at compile time |
| Minimum iOS | **17.0** | Needed for the Observation framework (`@Observable`), `AccessibilityNotification`, `performAccessibilityAudit`, and modern SwiftUI accessibility APIs. iOS 17 runs on iPhone XS/XR and later, so choosing it excludes very few users. Nothing newer is needed yet. |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait + landscape | One-handed phone use is the product. |
| Project format | Standard `.xcodeproj` with file-system-synchronised groups | No generator; new files are picked up automatically. |
| Unit tests | Swift Testing | Parameterised tests over currencies and denominations. |
| UI tests | XCUITest | Includes the accessibility audit API. |
| Dependencies | None | Apple frameworks cover everything so far. |
| Default actor isolation | Not enabled; UI types are explicitly `@MainActor` | Keeps the domain layer nonisolated and `Sendable`, so it can be used from actors and tests freely. |

## Layers

```
NaviNote/
  App/                 Composition root (NaviNoteApp), NaviNoteStore
  Core/
    Domain/            Pure value types: Money, Currency, SupportedDenomination,
                       RecognitionConfidence, ScanCandidate, CandidateGate,
                       CheckoutSession, ReturnedChangeSession, …
    StateMachine/      NaviNoteState, NaviNoteAction, NaviNoteEffect,
                       NaviNoteStateMachine
    Scanning/          StabilityTracker, AimingGuidance, ScanReadingParser
    Accessibility/     Announcement → spoken/visible copy (AnnouncementComposer)
    Logging/           OSLog categories with privacy defaults
  Features/
    Shell/             RootView: renders the current phase
    Home/              Home screen
    Help/, Settings/   Sheets
  Services/
    Haptics/           HapticsPlaying protocol + UIKit implementation
    Audio/             AudioCoordinator + protocol boundaries for AVAudioSession,
                       speech recognition, speech synthesis, VoiceOver (Phase 4,
                       see AUDIO.md)
    Camera/            CameraControlling + SystemCamera (AVCaptureSession)
    OCR/               TextRecognizing + VisionTextRecognizer
    Scanning/          ScanCoordinator: scan request → one tagged ServiceEvent
                       (Phase 5, see CAMERA.md)
    (Backend arrives in Phase 10)
  DesignSystem/
    Tokens/            Colours, typography, spacing, radii, elevation
    Components/        Buttons, banners, panels, indicators, camera shell…
  Resources/           Asset catalog (colours with dark + high-contrast variants, icon)
```

**Dependency rule:** `Core/Domain` and `Core/StateMachine` import only
Foundation. They never import SwiftUI, UIKit, AVFoundation, Vision, Speech or
URLSession, and they never touch the network. Everything platform-specific
lives in `Services/` behind a protocol, or in `Features/`/`DesignSystem/`.

## The state machine is authoritative

```
      ┌────────────┐  NaviNoteAction   ┌──────────────────────┐
View ─┤ NaviNote-  ├──────────────────►│ NaviNoteStateMachine │ (pure struct)
      │ Store      │◄──────────────────┤  handle(action)      │
      │ @MainActor │ TransitionResult  └──────────────────────┘
      │ @Observable│   .applied(effects) / .ignored(reason)
      └─────┬──────┘
            │ executes effects
            ▼
   AnnouncementPosting · HapticsPlaying · (scanner, audio, backend later)
            │
            └── async results come back as ServiceEvent(requestID, generation, payload)
                sent through the same store.send(_:)
```

- `NaviNoteState` holds the `phase`, the `SessionGeneration`, the checkout
  session, pending candidates, the returned-change session, the pending
  request, and the last announcement (for **Repeat**).
- `handle(_:)` either applies a transition and returns effects, or returns
  `.ignored(reason)` without touching state. It never throws.
- `cancel`, `reset` and `finish` start a new `SessionGeneration` and emit
  `cancelAllPendingWork`.
- Every scan is a **one-shot request** with its own `RequestID`. The machine
  records it as pending; a `ServiceEvent` is accepted only if its generation
  is current **and** its request ID is the pending one. After the first event
  the request is cleared, so a duplicated callback is ignored. This is what
  keeps a returned note in view from being counted twice.
- Views never assign state. `RootView` switches on `state.phase`.

### Phases

`home`, `checkoutIntroduction`, `acquiringTotal`, `confirmingTotal`,
`acquiringPaymentNote`, `confirmingPaymentNote`, `showingExpectedChange`,
`settingExpectedChange`, `confirmingExpectedChange`, `collectingReturnedChange`,
`confirmingReturnedNote`, `exactChange`,
`shortChange`, `excessiveChange`, `unresolvedChange`, `readingCurrency`,
`askingNaviNote`, `recoverableError(issue)`, `permissionDenied(kind)`.

`settingExpectedChange` is an addition to the brief's list: **Verify Change**
from the home screen needs the expected change before notes can be checked,
and there is no confirmed checkout to derive it from.

`askingNaviNote`, `recoverableError` and `permissionDenied` remember a
`resumePhase` so the user returns to where they were.

### Main transitions

| From | Action | To |
|---|---|---|
| home | startCheckout | checkoutIntroduction |
| checkoutIntroduction | continueCheckout | acquiringTotal |
| acquiringTotal | total candidate (gate passed) / enterTotalManually | confirmingTotal |
| confirmingTotal | selectTotalCurrency | confirmingTotal (currency set) |
| confirmingTotal | confirmTotal (currency known) | acquiringPaymentNote |
| confirmingTotal | rejectTotal | acquiringTotal |
| acquiringPaymentNote | note candidate (gate passed, same currency) / selectPaymentNoteManually | confirmingPaymentNote |
| confirmingPaymentNote | confirmPaymentNote | showingExpectedChange |
| confirmingPaymentNote | rejectPaymentNote | acquiringPaymentNote |
| showingExpectedChange | startReturnedChange (change due only) | collectingReturnedChange |
| home | startChangeVerification | settingExpectedChange |
| settingExpectedChange | enterExpectedChange (amount, optional currency) | confirmingExpectedChange |
| confirmingExpectedChange | selectExpectedChangeCurrency / confirmExpectedChange (currency required) | collectingReturnedChange |
| confirmingExpectedChange | rejectExpectedChange | settingExpectedChange |
| collectingReturnedChange | stable, confident camera note | counted immediately (announced, haptic, Remove Last Note offered) |
| collectingReturnedChange | manual, borderline, unstable or simulated note | confirmingReturnedNote |
| confirmingReturnedNote | confirmReturnedNote / rejectReturnedNote | counted / collectingReturnedChange |
| collectingReturnedChange | note counted → total == expected | exactChange |
| collectingReturnedChange | note accepted → total > expected | excessiveChange |
| collectingReturnedChange | finishReturnedChange (some notes) | shortChange |
| collectingReturnedChange | finishReturnedChange (no notes) | unresolvedChange |
| exact/excessive/short | removeLastReturnedNote | re-evaluated |
| short/unresolved | continueCollectingChange | collectingReturnedChange |
| home | startReadingCurrency | readingCurrency |
| any workflow phase | openAskNaviNote | askingNaviNote (resume later) |
| any non-home | cancel | home (new generation) |
| outcome phases | finish | home (new generation) |
| any | reset | home (new generation) |

## Payment boundary

`CheckoutSession.confirmedPayment` is a `CashPayment`, which stores a list of
notes but can only be created from a single note (`init(singleNote:)`). The
MVP is one payment note per checkout; paying with several notes can be added
later without changing the session or `CheckoutCalculator`.

## Returned-note policy (`CandidateGate.decideReturnedNote`)

| Reading | Decision |
|---|---|
| Camera, confidence ≥ 0.90, ≥ 3 agreeing observations | Count immediately; announce currency and denomination; success haptic; Remove Last Note available |
| Camera, confidence 0.70–0.90 (uncertain) or < 3 observations (unstable) | Needs explicit confirmation |
| Manual selection or simulated reading | Needs explicit confirmation |
| Confidence < 0.70 or missing | Rejected |
| Different currency, unsupported value | Rejected |

## Voice and typed commands

Final transcripts and typed text go through `VoiceCommandRouter`
(deterministic phrase table) to candidate actions; the store sends the first
one `permits(_:)` allows. There is no AI in this path.

## Money

- `Money` = `Int` minor units + `Currency`. All three Phase 1 currencies have
  two minor-unit digits (ISO 4217).
- `adding`, `subtracting`, `compare` use typed throws
  (`MoneyError.currencyMismatch`, `.overflow`). `Money` is deliberately
  **not** `Comparable`, so mixed-currency comparison can't compile by accident.
- `MoneyParser` turns typed text into `Money` using integer arithmetic only.
- Display formatting uses `Decimal` + `FormatStyle` (locale-aware; not used
  for decisions). Spoken formatting says units: "12 dollars and 50 cents".

## Recognition gate

`CandidateGate` is the only way a scan becomes usable:

1. Manual entries skip confidence checks (the person chose the value).
2. Camera/simulated candidates need a confidence. A missing confidence is
   **insufficient** — the app never invents one.
3. Confidence must reach `RecognitionPolicy.acceptThreshold` (0.90, an
   initial engineering value, not a calibrated result).
4. Camera candidates need at least `minimumAgreeingObservations` (3) agreeing
   observations.
5. Banknotes must match the transaction currency and be an approved
   denomination; totals must be positive and plausible.

Even after the gate, totals and payment notes need explicit confirmation.

## Announcements

The state machine emits semantic `Announcement` values, not strings.
`AnnouncementComposer` turns them into text, labelling simulated readings
("Simulated reading…") and manual entries. The same text is used for
VoiceOver announcements now and speech output in Phase 4, and it is stored so
**Repeat** can say it again.
