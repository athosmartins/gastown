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
# bd [-C <store>] list -l source-bead:<id> --json → reads
#   $GATE_MARKERS_DIR/<id>.json (ga-n937 in-gate marker check; absent
#   fixture = "[]", mirrors real bd's empty-result response)
# Accepts the new multi-store -C <store> prefix transparently.
cat > "$SHIM/bd" <<'SHIM'
#!/usr/bin/env bash
# Consume -C <store> prefix so existing fixture logic works unchanged
if [ "$1" = "-C" ]; then shift 2; fi
if [ "$1 $2" = "list --status" ] && [ "$3" = "in_progress" ]; then
    cat "${BEADS_FIXTURE:-/dev/null}"
    exit 0
fi
if [ "$1" = "list" ] && [ "$2" = "-l" ]; then
    case "$3" in
        source-bead:*)
            _bid="${3#source-bead:}"
            _f="${GATE_MARKERS_DIR:-}/${_bid}.json"
            if [ -n "${GATE_MARKERS_DIR:-}" ] && [ -f "$_f" ]; then
                cat "$_f"
            else
                echo "[]"
            fi
            exit 0
            ;;
    esac
fi
echo "[]"
SHIM
chmod +x "$SHIM/bd"

# ── gc shim ───────────────────────────────────────────────────────────────────
# gc session list --json → reads $WORK/sessions.json
# gc session logs <name> --tail 1 --json → reads $LOGS_FIXTURE_DIR/<name>.json
#   (absent fixture = simulates real `gc`'s "not found"/error response)
# gc mail send <recipient> -s <subject> → records "mail:<recipient>|<subject>"
cat > "$SHIM/gc" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "session list")
    if [ "${SESSIONS_QUERY_FAIL:-0}" = "1" ]; then
        # Simulates a real `gc session list` failure: nonzero exit, no
        # stdout — e.g. Dolt unreachable, gc binary crash, timeout.
        exit 1
    fi
    cat "${SESSIONS_FIXTURE:-/dev/null}"
    exit 0
    ;;
  "session logs")
    _target="${3:-}"
    _f="${LOGS_FIXTURE_DIR:-}/${_target}.json"
    if [ -n "${LOGS_FIXTURE_DIR:-}" ] && [ -f "$_f" ]; then
        cat "$_f"
        exit 0
    fi
    echo '{"ok":false,"error":{"message":"session not found"}}'
    exit 1
    ;;
  "session peek")
    _target="${3:-}"
    _f="${PEEK_FIXTURE_DIR:-}/${_target}.txt"
    if [ -n "${PEEK_FIXTURE_DIR:-}" ] && [ -f "$_f" ]; then
        cat "$_f"
    fi
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
    SESSIONS_QUERY_FAIL="${SESSIONS_QUERY_FAIL:-0}" \
    LOGS_FIXTURE_DIR="${LOGS_FIXTURE_DIR:-}" \
    PEEK_FIXTURE_DIR="${PEEK_FIXTURE_DIR:-}" \
    GATE_MARKERS_DIR="${GATE_MARKERS_DIR:-}" \
    ACTIONS_FILE="$ACTIONS" \
    STUCK_AGENT_SEC="${STUCK_AGENT_SEC:-1800}" \
    COOLDOWN_SEC="${COOLDOWN_SEC:-10800}" \
    TRANSCRIPT_FRESH_SEC="${TRANSCRIPT_FRESH_SEC:-1800}" \
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
LOGS_FIXTURE_DIR="$WORK/logsfx"
PEEK_FIXTURE_DIR="$WORK/peekfx"
GATE_MARKERS_DIR="$WORK/gatemarkers"
mkdir -p "$LOGS_FIXTURE_DIR" "$WORK/transcripts" "$GATE_MARKERS_DIR" "$PEEK_FIXTURE_DIR"
export BEADS_FIXTURE SESSIONS_FIXTURE LOGS_FIXTURE_DIR PEEK_FIXTURE_DIR GATE_MARKERS_DIR

# Default: empty sessions
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"

