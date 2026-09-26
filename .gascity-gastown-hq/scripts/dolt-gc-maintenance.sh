#!/bin/bash
# dolt-gc-maintenance.sh — keeps the city's hq beads store lean automatically.
#
# THREE independently-gated layers of upkeep. Mostly SILENT on success (Athos
# preference) — FAILURE always notifies, and (ga-azzfw) a sustained headroom-skip
# streak or a no-effect gc run also notify. Run by launchd every 2h.
#
#   1. EPHEMERAL PURGE  (ALWAYS ON)  — `bd purge` removes CLOSED *ephemeral* beads
#      (ephemeral=1: gate-reviewer sessions, terminal gate markers). Cheap. The >2h
#      cutoff guarantees we never touch a bead from a live gate run (runs finish <45m).
#
#   2. NON-EPHEMERAL PRUNE  (OPT-IN: PRUNE_ENABLED=1)  — `bd prune` removes CLOSED
#      *non-ephemeral* beads (ephemeral=0 tasks/chores/sessions) older than
#      PRUNE_KEEP_DAYS. These live in BOTH the `issues` and the `wisps` tables and are
#      caught by NEITHER the ephemeral purge (skips ephemeral=0) NOR the online gc.
#      ── THIS is the fix for the 2026-07-02 gate stall ──
#      hq.wisps bloated to 37,810 rows (97.8% closed ephemeral=0 task beads: 31,685).
#      Concurrent full-table reconcile scans over that bloat drove Dolt CPU to ~194%
#      sustained → the gate stopped producing verdicts for 20+ min. A manual
#      `bd prune --older-than 3d --force` (~22,900 rows) dropped CPU to ~43%. The
#      pipeline churns ~20k task beads/week, so the table re-bloats to 37k in ~10 days
#      without a routine. Prune stops the ROW-COUNT growth that drives the scans.
#      Bounded (PRUNE_MAX_PER_RUN — never a catastrophic single delete), backup-gated,
#      skip-when-hot, oldest-first. Because this job runs every 2h, steady state prunes
#      only the thin slice that just crossed the retention boundary (~hundreds/run),
#      never a big batch. Prune archives every deleted bead to
#      .gc/runtime/packs/maintenance/jsonl-archive/<store>/ (recoverable). DEFAULT OFF.
#
#   3. ONLINE GC + weekly FLATTEN  — `dolt_gc()` (size-triggered, ALWAYS ON) reclaims
#      unreferenced commit history (~1.4G/10h git-like bloat; the 2026-06-07 outage
#      root cause). `bd flatten` (OPT-IN: FLATTEN_ENABLED=1, weekly, off-peak) collapses
#      history so chunks freed by prune can GC off DISK. Flatten is HEAVY and
#      IRREVERSIBLE (destroys all Dolt commit history / time-travel) — DEFAULT OFF,
#      backup-gated, at most once per ISO-week inside a quiet local-hour window.
#      ga-sfj3i.4: the size-gated dolt_gc() call is now ALSO gated on disk headroom
#      (GC_MIN_FREE_PCT, 200-280% of hq's own on-disk size depending on
#      PRUNE_ENABLED — see GC_MIN_FREE_PCT_BASE/_WITH_PRUNE and
#      _gc_headroom_ok/_gc_floor_ok below for the measured basis; ga-3euoj
#      re-calibrated the flat 250% default after hq's growth made it permanently
#      unreachable). Before this fix it had ZERO disk-space
#      awareness and ran unconditionally every 2h whenever hq>=THRESHOLD_G (i.e.
#      continuously, since hq is essentially always over that floor) — a
#      disk-exhausted dolt_gc mid-store-rewrite can panic the WHOLE Dolt server
#      (all databases, not just hq), see ga-vs55. This step also has NO awareness
#      of hq's own compact-quarantine marker (a separate, narrower concern about
#      post-FLATTEN integrity verification that a bare dolt_gc() — no flatten
#      involved — does not share; deliberately left alone here, out of scope for
#      this fix).
#
#      ga-azzfw: the headroom skip above is now ALSO tracked as a consecutive-cycle
#      streak (GC_SKIP_STREAK_STATE) — 3 in a row (~6h @ 2h cadence) notifies + mails
#      the Mayor ONCE per streak, so a stuck skip can't go unnoticed for days the way
#      it did in ga-3euoj (found only by manual investigation, after disk had already
#      touched Dolt's CRITICAL floor twice). The streak clears the moment dolt_gc() is
#      next ATTEMPTED (success or failure — a SQL failure is a separate, already-
#      alerted condition). A dolt_gc() that runs to completion but reclaims no space
#      (post>=pre) is also flagged, once per occurrence — see _handle_gc_skip_streak
#      and _gc_no_effect below.
#
# Size-triggered gc (not pure time) self-adjusts to the bloat rate and never gc's a
# store that's already small. See memory: gate-reviewer-spawn-failure-playbook,
# post-outage-remaining-tech-debt, dolt-cpu-root-is-poll-frequency-not-query-ftmci.
#
# ── ENABLE (Mayor reviews the dry-run, then turns it on) ────────────────────────
# The prune/flatten schedule is STAGED OFF. Enable with a LOCAL (gitignored) toggle —
# takes effect on the next 2h cycle, NO launchd reload, NO code change:
#
#   mkdir -p /Users/athos/gt/.gascity-gastown-hq/.gc/config
#   printf 'PRUNE_ENABLED=1\n' \
#     > /Users/athos/gt/.gascity-gastown-hq/.gc/config/dolt-maintenance.env
#
# Optional deep on-disk reclaim (irreversible history loss): also add FLATTEN_ENABLED=1.
# Tune with PRUNE_KEEP_DAYS / PRUNE_MAX_PER_RUN in that same file.
# Disable: delete the file (or set PRUNE_ENABLED=0). Precedence: file > env > default.
#
# ── TEST (no Dolt, no deletions) ────────────────────────────────────────────────
#   bash scripts/dolt-gc-maintenance.selftest.sh   # unit-tests the decision logic
# Library mode: `DOLT_GC_MAINT_LIB=1 source dolt-gc-maintenance.sh` defines the pure
# decision functions WITHOUT running the maintenance flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"

# ga-0bjqix: canonical PID resolution (dolt.pid + basename+LISTEN verification,
# never a bare process-table sort). Sourced directly (not only transitively via
# the optional gc-dolt-probe.sh below) so the fallback branch of _dolt_cpu_pct
# is covered too. See dolt-pid-lib.sh.
# shellcheck source=dolt-pid-lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/dolt-pid-lib.sh"

DB="hq"
PORT="52756"
THRESHOLD_G="1"            # online gc when hq store >= 1 GB (ga-ftmci: re-bloats fast;
                           # a bigger store slows the per-rig reconcile full-table scan).
# ga-3euoj: GC_MIN_FREE_PCT's default depends on PRUNE_ENABLED — resolved in main()
# via _resolve_gc_min_free_pct, once PRUNE_ENABLED/the conf file below are final. An
# explicit pin here (env or the operator conf file) still wins outright either way.
GC_MIN_FREE_PCT_BASE="${GC_MIN_FREE_PCT_BASE:-200}"  # ga-3euoj: measured — of 665 real
                           # online dolt_gc() runs on hq with no prune batch in the same
                           # cycle (2026-06-08..09-05, hq 483MB..10GB, under normal
                           # concurrent city write load), the worst post/pre ratio EVER
                           # observed was exactly 1.000 (store never grew) — matching
                           # _gc_headroom_ok's documented 2x/"nothing collected"
                           # worst-case bound with zero real violations.
GC_MIN_FREE_PCT_WITH_PRUNE="${GC_MIN_FREE_PCT_WITH_PRUNE:-280}"  # ga-3euoj: of 235 runs
                           # where a prune BATCH ran in the same invocation right before
                           # dolt_gc() (deletes are new commits; nothing collects their
                           # garbage yet), the store grew PAST its pre-gc size twice —
                           # worst ratio 1.7358 (2026-07-25, 2026-08-16) = 273.6%
                           # implied peak, breaking the "post<=pre" assumption the base
                           # bound above relies on. 280 covers that with a small margin;
                           # applies only while PRUNE_ENABLED=1 can produce that burst.
GC_MIN_FREE_ABS_MB="${GC_MIN_FREE_ABS_MB:-3072}"  # ga-3euoj: absolute floor alongside
                           # the percentage gate — never let dolt_gc()'s worst-case
                           # extra disk use (up to size_mb) push avail below Dolt's
                           # CRITICAL level (3GB: a disk-exhausted GC mid-rewrite can
                           # panic the WHOLE server, not just hq — ga-vs55). The
                           # percentage alone only guarantees this by coincidence while
                           # hq is big; see _gc_floor_ok below.
GC_SKIP_ALERT_THRESHOLD="${GC_SKIP_ALERT_THRESHOLD:-3}"  # ga-azzfw: consecutive
                           # headroom-skip CYCLES (2h launchd cadence, so 3 = ~6h)
                           # before alerting the Mayor. The ga-3euoj incident skipped
                           # silently for DAYS because the skip line only reaches a log
                           # nobody reads — this makes that "if it skips again, reopen"
                           # criterion automatic instead of depending on a human read.
                           # One alert per STREAK, not one per cycle past the
                           # threshold — see _skip_streak_next.
