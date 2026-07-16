#!/usr/bin/env bash
# ── Runtime expectation (ga-iuzk1) ─────────────────────────────────────────
# This is BY FAR the largest file in this directory: ~380 assertions driven
# through ~94 real `pilot-dispatcher.sh` subprocess invocations (each spawns
# a fresh bash interpreter for the ~4500-line dispatcher). Measured full-run
# wall time: ~140s (2026-07-02, on the reference dev host) — vs. a sibling
# median around 150-200 lines / well under 15s. If you're batch-verifying
# every `*.selftest.sh` in this directory with a uniform short bound (a
# `timeout 15` sweep is the go-to convention here), that bound WILL kill this
# file mid-run with no PASS/FAIL summary. That is NOT a hang — every scenario
# passes given enough time (383/383 as of this writing; see ga-iuzk1). Give
# this file its own `timeout 180` (or no bound) rather than reusing the
# per-file default that's sized for its much smaller siblings.
#
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
#   FAKE_STORY_COMMENTS_JSON  JSON array returned for `comments <id> --json`
#                          (ga-pd7j mayor-hold-grace seam; default [])
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
    # gate-feedback lookup + ga-pd7j mayor-hold-grace check. Default [] keeps
    # every existing scenario byte-identical to before this seam existed.
    printf '%s' "${FAKE_STORY_COMMENTS_JSON:-[]}" ;;
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
        # ga-88g2: simulate a concurrent inflight-reclaim-guard escalation landing
        # gate:needs-human MID-DISPATCH — i.e. AFTER the ga-zzrts claim-verify's
        # `bd show` has already read this id once. Counter-based (per-id, in
        # $STATE) so the race is deterministic instead of depending on real
        # wall-clock concurrency. FAKE_ESCALATE_AFTER_SHOWS=N: the Nth and
        # earlier `bd show <id>` calls return clean; the (N+1)th and later
        # calls carry gate:needs-human. Unset/empty (the default) never escalates
        # — every existing scenario is byte-identical to before this seam existed.
        if [ -n "${FAKE_ESCALATE_AFTER_SHOWS:-}" ]; then
          _scf="$STATE/$id.showcount"
          _sc=$(cat "$_scf" 2>/dev/null || echo 0)
          _sc=$((_sc + 1))
          echo "$_sc" > "$_scf"
          [ "$_sc" -gt "$FAKE_ESCALATE_AFTER_SHOWS" ] && lbls="${lbls:+$lbls,}\"gate:needs-human\""
        fi
        # ga-pd7j: mark the fixture as already in the gate-fix loop (stable label,
        # present from the start — unlike the counter-based escalation above, this
        # test isn't about racing the LABEL, it's about racing a MAYOR COMMENT).
        [ "${FAKE_GATE_NEEDS_FIX:-0}" = "1" ] && lbls="${lbls:+$lbls,}\"gate:needs-fix\""
        st="open"
        case "$id" in *sling*) st="${FAKE_SLING_STATUS:-open}" ;; esac
        # ga-e5yw2: the dead-worker correction resolves a sling task's assignee.
        # FAKE_SLING_ASSIGNEES is a JSON map {"<slingid>":"<assignee>", …}.
        asg=""
        if [ -n "${FAKE_SLING_ASSIGNEES:-}" ]; then
          asg=$(printf '%s' "$FAKE_SLING_ASSIGNEES" | jq -r --arg id "$id" '.[$id] // ""' 2>/dev/null || echo "")
        fi
        # ga-d2jil: the sling gate-marker guard checks the sling/task bead's OWN
        # labels for gate:*. FAKE_SLING_LABELS is a JSON map {"<slingid>":"<label>", …}
        # (single extra label per id, folded into the same labels array as above).
        if [ -n "${FAKE_SLING_LABELS:-}" ]; then
          extra=$(printf '%s' "$FAKE_SLING_LABELS" | jq -r --arg id "$id" '.[$id] // ""' 2>/dev/null || echo "")
          [ -n "$extra" ] && lbls="${lbls:+$lbls,}\"$extra\""
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
  *" -l pilot:dispatching"*)
    # TTL recovery query — `bd list --json -l pilot:dispatching` (--all removed:
    # dolt-load opt; no closed bead ever carries pilot:dispatching in production).
    # Pattern matches the literal substring " -l pilot:dispatching" (space before
    # the flag), which differentiates the bare -l filter from --exclude-label
    # (the latter embeds "label pilot:dispatching" without a leading space-dash).
    # ctx:ready queries use --exclude-label and are caught first by *"-l ctx:ready"*.
    printf '%s' "${FAKE_STALE_JSON:-[]}" ;;   # Step-0 stale-claim query
  *"-l story:in-flight -l pilot:dispatched"*)
    # ga-v3z4z: Step-0c never-started detector query. Distinct from the slot query
    # (single -l) and from candidate queries (--exclude-label, never -l).
    printf '%s' "${FAKE_NEVERSTARTED_JSON:-[]}" ;;
  *" -l story:in-flight"*|*gate-status:queued*|*gate-status:running*)
    # in-flight count (single -l story:in-flight, --all removed: dolt-load opt)
    # and gate-congestion probes (gate-status:queued / gate-status:running, also
    # --all removed). Never-started (double -l) is caught by the case above.
    # --exclude-label story:in-flight in candidate queries embeds "label story:in-flight"
    # WITHOUT a leading space-dash, so " -l story:in-flight" won't match them.
    # ga-rk5va: FAKE_INFLIGHT_JSON injection exercises the stale-occupant slot
    # correction (overrides the [] default for slot scenarios only).
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
        prefix="{\"id\":\"tt-depblk\",\"title\":\"Explicit-dep bug fixture\",\"priority\":0,\"issue_type\":\"bug\",\"description\":\"fixture body\",\"status\":\"open\",\"labels\":[],\"assignee\":null,\"created_at\":\"2026-06-15T00:00:00Z\",\"metadata\":{\"story.depends_on_beads\":\"$dep_bead\"}},"  # newer than tt-blkd (2026-06-01) so newest-first still picks tt-depblk in Scenario 8 (dep-clear intent preserved)
      fi
      cat <<JSON
[
  ${prefix}
  {"id":"tt-blkd","title":"Blocked bug fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-unblk","title":"Unblocked bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
    fi ;;
  *"-l story:approved"*)
    # HQ story:approved TIER2 candidate query. FAKE_TIER2_JSON lets scenarios
    # inject specific approved-feature fixtures to exercise _filter_dispatch_gates
    # on the HQ TIER2 path (ga-25-hq-tier2-gates). Default [] keeps every other
    # scenario byte-identical to before this seam existed.
    printf '%s' "${FAKE_TIER2_JSON:-[]}" ;;
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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    FAKE_STALE_JSON="$1" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs Step-0c never-started recovery (ga-v3z4z) with an injected in-flight set.
# Branch existence is faked via PILOT_TEST_BRANCH_BEADS (hermetic — no real git).
#   $1 = FAKE_NEVERSTARTED_JSON         (beads from the story:in-flight+pilot:dispatched query)
#   $2 = PILOT_TEST_BRANCH_BEADS        (space-list of ids that "have a branch" via _beadid_has_branch)
#   $3 = FAKE_SESSIONS_JSON             (live-session roster; empty → roster untrustworthy)
#   $4 = FAKE_SLING_ASSIGNEES           (sling→assignee map for the live-worker guard)
#   $5 = PILOT_TEST_CREW_PROGRESSED     (crews treated as "progressed" for owner-grace)
#   $6 = PILOT_TEST_CREW_BRANCH_BEADS   (space-list of ids with a crew/<crew>/<id> branch — _beadid_has_crew_branch seam)
#   $7 = PILOT_TEST_PHANTOM_STALE_BEADS (space-list of ids treated as stale >45min — phantom guard seam)
#   $8 = FAKE_SLING_LABELS              (sling→extra-label map — ga-d2jil sling gate-marker guard seam)
#   $9 = PILOT_TEST_DEAD_SLINGS         (space-list of sling ids treated as STALE by _sling_is_live — ga-l7pp)
run_neverstarted() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_NEVERSTARTED_MINUTES=15 \
    FAKE_NEVERSTARTED_JSON="${1:-[]}" \
    PILOT_TEST_BRANCH_BEADS="${2:-}" \
    FAKE_SESSIONS_JSON="${3:-}" \
    FAKE_SLING_ASSIGNEES="${4:-}" \
    PILOT_TEST_CREW_PROGRESSED="${5:-}" \
    PILOT_TEST_CREW_BRANCH_BEADS="${6:-}" \
    PILOT_TEST_DEAD_SLINGS="${9:-}" \
    FAKE_SLING_LABELS="${8:-}" \
    PILOT_TEST_PHANTOM_STALE_BEADS="${7:-}" \
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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT="$1" \
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs a REAL (non-dry) dispatch where gate:needs-human lands on the candidate
# MID-DISPATCH — after N `bd show` reads have already happened — simulating a
# concurrent inflight-reclaim-guard escalation racing the builder-target-
# resolution window (ga-88g2). Arg 1: FAKE_ESCALATE_AFTER_SHOWS (unset/empty
# = never escalates, i.e. the plain happy path).
run_real_dispatch_escalate() { # FAKE_ESCALATE_AFTER_SHOWS
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT=0 \
    FAKE_ESCALATE_AFTER_SHOWS="${1:-}" \
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs a REAL (non-dry) dispatch of a gate:needs-fix candidate, with comments
# injected via FAKE_STORY_COMMENTS_JSON (ga-pd7j Mayor-hold grace window).
# Arg 1: FAKE_STORY_COMMENTS_JSON (unset/empty = no comments, plain happy path).
# Arg 2: PILOT_MAYOR_HOLD_GRACE_SECS override (default 300 if omitted).
run_real_dispatch_mayorhold() { # FAKE_STORY_COMMENTS_JSON [PILOT_MAYOR_HOLD_GRACE_SECS]
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT=0 \
    FAKE_GATE_NEEDS_FIX=1 \
    FAKE_STORY_COMMENTS_JSON="${1:-}" \
    PILOT_MAYOR_HOLD_GRACE_SECS="${2:-300}" \
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":["gate:needs-fix"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
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
#   $1 = PILOT_DOLT_CPU_OVERRIDE   (<=200 healthy, >200 saturated; since latency is now the
#        AUTHORITATIVE signal, >200 also forces latency=3000 so the fixture reads saturated)
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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_FRAMEWORK_DOG_EXEMPT="${PILOT_FRAMEWORK_DOG_EXEMPT:-}" \
    PILOT_PATH_RIG_GUARD="${PILOT_PATH_RIG_GUARD:-}" \
    PILOT_MISSING_FILE_GUARD="${PILOT_MISSING_FILE_GUARD:-}" \
    PILOT_TEST_RIG_HAS_FILE="${PILOT_TEST_RIG_HAS_FILE:-}" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS="$([ "${1:-10}" -gt 200 ] 2>/dev/null && echo 3000 || echo 100)" \
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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS="$([ "${5:-10}" -gt 200 ] 2>/dev/null && echo 3000 || echo 100)" \
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

# Scenario 3e2 (wa-tis4, mila-wa 2026-06-22): the painel "Soltar worker" action zeroes the
# assignee AND stamps a durable pilot:held label. The Pilot must EXCLUDE pilot:held beads from
# the candidate pool — else story:approved + empty assignee re-dispatches the held worker in
# ~2min. One clause in _filter_candidates (the single chokepoint for every dispatch path).
echo "Scenario 3e2: a pilot:held bead is excluded from the candidate pool (durable worker release)"
_FC_FN="$(awk '/^_FILTER_PREAPPROVAL_LABELS=/{print} /^_FILTER_RECLAIM_CAP=/{print} /^_filter_candidates\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_fc() { ( eval "$_FC_FN"; SELF_BEAD_ID=""; echo "$1" | _filter_candidates | jq -rc '[.[].id]' ); }
HELD='[{"id":"bd-held","assignee":null,"labels":["story:approved","pilot:held"],"description":"x"},{"id":"bd-free","assignee":null,"labels":["story:approved"],"description":"x"}]'
[ "$(_fc "$HELD")" = '["bd-free"]' ] && ok "pilot:held bead excluded; free story:approved kept (durable release holds)" || bad "pilot:held not excluded (got: $(_fc "$HELD"))"
grep -qE 'index..pilot:held' "$DISPATCHER" && ok "_filter_candidates carries the pilot:held clause"                      || bad "pilot:held clause missing from _filter_candidates"

# imp19 timed-hold cases: pilot:held + pilot:held-until:<epoch> (both labels present).
# (a) FUTURE expiry → bead is still held → must be SKIPPED (not dispatchable).
# (b) PAST expiry   → hold has expired  → must be PASSED THROUGH (dispatchable).
echo "Scenario 3e2a (imp19): pilot:held + pilot:held-until:<FUTURE> → bead must be SKIPPED"
_FC_NOW="$(date +%s)"
_FC_FUTURE=$(( _FC_NOW + 3600 ))
_FC_PAST=$(( _FC_NOW - 1 ))
HELD_FUTURE='[{"id":"bd-held-future","assignee":null,"labels":["story:approved","pilot:held","pilot:held-until:'"$_FC_FUTURE"'"],"description":"x"},{"id":"bd-free2","assignee":null,"labels":["story:approved"],"description":"x"}]'
_fc_res_future="$(_fc "$HELD_FUTURE")"
case "$_fc_res_future" in
  *bd-held-future*) bad "imp19: held+future-until bead leaked into candidates (should be SKIPPED): $(_fc "$HELD_FUTURE")" ;;
  *) ok "imp19(a): pilot:held + pilot:held-until:<FUTURE> → SKIPPED (hold still active)" ;;
esac
[ "$(_fc "$HELD_FUTURE")" = '["bd-free2"]' ] && ok "imp19(a): only the free bead passes through" || bad "imp19(a): unexpected candidate set: $(_fc "$HELD_FUTURE")"

echo "Scenario 3e2b (imp19): pilot:held + pilot:held-until:<PAST> → bead must be PASSED THROUGH (dispatchable)"
HELD_PAST='[{"id":"bd-held-past","assignee":null,"labels":["story:approved","pilot:held","pilot:held-until:'"$_FC_PAST"'"],"description":"x"},{"id":"bd-free3","assignee":null,"labels":["story:approved"],"description":"x"}]'
_fc_res_past="$(_fc "$HELD_PAST")"
case "$_fc_res_past" in
  *bd-held-past*) ok "imp19(b): pilot:held + pilot:held-until:<PAST> → PASSED THROUGH (hold expired)" ;;
  *) bad "imp19(b): expired-hold bead was incorrectly skipped (should be dispatchable): $_fc_res_past" ;;
esac

# ── Scenario 3e2c/d (ga-4aree): ACCUMULATED held-until stamps ──────────────────
# The stamp adds one held-until per hold; if they accumulate, a naive .[0] check reads the
# OLDEST (expired) stamp and wrongly judges the bead dispatchable → it is re-selected every
# sweep → the recurring dog-pool-refusal clog that starved buildable work. The filter must
# use the MAX (latest) epoch: a bead whose LATEST hold is still in the future must be SKIPPED
# even when older stamps have expired.
echo "Scenario 3e2c (ga-4aree): accumulated held-until (.[0]=PAST, max=FUTURE) → must be SKIPPED"
HELD_ACCUM='[{"id":"bd-held-accum","assignee":null,"labels":["story:approved","pilot:held","pilot:held-until:'"$_FC_PAST"'","pilot:held-until:'"$_FC_FUTURE"'"],"description":"x"},{"id":"bd-free4","assignee":null,"labels":["story:approved"],"description":"x"}]'
_fc_res_accum="$(_fc "$HELD_ACCUM")"
case "$_fc_res_accum" in
  *bd-held-accum*) bad "ga-4aree: accumulated held-until with FUTURE max leaked into candidates (the clog bug): $_fc_res_accum" ;;
  *) ok "ga-4aree: accumulated held-until, max=FUTURE → SKIPPED (uses MAX epoch, not .[0])" ;;
esac
[ "$(_fc "$HELD_ACCUM")" = '["bd-free4"]' ] && ok "ga-4aree: only the free bead passes (accumulated hold honored)" || bad "ga-4aree: unexpected candidate set: $(_fc "$HELD_ACCUM")"

echo "Scenario 3e2d (ga-4aree): accumulated held-until ALL PAST (max=PAST) → PASSED THROUGH"
_FC_PAST2=$(( _FC_NOW - 100 ))
HELD_ACCUM_EXP='[{"id":"bd-accum-exp","assignee":null,"labels":["story:approved","pilot:held","pilot:held-until:'"$_FC_PAST2"'","pilot:held-until:'"$_FC_PAST"'"],"description":"x"}]'
case "$(_fc "$HELD_ACCUM_EXP")" in
  *bd-accum-exp*) ok "ga-4aree: accumulated held-until all expired (max=PAST) → PASSED THROUGH" ;;
  *) bad "ga-4aree: all-expired accumulated hold incorrectly skipped: $(_fc "$HELD_ACCUM_EXP")" ;;
esac

# ── Scenario 3e3 (ga-iu9m/ga-enfe): graph.v2 workflow steps excluded from candidates ──
# ga-knfh ("Determine digest time range", a mol-digest-generate step) was dispatched as
# a code-build story 8x over 5.25h before being reclaimed each time — there is no repo
# to branch in, so the "implement -> /gate-done" doctrine this filter feeds into can
# never be satisfied. Such beads carry gc.root_bead_id (every step) or
# gc.formula_contract/gc.kind=workflow (the root itself, which has no root_bead_id since
# it IS the root) and are already serviced directly by whichever pool gc.routed_to names
# — Pilot must never treat them as buildable stories.
echo "Scenario 3e3 (ga-iu9m/ga-enfe): graph.v2 workflow step/root beads excluded from candidates"
STEP_BEAD='[{"id":"bd-step","assignee":null,"labels":[],"description":"x","metadata":{"gc.root_bead_id":"bd-root","gc.step_ref":"mol-x.step-y"}},{"id":"bd-normal","assignee":null,"labels":[],"description":"x","metadata":{}}]'
[ "$(_fc "$STEP_BEAD")" = '["bd-normal"]' ] && ok "ga-iu9m/ga-enfe: gc.root_bead_id step bead excluded; normal bug kept" || bad "ga-iu9m/ga-enfe: step-bead exclusion failed (got: $(_fc "$STEP_BEAD"))"

ROOT_BEAD='[{"id":"bd-root2","assignee":null,"labels":[],"description":"x","metadata":{"gc.formula_contract":"graph.v2","gc.kind":"workflow"}},{"id":"bd-normal2","assignee":null,"labels":[],"description":"x","metadata":{}}]'
[ "$(_fc "$ROOT_BEAD")" = '["bd-normal2"]' ] && ok "ga-iu9m/ga-enfe: workflow root bead (formula_contract+kind) excluded; normal bug kept" || bad "ga-iu9m/ga-enfe: root-bead exclusion failed (got: $(_fc "$ROOT_BEAD"))"

CONTROL_KIND_BEAD='[{"id":"bd-finalize","assignee":null,"labels":[],"description":"x","metadata":{"gc.kind":"workflow-finalize"}},{"id":"bd-normal3","assignee":null,"labels":[],"description":"x","metadata":{}}]'
[ "$(_fc "$CONTROL_KIND_BEAD")" = '["bd-normal3"]' ] && ok "ga-iu9m/ga-enfe: control-kind bead (workflow-finalize) excluded; normal bug kept" || bad "ga-iu9m/ga-enfe: control-kind exclusion failed (got: $(_fc "$CONTROL_KIND_BEAD"))"

UNRELATED_META='[{"id":"bd-has-meta","assignee":null,"labels":[],"description":"x","metadata":{"story.rig":"whatsapp_automation"}}]'
[ "$(_fc "$UNRELATED_META")" = '["bd-has-meta"]' ] && ok "ga-iu9m/ga-enfe: bead with unrelated metadata still dispatchable (no false-positive)" || bad "ga-iu9m/ga-enfe: false-positive — unrelated-metadata bead wrongly excluded (got: $(_fc "$UNRELATED_META"))"

echo "$_FC_FN" | grep -q 'gc.root_bead_id' && ok "_filter_candidates carries the gc.root_bead_id workflow-step exclusion clause" || bad "gc.root_bead_id exclusion clause missing from _filter_candidates"

# ── Scenario 3e2e-h (ga-am6h): pilot:reclaim-count cap is STICKY, independent of
# pilot:held ─────────────────────────────────────────────────────────────────────
# ga-knfh incident: inflight-reclaim-guard exhausted the reclaim cap (3/3) at
# 18:10 but its gate:needs-human escalation did not land until 19:51 — a 1h41m
# gap during which the ONLY thing keeping the bead out of Pilot's candidate pool
# was the pilot:held 60min cooldown, which expired first and let Pilot
# re-dispatch (19:17, 19:40) a bead that had already exhausted its cap.
# _filter_candidates must exclude on pilot:reclaim-count alone, with no
# dependency on pilot:held being present or unexpired (ga-52s2 fix).
echo "Scenario 3e2e (ga-am6h): pilot:reclaim-count AT cap, no pilot:held label → must be SKIPPED (sticky, not cooldown-gated)"
RECLAIM_CAPPED='[{"id":"bd-capped","assignee":null,"labels":["story:approved","pilot:reclaim-count:3"],"description":"x"},{"id":"bd-free5","assignee":null,"labels":["story:approved"],"description":"x"}]'
[ "$(_fc "$RECLAIM_CAPPED")" = '["bd-free5"]' ] && ok "ga-am6h: reclaim-count at cap excluded even with no pilot:held (sticky)" || bad "ga-am6h: capped bead leaked into candidates: $(_fc "$RECLAIM_CAPPED")"

echo "Scenario 3e2f (ga-am6h): pilot:reclaim-count ABOVE cap → must be SKIPPED (defensive, count can exceed cap)"
RECLAIM_ABOVE='[{"id":"bd-above-cap","assignee":null,"labels":["story:approved","pilot:reclaim-count:5"],"description":"x"}]'
case "$(_fc "$RECLAIM_ABOVE")" in
  *bd-above-cap*) bad "ga-am6h: reclaim-count above cap (5) leaked into candidates: $(_fc "$RECLAIM_ABOVE")" ;;
  *) ok "ga-am6h: reclaim-count above cap (5) excluded" ;;
esac

echo "Scenario 3e2g (ga-am6h): pilot:reclaim-count BELOW cap → still PASSED THROUGH (no regression for normal reclaim flow)"
RECLAIM_BELOW='[{"id":"bd-below-cap","assignee":null,"labels":["story:approved","pilot:reclaim-count:2"],"description":"x"}]'
case "$(_fc "$RECLAIM_BELOW")" in
  *bd-below-cap*) ok "ga-am6h: reclaim-count below cap (2 < 3) passes through" ;;
  *) bad "ga-am6h: below-cap bead incorrectly excluded: $(_fc "$RECLAIM_BELOW")" ;;
esac

echo "Scenario 3e2h (ga-am6h): no pilot:reclaim-count label at all → PASSED THROUGH (default/most-common case)"
RECLAIM_NONE='[{"id":"bd-no-reclaim","assignee":null,"labels":["story:approved"],"description":"x"}]'
case "$(_fc "$RECLAIM_NONE")" in
  *bd-no-reclaim*) ok "ga-am6h: no reclaim-count label → unaffected, passes through" ;;
  *) bad "ga-am6h: bead with no reclaim history incorrectly excluded: $(_fc "$RECLAIM_NONE")" ;;
esac

grep -qE 'pilot:reclaim-count:' "$DISPATCHER" && ok "_filter_candidates carries the pilot:reclaim-count clause"                      || bad "pilot:reclaim-count clause missing from _filter_candidates"

