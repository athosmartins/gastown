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
#   - It does not retry every poll when a run fails: a run that was not confirmed successful (the job
#     refused: S3 proof, health probe, busy staging, re-gate; or it could not be told apart from that)
#     backs off 5 → 10 → 20 … capped at 2h — PER KIND (ga-11vdhe). A refused RELEASE run may have gone
#     as far as an S3 proof (aws traffic); a DIRECT run cannot have, because the job refuses to take
#     the release path in a run the trigger started as "direct" (GC_TRIGGERED_KIND, see
#     dolt-gc-maintenance.sh: only kind=release may release). Before, one shared backoff meant a refused
#     release held back a later direct kick for up to 2h — it could sit out exactly the peak that lets the
#     GC run with no aws at all. Now each kind keeps its own attempts/next_allowed and neither erases the
#     other's memory (release → direct → release inside the release window is still held).
#     A confirmed success (below) resets both. A backoff belongs to its episode: once the streak is
#     known to be below the minimum both are dropped, and neither can reach further ahead than its own
#     cap. Vetoes that cost nothing to re-check (a backup writer is busy, a maintenance run is in flight,
#     cooldown) wait without counting as attempts.
#   - It does not take a run's word for success from ONE file. The job's outcome record (token-matched to
#     THIS run) and its skip-streak file must AGREE: streak "0 0" AND an outcome that says the step reached
#     its end (gc-ok, gc-failed — the job alerts on that itself — or below-threshold: hq MEASURED under the
#     threshold; a size the job could not measure is size-unmeasurable, which is not one). A missing, stale,
#     skipped, unknown-word or contradicting signal is "cannot tell" and is treated like "still standing":
#     attempt counted, backoff armed, the log says which signal said what. Until ga-11vdhe success was
#     inferred from the streak file alone ("cleared" = probably worked); the job always exits 0, so its
#     exit status says nothing.
#   - It does not run when the state is not chronic (streak < GC_RELEASE_MIN_STREAK): the 2h cycle
#     owns healthy operation. A minimum below 1 is refused as unusable (with 0 every healthy poll
#     would count as chronic). (It does still LOOK, at any streak, for a hung maintenance holder — read-only;
#     see "A HUNG HOLDER" below.)
#
# FAIL-CLOSED: an unreadable number → no run ("WAIT unmeasurable-input"); an unreadable clock → no
# run; a decision that is not exactly "KICK direct" / "KICK release" → no run ("WAIT unknown-decision");
# a state file that cannot be written (so the backoff could not be recorded) → no run; a second live
# invocation or a live maintenance run → no run. A state file that exists but is not ONE COMPLETE record
# (garbled, empty, cut mid-write, missing attempts/next_allowed, cut between the two direct_ fields) is
# "don't know" (its backoff may be lost): that poll stays inert, logs it, rewrites a clean state, and
# the next poll proceeds. The job's
# skip-streak file is read the same way (_trg_streak_read: absent / cleared / standing N / unreadable):
# unreadable before a run → no run ("WAIT streak-unreadable"); unreadable after a run → the attempt
# counts as failed, the backoff is armed. A state write that fails is logged (at most about once an
# hour) — the state file is the operator's only window into this job.
#
# A HUNG HOLDER (ga-11vdhe). "A run is in flight" is answered by pid liveness, which has no notion of how
# long: a run stuck on a Dolt that stopped answering (`bd purge` has no timeout) makes every later run —
# the 2h job and every poll — stand down, silently, for as long as it hangs. A live pid is never stolen
# from (it may be mid-dolt_gc), but once its lock is older than GC_MAINT_LOCK_STUCK_H (default 3h) this
# poll says so: decision `WAIT maintenance-stuck` (not the reassuring `maintenance-running`), one ALERT
# line and at most ONE notification per holder (dedupe marker beside the lock; if it cannot be written there
# is no push, so a stuck holder can never mean 288 pushes/day; a push that fails is not retried). The check is
# the FIRST thing a poll does once its state is loaded (_trg_poll, step 0) — ahead of the skip-streak gate, so
# what it reports does not depend on the streak: a healthy streak is the ~always case, and a run hung in
# `bd purge` never reaches the step that writes the streak, so the streak stays wherever the hang found it.
#
# WHO REPORTS A HUNG RUN, AND WHEN — it depends on WHICH run hung; the cases have different reporters.
#   - A hung 2h-CYCLE run (the `bd purge` hang above: purge runs only in the 2h cycle). The holder is
#     launchd's own instance of the job's label, and launchd runs one process per label — it does not start a
#     second instance while the first is still running — so the job's entry point does not get to see it.
#     THIS poll — another label, every 5 min — is the reporter, and it reports within one poll of the holder
#     turning GC_MAINT_LOCK_STUCK_H old, at any skip streak (dolt-gc-release-trigger.selftest.sh, section 3a).
#     (That launchd behaviour is the documented model and what this file's own locking already assumes; it was
#     not re-measured. The alert does not depend on it: both reporters run the same check on the same lock and
#     share one dedupe marker, so a hang that both of them find is still one push.)
#   - A hung TRIGGERED run. The poll that starts a run blocks in it (_trg_run_maintenance), launchd never
#     overlaps a label, and this script is started by nothing but that plist — so there is NO later poll to
#     notice: the poll that could is the one stuck inside the run. The report comes from the job's own
#     entry point (dolt-gc-maintenance.sh, "another run holds ..."): the run's child holds the job's lock,
#     the next 2h cycle finds it, and once that holder is GC_MAINT_LOCK_STUCK_H old it alerts. That is at
#     the first 2h tick after the holder turns 3h old — 3-5h into the hang at the nominal cadence, longer
#     when the cycle runs late (it has run every 2-3.5h), and never "within a poll". Tested through the
#     real job script (dolt-gc-maintenance.selftest.sh, the "entry/stuck" cases).
#   - A PAUSED trigger (GC_TRIGGER_ENABLED=0) reports NOTHING: it writes `DISABLED` and returns, by design
#     (the selftest asserts it). So while it is paused a hung 2h-cycle run has no reporter at all — the
#     watchdog is this poll, and pausing the poll pauses it. (A hung triggered run is still reported by the
#     job's entry point, as above.) If a 2h cycle has gone quiet while the trigger is paused, look at the
#     job's lock by hand: `ls -ld` / `ps -p $(cat <lockdir>/pid)`.
# _trg_stuck_sweep covers only what can really reach it: a SECOND invocation of this script while a run is
# in flight — an operator running it by hand to see why the release is quiet. That one reports at once.
#
# WHY THE TRIGGER DECIDES ON ONE SAMPLE, NOT "N POLLS IN A ROW" (ga-11vdhe item 2 — decided on data,
# 2026-09-26; do not add a persistence rule without re-running the measurement). The worry: 288 polls/day
# pick the MAX of a series that swings ±9 GB, so a pass is a peak, and free space may fall back before or
# during the GC. Measured on .gc/logs/disk-ballast-guard.log (`avail` every 2 min, 14 days = 9,566
# samples) and the 232 real dolt_gc runs since 30/07 in dolt-gc-maintenance.log that a sample brackets:
#   - across a real GC run free space ROSE by a median 214 MB; 11 of 232 lost > 1 GB, 4 > 2 GB, 2 > 3 GB,
#     1 > 5 GB (6.0 GB, a 275 s run). Real runs last median 19 s, p90 154 s, capped at 300 s by the
#     job's `timeout` — the exposure window is seconds to minutes, and the job re-measures `avail`
#     itself at run time (it never uses this trigger's number), so the trigger's sample is only a hint.
#   - after a passing sample, free space lost within 5 min: median 0.11 GB, p99 3.4 GB; P(> 3 GB) 1.5%,
#     P(> 5 GB) 0.3%. Requiring 2 (3) consecutive passing polls first lowers that to 1.2% (1.0%) and
#     0.25% — and barely moves the worst case (8.7 → 8.1 GB) — while doubling the median wait
#     for the first run (0.5 h → 1.0 h at a 9 GB bar, 2.4 h → 4.7 h at 11 GB, 4.4 h → 9.0 h at 12 GB).
#     And half of the peaks at 12 GB last under 10 min (median 8), so two polls would simply miss them —
#     the criterion the bead set for rejecting persistence.
#   - the direct bar (2 x hq + margin, 16.4 GB at hq 8.2 GB) was never reached in those 14 days; the
#     release bar (direct − staging + 2 GB slack ≈ 9 GB) was, on 39% of samples.
# Each kind of run therefore starts on a single passing sample, backs off per kind when refused, and the
# job's own re-measurement plus the unloosened 2x/2048MB gate are what protect the GC itself.
#
# POLL COST (ga-y0g5x doctrine: the guard must not become the load it watches). Measured
# 2026-09-26 on the live tree at load ~30-55 on 10 cores, whole script under /bin/bash 3.2:
#   healthy state (streak 0 — the ~always case):  ≈ 0.08 s CPU (the pre-ga-11vdhe poll: ≈ 0.085 s — the
#       state record is now read with builtins), 0.2–1.3 s wall (fork latency under load; most of it
#       is loading the job's library, ~0.35 s). The hung-holder check (_trg_poll step 0) is a directory test
#       when no run holds the lock: a 2 x 25-run A/B of the real script in a sandbox at load ~50 gave
#       0.074-0.078 s before it and 0.080-0.084 s after — about what its comments cost to parse. While a run
#       DOES hold the lock (only while the 2h job or a triggered run is live — a minority of polls) it also
#       forks the holder check (head/tr/ps/grep + stat): 0.090-0.095 s → 0.108-0.122 s on that poll.
#   chronic state: + one df and two du (~35 ms each), and — only when a release run would start on
#       THIS poll (past the backoff check, which is arithmetic and comes first) — the `ps -ax` busy
#       check (~1.2 s wall). A poll inside its backoff window, or one on the direct path, never forks it.
# StartInterval=300 ≫ any of these; ≈ 20 CPU-seconds/day in total. A pid-verified single-instance
# lock (same helper as the job) means a long child run can never stack polls.
#
# OBSERVABILITY: the state file (default .gc/runtime/packs/maintenance/dolt-gc-release-trigger.state)
# is rewritten every poll:
#   `poll=<epoch> decision=<KICK|WAIT reason> attempts=N next_allowed=<epoch> direct_attempts=N direct_next_allowed=<epoch>`
# (attempts/next_allowed are the RELEASE backoff, the names they always had; a record without the two direct_
# fields — written before ga-11vdhe — still reads, as direct 0/0) — its poll epoch is the liveness signal
# (during a long run it keeps the epoch the run began at and the decision ends in "(running)": see
# _trg_liveness, which the prod-test uses), `decision` says why nothing happened (a streak file the trigger
# cannot read shows as `WAIT streak-unreadable`, not as a healthy `streak-too-short`; a hung holder as
# `WAIT maintenance-stuck`). Changes of decision (and every started run + outcome) are logged to
# dolt-gc-maintenance.log with the numbers.
#
# KNOBS (operator file .gc/config/dolt-maintenance.env wins over env, as for the job):
#   GC_TRIGGER_ENABLED=0            kill switch (this trigger only; the 2h job is unaffected) — it also silences
#                                   the hung-holder report for a hung 2h-cycle run (see "WHO REPORTS A HUNG RUN")
#   GC_TRIGGER_BACKOFF_BASE_S=300   first retry delay after a run that left the skip streak standing
#   GC_TRIGGER_BACKOFF_MAX_S=7200   cap
#   GC_MAINT_LOCK_STUCK_H=3         a live lock holder older than this is reported as hung (job's knob, shared)
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
  # More than 9 digits is garbled too (the same rule as _dgm_stuck_limit_h): $(( )) wraps at 64 bits — under
  # bash 3.2 2^64 reads as 0 and 2^63 as negative — and a base or cap of 0 or below is NO backoff, i.e. a real
  # run on every poll. Length first, so nothing longer than that ever reaches the arithmetic.
  [ "${#max}" -le 9 ] || max=7200
  [ "${#s}" -le 9 ] || s=300
  # Operator knobs: "0300" is 300, not octal 192, and "0900" must not abort (see _gc_headroom_ok). Normalized
  # BEFORE the early return below, which echoes $max into the caller's $(( now + backoff )).
  max=$(( 10#$max )); s=$(( 10#$s ))
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

# _trg_state_load <file> — the four backoff values of a state record into _TRG_ATT/_TRG_NEXT (release) and
# _TRG_DATT/_TRG_DNEXT (direct); 0 for an absent file or a field it lacks. Builtins only: this runs on EVERY
# poll, healthy or not, and reading four keys through `head | awk` (what _trg_state_get does, one pipeline per
# key) was the one thing that made a poll dearer than before ga-11vdhe. Like _trg_state_get it is only
# meaningful after _trg_state_readable (a complete record or none); a value that is not all digits is ignored.
_trg_state_load() {
  local f="$1" line="" tok v had_f=1
  _TRG_ATT=0; _TRG_NEXT=0; _TRG_DATT=0; _TRG_DNEXT=0
  [ -f "$f" ] || return 0
  IFS= read -r line < "$f" 2>/dev/null
  case $- in *f*) ;; *) had_f=0; set -f ;; esac      # the record is split unquoted: no globbing of its words
  for tok in $line; do
    v="${tok#*=}"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    case "$tok" in
      attempts=*)            _TRG_ATT="$v" ;;
      next_allowed=*)        _TRG_NEXT="$v" ;;
      direct_attempts=*)     _TRG_DATT="$v" ;;
      direct_next_allowed=*) _TRG_DNEXT="$v" ;;
    esac
  done
  [ "$had_f" = "0" ] && set +f
  return 0
}

