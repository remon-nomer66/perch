#!/usr/bin/env bash
# Coordinates exclusive access to the single RFCOMM control session.
# Perch, perch-probe (Sony/Tandem), and bose-probe (Bose/BMAP) share this lock.
# Never put addresses or other personal data in the owner, note, lock or log.
#
# Usage:
#   control-lock.sh status
#   control-lock.sh acquire <owner> <app|probe> [note]
#   control-lock.sh release <owner> [force]
#   control-lock.sh app-start <owner> [note]
#   control-lock.sh app-stop <owner> [force]
#   control-lock.sh probe <owner> <address> <outfile> [note]
#   control-lock.sh bose-probe <owner> <outfile> [probe args...]
#     All remaining arguments are forwarded unchanged to bose-probe.
#
# A reservation survives between launches. Even the same owner must release it
# before acquiring again. Use force deliberately, after coordinating with its owner.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/.control-session.lock"
GATE="$LOCK.gate"
LOG="$ROOT/.control-session.log"
APP="$ROOT/.build/Perch.app"
PROBE="$ROOT/.build/debug/perch-probe"
BOSE_PROBE="$ROOT/.build/debug/bose-probe"
APP_PATTERN='.build/Perch.app/Contents/MacOS/Perch'
PROBE_PATTERN='perch-probe'
# Match the binary, not the bare subcommand in this wrapper's command line.
BOSE_PROBE_PATTERN='(^|/)bose-probe([[:space:]]|$)'
TOKEN="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
GATE_KEY="$$.$TOKEN"
GATE_DEPTH=0
DEFER_SIGNAL=0
PENDING_SIGNAL=0
CHILD_PID=""
CLEANUP_OWNER=""
CLEANUP_TOKEN=""
LOCK_TMP="$LOCK.tmp.$TOKEN"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
field() { [ -f "$LOCK" ] && sed -n "s/^$1=//p" "$LOCK" || true; }
log() { printf '%s %s\n' "$(now)" "$*" >> "$LOG"; }
single_line() { [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }
reservation_exists() { [ -e "$LOCK" ] || [ -L "$LOCK" ]; }

# Process detection also protects clients launched without this wrapper.
control_pids() {
  local result rc
  if result="$(pgrep -f "$1" 2>/dev/null)"; then
    printf '%s\n' "$result"
  else
    rc=$?
    [ "$rc" -eq 1 ] || echo unknown
  fi
}

holders() {
  {
    control_pids "$APP_PATTERN"
    control_pids "$PROBE_PATTERN"
    control_pids "$BOSE_PROBE_PATTERN"
  } | tr '\n' ' '
}

# A failed kill -0 may mean permission denied. Only ESRCH proves abandonment.
pid_is_dead() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  local result
  if result="$(LC_ALL=C kill -0 "$1" 2>&1)"; then return 1; fi
  [[ "$result" == *'No such process'* ]]
}

leave_gate() {
  [ "$GATE_DEPTH" -gt 0 ] || return 0
  GATE_DEPTH=$((GATE_DEPTH - 1))
  [ "$GATE_DEPTH" -eq 0 ] || return 0
  # Never unlink a generic marker: a later invocation has a different key.
  rmdir "$GATE/$GATE_KEY" 2>/dev/null || true
  rmdir "$GATE" 2>/dev/null || true
}

enter_gate() { # [force]
  if [ "$GATE_DEPTH" -gt 0 ]; then
    [ -d "$GATE/$GATE_KEY" ] || return 1
    GATE_DEPTH=$((GATE_DEPTH + 1))
    return 0
  fi
  local tries=0 marker pid entered
  while [ "$tries" -lt 50 ]; do
    # Defer signals across mkdir + ownership registration. EXIT can always clean
    # our exact marker, and no other invocation may recover a live PID.
    DEFER_SIGNAL=1
    entered=0
    if mkdir "$GATE" 2>/dev/null; then
      if mkdir "$GATE/$GATE_KEY" 2>/dev/null; then
        GATE_DEPTH=1
        # A competing force recovery may remove an empty, initializing gate.
        # Only a sole registered owner can enter the critical section.
        if [ "$(ls -A "$GATE" 2>/dev/null)" = "$GATE_KEY" ]; then
          entered=1
        else
          leave_gate
        fi
      else
        rmdir "$GATE" 2>/dev/null || true
      fi
    fi
    DEFER_SIGNAL=0
    [ "$PENDING_SIGNAL" -eq 0 ] || exit "$PENDING_SIGNAL"
    [ "$entered" -eq 0 ] || return 0

    if [ "${1:-}" = force ]; then
      marker="$(ls -A "$GATE" 2>/dev/null || true)"
      if [[ "$marker" =~ ^[1-9][0-9]*\.[0-9a-f]{32}$ ]] && [ -d "$GATE/$marker" ]; then
        pid="${marker%%.*}"
        if pid_is_dead "$pid"; then
          # Exact-key rmdir cannot remove a concurrent successor's marker.
          rmdir "$GATE/$marker" 2>/dev/null || true
          rmdir "$GATE" 2>/dev/null || true
        fi
      fi
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  echo 'BUSY: mutation gate held or unverifiable; coordinate before force recovery' >&2
  return 1
}

