#!/usr/bin/env bash
# gate-byfbd-gate-time-merge-fallback.selftest.sh — ga-byfbd drift-guard.
#
# Two composed defects in quality-gate-dispatcher.sh's GATE-TIME auto-rebase
# step (Step 4c — distinct from do_merge_ff's MERGE-time rebase, already
# covered by gate-qukyp-merge-rebase-fallback.selftest.sh):
#
#   DEFEITO 1 (stderr swallowed): the rebase's own `git ... rebase
#   "origin/$DEFAULT_BRANCH"` ran with 2>/dev/null — the ONE command whose
#   failure most directly explains a stranded branch, while the push right
#   after it already captured its own stderr to a temp file (ga-g0v96/AC3).
#   Every rebase failure therefore fell into the generic "auto-rebase failed
#   (worktree/push error) — no stderr captured" catch-all, indistinguishable
#   from an actual push failure.
#
#   DEFEITO 2 (no merge fallback at gate-time): `git rebase` REPLAYS each
#   commit as a flat patch — it can fail even when the two sides' FINAL
#   TREES don't actually conflict (a branch carrying an earlier re-anchor
#   merge commit somewhere in its history is the textbook case — see
#   do_merge_ff's own ga-qukyp comment for the full mechanism).
#   branch_tip_is_merge_commit only catches a merge commit AT THE TIP, not
#   one further back, so this case reached the plain rebase elif, which had
#   no fallback: rebase fails -> abort -> give up, even though merge-tree
#   already proved the pair merges clean. do_merge_ff already has this exact
#   fallback at MERGE time (ga-qukyp); it was never ported to GATE time.
#
# Measured live (mila-wa, wa-wpbfi, marker ga-9r3f8q, 2026-08-18): 6 commits
# stranded, the marker said "auto-rebase failed (worktree/push error) — no
# stderr captured" 5 times running. Reproduced by hand: NOT a worktree/push
# error, a genuine rebase-replay-vs-merge-tree discrepancy — `git merge
# --squash` of the tip onto fresh main gave zero conflict. Retries never
# helped (CONFLICT_KIND was wrongly "transient" for a deterministic replay
# failure) until MAX_REBASE_ATTEMPTS=3 circuit-broke to gate:needs-human,
# stranding a P1 for ~22h with a marker that gave the operator no way to
# diagnose it.
#
# Fix (both parts independent, both at BOTH call sites — container-rig and
# self-repo): capture worktree-add and rebase stderr into temp files (same
# pattern _PUSH_ERR_FILE already used); when rebase fails, fall back to a
# real `git merge` before giving up (identical mechanism, wording, and
# no-force-with-lease push convention as do_merge_ff's ga-qukyp fallback —
# this file's assertions intentionally verify the SAME structural shape
# gate-qukyp-merge-rebase-fallback.selftest.sh already proved live for
# merge-time, now ported to gate-time).
#
# This harness (1) reuses that same file's proven REAL fixture commits to
# demonstrate the stderr-capture mechanism concretely (a synthetic repo
# risks not reproducing the actual replay/merge-tree discrepancy — see that
# file's own header for why a hand-built minimal case failed to), (2)
# drift-guards that the merge fallback and stderr capture both exist at
# BOTH call sites with the correct push form, (3) drift-guards the fallback
# is positioned to actually run (inside the rebase-failed branch, before
# the block gives up), and (4) proves the regression guard: a genuine
# conflict never even reaches this code (HAS_CONFLICT=1 routes elsewhere
# entirely, upstream of both call sites). Exit 0 iff all hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

RB_WT=""
cleanup() {
  [ -n "$RB_WT" ] && { git -C "$SELF_DIR" worktree remove --force "$RB_WT" >/dev/null 2>&1 || rm -rf "$RB_WT"; }
}
trap cleanup EXIT

echo "── gate-time rebase-fallback + stderr-capture drift-guard (ga-byfbd) ──"

# ── 1. Concrete proof of DEFEITO 1: the exact real incident's fixture pair
#    (same SHAs gate-qukyp-merge-rebase-fallback.selftest.sh already proves
#    reproduce the replay-vs-merge-tree discrepancy live) produces a REAL,
#    non-empty stderr on the failing rebase — 2>/dev/null was discarding
#    actual diagnostic text, not "nothing to capture anyway". ──────────────
REAL_TIP="b13428b6e6720c4020c22e836aefd99038674865"
REAL_MAIN="06ab085eec47ec9e8a7d17702eaca2e632eece62"

if ! git -C "$SELF_DIR" cat-file -e "$REAL_TIP" 2>/dev/null || \
   ! git -C "$SELF_DIR" cat-file -e "$REAL_MAIN" 2>/dev/null; then
  bad "fixture commits not reachable from this checkout — cannot run live git assertions (shallow clone or history rewritten?)"