# ── Scenario 3e2i (ga-2lqv): engine-window:pending excluded from candidates ────
# ga-sm5p pattern: a builder finishes Phase-1 (code fix + green tests) and
# deliberately leaves the bug open with engine-window:pending because Phase-2
# (deploy) is batched with sibling bugs not yet ready. Pilot re-dispatched a
# SECOND builder onto the same bug ~3 min after the first dispatch closed — a
# pure no-op that burned a full dog-pool cycle re-verifying nothing had changed.
# _filter_candidates must exclude engine-window:pending the same way it excludes
# pilot:held, so the bead only re-enters the pool once whoever runs the batched
# deploy removes the label.
echo "Scenario 3e2i (ga-2lqv): engine-window:pending bead is excluded from the candidate pool (batched deploy hold)"
ENGWIN_PENDING='[{"id":"bd-engwin-pending","assignee":null,"labels":["story:approved","engine-window:pending"],"description":"x"},{"id":"bd-free6","assignee":null,"labels":["story:approved"],"description":"x"}]'
[ "$(_fc "$ENGWIN_PENDING")" = '["bd-free6"]' ] && ok "ga-2lqv: engine-window:pending bead excluded; free story:approved kept (batched-deploy hold honored)" || bad "ga-2lqv: engine-window:pending not excluded (got: $(_fc "$ENGWIN_PENDING"))"
grep -qE '"engine-window:pending"' "$DISPATCHER" && ok "_filter_candidates carries the engine-window:pending clause" || bad "engine-window:pending clause missing from _filter_candidates"

# ── Scenario OWN-GUARD (ga-htjni ext; wa-5wv49 / wa-xnuxd) ──────────────────────
# The reported systemic double-dispatch: a crew/human creates a bead intending to
# build it THEMSELVES and claims it (status=in_progress + assignee=<self>) — yet the
# Pilot still slung a PARALLEL wa-worker on the SAME bead. Root cause: the ga-htjni
# ownership guard's (b) branch blocked ONLY an assignee that resolves to a LIVE gc
# SESSION (exact grep -Fxq match) with a trustworthy roster — a self-claiming crew's
# assignee is session-suffixed (thies-wa-awispr9ofspp on both repro beads) so it never
# matched, and STATUS was never consulted at dispatch time. Signal (c) re-reads the
# bead FRESH from its OWNING store and refuses an external in_progress claim (or a
# raced terminal/blocked status), while still allowing the states that must dispatch.
# Extracted-function harness (mirrors _fc): stub bd/branch/session, assert the reason.
echo "Scenario OWN-GUARD (ga-htjni ext): guard refuses external in_progress crew self-claim, allows the legit states"
_OG_FN="$(awk '/^_ownership_guard_should_refuse\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
# Also extract signal (d)'s helper so the guard's real composition is tested (not a
# stub). With PILOT_TEST_GATE_ACTIVE_BEADS UNDEFINED (the default in the (1)-(5)
# cases below) it short-circuits to the stubbed bd → empty → return 1 (no active
# gate artifact → allow), so signal (d) is inert there and (a)/(b)/(c) behave exactly
# as before. The (d1)-(d5) cases DEFINE the seam to exercise (d) hermetically.
_GATE_FN="$(awk '/^_beadid_has_active_gate_artifact\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_og() { (
    eval "$_OG_FN"; eval "$_GATE_FN"
    SELF_BEAD_ID=""; _DEADWORKER_OK=1
    bd() { case "$*" in *" show "*) printf '%s' "${OG_BEAD_JSON:-}" ;; *) : ;; esac; }
    _beadid_has_crew_branch() { return 1; }   # no crew branch → signal (a) does not fire
    _session_is_live()        { return 1; }   # never a live session → isolate (c) from (b)
    _beadid_mentioned_in_attached_session() { return 1; }   # isolate from (e) — has its own dedicated scenario below
    _ownership_guard_should_refuse "$1" "$2" "ignored-db"
); }

# (1) EXTERNAL CLAIM — in_progress + session-suffixed crew assignee, NO pilot fingerprint → REFUSE.
OG_BEAD_JSON='[{"id":"wa-ext","status":"in_progress","assignee":"thies-wa-awispr9ofspp","labels":[],"metadata":{}}]'
_OG_R1="$(_og "wa-ext" '{"id":"wa-ext","assignee":"","status":"open","labels":[]}')"
case "$_OG_R1" in
  external-claim:thies-wa-awispr9ofspp@in_progress) ok "OWN-GUARD(1): external in_progress crew self-claim REFUSED (reason: $_OG_R1)" ;;
  *) bad "OWN-GUARD(1): external in_progress self-claim NOT refused (got: '$_OG_R1') — the double-dispatch bug is back" ;;
esac

# (2) MAYOR ROUTING — assignee set but status=OPEN (imp20) → must NOT be refused by (c).
OG_BEAD_JSON='[{"id":"wa-may","status":"open","assignee":"batista-ps","labels":[],"metadata":{}}]'
_OG_R2="$(_og "wa-may" '{"id":"wa-may","assignee":"","status":"open","labels":[]}')"
[ -z "$_OG_R2" ] && ok "OWN-GUARD(2): Mayor-routed open+assignee bead allowed (imp20 preserved)" \
                 || bad "OWN-GUARD(2): open+assignee bead wrongly refused (got: '$_OG_R2') — would break imp20 routing"

# (3) PILOT-FINGERPRINTED ORPHAN — in_progress + pool assignee WITH pilot:dispatched → allow (reclaim owns it).
OG_BEAD_JSON='[{"id":"wa-orph","status":"in_progress","assignee":"wa-worker-adhoc-xyz","labels":["pilot:dispatched"],"metadata":{"pilot.dispatched_at":"123"}}]'
_OG_R3="$(_og "wa-orph" '{"id":"wa-orph","assignee":"","status":"open","labels":[]}')"
[ -z "$_OG_R3" ] && ok "OWN-GUARD(3): Pilot-fingerprinted orphan allowed (NEVERSTARTED/ga-e5yw2 reclaim owns it, no deadlock)" \
                 || bad "OWN-GUARD(3): fingerprinted orphan wrongly refused (got: '$_OG_R3') — would deadlock reclaim"

# (4) RACED TERMINAL STATUS — status=blocked (claimed past the snapshot), no assignee → REFUSE.
OG_BEAD_JSON='[{"id":"wa-blk","status":"blocked","assignee":"","labels":[],"metadata":{}}]'
_OG_R4="$(_og "wa-blk" '{"id":"wa-blk","assignee":"","status":"open","labels":[]}')"
[ "$_OG_R4" = "status:blocked" ] && ok "OWN-GUARD(4): raced status=blocked REFUSED (reason: $_OG_R4)" \
                                 || bad "OWN-GUARD(4): raced blocked status NOT refused (got: '$_OG_R4')"

# (5) NEVERSTARTED-RELEASED RESIDUE — in_progress but assignee cleared to "" , no fingerprint → allow (re-dispatchable).
OG_BEAD_JSON='[{"id":"wa-ns","status":"in_progress","assignee":"","labels":[],"metadata":{}}]'
_OG_R5="$(_og "wa-ns" '{"id":"wa-ns","assignee":"","status":"open","labels":[]}')"
[ -z "$_OG_R5" ] && ok "OWN-GUARD(5): in_progress+empty-assignee residue allowed (released bead re-dispatchable, no deadlock)" \
                 || bad "OWN-GUARD(5): empty-assignee residue wrongly refused (got: '$_OG_R5') — would strand NEVERSTARTED releases"

# Structural: the (c) external-claim clause is present in the live dispatcher source.
grep -qE 'external-claim:%s@in_progress' "$DISPATCHER" \
  && ok "OWN-GUARD: dispatcher carries the (c) external-claim clause" \
  || bad "OWN-GUARD: (c) external-claim clause missing from dispatcher"

# ── Scenario OWN-GUARD (d): live gate-handoff artifact refuses duplicate dispatch ──
# The recurring "open-during-gate-handoff" race (wa-0hnsi/wa-62qbd/wa-xnuxd/wa-1tb9b):
# a bead released to open+unassigned while its gate-submit is in flight gets a
# duplicate pool-worker (signals a/b/c are all blind to it). Signal (d) refuses when a
# live quality-gate marker/run is ACTIVELY processing the bead's branch. The CRITICAL
# constraint: a parked/terminal artifact (failed/error/needs-rebase/passed/superseded)
# must NOT count as active — the gate:needs-fix re-fix loop (whose only marker is
# failed/error) MUST still dispatch, else we reintroduce the deadlock the rig-scan /
# held-until fixes cured. Two layers: (d1)-(d2) test the guard composition via the seam;
# (d3)-(d8) test the function's ACTIVE-state whitelist against real artifact JSON.
echo "Scenario OWN-GUARD (d): gate-handoff refuses active gating, allows parked/terminal (re-fix stays dispatchable)"

# (d1) guard REFUSES when signal (d) reports an active artifact (seam DEFINES the bead).
OG_BEAD_JSON='[{"id":"wa-hoff","status":"open","assignee":"","labels":[],"metadata":{}}]'
_OG_D1="$(PILOT_TEST_GATE_ACTIVE_BEADS="wa-hoff" _og "wa-hoff" '{"id":"wa-hoff","assignee":"","status":"open","labels":[]}')"
[ "$_OG_D1" = "gating:active" ] && ok "OWN-GUARD(d1): active gate-handoff artifact REFUSED (reason: $_OG_D1)" \
                               || bad "OWN-GUARD(d1): active gate artifact NOT refused (got: '$_OG_D1') — dup-dispatch race open"

# (d2) guard ALLOWS when no active artifact (seam DEFINED but bead absent) → open+unassigned dispatches.
_OG_D2="$(PILOT_TEST_GATE_ACTIVE_BEADS="some-other" _og "wa-hoff" '{"id":"wa-hoff","assignee":"","status":"open","labels":[]}')"
[ -z "$_OG_D2" ] && ok "OWN-GUARD(d2): bead with no active gate artifact allowed (normal dispatch preserved)" \
                 || bad "OWN-GUARD(d2): non-gated bead wrongly refused (got: '$_OG_D2')"

# Function-level ACTIVE-state whitelist (real artifact JSON; seam unset → hits the jq path).
_GATE_FN="$(awk '/^_beadid_has_active_gate_artifact\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_gate() { (
    eval "$_GATE_FN"
    unset PILOT_TEST_GATE_ACTIVE_BEADS
    GC_CITY="ignored-city"
    bd() { case "$*" in *" list "*"source-bead:"*) printf '%s' "${GATE_ARTS_JSON:-}" ;; *) : ;; esac; }
    _beadid_has_active_gate_artifact "$1"
); }

# (d3) ACTIVE marker (reviewing) → gating (return 0).
GATE_ARTS_JSON='[{"id":"ga-w1","status":"open","labels":["type:quality-gate-marker","source-bead:wa-x","gate-status:reviewing"]}]'
_gate "wa-x" && ok "OWN-GUARD(d3): reviewing marker counts as ACTIVE gating" \
             || bad "OWN-GUARD(d3): reviewing marker missed — race would stay open"

# (d4) ACTIVE run (running) → gating (return 0).
GATE_ARTS_JSON='[{"id":"ga-w2","status":"open","labels":["type:quality-gate-run","source-bead:wa-x","gate-status:running"]}]'
_gate "wa-x" && ok "OWN-GUARD(d4): running gate-run counts as ACTIVE gating" \
             || bad "OWN-GUARD(d4): running run missed — race would stay open"

# (d5) RE-FIX loop: only a failed marker → NOT active → allow (MUST dispatch, the critical carve-out).
GATE_ARTS_JSON='[{"id":"ga-w3","status":"open","labels":["type:quality-gate-marker","source-bead:wa-x","gate-status:failed"]}]'
_gate "wa-x" && bad "OWN-GUARD(d5): failed marker wrongly ACTIVE — would DEADLOCK gate:needs-fix re-fix!" \
             || ok "OWN-GUARD(d5): failed marker NOT active → re-fix dispatch preserved (rig-scan/held-until intact)"

# (d6) errored marker → NOT active → allow (parked, re-dispatchable).
GATE_ARTS_JSON='[{"id":"ga-w4","status":"open","labels":["type:quality-gate-marker","source-bead:wa-x","gate-status:error"]}]'
_gate "wa-x" && bad "OWN-GUARD(d6): error marker wrongly ACTIVE — would strand recovery re-queue" \
             || ok "OWN-GUARD(d6): error marker NOT active → parked bead re-dispatchable"

# (d7) superseded/needs-rebase → NOT active → allow.
GATE_ARTS_JSON='[{"id":"ga-w5","status":"open","labels":["type:quality-gate-run","source-bead:wa-x","gate-status:superseded"]}]'
_gate "wa-x" && bad "OWN-GUARD(d7): superseded run wrongly ACTIVE" \
             || ok "OWN-GUARD(d7): superseded run NOT active → allowed"

# (d8) FAIL-OPEN: no artifacts at all → allow (a bad/empty gate read must never wedge dispatch).
GATE_ARTS_JSON='[]'
_gate "wa-x" && bad "OWN-GUARD(d8): empty gate read wrongly refused — would wedge dispatch" \
             || ok "OWN-GUARD(d8): empty gate artifact set → fail-open allow (dispatch never wedged)"

# Structural: signal (d) clause + its actively-processing whitelist live in the dispatcher source.
grep -qE 'gating:active' "$DISPATCHER" \
  && ok "OWN-GUARD: dispatcher carries the (d) gating:active clause" \
  || bad "OWN-GUARD: (d) gating:active clause missing from dispatcher"

# ── Scenario OWN-GUARD (e): attached-session live-mention (ga-48vb) ────────────
# Pilot's approved-story auto-dispatch and a live ATTACHED framework session
# (Mayor, or any other human-interactive session — pool workers/dogs are NEVER
# attached) deciding in-conversation to hand-implement the SAME story have no
# cross-visibility: the attached session's manual pickup never touches the bd
# bead's assignee/status at all. Concrete instance (2026-07-16, ga-n9bw): Mayor's
# attached session delegated implementation to a background subagent while Pilot
# independently dispatched a builder for the same story — zero bd footprint on
# Mayor's side, so signals (a)-(d) (all keyed off branch/assignee/status/gate-
# marker) were structurally blind to it. Signal (e) closes the gap with a
# heuristic (not authoritative) check: does a live attached session's recent
# output mention the candidate bead id?
echo "Scenario OWN-GUARD (e): guard refuses when an attached session's transcript mentions the candidate; allows otherwise"
_ATT_FN="$(awk '/^_beadid_mentioned_in_attached_session\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_og_e() { (
    eval "$_OG_FN"; eval "$_ATT_FN"
    SELF_BEAD_ID=""; _DEADWORKER_OK=1
    bd() { case "$*" in *" show "*) printf '%s' "${OG_BEAD_JSON:-}" ;; *) : ;; esac; }
    _beadid_has_crew_branch()          { return 1; }   # isolate (a)
    _beadid_has_active_gate_artifact() { return 1; }   # isolate (d)
    _session_is_live()                 { return 1; }   # isolate (b)/(c)
    _ownership_guard_should_refuse "$1" "$2" "ignored-db"
); }

# (e1) attached-session seam reports a mention → REFUSE.
OG_BEAD_JSON='[{"id":"wa-att","status":"open","assignee":"","labels":[],"metadata":{}}]'
_OG_E1="$(PILOT_TEST_ATTACHED_MENTION_BEADS="wa-att" _og_e "wa-att" '{"id":"wa-att","assignee":"","status":"open","labels":[]}')"
[ "$_OG_E1" = "attached-session:mention" ] && ok "OWN-GUARD(e1): attached-session mention REFUSED (reason: $_OG_E1)" \
                                            || bad "OWN-GUARD(e1): attached-session mention NOT refused (got: '$_OG_E1') — Mayor/Pilot double-dispatch reopened"

# (e2) seam defined but for a DIFFERENT bead → allow (normal dispatch preserved).
_OG_E2="$(PILOT_TEST_ATTACHED_MENTION_BEADS="some-other-bead" _og_e "wa-att" '{"id":"wa-att","assignee":"","status":"open","labels":[]}')"
[ -z "$_OG_E2" ] && ok "OWN-GUARD(e2): no attached-session mention allowed (normal dispatch preserved)" \
                 || bad "OWN-GUARD(e2): unmentioned bead wrongly refused (got: '$_OG_E2')"

# (e3) gate:needs-fix carve-out: same discipline as signal (a) (Scenario 22h /
# the ps-2w5d 40-min stall) — a noisy heuristic signal must not deadlock the
# autonomous gate-fix re-dispatch loop.
_OG_E3="$(PILOT_TEST_ATTACHED_MENTION_BEADS="wa-fix" _og_e "wa-fix" '{"id":"wa-fix","assignee":"","status":"open","labels":["gate:needs-fix"]}')"
[ -z "$_OG_E3" ] && ok "OWN-GUARD(e3): gate:needs-fix bead NOT refused despite attached-session mention (re-fix loop preserved)" \
                 || bad "OWN-GUARD(e3): gate:needs-fix bead wrongly refused (got: '$_OG_E3') — would reintroduce the ps-2w5d stall"

# (e4) control — same mention, WITHOUT gate:needs-fix → STILL refused (carve-out doesn't leak).
_OG_E4="$(PILOT_TEST_ATTACHED_MENTION_BEADS="wa-fix2" _og_e "wa-fix2" '{"id":"wa-fix2","assignee":"","status":"open","labels":["story:approved"]}')"
[ "$_OG_E4" = "attached-session:mention" ] && ok "OWN-GUARD(e4): non-needs-fix bead with a mention STILL refused (carve-out scoped correctly)" \
                                            || bad "OWN-GUARD(e4): carve-out over-applied to a non-needs-fix bead (got: '$_OG_E4')"

# Structural: signal (e) clause lives in the dispatcher source.
grep -qE 'attached-session:mention' "$DISPATCHER" \
  && ok "OWN-GUARD: dispatcher carries the (e) attached-session:mention clause" \
  || bad "OWN-GUARD: (e) attached-session:mention clause missing from dispatcher"

# ── Direct unit coverage: _beadid_mentioned_in_attached_session real matching ───
# The scenarios above drive (e) through its test seam only (composition test).
# These exercise the REAL cache + boundary-safe grep logic against fabricated
# session/peek data — no live gc, no live sessions, fully hermetic. Note:
# _gc_session_peek_output is stubbed directly (NOT the `gc` binary) because a
# `timeout <bin>` pipeline execs its argument directly and can't be intercepted
# by shadowing a shell function named after the binary.
echo "Scenario OWN-GUARD (e) unit: _beadid_mentioned_in_attached_session real matching logic"
_CACHE_FN="$(awk '/^_attached_session_peek_cache\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_ATT_FN2="$(awk '/^_beadid_mentioned_in_attached_session\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_attmention() { (
    eval "$_CACHE_FN"; eval "$_ATT_FN2"
    unset PILOT_TEST_ATTACHED_MENTION_BEADS
    GC_CITY="ignored-city"
    _SESSIONS_JSON="${ATT_SESSIONS_JSON:-{}}"
    _gc_session_peek_output() { printf '%s' "${ATT_PEEK_OUTPUT:-}"; }
    _beadid_mentioned_in_attached_session "$1"
); }

ATT_SESSIONS_JSON='{"sessions":[{"alias":"gastown.mayor","closed":false,"attached":true}]}'

# (u1) real match: peek output mentions the bead id as a whole token.
ATT_PEEK_OUTPUT="🔨 ga-n9bw (engine-window) — implementando agora."
_attmention "ga-n9bw" && ok "OWN-GUARD(e-unit1): real cache/grep matches a mentioned bead id" \
                      || bad "OWN-GUARD(e-unit1): real cache/grep missed a genuine mention — signal (e) is inert"

# (u2) no mention → allow.
ATT_PEEK_OUTPUT="nothing relevant here"
_attmention "ga-n9bw" && bad "OWN-GUARD(e-unit2): false-positive match with no mention present" \
                      || ok "OWN-GUARD(e-unit2): no mention → allowed (fail-open preserved)"

# (u3) boundary safety: a LONGER id sharing the same prefix must not false-match.
ATT_PEEK_OUTPUT="working on ga-n9bwx today"
_attmention "ga-n9bw" && bad "OWN-GUARD(e-unit3): substring false-match on a longer id (ga-n9bwx matched query ga-n9bw)" \
                      || ok "OWN-GUARD(e-unit3): longer id sharing a prefix does NOT false-match (boundary-safe)"

# (u4) boundary safety: the id as a suffix of a longer token must not false-match.
ATT_PEEK_OUTPUT="see xga-n9bw for context"
_attmention "ga-n9bw" && bad "OWN-GUARD(e-unit4): substring false-match on a longer token (xga-n9bw matched query ga-n9bw)" \
                      || ok "OWN-GUARD(e-unit4): id as a token suffix does NOT false-match (boundary-safe)"

# (u5) no ATTACHED sessions at all (e.g. only pool workers live) → fail-open allow,
# and the peek wrapper must never even be consulted.
ATT_SESSIONS_JSON='{"sessions":[{"alias":"wa-worker-adhoc-1","closed":false,"attached":false}]}'
ATT_PEEK_OUTPUT="ga-n9bw"
_attmention "ga-n9bw" && bad "OWN-GUARD(e-unit5): fired with zero attached sessions — should never peek a non-attached worker" \
                      || ok "OWN-GUARD(e-unit5): zero attached sessions → fail-open allow, no spurious peek"

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

# 4d: stale-sling liveness — a DEAD open sling (no branch, idle) must NOT block its bead's
# TTL-release / re-dispatch; a LIVE one (branch or fresh activity) must. The dead-builder
# HOL-block: ga-gbu87/ga-vp0c3 sat open 3 DAYS, no session/branch, blocking ga-wm12t/ga-a3lmo
# ("beads travadas em execução"). Both the TTL-release and the dedup guard now gate on this.
echo "Scenario 4d: _sling_is_live — dead open sling stops HOL-blocking, live one is kept"
_SIL_FN="$(awk '/^_sling_is_live\(\)/{g=1} g{print} g&&/^}$/{exit}' "$DISPATCHER")"
_sil() { ( eval "$_SIL_FN"; PILOT_TEST_DEAD_SLINGS="$1" _sling_is_live "$2" /tmp "" && echo LIVE || echo DEAD ); }
[ "$(_sil 'ga-dead' 'ga-dead')" = DEAD ] && ok "a dead sling → DEAD (releases the HOL-blocked bead)"     || bad "dead sling not detected"
[ "$(_sil 'ga-dead' 'ga-live')" = LIVE ] && ok "a sling not in the dead set → LIVE (kept, no false-release)" || bad "live sling misread as dead"
# inline grep (the `has` helper is defined later in the file, ~L1100 — not yet in scope here)
grep -qE '_sling_is_live\(\)'         "$DISPATCHER" && ok "_sling_is_live helper defined"                        || bad "_sling_is_live not defined"
grep -qE 'PILOT_STALE_SLING_SECONDS'  "$DISPATCHER" && ok "stale-sling idle window tunable (PILOT_STALE_SLING_SECONDS)" || bad "PILOT_STALE_SLING_SECONDS missing"
grep -qE 'DEAD sling .worker leaked'  "$DISPATCHER" && ok "TTL-release closes a dead sling + releases the claim"   || bad "TTL-release stale path missing"
grep -qE 'DEAD wrapper .worker leaked' "$DISPATCHER" && ok "dedup-guard closes a dead wrapper + dispatches fresh"  || bad "dedup-guard stale path missing"

# 4e: human-conversation protection — the dispatcher must NEVER pick a crew whose tmux session
# is ATTACHED (a human, ~always Athos, is conversing in it). 2026-06-22: a dispatch of wa-oxkg
# to peter-wa surfaced mid-conversation and hijacked Athos's thread. pick_pool_builder now skips
# an attached crew → the bead routes to a free peer or waits a sweep, never interrupts.
echo "Scenario 4e: a human-attached crew is never picked for dispatch (no conversation hijack)"
_CHE_FN="$(awk '/^_crew_session_human_engaged\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_che() { ( eval "$_CHE_FN"; PILOT_TEST_ATTACHED_CREWS="$1" _crew_session_human_engaged "$2" && echo ENGAGED || echo FREE ); }
[ "$(_che 'peter-wa thies-wa' 'peter-wa')" = ENGAGED ] && ok "an attached crew → ENGAGED (skipped from dispatch)"  || bad "attached crew not detected"
[ "$(_che 'peter-wa' 'mila-wa')" = FREE ]              && ok "a non-attached crew → FREE (still dispatchable)"     || bad "free crew misread as engaged"
grep -qE '_crew_session_human_engaged\(\)' "$DISPATCHER" && ok "_crew_session_human_engaged helper defined"        || bad "helper missing"
[ "$(grep -cE '_crew_session_human_engaged "\$crew" && continue' "$DISPATCHER")" -ge 2 ] && ok "engaged-skip wired in BOTH pick_pool_builder loops" || bad "engaged-skip not wired in both loops"

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

