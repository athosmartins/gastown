#!/usr/bin/env bash
# pilot-dispatcher.selftest.sh — Regression harness for the Pilot dispatcher.
#
# Covers:
#   Scenarios 1-2 (ga-5ew): dependency-blocking filter — the Pilot must not
#     dispatch a story whose hard dependency is still open.
#   Scenario 3 (ga-6lum3): engine-window exclusion — a ready P0 bug labeled
#     needs:engine-window must NEVER be dispatched (engine source isn't on disk),
#     and the exclusion must appear in every dispatch query block.
#   Scenario 4 (ga-2azzj Defect A): TTL recovery measures claim age from the
#     pilot.dispatching_at STAMP, never updated_at — a fresh claim on an old
#     bead must not be released (the root of the ga-8nu8x double-dispatch).
#   Scenario 5 (ga-2azzj fix 1): a real dispatch confirms story:in-flight is
#     DURABLE before releasing pilot:dispatching; if it can't, it aborts and
#     leaves the claim on for TTL recovery rather than re-dispatching.
#
# Bug ga-5ew: the Pilot dispatched a story whose hard dependency was not yet
# merged. The fix (_filter_unblocked) drops candidates that bd reports as BLOCKED
# by unresolved (open) dependencies, BEFORE picking the top-priority dispatch.
#
# This harness drives the REAL pilot-dispatcher.sh in DRY_RUN against a THROWAWAY
# fixture city. It NEVER touches the live city: PILOT_CITY_OVERRIDE redirects the
# log/jsonl into a temp dir, and a PATH-shim replaces bd/gc/notify with fakes that
# return canned JSON. No live Dolt, no live gc, no live launchd — safe on a live host.
#
# Two candidate bugs are presented to the dispatcher every run:
#   tt-blkd  — priority P0 (HIGHEST), but BLOCKED by an unresolved dep
#   tt-unblk — priority P1 (lower),   UNBLOCKED
#
# Scenario 1 (dep enforced): blocked-set = {tt-blkd}. The fix MUST exclude the
#   higher-priority blocked bug and dispatch the lower-priority unblocked one.
#   Without the fix the dispatcher would pick tt-blkd (P0) — so this scenario
#   fails loudly if the regression returns.
# Scenario 2 (no over-filter): blocked-set = {}. Nothing is blocked, so the
#   dispatcher must pick the highest-priority bug (tt-blkd) and emit NO exclusion.
#
# Scenarios 6-7 (ga-do8jj): EXPLICIT-dep filter — the prose-style
#   `story.depends_on_beads` dependency that `bd blocked` cannot see:
#     Scenario 6 (held): tt-depblk (P0, oldest) declares an OPEN explicit dep →
#       must be held; tt-blkd dispatched instead.
#     Scenario 7 (auto-clear): the same dep is CLOSED → tt-depblk must NOT be
#       held and, being P0+oldest, is dispatched. Proves no over-blocking.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Throwaway workspace ───────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SHIMBIN="$WORK/bin"
FIXCITY="$WORK/city"
STATE="$WORK/state"
mkdir -p "$SHIMBIN" "$FIXCITY/.gc/logs" "$STATE"

# ── Fake bd ───────────────────────────────────────────────────────────────────
# Stateful shim. Dispatches on argv; tracks label state under $PILOT_TEST_STATE
# so read-after-write verifies (ga-2azzj durable in-flight) can be exercised.
# Case order matters — most-specific patterns first.
#   FAKE_BLOCKED_IDS       space-list of ids bd should report as blocked
#   FAKE_STALE_JSON        JSON array for the Step-0 stale-claim query (default [])
#   FAKE_BUGS_JSON         JSON array overriding the default 2-bug -t bug fixture
#   FAKE_INCLUDE_ENGWIN    =1 → inject a P0 needs:engine-window bug (ga-6lum3),
#                          dropped only when --exclude-label is actually passed
#   FAKE_SUPPRESS_INFLIGHT =1 → `label add story:in-flight` is silently dropped
#                          (simulates Dolt swallowing the write → never confirms)
#   FAKE_SLING_STATUS      status returned for `show <…sling…>` (default open)
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
args="$*"
STATE="${PILOT_TEST_STATE:-/tmp/pilot-selftest-state}"
mkdir -p "$STATE" 2>/dev/null || true
# token immediately following <want> in argv (controlled argv: no spaces in ids)
after() { local want="$1" prev=""; for a in $args; do [ "$prev" = "$want" ] && { echo "$a"; return; }; prev="$a"; done; }