write_lock() { # owner role pid note token state [acquiredAt] [operationPid]
  {
    printf 'owner=%s\nrole=%s\npid=%s\n' "$1" "$2" "$3"
    printf 'acquiredAt=%s\nnote=%s\n' "${7:-$(now)}" "$4"
    printf 'token=%s\nstate=%s\noperationPid=%s\n' "$5" "$6" "${8:-0}"
  } > "$LOCK_TMP" || return 1
  mv -f "$LOCK_TMP" "$LOCK"
}

valid_reservation() {
  [ -f "$LOCK" ] || return 1
  [ "$(wc -l < "$LOCK" | tr -d ' ')" = 8 ] || return 1
  single_line "$(field owner)" || return 1
  [[ "$(field acquiredAt)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [ "$(sed -n 's/^note=.*/present/p' "$LOCK")" = present ] || return 1
  [[ "$(field token)" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "$(field pid)" =~ ^[0-9]+$ ]] || return 1
  [[ "$(field operationPid)" =~ ^[0-9]+$ ]] || return 1
  case "$(field role)" in app|probe) ;; *) return 1;; esac
  case "$(field state)" in reserved|launching|running|stopping) ;; *) return 1;; esac
}

# Pre-token reservations may still protect a client after the script is updated.
# Only an explicit forced stop upgrades one; incomplete files never authorize quit.
valid_legacy_reservation() {
  [ -f "$LOCK" ] || return 1
  [ "$(wc -l < "$LOCK" | tr -d ' ')" = 5 ] || return 1
  single_line "$(field owner)" || return 1
  [[ "$(field pid)" =~ ^[0-9]+$ ]] || return 1
  [[ "$(field acquiredAt)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  case "$(field role)" in app|probe) ;; *) return 1;; esac
  [ "$(sed -n 's/^note=.*/present/p' "$LOCK")" = present ] || return 1
}

matches() {
  valid_reservation && [ "$(field owner)" = "$1" ] && [ "$(field token)" = "$2" ]
}

stop_is_active() {
  valid_reservation && [ "$(field state)" = stopping ] && ! pid_is_dead "$(field operationPid)"
}

acquire() { # owner role note
  single_line "$1" || { echo 'invalid owner' >&2; return 1; }
  case "$2" in app|probe) ;; *) echo 'invalid role' >&2; return 1;; esac
  [[ "${3:-}" != *$'\n'* && "${3:-}" != *$'\r'* ]] || return 1
  enter_gate || return 1
  if reservation_exists || [ -n "$(holders)" ]; then
    echo 'BUSY: a reservation or control process already exists; stop and release it first' >&2
    leave_gate
    return 1
  fi
  if ! write_lock "$1" "$2" 0 "${3:-}" "$TOKEN" reserved; then leave_gate; return 1; fi
  log "ACQUIRE owner=$1 role=$2 note=${3:-}"
  leave_gate
}

release() { # owner [force]
  single_line "$1" || return 1
  enter_gate "${2:-}" || return 1
  if ! reservation_exists; then leave_gate; echo 'already free'; return 0; fi
  if { { ! valid_reservation && ! valid_legacy_reservation; } || [ "$(field owner)" != "$1" ]; } && [ "${2:-}" != force ]; then
    echo 'REFUSED: reservation is malformed or belongs to another owner; coordinate before force recovery' >&2
    leave_gate
    return 1
  fi
  if stop_is_active || [ -n "$(holders)" ]; then
    echo 'REFUSED: a stop operation or control process is still running' >&2
    leave_gate
    return 1
  fi
  if [ "$(field state)" = launching ] && [ "${2:-}" != force ]; then
    echo 'REFUSED: launch completion is unknown; coordinate before force recovery' >&2
    leave_gate
    return 1
  fi
  rm -f "$LOCK"
  log "RELEASE owner=$1"
  leave_gate
  echo released
}

