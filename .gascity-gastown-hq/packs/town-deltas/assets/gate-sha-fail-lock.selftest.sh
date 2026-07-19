#!/usr/bin/env bash
# gate-sha-fail-lock.selftest.sh — Prove the ga-nooaw fail-closed-by-SHA fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-nooaw): a gate FAIL did not hold the commit. Reviewers across
#   independent gate-runs can diverge (one FAIL, a later one PASS); the
#   dispatcher merged the SAME already-rejected commit SHA the moment any run
#   PASSed it. Live incident: commit afb59120 (bead wa-zmw4r) was REJECTED by
#   gate-run ga-wisp-5qzux2 (a real blocking issue — list-open fallback opened
#   a WhatsApp chat by name without verifying identity), but a later run
#   PASSED the same SHA and merged it. wa-zmw4r closed carrying gate:failed AND
#   gate:passed AND story:done simultaneously — the signature of the race.
#
#   FIX: fail-closed by SHA. When a run FAILs, durably stamp the rejected
#   commit SHA onto the source bead (gate-sha-failed:<sha> label). Before any
#   future run acts on a PASS verdict, check whether THIS EXACT SHA already
#   carries that stamp; if so, downgrade to FAIL before the merge is even
#   attempted. A NEW commit (new SHA, i.e. an actual fix) carries no stamp and
#   re-gates normally — the legitimate re-fix loop is never blocked.
#
# This harness SOURCES the dispatcher in lib-only mode to unit-test the REAL
# pure decision (gate_labels_have_sha_fail, gate_sha_fail_label) and the REAL
# bd-backed resolver (gate_bead_has_prior_sha_fail, driven by an in-shell bd
# mock), then DRIFT-GUARDS the live script so a future refactor that drops or
# reorders the fix fails loudly. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_sha_fail_label          >/dev/null 2>&1 || { echo "FATAL: gate_sha_fail_label not defined by dispatcher"; exit 1; }
type gate_labels_have_sha_fail    >/dev/null 2>&1 || { echo "FATAL: gate_labels_have_sha_fail not defined by dispatcher"; exit 1; }
type gate_bead_has_prior_sha_fail >/dev/null 2>&1 || { echo "FATAL: gate_bead_has_prior_sha_fail not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_sha_fail_label — canonical label shape (pure) ────────────────────
echo "── 1. gate_sha_fail_label (label naming) ──"
eq "formats sha into the canonical stamp" "$(gate_sha_fail_label 'deadbeef')" "gate-sha-failed:deadbeef"
eq "formats a full 40-char sha"           "$(gate_sha_fail_label 'afb591200000000000000000000000000000ab')" "gate-sha-failed:afb591200000000000000000000000000000ab"

# ── 2. gate_labels_have_sha_fail — pure membership decision ──────────────────
echo "── 2. gate_labels_have_sha_fail (pure label-set membership) ──"
eq "empty label set → no"                                  "$(gate_labels_have_sha_fail '' 'abc123')"                                    "no"
eq "unrelated labels only → no"                             "$(gate_labels_have_sha_fail 'gate:failed area:gate' 'abc123')"                "no"
eq "exact match, sole label → yes"                          "$(gate_labels_have_sha_fail 'gate-sha-failed:abc123' 'abc123')"               "yes"
eq "match among other labels → yes"                         "$(gate_labels_have_sha_fail 'gate:failed gate-sha-failed:abc123 area:gate' 'abc123')" "yes"
eq "different sha's stamp present → no"                     "$(gate_labels_have_sha_fail 'gate-sha-failed:def456' 'abc123')"               "no"
# Boundary anchoring: a longer/shorter sha sharing a prefix/suffix must NOT
# false-positive via naive substring containment.
eq "longer sha sharing our prefix does NOT match (boundary)" "$(gate_labels_have_sha_fail 'gate-sha-failed:abc1234' 'abc123')"              "no"
eq "sha embedded as a suffix does NOT match (boundary)"      "$(gate_labels_have_sha_fail 'gate-sha-failed:xabc123' 'abc123')"               "no"

# ── 3. gate_bead_has_prior_sha_fail — bd-backed resolver (mock bd) ────────────
echo "── 3. gate_bead_has_prior_sha_fail (bd show + label check, mock bd) ──"
MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=0
bd() {
  case " $* " in
    *" show "*)
      [ "$MOCK_SHOW_FAIL" = "1" ] && return 1
      printf '%s\n' "$MOCK_SHOW_JSON"
      ;;
    *) : ;;
  esac
  return 0
}

