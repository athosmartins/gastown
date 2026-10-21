#!/usr/bin/env bash
# ── Runtime expectation + machine-wide single-flight (ga-iuzk1, ga-rj7b1a) ────
# This is BY FAR the largest file in this directory: hundreds of scenario blocks
# driven through real `pilot-dispatcher.sh` subprocess invocations (each spawns a
# fresh bash interpreter for the ~7000-line dispatcher) — vs. a sibling median
# around 150-200 lines / well under 15s. Wall time: ~140s on 2026-07-02 (~380
# assertions, ga-iuzk1) but 17+ min on 2026-09-19, when the box was saturated
# (ga-rj7b1a: the Mayor ran it with a 3400s bound). A uniform short bound (the
# `timeout 15` sweep convention here) WILL kill it mid-run with no PASS/FAIL
# summary. That is NOT a hang. Give it no bound, or one sized for a busy host.
#
# It is a HEAVY suite (ga-rj7b1a), so it protects the machine instead of competing
# with Dolt and the supervisor: it renices itself to ni 15 (children inherit) and
# takes a machine-wide lock — at most ONE full run in flight per machine. A second
# run waits (SELFTEST_LOCK_WAIT_SECS), then exits 75 = "NOT RUN", never a test
# failure: retry later. The gate's reviewers are the exception: they never queue
# (their verdict timeout already budgets for their own A/B pair of runs). Iterating
# on a change? Run the smaller pilot-*.selftest.sh siblings and leave the full file
# for the gate. Knobs: heavy-selftest-guard.sh.
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
DISPATCHER="${PROBE_DISPATCHER:-$SELF_DIR/pilot-dispatcher.sh}"
# ga-ck3sz7: the one scenario that puts a stub dir in front of the ambient PATH (18aa, the fake `git`) runs on a PATH with
# NO real gc/bd (selftest-sandbox-path.lib.sh). Every other scenario builds its own "$SHIMBIN:/usr/bin:/bin:/usr/local/bin",
# which already leaves gc/bd out. Sourced here, at the top, so a missing lib refuses to start instead of dying at line 4353.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ga-3ebneo: _filter_built / _target_has_real_branch / _beadid_has_crew_branch /
# _beadid_matched_crew_branch_ref delegate their git lookup to three helpers and read the
# branch-name list from delivery-branch-patterns.sh. Scenarios ga-8jxe1-b, ga-rcees and
# ga-6jqr below awk-extract those probes and eval them in isolation against REAL git repos,
# where the dispatcher's own load-time `source` never ran — without the lib and the helpers
# loaded here they would read "could not tell" and go red for a harness reason. Plain
# definitions (no `export -f`): subshells and $(...) inherit them, but a spawned
# `pilot-dispatcher.sh` does not, so a scenario that simulates a missing lib still sees one.
. "$SELF_DIR/delivery-branch-patterns.sh" || { echo "FATAL: cannot source $SELF_DIR/delivery-branch-patterns.sh" >&2; exit 2; }
for _dbh in _delivery_branch_patterns_ready _delivery_branch_local_ref _delivery_branch_remote_hit; do
  _dbh_src="$(awk -v n="$_dbh" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}$/ {exit}' "$DISPATCHER")"
  [ -n "$_dbh_src" ] || { echo "FATAL: $_dbh not found in $DISPATCHER" >&2; exit 2; }
  eval "$_dbh_src"
done
unset _dbh _dbh_src

# ── Heavy suite: low priority + one full run per machine (ga-rj7b1a) ──────────
# Taken BEFORE any fixture exists: a second run waits here (or exits 75 = NOT RUN)
# instead of adding another ~90-process tree to a box that Dolt and the supervisor
# share. A readability check, not a bare `source`: a missing sibling (partial deploy)
# would otherwise kill this script under a caller's `set -e`; here it runs unguarded
# and SAYS so.
if [ -r "$SELF_DIR/heavy-selftest-guard.sh" ]; then
  . "$SELF_DIR/heavy-selftest-guard.sh"
  true
