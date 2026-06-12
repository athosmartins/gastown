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
# Scenarios 7-8 (ga-do8jj): EXPLICIT-dep filter — the prose-style
#   `story.depends_on_beads` dependency that `bd blocked` cannot see:
#     Scenario 7 (held): tt-depblk (P0, oldest) declares an OPEN explicit dep →
#       must be held; tt-blkd dispatched instead.
#     Scenario 8 (auto-clear): the same dep is CLOSED → tt-depblk must NOT be
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
        # ga-e5yw2: the dead-worker correction resolves a sling task's assignee.
        # FAKE_SLING_ASSIGNEES is a JSON map {"<slingid>":"<assignee>", …}.
        asg=""
        if [ -n "${FAKE_SLING_ASSIGNEES:-}" ]; then
          asg=$(printf '%s' "$FAKE_SLING_ASSIGNEES" | jq -r --arg id "$id" '.[$id] // ""' 2>/dev/null || echo "")
        fi
        printf '{"id":"%s","status":"%s","assignee":"%s","labels":[%s]}' "$id" "$st" "$asg" "$lbls" ;;
    esac ;;
  *story:approved*pilot:dispatching*)
    printf '%s' "${FAKE_STALE_JSON:-[]}" ;;   # Step-0 stale-claim query
  *--all*)
    # in-flight count → lanes free by default. ga-rk5va: a scenario may inject
    # FAKE_INFLIGHT_JSON to exercise the stale-occupant slot correction.
    printf '%s' "${FAKE_INFLIGHT_JSON:-[]}" ;;
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
  *sling*)
    # ga-eu8vr: the live gc binary ALWAYS emits this benign warning on stderr —
    # on success AND failure alike. Mirror it so the test proves the dispatcher
    # never treats it as the failure cause. Failure injection seams:
    #   FAKE_SLING_FAIL_TIMES=N  → first N attempts fail (empty bead_id), then succeed
    #   FAKE_SLING_ALWAYS_FAIL=1 → every attempt fails
    # The REAL error rides on STDOUT (structured JSON) with a non-zero exit, exactly
    # like the live binary's `sling: Store is required` path.
    printf 'WARN native_store_unavailable gate=version_compat reason="bd/beads version compatibility could not be confirmed"\n' >&2
    _st="${PILOT_TEST_STATE:-/tmp/pilot-selftest-state}"
    _cnt=$(cat "$_st/sling_n" 2>/dev/null || echo 0); _cnt=$((_cnt + 1)); echo "$_cnt" > "$_st/sling_n"
    if [ "${FAKE_SLING_ALWAYS_FAIL:-0}" = "1" ] || [ "$_cnt" -le "${FAKE_SLING_FAIL_TIMES:-0}" ]; then
      printf '{"schema_version":"1","ok":false,"error":{"code":"native_store_unavailable","message":"sling: Store is required"}}'
      exit 1
    fi
    printf '{"bead_id":"tt-sling-1"}'
    ;;
  *"session list"*)  # ga-e5yw2 roster seam. Brace-in-default `${x:-{...}}` mis-parses
                     # (the inner } closes the expansion early) → use an explicit if.
                     if [ -n "${FAKE_SESSIONS_JSON:-}" ]; then printf '%s' "$FAKE_SESSIONS_JSON"; else printf '{"sessions":[]}'; fi ;;
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

