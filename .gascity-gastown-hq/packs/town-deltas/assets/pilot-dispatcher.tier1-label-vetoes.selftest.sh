#!/usr/bin/env bash
# pilot-dispatcher.tier1-label-vetoes.selftest.sh — Prove the ga-eirlk5 fix.
#
# Bug ga-eirlk5: the HQ Tier-1 pool (BUGS_JSON/DEBT_JSON/CHORE_JSON/TASK_JSON,
# feeding TIER1_JSON) never applied _filter_dispatch_gates' gates (c) and (d)
# — the "precondition-label" (blocked-on:/blocked:/depends-on:) and
# "blocking-label" (waiting-on:/next-action:, except the refino *-constroi/
# -corrige-gate/-corrige routing suffix) vetoes. It only ran
# _filter_terminal_status (gate (a), status-only — see ga-mdpe4c). Incident:
# ga-1exon4 (HQ, type=task) carried next-action:mayor from creation and was
# still selected/dispatched to gastown.dog with "No human review required."
#
# Fix: extract gates (c)+(d) out of _filter_dispatch_gates into their own
# function, _filter_label_vetoes, so BOTH paths — the full
# _filter_dispatch_gates bundle (TIER2_JSON, CTXREADY_JSON, every rig pool)
# AND the HQ Tier-1 pool (chained directly after _filter_terminal_status) —
# apply the identical predicate from one place. Gate (b) (20-char spec floor)
# and the unlettered design-first text-veto are deliberately NOT added to
# Tier-1 HQ — same reasoning ga-mdpe4c already established for gate (b) (see
# _filter_terminal_status's own header comment): out of scope for this bug,
# and (per ga-mdpe4c's own empirical finding) gate (b) has a real blast
# radius on short-but-legitimate Tier-1 bug descriptions.
#
# Runs entirely against extracted function bodies (same sed-extraction idiom
# already proven by pilot-dispatcher.tier1-exec-manual-defer.selftest.sh and
# pilot-dispatcher.text-veto-label.selftest.sh) with
# PILOT_BEAD_STATE_PY_OVERRIDE pointed at a nonexistent path so
# _filter_candidates takes its dependency-free jq-only fallback branch
# deterministically. No live Dolt/bd/gc required; safe on a live host.
#
# Scenarios (tasks/bugs, unassigned, normal-length descriptions unless noted
# — nothing here should trip any OTHER veto):
#   1. tt-tier1-normal          : no labels                        — MUST survive (control).
#   2. tt-tier1-next-action-mayor : next-action:mayor               — MUST be dropped (AC1: the
#                                                                      literal ga-1exon4 shape).
#   3. tt-tier1-next-action-constroi : next-action:batista-wa-constroi — MUST survive (refino
#                                                                      routing label, not a veto —
#                                                                      AC2, mirrors ga-f7bek).
#   4. tt-tier1-waiting-on      : waiting-on:ata-dedicada            — MUST be dropped (AC3a).
#   5. tt-tier1-blocked-on      : blocked-on:outro-lote              — MUST be dropped (AC3b).
#   6. tt-tier1-shortdesc       : description under the 20-char spec floor, no labels
#                                                                     — MUST survive (AC4: proves
#                                                                       gate (b) stays HQ-Tier-1-exempt).
#   7. Negative control: the CURRENT SHIPPED Tier-1 chain up to and including
#      _filter_terminal_status (i.e. the chain WITHOUT _filter_label_vetoes)
#      does NOT drop tt-tier1-next-action-mayor — proves _filter_terminal_status
#      alone was never responsible for this veto, so ga-eirlk5 could only be
#      closed by adding a new stage, not by editing _filter_terminal_status.
#   8. Non-divergence: _filter_dispatch_gates (full bundle) and
#      _filter_label_vetoes (standalone) applied to the SAME label-only
#      fixture set produce the IDENTICAL kept-id-set — proves the two
#      call paths share one predicate instead of two copies that could drift.
#   9. Structural drift-guards: all 4 Tier-1 HQ pipelines chain
#      _filter_label_vetoes after _filter_terminal_status in the shipped
#      file; _filter_dispatch_gates' shipped body pipes into
#      _filter_label_vetoes (proves delegation, not a duplicated inline copy).
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
FTS_FN="$(sed -n '/^_filter_terminal_status() {/,/^}$/p' "$DISPATCHER")"
FLV_FN="$(sed -n '/^_filter_label_vetoes() {/,/^}$/p' "$DISPATCHER")"
FDG_FN="$(sed -n '/^_filter_dispatch_gates() {/,/^}$/p' "$DISPATCHER")"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"