# make_bead_json <id> <assignee> <age_secs> <labels_json_array> [type]
# Like make_bead but with caller-controlled labels (ga-n937 gate tests).
make_bead_json() {
    local id="$1" assignee="$2" age="$3" labels="$4" itype="${5:-feature}"
    local ts
    ts="$(python3 -c "import time, datetime; e=time.time()-$age; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
    printf '{"id":"%s","title":"Test bead %s","assignee":"%s","status":"in_progress","issue_type":"%s","updated_at":"%s","labels":%s}' \
        "$id" "$id" "$assignee" "$itype" "$ts" "$labels"
}

# make_gate_marker_fixture <bead-id> <gate-status>
# Registers an OPEN type:quality-gate-marker naming <bead-id> via
# source-bead, for the `bd -C <city> list -l source-bead:<id> --json` query.
make_gate_marker_fixture() {
    local bid="$1" status="${2:-queued}"
    printf '[{"id":"ga-wisp-%s","status":"open","labels":["type:quality-gate-marker","source-bead:%s","gate-status:%s"]}]' \
        "$bid" "$bid" "$status" > "$GATE_MARKERS_DIR/$bid.json"
}

# make_transcript_fixture <session-name> <age-secs> [entries_json]
# Registers a `gc session logs <session-name> --json` fixture pointing at a
# real file whose mtime is <age-secs> old — lets tests simulate a transcript
# that's fresh ("advancing") or stale ("frozen") without a real running agent.
# [entries_json] (wa-y0620): optional JSON array string for the "entries"
# field session_awaiting_human_input() reads; defaults to "[]" so existing
# 2-arg callers are unaffected (empty entries → not-awaiting, same as today).
make_transcript_fixture() {
    local name="$1" age="$2" entries="${3:-[]}" tfile
    tfile="$WORK/transcripts/$name.jsonl"
    echo '{}' > "$tfile"
    python3 -c "import os,time; t=time.time()-$age; os.utime('$tfile', (t, t))"
    printf '{"ok":true,"transcript_path":"%s","entries":%s}' "$tfile" "$entries" > "$LOGS_FIXTURE_DIR/$name.json"
}

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

# ── T9: assignee session alive, transcript unresolvable → diagnostic notes ──
# session as active, but does NOT escalate (ga-4tmc fail-safe). This fixture
# shape (live session, no LOGS_FIXTURE_DIR entry registered) makes the gc
# shim fall through to its default {"ok":false,...} envelope — historically
# (pre-ga-4tmc) that got silently read as "confirmed empty transcript" and
# escalated; that was exactly the bug (ga-4tmc: a query FAILURE is not the
# same as a query that succeeded with an empty answer — ga-p5q3 root class).
echo "T9: assignee session alive, transcript unresolvable → unknown, no escalation"
echo '{"sessions":[{"name":"batista-ps","state":"active"}]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test04 batista-ps 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test04"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 out="$(run_script)"
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test04" "T9: no escalation — transcript state unresolvable (ga-4tmc fail-safe)"
log_contains "T9" "ativa" "T9: session 'ativa' status logged"

# ── T13: session alive + transcript ADVANCING → suppress escalation (ga-hehi) ─
echo "T13: session alive, transcript advancing → escalation suppressed"
echo '{"sessions":[{"name":"batista-ps","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture batista-ps 30   # written 30s ago — well under the 1800s threshold
printf '[%s]' "$(make_bead ga-test05 batista-ps 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test05"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test05" "T13: no mail — transcript advancing"
assert_absent "$ACTIONS" "notify" "T13: no notify — transcript advancing"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test05" ] && ok "T13: no escalation state written (suppression is log-only)" || bad "T13: unexpected state file written on suppression"
log_contains "T13" "SUPRIMINDO" "T13: log notes suppression"
rm -f "$LOGS_FIXTURE_DIR/batista-ps.json"

# ── T14: session alive + transcript FROZEN → escalation still fires ──────────
echo "T14: session alive, transcript frozen → escalation still fires"
echo '{"sessions":[{"name":"oracle-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture oracle-wa 3600   # written 1h ago — past the 1800s threshold
printf '[%s]' "$(make_bead ga-test06 oracle-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test06"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test06" "T14: escalation fires — transcript frozen despite live session"
log_contains "T14" "CONGELADO" "T14: log notes transcript frozen"
rm -f "$LOGS_FIXTURE_DIR/oracle-wa.json"