# _trg_state_readable <file> → 0 iff the file is ABSENT (a first run: genuinely no history) or holds
# one COMPLETE record: a first line of exactly
#   poll=<n> decision=<text> attempts=<n> next_allowed=<n> direct_attempts=<n> direct_next_allowed=<n>
# that ended in a newline (a write cut mid-number, `next_allowed=70` of `7000`, has no newline). The two
# direct_* fields are optional so a record written before ga-11vdhe (release backoff only) still reads —
# a cut BETWEEN them (`... direct_attempts=2` and nothing after) is NOT complete.
# 1 for anything else that exists — empty, garbled, partly written, a directory. That is a third
# state, not "no history": the backoff it held may be lost or wrong, so the poll treats it as
# "don't know" (stays inert once, says so, rewrites a clean state) rather than as zero attempts.
_trg_state_readable() {
  local nl
  [ -e "$1" ] || return 0
  [ -f "$1" ] || return 1
  nl="$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]')"
  case "$nl" in ''|*[!0-9]*|0) return 1 ;; esac
  # Numbers are canonical: "0" or no leading zero. A padded one ("attempts=08") can only be a hand edit — the
  # trigger writes its numbers from arithmetic — and read back through $(( )) it is OCTAL: 08/09 abort the poll
  # before it records anything (no run, no heartbeat), 007 is silently 7. Unreadable is the designed answer to
  # a hand edit: inert once, said out loud, a clean record rewritten (as _trg_streak_read does for its file).
  head -1 "$1" 2>/dev/null | grep -Eq '^poll=(0|[1-9][0-9]*) decision=.+ attempts=(0|[1-9][0-9]*) next_allowed=(0|[1-9][0-9]*)( direct_attempts=(0|[1-9][0-9]*) direct_next_allowed=(0|[1-9][0-9]*))?$'
}

