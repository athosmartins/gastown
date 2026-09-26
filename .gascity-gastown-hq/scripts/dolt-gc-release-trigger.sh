#!/bin/bash
# dolt-gc-release-trigger.sh — ga-mb57np: evaluate hq's dolt_gc gate (and the staging release
# that unblocks it) at POLL cadence instead of once per 2h cycle. Run by launchd every 5 min.
#
# THE PROBLEM (measured 2026-09-26, artifacts not reports): dolt-gc-maintenance.sh decides
# whether to run dolt_gc — and, when the skip is chronic, whether to release hq's redundant
# local backup staging (ga-btnq6h) — only when its own 2h launchd tick fires, against ONE
# `avail` sample. On this machine "free" swings ±9 GB with swap under memory pressure (load ~60),
# so whether the gate is met at a given instant is a lottery: of 15 samples 24-26/09, ~7 would
# have passed, yet the job saw one real chance in ~124h of skipping (62 consecutive), and that
# one fell on a Dolt health probe. hq keeps growing (~0.5 GB/day), raising the bar every day.
# (Re-measured from .gc/logs/dolt-gc-maintenance.log: of the 25 2h samples 24-26/09 — avail 3.6-12.5
# GB — 8 met the release condition with the ~9.4 GB staging; none met the direct 2x gate.)
#
# WHAT THIS DOES: every poll it reads ONE small file (the skip streak) and — only in a chronic
# state — one `df` and two `du` (ms). When the SAME gate the job enforces is reachable right now
# (directly, or after freeing the staging), it starts the existing job:
#     GC_TRIGGERED_RUN=1 /bin/bash dolt-gc-maintenance.sh
# That job stays the ONLY owner of the decision and of every destructive act: S3 proof, Dolt health
# probe, busy-staging check, 168h cooldown, the re-gate after the release. A triggered run does
# only the size-gated dolt_gc step (purge/prune/flatten stay on the 2h cadence) and its skips are
# not counted as 2h cycles.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#   - It never deletes anything (no rm in this file; a test greps for it) and never loosens the
#     2x gate or the 2048MB slack. It decides with the job's own functions (_gc_required_parts,
#     _gc_headroom_ok, _gc_floor_ok, _gc_release_decision) — imported, not copied — so it cannot
#     drift from the gate it is waiting for.
#   - It does not retry every poll when a run fails: a run that left the skip streak standing (the
#     job refused: S3 proof, health probe, busy staging, re-gate) backs off 5 → 10 → 20 … capped
#     at 2h (a refused run may have gone as far as an S3 proof, which is aws traffic); a run that
#     cleared the streak resets it. "Cleared" means EXACTLY the record the job writes ("0 0"): a
#     streak file the trigger cannot read after a run counts as NOT cleared (same backoff), never as
#     success. A backoff belongs to its episode: once the streak is known to be below the minimum
#     it is dropped, and it can never reach further ahead than its own cap. Vetoes that cost nothing
#     to re-check (a backup writer is busy, a maintenance run is in flight, cooldown) wait without
#     counting as attempts.
#   - It does not run when the state is not chronic (streak < GC_RELEASE_MIN_STREAK): the 2h cycle
#     owns healthy operation. A minimum below 1 is refused as unusable (with 0 every healthy poll
#     would count as chronic).
#
# FAIL-CLOSED: an unreadable number → no run ("WAIT unmeasurable-input"); an unreadable clock → no
# run; a decision that is not exactly "KICK direct" / "KICK release" → no run ("WAIT unknown-decision");
# a state file that cannot be written (so the backoff could not be recorded) → no run; a live sibling
# poll or a live maintenance run → no run. A state file that exists but is not ONE COMPLETE record
# (garbled, empty, cut mid-write, missing attempts/next_allowed) is "don't know" (its backoff may be
# lost): that poll stays inert, logs it, rewrites a clean state, and the next poll proceeds. The job's
# skip-streak file is read the same way (_trg_streak_read: absent / cleared / standing N / unreadable):
# unreadable before a run → no run ("WAIT streak-unreadable"); unreadable after a run → the attempt
# counts as failed, the backoff is armed. A state write that fails is logged (at most about once an
# hour) — the state file is the operator's only window into this job.
#
# POLL COST (ga-y0g5x doctrine: the guard must not become the load it watches). Measured
# 2026-09-26 on the live tree at load ~55 on 10 cores, whole script under /bin/bash 3.2:
#   healthy state (streak 0 — the ~always case):  ≈ 0.08 s CPU, 0.2–1.3 s wall (fork latency under
#       load; most of it is loading the job's library, ~0.35 s)
#   chronic state: + one df and two du (~35 ms each), and — only when a release run would start on
#       THIS poll (past the backoff check, which is arithmetic and comes first) — the `ps -ax` busy
#       check (~1.2 s wall). A poll inside its backoff window, or one on the direct path, never forks it.
# StartInterval=300 ≫ any of these; ≈ 25 CPU-seconds/day in total. A pid-verified single-instance
# lock (same helper as the job) means a long child run can never stack polls.
#
# OBSERVABILITY: the state file (default .gc/runtime/packs/maintenance/dolt-gc-release-trigger.state)
# is rewritten every poll: `poll=<epoch> decision=<KICK|WAIT reason> attempts=N next_allowed=<epoch>`
# — its mtime/poll epoch is the liveness signal, `decision` says why nothing happened (a streak file the
# trigger cannot read shows as `WAIT streak-unreadable`, not as a healthy `streak-too-short`). Changes of
# decision (and every started run + outcome) are logged to dolt-gc-maintenance.log with the numbers.
#
# KNOBS (operator file .gc/config/dolt-maintenance.env wins over env, as for the job):
#   GC_TRIGGER_ENABLED=0            kill switch (this trigger only; the 2h job is unaffected)
#   GC_TRIGGER_BACKOFF_BASE_S=300   first retry delay after a run that left the skip streak standing
#   GC_TRIGGER_BACKOFF_MAX_S=7200   cap
#   (+ every gate knob of dolt-gc-maintenance.sh: GC_RELEASE_STAGING_ENABLED, GC_RELEASE_MIN_STREAK,
#    GC_RELEASE_SLACK_MB, GC_RELEASE_COOLDOWN_H, GC_MIN_FREE_ABS_MB, …)
#
# There is NO dry-run: running this script by hand is a real poll — it may start the job and it moves
# the backoff. To see what it would decide, read the state file (`decision=` is the last poll's answer)
# and the `trigger:` lines in dolt-gc-maintenance.log; to pause it, GC_TRIGGER_ENABLED=0.
#
# TEST: bash scripts/dolt-gc-release-trigger.selftest.sh (hermetic; nothing is deleted or started)
# Library mode: `DOLT_GC_TRIGGER_LIB=1 source dolt-gc-release-trigger.sh` defines the functions only.
set -uo pipefail

