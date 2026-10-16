#!/usr/bin/env bash
# dolt-hang-watchdog.sh (ga-pjrjo) — detect a HUNG Dolt server and restart it.
#
# WHY: the process keeper only catches Dolt *death*. A HANG (process alive + port
# listening, but workers stuck mid-query → accept-loop stalls → back_log fills →
# "max waiting connections reached, client rejected" → every query dropped) is
# invisible to a death-based keeper. On 2026-06-14 such a hang took down the whole
# data plane (painel/gc/bd/gate) and sat ~17 min until a human noticed.
# (See memory: dolt-hang-worker-stall-backlog-exhaustion-incident.)
#
# WHAT: probe real serve-ability via `gc dolt health` (bounded by timeout). A hung
# server makes that hang (→ timeout) or report unreachable. Restart ONLY after
# MAX_STRIKES consecutive failing probes (avoids false-positive restart storms on a
# transient blip).
#
# HOW IT RESTARTS (ga-fzt548): `gc dolt restart` only — the engine stops Dolt with a
# plain SIGTERM (SIGKILL only as its own last-resort fallback). This script sends NO
# signal to Dolt itself. The old pre-restart `kill -QUIT` (for a goroutine dump) is
# opt-in now: DOLT_DUMP=1. It is OFF by default because SIGQUIT is not a dump-and-
# continue on a Go server — it terminates it — and the city's doctrine forbids it.
#
# AT MOST ONE RESTART PER BACKOFF WINDOW (ga-fzt548): a confirmed hang is allowed to
# restart Dolt once; the next one is held for RESTART_BACKOFF_MIN (30 min), then
# 2x, 4x ... up to RESTART_BACKOFF_MAX, and every held restart escalates (once per
# ESCALATE_REPEAT) instead of looping. Measured in this script's own log on 2026-09-24:
# 6 attempts in 16 min (13:04:47 -> 13:20:48, one every ~3 min). Dolt was down on a full
# disk and the engine REFUSED every restart ("recent Dolt log shows ENOSPC"), so each
# cycle was 3 strikes -> refused restart -> "STILL unhealthy" -> a fresh page, forever.
# Retrying a restart the engine keeps refusing is not recovery, it is noise.
#
# Kill switch: DOLT_WATCHDOG_ENABLED=0 → probe + log only, never restart.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"

# ga-0bjqix: canonical PID resolution (dolt.pid + basename+LISTEN verification,
# never a bare process-table sort). See dolt-pid-lib.sh.
_DHW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=dolt-pid-lib.sh
source "$_DHW_SCRIPT_DIR/dolt-pid-lib.sh"
# ga-153cq: LOG/STRIKES overridable so a dry run can use scratch state. They were
# hardcoded, which made even a DRY RUN unsafe: the strike counter is incremented
# BEFORE the restart decision, so exercising this script against the live counter
# would push it toward MAX_STRIKES and arm a genuine restart on the next real
# sweep. "You cannot test it without risking the outage it causes" is why 87
# restarts happened with no test ever written.
LOG="${DOLT_WATCHDOG_LOG:-$CITY/.gc/logs/dolt-hang-watchdog.log}"
# ga-fzt548: the state that DECIDES a restart (strikes, CPU-veto counter, restart
# history) lives under .gc/runtime, not /tmp. /tmp is wiped on reboot and by the OS's
# periodic cleaner, so a counter kept there silently forgets — and a restart history
# that forgets is a backoff that never holds. (LASTPID_FILE below stays in /tmp on
# purpose: it is only the forensic PID baseline, and forgetting it at reboot is right.)
STATE_DIR="${DOLT_WATCHDOG_STATE_DIR:-$CITY/.gc/runtime}"
STRIKES="${DOLT_WATCHDOG_STRIKES_FILE:-$STATE_DIR/dolt-hang-watchdog.strikes}"
MAX_STRIKES="${DOLT_WATCHDOG_MAX_STRIKES:-3}"
PROBE_TIMEOUT="${DOLT_WATCHDOG_PROBE_TIMEOUT:-12}"
ENABLED="${DOLT_WATCHDOG_ENABLED:-1}"
DOLT_PORT="${BEADS_DOLT_PORT:-52756}"            # live Dolt server port
# ga-153cq: 12 -> 25. This bound decides "alive but slow" vs "dead", so it has to
# sit ABOVE legitimate worst-case latency or it cannot separate them. Kept well
# under the 60s launchd StartInterval so runs never overlap. Not raised further:
# the 12s bound demonstrably DID serve SELECT 1 through 1,879 saturation events,
# up to 207% CPU — so this is headroom for the degraded regime, not a rewrite of
# a bound that was working.
SERVE_CONFIRM_TIMEOUT="${DOLT_WATCHDOG_SERVE_CONFIRM:-25}"

# ga-153cq: CPU veto on the destructive path (see the long note at the restart
# site). CPU_ALIVE_PCT is deliberately LOW: the claim being tested is only "is
# this process doing work at all", and a true deadlock/worker-stall sits at ~0%.
# 20% is far above idle noise and far below the 50-207% seen in real saturation.
CPU_ALIVE_PCT="${DOLT_WATCHDOG_CPU_ALIVE_PCT:-20}"
CPU_VETO_MAX="${DOLT_WATCHDOG_CPU_VETO_MAX:-5}"
CPU_VETO_FILE="${DOLT_WATCHDOG_CPU_VETO_FILE:-$STATE_DIR/dolt-hang-watchdog.cpuveto}"

# ga-fzt548: restart BACKOFF + escalation (see the gate at the restart site).
# RESTART_STATE holds "<restarts in this episode> <epoch of the last restart>";
# ESCALATE_STAMP holds the epoch of the last escalation (dedupe only — it never gates
# a restart). An episode ends after RESTART_RESET_AFTER seconds with no restart.
RESTART_STATE="${DOLT_WATCHDOG_RESTART_STATE_FILE:-$STATE_DIR/dolt-hang-watchdog.restarts}"
ESCALATE_STAMP="${DOLT_WATCHDOG_ESCALATE_STAMP_FILE:-$STATE_DIR/dolt-hang-watchdog.escalated}"
RESTART_BACKOFF_MIN="${DOLT_WATCHDOG_RESTART_BACKOFF_MIN:-1800}"     # 30 min between restarts
RESTART_BACKOFF_MAX="${DOLT_WATCHDOG_RESTART_BACKOFF_MAX:-21600}"    # doubling stops at 6 h
RESTART_RESET_AFTER="${DOLT_WATCHDOG_RESTART_RESET_AFTER:-$RESTART_BACKOFF_MAX}"
ESCALATE_REPEAT="${DOLT_WATCHDOG_ESCALATE_REPEAT:-3600}"             # re-page at most hourly
# Seconds to let Dolt come up before the post-restart probe (test seam; 5 in production).
POST_RESTART_WAIT="${DOLT_WATCHDOG_POST_RESTART_WAIT:-5}"
# Opt-in goroutine dump. 1 = send SIGQUIT before the restart. ⚠️ That EXITS Dolt (Go's
# default SIGQUIT is dump-then-terminate); it is only ever reached after a confirmed
# hang the backoff gate has already cleared for restart. Default OFF (ga-fzt548).
DOLT_DUMP="${DOLT_DUMP:-0}"
# ga-153cq (gate attempt 3 FAIL, reviewer right a third time in this same file):
# the CPU reading itself was the one remaining unmockable input. dolt_cpu_pct()
# did a raw, unscoped process-table PID lookup with no override — so the
# selftest's veto-branch assertion only passed when the REVIEW HOST happened to
# have a live Dolt process, and would silently fail to even exercise the veto
# branch (not "fail loud" — just never reach it) on a host without one: a bare
# CI box, or mid-outage when Dolt is actually down, exactly when this script
# matters most. Test-only seam, same shape as every other override above: unset
# in production (real dolt_server_pid() lookup, unchanged), set by the selftest to a
# controlled, always-alive PID (its own $$) so the assertion is hermetic instead
# of host-state-contingent.
CPU_PID_OVERRIDE="${DOLT_WATCHDOG_CPU_PID:-}"