case "$args" in
  *blocked*)
    ids="${FAKE_BLOCKED_IDS:-}"
    if [ -z "$ids" ]; then printf '[]'; exit 0; fi
    out="["; first=1
    for id in $ids; do
      [ "$first" -eq 1 ] || out="$out,"
      out="$out{\"id\":\"$id\",\"title\":\"blocked fixture\",\"status\":\"open\"}"
      first=0
    done
    printf '%s]' "$out"
    ;;
  *update*)
    # metadata writes (stamp / unset). Record stamps for optional assertions.
    case "$args" in
      *set-metadata*pilot.dispatching_at*) echo "stamp $(after update)" >> "$STATE/stamps.log" 2>/dev/null || true ;;
    esac
    : ;;
  *"label add"*story:in-flight*)
    id="$(after add)"
    [ "${FAKE_SUPPRESS_INFLIGHT:-0}" = "1" ] || touch "$STATE/$id.inflight" 2>/dev/null || true
    : ;;
  *"label add"*pilot:dispatching*)
    touch "$STATE/$(after add).dispatching" 2>/dev/null || true ; : ;;
  *"label remove"*pilot:dispatching*)
    id="$(after remove)"
    rm -f "$STATE/$id.dispatching" 2>/dev/null || true
    echo "released $id" >> "$STATE/releases.log" 2>/dev/null || true ; : ;;
  *"label add"*|*"label remove"*)
    : ;;          # other label ops (lane:*, pilot:dispatched, …) → no-op.
                  # NOTE: must match the 'label add/remove' SUBCOMMAND, not the
                  # '--exclude-label' flag that appears in the list queries below.
  *comments*)
    printf '[]' ;;                # gate-feedback lookup
  *show*)
    id="$(after show)"
    # Explicit-dep probe (ga-do8jj): _filter_explicit_deps calls `bd show <dep>
    # --json` and reads `.status`. The dep fixtures are named *base* with
    # open/closed in the name so a scenario can pick the dep's state. Route those
    # to a status-only object; everything else falls through to the label-state
    # path (ga-2azzj durable in-flight tracking) — the two must not shadow.
    case "$id" in
      *base*)
        case "$id" in
          *closed*) printf '{"id":"%s","status":"closed"}' "$id" ;;
          *)        printf '{"id":"%s","status":"open"}'   "$id" ;;
        esac ;;
      *)
        lbls=""
        [ -f "$STATE/$id.inflight" ]    && lbls="\"story:in-flight\""
        [ -f "$STATE/$id.dispatching" ] && lbls="${lbls:+$lbls,}\"pilot:dispatching\""
        st="open"
        case "$id" in *sling*) st="${FAKE_SLING_STATUS:-open}" ;; esac
        printf '{"id":"%s","status":"%s","labels":[%s]}' "$id" "$st" "$lbls" ;;
    esac ;;
  *story:approved*pilot:dispatching*)
    printf '%s' "${FAKE_STALE_JSON:-[]}" ;;   # Step-0 stale-claim query
  *--all*)
    printf '[]' ;;                            # in-flight count → lanes free
  *"-t bug"*)
    if [ -n "${FAKE_BUGS_JSON:-}" ]; then
      # ga-2azzj: explicit fixture injection (used by the non-dry in-flight test).
      printf '%s' "$FAKE_BUGS_JSON"
    elif [ "${FAKE_INCLUDE_ENGWIN:-0}" = "1" ]; then
      # Engine-window scenario (ga-6lum3): tt-engwin is a P0 engine-fork bug that
      # MUST NOT be dispatched. This fake bd honors the exclusion ONLY when the
      # dispatcher actually passes --exclude-label "needs:engine-window" — so the
      # bug fixture leaks in (and gets picked, being P0) if the fix is absent.
      case "$args" in
        *"needs:engine-window"*)
          cat <<'JSON'
[
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
          ;;
        *)
          cat <<'JSON'
