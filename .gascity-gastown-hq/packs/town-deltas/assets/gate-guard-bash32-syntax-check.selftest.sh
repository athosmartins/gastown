#!/usr/bin/env bash
# gate-guard-bash32-syntax-check.selftest.sh — Proves the ga-7dx2vw fix:
# quality-gate-guard.sh's Step 5b-pre3 refuses, at SUBMISSION time, any
# branch that changes a .sh file under packs/town-deltas/assets/ or
# scripts/ which does not parse under the REAL /bin/bash 3.2 interpreter
# these scripts are actually launchd-invoked with.
#
# INCIDENT THIS CLOSES: ga-6aj348 (00d526a76) passed reviewer verdicts and
# whatever ran under the PATH's Homebrew bash 5.3, but broke quality-gate-
# dispatcher.sh's own parse under /bin/bash 3.2 the moment it was merged and
# a sweep tried to spawn a reviewer — the gate itself was the broken
# component, 21 markers queued (incl. a P0) for 3h until a human-triggered
# emergency revert (79392548f) landed straight to main. Root cause (measured
# directly on THIS machine's two real bash binaries, both invoked below): a
# `case...esac` whose closing `esac` directly abuts a `$(...)` command
# substitution's own closing `)` with no separating newline — /bin/bash
# (3.2.57 on macOS) rejects it with "syntax error near unexpected token
# `;;'"; the PATH's Homebrew bash (5.x) parses it fine. shellcheck -s bash
# does not catch it either — it is a raw bash-3.2 PARSER limitation, not a
# shellcheck-recognized anti-pattern.
#
# Four layers, matching this codebase's own established convention (see
# gate-guard-ab-base-test-check.selftest.sh, the sibling this file copies
# its shape from):
#   0. Confirms the fixture actually reproduces the divergence on THIS
#      machine's real /bin/bash vs the PATH bash — without this, the rest
#      of the test would be exercising a fixture that proves nothing.
#   1. Pure-function unit tests (GATE_GUARD_LIB_ONLY=1 sourcing):
#      gate_bash32_verdict.
#   2. Real-git plumbing composition against a temp repo WITH an origin
#      remote — reproduces the exact fetch/rev-parse/merge-base/diff/
#      git-show/bash-n sequence the live check runs, not just the isolated
#      pure function. Covers: a branch that introduces the bad construct
#      (must be refused), a branch with a clean .sh change (must proceed), a
#      branch that touches no .sh file (must proceed, sem-sh-alterado), and
#      a branch whose ONLY bad .sh file sits OUTSIDE the two protected trees
#      (must proceed — scope must not over-reach).
#   3. Drift guards on the live script — placement, wiring, ordering.
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
bash -n "$GUARD" && ok "guard passes bash -n (PATH bash) syntax check" || bad "guard has syntax errors under PATH bash"
/bin/bash -n "$GUARD" && ok "guard passes /bin/bash -n (the real 3.2 interpreter) syntax check — this fix must not itself repeat ga-6aj348" \
  || bad "REGRESSION: guard.sh itself fails to parse under /bin/bash 3.2 — this fix would BE the next ga-6aj348"

# ── 0. Fixture sanity: does the case-in-$() construct actually diverge here? ──
echo "── 0. fixture sanity: bash-3.2-vs-5.x divergence reproduces on THIS machine ──"

FIXTURE_TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-b32-fixture.XXXXXX")"
BAD_FIXTURE="$FIXTURE_TMPD/bad.sh"
GOOD_FIXTURE="$FIXTURE_TMPD/good.sh"

cat > "$BAD_FIXTURE" <<'BADEOF'
#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  a) echo A;;
  b) echo B;;
  *) echo Z;; esac)
echo "$result"
BADEOF

cat > "$GOOD_FIXTURE" <<'GOODEOF'
#!/usr/bin/env bash
x="a"
case "$x" in
  a) result="A" ;;
  b) result="B" ;;
  *) result="Z" ;;
