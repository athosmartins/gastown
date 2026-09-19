#!/usr/bin/env bash
# Selftest for git-deploy-pull.sh (ga-nh1muq).
#
# A/B/C mirror lexbh-deploy-cmd.selftest.sh's correctness shape (behind->ff,
# diverged->refuse, untracked-survives). D is the load-bearing one: it
# reproduces the ACTUAL race this bead reports — via REAL concurrent
# processes, not a hand-poisoned FETCH_HEAD file. D1 proves the OLD
# `git pull --ff-only` pattern (still in prod today, in delivery-runbooks.toml
# and deploy-sync.sh, until this bead's sibling commits land) fails under a
# real concurrent interloper. D2 races TWO git-deploy-pull.sh callers against
# EACH OTHER (the actual post-fix topology: deploy-sync's 60s pull and
# story-delivery's deploy_cmd, both converted) and proves that pairing never
# misbehaves — see D2's own comment for why a non-cooperating third party
# (e.g. deploy_daemons.sh, deliberately not converted) is out of scope here.
# E proves the mutex-busy path is a distinct, non-mutating, exit-75 outcome.
# F is a regression guard for a latency trap found while writing this script
# (see git-deploy-pull.sh's own header): sourcing git-lock-hygiene.sh without
# pre-setting GIT_LOCK_RIG_ROOTS triggers a live `gc rig list` call on every
# invocation.
#
# Everything runs against throwaway git repos under a mktemp -d directory;
# the real whatsapp_automation checkout is never touched.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/git-deploy-pull.sh"

pass=0; fail=0
must() { "$@" || { echo "SETUP FAILED: $*" >&2; exit 1; }; }  # unrecoverable — abort, don't cascade
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

[ -x "$SCRIPT" ] && ok || bad "git-deploy-pull.sh is not present/executable at $SCRIPT"
bash -n "$SCRIPT" && ok || bad "git-deploy-pull.sh has a syntax error"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ORIGIN="$WORK/origin.git"
must git init --quiet --bare -b main "$ORIGIN"

OTHER="$WORK/other"
must git clone --quiet "$ORIGIN" "$OTHER"
must git -C "$OTHER" checkout --quiet -B main
must git -C "$OTHER" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m seed
must git -C "$OTHER" push --quiet origin HEAD:main
# A second branch, used by the race harness (D) as the interloper's target —
# real production interlopers are ALSO explicit-branch fetches (story-delivery.sh
# fetches $MERGE_BRANCH/$STALE_BRANCH), not bare `git fetch origin`.
must git -C "$OTHER" checkout --quiet -b other-branch
must git -C "$OTHER" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m other-branch-work
must git -C "$OTHER" push --quiet origin HEAD:other-branch
must git -C "$OTHER" checkout --quiet main

seed_runtime() { must git clone --quiet "$ORIGIN" "$1"; must git -C "$1" checkout --quiet -B main; }
advance_origin() {
  must git -C "$OTHER" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m "upstream work $RANDOM"
  must git -C "$OTHER" push --quiet origin HEAD:main
}
run_script() { # $1=repo $2=branch(optional) -> exit code in $?, stdout+stderr in $WORK/last.txt
  bash "$SCRIPT" "$1" "${2:-main}" >"$WORK/last.txt" 2>&1
}

# ── A. behind by one commit, clean tree -> fast-forwards, exit 0 ──────────────
RT_A="$WORK/rt-behind"; seed_runtime "$RT_A"; advance_origin
BEFORE=$(git -C "$RT_A" rev-parse HEAD)
run_script "$RT_A"; RC=$?
AFTER=$(git -C "$RT_A" rev-parse HEAD)
ORIGIN_TIP=$(git -C "$OTHER" rev-parse HEAD)
if [ "$RC" -eq 0 ] && [ "$AFTER" = "$ORIGIN_TIP" ] && [ "$AFTER" != "$BEFORE" ]; then
  ok
else
  bad "A behind-by-one: expected exit 0, HEAD->$ORIGIN_TIP; got rc=$RC head=$AFTER (was $BEFORE). Output: $(cat "$WORK/last.txt")"
fi

# ── B. local commit diverges from origin -> refuses, HEAD untouched ───────────
RT_B="$WORK/rt-diverged"; seed_runtime "$RT_B"
must git -C "$RT_B" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m "local-only work"
advance_origin
BEFORE=$(git -C "$RT_B" rev-parse HEAD)
run_script "$RT_B"; RC=$?
AFTER=$(git -C "$RT_B" rev-parse HEAD)
if [ "$RC" -ne 0 ] && [ "$RC" -ne 75 ] && [ "$AFTER" = "$BEFORE" ]; then
  ok
else
  bad "B diverged: expected a real (non-75) refusal with HEAD unchanged; got rc=$RC head=$AFTER (was $BEFORE). Output: $(cat "$WORK/last.txt")"