_TRG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MAINT="$_TRG_HERE/dolt-gc-maintenance.sh"

# Load the job's decision functions + config as a LIBRARY. A plain (NOT exported) variable, unset
# right after: the job started below must run main(), not load as a library and do nothing.
# shellcheck disable=SC2034  # read by the sourced file, deliberately not exported
DOLT_GC_MAINT_LIB=1
# shellcheck disable=SC1090
. "$MAINT"
unset DOLT_GC_MAINT_LIB

# Defaults AFTER the library load so the operator conf it sourced (file > env > default) wins.
GC_TRIGGER_ENABLED="${GC_TRIGGER_ENABLED:-1}"
GC_TRIGGER_STATE="${GC_TRIGGER_STATE:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-release-trigger.state}"
GC_TRIGGER_LOCKDIR="${GC_TRIGGER_LOCKDIR:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-release-trigger.lock.d}"
GC_TRIGGER_LOCK_RE="${GC_TRIGGER_LOCK_RE:-dolt-gc-release-trigger}"
GC_TRIGGER_BACKOFF_BASE_S="${GC_TRIGGER_BACKOFF_BASE_S:-300}"
GC_TRIGGER_BACKOFF_MAX_S="${GC_TRIGGER_BACKOFF_MAX_S:-7200}"

