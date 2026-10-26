#!/usr/bin/env bash
# Tests the User Scripts helpers with a fake docker command.
# Usage: bash tests/test_scripts.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

PASS=0
FAIL=0

ok() {
  if eval "$2"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    [ -f "$FAKE/out" ] && sed 's/^/  /' "$FAKE/out"
  fi
}

# Fake docker: answers inspect from env, records stop/start in calls.log.
cat > "$FAKE/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/calls.log"
case "$1" in
  inspect)
    [[ "$FAKE_EXISTS" == "N" ]] && exit 1
    case "$3" in
      *Mounts*) echo "$FAKE_STORAGE" ;;
      *Running*) echo "$FAKE_RUNNING" ;;
    esac ;;
  stop|start) exit "${FAKE_FAIL_STOP:-0}" ;;
esac
EOF
chmod +x "$FAKE/docker"

reset() {
  rm -rf "$FAKE/storage" "$FAKE/backups" "$FAKE/calls.log"
  mkdir -p "$FAKE/storage"
  truncate -s 64M "$FAKE/storage/data.img"          # sparse, like a real vdisk
  echo vars > "$FAKE/storage/windows.vars"
  echo iso > "$FAKE/storage/win11x64.iso"
}

backup() {
  env DOCKER="$FAKE/docker" FAKE_DIR="$FAKE" FAKE_STORAGE="$FAKE/storage" \
      DEST="$FAKE/backups" "$@" bash "$ROOT/scripts/winbox-backup.sh" > "$FAKE/out" 2>&1
}

# Running container: stop, copy, start.
reset
backup FAKE_RUNNING=true KEEP=2; rc=$?
ok "backup succeeds" "[[ $rc -eq 0 ]]"
dir=$(find "$FAKE/backups" -mindepth 1 -maxdepth 1 -type d | head -1)
ok "disk image copied" "[ -f '$dir/data.img' ]"
ok "vars copied" "[ -f '$dir/windows.vars' ]"
ok "iso skipped" "[ ! -e '$dir/win11x64.iso' ]"
ok "copy stays sparse" "[ \$(du -k '$dir/data.img' | cut -f1) -lt 1024 ]"
ok "stopped with long timeout" "grep -q '^stop -t 150 WinBox' '$FAKE/calls.log'"
ok "started again" "grep -q '^start WinBox' '$FAKE/calls.log'"
ok "stop happens before start" "[[ \$(grep -n '^stop' '$FAKE/calls.log' | cut -d: -f1) -lt \$(grep -n '^start' '$FAKE/calls.log' | cut -d: -f1) ]]"

# Stopped container stays stopped.
reset
backup FAKE_RUNNING=false
ok "stopped container is not started" "! grep -q '^start' '$FAKE/calls.log'"
ok "stopped container is not stopped" "! grep -q '^stop' '$FAKE/calls.log'"

# Pruning keeps the newest KEEP backups.
reset
mkdir -p "$FAKE/backups/20200101-000000" "$FAKE/backups/20210101-000000" "$FAKE/backups/20220101-000000" "$FAKE/backups/keep-me"
backup FAKE_RUNNING=false KEEP=2
ok "oldest backups pruned" "[ ! -d '$FAKE/backups/20200101-000000' ] && [ ! -d '$FAKE/backups/20210101-000000' ]"
ok "newest old backup kept" "[ -d '$FAKE/backups/20220101-000000' ]"
ok "foreign folders untouched" "[ -d '$FAKE/backups/keep-me' ]"

# A failed stop still restarts nothing broken and reports an error.
reset
backup FAKE_RUNNING=true FAKE_FAIL_STOP=1; rc=$?
ok "failed stop is an error" "[[ $rc -ne 0 ]] && grep -q 'Could not stop' '$FAKE/out'"
ok "no partial backup left" "[ -z \"\$(find '$FAKE/backups' -mindepth 1 2>/dev/null)\" ]"

# Missing container.
reset
backup FAKE_EXISTS=N; rc=$?
ok "missing container is an error" "[[ $rc -ne 0 ]] && grep -q 'not found' '$FAKE/out'"