[
  {"id":"tt-engwin","title":"Engine-fork bug fixture","priority":0,"issue_type":"bug","status":"open","labels":["needs:engine-window"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
          ;;
      esac
    else
      # Two open, unassigned bug candidates. tt-blkd is HIGHER priority (P0).
      # When FAKE_DEP_BEAD is set, ALSO emit tt-depblk: P0 AND created earlier than
      # tt-blkd (so it WOULD win the priority tie-break absent the filter),
      # declaring an explicit dep on FAKE_DEP_BEAD via story.depends_on_beads.
      dep_bead="${FAKE_DEP_BEAD:-}"
      prefix=""
      if [ -n "$dep_bead" ]; then
        prefix="{\"id\":\"tt-depblk\",\"title\":\"Explicit-dep bug fixture\",\"priority\":0,\"issue_type\":\"bug\",\"status\":\"open\",\"labels\":[],\"assignee\":null,\"created_at\":\"2026-05-01T00:00:00Z\",\"metadata\":{\"story.depends_on_beads\":\"$dep_bead\"}},"
      fi
      cat <<JSON
[
  ${prefix}
  {"id":"tt-blkd","title":"Blocked bug fixture","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-unblk","title":"Unblocked bug fixture","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
    fi ;;
  *)
    printf '[]' ;;                            # tech-debt, tier-2 features, etc.
esac
exit 0
SHIM
chmod +x "$SHIMBIN/bd"

# ── Fake gc / notify ──────────────────────────────────────────────────────────
# DRY scenarios never reach sling; the non-DRY durable-in-flight scenario does.
cat > "$SHIMBIN/gc" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"rig list"*)      printf '{"rigs":[]}' ;;     # rig fallback → empty
  *sling*)           printf '{"bead_id":"tt-sling-1"}' ;;  # builder task bead
  *"session list"*)  : ;;                         # no live builder sessions
  *"session nudge"*) : ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/gc"

cat > "$SHIMBIN/notify" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$SHIMBIN/notify"

# ── Runner ────────────────────────────────────────────────────────────────────
reset_state() { rm -rf "$STATE"; mkdir -p "$STATE"; }