GC_SKIP_STREAK_STATE="${GC_SKIP_STREAK_STATE:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-skip-streak.state}"
# ga-mb57np: single-instance lock. launchd only serializes runs of its OWN label; a manual run,
# or the run dolt-gc-release-trigger.sh starts, is invisible to it — and two overlapping runs
# could both reach dolt_gc() / the staging release. GC_MAINT_LOCK_RE is what a live holder's
# command line must match for its pid to count (guards against pid reuse after a crash).
GC_MAINT_LOCKDIR="${GC_MAINT_LOCKDIR:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-maintenance.lock.d}"
GC_MAINT_LOCK_RE="${GC_MAINT_LOCK_RE:-dolt-gc-maintenance}"
# ga-11vdhe: a lock is "held" for as long as its pid is alive — with no ceiling, one hung run (a Dolt
# that stopped answering `bd purge`, which has no timeout) silently makes EVERY later run exit on the
# lock: purge, prune and the GC all skipped, and nothing says the holder is hours old. A live pid is
# never stolen from; instead, once its lock is older than this many hours, the first run/poll that
# sees it says so loudly and notifies ONCE for that holder (see _dgm_lock_stuck_check). 3h is more
# than one 2h cycle (a run that is merely slow is not flagged) and well under "a day of skipped GC".
# A garbled or zero value falls back to 3 — never to "no alert". A zero-padded whole number ("08") is
# that number (8), see _dgm_stuck_limit_h.
GC_MAINT_LOCK_STUCK_H="${GC_MAINT_LOCK_STUCK_H:-3}"
# ga-11vdhe: what a TRIGGERED run reports back (see _gc_record_outcome). One short file, overwritten
# by each triggered run; the trigger reads it only when the token it handed the run matches.
GC_RUN_OUTCOME_STATE="${GC_RUN_OUTCOME_STATE:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-run-outcome.state}"
LOG="${DOLT_GC_MAINT_LOG:-$CITY/.gc/logs/dolt-gc-maintenance.log}"
NOTIFY="/Users/athos/.local/bin/notify"
DOLTDIR="$CITY/.beads/dolt/$DB"
BD="$(command -v bd 2>/dev/null || echo /Users/athos/.local/bin/bd)"
GC="${GC_BIN:-gc}"  # ga-azzfw: mirrors dolt-disk-floor-guard.sh / dolt-compact-routine.sh —
                    # used only for `gc mail send mayor` (skip-streak + no-effect alerts
                    # below); this script had no mail dependency before.

# ── non-ephemeral PRUNE knobs (all default-safe; operator file overrides below) ──
PRUNE_ENABLED="${PRUNE_ENABLED:-0}"                 # 0 = STAGED OFF (the Mayor enables)
PRUNE_KEEP_DAYS="${PRUNE_KEEP_DAYS:-3}"             # keep closed non-ephemeral beads this long
PRUNE_MAX_PER_RUN="${PRUNE_MAX_PER_RUN:-3000}"      # per-run deletion CEILING (CPU-spike guard)
PRUNE_STORES="${PRUNE_STORES:-$CITY:hq}"            # space-sep "bd_dir:db" pairs; default hq only.
                                                    # db names the backup-staging + jsonl-archive
                                                    # subdir (hq's bd dir basename != its db name).
                                                    # Add rigs e.g. "/path/to/rig:property_scrapers".
PRUNE_SKIP_CPU_PCT="${PRUNE_SKIP_CPU_PCT:-150}"     # skip prune if dolt %cpu above this
PRUNE_REQUIRE_BACKUP="${PRUNE_REQUIRE_BACKUP:-1}"   # 1 = require a same-day backup first
PRUNE_BACKUP_MAX_AGE_H="${PRUNE_BACKUP_MAX_AGE_H:-26}"
BACKUP_STAGING="${BACKUP_STAGING:-$CITY/.dolt-backup}"

# ── ga-btnq6h: release hq's LOCAL backup staging to make room for dolt_gc ───────────
# hq's dolt_gc() needs ~2x hq's own size free (measured worst case, ga-3euoj) — ~15.5 GB
# at 7.7 GB — while free space peaks near 14 GB and swings 3–14 GB. The one large,
# REDUNDANT block on that disk is hq's local backup staging (.dolt-backup/hq, ~8.8 GB):
# S3 mirrors it, and a separate 6-hourly job (mol-dog-backup) rebuilds it by incremental
# sync. MEASURED 2026-09-25: 53 consecutive headroom skips (~106 h); hq grew 3.9 → 7.7 GB
# since the last real GC (08-20), which raises the bar each cycle — a vicious circle no
# amount of waiting resolves. So, when the skip is CHRONIC and S3 is PROVEN to hold an
# identical, restorable copy, free the staging for the GC window (see
# _gc_maybe_release_staging below). Every guard is fail-closed; the release is the only act in
# this file that deletes BACKUP data (prune/flatten act on live beads, behind their own gates),
# and it is never taken on a guess.
GC_RELEASE_STAGING_ENABLED="${GC_RELEASE_STAGING_ENABLED:-1}"   # 0 = never release (kill switch)
GC_RELEASE_STAGING_DRYRUN="${GC_RELEASE_STAGING_DRYRUN:-0}"     # 1 = decide + log WOULD RELEASE, delete nothing
GC_RELEASE_MIN_STREAK="${GC_RELEASE_MIN_STREAK:-6}"     # consecutive headroom-skip cycles (2h each ≈ 12h): chronic, not a blip
GC_RELEASE_SLACK_MB="${GC_RELEASE_SLACK_MB:-2048}"      # headroom must clear the gate by this much AFTER the release
GC_RELEASE_COOLDOWN_H="${GC_RELEASE_COOLDOWN_H:-168}"   # at most one release per week (a no-effect GC must not loop delete→rebuild)
GC_RELEASE_STATE="${GC_RELEASE_STATE:-$CITY/.gc/runtime/packs/maintenance/dolt-gc-staging-release.state}"
GC_RELEASE_BACKUP_LOCKDIR="${GC_RELEASE_BACKUP_LOCKDIR:-$CITY/.gc/logs/.dolt-s3-backup.lock.d}"   # dolt-s3-backup.sh's single-instance lock
# A process that writes to the staging RIGHT NOW: the backup scripts (as a script token),
# or a dolt backup sync/restore. Matched against `ps -axo command=`; on doubt → busy.
GC_RELEASE_WRITER_RE="${GC_RELEASE_WRITER_RE:-(^|[ /])(mol-dog-backup|dolt-s3-backup|dolt-backup-reseed|dolt-backup-swap-repair|dolt-backup-residue-reclaim|dolt-compact-routine|dolt-offline-backup-sync)\\.sh( |\$)|dolt( .*)? backup (sync|restore)|DOLT_BACKUP}"
AWS="${AWS:-$(command -v aws 2>/dev/null || echo /opt/homebrew/bin/aws)}"     # read by dolt-backup-s3-proof.sh
BUCKET="${BUCKET:-urblink-dolt-backups}"                                        # read by dolt-backup-s3-proof.sh
S3PROOF_LOG="${S3PROOF_LOG:-$LOG}"                                              # upload output of the proof lib goes to the same log

# ── weekly FLATTEN knobs (deep on-disk reclaim; IRREVERSIBLE history loss) ───────
FLATTEN_ENABLED="${FLATTEN_ENABLED:-0}"
FLATTEN_STORES="${FLATTEN_STORES:-$CITY:hq}"        # "bd_dir:db" pairs (see PRUNE_STORES)
FLATTEN_QUIET_START="${FLATTEN_QUIET_START:-3}"     # local-hour window start (inclusive)
FLATTEN_QUIET_END="${FLATTEN_QUIET_END:-7}"         # local-hour window end   (exclusive)
FLATTEN_WEEK_SENTINEL="${FLATTEN_WEEK_SENTINEL:-$CITY/.gc/logs/.dolt-flatten.week}"

# ── operator override file (LOCAL, gitignored) — THE enable point (file wins) ───
DOLT_MAINT_CONF="${DOLT_MAINT_CONF:-$CITY/.gc/config/dolt-maintenance.env}"
# shellcheck disable=SC1090
[ -f "$DOLT_MAINT_CONF" ] && . "$DOLT_MAINT_CONF"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# optional shared Dolt-health probe (reuse gc-dolt-probe.sh; fall back to ps)
_PROBE="$CITY/scripts/gc-dolt-probe.sh"
# shellcheck disable=SC1090
[ -f "$_PROBE" ] && . "$_PROBE" 2>/dev/null || true

# ga-btnq6h: manifest-closure S3 proof + additive mirror (shared with dolt-s3-backup.sh).
# A missing/unloadable lib leaves _s3proof_* undefined; every use below treats that as
# "NOT proven" (command-not-found is non-zero), so the release stays inert.
# shellcheck source=dolt-backup-s3-proof.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/dolt-backup-s3-proof.sh" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by dolt-gc-maintenance.selftest.sh.
# No side effects; the read-only counter is injectable (stubbed in the selftest).
# ════════════════════════════════════════════════════════════════════════════════

# _dolt_cpu_pct → integer dolt %cpu, or "" if unknown. Never hangs (ps is local).
_dolt_cpu_pct() {
  local c
  if declare -f _gc_dolt_cpu_pct >/dev/null 2>&1; then
    c="$(_gc_dolt_cpu_pct)"
  else
    local pid; pid="$(dolt_server_pid || true)"
    [ -z "$pid" ] && { echo ""; return; }
    c="$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')"
  fi
  # strip the fractional part — ps renders it with a LOCALE decimal separator
  # ('.' OR ',', e.g. "62,4" under pt_BR). Both must reduce to a bare integer, else
  # the numeric guard in _should_skip_hot rejects "62,4" and fails open → the hot-check
  # would never fire (it wouldn't skip even at 194%). Handle both separators.
  case "$c" in ''|'?') echo ""; return ;; esac
  c="${c%%.*}"; c="${c%%,*}"; echo "$c"
}

# _should_skip_hot <cpu_pct> <threshold> → 0 = skip (hot), 1 = proceed.
# Empty/unknown cpu → proceed (fail-open; the health probe is the harder gate).
_should_skip_hot() {
  local cpu="$1" thr="$2"
  case "$cpu" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cpu" -gt "$thr" ]
}

# _avail_mb [path] — free space in MB, empty (not 0) on failure. Same idiom as
# dolt-compact-routine.sh's own _avail_mb (`df -k` + one division; macOS/BSD df
# has no -g) — matched deliberately for consistency across this codebase's two
# dolt-gc-adjacent scripts. Empty, not 0: a failed read must never read the
# same as "plenty of room" (error and empty must not produce the same value).
_avail_mb() {
  local path="${1:-$DOLTDIR}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 ))
}

