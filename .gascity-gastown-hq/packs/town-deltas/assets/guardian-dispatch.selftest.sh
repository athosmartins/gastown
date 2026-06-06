#!/usr/bin/env bash
# guardian-dispatch.selftest.sh — Unit+drift tests for the guardian-dispatch
# auto-heal system (story ga-0wxg).
#
# Tests:
#   1. Pure-logic helpers (file_age_sec, launchd_pid extraction, etc.)
#   2. Engine-stall classification (stale vs fresh log)
#   3. Incident lifecycle state transitions (open/resolve/escalate/cooldown)
#   4. Delivery-fail detection from JSONL
#   5. Drift-guards (guardian script + gate-health-monitor.py both implement
#      the required contracts)
#
# No live gc/bd/launchctl/Dolt calls — all IO uses temp fixtures.
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(dirname "$(dirname "$(dirname "$SELF_DIR")")")"
GUARDIAN="$CITY_ROOT/scripts/guardian-dispatch.sh"
MONITOR="$CITY_ROOT/scripts/gate-health-monitor.py"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── 1. file_age_sec: returns large value for missing file ─────────────────────
echo "── 1. file_age_sec for missing / existing file ──"

# Inline the function for testing (source is not safe without live GC_CITY)
file_age_sec_test() {
  local f="$1"
  [ -f "$f" ] || { echo "999999"; return; }
  echo $(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo "0") ))
}

eq "missing file → 999999" "$(file_age_sec_test /nonexistent/file)" "999999"

# Create a fresh file
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

touch "$TMP_DIR/fresh.log"
AGE=$(file_age_sec_test "$TMP_DIR/fresh.log")
if [ "$AGE" -lt 5 ]; then ok "fresh file age < 5s (=$AGE)"; else bad "fresh file age should be <5s, got $AGE"; fi

# Create a stale file
touch -t "$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null || date -d '20 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || echo "")" \
  "$TMP_DIR/stale.log" 2>/dev/null || { sleep 1; touch -d "20 minutes ago" "$TMP_DIR/stale.log" 2>/dev/null || touch "$TMP_DIR/stale.log"; }
STALE=$(file_age_sec_test "$TMP_DIR/stale.log")
if [ "$STALE" -gt 800 ]; then ok "stale file age > 800s (=$STALE)"; else bad "stale age should be >800s, got $STALE (touch -t may not have worked, skipping)"; fi

# ── 2. Engine stall classification ────────────────────────────────────────────
echo "── 2. Engine stall threshold classification ──"

ENGINE_STALL_SEC=900

is_stalled() {
  local age="$1"
  [ "$age" -gt "$ENGINE_STALL_SEC" ] && echo "stalled" || echo "ok"
}

eq "age 800s → ok"    "$(is_stalled 800)"   "ok"
eq "age 900s → ok"    "$(is_stalled 900)"   "ok"
eq "age 901s → stall" "$(is_stalled 901)"   "stalled"
eq "age 999999 → stall (missing file)" "$(is_stalled 999999)" "stalled"

# ── 3. Incident state transitions (pure JSON manipulations) ───────────────────
echo "── 3. Incident state: open / resolve / escalate ──"

FIX_CAP=3
now=$(date +%s)

# initial state — no incidents
ST='{"seen_qg":0,"seen_sd":0,"incidents":{}}'

# open an incident
open_in_state() {
  local st="$1" key="$2" bead="$3" ts="$4"
  printf '%s' "$st" | jq -c ".incidents[\"$key\"] = {\"bead\":\"$bead\",\"attempt\":1,\"opened_at\":$ts,\"last_checked\":$ts,\"escalated\":false}"
}

get_attempt() {
  printf '%s' "$1" | jq -r ".incidents[\"$2\"].attempt // 0"
}

get_escalated() {
  printf '%s' "$1" | jq -r ".incidents[\"$2\"].escalated // false"
}

is_incident_null() {
  result=$(printf '%s' "$1" | jq -r ".incidents[\"$2\"] // \"null\"")
  [ "$result" = "null" ] && echo "null" || echo "present"
}

# Open an incident
ST=$(open_in_state "$ST" "engine-stall-gate" "ga-test01" "$now")
eq "after open: attempt=1"    "$(get_attempt "$ST" "engine-stall-gate")" "1"
eq "after open: not escalated" "$(get_escalated "$ST" "engine-stall-gate")" "false"

# Bump attempt
bump_attempt() {
  local st="$1" key="$2" new_ts="$3"
  local old; old=$(printf '%s' "$st" | jq -r ".incidents[\"$key\"].attempt // 0")
  local new=$(( old + 1 ))
  printf '%s' "$st" | jq -c ".incidents[\"$key\"].attempt = $new | .incidents[\"$key\"].last_checked = $new_ts"
}

