#!/usr/bin/env bash
# quality-gate-dispatcher.sh — Autonomous Quality Gate Dispatcher ("G").
#
# Runs every ~2 min via launchd (com.gascity.quality-gate-dispatcher.plist).
# Picks up gate-status:queued markers (set by quality-gate-guard.sh after it
# claims and validates the marker), then:
#
#   1. Determines tier (CODE → 3 independent sessions; NON-CODE → 1 session + tests).
#   2. Spawns N GENUINELY INDEPENDENT reviewer sessions via
#      "gc session new gate-reviewer --no-attach".  NO shared context. Each
#      receives a unique targeted nudge describing exactly its review task.
#   3. Polls verdict beads until all reviewers post PASS or FAIL (or timeout).
#   4. On ALL-PASS  → direct-merge to production main + close source bead.
#      On ANY-FAIL  → set gate-status:failed, post blocking reasons, nudge author.
#   5. Appends one compact JSON line to .gc/quality-gate.jsonl.
#
# DESIGN INVARIANTS:
#   - Author-exclusion uses authoritative bead source (assignee/created_by).
#   - 3 separate dog sessions = 3 separate Claude Code processes. Not role-play.
#   - Verdict collection: each reviewer session closes its personal verdict bead
#     with a label "verdict:PASS" or "verdict:FAIL" and a comment with reason.
#   - DRY_RUN=1 → skips the actual git merge/push; logs "WOULD MERGE" instead.
#   - DRAIN-SAFE: this file + its plist are the ONLY artifacts. Does not touch
#     city.toml, pack.toml, or any crew skill files.
#
# Usage:
#   bash quality-gate-dispatcher.sh            # normal run
#   DRY_RUN=1 bash quality-gate-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/quality-gate-dispatcher.log"
QG_LOG="$GC_CITY/.gc/quality-gate.jsonl"

# Maximum wall-clock minutes to wait for all reviewer verdicts before timing out.
VERDICT_TIMEOUT_MINUTES="${VERDICT_TIMEOUT_MINUTES:-45}"

# Safety floor: never allow a timeout shorter than 15 minutes regardless of env var.
# (Prevents accidental short timeouts from leftover test env vars causing false FAILs.)
if [ "$VERDICT_TIMEOUT_MINUTES" -lt 15 ] 2>/dev/null; then
  warn "VERDICT_TIMEOUT_MINUTES=${VERDICT_TIMEOUT_MINUTES} is dangerously short — overriding to 15m (floor)."
  VERDICT_TIMEOUT_MINUTES=15
fi

# Poll interval (seconds) when waiting for verdicts.
VERDICT_POLL_INTERVAL="${VERDICT_POLL_INTERVAL:-30}"

# ── ga-zl277: orphaned gate-reviewer session TTL ──────────────────────────────
# A gate-reviewer session older than this cannot belong to any live run: a live
# dispatcher closes its reviewers in Step 9, and the verdict poll itself caps a
# run at VERDICT_TIMEOUT_MINUTES. The startup janitor (Step 0a-2) reaps asleep
# gate-reviewer sessions older than this so SIGKILL/OOM-orphaned reviewers cannot
# fill the gate-reviewer template's max_active_sessions=6 budget. TTL = verdict
# timeout + margin (slack over the longest a live run can hold a session open).
REVIEWER_SESSION_TTL_MINUTES="${REVIEWER_SESSION_TTL_MINUTES:-$((VERDICT_TIMEOUT_MINUTES + 20))}"

# Dry-run mode: skip actual git merge+push.
DRY_RUN="${DRY_RUN:-0}"

# ── ga-4u16h: re-convene a DEAD reviewer slot mid-collection ──────────────────
# The Dolt :52756 server intermittently resets connections (root cause ga-hxhaj).
# When a reset kills a gate-reviewer SESSION mid-review, its verdict bead stays
# verdict:pending; pre-ga-4u16h the dispatcher waited the FULL outer timeout and
# then counted the missing verdict as a FAIL — bouncing a GOOD fix on INFRA.
# Fix: when a slot's reviewer SESSION is confirmed DEAD (gone from the session
# list, or closed=true) while its verdict bead is still pending, re-spawn a FRESH
# reviewer for THAT slot (reusing the still-pending verdict bead), bounded by a
# per-slot budget. Real verdict:FAIL votes still fail immediately; healthy runs
# are unaffected. A permanently-broken Dolt converges to FAIL within
# (1 + MAX_RESPAWNS_PER_SLOT) reviewer cohorts via the unchanged outer timeout.
#
# Max re-spawns per reviewer slot. 0 disables re-convene (exact pre-ga-4u16h
# behavior). Sanitized + ceiling-guarded (mirrors the VERDICT_TIMEOUT floor).
MAX_RESPAWNS_PER_SLOT="${MAX_RESPAWNS_PER_SLOT:-2}"
case "$MAX_RESPAWNS_PER_SLOT" in ''|*[!0-9]*) MAX_RESPAWNS_PER_SLOT=2 ;; esac
if [ "$MAX_RESPAWNS_PER_SLOT" -gt 5 ] 2>/dev/null; then
  MAX_RESPAWNS_PER_SLOT=5   # ceiling: never thrash spawning >5 cohorts for one slot
fi

# Grace window (seconds) a freshly-(re)spawned reviewer gets before its session
# may be judged DEAD — covers slow startup/waking so a live-but-slow reviewer is
# NEVER re-convened. Floor-guarded.
RECONVENE_GRACE_SECS="${RECONVENE_GRACE_SECS:-60}"
case "$RECONVENE_GRACE_SECS" in ''|*[!0-9]*) RECONVENE_GRACE_SECS=60 ;; esac
[ "$RECONVENE_GRACE_SECS" -lt 20 ] 2>/dev/null && RECONVENE_GRACE_SECS=20

# Consecutive polls a slot must read DEAD before re-convene fires (defends
# against a transient/partial `gc session list`). Floor-guarded.
RECONVENE_DEAD_STREAK_MIN="${RECONVENE_DEAD_STREAK_MIN:-2}"
case "$RECONVENE_DEAD_STREAK_MIN" in ''|*[!0-9]*) RECONVENE_DEAD_STREAK_MIN=2 ;; esac
[ "$RECONVENE_DEAD_STREAK_MIN" -lt 1 ] 2>/dev/null && RECONVENE_DEAD_STREAK_MIN=1

# ga-mepb0 (defense-in-depth, root cause): seconds to pause after waking each
# reviewer (except the last) so N reviewers do NOT all boot `gc prime`
# (SessionStart) against the Dolt :52756 server at the same instant. That
# thundering herd is what opens the Dolt circuit-breaker and wedges a reviewer
# at boot in the first place (EDIT #1 re-convenes survivors; this lowers the odds
# of the wedge at all). 0 disables. Floor 0, capped so a misconfig can't add
# pathological latency to every gate. Total added latency = stagger × (N-1).
GATE_SPAWN_STAGGER_SECS="${GATE_SPAWN_STAGGER_SECS:-3}"
case "$GATE_SPAWN_STAGGER_SECS" in ''|*[!0-9]*) GATE_SPAWN_STAGGER_SECS=3 ;; esac
[ "$GATE_SPAWN_STAGGER_SECS" -gt 15 ] 2>/dev/null && GATE_SPAWN_STAGGER_SECS=15

# session_is_dead <present 0|1> <closed true|false|1|0> → echoes 1 (dead) | 0 (alive)
# A reviewer session is DEAD iff it is absent from the session list (present=0)
# OR explicitly closed. A present, non-closed session (active OR asleep) is ALIVE
# — `asleep` is the normal state of a reviewer that finished or is between turns,
# so it must NEVER be treated as dead. Pure; no I/O.
session_is_dead() {
  local present="$1" closed="$2"
  if [ "$present" = "0" ]; then echo 1; return 0; fi
  case "$closed" in true|TRUE|True|1) echo 1 ;; *) echo 0 ;; esac
}

# classify_slot_action <bead_closed 0|1> <session_dead 0|1> <budget_remaining int>
# The single decision for ONE reviewer slot in a poll iteration. Pure; no I/O.
#   received → verdict bead is closed (a verdict — PASS or FAIL — was recorded);
#              caller's existing logic counts it. NEVER re-spawn (so an explicit
#              verdict:FAIL fails immediately, as before).
#   respawn  → bead still pending AND session confirmed dead AND budget remains.
#   wait     → everything else: a live (slow) reviewer, OR a dead slot whose
#              budget is exhausted (the outer timeout is the ultimate backstop —
#              bounded, never spins).
classify_slot_action() {
  local bead_closed="$1" session_dead="$2" budget="$3"
  case "$budget" in ''|*[!0-9-]*) budget=0 ;; esac
  if [ "$bead_closed" = "1" ]; then echo "received"; return 0; fi
  if [ "$session_dead" = "1" ] && [ "$budget" -gt 0 ] 2>/dev/null; then echo "respawn"; return 0; fi
  echo "wait"
}

# slot_effectively_dead <session_dead 0|1> <acked 0|1> → 1 (treat as dead for the
# re-convene decision) | 0. Pure; no I/O.
# ga-mepb0: session_is_dead only sees absent/closed sessions. A reviewer can be
# PRESENT + not-closed (session_is_dead=0) yet wedged at boot — its SessionStart
# `gc prime` hung on the Dolt :52756 circuit-breaker, so the session is asleep
# with 0 terminal output and a still-pending verdict bead. It NEVER ACKs, so the
# ga-4u16h liveness gate alone could not see it and only the 45m outer timeout
# caught it → a FALSE FAIL on a GOOD branch. Fold the ACK signal into deadness: a
# slot is effectively dead if its session is DEAD *or* it has never shown a sign
# of life (acked != 1). The caller re-checks for LATE life (verdict progressed or
# new output) BEFORE trusting acked, so a slow-but-alive reviewer is never killed.
slot_effectively_dead() {
  local session_dead="$1" acked="$2"
  if [ "$session_dead" = "1" ]; then echo 1; return 0; fi
  if [ "$acked" != "1" ]; then echo 1; return 0; fi
  echo 0
}

# respawn_reviewer_slot <0-based idx> — re-spawn a fresh gate-reviewer session for
# a dead slot, REUSING the still-pending verdict bead VERDICT_BEAD_IDS[idx] and
# re-delivering the SAME stored review task REVIEW_TASKS[idx] (it already
# references the unchanged verdict bead). Updates SESSION_IDS[idx] in place.
# Returns 0 on a fresh spawn+nudge, 1 if the spawn itself failed (caller has
# already consumed budget so a permanent spawn failure stays bounded). Reuses the
# exact gate-reviewer template + independence model of the Step 7/8 spawn block;
# deliberately omits the spawn-abort escalation (that guards the INITIAL cohort —
# here the outer timeout + budget already bound the failure). No new verdict bead.
respawn_reviewer_slot() {
  local _idx="$1"
  local _rev=$(( _idx + 1 ))
  local _err_file="/tmp/gate-reviewer-respawn-err-$$.${_idx}"
  local _json _new_sid
  _json=$(gc --city "$GC_CITY" session new gate-reviewer \
    --no-attach \
    --title "gate-reviewer-${_rev} (re-convened): $BRANCH" \
    --json \
    2>"$_err_file" || echo "{}")
  rm -f "$_err_file" 2>/dev/null || true
  _new_sid=$(echo "$_json" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  if [ -z "$_new_sid" ]; then
    warn "  Re-convene: failed to spawn replacement reviewer for slot ${_idx} — slot stays dead; outer timeout is the backstop."
    return 1
  fi
  SESSION_IDS[$_idx]="$_new_sid"
  # ga-mepb0: the re-convened session must re-prove life. Clear its ACK flag so
  # the carried-over ACKED=1 from the since-replaced session cannot mask a fresh
  # boot-wedge. Index-assignment is safe even if the arrays are sparse.
  REVIEWER_ACKED[$_idx]=0
  gc --city "$GC_CITY" session wake "$_new_sid" 2>/dev/null || true
  # ga-mepb0: snapshot a REAL peek baseline for the NEW session here (post-wake,
  # pre-delivery) — exactly as the initial spawn does. Do NOT leave it empty: an
  # empty baseline differs from the boot banner's non-empty cksum, so the very
  # next poll's soft late-ACK would fire on boot output alone and falsely mark a
  # re-wedged respawn ALIVE — sending it back to the 45m timeout this fix exists
  # to kill. With a real pre-delivery baseline, only output produced AFTER task
  # delivery (genuine sign of life) flips the ACK. `|| echo ""` keeps set -e safe;
  # an empty result here is the conservative case (no false ACK), still backed by
  # the verdict-progressed strong check.
  REVIEWER_PEEK_BASELINE[$_idx]=$(gc --city "$GC_CITY" session peek "$_new_sid" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
  if gc --city "$GC_CITY" session nudge "$_new_sid" "${REVIEW_TASKS[$_idx]}" --delivery queue 2>/dev/null; then
    log "  Re-convene: review task re-queued to fresh session ${_new_sid} (slot ${_idx}, verdict bead ${VERDICT_BEAD_IDS[$_idx]} reused)."
  elif gc --city "$GC_CITY" session submit "$_new_sid" "${REVIEW_TASKS[$_idx]}" 2>/dev/null; then
    log "  Re-convene: review task re-submitted to fresh session ${_new_sid} (slot ${_idx})."
  else
    warn "  Re-convene: queue/submit to fresh session ${_new_sid} failed (slot ${_idx}) — verdict-poll + outer timeout backstop."
  fi
  return 0
}

# ── ga-rstw5: bare-mirror reconcile to origin (durable-landing false-FAIL fix) ─
# Container rigs keep a bare .repo.git whose OWN refs/heads/<main> a `git push` to
# origin never advances. When that bare ref drifts/forks from origin/<main> — the
# canonical durable line the gate merge pushes to — the durable-landing step used
# to FF-only-or-FAIL, flipping an all-PASS verdict to failed_durable_not_ff the
# moment the bare ref had FORKED (WA's orphan 'preserve' 9c8c8a20 from the
# gt-fc02b7 decommission). The merge DID land on origin; the bare mirror must just
# track it. These two functions (a pure decision + its git plumbing) are defined
# BEFORE the lib-only guard so gate-durable-landing-reconcile.selftest.sh can
# exercise both with real temp repos — single source of truth, no copy-drift.

# reconcile_main_action <local_sha> <origin_sha> <local_anc_origin 0|1> <origin_anc_local 0|1>
#   Pure (no IO, set -e safe). Echoes the ref move that makes the bare mirror track
#   origin, given the ancestry relationship:
#     noop      — already equal, OR bare strictly AHEAD of origin (extra local-only
#                 commits we must NOT discard), OR origin unresolvable (safety).
#     ff        — bare absent or strictly BEHIND origin (ancestor) → advance to origin.
#     reconcile — FORKED (neither is the other's ancestor) → reset bare to origin
#                 (canonical), preserving the forked tip under a backup ref.
reconcile_main_action() {
  local lsha="$1" osha="$2" local_anc_origin="$3" origin_anc_local="$4"
  [ -z "$osha" ] && { echo "noop"; return 0; }
  [ -z "$lsha" ] && { echo "ff"; return 0; }
  [ "$lsha" = "$osha" ] && { echo "noop"; return 0; }
  [ "$local_anc_origin" = "1" ] && { echo "ff"; return 0; }
  [ "$origin_anc_local" = "1" ] && { echo "noop"; return 0; }
  echo "reconcile"
}

# reconcile_bare_main_to_origin <bare_git_dir> <branch>
#   Git plumbing around reconcile_main_action. Fetches origin/<branch> into the
#   bare repo, classifies ancestry, and applies the decided ref move. FF-safe and
#   idempotent (noop when already tracking); only a FORKED ref is rewritten, and
#   only ever TO origin — the forked tip is first saved under
#   refs/heads/_backup-forked-<branch>-<sha> for forensics. Echoes a one-token
#   outcome (noop:* | ff:* | reconcile:* | fetch-failed | origin-unresolved |
#   updateref-failed); returns 0 on success/no-op, 1 on a hard git failure.
#   set -e safe: every git call is wrapped in `if`/`||` so a non-zero exit (e.g.
#   is-ancestor=false) never trips the shell, and callers capture rc via `|| rc=$?`.
reconcile_bare_main_to_origin() {
  local gdir="$1" branch="$2"
  if ! git --git-dir="$gdir" fetch origin "$branch" --quiet 2>/dev/null; then
    if ! git --git-dir="$gdir" fetch origin --quiet 2>/dev/null; then
      echo "fetch-failed"; return 1
    fi
  fi
  local osha lsha
  osha=$(git --git-dir="$gdir" rev-parse --verify -q "origin/$branch^{commit}" 2>/dev/null || echo "")
  [ -z "$osha" ] && { echo "origin-unresolved"; return 1; }
  lsha=$(git --git-dir="$gdir" rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null || echo "")
  local la=0 oa=0
  if [ -n "$lsha" ]; then
    if git --git-dir="$gdir" merge-base --is-ancestor "$lsha" "$osha" 2>/dev/null; then la=1; fi
    if git --git-dir="$gdir" merge-base --is-ancestor "$osha" "$lsha" 2>/dev/null; then oa=1; fi
  fi
  local action
  action=$(reconcile_main_action "$lsha" "$osha" "$la" "$oa")
  case "$action" in
    noop)
      echo "noop:${lsha:-<none>}"; return 0 ;;
    ff)
      if ! git --git-dir="$gdir" update-ref "refs/heads/$branch" "$osha" 2>/dev/null; then
        echo "updateref-failed"; return 1
      fi
      echo "ff:${lsha:-<none>}->$osha"; return 0 ;;
    reconcile)
      git --git-dir="$gdir" update-ref "refs/heads/_backup-forked-${branch}-${lsha}" "$lsha" 2>/dev/null || true
      if ! git --git-dir="$gdir" update-ref "refs/heads/$branch" "$osha" 2>/dev/null; then
        echo "updateref-failed"; return 1
      fi
      echo "reconcile:${lsha}->${osha}(backup:_backup-forked-${branch}-${lsha})"; return 0 ;;
  esac
}

