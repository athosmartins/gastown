#!/usr/bin/env bash
# gate-durable-landing-reconcile.selftest.sh — prove the ga-rstw5 fix in isolation,
# with NO live Dolt/gc/launchd and NO network.
#
# Bug ga-rstw5: container rigs (wa, property_scrapers, gastown, lexbh) have a bare
# .repo.git whose OWN refs/heads/main a `git push` to origin never advances. When
# that bare ref DRIFTS or FORKS from the canonical github origin/main (e.g. WA's
# bare main was force-set on 2026-06-04 to an orphan gitignore-only 'preserve'
# commit 9c8c8a20 during the gt-fc02b7 decommission), the dispatcher's
# durable-landing step would:
#   PASS all 3 reviewers → FF-merge → push to origin/main (the merge DOES land) →
#   try to advance the BARE ref, see it is not an ancestor of the merge, and REFUSE
#   with 'refusing non-FF ref move' → flip the all-PASS verdict to
#   failed_durable_not_ff. The branch then re-dispatches (now on origin/main it
#   supersedes), so every container-rig merge burned 2 gate cycles + mailed crew a
#   false FAIL.
#
# Fix: the bare ref is a SECONDARY MIRROR that must track origin/main (the durable
# target the merge already pushed to). reconcile_main_action (pure) decides the ref
# move; reconcile_bare_main_to_origin (git plumbing) applies it — FF when behind,
# reset-to-origin (with a forensic backup ref) when FORKED. Both wire into:
#   - do_merge_ff durable-landing (per-merge), and
#   - Step 0a-3 startup sweep (every container rig, every sweep).
#
# This harness SOURCES the dispatcher in lib-only mode for the REAL functions (one
# source of truth, no copy-drift), unit-tests every pure branch, runs a real-git
# integration test for the plumbing (noop / FF / forked), then DRIFT-GUARDS the
# live wiring. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL functions from the dispatcher (lib-only = no live sweep) ──────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type reconcile_main_action        >/dev/null 2>&1 || { echo "FATAL: reconcile_main_action not defined by dispatcher"; exit 1; }
type reconcile_bare_main_to_origin >/dev/null 2>&1 || { echo "FATAL: reconcile_bare_main_to_origin not defined by dispatcher"; exit 1; }

# ── 1. reconcile_main_action — pure decision, every branch ─────────────────────
# Signature: reconcile_main_action <local_sha> <origin_sha> <local_anc_origin 0|1> <origin_anc_local 0|1>
echo "── 1. reconcile_main_action (pure ref-move decision) ──"
eq "in-sync (equal sha) → noop"                 "$(reconcile_main_action AAA AAA 1 1)" "noop"
eq "bare behind origin (ancestor) → ff"         "$(reconcile_main_action AAA BBB 1 0)" "ff"
eq "bare absent → ff (first-time set)"          "$(reconcile_main_action '' BBB 0 0)"  "ff"
eq "FORKED (neither ancestor) → reconcile"      "$(reconcile_main_action XXX BBB 0 0)" "reconcile"
eq "bare AHEAD of origin → noop (never discard)" "$(reconcile_main_action CCC BBB 0 1)" "noop"
eq "origin unresolvable → noop (safety)"        "$(reconcile_main_action AAA '' 0 0)"  "noop"
# Equal-sha short-circuits before ancestry flags are even consulted.
eq "equal sha beats stale ancestry flags → noop" "$(reconcile_main_action AAA AAA 0 0)" "noop"

# ── 2. reconcile_bare_main_to_origin — real-git integration (no network) ───────
echo "── 2. reconcile_bare_main_to_origin (real bare repo, 3 scenarios) ──"

export GIT_AUTHOR_NAME=selftest  GIT_AUTHOR_EMAIL=selftest@local
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local

T="$(mktemp -d 2>/dev/null || mktemp -d -t gartstw5)"
cleanup() { rm -rf "$T" 2>/dev/null || true; }
trap cleanup EXIT

UP="$T/up"                  # upstream working repo = stands in for github origin
BARE="$T/bare.git"         # the rig's bare .repo.git mirror

# Upstream: one commit C1 on main.
git init -q -b main "$UP"
( cd "$UP" && echo a > a.txt && git add a.txt && git commit -q -m C1 )
C1=$(git -C "$UP" rev-parse HEAD)

# Bare mirror with origin → upstream; bare main initialised to C1 (in sync).
git init -q --bare "$BARE"
git --git-dir="$BARE" remote add origin "$UP"
git --git-dir="$BARE" fetch origin --quiet
git --git-dir="$BARE" update-ref refs/heads/main "$C1"

# 2a. IN-SYNC → noop, ref untouched.
OUT=$(reconcile_bare_main_to_origin "$BARE" main); RC=$?
eq "in-sync: rc=0"                 "$RC" "0"
eq "in-sync: action is noop"       "${OUT%%:*}" "noop"
eq "in-sync: bare main still C1"   "$(git --git-dir="$BARE" rev-parse refs/heads/main)" "$C1"

# 2b. ORIGIN ADVANCES (C2) → FF: bare main fast-forwards to origin.
( cd "$UP" && echo b > b.txt && git add b.txt && git commit -q -m C2 )
C2=$(git -C "$UP" rev-parse HEAD)
OUT=$(reconcile_bare_main_to_origin "$BARE" main); RC=$?
eq "ff: rc=0"                      "$RC" "0"
eq "ff: action is ff"              "${OUT%%:*}" "ff"
eq "ff: bare main advanced to C2"  "$(git --git-dir="$BARE" rev-parse refs/heads/main)" "$C2"

