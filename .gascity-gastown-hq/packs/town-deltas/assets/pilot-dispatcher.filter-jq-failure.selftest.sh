#!/usr/bin/env bash
# pilot-dispatcher.filter-jq-failure.selftest.sh — Prove the ga-fesw8n fix.
#
# Bug ga-fesw8n (root class: error-vs-empty): _filter_candidates turned ANY failure of its
# own jq into "[]", silently. One bead with a wrongly-typed field (labels as text,
# metadata as text, a non-text element inside labels, a numeric description) took the
# WHOLE list down with it, and nothing was logged — "could not find out" left with the same
# value as "the queue is empty". The siblings failed the opposite way, also silently:
# _filter_label_vetoes / _filter_exec_manual / _filter_dispatch_gates /
# _filter_terminal_status handed their INPUT back unchanged when jq failed, so a bead that
# carried blocked-on:/exec:manual walked past the veto because a neighbour was odd.
#
# Fix contract (asserted below, for each of the five stages):
#   * one odd bead does not hide its neighbours: it is dropped, they are judged by the
#     SAME program as if it were not there (the veto still applies to them);
#   * the drop is announced: a WARN naming the stage and the bead id, on STDERR only —
#     stdout is the live JSON pipe to the next stage and must stay a clean JSON array;
#   * input that is non-blank but unreadable as a list (error text, null, an envelope
#     object) is the inert "[]" PLUS a WARN — never the quiet "[]" of a really empty queue,
#     and never the input handed back unchanged;
#   * really empty input ("[]", blank) stays quiet; a healthy sweep prints no WARN.
#   * none of it aborts the stage under the dispatcher's own `set -euo pipefail`.
#
# Runs against extracted function bodies (same sed-extraction idiom as
# pilot-dispatcher.tier1-label-vetoes.selftest.sh) with PILOT_BEAD_STATE_PY_OVERRIDE
# pointed at a nonexistent path so _filter_exec_manual takes its jq-only branch
# deterministically. No live Dolt/bd/gc required; safe on a live host.
#
# SELFTEST_PATH overrides the PATH the stages run with (default puts /usr/bin first, i.e. Apple's
# jq 1.7.1; the live Pilot has /opt/homebrew/bin first, jq 1.8.1 — the per-element WARN uses
# jq's `stderr` builtin, so run it both ways: SELFTEST_PATH=/opt/homebrew/bin:/usr/bin:/bin).
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ga-fesw8n-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# `log`/`warn` are printed to STDOUT by the real file (callers add >&2), so the harness
# defines them exactly like the dispatcher does — a WARN that forgot its >&2 would then
# corrupt the JSON on stdout and be caught by the "stdout is a clean JSON array" asserts.
LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }
warn() { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: \$*\"; }"
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
    echo "FATAL: $label not found/extracted from $DISPATCHER — has the file changed shape?" >&2
    exit 2
  fi
done

# _run_chain <mode> <input-json-or-text> <bash pipe expression>
# Sets OUT (stdout), ERR (stderr) and RC (exit status of the pipeline).
#   mode prod   — the SHAPE the dispatcher really uses: the pipe runs inside $( ... )
#                 (BUGS_JSON=$(echo "$BUGS_JSON" | _filter_exec_manual | ... )), where bash
#                 clears `set -e` for the substitution. Under `set -euo pipefail` at the top,
#                 so a stage that returns non-zero still kills the harness the way it would
#                 kill the dispatcher.
#   mode strict — the pipe runs at top level under `set -euo pipefail`: a stage that lets a
#                 failing `x=$(jq ...)` escape would abort here (measured rc=5 on the
#                 pre-fix code). Callers do not do this today; a future one might.
_run_chain() {
  local mode="$1" runner
  printf '%s' "$2" > "$TMP/in.json"
  if [ "$mode" = strict ]; then
    runner="cat '$TMP/in.json' | $3"
  else
    runner="_chain_out=\$(cat '$TMP/in.json' | $3); printf '%s' \"\$_chain_out\""
  fi
  bash -c "
set -euo pipefail
export PATH=\"${SELFTEST_PATH:-/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin}\"
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
PILOT_BEAD_STATE_PY_OVERRIDE='${BSP_OVERRIDE:-/nonexistent/bead_state.py}'
$runner
" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}
run_chain()        { _run_chain prod "$@"; }
run_chain_strict() { _run_chain strict "$@"; }

ids_of() { jq -c '[.[].id] | sort' 2>/dev/null <<<"$1"; }
is_json_array() { jq -e 'type == "array"' >/dev/null 2>&1 <<<"$1"; }
# Predicates that never pipe text into `grep -q`. Under `set -o pipefail` an early-exiting
# `grep -q` makes the writer (`echo`) die of SIGPIPE and the whole pipeline report failure even
# though the text matched — measured 37/300 false negatives on a 2 KB body and 149/300 on 47 KB,
# vs 0/300 with a here-string. A flaky assertion is worse than none.
#   has <pattern> <text>   — <text> matches <pattern>
#   warn_has <pattern>     — some WARN line of $ERR matches <pattern>
has()      { grep -q -- "$1" <<<"$2"; }
warn_has() { grep 'WARN' <<<"$ERR" | grep -- "$1" >/dev/null; }

GOOD='{"id":"tt-good","title":"Normal eligible HQ task","priority":1,"issue_type":"task","status":"open","labels":[],"assignee":null,"description":"Reproduces on current main; needs a fix dispatched to a builder."}'
# The shapes measured in the bead (table "bead ruim ao lado de uma boa").
BAD_LABELS_TEXT='{"id":"tt-bad-labels-text","title":"odd","priority":1,"issue_type":"task","status":"open","labels":"story:approved","assignee":null,"description":"labels is text instead of a list."}'
BAD_METADATA_TEXT='{"id":"tt-bad-metadata-text","title":"odd","priority":1,"issue_type":"task","status":"open","labels":[],"metadata":"oops","assignee":null,"description":"metadata is text instead of an object."}'
BAD_LABELS_NONTEXT='{"id":"tt-bad-labels-nontext","title":"odd","priority":1,"issue_type":"task","status":"open","labels":[5],"assignee":null,"description":"labels holds a number."}'
BAD_DESC_NUMBER='{"id":"tt-bad-desc-number","title":"odd","priority":1,"issue_type":"task","status":"open","labels":[],"assignee":null,"description":5}'

echo "pilot-dispatcher.filter-jq-failure.selftest — ga-fesw8n jq failure inside the filter stages"

# ── 1. Controls ──────────────────────────────────────────────────────────────
echo ""
echo "Scenario 1: healthy list — served, and silent (no WARN)"
run_chain "[$GOOD]" "_filter_exec_manual | _filter_candidates | _filter_label_vetoes"
[ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
  && ok "good bead served through the real top-up chain (rc=0)" \
  || bad "control broke: rc=$RC out=$OUT"
has 'WARN' "$ERR" \
  && bad "a healthy list produced a WARN: $ERR" \
  || ok "no WARN on a healthy list"

echo ""
echo "Scenario 2: really empty input stays quiet — empty is not an alarm"
for empty_in in '[]' '' '   '; do
  for stage in _filter_candidates _filter_exec_manual _filter_label_vetoes _filter_dispatch_gates _filter_terminal_status; do
    run_chain "$empty_in" "$stage"
    [ "$RC" = 0 ] && [ "$OUT" = '[]' ] \
      && ok "$stage on $(printf '%q' "$empty_in") → [] (rc=0)" \
      || bad "$stage on $(printf '%q' "$empty_in") → rc=$RC out='$OUT'"
    has 'WARN' "$ERR" \
      && bad "$stage: empty input $(printf '%q' "$empty_in") raised a WARN: $ERR" \
      || ok "$stage: empty input $(printf '%q' "$empty_in") raised no WARN"
  done
done

# ── 3. One odd bead must not hide its neighbours (the bead's own table) ──────
echo ""
echo "Scenario 3: odd bead next to a good one — _filter_candidates"
for spec in "labels-text|$BAD_LABELS_TEXT|tt-bad-labels-text" \
            "metadata-text|$BAD_METADATA_TEXT|tt-bad-metadata-text" \
            "labels-nontext|$BAD_LABELS_NONTEXT|tt-bad-labels-nontext" \
            "desc-number|$BAD_DESC_NUMBER|tt-bad-desc-number"; do
  name="${spec%%|*}"; rest="${spec#*|}"; badjson="${rest%|*}"; badid="${rest##*|}"
  for order in "bad-first:[$badjson,$GOOD]" "good-first:[$GOOD,$badjson]"; do
    oname="${order%%:*}"; arr="${order#*:}"
    run_chain "$arr" "_filter_candidates"
    [ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
      && ok "$name/$oname: good bead still served, odd one dropped (rc=0)" \
      || bad "$name/$oname: rc=$RC kept=$(ids_of "$OUT") (want [\"tt-good\"]) — the odd bead hid the store"
    is_json_array "$OUT" \
      && ok "$name/$oname: stdout is a clean JSON array" \
      || bad "$name/$oname: stdout is not a JSON array (a WARN leaked onto stdout?): $OUT"
    has "WARN.*_filter_candidates.*$badid\|WARN.*$badid.*_filter_candidates" "$ERR" \
      && ok "$name/$oname: WARN on stderr names the stage and $badid" \
      || bad "$name/$oname: no WARN naming _filter_candidates + $badid on stderr (err='$ERR')"
    warn_has 'ga-fesw8n' \
      || bad "$name/$oname: WARN does not carry the ga-fesw8n tag for the next reader to grep"
  done
done

echo ""
echo "Scenario 4: the measured control — a numeric assignee does not crash anything"
run_chain "[$GOOD,{\"id\":\"tt-assignee-num\",\"title\":\"odd\",\"priority\":1,\"issue_type\":\"task\",\"status\":\"open\",\"labels\":[],\"assignee\":5,\"description\":\"assignee is a number.\"}]" "_filter_candidates"
[ "$RC" = 0 ] && has '"tt-good"' "$(ids_of "$OUT")" \
  && ok "good bead served beside the numeric assignee" \
  || bad "numeric assignee case: rc=$RC out=$OUT"

echo ""
echo "Scenario 5: several odd beads at once — every one dropped and named, the good one kept"
run_chain "[$BAD_LABELS_TEXT,$GOOD,$BAD_METADATA_TEXT,$BAD_DESC_NUMBER]" "_filter_candidates"
[ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
  && ok "three odd beads dropped, the good one served" \
  || bad "kept=$(ids_of "$OUT") rc=$RC"
for badid in tt-bad-labels-text tt-bad-metadata-text tt-bad-desc-number; do
  warn_has "$badid" \
    && ok "WARN names $badid" \
    || bad "no WARN names $badid (err='$ERR')"
done

# ── 6. Input that is not a list at all: loud AND inert ───────────────────────
echo ""
echo "Scenario 6: unreadable input → inert [] + WARN, never quiet and never the input back"
for spec in "error-text|Error: dolt server unreachable" "null|null" "envelope|{\"error\":\"boom\",\"issues\":[]}" "string|\"hello\""; do
  name="${spec%%|*}"; in="${spec#*|}"
  for stage in _filter_candidates _filter_exec_manual _filter_label_vetoes _filter_dispatch_gates _filter_terminal_status; do
    run_chain "$in" "$stage"
    [ "$RC" = 0 ] \
      && ok "$stage/$name: stage did not abort (rc=0)" \
      || bad "$stage/$name: stage aborted rc=$RC (set -e leak)"
    [ "$OUT" = '[]' ] \
      && ok "$stage/$name: stdout is the inert []" \
      || bad "$stage/$name: stdout='$OUT' (want [] — unreadable input must neither pass through nor vanish)"
    warn_has "$stage" \
      && ok "$stage/$name: WARN on stderr names the stage" \
      || bad "$stage/$name: silent — unreadable input gave the same quiet result as an empty queue (err='$ERR')"
  done
done

# ── 7. A veto never fails open because the list was unreadable ───────────────
echo ""
echo "Scenario 7: the four sibling stages, with an odd bead in the list, are inert+loud — never the input handed back"
BLOCKED='{"id":"tt-blocked","title":"blocked","priority":1,"issue_type":"task","status":"open","labels":["blocked-on:outro-lote"],"assignee":null,"description":"Waiting on a sibling bead to land first."}'
MANUAL='{"id":"tt-manual","title":"manual","priority":1,"issue_type":"task","status":"open","labels":["exec:manual"],"assignee":null,"description":"A human has to do this by hand."}'
CLOSED='{"id":"tt-closed","title":"closed","priority":1,"issue_type":"task","status":"closed","labels":[],"assignee":null,"description":"Closed bead, must never dispatch."}'

# Before the fix these returned the INPUT: the blocked-on bead walked past the veto because the
# list happened to contain a bead the jq could not read.
for stage in _filter_label_vetoes _filter_dispatch_gates; do
  run_chain "[$BLOCKED,$BAD_LABELS_NONTEXT,$GOOD]" "$stage"
  [ "$RC" = 0 ] && ! has 'tt-blocked' "$OUT" \
    && ok "$stage: the blocked-on bead is NOT handed back (rc=0, out=$(ids_of "$OUT"))" \
    || bad "$stage: the blocked-on bead walked past its veto (rc=$RC out=$OUT)"
  is_json_array "$OUT" \
    && ok "$stage: stdout is a clean JSON array" \
    || bad "$stage: stdout is not a JSON array: $OUT"
  # _filter_dispatch_gates ends by piping its result into _filter_label_vetoes, so when the
  # label check is the one that cannot read the list, the WARN carries the delegate's name.
  want="$stage"; [ "$stage" = _filter_dispatch_gates ] && want="_filter_label_vetoes"
  warn_has "$want" \
    && ok "$stage: WARN on stderr (from $want)" \
    || bad "$stage: silent (err='$ERR')"
done
run_chain "[$CLOSED,5,$GOOD]" "_filter_terminal_status"
[ "$RC" = 0 ] && ! has 'tt-closed' "$OUT" \
  && ok "_filter_terminal_status: the closed bead is NOT handed back (out=$(ids_of "$OUT"))" \
  || bad "_filter_terminal_status: the closed bead walked past its veto (rc=$RC out=$OUT)"
warn_has '_filter_terminal_status' \
  && ok "_filter_terminal_status: WARN on stderr names the stage" \
  || bad "_filter_terminal_status: silent (err='$ERR')"

echo ""
echo "Scenario 7a: _filter_exec_manual is the FIRST stage of every pipeline — it isolates a non-object element itself"
run_chain "[$MANUAL,5,$GOOD,null]" "_filter_exec_manual"
[ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
  && ok "exec:manual vetoed, the number and the null dropped, good served" \
  || bad "kept=$(ids_of "$OUT") rc=$RC out=$OUT"
warn_has '_filter_exec_manual' \
  && ok "WARN on stderr names the stage" \
  || bad "silent (err='$ERR')"

echo ""
echo "Scenario 7b: the REAL chains, odd beads next to vetoed ones — every veto holds, only the good bead is served"
ODD_BEADS="$BAD_LABELS_TEXT,$BAD_METADATA_TEXT,$BAD_LABELS_NONTEXT,$BAD_DESC_NUMBER"
for spec in "tier1-hq|_filter_exec_manual | _filter_candidates | _filter_terminal_status | _filter_label_vetoes" \
            "dispatch|_filter_exec_manual | _filter_candidates | _filter_dispatch_gates" \
            "topup|_filter_exec_manual | _filter_candidates | _filter_label_vetoes"; do
  cname="${spec%%|*}"; chain="${spec#*|}"
  run_chain "[$MANUAL,$BAD_LABELS_TEXT,$BLOCKED,$BAD_METADATA_TEXT,$GOOD,$BAD_LABELS_NONTEXT,$BAD_DESC_NUMBER]" "$chain"
  [ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
    && ok "$cname chain: only the good bead served (rc=0)" \
    || bad "$cname chain: kept=$(ids_of "$OUT") rc=$RC (want [\"tt-good\"])"
  for badid in tt-bad-labels-text tt-bad-metadata-text tt-bad-labels-nontext tt-bad-desc-number; do
    warn_has "$badid" \
      && ok "$cname chain: WARN names $badid" \
      || bad "$cname chain: no WARN names $badid (err='$ERR')"
  done
done

echo ""
echo "Scenario 7c: an odd bead does not blind the exclusion trace of the beads AFTER it"
EPIC='{"id":"tt-epic","title":"an epic","priority":1,"issue_type":"epic","status":"open","labels":[],"assignee":null,"description":"An epic is never built by a generic agent."}'
run_chain "[$BAD_LABELS_TEXT,$EPIC,$GOOD]" "_filter_candidates"
has 'EXCLUÍDO tt-epic por _filter_candidates' "$ERR" \
  && ok "tt-epic (listed after the odd bead) still gets its EXCLUÍDO line" \
  || bad "tt-epic lost its EXCLUÍDO line — the trace mirror aborted at the odd bead (err='$ERR')"
has 'EXCLUÍDO tt-bad-labels-text' "$ERR" \
  && bad "the odd bead was given an invented exclusion reason: $(grep 'EXCLUÍDO tt-bad-labels-text' <<<"$ERR")" \
  || ok "the odd bead gets no invented EXCLUÍDO reason (its WARN is the explanation)"
run_chain "[$MANUAL,5,$GOOD]" "_filter_exec_manual"
has 'EXCLUÍDO tt-manual por _filter_exec_manual' "$ERR" \
  && ok "_filter_exec_manual: tt-manual still gets its EXCLUÍDO line beside a non-object element" \
  || bad "_filter_exec_manual: tt-manual lost its EXCLUÍDO line (err='$ERR')"

echo ""
echo "Scenario 7d: _filter_exec_manual through the REAL bead_state.py bridge (the branch production takes)"
BSP="$SELF_DIR/../../../scripts/bead_state.py"
if [ -f "$BSP" ] && command -v python3 >/dev/null 2>&1; then
  BSP_OVERRIDE="$BSP" run_chain "[$MANUAL,$GOOD]" "_filter_exec_manual"
  [ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
    && ok "bridge, healthy list: exec:manual vetoed, good served" \
    || bad "bridge, healthy list: kept=$(ids_of "$OUT") rc=$RC"
  has 'WARN' "$ERR" \
    && bad "bridge, healthy list raised a WARN: $ERR" \
    || ok "bridge, healthy list is silent"
  BSP_OVERRIDE="$BSP" run_chain "[$MANUAL,5,$GOOD]" "_filter_exec_manual"
  [ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
    && ok "bridge, non-object element: exec:manual still vetoed, number dropped, good served" \
    || bad "bridge, non-object element: kept=$(ids_of "$OUT") rc=$RC (the bridge failure must fall back to the label check, not hand the list back)"
  warn_has '_filter_exec_manual' \
    && ok "bridge, non-object element: WARN on stderr" \
    || bad "bridge, non-object element: silent (err='$ERR')"
  BSP_OVERRIDE="$BSP" run_chain "Error: dolt server unreachable" "_filter_exec_manual"
  [ "$RC" = 0 ] && [ "$OUT" = '[]' ] && warn_has '_filter_exec_manual' \
    && ok "bridge, unreadable input: inert [] + WARN" \
    || bad "bridge, unreadable input: rc=$RC out='$OUT' err='$ERR'"
else
  echo "  - skipped: bead_state.py or python3 not available here"
fi

# ── 8. Not an abort, even when a caller runs the stage outside $( ... ) ──────
echo ""
echo "Scenario 8: under a top-level set -euo pipefail the stage still returns (no abort, no empty stdout)"
for stage in _filter_candidates _filter_exec_manual _filter_label_vetoes _filter_dispatch_gates _filter_terminal_status; do
  run_chain_strict "Error: dolt server unreachable" "$stage"
  [ "$RC" = 0 ] && [ "$OUT" = '[]' ] \
    && ok "$stage (strict, unreadable input): rc=0 and the inert []" \
    || bad "$stage (strict, unreadable input): rc=$RC out='$OUT' — a failing jq escaped through set -e"
done
run_chain_strict "[$BAD_LABELS_NONTEXT,$GOOD]" "_filter_candidates"
[ "$RC" = 0 ] && [ "$(ids_of "$OUT")" = '["tt-good"]' ] \
  && ok "_filter_candidates (strict, odd bead): rc=0, good bead served" \
  || bad "_filter_candidates (strict, odd bead): rc=$RC kept=$(ids_of "$OUT")"

# ── 9. Structural drift-guards ───────────────────────────────────────────────
echo ""
echo "Scenario 9: structural — no stage swallows its own jq failure any more"
for fn in _filter_candidates _filter_exec_manual _filter_label_vetoes _filter_dispatch_gates _filter_terminal_status; do
  body="$(sed -n "/^$fn() {/,/^}\$/p" "$DISPATCHER")"
  has 'ga-fesw8n' "$body" \
    && ok "$fn carries the ga-fesw8n handling" \
    || bad "$fn has no ga-fesw8n handling — still swallows its own jq failure"
done

echo ""
echo "──────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
