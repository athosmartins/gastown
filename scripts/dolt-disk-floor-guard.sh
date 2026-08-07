#!/bin/bash
# dolt-disk-floor-guard.sh (ga-gpzr) — last-resort disk-floor guard for Dolt.
#
# WHY: 2026-07-14 the HQ Dolt server (port 52756) died mid-journal-write when the
# disk filled to 100% (ga-vs55). It came back up clean this time (data intact,
# verified by the Mayor via positive control) but nothing actually PROTECTS Dolt
# from ENOSPC — a future full-disk event (any source, not just the symlink-descent
# vector already fixed) could hit Dolt mid-write again with no guarantee of a clean
# recovery. ga-vs55's other two furos (rising-pressure notify, symlink guard) don't
# cover this: they slow/warn about a fill that's already underway; neither reserves
# Dolt any headroom of its own, and disk-pressure-monitor.sh polls hourly — a lot
# can fill in an hour.
#
# WHAT: an EXTERNAL, non-invasive watchdog (same shape as dolt-hang-watchdog.sh /
# dolt-gc-maintenance.sh — NOT a patch to Dolt's config or its gitignored,
# framework-managed start wrapper under .gc/, which isn't a durable place to put a
# fix). Polls avail space on Dolt's data-dir filesystem every StartInterval and:
#
#   WARN_GB (default 8)     — attempt the pre-sanctioned-safe reclaim
#                             (`gc dolt-cleanup --force` — orphan test-DB SQL DROP,
#                             documented safe while Dolt is up), PLUS three more
#                             levers — reaping dead-session scratchpads under
#                             /private/tmp (see _reap_dead_scratch, ga-hjcxy/
#                             ga-02pnu: a single dead session's 1GB scratchpad
#                             caused a CRITICAL incident that this follow-up
#                             fixes — dolt-cleanup alone never touched that class
#                             of file), dead-session transcripts under
#                             ~/.claude/projects (see _reap_dead_transcripts,
#                             ga-t1ub9: 1.4GB/1232 files accumulated with no
#                             reaper at all — a disjoint leak class from
#                             scratch), and capping known unrotated app logs
#                             under /private/tmp and ~/shared/logs (see
#                             _reap_growing_logs, ga-dnc2m: ~4G across six
#                             never-rotated logs on the SAME APFS container as
#                             Dolt's own data-dir competed directly for this
#                             guard's floor, and none of the other three
#                             levers touch that file class — the guard used to
#                             log "reclaim OK — avail 6GB -> 6GB" through an
#                             entire log-driven CRITICAL dip, a reported
#                             success over a complete non-effect) — then
#                             rate-limited notify. Cooldown is bypassed if
#                             avail is WORSENING since the last notify (mirrors
#                             the exact fix ga-vs55 furo #2 added to
#                             disk-pressure-monitor.sh's dpm_should_notify — a
#                             cooldown blind to trend is what let the city monitor
#                             stay silent 28min before Dolt died; must not regress
#                             that lesson onto this guard).
#
#                             UNLIKE the other three levers, _reap_growing_logs
#                             runs on EVERY cycle regardless of floor class
#                             (see its call at the top of main(), before the
#                             avail/class computation) — ga-dnc2m's own
#                             acceptance criteria ask for these logs to always
#                             carry a cap, not merely to be capped reactively
#                             once Dolt is already under pressure. It is still
#                             gated by ENABLED (see Kill switch below), and
#                             being cheap (a handful of `stat` calls; a
#                             copytruncate only when a file is actually over
#                             its threshold) costs nothing on the common no-op
#                             cycle.
#
#   CRITICAL_GB (default 3) — same reclaim attempts + notify ALWAYS (cooldown
#                             bypassed unconditionally — this is the last rung
#                             before repeating ga-vs55) + a DURABLE mail to the
#                             Mayor once CRITICAL_MAIL_SUSTAIN (default 2)
#                             consecutive cycles confirm it (ga-q4cqr —
#                             debounces a single self-recovering compaction
#                             spike; see the Mayor's own 2026-07-27 comment on
#                             that bead: one such spike fired 4 pages in one
#                             incident). NOTIFY is never debounced, only the
#                             mail. A near-miss this close to repeating a
#                             city-wide outage must survive a session restart, so
#                             this is mail, not a nudge (see mail-lifecycle
#                             doctrine: "if the recipient dies and restarts, do
#                             they need this message? yes -> mail").
#
# Absolute-GB floors (not percent, unlike disk-pressure-monitor's WARN/EMERGENCY/
# HALT_IMMINENT_PCT): a %-based floor can look "fine" on a large disk while the
# absolute room left is thin, and vice versa on a small one. This guard is a
# Dolt-specific backstop underneath the general city-wide monitor, not a
# replacement for it.
#
# OUT OF SCOPE (deliberately — see ga-gpzr's own description: "needs design...
# this is NOT a lane:small fix"): this guard does NOT stop Dolt, does NOT refuse
# writes, and does NOT touch Dolt's data directory. An automated system unilaterally
# halting the town's SOLE data plane is a materially bigger policy decision than
# alerting + pre-sanctioned-safe cleanup, and deserves explicit Mayor/operator
# sign-off rather than being silently bundled into a no-human-review small-lane
# merge. Filed as a separate follow-up bead (see this commit's gate-done note).
#
# Kill switch: DOLT_DISK_FLOOR_GUARD_ENABLED=0 → skip ALL FOUR reclaim actions
# (dolt-cleanup, the scratchpad reaper, the transcript reaper, AND the log
# reaper) only. Notification is NEVER gated by this switch (imp07 CALL
# INVARIANT: alerting is the lowest-blast-radius action here and the one furo
# #2 just fixed for being wrongly suppressible — don't reintroduce that
# failure mode one guard over).
#
# TEST (no Dolt, no deletions, no real disk mutation, no mail/notify sent):
#   bash scripts/dolt-disk-floor-guard.selftest.sh
# Library mode: `DOLT_DISK_FLOOR_GUARD_LIB=1 source dolt-disk-floor-guard.sh` defines
# the pure decision functions WITHOUT running the guard flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
DOLTDIR="$CITY/.beads/dolt"
LOG="${DOLT_DISK_FLOOR_GUARD_LOG:-$CITY/.gc/logs/dolt-disk-floor-guard.log}"
NOTIFY="/Users/athos/.local/bin/notify"
GC="${GC_BIN:-gc}"
ENABLED="${DOLT_DISK_FLOOR_GUARD_ENABLED:-1}"

