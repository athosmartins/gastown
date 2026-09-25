#!/usr/bin/env bash
# quality-gate-full-suite-advisory.selftest.sh — ga-q4fkxa: prove the full-suite
# check no longer holds the citywide gate lock silently, on REAL git fixtures (a
# bare "rig" repo, real worktrees, real scripted suites) — no live Dolt/gc/launchd.
#
# Incident (25/09): finalizing ONE whatsapp_automation PASS took 51 min. gate_full_suite_check
# runs inside the citywide single-instance gate lock, for up to 2 × GATE_FULL_SUITE_TIMEOUT_SECS,
# and wrote no log line while it ran. For whatsapp_automation it can never change the outcome
# ("regression" needs a GREEN baseline on main, and that suite never finishes inside the budget
# — wa-f1hz5 / wa-t6eoz), and interrupted sweeps leaked 8+1 worktrees in /tmp (37 registered).
#
# Proven here (each against the REAL functions, extracted from the dispatcher):
#   A. an ADVISORY rig (env list, or a .gate-full-suite.advisory file on the DEFAULT branch)
#      never runs the suite, and says so in the log (source=env|file)
#   B. the declaration cannot be forged by the branch under review, an unreadable default
#      branch is "unknown" (→ run the check), matching is exact (no substring), and
#      GATE_FULL_SUITE_SKIP_ADVISORY=0 restores the pre-fix behavior
#   C. a non-advisory rig logs START and END (duration, verdict, both exit codes, TIMED OUT
#      called out) and leaves no worktree behind; verdicts are unchanged
#   D. the reaper removes worktrees of dead/ancient owners, never a live one, never a foreign
#      name, and runs even for an advisory rig
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

FX="$(mktemp -d "${TMPDIR:-/tmp}/ga-q4fkxa-fx-XXXXXX")"
trap 'rm -rf "$FX" 2>/dev/null || true' EXIT
export FS_MARK="$FX/suite-runs.txt"
LOGF="$FX/gate.log"
GATE_FS_TMPDIR="$FX/tmp"; mkdir -p "$GATE_FS_TMPDIR"
export GATE_FS_TMPDIR

# ── Load the REAL impure block (SELFTEST-EXTRACT) and the REAL pure helper (lib-only) ──
# Extract FIRST and fail fast: sourcing the whole dispatcher takes ~20s, and the gate's base-commit
# A/B (ga-rstae) gives each selftest only 30s against the code BEFORE the fix. Without this order a
# base that lacks the block burns most of that budget sourcing, and under load ends "unmeasured"
# instead of the clean FAIL that proves the test depends on the fix.
BLOCK="$(sed -n '/# SELFTEST-EXTRACT gate-full-suite-check: BEGIN/,/# SELFTEST-EXTRACT gate-full-suite-check: END/p' "$DISPATCHER")"
[ -n "$BLOCK" ] || { echo "FATAL: SELFTEST-EXTRACT gate-full-suite-check block not found in $DISPATCHER (ga-q4fkxa not applied?)"; exit 1; }

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
type gate_full_suite_verdict >/dev/null 2>&1 \
  || { echo "FATAL: gate_full_suite_verdict not defined (ga-3wgx8 missing?)"; exit 1; }

# The block's own dependencies: log() (the real one writes to STDOUT — see the dispatcher —
# so capture it to a file, which is also what lets us assert on it) and git_rig().
log() { printf '%s\n' "$*" >> "$LOGF"; }
git_rig() { git --git-dir="$FX/rig.git" "$@"; }
eval "$BLOCK"
for f in gate_full_suite_check gate_full_suite_is_advisory gate_full_suite_reap_stale gate_full_suite_log_end; do
  type "$f" >/dev/null 2>&1 || { echo "FATAL: $f not defined by the extracted block"; exit 1; }
done