# ── Scenario 5c/5d: pre-dispatch freshness re-check (ga-88g2) ──────────────────
# The ga-w5agg 9th-dispatch incident: the ga-zzrts claim-verify (Scenario 5's own
# happy path) passes clean, but gate:needs-human lands on the SAME bead later,
# during builder-target resolution — well before the actual sling/nudge. Without
# a re-check immediately before dispatch, Pilot sails through and dispatches a
# builder onto a bead the circuit breaker already parked for a human. The fix
# adds exactly that re-check; these scenarios prove it fails-before/passes-after.
echo "Scenario 5c: gate:needs-human landing mid-dispatch aborts BEFORE a builder is dispatched (ga-88g2)"

# 5c: escalation injected after the 1st `bd show` (the ga-zzrts claim-verify) —
# i.e. exactly the ga-w5agg race: clean at claim-verify time, escalated after.
LOG5C="$(run_real_dispatch_escalate 1)"
if echo "$LOG5C" | grep -q "ga-88g2:.*tt-flight now has gate:needs-human"; then
  ok "pre-dispatch re-check detected the mid-dispatch escalation and logged it"
else
  bad "REGRESSION: no ga-88g2 pre-dispatch re-check fired — the race is unguarded (would dispatch onto a circuit-broken bead, as ga-w5agg's 9th dispatch did)"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  bad "REGRESSION: story:in-flight was set despite the mid-dispatch escalation — the builder dispatch was NOT stopped"
else
  ok "story:in-flight was never set — dispatch correctly aborted before finalization"
fi
if echo "$LOG5C" | grep -q "Dispatch complete:"; then
  bad "REGRESSION: dispatch completed (builder notified) despite the mid-dispatch escalation"
else
  ok "no builder was notified — aborted before the sling/nudge step"
fi

# 5d: control — no escalation injected (FAKE_ESCALATE_AFTER_SHOWS unset) → the
# new re-check must be a pure no-op on the ordinary happy path (no false positive).
echo "Scenario 5d: control — no escalation → new re-check never false-positives (ga-88g2)"
LOG5D="$(run_real_dispatch_escalate "")"
if echo "$LOG5D" | grep -q "ga-88g2:"; then
  bad "REGRESSION: pre-dispatch re-check fired with no escalation injected (false positive)"
else
  ok "no false positive — re-check stayed silent on the plain happy path"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  ok "story:in-flight still set normally when nothing escalated"
else
  bad "REGRESSION: adding the re-check broke the ordinary happy-path dispatch"
fi

# ── Scenario 5e/5f/5g: Mayor out-of-band hold grace window (ga-pd7j) ─────────
# The ga-z6uo/ga-06um incident: Pilot auto-redispatches a gate:needs-fix bead
# once pilot:held/held-until is absent, but the Mayor's hold-disposition
# comment can land in the SAME builder-target-resolution window this suite
# already covers for label-based escalations (5c/5d above) — just via a
# comment instead of a label. These scenarios prove the new grace-window
# check defers dispatch on a fresh gastown__mayor comment, and stays silent
# otherwise (no comments; an old Mayor comment; a fresh non-Mayor comment).
echo "Scenario 5e: fresh gastown__mayor comment on a gate:needs-fix bead defers dispatch (ga-pd7j)"

_MH_NOW=$(date +%s)
_MH_RECENT=$(date -u -r $(( _MH_NOW - 30 )) +%Y-%m-%dT%H:%M:%SZ)
_MH_OLD=$(date -u -r $(( _MH_NOW - 3600 )) +%Y-%m-%dT%H:%M:%SZ)

