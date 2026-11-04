#!/bin/bash
# Applications' iPhone and iPad tests without a macOS VM: built in
# the Linux container that builds everything else (tools/ci/container_build.sh,
# with rules_applecross; //tools/ci:ios_tests_anywhere builds them there),
# and run on an iOS lease's simulator (`oss machine xctest`, an iPhone 17,
# as .bazelrc's tests and the pictures have it), as rules_apple runs them on
# a Mac. Then
# the proof: every picture the app's tests took, each against its picture at
# the proof's base (tools/ci/proof_baseline: a run by hand's release
# before the commit, a release's release before; never this tree's kept pictures,
# which a change re-records, so its own would show every screen it changed
# as unchanged). A lease's tests take no environment (no
# SNAPSHOT_RECORD_DIR), so the pictures come from the run's result bundle,
# where the tests attach every one they take (libraries/pipeline_snapshots),
# by xcresulttool. That, and the diffs (CoreGraphics), run on a slot of OS
# Server's primary Mac (tools/ci/mac_slot.sh), so the script runs on Linux,
# in a CI job's container.
#
#   tools/ci/ios_lease_tests.sh [--proof <dir>] [--logs <dir>] [--kind quick|full]
#
# The tests always run, comparing with this tree's kept pictures. Only with
# --proof is the proof made: CI makes it only by hand (to propose a
# release, or on an earlier commit to bisect; against the release before
# it), never for a pull request or a push to main, which only build and
# test. The proof, in <dir>:
#   screens/<name>.png  every picture the app's iPhone and iPad tests take
#   before/<name>.png   each that changed, as the base kept it
#                       (tests/app_tests/Snapshots there); none for a
#                       screen the base hasn't got (new, and changed)
#   diffs/<name>.png    each that changed, faded grey with its changed
#                       pixels red (tools/ci/snapshot_diff.swift, built
#                       on the slot)
#   proof.json          {"commit", "ref", "kind", "run",
#                        "base": {"ref", "commit"},
#                        "screens": [{"name", "changed", "changedPixels"}]}
# --logs gets each test's JUnit and result bundle. The script fails as the
# tests do, or (making the proof) where the base can't be fetched or no
# picture came back.
#
#   PROOF_REF  the ref the proof is of (default: GITHUB_REF, else the branch)
#   GITHUB_EVENT_NAME, GITHUB_BASE_REF, GITHUB_REF_NAME  what the base is
#              (by hand, none: main)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
# Every call asked again when no server answered (tools/ci/oss_retry.sh).
export OSS_REAL="$OSS"
OSS="$ROOT/tools/ci/oss_retry.sh"
DEVICE="iPhone 17"

usage() { echo "usage: tools/ci/ios_lease_tests.sh [--proof <dir>] [--logs <dir>] [--kind quick|full]" >&2; exit 2; }
proof=""
logs=""
kind="quick"
while [ $# -gt 0 ]; do
    case "$1" in
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --logs) logs="${2:?--logs takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        *) usage ;;
    esac
done
case "$kind" in quick | full) ;; *) usage ;; esac

commit="$(git -C "$ROOT" rev-parse HEAD)"
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git -C "$ROOT" branch --show-current)}}"
work="$(mktemp -d)"
chmod 700 "$work"
# shellcheck source=tools/ci/mac_slot.sh
. "$ROOT/tools/ci/mac_slot.sh"
lease=""
renewer=""
finished=""
release() {
    if [ -n "$renewer" ]; then kill "$renewer" 2> /dev/null || true; wait "$renewer" 2> /dev/null || true; renewer=""; fi
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "$me: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    release
    mac_slot_release
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Making the proof: the proof's base first (by proof_baseline, Foundation
# alone, built here), nothing built or leased if it fails.
if [ -n "$proof" ]; then
swiftc=(swiftc)
[ "$(uname -s)" != Darwin ] || swiftc=(xcrun swiftc)
"${swiftc[@]}" -O -o "$work/proof_baseline" "$ROOT/tools/ci/proof_baseline/Baseline.swift" "$ROOT/tools/ci/proof_baseline/main.swift"
# A release's base is the release before: its tags, asked of origin. A run
# by hand's (proposing a release, or proving an earlier commit to bisect)
# is the release before the commit: the tags its history has before it.
tags=""
case "${GITHUB_EVENT_NAME:-}" in
    release) tags="$(git -C "$ROOT" ls-remote --tags --refs origin 'v*' | sed 's#.*refs/tags/##')" ;;
    workflow_dispatch)
        if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = true ]; then
            git -C "$ROOT" fetch --quiet --unshallow --tags origin
        else
            git -C "$ROOT" fetch --quiet --tags origin
        fi
        tags="$(git -C "$ROOT" tag --merged "$commit^" --list 'v*' 2> /dev/null || true)"
        ;;
