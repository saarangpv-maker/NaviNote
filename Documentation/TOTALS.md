# Reading Totals (Phase 6)

`ReceiptTotalParser` (`NaviNote/Core/Scanning/ReceiptTotalParser.swift`) finds
the total on a receipt, bill or payment-terminal screen. It is pure,
deterministic and conservative: when in doubt it returns nothing. Every
result still has to pass stability, the recognition gate and the person's
confirmation.

## How it reads

1. **Rows.** Recognized lines are grouped into visual rows by vertical
   position, so "TOTAL" on the left and "25.00" on the right are one row even
   when Vision reports them separately or out of order.
2. **Row labels.**

   | Label | Strength | Examples |
   |---|---|---|
   | Grand total | 100 | "Grand Total" |
   | Due / payable / total incl. tax | 95 | "Amount due", "Balance due", "Total payable", "To pay", "Total incl. VAT" |
   | Total | 80 | "Total", "TOTAL AED" |
   | Amount / sale / pay | 60 | "Amount", "SALE", "PAY" |
   | Excluded — never the total | — | cash, change, tendered, paid, card, Visa, tip, discount, subtotal, excl., tax, VAT, GST, service charge, deposit |
   | Reference — numbers ignored | — | tel, phone, date, time, invoice, order, TRN, VAT reg, card no, auth, ref, table, terminal ID |

3. **Amounts.** `12.50`, `1,250.00`, `8976.00`, `12,50` (decimal comma), and
   whole numbers. Numbers attached to `/ : - + %` (dates, times, phone
   numbers, negatives, percentages) are ignored. If a label row has several
   numbers ("TOTAL 3 ITEMS 45.50"), the one with decimals is used.
4. **Choice.** The strongest label wins. If two *different* amounts share the
   strongest label, the result is **ambiguous → nothing**. A label with no
   number uses the next row if that row has exactly one amount.
5. **No label.** Accepted only if it is the *only* amount in view and looks
   like money (has decimals or a currency marker) — typical of a terminal
   showing "AED 25.00".
6. **Currency.** From markers on the chosen rows, else from the whole page —
   but only if exactly one currency is mentioned. Markers: AED, Dh/Dhs,
   dirham, د.إ, درهم; USD, US$, $, dollar; KES, KSh, KShs, shilling. None or
   several → no currency; the person chooses. Never guessed.
7. **Confidence.** The lowest recognizer confidence among the lines used; if
   any has none, none. Never invented.

`TotalStabilityTracker` then requires 3 agreeing frames (on the amount) in a
6-frame window. The currency comes from the agreeing frames; conflicting
currencies → none.

## Manual entry

"Or type the total" is always on the screen. Parsing is exact and follows the
device's decimal separator. The currency can be picked there or on the
confirm screen; confirming is refused until a currency is chosen.

## Evidence without images

`ReceiptTotalParser.analyze(_:)` returns *how* the total was found
(`labelledRow`, `labelledNextRow`, `singleAmount`, label strength) or why not
(`noText`, `noAmount`, `ambiguous`). That is enough to debug a misread
without keeping any image or text.

## Fixtures

All test receipts in `NaviNoteTests/Scanning/ReceiptTotalParserTests.swift`
are invented (AED café, USD market, KES supermarket, and terminal screens)
and contain no real business or personal data.

## Verification

| Area | Status |
|---|---|
| Parser, stability, manual entry parsing | unit-tested |
| Total screens (type, confirm, currency, reject, cancel, invalid input) | UI-tested |
| Invented test receipts shown on a screen, physical iPhone | **physical-device-tested** — all six slides pass |
| Printed receipts and real card terminals | **not yet verified** |

## Physical-iPhone checklist (Phase 6)

Use real receipts and, if possible, a card-terminal screen. Note the
currency, what it read, and whether it was right.

1. Start Checkout → Continue → **Scan with camera** on a printed receipt:
   it proposes the **total** (not subtotal, VAT, cash or change) and asks
   you to confirm.
2. A receipt where the total line has no currency: it asks you to choose.
3. A long receipt that doesn't fit: move along it; it should never propose
   an item price as the total.
4. A payment terminal or phone screen showing only "AED 25.00" or similar.
5. Glare, a crumpled receipt, low light: it should take longer or say it
   couldn't read — never propose a wrong amount confidently.
6. **No, scan or type again** returns to the total step.
7. **Type the total** with and without choosing a currency; try an invalid
   amount like `12.345`.
8. VoiceOver on: the total screen and confirm screen read clearly, and the
   amount is spoken with its currency ("25 dirhams").
9. Report any receipt it misread (a photo helps me build a sanitized test
   fixture — cover personal details first).

## Physical-device findings

### 2026-09-25 — iPhone 17 Pro Max, iOS 27.0, test receipts on a Mac screen

| Slide | Expected | Read | Result |
|---|---|---|---|
| 1 AED café | 31.50 dirhams | 31.50 dirhams | pass |
| 2 USD market | 7 dollars | 7 dollars | pass |
| 3 KES supermarket | 1,360 Kenyan shillings | 1,360 Kenyan shillings | pass |
| 4 No currency | 42.00, ask for currency | **42 dollars** | **fail — currency guessed** |
| 5 Terminal | 25 dirhams | 25 dirhams | pass |
| 6 Two totals | nothing (ambiguous) | **12 dirhams** | **fail — ambiguity missed** |

**Slide 4 cause:** a bare "$" anywhere on the page counted as US dollars;
text recognition sometimes reads a bold "S" as "$" ("$AMPLE $HOP"), and one
such frame was enough to set the currency.
**Fix:** "$" counts only next to a number; the currency must be named by at
least 2 of the agreeing frames.

**Slide 6 cause:** frames that saw both totals were rejected, but frames
that caught only the second total looked clean, and three of them agreed.
**Fix:** parsers report `.ambiguous` frames; `TotalStabilityTracker` blocks
acceptance while any ambiguous frame or any different amount is in the
6-frame window.

Both are covered by regression tests.

**Retest after the first fix:** slide 5 (terminal, very large amount) mostly
failed. Held close, some frames read only part of the amount ("5.00"), and
the first fix treated *any* different amount as a veto.
**Second fix:** only frames that see competing totals at once veto. Other
disagreement must be outweighed: the amount needs at least three times the
support of any different amount in the window (one stray frame tolerated;
repeated disagreement never produces a total). Regression tests cover both
directions.

**Device retest after the second fix (2026-09-25):** all six slides read as
expected — slides 1–3 and 5 correct, slide 4 asks for the currency, slide 6
proposes nothing. **physical-device-tested** (test receipts on a screen;
printed receipts still to be tried).