# ── Fixture rig: bare repo + one scripted suite per scenario ───────────────────
G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
G init -q --bare "$FX/rig.git"
G init -q "$FX/src"
: > "$FX/src/README"; G -C "$FX/src" add README; G -C "$FX/src" commit -q -m base
G -C "$FX/src" branch base
G -C "$FX/src" push -q "$FX/rig.git" base:refs/heads/base

# mk_side <ref-name> <suite-rc> [sleep-secs] [extra-file...]
#   commit on top of `base` with an executable .gate-full-suite.sh that records
#   its run, then exits <suite-rc>; push it as refs/heads/<ref-name>.
mk_side() {
  local name="$1" rc="$2" nap="${3:-0}"; shift 3 || shift $#
  G -C "$FX/src" checkout -q -B "$name" base
  printf '#!/bin/bash\necho "%s ran rc=%s" >> "$FS_MARK"\nsleep %s\nexit %s\n' "$name" "$rc" "$nap" "$rc" > "$FX/src/.gate-full-suite.sh"
  chmod +x "$FX/src/.gate-full-suite.sh"
  G -C "$FX/src" add .gate-full-suite.sh
  local f
  for f in "$@"; do echo "declared" > "$FX/src/$f"; G -C "$FX/src" add "$f"; done
  G -C "$FX/src" commit -q -m "$name"
  G -C "$FX/src" push -q -f "$FX/rig.git" "$name:refs/heads/$name"
}
sha_of() { git_rig rev-parse "refs/heads/$1"; }

reset_run() { : > "$LOGF"; : > "$FS_MARK"; }
runs()      { grep -c . "$FS_MARK" || true; }
logged()    { grep -cE "$1" "$LOGF" || true; }
# count by BASENAME, never by "$GATE_FS_TMPDIR/…": git prints PHYSICAL paths (/private/var/…) while the
# fixture dir is spelled through the /var symlink — a prefix grep would count 0 forever and every
# "nothing left behind" assertion would pass vacuously (section 5 pins the positive case).
fs_wts()    { git_rig worktree list --porcelain | grep -c 'worktree .*/gc-gate-fs-' || true; }
fs_dirs()   { find "$GATE_FS_TMPDIR" -maxdepth 1 -name 'gc-gate-fs-*' -type d | grep -c . || true; }

# ── scenarios ──
mk_side main-green  0 0
mk_side main-red    1 0
mk_side main-adv    0 0 .gate-full-suite.advisory      # rig-owned declaration ON the default branch
mk_side br-green    0 0
mk_side br-red      1 0
mk_side br-slow     0 6                                 # outlives a 1s budget → timeout (rc 124)
mk_side br-selfexempt 1 0 .gate-full-suite.advisory     # branch tries to declare ITSELF advisory

unset GATE_FULL_SUITE_ADVISORY_RIGS GATE_FULL_SUITE_SKIP_ADVISORY 2>/dev/null || true
RIG="whatsapp_automation"

echo "── 1. C: non-advisory rig — START/END logged, verdicts unchanged, nothing left behind ──"
reset_run
gate_full_suite_check "$(sha_of br-green)" "refs/heads/main-green" 30
eq "branch green → pass"                         "$GATE_FS_VERDICT" "pass"
eq "suite ran exactly once (main never measured)" "$(runs)" "1"
eq "START line logged"                            "$(logged 'full-suite START rig=whatsapp_automation')" "1"
eq "END line logged with verdict=pass"            "$(logged 'full-suite END .*verdict=pass branch_rc=0')" "1"
eq "END line carries a duration"                  "$(logged 'duration=[0-9]+s')" "1"
eq "START says it holds the citywide lock"        "$(logged 'holds the citywide gate lock')" "1"
eq "no worktree left registered"                  "$(fs_wts)" "0"
eq "no worktree dir left on disk"                 "$(fs_dirs)" "0"

