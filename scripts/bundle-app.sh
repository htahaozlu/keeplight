#!/usr/bin/env bash
# Builds dist/Keeplight.app and dist/keeplight (the CLI). UNIVERSAL=1 builds arm64 + x86_64.
# SIGN_IDENTITY="Developer ID Application: …" signs with hardened runtime instead of ad hoc, so
# macOS keeps permissions (Accessibility for the brightness keys) across rebuilds.
# SIGN_TIMESTAMP=1 (with SIGN_IDENTITY) also asks Apple's timestamp server for a secure timestamp,
# which notarization requires; scripts/release.sh sets it.
#
# Layout:
#   Keeplight.app/Contents/MacOS/Keeplight        app (SwiftPM product KeeplightApp)
#   Keeplight.app/Contents/Helpers/keeplight      CLI (Contents/MacOS/keeplight would collide with
#                                               Contents/MacOS/Keeplight on case-insensitive volumes)
#   Keeplight.app/Contents/Resources/AppIcon.icns
# Release binaries are stripped (`strip -S -x`) before they are signed.
# Info.plist gets DPGitCommit = short git commit ("unknown" outside a git checkout).
#
# Everything is assembled, signed and verified in .build/bundle/ first (strict signature check of
# the app and both CLI copies, then scripts/check-bundle.sh). Only a bundle that passed is copied
# to dist/; a failed run leaves dist/ exactly as it was.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

flags=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    flags+=(--arch arm64 --arch x86_64)
fi

swift build "${flags[@]}"
bin="$(swift build "${flags[@]}" --show-bin-path)"

# Fails the bundle if either binary references networking symbols.
if [[ -f "$root/scripts/audit-network.sh" ]]; then
    BIN_PATH="$bin" bash "$root/scripts/audit-network.sh" "$bin"
fi

commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
commit="${commit:-unknown}"

stage="$root/.build/bundle"
app="$stage/Keeplight.app"
cli="$stage/keeplight"
contents="$app/Contents"
rm -rf "$stage"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources"

cp "$bin/KeeplightApp" "$contents/MacOS/Keeplight"
cp "$bin/keeplight" "$contents/Helpers/keeplight"
cp "$root/Resources/Info.plist" "$contents/Info.plist"
[[ -f "$root/Resources/AppIcon.icns" ]] || { echo "missing Resources/AppIcon.icns" >&2; exit 1; }
cp "$root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
printf 'APPL????' > "$contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Add :DPGitCommit string $commit" "$contents/Info.plist"

cp "$bin/keeplight" "$cli"

# Release symbols are dead weight (about 55 % of each binary). Stripping invalidates any
# signature, so it happens before signing below.
sizes() { stat -f '%z' "$@" | paste -sd' ' -; }
before="$(sizes "$contents/MacOS/Keeplight" "$contents/Helpers/keeplight" "$cli")"
strip -S -x "$contents/MacOS/Keeplight" "$contents/Helpers/keeplight" "$cli"
echo "strip: app/helper/cli bytes $before -> $(sizes "$contents/MacOS/Keeplight" "$contents/Helpers/keeplight" "$cli")"

# Nested code first, then the bundle. Ad hoc unless SIGN_IDENTITY is set.
identity="${SIGN_IDENTITY:--}"
sign=(codesign --force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign+=(--options runtime)
    if [[ "${SIGN_TIMESTAMP:-0}" == "1" ]]; then sign+=(--timestamp); fi
fi
"${sign[@]}" --identifier io.github.htahaozlu.Keeplight.cli "$contents/Helpers/keeplight"
"${sign[@]}" --identifier io.github.htahaozlu.Keeplight.cli "$cli"
"${sign[@]}" "$app"

# Gates, all before anything reaches dist/.
codesign --verify --strict --deep "$app"
codesign --verify --strict "$cli"
bash "$root/scripts/check-bundle.sh" "$app"

# Publish: replace dist/Keeplight.app and dist/keeplight with the verified copies (ditto keeps the
# signature intact), then check the published bundle once more.
dist="$root/dist"
mkdir -p "$dist"
rm -rf "$dist/Keeplight.app.new" "$dist/keeplight.new"
ditto "$app" "$dist/Keeplight.app.new"
ditto "$cli" "$dist/keeplight.new"
codesign --verify --strict --deep "$dist/Keeplight.app.new"
codesign --verify --strict "$dist/keeplight.new"
rm -rf "$dist/Keeplight.app"
mv "$dist/Keeplight.app.new" "$dist/Keeplight.app"
mv -f "$dist/keeplight.new" "$dist/keeplight"
bash "$root/scripts/check-bundle.sh" "$dist/Keeplight.app"

if [[ "$identity" == "-" ]]; then
    echo "signature: ad hoc (local use only; not Developer ID signed, not notarized)"
else
    echo "signature: $identity (hardened runtime; not notarized by this script)"
fi
echo "$dist/Keeplight.app ($commit)"
echo "$dist/keeplight"
