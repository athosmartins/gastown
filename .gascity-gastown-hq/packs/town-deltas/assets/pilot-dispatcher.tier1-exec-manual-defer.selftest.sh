#!/usr/bin/env bash
# pilot-dispatcher.tier1-exec-manual-defer.selftest.sh — Prove the ga-w8btn fix.
#
# Bug ga-w8btn: ga-i9q44 (issue_type=bug) was dispatched 3x on 2026-09-05
# (11:58, 21:54, 22:39) despite carrying, simultaneously: (a) label exec:manual,
# (b) defer_until in the future (2026-09-07T10:30:00Z), and in part of the
# occurrences (c) a named assignee (gastown.mayor). Root-caused by reading the
# shipped pilot-dispatcher.sh directly (not log inference) — TWO independent
# gaps in the SAME code path, the HQ Tier-1 bug/tech-debt/chore/task pool
# (BUGS_JSON/DEBT_JSON/CHORE_JSON/TASK_JSON, feeding TIER1_JSON):
#
#   Gap A: that pipeline's chain was
#     `_reconcile_empty_description_signal | _reconcile_text_veto_labels |
#      _filter_candidates | _filter_terminal_status`
#   — missing _filter_exec_manual, unlike EVERY other candidate source in this
#   file (TIER2_JSON, CTXREADY_JSON, every rig ctx-typed/RIG_TIER1/rig-fallback
#   pool — 15 call sites total), which all prepend it. Confirmed live: as of
#   this writing, `bd -C <hq> list --json -t bug <same excludes as BUGS_JSON>`
#   still returns ga-i9q44 (exec:manual, status=open) verbatim.
#
#   Gap B: defer_until (the bd-native field _pilot_defer_extend, ga-sfj3i.1,
#   writes so bd-ready-based self-serve pool probes respect a timed hold) was
#   WRITE-ONLY in this entire file — _filter_terminal_status and
#   _filter_dispatch_gates both only check the .status STRING for the literal
#   value "deferred", never the raw defer_until timestamp. That status string
#   is not authoritative on its own: inflight-reclaim-guard.py's do_reclaim()
#   unconditionally runs `bd update <id> --status open` (ga-vw26y, "so a
#   reclaimed bead is actually re-dispatchable") without ever touching
#   defer_until — confirmed live on ga-i9q44 right now: status=open AND
#   defer_until=2026-09-07T10:30:00Z coexist on the same row. Once status
#   flips to "open" while defer_until survives in the future, the
#   string-only check can never see the hold again.
#
# Fix: (A) add _filter_exec_manual to the 4 missing pipe chains. (B) teach
# _filter_candidates — the ONE stage every candidate source in this file
# already funnels through, unlike the narrower _filter_terminal_status /
# _filter_dispatch_gates — to also drop a candidate whose defer_until is a
# non-empty, still-future ISO8601 timestamp, regardless of what .status says.
# One change covers every pool at once instead of patching two narrower
# functions and leaving a latent third copy of the same gap for the next
# pipeline that adds itself to this file.
#
# Assignee (veto c) is deliberately NOT touched: an assignee alone is, BY
# DESIGN, not an unconditional veto in _filter_candidates (ga-46wq5 — "a
# Mayor-assigned bead whose owner went quiet no longer drains the dispatch
# queue in silence"). That is intentional, pre-existing behavior this bug's
# own acceptance criteria does not ask to change ("não 'consertar' removendo
# o redispatch pós-reclaim... o alvo é o veto ser respeitado, não a
# funcionalidade sumir") — once (A) and (B) hold, exec:manual alone is
# sufficient to keep ga-i9q44-shaped beads out, same as the AC demands.
#
# Runs entirely against extracted function bodies (same sed-extraction idiom
# already proven by pilot-dispatcher.text-veto-label.selftest.sh) with
# PILOT_BEAD_STATE_PY_OVERRIDE pointed at a nonexistent path so
# _filter_exec_manual takes its dependency-free jq-only fallback branch
# deterministically. No live Dolt/bd/gc required; safe on a live host.
#
# Scenarios (bugs, unassigned unless noted, normal descriptions — nothing
# here should trip any OTHER veto):
#   1. tt-bug-normal        : no labels, no defer_until       — MUST survive (control).
#   2. tt-bug-execmanual    : label exec:manual                — MUST be dropped (Gap A).
#   3. tt-bug-deferred      : defer_until 2099-01-01 (future)  — MUST be dropped (Gap B).
#   4. tt-bug-deferred-past : defer_until 2020-01-01 (past)    — MUST survive (no
#                                                                  over-block: a lapsed
#                                                                  defer must not
#                                                                  permanently strand it).
#   5. Negative control: _filter_candidates ALONE (no _filter_exec_manual in front,
#      i.e. the OLD BUGS_JSON wiring) does NOT drop an exec:manual-labeled bead —
#      proves _filter_candidates was never responsible for that veto, so Gap A
#      needed its own fix and could not have been closed inside _filter_candidates.
#   6. ga-i9q44 incident replay: the exact real shape (issue_type=bug, exec:manual
#      + future defer_until + assignee=gastown.mayor, all three at once) through
#      the FIXED production chain order (_filter_exec_manual | _filter_candidates)
#      — MUST be dropped.
#   7. Structural drift-guards: _filter_exec_manual present on all 4 Tier-1 HQ
#      pipelines; _filter_candidates' shipped body references .defer_until in
#      real (non-comment) code at least twice (select clause + reason-trace).
#
# Exit 0 iff all assertions hold.

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

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
TVP="$(sed -n "/^_PILOT_ENGINE_REBUILD_RE=/,/^\]')\$/p" "$DISPATCHER")"
EM_FN="$(sed -n '/^_filter_exec_manual() {/,/^}$/p' "$DISPATCHER")"
FC_FN="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$DISPATCHER")"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"

