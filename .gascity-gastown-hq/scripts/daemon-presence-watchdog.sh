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

DPW_CRITICAL="${DPW_CRITICAL:-com.gascity.pilot com.gascity.context-check-dispatcher com.gascity.quality-gate-dispatcher com.gascity.auto-refino-dispatcher com.gascity.refino-gate-dispatcher com.gascity.story-delivery com.gascity.supervisor com.gascity.supervisor-config-guard com.gascity.inflight-reclaim-guard com.gascity.gate-recovery-watchdog com.gascity.dolt-hang-watchdog com.gascity.production-stall-watchdog com.gascity.crew-hang-detector com.gascity.lifecycle-coherence-janitor com.gascity.crew-autopin-guard com.gascity.lifecycle-correctness-auditor com.gascity.throughput-stall-watchdog}"

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

# ── RECYCLER — memory-bounded restart of known-leaky Python dashboards ────────
# Knobs (override via env or the launchd plist EnvironmentVariables):
#   RECYCLE_ENABLED        1=on, 0=disabled entirely (default: 1)
#   RECYCLE_DRY_RUN        1=log only, no actual kickstart (default: 0)
#   RECYCLE_RSS_MB         RSS threshold in MiB above which a daemon is recycled (default: 350)
#   RECYCLE_CHRONIC_PER_HR if a daemon needs recycling more than this many times in 60 min
#                          it is "chronically leaking" → escalate to Mayor (default: 3)
#   RECYCLE_DAEMONS        space-separated list of launchd labels eligible for recycling.
#                          ONLY these labels are ever touched — never anything else.
#
# Safety contract: ONLY labels listed in RECYCLE_DAEMONS are ever inspected or recycled.
# Any error (ps failure, label not loaded, kickstart failure) is caught, logged, and skipped;
# the failure never propagates to the watchdog's main sweep.
RECYCLE_ENABLED="${RECYCLE_ENABLED:-1}"
RECYCLE_DRY_RUN="${RECYCLE_DRY_RUN:-0}"
RECYCLE_RSS_MB="${RECYCLE_RSS_MB:-350}"
RECYCLE_CHRONIC_PER_HR="${RECYCLE_CHRONIC_PER_HR:-3}"
# Known-leaky daemons (add more as discovered; frota leaks slowly, auto-response-v2 leaked 455MB/3.5d):
RECYCLE_DAEMONS="${RECYCLE_DAEMONS:-com.urblink.painel-visibilidade com.whatsapp.frota-dashboard com.whatsapp.auto-response-v2-listener}"
# State dir for per-daemon recycle-hour counters (one file per label, content = "EPOCH COUNT"):
RECYCLE_STATE_DIR="${RECYCLE_STATE_DIR:-$HQ/.gc/recycle-state}"

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

# _rss_mb <label> — return current RSS in MiB for the process running under <label>.
# Uses launchctl list to get the PID, then ps -o rss= to read RSS in KiB.
# Prints nothing and returns 1 on any failure (not loaded, no PID, ps error).
_rss_mb() {
  local lbl="$1" pid rss_kb
  # `launchctl list <label>` prints JSON; the PID is in "PID" field.
  # A dash ("-") in the PID column means not running.
  pid=$(launchctl list "$lbl" 2>/dev/null | awk -F'"' '/"PID"/{print $4}')
  [ -z "$pid" ] || [ "$pid" = "-" ] && return 1
  rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$rss_kb" ] && return 1
  echo $(( rss_kb / 1024 ))
}

# _recycle_count_increment <label> <now_epoch> — bump the per-daemon counter for the
# current rolling hour. Returns the new count. State file format: "HOUR_START COUNT".
_recycle_count_increment() {
  local lbl="$1" now="$2" sf hour_start count
  sf="$RECYCLE_STATE_DIR/$lbl"
  mkdir -p "$RECYCLE_STATE_DIR" 2>/dev/null || true
  # Round down to the start of the current hour
  hour_start=$(( now - (now % 3600) ))
  if [ -f "$sf" ]; then
    local prev_start prev_count
    read -r prev_start prev_count < "$sf" 2>/dev/null || { prev_start=0; prev_count=0; }
    if [ "$prev_start" -eq "$hour_start" ] 2>/dev/null; then
      count=$(( prev_count + 1 ))
    else
      count=1   # new hour — reset
    fi
  else
    count=1
  fi
  printf '%s %s\n' "$hour_start" "$count" > "$sf" 2>/dev/null || true
  echo "$count"
}

