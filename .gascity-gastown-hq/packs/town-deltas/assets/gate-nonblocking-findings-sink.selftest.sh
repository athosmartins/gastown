#!/usr/bin/env bash
# gate-nonblocking-findings-sink.selftest.sh — audit of 72dc10768, finding 4: the reviewer bar of
# 2026-10-07 says non-blocking findings are "reported, never dropped", but on ALL-PASS they lived
# only on verdict beads that close at merge, read by nobody. Now `gate_nbf_prepare` (quality-gate-
# guard.sh, shared lib) extracts them from each verdict bead's VERDICT comment and the dispatcher
# appends them to the PASS comment on the SOURCE bead (+ label gate:nonblocking-findings).
#
# Tested: the pure extractor on the real comment shapes (template pasted in the first comment,
# verdict with findings, "none" forms, unreadable JSON); and, structurally, that each of the
# dispatcher's three "Quality gate PASSED" comments is preceded by gate_nbf_prepare and carries
# ${_GATE_NBF_BLOCK:-}.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi; }

extract_block() { sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'; }
FN="$(extract_block "$GUARD" "gate-extract-nonblocking-findings-fn")"
[ -n "$FN" ] || { echo "FATAL: extractor block not found" >&2; exit 2; }
eval "$FN"

# Shapes as `bd comments <vb> --json` prints them: the task text (first comment) quotes the template
# INSIDE a bd command line — no standalone "VERDICT: PASS" line — and the reviewer's verdict comment
# has the standalone line and the findings block last.
TEMPLATE='bd -C \"/x\" comment \"ga-vb\" \"VERDICT: PASS\nSUMMARY: ...\nNon-blocking findings: <one per line as severity: description, or none>\"'
VERDICT_WITH='    VERDICT: PASS\n    Reviewed 3 files.\n    Non-blocking findings:\n    low: test gap, mutation M9 survives. Removing the nested-key drop\n    fails ZERO tests; suggest one unit test.\n    low: /formato returns 200 ok:true when EVERY lot is unreadable while /janela returns 503.'
VERDICT_NONE='VERDICT: PASS\nNon-blocking findings: none'
VERDICT_DASH_NONE='VERDICT: PASS\nNon-blocking findings:\n- none'
VERDICT_SAMELINE='VERDICT: FAIL\nBlocking: x\nNon-blocking findings: low: a wording nit\nmedium: a second one'
mk() { printf '[%s]' "$(printf '{"author":"a","text":"%s"}\n' "$@" | paste -sd, -)"; }
# the helper itself must build VALID json for 2 comments — otherwise every 'nothing' case passes for the wrong reason
if printf '%s' "$(mk a b)" | jq -e 'length == 2' >/dev/null 2>&1; then ok "mk builds a 2-comment array (test harness sanity)"; else bad "mk does NOT build valid JSON for two comments — every empty-result case below would be meaningless"; fi

echo "— extractor —"
OUT=$(gate_extract_nonblocking_findings "$(mk "$TEMPLATE" "$VERDICT_WITH")")
eq "two findings, wrapped lines kept, indentation stripped (first line)" "$(printf '%s\n' "$OUT" | sed -n 1p)" "low: test gap, mutation M9 survives. Removing the nested-key drop"
eq "...continuation line kept" "$(printf '%s\n' "$OUT" | sed -n 2p)" "fails ZERO tests; suggest one unit test."
eq "...second finding kept" "$(printf '%s\n' "$OUT" | sed -n 3p)" "low: /formato returns 200 ok:true when EVERY lot is unreadable while /janela returns 503."
eq "exactly 3 lines" "$(printf '%s\n' "$OUT" | grep -c .)" "3"
eq "template placeholder alone is NOT a finding" "$(gate_extract_nonblocking_findings "$(mk "$TEMPLATE")")" ""
eq "'none' → nothing" "$(gate_extract_nonblocking_findings "$(mk "$TEMPLATE" "$VERDICT_NONE")")" ""
eq "'- none' on its own line → nothing" "$(gate_extract_nonblocking_findings "$(mk "$TEMPLATE" "$VERDICT_DASH_NONE")")" ""
OUT=$(gate_extract_nonblocking_findings "$(mk "$VERDICT_SAMELINE")")
eq "content on the 'Non-blocking findings:' line itself counts" "$(printf '%s\n' "$OUT" | sed -n 1p)" "low: a wording nit"
eq "...and the next line too" "$(printf '%s\n' "$OUT" | sed -n 2p)" "medium: a second one"
eq "the LAST verdict comment wins (a re-review supersedes)" "$(gate_extract_nonblocking_findings "$(mk "$VERDICT_WITH" "$VERDICT_NONE")")" ""
eq "unreadable JSON → nothing (never invented)" "$(gate_extract_nonblocking_findings '{nope')" ""
eq "empty input → nothing" "$(gate_extract_nonblocking_findings '')" ""
eq "object shape with .comments" "$(gate_extract_nonblocking_findings "{\"comments\":$(mk "$VERDICT_SAMELINE")}" | sed -n 1p)" "low: a wording nit"

echo "— dispatcher wiring —"
N_SITES=$(grep -cE 'bd -C "\$BEAD_CITY" comment "\$BEAD_ID" "Quality gate PASSED' "$DISPATCHER")
eq "three 'Quality gate PASSED' comment sites exist (shape pinned)" "$N_SITES" "3"
eq "the findings block appears exactly three times (two sites close their comment string on a later line)" "$(grep -c '\${_GATE_NBF_BLOCK:-}' "$DISPATCHER")" "3"
eq "every site is preceded by gate_nbf_prepare (the line right above)" "$(grep -B1 -E 'bd -C "\$BEAD_CITY" comment "\$BEAD_ID" "Quality gate PASSED' "$DISPATCHER" | grep -c '^\s*gate_nbf_prepare')" "3"
if grep -q '^gate_nbf_prepare()' "$GUARD"; then ok "gate_nbf_prepare lives in the shared guard lib (the dispatcher sources it with GATE_GUARD_LIB_ONLY=1)"; else bad "gate_nbf_prepare missing from the guard lib"; fi
if grep -A12 '^gate_nbf_prepare()' "$GUARD" | grep -q 'unreadable — not carried'; then ok "an unreadable verdict bead is logged, not read as 'no findings'"; else bad "unreadable verdict bead is not named in gate_nbf_prepare"; fi

echo
echo "== gate-nonblocking-findings-sink.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