FLOOR_WARN_GB="${DOLT_DISK_FLOOR_WARN_GB:-8}"
FLOOR_CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-3}"

NOTIFY_COOLDOWN_SECS="${DOLT_DISK_FLOOR_NOTIFY_COOLDOWN_SECS:-3600}"   # 1h — tighter
                        # than disk-pressure-monitor's 6h; this is Dolt-specific
                        # last-resort protection, not general city monitoring.
STATE_DIR="${DOLT_DISK_FLOOR_STATE_DIR:-$CITY/.gc/logs}"
STATE_EPOCH_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-notify"
STATE_AVAIL_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-notify-avail-gb"

# ga-q4cqr: consecutive CRITICAL cycles required before mailing the Mayor.
# Mayor's own comment on ga-q4cqr (2026-07-27 incident): a single transient
# compaction spike (avail dipped to 2GB then self-recovered within one cycle)
# fired 4 separate pages across the city's guards — "must debounce so a
# self-recovering condition does not storm the inbox." NOTIFY itself stays
# UNCONDITIONAL on every CRITICAL cycle (imp07 CALL INVARIANT, unchanged —
# alerting is the lowest-blast-radius action and must never be suppressed);
# only the DURABLE mail-Mayor escalation is debounced. Poll cadence is 5min
# (StartInterval), so the default of 2 consecutive cycles is a ~5-10min
# confirmation window — mirrors ram-pressure-monitor.sh's RPM_EMERGENCY_SUSTAIN.
CRITICAL_MAIL_SUSTAIN="${DOLT_DISK_FLOOR_CRITICAL_MAIL_SUSTAIN:-2}"
STATE_CRITICAL_SUSTAIN_FILE="$STATE_DIR/.dolt-disk-floor-guard.critical-sustain-count"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# optional shared Dolt-health probe (reuse gc-dolt-probe.sh; fail open if missing —
# _safe_reclaim's own timeout still bounds the write it gates)
_PROBE="$CITY/scripts/gc-dolt-probe.sh"
# shellcheck disable=SC1090
[ -f "$_PROBE" ] && . "$_PROBE" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by dolt-disk-floor-guard.selftest.sh.
# No side effects (the df call is read-only); config is passed as explicit params
# so the selftest can exercise arbitrary values without touching globals.
# ════════════════════════════════════════════════════════════════════════════════

