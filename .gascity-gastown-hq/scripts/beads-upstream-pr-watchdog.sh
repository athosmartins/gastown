#!/usr/bin/env bash
# beads-upstream-pr-watchdog.sh — durable watcher for our own upstream PRs
# against gastownhall/beads (the beads CLI's own repo — not a registered gc
# rig, so nothing in the normal gate/dispatch machinery watches it; fixes
# there ship via fork+PR+human-review only).
#
# ga-574zr: the only thing that had EVER polled PR #5439 for review activity
# was an ACCIDENT — a dog's Step 1a resume hook kept re-finding an in_progress
# bead and re-checking it as a side effect of retrying its own dispatch. When
# that bead was correctly moved out of in_progress (ga-e5tn8, a real fix for
# an unrelated false-positive stall alarm), the accidental polling stopped
# with it. Measured same day: 3 of our own upstream PRs (#5439, #5479, #5470)
# sitting open with ZERO durable watcher. This script is the deliberate
# replacement — built on purpose, not a side effect of something else.
#
# What it does:
#   - One `gh pr list --repo gastownhall/beads --author athosmartins --state
#     all` call per sweep, diffed against a persisted per-PR state file.
#   - Alerts ONLY on a state TRANSITION (previously-recorded state != current
#     state) — never on a persisting state. An alert that fires every sweep
#     regardless of change teaches people to ignore it.
#   - On transition to MERGED or CLOSED (without merging): comments on the
#     PR's mapped tracker bead (PR_BEAD_MAP below) and mails the Mayor. Merge
#     means the next step (engine rebuild+swap) needs his coordination; a
#     close-without-merge means a human should decide whether to resubmit.
#   - A PR observed for the FIRST time (no prior state) that is ALREADY
#     merged/closed also alerts immediately — "no prior baseline" must not be
#     silently folded into "nothing changed"; those are different states (see
#     classify_pr_transition below).
#   - Reopened PRs are tracked (state updated) but do not alert — nothing
#     downstream needs to act on a reopen by itself.
#   - Single-instance lock: mkdir+heartbeat+pid-liveness, same shape as
#     gate-orphaned-label-watchdog.sh's GOLW lock (ga-y0g5x: 4 simultaneous
#     watchdog instances stacked Dolt queries and took bd down citywide; the
#     fix there gates reclaim SOLELY on `kill -0` liveness, never on
#     heartbeat age alone — an old-but-alive holder must never be reclaimed).
#   - Runs once/day via launchd StartCalendarInterval (NOT StartInterval — a
#     long StartInterval resets its countdown on every sleep/reboot of the
#     mini and may in practice never fire; see upstream-drift-sentinel.plist
#     for the same lesson already learned in this repo). NOT CronCreate —
#     session-only, expires in 7 days, would silently reproduce this exact
#     bug (an invisible watcher nobody notices disappearing).
#
# TEST (hermetic, no live gh/bd/gc):
#   bash scripts/beads-upstream-pr-watchdog.selftest.sh
set -uo pipefail

HQ="${BUPW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
GH_REPO="${BUPW_GH_REPO:-gastownhall/beads}"
GH_AUTHOR="${BUPW_GH_AUTHOR:-athosmartins}"
GH_LIMIT="${BUPW_GH_LIMIT:-200}"
BD_BIN="${BD_BIN:-bd}"
GC_BIN="${GC_BIN:-gc}"
LOG="${BUPW_LOG:-$HQ/.gc/logs/beads-upstream-pr-watchdog.log}"
STATE="${BUPW_STATE:-$HOME/.gastown/state/beads-upstream-pr-watchdog.state.json}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# PR number -> tracker bead + the bead's OWN city. wa-* beads live in the
# whatsapp_automation rig's own bead DB, not HQ's — `bd show` without the
# right -C returns "no issue found", not a loud error you'd notice from exit
# code alone. Add a line here whenever a new upstream PR needs tracking.
PR_BEAD_MAP='
[
  {"pr": 5439, "bead": "wa-msxg5", "city": "/Users/athos/gt/whatsapp_automation"},
  {"pr": 5479, "bead": "wa-msxg5", "city": "/Users/athos/gt/whatsapp_automation"},
  {"pr": 5470, "bead": "ga-7uoua", "city": "/Users/athos/gt/.gascity-gastown-hq"}
]
'

