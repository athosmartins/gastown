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
# G/H (ga-zhwi4l): the fetch used to be unscoped (`git fetch origin`, no
# refspec), so it raced ANY concurrent ref update on the repo, not just
# updates to $BRANCH — in production, worker `crew/wa-worker/*` pushes share
# this repo's ref store and collided with main's deploy fetch ("cannot lock
# ref 'refs/remotes/origin/crew/wa-worker/wa-r17d3'..."). G1 proves the old
# unscoped pattern really does fail under a real concurrent update of an
# UNRELATED branch; G2 proves the shipped, branch-scoped fetch does not, by
# calling the real script. H proves the narrower residual this fix's own
# backstop covers: a collision on $BRANCH's OWN ref (from some other
# non-cooperating process, e.g. deploy_daemons.sh) still degrades to
# transient (75), never a real failure — same real-concurrent-process
# technique as D, not a mocked git.
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
# Unlike main, other-branch is seeded once and never touched again by anyone
# else — a repeat fetch of an unchanged ref is a same-SHA no-op that may never
# even attempt the ref-lock write, so G's race (below) needs this to generate
# genuine lock contention on that specific ref, the same way advance_origin
# does for D/D2/H's races on main.
advance_other_branch() {
  must git -C "$OTHER" checkout --quiet other-branch
  must git -C "$OTHER" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m "crew work $RANDOM"
  must git -C "$OTHER" push --quiet origin HEAD:other-branch
  must git -C "$OTHER" checkout --quiet main
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

# ── G. crew/*-style ref churn on an UNRELATED branch must not break main's deploy ──
# ga-zhwi4l: an unscoped `git fetch origin` (no refspec) tries to update EVERY
# remote-tracking ref, including ones this deploy never reads — "other-branch"
# here stands in for a worker's `crew/wa-worker/*` branch (worker worktrees
# share this repo's ref store in production). G1 proves the unscoped pattern
# (embedded inline — exactly line 61/86 read before this bead) really can fail
# when a real concurrent process touches ONLY that unrelated ref, never
# touching $BRANCH at all. G2 proves the shipped, branch-scoped fetch (the
# actual git-deploy-pull.sh, post-fix) never does, because it has no reason to
# touch that ref in the first place — so unlike D2, this is a deterministic
# assertion (always rc=0), not a "0 or 75" tolerance.
RT_G="$WORK/rt-crewref-old"; seed_runtime "$RT_G"
OLD_UNSCOPED_FAILED=0
OLD_UNSCOPED_MSG=""
for i in $(seq 1 30); do
  advance_other_branch
  ( git -C "$RT_G" fetch origin --quiet && git -C "$RT_G" merge --ff-only origin/main --quiet ) 2>"$WORK/g-old-$i.err" &
  VPID=$!
  ( git -C "$RT_G" fetch origin other-branch --quiet ) 2>/dev/null &
  IPID=$!
  wait "$VPID"; VRC=$?
  wait "$IPID"
  if [ "$VRC" -ne 0 ] && grep -q 'cannot lock ref' "$WORK/g-old-$i.err"; then
    OLD_UNSCOPED_FAILED=1
    OLD_UNSCOPED_MSG="$(cat "$WORK/g-old-$i.err")"
    break
  fi
done
if [ "$OLD_UNSCOPED_FAILED" -eq 1 ]; then
  ok
else
  bad "G1 (base-fails check): unscoped 'git fetch origin' did NOT hit 'cannot lock ref' even once across 30 iterations racing a concurrent update of an UNRELATED ref — this selftest is not exercising ga-zhwi4l's race; strengthen it before trusting G2 below."
fi

RT_G2="$WORK/rt-crewref-new"; seed_runtime "$RT_G2"
NEW_SCOPED_BAD=0
NEW_SCOPED_MSG=""
for i in $(seq 1 30); do
  advance_origin
  advance_other_branch
  ORIGIN_TIP=$(git -C "$OTHER" rev-parse HEAD)
  ( run_script "$RT_G2" main; echo "rc=$?" > "$WORK/g-new-$i.rc" ) &
  VPID=$!
  ( git -C "$RT_G2" fetch origin other-branch --quiet ) 2>/dev/null &
  IPID=$!
  wait "$VPID"
  wait "$IPID"
  VRC=$(sed -n 's/^rc=//p' "$WORK/g-new-$i.rc")
  AFTER=$(git -C "$RT_G2" rev-parse HEAD)
  if [ "$VRC" != "0" ]; then
    NEW_SCOPED_BAD=1
    NEW_SCOPED_MSG="iter $i: git-deploy-pull.sh returned rc=$VRC (expected always 0) racing a concurrent update of an unrelated branch ref — the branch-scoped fetch should never even contend on that ref"
    break
  fi
  if [ "$AFTER" != "$ORIGIN_TIP" ]; then
    NEW_SCOPED_BAD=1
    NEW_SCOPED_MSG="iter $i: reported success (rc=0) but HEAD ($AFTER) != origin tip ($ORIGIN_TIP) — SILENT WRONG STATE"
    break
  fi
done
if [ "$NEW_SCOPED_BAD" -eq 0 ]; then
  ok
else
  bad "G2: git-deploy-pull.sh (branch-scoped fetch) misbehaved racing a concurrent update of an unrelated branch ref: $NEW_SCOPED_MSG"
fi

# ── H. collision on the deploy branch's OWN ref degrades to transient (75) ────
# ga-zhwi4l part 2: G above eliminates the crew/* collision class entirely,
# but if some OTHER non-cooperating process independently races a fetch of
# the SAME branch (outside this wrapper's mutex — deploy_daemons.sh is the
# real one, out of scope per D2's own comment, but the shape is identical),
# the resulting "cannot lock ref" must be treated like mutex-busy (75), never
# surfaced as a real deploy failure. Real concurrent fetches of the identical
# ref — same mechanism as D, just narrowed to one ref instead of two — not a
# mocked/synthetic git failure.
RT_H="$WORK/rt-ownref-backstop"; seed_runtime "$RT_H"
BACKSTOP_HIT=0
BAD_RC_SEEN=0
BAD_RC_MSG=""
for i in $(seq 1 30); do
  advance_origin
  ORIGIN_TIP=$(git -C "$OTHER" rev-parse HEAD)
  ( run_script "$RT_H" main; echo "rc=$?" > "$WORK/h-wrap-$i.rc" ) &
  WPID=$!
  ( git -C "$RT_H" fetch origin main --quiet ) 2>/dev/null &
  IPID=$!
  wait "$WPID"; wait "$IPID"
  WRC=$(sed -n 's/^rc=//p' "$WORK/h-wrap-$i.rc")
  AFTER=$(git -C "$RT_H" rev-parse HEAD)
  case "$WRC" in
    75) BACKSTOP_HIT=1 ;;
    0) : ;;
    *) BAD_RC_SEEN=1; BAD_RC_MSG="iter $i: unexpected rc=$WRC (not 0, not 75)"; break ;;
  esac
  if [ "$WRC" = "0" ] && [ "$AFTER" != "$ORIGIN_TIP" ]; then
    BAD_RC_SEEN=1; BAD_RC_MSG="iter $i: wrapper reported success (rc=0) but HEAD ($AFTER) != origin tip ($ORIGIN_TIP) — SILENT WRONG STATE"; break
  fi
