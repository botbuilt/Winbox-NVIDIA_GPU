#!/bin/bash
#argumentDescription=create [label] | list | restore NAME | delete NAME
#argumentDefault=create
# WinBox snapshots for the Unraid "User Scripts" plugin (or the terminal).
#
#   winbox-snapshot.sh create [label]   shut Windows down, snapshot, start it
#   winbox-snapshot.sh list             show snapshots and their size
#   winbox-snapshot.sh restore NAME     roll Windows back to a snapshot
#   winbox-snapshot.sh delete NAME      remove a snapshot
#
# A snapshot is a copy-on-write copy of the storage folder (system disk,
# UEFI and TPM state) in <storage>/snapshots. On a btrfs, xfs or zfs pool it
# is instant and only takes space as Windows changes afterwards. Elsewhere it
# falls back to a full (sparse) copy.
#
# Windows is shut down for the snapshot, so it is always consistent. Restore
# first moves the current state into a "before-restore" snapshot, so a
# restore can itself be undone.

# ---- Settings ---------------------------------------------------------------
CONTAINER="${CONTAINER:-WinBox}"
STOP_TIMEOUT="${STOP_TIMEOUT:-150}"        # seconds Windows gets to shut down
KEEP="${KEEP:-0}"                          # keep only the newest KEEP snapshots, 0 = keep all
# -----------------------------------------------------------------------------

set -uo pipefail

DOCKER="${DOCKER:-docker}"

log() { echo "[winbox-snapshot] $*"; }
fail() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n 's/^#   //p' "$0"
  exit 1
}

storage=$($DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination "/storage"}}{{.Source}}{{end}}{{end}}' "$CONTAINER" 2>/dev/null) \
  || fail "Container '$CONTAINER' not found."
if [ -z "$storage" ] || [ ! -d "$storage" ]; then
  fail "Could not find the /storage folder of '$CONTAINER'."
fi

SNAPS="$storage/snapshots"
running=$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER")

# The VM state: everything in the storage folder except ISOs and snapshots.
stateItems() {
  find "$1" -mindepth 1 -maxdepth 1 ! -name '*.iso' ! -name snapshots ! -name '*.partial'
}

# Copy-on-write when the filesystem can, else a sparse full copy.
copyItems() {
  local from="$1" to="$2"
  stateItems "$from" | while IFS= read -r item; do
    cp -a --reflink=auto --sparse=always "$item" "$to/" || exit 1
  done
}

reflinkWorks() {
  local probe="$SNAPS/.reflink-probe"
  echo probe > "$probe" || return 1
  cp --reflink=always "$probe" "$probe.copy" 2>/dev/null
  local rc=$?
  rm -f "$probe" "$probe.copy"
  return $rc
}

checkName() {
  [ -n "${1:-}" ] || usage
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != .* ]] || fail "Invalid snapshot name '$1'."
  [ -d "$SNAPS/$1" ] || fail "No snapshot named '$1'. Run 'list' to see them."
}

restart() {
  if [[ "$running" == "true" ]]; then
    log "Starting $CONTAINER again."
    $DOCKER start "$CONTAINER" >/dev/null || log "ERROR: could not start $CONTAINER, start it from the Docker tab."
  fi
}

stopWindows() {
  # Whatever happens after this point, bring Windows back up.
  trap restart EXIT
  if [[ "$running" == "true" ]]; then
    log "Shutting down Windows in $CONTAINER (up to ${STOP_TIMEOUT}s)."
    $DOCKER stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null || fail "Could not stop $CONTAINER."
  fi
}

startWindows() {
  trap - EXIT
  restart
}

# Space a full copy would need, when copy-on-write is not available.
checkSpace() {
  local need free
  need=$(stateItems "$1" | xargs -r -d '\n' du -sck 2>/dev/null | tail -n 1 | cut -f1)
  free=$(df -Pk "$SNAPS" | awk 'NR==2 {print $4}')
  if (( ${need:-0} > free )); then
    fail "Not enough space for a full copy: need $((need / 1024 / 1024)) GB, have $((free / 1024 / 1024)) GB."
  fi
}