LOG5E="$(run_real_dispatch_mayorhold "[{\"author\":\"gastown__mayor\",\"text\":\"HOLD: engine-window disposition\",\"created_at\":\"$_MH_RECENT\"}]" 300)"
if echo "$LOG5E" | grep -q "ga-pd7j:.*tt-flight is gate:needs-fix with a gastown__mayor comment"; then
  ok "pre-dispatch re-check detected the fresh Mayor comment and logged it"
else
  bad "REGRESSION: no ga-pd7j Mayor-hold check fired — a fresh out-of-band hold would be raced onto a builder"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  bad "REGRESSION: story:in-flight was set despite the fresh Mayor comment — the builder dispatch was NOT stopped"
else
  ok "story:in-flight was never set — dispatch correctly deferred before finalization"
fi
if echo "$LOG5E" | grep -q "Dispatch complete:"; then
  bad "REGRESSION: dispatch completed (builder notified) despite the fresh Mayor comment"
else
  ok "no builder was notified — deferred before the sling/nudge step"
fi

echo "Scenario 5f: control — no comments at all → new re-check never false-positives (ga-pd7j)"
LOG5F="$(run_real_dispatch_mayorhold "" 300)"
if echo "$LOG5F" | grep -q "ga-pd7j:"; then
  bad "REGRESSION: Mayor-hold re-check fired with no comments injected (false positive)"
else
  ok "no false positive — re-check stayed silent with no comments present"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  ok "story:in-flight still set normally when no Mayor comment is present"
else
  bad "REGRESSION: adding the Mayor-hold re-check broke the ordinary gate:needs-fix happy path"
fi

echo "Scenario 5g: control — old Mayor comment + fresh non-Mayor comment → still no false positive (ga-pd7j)"
LOG5G="$(run_real_dispatch_mayorhold "[{\"author\":\"gastown__mayor\",\"text\":\"old disposition\",\"created_at\":\"$_MH_OLD\"},{\"author\":\"dog-abc123\",\"text\":\"status update\",\"created_at\":\"$_MH_RECENT\"}]" 300)"
if echo "$LOG5G" | grep -q "ga-pd7j:"; then
  bad "REGRESSION: Mayor-hold re-check fired on a stale Mayor comment / fresh non-Mayor comment (false positive)"
else
  ok "no false positive — re-check correctly ignores expired Mayor comments and non-Mayor authors"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  ok "story:in-flight still set normally when no IN-WINDOW Mayor comment is present"
else
  bad "REGRESSION: old-Mayor/fresh-non-Mayor comments incorrectly blocked dispatch"
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

# Scenario 10b: REGRESSION (2026-06-22 overnight pipeline stall). Latency is the AUTHORITATIVE
# health signal — high Dolt CPU with HEALTHY latency must NOT read as saturated. Chronic CPU
# 150-303% (amplified by memory pressure) was false-tripping the old cpu>200 ceiling → the
# Pilot throttled ALL dispatch to 0 for hours → nothing built/gated/delivered overnight.
echo "Scenario 10b: high CPU + healthy latency → NOT saturated (latency authoritative)"
_DS_FN="$(awk '/^_dolt_cpu\(\)/{c=1} c{print} c&&/^}$/{c=0} /^_dolt_saturated\(\)/{s=1} s{print} s&&/^}$/{exit}' "$DISPATCHER")"
_ds() { ( eval "$_DS_FN"; PILOT_DOLT_LATENCY_MAX_MS=2500; PILOT_DOLT_CPU_MAX=200; \
          DOLT_LATENCY_MS="$1" PILOT_DOLT_CPU_OVERRIDE="$2" _dolt_saturated && echo SAT || echo OK ); }
[ "$(_ds 62 303)" = OK ]   && ok "lat=62ms cpu=303% → healthy (the exact overnight bug, fixed)" || bad "lat=62 cpu=303 still SATURATED (bug)"
[ "$(_ds 3000 50)" = SAT ] && ok "lat=3000ms → saturated (real storm still caught)"             || bad "high latency not caught"
[ "$(_ds '' 303)" = SAT ]  && ok "latency blind + cpu=303% → saturated (CPU fallback)"          || bad "CPU fallback broken"
[ "$(_ds '' '')" = SAT ]   && ok "both probes blind → saturated (fail-safe)"                    || bad "fail-safe broken"

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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
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

echo "Scenario 15a: 5 WA bugs — 4 dispatch to distinct wa-worker slots, 5th defers (4-slot pool)"
# pilot-rewire: WA pool has 4 virtual slots (wa-worker-1..4) all mapping to the wa-worker
# template. 5 bugs → 4 dispatches fill all slots → 5th correctly defers.
LOG15A="$(run_capacity 10 "[]" 1 "$WA_FIVE_BUGS")"
B15A="$(builders_of "$LOG15A")"
TOTAL15A=$(echo "$B15A" | grep -c .)
DISTINCT15A=$(echo "$B15A" | sort -u | grep -c .)
if [ "$TOTAL15A" -ge 4 ] && [ "$DISTINCT15A" -ge 4 ]; then
  ok "4 dispatches went to 4 distinct wa-worker slots (total=$TOTAL15A distinct=$DISTINCT15A)"
else
  bad "REGRESSION: WA work not distributed to 4 slots (total=$TOTAL15A distinct=$DISTINCT15A — slot exhaustion not working?)"
fi
if echo "$B15A" | grep -qvE '^wa-worker-[0-9]+$'; then
  bad "a dispatch targeted a non-wa-worker-slot builder: $(echo "$B15A" | grep -vE '^wa-worker-[0-9]+$' | tr '\n' ' ')"
else
  ok "every dispatch targeted a wa-worker-N slot (pilot-rewire: ephemeral pool)"
fi
if [ "$TOTAL15A" -le 4 ]; then
  ok "5th WA bug deferred (all 4 slots exhausted — correct slot-based backpressure)"
else
  bad "REGRESSION: more than 4 dispatches in one sweep (total=$TOTAL15A — slot limit not enforced)"
fi

echo "Scenario 15b: non-pooled rig unchanged — gascity bugs still route to gastown.dog"
LOG15B="$(run_capacity 10 "[]" 1 "$FIVE_SMALL_BUGS")"
B15B="$(builders_of "$LOG15B")"
if [ "$(echo "$B15B" | grep -c .)" -ge 5 ] && [ -z "$(echo "$B15B" | grep -vE '^gastown\.dog$')" ]; then
  ok "all gascity dispatches still target gastown.dog (no regression)"
else
  bad "REGRESSION: gascity routing changed (got: $(echo "$B15B" | sort -u | tr '\n' ' '))"
fi

echo "Scenario 15c: WA pool (wa-worker slots) is NOT blocked by named-crew busy-set"
# pilot-rewire: PILOT_BUSY_BUILDERS tracks named crew but wa-worker-N slots are not named crew.
# Even when digo-wa has live in-flight work, wa-worker-1 is always available (the busy-set
# for named crew does not block the ephemeral pool).
NOW_ISO15="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INFLIGHT15C="[{\"id\":\"if-digo\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-digo\"}}]"
SESSIONS15C='{"sessions":[{"session_name":"digo-wa","closed":false}]}'
SLINGMAP15C='{"tt-sling-digo":"digo-wa"}'
WA_ONE_BUG='[{"id":"tt-wax","title":"wa bug x","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG15C="$(run_capacity 10 "$INFLIGHT15C" 1 "$WA_ONE_BUG" "$SESSIONS15C" "$SLINGMAP15C")"
B15C="$(builders_of "$LOG15C")"
if echo "$LOG15C" | grep -q "Busy builders (live in-flight): digo-wa"; then
  ok "busy-builder set still computed from live in-flight work (digo-wa busy)"
else
  bad "did not compute/log the busy-builder set (expected 'Busy builders (live in-flight): digo-wa')"
fi
if echo "$B15C" | grep -qE '^wa-worker-[0-9]+$'; then
  ok "WA bug dispatched to wa-worker slot ($B15C) — named-crew busy-set does not block ephemeral pool"
elif [ -z "$B15C" ]; then
  bad "WA bug deferred (wa-worker slot available but not dispatched — pool routing broken?)"
else
  bad "WA bug dispatched to unexpected target: '$B15C' (expected wa-worker-N)"
fi

echo "Scenario 15d: slot-based backpressure — 4 slots exhausted → 5th WA bug defers"
# pilot-rewire: the wa-worker pool has 4 virtual slots. Within one sweep, each slot
# can be used ONCE (PILOT_USED_BUILDERS). After 4 dispatches, the 5th WA bug must
# defer — even though there is still lane capacity. Run with WA_FIVE_BUGS to prove this.
LOG15D="$(run_capacity 10 "[]" 1 "$WA_FIVE_BUGS")"
B15D="$(builders_of "$LOG15D")"
TOTAL15D=$(echo "$B15D" | grep -c . 2>/dev/null || echo 0)
if [ "$TOTAL15D" -le 4 ]; then
  ok "at most 4 WA dispatches in one sweep (slot-based backpressure enforced; total=$TOTAL15D)"
else
  bad "REGRESSION: $TOTAL15D WA dispatches in one sweep — 4-slot per-sweep limit not enforced"
fi
DISTINCT15D=$(echo "$B15D" | sort -u | grep -c . 2>/dev/null || echo 0)
if [ "$DISTINCT15D" -eq "$TOTAL15D" ] && [ "$TOTAL15D" -gt 0 ]; then
  ok "each dispatch used a DISTINCT slot ($DISTINCT15D unique slots — no slot reused in sweep)"
else
  bad "slot uniqueness broken (total=$TOTAL15D distinct=$DISTINCT15D — same slot reused?)"
fi

echo "Scenario 15f: WA dispatch goes to wa-worker slot regardless of named-crew session_name in busy-set"
# pilot-rewire: named crew (e.g. digo-wa) with a session_name-form assignee in the sling-map
# is still computed into PILOT_BUSY_BUILDERS — but the WA pool no longer contains named crew.
# The WA bug must dispatch to a wa-worker slot; the digo-wa busy-set is irrelevant.
INFLIGHT15F="[{\"id\":\"if-digo2\",\"labels\":[\"story:in-flight\",\"lane:small\"],\"updated_at\":\"$NOW_ISO15\",\"metadata\":{\"pilot.sling_bead\":\"tt-sling-digo2\"}}]"
SESSIONS15F='{"sessions":[{"session_name":"digo-wa-gawispcze4o4","name":"digo-wa","alias":"digo-wa","id":"ga-wisp-cze4o4","agent_name":"digo-wa","closed":false}]}'
SLINGMAP15F='{"tt-sling-digo2":"digo-wa-gawispcze4o4"}'
LOG15F="$(run_capacity 10 "$INFLIGHT15F" 1 "$WA_ONE_BUG" "$SESSIONS15F" "$SLINGMAP15F")"
B15F="$(builders_of "$LOG15F")"
if echo "$B15F" | grep -qE '^wa-worker-[0-9]+$'; then
  ok "WA bug dispatched to wa-worker slot ($B15F) — digo-wa session_name busy-set irrelevant to ephemeral pool"
elif [ -z "$B15F" ]; then
  bad "WA bug deferred when a wa-worker slot is available — pool routing broken"
else
  bad "WA bug went to unexpected target: '$B15F' (expected wa-worker-N)"
fi

echo "Scenario 15e: drift-guard — pool routing + selection wired into the live dispatcher"
has "$DISPATCHER" 'rig_to_builders\(\)'                                     "rig_to_builders pool function is defined"
has "$DISPATCHER" 'wa-worker-1 wa-worker-2 wa-worker-3 wa-worker-4'        "WA rig maps to 4 wa-worker slots (pilot-rewire)"
has "$DISPATCHER" 'wa_worker_template\(\)'                                  "wa_worker_template slot→template mapping function is defined"
has "$DISPATCHER" 'pick_pool_builder\(\)'                                   "idle-crew selection function is defined"
has "$DISPATCHER" 'PILOT_BUSY_BUILDERS'                                     "busy-builder exclusion set is wired"

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

# ── ga-mfeip owner-grace: a live crew that OWNS but NEVER STARTED a bead (no branch),
# past the owner-grace window, with proof the crew progressed ELSEWHERE, is RELEASED
# (it was declined/skipped, not slow-built). Without that proof, or within the grace
# window, it is KEPT — the conservative default that protects a genuinely slow build.
NS_VERYOLD="$((NS_NOW - 90000))"   # 25h old → past the 24h owner-grace window

# 16o: aged>24h + no branch + live crew owner + owner progressed elsewhere → RELEASE.
NS_OG='[{"id":"tt-ns-ograce","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_VERYOLD"'"}}]'
LOG16O="$(run_neverstarted "$NS_OG" "" "$NS_CREW_SESS" '{"tt-ns-ograce":"batista-ps"}' "batista-ps")"
echo "Scenario 16o: owner-grace releases a never-started owned bead whose crew progressed elsewhere"
if echo "$LOG16O" | grep -q "releasing never-started in-flight bead tt-ns-ograce"; then
  ok "owner-grace: aged>24h + no branch + owner pushed other branches → released (ga-mfeip)"
else
  bad "owner-grace did NOT release a 25h-stale never-started owned bead whose crew progressed"
fi

# 16p: same but the owner has NOT progressed elsewhere → KEEP (may be slow-building).
NS_OG2='[{"id":"tt-ns-ograce2","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_VERYOLD"'"}}]'
LOG16P="$(run_neverstarted "$NS_OG2" "" "$NS_CREW_SESS" '{"tt-ns-ograce2":"batista-ps"}' "")"
echo "Scenario 16p: owner-grace KEEPS when the crew shows no progress elsewhere (conservative)"
if echo "$LOG16P" | grep -q "releasing never-started in-flight bead tt-ns-ograce2"; then
  bad "REGRESSION: released an owned bead with NO skip-proof (crew not progressed) — false-reclaim risk"
else
  ok "owner-grace KEEPS the bead when the crew has not progressed elsewhere (slow-build safe)"
fi

# 16q: aged only 1h (< owner-grace) even with progress proof → KEEP (age gates it).
NS_OG3='[{"id":"tt-ns-ograce3","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
LOG16Q="$(run_neverstarted "$NS_OG3" "" "$NS_CREW_SESS" '{"tt-ns-ograce3":"batista-ps"}' "batista-ps")"
echo "Scenario 16q: owner-grace KEEPS a bead still within the grace window (age gates the release)"
if echo "$LOG16Q" | grep -q "releasing never-started in-flight bead tt-ns-ograce3"; then
  bad "REGRESSION: released an owned bead aged only 1h (< 24h owner-grace) — premature reclaim"
else
  ok "owner-grace KEEPS a bead within the grace window even with progress proof (age gates it)"
fi

# 16r: structural — the knob + skip-proof helper are wired.
echo "Scenario 16r: owner-grace knob + skip-proof helper are wired (ga-mfeip)"
has "$DISPATCHER" 'PILOT_NEVERSTARTED_OWNER_GRACE_HOURS' "owner-grace window knob defined"
has "$DISPATCHER" '_crew_progressed_since()' "_crew_progressed_since skip-proof helper defined"
has "$DISPATCHER" 'owner-grace' "owner-grace release path wired into the never-started detector"

# 16r1 (ga-l7pp, ga-kuuk double-dispatch): an UNCLAIMED sling (no assignee — it is
# sitting QUEUED in its target pool, e.g. a backlogged gastown.dog) that is still
# fresh/live must NOT be released. Before this fix, the only guard on a
# sling-bearing bead was the live-SESSION check, which requires a non-empty
# assignee — an unclaimed sling fell through untouched and got released, which
# unsets pilot.sling_bead and ORPHANS the still-queued sling bead. The very next
# sweep then dispatches a fresh SIBLING sling for the same story — this is
# exactly what happened to ga-k4uh (5 sling beads in ~3h; two claimed by two
# different dogs within 46s of each other).
echo "Scenario 16r1 (ga-l7pp): an unclaimed-but-fresh sling is KEPT, not released"
NS_QUEUED='[{"id":"tt-ns-queued","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-queued"}}]'
LOG16R1="$(run_neverstarted "$NS_QUEUED" "" "$NS_SESS" "" "" "" "" "" "")"
if echo "$LOG16R1" | grep -q "releasing never-started in-flight bead tt-ns-queued"; then
  bad "REGRESSION (ga-l7pp): released a story whose sling is unclaimed but still queued/fresh — orphans the sling, mints a sibling (ga-kuuk double-dispatch mechanism)"
else
  ok "unclaimed-but-fresh sling is kept (pool hasn't served it yet, not abandoned)"
fi

# 16r2 (ga-l7pp): an UNCLAIMED sling that IS genuinely stale (idle past the SAME
# STALE_SLING_SECONDS window the dispatch-time dedup guard uses, no branch) is a
# real orphan — release the story, but ALSO close the orphaned sling bead itself
# so it can never be independently claimed after the story starts over.
echo "Scenario 16r2 (ga-l7pp): an unclaimed-and-stale sling releases the story AND closes the orphan"
NS_QUEUED_STALE='[{"id":"tt-ns-queued-stale","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-queued-stale"}}]'
LOG16R2="$(run_neverstarted "$NS_QUEUED_STALE" "" "$NS_SESS" "" "" "" "" "" "tt-sling-queued-stale")"
if echo "$LOG16R2" | grep -q "releasing never-started in-flight bead tt-ns-queued-stale"; then
  ok "unclaimed-and-stale sling is released (genuine orphan, pool never served it)"
else
  bad "REGRESSION (ga-l7pp): did NOT release a genuinely stale unclaimed-sling never-started bead"
fi
if echo "$LOG16R2" | grep -q "tt-sling-queued-stale is unclaimed AND stale"; then
  ok "orphaned stale sling is closed before the story releases (no lingering claimable duplicate)"
else
  bad "REGRESSION (ga-l7pp): released the story but did NOT close the orphaned stale sling bead"
fi

# 16r3 (ga-l7pp): control — parity with pre-fix 16h. An unclaimed sling still KEEPS
# when the session roster is untrustworthy, now via the staleness check rather
# than the _DEADWORKER_OK gate (roster trust is irrelevant when there is no
# assignee whose session liveness needs checking).
echo "Scenario 16r3 (ga-l7pp): unclaimed sling still kept when roster is untrustworthy (parity with 16h)"
NS_QUEUED_UNTRUST='[{"id":"tt-ns-queued-untrust","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-queued-untrust"}}]'
LOG16R3="$(run_neverstarted "$NS_QUEUED_UNTRUST" "" "" "" "" "" "" "" "")"
if echo "$LOG16R3" | grep -q "releasing never-started in-flight bead tt-ns-queued-untrust"; then
  bad "REGRESSION (ga-l7pp): released an unclaimed-sling bead while the roster was untrustworthy"
else
  ok "unclaimed-but-fresh sling kept even when roster is untrustworthy (fail-open by default)"
fi

# 16i: PILOT_NEVERSTARTED_MINUTES=0 fully disables the detector.
echo "Scenario 16i: PILOT_NEVERSTARTED_MINUTES=0 disables the detector"
: > "$FIXCITY/.gc/logs/pilot-dispatcher.log"; reset_state
env -i PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" HOME="$HOME" DRY_RUN=1 \
  PILOT_CITY_OVERRIDE="$FIXCITY" PILOT_TEST_STATE="$STATE" \
  PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
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

echo "Scenario 17b: data bug (email/financeiro/enrichment) dispatched to wa-worker pool (digo-wa no longer in pool)"
# pilot-rewire: domain prefer for digo-wa is now a no-op because digo-wa is not in the
# wa-worker pool. Data bugs dispatch to a wa-worker slot (not held for digo-wa).
DATA_BUILDER="$(builder_for_domain "$LOG17" data)"
if echo "$DATA_BUILDER" | grep -qE '^wa-worker-[0-9]+$'; then
  ok "data bug dispatched to wa-worker slot ($DATA_BUILDER) — domain prefer no-op for ephemeral pool"
elif [ -z "$DATA_BUILDER" ]; then
  bad "data bug was not dispatched (no domain=data Builder target line)"
else
  bad "data bug went to unexpected target: '${DATA_BUILDER:-none}' (expected wa-worker-N)"
fi

echo "Scenario 17c: both frontend and data WA bugs go to distinct wa-worker slots (no domain pinning)"
# pilot-rewire: with ephemeral pool, both frontend and data bugs pick from the same
# wa-worker-1..4 rotation. Domain routing (prefer/exclude) is a no-op for the new pool.
if [ -n "$FE_BUILDER" ] && [ -n "$DATA_BUILDER" ] && [ "$FE_BUILDER" != "$DATA_BUILDER" ]; then
  ok "frontend and data bugs dispatched to distinct wa-worker slots (frontend→$FE_BUILDER, data→$DATA_BUILDER)"
elif [ -n "$FE_BUILDER" ] && [ -n "$DATA_BUILDER" ] && [ "$FE_BUILDER" = "$DATA_BUILDER" ]; then
  bad "frontend and data bugs dispatched to SAME slot ($FE_BUILDER) — per-sweep slot uniqueness broken"
else
  bad "domain routing incomplete (frontend='${FE_BUILDER:-none}', data='${DATA_BUILDER:-none}')"
fi

echo "Scenario 17d: unknown-domain WA bug dispatched to wa-worker slot (FAIL-OPEN, no over-steer)"
WA_UNKNOWN='[{"id":"tt-waunk","title":"wa generic bug with no area signal","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG17D="$(run_capacity 10 "[]" 1 "$WA_UNKNOWN")"
UNK_BUILDER="$(builders_of "$LOG17D")"
if echo "$UNK_BUILDER" | grep -qE '^wa-worker-[0-9]+$'; then
  ok "unknown-domain WA bug dispatched to wa-worker slot ($UNK_BUILDER) — fail-open, pool rotation"
elif [ -z "$UNK_BUILDER" ]; then
  bad "unknown-domain WA bug not dispatched (wa-worker slot available but not taken)"
else
  bad "unknown-domain WA bug went to unexpected target: '${UNK_BUILDER:-none}'"
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

# Scenario 17f: real-estate routes to peter + EXCLUDES oracle (the wa-nvn9/wa-o65d loop —
# property enrichment round-robined to oracle, a warming crew; oracle released, Pilot re-grabbed).
echo "Scenario 17f: real-estate → peter + exclude oracle; warming → oracle (owner-domain routing)"
_BD_FN="$(awk '/^bead_domain\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_RO_FN="$(awk '/^rig_domain_owner\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_RE_FN="$(awk '/^rig_domain_exclude\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_dom() { ( eval "$_BD_FN"; bead_domain "$1" ); }
_own() { ( eval "$_RO_FN"; rig_domain_owner whatsapp_automation "$1" ); }
_exc() { ( eval "$_RE_FN"; rig_domain_exclude whatsapp_automation "$1" ); }
RE_BEAD='{"title":"enriquecer deals/imóveis fora de BH com geometria+zoneamento do ArcGIS","description":"funil imovel-to-campanha + quarteirao_map"}'
WARM_BEAD='{"title":"aquecimento de chip novo no grupo","description":"on-device send"}'
[ "$(_dom "$RE_BEAD")" = real-estate ]          && ok "ArcGIS/imóvel enrichment → real-estate (not data→digo)" || bad "real-estate misclassified: '$(_dom "$RE_BEAD")'"
[ "$(_own real-estate)" = peter-wa ]            && ok "real-estate prefers peter-wa"                            || bad "real-estate owner wrong: '$(_own real-estate)'"
echo "$(_exc real-estate)" | grep -q oracle-wa  && ok "real-estate EXCLUDES oracle-wa (kills the loop oracle reported)" || bad "real-estate does not exclude oracle"
# wa-nvn9 root: peter-wa human-engaged → pool rotation picked thies-wa (not excluded). thies owns
# the satmap/visual layer only; peter owns the ArcGIS/zoneamento/imóvel enrichment pipeline.
echo "$(_exc real-estate)" | grep -q thies-wa  && ok "real-estate EXCLUDES thies-wa (wa-nvn9 misroute to thies when peter human-engaged)" || bad "real-estate does not exclude thies-wa"
# Confirm the wa-nvn9 title/description keywords (geometria+zoneamento+ArcGIS+quarteirao_map) classify real-estate.
NVNBEAD='{"title":"Contagem: enriquecer deals/imóveis fora de BH com geometria+zoneamento do ArcGIS (plugar no funil imovel-to-campanha + quarteirao_map)","description":"API ArcGIS pública de Contagem sem auth, f=geojson."}'
[ "$(_dom "$NVNBEAD")" = real-estate ]          && ok "wa-nvn9 exact title (geometria+zoneamento+ArcGIS+quarteirao_map) → real-estate" || bad "wa-nvn9 bead misclassified: '$(_dom "$NVNBEAD")'"
[ "$(_dom "$WARM_BEAD")" = warming ]            && ok "chip/aquecimento → warming"                              || bad "warming misclassified: '$(_dom "$WARM_BEAD")'"
[ "$(_own warming)" = oracle-wa ]               && ok "warming prefers oracle-wa"                               || bad "warming owner wrong: '$(_own warming)'"

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
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
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

# pilot-rewire: wa-worker-* and ps-worker are ephemeral (like gastown.dog) → excluded
# from session reuse. Use a ga-* HQ bug with property_scrapers content keywords so the
# domain guard routes it to batista-ps (a persistent named crew) to test the REUSE
# mechanism, which only applies to non-ephemeral crew identities.
GT4_PS_BUG='[{"id":"ga-gt4ps","title":"Mapear proprietarios falecidos scraper RFB (semanal)","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}]'
GT4_WA_BUG='[{"id":"tt-gt4wa","title":"gt-4st3n wa bug","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{"story.rig":"whatsapp_automation"}}]'
GT4_GC_BUG='[{"id":"tt-gt4gc","title":"gt-4st3n gascity bug","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}]'
GT4_SESS_ACTIVE='{"sessions":[{"session_name":"batista-ps","alias":"batista-ps","agent_name":"batista-ps","id":"ga-wisp-batista","state":"active","closed":false}]}'
GT4_SESS_ASLEEP='{"sessions":[{"session_name":"batista-ps","alias":"batista-ps","agent_name":"batista-ps","id":"ga-wisp-batista","state":"asleep","closed":false}]}'
GT4_SESS_NONE='{"sessions":[]}'
GT4_SESS_DOG='{"sessions":[{"session_name":"dog-1","alias":"gastown.dog-1","agent_name":"gastown.dog-1","id":"ga-wisp-dog1","state":"active","closed":false}]}'

echo "Scenario 17a: ACTIVE crew session → REUSE (hook + follow_up submit), never spawn/interrupt"
# Uses a PS bug → routes to batista-ps (persistent crew, reuse applies).
# wa-worker-* are ephemeral (like gastown.dog) → excluded from reuse.
LOG17A="$(run_capacity_reuse 1 "$GT4_PS_BUG" "$GT4_SESS_ACTIVE")"
if echo "$LOG17A" | grep -qE "REUSE\(gt-4st3n\): batista-ps has an existing active session"; then
  ok "classified the active crew session for reuse (no 2nd spawn)"
else
  bad "did not classify the active session for reuse (expected REUSE(gt-4st3n) … batista-ps … active)"
fi
if echo "$LOG17A" | grep -qE "WOULD: gc session submit batista-ps .* --intent follow_up"; then
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
LOG17B="$(run_capacity_reuse 1 "$GT4_PS_BUG" "$GT4_SESS_ASLEEP")"
if echo "$LOG17B" | grep -qE "REUSE\(gt-4st3n\): batista-ps has an existing asleep session"; then
  ok "classified the asleep crew session for reuse"
else
  bad "did not classify the asleep session for reuse (expected REUSE(gt-4st3n) … batista-ps … asleep)"
fi
if echo "$LOG17B" | grep -qE "WOULD: gc session wake batista-ps"; then
  ok "wakes the existing asleep session (no parallel spawn)"
else
  bad "did not wake the existing asleep session"
fi
if echo "$LOG17B" | grep -qE "WOULD: gc session submit batista-ps .* --intent follow_up"; then
  ok "asleep path also delivers via non-interrupting follow_up submit"
else
  bad "asleep path did not choose follow_up submit"
fi

echo "Scenario 17c: NO existing session → spawn is correct (legacy sling path), no REUSE"
LOG17C="$(run_capacity_reuse 1 "$GT4_PS_BUG" "$GT4_SESS_NONE")"
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
# Use a PS bug (batista-ps — persistent crew, reuse applies when flag=1).
# With flag=0, reuse must not fire even for persistent crew.
LOG17E="$(run_capacity_reuse 0 "$GT4_PS_BUG" "$GT4_SESS_ACTIVE")"
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
# The reuse gate: PILOT_REUSE_SESSION=1 AND NOT an ephemeral pool target.
# pilot-rewire: wa-worker-* and gastown.dog are ephemeral → _skip_reuse=1 → exempt.
if grep -q '_skip_reuse' "$DISPATCHER" && grep -qE 'gastown\.dog.*wa-worker' "$DISPATCHER"; then
  ok "reuse gate uses _skip_reuse flag; gastown.dog and wa-worker excluded (pilot-rewire)"
else
  bad "reuse gate structure changed — _skip_reuse or ephemeral exclusion missing"
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

# Scenario 18j (batista-ps 2026-06-22): painel/kanban/dashboard beads carry property nouns
# (they DISPLAY property data, and "contagem"=count reads as the city Contagem) so they were
# misrouting to property_scrapers. The painel UI is mila's (WA) domain — property_scrapers
# builds the SCRAPERS, not the UI. bead_content_rig's WA precedence now includes painel/kanban.
echo "Scenario 18j: painel/kanban dashboard → whatsapp_automation, not property_scrapers (ga-wm12t)"
_BCR_FN="$(awk '/^bead_content_rig\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_bcr() { ( eval "$_BCR_FN"; bead_content_rig "$1" ); }
WM='{"title":"Dashboard: multi-rig kanban + filter pills por rig/tipo com contagem","description":"painel.urblink.com.br"}'
PROP='{"title":"Scraper de cadastro ITBI de imóveis e lotes em Contagem","description":"consolidar MotherDuck"}'
HEXD='{"title":"Hex notebook dashboard de lotes/proprietários","description":"RFB CNPJ"}'
[ "$(_bcr "$WM")" = whatsapp_automation ] && ok "ga-wm12t kanban/painel dashboard → whatsapp_automation (misroute fixed)"    || bad "painel dashboard still misroutes: '$(_bcr "$WM")'"
[ "$(_bcr "$PROP")" = property_scrapers ] && ok "genuine ITBI/lote scraper still → property_scrapers (no regression)"        || bad "property scraper broke: '$(_bcr "$PROP")'"
[ "$(_bcr "$HEXD")" = property_scrapers ] && ok "Hex-notebook dashboard (no painel/kanban) stays property_scrapers (edge safe)" || bad "Hex dashboard over-caught: '$(_bcr "$HEXD")'"

# ── Scenario 18k (ga-nlh79): OWNER-AUTHORITATIVE rig precedence ────────────────
# A ga-* bead whose created_by is a *-wa crew must route to whatsapp_automation
# even when the bead title/description contains property-vocabulary nouns (ITBI,
# Contagem, Hex) that would otherwise trigger property_scrapers in bead_content_rig.
# This is the ga-wuzeg/ga-nq64a/ga-lt8cw/wa-86jr root: the *-wa OWNER is more
# authoritative than keyword inference — the creator IS the domain signal.
# Also verifies: a genuine property bead (created_by=batista-ps) still → property.
echo "Scenario 18k (ga-nlh79): *-wa owner → whatsapp_automation BEFORE content inference"
# Fixture: ga-* bead, created_by=batista-wa, title mentions ITBI/Contagem (property nouns)
WA_OWNER_ITBI='[{"id":"ga-wuztest","title":"Contagem cadastre bulk-load via ITBI bridge — code-mode MCP servers","priority":3,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_by":"batista-wa","created_at":"2026-06-01T00:00:01Z","metadata":{}}]'
LOG18K="$(run_capacity 10 "[]" 1 "$WA_OWNER_ITBI")"
B18K="$(dispatched_builder "$LOG18K")"
if [ "$B18K" = "batista-ps" ]; then
  bad "REGRESSION (ga-nlh79): *-wa-owned bead with ITBI/Contagem nouns misrouted to batista-ps — owner-authoritative guard not firing"
elif echo "$B18K" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (ga-nlh79): *-wa-owned bead landed on dog pool — owner guard not promoting to WA crew"
elif echo "$LOG18K" | grep -q "ga-nlh79.*owner-authoritative\|whatsapp_automation.*domain build\|REFUSING.*whatsapp_automation" || [ -z "$B18K" ]; then
  ok "ga-nlh79: *-wa-owned bead with property nouns → WA domain (not batista-ps), owner guard fired"
else
  bad "ga-nlh79: *-wa-owned bead routed unexpectedly (got: '${B18K:-none}')"
fi
# Fixture: created_by=mila-wa, no WA magic keyword in title (code-mode MCP servers)
WA_OWNER_NOMATCH='[{"id":"ga-miltest","title":"code-mode MCP servers configuration for context injection","priority":3,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_by":"mila-wa","created_at":"2026-06-01T00:00:02Z","metadata":{}}]'
LOG18K2="$(run_capacity 10 "[]" 1 "$WA_OWNER_NOMATCH")"
B18K2="$(dispatched_builder "$LOG18K2")"
if [ "$B18K2" = "batista-ps" ]; then
  bad "REGRESSION (ga-nlh79): mila-wa-owned bead with no WA keyword misrouted to batista-ps"
elif echo "$B18K2" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (ga-nlh79): mila-wa-owned bead landed on dog pool"
elif echo "$LOG18K2" | grep -q "ga-nlh79.*owner-authoritative\|whatsapp_automation.*domain build\|REFUSING.*whatsapp_automation" || [ -z "$B18K2" ]; then
  ok "ga-nlh79: mila-wa-owned bead with no WA keyword → WA domain, owner guard fired"
else
  bad "ga-nlh79: mila-wa-owned bead routed unexpectedly (got: '${B18K2:-none}')"
fi
# Preservation: genuine property bead (no *-wa owner) still → property_scrapers
PS_OWNER_GENUINE='[{"id":"ga-pstest","title":"Scraper RFB: mapear proprietarios de imoveis em Contagem via CNAE/ITBI","priority":3,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_by":"batista-ps","created_at":"2026-06-01T00:00:03Z","metadata":{"story.o_que_e":"scraper semanal que verifica na Receita Federal o CPF dos proprietarios"}}]'
LOG18K3="$(run_capacity 10 "[]" 1 "$PS_OWNER_GENUINE")"
B18K3="$(dispatched_builder "$LOG18K3")"
if [ "$B18K3" = "batista-ps" ]; then
  ok "ga-nlh79 preservation: genuine property bead (batista-ps owner) still routes to batista-ps"
elif echo "$B18K3" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION: genuine property bead landed on dog (owner guard over-fired on ps owner)"
else
  bad "REGRESSION: genuine property bead routed unexpectedly (got: '${B18K3:-none}')"
fi
echo "Scenario 18k: drift-guard — owner-authoritative rig guard is wired"
has "$DISPATCHER" 'ga-nlh79'                            "ga-nlh79 owner-authoritative guard is wired"
has "$DISPATCHER" 'PILOT_OWNER_RIG_GUARD'               "PILOT_OWNER_RIG_GUARD env-gate is wired"
has "$DISPATCHER" 'owner-authoritative rig'             "ga-nlh79 log message wired"

# ── Scenario 18l (ga-l5ud0): launchd bundle-ID strip — bead_content_rig must NOT
# match "whatsapp" from a plist bundle-ID token (com.whatsapp.peter-predeploy-check).
# ROOT: ga-h55xa "repointar com.whatsapp.peter-predeploy-check pra root worktree" was
# classified as whatsapp_automation because bare "whatsapp" matched the WA-integration
# precedence regex — the plist daemon name, NOT the bead's actual domain. Fix: strip
# reverse-DNS bundle-ID patterns (com.<word>.<word>) before the regex fires.
echo "Scenario 18l (ga-l5ud0): launchd bundle-ID in bead → NOT whatsapp_automation (FIX #1)"
_BCR_FN18L="$(awk '/^bead_content_rig\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_bcr_18l() { ( eval "$_BCR_FN18L"; bead_content_rig "$1" ); }
# ga-h55xa fixture: plist bundle-ID in title/description — infra/peter domain, NOT WA
PETER_PLIST='{"id":"ga-h55xa","title":"Produção canônica (peter): repointar com.whatsapp.peter-predeploy-check pra root worktree","description":"launchd com.whatsapp.peter-predeploy-check roda de crew/peter/scripts/peter/predeploy_check.sh. AÇÃO: repointar plist pra scripts/peter/predeploy_check.sh","labels":["ctx:ready","exec:manual"]}'
PLIST_RIG="$(_bcr_18l "$PETER_PLIST")"
if [ "$PLIST_RIG" = "whatsapp_automation" ]; then
  bad "REGRESSION (ga-l5ud0): com.whatsapp.peter plist bundle-ID still misroutes to whatsapp_automation — bundle-ID strip not applied"
elif [ -z "$PLIST_RIG" ]; then
  ok "ga-l5ud0: com.whatsapp.* plist bundle-ID stripped → no domain inferred (infra/HQ, correct)"
else
  ok "ga-l5ud0: plist bead classified as '$PLIST_RIG' (not WA — bundle-ID strip working)"
fi
# Preservation: a genuine WA messaging bead must still → whatsapp_automation
LEGIT_WA='{"id":"ga-watest","title":"integrar whatsapp via whapi para disparo de mensagem","description":"envio de mensagem automatica via pipedrive","labels":["lane:small"]}'
LEGIT_RIG="$(_bcr_18l "$LEGIT_WA")"
[ "$LEGIT_RIG" = "whatsapp_automation" ] \
  && ok "ga-l5ud0 preservation: genuine WA messaging bead still → whatsapp_automation" \
  || bad "REGRESSION (ga-l5ud0): genuine WA bead broken by bundle-ID strip: '$LEGIT_RIG'"
# Verify: com.gascity.* bundle-IDs also stripped (no infra plist names leak domain)
GASCITY_PLIST='{"id":"ga-infra","title":"repointar com.gascity.context-check-dispatcher para scripts/","description":"o daemon com.gascity.pilot-dispatcher.plist aponta pro diretório errado","labels":[]}'
GC_RIG="$(_bcr_18l "$GASCITY_PLIST")"
[ "$GC_RIG" = "whatsapp_automation" ] \
  && bad "REGRESSION (ga-l5ud0): com.gascity.* plist still matches WA regex — bundle-ID strip incomplete" \
  || ok "ga-l5ud0: com.gascity.* infra plist → no WA match (correct)"
echo "Scenario 18l: drift-guard — bundle-ID strip is wired into bead_content_rig"
has "$DISPATCHER" 'ga-l5ud0 FIX #1'                    "ga-l5ud0 bundle-ID strip comment wired"
has "$DISPATCHER" 'bundle-ID'                           "bundle-ID strip keyword wired"

# ── Scenario 18m/18n (ga-tgo7q/ga-evjs2, 2026-07-02): gascity-FRAMEWORK beads that
# bead_content_rig mis-infers as a PRODUCT rig on an INCIDENTAL keyword must still
# DISPATCH to the dog pool (framework work builds on the HQ checkout the dog HAS),
# NEVER be REFUSED + 1h-held. ROOT of the ~22h / 336-loop pipeline stall: an infra
# bead whose text merely NAMES "whatsapp_automation" (the rig it repros on) or says
# "Disparou" (⊃ the WA keyword "disparo") → bead_content_rig=whatsapp_automation →
# rule (3) REFUSING (WA has no rig_domain_default_builder) → pilot:held every sweep,
# dispatching NOTHING though these were the ONLY buildable beads. FIX: bead_domain
# (which checks the 4 PRODUCT domains BEFORE infra) == infra ⇒ clear the mis-inferred
# product rig ⇒ the guard fails open (dispatches to the dog). dispatched_builder reads
# the POST-guard sling line, so it is populated ONLY if the bead actually dispatched
# (a REFUSED bead returns before that line → empty).
echo "Scenario 18m (ga-tgo7q): infra bead naming 'whatsapp_automation' → dog dispatch, NOT refused/held"
INFRA_LIFO='[{"id":"ga-tgtest","title":"quality-gate-dispatcher marker selection is newest-first (LIFO), not FIFO — starves old healthy markers","priority":2,"issue_type":"bug","description":"packs/town-deltas/assets/quality-gate-dispatcher.sh marker-selection jq is LIFO; fix the dispatcher sort to FIFO. NB this repro is on whatsapp_automation, 5 active crews.","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-01T00:00:01Z","metadata":{}}]'
INFRA_LIFO_OBJ="$(echo "$INFRA_LIFO" | jq -c '.[0]')"
# Precondition: bead_content_rig STILL mis-infers WA (the classifier the guard used to refuse on)…
[ "$(_bcr "$INFRA_LIFO_OBJ")" = whatsapp_automation ] && ok "precondition: bead_content_rig still mis-infers whatsapp_automation (incidental 'whatsapp' token)" || bad "precondition changed: bead_content_rig='$(_bcr "$INFRA_LIFO_OBJ")'"
# …but bead_domain classifies it as framework (infra), which is the exemption's key.
[ "$(_dom "$INFRA_LIFO_OBJ")" = infra ] && ok "bead_domain classifies ga-tgo7q shape as infra (framework)" || bad "bead_domain not infra: '$(_dom "$INFRA_LIFO_OBJ")'"
LOG18M="$(run_capacity 10 "[]" 1 "$INFRA_LIFO")"
B18M="$(dispatched_builder "$LOG18M")"
if echo "$B18M" | grep -qE '^gastown\.dog'; then
  ok "infra bead DISPATCHED to the dog pool ($B18M) — framework work builds on the dog (fix works)"
elif [ -z "$B18M" ] && echo "$LOG18M" | grep -q "REFUSING"; then
  bad "REGRESSION: infra bead REFUSED to the dog pool + held (the ga-tgo7q 336-loop stall)"
else
  bad "infra bead routed unexpectedly (got: '${B18M:-none}')"
fi
echo "$LOG18M" | grep -q "framework-dog-exempt: ga-tgtest" && ok "exemption logged for ga-tgo7q shape" || bad "framework-dog-exempt not logged for ga-tgo7q shape"
echo "$LOG18M" | grep -q "REFUSING to dispatch whatsapp_automation domain build ga-tgtest" && bad "ga-tgo7q shape still refused (bug present)" || ok "ga-tgo7q shape NOT refused (no pilot:held loop)"

echo "Scenario 18m2 (ga-tgo7q, guard OFF): PILOT_FRAMEWORK_DOG_EXEMPT=0 reproduces the REFUSE+hold bug"
LOG18M0="$(PILOT_FRAMEWORK_DOG_EXEMPT=0 run_capacity 10 "[]" 1 "$INFRA_LIFO")"
B18M0="$(dispatched_builder "$LOG18M0")"
if [ -z "$B18M0" ] && echo "$LOG18M0" | grep -q "REFUSING to dispatch whatsapp_automation domain build ga-tgtest"; then
  ok "with exemption OFF the bead is REFUSED+held (proves the fix is EXACTLY what flips the behaviour)"
else
  bad "toggle-off did not reproduce the refuse (knob not wired?) got builder='${B18M0:-none}'"
fi

echo "Scenario 18n (ga-evjs2): infra bead saying 'Disparou' (⊃ disparo) → dog dispatch, NOT refused"
INFRA_REVIEWER='[{"id":"ga-evtest","title":"Gate reviewer death-spiral on LARGE diffs: REVIEWER_STALE_SECS=300 fixed freeze-kill doesnt scale with diff size","priority":1,"issue_type":"bug","description":"big-diff reviewers false-reaped at 5min. Disparou throughput-stall watchdog + agent respawns; Dolt+quota burn. Scale the reviewer stale timeout with diff size.","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-01T00:00:02Z","metadata":{}}]'
INFRA_REV_OBJ="$(echo "$INFRA_REVIEWER" | jq -c '.[0]')"
[ "$(_bcr "$INFRA_REV_OBJ")" = whatsapp_automation ] && ok "precondition: bead_content_rig still mis-infers whatsapp_automation (incidental 'disparo' token)" || bad "precondition changed: bead_content_rig='$(_bcr "$INFRA_REV_OBJ")'"
[ "$(_dom "$INFRA_REV_OBJ")" = infra ] && ok "bead_domain classifies ga-evjs2 shape as infra (framework)" || bad "bead_domain not infra: '$(_dom "$INFRA_REV_OBJ")'"
LOG18N="$(run_capacity 10 "[]" 1 "$INFRA_REVIEWER")"
B18N="$(dispatched_builder "$LOG18N")"
if echo "$B18N" | grep -qE '^gastown\.dog'; then
  ok "gate-reviewer infra bead DISPATCHED to the dog pool ($B18N) — fix works"
elif [ -z "$B18N" ] && echo "$LOG18N" | grep -q "REFUSING"; then
  bad "REGRESSION: gate-reviewer infra bead REFUSED to the dog pool + held (the ga-evjs2 stall)"
else
  bad "gate-reviewer infra bead routed unexpectedly (got: '${B18N:-none}')"
fi
echo "$LOG18N" | grep -q "framework-dog-exempt: ga-evtest" && ok "exemption logged for ga-evjs2 shape" || bad "framework-dog-exempt not logged for ga-evjs2 shape"

echo "Scenario 18o (no regression): genuine PRODUCT-domain beads are NEVER infra-exempted → still steered to crew"
# The exemption keys on bead_domain=infra; a real product build classifies as its PRODUCT
# domain (checked BEFORE infra), so it is untouched. Prove both the classifier and the e2e route.
[ "$(_dom "$WARM_BEAD")" = warming ]        && ok "warming bead stays warming (NOT infra) → owner steering intact" || bad "warming reclassified: '$(_dom "$WARM_BEAD")'"
[ "$(_dom "$RE_BEAD")" = real-estate ]      && ok "real-estate bead stays real-estate (NOT infra)"                 || bad "real-estate reclassified: '$(_dom "$RE_BEAD")'"
[ "$(_own warming)" = oracle-wa ]           && ok "warming still owned by oracle-wa (steering preserved)"          || bad "warming owner changed: '$(_own warming)'"
[ "$(_own real-estate)" = peter-wa ]        && ok "real-estate still owned by peter-wa (steering preserved)"       || bad "real-estate owner changed: '$(_own real-estate)'"
# End-to-end: the property_scrapers domain build (18a fixture) must STILL reach batista-ps,
# not the dog — proving the exemption did not swallow product-domain routing.
LOG18O="$(run_capacity 10 "[]" 1 "$PS_DOMAIN_SMALL")"
B18O="$(dispatched_builder "$LOG18O")"
[ "$B18O" = batista-ps ] && ok "property_scrapers domain build STILL → batista-ps (product routing not regressed)" || bad "REGRESSION: property build → '${B18O:-none}' (expected batista-ps)"
echo "$LOG18O" | grep -q "framework-dog-exempt" && bad "exemption wrongly fired on a property build" || ok "exemption stayed silent on the property build (bead_domain≠infra)"

echo "Scenario 18p (fail-open): a ga- HQ bead with NO domain signal → dog dispatch, exemption silent"
NODOMAIN='[{"id":"ga-nodtest","title":"bump the sweep log verbosity flag default","priority":3,"issue_type":"bug","description":"flip a logging default; no domain content whatsoever","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-01T00:00:03Z","metadata":{}}]'
NODOMAIN_OBJ="$(echo "$NODOMAIN" | jq -c '.[0]')"
[ -z "$(_bcr "$NODOMAIN_OBJ")" ] && ok "no-domain bead: bead_content_rig empty (nothing to exempt)" || bad "no-domain bead unexpectedly inferred rig: '$(_bcr "$NODOMAIN_OBJ")'"
LOG18P="$(run_capacity 10 "[]" 1 "$NODOMAIN")"
B18P="$(dispatched_builder "$LOG18P")"
echo "$B18P" | grep -qE '^gastown\.dog' && ok "unknown-domain HQ bead dispatched to the dog (fail-open unchanged)" || bad "unknown-domain HQ bead routed unexpectedly: '${B18P:-none}'"
echo "$LOG18P" | grep -q "framework-dog-exempt" && bad "exemption fired on a no-domain bead (should only touch an inferred product rig)" || ok "exemption silent on no-domain bead (only acts on a mis-inferred product rig)"

echo "Scenario 18q: drift-guard — framework-dog-exempt is wired into the live dispatcher"
has "$DISPATCHER" 'PILOT_FRAMEWORK_DOG_EXEMPT'   "framework-dog-exempt knob is wired"
has "$DISPATCHER" 'framework-dog-exempt'         "framework-dog-exempt log/tag is wired"

# ── Scenario 18r–18w2 (ga-xzfl): PATH-authoritative rig inference ──────────────
# ROOT: rig inference used KEYWORDS (bead_content_rig/bead_domain) not code PATHS, so a
# bead ABOUT the router (cites packs/…/pilot-dispatcher.sh + scripts/auto-rehome-janitor.py,
# says "property_scrapers"/"scraper" in prose) was keyword-classified property_scrapers and
# mis-dispatched to batista-ps, which cannot build framework files → NEVERSTART. The bead's
# FILE PATHS are authoritative. FIX 1 bead_path_rig maps product paths → their rig (wins over
# owner/keyword); FIX 2 folds bead_path_rig==gascity + a framework/pack:town-deltas/dog-pool
# LABEL into the framework-dog-exempt (bead_domain matches 'scraper'⊂'property_scrapers' BEFORE
# 'infra', so the infra-only exemption always missed the self-case); FIX 3 refuses to route to
# a rig missing every file the bead names. All fail-open + knob-gated (PILOT_PATH_RIG_GUARD /
# PILOT_MISSING_FILE_GUARD, default-on).
echo "Scenario 18r (ga-xzfl): bead_path_rig UNIT — file PATHS drive the rig, not keywords"
_HAY_FN="$(awk '/^_bead_path_haystack\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_BPR_FN="$(awk '/^bead_path_rig\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_BCR_FN_R="$(awk '/^bead_content_rig\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_bpr() { ( eval "$_HAY_FN"; eval "$_BCR_FN_R"; eval "$_BPR_FN"; bead_path_rig "$1" ); }
R="$(_bpr '{"title":"x","description":"fix packs/town-deltas/assets/pilot-dispatcher.sh + scripts/auto-rehome-janitor.py; property_scrapers scraper inference wrong"}')"
[ "$R" = gascity ] && ok "packs/ (framework) → gascity even amid property/scraper prose (the ga-xzfl self-sabotage)" || bad "packs/ path not gascity: '$R'"
R="$(_bpr '{"title":"x","description":"branch crew/mila-wa/wa-9 broke"}')"
[ "$R" = whatsapp_automation ] && ok "crew/mila-wa/ → whatsapp_automation (crew suffix)" || bad "crew/*-wa/ misrouted: '$R'"
R="$(_bpr '{"title":"x","description":"crew/batista-ps/ps-1 needs rebase"}')"
[ "$R" = property_scrapers ] && ok "crew/batista-ps/ → property_scrapers (crew suffix)" || bad "crew/*-ps/ misrouted: '$R'"
R="$(_bpr '{"title":"x","description":"outreach/sender.py sends imovel ITBI proprietario deals"}')"
[ "$R" = whatsapp_automation ] && ok "outreach/ + property nouns → whatsapp_automation (path beats keyword)" || bad "outreach/ misrouted: '$R'"
R="$(_bpr '{"title":"x","description":"scrapers/rfb_death.py weekly job"}')"
[ "$R" = property_scrapers ] && ok "scrapers/ → property_scrapers (PS product path)" || bad "scrapers/ misrouted: '$R'"
R="$(_bpr '{"title":"ITBI bridge","description":"scripts/itbi_drive_bridge.py dispara itbi_combiner Hex whapi pipedrive"}')"
[ -z "$R" ] && ok "scripts/ + WA content → empty (defers to keyword; protects Scenario 18h)" || bad "scripts/ wrongly forced a rig: '$R'"
R="$(_bpr '{"title":"x","description":"tweak scripts/sweep_tool.py — no product keyword at all"}')"
[ -z "$R" ] && ok "FINDING 1: bare scripts/ (no keyword) → empty (rule 5 dropped; owner/content decides, never forced gascity)" || bad "FINDING 1 regression: bare scripts/ still forces rig '$R' (would override the *-wa/*-ps owner)"
R="$(_bpr '{"title":"x","description":"fix shared/whatsapp_sender.py retry logic"}')"
[ -z "$R" ] && ok "FINDING 3: shared/ → empty (it exists in WA AND PS — ambiguous; defers to owner/content)" || bad "FINDING 3 regression: shared/ still force-mapped to '$R'"
R="$(_bpr '{"title":"scraper RFB","description":"imovel ITBI cadastro — no file path cited"}')"
[ -z "$R" ] && ok "no path → empty (fail-open to existing keyword/owner inference)" || bad "pathless bead inferred a rig: '$R'"
R="$(_bpr '{"title":"x","description":"see the board at https://painel.urblink.com.br/kanban"}')"
[ -z "$R" ] && ok "URL is not a path → empty (hostname never mistaken for a repo path)" || bad "URL mistaken for path: '$R'"
has "$DISPATCHER" 'bead_path_rig()'           "bead_path_rig() is defined (drift-guard)"
has "$DISPATCHER" 'PILOT_PATH_RIG_GUARD'      "path-rig guard knob is wired"
has "$DISPATCHER" 'PILOT_MISSING_FILE_GUARD'  "missing-file guard knob is wired"

echo "Scenario 18s (ga-xzfl SELF-CASE): a bead ABOUT the router (cites packs/…+scripts/…) → dog, NOT batista-ps"
XZFL_SELF='[{"id":"ga-xzfltest","title":"Pilot/janitor mis-routes work to the WRONG rig — rig inference uses KEYWORDS not code PATHS","priority":1,"issue_type":"bug","description":"packs/town-deltas/assets/pilot-dispatcher.sh + scripts/auto-rehome-janitor.py: a bug ABOUT routing sabotages its own dispatch because bead_content_rig sees property_scrapers/scraper and mis-routes to batista-ps → NEVERSTART","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-11T00:00:01Z","metadata":{}}]'
XZFL_OBJ="$(echo "$XZFL_SELF" | jq -c '.[0]')"
[ "$(_bcr "$XZFL_OBJ")" = property_scrapers ] && ok "precondition: bead_content_rig STILL mis-infers property_scrapers (keyword 'scraper')" || bad "precondition changed: bead_content_rig='$(_bcr "$XZFL_OBJ")'"
[ "$(_dom "$XZFL_OBJ")" != infra ] && ok "bead_domain is NOT infra for the self-case ('scraper'⊂data wins before infra — why the infra-only exemption missed it)" || bad "bead_domain unexpectedly infra"
LOG18S="$(run_capacity 10 "[]" 1 "$XZFL_SELF")"
B18S="$(dispatched_builder "$LOG18S")"
if echo "$B18S" | grep -qE '^gastown\.dog'; then
  ok "self-case DISPATCHED to the dog (framework work builds on the HQ checkout the dog has)"
elif [ "$B18S" = batista-ps ]; then
  bad "REGRESSION (ga-xzfl): the router-bug bead misrouted to batista-ps → NEVERSTART (the exact bug)"
else
  bad "self-case routed unexpectedly (got: '${B18S:-none}')"
fi
echo "$LOG18S" | grep -q "framework-dog-exempt: ga-xzfltest is gascity-framework work (bead_path_rig=gascity)" && ok "self-case exempted via bead_path_rig=gascity (the new path-authoritative condition)" || bad "self-case not exempted via bead_path_rig=gascity"

echo "Scenario 18t (ga-xzfl): a framework/pack:town-deltas/dog-pool LABEL exempts a product-keyword bead → dog"
LABEL_FW='[{"id":"ga-lbltest","title":"scraper cadastro ITBI de imoveis — property words but framework-labeled","priority":2,"issue_type":"bug","description":"property_scrapers scraper imovel ITBI, but this is dog-pool framework work","status":"open","labels":["lane:small","story:approved","framework"],"assignee":null,"created_at":"2026-07-11T00:00:02Z","metadata":{}}]'
LOG18T="$(run_capacity 10 "[]" 1 "$LABEL_FW")"
B18T="$(dispatched_builder "$LOG18T")"
if echo "$B18T" | grep -qE '^gastown\.dog'; then
  ok "framework-labeled bead → dog despite property keywords"
elif [ "$B18T" = batista-ps ]; then
  bad "framework-labeled bead misrouted to batista-ps (label exemption not honored)"
else
  bad "framework-labeled bead routed unexpectedly (got: '${B18T:-none}')"
fi
echo "$LOG18T" | grep -q "framework-dog-exempt: ga-lbltest is gascity-framework work (framework-label)" && ok "label-exemption logged (reason=framework-label)" || bad "label exemption not logged"

echo "Scenario 18u (ga-xzfl Mode-A): WA bead citing outreach/ with property nouns → WA, NOT batista-ps"
MODE_A='[{"id":"ga-modea","title":"outreach flow includes proprietario imovel ITBI data in the deal","priority":3,"issue_type":"feature","description":"outreach/deal_builder.py enriches the deal with imovel/ITBI/proprietario nouns","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-11T00:00:03Z","metadata":{}}]'
LOG18U="$(run_capacity 10 "[]" 1 "$MODE_A")"
B18U="$(dispatched_builder "$LOG18U")"
if [ "$B18U" = batista-ps ]; then
  bad "REGRESSION (Mode-A): WA outreach/shared bead misrouted to batista-ps on property nouns"
elif echo "$B18U" | grep -qE '^gastown\.dog'; then
  bad "Mode-A WA bead landed on the dog ($B18U) — should classify as whatsapp_automation"
elif echo "$LOG18U" | grep -q "path-authoritative rig=whatsapp_automation"; then
  ok "Mode-A: outreach//shared/ path → whatsapp_automation (path beats the property nouns), NOT batista-ps"
else
  bad "Mode-A routed unexpectedly (got: '${B18U:-none}')"
fi

echo "Scenario 18v (ga-xzfl Mode-B): framework bead (packs/) with product keywords → dog, NOT a product rig"
MODE_B='[{"id":"ga-modeb","title":"packs/town-deltas/assets/quality-gate-dispatcher.sh — fix a whatsapp/painel/pipedrive wording in a log line","priority":2,"issue_type":"bug","description":"the dispatcher log line mentions whatsapp/painel/pipedrive; edit packs/town-deltas/assets/quality-gate-dispatcher.sh","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-11T00:00:04Z","metadata":{}}]'
LOG18V="$(run_capacity 10 "[]" 1 "$MODE_B")"
B18V="$(dispatched_builder "$LOG18V")"
if echo "$B18V" | grep -qE '^gastown\.dog'; then
  ok "Mode-B: framework-path bead → dog despite whatsapp/painel keywords (NOT WA-rehomed)"
else
  bad "Mode-B framework bead routed unexpectedly (got: '${B18V:-none}') — expected dog"
fi
echo "$LOG18V" | grep -q "framework-dog-exempt: ga-modeb is gascity-framework work (bead_path_rig=gascity)" && ok "Mode-B exempted via bead_path_rig=gascity" || bad "Mode-B not exempted via path"

echo "Scenario 18w (ga-xzfl): missing-file guard — file present in HQ, absent in routed rig → REFUSE, fall open to dog"
# GENUINE MISLOCATION (FINDING 2): the cited file exists in HQ (gascity) but NOT in the routed
# product rig. Seam "gascity" = only HQ has the file. Path-rig guard OFF so content infers WA.
MISSING_FIX='[{"id":"ga-missfile","title":"whatsapp painel kanban tweak that names packs/town-deltas/assets/pilot-dispatcher.sh","priority":2,"issue_type":"bug","description":"whatsapp painel kanban work — but the only file cited is packs/town-deltas/assets/pilot-dispatcher.sh, which lives in HQ, not in whatsapp_automation","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-11T00:00:05Z","metadata":{}}]'
LOG18W="$(PILOT_PATH_RIG_GUARD=0 PILOT_MISSING_FILE_GUARD=1 PILOT_TEST_RIG_HAS_FILE=gascity run_capacity 10 "[]" 1 "$MISSING_FIX")"
B18W="$(dispatched_builder "$LOG18W")"
echo "$LOG18W" | grep -q "missing-file guard: ga-missfile" && ok "missing-file guard FIRED: cited file present in HQ, absent in whatsapp_automation → cleared the inference" || bad "missing-file guard did NOT fire (expected refuse+reroute)"
if echo "$B18W" | grep -qE '^gastown\.dog'; then
  ok "after the missing-file refuse the bead fell OPEN to the dog (which builds in HQ, where the file is)"
elif [ "$B18W" = batista-ps ]; then
  bad "missing-file bead misrouted to batista-ps"
else
  bad "missing-file bead routed unexpectedly (got: '${B18W:-none}')"
fi
echo "Scenario 18w2 (control): PILOT_MISSING_FILE_GUARD=0 → NO refuse (kill-switch works)"
LOG18W0="$(PILOT_PATH_RIG_GUARD=0 PILOT_MISSING_FILE_GUARD=0 PILOT_TEST_RIG_HAS_FILE=gascity run_capacity 10 "[]" 1 "$MISSING_FIX")"
echo "$LOG18W0" | grep -q "missing-file guard: ga-missfile" && bad "guard fired despite PILOT_MISSING_FILE_GUARD=0" || ok "guard silent when disabled (kill-switch honored)"

# ── Scenario 18x (ga-xzfl review FINDING 2): CREATE-FILE bead — cited file exists in NO rig ──
# "create scrapers/foo_novo.py": bead_path_rig maps scrapers/ → property_scrapers, but the file
# doesn't exist yet (absent EVERYWHERE, incl HQ). The guard must NOT dog it (HQ can't build it
# either) — PS is the correct rig to CREATE it in. Seam "0" = absent in every rig.
echo "Scenario 18x (FINDING 2): create-file bead (cited file in NO rig) → property_scrapers, NOT dog"
CREATE_FILE='[{"id":"ga-createf","title":"novo scraper: create scrapers/foo_novo.py for weekly RFB","priority":2,"issue_type":"feature","description":"create a brand-new file scrapers/foo_novo.py — it does not exist yet in any rig","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-11T00:00:06Z","metadata":{}}]'
LOG18X="$(PILOT_MISSING_FILE_GUARD=1 PILOT_TEST_RIG_HAS_FILE=0 run_capacity 10 "[]" 1 "$CREATE_FILE")"
B18X="$(dispatched_builder "$LOG18X")"
if [ "$B18X" = batista-ps ]; then
  ok "create-file bead → batista-ps (correct rig to create the new file), NOT dogged"
elif echo "$B18X" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (FINDING 2): create-file bead DOGGED → HQ lacks scrapers/ too → NEVERSTART"
else
  bad "create-file bead routed unexpectedly (got: '${B18X:-none}')"
fi
echo "$LOG18X" | grep -q "missing-file guard: ga-createf" && bad "FINDING 2: guard wrongly fired on a create-file bead (HQ also lacks the file)" || ok "missing-file guard stayed SILENT on the create-file bead (HQ also lacks it → not mislocated)"

# ── Scenario 18y (ga-xzfl review FINDING 1): owner-authoritative scripts/ must beat gascity ──
# A product-crew-OWNED bead citing a bare scripts/<file> with NO product keyword must route to
# the OWNER's rig (ga-nlh79), NOT be forced to gascity→dog by the old rule-5.
echo "Scenario 18y (FINDING 1): ps-worker-owned bare scripts/ bead (no keyword) → batista-ps, NOT dog"
OWNED_PS='[{"id":"ga-ownps","title":"adjust the nightly sweep timing","priority":2,"issue_type":"bug","description":"tweak scripts/nightly_sweep.py interval — no product keyword whatsoever","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_by":"ps-worker-1","created_at":"2026-07-11T00:00:07Z","metadata":{}}]'
LOG18Y="$(run_capacity 10 "[]" 1 "$OWNED_PS")"
B18Y="$(dispatched_builder "$LOG18Y")"
if [ "$B18Y" = batista-ps ]; then
  ok "ps-worker-owned scripts/ bead → batista-ps (owner-authoritative preserved)"
elif echo "$B18Y" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (FINDING 1): owned scripts/ bead FORCED to gascity→dog → HQ scripts/ shares no basenames → NEVERSTART"
else
  bad "owned scripts/ bead routed unexpectedly (got: '${B18Y:-none}')"
fi
echo "Scenario 18y2 (FINDING 1): *-wa-owned bare scripts/ bead (no keyword) → WA/held, NOT dog"
OWNED_WA='[{"id":"ga-ownwa","title":"adjust the nightly sweep timing","priority":2,"issue_type":"bug","description":"tweak scripts/nightly_sweep.py interval — no product keyword whatsoever","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_by":"mila-wa","created_at":"2026-07-11T00:00:08Z","metadata":{}}]'
LOG18Y2="$(run_capacity 10 "[]" 1 "$OWNED_WA")"
B18Y2="$(dispatched_builder "$LOG18Y2")"
if echo "$B18Y2" | grep -qE '^gastown\.dog'; then
  bad "REGRESSION (FINDING 1): *-wa-owned scripts/ bead FORCED to gascity→dog → NEVERSTART"
elif [ "$B18Y2" = batista-ps ]; then
  bad "*-wa-owned scripts/ bead misrouted to batista-ps"
else
  ok "*-wa-owned scripts/ bead → whatsapp_automation (deferred/held), NOT dog (owner preserved)"
fi

# ── Scenario 18z (ga-xzfl review FINDING 3): shared/ collision — PS-content bead → PS, not WA ──
echo "Scenario 18z (FINDING 3): PS-content bead citing shared/<file> → batista-ps, NOT WA-held"
SHARED_PS='[{"id":"ga-shrps","title":"consolidar cadastro ITBI de imoveis e lotes","priority":2,"issue_type":"bug","description":"shared/rfb_scraper.py consolida o cadastro ITBI/imovel/lote no MotherDuck (scraper de propriedade)","status":"open","labels":["lane:small","story:approved"],"assignee":null,"created_at":"2026-07-11T00:00:09Z","metadata":{}}]'
LOG18Z="$(run_capacity 10 "[]" 1 "$SHARED_PS")"
B18Z="$(dispatched_builder "$LOG18Z")"
if [ "$B18Z" = batista-ps ]; then
  ok "shared/ + PS content → batista-ps (shared/ no longer force-maps to WA)"
elif echo "$LOG18Z" | grep -q "path-authoritative rig=whatsapp_automation"; then
  bad "REGRESSION (FINDING 3): shared/ force-mapped to WA → PS scraper held on the wrong rig"
else
  bad "shared/ PS-content bead routed unexpectedly (got: '${B18Z:-none}')"
fi

# ── Scenario 18aa (ga-xzfl review FINDING 4): probe-failure must FAIL-OPEN, never refuse ──────
echo "Scenario 18aa (FINDING 4): _rig_has_any_path — git-probe timeout (exit 124) → fail-open (present), NOT absent"
_RHAP_FN="$(awk '/^_rig_has_any_path\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
_RRP_FN="$(awk '/^rig_root_path\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
FAKEGIT="$WORK/fakegit"; mkdir -p "$FAKEGIT"
printf '#!/usr/bin/env bash\nexit 124\n' > "$FAKEGIT/git"; chmod +x "$FAKEGIT/git"
RIGROOT="$WORK/rigroot-ps"; mkdir -p "$RIGROOT"   # a REAL dir that does NOT contain the cited file
_probe() { ( PATH="$FAKEGIT:$PATH"; unset PILOT_TEST_RIG_HAS_FILE; PILOT_RIG_PATHS_JSON='{"rigs":[{"name":"property_scrapers","path":"'"$RIGROOT"'"}]}'; eval "$_RRP_FN"; eval "$_RHAP_FN"; _rig_has_any_path property_scrapers "scripts/foo.py" && echo present || echo absent ); }
if [ "$(_probe)" = present ]; then
  ok "git-probe timeout (124) → fail-open (present) — probe failure NEVER conflated with file-absent"
else
  bad "REGRESSION (FINDING 4): git-probe timeout treated as file-absent → would REFUSE (destructive)"
fi

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
EMIT_BUGS_19B='[{"id":"tt-emit-clean","title":"clean","priority":0,"issue_type":"bug","description":"clean ready bug with a full description for the assigned-veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},{"id":"tt-emit-assigned","title":"assigned","priority":0,"issue_type":"bug","description":"assigned bug with a full description for the assigned-veto test","status":"open","labels":[],"assignee":"someone-wa","created_at":"2026-06-01T00:00:00Z","metadata":{}}]'
F19B="$(run_emit "$EMIT_BUGS_19B")"
if jq -e '[.items[].id] | (index("tt-emit-clean") != null) and (index("tt-emit-assigned") == null)' "$F19B" >/dev/null 2>&1; then
  ok "emit kept the clean bead and excluded the assigned one (filter parity)"
else
  bad "emit did not apply the assigned-veto correctly (got: $(jq -c '[.items[].id]' "$F19B" 2>/dev/null))"
fi

echo "Scenario 19h: emit chain = real dispatch chain (ga-aprov: no blocked/manual/waiting leak into Aprovadas)"
# The emit feeds the painel 'Aprovadas' column AND the imparavel-check. It MUST exclude
# exactly what real dispatch excludes — else blocked/manual/waiting work shows as READY.
# (a) structural drift-guard: the emit chain string carries the full filter set.
has "$DISPATCHER" '_filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built | _filter_unblocked "\$_db" | _filter_explicit_deps "\$_db"' \
  "emit applies the FULL real-dispatch filter chain (exec_manual+dispatch_gates+built) — Aprovadas honest"
# (b) behavioral: _filter_dispatch_gates drops waiting-on:* and next-action:* (were missing everywhere).
_FDG="$(awk '/^_filter_dispatch_gates\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
FDG_OUT="$(eval "$_FDG"; printf '%s' '[
  {"id":"fdg-clean","status":"open","description":"a ready bead with a full description over the floor length","labels":["lane:small"]},
  {"id":"fdg-wait","status":"open","description":"a ready bead with a full description over the floor length","labels":["waiting-on:survival-wa-flba"]},
  {"id":"fdg-next","status":"open","description":"a ready bead with a full description over the floor length","labels":["next-action:athos+oracle"]}
]' | _filter_dispatch_gates | jq -rc '[.[].id]' 2>/dev/null)"
if [ "$FDG_OUT" = '["fdg-clean"]' ]; then
  ok "_filter_dispatch_gates excludes waiting-on:* and next-action:* (waiting work never dispatchable)"
else
  bad "_filter_dispatch_gates waiting-on/next-action exclusion broke (got: '$FDG_OUT')"
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
# ── rig-scope allowlist (ga-mfeip WA-only default — honors the bead's scope, cuts
# wasted ctx:ready queries against empty rigs → lighter Dolt footprint per sweep).
has "$DISPATCHER" 'PILOT_CTX_READY_RIGS' "rig-scan scope allowlist defined (default whatsapp_automation)"
has "$DISPATCHER" 'whatsapp_automation}"' "rig-scan scope defaults to whatsapp_automation (ga-mfeip scope)"

# ── Scenario 22g: HOL-block fix — built/gate-failed beads excluded from ctx:ready pool
# A bead that is already built (has a crew branch) or gate-failed must NOT be a ctx:ready
# candidate: it is picked first by priority, refused by the ownership guard, and head-of-
# line-blocks the lane every sweep (wa-xrdv / wa-vn5o → dispatched=0 while fresh beads wait).
echo "Scenario 22g: HOL-block fix — built + gate-failed beads are excluded from the ctx:ready pool"
# Layer 1 — query excludes the gate-failed states (both HQ and rig ctx:ready queries).
has "$DISPATCHER" 'exclude-label "gate:failed"'    "ctx:ready query excludes gate:failed (HOL-block layer 1)"
has "$DISPATCHER" 'exclude-label "gate:needs-fix"' "ctx:ready query excludes gate:needs-fix (HOL-block layer 1)"
# Layer 2 — _filter_built drops branched (built) candidates; behavioral unit + wiring.
# _filter_built now also consults the HQ gate markers (wa-8y45 leak), so extract its two
# gate helpers alongside it. Gate seams are set EMPTY (defined→hermetic, no live Dolt) in
# the branch-only cases so the gate consultation is a no-op there.
_FB_FN="$(awk '/^_beadid_has_active_gate_artifact\(\)/{f=1} /^_beadid_has_open_gate_marker\(\)/{f=1} /^_filter_built\(\)/{f=1} f{print} f&&/^}$/{f=0}' "$DISPATCHER")"
FB_OUT="$(eval "$_FB_FN"; export PILOT_TEST_BRANCH_BEADS="wa-built" PILOT_TEST_GATE_OPEN_BEADS="" PILOT_TEST_GATE_ACTIVE_BEADS=""; printf '%s' '[{"id":"wa-built"},{"id":"wa-fresh"}]' | _filter_built | jq -rc '[.[].id]' 2>/dev/null)"
if [ "$FB_OUT" = '["wa-fresh"]' ]; then
  ok "_filter_built drops the built (branched) bead, keeps the fresh candidate"
else
  bad "_filter_built logic wrong (got: '$FB_OUT')"
fi
FB_OPEN="$(eval "$_FB_FN"; export PILOT_TEST_GATE_OPEN_BEADS="" PILOT_TEST_GATE_ACTIVE_BEADS=""; printf '%s' '[{"id":"wa-built"},{"id":"wa-fresh"}]' | _filter_built 2>/dev/null | jq -rc '[.[].id]' 2>/dev/null)"
if [ "$FB_OPEN" = '["wa-built","wa-fresh"]' ]; then
  ok "_filter_built FAIL-OPEN keeps all candidates when branches are unprobeable (no false drop)"
else
  bad "_filter_built fail-open broke (got: '$FB_OPEN')"
fi
# gate:needs-fix EXEMPTION: a built bead in the gate-fix loop carries its fix branch but
# MUST stay a candidate for re-dispatch (parity with the ownership-guard exemption 025b0cf58).
# Dropping it would silently kill the gate-fix loop for self-repo rigs (local branch visible
# to _filter_built), now that the HQ-empty fallback applies _filter_built (f7990dcf6).
FB_NF="$(eval "$_FB_FN"; export PILOT_TEST_BRANCH_BEADS="wa-built wa-nf" PILOT_TEST_GATE_OPEN_BEADS="" PILOT_TEST_GATE_ACTIVE_BEADS=""
  printf '%s' '[{"id":"wa-built","labels":["story:approved"]},{"id":"wa-nf","labels":["story:approved","gate:needs-fix"]},{"id":"wa-fresh","labels":[]}]' \
    | _filter_built | jq -rc '[.[].id]' 2>/dev/null)"
if [ "$FB_NF" = '["wa-nf","wa-fresh"]' ]; then
  ok "_filter_built EXEMPTS gate:needs-fix (built fix-loop bead kept for re-dispatch; plain built dropped)"
else
  bad "_filter_built gate:needs-fix exemption broke (got: '$FB_NF')"
fi

# ── Scenario 22g-gate: _filter_built is GATE-MARKER-AWARE (wa-8y45 leak fix) ──────────
# ROOT of the wa-8y45 leak: _filter_built decided "built?" ONLY by crew-branch existence.
# When the gate parks a marker at needs-rebase/error it PRUNES the branch, so the git probe
# read "no branch → not built" and LEAKED the in-gate bead back as a FRESH candidate (churn
# + the class of confusion the downstream imparavel-check c9a8413f1 already patched). Now
# _filter_built also drops a candidate that an OPEN quality-gate-marker names (source-bead)
# OR that carries a gate:* lifecycle label — EXCEPT gate:needs-fix with no ACTIVE marker
# (the re-fix loop). Seams: PILOT_TEST_GATE_OPEN_BEADS (any open marker) +
# PILOT_TEST_GATE_ACTIVE_BEADS (actively-processing marker, reused signal-(d) helper).
# Test BOTH directions: an in-gate bead must NOT leak; a fresh/re-fix bead must NOT be dropped.
_fb() { # $1=OPEN-beads $2=ACTIVE-beads $3=input-json  → sorted id list; NO branch seam
  ( eval "$_FB_FN"
    export PILOT_TEST_GATE_OPEN_BEADS="$1" PILOT_TEST_GATE_ACTIVE_BEADS="$2"
    printf '%s' "$3" | _filter_built 2>/dev/null | jq -rc '[.[].id]' 2>/dev/null )
}
# (i) open ACTIVE gate-marker (source-bead), NO branch → filtered as built/in-gate.
FB_I="$(_fb "wa-ig" "wa-ig" '[{"id":"wa-ig","labels":["ctx:ready"]},{"id":"wa-fresh","labels":["ctx:ready"]}]')"
[ "$FB_I" = '["wa-fresh"]' ] && ok "_filter_built(i): open ACTIVE marker + pruned branch → dropped (no leak)" \
                             || bad "_filter_built(i): active-marker in-gate bead leaked (got: '$FB_I')"
# (i-b) THE wa-8y45 REGRESSION: open NON-active marker (needs-rebase), NO branch, NO gate
# label (it carried a stale ctx:ready at flag time) → still dropped via the open-marker signal.
FB_R="$(_fb "wa-8y45" "" '[{"id":"wa-8y45","labels":["ctx:ready","exec:auto"]},{"id":"wa-fresh","labels":["ctx:ready"]}]')"
[ "$FB_R" = '["wa-fresh"]' ] && ok "_filter_built(i-b): wa-8y45 open needs-rebase marker (non-active), pruned branch, stale ctx:ready → dropped (LEAK FIXED)" \
                             || bad "_filter_built(i-b): wa-8y45 in-gate bead STILL LEAKS (got: '$FB_R')"
# (ii) gate:needs-fix with ONLY a failed/error marker (non-active) → STILL dispatchable (re-fix).
FB_NF2="$(_fb "wa-rf" "" '[{"id":"wa-rf","labels":["story:approved","gate:needs-fix"]},{"id":"wa-fresh","labels":["ctx:ready"]}]')"
[ "$FB_NF2" = '["wa-rf","wa-fresh"]' ] && ok "_filter_built(ii): gate:needs-fix + only failed marker → kept (re-fix loop preserved; no deadlock)" \
                                       || bad "_filter_built(ii): re-fix bead wrongly dropped — DEADLOCK regression (got: '$FB_NF2')"
# (ii-b) carve-out BOUNDARY: gate:needs-fix WITH an active marker (re-queued) → dropped now.
FB_NF3="$(_fb "wa-rq" "wa-rq" '[{"id":"wa-rq","labels":["story:approved","gate:needs-fix"]},{"id":"wa-fresh","labels":["ctx:ready"]}]')"
[ "$FB_NF3" = '["wa-fresh"]' ] && ok "_filter_built(ii-b): gate:needs-fix + ACTIVE marker → dropped (actively re-gating, don't double-dispatch)" \
                               || bad "_filter_built(ii-b): actively-regated needs-fix bead leaked (got: '$FB_NF3')"
# (iii) normal fresh bead, no marker, no branch, no gate label → still a candidate.
FB_F="$(_fb "" "" '[{"id":"wa-fresh","labels":["story:approved"]}]')"
[ "$FB_F" = '["wa-fresh"]' ] && ok "_filter_built(iii): fresh bead (no marker/branch/gate-label) → kept as candidate" \
                             || bad "_filter_built(iii): fresh candidate wrongly dropped (got: '$FB_F')"
# (iv) live crew branch AND an in-gate bead compose: branch bead dropped, marker bead dropped, fresh kept.
FB_IV="$(eval "$_FB_FN"; export PILOT_TEST_BRANCH_BEADS="wa-br" PILOT_TEST_GATE_OPEN_BEADS="wa-mk" PILOT_TEST_GATE_ACTIVE_BEADS=""
  printf '%s' '[{"id":"wa-br","labels":[]},{"id":"wa-mk","labels":["ctx:ready"]},{"id":"wa-fresh","labels":[]}]' | _filter_built | jq -rc '[.[].id]' 2>/dev/null)"
[ "$FB_IV" = '["wa-fresh"]' ] && ok "_filter_built(iv): branch bead + marker bead both dropped, fresh kept (branch behavior unchanged, composes with gate)" \
                              || bad "_filter_built(iv): branch/gate composition wrong (got: '$FB_IV')"
# (v) FAIL-OPEN: an unreadable gate-marker query must NOT drop a candidate. bd removed from
# PATH + seams UNSET → both gate helpers fail-open (return "not in gate") → nothing dropped.
FB_V="$(eval "$_FB_FN"; unset PILOT_TEST_GATE_OPEN_BEADS PILOT_TEST_GATE_ACTIVE_BEADS PILOT_TEST_BRANCH_BEADS
  PATH="/usr/bin:/bin"; printf '%s' '[{"id":"wa-a","labels":["ctx:ready"]},{"id":"wa-b","labels":["ctx:ready"]}]' | _filter_built 2>/dev/null | jq -rc '[.[].id]' 2>/dev/null)"
[ "$FB_V" = '["wa-a","wa-b"]' ] && ok "_filter_built(v): unreadable gate query (no bd) → FAIL-OPEN, no candidate dropped (dispatch never wedged)" \
                               || bad "_filter_built(v): gate fail-open broke — would wedge dispatch (got: '$FB_V')"
# (vi) gate:* lifecycle LABEL alone (marker pruned) → dropped via the label signal (imparavel-check parity).
FB_VI="$(_fb "" "" '[{"id":"wa-rev","labels":["gate:reviewing"]},{"id":"wa-fresh","labels":["ctx:ready"]}]')"
[ "$FB_VI" = '["wa-fresh"]' ] && ok "_filter_built(vi): gate:* lifecycle label (no marker) → dropped (label signal, imparavel-check parity)" \
                             || bad "_filter_built(vi): gate:* label bead leaked (got: '$FB_VI')"

has "$DISPATCHER" '_filter_built()'                        "_filter_built helper defined (HOL-block layer 2)"
has "$DISPATCHER" '_beadid_has_open_gate_marker'           "_filter_built consults _beadid_has_open_gate_marker (any-open marker, wa-8y45 leak fix)"
has "$DISPATCHER" '_beadid_has_active_gate_artifact "\$id"' "_filter_built reuses signal-(d) _beadid_has_active_gate_artifact for the needs-fix carve-out"
has "$DISPATCHER" '_beadid_has_open_gate_marker()'         "_beadid_has_open_gate_marker helper defined"
has "$DISPATCHER" '_filter_dispatch_gates | _filter_built' "_filter_built applied in the ctx:ready filter chain"
# The HQ-empty rig FALLBACK scan (RIG_BUGS/RIG_DEBT/RIG_FEATURES) MUST apply the same
# filter chain as WA_RIG_TIER2 — else built beads (wa-huo0d: branch + ready-for-gate, still
# story:approved) and exec:manual bugs (ga-v3o6i) leak in, get picked first by priority, are
# REFUSED by the ownership guard, and head-of-line-block the lane so lower-priority rig work
# (ps-mrfb/ps-joc0) starves. Contiguous (escaped) match so it can't pass on a partial chain.
has "$DISPATCHER" '_filter_exec_manual \| _filter_candidates \| _filter_dispatch_gates \| _filter_built \| _filter_unblocked "\$rig_path"' \
  "HQ-empty rig FALLBACK applies the full filter chain (exec_manual+dispatch_gates+built) — HOL-block + exec:manual leak fix"
# NEVERSTARTED release MUST clear the dead worker's assignee — _filter_candidates requires an
# empty assignee, so a bead released back to story:approved while still carrying its drained
# builder's assignee is INVISIBLE to every candidate query forever (ps-mrfb/ps-joc0 stuck behind
# dead ps-worker-adhoc sessions). The gate-FAIL path unassigns; NEVERSTARTED must too.
has "$DISPATCHER" 'assign "\$_bid" ""' \
  "NEVERSTARTED release clears the dead-worker assignee (ga-mrfb: else _filter_candidates hides the released bead)"

# ── Scenario 22h: ownership guard exempts gate:needs-fix from the branch-exists refusal
# A gate-failed bead in the gate-fix loop OWNS its branch crew/*/<bead> from the prior
# attempt; _filter_built is blind to it on CONTAINER rigs (branch is remote-only, not a
# local ref), so it reaches the ownership guard, which would refuse forever (ps-2w5d
# attempt-3 refused every sweep 40+min). The gate cleared the assignee, so there is no
# live owner — signal (a) must be skipped for gate:needs-fix; signal (b) still guards a
# live crew owner. This is HOL-block layer 2b (guard-level), complementing layer 1/2.
echo "Scenario 22h: ownership guard exempts gate:needs-fix from the branch-exists refusal"
_OG_FNS="$(awk '/^_beadid_has_crew_branch\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")
$(awk '/^_ownership_guard_should_refuse\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
# (1) gate:needs-fix bead WITH a branch → signal (a) suppressed → NOT refused on branch.
OG_FIX="$( bd() { echo ""; }; eval "$_OG_FNS"
  export PILOT_TEST_CREW_BRANCH_BEADS="ps-2w5d" _DEADWORKER_OK=0
  _ownership_guard_should_refuse "ps-2w5d" '{"labels":["story:approved","gate:needs-fix"]}' "/nonexistent" 2>/dev/null
  printf 'rc=%s' "$?" )"
case "$OG_FIX" in
  *branch:*) bad "ownership guard STILL refuses a gate:needs-fix bead on its own branch (got: '$OG_FIX')" ;;
  *rc=1*)    ok  "ownership guard does NOT refuse a gate:needs-fix bead despite an existing branch (fix)" ;;
  *)         bad "unexpected ownership-guard result for gate:needs-fix (got: '$OG_FIX')" ;;
