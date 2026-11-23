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
# The live port comes from dolt_server_live_port (dolt-pid-lib.sh): GC_DOLT_PORT_OVERRIDE or the LISTEN socket of the verified
# server -- NEVER a file, not even the HQ port file: that file is one of the things this guard audits, so a "live" port taken from
# it could never be STALE and the guard would call the whole city clean (gate round 2, reproduced with a real killed server).
#
# THREE ANSWERS (root-class:error-vs-empty): no findings = OK; findings = ALERT; live port UNKNOWN = the guard
# cannot judge -> it logs UNKNOWN and changes NOTHING (no alert, no "recovered"). A plist plutil cannot parse is counted
# and logged ("unreadable") -- never read as "no pin". A plist that names a port variable but carries no EnvironmentVariables
# pin (the name sits in ProgramArguments / script text), an EMPTY dolt-server.port, a plist glob that matches nothing and a
# LaunchAgents dir that cannot be read are "unreadable" too: the guard could not judge them, and that is not "clean".
# A binary-format plist is invisible to the grep prefilter (the city's plists are XML); that is a known blind spot, not a clean bill.
#
# DELIVERY (gate round 2): the dedup state is written ONLY after the notification was delivered (notify rc 0). A failed
# push is logged ("NOTIFY FAILED ... will retry next run") and the next run (10 min) sends it again; it is never recorded as sent.
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

# vazio/falhou (override unset AND no verified server with a readable LISTEN socket, or the lib could not answer) -> UNKNOWN:
# judge nothing, change nothing. Strict on purpose: dolt_server_live_port never falls to a port FILE (the files are what we audit).
LIVE="$(dolt_server_live_port 2>/dev/null || true)"
if [ -z "$LIVE" ]; then
  log "UNKNOWN: live Dolt port could not be derived from a verified server -- nothing judged, state untouched"
  exit 0
fi

FINDINGS=()
UNREADABLE=0

# --- 1. launchd plists ---------------------------------------------------------------------------------------------
# vazio (no plist mentions a port var) -> no plist findings; falhou (plutil cannot parse a plist that does mention one) -> UNREADABLE, counted + logged, not "clean"
# (while-read, not mapfile: /bin/bash on macOS is 3.2)
# vazio (the glob matches no plist at all) or falhou (the LaunchAgents dir cannot be read) -> UNREADABLE, never "no plist = clean"
# shellcheck disable=SC2086
_plists=($PLIST_GLOB)
_hits=""
if [ "${#_plists[@]}" -eq 0 ] || [ ! -e "${_plists[0]}" ]; then
  UNREADABLE=$((UNREADABLE + 1)); log "unreadable: the plist glob matched nothing ($PLIST_GLOB) -- the plists were NOT checked"
else
  # grep rc: 0 = some plist names a port var; 1 = none does (vazio -> nothing to judge); >= 2 = grep itself failed (falhou -> UNREADABLE).
  # Hits grep did print before failing are kept: a partial answer is still judged, and the failure is counted on top of it.
  _hits="$(grep -lE 'BEADS_DOLT_PORT|BEADS_DOLT_SERVER_PORT|GC_DOLT_PORT' "${_plists[@]}" 2>/dev/null)"; _grc=$?
  if [ "$_grc" -gt 1 ]; then UNREADABLE=$((UNREADABLE + 1)); log "unreadable: grep over the plists failed (rc $_grc) -- some plists were NOT checked"; fi
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! plutil -lint "$f" >/dev/null 2>&1; then UNREADABLE=$((UNREADABLE + 1)); log "unreadable plist (plutil -lint failed): $f"; continue; fi
  _got=0
  for k in BEADS_DOLT_PORT BEADS_DOLT_SERVER_PORT GC_DOLT_PORT; do
    v="$(plutil -extract "EnvironmentVariables.$k" raw -o - "$f" 2>/dev/null || true)"   # key absent -> empty = no pin
    [ -n "$v" ] || continue
    _got=1
    if [ "$v" = "$LIVE" ]; then FINDINGS+=("PINNED $(basename "$f") $k=$v (== live today; breaks on the next flip)")
    else                         FINDINGS+=("STALE $(basename "$f") $k=$v (live=$LIVE)"); fi
  done
  # the grep prefilter matched, extraction found no EnvironmentVariables pin: the name sits somewhere we do not parse
  # (ProgramArguments / script text) -- cannot judge it, so it must not read as clean
  if [ "$_got" -eq 0 ]; then UNREADABLE=$((UNREADABLE + 1)); log "unreadable: $(basename "$f") names a Dolt port variable outside EnvironmentVariables (ProgramArguments/script text) -- not judged"; fi