# _trg_state_decision <file> → the last recorded decision text, "" if none.
_trg_state_decision() {
  [ -f "$1" ] && head -1 "$1" 2>/dev/null | sed -n 's/.* decision=\(.*\) attempts=[0-9]* next_allowed=[0-9]*\( direct_attempts=[0-9]* direct_next_allowed=[0-9]*\)\{0,1\}$/\1/p'
}

# _trg_state_write <file> <poll_epoch> <decision> <attempts> <next_allowed_epoch> <direct_attempts>
#                 <direct_next_allowed_epoch> → 0 iff written.
# One short line. attempts/next_allowed are the RELEASE backoff (the pre-ga-11vdhe names, kept: the record
# stays readable by anything that only knows those); direct_* is the DIRECT one. All six values are
# required — a caller that forgot the direct pair would silently zero a backoff it does not own — and a
# call with the wrong number of arguments writes nothing (returns 1: "could not record" → the poll stays
# inert). The write is truncate-then-write (not atomic), so a torn one is possible; it reads as
# UNREADABLE (see _trg_state_readable) and the next poll rewrites it — never as "no history".
_trg_state_write() {
  local f="$1"
  [ "$#" -eq 7 ] || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf 'poll=%s decision=%s attempts=%s next_allowed=%s direct_attempts=%s direct_next_allowed=%s\n' "$2" "$3" "$4" "$5" "$6" "$7" > "$f" 2>/dev/null
}

