#!/usr/bin/env bash
# Renders every Keeplight surface offscreen to PNG with the debug-only `keeplight-render` tool, and
# fails if the run changed Keeplight's real preferences or state on disk.
#
#   scripts/render.sh [OUT_DIR] [--only TEXT]      (default OUT_DIR: .build/render)
#
# Before and after the run it records, for the app's preferences plist, the tool's own defaults
# plist and every file under ~/Library/Application Support/Keeplight: mtime, size and SHA-256 (or
# "absent"). Any difference fails the script, as does a non-zero exit from the tool (a fake
# refused a call, a window became visible, or its temporary state directory was written).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

out="$root/.build/render"
if [[ $# -gt 0 && "$1" != --* ]]; then out="$1"; shift; fi

prefs="$HOME/Library/Preferences/io.github.htahaozlu.Keeplight.plist"
tool_prefs="$HOME/Library/Preferences/keeplight-render.plist"
support="$HOME/Library/Application Support/Keeplight"

file_state() {
    if [[ -f "$1" ]]; then
        printf '%s mtime=%s size=%s sha256=%s\n' "$1" "$(stat -f %m "$1")" "$(stat -f %z "$1")" \
            "$(shasum -a 256 < "$1" | cut -d' ' -f1)"
    elif [[ -d "$1" ]]; then
        printf '%s dir mtime=%s\n' "$1" "$(stat -f %m "$1")"
    else
        printf '%s absent\n' "$1"
    fi
}

state() {
    file_state "$prefs"
    file_state "$tool_prefs"
    if [[ -d "$support" ]]; then
        find "$support" -print | LC_ALL=C sort | while IFS= read -r path; do file_state "$path"; done
    else
        printf '%s absent\n' "$support"
    fi
}

mkdir -p "$out"
before="$out/state-before.txt"
after="$out/state-after.txt"

swift build --product keeplight-render
bin="$(swift build --show-bin-path)/keeplight-render"

# Belt and braces: anything that still asked for the live support directory would land here.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/keeplight-render-support.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

state > "$before"
status=0
KEEPLIGHT_SUPPORT_DIR="$scratch" "$bin" --out "$out" --resources "$root/Resources" "$@" || status=$?
state > "$after"

if [[ -n "$(ls -A "$scratch")" ]]; then
    echo "render.sh: FAIL — the support-directory override was written: $(ls -A "$scratch")" >&2
    status=1
fi
if ! diff -u "$before" "$after" > "$out/state-diff.txt"; then
    echo "render.sh: FAIL — Keeplight preferences or state changed during the run:" >&2
    cat "$out/state-diff.txt" >&2
    exit 1
fi
rm -f "$out/state-diff.txt"
echo "render.sh: preferences and state unchanged ($(wc -l < "$before" | tr -d ' ') paths checked)"
exit "$status"