done <<< "${_hits:-}"

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
  # _chk <file-label> <value>: numeric + != live -> finding; empty = the source names no port (no pin); anything else (incl. the "?"
  # that the readers below print for a key that IS there but holds nothing parseable) -> UNREADABLE, a third state, never "ok"
  _chk() {
    case "$2" in
      '') return 0 ;;
      *[!0-9]*) UNREADABLE=$((UNREADABLE + 1)); log "unreadable value in $d/$1: [$2]"; return 0 ;;
    esac
    [ "$2" = "$LIVE" ] || FINDINGS+=("STALE ${d#"$GT_ROOT"/}/$1 =$2 (live=$LIVE)")
  }
  if [ -r "$d/dolt-server.port" ]; then
    # the port file exists to hold a number: present but EMPTY (an interrupted write) is unreadable, not "no pin"
    _v="$(head -1 "$d/dolt-server.port" 2>/dev/null | tr -d '[:space:]')"
    _chk dolt-server.port "${_v:-?}"
  fi
  if [ -r "$d/config.yaml" ]; then
    # flat `dolt.port: N` or nested `dolt:` + indented `port: N`; a key that is there but empty prints "?" (unreadable); no key = no pin
    _chk config.yaml:dolt.port "$(awk '
      /^dolt\.port[ \t]*:/ { v=$0; sub(/^dolt\.port[ \t]*:[ \t]*/,"",v); sub(/[ \t]*#.*$/,"",v); gsub(/["\047]/,"",v); print (v==""?"?":v); exit }
      /^dolt[ \t]*:[ \t]*(#.*)?$/ { indolt=1; next }
      indolt && /^[^ \t#]/ { indolt=0 }
      indolt && /^[ \t]+port[ \t]*:/ { v=$0; sub(/^[ \t]+port[ \t]*:[ \t]*/,"",v); sub(/[ \t]*#.*$/,"",v); gsub(/["\047]/,"",v); print (v==""?"?":v); exit }
    ' "$d/config.yaml" 2>/dev/null)"
  fi
  if [ -r "$d/metadata.json" ]; then
    # key absent = no pin; key present with a number (bare or quoted) = judged; key present with anything else (null, empty) = "?" (unreadable)
    if grep -q '"dolt_server_port"' "$d/metadata.json" 2>/dev/null; then
      _v="$(sed -n 's/.*"dolt_server_port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' "$d/metadata.json" 2>/dev/null | head -1)"
      _chk metadata.json:dolt_server_port "${_v:-?}"
    fi
  fi
done

# --- verdict: alert when the SET of findings changes (not every 10 min), say when it clears ---------------------------
SIG="none"; [ "${#FINDINGS[@]}" -gt 0 ] && SIG="$(printf '%s\n' "${FINDINGS[@]}" | sort | cksum | cut -d' ' -f1)"
# vazio (no state file yet, or an interrupted write left it EMPTY) is "none": a lost previous verdict re-alerts at worst and never sends a "limpos" nobody earned
PREV="$(cat "$STATE" 2>/dev/null || true)"; [ -n "$PREV" ] || PREV=none
# _notify returns the REAL outcome (0 = delivered): the dedup state below may only record what was actually delivered (dolt-hang-watchdog restart_escalate does the same)
_notify() { command -v "$NOTIFY_CMD" >/dev/null 2>&1 || return 127; "$NOTIFY_CMD" -p 3 -t "$1" "$2" >/dev/null 2>&1; }
_set_state() { printf '%s' "$1" > "$STATE" 2>/dev/null || log "STATE WRITE FAILED ($STATE) -- the next run may repeat this verdict"; }

if [ "${#FINDINGS[@]}" -eq 0 ] && [ "$UNREADABLE" -gt 0 ]; then
  # nothing found, but something could not be read: that is NOT "clean" -- keep the previous verdict, say why
  log "INCONCLUSIVE: no finding, but $UNREADABLE source(s) unreadable -- state untouched (previous $PREV)"
  exit 0
fi
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  log "OK: live=$LIVE, no stale or pinned Dolt port found (unreadable=$UNREADABLE)"
  if [ "$PREV" = "none" ]; then
    _set_state none
  elif _notify 'Porta do Dolt: pins limpos' "Nenhuma porta fixa/velha restante (live=$LIVE)."; then
    _set_state none
  else
    log "NOTIFY FAILED (pins limpos) -- state untouched, will retry next run"
  fi
  exit 0
fi

for x in "${FINDINGS[@]}"; do log "FINDING: $x"; done
log "ALERT: ${#FINDINGS[@]} finding(s), live=$LIVE, unreadable=$UNREADABLE (set $SIG; previous $PREV)"
if [ "$SIG" != "$PREV" ]; then
  if _notify 'Porta do Dolt fixa/velha' "$(printf '%s; ' "${FINDINGS[@]:0:4}")live=$LIVE. Cada um fica cego na proxima troca de porta. Lista completa: $LOG"; then
    _set_state "$SIG"
  else
    log "NOTIFY FAILED (set $SIG) -- state untouched, will retry next run"
  fi
fi
exit 0
