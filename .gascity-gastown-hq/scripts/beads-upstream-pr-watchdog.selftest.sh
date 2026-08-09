#!/usr/bin/env bash
# beads-upstream-pr-watchdog.selftest.sh — hermetic proof for ga-574zr: our
# own upstream PRs against gastownhall/beads must be watched, and the alert
# must fire exactly on a state TRANSITION — never on every sweep, never
# missing the transition it exists to catch.
#
# No live gh/bd/gc/launchd: `gh`, `bd`, and `gc` are stubbed on PATH to record
# their calls instead of doing anything. All BUPW_* path overrides (state
# file, log file) are set BEFORE sourcing the watchdog in lib mode
# (BEADS_UPSTREAM_PR_WATCHDOG_LIB=1) — the watchdog binds STATE=$BUPW_STATE
# etc. as a top-level assignment AT SOURCE TIME, not inside a function, so
# setting the override after sourcing would silently write to the REAL
# production state path instead of this test's tmpdir.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SELF_DIR/beads-upstream-pr-watchdog.sh"
PLIST="$SELF_DIR/../packs/town-deltas/assets/beads-upstream-pr-watchdog.plist"
# The plist must reference where the script lives once deployed to the real
# HQ checkout — NOT wherever this selftest happens to be running from (a
# worktree path here would never match, before or after merge).
CANONICAL_SCRIPT="/Users/athos/gt/.gascity-gastown-hq/scripts/beads-upstream-pr-watchdog.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Hermetic stubs + all path overrides, set up BEFORE sourcing ────────────
export GH_CALLS_LOG="$TMP/gh-calls.log"
export BD_CALLS_LOG="$TMP/bd-calls.log"
export GC_CALLS_LOG="$TMP/gc-calls.log"
: > "$GH_CALLS_LOG"; : > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"

# GH_FIXTURE_STATE controls what the stubbed `gh pr list` returns this sweep —
# swapped between invocations below to simulate PR #5439 going OPEN -> MERGED.
export GH_FIXTURE_STATE="$TMP/gh-fixture-state"
echo "OPEN" > "$GH_FIXTURE_STATE"

cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$GH_CALLS_LOG"
state="$(cat "$GH_FIXTURE_STATE" 2>/dev/null || echo OPEN)"
merged_at="null"
[ "$state" = "MERGED" ] && merged_at='"2026-08-09T20:00:00Z"'
cat <<JSON
[
  {"number": 5439, "state": "$state", "mergedAt": $merged_at, "url": "https://github.com/gastownhall/beads/pull/5439", "title": "fix(bd): canonicalize actor==assignee comparisons"},
  {"number": 5479, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/5479", "title": "fix(bd): canonicalize remaining actor==assignee comparisons"},
  {"number": 5470, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/5470", "title": "fix: widen DefaultLeaseTTL"}
]
JSON
STUB
chmod +x "$TMP/gh"

cat > "$TMP/bd" <<'STUB'
#!/usr/bin/env bash
body="$(cat)"
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' STDIN=[%s]\n' "$body"; } >> "$BD_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/bd"

cat > "$TMP/gc" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$GC_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/gc"

export PATH="$TMP:$PATH"
export BUPW_STATE="$TMP/state.json"
export BUPW_LOG="$TMP/watchdog.log"
export BUPW_LOCK_ENABLED=0
export BD_BIN="bd"
export GC_BIN="gc"

export BEADS_UPSTREAM_PR_WATCHDOG_LIB=1
# shellcheck disable=SC1090
source "$WATCHDOG"

# ── Part 1: classify_pr_transition — pure logic, no I/O ────────────────────
echo "== classify_pr_transition =="

eq "unseen, still open"             "$(classify_pr_transition UNKNOWN OPEN)"   "first-seen"
eq "unseen, already merged"         "$(classify_pr_transition UNKNOWN MERGED)" "merged"
eq "unseen, already closed"         "$(classify_pr_transition UNKNOWN CLOSED)" "closed-no-merge"
eq "open, unchanged"                "$(classify_pr_transition OPEN OPEN)"      "no-change"
eq "open -> merged"                 "$(classify_pr_transition OPEN MERGED)"    "merged"
eq "open -> closed"                 "$(classify_pr_transition OPEN CLOSED)"    "closed-no-merge"
eq "closed -> reopened"             "$(classify_pr_transition CLOSED OPEN)"    "reopened"
eq "merged, unchanged (no re-fire)" "$(classify_pr_transition MERGED MERGED)"  "no-change"

# ── Part 2: run_sweep end-to-end against hermetic stubs ─────────────────────
echo ""
echo "== run_sweep (stubbed gh/bd/gc) =="

# Sweep 1: PR #5439 OPEN, no prior state -> baseline only, NO alert.
run_sweep
eq "sweep1: no bd comment calls (baseline, not a transition)" "$(wc -l < "$BD_CALLS_LOG" | tr -d ' ')" "0"
eq "sweep1: no gc mail calls (baseline, not a transition)"    "$(wc -l < "$GC_CALLS_LOG" | tr -d ' ')" "0"
eq "sweep1: state file records OPEN for 5439" "$(jq -r '.["5439"].state' "$BUPW_STATE" 2>&1)" "OPEN"

# Sweep 2: PR #5439 flips to MERGED -> must alert exactly once.
echo "MERGED" > "$GH_FIXTURE_STATE"
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "sweep2: exactly one bd comment call on merge" "$(wc -l < "$BD_CALLS_LOG" | tr -d ' ')" "1"
eq "sweep2: exactly one gc mail call on merge"    "$(wc -l < "$GC_CALLS_LOG" | tr -d ' ')" "1"
grep -q '\[-C\] \[/Users/athos/gt/whatsapp_automation\] \[comment\] \[wa-msxg5\]' "$BD_CALLS_LOG" \
  && ok "sweep2: bd comment targeted wa-msxg5 in the WA rig city" \
  || bad "sweep2: bd comment did not target wa-msxg5/WA-city as expected: $(cat "$BD_CALLS_LOG")"
grep -q '\[mail\] \[send\] \[mayor\]' "$GC_CALLS_LOG" \
  && ok "sweep2: gc mail addressed to mayor" \
  || bad "sweep2: gc mail not addressed to mayor: $(cat "$GC_CALLS_LOG")"
eq "sweep2: state file now records MERGED for 5439" "$(jq -r '.["5439"].state' "$BUPW_STATE" 2>&1)" "MERGED"

# Sweep 3: still MERGED -> must NOT re-alert (the whole point of transition-only alerting).
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "sweep3: no repeat bd comment on unchanged MERGED state" "$(wc -l < "$BD_CALLS_LOG" | tr -d ' ')" "0"
eq "sweep3: no repeat gc mail on unchanged MERGED state"    "$(wc -l < "$GC_CALLS_LOG" | tr -d ' ')" "0"

# ── Part 3: single-instance lock (ga-y0g5x pattern) ─────────────────────────
echo ""
echo "== single-instance lock =="
export BUPW_LOCK_DIR="$TMP/lock.d"
export BUPW_LOCK_HB="$BUPW_LOCK_DIR/heartbeat"
# Real pid:random format, using THIS process's own pid — it is guaranteed
# alive for the duration of this test, so this exercises the actual `kill -0`
# liveness branch, not the separate fail-closed-on-unparseable-token branch.
export BUPW_LOCK_TOKEN="$$:aaa"

if _acquire_bupw_lock; then ok "first acquire succeeds"; else bad "first acquire should succeed"; fi

BUPW_LOCK_TOKEN="$$:bbb" _acquire_bupw_lock \
  && bad "second acquire while holder is LIVE should fail, but it succeeded" \
  || ok "second acquire correctly blocked while first holder is live (kill -0 \$\$ path, always alive during this test)"

_release_bupw_lock
[ -d "$BUPW_LOCK_DIR" ] && bad "lock dir should be gone after release" || ok "release removes the lock dir"

# Dead-holder reclaim: fabricate a lock held by a PID that cannot be alive.
mkdir "$BUPW_LOCK_DIR"
echo "999999:deadtoken" > "$BUPW_LOCK_HB"
if kill -0 999999 2>/dev/null; then
  echo "  (skip dead-holder-reclaim case: pid 999999 unexpectedly alive on this machine)"
else
  BUPW_LOCK_TOKEN="holder-c" _acquire_bupw_lock \
    && ok "reclaim succeeds when the recorded holder pid is dead" \
    || bad "reclaim should succeed over a dead holder"
fi
rm -rf "$BUPW_LOCK_DIR" "${BUPW_LOCK_DIR}.reaping" 2>/dev/null

# ── Part 4: plist points at the canonical deployed path ─────────────────────
echo ""
echo "== plist wiring =="
if [ -f "$PLIST" ]; then
  if grep -q "$CANONICAL_SCRIPT" "$PLIST"; then
    ok "plist ProgramArguments references the canonical deployed script path"
  else
    bad "plist does not reference $CANONICAL_SCRIPT"
  fi
  grep -q "<key>StartInterval</key>" "$PLIST" \
    && bad "plist uses StartInterval (resets on sleep/reboot, may never fire) instead of StartCalendarInterval" \
    || ok "plist does not use StartInterval for the daily cadence"
  grep -q "<key>StartCalendarInterval</key>" "$PLIST" \
    && ok "plist uses StartCalendarInterval for the daily cadence" \
    || bad "plist is missing StartCalendarInterval"
else
  bad "plist not found at $PLIST"
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