# _avail_gb [path] → integer GB available on the filesystem hosting [path]
# (default $CITY), or "" if df fails/parses oddly (e.g. nonexistent path). Uses
# `df -k` + division rather than `df -g` (macOS/BSD df has no -g; -k is portable).
_avail_gb() {
  local path="${1:-$CITY}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 / 1024 ))
}

# _floor_class <avail_gb> <warn_gb> <crit_gb> → NONE|WARN|CRITICAL|UNKNOWN.
# UNKNOWN (empty/non-numeric avail_gb, e.g. df failed) is NEVER silently treated as
# NONE — a failed read must fail LOUD, not collapse into "no problem" (ga-p5q3:
# error and empty must not produce the same value when the emptiness is load-bearing).
_floor_class() {
  local avail="$1" warn="$2" crit="$3"
  case "$avail" in ''|*[!0-9]*) echo "UNKNOWN"; return ;; esac
  if [ "$avail" -le "$crit" ]; then echo "CRITICAL"; return; fi
  if [ "$avail" -le "$warn" ]; then echo "WARN"; return; fi
  echo "NONE"
}

# _worsening <current_avail_gb> <last_notified_avail_gb_or_empty> → 0 (true) only
# when there IS a valid prior value AND current is strictly LOWER — avail-GB
# FALLING is pressure worsening (the inverse framing of disk-pressure-monitor's
# usage-% RISING; same idiom, same reason: dpm_pressure_rising in
# disk-pressure-monitor.sh). No prior value → false (unknown trend is not on its
# own a reason to bypass the cooldown — _cooldown_elapsed's fail-open already
# covers "never notified").
_worsening() {
  local current="$1" last="$2"
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  case "$current" in ''|*[!0-9]*) return 1 ;; esac
  [ "$current" -lt "$last" ]
}

# _cooldown_elapsed <last_epoch_or_empty> <now_epoch> <cooldown_secs> → 0 (true)
# when there's no/invalid prior timestamp (fail-open — a corrupt state file must
# never silence a real emergency) or the cooldown window has passed.
_cooldown_elapsed() {
  local last="$1" now="$2" cd="$3"
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( now - last )) -ge "$cd" ]
}

# _should_notify <last_epoch> <now_epoch> <cooldown> <current_avail> <last_avail>
# → 0 (notify) when the cooldown elapsed OR pressure is worsening since the last
# notify. This is the WARN-tier gate; CRITICAL always notifies unconditionally
# (handled directly in main — the last rung before repeating ga-vs55 must never be
# rate-limited).
_should_notify() {
  local last_epoch="$1" now="$2" cooldown="$3" current="$4" last_avail="$5"
  _cooldown_elapsed "$last_epoch" "$now" "$cooldown" && return 0
  _worsening "$current" "$last_avail"
}

