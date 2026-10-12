# Ask NaviNote

A narrow assistant for the current transaction. It opens from Home, or by
saying or typing "Ask NaviNote" anywhere, on top of the current step, and
**Close** returns to that step. Every question has a button; typing and Talk
also work.

## Deterministic first

`AskQuestionRouter` matches the question; `AskAnswers` reads the state
underneath (the step Ask NaviNote was opened from); `AnnouncementComposer`
writes the words. No network, no model.

| Question | Answer comes from |
|---|---|
| What's the total? | Confirmed total, or a read total labelled "not confirmed yet" |
| Which currency? | Confirmed currency, or a chosen one labelled unconfirmed; never assumed |
| How much did I pay? | Confirmed payment notes |
| How much change should I get? | `CheckoutSession.outcome` (or the confirmed expected change in Verify Change) |
| How much have I received? / What's still missing? | `ReturnedChangeSession` |
| What did NaviNote scan? | The latest reading still in the session, with its status (unconfirmed / confirmed / counted) and "Simulated" when simulated |
| What should I do next? / Explain this screen | Fixed text per screen |
| Repeat the last instruction | The step's instruction (the Repeat button repeats the last *answer*) |
| What can I ask? | Help text |

Inside Ask NaviNote, commands still work after questions are checked:
"close", "go back", "repeat", "help".

## Astra: the accessibility companion

Approved 2026-10-09: questions NaviNote can't match go to Astra **only** if
Astra language help is on (Settings; off by default) and set up in the
build. They may be on **any topic**: small talk, everyday questions,
general knowledge, accessibility tips. The request is `kind: askQuestion`,
about the screen underneath, with only confirmed facts.

| Astra's reply | Shown as | Rules |
|---|---|---|
| `answer` (this transaction / NaviNote) | "Online answer from Astra. Amounts come from NaviNote." | Only NaviNote's amounts, in digits |
| `general` (anything else) | "General answer from Astra, not about your transaction." | Ordinary numbers fine; a number next to a money word or "$" must be NaviNote's; no money in words |
| `unsupported`, invalid, offline, slow | "Astra couldn't help with that. I can still answer questions about this transaction…" | — |

Always: no financial or investment advice; never calculates money; never
says whether a note is genuine (replies mentioning genuine / counterfeit /
fake are discarded, and "is this note real?" is answered by NaviNote itself:
"It can't tell whether a note is genuine"); proposed actions are ignored in
Ask NaviNote. With Astra off: "I can answer questions about this
transaction… For anything else, turn on Astra language help in Settings."

Live check (2026-10-09, `gpt-6-astra`): small talk, a fun fact, a wallet
organisation tip, the change due (NaviNote's 2.65 USD), a coffee price (no
invented amount), "real or fake" (declined), investing (no advice), the
time (doesn't know; suggests Siri), and a prompt injection (gave the real
amount): all correct.

## Nothing kept

The current answer is just NaviNote's current message; closing Ask
NaviNote returns to the step's instruction. A pending online question is
cancelled when Ask NaviNote closes or the screen changes (`cancelAstra`), and
a late reply is ignored. This also now applies to Astra command
interpretation: leaving a screen cancels its pending interpretation.

## Verification

| Area | Status |
|---|---|
| Question matching, answers per state, unconfirmed labelling, no guarantee/genuineness claims | unit-tested |
| State machine: questions only in Ask NaviNote, no workflow change, Astra answer / failure / cancellation / stale reply | unit-tested |
| Store: deterministic answers never use Astra; commands inside Ask; Astra off → refusal; Astra answer about the screen underneath; invalid amounts discarded; actions ignored; close while waiting | unit-tested |
| Buttons, typing, out-of-scope request, Close back to the step; accessibility audits at standard and largest text | UI-tested |
| Buttons, Talk, typing, out-of-scope refusal, Close button, online fallback on a physical iPhone (2026-10-08) | physical-device-tested |
| Saying "Close" | Device finding: answered "I can only answer questions…" because "close" wasn't a voice command. Fixed ("close", "close this", "exit"); unit-tested and physical-device-tested (2026-10-08) |
| With VoiceOver | **not yet verified** |

## Physical-iPhone checklist

1. Checkout: 17.35 dollars, pay with a 20 → say "Ask NaviNote" → tap
   **How much change should I get?** → "2 dollars and 65 cents…".
2. Say "what's the total" and "what should I do next" with Talk.
3. Type "send an email" → the polite refusal.
4. **Close** → back on the checkout result.
5. Verify Change with one note counted → Ask → "What's still missing?".
6. With the backend running and Astra on: ask something unusual, e.g. "so
   am I getting money back or not" → an online answer, labelled, quoting
   only NaviNote's amounts.
7. VoiceOver on: each answer is read once; every button is reachable.
