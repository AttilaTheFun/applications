#!/bin/bash
# OS Server's command line, asked again when no server answered: the client
# gives up when the server's hello takes over 4 seconds, which a busy Mac's
# server sometimes does ("oss: no oss server answered"). Nothing was asked
# of the server then, so asking again is safe: up to five tries, ten seconds
# apart. Any other failure is the command's own, passed on at once. The CI
# scripts call this in place of oss (OSS_REAL is oss itself).
#
#   OSS_REAL=<oss> tools/ci/oss_retry.sh <oss arguments…>
set -uo pipefail
real="${OSS_REAL:?oss_retry.sh: OSS_REAL names oss}"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
try=1
while :; do
    "$real" "$@" 2> "$err"
    status=$?
    cat "$err" >&2
    if [ "$status" -ne 0 ] && [ "$try" -lt 5 ] && grep -q "no oss server answered" "$err"; then
        echo "oss_retry.sh: no OS Server answered; asking again in 10 s (try $try of 5)" >&2
        try=$((try + 1))
        sleep 10
        continue
    fi
    exit "$status"
done
