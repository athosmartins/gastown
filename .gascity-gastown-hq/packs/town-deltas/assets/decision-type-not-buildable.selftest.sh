#!/usr/bin/env bash
# decision-type-not-buildable.selftest.sh — regression guard for ga-rahls6k.
#
# ## Contents
# - Bug  - Where the rule lives - Cases - Not covered
#
# Bug (08/11): a bead with issue_type=decision (ga-2i4hwda: exec:auto + story:approved + routed to
# gastown.dog) went out to a pool executor. A decision is somebody's call, not a build: the dog spent
# a whole turn and refused it (pool:refused:decision-not-dog-executable). wa-7hx7x2 (also a decision,
# routed to wa-worker) was only saved by a title regex — protection by accident, not by type. The
# Pilot and the probes already drop issue_type=epic ("a container, not a build"); a decision is the
# same class and was missing from every one of those filters.
#
# Where the rule lives. "What is buildable" has one predicate (issue_type, else type, lower-cased, == decision; a type that is not
# a string reads as "not a decision") and several copies, because the places are shell, jq, python and prompt text. THIS file pins the
# ones that decide what a pool executor is HANDED, with the same fixture shapes (one definition of eligible, ga-oc6knj):
#   A. pilot-dispatcher.sh  _filter_candidates     (+ its reason trace: the drop must be VISIBLE, ga-i00xl)
#   B. scripts/pool-probe.sh  POOL_FILTER          (the dog's Step 1c probe; = VETO_FILTER + the decision drop) run end to end behind a fake bd,
#      once per call site: tier 1 (B), tier 2 and tier 3 (B2), and the unlimited re-read of the disk hold and of the gate focus hold (B3);
#      plus the log line that makes the drop visible (pp_note_decisions), the exit code, and what happens when the list cannot be read (B4)
#   C. agents/wa-worker/prompt.template.md          Step 1b2 and Step 1b3 fallback jq programs
#   D. agents/ps-worker/prompt.template.md          Step 1b2 and Step 1b3 fallback jq programs
# The places that only COUNT or REPORT demand (they can alarm or stamp a route for a bead nobody will claim) carry the same predicate
# and are pinned by their own batteries, which this file does not run:
#   scripts/pilot-missing-route-watchdog.sh --selftest              both passes (_pmrw_approved_select and the first-pass selector)
#   scripts/test_pool_autoscale_watchdog.py                         probe_would_serve: test_decision_typed_bead_is_not_demand and friends
#   scripts/approved-state-reconciler.py --selftest                 Step 1c (no starvation alarm), scenarios ga-rahls6k-a..d
#   packs/town-deltas/assets/scripts/pool-probe-vetoes.selftest.sh  pool_veto_reasons says type:decision (the Pilot's cession, the gate FAIL
#                                                                   path), and nudge-on-route-gated.selftest.sh which reads those reasons
# Copies of the EPIC rule that were read and deliberately left alone (none of them chooses what a pool executor is handed): the in-flight
# reclaim guard and its divergence report (inflight-reclaim-guard.py, inflight_reclaim_divergence.py: they act on beads that already have an
# owner), the node classifiers (ps-node-classify.py, wa-node-classify.py: node or mini, decided after the Pilot chose the bead), the
# merged-bead janitor (closes beads whose work is merged) and the child-priority janitor (priority inheritance for slices).
#
# Cases (every place):
#   decision / "Decision" / decision only in .type          -> EXCLUDED (the bug; the case folding is deliberate)
#   task, bug, feature, chore, no issue_type at all          -> SURVIVE (nothing else changes)
#   issue_type that is not a string (5, an object)           -> SURVIVE and the neighbours are still judged: a bead the
#     filter cannot read must not take the whole list down with it (a jq error would turn the list into "[]", which a
#     dog reads as "no work"), and must not be dropped on a guess either
#   [decision, task] in ONE array                            -> only the task comes out (a lone-bead fixture cannot tell a
#     filter that works from one that kills the list)
#   epic                                                      -> the Pilot still EXCLUDES it (checked in section A). The dog probe's epic
#     exclusion is bd's own --exclude-type=epic flag, which the fake bd below does not model, so it is NOT re-proven here;
#     pool-probe.selftest.sh holds the bd argv byte-for-byte and would go red if that flag disappeared
# Each exclusion is paired with a survivor in the same run, so a filter that degraded into a pass-through or into
# "drop everything" turns this red instead of vacuously green.
#
# Not covered here (and why): the ENGINE's own demand probe (internal/config/config.go, --exclude-type=epic) still
# counts a routed decision as pool demand. That is a Go change that needs an engine window (see the bead comment);
# nothing in this repo can reach it. The probes above are what stop the dog from CLAIMING it: a dog the engine wakes
# for such a bead gets [] from the probe in B. Also not covered: the paths that put a gc.routed_to on an existing bead
# (the Pilot has about 15 writers, the gate FAIL path restores one) were not audited bead type by bead type - the log
# line in B is what shows a decision that gets through to the probe anyway.
#
# Runs on extracted function bodies, a fake bd and synthetic JSON. No live Dolt/bd/gc. Safe on a live host.
# Exit 0 iff every scenario holds.