# _trg_outcome_read <file> <token> → what the job said about THE run started with <token>, as one word:
#   <outcome>    the job's own word (see _gc_record_outcome in dolt-gc-maintenance.sh), for a record that is
#                one complete line `token=<t> outcome=<word>` whose token IS <token>
#   absent       no file (the job never got as far as recording one: crashed, or exited on its lock)
#   stale        a well-formed record for a DIFFERENT run — never this run's answer
#   unreadable   anything else that exists: empty, cut mid-write, two lines, an extra field, a directory
# Never a guess: a record that cannot be attributed to this run says nothing about it. Builtins only.
_trg_outcome_read() {
  local f="$1" tok="$2" line="" extra="" rl=9 re=9 t o sep=" outcome="
  [ -e "$f" ] || { echo absent; return 0; }
  [ -f "$f" ] || { echo unreadable; return 0; }
  { IFS= read -r line; rl=$?; IFS= read -r extra; re=$?; } 2>/dev/null < "$f"
  { [ "$rl" = "0" ] && [ "$re" = "1" ] && [ -z "$extra" ]; } || { echo unreadable; return 0; }
  case "$line" in token=*" outcome="*) ;; *) echo unreadable; return 0 ;; esac
  t="${line#token=}"; t="${t%%$sep*}"; o="${line#*$sep}"
  case "$t" in ''|*[!0-9.]*) echo unreadable; return 0 ;; esac
  case "$o" in ''|*[!a-z-]*) echo unreadable; return 0 ;; esac
  [ "$t" = "$tok" ] || { echo stale; return 0; }
  echo "$o"
}