esac
# (2) control — a non-gate:needs-fix bead WITH a branch → signal (a) STILL refuses (ga-htjni intact).
OG_CTL="$( bd() { echo ""; }; eval "$_OG_FNS"
  export PILOT_TEST_CREW_BRANCH_BEADS="wa-built" _DEADWORKER_OK=0
  _ownership_guard_should_refuse "wa-built" '{"labels":["story:approved"]}' "/nonexistent" 2>/dev/null
  printf 'rc=%s' "$?" )"
case "$OG_CTL" in
  *branch:crew/*/wa-built*) ok "ownership guard STILL refuses a plain branched bead (ga-htjni double-dispatch guard intact)" ;;
  *) bad "ownership guard no longer refuses a plain branched bead — ga-htjni regression (got: '$OG_CTL')" ;;
esac

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

# ── Scenario 22e2: per-crew in-flight CAP — an overloaded crew is skipped (load-balance)
echo "Scenario 22e2: per-crew in-flight cap — crew at/over the cap is capped, light crew is not"
_CAP_FNS="$(awk '/^PILOT_MAX_INFLIGHT_PER_CREW=/{p=1} p{print} /_crew_at_inflight_cap\(\)/{c=1} c&&/^}$/{exit}' "$DISPATCHER")"
CAP_RESULT="$(
  eval "$_CAP_FNS"
  export PILOT_TEST_INFLIGHT_COUNTS="mila-wa:5 oracle-wa:1"
  export PILOT_INFLIGHT_RIG_OVERRIDE="/tmp/dummy-rig"   # non-empty rig context (not fail-open)
  PILOT_MAX_INFLIGHT_PER_CREW=3
  if _crew_at_inflight_cap mila-wa;   then printf 'mila=capped ';  else printf 'mila=OK ';  fi
  if _crew_at_inflight_cap oracle-wa; then printf 'oracle=CAPPED'; else printf 'oracle=ok'; fi
)"
if [ "$CAP_RESULT" = "mila=capped oracle=ok" ]; then
  ok "per-crew cap: mila-wa (5≥3) capped, oracle-wa (1<3) not (real helper logic)"
else
  bad "per-crew cap logic wrong (got: '$CAP_RESULT')"
fi
CAP_OFF="$(
  eval "$_CAP_FNS"
  export PILOT_TEST_INFLIGHT_COUNTS="mila-wa:99"; export PILOT_INFLIGHT_RIG_OVERRIDE="/tmp/x"
  PILOT_MAX_INFLIGHT_PER_CREW=0
  _crew_at_inflight_cap mila-wa && echo "CAPPED" || echo "uncapped"
)"
[ "$CAP_OFF" = "uncapped" ] && ok "PILOT_MAX_INFLIGHT_PER_CREW=0 disables the cap" || bad "cap fired while disabled (got: $CAP_OFF)"
has "$DISPATCHER" '_crew_at_inflight_cap()'                   "_crew_at_inflight_cap helper defined"
has "$DISPATCHER" '_crew_at_inflight_cap "\$crew" && continue' "in-flight cap wired into pick_pool_builder rotation"

# ── Scenario 22f: gate (f) — rig-native dedup re-check before assign (structural) ─
echo "Scenario 22f: gate (f) — rig-native dispatch re-checks the live assignee before assigning (dedup)"
has "$DISPATCHER" 'rig_dedup_skip'  "gate (f) dedup-skip result code present"
# The dedup re-reads the CURRENT assignee from the rig DB right before assigning.
_dedup_block="$(awk '/RIG-NATIVE dispatch \(ga-mfeip\)/{f=1} f{print} /rig_native_ok/{if(f)exit}' "$DISPATCHER")"
if printf '%s' "$_dedup_block" | grep -q 'bd -C "\$STORY_BEAD_CITY" show "\$STORY_ID"' \
   && printf '%s' "$_dedup_block" | grep -q '_cur_asg.*!=.*_SLING_TARGET'; then
  ok "gate (f): fresh assignee re-read + mismatch-skip wired before the rig-native assign (_SLING_TARGET)"
else
  bad "gate (f): dedup re-check missing from the rig-native dispatch path"
fi

# ── Scenario 23 (Bug A fix: WA rig story:approved features in primary pool) ───
# Before this fix, the WA-rig story:approved FEATURE scan lived ONLY in Step 2c
# (fallback — only reached when HQ returned ZERO candidates). Since HQ almost always
# returns something (bugs, debt, HQ features), Step 2c never fired and 8 approved WA
# features (wa-zybp, wa-0gs8, wa-0z8e, wa-wdot, wa-oxkg, wa-i02u, wa-oly1, wa-nvn9)
# were never dispatched. Fix: lift them into the unconditional Step 2b-rig-tier2
# merge, alongside CTXREADY_RIG_JSON. Test seam: PILOT_WA_RIG_TIER2_OVERRIDE lets us
# inject a WA rig feature array hermetically (no gc/bd loop needed for selftests).
echo "Scenario 23: Bug A fix — WA rig story:approved features ARE in primary pool (not fallback-only)"

# run_wa_rig_tier2: runner that injects WA-rig approved features via the override
# seam AND sets FAKE_BUGS_JSON so HQ is non-empty (Step 2c fallback must NOT fire).
# $1 = PILOT_WA_RIG_TIER2_OVERRIDE  (JSON array of WA rig features)
# $2 = FAKE_BUGS_JSON               (HQ bugs — non-empty so HQ returns candidates)
# $3 = PILOT_WA_RIG_APPROVED_QUERIES (default "1")
run_wa_rig_tier2() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS=100 \
    PILOT_DOLT_CPU_OVERRIDE=10 \
    DISPATCH_TO_CAPACITY=1 \
    FAKE_BUGS_JSON="${2:-}" \
    FAKE_BLOCKED_IDS="" \
    PILOT_WA_RIG_TIER2_OVERRIDE="${1:-[]}" \
    PILOT_WA_RIG_APPROVED_QUERIES="${3:-1}" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# ── Scenario 23a: behavioral — WA rig feature IS dispatched even when HQ has bugs ─
echo "Scenario 23a: WA rig story:approved feature IS dispatched when HQ also has bugs"
WA_RIG_FEATURE_FX='[{"id":"wa-zybp","title":"WA rig approved feature fixture","priority":0,"issue_type":"feature","description":"fixture body — WA rig story:approved feature, 80+ chars to clear spec floor","status":"open","labels":["story:approved"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{"story.rig":"whatsapp_automation"}}]'
HQ_BUG_FX='[{"id":"tt-hq-bug","title":"HQ bug fixture","priority":1,"issue_type":"bug","description":"fixture body","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}]'
LOG23A="$(run_wa_rig_tier2 "$WA_RIG_FEATURE_FX" "$HQ_BUG_FX")"
if echo "$LOG23A" | grep -q "Lane picks.*wa-zybp\|WOULD DISPATCH.*wa-zybp\|Dispatch:.*wa-zybp\|small: wa-zybp\|big: wa-zybp"; then
  ok "WA rig story:approved feature (wa-zybp) dispatched even though HQ bug also present"
else
  bad "WA rig story:approved feature NOT dispatched when HQ has bugs — Bug A regression"
fi
# The WA rig feature must appear in the pool log (merged into primary, not fallback).
if echo "$LOG23A" | grep -q "WA_RIG_TIER2\|story:approved rig\|Bug A fix"; then
  ok "WA_RIG_TIER2 pool was scanned and logged in primary merge (not fallback-only)"
else
  bad "WA rig tier-2 pool scan log not found — may not have run in primary merge path"
fi

# ── Scenario 23b: env-gate OFF — PILOT_WA_RIG_APPROVED_QUERIES=0 disables scan ─
echo "Scenario 23b: PILOT_WA_RIG_APPROVED_QUERIES=0 disables WA rig approved scan"
LOG23B="$(run_wa_rig_tier2 "$WA_RIG_FEATURE_FX" "$HQ_BUG_FX" "0")"
if echo "$LOG23B" | grep -q "Lane picks.*wa-zybp\|WOULD DISPATCH.*wa-zybp\|small: wa-zybp\|big: wa-zybp"; then
  bad "WA rig feature dispatched even though PILOT_WA_RIG_APPROVED_QUERIES=0 — gate not honored"
else
  ok "WA rig feature NOT dispatched when PILOT_WA_RIG_APPROVED_QUERIES=0 (env-gate honored)"
fi

# ── Scenario 23c: structural checks ─────────────────────────────────────────────
echo "Scenario 23c: structural — Bug A fix wiring verified in dispatcher source"
has "$DISPATCHER" 'WA_RIG_TIER2_JSON'              "WA_RIG_TIER2_JSON variable wired (Bug A fix)"
has "$DISPATCHER" 'PILOT_WA_RIG_APPROVED_QUERIES'  "PILOT_WA_RIG_APPROVED_QUERIES env gate defined"
has "$DISPATCHER" 'PILOT_WA_RIG_TIER2_OVERRIDE'    "PILOT_WA_RIG_TIER2_OVERRIDE test seam defined"
has "$DISPATCHER" 'Step 2b-rig-tier2'              "Step 2b-rig-tier2 block comment present (not in fallback 2c)"
# The merge line must include WA_RIG_TIER2_JSON alongside the other pools.
# Use fixed-string grep to avoid ERE interpretation of the $ variable sigil.
if grep -qF '"$TIER1_JSON $TIER2_JSON $CTXREADY_JSON $CTXREADY_RIG_JSON $WA_RIG_TIER2_JSON"' "$DISPATCHER"; then
  ok "WA_RIG_TIER2_JSON merged into primary candidate pool (Bug A fix)"
else
  bad "WA_RIG_TIER2_JSON NOT in primary merge echo — pool merge incomplete (Bug A fix regression)"
fi

# ── Scenario 24 (gap fix: WA rig step-2b-rig-tier2 must apply full filter chain) ─
# Mila flagged (mail ga-wisp-a1radr): Step 2b-rig-tier2 dispatched wa-i02u (needs
# Athos's Fala.BR/CPF identity) and wa-0z8e (R&D, no AC, needs test device) because
# the block applied only _filter_candidates | _filter_unblocked | _filter_explicit_deps
# — missing _filter_exec_manual AND _filter_dispatch_gates. The fix adds both.
echo "Scenario 24: WA rig tier-2 gap fix — exec:manual + empty-spec features are EXCLUDED"

# ── Scenario 24a: exec:manual WA story:approved feature must NOT dispatch ────
echo "Scenario 24a: exec:manual WA story:approved feature is EXCLUDED from WA rig tier-2"
WA_RIG_EXECMANUAL_FX='[{"id":"wa-i02u-fx","title":"LAI e-SIC fixture — exec:manual","priority":2,"issue_type":"feature","description":"Submit LAI request on Fala.BR using Athos CPF credentials — requires human login","status":"open","labels":["story:approved","exec:manual"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG24A="$(run_wa_rig_tier2 "$WA_RIG_EXECMANUAL_FX" "$HQ_BUG_FX")"
if echo "$LOG24A" | grep -q "Lane picks.*wa-i02u-fx\|WOULD DISPATCH.*wa-i02u-fx\|small: wa-i02u-fx\|big: wa-i02u-fx"; then
  bad "REGRESSION: exec:manual WA story:approved feature (wa-i02u-fx) dispatched — ga-wisp-a1radr gap not fixed"
else
  ok "exec:manual WA story:approved feature (wa-i02u-fx) NOT dispatched (gap fixed, mila ga-wisp-a1radr)"
fi

# ── Scenario 24b: empty-spec WA story:approved feature must NOT dispatch ─────
echo "Scenario 24b: empty-AC/empty-spec WA story:approved feature is EXCLUDED from WA rig tier-2"
# wa-0z8e-style: open, story:approved, empty description (below 20-char floor) and
# no story.criterios. The dispatch gate (b) must reject it.
WA_RIG_EMPTYSPEC_FX='[{"id":"wa-0z8e-fx","title":"Android FLAG_SECURE R&D","priority":2,"issue_type":"feature","description":"","status":"open","labels":["story:approved"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG24B="$(run_wa_rig_tier2 "$WA_RIG_EMPTYSPEC_FX" "$HQ_BUG_FX")"
if echo "$LOG24B" | grep -q "Lane picks.*wa-0z8e-fx\|WOULD DISPATCH.*wa-0z8e-fx\|small: wa-0z8e-fx\|big: wa-0z8e-fx"; then
  bad "REGRESSION: empty-spec WA story:approved feature (wa-0z8e-fx) dispatched — ga-wisp-a1radr gap not fixed"
else
  ok "empty-spec WA story:approved feature (wa-0z8e-fx) NOT dispatched (spec-floor gate b enforced)"
fi

# ── Scenario 24c: a well-specified, non-exec:manual feature still dispatches ─
echo "Scenario 24c: well-specified WA story:approved feature still dispatches (no regression)"
WA_RIG_GOODSPEC_FX='[{"id":"wa-good-fx","title":"Well-specified WA feature fixture","priority":2,"issue_type":"feature","description":"Implement WhatsApp group membership sync with Pipedrive contacts — at least 80 chars of genuine spec","status":"open","labels":["story:approved"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{"story.rig":"whatsapp_automation"}}]'
LOG24C="$(run_wa_rig_tier2 "$WA_RIG_GOODSPEC_FX" "$HQ_BUG_FX")"
# Match the log patterns the dispatcher emits for a DRY_RUN dispatch:
#   "build story wa-good-fx:" appears in the Task title line inside the WOULD DISPATCH block.
#   "→ story:in-flight.*wa-good-fx" appears in the post-dispatch summary line.
if echo "$LOG24C" | grep -q "wa-good-fx.*story:in-flight\|story:in-flight.*wa-good-fx\|build story wa-good-fx\|Selected.*wa-good-fx"; then
  ok "Well-specified WA story:approved feature (wa-good-fx) dispatched (no false-drop)"
else
  bad "Well-specified WA story:approved feature (wa-good-fx) NOT dispatched — false-drop regression"
fi

# ── Scenario 24d: structural — full filter chain wired in the override seam ──
echo "Scenario 24d: structural — _filter_exec_manual + _filter_dispatch_gates wired in WA rig tier-2"
if grep -qF '_filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built' "$DISPATCHER"; then
  ok "_filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built found in dispatcher (full chain)"
else
  bad "Full filter chain NOT found in dispatcher — WA rig tier-2 gap fix may be incomplete"
fi
# The override seam must also apply the full chain (test coverage would be hollow otherwise).
# Check that the override block feeds into _filter_exec_manual (not just _filter_candidates).
if awk '/PILOT_WA_RIG_TIER2_OVERRIDE\+x/,/PILOT_WA_RIG_APPROVED_QUERIES/' "$DISPATCHER" \
    | grep -qF '_filter_exec_manual'; then
  ok "Override test seam also applies _filter_exec_manual (hermetic tests exercise the gate)"
else
  bad "Override test seam does NOT apply _filter_exec_manual — filter tests are hollow"
fi

# ── Scenario 25: HQ TIER2 story:approved path now applies the full gate chain ─
# Before this fix, the HQ TIER2 path (Step 2b) used only _filter_candidates +
# _filter_unblocked + _filter_explicit_deps — no _filter_exec_manual,
# _filter_dispatch_gates, or _filter_built. An empty-spec approved feature with
# no story.criterios and a stub description would be dispatched to a crew that
# has no context to build it. The fix applies the IDENTICAL gate chain as the
# WA rig tier-2 and ctx:ready paths.
# Test seam: FAKE_TIER2_JSON — injected into the fake bd's `-l story:approved`
# branch. Companion seam FAKE_BUGS_JSON="[]" empties TIER1 so the TIER2
# candidate is the sole dispatch candidate (no bug outranks it).
echo "Scenario 25: HQ TIER2 story:approved path applies full gate chain (_filter_dispatch_gates)"

# runner: inject a TIER2 fixture and collect the dispatch log.
#   $1 = FAKE_TIER2_JSON  (JSON array of HQ approved features)
run_hq_tier2() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS=100 \
    PILOT_DOLT_CPU_OVERRIDE=10 \
    DISPATCH_TO_CAPACITY=1 \
    FAKE_TIER2_JSON="${1:-[]}" \
    FAKE_BUGS_JSON="[]" \
    FAKE_BLOCKED_IDS="" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# ── Scenario 25a: empty-spec HQ approved feature is EXCLUDED (gate b) ────────
echo "Scenario 25a: empty-spec HQ approved feature is EXCLUDED by gate (b)"
HQ_EMPTYSPEC_FX='[{"id":"tt-hq-empty","title":"Empty-spec HQ approved feature","priority":2,"issue_type":"feature","description":"stub","status":"open","labels":["story:approved"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]'
LOG25A="$(run_hq_tier2 "$HQ_EMPTYSPEC_FX")"
if echo "$LOG25A" | grep -q "Lane picks.*tt-hq-empty\|dispatched.*tt-hq-empty"; then
  bad "REGRESSION: empty-spec HQ approved feature (tt-hq-empty) dispatched — gate (b) not applied to HQ TIER2"
else
  ok "empty-spec HQ approved feature (tt-hq-empty) NOT dispatched (gate b enforced on HQ TIER2)"
fi

# ── Scenario 25b: exec:manual HQ approved feature is EXCLUDED ────────────────
echo "Scenario 25b: exec:manual HQ approved feature is EXCLUDED from HQ TIER2"
HQ_EXECMANUAL_FX='[{"id":"tt-hq-manual","title":"Manual HQ feature requiring gov portal login","priority":1,"issue_type":"feature","description":"Submit e-SIC request on Fala.BR using Athos credentials — requires human login to the portal","status":"open","labels":["story:approved","exec:manual"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]'
LOG25B="$(run_hq_tier2 "$HQ_EXECMANUAL_FX")"
if echo "$LOG25B" | grep -q "Lane picks.*tt-hq-manual\|dispatched.*tt-hq-manual"; then
  bad "REGRESSION: exec:manual HQ approved feature (tt-hq-manual) dispatched — _filter_exec_manual not applied to HQ TIER2"
else
  ok "exec:manual HQ approved feature (tt-hq-manual) NOT dispatched (exec:manual gate applied to HQ TIER2)"
fi

# ── Scenario 25c: well-specified HQ approved feature IS dispatched ────────────
echo "Scenario 25c: well-specified HQ approved feature IS dispatched (no false-drop regression)"
HQ_GOODSPEC_FX='[{"id":"tt-hq-good","title":"Pipedrive: incluir demais imóveis do proprietário ao enviar deal","priority":2,"issue_type":"feature","description":"Ao enviar um deal ao Pipedrive o payload inclui os demais imóveis vinculados ao mesmo CPF/CNPJ do proprietário — consulta na base consolidada e monta o campo imoveis_vinculados no corpo do request","status":"open","labels":["story:approved"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{"story.criterios":"CPF/CNPJ do proprietário buscado na base; lista de imóveis montada; deal criado com imoveis_vinculados preenchido"}}]'
LOG25C="$(run_hq_tier2 "$HQ_GOODSPEC_FX")"
if echo "$LOG25C" | grep -q "Lane picks.*tt-hq-good\|dispatched.*tt-hq-good\|small.*tt-hq-good\|big.*tt-hq-good"; then
  ok "Well-specified HQ approved feature (tt-hq-good) dispatched — no false-drop on HQ TIER2"
else
  bad "Well-specified HQ approved feature (tt-hq-good) NOT dispatched — false-drop regression on HQ TIER2"
fi

# ── Scenario 25d: structural — TIER2 now applies the full gate chain ──────────
echo "Scenario 25d: structural — HQ TIER2 filter chain now includes _filter_exec_manual + _filter_dispatch_gates + _filter_built"
if grep -qF 'TIER2_JSON=$(echo "$TIER2_JSON" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built)' "$DISPATCHER"; then
  ok "HQ TIER2 filter chain includes full gate set (_filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built)"
else
  bad "HQ TIER2 filter chain does NOT include full gate set — gate (b) regression on HQ TIER2"
fi

# ── Scenario NEW-A through NEW-F: pilot-rewire structural checks ───────────────
# These verify the 8-item pilot-rewire-spec.md changes structurally (source patterns)
# without requiring a full dispatch run. Complement the runtime Scenario 15 tests.

echo "Scenario NEW-A: _beadid_live_crew_owner excludes wa-worker and ps-worker (ephemeral, not named crews)"
# Pattern extended (ga-mfeip mirror): wa-worker AND ps-worker both excluded alongside gastown.dog.
if grep -qE 'gastown\.dog\|gastown\.dog-\*\|wa-worker\|wa-worker-\*\|ps-worker' "$DISPATCHER"; then
  ok "wa-worker and ps-worker excluded from _beadid_live_crew_owner (ephemeral — not named crews)"
else
  bad "wa-worker/ps-worker NOT excluded from _beadid_live_crew_owner — ephemeral workers falsely pin beads"
fi

echo "Scenario NEW-B (ga-nlh79 + wa-worker): wa-worker* owner/creator → WA rig, not misroute"
# ga-nlh79: case includes *-wa|*-wa-*|wa-worker* so wa-worker-created beads signal WA domain.
if grep -qE '\*-wa\|\*-wa-\*\|wa-worker\*\)' "$DISPATCHER"; then
  ok "ga-nlh79 case extended to wa-worker* (prevents property misroute for WA builds)"
else
  bad "ga-nlh79 case NOT extended — wa-worker-built beads may misroute to property_scrapers"
fi

echo "Scenario NEW-C: rig_domain_default_builder returns '' for WA (no spurious pilot:held)"
_RDDB_FN="$(awk '/^rig_domain_default_builder\(\)/{f=1} f{print} f&&/^\}$/{exit}' "$DISPATCHER")"
_rddb() { ( eval "$_RDDB_FN"; rig_domain_default_builder "$1" ); }
_rddb_wa="$(_rddb whatsapp_automation 2>/dev/null || echo "ERROR")"
_rddb_ps="$(_rddb property_scrapers 2>/dev/null || echo "ERROR")"
_rddb_wa_alias="$(_rddb wa 2>/dev/null || echo "ERROR")"
[ "$_rddb_wa" = "" ] \
  && ok "rig_domain_default_builder('whatsapp_automation') = '' (no domain hold for WA)" \
  || bad "rig_domain_default_builder('whatsapp_automation') = '$_rddb_wa' (expected '' — WA beads may get spurious pilot:held)"
[ "$_rddb_ps" = "batista-ps" ] \
  && ok "rig_domain_default_builder('property_scrapers') = 'batista-ps' (unchanged)" \
  || bad "property_scrapers domain builder regression (got '$_rddb_ps')"
[ "$_rddb_wa_alias" = "" ] \
  && ok "rig_domain_default_builder('wa') = '' (short alias also returns empty)" \
  || bad "wa short alias regression (got '$_rddb_wa_alias')"

echo "Scenario NEW-D: suspended explicit assignee is blocked, bead falls to pool routing"
if awk '/explicit assignee.*SUSPENDED|crew is SUSPENDED.*clearing/{found=1} END{exit !found}' "$DISPATCHER"; then
  ok "suspended-crew check wired on explicit-assignee path (pilot-rewire spec item 6)"
else
  bad "suspended-crew check MISSING on explicit-assignee path — dispatches to suspended crew"
fi

echo "Scenario NEW-E: gate FAIL wa-worker nudge routes to Mayor (ephemeral, already drained)"
GATE_DISP="${PILOT_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}/packs/town-deltas/assets/quality-gate-dispatcher.sh"
if grep -qE 'wa-worker.*ephemeral|routing FAIL nudge to Mayor' "$GATE_DISP" 2>/dev/null; then
  ok "wa-worker FAIL nudge normalized to Mayor (gate-dispatcher wired)"
else
  bad "wa-worker FAIL nudge NOT normalized — FAIL on wa-worker build goes to a dead session"
fi

echo "Scenario NEW-F: escape hatch documented — explicit assignee = crew PM-choice mechanism"
if grep -q 'CREW PM-CHOICE ESCAPE HATCH' "$DISPATCHER"; then
  ok "PM-choice escape hatch documented in dispatcher (pilot-rewire spec item 8)"
else
  bad "PM-choice escape hatch comment MISSING — mechanism exists but undocumented"
fi

# ── Scenario NEW-G through NEW-J: pilot-spawn auto-spawn checks ───────────────
# Verify the FOLLOW-UP #2 fix: ephemeral wa-worker spawns via gc session new,
# not nudge-and-wait. These are structural pattern checks on the dispatcher source.

echo "Scenario NEW-G: wa-worker dispatch uses gc session new (spawn), not nudge"
if grep -q "session new wa-worker --no-attach" "$DISPATCHER"; then
  ok "dispatcher spawns wa-worker via 'gc session new wa-worker --no-attach' (pilot-spawn fix)"
else
  bad "dispatcher does NOT spawn wa-worker — missing 'gc session new wa-worker --no-attach' (FOLLOW-UP #2 not applied)"
fi

echo "Scenario NEW-H: crew dispatch (non-wa-worker) still uses session nudge"
# The nudge must still exist for named crew in the rig-native path
if grep -qE 'session nudge.*_SLING_TARGET.*DISPATCH_TASK|session nudge.*SLING_TARGET.*DISPATCH_TASK' "$DISPATCHER"; then
  ok "named crew (non-wa-worker) rig-native dispatch still uses session nudge (spawn only for ephemeral pool)"
else
  bad "session nudge path MISSING — named crew rig-native dispatch may be broken"
fi

echo "Scenario NEW-I: gc.routed_to=wa-worker metadata set before spawn (supervisor demand visibility)"
if grep -q 'set-metadata "gc.routed_to=wa-worker"' "$DISPATCHER"; then
  ok "gc.routed_to=wa-worker stamped before spawn (supervisor scale_check + RoutedPoolQuery)"
else
  bad "gc.routed_to=wa-worker NOT stamped — supervisor demand count blind; RoutedPoolQuery misses the bead"
fi

echo "Scenario NEW-J: PILOT_SPAWN_WA_WORKER guard present (spawn path is toggleable)"
if grep -q 'PILOT_SPAWN_WA_WORKER' "$DISPATCHER"; then
  ok "PILOT_SPAWN_WA_WORKER toggle present (set to 0 to revert to nudge-only for debugging)"
else
  bad "PILOT_SPAWN_WA_WORKER toggle MISSING — no way to disable auto-spawn without patching"
fi

# ── Scenario NEW-K/NEW-L: max-cap guard (ga-v3o6i runaway fix) ───────────────
# Verify that the max-cap guard is wired (structural) and that the test seam
# (PILOT_TEST_WA_WORKER_LIVE_COUNT) allows hermetic runtime cap verification.
# NEW-K: structural — knob + seam + cap logic present in source.
# NEW-L: runtime — at-cap suppresses spawn; below-cap proceeds (via DRY_RUN log).

echo "Scenario NEW-K: max-cap guard structural — knob, test seam, and cap logic wired"
has "$DISPATCHER" 'PILOT_WA_WORKER_MAX'                                \
  "PILOT_WA_WORKER_MAX knob defined (defaults to max_active_sessions=4)"
has "$DISPATCHER" 'PILOT_TEST_WA_WORKER_LIVE_COUNT'                    \
  "PILOT_TEST_WA_WORKER_LIVE_COUNT test seam wired (hermetic cap tests)"
has "$DISPATCHER" '_live_wa_count.*PILOT_WA_WORKER_MAX'                \
  "cap check compares _live_wa_count against PILOT_WA_WORKER_MAX"
has "$DISPATCHER" 'wa-worker pool at session cap'                       \
  "at-cap log message present (skip-spawn log identifies cap path)"

# NEW-L: structural checks for cap guard logic placement, log messages, and the
# test seam. Runtime dispatch testing against the WA rig requires mocking bd -C
# calls to the WA Dolt path; the structural checks here are sufficient to prove
# the guard is wired in the right code path (between PILOT_SPAWN_WA_WORKER check
# and the gc session new call).

echo "Scenario NEW-L1: cap guard is inside the PILOT_SPAWN_WA_WORKER=1 block (correct placement)"
# The cap check must appear AFTER the PILOT_SPAWN_WA_WORKER=1 guard but BEFORE
# the gc session new call, so PILOT_SPAWN_WA_WORKER=0 still short-circuits before
# any session list probe. Verify by extracting the spawn block text.
_spawn_block=$(awk '/PILOT_SPAWN_WA_WORKER:-1.*=.*1/{f=1} f{print} /PILOT_SPAWN_WA_WORKER=0.*skipping/{if(f)exit}' "$DISPATCHER")
if echo "$_spawn_block" | grep -q 'wa-worker pool at session cap\|_live_wa_count'; then
  ok "cap guard (_live_wa_count check) is inside the PILOT_SPAWN_WA_WORKER=1 block (correct placement)"
else
  bad "cap guard NOT found inside the PILOT_SPAWN_WA_WORKER=1 block — may run even when spawn is disabled"
fi

echo "Scenario NEW-L2: cap guard reads from PILOT_TEST_WA_WORKER_LIVE_COUNT seam first"
_cap_block=$(awk '/PILOT_TEST_WA_WORKER_LIVE_COUNT/{p=1} p{print} p&&/fi/{exit}' "$DISPATCHER" | head -10)
if echo "$_cap_block" | grep -q 'PILOT_TEST_WA_WORKER_LIVE_COUNT'; then
  ok "cap guard reads PILOT_TEST_WA_WORKER_LIVE_COUNT test seam before live probe (hermetic tests possible)"
else
  bad "cap guard does NOT read PILOT_TEST_WA_WORKER_LIVE_COUNT — hermetic test seam missing or mis-ordered"
fi

echo "Scenario NEW-L3: cap guard at-cap log message identifies the bead + slot counts"
if grep -q 'skip spawn for.*STORY_ID\|ga-v3o6i runaway\|session cap (' "$DISPATCHER"; then
  ok "cap guard at-cap log includes bead ID and cap counts (observable in pilot log)"
else
  bad "cap guard at-cap log message missing or doesn't identify the bead — hard to diagnose in production"
fi

# ── Scenario 16s–16v: phantom-claim guard (FOLLOW-UP #1, ga-9yb5s+) ──────────
# A live crew member may hold story.assignee but NEVER start the build (phantom).
# The phantom-claim guard inside _beadid_live_crew_owner must RELEASE (return 1)
# when NO crew branch exists AND the bead is stale (>45min). It must KEEP when
# a branch exists OR the bead is recent. PILOT_TEST_CREW_BRANCH_BEADS controls
# _beadid_has_crew_branch; PILOT_TEST_PHANTOM_STALE_BEADS controls staleness.

NS_ORACLE_SESS='{"sessions":[{"session_name":"oracle-wa","closed":false}]}'

# 16s: phantom — crew assignee live, no branch, stale → RELEASE (not "refusing to release").
NS_PHANTOM='[{"id":"tt-ns-phantom","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
echo "Scenario 16s: phantom-guard — stale crew-owned bead with no branch is released"
LOG16S="$(run_neverstarted "$NS_PHANTOM" "" "$NS_ORACLE_SESS" '{"tt-ns-phantom":"oracle-wa"}' "" "" "tt-ns-phantom")"
if echo "$LOG16S" | grep -q "releasing never-started in-flight bead tt-ns-phantom"; then
  ok "phantom-guard: stale crew-assigned bead with no branch is released (FOLLOW-UP #1)"
else
  bad "phantom-guard DID NOT release stale crew-assigned no-branch bead tt-ns-phantom (still blocking wa-worker pool)"
fi
if echo "$LOG16S" | grep -q "refusing to release"; then
  bad "phantom-guard still logged 'refusing to release' for phantom bead tt-ns-phantom (ga-9yb5s not phantom-aware)"
else
  ok "phantom-guard: 'refusing to release' log NOT emitted for phantom bead (correct)"
fi

# 16t: active branch — crew assignee live, branch exists, stale → KEEP (real work).
NS_PHANTOM_BR='[{"id":"tt-ns-phantom-br","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'"}}]'
echo "Scenario 16t: phantom-guard — crew-owned bead WITH a branch is kept (active build)"
LOG16T="$(run_neverstarted "$NS_PHANTOM_BR" "" "$NS_ORACLE_SESS" '{"tt-ns-phantom-br":"oracle-wa"}' "" "tt-ns-phantom-br" "tt-ns-phantom-br")"
if echo "$LOG16T" | grep -q "releasing never-started in-flight bead tt-ns-phantom-br"; then
  bad "REGRESSION (phantom-guard): released a crew-owned bead that HAS a branch (active build stolen)"
else
  ok "phantom-guard KEEPS crew-owned bead when a branch exists (active build protected)"
fi

# 16u: recent — crew assignee live, no branch, fresh (<45min dispatch) → KEEP.
NS_FRESH_DISP="$((NS_NOW - 600))"   # 10 min ago — within the 45min phantom window
NS_PHANTOM_FR='[{"id":"tt-ns-phantom-fr","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_FRESH_DISP"'"}}]'
echo "Scenario 16u: phantom-guard — recent crew-owned bead (no branch, <45min) is kept"
# PILOT_TEST_PHANTOM_STALE_BEADS is empty → the guard uses the timestamp path;
# since the bd shim returns no updated_at the epoch parse yields 0 → fail-conservative KEEP.
LOG16U="$(run_neverstarted "$NS_PHANTOM_FR" "" "$NS_ORACLE_SESS" '{"tt-ns-phantom-fr":"oracle-wa"}' "" "" "")"
if echo "$LOG16U" | grep -q "releasing never-started in-flight bead tt-ns-phantom-fr"; then
  bad "REGRESSION (phantom-guard): released a crew-owned bead that is within the 45min window"
else
  ok "phantom-guard KEEPS crew-owned bead that is within the staleness window (recent claim safe)"
fi

# 16v: structural checks for the phantom-guard knob and seam.
echo "Scenario 16v: phantom-guard structural — knob and test seam wired"
has "$DISPATCHER" 'PILOT_PHANTOM_STALE_SECS'             "phantom staleness knob defined (default 2700 = 45min)"
has "$DISPATCHER" 'PILOT_TEST_PHANTOM_STALE_BEADS'       "phantom staleness test seam wired"
has "$DISPATCHER" 'phantom: stale.*no branch'            "phantom-guard release path has identifying log/comment"

# ── Scenario 16w–16y: sling gate-marker guard (ga-d2jil) ─────────────────────
# The "fix bug"/"build story" sling-task dispatch shape writes progress labels
# (gate:reviewing, gate:needs-fix, …) onto the SLING/TASK bead, never mirrored
# back onto the story/bug bead evaluated here. A dog builder that FINISHED and
# submitted to the gate then drain-acks — _session_is_live_builder CORRECTLY
# reports it as not-live (an adhoc worker never resumes) — so absent this guard
# the already-gated bead falls through 16f's dead-worker path and gets
# released, triggering a fully redundant second dispatch (root cause of the
# live ga-tgo7q double-dispatch incident, 2026-07-02).

# 16w: sling assignee looks dead (same shape as 16f) BUT the sling carries a
# gate:* label → KEEP. This is the exact incident shape: trustworthy roster,
# provably-not-live builder, work already at the gate.
echo "Scenario 16w: ga-d2jil — a sling carrying a gate:* label protects the bead even with a dead-looking builder session"
NS_ATGATE='[{"id":"tt-ns-atgate","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-atgate"}}]'
LOG16W="$(run_neverstarted "$NS_ATGATE" "" "$NS_SESS" '{"tt-sling-atgate":"ghost-wa"}' "" "" "" '{"tt-sling-atgate":"gate:reviewing"}')"
if echo "$LOG16W" | grep -q "releasing never-started in-flight bead tt-ns-atgate"; then
  bad "REGRESSION (ga-d2jil): released a bead whose SLING carries a gate:* label (already reached the gate — false double-dispatch)"
else
  ok "bead kept when its sling/task carries a gate:* label, even with a provably-dead builder session (ga-d2jil)"
fi

# 16x: control — identical dead-worker shape to 16f, but with NO sling label at
# all → still RELEASE. Proves 16w's protection comes from the label, not merely
# from fetching sling JSON, and that 16f's original behavior is unchanged.
echo "Scenario 16x: ga-d2jil control — dead-worker sling with NO gate label still releases (16f unchanged)"
NS_DEAD2='[{"id":"tt-ns-dead2","description":"fixture body — context for veto test","status":"open","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.dispatched_at":"'"$NS_OLD"'","pilot.sling_bead":"tt-sling-dead2"}}]'
LOG16X="$(run_neverstarted "$NS_DEAD2" "" "$NS_SESS" '{"tt-sling-dead2":"ghost-wa"}')"
if echo "$LOG16X" | grep -q "releasing never-started in-flight bead tt-ns-dead2"; then
  ok "control: dead-worker sling with no gate label still releases (ga-d2jil did not weaken 16f)"
else
  bad "REGRESSION (ga-d2jil control): a dead-worker sling with NO gate label was kept (over-protection introduced)"
fi

# 16y: structural — the sling gate-marker guard is wired.
echo "Scenario 16y: ga-d2jil structural — sling gate-marker guard wired"
has "$DISPATCHER" 'case ",\$_sling_labels," in \*,gate:\*\) continue' \
  "sling gate-marker guard checks the sling/task bead's own labels for gate:* (ga-d2jil)"

# ── Scenario PS-WORKER: ps-worker ephemeral pool routing (ga-mfeip mirror) ───
# A ps-* rig-native story:approved bead must route to ps-worker (NOT batista-ps).
# Uses a custom gc shim that returns the property_scrapers rig path so
# STORY_BEAD_CITY != GC_CITY → _IS_RIG_NATIVE=1, and the DRY_RUN log emits
# "WOULD: gc ... session new ps-worker --no-attach". Mirrors the wa-worker test seam.
PS_FAKE_RIG_DIR="$WORK/fake-ps-rig"
mkdir -p "$PS_FAKE_RIG_DIR"
PS_SHIMBIN="$WORK/ps-bin"
mkdir -p "$PS_SHIMBIN"

# Custom gc shim: returns property_scrapers rig at PS_FAKE_RIG_DIR (makes _IS_RIG_NATIVE=1).
cat > "$PS_SHIMBIN/gc" <<PS_GC_EOF
#!/usr/bin/env bash
case "\$*" in
  *"rig list"*)      printf '{"rigs":[{"name":"property_scrapers","path":"$PS_FAKE_RIG_DIR","hq":false}]}' ;;
  *sling*)           printf '{"bead_id":"tt-ps-sling-1"}' ;;
  *"session list"*)  printf '{"sessions":[]}' ;;
  *"session new"*)   : ;;
  *"session nudge"*) : ;;
  *) : ;;
esac
exit 0
PS_GC_EOF
chmod +x "$PS_SHIMBIN/gc"
# Reuse the standard bd and notify shims.
ln -sf "$SHIMBIN/bd"     "$PS_SHIMBIN/bd"
ln -sf "$SHIMBIN/notify" "$PS_SHIMBIN/notify"

# ps-* rig-native story:approved fixture — spatial join MDS bug, no external deps.
PS_WORKER_FX='[{"id":"ps-test1","title":"Corrigir spatial join MDS — area poligono sem intersecao","priority":2,"issue_type":"feature","description":"fixture body — spatial join bug, no external deps (canary bead analogue for ps-worker pool test)","status":"open","labels":["story:approved","lane:small"],"assignee":null,"created_at":"2026-06-16T00:00:00Z","metadata":{"story.rig":"property_scrapers"}}]'

# Helper: run a DRY sweep with PS_SHIMBIN and PILOT_WA_RIG_TIER2_OVERRIDE.
# $1=FAKE_BUGS_JSON (use "[]" for ps-only test)
# $2=PILOT_WA_RIG_TIER2_OVERRIDE (the ps bead fixture JSON)
# $3=PILOT_TEST_PS_WORKER_LIVE_COUNT (pool slot count to inject)
run_ps_worker_dispatch() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$PS_SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS=100 \
    PILOT_DOLT_CPU_OVERRIDE=10 \
    DISPATCH_TO_CAPACITY=1 \
    FAKE_BUGS_JSON="${1:-[]}" \
    FAKE_BLOCKED_IDS="" \
    PILOT_WA_RIG_APPROVED_QUERIES=1 \
    PILOT_WA_RIG_TIER2_OVERRIDE="${2:-[]}" \
    PILOT_TEST_PS_WORKER_LIVE_COUNT="${3:-0}" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "Scenario PS-WORKER-A: property_scrapers rig-native story:approved bead routes to ps-worker (NOT batista-ps)"
LOG_PSW="$(run_ps_worker_dispatch "[]" "$PS_WORKER_FX" "0")"
if echo "$LOG_PSW" | grep -q "Builder target: ps-worker"; then
  ok "ps-worker: Builder target is ps-worker (property_scrapers routing correct)"
else
  bad "ps-worker: Builder target is NOT ps-worker — routing broken (expected ps-worker, not batista-ps)"
fi
if echo "$LOG_PSW" | grep -q "session new ps-worker --no-attach"; then
  ok "ps-worker: DRY_RUN log shows rig-native spawn 'WOULD: gc ... session new ps-worker --no-attach'"
else
  bad "ps-worker: 'session new ps-worker --no-attach' NOT in log — spawn arm missing or rig-native path not triggered"
fi
if echo "$LOG_PSW" | grep -q "batista-ps"; then
  bad "ps-worker: batista-ps appeared in dispatch log — old routing NOT replaced"
else
  ok "ps-worker: batista-ps NOT in dispatch log (routing correctly migrated to ps-worker)"
fi

echo "Scenario PS-WORKER-B: structural — ps-worker pool wiring verified in dispatcher"
has "$DISPATCHER" 'PILOT_PS_WORKER_MAX'               "PILOT_PS_WORKER_MAX cap knob defined"
has "$DISPATCHER" 'PILOT_TEST_PS_WORKER_LIVE_COUNT'   "PILOT_TEST_PS_WORKER_LIVE_COUNT test seam wired"
has "$DISPATCHER" 'PILOT_SPAWN_PS_WORKER'             "PILOT_SPAWN_PS_WORKER toggle wired"
has "$DISPATCHER" 'gc\.routed_to=ps-worker'           "gc.routed_to=ps-worker stamped before spawn"
has "$DISPATCHER" 'session new ps-worker --no-attach' "spawn arm uses gc session new ps-worker --no-attach"

# Helper: same as run_ps_worker_dispatch but also injects the ga-htjni ownership-
# guard test seams (ga-sndpm), so a scenario can simulate the routed candidate
# already having a crew branch (signal a) or an active gate marker (signal d).
# $4=PILOT_TEST_CREW_BRANCH_BEADS  $5=PILOT_TEST_GATE_ACTIVE_BEADS
run_ps_worker_dispatch_own_guard() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    PATH="$PS_SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_DOLT_LATENCY_OVERRIDE_MS=100 \
    PILOT_DOLT_CPU_OVERRIDE=10 \
    DISPATCH_TO_CAPACITY=1 \
    FAKE_BUGS_JSON="${1:-[]}" \
    FAKE_BLOCKED_IDS="" \
    PILOT_WA_RIG_APPROVED_QUERIES=1 \
    PILOT_WA_RIG_TIER2_OVERRIDE="${2:-[]}" \
    PILOT_TEST_PS_WORKER_LIVE_COUNT="${3:-0}" \
    PILOT_TEST_CREW_BRANCH_BEADS="${4:-}" \
    PILOT_TEST_GATE_ACTIVE_BEADS="${5:-}" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "Scenario POOL-OWN-A (ga-sndpm): routed-pool dispatch REFUSED when candidate already has a crew branch (signal a)"
LOG_POA="$(run_ps_worker_dispatch_own_guard "[]" "$PS_WORKER_FX" "0" "ps-test1" "")"
# ga-6hkzy: PILOT_TEST_CREW_BRANCH_BEADS is a STATIC seam, visible for the whole
# dispatch_one() call — so the EARLY ga-htjni guard (~L3392, right after claim) sees
# the signal and refuses BEFORE the LATE ga-sndpm re-verification (~L4005, right before
# the pool write) is ever reached. Confirmed via the un-grepped dispatcher log: it shows
# "ga-htjni: REFUSING dispatch of ps-test1 ... (branch:crew/*/ps-test1)", never the
# ga-sndpm line. That's correct layering, not a regression — ga-sndpm exists to catch a
# signal that FIRST appears in the wall-clock gap between the two checks (a real race a
# static seam can't simulate, see the ga-sndpm block comment). Accept refusal from EITHER
# guard as the pass condition (both give the identical collision-safe outcome); signal-(a)
# logic itself already has isolated unit coverage under Scenario 22h (ga-htjni). The
# ga-sndpm call site's continued existence is verified structurally below (POOL-OWN-STRUCT).
if echo "$LOG_POA" | grep -Eq "ga-(htjni|sndpm): REFUSING (routed-pool )?dispatch of ps-test1"; then
  ok "pool-own(a): routed-pool dispatch refused when a crew branch already exists for the candidate"
