#!/usr/bin/env bash
# gate-guard-ga-g3g72-feat-branch.selftest.sh — Drift-guard for ga-g3g72.
#
# Bug: GAP-1's orphan-strip reconciler (both the RIGSCAN "never-branched"
# sub-case and the GC_CITY "merged-but-OPEN" sweep) and GAP-2's merge-search
# only ever looked for branches matching `fix/<id>*`, `feature/<id>*`, or
# `crew/<agent>/<id>*` (the last added by ga-tconzw). This city's own live
# push guard (.githooks/pre-push) has allowed `feat/*`, `refactor/*`,
# `docs/*`, `chore/*`, and `test/*` as crew-commit work-branch prefixes all
# along — with `feat/` being the documented CANONICAL prefix for feature
# work (`feature/*` itself is not even in the push-guard allowlist, so it can
# never be pushed) — but none of the five were ever added to these three PAT
# lists. A bead whose fix landed as e.g. `feat/ga-yr8vm-ram-owner-attribution`
# looked exactly like "no branch ever created" to all three reconcilers.
# Confirmed live impact (2026-08-26T00:42Z, ga-yr8vm): GAP-1 stripped
# story:in-flight from a live, pushed, gate-reviewed P0 feature bead,
# claiming "no branch matching fix/ga-yr8vm* or feature/ga-yr8vm*" while the
# branch existed the whole time under the feat/ convention.
#
# This harness (1) proves the underlying git glob mechanism actually resolves
# each of the five new prefixes via both the ls-remote and
# for-each-ref/RREF fallback paths the guard uses (independent of the
# guard's own source), and (2) drift-guards that all three call sites in the
# live guard source now include all five new patterns in their PAT list,
# without having dropped the original fix/feature/crew patterns.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-guard GAP-1/GAP-2 feat/refactor/docs/chore/test branch-pattern drift-guard (ga-g3g72) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gc-ga-g3g72-selftest-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

echo "── 1. mechanism proof: git glob matching actually resolves the 5 new prefixes ──"

ORIGIN_BARE="$WORK/origin.git"
git init --quiet --bare "$ORIGIN_BARE"

SRC="$WORK/src"
git init --quiet "$SRC"
git -C "$SRC" config user.email "selftest@gascity.local"
git -C "$SRC" config user.name  "selftest"
( cd "$SRC" && echo base > base.txt && git add base.txt && git commit --quiet -m base )
git -C "$SRC" remote add origin "$ORIGIN_BARE"
git -C "$SRC" push --quiet origin HEAD:refs/heads/main

FAKE_ID="ga-g3g72fake"
OTHER_ID="ga-otherbead"
NEW_PREFIXES="feat refactor docs chore test"

for PFX in $NEW_PREFIXES; do
  git -C "$SRC" branch "$PFX/$FAKE_ID" HEAD
  git -C "$SRC" branch "$PFX/$FAKE_ID-desc" HEAD
  git -C "$SRC" push --quiet origin "$PFX/$FAKE_ID"
  git -C "$SRC" push --quiet origin "$PFX/$FAKE_ID-desc"
done
git -C "$SRC" branch "feat/$OTHER_ID" HEAD
git -C "$SRC" push --quiet origin "feat/$OTHER_ID"

for PFX in $NEW_PREFIXES; do
  # ls-remote path (the guard's primary lookup)
  BARE_HIT=$(git -C "$SRC" ls-remote origin "refs/heads/$PFX/$FAKE_ID" 2>/dev/null | awk '{print $2}')
  if [ "$BARE_HIT" = "refs/heads/$PFX/$FAKE_ID" ]; then
    ok "ls-remote 'refs/heads/$PFX/\$ID' resolves exactly the $PFX/<id> branch"
  else
    bad "ls-remote 'refs/heads/$PFX/\$ID' did not resolve the expected branch (got: [$BARE_HIT])"
  fi

  if git -C "$SRC" ls-remote origin "refs/heads/$PFX/$FAKE_ID-*" 2>/dev/null | grep -q "refs/heads/$PFX/$FAKE_ID-desc"; then
    ok "ls-remote 'refs/heads/$PFX/\$ID-*' resolves the description-suffixed $PFX branch"
  else
    bad "ls-remote 'refs/heads/$PFX/\$ID-*' did not resolve the description-suffixed $PFX branch"
  fi
done

if git -C "$SRC" ls-remote origin "refs/heads/feat/$FAKE_ID" 2>/dev/null | grep -q "$OTHER_ID"; then
  bad "REGRESSION: bare 'feat/\$ID' pattern over-matched an unrelated bead's branch (feat/$OTHER_ID)"
else
  ok "bare 'refs/heads/feat/\$ID' correctly does NOT match a different bead's feat branch"
fi

# for-each-ref / RREF-substitution path (the guard's local-cache fallback,
# used when ls-remote returns empty — same string substitution the live
# code performs: refs/heads/ -> refs/remotes/origin/)
git -C "$SRC" fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*'
for PFX in $NEW_PREFIXES; do
  RREF_HIT=$(git -C "$SRC" for-each-ref --format='%(refname)' "refs/remotes/origin/$PFX/$FAKE_ID" 2>/dev/null)
  if [ "$RREF_HIT" = "refs/remotes/origin/$PFX/$FAKE_ID" ]; then
    ok "for-each-ref fallback (post RREF substitution) resolves the $PFX/<id> branch"
  else
    bad "for-each-ref fallback did not resolve the $PFX/<id> branch (got: [$RREF_HIT])"
  fi
done

echo "── 2. drift-guard: all three PAT lists in the live guard include all 5 new patterns ──"

check_site() {
  local label="$1" var="$2"
  for PFX in $NEW_PREFIXES; do
    if grep -Fq "refs/heads/$PFX/\${${var}}\"" "$GUARD"; then
      ok "$label: PAT list includes refs/heads/$PFX/\${$var}"
    else
      bad "$label: PAT list is MISSING refs/heads/$PFX/\${$var} (ga-g3g72 regression)"
    fi
    if grep -Fq "refs/heads/$PFX/\${${var}}-*" "$GUARD"; then
      ok "$label: PAT list includes refs/heads/$PFX/\${$var}-*"
    else
      bad "$label: PAT list is MISSING refs/heads/$PFX/\${$var}-* (ga-g3g72 regression)"
    fi
  done
  # Regression guard: the original fix/feature/crew patterns must still be there too.
  if grep -Fq "refs/heads/fix/\${${var}}\"" "$GUARD" \
     && grep -Fq "refs/heads/feature/\${${var}}\"" "$GUARD" \
     && grep -Fq "refs/heads/crew/*/\${${var}}\"" "$GUARD"; then
    ok "$label: original fix/<id>, feature/<id>, and crew/*/<id> patterns are still present (no regression)"
  else
    bad "$label: original fix/<id>, feature/<id>, or crew/*/<id> pattern went missing"
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
