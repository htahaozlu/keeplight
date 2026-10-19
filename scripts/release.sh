#!/usr/bin/env bash
# release.sh — the downloadable Keeplight: a universal, Developer ID–signed (hardened runtime, secure
# timestamp), notarized and stapled Keeplight.app inside a signed, notarized and stapled DMG, its
# SHA-256, and the Homebrew cask filled in for this version. Output: dist/
#
#   scripts/release.sh
#
# Needs (once): the Developer ID Application certificate and its key in the login keychain, and
# notarytool credentials stored under a keychain profile. Snapline's profile is for the same team, so
# it works as is; to make one:
#   xcrun notarytool store-credentials snapline-notary --apple-id <id> --team-id DQJT5BCZCM
#
# Environment
#   SIGN_IDENTITY           codesign identity (default "Developer ID Application: Hasan Taha Ozlu (DQJT5BCZCM)")
#   NOTARY_PROFILE          notarytool keychain profile (default snapline-notary)
#   KEEPLIGHT_ALLOW_DIRTY=1 build from a tree with uncommitted changes (never for a published release)
#   KEEPLIGHT_SKIP_TESTS=1  skip `swift test` (never for a published release)
#
# Network: Apple's timestamp server (codesign --timestamp) and notary service (the app and the DMG are
# uploaded for notarization). Nothing else. It publishes nothing: tagging, the GitHub release and the
# tap update are printed at the end for you to run. Fails closed: every step that does not verify
# stops it, and a failed run never leaves a Keeplight.dmg behind.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Hasan Taha Ozlu (DQJT5BCZCM)}"
PROFILE="${NOTARY_PROFILE:-snapline-notary}"
TEAM="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_IDENTITY")"
[ -n "$TEAM" ] || die "SIGN_IDENTITY must end in its team ID, e.g. \"Developer ID Application: Name (ABCDE12345)\""

OUT="$ROOT/dist"
APP="$OUT/Keeplight.app"
DMG="$OUT/Keeplight.dmg"
SHA="$DMG.sha256"
CASK_TEMPLATE="$ROOT/packaging/homebrew/keeplight.rb"
CASK="$OUT/keeplight.rb"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/keeplight-release.XXXXXX")"
MOUNT=""

cleanup() {
    status=$?
    if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true; fi
    rm -rf "$WORK"
    # A run that did not finish leaves no DMG that could be mistaken for a release.
    if [ "$status" -ne 0 ]; then rm -f "$DMG" "$SHA" "$CASK"; fi
}
trap cleanup EXIT

# --- preconditions ----------------------------------------------------------------------------------

for tool in swift git codesign xcrun hdiutil spctl lipo shasum ditto plutil security; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[ -x /usr/libexec/PlistBuddy ] || die "missing /usr/libexec/PlistBuddy"
[ -f "$CASK_TEMPLATE" ] || die "missing $CASK_TEMPLATE"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
CORE_VERSION="$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/DisplayCore/Storage/Storage.swift | head -1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString '$VERSION' is not x.y.z"
[ "$VERSION" = "$CORE_VERSION" ] || die "Info.plist says $VERSION but DisplayCore (the CLI's --version) says '$CORE_VERSION'"

if [ "${KEEPLIGHT_ALLOW_DIRTY:-0}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
    die "uncommitted changes: commit first (the bundle records the commit, and the tag must match it)"
fi
COMMIT="$(git rev-parse --short HEAD)"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    [ "$(git rev-list -n 1 "v$VERSION")" = "$(git rev-parse HEAD)" ] || die "tag v$VERSION exists and points elsewhere: bump the version"
fi

security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\"" \
    || die "no valid codesigning identity \"$SIGN_IDENTITY\" in the keychain"
log "notary profile '$PROFILE' (asks Apple once, before anything is built)"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null \
    || die "notarytool cannot use keychain profile '$PROFILE' (xcrun notarytool store-credentials $PROFILE …)"

rm -f "$DMG" "$SHA" "$CASK" "$OUT"/notary-*.json

# --- build ------------------------------------------------------------------------------------------

if [ "${KEEPLIGHT_SKIP_TESTS:-0}" != "1" ]; then
    log "swift test"
    swift test
fi

log "build $VERSION ($BUILD, $COMMIT): universal, $SIGN_IDENTITY, hardened runtime, secure timestamp"
# bundle-app.sh also runs scripts/audit-network.sh and scripts/check-bundle.sh and only replaces
# dist/Keeplight.app when they pass.
UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" SIGN_TIMESTAMP=1 bash scripts/bundle-app.sh

# --- verify the app ---------------------------------------------------------------------------------

check_signature() {   # <path> [runtime]
    local info
    info="$(codesign -dv --verbose=4 "$1" 2>&1)" || die "cannot read the signature of $1"
    grep -q '^Authority=Developer ID Application: ' <<<"$info" || die "$1: not signed with a Developer ID Application certificate"
    grep -qx "TeamIdentifier=$TEAM" <<<"$info" || die "$1: team is not $TEAM"
    grep -q '^Timestamp=' <<<"$info" || die "$1: no secure timestamp (notarization would fail)"
    if [ "${2:-}" = runtime ]; then
        grep -Eq '^CodeDirectory .*flags=[^ ]*runtime' <<<"$info" || die "$1: hardened runtime missing"
    fi
}

check_universal() {
    local archs
    archs=" $(lipo -archs "$1") "
    [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]] || die "$1 is not universal (has:$archs)"
}