# ════════════════════════════════════════════════════════════════════════════════
# PURE / TESTABLE FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════════

# _gc_trigger_decision <streak> <avail_mb> <size_mb> <staging_mb> <pct> <floor_mb> <min_streak>
#                      <slack_mb> <release_enabled 1|0> <cooldown_ok 1|0>
# → "KICK direct"   the gate (pct AND floor) passes as it stands: the GC itself can run
#   "KICK release"  it does not, but freeing the staging clears it (_gc_release_decision says RELEASE)
#   "WAIT <reason>" anything else; the reason is the state file's answer to "why is nothing happening?"
# PURE. Any unmeasurable numeric input → "WAIT unmeasurable-input" (a failed read must never look
# like "plenty of room"), and so is a <min_streak> below 1: with 0, a HEALTHY streak of 0 already
# counts as chronic and every poll (288/day) would be eligible, with no backoff. <staging_mb> is 0
# when there is no releasable staging and blank when it exists but could not be measured; only the
# release path looks at it.
_gc_trigger_decision() {
  local streak="$1" avail="$2" size="$3" staging="$4" pct="$5" floor="$6" min_streak="$7" slack="$8" rel_on="$9" cool_ok="${10}"
  local v parts required d
  for v in "$streak" "$avail" "$size" "$pct" "$floor" "$min_streak" "$slack"; do
    case "$v" in ''|*[!0-9]*) echo "WAIT unmeasurable-input"; return 0 ;; esac
  done
  _trg_pos_int "$min_streak" || { echo "WAIT unmeasurable-input"; return 0; }
  [ "$streak" -ge "$min_streak" ] || { echo "WAIT streak-too-short"; return 0; }
  parts="$(_gc_required_parts "$size" "$pct" "$floor")" || { echo "WAIT unmeasurable-input"; return 0; }
  required="${parts##* }"
  if _gc_headroom_ok "$avail" "$size" "$pct" && _gc_floor_ok "$avail" "$size" "$floor"; then
    echo "KICK direct"; return 0
  fi
  [ "$rel_on" = "1" ]   || { echo "WAIT release-disabled"; return 0; }
  [ "$cool_ok" = "1" ]  || { echo "WAIT cooldown"; return 0; }
  d="$(_gc_release_decision "$streak" "$avail" "$staging" "$required" "$min_streak" "$slack")"
  # Allow-list: the two shapes _gc_release_decision documents. Blank or anything else (a failed
  # $(...), a changed contract) is "don't know" — never a KICK, never a WAIT with a blank reason.
  case "$d" in
    RELEASE)    echo "KICK release" ;;
    "REFUSE "?*) echo "WAIT ${d#REFUSE }" ;;
    *)          echo "WAIT unknown-release-decision" ;;
  esac
}

# _trg_pos_int <v> → 0 iff <v> is a whole number >= 1 (a usable minimum/count; 0 and garbage are not).
_trg_pos_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ]
}