# Runs the real dispatcher in DRY_RUN with the shims on PATH, returns the log.
run_dispatch() { # $1=FAKE_BLOCKED_IDS  $2=FAKE_INCLUDE_ENGWIN(0|1)  $3=FAKE_DEP_BEAD (optional)
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    FAKE_BLOCKED_IDS="$1" \
    FAKE_INCLUDE_ENGWIN="${2:-0}" \
    FAKE_DEP_BEAD="${3:-}" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs Step-0 TTL recovery in DRY_RUN with an injected stale-claim fixture.
run_step0() { # FAKE_STALE_JSON
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    FAKE_STALE_JSON="$1" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs a REAL (non-dry) dispatch of a single bug candidate through finalization.
# Arg 1: FAKE_SUPPRESS_INFLIGHT (0|1). Sleep is zeroed so the retry loop is fast.
run_real_dispatch() { # FAKE_SUPPRESS_INFLIGHT
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT="$1" \
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "pilot-dispatcher.selftest — dependency-blocking filter (ga-5ew)"

# ── Scenario 1: blocked dep is enforced ───────────────────────────────────────
echo "Scenario 1: tt-blkd BLOCKED — must skip it and dispatch tt-unblk"
LOG1="$(run_dispatch "tt-blkd")"

if echo "$LOG1" | grep -q "excluded 1 blocked candidate"; then
  ok "logged exclusion of the blocked candidate"
else
  bad "did NOT log exclusion (expected 'excluded 1 blocked candidate')"
fi

if echo "$LOG1" | grep -q "Lane picks — small: tt-unblk"; then
  ok "dispatched the UNBLOCKED bug (tt-unblk)"
else
  bad "did not pick tt-unblk as the small-lane dispatch"
fi

if echo "$LOG1" | grep -q "Lane picks — small: tt-blkd"; then
  bad "REGRESSION: dispatched the blocked bug (tt-blkd)"
else
  ok "did NOT dispatch the blocked bug"
fi

# ── Scenario 2: nothing blocked — no over-filtering ───────────────────────────
echo "Scenario 2: nothing blocked — must pick highest priority (tt-blkd) and not exclude"
LOG2="$(run_dispatch "")"

if echo "$LOG2" | grep -q "excluded .* blocked candidate"; then
  bad "over-filtered: emitted an exclusion when nothing was blocked"
else
  ok "no spurious exclusion when blocked-set is empty"
fi

if echo "$LOG2" | grep -q "Lane picks — small: tt-blkd"; then
  ok "picked the highest-priority bug (tt-blkd) when unblocked"
else
  bad "did not pick the highest-priority bug when nothing was blocked"
fi

# ── Scenario 3: engine-fork bugs are excluded from dispatch (ga-6lum3) ─────────
# A ready P0 bug labeled needs:engine-window must NEVER be dispatched (it can't be
# built — engine source isn't on disk). The fake bd only drops it when the
# dispatcher passes --exclude-label "needs:engine-window", so this fails loudly if
# any query block loses the exclusion.
echo "Scenario 3: needs:engine-window bug (P0) must be excluded, keeper (P1) dispatched"
LOG3="$(run_dispatch "" 1)"

if echo "$LOG3" | grep -q "Lane picks — small: tt-engwin"; then
  bad "LEAK: dispatched the engine-window bug (tt-engwin)"
else
  ok "did NOT dispatch the engine-window bug"
fi

if echo "$LOG3" | grep -q "Lane picks — small: tt-keep"; then
  ok "dispatched the normal keeper bug (tt-keep) instead"
else
  bad "did not dispatch the keeper bug (tt-keep)"
fi

# ── Structural: every dispatch query block excludes needs:engine-window ────────
# Belt to the behavioral test: the exclusion must appear in EVERY block that
# already excludes gate:needs-human (Tier 1 + Tier 2, HQ + rig paths).
echo "Structural: needs:engine-window paired with gate:needs-human in all query blocks"
GNH=$(grep -c 'exclude-label "gate:needs-human"' "$DISPATCHER")
ENG=$(grep -c 'exclude-label "needs:engine-window"' "$DISPATCHER")
if [ "$GNH" -gt 0 ] && [ "$ENG" -eq "$GNH" ]; then
  ok "needs:engine-window present in all $GNH query block(s)"
else
  bad "exclusion count mismatch: gate:needs-human=$GNH needs:engine-window=$ENG"
fi

# ── Scenario 4: stamp-based TTL recovery (ga-2azzj Defect A) ───────────────────
# Step-0 must measure claim age from the pilot.dispatching_at stamp, NOT
# updated_at. A FRESH claim on an OLD bead must NOT be released.
echo "Scenario 4: TTL recovery uses pilot.dispatching_at stamp, not updated_at"
NOW="$(date +%s)"
OLD_STAMP="$((NOW - 7200))"   # 2h old   → stale (TTL default 30m)
FRESH_STAMP="$((NOW - 60))"   # 1m young → fresh

# 4a: old stamp → release.
STALE_OLD='[{"id":"tt-stale","title":"x","status":"open","updated_at":"2020-01-01T00:00:00Z","labels":["story:approved","pilot:dispatching"],"metadata":{"pilot.dispatching_at":"'"$OLD_STAMP"'"}}]'
LOG4A="$(run_step0 "$STALE_OLD")"
if echo "$LOG4A" | grep -q "Releasing stale pilot:dispatching claim on tt-stale"; then
  ok "old stamp (age>TTL) → released the stale claim"
else
  bad "old stamp should have been released"
fi

# 4b: fresh stamp but ANCIENT updated_at → must KEEP (the actual Defect A repro).
STALE_FRESH='[{"id":"tt-fresh","title":"x","status":"open","updated_at":"2020-01-01T00:00:00Z","labels":["story:approved","pilot:dispatching"],"metadata":{"pilot.dispatching_at":"'"$FRESH_STAMP"'"}}]'
LOG4B="$(run_step0 "$STALE_FRESH")"
if echo "$LOG4B" | grep -q "claim is fresh.*tt-fresh\|tt-fresh.*claim is fresh"; then
  ok "fresh stamp + ancient updated_at → KEPT (Defect A fixed)"
else
  bad "fresh claim was not kept (Defect A regression)"
fi
if echo "$LOG4B" | grep -q "Releasing stale pilot:dispatching claim on tt-fresh"; then
  bad "REGRESSION: released a FRESH claim (the ga-8nu8x double-dispatch bug)"
else
  ok "did NOT release the fresh claim"
fi

# 4c: no stamp (legacy) → must stamp now, NOT release.
STALE_NOSTAMP='[{"id":"tt-legacy","title":"x","status":"open","updated_at":"2020-01-01T00:00:00Z","labels":["story:approved","pilot:dispatching"],"metadata":{}}]'
LOG4C="$(run_step0 "$STALE_NOSTAMP")"
if echo "$LOG4C" | grep -q "no pilot.dispatching_at stamp"; then
  ok "legacy claim with no stamp → stamped now, not released"
else
  bad "legacy claim path did not trigger stamp-now behavior"
fi
if echo "$LOG4C" | grep -q "Releasing stale pilot:dispatching claim on tt-legacy"; then
  bad "REGRESSION: released an un-stamped legacy claim (would re-dispatch fresh work)"
else
  ok "did NOT release the un-stamped legacy claim"
fi

# ── Scenario 5: durable story:in-flight before claim release (ga-2azzj fix 1) ──
# The load-bearing fix. A real (non-dry) dispatch must confirm story:in-flight
# BEFORE removing pilot:dispatching. If in-flight can't be confirmed, it must
# abort and LEAVE pilot:dispatching on (so TTL recovery owns it) — never release.
echo "Scenario 5: durable story:in-flight gates the claim release (non-dry)"

# 5a: happy path — in-flight confirms, claim released after.
LOG5A="$(run_real_dispatch 0)"
if [ -f "$STATE/tt-flight.inflight" ]; then
  ok "story:in-flight was set"
else
  bad "story:in-flight was never set on the happy path"
fi
if grep -q "released tt-flight" "$STATE/releases.log" 2>/dev/null; then
  ok "pilot:dispatching released AFTER in-flight confirmed"
else
  bad "claim was not released on the happy path"
fi
if echo "$LOG5A" | grep -q "DURABLE-INFLIGHT FAILED"; then
  bad "happy path wrongly reported DURABLE-INFLIGHT FAILED"
else
  ok "no false in-flight failure on the happy path"
fi

# 5b: failure injection — in-flight write swallowed → must NOT release the claim.
LOG5B="$(run_real_dispatch 1)"
if echo "$LOG5B" | grep -q "DURABLE-INFLIGHT FAILED on tt-flight"; then
  ok "unconfirmed in-flight → aborted hard with a loud error"
else
  bad "did not detect/announce the unconfirmed in-flight write"
fi
if grep -q "released tt-flight" "$STATE/releases.log" 2>/dev/null; then
  bad "REGRESSION: released the claim despite unconfirmed in-flight (re-dispatchable!)"
else
  ok "left pilot:dispatching ON for TTL recovery (no premature release)"
fi

# ── Scenario 6: explicit prose-style dep is enforced (ga-do8jj) ───────────────
# tt-depblk is P0 AND oldest (would win the tie-break), but declares an OPEN
# explicit dep via story.depends_on_beads → must be HELD; tt-blkd (P0) dispatched.
# This is the exact gap behind ga-do8jj: ga-2e605 dispatched before its base
# ga-e72kf landed because the dep was prose-only, invisible to `bd blocked`.
echo "Scenario 6: tt-depblk has an OPEN explicit dep — must hold it and dispatch tt-blkd"
LOG6="$(run_dispatch "" 0 "tt-openbase")"

if echo "$LOG6" | grep -q "holding tt-depblk — explicit dep tt-openbase"; then
  ok "logged hold on the explicit-dep candidate"
else
  bad "did NOT log hold (expected 'holding tt-depblk — explicit dep tt-openbase')"
fi

if echo "$LOG6" | grep -q "Lane picks — small: tt-blkd"; then
  ok "dispatched tt-blkd (explicit-dep candidate correctly held back)"
else
  bad "did not pick tt-blkd while tt-depblk was held"
fi

if echo "$LOG6" | grep -q "Lane picks — small: tt-depblk"; then
  bad "REGRESSION: dispatched a candidate with an open explicit dep (tt-depblk)"
else
  ok "did NOT dispatch the explicit-dep candidate"
fi

# ── Scenario 7: explicit dep is CLOSED — no over-filtering (auto-clear) ────────
# Same candidate, but its explicit dep is closed → it must NOT be held, and
# being P0+oldest it now wins the dispatch. Proves the filter auto-clears once
# the dependency lands and does not over-block.
echo "Scenario 7: tt-depblk's explicit dep is CLOSED — must NOT hold, picks tt-depblk"
LOG7="$(run_dispatch "" 0 "tt-closedbase")"

if echo "$LOG7" | grep -q "holding tt-depblk"; then
  bad "over-filtered: held a candidate whose explicit dep is already closed"
else
  ok "no spurious hold when the explicit dep is closed"
fi

if echo "$LOG7" | grep -q "Lane picks — small: tt-depblk"; then
  ok "dispatched tt-depblk once its explicit dep was satisfied (auto-clear)"
else
  bad "did not pick tt-depblk after its explicit dep closed"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
