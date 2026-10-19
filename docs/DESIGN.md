# Keeplight — design (v3 rules)

> **v4 supersedes the surfaces** (onboarding window, Settings, tokens, status glyph):
> [`design/v4-keeplight.md`](design/v4-keeplight.md). This file still binds the meaning ledger, the motion
> contract, budgets and safety.

Brief: understandable, plain, original, light as if it weren't there. v3 came from a diagnosis of
the earlier design and two independent proposals (kept in the development archive); the tables
below are what was decided.

## Meaning ledger (one form, one meaning)

| Form | Meaning |
|---|---|
| **Fuse** — row of 15 dots, lit = time left, outline = spent | time until Keeplight puts it back (Keep card, rescue HUD). Nowhere else. |
| Signal red (only accent) | needs you now: only the lit Fuse dots |
| Name, 13 semibold | which display |
| Secondary number, monospaced digits | brightness percent |
| `sun.max` | brightness |
| Word `Soft` | this resolution is blurry: stretched without HiDPI (absent = sharp; macOS's HiDPI "Looks like" sizes are not marked) |
| Prominent button | commit (`Keep`) |

## Decisions (where A and B differed)

| Topic | Decision | Why |
|---|---|---|
| Signature gesture | A: the Fuse (time until undo) | The not-understood part was the safety flow (shown 3×). The Fuse explains it without words, appears only at the risky moment, so it keeps one meaning. |
| Brightness control | A: native `Slider` + number | Readable at first sight; dots belong to the Fuse only. |
| Pending change | A: only on the Keep card (every screen); panel sections disabled; status item ` Keep?` | One decision surface. |
| Desk map, index numerals | A: deleted; click a name to Identify | Names identify; numbers had no other job. |
| Mode quality | A: only `Soft` is printed | One word instead of a 4-term vocabulary. |
| Status item | A: `display` symbol, ` Keep?` title while pending | No red in the menu bar; the word carries the state. |
| Brightness keys entry | Settings **+** the onboarding keys page when a DDC display exists (v4 §4) | Enabling is a decision with its reason; no promotional row in the panel. |
| Doto, chips, raw mode, ghost zeros, wordmark | deleted (both) | System fonts only; raw mode → `···` › `Copy Command`. |
| Bundle | A: strip release binaries | Measured −3.9 MB in A. |
| Settings tabs | v4: General · Displays · About (Journal tab removed, history kept for Undo) | v4 §5 |
| Panel container | One `PanelSurfaceView` on every macOS: an `NSVisualEffectView` content view whose `maskImage`, opaque fill (Reduce Transparency), hairline and content clip all come from `PanelShape` (radius 18 on macOS 26, 12 before; circular corners). `.menu` material, not `NSGlassEffectView` | A borderless window gets its shape and shadow only from a visual-effect content view's `maskImage`; with glass (or a rounded layer) the window stayed a rectangle, so its shadow drew a rectangle around the rounded surface. |
| First-run explanation frame | Drawn on the panel itself (Fuse in panel colors: signal red lit, secondary-ink outline), no dark plate | A§3.7/§3.9: no card on a card; the nested plate's corners could not follow the panel's. |
| Brightness keys | Target = the DDC display under the pointer (said in Settings); `Also use F1 and F2` off by default; the system prompt only on a user action (onboarding `Allow…`, the Settings toggle), never at launch | F1/F2 are taken from every app while on, so it is opt-in; a prompt at every launch was a nag. |
| First run | v4: its own onboarding window (v4 §4) | A panel closes when System Settings takes focus, which ended the permission wait. |

## Motion contract (binding)
- Every animation is a pure timeline `pose(at t)`; the same keyframes drive Core Animation
  (`CAKeyframeAnimation`/`CABasicAnimation` on layers) and the offscreen render tool. No timers,
  display links or delay chains for animation.
- The model stays at the resting pose; animations are removed on completion (no fill-forwards).
- Loops ≤ 3 cycles. Nothing plays when the surface is hidden, occluded, minimized, the app is
  hidden, the screen sleeps, or Reduce Motion is on — Reduce Motion shows the timeline's single
  explanation frame. Functional background checks (permission wait) still run while occluded.
- Interruptions continue from the presented pose. After every transition the resting state is
  clean (no stale content reappears on a later path).

## Budgets (measured before → target)
| | before | target |
|---|---|---|
| Bundle | 7.1 MB | ≤ 3.5 MB |
| Idle CPU (panel closed) | 0.0 % | 0.0 % |
| Idle wakeups | 0 /s (the 1 /s first recorded was a misread cumulative counter) | 0 /s |
| Footprint | 17 MB | ≤ 17 MB (A: ≤ 12 MB idle, ≤ 20 MB panel open) |
| Default 3-display panel words | 62 | ≤ 20 |
| Product copy words | ≈ 1,190 | ≤ 600 (v3), ≤ 560 (v4) |

Footprint status: not yet measured on a v3 build. The pass that rebuilt the views did not launch the app, so
the target is open; verify with `footprint` and `vmmap` on a release build before shipping.

## Safety
Render/test tool (`keeplight-render`) never ships (`scripts/check-bundle.sh`, positive + negative).
Test and measurement modes refuse product actions in code.