# Runs a REAL (non-dry) dispatch exercising the sling RETRY path (ga-eu8vr).
# Sleeps are zeroed so the retry loop is instant. The fake gc sling fails per the
# injected seams while ALWAYS emitting the benign version_compat warning on stderr.
run_sling_retry() { # $1=FAKE_SLING_FAIL_TIMES  $2=FAKE_SLING_ALWAYS_FAIL(0|1)
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_SLING_RETRIES=3 \
    PILOT_SLING_SLEEP=0 \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT=0 \
    FAKE_SLING_FAIL_TIMES="${1:-0}" \
    FAKE_SLING_ALWAYS_FAIL="${2:-0}" \
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs a DRY dispatch with the ga-rk5va dispatch-to-capacity feature exercised:
# Dolt health is forced via the override seams so the gate is deterministic (no
# live `gc dolt health` / `ps`). Default fixture = the two small bug candidates.
#   $1 = PILOT_DOLT_CPU_OVERRIDE   (<=200 healthy, >200 saturated)
#   $2 = FAKE_INFLIGHT_JSON        (in-flight beads for the stale-occupant test)
#   $3 = DISPATCH_TO_CAPACITY      (default 1)
#   $4 = FAKE_BUGS_JSON            (override the default 2-bug fixture)
#   $5 = FAKE_SESSIONS_JSON        (ga-e5yw2 live-session roster; default empty)
#   $6 = FAKE_SLING_ASSIGNEES      (ga-e5yw2 sling→assignee map; default empty)
run_capacity() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS=100 \
    PILOT_DOLT_CPU_OVERRIDE="${1:-10}" \
    FAKE_INFLIGHT_JSON="${2:-[]}" \
    DISPATCH_TO_CAPACITY="${3:-1}" \
    FAKE_BUGS_JSON="${4:-}" \
    FAKE_SESSIONS_JSON="${5:-}" \
    FAKE_SLING_ASSIGNEES="${6:-}" \
    FAKE_BLOCKED_IDS="" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Five small, unblocked bug candidates — the exact AC fixture ("5 free small slots
# + 5 ready candidates dispatches all 5").
FIVE_SMALL_BUGS='[
  {"id":"tt-c1","title":"cap bug 1","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-c2","title":"cap bug 2","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}},
  {"id":"tt-c3","title":"cap bug 3","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:03Z","metadata":{}},
  {"id":"tt-c4","title":"cap bug 4","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:04Z","metadata":{}},
  {"id":"tt-c5","title":"cap bug 5","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:05Z","metadata":{}}
]'

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

# ── Scenario 6: source bead never carries dog routing (ga-ms1jm) ──────────────
# Double-dispatch regression: an older dispatcher slung the SOURCE bead by id,
# stamping gc.routed_to=<dog-pool> onto it. While story:in-flight (open +
# unassigned) the dog pool's engine ready-query — which does NOT exclude
# story:in-flight — re-claimed it, spawning a second builder on already-fixed
# work and pinning dog slots. ga-zzrts hardened the PILOT side (won't
# re-dispatch); this guards the DOG side: the dispatcher slings a SEPARATE task
# bead by title and defensively unsets gc.routed_to on the source bead at the
# dispatch transition. Structural assertions (grep the real dispatcher source —
# no live Dolt needed):
echo "Scenario 6: source bead never carries gc.routed_to (ga-ms1jm double-dispatch)"

if grep -q -- '--unset-metadata gc.routed_to' "$DISPATCHER"; then
  ok "transition defensively unsets gc.routed_to on the source bead"
else
  bad "REGRESSION: source bead not stripped of gc.routed_to (--unset-metadata missing)"
fi

if grep -qE 'sling[[:space:]]+"\$BUILDER_TARGET"[[:space:]]+"\$STORY_ID"' "$DISPATCHER"; then
  bad "REGRESSION: dispatcher slings the SOURCE bead by id (would stamp gc.routed_to on it)"
else
  ok "dispatcher does not sling the source bead by id"
fi

# ── Scenario 7: explicit prose-style dep is enforced (ga-do8jj) ───────────────
# tt-depblk is P0 AND oldest (would win the tie-break), but declares an OPEN
# explicit dep via story.depends_on_beads → must be HELD; tt-blkd (P0) dispatched.
# This is the exact gap behind ga-do8jj: ga-2e605 dispatched before its base
# ga-e72kf landed because the dep was prose-only, invisible to `bd blocked`.
echo "Scenario 7: tt-depblk has an OPEN explicit dep — must hold it and dispatch tt-blkd"
LOG7="$(run_dispatch "" 0 "tt-openbase")"

if echo "$LOG7" | grep -q "holding tt-depblk — explicit dep tt-openbase"; then
  ok "logged hold on the explicit-dep candidate"
else
  bad "did NOT log hold (expected 'holding tt-depblk — explicit dep tt-openbase')"
fi

if echo "$LOG7" | grep -q "Lane picks — small: tt-blkd"; then
  ok "dispatched tt-blkd (explicit-dep candidate correctly held back)"
else
  bad "did not pick tt-blkd while tt-depblk was held"
fi

if echo "$LOG7" | grep -q "Lane picks — small: tt-depblk"; then
  bad "REGRESSION: dispatched a candidate with an open explicit dep (tt-depblk)"
else
  ok "did NOT dispatch the explicit-dep candidate"
fi

# ── Scenario 8: explicit dep is CLOSED — no over-filtering (auto-clear) ────────
# Same candidate, but its explicit dep is closed → it must NOT be held, and
# being P0+oldest it now wins the dispatch. Proves the filter auto-clears once
# the dependency lands and does not over-block.
echo "Scenario 8: tt-depblk's explicit dep is CLOSED — must NOT hold, picks tt-depblk"
LOG8="$(run_dispatch "" 0 "tt-closedbase")"

if echo "$LOG8" | grep -q "holding tt-depblk"; then
  bad "over-filtered: held a candidate whose explicit dep is already closed"
else
  ok "no spurious hold when the explicit dep is closed"
fi

if echo "$LOG8" | grep -q "Lane picks — small: tt-depblk"; then
  ok "dispatched tt-depblk once its explicit dep was satisfied (auto-clear)"
else
  bad "did not pick tt-depblk after its explicit dep closed"
fi

# ── Scenario 9: dispatch-to-capacity fills ALL free slots in one sweep (ga-rk5va)
# Two small bug candidates (tt-blkd, tt-unblk), 5 free small slots, Dolt healthy →
# BOTH must dispatch in a single sweep (the user's "máxima lotação"), not one.
echo "Scenario 9: healthy Dolt + 2 candidates + free slots → dispatch BOTH in one sweep"
LOG9="$(run_capacity 10)"

if echo "$LOG9" | grep -q "Dolt health OK"; then
  ok "Dolt probed healthy via override seam (dispatch-to-capacity armed)"
else
  bad "did not arm dispatch-to-capacity on a healthy Dolt"
fi

if echo "$LOG9" | grep -q "Lane small: dispatched 2 this sweep"; then
  ok "dispatched BOTH small candidates in ONE sweep (dispatch-to-capacity)"
else
  bad "did NOT fill both slots in one sweep (expected 'Lane small: dispatched 2')"
fi

# ── Scenario 9b: the literal AC — 5 free small slots + 5 ready candidates → 5 ───
echo "Scenario 9b: 5 free slots + 5 candidates → dispatch ALL 5 in one sweep, never more"
LOG9B="$(run_capacity 10 "[]" 1 "$FIVE_SMALL_BUGS")"
if echo "$LOG9B" | grep -q "Lane small: dispatched 5 this sweep"; then
  ok "filled all 5 small slots in a single sweep (AC satisfied)"
else
  bad "did not dispatch all 5 (expected 'Lane small: dispatched 5')"
fi
if echo "$LOG9B" | grep -qE "Lane small: dispatched ([6-9]|[1-9][0-9]+) this sweep"; then
  bad "REGRESSION: exceeded the small-lane cap of 5"
else
  ok "never exceeded the small-lane cap (MAX_SMALL=5)"
fi

# ── Scenario 10: Dolt saturation throttles to one dispatch per lane ────────────
# Same 2 candidates + free slots, but CPU override > ceiling → SATURATED at start.
# Must throttle to the legacy single dispatch (never add load to a hot data plane).
echo "Scenario 10: saturated Dolt → throttle to 1 dispatch/lane (constraint a backoff)"
LOG10="$(run_capacity 300)"

if echo "$LOG10" | grep -q "Dolt SATURATED at sweep start"; then
  ok "detected Dolt saturation at sweep start"
else
  bad "did not detect saturation (CPU override 300 > 200 ceiling)"
fi

if echo "$LOG10" | grep -q "Lane small: dispatched 1 this sweep"; then
  ok "throttled to a SINGLE dispatch under saturation (legacy-safe)"
else
  bad "did not throttle to 1 under saturation (capacity loop ignored the backoff)"
fi

if echo "$LOG10" | grep -q "Lane small: dispatched 2 this sweep"; then
  bad "REGRESSION: filled both slots while Dolt was saturated (added load to a hot server)"
else
  ok "did NOT fill multiple slots under saturation"
fi

# ── Scenario 10b: feature switch off → legacy single-pick even when healthy ────
echo "Scenario 10b: DISPATCH_TO_CAPACITY=0 → single dispatch even on a healthy Dolt"
LOG10B="$(run_capacity 10 "[]" 0)"
if echo "$LOG10B" | grep -q "Lane small: dispatched 1 this sweep"; then
  ok "feature-off honored (legacy one-per-lane)"
else
  bad "DISPATCH_TO_CAPACITY=0 did not fall back to single dispatch"
fi

# ── Scenario 11: stale in-flight bead is NOT counted as a live slot occupant ───
# One fresh + one stale (>2h untouched) in-flight bead. The stale one must be
# dropped from the slot count (16h-stuck-session bug) — freeing its slot — while
# the fresh one still occupies. It must NOT be re-dispatched (just not counted).
echo "Scenario 11: stale in-flight (>2h) freed from slot count (constraint c)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STALE_ISO="$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
INFLIGHT="[{\"id\":\"if-fresh\",\"labels\":[\"story:in-flight\"],\"updated_at\":\"$NOW_ISO\"},{\"id\":\"if-stale\",\"labels\":[\"story:in-flight\"],\"updated_at\":\"$STALE_ISO\"}]"
LOG11="$(run_capacity 10 "$INFLIGHT")"

if echo "$LOG11" | grep -q "Stale in-flight: 1 bead"; then
  ok "detected the stale in-flight occupant"
else
  bad "did not detect the stale in-flight occupant"
fi

if echo "$LOG11" | grep -q "live=1 (raw=2 stale=1 age=1 dead=0)"; then
  ok "slot count corrected: 1 live occupant, 1 stale freed (age)"
else
  bad "slot count not corrected (expected 'live=1 (raw=2 stale=1 age=1 dead=0)')"
fi

if echo "$LOG11" | grep -q "Stale ids: if-stale"; then
  ok "named the stale bead (if-stale)"
else
  bad "did not name the stale bead id"
fi

if echo "$LOG11" | grep -q "Stale ids:.*if-fresh"; then
  bad "REGRESSION: treated the FRESH bead as stale (would over-free slots)"
else
  ok "fresh bead correctly kept as a live occupant"
fi

# ── Scenario 12: dead-worker in-flight bead is NOT counted as a live slot ─────
# (ga-e5yw2) Three FRESH in-flight beads (none age-stale) whose builder sessions
# differ: one's sling-task assignee is a DEAD session (absent from the roster),
# one's is LIVE, one's sling-task has NO assignee. Only the dead-worker bead must
# be freed from the slot count; the live and the unresolved (no-assignee) ones
# must be kept (fail-safe: never over-free). Proves the raw=N-vs-real over-count
# that throttled dispatch with a free lane is corrected.
echo "Scenario 12: dead-worker in-flight freed from slot count (ga-e5yw2)"
NOW_ISO12="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INFLIGHT12="[\
{\"id\":\"if-dead\",\"labels\":[\"story:in-flight\"],\"updated_at\":\"$NOW_ISO12\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-dead\"}},\
{\"id\":\"if-live\",\"labels\":[\"story:in-flight\"],\"updated_at\":\"$NOW_ISO12\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-live\"}},\
{\"id\":\"if-noassg\",\"labels\":[\"story:in-flight\"],\"updated_at\":\"$NOW_ISO12\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-none\"}}]"
SESSIONS12='{"sessions":[{"session_name":"live-sess","template":"gastown.dog","closed":false}]}'
SLINGMAP12='{"tt-sling-dead":"dead-sess","tt-sling-live":"live-sess","tt-sling-none":""}'
LOG12="$(run_capacity 10 "$INFLIGHT12" 1 "" "$SESSIONS12" "$SLINGMAP12")"

if echo "$LOG12" | grep -q "live=2 (raw=3 stale=1 age=0 dead=1)"; then
  ok "slot count corrected: 2 live occupants, 1 dead-worker freed"
else
  bad "slot count not corrected (expected 'live=2 (raw=3 stale=1 age=0 dead=1)')"
fi

if echo "$LOG12" | grep -q "Dead-worker in-flight: 1 bead"; then
  ok "detected the dead-worker in-flight occupant"
else
  bad "did not detect the dead-worker in-flight occupant"
fi

if echo "$LOG12" | grep -q "Dead ids: if-dead"; then
  ok "named the dead-worker bead (if-dead)"
else
  bad "did not name the dead-worker bead id"
fi

if echo "$LOG12" | grep -qE "Dead ids:.*(if-live|if-noassg)"; then
  bad "REGRESSION: freed a LIVE or unresolved bead (would over-dispatch)"
else
  ok "live + no-assignee beads correctly kept as live occupants"
fi

# ── Scenario 12b: roster unreadable/empty → dead-worker check DISABLED ─────────
# (ga-e5yw2 fail-safe) Same in-flight set, but the session roster comes back
# EMPTY (a failed/racy `session list`). The dead-worker check must switch OFF
# entirely — every occupant kept — rather than free all three and over-dispatch.
echo "Scenario 12b: empty roster disables dead-worker check (fail-safe)"
LOG12B="$(run_capacity 10 "$INFLIGHT12" 1 "" "" "$SLINGMAP12")"

if echo "$LOG12B" | grep -q "live=3 (raw=3 stale=0 age=0 dead=0)"; then
  ok "empty roster → all 3 kept, zero freed (no over-dispatch)"
else
  bad "empty roster did not fail safe (expected 'live=3 (raw=3 stale=0 age=0 dead=0)')"
fi

if echo "$LOG12B" | grep -q "Dead-worker in-flight:"; then
  bad "REGRESSION: ran dead-worker check against an empty roster"
else
  ok "dead-worker check correctly suppressed on empty roster"
fi

# ── Scenario 13: resilient sling — version_compat warning is NOT a failure ────
# (ga-eu8vr) The live gc binary emits a CONSTANT benign "native_store_unavailable
# gate=version_compat" warning on stderr for EVERY sling (success and failure
# alike — verified 20/20). The prior dispatcher made ONE sling attempt and, on an
# empty bead_id, logged only STDERR (the benign warning) and permanently aborted —
# stalling a sole-candidate P1 backlog for ~2.5h while the SAME sling op succeeded
# moments later. The fix RETRIES the sling and attributes failures to the REAL
# stdout error, probing store reachability so the warning is non-blocking.
echo "Scenario 13a: sling retries through transient failures then succeeds (ga-eu8vr)"
LOG13A="$(run_sling_retry 2 0)"   # fail attempts 1-2, succeed on attempt 3
if [ -f "$STATE/tt-flight.inflight" ]; then
  ok "transient sling failures retried → dispatch reached story:in-flight (no false abort)"
else
  bad "sling did not recover via retry (tt-flight never reached in-flight)"
fi
if echo "$LOG13A" | grep -qE "attempt 1/3|attempt 2/3"; then
  ok "retry path was exercised (logged attempt N/3)"
else
  bad "no retry attempt was logged"
fi

echo "Scenario 13b: persistent sling failure attributed to REAL error, not the warning (ga-eu8vr)"
LOG13B="$(run_sling_retry 0 1)"   # always fail
if echo "$LOG13B" | grep -q "store ACCESSIBLE, transient sling-write failure"; then
  ok "failure correctly degraded: store-accessible transient, claim released for retry"
else
  bad "did not emit the store-accessible transient attribution"
fi
if echo "$LOG13B" | grep -q "Store is required"; then
  ok "the REAL stdout error (Store is required) was surfaced"
else
  bad "real stdout error was not surfaced"
fi
if echo "$LOG13B" | grep -qE "aborting dispatch \(err: .*version_compat"; then
  bad "REGRESSION: still misattributes the abort to the benign version_compat warning"
else
  ok "no longer blames the benign version_compat warning"
fi
if grep -q "released tt-flight" "$STATE/releases.log" 2>/dev/null; then
  ok "claim released after persistent failure (re-dispatchable next sweep)"
else
  bad "claim was not released after persistent sling failure"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