# _gc_headroom_ok <avail_mb> <db_size_mb> <pct> → 0 = enough room to run
# dolt_gc(), 1 = not enough (or unmeasurable — fail-closed). Pure arithmetic,
# same shape as dolt-compact-routine.sh's _headroom_ok.
#
# ga-sfj3i.4: measured 2026-08-26 (isolated copy of gastown, flattened then
# `dolt gc --full`, disk usage polled every ~0.1s during the call): peak
# disk usage during gc tracked pre-gc-size + the size of the live data being
# rewritten into the new generation (peak=38376KB, pre-gc=35228KB,
# live-after-gc=3180KB; 35228+3180=38408, matches within sampling noise).
# Live data can never exceed the pre-gc size, so that additive relationship
# bounds the worst case (a db with nothing to collect as garbage) at 2x
# pre-gc size. ga-3euoj: GC_MIN_FREE_PCT is no longer a flat 250 — see
# GC_MIN_FREE_PCT_BASE / _WITH_PRUNE above and _resolve_gc_min_free_pct below
# for the measured, prune-conditional replacement.
#
# ga-11vdhe: the numbers an operator supplies to the headroom/floor gate, the staging release (slack), the
# release cooldown, the trigger's backoff and the stuck-holder limit are put through `10#` before they meet
# $(( )) — here, in the functions below, and in dolt-gc-release-trigger.sh. A digits-only check accepts "08"
# and "0250", and in $(( )) a leading 0 means OCTAL: "08"/"09" abort the shell ("value too great for base";
# under /bin/bash 3.2 the enclosing command is discarded), and "0250" is silently 168 — for this gate
# that would quietly lower the free space it demands. (`[ -ge ]` reads decimal and needs no help.)
# Measured numbers (du, df, the clock) never carry a leading zero and are left alone.
#
# LENGTH is the other half: $(( )) WRAPS at 64 bits (bash 3.2: 2^64 reads as 0, 2^63 as negative), so a number
# of 19+ digits is not a number. Where a wrapped value goes the UNSAFE way it is refused before it gets there —
# the stuck-holder limit and the trigger's backoff knobs (garbled → their default, never "no alert" / "no
# backoff") and the release cooldown, both its hours and the state file's epoch (fail closed: cooldown not over).
# NOT covered, on purpose and named here so nobody reads this as a sweep of everything:
#   - the gate's own pct / floor / slack (_gc_headroom_ok, _gc_floor_ok, _gc_required_parts,
#     _gc_release_decision): a 19+ digit value wraps and WEAKENS the gate. It predates ga-11vdhe (the operand
#     went into $(( )) before the 10# too) and needs a bound per knob — a percentage is not a megabyte count —
#     which is a decision about the gate, not a guard to bolt on here.
#   - PRUNE_KEEP_DAYS and PRUNE_BACKUP_MAX_AGE_H (_prune_plan, _backup_fresh) reach $(( )) with no digits-only
#     check at all — a different fault, in a path that is staged off (PRUNE_ENABLED=0).
#   - _skip_streak_next: its count comes from the skip-streak file the job itself writes (never padded); a
#     hand-written "08 0" aborts the job. (The trigger's reader is strict and treats such a file as unreadable.)
_gc_headroom_ok() {
  local avail="$1" size="$2" pct="$3"
  case "$avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  [ "$avail" -ge $(( size * 10#$pct / 100 )) ]
}

# _gc_floor_ok <avail_mb> <size_mb> <abs_floor_mb> → 0 = the CRITICAL floor (ga-vs55:
# a disk-exhausted dolt_gc() mid-rewrite can panic the WHOLE Dolt server) survives even
# in _gc_headroom_ok's own worst case (post_gc_size == size_mb, i.e. nothing collected).
# ga-3euoj: makes that floor an explicit, always-enforced invariant instead of an
# accident of hq's current (large) size — GC_MIN_FREE_PCT_BASE alone only guarantees it
# while size_mb is already well above abs_floor_mb (true today at ~6-7GB vs 3GB, false
# once hq is small, e.g. right after a real GC succeeds). ANDed with _gc_headroom_ok in
# main() — neither check alone is sufficient.
_gc_floor_ok() {
  local avail="$1" size="$2" floor="$3"
  case "$avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$floor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$avail" -ge $(( size + 10#$floor )) ]
}

# _gc_required_parts <size_mb> <pct> <floor_mb> → echoes "PCT_MB FLOOR_MB REQUIRED_MB" (REQUIRED
# is the larger of the two: the free space _gc_headroom_ok AND _gc_floor_ok jointly demand), or
# prints nothing and returns 1 when any input is unmeasurable. ga-mb57np: the ONE place this is
# computed — main() uses it for the gate and the log, and dolt-gc-release-trigger.sh uses it to
# decide when to start a run, so the trigger can never drift from the gate it is waiting for.
_gc_required_parts() {
  local size="$1" pct="$2" floor="$3" by_pct by_floor req
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  case "$floor" in ''|*[!0-9]*) return 1 ;; esac
  by_pct=$(( size * 10#$pct / 100 ))
  by_floor=$(( size + 10#$floor ))
  req=$by_pct; [ "$by_floor" -gt "$req" ] && req=$by_floor
  echo "$by_pct $by_floor $req"
}

# _resolve_gc_min_free_pct <pinned> <prune_enabled> <base> <with_prune> → echoes the
# GC_MIN_FREE_PCT to use. <pinned> is whatever GC_MIN_FREE_PCT held BEFORE this
# resolution runs (env var or the operator conf file — either wins outright, matching
# this script's documented "file > env > default" precedence); empty means neither set
# it. ga-3euoj: kept separate from _gc_headroom_ok's own worst-case-bound rationale
# because the two measured defaults (base/with_prune, declared near GC_MIN_FREE_PCT
# above) come from DIFFERENT empirical cohorts — a prune batch running in the same
# maintenance-cycle invocation is what actually broke the "post<=pre" assumption in
# real logs, not hq's size or age.
_resolve_gc_min_free_pct() {
  local pinned="$1" prune_enabled="$2" base="$3" with_prune="$4"
  if [ -n "$pinned" ]; then echo "$pinned"; return; fi
  if [ "$prune_enabled" = "1" ]; then echo "$with_prune"; else echo "$base"; fi
}

# _skip_streak_parse <line> → echoes "COUNT ALERTED", defaulting to "0 0" for a missing
# or corrupt state line. Fail-SAFE, not fail-closed like _avail_mb/_gc_headroom_ok:
# this counter only ever drives a notify, never a destructive action, so misreading
# corrupt state as "no streak yet" costs one delayed alert at worst — never data loss.
_skip_streak_parse() {
  local line="${1:-}" count alerted
  count="${line%% *}"
  alerted="${line##* }"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$alerted" in 0|1) ;; *) alerted=0 ;; esac
  echo "$count $alerted"
}

# _skip_streak_next <prev_count> <prev_alerted> <threshold> → echoes "NEW_COUNT
# NEW_ALERTED SHOULD_ALERT" for one more consecutive headroom-skip cycle. SHOULD_ALERT
# is 1 only the FIRST cycle the streak reaches <threshold> (prev_alerted still 0) —
# never again while the SAME streak continues, so a stuck skip doesn't re-notify every
# 2h (ga-azzfw: "um alerta por sequência, sem repetir a cada ciclo").
_skip_streak_next() {
  local prev_count="$1" prev_alerted="$2" thr="$3" new_count should new_alerted
  case "$prev_count" in ''|*[!0-9]*) prev_count=0 ;; esac
  new_count=$(( prev_count + 1 ))
  should=0
  new_alerted="$prev_alerted"
  if [ "$new_count" -ge "$thr" ] && [ "$prev_alerted" != "1" ]; then
    should=1
    new_alerted=1
  fi
  echo "$new_count $new_alerted $should"
}

# _gc_no_effect <pre_mb> <post_mb> → 0 (true) when a dolt_gc() call that ran to
# completion reclaimed NO space (post >= pre) — ga-azzfw requirement 4 ("GC roda mas o
# hq não encolhe"). Fail-OPEN (never flag) on unmeasurable input: this is a notify-only
# signal, not a safety gate, and a `du` misread shouldn't cry wolf.
_gc_no_effect() {
  local pre="$1" post="$2"
  case "$pre" in ''|*[!0-9]*) return 1 ;; esac
  case "$post" in ''|*[!0-9]*) return 1 ;; esac
  [ "$post" -ge "$pre" ]
}

# _backup_fresh <staging_dir> <db> <max_age_h> → 0 if <staging_dir>/<db> was written
# within max_age_h. Belt: a bad prune is recoverable from this S3-staged backup (plus
# the jsonl-archive prune writes on every delete).
_backup_fresh() {
  local dir="$1/$2" max_h="$3"
  [ -d "$dir" ] || return 1
  [ -n "$(find "$dir" -maxdepth 0 -mmin -"$(( max_h * 60 ))" 2>/dev/null)" ]
}

# _prune_dryrun_count <dir> <age_days> → candidate count (0 if none). READ-ONLY
# (`bd prune --dry-run` makes no changes). Overridden with a stub in the selftest.
_prune_dryrun_count() {
  local dir="$1" age="$2" out n
  out="$(timeout 120 "$BD" -C "$dir" prune --older-than "${age}d" --dry-run 2>/dev/null)"
  n="$(printf '%s' "$out" | grep -oE 'Would prune [0-9]+' | awk '{print $3}' | head -1)"
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# _prune_plan <dir> <keep_days> <cap> → echoes "VERB AGE COUNT":
#   NOOP 0 0          nothing closed older than keep_days
#   PRUNE <keep> <n>  n<=cap → prune the full keep-window in one bounded pass (steady state)
#   BATCH <age> <n>   backlog>cap → prune the OLDEST slice that fits under cap; the
#                     remainder drains over subsequent 2h cycles (oldest-first)
#   OVERCAP 0 <n>     even the oldest slice exceeds cap → SKIP + escalate (never run a
#                     catastrophic single delete transaction)
_prune_plan() {
  local dir="$1" keep="$2" cap="$3" c f age cc
  c="$(_prune_dryrun_count "$dir" "$keep")"
  [ "$c" -eq 0 ] && { echo "NOOP 0 0"; return; }
  if [ "$c" -le "$cap" ]; then echo "PRUNE $keep $c"; return; fi
  # backlog > cap: walk ages upward (fewer beads as the window narrows to the oldest);
  # the first slice at/under cap wins → prune oldest-first, bounded.
  for f in 2 3 4 6 8 12; do
    age=$(( keep * f )); cc="$(_prune_dryrun_count "$dir" "$age")"
    if [ "$cc" -gt 0 ] && [ "$cc" -le "$cap" ]; then echo "BATCH $age $cc"; return; fi
  done
  echo "OVERCAP 0 $c"
}

# _flatten_due <sentinel> <enabled> <qstart> <qend> <now_hour> <now_week> → 0 if due.
# At most once per ISO-week, only inside the quiet local-hour window. The sentinel
# stores the last week flatten ran.
_flatten_due() {
  local sentinel="$1" enabled="$2" qs="$3" qe="$4" hr="$5" wk="$6" last=""
  [ "$enabled" = "1" ] || return 1
  { [ "$hr" -ge "$qs" ] && [ "$hr" -lt "$qe" ]; } || return 1
  [ -f "$sentinel" ] && last="$(cat "$sentinel" 2>/dev/null)"
  [ "$last" != "$wk" ]
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest)
# ════════════════════════════════════════════════════════════════════════════════

# _parse_pair <dir:db> → sets globals _PAIR_DIR, _PAIR_DB. A bare "dir" (no colon)
# falls back to db=basename(dir) — correct for rigs, but hq MUST use "$CITY:hq".
_parse_pair() {
  local p="$1"; _PAIR_DIR="${p%%:*}"; _PAIR_DB="${p#*:}"
  [ "$_PAIR_DB" = "$p" ] && _PAIR_DB="$(basename "${_PAIR_DIR%/}")"
}

_run_prune() {
  # skip-when-hot: never pile a delete onto an already-stressed Dolt.
  local cpu; cpu="$(_dolt_cpu_pct)"
  if _should_skip_hot "$cpu" "$PRUNE_SKIP_CPU_PCT"; then
    log "prune SKIP — dolt cpu=${cpu}% > ${PRUNE_SKIP_CPU_PCT}% (retry next 2h cycle)"; return 0
  fi
  # skip-unless-healthy: prune is a WRITE; only run when Dolt is confirmed healthy.
  if declare -f gc_dolt_probe >/dev/null 2>&1; then
    if ! gc_dolt_probe; then log "prune SKIP — dolt not confirmed-healthy (retry next 2h cycle)"; return 0; fi
  fi
  local pair dir store plan verb age cnt
  for pair in $PRUNE_STORES; do
    _parse_pair "$pair"; dir="$_PAIR_DIR"; store="$_PAIR_DB"
    if [ "$PRUNE_REQUIRE_BACKUP" = "1" ] && ! _backup_fresh "$BACKUP_STAGING" "$store" "$PRUNE_BACKUP_MAX_AGE_H"; then
      log "prune SKIP ${store} — no backup within ${PRUNE_BACKUP_MAX_AGE_H}h (waiting for daily backup; jsonl-archive belt still applies)"; continue
    fi
    plan="$(_prune_plan "$dir" "$PRUNE_KEEP_DAYS" "$PRUNE_MAX_PER_RUN")"
    verb="${plan%% *}"; age="$(echo "$plan" | awk '{print $2}')"; cnt="$(echo "$plan" | awk '{print $3}')"
    case "$verb" in
      NOOP)
        log "prune ${store}: 0 closed non-ephemeral beads >${PRUNE_KEEP_DAYS}d — nothing to do" ;;
      PRUNE|BATCH)
        log "prune ${store}: ${verb} ${cnt} closed non-ephemeral bead(s) >${age}d (cap=${PRUNE_MAX_PER_RUN}) …"
        if "$BD" -C "$dir" prune --older-than "${age}d" --force >> "$LOG" 2>&1; then
          log "prune ${store}: OK (${cnt} pruned >${age}d; archived to jsonl-archive/${store})"
        else
          log "prune ${store}: FAILED"
          "$NOTIFY" -t "Dolt prune" -p 4 "🚨 bd prune FALHOU em ${store} — verificar" 2>/dev/null || true
        fi
        [ "$verb" = "BATCH" ] && log "prune ${store}: backlog batch — remainder drains next 2h cycle" ;;
      OVERCAP)
        log "prune ${store}: OVERCAP — ${cnt} closed beads exceed cap ${PRUNE_MAX_PER_RUN} at every age slice; SKIP + escalate"
        "$NOTIFY" -t "Dolt prune" -p 4 "⚠️ prune backlog em ${store}: ${cnt} > cap ${PRUNE_MAX_PER_RUN} em todas as fatias — revisar manualmente" 2>/dev/null || true ;;
    esac
  done
}

