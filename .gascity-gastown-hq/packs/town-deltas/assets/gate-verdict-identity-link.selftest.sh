#!/usr/bin/env bash
# gate-verdict-identity-link.selftest.sh (ga-6wel0o)
#
# Proves: gate_check_verdict_identity_link() detects when a verdict bead's
# final PASS/FAIL was recorded by an identity OTHER than the one the bead
# was durably linked to (or by nobody-in-particular, when the durable link
# itself is gone) — and flags it (label + comment + loud log) instead of
# letting it pass through gate_collect_verdicts indistinguishable from a
# normal, correctly-attributed verdict.
#
# ROOT CAUSE it guards (ga-6wel0o, live 2026-09-17): gate-run ga-f40t9d
# (branch crew/wa-worker/wa-hphyc, required_reviewers=1) durably assigned its
# one verdict bead (ga-8jbtfq) to gate-reviewer-adhoc-e9160e4899
# (assign_verdict_bead_verified, ga-67hae) — that reviewer never ACKed (a
# known, accepted failure mode; see the ga-eqjo scope-reduction note in the
# dispatcher). The bead was instead closed with a well-formed "VERDICT: PASS"
# by gate-reviewer-adhoc-94fbe0f8d3, an UNRELATED reviewer whose own task (a
# different branch, a different gate-run) had already finished. By collection
# time ga-8jbtfq's assignee AND metadata.gc.session_name were both empty —
# nothing distinguished this from a normal completed review, so Phase C
# counted "1/1 verdicts" and merged. gate_collect_verdicts() itself has never
# checked WHO closed a verdict bead, only THAT it closed with a PASS/FAIL
# label — this suite targets that specific gap.
#
# Design intent (NOT enforcement): a mismatched verdict is COUNTED, never
# discarded — the review that landed was real work, and this file's own
# convention is that holding back good work is the expensive, silent error
# (ga-cjrxh). This suite proves visibility (label + comment + log), not
# rejection — gate_collect_verdicts' PASS/FAIL/VERDICTS_RECEIVED accounting
# is intentionally untouched by this fix and is NOT re-tested here (see
# gate-verdict-drained-reviewer-rescue.selftest.sh for that function's own
# coverage).
#
# Strategy: extract the LIVE "gate-verdict-identity-link-fn" block verbatim
# (real production code) and execute it under the dispatcher's own
# `set -euo pipefail`, stubbing only the I/O boundary (`bd`, `warn`). A
# MUTATION TEST disables the equality comparison and proves a previously
# clean (matched-identity) case then gets false-flagged — proof this suite
# is not vacuous.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-verdict-identity-link.selftest (ga-6wel0o) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

FN_LINK="$(extract_block "$DISPATCHER" "gate-verdict-identity-link-fn")"
if [ -z "$FN_LINK" ]; then
  echo "FATAL: could not locate 'gate-verdict-identity-link-fn' sentinel block in $DISPATCHER"
  exit 1
fi
ok "located live gate_check_verdict_identity_link() via sentinel extraction"