# ── T15: session absent/dead (no transcript fixture) → escalation unchanged ──
echo "T15: session absent/dead → escalation still fires (no regression)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test07 thies-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test07"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test07" "T15: escalation fires — absent session, no regression"

# ── T16: bead in gate:queued → suppressed (ga-n937) ──────────────────────────
echo "T16: bead with gate:queued label → suppressed (in-gate, ga-n937)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead_json ga-gate01 thies-wa 2200 '["ctx:ready","gate:queued"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate01"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-gate01" "T16: no mail — bead is in gate:queued"
assert_absent "$ACTIONS" "notify" "T16: no notify — bead is in gate:queued"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate01" ] && ok "T16: no escalation state written (suppression is log-only)" || bad "T16: unexpected state file written on suppression"
log_contains "T16" "EM GATE" "T16: log notes in-gate suppression"

# ── T17: bead in gate:reviewing → suppressed ──────────────────────────────────
echo "T17: bead with gate:reviewing label → suppressed"
printf '[%s]' "$(make_bead_json ga-gate02 mila-wa 3000 '["gate:reviewing"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate02"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T17: no mail — bead is in gate:reviewing"

# ── T18: bead carries no gate:* label but an OPEN quality-gate-marker still ──
# names it via source-bead (branch already pruned, wa-8y45-style) → suppressed
echo "T18: bead has no gate:* label but an OPEN quality-gate-marker names it → suppressed"
printf '[%s]' "$(make_bead_json ga-gate03 oracle-wa 2600 '["ctx:ready"]')" > "$BEADS_FIXTURE"
make_gate_marker_fixture ga-gate03 needs-rebase
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate03"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T18: no mail — open gate marker owns the bead"
log_contains "T18" "EM GATE" "T18: log notes in-gate suppression (marker-only signal)"
rm -f "$GATE_MARKERS_DIR/ga-gate03.json"

# ── T19: gate:needs-fix + dead session → STILL escalates (no regression) ─────
echo "T19: bead with gate:needs-fix label + dead session → escalation still fires"
printf '[%s]' "$(make_bead_json ga-gate04 thies-wa 2200 '["gate:needs-fix"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate04"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-gate04" "T19: gate:needs-fix still escalates (fixer should be working)"

# ── T20: gate:needs-human + dead session → STILL escalates (no regression) ───
echo "T20: bead with gate:needs-human label + dead session → escalation still fires"
printf '[%s]' "$(make_bead_json ga-gate05 mila-wa 2200 '["gate:needs-human"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate05"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-gate05" "T20: gate:needs-human still escalates (unchanged failure_markers behavior)"

# ── T21: building bead (no gate label/marker), transcript frozen → escalates ─
# (ga-hehi intact — explicit ACEITE case 3, also covered implicitly by T14)
echo "T21: building bead, no gate signal, transcript frozen → escalation still fires"
echo '{"sessions":[{"name":"peter-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture peter-wa 3600
printf '[%s]' "$(make_bead_json ga-gate06 peter-wa 2200 '["ctx:ready"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gate06"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-gate06" "T21: building bead with no gate signal still escalates (ga-hehi intact)"
rm -f "$LOGS_FIXTURE_DIR/peter-wa.json"

# ── T22: session alive but 'gc session logs' FAILS (ok:false) → UNKNOWN, ────
# never read as CONGELADO — escalation suppressed (ga-4tmc fail-safe: a
# failed query must never be treated as a confirmed-empty/frozen transcript)
echo "T22: session alive, gc session logs returns ok:false → unknown, escalation suppressed"
echo '{"sessions":[{"name":"thies-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
# No LOGS_FIXTURE_DIR/thies-wa.json registered → the gc shim falls through to
# its default: echo '{"ok":false,...}'; exit 1 — the exact envelope ga-4tmc
# found `gc session logs thies-wa-gam257` returning for a live crew session.
printf '[%s]' "$(make_bead ga-test08 thies-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test08"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test08" "T22: no mail — transcript query failed (ok:false), never treated as confirmed-frozen"
assert_absent "$ACTIONS" "notify" "T22: no notify — unknown state suppresses same as advancing"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test08" ] && ok "T22: no escalation state written (suppression is log-only)" || bad "T22: unexpected state file written on suppression"
log_contains "T22" "DESCONHECIDO" "T22: log distinguishes UNKNOWN from confirmed CONGELADO"
rm -f "$LOGS_FIXTURE_DIR/thies-wa.json"