_run_flatten() {
  local hr wk; hr="$(date '+%H')"; hr="$((10#$hr))"; wk="$(date '+%G-%V')"
  _flatten_due "$FLATTEN_WEEK_SENTINEL" "$FLATTEN_ENABLED" "$FLATTEN_QUIET_START" "$FLATTEN_QUIET_END" "$hr" "$wk" || return 1
  local pair dir store attempted=0 did=0
  for pair in $FLATTEN_STORES; do
    _parse_pair "$pair"; dir="$_PAIR_DIR"; store="$_PAIR_DB"
    # flatten is IRREVERSIBLE — a fresh backup is MANDATORY. If none, retry next cycle.
    if ! _backup_fresh "$BACKUP_STAGING" "$store" "$PRUNE_BACKUP_MAX_AGE_H"; then
      log "flatten SKIP ${store} — no backup within ${PRUNE_BACKUP_MAX_AGE_H}h (mandatory before irreversible flatten; retry next cycle)"; continue
    fi
    attempted=1
    log "flatten ${store}: weekly history-collapse (IRREVERSIBLE) …"
    if "$BD" -C "$dir" flatten --force >> "$LOG" 2>&1; then
      log "flatten ${store}: OK"; did=1
    else
      log "flatten ${store}: FAILED"
      "$NOTIFY" -t "Dolt flatten" -p 4 "🚨 bd flatten FALHOU em ${store}" 2>/dev/null || true
    fi
  done
  # Only mark the week done once we actually TRIED (avoids skipping the whole week when
  # the backup merely wasn't ready yet; avoids retry storms on repeated hard failure).
  [ "$attempted" = "1" ] && { echo "$wk" > "$FLATTEN_WEEK_SENTINEL" 2>/dev/null || true; }
  [ "$did" = "1" ]
}

# ── skip-streak state I/O + alert helpers (ga-azzfw) ────────────────────────────────
_read_skip_streak() {
  local f="$1" line=""
  [ -f "$f" ] && line="$(cat "$f" 2>/dev/null)"
  _skip_streak_parse "$line"
}

_write_skip_streak() {
  local f="$1" count="$2" alerted="$3"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # Third-state note: a write failure here (disk full, permissions) is
  # swallowed, same as every other external write in this file (log(),
  # notify, mail — all `2>/dev/null || true`). Worst case it silently stalls
  # THIS counter at its last-written value, so it never reaches the alert
  # threshold — but it is not this feature's only safety net: the underlying
  # disk condition is independently covered by dolt-disk-floor-guard.sh's own
  # CRITICAL-floor alerting, which does not depend on this state file at all.
  printf '%s %s\n' "$count" "$alerted" > "$f" 2>/dev/null || true
}

# _dolt_gc_notify <title> <priority> <message> — thin $NOTIFY wrapper so the selftest
# can redefine it instead of a real push firing (same idiom this file already uses for
# _prune_dryrun_count; see memory mutation-check-notify-code-neutralize).
_dolt_gc_notify() {
  "$NOTIFY" -t "$1" -p "$2" "$3" 2>/dev/null || true
}

# _dolt_gc_mail_mayor <subject> <body> — thin `gc mail send mayor` wrapper, same
# redefine-in-selftest idiom as _dolt_gc_notify.
_dolt_gc_mail_mayor() {
  ( cd "$CITY" && GC_CITY="$CITY" "$GC" mail send mayor -s "$1" -m "$2" >/dev/null 2>&1 ) || true
}

# _clear_skip_streak <state_file> <log_context> — resets the skip-streak counter to
# "0 0", logging only when it actually had something to clear (silent on the common
# already-zero path). Called from every NON-headroom-skip exit of the size-gc flow so a
# stale streak from days ago can't resurface after an unrelated cycle in between
# (ga-azzfw requirement 3, read as "whenever this cycle is not itself a headroom skip").
_clear_skip_streak() {
  local f="$1" ctx="$2" prev prev_count
  prev="$(_read_skip_streak "$f")"
  prev_count="${prev%% *}"
  [ "$prev_count" != "0" ] && log "dolt_gc skip streak cleared (was ${prev_count}) — ${ctx}"
  _write_skip_streak "$f" 0 0
}

# _handle_gc_skip_streak <size_mb> <avail_mb> <required_mb> — increments the persisted
# consecutive-headroom-skip counter, alerts (notify + mail mayor) the FIRST cycle it
# reaches GC_SKIP_ALERT_THRESHOLD, and always logs the running count. Called only from
# the headroom-skip branch of main() (ga-azzfw requirements 1+2).
_handle_gc_skip_streak() {
  local size_mb="$1" avail_mb="$2" required_mb="$3"
  local prev prev_count prev_alerted
  prev="$(_read_skip_streak "$GC_SKIP_STREAK_STATE")"
  prev_count="${prev%% *}"
  prev_alerted="$(echo "$prev" | awk '{print $2}')"
  local next new_count new_alerted should_alert
  next="$(_skip_streak_next "$prev_count" "$prev_alerted" "$GC_SKIP_ALERT_THRESHOLD")"
  new_count="${next%% *}"
  new_alerted="$(echo "$next" | awk '{print $2}')"
  should_alert="$(echo "$next" | awk '{print $3}')"
  _write_skip_streak "$GC_SKIP_STREAK_STATE" "$new_count" "$new_alerted"
  local hrs=$(( new_count * 2 ))
  log "dolt_gc skip streak: ${new_count} consecutive headroom-skip cycle(s) (~${hrs}h @ 2h cadence)"
  [ "$should_alert" != "1" ] && return 0
  local mail_body="dolt-gc-maintenance: hq's online dolt_gc() has been skipped for insufficient headroom ${new_count} consecutive cycles in a row (~${hrs}h at the 2h launchd cadence).

Latest reading: size=${size_mb:-<unmeasured>}MB avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB.

This is the exact silent-stall shape behind ga-3euoj: the skip line only reached the
log file, which nobody reads, and the gate stayed unreachable for days while disk
approached Dolt's CRITICAL floor (ga-vs55) twice. One alert per streak — this will not
repeat until the streak clears (an attempted dolt_gc) and later re-crosses the threshold."
  _dolt_gc_notify "Dolt GC" 4 "🚨 dolt_gc pulando por falta de espaço há ${new_count} ciclos seguidos (~${hrs}h) — hq=${size_mb:-?}MB avail=${avail_mb:-?}MB required=${required_mb:-?}MB"
  _dolt_gc_mail_mayor "Dolt GC: ${new_count} skips consecutivos por headroom" "$mail_body"
  log "ALERT: dolt_gc skip streak reached ${GC_SKIP_ALERT_THRESHOLD}+ — notified mayor (notify + mail)"
}

