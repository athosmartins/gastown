#!/usr/bin/env bash
# dolt-port-pin-guard.sh (ga-3v2zt00) -- DETECTION ONLY: finds a Dolt port written down somewhere that is not
# the port the live server answers on, and says where. It never edits a plist, a rig config or a port file.
#
# WHY: the Dolt port changes on every start (52756 -> 52757 at the 22/11 reboot, back to 52756 at the 23/11 09:52
# restart). Every place that wrote the number down went blind on the next flip -- the gate read its own queue as
# "raced away" for 80 min, the Pilot refused to dispatch, the sentinel and the disk-floor guard raised "Dolt
# unreachable" on a server that never went down, the child-priority-janitor crash-looped. Cleaning the pins by hand
# is Sisyphus (the next restart re-breaks them); this is the detector the clean-up was missing.
#
# WHAT IT LOOKS AT (the places that bit us, nothing else):
#   1. launchd plists (DPPG_PLIST_GLOB, default ~/Library/LaunchAgents/*.plist): EnvironmentVariables
#      BEADS_DOLT_PORT / BEADS_DOLT_SERVER_PORT / GC_DOLT_PORT.
#        - value != live port  -> STALE  (the job is blind right now)
#        - value == live port  -> PINNED (works today, breaks on the next flip: no plist may carry a number)
#   2. every rig .beads dir (HQ, <rig>/.beads, <rig>/mayor/rig/.beads): dolt-server.port, config.yaml `dolt.port:`,
#      metadata.json `dolt_server_port`. These files legitimately EQUAL the live port, so only a mismatch counts.
#      (a redirected rig whose copy nobody refreshes is exactly what crash-looped the janitor on 23/11.)
# The live port comes from dolt_server_port (dolt-pid-lib.sh): the LISTEN socket of the verified server, never a file.
#
# THREE ANSWERS (root-class:error-vs-empty): no findings = OK; findings = ALERT; live port UNKNOWN = the guard
# cannot judge -> it logs UNKNOWN and changes NOTHING (no alert, no "recovered"). A plist plutil cannot parse is counted
# and logged ("unreadable") -- never read as "no pin". A binary-format plist is invisible to the grep prefilter
# (the city's plists are XML); that is a known blind spot, not a clean bill.
#
# CADENCE / COST: StartInterval 600 s in the plist; one run = a grep over the plists + a few file reads (~1 s). A
# mkdir lock makes a second instance a no-op, so a slow run can never stack (ga-y0g5x).
# Exit code is always 0: a guard that fails launchd's job makes noise about itself instead of the pin.
#
# Env seams (selftest/operators): DPPG_PLIST_GLOB, DPPG_BEADS_DIRS (space-separated; replaces the default list),
# DPPG_SKIP_DIRS, DPPG_STATE, DPPG_LOG, DPPG_LOCK, DPPG_NOTIFY (command, default `notify`), GC_DOLT_PORT_OVERRIDE.

set -uo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GT_ROOT="$(dirname "$CITY")"
# shellcheck source=dolt-pid-lib.sh
source "${DPPG_LIB:-$(dirname "${BASH_SOURCE[0]:-$0}")/dolt-pid-lib.sh}"

PLIST_GLOB="${DPPG_PLIST_GLOB:-$HOME/Library/LaunchAgents/*.plist}"
# beads/.beads is the standalone beads repo's own old store (port 3307, not the city Dolt) -- not a pin of ours.
SKIP_DIRS="${DPPG_SKIP_DIRS:-$GT_ROOT/beads/.beads}"
STATE="${DPPG_STATE:-$CITY/.gc/dolt-port-pin-guard.state}"
LOG="${DPPG_LOG:-$CITY/.gc/logs/dolt-port-pin-guard.log}"
LOCK="${DPPG_LOCK:-$CITY/.gc/dolt-port-pin-guard.lock}"
NOTIFY_CMD="${DPPG_NOTIFY:-notify}"

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }

# a lock left by a killed run (> 30 min old: the run takes ~1 s) must not silence the guard for good
[ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || { log "another instance holds the lock -- skipping this run"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# vazio/falhou (no live server, no port file, no pin, or the lib could not answer) -> UNKNOWN: judge nothing, change nothing
LIVE="$(dolt_server_port 2>/dev/null || true)"
if [ -z "$LIVE" ]; then
  log "UNKNOWN: live Dolt port could not be derived -- nothing judged, state untouched"
  exit 0
fi

FINDINGS=()
UNREADABLE=0

# --- 1. launchd plists ---------------------------------------------------------------------------------------------
# vazio (no plist mentions a port var) -> no plist findings; falhou (plutil cannot parse a plist that does mention one) -> UNREADABLE, counted + logged, not "clean"
# (while-read, not mapfile: /bin/bash on macOS is 3.2)
# shellcheck disable=SC2086
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! plutil -lint "$f" >/dev/null 2>&1; then UNREADABLE=$((UNREADABLE + 1)); log "unreadable plist (plutil -lint failed): $f"; continue; fi
  for k in BEADS_DOLT_PORT BEADS_DOLT_SERVER_PORT GC_DOLT_PORT; do
    v="$(plutil -extract "EnvironmentVariables.$k" raw -o - "$f" 2>/dev/null || true)"   # key absent -> empty = no pin
    [ -n "$v" ] || continue
    if [ "$v" = "$LIVE" ]; then FINDINGS+=("PINNED $(basename "$f") $k=$v (== live today; breaks on the next flip)")
    else                         FINDINGS+=("STALE $(basename "$f") $k=$v (live=$LIVE)"); fi
  done
done < <(grep -lE 'BEADS_DOLT_PORT|BEADS_DOLT_SERVER_PORT|GC_DOLT_PORT' $PLIST_GLOB 2>/dev/null || true)

# --- 2. rig .beads dirs --------------------------------------------------------------------------------------------
if [ -n "${DPPG_BEADS_DIRS:-}" ]; then
  # shellcheck disable=SC2206
  _dirs=($DPPG_BEADS_DIRS)
else
  _dirs=("$CITY/.beads")
  for d in "$GT_ROOT"/*/.beads "$GT_ROOT"/*/mayor/rig/.beads; do [ -d "$d" ] && _dirs+=("$d"); done
fi
for d in "${_dirs[@]}"; do
  case " $SKIP_DIRS " in *" $d "*) continue ;; esac
  [ -d "$d" ] || continue
  _chk() {  # _chk <file-label> <value>: numeric + != live -> finding; non-numeric -> UNREADABLE (a third state, never "ok")
    case "$2" in
      '') return 0 ;;
      *[!0-9]*) UNREADABLE=$((UNREADABLE + 1)); log "unreadable value in $d/$1: [$2]"; return 0 ;;
    esac
    [ "$2" = "$LIVE" ] || FINDINGS+=("STALE ${d#"$GT_ROOT"/}/$1 =$2 (live=$LIVE)")
  }
  [ -r "$d/dolt-server.port" ] && _chk dolt-server.port "$(head -1 "$d/dolt-server.port" 2>/dev/null | tr -d '[:space:]')"
  [ -r "$d/config.yaml" ]      && _chk config.yaml:dolt.port "$(sed -n 's/^dolt\.port:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$d/config.yaml" 2>/dev/null | head -1 | tr -d "\"'")"
  [ -r "$d/metadata.json" ]    && _chk metadata.json:dolt_server_port "$(sed -n 's/.*"dolt_server_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$d/metadata.json" 2>/dev/null | head -1)"
done

# --- verdict: alert when the SET of findings changes (not every 10 min), say when it clears ---------------------------
SIG="none"; [ "${#FINDINGS[@]}" -gt 0 ] && SIG="$(printf '%s\n' "${FINDINGS[@]}" | sort | cksum | cut -d' ' -f1)"
PREV="$(cat "$STATE" 2>/dev/null || echo none)"
_notify() { command -v "$NOTIFY_CMD" >/dev/null 2>&1 && "$NOTIFY_CMD" -p 3 -t "$1" "$2" >/dev/null 2>&1 || true; }

if [ "${#FINDINGS[@]}" -eq 0 ] && [ "$UNREADABLE" -gt 0 ]; then
  # nothing found, but something could not be read: that is NOT "clean" -- keep the previous verdict, say why
  log "INCONCLUSIVE: no finding, but $UNREADABLE source(s) unreadable -- state untouched (previous $PREV)"
  exit 0
fi
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  log "OK: live=$LIVE, no stale or pinned Dolt port found (unreadable=$UNREADABLE)"
  if [ "$PREV" != "none" ]; then _notify 'Porta do Dolt: pins limpos' "Nenhuma porta fixa/velha restante (live=$LIVE)."; fi
  printf 'none' > "$STATE" 2>/dev/null || true
  exit 0
fi

for x in "${FINDINGS[@]}"; do log "FINDING: $x"; done
log "ALERT: ${#FINDINGS[@]} finding(s), live=$LIVE, unreadable=$UNREADABLE (set $SIG; previous $PREV)"
if [ "$SIG" != "$PREV" ]; then
  _notify 'Porta do Dolt fixa/velha' "$(printf '%s; ' "${FINDINGS[@]:0:4}")live=$LIVE. Cada um fica cego na proxima troca de porta. Lista completa: $LOG"
  printf '%s' "$SIG" > "$STATE" 2>/dev/null || true
fi
exit 0