esac
echo "$result"
GOODEOF

if /bin/bash -n "$BAD_FIXTURE" >/dev/null 2>&1; then
  bad "FATAL: fixture assumption broken — /bin/bash 3.2 on this machine accepts the case-in-\$() construct (expected it to reject). Cannot proceed; find a different reproducer."
  rm -rf "$FIXTURE_TMPD"
  echo "  PASS=$PASS  FAIL=$FAIL"; echo "  RESULT: FAIL"; exit 1
else
  ok "/bin/bash 3.2 REJECTS the case-in-\$() fixture, as the incident describes"
fi

if bash -n "$BAD_FIXTURE" >/dev/null 2>&1; then
  ok "PATH bash (Homebrew, newer) ACCEPTS the same fixture — this is exactly how it slipped through ga-6aj348's own review/tests"
else
  bad "fixture assumption broken — PATH bash also rejects it; the divergence this bug is about does not reproduce with this fixture"
fi

/bin/bash -n "$GOOD_FIXTURE" >/dev/null 2>&1 \
  && ok "control fixture (plain case...esac, not inside \$()) parses clean under /bin/bash 3.2" \
  || bad "control fixture unexpectedly fails under /bin/bash 3.2 — fixture itself is broken"

rm -rf "$FIXTURE_TMPD"

# ── 1. Pure function: gate_bash32_verdict ────────────────────────────────────
echo "── 1. pure function unit tests ──"

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail, which leaks into this
        # shell (sourced, not subprocessed) and would silently kill the rest
        # of this harness on the first non-zero command — same fix
        # gate-guard-ab-base-test-check.selftest.sh uses for the identical
        # reason.

if ! type gate_bash32_verdict >/dev/null 2>&1; then
  bad "FATAL: gate_bash32_verdict not defined after LIB_ONLY sourcing — cannot continue section 1"
else
  eq "no .sh changed (0,0,0) -> sem-sh-alterado" \
    "$(gate_bash32_verdict 0 0 0)" "sem-sh-alterado"

  eq "unparseable changed count (empty) -> nao-consegui-medir, NOT sem-sh-alterado (the erro==vazio collapse this whole convention exists to catch)" \
    "$(gate_bash32_verdict "" 0 0)" "nao-consegui-medir"

  eq "unparseable changed count (non-numeric) -> nao-consegui-medir" \
    "$(gate_bash32_verdict "abc" 0 0)" "nao-consegui-medir"

  eq "1 file, fully checked, parses clean -> bash32-ok" \
    "$(gate_bash32_verdict 1 1 0)" "bash32-ok"

  eq "1 file, fully checked, fails to parse -> bash32-fail (the block case)" \
    "$(gate_bash32_verdict 1 1 1)" "bash32-fail"

  eq "3 files, all checked, all clean -> bash32-ok" \
    "$(gate_bash32_verdict 3 3 0)" "bash32-ok"

  eq "3 files, all checked, only ONE fails -> bash32-fail (one genuine syntax failure is enough to block)" \
    "$(gate_bash32_verdict 3 3 1)" "bash32-fail"

  eq "2 changed but only 1 checked (extraction failure) -> nao-consegui-medir (partial measurement is never treated as proof)" \
    "$(gate_bash32_verdict 2 1 0)" "nao-consegui-medir"

  eq "2 files, both checked, both fail -> bash32-fail" \
    "$(gate_bash32_verdict 2 2 2)" "bash32-fail"
fi

# ── 2. Real-git integration ───────────────────────────────────────────────────
echo "── 2. real-git integration: fetch/merge-base/diff/git-show/bash-n against a real origin remote ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-b32-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

ORIGIN_DIR="$TMPD/origin.git"
CLONE_DIR="$TMPD/rig-clone"

git init -q --bare "$ORIGIN_DIR"
git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main

