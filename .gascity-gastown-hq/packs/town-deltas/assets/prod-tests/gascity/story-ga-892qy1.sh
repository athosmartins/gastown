#!/usr/bin/env bash
# prod-tests/gascity/story-ga-892qy1.sh — prod test for ga-892qy1: git-lock-hygiene no longer
# REMOVES the state of an in-progress merge / cherry-pick / revert / rebase; it reports it.
#
# Why: scripts/git-lock-hygiene.sh used to delete MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD,
# rebase-merge/ and rebase-apply/ once they were >300 s old with no live git process. "No git
# process" cannot tell a CRASHED operation from one PAUSED FOR A HUMAN (a conflict waiting to be
# resolved, an editor open, a break): deleting the state of the second loses work silently
# (no MERGE_HEAD = the next commit has one parent). Locks (index.lock, ...) are unchanged:
# there, age + no process IS proof. State items are now logged (stale_state_found) and notified
# once, and are removed only under the explicit GIT_LOCK_STATE_REMOVE=1 opt-in (ga-hl3xlw; the
# selftest covers the opt-in, this test covers the default path the janitor actually runs).
#
# Called by run.sh after deploy (STORY_ID=ga-892qy1). Exits 0 on pass.
#
# What this proves, against the DEPLOYED script (not this branch's copy):
#   1. structural: the report path is present and the state items are gone from the removal lists;
#   2. behavioral, END TO END through the real sweep entrypoint under /bin/bash (what launchd
#      runs — bash 3.2): in an isolated fixture repo + scratch city, a stale index.lock is removed
#      while a stale MERGE_HEAD and rebase-merge/ beside it SURVIVE and are reported;
#   3. the deployed script's own hermetic selftest wrapper passes;
#   4. the live janitor is actually loaded (merged != running).
# It never touches a production repo, the live log, the live notify topic, or the live state dir.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"
GLH="$SCRIPTS/git-lock-hygiene.sh"
GLH_SELFTEST="$SCRIPTS/git-lock-hygiene.selftest.sh"

log()  { echo "[prod-test:gascity ga-892qy1] $*"; }
fail() { echo "[prod-test:gascity ga-892qy1] FAIL: $*" >&2; exit 1; }

[[ -f "$GLH" ]] || fail "deployed git-lock-hygiene.sh missing: $GLH"
[[ -x "$GLH_SELFTEST" || -f "$GLH_SELFTEST" ]] || fail "deployed git-lock-hygiene.selftest.sh missing: $GLH_SELFTEST"
log "Deployed script found: $GLH"

# ── 1. Structural ─────────────────────────────────────────────────────────────
grep -q '^_report_stale_state()' "$GLH" \
  || fail "_report_stale_state() missing from deployed script — detect-only fix not deployed"
grep -q '"event\\":\\"stale_state_found\\"' "$GLH" \
  || fail "stale_state_found event missing from deployed script"
# The old removal lists named these as "<file>:<label>" / "<dir>:<label>" entries. None may be back.
for old in 'MERGE_HEAD:in-progress merge' 'CHERRY_PICK_HEAD:in-progress cherry-pick' \
           'REVERT_HEAD:in-progress revert' 'rebase-merge:in-progress rebase' 'rebase-apply:in-progress rebase'; do
  if grep -qF "\"$old" "$GLH"; then
    fail "deployed script still lists '$old' as a removal candidate — state items are being removed again"
  fi
done
log "report path present; state items are not in the removal lists ✓"

# ── 2. Behavioral, end to end, isolated ───────────────────────────────────────
# The fixture path is kept free of "git" on purpose. Before ga-hl3xlw the liveness check matched the
# repo path as a SUBSTRING of the ps line, so a path with "git" in it made the check match its own
# grep (a permanent false "live process", nothing ever judged stale). The check is exact now
# (per process, by git dir / cwd), so this is no longer required — it only keeps the fixture
# independent of that history. No real rig root has "git" in its path.
BASE=""
for _ in 1 2 3 4 5 6 7 8; do
  BASE="$(mktemp -d /tmp/glh-prod.XXXXXX)" || fail "mktemp failed"
  case "$BASE" in *git*) rmdir "$BASE"; BASE="" ;; *) break ;; esac
done
[[ -n "$BASE" ]] || fail "could not create a fixture dir without 'git' in its path"
cleanup() { [[ -n "${BASE:-}" && "$BASE" == /tmp/glh-prod.* ]] && /bin/rm -rf "$BASE"; }
trap cleanup EXIT