esac
# shellcheck disable=SC2086 # the tags, a word each
baseline="$("$work/proof_baseline" "${GITHUB_EVENT_NAME:-}" "${GITHUB_BASE_REF:-}" "${GITHUB_REF_NAME:-}" "$commit" $tags)"
{ read -r base_ref; read -r base_revision; read -r base_fetch; } <<< "$baseline"
if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" != true ]; then
    # shellcheck disable=SC2086 # git fetch's arguments, a word each
    base_fetch="$(printf '%s\n' $base_fetch | grep -v '^--depth=' | tr '\n' ' ')"
fi
# shellcheck disable=SC2086 # git fetch's arguments, a word each
git -C "$ROOT" fetch --quiet $base_fetch
base_commit="$(git -C "$ROOT" rev-parse --verify "$base_revision^{commit}")"
echo "$me: the proof compares with $base_ref ($base_commit)"
fi

# The tests' bundles and their hosts, built on Linux for the arm64
# simulator. Each test: its bundle's zip, its host's .ipa, and whether its
# pictures are the proof's.
tests=(
    "app_tests applications_ios proof"
)
echo "::group::The tests and their hosts, built on Linux"
bundles="$ROOT/.ci/ios-tests"
"$ROOT/tools/ci/container_build.sh" package "$bundles" \
    --//tools/ci:ios_tests_anywhere --ios_multi_cpus=sim_arm64 \
    //tests/app_tests //app:applications_ios
echo "::endgroup::"
for test in "${tests[@]}"; do
    read -r bundle host _ <<< "$test"
    for file in "$bundles/$bundle.zip" "$bundles/$host.ipa"; do
        [ -f "$file" ] || { echo "$me: the build left no $(basename "$file")" >&2; exit 1; }
    done
done

echo "::group::An iOS lease ($DEVICE)"
"$OSS" machine lease ios --device="$DEVICE" --minutes=60 --wait --exports > "$work/lease"
lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
echo "Leased $lease"
(
    trap 'kill $! 2> /dev/null; exit 0' TERM
    while :; do
        sleep 600 &
        wait $!
        "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
    done
) &
renewer=$!
echo "::endgroup::"

# Each test on the lease, one at a time (a lease runs one), whatever the
# one before did.
status=0
mkdir -p "$work/results"
for test in "${tests[@]}"; do
    read -r bundle host _ <<< "$test"
    echo "::group::$bundle"
    "$OSS" machine xctest "$lease" --tests="$bundles/$bundle.zip" --host="$bundles/$host.ipa" \
        --junit="$work/results/$bundle.xml" --result="$work/results/$bundle.xcresult.zip" || status=$?
    echo "::endgroup::"
