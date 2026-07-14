#!/usr/bin/env bash
# gate-guard-gap1-content-merge-check.selftest.sh — Drift-guard for ga-0ndi.
#
# Bug: quality-gate-guard.sh's Step 0c.1 (ga-pa36 GAP-1) orphan-reconciler
# computed BRANCH_MERGED via a bare `merge-base --is-ancestor` to decide
# whether a fix branch's work already landed on origin/main. This is the SAME
# class of bug fixed in ga-01yq for quality-gate-dispatcher.sh's Step 4b:
# after a rebase-merge (the gate's own auto-rebase, or any manual rebase),
# commits land on main under NEW shas, so a fully-merged branch's tip NEVER
# becomes an ancestor again. Here the practical consequence isn't a
# needs-rebase bounce (this is a silent reconciler, not an author-facing
# check) — it's a PERMANENTLY STRANDED story:in-flight label, leaking the
# Pilot lane slot forever for every branch the gate itself merges.
#
# Fix: quality-gate-guard.sh now falls back to a patch-id CONTENT check
# (guard_content_merged(), mirroring the dispatcher's rig_content_merged() /
# merged-bead-janitor.sh's content_in_main()) whenever the naive is-ancestor
# check says "not merged" — `git rev-list --count --cherry-pick --right-only
# <main>...<branch>` == 0 means every branch commit's patch is already present
# in main under some (possibly different) sha, so the branch is
# merged-by-content. A non-zero count means real, unmerged work exists — the
# existing skip:not-merged path is left completely unchanged for that case.
#
# This harness (1) reproduces the bug class with real throwaway git repos,
# proving the naive is-ancestor check really does misclassify a rebase-merged
# branch as unmerged, (2) is itself the MUTATION TEST the bug demands:
# assertion 2 shows naive sha-reachability (is-ancestor / rev-list --count)
# misclassifies case (1) as unmerged — proving the fix matters, (3) unit-tests
# the live guard_content_merged() directly (sourced via GATE_GUARD_LIB_ONLY=1,
# with GC_CITY re-pointed at the scratch repo) against both the
# merged-by-rebase fixture and a genuinely-unmerged fixture — the two
# acceptance directions from ga-01yq, ported to this file's GAP-1 check, and
# (4) drift-guards that the live GAP-1 loop actually wires guard_content_merged
# into its BRANCH_MERGED computation as the fallback taken only when the naive
# is-ancestor check fails.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-guard GAP-1 rebase-merge content-check drift-guard (ga-0ndi) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-0ndi-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

R="$WORK/repo"
git init --quiet "$R"
git -C "$R" config user.email "selftest@gascity.local"
git -C "$R" config user.name  "selftest"

( cd "$R" && echo base > base.txt && git add base.txt && git commit --quiet -m "base commit" )
git -C "$R" branch -M main

# ── Fixture 1: merged-by-rebase — a branch whose content is FULLY in main,
#    but whose tip is NOT an ancestor (a rebase-merge replayed it under a new
#    sha). Exact shape of the wa-jaxt8 catch that motivated ga-01yq. ─────────
git -C "$R" checkout --quiet -b topic-merged main
( cd "$R" && echo "topic feature" > feature.txt && git add feature.txt && git commit --quiet -m "feat: topic feature" )
git -C "$R" checkout --quiet main
( cd "$R" && echo "unrelated main progress" > progress.txt && git add progress.txt && git commit --quiet -m "chore: main moved on" )
git -C "$R" cherry-pick --quiet topic-merged >/dev/null 2>&1

# ── Fixture 2: genuinely unmerged — a branch with UNIQUE content never
#    replayed onto main. Must NEVER be reported merged (no regression). ──────
git -C "$R" checkout --quiet -b topic-unmerged main
( cd "$R" && echo "real unmerged work" > unmerged.txt && git add unmerged.txt && git commit --quiet -m "feat: real unmerged work" )
git -C "$R" checkout --quiet main

# ── 1. Reproduce: naive is-ancestor says topic-merged is NOT merged ─────────
if git -C "$R" merge-base --is-ancestor topic-merged main 2>/dev/null; then
  bad "fixture is broken: topic-merged unexpectedly IS an ancestor of main (cherry-pick landed as a fast-forward?)"
else
  ok "topic-merged tip is NOT an ancestor of main (rebase-merge changed the sha) — bug is reproducible"
fi

# ── 2. MUTATION TEST (mirrors ga-01yq acceptance criterion 3): the naive
#    check IS the "reverted" state. Proves that if the patch-id fallback were
#    removed, a merged-by-rebase branch would be misclassified as unmerged. ──
NAIVE_AHEAD="$(git -C "$R" rev-list --count main..topic-merged 2>/dev/null || echo ERR)"
if git -C "$R" merge-base --is-ancestor topic-merged main 2>/dev/null; then
  bad "MUTATION CHECK: naive is-ancestor unexpectedly says merged — fixture invalid, cannot prove the mutation matters"
elif [ "$NAIVE_AHEAD" != "0" ]; then
  ok "MUTATION CHECK: naive sha-reachability (rev-list --count / is-ancestor) says NOT merged (ahead=$NAIVE_AHEAD) on a fully-content-merged branch — confirms reverting the fix re-breaks case (1) VERMELHO"
else
  bad "MUTATION CHECK: naive rev-list --count reported 0 ahead — fixture invalid"
fi

# ── 3. Unit-test the LIVE guard_content_merged() directly. Source the guard in
#    lib-only mode (no I/O, no main loop), then re-point its hardcoded GC_CITY
#    at our scratch repo — GC_CITY is a plain (non-readonly) global the
#    function reads at CALL time, so reassigning it after sourcing is safe. ──
# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail; this harness counts its own pass/fail
GC_CITY="$R"

if guard_content_merged main topic-merged; then
  ok "guard_content_merged(main, topic-merged) says MERGED (patch-id count=0) — ga-0ndi fix works for the merged-by-rebase case"
else
  bad "guard_content_merged(main, topic-merged) said NOT merged — fix broken"
fi

# ── 4. Negative direction (no regression): genuinely unmerged branch must
#    NEVER be reported merged, so real work still bounces to skip:not-merged
#    exactly as before. ───────────────────────────────────────────────────────
if guard_content_merged main topic-unmerged; then
  bad "guard_content_merged(main, topic-unmerged) WRONGLY said merged — would silently drop real work (DANGEROUS)"
else
  ok "guard_content_merged(main, topic-unmerged) correctly says NOT merged — real work still flagged, no regression"
fi

# ── 5. Drift-guard: the live guard.sh must actually define guard_content_merged
#    and wire it into GAP-1's BRANCH_MERGED computation as the fallback taken
#    only when the naive is-ancestor check fails. ───────────────────────────
if grep -q '^guard_content_merged() {' "$GUARD"; then
  ok "guard.sh defines guard_content_merged()"
else
  bad "guard.sh is MISSING guard_content_merged() (ga-0ndi regression)"
fi

if grep -Fq 'elif guard_content_merged "$G1_MAIN_SHA" "$OI_BRANCH_SHA"; then' "$GUARD"; then
  ok "GAP-1's BRANCH_MERGED computation calls guard_content_merged as a fallback when is-ancestor fails"
else
  bad "GAP-1's BRANCH_MERGED computation does NOT call guard_content_merged — the naive is-ancestor check alone still governs it (ga-0ndi regression)"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