# _sustain_confirmed <pending_count> <threshold> → 0 (true) once pending_count
# has reached threshold. Trivial arithmetic, but kept as a named, unit-tested
# function — matching this file's own "decisions are pure + tested" convention
# — so the boundary (>= not >) is explicit and covered, same as _floor_class's
# inclusive boundaries above. A non-numeric pending_count (corrupt state file)
# fails CLOSED here (never confirmed) — the OPPOSITE fail-direction from
# _cooldown_elapsed's fail-open, deliberately: a corrupt cooldown timestamp
# must never SILENCE a real emergency (imp07), but a corrupt sustain COUNTER
# must never PREMATURELY confirm one on garbage data — _write_critical_sustain
# always writes a clean integer, so corruption here would mean external
# interference, not a normal empty-state case (contrast STATE_EPOCH_FILE/
# STATE_AVAIL_FILE, which are legitimately empty on a fresh install).
_sustain_confirmed() {
  local pending="$1" threshold="$2"
  case "$pending" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pending" -ge "$threshold" ]
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest)
# ════════════════════════════════════════════════════════════════════════════════

_read_state() {
  _LAST_EPOCH=""; _LAST_AVAIL=""
  [ -f "$STATE_EPOCH_FILE" ] && _LAST_EPOCH="$(cat "$STATE_EPOCH_FILE" 2>/dev/null)"
  [ -f "$STATE_AVAIL_FILE" ] && _LAST_AVAIL="$(cat "$STATE_AVAIL_FILE" 2>/dev/null)"
}

_write_state() {
  local epoch="$1" avail="$2"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$epoch" > "$STATE_EPOCH_FILE" 2>/dev/null || true
  echo "$avail" > "$STATE_AVAIL_FILE" 2>/dev/null || true
}

# _read_critical_sustain / _write_critical_sustain — persist the consecutive-
# CRITICAL-cycle counter the mail-Mayor sustain-guard reads. Missing/corrupt
# state reads as 0 (fresh install / no prior streak — NOT "sustain already
# confirmed"; see _sustain_confirmed's fail-CLOSED note above for why that
# asymmetry with the notify-cooldown state files is intentional).
_read_critical_sustain() {
  local f="$STATE_CRITICAL_SUSTAIN_FILE" v
  v="$([ -f "$f" ] && cat "$f" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

_write_critical_sustain() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$1" > "$STATE_CRITICAL_SUSTAIN_FILE" 2>/dev/null || true
}

# _safe_reclaim <before_avail_gb> → best-effort `gc dolt-cleanup --force` (orphan
# test-DB SQL DROP — pre-sanctioned safe while Dolt is up; see gastown.dog
# operational doctrine's dolt cleanup entry). Only runs when Dolt is confirmed
# healthy (never pile a write onto an already-struggling server — same
# skip-unless-healthy gate dolt-gc-maintenance.sh's _run_prune uses) and only when
# the kill switch is on. Bounded by timeout so a wedged Dolt can't hang the guard.
_safe_reclaim() {
  local before="$1"
  if [ "$ENABLED" != "1" ]; then
    log "reclaim SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if declare -f gc_dolt_probe >/dev/null 2>&1; then
    if ! gc_dolt_probe; then
      log "reclaim SKIP — dolt not confirmed-healthy (cleanup is a write; retry next cycle)"
      return
    fi
  fi
  # ga-eu2x: use the HYPHEN command (gc dolt-cleanup, the Go path) — NOT the space
  # form (gc dolt cleanup, shell). This runs AUTOMATICALLY and unattended when the
  # disk is low, which is EXACTLY when Dolt is slow and `gc rig list` degrades — and
  # the space form decides "orphan" by non-reference to a rig list that just failed,
  # so a degraded lookup could see a production DB as orphan and DROP it. The hyphen
  # form is prefix-gated (only test/agent DB name patterns) and cannot drop
  # production by construction, so it is the correct command for an automatic guard.
  # It still reclaims disk (drops stale test DBs + DOLT_PURGE_DROPPED_DATABASES).
  log "reclaim: avail=${before}GB at/below floor — running 'gc dolt-cleanup --force' …"
  if timeout 60 "$GC" dolt-cleanup --force >> "$LOG" 2>&1; then
    local after; after="$(_avail_gb "$DOLTDIR")"
    log "reclaim OK — avail ${before}GB -> ${after:-?}GB"
  else
    log "reclaim FAILED (gc dolt-cleanup --force nonzero exit)"
  fi
}

