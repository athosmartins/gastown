#!/usr/bin/env bash
# daemon-presence-watchdog.sh — "who watches the watchers" (24/7 resilience).
#
# Detects when a CRITICAL gascity daemon has gone ABSENT (plist on disk but NOT loaded
# — after a reboot, a manual unload, or launchd giving up on a crash-loop) or is
# persistently CRASH-LOOPING (loaded but exiting nonzero on consecutive checks), and
# self-heals + alerts. Closes the 24/7 blind spot where a core pipeline daemon
# (pilot/gate/classify/refine/delivery/...) silently disappears and bead delivery
# stalls for hours with nobody noticing — machine-health-reporter is telemetry-only,
# and nothing checked daemon PRESENCE.
#
# Runs every 5 min via launchd (com.gascity.daemon-presence-watchdog, StartInterval),
# fresh each run (self-recovering by design). Fail-safe: any probe error is logged,
# never crashes the sweep.
#
# Action policy:
#   ABSENT critical daemon         → bootstrap (reload) it + ntfy + mail Mayor (self-heal).
#   CRASH-LOOP (loaded, nonzero exit on 2 consecutive checks) → ntfy + mail Mayor; do NOT
#       reload (it is loaded and failing — reloading would just re-loop; needs a human/Mayor).
#   ALL HEALTHY                    → a single heartbeat line to the log (no noise).
#
# The CRITICAL set is the must-always-run pipeline + the watchdogs that protect it.
# One-shots (suavez-first-watch self-unloads by design) and deprecated jobs are
# deliberately ABSENT from this list — they are never auto-resurrected.
# Override the set with DPW_CRITICAL (space-list of labels).
set -uo pipefail

LAUNCH_DIR="${DPW_LAUNCH_DIR:-$HOME/Library/LaunchAgents}"
LOG="${DPW_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/daemon-presence-watchdog.log}"
STATE="${DPW_STATE:-/Users/athos/gt/.gascity-gastown-hq/.gc/daemon-presence-state}"
UID_NUM="$(id -u)"
DPW_RELOAD="${DPW_RELOAD:-1}"     # 1 = auto-reload absent critical daemons; 0 = alert only.

DPW_CRITICAL="${DPW_CRITICAL:-com.gascity.pilot com.gascity.context-check-dispatcher com.gascity.quality-gate-dispatcher com.gascity.auto-refino-dispatcher com.gascity.refino-gate-dispatcher com.gascity.story-delivery com.gascity.supervisor com.gascity.supervisor-config-guard com.gascity.inflight-reclaim-guard com.gascity.gate-recovery-watchdog com.gascity.dolt-hang-watchdog com.gascity.production-stall-watchdog com.gascity.crew-hang-detector com.gascity.lifecycle-coherence-janitor com.gascity.crew-autopin-guard}"

HQ="${DPW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"

# Heartbeat-WEDGE config — "label|heartbeat-logfile|max-stale-seconds". A LOADED daemon
# whose heartbeat log has NOT advanced past max-stale is WEDGED: loaded + "running" but
# its sweep/loop is stuck (e.g. hung on a Dolt query). launchd will NOT restart it (it is
# alive) and the absent/crash-loop checks miss it (it IS loaded) — so it stalls delivery
# silently. Only daemons that emit a per-cycle heartbeat line are listed; thresholds are
# ≈5× the cycle so a merely slow cycle never trips. A wedge → launchctl kickstart -k
# (un-stick) + alert. Override via DPW_HEARTBEAT; a daemon NOT listed is wedge-unchecked.
DPW_HEARTBEAT="${DPW_HEARTBEAT:-com.gascity.pilot|$HQ/.gc/logs/pilot-dispatcher.log|1500
com.gascity.inflight-reclaim-guard|$HQ/.gc/logs/inflight-reclaim-guard-launchd.out|1500
com.gascity.context-check-dispatcher|$HQ/.gc/logs/context-check-dispatcher.log|3000
com.gascity.quality-gate-dispatcher|$HQ/.gc/logs/quality-gate-dispatcher.log|900
com.gascity.auto-refino-dispatcher|$HQ/.gc/logs/auto-refino-dispatcher.log|1500
com.gascity.story-delivery|$HQ/.gc/logs/story-delivery.log|1500}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# A label is loaded iff `launchctl list <label>` succeeds.
_loaded()    { launchctl list "$1" >/dev/null 2>&1; }
# The last-exit-status column (2nd field) for a loaded label; empty if not listed.
_last_exit() { launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $2}'; }
# Previous exit recorded for a label (from the state file); empty if none.
_prev_exit() { awk -v l="$1" '$1==l {print $2}' "$STATE" 2>/dev/null; }
# Seconds since <file> was last modified ("$2"=now epoch); empty if missing / stat fails.
_log_age()   { local f="$1" now="$2" m; [ -f "$f" ] || return 0; m=$(stat -f %m "$f" 2>/dev/null) && echo $(( now - m )); }