git init -q -b main "$TMPD/seed"
git -C "$TMPD/seed" config user.email "test@gascity.local"
git -C "$TMPD/seed" config user.name "Test"
mkdir -p "$TMPD/seed/packs/town-deltas/assets" "$TMPD/seed/scripts"
cat > "$TMPD/seed/packs/town-deltas/assets/existing.sh" <<'SEEDEOF'
#!/usr/bin/env bash
echo "existing, untouched"
SEEDEOF
git -C "$TMPD/seed" add -A
git -C "$TMPD/seed" commit -q -m base
git -C "$TMPD/seed" remote add origin "$ORIGIN_DIR"
git -C "$TMPD/seed" push -q origin main

git clone -q "$ORIGIN_DIR" "$CLONE_DIR"
git -C "$CLONE_DIR" config user.email "test@gascity.local"
git -C "$CLONE_DIR" config user.name "Test"

# Branch A: introduces the bad construct under packs/town-deltas/assets/ —
# must be caught.
git -C "$CLONE_DIR" checkout -q -b feat/badsyntax
cat > "$CLONE_DIR/packs/town-deltas/assets/new-daemon.sh" <<'BADEOF'
#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  a) echo A;;
  b) echo B;;
  *) echo Z;; esac)
echo "$result"
BADEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: new daemon with a bash-3.2-incompatible construct"
git -C "$CLONE_DIR" push -q origin feat/badsyntax

# Branch B: clean .sh change under scripts/ — must proceed.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/goodsyntax
mkdir -p "$CLONE_DIR/scripts"
cat > "$CLONE_DIR/scripts/helper.sh" <<'GOODEOF'
#!/usr/bin/env bash
x="a"
case "$x" in
  a) result="A" ;;
  *) result="Z" ;;
esac
echo "$result"
GOODEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: new helper script, clean bash-3.2 syntax"
git -C "$CLONE_DIR" push -q origin feat/goodsyntax

# Branch C: no .sh file touched at all — just docs.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/notouch
echo "notes" > "$CLONE_DIR/NOTES.md"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "docs: notes, no .sh files touched"
git -C "$CLONE_DIR" push -q origin feat/notouch

# Branch D: bad construct, but OUTSIDE both protected trees — must NOT be
# flagged (scope must not over-reach into every rig's own scripts).
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/outofscope
mkdir -p "$CLONE_DIR/some/other/dir"
cat > "$CLONE_DIR/some/other/dir/unrelated.sh" <<'OOSEOF'
#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  a) echo A;;
  *) echo Z;; esac)
echo "$result"
OOSEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: bad-syntax script outside the protected trees"
git -C "$CLONE_DIR" push -q origin feat/outofscope

RIG_PATH="$TMPD/rig-registered-copy"
git clone -q "$ORIGIN_DIR" "$RIG_PATH"
git -C "$RIG_PATH" config user.email "test@gascity.local"
git -C "$RIG_PATH" config user.name "Test"

