#!/usr/bin/env bash
# mayor-inbox-jev-triage.selftest.sh (ga-aijm2v.2)
#
# Runs the REAL mayor-inbox-jev-triage.sh (not a reimplementation) against a
# fixture inbox, with GC_BIN and JEV_BIN swapped for fakes via the script's
# own env-var seams (same pattern as next-action-coordinator-alert.selftest
# .sh). Exit 0 iff every assertion holds.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../mayor-inbox-jev-triage.sh"
FAKE_GC="$SELF_DIR/mayor-inbox-jev-triage.fake-gc"
FAKE_JEV="$SELF_DIR/mayor-inbox-jev-triage.fake-jev"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "-- 1. syntax --"
if bash -n "$SCRIPT"; then ok "mayor-inbox-jev-triage.sh passes bash -n"; else bad "bash -n FAILED"; exit 1; fi

echo "-- setup: fixture inbox (7 messages across archive/control/uncertain/error/3-unmatched) --"
INBOX_FILE="$WORK/inbox.json"
cat > "$INBOX_FILE" <<'EOF'
{"messages":[
  {"id":"msg-archive","from":"human","subject":"Your gate PASS is held for daemon verification: wa-aaa11 (ga-l7n3v)","body":"branch merged but source bead not closed"},
  {"id":"msg-control","from":"human","subject":"Watchdog: 3 bead(s) com gate:* label e zero marker ativo (>=30min)","body":"gate-orphaned-label-watchdog body"},
  {"id":"msg-uncertain","from":"human","subject":"Daemon-presence: something looks off","body":"daemon presence body"},
  {"id":"msg-jeverror","from":"human","subject":"[city-health-sentinel] alert","body":"city health sentinel body"},
  {"id":"msg-unmatched","from":"human","subject":"Beads sem rota","body":"no known watchdog pattern here"},
  {"id":"msg-decisao","from":"gastown.mayor","subject":"Decisao pendente: wa-zzz99 (next-action:mayor)","body":"a real decision request, never eligible"},
  {"id":"msg-diskfloor","from":"human","subject":"Dolt disk-floor CRITICAL: avail=3GB","body":"explicitly out of scope, handled by ga-4f4opx instead"}
]}
EOF

FIXTURES_FILE="$WORK/jev-fixtures.json"
cat > "$FIXTURES_FILE" <<'EOF'
{
  "gate-pass-held:wa-aaa11": {"arm":"experiment","suppress":true,"jev_error":null},
  "watchdog-gate-orphaned-label:watchdog-gate-orphaned-label": {"arm":"control","suppress":true,"jev_error":"control_arm_skips_jev"},
  "daemon-presence:daemon-presence": {"arm":"experiment","suppress":false,"jev_error":null},
  "city-health-sentinel:city-health-sentinel": {"no_output":true}
}
EOF

ARCHIVE_LOG="$WORK/archive.log"
JEV_CALL_LOG="$WORK/jev-calls.log"
: > "$ARCHIVE_LOG"; : > "$JEV_CALL_LOG"

run_triage() {
    env -i \
        PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
        HOME="$HOME" \
        GC_CITY_PATH="$WORK/city" \
        GC_PACK_STATE_DIR="$WORK/state" \
        MAYOR_INBOX_TRIAGE_SEEN_FILE="$WORK/seen.json" \
        MAYOR_INBOX_TRIAGE_LOG_FILE="$WORK/triage.log" \
        MAYOR_INBOX_TRIAGE_DRY_RUN="${TEST_DRY_RUN:-0}" \
        GC_BIN="$FAKE_GC" \
        JEV_BIN="$FAKE_JEV" \
        FAKE_GC_INBOX_FILE="$INBOX_FILE" \
        FAKE_GC_ARCHIVE_LOG="$ARCHIVE_LOG" \
        FAKE_JEV_FIXTURES="$FIXTURES_FILE" \
        FAKE_JEV_CALL_LOG="$JEV_CALL_LOG" \
        bash "$SCRIPT"
}

echo "-- 2. functional: first run -- only the true experiment+suppress=true message archives --"
run_triage >/dev/null

ARCHIVE_COUNT1=$(wc -l < "$ARCHIVE_LOG" | tr -d ' ')
if [ "$ARCHIVE_COUNT1" = "1" ] && grep -qx "msg-archive" "$ARCHIVE_LOG"; then
    ok "exactly 1 archive call, and it's msg-archive"
else
    bad "expected exactly 1 archive (msg-archive), got: $(cat "$ARCHIVE_LOG" | tr '\n' ',')"
fi

echo "-- 3. functional: control arm (msg-control) is NEVER archived even though its fixture suppress=true --"
if grep -qx "msg-control" "$ARCHIVE_LOG"; then bad "msg-control (control arm) was archived -- arm gate is broken"; else ok "msg-control correctly left alone (control arm never archives)"; fi

echo "-- 4. functional: uncertain (suppress=false) and jev-error (no_output) are left alone --"
if grep -qx "msg-uncertain" "$ARCHIVE_LOG"; then bad "msg-uncertain was archived despite suppress=false"; else ok "msg-uncertain correctly left alone"; fi
if grep -qx "msg-jeverror" "$ARCHIVE_LOG"; then bad "msg-jeverror was archived despite Jev hard-failing"; else ok "msg-jeverror correctly left alone (third state: never archive on doubt)"; fi