done
if [ "$BAD_RC_SEEN" -eq 1 ]; then
  bad "H own-ref backstop: $BAD_RC_MSG"
else
  ok
fi
if [ "$BACKSTOP_HIT" -eq 1 ]; then
  ok
else
  bad "H (base-fires check): never observed rc=75 from a concurrent same-ref race across 30 iterations — this selftest is not exercising the backstop path; strengthen it before trusting the H own-ref-unchanged check above."
fi

# ── I. merge-side .git/index.lock collision degrades correctly (ga-4vb24i) ────
# Confirmed live 2026-09-24: a non-cooperating concurrent process (e.g. another
# daemon's `git status`/`git diff` opportunistically refreshing the index) can
# hold .git/index.lock across our merge step even though the mutex above only
# serializes OUR OWN callers. Unlike D/G/H's races (real concurrent git
# processes contending for a REF), here we simulate the external holder by
# creating .git/index.lock directly and holding it for a controlled duration —
# this is exactly the lock git itself takes before writing the index (same
# technique as E's direct git_mutex_acquire hold above), so a merge attempted
# while it exists fails with the identical "Unable to create '.../index.lock':
# File exists" message the bead reports, without depending on racy real-process
# timing to reproduce.
# I1 proves the failure mode is real (base-fails check, same convention as
# D1/G1/H). I2 proves the fixed script retries past a SHORT-lived collision and
# still completes the fast-forward. I3 proves a collision that outlives the
# retry budget degrades to transient (75), never a hard failure, with HEAD
# left untouched.
RT_I1="$WORK/rt-mergelock-base"; seed_runtime "$RT_I1"; advance_origin
must git -C "$RT_I1" fetch origin "+refs/heads/main:refs/remotes/origin/main" --quiet
: > "$RT_I1/.git/index.lock"
MERGE_ERR="$(git -C "$RT_I1" merge --ff-only origin/main --quiet 2>&1)"
MERGE_RC=$?
rm -f "$RT_I1/.git/index.lock"
if [ "$MERGE_RC" -ne 0 ] && printf '%s' "$MERGE_ERR" | grep -q "Unable to create '.*index\.lock': File exists"; then
  ok
