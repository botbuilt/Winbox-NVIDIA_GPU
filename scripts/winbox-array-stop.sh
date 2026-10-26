#!/bin/bash
# WinBox clean shutdown for the Unraid "User Scripts" plugin.
#
# Schedule: "At Stopping of Array". Unraid stops all containers with the
# Docker Stop Timeout (default 10 seconds), which is too short for Windows.
# This stops WinBox first with a long timeout, so Windows always shuts down
# cleanly when the array or server goes down.

CONTAINER="${CONTAINER:-WinBox}"
STOP_TIMEOUT="${STOP_TIMEOUT:-150}"
DOCKER="${DOCKER:-docker}"

if [[ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]; then
  echo "[winbox] Shutting down Windows in $CONTAINER (up to ${STOP_TIMEOUT}s)."
  $DOCKER stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null
fi
