# Checkout

Checkout has three steps, each an explicit user action. Every value is
confirmed before it is used.

| Step | Screen | Phase(s) |
|---|---|---|
| 1. Total | `TotalCaptureView`, `ConfirmTotalView` | `acquiringTotal`, `confirmingTotal` ([TOTALS.md](TOTALS.md)) |
| 2. Payment (one or more notes) | `PaymentNoteCaptureView`, `ConfirmPaymentNoteView` | `acquiringPaymentNote`, `confirmingPaymentNote` |
| 3. Change | `CheckoutResultView` | `showingExpectedChange` |

## Payment notes

- Notes are added **one at a time**: scan each note (the same printed-text
  reader as Read Currency, [CURRENCY.md](CURRENCY.md)), or choose it from
  the notes of the **checkout's currency only**, so a mixed-currency payment
  can't be chosen. A scanned note in another currency is rejected by
  `CandidateGate`.
- Every note, scanned or chosen, needs **Yes, pay with this note**. The
  source is shown: read from printed text, chosen by you, or simulated.
- While the notes don't cover the total, the screen shows **Total**, **Paid
  so far** and **Still needed**, and the notes added; NaviNote says e.g.
  "Added a 20 dirham note. Paid 20 dirhams so far. 5 dirhams still needed."
- As soon as the notes cover the total, the change is shown (approved
  2026-09-26, replacing one note per checkout).
- **Remove last note** is offered while adding notes and on the result.
- **That's all my notes** shows what is still owed when the notes don't
  cover the total.
- `CashPayment` is never empty and never mixed-currency; it refuses a sum
  that would overflow.

## Change

`CheckoutCalculator` works out the outcome from the confirmed total and note
in exact minor units, on the iPhone. The screen only displays
`CheckoutSession.outcome`.

| Outcome | Shown | Said |
|---|---|---|
| Change due | "Change due" + amount (success icon) | "You paid 20 dollars for a total of 17 dollars and 35 cents. You should receive 2 dollars and 65 cents in change." (paid = all notes) |
| Exact | "Exact payment", no change due | "… Exact payment. No change is due." |
| Notes don't cover it (after "That's all my notes") | "Still to pay" + amount (warning icon) | "… That doesn't cover the total. You still need to pay …" |

**Finish checkout** returns home and starts a new session; nothing is saved.
When change is due, **Check my change** continues into Verify Change
([VERIFY_CHANGE.md](VERIFY_CHANGE.md)).

## Verification

| Area | Status |
|---|---|
| Calculation, confirmation rules, stale events (state machine) | unit-tested |
| Choose / confirm / reject note, several notes, remove last note, "That's all my notes", three outcomes, only the checkout currency's notes, Finish, Cancel | UI-tested |
| Paying with several real notes on a physical iPhone | **not yet verified** |
| Accessibility audits of the three screens, standard and largest text | UI-tested |
| Checkout with a real AED 10 payment note on a physical iPhone | physical-device-tested (2026-09-26): change correct; see findings |
| With VoiceOver on | **not yet verified** |

## Physical-device findings

### 2026-09-26 — iPhone 17 Pro Max, iOS 27.0

- 10 dirham note for a 7 dirham total: note read and confirmed, "3 dirhams"
  change — pass.
- While scanning the dirham note, NaviNote said "Try turning it over" even
  though the value was on that side. Cause: "10" was seen once per frame,
  which isn't enough to read but was counted as "no value". Fixed; the
  suggestion now needs frames with no value at all. Device retest pending.
- Requested: after the change is worked out, check the change actually
  handed back. That is Phase 9 (returned-change verification).

## Physical-iPhone checklist

1. Checkout → type a total (e.g. 7 dirhams) → confirm.
2. **Scan with camera** with a 10 dirham note → "You're paying with a 10
   dirham note. Is that right?" → Yes → "You should receive 3 dirhams in
   change."
3. Repeat with a dollar total and the $1 note (large "ONE" side).
4. Scan a dirham note during a dollar checkout: it must be rejected, not
   used.
5. Pay 25 dirhams with a 20 and a 10 (scan or choose each): after the 20
   it says 5 dirhams still needed; after the 10, "5 dirhams in change".
   **Remove last note** takes the 10 off again.
6. Pay with notes smaller than the total, then **That's all my notes**: it
   says how much is still to pay.
7. With VoiceOver on: each step's message is read once; every button is
   reachable and labelled (e.g. "20 dollar note").
8. **Finish checkout** returns home.
