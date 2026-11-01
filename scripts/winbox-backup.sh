#!/bin/bash
# WinBox backup for the Unraid "User Scripts" plugin.
#
# Shuts Windows down cleanly, copies the VM's storage folder (system disk,
# UEFI/TPM state) to a dated backup folder, starts Windows again, and keeps
# the newest KEEP backups. Schedule it weekly, at a time nobody uses Windows.
#
# Restore: stop the container, copy the files of one backup folder back into
# the storage folder, start the container.

# ---- Settings ---------------------------------------------------------------
CONTAINER="${CONTAINER:-WinBox}"
DEST="${DEST:-/mnt/user/backups/winbox}"   # where backups go (ideally the array, not the cache)
KEEP="${KEEP:-3}"                          # number of backups to keep
STOP_TIMEOUT="${STOP_TIMEOUT:-150}"        # seconds Windows gets to shut down
# -----------------------------------------------------------------------------

set -uo pipefail

DOCKER="${DOCKER:-docker}"

log() { echo "[winbox-backup] $*"; }
fail() { log "ERROR: $*"; exit 1; }

storage=$($DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination "/storage"}}{{.Source}}{{end}}{{end}}' "$CONTAINER" 2>/dev/null) \
  || fail "Container '$CONTAINER' not found."
if [ -z "$storage" ] || [ ! -d "$storage" ]; then
  fail "Could not find the /storage folder of '$CONTAINER'."
fi

running=$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER")

restart() {
  if [[ "$running" == "true" ]]; then
    log "Starting $CONTAINER again."
    $DOCKER start "$CONTAINER" >/dev/null || log "ERROR: could not start $CONTAINER, start it from the Docker tab."
  fi
}

# Whatever happens after this point, bring Windows back up.
trap restart EXIT

mkdir -p "$DEST" || fail "Cannot create $DEST."

need=$(du -sk --exclude='*.iso' --exclude=snapshots --exclude=.nvcache "$storage" | awk '{print $1}')
free=$(df -Pk "$DEST" | awk 'NR==2 {print $4}')
if (( need > free )); then
  fail "Not enough space in $DEST: need $((need / 1024 / 1024)) GB, have $((free / 1024 / 1024)) GB."
fi

if [[ "$running" == "true" ]]; then
  log "Shutting down Windows in $CONTAINER (up to ${STOP_TIMEOUT}s)."
  $DOCKER stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null || fail "Could not stop $CONTAINER."
fi

target="$DEST/$(date +%Y%m%d-%H%M%S)"
partial="$target.partial"
log "Copying $storage to $target."

# Sparse copy keeps the empty parts of the disk image empty; reflink makes it
# near-instant when source and destination are on the same btrfs/xfs pool.
mkdir -p "$partial" || fail "Cannot create $partial."
if ! find "$storage" -mindepth 1 -maxdepth 1 ! -name '*.iso' ! -name snapshots ! -name .nvcache \
       -exec cp -a --sparse=always --reflink=auto {} "$partial/" \; ; then
  rm -rf "$partial"
  fail "Copy failed, nothing was kept."
fi
mv "$partial" "$target" || fail "Could not finalize $target."

# Start Windows before pruning, so the downtime is only the copy.
trap - EXIT
restart

log "Backup done: $target ($(du -sh "$target" | awk '{print $1}') on disk)."

# Prune: keep the newest KEEP finished backups.
mapfile -t old < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' | sort -r | tail -n +"$((KEEP + 1))")
for dir in "${old[@]}"; do
  log "Removing old backup $dir."
  rm -rf "$dir"
done