reset_run
gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-green" 30
eq "branch red + main green → regression (the blocking verdict is unchanged)" "$GATE_FS_VERDICT" "regression"
eq "both runs happened"                           "$(runs)" "2"
eq "END shows both exit codes"                    "$(logged 'verdict=regression branch_rc=1 main_rc=0')" "1"
eq "no worktree left registered"                  "$(fs_wts)" "0"

reset_run
gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-red" 30
eq "branch red + main red → preexisting-debt"      "$GATE_FS_VERDICT" "preexisting-debt"
eq "END shows both exit codes"                    "$(logged 'verdict=preexisting-debt branch_rc=1 main_rc=1')" "1"

reset_run
gate_full_suite_check "$(sha_of br-slow)" "refs/heads/main-red" 1
eq "budget exceeded on both sides → preexisting-debt (as wa-f1hz5 measured)" "$GATE_FS_VERDICT" "preexisting-debt"
eq "END calls the branch timeout out as a TIMEOUT, not a test failure" "$(logged 'branch_rc=124.*branch run TIMED OUT after 1s')" "1"
eq "no worktree left registered after a timeout"   "$(fs_wts)" "0"

echo "── 2. A: advisory rig — the suite is NOT run, and the log says why ──"
reset_run
GATE_FULL_SUITE_ADVISORY_RIGS="foo whatsapp_automation" gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-green" 30
eq "env-declared advisory → skipped"              "$GATE_FS_VERDICT" "skipped"
eq "suite did NOT run"                            "$(runs)" "0"
eq "log says SKIPPED source=env"                  "$(logged 'full-suite check SKIPPED for rig=whatsapp_automation .*source=env')" "1"
eq "no START line (the lock is not held)"         "$(logged 'full-suite START')" "0"
eq "GATE_FS_DETAIL explains the skip"             "$(printf '%s' "$GATE_FS_DETAIL" | grep -c 'advisory (source=env)' || true)" "1"
eq "no worktree created"                          "$(fs_wts)" "0"

reset_run
gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-adv" 30
eq "file-declared advisory (on the DEFAULT branch) → skipped" "$GATE_FS_VERDICT" "skipped"
eq "suite did NOT run"                            "$(runs)" "0"
eq "log says SKIPPED source=file"                 "$(logged 'source=file')" "1"

echo "── 3. B: the declaration cannot be forged, guessed, or half-read ──"
reset_run
gate_full_suite_check "$(sha_of br-selfexempt)" "refs/heads/main-green" 30
eq "branch that adds .gate-full-suite.advisory ITSELF is NOT exempt (read from main, not the branch)" "$GATE_FS_VERDICT" "regression"
eq "…and its suite ran"                           "$(runs)" "2"

reset_run
gate_full_suite_check "$(sha_of br-green)" "refs/heads/does-not-exist" 30
eq "unreadable default ref = UNKNOWN → runs the check as before (never skips on an error)" "$GATE_FS_VERDICT" "pass"
eq "…suite ran"                                   "$(runs)" "1"
eq "…and the unreadable declaration is logged"    "$(logged 'could not read .gate-full-suite.advisory on refs/heads/does-not-exist')" "1"
eq "…never mistaken for advisory"                 "$(logged 'SKIPPED')" "0"

reset_run
RIG="whatsapp" GATE_FULL_SUITE_ADVISORY_RIGS="whatsapp_automation" gate_full_suite_check "$(sha_of br-green)" "refs/heads/main-green" 30
eq "rig 'whatsapp' is NOT matched by list entry 'whatsapp_automation' (exact match, no substring)" "$GATE_FS_VERDICT" "pass"
reset_run
RIG="whatsapp_automation" GATE_FULL_SUITE_ADVISORY_RIGS="dc,whatsapp_automation,lexbh" gate_full_suite_check "$(sha_of br-green)" "refs/heads/main-green" 30
eq "comma-separated list matches"                 "$GATE_FS_VERDICT" "skipped"
reset_run
RIG="whatsapp_automation" GATE_FULL_SUITE_ADVISORY_RIGS="dc, whatsapp_automation" gate_full_suite_check "$(sha_of br-green)" "refs/heads/main-green" 30
eq "comma+space separated list matches"           "$GATE_FS_VERDICT" "skipped"
reset_run
RIG="" GATE_FULL_SUITE_ADVISORY_RIGS="whatsapp_automation" gate_full_suite_check "$(sha_of br-green)" "refs/heads/main-green" 30
eq "empty RIG never matches the env list (fails toward RUNNING the check)" "$GATE_FS_VERDICT" "pass"
RIG="whatsapp_automation"