else
  echo "[heavy-selftest] WARN heavy-selftest-guard.sh not found next to this selftest — running UNGUARDED (inherited priority, no single-flight)" >&2
fi

# ── Throwaway workspace ───────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; heavy_selftest_release 2>/dev/null || true; }
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
#   FAKE_SUPPRESS_LANE     =1 → `label add lane:*` is silently dropped (ga-05604.2:
#                          same failure mode as FAKE_SUPPRESS_INFLIGHT, but for the
#                          lane tag's own retry+verify loop)
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
  *"label add"*"lane:"*)
    # ga-05604.2: track lane-label state the same way story:in-flight is
    # tracked above, so the lane write's own retry+verify loop can be
    # faithfully exercised. FAKE_SUPPRESS_LANE=1 simulates Dolt silently
    # swallowing the write (write returns 0 but never lands) — the failure
    # mode the retry loop exists to catch.
    id="$(after add)"
    lane_tok=$(printf '%s' "$args" | grep -oE 'lane:[A-Za-z0-9_-]+' | head -1)
    [ "${FAKE_SUPPRESS_LANE:-0}" = "1" ] || { [ -n "$lane_tok" ] && printf '%s' "$lane_tok" > "$STATE/$id.lane" 2>/dev/null; }
    : ;;
  *"label add"*pilot:dispatching*)
    touch "$STATE/$(after add).dispatching" 2>/dev/null || true ; : ;;
  *"label remove"*pilot:dispatching*)
    id="$(after remove)"
    rm -f "$STATE/$id.dispatching" 2>/dev/null || true
    echo "released $id" >> "$STATE/releases.log" 2>/dev/null || true ; : ;;
  *"label add"*|*"label remove"*)
    : ;;          # other label ops (pilot:dispatched, …) → no-op.
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
        if [ -f "$STATE/$id.lane" ]; then
          _lane_val="$(cat "$STATE/$id.lane" 2>/dev/null || echo "")"
          [ -n "$_lane_val" ] && lbls="${lbls:+$lbls,}\"$_lane_val\""
        fi
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
        # ga-4iw15: same counter-based race shape as ga-88g2 above, but for the
        # label the LATE re-check did NOT cover before this fix: pilot:no-auto-
        # dispatch landing (simulating the Mayor's hold — remove gate:needs-fix,
        # add pilot:no-auto-dispatch) between the claim-verify show and the late
        # pre-dispatch re-check. Separate counter file so it can be exercised
        # independently of (or alongside) FAKE_ESCALATE_AFTER_SHOWS.
        # FAKE_NOAUTO_AFTER_SHOWS=N: Nth and earlier `bd show` calls return
        # clean; (N+1)th and later carry pilot:no-auto-dispatch. Unset/empty
        # (the default) never injects it — every existing scenario is
        # byte-identical to before this seam existed.
        if [ -n "${FAKE_NOAUTO_AFTER_SHOWS:-}" ]; then
          _scf2="$STATE/$id.showcount2"
          _sc2=$(cat "$_scf2" 2>/dev/null || echo 0)
          _sc2=$((_sc2 + 1))
          echo "$_sc2" > "$_scf2"
          # ga-rfpm9: label text is now parametrized (default unchanged) so the
          # SAME shim can inject either the prefixed or bare form — proves the
          # late re-check's bare-label alias through the real dispatch_one()
          # path, not just the isolated _filter_candidates unit test above.
          [ "$_sc2" -gt "$FAKE_NOAUTO_AFTER_SHOWS" ] && lbls="${lbls:+$lbls,}\"${FAKE_NOAUTO_LABEL:-pilot:no-auto-dispatch}\""
        fi
        # ga-pd7j: mark the fixture as already in the gate-fix loop (stable label,
        # present from the start — unlike the counter-based escalation above, this
        # test isn't about racing the LABEL, it's about racing a MAYOR COMMENT).
        [ "${FAKE_GATE_NEEDS_FIX:-0}" = "1" ] && lbls="${lbls:+$lbls,}\"gate:needs-fix\""
        st="open"
        desc=""
        case "$id" in
          *sling*)
            st="${FAKE_SLING_STATUS:-open}"
            # ga-e2n96 AC3: mirror whatever the gc shim actually received via
            # --stdin (captured to $STATE/sling_stdin.txt) — everything after
            # the first line is the description, matching the real gc binary's
            # --stdin contract (first line=title, rest=description). Lets a
            # scenario assert the durable sling bead never has an empty
            # description (the AC3 invariant this bug's fix introduces).
            [ -f "$STATE/sling_stdin.txt" ] && desc=$(tail -n +2 "$STATE/sling_stdin.txt" 2>/dev/null)
            ;;
        esac
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
        printf '{"id":"%s","status":"%s","assignee":"%s","labels":[%s],"description":%s}' \
          "$id" "$st" "$asg" "$lbls" "$(printf '%s' "$desc" | jq -Rs .)" ;;
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
    elif [ "${FAKE_INCLUDE_ENGSIGNAL:-0}" = "1" ]; then
      # ga-vhyd: tt-engsignal carries NO needs:engine-window label — only its
      # own title+description text signals an engine rebuild. tt-frameworklabel
      # carries the manual framework:engine marker (already in live use, e.g.
      # ga-g7yt, but previously unwired into any exclusion). Unlike the
      # FAKE_INCLUDE_ENGWIN fixture above, both leak in UNCONDITIONALLY (no
      # --exclude-label branch to honor for either), so only the
      # _filter_candidates body-text veto / framework:engine label clause can
      # drop them. tt-benign is a P0 control that mentions "engine"/"rebuild"
      # in an UNRELATED sense and must NOT be caught (regression guard against
      # an over-broad regex).
      cat <<'JSON'