run_sweep() {
  local absent="" reloaded="" crashloop="" wedged="" healthy=0 newstate="" lbl plist ex prev _hb _hblog _hbmax _age
  local NOW; NOW="$(date +%s)"
  for lbl in $DPW_CRITICAL; do
    plist="$LAUNCH_DIR/$lbl.plist"
    if _loaded "$lbl"; then
      ex="$(_last_exit "$lbl")"; ex="${ex:-0}"
      prev="$(_prev_exit "$lbl")"
      # CRASH-LOOP = a POSITIVE exit (a real error, not a negative=signal restart) seen
      # on TWO consecutive checks. One transient nonzero exit never alerts.
      if [ "$ex" -gt 0 ] 2>/dev/null && [ -n "$prev" ] && [ "$prev" -gt 0 ] 2>/dev/null; then
        crashloop="$crashloop $lbl(exit=$ex)"
      else
        healthy=$((healthy + 1))
      fi
      # WEDGE: loaded but its per-cycle heartbeat log went stale past threshold = stuck.
      _hb="$(printf '%s\n' "$DPW_HEARTBEAT" | awk -F'|' -v l="$lbl" '$1==l{print $2"\t"$3; exit}')"
      if [ -n "$_hb" ]; then
        _hblog="${_hb%%$'\t'*}"; _hbmax="${_hb##*$'\t'}"
        _age="$(_log_age "$_hblog" "$NOW")"
        if [ -n "$_age" ] && [ "$_age" -gt "$_hbmax" ] 2>/dev/null; then
          wedged="$wedged $lbl(stale=${_age}s)"
          if [ "$DPW_RELOAD" = "1" ] && launchctl kickstart -k "gui/$UID_NUM/$lbl" 2>/dev/null; then
            log "KICKSTARTED wedged daemon: $lbl (heartbeat stale ${_age}s > ${_hbmax}s)"
          else
            log "WEDGED daemon NOT kickstarted: $lbl (stale ${_age}s, DPW_RELOAD=$DPW_RELOAD or kickstart failed)"
          fi
        fi
      fi
      newstate="$newstate$lbl $ex"$'\n'
    else
      newstate="$newstate$lbl absent"$'\n'
      if [ -f "$plist" ]; then
        absent="$absent $lbl"
        if [ "$DPW_RELOAD" = "1" ] && launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null; then
          reloaded="$reloaded $lbl"
          log "RELOADED absent critical daemon: $lbl"
        else
          log "ABSENT critical daemon NOT reloaded: $lbl (DPW_RELOAD=$DPW_RELOAD or bootstrap failed)"
        fi
      else
        log "WARN critical daemon $lbl is absent AND has no plist on disk ($plist)"
      fi
    fi
  done

  printf '%s' "$newstate" > "$STATE" 2>/dev/null || true

  if [ -n "$absent" ] || [ -n "$crashloop" ] || [ -n "$wedged" ]; then
    local msg="Daemon-presence watchdog:"
    [ -n "$absent" ]    && msg="$msg ABSENT:${absent} (reloaded:${reloaded:- none})."
    [ -n "$crashloop" ] && msg="$msg CRASH-LOOP:${crashloop} (loaded but failing — NOT reloaded, investigate)."
    [ -n "$wedged" ]    && msg="$msg WEDGED:${wedged} (loaded but heartbeat stale — kickstarted)."
    log "ALERT $msg"
    command -v notify >/dev/null 2>&1 && notify -t "Daemon watchdog" -p 4 "$msg" 2>/dev/null || true
    command -v gc >/dev/null 2>&1 && gc mail send mayor -s "Daemon-presence: critical daemon absent/crash-looping/wedged" -m "$msg" 2>/dev/null || true
    return 1
  fi
  log "OK: all $(echo $DPW_CRITICAL | wc -w | tr -d ' ') critical daemons loaded + healthy (heartbeat)"
  return 0
}