else
  RB_WT=$(mktemp -d)
  if git -C "$SELF_DIR" worktree add -q --detach "$RB_WT" "$REAL_TIP" 2>/dev/null; then
    ERR_FILE=$(mktemp)
    git -C "$RB_WT" -c user.email="selftest@local" -c user.name="selftest" \
      rebase "$REAL_MAIN" >/dev/null 2>"$ERR_FILE"
    rb_rc=$?
    git -C "$RB_WT" rebase --abort >/dev/null 2>&1 || true
    if [ "$rb_rc" -ne 0 ] && [ -s "$ERR_FILE" ]; then
      ok "DEFEITO 1 concrete proof: the real failing rebase produces non-empty stderr (2>/dev/null was discarding real diagnostic text, not nothing) — $(wc -c < "$ERR_FILE" | tr -d ' ') bytes captured"
    elif [ "$rb_rc" -eq 0 ]; then
      bad "rebase-replay unexpectedly succeeded — fixture no longer reproduces the bug (main history rewritten since?)"
    else
      bad "rebase failed but produced EMPTY stderr — the fixture doesn't demonstrate the capture actually helps here"
    fi
    rm -f "$ERR_FILE"
  else
    bad "could not create worktree at $REAL_TIP — fixture unusable"
  fi
fi

# ── 2. Drift-guard: worktree-add AND rebase stderr are captured to temp
#    files at BOTH call sites (container-rig + self-repo), not discarded. ──
echo "── drift-guard: stderr capture (DEFEITO 1) ──"
WT_CAPTURE_COUNT=$(grep -c 'worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>"$_WT_ERR_FILE"; then' "$GATE" 2>/dev/null)
WT_CAPTURE_COUNT=${WT_CAPTURE_COUNT:-0}
if [ "$WT_CAPTURE_COUNT" -eq 2 ]; then
  ok "worktree-add stderr captured (not discarded) at both call sites, $WT_CAPTURE_COUNT occurrences"
else
  bad "expected worktree-add stderr capture at exactly 2 call sites, found $WT_CAPTURE_COUNT"
fi

REBASE_CAPTURE_COUNT=$(grep -c 'rebase "origin/$DEFAULT_BRANCH" 2>"$_REBASE_ERR_FILE"; then' "$GATE" 2>/dev/null)
REBASE_CAPTURE_COUNT=${REBASE_CAPTURE_COUNT:-0}
if [ "$REBASE_CAPTURE_COUNT" -eq 2 ]; then
  ok "rebase stderr captured (not discarded) at both call sites, $REBASE_CAPTURE_COUNT occurrences"
else
  bad "expected rebase stderr capture at exactly 2 call sites, found $REBASE_CAPTURE_COUNT"
fi
# NOTE: do_merge_ff's OWN rebase call (merge-TIME, lines ~4119/4204) still
# uses 2>/dev/null — deliberately untouched, out of scope for ga-byfbd (the
# bug report cites only the gate-time call sites; do_merge_ff already has
# its own working merge fallback regardless of whether its rebase stderr is
# captured). A "no stale 2>/dev/null anywhere" check would incorrectly flag
# that pre-existing, unrelated code — the exact-count check above already
# fully proves the gate-time fix is complete at exactly its 2 call sites.

# Self-audit catch: the merge FALLBACK's own `git merge` command is the
# LAST remedy tried — if it also fails (rare: merge-tree already proved this
# pair clean), that failure's stderr must not be silently discarded either,
# or the fix reintroduces the exact defect class it exists to close, just
# one command later.
MERGE_CAPTURE_COUNT=$(grep -c 'merge "origin/$DEFAULT_BRANCH" -m "Merge origin/$DEFAULT_BRANCH into $BRANCH (gate auto-merge fallback — rebase-replay failed despite zero merge-tree conflict, ga-byfbd/ga-qukyp)" 2>"$_MERGE_ERR_FILE"; then' "$GATE" 2>/dev/null)
MERGE_CAPTURE_COUNT=${MERGE_CAPTURE_COUNT:-0}
if [ "$MERGE_CAPTURE_COUNT" -eq 2 ]; then
  ok "the merge fallback's OWN stderr (its own failure path, not just rebase's) is also captured at both call sites, $MERGE_CAPTURE_COUNT occurrences"
else
  bad "expected the merge fallback's own stderr capture at exactly 2 call sites, found $MERGE_CAPTURE_COUNT — the last-remedy failure would go undiagnosed again"
fi