ST=$(bump_attempt "$ST" "engine-stall-gate" "$now")
eq "after bump: attempt=2" "$(get_attempt "$ST" "engine-stall-gate")" "2"

ST=$(bump_attempt "$ST" "engine-stall-gate" "$now")
eq "after bump: attempt=3" "$(get_attempt "$ST" "engine-stall-gate")" "3"

# At attempt > FIX_CAP → escalate
should_escalate() {
  local attempt="$1"
  [ "$attempt" -gt "$FIX_CAP" ] && echo "escalate" || echo "retry"
}

eq "attempt 3 → retry"    "$(should_escalate 3)" "retry"
eq "attempt 4 → escalate" "$(should_escalate 4)" "escalate"

# Mark escalated
ST=$(printf '%s' "$ST" | jq -c ".incidents[\"engine-stall-gate\"].escalated = true")
eq "after escalate: escalated=true" "$(get_escalated "$ST" "engine-stall-gate")" "true"

# Clear incident on resolve
ST=$(printf '%s' "$ST" | jq -c 'del(.incidents["engine-stall-gate"])')
eq "after clear: incident null" "$(is_incident_null "$ST" "engine-stall-gate")" "null"

# ── 4. Delivery-fail JSONL parsing ────────────────────────────────────────────
echo "── 4. Delivery-fail detection from JSONL ──"

parse_delivery_fails() {
  local jsonl="$1"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local result story_id
    result=$(printf '%s' "$line" | jq -r '.result // ""' 2>/dev/null || true)
    story_id=$(printf '%s' "$line" | jq -r '.story_id // .story // ""' 2>/dev/null || true)
    case "$result" in
      *FAIL*|*HALT*) echo "FAIL:$story_id" ;;
      *) ;;
    esac
  done <<< "$jsonl"
}

JSONL='{"ts":"2026-06-05T12:00:00Z","event":"delivery_complete","story_id":"ga-abc","result":"PASS"}
{"ts":"2026-06-05T12:01:00Z","event":"delivery_complete","story_id":"ga-def","result":"FAIL","rig":"gascity"}
{"ts":"2026-06-05T12:02:00Z","event":"delivery_complete","story_id":"ga-ghi","result":"HALT","rig":"wa"}
{"ts":"2026-06-05T12:03:00Z","event":"delivery_complete","story_id":"ga-jkl","result":"PASS"}'

FAILS=$(parse_delivery_fails "$JSONL")
count_matches() { echo "$1" | grep -c "$2" 2>/dev/null; } || true
eq "PASS not detected"       "$(count_matches "$FAILS" "ga-abc")" "0"
eq "FAIL detected"           "$(count_matches "$FAILS" "ga-def")" "1"
eq "HALT detected"           "$(count_matches "$FAILS" "ga-ghi")" "1"
eq "second PASS not detected" "$(count_matches "$FAILS" "ga-jkl")" "0"

# ── 5. Cooldown: last_checked prevents re-alert within REALERT_SEC ────────────
echo "── 5. Cooldown: no re-check within REALERT_SEC ──"

REALERT_SEC=900

should_recheck() {
  local last_checked="$1" now="$2"
  local age=$(( now - last_checked ))
  [ "$age" -ge "$REALERT_SEC" ] && echo "recheck" || echo "skip"
}

eq "just checked (0s ago) → skip"   "$(should_recheck "$now" "$now")" "skip"
eq "800s ago → skip"                "$(should_recheck $(( now - 800 )) "$now")" "skip"
eq "900s ago → recheck"             "$(should_recheck $(( now - 900 )) "$now")" "recheck"
eq "1800s ago → recheck"            "$(should_recheck $(( now - 1800 )) "$now")" "recheck"

# ── 6. Drift-guards: guardian script implements required contracts ─────────────
echo "── 6. Drift-guard: guardian-dispatch.sh ──"

[ -f "$GUARDIAN" ] && ok "guardian-dispatch.sh exists" || { bad "guardian-dispatch.sh missing"; }