for pair in "LE_FN:_log_exclusions" "TVP:_PILOT_ENGINE_REBUILD_RE block" "EM_FN:_filter_exec_manual" "FC_FN:_filter_candidates" "PRE:_FILTER_PREAPPROVAL_LABELS" "CAP:_FILTER_RECLAIM_CAP" "FML:_FILTER_FRAMEWORK_MARKER_LABELS"; do
  var="${pair%%:*}"; label="${pair#*:}"
  if [ -z "${!var}" ]; then
    echo "FATAL: $label not found/extracted from $DISPATCHER — has the file changed shape?" >&2
    exit 2
  fi
done

# run_pipeline <input-json> <jq-pipe-expr-in-bash>
# jq-pipe-expr is literal bash piping _filter_exec_manual and/or
# _filter_candidates, e.g. "_filter_exec_manual | _filter_candidates"
run_pipeline() {
  local input="$1" pipe="$2"
  bash -c "
export PATH=\"/usr/bin:/bin:/usr/local/bin\"
$LOG_FN
$LE_FN
$PRE
$CAP
$FMS
$FML
$TVP
$EM_FN
$FC_FN
SELF_BEAD_ID=''
PILOT_BEAD_STATE_PY_OVERRIDE='/nonexistent/bead_state.py'
printf '%s' '$input' | $pipe
" 2>/dev/null
}

ids_of() { jq -c '[.[].id] | sort' 2>/dev/null <<<"$1"; }