# Lib-only entrypoint for quality-gate-reconvene.selftest.sh: expose the helpers
# above WITHOUT running the live dispatcher (mirrors quality-gate-guard.sh's
# GATE_GUARD_LIB_ONLY). Must precede the log-redirect + live work below. Never
# taken in normal `bash quality-gate-dispatcher.sh` execution.
if [ -n "${GATE_DISPATCHER_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

# Load guard pure functions (lib-only: no live sweep) — gives us parse_marker_id
# as the canonical single source of truth (DRY: ga-b92q / ga-tmug).
GATE_GUARD_LIB_ONLY=1 source "${GC_CITY}/packs/town-deltas/assets/quality-gate-guard.sh" 2>/dev/null || true

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] WARN: $*"; }

# ── ga-piscg: systemic spawn-abort escalation (consecutive-abort alert) ───────
# The dispatcher processes exactly ONE queued marker per sweep. A broken spawn
# mechanism (gate-reviewer template misconfig / session-cap deadlock — ga-mzc3h)
# aborts the reviewer-spawn for EVERY marker, but each marker churns
# error→queued→error too fast for the per-marker [GATE-ERROR] monitor (10min
# stuck) to fire. We persist a counter across sweeps so K CONSECUTIVE
# spawn-aborts (across markers, not one branch) PAGE A HUMAN in minutes — the
# alerting layer that was missing during the 2026-06-06 town-wide 20h outage
# (dispatcher aborted spawn 7+x, set gate-status:error each time, never escalated).
SPAWN_ABORT_THRESHOLD="${SPAWN_ABORT_THRESHOLD:-3}"          # consecutive aborts before paging
SPAWN_ABORT_REALERT_SEC="${SPAWN_ABORT_REALERT_SEC:-1800}"  # re-page cadence (30m) while still broken
SPAWN_ABORT_COUNT_FILE="$GC_CITY/.gc/gate-spawn-abort-count"     # persisted consecutive count
SPAWN_ABORT_ALERT_FILE="$GC_CITY/.gc/gate-spawn-abort-alerted"  # last-page epoch (re-alert cadence)

# Pure decision (no IO, set -e safe) so the selftest can drift-guard it:
# given (consecutive_count, threshold, now_epoch, last_alert_epoch, realert_sec)
# echo "page" iff count>=threshold AND we are past the re-alert cooldown, else "hold".
spawn_abort_should_page() {
  local count="$1" threshold="$2" now="$3" last="$4" realert="$5"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last"  in ''|*[!0-9]*) last=0  ;; esac
  if [ "$count" -lt "$threshold" ]; then echo "hold"; return 0; fi
  if [ "$((now - last))" -ge "$realert" ]; then echo "page"; else echo "hold"; fi
}

# NOTE: set_gate_status() is provided by the guard lib sourced above (line ~58,
# GATE_GUARD_LIB_ONLY=1) — same DRY pattern as parse_marker_id. Single source of
# truth in quality-gate-guard.sh; no copy here to avoid drift (ga-jhyu).

# ── supersede_sibling_runs — proactively close guard's companion gate-run bead ─
# The guard creates a quality-gate: sibling bead at claim time. The dispatcher
# drives ITS OWN gate-run: bead but never drives the sibling to terminal (ga-tmug
# Vector B). Calling this on BOTH PASS and FAIL terminal paths supersedes any
# still-running sibling immediately, without waiting for the guard's 90m TTL fallback.
#
# Usage: supersede_sibling_runs <marker_id> <branch> <bead_id>
supersede_sibling_runs() {
  local this_marker="$1" branch="$2" bead_id="$3"
  [ -z "$this_marker" ] && return 0

  local running_json count
  running_json=$(bd -C "$GC_CITY" list --json --all \
    -l type:quality-gate-run \
    -l gate-status:running \
    2>/dev/null || echo "[]")
  count=$(echo "$running_json" | jq 'length' 2>/dev/null || echo "0")
  [ "$count" = "0" ] && return 0

  local i sibling sibling_id sibling_desc sibling_marker
  for i in $(seq 0 $((count - 1))); do
    sibling=$(echo "$running_json" | jq ".[$i]")
    sibling_id=$(echo "$sibling" | jq -r '.id')
    sibling_desc=$(echo "$sibling" | jq -r '.description // ""')
    sibling_marker=$(parse_marker_id "$sibling_desc")

    if [ "$sibling_marker" = "$this_marker" ] || \
       { [ -n "$bead_id" ] && echo "$sibling_desc" | grep -q "source_bead: $bead_id"; }; then
      log "  Superseding sibling gate-run $sibling_id (marker=$sibling_marker, branch=$branch)"
      set_gate_status "$sibling_id" "superseded"
      bd -C "$GC_CITY" comment "$sibling_id" "Dispatcher: gate-run superseded proactively on terminal path (marker $this_marker reached terminal; branch $branch). No need to wait for 90m TTL fallback. (ga-tmug Vector B)" 2>/dev/null || true
      # ga-jhyu: CLOSE at terminal so wisp-compact reaps it (was relabel-only → OPEN forever).
      bd -C "$GC_CITY" close "$sibling_id" -r "gate-run superseded (terminal) — marker $this_marker reached terminal. Closed by dispatcher (ga-jhyu)." 2>/dev/null || true
    fi
  done
}

echo ""
log "=== Dispatcher sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Step 0a: TTL recovery — re-queue zombie dispatching markers ───────────────
# If a marker has been in gate-status:dispatching for > DISPATCHING_TTL_MINUTES,
# the dispatcher process was killed mid-run (after claiming but before completing).
# These would otherwise block forever because the dispatcher only processes
# gate-status:queued markers.  Reset them to queued so this sweep (or the next)
# can re-process them.
#
# TTL is 30m — same as the guard's claimed TTL.  Any legitimate dispatcher run
# that's been in flight for 30m has either spawned reviewers (verdict poll keeps
# the bead alive) or should be considered dead.
#
# Safety: we only recover markers that are STILL in dispatching — i.e. the
# dispatcher never finished (no passed/failed/error/needs-rebase was set).
DISPATCHING_TTL_MINUTES=30

DISPATCHING_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:dispatching \
  2>/dev/null || echo "[]")
DISPATCHING_COUNT=$(printf '%s\n' "$DISPATCHING_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$DISPATCHING_COUNT" -gt 0 ]; then
  NOW_EPOCH_D=$(date +%s)
  for di in $(seq 0 $((DISPATCHING_COUNT - 1))); do
    D_MARKER=$(printf '%s\n' "$DISPATCHING_JSON" | jq ".[$di]")
    D_ID=$(printf '%s\n' "$D_MARKER" | jq -r '.id')
    D_UPDATED=$(printf '%s\n' "$D_MARKER" | jq -r '.updated_at // .created_at // ""')
    if [ -z "$D_UPDATED" ]; then continue; fi
    # updated_at/created_at is UTC ("...Z"). Parse the BSD branch with -u so the
    # epoch is absolute and matches `date +%s`; without -u, macOS `date -j -f`
    # reads the naive timestamp as LOCAL time and ages come out skewed by the UTC
    # offset (negative under UTC-3), so the DISPATCHING_TTL recovery never fires
    # (ga-35zp1). GNU `date -d` keeps the trailing Z and is already UTC-correct.
    D_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${D_UPDATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$D_UPDATED" +%s 2>/dev/null || echo "0")
    D_AGE_MINUTES=$(( (NOW_EPOCH_D - D_EPOCH) / 60 ))
    if [ "$D_AGE_MINUTES" -gt "$DISPATCHING_TTL_MINUTES" ]; then
      warn "Re-queuing zombie dispatching marker $D_ID (age=${D_AGE_MINUTES}m > TTL=${DISPATCHING_TTL_MINUTES}m — dispatcher died mid-run)"
      bd -C "$GC_CITY" label remove "$D_ID" "gate-status:dispatching" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$D_ID" "gate-status:queued"      -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$D_ID" "Dispatcher TTL recovery: marker was stuck in gate-status:dispatching for ${D_AGE_MINUTES}m (> ${DISPATCHING_TTL_MINUTES}m TTL). Dispatcher process died mid-run. Re-queuing for re-processing." 2>/dev/null || true
    fi
  done
fi

# ── Step 0a-2 (ga-zl277): reap orphaned gate-reviewer sessions ────────────────
# Backstop for the EXIT trap below: a dispatcher killed by SIGKILL/OOM/launchd
# timeout cannot run any trap, so its already-spawned reviewer sessions stay
# ASLEEP and never get closed. They consume the gate-reviewer template's
# max_active_sessions=6 budget; once full, runs spawn fewer than 3 reviewers and
# fail too — the ga-zl277 vicious cycle. Each sweep we close any gate-reviewer
# session that is NON-active, NON-attached, and older than the TTL.
#
# SAFE UNDER CONCURRENCY: launchd fires this dispatcher every ~2 min while a run
# can hold reviewers open for up to VERDICT_TIMEOUT_MINUTES, so sibling runs DO
# overlap. A live run closes its reviewers in Step 9 (before the merge) and the
# verdict poll caps the run at VERDICT_TIMEOUT_MINUTES, so any gate-reviewer
# older than verdict-timeout+margin cannot belong to a live sibling. We never
# touch an active or attached session.
#
# Pure decision (no IO, set -e safe) — mirrored + drift-guarded by
# gate-reviewer-orphan-reap.selftest.sh. echo "reap" iff the session is a
# NON-active, NON-attached gate-reviewer older than the TTL, else "keep".
reviewer_session_should_reap() {
  local state="$1" attached="$2" age="$3" ttl="$4"
  case "$age" in ''|*[!0-9]*) echo "keep"; return 0 ;; esac
  case "$ttl" in ''|*[!0-9]*) echo "keep"; return 0 ;; esac
  [ "$attached" = "true" ] && { echo "keep"; return 0; }
  [ "$state" = "active" ]  && { echo "keep"; return 0; }
  if [ "$age" -gt "$ttl" ]; then echo "reap"; else echo "keep"; fi
}

REVIEWER_SESSIONS_RAW=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo '{}')
REVIEWER_SESSIONS_JSON=$(echo "$REVIEWER_SESSIONS_RAW" \
  | jq -c '[.sessions[]? | select(.template=="gate-reviewer")]' 2>/dev/null || echo "[]")
REVIEWER_SESSION_COUNT=$(echo "$REVIEWER_SESSIONS_JSON" | jq 'length' 2>/dev/null || echo "0")
case "$REVIEWER_SESSION_COUNT" in ''|*[!0-9]*) REVIEWER_SESSION_COUNT=0 ;; esac

if [ "$REVIEWER_SESSION_COUNT" -gt 0 ]; then
  NOW_EPOCH_R=$(date +%s)
  REAPED_REVIEWERS=0
  for ri in $(seq 0 $((REVIEWER_SESSION_COUNT - 1))); do
    R_SESSION=$(echo "$REVIEWER_SESSIONS_JSON" | jq -c ".[$ri]" 2>/dev/null || echo "{}")
    R_ID=$(echo "$R_SESSION" | jq -r '.id // empty' 2>/dev/null || echo "")
    R_STATE=$(echo "$R_SESSION" | jq -r '.state // ""' 2>/dev/null || echo "")
    R_ATTACHED=$(echo "$R_SESSION" | jq -r '.attached // false' 2>/dev/null || echo "false")
    R_CREATED=$(echo "$R_SESSION" | jq -r '.created_at // ""' 2>/dev/null || echo "")
    [ -z "$R_ID" ] && continue
    [ -z "$R_CREATED" ] && continue
    # created_at is UTC ("...Z"). Parse the BSD branch with -u so the epoch is
    # absolute and matches `date +%s`; without -u, macOS `date -j -f` reads the
    # naive timestamp as LOCAL time and ages come out skewed by the UTC offset
    # (negative under UTC-3). GNU `date -d` keeps the trailing Z and is already
    # UTC-correct.
    R_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${R_CREATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$R_CREATED" +%s 2>/dev/null || echo "0")
    [ "$R_EPOCH" = "0" ] && continue
    R_AGE_MINUTES=$(( (NOW_EPOCH_R - R_EPOCH) / 60 ))
    if [ "$(reviewer_session_should_reap "$R_STATE" "$R_ATTACHED" "$R_AGE_MINUTES" "$REVIEWER_SESSION_TTL_MINUTES")" = "reap" ]; then
      warn "Reaping orphaned gate-reviewer session $R_ID (state=$R_STATE attached=$R_ATTACHED age=${R_AGE_MINUTES}m > TTL=${REVIEWER_SESSION_TTL_MINUTES}m — frees cap slot; ga-zl277)"
      gc --city "$GC_CITY" session close "$R_ID" 2>/dev/null || true
      REAPED_REVIEWERS=$((REAPED_REVIEWERS + 1))
    fi
  done
  if [ "$REAPED_REVIEWERS" -gt 0 ]; then
    log "Reaped $REAPED_REVIEWERS orphaned gate-reviewer session(s) this sweep (ga-zl277)."
  fi
fi

# ── Step 0a-3 (ga-rstw5): reconcile container-rig bare mains to origin ─────────
# Container rigs (.repo.git) keep a LOCAL refs/heads/<main> that a push to origin
# never advances; when it drifts/forks from origin/<main> the durable-landing step
# used to false-FAIL an all-PASS verdict (failed_durable_not_ff) and mail crew a
# spurious FAIL (ga-rstw5). do_merge_ff now reconciles the rig it merges, but this
# startup sweep additionally keeps EVERY container rig's bare main tracking origin
# each sweep, healing a stale/forked mirror BEFORE any branch reaches the guard
# (AC: bare main of every container rig tracks origin/main after a gate run).
# Cheap + idempotent: a single-ref fetch + ancestry check; only a forked ref is
# rewritten (to origin; forked tip backed up first). Silent on the common no-op so
# it does not spam the log every ~2 min.
RECON_RIG_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo '{}')
RECON_RIG_COUNT=$(echo "$RECON_RIG_JSON" | jq '.rigs | length' 2>/dev/null || echo "0")
case "$RECON_RIG_COUNT" in ''|*[!0-9]*) RECON_RIG_COUNT=0 ;; esac
if [ "$RECON_RIG_COUNT" -gt 0 ]; then
  for rci in $(seq 0 $((RECON_RIG_COUNT - 1))); do
    RC_PATH=$(echo "$RECON_RIG_JSON"   | jq -r ".rigs[$rci].path // \"\""               2>/dev/null || echo "")
    RC_BRANCH=$(echo "$RECON_RIG_JSON" | jq -r ".rigs[$rci].default_branch // \"main\"" 2>/dev/null || echo "main")
    RC_NAME=$(echo "$RECON_RIG_JSON"   | jq -r ".rigs[$rci].name // \"?\""              2>/dev/null || echo "?")
    [ -z "$RC_PATH" ] && continue
    # Only container rigs have a bare .repo.git mirror that can drift; self-repo
    # rigs (wa, gascity, marketing) read origin directly and are unaffected.
    [ -d "$RC_PATH/.repo.git" ] || continue
    RC_OUT=""
    RC_RC=0
    RC_OUT=$(reconcile_bare_main_to_origin "$RC_PATH/.repo.git" "$RC_BRANCH") || RC_RC=$?
    if [ "$RC_RC" != "0" ]; then
      warn "Startup reconcile: rig $RC_NAME bare $RC_BRANCH FAILED ($RC_OUT) — continuing"
    else
      case "$RC_OUT" in
        noop:*) : ;;  # already tracking origin — silent
        *) log "Startup reconcile: rig $RC_NAME bare $RC_BRANCH → origin ($RC_OUT)" ;;
      esac
    fi
  done
fi

# ── Step 0b: Find a queued marker ────────────────────────────────────────────
# quality-gate-guard.sh claims, validates, derives author, and parks markers as
# gate-status:queued.  We only process queued markers — the guard already did
# all the security work.

MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:queued \
  2>/dev/null || echo "[]")