else
  bad "pool-own(a): REGRESSION — no ownership-guard refusal logged; a bead with an existing crew branch would still get gc.routed_to stamped (collision risk)"
fi
if echo "$LOG_POA" | grep -q "session new ps-worker --no-attach"; then
  bad "pool-own(a): REGRESSION — pool worker spawn happened despite an existing crew branch for the candidate"
else
  ok "pool-own(a): pool worker spawn correctly skipped"
fi

echo "Scenario POOL-OWN-D (ga-sndpm): routed-pool dispatch REFUSED when candidate has an ACTIVE gate marker (signal d)"
LOG_POD="$(run_ps_worker_dispatch_own_guard "[]" "$PS_WORKER_FX" "0" "" "ps-test1")"
# ga-6hkzy: same static-seam reasoning as POOL-OWN-A above — ga-htjni fires first with
# "(gating:active)" and the dispatch never reaches the ga-sndpm re-verification call site.
if echo "$LOG_POD" | grep -Eq "ga-(htjni|sndpm): REFUSING (routed-pool )?dispatch of ps-test1"; then
  ok "pool-own(d): routed-pool dispatch refused when an active gate marker already exists for the candidate"
else
  bad "pool-own(d): REGRESSION — no ownership-guard refusal logged; a bead being actively gated would still get gc.routed_to stamped (collision risk)"
