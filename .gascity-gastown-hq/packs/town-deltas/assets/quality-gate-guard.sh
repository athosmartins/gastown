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

# ga-u07fn: grace window for the dead-reviewer VERDICT reap (distinct from
# Vector B's whole-RUN zombie check above, and from GATE_ZERO_VERDICT_GRACE_
# MINUTES above — that one gates a run with NO verdict bead at all; this one
# gates an EXISTING verdict bead whose specific assignee session isn't found
# alive). A freshly-spawned reviewer can take ~210s to appear in the session
# snapshot under load (ga-flfo/ga-xwdl); the grace window must clear that with
# a comfortable margin so the sweep never releases/closes a booting reviewer's
# own verdict bead out from under it.
#
# Deliberately matches GATE_ZERO_VERDICT_GRACE_MINUTES's value (15), not the
# bead's own "5-10min" prose suggestion: Mayor's live triage (ga-jeicm,
# 2026-08-07T23:29:11Z) explicitly left a 13-minute-old dead-looking verdict
# (ga-vvmc4) untouched as "still might be booting" — a 5-10min threshold would
# have wrongly caught it (13 > 10). 15 is the smallest round value consistent
# with ALL three of Mayor's worked examples: 13min → skip (still might be
# booting), 63min and 88min → act (long past any boot doubt). Reusing the
# already-battle-tested sibling constant's value, rather than picking a fresh
# number from the prose alone, is also just fewer independent magic numbers
# for the next reader to reconcile.
GATE_DEAD_VERDICT_GRACE_MINUTES="${GATE_DEAD_VERDICT_GRACE_MINUTES:-15}"

# ── Pure decision functions (loaded in GATE_GUARD_LIB_ONLY=1 mode by tests/dispatcher) ──

# gc_json_or_unknown <cmd...>
#
# ga-07509: `VAR=$(gc ... --json 2>/dev/null || echo "")` does not protect
# against a failing `gc` call — gc still prints a JSON envelope to STDOUT
# even when it exits non-zero (e.g. {"ok":false,"error":{...}}, or for
# `gc bd <sub>` a bare {"error":"..."} with no "ok" key at all), so the
# command substitution already captured that non-empty envelope before
# `|| echo` ever runs. The envelope then parses as valid JSON, and a
# downstream `.field | length` read on it silently returns 0 —
# indistinguishable from "queried successfully, zero results".
#
# This wrapper captures the REAL exit code before anything can discard it
# (via `if VAR=$(...); then`, exempt from this file's `set -e` the same way
# the rest of its guard clauses are), and additionally checks the envelope's
# own `ok` field (some gc paths print an error envelope and still exit 0).
# It resolves to exactly one of three states — never collapses the last two:
#   - valid data / legitimate-empty: prints the raw JSON to stdout, returns
#     0. The JSON may legitimately describe an empty result (e.g.
#     {"sessions": []}) — that is for the CALLER to determine via its own
#     field-specific jq query, exactly as before this fix. This helper only
#     answers "did the call itself succeed", not "was the result empty".
#   - FAILURE: prints nothing, returns 1. Callers MUST treat this distinctly
#     from a legitimate empty result — never proceed as if the answer was
#     "no data" (defer/retry/explicit fail-open per call site's own policy).
#
# Usage:
#   if _OUT=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json); then
#     ... use $_OUT, e.g. echo "$_OUT" | jq '.sessions | length' ...
#   else
#     ... gc call FAILED — decide explicitly what this call site does ...
#   fi
# Or, for a memoized cache that should retry-on-failure rather than pin an
# empty sentinel: CACHE=$(gc_json_or_unknown gc ...) || true; [ -z "$CACHE" ]
# unambiguously means "failed" — a real success is never an empty string
# (this helper's own success path always prints at least "{}"/"[]").
#
# ga-07rb3: relocated once already (was defined AFTER validate_rig, its first
# caller further down — a "command not found" for validate_rig's own use).
# ga-zdkn1: relocated AGAIN, all the way to the top of the pure-decision-
# functions section — resolve_author_agent_alias() (ga-pyzo) was added to
# THIS section later and calls gc_json_or_unknown too, but this section loads
# under GATE_GUARD_LIB_ONLY=1 (tests/dispatcher lib-only sourcing), which
# returns before reaching the OLD location further down in the file. Same
# defect class as ga-07rb3, one section up: production execution always
# sources the whole file top-to-bottom before calling anything, so it never
# saw this; only lib-only-mode callers did (confirmed: this function's own
# selftest — gate-recycled-session-author-fallback.selftest.sh — silently
# read every real resolution as empty, "command not found" swallowed by the
# call site's own `|| true`). Defining it once, at the very top of this
# section, keeps every in-file caller working regardless of call order OR
# sourcing mode.
gc_json_or_unknown() {
  local _gjou_out _gjou_rc
  if _gjou_out=$("$@" 2>/dev/null); then
    _gjou_rc=0
  else
    _gjou_rc=$?
  fi
  [ "$_gjou_rc" -eq 0 ] || return 1
  [ -n "$_gjou_out" ] || return 1
  if ! printf '%s' "$_gjou_out" | jq -e . >/dev/null 2>&1; then
    return 1   # exit 0 but unparseable — never hand malformed JSON upstream
  fi
  if printf '%s' "$_gjou_out" | jq -e 'has("ok") and (.ok == false)' >/dev/null 2>&1; then
    return 1   # exit 0 but envelope explicitly says ok:false
  fi
  printf '%s' "$_gjou_out"
  return 0
}

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

# reconcile_dead_reviewer_verdict_action <verdict_age_min> <grace_min> \
#                                         <reviewer_alive: 0|1> <parent_run_terminal: 0|1>
# Pure decision (ga-u07fn): what to do with a SINGLE `type:quality-gate-verdict`
# bead (still verdict:pending) whose specific assignee reviewer session might be
# dead. This is deliberately verdict-scoped, not run-scoped — it is the sibling
# ga-jeicm/Mayor asked for alongside Vector B's reconcile_gaterun_action above,
# because that function's action vocabulary is {skip, supersede-the-WHOLE-run,
# abort-by-TTL}: it has no way to free ONE stuck verdict while leaving a still-
# legitimate run (or a run with other live reviewers) alone. Two DIFFERENT
# recoveries share the same trigger (assignee session gone) and are told apart
# ONLY by whether the parent gate-run is still alive:
#   - parent run still active  → release: the run is legitimately still being
#     reviewed (or recoverable), so free the verdict bead for re-convocation
#     rather than tearing down and re-dispatching the whole run.
#   - parent run terminal      → close: the run already ended (closed/
#     superseded/error) — this verdict is leftover state holding a stale
#     assignee, not a stuck review anyone is coming back to finish.
# Live-measured worked examples this function's grace/action split must match
# (Mayor, ga-jeicm comment, 2026-08-07T23:29:11Z — mirrored as regression
# cases in the selftest): ga-vvmc4 (13min, run active) → skip (still-booting
# doubt); ga-k2na1 (63min, run active) → release; ga-u8e1h (88min, run
# terminal) → close.
#
# Priority (most-specific / safest first — mirrors reconcile_gaterun_action's
# own ordering above):
#   1. reviewer_alive=1            → skip  (nothing wrong, don't touch)
#   2. verdict_age_min <= grace_min → skip  (could still be booting, ~210s
#                                     typical — see GATE_DEAD_VERDICT_GRACE_
#                                     MINUTES above for why 15, not the boot
#                                     estimate itself)
#   3. parent_run_terminal=1        → close   (nothing left to finish)
#   4. else                         → release (run is alive; free for re-convocation)
reconcile_dead_reviewer_verdict_action() {
  local age_min="$1" grace_min="$2" reviewer_alive="$3" parent_run_terminal="$4"
  [ "$reviewer_alive" = "1" ] && { echo "skip"; return; }
  [ "$age_min" -le "$grace_min" ] && { echo "skip"; return; }
  [ "$parent_run_terminal" = "1" ] && { echo "close"; return; }
  echo "release"
}

# reconcile_orphaned_verdict_action <age_min> <grace_min> <has_gate_run_label> <parent_lookup_state>
#   parent_lookup_state: "found" | "not_found" | "unknown" — "unknown" means
#   the parent lookup itself couldn't even be parsed as JSON (Dolt timeout/bad
#   path/etc.), distinct from "not_found" (bd show succeeded in telling us the
#   id genuinely doesn't exist). Step 0b.2's sibling of
#   reconcile_dead_reviewer_verdict_action above, for verdicts whose PARENT
#   gate-run bead is gone entirely (ga-qtc16), not just carrying a dead
#   reviewer on an otherwise-live run (that's this function's own sibling's
#   job). Only a CONFIRMED "not_found" ever triggers close — "unknown" must
#   never collapse into "confirmed gone" (root-class:error-vs-empty; a query
#   failure is not evidence of absence).
#
# Priority (most-specific / safest first, mirrors the sibling's ordering):
#   1. age_min <= grace_min                 → skip (same-cycle replication-lag
#      artifact guard, not a real race in normal operation — see call site)
#   2. has_gate_run_label != 1              → skip (can't determine parent at
#      all, never guess)
#   3. parent_lookup_state != "not_found"   → skip (found = genuinely pending,
#      not orphaned; unknown = query failed, not confirmed absent)
#   4. else (not_found, past grace, labeled) → close
reconcile_orphaned_verdict_action() {
  local age_min="$1" grace_min="$2" has_gate_run_label="$3" parent_lookup_state="$4"
  [ "$age_min" -le "$grace_min" ] && { echo "skip"; return; }
  [ "$has_gate_run_label" != "1" ] && { echo "skip"; return; }
  [ "$parent_lookup_state" != "not_found" ] && { echo "skip"; return; }
  echo "close"
}

# session_alive_for_assignee <assignee> <sess_snap_json> — pure given the
# snapshot as data (ga-u07fn). Single-assignee liveness check: is <assignee> a
# still-open (non-closed) session in <sess_snap_json>? Same snapshot shape and
# same match rule (id/session_name/session_id) as reviewers_alive_for_run's
# inner loop below, deliberately kept as an independent standalone helper
# rather than refactoring that function to share it — reviewers_alive_for_run
# is live/tested code answering a different question (is ANY of N assignees
# for a RUN alive), and collapsing the two into one shared helper is out of
# scope for this bead (systematic-debugging: one change at a time, no bundled
# refactor of working code). Takes the snapshot as a plain arg rather than
# reading a global so it stays testable without sourcing the live gc-session-
# list-cached.sh I/O path.
session_alive_for_assignee() {
  local a="$1" snap="$2" present
  [ -z "$a" ] && { echo 0; return; }
  present=$(printf '%s\n' "$snap" \
    | jq -r --arg s "$a" 'if type=="array" then . else (.sessions // []) end
        | map(select((.id==$s) or (.session_name==$s) or (.session_id==$s))
              | select((.closed // false) != true)) | length' \
    2>/dev/null || echo 0)
  case "$present" in ''|*[!0-9]*) present=0 ;; esac
  [ "$present" -ge 1 ] && { echo 1; return; }
  echo 0
}

# gaterun_status_terminal <gate-status-value> — pure text classification
# (ga-u07fn). Feeds reconcile_dead_reviewer_verdict_action's parent_run_
# terminal arg from a gate-run bead's single gate-status:* label (extract via
# marker_status_from_labels below, which already solves the ga-i0n83
# ambiguous/mid-transition-label problem generically for any bead type, not
# just markers, despite its name). Terminal = the run will never produce a
# verdict; anything else (including empty/unrecognized, fail-safe) is treated
# as still-active so this reaper never closes a verdict out from under a run
# that might just be using a status word this function doesn't recognize yet.
#
# The four values below are EXHAUSTIVE for gate-run beads specifically, not
# guessed from the (much larger) marker vocabulary — verified by grepping
# every `set_gate_status "$GR_ID"/"$GATE_RUN_ID"` call site in both this file
# and quality-gate-dispatcher.sh (plus confirming no direct `label add
# "$GR_ID"/"$GATE_RUN_ID"` bypasses set_gate_status anywhere): a gate-run only
# ever carries running|claimed (non-terminal, the two GATE_RUNS_JSON already
# filters on) or superseded|aborted|passed|failed (terminal). error/done/
# queued/ready/dispatching/needs-rebase/parked-needs-human etc. are real
# gate-status values too, but only ever applied to MARKER beads via
# set_gate_status "$MARKER_ID" — never observed on a gate-run.
gaterun_status_terminal() {
  case "$1" in
    superseded|aborted|passed|failed) echo 1 ;;
    *)                                echo 0 ;;
  esac
}

# marker_status_from_labels <labels-string> — pure text extraction (ga-i0n83).
# Feeds reconcile_zero_verdict_run_action's marker_status arg. Returns the
# single gate-status:* value IFF exactly one is present in <labels-string>;
# otherwise empty. Never guesses between ambiguous candidates: a marker
# mid-transition (set_gate_status now adds the new label BEFORE removing the
# old one, ga-i0n83) can briefly carry TWO gate-status:* labels — a blind
# `head -1` pick could feed reconcile_zero_verdict_run_action a stale status
# and fire supersede:requeue-marker against a marker that isn't actually
# stranded. Zero matches (the pre-existing invisible-forever case, ga-5jyo8)
# already collapses to empty the same way — that function's `*)` case already
# treats empty as a safe no-op, so "ambiguous" and "absent" share one outcome.
marker_status_from_labels() {
  local labels="$1" matches n
  matches=$(printf '%s\n' "$labels" | grep -oE "gate-status:[a-z-]+" || true)
  n=$(printf '%s\n' "$matches" | grep -c .)
  if [ "$n" = "1" ]; then
    printf '%s\n' "$matches" | sed 's/^gate-status://'
  else
    printf ''
  fi
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

# open_verdict_ids_from_json <verdict_beads_json> — pure fn (ga-g4m18).
# Companion to verdict_count_from_query/verdict_bead_count_for_run, same input
# shape (the JSON array from `bd list --json --all -l type:quality-gate-verdict
# -l gate-run:<id>`), different projection: instead of a count, return the ids
# of every bead whose status is NOT closed, one per line.
#
# THE POINT (ga-g4m18): when Vector B confirms a gate-run's reviewers are all
# dead and supersedes the gate-run bead itself (supersede:dead-reviewers,
# ga-o57gn), the per-reviewer verdict beads that run spawned were never
# touched — they sat open+in_progress, assigned to the now-confirmed-dead
# reviewer session, forever (observed live: ga-ydf9v/ga-z8erc, hand-closed by
# the Mayor as a one-off). This is the pure half of the cascade-close fix —
# the live I/O half (close_dead_reviewer_verdicts, below the lib-only cutoff)
# fetches the JSON and calls this to decide which ids to close.
#
# Pure: no bd/gc I/O, deterministic given the input string — the selftest
# exercises it directly with a fixture instead of a mocked bd.
# SELFTEST-EXTRACT open-verdict-ids-from-json-fn: BEGIN
open_verdict_ids_from_json() {
  local vbs="$1"
  printf '%s\n' "$vbs" \
    | jq -r '.[]? | select((.status // "") != "closed") | .id // empty' \
    2>/dev/null || true
}
# SELFTEST-EXTRACT open-verdict-ids-from-json-fn: END

# companion_liveness_from_query <query_ok: 0|1> <marker_found_running: 0|1>
# Pure decision (ga-qj1xh): what has_live_companion_run should be, given whether
# the SHARED gate-runs query (Vector A/B prelude, GATE_RUNS_JSON below) actually
# succeeded this sweep. THE POINT: a FAILED query must never collapse to "this
# marker has no companion" — that is indistinguishable from a query that
# succeeded and genuinely found none, and has_live_companion_run is DECISIVE
# counter-evidence in reconcile_marker_action (ga-cgynn): 1 forces skip no
# matter how stale the marker looks or how many reclaims it has used. Reported
# live (ga-qj1xh, Mayor, Dolt at 215% CPU / 3-dog boot burst): the guard's own
# `bd list ... || echo "[]"` shared-prelude fetch can fail exactly when Dolt is
# under the same contention that produces real stuck markers — collapsing
# "unknown" into "definitely 0 companions" would then fire a false
# reclaim/error against a marker whose real companion gate-run IS alive, just
# invisible to this sweep's failed read. Fail-safe direction: unknown reads as
# "assume a companion might be alive" (1) — the same direction
# reconcile_marker_action already treats as "don't touch this marker," and the
# cost of guessing wrong that way is one skipped sweep, not a killed review.
# marker_found is ignored once query_ok=0 — it was computed from data we now
# know is untrustworthy, not from a genuine empty result.
companion_liveness_from_query() {
  local query_ok="$1" marker_found="$2"
  [ "$query_ok" != "1" ] && { echo 1; return; }
  [ "$marker_found" = "1" ] && { echo 1; return; }
  echo 0
}

# dedup_gaterun_action <group_count> <is_newest: 0|1>
# Pure decision: enforce ≤1 running gate-run per source-bead/marker (ga-o57gn (c)).
# The guard creates a tracking gate-run at claim time (gate-status:claimed as of
# ga-f1ngu) and the dispatcher creates its OWN at dispatch time (gate-status:
# running); a re-queued marker (dead-dispatcher recovery) then spawns yet
# another real run. Multiple gate-runs sharing a marker_id are thus normal
# transiently — but only the NEWEST is the live one; older ones are stale and
# (pre-ga-f1ngu) used to inflate the "GATES RODANDO" count by masquerading as
# :running. Keep the newest, supersede the rest — this is also what retires the
# guard's own claim receipt the sweep after a real gate-run bead lands for the
# same marker_id.
# A lone run (group_count<=1) is always kept. Returns: keep | supersede:duplicate
dedup_gaterun_action() {
  local group_count="$1" is_newest="$2"
  case "$group_count" in ''|*[!0-9]*) echo "keep"; return ;; esac
  [ "$group_count" -le 1 ] && { echo "keep"; return; }
  [ "$is_newest" = "1" ] && { echo "keep"; return; }
  echo "supersede:duplicate"
}