set -uo pipefail
# the pool probes read the gate focus mode and the free disk; pin both so a run inside the live city never inherits them
export GATE_FOCUS_ACTIVE_OVERRIDE=0
export DISK_FREE_OVERRIDE_MB=100000
unset GATE_FOCUS_PROBE DISK_HEADROOM_PROBE

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/pilot-dispatcher.sh}"
PROBE="${PROBE:-$SELF_DIR/scripts/pool-probe.sh}"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$PROBE" ] || { echo "FATAL: pool-probe.sh not found at $PROBE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/decision-type-selftest.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"' EXIT

# ---- the shared fixture ---------------------------------------------------------------------------------
# Every bead is otherwise dispatchable (no assignee, a real description, no veto label, no hold), so the ONLY thing
# separating "kept" from "excluded" is the issue type. Oldest first, so a probe that fails to drop the decision
# would hand it out before the task.
beads_json() {
  cat <<'EOF'
[
  {"id":"b-decision","title":"escolher o provedor","description":"x","assignee":null,"labels":["exec:auto","story:approved"],"issue_type":"decision","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-decision-caps","title":"escolher o outro","description":"x","assignee":null,"labels":[],"issue_type":"Decision","created_at":"2026-11-01T01:00:00Z","updated_at":"2026-11-01T01:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-decision-type-only","title":"so o campo type","description":"x","assignee":null,"labels":[],"type":"decision","created_at":"2026-11-01T02:00:00Z","updated_at":"2026-11-01T02:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-task","title":"uma tarefa","description":"x","assignee":null,"labels":[],"issue_type":"task","created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-bug","title":"um bug","description":"x","assignee":null,"labels":[],"issue_type":"bug","created_at":"2026-11-02T01:00:00Z","updated_at":"2026-11-02T01:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-feature","title":"uma feature","description":"x","assignee":null,"labels":[],"issue_type":"feature","created_at":"2026-11-02T02:00:00Z","updated_at":"2026-11-02T02:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-chore","title":"uma chore","description":"x","assignee":null,"labels":[],"issue_type":"chore","created_at":"2026-11-02T03:00:00Z","updated_at":"2026-11-02T03:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-notype","title":"sem tipo","description":"x","assignee":null,"labels":[],"created_at":"2026-11-02T04:00:00Z","updated_at":"2026-11-02T04:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-type-num","title":"tipo ilegivel (numero)","description":"x","assignee":null,"labels":[],"issue_type":5,"created_at":"2026-11-02T05:00:00Z","updated_at":"2026-11-02T05:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"b-type-obj","title":"tipo ilegivel (objeto)","description":"x","assignee":null,"labels":[],"issue_type":{"name":"decision"},"created_at":"2026-11-02T06:00:00Z","updated_at":"2026-11-02T06:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}
]
EOF
}
DECISIONS="b-decision b-decision-caps b-decision-type-only"
SURVIVORS="b-task b-bug b-feature b-chore b-notype b-type-num b-type-obj"

# check_ids <label> <newline-or-space separated ids that came out> [epic-expected-out]
# Asserts: every decision is gone, every survivor is present (so "drop everything" is red too).
check_ids() {
  local label="$1" got=" $(printf '%s' "$2" | tr '\n' ' ') " id
  for id in $DECISIONS; do
    case "$got" in *" $id "*) bad "$label: decision bead $id was NOT excluded (the reported bug)" ;; *) ok "$label: decision bead $id excluded" ;; esac
  done
  for id in $SURVIVORS; do
    case "$got" in *" $id "*) ok "$label: $id survives" ;; *) bad "$label: $id was dropped (got: $got)" ;; esac
  done
}