fi
if echo "$LOG_POD" | grep -q "session new ps-worker --no-attach"; then
  bad "pool-own(d): REGRESSION — pool worker spawn happened despite an active gate marker for the candidate"
else
  ok "pool-own(d): pool worker spawn correctly skipped"
fi

echo "Scenario POOL-OWN-CTL (ga-sndpm): control — routed-pool dispatch STILL proceeds when candidate is genuinely free"
LOG_POCTL="$(run_ps_worker_dispatch_own_guard "[]" "$PS_WORKER_FX" "0" "" "")"
if echo "$LOG_POCTL" | grep -q "ga-sndpm: REFUSING routed-pool dispatch"; then
  bad "pool-own(control): REGRESSION — a genuinely free candidate was refused (over-blocking)"
else
  ok "pool-own(control): a genuinely free candidate is NOT refused (no over-blocking)"
fi
if echo "$LOG_POCTL" | grep -q "session new ps-worker --no-attach"; then
  ok "pool-own(control): pool worker spawn still proceeds for a genuinely free candidate"
else
  bad "pool-own(control): REGRESSION — pool worker spawn missing even with no competing ownership signal"
fi

echo "Scenario POOL-OWN-STRUCT (ga-sndpm): structural — ownership guard still re-verified at BOTH call sites"
# POOL-OWN-A/D above can only observe whichever guard fires FIRST (ga-htjni, by code
# order) when driven through a static test seam — they cannot behaviorally reach the LATE
# ga-sndpm call site to prove it specifically still exists. Guard that gap structurally
# instead (same idiom as the engaged-skip dual-loop check ~L937): count call sites of the
# exact guard invocation. Expect >=2 (ga-htjni ~L3394 + ga-sndpm ~L4005) — if a future
# refactor deletes the late re-verification, this count drops to 1 and catches the
# regression even though POOL-OWN-A/D would stay green (masked by the early guard).
[ "$(grep -cE '_ownership_guard_should_refuse "\$STORY_ID" "\$STORY" "\$STORY_BEAD_CITY"' "$DISPATCHER")" -ge 2 ] \
  && ok "ga-sndpm: ownership guard re-verified at BOTH call sites (early ga-htjni + late pool-write re-check)" \
  || bad "ga-sndpm: ownership guard call-site count regressed — late re-verification before the pool write may have been removed (claim-to-write race window reopened)"

