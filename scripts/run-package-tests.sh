#!/bin/zsh
# Runs DarkRoomKit's unit tests.
set -euo pipefail
cd "$(dirname "$0")/../Packages/DarkRoomKit"
swift test --no-parallel "$@"
