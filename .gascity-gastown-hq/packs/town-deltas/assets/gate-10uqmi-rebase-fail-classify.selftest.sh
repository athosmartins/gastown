#!/usr/bin/env bash
# gate-10uqmi-rebase-fail-classify.selftest.sh (ga-10uqmi)
#
# Proves the ga-10uqmi fix in quality-gate-dispatcher.sh's pre-review
# auto-rebase failure classification — the "else" of
# `if [ "$AUTO_REBASE_OK" = "1" ] && [ "$BRANCH_IS_CURRENT" = "1" ]` in
# Step 4c, which decides CONFLICT_KIND after an auto-rebase/auto-merge
# attempt that did not end in a successful push.
#
# THE BUG (measured live 2026-09-17, ga-ks0mq8/ga-bpn9fi, gate stalled
# 1h47m): a rebase/merge attempt that GIT ITSELF considered successful (a
# commit exists) but whose resulting tree does not match a real 3-way merge
# (rebase_content_verdict()="no", ga-m07gc — content silently altered/lost)
# was classified CONFLICT_KIND="transient" unconditionally, with no regard
# for PR_CONTENT_VERDICT at all. That is wrong: re-running the identical
# rebase/merge reproduces the identical wrong tree every time — a
# DETERMINISTIC failure. Worse, the ONLY mechanism that resets the resulting
# retry counter (gate_exile_recovery_sweep, ga-0ye7ar) checks nothing but
# the TEXTUAL rig_merge_has_conflict signal, which is by construction
# already "0" for any branch that reaches a content mismatch at all (the
# absence of a textual conflict is exactly what makes the mismatch
# possible/surprising) — so the two safety valves compounded into a
# resonance loop that never converged and never escalated to a human
# (gate:rebase-fail-count measured oscillating 1/3 -> 2/3 -> 1/3 -> 2/3,
# never reaching 3/3).
#
# THE FIX: PR_CONTENT_VERDICT="no" now routes to CONFLICT_KIND="merge" — the
# SAME classification a genuine textual conflict already gets. The
# downstream disposition logic (unmodified by this bead — see Section C
# drift-guards below) already sends CONFLICT_KIND="merge" straight to
# gate-status:needs-rebase for both a live author (bounce + nudge) and a
# dead/pool author (immediate skip + mail Mayor), and neither of those
# paths ever touches gate:rebase-fail-count/gate:exiled-tier5 — so a
# content-mismatch marker can no longer enter the retry/exile machinery at
# all, closing the resonance loop upstream of gate_exile_recovery_sweep
# rather than inside it.
#
# Deliberately checking `= "no"` and not `!= "yes"` (ga-pgxs78, 2026-09-12):
# rebase_content_verdict() also returns an explicit "unknown" when it could
# not verify — that must fall through to the ordinary transient/plumbing
# path exactly like a plain unset verdict, never be treated as a confirmed
# mismatch. Section A below proves this discrimination directly.
#
# Strategy: extract the classification block via its own SELFTEST-EXTRACT
# sentinel and eval it under `bash -c` with the minimal set of inputs it
# actually reads (mirrors gate-0ye7ar-exile-recovery.selftest.sh Section B,
# the established pattern in this file for an inline, non-function block).
# AUTO_REBASE_OK is always forced to 0 so every case below lands in the
# classification "else" — the sibling success branch (AUTO_REBASE_OK=1)
# needs MARKER_ID/BEAD_CITY/`bd`, which this test never stubs, by design:
# it is unmodified pre-existing code this bead does not touch.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-10uqmi-rebase-fail-classify.selftest (ga-10uqmi) =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

BLOCK=$(sed -n '/# SELFTEST-EXTRACT gate-10uqmi-rebase-fail-classify: BEGIN/,/# SELFTEST-EXTRACT gate-10uqmi-rebase-fail-classify: END/p' "$DISPATCHER")
if [ -z "$BLOCK" ]; then
  echo "FATAL: could not extract gate-10uqmi-rebase-fail-classify block (sentinels missing?)" >&2
  exit 2