# dup_marker_ids_for_branch <markers_json> <branch> <exclude_id>
# Pure (no bd/gc I/O — takes the query result as data): given the JSON array of
# type:quality-gate-marker beads already filtered by the caller to
# gate-status:{ready,queued,needs-rebase} (ga-o64z1's Step 4b query), return the
# ids (one per line, empty output = none) whose description carries a `branch:`
# line EXACTLY equal to <branch>, excluding <exclude_id> (the marker THIS sweep
# just claimed) and re-checking status=open per-candidate as defense-in-depth
# (mirrors live_sibling_run_for_branch's own belt-and-suspenders status gate in
# quality-gate-dispatcher.sh — ga-tgj23 showed a label/list inconsistency can
# otherwise surface a closed bead as a false candidate). Matches on the
# DESCRIPTION's branch: line, not the branch: LABEL — the label is display-only
# for the painel (docs/gate-marker-recipe.md), the description is the field
# every real consumer (including this guard's own Step 3 extract()) trusts.
# Exact string equality, not substring/regex — avoids fix/ga-1 matching
# fix/ga-10.
dup_marker_ids_for_branch() {
  local markers_json="$1" branch="$2" exclude_id="$3"
  printf '%s\n' "$markers_json" | jq -r --arg mid "$exclude_id" --arg branch "$branch" '
    def branch_of(d): (d // "") | split("\n") | map(select(startswith("branch:"))) | (.[0] // "") | ltrimstr("branch:") | sub("^ +"; "");
    [ .[] | select(.id != $mid) | select((.status // "") == "open") | select(branch_of(.description) == $branch) | .id ] | .[]
  ' 2>/dev/null || true
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
  # ga-i0n83: ADD the new label BEFORE removing the old one(s) — the reverse
  # order (remove-then-add, pre-fix) has a window where an interrupted
  # transition (crash, Dolt hiccup between the two bd calls) leaves the bead
  # with ZERO gate-status:* labels: "unreachable by construction" (ga-5jyo8) —
  # invisible to every dispatcher/guard query that selects by
  # --label-any gate-status:{...}, undetected for days until a human manually
  # re-labels it. Add-then-remove trades that for a strictly safer failure
  # mode: an interrupted transition leaves AT MOST two gate-status labels
  # (old+new) — still selected by every existing query, still discoverable,
  # and the exact "duplicate label" shape this function already tolerates/
  # cleans up (strips ALL gate-status:* down to one) on its next successful run.
  bd -C "$GC_CITY" label add "$_id" "gate-status:$_new" -q 2>/dev/null || true
  for _lbl in $_cur; do
    [ "$_lbl" = "gate-status:$_new" ] && continue
    bd -C "$GC_CITY" label remove "$_id" "$_lbl" -q 2>/dev/null || true
  done
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

# classify_parent_gap2 <has_pilot_dispatched> <has_live_assignee> <sling_found> <sling_needs_fix> <sling_closed> [sling_refused]
# Pure decision for ga-pa36 GAP-2: parent story/bug retains story:in-flight after
# the gate ran on a sling/work bead (Pilot-dispatched path) and that bead is terminal.
# sling_needs_fix: 1 if sling bead has gate:needs-fix or gate:needs-human (gate FAILED).
# sling_closed:    1 if sling bead is closed (gate PASSED, work done).
# sling_refused (ga-eu75w, optional, defaults to 0 — old 5-arg callers unchanged):
#   1 if the sling carries an explicit pool:refused[:reason] signal (on the sling
#   itself, bridged from the parent's own labels, or only in the sling's
#   close_reason text — see gap2_refused_token). A refusal means the builder
#   declared the work out of scope and drained BEFORE any gate review ran, so
#   the sling was never actually "gate-passed" — the OLD bug read "closed + no
#   needs-fix" as proof of a pass, silently conflating an explicit refusal with
#   a real review outcome. Checked only AFTER sling_needs_fix (a genuine gate
#   failure always wins — never swallow a real rejection, even if something
#   else mistakenly also stamped pool:refused on the same bead) and only once
#   the sling has actually closed — a refusal on a still-open/in_progress sling
#   is left to inflight-reclaim-guard.py (list_refused_sling_source_beads /
#   _promote_refusal_labels), which already owns that in-flight window; GAP-2
#   only cleans up once the sling has terminated.
# Returns: free:fail-stranded | free:refused-stranded | free:pass-stranded | skip:not-dispatched | skip:live-assignee | skip:no-sling | skip:active-sling
classify_parent_gap2() {
  local has_pilot_dispatched="$1" has_live_assignee="$2" sling_found="$3" sling_needs_fix="$4" sling_closed="$5" sling_refused="${6:-0}"
  [ "$has_pilot_dispatched" != "1" ] && { echo "skip:not-dispatched"; return; }
  [ "$has_live_assignee" = "1" ]     && { echo "skip:live-assignee"; return; }
  [ "$sling_found" != "1" ]          && { echo "skip:no-sling"; return; }
  [ "$sling_needs_fix" = "1" ]       && { echo "free:fail-stranded"; return; }
  [ "$sling_closed" != "1" ]         && { echo "skip:active-sling"; return; }
  [ "$sling_refused" = "1" ]         && { echo "free:refused-stranded"; return; }
  echo "free:pass-stranded"
}

# classify_gap2_bugtask_verdict <merge_verified> <has_untracked_marker> [has_active_marker]
# — ga-6ync4: a bug/task parent's sling passed+closed is a done-SIGNAL, not proof —
# the sling can gate-pass on a review of code that never actually landed on the
# parent's own fix. Mirrors story-delivery.sh's task_reconciler_verdict (ga-266z8,
# same root flaw, different code path): require independent content/ancestry
# evidence before trusting a passed+closed sling enough to close the parent.
# ga-x2x63: "no fix/feature branch found" must not collapse to the same verdict as
# "checked and genuinely not merged" — a parent explicitly labeled delivery:untracked
# has a legitimate deliverable that is a git-ignored/untracked file edit (no branch
# could ever exist to find), and treating that structural absence as proof-of-not-done
# is the error-vs-empty class of bug (ga-p5q3/ga-eu2x). has_untracked_marker only
# matters when merge_verified didn't already succeed.
# ga-4tgga: "not (yet) verified merged" must not collapse to "abandoned" either — the
# SAME error-vs-empty shape, one signal later. A parent whose own fix has an ACTIVE
# quality-gate-marker (gate-status ready/queued/claimed/dispatching/running) is mid
# review, not orphaned: re-arming gate:needs-fix strips pilot:dispatched and lets
# Pilot dispatch a SECOND builder racing the gate's own in-flight review (observed
# live: a marker went gate-status:QUEUED at 17:58:46Z, GAP-2 declared the same bead
# unmerged-and-abandoned 74s later — ga-ffop9). has_active_marker only matters when
# neither stronger signal above already resolved the verdict.
# Returns: close:merge-verified | close:untracked-delivery | wait:active-marker | keep:merge-not-verified
classify_gap2_bugtask_verdict() {
  local merge_verified="$1" has_untracked_marker="${2:-}" has_active_marker="${3:-}"
  [ "$merge_verified" = "1" ]       && { echo "close:merge-verified"; return; }
  [ "$has_untracked_marker" = "1" ] && { echo "close:untracked-delivery"; return; }
  [ "$has_active_marker" = "1" ]    && { echo "wait:active-marker"; return; }
  echo "keep:merge-not-verified"
}

# classify_external_pr_gap3 <pr_state> <review_decision>
# Pure decision for ga-jto05 GAP-3: a story:awaiting-external-merge bead's real
# deliverable is a PR in a DIFFERENT repo (fork -> PR -> upstream-review flow,
# e.g. the beads CLI's own gastownhall/beads — bd-binary-separate-from-gascity-
# engine). GAP-1/GAP-2 above only ever check gascity-hq's own origin/main, which
# by construction never contains a foreign repo's commits, so they are
# structurally blind to this bead class. story:awaiting-external-merge's own
# doc-comment (pilot-dispatcher.sh, ga-spux4) says "no daemon watches external
# PRs for merge yet, so removal is manual" — this is that daemon.
# Cost of the gap (ga-jto05): 2 confirmed beads sat merged-but-open ~11 days
# each before a dog happened to check gh pr view by hand; a 3rd was one
# accidental GAP-2 re-arm away from the same fate.
# pr_state: MERGED | CLOSED | OPEN | "" (gh call failed, no PR ref found, or the
#   PR could not be resolved — all fold to the same fail-safe skip:indeterminate).
# review_decision: APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | "" (none
#   yet). Only consulted when pr_state=OPEN — irrelevant once the PR is terminal.
# Returns: close:merged | flag:closed-not-merged | flag:changes-requested | wait:pending | skip:indeterminate
classify_external_pr_gap3() {
  local pr_state="$1" review_decision="${2:-}"
  case "$pr_state" in
    MERGED) echo "close:merged" ;;
    CLOSED) echo "flag:closed-not-merged" ;;
    OPEN)
      if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
        echo "flag:changes-requested"
      else
        echo "wait:pending"
      fi
      ;;
    *) echo "skip:indeterminate" ;;
  esac
}

# gap2_query_active_markers — ga-4tgga: I/O helper (not pure, like set_gate_status
# above) fetching every type:quality-gate-marker whose gate-status is still ACTIVE
# (ready/queued/claimed/dispatching/running — anything short of terminal). Defined
# here in the lib region so the selftest can source + exercise its companion pure
# filter (gap2_marker_for_bead) against fixture JSON of this exact shape. Echoes
# "[]" on any query failure — fail-safe: an empty/failed fetch makes
# gap2_marker_for_bead find nothing, which flows into the existing
# keep:merge-not-verified path, never a false "found none, so it's safe to
# redispatch" from a query that actually errored.
gap2_query_active_markers() {
  # ga-4tgga gate-feedback (blocking issue 1): --all alone RE-ADMITS CLOSED
  # markers (see the --all doc comment above, ~L1371) and bd close never
  # touches labels — a marker closed as superseded/duplicate can keep a
  # stale non-terminal gate-status:{ready,queued,...} label forever
  # (live-verified: ga-wisp-qiij1x1, closed by the Mayor as superseded,
  # still carries gate-status:queued). Without --status open, that dead
  # record makes this function return a false active hit, which flows into
  # gap2_marker_for_bead -> wait:active-marker and silently masks a
  # genuinely-stranded parent — the exact failure ga-4tgga exists to fix,
  # reintroduced via a different path. Mirrors DUP_MARKERS_JSON's own
  # --all --status open convention ~200 lines below (~L1893) — nothing
  # here is a new pattern, just the one this file already established.
  # --include-infra (ga-vm20x, Mayor 07/08): this file's own Step 1 fix
  # (~L2252 below) already covers the SAME blindness for a different query —
  # markers are born --ephemeral (INFRA), hidden from `bd list` by default
  # under bd 1.1.0. This gap2_* helper was missed in that pass; without the
  # flag it silently returns fewer active markers than really exist, which
  # flows into gap2_marker_for_bead as a false "no active marker" and can
  # mask a genuinely gate-active parent (the same failure shape ga-4tgga
  # fixed for the closed-marker case just above).
  bd -C "$GC_CITY" list --json --all --include-infra --status open \
    -l type:quality-gate-marker \
    --label-any gate-status:ready \
    --label-any gate-status:queued \
    --label-any gate-status:claimed \
    --label-any gate-status:dispatching \
    --label-any gate-status:running \
    2>/dev/null || echo "[]"
}

# gap2_marker_for_bead <active_markers_json> <bead_id> — pure jq filter (no I/O of
# its own; <active_markers_json> is whatever gap2_query_active_markers returned).
# Echoes "<marker_id> <gate-status-value>" for the first active marker matching
# <bead_id>, or empty if none. Matches on EITHER signal, the same dual-source
# convention the dispatcher's own BEAD_ID resolution uses: the source-bead:<id>
# LABEL (present once the guard has claimed+parked the marker — Step 6/7 below,
# wa-qq33j) OR a `bead_id: <id>` line in the DESCRIPTION (present from creation per
# the canonical /gate-done recipe, docs/gate-marker-recipe.md — the ONLY signal
# available while the marker still sits gate-status:ready, before any guard sweep
# has touched it). Checking the label alone would miss exactly the freshest,
# not-yet-claimed submissions — the description field is the MANDATORY one per
# that doc; the label is "secondary/display". Line-anchored (not a bare substring
# test) so bead_id ga-ffop9 does not false-match a description carrying ga-ffop9x.
gap2_marker_for_bead() {
  local json="$1" bid="$2"
  [ -z "$bid" ] && return 0
  printf '%s' "$json" | jq -r --arg b "$bid" '
    .[] | select(
      ((.labels // []) | index("source-bead:" + $b)) or
      # ga-4tgga gate-feedback (secondary, non-blocking): do NOT splice $b
      # into a regex — dotted sub-bead IDs (ga-sb11i.2 is a real, live shape
      # in this city) put a "." in the QUERY, which as a spliced-in pattern
      # matches ANY character, so a query for ga-sb11i.2 could false-match
      # an UNRELATED marker whose description says ga-sb11iX2. Match the
      # "bead_id:" prefix with a FIXED (non-interpolated) regex, strip it,
      # then compare the remainder to $b via plain string equality — zero
      # regex-metachar risk from bid, whatever characters it contains.
      ((.description // "") | split("\n") | any(
        test("^bead_id:[ \t]*") and
        ((sub("^bead_id:[ \t]*"; "") | sub("[ \t]*$"; "")) == $b)
      ))
    ) |
    "\(.id) \((.labels // []) | map(select(startswith("gate-status:"))) | .[0] // "gate-status:unknown" | sub("^gate-status:"; ""))"
  ' 2>/dev/null | head -1
}

# gap2_refused_token <sling_labels> <parent_labels> <sling_close_reason> — pure
# text scan (ga-eu75w). A worker refusing pool-ineligible work (e.g. a fix that
# needs an engine rebuild) stamps pool:refused[:<reason-slug>] somewhere before
# the sling terminates — but WHERE varies by observed precedent, not a single
# documented contract: the ps-worker/wa-worker refusal protocol labels the
# SLING itself and leaves it for inflight-reclaim-guard.py to close; a
# dog-pool refusal observed live (ga-1ztxb / its sling ga-0hela) instead
# labeled the PARENT directly and closed the sling itself, with the marker
# surfacing on the sling only in its own close_reason text — confirmed live:
# ga-0hela's own labels are just ["ctx:ready","exec:auto"], no pool:refused
# anywhere on the sling itself. Checking any ONE location would have missed
# that real incident, so this checks all three, in priority order (the
# sling's own label first — the documented/most-authoritative source), and
# returns the FIRST literal pool:refused[:<reason>] token found, or "" if
# none. A bare "pool:refused" (no reason suffix) is a valid, complete match.
gap2_refused_token() {
  local sling_labels="$1" parent_labels="$2" sling_close_reason="$3" tok=""
  tok=$(printf '%s' "$sling_labels" | grep -oE 'pool:refused(:[A-Za-z0-9_-]+)?' | head -1 || echo "")
  [ -z "$tok" ] && tok=$(printf '%s' "$parent_labels" | grep -oE 'pool:refused(:[A-Za-z0-9_-]+)?' | head -1 || echo "")
  [ -z "$tok" ] && tok=$(printf '%s' "$sling_close_reason" | grep -oE 'pool:refused(:[A-Za-z0-9_-]+)?' | head -1 || echo "")
  printf '%s' "$tok"
}

# gap2_free_refused_stranded <bead_id> <sling_id> <refused_token> — ga-eu75w:
# the refused-parallel to gap2_arm_needs_remerge() below. A sling that closed
# via an explicit worker refusal never reached a real gate review, so the OLD
# default behavior here (falling through to free:pass-stranded, since a
# refused sling usually carries no gate:needs-fix either) asserted a review
# outcome that never happened — a parent left with gate:needs-fix/
# gate:needs-remerge but no branch and no gate-run anywhere is exactly what
# gate-orphaned-label-watchdog.sh's own detection criterion is, and nothing
# upstream ever resolved it, so the watchdog re-flagged the same beads every
# cycle forever (measured: ga-1ztxb, ga-6bghe, ga-aw0db/ga-avvu2, same night).
# Extracted into its own function — like gap2_arm_needs_remerge — so the
# selftest can call it directly with a mocked bd() and assert on the ACTUAL
# label remove/add calls it makes (ga-4tgga attempt-2's lesson: a comment
# that only CLAIMS labels were cleared, without the bd calls to back it up,
# is worse than no comment — it tells the next reader to stop looking here).
# Clears ONLY the four gate:* labels that can carry the false claim (never a
# wildcard gate:* strip) — gate:needs-human* and gate:passed are structurally
# unreachable by this function. Stamps the REAL reason (idempotent if a
# worker already stamped pool:refused directly on the parent, per the
# ga-1ztxb precedent) and frees the lane like the fail/pass-stranded arms.
# Freeing the lane here does not reopen a re-dispatch loop: pilot-dispatcher.sh's
# _filter_candidates already excludes any bead carrying pool:refused[:*] from
# future dispatch consideration (ga-y8qh) — the SAME label this function
# stamps is what stops Pilot from re-selecting this bead and walking a fresh
# builder into the identical refusal.
gap2_free_refused_stranded() {
  local bead_id="$1" sling_id="$2" refused_token="$3"
  [ -z "$refused_token" ] && refused_token="pool:refused"
  bd -C "$GC_CITY" label remove "$bead_id" "gate:needs-fix"     -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "gate:needs-remerge" -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "gate:queued"        -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "gate:failed"        -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "story:in-flight"    -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "pilot:dispatched"   -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$bead_id" "$refused_token"     -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$bead_id" "ga-pa36 GAP-2 reconciler (ga-eu75w): sling bead $sling_id closed via an explicit worker refusal ($refused_token), not a gate review — no branch or gate-run ever existed for this attempt, so gate:needs-fix/needs-remerge/queued/failed would have asserted a review outcome that never happened (the exact false state gate-orphaned-label-watchdog.sh kept flagging forever). Those labels are now removed; story:in-flight + pilot:dispatched cleared; $refused_token stamped on this bead so pilot-dispatcher.sh's _filter_candidates (ga-y8qh) excludes it from re-dispatch instead of walking a fresh builder into the same refusal. gate:needs-human* labels, if any, are left untouched." 2>/dev/null || true
}

# gap2_arm_needs_remerge <bead_id> <sling_id> — ga-4tgga: the genuine
# "abandoned, needs resubmit" outcome (classify_gap2_bugtask_verdict's
# default `*)` case, after the race-guard recheck finds no active marker).
# Extracted into its own function — like gap2_query_active_markers and
# gap2_marker_for_bead above — specifically so the selftest can call it
# directly with a mocked bd() and assert on the ACTUAL label-remove calls it
# makes, not merely that it posts a comment claiming to have made them.
# ga-4tgga gate-feedback (attempt 2, blocking): this arm's comment has always
# CLAIMED "story:in-flight + pilot:dispatched cleared", mirroring the
# close:merge-verified / close:untracked-delivery arms which strip both
# labels before their terminal action — but attempt 2's version of this body
# never made the two `bd label remove` calls that would have made the claim
# true. The two labels survived, so the bead stayed permanently invisible to
# every Pilot dispatch query (all of which --exclude-label story:in-flight
# and --exclude-label pilot:dispatched), permanently holding its lane slot,
# while this exact sweep kept re-selecting the same bead and re-posting the
# same false "cleared" claim every pass — a comment that promises more than
# the code delivers is worse than no comment, because it tells the next
# reader to stop looking here (Mayor, 2026-08-06). Strip both BEFORE
# re-arming, mirroring the close:* arms exactly.
gap2_arm_needs_remerge() {
  local bead_id="$1" sling_id="$2"
  bd -C "$GC_CITY" label remove "$bead_id" "story:in-flight"  -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "pilot:dispatched" -q 2>/dev/null || true
  # ga-e2n96: this arm is a PURE re-merge signal — no reviewer ever rejected
  # $bead_id's code, the sling already gate-passed. Reusing bare
  # gate:needs-fix for this made it indistinguishable from a real reviewer
  # rejection to the Pilot dispatcher (and every other consumer of the
  # label), which then dispatched a builder with a completely empty brief.
  # gate:needs-remerge is the reconciler's OWN signal for "resubmit, nothing
  # is broken" — set ADDITIVELY (gate:needs-fix stays too) so every existing
  # gate:needs-fix consumer/filter keeps working unchanged; the Pilot
  # dispatcher checks for gate:needs-remerge FIRST and resubmits/escalates
  # instead of slinging a builder.
  bd -C "$GC_CITY" label add "$bead_id" "gate:needs-fix" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add "$bead_id" "gate:needs-remerge" -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$bead_id" "ga-pa36 GAP-2 reconciler: sling bead $sling_id gate-passed+closed, but no independent evidence the parent's own fix ($bead_id) is merged into origin/main was found (checked branches fix/$bead_id*, feature/$bead_id*, and sling fix/$sling_id*, feature/$sling_id*). ga-6ync4 fix: never trust sling-passed alone. story:in-flight + pilot:dispatched cleared; gate:needs-fix + gate:needs-remerge set (ga-e2n96: needs-remerge is the distinct re-submission signal — no reviewer ever rejected this code) so Pilot resubmits the existing branch to the gate or escalates, instead of dispatching a builder with an empty brief. (If this parent's delivery is legitimately untracked, apply the delivery:untracked label — see ga-x2x63.)" 2>/dev/null || true
}

# gap2_apply_pass_verdict <bead_id> <sling_id> <is_story_approved> <verdict> —
# ga-1un0n: the SHARED terminal action for free:pass-stranded's two
# affirmative verdicts (close:merge-verified / close:untracked-delivery).
# Extracted — like gap2_arm_needs_remerge and gap2_free_refused_stranded
# above — so the selftest can call it directly with a mocked bd() and assert
# on the ACTUAL label/close calls it makes.
#
# Root cause this closes: the OLD code let a story:approved parent skip
# classify_gap2_bugtask_verdict ENTIRELY and set gate:passed straight off
# "sling closed, didn't fail" — story:approved is PRODUCT approval, not proof
# a reviewer ever ran. Measured live TWICE in ~1h (ga-qhca1, ga-x3e7p):
# gate:passed landed on a parent while its real gate-run was still
# gate-status:running, no verdict — story-delivery.sh's independent merge
# verification (ga-mmdm2) is what actually stopped a real merge both times,
# not this reconciler. Both parent types now reach this function through the
# IDENTICAL classify_gap2_bugtask_verdict call (see the free:pass-stranded
# arm below) — only the terminal action differs: a story hands off via
# gate:passed (story-delivery.sh owns deploy + story:done, and re-verifies
# merge itself, ga-mmdm2); a bug/task has no further delivery step, so it is
# closed directly here, unchanged from before.
#
# Returns 1 (no-op, no bd calls) for any verdict other than the two close:*
# ones — a caller must never be able to mistake "I called this with the
# wrong verdict" for "it acted".
gap2_apply_pass_verdict() {
  local bead_id="$1" sling_id="$2" is_story="$3" verdict="$4"

  case "$verdict" in
    close:merge-verified|close:untracked-delivery) : ;;
    *) return 1 ;;
  esac

  bd -C "$GC_CITY" label remove "$bead_id" "story:in-flight"  -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$bead_id" "pilot:dispatched" -q 2>/dev/null || true

  if [ "$is_story" = "1" ]; then
    local story_reason=""
    case "$verdict" in
      close:merge-verified)
        story_reason="parent's own fix verified merged into origin/main (ga-6ync4)"
        ;;
      close:untracked-delivery)
        story_reason="parent carries delivery:untracked (ga-x2x63) — no git artifact is expected by design, so merge verification was skipped and the sling-passed signal is trusted"
        ;;
    esac
    bd -C "$GC_CITY" label add "$bead_id" "gate:passed" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$bead_id" "ga-pa36 GAP-2 reconciler (ga-1un0n): sling bead $sling_id gate-passed and closed, and $story_reason. story:in-flight + pilot:dispatched cleared; gate:passed set — story-delivery will deploy and mark story:done." 2>/dev/null || true
  else
    # ga-1un0n: bug/task messages preserved VERBATIM from the pre-fix code —
    # this path's behavior is unchanged, only its verification gate moved.
    case "$verdict" in
      close:merge-verified)
        bd -C "$GC_CITY" close "$bead_id" \
          -r "ga-pa36 GAP-2 reconciler: sling bead $sling_id gate-passed and closed, and parent's own fix verified merged into origin/main (ga-6ync4) — work is done; closing parent." \
          2>/dev/null || warn "Could not close parent $bead_id after pass-stranded detection"
        ;;
      close:untracked-delivery)
        bd -C "$GC_CITY" close "$bead_id" \
          -r "ga-pa36 GAP-2 reconciler: sling bead $sling_id gate-passed and closed; parent carries delivery:untracked (ga-x2x63) — no git artifact is expected by design, so merge verification was skipped and the sling-passed signal is trusted; closing parent." \
          2>/dev/null || warn "Could not close parent $bead_id after pass-stranded detection (untracked delivery)"
        ;;
    esac
  fi
}