# _reap_dead_scratch — second reclaim lever, alongside _safe_reclaim (ga-hjcxy,
# fixing ga-02pnu): dead Claude Code sessions' scratchpads under /private/tmp
# accumulate with nothing to reap them (the worktree-reaper only covers
# REGISTERED git worktrees, not loose scratch dirs) — a single 1GB dead
# scratchpad caused a CRITICAL disk-floor incident this follow-up fixes.
# Delegates to the standalone, independently-selftested scratchpad-reaper.sh so
# its liveness/staleness safety logic is unit-tested in isolation rather than
# inlined here. Bounded by timeout so a wedged `gc session list` can't hang this
# guard; best-effort — a failure here must never block the dolt-cleanup lever or
# the notify decision that follows it.
#
# SCRATCHPAD_REAPER_PROD=1 (ga-h565g): this function IS the real, launchd-driven
# caller scratchpad-reaper.sh's own production-sentinel guard is designed to
# trust — the ONLY place that should ever set this opt-in. It authorizes
# scratchpad-reaper.sh to actually delete when its resolved root equals its
# real default; without it, a harness bug that leaves that root at the default
# (exactly what caused the sibling transcript-reaper.sh incident) forces a
# dry-run instead of deleting real data.
#
# <was_critical> (ga-rjhfz, optional, defaults "0"): main() passes whether
# THIS cycle was CRITICAL at any point (pre- or post-reclaim — see the
# was_critical latch above). "1" sets SCRATCHPAD_REAPER_PRESSURE=CRITICAL,
# which is the ONLY thing that activates scratchpad-reaper.sh's own
# size-escape gate (independently selftested there) — a large dead scratchpad
# too fresh for its normal 24h grace window can still be freed during a real
# crisis instead of surviving it, which is what happened 2026-08-06 (a 10GB/
# 3.5h dead scratchpad outlived two CRITICAL cycles because age was the only
# gate). "0"/omitted leaves the variable unset — behavior identical to before
# ga-rjhfz.
_reap_dead_scratch() {
  local was_critical="${1:-0}"
  if [ "$ENABLED" != "1" ]; then
    log "scratch-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/scratchpad-reaper.sh"
  if [ ! -f "$reaper" ]; then
    log "scratch-reap SKIP — $reaper not found"
    return
  fi
  if [ "$was_critical" = "1" ]; then
    log "scratch-reap: running dead-session scratchpad cleanup (pressure=CRITICAL, size-escape eligible) …"
    if SCRATCHPAD_REAPER_PROD=1 SCRATCHPAD_REAPER_PRESSURE=CRITICAL timeout 60 bash "$reaper" >> "$LOG" 2>&1; then
      log "scratch-reap OK"
    else
      log "scratch-reap FAILED or aborted (nonzero exit) — see log lines above"
    fi
  else
    log "scratch-reap: running dead-session scratchpad cleanup …"
    if SCRATCHPAD_REAPER_PROD=1 timeout 60 bash "$reaper" >> "$LOG" 2>&1; then
      log "scratch-reap OK"
    else
      log "scratch-reap FAILED or aborted (nonzero exit) — see log lines above"
    fi
  fi
}