fi
ok "located live rebase-fail classification block via sentinel extraction"

# classify <pr_content_verdict> [push_err] [merge_fallback_err] [setup_err] [lost_paths]
# Runs the REAL extracted block with AUTO_REBASE_OK=0/BRANCH_IS_CURRENT=0
# (forces the classification "else"). Prints "KIND|FILES|HAS_CONFLICT" on
# success. set -euo pipefail INSIDE the subshell mirrors the real
# dispatcher's own top-of-file mode (line 30) — an unbound-variable
# reference in the extracted block would abort the subshell instead of
# silently reading empty, exactly like it would in production.
STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/gate-10uqmi-classify-stderr.XXXXXX" 2>/dev/null || echo "/tmp/gate-10uqmi-classify-stderr.$$")"
classify() {
  local pcv="$1" push_err="${2:-}" merge_err="${3:-}" setup_err="${4:-}" lost="${5:-}"
  AUTO_REBASE_OK=0 BRANCH_IS_CURRENT=0 \
  PR_CONTENT_VERDICT="$pcv" AUTO_REBASE_PUSH_ERR="$push_err" AUTO_REBASE_PUSH_RC="1" \
  AUTO_MERGE_FALLBACK_ERR="$merge_err" AUTO_REBASE_SETUP_ERR="$setup_err" _LOST_PATHS="$lost" \
  bash -c "set -euo pipefail; $BLOCK"$'\nprintf "%s|%s|%s" "$CONFLICT_KIND" "$CONFLICT_FILES" "$HAS_CONFLICT"' \
    2>"$STDERR_FILE"
}
# classify_unset — mirrors the ONE realistic way production can reach this
# block with PR_CONTENT_VERDICT/_LOST_PATHS truly never assigned (not even
# ""): the merge-fallback's own `git merge` command fails outright (the
# "Auto-merge fallback git merge command also failed" branch, AUTO_
# MERGE_FALLBACK_ERR set) — that path never computes NEW_TIP, so
# rebase_content_verdict() is never called this sweep. AUTO_REBASE_PUSH_ERR/
# _RC/AUTO_REBASE_SETUP_ERR/AUTO_MERGE_FALLBACK_ERR are NOT omitted here:
# the real dispatcher unconditionally pre-initializes all four to "" at the
# top of the "Clean rebase within envelope" block (confirmed by reading the
# live source, a few hundred lines above this bead's own edit and untouched
# by it) before this classification code ever runs, so omitting them too
# would test a combination that cannot occur in production — env -i doing
# that in an earlier revision of this test produced a false positive here.
# The thing actually worth proving is narrower and sharper: that THIS
# bead's own new ${PR_CONTENT_VERDICT:-}/${_LOST_PATHS:-...} guards are
# real, not decorative — without them, this exact realistic case would
# abort under set -u instead of falling through to the transient path.
classify_unset() {
  local merge_err="${1:-}"
  AUTO_REBASE_OK=0 BRANCH_IS_CURRENT=0 \
  AUTO_REBASE_PUSH_ERR="" AUTO_REBASE_PUSH_RC="" AUTO_REBASE_SETUP_ERR="" AUTO_MERGE_FALLBACK_ERR="$merge_err" \
  bash -c "set -euo pipefail; $BLOCK"$'\nprintf "%s|%s|%s" "$CONFLICT_KIND" "$CONFLICT_FILES" "$HAS_CONFLICT"' \
    2>"$STDERR_FILE"
}

echo "── SECTION A: content-mismatch (ga-m07gc) now classifies as deterministic, not transient ──"

OUT=$(classify "no" "" "" "" "docs/data_dictionary.md config.yaml")
RC=$?
KIND="${OUT%%|*}"
if [ "$RC" = "0" ] && [ "$KIND" = "merge" ]; then
  ok "PR_CONTENT_VERDICT=no -> CONFLICT_KIND=merge (the fix's core claim — was unconditionally 'transient' pre-fix)"