# _trg_streak_read <file> → the job's skip-streak file as ONE of four answers, never a guess:
#   absent         no file: the job never skipped (or never ran) — genuinely no streak
#   cleared        the file is EXACTLY "0 0\n" — what the job's _clear_skip_streak writes
#   standing <n>   exactly one complete line "<n> <0|1>\n", n >= 1, no leading zero
#   unreadable     anything else that exists: empty, cut mid-write (no newline), torn, an extra field or
#                  line, "0 1", a directory, a file that cannot be opened
# The job's own _read_skip_streak is fail-SAFE for its alert counter (missing/garbled → "0 0"), which is
# right for something that only drives a notify and WRONG here: "could not read" must never read as
# "cleared". Builtins only (no fork): this runs on every poll, healthy or not.
_trg_streak_read() {
  local f="$1" line="" extra="" rl=9 re=9 n flag
  [ -e "$f" ] || { echo absent; return 0; }
  [ -f "$f" ] || { echo unreadable; return 0; }
  # read #1 returns 0 only for a line that ended in a newline; read #2 must then hit a clean EOF
  # (status 1, nothing read). The redirect comes first so a failed open leaves rl/re at 9.
  { IFS= read -r line; rl=$?; IFS= read -r extra; re=$?; } 2>/dev/null < "$f"
  { [ "$rl" = "0" ] && [ "$re" = "1" ] && [ -z "$extra" ]; } || { echo unreadable; return 0; }
  [ "$line" = "0 0" ] && { echo cleared; return 0; }
  n="${line%% *}"; flag="${line#* }"
  case "$n" in ''|0*|*[!0-9]*) echo unreadable; return 0 ;; esac
  case "$flag" in 0|1) ;; *) echo unreadable; return 0 ;; esac
  [ "$line" = "$n $flag" ] || { echo unreadable; return 0; }
  echo "standing $n"
}

# _trg_warn_hourly <now> <message> — a WARN that would repeat every poll (288/day) while a fault
# persists (e.g. an unwritable state file) is logged only by the poll that lands in the first 300s
# of an hour: stateless, ~once an hour at the 300s cadence. Approximate on purpose — a fault that
# outlives the hour is logged again, and a skipped poll can skip one line, never the fault itself.
_trg_warn_hourly() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $1 % 3600 )) -lt 300 ] && log "$2"
  return 0
}

# _trg_backoff_s <attempts> → seconds to wait after that many consecutive runs that left the skip
# streak standing: base, then doubling, capped. A non-numeric count backs off to the cap (never to 0).
_trg_backoff_s() {
  local n="$1" s="$GC_TRIGGER_BACKOFF_BASE_S" max="$GC_TRIGGER_BACKOFF_MAX_S" i=1
  case "$max" in ''|*[!0-9]*) max=7200 ;; esac
  case "$s" in ''|*[!0-9]*) s=300 ;; esac
  case "$n" in ''|*[!0-9]*) echo "$max"; return ;; esac
  while [ "$i" -lt "$n" ] && [ "$s" -lt "$max" ]; do s=$(( s * 2 )); i=$(( i + 1 )); done
  [ "$s" -gt "$max" ] && s="$max"
  echo "$s"
}

# _trg_state_get <file> <key> → the numeric value of key (poll|attempts|next_allowed), 0 when the
# file is absent or lacks the key. Callers gate on _trg_state_readable first, which admits only an
# ABSENT file (genuinely no history) or a COMPLETE record — so a 0 from here in a poll that could
# start a run always means "first run", never "a record that lost its fields".
_trg_state_get() {
  local f="$1" k="$2" v=""
  [ -f "$f" ] && v="$(head -1 "$f" 2>/dev/null | awk -v k="$k" '{ for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { x = substr($i, length(k) + 2); if (x ~ /^[0-9]+$/) print x; exit } }')"
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

# _trg_state_readable <file> → 0 iff the file is ABSENT (a first run: genuinely no history) or holds
# one COMPLETE record: a first line of exactly `poll=<n> decision=<text> attempts=<n> next_allowed=<n>`
# that ended in a newline (a write cut mid-number, `next_allowed=70` of `7000`, has no newline).
# 1 for anything else that exists — empty, garbled, partly written, a directory. That is a third
# state, not "no history": the backoff it held may be lost or wrong, so the poll treats it as
# "don't know" (stays inert once, says so, rewrites a clean state) rather than as zero attempts.
_trg_state_readable() {
  local nl
  [ -e "$1" ] || return 0
  [ -f "$1" ] || return 1
  nl="$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]')"
  case "$nl" in ''|*[!0-9]*|0) return 1 ;; esac
  head -1 "$1" 2>/dev/null | grep -Eq '^poll=[0-9]+ decision=.+ attempts=[0-9]+ next_allowed=[0-9]+$'
}