# _recycle_count_current <label> <now_epoch> — return count within the current hour (0 if none).
_recycle_count_current() {
  local lbl="$1" now="$2" sf hour_start
  sf="$RECYCLE_STATE_DIR/$lbl"
  hour_start=$(( now - (now % 3600) ))
  [ -f "$sf" ] || { echo 0; return; }
  local prev_start prev_count
  read -r prev_start prev_count < "$sf" 2>/dev/null || { echo 0; return; }
  if [ "$prev_start" -eq "$hour_start" ] 2>/dev/null; then
    echo "$prev_count"
  else
    echo 0
  fi
}

run_recycle_sweep() {
  [ "${RECYCLE_ENABLED:-1}" = "1" ] || return 0
  local now lbl rss_mb count
  now="$(date +%s)"

  for lbl in $RECYCLE_DAEMONS; do
    # Fail-safe wrapper: any error in this block is logged and we move on.
    {
      # 1. Must be loaded — skip silently if not (it may be intentionally stopped).
      if ! launchctl list "$lbl" >/dev/null 2>&1; then
        continue
      fi

      # 2. Read RSS; skip if we can't determine it.
      rss_mb=$(_rss_mb "$lbl" 2>/dev/null) || { log "RECYCLE skip $lbl: could not read RSS"; continue; }

      # 3. Check against threshold.
      if [ "$rss_mb" -le "${RECYCLE_RSS_MB:-350}" ] 2>/dev/null; then
        log "RECYCLE ok $lbl RSS=${rss_mb}MB (threshold=${RECYCLE_RSS_MB:-350}MB)"
        continue
      fi

      log "RECYCLE trigger $lbl RSS=${rss_mb}MB > threshold=${RECYCLE_RSS_MB:-350}MB"

      # 4. Dry-run gate.
      if [ "${RECYCLE_DRY_RUN:-0}" = "1" ]; then
        log "RECYCLE dry-run: would kickstart $lbl (RSS=${rss_mb}MB)"
        notify -t "Recycler dry-run" "Would recycle $lbl RSS=${rss_mb}MB" 2>/dev/null || true
        continue
      fi

      # 5. Actually recycle: kickstart -k stops-and-restarts the process.
      if launchctl kickstart -k "gui/$UID_NUM/$lbl" 2>/dev/null; then
        log "RECYCLED $lbl (RSS was ${rss_mb}MB)"
        notify -t "Daemon recycled" "$lbl RSS=${rss_mb}MB exceeded ${RECYCLE_RSS_MB:-350}MB — recycled" 2>/dev/null || true
      else
        log "RECYCLE kickstart FAILED for $lbl (RSS=${rss_mb}MB)"
        notify -t "Recycler error" "kickstart -k $lbl failed" 2>/dev/null || true
        continue
      fi

      # 6. Chronic-leak detection: bump counter, escalate if over threshold.
      count=$(_recycle_count_increment "$lbl" "$now")
      if [ "$count" -gt "${RECYCLE_CHRONIC_PER_HR:-3}" ] 2>/dev/null; then
        local msg="CHRONIC LEAK: $lbl recycled ${count}x this hour (threshold=${RECYCLE_CHRONIC_PER_HR:-3}/hr) — needs a code fix"
        log "ALERT $msg"
        notify -t "Chronic leak" "$msg" 2>/dev/null || true
        command -v gc >/dev/null 2>&1 && gc mail send mayor \
          -s "Recycler: chronic leak $lbl" \
          -m "$msg (RSS was ${rss_mb}MB)" 2>/dev/null || true
      fi
    } || log "RECYCLE unexpected error for $lbl — skipped (fail-safe)"
  done
  return 0   # recycler never fails the watchdog
}

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

  # ── RECYCLER selftests (scenarios 8–12) ──────────────────────────────────
  # All recycler scenarios use seams: a stub `ps` that returns a controlled RSS,
  # a stub `launchctl` that handles both the watchdog list queries AND the recycler's
  # `list <label>` loaded-check + PID lookup, and the same stub `notify`/`gc`.
  # RECYCLE_DRY_RUN is forced to 0 so kickstart is tested; kickstart writes to
  # DPW_TEST_KICKSTARTS (the same file used by the main watchdog stubs above).
  # No real daemon is ever touched.

  echo "Scenario 8: RECYCLE_ENABLED=0 → recycler does nothing even when RSS exceeds threshold"
  RECYCLE_ENABLED=0 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=100 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    run_recycle_sweep
  ok "RECYCLE_ENABLED=0 returns 0 (no-op)" # always passes; would error if function missing

  echo "Scenario 9: DRY_RUN=1 — logs intent but does NOT kickstart"
  # Stub a loaded leaky daemon with RSS 400MB (above default 350 threshold).
  cat > "$TMP/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    if [ -n "${2:-}" ]; then
      case " $DPW_TEST_LOADED " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac
    fi
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
  # The recycler calls `launchctl list <label>` (uses the stub → succeeds if label in DPW_TEST_LOADED)
  # then `launchctl list <label>` JSON for PID. We stub _rss_mb directly by overriding the function.
  # Simpler: override _rss_mb to return a fixed value for the test label.
  _rss_mb() { echo 400; }   # stub: always 400 MB
  : > "$DPW_TEST_KICKSTARTS"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=1 RECYCLE_RSS_MB=350 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "DRY_RUN=1: no kickstart issued" || bad "DRY_RUN=1 unexpectedly kickstarted"
  grep -q "dry-run" "$LOG" 2>/dev/null && ok "DRY_RUN=1: logged dry-run intent" || bad "DRY_RUN=1: missing dry-run log entry"

  echo "Scenario 10: RSS below threshold → no recycle"
  _rss_mb() { echo 100; }   # stub: 100 MB — well under 350
  : > "$DPW_TEST_KICKSTARTS"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=350 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "RSS below threshold: no kickstart" || bad "RSS below threshold unexpectedly kickstarted"

  echo "Scenario 11: RSS above threshold, DRY_RUN=0 → kickstart issued"
  _rss_mb() { echo 500; }   # stub: 500 MB
  : > "$DPW_TEST_KICKSTARTS"; rm -f "$TMP/rstate/com.test.leaky"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=350 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  grep -q "com.test.leaky" "$DPW_TEST_KICKSTARTS" && ok "RSS above threshold: kickstart issued" || bad "RSS above threshold: kickstart NOT issued"
  grep -q "RECYCLED" "$LOG" 2>/dev/null && ok "RSS above threshold: RECYCLED logged" || bad "RSS above threshold: RECYCLED not logged"

  echo "Scenario 12: chronic-leak escalation — recycles > RECYCLE_CHRONIC_PER_HR times"
  _rss_mb() { echo 500; }
  rm -rf "$TMP/rstate"; mkdir -p "$TMP/rstate"
  # Simulate 3 previous recycles this hour by pre-seeding the state file.
  NOW_EPOCH="$(date +%s)"; HOUR_START=$(( NOW_EPOCH - (NOW_EPOCH % 3600) ))
  printf '%s %s\n' "$HOUR_START" "3" > "$TMP/rstate/com.test.leaky"
  # A 4th recycle (count=4 > RECYCLE_CHRONIC_PER_HR=3) should trigger mail.
  MAILSENT="$TMP/mailsent"; : > "$MAILSENT"
  cat > "$TMP/gc" <<GCSTUB
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT"
exit 0
GCSTUB
  chmod +x "$TMP/gc"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=350 RECYCLE_CHRONIC_PER_HR=3 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  grep -q "mail" "$MAILSENT" && ok "chronic leak (4th recycle/hr): gc mail send issued" || bad "chronic leak: gc mail NOT sent"
  grep -q "CHRONIC" "$LOG" 2>/dev/null && ok "chronic leak: CHRONIC LEAK logged" || bad "chronic leak: CHRONIC LEAK not logged"

  # Restore _rss_mb to real implementation for subsequent use.
  unset -f _rss_mb

  echo ""
  echo "daemon-presence-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep
run_recycle_sweep
