#!/usr/bin/env bash
# quality-gate-guard.sh — Autonomous quality gate guard.
#
# Scans for ready-for-gate markers, claims one atomically, spawns three
# INDEPENDENT reviewer sessions via gc session new + gc sling.
#
# Runs every ~2 minutes via launchd (com.gascity.quality-gate-guard.plist).
# Mirror of the peter-wrapper.sh pattern.
#
# Design invariants:
#   - Guard is the ONLY thing that spawns reviewers. Workers never spawn them.
#   - At most ONE runner per marker (claim via label swap + TTL recovery).
#   - Markers are durable beads — survive worker session death.
#   - Author-exclusion is FAIL-SAFE: author derived from bead DB, not marker
#     self-declaration. If author cannot be resolved authoritatively, DEFER.
#   - Three INDEPENDENT reviewer sessions spawned for CODE tier; each sees
#     only the diff and no shared context from the others.
#   - Claim is re-verified before dispatch to prevent double-processing.
#   - Stale "claimed" markers older than TTL are released back to "ready".

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/quality-gate-guard.log"
QG_LOG="$GC_CITY/.gc/quality-gate.jsonl"

# ── Constants ─────────────────────────────────────────────────────────────────
CLAIM_TTL_MINUTES=30
DISPATCHING_TTL_MINUTES=30
GATE_RUN_TTL_MINUTES=90
MAX_RECLAIMS=3
# ga-o57gn: a gate-run legitimately stays gate-status:running only while its
# owning dispatcher process polls verdicts — capped at VERDICT_TIMEOUT_MINUTES
# (dispatcher default 45). Past that, a still-running gate-run with no live
# reviewer is a zombie (dispatcher died/OOM/credit-limited). Kept in sync with
# the dispatcher's VERDICT_TIMEOUT_MINUTES default so the dead-reviewer sweep
# fires right after a real run would have driven itself terminal.
GATE_VERDICT_TIMEOUT_MINUTES="${VERDICT_TIMEOUT_MINUTES:-45}"
# Margin past verdict-timeout before the dead-reviewer sweep fires. The
# dispatcher closes reviewer sessions (Step 9) BEFORE it stamps the gate-run
# terminal (post-merge), so a run whose verdicts land NEAR the timeout has a
# brief window with reviewers closed but the bead still running. The margin
# keeps the sweep clear of that window — a live run is terminal well before
# (verdict-timeout + margin), so only genuinely abandoned runs are caught.
GATE_DEAD_REVIEWER_MARGIN_MINUTES="${GATE_DEAD_REVIEWER_MARGIN_MINUTES:-10}"
GATE_ZOMBIE_AGE_MINUTES=$(( GATE_VERDICT_TIMEOUT_MINUTES + GATE_DEAD_REVIEWER_MARGIN_MINUTES ))
# ga-jfo7: a gate-run with ZERO verdict beads never had a dispatcher-spawned
# reviewer attached to IT — verdict beads are keyed to the DISPATCHER's own
# separately-created gate-run id (Step 6/7), never to the guard's claim-time
# tracking bead. So this bead is either (a) the guard's own tracking bead with
# its companion marker still healthily queued/claimed/dispatching, or (b) a
# dispatcher run that died before ever reaching Step 7. In BOTH cases there is
# NO real review in flight to wait on, so GATE_ZOMBIE_AGE_MINUTES (~55m,
# calibrated for a genuine review that legitimately runs up to verdict-timeout)
# is the wrong gate — it wastes ~55m before this bead is even looked at, then
# closes it with a "no live reviewer — dispatcher abandoned it" message that is
# actively misleading when nothing was ever dispatched (e.g. Dolt-hot headroom
# defer, ga-cw4pm — the marker is correctly still queued the whole time).
GATE_ZERO_VERDICT_GRACE_MINUTES="${GATE_ZERO_VERDICT_GRACE_MINUTES:-15}"

# ── Pure decision functions (loaded in GATE_GUARD_LIB_ONLY=1 mode by tests/dispatcher) ──

# age_minutes_of <ts_Z> <now_epoch>
# Returns age of a UTC bead timestamp in whole minutes.
# Uses date -j -u -f (macOS BSD, UTC) to avoid the TZ-offset bug where local-time
# parse made every age negative on UTC-offset hosts.
age_minutes_of() {
  local ts="$1" now_epoch="${2:-$(date +%s)}"
  [ -z "$ts" ] && { echo "0"; return; }
  local ts_epoch
  ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%Z*}" "+%s" 2>/dev/null \
    || date -d "$ts" +%s 2>/dev/null || echo "0")
  echo $(( (now_epoch - ts_epoch) / 60 ))
}

# parse_marker_id <description_text>
# Canonical extractor for the marker_id: field in gate-run bead descriptions.
# Handles space and tab separators, strips trailing whitespace.
# Both the guard and dispatcher converge on this function (DRY: ga-b92q).
parse_marker_id() {
  local desc="$1"
  [ -z "$desc" ] && { echo ""; return; }
  local line
  line=$(printf '%s\n' "$desc" | grep -E "^marker_id:" | head -1 || true)
  [ -z "$line" ] && { echo ""; return; }
  printf '%s' "$line" | sed 's/^marker_id:[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# reconcile_marker_action <status> <age_min> <ttl_min> <reclaim_count> <max_reclaims> \
#                          [has_live_companion_run: 0|1]
# Pure decision: what to do with a marker stuck in a transient state.
# Returns: skip | requeue:queued | requeue:ready | error
#
# has_live_companion_run (ga-cgynn): 1 iff a currently-running (non-terminal)
# gate-run bead's marker_id: back-reference points at THIS marker. A
# dispatcher yield-bounce ("live sibling gate-run already running for this
# branch" — dispatching flipped straight back toward queued) is a label-only
# change, which does NOT bump the marker's updated_at. So age_min alone
# cannot tell "just touched, real work is in flight elsewhere" apart from
# "genuinely abandoned an hour ago" — every subsequent sweep miscounts the
# bounce as a fresh stuck-reclaim event, exhausts MAX_RECLAIMS, and forces
# gate-status:error on a marker whose review is healthy (which then makes
# Vector B kill the still-live gate-run as an "orphan"). A live companion run
# is decisive counter-evidence: never reclaim-count or error a marker whose
# own gate-run is actively running, no matter how stale updated_at looks.
# Defaults to 0 so pre-existing 5-arg callers are unaffected.
reconcile_marker_action() {
  local status="$1" age_min="$2" ttl_min="$3" count="$4" max="$5"
  local has_live_companion_run="${6:-0}"
  case "$status" in
    dispatching|claimed) ;;
    *) echo "skip"; return ;;
  esac
  [ "$has_live_companion_run" = "1" ] && { echo "skip"; return; }
  [ "$age_min" -le "$ttl_min" ] && { echo "skip"; return; }
  [ "$count" -ge "$max" ]       && { echo "error"; return; }
  case "$status" in
    dispatching) echo "requeue:queued" ;;
    claimed)     echo "requeue:ready"  ;;
  esac
}

# reconcile_gaterun_action <age_min> <ttl_min> <marker_active: 0|1> \
#                          [verdict_timeout_min] [reviewers_alive: 0|1]
# Pure decision: what to do with a gate-run bead stuck in gate-status:running.
# Returns: skip | supersede:marker | supersede:dead-reviewers | abort:age
#
# Priority (most-specific / safest first):
#   1. marker terminal/gone (marker_active=0) → supersede:marker     [ga-tmug]
#   2. age > verdict_timeout AND reviewers_alive=0 → supersede:dead-reviewers
#      [ga-o57gn] The owning dispatcher caps a real run at verdict_timeout, so a
#      run still RUNNING past that with no live reviewer is abandoned. Requiring
#      BOTH conditions means we NEVER kill a live run: a live dispatcher reaches
#      terminal by verdict_timeout, and the reviewer-liveness check is the
#      corroborating signal the bug (ga-o57gn) asked for.
#   3. age > ttl (90m hard cap) → abort:age                          [ga-tmug]
#   4. else → skip (in-flight, untouched)
#
# Back-compat: callers may omit the last two args. Defaults (verdict_timeout
# effectively infinite, reviewers_alive=1) make rule 2 inert, so a 3-arg call
# behaves EXACTLY as the pre-ga-o57gn function did.
reconcile_gaterun_action() {
  local age_min="$1" ttl_min="$2" marker_active="$3"
  local verdict_timeout_min="${4:-999999}" reviewers_alive="${5:-1}"
  [ "$marker_active" = "0" ] && { echo "supersede:marker"; return; }
  if [ "$reviewers_alive" = "0" ] && [ "$age_min" -gt "$verdict_timeout_min" ]; then
    echo "supersede:dead-reviewers"; return
  fi
  [ "$age_min" -le "$ttl_min" ] && { echo "skip"; return; }
  echo "abort:age"
}

# reconcile_zero_verdict_run_action <age_min> <grace_min> <marker_status>
# Pure decision (ga-jfo7): what to do with a gate-status:running gate-run that
# has ZERO verdict beads — it never had a dispatcher-spawned reviewer attached
# to ITS id (see GATE_ZERO_VERDICT_GRACE_MINUTES above for why). Only called
# when the companion marker is still active (queued/claimed/dispatching) — a
# terminal/gone marker is already handled by reconcile_gaterun_action's
# higher-priority supersede:marker rule.
#
# CONTRACT (gate-feedback, ga-jfo7 attempt 1): age_min MUST be the MARKER's own
# time-in-current-state (its updated_at — mirrors Vector A's T_AGE for the same
# claimed/dispatching states), NEVER the guard's claim-time gate-run tracking
# bead's age. The tracking bead is stamped once at Step 7 (marker enters
# gate-status:queued) and never touched again; markers routinely sit queued for
# hours behind the backlog, so that age inherits the FULL backlog wait and
# blows past grace_min before a live dispatcher has done anything — firing
# supersede:requeue-marker against an actively-processing dispatch. Returns:
#
#   skip                       — younger than the grace window; a brand-new
#                                 claim/dispatch handoff needs a moment to land
#   supersede:still-queued     — marker is STILL gate-status:queued: nothing is
#                                 stuck, the dispatcher simply hasn't reached it
#                                 yet (backlog or Dolt-hot headroom defer,
#                                 ga-cw4pm) — close this orphan bookkeeping bead
#                                 quietly, the marker needs no correction
#   supersede:requeue-marker   — marker is claimed/dispatching: something WAS
#                                 actively working it and died before creating
#                                 any verdict bead (dispatcher crashed between
#                                 claiming the marker and its own Step 6/7).
#                                 Genuinely stuck — close the run AND re-queue
#                                 the marker so a fresh sweep retries it
#   skip                       — unrecognized/empty marker_status: fail-safe,
#                                 never guess
reconcile_zero_verdict_run_action() {
  local age_min="$1" grace_min="$2" marker_status="$3"
  [ "$age_min" -le "$grace_min" ] && { echo "skip"; return; }
  case "$marker_status" in
    queued)              echo "supersede:still-queued" ;;
    claimed|dispatching) echo "supersede:requeue-marker" ;;
    *)                   echo "skip" ;;
  esac
}