[
  {"id":"tt-engsignal","title":"Pilot despacha engine bug pro pool","priority":0,"issue_type":"bug","description":"requires a full gascity engine rebuild + binary swap + town bounce before this can ship","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-frameworklabel","title":"Engine fix needed","priority":0,"issue_type":"bug","description":"see comments for details","status":"open","labels":["framework:engine"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-benign","title":"Fix the search engine ranking bug","priority":0,"issue_type":"bug","description":"the recommendation engine rebuild of the index is unrelated to gc binary","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-keep","title":"Normal bug fixture","priority":1,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
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
    # ga-3hhnyn: FAKE_TIER2_QUERY_FAIL=1 simulates the query itself failing
    # (non-zero exit, no stdout) so a scenario can prove the lanes-full
    # backoff path's WAITING_QUERY_OK guard fails closed to "unknown" rather
    # than collapsing a failed query into "[]" (root-class:error-vs-empty).
    # Default 0/unset keeps every other scenario byte-identical.
    if [ "${FAKE_TIER2_QUERY_FAIL:-0}" = "1" ]; then
      echo "simulated bd failure for story:approved query" >&2
      exit 1
    fi
    printf '%s' "${FAKE_TIER2_JSON:-[]}" ;;
  *"--created-after"*)
    # ga-6psx5: sling orphan-adoption lookup — "did gc sling already create a
    # bead matching this exact title, despite reporting an unparseable/empty
    # bead_id?" FAKE_SLING_ORPHAN_JSON lets a scenario inject that bead so the
    # retry loop's adoption path can be proven; default [] (no orphan found)
    # keeps every other scenario byte-identical to before this seam existed.
    printf '%s' "${FAKE_SLING_ORPHAN_JSON:-[]}" ;;
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
    # ga-e2n96 AC3: capture the --stdin payload (title+description) so a scenario
    # can assert the durable sling bead never has an empty description — the
    # exact defect this bug reports (gc sling was called with a title argument
    # only, no --stdin, so the created bead's Description was unconditionally "").
    case "$*" in
      *--stdin*) cat > "$_st/sling_stdin.txt" 2>/dev/null || true ;;
    esac
    if [ "${FAKE_SLING_ALWAYS_FAIL:-0}" = "1" ] || [ "$_cnt" -le "${FAKE_SLING_FAIL_TIMES:-0}" ]; then
      printf '{"schema_version":"1","ok":false,"error":{"code":"native_store_unavailable","message":"sling: Store is required"}}'
      exit 1
    fi
    printf '{"bead_id":"tt-sling-1"}'
    ;;
  *"session list"*)  # ga-e5yw2 roster seam. Brace-in-default `${x:-{...}}` mis-parses
                     # (the inner } closes the expansion early) → use an explicit if.
                     if [ -n "${FAKE_SESSIONS_JSON:-}" ]; then printf '%s' "$FAKE_SESSIONS_JSON"; else printf '{"sessions":[]}'; fi ;;
  *"agent list"*)    # ga-7ti1t: crew-alias roster seam for _pilot_crew_aliases /
                     # _pilot_suspended_crews (both parse `<name> <status>` columns,
                     # same as the real `gc agent list`). Default: the real live
                     # <name>-<code> crews, all active (nobody suspended — matches the
                     # PRIOR unmatched-case behavior of "" for _pilot_suspended_crews,
                     # which no existing scenario depends on being non-empty).
                     if [ -n "${FAKE_AGENT_LIST_OUTPUT:-}" ]; then printf '%s' "$FAKE_AGENT_LIST_OUTPUT"; else printf 'batista-lx active\nbatista-ps active\nbatista-wa active\ndigo-wa active\nmila-wa active\noracle-wa active\npeter-wa active\nthies-ps active\nthies-wa active\n'; fi ;;
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

