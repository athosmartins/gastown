#!/usr/bin/env bash
# gate-guard-ga-tconzw-crew-branch.selftest.sh — Drift-guard for ga-tconzw.
#
# Bug: GAP-1's orphan-strip reconciler (both the RIGSCAN "never-branched"
# sub-case and the GC_CITY "merged-but-OPEN" sweep) and GAP-2's merge-search
# only ever looked for branches matching `fix/<id>*` or `feature/<id>*`. This
# city's own standard crew-submission convention, `crew/<agent>/<id>`
# (crew-commit skill; gate-done's branch-derivation logic has a whole
# separate case for it), was never checked — so a bead whose fix landed as
# e.g. `crew/digo/wa-2lwr6` looked exactly like "no branch ever created" to
# all three reconcilers. Confirmed live impact (2026-08-24, ga-usdm6p): GAP-1
# stripped story:in-flight from an Athos-approved feature, claiming "no
# branch matching fix/wa-2lwr6* or feature/wa-2lwr6*" while the branch
# existed the whole time under the crew/ convention.
#
# This harness (1) proves the underlying git glob mechanism actually resolves
# a `crew/<agent>/<id>` branch via both the ls-remote and for-each-ref/RREF
# fallback paths the guard uses (independent of the guard's own source), and
# (2) drift-guards that all three call sites in the live guard source now
# include the crew pattern in their PAT list, without having dropped the
# original fix/feature patterns.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-guard GAP-1/GAP-2 crew/<agent>/<id> branch-pattern drift-guard (ga-tconzw) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-tconzw-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "── 1. mechanism proof: git glob matching actually resolves crew/<agent>/<id> ──"

ORIGIN_BARE="$WORK/origin.git"
git init --quiet --bare "$ORIGIN_BARE"

SRC="$WORK/src"
git init --quiet "$SRC"
git -C "$SRC" config user.email "selftest@gascity.local"
git -C "$SRC" config user.name  "selftest"
( cd "$SRC" && echo base > base.txt && git add base.txt && git commit --quiet -m base )
git -C "$SRC" remote add origin "$ORIGIN_BARE"
git -C "$SRC" push --quiet origin HEAD:refs/heads/main

FAKE_ID="ga-tconzwfake"
OTHER_ID="ga-otherbead"
git -C "$SRC" branch "crew/digo/$FAKE_ID" HEAD
git -C "$SRC" branch "crew/digo/$FAKE_ID-desc" HEAD
git -C "$SRC" branch "crew/mila/$OTHER_ID" HEAD
git -C "$SRC" push --quiet origin "crew/digo/$FAKE_ID"
git -C "$SRC" push --quiet origin "crew/digo/$FAKE_ID-desc"
git -C "$SRC" push --quiet origin "crew/mila/$OTHER_ID"

# ls-remote path (the guard's primary lookup)
BARE_HIT=$(git -C "$SRC" ls-remote origin "refs/heads/crew/*/$FAKE_ID" 2>/dev/null | awk '{print $2}')
if [ "$BARE_HIT" = "refs/heads/crew/digo/$FAKE_ID" ]; then
  ok "ls-remote 'refs/heads/crew/*/\$ID' resolves exactly the crew/<agent>/<id> branch"
else
  bad "ls-remote 'refs/heads/crew/*/\$ID' did not resolve the expected branch (got: [$BARE_HIT])"
fi

DESC_HIT_COUNT=$(git -C "$SRC" ls-remote origin "refs/heads/crew/*/$FAKE_ID-*" 2>/dev/null | wc -l | tr -d ' ')
if git -C "$SRC" ls-remote origin "refs/heads/crew/*/$FAKE_ID-*" 2>/dev/null | grep -q "refs/heads/crew/digo/$FAKE_ID-desc"; then
  ok "ls-remote 'refs/heads/crew/*/\$ID-*' resolves the description-suffixed crew branch ($DESC_HIT_COUNT ref(s) matched)"
else
  bad "ls-remote 'refs/heads/crew/*/\$ID-*' did not resolve the description-suffixed crew branch"
fi

if git -C "$SRC" ls-remote origin "refs/heads/crew/*/$FAKE_ID" 2>/dev/null | grep -q "mila"; then
  bad "REGRESSION: bare '\$ID' pattern over-matched an unrelated bead's crew branch (crew/mila/$OTHER_ID)"
else
  ok "bare 'refs/heads/crew/*/\$ID' correctly does NOT match a different bead's crew branch"
fi

# for-each-ref / RREF-substitution path (the guard's local-cache fallback,
# used when ls-remote returns empty — same string substitution the live
# code performs: refs/heads/ -> refs/remotes/origin/)
git -C "$SRC" fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*'
RREF_HIT=$(git -C "$SRC" for-each-ref --format='%(refname)' "refs/remotes/origin/crew/*/$FAKE_ID" 2>/dev/null)
if [ "$RREF_HIT" = "refs/remotes/origin/crew/digo/$FAKE_ID" ]; then
  ok "for-each-ref fallback (post RREF substitution) resolves the same crew/<agent>/<id> branch"
else
  bad "for-each-ref fallback did not resolve the expected branch (got: [$RREF_HIT])"
fi

echo "── 2. drift-guard: all three PAT lists in the live guard include the crew pattern ──"

check_site() {
  local label="$1" var="$2"
  if grep -Fq "refs/heads/crew/*/\${${var}}\"" "$GUARD"; then
    ok "$label: PAT list includes refs/heads/crew/*/\${$var}"
  else
    bad "$label: PAT list is MISSING refs/heads/crew/*/\${$var} (ga-tconzw regression)"
  fi
  if grep -Fq "refs/heads/crew/*/\${${var}}-*" "$GUARD"; then
    ok "$label: PAT list includes refs/heads/crew/*/\${$var}-*"
  else
    bad "$label: PAT list is MISSING refs/heads/crew/*/\${$var}-* (ga-tconzw regression)"
  fi
  # Regression guard: the original fix/feature patterns must still be there too.
  if grep -Fq "refs/heads/fix/\${${var}}\"" "$GUARD" && grep -Fq "refs/heads/feature/\${${var}}\"" "$GUARD"; then
    ok "$label: original fix/<id> and feature/<id> patterns are still present (no regression)"
  else
    bad "$label: original fix/<id> or feature/<id> pattern went missing"
  fi
}

check_site "GAP-1 RIGSCAN (never-branched, rig-scoped)" "RIGSCAN_OI_ID"
check_site "GAP-1 GC_CITY (merged-but-OPEN sweep)" "OI_ID"
check_site "GAP-2 merge-search" "GAP2_TRY_ID"

echo "── 3. sanity: quality-gate-guard.sh still parses cleanly ──"
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses cleanly (bash -n)"
else
  bad "quality-gate-guard.sh FAILED bash -n syntax check"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
