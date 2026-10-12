# Reading Banknotes (Phase 7)

## What it is — and isn't

`BanknoteTextParser` identifies a note's **currency and value from its
printed text**, using the same on-device text recognition as totals.

- It is **not** a trained image classifier. No labelled banknote dataset or
  validated model exists, and none is claimed.
- It works only when the issuer text and the value are legible. A folded,
  worn, crumpled or partly covered note may not be read.
- It identifies **value only**. It never says whether a note is genuine.
- **Coins are not supported**, and the screen says so.
- Accuracy is **unknown until tested with real notes**; no accuracy figure is
  claimed.

## Rules

| Step | Rule |
|---|---|
| Currency | Issuer text or currency words: "FEDERAL RESERVE NOTE", "UNITED STATES OF AMERICA", "DOLLAR(S)"; "UNITED ARAB EMIRATES", "CENTRAL BANK OF THE U.A.E.", "DIRHAM(S)"; "CENTRAL BANK OF KENYA", "KENYA", "SHILLING(S)", "SHILINGI". None → nothing; more than one → ambiguous. |
| Value (words) | Whole words, longest phrase first: ONE THOUSAND, FIVE/TWO/ONE HUNDRED, FIFTY, TWENTY, TEN, FIVE, TWO, ONE; Swahili ELFU MOJA, MIA TANO/MBILI/MOJA, HAMSINI. Only approved values for that currency. Different values → ambiguous. |
| Value (numerals) | Only if no value words: standalone numbers that are approved values for that currency; the most frequent, seen at least twice and more often than any other. Serials ("L 12345678 A"), years ("SERIES 2017"), plate codes ("B2") are ignored. |
| Confidence | Each fact (currency, value) takes the confidence of the clearest line stating it; the reading takes the weaker fact. Missing → none; never invented. |
| Currency across frames | `BanknoteScanContext`: once the same single currency has been seen in ≥2 frames of this scan (and no other currency at all), a frame showing a value but no legible currency uses it. A frame naming a different currency is ambiguous. |
| Stability | `StabilityTracker`: ≥3 agreeing frames in a 12-frame window; ambiguous frames block; the value needs 3× the support of any other value. |
| Other side | If a currency is seen but **no value at all** for 15 frames, NaviNote says once: "NaviNote can't read this note's value on this side. Try turning it over." A real note value seen even once in a frame (too little to read) resets the count, and once a value has been clearly seen (confidence ≥ 0.70) in two frames of the scan, the suggestion is off for the rest of that scan — the value is on this side. It never guesses the value. |
| Gate | `CandidateGate`: confidence ≥ 0.90; unsupported values rejected with "Coins aren't supported". |

Each scan reads **one** note; the next note needs another press, so the same
note in view can't be counted twice.

## Known limits

- English-side text only: Vision is configured for English, so the Arabic
  side of dirham notes is not read. Show the English side.
- US notes: the Federal Reserve district number (1–12) printed on some notes
  can match a valid value (e.g. "5"), which is why value **words** win over
  numerals.
- **The portrait side of the US $1 cannot be read.** Its value text is
  decorative and small; on a physical iPhone, a garbled "ONE" appeared in
  only a handful of frames. Rather than fuzzy-match, NaviNote asks the
  person to turn the note over. The other side (large "ONE") reads well.
- Dirham notes: "10" is often seen once per frame, and a numeral needs two
  sightings in a frame, so reading can take a few seconds. (Device finding,
  2026-09-26: this briefly-seen value wrongly triggered "Try turning it
  over" during checkout; fixed — see the Other side rule. It still happened
  in Verify Change when "10" disappeared for longer than the delay; the
  "clearly seen twice" rule was added. Regression tests added; device
  retest pending.)

## Verification

| Area | Status |
|---|---|
| Parser (USD, AED, KES text layouts), stability, Read Currency flow | unit-tested |
| Read Currency screen, camera-unavailable path, accessibility audit | UI-tested |
| AED 10 and USD 1 on a physical iPhone | physical-device-tested (2026-09-26) |
| Other AED and USD values | **not yet verified** |
| With VoiceOver on | **not yet verified** |
| Real KES notes | **not yet verified** (none available) |

## Physical-iPhone checklist (AED and USD notes)

Record each note's value, which side you showed, the lighting, and what
NaviNote said.

1. **Read Currency → Scan with camera** with each AED note you have (English
   side up): it should say e.g. "This is a 50 UAE dirham note."
2. Each USD note you have (either side).
3. Hold the note at different distances (10–40 cm) and slight angles.
4. A folded or partly covered note: it should take longer or say it couldn't
   read — never name a wrong value.
