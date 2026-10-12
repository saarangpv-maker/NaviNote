# NaviNote Accessibility Checklist

Run through this for every new or changed screen. Automated checks
(`performAccessibilityAudit`, unit tests) help, but they **do not replace**
manual VoiceOver testing on a physical iPhone.

## VoiceOver

- [ ] Every interactive element has a short, specific label (no "button",
      no icon names).
- [ ] Hints only where the result of activating isn't obvious.
- [ ] Correct traits: `.isHeader` on section titles, `.isSelected` on the
      selected option, `.isButton` on custom tappable views.
- [ ] Values exposed via `accessibilityValue` (e.g. amount, step "2 of 5").
- [ ] Reading order matches visual order; decorative images hidden.
- [ ] Composite rows are combined into a single element where it helps.
- [ ] Headings let the rotor jump between sections.
- [ ] After a state change, focus lands on the new screen's title or result
      (`@AccessibilityFocusState`).
- [ ] Announcements are posted once per event (no duplicate speech), and not
      at the same moment as a focus change that already reads the same text.
- [ ] Money is spoken with units: "12 dollars and 50 cents", not "$12.50".

## Visual

- [ ] Text uses Dynamic Type text styles only — no fixed point sizes.
- [ ] Verified at `accessibility5` (AX XXXL): nothing clipped or truncated;
      rows reflow vertically.
- [ ] Bold Text respected (system text styles do this automatically).
- [ ] Increase Contrast: asset colours have high-contrast variants; borders
      become more visible.
- [ ] Contrast ≥ 4.5:1 for body text, ≥ 3:1 for large text and UI glyphs,
      in light and dark mode.
- [ ] Status never relies on colour alone — always an icon **and** words.
- [ ] Differentiate Without Color: selected/state indicators use shape or
      symbol changes too.
- [ ] Reduce Motion: no scaling/sliding transitions; indicators become static.
- [ ] Touch targets ≥ 44×44 pt; primary actions ≥ 64 pt tall.
- [ ] Small iPhone (iPhone SE / 17e width) and landscape: no horizontal
      clipping; content scrolls.

## Operation

- [ ] Every workflow completes with buttons only (no speech recognition).
- [ ] Every workflow completes without internet.
- [ ] Every camera step offers a manual alternative immediately.
- [ ] Permission-denied paths explain what happened and offer the manual
      route.
- [ ] Switch Control can reach every control (no gesture-only actions).
- [ ] Hardware keyboard: Tab/arrow navigation reaches all controls where the
      platform supports it.

## Voice and VoiceOver (Phase 4)

- [ ] With VoiceOver on, each message is heard once (VoiceOver only, never
      also NaviNote's voice).
- [ ] Talk works with a VoiceOver double-tap; VoiceOver's speech is not
      captured as a command.
- [ ] Status line always says what voice is doing, in words.
- [ ] Denied/unavailable voice leaves every feature usable via buttons and
      Type a Command.

These are unit-tested with fakes and **not yet VoiceOver-tested** on a device.

## Current status (end of Phase 3)

| Check | Status |
|---|---|
| Labels, hints, traits, headings on home, workflow placeholder, help, settings | statically verified; UI-tested (XCUITest `performAccessibilityAudit`, light + dark) |
| Dynamic Type at AX XXXL: reflow, nothing clipped, every control reachable | UI-tested (audit + scroll reachability), simulator-tested (screenshot) |
| Colour contrast, light/dark/Increase Contrast | statically verified (computed ratios in DESIGN_SYSTEM.md); UI-tested (audit) |
| Reduce Motion (no scale/animation) | statically verified |
| Differentiate Without Color (symbols + words for every status) | statically verified |
| Manual VoiceOver pass | **not yet verified** — needs a physical iPhone |
| Switch Control, hardware keyboard | **not yet verified** |
| Landscape | statically verified (single-column scroll, 640 pt cap); not yet screenshot-tested |
| Small iPhone | simulator-tested on iPhone 17e only; iPhone SE-class width **not yet verified** |

### Audit scoping (documented, deliberately narrow)

`AccessibilityAuditUITests.audit(_:)` skips these, each with a reason, each with a reason:

1. Static text that is not hittable, and contrast findings on any element
   not fully inside the visible scroll area. These are scrolled (partly) out
   of view or under the voice bar, so the audit measures them against
   whatever covers them. Reachability is tested by scrolling.
2. Dynamic Type or clipping findings on rows inside a scrolling list (Help,
   Settings). Rows that grow with larger text move below the screen edge.
   `testHelpAtLargestTextSize` checks instead that every row can be scrolled
   to at AX XXXL.
3. Dynamic Type findings on the system sheet "Done" toolbar button, and any
   finding on the system keyboard (its predictive-text bar has unlabelled
   cells).
4. Issues the audit cannot attribute to any element. They are counted in an
   attachment and need a manual check on device.

### Real defect found by the audit and fixed

`naviSurface()` applied its light-mode shadow to the whole view, so the
**text itself** had a soft shadow halo. The audit flagged it as a contrast
failure in light mode only, the one mode with a shadow. The shadow now
belongs to the background shape alone. Home-card subtitles also moved to the
primary text colour for extra legibility. The voice bar now sits below the
scroll view instead of over it, so no content is blurred behind it.

### Disabled controls (Phase 4)

Disabled buttons keep full-contrast labels. "Unavailable" is shown by a
dashed outline (and a slashed microphone on Talk), and VoiceOver announces
"dimmed". WCAG exempts disabled controls from contrast rules, but low-vision
users still need to read what a control is.