REPO="$BASE/repo"
mkdir -p "$REPO" "$BASE/city/.gc/logs"
( cd "$REPO" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) \
  || fail "could not create the fixture repo"
touch -t 200001010000 "$REPO/.git/index.lock" "$REPO/.git/MERGE_HEAD"
mkdir -p "$REPO/.git/rebase-merge"; touch -t 200001010000 "$REPO/.git/rebase-merge"

FAKE_NOTIFY="$BASE/fake-notify"
cat > "$FAKE_NOTIFY" <<'FAKE'
#!/bin/sh
echo "$*" >> "$NOTIFY_CALLS"
echo "Logged for digest (prod-test fake): $*"
exit 0
FAKE
chmod +x "$FAKE_NOTIFY"
NOTIFY_CALLS="$BASE/notify.calls"; : > "$NOTIFY_CALLS"
SWEEP_LOG="$BASE/sweep.jsonl"; : > "$SWEEP_LOG"

# /bin/bash on purpose: it is what com.gascity.git-lock-hygiene's plist runs (bash 3.2 on macOS).
# env -u GIT_LOCK_PROCESS_CHECK_FN: the real liveness check, not a stub.
env -u GIT_LOCK_PROCESS_CHECK_FN -u GIT_LOCK_DRY_RUN -u GIT_LOCK_ENABLED -u GIT_LOCK_STALE_AGE_SEC \
    GC_CITY_PATH="$BASE/city" GIT_LOCK_RIG_ROOTS="$REPO" GIT_LOCK_LOG="$SWEEP_LOG" \
    NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_CALLS="$NOTIFY_CALLS" GIT_LOCK_STATE_DIR="$BASE/state-notified" \
    /bin/bash "$GLH" >/dev/null 2>"$BASE/sweep.err"
rc=$?
[[ $rc -eq 0 ]] || fail "deployed sweep exited $rc under /bin/bash — stderr: $(head -c 400 "$BASE/sweep.err")"

[[ ! -e "$REPO/.git/index.lock" ]] \
  || fail "stale index.lock was NOT removed — the lock half of the janitor regressed"
[[ -f "$REPO/.git/MERGE_HEAD" ]] \
  || fail "stale MERGE_HEAD was REMOVED — a merge paused for a human would lose its second parent"
[[ -d "$REPO/.git/rebase-merge" ]] \
  || fail "stale rebase-merge/ was REMOVED — a rebase paused for a human would be lost"
n_state=$(grep -c '"event":"stale_state_found"' "$SWEEP_LOG" || true)
[[ "${n_state:-0}" == "2" ]] \
  || fail "expected 2 stale_state_found events (MERGE_HEAD, rebase-merge), got ${n_state:-0}: $(cut -c1-200 "$SWEEP_LOG")"
grep -q '"event":"sweep".*"removed":1,' "$SWEEP_LOG" \
  || fail "sweep summary should say removed=1 (the lock only): $(grep '"event":"sweep"' "$SWEEP_LOG")"
n_notify=$(grep -c . "$NOTIFY_CALLS" || true)
[[ "${n_notify:-0}" == "3" ]] \
  || fail "expected 3 notifications (2 state items + 1 removal summary), got ${n_notify:-0}: $(cat "$NOTIFY_CALLS")"
log "end-to-end under /bin/bash: lock removed, MERGE_HEAD + rebase-merge/ kept, 2 stale_state_found, removed=1, 3 notifies ✓"

# ── 3. The deployed script's own hermetic selftest ────────────────────────────
ST_OUT="$BASE/selftest.out"
bash "$GLH_SELFTEST" > "$ST_OUT" 2>&1
st_rc=$?
if [[ $st_rc -ne 0 ]]; then
  grep 'FAIL ' "$ST_OUT" | head -10 >&2
  fail "deployed git-lock-hygiene selftest exited $st_rc"
fi
grep -Eq '^PASS=[0-9]+  FAIL=0$' "$ST_OUT" \
  || fail "deployed selftest did not report FAIL=0: $(grep -E '^PASS=' "$ST_OUT")"
log "deployed selftest: $(grep -E '^PASS=' "$ST_OUT") ✓"

# ── 4. Merged != running: the live janitor job is loaded ──────────────────────
launchctl list 2>/dev/null | grep -q 'com\.gascity\.git-lock-hygiene' \
  || fail "com.gascity.git-lock-hygiene is not loaded in launchd — the janitor is not running at all"
log "launchd job com.gascity.git-lock-hygiene is loaded ✓"

log "PASS — stale merge/cherry-pick/revert/rebase state is reported, not removed by default; stale locks are still removed"
exit 0