# check_source_bead_park <space_sep_labels>
# Pure decision: should the gate park a marker because the source-bead is in a
# state that must not enter the review cycle?
#   story:needs-approval — bead was never product-approved; the gate would spawn
#     reviewers who reject it, the crew re-submits, and the cycle repeats forever.
#   gate:needs-human / gate:needs-human:* (EXCEPT :partial-delivery, see below)
#     — bead is circuit-broken and requires human intervention; the same
#     re-submit loop applies.
#   gate:needs-human:partial-delivery — ga-o5de8: NOT a circuit-break. This
#     sub-reason is the ga-k2wjn/ga-zhfk8 scope backstop holding a gate-PASSED
#     bead open because its body looks like it enumerates more deliverables
#     than the one diff that was just reviewed covered (see
#     gate_delivery_looks_partial in quality-gate-dispatcher.sh). Parking Step
#     5a on it deadlocked: the only way to clear the label is to merge a branch
#     that delivers the missing item, and merging requires passing Step 5a
#     first. So a source bead carrying gate:needs-human(:partial-delivery) with
#     NO OTHER circuit-break sub-reason present is left eligible for review — a
#     freshly submitted marker is NOT parked here. This does not reopen the
#     door to premature closure: the scope check re-runs at PASS/merge time
#     (quality-gate-dispatcher.sh's IS_PARTIAL branch) and re-holds the bead —
#     open, delivery:partial, gate:needs-human:partial-delivery — regardless of
#     which branch merged, until some diff actually adds scope_covered:all.
#     This function only ever gates whether Step 5a spawns a reviewer, never
#     whether the bead is allowed to close.
#   gate:needs-fix ALONE is NOT a park reason — it is the normal fix-iterate path
#     (crew fixed, re-submitted; gate should review it).
# The check is FAIL-OPEN: if labels are empty/unrecognized, returns "ok" so a
# network hiccup never blocks a legitimate story:approved submission.
# Returns: ok | park:needs-approval | park:needs-human
check_source_bead_park() {
  local labels="$1" lbl
  local saw_bare=0 saw_partial_delivery=0 saw_other_reason=0
  for lbl in $labels; do
    case "$lbl" in
      story:needs-approval) echo "park:needs-approval"; return ;;
    esac
  done
  for lbl in $labels; do
    case "$lbl" in
      gate:needs-human:partial-delivery) saw_partial_delivery=1 ;;
      gate:needs-human:*)                saw_other_reason=1 ;;
      gate:needs-human)                  saw_bare=1 ;;
    esac
  done
  # A genuine (non-partial-delivery) circuit-break sub-reason always parks,
  # even alongside a co-present partial-delivery label.
  [ "$saw_other_reason" = "1" ] && { echo "park:needs-human"; return; }
  # partial-delivery-only (with or without the bare co-tag) — exempt (ga-o5de8).
  [ "$saw_partial_delivery" = "1" ] && { echo "ok"; return; }
  # bare gate:needs-human with no sub-reason at all — preserve prior behavior.
  [ "$saw_bare" = "1" ] && { echo "park:needs-human"; return; }
  echo "ok"
}

