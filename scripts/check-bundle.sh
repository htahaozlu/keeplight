#!/usr/bin/env bash
# Verifies dist/Keeplight.app (or the bundle given as $1).
#   positive: the app executable, the CLI helper, Info.plist and the icon are present, and the
#             app (with its nested helper) and the CLI next to it pass a strict signature check.
#   negative: nothing of the debug-only `keeplight-render` tool shipped: no such file, and none of
#             its fakes, scenario names or messages appear as strings in any bundled binary.
#             No debug hook shipped either: no `KEEPLIGHT_DEBUG` variable and no
#             `CGWindowListCreateImage` (the screenshot capture) in any bundled binary.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-$root/dist/Keeplight.app}"
cli="$(dirname "$app")/keeplight"
fail=0
bad() { echo "check-bundle: FAIL $*" >&2; fail=1; }

# Positive.
for path in \
    "$app/Contents/MacOS/Keeplight" \
    "$app/Contents/Helpers/keeplight" \
    "$app/Contents/Info.plist" \
    "$app/Contents/Resources/AppIcon.icns" \
    "$cli"; do
    [[ -e "$path" ]] || bad "missing $path"
done
for exe in "$app/Contents/MacOS/Keeplight" "$app/Contents/Helpers/keeplight" "$cli"; do
    [[ -x "$exe" ]] || bad "not executable: $exe"
done
[[ ! -e "$app/Contents/Resources/Fonts" ]] || bad "unexpected Resources/Fonts in bundle"
codesign --verify --strict --deep "$app" 2>/dev/null || bad "codesign verification of $app"
[[ ! -e "$cli" ]] || codesign --verify --strict "$cli" 2>/dev/null || bad "codesign verification of $cli"

# Negative: file names.
if [[ -d "$app" ]] && find "$app" -iname '*render*' | grep -q .; then
    bad "render-looking file in bundle: $(find "$app" -iname '*render*' | tr '\n' ' ')"
fi
[[ ! -e "$(dirname "$app")/keeplight-render" ]] || bad "keeplight-render next to the bundle"

# Negative: strings in every bundled Mach-O (app, CLI, helper).
markers='keeplight-render|RefusalLog|FakeDisplaySystem|RenderTool|keeplight-render refuses|Scenarios|KEEPLIGHT_DEBUG|CGWindowListCreateImage'
for exe in "$app/Contents/MacOS/Keeplight" "$app/Contents/Helpers/keeplight" "$cli"; do
    [[ -f "$exe" ]] || continue
    hits="$(strings -a "$exe" | grep -E "$markers" | sort -u | head -5 || true)"
    [[ -z "$hits" ]] || bad "$(basename "$exe") contains render-tool or debug strings: $hits"
done

if [[ $fail -ne 0 ]]; then exit 1; fi
echo "check-bundle: OK ($app: app + CLI present, no render tool, no debug hooks)"