log "verify the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
check_signature "$APP" runtime
check_signature "$APP/Contents/Helpers/keeplight" runtime
check_universal "$APP/Contents/MacOS/Keeplight"
check_universal "$APP/Contents/Helpers/keeplight"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
    || die "the bundle's version is not $VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :DPGitCommit' "$APP/Contents/Info.plist")" = "$COMMIT" ] \
    || die "the bundle was not built from $COMMIT"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -Eq '<key>|\[Key\]'; then
    die "the app carries entitlements; Keeplight ships with none"
fi

notarize() {   # <file> <label>
    local json="$OUT/notary-$2.json" status id
    log "notarize $2 (uploads to Apple, waits for the verdict)"
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$json" || true
    status="$(plutil -extract status raw -o - "$json" 2>/dev/null || echo "no answer")"
    id="$(plutil -extract id raw -o - "$json" 2>/dev/null || true)"
    if [ -n "$id" ]; then
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-$2-log.json" >/dev/null || true
    fi
    [ "$status" = "Accepted" ] || die "notarization of $2: $status (details: $OUT/notary-$2-log.json)"
    printf '  %s accepted (%s)\n' "$2" "$id"
}

ditto -c -k --keepParent "$APP" "$WORK/Keeplight.zip"
notarize "$WORK/Keeplight.zip" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

log "Gatekeeper: the app"
assessment="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" || die "Gatekeeper rejects the app: $assessment"
grep -q 'source=Notarized Developer ID' <<<"$assessment" || die "Gatekeeper does not see a notarized Developer ID app: $assessment"

# --- the DMG ----------------------------------------------------------------------------------------

log "DMG: Keeplight.app + Applications"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Keeplight.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Keeplight" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
check_signature "$DMG"

notarize "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

log "Gatekeeper: the DMG"
assessment="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1)" \
    || die "Gatekeeper rejects the DMG: $assessment"
grep -q 'source=Notarized Developer ID' <<<"$assessment" || die "Gatekeeper does not see a notarized Developer ID DMG: $assessment"

log "the DMG as a user gets it: mount read-only and check what is inside"
MOUNT="$WORK/mount"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
[ -d "$MOUNT/Keeplight.app" ] || die "Keeplight.app missing from the DMG"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] || die "the Applications link is missing from the DMG"
codesign --verify --deep --strict "$MOUNT/Keeplight.app" || die "the app inside the DMG does not verify"
xcrun stapler validate "$MOUNT/Keeplight.app" >/dev/null || die "the app inside the DMG carries no notarization ticket"
assessment="$(spctl --assess --type execute --verbose=4 "$MOUNT/Keeplight.app" 2>&1)" || die "Gatekeeper rejects the app inside the DMG: $assessment"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/Keeplight.app/Contents/Info.plist")" = "$VERSION" ] \
    || die "the app inside the DMG is not $VERSION"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# --- checksum and cask ------------------------------------------------------------------------------

(cd "$OUT" && shasum -a 256 Keeplight.dmg > Keeplight.dmg.sha256)
DIGEST="$(awk '{print $1}' "$SHA")"
[[ "$DIGEST" =~ ^[0-9a-f]{64}$ ]] || die "bad SHA-256: $DIGEST"

# The template's header comment is for this repository; the tap gets the cask alone.
sed -e '/^#/d' -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$DIGEST/" "$CASK_TEMPLATE" > "$CASK"
! grep -q '__[A-Z0-9]*__' "$CASK" || die "placeholders left in $CASK"
if command -v ruby >/dev/null; then ruby -c "$CASK" >/dev/null || die "$CASK is not valid Ruby"; fi

echo
log "result: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
printf '  version:  %s (build %s, commit %s)\n' "$VERSION" "$BUILD" "$COMMIT"
printf '  sha256:   %s\n' "$DIGEST"
printf '  app:      %s (Developer ID, hardened runtime, notarized, stapled; universal)\n' "$APP"
printf '  cask:     %s (version and sha256 filled in)\n' "$CASK"
cat <<EOF

Nothing has been published. To release $VERSION:
  git tag -a v$VERSION -m "Keeplight $VERSION" && git push origin v$VERSION
  gh release create v$VERSION "$DMG" "$SHA" --title "Keeplight $VERSION" --notes "SHA-256: $DIGEST"
  # then, in a clone of github.com/htahaozlu/homebrew-keeplight:
  cp "$CASK" Casks/keeplight.rb && git add Casks/keeplight.rb \\
    && git commit -m "keeplight $VERSION" && git push
EOF