# run_check <dispatcher-file> <vb_id> <bd_log> -> stdout: captured stderr
# (WARN lines) from a single gate_check_verdict_identity_link call.
#
# Re-extracts the function from <dispatcher-file> on EVERY call (not from a
# pre-captured global) — required so the mutation test below, which passes a
# MUTATED copy of the file, actually exercises the mutated code instead of
# silently re-running the original (the exact gap that made an earlier draft
# of this suite's mutation test a false pass).
#
# Fixture beads (fed one per invocation):
#   vb-match            metadata.gc.session_name=reviewer-A  comment author=reviewer-A  -> no flag
#   vb-assignee-fallback metadata={} assignee=reviewer-E      comment author=reviewer-E  -> no flag (assignee fallback)
#   vb-mismatch         metadata.gc.session_name=reviewer-A  comment author=reviewer-B  -> FLAGGED (mismatch)
#   vb-already-flagged  same mismatch as vb-mismatch, but ALREADY carries the
#                       verdict:identity-unlinked label (as if a prior sweep
#                       already flagged it)                                  -> no NEW writes (idempotent)
#   vb-nolink           metadata=null assignee=null           comment author=reviewer-C  -> FLAGGED (no durable link)
#   vb-nocomment        metadata.gc.session_name=reviewer-D  comments=[]                -> no flag (nothing to compare)
#   vb-unreadable       bd show fails entirely                                          -> no flag, no crash
run_check() {
  local file="$1" vb="$2" bd_log="$3"
  local fn_link
  fn_link="$(extract_block "$file" "gate-verdict-identity-link-fn")"
  if [ -z "$fn_link" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    BD_LOG="$1"; VB="$2"

    VB_MATCH='"'"'{"metadata":{"gc.session_name":"reviewer-A"},"assignee":"reviewer-A"}'"'"'
    VB_MATCH_COMMENTS='"'"'[{"author":"reviewer-A","text":"VERDICT: PASS\nSummary: looks good."}]'"'"'
    VB_FALLBACK='"'"'{"metadata":{},"assignee":"reviewer-E"}'"'"'
    VB_FALLBACK_COMMENTS='"'"'[{"author":"reviewer-E","text":"VERDICT: FAIL\nBlocking issue 1: nope."}]'"'"'
    VB_MISMATCH='"'"'{"metadata":{"gc.session_name":"reviewer-A"},"assignee":"reviewer-A"}'"'"'
    VB_MISMATCH_COMMENTS='"'"'[{"author":"reviewer-B","text":"VERDICT: PASS\nSummary: reviewed everything."}]'"'"'
    VB_ALREADY_FLAGGED='"'"'{"metadata":{"gc.session_name":"reviewer-A"},"assignee":"reviewer-A","labels":["type:quality-gate-verdict","verdict:PASS","verdict:identity-unlinked"]}'"'"'
    VB_NOLINK='"'"'{"metadata":null,"assignee":null}'"'"'
    VB_NOLINK_COMMENTS='"'"'[{"author":"reviewer-C","text":"VERDICT: FAIL\nBlocking issue 1: race condition."}]'"'"'
    VB_NOCOMMENT='"'"'{"metadata":{"gc.session_name":"reviewer-D"},"assignee":"reviewer-D"}'"'"'

    bd() {
      case " $* " in
        *" show vb-match "*)             echo "$VB_MATCH"; return 0 ;;
        *" show vb-assignee-fallback "*) echo "$VB_FALLBACK"; return 0 ;;
        *" show vb-mismatch "*)          echo "$VB_MISMATCH"; return 0 ;;
        *" show vb-already-flagged "*)   echo "$VB_ALREADY_FLAGGED"; return 0 ;;
        *" show vb-nolink "*)            echo "$VB_NOLINK"; return 0 ;;
        *" show vb-nocomment "*)         echo "$VB_NOCOMMENT"; return 0 ;;
        *" show vb-unreadable "*)        return 1 ;;
        *" comments vb-match "*)             echo "$VB_MATCH_COMMENTS"; return 0 ;;
        *" comments vb-assignee-fallback "*) echo "$VB_FALLBACK_COMMENTS"; return 0 ;;
        *" comments vb-mismatch "*)          echo "$VB_MISMATCH_COMMENTS"; return 0 ;;
        *" comments vb-nolink "*)            echo "$VB_NOLINK_COMMENTS"; return 0 ;;
        *" comments vb-nocomment "*)         echo "[]"; return 0 ;;
        *" label add "*)  echo "$*" >> "$BD_LOG"; return 0 ;;
        *" comment "*)    echo "$*" >> "$BD_LOG"; return 0 ;;
      esac
      echo "UNEXPECTED:$*" >> "$BD_LOG"
      return 0
    }
    warn() { echo "WARN: $*" >&2; }
    log()  { echo "LOG: $*" >&2; }

    '"$fn_link"'

    gate_check_verdict_identity_link "$VB"
    echo "RC=$?"
  ' _ "$bd_log" "$vb"
}

echo "── 1. Matched identity (metadata link == comment author): not flagged ──"
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-match "$BD_LOG" 2>&1)"
if grep -q "identity-unlinked" "$BD_LOG"; then
  bad "vb-match was labeled identity-unlinked even though its link matches the comment author — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "vb-match was NOT labeled (durable link and comment author agree)"
fi
case "$OUT" in
  *"IDENTITY MISMATCH"*|*"NO DURABLE LINK"*) bad "vb-match produced a spurious WARN: $OUT" ;;
  *) ok "vb-match produced no mismatch/no-link WARN" ;;
esac
rm -f "$BD_LOG"