reset_run
GATE_FULL_SUITE_SKIP_ADVISORY=0 GATE_FULL_SUITE_ADVISORY_RIGS="whatsapp_automation" gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-green" 30
eq "GATE_FULL_SUITE_SKIP_ADVISORY=0 restores the pre-fix behavior (env declaration ignored)" "$GATE_FS_VERDICT" "regression"
reset_run
GATE_FULL_SUITE_SKIP_ADVISORY=0 gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-adv" 30
eq "…and the file declaration is ignored too"     "$GATE_FS_VERDICT" "regression"

echo "── 4. opt-in gate unchanged: a rig with no .gate-full-suite.sh pays nothing and logs nothing ──"
G -C "$FX/src" checkout -q -B no-optin base
G -C "$FX/src" commit -q --allow-empty -m no-optin
G -C "$FX/src" push -q -f "$FX/rig.git" no-optin:refs/heads/no-optin
reset_run
gate_full_suite_check "$(sha_of no-optin)" "refs/heads/main-green" 30
eq "not opted in → skipped"                       "$GATE_FS_VERDICT" "skipped"
eq "…zero log lines"                              "$(grep -c . "$LOGF" || true)" "0"

echo "── 5. D: the reaper ──"
# a PID that is certainly not running
DEAD=""; for p in 99981 99982 99983 99984 99985 99986 99987 99988; do ps -p "$p" >/dev/null 2>&1 || { DEAD="$p"; break; }; done
[ -n "$DEAD" ] || { echo "FATAL: could not find a dead pid for the fixture"; exit 1; }
BSHA="$(sha_of br-green)"
git_rig worktree add -q --detach "$GATE_FS_TMPDIR/gc-gate-fs-branch-$DEAD" "$BSHA"
git_rig worktree add -q --detach "$GATE_FS_TMPDIR/gc-gate-fs-main-$DEAD"   "$BSHA"
git_rig worktree add -q --detach "$GATE_FS_TMPDIR/gc-gate-fs-branch-$$"    "$BSHA"          # owner (this test) is ALIVE
git_rig worktree add -q --detach "$GATE_FS_TMPDIR/other-wt-$DEAD"          "$BSHA"          # foreign name, dead-looking suffix
: > "$GATE_FS_TMPDIR/gc-gate-fs-branch-log-STALE1"; touch -t 200001010000 "$GATE_FS_TMPDIR/gc-gate-fs-branch-log-STALE1"
: > "$GATE_FS_TMPDIR/gc-gate-fs-branch-log-FRESH1"
eq "fixture: 4 worktrees registered before the reap (positive control — proves fs_wts can see them)" "$(git_rig worktree list --porcelain | grep -cE 'worktree .*/(gc-gate-fs-|other-wt-)')" "4"
eq "fixture is spelled through a symlink, like /tmp on macOS (the case that broke the first reaper)" \
  "$([ "$(cd "$GATE_FS_TMPDIR" && pwd -P)" != "$GATE_FS_TMPDIR" ] && echo symlinked || echo plain)" "symlinked"