# _trg_liveness <state_file> <lockdir> <lock_re> <now> <max_idle_s> <max_run_s> → is the poll ALIVE?
#   alive          the state was rewritten within <max_idle_s> (every poll rewrites it, healthy or not)
#   alive-running  it was NOT, but its last decision is "... (running)" and the trigger lock is held by a live
#                  matching pid, and the run began less than <max_run_s> ago. A poll that starts the job blocks
#                  for the whole run (an S3 proof + dolt_gc of an ~8 GB hq can outlast any idle limit), and the
#                  state keeps the epoch it had when the run began — so "old state" alone is a false alarm
#                  during a healthy long run (ga-mb57np gate round 2, INFO).
#   stale          none of the above: not running, or running for <max_run_s> or longer (the stuck-holder alert
#                  reports that; calling it "alive" would hide it). <max_run_s> is the SAME number as the alert's
#                  limit — pass $(( $(_dgm_stuck_limit_h) * 3600 )) — and the boundary is the alert's too (at
#                  exactly the limit the alert fires, so the run is no longer "alive-running"): two thresholds for
#                  "a run that is too long" would have a healthy 3-4h run read as hung AND alive at once.
#   absent / unreadable   no state file / not one complete record
# Read-only; used by the ga-mb57np prod-test (which cannot use a fixed idle limit) and unit-tested here.
_trg_liveness() {
  local f="$1" lockdir="$2" re="$3" now="$4" idle="$5" maxrun="$6" poll age dec
  [ -e "$f" ] || { echo absent; return 0; }
  _trg_state_readable "$f" || { echo unreadable; return 0; }
  for age in "$now" "$idle" "$maxrun"; do
    case "$age" in ''|*[!0-9]*) echo unreadable; return 0 ;; esac
  done
  poll="$(_trg_state_get "$f" poll)"
  [ "$now" -ge "$poll" ] || { echo unreadable; return 0; }     # a poll in the future: a clock we cannot trust
  age=$(( now - poll ))
  [ "$age" -le "$idle" ] && { echo alive; return 0; }
  dec="$(_trg_state_decision "$f")"
  case "$dec" in
    *" (running)")
      if [ "$age" -lt "$maxrun" ] && _dgm_lock_held "$lockdir" "$re"; then echo alive-running; return 0; fi ;;
  esac
  echo stale
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
# triggered run by prefixing GC_TRIGGERED_RUN=1 (in effect for the call and exported to the job) and
# tells it WHICH kind (GC_TRIGGERED_KIND=direct|release — only a "release" run may touch the staging)
# and which run it is (GC_RUN_TOKEN, echoed back in the job's outcome record); all three are set at the
# call site so the selftest, which replaces this function, sees what the real call passes.
_trg_run_maintenance() {
  /bin/bash "$MAINT"
}

# _trg_set_backoff <kind> <attempts> <next_allowed> — put one kind's backoff pair into the poll's working
# record. The other kind's pair is not touched: a refused release run (aws traffic) must not hold back a
# direct run (none) and vice versa (ga-11vdhe). Anything but the two known kinds is refused (returns 1).
_trg_set_backoff() {
  case "$1" in
    release) _TRG_ATT="$2";  _TRG_NEXT="$3" ;;
    direct)  _TRG_DATT="$2"; _TRG_DNEXT="$3" ;;
    *) return 1 ;;
  esac
}