# NOTE (ga-l2d2, resolved): T9/T13/T14/T21/T22 above already exercise
# crew-shaped names (batista-ps, oracle-wa, peter-wa, thies-wa) through
# every tri-state branch — advancing, frozen, and unknown. That's real
# coverage of THIS script's branching logic, which is name-agnostic (the
# `gc` shim keys off whatever LOGS_FIXTURE_DIR/<name>.json fixture is
# registered, never the real ~/.claude/projects/<slug> resolution). It
# does NOT and structurally CANNOT prove `gc session logs` itself resolves
# real crew transcripts — that bug (ProjectSlug preserving "_" so every
# whatsapp_automation/property_scrapers crew session was permanently
# unresolvable, while HQ-path Mayor/dog sessions worked by coincidence of
# containing no "_") lived entirely inside `gc`, one layer below anything
# this stub touches. Adding another stubbed crew-shaped case here would
# re-test the same branching logic under a different fixture name, not
# close that gap. The real-resolution proof (hermetic, fails pre-fix,
# passes post-fix) lives in the gc engine repo instead, where the bug
# actually was: internal/sessionlog/reader.go ProjectSlug +
# internal/sessionlog/sessionlog_test.go TestProjectSlug +
# cmd/gc/cmd_session_logs_test.go
# Test{ResolveSessionLogPathResolvesCrewShapedWorkDirWithUnderscore,
# ResolveStoredSessionLogSource_ResolvesCrewShapedWorkDirWithUnderscore}.

# ── T23: assignee is a session_name distinct from the session's `name` ──────
# (ga-2tpd part 1): this is the REAL shape of every CREW/DOG session —
# bead.assignee carries session_name (e.g. "thies-wa-gam257"), never the
# session's `name`/alias (e.g. "thies-wa"). Every fixture above (T9-T22) used
# adhoc-shaped sessions where name==session_name, which is exactly why the
# bug (ACTIVE_SESSIONS indexed only `name`) passed every prior test while
# never matching a real crew/dog assignee in production. Before the fix, this
# fixture's assignee could never match ACTIVE_SESSIONS, so sess_status stayed
# AUSENTE, the tri-state transcript check never ran, and the bead escalated
# against a session that was actually alive and advancing.
echo "T23: assignee is a session_name distinct from name → session resolves, transcript-advancing suppresses (ga-2tpd)"
echo '{"sessions":[{"name":"thies-wa","session_name":"thies-wa-gam257","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture thies-wa-gam257 30   # keyed by session_name, not name
printf '[%s]' "$(make_bead ga-test09 thies-wa-gam257 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test09"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test09" "T23: no escalation — assignee (session_name) resolves against the live session"
log_contains "T23" "ativa" "T23: session recognized as ativa via session_name match"
log_contains "T23" "SUPRIMINDO" "T23: log notes transcript-advancing suppression"
rm -f "$LOGS_FIXTURE_DIR/thies-wa-gam257.json"

