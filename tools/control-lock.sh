#!/usr/bin/env bash
#
# Coordinates exclusive access to the single Sony control (RFCOMM) session.
#
# The headset exposes exactly one control channel. The notch app and the probe
# CLI both open it, so only one may run at a time; a second one hangs waiting for
# the channel. Every agent MUST take the lock before launching either, and release
# it after stopping. The lock records which agent (owner) holds it and when, and an
# append-only log keeps the history of who changed it.
#
# NEVER write a Bluetooth address or other personal data into the lock or the log.
#
# Usage:
#   control-lock.sh status
#   control-lock.sh acquire <owner> <app|probe> [note]
#   control-lock.sh release <owner>
#   control-lock.sh app-start <owner> [note]          # acquire + open the notch app
#   control-lock.sh app-stop  <owner>                 # quit the notch app + release
#   control-lock.sh probe     <owner> <address> <outfile> [note]   # acquire + run probe + release
#
# <owner> should identify the agent/session (e.g. its Claude Code session id).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/.control-session.lock"
LOG="$ROOT/.control-session.log"
APP="$ROOT/.build/Perch.app"
PROBE="$ROOT/.build/debug/perch-probe"
APP_PATTERN='.build/Perch.app/Contents/MacOS/Perch'
PROBE_PATTERN='perch-probe'

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
field() { [ -f "$LOCK" ] && sed -n "s/^$1=//p" "$LOCK" || true; }

# Any process actually holding the channel right now, lock file aside.
holders() {
  { pgrep -f "$APP_PATTERN" 2>/dev/null || true; pgrep -f "$PROBE_PATTERN" 2>/dev/null || true; } | tr '\n' ' '
}

write_lock() { # owner role pid note
  {
    echo "owner=$1"
    echo "role=$2"
    echo "pid=$3"
    echo "acquiredAt=$(now)"
    echo "note=$4"
  } > "$LOCK"
}

log() { echo "$(now) $*" >> "$LOG"; }

acquire() { # owner role note
  local owner="$1" role="$2" note="${3:-}"

  # Serialize the check-and-create so two concurrent acquires cannot both pass. mkdir
  # is atomic; a leftover gate older than a minute is treated as abandoned.
  local gate="$LOCK.gate" tries=0
  while ! mkdir "$gate" 2>/dev/null; do
    if [ -n "$(find "$gate" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$gate" 2>/dev/null || true; continue; fi
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then echo "BUSY: acquire gate held; try again" >&2; return 1; fi
    sleep 0.1
  done

  local rc=0 msg=""
  # Only one control client may ever run. If any is already live, refuse — even to the
  # same owner, since starting a second client is what hangs on the single channel.
  local running; running="$(holders)"
  if [ -n "$running" ]; then
    local lo=""; [ -f "$LOCK" ] && lo="$(field owner)"
    msg="BUSY: a control process is already running (pids: $running${lo:+, lock owner=$lo}); stop it first."
    rc=1
  else
    if [ -f "$LOCK" ]; then
      local lo; lo="$(field owner)"
      [ "$lo" != "$owner" ] && log "OVERTAKE stale lock of '$lo' by '$owner'"
    fi
    write_lock "$owner" "$role" "0" "$note"
    log "ACQUIRE owner=$owner role=$role note=$note"
  fi

  rmdir "$gate" 2>/dev/null || true
  [ -n "$msg" ] && echo "$msg" >&2
  return $rc
}

set_pid() { [ -f "$LOCK" ] && sed -i '' "s/^pid=.*/pid=$1/" "$LOCK" || true; }

release() { # owner [force]
  local owner="$1" force="${2:-}"
  if [ ! -f "$LOCK" ]; then echo "already free"; return 0; fi
  local lo; lo="$(field owner)"
  if [ "$lo" != "$owner" ] && [ "$force" != "force" ]; then
    echo "REFUSED: lock is owned by '$lo', not '$owner' (use 'release <owner> force' to override)" >&2
    return 1
  fi
  log "RELEASE owner=$owner (was owner=$lo)"
  rm -f "$LOCK"
  echo "released"
}

cmd="${1:-status}"
case "$cmd" in
  status)
    if [ -f "$LOCK" ]; then echo "== lock =="; cat "$LOCK"; else echo "no lock file"; fi
    local_h="$(holders)"
    echo "== live control processes =="
    echo "${local_h:-none}"
    ;;

  acquire)
    acquire "${2:?owner}" "${3:?role app|probe}" "${4:-}"
    echo "acquired by ${2}"
    ;;

  release)
    release "${2:?owner}" "${3:-}"
    ;;

  app-start)
    owner="${2:?owner}"; note="${3:-}"
    acquire "$owner" "app" "$note"
    # If packaging or launching fails (or the script is interrupted) after the lock
    # was taken, do not leave it held: nothing is running, so nobody could release it.
    # The trap is cleared once the app is actually up, at which point the lock must
    # survive this script exiting.
    trap 'log "AUTORELEASE app-start failed owner=$owner"; release "$owner" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Always repackage first: `swift build` refreshes .build/<config>/Perch but
    # NOT the .app bundle, so launching without this runs a stale binary.
    "$ROOT/tools/package_app.sh" >/dev/null
    open "$APP"
    trap - EXIT INT TERM
    sleep 1
    set_pid "$(pgrep -f "$APP_PATTERN" | head -1 || echo 0)"
    echo "app started; $(field pid | sed 's/^/pid /')"
    ;;

  app-stop)
    owner="${2:?owner}"; force="${3:-}"
    # Never clobber another agent's session. If the lock belongs to a different owner,
    # refuse without 'force' — even when no process is currently live, since the other
    # agent may be between launches and still counts on its lock.
    lo="$(field owner)"
    if [ -n "$lo" ] && [ "$lo" != "$owner" ] && [ "$force" != "force" ]; then
      echo "REFUSED: the control lock is owned by '$lo', not '$owner' (use 'app-stop $owner force' to override)" >&2
      exit 1
    fi
    osascript -e 'quit app "Perch"' 2>/dev/null || true
    pkill -f "$APP_PATTERN" 2>/dev/null || true
    sleep 1
    # 'force' here only covers the ownership cases already allowed above (own lock,
    # empty owner field, or an explicit force from the caller).
    release "$owner" force
    ;;

  probe)
    owner="${2:?owner}"; address="${3:?bluetooth address}"; out="${4:?output file}"; note="${5:-probe}"
    acquire "$owner" "probe" "$note"
    # Release on any exit, including SIGINT/SIGTERM. Bash delivers the trap only
    # after the foreground probe finishes, so the lock is never released while the
    # probe still holds the channel. Ctrl-C also reaches the probe itself (same
    # process group), which is what ends it.
    trap 'log "AUTORELEASE probe interrupted owner=$owner"; release "$owner" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    set +e
    "$PROBE" "$address" > "$out" 2>&1
    rc=$?
    set -e
    trap - EXIT INT TERM
    release "$owner"
    echo "probe exit=$rc -> $out"
    exit $rc
    ;;

  *)
    echo "unknown command: $cmd" >&2
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
