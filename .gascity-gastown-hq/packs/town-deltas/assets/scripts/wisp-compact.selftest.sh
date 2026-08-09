#!/bin/bash
# wisp-compact.selftest.sh — hermetic test for the ga-3rqwa mail-preservation
# carve-out in wisp-compact.sh.
#
# Hermetic: stubs `bd` with a fake executable (prepended to PATH) that
# returns canned JSON for `bd list` and only LOGS delete/update/comment
# calls — never executes them. No real Dolt server is contacted, nothing is
# ever deleted. Runs the REAL script (not a stubbed copy of its logic), so
# this exercises the actual code path, not a reimplementation of it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/wisp-compact.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/bin"
CALLLOG="$WORKDIR/bd-calls.log"
: > "$CALLLOG"

# Fixed far-past timestamp — always past every TTL bucket (max 7d) regardless
# of when this test runs, so no "now" synchronization with the script is
# needed.
OLD_TS="2016-01-01T00:00:00Z"

# Five synthetic ephemeral beads covering every branch wisp-compact.sh can
# take, all past-TTL, zero comments, no keep label (the exact shape that
# reaches the delete branch pre-fix):
#   test-mail-closed   message/closed  → MUST be preserved (the ga-3rqwa bug)
#   test-mail-open     message/open    → MUST be promoted (non-regression:
#                                         open mail's pre-existing "stuck
#                                         detection" behavior is unchanged)
#   test-gate-closed   task/closed, type:quality-gate-run label → MUST still
#                                         be deleted (pre-existing carve-out)
#   test-generic-closed task/closed    → MUST still be deleted (proves the
#                                         fix didn't blanket-preserve everything)
#   test-generic-open  task/open       → MUST still be promoted (pre-existing
#                                         non-closed rule, non-regression)
FIXTURE=$(jq -nc --arg ts "$OLD_TS" '[
  {id:"test-mail-closed",    status:"closed", updated_at:$ts, comment_count:0, issue_type:"message", labels:[], ephemeral:true},
  {id:"test-mail-open",      status:"open",   updated_at:$ts, comment_count:0, issue_type:"message", labels:[], ephemeral:true},
  {id:"test-gate-closed",    status:"closed", updated_at:$ts, comment_count:0, issue_type:"task",    labels:["type:quality-gate-run"], ephemeral:true},
  {id:"test-generic-closed", status:"closed", updated_at:$ts, comment_count:0, issue_type:"task",    labels:[], ephemeral:true},
  {id:"test-generic-open",   status:"open",   updated_at:$ts, comment_count:0, issue_type:"task",    labels:[], ephemeral:true}
]')
echo "$FIXTURE" > "$WORKDIR/fixture.json"

# Fake `bd` — logs delete/update/comment calls, serves the fixture for list.
cat > "$WORKDIR/bin/bd" <<'STUB'
#!/bin/bash
case "$1" in
  list)
    cat "$FIXTURE_FILE"
    ;;
  delete)
    echo "DELETE $2" >> "$CALLLOG_FILE"
    ;;
  update)
    echo "PROMOTE $2" >> "$CALLLOG_FILE"
    ;;
  comment)
    echo "COMMENT $2" >> "$CALLLOG_FILE"
    ;;
  *)
    echo "unexpected bd call: $*" >> "$CALLLOG_FILE"
    ;;
esac
exit 0
STUB
chmod +x "$WORKDIR/bin/bd"

echo "=== wisp-compact.selftest.sh ==="

PATH="$WORKDIR/bin:$PATH" FIXTURE_FILE="$WORKDIR/fixture.json" CALLLOG_FILE="$CALLLOG" bash "$SCRIPT" >"$WORKDIR/script-output.log" 2>&1
SCRIPT_RC=$?

[ "$SCRIPT_RC" -eq 0 ] && ok "script exits 0 against the fixture" || bad "script exited $SCRIPT_RC — output: $(cat "$WORKDIR/script-output.log")"

# ── the actual bug: closed mail must NOT be deleted ───────────────────────
if grep -qF "DELETE test-mail-closed" "$CALLLOG"; then
  bad "CLOSED MAIL WAS DELETED — the exact ga-3rqwa bug is back"
else
  ok "closed mail (test-mail-closed) was not deleted"
fi
if grep -qF "PROMOTE test-mail-closed" "$CALLLOG"; then
  bad "closed mail was promoted — should be left exactly as-is, not converted to permanent"
else
  ok "closed mail (test-mail-closed) was not promoted either — left untouched"
fi

# ── non-regression: open mail keeps its pre-existing promote behavior ─────
if grep -qF "PROMOTE test-mail-open" "$CALLLOG"; then
  ok "open mail (test-mail-open) is still promoted — pre-existing stuck-detection behavior unchanged"
else
  bad "open mail (test-mail-open) was NOT promoted — the fix over-widened beyond closed mail"
fi
if grep -qF "DELETE test-mail-open" "$CALLLOG"; then
  bad "open mail was deleted — open wisps must never be deleted"
fi

# ── non-regression: quality-gate carve-out still deletes ──────────────────
if grep -qF "DELETE test-gate-closed" "$CALLLOG"; then
  ok "quality-gate wisp (test-gate-closed) is still deleted — pre-existing carve-out unaffected"
else
  bad "quality-gate wisp (test-gate-closed) was NOT deleted — pre-existing carve-out regressed"
fi

# ── non-regression: generic closed wisps still deleted (fix isn't a blanket
# ── "never delete anything" no-op) ─────────────────────────────────────────
if grep -qF "DELETE test-generic-closed" "$CALLLOG"; then
  ok "generic closed wisp (test-generic-closed) is still deleted — fix is scoped to mail, not blanket"
else
  bad "generic closed wisp (test-generic-closed) was NOT deleted — fix over-widened to all wisps"
fi

# ── non-regression: generic open wisps still promoted ──────────────────────
if grep -qF "PROMOTE test-generic-open" "$CALLLOG"; then
  ok "generic open wisp (test-generic-open) is still promoted — non-closed rule unaffected"
else
  bad "generic open wisp (test-generic-open) was NOT promoted — non-closed rule regressed"
fi

echo "── call log ──"
cat "$CALLLOG"

# ── drift-guard: the carve-out is scoped to status==closed, not blanket on
# ── issue_type alone (the over-wide version this test's own history caught
# ── during development) ─────────────────────────────────────────────────
if grep -qE '\[ "\$issue_type" = "message" \] && \[ "\$status" = "closed" \]' "$SCRIPT"; then
  ok "mail carve-out is scoped to status==closed in the live script text"
else
  bad "mail carve-out no longer scoped to status==closed — check for over-widening"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