# ga-153cq (gate attempt 2 FAIL, reviewer was right again): DRY_RUN was only
# gated at the kill -QUIT decision point, deep in the script. But STRIKES and
# CPU_VETO_FILE are also mutated in THREE other places this file can exit
# from — the healthy-recovery branch, the saturation branch, and the strike
# counter's own write — and each ran unconditionally regardless of DRY_RUN. A
# flag that promises "side-effect-free end to end" has to be consulted at
# EVERY mutation, not just the destructive one, or the promise is only as
# true as whichever branch was last audited. One variable, one helper, one
# call-site pattern (`if is_dry_run`) used at every write below — grep for it
# to audit coverage; there are exactly 5 (probe_ok recovery, saturation
# recovery, strike write, veto/restart, PID-change forensic capture) and the
# selftest asserts that count.
DRY_RUN="${DOLT_WATCHDOG_DRY_RUN:-0}"
is_dry_run() { [ "$DRY_RUN" = "1" ]; }

# ga-xyhl9d (sling ga-oyw1tw): PID-change/death forensic snapshot.
#
# WHY: the 2026-09-25 00:26:43 Dolt death left NO trace anywhere (no Go panic
# in dolt.log, no jetsam/highwater kill, no watchdog strike) because the
# separate process-keeper already respawned it in ~14s — well inside this
# watchdog's ~60-90s launchd cadence, so the very next probe here just saw a
# HEALTHY (if different) server and cleared state normally. A hang-focused
# probe only ever answers "healthy now" or "hung now"; it has no memory of
# which PID it last saw, so a fast death+respawn is invisible to it BY
# CONSTRUCTION, not bad luck. Mayor's decision (ga-xyhl9d comment, 2026-09-25
# 04:01, option (b)): track the last-seen PID across invocations and capture
# a read-only forensic snapshot the INSTANT it changes or disappears — turns
# the next death into proof instead of a postmortem hypothesis. This adds NO
# new restart/kill path; it only reads and writes a plain log file.
LASTPID_FILE="${DOLT_WATCHDOG_LASTPID_FILE:-/tmp/dolt-hang-watchdog.lastpid}"
DEATH_LOG_DIR="${DOLT_WATCHDOG_DEATH_LOG_DIR:-$CITY/.gc/logs}"

# Read-only capture: everything here only READS system/log state and writes
# ONE new file under DEATH_LOG_DIR. Never signals or restarts anything.
#
# Every section that embeds text we do not control is bounded per line (SNAP_LINE_MAX
# / SNAP_PS_LINE_MAX) and, for ps, per count. Measured 2026-09-25: an unbounded
# `ps -ef | grep -i dolt` matched every `claude` agent session — each one carries its
# whole system prompt (which mentions "dolt") in argv, ~100 KB per line — and made a
# single snapshot 1.1 MB, 90% of the file, all of it burying the dolt/supervisor rows
# this file exists to show. Snapshots are never rotated and PID changes cluster (a
# flapping night writes many), on a disk that has already run out of space once.
SNAP_LINE_MAX=1000
SNAP_PS_LINE_MAX=240
SNAP_PS_MAX_LINES=120
SNAP_LOG_MAX_LINES=1000
# ga-fctr6g: TOTAL budget (seconds) for the whole forensic `log show` window, shared by its
# chunks -- NOT a per-query cap. Kept at 30 so the snapshot's share of the launchd tick
# (StartInterval=60) is exactly what ga-xyhl9d shipped; the fix reorders the work inside
# that budget instead of growing it.
SNAP_LOG_TIMEOUT="${DOLT_WATCHDOG_SNAP_LOG_TIMEOUT:-30}"
# Window = these chunk lengths in seconds, NEWEST FIRST (default 30+30+60+60 = the same 3m).
SNAP_LOG_CHUNKS_DEFAULT="30 30 60 60"
SNAP_LOG_CHUNKS="${DOLT_WATCHDOG_SNAP_LOG_CHUNKS:-$SNAP_LOG_CHUNKS_DEFAULT}"
SNAP_LOG_PREDICATE='eventMessage contains "dolt" OR eventMessage contains "memorystatus" OR eventMessage contains "jetsam" OR eventMessage contains "tcp_close" OR eventMessage contains "SIGKILL" OR eventMessage contains "SIGQUIT" OR eventMessage contains "SIGTERM"'
SNAP_BURST_TIMEOUT="${DOLT_WATCHDOG_SNAP_BURST_TIMEOUT:-20}"
SNAP_END_MARK="=== end of snapshot ==="

# `log show --start/--end` read local time; %z pins the instant (no DST/timezone ambiguity).
_snap_fmt() { date -r "$1" '+%Y-%m-%d %H:%M:%S%z'; }