# ---- A. Pilot: _filter_candidates --------------------------------------------------------------------------
echo "A. pilot-dispatcher.sh _filter_candidates"
run_pilot_filter() { # $1 = input json file, $2 = tag ; kept ids in $WORK/$2.ids, trace in $WORK/$2.stderr
  local src="$DISPATCHER" tag="$2" log_fn le_fn consts fc_fn
  log_fn="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
  le_fn="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$src")"
  consts="$(awk '/^_FILTER_PREAPPROVAL_LABELS=/{print} /^_FILTER_FRAMEWORK_MARKER_LABELS=/{print} /^_FILTER_RECLAIM_CAP=/{print} /^_PILOT_ENGINE_REBUILD_RE=/{print} /^_PILOT_ENGINE_REBUILD_NONREQUEST_RE=/{print}' "$src")"
  fc_fn="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$src")"
  [ -n "$fc_fn" ] || { echo "FATAL: _filter_candidates() not found in $src" >&2; exit 2; }
  cat > "$WORK/$tag.sh" <<EOF
$log_fn
$le_fn
source "$SELF_DIR/framework-marker-labels.sh"
$consts
$fc_fn
SELF_BEAD_ID=""
_filter_candidates < "$1"
EOF
  bash "$WORK/$tag.sh" 2>"$WORK/$tag.stderr" | jq -r '.[].id' 2>/dev/null | sort > "$WORK/$tag.ids"
}
beads_json > "$WORK/all.json"
run_pilot_filter "$WORK/all.json" pilot
if [ ! -s "$WORK/pilot.ids" ]; then
  bad "A: the Pilot filter produced no output at all - harness broken or every bead dropped (stderr: $(head -3 "$WORK/pilot.stderr" 2>/dev/null))"
else
  check_ids "A Pilot" "$(cat "$WORK/pilot.ids")"
fi
# the drop must be VISIBLE (ga-i00xl): a line naming the bead AND the reason, never a silent filter
for id in $DECISIONS; do
  t="$(grep -F "EXCLUÍDO $id por _filter_candidates:" "$WORK/pilot.stderr" || true)"
  case "$t" in
    *"issue_type:decision"*) ok "A Pilot: trace for $id names issue_type:decision" ;;
    *) bad "A Pilot: trace for $id missing/wrong (got: '$t')" ;;
  esac
done
# the neighbours are not blamed: a survivor must have no exclusion line
for id in $SURVIVORS; do
  t="$(grep -F "EXCLUÍDO $id por _filter_candidates:" "$WORK/pilot.stderr" || true)"
  [ -z "$t" ] && ok "A Pilot: no exclusion line for survivor $id" || bad "A Pilot: survivor $id has an exclusion line: $t"
done
# epic stays out (no regression) and a decision next to it does not change that
printf '%s' '[{"id":"b-epic","title":"x","description":"x","assignee":null,"labels":[],"issue_type":"epic"},{"id":"b-task2","title":"y","description":"x","assignee":null,"labels":[],"issue_type":"task"}]' > "$WORK/epic.json"
run_pilot_filter "$WORK/epic.json" pilot-epic
if grep -qx 'b-task2' "$WORK/pilot-epic.ids" && ! grep -qx 'b-epic' "$WORK/pilot-epic.ids"; then ok "A Pilot: epic still excluded, task kept"; else bad "A Pilot: epic/task regression (kept: $(tr '\n' ' ' < "$WORK/pilot-epic.ids"))"; fi

# ---- B. the dog's probe: VETO_FILTER (all three tiers) + end to end ---------------------------------------
echo "B. scripts/pool-probe.sh"
# the program is the single-quoted value of `VETO_FILTER='...'`, on one line
veto_only="$(grep -m1 '^VETO_FILTER=' "$PROBE" | sed "s/^VETO_FILTER='//; s/'\$//")"
drop="$(grep -m1 '^DECISION_DROP_JQ=' "$PROBE" | sed "s/^DECISION_DROP_JQ='//; s/'\$//")"
# the probe runs "$VETO_FILTER | $DECISION_DROP_JQ" (POOL_FILTER) in ONE jq program; pin that composition too
grep -q '^POOL_FILTER="\$VETO_FILTER | \$DECISION_DROP_JQ"$' "$PROBE" && ok "B: POOL_FILTER is the veto filter followed by the decision drop" \
  || bad "B: POOL_FILTER is not defined as \"\$VETO_FILTER | \$DECISION_DROP_JQ\" (shape changed?)"