create() {
  local label="${1:-}" name partial

  if [ -n "$label" ] && [[ ! "$label" =~ ^[A-Za-z0-9_-]+$ ]]; then
    fail "Labels may only contain letters, digits, - and _."
  fi
  name="$(date +%Y%m%d-%H%M%S)${label:+-$label}"
  partial="$SNAPS/$name.partial"

  mkdir -p "$SNAPS" || fail "Cannot create $SNAPS."
  if reflinkWorks; then
    log "The pool supports copy-on-write: the snapshot is instant."
  else
    log "The pool does not support copy-on-write (use btrfs, xfs or zfs for instant snapshots): making a full copy."
    checkSpace "$storage"
  fi

  stopWindows

  mkdir "$partial" || fail "Cannot create $partial."
  if ! copyItems "$storage" "$partial"; then
    rm -rf "$partial"
    fail "Copy failed, nothing was kept."
  fi
  mv "$partial" "$SNAPS/$name" || fail "Could not finalize $name."

  startWindows
  log "Snapshot created: $name"

  prune
}

prune() {
  (( KEEP > 0 )) || return 0
  local old dir
  mapfile -t old < <(find "$SNAPS" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -printf '%f\n' | sort -r | tail -n +"$((KEEP + 1))")
  for dir in "${old[@]}"; do
    log "Removing old snapshot $dir."
    rm -rf "${SNAPS:?}/$dir"
  done
}

list() {
  local dir
  if [ ! -d "$SNAPS" ] || [ -z "$(find "$SNAPS" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial')" ]; then
    log "No snapshots yet. Create one with: $0 create [label]"
    return 0
  fi
  printf '%-40s %s\n' "NAME" "SPACE USED"
  find "$SNAPS" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -printf '%f\n' | sort | while IFS= read -r dir; do
    # On copy-on-write pools shared blocks are counted in full here.
    printf '%-40s %s\n' "$dir" "$(du -sh "$SNAPS/$dir" | cut -f1)"
  done
}

restore() {
  local name="$1" undo item

  checkName "$name"
  undo="$(date +%Y%m%d-%H%M%S)-before-restore"

  stopWindows

  # Moving within the same folder is instant and keeps the current state.
  # If anything goes wrong mid-way, don't start Windows on a half-restored
  # folder: with no disk image upstream would begin a fresh install.
  mkdir "$SNAPS/$undo" || fail "Cannot create $SNAPS/$undo."
  while IFS= read -r item; do
    if ! mv "$item" "$SNAPS/$undo/"; then
      trap - EXIT
      fail "Could not move $item aside. The current state is partly in $SNAPS/$undo; move it back before starting $CONTAINER."
    fi
  done < <(stateItems "$storage")

  if ! copyItems "$SNAPS/$name" "$storage"; then
    log "ERROR: restoring $name failed, putting the previous state back."
    stateItems "$storage" | xargs -r -d '\n' rm -rf
    while IFS= read -r item; do
      if ! mv "$item" "$storage/"; then
        trap - EXIT
        fail "Could not put $item back. Move the files in $SNAPS/$undo back to $storage before starting $CONTAINER."
      fi
    done < <(stateItems "$SNAPS/$undo")
    rmdir "$SNAPS/$undo"
    exit 1
  fi

  startWindows
  log "Restored $name. The previous state was saved as snapshot $undo."
}

delete() {
  checkName "$1"
  rm -rf "${SNAPS:?}/$1" || fail "Could not delete $1."
  log "Deleted snapshot $1."
}

# User Scripts passes its arguments as one string.
if (( $# == 1 )); then
  read -r -a args <<< "$1"
  set -- "${args[@]}"
fi

case "${1:-}" in
  create) create "${2:-}" ;;
  list) list ;;
  restore) restore "${2:-}" ;;
  delete) delete "${2:-}" ;;
  *) usage ;;
esac
