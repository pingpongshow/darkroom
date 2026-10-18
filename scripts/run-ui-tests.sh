#!/usr/bin/env bash
# Runs DarkRoom's UI tests against the test server without touching protected folders
# (Desktop/Documents), so macOS never shows file-access prompts for the test runner.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${DARKROOM_DERIVED_DATA:-$HOME/Library/Caches/DarkRoom/DerivedData}"
creds_tmp="$(mktemp -d "${TMPDIR:-/tmp}/darkroom-uitest.XXXXXX")/credentials.json"
trap 'rm -rf "$(dirname "$creds_tmp")"' EXIT
install -m 600 "$root/TestServer/.secrets/credentials.json" "$creds_tmp"
"$root/scripts/test-server.sh" tunnel >/dev/null
cd "$root"
TEST_RUNNER_DARKROOM_TEST_CREDENTIALS="$creds_tmp" \
  xcodebuild -project DarkRoom.xcodeproj -scheme DarkRoom -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" test "$@"