# verdict_count_from_query <rc> <stdout> — pure companion to
# verdict_bead_count_for_run (ga-jfo7, gate-feedback attempt 2). Maps a `bd list`
# OUTCOME to a verdict-bead count, or "unknown" when the count cannot be trusted.
# THE POINT: a FAILED query (rc!=0 — Dolt timeout/contention) must NEVER be reported
# as a confirmed 0. Zero verdict beads is the exact signature of a reviewer-AWOL run,
# so a false 0 fires supersede:requeue-marker against a HEALTHY run — and Dolt-hot is
# precisely when the query fails AND when real AWOLs happen, making the conflation
# maximally dangerous. The prior `bd ... || echo "[]"` collapsed every nonzero exit to
# an empty array => length 0. "unknown" is non-numeric on purpose: the caller's
# ''|*[!0-9]* guard converts it to a fail-safe skip. Genuine confirmed-empty
# (rc0 + "[]") still returns "0" so real AWOL recovery keeps working.
verdict_count_from_query() {
  local rc="$1" out="$2" n
  [ "$rc" -ne 0 ] && { echo "unknown"; return; }          # query failed → never a confirmed 0
  n=$(printf '%s\n' "$out" | jq 'length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo "unknown"; return ;; esac # empty/unparseable body → unknown, not 0
  echo "$n"
}

# dedup_gaterun_action <group_count> <is_newest: 0|1>
# Pure decision: enforce ≤1 running gate-run per source-bead/marker (ga-o57gn (c)).
# The guard creates a tracking gate-run at claim time and the dispatcher creates
# its OWN at dispatch time; a re-queued marker (dead-dispatcher recovery) then
# spawns yet another. Multiple gate-runs sharing a marker_id are thus normal
# transiently — but only the NEWEST is the live run; older ones are stale and
# inflate the "GATES RODANDO" count. Keep the newest, supersede the rest.
# A lone run (group_count<=1) is always kept. Returns: keep | supersede:duplicate
dedup_gaterun_action() {
  local group_count="$1" is_newest="$2"
  case "$group_count" in ''|*[!0-9]*) echo "keep"; return ;; esac
  [ "$group_count" -le 1 ] && { echo "keep"; return; }
  [ "$is_newest" = "1" ] && { echo "keep"; return; }
  echo "supersede:duplicate"
}

# ── set_gate_status <bead_id> <new_status> ─────────────────────────────────
# Atomic-effect gate-status transition: leave EXACTLY ONE gate-status:* label on
# the bead. The legacy `label remove <known>; label add <new>` pattern is
# non-atomic and, when the prior status is unknown or already dual, leaks two
# gate-status labels (observed live: done+failed, passed+superseded — ga-jhyu).
# This strips EVERY gate-status:* currently present, then adds the single target.
# I/O helper (not a pure fn) but defined here in the lib region so the selftest
# can source + unit-test it with a mock bd. Kept BYTE-IDENTICAL with the
# dispatcher's copy (drift-guarded by quality-gate-reconcile.selftest.sh).
set_gate_status() {
  local _id="$1" _new="$2" _cur _lbl
  [ -z "$_id" ] && return 0
  _cur=$(bd -C "$GC_CITY" show "$_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[]? | select(startswith("gate-status:"))' 2>/dev/null || true)
  for _lbl in $_cur; do
    [ "$_lbl" = "gate-status:$_new" ] && continue
    bd -C "$GC_CITY" label remove "$_id" "$_lbl" -q 2>/dev/null || true
  done
  bd -C "$GC_CITY" label add "$_id" "gate-status:$_new" -q 2>/dev/null || true
}

# ── notify_park_author <author> <bead_id> <branch> <marker_id> <park_reason> ──
# ga-oo66: Step 5a parks a marker (needs-approval / needs-human) by commenting
# on the marker (closed right after — nobody re-opens it) and the source bead
# (comments don't notify anyone). The author never actually heard about it,
# even though /gate-done promises "you will be mailed when the gate passes or
# fails" — a park is neither, so that promise silently went unkept. Mail (not
# nudge): AUTHOR's session may be long dead by the time this guard sweep runs.
# I/O helper (not pure) but defined here in the lib region so the selftest can
# source + unit-test it with a mock gc/notify — same rationale as
# set_gate_status above.
notify_park_author() {
  local _author="$1" _bead_id="$2" _branch="$3" _marker_id="$4" _park_reason="$5"
  gc --city "$GC_CITY" mail send "$_author" \
    -s "Gate marker parked — human action needed ($_bead_id)" \
    -m "$(printf 'Your gate submission for %s (branch %s, marker %s) was PARKED, not reviewed: %s.\n\nNo reviewer was spawned, and none will be until this is resolved.\nTo unblock: resolve the blocking condition on %s (get it product-approved / clear gate:needs-human), then submit a fresh gate marker (/gate-done).' \
      "$_bead_id" "$_branch" "$_marker_id" "$_park_reason" "$_bead_id")" \
    2>/dev/null || warn "could not mail author $_author for parked marker $_marker_id"
  notify -t "Gate needs-human" -p 4 "$_bead_id ($_branch) parked, not reviewed — $_park_reason. Author $_author mailed." 2>/dev/null || true
}

# classify_inflight_gap1 <status> <has_gate_passed> <has_live_assignee> <branch_merged>
# Pure decision for ga-pa36 GAP-1: OPEN story:in-flight bead whose fix branch
# was already merged to origin/main but has no gate:passed label.
# branch_merged: 1=merged, 0=not-merged, anything-else=indeterminate (safe-skip).
# Returns: strip:merged | skip:already-handled | skip:live-builder | skip:not-merged | skip:indeterminate
classify_inflight_gap1() {
  local status="$1" has_gate_passed="$2" has_live_assignee="$3" branch_merged="$4"
  [ "$status" = "closed" ]       && { echo "skip:already-handled"; return; }
  [ "$has_gate_passed" = "1" ]   && { echo "skip:already-handled"; return; }
  [ "$has_live_assignee" = "1" ] && { echo "skip:live-builder"; return; }
  case "$branch_merged" in
    1) echo "strip:merged" ;;
    0) echo "skip:not-merged" ;;
    *) echo "skip:indeterminate" ;;
  esac
}

# guard_content_merged <main_ref> <branch_ref> — ga-0ndi: mirrors quality-gate-
# dispatcher.sh's rig_content_merged() (ga-01yq) for GAP-1's orphan reconciler.
# SHA-ancestry is FALSE BY CONSTRUCTION after a rebase-merge (the gate's own
# auto-rebase, or any manual rebase, replays commits under NEW shas) — a
# fully-merged branch never becomes an ancestor again, so the bare
# `merge-base --is-ancestor` at the GAP-1 call site (below) would strand its
# story:in-flight label FOREVER instead of stripping it, permanently leaking
# the lane slot — the same class of bug ga-01yq fixed in the dispatcher's Step
# 4b, just manifesting here as silent lane starvation instead of a
# needs-rebase bounce.
#
# rc0 iff every commit reachable from <branch_ref> but not <main_ref> already
# has its patch present on <main_ref> (git matches rebased/squashed/
# re-committed content by patch-id, not sha) — i.e. the branch's content is
# fully merged regardless of sha lineage.
#
# FAIL-CLOSED: any non-"0"/empty/error count → rc1 (treated as NOT merged), so
# the caller keeps the existing safe skip:not-merged path on any doubt.
guard_content_merged() {
  local main_ref="$1" branch_ref="$2" n
  n=$(git -C "$GC_CITY" rev-list --count --cherry-pick --right-only "${main_ref}...${branch_ref}" 2>/dev/null || echo ERR)
  [ "$n" = "0" ]
}

# classify_parent_gap2 <has_pilot_dispatched> <has_live_assignee> <sling_found> <sling_needs_fix> <sling_closed>
# Pure decision for ga-pa36 GAP-2: parent story/bug retains story:in-flight after
# the gate ran on a sling/work bead (Pilot-dispatched path) and that bead is terminal.
# sling_needs_fix: 1 if sling bead has gate:needs-fix or gate:needs-human (gate FAILED).
# sling_closed:    1 if sling bead is closed (gate PASSED, work done).
# Returns: free:fail-stranded | free:pass-stranded | skip:not-dispatched | skip:live-assignee | skip:no-sling | skip:active-sling
classify_parent_gap2() {
  local has_pilot_dispatched="$1" has_live_assignee="$2" sling_found="$3" sling_needs_fix="$4" sling_closed="$5"
  [ "$has_pilot_dispatched" != "1" ] && { echo "skip:not-dispatched"; return; }
  [ "$has_live_assignee" = "1" ]     && { echo "skip:live-assignee"; return; }
  [ "$sling_found" != "1" ]          && { echo "skip:no-sling"; return; }
  [ "$sling_needs_fix" = "1" ]       && { echo "free:fail-stranded"; return; }
  [ "$sling_closed" = "1" ]          && { echo "free:pass-stranded"; return; }
  echo "skip:active-sling"
}

# check_source_bead_park <space_sep_labels>
# Pure decision: should the gate park a marker because the source-bead is in a
# state that must not enter the review cycle?
#   story:needs-approval — bead was never product-approved; the gate would spawn
#     reviewers who reject it, the crew re-submits, and the cycle repeats forever.
#   gate:needs-human / gate:needs-human:* — bead is circuit-broken and requires
#     human intervention; the same re-submit loop applies.
#   gate:needs-fix ALONE is NOT a park reason — it is the normal fix-iterate path
#     (crew fixed, re-submitted; gate should review it).
# The check is FAIL-OPEN: if labels are empty/unrecognized, returns "ok" so a
# network hiccup never blocks a legitimate story:approved submission.
# Returns: ok | park:needs-approval | park:needs-human
check_source_bead_park() {
  local labels="$1" lbl
  for lbl in $labels; do
    case "$lbl" in
      story:needs-approval)         echo "park:needs-approval"; return ;;
      gate:needs-human|gate:needs-human:*) echo "park:needs-human"; return ;;
    esac
  done
  echo "ok"
}