# classify_pr_transition <prev_state> <cur_state>
#   -> first-seen | merged | closed-no-merge | reopened | no-change | unknown
# Pure decision, no I/O — same shape as classify_external_pr_gap3 in
# quality-gate-guard.sh (that one sweeps per-bead-labeled PRs; this one
# sweeps by author, so a PR needs no per-bead opt-in to be watched).
# prev="UNKNOWN" means "no prior sweep ever recorded a state for this PR" —
# kept distinct from "recorded and unchanged" (no-change) on purpose: a PR
# that is ALREADY merged/closed the first time we ever see it still deserves
# an alert, because nothing has watched its transition until now either.
classify_pr_transition() {
  local prev="$1" cur="$2"
  if [ "$prev" = "UNKNOWN" ]; then
    case "$cur" in
      MERGED) echo "merged"; return ;;
      CLOSED) echo "closed-no-merge"; return ;;
      *)      echo "first-seen"; return ;;
    esac
  fi
  if [ "$prev" = "$cur" ]; then echo "no-change"; return; fi
  case "$cur" in
    MERGED) echo "merged" ;;
    CLOSED) echo "closed-no-merge" ;;
    OPEN)   echo "reopened" ;;
    *)      echo "unknown" ;;
  esac
}

# Both _alert_* functions return 0 only if EVERY notification channel
# succeeded, 1 if any failed. The caller (run_sweep) uses this to decide
# whether the transition is truly "handled" — see the state-advance comment
# below for why that distinction matters.
_alert_merge() {
  local pr_num="$1" url="$2" bead_id="$3" bead_city="$4" msg ok=0
  msg="beads-upstream-pr-watchdog (ga-574zr): upstream PR $url (gastownhall/beads #$pr_num, author $GH_AUTHOR) is now MERGED. Next step (engine rebuild+swap) needs Mayor coordination — this bead does not close itself."
  printf '%s' "$msg" | "$BD_BIN" -C "$bead_city" comment "$bead_id" --stdin >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: bd comment failed for $bead_id (PR #$pr_num)"; }
  "$GC_BIN" mail send mayor -s "Upstream PR merged: gastownhall/beads #$pr_num" -m "$msg" >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: gc mail send failed for PR #$pr_num"; }
  return "$ok"
}

_alert_closed_no_merge() {
  local pr_num="$1" url="$2" bead_id="$3" bead_city="$4" msg ok=0
  msg="beads-upstream-pr-watchdog (ga-574zr): upstream PR $url (gastownhall/beads #$pr_num, author $GH_AUTHOR) was CLOSED WITHOUT merging. A human should decide whether to resubmit or abandon."
  printf '%s' "$msg" | "$BD_BIN" -C "$bead_city" comment "$bead_id" --stdin >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: bd comment failed for $bead_id (PR #$pr_num)"; }
  "$GC_BIN" mail send mayor -s "Upstream PR closed without merge: gastownhall/beads #$pr_num" -m "$msg" >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: gc mail send failed for PR #$pr_num"; }
  return "$ok"
}

run_sweep() {
  if ! command -v gh >/dev/null 2>&1; then
    log "gh CLI not found on PATH — skipping sweep entirely"
    return 0
  fi

  local all_prs
  all_prs=$(gh pr list --repo "$GH_REPO" --author "$GH_AUTHOR" --state all \
    --json number,state,mergedAt,url,title --limit "$GH_LIMIT" 2>>"$LOG")
  if [ -z "$all_prs" ] || ! printf '%s' "$all_prs" | jq -e '.' >/dev/null 2>&1; then
    log "gh pr list failed or returned unparseable output — safe-skip, no state change"
    return 0
  fi

  local prev_state
  prev_state=$(cat "$STATE" 2>/dev/null || echo '{}')
  printf '%s' "$prev_state" | jq -e '.' >/dev/null 2>&1 || prev_state='{}'
  local new_state="$prev_state"
  local tracked_count=0 event_count=0

  local pr_num bead_id bead_city
  while IFS=$'\t' read -r pr_num bead_id bead_city; do
    [ -z "$pr_num" ] && continue

    local cur cur_state cur_url prev_pr_state action handled
    cur=$(printf '%s' "$all_prs" | jq -c --argjson n "$pr_num" '[.[] | select(.number == $n)][0] // empty')
    if [ -z "$cur" ]; then
      log "PR #$pr_num (author=$GH_AUTHOR) not found in this sweep's result — safe-skip (may be outside --limit=$GH_LIMIT; widen BUPW_GH_LIMIT if this persists)"
      continue
    fi
    cur_state=$(printf '%s' "$cur" | jq -r '.state')
    cur_url=$(printf '%s' "$cur" | jq -r '.url')
    prev_pr_state=$(printf '%s' "$prev_state" | jq -r --arg k "$pr_num" '.[$k].state // "UNKNOWN"')

    tracked_count=$((tracked_count + 1))
    action=$(classify_pr_transition "$prev_pr_state" "$cur_state")
    # "handled" gates whether new_state advances below. A transition whose
    # alert only partially succeeded (e.g. bd comment landed but the Mayor
    # mail failed on a transient Dolt/network blip) must NOT be recorded as
    # done — advancing the state here would permanently silence the retry,
    # since transition-only alerting means classify_pr_transition() would see
    # MERGED->MERGED ("no-change") on every future sweep and never speak
    # again. Leaving prev_pr_state untouched costs one duplicate alert
    # (visible, cheap) in exchange for never silently losing one.
    handled=1
    case "$action" in
      merged)
        log "TRANSITION: PR #$pr_num $prev_pr_state -> $cur_state (merged) — alerting bead=$bead_id"
        if _alert_merge "$pr_num" "$cur_url" "$bead_id" "$bead_city"; then
          event_count=$((event_count + 1))
        else
          handled=0
          log "WARN: PR #$pr_num merge alert incomplete — state NOT advanced, will retry next sweep"
        fi
        ;;
      closed-no-merge)
        log "TRANSITION: PR #$pr_num $prev_pr_state -> $cur_state (closed, no merge) — alerting bead=$bead_id"
        if _alert_closed_no_merge "$pr_num" "$cur_url" "$bead_id" "$bead_city"; then
          event_count=$((event_count + 1))
        else
          handled=0
          log "WARN: PR #$pr_num closed-no-merge alert incomplete — state NOT advanced, will retry next sweep"
        fi
        ;;
      reopened)
        log "TRANSITION: PR #$pr_num $prev_pr_state -> $cur_state (reopened) — tracking resumes, no alert"
        event_count=$((event_count + 1))
        ;;
      first-seen)
        log "BASELINE: PR #$pr_num first seen at state=$cur_state (bead=$bead_id) — no prior watcher to compare against, recording only"
        ;;
      no-change) ;;
      *)
        log "WARN: PR #$pr_num unrecognized transition $prev_pr_state -> $cur_state"
        event_count=$((event_count + 1))
        ;;
    esac

    if [ "$handled" = "1" ]; then
      new_state=$(printf '%s' "$new_state" | jq --arg k "$pr_num" --arg s "$cur_state" --arg t "$(ts)" \
        '.[$k] = {state: $s, checked_at: $t}')
    fi
  done < <(printf '%s' "$PR_BEAD_MAP" | jq -r '.[] | [.pr, .bead, .city] | @tsv')

  # Unconditional per-sweep line, even when nothing changed: on a log that
  # only ever writes on notable events, a daemon that silently stopped
  # running would leave the exact same empty-since-last-write log as one that
  # ran fine and found nothing new — the two are indistinguishable without
  # this. This line is the proof-of-life the other one can't provide.
  log "sweep complete: $tracked_count tracked PR(s), $event_count event(s)"

  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  printf '%s' "$new_state" > "$STATE" 2>/dev/null || log "WARN: failed to write state file $STATE"
}