fi

# ── C. unrelated untracked file survives a REAL fast-forward ──────────────────
RT_C="$WORK/rt-untracked"; seed_runtime "$RT_C"
echo "scratch-$RANDOM" > "$RT_C/untracked-scratch.txt"
UNTRACKED_CONTENT="$(cat "$RT_C/untracked-scratch.txt")"
advance_origin
run_script "$RT_C"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$RT_C/untracked-scratch.txt" ] && [ "$(cat "$RT_C/untracked-scratch.txt")" = "$UNTRACKED_CONTENT" ]; then
  ok
else
  bad "C untracked-file: expected exit 0 with untracked-scratch.txt preserved; got rc=$RC. Output: $(cat "$WORK/last.txt")"
fi

# ── D. THE RACE (ga-nh1muq) — real concurrent processes, not a poisoned file ──
# Victim = the pattern literally in prod today (delivery-runbooks.toml's
# deploy_cmd / deploy-sync.sh, pre-fix): `git pull --ff-only`, no args.
# Interloper = a second real process explicit-fetching a DIFFERENT branch
# concurrently — the same shape story-delivery.sh's own $MERGE_BRANCH/
# $STALE_BRANCH fetches take against this exact repo (see story-delivery.sh
# lines ~1762/~1887). Raced for real (backgrounded, launched back-to-back);
# not deterministic on a single run, so this sweeps up to 30 iterations and
# requires the failure to show up at least once — matching what a tight
# manual repro measured (2/150 to reproduce the EXACT bead-quoted string;
# far more of the two known-error-string OR ref-lock-contention shapes
# overall). A run that never reproduces the OLD pattern's raciness at all
# would mean this test stopped testing anything — see the T25-style mutation
# discipline elsewhere in this pack.
RT_D="$WORK/rt-race-old"; seed_runtime "$RT_D"
OLD_PATTERN_FAILED=0
OLD_PATTERN_FAIL_MSG=""
for i in $(seq 1 30); do
  advance_origin
  ( git -C "$RT_D" pull --ff-only --quiet 2>"$WORK/d-old-$i.err" ) &
  VPID=$!
  ( git -C "$RT_D" fetch origin main other-branch --quiet 2>/dev/null ) &
  IPID=$!
  wait "$VPID"; VRC=$?
  wait "$IPID"
  if [ "$VRC" -ne 0 ]; then
    OLD_PATTERN_FAILED=1
    OLD_PATTERN_FAIL_MSG="$(cat "$WORK/d-old-$i.err")"
    break
  fi
done
if [ "$OLD_PATTERN_FAILED" -eq 1 ]; then
  ok
else
  bad "D1 (base-fails check): 'git pull --ff-only' (today's prod pattern) did NOT fail even once across 30 racing iterations — this selftest is not exercising the real race; strengthen it before trusting D2 below."
fi
case "$OLD_PATTERN_FAIL_MSG" in
  *FETCH_HEAD*|*"multiple branches"*|*"cannot lock ref"*) ok ;;
  *) bad "D1b: old pattern failed, but not with a known race signature — got: $OLD_PATTERN_FAIL_MSG (investigate before assuming this is the same bug)" ;;
esac

# D2 scope (measured while writing this test, see git-deploy-pull.sh's own
# header): the mutex only serializes callers that GO THROUGH IT. Racing the
# wrapper against a truly non-cooperating raw `git fetch` (e.g. simulating
# deploy_daemons.sh, which this bead deliberately does NOT convert — it
# already uses the safe explicit fetch+merge pattern, just not through this
# mutex) still intermittently hits the transient "cannot lock ref" class —
# confirmed directly, not theorized. That is an accepted, documented residual
# (deploy_daemons.sh runs every 5min vs this pair's 60s/on-demand cadence,
# and every caller already treats a deploy failure as "retry next cycle").
# D2 tests what this bead actually fixes: the two REAL racing culprits
# (com.whatsapp.deploy-sync's 60s pull and story-delivery.sh's deploy_cmd),
# BOTH converted to this wrapper — i.e. wrapper vs wrapper, matching the
# actual post-fix production topology.
RT_D2="$WORK/rt-race-new"; seed_runtime "$RT_D2"
NEW_PATTERN_BAD=0
NEW_PATTERN_MSG=""
for i in $(seq 1 30); do
  advance_origin
  ORIGIN_TIP=$(git -C "$OTHER" rev-parse HEAD)
  ( run_script "$RT_D2" main; echo "rc=$?" > "$WORK/d-new-a-$i.rc" ) &
  VPID=$!
  ( run_script "$RT_D2" main >/dev/null 2>&1; echo "rc=$?" > "$WORK/d-new-b-$i.rc" ) &
  IPID=$!
  wait "$VPID"
  wait "$IPID"
  VRC=$(sed -n 's/^rc=//p' "$WORK/d-new-a-$i.rc")
  IRC=$(sed -n 's/^rc=//p' "$WORK/d-new-b-$i.rc")
  AFTER=$(git -C "$RT_D2" rev-parse HEAD)
  if { [ "$VRC" = "0" ] || [ "$IRC" = "0" ]; } && [ "$AFTER" != "$ORIGIN_TIP" ]; then
    NEW_PATTERN_BAD=1
    NEW_PATTERN_MSG="iter $i: a caller reported success (vrc=$VRC irc=$IRC) but HEAD ($AFTER) != origin tip ($ORIGIN_TIP) — SILENT WRONG STATE"
    break
  fi
  for _rc in "$VRC" "$IRC"; do
    if [ "$_rc" != "0" ] && [ "$_rc" != "75" ]; then
      # A real (non-transient) failure under a race that origin-behind alone
      # would never cause — the untracked-file/diverged shapes (B) are
      # covered separately; here origin only ever moves forward and RT_D2
      # starts clean, and both racers are mutex-cooperating by construction.
      NEW_PATTERN_BAD=1
      NEW_PATTERN_MSG="iter $i: unexpected rc=$_rc (not 0, not 75) — vrc=$VRC irc=$IRC"
      break 2
    fi
  done