COUNT=$(printf '%s\n' "$MARKERS_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT queued marker(s)"

if [ "$COUNT" = "0" ]; then
  log "No queued markers. Exiting."
  exit 0
fi

# FIFO: oldest-first so no queued marker starves (ga-zf61i). bd list returns
# newest-first; bare .[0] always grabbed the NEWEST → with ~1 marker/sweep
# throughput, older markers (e.g. iz4a96/ga-mr8ym, + 2-day-old pddg18/pqzl9h)
# starved indefinitely as newer ones jumped the line. sort_by(created_at) drains
# the queue in arrival order. (Throughput / parallel dispatch = Phase 2, separate.)
#
# ga-q3ig2 HEAD-OF-LINE FIX: a marker whose branch is stale-with-conflict and
# whose author is dead/transient gets re-queued — here (dead-author bounded
# retry re-adds gate-status:queued), by gate-health-monitor, or by a manual
# re-anchor that resets the gate:rebase-attempt counter. Because the broken
# marker keeps the OLDEST created_at, a pure FIFO sort re-selects it EVERY
# sweep, fails the same rebase, and never reaches the N healthy markers behind
# it ("o FIFO insiste nele"). Result: 2× outages 2026-06-10 (~16:30, ~18:03-18:52
# = 49min) where one broken branch travou a fila INTEIRA (18 markers), zero
# merges until manual intervention.
#
# Fix: two-tier ordering. Markers with NO prior auto-rebase failure are drained
# first (FIFO by created_at). Markers that already failed an auto-rebase (they
# carry a gate:rebase-attempt:N label) sink to the BACK and are only re-attempted
# when no healthy marker is queued. One broken branch can no longer travar a fila
# regardless of who re-queues it — the queue drains the healthy markers while the
# broken one is "tratado à parte" (escalated to needs-rebase by its own bounded
# retry / gate-health-monitor). Star-guide: gate never idles >15min on 1 stale branch.
MARKER=$(printf '%s\n' "$MARKERS_JSON" | jq '
  def has_rebase_fail: ((.labels // []) | map(select(test("^gate:rebase-attempt:[0-9]+$"))) | length) > 0;
  sort_by(.created_at)
  | (map(select(has_rebase_fail | not)) + map(select(has_rebase_fail)))
  | .[0]')
MARKER_ID=$(printf '%s\n' "$MARKER" | jq -r '.id')
DESC=$(printf '%s\n' "$MARKER" | jq -r '.description // ""')

log "Attempting to claim marker $MARKER_ID ..."

# ── Step 1: Atomic claim — transition queued → dispatching ───────────────────
# Remove queued label first. If another dispatcher process beat us, the re-fetch
# will show the marker no longer in queued state.

bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:queued" -q 2>/dev/null || true

# Re-fetch to verify we won the race
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null || echo "[]")
VERIFY_LABELS=$(echo "$VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$VERIFY_LABELS" | grep -q "gate-status:dispatching"; then
  log "Marker $MARKER_ID already dispatching by another process. Skipping."
  exit 0
fi
if echo "$VERIFY_LABELS" | grep -q "gate-status:queued"; then
  log "Marker $MARKER_ID still queued after removal (race condition). Skipping."
  exit 0
fi

# We own it — add dispatching label
bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || {
  err "Failed to add gate-status:dispatching to $MARKER_ID. Aborting."
  exit 1
}

log "Marker $MARKER_ID claimed for dispatching."

# ── Step 2: Extract fields from marker description ────────────────────────────

extract() { echo "$DESC" | grep -E "^$1:" | head -1 | sed "s/^$1: *//"; }

BRANCH=$(extract "branch")
BEAD_ID=$(extract "bead_id")
BASE_COMMIT=$(extract "base_commit")
RIG=$(extract "rig")

log "  branch=$BRANCH  bead_id=$BEAD_ID  rig=${RIG:-unknown}"

# ── Step 3: Re-derive author authoritatively (never trust marker self-declaration)
#
# Resolution order (most-to-least authoritative):
#   1. Look up the bead via "gc bd show" (cross-rig lookup — works for any rig DB).
#   2. Try HQ DB directly as a fallback (in case gc bd fails).
#   3. If assignee is a session-id (contains "adhoc"), map it back to the base
#      crew role by stripping the adhoc suffix (e.g. "digo-wa-adhoc-e2510107f6" → "digo-wa").
#
# SECURITY: We do NOT trust the marker's self-declared author. The resolved value
# is used solely for self-review exclusion. A partial/approximate match is safe
# here: it only prevents a reviewer from reviewing their own work; it doesn't
# grant access.

AUTHOR=""

# bead_field_grep <raw_json_text> <field_name>
# Extracts a simple string field from potentially-malformed JSON output.
# Uses grep/sed instead of jq because gc bd output may contain literal newlines
# embedded in string values (invalid JSON per RFC7159) that cause jq 1.8.1+ to fail.
bead_field_grep() {
  local raw="$1" field="$2"
  # The || true prevents pipefail from aborting when grep finds no match (exits 1).
  echo "$raw" | grep -o "\"${field}\": *\"[^\"]*\"" \
    | sed "s/\"${field}\": *\"\(.*\)\"/\1/" \
    | head -1 || true
}

if [ -n "$BEAD_ID" ]; then
  # 1. Cross-rig lookup via gc bd (authoritative — queries the owning rig's DB).
  #    This handles beads in rig DBs (e.g. wa-*, ps-*) that are NOT in the HQ DB.
  BEAD_RAW=$(gc --city "$GC_CITY" bd show "$BEAD_ID" --json 2>/dev/null || echo "")

  # If cross-rig lookup returned nothing, fall back to HQ DB
  if [ -z "$BEAD_RAW" ]; then
    log "  gc bd cross-rig lookup returned empty; trying HQ DB directly."
    BEAD_RAW=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null || echo "")
  fi

  # Extract fields using grep (robust to embedded-newline JSON from gc bd)
  AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "created_by")
  fi
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "owner")
  fi
fi

# 3. Session-id normalization: if assignee looks like an adhoc session-id
#    (e.g. "digo-adhoc-e2510107f6"), strip the adhoc suffix to get the crew role.
#    We keep the FULL id as the exclusion target AND the normalized role — a
#    reviewer session matches if its alias contains either form.
if [ -n "$AUTHOR" ] && echo "$AUTHOR" | grep -qE "-adhoc-[0-9a-f]+" 2>/dev/null; then
  AUTHOR_BASE=$(echo "$AUTHOR" | sed 's/-adhoc-[0-9a-f]*$//')
  log "  Author '$AUTHOR' looks like a session-id; normalized to base role '$AUTHOR_BASE'."
  AUTHOR="$AUTHOR_BASE"
fi

if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
  err "Cannot derive author authoritatively for bead $BEAD_ID — aborting (fail-safe)."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred"    -q 2>/dev/null || true
  # wa-uthi: non-terminal (deferred) — no push to Athos. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): author unresolvable for $MARKER_ID — deferred."
  exit 0
fi

log "Authoritative author: $AUTHOR"

# ── Step 4: Determine rig path and git references ─────────────────────────────

RIG_PATH=""
RIG_LIST_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo '{}')
if [ -n "$RIG" ]; then
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
fi