# ── T24: `gc session list` query fails entirely → session state UNKNOWN for ──
# the whole pass, escalation suppressed (ga-2tpd part 2 — ga-p5q3 root class
# again: a query FAILURE must never collapse to the same value as a query
# that SUCCEEDED with an empty result). Before the fix, `${SESS_RAW:-{}}`
# made a failed `gc session list` look byte-identical to `{"sessions":[]}`,
# so every assignee read AUSENTE and every stuck bead with an assignee
# escalated on a session state nobody actually confirmed.
echo "T24: gc session list query fails entirely → session state unknown, escalation suppressed"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"   # ignored — shim fails before reading it
printf '[%s]' "$(make_bead ga-test10 thies-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test10"
: > "$ACTIONS"
SESSIONS_QUERY_FAIL=1 STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test10" "T24: no mail — session-list query failed, not confirmed-absent"
assert_absent "$ACTIONS" "notify" "T24: no notify — session-list query failure suppresses same as unknown transcript"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test10" ] && ok "T24: no escalation state written (suppression is log-only)" || bad "T24: unexpected state file written on suppression"
log_contains "T24" "DESCONHECIDO" "T24: log distinguishes session-query-failed from confirmed-absent"

# ── T25: session-list query fails + UNASSIGNED bead → still suppressed ───────
# (ga-79vq revision): this test used to assert the OPPOSITE — that an
# unassigned bead escalates "on age alone" regardless of session-query
# state. That assumption WAS the bug (see T26 below): an in_progress bead's
# assignee can be cleared out from under a live owner (inflight-reclaim-
# guard, a raw `bd update`, ...), so empty-assignee is UNKNOWN ownership,
# not proof nobody's home. Kept as its own case (rather than folded into
# T26) to document that the empty-assignee fail-safe and the
# session-query-failure fail-safe compose without conflict — either one
# alone is enough to suppress.
echo "T25: gc session list query fails + unassigned bead → still suppressed (ga-79vq)"
printf '[%s]' "$(make_bead ga-test11 "" 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test11"
: > "$ACTIONS"
SESSIONS_QUERY_FAIL=1 STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test11" "T25: unassigned bead suppressed even when session-query also fails"

# ── T26: empty assignee, session-list query SUCCEEDS → still suppressed ──────
# (ga-79vq core fix, acceptance case i). Distinct from T25 (which fails the
# session query entirely): here `gc session list` works fine and even
# reports an unrelated live session — but THIS bead's own assignee field is
# empty, so there's no name to check it against. Empty assignee is UNKNOWN
# ownership, not a dead assignee proven absent, and must suppress just like
# T22/T24/T25 — same root class (ga-p5q3): error and empty must not
# collapse to the same escalate-or-not answer. Real-world shape: wa-ka2lm
# escalated 3x this way while thies-wa-gam257 was alive and building it.
echo "T26: empty assignee, session-list query succeeds → suppressed (ga-79vq i)"
echo '{"sessions":[{"name":"thies-wa","session_name":"thies-wa-gam257","state":"active"}]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test12 "" 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test12"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test12" "T26: empty assignee suppressed regardless of session-query outcome"
assert_absent "$ACTIONS" "notify" "T26: no notify — unknown owner suppresses"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test12" ] && ok "T26: no escalation state written (suppression is log-only)" || bad "T26: unexpected state file written on suppression"
log_contains "T26" "assignee vazio" "T26: log distinguishes empty-assignee unknown from confirmed-absent"

# ── T27: assignee set, session genuinely absent → still escalates ────────────
# (ga-79vq acceptance case ii, no regression). Confirms the new
# empty-assignee fail-safe does NOT swallow the genuinely-dead-assignee
# case — only a truly EMPTY assignee suppresses; a real name with no
# matching active session is still a confirmed-absent verdict and escalates
# exactly as before (same shape as T15; kept as its own explicitly-named
# case for ga-79vq traceability).
echo "T27: assignee genuinely dead (non-empty, no matching session) → still escalates (ga-79vq ii)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test13 wa-dead-assignee 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test13"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test13" "T27: genuinely dead assignee still escalates (no regression)"

# ── T28: assignee alive, transcript advancing → suppressed ───────────────────
# (ga-79vq acceptance case iii, no regression). Same shape as T13 (ga-hehi);
# kept as its own explicitly-named case for ga-79vq traceability, using a
# fresh bead id/session so it can't accidentally reuse T13's fixtures.
echo "T28: assignee alive, transcript advancing → suppressed (ga-79vq iii)"
echo '{"sessions":[{"name":"mila-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture mila-wa 30
printf '[%s]' "$(make_bead ga-test14 mila-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test14"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test14" "T28: no mail — transcript advancing (regression, ga-hehi intact)"
rm -f "$LOGS_FIXTURE_DIR/mila-wa.json"