# 2c. BARE FORKS (orphan commit not on origin) → reconcile: reset to origin,
#     forked tip preserved under a backup ref. This is the exact ga-rstw5 shape
#     (WA's orphan 'preserve' 9c8c8a20 vs the live origin line).
FORK="$T/fork"
git init -q -b main "$FORK"
( cd "$FORK" && echo orphan > o.txt && git add o.txt && git commit -q -m ORPHAN )
CORPHAN=$(git -C "$FORK" rev-parse HEAD)
git --git-dir="$BARE" fetch "$FORK" "+refs/heads/main:refs/heads/main" --quiet
eq "fork setup: bare main is the orphan" "$(git --git-dir="$BARE" rev-parse refs/heads/main)" "$CORPHAN"
OUT=$(reconcile_bare_main_to_origin "$BARE" main); RC=$?
eq "forked: rc=0"                  "$RC" "0"
eq "forked: action is reconcile"   "${OUT%%:*}" "reconcile"
eq "forked: bare main reset to origin C2" "$(git --git-dir="$BARE" rev-parse refs/heads/main)" "$C2"
BK="refs/heads/_backup-forked-main-${CORPHAN}"
if git --git-dir="$BARE" rev-parse --verify -q "$BK" >/dev/null 2>&1; then
  eq "forked: backup ref preserves orphan tip" "$(git --git-dir="$BARE" rev-parse "$BK")" "$CORPHAN"
else
  bad "forked: backup ref $BK missing"
fi

# 2d. RE-RUN after reconcile is a clean noop (idempotent).
OUT=$(reconcile_bare_main_to_origin "$BARE" main); RC=$?
eq "idempotent re-run: rc=0"       "$RC" "0"
eq "idempotent re-run: noop"       "${OUT%%:*}" "noop"

# 2e. Bad git-dir → fetch-failed, rc=1 (caller degrades to error, never closes).
OUT=$(reconcile_bare_main_to_origin "$T/does-not-exist.git" main) || RC=$?
eq "missing repo: action fetch-failed" "$OUT" "fetch-failed"

# ── 3. Drift-guard: the live dispatcher wires the fix ──────────────────────────
echo "── 3. drift-guard: dispatcher wiring ──"
grep -q 'GATE_DISPATCHER_LIB_ONLY'              "$DISPATCHER" && ok "dispatcher sourceable in lib-only mode"        || bad "dispatcher missing lib-only hook"
grep -q 'reconcile_main_action()'               "$DISPATCHER" && ok "dispatcher defines reconcile_main_action"      || bad "dispatcher missing reconcile_main_action def"
grep -q 'reconcile_bare_main_to_origin()'       "$DISPATCHER" && ok "dispatcher defines reconcile_bare_main_to_origin" || bad "dispatcher missing reconcile_bare_main_to_origin def"
# The false-FAIL guard must be GONE — its removal is the whole point (ga-rstw5).
# Match the CODE assignment, not comment mentions (the comments document the fix).
! grep -q 'MERGE_RESULT="failed_durable_not_ff"' "$DISPATCHER" && ok "old failed_durable_not_ff assignment removed" || bad "MERGE_RESULT=failed_durable_not_ff still set — bug not fixed"
! grep -q 'refusing non-FF ref move'            "$DISPATCHER" && ok "old 'refusing non-FF ref move' branch removed" || bad "non-FF-refusal branch still present"
# Durable-landing (do_merge_ff) reconciles to origin instead.
grep -q 'reconcile_bare_main_to_origin "\$GIT_DIR_PATH" "\$DEFAULT_BRANCH"' "$DISPATCHER" \
  && ok "durable-landing calls reconcile_bare_main_to_origin" || bad "durable-landing not calling reconcile"
# Startup sweep across all container rigs.
grep -q 'Step 0a-3'                             "$DISPATCHER" && ok "dispatcher implements Step 0a-3 startup sweep"  || bad "missing Step 0a-3 sweep"
grep -q 'Startup reconcile:'                    "$DISPATCHER" && ok "startup sweep logs reconcile actions"          || bad "startup sweep missing log line"
grep -q 'reconcile_bare_main_to_origin "\$RC_PATH/.repo.git" "\$RC_BRANCH"' "$DISPATCHER" \
  && ok "startup sweep reconciles each container rig's bare repo" || bad "startup sweep not calling reconcile per rig"
# Startup sweep must restrict to container rigs (.repo.git) only.
grep -q '\[ -d "\$RC_PATH/.repo.git" \] || continue' "$DISPATCHER" \
  && ok "startup sweep skips self-repo rigs (.repo.git guard)" || bad "startup sweep missing .repo.git container guard"
# set -e safety: the durable-landing reconcile call captures rc via `|| ...`
# (the documented ga set -e/pipefail crash class — unguarded VAR=$(cmd) aborts).
grep -q 'DURABLE_RECON_OUT=$(reconcile_bare_main_to_origin .*) || DURABLE_RECON_RC=$?' "$DISPATCHER" \
  && ok "durable-landing reconcile is set -e safe (|| rc capture)" || bad "durable-landing reconcile not set -e guarded"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