# ga-67hae: COMPOUND rig fallback — /gate-done writes rig=mila-wa or rig=batista-ps
# (crew-qualified). No rig has that compound name → bead-id prefix is authoritative
# (wa-ucrq → wa → whatsapp_automation; ps-s27l → ps → property_scrapers).
if { [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; } && [ -n "$BEAD_ID" ]; then
  _bid_prefix="${BEAD_ID%%-*}"
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$_bid_prefix" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
  [ -n "$RIG_PATH" ] && log "  rig='$RIG' unresolved; derived from bead-id prefix '$_bid_prefix' -> $RIG_PATH"
fi
# Trailing-segment fallback: mila-wa → wa
if { [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; } && [ -n "$RIG" ] && printf '%s' "$RIG" | grep -q '-'; then
  _rig_tail="${RIG##*-}"
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$_rig_tail" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
  [ -n "$RIG_PATH" ] && log "  rig='$RIG' unresolved; derived from trailing segment '$_rig_tail' -> $RIG_PATH"
fi

if [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; then
  err "Cannot resolve rig path for rig='$RIG' (bead=$BEAD_ID). Aborting."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  exit 1
fi

# ga-67hae: normalize $RIG to the canonical rig name (compound values break
# downstream select(.name == $RIG) lookups like DEFAULT_BRANCH derivation).
_RIG_CANON=$(echo "$RIG_LIST_JSON" | jq -r --arg p "$RIG_PATH" '.rigs[] | select(.path == $p) | .name' 2>/dev/null | head -1 || echo "")
if [ -n "$_RIG_CANON" ] && [ "$_RIG_CANON" != "$RIG" ]; then
  log "  Normalized rig '$RIG' -> canonical '$_RIG_CANON' for downstream lookups."
  RIG="$_RIG_CANON"
fi

# wa-re77: source-bead (BEAD_ID) lives in the RIG's own Dolt DB, not HQ.
# Use BEAD_CITY for all bd ops on $BEAD_ID; keep GC_CITY for marker/gate-run/verdict ops.
#
# ── ga-qw7y6: resolve the store that ACTUALLY contains the source bead ─────────
# BEAD_CITY="${RIG_PATH:-$GC_CITY}" alone is WRONG when an HQ-resident `ga-` bead
# is built on a RIG branch (e.g. an HQ painel story built on whatsapp_automation's
# crew branch — see painel-lives-in-wa-rig). There the marker carries
# rig=whatsapp_automation, so RIG_PATH resolves to the rig store, but the source
# bead lives in the HQ city store. The PASS-merge close (`bd -C "$BEAD_CITY"
# close`) and the ga-esbg post-merge verification then target the rig store,
# can't find the HQ bead, and silently no-op — the source bead stays open, the
# verification reports "absent" (false OK), and Pilot phantom-re-dispatches the
# already-merged work (ga-8tv0s re-dispatched 3×: a direct slot/cycle leak).
# Conversely, wa-re77 rig-native beads DO live in the rig store. The owning store
# is therefore NOT derivable from RIG_PATH alone — probe which store resolves it.
#
# resolve_bead_city <bead-id> — echo the store dir whose Dolt DB owns <bead-id>.
# Probes RIG_PATH first (preserve wa-re77 rig-native behavior), then GC_CITY (HQ).
# A store "owns" the bead iff `bd -C <store> show <bead> --json` yields a record
# with a non-empty .status; a not-found probe returns {"error":...} (no .status →
# empty → skip). Falls back to a bead-id prefix heuristic (ga-* → HQ) only when
# NEITHER store resolves (e.g. transient Dolt hiccup), so the close still targets
# the most-likely-correct store rather than blindly trusting RIG_PATH.
resolve_bead_city() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    st=$(bd -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  # Neither store resolved (transient Dolt issue): prefix heuristic. The HQ city
  # prefix is `ga` (gascity); every other prefix is a rig.
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}
BEAD_CITY="$(resolve_bead_city "$BEAD_ID")"
if [ "$BEAD_CITY" != "${RIG_PATH:-$GC_CITY}" ]; then
  log "  ga-qw7y6: source bead $BEAD_ID resolves to store $BEAD_CITY (NOT rig store ${RIG_PATH:-$GC_CITY}) — cross-store close corrected."
fi

# Determine the canonical git repo location.
# Container rigs (property_scrapers, lexbh) have a bare .repo.git.
# Self-repo rigs (gastown, whatsapp_automation, marketing) have .git in root.
if [ -d "$RIG_PATH/.repo.git" ]; then
  GIT_DIR_PATH="$RIG_PATH/.repo.git"
  IS_CONTAINER_RIG=1
else
  GIT_DIR_PATH="$RIG_PATH"
  IS_CONTAINER_RIG=0
fi

# git_rig — wrapper that calls git with the correct rig-specific flags.
# Usage: git_rig <args...>
git_rig() {
  if [ "$IS_CONTAINER_RIG" = "1" ]; then
    git --git-dir="$GIT_DIR_PATH" "$@"
  else
    git -C "$GIT_DIR_PATH" "$@"
  fi
}

# ── ga-ljbx: hardened ref resolution (defense-in-depth) ───────────────────────
# rig_resolve_commit <ref> — resolve <ref> to a real COMMIT object SHA.
#
# Plain `git rev-parse origin/main` returns whatever 40-hex string the ref file
# holds, EVEN IF that object is missing from the object DB (e.g. a ref left
# dangling by a racing/aborted fetch or a competing reconciler). That garbage SHA
# then poisons every downstream merge-base/merge-tree computation: merge-base
# returns empty ("no common ancestor"), the branch is misclassified as having
# unrelated histories, and a perfectly clean stale branch is bounced to
# needs-rebase with a non-existent main_sha (observed live on ga-tmug:
# main_sha=7b03eb9a… / e7949128…, neither of which exists in the repo).
#
# `git rev-parse --verify -q <ref>^{commit}` forces the ref to dereference to a
# real, present commit object. On a missing/garbage object it prints NOTHING and
# returns nonzero — callers can then distinguish "ref points at garbage" (→ treat
# as a transient/re-triable error, gate-status:error) from "clean stale branch"
# (→ auto-rebase). Output is empty on failure so `[ -z "$X" ]` guards trip.
rig_resolve_commit() {
  git_rig rev-parse --verify -q "$1^{commit}" 2>/dev/null || echo ""
}

# ── ga-ljbx: git-2.54 conflict detection ──────────────────────────────────────
# rig_merge_has_conflict <main_ref> <branch_ref> — echo "1" if merging
# <branch_ref> into <main_ref> conflicts, "0" if clean, "err" if undeterminable.
#
# The legacy 3-arg form `git merge-tree <base> <ours> <theirs>` + grep '^<<<<<<<'
# is BROKEN on git 2.54: the conflict markers in that output are diff-prefixed
# (" +<<<<<<<"), so the anchored grep never matches and a real conflict reads as
# clean (verified empirically on git 2.54.0). The modern
# `git merge-tree --write-tree <main> <branch>` is authoritative: exit 0 = clean,
# exit 1 = conflict, exit >1 = error (e.g. unrelated histories / bad ref).
rig_merge_has_conflict() {
  local main_ref="$1" branch_ref="$2"
  git_rig merge-tree --write-tree "$main_ref" "$branch_ref" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "0" ]; then
    echo "0"
  elif [ "$rc" = "1" ]; then
    echo "1"
  else
    echo "err"
  fi
}

log "  rig_path=$RIG_PATH  git_dir=$GIT_DIR_PATH  container_rig=$IS_CONTAINER_RIG"

# Determine default branch (main unless overridden)
DEFAULT_BRANCH=$(echo "$RIG_LIST_JSON" \
  | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .default_branch // "main"' 2>/dev/null | head -1 || echo "main")

# Fetch to ensure we have the latest remote state
log "Fetching remote for rig $RIG ..."
git_rig fetch origin 2>/dev/null || warn "git fetch failed (continuing with stale refs)"

# Verify branch exists on remote (ga-ljbx: hardened — a ref pointing at a missing
# object yields EMPTY here, so we fail to gate-status:error, never proceed on garbage)
BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH")
if [ -z "$BRANCH_SHA" ]; then
  err "Branch '$BRANCH' not found on remote origin (or ref points at a missing object). Aborting."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  # wa-uthi: non-terminal (marker error, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH not found on remote — gate-status:error."
  exit 1
fi

log "  branch_sha=$BRANCH_SHA"

# ── Step 4b: Already-merged detection ────────────────────────────────────────
# If the branch tip is already an ancestor of the rig's default branch, the
# work has already been merged.  Re-spawning reviewers on merged work wastes
# sessions and produces duplicate gate-failed/passed noise.
# DETECT: if merge-base --is-ancestor origin/$BRANCH origin/$DEFAULT_BRANCH → true
# → mark marker gate-status:done/superseded and exit cleanly.

ALREADY_MERGED=0
if git_rig merge-base --is-ancestor "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
  ALREADY_MERGED=1
fi

if [ "$ALREADY_MERGED" = "1" ]; then
  log "Branch $BRANCH is already merged into $DEFAULT_BRANCH — superseding marker $MARKER_ID."
  set_gate_status "$MARKER_ID" "superseded"
  bd -C "$GC_CITY" comment "$MARKER_ID" "Branch $BRANCH is already merged into $DEFAULT_BRANCH (SHA $BRANCH_SHA is ancestor of main). Gate skipped — no reviewers needed." 2>/dev/null || true
  # ga-jhyu: CLOSE the marker at terminal (superseded) so it is reaped, not left OPEN.
  bd -C "$GC_CITY" close "$MARKER_ID" -r "Gate marker terminal: SUPERSEDED (branch $BRANCH already merged to $DEFAULT_BRANCH). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true

  # Also close the source bead cleanly if open
  if [ -n "$BEAD_ID" ]; then
    BD_STATUS=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | .status // "open"')
    if [ "$BD_STATUS" != "closed" ]; then
      bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:superseded" -q 2>/dev/null || true
      # ga-67hae PILOT-CASCADE FIX: branch already merged → strip story:in-flight so
      # the Pilot lane slot frees. The PASS path strips it at merge (ga-3h8l) but this
      # supersede path did not — phantom in-flight slots wedged the Pilot at capacity.
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" assign "$BEAD_ID" "" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "Branch $BRANCH already in $DEFAULT_BRANCH — gate superseded (marker $MARKER_ID). story:in-flight stripped (Pilot lane slot freed — ga-67hae pilot-cascade fix); work already merged." 2>/dev/null || true
    fi
  fi

  # Log and exit without error
  mkdir -p "$(dirname "$QG_LOG")"
  jq -c -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$BRANCH" \
    --arg bead "$BEAD_ID" \
    --arg rig "${RIG:-unknown}" \
    --arg marker "$MARKER_ID" \
    '{ts: $ts, event: "dispatcher_superseded", branch: $branch, bead: $bead, rig: $rig, marker: $marker, reason: "already_merged"}' \
    >> "$QG_LOG" 2>/dev/null || true

  # wa-uthi: non-terminal (marker superseded — no new outcome) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH already merged — gate marker superseded."
  log "=== Dispatcher sweep complete: branch=$BRANCH verdict=SUPERSEDED (already merged) ==="
  exit 0
fi

log "  Branch $BRANCH not yet merged into $DEFAULT_BRANCH — proceeding with review."

# ── Step 4c: Stale-base check (Bug 1a) ───────────────────────────────────────
# Require that the branch be CURRENT with main before review starts.
# A branch is current iff main HEAD is an ancestor of the branch tip — i.e.
# the branch was forked from (or rebased onto) the current main tip.
#
# If main has moved ahead of the branch base, a merge-tree pre-check can still
# silently resolve conflicts to main's side (as happened with wa-e99e / 52ba4c95).
# We refuse to proceed and bounce back to the author with gate-status:needs-rebase.

# ga-ljbx: hardened — resolve main to a REAL commit object. If the ref points at a
# missing/garbage object (racing fetch, competing reconciler), we MUST NOT proceed:
# every downstream merge-base/merge-tree would silently misclassify a clean branch
# as "no common ancestor" and strand it on needs-rebase (root cause of the ga-tmug
# bounce: main_sha 7b03eb9a…/e7949128… never existed in the repo). Instead, set
# gate-status:error (re-triable on the next sweep once the ref settles) and exit.
MAIN_HEAD_SHA=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
if [ -z "$MAIN_HEAD_SHA" ]; then
  err "Cannot resolve origin/$DEFAULT_BRANCH to a real commit (dangling/garbage ref). Marking gate-status:error for retry."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$MARKER_ID" "Gate transient error: origin/$DEFAULT_BRANCH did not resolve to a present commit object (likely a racing fetch). NOT a conflict — will retry on next sweep." 2>/dev/null || true
  log "SUPPRESSED PUSH (wa-uthi non-terminal): origin/$DEFAULT_BRANCH unresolvable — gate-status:error (retriable)."
  exit 1
fi
BRANCH_IS_CURRENT=0
# main is an ancestor of branch iff the branch includes all of main
if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
  BRANCH_IS_CURRENT=1
fi

if [ "$BRANCH_IS_CURRENT" != "1" ]; then
  # ── ga-we1: Auto-rebase (clean branches only) ─────────────────────────────
  # Instead of bouncing to the author, the dispatcher attempts a conflict-free
  # rebase directly.  This eliminates the starvation loop where a branch passes
  # the stale check, enters review, main moves again during review→merge, and
  # the whole cycle restarts.
  #
  # Strategy:
  #   1. Use `git merge-tree` to detect conflicts before touching anything.
  #   2. If conflict-free: create a temp worktree, rebase onto current main,
  #      push the rebased branch tip, update BRANCH_SHA, and continue.
  #   3. If conflicts: bounce to author with a targeted conflict report (not
  #      a generic "rebase and re-run" — we know exactly which files conflict).

  log "  Branch $BRANCH is STALE (main=$MAIN_HEAD_SHA not in branch=$BRANCH_SHA). Attempting auto-rebase ..."

  # ga-ljbx: deterministic conflict detection (git 2.54). The legacy
  # `merge-tree <base> <ours> <theirs>` + grep '^<<<<<<<' read EVERY real conflict
  # as clean on git 2.54 (markers are diff-indented), so genuine conflicts slipped
  # into the rebase and a transient empty merge-base was mislabeled "no common
  # ancestor" → forced conflict → strand. We now use --write-tree exit codes.
  HAS_CONFLICT=0
  CONFLICT_FILES=""
  # ga-q3ig2: classify WHY a branch can't fast-forward so the dead-author handler
  # can decide whether a server-side retry is worthwhile. "merge" = a genuine,
  # deterministic merge conflict vs current main (re-running the rebase yields the
  # same result; a dead author cannot resolve it → skip retries, escalate at once).
  # "transient" = auto-rebase worktree/push plumbing failure (main may settle →
  # bounded retry still makes sense).
  CONFLICT_KIND=""
  MERGE_BASE_SHA=$(git_rig merge-base "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
  MT_VERDICT=$(rig_merge_has_conflict "origin/$DEFAULT_BRANCH" "origin/$BRANCH")

  if [ "$MT_VERDICT" = "err" ]; then
    # Undeterminable (unrelated histories OR a ref still settling). Do NOT bounce to
    # needs-rebase — that strands a possibly-clean branch on a dead author. Mark
    # gate-status:error so the next sweep re-attempts once refs settle.
    err "  Conflict pre-check undeterminable for $BRANCH (merge-tree err; base=${MERGE_BASE_SHA:-none}). Marking gate-status:error for retry."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$MARKER_ID" "Gate transient error: merge-tree conflict pre-check for $BRANCH vs $DEFAULT_BRANCH was undeterminable (merge-base=${MERGE_BASE_SHA:-none}). NOT necessarily a conflict — will retry on next sweep." 2>/dev/null || true
    log "SUPPRESSED PUSH (wa-uthi non-terminal): merge-tree undeterminable for $BRANCH — gate-status:error (retriable)."
    exit 1
  elif [ "$MT_VERDICT" = "1" ]; then
    HAS_CONFLICT=1
    CONFLICT_KIND="merge"   # ga-q3ig2: genuine, deterministic merge conflict.
    # Capture conflicting file names from the structured --write-tree conflict block.
    # The trailing `|| true` is REQUIRED: merge-tree --write-tree returns rc=1 on a
    # conflict, and under `set -euo pipefail` (line 30) `pipefail` propagates that
    # non-zero through the pipe, so the bare `CONFLICT_FILES=$(...)` assignment would
    # trip `set -e` and SILENTLY kill the dispatcher mid-conflict-handling — head-of-
    # line-blocking the whole gate on the first conflicting branch (ga-mzc3h follow-up).
    CONFLICT_FILES=$(git_rig merge-tree --write-tree --name-only "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null \
      | tail -n +2 | head -5 | tr '\n' ' ' | cut -c1-300 || true)
    [ -z "$CONFLICT_FILES" ] && CONFLICT_FILES="merge conflict (files unavailable)"
  fi

  if [ "$HAS_CONFLICT" = "0" ]; then
    # Clean rebase: perform in a temp worktree, push to origin, continue with review.
    log "  Auto-rebase: no conflicts detected — rebasing $BRANCH onto $MAIN_HEAD_SHA ..."
    AUTO_REBASE_OK=0
    TMP_REBASE_WT="/tmp/gc-gate-autorebase-$$"

    if [ "$IS_CONTAINER_RIG" = "1" ]; then
      # Container rig (bare repo): worktree uses the bare .repo.git
      if git_rig worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>/dev/null; then
        # Configure git user inside worktree for the rebase commit
        git -C "$TMP_REBASE_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
        git -C "$TMP_REBASE_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
        if git -C "$TMP_REBASE_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
          if [ -n "$NEW_TIP" ] && git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
            AUTO_REBASE_OK=1
            BRANCH_SHA="$NEW_TIP"
            log "  Auto-rebase success: $BRANCH pushed to $NEW_TIP (rebased onto $MAIN_HEAD_SHA)"
            bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-rebased $BRANCH onto main ($MAIN_HEAD_SHA). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
            # Re-verify stale check passes now
            git_rig fetch origin 2>/dev/null || true
            BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH"); [ -z "$BRANCH_SHA" ] && BRANCH_SHA="$NEW_TIP"
            if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
              BRANCH_IS_CURRENT=1
            else
              warn "  Post-auto-rebase stale check still fails — falling through to bounce."
              AUTO_REBASE_OK=0
            fi
          else
            warn "  Auto-rebase push failed for $BRANCH"
          fi
        else
          warn "  Auto-rebase git rebase command failed (unexpected — merge-tree reported no conflicts)"
          git -C "$TMP_REBASE_WT" rebase --abort 2>/dev/null || true
        fi
        git_rig worktree remove "$TMP_REBASE_WT" --force 2>/dev/null || true
      else
        warn "  Could not create auto-rebase worktree at $TMP_REBASE_WT"
      fi
    else
      # Self-repo rig
      if git -C "$GIT_DIR_PATH" worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>/dev/null; then
        git -C "$TMP_REBASE_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
        git -C "$TMP_REBASE_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
        if git -C "$TMP_REBASE_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
          if [ -n "$NEW_TIP" ] && git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
            AUTO_REBASE_OK=1
            BRANCH_SHA="$NEW_TIP"
            log "  Auto-rebase success (self-repo): $BRANCH pushed to $NEW_TIP"
            bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-rebased $BRANCH onto main ($MAIN_HEAD_SHA). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
            git_rig fetch origin 2>/dev/null || true
            BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH"); [ -z "$BRANCH_SHA" ] && BRANCH_SHA="$NEW_TIP"
            if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
              BRANCH_IS_CURRENT=1
            else
              warn "  Post-auto-rebase stale check still fails — falling through to bounce."
              AUTO_REBASE_OK=0
            fi
          else
            warn "  Auto-rebase push failed (self-repo) for $BRANCH"
          fi
        else
          warn "  Auto-rebase git rebase failed (self-repo)"
          git -C "$TMP_REBASE_WT" rebase --abort 2>/dev/null || true
        fi
        git -C "$GIT_DIR_PATH" worktree remove "$TMP_REBASE_WT" --force 2>/dev/null || true
      else
        warn "  Could not create auto-rebase worktree (self-repo) at $TMP_REBASE_WT"
      fi
    fi

    if [ "$AUTO_REBASE_OK" = "1" ] && [ "$BRANCH_IS_CURRENT" = "1" ]; then
      log "  Auto-rebase complete — branch is now current. Continuing with review."
      # Fall through to Step 5 with updated BRANCH_SHA
    else
      # Auto-rebase failed despite no conflicts (worktree/push failure)
      HAS_CONFLICT=1
      CONFLICT_KIND="transient"   # ga-q3ig2: plumbing failure, not a real conflict — retry is worthwhile.
      CONFLICT_FILES="auto-rebase failed (worktree/push error)"
    fi
  fi

  if [ "$BRANCH_IS_CURRENT" != "1" ]; then
    # ── ga-ljbx: never-strand bounce ──────────────────────────────────────────
    # GENUINE conflict (or auto-rebase worktree/push failure). The old behavior
    # bounced to needs-rebase + nudged the author. For framework self-fixes the
    # author is a drained/transient pool dog (AUTHOR empty OR no live session), so
    # the nudge hit nothing and the bead stranded forever, re-firing needs_rebase
    # on every re-pick. We now:
    #   1. Decide if the author is reachable (non-empty AND a live session exists).
    #   2. If reachable: bounce + nudge as before (author can fix conflicts).
    #   3. If NOT reachable: track a bounded gate:rebase-attempt:N counter on the
    #      marker. Below MAX → mark gate-status:error (the next sweep re-attempts
    #      the auto-rebase; main may have settled / a transient may clear). At/above
    #      MAX → escalate to the Mayor via mail (durable) and mark needs-rebase, so
    #      a human-or-Mayor-driven resolution happens — but we NEVER silently strand.
    MAX_REBASE_ATTEMPTS=3

    AUTHOR_ALIVE=0
    if [ -n "$AUTHOR" ]; then
      if gc --city "$GC_CITY" session list --json 2>/dev/null \
           | jq -e --arg a "$AUTHOR" 'if type=="array" then . else (.sessions // []) end
                 | map(select((.alias==$a) or (.name==$a) or (.agent==$a))) | length > 0' >/dev/null 2>&1; then
        AUTHOR_ALIVE=1
      fi
    fi

    # Read current rebase-attempt counter from the marker labels.
    REBASE_ATTEMPT=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[]' 2>/dev/null \
      | sed -n 's/^gate:rebase-attempt:\([0-9]\+\)$/\1/p' | sort -rn | head -1)
    [ -z "$REBASE_ATTEMPT" ] && REBASE_ATTEMPT=0

    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true

    if [ "$AUTHOR_ALIVE" = "1" ]; then
      # Author can resolve — bounce + nudge (legacy path).
      warn "Branch $BRANCH: genuine conflict (${CONFLICT_FILES:-conflicts}); author $AUTHOR is live — bouncing for manual rebase."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$MARKER_ID" "Gate BLOCKED: branch $BRANCH is stale and has conflicts that prevent auto-rebase.
main HEAD is $MAIN_HEAD_SHA. Conflicting regions: ${CONFLICT_FILES:-unknown}.
Action required: manually rebase $BRANCH onto current origin/$DEFAULT_BRANCH, resolve conflicts, and re-run /gate-done." 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add  "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Quality gate blocked: branch $BRANCH has conflicts with current main ($MAIN_HEAD_SHA). Auto-rebase failed (${CONFLICT_FILES:-conflicts}). Manual rebase required — re-run /gate-done after resolving." 2>/dev/null || true
      fi
      gc --city "$GC_CITY" session nudge "$AUTHOR" \
        "GATE BLOCKED for branch $BRANCH: stale with conflicts — auto-rebase failed. Conflicts: ${CONFLICT_FILES:-unknown}. Manually rebase onto origin/$DEFAULT_BRANCH (main HEAD: $MAIN_HEAD_SHA), resolve conflicts, re-run /gate-done. Bead: $BEAD_ID" \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR for rebase"
      REBASE_EVENT="dispatcher_needs_rebase"
      REBASE_VERDICT="NEEDS_REBASE (conflicts, author live, bounced)"
    elif [ "$CONFLICT_KIND" = "merge" ]; then
      # ga-q3ig2 IDEAL SKIP: a GENUINE merge conflict vs current main is
      # deterministic — re-running the same rebase next sweep produces the same
      # conflict, and the author session is gone so no one will resolve it. The
      # old bounded-retry path (below) burned MAX_REBASE_ATTEMPTS sweeps re-failing
      # before escalating; with the broken marker keeping the oldest created_at it
      # also head-of-line-blocked the queue. Go STRAIGHT to needs-rebase + escalate
      # so the marker leaves the active queue on its FIRST determination and the
      # gate-health-monitor / a fresh re-dispatch can re-anchor or rebuild it.
      err "Branch $BRANCH: genuine merge conflict vs $DEFAULT_BRANCH, author dead/empty — immediate needs-rebase (no retry; conflict is deterministic)."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$MARKER_ID" "Gate SKIPPED + ESCALATED (ga-q3ig2): branch $BRANCH has a genuine, deterministic merge conflict (${CONFLICT_FILES:-unknown}) vs main ($MAIN_HEAD_SHA) and no live author session exists. A server-side rebase retry would fail identically, so the marker is parked at needs-rebase immediately (NOT re-queued) — it no longer blocks the queue. Needs re-anchor/rebuild or a Mayor decision." 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
      fi
      gc --city "$GC_CITY" mail send mayor \
        -s "Gate escalation: $BRANCH genuine conflict (no live author)" \
        -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) has a genuine, deterministic conflict vs origin/$DEFAULT_BRANCH ($MAIN_HEAD_SHA). Conflicting: ${CONFLICT_FILES:-unknown}. Author session is gone — gate cannot self-heal, and a rebase retry would fail identically. Parked at needs-rebase (not blocking the queue). Needs a manual re-anchor/rebuild or a decision." 2>/dev/null \
        || warn "Could not mail Mayor for gate escalation on $BRANCH"
      REBASE_EVENT="dispatcher_needs_rebase_immediate"
      REBASE_VERDICT="NEEDS_REBASE (genuine conflict, dead author — immediate skip)"
    else
      # Dead/empty author + TRANSIENT auto-rebase failure (worktree/push plumbing).
      # main may settle on a later sweep, so a bounded server-side retry is worth
      # it; then escalate. (Genuine merge conflicts take the immediate-skip branch
      # above — they never reach here.)
      NEXT_ATTEMPT=$((REBASE_ATTEMPT + 1))
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:rebase-attempt:$REBASE_ATTEMPT" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$MARKER_ID" "gate:rebase-attempt:$NEXT_ATTEMPT"  -q 2>/dev/null || true
      if [ "$NEXT_ATTEMPT" -lt "$MAX_REBASE_ATTEMPTS" ]; then
        warn "Branch $BRANCH: transient auto-rebase-fail, author dead/empty (attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS) — gate-status:queued for server-side retry."
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:queued" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$MARKER_ID" "Gate auto-retry $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS: branch $BRANCH hit a transient auto-rebase failure (${CONFLICT_FILES:-plumbing}) and the author session is gone. Queued for server-side retry on next sweep (NOT stranded on a dead author). Carries gate:rebase-attempt:$NEXT_ATTEMPT so it sinks behind healthy markers (ga-q3ig2)." 2>/dev/null || true
        REBASE_EVENT="dispatcher_autorebase_retry"
        REBASE_VERDICT="QUEUED (retry $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS, dead author)"
      else
        err "Branch $BRANCH: transient auto-rebase failure persists after $MAX_REBASE_ATTEMPTS server-side attempts, author dead/empty — escalating to Mayor."
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$MARKER_ID" "Gate ESCALATED: branch $BRANCH could not auto-rebase (${CONFLICT_FILES:-unknown}) vs main ($MAIN_HEAD_SHA) after $MAX_REBASE_ATTEMPTS attempts, and no live author session exists. Escalated to Mayor for resolution." 2>/dev/null || true
        if [ -n "$BEAD_ID" ]; then
          bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
        fi
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate escalation: $BRANCH stranded conflict (no live author)" \
          -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) could not auto-rebase vs origin/$DEFAULT_BRANCH ($MAIN_HEAD_SHA). ${CONFLICT_FILES:-unknown}. Auto-rebase failed $MAX_REBASE_ATTEMPTS times and the author session is gone — gate cannot self-heal. Needs a manual rebase or a decision." 2>/dev/null \
          || warn "Could not mail Mayor for gate escalation on $BRANCH"
        REBASE_EVENT="dispatcher_needs_rebase_escalated"
        REBASE_VERDICT="NEEDS_REBASE (escalated to Mayor after $MAX_REBASE_ATTEMPTS attempts)"
      fi
    fi

    # wa-uthi: non-terminal (retryable / escalated) — no push to Athos.
    log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH — $REBASE_VERDICT."

    mkdir -p "$(dirname "$QG_LOG")"
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg branch "$BRANCH" \
      --arg bead "$BEAD_ID" \
      --arg rig "${RIG:-unknown}" \
      --arg marker "$MARKER_ID" \
      --arg author "$AUTHOR" \
      --arg main_sha "$MAIN_HEAD_SHA" \
      --arg conflicts "${CONFLICT_FILES:-unknown}" \
      --arg event "$REBASE_EVENT" \
      '{ts: $ts, event: $event, branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author, main_sha: $main_sha, conflicts: $conflicts}' \
      >> "$QG_LOG" 2>/dev/null || true

    log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$REBASE_VERDICT ==="
    exit 0
  fi
fi

log "  Branch $BRANCH is current with $DEFAULT_BRANCH — stale-base check passed."

# ── Step 5: Code-vs-non-code tier classification ──────────────────────────────
#
# NON-CODE: ALL changed files are ONLY in docs/, tests/ (test_*.py, *_test.py,
# *_test.go, *.test.*, spec files), or pure data-config (*.json, *.yaml, *.toml,
# *.md, *.csv, *.txt under docs/ or data/).
#
# CODE: ANY file outside the above set → CODE tier.
#
# When classifier is uncertain or the gate policy itself is modified → CODE tier.
# This is the "escalate up, never down" rule from review-merge-policy.md.

CHANGED_FILES=$(git_rig diff --name-only "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null || echo "")

TIER="CODE"
if [ -n "$CHANGED_FILES" ]; then
  NON_CODE_PATTERN='^(docs/|tests?/|test_|.*_test\.(py|go|js|ts)|.*\.test\.(js|ts|jsx|tsx)|.*\.spec\.(js|ts)|.*\.(md|txt|csv)$|\.github/)'
  ANY_CODE=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! echo "$f" | grep -qE "$NON_CODE_PATTERN"; then
      ANY_CODE=1
      break
    fi
  done <<< "$CHANGED_FILES"
  if [ "$ANY_CODE" = "0" ]; then
    TIER="NON-CODE"
  fi
fi

# Policy self-protection: if the gate policy or classifier is being modified,
# escalate to CODE tier regardless.
POLICY_FILES=$(echo "$CHANGED_FILES" | grep -E "(review-merge-policy|quality-gate)" || echo "")
if [ -n "$POLICY_FILES" ]; then
  TIER="CODE"
  warn "Gate policy file in diff — escalating to CODE tier (self-protection)."
fi

case "$TIER" in
  CODE)     REQUIRED_REVIEWERS=3 ;;
  NON-CODE) REQUIRED_REVIEWERS=1 ;;
  *)        REQUIRED_REVIEWERS=3 ;;
esac

log "Tier: $TIER  required_reviewers: $REQUIRED_REVIEWERS"

# ── Step 6: Create gate-run tracking bead ────────────────────────────────────

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GATE_START_EPOCH=$(date +%s)

GATE_RUN_ID=$(bd -C "$GC_CITY" create \
  "gate-run: $BRANCH ($BEAD_ID)" \
  -t chore --ephemeral \
  -l type:quality-gate-run \
  -l gate-status:running \
  -l "source-bead:$BEAD_ID" \
  -d "Autonomous gate run for $BRANCH.
source_bead: $BEAD_ID
author: $AUTHOR
rig: $RIG
tier: $TIER
required_reviewers: $REQUIRED_REVIEWERS
branch_sha: $BRANCH_SHA
marker_id: $MARKER_ID
started_at: $NOW" \
  --json 2>/dev/null | jq -r '.id // empty')

if [ -z "$GATE_RUN_ID" ]; then
  warn "Could not create gate-run tracking bead. Continuing without it."
  GATE_RUN_ID="unknown"
fi
log "Gate-run bead: $GATE_RUN_ID"

# ── Step 7: Create verdict beads (one per reviewer) ───────────────────────────
# Each reviewer session writes its verdict to its personal verdict bead:
#   - Closes bead with label "verdict:PASS" or "verdict:FAIL"
#   - Posts a comment with the reasons (required for FAIL)
#
# The dispatcher polls these beads for closed status + verdict label.

DIFF_SUMMARY=$(git_rig diff --stat "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | tail -5 | tr '\n' ' ' | cut -c1-300 || true)
# Note: "|| true" suppresses SIGPIPE (exit 141) from `head` truncating a large diff under pipefail.
# Without it, the git diff process is killed by SIGPIPE when head exits, causing the script to abort.
DIFF_FULL=$(git_rig diff "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | head -2000 || true)

VERDICT_BEAD_IDS=()
SESSION_IDS=()
# ga-noxbv: parallel arrays (index-aligned with the two above) backing the
# post-spawn ACK-verification pass. REVIEW_TASKS keeps each reviewer's exact task
# text so it can be re-queued; REVIEWER_PEEK_BASELINE snapshots each session's
# terminal BEFORE the task lands (new output later = the reviewer came alive);
# REVIEWER_ACKED tracks per-reviewer delivery confirmation.
REVIEW_TASKS=()
REVIEWER_PEEK_BASELINE=()
REVIEWER_ACKED=()

# ── ga-zl277: guaranteed reviewer-session cleanup on EVERY exit path ───────────
# Reviewer sessions used to be closed ONLY at Step 9 (the success/timeout path).
# A mid-loop spawn-abort (the `exit 1` in the spawn loop below) or any signal/
# timeout kill of the dispatcher left already-spawned reviewer sessions ASLEEP
# and never closed. They pile up against the gate-reviewer template's
# max_active_sessions=6 budget until the gate can no longer spawn 3 reviewers
# (vicious cycle). This EXIT/signal trap closes whatever is in SESSION_IDS
# exactly once, from one place, so every abort path frees its cap slots.
# (SIGKILL/OOM cannot be trapped — the Step 0a-2 startup janitor backstops those.)
_gate_cleanup_done=0
cleanup_reviewer_sessions() {
  [ "$_gate_cleanup_done" = "1" ] && return 0
  _gate_cleanup_done=1
  if [ "${#SESSION_IDS[@]}" -gt 0 ]; then
    for _SID in "${SESSION_IDS[@]}"; do
      [ -z "$_SID" ] && continue
      gc --city "$GC_CITY" session close "$_SID" 2>/dev/null || true
    done
    log "Reviewer sessions closed (cleanup): ${SESSION_IDS[*]}"
  fi
}
trap cleanup_reviewer_sessions EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

log "Spawning $REQUIRED_REVIEWERS independent reviewer session(s) ..."

for i in $(seq 1 $REQUIRED_REVIEWERS); do
  REVIEWER_LENS=""
  case "$i" in
    1) REVIEWER_LENS="CORRECTNESS: focus on logic errors, edge cases, off-by-one bugs, null/empty handling, error propagation, and incorrect assumptions. Be adversarial." ;;
    2) REVIEWER_LENS="SECURITY & ROBUSTNESS: focus on injection risks, unsafe eval/exec, credentials in code, path traversal, race conditions, resource leaks, and missing input validation." ;;
    3) REVIEWER_LENS="DESIGN & MAINTAINABILITY: focus on architectural concerns, code duplication, missing tests, test quality, unclear naming, violation of existing conventions, and tech debt introduced." ;;
  esac

  # Create a verdict bead for this reviewer
  VERDICT_BEAD_ID=$(bd -C "$GC_CITY" create \
    "reviewer-verdict: $BRANCH (reviewer $i/$REQUIRED_REVIEWERS)" \
    -t chore --ephemeral \
    -l type:quality-gate-verdict \
    -l "gate-run:$GATE_RUN_ID" \
    -l "reviewer-index:$i" \
    -l verdict:pending \
    -d "Verdict bead for reviewer $i of $REQUIRED_REVIEWERS on branch $BRANCH.
gate_run: $GATE_RUN_ID
branch: $BRANCH
author: $AUTHOR
lens: $REVIEWER_LENS
This bead ID will be delivered to the reviewer session via nudge with exact commands." \
    --json 2>/dev/null | jq -r '.id // empty')

  if [ -z "$VERDICT_BEAD_ID" ]; then
    err "Failed to create verdict bead for reviewer $i. Aborting gate."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    exit 1
  fi

  VERDICT_BEAD_IDS+=("$VERDICT_BEAD_ID")
  log "  Verdict bead $i: $VERDICT_BEAD_ID"

  # Build the review task message for the session nudge.
  # Each session gets: (a) the diff, (b) its specific lens, (c) exact bd commands to record verdict.
  REVIEW_TASK=$(cat <<TASK
QUALITY GATE REVIEW — You are reviewer $i of $REQUIRED_REVIEWERS for branch: $BRANCH
Author (EXCLUDED from reviewing): $AUTHOR
Rig: $RIG
Branch SHA: $BRANCH_SHA

YOUR REVIEW LENS: $REVIEWER_LENS

CHANGED FILES:
$CHANGED_FILES

DIFF SUMMARY:
$DIFF_SUMMARY

FULL DIFF (first 2000 lines):
$DIFF_FULL

--- YOUR TASK ---
Review this diff adversarially using ONLY your assigned lens above.
You must NOT know or consider what the other reviewers think (you are independent).
This author ($AUTHOR) cannot be a reviewer of their own work.

After completing your review, record your verdict with EXACTLY these bash commands:

bd -C "$GC_CITY" label remove "$VERDICT_BEAD_ID" "verdict:pending"
# If PASS:
bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:PASS"
bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: PASS
Summary: <2-3 sentence summary of what you checked and why it passes your lens>"
bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

# If FAIL:
# bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:FAIL"
# bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: FAIL
# Blocking issue 1: <description>
# Blocking issue 2: <description> (if any)"
# bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

Run those commands and then exit your session. Do not start other work.
TASK
)

  # Spawn an independent reviewer session (no attach, fresh wake mode).
  # Uses "gate-reviewer" template (not gastown.dog) to avoid consuming the
  # dog pool's 3 permanent cap slots (ga-mzc3h). The gate-reviewer template has
  # its own budget (max_active_sessions=6, min=0 → no permanent pool workers).
  # Stderr is captured to a temp file (not swallowed) so failures are visible.
  # NOTE: this loop runs at top-level script scope (not a function), so we do
  # NOT use `local` here — `local` outside a function errors to stderr.
  _spawn_err_file="/tmp/gate-reviewer-spawn-err-$$.${i}"
  SESSION_JSON=$(gc --city "$GC_CITY" session new gate-reviewer \
    --no-attach \
    --title "gate-reviewer-$i: $BRANCH" \
    --json \
    2>"$_spawn_err_file" || echo "{}")
  _spawn_err=$(head -c 300 "$_spawn_err_file" 2>/dev/null || echo "")
  rm -f "$_spawn_err_file"

  SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

  if [ -z "$SESSION_ID" ]; then
    err "Failed to spawn reviewer session $i (ga-mzc3h). Aborting gate. spawn_err=${_spawn_err:-no output}"
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true

    # ── ga-piscg: account this abort + escalate on K consecutive (across markers).
    # Every $() is guarded with `|| echo …` and every numeric is sanitized so this
    # block can NEVER crash the set -euo pipefail dispatcher (cf ga-8fx5e).
    _sa_count=$(cat "$SPAWN_ABORT_COUNT_FILE" 2>/dev/null || echo 0)
    case "$_sa_count" in ''|*[!0-9]*) _sa_count=0 ;; esac
    _sa_count=$((_sa_count + 1))
    echo "$_sa_count" > "$SPAWN_ABORT_COUNT_FILE" 2>/dev/null || true

    # Structured audit-trail event (carries spawn_err + consecutive count).
    mkdir -p "$(dirname "$QG_LOG")" 2>/dev/null || true
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg branch "$BRANCH" \
      --arg bead "$BEAD_ID" \
      --arg marker "$MARKER_ID" \
      --arg reviewer "$i" \
      --arg spawn_err "${_spawn_err:-no output}" \
      --argjson consec "$_sa_count" \
      '{ts:$ts, event:"spawn_abort", branch:$branch, bead:$bead, marker:$marker, reviewer:$reviewer, consecutive:$consec, spawn_err:$spawn_err}' \
      >> "$QG_LOG" 2>/dev/null || true

    if [ "$_sa_count" -ge "$SPAWN_ABORT_THRESHOLD" ]; then
      _sa_now=$(date +%s 2>/dev/null || echo 0)
      _sa_last=$(cat "$SPAWN_ABORT_ALERT_FILE" 2>/dev/null || echo 0)
      if [ "$(spawn_abort_should_page "$_sa_count" "$SPAWN_ABORT_THRESHOLD" "$_sa_now" "$_sa_last" "$SPAWN_ABORT_REALERT_SEC")" = "page" ]; then
        err "SYSTEMIC SPAWN OUTAGE: $_sa_count consecutive reviewer-spawn aborts across markers (threshold=$SPAWN_ABORT_THRESHOLD). Paging Athos + Mayor. spawn_err=${_spawn_err:-no output}"
        notify -t "🚨 Gate spawn OUTAGE" -p 5 "🚨 Quality gate DOWN: $_sa_count consecutive reviewer-spawn aborts across markers — no gate can pass. spawn_err: ${_spawn_err:-no output}" 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "🚨 Gate DOWN: $_sa_count consecutive reviewer-spawn aborts" \
          -m "$(printf 'The quality-gate dispatcher has aborted reviewer-spawn %s times CONSECUTIVELY across markers (threshold=%s, one marker per sweep). The reviewer-spawn mechanism appears broken town-wide (cf ga-mzc3h: gate-reviewer template / session cap). NO gate can PASS until this is fixed.\n\nLatest marker: %s\nLatest branch: %s\nLatest source bead: %s\nspawn_err: %s\n\nAthos was paged via ntfy. Investigate the gate-reviewer template + session cap immediately; clear the counter at %s once spawn works again.' \
            "$_sa_count" "$SPAWN_ABORT_THRESHOLD" "$MARKER_ID" "$BRANCH" "$BEAD_ID" "${_spawn_err:-no output}" "$SPAWN_ABORT_COUNT_FILE")" \
          2>/dev/null || warn "Could not mail Mayor spawn-outage escalation"
        echo "$_sa_now" > "$SPAWN_ABORT_ALERT_FILE" 2>/dev/null || true
      fi
    fi
    exit 1
  fi

  SESSION_IDS+=("$SESSION_ID")
  log "  Reviewer session $i spawned: session_id=$SESSION_ID verdict_bead=$VERDICT_BEAD_ID"

  # Wake the session so it starts immediately
  gc --city "$GC_CITY" session wake "$SESSION_ID" 2>/dev/null || true

  # ga-67hae: DURABLE PULL CHANNEL — assign verdict bead to this reviewer's
  # session_name + embed the review task in its comment. The nudge below is a
  # fast-path; the reviewer's poll loop (`gc bd list --assignee=$GC_SESSION_NAME`)
  # is the reliable fallback that survives nudge-injection races. All guarded
  # with || true (set -euo pipefail safe).
  SESSION_NAME=$(echo "$SESSION_JSON" | jq -r '.session_name // empty')
  if [ -n "$SESSION_NAME" ]; then
    bd -C "$GC_CITY" update "$VERDICT_BEAD_ID" --assignee "$SESSION_NAME" --status in_progress -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "$REVIEW_TASK" 2>/dev/null || true
    log "  Verdict bead $VERDICT_BEAD_ID assigned to $SESSION_NAME + task embedded (durable pull, ga-67hae)"
  fi

  # ga-noxbv: snapshot the session's terminal BEFORE the task is delivered. The
  # ACK pass (Step 7b) compares a fresh peek against this baseline — any change
  # means the reviewer came alive and consumed input. cksum of the peek buffer is
  # a cheap stable fingerprint. `|| echo ""` keeps set -euo pipefail happy.
  _peek_base=$(gc --city "$GC_CITY" session peek "$SESSION_ID" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
  REVIEW_TASKS+=("$REVIEW_TASK")
  REVIEWER_PEEK_BASELINE+=("$_peek_base")
  REVIEWER_ACKED+=(0)

  # Deliver the review task via `queue` (enqueue-and-return). ga-noxbv root cause:
  # `--delivery immediate` typed the task into a freshly-spawned headless session
  # that was NOT yet input-ready → keystrokes dropped → reviewer idle forever →
  # gate hung at N/3 verdicts. `queue` hands the task to the runtime, which
  # delivers it WHEN the session becomes input-ready (no dropped keystrokes, no
  # magic sleep needed). NOT `wait-idle`: this spawn loop is sequential, so a
  # blocking wait on a never-idle reviewer would stall spawning reviewers 2&3 —
  # `queue` returns immediately. Do NOT log "delivered" here (it would lie on a
  # send the reviewer never consumed); Step 7b confirms a real ACK.
  if gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REVIEW_TASK" --delivery queue 2>/dev/null; then
    log "  Review task QUEUED to session $SESSION_ID (reviewer $i) — ACK pending (Step 7b)"
  elif gc --city "$GC_CITY" session submit "$SESSION_ID" "$REVIEW_TASK" 2>/dev/null; then
    log "  Review task SUBMITTED to session $SESSION_ID (reviewer $i) — ACK pending (Step 7b)"
  else
    warn "  Initial queue/submit to session $SESSION_ID failed — Step 7b will retry (reviewer $i)"
  fi

  # ga-mepb0 (EDIT #2, defense-in-depth): stagger the NEXT reviewer's spawn so the
  # N reviewers do not all fire `gc prime` (SessionStart) against Dolt :52756 in
  # the same instant — that thundering herd is what trips the Dolt circuit-breaker
  # and wedges a reviewer at boot (the false-FAIL root). Skip the pause after the
  # last reviewer (nothing left to spawn) and when disabled (stagger=0). EDIT #1
  # still re-convenes any reviewer that wedges despite this; the stagger just
  # lowers the odds of the wedge. Guarded so a misconfig can't crash the loop.
  if [ "$GATE_SPAWN_STAGGER_SECS" -gt 0 ] 2>/dev/null && [ "$i" -lt "$REQUIRED_REVIEWERS" ] 2>/dev/null; then
    log "  Spawn stagger: sleeping ${GATE_SPAWN_STAGGER_SECS}s before reviewer $((i+1)) (ga-mepb0, Dolt boot-herd guard)"
    sleep "$GATE_SPAWN_STAGGER_SECS" || true
  fi
done

log "All $REQUIRED_REVIEWERS reviewer sessions spawned: ${SESSION_IDS[*]}"

# ── ga-4u16h: per-slot re-convene state (index-aligned with VERDICT_BEAD_IDS /
# SESSION_IDS / REVIEW_TASKS). RESPAWN_BUDGET caps re-spawns per slot;
# SLOT_SPAWN_EPOCH anchors each slot's grace window (reset on every re-spawn so a
# fresh reviewer gets a fair start); SLOT_DEAD_STREAK requires consecutive DEAD
# reads before acting (transient-list-failure guard).
RESPAWN_BUDGET=()
SLOT_SPAWN_EPOCH=()
SLOT_DEAD_STREAK=()
_reconvene_init_now=$(date +%s)
for _ri in "${!SESSION_IDS[@]}"; do
  RESPAWN_BUDGET+=("$MAX_RESPAWNS_PER_SLOT")
  SLOT_SPAWN_EPOCH+=("$_reconvene_init_now")
  SLOT_DEAD_STREAK+=(0)
done

# ── ga-piscg: spawn mechanism is proven working this sweep → reset the
# consecutive-abort counter + alert state so a FUTURE outage pages fresh (and so
# we don't carry a stale count from an outage that has since recovered).
_sa_prev=$(cat "$SPAWN_ABORT_COUNT_FILE" 2>/dev/null || echo 0)
case "$_sa_prev" in ''|*[!0-9]*) _sa_prev=0 ;; esac
if [ "$_sa_prev" -gt 0 ]; then
  log "Reviewer-spawn succeeded — clearing consecutive spawn-abort counter (was $_sa_prev)."
fi
rm -f "$SPAWN_ABORT_COUNT_FILE" "$SPAWN_ABORT_ALERT_FILE" 2>/dev/null || true

# ── Step 7b: ACK verification — confirm reviewers actually consumed their task ──
# ga-noxbv reliability fix. `queue` delivery (above) lets the runtime deliver when
# a session is input-ready, but a session that spawned-then-wedged would still
# never consume the task → the old gate hung at N/3 forever, invisibly. Here we
# confirm a real ACK per reviewer and RE-QUEUE only sessions showing NO sign of
# life, bounded to ~ACK_MAX_RETRIES*ACK_WAIT_SECS (~80s worst case). A reviewer
# ACKs when EITHER (strong) its verdict bead has progressed past verdict:pending
# OR (soft) its session has produced new terminal output since the pre-delivery
# baseline. We only re-queue sessions that show neither — exactly the wedged/idle
# case — so a live-but-slow reviewer is never spammed with duplicate tasks.
# NON-fatal by design: the verdict poll, the DISPATCHING_TTL zombie-recovery, and
# gate-health-monitor's idle-reviewer watchdog remain the ultimate backstops, so
# we never abort the gate here.
# HARD CONSTRAINT (memory gate-dispatcher-set-e-pipefail-crash): set -euo pipefail
# is active — every command below is `|| true`-guarded or used as a condition so a
# transient failure can never head-of-line-block the gate.
ACK_MAX_RETRIES="${ACK_MAX_RETRIES:-4}"
ACK_WAIT_SECS="${ACK_WAIT_SECS:-20}"
for _ack_attempt in $(seq 1 "$ACK_MAX_RETRIES"); do
  _all_acked=1
  for k in "${!VERDICT_BEAD_IDS[@]}"; do
    if [ "${REVIEWER_ACKED[$k]:-0}" = "1" ]; then continue; fi
    _vb="${VERDICT_BEAD_IDS[$k]}"
    _sid="${SESSION_IDS[$k]}"
    # Strong ACK: verdict bead progressed past verdict:pending (reviewer is acting).
    _vb_labels=$(bd -C "$GC_CITY" show "$_vb" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "verdict:pending")
    if ! echo "$_vb_labels" | grep -q "verdict:pending"; then
      REVIEWER_ACKED[$k]=1
      log "  ACK (verdict-progressed): reviewer $((k+1)) session=$_sid bead=$_vb"
      continue
    fi
    # Soft ACK: session produced new output since baseline → alive and consuming
    # input; trust the already-queued task will deliver. Stop re-queuing it.
    _peek_now=$(gc --city "$GC_CITY" session peek "$_sid" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
    if [ -n "$_peek_now" ] && [ "$_peek_now" != "${REVIEWER_PEEK_BASELINE[$k]:-}" ]; then
      REVIEWER_ACKED[$k]=1
      log "  ACK (session-alive): reviewer $((k+1)) producing output session=$_sid"
      continue
    fi
    # No sign of life. On the FIRST attempt just wait (give the initial queue a
    # chance); from attempt 2 on, re-queue the exact task into the idle session.
    _all_acked=0
    if [ "$_ack_attempt" -gt 1 ]; then
      warn "  No ACK from reviewer $((k+1)) (attempt $_ack_attempt/$ACK_MAX_RETRIES) — re-queuing task session=$_sid"
      gc --city "$GC_CITY" session nudge "$_sid" "${REVIEW_TASKS[$k]}" --delivery queue 2>/dev/null || true
    fi
  done
  [ "$_all_acked" = "1" ] && break
  sleep "$ACK_WAIT_SECS" || true
done
for k in "${!VERDICT_BEAD_IDS[@]}"; do
  if [ "${REVIEWER_ACKED[$k]:-0}" != "1" ]; then
    warn "  Reviewer $((k+1)) never ACKed after ${ACK_MAX_RETRIES} attempts — relying on verdict-poll + DISPATCHING_TTL + monitor backstops (session=${SESSION_IDS[$k]})"
  fi
done

log "Waiting for verdicts (timeout=${VERDICT_TIMEOUT_MINUTES}m, poll=${VERDICT_POLL_INTERVAL}s) ..."

# ── Step 8: Poll for verdicts ─────────────────────────────────────────────────

VERDICT_TIMEOUT_SECS=$((VERDICT_TIMEOUT_MINUTES * 60))
WAIT_START=$(date +%s)
ALL_VERDICTS_IN=0
OVERALL_VERDICT="PASS"
FAIL_REASONS=""

while true; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - WAIT_START))

  if [ "$ELAPSED" -gt "$VERDICT_TIMEOUT_SECS" ]; then
    warn "Verdict timeout after ${ELAPSED}s (limit=${VERDICT_TIMEOUT_SECS}s). Treating as FAIL."
    OVERALL_VERDICT="FAIL"
    FAIL_REASONS="TIMEOUT: reviewers did not submit verdicts within ${VERDICT_TIMEOUT_MINUTES} minutes."
    # Close any remaining pending verdict beads as timed-out
    for VB in "${VERDICT_BEAD_IDS[@]}"; do
      VB_STATUS=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | .status // "open"')
      if [ "$VB_STATUS" != "closed" ]; then
        bd -C "$GC_CITY" label remove "$VB" "verdict:pending" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$VB" "verdict:TIMEOUT" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$VB" "VERDICT: TIMEOUT — reviewer session did not complete within ${VERDICT_TIMEOUT_MINUTES}m" 2>/dev/null || true
        bd -C "$GC_CITY" close "$VB" 2>/dev/null || true
      fi
    done
    break
  fi

  VERDICTS_RECEIVED=0
  ANY_FAIL=0

  # ── ga-4u16h: snapshot reviewer-session liveness ONCE per poll (cheap) so each
  # still-pending slot can be checked for a DEAD session without N list calls.
  # Fail-safe: if the list call fails or is unparseable, RECONVENE_LIST_OK stays 0
  # and NO slot is re-convened this poll (a transient list glitch must never
  # re-spawn a live reviewer). Skipped entirely when the feature is disabled.
  RECONVENE_LIST_OK=0
  RECONVENE_SESS_JSON=""
  if [ "$MAX_RESPAWNS_PER_SLOT" -gt 0 ]; then
    RECONVENE_SESS_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo "")
    if [ -n "$RECONVENE_SESS_JSON" ] && echo "$RECONVENE_SESS_JSON" \
         | jq -e 'if type=="array" then true else has("sessions") end' >/dev/null 2>&1; then
      RECONVENE_LIST_OK=1
    fi
  fi

  for j in "${!VERDICT_BEAD_IDS[@]}"; do
    VB="${VERDICT_BEAD_IDS[$j]}"
    VB_JSON=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null || echo "[]")
    VB_STATUS=$(echo "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"')
    VB_LABELS=$(echo "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")')

    if [ "$VB_STATUS" = "closed" ]; then
      VERDICTS_RECEIVED=$((VERDICTS_RECEIVED + 1))
      if echo "$VB_LABELS" | grep -q "verdict:PASS"; then
        : # explicit PASS — continue
      elif echo "$VB_LABELS" | grep -q "verdict:FAIL"; then
        ANY_FAIL=1
        # Collect the fail reason from the reviewer's verdict comment.
        # NOTE (ga-kf0v): the beads "bd comments --json" schema uses .text
        # (keys: author, created_at, id, issue_id, text) — there is NO .body
        # field. The old accessor read .[0].body, so jq always fell through to
        # the "No reason provided" default and EVERY genuine reviewer FAIL lost
        # its reason. Parse .text (with .body kept as a defensive fallback for
        # any future schema drift), preferring the comment that starts with
        # "VERDICT:" (the reviewer convention), else the first non-empty one.
        VB_COMMENTS_JSON=$(bd -C "$GC_CITY" comments "$VB" --json 2>/dev/null || echo "[]")
        FAIL_COMMENT=$(printf '%s' "$VB_COMMENTS_JSON" | jq -r '
            [ .[]? | (.text // .body // "") ]
            | ( map(select(test("^\\s*VERDICT:"; "i"))) | last )
              // ( map(select(. != "")) | first )
              // ""
          ' 2>/dev/null || echo "")
        # FORENSICS (ga-kf0v #3): always log the raw comments + verdict labels
        # for a FAIL so any future schema/field drift is visible in the
        # dispatcher log without re-deriving from beads.
        log "  FAIL forensics reviewer $((j+1)) bead=$VB labels=[$VB_LABELS] raw_comments=$(printf '%s' "$VB_COMMENTS_JSON" | jq -c . 2>/dev/null | cut -c1-2000)"
        if [ -z "$FAIL_COMMENT" ]; then
          # Reviewer closed verdict:FAIL but left no parseable reason. Now rare
          # (the .text fix above resolves the common case). Fail-safe: PASS is
          # the only acceptable verdict, so an empty-reason FAIL still blocks
          # the merge — but mark it INCONCLUSIVE and warn loudly so it is
          # distinguishable from a substantive FAIL. (Full per-reviewer session
          # re-run retry per ga-kf0v #2 is deliberately deferred: re-dispatching
          # a reviewer mid-collection is higher-risk than this lane:small fix
          # warrants; making the empty case visible addresses the intent without
          # destabilising the gate's verdict-collection loop.)
          warn "Reviewer $((j+1)) (bead $VB) closed verdict:FAIL with no parseable reason — counting as INCONCLUSIVE FAIL (fail-safe)."
          FAIL_COMMENT="INCONCLUSIVE — verdict:FAIL with empty/unparseable reason (raw bead $VB; see forensics log above)"
        fi
        FAIL_REASONS="${FAIL_REASONS}Reviewer $((j+1)) FAIL: $FAIL_COMMENT\n"
      else
        # Any other label (TIMEOUT, ABORTED, or missing verdict label) → FAIL.
        # PASS is the ONLY acceptable verdict; anything else blocks the merge.
        ANY_FAIL=1
        VERDICT_LABEL=$(echo "$VB_LABELS" | tr ' ' '\n' | grep "^verdict:" | head -1 || echo "no-verdict-label")
        FAIL_REASONS="${FAIL_REASONS}Reviewer $((j+1)) ${VERDICT_LABEL}: verdict bead closed without explicit PASS.\n"
      fi
    else
      # ── ga-4u16h: verdict bead still pending. If this slot's reviewer SESSION
      # is DEAD (Dolt reset killed it), re-convene a fresh reviewer for THIS slot
      # rather than waiting the full outer timeout and counting it a false FAIL.
      # Conservative gating (all must hold): re-convene is enabled, the session
      # list call succeeded this poll, the slot is past its grace window, the
      # session reads DEAD for RECONVENE_DEAD_STREAK_MIN consecutive polls, and
      # respawn budget remains. A live-but-slow reviewer (present + not closed,
      # incl. `asleep`) is never re-convened.
      if [ "$MAX_RESPAWNS_PER_SLOT" -gt 0 ] && [ "$RECONVENE_LIST_OK" = "1" ]; then
        _sid="${SESSION_IDS[$j]}"
        _spawn_age=$(( NOW_EPOCH - ${SLOT_SPAWN_EPOCH[$j]:-$NOW_EPOCH} ))
        _present_n=$(echo "$RECONVENE_SESS_JSON" \
          | jq -r --arg s "$_sid" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | length' 2>/dev/null || echo 1)
        case "$_present_n" in ''|*[!0-9]*) _present_n=1 ;; esac
        if [ "$_present_n" -ge 1 ]; then
          _present_flag=1
          _closed_flag=$(echo "$RECONVENE_SESS_JSON" \
            | jq -r --arg s "$_sid" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | .[0].closed // false' 2>/dev/null || echo false)
        else
          _present_flag=0
          _closed_flag=false
        fi
        _dead=$(session_is_dead "$_present_flag" "$_closed_flag")
        # ── ga-mepb0: late-ACK re-check + boot-wedge deadness ───────────────────
        # A reviewer wedged at boot (gc prime hung on the Dolt circuit-breaker) is
        # present + asleep (session_is_dead=0) but never ACKs, so the session-only
        # liveness gate above left it for the 45m outer timeout to fail — bouncing
        # a GOOD branch on INFRA. Treat a never-ACKed slot as effectively dead so
        # it is re-convened in <grace+streak. BUT re-check for LATE life first so a
        # slow-but-alive reviewer is NEVER killed:
        #   strong: its verdict bead already dropped verdict:pending — reuse the
        #           VB_LABELS fetched above, so NO extra bd call; OR
        #   soft:   its session produced new terminal output since the baseline.
        # Both checks are skipped once the slot has ACKed (cheap; bounded to the
        # wedged-looking window only).
        if [ "${REVIEWER_ACKED[$j]:-0}" != "1" ]; then
          if ! echo "$VB_LABELS" | grep -q "verdict:pending"; then
            REVIEWER_ACKED[$j]=1
            log "  Late ACK (verdict-progressed): reviewer $((j+1)) session=${_sid} bead=$VB"
          else
            _peek_now=$(gc --city "$GC_CITY" session peek "$_sid" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
            if [ -n "$_peek_now" ] && [ "$_peek_now" != "${REVIEWER_PEEK_BASELINE[$j]:-}" ]; then
              REVIEWER_ACKED[$j]=1
              log "  Late ACK (session-alive): reviewer $((j+1)) session=${_sid}"
            fi
          fi
        fi
        _eff_dead=$(slot_effectively_dead "$_dead" "${REVIEWER_ACKED[$j]:-0}")
        # Grace gate: never call a freshly-(re)spawned reviewer dead too early.
        if [ "$_eff_dead" = "1" ] && [ "$_spawn_age" -ge "$RECONVENE_GRACE_SECS" ]; then
          SLOT_DEAD_STREAK[$j]=$(( ${SLOT_DEAD_STREAK[$j]:-0} + 1 ))
        else
          SLOT_DEAD_STREAK[$j]=0
        fi
        _confirmed_dead=0
        if [ "$_eff_dead" = "1" ] && [ "${SLOT_DEAD_STREAK[$j]:-0}" -ge "$RECONVENE_DEAD_STREAK_MIN" ]; then
          _confirmed_dead=1
        fi
        _action=$(classify_slot_action 0 "$_confirmed_dead" "${RESPAWN_BUDGET[$j]:-0}")
        if [ "$_action" = "respawn" ]; then
          RESPAWN_BUDGET[$j]=$(( ${RESPAWN_BUDGET[$j]:-0} - 1 ))
          _respawn_k=$(( MAX_RESPAWNS_PER_SLOT - ${RESPAWN_BUDGET[$j]} ))
          # ga-mepb0: name the deadness cause so a boot-wedge (false-FAIL root) is
          # distinguishable from a Dolt-killed session in the gate log.
          if [ "$_dead" = "1" ]; then _dead_reason="session dead"; else _dead_reason="boot-wedged (present but never ACKed — gc prime/Dolt stall)"; fi
          log "Re-convening dead reviewer slot $j (respawn ${_respawn_k}/${MAX_RESPAWNS_PER_SLOT}) — session ${SESSION_IDS[$j]} ${_dead_reason}, verdict bead ${VERDICT_BEAD_IDS[$j]} still pending."
          SLOT_SPAWN_EPOCH[$j]="$NOW_EPOCH"   # reset this slot's grace clock
          SLOT_DEAD_STREAK[$j]=0
          respawn_reviewer_slot "$j" || true
        fi
      fi
    fi
  done

  log "  Verdicts: $VERDICTS_RECEIVED/$REQUIRED_REVIEWERS received (elapsed: ${ELAPSED}s)"

  if [ "$VERDICTS_RECEIVED" -eq "$REQUIRED_REVIEWERS" ]; then
    ALL_VERDICTS_IN=1
    if [ "$ANY_FAIL" = "1" ]; then
      OVERALL_VERDICT="FAIL"
    fi
    break
  fi

  sleep "$VERDICT_POLL_INTERVAL"
done

log "Verdict collection complete: OVERALL=$OVERALL_VERDICT"

# ── Step 9: Close reviewer sessions ──────────────────────────────────────────
# Close promptly here (before the Step 10 merge) to free the gate-reviewer cap
# slots ASAP. The EXIT trap (ga-zl277) is the safety net for every abort path
# that never reaches this line; the shared idempotent helper makes the trap a
# no-op once this has run.
cleanup_reviewer_sessions

# ── Step 10: Act on verdict ───────────────────────────────────────────────────

GATE_END_EPOCH=$(date +%s)
ELAPSED_S=$((GATE_END_EPOCH - GATE_START_EPOCH))

if [ "$OVERALL_VERDICT" = "PASS" ]; then
  log "ALL PASS — proceeding to merge branch $BRANCH → $DEFAULT_BRANCH ..."

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD MERGE: git_rig push origin <branch_sha>:refs/heads/$DEFAULT_BRANCH (FF merge of $BRANCH)"
    log "DRY_RUN=1 — WOULD CLOSE source bead $BEAD_ID"
    MERGE_SHA="DRY_RUN_NO_MERGE"
    MERGE_RESULT="dry_run"
  else
    # ── Container-rig direct merge ──────────────────────────────────────────
    # For container rigs (bare .repo.git):
    #   1. Rebase the branch onto origin/main (ensures clean FF merge)
    #   2. Fast-forward main to the branch tip
    #   3. Push main to origin
    #
    # For self-repo rigs (normal .git directory):
    #   Use standard git commands via -C <rig_path>
    #
    # SECURITY NOTE: We do NOT use `git push --force`. This is a FF merge only.
    # If FF fails (diverged history), we abort and report failure.

    MERGE_SHA=""
    MERGE_RESULT="failed"

    # ── ga-3b8: Merge-time rebase+retry (starvation fix) ──────────────────────
    # The review→merge window is the starvation attack surface: another rig merge
    # can land between "reviewers PASS" and "push main".  We handle this by
    # re-fetching at merge time and, if main moved, auto-rebasing the branch
    # (conflict-free only) before the FF push.  If the FF push races again, we
    # retry the whole rebase→push sequence up to MAX_MERGE_RETRIES times.
    # Each attempt is fast (seconds), so 3 retries closes the window even on a
    # very busy rig.
    MAX_MERGE_RETRIES=3
    MERGE_ATTEMPT=0

    do_merge_ff() {
      # Arguments: IS_CONTAINER_RIG, BRANCH, DEFAULT_BRANCH — all from outer scope.
      # Returns: sets MERGE_SHA and MERGE_RESULT in outer scope.
      # Strategy per attempt:
      #   1. git fetch (get current remote state)
      #   2. If main moved (branch no longer FF-able): auto-rebase if clean
      #   3. FF push branch SHA to main
      #   4. Verify landing

      git_rig fetch origin 2>/dev/null || warn "Pre-merge fetch failed (attempt $((MERGE_ATTEMPT+1)))"
      # ga-ljbx: hardened — resolve to REAL commit objects so a dangling ref
      # surfaces as failed_sha_resolution (retryable) rather than poisoning the
      # downstream merge-base/merge-tree with a non-existent SHA.
      local CUR_MAIN
      CUR_MAIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
      local CUR_BRANCH
      CUR_BRANCH=$(rig_resolve_commit "origin/$BRANCH")

      if [ -z "$CUR_MAIN" ] || [ -z "$CUR_BRANCH" ]; then
        MERGE_RESULT="failed_sha_resolution"
        return 1
      fi

      local IS_ANC
      IS_ANC=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

      if [ "$IS_ANC" != "yes" ]; then
        # Main moved during review — attempt inline rebase before push
        log "  Merge-time rebase: main moved to $CUR_MAIN after review; rebasing $BRANCH ..."
        local TMP_MR_WT="/tmp/gc-gate-mr-retry-$$-${MERGE_ATTEMPT}"
        local MR_OK=0

        # ga-ljbx: deterministic conflict pre-check (git 2.54) — see
        # rig_merge_has_conflict. An "err" verdict is treated as a transient
        # resolution failure (retryable) rather than a phantom conflict.
        local MR_BASE
        MR_BASE=$(git_rig merge-base "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
        local MR_CONFLICT=0
        local MR_VERDICT
        MR_VERDICT=$(rig_merge_has_conflict "origin/$DEFAULT_BRANCH" "origin/$BRANCH")
        if [ "$MR_VERDICT" = "1" ]; then
          MR_CONFLICT=1
        elif [ "$MR_VERDICT" = "err" ]; then
          err "  Merge-time conflict pre-check undeterminable (base=${MR_BASE:-none}) — treating as transient (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_sha_resolution"
          return 1
        fi

        if [ "$MR_CONFLICT" = "1" ]; then
          err "  Merge-time rebase: conflicts detected — cannot auto-rebase (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_merge_time_conflict"
          return 1
        fi

        if [ "$IS_CONTAINER_RIG" = "1" ]; then
          if git_rig worktree add "$TMP_MR_WT" "origin/$BRANCH" 2>/dev/null; then
            git -C "$TMP_MR_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
            git -C "$TMP_MR_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
            if git -C "$TMP_MR_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
              local NEW_TIP_MR
              NEW_TIP_MR=$(git -C "$TMP_MR_WT" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$NEW_TIP_MR" ] && git -C "$TMP_MR_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
                MR_OK=1
                log "  Merge-time rebase: pushed $BRANCH → $NEW_TIP_MR"
              else
                git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
              fi
            else
              git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
            fi
            git_rig worktree remove "$TMP_MR_WT" --force 2>/dev/null || true
          fi
        else
          if git -C "$GIT_DIR_PATH" worktree add "$TMP_MR_WT" "origin/$BRANCH" 2>/dev/null; then
            git -C "$TMP_MR_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
            git -C "$TMP_MR_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
            if git -C "$TMP_MR_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
              local NEW_TIP_MR_SR
              NEW_TIP_MR_SR=$(git -C "$TMP_MR_WT" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$NEW_TIP_MR_SR" ] && git -C "$TMP_MR_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
                MR_OK=1
                log "  Merge-time rebase (self-repo): pushed $BRANCH → $NEW_TIP_MR_SR"
              else
                git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
              fi
            else
              git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
            fi
            git -C "$GIT_DIR_PATH" worktree remove "$TMP_MR_WT" --force 2>/dev/null || true
          fi
        fi

        if [ "$MR_OK" != "1" ]; then
          err "  Merge-time rebase: worktree/push failed (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_merge_time_rebase"
          return 1
        fi

        # Re-fetch after rebase push (ga-ljbx: hardened resolution)
        git_rig fetch origin 2>/dev/null || true
        CUR_BRANCH=$(rig_resolve_commit "origin/$BRANCH")
        CUR_MAIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
        if [ -z "$CUR_BRANCH" ] || [ -z "$CUR_MAIN" ]; then
          MERGE_RESULT="failed_sha_resolution"
          return 1
        fi
        IS_ANC=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

        if [ "$IS_ANC" != "yes" ]; then
          err "  Merge-time rebase: branch still not FF-able after rebase (main moved again?)"
          MERGE_RESULT="failed_still_not_ff_after_rebase"
          return 1
        fi
      fi

      # FF push
      if git_rig push origin "${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH" 2>/dev/null; then
        git_rig fetch origin 2>/dev/null || warn "Post-FF-push fetch failed"
        local POST_MAIN
        POST_MAIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
        if [ -n "$POST_MAIN" ] && git_rig merge-base --is-ancestor "$CUR_BRANCH" "$POST_MAIN" 2>/dev/null; then
          MERGE_SHA="$CUR_BRANCH"
          MERGE_RESULT="direct_ff"
          log "FF merge + landing verified (attempt $((MERGE_ATTEMPT+1))): $BRANCH → $DEFAULT_BRANCH (sha=$MERGE_SHA, main=$POST_MAIN)"

          # ── ga-eptel: durable rig-canonical landing + survival audit ─────────
          # The FF push above advances the REMOTE (origin/$DEFAULT_BRANCH on
          # GitHub), but for a CONTAINER rig `git_rig` targets the bare
          # .repo.git — whose OWN local refs/heads/$DEFAULT_BRANCH is NOT touched
          # by a push. Crew worktrees clone from that bare repo, so a stale local
          # main makes a gate-verified merge "disappear" from the rig's canonical
          # main even though it lives on GitHub. This is the root cause of
          # ga-eptel: ps-l72n (305dd697c) and ga-i5vt (d3cafb679) were reported
          # "FF merge + landing verified" yet vanished from the rig's main —
          # because the bare local main was never advanced (verified live: both
          # SHAs present on origin/main, absent from the bare .repo.git main).
          #
          # Fix: advance the bare local main to the merge SHA (FF-only — never
          # rewrite history), then AUDIT survival by confirming the merge is an
          # ancestor of BOTH the rig-canonical local main AND origin/main after a
          # fresh fetch. If it vanished (e.g. a racing town-main push clobbered a
          # shared remote), do NOT report success: return 1 so the caller
          # degrades to gate-status:error and the source bead is re-enqueued, not
          # closed. Self-repo rigs (wa, gascity) are unaffected and untouched —
          # their deploy reads GitHub directly and they survived the audit (4/4).
          if [ "$IS_CONTAINER_RIG" = "1" ]; then
            local RESOLVED_MERGE LOCAL_MAIN AUDIT_LOCAL AUDIT_ORIGIN
            RESOLVED_MERGE=$(rig_resolve_commit "$CUR_BRANCH")
            if [ -z "$RESOLVED_MERGE" ]; then
              err "  Durable-landing: merge SHA unresolvable post-push ($CUR_BRANCH)"
              MERGE_RESULT="failed_durable_resolution"
              return 1
            fi
            # ga-rstw5: track origin/$DEFAULT_BRANCH (the canonical durable line the
            # FF push above just advanced — $RESOLVED_MERGE is verified an ancestor
            # of it), NOT merely the merge SHA. FF when the bare ref is behind; when
            # it has FORKED off origin (orphan commits — e.g. a decommission
            # 'preserve' commit) RECONCILE to origin instead of false-FAILing the
            # all-PASS verdict. The old FF-only-or-fail guard's failed_durable_not_ff
            # burned a 2nd gate cycle + mailed crew a spurious FAIL the instant the
            # bare mirror diverged. The survival audit below STILL re-verifies the
            # merge in BOTH the rig-canonical local main AND origin, so a genuine
            # clobber/orphan is still caught and re-enqueued (not closed).
            DURABLE_RECON_OUT=""
            DURABLE_RECON_RC=0
            DURABLE_RECON_OUT=$(reconcile_bare_main_to_origin "$GIT_DIR_PATH" "$DEFAULT_BRANCH") || DURABLE_RECON_RC=$?
            if [ "$DURABLE_RECON_RC" != "0" ]; then
              err "  Durable-landing: bare $DEFAULT_BRANCH reconcile to origin FAILED ($DURABLE_RECON_OUT)"
              MERGE_RESULT="failed_durable_updateref"
              return 1
            fi
            log "  Durable-landing: bare $DEFAULT_BRANCH reconciled to origin ($DURABLE_RECON_OUT)"
            # Survival audit: fresh fetch, then confirm the merge survives in BOTH
            # the rig-canonical local main AND origin/main. A failure here means
            # the merge was orphaned (shared-remote clobber or lost push) — fail
            # so the bead is re-enqueued, not closed (ga-eptel audit-guard ask).
            git_rig fetch origin 2>/dev/null || warn "  Durable-landing: audit re-fetch failed (continuing with stale refs)"
            AUDIT_LOCAL=$(rig_resolve_commit "refs/heads/$DEFAULT_BRANCH")
            if [ -z "$AUDIT_LOCAL" ] || ! git_rig merge-base --is-ancestor "$RESOLVED_MERGE" "$AUDIT_LOCAL" 2>/dev/null; then
              err "  Durable-landing AUDIT FAILED: merge $RESOLVED_MERGE not in rig-canonical $DEFAULT_BRANCH (${AUDIT_LOCAL:-<unresolved>})"
              MERGE_RESULT="failed_durable_audit_local"
              return 1
            fi
            AUDIT_ORIGIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
            if [ -z "$AUDIT_ORIGIN" ] || ! git_rig merge-base --is-ancestor "$RESOLVED_MERGE" "$AUDIT_ORIGIN" 2>/dev/null; then
              err "  Durable-landing AUDIT FAILED: merge $RESOLVED_MERGE not in origin/$DEFAULT_BRANCH (${AUDIT_ORIGIN:-<unresolved>}) — possible shared-remote clobber"
              MERGE_RESULT="failed_durable_audit_origin"
              return 1
            fi
            log "  Durable-landing verified: merge $RESOLVED_MERGE is ancestor of BOTH rig-canonical $DEFAULT_BRANCH ($AUDIT_LOCAL) and origin ($AUDIT_ORIGIN)"
          fi

          return 0
        else
          err "Landing verification FAILED (attempt $((MERGE_ATTEMPT+1))): $CUR_BRANCH not in $DEFAULT_BRANCH ($POST_MAIN)"
          MERGE_RESULT="failed_landing_not_verified"
          return 1
        fi
      else
        # FF push rejected: main moved between our rebase and push (race)
        warn "  FF push rejected (attempt $((MERGE_ATTEMPT+1))) — main moved during push; will retry"
        MERGE_RESULT="failed_push_race"
        return 1
      fi
    }

    while [ "$MERGE_ATTEMPT" -lt "$MAX_MERGE_RETRIES" ]; do
      MERGE_ATTEMPT=$((MERGE_ATTEMPT + 1))
      log "Merge attempt $MERGE_ATTEMPT/$MAX_MERGE_RETRIES ..."
      if do_merge_ff; then
        break
      fi
      # Only retry on push-race or stale-after-rebase; give up on conflict/worktree failure
      if [ "$MERGE_RESULT" = "failed_merge_time_conflict" ] || \
         [ "$MERGE_RESULT" = "failed_merge_time_rebase" ] || \
         [ "$MERGE_RESULT" = "failed_sha_resolution" ]; then
        log "  Non-retryable failure ($MERGE_RESULT). Stopping retry loop."
        break
      fi
      if [ "$MERGE_ATTEMPT" -lt "$MAX_MERGE_RETRIES" ]; then
        log "  Retrying in 2s ..."
        sleep 2
      fi
    done

    if [[ "$MERGE_RESULT" = failed* ]]; then
      # Merge failed despite all-PASS verdict — degrade to FAIL
      OVERALL_VERDICT="FAIL"
      FAIL_REASONS="Merge failed after all-PASS verdict. Merge result: $MERGE_RESULT. Check git state of rig $RIG."
      warn "All-PASS verdict but merge failed ($MERGE_RESULT). Setting gate to failed."
    fi

    # ── ga-hawi: soft-reload immediately after merge ──────────────────────────
    # Every gate merge bumps the template config hash (CopyFiles mtime changes).
    # Without this, the session reconciler's next tick sees config drift and
    # issues drain decisions against crew, even pinned ones (race window = 0..Ns
    # until town-root-reconciler's poll).  --soft accepts the new hash in place;
    # --async returns immediately so we don't block the gate.  Non-fatal if missing.
    if [[ ! "$MERGE_RESULT" = failed* ]] && [ "$MERGE_RESULT" != "dry_run" ]; then
      gc reload --soft --async 2>/dev/null \
        && log "ga-hawi: soft-reload dispatched post-merge (config-drift guard for pinned crew)." \
        || warn "ga-hawi: gc reload --soft --async failed (non-fatal; binary guard still active)."
    fi

    # ── Bug 1b: Post-merge diff-integrity verification (belt-and-suspenders) ──
    # After a successful merge, verify the branch's changes are actually present
    # in the merged main. This catches silent conflict resolutions where git
    # resolved to main's side (dropping the fix entirely — as seen in wa-e99e).
    #
    # Strategy: fetch updated remote refs, then verify each file changed by the
    # branch still has a non-empty diff vs what was in main BEFORE the merge.
    # If any changed file regressed back to its pre-branch state, the merge
    # silently dropped changes — revert and bounce to author.
    if [[ ! "$MERGE_RESULT" = failed* ]] && [ "$MERGE_RESULT" != "dry_run" ]; then
      log "Post-merge diff-integrity check (Bug 1b belt-and-suspenders) ..."
      git_rig fetch origin 2>/dev/null || warn "Post-merge fetch failed; integrity check may use stale refs"

      MERGED_HEAD=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
      INTEGRITY_FAIL=0
      INTEGRITY_MSG=""

      if [ -n "$MERGED_HEAD" ] && [ -n "$BRANCH_SHA" ]; then
        # For each file changed by the branch, compute:
        #   diff_in_branch   = lines added/removed by branch vs its base (pre-branch main)
        #   diff_in_merged   = what actually changed in merged main vs the original pre-merge main SHA
        # If a file was changed by the branch but shows ZERO net change in the
        # merged result vs pre-merge main, the fix was dropped.
        PRE_MERGE_MAIN="${MAIN_HEAD_SHA}"
        BRANCH_CHANGED_FILES=$(git_rig diff --name-only "${PRE_MERGE_MAIN}...origin/$BRANCH" 2>/dev/null || echo "")

        if [ -n "$BRANCH_CHANGED_FILES" ] && [ -n "$PRE_MERGE_MAIN" ]; then
          while IFS= read -r f; do
            [ -z "$f" ] && continue
            # Lines the branch added in this file (vs pre-merge main)
            BRANCH_ADDITIONS=$(git_rig diff "$PRE_MERGE_MAIN" "origin/$BRANCH" -- "$f" 2>/dev/null | grep -c "^+" || echo "0")
            # Lines that actually made it into merged main (vs pre-merge main)
            MERGED_ADDITIONS=$(git_rig diff "$PRE_MERGE_MAIN" "$MERGED_HEAD" -- "$f" 2>/dev/null | grep -c "^+" || echo "0")

            # If branch added lines to a file but the merged result has ZERO
            # additions relative to pre-merge main, the file was completely dropped.
            if [ "$BRANCH_ADDITIONS" -gt 0 ] && [ "$MERGED_ADDITIONS" = "0" ]; then
              INTEGRITY_FAIL=1
              INTEGRITY_MSG="${INTEGRITY_MSG}File $f: branch had $BRANCH_ADDITIONS additions but merged main has 0 (DROPPED).\n"
              log "  INTEGRITY FAIL: $f — branch additions not in merged main"
            fi
          done <<< "$BRANCH_CHANGED_FILES"
        fi
      fi

      if [ "$INTEGRITY_FAIL" = "1" ]; then
        warn "Post-merge integrity FAILED — merge silently dropped branch changes. Reverting."
        # Revert the merge by resetting main back to pre-merge SHA
        REVERT_OK=0
        if [ -n "$MAIN_HEAD_SHA" ] && [ -n "$MERGED_HEAD" ] && [ "$MAIN_HEAD_SHA" != "$MERGED_HEAD" ]; then
          if git_rig push origin "${MAIN_HEAD_SHA}:refs/heads/$DEFAULT_BRANCH" --force-with-lease 2>/dev/null; then
            REVERT_OK=1
            log "  Main reverted to pre-merge SHA $MAIN_HEAD_SHA (merge SHA $MERGED_HEAD removed)"
          else
            err "  Revert push failed. Main may be in corrupted state. Manual intervention required."
          fi
        fi

        OVERALL_VERDICT="FAIL"
        REVERT_STATUS=$([ "$REVERT_OK" = "1" ] && echo "REVERTED (main restored to $MAIN_HEAD_SHA)" || echo "REVERT FAILED — manual fix required")
        FAIL_REASONS="Post-merge integrity check failed: merge silently dropped branch changes.
Files with dropped changes:
$(echo -e "$INTEGRITY_MSG")
Revert status: $REVERT_STATUS
Author must inspect conflict resolution and rebase + resubmit."

        # Comment on the source bead explaining what happened
        if [ -n "$BEAD_ID" ]; then
          bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:integrity-fail" -q 2>/dev/null || true
          bd -C "$BEAD_CITY" comment "$BEAD_ID" "GATE INTEGRITY FAIL: the merge of branch $BRANCH silently dropped your changes (conflict resolved to main's side).
$(echo -e "$INTEGRITY_MSG")
Revert: $REVERT_STATUS
Action required: rebase $BRANCH onto current main, resolve conflicts explicitly, and re-submit via /gate-done." 2>/dev/null || true
        fi

        # wa-uthi: TERMINAL FAIL (merge reverted, definitive) — this push is KEPT.
        notify -t "Quality Gate INTEGRITY FAIL" -p 4 "Branch $BRANCH merge dropped changes — reverted. Author: $AUTHOR" 2>/dev/null || true
        log "Post-merge integrity FAILED: $INTEGRITY_MSG — merge reverted ($REVERT_STATUS)"
      else
        log "Post-merge integrity check PASSED — branch changes present in merged main."
      fi
    fi
  fi

  if [ "$OVERALL_VERDICT" = "PASS" ]; then
    # Update markers and beads for success
    set_gate_status "$MARKER_ID" "passed"
    # ga-jhyu: CLOSE the marker at terminal (passed) so it is reaped, not left
    # OPEN forever. Safe — no open-marker consumer scans gate-status:passed
    # (gate-health-monitor.py only scans gate-status:error). Idempotent.
    bd -C "$GC_CITY" close "$MARKER_ID" -r "Gate marker terminal: PASSED (branch $BRANCH merged sha=$MERGE_SHA). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true

    if [ "$GATE_RUN_ID" != "unknown" ]; then
      set_gate_status "$GATE_RUN_ID" "passed"
      bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate PASSED. Branch $BRANCH merged to $DEFAULT_BRANCH. SHA=$MERGE_SHA. Tier=$TIER. Reviewers=$REQUIRED_REVIEWERS. Elapsed=${ELAPSED_S}s. mode=${MERGE_RESULT}." 2>/dev/null || true
      # ga-jhyu: CLOSE the gate-run at terminal so wisp-compact reaps it.
      bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "gate-run terminal: PASSED (branch $BRANCH sha=$MERGE_SHA). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true
    fi

    # ── ga-esbg: DRIVE THE SOURCE BEAD TO ITS TERMINAL/HANDOFF STATE ──────────
    # A gate PASS+merge MUST NOT leave the source bead in_progress with the live
    # builder still assigned. The legacy PASS path only added gate:passed + a
    # comment, so the bead stayed in_progress with a live assignee: the pool
    # crash-recovery selector (bd list --status in_progress --assignee <builder>)
    # kept RE-SPAWNING the worker, and the Pilot's Tier-1 selectors kept
    # re-picking open bugs/tech-debt — a wasteful re-spawn loop (wa-krzm).
    # Mirror the already-merged short-circuit: drive the bead all the way to its
    # terminal state — CLOSE bugs/tasks; HAND OFF stories to delivery.
    if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
      # gate:passed is BOTH the success label AND story-delivery's pickup signal
      # (story-delivery selects story:approved + gate:passed, excluding story:done).
      bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "Quality gate PASSED. Branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA) via autonomous dispatcher (gate_run=$GATE_RUN_ID)." 2>/dev/null || true

      # Read the source bead state authoritatively (labels + live assignee).
      SRC_JSON=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      SRC_LABELS=$(printf '%s' "$SRC_JSON" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")
      BUILDER_ASSIGNEE=$(printf '%s' "$SRC_JSON" | jq -r '.assignee // ""' 2>/dev/null || echo "")
      IS_STORY=0
      if printf '%s' "$SRC_LABELS" | grep -q "story:approved"; then IS_STORY=1; fi

      # (1) Clear the live builder assignee on EVERY source bead. This is what
      #     removes it from the pool in_progress crash-recovery selector
      #     (--assignee <builder>) and from the Pilot's assigned-bead exclusion,
      #     breaking the re-spawn loop even if the close/handoff below fails.
      if [ -n "$BUILDER_ASSIGNEE" ]; then
        bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null \
          || warn "Could not clear builder assignee on source bead $BEAD_ID"
      fi

      # (2) Terminal vs handoff, decided by the canonical story marker
      #     (label story:approved — the type field is null for stories in bd;
      #     see story-delivery.sh / pilot-dispatcher.sh).
      if [ "$IS_STORY" = "1" ]; then
        # STORY → hand off to story-delivery (deploy + prod-test → story:done).
        # Leave it OPEN: delivery needs an open story:approved + gate:passed bead.
        # Pool re-spawn is already closed (assignee cleared above).
        # ga-3h8l: strip story:in-flight NOW (at merge). The lane slot MUST free
        # at merge — delivery may lag/fail, permanently eating a lane slot if we
        # wait. The Pilot's Tier-2 selector excludes gate:passed (see
        # pilot-dispatcher.sh), so stripping in-flight does NOT re-expose the
        # bead to re-dispatch.
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true
        log "Source story $BEAD_ID handed off to delivery (gate:passed set; story:in-flight cleared; builder assignee cleared)."
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate PASS handoff (ga-3h8l fix): builder assignee cleared; story:in-flight stripped (lane slot freed at merge); story:approved + gate:passed in place. story-delivery will deploy + prod-test, then mark story:done." 2>/dev/null || true
      else
        # BUG/TASK → close it. bd list defaults to OPEN-only, so closing removes
        # the bead from EVERY open-work selector (Pilot Tier-1 bug & tech-debt),
        # and — combined with the assignee clear — from the pool crash-recovery
        # query. Closing is the durable fix for non-story source beads.
        log "Closing source bug/task $BEAD_ID (gate PASS + merged sha=$MERGE_SHA)."
        bd -C "$BEAD_CITY" close "$BEAD_ID" \
          -r "Quality gate PASSED — branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA, gate_run=$GATE_RUN_ID). Closed by autonomous dispatcher (ga-esbg)." \
          2>/dev/null || warn "Could not close source bead $BEAD_ID"
      fi

      # (3) POST-MERGE VERIFICATION (ga-esbg): assert the source bead no longer
      #     appears in any re-spawn / re-pick selector the dispatcher knows about.
      #     If it does, a live loop vector remains — comment + escalate (never
      #     silently leave it).
      RESPAWN_HITS=""
      _still_listed() {  # 0 (true) iff $BEAD_ID is present in `bd list --json <args>`
        bd -C "$BEAD_CITY" list --json "$@" 2>/dev/null \
          | jq -e --arg id "$BEAD_ID" 'any(.[]?; .id == $id)' >/dev/null 2>&1
      }
      # a) Pool in_progress crash-recovery (applies to ALL beads — the core loop).
      if [ -n "$BUILDER_ASSIGNEE" ]; then
        if _still_listed --status in_progress --assignee "$BUILDER_ASSIGNEE"; then
          RESPAWN_HITS="$RESPAWN_HITS pool:in_progress+assignee=$BUILDER_ASSIGNEE"
        fi
      fi
      # b/c) Pilot Tier-1 open-bug / open-tech-debt re-pick. Stories are EXEMPT
      #      from Tier-1 checks (open for delivery; not type:bug / tech-debt).
      if [ "$IS_STORY" != "1" ]; then
        if _still_listed -t bug;        then RESPAWN_HITS="$RESPAWN_HITS pilot:open-bug"; fi
        if _still_listed -l tech-debt;  then RESPAWN_HITS="$RESPAWN_HITS pilot:open-tech-debt"; fi
      fi
      # d) ga-3h8l: story lane-occupancy check. After PASS, story:in-flight must
      #    have been stripped (lane slot freed at merge). If still present, the
      #    slot is permanently leaked — escalate immediately.
      if [ "$IS_STORY" = "1" ]; then
        if _still_listed -l "story:in-flight"; then
          RESPAWN_HITS="$RESPAWN_HITS story:in-flight-leaked"
        fi
      fi

      if [ -n "$RESPAWN_HITS" ]; then
        warn "POST-MERGE re-spawn vector STILL PRESENT for $BEAD_ID:$RESPAWN_HITS"
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "WARNING (ga-esbg post-merge verify): source bead still appears in open-work selector(s) after gate PASS+merge:$RESPAWN_HITS. This is a re-spawn/re-pick vector — the terminal/handoff transition did not fully take." 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate post-merge: $BEAD_ID still re-pickable after PASS+merge" \
          -m "$(printf 'Source bead %s PASSED the quality gate and merged (branch %s, sha %s, gate_run %s) but still appears in open-work selector(s):%s\n\nThis leaves a re-spawn / re-pick vector (ga-esbg). The dispatcher could not drive it to terminal/handoff state — investigate (close failed? assignee clear failed? unexpected labels?).' \
            "$BEAD_ID" "$BRANCH" "$MERGE_SHA" "$GATE_RUN_ID" "$RESPAWN_HITS")" \
          2>/dev/null || warn "Could not mail Mayor post-merge re-spawn escalation for $BEAD_ID"
        notify -t "Gate post-merge vector" -p 3 "$BEAD_ID still re-pickable after PASS+merge:$RESPAWN_HITS" 2>/dev/null || true
      else
        log "Post-merge verify OK (ga-esbg): $BEAD_ID absent from all re-spawn/re-pick selectors."
      fi
    fi

    # wa-uthi: TERMINAL SUCCESS (merged to prod) — this push is KEPT.
    # wa-wzvg: differentiate the merge push for Pilot-origin stories. The Pilot
    # sets a durable "pilot:dispatched" label when it autonomously pulls a story
    # (see pilot-dispatcher.sh). If present, use a distinct prefix/emoji so Athos
    # can tell an autonomous Pilot merge apart from a human/Mayor-dispatched one.
    PILOT_ORIGIN=0
    if [ -n "$BEAD_ID" ]; then
      BEAD_LABELS_NOW=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
      if echo "$BEAD_LABELS_NOW" | grep -q "pilot:dispatched"; then
        PILOT_ORIGIN=1
      fi
    fi
    if [ "$PILOT_ORIGIN" = "1" ]; then
      notify -t "🤖 Pilot Gate PASSED" -p 2 "🤖 [Pilot] Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s (autonomous pickup)" 2>/dev/null || true
      log "Gate PASSED (origin=Pilot): branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
    else
      notify -t "Quality Gate PASSED" -p 2 "Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
      log "Gate PASSED: branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
    fi
    supersede_sibling_runs "$MARKER_ID" "$BRANCH" "$BEAD_ID"
  fi

else
  # ── FAIL path ─────────────────────────────────────────────────────────────
  log "Gate FAILED: $FAIL_REASONS"

  set_gate_status "$MARKER_ID" "failed"
  # ga-jhyu: CLOSE the marker at terminal (failed) so it is reaped. A FAIL is
  # terminal for THIS gate attempt — re-running /gate-done mints a fresh marker.
  # Safe: no open-marker consumer scans gate-status:failed. Idempotent.
  bd -C "$GC_CITY" close "$MARKER_ID" -r "Gate marker terminal: FAILED (branch $BRANCH). Re-gate mints a new marker. Closed by dispatcher (ga-jhyu)." 2>/dev/null || true

  if [ "$GATE_RUN_ID" != "unknown" ]; then
    set_gate_status "$GATE_RUN_ID" "failed"
    bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate FAILED.
Branch: $BRANCH
Tier: $TIER  Reviewers required: $REQUIRED_REVIEWERS
Elapsed: ${ELAPSED_S}s

Blocking reasons:
$(echo -e "$FAIL_REASONS")" 2>/dev/null || true
    # ga-jhyu: CLOSE the gate-run at terminal so wisp-compact reaps it.
    bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "gate-run terminal: FAILED (branch $BRANCH). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true
  fi

  # Notify the author (not the Mayor) via nudge
  if [ -n "$AUTHOR" ]; then
    gc --city "$GC_CITY" session nudge "$AUTHOR" \
      "QUALITY GATE FAILED for branch $BRANCH. Blocking reasons: $(echo -e "$FAIL_REASONS" | head -3). Gate run: $GATE_RUN_ID. Fix the issues and re-run /gate-done when ready." \
      --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR (session may not exist)"
  fi

  # ── ga-jb4l: SELF-HEALING FAIL LOOP ────────────────────────────────────────
  # A gate FAIL must not strand the source story forever. The legacy FAIL path
  # only touched the EPHEMERAL marker/gate-run beads and an ephemeral author
  # session nudge — no durable feedback reached the SOURCE bead and no actor
  # ever re-picked it (the Pilot's selection hid it: features by story:in-flight,
  # bugs by a stale builder assignee). Here we close that loop:
  #   (a) attach the FAILing reviewer reasons to the SOURCE bead (durable),
  #   (b) transition it to a Pilot-re-dispatchable gate:needs-fix state, and
  #   (c) cap auto-retry at N=3, escalating to a human (Mayor) exactly once.
  # FAIL_REASONS is already populated upstream (and, post-ga-kf0v, carries the
  # real reviewer .text reasons), so the feedback we attach is substantive.
  if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
    GATE_FIX_CAP=3

    # Read the source bead's current labels (story beads live in the HQ/city DB).
    SRC_LABELS=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
      2>/dev/null || echo "")

    # Current fix-attempt count from label gate:fix-attempt:N (default 0). Take
    # the MAX in case multiple counter labels ever coexist.
    PREV_ATTEMPT=$(printf '%s' "$SRC_LABELS" | tr ' ' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
    [ -z "$PREV_ATTEMPT" ] && PREV_ATTEMPT=0

    # (a) ATTACH FEEDBACK TO THE SOURCE BEAD — durable, machine-readable marker
    #     (prefix "GATE-FEEDBACK") so the Pilot can surface it to the re-dispatched
    #     builder verbatim.
    bd -C "$BEAD_CITY" comment "$BEAD_ID" "$(printf 'GATE-FEEDBACK (gate_run=%s branch=%s): quality gate FAILED. Fix THESE specific blocking issues, then run /gate-done to re-gate.\n\n%s' \
      "$GATE_RUN_ID" "$BRANCH" "$(echo -e "$FAIL_REASONS")")" \
      2>/dev/null || warn "Could not attach gate feedback to source bead $BEAD_ID"
    bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:failed" -q 2>/dev/null || true

    if [ "$PREV_ATTEMPT" -ge "$GATE_FIX_CAP" ]; then
      # (c) RETRY CAP REACHED — stop auto-retry, escalate to the Mayor ONCE.
      log "Gate fix-attempt cap reached for $BEAD_ID (prev=$PREV_ATTEMPT >= $GATE_FIX_CAP). Escalating; no further auto-retry."
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:needs-fix"   -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate auto-fix cap ($GATE_FIX_CAP attempts) exhausted — labeled gate:needs-human. The machine could not resolve this after $GATE_FIX_CAP fix cycles; the Pilot will NOT re-dispatch it. Human/Mayor intervention required." 2>/dev/null || true
      # Escalate EXACTLY once: only mail if gate:needs-human was not already set.
      if ! printf '%s' "$SRC_LABELS" | grep -q "gate:needs-human"; then
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate needs-human: $BEAD_ID exhausted $GATE_FIX_CAP fix attempts" \
          -m "$(printf 'Source bead %s failed the quality gate %s times. Auto-retry is now DISABLED (label gate:needs-human); the Pilot will not re-dispatch it.\n\nBranch: %s\nRig: %s\nGate run: %s\n\nLast blocking reasons:\n%s\n\nA human or the Mayor must intervene.' \
            "$BEAD_ID" "$((GATE_FIX_CAP + 1))" "$BRANCH" "$RIG" "$GATE_RUN_ID" "$(echo -e "$FAIL_REASONS")")" \
          2>/dev/null || warn "Could not mail Mayor escalation for $BEAD_ID"
        notify -t "Gate needs-human" -p 4 "$BEAD_ID exhausted $GATE_FIX_CAP gate fix attempts — Mayor escalated" 2>/dev/null || true
      fi
      # ga-5w0hr: a needs-human bead has NO active worker — the gate just gave up
      # auto-retry. Mirror the needs-fix-branch cleanup so the bead is honestly
      # represented as "awaiting human" rather than masquerading as in-flight.
      # gate:needs-human (which the Pilot EXCLUDES in every candidate query —
      # pilot-dispatcher.sh) remains the re-dispatch block; this only strips the
      # contradictory story:in-flight / pilot:* claim + stale builder assignee
      # left over from the failed dispatch, which otherwise stranded the bead
      # looking forever in-flight with no worker (ga-jhyu: 21h SEM WORKER after
      # 3× FAIL). Re-dispatch policy is unchanged — needs-human still requires
      # Human/Mayor intervention to clear.
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null || true
    else
      # (b) TRANSITION TO A PILOT-RE-DISPATCHABLE needs-fix STATE.
      NEW_ATTEMPT=$((PREV_ATTEMPT + 1))
      log "Marking $BEAD_ID gate:needs-fix (attempt $NEW_ATTEMPT/$GATE_FIX_CAP) for autonomous Pilot re-dispatch."
      # Bump the attempt counter (drop any stale counters first).
      for OLD in $(printf '%s' "$SRC_LABELS" | tr ' ' '\n' | grep '^gate:fix-attempt:'); do
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "$OLD" -q 2>/dev/null || true
      done
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:fix-attempt:${NEW_ATTEMPT}" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-fix"                  -q 2>/dev/null || true
      # Remove story:in-flight so the Pilot's feature-exclusion no longer hides it.
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"  -q 2>/dev/null || true
      # Clear stale Pilot claim labels left over from the failed dispatch.
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true
      # The Pilot's _filter_candidates drops ASSIGNED beads (both Tier-1 bugs and
      # Tier-2 features), so a stale builder assignee makes a failed bead invisible.
      # Clear it so the next sweep can re-pick this bead.
      bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate FAILED (attempt ${NEW_ATTEMPT}/${GATE_FIX_CAP}) — labeled gate:needs-fix; story:in-flight and builder assignee cleared. The Pilot will re-dispatch a builder with the GATE-FEEDBACK above." 2>/dev/null || true
    fi
  fi

  # wa-uthi: TERMINAL FAIL (review rejected, definitive) — this push is KEPT.
  notify -t "Quality Gate FAILED" -p 3 "Branch $BRANCH failed review — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
  supersede_sibling_runs "$MARKER_ID" "$BRANCH" "$BEAD_ID"
fi

# ── Step 11: Log to quality-gate.jsonl ───────────────────────────────────────

mkdir -p "$(dirname "$QG_LOG")"
REASON=""
if [ "$OVERALL_VERDICT" = "PASS" ]; then
  REASON="quorum_${REQUIRED_REVIEWERS}_of_${REQUIRED_REVIEWERS}_independent_sessions"
else
  REASON=$(echo -e "$FAIL_REASONS" | head -1 | tr '\n' ' ' | cut -c1-200)
fi

jq -c -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg branch "$BRANCH" \
  --arg bead "$BEAD_ID" \
  --arg rig "${RIG:-unknown}" \
  --arg tier "$TIER" \
  --arg result "$OVERALL_VERDICT" \
  --arg reason "$REASON" \
  --arg gate_run "$GATE_RUN_ID" \
  --arg marker "$MARKER_ID" \
  --argjson elapsed_s "$ELAPSED_S" \
  --argjson reviewers "$REQUIRED_REVIEWERS" \
  --arg dry_run "$DRY_RUN" \
  '{ts: $ts, event: "dispatcher_complete", branch: $branch, bead: $bead,
    rig: $rig, tier: $tier, result: $result, reason: $reason,
    gate_run: $gate_run, marker: $marker, elapsed_s: $elapsed_s,
    reviewers: $reviewers, dry_run: $dry_run}' \
  >> "$QG_LOG" 2>/dev/null || true

log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$OVERALL_VERDICT elapsed=${ELAPSED_S}s ==="