# resolve_author_agent_alias <author> — ga-pyzo. Best-effort maps a
# session_name-form AUTHOR (<agent>-<sessionid>, e.g. batista-wa-gawispiwq9sj)
# to its durable agent alias (e.g. batista-wa) via a live `gc session list`
# lookup, for markers whose specific submitting session may later recycle
# (restart/crash/reap) — leaving AUTHOR permanently unmatchable even though
# the durable agent is up under a NEW session id (author_is_alive() then reads
# a live agent as dead FOREVER; evidence: 3 parked markers, 2026-07-14, see
# bug). Echoes the alias if AUTHOR resolves to a live session AND the alias
# differs from AUTHOR itself (no new info otherwise); echoes empty if
# unresolvable or for pool/ephemeral builders (SCOPE GUARD below). Never
# fatal — a lookup failure yields empty, same as "no fallback available".
#
# SCOPE GUARD: pool/ephemeral builders (dog-pool, wa-worker, ps-worker) churn
# through a constant rotation of UNRELATED occupants under the SAME template
# alias — "gastown.dog-3 is alive" seconds later is almost always a DIFFERENT
# dog with zero context on this branch, not the same worker resuming. Unlike a
# named crew alias (batista-wa, peter-wa — one durable identity, one owner,
# indefinitely), resolving an alias fallback for these would let a later
# liveness check misdirect a rebase-conflict bounce+nudge to a stranger dog
# instead of correctly falling through to the existing dead-author
# auto-retry/circuit-break path. Mirrors quality-gate-dispatcher.sh's
# gate_fail_assignee_action deny-list (kept in sync by inspection — both
# lists are short and rarely change).
resolve_author_agent_alias() {
  local author="${1:-}"
  case "$author" in
    ''|mayor|gastown.dog|gastown.dog-*|dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*)
      return 0 ;;  # pool/ephemeral or empty — no agent fallback, echo nothing
  esac
  local agent
  agent=$(gc --city "$GC_CITY" session list --json 2>/dev/null \
    | jq -r --arg a "$author" \
        '(if type=="array" then . else (.sessions // []) end)[]
         | select(.closed != true)
         | select((.session_name==$a) or (.id==$a) or (.name==$a) or (.alias==$a) or (.agent_name==$a))
         | (.alias // .name // .agent_name // empty)' 2>/dev/null | head -1 || true)
  [ "$agent" = "$author" ] && agent=""
  [ "$agent" = "null" ] && agent=""
  printf '%s' "$agent"
}

# session_matches_author <author> <sessions_json>
# Pure predicate — canonical liveness check shared by GAP-1, GAP-2, and (via a
# thin wrapper) quality-gate-dispatcher.sh's author_is_alive(). Echoes 1 iff
# <author> matches the session_name, name, alias, id, or agent_name of some
# non-closed session in <sessions_json>; 0 otherwise (empty author, no match,
# or unparseable JSON). <sessions_json> may be a bare array or the
# {"sessions":[...]} shape (both `gc session list --json` and its cache shim
# emit the latter).
#
# ga-bnu1: GAP-1/GAP-2 used to run their OWN inline predicate here — an
# any(...) test comparing just two fields (id, name) against the array
# itself rather than iterating each element — which is doubly broken: (1) a
# generator of "." over an array binds "." in the condition to the ARRAY
# itself (not each element — iterating needs ".[]" instead), so it throws
# "Cannot index array with string" on every non-empty session list,
# silently falling back to a 3-way "uncertain" string the caller treats as
# alive; (2) even fixed to iterate, checking only .id/.name misses the form
# bd's `assignee` field actually stores — .session_name (e.g. the named-crew
# form `gastown__mayor`, or the pool form `<agent>-<sessionid>`) — the exact
# class of bug ga-ipf6 already fixed once for author_is_alive()'s two
# dispatcher.sh call sites. A live named-crew author whose .name
# ("gastown.mayor") differs from .session_name ("gastown__mayor") reads as
# dead under the old predicate. Single source of truth now for all three call
# sites so they cannot diverge again.
session_matches_author() {
  local author="${1:-}" sessions_json="${2:-}"
  [ -z "$author" ] && { echo 0; return 0; }
  if printf '%s' "$sessions_json" | jq -e --arg a "$author" \
       '[(if type=="array" then . else (.sessions // []) end)[]
         | select(.closed != true)
         | (.session_name, .name, .alias, .id, .agent_name)]
        | map(select(. != null and . != ""))
        | index($a) != null' >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# ── Lib-only mode: source with GATE_GUARD_LIB_ONLY=1 to load pure functions ──
# without running the live guard sweep. Used by tests and by the dispatcher.
if [ -n "${GATE_GUARD_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-guard] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-guard] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-guard] WARN: $*"; }

echo ""
log "=== Guard sweep start ==="

# ── ga-ny4y: surface silent pre-redirect parse failures ──────────────────────
# A bash PARSE error happens before the `exec >> "$LOG" 2>&1` redirect above
# takes effect, so it never reaches this timestamped log — it only lands in
# launchd's untimestamped StandardErrorPath file, where it can sit unnoticed
# for weeks (observed: a 2026-06-23 occurrence was still sitting there,
# undetected, on 2026-07-10). Checkpoint that file's line count each sweep;
# if it grew, a prior invocation wrote to it — warn here (timestamped, in the
# log operators actually watch) instead of relying on someone remembering to
# check a second, separate, untimestamped file.
LAUNCHD_ERR="$GC_CITY/.gc/logs/quality-gate-guard-launchd.err"
ERR_CHECKPOINT="$GC_CITY/.gc/logs/quality-gate-guard-launchd-err.checkpoint"
if [ -f "$LAUNCHD_ERR" ]; then
  CUR_ERR_LINES=$(wc -l < "$LAUNCHD_ERR" 2>/dev/null | tr -d ' ' || echo "")
  PREV_ERR_LINES=$(cat "$ERR_CHECKPOINT" 2>/dev/null || echo "")
  if [ -n "$CUR_ERR_LINES" ] && [ -n "$PREV_ERR_LINES" ] && [ "$CUR_ERR_LINES" != "$PREV_ERR_LINES" ]; then
    TAIL_SNIPPET=$(tail -n 5 "$LAUNCHD_ERR" 2>/dev/null | tr '\n' ' ' || true)
    warn "launchd stderr capture ($LAUNCHD_ERR) changed since last sweep (was $PREV_ERR_LINES lines, now $CUR_ERR_LINES) — a prior invocation likely hit a pre-redirect parse failure (ga-ny4y). Tail: $TAIL_SNIPPET"
  fi
  [ -n "$CUR_ERR_LINES" ] && echo "$CUR_ERR_LINES" > "$ERR_CHECKPOINT" 2>/dev/null || true
fi

# ── Input validation helpers ──────────────────────────────────────────────────

# Validate branch: lowercase alphanumeric, hyphens, underscores, slashes, dots.
# Uppercase is excluded to avoid case-insensitive filesystem collisions.
# Bug 4 fix: '+' and other unsafe chars (as used in "worktree-fix+wa-..." branches)
# are rejected here, producing gate-status:error with a clear diagnostic.
# Dots are allowed (sub-bead branches like feat/ga-qw3p.1-desc) but consecutive
# dots (..) are blocked to prevent remote-tracking ref confusion (origin/main..HEAD).
validate_branch() {
  local val="$1"
  if [[ "$val" =~ ^[a-z0-9/_.-]{1,200}$ ]] && ! [[ "$val" =~ \.\. ]]; then
    return 0
  fi
  return 1
}

# Validate bead ID: e.g. "gt-abc123", "wa-xyz", "ga-qw3p.1" (sub-beads).
validate_bead_id() {
  local val="$1"
  if [[ "$val" =~ ^[a-z]{1,8}-[a-z0-9]{2,16}(\.[0-9]{1,4})?$ ]]; then
    return 0
  fi
  return 1
}

# Validate rig name against the known registered rigs.
validate_rig() {
  local val="$1"
  local known_rigs
  known_rigs=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[].name' 2>/dev/null || echo "")
  if [ -z "$known_rigs" ]; then
    warn "Could not fetch rig list for validation; allowing rig='$val' with caution."
    # Still reject obvious injection attempts
    if [[ "$val" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
      return 0
    fi
    return 1
  fi
  echo "$known_rigs" | grep -qx "$val"
}

# ── Shared prelude: currently-running gate-runs (ga-cgynn) ───────────────────
# Fetched ONCE here — reused unchanged by Vector B below (was previously a
# second, separate bd round-trip in Step 0b) AND by Vector A's companion-
# liveness check right below. Both vectors must see the identical snapshot;
# two separate fetches could observe different states across the gap.
GATE_RUNS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-run \
  -l gate-status:running \
  2>/dev/null || echo "[]")
GATE_RUN_COUNT=$(printf '%s\n' "$GATE_RUNS_JSON" | jq 'length' 2>/dev/null || echo "0")
case "$GATE_RUN_COUNT" in ''|*[!0-9]*) GATE_RUN_COUNT=0 ;; esac

# marker_id: back-references of every currently-running gate-run. Membership
# here is the has_live_companion_run signal reconcile_marker_action needs.
RUNNING_GATERUN_MARKER_IDS=""
if [ "$GATE_RUN_COUNT" -gt 0 ]; then
  for _gi in $(seq 0 $((GATE_RUN_COUNT - 1))); do
    _gr_desc=$(printf '%s\n' "$GATE_RUNS_JSON" | jq -r ".[$_gi].description // \"\"")
    _gr_mid=$(parse_marker_id "$_gr_desc")
    [ -n "$_gr_mid" ] && RUNNING_GATERUN_MARKER_IDS="${RUNNING_GATERUN_MARKER_IDS}${_gr_mid}
"
  done
fi

# ── Step 0: Vector A — unified transient-marker reclaim (dispatching + claimed) ─
# The dispatcher's Step 0a only reclaims gate-status:dispatching when IT runs.
# When the dispatcher CRASHES mid-dispatch, no one reclaims the marker — it
# strands forever (ga-tmug Vector A). Fix: guard now reclaims BOTH transient
# states in ONE authoritative place, with a gate-reclaim-count: thrash cap.

log "Step 0: Vector A reclaim — stuck transient markers (TTL=${CLAIM_TTL_MINUTES}m, MAX_RECLAIMS=${MAX_RECLAIMS})..."

DISP_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker -l gate-status:dispatching \
  2>/dev/null || echo "[]")
CLAIM_JSON_V=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker -l gate-status:claimed \
  2>/dev/null || echo "[]")
TRANSIENT_JSON=$(printf '%s\n%s' "$DISP_JSON" "$CLAIM_JSON_V" \
  | jq -s 'add | unique_by(.id)' 2>/dev/null || echo "[]")
TRANSIENT_COUNT=$(echo "$TRANSIENT_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$TRANSIENT_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)
  for i in $(seq 0 $((TRANSIENT_COUNT - 1))); do
    T=$(echo "$TRANSIENT_JSON" | jq ".[$i]")
    T_ID=$(echo "$T" | jq -r '.id')
    T_UPDATED=$(echo "$T" | jq -r '.updated_at // .created_at // ""')
    T_LABELS=$(echo "$T" | jq -r '(.labels // []) | join(" ")')

    T_STATUS=""
    echo "$T_LABELS" | grep -q "gate-status:dispatching" && T_STATUS="dispatching"
    echo "$T_LABELS" | grep -q "gate-status:claimed"     && T_STATUS="claimed"
    [ -z "$T_STATUS" ] && continue

    T_AGE=$(age_minutes_of "$T_UPDATED" "$NOW_EPOCH")
    T_COUNT=$(echo "$T_LABELS" | tr ' ' '\n' \
      | sed -n 's/^gate-reclaim-count:\([0-9]*\)$/\1/p' | sort -n | tail -1)
    [ -z "$T_COUNT" ] && T_COUNT=0

    HAS_LIVE_COMPANION=0
    if [ -n "$RUNNING_GATERUN_MARKER_IDS" ] \
      && printf '%s\n' "$RUNNING_GATERUN_MARKER_IDS" | grep -qx "$T_ID"; then
      HAS_LIVE_COMPANION=1
    fi

    ACTION=$(reconcile_marker_action "$T_STATUS" "$T_AGE" "$CLAIM_TTL_MINUTES" "$T_COUNT" "$MAX_RECLAIMS" "$HAS_LIVE_COMPANION")
    case "$ACTION" in
      requeue:queued)
        warn "Vector A: requeueing zombie dispatching marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:dispatching" -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed"     -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:queued"      -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:dispatching for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Dispatcher likely crashed. Re-queued for re-processing (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      requeue:ready)
        warn "Vector A: re-readying zombie claimed marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed"     -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:dispatching" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:ready"       -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:claimed for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Guard likely crashed. Re-readied for re-claim (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      error)
        warn "Vector A: exhausted reclaims for $T_ID (count=${T_COUNT} >= MAX_RECLAIMS=${MAX_RECLAIMS})"
        set_gate_status "$T_ID" "error"
        # ga-jhyu: do NOT close on error. gate-health-monitor.py pages a human on
        # OPEN markers stuck in gate-status:error >10min (ga-piscg). Closing here
        # would make that escalation blind. The marker is reaped after a human
        # resolves it (which closes it), not at the error transition.
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker exhausted ${MAX_RECLAIMS} reclaim attempts stuck in gate-status:${T_STATUS}. Marking gate-status:error — human/Mayor intervention required." 2>/dev/null || true
        ;;
      skip)
        if [ "$HAS_LIVE_COMPANION" = "1" ]; then
          log "  Marker $T_ID in $T_STATUS has a live companion gate-run — legitimate yield-bounce, not stuck (ga-cgynn). Skipping."
        else
          log "  Marker $T_ID in $T_STATUS for ${T_AGE}m — within TTL, skipping."
        fi
        ;;
    esac
  done