for pair in "LE_FN:_log_exclusions" "TVP:_PILOT_ENGINE_REBUILD_RE block" "EM_FN:_filter_exec_manual" "FC_FN:_filter_candidates" "FTS_FN:_filter_terminal_status" "FLV_FN:_filter_label_vetoes" "FDG_FN:_filter_dispatch_gates" "PRE:_FILTER_PREAPPROVAL_LABELS" "CAP:_FILTER_RECLAIM_CAP" "FML:_FILTER_FRAMEWORK_MARKER_LABELS"; do
  var="${pair%%:*}"; label="${pair#*:}"
  if [ -z "${!var}" ]; then
    echo "FATAL: $label not found/extracted from $DISPATCHER — has the file changed shape, or is the ga-eirlk5 fix missing?" >&2
    exit 2
  fi
done

# run_pipeline <input-json> <jq-pipe-expr-in-bash>
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
$FTS_FN
$FLV_FN
$FDG_FN
SELF_BEAD_ID=''
PILOT_BEAD_STATE_PY_OVERRIDE='/nonexistent/bead_state.py'
printf '%s' '$input' | $pipe
" 2>/dev/null
}

ids_of() { jq -c '[.[].id] | sort' 2>/dev/null <<<"$1"; }

FIXTURES='[
  {"id":"tt-tier1-normal","title":"Normal eligible HQ task","priority":1,"issue_type":"task","status":"open","labels":[],"assignee":null,"description":"Reproduces on current main; needs a fix dispatched to a builder."},
  {"id":"tt-tier1-next-action-mayor","title":"HQ task waiting on the Mayor","priority":1,"issue_type":"task","status":"open","labels":["next-action:mayor"],"assignee":null,"description":"Needs a coordinator decision before any builder can touch this."},
  {"id":"tt-tier1-next-action-constroi","title":"HQ task routed to a crew","priority":1,"issue_type":"task","status":"open","labels":["next-action:batista-wa-constroi"],"assignee":null,"description":"Refino already routed this to a crew; it is ready to build, not blocked."},
  {"id":"tt-tier1-waiting-on","title":"HQ task waiting on external data","priority":1,"issue_type":"task","status":"open","labels":["waiting-on:ata-dedicada"],"assignee":null,"description":"Cannot proceed until the referenced external artifact lands."},
  {"id":"tt-tier1-blocked-on","title":"HQ bug blocked on another lot","priority":1,"issue_type":"bug","status":"open","labels":["blocked-on:outro-lote"],"assignee":null,"description":"Fix depends on a sibling bead finishing first, tracked by this label."},
  {"id":"tt-tier1-shortdesc","title":"Short-spec HQ bug","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"description":"Typo fix."}
]'

echo "pilot-dispatcher.tier1-label-vetoes.selftest — ga-eirlk5 Tier-1 HQ next-action:/waiting-on:/blocked(-on) gap"

echo ""
echo "Scenarios 1-6: fixed production chain (_filter_candidates | _filter_terminal_status | _filter_label_vetoes)"
OUT="$(run_pipeline "$FIXTURES" "_filter_candidates | _filter_terminal_status | _filter_label_vetoes")"
KEPT="$(ids_of "$OUT")"
echo "  kept: $KEPT"

echo "$KEPT" | grep -q '"tt-tier1-normal"' \
  && ok "tt-tier1-normal survives (control)" \
  || bad "tt-tier1-normal was dropped — fix over-blocks ordinary Tier-1 work (kept=$KEPT)"