# _reap_dead_transcripts — third reclaim lever, alongside _safe_reclaim and
# _reap_dead_scratch (ga-t1ub9, same family as ga-02pnu): Claude Code session
# transcripts under ~/.claude/projects/<project>/<session-id>.jsonl accumulate
# forever with nothing to reap them — 1.4GB across 1232 files by 2026-07-26,
# contributing to two Dolt ENOSPC hits that day. Delegates to the standalone,
# independently-selftested transcript-reaper.sh so its liveness/staleness
# safety logic (NEVER reap a live or suspended session's transcript — losing
# one is unrecoverable, unlike scratch) is unit- AND integration-tested in
# isolation rather than inlined here. Bounded by timeout so a wedged `gc
# session list` can't hang this guard; best-effort — a failure here must never
# block the other two reclaim levers or the notify decision that follows.
#
# TRANSCRIPT_REAPER_PROD=1 (ga-lfj05, completing ga-h565g for this file): this
# function IS the real, launchd-driven caller transcript-reaper.sh's own
# production-sentinel guard is designed to trust — the ONLY place that should
# ever set this opt-in. It authorizes transcript-reaper.sh to actually delete
# when its resolved root equals its real default; without it, a harness bug
# that leaves that root at the default (exactly what caused this script's own
# 2026-07-26 185-transcript incident) forces a dry-run instead of deleting
# real data.
_reap_dead_transcripts() {
  if [ "$ENABLED" != "1" ]; then
    log "transcript-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/transcript-reaper.sh"
  if [ ! -f "$reaper" ]; then
    log "transcript-reap SKIP — $reaper not found"
    return
  fi
  log "transcript-reap: running dead-session transcript cleanup …"
  # Bound sized to the MEASURED cost of the work, not to a round number.
  # MEASURED 2026-08-01: a full pass takes ~39s on this host (1854 transcripts
  # across 122 project dirs; the reaper `du -sk`s each candidate AND its sibling
  # dir, and calls `gc session list --json` first to verify liveness before any
  # irreversible delete). 39s against a 60s bound is a ~35% margin — and the
  # liveness call alone stretches from ~1.3s to 10-20s whenever Dolt is warm,
  # which is precisely WHEN this path runs (disk pressure and Dolt pressure
  # arrive together). Live evidence in this very log: 5 runs, 5 timeouts, ZERO
  # successes, each lasting exactly ~60s (23:36:56->23:37:57, 23:43:21->23:44:21).
  # An emergency disk-reclaim that never completes is worse than none, because
  # the "FAILED" line reads as "tried and could not free space" when the truth
  # is "was killed before it could try". Same class as ga-gquc1 (backup dog:
  # 120s bound vs a 6.3G database) and ga-q4cqr's ladder.
  # 300s is deliberately generous: this runs only at/below the disk floor, at
  # most once per guard cycle, and finishing LATE is strictly better than not
  # finishing. The reaper is itself fail-safe — it ABORTS rather than delete
  # when it cannot verify session liveness (ga-lfj05, after the 2026-07-26
  # incident that deleted 185 live transcripts), so a longer bound cannot make
  # it delete anything it would not have deleted at 60s.
  local _reap_bound="${TRANSCRIPT_REAP_TIMEOUT_SECS:-300}"
  local _reap_start _reap_elapsed
  _reap_start=$(date +%s)
  if TRANSCRIPT_REAPER_PROD=1 timeout "$_reap_bound" bash "$reaper" >> "$LOG" 2>&1; then
    _reap_elapsed=$(( $(date +%s) - _reap_start ))
    log "transcript-reap OK (${_reap_elapsed}s, bound=${_reap_bound}s)"
  else
    _reap_elapsed=$(( $(date +%s) - _reap_start ))
    # Distinguish "ran out of time" from "ran and failed" — they need different
    # responses, and collapsing them is what hid 5 consecutive timeouts as a
    # generic FAILED (root-class:error-vs-empty).
    if [ "$_reap_elapsed" -ge "$_reap_bound" ]; then
      log "transcript-reap TIMED OUT after ${_reap_elapsed}s (bound=${_reap_bound}s) — reclaim did NOT run to completion; raise TRANSCRIPT_REAP_TIMEOUT_SECS if this repeats"
    else
      log "transcript-reap FAILED after ${_reap_elapsed}s (nonzero exit, not a timeout) — see log lines above"
    fi
  fi
}