# ── Single-instance lock ────────────────────────────────────────────────────
# Same shape as gate-orphaned-label-watchdog.sh's GOLW lock (ga-y0g5x): atomic
# `mkdir` mutex (POSIX-atomic, no fd — a leaked fd can never keep a directory
# "locked", unlike the flock-inode leak that once deadlocked the pilot for
# 5h+), a heartbeat file for staleness, and `kill -0 $pid` as the SOLE gate on
# reclaim (age is diagnostic-only in the log line — gating reclaim on age
# alone can steal the lock from a legitimately-slow-but-alive holder).
BUPW_LOCK_ENABLED="${BUPW_LOCK_ENABLED:-1}"
BUPW_LOCK_DIR="${TMPDIR:-/tmp}/beads-upstream-pr-watchdog.lock.d"
BUPW_LOCK_HB="$BUPW_LOCK_DIR/heartbeat"
BUPW_LOCK_REAP_TTL="${BUPW_LOCK_REAP_TTL:-10}"
BUPW_LOCK_TOKEN="${BUPW_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"

_bupw_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}
_bupw_lock_hb_age() { _bupw_lock_path_age "$BUPW_LOCK_HB"; }

_bupw_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$BUPW_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null && return 1
  return 0
}

_bupw_lock_write_hb() { printf '%s\n' "$BUPW_LOCK_TOKEN" > "$BUPW_LOCK_HB" 2>/dev/null || true; }