fi

# ── Step 0b: Vector B — reconcile orphan gate-run:running beads ───────────────
# The guard creates a quality-gate: bead (type:quality-gate-run, gate-status:running)
# at claim time. The dispatcher drives ITS OWN gate-run: bead but NEVER drives the
# guard's bead to terminal — leaving orphans pinned in running after their run
# completed (ga-tmug Vector B, 9 such beads observed).
#
# Fix: use reconcile_gaterun_action keyed on the companion marker's state
# (extracted via parse_marker_id from the gate-run description):
#   - marker terminal/gone → supersede:marker (immediate, no TTL wait)
#   - marker active + age > TTL → abort:age (age fallback preserved)
#   - marker active + within TTL → skip (in-flight, untouched)
#
# Keying on marker_id (not just source-bead) prevents false-positives on
# re-dispatched live runs that share a source bead with an older failed attempt.

log "Step 0b: Vector B reconcile — orphan gate-run:running beads (TTL=${GATE_RUN_TTL_MINUTES}m, zombie-age=${GATE_ZOMBIE_AGE_MINUTES}m=verdict-timeout+margin)..."

# reviewers_alive_for_run <gate_run_id> — I/O helper (ga-o57gn).
# Echo 1 iff at least one of this gate-run's still-OPEN verdict beads is assigned
# to a reviewer session that is present (alive) in SESS_SNAP_JSON, else 0. A
# gate-run still running past verdict-timeout with zero live reviewers is a
# zombie whose dispatcher died. (Live section only — uses bd/gc; never called in
# lib-only mode, so it is intentionally NOT one of the drift-guarded pure fns.)
reviewers_alive_for_run() {
  local gr_id="$1" vbs assignees a present
  [ -z "$gr_id" ] && { echo 0; return; }
  vbs=$(bd -C "$GC_CITY" list --json --all \
    -l type:quality-gate-verdict -l "gate-run:$gr_id" 2>/dev/null || echo "[]")
  # Only OPEN verdict beads matter — a closed verdict means the reviewer finished.
  assignees=$(printf '%s\n' "$vbs" \
    | jq -r '.[]? | select((.status // "") != "closed") | .assignee // empty' \
    2>/dev/null || true)
  [ -z "$assignees" ] && { echo 0; return; }
  for a in $assignees; do
    [ -z "$a" ] && continue
    present=$(printf '%s\n' "$SESS_SNAP_JSON" \
      | jq -r --arg s "$a" 'if type=="array" then . else (.sessions // []) end
          | map(select((.id==$s) or (.session_name==$s) or (.session_id==$s))
                | select((.closed // false) != true)) | length' \
      2>/dev/null || echo 0)
    case "$present" in ''|*[!0-9]*) present=0 ;; esac
    [ "$present" -ge 1 ] && { echo 1; return; }
  done
  echo 0
}

# verdict_bead_count_for_run <gate_run_id> — I/O helper (ga-jfo7).
# Total (open+closed) verdict beads ever created for this gate-run id. 0 means
# no dispatcher-spawned reviewer was ever attached to THIS bead's id (see
# GATE_ZERO_VERDICT_GRACE_MINUTES above). Cheap: same query shape as
# reviewers_alive_for_run, just a bare count — no session-snapshot lookup
# needed to answer "did dispatch even begin for this run".
verdict_bead_count_for_run() {
  local gr_id="$1" vbs rc
  [ -z "$gr_id" ] && { echo 0; return; }
  # Capture bd's exit status WITHOUT masking it (the old `|| echo "[]"` conflated a
  # failed query with 0 verdicts — ga-jfo7 attempt 2). The `if` keeps `set -euo
  # pipefail` from aborting on a nonzero bd exit; verdict_count_from_query then maps
  # rc!=0 to "unknown" so the caller fail-safes instead of superseding a healthy run.
  if vbs=$(bd -C "$GC_CITY" list --json --all \
      -l type:quality-gate-verdict -l "gate-run:$gr_id" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  verdict_count_from_query "$rc" "$vbs"
}

# GATE_RUNS_JSON / GATE_RUN_COUNT: already fetched once in the shared prelude
# above Step 0 (ga-cgynn) — reused here unchanged so Vector A's companion-
# liveness check and Vector B see the identical snapshot instead of two
# separate bd round-trips that could observe different states.

if [ "$GATE_RUN_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)

  # One session snapshot for the whole sweep (reviewer-liveness lookups, ga-o57gn).
  SESS_SNAP_JSON=$(bash "$GC_CITY/scripts/gc-session-list-cached.sh" 2>/dev/null || echo '{}')

  # ── First pass: build the dedup grouping key for every running gate-run. ────
  # ga-o57gn (c): enforce ≤1 running gate-run per marker. Key on marker_id
  # (canonical — matches the anti-false-positive guidance below); fall back to
  # the source-bead label when a description carries no marker_id. created_at is
  # an ISO-8601 'Z' string, so a lexical compare == a chronological compare.
  GR_ID_ARR=(); GR_KEY_ARR=(); GR_CREATED_ARR=()
  for i in $(seq 0 $((GATE_RUN_COUNT - 1))); do
    _gr=$(printf '%s\n' "$GATE_RUNS_JSON" | jq ".[$i]")
    _id=$(printf '%s\n' "$_gr" | jq -r '.id // ""')
    _created=$(printf '%s\n' "$_gr" | jq -r '.created_at // .updated_at // ""')
    _desc=$(printf '%s\n' "$_gr" | jq -r '.description // ""')
    _key=$(parse_marker_id "$_desc")
    if [ -z "$_key" ]; then
      _key=$(printf '%s\n' "$_gr" \
        | jq -r '(.labels // [])[]? | select(startswith("source-bead:"))' 2>/dev/null | head -1 || true)
    fi
    GR_ID_ARR+=("$_id"); GR_KEY_ARR+=("$_key"); GR_CREATED_ARR+=("$_created")
  done

  for i in $(seq 0 $((GATE_RUN_COUNT - 1))); do
    GR=$(printf '%s\n' "$GATE_RUNS_JSON" | jq ".[$i]")
    GR_ID="${GR_ID_ARR[$i]}"
    GR_UPDATED=$(printf '%s\n' "$GR" | jq -r '.updated_at // .created_at // ""')
    GR_DESC=$(printf '%s\n' "$GR" | jq -r '.description // ""')

    GR_AGE=$(age_minutes_of "$GR_UPDATED" "$NOW_EPOCH")

    # ── Dedup decision: does a NEWER running gate-run share this key? ─────────
    # Keep-newest never supersedes the newest run, so a live re-dispatch (always
    # the newest) is safe; only the stale older siblings (guard tracking bead,
    # dead-dispatcher re-queue remnants) are superseded.
    _key="${GR_KEY_ARR[$i]}"
    _group_count=0; _is_newest=1
    if [ -n "$_key" ]; then
      for j in $(seq 0 $((GATE_RUN_COUNT - 1))); do
        [ "${GR_KEY_ARR[$j]}" = "$_key" ] || continue
        _group_count=$((_group_count + 1))
        [ "$j" -eq "$i" ] && continue
        _cj="${GR_CREATED_ARR[$j]}"; _ci="${GR_CREATED_ARR[$i]}"
        if [[ "$_cj" > "$_ci" ]] || { [ "$_cj" = "$_ci" ] && [[ "${GR_ID_ARR[$j]}" > "$GR_ID" ]]; }; then
          _is_newest=0
        fi
      done
    fi
    DEDUP_ACTION=$(dedup_gaterun_action "$_group_count" "$_is_newest")
    if [ "$DEDUP_ACTION" = "supersede:duplicate" ]; then
      warn "Vector B: superseding STALE DUPLICATE gate-run $GR_ID (a newer running run shares key='$_key'; keep-newest dedup, ga-o57gn)"
      set_gate_status "$GR_ID" "superseded"
      bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-o57gn): stale duplicate — a newer running gate-run shares this marker/source-bead. Keep-newest dedup enforces ≤1 running gate-run per source-bead. Self-healed by guard." 2>/dev/null || true
      bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — stale duplicate, newer running run exists. Closed by guard (ga-o57gn)." 2>/dev/null || true
      continue
    fi

    # Determine if the companion marker is still active.
    # parse_marker_id extracts the marker_id: field written by the guard at Step 6.
    COMPANION_MARKER_ID=$(parse_marker_id "$GR_DESC")
    MARKER_ACTIVE=0
    MARKER_AGE="$GR_AGE"   # fallback only — overwritten below whenever the marker itself is readable
    if [ -n "$COMPANION_MARKER_ID" ]; then
      MARKER_JSON=$(bd -C "$GC_CITY" show "$COMPANION_MARKER_ID" --json 2>/dev/null || echo "")
      if [ -n "$MARKER_JSON" ]; then
        MARKER_LABELS=$(printf '%s\n' "$MARKER_JSON" \
          | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
          2>/dev/null || echo "")
        # ga-jfo7 gate-feedback (attempt 1): GR_AGE is the GUARD's own claim-time
        # tracking bead, stamped once at Step 7 the instant the marker first goes
        # gate-status:queued — never touched again for the rest of this run's life.
        # Markers routinely sit queued for hours behind the single-threaded backlog
        # (Step 5b above), so by the time one is actually claimed/dispatched, GR_AGE
        # has usually ALREADY blown past GATE_ZERO_VERDICT_GRACE_MINUTES from queue
        # wait alone — with no dispatcher activity involved. The marker's OWN
        # updated_at is refreshed at each real state transition (claimed at Step
        # ~961, dispatching by the dispatcher) — the same T_AGE signal Vector A
        # already uses for these exact states (Step 0 above) — so it measures time
        # in the CURRENT state instead of time-since-queued.
        MARKER_UPDATED=$(printf '%s\n' "$MARKER_JSON" \
          | jq -r 'if type=="array" then .[0] else . end | .updated_at // .created_at // ""' \
          2>/dev/null || echo "")
        [ -n "$MARKER_UPDATED" ] && MARKER_AGE=$(age_minutes_of "$MARKER_UPDATED" "$NOW_EPOCH")
        printf '%s\n' "$MARKER_LABELS" | grep -qE "gate-status:(queued|claimed|dispatching)" \
          && MARKER_ACTIVE=1 || true
        printf '%s\n' "$MARKER_LABELS" | grep -qE "gate-status:" || MARKER_ACTIVE=1
      fi
    fi

    # ── ga-jfo7: zero-verdict-bead early check ──────────────────────────────
    # Reused below for logging even when this branch doesn't fire the action.
    MARKER_STATUS=$(printf '%s\n' "$MARKER_LABELS" \
      | grep -oE "gate-status:[a-z-]+" | head -1 | sed 's/^gate-status://' || true)
    if [ "$MARKER_ACTIVE" = "1" ]; then
      ZV_TOTAL=$(verdict_bead_count_for_run "$GR_ID")
      case "$ZV_TOTAL" in ''|*[!0-9]*) ZV_TOTAL=1 ;; esac  # unreadable → fail-safe, defer to the existing path below
      if [ "$ZV_TOTAL" = "0" ]; then
        ZV_ACTION=$(reconcile_zero_verdict_run_action "$MARKER_AGE" "$GATE_ZERO_VERDICT_GRACE_MINUTES" "$MARKER_STATUS")
        case "$ZV_ACTION" in
          supersede:still-queued)
            log "  Vector B (ga-jfo7): closing orphan gate-run $GR_ID (marker age=${MARKER_AGE}m, 0 verdict beads, marker $COMPANION_MARKER_ID still queued — healthy backlog/Dolt-hot defer, nothing stuck)."
            set_gate_status "$GR_ID" "superseded"
            bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-jfo7): orphan claim-time tracking bead closed — 0 verdict beads (no reviewer was ever attached to THIS bead's id) and companion marker $COMPANION_MARKER_ID is still healthily queued. Self-healed by guard." 2>/dev/null || true
            bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — 0-verdict orphan tracking bead, marker still queued. Closed by guard (ga-jfo7)." 2>/dev/null || true
            continue
            ;;
          supersede:requeue-marker)
            warn "Vector B (ga-jfo7): gate-run $GR_ID stuck (gate-run age=${GR_AGE}m, marker-state age=${MARKER_AGE}m, 0 verdict beads, marker $COMPANION_MARKER_ID stranded at gate-status:${MARKER_STATUS} — dispatcher died before ever creating its own run). Closing + re-queuing marker."
            set_gate_status "$GR_ID" "superseded"
            bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-jfo7): reviewer-AWOL — 0 verdict beads were ever created and marker was stranded at gate-status:${MARKER_STATUS} (dispatcher died before Step 6/7). Closing this run and re-queuing the marker for a fresh dispatcher attempt. Self-healed by guard." 2>/dev/null || true
            bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — reviewer-AWOL, 0 verdict beads, marker re-queued. Closed by guard (ga-jfo7)." 2>/dev/null || true
            set_gate_status "$COMPANION_MARKER_ID" "queued"
            bd -C "$GC_CITY" comment "$COMPANION_MARKER_ID" "Vector B (ga-jfo7): re-queued — the prior gate-run attempt died with 0 verdict beads ever created (reviewer-AWOL). A fresh dispatcher sweep will retry this branch." 2>/dev/null || true
            continue
            ;;
        esac
      fi
    fi

    # ── Reviewer-liveness (ga-o57gn): computed ONLY when it can change the
    # outcome — the marker still looks active AND the run is already past
    # verdict-timeout. This bounds the extra bd/gc round-trip to genuine
    # zombie candidates and never touches young/in-flight runs. (Only reached
    # here when the run has >=1 verdict bead — the ga-jfo7 block above already
    # handled and `continue`d past the 0-verdict-bead case.)
    REVIEWERS_ALIVE=1
    if [ "$MARKER_ACTIVE" = "1" ] && [ "$GR_AGE" -gt "$GATE_ZOMBIE_AGE_MINUTES" ]; then
      REVIEWERS_ALIVE=$(reviewers_alive_for_run "$GR_ID")
    fi

    ACTION=$(reconcile_gaterun_action "$GR_AGE" "$GATE_RUN_TTL_MINUTES" "$MARKER_ACTIVE" "$GATE_ZOMBIE_AGE_MINUTES" "$REVIEWERS_ALIVE")
    case "$ACTION" in
      supersede:marker)
        warn "Vector B: superseding orphan gate-run $GR_ID (age=${GR_AGE}m, marker $COMPANION_MARKER_ID is terminal/gone)"
        set_gate_status "$GR_ID" "superseded"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): orphan gate-run superseded — companion marker $COMPANION_MARKER_ID is terminal/gone; run is no longer active. Self-healed by guard." 2>/dev/null || true
        # ga-jhyu: CLOSE at terminal so wisp-compact reaps it (was relabel-only → OPEN forever).
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — companion marker $COMPANION_MARKER_ID terminal/gone. Closed by guard (ga-jhyu)." 2>/dev/null || true
        ;;
      supersede:dead-reviewers)
        warn "Vector B: superseding ZOMBIE gate-run $GR_ID (age=${GR_AGE}m > zombie-age=${GATE_ZOMBIE_AGE_MINUTES}m [verdict-timeout ${GATE_VERDICT_TIMEOUT_MINUTES}m + margin ${GATE_DEAD_REVIEWER_MARGIN_MINUTES}m], no live reviewer — dispatcher abandoned it; ga-o57gn)"
        set_gate_status "$GR_ID" "superseded"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-o57gn): zombie gate-run superseded — age ${GR_AGE}m exceeds verdict-timeout+margin (${GATE_ZOMBIE_AGE_MINUTES}m) AND no live reviewer is assigned to an open verdict bead. The owning dispatcher died/was killed mid-run. Self-healed by guard." 2>/dev/null || true
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — zombie: age>verdict-timeout, no live reviewer. Closed by guard (ga-o57gn)." 2>/dev/null || true
        ;;
      abort:age)
        warn "Vector B: aborting gate-run $GR_ID by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m, marker_active=${MARKER_ACTIVE})"
        set_gate_status "$GR_ID" "aborted"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): gate-run aborted by guard TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m; marker $COMPANION_MARKER_ID still active but run exceeded max wait)." 2>/dev/null || true
        # ga-jhyu: CLOSE at terminal so wisp-compact reaps it.
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run aborted (terminal) by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m). Closed by guard (ga-jhyu)." 2>/dev/null || true
        ;;
      skip)
        log "  Gate-run $GR_ID active (age=${GR_AGE}m, marker_active=${MARKER_ACTIVE}, reviewers_alive=${REVIEWERS_ALIVE}) — skipping."
        ;;
    esac
  done
