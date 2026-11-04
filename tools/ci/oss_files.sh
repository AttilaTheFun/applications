# Sourced by tools/ci/container_build.sh and tools/ci/mac_vm_tests.sh: where
# Bazel takes Xcode 27.2's SDK archive and rules_applecross's ported tools
# from, OS Server's files (by SHA-256, with its cache's read token in
# .netrc), through a downloader config for MODULE.bazel's placeholders. No
# host is named in the repository.

# Xcode 27.2's SDK archive.
SDK_SHA256="b1583e60f9fd35881b5a948ce71627079877f1ced7ea231e14d3c342dd389668"

# The OS Server whose files and cache a build reads: OSS_FILES_HOST, else
# the first of OSS_SERVERS (an OS Server job's environment has it).
oss_files_host() {
    local host="${OSS_FILES_HOST:-}"
    if [ -z "$host" ]; then
        host="${OSS_SERVERS:-}"
        host="${host%%[ ,]*}"
        host="${host#*://}"
        host="${host%%[:/]*}"
    fi
    [ -n "$host" ] || { echo "$(basename "$0"): no host for OS Server's files: set OSS_FILES_HOST (or OSS_SERVERS)" >&2; return 1; }
    printf '%s\n' "$host"
}

# write_downloader_config <file> <host>
write_downloader_config() {
    cat > "$1" << EOF
rewrite apple-sdks\.invalid/.* http://$2:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$2:7490/files/sha256/\$1
EOF
}