# _reap_growing_logs — fourth reclaim lever, alongside _safe_reclaim,
# _reap_dead_scratch, and _reap_dead_transcripts (ga-dnc2m): known app logs
# under /private/tmp and ~/shared/logs that nothing ever rotated — a distinct
# leak class from the other three (none of them look at app-log files at
# all). Delegates to the standalone, independently-selftested log-reaper.sh
# so its size-cap logic is unit-tested in isolation rather than inlined here
# — same pattern as the scratch/transcript levers. Cheap and bounded by
# timeout so it can safely run on every cycle (see the UNLIKE note in this
# file's own header): a handful of `stat` calls, with a `cp`+truncate only
# for a file that is actually over threshold.
#
# LOG_REAPER_PROD=1 (same ga-h565g pattern as the other two reapers): this
# function IS the real, launchd-driven caller log-reaper.sh's own
# production-sentinel guard is designed to trust — the ONLY place that
# should ever set this opt-in.
_reap_growing_logs() {
  if [ "$ENABLED" != "1" ]; then
    log "log-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/log-reaper.sh"
  if [ ! -f "$reaper" ]; then
    log "log-reap SKIP — $reaper not found"
    return
  fi
  if LOG_REAPER_PROD=1 timeout 30 bash "$reaper" >> "$LOG" 2>&1; then
    log "log-reap OK"
  else
    log "log-reap FAILED or aborted (nonzero exit) — see log lines above"
  fi
}

