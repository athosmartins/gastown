#!/usr/bin/env bash
# agent-stuck-escalation.selftest.sh — hermetic tests for agent-stuck-escalation.sh
# (ga-qw3p.2)
#
# Stubs `bd`, `gc`, and `notify` with fixture-driven shims.
# No real beads are read; no real mail or notifications fire.
# Exits 0 on PASS (all assertions), non-zero on first failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/agent-stuck-escalation.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }
assert_contains() { grep -qF "$2" "$1" && ok "$3" || bad "$3 (expected '$2' in $1)"; }
assert_absent()   { grep -qF "$2" "$1" && bad "$3 (unexpected '$2' in $1)" || ok "$3"; }
# log_contains: check the agent-stuck-escalation.log file (output goes there when DRY_RUN off)
log_contains()    { grep -qF "$2" "$WORK/city/.gc/logs/agent-stuck-escalation.log" && ok "$3" || bad "$3 (expected '$2' in log)"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHIM="$WORK/bin"
mkdir -p "$SHIM"
ACTIONS="$WORK/actions.log"
: > "$ACTIONS"

# ── bd shim ───────────────────────────────────────────────────────────────────
# bd list --status in_progress --json → reads $WORK/beads.json
cat > "$SHIM/bd" <<'SHIM'
#!/usr/bin/env bash
if [ "$1 $2" = "list --status" ] && [ "$3" = "in_progress" ]; then
    cat "${BEADS_FIXTURE:-/dev/null}"
    exit 0
fi
echo "[]"
SHIM
chmod +x "$SHIM/bd"

# ── gc shim ───────────────────────────────────────────────────────────────────
# gc session list --json → reads $WORK/sessions.json
# gc mail send mayor ... → records call to actions.log
cat > "$SHIM/gc" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "session list")
    cat "${SESSIONS_FIXTURE:-/dev/null}"
    exit 0
    ;;
  "mail send")
    # record subject (arg after -s)
    while [ $# -gt 0 ]; do
      if [ "$1" = "-s" ]; then
        echo "mail_to_mayor|$2" >> "$ACTIONS_FILE"
        break
      fi
      shift
    done
    exit 0
    ;;
esac
exit 0
SHIM
chmod +x "$SHIM/gc"

# ── notify shim ───────────────────────────────────────────────────────────────
cat > "$SHIM/notify" <<'SHIM'
#!/usr/bin/env bash
echo "notify $*" >> "$ACTIONS_FILE"
exit 0
SHIM
chmod +x "$SHIM/notify"

# ── helpers ───────────────────────────────────────────────────────────────────
run_script() {
    : > "$ACTIONS"
    GC_CITY_PATH="$WORK/city" \
    GC="$SHIM/gc" \
    BD="$SHIM/bd" \
    NOTIFY_BIN="$SHIM/notify" \
    BEADS_FIXTURE="${BEADS_FIXTURE:-}" \
    SESSIONS_FIXTURE="${SESSIONS_FIXTURE:-}" \
    ACTIONS_FILE="$ACTIONS" \
    STUCK_AGENT_SEC="${STUCK_AGENT_SEC:-1800}" \
    COOLDOWN_SEC="${COOLDOWN_SEC:-10800}" \
    bash "$SCRIPT" 2>&1
}

# Build a fake city dir
mkdir -p "$WORK/city/.gc/state" "$WORK/city/.gc/logs"

# Make fixture helper: age_secs is how OLD the bead is
make_bead() {  # make_bead <id> <assignee> <age_secs> [type]
    local id="$1" assignee="$2" age="$3" itype="${4:-feature}"
    local ts
    ts="$(python3 -c "import time, datetime; e=time.time()-$age; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
    printf '{"id":"%s","title":"Test bead %s","assignee":"%s","status":"in_progress","issue_type":"%s","updated_at":"%s","labels":[]}' \
        "$id" "$id" "$assignee" "$itype" "$ts"
}

BEADS_FIXTURE="$WORK/beads.json"
SESSIONS_FIXTURE="$WORK/sessions.json"
export BEADS_FIXTURE SESSIONS_FIXTURE

# Default: empty sessions
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"

# ── T1: no beads → healthy, no escalation ────────────────────────────────────
echo "T1: no in_progress beads → healthy"
echo "[]" > "$BEADS_FIXTURE"
out="$(run_script)"
assert_absent "$ACTIONS" "mail_to_mayor" "T1: no mail fired"
log_contains "T1" "no in_progress beads" "T1: correct log message"

# ── T2: bead stuck >30min, no session → escalates ────────────────────────────
echo "T2: bead stuck >30min with dead session → escalate"
printf '[%s]' "$(make_bead ga-test01 thies-wa 2000)" > "$BEADS_FIXTURE"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail_to_mayor|Agente travado: ga-test01" "T2: escalation mail sent"
assert_contains "$ACTIONS" "notify" "T2: notify sent"
# State file created
[ -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test01" ] && ok "T2: state file created" || bad "T2: missing state file"

# ── T3: same bead within cooldown → NO re-escalation ─────────────────────────
echo "T3: same bead within cooldown → no re-escalation"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 COOLDOWN_SEC=10800 run_script > /dev/null
assert_absent "$ACTIONS" "mail_to_mayor" "T3: no re-escalation within cooldown"

# ── T4: bead NOT stuck (<30min) → no escalation ──────────────────────────────
echo "T4: bead fresh (<30min) → no escalation"
: > "$WORK/city/.gc/state/agent-stuck-escalation/ga-test01"  # clear state
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test01"
printf '[%s]' "$(make_bead ga-test02 mila-wa 900)" > "$BEADS_FIXTURE"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail_to_mayor" "T4: no mail for fresh bead"

# ── T5: infrastructure bead (type=warrant) → skipped ─────────────────────────
echo "T5: warrant-type bead → skipped"
printf '[%s]' "$(make_bead ga-warrant1 dog-xxx 3600 warrant)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-warrant1"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail_to_mayor" "T5: warrant bead skipped"

# ── T6: two beads, one stuck, one fresh → only stuck one escalates ─────────
echo "T6: mixed beads → only stuck one escalates"
printf '[%s,%s]' \
    "$(make_bead ga-stuck-a oracle-wa 2500)" \
    "$(make_bead ga-fresh-b mila-wa 300)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-stuck-a"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "ga-stuck-a" "T6: stuck bead escalated"
assert_absent   "$ACTIONS" "ga-fresh-b" "T6: fresh bead not escalated"

# ── T7: state GC — bead closed → state file removed ──────────────────────────
echo "T7: bead closed between passes → state GC removes file"
# T6 left a state file for ga-stuck-a. Now serve empty beads (it closed).
echo "[]" > "$BEADS_FIXTURE"
run_script > /dev/null
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-stuck-a" ] && ok "T7: state file GC'd" || bad "T7: state file should have been removed"

# ── T8: kill-switch → no-op ───────────────────────────────────────────────────
echo "T8: kill-switch → no-op"
touch "$WORK/city/.gc/state/agent-stuck-escalation.disabled"
printf '[%s]' "$(make_bead ga-test03 oracle-wa 3600)" > "$BEADS_FIXTURE"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail_to_mayor" "T8: no mail with kill-switch"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation.disabled"

# ── T9: assignee session alive → diagnostic notes it ─────────────────────────
echo "T9: assignee session alive → logged as active"
echo '{"sessions":[{"name":"batista-ps","state":"active"}]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test04 batista-ps 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test04"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 out="$(run_script)"
assert_contains "$ACTIONS" "mail_to_mayor|Agente travado: ga-test04" "T9: escalation fired (session alive is OK — still stuck)"
log_contains "T9" "ativa" "T9: session 'ativa' status logged"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
