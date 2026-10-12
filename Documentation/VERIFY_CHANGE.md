# Verify Change

Checks the change handed back, one note at a time, against the change
expected. Deterministic and local (`ReturnedChangeSession`); the screens
only display it and send actions.

## Two ways in

| From | Expected change comes from |
|---|---|
| Checkout result, **Check my change** (only when change is due) | `CheckoutSession.outcome` — the confirmed total and note |
| Home, **Verify Change** | Typed by the person, then its amount **and currency** confirmed (approved 2026-09-24). No currency is ever assumed. |

## Counting notes

Each returned note is scanned or chosen from the **expected currency's
notes only**. `CandidateGate.decideReturnedNote` decides (approved
2026-09-24):

| Reading | Result |
|---|---|
| Camera, stable (≥3 agreeing frames), confidence ≥ 0.90 | Counted at once, announced, with a haptic; **Remove last note** is offered |
| Chosen by the person | "Count it?" — needs **Yes, count it** |
| Camera, confidence 0.70–0.90, or unsteady | "Count it?" with the reason shown |
| Simulated | "Count it?", labelled simulated |
| Low confidence, other currency, unsupported value (e.g. a coin) | Rejected and said why; never counted |

The same scan result can never be counted twice (request IDs). Each scan
reads one note; the next note needs another press.

The screen shows **Change expected**, **Received so far** and the status in
words and an icon (never colour alone), plus the list of counted notes and
how each was counted (scanned / chosen).

## Results

| Result | When | Offered |
|---|---|---|
| Change matches | Received equals expected (at once, when a note makes it exact) | Remove last note, Done |
| More than expected | Received exceeds expected (at once) | Remove last note, Done |
| Less than expected | **That's all the change** with less than expected | Add more notes, Remove last note, Done |
| Change not checked | **That's all the change** with no notes counted | Add more notes, Done |

Results say what was counted ("based on the notes counted"); NaviNote never
claims the change is guaranteed correct, and never judges the cashier.
**Done** returns home; nothing is saved.

Coins aren't supported. Change that includes coins can't be fully
checked; for example, 3 dirhams in change is coins only.

## Verification

| Area | Status |
|---|---|
| Session arithmetic, tiered policy, duplicates, currency guard (domain + state machine) | unit-tested |
| From checkout and from home; matches / less / more / not checked; confirm, reject, remove last, add more; currency required; only expected-currency notes | UI-tested |
| Accessibility audits of every Verify Change screen, standard and largest text | UI-tested |
| Scanning real returned notes on a physical iPhone | **not yet verified** |
| With VoiceOver on | **not yet verified** |

## Physical-iPhone checklist

1. Checkout: total 15 dirhams, pay with a 20 → **Check my change** → scan
   a 5 dirham note (if you have one) or choose it → "Change matches".
2. Home → **Verify Change** → type 20, choose UAE dirhams, confirm → scan
   the 10 dirham note: a steady, clear scan counts at once ("Counted a 10
   dirham note…"), otherwise it asks "Count it?".
3. Scan the same 10 dirham note again → it's counted again (it's a new
   note to NaviNote) → **Remove last note** takes it off.
4. Scan the $1 note during a dirham check → rejected, not counted.
5. **That's all the change** with 10 of 20 → "Less than expected: 10
   dirhams".
6. VoiceOver on: each count and the result are read once; every button is
   reachable and labelled.