# matching_veto_labels <space_sep_labels> <prefix> — ga-6qbgy.
# Echoes the space-joined subset of <labels> that equal <prefix> exactly OR
# start with "<prefix>:" (the same bare-or-colon-suffixed rule
# check_source_bead_park() above uses to PARK — kept in sync by inspection,
# same idiom as resolve_author_agent_alias's deny-list comment below).
#
# WHY THIS EXISTS: check_source_bead_park() above deliberately collapses
# gate:needs-human, gate:needs-human:technical, gate:needs-human:refused,
# etc. into one generic "park:needs-human" token — correct for the yes/no
# park decision, but the caller then had no way to say WHICH label actually
# fired. It hardcoded the bare prefix name in the park message instead
# ("carries gate:needs-human"). `bd label remove` only removes an EXACT
# name, so an operator who reads that message, removes the bare
# gate:needs-human label, and re-checks BY EXACT NAME sees a clean list and
# declares the veto cleared — while gate:needs-human:technical (a label
# they never saw named) silently keeps parking every resubmission. Real
# incident: wa-vcd01, 2026-08-06 — ~4h of blocked crew work plus a dead
# marker requiring manual resubmission, because the verification the
# operator ran was incapable of detecting the state it was checking for.
# This function lets a caller cite the label(s) that ACTUALLY matched
# instead of the prefix family name, so the message people act on is never
# less specific than the guard's own decision.
matching_veto_labels() {
  local labels="$1" prefix="$2" lbl out=""
  for lbl in $labels; do
    case "$lbl" in
      "$prefix"|"$prefix":*)
        out="${out:+$out }$lbl" ;;
    esac
  done
  printf '%s' "$out"
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
  local agent agent_sessions_json
  # ga-07rb3: the prior `| head -1 || true` swallowed a gc failure the same
  # way as a legitimate zero-match result — both silently produced an empty
  # $agent. That happens to already be this function's safe/best-effort
  # fallback (see the docstring above: caller falls back to no agent alias),
  # so behavior is unchanged; gc_json_or_unknown just makes the distinction
  # explicit instead of accidental, consistent with every other site fixed
  # by this story.
  agent_sessions_json=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json) || true
  agent=$(printf '%s' "$agent_sessions_json" | jq -r --arg a "$author" \
        '(if type=="array" then . else (.sessions // []) end)[]
         | select(.closed != true)
         | select((.session_name==$a) or (.id==$a) or (.name==$a) or (.alias==$a) or (.agent_name==$a))
         | (.alias // .name // .agent_name // empty)' 2>/dev/null | head -1)
  [ "$agent" = "$author" ] && agent=""
  [ "$agent" = "null" ] && agent=""
  printf '%s' "$agent"
}

# session_matches_author <author> <sessions_json>
# Pure predicate — canonical liveness check shared by GAP-1, GAP-2, and (via a
# thin wrapper) quality-gate-dispatcher.sh's author_is_alive(). Echoes 1 iff
# <author> matches the session_name, name, alias, id, or agent_name of some
# non-closed, non-dead-state session in <sessions_json>; 0 otherwise (empty
# author, no match, or unparseable JSON). <sessions_json> may be a bare array
# or the {"sessions":[...]} shape (both `gc session list --json` and its
# cache shim emit the latter).
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
#
# ga-625z4: `.closed != true` alone is not sufficient — a session row can sit
# closed:false in a non-working `state` (asleep/drained/etc) indefinitely.
# GAP-1 safe-skipped forever on exactly this shape: an HQ story bead's
# assignee is the always-live orchestrating owner (e.g. gastown__mayor), so
# `.closed` never flips even after the actual builder/sling session that did
# the work went dormant and the fix had already landed (ga-eiv38 stuck 13h
# this way — gate-done marker present, sling bead closed, PR unmerged).
# Mirrors _POOL_DEAD_STATES in scripts/inflight-reclaim-guard.py: excluding
# dead states is a strict superset of the old behavior (it only REMOVES
# matches already provably dead by state), so rows carrying no `state` key
# at all — including every row in the existing selftest fixture — still
# match exactly as before. Conservative by construction: unknown or missing
# state keeps reading as alive, never a new way to fail-closed.
session_matches_author() {
  local author="${1:-}" sessions_json="${2:-}"
  [ -z "$author" ] && { echo 0; return 0; }
  if printf '%s' "$sessions_json" | jq -e --arg a "$author" \
       'def dead_states: ["asleep","drained","closed","archived","quarantined","failed-create"];
        [(if type=="array" then . else (.sessions // []) end)[]
         | select(.closed != true)
         | select((.state // "") as $s | ($s == "" or (dead_states | index($s)) == null))
         | (.session_name, .name, .alias, .id, .agent_name)]
        | map(select(. != null and . != ""))
        | index($a) != null' >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# _gate_delivery_header_class <line> — ga-1yxyt: classifies a single candidate
# section-header line as "scope" (a SCOPE/WORK header: FIX PEDIDO,
# ENTREGAVEIS, ESCOPO, CRITERIO DE ACEITE, O QUE FAZER), "diagnostic" (a
# DIAGNOSTIC/OBSERVATION header: O CICLO, A CADEIA, SINTOMA, A MEDICAO, O
# DEFEITO, EVIDENCIA, COMO ACONTECE), or "unknown" (neither recognized).
# Case- and accent-insensitive: this city's bug reports mix
# "CRITÉRIO"/"CRITERIO", "MEDIÇÃO"/"MEDICAO" freely depending on author.
#
# ga-cjrxh: a third class, "verification". CRITERIO DE ACEITE moved OUT of
# "scope" into it — measured 2026-08-06 against ga-tqe4j, whose held run sits
# under "=== CRITERIO DE ACEITE (falsificavel) ===". ga-1yxyt listed that
# header as scope vocabulary, but its own fixture only exercised "FIX PEDIDO"
# with list structure (ga-o5de8's CRITERIO section used "· " bullets, which
# never form a run), so nothing actually asserted the CRITERIO classification
# — the reclassification breaks no existing assertion. Acceptance criteria
# enumerate how ONE deliverable will be PROVEN, which is the opposite of
# enumerating several approved deliverables.
#
# _gate_delivery_norm <s> — uppercase + deaccent, the shared normalizer.
# ga-cjrxh BUGFIX (measured, not theorized): the inline version this replaces
# deaccented only UPPERCASE vowels, but `tr '[:lower:]' '[:upper:]'` is
# byte-wise and leaves multibyte "é" untouched — so a lowercase-accented
# header never got folded. Measured against ga-05604.2, whose real header is
# "=== CRITÉRIO DE ACEITE (falsificável) ===": it classified as "unknown"
# instead of matching the CRITERIO vocabulary at all. ga-1yxyt's fixtures
# happened to be written in caps, so nothing caught it. Deaccent BOTH cases
# first, then uppercase.
_gate_delivery_norm() {
  printf '%s' "${1:-}" \
    | sed -e 's/[áàâãÁÀÂÃ]/a/g; s/[éêÉÊ]/e/g; s/[íîÍÎ]/i/g; s/[óôõÓÔÕ]/o/g; s/[úûÚÛ]/u/g; s/[çÇ]/c/g' \
    | tr '[:lower:]' '[:upper:]'
}

_gate_delivery_header_class() {
  local norm
  norm=$(_gate_delivery_norm "$1")
  # Checked FIRST: "CRITERIO DE ACEITE" would otherwise be caught by the
  # scope branch below, which is exactly the ga-tqe4j false positive.
  # (GATE-FEEDBACK ga-wisp-05gt4qu, same class, found by self-audit rather than
  # by the reviewer: these are SUBSTRING matches by design — a header reads
  # "=== CRITERIO DE ACEITE (falsificavel) ===" — but bare "AC[0-9]" would then
  # fire on any header merely CONTAINING "ac" before a digit. Anchored to a word
  # start; the rest stay substrings on purpose.)
  if printf '%s' "$norm" | grep -Eq 'CRITERIO DE ACEITE|CRITERIOS DE ACEITE|COMO TESTAR|VERIFICACAO|PLANO DE TESTE|TESTES?:|\bAC[0-9]'; then
    echo "verification"; return 0
  fi
  if printf '%s' "$norm" | grep -Eq 'FIX PEDIDO|ENTREGAVEIS|ESCOPO|O QUE FAZER'; then
    echo "scope"; return 0
  fi
  if printf '%s' "$norm" | grep -Eq 'O CICLO|A CADEIA|SINTOMA|A MEDICAO|O DEFEITO|EVIDENCIA|COMO ACONTECE'; then
    echo "diagnostic"; return 0
  fi
  echo "unknown"
}

# _gate_delivery_item_is_verification <item_line> — ga-cjrxh. Is ONE list item
# a verification/constraint step rather than a deliverable? The header rule
# above only fires when the author wrote a recognizable header; this is the
# rule that generalizes when they did not. Three signals, all anchored at the
# START of the item's text (after its "1." / "a." marker), never as a
# substring — "Adicionar teste de regressao" is a DELIVERABLE that merely
# mentions a test, and must keep counting:
#   · a verification LABEL     — FIXTURE:, CONTROLE, AC1, CENARIO, INVARIANTE…
#   · a test VERB in infinitive — rodar, conferir, medir, verificar, validar…
#     (deliverables read as change verbs: corrigir, adicionar, remover, mover)
#   · a NEGATION               — "NAO mudar o CAP" (Mayor's item (e)): never a
#     deliverable, it is a scope RESTRICTION satisfied by doing nothing.
_gate_delivery_item_is_verification() {
  local norm
  # Strip the list marker ("1. ", "a. ", "A. ") and any leading space, then
  # normalize case/accents the same way the header classifier does.
  norm=$(_gate_delivery_norm "$(printf '%s' "$1" \
    | sed -E 's/^[[:space:]]*([0-9]{1,2}|[A-Za-z])\.[[:space:]]*//')")
  # GATE-FEEDBACK ga-wisp-05gt4qu: the \b is LOAD-BEARING and was missing here
  # while its sibling verb alternation below already had it. Without it, any
  # deliverable that merely shares a PREFIX with a short label was silently
  # counted as verification — measured: "Provavelmente resolve..." hit PROVA,
  # "Controlemos os efeitos..." hit CONTROLE, "Evidenciar o problema..." hit
  # EVIDENCIA. A silent -1 on the deliverable count flips an exactly-3-item
  # real multi-scope run from HOLD to RELEASE, and can drop it under the
  # ADVISORY bar too, so not even the warning fires.
  printf '%s' "$norm" | grep -Eq \
    '^(FIXTURE|CONTROLE|CONTROL|CENARIO|CASO DE TESTE|INVARIANTE|PLACAR|REGRESSAO|EVIDENCIA|PROVA|BASELINE)\b' \
    && return 0
  # AC1/AC10/AC11 — deliberately NOT \b-anchored, and therefore split out of the
  # alternation above instead of taking a blanket \b on the whole group: \b
  # between two DIGITS is not a boundary, so "AC[0-9]\b" stops matching at AC10.
  printf '%s' "$norm" | grep -Eq '^AC[0-9]' && return 0
  printf '%s' "$norm" | grep -Eq \
    '^(RODAR|CONFERIR|MEDIR|VERIFICAR|VALIDAR|CHECAR|TESTAR|GARANTIR|CONFIRMAR|REPRODUZIR|PROVAR|ASSERTAR|OBSERVAR)\b' \
    && return 0
  printf '%s' "$norm" | grep -Eq '^(NAO|NUNCA|JAMAIS)\b' && return 0
  return 1
}

# _gate_delivery_list_run <text> <line_regex> <label>
# ga-zhfk8: structural half of gate_delivery_looks_partial. Finds the longest
# run of >=3 lines in <text> that each match <line_regex> anchored at the
# start of the line, tolerating INDENTED non-matching lines in between as
# wrapped continuations of the previous item's text (e.g. "1. foo,\n   bar."
# — a realistic way to write a deliverables list, not just one line per
# item). A line that is blank, OR non-blank but NOT indented (flush-left
# prose — a new paragraph/sentence, not a continuation of the item above),
# ends the run instead. On a qualifying run, prints "detectei (<label>):"
# followed by the matched item-start lines — so a caller can quote real
# evidence in the hold message instead of asserting without showing (ga-zhfk8
# fix 3) — and returns 0. Prints nothing and returns 1 otherwise.
#
# ga-zhfk8 fix attempt 2 (gate-rejected attempt 1): a STRICT no-gap
# consecutive-line requirement regressed on exactly this wrapped-item shape —
# any non-matching line, including an indented continuation, reset the run to
# zero, so a genuine 3-item list where each item's rationale wraps to a
# second line never reached the threshold (empirically confirmed by the
# reviewer against this file's pre-fix logic). The indented/flush-left
# distinction restores that case without reopening the ORIGINAL bug this
# backstop exists to fix: prose with scattered flush-left lines that merely
# LOOK like list markers (see the "non-consecutive numbered refs in unrelated
# prose" and wa-zlgye fixtures in the selftest) still does not accumulate a
# run, because those in-between lines are not indented.
#
# ga-1yxyt: a qualifying run only counts toward `best` if the nearest
# preceding flush-left, non-blank line (the run's "header", tracked via
# `pending_header` — blank lines are skipped over, indented continuation
# lines never touch it) does NOT classify as "diagnostic" via
# _gate_delivery_header_class. This is the fix for ga-o5de8: a numbered list
# under "O CICLO:" describes the 3-step DEADLOCK being reported, not 3
# approved deliverables — v2 (ga-zhfk8) found the list structure correctly
# but had no notion of what the list was FOR. A "scope" header or no
# recognizable header at all (fail-safe — see ga-1yxyt's own AC) both still
# count, same as before this fix; only a confirmed "diagnostic" header newly
# excludes a run. Excluding a run does not zero it out silently — a LONGER
# diagnostic run yields the slot to a SHORTER qualifying one found elsewhere
# in the same text, so a real partial-scope list past a diagnostic section
# is still caught.
#
# ga-cjrxh: a run is now scored by its DELIVERABLE count, not its raw item
# count — verification items (see _gate_delivery_item_is_verification) stay in
# the run for continuity and for the quoted evidence, but do not count toward
# the >=3 threshold. This is what fixes ga-05604.2, where 2 real fix items + 1
# fixture + 1 negative constraint counted as 4. A run under a "verification"
# header is skipped wholesale, same as "diagnostic".
# _gate_delivery_run_verdict <header> — ga-cjrxh direction (c), softened by
# what measuring the real bodies showed. Taken literally, (c) says "only hold
# when the list is in a SCOPE section". Measured against the three original
# ga-k2wjn true positives, that would have RELEASED wa-k0m1q, whose list is
# headed "Os 11 itens, na ordem em que ele pediu:" — no scope vocabulary at
# all. So an ENUMERATING header (>=3 units) counts as scope-equivalent.
#
# What is left over — a qualifying run under a header that is neither scope,
# nor enumerating, nor recognizably diagnostic/verification — is the case that
# produced the measured 75% false-positive rate (ga-tqe4j's "POR QUE E O PIOR
# CASO DESSA CLASSE", ga-05604.2's criteria section). ga-1yxyt made that case
# HOLD, as its fail-safe. ga-cjrxh reverses the fail-safe deliberately, and
# says why: holding good work is the EXPENSIVE, SILENT error (the bead stops,
# does not shout, and the triage lands on the Mayor), while releasing is
# cheap — "preferir errar liberando + reportando a errar segurando". The
# "+ reportando" is not optional, and is why this is a THIRD verdict rather
# than a silent release: the caller emits an advisory naming the header it
# could not classify, so the signal survives without blocking the merge.
_gate_delivery_run_verdict() {
  local cls
  cls=$(_gate_delivery_header_class "$1")
  case "$cls" in
    diagnostic|verification) echo "skip";  return 0 ;;
    scope)                   echo "hold";  return 0 ;;
  esac
  if _gate_delivery_enumerates "$1" >/dev/null 2>&1; then echo "hold"; return 0; fi
  echo "advisory"
}

_gate_delivery_list_run() {
  local text="$1" pattern="$2" label="$3" line verdict
  local run="" run_n=0 run_d=0 run_header="" pending_header=""
  local best="" best_d=0 adv="" adv_d=0 adv_hdr=""
  # Inlined twice (loop body + post-loop flush) rather than factored into a
  # helper, because it mutates five locals — same shape as the pre-ga-cjrxh
  # code, which flushed in both places for the same reason.
  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -Eq "$pattern"; then
      [ "$run_n" -eq 0 ] && run_header="$pending_header"
      run="${run}${line}"$'\n'
      run_n=$((run_n + 1))
      _gate_delivery_item_is_verification "$line" || run_d=$((run_d + 1))
    elif printf '%s' "$line" | grep -Eq '^[[:space:]]+[^[:space:]]'; then
      : # indented, non-blank, non-matching: wrapped continuation of the
        # current item's text — does not break the run, not counted, and
        # (ga-1yxyt) never updates pending_header — a continuation is part
        # of the item's own text, not a new section header.
    else
      verdict=$(_gate_delivery_run_verdict "$run_header")
      if [ "$verdict" = "hold" ] && [ "$run_d" -gt "$best_d" ]; then
        best="$run"; best_d=$run_d
      elif [ "$verdict" = "advisory" ] && [ "$run_d" -gt "$adv_d" ]; then
        adv="$run"; adv_d=$run_d; adv_hdr="$run_header"
      fi
      run=""; run_n=0; run_d=0; run_header=""
      [ -n "$line" ] && pending_header="$line"
    fi
  done <<EOF
$text
EOF
  verdict=$(_gate_delivery_run_verdict "$run_header")
  if [ "$verdict" = "hold" ] && [ "$run_d" -gt "$best_d" ]; then
    best="$run"; best_d=$run_d
  elif [ "$verdict" = "advisory" ] && [ "$run_d" -gt "$adv_d" ]; then
    adv="$run"; adv_d=$run_d; adv_hdr="$run_header"
  fi
  if [ "$best_d" -ge 3 ]; then
    printf 'detectei (%s):\n%s' "$label" "$best"
    return 0
  fi
  # Not a hold — but if an unclassifiable run cleared the same bar, hand the
  # caller something to warn with instead of dropping the signal on the floor.
  if [ "$adv_d" -ge 3 ] && [ -z "${_GDLR_ADVISORY:-}" ]; then
    _GDLR_ADVISORY=$(printf '%s de %d itens sob cabecalho nao classificado "%s"' \
      "$label" "$adv_d" "$(printf '%s' "$adv_hdr" | cut -c1-60)")
    _GDLR_ADVISORY_EVIDENCE="$adv"
  fi
  return 1
}

# _gate_delivery_enumerates <string> — ga-cjrxh direction (d), reinforced by
# the Mayor's measurement: across the 4 holds sampled on 2026-08-05, the one
# signal that separated the single TRUE positive from the 3 false ones was an
# explicit COUNT in the bead's TITLE — wa-se0zu's reads "prod diverge do
# mockup em 8 pontos". Cheap, independent of how the author formatted the
# body, and it still fires when the body list is written in a shape the
# structural patterns miss.
#
# Applied to the run's own HEADER as well as the title, because measuring the
# real bodies showed the header carries the same signal: wa-k0m1q — one of the
# three original ga-k2wjn true positives — heads its list with "Os 11 itens,
# na ordem em que ele pediu:". That header is not in any scope vocabulary, so
# a scope-header-only rule (direction (c) taken literally) would have RELEASED
# a known real partial delivery. The enumeration is what saves it.
#
# Prints the matched phrase, returns 0, iff it enumerates >=3 units — the same
# >=3 threshold the rest of this guard uses, so "2 pontos" is not multi-scope.
_gate_delivery_enumerates() {
  local norm n
  norm=$(_gate_delivery_norm "${1:-}")
  n=$(printf '%s' "$norm" \
    | grep -oE '[0-9]{1,3}[[:space:]]+(PONTOS|ITENS|FRENTES|LUGARES|PARTES|CASOS|ETAPAS|TELAS|ARQUIVOS)\b' \
    | head -1 || true)
  [ -n "$n" ] || return 1
  [ "$(printf '%s' "$n" | grep -oE '^[0-9]{1,3}')" -ge 3 ] 2>/dev/null || return 1
  printf '%s' "$n"
  return 0
}

# gate_delivery_looks_partial <bead_text>
# ga-k2wjn, tightened by ga-zhfk8 (measured 2026-08-04, wa-zlgye false
# positive): does <bead_text> (a bead's description + notes, CONCATENATED)
# look like it enumerates multiple approved deliverables, such that "the gate
# approved this diff" is not the same claim as "this bead's full scope is
# done"? Confirmed empirically against the 3 real false-closes ga-k2wjn cites
# (wa-uhbqb: lettered list a.-i.; wa-a7e98: numbered list 1.-4.; wa-k0m1q:
# numbered list 1.-11., list lives ENTIRELY in bd's notes field — description
# is empty, so the caller must pass description+notes concatenated, never
# description alone) — and against wa-zlgye (ga-zhfk8's measured false
# positive: prose using "a)"/"d)"/"e)" and the bare word "fatia"/"fatias",
# zero real list items), which must NOT trigger.
#
# v1 (ga-k2wjn) also fired on an isolated "fatia"/"fatias"/"itens aprovados"
# TOKEN anywhere in the text, no list structure required at all — common
# words in this city's technical Portuguese, and the actual root cause of the
# wa-zlgye false positive. v2 (ga-zhfk8) drops that standalone-token trigger
# entirely and requires genuine list STRUCTURE: >=3 lines each starting with
# "N. " (1-2 digit number) or "x. " (single lowercase letter), tolerating
# indented wrapped-continuation lines between them but not flush-left prose
# or blank-line paragraph breaks (see _gate_delivery_list_run — tightened
# again in ga-zhfk8 fix attempt 2 after gate review found the first attempt's
# strict no-gap requirement false-negatived on multi-line list items). On a
# match it prints the detected item lines to stdout (see
# _gate_delivery_list_run) for the caller to quote in the hold message.
#
# False positives on genuine list structure are still the accepted/cheap
# failure mode (costs one human review — ga-k2wjn's own stated tradeoff);
# false negatives silently drop approved work, which is the bug this exists
# to stop. Returns 0 (true, evidence on stdout) iff it looks partial; 1
# (false, nothing on stdout) otherwise.
#
# v3 (ga-1yxyt, measured 2026-08-05, ga-o5de8 false positive): v2 found list
# STRUCTURE correctly but not what the list was FOR — ga-o5de8's "O CICLO:"
# section numbers the 3 steps of the DEADLOCK being reported, not 3 approved
# deliverables, and got held anyway. v3 has _gate_delivery_list_run classify
# the header immediately preceding a run (see _gate_delivery_header_class)
# and skip runs headed by a DIAGNOSTIC/OBSERVATION label (O CICLO, A CADEIA,
# SINTOMA, A MEDICAO, O DEFEITO, EVIDENCIA, COMO ACONTECE). A SCOPE/WORK
# header (FIX PEDIDO, ENTREGAVEIS, ESCOPO, CRITERIO DE ACEITE, O QUE FAZER)
# or no recognizable header at all still counts — fail-safe unchanged from
# v1/v2: retaining too much costs a human review, retaining too little
# silently drops scope, so an unclassifiable header must keep retaining.
#
# v4 (ga-cjrxh, measured 2026-08-05: 4 holds in one session, 3 false = 75%).
# v3 could find a list and tell scope from diagnosis, but could not tell a
# list of DELIVERABLES from a list of ACCEPTANCE CRITERIA — and in this city's
# bug-report convention those look identical, so the better the report, the
# likelier the wrongful hold. v4 fixes both directions at once, because
# fixing only the first would have RELEASED wa-se0zu (the one true positive,
# which v3 held for an unrelated reason):
#   · stop counting verification items (header class + per-item rule);
#   · start catching the multi-scope signals that escaped — UPPERCASE lettered
#     lists and an enumeration in the TITLE.
# Bias, stated explicitly: ga-cjrxh directs that holding good work is the
# EXPENSIVE, SILENT error (a held bead does not shout, it stops, and the cost
# lands on the Mayor as manual triage), while releasing with a warning is
# cheap. Where this heuristic must guess, it now prefers to release and say
# so. Optional 2nd arg is the bead TITLE.
gate_delivery_looks_partial() {
  local text="${1:-}" title="${2:-}" hit=""
  _GDLR_ADVISORY=""; _GDLR_ADVISORY_EVIDENCE=""   # globals, set by the run scanner
  # AC3 (root-class error-vs-empty): "the body was empty so I could not
  # evaluate" and "I evaluated and found no multiple scope" are different
  # facts that used to share one silent rc=1. Name which one happened.
  if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ] && [ -z "$title" ]; then
    echo "escopo-multiplo:nao-avaliavel (corpo do bead vazio ou so espaco — o guard nao teve o que ler)" >&2
    return 1
  fi
  _gate_delivery_list_run "$text" '^[[:space:]]*[0-9]{1,2}\.[[:space:]]' 'lista numerada' && return 0
  # ga-cjrxh: [A-Za-z], not [a-z]. wa-se0zu enumerates its 8 real deliverables
  # as "A." .. "H." — that run escaped the guard entirely, and the bead was
  # held only by accident, on an unrelated numbered verification list. Fixing
  # the false positives without this would have released a true positive.
  _gate_delivery_list_run "$text" '^[[:space:]]*[A-Za-z]\.[[:space:]]' 'lista com letras' && return 0
  if hit=$(_gate_delivery_enumerates "$title"); then
    printf 'detectei (titulo enumera escopo): "%s" — o titulo declara %s\n' "$title" "$hit"
    return 0
  fi
  # ga-cjrxh "errar liberando + REPORTANDO": a run cleared the >=3 deliverable
  # bar but sits under a header this guard cannot classify. Releasing it
  # silently would throw the signal away; holding it is the expensive silent
  # error that this bead exists to stop. Release, and say exactly what was
  # seen and why it was let through.
  if [ -n "${_GDLR_ADVISORY:-}" ]; then
    printf 'escopo-multiplo:possivel — %s. LIBERADO (ga-cjrxh: segurar trabalho bom e o erro caro e silencioso, liberar custa uma conferida); confira se o diff cobre todo o escopo.\n' \
      "$_GDLR_ADVISORY" >&2
    return 1
  fi
  echo "escopo-multiplo:nao-detectado (avaliei corpo e titulo; nenhuma lista de >=3 entregaveis, nem enumeracao no titulo ou no cabecalho)" >&2
  return 1
}

# branch_bead_commit_verdict <unique_commit_count> <messages_blob> <bead_id>
#   Mirrors quality-gate-dispatcher.sh's function of the SAME name — same
#   contract, same anchored-match logic, deliberately kept in this strict,
#   3-arg-only form FOREVER (ga-pj5va). fix-attempt-1 tried adding a 4th
#   own_text parameter to the dispatcher's copy so a sliced sub-bead citing
#   only its PARENT (this city's "item N of X" convention) would still pass
#   — gate review FAILED it: bare co-mention in prose is not proof of a
#   declared relationship, and it reopens the exact ga-y9a1d incident class
#   (content merged under the wrong bead's identity) this check exists to
#   catch. The corrected fix moves parent/child accommodation to the WRITER
#   side (the commit-message convention documented in gate-done.md) instead
#   of loosening either reader-side copy of this function. Do not add
#   own_text/prose heuristics here, or to the dispatcher's copy — ever.
#   Pure (no IO).
#     skip — count is 0/empty/unparseable, or bead is empty.
#     yes  — bead_id appears anchored somewhere in messages_blob.
#     no   — count > 0 but bead_id appears nowhere.
#
#   ga-pj5va: defined HERE, above the GATE_GUARD_LIB_ONLY cutoff just below —
#   NOT down at its call site (Step 5b-pre, near BEAD_CITY resolution). This
#   is the exact defect class ga-zdkn1 already found and fixed once in this
#   same section (see that comment a few screens up, on gc_json_or_unknown):
#   a pure function defined past this cutoff is invisible to lib-only test
#   sourcing, which returns right here and never reaches it.
branch_bead_commit_verdict() {
  local count="$1" messages="$2" bead="$3"
  case "$count" in ''|*[!0-9]*|0) printf 'skip'; return 0 ;; esac
  [ -z "$bead" ] && { printf 'skip'; return 0; }
  local _anchored='(^|[^A-Za-z0-9])'"$bead"'([^A-Za-z0-9]|$)'
  if [[ "$messages" =~ $_anchored ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# gate_ab_arm_for_bead <bead_id>
#   ga-rstae: deterministic A/B arm assignment for the base-commit test check
#   below (Step 5b-pre2). Pure bash polynomial hash (base-31, same recurrence
#   as Java's String.hashCode) over the bead id's characters — zero external
#   process/tool dependency (no shasum/sha1sum/md5 subprocess), so it can
#   never vary because a hashing tool is missing or differs across hosts.
#   MUST be a pure function of bead_id alone — no timestamp, no counter, no
#   $RANDOM — or a bead that fails and re-submits under the SAME id could
#   land in a DIFFERENT arm on retry and contaminate both arms' measurement
#   (this is the one mistake the whole experiment design cannot tolerate;
#   see the bead body's own emphasis on this). Same bead_id -> same arm,
#   forever, on any host. Verified over 200 random ga-xxxxx-shaped ids: 99/101
#   A/B split — not a coincidentally-lopsided hash.
#     A — control. Braco A must stay byte-for-byte today's behavior: this
#         function is called (cheap, no IO) so the caller can log which arm
#         a submission landed in, but arm A must never reach the actual
#         worktree/checkout/run machinery below — "A com um aviso" is not
#         A (bead's own words).
#     B — treatment. May be REFUSED at submission by the base-commit check.
#   Empty/missing bead_id defaults to 'A' (the arm that can never block) —
#   fail-open on unresolved input, same posture as branch_bead_commit_verdict
#   above returning 'skip' rather than guessing.
#   Pure (no IO, no subprocess).
gate_ab_arm_for_bead() {
  local bead="$1"
  [ -z "$bead" ] && { printf 'A'; return 0; }
  local i c ord sum=0 len=${#bead}
  for (( i = 0; i < len; i++ )); do
    c="${bead:$i:1}"
    printf -v ord '%d' "'$c"
    sum=$(( (sum * 31 + ord) % 100000007 ))
  done
  if (( sum % 2 == 0 )); then
    printf 'A'
  else
    printf 'B'
  fi
}

# gate_base_test_verdict <detected> <copy_ok> <ran> <failed>
#   ga-rstae: collapses the base-commit test check's raw counts (computed by
#   the impure Step 5b-pre2 block below: how many *.selftest.sh files were
#   added/changed on the branch, how many of those were successfully
#   materialized onto a throwaway base-commit worktree, how many actually
#   completed execution within their timeout budget, and how many of THOSE
#   exited non-zero) into exactly ONE of four named states. All four are
#   REQUIRED reporting buckets per the bead — "sem-teste-novo" and
#   "nao-consegui-medir" are not swallowed into a generic pass, they are
#   counted separately so the A/B apuracao measures "who wrote a test that
#   proves something", not "who wrote any test" or "who got measured".
#     sem-teste-novo      — detected=0, and detected was a CONFIRMED, cleanly
#                            parsed zero (the call site actually counted the
#                            diff and got nothing). Never blocks; this
#                            submission does not participate in the "does the
#                            test prove anything" question at all.
#     nao-consegui-medir  — either detected itself is empty/unparseable (we
#                            don't even know how many test files there are —
#                            NOT the same claim as "confirmed zero", so it
#                            must not collapse into sem-teste-novo: that
#                            exact collapse — empty read treated the same as
#                            a confirmed value — is family #2 in the gate's
#                            own failure taxonomy, "3o-estado colapsado", 30%
#                            of blocking issues, and this function existing
#                            to fight that family while committing it itself
#                            would be the worst possible outcome here) OR
#                            detected>0 but copy_ok!=detected or ran!=detected
#                            (worktree creation failed, git-show extraction
#                            failed for at least one file, or a file was
#                            killed by its timeout — see the call site's 124
#                            handling). Never blocks.
#     passou-na-base       — detected>0 (confirmed), every file measured, ALL
#                            exit 0 against the pre-fix base. The test
#                            doesn't distinguish base from fix -> proves
#                            nothing. BLOCKS (arm B only).
#     reprovou-na-base     — detected>0 (confirmed), every file measured, AT
#                            LEAST ONE exits non-zero against base ->
#                            something in the new/changed test genuinely
#                            depends on the fix. Never blocks — the GOOD case.
#   "measured" above means copy_ok==detected AND ran==detected: a PARTIAL
#   measurement (some files ok, some not) is treated the same as a total
#   failure to measure, never as partial proof — fail-open on ANY
#   uncertainty, matching Step 5b-pre's own stated posture, because a false
#   REFUSE here costs a live builder real time on a false alarm.
#   Pure (no IO) — the impure call site does all git/worktree/bash work and
#   passes in only these four counts.
gate_base_test_verdict() {
  local detected="$1" copy_ok="$2" ran="$3" failed="$4"
  case "$detected" in
    ''|*[!0-9]*) printf 'nao-consegui-medir'; return 0 ;;
  esac
  if [ "$detected" -eq 0 ]; then
    printf 'sem-teste-novo'
    return 0
  fi
  case "$copy_ok" in ''|*[!0-9]*) copy_ok=0 ;; esac
  case "$ran" in ''|*[!0-9]*) ran=0 ;; esac
  case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
  if [ "$copy_ok" -ne "$detected" ] || [ "$ran" -ne "$detected" ]; then
    printf 'nao-consegui-medir'
    return 0
  fi
  if [ "$failed" -gt 0 ]; then
    printf 'reprovou-na-base'
  else
    printf 'passou-na-base'
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
  local known_rigs known_rigs_json
  # ga-07rb3: known_rigs empty ALREADY gets an explicit, deliberate fallback
  # below (warn + regex-based injection check) regardless of WHY it's empty —
  # this just makes "gc genuinely failed" distinguishable from "gc succeeded,
  # zero rigs registered" in that warning, rather than relying on a bare
  # `|| echo ""` that would also silently swallow a malformed-but-exit-0 envelope.
  known_rigs_json=$(gc_json_or_unknown gc --city "$GC_CITY" rig list --json) || true
  known_rigs=$(printf '%s' "$known_rigs_json" | jq -r '.rigs[].name' 2>/dev/null)
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
#
# ga-f1ngu: includes gate-status:claimed alongside :running — a claim receipt
# (Step 6 below) is a real, live companion of its marker even though it is not
# itself a review run. Narrowing this to :running only would (a) make Vector
# A's has_live_companion_run go false the instant a marker is merely claimed
# but not yet dispatched, re-exposing it to false reclaim/error, and (b) leave
# claim receipts with no companion query to ever dedup/close them once a real
# gate-run bead supersedes them — they'd accumulate as permanently-open beads
# forever (nothing else queries gate-status:claimed gate-runs). --label-any is
# OR (verified empirically: passed OR failed counts summed to the union count).
# ga-qj1xh: capture bd's exit status WITHOUT masking it — the old
# `2>/dev/null || echo "[]"` collapsed a FAILED query (Dolt timeout/contention)
# into "zero gate-runs running", indistinguishable from a genuinely empty
# result. That false-empty then propagates two ways: Vector B's dedup loop
# below is gated on GATE_RUN_COUNT>0, so on failure it happens to skip rather
# than supersede — but silently, with no signal this sweep couldn't actually
# see the sibling state. RUNNING_GATERUN_MARKER_IDS (built from this same JSON
# just below) is the dangerous one: on failure it defaults to empty, so every
# has_live_companion_run lookup in Vector A reads false even when a real
# companion run is alive — exactly the false-reclaim/error ga-cgynn's
# companion-liveness check exists to prevent, sourced from the very query
# meant to feed it. GATE_RUNS_QUERY_OK propagates the distinction downstream;
# see companion_liveness_from_query above. The `if` keeps `set -euo pipefail`
# from aborting on a nonzero bd exit (same idiom as reviewers_alive_for_run /
# verdict_bead_count_for_run below, ga-48xcv).

# --include-infra (ga-vm20x, Mayor 07/08): gate-run beads are born
# --ephemeral (INFRA), hidden from `bd list` by default under bd 1.1.0.
# This shared-prelude query feeds BOTH Vector B dedup and Vector A
# companion-liveness (see the block above) — without the flag it
# undercounts the same way a query FAILURE does, except silently, with
# GATE_RUNS_QUERY_OK=1 masking that anything was missed.
if GATE_RUNS_JSON=$(bd -C "$GC_CITY" list --json --all --include-infra \
    -l type:quality-gate-run \
    --label-any gate-status:running \
    --label-any gate-status:claimed \
    2>/dev/null); then
  GATE_RUNS_QUERY_OK=1
else
  GATE_RUNS_QUERY_OK=0
  GATE_RUNS_JSON="[]"
  warn "Shared prelude: gate-runs query failed — cannot determine running/claimed siblings this sweep. Vector B dedup and Vector A companion-liveness both fail-safe (skip) rather than guess (root-class:error-vs-empty, ga-qj1xh)."
fi
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

# --include-infra (ga-vm20x, Mayor 07/08): gate markers are born --ephemeral
# (INFRA), hidden from `bd list` by default under bd 1.1.0. Without this
# flag, an ephemeral marker stuck in dispatching/claimed is invisible to
# THIS reclaim step — the one mechanism ga-tmug Vector A relies on to
# unstick it — so it strands forever exactly the way the comment above
# describes for a crashed dispatcher, just via a different root cause.
DISP_JSON=$(bd -C "$GC_CITY" list --json --all --include-infra \
  -l type:quality-gate-marker -l gate-status:dispatching \
  2>/dev/null || echo "[]")
CLAIM_JSON_V=$(bd -C "$GC_CITY" list --json --all --include-infra \
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

    _T_MARKER_FOUND=0
    if [ -n "$RUNNING_GATERUN_MARKER_IDS" ] \
      && printf '%s\n' "$RUNNING_GATERUN_MARKER_IDS" | grep -qx "$T_ID"; then
      _T_MARKER_FOUND=1
    fi
    # ga-qj1xh: route through companion_liveness_from_query so a failed shared
    # gate-runs query (GATE_RUNS_QUERY_OK=0 above) fails safe as "assume live"
    # instead of silently reading as "confirmed no companion" — see that
    # function's header for why the naive default was destructive under Dolt
    # load.
    HAS_LIVE_COMPANION=$(companion_liveness_from_query "$GATE_RUNS_QUERY_OK" "$_T_MARKER_FOUND")

    ACTION=$(reconcile_marker_action "$T_STATUS" "$T_AGE" "$CLAIM_TTL_MINUTES" "$T_COUNT" "$MAX_RECLAIMS" "$HAS_LIVE_COMPANION")
    case "$ACTION" in
      requeue:queued)
        warn "Vector A: requeueing zombie dispatching marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        # ga-qblq4: add queued BEFORE removing dispatching/claimed — same
        # invariant as set_gate_status/ga-i0n83 — so the marker is never left
        # with ZERO gate-status:* labels (misread as FANTASMA by
        # gate-queue-composition.sh) mid-reclaim.
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:queued"      -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:dispatching" -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed"     -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:dispatching for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Dispatcher likely crashed. Re-queued for re-processing (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      requeue:ready)
        warn "Vector A: re-readying zombie claimed marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        # ga-qblq4: add ready BEFORE removing claimed/dispatching — same
        # invariant as the requeue:queued branch above.
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:ready"       -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed"     -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:dispatching" -q 2>/dev/null || true
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
        if [ "$GATE_RUNS_QUERY_OK" != "1" ]; then
          log "  Marker $T_ID in $T_STATUS — shared gate-runs query failed this sweep, cannot verify companion liveness; fail-safe skip (ga-qj1xh)."
        elif [ "$HAS_LIVE_COMPANION" = "1" ]; then
          log "  Marker $T_ID in $T_STATUS has a live companion gate-run — legitimate yield-bounce, not stuck (ga-cgynn). Skipping."
        else
          log "  Marker $T_ID in $T_STATUS for ${T_AGE}m — within TTL, skipping."
        fi
        ;;
    esac
  done
fi

# ── Step 0b: Vector B — reconcile orphan gate-run beads ───────────────────────
# The guard creates a quality-gate: claim-receipt bead (type:quality-gate-run,
# gate-status:claimed — NOT :running as of ga-f1ngu, see Step 6's header) at
# claim time. The dispatcher drives ITS OWN gate-run: bead (gate-status:running)
# but never drives the guard's claim-receipt to terminal — leaving orphans
# pinned open after their real run completed (ga-tmug Vector B, 9 such beads
# observed originally in gate-status:running; the SAME orphaning happens today
# in gate-status:claimed, just no longer masquerading as a live review).
#
# Fix: use reconcile_gaterun_action keyed on the companion marker's state
# (extracted via parse_marker_id from the gate-run description):
#   - marker terminal/gone → supersede:marker (immediate, no TTL wait)
#   - marker active + age > TTL → abort:age (age fallback preserved)
#   - marker active + within TTL → skip (in-flight, untouched)
#
# Keying on marker_id (not just source-bead) prevents false-positives on
# re-dispatched live runs that share a source bead with an older failed attempt.
#
# This vector, plus the dedup pass below, is what ultimately closes out every
# claim receipt — either via keep-newest dedup the sweep after a real gate-run
# bead appears for the same marker_id, or (if dispatch never happens) via the
# zero-verdict grace-window check once the marker itself goes stale. Nothing
# else queries gate-status:claimed gate-run beads, so this loop is their only
# path to ever closing (ga-f1ngu) — see the shared-prelude query above.

log "Step 0b: Vector B reconcile — orphan gate-run beads, running+claimed (TTL=${GATE_RUN_TTL_MINUTES}m, zombie-age=${GATE_ZOMBIE_AGE_MINUTES}m=verdict-timeout+margin)..."

# reviewers_alive_for_run <gate_run_id> — I/O helper (ga-o57gn).
# Echo 1 iff at least one of this gate-run's still-OPEN verdict beads is assigned
# to a reviewer session that is present (alive) in SESS_SNAP_JSON, else 0. A
# gate-run still running past verdict-timeout with zero live reviewers is a
# zombie whose dispatcher died. (Live section only — uses bd/gc; never called in
# lib-only mode, so it is intentionally NOT one of the drift-guarded pure fns.)
reviewers_alive_for_run() {
  local gr_id="$1" vbs assignees a present
  [ -z "$gr_id" ] && { echo 0; return; }
  # ga-48xcv: routed through the read-cache shim — verdict_bead_count_for_run
  # below issues this identical query for the same gr_id earlier in the same
  # loop iteration; the shim collapses the pair into one live Dolt round-trip.
  vbs=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json --all \
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

# close_dead_reviewer_verdicts <gate_run_id> — I/O helper (ga-g4m18).
# Cascades Vector B's dead-reviewer supersede onto sibling verdict beads.
# reviewers_alive_for_run already confirmed (immediately above, same loop
# iteration) that every OPEN verdict bead for this gate-run is assigned to a
# dead session before the caller ever reaches supersede:dead-reviewers — this
# closes those verdict beads themselves once $gr_id's gate-run is superseded,
# instead of leaving them orphaned open+in_progress forever (ga-g4m18: the
# gap reviewers_alive_for_run's own liveness check never closed, observed
# live as ga-ydf9v/ga-z8erc, hand-closed by the Mayor as a one-off).
#
# ga-48xcv: reuses reviewers_alive_for_run's exact query shape (same labels,
# same gr_id) — the read-cache shim (default TTL 5s) collapses the pair into
# one live Dolt round-trip since this always runs in the same loop iteration,
# right after reviewers_alive_for_run's own call for the same $gr_id.
#
# (Live section only — uses bd/gc; never called in lib-only mode. The pure
# projection it depends on, open_verdict_ids_from_json, lives above the
# GATE_GUARD_LIB_ONLY cutoff and IS selftest-exercised directly.)
close_dead_reviewer_verdicts() {
  local gr_id="$1" vbs ids v_id
  [ -z "$gr_id" ] && return
  vbs=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json --all \
    -l type:quality-gate-verdict -l "gate-run:$gr_id" 2>/dev/null || echo "[]")
  ids=$(open_verdict_ids_from_json "$vbs")
  [ -z "$ids" ] && return
  for v_id in $ids; do
    [ -z "$v_id" ] && continue
    bd -C "$GC_CITY" comment "$v_id" "Vector B (ga-g4m18): cascade-closed — parent gate-run $gr_id was superseded (dead reviewer, no live session assigned to this verdict). Self-healed by guard." 2>/dev/null || true
    bd -C "$GC_CITY" close "$v_id" -r "quality-gate-verdict orphaned (terminal) — parent gate-run $gr_id superseded, dead reviewer. Closed by guard (ga-g4m18)." 2>/dev/null || true
  done
}

# close_pending_verdicts_for_run <gate_run_id> <reason_text> — I/O helper (ga-hgsqg).
# Generic sibling of close_dead_reviewer_verdicts above (ga-g4m18, wired only
# into supersede:dead-reviewers) and _close_pending_verdicts_for_run in
# gate-recovery-watchdog.py (ga-9as9h, that file's FIX 1/FIX 3) — same fix,
# same shape, THIS file's remaining gap. Between them, ga-g4m18 and ga-9as9h
# cover every OTHER place a gate-run bead gets superseded; supersede:marker,
# abort:age and supersede:duplicate below never got the same cascade, so a
# run closed via any of those three left its own pending verdict bead(s)
# open forever — invisible to every consumer (Phase C only ever queries
# gate-status:running, never --all) and unreachable by either sweep meant to
# mop up stragglers: Step 0b.1 requires a non-empty, CONFIRMED-DEAD assignee
# (reconcile_dead_reviewer_verdict_action's own rule 1: reviewer_alive=1 →
# skip, regardless of parent state), Step 0b.2 requires the parent to be
# CONFIRMED GONE via bd show (reconcile_orphaned_verdict_action: parent
# "found" — even closed-but-still-resolvable — → skip, not orphaned). A run
# closed by supersede:marker/abort:age/supersede:duplicate is neither: its
# assignee may be empty AND alive, and its parent is "found", just closed.
# MEASURED LIVE (ga-hgsqg, 2026-08-10): ga-yv9z9 (parent ga-4z58o) and
# ga-ht83i (parent ga-gpiwx) — both empty-assignee, both stuck exactly this
# way, though produced by gate-recovery-watchdog.py's FIX3 before ga-9as9h
# closed that specific file's version of the same gap; used here as the
# fixture shapes for this fix's own selftest.
#
# Deliberately UNCONDITIONAL on the verdict's own assignee/reviewer-liveness
# — unlike reconcile_dead_reviewer_verdict_action's grace/liveness gate, this
# helper only ever runs AFTER the caller already independently decided the
# RUN itself is terminal (it is called from inside the supersede:*/abort:age
# branches only, never from skip — see this file's own selftest for the
# structural proof). Once a run is terminal, nothing downstream ever reads
# its verdicts again regardless of whether a reviewer is still alive and
# about to write a real PASS/FAIL — closing early discards nothing a live
# reviewer's own eventual close wouldn't have been discarded anyway
# (idempotent either way: `bd close` on an already-closed bead is a no-op).
#
# Reason text is caller-supplied so each of the 3 call sites' bd comment
# accurately reflects ITS OWN close reason (marker terminal/gone vs TTL abort
# vs stale duplicate) instead of borrowing close_dead_reviewer_verdicts' own
# dead-reviewer-specific wording, which would be an unverified — and for
# supersede:marker/abort:age, often simply FALSE — claim: both fire with NO
# reviewer-liveness check at all (reconcile_gaterun_action's priority order,
# rules 1 and 3 above).
#
# ga-h199q precedent: queries `bd` directly, NOT through bd-list-cached.sh —
# that shim's child-process `bash <path>` invocation can't see an in-shell
# `bd` mock (confirmed the hard way: gate-verdict-drained-reviewer-rescue.
# selftest.sh hit exactly this for a different function, 6 assertion
# failures, documented at that function's own call site in
# quality-gate-dispatcher.sh). This call fires at most once per gate-run's
# entire lifetime — at its own close — not once per sweep like the polling
# reads the shim exists to de-duplicate, so there's no real efficiency cost
# to staying directly testable.
#
# (Live section only — uses bd; never called in lib-only mode. The pure
# projection it depends on, open_verdict_ids_from_json, lives above the
# GATE_GUARD_LIB_ONLY cutoff and IS selftest-exercised directly.)
# SELFTEST-EXTRACT close-pending-verdicts-for-run-fn: BEGIN
close_pending_verdicts_for_run() {
  local gr_id="$1" reason="$2" vbs ids v_id
  [ -z "$gr_id" ] && return
  vbs=$(bd -C "$GC_CITY" list --json --all --limit 0 \
    -l type:quality-gate-verdict -l "gate-run:$gr_id" 2>/dev/null || echo "[]")
  ids=$(open_verdict_ids_from_json "$vbs")
  [ -z "$ids" ] && return
  for v_id in $ids; do
    [ -z "$v_id" ] && continue
    bd -C "$GC_CITY" comment "$v_id" "Vector B (ga-hgsqg): cascade-closed — parent gate-run $gr_id closed ($reason). Self-healed by guard." 2>/dev/null || true
    bd -C "$GC_CITY" close "$v_id" -r "quality-gate-verdict orphaned (terminal) — parent gate-run $gr_id closed ($reason). Closed by guard (ga-hgsqg)." 2>/dev/null || true
  done
}
# SELFTEST-EXTRACT close-pending-verdicts-for-run-fn: END

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
  # ga-48xcv: routed through the read-cache shim (see reviewers_alive_for_run).
  if vbs=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json --all \
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
      # ga-hgsqg: cascade-close this run's own OPEN verdict beads too — a
      # stale duplicate can have live reviewers already dispatched on it;
      # once the newer sibling run wins, this run's verdicts can never be
      # consumed by anything (see close_pending_verdicts_for_run's docstring).
      close_pending_verdicts_for_run "$GR_ID" "stale duplicate — a newer running gate-run supersedes it, ga-o57gn dedup"
      continue
    fi

    # Determine if the companion marker is still active.
    # parse_marker_id extracts the marker_id: field written by the guard at Step 6.
    COMPANION_MARKER_ID=$(parse_marker_id "$GR_DESC")
    MARKER_ACTIVE=0
    MARKER_AGE="$GR_AGE"   # fallback only — overwritten below whenever the marker itself is readable
    if [ -n "$COMPANION_MARKER_ID" ]; then
      # ga-48xcv: routed through the read-cache shim — a status/liveness lookup
      # whose worst-case staleness (default 5s TTL) is a briefly-delayed reap
      # of an orphan gate-run tracking bead on the next ~2min sweep, not a
      # correctness issue (the shim never caches writes; see its header note
      # on call sites that gate close/requeue decisions).
      MARKER_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" show "$COMPANION_MARKER_ID" --json 2>/dev/null || echo "")
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
    # ga-i0n83: routed through marker_status_from_labels (defined above,
    # alongside reconcile_zero_verdict_run_action) instead of a raw `head -1`
    # — see that function's docstring for why an ambiguous (0 or 2+) label set
    # must never be guessed at.
    MARKER_STATUS=$(marker_status_from_labels "$MARKER_LABELS")
    if [ "$MARKER_ACTIVE" = "1" ]; then
      ZV_TOTAL=$(verdict_bead_count_for_run "$GR_ID")
      case "$ZV_TOTAL" in ''|*[!0-9]*) ZV_TOTAL=1 ;; esac  # unreadable → fail-safe, defer to the existing path below
      if [ "$ZV_TOTAL" = "0" ]; then
        ZV_ACTION=$(reconcile_zero_verdict_run_action "$MARKER_AGE" "$GATE_ZERO_VERDICT_GRACE_MINUTES" "$MARKER_STATUS")
        case "$ZV_ACTION" in
          supersede:still-queued)
            # ga-4t5xe: reassurance FIRST, entities named explicitly (marker vs.
            # tracking bead) — three independent readers on 2026-08-01 conflated
            # "closing $GR_ID" with "the marker died" because the old ordering led
            # with alarm words ("closing orphan", "0 verdict beads") and buried the
            # healthy verdict at the end of a long line.
            log "  Vector B (ga-jfo7): healthy backlog/Dolt-hot defer, nothing stuck — marker $COMPANION_MARKER_ID stays queued and will be reviewed normally; closing $GR_ID (its claim-time tracking bead only — 0 verdict beads, no reviewer was ever attached; marker age=${MARKER_AGE}m)."
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
        # ga-hgsqg: cascade-close this run's own OPEN verdict beads too — the
        # companion marker died/finished elsewhere with NO reviewer-liveness
        # check here, so a live reviewer can genuinely still be mid-review;
        # its verdict can never be consumed by anything once this run is
        # superseded regardless (see close_pending_verdicts_for_run's
        # docstring for why that's still safe to close, not destructive).
        close_pending_verdicts_for_run "$GR_ID" "companion marker $COMPANION_MARKER_ID is terminal/gone, ga-tmug"
        ;;
      supersede:dead-reviewers)
        warn "Vector B: superseding ZOMBIE gate-run $GR_ID (age=${GR_AGE}m > zombie-age=${GATE_ZOMBIE_AGE_MINUTES}m [verdict-timeout ${GATE_VERDICT_TIMEOUT_MINUTES}m + margin ${GATE_DEAD_REVIEWER_MARGIN_MINUTES}m], no live reviewer — dispatcher abandoned it; ga-o57gn)"
        set_gate_status "$GR_ID" "superseded"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-o57gn): zombie gate-run superseded — age ${GR_AGE}m exceeds verdict-timeout+margin (${GATE_ZOMBIE_AGE_MINUTES}m) AND no live reviewer is assigned to an open verdict bead. The owning dispatcher died/was killed mid-run. Self-healed by guard." 2>/dev/null || true
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — zombie: age>verdict-timeout, no live reviewer. Closed by guard (ga-o57gn)." 2>/dev/null || true
        # ga-g4m18: cascade-close this run's own OPEN verdict beads — Vector B
        # closed the gate-run above but previously left its sibling verdict
        # beads (the ones reviewers_alive_for_run just confirmed are all
        # assigned to dead sessions) orphaned open forever.
        close_dead_reviewer_verdicts "$GR_ID"
        ;;
      abort:age)
        warn "Vector B: aborting gate-run $GR_ID by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m, marker_active=${MARKER_ACTIVE})"
        set_gate_status "$GR_ID" "aborted"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): gate-run aborted by guard TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m; marker $COMPANION_MARKER_ID still active but run exceeded max wait)." 2>/dev/null || true
        # ga-jhyu: CLOSE at terminal so wisp-compact reaps it.
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run aborted (terminal) by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m). Closed by guard (ga-jhyu)." 2>/dev/null || true
        # ga-hgsqg: cascade-close this run's own OPEN verdict beads too — the
        # TTL fallback fires with NO reviewer-liveness check (reconcile_
        # gaterun_action's rule 3), so a live reviewer can genuinely still be
        # mid-review; its verdict can never be consumed once this run is
        # aborted regardless (see close_pending_verdicts_for_run's docstring).
        close_pending_verdicts_for_run "$GR_ID" "aborted by guard TTL fallback, age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m, ga-tmug"
        ;;
      skip)
        log "  Gate-run $GR_ID active (age=${GR_AGE}m, marker_active=${MARKER_ACTIVE}, reviewers_alive=${REVIEWERS_ALIVE}) — skipping."
        ;;
    esac
  done