# _trg_record <now> <decision> — state write from the poll's working record (_TRG_ATT/_TRG_NEXT for the
# release backoff, _TRG_DATT/_TRG_DNEXT for the direct one) + change-only logging. Reading all four from
# the working record, not from arguments, is what keeps a call site from dropping the pair it does not own.
_trg_record() {
  local now="$1" decision="$2" prev
  prev="$(_trg_state_decision "$GC_TRIGGER_STATE")"
  _trg_state_write "$GC_TRIGGER_STATE" "$now" "$decision" "$_TRG_ATT" "$_TRG_NEXT" "$_TRG_DATT" "$_TRG_DNEXT" || {
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
  local now streak sk max_s lim size_mb avail_mb staging_mb target pct parts rel_on cool_ok decision kind att nxt busy backoff end run_rc rc_note token oc ocls why
  _TRG_STREAK=""; _TRG_AVAIL=""; _TRG_SIZE=""; _TRG_STAGING=""; _TRG_REQUIRED=""; _TRG_NOTE=""
  _TRG_ATT=0; _TRG_NEXT=0; _TRG_DATT=0; _TRG_DNEXT=0
  now="$(_gc_now_epoch)"
  case "$now" in ''|*[!0-9]*)
    # No clock → no backoff arithmetic, no cooldown, no readable heartbeat: nothing here can be
    # decided safely. (A blank epoch made `[ "$now" -lt "$next_allowed" ]` an error, i.e. false.)
    log "trigger: WARN cannot read the clock ('${now}') — no decision this poll, no state written (a stale heartbeat in $GC_TRIGGER_STATE is the signal)"
    return 0 ;;
  esac
  if ! _trg_state_readable "$GC_TRIGGER_STATE"; then
    # exists but unreadable: the backoff it held may be lost → don't act on a guess this poll.
    if _trg_state_write "$GC_TRIGGER_STATE" "$now" "WAIT state-unreadable" 0 0 0 0; then
      log "trigger: state file $GC_TRIGGER_STATE is unreadable (garbled/empty — a torn write or a hand edit) — no run this poll; reset to a clean record"
    else
      _trg_warn_hourly "$now" "trigger: state file $GC_TRIGGER_STATE is unreadable AND cannot be rewritten — no run until it is fixed (delete it, or restore write access)"
    fi
    return 0
  fi
  _trg_state_load "$GC_TRIGGER_STATE"
  # A backoff never reaches further ahead than its own cap: one written under a clock that ran fast
  # (or by a hand edit) must not hold the trigger inert for days. Both kinds.
  max_s="$GC_TRIGGER_BACKOFF_MAX_S"; case "$max_s" in ''|*[!0-9]*) max_s=7200 ;; esac
  [ "${#max_s}" -le 9 ] || max_s=7200   # 10+ digits wrap in $(( )) (2^64 reads as 0 = every backoff clamped away): garbled → the default, as in _trg_backoff_s
  max_s=$(( 10#$max_s ))   # an operator knob: "08" must not abort the poll, "0300" is 300 (see _gc_headroom_ok)
  [ "$_TRG_NEXT" -gt $(( now + max_s )) ] && _TRG_NEXT=$(( now + max_s ))
  [ "$_TRG_DNEXT" -gt $(( now + max_s )) ] && _TRG_DNEXT=$(( now + max_s ))

  # 0) a HUNG maintenance holder is reported first, before anything that can return early on unrelated grounds
  #    (ga-11vdhe, gate round 4). The hang this exists for is a 2h-cycle run stuck in `bd purge` (no timeout):
  #    its holder is launchd's own instance of the JOB, and launchd runs one process per label, so the job's
  #    entry check does not get to say so — this poll, another label, is the reporter (see the header). It
  #    used to sit behind the streak gate below, and a healthy streak (the ~always case) returned
  #    `WAIT streak-too-short` first: "did not look" recorded as "looked, nothing there". A run hung in
  #    `bd purge` never reaches the step that writes the streak, so whatever the streak was when the hang
  #    began — healthy, usually — is what every later poll keeps seeing. Read-only and deduped per holder
  #    (see _dgm_lock_stuck_check);
  #    it never touches the lock. The `[ -d ]` keeps the always-case cost at a directory test — no holder,
  #    no fork. A young holder (a run merely in flight) falls through: what the gates below say about it is
  #    unchanged.
  if [ -d "$GC_MAINT_LOCKDIR" ] && _dgm_lock_stuck_check "$GC_MAINT_LOCKDIR" "$GC_MAINT_LOCK_RE" "dolt-gc-maintenance"; then
    lim="$(_dgm_stuck_limit_h)"; case "$lim" in ''|*[!0-9]*|0) lim=3 ;; esac   # blank = a failed $(...) under fork pressure: the alert's own fallback
    _TRG_NOTE="its holder has had the lock for over ${lim}h — see the ALERT line above"
    _trg_record "$now" "WAIT maintenance-stuck"; return 0
  fi

  # 1) cheapest first: not chronic → the 2h cycle owns this; no disk read at all. The streak is read
  #    strictly (see _trg_streak_read): "no streak" and "cleared" are KNOWN states (streak 0), a file
  #    that exists but cannot be read is not — it is neither "not chronic" nor "chronic".
  sk="$(_trg_streak_read "$GC_SKIP_STREAK_STATE")"
  case "$sk" in
    absent|cleared) streak=0 ;;
    "standing "*)   streak="${sk#standing }" ;;
    *) _TRG_NOTE="skip-streak file $GC_SKIP_STREAK_STATE is not a complete '<n> <0|1>' line — cannot tell whether hq is skipping"
       _trg_record "$now" "WAIT streak-unreadable"; return 0 ;;
  esac
  _TRG_STREAK="$streak"
  if _trg_pos_int "$GC_RELEASE_MIN_STREAK" && [ "$streak" -lt "$GC_RELEASE_MIN_STREAK" ]; then
    # Known and below the minimum: any earlier episode is over — a backoff belongs to the episode that
    # earned it, so the next chronic episode starts at attempt 1, not near the cap. (Both kinds.)
    _TRG_ATT=0; _TRG_NEXT=0; _TRG_DATT=0; _TRG_DNEXT=0
    _trg_record "$now" "WAIT streak-too-short"; return 0
  fi
  # (an unusable minimum — 0, blank, non-numeric — falls through: _gc_trigger_decision refuses it below)

  # 2) a maintenance run in flight owns the job (and the staging) right now. (One that has held the lock for
  #    hours is not "in flight", it is hung — step 0 above has already said so and returned.)
  if _dgm_lock_held "$GC_MAINT_LOCKDIR" "$GC_MAINT_LOCK_RE"; then
    _trg_record "$now" "WAIT maintenance-running"; return 0
  fi

  # 3) measure. One df + two du.
  case "$THRESHOLD_G" in ''|*[!0-9]*)
    _trg_record "$now" "WAIT unmeasurable-input"; return 0 ;;   # a garbled knob is not "no threshold"
  esac
  size_mb="$(_trg_dir_mb "$DOLTDIR")"; _TRG_SIZE="$size_mb"
  case "$size_mb" in ''|*[!0-9]*) ;; *)   # unmeasurable size: _gc_trigger_decision refuses it below
    if [ $(( size_mb / 1024 )) -lt "$THRESHOLD_G" ]; then
      _trg_record "$now" "WAIT hq-below-threshold"; return 0   # the job would skip: nothing to start
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
    WAIT*) _trg_record "$now" "$decision"; return 0 ;;
    *) _TRG_NOTE="unrecognized decision '${decision}'"
       _trg_record "$now" "WAIT unknown-decision"; return 0 ;;
  esac
  kind="${decision#KICK }"

  # 4) eligible. Cheapest veto first: the backoff is arithmetic — and it is the backoff of THIS kind:
  #    a refused release run (which may have gone as far as an S3 proof) must not sit out the peak that
  #    lets the GC run directly, with no aws at all (ga-11vdhe). Only then, on the release path, the one
  #    veto that costs a `ps -ax` (~1.2 s at load) but is free to re-check and must not escalate the
  #    backoff: something is writing the staging right now.
  case "$kind" in release) att="$_TRG_ATT"; nxt="$_TRG_NEXT" ;; *) att="$_TRG_DATT"; nxt="$_TRG_DNEXT" ;; esac
  if [ "$now" -lt "$nxt" ]; then
    _trg_record "$now" "WAIT backoff"; return 0
  fi
  if [ "$kind" = "release" ] && busy="$(_gc_release_busy "$target")"; then
    _trg_record "$now" "WAIT staging-busy:${busy}"; return 0
  fi

  # 5) start the job. The attempt is recorded BEFORE the run: if it cannot be recorded there is no
  #    backoff to rely on → do not start; and a crash mid-run keeps the backoff in force.
  att=$(( att + 1 ))
  backoff="$(_trg_backoff_s "$att")"
  _trg_set_backoff "$kind" "$att" "$(( now + backoff ))"
  if ! _trg_state_write "$GC_TRIGGER_STATE" "$now" "$decision (running)" "$_TRG_ATT" "$_TRG_NEXT" "$_TRG_DATT" "$_TRG_DNEXT"; then
    _trg_warn_hourly "$now" "trigger: cannot write $GC_TRIGGER_STATE — not starting a run (an attempt that cannot be recorded cannot be backed off)"
    return 0
  fi
  token="${now}.$$"
  log "trigger: ${decision} — streak=${streak} avail=${avail_mb}MB size=${size_mb}MB staging=${staging_mb}MB required=${_TRG_REQUIRED}MB → starting dolt-gc-maintenance as a triggered ${kind} run (attempt ${att})"
  GC_TRIGGERED_KIND="$kind" GC_RUN_TOKEN="$token" GC_TRIGGERED_RUN=1 _trg_run_maintenance; run_rc=$?
  end="$(_gc_now_epoch)"
  case "$end" in ''|*[!0-9]*) end="$now" ;; esac   # never a blank: the poll's own start is a lower bound of the true time
  rc_note=""; [ "$run_rc" -ne 0 ] && rc_note=" (the job exited rc=${run_rc}: it could not start, or it crashed)"

  # 6) what happened? Two signals, and a run counts as SUCCESSFUL only when they AGREE (ga-11vdhe):
  #    - the job's own OUTCOME record for this run (token-matched — see _trg_outcome_read). Until now the
  #      trigger had only the second signal and inferred success from it.
  #    - the job's skip-streak file, "cleared" being exactly the record it writes when its size-gated step
  #      does NOT skip (it attempted dolt_gc, or found hq under the threshold).
  #    "Success" needs the streak cleared AND an outcome that says the step reached its end (gc-ok,
  #    gc-failed — the job already alerted — or below-threshold, which the job records only for an hq it
  #    MEASURED under the threshold). Anything else — a standing or unreadable streak, no outcome for this
  #    run (crashed / exited on its lock / could not write it), an outcome that says it skipped (including
  #    size-unmeasurable: the job could not measure hq and decided nothing), or a word this trigger does
  #    not know — is NOT success: "could not tell" is treated like "still standing" (attempt counted,
  #    backoff armed), never like "it worked".
  sk="$(_trg_streak_read "$GC_SKIP_STREAK_STATE")"
  oc="$(_trg_outcome_read "$GC_RUN_OUTCOME_STATE" "$token")"
  case "$oc" in
    gc-ok|gc-failed|below-threshold)                        ocls=terminal ;;
    skip-headroom|release-not-taken|released-still-short|size-unmeasurable)   ocls=skipped ;;
    absent|stale|unreadable)                                ocls=none ;;
    *)                                                      ocls=unknown ;;
  esac
  if [ "$sk" = "cleared" ] && [ "$ocls" = "terminal" ]; then
    log "trigger: run finished — outcome=${oc}, the skip streak is cleared; backoff reset${rc_note}"
    _TRG_ATT=0; _TRG_NEXT=0; _TRG_DATT=0; _TRG_DNEXT=0
    _trg_state_write "$GC_TRIGGER_STATE" "$end" "$decision" 0 0 0 0 || log "trigger: WARN could not record the outcome in $GC_TRIGGER_STATE"
    return 0
  fi
  case "$sk" in
    "standing "*)
      case "$ocls" in
        skipped)  why="the job refused (its own outcome: ${oc}; its log lines say why)" ;;
        terminal) why="INCONSISTENT — the job says outcome=${oc} but its skip streak is still standing" ;;
        *)        why="the job's outcome for this run is '${oc}' — it refused or did not get that far" ;;
      esac
      why="run finished WITHOUT clearing the skip streak (streak=${sk#standing }) — ${why}" ;;
    cleared)
      why="run finished but cannot confirm the step reached its end — the streak file says cleared while the job's outcome for this run is '${oc}'" ;;
    *)
      why="run finished but the skip-streak file is ${sk} ($GC_SKIP_STREAK_STATE) and the job's outcome for this run is '${oc}' — cannot tell whether the job cleared it" ;;
  esac
  log "trigger: ${why}; this counts as NOT cleared (attempt ${att} of the ${kind} backoff, next ${kind} attempt not before +${backoff}s)${rc_note}"
  _trg_set_backoff "$kind" "$att" "$(( end + backoff ))"
  _trg_state_write "$GC_TRIGGER_STATE" "$end" "$decision" "$_TRG_ATT" "$_TRG_NEXT" "$_TRG_DATT" "$_TRG_DNEXT" || log "trigger: WARN could not record the outcome in $GC_TRIGGER_STATE"
  return 0
}