else
  bad "PR_CONTENT_VERDICT=no -> expected CONFLICT_KIND=merge, got rc=$RC out='$OUT' stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
case "$OUT" in
  *"ga-m07gc"*"docs/data_dictionary.md config.yaml"*)
    ok "diagnostic text cites ga-m07gc and the real diverging paths (not a generic 'no stderr captured')" ;;
  *)
    bad "diagnostic text missing ga-m07gc reference or diverging paths — got '$OUT'" ;;
esac
HAS_C="${OUT##*|}"
[ "$HAS_C" = "1" ] && ok "HAS_CONFLICT=1 for the content-mismatch case (still routes through the bounce/needs-rebase path below)" \
                    || bad "expected HAS_CONFLICT=1, got '$HAS_C'"

echo "── SECTION B: 'unknown' (could-not-verify) is NOT treated as a confirmed mismatch (ga-pgxs78) ──"

OUT=$(classify "unknown" "network blip, exit 1" "" "" "")
RC=$?
KIND="${OUT%%|*}"
if [ "$RC" = "0" ] && [ "$KIND" = "transient" ]; then
  ok "PR_CONTENT_VERDICT=unknown falls through to CONFLICT_KIND=transient — an unverifiable verdict is never collapsed into a confirmed 'no' (error != empty != yes)"
else
  bad "PR_CONTENT_VERDICT=unknown -> expected CONFLICT_KIND=transient, got rc=$RC out='$OUT'"
fi
case "$OUT" in
  *"network blip, exit 1"*) ok "transient path still surfaces the real push diagnostic for the 'unknown' case" ;;
  *) bad "transient path lost the push diagnostic for the 'unknown' case — got '$OUT'" ;;
esac

echo "── SECTION C: PR_CONTENT_VERDICT=yes (should not reach here, but defense-in-depth) also stays transient ──"

OUT=$(classify "yes" "some push error" "" "" "")
KIND="${OUT%%|*}"
[ "$KIND" = "transient" ] && ok "PR_CONTENT_VERDICT=yes never misroutes into the deterministic/merge path" \
                          || bad "PR_CONTENT_VERDICT=yes -> expected transient, got '$KIND'"

echo "── SECTION D: regression guard — the pre-existing transient sub-cases are byte-for-byte unchanged ──"

OUT=$(classify "" "push failed: non-fast-forward" "" "")
[ "$OUT" = "transient|auto-rebase push failed (exit=1): push failed: non-fast-forward|1" ] \
  && ok "push-error sub-case unchanged" \
  || bad "push-error sub-case drifted: got '$OUT'"

OUT=$(classify "" "" "merge also exploded" "rebase exploded")
[ "$OUT" = "transient|auto-rebase failed (rebase exploded); merge fallback (ga-byfbd/ga-qukyp) also failed: merge also exploded|1" ] \
  && ok "merge-fallback-also-failed sub-case unchanged" \
  || bad "merge-fallback-also-failed sub-case drifted: got '$OUT'"

OUT=$(classify "" "" "" "worktree add: no space left on device")
[ "$OUT" = "transient|auto-rebase failed: worktree add: no space left on device|1" ] \
  && ok "setup-error sub-case unchanged" \
  || bad "setup-error sub-case drifted: got '$OUT'"

OUT=$(classify "" "" "" "")
[ "$OUT" = "transient|auto-rebase failed (worktree/push error) — no stderr captured|1" ] \
  && ok "bare-nothing-captured sub-case unchanged (still exists for the case this bead does NOT touch — a real, contentless plumbing failure)" \
  || bad "bare-nothing-captured sub-case drifted: got '$OUT'"

echo "── SECTION E: set -u safety — reaching classification with PR_CONTENT_VERDICT/_LOST_PATHS never assigned this sweep must not crash the dispatcher ──"