veto="$veto_only | $drop"
if [ -z "$veto_only" ] || [ -z "$drop" ]; then
  bad "B: could not extract VETO_FILTER / DECISION_DROP_JQ from $PROBE (line shape changed?)"
else
  out="$(jq -c --argjson now_ts "$(date +%s)" "$veto" < "$WORK/all.json" 2>&1)"
  if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    check_ids "B POOL_FILTER" "$(printf '%s' "$out" | jq -r '.[].id')"
  else
    bad "B POOL_FILTER: the program failed on the shared fixture: $out"
  fi
  # a lone decision gives [] (a real "nothing for you"), and a lone unreadable type stays
  printf '%s' '[{"id":"lone","title":"t","labels":[],"issue_type":"decision"}]' | jq -c --argjson now_ts "$(date +%s)" "$veto" | grep -qx '\[\]' \
    && ok "B POOL_FILTER: a lone decision -> []" || bad "B POOL_FILTER: a lone decision was not dropped"
fi

# end to end: the probe itself, behind a fake bd. One answer file per bd call (a missing or empty file is "[]"): tier 1 asked with
# --limit=20 (tier1.json) and with --limit=0 (tier1-all.json: the hold's unlimited re-read), tier 2 (tier2.json), tier 3 (tier3.json).
# That is what lets every POOL_FILTER call site be exercised by its own scenario instead of only the first read of tier 1.
FAKE="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$FAKE" "$FIX"
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
[ -n "${BD_ARGV_LOG:-}" ] && echo "$*" >> "$BD_ARGV_LOG"
ans() { if [ -s "$BD_FIX/$1" ]; then cat "$BD_FIX/$1"; else printf '[]'; fi; }
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*)
    for a in "$@"; do [ "$a" = "--limit=0" ] && { ans tier1-all.json; exit 0; }; done
    ans tier1.json ;;
  "ready --metadata-field gc.run_target="*) ans tier2.json ;;
  "query --json ephemeral=true"*) ans tier3.json ;;
  *) printf '[]' ;;
esac
EOF
chmod +x "$FAKE/bd"
fix_reset() { local f; for f in tier1 tier1-all tier2 tier3; do : > "$FIX/$f.json"; done; }
fix_put() { cp "$2" "$FIX/$1.json"; } # fix_put <tier1|tier1-all|tier2|tier3> <file>
# probe_run [ENV=VALUE ...]: runs the probe on whatever sits in $FIX. stdout -> probe.out, stderr -> probe.err, the exit code -> PROBE_RC,
# the pool-probe log of THIS run only -> pp.log, every bd call -> bd.argv. The children lib is pointed at nothing (a line in the log, pass-through).
probe_run() {
  : > "$WORK/pp.log"; : > "$WORK/bd.argv"
  env BD_FIX="$FIX" BD_ARGV_LOG="$WORK/bd.argv" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN=ephemeral POOL_PROBE_LOG="$WORK/pp.log" \
      POOL_PROBE_CHILDREN_LIB=/nonexistent/children-in-hand-lib.sh "$@" sh "$PROBE" gastown.dog >"$WORK/probe.out" 2>"$WORK/probe.err" </dev/null
  PROBE_RC=$?
}
probe_ids() { jq -r 'if type == "array" then map(.id) | join(",") else "?" end' < "$WORK/probe.out" 2>/dev/null; }
# The line the probe logs for the beads it skipped; $1 = the tier text as it appears in the line. Prints the ids, nothing when there is no line.
skipped_ids() { sed -n "s/.*pool-probe\[[^]]*\]: tier $1 skipped routed decision bead(s) - somebody's call, not a build: \(.*\) (ga-rahls6k)\$/\1/p" "$WORK/pp.log"; }
# e2e_verdict <label> <expected ids> : the answer, the exit code and stderr of the last probe_run
e2e_verdict() {
  local label="$1" want="$2" got; got="$(probe_ids)"
  case "$got" in
    "$want") ok "$label: the probe answers '$want'" ;;
    *) bad "$label: expected '$want', got '$got' (stderr: $(head -c 200 "$WORK/probe.err"))" ;;
  esac
  [ "$PROBE_RC" -eq 0 ] && ok "$label: exit 0" || bad "$label: exit $PROBE_RC (a [] that is a verdict, or a bead, exits 0)"
  [ ! -s "$WORK/probe.err" ] && ok "$label: nothing on stderr" || bad "$label: stderr: $(head -c 200 "$WORK/probe.err")"
}