echo "$KEPT" | grep -q '"tt-tier1-next-action-mayor"' \
  && bad "REGRESSION: tt-tier1-next-action-mayor survived (ga-eirlk5 not fixed — the exact ga-1exon4 shape) (kept=$KEPT)" \
  || ok "tt-tier1-next-action-mayor dropped (ga-eirlk5 AC1 closed)"

echo "$KEPT" | grep -q '"tt-tier1-next-action-constroi"' \
  && ok "tt-tier1-next-action-constroi survives (refino routing label is not a veto — AC2)" \
  || bad "tt-tier1-next-action-constroi was dropped — fix over-blocks refino's *-constroi routing convention (kept=$KEPT)"

echo "$KEPT" | grep -q '"tt-tier1-waiting-on"' \
  && bad "REGRESSION: tt-tier1-waiting-on survived (AC3a not closed) (kept=$KEPT)" \
  || ok "tt-tier1-waiting-on dropped (AC3a closed)"

echo "$KEPT" | grep -q '"tt-tier1-blocked-on"' \
  && bad "REGRESSION: tt-tier1-blocked-on survived (AC3b not closed) (kept=$KEPT)" \
  || ok "tt-tier1-blocked-on dropped (AC3b closed)"

echo "$KEPT" | grep -q '"tt-tier1-shortdesc"' \
  && ok "tt-tier1-shortdesc survives (gate (b)'s spec floor stays HQ-Tier-1-exempt — AC4)" \
  || bad "tt-tier1-shortdesc was dropped — fix wrongly applied gate (b)'s spec floor to Tier-1 HQ (kept=$KEPT)"

echo ""
echo "Scenario 7: negative control — the OLD Tier-1 chain (_filter_candidates |"
echo "  _filter_terminal_status, WITHOUT _filter_label_vetoes) does NOT catch next-action:mayor"
OUT7="$(run_pipeline "$FIXTURES" "_filter_candidates | _filter_terminal_status")"
KEPT7="$(ids_of "$OUT7")"
echo "$KEPT7" | grep -q '"tt-tier1-next-action-mayor"' \
  && ok "confirms _filter_terminal_status alone never vetoed next-action:mayor — ga-eirlk5 could only be closed by adding _filter_label_vetoes to the chain, not by editing _filter_terminal_status" \
  || bad "unexpected: the old chain (without _filter_label_vetoes) already drops next-action:mayor (kept7=$KEPT7) — is this fixture wrong, or was the bug already fixed elsewhere?"

echo ""
echo "Scenario 8: non-divergence — _filter_dispatch_gates (full bundle) and"
echo "  _filter_label_vetoes (standalone) agree on the same label-only fixture set"
LABEL_ONLY_FIXTURES='[
  {"id":"tt-tier1-normal","title":"Normal eligible HQ task","priority":1,"issue_type":"task","status":"open","labels":[],"assignee":null,"description":"Reproduces on current main; needs a fix dispatched to a builder; long enough to clear the spec floor easily."},
  {"id":"tt-tier1-next-action-mayor","title":"HQ task waiting on the Mayor","priority":1,"issue_type":"task","status":"open","labels":["next-action:mayor"],"assignee":null,"description":"Needs a coordinator decision before any builder can touch this; long enough to clear the spec floor easily."},
  {"id":"tt-tier1-next-action-constroi","title":"HQ task routed to a crew","priority":1,"issue_type":"task","status":"open","labels":["next-action:batista-wa-constroi"],"assignee":null,"description":"Refino already routed this to a crew; it is ready to build, not blocked; long enough to clear the spec floor."},
  {"id":"tt-tier1-waiting-on","title":"HQ task waiting on external data","priority":1,"issue_type":"task","status":"open","labels":["waiting-on:ata-dedicada"],"assignee":null,"description":"Cannot proceed until the referenced external artifact lands; long enough to clear the spec floor easily."},
  {"id":"tt-tier1-blocked-on","title":"HQ bug blocked on another lot","priority":1,"issue_type":"bug","status":"open","labels":["blocked-on:outro-lote"],"assignee":null,"description":"Fix depends on a sibling bead finishing first, tracked by this label; long enough to clear the spec floor."}
]'
OUT8A="$(run_pipeline "$LABEL_ONLY_FIXTURES" "_filter_dispatch_gates")"
OUT8B="$(run_pipeline "$LABEL_ONLY_FIXTURES" "_filter_label_vetoes")"
KEPT8A="$(ids_of "$OUT8A")"
KEPT8B="$(ids_of "$OUT8B")"
if [ "$KEPT8A" = "$KEPT8B" ]; then
  ok "_filter_dispatch_gates and _filter_label_vetoes agree on the label-only fixture set (kept=$KEPT8A) — one shared predicate, no drift"
