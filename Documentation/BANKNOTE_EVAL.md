# Banknote Recognition — Evaluation Results

Measured on the user's own photos (`TestData/BanknotePhotos/`, git-ignored).
Model output is never treated as a calibrated probability: decision rules
are chosen from these results.

## 2026-10-11 — cloud vision (`gpt-6-astra`), 48 photos

Photos: AED 5, 10, 50, 100 (old paper and polymer), 500 (paper), 1000
(paper and polymer); both sides; many folded, crumpled, rolled, hand-held,
at an angle, in cluttered scenes or with a second note in frame. **No
photos with every value marking covered yet; no "not a note" photos; none
of AED 20 or 200.** Each photo read twice: allowed to use printed numerals
("with text") and told not to ("appearance only").

| | With text | Appearance only |
|---|---|---|
| Correct | 43 / 48 (90%) | 40 / 48 (83%) |
| Said "not sure" (abstained) | 3 | 7 |
| No answer (incomplete) | 1 | 0 |
| **Wrong** | **1** — folded old 100 → 1000, *low* uncertainty | **1** — tightly rolled 5 → 100, *medium* |

- Appearance-only answers at *low* uncertainty: 35 / 35 correct. With-text
  answers at *low* uncertainty: 41 / 42 (one confident error) — the model's
  own uncertainty is not sufficient.
- **Candidate rule:** announce only when the two reads agree and neither is
  "high" uncertainty. On this data: 0 wrong, ~40 / 48 identified, the rest
  → scan again / confirm. 0 errors in ~40 is consistent with a true error
  rate up to ~7% (95%).
- Cost per read: ~1,230 input + ~285 output tokens; median ~5.3 s.
- First run had 15 "incomplete" replies: the 400-token output limit was
  consumed by the model's reasoning on hard photos. Raised to 2,000.

## 2026-10-11 — on-device Create ML classifier, same photos

30 train / 18 test (fixed split; AED 500 had no training photos). Top-1
accuracy 39%; errors at 0.94–1.00 model "confidence". **Not usable** — far
too little data (needs roughly 25+ photos per side per note).

## Adopted in the app (2026-10-11)

The candidate two-read rule is what `OnlineNoteDecision` implements for
the online note check prototype (CURRENCY.md). It will be re-checked when
fully covered and not-a-note photos are evaluated.

## Still needed

1. Photos with **every** value numeral and value word covered (in each
   side's `value-covered` folder).
2. 10+ "not a note" photos (receipts, a dollar, hands, wallet, table).
3. More photos per side for the on-device classifier.