# Array stop script.
rm -f "$FAKE/calls.log"
env DOCKER="$FAKE/docker" FAKE_DIR="$FAKE" FAKE_RUNNING=true bash "$ROOT/scripts/winbox-array-stop.sh" > "$FAKE/out" 2>&1
ok "array stop uses long timeout" "grep -q '^stop -t 150 WinBox' '$FAKE/calls.log'"
rm -f "$FAKE/calls.log"
env DOCKER="$FAKE/docker" FAKE_DIR="$FAKE" FAKE_RUNNING=false bash "$ROOT/scripts/winbox-array-stop.sh" > "$FAKE/out" 2>&1
ok "array stop skips a stopped container" "! grep -q '^stop' '$FAKE/calls.log'"

# Backups leave snapshots out.
reset
mkdir -p "$FAKE/storage/snapshots/20240101-000000"
backup FAKE_RUNNING=false
dir=$(find "$FAKE/backups" -mindepth 1 -maxdepth 1 -type d | head -1)
ok "backup skips snapshots" "[ ! -e '$dir/snapshots' ] && [ -f '$dir/data.img' ]"

# Snapshots.
snap() {
  env DOCKER="$FAKE/docker" FAKE_DIR="$FAKE" FAKE_STORAGE="$FAKE/storage" "${SNAPENV[@]}" \
      bash "$ROOT/scripts/winbox-snapshot.sh" "$@" > "$FAKE/out" 2>&1
}
S="$FAKE/storage/snapshots"

reset
SNAPENV=(FAKE_RUNNING=true)
snap create before-update; rc=$?
name=$(find "$S" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)
ok "snapshot succeeds" "[[ $rc -eq 0 ]]"
ok "snapshot is named with the label" "[[ '$name' == *-before-update ]]"
ok "snapshot has the disk and vars" "[ -f '$S/$name/data.img' ] && [ -f '$S/$name/windows.vars' ]"
ok "snapshot skips the iso" "[ ! -e '$S/$name/win11x64.iso' ]"
ok "snapshot stops then starts" "grep -q '^stop -t 150 WinBox' '$FAKE/calls.log' && grep -q '^start WinBox' '$FAKE/calls.log'"

snap list
ok "list shows the snapshot" "grep -q '$name' '$FAKE/out'"

# User Scripts passes all arguments as one string.
snap "list"
ok "single-string arguments work" "grep -q '$name' '$FAKE/out'"

# Restore rolls back and keeps the replaced state.
echo changed > "$FAKE/storage/windows.vars"
echo new > "$FAKE/storage/extra.img"
rm -f "$FAKE/calls.log"
snap restore "$name"; rc=$?
ok "restore succeeds" "[[ $rc -eq 0 ]]"
ok "restore brings back the old vars" "[[ \$(cat '$FAKE/storage/windows.vars') == vars ]]"
ok "restore removes files made after the snapshot" "[ ! -e '$FAKE/storage/extra.img' ]"
ok "restore keeps the iso" "[ -f '$FAKE/storage/win11x64.iso' ]"
undo=$(find "$S" -mindepth 1 -maxdepth 1 -type d -name '*-before-restore' -printf '%f\n' | head -1)
ok "restore saves the previous state" "[ -n '$undo' ] && [[ \$(cat '$S/$undo/windows.vars') == changed ]]"
ok "restore restarts Windows" "grep -q '^start WinBox' '$FAKE/calls.log'"
ok "the snapshot itself is untouched" "[ -f '$S/$name/data.img' ]"

snap restore nope; rc=$?
ok "unknown snapshot is an error" "[[ $rc -ne 0 ]] && grep -q 'No snapshot named' '$FAKE/out'"
snap restore ../storage; rc=$?
ok "path names are refused" "[[ $rc -ne 0 ]]"
snap create 'bad label'; rc=$?
ok "bad label is refused" "[[ $rc -ne 0 ]]"

snap delete "$undo"; rc=$?
ok "delete removes a snapshot" "[[ $rc -eq 0 ]] && [ ! -d '$S/$undo' ]"

# KEEP prunes the oldest.
mkdir -p "$S/20000101-000000" "$S/20000102-000000"
SNAPENV=(FAKE_RUNNING=false KEEP=2)
snap create
ok "KEEP prunes the oldest snapshots" "[ ! -d '$S/20000101-000000' ] && [ ! -d '$S/20000102-000000' ] && [ -d '$S/$name' ]"
SNAPENV=(FAKE_RUNNING=false)

snap; rc=$?
ok "no command prints usage" "[[ $rc -ne 0 ]] && grep -q 'restore NAME' '$FAKE/out'"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