else
  bad "DIVERGENCE: _filter_dispatch_gates kept=$KEPT8A but _filter_label_vetoes kept=$KEPT8B — the two paths disagree"
fi

echo ""
echo "Scenario 9: structural drift-guards — fix present in the shipped file"
if grep -q 'BUGS_JSON=\$(echo "\$BUGS_JSON" | _filter_exec_manual .* _filter_terminal_status | _filter_label_vetoes)' "$DISPATCHER"; then
  ok "BUGS_JSON pipeline chains _filter_label_vetoes after _filter_terminal_status"
else
  bad "BUGS_JSON pipeline MISSING _filter_label_vetoes after _filter_terminal_status"
fi
if grep -q 'DEBT_JSON=\$(echo "\$DEBT_JSON" | _filter_exec_manual .* _filter_terminal_status | _filter_label_vetoes)' "$DISPATCHER"; then
  ok "DEBT_JSON pipeline chains _filter_label_vetoes after _filter_terminal_status"
else
  bad "DEBT_JSON pipeline MISSING _filter_label_vetoes after _filter_terminal_status"
fi
if grep -q 'CHORE_JSON=\$(echo "\$CHORE_JSON" | _filter_exec_manual .* _filter_terminal_status | _filter_label_vetoes)' "$DISPATCHER"; then
  ok "CHORE_JSON pipeline chains _filter_label_vetoes after _filter_terminal_status"
else
  bad "CHORE_JSON pipeline MISSING _filter_label_vetoes after _filter_terminal_status"
fi
if grep -q 'TASK_JSON=\$(echo "\$TASK_JSON" | _filter_exec_manual .* _filter_terminal_status | _filter_label_vetoes)' "$DISPATCHER"; then
  ok "TASK_JSON pipeline chains _filter_label_vetoes after _filter_terminal_status"
else
  bad "TASK_JSON pipeline MISSING _filter_label_vetoes after _filter_terminal_status"
fi

DELEGATION_REFS=$(awk '/^_filter_dispatch_gates\(\) \{/{f=1} f&&/^}$/{exit} f' "$DISPATCHER" \
  | grep -v '^[[:space:]]*#' | grep -c '_filter_label_vetoes')
if [ "$DELEGATION_REFS" -ge 1 ]; then
  ok "_filter_dispatch_gates' CODE (non-comment) pipes into _filter_label_vetoes — delegates, does not duplicate gates (c)/(d)"
else
  bad "_filter_dispatch_gates does not call _filter_label_vetoes (found $DELEGATION_REFS non-comment reference(s)) — predicate may be duplicated instead of shared"
fi

INLINE_CD_LEFTOVER=$(awk '/^_filter_dispatch_gates\(\) \{/{f=1} f&&/^}$/{exit} f' "$DISPATCHER" \
  | grep -v '^[[:space:]]*#' | grep -c 'blocked-on|blocked|depends-on')
if [ "$INLINE_CD_LEFTOVER" -eq 0 ]; then
  ok "_filter_dispatch_gates' CODE no longer inlines the precondition-label predicate (fully delegated)"
else
  bad "_filter_dispatch_gates still inlines the precondition-label predicate ($INLINE_CD_LEFTOVER reference(s)) — gates (c)/(d) duplicated, not shared"
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
