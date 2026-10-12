# NaviNote

**NaviNote helps blind and visually impaired people pay with cash
independently.** It reads a bill or payment-terminal total, identifies
banknotes, works out the change you should get back, and checks the change
you actually receive — by voice, with VoiceOver, or with buttons alone.

A native iPhone app in Swift and SwiftUI, with an optional small backend for
language help. No third-party dependencies in the app.

> **Status: working prototype.** The core flows have been used on a
> physical iPhone, including with VoiceOver. It is not on the App Store.
> Some parts are prototypes and are labelled as such below.

## What it does

| Feature | What happens | Verified |
|---|---|---|
| **Checkout** | Scan a receipt or terminal screen (or type the total) → confirm it → add the notes you pay with, one at a time → NaviNote works out your change | Physical iPhone, VoiceOver |
| **Read Currency** | Hold up a note; NaviNote reads its printed value on the iPhone and says it | Physical iPhone (AED 10, AED 5, USD 1) |
| **Check note online** *(prototype, opt-in)* | Recognises a note from its overall appearance — useful when the printed value is folded away. One photo, read twice; announced only when both reads agree | Physical iPhone; evaluated on 48 labelled photos ([results](Documentation/BANKNOTE_EVAL.md)) |
| **Verify Change** | After checkout, or on its own: count each returned note and hear whether the change matches, is short or is too much | Unit- and UI-tested; physical iPhone |
| **Ask NaviNote** | "What's the total?", "How much change should I get?", "What should I do next?" — answered on the iPhone from the transaction's confirmed facts | Physical iPhone |
| **Talk** | Push-to-talk voice commands; on-device speech recognition; stops listening by itself when you finish speaking | Physical iPhone, VoiceOver |
| **Astra** *(optional, off by default)* | A language companion: understands unusual phrasings and answers general questions, through NaviNote's own backend | Live model and physical iPhone |

Supported banknotes: **UAE dirham** (5–1000), **US dollar** (1–100) and
**Kenyan shilling** (50–1000). Coins are not supported, and NaviNote says so.

## Design principles

- **Money is exact and local.** All amounts are whole minor units with an
  explicit currency; change is calculated on the iPhone by deterministic
  code, never by an AI model.
- **Nothing uncertain is announced as fact.** Camera readings need several
  agreeing frames; totals and payment notes are always confirmed; if NaviNote
  isn't sure, it says so and offers another way.
- **One source of truth.** A single, pure state machine drives every
  workflow; views only render state and send actions; late or stale results
  from the camera or network are discarded.
- **Accessible first.** Every control is labelled for VoiceOver, text uses
  Dynamic Type, everything works with buttons alone, at the largest text
  sizes, in dark mode and in landscape.

## Privacy

- No transaction history is saved. No payment cards or wallet details, ever.
- Camera and speech processing happen **on the iPhone**. The microphone
  only listens after you press Talk; audio is never uploaded.
- Leaving the iPhone only when *you* turn it on in Settings:
  - **Astra language help** sends your words and the transaction's confirmed
    amounts (never images or audio) to the NaviNote backend.
  - **Send note photos** lets "Check note online" send one photo of a note.
- The OpenAI API key lives only on the backend. The app contains no secrets.

NaviNote never says whether a banknote is genuine, and never guarantees a
calculation.

## Planned: smart cane integration

NaviNote grew out of an earlier "Smart Cane Assist" prototype — a companion
app for a Bluetooth Low Energy smart walking cane with walking mode and
obstacle and water alerts. Those features were deliberately left out of
this first version so the cash workflow could be built and verified on its
own. **They are not implemented here.**

The plan is to bring the cane back as an optional companion to NaviNote,
following the same rules as the rest of the app:

- **Optional:** NaviNote must keep working fully without a cane.
- **One voice:** cane alerts would go through NaviNote's single audio
  coordinator (and VoiceOver when it's on), so alerts and payment messages
  never talk over each other, with safety alerts taking priority.
- **Explicit actions only:** the cane would never start a checkout or
  confirm a payment on its own.
- **Tested on hardware:** nothing about the cane will be described as working
  until it has been tested with the physical device.

*(Design details — pairing, which alerts, and how cane buttons map to
NaviNote actions — are still to be decided.)*

## Running it

Requirements: Xcode 27 or later, an iPhone or simulator with iOS 17+.

```bash
open NaviNote.xcodeproj
```

Choose the **NaviNote** scheme and an iPhone, then Run. To run on your own
iPhone, set your own development team under *Signing & Capabilities*.

Tests:

```bash
xcodebuild -project NaviNote.xcodeproj -scheme NaviNote \
  -destination 'platform=iOS Simulator,name=iPhone 17e' test
```

The app works fully without the backend. To try Astra and the online note
check, see [Backend/README.md](Backend/README.md) — it needs your own OpenAI
API key in `Backend/.env` (never committed).

## Project layout

| Path | Contents |
|---|---|
| `NaviNote/Core` | Money, the state machine, recognition rules — Foundation only |
| `NaviNote/Services` | Camera, text recognition, audio, backend clients — behind protocols with test fakes |
| `NaviNote/Features` | SwiftUI screens |
| `NaviNoteTests`, `NaviNoteUITests` | Unit tests and UI/accessibility tests |
| `Backend` | Optional TypeScript service in front of the OpenAI API |
| `Documentation` | Architecture, security, accessibility, testing and evaluation notes |

Good places to start: [Architecture](Documentation/ARCHITECTURE.md) ·
[Security](Documentation/SECURITY.md) ·
[Accessibility checklist](Documentation/ACCESSIBILITY_CHECKLIST.md) ·
[Testing](Documentation/TESTING.md) · [Roadmap](Documentation/ROADMAP.md).

## Status and limits

- Not yet tested: Kenyan shilling notes; AED 20 and 200; Switch Control,
  Bold Text and Increase Contrast on a device.
- The online note check is a prototype: it needs the backend, internet and
  your consent, and has been evaluated on a small set of photos.
- App Attest (only genuine NaviNote installs may call the backend) is
  designed but not implemented; required before any public backend.

## Licence

Copyright © 2026 Saarang Vibin. All rights reserved. The source is
published for review; no licence is granted to copy, modify or
redistribute it.