fi

# ── Step 0b.1 (ga-u07fn): dead-reviewer VERDICT reap ─────────────────────────
# Sibling of Vector B above, at verdict granularity instead of run granularity.
# Vector B's only actions are {skip, supersede-the-WHOLE-run, abort-by-TTL} —
# it cannot free ONE stuck verdict while leaving a still-legitimate run (or a
# run with other live reviewers) alone. This step queries every still-pending
# type:quality-gate-verdict bead, and for any whose specific assignee session
# is confirmed dead AND has had at least GATE_DEAD_VERDICT_GRACE_MINUTES to
# boot, either releases it (parent run still active — re-convocation
# candidate) or closes it (parent run terminal — leftover state). See
# reconcile_dead_reviewer_verdict_action's docstring above for the full
# decision table and the live worked examples it mirrors (ga-jeicm, Mayor,
# 2026-08-07T23:29:11Z).
#
# Scope: NON-EMPTY assignee only (ga-u07fn investigation). A live sweep of
# today's actual verdict:pending population found 45 of 46 open verdicts with
# assignee=="" and gate-run labels referencing ga-wisp-* ids that don't
# resolve via `bd show` (ages up to ~40 days) — these do NOT match the bead's
# own framing ("assignee sessão gate-reviewer-* sem sessão viva") or any of
# Mayor's three worked examples, all of which had a real gate-reviewer-*
# assignee. That population looks like a different, older, unexplained issue
# (dangling reference to an already-reaped parent wisp, most likely) and is
# OUT OF SCOPE here — touching beads whose root cause I haven't verified would
# be exactly the "guess instead of measure" failure mode this codebase's own
# doctrine warns against. Filed as a separate follow-up: ga-u07fn's own
# tracking comment cross-references the new bead. Do not fold that population
# into this reap without its own investigation.
#
# Deliberately placed AFTER Vector B's own loop (not interleaved) so that any
# gate-run Vector B just superseded in THIS sweep already reads as terminal
# when this step looks it up — collapsing what would otherwise be a one-cycle
# race (release now, close next sweep) into a same-sweep correct close.
#
# verdict beads are NOT ephemeral (dispatcher creates them deliberately non-
# ephemeral, ga-vephl — see the create call's own comment) so this query needs
# no --include-infra. Must NOT add --status open: verified live that a
# claimed-but-not-yet-formally-in_progress verdict sits at status=="open" as
# its normal resting state (assign_verdict_bead_verified sets in_progress only
# on the ga-cvhoj re-convene path) — `--status open` would silently exclude
# genuine in_progress verdicts, the exact shape this step exists to catch.
# --limit 0 matters (ga-21kmp): today's live count (46) is already close to
# the 50-row default truncation.
log "Step 0b.1 (ga-u07fn): dead-reviewer verdict reap — grace=${GATE_DEAD_VERDICT_GRACE_MINUTES}m..."

# ga-u07fn self-audit fix: capture query success/failure explicitly, same
# idiom as the GATE_RUNS_JSON fetch above (ga-qj1xh) — a FAILED query
# (Dolt timeout/contention) must never silently read the same as a
# CONFIRMED-empty result. The consequence here is benign either way (this
# step just takes no action, which is the safe/inert default) but SILENT
# fail-open is still wrong per the third-state rule: it must be visible,
# not indistinguishable from "genuinely nothing to do this sweep".
if DEAD_VERDICT_JSON=$(bd -C "$GC_CITY" list --json --limit 0 \
    -l type:quality-gate-verdict -l verdict:pending \
    2>/dev/null); then
  DEAD_VERDICT_COUNT=$(printf '%s\n' "$DEAD_VERDICT_JSON" | jq 'length' 2>/dev/null || echo "0")
  case "$DEAD_VERDICT_COUNT" in
    ''|*[!0-9]*)
      warn "ga-u07fn: verdict-reap query returned unparseable output — skipping this sweep rather than guessing a count."
      DEAD_VERDICT_COUNT=0
      ;;
  esac
else
  warn "ga-u07fn: verdict-reap query FAILED (Dolt timeout/contention?) — skipping this sweep; next sweep in ~2min will retry. Not a confirmed-empty result."
  DEAD_VERDICT_JSON="[]"
  DEAD_VERDICT_COUNT=0
fi

if [ "$DEAD_VERDICT_COUNT" -gt 0 ]; then
  # NOW_EPOCH/SESS_SNAP_JSON may already be set by the Vector B block above —
  # but that block only runs when GATE_RUN_COUNT>0, so this step cannot rely
  # on either being set and must fall back to fetching its own.
  NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"
  if [ -z "${SESS_SNAP_JSON:-}" ]; then
    SESS_SNAP_JSON=$(bash "$GC_CITY/scripts/gc-session-list-cached.sh" 2>/dev/null || echo '{}')
  fi

  for _dvi in $(seq 0 $((DEAD_VERDICT_COUNT - 1))); do
    DV=$(printf '%s\n' "$DEAD_VERDICT_JSON" | jq ".[$_dvi]")
    DV_ID=$(printf '%s\n' "$DV" | jq -r '.id // ""')
    DV_ASSIGNEE=$(printf '%s\n' "$DV" | jq -r '.assignee // ""')
    # ga-1olmq gate-feedback (non-blocking note, addressed): updated_at, NOT
    # created_at. Same CONTRACT reconcile_zero_verdict_run_action's own
    # docstring above already documents for the sibling grace check (ga-jfo7
    # attempt 1) — age_min must reflect time-IN-CURRENT-STATE. A verdict
    # bead's created_at never changes across repeated release/re-convene
    # cycles on the same id; anchoring the boot-grace check to it would work
    # correctly ONLY on the very first assignment, then permanently defeat
    # the grace window on every later reassignment (a freshly re-convoked
    # reviewer's own ~210s boot time would be judged against the ORIGINAL
    # assignment's age, not its own, and get yanked before it ever has a
    # fair chance to appear).
    DV_UPDATED=$(printf '%s\n' "$DV" | jq -r '.updated_at // ""')
    DV_LABELS=$(printf '%s\n' "$DV" | jq -r '(.labels // []) | join(" ")')
    [ -z "$DV_ID" ] && continue
    # Empty assignee: out of scope (see comment block above) — nothing to
    # release (there is no live claim to break) and closing on parent-
    # terminal-alone belongs to the separate follow-up investigation, not
    # silently folded in here.
    [ -z "$DV_ASSIGNEE" ] && continue

    DV_ALIVE=$(session_alive_for_assignee "$DV_ASSIGNEE" "$SESS_SNAP_JSON")
    [ "$DV_ALIVE" = "1" ] && continue

    DV_AGE=$(age_minutes_of "$DV_UPDATED" "$NOW_EPOCH")
    case "$DV_AGE" in ''|*[!0-9]*) DV_AGE=0 ;; esac
    if [ "$DV_AGE" -le "$GATE_DEAD_VERDICT_GRACE_MINUTES" ]; then
      continue
    fi

    DV_GR_ID=$(printf '%s\n' "$DV_LABELS" | grep -oE 'gate-run:[A-Za-z0-9._-]+' | head -1 | sed 's/^gate-run://')
    if [ -z "$DV_GR_ID" ]; then
      warn "ga-u07fn: verdict $DV_ID (age=${DV_AGE}m, assignee=$DV_ASSIGNEE not alive) carries no gate-run:<id> label — cannot determine parent liveness, skipping rather than guessing."
      continue
    fi
    DV_GR_JSON=$(bd -C "$GC_CITY" show "$DV_GR_ID" --json 2>/dev/null)
    DV_GR_FOUND_ID=$(printf '%s\n' "$DV_GR_JSON" | jq -r 'if type=="array" then (.[0].id // empty) else (.id // empty) end' 2>/dev/null)
    if [ -z "$DV_GR_FOUND_ID" ]; then
      warn "ga-u07fn: verdict $DV_ID's parent gate-run $DV_GR_ID unresolvable via bd show — skipping this sweep rather than guessing release-vs-close on an unreadable parent (root-class:error-vs-empty)."
      continue
    fi
    DV_GR_LABELS=$(printf '%s\n' "$DV_GR_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null)
    DV_GR_STATUS=$(marker_status_from_labels "$DV_GR_LABELS")
    DV_GR_TERMINAL=$(gaterun_status_terminal "$DV_GR_STATUS")

    DV_ACTION=$(reconcile_dead_reviewer_verdict_action "$DV_AGE" "$GATE_DEAD_VERDICT_GRACE_MINUTES" "$DV_ALIVE" "$DV_GR_TERMINAL")
    case "$DV_ACTION" in
      release)
        warn "ga-u07fn: releasing stuck verdict $DV_ID (age=${DV_AGE}m, assignee=$DV_ASSIGNEE not alive, parent run $DV_GR_ID active [gate-status:${DV_GR_STATUS:-?}]) for re-convocation."
        bd -C "$GC_CITY" comment "$DV_ID" "ga-u07fn: verdict released — assignee $DV_ASSIGNEE has no live session after ${DV_AGE}m (grace=${GATE_DEAD_VERDICT_GRACE_MINUTES}m) and parent gate-run $DV_GR_ID is still active (gate-status:${DV_GR_STATUS:-?}). Freed for re-convocation by a fresh reviewer. Self-healed by guard." 2>/dev/null || true
        # ga-1olmq gate-feedback (blocking, fixed): --force and --if-assignee
        # are documented as MUTUALLY EXCLUSIVE by `bd unclaim --help`
        # ("cannot be combined with --force (they encode contradictory
        # intent)") and empirically confirmed to error on every invocation,
        # not just races (`bd unclaim <id> --force --if-assignee <x>` ->
        # "Error: if any flags in the group [force if-assignee] are set none
        # of the others can be" — verified live against the real bd 1.1.0
        # binary this guard invokes). The prior version's `2>/dev/null ||
        # warn "...benign race..."` masked a GUARANTEED failure as a rare
        # timing issue, so release never actually happened. --if-assignee
        # ALONE already provides the atomic compare-and-swap this call
        # wants — verified empirically (throwaway test bead): a matching
        # assignee releases successfully as a third party (no --force
        # needed), a mismatched one fails cleanly with no state change,
        # naming the actual current holder. Dropping --force is not a
        # weaker guard than the original intent; it is the only combination
        # bd actually accepts for this operation.
        bd -C "$GC_CITY" unclaim "$DV_ID" --if-assignee "$DV_ASSIGNEE" -r "ga-u07fn: dead-reviewer reap — no live session after ${DV_AGE}m, parent run still active" 2>/dev/null || \
          warn "ga-u07fn: unclaim of $DV_ID did not apply (assignee likely changed since the liveness check moments ago — benign race, next sweep re-evaluates fresh)."
        ;;
      close)
        warn "ga-u07fn: closing stuck verdict $DV_ID (age=${DV_AGE}m, assignee=$DV_ASSIGNEE not alive, parent run $DV_GR_ID terminal [gate-status:${DV_GR_STATUS:-?}]) — leftover state, nothing left to finish."
        bd -C "$GC_CITY" comment "$DV_ID" "ga-u07fn: verdict closed — assignee $DV_ASSIGNEE has no live session after ${DV_AGE}m and parent gate-run $DV_GR_ID is already terminal (gate-status:${DV_GR_STATUS:-?}). This verdict was leftover state, not a stuck review. Self-healed by guard." 2>/dev/null || true
        # ga-u07fn self-audit fix: the comment above already asserts "verdict
        # closed" — if the close call below fails, that comment becomes a
        # claim the code didn't deliver (exactly the "comment promises more
        # than the code does" defect). Mirror the release branch's existing
        # explicit-warn-on-failure pattern instead of a bare `|| true`.
        bd -C "$GC_CITY" close "$DV_ID" -r "gate-run $DV_GR_ID terminal (gate-status:${DV_GR_STATUS:-?}), verdict was leftover assignee state. Closed by guard (ga-u07fn)." 2>/dev/null || \
          warn "ga-u07fn: close of $DV_ID FAILED — the comment above claims it closed but the bead is still open. Next sweep will retry."
        ;;
      skip)
        : # reviewer_alive/grace already filtered above via early `continue`s; reconcile fn's own skip branch is defense-in-depth, nothing further to do
        ;;
    esac
  done