cleanup_reservation() { # owner token; never releases a replacement or active stop
  enter_gate || return 1
  if matches "$1" "$2" && [[ "$(field state)" =~ ^(reserved|running)$ ]] && [ -z "$(holders)" ]; then
    rm -f "$LOCK"
    log "AUTORELEASE owner=$1"
  fi
  leave_gate
}

stop_child() {
  [ -n "$CHILD_PID" ] || return 0
  kill -TERM "$CHILD_PID" 2>/dev/null || true
  local tries=0
  while kill -0 "$CHILD_PID" 2>/dev/null && [ "$tries" -lt 10 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ "$tries" -ge 10 ]; then kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
}

run_bounded() { # number of 0.1s checks, command...
  local limit="$1" tries=0 rc
  shift
  DEFER_SIGNAL=1
  "$@" &
  CHILD_PID=$!
  DEFER_SIGNAL=0
  [ "$PENDING_SIGNAL" -eq 0 ] || exit "$PENDING_SIGNAL"
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if [ "$tries" -ge "$limit" ]; then stop_child; return 124; fi
    sleep 0.1
    tries=$((tries + 1))
  done
  if wait "$CHILD_PID"; then rc=0; else rc=$?; fi
  CHILD_PID=""
  return "$rc"
}

interrupted() {
  if [ "$DEFER_SIGNAL" -eq 1 ]; then PENDING_SIGNAL="$1"; else exit "$1"; fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  trap '' INT TERM
  stop_child
  # Drop our gate before token-checked cleanup; never wait on our own gate.
  while [ "$GATE_DEPTH" -gt 0 ]; do leave_gate; done
  if [ -n "$CLEANUP_TOKEN" ]; then cleanup_reservation "$CLEANUP_OWNER" "$CLEANUP_TOKEN" || true; fi
  rm -f "$LOCK_TMP"
  exit "$rc"
}
trap on_exit EXIT
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

app_start() {
  local owner="$1" note="${2:-}" pid tries=0
  CLEANUP_OWNER="$owner"; CLEANUP_TOKEN="$TOKEN"
  acquire "$owner" app "$note" || return 1
  # Building does not hold the mutation gate. A deliberate recovery may cancel
  # this reservation, so ownership must be checked again immediately before open.
  "$ROOT/tools/package_app.sh" >/dev/null || return $?
  enter_gate || return 1
  if ! matches "$owner" "$TOKEN" || [ "$(field state)" != reserved ] || [ -n "$(holders)" ]; then
    echo 'REFUSED: startup reservation changed or a control process appeared' >&2
    leave_gate
    return 1
  fi
  # Once open is invoked, even an error or interruption may leave a queued
  # LaunchServices request. Do not infer that no client will appear later.
  write_lock "$owner" app 0 "$note" "$TOKEN" launching "$(field acquiredAt)" || return 1
  CLEANUP_TOKEN=""
  if run_bounded 50 open "$APP"; then
    pid="$(pgrep -f "$APP_PATTERN" 2>/dev/null | head -1 || true)"
    while [ -z "$pid" ] && [ "$tries" -lt 50 ]; do
      sleep 0.1
      tries=$((tries + 1))
      pid="$(pgrep -f "$APP_PATTERN" 2>/dev/null | head -1 || true)"
    done
    if [ -n "$pid" ]; then
      write_lock "$owner" app "$pid" "$note" "$TOKEN" running "$(field acquiredAt)" || return 1
    fi
    leave_gate
    echo "app launch requested; pid ${pid:-0}"
  else
    local rc=$?
    leave_gate
    return "$rc"
  fi
}

