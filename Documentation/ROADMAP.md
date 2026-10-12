# NaviNote Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 | Read-only audit of the Flutter prototype | Done |
| 1 | Native Xcode project foundation | Done |
| 2 | Deterministic domain + authoritative state machine | Done |
| 3 | Design system + home screen/application shell | Done |
| 4 | Audio coordinator (push-to-talk, speech output) | Done; crash and VoiceOver fixes device-verified; rest of checklist pending ([AUDIO.md](AUDIO.md)) |
| 5 | Camera + on-device Vision OCR | Done; camera and hints device-verified ([CAMERA.md](CAMERA.md)) |
| 6 | Receipt/terminal total reader | Done; test receipts device-verified; printed receipts pending ([TOTALS.md](TOTALS.md)) |
| 7 | Currency reader (assisted, honest) | Done — AED 10 and USD 1 physical-device-tested; other values, KES and VoiceOver not yet verified ([CURRENCY.md](CURRENCY.md)) |
| 8 | Checkout engine UI | Done — checkout with a real AED 10 note physical-device-tested; VoiceOver not yet verified ([CHECKOUT.md](CHECKOUT.md)) |
| 9 | Returned-change verification UI | Done in code, unit- and UI-tested — **real returned notes on iPhone pending** ([VERIFY_CHANGE.md](VERIFY_CHANGE.md)) |
| 10 | Secure Astra backend | Done — backend-tested (mocked and live `gpt-6-astra`), physical-device-tested on iPhone over local Wi-Fi; VoiceOver with Astra not yet verified; production host and App Attest not implemented ([Backend/README.md](../Backend/README.md)) |
| 11 | Ask NaviNote | Done — physical-device-tested (buttons, Talk, typing, online fallback); spoken "Close" fixed and retested; VoiceOver not yet verified ([ASK_NAVINOTE.md](ASK_NAVINOTE.md)) |
| 12 | Accessibility verification | Done for the core flows — automated audits of every screen (largest text, dark, landscape) UI-tested; VoiceOver-tested on iPhone: checkout, Talk, Read Currency, Ask NaviNote, landscape. Some manual checks remain |
| 13 | Testing + device hardening | Ongoing |
| 14 | Demo + release hardening | Not started |