fix_reset; fix_put tier1 "$WORK/all.json"
probe_run
# the oldest bead is a decision: before the fix the probe handed THAT out
case "$(probe_ids)" in
  "b-task") ok "B end-to-end: the oldest bead is a decision, the probe hands out the task behind it" ;;
  *"b-decision"*) bad "B end-to-end: the probe handed out a decision bead ($(probe_ids)) - the reported bug" ;;
  *) : ;;
esac
e2e_verdict "B tier 1" "b-task"
got="$(skipped_ids 1)"
[ "$got" = "b-decision,b-decision-caps,b-decision-type-only" ] && ok "B tier 1: the log names exactly the three decisions ($got)" \
  || bad "B tier 1: the log line for the skipped decisions is wrong/missing (got '$got'; log: $(tr '\n' '|' < "$WORK/pp.log" | head -c 300))"

printf '%s' '[{"id":"only-decision","title":"t","description":"x","assignee":null,"labels":[],"issue_type":"decision","updated_at":"2026-11-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}]' > "$WORK/lone.json"
fix_reset; fix_put tier1 "$WORK/lone.json"; probe_run
[ "$(cat "$WORK/probe.out")" = "[]" ] && ok "B tier 1: only a decision is routed -> [] (no work for a builder)" || bad "B tier 1: only a decision, the probe answered '$(cat "$WORK/probe.out")'"
# [] here is a clean verdict, not "could not tell": exit 0 and nothing on stderr; the log is what tells it from "nothing routed"
e2e_verdict "B tier 1 lone decision" ""
got="$(skipped_ids 1)"
[ "$got" = "only-decision" ] && ok "B tier 1 lone decision: the log says a decision was skipped ($got) - [] is not 'nothing routed'" || bad "B tier 1 lone decision: log line missing/wrong ('$got')"

# no decision anywhere: the stage is invisible - no ga-rahls6k line (a line on every probe would be noise nobody reads)
printf '%s' '[{"id":"plain-task","title":"t","description":"x","assignee":null,"labels":[],"issue_type":"task","updated_at":"2026-11-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}]' > "$WORK/plain.json"
fix_reset; fix_put tier1 "$WORK/plain.json"; probe_run
e2e_verdict "B tier 1 no decision" "plain-task"
if grep -q 'ga-rahls6k' "$WORK/pp.log"; then bad "B tier 1 no decision: the log carries a ga-rahls6k line with no decision in sight: $(grep 'ga-rahls6k' "$WORK/pp.log" | head -2)"; else ok "B tier 1 no decision: no ga-rahls6k line in the log"; fi

