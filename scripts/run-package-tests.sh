#!/bin/zsh
# Runs DarkRoomKit's unit and integration tests. Integration suites share one test server and
# temporarily change seeded photos, so they run one at a time.
set -euo pipefail
cd "$(dirname "$0")/../Packages/DarkRoomKit"
swift test --no-parallel "$@"
