# Keeplight panel v5 — Control Center language (spec)

Binding with `docs/DESIGN.md` (ledger, motion contract) and `docs/design/v4-keeplight.md` §1. Only the
panel changes. Today: text on bare material, hairline separators, a thin stock slider. v5: every display
is a **module tile** with a **capsule slider**.

## 1. Geometry (pt)

| Token | Value | Note |
|---|---|---|
| `panelWidth` | 320 | unchanged |
| `panelRadius` R | 18 (macOS 26) / **16** (14–15) | 12 → 16 pre‑26 so concentric radii survive |
| `inset` | **6** | panel edge → module edge, all sides; also module gap |
| `moduleRadius` | R − inset = **12 / 10** | concentric; equals `stage` / `group` radii |
| module padding | 12 h · 10 v | content width 284 |
| header row | 24 | name · `Main` · `···` |
| slider row | 28 | capsule 24 centred, 6 above |
| resolution row | 24 | chip, 6 above |
| module height (controllable) | 108 | mirror/no‑control/disconnected: 108 too (rail keeps the slot) |
| notice tile | min 36 | callout 12, chip right |
| footer | 32 | on the material, not a tile |
| 1 display | 6+108+6+32+6 = 158 | 3 displays: 380; scroll above `panelMaxHeight` |

Materials: panel stays `PanelSurfaceView` (`.menu`, mask, hairline). Module fill `module.fill` = white α.60
light / white α.07 dark on the material; Reduce Transparency: `paper.raised` #FFFFFF / #161618. Module
hairline 0.5 pt inside the shape: `hairline` at half alpha (α.06/.07; IC α.45). No shadows, no blur of our own.

## 2. Layouts

```
1 display (158 × 320)                        3 displays (380)
┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
│ ╭──────────────────────────────────╮ │    │ ╭ Set DELL U2723QE back to 40 [Undo]╮ │  notice tile
│ │ BenQ EW3270U                 ··· │ │    │ ╰──────────────────────────────────╯ │
│ │ ╭☼████████████████╮░░░░░░░╮   72 │ │    │ ╭ Built‑in Liquid Retina XDR    ··· ╮ │
│ │ ╰──────────────────────────╯     │ │    │ │ ╭☼█████████████████████╮░░╮   72 │ │
│ │ (3840 × 2160 ⌄)                  │ │    │ │ (1512 × 982 ⌄)                   │ │
│ ╰──────────────────────────────────╯ │    │ ╰──────────────────────────────────╯ │
│  Settings…                     Quit  │    │ ╭ DELL U2723QE            Main  ··· ╮ │
└──────────────────────────────────────┘    │ │ ╭☼███████╮░░░░░░░░░░░░░░░░░╮   40 │ │
                                            │ │ (2560 × 1440 ⌄)                  │ │
 ☼ = sun.max inside the fill                │ ╰──────────────────────────────────╯ │
 █ = white fill   ░ = track                 │ ╭ LG HDR 4K                     ··· ╮ │
 ( ⌄) = resolution chip                     │ │ ╭ No brightness control      ⓘ ╮  │ │  empty rail
                                            │ │ (1920 × 1080 Soft ⌄)             │ │
                                            │ ╰──────────────────────────────────╯ │
                                            │  Settings…                     Quit  │
                                            └──────────────────────────────────────┘
```

Order top→bottom: notice tile (safe start › error › receipt, one at a time) · display modules
(`model.items`, then disconnected) · `Waking…` line · footer.

## 3. Module anatomy

**Header (24).** Name `titlePlate` 13 semibold primary, tail truncation, click = Identify (target full row
height 24, `help` `Show on screen`). Right: `Main` caption 11 `inkSecondary` (only when >1 desktop), then
`···` 15 secondary, 24 × 24, glyph flush right. Hover `···`: primary ink. Pressed: α.6.