app_stop() {
  local owner="$1" force="${2:-}" held_owner held_token tries=0
  single_line "$owner" || return 1
  enter_gate "$force" || return 1
  if ! reservation_exists; then
    if [ -z "$(holders)" ]; then leave_gate; echo 'already free'; return 0; fi
    if [ "$force" != force ]; then
      echo 'REFUSED: an unreserved control process requires deliberate force' >&2
      leave_gate; return 1
    fi
    write_lock "$owner" app 0 '' "$TOKEN" reserved || return 1
  fi
  if ! valid_reservation && [ "$force" = force ] && valid_legacy_reservation && [ "$(field role)" = app ]; then
    write_lock "$(field owner)" "$(field role)" "$(field pid)" "$(field note)" "$TOKEN" running "$(field acquiredAt)" || return 1
  fi
  if ! valid_reservation || [ "$(field role)" != app ]; then
    echo 'REFUSED: app-stop requires a valid app reservation' >&2
    leave_gate; return 1
  fi
  if { [ "$(field owner)" != "$owner" ] && [ "$force" != force ]; } || stop_is_active; then
    echo 'REFUSED: reservation belongs to another owner or stop operation' >&2
    leave_gate; return 1
  fi
  if [ "$(field state)" = launching ] && [ -z "$(pgrep -f "$APP_PATTERN" 2>/dev/null || true)" ]; then
    echo 'REFUSED: launch completion is unknown; retry after the app appears' >&2
    leave_gate; return 1
  fi
  held_owner="$(field owner)"; held_token="$(field token)"
  write_lock "$held_owner" app "$(field pid)" "$(field note)" "$held_token" stopping "$(field acquiredAt)" "$$" || return 1
  leave_gate

  # The stopping reservation blocks acquire/release while quit runs outside the
  # gate. A hung command or stubborn process cannot cause premature release.
  run_bounded 30 osascript -e 'quit app "Perch"' 2>/dev/null || true
  run_bounded 20 pkill -f "$APP_PATTERN" 2>/dev/null || true
  while [ -n "$(holders)" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  enter_gate "$force" || return 1
  if ! matches "$held_owner" "$held_token" || [ "$(field operationPid)" != "$$" ] || [ -n "$(holders)" ]; then
    echo 'REFUSED: stop did not finish; reservation retained' >&2
    leave_gate; return 1
  fi
  rm -f "$LOCK"
  log "STOP owner=$owner"
  leave_gate
  echo 'app stopped; released'
}

# Both probes use the same reservation, launch, PID and cleanup lifecycle.
run_probe() { # binary label owner outfile note [probe args...]
  local binary="$1" label="$2" owner="$3" out="$4" note="${5:-}" rc
  shift 5
  if [ ! -x "$binary" ]; then
    echo "MISSING: $label is not built (swift build --product $label)" >&2
    return 1
  fi
  note="$label${note:+: $note}"
  CLEANUP_OWNER="$owner"; CLEANUP_TOKEN="$TOKEN"
  acquire "$owner" probe "$note" || return 1
  enter_gate || return 1
  if ! matches "$owner" "$TOKEN" || [ "$(field state)" != reserved ] || [ -n "$(holders)" ]; then
    leave_gate; return 1
  fi
  DEFER_SIGNAL=1
  "$binary" "$@" > "$out" 2>&1 &
  CHILD_PID=$!
  DEFER_SIGNAL=0
  [ "$PENDING_SIGNAL" -eq 0 ] || exit "$PENDING_SIGNAL"
  write_lock "$owner" probe "$CHILD_PID" "$note" "$TOKEN" running "$(field acquiredAt)" || return 1
  leave_gate
  if wait "$CHILD_PID"; then rc=0; else rc=$?; fi
  CHILD_PID=""
  cleanup_reservation "$owner" "$TOKEN" || true
  CLEANUP_TOKEN=""
  echo "$label exit=$rc"
  return "$rc"
}

cmd="${1:-status}"
case "$cmd" in
  status)
    if reservation_exists; then echo '== lock =='; cat "$LOCK"; else echo 'no lock file'; fi
    echo '== live control processes =='
    running="$(holders)"; echo "${running:-none}"
    ;;
  acquire) acquire "${2:?owner}" "${3:?role app|probe}" "${4:-}"; echo "acquired by $2" ;;
  release) release "${2:?owner}" "${3:-}" ;;
  app-start) app_start "${2:?owner}" "${3:-}" ;;
  app-stop) app_stop "${2:?owner}" "${3:-}" ;;
  probe) run_probe "$PROBE" perch-probe "${2:?owner}" "${4:?output file}" "${5:-}" "${3:?address}" ;;
  bose-probe) run_probe "$BOSE_PROBE" bose-probe "${2:?owner}" "${3:?output file}" '' "${@:4}" ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
