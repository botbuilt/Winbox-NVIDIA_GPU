#!/usr/bin/env bash
# Tests the healthcheck with a fake /run/shm and a local web server.
# Usage: bash tests/test_health.sh
set -uo pipefail

HEALTH="$(cd "$(dirname "$0")/.." && pwd)/src/health.sh"
FAKE="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))

python3 - "$PORT" <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401 if self.path == "/auth/" else 200)
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$FAKE"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

PASS=0
FAIL=0

# check <name> <expected exit> [env...]
check() {
  local name="$1" want="$2" rc
  shift 2
  env HEALTH_SHM="$FAKE" HEALTH_WEB_URL="http://127.0.0.1:$PORT/" "$@" bash "$HEALTH" >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq $want ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name (exit $rc, wanted $want)"
  fi
}

check "before QEMU starts, web up" 0
check "password-protected console counts as up" 0 HEALTH_WEB_URL="http://127.0.0.1:$PORT/auth/"
check "web console down" 1 HEALTH_WEB_URL="http://127.0.0.1:1/"
check "web disabled skips the web check" 0 WEB=N HEALTH_WEB_URL="http://127.0.0.1:1/"

sleep 300 & alive=$!
echo "$alive" > "$FAKE/qemu.pid"
check "running QEMU" 0

kill "$alive"; wait "$alive" 2>/dev/null
check "dead QEMU" 1

touch "$FAKE/qemu.end"
check "shutting down" 1

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