# ga-fctr6g: the forensic `log show` window, asked for as NEWEST-FIRST chunks under ONE total
# budget (SNAP_LOG_TIMEOUT), with a coverage statement per chunk and one for the whole window.
#
# WHY: a single `log show --last 3m` with SNAP_LOG_PREDICATE took 39s cold / 33s warm at the
# load that goes WITH a Dolt death (load 65-80 on 10 cores, measured 2026-09-25) -- over a 30s
# cap -- while 1m took 9s and 30s took ~4s. And `log show` prints OLDEST-FIRST: a timeout keeps
# the start of the window and loses the END (a 3s cap on `--last 3m` returned events only up to
# ~10s into the 180s window). The end of the window is the newest time -- the part nearest the
# death -- so the old single query failed worst exactly where the evidence is. Chunked and
# newest-first, the last minute is secured before the older minutes are touched, and a chunk
# that does not finish says how far it got instead of an undifferentiated "PARTIAL".
# (Adjacent --start/--end chunks were checked to partition a window exactly: 904 events in
# three 60s chunks == 904 in one 180s query, 0 missing, 0 duplicated.)
#
# The newest chunk omits --end: an --end at the second-truncated anchor would drop the events
# of the current second. Older chunks end exactly where the next-newer one starts.
# Output (to stdout): a chunk table, a `coverage:` line, then the events oldest-chunk-first.
capture_log_window() {
  local -a _clen=() _cwin=() _cstat=() _cbody=()
  local _spec="$SNAP_LOG_CHUNKS" _tok _bad=0 _n=0 _tot=0 _i _cum=0 _anchor _t0 _tc _remain _len
  local _s _e _elabel _out _rc _body _cnt _last _msg _cov=0 _open=1 _lg _lg_n _budget="$SNAP_LOG_TIMEOUT"

  # Under `set -u` a non-numeric budget would abort inside $(( )) and kill the snapshot half-written.
  case "$_budget" in
    ''|*[!0-9]*) echo "(!! DOLT_WATCHDOG_SNAP_LOG_TIMEOUT='${SNAP_LOG_TIMEOUT}' is not whole seconds -- using 30)"; _budget=30 ;;
  esac
  _budget=$((10#$_budget))   # 10# : a leading zero (08) must not be read as octal
  for _tok in $_spec; do
    case "$_tok" in ''|*[!0-9]*|0*) _bad=1 ;; esac   # 0* also rejects 030 (octal inside $(( )))
    _n=$((_n + 1))
  done
  if [ "$_bad" -eq 1 ] || [ "$_n" -eq 0 ]; then
    echo "(!! DOLT_WATCHDOG_SNAP_LOG_CHUNKS='${SNAP_LOG_CHUNKS}' is not a list of positive whole seconds -- using the default '${SNAP_LOG_CHUNKS_DEFAULT}')"
    _spec="$SNAP_LOG_CHUNKS_DEFAULT"
  fi
  _n=0
  for _tok in $_spec; do _clen[$_n]="$_tok"; _tot=$((_tot + _tok)); _n=$((_n + 1)); done

  _anchor="$(date +%s)"; _t0="$_anchor"
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _len="${_clen[$_i]}"
    _s=$((_anchor - _cum - _len)); _e=$((_anchor - _cum)); _cum=$((_cum + _len))
    if [ "$_i" -eq 0 ]; then _elabel="now"; else _elabel="$(date -r "$_e" '+%H:%M:%S')"; fi
    _cwin[$_i]="$(date -r "$_s" '+%H:%M:%S') .. ${_elabel}"
    _remain=$((_budget - ($(date +%s) - _t0)))
    if [ "$_remain" -lt 1 ]; then    # `timeout 0` would mean NO limit, so never pass it
      _open=0; _cstat[$_i]="NOT ATTEMPTED -- the ${_budget}s total budget was already spent on newer chunks"; _cbody[$_i]=""
      _i=$((_i + 1)); continue
    fi
    _tc="$(date +%s)"
    if [ "$_i" -eq 0 ]; then
      _out="$(timeout "$_remain" log show --start "$(_snap_fmt "$_s")" --predicate "$SNAP_LOG_PREDICATE" 2>&1)"; _rc=$?
    else
      _out="$(timeout "$_remain" log show --start "$(_snap_fmt "$_s")" --end "$(_snap_fmt "$_e")" --predicate "$SNAP_LOG_PREDICATE" 2>&1)"; _rc=$?
    fi
    # Drop only the constant preamble; events can span several lines, so everything else stays.
    _body="$(printf '%s\n' "$_out" | grep -v -E '^$|^Filtering the log data using|^Timestamp +Thread +Type' || true)"
    _cnt="$(printf '%s\n' "$_body" | grep -c . || true)"
    if [ "$_rc" -eq 0 ]; then
      _cstat[$_i]="COMPLETE (${_cnt} lines, $(($(date +%s) - _tc))s)"; _cbody[$_i]="$_body"
      [ "$_open" -eq 1 ] && _cov=$((_cov + _len))
    elif [ "$_rc" -eq 124 ]; then
      _open=0
      _last="$(printf '%s\n' "$_out" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' | tail -1 | cut -c1-23)"
      if [ -n "$_last" ]; then
        _cstat[$_i]="PARTIAL -- log show TIMED OUT after ${_remain}s; events seen only up to ${_last} (${_cnt} lines), everything from there to ${_elabel} is NOT covered (log show prints oldest-first: a timeout loses the NEWEST end)"
      else
        _cstat[$_i]="PARTIAL -- log show TIMED OUT after ${_remain}s with NO events out; how far it got is UNKNOWN, the whole chunk is NOT covered"
      fi
      _cbody[$_i]="$_body"
    else
      _open=0
      _msg="$(printf '%s\n' "$_out" | head -1 | cut -c1-200)"
      _cstat[$_i]="FAILED (log show FAILED rc=${_rc}: ${_msg}) -- these lines are an ERROR, not events; the chunk is NOT covered"
      _cbody[$_i]=""
    fi
    _i=$((_i + 1))
  done

  echo "window: $(_snap_fmt $((_anchor - _tot))) .. now (anchored $(_snap_fmt "$_anchor")); ${_tot}s in ${_n} chunks, newest first, ${_budget}s total budget"
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    echo "  chunk $((_i + 1)) [${_clen[$_i]}s] ${_cwin[$_i]}: ${_cstat[$_i]}"
    _i=$((_i + 1))
  done
  if [ "$_cov" -eq "$_tot" ]; then
    echo "coverage: all ${_tot}s COMPLETE"
  elif [ "$_cov" -gt 0 ]; then
    echo "coverage: newest ${_cov}s COMPLETE; the older $((_tot - _cov))s is NOT fully covered (see the chunks above)"
  else
    echo "coverage: NONE -- not even the newest chunk is COMPLETE (see the chunks above)"
  fi

  # Events oldest chunk first (chunks are disjoint in time, so this is chronological). The cap
  # keeps the NEWEST lines and says so, exactly as before ga-fctr6g.
  _lg=""; _i=$((_n - 1))
  while [ "$_i" -ge 0 ]; do
    [ -n "${_cbody[$_i]:-}" ] && _lg="${_lg}${_cbody[$_i]}"$'\n'
    _i=$((_i - 1))
  done
  _lg_n="$(printf '%s' "$_lg" | grep -c . || true)"
  [ "$_lg_n" -gt "$SNAP_LOG_MAX_LINES" ] && echo "(!! TRUNCATED: showing the newest ${SNAP_LOG_MAX_LINES} of ${_lg_n} matching lines -- the oldest $((_lg_n - SNAP_LOG_MAX_LINES)) were dropped)"
  printf '%s' "$_lg" | tail -"$SNAP_LOG_MAX_LINES" | cut -c1-"$SNAP_LINE_MAX"
}
# Every `log show` section below must tell the reader when its output is NOT a valid window:
# exit 124 = timeout (partial output; `log show` prints oldest-first so it is the NEWEST end
# that is missing), any other nonzero = the command itself failed (what it printed is an error
# message, not log events). A section that handles only one of the two -- or none -- prints a
# failure in the same shape as "nothing happened", and this file exists to be believed about
# exactly that.
capture_death_snapshot() {
  local _old="$1" _new="$2" _ts _out _ps _ps_n _bs _bs_rc _wrc
  _ts="$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$DEATH_LOG_DIR" 2>/dev/null || true
  # ${_ts} has 1-second resolution and `>` truncates: two captures in the same second
  # (overlapping runs, or a flapping Dolt) would overwrite each other and leave ONE file
  # for TWO events, with nothing saying so. The run's PID makes the name unique per run.
  _out="$DEATH_LOG_DIR/dolt-death-${_ts}-$$.txt"
  {
    echo "=== dolt-hang-watchdog PID-change forensic snapshot ==="
    echo "captured_at:  $(ts)"
    echo "previous_pid: ${_old:-<none>}"
    echo "current_pid:  ${_new:-<none>}"
    echo
    echo "--- dolt-state.json (current supervisor record) ---"
    { cat "$CITY/.gc/runtime/packs/dolt/dolt-state.json" 2>/dev/null || echo "(not found)"; } \
      | cut -c1-"$SNAP_LINE_MAX" | head -20
    echo
    echo "--- log show, newest-first chunks: dolt / memorystatus / jetsam / tcp_close / signals ---"
    # Truncation, timeout and failure are stated IN the file, never silent -- per chunk and
    # for the window as a whole (see capture_log_window). Under memory pressure (the
    # incident's own condition) jetsam/memorystatus lines alone fill the line cap and the
    # oldest are what drops; a reader must be able to tell "nothing happened before T" from
    # "the file stopped looking before T".
    capture_log_window
    echo
    echo "--- ps: supervisor + dolt process tree (snapshot at capture time) ---"
    # Single-pass awk (header + rows mentioning dolt), NOT `{ head -1; grep; }`: on a pipe
    # `head` reads a whole block rather than one line and the grep never sees what it
    # swallowed -- measured 40/40 runs losing the dolt sql-server row against a fast writer,
    # so whether the rows survived depended on how `ps` happened to chunk its output.
    # `d[o]lt` keeps awk's own argv from matching itself in the process table.
    # Captured, not streamed, so the cap and an empty result can be STATED like the log
    # section's: 0 rows = `ps` itself failed (the header row alone is 1), which is UNKNOWN,
    # not "no dolt process".
    _ps="$(ps -ef 2>/dev/null | awk 'NR == 1 || tolower($0) ~ /d[o]lt/' | cut -c1-"$SNAP_PS_LINE_MAX")"
    _ps_n="$(printf '%s\n' "$_ps" | grep -c . || true)"
    [ "$_ps_n" -eq 0 ] && echo "(!! ps returned NO rows -- the process tree is UNKNOWN, not empty)"
    [ "$_ps_n" -gt "$SNAP_PS_MAX_LINES" ] && echo "(!! TRUNCATED: showing the first ${SNAP_PS_MAX_LINES} of ${_ps_n} ps rows -- $((_ps_n - SNAP_PS_MAX_LINES)) were dropped)"
    printf '%s\n' "$_ps" | head -"$SNAP_PS_MAX_LINES"
    echo
    echo "--- last 50 lines of dolt.log ---"
    { tail -50 "$CITY/.gc/runtime/packs/dolt/dolt.log" 2>/dev/null || echo "(not found)"; } \
      | cut -c1-"$SNAP_LINE_MAX"
    echo
    echo "--- short-lived 'dolt' CLI process count in the last 60s (ga-oyw1tw burst lead) ---"
    # This number is the evidence for the burst hypothesis, so it must never be a number
    # when the query did not actually answer. A bare `| grep -c .` counted the column-header
    # line ("1" for a window with zero events) and the error line of a failed query ("1"),
    # and a timed-out query printed "0" -- all three read as "no burst", the one conclusion
    # a query that could not run must not support, under the same memory pressure that made
    # it time out. So: count only real event lines (they start with a timestamp), and say
    # UNAVAILABLE when `log show` timed out (124) or failed (any other nonzero).
    _bs="$(timeout "$SNAP_BURST_TIMEOUT" log show --last 1m --predicate \
      'eventMessage contains "Retrieve User by ID" AND processImagePath contains "dolt"' \
      2>&1)"
    _bs_rc=$?
    if [ "$_bs_rc" -eq 124 ]; then
      echo "count: UNAVAILABLE (log show TIMED OUT after ${SNAP_BURST_TIMEOUT}s -- this is NOT 0 events, the burst question is UNANSWERED)"
    elif [ "$_bs_rc" -ne 0 ]; then
      echo "count: UNAVAILABLE (log show FAILED rc=${_bs_rc}: $(printf '%s\n' "$_bs" | head -1 | cut -c1-200) -- this is NOT 0 events, the burst question is UNANSWERED)"
    else
      echo "count: $(printf '%s\n' "$_bs" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' || true)"
    fi
    echo
    echo "--- exit status/signal of the previous PID, if the supervisor recorded one ---"
    echo "(no such record is currently exposed by the supervisor; dolt-state.json above only has the CURRENT pid/started_at)"
    echo "$SNAP_END_MARK"
  } > "$_out" 2>&1
  _wrc=$?
  printf '%s' "$_out"
  # "captured" must mean the file is whole. The disk this runs on has already filled once
  # (no space left on device); a redirect that could not open the file, or a write that
  # died midway, used to fall through to printf of the path and the caller logged
  # "snapshot captured" for a file that was absent, empty, or cut short. The end-mark is
  # the last line written, so its absence means the write did not finish.
  [ "$_wrc" -eq 0 ] && [ "$(tail -1 "$_out" 2>/dev/null)" = "$SNAP_END_MARK" ]
}

