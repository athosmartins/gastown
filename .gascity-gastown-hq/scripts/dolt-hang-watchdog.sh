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
# transient blip), capturing a goroutine dump first for diagnosis.
#
# Kill switch: DOLT_WATCHDOG_ENABLED=0 → probe + log only, never restart.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
# ga-153cq: LOG/STRIKES overridable so a dry run can use scratch state. They were
# hardcoded, which made even a DRY RUN unsafe: the strike counter is incremented
# BEFORE the restart decision, so exercising this script against the live counter
# would push it toward MAX_STRIKES and arm a genuine restart on the next real
# sweep. "You cannot test it without risking the outage it causes" is why 87
# restarts happened with no test ever written.
LOG="${DOLT_WATCHDOG_LOG:-$CITY/.gc/logs/dolt-hang-watchdog.log}"
STRIKES="${DOLT_WATCHDOG_STRIKES_FILE:-/tmp/dolt-hang-watchdog.strikes}"
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
CPU_VETO_FILE="${DOLT_WATCHDOG_CPU_VETO_FILE:-/tmp/dolt-hang-watchdog.cpuveto}"

# ga-153cq (gate attempt 2 FAIL, reviewer was right again): DRY_RUN was only
# gated at the kill -QUIT decision point, deep in the script. But STRIKES and
# CPU_VETO_FILE are also mutated in THREE other places this file can exit
# from — the healthy-recovery branch, the saturation branch, and the strike
# counter's own write — and each ran unconditionally regardless of DRY_RUN. A
# flag that promises "side-effect-free end to end" has to be consulted at
# EVERY mutation, not just the destructive one, or the promise is only as
# true as whichever branch was last audited. One variable, one helper, one
# call-site pattern (`if is_dry_run`) used at every write below — grep for it
# to audit coverage; there are exactly 4 (probe_ok recovery, saturation
# recovery, strike write, veto/restart) and the selftest asserts that count.
DRY_RUN="${DOLT_WATCHDOG_DRY_RUN:-0}"
is_dry_run() { [ "$DRY_RUN" = "1" ]; }

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
  _pid=$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1)
  [ -z "$_pid" ] && { printf ''; return; }
  _cpu=$(ps -p "$_pid" -o %cpu= 2>/dev/null | tr -d ' ')
  [ -z "$_cpu" ] && { printf ''; return; }
  printf '%s' "${_cpu%%.*}"
}

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
  _cpu=$(ps -p "$(pgrep -f 'dolt sql-server' | head -1)" -o %cpu= 2>/dev/null | tr -d ' ')
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
  echo "$n" > "$STRIKES"
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
# it vanished on the spot and took the city down. That NEVER was written about a
# different call site — an ad-hoc "diagnostic" against a server just confirmed
# HEALTHY, under the false premise that SIGQUIT was non-fatal. Here it is the
# only automated recovery for a true hang, behind 3 confirmed strikes, and the
# author knew it exits Dolt. So the answer is not to delete the recovery path.
#
# But "confirmed" has to mean confirmed. Measured on the live log before this
# change: 1,879 saturation events (health probe failed, raw SELECT 1 still
# served — at up to 207% CPU) vs 319 strikes and 87 actual restarts. The health
# probe failing is ROUTINE; the single thing standing between routine saturation
# and an automatic SIGQUIT of the city's data plane is one bounded SELECT 1.
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
    _pid_dr="$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)"
    log "DRY-RUN: would kill -QUIT pid=${_pid_dr:-<none>} and run 'gc dolt restart' (strikes=${n}, cpu=${_cpu_now:-?}%, vetoes=${_vetoes}/${CPU_VETO_MAX}). Nothing signalled; strikes and veto counter left intact."
  fi
  exit 0
fi

if [ -n "$_cpu_now" ] && [ "$_cpu_now" -ge "$CPU_ALIVE_PCT" ] && [ "$_vetoes" -lt "$CPU_VETO_MAX" ]; then
  _vetoes=$(( _vetoes + 1 ))
  echo "$_vetoes" > "$CPU_VETO_FILE"
  log "CONFIRMED-by-strikes but Dolt is burning ${_cpu_now}% CPU (>=${CPU_ALIVE_PCT}%) — WORKING, not hung. Restart VETOED (${_vetoes}/${CPU_VETO_MAX}). Not clearing strikes."
  command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Dolt hang-watchdog' \
    "Hang confirmed by probes but Dolt at ${_cpu_now}% CPU — restart vetoed (${_vetoes}/${CPU_VETO_MAX}). Saturation, not a hang." >/dev/null 2>&1 || true
  exit 0
fi
if [ "$_vetoes" -ge "$CPU_VETO_MAX" ]; then
  log "CPU veto EXHAUSTED (${_vetoes}/${CPU_VETO_MAX}) at cpu=${_cpu_now:-?}% — a spin-deadlock also burns CPU, so proceeding with restart rather than never recovering."
  command -v notify >/dev/null 2>&1 && notify -p 5 -t 'Dolt hang-watchdog' \
    "CPU veto exhausted (${_vetoes}x) — restarting Dolt anyway at ${_cpu_now:-?}% CPU. Investigate: possible spin-deadlock." >/dev/null 2>&1 || true
fi
rm -f "$CPU_VETO_FILE" 2>/dev/null || true

log "CONFIRMED Dolt hang (${n} consecutive strikes, cpu=${_cpu_now:-?}%) — capturing goroutine dump + restarting."
PID="$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)"

# ga-153cq: the DRY_RUN interception lives ABOVE the veto section now (see the note
# there). It must stay there: any dry-run gate placed at this point is already past
# the veto counter write and both notify calls, which is exactly what failed review.
# DOLT_WATCHDOG_DRY_RUN=1 exists because the only other way to exercise this branch
# was to actually SIGQUIT the city's data plane — so in practice it was never
# tested, only observed after the fact, 87 times. An unrunnable safety path is an
# unverified one.

if [ -n "$PID" ]; then
  kill -QUIT "$PID" 2>/dev/null || true   # dumps goroutines to dolt.log (also exits Dolt; restart below recovers)
  sleep 3
fi
( cd "$CITY" && GC_CITY="$CITY" gc dolt restart >> "$LOG" 2>&1 ) || log "WARN: gc dolt restart returned nonzero"
sleep 5
if probe_ok; then
  log "Restart OK — Dolt serving again."
  command -v notify >/dev/null 2>&1 && notify -p 4 -t 'Dolt hang-watchdog' "Restarted HUNG Dolt after ${n} strikes — now healthy" >/dev/null 2>&1 || true
else
  log "WARN: Dolt STILL unhealthy after restart — escalating."
  command -v notify >/dev/null 2>&1 && notify -p 5 -t 'Dolt hang-watchdog' "Restart attempted but Dolt STILL unhealthy after ${n} strikes — NEEDS HUMAN" >/dev/null 2>&1 || true
fi
rm -f "$STRIKES"
exit 0