done
release
if [ -n "$logs" ]; then
    mkdir -p "$logs"
    cp "$work/results"/* "$logs"/ 2> /dev/null || true
fi

if [ -z "$proof" ]; then
    finished=1
    exit "$status"
fi

# The pictures: each attachment of the proof's tests named <screen>.png,
# exported from its result bundle by xcresulttool, on the slot.
mac_slot_lease
mkdir -p "$work/recorded"
for test in "${tests[@]}"; do
    read -r bundle _ role <<< "$test"
    [ "$role" = proof ] || continue
    result="$work/results/$bundle.xcresult.zip"
    [ -f "$result" ] || { echo "$me: $bundle left no result bundle" >&2; continue; }
    rm -rf "$work/attachments"
    mkdir "$work/attachments"
    mac_slot_upload "$result" result.xcresult.zip
    mac_slot_exec bash -c 'rm -rf result attachments && mkdir result attachments \
        && ditto -x -k result.xcresult.zip result \
        && bundle="$(find result -maxdepth 2 -name "*.xcresult" -type d | head -1)" \
        && xcrun xcresulttool export attachments --path "$bundle" --output-path attachments > /dev/null \
        && tar -czf attachments.tar.gz -C attachments .'
    mac_slot_download attachments.tar.gz "$work/attachments.tar.gz"
    tar -xzf "$work/attachments.tar.gz" -C "$work/attachments"
    python3 - "$work/attachments" "$work/recorded" << 'PY'
import json, os, re, shutil, sys
source, out = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test.get("attachments", []):
        # The attachment's name as the test gave it, which xcresulttool
        # suffixes with an index and an identifier.
        name = attachment.get("suggestedHumanReadableName", "")
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$)", "", name)
        if name.endswith(".png"):
            shutil.copy(os.path.join(source, attachment["exportedFileName"]), os.path.join(out, name))
PY
done
ls "$work/recorded"

# Each picture against its kept one at the base, by snapshot_diff on the
# slot: the pictures and the kept ones go up, the diffs and each one's
# count of changed pixels come back.
mkdir -p "$work/compare/recorded" "$work/compare/base"
snapshots=tests/app_tests/Snapshots
for picture in "$work/recorded"/*.png; do
    [ -e "$picture" ] || continue
    name="$(basename "$picture" .png)"
    cp "$picture" "$work/compare/recorded/$name.png"
    if git -C "$ROOT" cat-file -e "$base_commit:$snapshots/$name.png" 2>/dev/null; then
        git -C "$ROOT" show "$base_commit:$snapshots/$name.png" > "$work/compare/base/$name.png"
    fi
done
cp "$ROOT/tools/ci/snapshot_diff.swift" "$work/compare/"
tar -czf "$work/compare.tar.gz" -C "$work/compare" .
mac_slot_upload "$work/compare.tar.gz" compare.tar.gz
mac_slot_exec bash -c 'rm -rf compare && mkdir compare && tar -xzf compare.tar.gz -C compare && cd compare \
    && xcrun swiftc -O -o snapshot_diff snapshot_diff.swift && mkdir diffs \
    && for picture in recorded/*.png; do
        [ -e "$picture" ] || continue
        name="$(basename "$picture" .png)"
        printf "%s %s\n" "$(./snapshot_diff "base/$name.png" "$picture" "diffs/$name.png")" "$name" >> pixels.txt || exit
    done; touch pixels.txt && tar -czf ../diffs.tar.gz diffs pixels.txt'
mac_slot_download diffs.tar.gz "$work/diffs.tar.gz"
mac_slot_release
mkdir "$work/diffed"
tar -xzf "$work/diffs.tar.gz" -C "$work/diffed"

# The proof, from the pictures, the kept ones and their diffs.
json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
mkdir -p "$proof/screens" "$proof/diffs" "$proof/before"
screens=""
summary=""
while read -r pixels name; do
    [ -n "$name" ] || continue
    cp "$work/recorded/$name.png" "$proof/screens/$name.png"
    [ ! -e "$work/diffed/diffs/$name.png" ] || cp "$work/diffed/diffs/$name.png" "$proof/diffs/$name.png"
    changed=false
    [ "$pixels" -eq 0 ] || changed=true
    if [ "$changed" = true ] && [ -e "$work/compare/base/$name.png" ]; then cp "$work/compare/base/$name.png" "$proof/before/$name.png"; fi
    screens="$screens${screens:+,}
    {\"name\": \"$(json "$name")\", \"changed\": $changed, \"changedPixels\": $pixels}"
    summary="$summary| $name | $([ "$changed" = true ] && echo "$pixels pixels changed" || echo unchanged) |
"
done < "$work/diffed/pixels.txt"
cat > "$proof/proof.json" << EOF
{
  "commit": "$commit",
  "ref": "$(json "$ref")",
  "kind": "$kind",
  "run": ${GITHUB_RUN_ID:-null},
  "base": {"ref": "$(json "$base_ref")", "commit": "$base_commit"},
  "screens": [$screens
  ]
}
EOF
cat "$proof/proof.json"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Proof (%s, on an iOS lease) of %s\n\n| Screen | Against %s (%s) |\n| --- | --- |\n%s' "$kind" "${commit:0:7}" "$base_ref" "${base_commit:0:7}" \
        "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -z "$screens" ]; then
    echo "$me: no pictures came back in the result bundle" >&2
    [ "$status" -ne 0 ] || status=1
fi
finished=1
exit "$status"
