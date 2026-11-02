#!/bin/bash
# Applications built in a Linux container, as isomer's and visor's CI build
# theirs: a container leased from this Mac's OS Server (containers are lent
# on the server's own Mac only), made from Visor's agent image, so CI builds
# where a session's agent works. The apps and the server take Xcode 27.2's
# SDK archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token in the container's .netrc)
# through a downloader config written here, and its Bazel reads that
# server's cache: no host is named in the repository.
#
# The build is the container's main process (`--command`): a script written
# into .ci/container, where it also writes its log and its exit status,
# which this script follows and passes on, releasing the container however
# it ends. Not `oss machine run --inside`: that sends its command over the
# container's socket, in OS Server's own folder, which only OS Server's
# user reaches, and CI's runner is a user of its own (until OS Server runs a
# container's commands through its API).
#
#   tools/ci/container_build.sh                  # what CI builds, then the tests that run on Linux
#   tools/ci/container_build.sh build <args…>    # bazel build <args…> there (test, the same)
#   tools/ci/container_build.sh package <dir> <args…>
#                                                # bazel build <args…>, then the targets' files
#                                                # copied to <dir> (in this checkout), for CI to publish
#
#   OSS_FILES_HOST          the name the container reaches this Mac's OS Server by
#                           (default: this Mac's tailnet name, from Tailscale)
#   APPLICATIONS_CI_IMAGE   the image (default: Visor's agent image, below)
#   APPLICATIONS_CI_VOLUME  Bazel's tree: by default one of the run's own, given
#                           back with the lease (a build from cold but for what
#                           the server's cache has); a name of your own is kept
#                           between runs (`oss volume delete <name>` when done)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${APPLICATIONS_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.41.2}"
SDK_SHA256="b1583e60f9fd35881b5a948ce71627079877f1ced7ea231e14d3c342dd389668"
if [ -n "${APPLICATIONS_CI_VOLUME:-}" ]; then
    volume="$APPLICATIONS_CI_VOLUME:/var/cache/bazel:128:keep"
else
    volume="applications-ci-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}:/var/cache/bazel:128"
fi
# The container's command is split on spaces.
case "$ROOT" in *" "*) echo "container_build.sh: this checkout's path has a space ($ROOT)" >&2; exit 1 ;; esac

# The command line inside OS Server, or on the path.
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
# Every call asked again when no server answered (tools/ci/oss_retry.sh).
export OSS_REAL="$OSS"
OSS="$ROOT/tools/ci/oss_retry.sh"

host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    host="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null | plutil -extract Self.DNSName raw -o - - 2>/dev/null || true)"
    host="${host%.}"
fi
if [ -z "$host" ]; then
    # Tailscale's command line answers only the user signed in to its app,
    # not CI's: the same name, from MagicDNS, for this Mac's tailnet address.
    address="$(ifconfig | awk '/inet 100\./ { print $2; exit }')"
    [ -z "$address" ] || host="$(dig +short +time=2 +tries=2 -x "$address" @100.100.100.100 | head -1)"
    host="${host%.}"
fi
[ -n "$host" ] || { echo "container_build.sh: no tailnet name for this Mac (Tailscale off?): set OSS_FILES_HOST" >&2; exit 1; }

# MODULE.bazel's placeholders, to this Mac's OS Server (.ci is not checked
# in; a builder's .bazelrc.user may name the same file).
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF

# What the container runs, and where it says how it went. The container
# writes as OS Server's user, which needn't be this one (CI's runner is a
# user of its own): the folders it writes are made here, writable by the
# group the two share, and emptied of an earlier run's.
box="$ROOT/.ci/container"
rm -rf "$box"
mkdir -p "$box"
chmod 775 "$box"