OUT=$(classify_unset "merge command failed outright")
RC=$?
if [ "$RC" = "0" ] && [ "$OUT" = "transient|auto-rebase failed (no stderr captured); merge fallback (ga-byfbd/ga-qukyp) also failed: merge command failed outright|1" ]; then
  ok "PR_CONTENT_VERDICT/_LOST_PATHS entirely unset (not even empty-string) does not abort under set -u — the \${VAR:-} guards this bead added are real, not decorative"
else
  bad "unset PR_CONTENT_VERDICT crashed or misclassified under set -u (rc=$RC out='$OUT') — a real dispatcher would have died mid-sweep on THIS bead's own new code. stderr: $(cat "$STDERR_FILE" 2>/dev/null)"
fi

echo "── SECTION F: drift-guards — the downstream 'merge' disposition this fix relies on is present and still untouched by this bead ──"

grep -q 'if \[ "\$REBASE_AUTHOR_ALIVE" = "1" \] && \[ "\$CONFLICT_KIND" = "merge" \]; then' "$DISPATCHER" \
  && ok "live-author + CONFLICT_KIND=merge bounce-to-needs-rebase disposition still present" \
  || bad "live-author merge disposition missing/drifted — this fix's routing target is gone"

grep -q 'elif \[ "\$CONFLICT_KIND" = "merge" \]; then' "$DISPATCHER" \
  && ok "dead/pool-author + CONFLICT_KIND=merge immediate-skip disposition (ga-q3ig2 IDEAL SKIP) still present" \
  || bad "dead-author merge disposition missing/drifted — this fix's routing target is gone"

# Both "merge" disposition blocks run from their own `if`/`elif` line to the
# next top-level `elif`/`else` at the SAME nesting depth (4-space indent,
# matching the surrounding if/elif/elif/else chain read directly from the
# file during investigation). Extract each span and confirm neither one
# writes the retry-counter/exile labels — the structural reason a
# content-mismatch marker can no longer enter the resonance loop at all.
LIVE_MERGE_SPAN=$(awk '/if \[ "\$REBASE_AUTHOR_ALIVE" = "1" \] && \[ "\$CONFLICT_KIND" = "merge" \]; then/{flag=1} flag{print} /^    elif \[ "\$REBASE_AUTHOR_ALIVE" = "1" \] && \[ "\$CONFLICT_KIND" = "transient" \]; then/{if(flag && NR>1) exit}' "$DISPATCHER")
if printf '%s' "$LIVE_MERGE_SPAN" | grep 'gate:rebase-fail-count\|gate:exiled-tier5' >/dev/null; then
  bad "live-author merge disposition now touches rebase-fail-count/exiled-tier5 labels — invariant (c)/(b) at risk, this fix's premise (content-mismatch never enters the counter) no longer holds"
else
  ok "live-author merge disposition still never writes gate:rebase-fail-count/gate:exiled-tier5 — content-mismatch structurally cannot enter the exile-recovery resonance loop"
fi

DEAD_MERGE_SPAN=$(awk '/^    elif \[ "\$CONFLICT_KIND" = "merge" \]; then/{flag=1} flag{print} /^    else$/{if(flag && NR>1) exit}' "$DISPATCHER")
if printf '%s' "$DEAD_MERGE_SPAN" | grep 'gate:rebase-fail-count\|gate:exiled-tier5' >/dev/null; then
  bad "dead-author merge disposition now touches rebase-fail-count/exiled-tier5 labels — invariant (c)/(b) at risk"
else
  ok "dead-author merge disposition still never writes gate:rebase-fail-count/gate:exiled-tier5"
fi

grep -q 'gate_exile_recovery_sweep()' "$DISPATCHER" \
  && ok "gate_exile_recovery_sweep still defined (this bead documents it, does not remove/rename it)" \
  || bad "gate_exile_recovery_sweep missing — unrelated regression"

echo ""
echo "== gate-10uqmi-rebase-fail-classify.selftest: PASS=$PASS FAIL=$FAIL =="
rm -f "$STDERR_FILE" 2>/dev/null || true
[ "$FAIL" -eq 0 ]