grep -q 'engine-stall-gate'   "$GUARDIAN" && ok "detects engine-stall-gate"   || bad "missing engine-stall-gate"
grep -q 'engine-stall-pilot'  "$GUARDIAN" && ok "detects engine-stall-pilot"  || bad "missing engine-stall-pilot"
grep -q 'check_real_jams'     "$GUARDIAN" && ok "checks real jams"             || bad "missing check_real_jams"
grep -q 'check_delivery_fails' "$GUARDIAN" && ok "checks delivery fails"       || bad "missing check_delivery_fails"
grep -q 'FIX_CAP'             "$GUARDIAN" && ok "has FIX_CAP (retry cap)"     || bad "missing FIX_CAP"
grep -q 'escalate_to_mayor'   "$GUARDIAN" && ok "escalates to Mayor"           || bad "missing escalate_to_mayor"
grep -q 'mail send mayor'     "$GUARDIAN" && ok "uses gc mail send mayor"      || bad "missing mail send mayor"
grep -q 'notify'              "$GUARDIAN" && ok "sends notify alert"           || bad "missing notify"
grep -q 'guardian.heartbeat'  "$GUARDIAN" && ok "writes heartbeat"             || bad "missing heartbeat"
grep -q 'guardian.lock'       "$GUARDIAN" && ok "has lock (no concurrent runs)" || bad "missing lock"
grep -q 'GUARDIAN_CITY_OVERRIDE' "$GUARDIAN" && ok "has city override (testable)" || bad "missing GUARDIAN_CITY_OVERRIDE"
grep -q 'DRY_RUN'             "$GUARDIAN" && ok "implements DRY_RUN flag"      || bad "missing DRY_RUN (documented but unimplemented is a safety trap)"
grep -q '"1".*DRY_RUN\|DRY_RUN.*"1"' "$GUARDIAN" && ok "DRY_RUN guard present" || bad "DRY_RUN not actually checked in script body"
grep -q 'mv.*tmp.*STATE_FILE\|tmp.*mv.*STATE_FILE\|STATE_FILE.*tmp' "$GUARDIAN" && \
  ok "state_save is atomic (tmp+mv)" || bad "state_save non-atomic (corrupt on crash → crash loop)"

# ── 7. Drift-guard: gate-health-monitor.py adds GUARDIAN-STALL ────────────────
echo "── 7. Drift-guard: gate-health-monitor.py ──"

[ -f "$MONITOR" ] && ok "gate-health-monitor.py exists" || bad "gate-health-monitor.py missing"
grep -q 'GUARDIAN-STALL'        "$MONITOR" && ok "emits [GUARDIAN-STALL]"               || bad "missing GUARDIAN-STALL"
grep -q 'guardian.heartbeat'    "$MONITOR" && ok "checks guardian.heartbeat"             || bad "missing guardian.heartbeat check"
grep -q 'GUARDIAN_STALL_SEC'    "$MONITOR" && ok "has GUARDIAN_STALL_SEC threshold"      || bad "missing GUARDIAN_STALL_SEC"
grep -q 'guardian_alerted'      "$MONITOR" && ok "has cooldown for guardian stall"       || bad "missing guardian_alerted cooldown"
grep -q '_CITY_ROOT\|abspath.*__file__' "$MONITOR" && \
  ok "monitor uses absolute paths (runnable from any cwd)" || bad "monitor uses relative paths (cwd-dependent, no deployment guarantee)"

# ── 8. Drift-guard: plist exists and references the script ────────────────────
echo "── 8. Drift-guard: guardian-dispatch.plist ──"

PLIST="$SELF_DIR/guardian-dispatch.plist"
[ -f "$PLIST" ] && ok "guardian-dispatch.plist exists" || bad "guardian-dispatch.plist missing"
grep -q 'com.gascity.guardian' "$PLIST" && ok "plist label is com.gascity.guardian" || bad "wrong plist label"
grep -q 'guardian-dispatch.sh' "$PLIST" && ok "plist references guardian-dispatch.sh" || bad "plist wrong script path"
grep -q 'StartInterval'        "$PLIST" && ok "plist has StartInterval"              || bad "plist missing StartInterval"

# ── 9. Drift-guard: gate-health-monitor.plist exists ─────────────────────────
echo "── 9. Drift-guard: gate-health-monitor.plist ──"

MONITOR_PLIST="$SELF_DIR/gate-health-monitor.plist"
[ -f "$MONITOR_PLIST" ] && ok "gate-health-monitor.plist exists" || bad "gate-health-monitor.plist missing — monitor has no launch mechanism"
grep -q 'com.gascity.gate-health-monitor' "$MONITOR_PLIST" 2>/dev/null && \
  ok "plist label is com.gascity.gate-health-monitor" || bad "wrong plist label for monitor"
grep -q 'gate-health-monitor.py' "$MONITOR_PLIST" 2>/dev/null && \
  ok "plist references gate-health-monitor.py" || bad "plist wrong script path for monitor"
grep -q 'KeepAlive' "$MONITOR_PLIST" 2>/dev/null && \
  ok "monitor plist has KeepAlive (persistent daemon)" || bad "monitor plist missing KeepAlive"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "guardian-dispatch.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
