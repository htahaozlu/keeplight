# Keeplight v4 — design (binding)

Consensus of two independent redesigns, Fable and Opus (kept in the development archive), each
cross-reviewed by the other; where the two reviews conceded in opposite directions the lead chose the simpler, calmer option
(marked **lead**). Donor system: Nokta (same author). `docs/DESIGN.md` stays binding where this file is
silent (meaning ledger, motion contract, safety).

## 1. Tokens
- **Custom surfaces** (onboarding, stage): `ink` #111113 / #F5F5F3; `ink.2` ink α.62; `ink.3` α.28/.30;
  `ink.wash` α.06/.08; `paper` #F7F7F5 / #0B0B0C; `paper.raised` #FFFFFF / #161618; `hairline` α.12/.14.
  Increase Contrast: ink #000/#FFF, `ink.2` α.80, `ink.3` α.55/.60, hairline α.45.
- **Panel and Settings**: system semantic colours; `inkSecondary` #5E5E62 / #A3A3A8 stays (≥ 4.5:1).
- **Red** `signal` #E0301E / #FF4438 (IC #B8200F / #FF6A5C): **only lit Fuse dots** (Keep card, Rescue HUD,
  onboarding Fuse scene). Never the menu bar, never a waiting indicator (that is an ink ring).
- **Type** (SF only): wordmark Display Bold 40/44 (28 in About); title Semibold 22/28; body 13/16; callout
  12/15 secondary; caption 11/14; digits monospaced 13; plate Semibold 15/20. Identify: SF Display
  Semibold 40 (not Rounded).
- **Spacing** 4·8·12·16·20·24·32·40·64. Radii: control 6, group 10, stage 12; panel 18 (macOS 26) / 12.
- **Curves**: `out` (0,0,.2,1), `in` (.4,0,1,1), `glide` (.2,0,0,1) (today's `Easing.out`), `land`
  (.34,1.32,.64,1, only the granted ring), `hand` (.42,0,.58,1), `step`. Linear only for Reduce Motion fades.
- **Durations** (ms, **lead**: unchanged where the reviews crossed): panel open 160; Keep card in/out
  180/160; Fuse tick 120; resolved 700 + 160; Identify 120 / 1200 / 240; OSD 100 / 250; onboarding page 320.
  No ✓ stamp.
- **Engine**: Nokta's multi-track named-layer `Timeline` (pose(at:), CA keyframes from the same keys,
  ≤ 3 loops + tail, rest pose on the model) and its event-driven `MotionGate`, as `Design/SceneTimeline.swift`
  and `Design/MotionGate.swift`. The existing opacity/scale `Timeline` keeps driving panel and overlays.
- Keep the single rescue haptic; no sound.

## 2. Status item glyph
18 × 18 template drawn in code: rounded frame (2, 4.25, 14, 9.5), r 2.25, line 1.5 (IC 2); a filled
half-disc r 3.25 on the inner bottom edge, centred (the light rising in a screen). Pending: half-disc as a
1 pt outline + title ` Keep?`. Never animated, never red. VoiceOver `Keeplight` / `Keeplight, keep change?`.
No right-click permission item (**lead**: Settings carries the permission row).

## 3. Panel
v3 geometry unchanged (inset 8, side 12, row 28, footer 32). `Main` only with more than one display.
`Waking…`, receipt and error rows at callout 12. First run leaves the panel. P2: `Copy Command` as the ⌥
alternate of `Identify`.

## 4. Onboarding window
- 560 × 440, titled + closable, full-size content, transparent hidden title bar, `paper`; on the screen with
  the pointer; `.regular` activation while open, `.accessory` after. No Identify at launch.
- Stage 480 × 200 at (40, 40), `paper.raised`, r 12, hairline; never moves, only its content changes. Title
  y 264, body y 304, control row y 336. Bottom bar 64: progress segments left (N × 20 × 3, r 1.5, gap 6;
  done/current ink, next ink.3; VoiceOver `Step 2 of 3`), buttons right (≥ 76 wide, 12 apart).
