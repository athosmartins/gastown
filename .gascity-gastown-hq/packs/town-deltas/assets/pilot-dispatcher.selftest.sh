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
  *" blocked"*)
    # The `bd blocked` SUBCOMMAND (space-prefixed token), NOT the `--exclude-label
    # story:blocked` flag that the ctx:ready candidate queries now pass (ga-mfeip
    # gate-a). `story:blocked` is colon-prefixed, so `* blocked*` never matches it —
    # the query falls through to the `-l ctx:ready` case below as intended.
    ids="${FAKE_BLOCKED_IDS:-}"
    if [ -z "$ids" ]; then printf '[]'; exit 0; fi
    out="["; first=1
    for id in $ids; do
      [ "$first" -eq 1 ] || out="$out,"
      out="$out{\"id\":\"$id\",\"title\":\"blocked fixture\",\"description\":\"fixture body\",\"status\":\"open\"}"
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
          *)        printf '{"id":"%s","description":"fixture body — context for veto test","status":"open"}'   "$id" ;;
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
  *"-l ctx:ready"*)
    # ctx:ready chore/task/debt candidate query (PILOT_CTX_READY_QUERIES). MUST be
    # matched BEFORE the *pilot:dispatching* stale-claim pattern below: the
    # ctx:ready query EXCLUDES both --exclude-label story:approved AND
    # --exclude-label pilot:dispatching, so argv contains both substrings and
    # would otherwise be swallowed by the stale-claim case. Its `-l ctx:ready`
    # head token is unique to this query. Returns the injected fixture so a
    # scenario can prove ctx:ready beads ARE sourced as candidates (and that
    # assigned/thin/braked ones are NOT). Default [] keeps every OTHER scenario
    # byte-identical to before this seam existed.
    printf '%s' "${FAKE_CTXREADY_JSON:-[]}" ;;
  *--all*-l*pilot:dispatching*)
    # ga-mfeip: TTL recovery query — `bd list --all -l pilot:dispatching`. Changed
    # from the old `*story:approved*pilot:dispatching*` pattern: the TTL query no
    # longer filters on story:approved so it also covers rig-native ctx:ready beads
    # (chore/task) that carry pilot:dispatching but NOT story:approved. Must be
    # matched BEFORE the generic *--all* in-flight count branch below (which would
    # otherwise swallow it). This case continues to return FAKE_STALE_JSON.
    printf '%s' "${FAKE_STALE_JSON:-[]}" ;;   # Step-0 stale-claim query
  *"-l story:in-flight -l pilot:dispatched"*)
    # ga-v3z4z: Step-0c never-started detector query. Distinct from the slot query
    # (single -l) and from candidate queries (--exclude-label, never -l).
    printf '%s' "${FAKE_NEVERSTARTED_JSON:-[]}" ;;
  *--all*)
    # in-flight count → lanes free by default. ga-rk5va: a scenario may inject
    # FAKE_INFLIGHT_JSON to exercise the stale-occupant slot correction.
    printf '%s' "${FAKE_INFLIGHT_JSON:-[]}" ;;
  *"-t bug"*)
    if [ -n "${FAKE_BUGS_JSON:-}" ]; then
      # ga-2azzj: explicit fixture injection (used by the non-dry in-flight test).
      printf '%s' "$FAKE_BUGS_JSON"
    elif [ "${FAKE_INCLUDE_EPIC:-0}" = "1" ]; then
      # Split-epic scenario (gt-14nya): tt-epic is a P0 type=epic / story:epic-split
      # shell that MUST NEVER be dispatched (empty diff → gate FAIL / dog refusal).
      # This fixture leaks it UNCONDITIONALLY into the candidate stream — the
      # dispatcher's _filter_candidates epic guard is what must drop it. If the
      # guard is absent, tt-epic (P0) wins the pick and the scenario fails loudly.
      cat <<'JSON'
