#!/bin/bash
# Builds Applications for the Mac, its Alpha (the default build; Production
# is CI's release job's, docs/VARIANTS.md), and signs it
# with the builder's own team (the team in .bazelrc.user, PIPELINE_TEAM_ID:
# its "Developer ID Application" certificate if the keychain has one, else
# its "Apple Development" one) — then publishes it to Applications Server,
# as a beta, with the notes given; Applications for the Mac installs builds
# signed by its own team.
#
# Notarized and stapled when a notarytool keychain profile is named
# (APPLICATIONS_NOTARY_PROFILE; APPLICATIONS_NOTARY_KEYCHAIN when it is in
# a keychain of its own, unlocked with the password in the file
# APPLICATIONS_NOTARY_KEYCHAIN_PASSWORD_FILE), so Gatekeeper takes it
# however it arrives; without one it is said so, and the build is only signed.
#
#   tools/install_mac_app.sh --publish <notes.md>
#   tools/install_mac_app.sh --zip <out.zip>
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="$(sed -n 's/.*PIPELINE_TEAM_ID=\([A-Z0-9]*\).*/\1/p' .bazelrc.user 2>/dev/null | head -1)"
[ -n "$TEAM" ] || { echo "No PIPELINE_TEAM_ID in .bazelrc.user" >&2; exit 1; }
IDENTITY="$(python3 - "$TEAM" <<'PY'
import re, subprocess, sys
team = sys.argv[1]
listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
found = {}
for sha, name in re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', listing):
    pem = subprocess.run(["security", "find-certificate", "-a", "-Z", "-p", "-c", name], capture_output=True, text=True).stdout
    for block in pem.split("SHA-1 hash: ")[1:]:
        if not block.startswith(sha):
            continue
        cert = block[block.index("-----BEGIN"):]
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=cert, capture_output=True, text=True).stdout
        if f"OU={team}" in subject.replace(" ", ""):
            kind = "developer-id" if name.startswith("Developer ID Application") else "development" if name.startswith("Apple Development") else None
            if kind:
                found.setdefault(kind, sha)
print(found.get("developer-id") or found.get("development") or "")
PY
)"
[ -n "$IDENTITY" ] || { echo "No signing identity for the team in the keychain (Xcode → Settings → Accounts)" >&2; exit 1; }
bazel build -c opt //app:applications_macos
ZIP="$(bazel cquery -c opt --output=files //app:applications_macos 2>/dev/null | head -1)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
APP="$WORK/Applications.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
if [ -n "${APPLICATIONS_NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$APPLICATIONS_NOTARY_PROFILE")
  if [ -n "${APPLICATIONS_NOTARY_KEYCHAIN:-}" ]; then
    if [ -n "${APPLICATIONS_NOTARY_KEYCHAIN_PASSWORD_FILE:-}" ]; then
      printf 'unlock-keychain -p "%s" "%s"\n' "$(cat "$APPLICATIONS_NOTARY_KEYCHAIN_PASSWORD_FILE")" "$APPLICATIONS_NOTARY_KEYCHAIN" | security -i >/dev/null
    fi
    NOTARY+=(--keychain "$APPLICATIONS_NOTARY_KEYCHAIN")
  fi
  echo "Applications: notarizing…"
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" "${NOTARY[@]}" --wait --output-format json >"$WORK/notary.json"
  grep -q '"status" *: *"Accepted"' "$WORK/notary.json" || { cat "$WORK/notary.json" >&2; exit 1; }
  xcrun stapler staple -q "$APP"
  spctl --assess --type execute "$APP"
else
  echo "Applications: signed, not notarized (no APPLICATIONS_NOTARY_PROFILE)" >&2
fi
ditto -c -k --keepParent "$APP" "$WORK/Applications-mac.zip"
case "${1:-}" in
  --publish) "${APPLICATIONS_SERVER:-applications-server}" publish "$WORK/Applications-mac.zip" --notes-file "${2:?--publish takes the release notes file}" ;;
  --zip) cp "$WORK/Applications-mac.zip" "${2:?--zip takes where to put it}"; echo "Applications for the Mac: $2" ;;
  *) echo "tools/install_mac_app.sh --publish <notes.md> | --zip <out.zip>" >&2; exit 64 ;;
esac
