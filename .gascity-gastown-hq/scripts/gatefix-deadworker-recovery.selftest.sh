#!/usr/bin/env bash
# Selftest for gatefix-deadworker-recovery.sh — proves the pure decision in isolation.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/gatefix-deadworker-recovery.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3] got [$2]"; fi; }

GATEFIX_RECOVERY_LIB_ONLY=1 source "$J" || { echo "FATAL: cannot source lib-only"; exit 1; }
type gatefix_recovery_decide >/dev/null 2>&1 || { echo "FATAL: decide fn missing"; exit 1; }

LIVE="wa-worker-adhoc-LIVE mila-wa oracle-wa"

echo "── gatefix_recovery_decide ──"
# recover ONLY when: needs-fix=1, not in-flight, non-empty worker, worker NOT live
eq "dead worker + needs-fix + not-inflight → RECOVER" "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE")" "recover"
eq "live worker → skip"                               "$(gatefix_recovery_decide 1 0 mila-wa "$LIVE")"             "skip:worker-still-live"
eq "in-flight (active rework) → skip"                 "$(gatefix_recovery_decide 1 1 wa-worker-adhoc-DEAD "$LIVE")" "skip:in-flight-active-rework"
eq "no recorded worker → skip (cannot prove dead)"    "$(gatefix_recovery_decide 1 0 '' "$LIVE")"                  "skip:no-recorded-worker"
eq "not needs-fix → skip"                             "$(gatefix_recovery_decide 0 0 wa-worker-adhoc-DEAD "$LIVE")" "skip:not-needs-fix"
# the live-match is exact-token (a dead worker whose name is a substring of a live one is NOT spared)
eq "substring of a live name is NOT 'live' → recover" "$(gatefix_recovery_decide 1 0 wa-worker "$LIVE")"           "recover"

echo ""
echo "── drift-guard: live wiring present ──"
grep -q 'gc session list --json' "$J" && ok "reads gc session roster" || bad "no roster read"
grep -q 'empty_roster_failsafe' "$J" && ok "FAIL-SAFE on empty roster (never reaps blind)" || bad "no empty-roster failsafe"
grep -q 'worktree remove --force' "$J" && ok "reaps orphan worktree" || bad "no worktree reap"
# NO BRANCH DELETION (ga-0re8j): the glob refs/heads|remotes/.../crew/*/<bead> can only
# ever match the crew's PRIMARY submission branch (git ref globs never cross '/', and the
# gatefix-worker worktree checks out that SAME ref) — never re-add branch deletion here.
grep -q 'branch -D' "$J" && bad "local branch deletion present — DATA-LOSS regression (ga-0re8j)" || ok "no local branch deletion (ga-0re8j)"
grep -q 'push origin --delete' "$J" && bad "remote branch deletion present — DATA-LOSS regression (ga-0re8j)" || ok "no remote branch deletion (ga-0re8j)"

echo ""
echo "── live-path: missing dependency → must notify, not die silently (ga-4zpf) ──"
LIVE_TMP="$(mktemp -d)"
NOTIFY_LOG="$LIVE_TMP/notify.log"
cat > "$LIVE_TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$LIVE_TMP/notify"
env -i PATH=/usr/bin:/bin HOME="$HOME" \
    GATEFIX_RECOVERY_NOTIFY="$LIVE_TMP/notify" \
    GATEFIX_RECOVERY_LOG="$LIVE_TMP/run.log" \
    bash "$J" >/dev/null 2>&1
grep -qi 'gc' "$NOTIFY_LOG" 2>/dev/null && ok "live-path: missing gc dependency → notified (ga-4zpf)" || bad "live-path: missing gc dependency did NOT notify — silent failure (ga-4zpf regression)"
rm -rf "$LIVE_TMP"

echo ""
echo "── mutation guard: live sweep must NOT delete the crew's branch (ga-0re8j) ──"
MUT_TMP="$(mktemp -d)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