else
  bad "I1 (base-fails check): a single-shot 'git merge --ff-only' while .git/index.lock is externally held did NOT fail with the expected index.lock message (rc=$MERGE_RC, err=$MERGE_ERR) — this selftest is not exercising the real ga-4vb24i failure mode; strengthen it before trusting I2/I3 below."
fi

RT_I2="$WORK/rt-mergelock-fast"; seed_runtime "$RT_I2"; advance_origin
ORIGIN_TIP=$(git -C "$OTHER" rev-parse HEAD)
: > "$RT_I2/.git/index.lock"
( sleep 1; rm -f "$RT_I2/.git/index.lock" ) &
HOLDER_PID=$!
GIT_DEPLOY_PULL_MERGE_RETRY_SEC=4 GIT_DEPLOY_PULL_MERGE_POLL_SEC=0.1 run_script "$RT_I2"; RC=$?
wait "$HOLDER_PID" 2>/dev/null
AFTER=$(git -C "$RT_I2" rev-parse HEAD)
if [ "$RC" -eq 0 ] && [ "$AFTER" = "$ORIGIN_TIP" ]; then
  ok
else
  bad "I2 merge-lock-collision-clears: expected exit 0 with HEAD==origin tip once the external index.lock clears within the retry budget; got rc=$RC head=$AFTER (origin $ORIGIN_TIP). Output: $(cat "$WORK/last.txt")"
fi

RT_I3="$WORK/rt-mergelock-exhaust"; seed_runtime "$RT_I3"
BEFORE=$(git -C "$RT_I3" rev-parse HEAD)
advance_origin
: > "$RT_I3/.git/index.lock"
( sleep 2; rm -f "$RT_I3/.git/index.lock" ) &
HOLDER_PID=$!
GIT_DEPLOY_PULL_MERGE_RETRY_SEC=1 GIT_DEPLOY_PULL_MERGE_POLL_SEC=0.1 run_script "$RT_I3"; RC=$?
AFTER=$(git -C "$RT_I3" rev-parse HEAD)
wait "$HOLDER_PID" 2>/dev/null
rm -f "$RT_I3/.git/index.lock" 2>/dev/null
if [ "$RC" -eq 75 ] && [ "$AFTER" = "$BEFORE" ]; then
  ok
else
  bad "I3 merge-lock-collision-exhausted: expected exit 75 with HEAD unchanged when the external index.lock outlasts the retry budget; got rc=$RC head=$AFTER (was $BEFORE). Output: $(cat "$WORK/last.txt")"
fi

echo "git-deploy-pull selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