flags=("--downloader_config=$ROOT/.ci/downloader.cfg")
# A builder's .bazelrc.user may turn apple_on_linux on already (README):
# given twice, Bazel warns of it.
grep -qsx 'build:linux --config=apple_on_linux' "$ROOT/.bazelrc.user" || flags+=(--config=apple_on_linux)
if [ "${1:-}" = package ]; then
    [ $# -ge 3 ] || { echo "usage: tools/ci/container_build.sh package <dir> <bazel args…>" >&2; exit 1; }
    # Bazel's tree is the container's own (a volume), gone with the lease:
    # what CI publishes is copied out into this checkout, the one folder of
    # the Mac's the container sees.
    mkdir -p "$2"
    out="$(cd "$2" && pwd)"
    case "$out/" in
        "$ROOT"/*) ;;
        *) echo "container_build.sh: package's folder must be in this checkout ($ROOT)" >&2; exit 1 ;;
    esac
    rm -f "$out"/*
    chmod 775 "$out"
    # Each target's files (a Mac app's .zip, an .ipa), by cquery with the
    # build's own flags, from the execution root (no bazel-out link here),
    # which info gives with the build's options (a .bazelrc.user's may need
    # them).
    command=(bash -c 'out="$1"; shift
        options=()
        query=""
        # cquery takes one expression: the targets as a union of them.
        for argument in "$@"; do case "$argument" in -*) options+=("$argument") ;; *) query="${query:+$query + }$argument" ;; esac; done
        bazel build --keep_going "$@" || exit
        root="$(bazel info "${options[@]}" execution_root)" || exit
        files="$(bazel cquery "${options[@]}" "$query" --output=files 2>/dev/null)" || exit
        for file in $files; do cp "$root/$file" "$out/" || exit; done
        ls -l "$out"' -- "$out" "${flags[@]}" "${@:3}")
elif [ $# -gt 0 ]; then
    command=(bazel "$1" --keep_going "${flags[@]}" "${@:2}")
else
    # The server (the Mac's command line, until it runs on Linux:
    # docs/APPLICATIONS_PLAN.md), the apps, the libraries (those that run on
    # Linux for Linux, the others in the server), then every test Linux can
    # run (the rest need a Mac: a simulator, AppKit, hdiutil).
    command=(bash -c 'bazel build --keep_going "$@" //server //app:applications_ios //app:applications_macos //libraries/... && bazel test "$@" //...' -- "${flags[@]}")
fi

# The cache's read token, for Bazel's cache and the served files: a
# client's own (~/.config/oss, as CI's user has it), else the server's
# (`oss cache token`, for OS Server's own user). Never on a command line: in
# a file only this user and that group read, which the container moves into
# its own .netrc.
token_file="${OSS_HOME:-$HOME}/.config/oss/cache-read-token"
if [ -r "$token_file" ]; then
    token="$(tr -d '\n' < "$token_file")"
else
    token="$("$OSS" cache token --read 2> /dev/null | tr -d '\n')" || token=""
fi
[ -n "$token" ] || { echo "container_build.sh: no cache read token ($token_file, or oss cache token --read as OS Server's user)" >&2; exit 1; }
(umask 027 && printf 'machine %s login bazel password %s\n' "$host" "$token" > "$box/netrc")
unset token
{
    echo '#!/bin/bash'
    echo "# The container's main process (tools/ci/container_build.sh)."
    printf 'box=%q\ncd %q || exit\n' "$box" "$ROOT"
    cat <<'EOF'
# Once: a container whose process ended may be started again.
[ -e "$box/status" ] && exec sleep infinity
install -m 600 "$box/netrc" ~/.netrc && rm -f "$box/netrc"
EOF
    printf 'echo %q >> ~/.bazelrc\n' "build --remote_cache=http://$host:7490 --noremote_upload_local_results"
    printf '%q ' "${command[@]}"
    printf '> "$box/log" 2>&1\n'
    cat <<'EOF'
echo $? > "$box/status.new" && mv "$box/status.new" "$box/status"
exec sleep infinity
EOF
} > "$box/build.sh"

lease=""
child=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
finished=""
finish() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$box/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "container_build.sh: lease $lease was not released: oss machine release $lease" >&2
    fi
    rm -f "$box/netrc" "$box/lease"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# In the background, waited for: a signal reaches the trap at once. It
# waits for a free container (--wait): the server lends a few, which the
# jobs of every repository on this Mac share (linux and ios-tests each
# take one), so a busy server is a wait, not a failure.
"$OSS" machine lease container --wait --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$volume" --command="bash $box/build.sh" --exports > "$box/lease" &
child=$!
wait "$child"
child=""
lease="$(. "$box/lease"; printf '%s' "$OSS_ID")"

# The build's log as it comes, until its status does (or the container goes).
tail -n +1 -F "$box/log" &
child=$!
checks=0
until [ -e "$box/status" ]; do
    sleep 2
    checks=$((checks + 1))
    if [ $((checks % 30)) -eq 0 ] && ! "$OSS" machine list | grep -q "^$lease .* ready "; then
        echo "container_build.sh: container $lease is no longer running" >&2
        exit 1
    fi
done
sleep 1
kill "$child" 2> /dev/null || true
child=""
status="$(cat "$box/status")"
finished=1
exit "$status"