# Compares the PID this run observes against the PID the LAST run recorded.
# A change (including a disappearance) fires capture_death_snapshot(); the
# baseline is then advanced to the current observation either way. First-ever
# observation (no baseline on disk) never fires — there's nothing to diff.
check_pid_change() {
  local _cur _prev _changed=0
  _cur="${DOLT_WATCHDOG_PID_OVERRIDE-$(dolt_server_pid || true)}"
  _prev="$(cat "$LASTPID_FILE" 2>/dev/null || true)"

  # dolt_server_pid's own contract (dolt-pid-lib.sh): empty = UNKNOWN, not "no server".
  # Its lsof/ps verification can miss a live server under exactly the saturation this
  # snapshot exists for. If the PID recorded last run still answers `kill -0` (signal 0
  # never delivers anything), the server did not go anywhere: keep the baseline and say the
  # lookup was unknown, instead of logging a "disappearance", writing a snapshot and
  # deleting the baseline -- which would also hide a real death+respawn that lands before
  # the next run (the next run would find no baseline to diff against).
  if [ -z "$_cur" ] && [ -n "$_prev" ] && kill -0 "$_prev" 2>/dev/null; then
    log "Dolt PID lookup came back EMPTY but the previous PID ${_prev} is still alive -- treating as UNKNOWN (resolver miss), baseline kept at ${_prev}, no snapshot"
    return 0
  fi

  [ -n "$_prev" ] && [ "$_prev" != "$_cur" ] && _changed=1

  if is_dry_run; then
    if [ "$_changed" -eq 1 ]; then
      log "DRY-RUN: Dolt PID changed (${_prev} -> ${_cur:-<none>}) -- would capture forensic snapshot in ${DEATH_LOG_DIR}. Not written; lastpid left at ${_prev} on disk."
    fi
  else
    if [ "$_changed" -eq 1 ]; then
      local _snap _snap_rc
      _snap="$(capture_death_snapshot "$_prev" "$_cur")"; _snap_rc=$?
      if [ "$_snap_rc" -eq 0 ]; then
        log "Dolt PID CHANGED (${_prev} -> ${_cur:-<none>}) -- forensic snapshot captured: ${_snap}"
      else
        log "Dolt PID CHANGED (${_prev} -> ${_cur:-<none>}) -- forensic snapshot capture FAILED or INCOMPLETE (rc=${_snap_rc}; disk full or DEATH_LOG_DIR unwritable?): ${_snap:-<no path>}"
      fi
    fi
    if [ -n "$_cur" ]; then
      printf '%s' "$_cur" > "$LASTPID_FILE" 2>/dev/null \
        || log "WARN: could not write the Dolt PID baseline ${LASTPID_FILE} -- the next run will diff against a stale or missing baseline"
    else rm -f "$LASTPID_FILE" 2>/dev/null || true; fi
  fi
}

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