done
if [ "$NEW_PATTERN_BAD" -eq 0 ]; then
  ok
else
  bad "D2: two cooperating git-deploy-pull.sh callers misbehaved racing each other (the actual post-fix topology): $NEW_PATTERN_MSG"
fi

# ── E. mutex busy -> exit 75, no mutation, distinct from a real failure ───────
RT_E="$WORK/rt-mutex-busy"; seed_runtime "$RT_E"
export GIT_LOCK_RIG_ROOTS="$RT_E"
export GIT_REPO_MUTEX_BASE="$WORK/mutexes-e"
GLH_PATH="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}/scripts/git-lock-hygiene.sh"
if [ -r "$GLH_PATH" ]; then
  ( GIT_LOCK_HYGIENE_LIB=1; . "$GLH_PATH"; git_mutex_acquire "$RT_E" && sleep 3 ) &
  HOLDER_PID=$!
  sleep 0.3   # let the holder actually take the lock before we race it
  BEFORE=$(git -C "$RT_E" rev-parse HEAD)
  GIT_DEPLOY_PULL_MUTEX_WAIT_SEC=1 GIT_DEPLOY_PULL_MUTEX_POLL_SEC=0.1 \
    GC_CITY_PATH="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}" \
    run_script "$RT_E"; RC=$?
  AFTER=$(git -C "$RT_E" rev-parse HEAD)
  wait "$HOLDER_PID" 2>/dev/null
  if [ "$RC" -eq 75 ] && [ "$AFTER" = "$BEFORE" ]; then
    ok
  else
    bad "E mutex-busy: expected exit 75 with HEAD unchanged while lock is held; got rc=$RC head=$AFTER (was $BEFORE). Output: $(cat "$WORK/last.txt")"
  fi
else
  echo "SKIP E: git-lock-hygiene.sh not found at $GLH_PATH (unlocked-fallback environment) — mutex-busy path not exercisable here"
fi
unset GIT_LOCK_RIG_ROOTS GIT_REPO_MUTEX_BASE

# ── F. regression guard: GIT_LOCK_RIG_ROOTS must be pre-set before sourcing ───
# (latency trap found writing this script — see git-deploy-pull.sh header)
grep -qE 'GIT_LOCK_RIG_ROOTS="\$\{GIT_LOCK_RIG_ROOTS:-' "$SCRIPT" \
  && ok || bad "F1: git-deploy-pull.sh no longer pre-sets GIT_LOCK_RIG_ROOTS before sourcing git-lock-hygiene.sh — this reintroduces a live 'gc rig list' call on every invocation (catastrophic at a 60s cadence)"

# Behavioral proof, not just structural: an invocation must stay fast even
# though git-lock-hygiene.sh IS sourced. A nonexistent repo makes the git
# commands fail instantly, so any slowness here is sourcing overhead, not git
# I/O. Generous 5s ceiling (rig-discovery observed taking several seconds to
# tens of seconds under load) — comfortably distinguishes "fixed" (<1s in
# practice) from "regressed" without being a flaky timing test.
_F2_START=$(date +%s)
bash "$SCRIPT" "$WORK/does-not-exist-$RANDOM" main >/dev/null 2>&1
_F2_ELAPSED=$(( $(date +%s) - _F2_START ))
[ "$_F2_ELAPSED" -lt 5 ] && ok \
  || bad "F2: git-deploy-pull.sh took ${_F2_ELAPSED}s on a trivial failing invocation (>=5s) — sourcing git-lock-hygiene.sh is likely doing live rig discovery again"

echo "git-deploy-pull selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