_release_bupw_lock() {
  local _own
  _own=$(head -n1 "$BUPW_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$BUPW_LOCK_TOKEN" ] && rm -rf "$BUPW_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE run holds it (caller backs off).
_acquire_bupw_lock() {
  if mkdir "$BUPW_LOCK_DIR" 2>/dev/null; then
    _bupw_lock_write_hb
    if [ ! -s "$BUPW_LOCK_HB" ]; then
      rm -rf "$BUPW_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  if ! _bupw_lock_holder_dead; then
    return 1   # holder is ALIVE -> never reclaim, no matter how old the heartbeat is.
  fi
  if [ ! -s "$BUPW_LOCK_HB" ]; then
    return 1
  fi
  local _reaping="${BUPW_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    if [ "$(_bupw_lock_path_age "$_reaping")" -ge "$BUPW_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${BUPW_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then rm -rf "$_dead" 2>/dev/null || true; fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1   # another reclaimer owns the recovery -> back off (no double-win).
    fi
  fi
  if ! _bupw_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  local _age
  _age=$(_bupw_lock_hb_age)
  _bupw_lock_write_hb
  if [ ! -s "$BUPW_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE/DEAD lock (heartbeat age ${_age}s) — taking over."
  return 0
}

# Lib mode (BEADS_UPSTREAM_PR_WATCHDOG_LIB=1): define functions, do not run —
# lets the selftest source this file and drive run_sweep()/classify_pr_transition()
# directly against hermetic fixtures. Matches the house convention
# (GATE_DISPATCHER_LIB_ONLY, ORDER_EXEC_FAILURE_WATCHDOG_LIB, …) used
# throughout this tree's *.selftest.sh files.
if [ "${BEADS_UPSTREAM_PR_WATCHDOG_LIB:-0}" != "1" ]; then
  if [ "$BUPW_LOCK_ENABLED" = "1" ]; then
    if _acquire_bupw_lock; then
      trap '_release_bupw_lock' EXIT
    else
      log "Another beads-upstream-pr-watchdog run holds the lock — backing off (single-instance guard)."
      exit 0
    fi
  fi
  run_sweep
  exit 0
fi