fi

# ── Step 0b.2 (ga-qtc16): orphaned verdict reap — parent gate-run REAPED, not just dead-reviewer ──
# Sibling of Step 0b.1 above, for the population that step's own comment
# explicitly carved OUT of scope: EMPTY-assignee verdict beads whose
# gate-run:<id> doesn't resolve via `bd show` at all (ga-u07fn investigation,
# 45 of 46 open verdicts that day). That population is NOT "dead reviewer on
# a still-active run" (Step 0b.1's case) — it's the run's PARENT gate-run bead
# itself no longer existing, most likely reaped as an old ga-wisp-* ephemeral
# by the wisp reaper, which has no knowledge of (and doesn't cascade to) the
# verdict-bead children a gate-run spawned (distinct from ga-g4m18, which only
# cascades on THIS guard's own supersede:dead-reviewers path — see that
# function's own comment above).
#
# Measured 2026-08-10 (ga-qtc16): of 41 sampled open verdicts, 34 (83%) carry
# a gate-run:<id> pointing nowhere — permanently unkillable via the normal
# dispatch path (no future sweep will ever revisit a bead whose parent is
# gone), and gate-health-monitor.py's VERDICT-ASSIGNEE-GAP/IDLE-REVIEWER
# checks fire on them every cycle as pure, unactionable noise.
#
# root-class:error-vs-empty (deliberately careful): `bd show <id>` exits 1 for
# BOTH "confirmed not found" AND a genuine query failure (Dolt timeout/bad
# path) — same exit code, verified empirically while writing this fix, so
# exit code alone cannot distinguish them. The two cases differ in whether
# stdout is valid, bd-shaped JSON at all: "not found" returns a parseable
# JSON object ({"error": "no issues found matching the provided IDs", ...},
# no .id field); a genuine failure returns a bare, non-JSON error line. So:
# JSON-parses AND .id absent → CONFIRMED gone, safe to close. Doesn't-parse-
# as-JSON → unknown failure, skip (never treat "couldn't read" as "confirmed
# absent" — the exact collapse this codebase's doctrine warns against).
#
# Grace: reuses GATE_DEAD_VERDICT_GRACE_MINUTES (Step 0b.1's sibling constant,
# same "fewer magic numbers" reasoning as that constant's own comment) against
# the VERDICT bead's own age — no plausible legitimate path creates a verdict
# referencing a gate-run that doesn't exist yet (the dispatcher creates the
# gate-run before spawning reviewers), so this only guards against a same-
# cycle Dolt replication-lag artifact, not a real race in normal operation.
log "Step 0b.2 (ga-qtc16): orphaned verdict reap — parent gate-run gone, grace=${GATE_DEAD_VERDICT_GRACE_MINUTES}m..."

if ORPHAN_VERDICT_JSON=$(bd -C "$GC_CITY" list --json --limit 0 \
    -l type:quality-gate-verdict -l verdict:pending \
    --no-assignee \
    2>/dev/null); then
  ORPHAN_VERDICT_COUNT=$(printf '%s\n' "$ORPHAN_VERDICT_JSON" | jq 'length' 2>/dev/null || echo "0")
  case "$ORPHAN_VERDICT_COUNT" in
    ''|*[!0-9]*)
      warn "ga-qtc16: orphan-verdict-reap query returned unparseable output — skipping this sweep rather than guessing a count."
      ORPHAN_VERDICT_COUNT=0
      ;;
  esac
else
  warn "ga-qtc16: orphan-verdict-reap query FAILED (Dolt timeout/contention?) — skipping this sweep; next sweep in ~2min will retry. Not a confirmed-empty result."
  ORPHAN_VERDICT_JSON="[]"
  ORPHAN_VERDICT_COUNT=0
fi

if [ "$ORPHAN_VERDICT_COUNT" -gt 0 ]; then
  NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"

  for _ovi in $(seq 0 $((ORPHAN_VERDICT_COUNT - 1))); do
    OV=$(printf '%s\n' "$ORPHAN_VERDICT_JSON" | jq ".[$_ovi]")
    OV_ID=$(printf '%s\n' "$OV" | jq -r '.id // ""')
    OV_UPDATED=$(printf '%s\n' "$OV" | jq -r '.updated_at // ""')
    OV_LABELS=$(printf '%s\n' "$OV" | jq -r '(.labels // []) | join(" ")')
    [ -z "$OV_ID" ] && continue

    OV_AGE=$(age_minutes_of "$OV_UPDATED" "$NOW_EPOCH")
    case "$OV_AGE" in ''|*[!0-9]*) OV_AGE=0 ;; esac

    # ga-qtc16 gate-fix (attempt 3): same failure class as the OV_GR_RAW fix
    # below, one sibling over. When a verdict carries no gate-run: substring
    # at all — Step 0b.2's OWN anticipated "no label" case, with a dedicated
    # skip branch further down — `grep -oE` finds no match and exits 1; under
    # `pipefail` that nonzero status survives through `head -1`/`sed` (both
    # succeed trivially on empty input) to become the whole pipeline's exit
    # status, so the bare assignment aborted the ENTIRE script on exactly the
    # input this step exists to handle. `|| true` is the same established
    # idiom as the sibling fix immediately below.
    OV_GR_ID=$(printf '%s\n' "$OV_LABELS" | grep -oE 'gate-run:[A-Za-z0-9._-]+' | head -1 | sed 's/^gate-run://') || true
    OV_HAS_GR_LABEL=1
    [ -z "$OV_GR_ID" ] && OV_HAS_GR_LABEL=0

    OV_PARENT_STATE="unknown"
    if [ "$OV_HAS_GR_LABEL" = "1" ]; then
      # ga-qtc16 gate-fix (attempt 2): bare `VAR=$(bd show ...)` aborted the
      # WHOLE script under `set -euo pipefail` the moment the parent gate-run
      # was genuinely not found (bd show exit 1) — the exact case Step 0b.2
      # exists to detect, so it recurred every sweep with any orphan queued.
      # `|| true` is this file's own established idiom for this shape (see
      # line ~3042's near-identical `bd show <id> --json ... || true`): the
      # assignment still captures whatever stdout bd produced on either exit
      # code (the not-found error envelope `{"error": ...}` parses as a JSON
      # object same as before), only the abort-on-nonzero-exit is removed.
      OV_GR_RAW=$(bd -C "$GC_CITY" show "$OV_GR_ID" --json 2>/dev/null) || true
      if printf '%s' "$OV_GR_RAW" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
        OV_GR_FOUND_ID=$(printf '%s' "$OV_GR_RAW" | jq -r 'if type=="array" then (.[0].id // empty) else (.id // empty) end' 2>/dev/null)
        if [ -n "$OV_GR_FOUND_ID" ]; then
          OV_PARENT_STATE="found"
        else
          OV_PARENT_STATE="not_found"
        fi
      fi
      # else stays "unknown" — bd show's own response didn't even parse as
      # JSON, a genuine query failure (Dolt timeout/bad path/etc.), not
      # confirmed absence.
    fi

    OV_ACTION=$(reconcile_orphaned_verdict_action "$OV_AGE" "$GATE_DEAD_VERDICT_GRACE_MINUTES" "$OV_HAS_GR_LABEL" "$OV_PARENT_STATE")
    case "$OV_ACTION" in
      close)
        warn "ga-qtc16: closing orphaned verdict $OV_ID (age=${OV_AGE}m, no assignee, parent gate-run $OV_GR_ID confirmed gone via bd show) — permanently unkillable via the normal dispatch path otherwise."
        bd -C "$GC_CITY" comment "$OV_ID" "ga-qtc16: verdict closed — parent gate-run $OV_GR_ID no longer exists (bd show: not found), most likely reaped as an old ephemeral by the wisp reaper. This verdict was leftover debris, not a stuck review. Self-healed by guard." 2>/dev/null || true
        bd -C "$GC_CITY" close "$OV_ID" -r "parent gate-run $OV_GR_ID does not exist (reaped) — orphaned verdict debris. Closed by guard (ga-qtc16)." 2>/dev/null || \
          warn "ga-qtc16: close of $OV_ID FAILED — the comment above claims it closed but the bead is still open. Next sweep will retry."
        ;;
      skip)
        if [ "$OV_HAS_GR_LABEL" = "1" ] && [ "$OV_PARENT_STATE" = "unknown" ] && [ "$OV_AGE" -gt "$GATE_DEAD_VERDICT_GRACE_MINUTES" ]; then
          warn "ga-qtc16: parent gate-run $OV_GR_ID lookup for verdict $OV_ID returned unparseable output — genuine query failure, not confirmed absent. Skipping."
        elif [ "$OV_HAS_GR_LABEL" != "1" ] && [ "$OV_AGE" -gt "$GATE_DEAD_VERDICT_GRACE_MINUTES" ]; then
          warn "ga-qtc16: verdict $OV_ID (age=${OV_AGE}m, no assignee) carries no gate-run:<id> label — cannot determine parent, skipping rather than guessing."
        fi
        # age<=grace or parent genuinely found: routine, no warn needed.
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
# ga-4tgga: for the bug/task (non-story) branch below, "parent's fix not yet
# verified in origin/main" ALSO gets a safe-default now — if an ACTIVE gate
# marker is currently processing that fix, we wait instead of re-arming
# gate:needs-fix (see classify_gap2_bugtask_verdict above).

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
    SC_LABELS=$(echo "$SC_SHOW" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")

    HAS_SC_ASSIGNEE=0
    if [ -n "$SC_ASSIGNEE" ] && [ "$SC_ASSIGNEE" != "null" ]; then
      SC_SESSION_JSON=$(bash "$GC_CITY/scripts/gc-session-list-cached.sh" 2>/dev/null || echo "{}")
      [ "$(session_matches_author "$SC_ASSIGNEE" "$SC_SESSION_JSON")" = "1" ] && HAS_SC_ASSIGNEE=1
    fi

    # Find sling bead ID from Pilot dispatch comment.
    SLING_ID=$(echo "$SC_SHOW" | jq -r '
      .comments // [] | sort_by(.created_at) | reverse |
      .[] | .text // "" | select(test("Sling task bead:")) |
      capture("Sling task bead: (?<id>[a-z][a-z0-9-]+)") | .id
    ' 2>/dev/null | head -1 || echo "")

    SLING_FOUND=0
    SLING_NEEDS_FIX=0
    SLING_CLOSED=0
    SLING_REFUSED=0
    SLING_REFUSED_TOKEN=""

    if [ -n "$SLING_ID" ] && [ "$SLING_ID" != "null" ]; then
      SLING_FOUND=1
      SLING_JSON=$(bd -C "$GC_CITY" show "$SLING_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      SLING_STATUS=$(echo "$SLING_JSON" | jq -r '.status // ""' 2>/dev/null || echo "")
      SLING_LABELS=$(echo "$SLING_JSON" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")
      SLING_CLOSE_REASON=$(echo "$SLING_JSON" | jq -r '.close_reason // ""' 2>/dev/null || echo "")

      [ "$SLING_STATUS" = "closed" ] && SLING_CLOSED=1
      echo "$SLING_LABELS" | grep -qE "gate:needs-fix|gate:needs-human" && SLING_NEEDS_FIX=1 || true

      # ga-eu75w: a refused sling was never gate-reviewed — its terminal state
      # must not be read as "gate-passed" just because it lacks gate:needs-fix
      # (the old bug). The refusal marker can land on the sling itself, on the
      # PARENT directly (ga-1ztxb precedent), or only in the sling's own
      # close_reason text — gap2_refused_token checks all three.
      SLING_REFUSED_TOKEN=$(gap2_refused_token "$SLING_LABELS" "$SC_LABELS" "$SLING_CLOSE_REASON" || echo "")
      [ -n "$SLING_REFUSED_TOKEN" ] && SLING_REFUSED=1 || true
    fi

    ACTION=$(classify_parent_gap2 "1" "$HAS_SC_ASSIGNEE" "$SLING_FOUND" "$SLING_NEEDS_FIX" "$SLING_CLOSED" "$SLING_REFUSED")

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
      free:refused-stranded)
        warn "GAP-2: $SC_ID stranded (sling $SLING_ID closed via refusal: $SLING_REFUSED_TOKEN) — clearing false gate labels, freeing lane"
        gap2_free_refused_stranded "$SC_ID" "$SLING_ID" "$SLING_REFUSED_TOKEN"
        ;;
      free:pass-stranded)
        warn "GAP-2: $SC_ID stranded (sling $SLING_ID closed/passed) — freeing lane"

        # ga-1un0n: story:approved is PRODUCT approval, not proof a reviewer
        # ever ran — it must NEVER bypass the verification below (it used to:
        # this branch used to set gate:passed unconditionally the moment a
        # sling closed without failing, with zero check that any review had
        # started. Measured live TWICE in ~1h — ga-qhca1, ga-x3e7p — both
        # times with the real gate-run still gate-status:running, no
        # verdict). Every parent type now computes the SAME evidence
        # (untracked-marker / active-marker / merge-ancestry) and reaches the
        # SAME classify_gap2_bugtask_verdict call; only the terminal action on
        # an affirmative verdict differs (gate:passed handoff vs. direct
        # close), decided by gap2_apply_pass_verdict below.
        GAP2_IS_STORY=0
        echo "$SC_LABELS" | grep -q "story:approved" && GAP2_IS_STORY=1

        # sling-passed+closed is a done-SIGNAL, not proof the PARENT's own fix
        # landed (ga-6ync4 — same root flaw as ga-266z8's story-delivery.sh
        # task reconciler, different code path: trusting a done-signal
        # instead of an ancestry/content merge check). Verify via the same
        # branch-lookup + guard_content_merged check GAP-1 already uses just
        # above (this file) before closing — try the parent's own id first,
        # then the sling wrapper's id (a fix branch is occasionally named
        # after the sling task instead of the parent; ga-vokwv precedent in
        # merged-bead-janitor.sh's sibling sweep).
        #
        # ga-x2x63: a parent explicitly labeled delivery:untracked has a
        # legitimate deliverable that is a git-ignored/untracked file edit (no
        # worktree, no PR, no branch by design — see ga-liaaj precedent), so no
        # fix/feature branch could ever exist to find. Skip the branch search
        # for that case instead of letting it run and find nothing — running
        # it anyway would collapse "structurally inapplicable" into "checked
        # and not merged", the exact false-positive this bug reports.
        #
        # ga-4tgga: labels are now left UNTOUCHED (not just the verdict — the
        # actual bd label calls below) until we know we are not simply waiting
        # on the gate. The old code stripped story:in-flight/pilot:dispatched
        # unconditionally before any of this ran, so even the "waiting on an
        # active marker" case let Pilot redispatch a second builder the moment
        # the strip landed, regardless of what the verdict turned out to be.
        GAP2_HAS_UNTRACKED_MARKER=0
        echo "$SC_LABELS" | grep -q "delivery:untracked" && GAP2_HAS_UNTRACKED_MARKER=1

        # Check for an ACTIVE gate marker on the parent's OWN fix BEFORE
        # running the (slower) merge-ancestry search below — same
        # error-vs-empty shape as the untracked-delivery check above. "Not
        # yet verified in origin/main" only means "abandoned" if nothing is
        # currently reviewing it; a marker still ready/queued/claimed/
        # dispatching/running for this exact source-bead means the fix
        # simply hasn't finished its turn in the gate queue yet.
        GAP2_HAS_ACTIVE_MARKER=0
        GAP2_ACTIVE_HIT=""
        if [ "$GAP2_HAS_UNTRACKED_MARKER" != "1" ]; then
          GAP2_ACTIVE_MARKERS_JSON=$(gap2_query_active_markers)
          GAP2_ACTIVE_HIT=$(gap2_marker_for_bead "$GAP2_ACTIVE_MARKERS_JSON" "$SC_ID")
          [ -z "$GAP2_ACTIVE_HIT" ] && GAP2_ACTIVE_HIT=$(gap2_marker_for_bead "$GAP2_ACTIVE_MARKERS_JSON" "$SLING_ID")
          [ -n "$GAP2_ACTIVE_HIT" ] && GAP2_HAS_ACTIVE_MARKER=1
        fi

        GAP2_MERGE_VERIFIED=0
        if [ "$GAP2_HAS_UNTRACKED_MARKER" = "1" ]; then
          log "GAP-2: $SC_ID carries delivery:untracked — skipping branch/merge search"
        elif [ "$GAP2_HAS_ACTIVE_MARKER" = "1" ]; then
          log "GAP-2: $SC_ID — active gate marker found ($GAP2_ACTIVE_HIT) — skipping branch/merge search, waiting for the gate instead"
        else
          GAP2_MAIN_SHA=""
          git -C "$GC_CITY" fetch origin main --quiet 2>/dev/null || true
          GAP2_MAIN_SHA=$(git -C "$GC_CITY" rev-parse "origin/main" 2>/dev/null || echo "")

          if [ -n "$GAP2_MAIN_SHA" ]; then
            for GAP2_TRY_ID in "$SC_ID" "$SLING_ID"; do
              [ -n "$GAP2_TRY_ID" ] || continue
              GAP2_BRANCH_SHA=""
              for GAP2_PAT in "refs/heads/fix/${GAP2_TRY_ID}" "refs/heads/fix/${GAP2_TRY_ID}-*" \
                         "refs/heads/feature/${GAP2_TRY_ID}" "refs/heads/feature/${GAP2_TRY_ID}-*"; do
                GAP2_SHA=$(git -C "$GC_CITY" ls-remote origin "$GAP2_PAT" 2>/dev/null | head -1 | awk '{print $1}')
                if [ -z "$GAP2_SHA" ]; then
                  GAP2_RREF="${GAP2_PAT/refs\/heads\//refs\/remotes\/origin\/}"
                  GAP2_SHA=$(git -C "$GC_CITY" for-each-ref --format='%(objectname)' "$GAP2_RREF" 2>/dev/null | head -1)
                fi
                [ -n "$GAP2_SHA" ] && { GAP2_BRANCH_SHA="$GAP2_SHA"; break; }
              done
              [ -z "$GAP2_BRANCH_SHA" ] && continue

              if git -C "$GC_CITY" merge-base --is-ancestor "$GAP2_BRANCH_SHA" "$GAP2_MAIN_SHA" 2>/dev/null; then
                GAP2_MERGE_VERIFIED=1; break
              elif guard_content_merged "$GAP2_MAIN_SHA" "$GAP2_BRANCH_SHA"; then
                GAP2_MERGE_VERIFIED=1; break
              fi
            done
          else
            warn "GAP-2: $SC_ID — origin/main SHA unreachable — cannot verify merge; treating as NOT verified (fail-safe)"
          fi
        fi

        GAP2_VERDICT=$(classify_gap2_bugtask_verdict "$GAP2_MERGE_VERIFIED" "$GAP2_HAS_UNTRACKED_MARKER" "$GAP2_HAS_ACTIVE_MARKER")
        case "$GAP2_VERDICT" in
          close:merge-verified|close:untracked-delivery)
            gap2_apply_pass_verdict "$SC_ID" "$SLING_ID" "$GAP2_IS_STORY" "$GAP2_VERDICT"
            ;;
          wait:active-marker)
            log "GAP-2: $SC_ID sling $SLING_ID gate-passed+closed, parent's own fix not yet verified in origin/main, but an ACTIVE gate marker ($GAP2_ACTIVE_HIT) is still processing it — not touching labels, waiting for the gate."
            bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: sling bead $SLING_ID gate-passed+closed; parent's own fix not yet independently verified in origin/main, but an ACTIVE quality-gate-marker ($GAP2_ACTIVE_HIT) is currently processing it — still queued for review, not abandoned. No labels changed; will re-check next sweep. (ga-4tgga)" 2>/dev/null || true
            ;;
          *)
            # ga-4tgga race guard: re-check for an active marker RIGHT before
            # this mutation — the git branch-search above can take several
            # seconds, wide enough for a fresh submission to land while it
            # ran. Fail-safe toward NOT touching labels, per the bug's own
            # cost asymmetry: a wrong redispatch costs a duplicate branch; a
            # wrongly-skipped sweep costs one more reconciler pass (cheap,
            # self-corrects next run).
            GAP2_RECHECK_JSON=$(gap2_query_active_markers)
            GAP2_RECHECK_HIT=$(gap2_marker_for_bead "$GAP2_RECHECK_JSON" "$SC_ID")
            [ -z "$GAP2_RECHECK_HIT" ] && GAP2_RECHECK_HIT=$(gap2_marker_for_bead "$GAP2_RECHECK_JSON" "$SLING_ID")
            if [ -n "$GAP2_RECHECK_HIT" ]; then
              log "GAP-2: $SC_ID — active marker ($GAP2_RECHECK_HIT) appeared during merge-search — waiting instead of re-arming (race guard)"
              bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: sling bead $SLING_ID gate-passed+closed; an active quality-gate-marker ($GAP2_RECHECK_HIT) for the parent's own fix appeared while this sweep was verifying merge state — treating as in-flight, not abandoned. No labels changed. (ga-4tgga)" 2>/dev/null || true
            else
              warn "GAP-2: $SC_ID sling $SLING_ID gate-passed+closed but parent's own fix NOT verified in origin/main (ga-6ync4 — sling-passed is a signal, not proof) — NOT marking gate:passed/closing; re-arming gate:needs-fix + gate:needs-remerge"
              # ga-4tgga gate-feedback (attempt 2, blocking): extracted to
              # gap2_arm_needs_remerge() (lib region above) so this arm's
              # label-remove calls are independently unit-testable — see
              # that function's doc-comment for why.
              gap2_arm_needs_remerge "$SC_ID" "$SLING_ID"
            fi
            ;;
        esac
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