reset_run
gate_full_suite_reap_stale
eq "dead-owner branch worktree reaped"            "$([ -d "$GATE_FS_TMPDIR/gc-gate-fs-branch-$DEAD" ] && echo present || echo gone)" "gone"
eq "dead-owner main worktree reaped"              "$([ -d "$GATE_FS_TMPDIR/gc-gate-fs-main-$DEAD" ] && echo present || echo gone)" "gone"
eq "…and their registrations are dropped"         "$(git_rig worktree list --porcelain | grep -c "gc-gate-fs-.*-$DEAD" || true)" "0"
eq "LIVE-owner worktree is NEVER touched"         "$([ -d "$GATE_FS_TMPDIR/gc-gate-fs-branch-$$" ] && echo present || echo gone)" "present"
eq "foreign-named worktree is NEVER touched"      "$([ -d "$GATE_FS_TMPDIR/other-wt-$DEAD" ] && echo present || echo gone)" "present"
eq "stale (>3h) suite log deleted"                "$([ -e "$GATE_FS_TMPDIR/gc-gate-fs-branch-log-STALE1" ] && echo present || echo gone)" "gone"
eq "fresh suite log kept"                         "$([ -e "$GATE_FS_TMPDIR/gc-gate-fs-branch-log-FRESH1" ] && echo present || echo gone)" "present"
eq "reaper logged what it did"                    "$(logged 'reaped 2 stale full-suite worktree')" "1"

# PID-reuse guard: a live owner but an ANCIENT dir is stale anyway
touch -t 200001010000 "$GATE_FS_TMPDIR/gc-gate-fs-branch-$$"
GATE_FS_STALE_MAX_AGE_SECS=60 gate_full_suite_reap_stale
eq "live pid but dir older than the age cap → reaped (PID-reuse guard)" "$([ -d "$GATE_FS_TMPDIR/gc-gate-fs-branch-$$" ] && echo present || echo gone)" "gone"
eq "foreign-named worktree still untouched after the second reap" "$([ -d "$GATE_FS_TMPDIR/other-wt-$DEAD" ] && echo present || echo gone)" "present"

echo "── 5b. D: a worktree listing that FAILS is reported as UNVERIFIED, never read as 'nothing to reap' ──"
reset_run
_SAVED_GIT_RIG="$(declare -f git_rig)"
git_rig() { return 3; }
gate_full_suite_reap_stale
eval "$_SAVED_GIT_RIG"
eq "listing failure is logged: reap SKIPPED, nothing removed" "$(logged 'could not list worktrees \(git rc=3\) .*reap SKIPPED')" "1"
eq "…and no 'reaped N' claim is made" "$(logged 'reaped [0-9]+ stale')" "0"
eq "git_rig restored for the rest of the run" "$(git_rig rev-parse --is-bare-repository)" "true"

echo "── 6. D: an advisory rig still reaps what it leaked before it was advisory ──"
git_rig worktree add -q --detach "$GATE_FS_TMPDIR/gc-gate-fs-branch-$DEAD" "$BSHA"
reset_run
GATE_FULL_SUITE_ADVISORY_RIGS="whatsapp_automation" gate_full_suite_check "$(sha_of br-red)" "refs/heads/main-green" 30
eq "advisory → skipped"                           "$GATE_FS_VERDICT" "skipped"
eq "…but the stale worktree was reaped"           "$([ -d "$GATE_FS_TMPDIR/gc-gate-fs-branch-$DEAD" ] && echo present || echo gone)" "gone"
eq "…and the suite still did not run"             "$(runs)" "0"

echo "── 7. drift-guards: the real call site is wired to the checked function ──"
grep -q 'gate_full_suite_check "\$BRANCH_SHA" "origin/\$DEFAULT_BRANCH"' "$DISPATCHER" \
  && ok "gate_finalize_run still calls gate_full_suite_check with the default-branch ref" \
  || bad "call site changed — the advisory read uses the 2nd argument as the DEFAULT branch ref"
grep -q 'gate_full_suite_reap_stale || true' "$DISPATCHER" \
  && ok "reaper is invoked from the check and cannot fail it (|| true)" \
  || bad "reaper call missing or unguarded"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
