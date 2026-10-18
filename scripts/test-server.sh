#!/usr/bin/env bash
# DarkRoom test server helper. The test host is read from TestServer/.secrets/ssh-host (untracked).
#   scripts/test-server.sh tunnel   # forward http://localhost:2283 -> test server (background)
#   scripts/test-server.sh status   # tunnel + server version
#   scripts/test-server.sh close    # stop the tunnel
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
host="$(cat "$root/TestServer/.secrets/ssh-host" 2>/dev/null || true)"
[[ -n "$host" ]] || { echo "Missing TestServer/.secrets/ssh-host" >&2; exit 1; }
port="${DARKROOM_TEST_PORT:-2283}"
case "${1:-status}" in
  tunnel)
    if curl -s -m 2 "http://localhost:$port/api/server/ping" >/dev/null; then echo "tunnel already up on :$port"; exit 0; fi
    ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L "$port:127.0.0.1:2284" "$host"
    sleep 1; curl -s "http://localhost:$port/api/server/version"; echo ;;
  status)
    curl -s -m 3 "http://localhost:$port/api/server/version" && echo || echo "tunnel down" ;;
  close)
    pkill -f "ssh -f -N .*-L $port:127.0.0.1:2284" && echo "closed" || echo "not running" ;;
  *) echo "usage: $0 tunnel|status|close" >&2; exit 2 ;;
esac