# _trg_state_decision <file> → the last recorded decision text, "" if none.
_trg_state_decision() {
  [ -f "$1" ] && head -1 "$1" 2>/dev/null | sed -n 's/.* decision=\(.*\) attempts=[0-9]* next_allowed=[0-9]*$/\1/p'
}

# _trg_state_write <file> <poll_epoch> <decision> <attempts> <next_allowed_epoch> → 0 iff written.
# One short line. The write is truncate-then-write (not atomic), so a torn one is possible; it reads
# as UNREADABLE (see _trg_state_readable) and the next poll rewrites it — never as "no history".
_trg_state_write() {
  local f="$1"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf 'poll=%s decision=%s attempts=%s next_allowed=%s\n' "$2" "$3" "$4" "$5" > "$f" 2>/dev/null
}

# _trg_dir_mb <path> → integer MB of the tree, blank when it cannot be measured (never 0).
_trg_dir_mb() {
  local m; m="$(du -sm "$1" 2>/dev/null | awk '{print $1}')"
  case "$m" in ''|*[!0-9]*) echo "" ;; *) echo "$m" ;; esac
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTION
# ════════════════════════════════════════════════════════════════════════════════

# _trg_run_maintenance — start the existing job (blocking: this poll's launchd instance lives as
# long as the run, and launchd will not start a second poll meanwhile). The caller marks it as a
# triggered run by prefixing GC_TRIGGERED_RUN=1 (in effect for the call and exported to the job);
# kept at the call site so the selftest, which replaces this function, sees what the real call passes.
_trg_run_maintenance() {
  /bin/bash "$MAINT"
}

# _trg_record <now> <decision> <attempts> <next_allowed> — state write + change-only logging.
_trg_record() {
  local now="$1" decision="$2" attempts="$3" next="$4" prev
  prev="$(_trg_state_decision "$GC_TRIGGER_STATE")"
  _trg_state_write "$GC_TRIGGER_STATE" "$now" "$decision" "$attempts" "$next" || {
    # No state → no heartbeat and no recorded backoff. Not a run path (a poll that cannot record does
    # not start one), but it must not be silent: the state file is the operator's only window.
    _trg_warn_hourly "$now" "trigger: WARN cannot write $GC_TRIGGER_STATE — decision '${decision}' not recorded (no heartbeat from this poll; an unwritable state also blocks every run)"
    return 1
  }
  [ "$prev" != "$decision" ] && log "trigger: decision ${prev:-<none>} → ${decision} (streak=${_TRG_STREAK:-?} avail=${_TRG_AVAIL:-?}MB size=${_TRG_SIZE:-?}MB staging=${_TRG_STAGING:-?}MB required=${_TRG_REQUIRED:-?}MB)${_TRG_NOTE:+ — ${_TRG_NOTE}}"
  return 0
}