**Capsule slider (`CapsuleSlider`, replaces `Slider`+`SunIcon`).** Track 246 × 24, radius 12 (content 284 −
8 gap − 30 percent). Colours: `slider.track` = `hairline` token (ink α.12 light / white α.14 dark; IC α.45);
`slider.fill` = #FFFFFF both appearances (Control Center). Fill width `24 + 222·level`, left‑anchored, radius
12 — the fill never shrinks below the glyph. `sun.max` 12 semibold, `ink` #111113 fixed (always on white),
centred in the first 24 × 24. No thumb. Percent `bodyText` 13 monospaced, 30 wide right‑aligned,
`inkSecondary`; **primary while the pointer is over the track or a drag is live**; `—` when unknown. Gesture:
`DragGesture(minimumDistance: 0)` — press jumps to `(x − 12)/222` clamped and drags from there;
`beginDrag`/`endDrag` as today. Keyboard: focusable; ← → one key step (1/16, the brightness‑key grid), ⌥⇧ ← →
fine step (1/64), Home/End 0/1. Focus ring: system, tinted `inkPrimary`, capsule.

**States of the slider slot (same 24 × 246 rail, so modules align):**
- *probing*: empty rail, `Reading…` callout 12 secondary at x 10.
- *no control*: empty rail, `No brightness control` callout 12 secondary at x 10; `info.circle` 13 secondary
  in the last 24 × 24 of the rail; the whole rail is the button (opens `WhyPopover`, unchanged).
- *mirror target*: rail replaced by `Mirrors {source}` 13 secondary + `Stop Mirroring` chip right.
- *disconnected*: name in secondary; header right `Disconnected` caption; second row `Back after you log
  out.` caption 11 + `Reconnect` chip; no resolution row (module still 108 via bottom padding).

**Resolution chip.** Capsule 24 tall, padding 10 h, fill `ink.wash` (α.06/.08), hover α.10/.12, pressed
α.14/.16, IC: + 1 pt `hairline`. Content: `sizeText` 13 digits primary · `Soft` 13 secondary (only when
blurry) · `chevron.down` 9 semibold secondary, 6 apart. Menu unchanged (`recommended`, `Show All…`). Left
aligned; nothing on the right of this row.

**Chip** is the one small button of the panel (`Undo`, `Reconnect`, `Stop Mirroring`, `Rescue`, `Continue`,
`Check Again`): same capsule, 13 primary text. Replace `ActionButton(.bordered)` inside the panel. No filled
chip: the only prominent button in the app stays `Keep`.

**Locked** (pending Keep card, waking): module content opacity .45, disabled, `···` too; tile fill stays.

## 4. Notice tile and footer

Notice tile: `moduleRadius`, same fill, padding 12 h / 8 v, min 36. Variants: receipt → `receipt.text`
callout 12 primary (2 lines max) + `Undo` chip when `undo != nil && pending == nil`; error →
`exclamationmark.triangle` 12 secondary (never red) + text + `xmark` 10 semibold 24 × 24 `Dismiss`; safe
start → `Safe start: nothing applied.` + `Rescue` · `Continue` chips (Return = Continue; both chips equal).
`Waking…`: 24‑tall line between modules and footer, x 12: static 10 pt ring (1.5 pt `inkSecondary` — the
ink‑ring waiting form of v4 §1, never animated) + `Waking…` callout 12 secondary. `floorCaption` uses the
same line without the ring.

Footer (32, on the material): `Settings…` left, `Quit` right, 13 `inkSecondary` → primary on hover, α.6
pressed, hit ≥ 44 × 28; `⌘,` and `⌘Q` as `keyboardShortcut`s (not printed). No separator above: the last
tile's edge is the separation.

Empty desk: one tile, `No active displays.` 13 secondary, 108 tall.

## 5. Interaction

- Panel is a `.nonactivatingPanel` made key on open; `NSHostingView` subclass returns `true` from
  `acceptsFirstMouse(for:)`; `CapsuleSlider` and chips react on the first click.
- Tab order per module in reading order: name → `···` → slider → resolution; modules top→bottom; notice
  chips first; `Settings…`, `Quit` last. Esc closes the panel. Space/↓ opens the chips' menus.