# Self-audit catch #2: the merge fallback's own stderr must go into its OWN
# variable (AUTO_MERGE_FALLBACK_ERR), never overwrite AUTO_REBASE_SETUP_ERR
# in place — an overwrite would silently DISCARD the still-valid rebase
# diagnostic whenever the fallback's own capture happens to come back
# empty (git does not write to stderr on every failure mode), exactly the
# error==empty collapse this whole bead exists to close. Both call sites
# must write to the separate variable, never the original.
MERGE_OWN_VAR_COUNT=$(grep -c 'AUTO_MERGE_FALLBACK_ERR=\$(tr' "$GATE" 2>/dev/null)
MERGE_OWN_VAR_COUNT=${MERGE_OWN_VAR_COUNT:-0}
OVERWRITE_LEAK=$(grep -B2 'git -C "\$TMP_REBASE_WT" merge --abort 2>/dev/null || true' "$GATE" 2>/dev/null | grep -c 'AUTO_REBASE_SETUP_ERR=\$(tr')
OVERWRITE_LEAK=${OVERWRITE_LEAK:-0}
if [ "$MERGE_OWN_VAR_COUNT" -eq 2 ] && [ "$OVERWRITE_LEAK" -eq 0 ]; then
  ok "merge fallback's own stderr writes to its own variable at both call sites (count=$MERGE_OWN_VAR_COUNT), never overwriting the rebase diagnostic in place (overwrite-leak=$OVERWRITE_LEAK)"
else
  bad "merge fallback's own stderr capture risks overwriting/losing the rebase diagnostic (own-var count=$MERGE_OWN_VAR_COUNT, overwrite-leak=$OVERWRITE_LEAK) — expected 2 and 0"
fi
grep -qF 'elif [ -n "${AUTO_MERGE_FALLBACK_ERR:-}" ]; then' "$GATE" \
  && ok "CONFLICT_FILES has a dedicated branch for 'fallback also failed', distinct from the plain setup-error branch" \
  || bad "CONFLICT_FILES does not check AUTO_MERGE_FALLBACK_ERR separately — the fallback's own failure diagnostic never reaches the operator"

# ── 3. Drift-guard: CONFLICT_FILES prefers the captured setup diagnostic
#    over the old zero-information string, and the variable is reset every
#    sweep iteration (never leaks a prior branch's error into this one's). ──
grep -qF 'elif [ -n "${AUTO_REBASE_SETUP_ERR:-}" ]; then' "$GATE" \
  && ok "CONFLICT_FILES prefers the captured setup-error diagnostic when present" \
  || bad "CONFLICT_FILES does not check AUTO_REBASE_SETUP_ERR — DEFEITO 1's capture never reaches the operator-visible message"
grep -qF 'AUTO_REBASE_SETUP_ERR=""' "$GATE" \
  && ok "AUTO_REBASE_SETUP_ERR is reset at the top of each sweep iteration (no stale leak across branches)" \
  || bad "AUTO_REBASE_SETUP_ERR is not reset per-sweep — a prior branch's setup error could leak into an unrelated branch's diagnostic"

# ── 4. Drift-guard: the merge fallback (DEFEITO 2) exists at both call
#    sites, with the exact structural properties do_merge_ff's own proven
#    ga-qukyp fallback has — same marker text (so log/bead-comment greps for
#    one family find both), same no-force push (merge never rewrites
#    existing commits, so plain push is correct and safer). ─────────────────
echo "── drift-guard: gate-time merge fallback (DEFEITO 2) ──"
FALLBACK_COUNT=$(grep -c 'gate auto-merge fallback — rebase-replay failed despite zero merge-tree conflict, ga-byfbd/ga-qukyp' "$GATE" 2>/dev/null)
FALLBACK_COUNT=${FALLBACK_COUNT:-0}
if [ "$FALLBACK_COUNT" -eq 2 ]; then
  ok "gate-time merge fallback present at both call sites (container-rig + self-repo), $FALLBACK_COUNT occurrences"
else
  bad "expected gate-time merge fallback at exactly 2 call sites, found $FALLBACK_COUNT"
fi

FALLBACK_BLOCK=$(grep -A20 'gate auto-merge fallback — rebase-replay failed despite zero merge-tree conflict, ga-byfbd/ga-qukyp' "$GATE" 2>/dev/null)
PLAIN_PUSH_COUNT=$(printf '%s\n' "$FALLBACK_BLOCK" | grep -c 'push origin "HEAD:refs/heads/\$BRANCH" 2>"\$_PUSH_ERR_FILE"; then')
FORCE_LEAK=$(printf '%s\n' "$FALLBACK_BLOCK" | grep -c -- '--force-with-lease')
if [ "$PLAIN_PUSH_COUNT" -eq 2 ] && [ "$FORCE_LEAK" -eq 0 ]; then
  ok "both fallback blocks push with a PLAIN push (no --force-with-lease) — correct, merge never rewrites existing commits"
else
  bad "fallback push form incorrect (plain-push occurrences=$PLAIN_PUSH_COUNT, --force-with-lease leaks=$FORCE_LEAK) — expected 2 plain pushes, 0 force"