# ---- B2. tiers 2 and 3: each has its OWN POOL_FILTER call site, so each gets its own scenario ------------------------
# Tier 1 answers nothing here ([]), so the probe falls through. The decision is the OLDEST in the list, so a tier that
# forgot the drop would hand it out; the task behind it must come out instead (the survivor of the same run).
cat > "$WORK/tier2.json" <<'EOF'
[
  {"id":"t2-decision","title":"d","description":"x","assignee":null,"labels":[],"issue_type":"decision","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-01T00:00:00Z","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"}},
  {"id":"t2-task","title":"t","description":"x","assignee":null,"labels":[],"issue_type":"task","created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"}}
]
EOF
fix_reset; fix_put tier2 "$WORK/tier2.json"; probe_run
e2e_verdict "B2 tier 2 (legacy workflow)" "t2-task"
got="$(skipped_ids 2)"; [ "$got" = "t2-decision" ] && ok "B2 tier 2: the log names t2-decision" || bad "B2 tier 2: log line missing/wrong ('$got')"
cat > "$WORK/tier3.json" <<'EOF'
[
  {"id":"t3-decision","title":"d","description":"x","assignee":null,"labels":[],"issue_type":"decision","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}},
  {"id":"t3-task","title":"t","description":"x","assignee":null,"labels":[],"issue_type":"task","created_at":"2026-11-02T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}
]
EOF
fix_reset; fix_put tier3 "$WORK/tier3.json"; probe_run
e2e_verdict "B2 tier 3 (ephemeral store)" "t3-task"
got="$(skipped_ids 3)"; [ "$got" = "t3-decision" ] && ok "B2 tier 3: the log names t3-decision" || bad "B2 tier 3: log line missing/wrong ('$got')"

# ---- B3. the two holds re-read tier 1 without a limit (a 20-bead window of held stories): that re-read has its own POOL_FILTER ----
# The window is the engine's --limit=20: one old decision plus 19 new stories (task, no gc.kind) = a FULL window. POOL_FILTER drops the
# decision, the hold drops the 19 stories, nothing is left, the window was full -> tier 1 is read again with --limit=0, where the formula
# bead (gc.kind set: not a "new story", so the hold lets it through) waits behind them. A decision is not a "new story" for the hold either
# (its type is not task/bug/feature/chore/epic/spike), so if the re-read forgot the drop the OLDEST bead out there - the decision - would
# be handed out. The formula bead is the survivor of the same run.
jq -n '[ {id:"w-decision",title:"d",description:"x",assignee:null,labels:[],issue_type:"decision",created_at:"2026-10-01T00:00:00Z",updated_at:"2026-10-01T00:00:00Z",metadata:{"gc.routed_to":"gastown.dog"}} ]
       + [ range(0; 19) | {id:("w-story-\(.)"),title:"s",description:"x",assignee:null,labels:[],issue_type:"task",created_at:"2026-10-02T00:00:00Z",updated_at:"2026-10-02T00:00:00Z",metadata:{"gc.routed_to":"gastown.dog"}} ]' > "$WORK/window.json"
jq '. + [ {id:"w-formula",title:"f",description:"x",assignee:null,labels:[],issue_type:"task",created_at:"2026-10-03T00:00:00Z",updated_at:"2026-10-03T00:00:00Z",metadata:{"gc.routed_to":"gastown.dog","gc.kind":"workflow"}} ]' "$WORK/window.json" > "$WORK/window-all.json"
[ "$(jq length "$WORK/window.json")" = "20" ] || bad "B3: the fixture window is not 20 beads - the refetch would not be reached"
for hold in disk focus; do
  case "$hold" in
    disk)  hold_env="DISK_FREE_OVERRIDE_MB=1000"; refetch_line="free disk under the floor, the --limit=20 window held nothing but new stories" ;;
    focus) hold_env="GATE_FOCUS_ACTIVE_OVERRIDE=1"; refetch_line="gate focus mode ON, the first 20 beads held nothing but new stories" ;;
  esac
  fix_reset; fix_put tier1 "$WORK/window.json"; fix_put tier1-all "$WORK/window-all.json"; probe_run "$hold_env"
  e2e_verdict "B3 $hold hold, unlimited re-read" "w-formula"
  # the path really ran: the re-read happened (else the scenario proves nothing about that call site) and the hold said so
  grep -q -- '--limit=0' "$WORK/bd.argv" && ok "B3 $hold hold: tier 1 was read again with --limit=0" || bad "B3 $hold hold: no --limit=0 read - the re-read path was not reached"
  grep -qF "$refetch_line" "$WORK/pp.log" && ok "B3 $hold hold: the log says the window was re-read" || bad "B3 $hold hold: no re-read line in the log"
  got="$(skipped_ids 1)"; [ "$got" = "w-decision" ] && ok "B3 $hold hold: the window's log line names w-decision" || bad "B3 $hold hold: window log line missing/wrong ('$got')"
  got="$(skipped_ids '1 (refetch without a limit)')"; [ "$got" = "w-decision" ] && ok "B3 $hold hold: the re-read's log line names w-decision" || bad "B3 $hold hold: re-read log line missing/wrong ('$got')"
done

