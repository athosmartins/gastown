#!/usr/bin/env bash
# pilot-dispatcher.reclaim-anchor-newline.selftest.sh — regression harness for
# ga-jyh22: the jq anchor `$` (not `\z`) used to numeric-guard
# pilot:reclaim-count:/pilot:held-until:/pilot:held-count:<slug>: label
# suffixes admits a trailing-newline suffix ("3\n") — `$` matches BEFORE a
# final `\n` in jq/Oniguruma, so `test("^[0-9]+$")` returns true for "3\n",
# and the following `tonumber` then throws (jq: "3\n" cannot be parsed as a
# number), aborting the whole jq invocation with exit 5. This is the exact
# ga-yve5g crash mechanism (label passes a numeric-looking guard, tonumber
# then dies, `2>/dev/null` + `[ -z ] && ="[]"` turns the abort into a
# silent, wrong empty result), reproduced by a DIFFERENT malformed-suffix
# shape than the one ga-yve5g fixed (non-numeric text vs. numeric+newline).
#
# NOT exploitable today (see bead body): the only known writer
# (inflight-reclaim-guard.py) always formats the suffix via a pure-int
# f-string, which never contains a newline. This selftest exists as
# defense-in-depth so a future writer (or a hand-pasted `bd label add`)
# can never again silently zero out the Pilot's whole candidate batch.
#
# Acceptance criteria under test (bead ga-jyh22):
#   AC1. A pilot:reclaim-count: label with a purely-textual suffix
#        (escalated-at-N, the ga-yve5g shape) does not crash and is treated
#        as "no count" — the bead is NOT vetoed by the reclaim-count clause
#        alone (regression guard: this is ga-yve5g's OWN fixed behavior,
#        which the anchor change in this bead must not disturb).
#   AC2. A pilot:reclaim-count: label with a numeric suffix PLUS a trailing
#        newline ("3\n") does not crash _filter_candidates, and a healthy
#        SIBLING bead in the same input batch is NOT collaterally excluded
#        — this is the actual, observable blast radius: _cf_out is a single
#        `[.[] | select(...)]` array comprehension, so pre-fix, one bad
#        label anywhere in the batch wipes every candidate, not just its
#        own bead.
#   AC3. Positive control: a plain, well-formed numeric reclaim-count label
#        at/above the cap is still correctly vetoed after the anchor change
#        — proves the fix does not loosen the intended cap semantics.
#   AC4. Same as AC2, for the pilot:held-until: clause (the OTHER of
#        _filter_candidates' two vulnerable sites).
#   AC5. The third, differently-shaped site — _pilot_hold_or_escalate's
#        own pilot:held-count:<slug>: scalar extraction (~L2145) — does not
#        crash on a numeric+trailing-newline suffix either; the malformed
#        label is ignored (falls back to a fresh count of 0/1), not
#        silently reset by a masked jq error.
#
# Run against the pre-fix dispatcher (anchor still `$`), AC2/AC4/AC5 fail
# exactly as the bead describes — that failure is what proves this harness
# catches the bug, not just a syntax check. Run again post-fix (anchor
# `\z`), all scenarios pass.
#
# Runs entirely against extracted function bodies (same awk/sed-extraction
# idiom as this file's siblings, e.g.
# pilot-dispatcher.empty-description-label.selftest.sh) — no live bd/gc/Dolt
# required, safe on a live host.
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-reclaim-anchor-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
WARN_FN="warn() { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: \$*\"; }"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"
TVP="$(grep '^_PILOT_ENGINE_REBUILD_RE=' "$DISPATCHER"; grep '^_PILOT_DIAGNOSTIC_ONLY_RE=' "$DISPATCHER")"
FC_FN="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$DISPATCHER")"
PHE_FN="$(sed -n '/^_pilot_hold_or_escalate() {/,/^}$/p' "$DISPATCHER")"
# _filter_candidates pipes its reason-trace pass through _log_exclusions at
# its own tail (after $_cf_out is already computed and about to be printed)
# — extract it so that pipe doesn't error as "command not found" and pollute
# stderr with noise unrelated to this bead's actual assertions.
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
# ga-vmn7kv: _filter_candidates references $framework_markers (--argjson) —
# without this, the whole jq call errors (empty --argjson is invalid JSON)
# and every scenario below silently collapses to "[]" regardless of this
# bead's own fix. Absolute $SELF_DIR path (not the dispatcher's own
# BASH_SOURCE-relative source line, which would resolve against $WORK here).
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"

if [ -z "$FC_FN" ]; then
  echo "FATAL: _filter_candidates() not found in $DISPATCHER" >&2
  exit 2
fi
if [ -z "$PHE_FN" ]; then
  echo "FATAL: _pilot_hold_or_escalate() not found in $DISPATCHER" >&2
  exit 2
fi
if [ -z "$LE_FN" ]; then
  echo "FATAL: _log_exclusions() not found in $DISPATCHER" >&2
  exit 2
fi