# ── T29: session alive, transcript frozen, last turn ended cleanly on text ───
# (plain end_turn, no tool call) → suppressed (wa-y0620 core fix). Mirrors
# the bug's own primary example verbatim: oracle-wa's last line was "Sigo
# parado aguardando o mockup." — a declarative sentence, NOT a question, so
# this also proves the fix does NOT rely on question-mark/keyword matching.
echo "T29: session alive, transcript frozen, last turn end_turn/no-tool → suppressed (wa-y0620)"
echo '{"sessions":[{"name":"oracle-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture oracle-wa 3600 '[{"type":"assistant","message":{"stop_reason":"end_turn"},"blocks":[{"type":"text","text":"Sigo parado aguardando o mockup."}]}]'
printf '[%s]' "$(make_bead ga-test15 oracle-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test15"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test15" "T29: no mail — last turn ended cleanly awaiting human (wa-y0620)"
assert_absent "$ACTIONS" "notify" "T29: no notify — awaiting-human suppresses"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test15" ] && ok "T29: no escalation state written (suppression is log-only)" || bad "T29: unexpected state file written on suppression"
log_contains "T29" "AGUARDANDO HUMANO" "T29: log notes awaiting-human suppression"
rm -f "$LOGS_FIXTURE_DIR/oracle-wa.json"

# ── T30: session alive, transcript frozen, last turn mid OTHER tool_use ──────
# (e.g. a Bash call with no result yet) → escalation STILL fires (no
# regression). This is the genuine hang case Mayor's case (a) describes: the
# environment owes this call a tool_result that never arrived.
echo "T30: session alive, transcript frozen, last turn mid Bash tool_use → escalation still fires"
echo '{"sessions":[{"name":"batista-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture batista-wa 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash"}]}]'
printf '[%s]' "$(make_bead ga-test16 batista-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test16"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test16" "T30: escalation fires — mid-tool-call is a real hang, not awaiting-human"
rm -f "$LOGS_FIXTURE_DIR/batista-wa.json"

# ── T31: session alive, transcript frozen, last turn IS the AskUserQuestion ──
# tool → suppressed. Structural equivalent of inflight-reclaim-guard.py's
# session_awaiting_human_input() (ga-nlaa), which detects the same case via
# a pane-text substring match instead.
echo "T31: session alive, transcript frozen, last turn is AskUserQuestion tool_use → suppressed"
echo '{"sessions":[{"name":"mila-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture mila-wa 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"AskUserQuestion"}]}]'
printf '[%s]' "$(make_bead ga-test17 mila-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test17"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test17" "T31: no mail — AskUserQuestion tool call is awaiting-human (ga-nlaa equivalent)"
log_contains "T31" "AGUARDANDO HUMANO" "T31: log notes awaiting-human suppression"
rm -f "$LOGS_FIXTURE_DIR/mila-wa.json"

# ── T32: session alive, transcript frozen, last entry is a tool_result ───────
# (assistant hasn't responded yet) → escalation still fires. Not the
# awaiting-human shape — this is "the environment already replied and the
# agent itself never picked it back up", the opposite of ceding control.
echo "T32: session alive, transcript frozen, last entry is tool_result (not assistant) → escalation still fires"
echo '{"sessions":[{"name":"thies-wa","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture thies-wa 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash"}]},{"type":"user","blocks":[{"type":"tool_result"}]}]'
printf '[%s]' "$(make_bead ga-test18 thies-wa 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test18"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test18" "T32: escalation fires — last entry is tool_result, not an assistant awaiting-human shape"
rm -f "$LOGS_FIXTURE_DIR/thies-wa.json"