echo "── 2. Assignee fallback (no metadata, but assignee matches comment author): not flagged ──"
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-assignee-fallback "$BD_LOG" 2>&1)"
if grep -q "identity-unlinked" "$BD_LOG"; then
  bad "vb-assignee-fallback was labeled even though assignee matches the comment author — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "vb-assignee-fallback was NOT labeled (assignee-only link still verifies)"
fi
rm -f "$BD_LOG"

echo "── 3. Identity mismatch (durable link says reviewer-A, comment authored by reviewer-B): FLAGGED ──"
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-mismatch "$BD_LOG" 2>&1)"
grep -q "label add vb-mismatch verdict:identity-unlinked" "$BD_LOG" \
  && ok "vb-mismatch was labeled verdict:identity-unlinked" \
  || bad "vb-mismatch was NOT labeled — bd_log: $(tr '\n' ';' < "$BD_LOG")"
grep -q "comment vb-mismatch" "$BD_LOG" \
  && ok "vb-mismatch got an audit comment" \
  || bad "vb-mismatch got no audit comment — bd_log: $(tr '\n' ';' < "$BD_LOG")"
case "$OUT" in
  *"IDENTITY MISMATCH"*"reviewer-A"*"reviewer-B"*) ok "WARN names both identities (linked=reviewer-A, actual=reviewer-B)" ;;
  *) bad "WARN did not name both identities as expected; got: $OUT" ;;
esac
rm -f "$BD_LOG"

echo "── 3b. Idempotent: an ALREADY-flagged bead gets no duplicate comment on a later sweep ──"
# gate_collect_verdicts() re-scans every verdict bead on every sweep until the
# whole run finalizes — a required_reviewers>1 run whose sibling slots are
# still pending would otherwise re-process this same closed, already-flagged
# bead again next sweep. Without the idempotency guard this fixture would hit
# the bd() mock's catch-all (no "comments vb-already-flagged" case is
# defined) and log "UNEXPECTED:...".
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-already-flagged "$BD_LOG" 2>&1)"
case "$OUT" in
  *"RC=0"*) ok "vb-already-flagged: function returns cleanly (rc=0)" ;;
  *) bad "vb-already-flagged: unexpected exit — $OUT" ;;
esac
if [ -s "$BD_LOG" ]; then
  bad "vb-already-flagged triggered bd write(s) on a repeat sweep (not idempotent) — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "vb-already-flagged produced ZERO bd calls beyond the initial show (no duplicate comment, no wasted comments-fetch)"
fi
case "$OUT" in
  *"IDENTITY MISMATCH"*|*"NO DURABLE LINK"*) bad "vb-already-flagged produced a fresh WARN on a repeat sweep: $OUT" ;;
  *) ok "vb-already-flagged produced no fresh WARN (already recorded, nothing new to say)" ;;
esac
rm -f "$BD_LOG"

echo "── 4. No durable link at all (metadata AND assignee null — the ga-8jbtfq real shape): FLAGGED ──"
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-nolink "$BD_LOG" 2>&1)"
grep -q "label add vb-nolink verdict:identity-unlinked" "$BD_LOG" \
  && ok "vb-nolink was labeled verdict:identity-unlinked" \
  || bad "vb-nolink was NOT labeled — bd_log: $(tr '\n' ';' < "$BD_LOG")"
case "$OUT" in
  *"NO DURABLE LINK"*"reviewer-C"*) ok "WARN reports no durable link and names the actual author (reviewer-C)" ;;
  *) bad "WARN did not report the no-link case as expected; got: $OUT" ;;
esac
rm -f "$BD_LOG"

echo "── 5. No VERDICT comment yet (nothing to compare against): not flagged, no crash ──"
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-nocomment "$BD_LOG" 2>&1)"
case "$OUT" in
  *"RC=0"*) ok "vb-nocomment: function returns cleanly (rc=0)" ;;
  *) bad "vb-nocomment: unexpected exit — $OUT" ;;
esac
if grep -q "identity-unlinked" "$BD_LOG"; then
  bad "vb-nocomment was labeled despite having no VERDICT comment to compare — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "vb-nocomment was NOT labeled (inconclusive, not an anomaly)"
fi
rm -f "$BD_LOG"

echo "── 6. bd show failure (unreadable bead): degrades safely, no crash, no flag ──"
BD_LOG="$(mktemp)"
OUT="$(run_check "$DISPATCHER" vb-unreadable "$BD_LOG" 2>&1)"
case "$OUT" in
  *"RC=0"*) ok "vb-unreadable: function returns cleanly (rc=0) instead of aborting the caller" ;;
  *) bad "vb-unreadable: unexpected exit — $OUT" ;;
