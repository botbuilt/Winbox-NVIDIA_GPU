#!/usr/bin/env bash
set -Eeuo pipefail

# Container healthcheck: is the VM process alive and the web console serving?
#
# Upstream's /run/check.sh is not used: it probes the guest on port 80, which
# Windows doesn't listen on, so a working VM would be reported as unhealthy.
# The guest itself isn't probed here either, because Windows can be busy for
# a long time installing or updating while everything is fine.

SHM="${HEALTH_SHM:-/run/shm}"
WEB_URL="${HEALTH_WEB_URL:-http://127.0.0.1:${WEB_PORT:-8006}/}"

if [ -f "$SHM/qemu.end" ]; then
  echo "QEMU is shutting down."
  exit 1
fi

# Before QEMU starts, Windows is still being downloaded or prepared.
if [ -s "$SHM/qemu.pid" ]; then
  pid=$(<"$SHM/qemu.pid")
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "QEMU (pid $pid) is no longer running."
    exit 1
  fi
fi

if [[ "${WEB:-Y}" =~ ^[Yy] ]]; then
  # 401 is fine: the console is up and asks for the password (PROTECT=Y).
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$WEB_URL" || echo "000")
  if [[ "$code" != "200" && "$code" != "401" ]]; then
    echo "Web console is not responding (HTTP $code)."
    exit 1
  fi
fi

echo "Healthy."
exit 0