FIXTURES='[
  {"id":"tt-bug-normal","title":"Normal eligible bug","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"description":"Reproduces on current main; needs a fix dispatched to a builder."},
  {"id":"tt-bug-execmanual","title":"Bug requiring physical device step","priority":1,"issue_type":"bug","status":"open","labels":["exec:manual"],"assignee":null,"description":"Requires a human to touch a physical device; must never auto-dispatch."},
  {"id":"tt-bug-deferred","title":"Bug deferred two nights for evidence","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"description":"Waiting on two consecutive clean nights before re-attempt.","defer_until":"2099-01-01T00:00:00Z"},
  {"id":"tt-bug-deferred-past","title":"Bug whose defer already lapsed","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"description":"Its hold window is long over; must be a normal candidate again.","defer_until":"2020-01-01T00:00:00Z"}
]'

echo "pilot-dispatcher.tier1-exec-manual-defer.selftest — ga-w8btn Tier-1 exec:manual + defer_until gaps"

echo ""
echo "Scenarios 1-4: fixed production chain (_filter_exec_manual | _filter_candidates)"
OUT="$(run_pipeline "$FIXTURES" "_filter_exec_manual | _filter_candidates")"
KEPT="$(ids_of "$OUT")"
echo "  kept: $KEPT"

echo "$KEPT" | grep -q '"tt-bug-normal"' \
  && ok "tt-bug-normal survives (control)" \
  || bad "tt-bug-normal was dropped — fix over-blocks ordinary Tier-1 bugs (kept=$KEPT)"

echo "$KEPT" | grep -q '"tt-bug-execmanual"' \
  && bad "REGRESSION: tt-bug-execmanual survived (Gap A: exec:manual not respected) (kept=$KEPT)" \
  || ok "tt-bug-execmanual dropped (Gap A closed)"

echo "$KEPT" | grep -q '"tt-bug-deferred"' \
  && bad "REGRESSION: tt-bug-deferred survived (Gap B: future defer_until not respected) (kept=$KEPT)" \
  || ok "tt-bug-deferred dropped (Gap B closed)"

echo "$KEPT" | grep -q '"tt-bug-deferred-past"' \
  && ok "tt-bug-deferred-past survives (a lapsed hold does not permanently strand the bead)" \
  || bad "tt-bug-deferred-past was dropped — defer_until check over-blocks a PAST hold (kept=$KEPT)"

echo ""
echo "Scenario 5: negative control — _filter_candidates ALONE (the OLD BUGS_JSON wiring,"
echo "  before _filter_exec_manual was added to the chain) does NOT catch exec:manual"
OUT5="$(run_pipeline "$FIXTURES" "_filter_candidates")"
KEPT5="$(ids_of "$OUT5")"
echo "$KEPT5" | grep -q '"tt-bug-execmanual"' \
  && ok "confirms _filter_candidates alone never vetoed exec:manual — Gap A could only be closed by adding _filter_exec_manual to the chain, not by editing _filter_candidates" \
  || bad "unexpected: _filter_candidates alone already drops exec:manual (kept5=$KEPT5) — is exec:manual handled twice now?"

echo ""
echo "Scenario 6: ga-i9q44 incident replay — exec:manual + future defer_until + named"
echo "  assignee, all three at once, through the fixed production chain"
INCIDENT='[{"id":"ga-i9q44-replay","title":"Reboot diario replay","priority":0,"issue_type":"bug","status":"open","labels":["area:infra","exec:manual","lane:small","pilot:no-auto-dispatch"],"assignee":"gastown.mayor","description":"Waiting on 2 consecutive clean nightly-reboot nights; nothing to build, evidence gate only.","defer_until":"2026-09-07T10:30:00Z"}]'
OUT6="$(run_pipeline "$INCIDENT" "_filter_exec_manual | _filter_candidates")"
KEPT6="$(ids_of "$OUT6")"
[ "$KEPT6" = "[]" ] \
  && ok "ga-i9q44-shaped bead dropped through the fixed chain (incident cannot recur via this path)" \
  || bad "ga-i9q44-shaped bead SURVIVED the fixed chain — incident not actually fixed (kept6=$KEPT6)"

echo ""
echo "Scenario 7: structural drift-guards — fixes present in the shipped file"
if grep -q 'BUGS_JSON=\$(echo "\$BUGS_JSON" | _filter_exec_manual' "$DISPATCHER"; then
  ok "BUGS_JSON pipeline includes _filter_exec_manual"
else
  bad "BUGS_JSON pipeline MISSING _filter_exec_manual"
fi
if grep -q 'DEBT_JSON=\$(echo "\$DEBT_JSON" | _filter_exec_manual' "$DISPATCHER"; then
  ok "DEBT_JSON pipeline includes _filter_exec_manual"
else
  bad "DEBT_JSON pipeline MISSING _filter_exec_manual"
fi
if grep -q 'CHORE_JSON=\$(echo "\$CHORE_JSON" | _filter_exec_manual' "$DISPATCHER"; then
  ok "CHORE_JSON pipeline includes _filter_exec_manual"
else
  bad "CHORE_JSON pipeline MISSING _filter_exec_manual"
fi
if grep -q 'TASK_JSON=\$(echo "\$TASK_JSON" | _filter_exec_manual' "$DISPATCHER"; then
  ok "TASK_JSON pipeline includes _filter_exec_manual"
else
  bad "TASK_JSON pipeline MISSING _filter_exec_manual"
fi

DEFER_CODE_REFS=$(awk '/^_filter_candidates\(\) \{/{f=1} f&&/^}$/{exit} f' "$DISPATCHER" \
  | grep -v '^[[:space:]]*#' | grep -c '\.defer_until')
if [ "$DEFER_CODE_REFS" -ge 2 ]; then
  ok "_filter_candidates' CODE (non-comment) references .defer_until $DEFER_CODE_REFS time(s): select clause + reason-trace"
else
  bad "_filter_candidates' code does not read .defer_until (found $DEFER_CODE_REFS non-comment reference(s), need >=2)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "SELFTEST PASS"
  exit 0
else
  echo "SELFTEST FAIL"
  exit 1
fi