run_live_bash32_check() {
  # Mirrors the EXACT git-plumbing + bash-n sequence in quality-gate-
  # guard.sh's Step 5b-pre3 block, through computing the verdict. The
  # bd/label/comment/refuse side effects need a live city DB and are
  # intentionally NOT exercised here — same scope
  # gate-guard-ab-base-test-check.selftest.sh's run_live_basetest_check()
  # uses for the sibling ga-rstae check.
  local branch="$1"
  local verdict="nao-consegui-medir"   # pessimistic default — mirrors the
                                        # live check's own _B32_VERDICT init
  local changed=0 checked=0 failed=0
  local base="" files=""

  git -C "$RIG_PATH" fetch origin main "$branch" --quiet 2>/dev/null || true
  local main_sha branch_sha
  main_sha=$(git -C "$RIG_PATH" rev-parse "origin/main" 2>/dev/null || echo "")
  branch_sha=$(git -C "$RIG_PATH" rev-parse "origin/$branch" 2>/dev/null || echo "")
  if [ -n "$main_sha" ] && [ -n "$branch_sha" ]; then
    base=$(git -C "$RIG_PATH" merge-base "$branch_sha" "$main_sha" 2>/dev/null || echo "")
  fi

  if [ -n "$base" ]; then
    files=$(git -C "$RIG_PATH" diff --name-only --diff-filter=AM "${base}..${branch_sha}" -- 'packs/town-deltas/assets' 'scripts' 2>/dev/null | grep '\.sh$' || true)
    if [ -n "$files" ]; then
      changed=$(printf '%s\n' "$files" | grep -c .)
      local wt
      wt=$(mktemp -d "${TMPDIR:-/tmp}/gate-b32-selftest-wt.XXXXXX" 2>/dev/null || echo "")
      if [ -n "$wt" ]; then
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          mkdir -p "$(dirname "$wt/$f")" 2>/dev/null
          if git -C "$RIG_PATH" show "${branch_sha}:$f" > "$wt/$f" 2>/dev/null; then
            checked=$((checked + 1))
            /bin/bash -n "$wt/$f" >/dev/null 2>&1 || failed=$((failed + 1))
          fi
        done <<FILESEOF
$files
FILESEOF
        rm -rf "$wt" 2>/dev/null
      fi
    fi
    verdict=$(gate_bash32_verdict "$changed" "$checked" "$failed")
  fi
  printf '%s' "$verdict"
}

eq "real-git+origin: badsyntax (bash-3.2-incompatible .sh under packs/town-deltas/assets/) -> bash32-fail (WOULD be refused today)" \
  "$(run_live_bash32_check feat/badsyntax)" "bash32-fail"

eq "real-git+origin: goodsyntax (clean .sh under scripts/) -> bash32-ok (proceeds)" \
  "$(run_live_bash32_check feat/goodsyntax)" "bash32-ok"

eq "real-git+origin: notouch (no .sh file touched) -> sem-sh-alterado (proceeds)" \
  "$(run_live_bash32_check feat/notouch)" "sem-sh-alterado"

eq "real-git+origin: outofscope (bad syntax OUTSIDE both protected trees) -> sem-sh-alterado (scope does not over-reach)" \
  "$(run_live_bash32_check feat/outofscope)" "sem-sh-alterado"

eq "real-git+origin: nonexistent branch (fetch/rev-parse fails) -> nao-consegui-medir, fails open, never crashes" \
  "$(run_live_bash32_check feat/does-not-exist)" "nao-consegui-medir"

_WT_LEFTOVER=$(git -C "$RIG_PATH" worktree list 2>/dev/null | grep -c "gate-b32-selftest-wt" || true)
eq "no leftover linked worktrees after check runs" "${_WT_LEFTOVER:-0}" "0"

rm -rf "$TMPD"
trap - EXIT

# ── 3. DRIFT GUARDS on the live script ────────────────────────────────────────
echo "── 3. drift guards: placement, wiring, ordering ──"