- Keys: Return = primary; ⌘[ = Back; Esc closes on pages 1–2 and is `Not Now` on page 3; clicking the stage
  replays the scene.
- Shown while `onboardingVersion < 1` (new defaults domain after the rename → shows on first launch).
  `Done` or closing the window finishes it.
- Transition (320 ms): old page out 0–160 `in` −24 pt, new in 80–320 `out` from +24, scene .98 → 1; Back
  mirrors; Reduce Motion: 150 ms linear cross-fade.

| Page | Scene (pure timeline, `explainT`) | Copy | Buttons |
|---|---|---|---|
| 1 Welcome | **Light** (**lead**: no cursor): the user's real displays as outlines (≤ 3, 120 × 72, r 6, 1.5 pt) at their arrangement, 0–240 fade/scale .98→1 with 60 ms stagger; 300–1500 interior light α.15→.85 `glide`; 1500–1740 names in. Once, 2400, explainT 2400. | wordmark `Keeplight` · `Brightness and resolution for every display.` | `Continue` |
| 2 Keep | **Fuse** (**lead**: card only): 0.8-scale Keep card `Keep 3008 × 1692?`; dots 200–3200 one per 200 ms (120 ms fade); `Reverted` 3200–3900; fade out by 4060; loop 4400, ≤ 3; explainT 1200 (10 of 15 lit). | `Changes wait for Keep` · `Unless you press Keep, changes go back.` · callout `Screen gone? Hold ⌃⌥⌘R.` | `Back` · `Continue` (`Done` + `Open at login` switch when last) |
| 3 Keys (DDC display only) | notAsked: **Keys** (48 pt `sun.max` keycap down 0–100, mini OSD up 100–400, key up 900–1000, out 2400–2560; loop 3600 ≤ 3, explainT 400). waiting: **Access** (abstract `Privacy & Security › Accessibility` list with a `Keeplight` row, cursor `hand` 150–750, press 750–910, switch 830–1030; loop 3200 ≤ 3, explainT 1500). granted: ring fills to ink 100 ms `land`, cross-fade. | `Brightness keys` · `Use your keyboard's brightness keys on BenQ EW3270U.` (plural: `on your external displays`) · notAsked callout `macOS asks once for Accessibility permission.` · waiting `○ Waiting for permission…` + `Not working?` (popover `Remove Keeplight with −, then add it again.`) · granted `Brightness keys are on.` · `Open at login` switch (on by default) | notAsked `Back` · `Not Now` · `Allow…`; waiting `Back` · `Not Now` · `Open System Settings…`; granted `Done` |

Permission state machine: `notAsked → waiting` (`Allow…`: keys on, `AXIsProcessTrustedWithOptions(prompt)`
once) `→ granted` (trusted: tap starts; app activates, window front, VoiceOver `Brightness keys are on.`),
or `deferred` (`Not Now`, Esc, closing): keys off, nothing nags; Settings carries the row. Detection: the
existing event path (`com.apple.accessibility.api`, re-checks, `didBecomeActive`) plus a 1 Hz timer
(tolerance 0.5) **only while page 3 is in `waiting` and on screen** (occlusion does not stop it, hidden or
asleep does). Idle stays at 0 wakeups.

## 5. Settings
`NSTabViewController(.toolbar)`, `toolbarStyle .preference`, 560 wide, inset 20, height fits each tab, ⌘1–3:
`General` (`gearshape`) · `Displays` (`display`) · `About` (`info.circle`). No group headers; groups 20 apart;
help ≤ 1 callout line, the rest in tooltips.

- **General**: `Open at login` · `Show in menu bar` (off: callout `Reopen with ⌃⌥⌘D.`) ‖ `Revert after`
  segmented `15 s | 30 s` · `Restore brightness after wake` ‖ `Brightness keys` (tooltip `Changes the
  display under the pointer. ⌥⇧ for fine steps.`); on and untrusted: callout `Needs Accessibility
  permission.` + `Allow in System Settings…`; on: indented `Use F1 and F2` (tooltip `Plain F1 and F2 no
  longer reach other apps.`) ‖ `Open Keeplight ⌃⌥⌘D` · `Rescue (hold) ⌃⌥⌘R` (failure line only when taken).
- **Displays**: sidebar 180 (names wrap; `Disconnected` caption) · detail: name 17 semibold + `Identify` ·
  `Name` field (placeholder = EDID name) · `Brightness` row: `DDC/CI` | `macOS` | the one-line reason +
  `Check Again` · `Details` disclosure closed: Made, Size, Panel, Modes, Identity · `Copy Report`. The
  diagnosis table lives only in Copy Report.
- **About**: icon 64 + wordmark 28, right `0.3.0 · arm64` · `Network` `0 connections` (measured: this process's
  sockets when the tab appears) · `Accessibility` `Allowed` / `Not used` · `Private APIs` `13 of 13 found` ·
  caption `Measured now.` · `Details` closed: the private symbols (`symbol — purpose`, `· missing`),
  `Signature`, `Data` path + `Show in Finder`, `License MIT` · `Copy Report` · `Erase All Keeplight Data…`.
- **Journal**: tab deleted, store kept (⌘Z, receipt and menu Undo, Rescue groups, CLI). Delete
  `SettingsJournal.swift`, `SettingsTab.journal`, `Copy.source/result`, Export/Clear, the Private APIs sheet.

## 6. Overlays
Keep card, Rescue HUD: unchanged except `signal`. OSD: name only when more than one display is
controllable. Identify: font per §1.

## 6a. Brightness below the monitor's minimum
DDC 0 is the dimmest a monitor's backlight goes, far brighter than a Mac screen's lowest step. For DDC
monitors the app range is split at `DimmingCurve.handover` = 3/16 (on the key grid): below it the
backlight stays at 0 and the gamma table is scaled from 1 down to `darkest` **0 (black, like a Mac
screen at its lowest; owner's request 2026-10-19)** (`SoftwareDimmer`,
original table captured once, restored at 100 % gain, on quit, rescue, erase; re-applied after wake and
reconfiguration). Above it the range is the monitor's own 0…100. Saved levels from before (and
Dotpitch's) are converted at the next probe; journal entries with the old mechanism are converted on
Undo. The CLI stays on the monitor's own scale.

## 7. Migration (safety)
Before `TransactionEngine` recovery reads `pending.json`/`disconnected.json`: move
`Application Support/Dotpitch` → `Keeplight` once (not while the old app runs; not over a used folder), and
import `nicknames`, `knownDisplays`, `lastWritten`, `revertSeconds`, `restoreAfterWake` from the
`io.github.htahaozlu.Dotpitch` defaults. Never `hasLaunched`, `brightnessKeys` or F1/F2 (the TCC grant
belonged to the old identity).

## 8. Copy budget
Estimate ≈ 520 words; cap lowered from 600 to **560**; `Onboarding/` is its own surface in the script.

## Amendments (2026-10-19, owner feedback after hardware tests)
- **0 % means off/black**, as in macOS: no 2 % floor for the slider, keys or Undo on a Mac screen; DDC monitors reach
  black through the gamma table. Safety only at transitions: an Apple panel that *becomes* the only screen below 2 % is
  raised once; waking lifts a black DDC monitor to the first key step (`DimmingCurve.wakeGain`). Rescue and quitting
  restore the gamma.
- **Fine steps with ⌥** (alone or ⌥⇧, macOS's chord): quarter steps (1/64) on keys and the panel slider. ⌥ + sun on an
  Apple display Keeplight does not handle still reaches macOS.
- **Brightness keys arrive in three forms**: `NX_SYSDEFINED`, key codes 144/145 (Apple keyboard with no dimmable
  screen — verified on the owner's clamshell M3 + Magic Keyboard), F15/F14; F1/F2 only when chosen.
- **Settings**: tabs switch without animation (no cross-fade, no animated resize). Rows whose name does not say what
  they do carry one secondary detail line under the title (System Settings' subtitle) instead of a tooltip: Revert
  after, Restore brightness after wake, Brightness keys, Use F1 and F2, Rescue (hold). Displays › Brightness reads
  `Over the cable (DDC/CI)` / `By macOS`.
