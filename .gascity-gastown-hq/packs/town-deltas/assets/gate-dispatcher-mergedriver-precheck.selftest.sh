#!/usr/bin/env bash
# gate-dispatcher-mergedriver-precheck.selftest.sh (ga-kjlhk)
#
# Proves the ga-kjlhk fix: rig_path_is_union_resolvable() generalizes from
# "driver name is literally union" to "path has ANY driver registered via
# `git config --get merge.<name>.driver`" — so rig_merge_has_conflict() no
# longer hard-fails a branch whose only textual conflict is on a path with a
# CUSTOM (non-union) merge driver (e.g. WA's daemons/deploy_deps.json,
# merge=deploydeps).
#
# METHODOLOGY NOTE (read before trusting/extending this test): while building
# this fix, direct empirical testing — both a synthetic repo AND the exact
# historical commit SHAs from the wa-b1v7t-r4 incident this bug cites
# (5ba4861f.../eeb49475... in whatsapp_automation, still-reachable objects)
# — showed that on THIS git version (2.54.0), `git merge-tree --write-tree`
# already invokes a properly REGISTERED driver (union or custom) on its own
# and returns clean (rc=0) BEFORE rig_merge_has_conflict's union-aware
# fallback is ever reached. That fallback (rig_path_is_union_resolvable +
# rig_real_merge_is_clean) is therefore only reachable when merge-tree's
# top-level plumbing check reports a conflict (rc=1) DESPITE a resolvable
# driver being registered — which the shipped code's own comment (ga-78n2z)
# and this bug both assert happens (for union and custom drivers
# respectively), but which could not be reproduced on demand against a
# genuinely-working driver in this session (an UNREGISTERED/broken driver
# DOES reproduce a conflict — confirmed against the real wa-b1v7t-r4 SHAs,
# byte-for-byte matching the historical gate log — but a real merge would
# fail identically in that case, same underlying config, so the fallback
# can't rescue it either; likely explanation for the historical incidents:
# driver-registration fragility and/or a confounding genuine conflict in a
# sibling file, not merge-tree ignoring a working driver). Rather than
# depend on an unreliable natural repro, this test drives the exact
# scenario directly: it stubs ONLY the top-level `git_rig merge-tree
# --write-tree` call to report a conflict on the driver-covered path, while
# check-attr, config, worktree, and the REAL merge inside
# rig_real_merge_is_clean all hit REAL git against a REAL repo with a REAL
# registered driver — so the FALLBACK logic (what this bug actually
# changes) is exercised for real, deterministically, independent of
# whatever merge-tree's own top-level heuristics do on any given git
# version.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-dispatcher-mergedriver-precheck.selftest =="

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

BLOCK="$(extract_block "$DISPATCHER" "gate-mergedriver-precheck")"
if [ -z "$BLOCK" ]; then
  echo "COULD_NOT_EXTRACT_BLOCK" >&2
  exit 99
fi

# ── Build a real throwaway repo: base + one branch per scenario, each editing
#    its own file conflictingly vs a later "mainmove" commit (realistic
#    shape; the merge-tree top-level rc is stubbed per-call below so this
#    natural conflict is defense-in-depth, not what drives the assertions).
TMP_REPO="$(mktemp -d "${TMPDIR:-/tmp}/gate-mergedriver-test.XXXXXX")"
cleanup() { rm -rf "$TMP_REPO"; }
trap cleanup EXIT

(
  cd "$TMP_REPO" || exit 1
  git init -q
  git config user.email t@t; git config user.name t
  git branch -M main
  cat > .gitattributes <<'EOF'
custom.txt merge=testdrv
union.txt merge=union
ghost.txt merge=ghostdrv
EOF
  printf 'a\nb\nc\n' > custom.txt
  printf 'a\nb\nc\n' > union.txt
  printf 'a\nb\nc\n' > ghost.txt
  printf 'a\nb\nc\n' > plain.txt
  git add .gitattributes custom.txt union.txt ghost.txt plain.txt
  git commit -qm base
  # testdrv: a real, always-resolving custom driver (analogous in kind to
  # WA's deploydeps python script, minimal for test purposes — this test
  # only needs "a registered non-union driver that resolves", not a specific
  # merge algorithm). ghostdrv deliberately left UNREGISTERED — the
  # fail-safe case (attribute names a driver, but no command is configured).
  git config merge.testdrv.driver true

  BASE=$(git rev-parse HEAD)
  git checkout -qb featcustom "$BASE"; printf 'a\nb\nc\nFEAT\n' > custom.txt; git commit -qam featcustom
  git checkout -qb featunion  "$BASE"; printf 'a\nb\nc\nFEAT\n' > union.txt;  git commit -qam featunion
  git checkout -qb featghost  "$BASE"; printf 'a\nb\nc\nFEAT\n' > ghost.txt;  git commit -qam featghost
  git checkout -qb featplain  "$BASE"; printf 'a\nb\nc\nFEAT\n' > plain.txt;  git commit -qam featplain

  git checkout -q main
  printf 'a\nb\nc\nMAIN\n' > custom.txt
  printf 'a\nb\nc\nMAIN\n' > union.txt
  printf 'a\nb\nc\nMAIN\n' > ghost.txt
  printf 'a\nb\nc\nMAIN\n' > plain.txt
  git commit -qam mainmove
) >/dev/null 2>&1