# ── T33: assignee is a human identity (email), no session → suppressed ──────
# (ga-tiwmm). Mirrors T27 exactly (non-empty assignee, no matching active
# session) EXCEPT the assignee is a human email instead of an agent session
# name — proves the new is_human_assignee() guard fires before the
# genuinely-dead-assignee escalation path, without weakening T27 itself
# (T27's assignee "wa-dead-assignee" has no "@" and must still escalate).
echo "T33: assignee is human identity (email), no session → suppressed (ga-tiwmm)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test19 athosmartins@gmail.com 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test19"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test19" "T33: no mail — human assignee, absent session is normal"
assert_absent "$ACTIONS" "notify" "T33: no notify — human-assignee suppresses"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test19" ] && ok "T33: no escalation state written (suppression is log-only)" || bad "T33: unexpected state file written on suppression"
log_contains "T33" "identidade humana" "T33: log notes human-assignee suppression"

# ── T34-T39: pane_shows_permission_prompt / permission_prompt_blocked_command ─
# (ga-iog1v, AC1+AC2 of ga-q640n). T30 above (transcript frozen, pending Bash
# tool_use, NO peek fixture registered — the shim then returns empty stdout)
# already proves the fail-closed default: no PEEK_FIXTURE_DIR entry → generic
# "Agente travado" escalation, unchanged. These tests cover the new signal.

echo "T34: transcript frozen, pending Bash tool_use, pane confirms permission dialog → BLOQUEADO-EM-PROMPT escalation"
echo '{"sessions":[{"name":"dog-test1","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-test1 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash","input":{"command":"rm -rf scripts/__pycache__"}}]}]'
{
    echo "Permission rule Bash(rm -rf:*) requires confirmation for this command."
    echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"
} > "$PEEK_FIXTURE_DIR/dog-test1.txt"
printf '[%s]' "$(make_bead ga-test20 dog-test1 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test20"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente BLOQUEADO EM PROMPT (1 tecla resolve): ga-test20" "T34: differentiated escalation subject fires"
log_contains "T34" "ga-test20: BLOQUEADO-EM-PROMPT" "T34: log notes permission-prompt detection for this bead"
log_contains "T34" "rm -rf scripts/__pycache__" "T34: log includes the exact blocked command"
rm -f "$LOGS_FIXTURE_DIR/dog-test1.json" "$PEEK_FIXTURE_DIR/dog-test1.txt"

echo "T35: transcript frozen, pending Bash tool_use, pane has UNRELATED content → generic escalation (no false positive)"
echo '{"sessions":[{"name":"dog-test2","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-test2 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}]'
{
    echo "Running tests..."
    echo "12 passed, 0 failed"
} > "$PEEK_FIXTURE_DIR/dog-test2.txt"
printf '[%s]' "$(make_bead ga-test21 dog-test2 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test21"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test21" "T35: generic escalation — pane content doesn't match the permission-prompt signature"
log_contains "T35" "ga-test21: STUCK" "T35: log uses the generic STUCK marker, not BLOQUEADO-EM-PROMPT"
rm -f "$LOGS_FIXTURE_DIR/dog-test2.json" "$PEEK_FIXTURE_DIR/dog-test2.txt"

echo "T37: permission-prompt text present only in OLD scrollback (outside last 12 lines) → generic escalation (tail-anchoring holds)"
echo '{"sessions":[{"name":"dog-test3","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-test3 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash","input":{"command":"npm run build"}}]}]'
{
    echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"
    for i in $(seq 1 20); do echo "unrelated old scrollback line $i"; done
} > "$PEEK_FIXTURE_DIR/dog-test3.txt"
printf '[%s]' "$(make_bead ga-test22 dog-test3 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test22"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test22" "T37: generic escalation — prompt text is stale scrollback, not the pane's current tail"
rm -f "$LOGS_FIXTURE_DIR/dog-test3.json" "$PEEK_FIXTURE_DIR/dog-test3.txt"

echo "T38: pane shows 'requires confirmation' phrasing alone (no 'Do you want to proceed?' line) → still detected"
echo '{"sessions":[{"name":"dog-test4","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-test4 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash","input":{"command":"sudo apt-get update"}}]}]'
echo "Permission rule Bash(sudo:*) requires confirmation for this command." > "$PEEK_FIXTURE_DIR/dog-test4.txt"
printf '[%s]' "$(make_bead ga-test23 dog-test4 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test23"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente BLOQUEADO EM PROMPT (1 tecla resolve): ga-test23" "T38: 'requires confirmation' phrasing alone is also detected"
rm -f "$LOGS_FIXTURE_DIR/dog-test4.json" "$PEEK_FIXTURE_DIR/dog-test4.txt"