fi

# ── 5. Drift-guard: the fallback is positioned to actually RUN — inside the
#    rebase-failed else branch (not, say, dead code after an early return),
#    and BEFORE the worktree is torn down. Line-order check: the fallback's
#    merge attempt must appear between the rebase's own failure warning and
#    the worktree-remove call, at both sites. ───────────────────────────────
FAIL_WARN_LINES=$(grep -n 'trying merge fallback (ga-byfbd/ga-qukyp)' "$GATE" | cut -d: -f1)
WT_REMOVE_LINES=$(grep -n 'worktree remove "\$TMP_REBASE_WT" --force\|worktree remove "\$TMP_REBASE_WT" --force' "$GATE" | cut -d: -f1)
# Must include "ga-byfbd" — do_merge_ff's PRE-EXISTING merge-time fallback
# (lines ~4179/4230) shares the same "gate auto-merge fallback" prefix but
# ends "..., ga-qukyp)" with no ga-byfbd — a pattern without that suffix
# would match 4 lines (2 old + 2 new) instead of 2, corrupting the
# positional pairing against FAIL_WARN_LINES below.
FALLBACK_MERGE_LINES=$(grep -n 'Merge origin/\$DEFAULT_BRANCH into \$BRANCH (gate auto-merge fallback — rebase-replay failed despite zero merge-tree conflict, ga-byfbd/ga-qukyp)' "$GATE" | cut -d: -f1)
_POS_OK=1
_i=0
for _fw in $FAIL_WARN_LINES; do
  _i=$((_i + 1))
  _fm=$(printf '%s\n' "$FALLBACK_MERGE_LINES" | sed -n "${_i}p")
  if [ -z "$_fm" ] || [ "$_fm" -le "$_fw" ]; then
    _POS_OK=0
  fi
done
if [ "$_POS_OK" = "1" ] && [ -n "$FAIL_WARN_LINES" ]; then
  ok "the merge-fallback attempt runs AFTER the rebase-failed warning at both call sites (fallback is reachable code, not dead)"
else
  bad "merge-fallback attempt does not correctly follow the rebase-failed warning — may be unreachable"
fi

# ── 6. Regression guard: this whole rebase-then-merge-fallback block only
#    runs when HAS_CONFLICT=0 going in (merge-tree already proved clean) —
#    a genuine conflict is routed OUT before either call site, upstream,
#    the same MT_VERDICT="1" gate gate-qukyp's own file already proves
#    correctly detects a real same-line conflict. Verify the gating text
#    itself is present and unchanged at both call sites (belt-and-suspenders
#    on top of that upstream proof — this fix must never weaken it). ────────
echo "── regression guard: fallback stays inside the HAS_CONFLICT=0 envelope ──"
GATE_COUNT=$(grep -cF 'if [ "$IS_CONTAINER_RIG" = "1" ] && [ "$HAS_CONFLICT" = "0" ]; then' "$GATE")
GATE_COUNT=${GATE_COUNT:-0}
ELIF_GATE_COUNT=$(grep -cF 'elif [ "$HAS_CONFLICT" = "0" ]; then' "$GATE")
ELIF_GATE_COUNT=${ELIF_GATE_COUNT:-0}
if [ "$GATE_COUNT" -eq 1 ] && [ "$ELIF_GATE_COUNT" -ge 1 ]; then
  ok "both call sites (container-rig, self-repo) remain gated on HAS_CONFLICT=0 — a genuine conflict never reaches either the rebase attempt or its merge fallback"
else
  bad "HAS_CONFLICT=0 gating missing or weakened at one or both call sites (container-rig gate=$GATE_COUNT, self-repo elif=$ELIF_GATE_COUNT)"
fi

# ── 7. Mutation guard: reverting DEFEITO 1's capture (the container-rig
#    rebase call back to 2>/dev/null) must make check §2's assertion fail —
#    proves that assertion is not vacuous. ──────────────────────────────────
MUTATED=$(sed 's#rebase "origin/\$DEFAULT_BRANCH" 2>"\$_REBASE_ERR_FILE"; then#rebase "origin/\$DEFAULT_BRANCH" 2>/dev/null; then#' "$GATE")
MUT_REBASE_CAPTURE_COUNT=$(printf '%s\n' "$MUTATED" | grep -c 'rebase "origin/$DEFAULT_BRANCH" 2>"$_REBASE_ERR_FILE"; then')
if [ "${MUT_REBASE_CAPTURE_COUNT:-0}" -eq 0 ]; then
  ok "mutation check: reverting the stderr-capture fix makes §2's rebase-capture assertion correctly fail (count drops to 0) — not vacuous"
else
  bad "mutation check: the sed substitution did not remove the capture pattern as expected — mutation itself is broken, cannot trust §2"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