eq "(a) empty bead_id → no (never calls bd)"    "$(gate_bead_has_prior_sha_fail 'city' '' 'abc123')"     "no"
eq "(b) empty sha → no (never calls bd)"        "$(gate_bead_has_prior_sha_fail 'city' 'bead1' '')"      "no"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate:failed","area:gate"]}]'
eq "(c) bead has no gate-sha-failed label → no" "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate:failed","gate-sha-failed:abc123"]}]'
eq "(d) bead stamped for THIS sha → yes"        "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "yes"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate-sha-failed:def456"]}]'
eq "(e) bead stamped for a DIFFERENT sha → no"  "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='{"id":"bead1","labels":["gate-sha-failed:abc123"]}'
eq "(f) bare object (not array) response → yes" "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "yes"

MOCK_SHOW_JSON='[{"id":"bead1"}]'
eq "(g) labels field absent entirely → no"      "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=1
eq "(h) bd show fails (transient) → no (fail-open)" "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"
MOCK_SHOW_FAIL=0

# ── 4. DRIFT GUARD: helpers defined before the lib-only cutoff ───────────────
echo "── 4. drift guard: helpers are selftest-sourceable (defined before lib-only guard) ──"
DEF_LN=$(grep -n '^gate_bead_has_prior_sha_fail() {' "$DISPATCHER" | head -1 | cut -d: -f1)
CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "gate_bead_has_prior_sha_fail (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
else
  bad "helpers must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

# ── 5. DRIFT GUARD: pre-merge check wired in, and runs BEFORE the merge ──────
echo "── 5. drift guard: fail-closed check precedes the merge attempt ──"
has "$DISPATCHER" 'gate_bead_has_prior_sha_fail "\$BEAD_CITY" "\$BEAD_ID" "\$BRANCH_SHA"' \
  "pre-merge check calls gate_bead_has_prior_sha_fail with BEAD_CITY/BEAD_ID/BRANCH_SHA"
has "$DISPATCHER" 'OVERALL_VERDICT="FAIL"' "fail-closed check can downgrade OVERALL_VERDICT to FAIL"

CHECK_LN=$(grep -n 'gate_bead_has_prior_sha_fail "\$BEAD_CITY" "\$BEAD_ID" "\$BRANCH_SHA"' "$DISPATCHER" | head -1 | cut -d: -f1)
MERGE_LOG_LN=$(grep -n 'log "ALL PASS — proceeding to merge branch' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$CHECK_LN" ] && [ -n "$MERGE_LOG_LN" ] && [ "$CHECK_LN" -lt "$MERGE_LOG_LN" ]; then
  ok "fail-closed check (line $CHECK_LN) runs BEFORE the merge attempt (line $MERGE_LOG_LN)"
else
  bad "fail-closed check must precede the merge attempt (check=$CHECK_LN merge=$MERGE_LOG_LN)"
fi

# ── 6. DRIFT GUARD: FAIL path stamps the rejected SHA ─────────────────────────
echo "── 6. drift guard: FAIL path stamps the rejected SHA ──"
STAMP_LN=$(grep -n 'label add "\$BEAD_ID" "\$(gate_sha_fail_label "\$BRANCH_SHA")"' "$DISPATCHER" | head -1 | cut -d: -f1)
FAILED_LABEL_LN=$(grep -n 'label add "\$BEAD_ID" "gate:failed" -q' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$STAMP_LN" ]; then
  ok "FAIL path stamps the rejected SHA via gate_sha_fail_label (line $STAMP_LN)"
else
  bad "FAIL path must stamp the rejected SHA via gate_sha_fail_label"
fi
if [ -n "$STAMP_LN" ] && [ -n "$FAILED_LABEL_LN" ] && [ "$STAMP_LN" -gt "$FAILED_LABEL_LN" ]; then
  ok "SHA stamp (line $STAMP_LN) is written in the same FAIL path as gate:failed (line $FAILED_LABEL_LN)"
else
  bad "SHA stamp must sit in the FAIL path, after the gate:failed label add (stamp=$STAMP_LN failed=$FAILED_LABEL_LN)"
fi

# ── 7. syntax ──────────────────────────────────────────────────────────────
echo "── 7. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
