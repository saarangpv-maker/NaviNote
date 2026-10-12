# NaviNote Design System

Calm, high-contrast, tactile, and native. Deep navy and warm off-white, with
one gold accent that marks the most important action. SwiftUI components and
system behaviour are used wherever they fit; custom styling is limited to
colour, type, shape and spacing.

## Colour (`DesignSystem/Tokens/NaviColor.swift`, asset catalog)

Every colour has **light, dark, light + Increase Contrast, dark + Increase
Contrast** variants in `Resources/Assets.xcassets`.

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | #F5F1E8 warm off-white | #0A0F1C near-black navy | Screen background |
| `surface` | #FFFFFF | #151C2D | Cards, panels |
| `surfaceMuted` | #ECE6D9 | #1C2438 | Voice bar, icon tiles, disabled fills |
| `textPrimary` | #0B1220 | #F6F2EA | Main text |
| `textSecondary` | #434C5E | #BDC4D3 | Supporting text |
| `accent` | #E3A82B | #F2C14E | Gold fill of the main action |
| `onAccent` | #0B1220 | #0B1220 | Text on gold |
| `accentText` | #7A5300 | #F2C14E | Gold used as text/icons (tint) |
| `navy` / `onNavy` | #101A33 / #F6F2EA | same | Brand tile, camera shell |
| `border` | #8A806C | #6B7895 | Component edges (≥ 3:1 against surfaces) |
| `success` / `warning` / `error` / `info` | #1A6B3C / #8A5700 / #B3261E / #1F4E9E | #6FDB98 / #FFBE5C / #FF8F85 / #8DB7FF | Status icons and edges |

### Measured contrast (WCAG ratio)

| Pair | Light | Dark | Light HC | Dark HC |
|---|---|---|---|---|
| textPrimary / background | 16.6 | 17.1 | 21.0 | 21.0 |
| textSecondary / surface | 8.6 | 9.7 | 15.4 | 16.2 |
| textSecondary / surfaceMuted | 6.9 | 8.8 | 11.3 | 14.4 |
| onAccent / accent | 8.8 | 11.2 | 11.5 | 14.6 |
| accentText / surfaceMuted | 5.5 | 9.2 | 7.2 | 11.8 |
| success / surface | 6.5 | 9.9 | 9.4 | 13.9 |
| warning / surface | 6.1 | 10.3 | 8.8 | 13.3 |
| error / surface | 6.5 | 7.7 | 9.1 | 11.0 |
| info / surface | 8.0 | 8.4 | 10.7 | 12.0 |
| border / surface | 3.9 | 3.8 | 7.2 | 7.7 |

All text pairs exceed WCAG AA (4.5:1); all component edges meet 3:1.

## Typography (`NaviFont`)

All roles are Dynamic Type text styles (rounded design for headings and
amounts). No fixed point sizes anywhere.

| Role | Style |
|---|---|
| `screenTitle` | Large Title, rounded, bold |
| `sectionTitle` | Title 2, rounded, bold |
| `actionTitle` | Title 3, rounded, semibold |
| `message` | Title 3 — what NaviNote says |
| `body` / `bodyEmphasized` | Body |
| `supporting` | Callout |
| `caption` | Footnote |
| `overline` | Subheadline, rounded, semibold |
| `amount` | Large Title, rounded, bold, monospaced digits |

## Spacing, radius, size

- Spacing: 4 · 8 · 12 · 16 · 24 · 32 · 48 (`NaviSpacing`)
- Radius: 12 · 18 · 26, continuous corners (`NaviRadius`)
- Touch targets ≥ 44 pt; buttons ≥ 60 pt; home actions ≥ 88 pt; Talk 76 pt
  — all scaled with `@ScaledMetric`.
- Content width capped at 640 pt for landscape readability.

## Elevation

`naviSurface()` — filled rounded rectangle, hairline border, soft shadow in
light mode only. With Increase Contrast, borders thicken (2–3 pt) and shadows
are removed.

## States

- **Pressed:** slight darkening + 2% scale (scale removed with Reduce Motion).
- **Disabled:** muted fill, secondary text, and for Talk a **dashed** outline,
  so it's recognisable without colour. VoiceOver says "dimmed".
- **Selected:** checkmark symbol + thicker accent border + `.isSelected`.
- **Tones:** each has a distinct symbol *shape* (circle-i, checkmark,
  triangle, octagon) and a spoken prefix ("Warning: …").

## Components (`DesignSystem/Components`)

| Component | Purpose |
|---|---|
| `NaviButtonStyle` (`.naviPrimary`, `.naviSecondary`, `.naviCancel`, `.naviDestructive`) | Full-width actions |
| `IconActionButton` | Labelled icon (Repeat, Help) |
| `HomeActionButton` | Large feature row; reflows vertically at accessibility sizes |
| `StatusBanner` | Tone + title + message |
| `AssistantMessageView` | What NaviNote last said |
| `ResultPanel` | Outcome with amount |
| `ConfirmationPanel` | "Is this right?" with confirm / try again |
| `AmountDisplay` | Large money, spoken with units |
| `CurrencyBadge`, `CurrencyChoiceButton` | Currency display and selection |
| `StepIndicator` | "Step 2 of 5" with shape-coded segments |
| `PermissionExplanationView` | Why a permission is needed + manual route |
| `ErrorRecoveryView` | Try again / cancel |
| `ListeningIndicator`, `SpeakingIndicator` | Voice state; static with Reduce Motion |
| `CameraViewportShell` | Camera frame, corners, guidance; single VoiceOver element |
| `EmptyStateView`, `LoadingStateView` | Empty and busy states |
| `PrivacyNotice` | Short privacy promise |

Every component has SwiftUI previews (light, dark, and AX sizes where layout
changes).

## Layout rules

- The home voice bar sits **below** the scroll view, never over it, so no
  content is hidden or blurred behind it. At accessibility text sizes it
  becomes full-width buttons at the end of the scroll content.
- Screens are single-column scroll views; nothing is fixed-height.