echo "T39: permission prompt confirmed but pending tool has no 'command' input field → falls back gracefully, doesn't break"
echo '{"sessions":[{"name":"dog-test5","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-test5 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Write","input":{"file_path":"/etc/hosts","content":"x"}}]}]'
echo "Do you want to proceed?  1. Yes  2. No" > "$PEEK_FIXTURE_DIR/dog-test5.txt"
printf '[%s]' "$(make_bead ga-test24 dog-test5 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test24"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente BLOQUEADO EM PROMPT (1 tecla resolve): ga-test24" "T39: detection still fires for a non-Bash tool (Write) pending approval"
log_contains "T39" "ga-test24: BLOQUEADO-EM-PROMPT" "T39: log line present even without a 'command' field"
rm -f "$LOGS_FIXTURE_DIR/dog-test5.json" "$PEEK_FIXTURE_DIR/dog-test5.txt"

# ── T40: assignee not found in the batch session-list scan, but a DIRECT ────
# transcript probe on the raw assignee confirms ADVANCING → suppressed
# (ga-v6ols core fix). This is the actual reported incident: `gc session
# list` (batch) failed to list a session that was, in fact, active — its
# transcript had been written 6 seconds before the false escalation. Before
# this fix, "not found in the batch scan" (live_session_name empty) skipped
# the transcript probe entirely and escalated unconditionally.
echo "T40: assignee not found in batch session-list, direct transcript probe confirms ADVANCING → suppressed (ga-v6ols)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"   # batch scan does NOT list this assignee at all
make_transcript_fixture dog-gav6ols-a 30       # yet its own transcript was written 30s ago
printf '[%s]' "$(make_bead ga-test25 dog-gav6ols-a 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test25"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test25" "T40: no mail — direct transcript probe overrides a stale/incomplete batch-absent verdict"
assert_absent "$ACTIONS" "notify" "T40: no notify — advancing suppresses"
log_contains "T40" "ga-v6ols" "T40: log shows the direct-probe contradiction note"
rm -f "$LOGS_FIXTURE_DIR/dog-gav6ols-a.json"

# ── T41: assignee not found in the batch scan, direct transcript probe ──────
# confirms FROZEN (resolvable transcript, stale mtime) → STILL escalates
# (ga-v6ols AC4: a batch "not found" verdict must not become a blanket
# suppression — only an AFFIRMATIVE contradiction changes the outcome).
# Also proves the improved diagnostic: the log now says CONGELADO via the
# direct probe instead of the old bare "n/d" default.
echo "T41: assignee not found in batch session-list, direct transcript probe confirms FROZEN → escalation still fires (ga-v6ols AC4)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-gav6ols-b 3600      # resolvable transcript, 1h stale
printf '[%s]' "$(make_bead ga-test26 dog-gav6ols-b 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test26"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test26" "T41: escalation still fires — batch-absent + confirmed-frozen (no false-negative regression)"
log_contains "T41" "CONGELADO" "T41: log shows CONGELADO via the direct probe (ga-v6ols), not the old bare n/d"
rm -f "$LOGS_FIXTURE_DIR/dog-gav6ols-b.json"

# ── T42: assignee not found in the batch scan, direct probe ALSO ────────────
# inconclusive (no transcript fixture at all) → escalation still fires
# unchanged (ga-v6ols non-regression — mirrors T15/T27 under this fix's own
# name for traceability: an unproven fallback probe must not silently start
# suppressing the daemon's core "genuinely absent" signal).
echo "T42: assignee not found in batch session-list, direct probe also inconclusive → escalation still fires (ga-v6ols non-regression)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test27 dog-gav6ols-c 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test27"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test27" "T42: escalation still fires — batch-absent + inconclusive probe, same as before this fix (AC1: não-encontrada alone still escalates)"

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