CUTOFF_LINE=$(grep -n 'GATE_GUARD_LIB_ONLY:-' "$GUARD" | head -1 | cut -d: -f1)
VERDICT_DEF_LINE=$(grep -n '^gate_bash32_verdict() {' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$VERDICT_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$VERDICT_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_bash32_verdict (L$VERDICT_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_bash32_verdict def=${VERDICT_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

STEP_COUNT=$(grep -c 'Step 5b-pre3 (ga-7dx2vw)' "$GUARD")
eq "guard.sh: Step 5b-pre3 (ga-7dx2vw) block present exactly once" "$STEP_COUNT" "1"

B32_BLOCK=$(awk '/Step 5b-pre3 \(ga-7dx2vw\)/,/^fi$/' "$GUARD")

echo "$B32_BLOCK" | grep 'gate_bash32_verdict "\$_B32_CHANGED" "\$_B32_CHECKED" "\$_B32_FAILED"' >/dev/null \
  && ok "guard.sh: block calls gate_bash32_verdict with the three counts" \
  || bad "guard.sh: block does not call gate_bash32_verdict correctly"

echo "$B32_BLOCK" | grep '/bin/bash -n' >/dev/null \
  && ok "guard.sh: block invokes /bin/bash -n explicitly (not bare 'bash -n', which would hit PATH's Homebrew bash and never catch this class of bug)" \
  || bad "guard.sh: block does not invoke /bin/bash -n — would not reproduce the real interpreter"

echo "$B32_BLOCK" | grep -F "'packs/town-deltas/assets' 'scripts'" >/dev/null \
  && ok "guard.sh: diff is scoped to packs/town-deltas/assets and scripts (not every rig's own scripts)" \
  || bad "guard.sh: diff pathspec scoping missing or changed"

echo "$B32_BLOCK" | grep 'set_gate_status "\$MARKER_ID" "error"' >/dev/null \
  && ok "guard.sh: refusal sets gate-status:error (re-submittable, matches the sibling checks' own convention)" \
  || bad "guard.sh: refusal does not set gate-status:error"

echo "$B32_BLOCK" | grep 'exit 1' >/dev/null \
  && ok "guard.sh: refusal actually exits 1 (does not fall through to Step 7)" \
  || bad "guard.sh: refusal does not exit — sweep would continue to Step 7 anyway"

echo "$B32_BLOCK" | grep '"\$_B32_VERDICT" in' -A1 | grep 'bash32-fail)' >/dev/null \
  && ok "guard.sh: refusal is gated on verdict = bash32-fail (not a broader condition that would also refuse sem-sh-alterado/nao-consegui-medir/bash32-ok)" \
  || bad "guard.sh: refusal condition missing or wrong — could over-refuse the non-blocking states"

RIGPATH_LINE=$(grep -n '\[ -d "\$RIG_PATH" \] || RIG_PATH=""' "$GUARD" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'Step 5b-pre3 (ga-7dx2vw)' "$GUARD" | head -1 | cut -d: -f1)
QUEUED_LINE=$(grep -n 'label add    "\$MARKER_ID" "gate-status:queued"' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$RIGPATH_LINE" ] && [ -n "$CHECK_LINE" ] && [ "$RIGPATH_LINE" -lt "$CHECK_LINE" ]; then
  ok "guard.sh: RIG_PATH resolved (L$RIGPATH_LINE) BEFORE the bash32 check (L$CHECK_LINE)"
else
  bad "guard.sh: ordering wrong — RIG_PATH=${RIGPATH_LINE:-missing} check=${CHECK_LINE:-missing}, check would run with an unresolved RIG_PATH"
fi

if [ -n "$CHECK_LINE" ] && [ -n "$QUEUED_LINE" ] && [ "$CHECK_LINE" -lt "$QUEUED_LINE" ]; then
  ok "guard.sh: bash32 check (L$CHECK_LINE) fires BEFORE the marker is parked gate-status:queued (L$QUEUED_LINE) — genuinely pre-enqueue"
else
  bad "guard.sh: ordering wrong — check=${CHECK_LINE:-missing} queued-park=${QUEUED_LINE:-missing}, check would run too late to prevent enqueueing"
fi

# Neighboring checks (ga-pj5va, ga-rstae) untouched.
PJ5VA_COUNT=$(grep -c 'Step 5b-pre (ga-pj5va)' "$GUARD")
eq "guard.sh: neighboring Step 5b-pre (ga-pj5va) check still present exactly once, untouched" "$PJ5VA_COUNT" "1"
RSTAE_COUNT=$(grep -c 'Step 5b-pre2 (ga-rstae)' "$GUARD")
eq "guard.sh: neighboring Step 5b-pre2 (ga-rstae) check still present exactly once, untouched" "$RSTAE_COUNT" "1"
E7ZK7_COUNT=$(grep -c 'Step 5b (ga-e7zk7)' "$GUARD")
eq "guard.sh: downstream Step 5b (ga-e7zk7) still present exactly once, untouched" "$E7ZK7_COUNT" "1"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