# Healthy iff `gc dolt health --json` returns within PROBE_TIMEOUT, parses, and
# reports .server.reachable == true. timeout rc!=0 (hang) or reachable!=true → fail.
probe_ok() {
  local out rc
  out=$(cd "$CITY" && GC_CITY="$CITY" timeout "$PROBE_TIMEOUT" gc dolt health --json 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && return 1
  printf '%s' "$out" | jq -e '.server.reachable == true' >/dev/null 2>&1 || return 1
  return 0
}

# A failed health-probe under heavy CPU load is usually SATURATION (Dolt busy/slow),
# NOT a hang — and restarting a busy-but-serving Dolt is disruptive + futile (the
# load returns immediately). Confirm with a direct raw `SELECT 1`: if Dolt actually
# serves it, the server is ALIVE (the health probe just timed out under load) → not
# a hang, don't strike/restart. A TRUE hang (deadlock / worker-stall, typically ~0%
# CPU) fails this too → we proceed to restart. (Mayor 2026-06-15: stop false-restarts
# on Dolt-CPU spikes — the ga-8smq3 saturation that recurs all day.)
dolt_actually_serving() {
  # ga-153cq: connect_timeout must track SERVE_CONFIRM_TIMEOUT, not sit below it.
  # It used to be a hardcoded 8 under a 12s outer `timeout`, which made the outer
  # bound decorative: the connect gave up at 8s and the extra 4s were never usable.
  # Two bounds on the same wait must not disagree, or raising the visible one
  # changes nothing — the invisible one still decides.
  local _ct=$(( SERVE_CONFIRM_TIMEOUT > 4 ? SERVE_CONFIRM_TIMEOUT - 4 : SERVE_CONFIRM_TIMEOUT ))
  timeout "$SERVE_CONFIRM_TIMEOUT" python3 - "$DOLT_PORT" "$_ct" <<'PY' 2>/dev/null
import sys
try:
    import pymysql
    c = pymysql.connect(host='127.0.0.1', port=int(sys.argv[1]), user='root',
                        connect_timeout=int(sys.argv[2]))
    cur = c.cursor(); cur.execute('SELECT 1'); cur.fetchone()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# ga-153cq: CPU of the live dolt sql-server, as a whole number ("" if unknown).
# This is the discriminator the comment above ALREADY names as what separates a
# true hang from saturation ("typically ~0% CPU") — but which the code only ever
# read on the branch where it had already decided NOT to restart. Reading it here
# lets the destructive branch use it too.
dolt_cpu_pct() {
  local _pid _cpu
  _pid="$CPU_PID_OVERRIDE"
  [ -z "$_pid" ] && _pid=$(dolt_server_pid)
  [ -z "$_pid" ] && { printf ''; return; }
  _cpu=$(ps -p "$_pid" -o %cpu= 2>/dev/null | tr -d ' ')
  [ -z "$_cpu" ] && { printf ''; return; }
  printf '%s' "${_cpu%%.*}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ga-fzt548 — RESTART BACKOFF. A confirmed hang may restart Dolt ONCE per window.
#
# Why: on 2026-09-24 this script attempted a restart at 13:04, 13:08, 13:11, 13:14,
# 13:17 and 13:20 — six times in sixteen minutes — against a Dolt that was down on a
# full disk. `gc dolt restart` refused every one (ENOSPC guard), each attempt ended in
# "STILL unhealthy" and a fresh page, and nothing in the script remembered it had just
# tried. A remedy that fires every three minutes and never works is a loop, and the way
# out is not a smarter probe: it is a ceiling on the remedy plus a human in the loop.
#
# The record counts restart ATTEMPTS, not successes: an attempt the engine refuses still
# spends the window (retrying it sooner IS the 24/09 loop). A human who has fixed the
# cause does not wait for the window — `gc dolt restart` by hand is always available.
#
# Window after the k-th restart of an episode: RESTART_BACKOFF_MIN * 2^(k-1), capped at
# RESTART_BACKOFF_MAX (30 min, 1 h, 2 h, 4 h, 6 h, 6 h ...). An episode ends after
# RESTART_RESET_AFTER seconds with no restart. A held restart is not dropped: strikes
# stay armed, so the restart happens on the first tick after the window opens.

# Seconds to hold the NEXT restart after the $1-th restart of an episode ($1 >= 1).
restart_backoff_for() {
  local _c="$1" _b="$RESTART_BACKOFF_MIN" _i
  for (( _i = 1; _i < _c; _i++ )); do
    _b=$(( _b * 2 ))
    [ "$_b" -ge "$RESTART_BACKOFF_MAX" ] && break
  done
  [ "$_b" -gt "$RESTART_BACKOFF_MAX" ] && _b="$RESTART_BACKOFF_MAX"
  [ "$_b" -lt "$RESTART_BACKOFF_MIN" ] && _b="$RESTART_BACKOFF_MIN"   # the floor is the contract
  printf '%s' "$_b"
}

# May we restart Dolt NOW? READ-ONLY (so it is safe under DRY_RUN): it decides, the
# caller writes. Sets, for the caller:
#   RG_VERDICT  allow | hold | unreadable
#   RG_COUNT    restarts so far in the current episode (0 = none / episode expired)
#   RG_LAST     epoch of the last restart ("" = none)
#   RG_WAIT     seconds until a restart is allowed (0 unless hold)
# Three states, never two: NO history (allow) / history says wait (hold) / cannot tell
# (unreadable). Unreadable is NOT "no history" — a restart is the destructive step, so
# when the record that would stop a loop cannot be read, the answer is the inert one.
restart_gate() {
  local _now _raw _count _last _extra _age _backoff
  _now=$(date +%s)
  RG_VERDICT=allow; RG_COUNT=0; RG_LAST=""; RG_WAIT=0
  # vazio (arquivo ausente) → nunca reiniciou: restart permitido; falhou/ilegível (existe mas não lê, está vazio, não tem exatamente "<n> <epoch>", ou o carimbo está no futuro) → INERTE: restart recusado e escalado, nunca tratado como "sem histórico"
  [ -e "$RESTART_STATE" ] || return 0
  _raw=$(cat "$RESTART_STATE" 2>/dev/null) || { RG_VERDICT=unreadable; return 0; }
  read -r _count _last _extra <<< "$_raw"
  case "$_count" in ''|*[!0-9]*) RG_VERDICT=unreadable; return 0 ;; esac
  case "$_last"  in ''|*[!0-9]*) RG_VERDICT=unreadable; return 0 ;; esac
  if [ -n "$_extra" ] || [ "${#_count}" -gt 9 ] || [ "${#_last}" -gt 12 ]; then RG_VERDICT=unreadable; return 0; fi
  _count=$(( 10#$_count )); _last=$(( 10#$_last ))
  [ "$_last" -gt "$_now" ] && { RG_VERDICT=unreadable; return 0; }   # clock stepped back / garbage

  _age=$(( _now - _last ))
  if [ "$_count" -eq 0 ] || [ "$_age" -ge "$RESTART_RESET_AFTER" ]; then return 0; fi   # no live episode
  RG_COUNT="$_count"; RG_LAST="$_last"
  _backoff=$(restart_backoff_for "$_count")
  if [ "$_age" -lt "$_backoff" ]; then RG_VERDICT=hold; RG_WAIT=$(( _backoff - _age )); fi
  return 0
}

# Persist "<count> <now>" ATOMICALLY (tmp + mv, so a kill mid-write can never leave a
# half-written history that restart_gate would have to call unreadable). rc != 0 = NOT
# persisted. Called BEFORE the restart is attempted, never after: a restart that gets
# killed mid-flight (launchd, a timeout, a crash) must still count, or the very loop
# this exists to stop can run unrecorded.
restart_record() {
  local _tmp="$RESTART_STATE.tmp.$$"
  mkdir -p "$(dirname "$RESTART_STATE")" 2>/dev/null || return 1
  if printf '%s %s\n' "$1" "$(date +%s)" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$RESTART_STATE" 2>/dev/null; then
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null
  return 1
}

# Remember that a human was paged (dedupe only; it never gates a restart). Best effort:
# a stamp that cannot be written makes the NEXT tick page again — the loud direction.
escalation_stamp() {
  mkdir -p "$(dirname "$ESCALATE_STAMP")" 2>/dev/null || true
  date +%s > "$ESCALATE_STAMP" 2>/dev/null \
    || log "WARN: could not write the escalation stamp ${ESCALATE_STAMP} — the next held tick will page again"
}

# Page ($1 = title, $2 = body) through the canonical path (mail to the Mayor + push), at
# most once per ESCALATE_REPEAT. Without the dedupe a held restart would page every 60 s
# for as long as the window lasts.
restart_escalate() {
  local _now _last
  _now=$(date +%s)
  # vazio (sem carimbo) → nunca escalou: escala agora; falhou/ilegível (não numérico, longo demais ou no futuro) → escala também: aqui o alarme É o estado inerte, um page a mais custa pouco e silêncio com o Dolt pendurado custa a cidade
  _last=$(cat "$ESCALATE_STAMP" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  [ "${#_last}" -gt 12 ] && _last=0
  _last=$(( 10#$_last ))
  if [ "$_last" -le "$_now" ] && [ $(( _now - _last )) -lt "$ESCALATE_REPEAT" ]; then
    log "escalation suppressed (already paged $(( _now - _last ))s ago, repeat every ${ESCALATE_REPEAT}s)"
    return 0
  fi
  # The stamp means "a human was PAGED", so it is written only after the page reports
  # success: escalate_emergency.py exits 1 when the push did not go out. A page that
  # failed must not read as one that happened, or the retry is silenced for the whole
  # ESCALATE_REPEAT with nobody told.
  if python3 "$CITY/scripts/escalate_emergency.py" \
       --class town-halted \
       --title "$1" \
       "$2" \
       >> "$LOG" 2>&1; then
    escalation_stamp
  else
    log "WARN: escalate_emergency.py FAILED to page — NOT stamping, so the next held tick pages again"
  fi
}

# Runs UNCONDITIONALLY, before any health decision: a death+respawn can
# complete well inside this watchdog's own polling interval, so probe_ok()
# below may see a healthy server on every single run and never know a death
# happened in between. This is the only place in the file that would notice.
check_pid_change

if probe_ok; then
  # ga-153cq: the veto counter must reset on recovery too. It counts CONSECUTIVE
  # vetoed confirmations; if it survived a healthy period it would carry stale
  # pressure into an unrelated future episode and exhaust the veto early —
  # turning a safety valve into a countdown to the very restart it prevents.
  #
  # ga-153cq (gate attempt 2): both clears below used to run unconditionally,
  # so DOLT_WATCHDOG_DRY_RUN=1 against an actually-healthy Dolt still zeroed
  # the real counters — a real mutation under a flag that promises none.
  # Gated like every other write site now (see is_dry_run() above).
  if is_dry_run; then
    [ -f "$STRIKES" ] && log "DRY-RUN: Dolt healthy — would clear $(cat "$STRIKES" 2>/dev/null) strike(s). Left on disk, not written."
    [ -f "$CPU_VETO_FILE" ] && log "DRY-RUN: Dolt healthy — would clear CPU veto counter ($(cat "$CPU_VETO_FILE" 2>/dev/null)). Left on disk, not written."
  else
    if [ -f "$STRIKES" ]; then log "Dolt healthy again — clearing $(cat "$STRIKES" 2>/dev/null) strike(s)."; rm -f "$STRIKES"; fi
    rm -f "$CPU_VETO_FILE" 2>/dev/null || true
  fi
  exit 0
fi

# Saturation guard: probe failed, but is Dolt actually serving? If a raw SELECT 1
# succeeds, it's busy/slow (saturation), NOT hung — don't strike, don't restart.
if dolt_actually_serving; then
  _cpu="$(dolt_cpu_pct)"
  log "Health-probe failed but Dolt SERVES a raw SELECT 1 (cpu=${_cpu:-?}%) — saturation, NOT a hang. Skipping strike/restart."
  # ga-153cq (gate attempt 2): same class as the probe_ok branch above — proven
  # serving means "clean slate" for real, but only when we're not simulating.
  if is_dry_run; then
    [ -f "$STRIKES" ] && log "DRY-RUN: saturation, not a hang — would clear $(cat "$STRIKES" 2>/dev/null) strike(s). Left on disk, not written."
    [ -f "$CPU_VETO_FILE" ] && log "DRY-RUN: saturation, not a hang — would clear CPU veto counter. Left on disk, not written."
  else
    [ -f "$STRIKES" ] && rm -f "$STRIKES"
    rm -f "$CPU_VETO_FILE" 2>/dev/null || true   # ga-153cq: proven serving = clean slate
  fi
  exit 0
fi

# ga-153cq (gate attempt 2 FAIL, reviewer was right): this write used to be
# unconditional, sitting well ABOVE the only DRY_RUN gate that existed at the
# time (the kill -QUIT decision point ~60 lines down). So every path that
# reached that gate had ALREADY advanced the real strike count on the same
# invocation — the dry-run report down there claiming "strikes ... left
# intact" was false. `n` (in-memory) is still computed and used below either
# way, to report/simulate what the count WOULD become; only persistence is
# conditional.
n=$(( $(cat "$STRIKES" 2>/dev/null || echo 0) + 1 ))
if is_dry_run; then
  log "DRY-RUN: would advance strike counter to ${n}/${MAX_STRIKES}. Not written — on-disk value left intact."
else
  # ga-fzt548: the file moved out of /tmp, so its directory is no longer guaranteed. A
  # strike that cannot be written never accumulates — which is the INERT outcome (no
  # restart) but a silent one; say so instead of failing quietly.
  mkdir -p "$(dirname "$STRIKES")" 2>/dev/null
  echo "$n" > "$STRIKES" 2>/dev/null \
    || log "WARN: could not write the strike counter ${STRIKES} — strikes will not accumulate, so no restart can happen until this is fixed"
fi
_strike_cpu="$(dolt_cpu_pct)"
# ga-153cq: record CPU on the STRIKE path too, not only on the saturation path.
# Until now CPU was logged only where we decided NOT to restart, so after 87 real
# restarts there is no way to tell, retroactively, how many killed a server that
# was merely busy. A number you only record when it doesn't matter is not evidence.
log "Dolt probe FAILED + raw query also failed (true unresponsiveness, strike ${n}/${MAX_STRIKES}, cpu=${_strike_cpu:-?}%)."
[ "$n" -lt "$MAX_STRIKES" ] && exit 0

if [ "$ENABLED" != "1" ]; then
  log "CONFIRMED hang (${n} strikes) but DOLT_WATCHDOG_ENABLED=0 — probe-only, NOT restarting."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# ga-153cq — CPU VETO on the destructive step.
#
# Doctrine (CLAUDE.md) says NEVER kill -QUIT the Dolt PID: sent to a live server
# it vanished on the spot and took the city down. ga-153cq kept a pre-restart
# SIGQUIT in this path, arguing that the restart was the only automated recovery
# for a true hang and that SIGQUIT exits Dolt anyway. ga-fzt548 overturned that: the
# recovery is `gc dolt restart` alone (the engine's own SIGTERM stop), SIGQUIT is
# opt-in via DOLT_DUMP=1, and the restart itself is capped by a backoff (restart_gate).
# The veto below is unchanged — it is still what keeps routine saturation from being
# "confirmed" as a hang in the first place.
#
# But "confirmed" has to mean confirmed. Measured on the live log before this
# change: 1,879 saturation events (health probe failed, raw SELECT 1 still
# served — at up to 207% CPU) vs 319 strikes and 87 actual restarts. The health
# probe failing is ROUTINE; the single thing standing between routine saturation
# and an automatic restart of the city's data plane is one bounded SELECT 1.
# When Dolt degrades hard (measured this same night: bd latency 30-74s before
# the ga-9ae7o vendor fix, 150-257ms after), that SELECT 1 can miss its bound
# while the server is alive and working — and the old code then killed it.
#
# So apply the discriminator this file ALREADY documents at dolt_actually_serving
# ("a TRUE hang — deadlock/worker-stall — is typically ~0% CPU"). It was never
# actually consulted here. A process burning real CPU is doing work; killing it
# is the futile-and-disruptive restart the saturation guard exists to prevent.
#
# ⚠️ This VETO is deliberately not permanent: a spin-deadlock can burn CPU, so a
# veto that never yields would trade "kills a healthy server" for "never recovers
# a real hang" — the worse failure, and the one the bead's author warned about.
# After CPU_VETO_MAX consecutive vetoed confirmations we stop vetoing and let the
# restart proceed, escalating loudly first. Visible and counted, never silent.
_cpu_now="$(dolt_cpu_pct)"
_vetoes=$(cat "$CPU_VETO_FILE" 2>/dev/null || echo 0)

# ga-153cq FIX (gate attempt 1 FAIL, reviewer was right): the DRY_RUN gate used to
# sit 15 lines BELOW this point, guarding only the kill -QUIT. Everything from here
# to the restart ran unconditionally — so `DOLT_WATCHDOG_DRY_RUN=1` still wrote the
# real $CPU_VETO_FILE and still fired real notify's, including a P5 saying
# "restarting Dolt anyway" for a restart the dry run then never performed. That is
# the exact bug shape this whole change exists to remove (a claim asserted louder
# than what the code does), reintroduced by me one branch over, in the feature whose
# doc comment promised "without signalling or restarting anything".
#
# ⚠️ And my own verification MASKED it: the dry-run test passed
# DOLT_WATCHDOG_CPU_VETO_FILE explicitly, so the state write landed in scratch and
# looked clean. A test that supplies the override cannot discover that the override
# is REQUIRED. The selftest now asserts the no-override case.
#
# ga-153cq (gate attempt 2 FAIL): fixing THIS gate wasn't enough — the STRIKES
# write above and the two recovery branches earlier in the file had the exact
# same unconditional-mutation shape, just on a different variable. Reviewer
# caught it on the very next attempt. All four sites now share one helper
# (is_dry_run(), defined near the top) instead of four independent copies of
# the same env-var check, specifically so a future audit is "grep for the
# helper" instead of "re-read the whole file and hope nothing was missed" —
# which is exactly what missed these two sites the first time.
#
# So decide first, THEN act — with the dry run intercepting before any write or
# notify, while still reporting which branch it would have taken.
if is_dry_run; then
  if [ -n "$_cpu_now" ] && [ "$_cpu_now" -ge "$CPU_ALIVE_PCT" ] && [ "$_vetoes" -lt "$CPU_VETO_MAX" ]; then
    log "DRY-RUN: would VETO the restart — Dolt at ${_cpu_now}% CPU (>=${CPU_ALIVE_PCT}%), veto would become $(( _vetoes + 1 ))/${CPU_VETO_MAX}. No counter written, no notify sent."
  else
    # ga-fzt548: the dry run reports what the BACKOFF GATE below would decide too —
    # restart_gate is read-only, so consulting it here writes nothing.
    restart_gate
    _dump_dr=""
    [ "$DOLT_DUMP" = "1" ] && _dump_dr=" DOLT_DUMP=1: it would ALSO send SIGQUIT first, which EXITS Dolt."
    case "$RG_VERDICT" in
      allow)
        log "DRY-RUN: would run 'gc dolt restart' (graceful stop by the engine; this script signals nothing itself) — restart #$(( RG_COUNT + 1 )) of the episode (strikes=${n}, cpu=${_cpu_now:-?}%, vetoes=${_vetoes}/${CPU_VETO_MAX}).${_dump_dr} Nothing signalled; strikes, veto counter and restart history left intact." ;;
      hold)
        log "DRY-RUN: would HOLD the restart (backoff) — ${RG_COUNT} restart(s) this episode, next allowed in ${RG_WAIT}s, and would page the Mayor (at most every ${ESCALATE_REPEAT}s). Nothing signalled; nothing written." ;;
      *)
        log "DRY-RUN: would REFUSE the restart — the restart history ${RESTART_STATE} exists but cannot be read, so it cannot be known whether one just happened; would page the Mayor. Nothing signalled; nothing written." ;;
    esac
  fi
  exit 0
fi

if [ -n "$_cpu_now" ] && [ "$_cpu_now" -ge "$CPU_ALIVE_PCT" ] && [ "$_vetoes" -lt "$CPU_VETO_MAX" ]; then
  _vetoes=$(( _vetoes + 1 ))
  mkdir -p "$(dirname "$CPU_VETO_FILE")" 2>/dev/null
  echo "$_vetoes" > "$CPU_VETO_FILE" 2>/dev/null \
    || log "WARN: could not write the CPU-veto counter ${CPU_VETO_FILE} — the veto will not count toward exhaustion"
  log "CONFIRMED-by-strikes but Dolt is burning ${_cpu_now}% CPU (>=${CPU_ALIVE_PCT}%) — WORKING, not hung. Restart VETOED (${_vetoes}/${CPU_VETO_MAX}). Not clearing strikes."
  command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Dolt hang-watchdog' \
    "Hang confirmed by probes but Dolt at ${_cpu_now}% CPU — restart vetoed (${_vetoes}/${CPU_VETO_MAX}). Saturation, not a hang." >/dev/null 2>&1 || true
  exit 0
fi

# ga-fzt548 — BACKOFF GATE (see restart_gate above). Past the veto the only question
# left is "may we restart NOW?". Everything the veto would have said is already said;
# a held or refused restart returns BEFORE the veto-exhausted notify below, whose text
# ("restarting Dolt anyway") would be false for a restart that does not happen, and
# BEFORE the veto counter is cleared (strikes and veto stay armed, so the restart fires
# on the first tick after the window opens).
restart_gate
case "$RG_VERDICT" in
  hold)
    log "CONFIRMED Dolt hang (${n} strikes, cpu=${_cpu_now:-?}%) but the restart is HELD by backoff: ${RG_COUNT} restart(s) this episode, the last at $(_snap_fmt "$RG_LAST"); next one allowed in ${RG_WAIT}s. Strikes and veto counter kept — it restarts on its own once the window opens."
    restart_escalate "Dolt hang-watchdog: restart held by backoff" \
      "Dolt is confirmed hung (${n} strikes) but the watchdog already tried to restart it ${RG_COUNT}x this episode (last attempt: $(_snap_fmt "$RG_LAST"); an attempt the engine refuses counts too). It will NOT try again for another ${RG_WAIT}s (about $(( (RG_WAIT + 59) / 60 )) min) — a restart loop does not cure saturation. If the city is down and you want it NOW: 'gc dolt restart'. Investigate the load first: ${LOG}"
    exit 0 ;;
  unreadable)
    log "CONFIRMED Dolt hang (${n} strikes) but the restart history ${RESTART_STATE} exists and cannot be read (empty, malformed or dated in the future) — REFUSING to restart: without it there is no telling whether a restart just happened, and that is how the 2026-09-24 loop ran. Fix or delete the file."
    restart_escalate "Dolt hang-watchdog: restart refused (history unreadable)" \
      "Dolt is confirmed hung (${n} strikes) but the watchdog cannot read its restart history (${RESTART_STATE}), so it cannot tell whether it just restarted Dolt and refuses to risk a loop. Inspect the file; delete it to re-arm the automatic restart, or run 'gc dolt restart' by hand."
    exit 0 ;;
esac

# Persist the attempt BEFORE making it. If it cannot be persisted the backoff could not
# hold next time, so the restart is refused too — the same inert answer as unreadable.
_restart_no=$(( RG_COUNT + 1 ))
if ! restart_record "$_restart_no"; then
  log "WARN: could not write the restart history ${RESTART_STATE} — REFUSING the restart: an unrecorded restart is exactly how the backoff gets bypassed."
  restart_escalate "Dolt hang-watchdog: restart refused (history not writable)" \
    "Dolt is confirmed hung (${n} strikes) but the watchdog cannot write its restart history (${RESTART_STATE}), so it refuses to restart without a record. Fix the path's permissions, or run 'gc dolt restart' by hand."
  exit 0
fi

if [ "$_vetoes" -ge "$CPU_VETO_MAX" ]; then
  log "CPU veto EXHAUSTED (${_vetoes}/${CPU_VETO_MAX}) at cpu=${_cpu_now:-?}% — a spin-deadlock also burns CPU, so proceeding with restart rather than never recovering."
  command -v notify >/dev/null 2>&1 && notify -p 5 -t 'Dolt hang-watchdog' \
    "CPU veto exhausted (${_vetoes}x) — restarting Dolt anyway at ${_cpu_now:-?}% CPU. Investigate: possible spin-deadlock." >/dev/null 2>&1 || true
fi
rm -f "$CPU_VETO_FILE" 2>/dev/null || true

log "CONFIRMED Dolt hang (${n} consecutive strikes, cpu=${_cpu_now:-?}%) — restarting via 'gc dolt restart' (restart #${_restart_no} of this episode; the next one is held for $(restart_backoff_for "$_restart_no")s)."

# ga-153cq: the DRY_RUN interception lives ABOVE the veto section now (see the note
# there). It must stay there: any dry-run gate placed at this point is already past
# the veto counter write and both notify calls, which is exactly what failed review.
# DOLT_WATCHDOG_DRY_RUN=1 exists because the only other way to exercise this branch
# was to actually restart the city's data plane — so in practice it was never
# tested, only observed after the fact, 87 times. An unrunnable safety path is an
# unverified one.

# ga-fzt548: NO signal to Dolt by default. The goroutine dump is opt-in (DOLT_DUMP=1)
# because SIGQUIT does not dump-and-continue on a Go server, it terminates it; the
# restart below would have done that anyway, but the doctrine forbids sending it as a
# routine step. Dolt's own stop path (gc dolt restart) is a plain SIGTERM.
if [ "$DOLT_DUMP" = "1" ]; then
  # vazio (PID desconhecido) → sem dump, e sem chute de PID; falhou/ilegível → idem: o restart abaixo segue sem o dump
  PID="$(dolt_server_pid || true)"
  if [ -n "$PID" ]; then
    log "DOLT_DUMP=1: sending SIGQUIT to pid ${PID} for a goroutine dump (opt-in; this EXITS Dolt — the restart below brings it back)."
    kill -QUIT "$PID" 2>/dev/null || true   # dumps goroutines to dolt.log, then Go exits the process
    sleep 3
  else
    log "DOLT_DUMP=1 but the Dolt PID is unknown — no dump taken (never guessing a PID); restarting without it."
  fi
fi
( cd "$CITY" && GC_CITY="$CITY" gc dolt restart >> "$LOG" 2>&1 ) || log "WARN: gc dolt restart returned nonzero"
sleep "$POST_RESTART_WAIT"
if probe_ok; then
  log "Restart OK — Dolt serving again."
  command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Dolt hang-watchdog' "Restarted HUNG Dolt after ${n} strikes (restart #${_restart_no} of this episode; next held for $(restart_backoff_for "$_restart_no")s) — now healthy" >/dev/null 2>&1 || true
else
  log "WARN: Dolt STILL unhealthy after restart — escalating."
  # ga-wxwao (case 2): migrated from an ad-hoc `notify -p 5` call to the
  # canonical escalate_emergency() path — same eventual notify (it calls
  # notify -p 5 internally with NOTIFY_FORCE_PUSH=1), PLUS mayor mail and a
  # ledger audit trail this site never had. Also removes a "by luck of
  # wording" fragility: this call only ever reached push because its message
  # happened to contain "NEEDS HUMAN", matching notify's own content
  # classifier — a future reword would have silently stopped pushing with no
  # test catching it. DRY_RUN cannot reach this line at all (is_dry_run()
  # exits unconditionally at line 257, well before here — see ga-153cq's
  # note above), so no separate dry-run threading is needed: by the time
  # we're here, this is a real, confirmed-still-unhealthy event.
  # ga-fzt548: a page that went out counts for the dedupe too, or the next held tick
  # (strikes are cleared below, so ~3 min from now) would page the same human again for
  # the same outage. A page that FAILED must not count — it stamps only on exit 0.
  if python3 /Users/athos/gt/.gascity-gastown-hq/scripts/escalate_emergency.py \
       --class town-halted \
       --title "Dolt hang-watchdog: restart did not recover" \
       "Restart attempted but Dolt STILL unhealthy after ${n} strikes — NEEDS HUMAN." \
       >> "$LOG" 2>&1; then
    escalation_stamp
  else
    log "WARN: escalate_emergency.py call failed (non-fatal) — page NOT stamped, a held tick will page again"
  fi
fi
rm -f "$STRIKES"
exit 0