# ── ga-btnq6h: guarded release of hq's local backup staging for the dolt_gc window ─────
#
# WHEN: only inside the headroom-skip branch of main(), after the streak was counted, and
# only when the skip is CHRONIC (GC_RELEASE_MIN_STREAK cycles) — a one-off tight moment is
# never enough. WHAT: remove $BACKUP_STAGING/$DB (hq's LOCAL backup copy) so the GC has room.
# WHY THAT IS SAFE ONLY UNDER PROOF: the copy is redundant iff S3 holds an identical AND
# restorable one. _s3proof_repair_then_prove establishes exactly that (manifest closure on
# both sides + nothing left to upload), repairing S3 first from the staging when it lags.
# "The manifest object exists" is NOT that proof — on 2026-09-25 hq's S3 manifest existed and
# named a table the bucket lacked (see dolt-backup-s3-proof.sh).
#
# AFTER: mol-dog-backup (6-hourly order) rebuilds the staging by incremental sync, and the
# nightly job mirrors it; both work on a missing dir (dolt-s3-backup.sh already wipes and
# rebuilds it on a stale manifest). Meanwhile S3 + the live store hold the data, and the
# staging comes back SMALLER once the GC has shrunk hq.

# _gc_now_epoch — testable clock (override with GC_NOW_EPOCH).
_gc_now_epoch() { if [ -n "${GC_NOW_EPOCH:-}" ]; then printf '%s' "$GC_NOW_EPOCH"; else date +%s; fi; }