# ── selftest (hermetic; no launchctl/notify side effects) ─────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${DPW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  # Stub launchctl/notify/gc so the sweep is hermetic. SCEN drives loaded/exit per label.
  cat > "$TMP/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    if [ -n "${2:-}" ]; then
      # `launchctl list <label>` → success iff label is in DPW_TEST_LOADED.
      case " $DPW_TEST_LOADED " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac
    fi
    # table form: emit "PID EXIT LABEL" for loaded labels (exit from DPW_TEST_EXIT map).
    for l in $DPW_TEST_LOADED; do
      e=0; for kv in $DPW_TEST_EXIT; do case "$kv" in "$l:"*) e="${kv#*:}";; esac; done
      printf '%s\t%s\t%s\n' "-" "$e" "$l"
    done ;;
  bootstrap) echo "$2 $3" >> "$DPW_TEST_BOOTSTRAPS"; exit 0 ;;
  kickstart) echo "$*" >> "$DPW_TEST_KICKSTARTS"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TMP/launchctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/notify"; chmod +x "$TMP/notify"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gc";     chmod +x "$TMP/gc"
  export PATH="$TMP:$PATH"
  # Override the SCRIPT vars directly — the top-level `LAUNCH_DIR=${DPW_LAUNCH_DIR:-…}`
  # already ran at load, so setting DPW_LAUNCH_DIR now would be too late.
  LAUNCH_DIR="$TMP/agents"; mkdir -p "$LAUNCH_DIR"
  LOG="$TMP/log"; STATE="$TMP/state"
  DPW_CRITICAL="com.gascity.alpha com.gascity.beta com.gascity.gamma"
  export DPW_TEST_BOOTSTRAPS="$TMP/bootstraps"; : > "$DPW_TEST_BOOTSTRAPS"
  export DPW_TEST_KICKSTARTS="$TMP/kicks";      : > "$DPW_TEST_KICKSTARTS"
  DPW_HEARTBEAT=""   # scenarios 1–5 do not exercise the wedge check; 6–7 set it explicitly
  : > "$LAUNCH_DIR/com.gascity.alpha.plist"
  : > "$LAUNCH_DIR/com.gascity.beta.plist"
  : > "$LAUNCH_DIR/com.gascity.gamma.plist"

  export DPW_TEST_LOADED DPW_TEST_EXIT DPW_RELOAD   # exported so the stub subprocess sees them
  ALL="com.gascity.alpha com.gascity.beta com.gascity.gamma"

  echo "Scenario 1: all loaded + clean → OK (exit 0), no bootstrap"
  DPW_RELOAD=1; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  run_sweep && ok "all-healthy returns 0" || bad "all-healthy should return 0"
  [ ! -s "$DPW_TEST_BOOTSTRAPS" ] && ok "no bootstrap when all loaded" || bad "bootstrapped despite all loaded"

  echo "Scenario 2: beta ABSENT → reloaded + alert (exit 1)"
  : > "$DPW_TEST_BOOTSTRAPS"; DPW_TEST_LOADED="com.gascity.alpha com.gascity.gamma"; DPW_TEST_EXIT=""
  run_sweep && bad "absent should return 1" || ok "absent critical daemon returns 1 (alert)"
  grep -q "com.gascity.beta" "$DPW_TEST_BOOTSTRAPS" && ok "absent beta was reloaded (bootstrap)" || bad "absent beta NOT reloaded"

  echo "Scenario 3: DPW_RELOAD=0 → absent alerts but does NOT reload"
  : > "$DPW_TEST_BOOTSTRAPS"; DPW_RELOAD=0; DPW_TEST_LOADED="com.gascity.alpha com.gascity.gamma"; DPW_TEST_EXIT=""
  run_sweep; [ ! -s "$DPW_TEST_BOOTSTRAPS" ] && ok "DPW_RELOAD=0 suppresses auto-reload" || bad "reloaded despite DPW_RELOAD=0"
  DPW_RELOAD=1

  echo "Scenario 4: crash-loop needs TWO consecutive nonzero exits"
  : > "$STATE"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.beta:1"
  run_sweep && ok "single nonzero exit does NOT alert (transient)" || bad "transient nonzero exit falsely alerted"
  run_sweep && bad "2nd consecutive nonzero should alert (return 1)" || ok "persistent crash-loop alerts on 2nd consecutive nonzero exit"

  echo "Scenario 5: negative exit (signal restart) is NOT a crash-loop"
  : > "$STATE"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.beta:-15"
  run_sweep >/dev/null 2>&1
  run_sweep && ok "signal exit (-15) never treated as crash-loop" || bad "signal exit falsely flagged as crash-loop"

  echo "Scenario 6: loaded daemon with a STALE heartbeat log → WEDGED + kickstart"
  : > "$STATE"; : > "$DPW_TEST_KICKSTARTS"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  HB="$TMP/beta-hb.log"; DPW_HEARTBEAT="com.gascity.beta|$HB|300"
  touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$HB"   # mtime ~1h ago
  run_sweep && bad "wedged should return 1" || ok "wedged daemon (stale heartbeat) returns 1 (alert)"
  grep -q "com.gascity.beta" "$DPW_TEST_KICKSTARTS" && ok "wedged beta was kickstarted" || bad "wedged beta NOT kickstarted"

  echo "Scenario 7: FRESH heartbeat log → not wedged, no kickstart"
  : > "$DPW_TEST_KICKSTARTS"; touch "$HB"   # mtime = now
  run_sweep && ok "fresh heartbeat → no wedge (return 0)" || bad "fresh heartbeat falsely wedged"
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "no kickstart when heartbeat fresh" || bad "kickstarted despite fresh heartbeat"
  DPW_HEARTBEAT=""

  echo ""
  echo "daemon-presence-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep
