#!/usr/bin/env bash
# gate-guard-ab-base-test-check.selftest.sh — Prove the ga-rstae A/B fix:
# arm B (per gate_ab_arm_for_bead, a pure hash of the bead id) is refused at
# SUBMISSION time when every new/changed *.selftest.sh on the branch passes
# UNMODIFIED against the pre-fix base commit — i.e. the test doesn't actually
# depend on this branch's own diff and proves nothing. Arm A never sees this
# check at all (control, byte-for-byte today's behavior — "A com um aviso"
# is not A, per the bead's own words).
#
# MEASURED MOTIVATION (docs/gate-analysis/2026-08-12-gate-failure-taxonomy.md):
# "teste nao pega o bug" is family #5, 22% of 443 classified blocking issues
# across 1524 gate-runs (2026-07-23..2026-08-12). Doctrine prose already asks
# builders not to do this (test-driven-development's own Iron Law, gate-
# done.md's pre-flight self-audit) and still produces this rate — the next
# degree has to be mechanical verification, not more prose (the taxonomy
# doc's own closing argument).
#
# Three layers, matching this codebase's own established convention (see
# gate-guard-submission-time-coherence.selftest.sh, the sibling this file
# copies its shape from):
#   1. Pure-function unit tests (GATE_GUARD_LIB_ONLY=1 sourcing) — both new
#      functions: gate_ab_arm_for_bead, gate_base_test_verdict. ga-yl1k3w adds
#      the repair-aware cases of the verdict (a selftest that is red on base in
#      its OLD form and green in its NEW form is non-blocking) and, in layer 2,
#      direct tests of gate_base_test_old_state — the one new IO function,
#      which layer 2's mirror loop calls for real instead of copying.
#   2. Real-git plumbing composition against a temp repo WITH an origin
#      remote — proves the exact fetch/rev-parse/merge-base/diff/worktree-
#      add/git-show/run sequence the live check runs, not just the isolated
#      pure functions. This doubles as the bead's own mandatory self-
#      measurement requirement: it reproduces a submission whose test passes
#      on base (must be refused) and one whose test fails on base (must
#      proceed) — the exact family-#5-applied-to-itself proof the bead body
#      demands.
#   3. Drift guards on the live script — placement, wiring, ordering, and
#      that arm A genuinely never reaches the worktree machinery.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
bash -n "$GUARD" && ok "guard passes bash -n syntax check" || bad "guard has syntax errors"

# ── 1. Pure functions: gate_ab_arm_for_bead + gate_base_test_verdict ────────
echo "── 1. pure function unit tests ──"

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail, which leaks into this
        # shell (sourced, not subprocessed) and would silently kill the rest
        # of this harness on the first non-zero command — same fix
        # gate-guard-submission-time-coherence.selftest.sh uses for the
        # identical reason.

if ! type gate_ab_arm_for_bead >/dev/null 2>&1; then
  bad "FATAL: gate_ab_arm_for_bead not defined after LIB_ONLY sourcing — cannot continue section 1"
elif ! type gate_base_test_verdict >/dev/null 2>&1; then
  bad "FATAL: gate_base_test_verdict not defined after LIB_ONLY sourcing — cannot continue section 1"
else
  echo "  -- gate_ab_arm_for_bead --"

  eq "same bead id called twice -> identical arm (stability, not a fresh coin flip each call)" \
    "$(gate_ab_arm_for_bead ga-rstae)" "$(gate_ab_arm_for_bead ga-rstae)"

  eq "empty bead id -> A (fail-open: unresolved input never lands in the arm that can block)" \
    "$(gate_ab_arm_for_bead "")" "A"

  _ARM_OUT=$(gate_ab_arm_for_bead ga-rstae)
  case "$_ARM_OUT" in
    A|B) ok "output is exactly 'A' or 'B', never anything else (got '$_ARM_OUT')" ;;
    *)   bad "output is not A/B: got '$_ARM_OUT'" ;;
  esac

  # Regression pins — hardcoded expected outputs for specific ids, computed
  # once and fixed here. If these ever change, the hash algorithm changed
  # underneath already-submitted beads — exactly the arm-hopping contamination
  # the bead's design forbids (a bead that fails once and resubmits under the
  # SAME id must land in the SAME arm, forever).
  eq "regression pin: ga-rstae -> A" "$(gate_ab_arm_for_bead ga-rstae)" "A"
  eq "regression pin: ga-pj5va -> B" "$(gate_ab_arm_for_bead ga-pj5va)" "B"
  eq "regression pin: ga-sdkqs -> B" "$(gate_ab_arm_for_bead ga-sdkqs)" "B"
  eq "regression pin: ga-kgja -> A"  "$(gate_ab_arm_for_bead ga-kgja)"  "A"

  # Balance sanity over a FIXED (not random — this file must itself be
  # deterministic), realistic-looking sample of 20 ids: both arms must
  # appear. A hash bug that always returns the same arm regardless of input
  # would sail through the stability/pin checks above (a constant function
  # IS "stable") but fails this one.
  SAMPLE_IDS="ga-rstae ga-pj5va ga-sdkqs wa-uthi ga-5crlw ga-qubtx ga-kgja ga-oiu7 ga-art5 ga-31ac ga-y9a1d ga-zdkn1 ga-o64z1 ga-e7zk7 ga-f1ngu ga-jto05 ga-pa36 ga-3h8l ga-u07fn ga-qtc16"
  SAMPLE_A=0; SAMPLE_B=0
  for _id in $SAMPLE_IDS; do
    case "$(gate_ab_arm_for_bead "$_id")" in
      A) SAMPLE_A=$((SAMPLE_A+1)) ;;
      B) SAMPLE_B=$((SAMPLE_B+1)) ;;
    esac
  done
  if [ "$SAMPLE_A" -gt 0 ] && [ "$SAMPLE_B" -gt 0 ]; then
    ok "20-id fixed sample lands in BOTH arms (A=$SAMPLE_A B=$SAMPLE_B) — not a degenerate constant function"
  else
    bad "REGRESSION: 20-id fixed sample is all one arm (A=$SAMPLE_A B=$SAMPLE_B) — hash is degenerate"
  fi

  echo "  -- gate_base_test_verdict --"

  eq "no test files (0,0,0,0) -> sem-teste-novo" \
    "$(gate_base_test_verdict 0 0 0 0)" "sem-teste-novo"

  eq "unparseable detected count (empty) -> nao-consegui-medir, NOT sem-teste-novo (the erro==vazio collapse this whole bead exists to catch — see the function's own header comment)" \
    "$(gate_base_test_verdict "" 0 0 0)" "nao-consegui-medir"

  eq "unparseable detected count (non-numeric) -> nao-consegui-medir" \
    "$(gate_base_test_verdict "abc" 0 0 0)" "nao-consegui-medir"

  eq "1 file, fully measured, passes on base -> passou-na-base (the block case)" \
    "$(gate_base_test_verdict 1 1 1 0)" "passou-na-base"

  eq "1 file, fully measured, fails on base -> reprovou-na-base (the good case)" \
    "$(gate_base_test_verdict 1 1 1 1)" "reprovou-na-base"

  eq "3 files, all pass on base -> passou-na-base" \
    "$(gate_base_test_verdict 3 3 3 0)" "passou-na-base"

  eq "3 files, only ONE fails on base -> reprovou-na-base (one genuine failure is enough to prove something — matches 'ao menos um reprovar' in the bead)" \
    "$(gate_base_test_verdict 3 3 3 1)" "reprovou-na-base"

  eq "2 detected but only 1 copied -> nao-consegui-medir (partial measurement is never treated as proof)" \
    "$(gate_base_test_verdict 2 1 1 0)" "nao-consegui-medir"

  eq "1 detected, copied, but 0 ran (e.g. timeout-killed) -> nao-consegui-medir" \
    "$(gate_base_test_verdict 1 1 0 0)" "nao-consegui-medir"

  eq "2 files, both measured, both fail -> reprovou-na-base" \
    "$(gate_base_test_verdict 2 2 2 2)" "reprovou-na-base"

  # ── ga-yl1k3w: repair-aware verdict (args 5/6 = repaired / unclassified) ──
  # A selftest that is WRONGLY RED on base and is fixed by the branch passes on
  # base in its new form by definition. Before this bead that always landed in
  # passou-na-base = refused, so a test-repair bead was unsatisfiable in arm B.
  echo "  -- gate_base_test_verdict: repair-aware (ga-yl1k3w) --"

  eq "1 modified file, new form passes on base, OLD form failed on base (repaired=1) -> consertou-teste-vermelho (non-blocking)" \
    "$(gate_base_test_verdict 1 1 1 0 1 0)" "consertou-teste-vermelho"

  eq "1 file passes on base and repaired=0 stated explicitly -> still passou-na-base (a test that passes on base in BOTH forms stays refused)" \
    "$(gate_base_test_verdict 1 1 1 0 0 0)" "passou-na-base"

  eq "legacy 4-arg call (no repaired/unclassified) -> passou-na-base, byte-for-byte the pre-ga-yl1k3w answer" \
    "$(gate_base_test_verdict 1 1 1 0)" "passou-na-base"

  eq "2 files, one repair + one that passes in both forms -> consertou-teste-vermelho (at least one discriminating file is enough, same rule as reprovou-na-base)" \
    "$(gate_base_test_verdict 2 2 2 0 1 0)" "consertou-teste-vermelho"

  eq "precedence: a file that FAILS on base beats a repair -> reprovou-na-base (existing meaning untouched)" \
    "$(gate_base_test_verdict 2 2 2 1 1 0)" "reprovou-na-base"

  eq "passing file whose old form could not be classified (unclassified=1) -> nao-consegui-medir, NEVER passou-na-base (uncertainty must not refuse a builder)" \
    "$(gate_base_test_verdict 1 1 1 0 0 1)" "nao-consegui-medir"

  eq "repair + an unclassifiable sibling -> consertou-teste-vermelho (positive evidence present, both non-blocking)" \
    "$(gate_base_test_verdict 2 2 2 0 1 1)" "consertou-teste-vermelho"

  eq "repaired count present-but-EMPTY -> nao-consegui-medir, not collapsed to 0 (which would refuse: the erro==vazio family)" \
    "$(gate_base_test_verdict 1 1 1 0 "" 0)" "nao-consegui-medir"

  eq "repaired count non-numeric -> nao-consegui-medir, not collapsed to 0" \
    "$(gate_base_test_verdict 1 1 1 0 abc 0)" "nao-consegui-medir"

  eq "unclassified count present-but-EMPTY -> nao-consegui-medir" \
    "$(gate_base_test_verdict 1 1 1 0 0 "")" "nao-consegui-medir"

  eq "repaired > detected (impossible counts) -> nao-consegui-medir, inconsistent input is not evidence" \
    "$(gate_base_test_verdict 1 1 1 0 2 0)" "nao-consegui-medir"

  eq "partial measurement wins over a repair claim (2 detected, 1 copied) -> nao-consegui-medir" \
    "$(gate_base_test_verdict 2 1 1 0 1 0)" "nao-consegui-medir"

  eq "no test files + a stray repaired count -> sem-teste-novo (detected=0 still short-circuits)" \
    "$(gate_base_test_verdict 0 0 0 0 1 0)" "sem-teste-novo"

  eq "unparseable detected + a repaired count -> nao-consegui-medir (still not sem-teste-novo)" \
    "$(gate_base_test_verdict "" 0 0 0 1 0)" "nao-consegui-medir"
fi

if ! type gate_base_test_old_state >/dev/null 2>&1; then
  bad "FATAL: gate_base_test_old_state not defined after LIB_ONLY sourcing (ga-yl1k3w) — cannot classify a modified selftest's OLD form"
fi

# ── 2. Real-git integration: the exact fetch/rev-parse/merge-base/diff/ ─────
#       worktree-add/git-show/run sequence Step 5b-pre2 runs ────────────────
echo "── 2. real-git integration: fetch/merge-base/diff/worktree-add/git-show/run against a real origin remote ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

ORIGIN_DIR="$TMPD/origin.git"
CLONE_DIR="$TMPD/rig-clone"

git init -q --bare "$ORIGIN_DIR"
# A bare repo's HEAD defaults to refs/heads/master (or whatever
# init.defaultBranch says) regardless of what gets pushed later — without
# this, HEAD can point at a ref that never comes to exist (only "main" ever
# gets pushed below) and `git clone` silently leaves the working tree empty.
# Same fix gate-guard-submission-time-coherence.selftest.sh uses.
git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main

git init -q -b main "$TMPD/seed"
git -C "$TMPD/seed" config user.email "test@gascity.local"
git -C "$TMPD/seed" config user.name "Test"
mkdir -p "$TMPD/seed/lib"
cat > "$TMPD/seed/lib/add.sh" <<'SEEDEOF'
add() { echo $(( $1 + $2 )); }
SEEDEOF
# ga-yl1k3w: three selftests that ALREADY EXIST on base, so a branch that touches
# them is a MODIFICATION (diff-filter=M), not an addition. red = wrongly red on
# base (asserts 2+2==5), green = correctly green, slow = an old form that will
# not finish inside the timeout budget.
cat > "$TMPD/seed/lib/red.selftest.sh" <<'REDEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
[ "$(add 2 2)" = "5" ] && exit 0 || exit 1
REDEOF
cat > "$TMPD/seed/lib/green.selftest.sh" <<'GREENEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
[ "$(add 2 2)" = "4" ] && exit 0 || exit 1
GREENEOF
cat > "$TMPD/seed/lib/slow.selftest.sh" <<'SLOWEOF'
#!/usr/bin/env bash
sleep 5
exit 0
SLOWEOF
git -C "$TMPD/seed" add -A
git -C "$TMPD/seed" commit -q -m base
git -C "$TMPD/seed" remote add origin "$ORIGIN_DIR"
git -C "$TMPD/seed" push -q origin main

git clone -q "$ORIGIN_DIR" "$CLONE_DIR"
git -C "$CLONE_DIR" config user.email "test@gascity.local"
git -C "$CLONE_DIR" config user.name "Test"

# Branch A: a selftest that would pass EVEN ON THE UNFIXED BASE — it never
# exercises anything the base lacks, so it proves nothing about this branch.
git -C "$CLONE_DIR" checkout -q -b feat/badtest
mkdir -p "$CLONE_DIR/lib"
cat > "$CLONE_DIR/lib/add.selftest.sh" <<'BADEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
result=$(add 2 2)
[ "$result" = "4" ] && exit 0 || exit 1
BADEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: add trivial selftest that passes regardless of the fix"
git -C "$CLONE_DIR" push -q origin feat/badtest

# Branch B: a selftest that genuinely FAILS on base — it depends on
# add_safe, which base does not have yet.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/goodtest
cat > "$CLONE_DIR/lib/add.selftest.sh" <<'GOODEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
result=$(add_safe 2 2 2>/dev/null || echo "MISSING")
[ "$result" = "4" ] && exit 0 || exit 1
GOODEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: add selftest for add_safe (not implemented on base)"
git -C "$CLONE_DIR" push -q origin feat/goodtest

# Branch C: no test file touched at all — just a docs change.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/notest
echo "notes" > "$CLONE_DIR/NOTES.md"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "docs: notes, no test files touched"
git -C "$CLONE_DIR" push -q origin feat/notest

# Branch D: 16 new selftest files — exceeds the safety cap (>15), must be
# nao-consegui-medir regardless of their (trivially-passing) content.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/toomanytests
mkdir -p "$CLONE_DIR/manyfiles"
for _n in $(seq 1 16); do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE_DIR/manyfiles/f${_n}.selftest.sh"
done
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: 16 new selftest files, exceeds the measurement cap"
git -C "$CLONE_DIR" push -q origin feat/toomanytests

# ── ga-yl1k3w: branches that MODIFY selftests already on base ────────────────
# Branch E: REPAIRS the wrongly-red selftest (old form red on base, new form
# green on base). Must be non-blocking: consertou-teste-vermelho.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/repair
cat > "$CLONE_DIR/lib/red.selftest.sh" <<'REPAIREOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
[ "$(add 2 2)" = "4" ] && exit 0 || exit 1
REPAIREOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: repair the wrongly-red selftest"
git -C "$CLONE_DIR" push -q origin feat/repair

# Branch F: touches a selftest that was ALREADY green on base and keeps it green
# (passes on base in BOTH forms). Still proves nothing -> passou-na-base.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/noopmod
echo "# cosmetic edit, behavior identical" >> "$CLONE_DIR/lib/green.selftest.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "chore: touch an already-green selftest"
git -C "$CLONE_DIR" push -q origin feat/noopmod

# Branch G: one repair + one brand-new always-green selftest. At least one file
# discriminates -> consertou-teste-vermelho (same at-least-one rule as
# reprovou-na-base).
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/repair-plus-added
git -C "$CLONE_DIR" show feat/repair:lib/red.selftest.sh > "$CLONE_DIR/lib/red.selftest.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE_DIR/lib/extra.selftest.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: repair red selftest and add an unrelated always-green one"
git -C "$CLONE_DIR" push -q origin feat/repair-plus-added

# Branch H: modifies a selftest whose OLD form cannot finish inside the timeout
# budget (run below with a 1s old-form budget). Whether it would have failed is
# unknowable -> nao-consegui-medir, never a refusal.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/oldtimeout
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE_DIR/lib/slow.selftest.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: rewrite the slow selftest so it finishes"
git -C "$CLONE_DIR" push -q origin feat/oldtimeout

# A second, independent local clone stands in for RIG_PATH — the guard never
# runs inside the submitter's own worktree, it operates on the registered
# rig's own local checkout. Proves the check doesn't depend on any local
# state left over from creating the branches above.
RIG_PATH="$TMPD/rig-registered-copy"
git clone -q "$ORIGIN_DIR" "$RIG_PATH"
git -C "$RIG_PATH" config user.email "test@gascity.local"
git -C "$RIG_PATH" config user.name "Test"

run_live_basetest_check() {
  # Mirrors the EXACT git-plumbing sequence in quality-gate-guard.sh's Step
  # 5b-pre2 block, through computing the verdict. The bd/label/comment/
  # refuse side effects need a live city DB and are intentionally NOT
  # exercised here — same scope the sibling selftest's run_live_check()
  # uses for the ga-pj5va check.
  local branch="$1"
  local verdict="nao-consegui-medir"
  local detected=0 copy_ok=0 ran=0 failed=0 repaired=0 unclassified=0
  local base="" test_files=""
  local outside="unknown"   # ga-x4mkk2: "never measured" is NOT 0

  git -C "$RIG_PATH" fetch origin main "$branch" --quiet 2>/dev/null || true
  local main_sha branch_sha
  main_sha=$(git -C "$RIG_PATH" rev-parse "origin/main" 2>/dev/null || echo "")
  branch_sha=$(git -C "$RIG_PATH" rev-parse "origin/$branch" 2>/dev/null || echo "")
  if [ -n "$main_sha" ] && [ -n "$branch_sha" ]; then
    base=$(git -C "$RIG_PATH" merge-base "$branch_sha" "$main_sha" 2>/dev/null || echo "")
  fi

  if [ -n "$base" ]; then
    # ga-x4mkk2: the REAL guard function, not a copy. Count only — `outside` is never
    # an input to the verdict below. It reaches the caller through a FILE because this
    # function runs inside $(...), where a variable assignment would die with the subshell.
    outside=$(gate_base_test_outside_subtree "$RIG_PATH" "$base" "$branch_sha")
    test_files=$(git -C "$RIG_PATH" diff --name-only --diff-filter=AM "${base}..${branch_sha}" -- '*.selftest.sh' 2>/dev/null || echo "")
    [ -n "$test_files" ] && detected=$(printf '%s\n' "$test_files" | grep -c .)

    if [ "$detected" -eq 0 ]; then
      verdict="sem-teste-novo"
    elif [ "$detected" -gt 15 ]; then
      verdict="nao-consegui-medir"
    else
      local wt
      wt=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-wt.XXXXXX" 2>/dev/null || echo "")
      if [ -n "$wt" ] && git -C "$RIG_PATH" worktree add --detach --quiet "$wt" "$base" 2>/dev/null; then
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          mkdir -p "$(dirname "$wt/$f")" 2>/dev/null
          if git -C "$RIG_PATH" show "${branch_sha}:$f" > "$wt/$f" 2>/dev/null; then
            copy_ok=$((copy_ok + 1))
            if timeout 30 bash "$wt/$f" >/dev/null 2>&1; then
              ran=$((ran + 1))
              # ga-yl1k3w: the new form passed on base; ask the REAL guard function
              # (not a copy of it) what base's own copy of this file does on base.
              case "$(gate_base_test_old_state "$RIG_PATH" "$base" "$wt" "$f")" in
                old-fails)         repaired=$((repaired + 1)) ;;
                added|old-passes)  : ;;
                *)                 unclassified=$((unclassified + 1)) ;;
              esac
            else
              rc=$?
              if [ "$rc" != "124" ]; then
                ran=$((ran + 1))
                failed=$((failed + 1))
              fi
            fi
          fi
        done <<TESTFILESEOF
$test_files
TESTFILESEOF
        git -C "$RIG_PATH" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt" 2>/dev/null
      else
        [ -n "$wt" ] && rm -rf "$wt" 2>/dev/null
      fi
      verdict=$(gate_base_test_verdict "$detected" "$copy_ok" "$ran" "$failed" "$repaired" "$unclassified")
    fi
  fi
  if [ -n "${ABT_OUTSIDE_FILE:-}" ]; then printf '%s' "$outside" > "$ABT_OUTSIDE_FILE"; fi
  printf '%s' "$verdict"
}

# ga-x4mkk2: run the mirror and report BOTH what the guard decides and what it counts, from
# the SAME run — "the verdict is unchanged" is only a claim if it is read next to the count.
run_live_check_full() {
  local of v
  of=$(mktemp "${TMPDIR:-/tmp}/gate-xk-outside.XXXXXX")
  v=$(ABT_OUTSIDE_FILE="$of" run_live_basetest_check "$1")
  printf '%s outside-subtree=%s' "$v" "$(cat "$of")"
  rm -f "$of"
}

eq "real-git+origin: badtest (passes unmodified on base) -> passou-na-base (WOULD be refused today)" \
  "$(run_live_basetest_check feat/badtest)" "passou-na-base"

eq "real-git+origin: goodtest (fails on base, depends on the fix) -> reprovou-na-base (proceeds)" \
  "$(run_live_basetest_check feat/goodtest)" "reprovou-na-base"

eq "real-git+origin: notest (no selftest touched) -> sem-teste-novo (proceeds)" \
  "$(run_live_basetest_check feat/notest)" "sem-teste-novo"

eq "real-git+origin: toomanytests (16 files, exceeds cap) -> nao-consegui-medir (proceeds, capped not silently truncated)" \
  "$(run_live_basetest_check feat/toomanytests)" "nao-consegui-medir"

eq "real-git+origin: nonexistent branch (fetch/rev-parse fails) -> nao-consegui-medir, fails open, never crashes" \
  "$(run_live_basetest_check feat/does-not-exist)" "nao-consegui-medir"

# ga-x4mkk2: when the rig IS the repo toplevel there is no "outside" — the count is a MEASURED 0
# (real selftests changed, all of them inside), never a blank; and when no base could be
# resolved it is `unknown`, which must not read as that same 0.
eq "toplevel rig: badtest (a selftest changed, all inside) -> verdict unchanged, outside-subtree=0" \
  "$(run_live_check_full feat/badtest)" "passou-na-base outside-subtree=0"
eq "toplevel rig: notest -> verdict unchanged, outside-subtree=0 (measured zero)" \
  "$(run_live_check_full feat/notest)" "sem-teste-novo outside-subtree=0"
eq "toplevel rig: nonexistent branch (no base) -> nao-consegui-medir, outside-subtree=unknown, NOT 0" \
  "$(run_live_check_full feat/does-not-exist)" "nao-consegui-medir outside-subtree=unknown"

# ── ga-yl1k3w: a selftest REPAIR is satisfiable, a no-op edit is still refused ──
eq "real-git+origin: repair (old form RED on base, new form green) -> consertou-teste-vermelho (non-blocking; before ga-yl1k3w this was passou-na-base = refused)" \
  "$(run_live_basetest_check feat/repair)" "consertou-teste-vermelho"

eq "real-git+origin: noopmod (already-green selftest edited, green in BOTH forms) -> passou-na-base (still refused in arm B — the check's intent survives)" \
  "$(run_live_basetest_check feat/noopmod)" "passou-na-base"

eq "real-git+origin: repair + a brand-new always-green selftest -> consertou-teste-vermelho (at least one discriminating file)" \
  "$(run_live_basetest_check feat/repair-plus-added)" "consertou-teste-vermelho"

eq "real-git+origin: modified selftest whose OLD form times out (1s old-form budget) -> nao-consegui-medir, never a refusal" \
  "$(GATE_ABT_OLD_TIMEOUT=1 run_live_basetest_check feat/oldtimeout)" "nao-consegui-medir"

# Direct three-state tests of the new function (the only new IO in the check).
_OS_BASE=$(git -C "$RIG_PATH" rev-parse origin/main)
_OS_WT=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-oldstate.XXXXXX")
git -C "$RIG_PATH" worktree add --detach --quiet "$_OS_WT" "$_OS_BASE" 2>/dev/null
eq "old_state: file that does not exist on base (an ADDED selftest) -> added" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/brand-new.selftest.sh)" "added"
eq "old_state: base copy red on base -> old-fails" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/red.selftest.sh)" "old-fails"
eq "old_state: base copy green on base -> old-passes" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/green.selftest.sh)" "old-passes"
eq "old_state: base copy that outlives the budget -> unknown (timeout is ambiguous, not a failure)" \
  "$(GATE_ABT_OLD_TIMEOUT=1 gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/slow.selftest.sh)" "unknown"
eq "old_state: unresolvable base sha (ls-tree ERRORS) -> unknown, NOT added (error must not read as 'file absent')" \
  "$(gate_base_test_old_state "$RIG_PATH" "0000000000000000000000000000000000000000" "$_OS_WT" lib/red.selftest.sh)" "unknown"
eq "old_state: empty base -> unknown" \
  "$(gate_base_test_old_state "$RIG_PATH" "" "$_OS_WT" lib/red.selftest.sh)" "unknown"
eq "old_state: empty file arg -> unknown" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" "")" "unknown"
eq "old_state: always exits 0 (safe under the guard's set -e even on 'unknown')" \
  "$(gate_base_test_old_state "$RIG_PATH" "" "$_OS_WT" x >/dev/null; echo $?)" "0"
git -C "$RIG_PATH" worktree remove --force "$_OS_WT" 2>/dev/null || rm -rf "$_OS_WT" 2>/dev/null

# ── ga-yl1k3w gate feedback 1/3 (gate ga-ql6pdl): the PRODUCTION topology ────
# Every fixture above clones origin as a TOP-LEVEL repo, so RIG_PATH == the repo
# toplevel and a path relative to the -C dir equals a path relative to the root.
# The gascity rig is not shaped like that: its RIG_PATH is a SUBDIRECTORY of the
# repo (/Users/athos/gt/.gascity-gastown-hq inside /Users/athos/gt), while the
# selftest paths the guard feeds gate_base_test_old_state come from
# `git diff --name-only` — ROOT-relative. A plain `git ls-tree` resolves its
# path against the -C dir, exits 0 with EMPTY output for a file that exists on
# base, and the function called a real repair `added` (=> refused). 74/74 stayed
# green with that bug present because no fixture had this shape. This one does.
SUB_ORIGIN="$TMPD/sub-origin.git"
SUB_SEED="$TMPD/sub-seed"
SUB_CLONE="$TMPD/sub-rig-clone"    # the repo TOPLEVEL
SUB_RIG="$SUB_CLONE/sub"           # what the guard is handed as RIG_PATH
git init -q --bare "$SUB_ORIGIN"
git -C "$SUB_ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q -b main "$SUB_SEED"
git -C "$SUB_SEED" config user.email "test@gascity.local"
git -C "$SUB_SEED" config user.name "Test"
mkdir -p "$SUB_SEED/sub/lib"
cp "$TMPD/seed/lib/add.sh" "$TMPD/seed/lib/red.selftest.sh" "$TMPD/seed/lib/green.selftest.sh" "$SUB_SEED/sub/lib/"
# Exit-status boundary fixtures (old-fails must only be claimed for a test that
# RAN and went red; 126/127/signal are "could not tell", not "was red").
printf '#!/usr/bin/env bash\nexit 125\n' > "$SUB_SEED/sub/lib/exit125.selftest.sh"
printf '#!/usr/bin/env bash\nexit 126\n' > "$SUB_SEED/sub/lib/exit126.selftest.sh"
printf '#!/usr/bin/env bash\nexit 127\n' > "$SUB_SEED/sub/lib/exit127.selftest.sh"
cat > "$SUB_SEED/sub/lib/sigkill.selftest.sh" <<'SIGKILLEOF'
#!/usr/bin/env bash
kill -9 $$
SIGKILLEOF
# ga-x4mkk2: selftests that live OUTSIDE the rig subtree (sub/) — the shape of the 4
# selftests (of 304) in the real repo that the arm-B detection, scoped to the -C
# directory, cannot see. sub-other/ shares the "sub" NAME prefix on purpose: a subtree
# test that forgets the trailing slash would file it as inside.
mkdir -p "$SUB_SEED/top/lib" "$SUB_SEED/sub-other/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_SEED/top/lib/outside.selftest.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_SEED/sub-other/lib/sibling.selftest.sh"
git -C "$SUB_SEED" add -A
git -C "$SUB_SEED" commit -q -m base
git -C "$SUB_SEED" remote add origin "$SUB_ORIGIN"
git -C "$SUB_SEED" push -q origin main
git clone -q "$SUB_ORIGIN" "$SUB_CLONE"
git -C "$SUB_CLONE" config user.email "test@gascity.local"
git -C "$SUB_CLONE" config user.name "Test"

# feat/repair-sub: the old red form is fixed to go green (the ga-97tqu7 shape).
git -C "$SUB_CLONE" checkout -q -b feat/repair-sub
git -C "$SUB_CLONE" show main:sub/lib/green.selftest.sh > "$SUB_CLONE/sub/lib/red.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "fix: repair the wrongly-red selftest"
git -C "$SUB_CLONE" push -q origin feat/repair-sub
# feat/noop-sub: an already-green selftest is edited but stays green in BOTH forms.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/noop-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/sub/lib/green.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "chore: touch an already-green selftest"
git -C "$SUB_CLONE" push -q origin feat/noop-sub
# feat/added-sub: a brand-new always-green selftest (there is no old form).
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/added-sub
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_CLONE/sub/lib/brand-new.selftest.sh"
git -C "$SUB_CLONE" add -A
git -C "$SUB_CLONE" commit -q -m "test: add a new always-green selftest"
git -C "$SUB_CLONE" push -q origin feat/added-sub

# ga-x4mkk2 branches: changed selftests OUTSIDE sub/ (the arm-B detection is blind to them).
# feat/outside-only-sub: the ONLY changed selftest is outside the subtree.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-only-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "chore: touch a selftest outside the rig subtree"
git -C "$SUB_CLONE" push -q origin feat/outside-only-sub
# feat/outside-two-sub: TWO outside — one modified, one ADDED four levels deep (proves the
# wildcard crosses directory separators).
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-two-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
mkdir -p "$SUB_CLONE/top/a/b/c"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_CLONE/top/a/b/c/deep.selftest.sh"
git -C "$SUB_CLONE" add -A
git -C "$SUB_CLONE" commit -q -m "test: two selftests outside the rig subtree"
git -C "$SUB_CLONE" push -q origin feat/outside-two-sub
# feat/outside-and-inside-sub: a REPAIR inside the subtree + an edit outside it.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-and-inside-sub
git -C "$SUB_CLONE" show main:sub/lib/green.selftest.sh > "$SUB_CLONE/sub/lib/red.selftest.sh"
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "fix: repair a selftest inside the subtree, touch one outside"
git -C "$SUB_CLONE" push -q origin feat/outside-and-inside-sub
# feat/sibling-prefix-sub: sub-other/ is OUTSIDE sub/ even though its name starts with "sub".
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/sibling-prefix-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/sub-other/lib/sibling.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "chore: touch a selftest in a sibling dir sharing the sub prefix"
git -C "$SUB_CLONE" push -q origin feat/sibling-prefix-sub
# feat/outside-deleted-sub: an outside selftest is DELETED. The detection filters AM, so the
# count must too — otherwise the two numbers stop being comparable.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-deleted-sub
git -C "$SUB_CLONE" rm -q "top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" commit -q -m "chore: delete a selftest outside the rig subtree"
git -C "$SUB_CLONE" push -q origin feat/outside-deleted-sub
git -C "$SUB_CLONE" checkout -q main

# Fixture preconditions — without these the block below could pass vacuously.
eq "subdir-topology fixture: RIG_PATH really is a SUBDIRECTORY of the repo toplevel" \
  "$(git -C "$SUB_RIG" rev-parse --show-prefix)" "sub/"
_SS_BASE=$(git -C "$SUB_RIG" rev-parse origin/main)
eq "subdir-topology fixture: a plain ls-tree on the ROOT-relative path is EMPTY from the subdir rig (the failure mode this block guards)" \
  "$(git -C "$SUB_RIG" ls-tree "$_SS_BASE" -- sub/lib/red.selftest.sh)" ""
[ -n "$(git -C "$SUB_RIG" ls-tree --full-tree "$_SS_BASE" -- sub/lib/red.selftest.sh)" ] \
  && ok "subdir-topology fixture: ls-tree --full-tree finds that same path" \
  || bad "subdir-topology fixture: ls-tree --full-tree did not find sub/lib/red.selftest.sh"

_SAVED_RIG_PATH="$RIG_PATH"
RIG_PATH="$SUB_RIG"
eq "subdir rig, real-git+origin: repair (old red, new green) -> consertou-teste-vermelho (was passou-na-base = REFUSED before this fix)" \
  "$(run_live_basetest_check feat/repair-sub)" "consertou-teste-vermelho"
eq "subdir rig, real-git+origin: no-op edit (green in BOTH forms) -> passou-na-base (still refused in arm B)" \
  "$(run_live_basetest_check feat/noop-sub)" "passou-na-base"
eq "subdir rig, real-git+origin: ADDED selftest (no old form) -> passou-na-base (still refused in arm B)" \
  "$(run_live_basetest_check feat/added-sub)" "passou-na-base"

_SS_WT=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-subold.XXXXXX")
git -C "$SUB_RIG" worktree add --detach --quiet "$_SS_WT" "$_SS_BASE" 2>/dev/null
eq "subdir rig, old_state: base copy red on base (root-relative path) -> old-fails, NOT added" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/red.selftest.sh)" "old-fails"
eq "subdir rig, old_state: base copy green on base -> old-passes" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/green.selftest.sh)" "old-passes"
eq "subdir rig, old_state: path genuinely absent on base -> added (--full-tree must not turn absence into an error)" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/brand-new.selftest.sh)" "added"
eq "subdir rig, old_state: unresolvable base sha -> unknown (ls-tree error, not 'added')" \
  "$(gate_base_test_old_state "$SUB_RIG" "0000000000000000000000000000000000000000" "$_SS_WT" sub/lib/red.selftest.sh)" "unknown"
# old-fails is a positive claim ("the old test was red"): only an ordinary failure status may make it.
eq "old_state: old form exits 125 (top of the ordinary-failure range) -> old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/exit125.selftest.sh)" "old-fails"
eq "old_state: old form exits 126 (could not execute) -> unknown, NOT old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/exit126.selftest.sh)" "unknown"
eq "old_state: old form exits 127 (command not found in the bare worktree) -> unknown, NOT old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/exit127.selftest.sh)" "unknown"
eq "old_state: old form killed by SIGKILL (exit 137) -> unknown, NOT old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/sigkill.selftest.sh)" "unknown"
git -C "$SUB_RIG" worktree remove --force "$_SS_WT" 2>/dev/null || rm -rf "$_SS_WT" 2>/dev/null
_SS_LEFTOVER=$(git -C "$SUB_RIG" worktree list 2>/dev/null | grep -c -E "gate-rstae-selftest-(wt|subold)" || true)
eq "subdir rig: no leftover linked worktrees after the subdir-topology runs" "${_SS_LEFTOVER:-0}" "0"

# ── ga-x4mkk2: a changed selftest OUTSIDE the rig subtree is counted, never silent ──
# The detection above is scoped to the -C directory (a subdirectory of the repo), so a
# submission whose only changed selftest lives elsewhere reads as sem-teste-novo — the
# same look as "no test at all". Each line below reads the VERDICT and the COUNT from one
# run: the verdict must be exactly what it was before this bead (option 1: detection
# only, the arm-B experiment is untouched) while the count makes the blind spot visible.
eq "subdir rig: ONLY selftest changed is outside sub/ -> verdict unchanged (sem-teste-novo), outside-subtree=1" \
  "$(run_live_check_full feat/outside-only-sub)" "sem-teste-novo outside-subtree=1"
eq "subdir rig: two outside (one modified, one ADDED 4 levels deep) -> outside-subtree=2 (the wildcard crosses directory separators)" \
  "$(run_live_check_full feat/outside-two-sub)" "sem-teste-novo outside-subtree=2"
eq "subdir rig: REPAIR inside + edit outside -> verdict unchanged (consertou-teste-vermelho), outside-subtree=1" \
  "$(run_live_check_full feat/outside-and-inside-sub)" "consertou-teste-vermelho outside-subtree=1"
eq "subdir rig: sub-other/ (name starts with 'sub') is OUTSIDE sub/ -> outside-subtree=1 (subtree test needs the trailing slash)" \
  "$(run_live_check_full feat/sibling-prefix-sub)" "sem-teste-novo outside-subtree=1"
eq "subdir rig: a DELETED outside selftest is not counted (same AM filter as the detection) -> outside-subtree=0" \
  "$(run_live_check_full feat/outside-deleted-sub)" "sem-teste-novo outside-subtree=0"
eq "subdir rig: repair, everything inside -> verdict unchanged, outside-subtree=0 (measured zero, not blank)" \
  "$(run_live_check_full feat/repair-sub)" "consertou-teste-vermelho outside-subtree=0"
eq "subdir rig: no-op edit inside -> still refusable (passou-na-base), outside-subtree=0" \
  "$(run_live_check_full feat/noop-sub)" "passou-na-base outside-subtree=0"
eq "subdir rig: ADDED selftest inside -> still refusable (passou-na-base), outside-subtree=0" \
  "$(run_live_check_full feat/added-sub)" "passou-na-base outside-subtree=0"
eq "subdir rig: nonexistent branch (no base) -> nao-consegui-medir, outside-subtree=unknown, NOT 0" \
  "$(run_live_check_full feat/does-not-exist)" "nao-consegui-medir outside-subtree=unknown"

# Direct three-state tests of the helper itself. `unknown` (could not ask git) must never
# collapse into `0` (asked, and the answer was none) — that is the family-#2 defect this
# whole check exists downstream of, and a blind-spot counter that reads 0 on error would
# hide the blind spot exactly when it is widest.
git -C "$SUB_RIG" fetch -q origin main feat/outside-two-sub 2>/dev/null
_XK_BASE=$(git -C "$SUB_RIG" rev-parse origin/main)
_XK_HEAD=$(git -C "$SUB_RIG" rev-parse origin/feat/outside-two-sub)
_XK_ZERO="0000000000000000000000000000000000000000"
eq "outside_subtree: two outside selftests between base and head -> 2" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_HEAD")" "2"
eq "outside_subtree: empty range (base..base) is a MEASURED zero -> 0" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_BASE")" "0"
eq "outside_subtree: unresolvable head sha (diff ERRORS) -> unknown, NOT 0" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_ZERO")" "unknown"
eq "outside_subtree: unresolvable base sha (diff ERRORS) -> unknown, NOT 0" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_ZERO" "$_XK_HEAD")" "unknown"
eq "outside_subtree: empty rig -> unknown" \
  "$(gate_base_test_outside_subtree "" "$_XK_BASE" "$_XK_HEAD")" "unknown"
eq "outside_subtree: empty base -> unknown" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "" "$_XK_HEAD")" "unknown"
eq "outside_subtree: empty head -> unknown" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "")" "unknown"
_XK_NOTREPO=$(mktemp -d "${TMPDIR:-/tmp}/gate-xk-notrepo.XXXXXX")
eq "outside_subtree: rig is not a git repo -> unknown (an empty diff there must not read as 0)" \
  "$(gate_base_test_outside_subtree "$_XK_NOTREPO" "$_XK_BASE" "$_XK_HEAD")" "unknown"
rmdir "$_XK_NOTREPO" 2>/dev/null
eq "outside_subtree: always exits 0 (safe under the guard's set -e even on 'unknown')" \
  "$(gate_base_test_outside_subtree "" "" "" >/dev/null; echo $?)" "0"
RIG_PATH="$_SAVED_RIG_PATH"

# The call site's own third state: gate_base_test_old_state is documented to print
# exactly one word, but if it ever printed NOTHING (killed substitution) or an
# unrecognised word, a `case` with only old-fails/unknown arms would count nothing,
# the file would read "ran, passed, no repair, no doubt", and the verdict would be
# passou-na-base = a REFUSED builder made from "I don't know". noopmod is the
# fixture that is honestly refusable (green in both forms): with a healthy
# function it stays passou-na-base (asserted above); with a function that cannot
# answer it must degrade to nao-consegui-medir.
_REAL_OLDSTATE_DEF=$(declare -f gate_base_test_old_state)
gate_base_test_old_state() { printf ''; return 0; }
eq "call site: old_state prints NOTHING -> nao-consegui-medir, NOT a refusal (don't-know must not become passou-na-base)" \
  "$(run_live_basetest_check feat/noopmod)" "nao-consegui-medir"
gate_base_test_old_state() { printf 'garbage'; return 0; }
eq "call site: old_state prints an UNRECOGNISED word -> nao-consegui-medir, NOT a refusal" \
  "$(run_live_basetest_check feat/noopmod)" "nao-consegui-medir"
eval "$_REAL_OLDSTATE_DEF"
eq "call site: real old_state restored after the stubs (noopmod is refusable again)" \
  "$(run_live_basetest_check feat/noopmod)" "passou-na-base"

# Worktree hygiene: after all the runs above, the RIG_PATH clone must have
# no leftover linked worktrees and no stray temp directories — a leaked
# throwaway worktree on every guard sweep would slowly fill disk on the one
# machine this whole city's control plane runs on.
_WT_LEFTOVER=$(git -C "$RIG_PATH" worktree list 2>/dev/null | grep -c -E "gate-rstae-selftest-(wt|oldstate)" || true)
eq "no leftover linked worktrees after 9 check runs + the old_state probes (git worktree remove ran cleanly every time)" \
  "${_WT_LEFTOVER:-0}" "0"

rm -rf "$TMPD"
trap - EXIT

# ── 3. DRIFT GUARDS on the live script ───────────────────────────────────────
echo "── 3. drift guards: placement, param shape, wiring, ordering, arm-A isolation ──"

# 3a. Both pure functions defined before the GATE_GUARD_LIB_ONLY cutoff (the
# ga-zdkn1-class regression this codebase has already hit once before: a
# pure function defined past the cutoff is invisible to lib-only sourcing).
CUTOFF_LINE=$(grep -n 'GATE_GUARD_LIB_ONLY:-' "$GUARD" | head -1 | cut -d: -f1)
ARM_DEF_LINE=$(grep -n '^gate_ab_arm_for_bead() {' "$GUARD" | head -1 | cut -d: -f1)
VERDICT_DEF_LINE=$(grep -n '^gate_base_test_verdict() {' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$ARM_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$ARM_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_ab_arm_for_bead (L$ARM_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_ab_arm_for_bead def=${ARM_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

if [ -n "$VERDICT_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$VERDICT_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_base_test_verdict (L$VERDICT_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_base_test_verdict def=${VERDICT_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

OUTSIDE_DEF_LINE=$(grep -n '^gate_base_test_outside_subtree() {' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$OUTSIDE_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$OUTSIDE_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_base_test_outside_subtree (L$OUTSIDE_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE) (ga-x4mkk2)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_base_test_outside_subtree def=${OUTSIDE_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

OLDSTATE_DEF_LINE=$(grep -n '^gate_base_test_old_state() {' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$OLDSTATE_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$OLDSTATE_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_base_test_old_state (L$OLDSTATE_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE) (ga-yl1k3w)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_base_test_old_state def=${OLDSTATE_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

# 3b. The Step 5b-pre2 block exists exactly once and is wired: calls both
# pure functions, gates the worktree machinery on arm B, sets
# gate-status:error, and exits 1 on the block path.
STEP_COUNT=$(grep -c 'Step 5b-pre2 (ga-rstae)' "$GUARD")
eq "guard.sh: Step 5b-pre2 (ga-rstae) block present exactly once" "$STEP_COUNT" "1"

ABT_BLOCK=$(awk '/Step 5b-pre2 \(ga-rstae\)/,/^fi$/' "$GUARD")

echo "$ABT_BLOCK" | grep '_ABT_ARM=\$(gate_ab_arm_for_bead "\$BEAD_ID")' >/dev/null \
  && ok "guard.sh: block calls gate_ab_arm_for_bead on BEAD_ID" \
  || bad "guard.sh: block does not call gate_ab_arm_for_bead correctly"

echo "$ABT_BLOCK" | grep '_ABT_VERDICT=\$(gate_base_test_verdict' >/dev/null \
  && ok "guard.sh: block calls gate_base_test_verdict" \
  || bad "guard.sh: block does not call gate_base_test_verdict"

echo "$ABT_BLOCK" | grep 'set_gate_status "\$MARKER_ID" "error"' >/dev/null \
  && ok "guard.sh: refusal sets gate-status:error (re-submittable, matches Step 5b-pre's own convention)" \
  || bad "guard.sh: refusal does not set gate-status:error"

echo "$ABT_BLOCK" | grep 'exit 1' >/dev/null \
  && ok "guard.sh: refusal actually exits 1 (does not fall through to Step 7)" \
  || bad "guard.sh: refusal does not exit — sweep would continue to Step 7 anyway"

echo "$ABT_BLOCK" | grep '"\$_ABT_VERDICT" = "passou-na-base"' >/dev/null \
  && ok "guard.sh: refusal is gated EXACTLY on verdict = passou-na-base (not a broader condition that would also refuse sem-teste-novo/nao-consegui-medir/reprovou-na-base)" \
  || bad "guard.sh: refusal condition missing or wrong — could over-refuse the non-blocking states"

# 3c. Arm-A isolation: the arm-B gate must appear BEFORE any worktree/fetch
# machinery in the block — i.e. arm A truly never reaches it. Compare line
# numbers WITHIN the extracted block (awk NR resets per invocation, so use a
# fresh grep -n on the block text itself).
ARM_GATE_LINE=$(echo "$ABT_BLOCK" | grep -n '"\$_ABT_ARM" = "B"' | head -1 | cut -d: -f1)
WORKTREE_LINE=$(echo "$ABT_BLOCK" | grep -n 'worktree add' | head -1 | cut -d: -f1)
FETCH_LINE=$(echo "$ABT_BLOCK" | grep -n 'git -C "\$RIG_PATH" fetch origin main "\$BRANCH"' | head -1 | cut -d: -f1)

if [ -n "$ARM_GATE_LINE" ] && [ -n "$WORKTREE_LINE" ] && [ "$ARM_GATE_LINE" -lt "$WORKTREE_LINE" ]; then
  ok "guard.sh: arm-B gate (block-relative L$ARM_GATE_LINE) precedes worktree add (L$WORKTREE_LINE) — arm A cannot reach the worktree machinery"
else
  bad "REGRESSION: arm gate=${ARM_GATE_LINE:-missing} worktree=${WORKTREE_LINE:-missing} — arm A might reach worktree machinery"
fi

if [ -n "$ARM_GATE_LINE" ] && [ -n "$FETCH_LINE" ] && [ "$ARM_GATE_LINE" -lt "$FETCH_LINE" ]; then
  ok "guard.sh: arm-B gate (block-relative L$ARM_GATE_LINE) precedes the fetch/rev-parse/merge-base git calls (L$FETCH_LINE) — arm A does zero git IO from this check"
else
  bad "REGRESSION: arm gate=${ARM_GATE_LINE:-missing} fetch=${FETCH_LINE:-missing} — arm A might trigger git IO"
fi

# 3c'. ga-yl1k3w: the old-form probe is arm-B-only too — the call must sit after
# the arm-B gate inside the block, and the verdict call must hand over BOTH new
# counts (a 4-arg call would silently drop repairs and re-refuse them).
OLDSTATE_CALL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_old_state "\$RIG_PATH"' | head -1 | cut -d: -f1)
if [ -n "$ARM_GATE_LINE" ] && [ -n "$OLDSTATE_CALL_LINE" ] && [ "$ARM_GATE_LINE" -lt "$OLDSTATE_CALL_LINE" ]; then
  ok "guard.sh: gate_base_test_old_state is called only after the arm-B gate (block-relative L$OLDSTATE_CALL_LINE > L$ARM_GATE_LINE) — arm A never runs it"
else
  bad "REGRESSION: old-state call line=${OLDSTATE_CALL_LINE:-missing} arm gate=${ARM_GATE_LINE:-missing} — arm A might run the old-form probe"
fi

echo "$ABT_BLOCK" | grep '_ABT_VERDICT=\$(gate_base_test_verdict "\$_ABT_DETECTED" "\$_ABT_COPY_OK" "\$_ABT_RAN" "\$_ABT_FAILED" "\$_ABT_REPAIRED" "\$_ABT_UNCLASSIFIED")' >/dev/null \
  && ok "guard.sh: verdict call passes repaired AND unclassified (6 args)" \
  || bad "guard.sh: verdict call does not pass both new counts — repairs would be re-refused"

echo "$ABT_BLOCK" | grep -E '^[[:space:]]*added\|old-passes\)[[:space:]]+:[[:space:]]*;;' >/dev/null \
  && echo "$ABT_BLOCK" | grep -E '^[[:space:]]*\*\)[[:space:]]+_ABT_UNCLASSIFIED=\$\(\(_ABT_UNCLASSIFIED \+ 1\)\) ;;' >/dev/null \
  && ok "guard.sh: the old_state case names added|old-passes as the ONLY no-count answers and sends everything else (empty/garbage/unknown) to unclassified" \
  || bad "guard.sh: the old_state case lacks the added|old-passes / *) unclassified arms — an empty or unrecognised answer would read as a refusal"

echo "$ABT_BLOCK" | grep 'AB-BASE-TEST bead=.*repaired=\$_ABT_REPAIRED unclassified=\$_ABT_UNCLASSIFIED' >/dev/null \
  && ok "guard.sh: AB-BASE-TEST log line carries repaired=/unclassified= (appended, existing fields untouched)" \
  || bad "guard.sh: AB-BASE-TEST log line lacks repaired=/unclassified="

# ga-x4mkk2: the outside-subtree count is arm-B-only, starts as `unknown` (never measured is
# not 0), is measured with the REAL helper against the same base/head the detection uses, is
# logged as the LAST field (existing fields untouched), and is NOT an input to any verdict or
# refusal — option 1 of the bead is detection only.
OUTSIDE_CALL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_outside_subtree "\$RIG_PATH" "\$_ABT_BASE" "\$_ABT_BRANCH_SHA"' | head -1 | cut -d: -f1)
if [ -n "$ARM_GATE_LINE" ] && [ -n "$OUTSIDE_CALL_LINE" ] && [ "$ARM_GATE_LINE" -lt "$OUTSIDE_CALL_LINE" ]; then
  ok "guard.sh: gate_base_test_outside_subtree is called only after the arm-B gate (block-relative L$OUTSIDE_CALL_LINE > L$ARM_GATE_LINE) with RIG_PATH/base/branch sha — arm A never runs it"
else
  bad "REGRESSION: outside-subtree call line=${OUTSIDE_CALL_LINE:-missing} arm gate=${ARM_GATE_LINE:-missing} — arm A might run it, or it is not wired to the same base/head as the detection"
fi

echo "$ABT_BLOCK" | grep -E '^[[:space:]]*_ABT_OUTSIDE="unknown"' >/dev/null \
  && ok "guard.sh: _ABT_OUTSIDE starts as \"unknown\" (a count that was never measured cannot read as 0)" \
  || bad "guard.sh: _ABT_OUTSIDE is not initialised to \"unknown\" — an unmeasured submission could log a blank or a 0"

echo "$ABT_BLOCK" | grep -E 'AB-BASE-TEST bead=.*unclassified=\$_ABT_UNCLASSIFIED outside-subtree=\$_ABT_OUTSIDE"$' >/dev/null \
  && ok "guard.sh: AB-BASE-TEST log line ends with outside-subtree=\$_ABT_OUTSIDE (appended last, existing fields untouched)" \
  || bad "guard.sh: AB-BASE-TEST log line does not end with outside-subtree=\$_ABT_OUTSIDE"

_XK_LEAK=$(echo "$ABT_BLOCK" | grep -E 'gate_base_test_verdict|"\$_ABT_VERDICT" = ' | grep -c '_ABT_OUTSIDE')
eq "guard.sh: _ABT_OUTSIDE appears on NO verdict-computing or refusal line (count is logged, never decided on)" "${_XK_LEAK:-0}" "0"

# The tally: "counted separately" only means something if scripts/gate-ab-apuracao.sh
# really aggregates by verdict. That section was silent for two independent reasons
# (it read the DISPATCHER log, which never gets AB-BASE-TEST lines, and used \S in a
# BSD sed that does not understand it), so run the script's OWN pipeline text — not a
# re-typed regexp — over a synthetic guard log in the guard's real line format.
_APU="$SELF_DIR/../../../scripts/gate-ab-apuracao.sh"
if [ ! -r "$_APU" ]; then
  bad "cannot read $_APU — the tally cannot be checked"
else
  _APU_PIPE=$(awk "/^  grep -oE 'AB-BASE-TEST/,/head -10/" "$_APU")
  _APU_LOG=$(mktemp "${TMPDIR:-/tmp}/gate-rstae-apu.XXXXXX")
  {
    echo "[2026-09-25 09:21:37] [quality-gate-guard] AB-BASE-TEST bead=ga-a arm=B verdict=passou-na-base branch=fix/ga-a base=aaa detected=1 copy_ok=1 ran=1 failed=0 repaired=0 unclassified=0 outside-subtree=1"
    echo "[2026-09-25 09:22:37] [quality-gate-guard] AB-BASE-TEST bead=ga-b arm=B verdict=passou-na-base branch=fix/ga-b base=bbb detected=1 copy_ok=1 ran=1 failed=0"
    echo "[2026-09-25 09:23:37] [quality-gate-guard] AB-BASE-TEST bead=ga-c arm=B verdict=consertou-teste-vermelho branch=fix/ga-c base=ccc detected=1 copy_ok=1 ran=1 failed=0 repaired=1 unclassified=0 outside-subtree=0"
    echo "[2026-09-25 09:24:37] [quality-gate-guard] AB-BASE-TEST bead=ga-d arm=B verdict=reprovou-na-base branch=fix/ga-d base=ddd detected=1 copy_ok=1 ran=1 failed=1 repaired=0 unclassified=0 outside-subtree=unknown"
  } > "$_APU_LOG"
  _APU_OUT=$(GUARD_LOG="$_APU_LOG" eval "$_APU_PIPE" 2>/dev/null | sed -E 's/^ +//; s/ +/ /g')
  rm -f "$_APU_LOG"
  printf '%s\n' "$_APU_OUT" | grep -qx '2 B passou-na-base' \
    && ok "apuracao tally aggregates the two passou-na-base lines into ONE row (2 B passou-na-base) — BSD-sed safe" \
    || bad "apuracao tally did not aggregate: got '$(printf '%s' "$_APU_OUT" | tr '\n' '|')'"
  printf '%s\n' "$_APU_OUT" | grep -qx '1 B consertou-teste-vermelho' \
    && ok "apuracao tally counts consertou-teste-vermelho as its own separate row (1 B consertou-teste-vermelho)" \
    || bad "apuracao tally lacks the separate consertou-teste-vermelho row: got '$(printf '%s' "$_APU_OUT" | tr '\n' '|')'"
  grep -q 'quality-gate-guard.log' "$_APU" \
    && ok "apuracao reads quality-gate-guard.log for the verdict section (where the guard actually writes AB-BASE-TEST)" \
    || bad "apuracao does not reference quality-gate-guard.log — verdict section would read the wrong log again"
fi

# 3d. Every arm-B path (including nao-consegui-medir / sem-teste-novo /
# reprovou-na-base, not just the block case) reaches the label+log lines —
# required so the A/B apuracao counts all four states, not just refusals.
echo "$ABT_BLOCK" | grep 'label add "\$MARKER_ID" "gate-ab:arm-b"' >/dev/null \
  && ok "guard.sh: arm-b label is written unconditionally within the arm-B branch (before the passou-na-base check, not inside it)" \
  || bad "guard.sh: gate-ab:arm-b label missing or misplaced"

echo "$ABT_BLOCK" | grep 'AB-BASE-TEST bead=\$BEAD_ID arm=B verdict=\$_ABT_VERDICT' >/dev/null \
  && ok "guard.sh: structured AB-BASE-TEST log line present with bead/arm/verdict fields (apuracao-parseable)" \
  || bad "guard.sh: AB-BASE-TEST structured log line missing or malformed"

# 3e. Ordering: the check runs AFTER RIG_PATH is resolved (it depends on it)
# and BEFORE Step 7 parks the marker as gate-status:queued (the actual
# enqueue point — refusing after that would be pointless).
RIGPATH_LINE=$(grep -n '\[ -d "\$RIG_PATH" \] || RIG_PATH=""' "$GUARD" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'Step 5b-pre2 (ga-rstae)' "$GUARD" | head -1 | cut -d: -f1)
QUEUED_LINE=$(grep -n 'label add    "\$MARKER_ID" "gate-status:queued"' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$RIGPATH_LINE" ] && [ -n "$CHECK_LINE" ] && [ "$RIGPATH_LINE" -lt "$CHECK_LINE" ]; then
  ok "guard.sh: RIG_PATH resolved (L$RIGPATH_LINE) BEFORE the base-test check (L$CHECK_LINE)"
else
  bad "guard.sh: ordering wrong — RIG_PATH=${RIGPATH_LINE:-missing} check=${CHECK_LINE:-missing}, check would run with an unresolved RIG_PATH"
fi

if [ -n "$CHECK_LINE" ] && [ -n "$QUEUED_LINE" ] && [ "$CHECK_LINE" -lt "$QUEUED_LINE" ]; then
  ok "guard.sh: base-test check (L$CHECK_LINE) fires BEFORE the marker is parked gate-status:queued (L$QUEUED_LINE) — genuinely pre-enqueue"
else
  bad "guard.sh: ordering wrong — check=${CHECK_LINE:-missing} queued-park=${QUEUED_LINE:-missing}, check would run too late to prevent enqueueing"
fi

# 3f. The neighboring ga-pj5va check (Step 5b-pre) is untouched and still
# wired — regression guard: this bead must not have weakened or duplicated
# the existing branch-content-coherence safety net while inserting its own.
PJ5VA_COUNT=$(grep -c 'Step 5b-pre (ga-pj5va)' "$GUARD")
eq "guard.sh: neighboring Step 5b-pre (ga-pj5va) check still present exactly once, untouched" "$PJ5VA_COUNT" "1"

CBC_CALL_COUNT=$(grep -c 'branch_bead_commit_verdict' "$GUARD")
if [ "$CBC_CALL_COUNT" -ge 2 ]; then
  ok "guard.sh: branch_bead_commit_verdict (ga-pj5va's function) still defined+called ($CBC_CALL_COUNT refs) — not weakened by this bead's insertion"
else
  bad "guard.sh: only $CBC_CALL_COUNT branch_bead_commit_verdict references — ga-pj5va's check may have been damaged"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
