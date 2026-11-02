#!/bin/bash
# Applications' tests that need a Mac, in a macOS VM leased from OS Server
# (xcode_27_2): the Mac's tests and the server's, with the rest of //tests
# and //libraries, but not the iPhone and iPad tests, which are built on
# Linux and run on an iOS lease, where the proof is made of their pictures
# (tools/ci/ios_lease_tests.sh).
#
#   tools/ci/mac_vm_tests.sh [--logs <dir>]
#
# --logs gets the tests' logs (their bazel-testlogs). The script fails as
# the tests do.
#
# The VM (tools/ci/mac_vm.sh) is the script's alone, released however it
# ends; the tree goes in as committed (the job stamps no version). The
# Mac's pictures aren't compared: a VM's window server draws the Mac's
# sidebars blank (tests/mac_tests), and they compare only where CI or
# SNAPSHOT_COMPARE is set, which nothing passes in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"

usage() { echo "usage: tools/ci/mac_vm_tests.sh [--logs <dir>]" >&2; exit 2; }
logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --logs) logs="${2:?--logs takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done

mac_vm_start applications-ci

# The iOS tests are ios-tests' (tools/ci/ios_lease_tests.sh).
mac_vm_steps << 'STEPS'
    test)
        cd src && bazel test --keep_going --test_output=errors -- //tests/... //libraries/... -//tests/app_tests
        ;;
    logs)
        cd src && tar -czf ~/ci/test-logs.tar.gz -C bazel-testlogs/ .
        ;;
STEPS

echo "::group::A macOS VM (xcode_27_2)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

echo "::group::bazel test //tests/... //libraries/..."
status=0
run in_vm test || status=$?
echo "::endgroup::"
if [ -n "$logs" ]; then
    mkdir -p "$logs"
    if run in_vm logs && run "$OSS" machine download "$lease" --identity="$work/key" ci/test-logs.tar.gz "$work/test-logs.tar.gz"; then
        tar -xzf "$work/test-logs.tar.gz" -C "$logs"
    else
        echo "mac_vm_tests.sh: no test logs" >&2
    fi
fi
mac_vm_release
finished=1
exit "$status"