# ---- B4. the log-only stage never changes the verdict ---------------------------------------------------------------
# An array that parses but that the drop cannot read (a bare number where a bead should be): the tier is unreadable (exit 3, stderr names
# it), and the log says it could not tell - the third state, never the silence of "no decision".
printf '%s' '[1]' > "$WORK/odd.json"
fix_reset; fix_put tier1 "$WORK/odd.json"; probe_run
[ "$(cat "$WORK/probe.out")" = "[]" ] && ok "B4 unreadable element: stdout is [] (nothing found)" || bad "B4 unreadable element: stdout '$(cat "$WORK/probe.out")'"
[ "$PROBE_RC" -eq 3 ] && ok "B4 unreadable element: exit 3 (the [] is NOT 'no work')" || bad "B4 unreadable element: exit $PROBE_RC, expected 3"
grep -q 'tier 1: could not tell whether the list holds decision beads' "$WORK/pp.log" && ok "B4 unreadable element: the log says it could not tell" || bad "B4 unreadable element: no 'could not tell' line ($(tr '\n' '|' < "$WORK/pp.log" | head -c 300))"
# not JSON at all: pp_note_decisions stays out of it (the tier's own read already marks it unreadable, exit 3 + stderr)
printf '%s' 'not json at all' > "$WORK/notjson.json"
fix_reset; fix_put tier1 "$WORK/notjson.json"; probe_run
[ "$PROBE_RC" -eq 3 ] && ok "B4 not JSON: exit 3" || bad "B4 not JSON: exit $PROBE_RC, expected 3"
if grep -q 'ga-rahls6k' "$WORK/pp.log"; then bad "B4 not JSON: pp_note_decisions wrote a line for something that is not an array: $(grep 'ga-rahls6k' "$WORK/pp.log" | head -1)"; else ok "B4 not JSON: no decision line (the tier's own unreadable state owns it)"; fi

# ---- C/D. the wa-worker and ps-worker probes --------------------------------------------------------------
extract_step1b2_jq() { # the program that follows `| jq --argjson now_ts "$(date +%s)" '` on the hardcoded `bd ready` line
  local line marker after prog
  line="$(grep -F '| jq --argjson now_ts "$(date +%s)" ' "$1" | grep -F 'bd ready --metadata-field "gc.routed_to=' | head -1)"
  [ -n "$line" ] || return 1
  marker='| jq --argjson now_ts "$(date +%s)" '"'"
  after="${line#*$marker}"; [ "$after" != "$line" ] || return 1
  prog="${after%\'}"; [ -n "$prog" ] && [ "$prog" != "$after" ] || return 1
  printf '%s' "$prog"
}
extract_step1b3_jq() { # the program after `{{ .RoutedPoolQuery }} | jq -c '`
  local line marker after prog
  line="$(grep -F '{{ .RoutedPoolQuery }} | jq -c ' "$1" | head -1)"
  [ -n "$line" ] || return 1
  marker='{{ .RoutedPoolQuery }} | jq -c '"'"
  after="${line#*$marker}"; [ "$after" != "$line" ] || return 1
  prog="${after%\'}"; [ -n "$prog" ] && [ "$prog" != "$after" ] || return 1
  printf '%s' "$prog"
}
run_worker_prog() { # $1 = label, $2 = program, $3 = "--now" for the 1b2 shape
  local label="$1" prog="$2" now="$3" out
  if [ "$now" = "--now" ]; then out="$(jq -c --argjson now_ts "$(date +%s)" "$prog" < "$WORK/all.json" 2>&1)"
  else out="$(jq -c "$prog" < "$WORK/all.json" 2>&1)"; fi
  if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    check_ids "$label" "$(printf '%s' "$out" | jq -r '.[].id')"
  else
    bad "$label: the program failed on the shared fixture (a bead it cannot read must not kill the list): $out"
    return
  fi
  # a lone decision is [], and the same program keeps a lone task
  if [ "$now" = "--now" ]; then
    printf '%s' '[{"id":"lone","title":"t","labels":[],"issue_type":"decision"}]' | jq -c --argjson now_ts "$(date +%s)" "$prog" | grep -qx '\[\]' && ok "$label: a lone decision -> []" || bad "$label: a lone decision was not dropped"
  else
    printf '%s' '[{"id":"lone","title":"t","labels":[],"issue_type":"decision"}]' | jq -c "$prog" | grep -qx '\[\]' && ok "$label: a lone decision -> []" || bad "$label: a lone decision was not dropped"
  fi
}
for who in wa-worker ps-worker; do
  tpl="$CITY_ROOT/agents/$who/prompt.template.md"
  echo "C/D. $who ($tpl)"
  if [ ! -f "$tpl" ]; then bad "$who: template not found at $tpl"; continue; fi
  if prog="$(extract_step1b2_jq "$tpl")"; then run_worker_prog "$who Step 1b2" "$prog" --now; else bad "$who Step 1b2: could not extract the jq program (line shape changed?)"; fi
  if prog="$(extract_step1b3_jq "$tpl")"; then run_worker_prog "$who Step 1b3 fallback" "$prog" ""; else bad "$who Step 1b3 fallback: could not extract the jq program (line shape changed?)"; fi
done

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
