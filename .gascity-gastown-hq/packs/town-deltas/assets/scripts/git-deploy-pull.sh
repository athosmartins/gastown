#!/usr/bin/env bash
# git-deploy-pull.sh — serialized, FETCH_HEAD-race-free "pull" for automated
# deploy call sites (ga-nh1muq).
#
# WHY: `git pull --ff-only` decides what to merge by reading .git/FETCH_HEAD —
# a plain file ANY concurrent `git fetch`/`git pull` against the SAME repo can
# overwrite between our own fetch step and our own merge step. whatsapp_automation
# has 2+ independent, uncoordinated periodic fetchers against the same working
# tree (com.whatsapp.deploy-sync every 60s, story-delivery.sh's deploy_cmd on
# every delivery) — confirmed live (ga-nh1muq): two story-delivery pull attempts
# failed 27 min apart with two different FETCH_HEAD symptoms ("not something we
# can merge in .git/FETCH_HEAD", "Cannot fast-forward to multiple branches").
# Reproduced deterministically in this bead's selftest via a REAL concurrent
# race (not a synthetic FETCH_HEAD poison) — see git-deploy-pull.selftest.sh.
#
# FIX, two parts, BOTH needed (measured — see selftest race harness):
#   1. Never read FETCH_HEAD: fetch, then merge the durable
#      refs/remotes/origin/<branch> ref directly (same pattern already proven
#      for the lexbh/gascity delivery-runbooks.toml entries). This alone
#      eliminates the "silently merges the wrong ref" class entirely — but
#      under a real race it TRADES that for a MORE FREQUENT "cannot lock ref"
#      transient failure (measured: 77/150 runs under adversarial concurrent
#      fetches against the same ref).
#   2. Serialize with the city's own per-repo git mutex
#      (scripts/git-lock-hygiene.sh, imp18 — already proven in production by
#      quality-gate-dispatcher.sh's auto-rebase) so concurrent callers never
#      even interleave their git operations. With the mutex, the same
#      adversarial race harness measured 0 transient failures across 40 runs.
#
# GOTCHA (found writing this): sourcing git-lock-hygiene.sh as a lib WITHOUT
# pre-setting GIT_LOCK_RIG_ROOTS triggers a live `gc rig list` call on every
# single invocation (its Part-1 janitor root-discovery) — fine for a caller
# that sources it once, catastrophic for a wrapper invoked every 60s. We only
# need Part 2 (the mutex functions), so GIT_LOCK_RIG_ROOTS is pre-set below to
# skip that discovery unconditionally.
#
# Usage: git-deploy-pull.sh <repo_dir> [<branch>]   (branch defaults to main)
# Exit 0  = fast-forwarded (or already up to date).
# Exit 75 = could not acquire the per-repo deploy mutex within the wait budget
#           (another deploy is genuinely in flight) — a TRANSIENT,
#           not-our-fault non-completion. Callers should treat this exactly
#           like "try again next cycle," never as a real deploy failure
#           (75 = EX_TEMPFAIL in sysexits.h — chosen for that reason).
# Other nonzero = a real git failure (diverged history, network, missing
#           branch, ...) — a normal, actionable deploy failure.
set -uo pipefail

REPO="${1:?usage: git-deploy-pull.sh <repo_dir> [<branch>]}"
BRANCH="${2:-main}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GLH="${CITY}/scripts/git-lock-hygiene.sh"
MUTEX_WAIT_SEC="${GIT_DEPLOY_PULL_MUTEX_WAIT_SEC:-5}"
MUTEX_POLL_SEC="${GIT_DEPLOY_PULL_MUTEX_POLL_SEC:-0.2}"

# git-lock-hygiene.sh missing/unreadable: degrade to unlocked fetch+merge
# rather than hard-failing the deploy. Still strictly safer than the old
# plain `git pull --ff-only` (no FETCH_HEAD dependency at all), just without
# the extra serialization against the "cannot lock ref" class.
if [ ! -r "$GLH" ]; then
  echo "git-deploy-pull.sh: git-lock-hygiene.sh not found/readable at $GLH — falling back to unlocked fetch+merge" >&2
  git -C "$REPO" fetch origin --quiet && git -C "$REPO" merge --ff-only "origin/$BRANCH" --quiet
  exit $?
fi

GIT_LOCK_HYGIENE_LIB=1
GIT_LOCK_RIG_ROOTS="${GIT_LOCK_RIG_ROOTS:-$REPO}"
# shellcheck disable=SC1090
. "$GLH"

_acquired=0
_deadline=$(( $(date +%s) + MUTEX_WAIT_SEC ))
while :; do
  if git_mutex_acquire "$REPO"; then
    _acquired=1
    break
  fi
  [ "$(date +%s)" -ge "$_deadline" ] && break
  sleep "$MUTEX_POLL_SEC"
done

if [ "$_acquired" -ne 1 ]; then
  echo "git-deploy-pull.sh: could not acquire deploy mutex for $REPO within ${MUTEX_WAIT_SEC}s — another deploy is in flight, try again next cycle" >&2
  exit 75
fi

git -C "$REPO" fetch origin --quiet
RC=$?
if [ "$RC" -eq 0 ]; then
  git -C "$REPO" merge --ff-only "origin/$BRANCH" --quiet
  RC=$?
fi
git_mutex_release "$REPO"
exit "$RC"