# _trg_poll — one evaluation. Always returns 0 (a poll that decides nothing is a normal outcome).
_trg_poll() {
  local now streak sk attempts next_allowed max_s size_mb avail_mb staging_mb target pct parts rel_on cool_ok decision busy backoff end run_rc rc_note
  _TRG_STREAK=""; _TRG_AVAIL=""; _TRG_SIZE=""; _TRG_STAGING=""; _TRG_REQUIRED=""; _TRG_NOTE=""
  now="$(_gc_now_epoch)"
  case "$now" in ''|*[!0-9]*)
    # No clock → no backoff arithmetic, no cooldown, no readable heartbeat: nothing here can be
    # decided safely. (A blank epoch made `[ "$now" -lt "$next_allowed" ]` an error, i.e. false.)
    log "trigger: WARN cannot read the clock ('${now}') — no decision this poll, no state written (a stale heartbeat in $GC_TRIGGER_STATE is the signal)"
    return 0 ;;
  esac
  if ! _trg_state_readable "$GC_TRIGGER_STATE"; then
    # exists but unreadable: the backoff it held may be lost → don't act on a guess this poll.
    if _trg_state_write "$GC_TRIGGER_STATE" "$now" "WAIT state-unreadable" 0 0; then
      log "trigger: state file $GC_TRIGGER_STATE is unreadable (garbled/empty — a torn write or a hand edit) — no run this poll; reset to a clean record"
    else
      _trg_warn_hourly "$now" "trigger: state file $GC_TRIGGER_STATE is unreadable AND cannot be rewritten — no run until it is fixed (delete it, or restore write access)"
    fi
    return 0
  fi
  attempts="$(_trg_state_get "$GC_TRIGGER_STATE" attempts)"
  next_allowed="$(_trg_state_get "$GC_TRIGGER_STATE" next_allowed)"
  # A backoff never reaches further ahead than its own cap: one written under a clock that ran fast
  # (or by a hand edit) must not hold the trigger inert for days.
  max_s="$GC_TRIGGER_BACKOFF_MAX_S"; case "$max_s" in ''|*[!0-9]*) max_s=7200 ;; esac
  [ "$next_allowed" -gt $(( now + max_s )) ] && next_allowed=$(( now + max_s ))

  # 1) cheapest first: not chronic → the 2h cycle owns this; no disk read at all. The streak is read
  #    strictly (see _trg_streak_read): "no streak" and "cleared" are KNOWN states (streak 0), a file
  #    that exists but cannot be read is not — it is neither "not chronic" nor "chronic".
  sk="$(_trg_streak_read "$GC_SKIP_STREAK_STATE")"
  case "$sk" in
    absent|cleared) streak=0 ;;
    "standing "*)   streak="${sk#standing }" ;;
    *) _TRG_NOTE="skip-streak file $GC_SKIP_STREAK_STATE is not a complete '<n> <0|1>' line — cannot tell whether hq is skipping"
       _trg_record "$now" "WAIT streak-unreadable" "$attempts" "$next_allowed"; return 0 ;;
  esac
  _TRG_STREAK="$streak"
  if _trg_pos_int "$GC_RELEASE_MIN_STREAK" && [ "$streak" -lt "$GC_RELEASE_MIN_STREAK" ]; then
    # Known and below the minimum: any earlier episode is over — a backoff belongs to the episode that
    # earned it, so the next chronic episode starts at attempt 1, not near the cap.
    _trg_record "$now" "WAIT streak-too-short" 0 0; return 0
  fi
  # (an unusable minimum — 0, blank, non-numeric — falls through: _gc_trigger_decision refuses it below)

  # 2) a maintenance run in flight owns the job (and the staging) right now.
  if _dgm_lock_held "$GC_MAINT_LOCKDIR" "$GC_MAINT_LOCK_RE"; then
    _trg_record "$now" "WAIT maintenance-running" "$attempts" "$next_allowed"; return 0
  fi

  # 3) measure. One df + two du.
  case "$THRESHOLD_G" in ''|*[!0-9]*)
    _trg_record "$now" "WAIT unmeasurable-input" "$attempts" "$next_allowed"; return 0 ;;   # a garbled knob is not "no threshold"
  esac
  size_mb="$(_trg_dir_mb "$DOLTDIR")"; _TRG_SIZE="$size_mb"
  case "$size_mb" in ''|*[!0-9]*) ;; *)   # unmeasurable size: _gc_trigger_decision refuses it below
    if [ $(( size_mb / 1024 )) -lt "$THRESHOLD_G" ]; then
      _trg_record "$now" "WAIT hq-below-threshold" "$attempts" "$next_allowed"; return 0   # the job would skip: nothing to start
    fi ;;
  esac
  avail_mb="$(_avail_mb "$DOLTDIR")"; _TRG_AVAIL="$avail_mb"
  if target="$(_gc_release_target "$BACKUP_STAGING" "$DB")"; then staging_mb="$(_trg_dir_mb "$target")"; else target=""; staging_mb=0; fi
  _TRG_STAGING="$staging_mb"
  pct="$(_resolve_gc_min_free_pct "${GC_MIN_FREE_PCT:-}" "$PRUNE_ENABLED" "$GC_MIN_FREE_PCT_BASE" "$GC_MIN_FREE_PCT_WITH_PRUNE")"
  parts="$(_gc_required_parts "$size_mb" "$pct" "$GC_MIN_FREE_ABS_MB")"; _TRG_REQUIRED="${parts##* }"
  rel_on=0; [ "$GC_RELEASE_STAGING_ENABLED" = "1" ] && rel_on=1
  cool_ok=0; _gc_release_cooldown_ok "$GC_RELEASE_STATE" "$GC_RELEASE_COOLDOWN_H" "$now" && cool_ok=1

  decision="$(_gc_trigger_decision "$streak" "$avail_mb" "$size_mb" "$staging_mb" "$pct" "$GC_MIN_FREE_ABS_MB" "$GC_RELEASE_MIN_STREAK" "$GC_RELEASE_SLACK_MB" "$rel_on" "$cool_ok")"
  # Allow-list, not a deny-list: only the two exact KICK strings go on. A blank or unrecognized
  # decision (a failed $(...) under fork/memory pressure) is "don't know" → inert, visible, and not
  # an attempt — it must never be treated like a KICK.
  case "$decision" in
    "KICK direct"|"KICK release") ;;
    WAIT*) _trg_record "$now" "$decision" "$attempts" "$next_allowed"; return 0 ;;
    *) _TRG_NOTE="unrecognized decision '${decision}'"
       _trg_record "$now" "WAIT unknown-decision" "$attempts" "$next_allowed"; return 0 ;;
  esac

  # 4) eligible. Cheapest veto first: the backoff is arithmetic. Only then, on the release path, the
  #    one veto that costs a `ps -ax` (~1.2 s at load) but is free to re-check and must not escalate
  #    the backoff: something is writing the staging right now.
  if [ "$now" -lt "$next_allowed" ]; then
    _trg_record "$now" "WAIT backoff" "$attempts" "$next_allowed"; return 0
  fi
  if [ "$decision" = "KICK release" ] && busy="$(_gc_release_busy "$target")"; then
    _trg_record "$now" "WAIT staging-busy:${busy}" "$attempts" "$next_allowed"; return 0
  fi

  # 5) start the job. The attempt is recorded BEFORE the run: if it cannot be recorded there is no
  #    backoff to rely on → do not start; and a crash mid-run keeps the backoff in force.
  attempts=$(( attempts + 1 ))
  backoff="$(_trg_backoff_s "$attempts")"
  if ! _trg_state_write "$GC_TRIGGER_STATE" "$now" "$decision (running)" "$attempts" "$(( now + backoff ))"; then
    _trg_warn_hourly "$now" "trigger: cannot write $GC_TRIGGER_STATE — not starting a run (an attempt that cannot be recorded cannot be backed off)"
    return 0
  fi
  log "trigger: ${decision} — streak=${streak} avail=${avail_mb}MB size=${size_mb}MB staging=${staging_mb}MB required=${_TRG_REQUIRED}MB → starting dolt-gc-maintenance as a triggered run (attempt ${attempts})"
  GC_TRIGGERED_RUN=1 _trg_run_maintenance; run_rc=$?
  end="$(_gc_now_epoch)"
  case "$end" in ''|*[!0-9]*) end="$now" ;; esac   # never a blank: the poll's own start is a lower bound of the true time
  rc_note=""; [ "$run_rc" -ne 0 ] && rc_note=" (the job exited rc=${run_rc}: it could not start, or it crashed)"
  # The job's skip-streak file is the only outcome signal it gives (it always exits 0 once running).
  # "Cleared" is what its size-gated step does when it does NOT skip: it ran dolt_gc, OR found nothing
  # to do (hq under the threshold / size unmeasurable). It is accepted ONLY as the exact record the job
  # writes; a file that is standing, absent, empty, torn or otherwise unreadable is NOT cleared — "could
  # not read it" is treated like "still standing" (attempt counted, backoff armed), never like success.
  sk="$(_trg_streak_read "$GC_SKIP_STREAK_STATE")"
  case "$sk" in
    cleared)
      log "trigger: run finished — the skip streak is cleared (dolt_gc ran, or the job found nothing to do); backoff reset${rc_note}"
      _trg_state_write "$GC_TRIGGER_STATE" "$end" "$decision" 0 0 || log "trigger: WARN could not record the outcome in $GC_TRIGGER_STATE"
      return 0 ;;
    "standing "*)
      log "trigger: run finished WITHOUT clearing the skip streak (streak=${sk#standing }) — the job refused, or did not get that far (its own log lines say why); next attempt not before +${backoff}s${rc_note}" ;;
    *)
      log "trigger: run finished but the skip-streak file is ${sk} ($GC_SKIP_STREAK_STATE) — cannot tell whether the job cleared it, so this counts as NOT cleared (attempt counted, next attempt not before +${backoff}s)${rc_note}" ;;
  esac
  _trg_state_write "$GC_TRIGGER_STATE" "$end" "$decision" "$attempts" "$(( end + backoff ))" || log "trigger: WARN could not record the outcome in $GC_TRIGGER_STATE"
  return 0
}

