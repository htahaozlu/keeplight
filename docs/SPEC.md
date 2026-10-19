# Keeplight — specification

Independent, open implementation of a macOS display manager; the implementation is original.
Design decisions live in `docs/DESIGN.md` and `docs/design/`.

Minimum macOS 14, Swift 6 toolchain, zero third-party dependencies.

## Modules

| Target | Kind | Role |
|---|---|---|
| `CPrivateDisplay` | C header | Types for private CoreGraphics (CGS mode record) and IOKit (IOAVService) APIs. No function declarations. |
| `DisplayCore` | library | All display logic, no UI. |
| `keeplight` | executable | CLI over `DisplayCore`. |
| `KeeplightApp` | executable | Menu bar app, bundled as `Keeplight.app` by `scripts/bundle-app.sh`. |

Every private C function (13 symbols in CoreGraphics/SkyLight, DisplayServices,
CoreDisplay and IOKit) is resolved at runtime with `dlsym`; absence degrades the feature
instead of crashing or preventing launch. `PrivateInterfaces.all` reports live status.

The app target is named `KeeplightApp` because `Keeplight` and `keeplight` collide on
case-insensitive volumes (source folders, build products, and `Contents/MacOS`); for the
same reason the bundled CLI lives at `Keeplight.app/Contents/Helpers/keeplight`.

## v0.1 scope

1. **Display inventory** — online displays with ID, name, vendor/product/serial, UUID,
   built-in/main/active/mirror flags, bounds, current mode.
2. **Modes** — full CGS mode list (includes HiDPI duplicates), set mode by number or
   `WxH[@Hz][hidpi]`.
3. **Arrangement** — set main display, mirror/unmirror, software disconnect/reconnect
   (`CGSConfigureDisplayEnabled`). Never disable the last enabled physical display.
4. **Brightness** — resolver picks the best backend per display:
   Apple (`DisplayServices`) → DDC (VCP 0x10). A DDC display reporting a zero maximum
   is treated as having no DDC brightness.
5. **DDC/CI (Apple silicon)** — IOAVService discovery and display matching, get/set any
   VCP code, named codes for brightness, contrast, volume, mute, input source, power.
6. **EDID** — read from IORegistry and parse VESA EDID 1.3/1.4 base block.
7. **App** — menu bar panel per display: brightness slider, resolution menu, main /
   mirror / disconnect actions; launch at login.

## v0.2 engine (DisplayCore)

1. **Identity** — `DisplayInfo.fingerprint` (`vendor:product:serial`, EDID serial string
   preferred; twins disambiguated by an `IODisplayLocation` hash; CG UUID fallback). All
   persisted state is keyed by fingerprint.
2. **Sharpness** — `DisplayManager.nativePixelSize(for:)`, `DisplayMode.sharpness(native:)`
   (`crisp` / `scaled` / `native` / `soft`) and `recommendedModes` (the ≤ 6-row
   "Looks like" list).
3. **Snapshot / restore** — `DisplayManager.snapshot()` and `restore(_:option:)`; every
   configuration call takes a `CGConfigureOption`.
4. **Transactions** — `TransactionEngine`: snapshot → `pending.json` write-ahead → apply
   with `.forAppOnly` → keep (`.permanently`, `.forSession` for disconnect) or revert;
   recovery at launch. The CLI never uses transactions; it applies directly
   (`DirectChange`) and journals with source `cli`.
5. **Journal** — `journal.jsonl` shared by app and CLI (`flock`), pruned to 1,000 entries /
   90 days; brightness gestures coalesced.
6. **Registries** — displays Keeplight disconnected (`disconnected.json`) and mirrors it
   created (`mirrors.json`).
7. **Rescue** — known-good snapshots per display set (`known-good.json`, last 10);
   `Rescue.plan()` / `run(dryRun:)`; auto-rescue when no physical display is enabled.
8. **Diagnostics** — graded steps (OBSERVED / NO REPLY / NOT AVAILABLE / NOT TESTED), one
   verdict sentence, Markdown report with serials redacted.
9. **Brightness write policy** — `WriteThrottle`: ≤ 1 write / 16 ms (Apple) or 100 ms
   (DDC), leading and trailing.

State lives in `~/Library/Application Support/Keeplight/` (`$KEEPLIGHT_SUPPORT_DIR`
overrides it).

## CLI (`keeplight`)

`list`, `info`, `modes`, `mode`, `main`, `mirror`, `unmirror`, `enable`, `disable`,
`brightness`, `ddc`, `edid`, `doctor`, `journal`, `rescue [--dry-run]`, `interfaces`.
Mutating commands append journal entries with source `cli`.

## Roadmap (not in v0.2)

Virtual displays, display overrides, rotation, HDR/XDR toggles and presets, keyboard
brightness keys + OSD, desk profiles, display groups, PiP/streaming, Intel DDC
(`IOI2CInterface`), network TV controllers, HTTP integration API, sentinel process for
pending changes.

## Out of scope

Licensing/activation, telemetry, auto-update, network access of any kind, software
(gamma/overlay) dimming.