# ga-a2v0bz: every real-dispatcher run in this file pins DRAIN_WINDOW_OVERRIDE=OPEN, next to the RAM-level pin.
# The drain signal is AMBIENT state (~/.gastown/run/city-drain.level, rewritten by nightly-reboot.sh 23:00-23:55)
# and these runs keep the caller's real HOME. Until the pin this suite was immune only BY ACCIDENT: its PATH has no
# /usr/sbin, so `sysctl` is not found, the boot cannot be proven and the gate fails open — add /usr/sbin and every
# assertion fails at night. selftest-drain-pin-class.selftest.sh fails when a run site loses the pin.
# Runs the real dispatcher in DRY_RUN with the shims on PATH, returns the log.
run_dispatch() { # $1=FAKE_BLOCKED_IDS  $2=FAKE_INCLUDE_ENGWIN(0|1)  $3=FAKE_DEP_BEAD (optional)  $4=FAKE_INCLUDE_EPIC(0|1)  $5=FAKE_INCLUDE_PREAPPROVAL(0|1)  $6=FAKE_INCLUDE_ENGSIGNAL(0|1)
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    FAKE_BLOCKED_IDS="$1" \
    FAKE_INCLUDE_ENGWIN="${2:-0}" \
    FAKE_DEP_BEAD="${3:-}" \
    FAKE_INCLUDE_EPIC="${4:-0}" \
    FAKE_INCLUDE_PREAPPROVAL="${5:-0}" \
    FAKE_INCLUDE_ENGSIGNAL="${6:-0}" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs Step-0 TTL recovery in DRY_RUN with an injected stale-claim fixture.
run_step0() { # FAKE_STALE_JSON
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  reset_state
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
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
#   $10 = FAKE_SLING_STATUS             (bd-native status the shim reports for any *sling* id; default "open" — ga-brnlfa)
run_neverstarted() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  reset_state
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_NEVERSTARTED_MINUTES=15 \
    FAKE_NEVERSTARTED_JSON="${1:-[]}" \
    PILOT_TEST_BRANCH_BEADS="${2:-}" \
    FAKE_SESSIONS_JSON="${3:-}" \
    FAKE_SLING_STATUS="${10:-}" \
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
# Arg 1: FAKE_SUPPRESS_INFLIGHT (0|1). Arg 2: FAKE_SUPPRESS_LANE (0|1, ga-05604.2,
# default 0). Sleep is zeroed so the retry loops are fast.
run_real_dispatch() { # FAKE_SUPPRESS_INFLIGHT FAKE_SUPPRESS_LANE
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT="$1" \
    FAKE_SUPPRESS_LANE="${2:-0}" \
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
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
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

# Runs a REAL (non-dry) dispatch where pilot:no-auto-dispatch lands on the
# candidate MID-DISPATCH — after N `bd show` reads have already happened —
# simulating the Mayor's hold (remove gate:needs-fix, add pilot:no-auto-
# dispatch) racing the SAME builder-target-resolution window as ga-88g2 above
# (ga-4iw15 / ga-9uwbw incident: the hold landed 253s before dispatch, well
# inside the window, and was silently bypassed because the late re-check only
# knew about 4 labels). Arg 1: FAKE_NOAUTO_AFTER_SHOWS (unset/empty = never
# injects it, i.e. the plain happy path). Arg 2 (ga-rfpm9): the exact label
# TEXT to inject once the threshold trips — default "pilot:no-auto-dispatch"
# keeps every pre-existing call site byte-identical; pass "no-auto-dispatch"
# to exercise the bare-label alias through the SAME real dispatch_one() path.
run_real_dispatch_noauto() { # FAKE_NOAUTO_AFTER_SHOWS [FAKE_NOAUTO_LABEL]
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT=0 \
    FAKE_NOAUTO_AFTER_SHOWS="${1:-}" \
    FAKE_NOAUTO_LABEL="${2:-pilot:no-auto-dispatch}" \
    FAKE_BUGS_JSON='[{"id":"tt-flight","title":"Durable in-flight fixture","priority":0,"issue_type":"bug","description":"fixture body — context for veto test","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs a REAL (non-dry) dispatch of a gate:needs-fix candidate, with comments
# injected via FAKE_STORY_COMMENTS_JSON (ga-pd7j Mayor-hold grace window).
# Arg 1: FAKE_STORY_COMMENTS_JSON (unset/empty = no comments, plain happy path).
# Arg 2: PILOT_MAYOR_HOLD_GRACE_SECS override (default 300 if omitted).
# ga-e2n96: this scenario tests the ga-pd7j Mayor-hold-grace check in ISOLATION —
# it must not also trip the newer ga-e2n96 zero-feedback guard, a DIFFERENT check
# on the same gate:needs-fix label that skips dispatch entirely when the injected
# GATE-FEEDBACK comment is empty. Seed a baseline GATE-FEEDBACK comment so
# STORY_GATE_FEEDBACK is always non-empty here (real reprovacao shape, AC2); the
# caller's JSON (Mayor-hold comments, or "" for the plain-happy-path controls) is
# merged on top via jq rather than replacing the comment list outright.
# Arg 3 (ga-4iw15 AC2, default 1 = byte-identical to every pre-existing call
# site): FAKE_GATE_NEEDS_FIX override. Pass 0 to prove the grace window now
# fires for an ORDINARY candidate that never carried gate:needs-fix at all —
# the AC2 broadening (grace check no longer gated on gate:needs-fix being
# present) — as opposed to arg-default 1, which exercises the pre-existing
# gate:needs-fix-specific path (ga-pd7j's original scope, scenarios 5e-5g).
run_real_dispatch_mayorhold() { # FAKE_STORY_COMMENTS_JSON [PILOT_MAYOR_HOLD_GRACE_SECS] [FAKE_GATE_NEEDS_FIX]
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  reset_state
  local _mh_extra="${1:-}"
  [ -z "$_mh_extra" ] && _mh_extra="[]"
  local _mh_base='[{"text":"GATE-FEEDBACK (gate_run=test): fixture reviewer feedback so this scenario stays isolated from the ga-e2n96 zero-feedback path.","author":"gate-reviewer","created_at":"2026-01-01T00:00:00Z"}]'
  local _mh_comments
  _mh_comments=$(jq -c -n --argjson base "$_mh_base" --argjson extra "$_mh_extra" '$base + $extra' 2>/dev/null) \
    || _mh_comments="$_mh_base"
  local _mh_needsfix="${3:-1}"
  local _mh_labels='[]'
  [ "$_mh_needsfix" = "1" ] && _mh_labels='["gate:needs-fix"]'
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    PILOT_RAM_LEVEL_FILE="/nonexistent-hermetic-ram-level-for-tests" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_TEST_STATE="$STATE" \
    PILOT_DISPATCHABLE_FILE="$FIXCITY/.gc/pilot-dispatchable.json" \
    PILOT_INFLIGHT_RETRIES=3 \
    PILOT_INFLIGHT_SLEEP=0 \
    FAKE_BLOCKED_IDS="" \
    FAKE_SUPPRESS_INFLIGHT=0 \
    FAKE_GATE_NEEDS_FIX="$_mh_needsfix" \
    FAKE_STORY_COMMENTS_JSON="$_mh_comments" \
    PILOT_MAYOR_HOLD_GRACE_SECS="${2:-300}" \
    FAKE_BUGS_JSON="[{\"id\":\"tt-flight\",\"title\":\"Durable in-flight fixture\",\"priority\":0,\"issue_type\":\"bug\",\"description\":\"fixture body — context for veto test\",\"status\":\"open\",\"labels\":$_mh_labels,\"assignee\":null,\"created_at\":\"2026-06-01T00:00:00Z\",\"metadata\":{}}]" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

# Runs a DRY dispatch with a single bug candidate carrying ZERO feedback under
# gate:needs-fix and/or gate:needs-remerge (ga-e2n96) — proves the dispatcher
# does NOT blind-dispatch a builder with an empty brief, instead resubmitting an
# existing branch or escalating. FAKE_STORY_COMMENTS_JSON is left at the default
# [] (no GATE-FEEDBACK comment) so STORY_GATE_FEEDBACK is always "" here.
#   $1 = extra label(s) on the candidate, comma-joined (e.g. "gate:needs-remerge"
#        or "gate:needs-fix")
#   $2 = PILOT_TEST_REMERGE_BEADS (space-list; "tt-remerge" → branch found, "" → not found)
#   $3 = PILOT_TEST_REMERGE_UNKNOWN_BEADS (ga-x7m5rg; "tt-remerge" → lookup could not be completed, rc 2)
_MH_NOW=$(date +%s)
_MH_RECENT=$(date -u -r $(( _MH_NOW - ${PROBE_AGE:-30} )) +%Y-%m-%dT%H:%M:%SZ)
echo "Scenario 5j: fresh gastown__mayor comment defers an ORDINARY (non gate:needs-fix) dispatch (ga-4iw15 AC2)"
LOG5J="$(run_real_dispatch_mayorhold "[{\"author\":\"gastown__mayor\",\"text\":\"HOLD: re-measure first\",\"created_at\":\"$_MH_RECENT\"}]" 300 0)"
if echo "$LOG5J" | grep "ga-pd7j:.*tt-flight has a gastown__mayor comment" >/dev/null; then
  ok "pre-dispatch re-check deferred an ordinary candidate on a fresh Mayor comment, independent of gate:needs-fix (AC2)"
else
  bad "REGRESSION: AC2 did not fire — the Mayor-grace window is still gated on gate:needs-fix, so a hold on any other kind of dispatch can still be raced"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  bad "REGRESSION: story:in-flight was set despite the fresh Mayor comment on a non-gate:needs-fix candidate"
else
  ok "story:in-flight was never set — dispatch correctly deferred before finalization"
fi

echo "Scenario 5k: control — ordinary candidate, NO Mayor comment, gate:needs-fix absent → still dispatches normally (ga-4iw15 AC2)"
LOG5K="$(run_real_dispatch_mayorhold "" 300 0)"
if echo "$LOG5K" | grep "ga-pd7j:" >/dev/null; then
  bad "REGRESSION: AC2 broadening false-positived on an ordinary candidate with no Mayor activity at all"
else
  ok "no false positive — broadened grace check stays silent with no Mayor comment present"
fi
if [ -f "$STATE/tt-flight.inflight" ]; then
  ok "story:in-flight still set normally for an ordinary candidate with no Mayor activity"
else
  bad "REGRESSION: AC2 broadening broke the ordinary non-gate:needs-fix happy path"
fi

echo "probe: PROBE_AGE=${PROBE_AGE:-30} dispatcher=$(basename "$DISPATCHER") PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