fi

# ── Step 0c: ga-3h8l — sweep orphaned story:in-flight labels ─────────────────
# story:in-flight is the Pilot's lane-occupancy signal. It is stripped at merge
# (gate PASS+merge dispatcher path) as of ga-3h8l. But beads can accumulate
# a stale story:in-flight via paths the dispatcher doesn't cover:
#   (a) story closed by hand / superseded without going through the gate
#   (b) story merged outside the full gate flow (no gate:passed set)
#   (c) any future path that misses the dispatcher's PASS block
#
# Sweep condition: story:in-flight bead is CLOSED OR carries gate:passed.
# Both states mean the build is done — delivery either completed or will complete
# on its own — so the lane slot is permanently leaked. Strip and log.
#
# bd list without --all returns only OPEN beads. To catch closed beads, use --all.
# We then filter in jq: status==closed OR labels include gate:passed.

log "Checking for orphaned story:in-flight labels (ga-3h8l reconciler)..."

INFLIGHT_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l "story:in-flight" \
  -n 0 \
  2>/dev/null || echo "[]")

INFLIGHT_COUNT=$(echo "$INFLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$INFLIGHT_COUNT" -gt 0 ]; then
  ORPHAN_IDS=$(echo "$INFLIGHT_JSON" | jq -r '
    .[] |
    select(
      .status == "closed" or
      ((.labels // []) | contains(["gate:passed"]))
    ) | .id' 2>/dev/null || echo "")

  for ORP_ID in $ORPHAN_IDS; do
    [ -z "$ORP_ID" ] && continue
    warn "Stripping orphaned story:in-flight from $ORP_ID (ga-3h8l reconciler: closed or gate:passed)"
    bd -C "$GC_CITY" label remove "$ORP_ID" "story:in-flight" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$ORP_ID" "ga-3h8l reconciler: stripped orphaned story:in-flight (bead is closed or carries gate:passed — lane slot was permanently leaked). Self-healed." 2>/dev/null || true
  done
fi

# ── Step 0c.1 (ga-pa36 GAP-1): merged-but-OPEN beads ────────────────────────
# OPEN story:in-flight beads with no gate:passed whose fix branch was already
# merged to origin/main (merged via old gate before ga-3h8l strip code, or
# merged out-of-band). The existing Step-0c misses them because they are OPEN
# with no gate:passed.
# Safe-default: if branch SHA cannot be positively resolved → do NOT act.
# Pilot:dispatched beads are excluded — they are handled by GAP-2 below.

log "Step 0c.1 (ga-pa36 GAP-1): sweep merged-but-OPEN story:in-flight beads..."

if [ "$INFLIGHT_COUNT" -gt 0 ]; then
  GAP1_IDS=$(echo "$INFLIGHT_JSON" | jq -r '
    .[] |
    select(
      .status != "closed" and
      ((.labels // []) | contains(["gate:passed"]) | not) and
      ((.labels // []) | contains(["pilot:dispatched"]) | not)
    ) | .id' 2>/dev/null || echo "")

  if [ -n "$GAP1_IDS" ]; then
    G1_MAIN_SHA=""
    git -C "$GC_CITY" fetch origin main --quiet 2>/dev/null || true
    G1_MAIN_SHA=$(git -C "$GC_CITY" rev-parse "origin/main" 2>/dev/null || echo "")

    for OI_ID in $GAP1_IDS; do
      [ -z "$OI_ID" ] && continue

      # Check assignee via bd show (bd list --json does not include assignee).
      OI_SHOW=$(bd -C "$GC_CITY" show "$OI_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      OI_ASSIGNEE=$(echo "$OI_SHOW" | jq -r '.assignee // ""' 2>/dev/null || echo "")

      HAS_LIVE_ASSIGNEE=0
      if [ -n "$OI_ASSIGNEE" ] && [ "$OI_ASSIGNEE" != "null" ]; then
        SESSION_JSON=$(bash "$GC_CITY/scripts/gc-session-list-cached.sh" 2>/dev/null || echo "{}")
        [ "$(session_matches_author "$OI_ASSIGNEE" "$SESSION_JSON")" = "1" ] && HAS_LIVE_ASSIGNEE=1
      fi

      ACTION=$(classify_inflight_gap1 "open" "0" "$HAS_LIVE_ASSIGNEE" "unknown")
      if [ "$ACTION" = "skip:live-builder" ]; then
        log "GAP-1: $OI_ID has live assignee ($OI_ASSIGNEE) — safe-skip"
        continue
      fi

      if [ -z "$G1_MAIN_SHA" ]; then
        log "GAP-1: origin/main SHA unreachable — safe-skip all GAP-1 candidates"
        break
      fi

      # Find branch tip by convention: fix/<id>* or feature/<id>*
      # Prefer ls-remote (live) with for-each-ref as local cache fallback.
      OI_BRANCH_SHA=""
      for PAT in "refs/heads/fix/${OI_ID}" "refs/heads/fix/${OI_ID}-*" \
                 "refs/heads/feature/${OI_ID}" "refs/heads/feature/${OI_ID}-*"; do
        SHA=$(git -C "$GC_CITY" ls-remote origin "$PAT" 2>/dev/null | head -1 | awk '{print $1}')
        if [ -z "$SHA" ]; then
          RREF="${PAT/refs\/heads\//refs\/remotes\/origin\/}"
          SHA=$(git -C "$GC_CITY" for-each-ref --format='%(objectname)' "$RREF" 2>/dev/null | head -1)
        fi
        [ -n "$SHA" ] && { OI_BRANCH_SHA="$SHA"; break; }
      done

      if [ -z "$OI_BRANCH_SHA" ]; then
        log "GAP-1: $OI_ID — no branch matching fix/$OI_ID* or feature/$OI_ID* — safe-skip"
        continue
      fi

      BRANCH_MERGED=0
      MERGED_BY_REBASE=0
      if git -C "$GC_CITY" merge-base --is-ancestor "$OI_BRANCH_SHA" "$G1_MAIN_SHA" 2>/dev/null; then
        BRANCH_MERGED=1
      elif guard_content_merged "$G1_MAIN_SHA" "$OI_BRANCH_SHA"; then
        BRANCH_MERGED=1
        MERGED_BY_REBASE=1
      fi

      ACTION=$(classify_inflight_gap1 "open" "0" "$HAS_LIVE_ASSIGNEE" "$BRANCH_MERGED")
      case "$ACTION" in
        strip:merged)
          if [ "$MERGED_BY_REBASE" = "1" ]; then
            warn "GAP-1: $OI_ID branch tip $OI_BRANCH_SHA merged-by-rebase into origin/main (not a sha ancestor, but 0 unmerged patches by content), no gate:passed, no live builder — stripping story:in-flight (ga-0ndi)"
            bd -C "$GC_CITY" comment "$OI_ID" "ga-pa36 GAP-1 reconciler: stripped orphaned story:in-flight — branch tip $OI_BRANCH_SHA is merged-by-rebase into origin/main (git rev-list --cherry-pick --right-only == 0; not a sha ancestor because a rebase/re-commit replays commits under new shas), no gate:passed label, no live builder. Lane slot freed. (ga-0ndi)" 2>/dev/null || true
          else
            warn "GAP-1: $OI_ID branch tip $OI_BRANCH_SHA merged to origin/main, no gate:passed, no live builder — stripping story:in-flight"
            bd -C "$GC_CITY" comment "$OI_ID" "ga-pa36 GAP-1 reconciler: stripped orphaned story:in-flight — branch tip $OI_BRANCH_SHA already merged to origin/main, no gate:passed label, no live builder. Lane slot freed." 2>/dev/null || true
          fi
          bd -C "$GC_CITY" label remove "$OI_ID" "story:in-flight" -q 2>/dev/null || true
          ;;
        skip:not-merged)
          log "GAP-1: $OI_ID branch tip $OI_BRANCH_SHA not yet merged — skip"
          ;;
        *)
          log "GAP-1: $OI_ID action=$ACTION — skip"
          ;;
      esac
    done
  fi
fi

# ── Step 0c.2 (ga-pa36 GAP-2): parent-story stranding ────────────────────────
# When the gate runs on a SLING/WORK bead (Pilot-dispatched path), the FAIL
# self-heal strips story:in-flight from the WORK bead but the PARENT retains
# story:in-flight + pilot:dispatched with no builder — the Pilot's exclusion
# hides it forever. Detect via "Sling task bead: $ID" comment the Pilot writes.
# Safe-default: if sling bead ID is absent from comments or state is ambiguous
# → do NOT act.

log "Step 0c.2 (ga-pa36 GAP-2): sweep stranded parent stories..."

if [ "$INFLIGHT_COUNT" -gt 0 ]; then
  GAP2_IDS=$(echo "$INFLIGHT_JSON" | jq -r '
    .[] |
    select(
      .status != "closed" and
      ((.labels // []) | contains(["gate:passed"]) | not) and
      ((.labels // []) | contains(["pilot:dispatched"]))
    ) | .id' 2>/dev/null || echo "")

  for SC_ID in $GAP2_IDS; do
    [ -z "$SC_ID" ] && continue

    # Check parent's own assignee (Pilot does not assign story to builder, but be safe).
    SC_SHOW=$(bd -C "$GC_CITY" show "$SC_ID" --json --include-comments 2>/dev/null \
      | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
    SC_ASSIGNEE=$(echo "$SC_SHOW" | jq -r '.assignee // ""' 2>/dev/null || echo "")

    HAS_SC_ASSIGNEE=0
    if [ -n "$SC_ASSIGNEE" ] && [ "$SC_ASSIGNEE" != "null" ]; then
      SC_SESSION_JSON=$(bash "$GC_CITY/scripts/gc-session-list-cached.sh" 2>/dev/null || echo "{}")
      [ "$(session_matches_author "$SC_ASSIGNEE" "$SC_SESSION_JSON")" = "1" ] && HAS_SC_ASSIGNEE=1
    fi

    # Find sling bead ID from Pilot dispatch comment.
    SLING_ID=$(echo "$SC_SHOW" | jq -r '
      .comments // [] | sort_by(.created_at) | reverse |
      .[] | .text // "" | select(test("Sling task bead:")) |
      capture("Sling task bead: (?P<id>[a-z][a-z0-9-]+)") | .id
    ' 2>/dev/null | head -1 || echo "")

    SLING_FOUND=0
    SLING_NEEDS_FIX=0
    SLING_CLOSED=0

    if [ -n "$SLING_ID" ] && [ "$SLING_ID" != "null" ]; then
      SLING_FOUND=1
      SLING_JSON=$(bd -C "$GC_CITY" show "$SLING_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      SLING_STATUS=$(echo "$SLING_JSON" | jq -r '.status // ""' 2>/dev/null || echo "")
      SLING_LABELS=$(echo "$SLING_JSON" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")

      [ "$SLING_STATUS" = "closed" ] && SLING_CLOSED=1
      echo "$SLING_LABELS" | grep -qE "gate:needs-fix|gate:needs-human" && SLING_NEEDS_FIX=1 || true
    fi

    ACTION=$(classify_parent_gap2 "1" "$HAS_SC_ASSIGNEE" "$SLING_FOUND" "$SLING_NEEDS_FIX" "$SLING_CLOSED")

    case "$ACTION" in
      free:fail-stranded)
        warn "GAP-2: $SC_ID stranded (sling $SLING_ID gate-failed) — freeing lane, applying gate:needs-fix"

        # Propagate GATE-FEEDBACK from sling bead to parent.
        GATE_FEEDBACK=$(bd -C "$GC_CITY" show "$SLING_ID" --json --include-comments 2>/dev/null \
          | jq -r 'if type=="array" then .[0] else . end |
            .comments // [] | map(select(.text | test("^GATE-FEEDBACK"))) | last | .text // ""' \
          2>/dev/null || echo "")

        bd -C "$GC_CITY" label remove "$SC_ID" "story:in-flight"  -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$SC_ID" "pilot:dispatched" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$SC_ID" "gate:needs-fix"   -q 2>/dev/null || true

        if [ -n "$GATE_FEEDBACK" ]; then
          bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: parent stranded after sling bead $SLING_ID gate-failed. story:in-flight + pilot:dispatched cleared; gate:needs-fix set so Pilot re-dispatches.
Propagated from $SLING_ID: $GATE_FEEDBACK" 2>/dev/null || true
        else
          bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: parent stranded after sling bead $SLING_ID gate-failed (labels: $SLING_LABELS). story:in-flight + pilot:dispatched cleared; gate:needs-fix set. Pilot will re-dispatch." 2>/dev/null || true
        fi
        ;;
      free:pass-stranded)
        warn "GAP-2: $SC_ID stranded (sling $SLING_ID closed/passed) — freeing lane"
        SC_LABELS=$(echo "$SC_SHOW" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")

        bd -C "$GC_CITY" label remove "$SC_ID" "story:in-flight"  -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$SC_ID" "pilot:dispatched" -q 2>/dev/null || true

        if echo "$SC_LABELS" | grep -q "story:approved"; then
          # Story-type parent: set gate:passed so story-delivery finalizes it.
          bd -C "$GC_CITY" label add "$SC_ID" "gate:passed" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: parent stranded after sling bead $SLING_ID gate-passed+closed. story:in-flight + pilot:dispatched cleared; gate:passed set — story-delivery will deploy and mark story:done." 2>/dev/null || true
        else
          # Bug/task parent: close it (work was merged via sling bead).
          bd -C "$GC_CITY" close "$SC_ID" \
            -r "ga-pa36 GAP-2 reconciler: sling bead $SLING_ID gate-passed and closed — work is done; closing parent." \
            2>/dev/null || warn "Could not close parent $SC_ID after pass-stranded detection"
        fi
        ;;
      skip:live-assignee)
        log "GAP-2: $SC_ID has live assignee ($SC_ASSIGNEE) — safe-skip"
        ;;
      skip:no-sling)
        log "GAP-2: $SC_ID — no 'Sling task bead' comment found — safe-skip"
        ;;
      skip:active-sling)
        log "GAP-2: $SC_ID sling $SLING_ID is active (status=$SLING_STATUS) — skip"
        ;;
      skip:not-dispatched)
        log "GAP-2: $SC_ID not pilot:dispatched — skip (should not reach here)"
        ;;
    esac
  done
fi

# ── Step 1: Find unclaimed ready-for-gate markers ─────────────────────────────

MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:ready \
  2>/dev/null || echo "[]")

COUNT=$(printf '%s\n' "$MARKERS_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT unclaimed marker(s)"

if [ "$COUNT" = "0" ]; then
  log "No work. Exiting."
  exit 0
fi

# ── Step 2: Claim the first marker (atomic conditional claim) ─────────────────
# We remove the "ready" label first. If another process already removed it
# (race), the remove will report nothing changed and the re-fetch below will
# confirm the claim is ours or not.

MARKER=$(printf '%s\n' "$MARKERS_JSON" | jq '.[0]')
MARKER_ID=$(printf '%s\n' "$MARKER" | jq -r '.id')

log "Attempting to claim marker $MARKER_ID ..."

# Remove ready label (may be a no-op if another sweep beat us)
bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:ready" -q 2>/dev/null || true

# Re-fetch the marker to verify its current state
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null || echo "{}")
CURRENT_LABELS=$(echo "$VERIFY_JSON" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$CURRENT_LABELS" | grep -q "gate-status:claimed"; then
  log "Marker $MARKER_ID already claimed by another sweep. Skipping."
  exit 0
fi

if echo "$CURRENT_LABELS" | grep -q "gate-status:ready"; then
  # Someone re-added ready, or remove failed silently; abort to avoid double dispatch
  log "Marker $MARKER_ID still in ready state after remove attempt (race condition). Skipping."
  exit 0
fi

# We removed ready without another process adding claimed — add claimed atomically
bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || {
  err "Failed to add gate-status:claimed to $MARKER_ID. Aborting."
  exit 1
}

log "Marker $MARKER_ID claimed."

# ── Step 3: Extract metadata from marker description ─────────────────────────

DESC=$(printf '%s\n' "$MARKER" | jq -r '.description // ""')

# ga-7zjs1 (ported from the dispatcher's extract, quality-gate-dispatcher.sh): a
# marker missing a field (e.g. a hand-rolled re-submit marker with no `rig:` line)
# makes `grep` exit 1 → under `set -euo pipefail` the pipeline status propagates and
# the bare `RIG=$(extract "rig")` command substitution aborts the guard SILENTLY,
# right after the "claimed" log and before any branch log. The marker is then
# stranded at gate-status:claimed → Vector A re-readies it ×3 → gate-status:error
# (looks like a deterministic dispatcher crash; it's the guard). `|| true` makes a
# missing field yield "" (safe: validate_rig only runs when RIG is non-empty, and
# the rig is re-derived from the bead-id prefix downstream). Also absorbs head -1
# SIGPIPE on a large multi-line $DESC.
extract() { echo "$DESC" | grep -E "^$1:" | head -1 | sed "s/^$1: *//" || true; }

BRANCH=$(extract "branch")
BEAD_ID=$(extract "bead_id")
MARKER_AUTHOR=$(extract "author")  # Self-declared — used for logging only, NOT for exclusion
BASE_COMMIT=$(extract "base_commit")
RIG=$(extract "rig")

log "  branch=$BRANCH  bead_id=$BEAD_ID  marker_author=${MARKER_AUTHOR:-<EMPTY>}  rig=$RIG"

# ── Step 4: Input validation (security: prevent injection) ──────────────────

VALIDATION_OK=true

if [ -z "$BRANCH" ] || ! validate_branch "$BRANCH"; then
  err "branch '$BRANCH' is missing or contains unsafe characters. Deferring."
  VALIDATION_OK=false
fi

# ga-mxhf6 / gate-main-close: protected-branch guard.
# HQ-infra dogs legitimately commit directly to main (daemon scripts, gate fixes).
# When they run /gate-done on main, a branch=main marker is created — but the gate
# CANNOT review it (main is its own ancestor; the dispatcher would silently supersede).
# Unlike bad-bead-id/rig (fixable by re-submit), branch=main is UN-FIXABLE: you
# cannot make main not-main. Leaving it gate-status:error forever is permanent
# painel noise ("erro no gate" / "gate parado"). Instead, CLOSE the marker cleanly
# (closed markers don't render as gate-error). Other validation failures (bad
# bead_id/rig) remain → gate-status:error (re-submittable, visible to the author).
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  err "branch '$BRANCH' is protected and not gate-reviewable (HQ work lands directly on main). Closing marker cleanly (gate-main-close, not error)."
  bd -C "$GC_CITY" comment "$MARKER_ID" "Branch is '$BRANCH' — not gate-reviewable. HQ work committed directly to main bypasses the gate by design. This marker cannot be fixed by re-submit (main will always be main). Closing cleanly to avoid permanent gate-status:error painel noise.
If this bead's work is real, it is already on main.
If a feature branch was intended, re-submit the bead with branch fix/<bead_id>-<desc>." 2>/dev/null || true
  bd -C "$GC_CITY" close "$MARKER_ID" \
    -r "branch=$BRANCH not gate-reviewable (HQ work lands on main directly). Closed cleanly by guard (gate-main-close) — not an error." 2>/dev/null || true
  log "gate-main-close: marker $MARKER_ID branch=$BRANCH closed cleanly (not error, not re-submittable)."
  exit 0
fi

if [ -z "$BEAD_ID" ] || ! validate_bead_id "$BEAD_ID"; then
  err "bead_id '$BEAD_ID' is missing or has unexpected format. Deferring."
  VALIDATION_OK=false
fi

if [ -n "$RIG" ] && ! validate_rig "$RIG"; then
  err "rig '$RIG' is not in the known rig list. Deferring."
  VALIDATION_OK=false
fi

if [ "$VALIDATION_OK" = "false" ]; then
  # ga-jhyu: atomic single-label transition; do NOT close (gate-health-monitor.py
  # pages a human on OPEN gate-status:error markers — see Vector A note).
  set_gate_status "$MARKER_ID" "error"
  # Bug 3 fix: no Mayor mail — autonomous gate; author gets nudge if resolvable
  if [ -n "$BEAD_ID" ]; then
    bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard rejected marker: invalid/unsafe field values.
branch='$BRANCH' bead_id='$BEAD_ID' rig='$RIG'
Marker set to gate-status:error. Fix the marker fields and re-submit." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (marker error, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): invalid marker $MARKER_ID — security check failed (gate-status:error)."
  exit 1
fi

# ── Step 5: Derive author from the authoritative bead record ─────────────────
# SECURITY: Do NOT use MARKER_AUTHOR (self-declared by worker) for exclusion.
# Instead, look up the bead's assignee or owner in the DB. This prevents
# an attacker from spoofing the author field to bypass self-review checks.
#
# Resolution order:
#   1. Cross-rig lookup via "gc bd show" (handles beads in rig DBs, e.g. wa-*, ps-*).
#   2. HQ DB fallback (bd -C $GC_CITY show) for beads created in the HQ DB.
#   3. Session-id normalization: if assignee is "digo-adhoc-e2510107f6" → strip adhoc
#      suffix → "digo" (the crew role/identity). Prevents false unresolvable on crew beads.

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

BEAD_RAW=""
if [ -n "$BEAD_ID" ]; then
  # 1. Cross-rig lookup via gc bd (authoritative — queries the owning rig's Dolt DB).
  #    Handles beads in rig DBs (e.g. wa-*, ps-*) that are NOT in the HQ DB.
  BEAD_RAW=$(gc --city "$GC_CITY" bd show "$BEAD_ID" --json 2>/dev/null || echo "")

  if [ -z "$BEAD_RAW" ]; then
    log "  gc bd cross-rig lookup empty; falling back to HQ DB."
    BEAD_RAW=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null || echo "")
  fi

  # Extract fields using grep (robust to embedded-newline JSON from gc bd)
  # Try assignee first, then owner/creator
  AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "created_by")
  fi
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "owner")
  fi
fi

# Session-id normalization: strip adhoc suffix from session IDs to get the crew role.
# e.g. "digo-wa-adhoc-e2510107f6" → "digo-wa", "batista-lx-adhoc-abc123" → "batista-lx"
if [ -n "$AUTHOR" ] && echo "$AUTHOR" | grep -qE "-adhoc-[0-9a-f]+" 2>/dev/null; then
  AUTHOR_NORMALIZED=$(echo "$AUTHOR" | sed 's/-adhoc-[0-9a-f]*$//')
  log "  Author '$AUTHOR' looks like a session-id; normalizing to crew role '$AUTHOR_NORMALIZED'."
  AUTHOR="$AUTHOR_NORMALIZED"
fi

# ga-pyzo: best-effort resolve the DURABLE agent alias behind AUTHOR (see
# resolve_author_agent_alias in the pure-decision-functions section above for
# the full rationale + scope guard), while the submitting session is still
# very likely alive — this guard runs synchronously, seconds after that same
# session's own /gate-done call. Persisting the alias now (Step 7 below) lets
# the dispatcher fall back to it later if AUTHOR's own session has since
# recycled, instead of reading a live agent as dead forever (evidence: 3
# parked markers, 2026-07-14, see bug).
AUTHOR_AGENT=$(resolve_author_agent_alias "$AUTHOR")
[ -n "$AUTHOR_AGENT" ] && log "  Durable agent alias for '$AUTHOR': '$AUTHOR_AGENT' (ga-pyzo, best-effort)."

if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
  warn "Cannot determine author authoritatively for bead $BEAD_ID — DEFERRING (fail-safe)."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed"  -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred" -q 2>/dev/null || true
  # Bug 3 fix: no Mayor mail — author-unresolvable is a bead data issue, not a Mayor task.
  # Comment on the marker bead with diagnostic info; ntfy alerts Athos if needed.
  bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard deferred: cannot determine author authoritatively for bead $BEAD_ID.
Marker self-declared author: ${MARKER_AUTHOR:-<empty>}
Self-review prevention requires an authoritative author source.
Fix the bead's assignee/created_by field and re-submit." 2>/dev/null || true
  # wa-uthi: non-terminal (deferred — bead data issue, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): author unresolvable for marker $MARKER_ID — deferred (gate-status:deferred)."
  exit 0
fi

log "Authoritative author: $AUTHOR"

# ── Step 5a: park markers whose source-bead is not approved or circuit-broken ──
# BEAD_RAW was fetched in Step 5 above. Extract labels and run the pure decision.
# This check fires BEFORE the gate-run bead is created (Step 6) so no reviewer is
# ever spawned for an ineligible source bead. FAIL-OPEN: if BEAD_RAW is empty
# (transient Dolt hiccup) we cannot determine labels → proceed normally (don't
# block a legitimate story:approved submission over a lookup failure).
if [ -n "$BEAD_RAW" ]; then
  SRC_LABELS_PARK=$(printf '%s\n' "$BEAD_RAW" \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
    2>/dev/null || echo "")
  PARK_ACTION=$(check_source_bead_park "$SRC_LABELS_PARK")
  if [ "$PARK_ACTION" != "ok" ]; then
    case "$PARK_ACTION" in
      park:needs-approval) PARK_REASON="source bead $BEAD_ID carries story:needs-approval (not yet product-approved)" ;;
      park:needs-human)    PARK_REASON="source bead $BEAD_ID carries gate:needs-human (circuit-broken — human intervention required)" ;;
      *)                   PARK_REASON="source bead $BEAD_ID is not eligible for gate review ($PARK_ACTION)" ;;
    esac
    warn "Step 5a: parking marker $MARKER_ID — $PARK_REASON"
    # Transition: claimed → parked-needs-human (terminal; Step 1 only picks gate-status:ready).
    set_gate_status "$MARKER_ID" "parked-needs-human"
    bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard Step 5a: marker parked — $PARK_REASON.
No gate-run was created and no reviewer was spawned.
To re-enter the gate: resolve the blocking condition on $BEAD_ID (get it approved / clear gate:needs-human), then submit a fresh gate marker." \
      2>/dev/null || true
    # Best-effort comment on the source bead. gc bd is cross-rig; bd -C HQ is fallback.
    gc --city "$GC_CITY" bd comment "$BEAD_ID" \
      "Gate guard Step 5a: blocked gate submission — $PARK_REASON. Gate marker $MARKER_ID was parked (gate-status:parked-needs-human); no reviewer was spawned. Resolve the blocking condition, then re-submit a fresh gate marker." \
      2>/dev/null || bd -C "$GC_CITY" comment "$BEAD_ID" \
      "Gate guard Step 5a: blocked gate submission — $PARK_REASON. Gate marker $MARKER_ID was parked (gate-status:parked-needs-human); no reviewer was spawned. Resolve the blocking condition, then re-submit a fresh gate marker." \
      2>/dev/null || true
    bd -C "$GC_CITY" close "$MARKER_ID" \
      -r "Gate guard Step 5a: marker parked (terminal) — $PARK_REASON. No gate-run created." \
      2>/dev/null || true
    notify_park_author "$AUTHOR" "$BEAD_ID" "$BRANCH" "$MARKER_ID" "$PARK_REASON"
    log "SUPPRESSED PUSH (wa-uthi non-terminal): marker $MARKER_ID parked (Step 5a: $PARK_ACTION)."
    exit 0
  fi
fi

# ── Resolve the store that OWNS the source bead (gt-gwng6) ────────────────────
# Step 5b below clears the source bead's assignee and strips its gc.routed_to to
# stop the dog pool from re-matching it mid-gate. Those writes MUST target the
# store that actually contains $BEAD_ID. Rig-native beads (wa-*, ps-*, lx-*) live
# in their RIG's own Dolt DB, NOT the HQ store — `bd -C "$GC_CITY"` (HQ) silently
# no-ops on them, so the assignee never clears and the reconciler re-spawns pool
# workers infinitely (wa-nr8o/wa-32fq/wa-tnl5 churned 5x-15x; the guard also
# re-dispatched duplicate gate runs — wa-tnl5 had 4 markers, 2 running). ga-e7zk7
# fixed only the dog-side re-claim, NOT this guard leg. Mirror the dispatcher's
# ga-qw7y6 resolution: resolve RIG_PATH from the marker rig (+ bead-prefix /
# trailing-segment fallbacks), then probe which store actually owns the bead.
# UNLIKE the dispatcher, resolution failure here is NON-FATAL — the detach is
# best-effort (set -euo pipefail discipline below), so we never abort the sweep;
# resolve_bead_city's prefix heuristic still picks the most-likely store, and a
# wrong guess only leaves the bead attached — exactly the pre-fix behavior, never
# worse.
RIG_PATH=""
RIG_LIST_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo '{}')
if [ -n "$RIG" ]; then
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
fi
# Compound/crew rig fallback (rig=mila-wa) → bead-id prefix is authoritative.
if { [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; } && [ -n "$BEAD_ID" ]; then
  _bid_prefix="${BEAD_ID%%-*}"
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$_bid_prefix" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
fi
# Trailing-segment fallback: mila-wa → wa.
if { [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; } && [ -n "$RIG" ] && printf '%s' "$RIG" | grep -q '-'; then
  _rig_tail="${RIG##*-}"
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$_rig_tail" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
fi
[ -d "$RIG_PATH" ] || RIG_PATH=""   # never hand a non-existent dir to resolve_bead_city

# resolve_bead_city <bead-id> — echo the store dir whose Dolt DB owns <bead-id>.
# Probes RIG_PATH first (rig-native beads), then GC_CITY (HQ). A store "owns" the
# bead iff `bd -C <store> show` yields a record with non-empty .status; a
# not-found probe returns {"error":...} (no .status → skip). Falls back to a
# bead-id prefix heuristic (ga-* → HQ; else rig) only when NEITHER store resolves
# (transient Dolt hiccup). Mirrors quality-gate-dispatcher.sh:resolve_bead_city.
resolve_bead_city() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    st=$(bd -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}
BEAD_CITY="$(resolve_bead_city "$BEAD_ID")"
if [ "$BEAD_CITY" != "$GC_CITY" ]; then
  log "  gt-gwng6: source bead $BEAD_ID resolves to store $BEAD_CITY (NOT HQ $GC_CITY) — cross-store detach corrected."
fi

# ── Step 5b (ga-e7zk7): detach source bead from the dog pool — gate owns it now ──
# Why HERE (after Step 5), not before it: Step 5 derives the self-review-exclusion
# author from the source bead's record, and its FIRST-CHOICE signal is the bead's
# assignee (assignee → created_by → owner). assignee and created_by routinely
# diverge in production (e.g. assignee=oracle-wa, created_by=peter-wa — different
# crew). Clearing the assignee BEFORE Step 5 (the original ga-e7zk7 attempt) forced
# author resolution to fall through to created_by (the FILER), which would let the
# real builder be picked to review their own branch — the exact self-review bypass
# Step 5's SECURITY block exists to prevent. So the detach MUST run only after
# AUTHOR is resolved. By this line AUTHOR is final and the author-unresolvable
# fail-safe above has already `exit 0`d (correctly leaving such beads attached for
# re-dispatch), so detaching here is safe for both paths.
#
# What it fixes: the builder leaves the source bead in_progress + assignee=<pool
# alias> for the WHOLE gate duration (the gate closes it on PASS). Markers routinely
# sit queued for hours behind the single-threaded backlog, and throughout that
# window the dog-pool startup probes — label-blind and engine-baked (cannot be
# changed without an engine window) — keep re-matching the source bead:
#   - Step 1a: bd list --status in_progress --assignee=<session id|name|alias>
#              → every recycle of the builder's pool alias re-finds it (Vector 1a)
#   - Step 1c: bd ready --metadata-field gc.routed_to=<template> --unassigned
#              → on dog death the reconciler reset-to-ready re-exposes any residual
#                gc.routed_to (Vector 1c)
# Each re-match spins up a no-op dog that verifies-and-exits — pure session burn
# (ga-noxbv was re-dispatched 15x mid-gate; see ga-e7zk7). The marker is still
# gate-status:claimed at this point (Step 6 has not flipped it yet), an active state
# the inflight-reclaim-guard already excludes, so detaching cannot trigger a false
# reclaim. Neutralize both vectors at the routing layer: clear the source bead's
# assignee (kills 1a) and strip gc.routed_to (kills 1c). The bead stays in_progress
# + story:in-flight; the gate closes it on PASS, or on FAIL the Pilot re-dispatches
# (re-assigning fresh). The marker's source-bead: label — not the bead's assignee —
# is what the gate and delivery use to find it, so detaching is safe. Best-effort,
# never fatal (set -euo pipefail discipline).
if [ -n "$BEAD_ID" ]; then
  # gt-gwng6: target $BEAD_CITY (the bead's OWNING store), not $GC_CITY (HQ).
  # On a rig-native bead these are different stores; HQ-targeted writes no-op.
  if bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null; then
    log "  detached source bead $BEAD_ID from dog pool (cleared assignee in $BEAD_CITY — ga-e7zk7/gt-gwng6)"
  else
    log "  WARN: could not clear assignee on source bead $BEAD_ID in $BEAD_CITY (non-fatal — ga-e7zk7)"
  fi
  # Strip the metadata-keyed pool route (no-op in the current sling-bead model,
  # where the source bead carries no gc.routed_to; covers the legacy direct-route
  # model where it did). Guarded so a missing key never aborts the sweep.
  bd -C "$BEAD_CITY" update "$BEAD_ID" --unset-metadata gc.routed_to -q 2>/dev/null || true
fi

# ── Step 6: Create gate-run tracking bead ─────────────────────────────────────

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

GATE_RUN_ID=$(bd -C "$GC_CITY" create \
  "quality-gate: $BRANCH ($BEAD_ID)" \
  -t chore --ephemeral \
  -l type:quality-gate-run \
  -l gate-status:running \
  -l "source-bead:$BEAD_ID" \
  -d "Quality gate run for branch $BRANCH.
source_bead: $BEAD_ID
author: $AUTHOR
rig: $RIG
base_commit: ${BASE_COMMIT:-unknown}
marker_id: $MARKER_ID
started_at: $NOW" \
  --json 2>/dev/null | jq -r '.id // empty')

if [ -z "$GATE_RUN_ID" ]; then
  warn "Could not create gate-run tracking bead. Continuing without it."
  GATE_RUN_ID="unknown"
fi
log "Gate-run tracking bead: $GATE_RUN_ID"

# ── Step 7: Park marker for autonomous dispatcher (G) ────────────────────────
#
# The guard's role is to: scan, validate, claim, derive author (security),
# create the gate-run tracking bead, then park as gate-status:queued.
#
# The autonomous Quality Gate Dispatcher (G, com.gascity.quality-gate-dispatcher)
# picks up gate-status:queued markers and runs the full review + merge flow
# independently. No Mayor involvement required — the gate is fully autonomous.
#
# NOTE: This comment block previously referred to "Mayor dispatch" — that was
# a legacy message from before G was built. G is now the dispatcher.
# Bug 3 fix (ga-v60): removed obsolete Mayor-notification mails.

log "Guard: parking marker $MARKER_ID as gate-status:queued for autonomous dispatcher (G)."

bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || true
bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:queued"  -q 2>/dev/null || true
bd -C "$GC_CITY" update "$GATE_RUN_ID" \
  --notes "Guard claimed marker and created gate-run bead. Marker queued for autonomous dispatcher (G)." \
  2>/dev/null || true

# ga-tkvsa (fixes ga-w5agg): persist the author THIS script just resolved
# authoritatively (Step 5) onto the marker itself, via metadata (--set-metadata
# is overwrite/last-write-wins, unlike label add — a worker cannot forge this by
# pre-seeding a label at marker-creation time). The dispatcher re-derives author
# independently at dispatch time (seconds to minutes later) from the SAME source
# bead's assignee/created_by/owner — but Step 5 above (dog-pool detach, ga-e7zk7)
# already cleared that bead's assignee in THIS SAME run, and created_by/owner are
# never populated on programmatically-created sling beads either. Every
# dog-submitted marker for a fix/* branch therefore hit the dispatcher's
# author-unresolvable fail-safe and dead-ended at gate-status:deferred, which
# nothing ever re-reads — not an edge case, the NORMAL dog lifecycle (submit,
# close, exit before the dispatcher's next sweep). Recording the value here lets
# the dispatcher trust it instead of re-deriving from a field this same guard run
# is about to clear.
bd -C "$GC_CITY" update "$MARKER_ID" --set-metadata "gate.submitted_by=$AUTHOR" -q 2>/dev/null || true

# ga-pyzo: persist the durable agent alias (resolved above, best-effort)
# alongside gate.submitted_by. gate.submitted_by remains the sole trusted
# self-review-exclusion identity (SECURITY, see Step 5 header) — this is a
# secondary liveness FALLBACK the dispatcher consults only when AUTHOR's own
# recorded session has since recycled. Omitted (no-op) when unresolved so old
# and new markers coexist without a schema migration.
[ -n "$AUTHOR_AGENT" ] && bd -C "$GC_CITY" update "$MARKER_ID" --set-metadata "gate.submitted_by_agent=$AUTHOR_AGENT" -q 2>/dev/null || true

# ── wa-qq33j: kanban sync — stamp source-bead + marker so the board shows in-review ──
# (a) Add source-bead:$BEAD_ID and branch:$BRANCH labels to the marker so the
#     painel's _parse_gate_marker can map marker → source-bead WITHOUT parsing
#     the description. Pre-wa-qq33j markers lacked these labels → Gate column
#     was always empty; every in-review bead showed in triagem (looks idle).
bd -C "$GC_CITY" label add "$MARKER_ID" "source-bead:$BEAD_ID" -q 2>/dev/null || true
bd -C "$GC_CITY" label add "$MARKER_ID" "branch:$BRANCH"       -q 2>/dev/null || true
# (b) Set gate:reviewing on the source bead itself (label-based belt-and-suspenders:
#     the painel sweeps gate:reviewing beads → Gate column even if the marker lookup
#     fails). Cleared by the dispatcher on PASS (merge) and FAIL (needs-fix). Uses
#     BEAD_CITY (resolved cross-rig store) so WA/PS beads update in their own DB.
if [ -n "$BEAD_ID" ]; then
  gc --city "$GC_CITY" bd label add "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || \
    bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || true
  log "  wa-qq33j: gate:reviewing set on $BEAD_ID (kanban: in-review state)"
fi

# Notify the author (not Mayor) that their branch is queued for autonomous review
if [ -n "$AUTHOR" ]; then
  gc --city "$GC_CITY" session nudge "$AUTHOR" \
    "Your branch $BRANCH ($BEAD_ID) has passed guard validation and is queued for autonomous quality gate review (G). No action needed — G will process it within ~2 minutes." \
    --delivery wait-idle 2>/dev/null || true
fi

# wa-uthi: non-terminal (queued / entered review) — no push to Athos. The author
# is nudged above; Athos only hears about terminal outcomes (merged / rejected).
log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH queued for autonomous gate review (G dispatching)."

log "Marker $MARKER_ID parked as queued, autonomous dispatcher (G) will pick it up (gate-run=$GATE_RUN_ID)"

# ── Step 8: Append guard sweep to structured log ──────────────────────────────

mkdir -p "$(dirname "$QG_LOG")"
# FM-1 FIX: use -c (compact) so each event is a single line.
# The painel reads JSON-LINES (one object per line); pretty-printed multi-line
# JSON breaks json.loads() per line.
jq -c -n \
  --arg ts "$NOW" \
  --arg branch "$BRANCH" \
  --arg bead "$BEAD_ID" \
  --arg rig "${RIG:-unknown}" \
  --arg marker "$MARKER_ID" \
  --arg gate_run "$GATE_RUN_ID" \
  --arg target "autonomous-dispatcher-G" \
  '{ts: $ts, event: "guard_queued", branch: $branch, bead: $bead, rig: $rig, marker: $marker, gate_run: $gate_run, target: $target}' \
  >> "$QG_LOG" 2>/dev/null || true

log "=== Guard sweep complete ==="