# ── Scenario QM7U (ga-qm7u): live-verify-first section injected when a candidate
# carries prior zero-progress reclaim history ─────────────────────────────────
# ga-qm7u incident: a bead whose reported symptom was already fixed LIVE outside
# the bd/gate flow was blind-redispatched 3x over ~2h, each builder finding
# nothing to build and idling out the full 25min reclaim-guard TTL before being
# caught. _filter_candidates already caps redispatch at pilot:reclaim-count>=3
# (ga-am6h) — but that only stops it AFTER 3 blind cycles. This adds a builder-
# facing nudge (mirrors the existing gate:fix-attempt / GATE_FIX_SECTION
# pattern ~L3330): once a candidate carries ANY reclaim history
# (pilot:reclaim-count>=1), tell the next builder to verify live BEFORE writing
# code, so an already-fixed bead resolves in minutes (via the existing
# no-changes close convention) instead of burning another full idle cycle.
QM7U_BUG_RC1='[{"id":"ga-qm7ut1","title":"qm7u reclaim-count 1 fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":["pilot:reclaim-count:1"],"assignee":null,"created_at":"2026-06-01T00:00:01Z","metadata":{}}]'
QM7U_BUG_RC2='[{"id":"ga-qm7ut2","title":"qm7u reclaim-count 2 fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":["pilot:reclaim-count:2"],"assignee":null,"created_at":"2026-06-01T00:00:02Z","metadata":{}}]'
QM7U_BUG_NONE='[{"id":"ga-qm7ut0","title":"qm7u no reclaim-count fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:03Z","metadata":{}}]'

echo "Scenario QM7U-a (ga-qm7u): pilot:reclaim-count:1 → live-verify-first section injected into dispatch prompt"
LOG_QM7U_A="$(run_capacity_reuse 1 "$QM7U_BUG_RC1" "$GT4_SESS_NONE")"
if echo "$LOG_QM7U_A" | grep -q "ga-qm7ut1 has pilot:reclaim-count:1 — injecting live-verify-first section"; then
  ok "ga-qm7u: reclaim-count:1 candidate gets the live-verify-first section injected"
else
  bad "ga-qm7u: reclaim-count:1 candidate did NOT get the live-verify-first section injected (log: $LOG_QM7U_A)"
fi

echo "Scenario QM7U-b (ga-qm7u): pilot:reclaim-count:2 → live-verify-first section still injected"
LOG_QM7U_B="$(run_capacity_reuse 1 "$QM7U_BUG_RC2" "$GT4_SESS_NONE")"
if echo "$LOG_QM7U_B" | grep -q "ga-qm7ut2 has pilot:reclaim-count:2 — injecting live-verify-first section"; then
  ok "ga-qm7u: reclaim-count:2 candidate gets the live-verify-first section injected"
else
  bad "ga-qm7u: reclaim-count:2 candidate did NOT get the live-verify-first section injected (log: $LOG_QM7U_B)"
fi

echo "Scenario QM7U-c (ga-qm7u): no pilot:reclaim-count label → section NOT injected (no regression on common case)"
LOG_QM7U_C="$(run_capacity_reuse 1 "$QM7U_BUG_NONE" "$GT4_SESS_NONE")"
if echo "$LOG_QM7U_C" | grep -q "injecting live-verify-first section"; then
  bad "ga-qm7u: REGRESSION — live-verify-first section injected with no reclaim-count history (log: $LOG_QM7U_C)"
else
  ok "ga-qm7u: no reclaim-count label → section correctly NOT injected"
fi

# QM7U-a/b/c above all route through the BUG-tier DISPATCH_TASK heredoc (they use
# issue_type:"bug", which _bead_tier() always maps to DISPATCH_TIER="bug"). The
# feature/story-tier heredoc has its own separate $LIVE_VERIFY_SECTION injection
# site — untested by QM7U-a/b/c — so a future edit could silently drop it there
# while every other QM7U scenario (and the whole 400+ suite) stays green. Exercise
# the HQ TIER2 (story:approved) path via run_hq_tier2 (Scenario 25's runner) so this
# site is covered too.
echo "Scenario QM7U-d (ga-qm7u): feature-tier (story:approved) candidate with pilot:reclaim-count:1 → live-verify-first section injected (covers the OTHER DISPATCH_TASK template)"
QM7U_FEATURE_RC1='[{"id":"ga-qm7utf1","title":"qm7u feature-tier reclaim-count 1 fixture","priority":2,"issue_type":"feature","description":"fixture body — context for veto test","status":"open","labels":["story:approved","pilot:reclaim-count:1"],"assignee":null,"created_at":"2026-06-01T00:00:04Z","metadata":{"story.criterios":"fixture acceptance criteria for veto test"}}]'
LOG_QM7U_D="$(run_hq_tier2 "$QM7U_FEATURE_RC1")"
if echo "$LOG_QM7U_D" | grep -q "ga-qm7utf1 has pilot:reclaim-count:1 — injecting live-verify-first section"; then
  ok "ga-qm7u: feature-tier candidate with reclaim-count:1 gets the live-verify-first section injected (story/feature DISPATCH_TASK template covered)"
else
  bad "ga-qm7u: feature-tier candidate with reclaim-count:1 did NOT get the live-verify-first section injected (log: $LOG_QM7U_D)"
fi

grep -qE 'PRIOR ZERO-PROGRESS ATTEMPT' "$DISPATCHER" \
  && ok "ga-qm7u: dispatch prompt template carries the live-verify-first section marker" \
  || bad "ga-qm7u: live-verify-first section marker missing from dispatch prompt templates"

# Structural: both DISPATCH_TASK heredocs (bug-tier and feature-tier) must inject
# $LIVE_VERIFY_SECTION — a bare grep for the marker (above) is satisfied by the
# variable's definition alone and would stay green even if a future edit dropped
# one of the two injection sites. Count exact injection-line occurrences instead.
[ "$(grep -cE '^\$LIVE_VERIFY_SECTION$' "$DISPATCHER")" -eq 2 ] \
  && ok "ga-qm7u: \$LIVE_VERIFY_SECTION injected at both DISPATCH_TASK sites (bug-tier + feature-tier)" \
  || bad "ga-qm7u: \$LIVE_VERIFY_SECTION injection-site count != 2 — one of the two dispatch templates lost its injection"

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