# _gc_release_decision <streak> <avail_mb> <staging_mb> <required_mb> <min_streak> <slack_mb>
# → echoes "RELEASE" or "REFUSE <reason>". PURE arithmetic; any non-numeric input (an
# unmeasurable number) REFUSES — a failed read must never look like "plenty of room".
# RELEASE needs: a real staging to free, a chronic streak, and — the point of doing it at all
# — that freeing it actually clears the GC gate (avail + staging >= required + slack).
_gc_release_decision() {
  local streak="$1" avail="$2" staging="$3" required="$4" min_streak="$5" slack="$6" v
  for v in "$streak" "$avail" "$staging" "$required" "$min_streak" "$slack"; do
    case "$v" in ''|*[!0-9]*) echo "REFUSE unmeasurable-input"; return 0 ;; esac
  done
  [ "$staging" -gt 0 ] || { echo "REFUSE no-staging"; return 0; }
  [ "$streak" -ge "$min_streak" ] || { echo "REFUSE streak-too-short"; return 0; }
  [ $(( avail + staging )) -ge $(( required + 10#$slack )) ] || { echo "REFUSE would-not-unblock-gc"; return 0; }
  echo "RELEASE"
}

# _gc_release_cooldown_ok <state_file> <cooldown_h> <now_epoch> → 0 iff no release inside the
# cooldown. Never released (no state file) → ok. A state file that exists but cannot be read
# as an epoch, or a clock that ran backwards → NOT ok (cannot tell; an operator can delete it).
_gc_release_cooldown_ok() {
  local f="$1" hrs="$2" now="$3" last
  case "$hrs" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ -e "$f" ] || return 0
  last="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  # This is the guard against releasing the staging twice, so it fails CLOSED on a number it cannot trust — and
  # $(( )) is not to be trusted with one too long to fit: it wraps at 64 bits (bash 3.2: 2^64 reads as 0), so a
  # state epoch of 2^64 would read as "released in 1970" and a cooldown of 2^64 hours as "0 hours" — both "the
  # cooldown is over". 10# because the state number may carry a leading zero (a hand edit; in $(( )) "08" aborts
  # and "010" is 8). An epoch has 10 digits: 18 is the most that cannot wrap.
  [ "${#last}" -le 18 ] && [ "${#hrs}" -le 9 ] || return 1
  [ $(( now - 10#$last )) -ge $(( 10#$hrs * 3600 )) ]
}

# _gc_release_writer_active — 0 iff a process that writes the staging is running or we cannot
# tell (no ps output, grep error): only a clean "no such process" (grep rc 1) is "not active".
_gc_release_writer_active() {
  local procs rc
  procs="$(ps -axo command= 2>/dev/null)"; rc=$?
  { [ "$rc" -eq 0 ] && [ -n "$procs" ]; } || return 0
  printf '%s\n' "$procs" | grep -Eq "$GC_RELEASE_WRITER_RE"; rc=$?
  [ "$rc" -eq 1 ] && return 1
  return 0
}

# _gc_release_busy <target> — echoes why the staging must not be touched right now and returns
# 0; returns 1 (echoes nothing) when nothing else is using it. A held nightly-backup lock, a
# reseed's .new/.old residue, or a running backup writer all mean "someone is mid-operation".
_gc_release_busy() {
  local target="$1"
  if [ -e "$GC_RELEASE_BACKUP_LOCKDIR" ]; then echo "nightly-backup-lock-held"; return 0; fi
  if [ -e "$target.new" ] || [ -e "$target.old" ]; then echo "reseed-residue-present"; return 0; fi
  if _gc_release_writer_active; then echo "backup-writer-running"; return 0; fi
  return 1
}

# _gc_release_target <staging_root> <db> — echoes the directory that may be released, or returns
# 1. Path-safety: an absolute root literally named .dolt-backup, a plain identifier as db (no
# '/', '.', spaces), a real directory (never a symlink) whose parent is exactly that root, and
# one that holds a manifest (something that IS a backup copy).
_gc_release_target() {
  local root="$1" db="$2" t
  case "$db" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  case "$root" in /*) ;; *) return 1 ;; esac
  [ "$(basename "$root")" = ".dolt-backup" ] || return 1
  t="$root/$db"
  [ -d "$t" ] && [ ! -L "$t" ] || return 1
  [ "$(cd "$root" 2>/dev/null && pwd -P)" = "$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)" ] || return 1
  [ -s "$t/manifest" ] || return 1
  echo "$t"
}

# _gc_maybe_release_staging <size_mb> <avail_mb> <required_mb> — returns 0 iff it RELEASED the
# staging (the caller then re-measures headroom and re-checks the gate); 1 otherwise. Logs one
# line per decision. Order: cheap decisions first, the S3 proof (the slow, aws-touching part)
# only when everything else already says yes, and the state that could have moved during that
# proof is re-checked immediately before the delete.
_gc_maybe_release_staging() {
  local size_mb="$1" avail_mb="$2" required_mb="$3"
  [ "$GC_RELEASE_STAGING_ENABLED" = "1" ] || return 1
  local streak target staging_mb decision now busy fp_before fp_after
  streak="$(_read_skip_streak "$GC_SKIP_STREAK_STATE")"; streak="${streak%% *}"
  target="$(_gc_release_target "$BACKUP_STAGING" "$DB")" || {
    log "staging-release: no releasable local staging at $BACKUP_STAGING/$DB (absent, not a real dir, or no manifest) — not releasing"
    return 1
  }
  staging_mb="$(du -sm "$target" 2>/dev/null | awk '{print $1}')"
  decision="$(_gc_release_decision "$streak" "$avail_mb" "$staging_mb" "$required_mb" "$GC_RELEASE_MIN_STREAK" "$GC_RELEASE_SLACK_MB")"
  if [ "$decision" != "RELEASE" ]; then
    log "staging-release: not releasing — ${decision#REFUSE } (streak=${streak:-?}/${GC_RELEASE_MIN_STREAK} avail=${avail_mb:-?}MB staging=${staging_mb:-?}MB required=${required_mb:-?}MB slack=${GC_RELEASE_SLACK_MB}MB)"
    return 1
  fi
  now="$(_gc_now_epoch)"
  if ! _gc_release_cooldown_ok "$GC_RELEASE_STATE" "$GC_RELEASE_COOLDOWN_H" "$now"; then
    log "staging-release: not releasing — cooldown (${GC_RELEASE_COOLDOWN_H}h) not elapsed since the last release, or its state is unreadable ($GC_RELEASE_STATE)"
    return 1
  fi
  if busy="$(_gc_release_busy "$target")"; then
    log "staging-release: not releasing — staging is in use: $busy"
    return 1
  fi
  # Fail CLOSED on the probe too: one that never loaded is "cannot tell", not "healthy". (The prune
  # path above tolerates a missing probe; deleting backup data must not — the staging is the one
  # local copy sitting next to a Dolt we could not confirm is well.)
  if ! declare -f gc_dolt_probe >/dev/null 2>&1; then
    log "staging-release: not releasing — the Dolt health probe is not loaded, cannot confirm Dolt is healthy"
    return 1
  fi
  if ! gc_dolt_probe; then
    log "staging-release: not releasing — Dolt not confirmed healthy"
    return 1
  fi
  if ! declare -f _s3proof_repair_then_prove >/dev/null 2>&1; then
    log "staging-release: not releasing — the S3 proof library is not loaded (dolt-backup-s3-proof.sh)"
    return 1
  fi
  fp_before="$(cksum < "$target/manifest" 2>/dev/null)"
  log "staging-release: chronic headroom skip (streak=${streak}) and freeing ${staging_mb}MB would clear the gate — proving S3 holds an identical, restorable copy first"
  if ! _s3proof_repair_then_prove "$target" "$DB"; then
    log "staging-release: REFUSED — S3 is not proven restorable and identical to the local staging; NOTHING deleted (see the proof lines above)"
    return 1
  fi
  # The proof can take minutes (it may upload). Anything that changed the staging or started
  # writing to it in the meantime makes that proof stale — re-check right before the delete.
  fp_after="$(cksum < "$target/manifest" 2>/dev/null)"
  if [ -z "$fp_before" ] || [ "$fp_before" != "$fp_after" ]; then
    log "staging-release: REFUSED — the staging's manifest changed while proving S3 (a writer touched it); the proof is stale, NOTHING deleted"
    return 1
  fi
  if busy="$(_gc_release_busy "$target")"; then
    log "staging-release: REFUSED — staging became busy while proving S3: $busy; NOTHING deleted"
    return 1
  fi
  if [ "$GC_RELEASE_STAGING_DRYRUN" = "1" ]; then
    log "staging-release: DRYRUN — WOULD RELEASE ${staging_mb}MB at $target (S3 proven identical+restorable); nothing deleted"
    return 1
  fi
  log "staging-release: S3 proven identical + restorable — RELEASING local staging $target (${staging_mb}MB) so dolt_gc can run"
  rm -rf -- "$target"
  if [ -e "$target" ]; then
    log "staging-release: rm of $target did not complete — staging left partially removed; S3 holds the full copy (mol-dog-backup will rebuild it)"
    return 1
  fi
  mkdir -p "$(dirname "$GC_RELEASE_STATE")" 2>/dev/null || true
  printf '%s\n' "$now" > "$GC_RELEASE_STATE" 2>/dev/null || log "staging-release: WARN could not write the cooldown state $GC_RELEASE_STATE"
  log "staging-release: released ${staging_mb}MB — hq staging is gone until mol-dog-backup rebuilds it (≤6h); S3 has the proven copy"
  _dolt_gc_notify "Dolt GC" 3 "hq: staging local (${staging_mb}MB) liberado p/ o dolt_gc — S3 provado idêntico+restaurável; mol-dog-backup recria em ≤6h"
  _dolt_gc_mail_mayor "Dolt GC: staging local do hq liberado para o dolt_gc" "dolt-gc-maintenance (ga-btnq6h): o dolt_gc do hq estava pulando por falta de espaço há ${streak} ciclos seguidos (size=${size_mb:-?}MB avail=${avail_mb:-?}MB required=${required_mb:-?}MB). Liberei o staging LOCAL .dolt-backup/${DB} (${staging_mb}MB) para abrir espaço, SOMENTE após provar que o S3 tem uma cópia idêntica e restaurável (fecho do manifest + nada a subir). O mol-dog-backup (a cada 6h) recria o staging; o dolt_gc tenta rodar neste mesmo ciclo, mas só se o MESMO portão de espaço passar na re-medição logo após a liberação (o portão não é afrouxado; se ainda faltar, o ciclo pula e o log diz). Cooldown de ${GC_RELEASE_COOLDOWN_H}h. Kill switch: GC_RELEASE_STAGING_ENABLED=0."
  return 0
}

# ── ga-mb57np: single-instance lock (mkdir; no flock on macOS) ──────────────────────────
# Why here: the release trigger starts this job outside the 2h cadence, and launchd only
# serializes runs of its own label — a manual run, or the trigger's child, is invisible to it.
# Two overlapping runs could both reach dolt_gc() or the staging release.
#
# A lock is "held" only while the pid in <dir>/pid is ALIVE and its command line matches <re>:
# a crashed run (SIGKILL, power loss) leaves a dir behind that must not wedge the job forever,
# and a recycled pid must not be mistaken for the holder. A dir with no readable pid is held
# only while young (its creator is between mkdir and writing the pid); an old one is a crash
# leftover. Reclaiming a stale lock uses the same rmdir-then-mkdir idiom as dolt-s3-backup.sh:
# two processes reclaiming the SAME stale lock in the same instant can, in theory, both win —
# the window is microseconds and needs two starts at once after a crash; not worth a second lock.

# _dgm_lock_held <lockdir> <cmd_re> → 0 iff held (see above); 1 otherwise. Read-only.
_dgm_lock_held() {
  local d="$1" re="$2" pid cmd
  [ -d "$d" ] || return 1
  pid="$(head -1 "$d/pid" 2>/dev/null | tr -d '[:space:]')"
  case "$pid" in
    ''|*[!0-9]*)
      [ -n "$(find "$d" -maxdepth 0 -mmin -2 2>/dev/null)" ] && return 0
      return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
  [ -n "$cmd" ] || return 0      # alive but its command cannot be read → cannot tell → held
  printf '%s' "$cmd" | grep -Eq "$re"
}

# _dgm_lock_acquire <lockdir> <cmd_re> → 0 acquired · 1 held by a live run · 2 cannot lock at all
# (the lock directory cannot be created — a third state, deliberately not "held" and not "ok").
_dgm_lock_acquire() {
  local d="$1" re="$2"
  mkdir -p "$(dirname "$d")" 2>/dev/null || return 2
  if ! mkdir "$d" 2>/dev/null; then
    [ -d "$d" ] || return 2
    _dgm_lock_held "$d" "$re" && return 1
    rm -f "$d/pid" 2>/dev/null
    { rmdir "$d" 2>/dev/null && mkdir "$d" 2>/dev/null; } || return 1
  fi
  printf '%s\n' "$$" > "$d/pid" 2>/dev/null || { rmdir "$d" 2>/dev/null; return 2; }
  return 0
}

# _dgm_lock_release <lockdir> — removes the lock only if THIS process owns it.
_dgm_lock_release() {
  local d="$1" pid
  pid="$(head -1 "$d/pid" 2>/dev/null | tr -d '[:space:]')"
  [ "$pid" = "$$" ] || return 0
  rm -f "$d/pid" 2>/dev/null
  rmdir "$d" 2>/dev/null
  return 0
}

# ── ga-11vdhe: a LIVE holder that has held the lock for hours ─────────────────────────────
# _dgm_lock_held answers "is the holder alive?" and has no notion of HOW LONG. A hung run is alive
# too, and it blocks every later run for as long as it hangs. We must not take the lock from a live
# pid (it may be mid-dolt_gc; two runs overlapping is what the lock exists to prevent) — but silence
# is the bug: the only trace was one "another run holds ..." line per cycle, with no age on it.

# _dgm_pos_int <v> → 0 iff <v> is a whole number >= 1 (0 and garbage are not a usable ceiling).
_dgm_pos_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ]
}

# _dgm_stuck_limit_h → the EFFECTIVE stuck-holder limit in hours, always a plain decimal >= 1: the knob when
# it is a whole number >= 1, else 3 (garbled, blank, 0, negative, decimal, or too long to multiply safely).
# It is decided HERE and nowhere else: the alert, the trigger's state note and the prod-test's "a run this old
# is not alive" ceiling all read it, so what is reported can never differ from what was decided (the state
# note once printed the raw knob — "over abch" — while the alert had used 3). A zero-padded number is a whole
# number: "08" is 8. It goes through 10# because in $(( )) a leading 0 is octal — 08/09 abort the shell and
# 010 would silently mean 8. More than 9 digits is refused before multiplying by 3600 (a wrapped product can
# come out negative, and a negative limit alerts on every holder).
_dgm_stuck_limit_h() {
  # (length first: `[ -ge ]` on a 20-digit string is an error message, not just "false")
  if [ "${#GC_MAINT_LOCK_STUCK_H}" -le 9 ] && _dgm_pos_int "$GC_MAINT_LOCK_STUCK_H"; then
    echo $(( 10#$GC_MAINT_LOCK_STUCK_H ))
  else
    echo 3
  fi
}

# _dgm_mtime <file> → epoch mtime, blank (never 0) when it cannot be read. BSD stat first (macOS),
# GNU second; anything non-numeric is "unknown".
_dgm_mtime() {
  local m; m="$(stat -f %m "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  case "$m" in ''|*[!0-9]*) echo "" ;; *) echo "$m" ;; esac
}

# _dgm_lock_age_s <lockdir> <now_epoch> → seconds since the holder took the lock, blank when unknowable.
# The pid file is written once, at acquisition, so its mtime IS the acquisition time (the lock dir's own
# mtime is not: it moves whenever an entry is added or removed). A clock that ran backwards is unknowable,
# not "0 seconds".
_dgm_lock_age_s() {
  local d="$1" now="$2" m
  case "$now" in ''|*[!0-9]*) echo ""; return ;; esac
  m="$(_dgm_mtime "$d/pid")"
  [ -n "$m" ] && [ "$now" -ge "$m" ] || { echo ""; return; }
  echo $(( now - m ))
}

# _dgm_fmt_age <seconds> → "5h12m" (or "37m").
_dgm_fmt_age() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"; else echo "$(( s / 60 ))m"; fi
}

# _dgm_lock_stuck_check <lockdir> <cmd_re> <label> [scope] → 0 iff the lock is held by a LIVE, matching
# holder that has held it longer than GC_MAINT_LOCK_STUCK_H hours (whether or not this call is the one that
# alerted); 1 in every other case (free, dead holder, young holder, or age unknowable — which logs one WARN
# per holder instead of passing for "young"). Side effect, at most
# once per holder: an ALERT line in the log and one $NOTIFY push. It never touches the lock.
# <scope> says what that lock blocks, because the alert must not claim more than is true: "maintenance"
# (default — the job's lock: every maintenance run AND the release trigger stand down) or "trigger" (the
# trigger's own lock: only the trigger's polls stand down; the 2h job is unaffected).
#
# "Once per holder" is a marker file beside the lock dir holding "<pid>:<pid-file mtime>" — the mtime is
# what tells a NEW holder that reused the pid from the one already reported. The marker is written BEFORE
# the push, and if it cannot be written there is NO push: a notification that cannot be deduped would
# repeat on every poll (288/day from the trigger). A missing alert is logged (WARN), never silent — but
# unlike the alert it can recur every call; it needs the state directory to have become unwritable while a
# holder is alive in that very directory, which is not a shape worth more machinery.
# That makes the push AT MOST once, not "exactly once": the marker says "we tried", and _dolt_gc_notify
# swallows a failed push, so a push that never left is not retried for that holder — the ALERT log line is the
# durable record, and its text says so. The "age cannot be determined" WARN dedupes through a SECOND marker,
# "<lockdir>.stuck-age-unknown" (same "<pid>:<mtime>" key), so it can never overwrite the alert's.
_dgm_lock_stuck_check() {
  local d="$1" re="$2" label="$3" scope="${4:-maintenance}" pid now age limit key marker wmarker mtime blocks_en blocks_pt
  case "$scope" in
    trigger) blocks_en="every poll of the release trigger stands down while it holds it (the 2h maintenance job is NOT affected)"
             blocks_pt="o gatilho de 5 min do dolt_gc está parado até ele terminar (a manutenção de 2h segue normal)" ;;
    *)       blocks_en="every maintenance run (purge/prune/GC) and the release trigger stand down while it holds it"
             blocks_pt="TODA a manutenção do hq (purge/prune/GC) está sendo pulada até ele terminar" ;;
  esac
  _dgm_lock_held "$d" "$re" || return 1
  pid="$(head -1 "$d/pid" 2>/dev/null | tr -d '[:space:]')"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac      # "held" only because the dir is young and its pid not written yet
  now="$(_gc_now_epoch)"
  mtime="$(_dgm_mtime "$d/pid")"
  marker="${d}.stuck-alerted"
  age="$(_dgm_lock_age_s "$d" "$now")"
  case "$age" in ''|*[!0-9]*)
    # A live holder whose age cannot be read (the clock is behind the lock's own timestamp, or the stamp
    # is unreadable) is NOT "young": it is "don't know". Not stuck — no push on a guess — but not silent
    # either: one WARN per holder. The WARN has its OWN marker file, not the alert's: sharing one let the WARN
    # overwrite "alerted", and a clock that then recovered alerted the SAME holder a second time (gate rounds
    # 2 and 3). With separate files a later readable age still alerts if it never did, and never repeats if it did.
    wmarker="${d}.stuck-age-unknown"; key="${pid}:${mtime}"
    if [ "$(head -1 "$wmarker" 2>/dev/null)" != "$key" ]; then
      printf '%s\n' "$key" > "$wmarker" 2>/dev/null
      log "WARN: the ${label} lock $d is held by LIVE pid ${pid} but its age cannot be determined (clock ${now:-<blank>} vs lock stamp ${mtime:-<unreadable>}) — cannot tell whether it is stuck; no alert on a guess"
    fi
    return 1 ;;
  esac
  limit="$(_dgm_stuck_limit_h)"
  # A failed $(...) (fork pressure) hands back blank: that is "don't know", not a number — a blank limit
  # reaching the arithmetic below reads as 0 and would call EVERY holder stuck. Fall back like a garbled knob.
  case "$limit" in ''|*[!0-9]*|0) limit=3 ;; esac
  [ "$age" -ge $(( limit * 3600 )) ] || return 1
  key="${pid}:${mtime}"
  if [ "$(head -1 "$marker" 2>/dev/null)" != "$key" ]; then
    if printf '%s\n' "$key" > "$marker" 2>/dev/null; then
      log "ALERT: the ${label} lock $d has been held by LIVE pid ${pid} for $(_dgm_fmt_age "$age") (limit ${limit}h) — ${blocks_en}. The lock is NOT reclaimed (a live pid is never stolen from). One push is sent for this holder, at most once (the dedupe marker is written before the push and a failed push is not retried — this line is the record). Inspect: ps -p ${pid} -o etime=,command="
      _dolt_gc_notify "Dolt GC" 4 "🚨 ${label}: o run pid ${pid} segura o lock há $(_dgm_fmt_age "$age") (limite ${limit}h) — ${blocks_pt}. NÃO foi morto. Ver: ps -p ${pid} -o etime=,command="
    else
      log "WARN: the ${label} lock $d has been held by LIVE pid ${pid} for $(_dgm_fmt_age "$age") (limit ${limit}h) but the alert marker $marker cannot be written — NOT notifying (an alert that cannot be deduped would repeat on every poll)"
    fi
  fi
  return 0
}

# ── main flow ────────────────────────────────────────────────────────────────────
main() {
  # ga-3euoj: resolve GC_MIN_FREE_PCT now that PRUNE_ENABLED + any operator pin (env
  # or the conf file sourced above) are final. Kept inside main() (not top-level) so
  # the selftest — which sources this file as a library and never calls main() — can
  # exercise _resolve_gc_min_free_pct directly with whatever inputs each test wants,
  # rather than being stuck with one value baked in at source-time.
  GC_MIN_FREE_PCT="$(_resolve_gc_min_free_pct "${GC_MIN_FREE_PCT:-}" "$PRUNE_ENABLED" "$GC_MIN_FREE_PCT_BASE" "$GC_MIN_FREE_PCT_WITH_PRUNE")"

  # ga-mb57np: a run started by dolt-gc-release-trigger.sh (GC_TRIGGERED_RUN=1 — only the
  # literal 1) does ONLY the size-gated dolt_gc step below. Purge/prune/flatten stay on the 2h
  # cadence: they have no reason to run every few minutes. (The headroom percentage does not depend
  # on which steps ran: it was resolved just above from PRUNE_ENABLED as configured, and the trigger
  # resolves it the same way — so a triggered run and the trigger's own decision use the same gate.)
  if [ "${GC_TRIGGERED_RUN:-0}" = "1" ]; then
    log "triggered run (ga-mb57np: headroom poll saw the gate reachable) — running ONLY the size-gated dolt_gc step; purge/prune/flatten stay on the 2h cadence"
    _run_size_gc
    return 0
  fi

  # 1) EPHEMERAL PURGE (always) — unchanged behavior.
  if [ -x "$BD" ]; then
    local purged
    purged="$("$BD" -C "$CITY" purge --older-than 2h --force 2>/dev/null | grep -oE 'Purged [0-9]+' | awk '{print $2}')"
    [ -n "${purged:-}" ] && [ "$purged" != "0" ] && log "purged ${purged} closed ephemeral bead(s) (>2h)"
  else
    log "WARN: bd not found — skipped ephemeral purge"
  fi

  # 2) NON-EPHEMERAL PRUNE (opt-in) — the row-count fix for the 2026-07-02 gate stall.
  if [ "$PRUNE_ENABLED" = "1" ]; then
    if [ -x "$BD" ]; then _run_prune; else log "WARN: bd not found — skipped prune"; fi
  fi

  # 3) weekly FLATTEN (opt-in, deep reclaim) — does its own gc; skip the size-gc if it ran.
  local flattened=1
  if [ "$FLATTEN_ENABLED" = "1" ] && [ -x "$BD" ]; then _run_flatten; flattened=$?; fi
  if [ "$flattened" -eq 0 ]; then
    log "size-gc skipped — flatten already reclaimed this run"
    _clear_skip_streak "$GC_SKIP_STREAK_STATE" "flatten already reclaimed this run"
    return 0
  fi

  _run_size_gc
  return 0
}

# _gc_record_outcome <outcome> — ga-11vdhe: the run's explicit RESULT, for the trigger that started it.
# The job always exits 0 once it is running, so until now the trigger could only infer "did it work?" from
# the skip-streak file (cleared = probably yes). This is the real signal: one line, `token=<t> outcome=<x>`,
# written ONLY for a triggered run (the trigger hands it GC_RUN_TOKEN; a normal 2h cycle has none and writes
# nothing — that path is unchanged). The trigger accepts it only when the token is the one it handed out, so
# a leftover from an earlier run can never be mistaken for this one; a write that fails leaves no matching
# record, which the trigger reads as "cannot tell" (= not cleared), never as success.
# Outcome words: below-threshold (hq MEASURED under the threshold) · size-unmeasurable (hq could not be
# measured — decided nothing, cleared nothing) · skip-headroom · release-not-taken · released-still-short ·
# gc-ok · gc-failed · unknown (the step returned without saying — a path added later that forgot to set one).
_gc_record_outcome() {
  case "${GC_RUN_TOKEN:-}" in ''|*[!0-9.]*) return 0 ;; esac
  { mkdir -p "$(dirname "$GC_RUN_OUTCOME_STATE")" 2>/dev/null \
      && printf 'token=%s outcome=%s\n' "$GC_RUN_TOKEN" "$1" > "$GC_RUN_OUTCOME_STATE" 2>/dev/null; } \
    || log "WARN: could not record the run outcome '$1' in $GC_RUN_OUTCOME_STATE (the trigger will read this run's result as unknown)"
  return 0
}

# 4) ONLINE size-gated dolt_gc — step 4 of main() above, and (ga-mb57np) the ONLY step a
# triggered run performs. Always leaves via `return 0`; every outcome is logged.
# ga-11vdhe: the ONE place the outcome is recorded — the step body below sets _RUN_OUTCOME at each of its
# exits, and anything that leaves without setting it is recorded as "unknown" rather than as nothing.
_run_size_gc() {
  _RUN_OUTCOME="unknown"
  _run_size_gc_step
  _gc_record_outcome "$_RUN_OUTCOME"
  return 0
}

_run_size_gc_step() {
  # ONLINE size-gated dolt_gc (always). size_mb replaces the old bare
  # `du -sg` read (same truncated-whole-GB value via integer division, so
  # the THRESHOLD_G comparison below is unchanged) — MB precision is what
  # the new headroom check below needs; see _largest_db_mb's own comment in
  # dolt-compact-routine.sh for why whole-GB truncation is unsafe for a
  # multiplier computation.
  local size_mb; size_mb="$(du -sm "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
  case "$size_mb" in ''|*[!0-9]*) size_mb="" ;; esac
  # ga-11vdhe (gate round 3): three answers, not two — hq is small / hq is big / hq could not be measured.
  # This used to read a failed `du` as 0G, i.e. "below the threshold": it logged that, CLEARED the skip streak
  # and (for a triggered run) recorded a real result — so one `du` hiccup (load 55+ here, where a failed $(...)
  # is a documented event) wiped the chronic streak that arms the staging release, and the trigger, which only
  # starts a run after ITS OWN measurement put hq over the threshold, read "below-threshold" as success and
  # zeroed both backoffs. Unmeasured is "don't know": nothing is decided, nothing is cleared (a normal 2h
  # cycle too — the streak is neither cleared nor advanced), and the outcome says so.
  if [ -z "$size_mb" ]; then
    log "hq size unmeasurable (du failed or returned nothing) — skip gc; NOT treated as below the ${THRESHOLD_G}G threshold: the skip streak is left as it is"
    _RUN_OUTCOME="size-unmeasurable"
    return 0
  fi
  local size_g=$(( size_mb / 1024 ))
  if [ "$size_g" -lt "$THRESHOLD_G" ]; then
    log "hq=${size_g}G < ${THRESHOLD_G}G threshold — skip gc"
    _clear_skip_streak "$GC_SKIP_STREAK_STATE" "hq below ${THRESHOLD_G}G threshold"
    _RUN_OUTCOME="below-threshold"
    return 0
  fi

  # ga-sfj3i.4 / ga-3euoj: disk headroom gate — TWO independent checks, both must
  # pass: _gc_headroom_ok (percentage of size, prune-conditional — see
  # GC_MIN_FREE_PCT_BASE/_WITH_PRUNE above) and _gc_floor_ok (absolute Dolt-CRITICAL
  # floor — see GC_MIN_FREE_ABS_MB above). Always logs the numbers when size measures,
  # including on runs that proceed, so headroom stays visible in the log.
  local avail_mb; avail_mb="$(_avail_mb "$DOLTDIR")"
  local required_pct_mb="" required_floor_mb="" required_mb=""
  if [ -n "$size_mb" ]; then
    # ga-mb57np: computed by _gc_required_parts (shared with the release trigger); a blank
    # result (unmeasurable pin/floor) leaves all three empty → the gate below fails closed.
    read -r required_pct_mb required_floor_mb required_mb <<< "$(_gc_required_parts "$size_mb" "$GC_MIN_FREE_PCT" "$GC_MIN_FREE_ABS_MB")"
  fi
  log "hq disk headroom check: size=${size_mb:-<unmeasured>}MB avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB (max of ${GC_MIN_FREE_PCT}% size=${required_pct_mb:-<unmeasured>}MB, size+${GC_MIN_FREE_ABS_MB}MB floor=${required_floor_mb:-<unmeasured>}MB)"
  if ! _gc_headroom_ok "$avail_mb" "$size_mb" "$GC_MIN_FREE_PCT" || ! _gc_floor_ok "$avail_mb" "$size_mb" "$GC_MIN_FREE_ABS_MB"; then
    log "hq size=${size_mb:-<unmeasured>}MB avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB — insufficient free space (or unmeasurable) for dolt_gc — skip this cycle, will retry in 2h"
    if [ "${GC_TRIGGERED_RUN:-0}" = "1" ]; then
      # ga-mb57np: the streak counts 2h launchd CYCLES (its alert text and the release's
      # "chronic" test both read it that way). A run started between cycles by the headroom
      # poll is not one, so it must not advance it — else a refused trigger would inflate
      # "~Nh of skips" by minutes-apart attempts.
      log "triggered run: this skip is not a 2h cycle — the skip streak is NOT advanced"
    else
      _handle_gc_skip_streak "$size_mb" "$avail_mb" "$required_mb"
    fi
    # ga-11vdhe: a triggered run may reach the release ONLY if the trigger started it as a "release" run.
    # The trigger backs off per kind (a refused release run is aws traffic; a direct run is not), and that
    # accounting is only true if a run started as "direct" can never turn into a release attempt — which it
    # did whenever the gate failed at this run's own sample (a peak that fell in the second between the
    # trigger's measurement and ours). Under any doubt about the kind (unset, garbled) a triggered run stays
    # inert here, as it does when the lock cannot be created; a missed release costs one poll.
    if [ "${GC_TRIGGERED_RUN:-0}" = "1" ] && [ "${GC_TRIGGERED_KIND:-}" != "release" ]; then
      log "triggered run (kind='${GC_TRIGGERED_KIND:-<none>}'): the gate is not met at this run's own sample — NOT attempting the staging release (only a run the trigger started as 'release' may); the next poll decides again"
      _RUN_OUTCOME="skip-headroom"
      return 0
    fi
    # ga-btnq6h: a CHRONIC skip is a vicious circle (the GC that would shrink hq is the thing
    # that cannot run) — when S3 is proven to hold an identical, restorable copy, free the
    # redundant local staging and re-check the SAME gate with a fresh measurement. Never
    # lowers the gate (the 2x bound is measured, ga-3euoj); it only makes room to meet it.
    if ! _gc_maybe_release_staging "$size_mb" "$avail_mb" "$required_mb"; then
      _RUN_OUTCOME="release-not-taken"
      return 0
    fi
    avail_mb="$(_avail_mb "$DOLTDIR")"
    log "hq staging released — re-checking the same headroom gate with a fresh measurement: avail=${avail_mb:-<unmeasured>}MB required=${required_mb:-<unmeasured>}MB"
    if ! _gc_headroom_ok "$avail_mb" "$size_mb" "$GC_MIN_FREE_PCT" || ! _gc_floor_ok "$avail_mb" "$size_mb" "$GC_MIN_FREE_ABS_MB"; then
      log "hq still short of the gate after releasing the staging (avail=${avail_mb:-<unmeasured>}MB) — skip this cycle; the gate is NOT lowered"
      _RUN_OUTCOME="released-still-short"
      return 0
    fi
  fi

  local pre; pre="$(du -sh "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
  log "hq=${pre} >= ${THRESHOLD_G}G, headroom ok — running online dolt_gc ..."
  # ga-azzfw requirement 3: the headroom problem this cycle is resolved the moment we
  # reach an actual attempt, independent of whether the SQL call below then succeeds —
  # a transient dolt_gc() failure is a DIFFERENT, already-alerted condition (below) and
  # must not keep the (unrelated) skip-streak counter artificially elevated.
  _clear_skip_streak "$GC_SKIP_STREAK_STATE" "dolt_gc attempted"
  if DOLT_CLI_PASSWORD='' timeout 300 dolt --host 127.0.0.1 --port "$PORT" --user root --no-tls \
       sql -q "USE \`$DB\`; CALL dolt_gc();" >> "$LOG" 2>&1; then
    local post post_mb; post="$(du -sh "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
    post_mb="$(du -sm "$DOLTDIR" 2>/dev/null | awk '{print $1}')"
    case "$post_mb" in ''|*[!0-9]*) post_mb="" ;; esac
    log "dolt_gc OK — hq ${pre} -> ${post}"
    _RUN_OUTCOME="gc-ok"
    # ga-azzfw requirement 4: dolt_gc() succeeded (rc=0) but reclaimed nothing. size_mb
    # is reused as "pre" here — it's the exact same pre-gc measurement the headroom
    # decision above was based on, not a fresh re-read that could drift from it.
    if _gc_no_effect "$size_mb" "$post_mb"; then
      log "dolt_gc had NO EFFECT — hq ${size_mb:-<unmeasured>}MB -> ${post_mb:-<unmeasured>}MB (not smaller)"
      _dolt_gc_notify "Dolt GC" 4 "⚠️ dolt_gc rodou mas hq não encolheu — ${size_mb:-?}MB -> ${post_mb:-?}MB"
      _dolt_gc_mail_mayor "Dolt GC: rodou sem efeito (hq ${size_mb:-?}MB -> ${post_mb:-?}MB)" "dolt-gc-maintenance: dolt_gc() ran to completion (rc=0) but hq's on-disk size did not shrink — ${size_mb:-<unmeasured>}MB before, ${post_mb:-<unmeasured>}MB after (ga-azzfw requirement 4).

Either there was nothing eligible to collect this cycle, or something is preventing
reclaim. Not necessarily an emergency by itself — but worth a look if it keeps
recurring, since the headroom gate above assumes a normal dolt_gc() brings the store
back down toward its live-data floor."
    fi
  else
    local rc=$?
    log "dolt_gc FAILED (rc=$rc)"
    _RUN_OUTCOME="gc-failed"
    "$NOTIFY" -t "Dolt gc" -p 4 "🚨 Manutenção dolt gc FALHOU (rc=$rc) — store em ${pre}, verificar antes de re-inchar" 2>/dev/null || true
  fi
  return 0
}

# ── run unless sourced as a library (selftest sources with DOLT_GC_MAINT_LIB=1) ──
if [ "${DOLT_GC_MAINT_LIB:-0}" != "1" ]; then
  _dgm_lock_acquire "$GC_MAINT_LOCKDIR" "$GC_MAINT_LOCK_RE"
  case "$?" in
    0) trap '_dgm_lock_release "$GC_MAINT_LOCKDIR"' EXIT ;;
    1) _held_age="$(_dgm_lock_age_s "$GC_MAINT_LOCKDIR" "$(_gc_now_epoch)")"
       log "another dolt-gc-maintenance run holds $GC_MAINT_LOCKDIR (pid $(head -1 "$GC_MAINT_LOCKDIR/pid" 2>/dev/null)${_held_age:+, held for $(_dgm_fmt_age "$_held_age")}) — exiting; nothing done in this invocation"
       # ga-11vdhe: a holder that is hours old is a hung run, not a busy one — say so, once (never steals the lock)
       _dgm_lock_stuck_check "$GC_MAINT_LOCKDIR" "$GC_MAINT_LOCK_RE" "dolt-gc-maintenance" || true
       exit 0 ;;
    # Cannot create the lock at all (fs trouble). The 2h cycle runs anyway, as this job always has —
    # refusing would silently stop ALL maintenance over a bookkeeping failure — but says so. A
    # TRIGGERED run is the extra path that may release the staging: under the same doubt it stays
    # inert (a missed one costs nothing; the next poll retries).
    *) if [ "${GC_TRIGGERED_RUN:-0}" = "1" ]; then
         log "WARN: cannot create the single-instance lock $GC_MAINT_LOCKDIR — a TRIGGERED run (which may release the staging) does not run without overlap protection; nothing done in this invocation"
         exit 0
       fi
       log "WARN: cannot create the single-instance lock $GC_MAINT_LOCKDIR — running WITHOUT overlap protection" ;;
  esac
  main
  exit 0
fi