echo "-- 5. functional: unmatched subjects (unknown / decisao-pendente / disk-floor) never call Jev at all --"
JEV_CALLS1=$(wc -l < "$JEV_CALL_LOG" | tr -d ' ')
if [ "$JEV_CALLS1" = "4" ]; then ok "exactly 4 Jev calls (archive, control, uncertain, jeverror)"; else bad "expected 4 Jev calls, got $JEV_CALLS1: $(cat "$JEV_CALL_LOG" | tr '\n' ',')"; fi
if grep -qE '^(watchdog-gate-orphaned-label:watchdog-gate-orphaned-label)$' "$JEV_CALL_LOG" && \
   ! grep -q "msg-unmatched\|msg-decisao\|msg-diskfloor" "$JEV_CALL_LOG"; then
    ok "no Jev call carries an unmatched message's id/subject"
fi
if grep -qE '^gate-pass-held:wa-aaa11$' "$JEV_CALL_LOG"; then ok "entity_id = tipo:entidade extracted correctly (gate-pass-held:wa-aaa11)"; else bad "expected entity_id gate-pass-held:wa-aaa11 in Jev call log, not found"; fi
if grep -qE '^daemon-presence:daemon-presence$' "$JEV_CALL_LOG"; then ok "entity_id falls back to tipo:tipo when no bead-id is present in the subject"; else bad "expected fallback entity_id daemon-presence:daemon-presence, not found"; fi

echo "-- 6. functional: never touches 'Dolt disk-floor CRITICAL' (explicitly out of scope) or 'Decisao pendente' (explicit decision request) --"
if grep -q "diskfloor\|disk-floor" "$JEV_CALL_LOG" "$ARCHIVE_LOG"; then bad "disk-floor alert was touched -- must stay untouched (separate bead ga-4f4opx)"; else ok "disk-floor alert correctly never evaluated or archived"; fi
if grep -q "decisao\|next-action" "$JEV_CALL_LOG" "$ARCHIVE_LOG"; then bad "Decisao pendente alert was touched -- must stay untouched (explicit decision request)"; else ok "Decisao pendente alert correctly never evaluated or archived"; fi

echo "-- 7. functional: dedup -- second run over the same (now-filtered) inbox adds ZERO new Jev calls or archives --"
run_triage >/dev/null
ARCHIVE_COUNT2=$(wc -l < "$ARCHIVE_LOG" | tr -d ' ')
JEV_CALLS2=$(wc -l < "$JEV_CALL_LOG" | tr -d ' ')
if [ "$ARCHIVE_COUNT2" = "$ARCHIVE_COUNT1" ]; then ok "second run added zero new archives ($ARCHIVE_COUNT2 total)"; else bad "second run archived more (got $ARCHIVE_COUNT2, expected $ARCHIVE_COUNT1)"; fi
if [ "$JEV_CALLS2" = "$JEV_CALLS1" ]; then ok "second run added zero new Jev calls -- SEEN_FILE dedup honored for still-unread messages"; else bad "second run re-evaluated (got $JEV_CALLS2 Jev calls, expected $JEV_CALLS1) -- dedup broken"; fi

echo "-- 8. functional: DRY_RUN never calls gc mail archive, even for a true experiment+suppress=true message --"
DRY_INBOX="$WORK/dry-inbox.json"
cat > "$DRY_INBOX" <<'EOF'
{"messages":[{"id":"msg-dryrun","from":"human","subject":"Your gate PASS is held for scope review: wa-bbb22 (ga-k2wjn)","body":"dry run body"}]}
EOF
DRY_FIXTURES="$WORK/dry-fixtures.json"
cat > "$DRY_FIXTURES" <<'EOF'
{"gate-pass-held:wa-bbb22": {"arm":"experiment","suppress":true,"jev_error":null}}
EOF
DRY_ARCHIVE_LOG="$WORK/dry-archive.log"; : > "$DRY_ARCHIVE_LOG"
DRY_JEV_LOG="$WORK/dry-jev.log"; : > "$DRY_JEV_LOG"
env -i \
    PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
    HOME="$HOME" \
    GC_CITY_PATH="$WORK/city" \
    GC_PACK_STATE_DIR="$WORK/dry-state" \
    MAYOR_INBOX_TRIAGE_SEEN_FILE="$WORK/dry-seen.json" \
    MAYOR_INBOX_TRIAGE_LOG_FILE="$WORK/dry-triage.log" \
    MAYOR_INBOX_TRIAGE_DRY_RUN="1" \
    GC_BIN="$FAKE_GC" \
    JEV_BIN="$FAKE_JEV" \
    FAKE_GC_INBOX_FILE="$DRY_INBOX" \
    FAKE_GC_ARCHIVE_LOG="$DRY_ARCHIVE_LOG" \
    FAKE_JEV_FIXTURES="$DRY_FIXTURES" \
    FAKE_JEV_CALL_LOG="$DRY_JEV_LOG" \
    bash "$SCRIPT" > "$WORK/dry-stdout.log" 2>&1
if [ -s "$DRY_ARCHIVE_LOG" ]; then bad "DRY_RUN=1 still called gc mail archive"; else ok "DRY_RUN=1 never calls gc mail archive"; fi
if grep -q "would_archive=1" "$WORK/dry-stdout.log"; then ok "DRY_RUN=1 reports would_archive=1 in its summary"; else bad "DRY_RUN=1 summary missing would_archive=1: $(cat "$WORK/dry-stdout.log")"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