# ── Step 0c.3 (ga-jto05 GAP-3): external-PR re-check ────────────────────────
# GAP-1/GAP-2 above only ever look for evidence in gascity-hq's OWN origin/main
# — structurally blind to a bead whose real deliverable is a PR in a DIFFERENT
# repo (fork -> PR -> upstream-review flow, e.g. the beads CLI's own
# gastownhall/beads). story:awaiting-external-merge is documented as "the
# manual marker" for exactly this path (pilot-dispatcher.sh, ga-spux4): "a
# human/Mayor sweep removes the label once the PR merges... no daemon watches
# external PRs for merge yet, so removal is manual." This step IS that daemon.
# Cost of the gap (ga-jto05): ga-ahnxx/ga-hqchm sat merged-but-open ~11 days
# each before a dog checked gh pr view by hand; ga-yp9r8 was one accidental
# GAP-2 re-arm away from the same fate (GAP-2's blind spot mislabeled it
# gate:needs-fix/needs-remerge — a real reviewer never rejected anything, the
# PR was simply clean and unreviewed).
# Safe-default: no PR URL found in comments, or gh call fails/PR state
# ambiguous -> do NOT act (both fold into a silent, logged no-op).

log "Step 0c.3 (ga-jto05 GAP-3): sweep story:awaiting-external-merge beads for external PR state..."

if ! command -v gh >/dev/null 2>&1; then
  log "GAP-3: gh CLI not found on PATH — skipping external-PR sweep entirely"
else
  EXT_IDS=$(bd -C "$GC_CITY" list --json --all --status open -l story:awaiting-external-merge 2>/dev/null \
    | jq -r '.[].id' 2>/dev/null || echo "")

  for EXT_ID in $EXT_IDS; do
    [ -z "$EXT_ID" ] && continue

    # ga-jto05 gate-FAIL fix: bd's own failure convention prints a non-empty
    # JSON error object ({"error":...}) to STDOUT with a nonzero exit — the
    # previous version piped straight into jq, whose `if type=="array"`
    # passes that object through unchanged (else-branch), so `-z` on the
    # RESULT never saw an empty string and this branch never fired. Checking
    # bd's own exit status directly, before jq ever sees the output, is the
    # only way to tell "bd show failed" apart from "bd show succeeded but
    # returned something jq couldn't use" — the two checks below are
    # deliberately two separate steps, not one combined pipeline.
    if ! EXT_SHOW_RAW=$(bd -C "$GC_CITY" show "$EXT_ID" --json --include-comments 2>/dev/null); then
      log "GAP-3: $EXT_ID — bd show --include-comments failed (nonzero exit) — safe-skip"
      continue
    fi

    EXT_SHOW=$(echo "$EXT_SHOW_RAW" | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")

    # ga-jto05 self-audit: "no PR ref found" and "couldn't even read the bead"
    # are different failures with the same downstream action (skip) but a
    # DIFFERENT cause a human triaging the log needs to see distinctly — a
    # collapsed "no GitHub PR URL found" message here would itself become the
    # kind of misleading-comment defect this file's own doctrine warns about
    # (a log line that stops the next reader from looking further).
    if [ -z "$EXT_SHOW" ]; then
      log "GAP-3: $EXT_ID — bd show --include-comments returned unparseable data — safe-skip"
      continue
    fi

    # Newest-first: if a bead was dispatched more than once (a prior PR
    # abandoned, a fresh one opened later), the most recent comment is the
    # live reference — mirrors GAP-2's own "Sling task bead" extraction
    # (sort_by(.created_at)|reverse, select() before capture() so a
    # non-matching comment never reaches capture() and aborts the pipeline).
    EXT_PR_REF=$(echo "$EXT_SHOW" | jq -r '
      .comments // [] | sort_by(.created_at) | reverse |
      .[] | .text // "" |
      select(test("https://github\\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+")) |
      capture("https://github\\.com/(?<owner>[^/\\s]+)/(?<repo>[^/\\s]+)/pull/(?<num>[0-9]+)") |
      "\(.owner)/\(.repo) \(.num)"
    ' 2>/dev/null | head -1 || echo "")

    if [ -z "$EXT_PR_REF" ]; then
      log "GAP-3: $EXT_ID — no GitHub PR URL found in comments — safe-skip"
      continue
    fi

    EXT_REPO="${EXT_PR_REF%% *}"
    EXT_NUM="${EXT_PR_REF##* }"

    EXT_PR_JSON=$(gh pr view "$EXT_NUM" --repo "$EXT_REPO" --json state,reviewDecision,mergedAt,mergeCommit,url 2>/dev/null || echo "")

    if [ -z "$EXT_PR_JSON" ]; then
      log "GAP-3: $EXT_ID — gh pr view $EXT_NUM --repo $EXT_REPO failed (network/auth/not-found) — safe-skip"
      continue
    fi

    EXT_STATE=$(echo "$EXT_PR_JSON" | jq -r '.state // ""' 2>/dev/null || echo "")
    EXT_REVIEW=$(echo "$EXT_PR_JSON" | jq -r '.reviewDecision // ""' 2>/dev/null || echo "")
    EXT_MERGE_SHA=$(echo "$EXT_PR_JSON" | jq -r '.mergeCommit.oid // ""' 2>/dev/null || echo "")
    EXT_URL=$(echo "$EXT_PR_JSON" | jq -r '.url // ""' 2>/dev/null || echo "")
    [ -z "$EXT_URL" ] && EXT_URL="https://github.com/$EXT_REPO/pull/$EXT_NUM"

    EXT_ACTION=$(classify_external_pr_gap3 "$EXT_STATE" "$EXT_REVIEW")

    case "$EXT_ACTION" in
      close:merged)
        warn "GAP-3: $EXT_ID — PR $EXT_URL is MERGED${EXT_MERGE_SHA:+ ($EXT_MERGE_SHA)} — closing"
        bd -C "$GC_CITY" label remove "$EXT_ID" "story:awaiting-external-merge" -q 2>/dev/null || true
        bd -C "$GC_CITY" close "$EXT_ID" \
          -r "ga-jto05 GAP-3 reconciler: external PR $EXT_URL merged${EXT_MERGE_SHA:+ (commit $EXT_MERGE_SHA)} — work is done; closing." \
          2>/dev/null || warn "GAP-3: could not close $EXT_ID after external-PR-merged detection"
        ;;
      flag:closed-not-merged)
        warn "GAP-3: $EXT_ID — PR $EXT_URL is CLOSED without merging — flagging needs-human"
        bd -C "$GC_CITY" label remove "$EXT_ID" "story:awaiting-external-merge" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$EXT_ID" "gate:needs-human"              -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$EXT_ID" "ga-jto05 GAP-3 reconciler: external PR $EXT_URL was closed WITHOUT merging (rejected/abandoned upstream). story:awaiting-external-merge cleared; gate:needs-human set — a human should decide whether to open a new PR or abandon this bead." 2>/dev/null || true
        ;;
      flag:changes-requested)
        warn "GAP-3: $EXT_ID — PR $EXT_URL has CHANGES_REQUESTED — surfacing real gate:needs-fix"
        bd -C "$GC_CITY" label remove "$EXT_ID" "story:awaiting-external-merge" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$EXT_ID" "gate:needs-fix"                -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$EXT_ID" "ga-jto05 GAP-3 reconciler: external PR $EXT_URL is OPEN with reviewDecision=CHANGES_REQUESTED — an upstream reviewer requested changes. story:awaiting-external-merge cleared; gate:needs-fix set so Pilot dispatches a builder with the real review feedback as brief (fetch via gh pr view $EXT_NUM --repo $EXT_REPO --json reviews,comments — this is the case ga-e2n96 says gate:needs-fix should actually mean: a reviewer really did reject the code)." 2>/dev/null || true
        ;;
      wait:pending)
        log "GAP-3: $EXT_ID — PR $EXT_URL is OPEN, reviewDecision=${EXT_REVIEW:-none} — still genuinely pending, no action"
        ;;
      skip:indeterminate)
        log "GAP-3: $EXT_ID — PR state indeterminate (state='$EXT_STATE') — safe-skip"
        ;;
    esac
  done
fi

# ── Step 1: Find unclaimed ready-for-gate markers ─────────────────────────────

# ⚠️ --include-infra e --limit 0 são OBRIGATÓRIOS aqui (Mayor, 07/08).
#
# --include-infra: o bd 1.1.0 classifica bead `--ephemeral` como INFRA e o OMITE
# de `bd list` por padrão. Markers antigos (e qualquer um criado por um /gate-done
# ainda não atualizado) são ephemeral, então esta consulta — a DESCOBERTA PRIMÁRIA
# do gate — enxergava zero e o guard saía logando honestamente "No work. Exiting."
# Medido no momento do conserto: **o guard via 0, existiam 7** markers
# gate-status:ready. Foi a causa do gate passar 2h sem revisar nada.
#
# --limit 0: `bd list` trunca em 50 e o aviso vai pro stderr, que o `2>/dev/null`
# logo abaixo engole (ga-21kmp). Com fila funda o guard veria só os 50 primeiros —
# defeito latente que aparece justamente quando há backlog.
#
# Este é o par error-vs-empty: "não achei" e "não existe" produziam o mesmo valor,
# e o valor significava "não há trabalho".
MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all --limit 0 --include-infra \
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

# ga-qblq4: verify FIRST (pure read, no mutation) — then add claimed BEFORE
# removing ready, same invariant as set_gate_status/ga-i0n83 and mirroring the
# dispatcher's queued→dispatching claim fix (quality-gate-dispatcher.sh Step
# 1). The prior shape (remove ready, THEN verify) put the live marker through
# a window with ZERO gate-status:* labels while the verify+log steps ran —
# gate-queue-composition.sh's classifier reads that as FANTASMA (safe to
# clean up), misreading a marker mid-claim as abandoned garbage. Worst case
# now is a brief window with BOTH ready+claimed, which the classifier reads
# as ambiguous/UNKNOWN — inert, not destructive — and Vector A's CLAIM_TTL
# reclaim (this file) already converges a marker stuck with two labels back
# to one.
# `bd show --json` returns an ARRAY, not an object. Without the array
# normalization below, `jq '(.labels // [])'` errors out ("Cannot index array
# with string labels"), 2>/dev/null swallows it, CURRENT_LABELS comes back
# EMPTY, and the gate-status:ready check below can never match — so every
# claim attempt reported "raced away before claim" and exit 0'd, forever, on
# a marker that was sitting at gate-status:ready the whole time. Because that
# exit 0 abandons the whole sweep, ONE marker head-of-line-blocked the entire
# queue: measured 2026-08-10, ga-zwjmf failed identically on 7 consecutive
# sweeps (14:19→14:32) while two other ready markers behind it were never
# even attempted, and the dispatcher correctly logged "Found 0 queued
# marker(s)" because nothing was ever promoted ready→queued.
#
# The two other `bd show --json` reads in this same file (SC_SHOW ~L2578,
# SLING_JSON ~L2604) already carry this exact normalization — this call site
# was the one that was missed, which is why the bug looked like a race
# instead of a parse error. Note the failure mode this collapses: a read
# error and a genuinely-empty label set produced the SAME value (""), so a
# permanent parse failure was indistinguishable from — and got reported as —
# a transient race.
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null \
  | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "{}")
CURRENT_LABELS=$(echo "$VERIFY_JSON" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$CURRENT_LABELS" | grep -q "gate-status:claimed"; then
  log "Marker $MARKER_ID already claimed by another sweep. Skipping."
  exit 0
fi

if ! echo "$CURRENT_LABELS" | grep -q "gate-status:ready"; then
  log "Marker $MARKER_ID no longer ready (raced away before claim). Skipping."
  exit 0
fi

# We believe we can claim it — add claimed before removing ready.
bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || {
  err "Failed to add gate-status:claimed to $MARKER_ID. Aborting."
  exit 1
}
bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:ready" -q 2>/dev/null || true

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
# wa-2ddr0 (mirrors quality-gate-dispatcher.sh Step 2): the bead's OWN store,
# independent of $RIG (the code rig) — feeds resolve_bead_city's 3rd probe
# candidate below. Empty on a marker predating this fix; resolve_bead_city
# then degrades to its pre-existing RIG_PATH/GC_CITY behavior, unchanged.
BEAD_RIG=$(extract "bead_rig")

log "  branch=$BRANCH  bead_id=$BEAD_ID  marker_author=${MARKER_AUTHOR:-<EMPTY>}  rig=$RIG  bead_rig=${BEAD_RIG:-<EMPTY>}"

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

# ── Step 4b (ga-o64z1): supersede duplicate open markers for the same branch ──
# BUG: every /gate-done resubmission (gate FAIL -> author fixes -> resubmit)
# creates a brand-new marker, but nothing ever closes the PRIOR marker for the
# same branch. Confirmed live: fix/ga-0xmxt-midturn-liveness accumulated 3
# simultaneous open markers; fix/ga-991au-skip-ineligible and
# fix/ga-kyxih-gate-rebase-merge-commit-tip 2 each. Not just queue litter:
# quality-gate-dispatcher.sh's Step 5b (ga-dupnv, "one branch = one
# authoritative run") sees a live gate-run for the branch and makes the WHOLE
# sweep YIELD without admitting any other marker — so a duplicate sterilizes
# sweeps while its sibling runs, and the cost grows with every resubmission.
# Step 0a only re-queues zombie `dispatching` markers past a TTL; it never
# closes a duplicate sitting in ready/queued/needs-rebase. Fixing it HERE
# (not gate-done.md, which is agent-executed markdown and does not source
# this file's helpers, so duplicating the query there would drift) means
# every marker gets deduped exactly once, right after BRANCH is validated
# (Step 4) and before this marker does anything else. Every resubmission
# creates a fresh gate-status:ready marker (gate-done.md Step 3), so Step 1's
# unclaimed-ready scan always eventually reaches it and fires this check —
# even when the OLDER siblings have since aged into queued/needs-rebase.
# Only ready/queued/needs-rebase are touched (AC1) — dispatching/running are
# deliberately left alone; a legitimate live run for this branch is the
# dispatcher's Step 5b's job, not this one's.
DUP_QUERY_OK=1
# --include-infra/--limit 0: mesma razão da consulta do Step 1 (ver comentário lá).
# Aqui o custo de ficar cego é PIOR e mais silencioso: esta consulta detecta marker
# DUPLICADO. Sem enxergar os ephemeral, ela conclui "não há duplicata" e o guard
# deixa passar dois markers para a mesma branch — dois runs, dois revisores, e
# possivelmente dois merges. Um detector cego não fica quieto: ele dá sinal verde.
DUP_MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all --status open --limit 0 --include-infra \
  -l type:quality-gate-marker \
  --label-any gate-status:ready \
  --label-any gate-status:queued \
  --label-any gate-status:needs-rebase \
  2>/dev/null) || DUP_QUERY_OK=0
[ -z "$DUP_MARKERS_JSON" ] && DUP_MARKERS_JSON="[]"

if [ "$DUP_QUERY_OK" = "0" ]; then
  # AC2: a failed query must not read the same as "checked, found none" — log
  # it as its own distinct outcome so a broken query is diagnosable instead
  # of silently passing as a clean branch.
  warn "Step 4b: sibling-marker query failed for branch $BRANCH — dedup check SKIPPED (non-fatal, distinct from '0 duplicates found')."
else
  DUP_IDS=$(dup_marker_ids_for_branch "$DUP_MARKERS_JSON" "$BRANCH" "$MARKER_ID")
  DUP_COUNT=$(printf '%s\n' "$DUP_IDS" | grep -c . || true)
  case "$DUP_COUNT" in ''|*[!0-9]*) DUP_COUNT=0 ;; esac

  if [ "$DUP_COUNT" -gt 0 ]; then
    log "Step 4b: branch $BRANCH has $DUP_COUNT pre-existing open marker(s) in {ready,queued,needs-rebase} — superseding by $MARKER_ID."
    printf '%s\n' "$DUP_IDS" | while IFS= read -r DUP_ID; do
      [ -z "$DUP_ID" ] && continue
      set_gate_status "$DUP_ID" "superseded"
      bd -C "$GC_CITY" comment "$DUP_ID" "Superseded by $MARKER_ID — newer /gate-done submission for the same branch ($BRANCH). Gate guard Step 4b (ga-o64z1): at most one open marker per branch." 2>/dev/null || true
      bd -C "$GC_CITY" close "$DUP_ID" -r "Superseded by $MARKER_ID for branch $BRANCH (ga-o64z1 marker dedup)." 2>/dev/null || true
      log "  Step 4b: superseded $DUP_ID (branch $BRANCH)."
    done
  else
    log "Step 4b: no pre-existing open marker for branch $BRANCH — nothing to supersede."
  fi
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
  # ga-07509: on failure BEAD_RAW stays "" exactly as before — the fallback-
  # to-HQ-DB guard right below already treats empty as "try the other
  # lookup", which is the correct response whether gc failed OR the bead
  # genuinely wasn't found there; only the failure DETECTION changes.
  BEAD_RAW=$(gc_json_or_unknown gc --city "$GC_CITY" bd show "$BEAD_ID" --json) || true

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
  # ga-qblq4: add deferred BEFORE removing claimed (same invariant as
  # set_gate_status/ga-i0n83) — avoids a zero-gate-status window.
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred" -q 2>/dev/null || true
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed"  -q 2>/dev/null || true
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