# run_conflict_check <branch> <conflicting-path> <repo> — extracts+sources
# the real fix, stubs ONLY the top-level `merge-tree --write-tree` (no
# --name-only) call to force rc=1 (simulating "plumbing reports conflict
# despite a resolvable driver"), and makes rig_conflict_paths' --name-only
# call report exactly <conflicting-path> as the sole conflict — everything
# else (check-attr, config, worktree, and the REAL merge inside
# rig_real_merge_is_clean) hits real git against the real repo.
run_conflict_check() {
  local branch="$1" path="$2" repo="$3"
  bash -c '
    set -euo pipefail
    IS_CONTAINER_RIG=0
    GIT_DIR_PATH="$1"
    CONFLICT_PATH="$2"
    git_rig() {
      if [ "$1" = "merge-tree" ] && [ "$2" = "--write-tree" ]; then
        if [ "$3" = "--name-only" ]; then
          printf "faketree\n%s\n\n" "$CONFLICT_PATH"
        else
          echo "faketree"
          return 1
        fi
        return 0
      fi
      git -C "$GIT_DIR_PATH" "$@"
    }
    '"$BLOCK"'
    # ga-kjlhk selftest gotcha: call via $(...), matching the REAL call site
    # (MT_VERDICT=$(rig_merge_has_conflict ...) in the dispatcher itself).
    # bash disables inherit_errexit by default, so a command substitution
    # shields its internal bare-failing-commands (git_rig merge-tree
    # returning 1 is EXPECTED here) from killing the process under set -e.
    # Calling rig_merge_has_conflict bare at this script'\''s own top level
    # does NOT get that shield and dies silently on the very first simulated
    # conflict, before ever reaching its echo — verified empirically while
    # building this test (all four assertions came back "" until this was
    # fixed to match production'\''s own invocation shape).
    VERDICT=$(rig_merge_has_conflict "main" "$3")
    echo "$VERDICT"
  ' _ "$repo" "$path" "$branch"
}

V_CUSTOM=$(run_conflict_check featcustom custom.txt "$TMP_REPO")
[ "$V_CUSTOM" = "0" ] && ok "custom REGISTERED (non-union) driver: precheck resolves clean via real fallback merge — no longer a false 'genuine conflict'" \
  || bad "custom registered driver should resolve clean via fallback, got '$V_CUSTOM' (ga-kjlhk regression)"

V_GHOST=$(run_conflict_check featghost ghost.txt "$TMP_REPO")
[ "$V_GHOST" = "1" ] && ok "driver NAMED but NOT registered (no merge.ghostdrv.driver in git config): fail-safe still escalates as genuine conflict" \
  || bad "named-but-unregistered driver must stay a genuine conflict (false-negative risk), got '$V_GHOST'"

V_PLAIN=$(run_conflict_check featplain plain.txt "$TMP_REPO")
[ "$V_PLAIN" = "1" ] && ok "path with NO merge attribute: real conflict still escalates (unchanged behavior)" \
  || bad "no-attribute genuine conflict should still be 1, got '$V_PLAIN'"

V_UNION=$(run_conflict_check featunion union.txt "$TMP_REPO")
[ "$V_UNION" = "0" ] && ok "builtin union driver: still resolves clean via fallback (no regression on the already-covered ga-78n2z case)" \
  || bad "union driver should still resolve clean, got '$V_UNION'"

echo "── drift-guards (shipped code still defines what this test extracted) ──"
grep -q 'rig_path_is_union_resolvable()' "$DISPATCHER" && ok "dispatcher still defines rig_path_is_union_resolvable" || bad "missing rig_path_is_union_resolvable"
grep -q 'rig_real_merge_is_clean()' "$DISPATCHER" && ok "dispatcher still defines rig_real_merge_is_clean" || bad "missing rig_real_merge_is_clean"
grep -qE 'merge\.\$drv\.driver|merge\."\$drv"\.driver' "$DISPATCHER" && ok "generalized check consults merge.<drv>.driver in git config" || bad "generalized driver-registration lookup not found in source"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
