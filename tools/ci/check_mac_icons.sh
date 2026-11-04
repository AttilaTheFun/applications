#!/bin/bash
# Every Mac app among a folder's zips has icons in the dark appearance
# (NSAppearanceNameDarkAqua, by `assetutil --info` of its Assets.car), or
# this fails and nothing is published: a flat icon, with no dark or tinted
# appearance, is never published. The apps are built on Linux with
# rules_applecross, whose actool compiles an Icon Composer icon's layers and
# appearances as Xcode does (.bazelrc's apple_on_linux accepts its flattened
# images, which aren't Xcode's); this checks what it made with Xcode's
# assetutil, on a slot of OS Server's primary Mac (tools/ci/mac_slot.sh), so
# it runs on Linux, in a CI job's container, as on a Mac.
#
#   tools/ci/check_mac_icons.sh <dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
dir="${1:?usage: tools/ci/check_mac_icons.sh <dir>}"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss || true)"
# Every call asked again when no server answered (tools/ci/oss_retry.sh).
export OSS_REAL="$OSS"
OSS="$ROOT/tools/ci/oss_retry.sh"
work="$(mktemp -d)"
# shellcheck source=tools/ci/mac_slot.sh
. "$ROOT/tools/ci/mac_slot.sh"
cleanup() {
    local status=$?
    mac_slot_release
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# assetutil --info <car>, on the slot.
asset_info() {
    mac_slot_lease
    mac_slot_upload "$1" Assets.car
    mac_slot_exec xcrun --sdk macosx assetutil --info Assets.car
}

status=0
zips=0
for zip in "$dir"/*.zip; do
    [ -e "$zip" ] || continue
    zips=$((zips + 1))
    rm -rf "$work/unzipped" && mkdir "$work/unzipped"
    unzip -q "$zip" -d "$work/unzipped"
    apps=0
    for app in "$work/unzipped"/*.app; do
        [ -e "$app" ] || continue
        apps=$((apps + 1))
        name="$(basename "$app")"
        car="$app/Contents/Resources/Assets.car"
        if [ ! -f "$car" ]; then
            echo "::error::$name has no Assets.car: no icon compiled by actool"
            status=1
            continue
        fi
        info="$(asset_info "$car")" || { echo "::error::assetutil couldn't read $name's Assets.car"; status=1; continue; }
        dark="$(printf '%s\n' "$info" | grep -c NSAppearanceNameDarkAqua)" || true
        if [ "${dark:-0}" -gt 0 ]; then
            echo "$name: $dark renditions in the dark appearance (NSAppearanceNameDarkAqua)"
        else
            echo "::error::$name's icon has no dark appearance (no NSAppearanceNameDarkAqua in its Assets.car): a flat icon"
            status=1
        fi
    done
    if [ "$apps" -eq 0 ]; then
        echo "::error::$(basename "$zip") holds no Mac app"
        status=1
    fi
done
[ "$zips" -gt 0 ] || { echo "::error::no zip in $dir"; status=1; }
exit "$status"