# ga-409f4: notification target for this guard's own nudges/mails below,
# resolved separately from $AUTHOR. $AUTHOR (Step 5 above) is derived from
# the bead's assignee/created_by/owner for the DIFFERENT purpose of
# self-review exclusion (SECURITY note above) — a bead's assignee can be a
# reporter/PM who delegated the coding to someone else without reassigning
# the bead. Reproduced live: bead assignee=digo-wa, actual branch
# author=mila on crew/mila/wa-o4ygn-r2 — a gate notification went to
# digo-wa, costing the real author 2 hops/~15min to learn about it. The
# branch's own crew/<name>/ segment is immutable once pushed and always
# names the real author for crew branches; anything else (dog fix/*,
# wa-worker/* branches) falls back to $AUTHOR unchanged — the CONTROLE case
# from ga-409f4's acceptance criteria (no crew segment -> today's behavior).
# SELFTEST-EXTRACT notify-author-resolve: BEGIN
NOTIFY_AUTHOR=$(printf '%s' "$BRANCH" | sed -n 's#^crew/\([^/]\{1,\}\)/.*#\1#p')
[ -z "$NOTIFY_AUTHOR" ] && NOTIFY_AUTHOR="$AUTHOR"
# SELFTEST-EXTRACT notify-author-resolve: END

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
    # ga-6qbgy: cite the label(s) that ACTUALLY matched, not the bare prefix
    # name — see matching_veto_labels() above for why. Falls back to the old
    # bare-name text only if extraction somehow comes up empty (defensive;
    # should be unreachable since PARK_ACTION already proved a match exists).
    case "$PARK_ACTION" in
      park:needs-approval)
        MATCHED_VETO_LABELS=$(matching_veto_labels "$SRC_LABELS_PARK" "story:needs-approval")
        PARK_REASON="source bead $BEAD_ID carries ${MATCHED_VETO_LABELS:-story:needs-approval} (not yet product-approved)" ;;
      park:needs-human)
        MATCHED_VETO_LABELS=$(matching_veto_labels "$SRC_LABELS_PARK" "gate:needs-human")
        PARK_REASON="source bead $BEAD_ID carries ${MATCHED_VETO_LABELS:-gate:needs-human} (circuit-broken — human intervention required)" ;;
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
    # ga-oo66: durable mail to the AUTHOR — a marker/source-bead COMMENT alone
    # is indistinguishable from "queued, reviewers incoming" (both look like
    # silence to whoever submitted). /gate-done promises "you will be mailed
    # when the gate passes or fails" and this park never fulfilled that
    # promise. Mail (not nudge) survives a dead/restarted author session and
    # reaches whoever resubmits later even from a DIFFERENT session
    # (compaction, crash, different agent) — same rationale as ga-u4yi's
    # AUTHOR mail at the dispatcher's gate:needs-human transition sites.
    case "$PARK_ACTION" in
      park:needs-approval) UNBLOCK_HINT="Get $BEAD_ID product-approved (clear ${MATCHED_VETO_LABELS:-story:needs-approval})" ;;
      park:needs-human)    UNBLOCK_HINT="Get a human/Mayor to resolve the gate:needs-human circuit-break on $BEAD_ID — clear ALL of: ${MATCHED_VETO_LABELS:-gate:needs-human} (bd label remove only takes exact names, so removing just the bare label can leave a sibling variant live and parking silently; scripts/gate-unhold.sh $BEAD_ID gate:needs-human clears every variant in one verified operation — ga-6qbgy)" ;;
      *)                   UNBLOCK_HINT="Resolve the blocking condition on $BEAD_ID" ;;
    esac
    # ga-409f4: NOTIFY_AUTHOR (branch-author-aware), not the bead-derived $AUTHOR.
    if [ -n "$NOTIFY_AUTHOR" ]; then
      gc --city "$GC_CITY" mail send "$NOTIFY_AUTHOR" \
        -s "Gate marker parked (not queued): $BEAD_ID" \
        -m "$(printf 'Your gate marker %s (bead %s, branch %s) was PARKED, not queued — %s.\n\nNo gate-run was created and no reviewer was spawned. This is different from "queued, reviewers incoming": nothing further will happen on this marker.\n\n%s, then submit a fresh gate marker. Until then, any further /gate-done resubmission for this bead will keep being silently parked — this mail is the one signal you get for THIS attempt.' \
          "$MARKER_ID" "$BEAD_ID" "$BRANCH" "$PARK_REASON" "$UNBLOCK_HINT")" \
        2>/dev/null || warn "Could not mail author $NOTIFY_AUTHOR for Step 5a park on $BEAD_ID (marker $MARKER_ID)"
    fi
    bd -C "$GC_CITY" close "$MARKER_ID" \
      -r "Gate guard Step 5a: marker parked (terminal) — $PARK_REASON. No gate-run created." \
      2>/dev/null || true
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
# ga-07509: on failure RIG_LIST_JSON stays "" (never the look-alike-valid
# '{}' the old fallback produced). Every fallback below already treats
# "no match" the same regardless of whether RIG_LIST_JSON is "" or '{}' (all
# read via `jq ... 2>/dev/null | head -1 || echo ""`, which degrades to
# empty either way) — and per the comment above, an unresolved RIG_PATH here
# is explicitly non-fatal (best-effort detach), so this migration only moves
# failure DETECTION onto the authoritative signal without changing behavior.
RIG_LIST_JSON=$(gc_json_or_unknown gc --city "$GC_CITY" rig list --json) || true
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

# wa-2ddr0 (mirrors quality-gate-dispatcher.sh's gate_resolve_rig_context): resolve
# BEAD_RIG into a path too, independent of RIG_PATH above. Same rationale as the
# dispatcher — "gascity" is itself a registered self-repo rig (path == $GC_CITY)
# so it round-trips through this same lookup with no special-casing; "unknown" is
# /gate-done's explicit could-not-determine sentinel, never a real rig name.
BEAD_RIG_PATH=""
if [ -n "${BEAD_RIG:-}" ] && [ "$BEAD_RIG" != "unknown" ]; then
  BEAD_RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$BEAD_RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
fi
[ -d "$BEAD_RIG_PATH" ] || BEAD_RIG_PATH=""

# resolve_bead_city <bead-id> — echo the store dir whose Dolt DB owns <bead-id>.
# Probes BEAD_RIG_PATH first (wa-2ddr0: the bead's own resolved store — the
# strongest signal, since /gate-done computed it by actually probing at submit
# time), then RIG_PATH (rig-native beads), then GC_CITY (HQ). A store "owns" the
# bead iff `bd -C <store> show` yields a record with non-empty .status; a
# not-found probe returns {"error":...} (no .status → skip). Falls back to a
# bead-id prefix heuristic (ga-* → HQ; else rig) only when NO store resolves
# (transient Dolt hiccup). Mirrors quality-gate-dispatcher.sh:resolve_bead_city.
resolve_bead_city() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${BEAD_RIG_PATH:-}" "${RIG_PATH:-}" "$GC_CITY"; do
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

# ── Step 5b-pre (ga-pj5va): submission-time branch-content-coherence check ──
# Moves the ga-y9a1d branch/bead-identity check from MERGE time (deep inside
# quality-gate-dispatcher.sh's Step 10 — a full fix cycle away, often hours,
# and a real miss escalates to gate:needs-human waiting on a person) to
# SUBMISSION time: this same guard sweep, ~2 min after /gate-done, refused
# with gate-status:error and an actionable comment — the same cost class as
# any other Step 4 validation failure, not a human escalation.
#
# Fail-OPEN on any uncertainty (RIG_PATH unresolved, fetch/rev-parse/
# merge-base failure): this is a NEW, additive safety net on top of the
# existing merge-time check (which still runs regardless, unchanged) — it
# must never itself become a new false-FAIL source (mirrors the caution the
# dispatcher's own Step 10 comment states around this exact check).
#
# Hardcodes origin/main as the comparison base, deliberately: this mirrors
# gate-done.md's OWN base_commit computation (`git rev-parse origin/main`),
# which is what this entire submission convention already assumes — adding
# a configurable default-branch lookup here is out of scope for ga-pj5va.
# Recomputes the range from freshly-fetched refs rather than trusting the
# marker's own declared base_commit field (a self-declared value in an
# agent-authored marker) — same non-trusting posture as every other
# security/coherence-relevant read in this file.
if [ -n "$RIG_PATH" ] && [ -n "$BEAD_ID" ] && [ -n "$BRANCH" ]; then
  git -C "$RIG_PATH" fetch origin main "$BRANCH" --quiet 2>/dev/null || true
  _CBC_MAIN_SHA=$(git -C "$RIG_PATH" rev-parse "origin/main" 2>/dev/null || echo "")
  _CBC_BRANCH_SHA=$(git -C "$RIG_PATH" rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
  if [ -n "$_CBC_MAIN_SHA" ] && [ -n "$_CBC_BRANCH_SHA" ]; then
    _CBC_BASE=$(git -C "$RIG_PATH" merge-base "$_CBC_BRANCH_SHA" "$_CBC_MAIN_SHA" 2>/dev/null || echo "")
    if [ -n "$_CBC_BASE" ]; then
      _CBC_COUNT=$(git -C "$RIG_PATH" rev-list --count "${_CBC_BASE}..${_CBC_BRANCH_SHA}" 2>/dev/null || echo "")
      _CBC_MSGS=$(git -C "$RIG_PATH" log --format='%B' "${_CBC_BASE}..${_CBC_BRANCH_SHA}" 2>/dev/null || echo "")
      _CBC_VERDICT=$(branch_bead_commit_verdict "$_CBC_COUNT" "$_CBC_MSGS" "$BEAD_ID")
      if [ "$_CBC_VERDICT" = "no" ]; then
        err "  branch-content-coherence (ga-pj5va): $_CBC_COUNT unique commit(s) on $BRANCH vs origin/main never mention bead $BEAD_ID. Refusing at submission."
        set_gate_status "$MARKER_ID" "error"
        bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard rejected marker: branch-content-coherence check (ga-pj5va).
None of the $_CBC_COUNT commit(s) unique to $BRANCH (vs origin/main) mention bead $BEAD_ID.
If $BEAD_ID is a slice of a parent epic, citing the parent is fine — ADD a commit that also cites $BEAD_ID itself, don't cite only the parent:
  git commit --allow-empty -m \"chore($BEAD_ID): registra o vinculo\"
  git push origin $BRANCH
Then re-run /gate-done. Marker set to gate-status:error (fixable + re-submittable, not lost)." 2>/dev/null || true
        log "SUPPRESSED PUSH (wa-uthi non-terminal): branch-content-coherence pre-check failed for $MARKER_ID (gate-status:error)."
        exit 1
      fi
    fi
  fi
fi

# ── Step 5b-pre2 (ga-rstae): A/B — refuse when a new/changed selftest passes
# unmodified against the pre-fix base commit ────────────────────────────────
# Measured motivation (docs/gate-analysis/2026-08-12-gate-failure-taxonomy.md,
# 1524 gate-runs / 2026-07-23..2026-08-12): "teste nao pega o bug" is 22% of
# 443 classified blocking issues (family #5) — a builder writes a test that
# would pass regardless of whether the fix landed, and a human/reviewer only
# catches it later, if at all. Doctrine prose already asks for this (test-
# driven-development's own Iron Law, gate-done.md's pre-flight checklist) and
# STILL produces this rate (the taxonomy doc's own closing argument) — the
# next degree has to be MECHANICAL, not more prose.
#
# THIS IS AN A/B EXPERIMENT, not a blanket policy change (Athos, 2026-08-12,
# choosing HARD BLOCK for arm B over "warn only" — a softer intervention
# would not produce a measurable lift at this submission volume; see the
# power calculation in the bead body). Arm assignment (gate_ab_arm_for_bead,
# defined above the GATE_GUARD_LIB_ONLY cutoff) is a PURE function of the
# bead id alone — stable across resubmissions of the same bead by
# construction, so a bead that fails once and retries cannot hop arms.
#   Arm A: today's behavior, byte-for-byte. This block does not touch arm-A
#          submissions beyond the one cheap, non-IO hash call needed to log
#          which arm they landed in — no worktree, no checkout, no test run,
#          no added latency, no new log/label volume attributable to the
#          check itself. "A with a warning" is not A (bead's own words).
#   Arm B: may be REFUSED here when every new/changed *.selftest.sh in the
#          submission's range passes unmodified against the PRE-FIX base
#          commit — i.e. proves nothing about this branch's own diff.
#
# Scope (deliberate, not a placeholder): only *.selftest.sh files are
# measured. This repo's dominant, uniformly-runnable test convention for the
# files this guard protects (packs/town-deltas/assets/*.sh) is exactly this
# bash selftest pattern (see gate-guard-submission-time-coherence.selftest.sh
# and its siblings) — it runs inline with zero setup (no venv/npm install/
# network) and is what every existing check in this file already assumes.
# Other rigs' test conventions (pytest, jest, go test, ...) are NOT run by
# this check — a submission whose only new tests are those file types is
# indistinguishable, from here, from "no new test files": it lands in
# sem-teste-novo, never nao-consegui-medir, because this check never
# attempted to look for them. Extending coverage to another test convention
# is future work, tracked separately — not a defect of this bead.
#
# Same fail-open posture as Step 5b-pre immediately above: any uncertainty
# (RIG_PATH unresolved, fetch/rev-parse/merge-base failure, worktree
# creation failure, a file the guard can't extract, or a file that times
# out) routes to nao-consegui-medir, which never blocks. This check must
# never become a new false-FAIL source on top of the merge-time safety nets
# that already exist — a false block here costs a live, currently-working
# builder real minutes on a false alarm, which is exactly what family #5
# already costs them today, just moved earlier instead of removed.
#
# THIRD STATE IS MANDATORY HERE OF ALL PLACES: getting this wrong would be
# the exact defect class (family #2, "3o-estado colapsado", 30% of the same
# 443 issues) that this whole check exists downstream of. gate_base_test_
# verdict (above) treats ANY partial measurement (some files copied/run,
# some not) as nao-consegui-medir, never as passou-na-base — collapsing
# "couldn't tell" into "proves nothing, refuse" would be worse than not
# building this check at all.
#
# Every submission that reaches this point with arm=B gets a verdict label
# + a structured "AB-BASE-TEST" log line, REGARDLESS of whether it blocks —
# "sem-teste-novo" and "nao-consegui-medir" must be counted, not just
# "passou-na-base", or the A/B apuracao measures "who wrote a test" instead
# of "who wrote a test that proves something" (bead's own requirement).
if [ -n "$RIG_PATH" ] && [ -n "$BEAD_ID" ] && [ -n "$BRANCH" ]; then
  _ABT_ARM=$(gate_ab_arm_for_bead "$BEAD_ID")
  log "AB-ARM bead=$BEAD_ID arm=$_ABT_ARM marker=$MARKER_ID"

  if [ "$_ABT_ARM" = "B" ]; then
    _ABT_VERDICT="nao-consegui-medir"   # pessimistic default; only upgraded
                                         # below once a stage actually succeeds
    _ABT_DETECTED=0; _ABT_COPY_OK=0; _ABT_RAN=0; _ABT_FAILED=0
    _ABT_BASE=""; _ABT_TEST_FILES=""

    git -C "$RIG_PATH" fetch origin main "$BRANCH" --quiet 2>/dev/null || true
    _ABT_MAIN_SHA=$(git -C "$RIG_PATH" rev-parse "origin/main" 2>/dev/null || echo "")
    _ABT_BRANCH_SHA=$(git -C "$RIG_PATH" rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
    if [ -n "$_ABT_MAIN_SHA" ] && [ -n "$_ABT_BRANCH_SHA" ]; then
      _ABT_BASE=$(git -C "$RIG_PATH" merge-base "$_ABT_BRANCH_SHA" "$_ABT_MAIN_SHA" 2>/dev/null || echo "")
    fi

    if [ -n "$_ABT_BASE" ]; then
      _ABT_TEST_FILES=$(git -C "$RIG_PATH" diff --name-only --diff-filter=AM "${_ABT_BASE}..${_ABT_BRANCH_SHA}" -- '*.selftest.sh' 2>/dev/null || echo "")
      [ -n "$_ABT_TEST_FILES" ] && _ABT_DETECTED=$(printf '%s\n' "$_ABT_TEST_FILES" | grep -c .)

      if [ "$_ABT_DETECTED" -eq 0 ]; then
        _ABT_VERDICT="sem-teste-novo"        # explicit success: we DID determine there's nothing new
      elif [ "$_ABT_DETECTED" -gt 15 ]; then
        # Safety cap, not a silent truncation: >15 changed selftest files in
        # one submission is unprecedented in this codebase's actual usage —
        # don't spend an unbounded guard-sweep budget attempting it. Still
        # logged below via the shared AB-BASE-TEST line like any other
        # nao-consegui-medir case, so a cap hit is visible, not silent.
        _ABT_VERDICT="nao-consegui-medir"
      else
        _ABT_WT=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-basetest.XXXXXX" 2>/dev/null || echo "")
        if [ -n "$_ABT_WT" ] && git -C "$RIG_PATH" worktree add --detach --quiet "$_ABT_WT" "$_ABT_BASE" 2>/dev/null; then
          while IFS= read -r _abt_f; do
            [ -z "$_abt_f" ] && continue
            mkdir -p "$(dirname "$_ABT_WT/$_abt_f")" 2>/dev/null
            if git -C "$RIG_PATH" show "${_ABT_BRANCH_SHA}:$_abt_f" > "$_ABT_WT/$_abt_f" 2>/dev/null; then
              _ABT_COPY_OK=$((_ABT_COPY_OK + 1))
              if timeout 30 bash "$_ABT_WT/$_abt_f" >/dev/null 2>&1; then
                _ABT_RAN=$((_ABT_RAN + 1))
              else
                _abt_rc=$?
                # 124 = killed by timeout (coreutils convention): ambiguous by
                # construction (would it have failed, or just needed more time
                # in a throwaway worktree with no other context?) — do NOT
                # count as ran, so gate_base_test_verdict's ran!=detected check
                # routes this to nao-consegui-medir, never to a verdict this
                # check isn't actually sure of.
                if [ "$_abt_rc" != "124" ]; then
                  _ABT_RAN=$((_ABT_RAN + 1))
                  _ABT_FAILED=$((_ABT_FAILED + 1))
                fi
              fi
            fi
          done <<ABT_TEST_FILES_EOF
$_ABT_TEST_FILES
ABT_TEST_FILES_EOF
          git -C "$RIG_PATH" worktree remove --force "$_ABT_WT" 2>/dev/null || rm -rf "$_ABT_WT" 2>/dev/null
        else
          [ -n "$_ABT_WT" ] && rm -rf "$_ABT_WT" 2>/dev/null   # mktemp ok but worktree add itself failed
        fi
        _ABT_VERDICT=$(gate_base_test_verdict "$_ABT_DETECTED" "$_ABT_COPY_OK" "$_ABT_RAN" "$_ABT_FAILED")
      fi
    fi

    bd -C "$GC_CITY" label add "$MARKER_ID" "gate-ab:arm-b" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add "$MARKER_ID" "gate-ab-basetest:$_ABT_VERDICT" -q 2>/dev/null || true
    log "AB-BASE-TEST bead=$BEAD_ID arm=B verdict=$_ABT_VERDICT branch=$BRANCH base=$_ABT_BASE detected=$_ABT_DETECTED copy_ok=$_ABT_COPY_OK ran=$_ABT_RAN failed=$_ABT_FAILED"

    if [ "$_ABT_VERDICT" = "passou-na-base" ]; then
      err "  base-commit-test-check (ga-rstae, arm B): $_ABT_DETECTED new/changed selftest(s) on $BRANCH ALL pass unmodified against pre-fix base $_ABT_BASE — proves nothing about this branch's own diff. Refusing at submission."
      set_gate_status "$MARKER_ID" "error"
      bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard rejected marker: base-commit test check (ga-rstae, A/B experiment arm B).
$_ABT_DETECTED new/changed selftest file(s) on $BRANCH pass UNCHANGED when run against the pre-fix base commit ($_ABT_BASE) — meaning they don't actually exercise the bug/regression this branch claims to fix (test-driven-development's own Iron Law: a test that passes before your fix exists proves nothing).
Files: $(printf '%s' "$_ABT_TEST_FILES" | tr '\n' ' ')
Fix (this is the point of the check, not busywork): strengthen the test so it FAILS against base — i.e. it actually depends on your fix — then push again:
  git push origin $BRANCH
Then re-run /gate-done. Marker set to gate-status:error (fixable + re-submittable, not lost).
(You landed in arm B of a running A/B experiment measuring this check's effect on first-attempt gate pass rate — ga-rstae. Arm A submissions never see this block.)" 2>/dev/null || true
      log "SUPPRESSED PUSH (wa-uthi non-terminal): base-commit-test-check failed for $MARKER_ID (gate-status:error, arm B)."
      exit 1
    fi
  fi
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

# ── Step 6: Create gate-run CLAIM RECEIPT (ga-f1ngu) ──────────────────────────
# This bead is NOT a review run — no reviewer is ever spawned against it, the
# dispatcher creates its OWN, separate type:quality-gate-run bead (title
# "gate-run: ...", gate-status:running) once it actually begins reviewing. This
# one exists only so the claim is durably recorded before the marker is parked
# gate-status:queued below.
#
# gate-status:claimed (NOT :running) is deliberate — ga-f1ngu (2026-07-29):
# labeling this :running made it indistinguishable from a REAL run to every
# consumer that scans `type:quality-gate-run + gate-status:running` as "a
# review is in flight": Phase C's health sweep (quality-gate-dispatcher.sh),
# gate-recovery-watchdog.py's hung_run_verdict, AND the gate-congestion
# throttle checks in pilot-dispatcher.sh / auto-refino-dispatcher.sh (all
# inflated by every claim receipt sitting in queue). Worse, it let the
# dispatcher's OWN pre-creation duplicate-run guard (live_sibling_run_for_branch,
# ga-dupnv) miss this bead as a sibling — that guard matches candidates by the
# exact description substring "Autonomous gate run for X." which only the
# dispatcher's own template writes, so it never recognized this bead as
# competition and happily created a second, real run on top of it. (Making the
# text match instead would be WORSE, not better: the dispatcher would then
# yield to this receipt as a perpetually-"live" sibling forever, since nothing
# in the dispatcher's own lifecycle ever ages it out — the gate would never
# actually dispatch anything.) Do NOT relabel this back to :running without
# also either (a) giving it real verdict beads, or (b) re-auditing every one of
# those consumers.
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ⚠️ NÃO reintroduza --ephemeral aqui (Mayor, 07/08). No bd 1.1.0 ephemeral = INFRA,
# e INFRA some de `bd list` por padrão — o bead de run ficava invisível para todo
# monitor, watchdog e diagnóstico da cidade, que então reportavam "nenhum run ativo"
# com um run acontecendo. O bead de run é barato e o wisp-reaper já o recolhe; a
# economia de mantê-lo ephemeral não paga a cegueira que ela causa.
GATE_RUN_ID=$(bd -C "$GC_CITY" create \
  "quality-gate: $BRANCH ($BEAD_ID)" \
  -t chore \
  -l type:quality-gate-run \
  -l gate-status:claimed \
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

# ga-qblq4: add queued BEFORE removing claimed (same invariant as
# set_gate_status/ga-i0n83) — avoids a zero-gate-status window.
bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:queued"  -q 2>/dev/null || true
bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || true
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

# Notify the author (not Mayor) that their branch is queued for autonomous
# review. ga-409f4: NOTIFY_AUTHOR (branch-author-aware), not the
# bead-derived $AUTHOR.
if [ -n "$NOTIFY_AUTHOR" ]; then
  gc --city "$GC_CITY" session nudge "$NOTIFY_AUTHOR" \
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