run_filter() {
  # run_filter <input-json> -> stdout: _filter_candidates' own stdout ("[]" on empty)
  local input="$1"
  cat > "$WORK/run.sh" <<EOF
$LOG_FN
$WARN_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$TVP
$FC_FN
SELF_BEAD_ID=''
printf '%s' '$input' | _filter_candidates
EOF
  bash "$WORK/run.sh" 2>"$WORK/run.stderr"
}

kept_ids() {
  # kept_ids <filter-output-json> -> newline-separated ids, "" if empty/invalid
  printf '%s' "$1" | jq -r '.[].id' 2>/dev/null
}

run_hold_or_escalate() {
  # run_hold_or_escalate <labels-json> -> stdout: the WOULD-stamp/escalate log line (DRY_RUN=1)
  local labels="$1"
  cat > "$WORK/phe.sh" <<EOF
$LOG_FN
$WARN_FN
export DRY_RUN=1
export PILOT_HOLD_ESCALATE_CAP=5
$PHE_FN
_pilot_hold_or_escalate /fake/db ga-phe1 test-slug "test reason" "" '$labels'
EOF
  bash "$WORK/phe.sh" 2>&1
}

BASE_DESC='"description":"a normal buildable task with real content"'

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1 (AC1): escalated-at-N text suffix — no crash, treated as no-count, not vetoed"
IN1="[{\"id\":\"ga-esc1\",\"assignee\":null,\"labels\":[\"pilot:reclaim-count:escalated-at-3\"],\"issue_type\":\"bug\",\"metadata\":{},$BASE_DESC}]"
OUT1="$(run_filter "$IN1")"
K1="$(kept_ids "$OUT1")"
[ "$K1" = "ga-esc1" ] \
  && ok "AC1: non-numeric suffix ignored, bead not vetoed by reclaim-count alone (kept: $K1)" \
  || bad "AC1: expected ga-esc1 kept, got: $OUT1 (stderr: $(cat "$WORK/run.stderr"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2 (AC3 positive control): well-formed numeric suffix >= cap still vetoes"
IN2="[{\"id\":\"ga-cap1\",\"assignee\":null,\"labels\":[\"pilot:reclaim-count:3\"],\"issue_type\":\"bug\",\"metadata\":{},$BASE_DESC}]"
OUT2="$(run_filter "$IN2")"
K2="$(kept_ids "$OUT2")"
[ -z "$K2" ] \
  && ok "AC3: reclaim-count:3 >= cap(3) still correctly vetoes the bead (fix does not loosen the cap)" \
  || bad "AC3: expected ga-cap1 excluded, got kept: $K2"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3 (AC2 — THE bug): reclaim-count numeric+trailing-newline suffix must not"
echo "  crash the WHOLE batch — a healthy sibling bead must survive"
IN3='[{"id":"ga-bad1","assignee":null,"labels":["pilot:reclaim-count:3\n"],"issue_type":"bug","metadata":{},'"$BASE_DESC"'},
      {"id":"ga-healthy1","assignee":null,"labels":[],"issue_type":"bug","metadata":{},'"$BASE_DESC"'}]'
OUT3="$(run_filter "$IN3")"
K3="$(kept_ids "$OUT3")"
if echo "$K3" | grep -qx "ga-healthy1"; then
  ok "AC2: trailing-newline label does not crash the batch — sibling ga-healthy1 survives (kept: $(echo "$K3" | tr '\n' ' '))"
else
  bad "AC2: sibling ga-healthy1 was collaterally wiped out — batch crashed (kept: '$K3', stderr: $(cat "$WORK/run.stderr"))"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4 (AC4): same trailing-newline shape on pilot:held-until: — no crash,"
echo "  healthy sibling survives"
IN4='[{"id":"ga-badheld1","assignee":null,"labels":["pilot:held","pilot:held-until:99999999999\n"],"issue_type":"bug","metadata":{},'"$BASE_DESC"'},
      {"id":"ga-healthy2","assignee":null,"labels":[],"issue_type":"bug","metadata":{},'"$BASE_DESC"'}]'
OUT4="$(run_filter "$IN4")"
K4="$(kept_ids "$OUT4")"
if echo "$K4" | grep -qx "ga-healthy2"; then
  ok "AC4: held-until trailing-newline label does not crash the batch — sibling ga-healthy2 survives (kept: $(echo "$K4" | tr '\n' ' '))"
else
  bad "AC4: sibling ga-healthy2 was collaterally wiped out via held-until crash (kept: '$K4', stderr: $(cat "$WORK/run.stderr"))"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 5 (AC5): _pilot_hold_or_escalate's own pilot:held-count:<slug>: scalar"
echo "  extraction (~L2145) does not crash on a numeric+trailing-newline suffix"
LBL5='["pilot:held-count:test-slug:2\n"]'
PHE_OUT5="$(run_hold_or_escalate "$LBL5")"
echo "$PHE_OUT5" | grep -qE 'WOULD (stamp|ESCALATE)' \
  && ok "AC5: malformed held-count label does not abort the function — it still logs a WOULD-stamp/escalate decision ($PHE_OUT5)" \
  || bad "AC5: expected a WOULD-stamp/escalate log line, got: $PHE_OUT5"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "SELFTEST PASS"
  exit 0
else
  echo "SELFTEST FAIL"
  exit 1
fi