- All targets ≥ 24 × 24 (`hitTarget` audit as today); slider rail 24 tall; percent text not a target.
- Pointer: default everywhere (Control Center shows no hand cursor).

## 6. Motion (pure timelines, `Motion.swift`)

| Timeline | Keys | Reduce Motion |
|---|---|---|
| `panelOpen` | unchanged 160 ms `out` | fade 150 linear |
| `sliderFill` | fill width → target, 160 ms `out`; only for external changes (keys, OSD, Undo, wake restore, probe result). Drag: immediate | snap |
| `hover` | ink / wash colour 120 ms `out`; pressed immediate | snap |
| `noticeIn` / `noticeOut` | opacity 0→1 + height 0→h 180 `out` / 160 `in`; modules move with it | 150 linear opacity, height snaps |
| `lock` | content opacity 1→.45, 160 `out`; back the same | snap |

No loops anywhere on the panel; the ring is static. Rest pose on the model; animations removed on completion.

## 7. Accessibility (VoiceOver)

Module: container, label `{name}` / `{name}, main display` / `{name}, disconnected`. Name button: label
`{name}`, hint `Shows each display's name on its screen`. Slider: `Brightness`, value `{n} percent` /
`unknown`, adjustable (increment = key step). Rail: `No brightness control` button, hint `Shows why`;
`Reading…` static text. Resolution: `Resolution`, value `2560 by 1440` (+ `, soft`). `···`: `More for
{name}`. Chips: their titles. Notice: container; `Dismiss`, `Undo`. Footer: `Settings`, `Quit Keeplight`.
Percent text hidden (slider value carries it). Increase Contrast: tokens per v4 §1; module hairline α.45;
chips get a 1 pt hairline.

## 8. Copy (panel, exact; ≈ 45 words, net 0)

`Main` · `Soft` · `Show All…` · `No brightness control` · `Reading…` · `Mirrors {name}` · `Stop Mirroring` ·
`Disconnected` · `Back after you log out.` · `Reconnect` · `Waking…` · `Settings…` · `Quit` · `Undo` ·
`Safe start: nothing applied.` · `Rescue` · `Continue` · `No active displays.` · `···` menu: `Make Main
Display`, `Mirror Onto`, `Stop Mirroring`, `Identify`, `Copy Command`, `Show in Settings…`, `Disconnect…`.
Nothing new is printed; `Soft` stays the only quality word; no `%` sign (the ledger's secondary number).

## 9. Delete

`SectionSeparator`; native `Slider` + `SunIcon` column; `.bordered` `ActionButton` use inside the panel
(`Cards.swift`, `ReceiptRow`, `MirrorRow`, `DisconnectedSection`); `plateHPadding`‑based bare rows
(`ReceiptRow`, `ErrorRow`, `SafeStartCard` become `NoticeTile` variants); `Metrics.row = 28` as the generic
row (replace by `header 24`, `slider 28`, `chipRow 24`); `panelRadius` 12 pre‑26. Keep `PanelSurfaceView`,
`WhyPopover`, `AllModesMenu`, `MoreMenu`, `hitTarget`, `dimWhenDisabled`.

## 10. Acceptance

All existing `panel-*` renders in light/dark/IC/Reduce Transparency; every module 108 × 308; corners
audit: module radius = panel radius − 6; every target ≥ 24 × 24; first click on a freshly opened panel
moves the slider; copy script ≤ 560.

## Amendments after the visual review (2026-10-19)
- Light module fill α.60 → **α.40**, `hairline` light α.12 → α.16, slider edge light α.08 → α.14, `wash` rest/hover/pressed
  light .08/.12/.18 (dark .08/.14/.20), `surfaceBase` light #F7F7F5 → #F2F2F0: the white slider fill was invisible on a
  white tile and the four greys were too close.
- Mirror target and disconnected modules are **compact, 78 pt** (no resolution row); the formula is in `PanelLayout.height`.
- Locked content α.45 → **α.5**. Notice text at body 13 next to 13 pt chips. Safe start: one line when it fits, else the
  sentence with the chips right-aligned under it. `···` is SF `ellipsis` 13 semibold on the trailing column.