# _trg_stuck_sweep — a second invocation that finds the trigger lock held (a run in flight) is silent and
# cheap by design, which is also how a HUNG run stays invisible to it. Under launchd that invocation does not
# exist (a label never overlaps, and the poll that started the run is blocked inside it), so a hung
# TRIGGERED run is reported in production by the 2h job's entry point instead (see the header). This is for
# the invocation that CAN happen: someone running the script by hand while a run is in flight. Check the two
# locks a hung triggered run holds — the job's first (that is the one that blocks all maintenance), the
# trigger's own only if the job's is not stuck, so one hang is one alert. Alerts at most once per holder
# (see _dgm_lock_stuck_check); never touches a lock.
_trg_stuck_sweep() {
  _dgm_lock_stuck_check "$GC_MAINT_LOCKDIR" "$GC_MAINT_LOCK_RE" "dolt-gc-maintenance" \
    || _dgm_lock_stuck_check "$GC_TRIGGER_LOCKDIR" "$GC_TRIGGER_LOCK_RE" "dolt-gc-release-trigger" trigger \
    || true
  return 0
}

# trigger_main — kill switch, single-instance lock, one poll.
trigger_main() {
  local lrc dnow da=0 dn=0 dda=0 ddn=0
  if [ "$GC_TRIGGER_ENABLED" != "1" ]; then
    # A pause, not a reset: keep BOTH recorded backoffs (only when it is a complete record — an unreadable
    # one is not trusted) so re-enabling does not forget them. No clock → no record (a blank poll= would
    # make the file unreadable and cost the next enabled poll its one inert turn).
    dnow="$(_gc_now_epoch)"
    case "$dnow" in ''|*[!0-9]*) return 0 ;; esac
    if _trg_state_readable "$GC_TRIGGER_STATE"; then
      _trg_state_load "$GC_TRIGGER_STATE"
      da="$_TRG_ATT"; dn="$_TRG_NEXT"; dda="$_TRG_DATT"; ddn="$_TRG_DNEXT"
    fi
    _trg_state_write "$GC_TRIGGER_STATE" "$dnow" "DISABLED" "$da" "$dn" "$dda" "$ddn" || true
    return 0
  fi
  _dgm_lock_acquire "$GC_TRIGGER_LOCKDIR" "$GC_TRIGGER_LOCK_RE"; lrc=$?
  # 1 = another invocation (or the run it started) holds the lock — under launchd this is not reachable
  # (one poll at a time; the running poll is blocked in its run), so it is a manual second run; silent
  # unless the holder has been live for hours (_trg_stuck_sweep). 2 = the lock dir cannot be created —
  # inert but NOT silent. Either way this trigger is optional; the 2h cycle is untouched.
  if [ "$lrc" -eq 2 ]; then
    log "trigger: WARN cannot create the trigger lock $GC_TRIGGER_LOCKDIR — staying inert this poll (no run can start without single-instance protection)"
    return 0
  fi
  if [ "$lrc" -eq 1 ]; then _trg_stuck_sweep; return 0; fi
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