5. Two different notes in view at once: it should *not* name either
   (expected: couldn't read).
6. The Arabic side of a dirham note: expected to fail (known limit).
7. A coin: never named as a note.
8. VoiceOver on: the result is read once, e.g. "This is a 20 US dollar note".
9. **Done** returns home.

## Physical-device findings

### 2026-09-25 — iPhone 17 Pro Max, iOS 27.0

| Note | Side | Result |
|---|---|---|
| AED 10 | English | Read correctly — pass |
| USD 1 | Both | "Isn't sure yet" — **fail** |

**Cause:** the reading reached the final gate (so ≥3 frames agreed) but with
confidence between 0.70 and 0.90. Confidence was the *lowest* of every line
naming the currency or value, so decorative lettering on the 1 dollar note
("FEDERAL RESERVE NOTE", "THE UNITED STATES OF AMERICA"), read with lower
confidence, held back a clearly read "ONE DOLLAR".
**Fix:** each fact (currency, value) takes the confidence of the clearest
line stating it; the reading takes the weaker fact. Disagreeing lines still
make the reading ambiguous. Regression tests added.

**Retest:** still failed. Debug diagnostics (below) showed the currency text
is rarely legible in the same frame as the value on the $1 portrait side,
and its value almost never. Added the scan-wide currency context, plainer
issuer markers ("IN GOD WE TRUST", "THE DEPARTMENT OF THE TREASURY",
"WASHINGTON D C") and the "try the other side" guidance.

### 2026-09-26 — iPhone 17 Pro Max, iOS 27.0

| Note | Side | Result |
|---|---|---|
| USD 1 | Portrait (Washington) | Currency seen in 81 frames, no value accepted; said "Try turning it over" — pass (expected behaviour) |
| USD 1 | Large "ONE" | "1 US dollar note" within a few frames — pass |
| AED 10 | English | Read correctly, twice — pass |

The Federal Reserve district number "12" was seen repeatedly on the portrait
side and correctly ignored (not a US note value). No wrong value was named.

## Debug diagnostics

Debug builds only (compiled out of Release): launching with
`NAVINOTE_SCAN_DIAGNOSTICS=1` prints one summary line per frame to standard
output — keyword hits, numbers and confidences, never the recognized text.
A second switch, `NAVINOTE_SCAN_DIAGNOSTICS_TEXT=1`, prints recognized text
with digit runs of 5+ masked, for diagnosing a specific note on the
developer's own device. See SECURITY.md.

```bash
DEVICECTL_CHILD_NAVINOTE_SCAN_DIAGNOSTICS=1 xcrun devicectl device process launch --console --terminate-existing --device <device-id> com.saarangvibin.navinote
```

## Online note check (prototype, hybrid recognition)

Approved 2026-10-09. In Read Currency, **Check note online (prototype)**
recognises a note from its overall **appearance** (colours, illustrations,
patterns, layout), so it doesn't depend on the printed value being legible.

- **Consent:** nothing is photographed or sent unless **Settings → Send note
  photos** is on (off by default) *and* the person presses the button. Only
  shown when a backend is set up in the build.
- The live camera preview appears at the top of Read Currency (no
  scrolling) and stays on until the answer. **1.5 seconds to aim** before
  the photo (device findings: 0.5 s far too quick; 3, 2.5 and 2 s slow).
- **One photo** (≤ 1024 px JPEG) is taken after focus/exposure settle, held
  in memory only, sent to the NaviNote backend (never directly to OpenAI),
  never stored or logged.
- It is **read twice** — appearance only, and with printed text allowed —
  and validated on the backend and again in Swift (`OnlineNoteValidator`).
- **Decision (`OnlineNoteDecision`), from measured results
  (BANKNOTE_EVAL.md):** a denomination is announced only when both reads
  see a banknote, agree on currency and value, and neither is "high"
  uncertainty. Otherwise: "isn't sure", "couldn't see a banknote", "couldn't
  take a photo" or "online check isn't available" — never a guess.
- The result says how it was recognised ("checked online from its
  appearance; two independent reads agreed"), the visual evidence, and
  whether the printed value was also readable. It never says a note is
  genuine.
- Checkout and Verify Change are unchanged: they still use the on-device
  reader and their confirmation rules.
- Cancelled when leaving Read Currency or the app; late results ignored.

| Area | Status |
|---|---|
| Two-read rule, validation, state machine, consent gate, cancellation | unit-tested |
| End to end on a physical iPhone with real AED notes (2026-10-11) | physical-device-tested: AED 10 and AED 5 identified (both sides), a non-note → "couldn't see a banknote", one 5 read as 100 by the appearance read → disagreement → "not sure" (no wrong announcement) |
| 1.5-second aiming time | physical-device-tested (2026-10-11): feels right |