MUT_ORIGIN="$MUT_TMP/origin.git"; git init -q --bare "$MUT_ORIGIN"
MUT_GT="$MUT_TMP/gt"; mkdir -p "$MUT_GT/.gascity-gastown-hq"
git init -q -b main "$MUT_GT"
( cd "$MUT_GT"
  git remote add origin "$MUT_ORIGIN"
  echo a > a.txt; git add a.txt; git commit -qm "base"
  git push -q origin main
  # the crew's real submission branch — one commit AHEAD of main (unmerged, live rework)
  git checkout -qb crew/oracle/fx-bead main
  echo b > b.txt; git add b.txt; git commit -qm "fix in progress"
  git push -q origin crew/oracle/fx-bead
  git fetch -q origin
  git checkout -q main
  # an orphan gatefix-worker worktree, checked out to a THROWAWAY branch (never the
  # submission branch itself) — proves worktree reaping still works post-fix
  git branch scratch/fx-bead-wt main
  git worktree add -q "$MUT_GT/crew/worker-fx-bead" scratch/fx-bead-wt
) >/dev/null 2>&1

# fake gc/bd: report the bead as gate:needs-fix, worker dead (absent from the live
# roster), not in-flight — the exact shape ga-0re8j reproduces.
MUT_BIN="$MUT_TMP/bin"; mkdir -p "$MUT_BIN"
cat > "$MUT_BIN/gc" <<'FAKEGC'
#!/usr/bin/env bash
case "$*" in
  *"session list --json"*) echo '{"sessions":[{"session_name":"someone-else-live","state":"active"}]}' ;;
  *"rig list --json"*)     echo '{"rigs":[]}' ;;
  *)                        echo '{}' ;;
esac
FAKEGC
cat > "$MUT_BIN/bd" <<'FAKEBD'
#!/usr/bin/env bash
case "$*" in
  *"list -l gate:needs-fix"*) echo '[{"id":"fx-bead","labels":["gate:needs-fix"],"metadata":{"gc.session_name":"dead-worker-xyz"}}]' ;;
  *"show fx-bead"*)           echo '[{"assignee":"dead-worker-xyz"}]' ;;
  *)                           : ;;
esac
exit 0
FAKEBD
chmod +x "$MUT_BIN/gc" "$MUT_BIN/bd"

PATH="$MUT_BIN:$PATH" \
GATEFIX_RECOVERY_GT="$MUT_GT" \
GATEFIX_RECOVERY_LOG="$MUT_TMP/run.jsonl" \
GATEFIX_RECOVERY_ENABLED=1 \
GATEFIX_RECOVERY_DRY_RUN=0 \
  bash "$J" >/dev/null 2>&1

if git -C "$MUT_GT" rev-parse --verify -q refs/heads/crew/oracle/fx-bead >/dev/null 2>&1; then
  ok "local crew/oracle/fx-bead branch SURVIVES the sweep"
else
  bad "local crew/oracle/fx-bead branch was DELETED by the sweep — DATA-LOSS regression (ga-0re8j)"
fi
if git -C "$MUT_ORIGIN" rev-parse --verify -q refs/heads/crew/oracle/fx-bead >/dev/null 2>&1; then
  ok "remote (origin) crew/oracle/fx-bead branch SURVIVES the sweep"
else
  bad "remote crew/oracle/fx-bead branch was DELETED by the sweep — DATA-LOSS regression (ga-0re8j)"
fi
grep -q '"event":"branch_deleted"' "$MUT_TMP/run.jsonl" 2>/dev/null && bad "run log recorded a branch_deleted event (ga-0re8j)" || ok "no branch_deleted event logged"
grep -q '"event":"remote_branch_deleted"' "$MUT_TMP/run.jsonl" 2>/dev/null && bad "run log recorded a remote_branch_deleted event (ga-0re8j)" || ok "no remote_branch_deleted event logged"
[ -d "$MUT_GT/crew/worker-fx-bead" ] && bad "orphan gatefix-worker worktree NOT reaped (regression)" || ok "orphan gatefix-worker worktree still reaped"

rm -rf "$MUT_TMP"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