esac
if grep -q "identity-unlinked" "$BD_LOG"; then
  bad "vb-unreadable was somehow labeled despite an unreadable bd show — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "vb-unreadable produced no label/comment writes"
fi
rm -f "$BD_LOG"

echo "── 7. MUTATION TEST: disabling the equality check must false-flag a clean case ──"
MUT="$(mktemp "${TMPDIR:-/tmp}/gate-verdict-identity-link-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-verdict-identity-link-mutant-$$.sh")"
trap 'rm -f "$MUT"' EXIT
cp "$DISPATCHER" "$MUT"
MUTATE_OK=0
python3 - "$MUT" <<'PYEOF' && MUTATE_OK=1
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
anchor = '  if [ -n "$_linked_id" ] && [ "$_linked_id" = "$_comment_author" ]; then\n    return 0  # durable link present and matches who actually wrote it.\n  fi'
n = c.count(anchor)
if n != 1:
    print("ANCHOR_NOT_UNIQUE count=%d" % n, file=sys.stderr)
    sys.exit(1)
mutant = '  if false; then  # MUTATED (ga-6wel0o selftest): match-check disabled\n    return 0\n  fi'
c2 = c.replace(anchor, mutant, 1)
if c2 == c:
    print("SWAP_NO_OP", file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.write(c2)
PYEOF
if [ "$MUTATE_OK" != "1" ]; then
  bad "mutation-test: could not construct the mutant (anchor not found exactly once — source shape changed?) — INCONCLUSIVE, treat as FAIL"
else
  bash -n "$MUT" 2>/tmp/mutant-syntax-err.$$ && ok "mutant still parses (bash -n)" || bad "mutant failed to parse: $(cat /tmp/mutant-syntax-err.$$)"
  rm -f /tmp/mutant-syntax-err.$$
  BD_LOG="$(mktemp)"
  MUT_OUT="$(run_check "$MUT" vb-match "$BD_LOG" 2>&1)"
  if grep -q "label add vb-match verdict:identity-unlinked" "$BD_LOG"; then
    ok "mutant flags the previously-clean vb-match case (proves the test exercises the real comparison, not a vacuous pass)"
  else
    bad "mutant did NOT flag vb-match — the test may not actually be exercising the equality check; mutant output: $MUT_OUT bd_log: $(tr '\n' ';' < "$BD_LOG")"
  fi
  rm -f "$BD_LOG"
fi
rm -f "$MUT"
trap - EXIT

echo "── 8. drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'SELFTEST-EXTRACT gate-verdict-identity-link-fn: BEGIN' "$DISPATCHER" \
  && ok "extraction sentinel present (prevents future silent copy-drift)" || bad "extraction sentinel missing"
grep -q 'gate_check_verdict_identity_link()' "$DISPATCHER" \
  && ok "gate_check_verdict_identity_link() helper present" || bad "gate_check_verdict_identity_link() helper missing"
grep -q 'gate_check_verdict_identity_link "\$VB"' "$DISPATCHER" \
  && ok "gate_collect_verdicts() actually calls the identity-link check" || bad "call site into gate_collect_verdicts() is missing — the fix is defined but never invoked"
# Placement guard: the call site must sit INSIDE the closed-bead branch, i.e.
# between the VERDICTS_RECEIVED increment and the verdict:PASS label check —
# so it runs for every counted verdict, not a subset.
INCR_LINE=$(grep -n 'VERDICTS_RECEIVED=\$((VERDICTS_RECEIVED + 1))' "$DISPATCHER" | head -1 | cut -d: -f1)
CALL_LINE=$(grep -n 'gate_check_verdict_identity_link "\$VB"' "$DISPATCHER" | head -1 | cut -d: -f1)
PASSCHK_LINE=$(grep -n 'grep "verdict:PASS" >/dev/null' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$INCR_LINE" ] && [ -n "$CALL_LINE" ] && [ -n "$PASSCHK_LINE" ] \
   && [ "$INCR_LINE" -lt "$CALL_LINE" ] && [ "$CALL_LINE" -lt "$PASSCHK_LINE" ]; then
  ok "call site sits between the VERDICTS_RECEIVED increment and the PASS/FAIL branch"
else
  bad "call site placement drifted (incr=$INCR_LINE call=$CALL_LINE passchk=$PASSCHK_LINE)"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