[
  {"id":"tt-epic","title":"Split-epic shell fixture","priority":0,"issue_type":"epic","description":"fixture body — context for veto test","status":"open","labels":["story:epic-split"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
    elif [ "${FAKE_INCLUDE_PREAPPROVAL:-0}" = "1" ]; then
      # Pre-approval lifecycle scenario (ga-w7wvm): two NON-dispatchable features
      # leak UNCONDITIONALLY into the candidate stream — the dispatcher's
      # _filter_candidates lifecycle guard is what must drop them:
      #   tt-triage   — P0 feature still in triage (story:triage). Pre-approval.
      #   tt-mislabel — P0 feature carrying BOTH story:approved AND story:unrefined
      #                 (mid-transition / mislabeled). The single-source query gate
      #                 (-l story:approved) would pass it; only the blocklist guard
      #                 disqualifies it. This is the leak the guard exists to close.
      # Both are P0 so absent the guard they win the pick over the P1 keeper bug.
      cat <<'JSON'
[
  {"id":"tt-triage","title":"In-triage feature fixture","priority":0,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["story:triage"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-mislabel","title":"Mislabeled approved+unrefined fixture","priority":0,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["story:approved","story:unrefined"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
    elif [ "${FAKE_INCLUDE_ENGWIN:-0}" = "1" ]; then
      # Engine-window scenario (ga-6lum3): tt-engwin is a P0 engine-fork bug that
      # MUST NOT be dispatched. This fake bd honors the exclusion ONLY when the
      # dispatcher actually passes --exclude-label "needs:engine-window" — so the
      # bug fixture leaks in (and gets picked, being P0) if the fix is absent.
      case "$args" in
        *"needs:engine-window"*)
          cat <<'JSON'
[
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
          ;;
        *)
          cat <<'JSON'
[
  {"id":"tt-engwin","title":"Engine-fork bug fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":["needs:engine-window"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
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
        prefix="{\"id\":\"tt-depblk\",\"title\":\"Explicit-dep bug fixture\",\"priority\":0,\"issue_type\":\"bug\",\"description\":\"fixture body\",\"status\":\"open\",\"labels\":[],\"assignee\":null,\"created_at\":\"2026-05-01T00:00:00Z\",\"metadata\":{\"story.depends_on_beads\":\"$dep_bead\"}},"
      fi
      cat <<JSON
[
  ${prefix}
  {"id":"tt-blkd","title":"Blocked bug fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-unblk","title":"Unblocked bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
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
run_dispatch() { # $1=FAKE_BLOCKED_IDS  $2=FAKE_INCLUDE_ENGWIN(0|1)  $3=FAKE_DEP_BEAD (optional)  $4=FAKE_INCLUDE_EPIC(0|1)  $5=FAKE_INCLUDE_PREAPPROVAL(0|1)
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
    FAKE_INCLUDE_EPIC="${4:-0}" \
    FAKE_INCLUDE_PREAPPROVAL="${5:-0}" \
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

# Runs Step-0c never-started recovery (ga-v3z4z) with an injected in-flight set.
# Branch existence is faked via PILOT_TEST_BRANCH_BEADS (hermetic — no real git).
#   $1 = FAKE_NEVERSTARTED_JSON   (beads from the story:in-flight+pilot:dispatched query)
#   $2 = PILOT_TEST_BRANCH_BEADS  (space-list of ids that "have a branch")
#   $3 = FAKE_SESSIONS_JSON       (live-session roster; empty → roster untrustworthy)
#   $4 = FAKE_SLING_ASSIGNEES     (sling→assignee map for the live-worker guard)
run_neverstarted() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_NEVERSTARTED_MINUTES=15 \
    FAKE_NEVERSTARTED_JSON="${1:-[]}" \
    PILOT_TEST_BRANCH_BEADS="${2:-}" \
    FAKE_SESSIONS_JSON="${3:-}" \
    FAKE_SLING_ASSIGNEES="${4:-}" \
    FAKE_BLOCKED_IDS="" \
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
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
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
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
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

# ── ctx:ready candidate-source runner (PILOT_CTX_READY_QUERIES default-on) ─────
# Drives a DRY sweep with the ctx:ready candidate query fixture injected. Proves
# the new candidate source: an unassigned ctx:ready chore/task IS dispatched; an
# assigned one is NOT (owned); and (via the seams below) that ctx:ready candidates
# obey the same lane caps + cross-stage congestion yield as every other tier.
#   $1 = FAKE_CTXREADY_JSON            (the -l ctx:ready query result)
#   $2 = FAKE_BUGS_JSON                (override the default 2-bug Tier-1 fixture;
#                                       pass '[]' to make ctx:ready the ONLY source)
#   $3 = PILOT_CTX_READY_QUERIES       (default 1 — i.e. exercise the new default;
#                                       pass 0 to prove the env-gate still disables)
#   $4 = PILOT_GATE_CONGESTED_OVERRIDE ("" probe / "1" congested / "0" empty)
#   $5 = PILOT_DOLT_CPU_OVERRIDE       (default 10 healthy; >200 → Dolt SATURATED →
#                                       resource-tight, which + gate-congested arms
#                                       the ga-d0hz3 cross-stage YIELD. Using Dolt
#                                       saturation — NOT quota — keeps the sweep from
#                                       short-circuiting at the earlier quota-pause.)
#   $6 = FAKE_INFLIGHT_JSON            (occupy lane slots to exercise the cap)
run_ctxready() {
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
    PILOT_DOLT_CPU_OVERRIDE="${5:-10}" \
    DISPATCH_TO_CAPACITY=1 \
    PILOT_CTX_READY_QUERIES="${3:-1}" \
    FAKE_CTXREADY_JSON="${1:-[]}" \
    FAKE_BUGS_JSON="${2:-}" \
    PILOT_GATE_CONGESTED_OVERRIDE="${4:-}" \
    FAKE_INFLIGHT_JSON="${6:-[]}" \
    FAKE_BLOCKED_IDS="" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# ── wa-u5r1: dispatchable-queue emit runner ───────────────────────────────────
# Drives a full DRY_RUN sweep and redirects the emit to a fixture file so the test
# can assert on its JSON without touching the live ~/.gc/pilot-dispatchable.json.
#   $1 = FAKE_BUGS_JSON override (the -t bug fixture; controls the candidate set)
#   $2 = PILOT_QUOTA_OVERRIDE  ("2" → force the quota-pause early-exit)
#   $3 = PILOT_EMIT_DISPATCHABLE ("0" → disable the emit; default 1)
#   $4 = FAKE_INFLIGHT_JSON (occupy slots → exercise the both-lanes-full path)
# Emits the file path on stdout (caller jq's it). The file is reset each run.
EMIT_FILE="$WORK/pilot-dispatchable.json"
run_emit() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl" "$EMIT_FILE"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS=100 \
    PILOT_DOLT_CPU_OVERRIDE=10 \
    PILOT_DISPATCHABLE_FILE="$EMIT_FILE" \
    FAKE_BUGS_JSON="${1:-}" \
    PILOT_QUOTA_OVERRIDE="${2:-}" \
    PILOT_EMIT_DISPATCHABLE="${3:-1}" \
    FAKE_INFLIGHT_JSON="${4:-[]}" \
    FAKE_BLOCKED_IDS="" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  echo "$EMIT_FILE"
}

# Five small, unblocked bug candidates — the exact AC fixture ("5 free small slots
# + 5 ready candidates dispatches all 5").
FIVE_SMALL_BUGS='[
  {"id":"tt-c1","title":"cap bug 1","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-c2","title":"cap bug 2","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}},
  {"id":"tt-c3","title":"cap bug 3","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:03Z","metadata":{}},
  {"id":"tt-c4","title":"cap bug 4","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:04Z","metadata":{}},
  {"id":"tt-c5","title":"cap bug 5","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:05Z","metadata":{}}
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

# ── Scenario 3e: split-epic shells are excluded from dispatch (gt-14nya) ───────
# A type=epic / story:epic-split shell bead is NOT buildable (empty diff → gate
# FAIL or dog refusal) yet the Pilot re-dispatched it every sweep (ga-z0icp 5×).
# The fix ports the Mayor probe's (issue_type//type)!=epic guard into the
# candidate filter. The fake bd leaks a P0 epic into the -t bug stream; if the
# guard is absent it wins the pick (P0) and shows in "Lane picks".
echo "Scenario 3e: split-epic shell (P0 epic) must be excluded, keeper (P1 bug) dispatched"
LOG3E="$(run_dispatch "" 0 "" 1)"

if echo "$LOG3E" | grep -q "Lane picks — small: tt-epic"; then
  bad "LEAK: dispatched the split-epic shell (tt-epic)"
else
  ok "did NOT dispatch the split-epic shell"
fi

if echo "$LOG3E" | grep -q "Lane picks — small: tt-keep"; then
  ok "dispatched the normal keeper bug (tt-keep) instead"
else
  bad "did not dispatch the keeper bug (tt-keep)"
fi

# ── Scenario 3f: pre-approval lifecycle stories are excluded (ga-w7wvm) ─────────
# The Pilot dispatches ONLY story:approved features; pre-approval lifecycle states
# (story:triage / story:unrefined / story:refinement-in-progress) and the terminal
# story:cancelled must NEVER be dispatched. tt-triage (P0, story:triage) and
# tt-mislabel (P0, story:approved+story:unrefined mid-transition) both leak into the
# candidate stream; the _filter_candidates blocklist guard must drop BOTH so the
# P1 keeper bug wins. If the guard is absent, a P0 pre-approval story wins the pick.
echo "Scenario 3f: pre-approval/in-triage stories must be excluded, keeper (P1 bug) dispatched"
LOG3F="$(run_dispatch "" 0 "" 0 1)"

if echo "$LOG3F" | grep -q "Lane picks — small: tt-triage"; then
  bad "LEAK: dispatched an in-triage story (tt-triage)"
else
  ok "did NOT dispatch the in-triage story (tt-triage)"
fi

if echo "$LOG3F" | grep -q "Lane picks — small: tt-mislabel"; then
  bad "LEAK: dispatched a mislabeled approved+unrefined story (tt-mislabel)"
else
  ok "did NOT dispatch the mislabeled approved+unrefined story (tt-mislabel)"
fi

if echo "$LOG3F" | grep -q "Lane picks — small: tt-keep"; then
  ok "dispatched the normal keeper bug (tt-keep) instead"
else
  bad "did not dispatch the keeper bug (tt-keep)"
fi

# ── Structural: every dispatch query block excludes type=epic natively ─────────
# Belt to the behavioral test: --exclude-type epic must appear in EVERY block
# that already excludes gate:needs-human (Tier 1 + Tier 2, HQ + rig paths) so an
# epic is never even fetched as a candidate.
echo "Structural: --exclude-type epic paired with gate:needs-human in all query blocks"
GNH_E=$(grep -c 'exclude-label "gate:needs-human"' "$DISPATCHER")
EPT=$(grep -c 'exclude-type epic' "$DISPATCHER")
if [ "$GNH_E" -gt 0 ] && [ "$EPT" -eq "$GNH_E" ]; then
  ok "--exclude-type epic present in all $GNH_E query block(s)"
else
  bad "exclusion count mismatch: gate:needs-human=$GNH_E exclude-type-epic=$EPT"
fi

# ── Scenario 4: stamp-based TTL recovery (ga-2azzj Defect A) ───────────────────
# Step-0 must measure claim age from the pilot.dispatching_at stamp, NOT
# updated_at. A FRESH claim on an OLD bead must NOT be released.
echo "Scenario 4: TTL recovery uses pilot.dispatching_at stamp, not updated_at"
NOW="$(date +%s)"
OLD_STAMP="$((NOW - 7200))"   # 2h old   → stale (TTL default 30m)
FRESH_STAMP="$((NOW - 60))"   # 1m young → fresh

# 4a: old stamp → release.
STALE_OLD='[{"id":"tt-stale","title":"x","description":"fixture body — context for veto test","status":"open","updated_at":"2020-01-01T00:00:00Z","labels":["story:approved","pilot:dispatching"],"metadata":{"pilot.dispatching_at":"'"$OLD_STAMP"'"}}]'
LOG4A="$(run_step0 "$STALE_OLD")"
if echo "$LOG4A" | grep -q "Releasing stale pilot:dispatching claim on tt-stale"; then
  ok "old stamp (age>TTL) → released the stale claim"
else
  bad "old stamp should have been released"
fi

# 4b: fresh stamp but ANCIENT updated_at → must KEEP (the actual Defect A repro).
STALE_FRESH='[{"id":"tt-fresh","title":"x","description":"fixture body — context for veto test","status":"open","updated_at":"2020-01-01T00:00:00Z","labels":["story:approved","pilot:dispatching"],"metadata":{"pilot.dispatching_at":"'"$FRESH_STAMP"'"}}]'
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
STALE_NOSTAMP='[{"id":"tt-legacy","title":"x","description":"fixture body — context for veto test","status":"open","updated_at":"2020-01-01T00:00:00Z","labels":["story:approved","pilot:dispatching"],"metadata":{}}]'
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

# ── Scenarios 14: ga-x3nmz Claude 5h-quota back-off ───────────────────────────
# A builder dispatched while the Claude 5h window is exhausted dies mid-build, so
# the Pilot must PAUSE the whole sweep (dispatch nothing, mutate no marker) and
# auto-resume once the window resets. Driven through the REAL dispatcher in
# DRY_RUN with the Dolt probe seamed healthy and the quota forced via the
# PILOT_QUOTA_OVERRIDE seam — a candidate bug is present, so a pause proves the
# gate actually stops dispatch (vs. there being nothing to dispatch).
run_quota() { # $1=PILOT_QUOTA_OVERRIDE  $2=PILOT_QUOTA_ETA_OVERRIDE
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
    PILOT_DOLT_CPU_OVERRIDE=10 \
    PILOT_QUOTA_OVERRIDE="$1" \
    PILOT_QUOTA_ETA_OVERRIDE="${2:-}" \
    FAKE_BLOCKED_IDS="" \
    FAKE_BUGS_JSON='[{"id":"tt-q","title":"quota fixture bug","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "Scenario 14a: quota LIMITED → PAUSE sweep, dispatch nothing, ETA in notice"
LOG14A="$(run_quota 2 'resets 5pm (in 12min)')"
if echo "$LOG14A" | grep -q "PAUSING all dispatch"; then
  ok "quota-limited sweep logs the pause"
else
  bad "quota-limited sweep did NOT pause (expected 'PAUSING all dispatch')"
fi
if echo "$LOG14A" | grep -q "dispatched=0 (paused: cota 5h limitada"; then
  ok "sweep-complete line reports dispatched=0 (paused)"
else
  bad "sweep-complete did not report the paused/dispatched=0 state"
fi
if echo "$LOG14A" | grep -q "resets 5pm (in 12min)"; then
  ok "pause notice carries the reset ETA (AC4)"
else
  bad "pause notice missing the reset ETA"
fi
if echo "$LOG14A" | grep -qE "pegou uma história|gc sling|story:in-flight"; then
  bad "REGRESSION: dispatched/slung a builder despite exhausted quota"
else
  ok "no builder dispatched under exhausted quota (AC1)"
fi

echo "Scenario 14b: quota OK → no pause, sweep proceeds normally"
LOG14B="$(run_quota 0)"
if echo "$LOG14B" | grep -q "PAUSING all dispatch"; then
  bad "REGRESSION: paused the sweep when quota was fine"
else
  ok "quota-OK sweep does not pause (proceeds to dispatch logic)"
fi

echo "Scenario 14c: drift-guard — the quota back-off is wired into the live sweep"
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
has "$DISPATCHER" '_pilot_quota_limited\(\)'        "quota probe helper is defined"
has "$DISPATCHER" '_pilot_quota_eta\(\)'            "reset-ETA helper is defined"
has "$DISPATCHER" 'PILOT_QUOTA_OVERRIDE'            "quota override seam wired"
has "$DISPATCHER" 'PAUSING all dispatch this sweep' "pause gate present in the sweep"
# FAIL-OPEN: an absent checker (and no override) must return '0' (never block).
if grep -qE '\[ -x "\$_qc" \] \|\| \{ printf .0.; return 0; \}' "$DISPATCHER"; then
  ok "quota probe fail-opens when the checker is absent"
else
  bad "quota probe missing the fail-open guard (absent checker must not block dispatch)"
fi

# ── Scenario 15: pooled-rig crew distribution (ga-mtlm6) ──────────────────────
# Bug ga-mtlm6: rig_to_builder() hardcoded whatsapp_automation → digo-wa, so EVERY
# WA bug routed to ONE pinned session. With it already live, the wa-1eos mutex
# deferred forever — 4 idle WA crew starved while 46 bugs waited. The fix treats a
# multi-crew rig as a POOL: each dispatch in a sweep picks a DISTINCT idle crew
# (rotation), a crew already holding live in-flight work is EXCLUDED (busy-set),
# and an idle crew with a live session RECEIVES the task instead of being deferred.
#
# Helper: pull the chosen builder from each "Builder target:" log line.
builders_of() { echo "$1" | grep 'Builder target:' | sed -E 's/.*Builder target: ([^ ]+).*/\1/'; }

# Five small, unblocked WA-rig bugs (story.rig overrides prefix inference).
WA_FIVE_BUGS='[
  {"id":"tt-wa1","title":"wa bug 1","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}},
  {"id":"tt-wa2","title":"wa bug 2","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{"story.rig":"whatsapp_automation"}},
  {"id":"tt-wa3","title":"wa bug 3","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:03Z","metadata":{"story.rig":"whatsapp_automation"}},
  {"id":"tt-wa4","title":"wa bug 4","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:04Z","metadata":{"story.rig":"whatsapp_automation"}},
  {"id":"tt-wa5","title":"wa bug 5","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:05Z","metadata":{"story.rig":"whatsapp_automation"}}
]'

echo "Scenario 15a: 5 WA bugs in one sweep fan out to 5 DISTINCT crew (not all digo-wa)"
LOG15A="$(run_capacity 10 "[]" 1 "$WA_FIVE_BUGS")"
B15A="$(builders_of "$LOG15A")"
TOTAL15A=$(echo "$B15A" | grep -c .)
DISTINCT15A=$(echo "$B15A" | sort -u | grep -c .)
if [ "$TOTAL15A" -ge 5 ] && [ "$DISTINCT15A" -ge 5 ]; then
  ok "5 dispatches went to 5 distinct crew (total=$TOTAL15A distinct=$DISTINCT15A)"
else
  bad "REGRESSION: WA work not distributed (total=$TOTAL15A distinct=$DISTINCT15A — single-point routing?)"
fi
if echo "$B15A" | grep -qvE '^(digo|mila|oracle|peter|thies)-wa$'; then
  bad "a dispatch targeted a non-WA-crew builder: $(echo "$B15A" | grep -vE '^(digo|mila|oracle|peter|thies)-wa$' | tr '\n' ' ')"
else
  ok "every dispatch targeted a member of the WA crew pool"
fi
if [ "$(echo "$B15A" | grep -c '^digo-wa$')" -le 1 ]; then
  ok "digo-wa is no longer the sole sink (appears at most once)"
else
  bad "REGRESSION: digo-wa received multiple dispatches in one sweep (pile-up)"
fi

echo "Scenario 15b: non-pooled rig unchanged — gascity bugs still route to gastown.dog"
LOG15B="$(run_capacity 10 "[]" 1 "$FIVE_SMALL_BUGS")"
B15B="$(builders_of "$LOG15B")"
if [ "$(echo "$B15B" | grep -c .)" -ge 5 ] && [ -z "$(echo "$B15B" | grep -vE '^gastown\.dog$')" ]; then
  ok "all gascity dispatches still target gastown.dog (no regression)"
else
  bad "REGRESSION: gascity routing changed (got: $(echo "$B15B" | sort -u | tr '\n' ' '))"
fi

echo "Scenario 15c: a busy crew (live in-flight work) is EXCLUDED — next idle crew chosen"
NOW_ISO15="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INFLIGHT15C="[{\"id\":\"if-digo\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-digo\"}}]"
SESSIONS15C='{"sessions":[{"session_name":"digo-wa","closed":false}]}'
SLINGMAP15C='{"tt-sling-digo":"digo-wa"}'
WA_ONE_BUG='[{"id":"tt-wax","title":"wa bug x","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG15C="$(run_capacity 10 "$INFLIGHT15C" 1 "$WA_ONE_BUG" "$SESSIONS15C" "$SLINGMAP15C")"
B15C="$(builders_of "$LOG15C")"
if echo "$LOG15C" | grep -q "Busy builders (live in-flight): digo-wa"; then
  ok "computed the busy-builder set from live in-flight work"
else
  bad "did not compute/log the busy-builder set (expected 'Busy builders (live in-flight): digo-wa')"
fi
if [ "$B15C" = "digo-wa" ]; then
  bad "REGRESSION: dispatched to the BUSY crew digo-wa (would risk duplicate session)"
elif echo "$B15C" | grep -qE '^(mila|oracle|peter|thies)-wa$'; then
  ok "busy digo-wa excluded; work delivered to an idle crew ($B15C)"
else
  bad "expected an idle WA crew, got: '$B15C'"
fi

echo "Scenario 15d: ALL crew busy → defer (backpressure), never pile onto one"
# 4 small in-flight (digo/mila/oracle/peter busy) + 1 big in-flight (thies busy):
# leaves 1 small slot FREE yet every WA crew is busy → the lone WA bug must DEFER.
INFLIGHT15D="[\
{\"id\":\"if-d\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-s-d\"}},\
{\"id\":\"if-m\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-s-m\"}},\
{\"id\":\"if-o\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-s-o\"}},\
{\"id\":\"if-p\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-s-p\"}},\
{\"id\":\"if-t\",\"labels\":[\"story:in-flight\",\"lane:big\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-s-t\"}}]"
SESSIONS15D='{"sessions":[{"session_name":"digo-wa","closed":false},{"session_name":"mila-wa","closed":false},{"session_name":"oracle-wa","closed":false},{"session_name":"peter-wa","closed":false},{"session_name":"thies-wa","closed":false}]}'
SLINGMAP15D='{"tt-s-d":"digo-wa","tt-s-m":"mila-wa","tt-s-o":"oracle-wa","tt-s-p":"peter-wa","tt-s-t":"thies-wa"}'
LOG15D="$(run_capacity 10 "$INFLIGHT15D" 1 "$WA_ONE_BUG" "$SESSIONS15D" "$SLINGMAP15D")"
B15D="$(builders_of "$LOG15D")"
if [ -z "$B15D" ] && echo "$LOG15D" | grep -qE "POOL\(whatsapp_automation\): all crew busy"; then
  ok "all-busy pool deferred the bug (no dispatch, correct backpressure)"
else
  bad "all-busy pool did not defer cleanly (builders='$(echo "$B15D" | tr '\n' ' ')')"
fi

echo "Scenario 15f: busy crew matched by NAME even when sling task records the session_name"
# Production shape (verified live): a crew claims its sling task with its
# GC_SESSION_NAME (e.g. 'digo-wa-gawispcze4o4'), NOT the alias 'digo-wa' the pool
# lists. The busy-set must normalize the assignee through the session roster so
# the alias-named pool member is still excluded — otherwise exclusion silently
# no-ops in prod and a busy crew gets a second task.
INFLIGHT15F="[{\"id\":\"if-digo2\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-digo2\"}}]"
SESSIONS15F='{"sessions":[{"session_name":"digo-wa-gawispcze4o4","name":"digo-wa","alias":"digo-wa","id":"ga-wisp-cze4o4","agent_name":"digo-wa","closed":false}]}'
SLINGMAP15F='{"tt-sling-digo2":"digo-wa-gawispcze4o4"}'
LOG15F="$(run_capacity 10 "$INFLIGHT15F" 1 "$WA_ONE_BUG" "$SESSIONS15F" "$SLINGMAP15F")"
B15F="$(builders_of "$LOG15F")"
if [ "$B15F" = "digo-wa" ]; then
  bad "REGRESSION: assignee in session_name form not normalized — dispatched to BUSY digo-wa"
elif echo "$B15F" | grep -qE '^(mila|oracle|peter|thies)-wa$'; then
  ok "session_name assignee normalized to alias; busy digo-wa excluded (chose $B15F)"
else
  bad "expected an idle WA crew, got: '$B15F'"
fi

echo "Scenario 15e: drift-guard — pool routing + selection wired into the live dispatcher"
has "$DISPATCHER" 'rig_to_builders\(\)'                         "rig_to_builders pool function is defined"
has "$DISPATCHER" 'digo-wa mila-wa oracle-wa peter-wa thies-wa' "WA rig maps to the full 5-crew pool"
has "$DISPATCHER" 'pick_pool_builder\(\)'                       "idle-crew selection function is defined"
has "$DISPATCHER" 'PILOT_BUSY_BUILDERS'                         "busy-builder exclusion set is wired"

# ── Scenario 16: never-started in-flight recovery (ga-v3z4z) ──────────────────
# A bead stuck story:in-flight + pilot:dispatched whose dispatch never produced a
# worker OR a branch must be RELEASED so the next sweep re-dispatches it — while
# every "real work happened" signal (gate marker, live worker, branch, fresh age)
# must PROTECT a bead from release.
echo "Scenario 16: never-started in-flight beads are released; real ones are protected"
NS_NOW="$(date +%s)"
NS_OLD="$((NS_NOW - 3600))"     # 1h old → past the 15m threshold
NS_FRESH="$((NS_NOW - 60))"     # 1m old → fresh
NS_SESS='{"sessions":[{"session_name":"digo-wa","closed":false}]}'

# 16a: aged, no sling, no branch, no gate → RELEASE.
NS_REL='[{"id":"tt-ns-rel","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
LOG16A="$(run_neverstarted "$NS_REL" "" "" "")"
if echo "$LOG16A" | grep -q "releasing never-started in-flight bead tt-ns-rel"; then
  ok "released a never-started bead (aged, no worker/branch/gate)"
else
  bad "did NOT release the never-started bead tt-ns-rel"
fi

# 16b: fresh dispatch (age < threshold) → KEEP.
NS_FRESH_J='[{"id":"tt-ns-fresh","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_FRESH"'"}}]'
LOG16B="$(run_neverstarted "$NS_FRESH_J" "" "" "")"
if echo "$LOG16B" | grep -q "releasing never-started in-flight bead tt-ns-fresh"; then
  bad "REGRESSION: released a FRESH dispatch (age < 15m threshold)"
else
  ok "fresh dispatch kept (age < threshold — worker may still be spawning)"
fi

# 16c: a surviving crew branch → KEEP (real work landed before the worker died).
NS_BR='[{"id":"tt-ns-branch","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
LOG16C="$(run_neverstarted "$NS_BR" "tt-ns-branch" "" "")"
if echo "$LOG16C" | grep -q "releasing never-started in-flight bead tt-ns-branch"; then
  bad "REGRESSION: released a bead that HAS a crew branch"
else
  ok "bead with a surviving crew branch kept"
fi

# 16d: a gate:* label → KEEP (it reached the gate, so it was built).
NS_GATE='[{"id":"tt-ns-gate","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched","gate:needs-fix"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
LOG16D="$(run_neverstarted "$NS_GATE" "" "" "")"
if echo "$LOG16D" | grep -q "releasing never-started in-flight bead tt-ns-gate"; then
  bad "REGRESSION: released a bead carrying a gate marker (gate:needs-fix)"
else
  ok "bead with a gate marker kept"
fi

# 16e: a sling whose assignee is a LIVE session → KEEP (build in flight).
NS_LIVE='[{"id":"tt-ns-live","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-live"}}]'
LOG16E="$(run_neverstarted "$NS_LIVE" "" "$NS_SESS" '{"tt-sling-live":"digo-wa"}')"
if echo "$LOG16E" | grep -q "releasing never-started in-flight bead tt-ns-live"; then
  bad "REGRESSION: released a bead whose builder session is LIVE"
else
  ok "bead with a live builder session kept"
fi

# 16f: a sling whose assignee is PROVABLY gone (roster trustworthy) → RELEASE.
NS_DEAD='[{"id":"tt-ns-dead","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-dead"}}]'
LOG16F="$(run_neverstarted "$NS_DEAD" "" "$NS_SESS" '{"tt-sling-dead":"ghost-wa"}')"
if echo "$LOG16F" | grep -q "releasing never-started in-flight bead tt-ns-dead"; then
  ok "released a bead whose builder session is provably gone"
else
  bad "did NOT release the dead-worker never-started bead tt-ns-dead"
fi

# 16g: legacy bead with NO pilot.dispatched_at stamp → stamp-now, NOT released
# (the ga-2azzj Defect-A discipline: never release on first sight).
NS_LEGACY='[{"id":"tt-ns-legacy","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{}}]'
LOG16G="$(run_neverstarted "$NS_LEGACY" "" "" "")"
if echo "$LOG16G" | grep -q "no pilot.dispatched_at stamp.*stamping now, NOT releasing"; then
  ok "legacy bead is stamped, not released on first sight (Defect-A guard)"
else
  bad "legacy stamp-now guard did not fire for tt-ns-legacy"
fi
if echo "$LOG16G" | grep -q "releasing never-started in-flight bead tt-ns-legacy"; then
  bad "REGRESSION: released a legacy bead on first sight (Defect-A violation)"
else
  ok "legacy bead NOT released on first sight"
fi

# 16h: sling present but roster untrustworthy (empty) → KEEP (cannot prove dead).
NS_UNTRUST='[{"id":"tt-ns-untrust","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-x"}}]'
LOG16H="$(run_neverstarted "$NS_UNTRUST" "" "" "")"
if echo "$LOG16H" | grep -q "releasing never-started in-flight bead tt-ns-untrust"; then
  bad "REGRESSION: released a sling-bearing bead while the roster was untrustworthy"
else
  ok "sling-bearing bead kept when roster is untrustworthy (cannot prove worker dead)"
fi

# 16L (ga-9yb5s): a CREW owns the story directly (story.assignee = a live named
# crew) → KEEP, even with no sling/branch/gate. A crew claims the STORY bead
# itself; dogs/polecats claim the SLING task instead. The sling-assignee
# live-worker guard (16e) is therefore BLIND to a crew builder, so an active
# crew-built story read "no live worker, no branch" and was falsely reclaimed →
# re-dispatched to the dog pool → two builders on one story (worktree collision).
# The reclaim guard must treat a live crew owner as a live builder — parity with
# the ga-htjni dispatch guard signal (b). FAKE_SLING_ASSIGNEES maps the STORY id
# to the crew, so `bd show <story>` reports that crew as the bead's assignee.
echo "Scenario 16L: ga-9yb5s — a live crew owner of the story protects it from reclaim"
NS_CREW_SESS='{"sessions":[{"session_name":"batista-ps","closed":false}]}'
NS_CREW='[{"id":"tt-ns-crew","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
LOG16L="$(run_neverstarted "$NS_CREW" "" "$NS_CREW_SESS" '{"tt-ns-crew":"batista-ps"}')"
if echo "$LOG16L" | grep -q "releasing never-started in-flight bead tt-ns-crew"; then
  bad "REGRESSION (ga-9yb5s): released a story owned by a LIVE crew (false reclaim → double-dispatch)"
else
  ok "story owned by a live crew is kept (ga-9yb5s parity with ga-htjni dispatch guard)"
fi

# 16m (ga-9yb5s): the crew owner is DEAD (roster trustworthy, owner not in it) →
# RELEASE. The new guard must not pin a genuine orphan whose crew session died;
# it asserts an owner ONLY when that owner is provably live.
echo "Scenario 16m: ga-9yb5s — a DEAD crew owner does NOT pin the bead (no deadlock)"
NS_CREWD='[{"id":"tt-ns-crewdead","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
LOG16M="$(run_neverstarted "$NS_CREWD" "" "$NS_CREW_SESS" '{"tt-ns-crewdead":"ghost-ps"}')"
if echo "$LOG16M" | grep -q "releasing never-started in-flight bead tt-ns-crewdead"; then
  ok "story whose crew owner is provably gone is released (no deadlock)"
else
  bad "REGRESSION (ga-9yb5s): a DEAD crew owner pinned a genuine orphan (deadlock risk)"
fi

# 16n (ga-9yb5s): a dog-pool assignee is NOT a crew owner — the dog path is
# tracked by the SLING task, never by story.assignee. The crew-owner guard must
# ignore a gastown.dog* assignee so dog reclaim behaviour is unchanged.
echo "Scenario 16n: ga-9yb5s — a dog-pool assignee is not treated as a crew owner"
NS_DOG='[{"id":"tt-ns-dog","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
NS_DOG_SESS='{"sessions":[{"session_name":"gastown.dog","closed":false}]}'
LOG16N="$(run_neverstarted "$NS_DOG" "" "$NS_DOG_SESS" '{"tt-ns-dog":"gastown.dog"}')"
if echo "$LOG16N" | grep -q "releasing never-started in-flight bead tt-ns-dog"; then
  ok "dog-pool assignee not mistaken for a crew owner (dog reclaim unchanged)"
else
  bad "REGRESSION (ga-9yb5s): a dog-pool assignee blocked reclaim (should be sling-tracked only)"
fi

# 16i: PILOT_NEVERSTARTED_MINUTES=0 fully disables the detector.
echo "Scenario 16i: PILOT_NEVERSTARTED_MINUTES=0 disables the detector"
: > "$FIXCITY/.gc/logs/pilot-dispatcher.log"; reset_state
env -i PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" HOME="$HOME" DRY_RUN=1 \
  PILOT_CITY_OVERRIDE="$FIXCITY" PILOT_TEST_STATE="$STATE" \
  PILOT_NEVERSTARTED_MINUTES=0 FAKE_NEVERSTARTED_JSON="$NS_REL" \
  PILOT_TEST_BRANCH_BEADS="" FAKE_BLOCKED_IDS="" \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
LOG16I="$(cat "$FIXCITY/.gc/logs/pilot-dispatcher.log")"
if echo "$LOG16I" | grep -q "releasing never-started in-flight bead"; then
  bad "detector ran despite PILOT_NEVERSTARTED_MINUTES=0"
else
  ok "PILOT_NEVERSTARTED_MINUTES=0 fully disables the detector"
fi

# 16j: AC#1 (structural) — the MUTEX/pool defer paths release the claim and can
# NEVER reach the story:in-flight mark, so a deferred dispatch leaves no limbo.
echo "Scenario 16j: AC#1 — defer releases the claim BEFORE any in-flight mark"
has "$DISPATCHER" 'MUTEX\(wa-1eos\).+Releasing claim'        "mutex defer logs claim release"
has "$DISPATCHER" 'all crew busy/used this sweep.+Releasing claim' "pool defer logs claim release"
ns_inflight_ln=$(grep -nF 'label add "$STORY_ID" "story:in-flight"' "$DISPATCHER" | tail -1 | cut -d: -f1)
ns_muxdefer_ln=$(grep -nF 'MUTEX(wa-1eos): builder' "$DISPATCHER" | tail -1 | cut -d: -f1)
if [ -n "$ns_inflight_ln" ] && [ -n "$ns_muxdefer_ln" ] && [ "$ns_inflight_ln" -gt "$ns_muxdefer_ln" ]; then
  ok "story:in-flight is marked only AFTER the defer paths (defer cannot create limbo)"
else
  bad "story:in-flight mark not strictly after defer (in-flight=${ns_inflight_ln:-?} defer=${ns_muxdefer_ln:-?})"
fi

# 16k: drift-guard — the detector + its clock are wired into the live dispatcher.
echo "Scenario 16k: drift-guard — never-started recovery wired into the dispatcher"
has "$DISPATCHER" '_neverstarted_recover_db\(\)'  "never-started recovery function is defined"
has "$DISPATCHER" '_beadid_has_branch\(\)'        "cross-repo branch detector is defined"
has "$DISPATCHER" '_beadid_live_crew_owner\(\)'   "live-crew-owner guard is defined (ga-9yb5s)"
has "$DISPATCHER" '_beadid_live_crew_owner "\$_bid" "\$_db"' "live-crew-owner guard is wired into never-started recovery (ga-9yb5s)"
has "$DISPATCHER" 'pilot.dispatched_at='          "dispatch stamps pilot.dispatched_at (never-started clock)"
has "$DISPATCHER" 'PILOT_NEVERSTARTED_MINUTES'    "never-started threshold knob is wired"

# ── Scenario 17: domain-aware routing (gt-s1saw / wa-ihto) ────────────────────
# Bug gt-s1saw: the Pilot dispatched by rig POOL only — blind to which crew owns
# the bead's AREA. Three UI bugs touching lib/urblink_design_system.py (wa-tnl5,
# wa-rctg, wa-2p8i) landed on digo-wa — the data/email/financeiro owner, NOT the
# frontend owner — who bounced each back to the kanban; the Pilot then re-
# dispatched the SAME bug to digo every sweep, burning cycles in a loop (the
# epic ga-spd2n C3: "Pilot nunca despacha pra domínio errado").
#
# The fix consults a DOMAIN MAP before picking from the pool, FAIL-OPEN:
#   • bead_domain        classifies a bead into frontend / data / infra / "".
#   • rig_domain_owner   PREFERS the mapped owner (data → digo-wa).
#   • rig_domain_exclude DROPS a crew KNOWN NOT to own the area (frontend ≠ digo).
# Unknown domain or unmapped rig ⇒ the pool rotates exactly as before.
#
# The discriminating fixture: a FRONTEND bug (oldest, dispatched first) and a
# DATA bug in the SAME sweep. Blind routing would sink the frontend bug onto
# digo-wa (pool head); the fix must keep frontend OFF digo and still steer the
# data bug TO digo via the prefer rule.
builder_for_domain() { echo "$1" | grep "Builder target:.*domain=$2" | sed -E 's/.*Builder target: ([^ ]+).*/\1/' | head -1; }

WA_DOMAIN_BUGS='[
  {"id":"tt-wafe","title":"painel-historias: corrigir botao no design-system (lib/urblink_design_system.py)","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}},
  {"id":"tt-wadata","title":"enrichment: backfill financeiro do ledger por email","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{"story.rig":"whatsapp_automation"}}
]'

echo "Scenario 17a: frontend bug (design-system) is kept OFF digo-wa (exclude rule)"
LOG17="$(run_capacity 10 "[]" 1 "$WA_DOMAIN_BUGS")"
FE_BUILDER="$(builder_for_domain "$LOG17" frontend)"
if [ -n "$FE_BUILDER" ] && [ "$FE_BUILDER" != "digo-wa" ]; then
  ok "frontend bug routed to a non-digo crew ($FE_BUILDER)"
elif [ "$FE_BUILDER" = "digo-wa" ]; then
  bad "REGRESSION: frontend bug landed on digo-wa (the re-dispatch loop)"
else
  bad "frontend bug was not classified/dispatched (no domain=frontend Builder target line)"
fi

echo "Scenario 17b: data bug (email/financeiro/enrichment) is steered TO digo-wa (prefer rule)"
DATA_BUILDER="$(builder_for_domain "$LOG17" data)"
if [ "$DATA_BUILDER" = "digo-wa" ]; then
  ok "data bug routed to its domain owner digo-wa (prefer)"
else
  bad "data bug did not route to digo-wa (got: '${DATA_BUILDER:-none}')"
fi

echo "Scenario 17c: in one sweep the data bug still reaches digo even though it dispatched second"
# Proves prefer beats plain rotation: the frontend bug (first) excludes digo and
# consumes an idle crew; without the prefer rule the data bug would rotate to the
# NEXT idle crew, not back to digo. The owner must win regardless of dispatch order.
if [ "$FE_BUILDER" != "digo-wa" ] && [ "$DATA_BUILDER" = "digo-wa" ]; then
  ok "owner-prefer overrides rotation order (frontend→$FE_BUILDER, data→digo-wa)"
else
  bad "domain routing did not hold across the sweep (frontend→'${FE_BUILDER:-none}', data→'${DATA_BUILDER:-none}')"
fi

echo "Scenario 17d: unknown-domain WA bug still rotates normally (FAIL-OPEN, no over-steer)"
WA_UNKNOWN='[{"id":"tt-waunk","title":"wa generic bug with no area signal","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG17D="$(run_capacity 10 "[]" 1 "$WA_UNKNOWN")"
UNK_BUILDER="$(builders_of "$LOG17D")"
if echo "$UNK_BUILDER" | grep -qE '^(digo|mila|oracle|peter|thies)-wa$'; then
  ok "unknown-domain bug dispatched to a WA crew member ($UNK_BUILDER) — fail-open intact"
else
  bad "unknown-domain bug was not dispatched normally (got: '${UNK_BUILDER:-none}')"
fi
if echo "$LOG17D" | grep -q "Builder target:.*domain=none"; then
  ok "unknown domain logged as domain=none (classifier returned empty, no spurious steer)"
else
  bad "unknown-domain dispatch did not log domain=none"
fi

echo "Scenario 17e: drift-guard — the domain map is wired into the live dispatcher"
has "$DISPATCHER" 'bead_domain\(\)'         "bead_domain classifier is defined"
has "$DISPATCHER" 'rig_domain_owner\(\)'    "rig_domain_owner (prefer) map is defined"
has "$DISPATCHER" 'rig_domain_exclude\(\)'  "rig_domain_exclude (negative) map is defined"
has "$DISPATCHER" 'urblink_design_system'   "frontend classifier keys on the design-system path"
if grep -qE 'whatsapp_automation/frontend\|wa/frontend\)[[:space:]]*echo "digo-wa"' "$DISPATCHER"; then
  ok "WA frontend area excludes digo-wa (the reported mis-route)"
else
  bad "WA frontend→exclude-digo mapping not present in the dispatcher"
fi
# ── Scenario 17: reuse existing crew session, never spawn a 2nd (gt-4st3n) ────
# Bug gt-4st3n: the Pilot routed work to a crew identity via `gc sling <identity>`
# + an immediate nudge. When that crew ALREADY had a session this spawned/resumed
# a SECOND one alongside (origin=flag resume=--resume → crew-session-dedup drains
# the dup → looks like a reset) and interrupted work the crew may be doing for
# Athos. The fix classifies the target's session and, when one exists, REUSES it:
# ACTIVE → hook + non-interrupting `session submit --intent follow_up`; ASLEEP →
# `session wake` the existing session, then reuse; NONE → legacy spawn. The dog
# pool (gastown.dog) is exempt. PILOT_REUSE_SESSION=0 restores legacy behaviour.
#
# Helper: run a DRY sweep with PILOT_REUSE_SESSION forced to a chosen value.
run_capacity_reuse() { # $1=PILOT_REUSE_SESSION  $2=FAKE_BUGS_JSON  $3=FAKE_SESSIONS_JSON
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
    PILOT_DOLT_CPU_OVERRIDE=10 \
    PILOT_REUSE_SESSION="${1:-1}" \
    FAKE_INFLIGHT_JSON="[]" \
    DISPATCH_TO_CAPACITY=1 \
    FAKE_BUGS_JSON="${2:-}" \
    FAKE_SESSIONS_JSON="${3:-}" \
    FAKE_SLING_ASSIGNEES="" \
    FAKE_BLOCKED_IDS="" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# One WA bug → pooled rig; with no in-flight the busy-set is empty so the picker
# selects the first idle crew (digo-wa), which is the identity we stage a session
# for below.
GT4_WA_BUG='[{"id":"tt-gt4wa","title":"gt-4st3n wa bug","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}}]'
GT4_GC_BUG='[{"id":"tt-gt4gc","title":"gt-4st3n gascity bug","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}]'
GT4_SESS_ACTIVE='{"sessions":[{"session_name":"digo-wa","alias":"digo-wa","agent_name":"digo-wa","id":"ga-wisp-digo","state":"active","closed":false}]}'
GT4_SESS_ASLEEP='{"sessions":[{"session_name":"digo-wa","alias":"digo-wa","agent_name":"digo-wa","id":"ga-wisp-digo","state":"asleep","closed":false}]}'
GT4_SESS_NONE='{"sessions":[]}'
GT4_SESS_DOG='{"sessions":[{"session_name":"dog-1","alias":"gastown.dog-1","agent_name":"gastown.dog-1","id":"ga-wisp-dog1","state":"active","closed":false}]}'

echo "Scenario 17a: ACTIVE crew session → REUSE (hook + follow_up submit), never spawn/interrupt"
LOG17A="$(run_capacity_reuse 1 "$GT4_WA_BUG" "$GT4_SESS_ACTIVE")"
if echo "$LOG17A" | grep -qE "REUSE\(gt-4st3n\): digo-wa has an existing active session"; then
  ok "classified the active crew session for reuse (no 2nd spawn)"
else
  bad "did not classify the active session for reuse (expected REUSE(gt-4st3n) … active)"
fi
if echo "$LOG17A" | grep -qE "WOULD: gc session submit digo-wa .* --intent follow_up"; then
  ok "delivers via non-interrupting follow_up submit to the existing session"
else
  bad "did not choose non-interrupting follow_up submit for the active session"
fi
if echo "$LOG17A" | grep -q "WOULD: gc session wake"; then
  bad "must NOT wake an already-active session"
else
  ok "active session is not waked (only asleep sessions are)"
fi

echo "Scenario 17b: ASLEEP crew session → wake the EXISTING session, then reuse (no parallel)"
LOG17B="$(run_capacity_reuse 1 "$GT4_WA_BUG" "$GT4_SESS_ASLEEP")"
if echo "$LOG17B" | grep -qE "REUSE\(gt-4st3n\): digo-wa has an existing asleep session"; then
  ok "classified the asleep crew session for reuse"
else
  bad "did not classify the asleep session for reuse (expected REUSE(gt-4st3n) … asleep)"
fi
if echo "$LOG17B" | grep -qE "WOULD: gc session wake digo-wa"; then
  ok "wakes the existing asleep session (no parallel spawn)"
else
  bad "did not wake the existing asleep session"
fi
if echo "$LOG17B" | grep -qE "WOULD: gc session submit digo-wa .* --intent follow_up"; then
  ok "asleep path also delivers via non-interrupting follow_up submit"
else
  bad "asleep path did not choose follow_up submit"
fi

echo "Scenario 17c: NO existing session → spawn is correct (legacy sling path), no REUSE"
LOG17C="$(run_capacity_reuse 1 "$GT4_WA_BUG" "$GT4_SESS_NONE")"
if echo "$LOG17C" | grep -q "REUSE(gt-4st3n)"; then
  bad "REGRESSION: claimed reuse when no session exists (would never spawn → starvation)"
else
  ok "no session → no reuse (spawn path taken)"
fi
if echo "$LOG17C" | grep -q "spawn: no existing session"; then
  ok "logs the spawn path explicitly when there is no session to reuse"
else
  bad "did not log the spawn path for the no-session case"
fi

echo "Scenario 17d: gastown.dog is a DOG POOL → always spawn, exempt from reuse"
LOG17D="$(run_capacity_reuse 1 "$GT4_GC_BUG" "$GT4_SESS_DOG")"
if echo "$LOG17D" | grep -q "Builder target: gastown.dog"; then
  ok "gascity bug routed to the gastown.dog pool"
else
  bad "gascity bug did not route to gastown.dog (fixture drift)"
fi
if echo "$LOG17D" | grep -q "REUSE(gt-4st3n)"; then
  bad "REGRESSION: dog pool must be exempt — reuse would break multi-instance design"
else
  ok "dog pool exempt from reuse even with a live gastown.dog session present"
fi

echo "Scenario 17e: PILOT_REUSE_SESSION=0 restores legacy behaviour (no reuse classification)"
LOG17E="$(run_capacity_reuse 0 "$GT4_WA_BUG" "$GT4_SESS_ACTIVE")"
if echo "$LOG17E" | grep -q "REUSE(gt-4st3n)"; then
  bad "REGRESSION: reuse fired with PILOT_REUSE_SESSION=0 (flag not honoured)"
else
  ok "PILOT_REUSE_SESSION=0 disables reuse (legacy spawn+nudge path)"
fi

echo "Scenario 17f: drift-guard — reuse machinery wired into the live dispatcher"
has "$DISPATCHER" '_target_session_state\(\)'          "session-state classifier is defined"
has "$DISPATCHER" 'PILOT_REUSE_SESSION'                "reuse knob is wired"
has "$DISPATCHER" 'session submit .* --intent follow_up' "non-interrupting follow_up submit is used"
has "$DISPATCHER" 'gc --city "\$GC_CITY" session wake'  "asleep-session wake is wired"
# The wa-1eos defer must be gated behind the legacy (reuse=0) path so a live
# session is reused, not deferred, when reuse is enabled.
if grep -qE 'PILOT_REUSE_SESSION:-1.+!= "1".+\&\&.+BUILDER_TARGET.+!= "gastown.dog"' "$DISPATCHER" \
   || grep -B0 -A0 -E '\[ "\$\{PILOT_REUSE_SESSION:-1\}" != "1" \] && \[ "\$DRY_RUN" != "1" \]' "$DISPATCHER" >/dev/null 2>&1; then
  ok "wa-1eos defer is gated to the legacy (reuse-disabled) path"
else
  bad "wa-1eos defer not gated behind PILOT_REUSE_SESSION!=1"
fi

# ── Scenario 18 (ga-lfvs6/ga-wgcyk/ga-m3n1x): DOMAIN-aware no-dog routing ─────
# A property_scrapers DOMAIN build authored as an HQ ga- bead (story.rig unset →
# inferred gascity → would route to gastown.dog) must NOT land on the dog: it is
# re-routed to the owning persistent crew (batista-ps) or DEFERRED, for ANY lane.
# Generic HQ work with no domain signal must STILL route to the dog (fail-open).
#
# These fixtures use ga-* (HQ) ids with NO story.rig, mirroring the real misroutes
# (ga-wgcyk RFB death-check scraper, ga-m3n1x ITBI/CNAE lote mapping). The default
# run_capacity has NO live batista-ps session and an empty busy/used set, so the
# domain build re-routes affirmatively to batista-ps (rule 2).
#
# NOTE: the early "Builder target:" log line is emitted at the routing step BEFORE
# the domain-route guard runs, so it still reads the rig-inferred gastown.dog. The
# AUTHORITATIVE dispatched builder is the post-guard sling line ("→ builder: X" /
# "builder=X"). dispatched_builder() reads that, not the pre-guard target.
dispatched_builder() { echo "$1" | grep -oE '→ story:in-flight \(builder=[^ )]+' | sed -E 's/.*builder=//' | head -1; }
echo "Scenario 18a: property_scrapers domain build (lane:small, ga- HQ bead) → batista-ps, NOT dog"
PS_DOMAIN_SMALL='[{"id":"ga-wgtest","title":"Mapeamento automatico de falecimento de proprietarios idosos (scraper RFB semanal)","priority":3,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-06-12T00:00:01Z","metadata":{"story.o_que_e":"scraper semanal que verifica na Receita Federal o CPF dos proprietarios dos imoveis de interesse"}}]'
LOG18A="$(run_capacity 10 "[]" 1 "$PS_DOMAIN_SMALL")"
B18A="$(dispatched_builder "$LOG18A")"
if [ "$B18A" = "batista-ps" ]; then
  ok "lane:small property_scrapers domain build routed to batista-ps (not the dog)"
elif echo "$B18A" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION: domain build landed on the dog pool ($B18A) — the recurring misroute"
else
  bad "domain build routed unexpectedly (got: '${B18A:-none}')"
fi
if echo "$LOG18A" | grep -q "ga-lfvs6: .* domain build .* routing to the owning persistent crew batista-ps"; then
  ok "domain-route guard logged the re-route to batista-ps"
else
  bad "domain-route guard did not log the affirmative re-route"
fi

echo "Scenario 18b: data-build (ITBI/CNAE, lane:small, ga- HQ bead) → batista-ps, NOT dog"
PS_DOMAIN_DATA='[{"id":"ga-m3test","title":"Mapear compradores de lotes em BH — segmentacao PF/PJ por CNAE","priority":3,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-06-12T00:00:02Z","metadata":{"story.dependencias":"Acesso aos dados de ITBI de BH e a uma fonte de CNAE por CNPJ (Receita Federal)"}}]'
LOG18B="$(run_capacity 10 "[]" 1 "$PS_DOMAIN_DATA")"
B18B="$(dispatched_builder "$LOG18B")"
if [ "$B18B" = "batista-ps" ]; then
  ok "lane:small ITBI/CNAE data-build routed to batista-ps (not the dog)"
elif echo "$B18B" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION: data-build landed on the dog pool ($B18B)"
else
  bad "data-build routed unexpectedly (got: '${B18B:-none}')"
fi

echo "Scenario 18c: generic HQ work (no domain signal) STILL routes to gastown.dog (fail-open)"
LOG18C="$(run_capacity 10 "[]" 1 "$FIVE_SMALL_BUGS")"
B18C="$(builders_of "$LOG18C")"
if [ "$(echo "$B18C" | grep -c .)" -ge 5 ] && [ -z "$(echo "$B18C" | grep -vE '^gastown\.dog$')" ]; then
  ok "all generic HQ dispatches still target gastown.dog (domain guard is fail-open)"
else
  bad "REGRESSION: generic HQ routing changed (got: $(echo "$B18C" | sort -u | tr '\n' ' '))"
fi
if echo "$LOG18C" | grep -q "ga-lfvs6:"; then
  bad "domain-route guard fired on generic HQ work (false positive)"
else
  ok "domain-route guard stayed silent on generic HQ work (no false positive)"
fi

echo "Scenario 18d: lane:big property_scrapers domain build → batista-ps (guard is lane-agnostic)"
# Proves the new guard generalises the lane:big nodog guard to data-build content:
# even a lane:big domain build with no story.rig reaches the crew, not the dog.
PS_DOMAIN_BIG='[{"id":"ga-bigtest","title":"Georreferenciar imoveis Contagem — match cadastral (cadastro PBH + geocode)","priority":2,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:big","story:approved"],"assignee":null,"created_at":"2026-06-16T00:00:01Z","metadata":{"story.notebook":"Hex Compatibilizar ads - Fase 1; pesquisa_mercado.lotes_cadastro_match"}}]'
LOG18D="$(run_capacity 10 "[]" 1 "$PS_DOMAIN_BIG")"
B18D="$(dispatched_builder "$LOG18D")"
if [ "$B18D" = "batista-ps" ]; then
  ok "lane:big domain build also routed to batista-ps (lane-agnostic)"
elif echo "$B18D" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION: lane:big domain build landed on the dog pool ($B18D)"
else
  bad "lane:big domain build routed unexpectedly (got: '${B18D:-none}')"
fi

echo "Scenario 18e: domain build DEFERS (no dog) when the owning crew is BUSY this sweep"
# batista-ps already holds live in-flight work → busy set → the domain build must
# DEFER (leave queued), never fall back to a dog. Correct backpressure.
NOW_ISO18="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INFLIGHT18E="[{\"id\":\"if-ps\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO18\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-ps\"}}]"
SESSIONS18E='{"sessions":[{"session_name":"batista-ps","closed":false}]}'
SLINGMAP18E='{"tt-sling-ps":"batista-ps"}'
LOG18E="$(run_capacity 10 "$INFLIGHT18E" 1 "$PS_DOMAIN_SMALL" "$SESSIONS18E" "$SLINGMAP18E")"
B18E="$(dispatched_builder "$LOG18E")"
if echo "$B18E" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION: domain build fell back to a dog while batista-ps was busy ($B18E)"
elif [ "$B18E" = "batista-ps" ]; then
  bad "domain build dispatched to batista-ps despite it being busy (mutex bypass)"
elif echo "$LOG18E" | grep -q "ga-lfvs6: REFUSING"; then
  ok "domain build DEFERRED (no dispatch, no dog) while owning crew busy — correct backpressure"
elif [ -z "$B18E" ]; then
  ok "domain build not dispatched to any builder while owning crew busy (deferred)"
else
  bad "domain build routed unexpectedly while busy (got: '${B18E:-none}')"
fi

echo "Scenario 18f: drift-guard — the domain-route guard is wired into the live dispatcher"
has "$DISPATCHER" 'PILOT_DOMAIN_ROUTE_GUARD'            "domain-route guard knob is wired"
has "$DISPATCHER" 'bead_content_rig\(\)'               "content→rig classifier is defined"
has "$DISPATCHER" 'rig_domain_default_builder\(\)'     "domain→persistent-crew map is defined"

# ── Scenario 18g/18h (ga-lt8cw/ga-nq64a): WA-integration beads that CARRY property
# vocabulary must NOT misroute to property_scrapers/batista-ps. ROOT: bead_content_rig
# checked property keywords first, so a pipedrive deal ("imóveis do proprietário") or
# the itbi_drive_bridge ("ITBI/Hex") matched property and landed on batista-ps, which
# circuit-broke it → re-dispatch loop. The WA-integration precedence (pipedrive/whapi/
# whatsapp/urblink/drive bridge) must win, so these defer (or route to a live WA owner),
# never to property_scrapers or a dog.
echo "Scenario 18g (ga-lt8cw): WA pipedrive feature with property nouns → NOT property_scrapers/dog"
WA_PIPEDRIVE='[{"id":"ga-lt8test","title":"Pipedrive: incluir demais imoveis do mesmo proprietario ao enviar deal","priority":3,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-06-12T00:00:03Z","metadata":{"story.o_que_e":"ao enviar um deal ao pipedrive o payload inclui os demais imoveis do mesmo proprietario CPF/CNPJ"}}]'
LOG18G="$(run_capacity 10 "[]" 1 "$WA_PIPEDRIVE")"
B18G="$(dispatched_builder "$LOG18G")"
if [ "$B18G" = "batista-ps" ]; then
  bad "REGRESSION (ga-lt8cw): WA pipedrive feature misrouted to property_scrapers/batista-ps"
elif echo "$B18G" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (ga-lt8cw): WA pipedrive feature landed on the dog pool ($B18G)"
elif echo "$LOG18G" | grep -q "whatsapp_automation domain build" || [ -z "$B18G" ]; then
  ok "WA pipedrive feature classified WA → deferred/owned, not the property misroute"
else
  bad "WA pipedrive feature routed unexpectedly (got: '${B18G:-none}')"
fi

echo "Scenario 18h (ga-nq64a): WA itbi_drive_bridge feature with ITBI/Hex nouns → NOT property_scrapers/dog"
WA_BRIDGE='[{"id":"ga-nqtest","title":"ITBI bridge dispara itbi_combiner via Hex API quando espelha mes novo","priority":2,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-06-18T00:00:01Z","metadata":{"story.o_que_e":"o scripts/itbi_drive_bridge.py espelha o relatorio ITBI para a pasta Drive e dispara o notebook itbi_combiner Hex via run API; scrapers PBH"}}]'
LOG18H="$(run_capacity 10 "[]" 1 "$WA_BRIDGE")"
B18H="$(dispatched_builder "$LOG18H")"
if [ "$B18H" = "batista-ps" ]; then
  bad "REGRESSION (ga-nq64a): WA itbi_drive_bridge feature misrouted to property_scrapers/batista-ps"
elif echo "$B18H" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (ga-nq64a): WA bridge feature landed on the dog pool ($B18H)"
elif echo "$LOG18H" | grep -q "whatsapp_automation domain build" || [ -z "$B18H" ]; then
  ok "WA bridge feature classified WA → deferred/owned, not the property misroute"
else
  bad "WA bridge feature routed unexpectedly (got: '${B18H:-none}')"
fi

echo "Scenario 18i: drift-guard — WA-integration precedence is wired into bead_content_rig"
has "$DISPATCHER" 'WA-INTEGRATION PRECEDENCE'          "WA-integration precedence guard is wired"

# ── Scenario 19 (wa-u5r1): dispatchable-queue emit for the painel ─────────────
echo "Scenario 19a: emit writes valid JSON with the contract shape + count + items"
F19="$(run_emit)"
if [ ! -f "$F19" ]; then
  bad "emit did not write a file on a normal sweep"
elif ! jq -e . "$F19" >/dev/null 2>&1; then
  bad "emit wrote invalid JSON"
else
  ok "emit wrote a file with valid JSON"
  if jq -e '(.generated_at|type=="string") and (.ttl_seconds|type=="number") and (.count|type=="number") and (.items|type=="array")' "$F19" >/dev/null 2>&1; then
    ok "emit JSON has the contract keys (generated_at, ttl_seconds, count, items)"
  else
    bad "emit JSON missing one of generated_at/ttl_seconds/count/items"
  fi
  # Default -t bug fixture yields tt-blkd + tt-unblk (both clean, with descriptions).
  if jq -e '[.items[].id] | (index("tt-blkd") != null) and (index("tt-unblk") != null)' "$F19" >/dev/null 2>&1; then
    ok "emit includes the eligible candidates (tt-blkd, tt-unblk)"
  else
    bad "emit missing expected eligible candidates"
  fi
  if jq -e 'all(.items[]; has("id") and has("title") and has("type") and has("rig") and has("priority") and has("created_at") and has("assignee") and has("store"))' "$F19" >/dev/null 2>&1; then
    ok "every emit item carries the full per-item key set"
  else
    bad "an emit item is missing a contract key"
  fi
  if jq -e '.count == (.items|length)' "$F19" >/dev/null 2>&1; then
    ok "emit count matches items length"
  else
    bad "emit count != items length"
  fi
fi

echo "Scenario 19b: emit EXCLUDES assigned/braked beads (shared filter chain)"
# An ASSIGNED bug must be dropped by _filter_candidates; a clean one kept.
EMIT_BUGS_19B='[{"id":"tt-emit-clean","title":"clean","priority":0,"issue_type":"bug","description":"ctx","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},{"id":"tt-emit-assigned","title":"assigned","priority":0,"issue_type":"bug","description":"ctx","status":"open","labels":[],"assignee":"someone-wa","created_at":"2026-06-01T00:00:00Z","metadata":{}}]'
F19B="$(run_emit "$EMIT_BUGS_19B")"
if jq -e '[.items[].id] | (index("tt-emit-clean") != null) and (index("tt-emit-assigned") == null)' "$F19B" >/dev/null 2>&1; then
  ok "emit kept the clean bead and excluded the assigned one (filter parity)"
else
  bad "emit did not apply the assigned-veto correctly (got: $(jq -c '[.items[].id]' "$F19B" 2>/dev/null))"
fi

echo "Scenario 19c: emit writes count=0 / items=[] when there are NO candidates"
EMIT_BUGS_19C='[]'
F19C="$(run_emit "$EMIT_BUGS_19C")"
# Force ALL queries empty: the default shim returns the 2-bug fixture for -t bug
# UNLESS FAKE_BUGS_JSON is set; '[]' makes it empty. tech-debt/features default [].
if jq -e '.count == 0 and (.items == [])' "$F19C" >/dev/null 2>&1; then
  ok "emit wrote the zero-shape (count=0, items=[]) — 'out of dispatchable work'"
else
  bad "emit did not write the zero-shape on an empty pool (got: $(jq -c '{count,items}' "$F19C" 2>/dev/null))"
fi

echo "Scenario 19d: emit STILL writes on the quota-pause early-exit (queue persists)"
F19D="$(run_emit "" 2)"   # PILOT_QUOTA_OVERRIDE=2 → quota PAUSE exit
if [ -f "$F19D" ] && jq -e '.items|type=="array"' "$F19D" >/dev/null 2>&1; then
  ok "emit refreshed the queue even though the sweep PAUSED for quota (file never goes stale on a paused sweep)"
else
  bad "emit did NOT write on the quota-pause path — painel would falsely show stale/empty"
fi

echo "Scenario 19e: emit is env-gated OFF (PILOT_EMIT_DISPATCHABLE=0 → no file)"
F19E="$(run_emit "" "" 0)"
if [ -f "$F19E" ]; then
  bad "emit wrote a file even though PILOT_EMIT_DISPATCHABLE=0"
else
  ok "emit produced no file when disabled (env-gate honored)"
fi

echo "Scenario 19f: a failed emit does NOT abort the dispatch sweep (fail-open)"
# Point the emit at an UNWRITABLE path; the sweep must still complete normally.
: > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
reset_state
env -i \
  PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" HOME="$HOME" DRY_RUN=1 \
  PILOT_CITY_OVERRIDE="$FIXCITY" PILOT_TEST_STATE="$STATE" \
  PILOT_DOLT_LATENCY_OVERRIDE_MS=100 PILOT_DOLT_CPU_OVERRIDE=10 \
  PILOT_DISPATCHABLE_FILE="/this/path/does/not/exist/and/cannot/be/made/x.json" \
  FAKE_BLOCKED_IDS="" \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
LOG19F="$(cat "$FIXCITY/.gc/logs/pilot-dispatcher.log")"
if echo "$LOG19F" | grep -q "=== Pilot sweep complete\|=== Pilot sweep start"; then
  ok "sweep ran to completion despite an unwritable emit path (fail-open, no abort)"
else
  bad "an emit failure aborted the sweep (NOT fail-open)"
fi

echo "Scenario 19g: drift-guard — the emit is wired into the live dispatcher"
has "$DISPATCHER" '_pilot_emit_dispatchable'        "emit function is defined"
has "$DISPATCHER" 'PILOT_EMIT_DISPATCHABLE'         "emit env-gate knob is wired"
has "$DISPATCHER" 'PILOT_DISPATCHABLE_FILE'         "emit output-path seam is wired"

# ── Scenario 20 (ctx:ready auto-dispatch — PILOT_CTX_READY_QUERIES default-on) ─
# Athos directive: the Pilot must ALSO pull plain ctx:ready chore/task/debt beads
# (no story:* label) that fell in no tier and sat idle forever. These four
# scenarios prove: (a) an unassigned ctx:ready chore IS a candidate and dispatches;
# (b) an ASSIGNED ctx:ready task is NOT (owned-exclusion preserved); (c) the new
# candidates respect the per-lane cap; (d) they respect the ga-d0hz3 cross-stage
# congestion yield; (e) the env-gate still disables them. The fake bd returns
# FAKE_CTXREADY_JSON for the `-l ctx:ready` query ONLY.

# One unassigned, context-complete chore (small lane, no story:* label).
CTX_ONE_CHORE='[
  {"id":"tt-ctx-chore","title":"ctx:ready chore fixture","priority":0,"issue_type":"chore","description":"fixture body — context for the generic builder","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}
]'

# ── Scenario 20a: an unassigned ctx:ready chore IS dispatched (the whole point) ─
echo "Scenario 20a: unassigned ctx:ready chore is a candidate and dispatches (default-on)"
# FAKE_BUGS_JSON='[]' makes the ctx:ready chore the ONLY candidate, so the pick is
# unambiguous proof the new source fed the pool.
LOG20A="$(run_ctxready "$CTX_ONE_CHORE" "[]")"
if echo "$LOG20A" | grep -q "ctx:ready chore/task/debt: 1 candidate"; then
  ok "ctx:ready query sourced the chore as a candidate (PILOT_CTX_READY_QUERIES=1 default)"
else
  bad "ctx:ready chore was NOT sourced (expected 'ctx:ready chore/task/debt: 1 candidate')"
fi
if echo "$LOG20A" | grep -q "Lane picks — small: tt-ctx-chore"; then
  ok "dispatched the unassigned ctx:ready chore"
else
  bad "did NOT dispatch the ctx:ready chore (expected 'Lane picks — small: tt-ctx-chore')"
fi

# ── Scenario 20a2: env-gate still turns it OFF (PILOT_CTX_READY_QUERIES=0) ──────
echo "Scenario 20a2: PILOT_CTX_READY_QUERIES=0 disables the ctx:ready source (env-gate honored)"
LOG20A2="$(run_ctxready "$CTX_ONE_CHORE" "[]" 0)"
if echo "$LOG20A2" | grep -q "ctx:ready chore/task/debt:"; then
  bad "ctx:ready query ran while gated OFF (env-gate not honored)"
else
  ok "ctx:ready query SKIPPED when gated off (byte-equivalent to legacy)"
fi
if echo "$LOG20A2" | grep -q "Lane picks — small: tt-ctx-chore"; then
  bad "dispatched a ctx:ready chore while the source was gated OFF"
else
  ok "no ctx:ready dispatch when gated off"
fi

# ── Scenario 20b: an ASSIGNED ctx:ready task is NOT a candidate (owned) ─────────
# The owned-exclusion lives in _filter_candidates (assignee == null/empty). A
# ctx:ready task already claimed by a crew must NEVER be re-dispatched.
echo "Scenario 20b: an ASSIGNED ctx:ready task is excluded (owned — no double-dispatch)"
CTX_ASSIGNED='[
  {"id":"tt-ctx-owned","title":"owned ctx:ready task","priority":0,"issue_type":"task","description":"fixture body — already owned","status":"open","labels":["ctx:ready"],"assignee":"batista-ps","created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-ctx-free","title":"free ctx:ready task","priority":1,"issue_type":"task","description":"fixture body — unowned","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}
]'
LOG20B="$(run_ctxready "$CTX_ASSIGNED" "[]")"
if echo "$LOG20B" | grep -q "Lane picks — small: tt-ctx-owned"; then
  bad "REGRESSION: dispatched an ASSIGNED ctx:ready task (owned-exclusion lost)"
else
  ok "did NOT dispatch the assigned ctx:ready task (owned-exclusion preserved)"
fi
if echo "$LOG20B" | grep -q "Lane picks — small: tt-ctx-free"; then
  ok "dispatched the UNASSIGNED ctx:ready task instead (P1, the only eligible one)"
else
  bad "did not dispatch the unassigned ctx:ready task"
fi

# ── Scenario 20c: ctx:ready candidates respect the per-lane cap (no flood) ──────
# Six small ctx:ready chores, 5 free small slots → exactly 5 dispatch, never 6.
echo "Scenario 20c: ctx:ready candidates obey the small-lane cap (MAX_SMALL=5) — cannot flood"
CTX_SIX_CHORES='[
  {"id":"tt-cx1","title":"ctx chore 1","priority":0,"issue_type":"chore","description":"fixture body — context","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-cx2","title":"ctx chore 2","priority":0,"issue_type":"chore","description":"fixture body — context","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}},
  {"id":"tt-cx3","title":"ctx chore 3","priority":0,"issue_type":"chore","description":"fixture body — context","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:03Z","metadata":{}},
  {"id":"tt-cx4","title":"ctx chore 4","priority":0,"issue_type":"chore","description":"fixture body — context","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:04Z","metadata":{}},
  {"id":"tt-cx5","title":"ctx chore 5","priority":0,"issue_type":"chore","description":"fixture body — context","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:05Z","metadata":{}},
  {"id":"tt-cx6","title":"ctx chore 6","priority":0,"issue_type":"chore","description":"fixture body — context","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:06Z","metadata":{}}
]'
LOG20C="$(run_ctxready "$CTX_SIX_CHORES" "[]")"
if echo "$LOG20C" | grep -q "Lane small: dispatched 5 this sweep"; then
  ok "filled exactly the 5 free small slots from the ctx:ready backlog (cap honored)"
else
  bad "did not dispatch all 5 ctx:ready chores (expected 'Lane small: dispatched 5')"
fi
if echo "$LOG20C" | grep -qE "Lane small: dispatched ([6-9]|[1-9][0-9]+) this sweep"; then
  bad "REGRESSION: ctx:ready backlog flooded past the small-lane cap of 5"
else
  ok "ctx:ready backlog never exceeded MAX_SMALL — cannot flood the crews"
fi

# ── Scenario 20d: ctx:ready candidates respect the ga-d0hz3 cross-stage yield ──
# Gate congested + Dolt saturated (resource-tight) → the WHOLE sweep defers BEFORE
# sourcing candidates, so a ctx:ready backlog can never pile onto a congested Gate.
echo "Scenario 20d: ctx:ready dispatch DEFERS under the cross-stage gate-congestion yield"
#                       ctxJSON          bugs  gate gateCongested doltCPU(300=saturated)
LOG20D="$(run_ctxready "$CTX_SIX_CHORES" "[]" 1 1 300)"
if echo "$LOG20D" | grep -q "Cross-stage YIELD (ga-d0hz3)"; then
  ok "ctx:ready sweep yielded to the congested Gate under resource contention"
else
  bad "did not yield under gate-congested + resource-tight (ga-d0hz3 not honored for ctx:ready)"
fi
if echo "$LOG20D" | grep -q "Lane picks — small: tt-cx"; then
  bad "REGRESSION: dispatched ctx:ready work while the Gate was congested + Dolt hot"
else
  ok "dispatched NO ctx:ready work during the cross-stage yield (no Gate flood)"
fi

# ── Scenario 20e: drift-guard — ctx:ready default flipped to 1 and stays env-gated
echo "Scenario 20e: drift-guard — PILOT_CTX_READY_QUERIES defaults to 1 and is env-gated"
has "$DISPATCHER" 'PILOT_CTX_READY_QUERIES="\$\{PILOT_CTX_READY_QUERIES:-1\}"' \
  "ctx:ready knob defaults to 1 (ON) and remains overridable via env"
has "$DISPATCHER" '\-l "ctx:ready"' \
  "the ctx:ready candidate query is wired into the dispatcher"
# Every exclusion the other tiers enforce must also gate the ctx:ready query.
echo "Scenario 20f: structural — the ctx:ready query keeps every existing exclusion"
CTXBLOCK=$(awk '/Step 2a-ctx:/{f=1} f{print} /CTXREADY_COUNT=\$\(echo/{if(f)exit}' "$DISPATCHER")
for excl in "story:in-flight" "story:done" "gate:passed" "pilot:dispatching" \
            "gate:needs-human" "needs:engine-window" "pilot:dispatched" "ctx:thin"; do
  if echo "$CTXBLOCK" | grep -q "exclude-label \"$excl\""; then
    ok "ctx:ready query excludes $excl"
  else
    bad "ctx:ready query is MISSING the $excl exclusion"
  fi
done

# ── Scenario 21 (ga-mfeip: exec:manual exclusion + rig-native ctx:ready dispatch)
# ga-mfeip AC3: exec:manual beads must NOT be auto-dispatched — they require
# physical-device / gov-portal / human-credential interaction that a crew cannot
# perform. exec:auto and unlabelled beads dispatch normally.
# ga-mfeip: rig-native dispatch (cross-store sling refused) goes through
# `bd update --assignee` + nudge path, gated by PILOT_CTX_READY_RIG_QUERIES.

# ── Scenario 21a: exec:manual ctx:ready beads are NOT dispatched ─────────────
echo "Scenario 21a: exec:manual ctx:ready bead is EXCLUDED from auto-dispatch (ga-mfeip AC3)"
CTX_MANUAL='[
  {"id":"tt-ctx-manual","title":"exec:manual task fixture","priority":0,"issue_type":"task","description":"fixture body — requires physical device","status":"open","labels":["ctx:ready","exec:manual"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-ctx-auto","title":"exec:auto task fixture","priority":1,"issue_type":"task","description":"fixture body — fully automatable","status":"open","labels":["ctx:ready","exec:auto"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}
]'
LOG21A="$(run_ctxready "$CTX_MANUAL" "[]")"
if echo "$LOG21A" | grep -q "Lane picks — small: tt-ctx-manual"; then
  bad "REGRESSION: dispatched an exec:manual ctx:ready bead (ga-mfeip AC3 violation)"
else
  ok "exec:manual ctx:ready bead was NOT dispatched (ga-mfeip AC3 preserved)"
fi
if echo "$LOG21A" | grep -q "Lane picks — small: tt-ctx-auto"; then
  ok "exec:auto ctx:ready bead WAS dispatched (only manual is excluded)"
else
  bad "exec:auto bead was NOT dispatched — over-filtered or no candidate sourced"
fi

# ── Scenario 21b: unlabelled (no exec:) ctx:ready bead IS dispatched ─────────
echo "Scenario 21b: ctx:ready bead with NO exec: label dispatches normally (conservative default)"
CTX_NOLABEL='[
  {"id":"tt-ctx-nolabel","title":"no-exec-label ctx:ready task","priority":0,"issue_type":"task","description":"fixture body — no exec label","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}
]'
LOG21B="$(run_ctxready "$CTX_NOLABEL" "[]")"
if echo "$LOG21B" | grep -q "Lane picks — small: tt-ctx-nolabel"; then
  ok "ctx:ready task with no exec: label IS dispatched (conservative default: auto-OK)"
else
  bad "ctx:ready task with no exec: label was NOT dispatched — over-filter regression"
fi

# ── Scenario 21c: structural — exec:manual is excluded at query + filter level ─
echo "Scenario 21c: structural — exec:manual exclusion wired at query AND filter level"
# Query-level: the bd list command must pass --exclude-label exec:manual.
# grep -E treats leading '--' as options; anchor the search on exclude-label.
has "$DISPATCHER" 'exclude-label "exec:manual"' \
  "ctx:ready query excludes exec:manual at the bd list query level"
# Filter-level: _filter_exec_manual function is defined (defense-in-depth safety belt).
has "$DISPATCHER" '_filter_exec_manual()' \
  "_filter_exec_manual function defined (defense-in-depth exec:manual filter)"
# Applied in the HQ ctx:ready chain.
has "$DISPATCHER" '_filter_exec_manual | _filter_candidates' \
  "exec:manual filter applied in HQ ctx:ready filter chain"

# ── Scenario 21d: structural — rig-native ctx:ready dispatch path wired ────────
echo "Scenario 21d: structural — rig-native dispatch path and env gate are wired (ga-mfeip)"
has "$DISPATCHER" 'PILOT_CTX_READY_RIG_QUERIES' \
  "PILOT_CTX_READY_RIG_QUERIES env gate defined (ga-mfeip)"
has "$DISPATCHER" 'CTXREADY_RIG_JSON' \
  "CTXREADY_RIG_JSON variable wired (rig ctx:ready pool)"
has "$DISPATCHER" '_IS_RIG_NATIVE' \
  "rig-native dispatch selector _IS_RIG_NATIVE defined in dispatch_one"
has "$DISPATCHER" 'rig_assign_failed' \
  "rig-native assign-failure result code present"
has "$DISPATCHER" 'rig_native_ok' \
  "rig-native success result code present"
# Verify the sling bead self-reference for TTL compatibility.
has "$DISPATCHER" 'pilot.sling_bead=\$STORY_ID' \
  "rig-native dispatch sets pilot.sling_bead=STORY_ID for TTL compatibility"

# ── Scenario 21e: structural — TTL recovery extended to cover rig ctx:ready ────
echo "Scenario 21e: structural — TTL recovery covers rig ctx:ready beads (no story:approved filter)"
# The TTL query must NOT require story:approved so it catches chore/task rig beads.
_ttl_block=$(awk '/Helper: scan one DB for stale pilot:dispatching/{f=1} f{print} /^}$/{if(f)exit}' "$DISPATCHER")
if echo "$_ttl_block" | grep -q '"story:approved"'; then
  bad "REGRESSION: TTL recovery still requires story:approved — rig ctx:ready beads won't be cleaned up"
else
  ok "TTL recovery does NOT require story:approved — covers rig ctx:ready beads (ga-mfeip)"
fi
# TTL must handle self-referential sling_bead (rig-native: _sling == _bid).
has "$DISPATCHER" '_sling_db.*_db' \
  "TTL recovery routes sling-status lookup to rig DB for rig-native beads"

# ── Scenario 22 (ga-mfeip DISPATCH QUALITY GATES a–f) ─────────────────────────
# The six gates required before re-enabling rig ctx:ready dispatch (Mayor escalation
# 2026-06-20). A ctx:ready bead must be SKIPPED (not autonomous-built) when it is:
#   (a) blocked / needs-human;  (b) un-spec'd (empty AC + thin desc);
#   (c) carrying a blocked-on:/depends-on: precondition label;  (d) on an unmet dep;
#   (e) about to be assigned to a SUSPENDED crew (digo-wa);  (f) already owned (dedup).
# (d) is already covered by Scenarios using _filter_unblocked/_filter_explicit_deps.

# ── Scenario 22a: gate (b) — a thin, un-spec'd ctx:ready bead is NOT dispatched ─
echo "Scenario 22a: gate (b) — un-spec'd ctx:ready bead (empty AC + thin desc) is NOT dispatched"
CTX_THIN='[
  {"id":"tt-thin","title":"stub","priority":0,"issue_type":"task","description":"todo","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-spec","title":"specced task","priority":1,"issue_type":"task","description":"fixture body — a properly specified task with enough context for a crew to build it","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}
]'
LOG22A="$(run_ctxready "$CTX_THIN" "[]")"
if echo "$LOG22A" | grep -q "Lane picks — small: tt-thin"; then
  bad "REGRESSION: dispatched a thin/un-spec'd ctx:ready bead (gate (b) violation)"
else
  ok "thin/un-spec'd ctx:ready bead was NOT dispatched (gate (b))"
fi
if echo "$LOG22A" | grep -q "Lane picks — small: tt-spec"; then
  ok "the well-specified ctx:ready bead WAS dispatched (only the stub is dropped)"
else
  bad "the well-specified bead was NOT dispatched — gate (b) over-filtered"
fi

# ── Scenario 22b: gate (c) — a blocked-on:/depends-on: labelled bead is excluded ─
echo "Scenario 22b: gate (c) — ctx:ready bead with a blocked-on: precondition label is NOT dispatched"
CTX_BLKLABEL='[
  {"id":"tt-blklabel","title":"has precondition","priority":0,"issue_type":"task","description":"fixture body — carries an unsatisfied precondition label that bd cannot see","status":"open","labels":["ctx:ready","blocked-on:ata-dedicada"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-noblk","title":"no precondition","priority":1,"issue_type":"task","description":"fixture body — a clean task with no precondition labels whatsoever here","status":"open","labels":["ctx:ready"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}
]'
LOG22B="$(run_ctxready "$CTX_BLKLABEL" "[]")"
if echo "$LOG22B" | grep -q "Lane picks — small: tt-blklabel"; then
  bad "REGRESSION: dispatched a blocked-on:-labelled ctx:ready bead (gate (c) violation)"
else
  ok "blocked-on:-labelled ctx:ready bead was NOT dispatched (gate (c))"
fi
if echo "$LOG22B" | grep -q "Lane picks — small: tt-noblk"; then
  ok "the clean ctx:ready bead WAS dispatched (only the precondition-labelled one is dropped)"
else
  bad "the clean bead was NOT dispatched — gate (c) over-filtered"
fi

# ── Scenario 22b2: gate (a) — a status=blocked bead is NOT dispatched (status FIELD) ─
# wa-tozk/wa-1my1 regression: a crew/triage gates a design-first bead by setting its
# status FIELD to "blocked". `bd list -l ctx:ready` does NOT filter the status field, so
# it leaks past the label exclusions; _filter_dispatch_gates must drop it.
echo "Scenario 22b2: gate (a) — a status=blocked ctx:ready bead is NOT dispatched (status FIELD leak)"
CTX_BLOCKED_STATUS='[
  {"id":"tt-blocked-status","title":"design-first locked","priority":0,"issue_type":"task","description":"fixture body — design-first, locked by a crew pending Athos approval (wa-tozk class)","status":"blocked","labels":["ctx:ready","exec:auto"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-open-ok","title":"open buildable","priority":1,"issue_type":"task","description":"fixture body — a normal open task with enough context to build right here","status":"open","labels":["ctx:ready","exec:auto"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}
]'
LOG22B2="$(run_ctxready "$CTX_BLOCKED_STATUS" "[]")"
if echo "$LOG22B2" | grep -q "Lane picks — small: tt-blocked-status"; then
  bad "REGRESSION: dispatched a status=blocked ctx:ready bead (gate (a) violation — wa-tozk/wa-1my1 class)"
else
  ok "status=blocked ctx:ready bead was NOT dispatched (gate (a) — crew/triage lock holds)"
fi
if echo "$LOG22B2" | grep -q "Lane picks — small: tt-open-ok"; then
  ok "the status=open bead WAS dispatched (only the blocked-status one is gated)"
else
  bad "the status=open bead was NOT dispatched — gate (a) status-check over-filtered"
fi
has "$DISPATCHER" '!= "blocked" and ' "gate (a) status=blocked/closed exclusion wired in _filter_dispatch_gates"

# ── Scenario 22b3: gate (a) — a "design-first" bead is NOT dispatched (needs approval) ─
echo "Scenario 22b3: gate (a) — a design-first ctx:ready bead is NOT dispatched (spec needs Athos approval)"
CTX_DESIGNFIRST='[
  {"id":"tt-designfirst","title":"F2 inbound on-device v2","priority":0,"issue_type":"task","description":"DESIGN-FIRST: spec aprovado por Athos antes de codar. Acceptance criteria a definir.","status":"open","labels":["ctx:ready","exec:auto"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}},
  {"id":"tt-buildable","title":"normal task","priority":1,"issue_type":"task","description":"fixture body — a normal open task with enough context to build right here now","status":"open","labels":["ctx:ready","exec:auto"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}
]'
LOG22B3="$(run_ctxready "$CTX_DESIGNFIRST" "[]")"
if echo "$LOG22B3" | grep -q "Lane picks — small: tt-designfirst"; then
  bad "REGRESSION: dispatched a design-first ctx:ready bead (gate (a) violation — wa-1my1 class)"
else
  ok "design-first ctx:ready bead was NOT dispatched (gate (a) — needs Athos design approval)"
fi
if echo "$LOG22B3" | grep -q "Lane picks — small: tt-buildable"; then
  ok "the normal buildable bead WAS dispatched (only the design-first one is gated)"
else
  bad "the normal bead was NOT dispatched — design-first gate over-filtered"
fi

# ── Scenario 22c: gate (a) — structural — query excludes blocked/needs-human/etc ─
echo "Scenario 22c: gate (a) — ctx:ready query excludes blocked / needs-human / future markers"
has "$DISPATCHER" 'exclude-label "story:blocked"'        "query excludes story:blocked (gate a)"
has "$DISPATCHER" 'exclude-label "needs-human"'          "query excludes needs-human (gate a)"
has "$DISPATCHER" 'exclude-label "needs-human-decision"' "query excludes needs-human-decision (gate a)"
has "$DISPATCHER" 'exclude-label "type:future"'          "query excludes type:future (gate c)"
has "$DISPATCHER" 'exclude-label "cost-decision"'        "query excludes cost-decision (gate c)"
has "$DISPATCHER" 'exclude-label "phone-proxy"'          "query excludes phone-proxy (gate c — digo's ban-sensitive operational domain)"

# ── Scenario 22d: gates (b)+(c) — structural — filter defined and wired both chains
echo "Scenario 22d: gates (b)+(c) — _filter_dispatch_gates defined and applied in HQ + rig chains"
has "$DISPATCHER" '_filter_dispatch_gates()' "_filter_dispatch_gates function defined"
has "$DISPATCHER" '_filter_candidates | _filter_dispatch_gates' "dispatch gates applied after _filter_candidates"
has "$DISPATCHER" 'PILOT_CTX_MIN_SPEC_CHARS' "spec-floor knob (gate b) is wired and tunable"

# ── Scenario 22e: gate (e) — suspended crews are excluded (unit + structural) ───
echo "Scenario 22e: gate (e) — _crew_is_suspended excludes a suspended crew, keeps an active one"
# Behavioral unit test: extract the two real helper fns and exercise them through the
# PILOT_SUSPENDED_CREWS_OVERRIDE seam (no gc dependency). Proves the membership logic.
_SUSP_FNS="$(awk '/_PILOT_SUSPENDED_CREWS=""/{p=1} p{print} /_crew_is_suspended\(\)/{c=1} c&&/^}$/{exit}' "$DISPATCHER")"
SUSP_RESULT="$(
  eval "$_SUSP_FNS"
  export PILOT_SUSPENDED_CREWS_OVERRIDE="digo-wa gastown.boot"
  if _crew_is_suspended digo-wa; then printf 'digo=excluded '; else printf 'digo=KEPT '; fi
  if _crew_is_suspended thies-wa; then printf 'thies=EXCLUDED'; else printf 'thies=active'; fi
)"
if [ "$SUSP_RESULT" = "digo=excluded thies=active" ]; then
  ok "gate (e): suspended digo-wa excluded, active thies-wa kept (real helper logic)"
else
  bad "gate (e): _crew_is_suspended logic wrong (got: '$SUSP_RESULT')"
fi
has "$DISPATCHER" '_crew_is_suspended()'                 "_crew_is_suspended gate (e) helper defined"
has "$DISPATCHER" '_crew_is_suspended "\$crew" && continue' "suspended-crew skip wired into pick_pool_builder"

# ── Scenario 22f: gate (f) — rig-native dedup re-check before assign (structural) ─
echo "Scenario 22f: gate (f) — rig-native dispatch re-checks the live assignee before assigning (dedup)"
has "$DISPATCHER" 'rig_dedup_skip'  "gate (f) dedup-skip result code present"
# The dedup re-reads the CURRENT assignee from the rig DB right before assigning.
_dedup_block="$(awk '/RIG-NATIVE dispatch \(ga-mfeip\)/{f=1} f{print} /rig_native_ok/{if(f)exit}' "$DISPATCHER")"
if printf '%s' "$_dedup_block" | grep -q 'bd -C "\$STORY_BEAD_CITY" show "\$STORY_ID"' \
   && printf '%s' "$_dedup_block" | grep -q '_cur_asg.*!=.*BUILDER_TARGET'; then
  ok "gate (f): fresh assignee re-read + mismatch-skip wired before the rig-native assign"
else
  bad "gate (f): dedup re-check missing from the rig-native dispatch path"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