main() {
  local avail class now

  # UNLIKE the other three levers below, this runs UNCONDITIONALLY, before
  # the avail/class computation — see this file's own header for why.
  _reap_growing_logs

  avail="$(_avail_gb "$DOLTDIR")"
  now=$(date +%s)
  class="$(_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB")"

  if [ "$class" = "UNKNOWN" ]; then
    log "WARN: could not read avail space for $DOLTDIR (df failed/unparseable) — cannot verify Dolt's disk floor this cycle"
    "$NOTIFY" -t "Dolt disk-floor guard" -p 3 "⚠️ disk-floor guard couldn't read df for Dolt's data dir — check manually" 2>/dev/null || true
    return 0
  fi
  if [ "$class" = "NONE" ]; then
    log "avail=${avail}GB > floor(warn=${FLOOR_WARN_GB}GB) — OK"
    _write_critical_sustain 0
    return 0
  fi

  # Latch whether THIS reading (pre-reclaim) was CRITICAL. The CRITICAL-tier
  # guarantee ("notify ALWAYS, cooldown bypassed, mail Mayor" — see header) must
  # key off "was CRITICAL at any point this cycle", not solely the `class`
  # recomputed below AFTER reclaim — otherwise a reclaim that recovers avail
  # back into WARN/NONE silently swallows the exact breach this guard exists to
  # report (gate-fix-1: GATE-FEEDBACK on gate_run=ga-wisp-9b4hnh — repro'd with
  # shipped defaults WARN=8/CRIT=3/cooldown=3600: a CRITICAL 2GB reading
  # reclaimed back to exactly 8GB was reclassified WARN and suppressed by
  # ordinary WARN cooldown/worsening logic, skipping the CRITICAL-only
  # mail-Mayor alert entirely).
  local was_critical=0
  [ "$class" = "CRITICAL" ] && was_critical=1

  _read_state
  _safe_reclaim "$avail"
  _reap_dead_scratch "$was_critical"
  _reap_dead_transcripts

  # re-read avail — reclaim may have freed space; `class` becomes the CURRENT
  # (post-reclaim) reading, used for logging/messaging. was_critical also
  # latches a post-reclaim CRITICAL reading (e.g. a concurrent fill worsens
  # avail during the reclaim window) so the guarantee holds regardless of
  # which direction avail moved this cycle.
  local avail_after; avail_after="$(_avail_gb "$DOLTDIR")"
  [ -n "$avail_after" ] && avail="$avail_after"
  class="$(_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB")"
  [ "$class" = "CRITICAL" ] && was_critical=1

  # ga-q4cqr: any cycle that is NOT critical (post-reclaim) breaks a
  # CRITICAL-mail sustain streak, regardless of which of the three
  # non-critical exits below this cycle takes — mirrors
  # ram-pressure-monitor.sh resetting its own EMERGENCY sustain count on
  # every OK *and* every WARN-but-not-EMERGENCY sample. Placed once here
  # (rather than in each of the three exits) so it can't be missed if a
  # future edit adds a fourth.
  [ "$was_critical" = "0" ] && _write_critical_sustain 0

  if [ "$class" = "NONE" ] && [ "$was_critical" = "0" ]; then
    log "avail=${avail}GB back above floor after reclaim — no notify needed"
    _write_state "$now" "$avail"
    return 0
  fi

  local do_notify=1
  if [ "$was_critical" = "0" ] && [ "$class" = "WARN" ] && ! _should_notify "$_LAST_EPOCH" "$now" "$NOTIFY_COOLDOWN_SECS" "$avail" "$_LAST_AVAIL"; then
    do_notify=0
    log "avail=${avail}GB <= warn floor(${FLOOR_WARN_GB}GB) but within cooldown + not worsening — suppressing (last notified avail=${_LAST_AVAIL:-none}GB)"
  fi

  if [ "$do_notify" = "1" ]; then
    local prio=3
    [ "$was_critical" = "1" ] && prio=5
    log "class=${class} was_critical=${was_critical}: avail=${avail}GB (warn=${FLOOR_WARN_GB}GB crit=${FLOOR_CRITICAL_GB}GB) — notifying"
    "$NOTIFY" -t "Dolt disk-floor guard" -p "$prio" "🚨 [${class}] Dolt data-dir avail=${avail}GB — reclaim attempted. See ga-gpzr." 2>/dev/null || true
    if [ "$was_critical" = "1" ]; then
      # ga-q4cqr sustain-guard: require CRITICAL_MAIL_SUSTAIN consecutive
      # CRITICAL cycles before mailing the Mayor — debounces a single
      # transient dip (self-recovering compaction spike). NOTIFY above is
      # UNCONDITIONAL regardless (imp07 invariant, unchanged) — only this
      # durable escalation is gated.
      local pending; pending=$(( $(_read_critical_sustain) + 1 ))
      _write_critical_sustain "$pending"
      if _sustain_confirmed "$pending" "$CRITICAL_MAIL_SUSTAIN"; then
        log "CRITICAL sustain confirmed (${pending}/${CRITICAL_MAIL_SUSTAIN} consecutive cycles) — mailing Mayor"
        # NOTE: deliberately NOT a heredoc — bash 3.2 (macOS system /bin/bash, what
        # launchd invokes per the plist) mis-parses a heredoc nested inside a $(...)
        # command substitution when the body contains an apostrophe (confirmed by
        # direct repro on this machine). A plain multi-line double-quoted assignment
        # has no such bug and is otherwise equivalent.
        local mail_body="dolt-disk-floor-guard: Dolt data-dir hit CRITICAL floor (<= ${FLOOR_CRITICAL_GB}GB) for ${pending} consecutive cycles.
Safe reclaim (gc dolt-cleanup --force) and dead-session scratchpad cleanup were already attempted -
avail is now ${avail}GB (post-reclaim, currently classified ${class}). This is the same class of
event that killed the HQ Dolt server on 2026-07-14 (ga-vs55): a full disk hitting Dolt
mid-journal-write. Recommend checking what is consuming space now (df -h, du -sh on shared/data
and .gc/logs) even if the current reading looks recovered — CRITICAL persisted across multiple
cycles and could recur."
        "$GC" mail send mayor -s "Dolt disk-floor CRITICAL: avail=${avail}GB" -m "$mail_body" 2>/dev/null || log "WARN: gc mail send mayor failed"
      else
        log "CRITICAL sample ${pending}/${CRITICAL_MAIL_SUSTAIN} — PENDING, not yet mailing Mayor (single-cycle dip may self-recover; notify above already fired unconditionally)"
      fi
    fi
    _write_state "$now" "$avail"
  fi
}

# ── run unless sourced as a library (selftest sources with DOLT_DISK_FLOOR_GUARD_LIB=1) ──
if [ "${DOLT_DISK_FLOOR_GUARD_LIB:-0}" != "1" ]; then
  main
  exit 0
fi
