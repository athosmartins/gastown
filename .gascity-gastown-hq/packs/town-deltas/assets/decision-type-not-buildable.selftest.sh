#!/usr/bin/env bash
# decision-type-not-buildable.selftest.sh — regression guard for ga-rahls6k.
#
# ## Contents
# - Bug  - Four places - Cases - Not covered
#
# Bug (08/11): a bead with issue_type=decision (ga-2i4hwda: exec:auto + story:approved + routed to
# gastown.dog) went out to a pool executor. A decision is somebody's call, not a build: the dog spent
# a whole turn and refused it (pool:refused:decision-not-dog-executable). wa-7hx7x2 (also a decision,
# routed to wa-worker) was only saved by a title regex — protection by accident, not by type. The
# Pilot and the probes already drop issue_type=epic ("a container, not a build"); a decision is the
# same class and was missing from every one of those filters.
#
# Four places carry the "what is buildable" rule and all four must agree (one definition of eligible,
# ga-oc6knj), so this file pins all four with the same fixture shapes:
#   A. pilot-dispatcher.sh  _filter_candidates     (+ its reason trace: the drop must be VISIBLE, ga-i00xl)
#   B. scripts/pool-probe.sh  POOL_FILTER          (the dog's Step 1c probe, all three tiers; = VETO_FILTER + the decision drop) + an end-to-end run
#   C. agents/wa-worker/prompt.template.md          Step 1b2 and Step 1b3 fallback jq programs
#   D. agents/ps-worker/prompt.template.md          Step 1b2 and Step 1b3 fallback jq programs
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
# nothing in this repo can reach it. The probes above are what stop the dog from CLAIMING it.
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

# end to end: the probe itself, behind a fake bd that answers tier 1 with the shared fixture
FAKE="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$FAKE" "$FIX"
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*) [ -f "$BD_FIX/tier1.json" ] && cat "$BD_FIX/tier1.json" || printf '[]' ;;
  *) printf '[]' ;;
esac
EOF
chmod +x "$FAKE/bd"
probe_out() { # $1 = fixture file ; prints the probe's stdout
  cp "$1" "$FIX/tier1.json"
  env BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN=ephemeral POOL_PROBE_LOG="$WORK/pp.log" \
      POOL_PROBE_CHILDREN_LIB=/nonexistent/children-in-hand-lib.sh sh "$PROBE" gastown.dog 2>"$WORK/probe.err" </dev/null
}
# the oldest bead is a decision: before the fix the probe handed THAT out
got="$(probe_out "$WORK/all.json" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
case "$got" in
  "b-task") ok "B end-to-end: the oldest bead is a decision, the probe hands out the task behind it ($got)" ;;
  *"b-decision"*) bad "B end-to-end: the probe handed out a decision bead ($got) - the reported bug" ;;
  *) bad "B end-to-end: expected b-task, got '$got' (stderr: $(head -c 200 "$WORK/probe.err"))" ;;
esac
printf '%s' '[{"id":"only-decision","title":"t","description":"x","assignee":null,"labels":[],"issue_type":"decision","updated_at":"2026-11-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}]' > "$WORK/lone.json"
got="$(probe_out "$WORK/lone.json")"
[ "$got" = "[]" ] && ok "B end-to-end: only a decision is routed -> [] (no work for a builder)" || bad "B end-to-end: only a decision, the probe answered '$got'"
# [] here is a clean verdict, not "could not tell": exit 0 and nothing on stderr
[ ! -s "$WORK/probe.err" ] && ok "B end-to-end: nothing on stderr for that [] (it is a verdict, not a failed read)" || bad "B end-to-end: stderr: $(head -c 200 "$WORK/probe.err")"

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