# trigger_main — kill switch, single-instance lock, one poll.
trigger_main() {
  local lrc dnow da=0 dn=0
  if [ "$GC_TRIGGER_ENABLED" != "1" ]; then
    # A pause, not a reset: keep the recorded backoff (only when it is a complete record — an unreadable
    # one is not trusted) so re-enabling does not forget it. No clock → no record (a blank poll= would
    # make the file unreadable and cost the next enabled poll its one inert turn).
    dnow="$(_gc_now_epoch)"
    case "$dnow" in ''|*[!0-9]*) return 0 ;; esac
    if _trg_state_readable "$GC_TRIGGER_STATE"; then
      da="$(_trg_state_get "$GC_TRIGGER_STATE" attempts)"; dn="$(_trg_state_get "$GC_TRIGGER_STATE" next_allowed)"
    fi
    _trg_state_write "$GC_TRIGGER_STATE" "$dnow" "DISABLED" "$da" "$dn" || true
    return 0
  fi
  _dgm_lock_acquire "$GC_TRIGGER_LOCKDIR" "$GC_TRIGGER_LOCK_RE"; lrc=$?
  # 1 = a sibling poll (or the run it started) is live — normal, silent. 2 = the lock dir cannot be
  # created — inert but NOT silent. Either way this trigger is optional; the 2h cycle is untouched.
  if [ "$lrc" -eq 2 ]; then
    log "trigger: WARN cannot create the trigger lock $GC_TRIGGER_LOCKDIR — staying inert this poll (no run can start without single-instance protection)"
    return 0
  fi
  [ "$lrc" -eq 0 ] || return 0
  _trg_poll
  _dgm_lock_release "$GC_TRIGGER_LOCKDIR"
  return 0
}

# ── run unless sourced as a library (selftest sources with DOLT_GC_TRIGGER_LIB=1) ──
if [ "${DOLT_GC_TRIGGER_LIB:-0}" != "1" ]; then
  trap '_dgm_lock_release "$GC_TRIGGER_LOCKDIR"' EXIT
  trigger_main
  exit 0
fi
