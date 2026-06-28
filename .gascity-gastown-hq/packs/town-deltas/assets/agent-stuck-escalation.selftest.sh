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
# bd [-C <store>] list --status in_progress --json → reads $WORK/beads.json
# Accepts the new multi-store -C <store> prefix transparently.
cat > "$SHIM/bd" <<'SHIM'
#!/usr/bin/env bash
# Consume -C <store> prefix so existing fixture logic works unchanged
if [ "$1" = "-C" ]; then shift 2; fi
if [ "$1 $2" = "list --status" ] && [ "$3" = "in_progress" ]; then
    cat "${BEADS_FIXTURE:-/dev/null}"
    exit 0
fi
echo "[]"
SHIM
chmod +x "$SHIM/bd"

# ── gc shim ───────────────────────────────────────────────────────────────────
# gc session list --json → reads $WORK/sessions.json
# gc mail send <recipient> -s <subject> → records "mail:<recipient>|<subject>"
cat > "$SHIM/gc" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "session list")
    cat "${SESSIONS_FIXTURE:-/dev/null}"
    exit 0
    ;;
  "mail send")
    # $3 = recipient; find subject after -s flag
    _recipient="${3:-mayor}"
    shift 3 2>/dev/null || true
    while [ $# -gt 0 ]; do
      if [ "$1" = "-s" ]; then
        echo "mail:${_recipient}|$2" >> "$ACTIONS_FILE"
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
    ESCALATION_STORES="$WORK/city" \
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
assert_absent "$ACTIONS" "mail:mayor" "T1: no mail fired"
log_contains "T1" "no in_progress beads" "T1: correct log message"

# ── T2: bead stuck >30min, no session → escalates ────────────────────────────
echo "T2: bead stuck >30min with dead session → escalate"
printf '[%s]' "$(make_bead ga-test01 thies-wa 2000)" > "$BEADS_FIXTURE"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test01" "T2: escalation mail sent"
assert_contains "$ACTIONS" "notify" "T2: notify sent"
# State file created
[ -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test01" ] && ok "T2: state file created" || bad "T2: missing state file"

# ── T3: same bead within cooldown → NO re-escalation ─────────────────────────
echo "T3: same bead within cooldown → no re-escalation"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 COOLDOWN_SEC=10800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T3: no re-escalation within cooldown"

# ── T4: bead NOT stuck (<30min) → no escalation ──────────────────────────────
echo "T4: bead fresh (<30min) → no escalation"
: > "$WORK/city/.gc/state/agent-stuck-escalation/ga-test01"  # clear state
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test01"
printf '[%s]' "$(make_bead ga-test02 mila-wa 900)" > "$BEADS_FIXTURE"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T4: no mail for fresh bead"

# ── T5: infrastructure bead (type=warrant) → skipped ─────────────────────────
echo "T5: warrant-type bead → skipped"
printf '[%s]' "$(make_bead ga-warrant1 dog-xxx 3600 warrant)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-warrant1"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T5: warrant bead skipped"

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
assert_absent "$ACTIONS" "mail:mayor" "T8: no mail with kill-switch"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation.disabled"

# ── T9: assignee session alive → diagnostic notes it ─────────────────────────
echo "T9: assignee session alive → logged as active"
echo '{"sessions":[{"name":"batista-ps","state":"active"}]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test04 batista-ps 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test04"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 out="$(run_script)"
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test04" "T9: escalation fired (session alive is OK — still stuck)"
log_contains "T9" "ativa" "T9: session 'ativa' status logged"

# ── T10–T12: Layer 1 routing integration (ga-qw3p.1) ────────────────────────
# Deploy the real escalation-router.sh so the script can source it.
echo "T10-T12: Layer 1 routing via escalation-router.sh"
HERE_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$WORK/city/packs/town-deltas/assets"
cp "$HERE_SELF/escalation-router.sh" "$WORK/city/packs/town-deltas/assets/escalation-router.sh"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"

# T10: bead with property keywords → routes to batista-ps
printf '[%s]' "$(make_bead ga-prop01 thies-wa 3600)" > "$BEADS_FIXTURE"
# Override title to have property keywords (make_bead uses generic title; patch fixture)
printf '[{"id":"ga-prop01","title":"scraper ITBI CNPJ cadastro RFB falhou","assignee":"thies-wa","status":"in_progress","issue_type":"feature","updated_at":"%s","labels":[]}]' \
    "$(python3 -c "import time, datetime; e=time.time()-3600; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")" \
    > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-prop01"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:batista-ps|" "T10: property bead routes to batista-ps"

# T11: bead with WA keywords → routes to mila-wa
printf '[{"id":"ga-wa01","title":"painel kanban pipedrive filtros erro","assignee":"oracle-wa","status":"in_progress","issue_type":"feature","updated_at":"%s","labels":[]}]' \
    "$(python3 -c "import time, datetime; e=time.time()-3600; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")" \
    > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-wa01"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mila-wa|" "T11: WA bead routes to mila-wa"

# T12: bead with no domain keywords → fallback to Mayor
printf '[{"id":"ga-gen01","title":"generic task sem topico especifico","assignee":"dog-x","status":"in_progress","issue_type":"feature","updated_at":"%s","labels":[]}]' \
    "$(python3 -c "import time, datetime; e=time.time()-3600; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")" \
    > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gen01"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|" "T12: no-topic bead fallback to Mayor"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
