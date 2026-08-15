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
if [ "$1" = "list" ]; then
    # Scan remaining args for "-l <label>" pairs instead of assuming -l is
    # exactly $2 — a fixed positional check broke the instant the real
    # callers gained --include-infra ahead of -l (ga-vm20x). Any other flag
    # (--include-infra, --json, ...) anywhere else in argv is simply skipped.
    shift
    while [ $# -gt 0 ]; do
        if [ "$1" = "-l" ] && [ -n "${2:-}" ]; then
            case "$2" in
                source-bead:*)
                    _bid="${2#source-bead:}"
                    _f="${GATE_MARKERS_DIR:-}/${_bid}.json"
                    if [ -n "${GATE_MARKERS_DIR:-}" ] && [ -f "$_f" ]; then
                        cat "$_f"
                    else
                        echo "[]"
                    fi
                    exit 0
                    ;;
                gate-run:*)
                    _rid="${2#gate-run:}"
                    _f="${GATE_VERDICTS_DIR:-}/${_rid}.json"
                    if [ -n "${GATE_VERDICTS_DIR:-}" ] && [ -f "$_f" ]; then
                        cat "$_f"
                    else
                        echo "[]"
                    fi
                    exit 0
                    ;;
            esac
        fi
        shift
    done
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
  "session nudge")
    # gc session nudge <target> <message> (ga-nrkh92)
    echo "nudge:${3:-}|${4:-}" >> "$ACTIONS_FILE"
    exit 0
    ;;
  "mail send")
    # $3 = recipient; subject after -s flag (unchanged format/behavior);
    # body after -m flag written to MAIL_BODY_FILE (ga-0xmxt: needed to
    # assert on escalation-body wording, which the subject-only ACTIONS log
    # can't capture). Scans ALL args now instead of breaking at -s, so both
    # flags are found regardless of order — existing subject-only assertions
    # are unaffected since the ACTIONS line format/content is identical.
    _recipient="${3:-mayor}"
    shift 3 2>/dev/null || true
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) echo "mail:${_recipient}|$2" >> "$ACTIONS_FILE"; shift 2 ;;
        -m) printf '%s' "$2" > "${MAIL_BODY_FILE:-/dev/null}"; shift 2 ;;
        *) shift ;;
      esac
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

# ── tmux shim (ga-nrkh92) ────────────────────────────────────────────────────
# has-session -t <name>            → exit 0/1 from $TMUX_SESSIONS_DIR/<name> presence
# list-panes -t <name> -F '...'    → prints the PID recorded in that fixture file
# send-keys -t <name> [--] <text>  → records "tmux-send-keys:<name>|<text>" to ACTIONS
cat > "$SHIM/tmux" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  has-session)
    _name="${3:-}"
    [ -f "${TMUX_SESSIONS_DIR:-/dev/null}/$_name" ] && exit 0
    exit 1
    ;;
  list-panes)
    _name="${3:-}"
    _f="${TMUX_SESSIONS_DIR:-}/$_name"
    [ -n "${TMUX_SESSIONS_DIR:-}" ] && [ -f "$_f" ] && cat "$_f" && exit 0
    exit 1
    ;;
  send-keys)
    shift
    _name=""
    _rest=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) _name="$2"; shift 2 ;;
        --) shift ;;
        *) _rest+=("$1"); shift ;;
      esac
    done
    echo "tmux-send-keys:${_name}|${_rest[*]}" >> "$ACTIONS_FILE"
    exit 0
    ;;
esac
exit 0
SHIM
chmod +x "$SHIM/tmux"

# ── helpers ───────────────────────────────────────────────────────────────────
run_script() {
    : > "$ACTIONS"
    GC_CITY_PATH="$WORK/city" \
    GC="$SHIM/gc" \
    BD="$SHIM/bd" \
    NOTIFY_BIN="$SHIM/notify" \
    TMUX_BIN="$SHIM/tmux" \
    GIT_BIN="${GIT_BIN_OVERRIDE:-git}" \
    BEADS_FIXTURE="${BEADS_FIXTURE:-}" \
    SESSIONS_FIXTURE="${SESSIONS_FIXTURE:-}" \
    SESSIONS_QUERY_FAIL="${SESSIONS_QUERY_FAIL:-0}" \
    LOGS_FIXTURE_DIR="${LOGS_FIXTURE_DIR:-}" \
    PEEK_FIXTURE_DIR="${PEEK_FIXTURE_DIR:-}" \
    GATE_MARKERS_DIR="${GATE_MARKERS_DIR:-}" \
    GATE_VERDICTS_DIR="${GATE_VERDICTS_DIR:-}" \
    TMUX_SESSIONS_DIR="${TMUX_SESSIONS_DIR:-}" \
    ACTIONS_FILE="$ACTIONS" \
    MAIL_BODY_FILE="$WORK/last_mail_body.txt" \
    STUCK_AGENT_SEC="${STUCK_AGENT_SEC:-1800}" \
    COOLDOWN_SEC="${COOLDOWN_SEC:-10800}" \
    TRANSCRIPT_FRESH_SEC="${TRANSCRIPT_FRESH_SEC:-1800}" \
    RESUME_GRACE_SEC="${RESUME_GRACE_SEC:-99999}" \
    IDLE_CPU_SAMPLE_SEC="${IDLE_CPU_SAMPLE_SEC:-1}" \
    ESCALATION_STORES="$WORK/city" \
    bash "$SCRIPT" 2>&1
}

# seed_resume_state <bead-id> [nudged_secs_ago] [session] (ga-nrkh92):
# pre-seeds the idle-resume state file as if a PRIOR pass already sent the
# interactive nudge <nudged_secs_ago> ago (default: far past
# RESUME_GRACE_SEC). Lets a single run_script call land past the grace
# period, so tests written before this feature existed — which assert
# immediate escalation for a live+frozen session — keep testing their OWN
# original suppression-layer signal instead of re-proving the two-phase
# resume ladder every time.
#
# [session] is OPTIONAL (ga-nrkh92 gate-fix, blocking issue 1): when given,
# also writes the session the nudge was recorded for (line 2 of $rf) — use
# this to simulate a stale nudge from a DIFFERENT, since-reassigned session
# (see T63). Omitted (the 13 pre-existing call sites), this writes the old
# single-line format, which the production mismatch check treats as "no
# evidence either way" and leaves the pre-existing elapsed-time behavior
# unchanged — those tests are not exercising the reassignment path at all.
seed_resume_state() {
    local bid="$1" age="${2:-999999}" sess="${3:-}"
    mkdir -p "$WORK/city/.gc/state/agent-idle-resume"
    python3 -c "import time; print(int(time.time()-$age))" > "$WORK/city/.gc/state/agent-idle-resume/$bid"
    [ -n "$sess" ] && printf '%s\n' "$sess" >> "$WORK/city/.gc/state/agent-idle-resume/$bid"
}

# seed_tmux_pane <session-name> <pid> (ga-nrkh92): registers the fixture the
# tmux shim's has-session/list-panes cases read — makes pane_pid_for_session
# resolve to a REAL pid the test controls (a backgrounded sleep for "idle",
# a backgrounded busy-loop for "not idle") instead of stubbing `ps` itself.
seed_tmux_pane() {
    local sess="$1" pid="$2"
    mkdir -p "$WORK/tmuxsessions"
    printf '%s' "$pid" > "$WORK/tmuxsessions/$sess"
    export TMUX_SESSIONS_DIR="$WORK/tmuxsessions"
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
GATE_VERDICTS_DIR="$WORK/gateverdicts"
mkdir -p "$LOGS_FIXTURE_DIR" "$WORK/transcripts" "$GATE_MARKERS_DIR" "$PEEK_FIXTURE_DIR" "$GATE_VERDICTS_DIR"
export BEADS_FIXTURE SESSIONS_FIXTURE LOGS_FIXTURE_DIR PEEK_FIXTURE_DIR GATE_MARKERS_DIR GATE_VERDICTS_DIR

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

# make_gate_run_fixture <bead-id> <run-id> (ga-lxk26)
# Registers an OPEN type:quality-gate-run/gate-status:running bead naming
# <bead-id> via source-bead — the SAME `-l source-bead:<id>` query
# make_gate_marker_fixture above feeds, just a different bead TYPE in the
# result set. This is what gate_reviewer_permission_prompt_session()'s hop 1
# looks for (real bd would return marker+run beads together for this query;
# tests that only need the run, not a marker too, can call this alone).
make_gate_run_fixture() {
    local bid="$1" run_id="$2"
    printf '[{"id":"%s","status":"open","labels":["type:quality-gate-run","source-bead:%s","gate-status:running"]}]' \
        "$run_id" "$bid" > "$GATE_MARKERS_DIR/$bid.json"
}

# make_gate_verdict_fixture <run-id> <verdict-bead-id> <reviewer-session> [status] (ga-lxk26)
# Registers an open (default) or closed type:quality-gate-verdict bead for
# `-l gate-run:<run-id>` — hop 2 of gate_reviewer_permission_prompt_session():
# .assignee is the reviewer's live session name, exactly as
# quality-gate-dispatcher.sh's assign_verdict_bead_verified() sets it.
make_gate_verdict_fixture() {
    local run_id="$1" vid="$2" reviewer="$3" status="${4:-open}"
    printf '[{"id":"%s","status":"%s","assignee":"%s","labels":["type:quality-gate-verdict","gate-run:%s","reviewer-index:1","verdict:pending"]}]' \
        "$vid" "$status" "$reviewer" "$run_id" > "$GATE_VERDICTS_DIR/$run_id.json"
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
seed_resume_state ga-test06   # ga-nrkh92: past-grace nudge already recorded — this test proves T14's ORIGINAL signal (transcript frozen despite live session), not the resume ladder itself (see T53+)
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test06" "T14: escalation fires — transcript frozen despite live session"
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
seed_resume_state ga-gate06   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-gate06" "T21: building bead with no gate signal still escalates (ga-hehi intact)"
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
seed_resume_state ga-test16   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test16" "T30: escalation fires — mid-tool-call is a real hang, not awaiting-human"
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
seed_resume_state ga-test18   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test18" "T32: escalation fires — last entry is tool_result, not an assistant awaiting-human shape"
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
seed_resume_state ga-test21   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test21" "T35: generic escalation — pane content doesn't match the permission-prompt signature"
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
seed_resume_state ga-test22   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test22" "T37: generic escalation — prompt text is stale scrollback, not the pane's current tail"
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
seed_resume_state ga-test26   # ga-nrkh92: see T14 note above (live_session_name is set here via the direct-probe path, ga-v6ols)
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test26" "T41: escalation still fires — batch-absent + confirmed-frozen (no false-negative regression)"
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

# ── T43-T46: bead EM GATE, but its ACTIVE gate-run's REVIEWER session is ────
# blocked on a permission dialog (ga-lxk26). The ga-n937 suppression above
# (T16-T18) is correct for "gate queue has no builder session" — but it ran
# BEFORE any check of the reviewer session ga-n937 itself never looked at,
# so a human silently blocking the WHOLE gate (Athos: "eu nem sabia que isso
# estava pendente em mim") produced total silence for 20+ minutes. These
# tests are the falsifiable acceptance criteria from the bug report:
#   T43 = FIXTURE (AC1): reviewer blocked → escalates + notify.
#   T44 = CONTROL: reviewer working normally → still suppressed (ga-n937 intact).
#   T45 = AC3: both shapes in the SAME pass, asserted to produce DIFFERENT
#         outputs from the SAME actions/log capture — "o coração do bug".
#   T46 = CONTROL: no gate-run dispatched yet (queue simply parked, the most
#         common real shape) → still suppressed; traceability companion to T16.

echo "T43: bead EM GATE, reviewer session pane confirms permission dialog → escalates + notify (ga-lxk26 AC1)"
echo '{"sessions":[{"name":"gate-reviewer-test1","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_gate_run_fixture ga-gatelock01 ga-wisp-testrun1
make_gate_verdict_fixture ga-wisp-testrun1 ga-verdict1 gate-reviewer-test1
make_transcript_fixture gate-reviewer-test1 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash","input":{"command":"rm -rf .gc-worktrees/ga-lxk26-reviewer-test"}}]}]'
{
    echo "Permission rule Bash(rm -rf:*) requires confirmation for this command."
    echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"
} > "$PEEK_FIXTURE_DIR/gate-reviewer-test1.txt"
printf '[%s]' "$(make_bead_json ga-gatelock01 "" 2200 '["ctx:ready","gate:queued"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock01"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente BLOQUEADO EM PROMPT (1 tecla resolve): ga-gatelock01" "T43: escalates despite EM GATE — reviewer confirmed blocked"
assert_contains "$ACTIONS" "notify" "T43: notify fires (imp07 notify-first honored)"
log_contains "T43" "ga-lxk26" "T43: log cites ga-lxk26 as the reason suppression was lifted"
log_contains "T43" "rm -rf .gc-worktrees/ga-lxk26-reviewer-test" "T43: log includes the reviewer's exact blocked command"
[ -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock01" ] && ok "T43: state file written (cooldown honored)" || bad "T43: missing state file — cooldown would not hold"
rm -f "$GATE_MARKERS_DIR/ga-gatelock01.json" "$GATE_VERDICTS_DIR/ga-wisp-testrun1.json" "$PEEK_FIXTURE_DIR/gate-reviewer-test1.txt" "$LOGS_FIXTURE_DIR/gate-reviewer-test1.json"

echo "T44: bead EM GATE, reviewer session working normally (no dialog) → still suppressed (ga-lxk26 CONTROL)"
echo '{"sessions":[{"name":"gate-reviewer-test2","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_gate_run_fixture ga-gatelock02 ga-wisp-testrun2
make_gate_verdict_fixture ga-wisp-testrun2 ga-verdict2 gate-reviewer-test2
{
    echo "Reading file src/foo.go..."
    echo "Running go test ./..."
} > "$PEEK_FIXTURE_DIR/gate-reviewer-test2.txt"
printf '[%s]' "$(make_bead_json ga-gatelock02 "" 2200 '["ctx:ready","gate:reviewing"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock02"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T44: no mail — reviewer pane shows no permission dialog"
assert_absent "$ACTIONS" "notify" "T44: no notify — same"
log_contains "T44" "SUPRIMINDO escalação (sem builder por design, ga-n937)" "T44: log preserves the ORIGINAL ga-n937 suppression message"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock02" ] && ok "T44: no state file (suppression is log-only, matches ga-n937 shape)" || bad "T44: unexpected state file on suppression"
rm -f "$GATE_MARKERS_DIR/ga-gatelock02.json" "$GATE_VERDICTS_DIR/ga-wisp-testrun2.json" "$PEEK_FIXTURE_DIR/gate-reviewer-test2.txt"

echo "T45: blocked-reviewer bead and normal-reviewer bead in the SAME pass → asserted DIFFERENT outcomes (ga-lxk26 AC3)"
echo '{"sessions":[{"name":"gate-reviewer-test3","state":"active"},{"name":"gate-reviewer-test4","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_gate_run_fixture ga-gatelock03 ga-wisp-testrun3
make_gate_verdict_fixture ga-wisp-testrun3 ga-verdict3 gate-reviewer-test3
make_gate_run_fixture ga-gatelock04 ga-wisp-testrun4
make_gate_verdict_fixture ga-wisp-testrun4 ga-verdict4 gate-reviewer-test4
{
    echo "Permission rule Bash(rm -rf:*) requires confirmation for this command."
    echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"
} > "$PEEK_FIXTURE_DIR/gate-reviewer-test3.txt"
{
    echo "Editing file bar.go..."
} > "$PEEK_FIXTURE_DIR/gate-reviewer-test4.txt"
printf '[%s,%s]' \
    "$(make_bead_json ga-gatelock03 "" 2200 '["ctx:ready","gate:queued"]')" \
    "$(make_bead_json ga-gatelock04 "" 2200 '["ctx:ready","gate:queued"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock03" "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock04"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente BLOQUEADO EM PROMPT (1 tecla resolve): ga-gatelock03" "T45: blocked-reviewer bead escalates"
assert_absent   "$ACTIONS" "ga-gatelock04" "T45: SAME pass — normal-reviewer bead produces NO action line at all (the difference the bug swallowed)"
log_contains "T45" "ga-gatelock03: EM GATE mas reviewer gate-reviewer-test3 BLOQUEADO-EM-PROMPT" "T45: log distinguishes the blocked bead"
log_contains "T45" "ga-gatelock04: bead.updated_at parado" "T45: log still shows the normal bead going through the unchanged ga-n937 path"
rm -f "$GATE_MARKERS_DIR/ga-gatelock03.json" "$GATE_VERDICTS_DIR/ga-wisp-testrun3.json" "$PEEK_FIXTURE_DIR/gate-reviewer-test3.txt"
rm -f "$GATE_MARKERS_DIR/ga-gatelock04.json" "$GATE_VERDICTS_DIR/ga-wisp-testrun4.json" "$PEEK_FIXTURE_DIR/gate-reviewer-test4.txt"

echo "T46: bead EM GATE, no gate-run yet (queue parked) → still suppressed (ga-lxk26 CONTROL, companion to T16)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead_json ga-gatelock05 "" 2200 '["ctx:ready","gate:queued"]')" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-gatelock05"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T46: no mail — no gate-run dispatched yet"
log_contains "T46" "SUPRIMINDO escalação (sem builder por design, ga-n937)" "T46: log preserves the ORIGINAL ga-n937 suppression message"

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

# ── T43-T51: pane_shows_active_child_process / pane_extract_token_count / ───
# tokens_rising_or_first_sample (ga-0xmxt). Falsifiable acceptance criteria
# from the bug: FIXTURE (active child / rising tokens → NOT escala),
# CONTROLE (dead process, no activity signals → CONTINUA escalando),
# CONTROLE 3 (the two cases produce DIFFERENT outputs, asserted together).

echo "T43: transcript frozen, pane shows live 'Running N shell command…' → suppressed (ga-0xmxt FIXTURE: active child process)"
echo '{"sessions":[{"name":"dog-ga0xmxt-1","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-ga0xmxt-1 3600
echo "⏺ Running 1 shell command…" > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-1.txt"
printf '[%s]' "$(make_bead ga-test28 dog-ga0xmxt-1 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test28"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test28" "T43: no mail — pane confirms an active child process (shell command running)"
assert_absent "$ACTIONS" "notify" "T43: no notify — active child process suppresses"
[ ! -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test28" ] && ok "T43: no escalation state written (suppression is log-only)" || bad "T43: unexpected state file written on suppression"
log_contains "T43" "processo filho ativo" "T43: log notes active-child-process suppression"
rm -f "$LOGS_FIXTURE_DIR/dog-ga0xmxt-1.json" "$PEEK_FIXTURE_DIR/dog-ga0xmxt-1.txt"

echo "T43b: transcript frozen, pane shows only the PAST-TENSE 'Ran N shell commands' summary (no live indicator) → generic escalation (no false match on completed-turn scrollback)"
echo '{"sessions":[{"name":"dog-ga0xmxt-1b","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-ga0xmxt-1b 3600
{
    echo "⏺ All done here."
    echo ""
    echo "  Ran 3 shell commands"
} > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-1b.txt"
printf '[%s]' "$(make_bead ga-test29 dog-ga0xmxt-1b 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test29"
seed_resume_state ga-test29   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test29" "T43b: escalation fires — 'Ran N shell commands' is a past-tense completed-turn summary, not live activity"
rm -f "$LOGS_FIXTURE_DIR/dog-ga0xmxt-1b.json" "$PEEK_FIXTURE_DIR/dog-ga0xmxt-1b.txt"

echo "T44: transcript frozen, pane shows a live token counter, FIRST sample for this bead → suppressed (grace pass, ga-0xmxt FIXTURE: rising tokens part 1)"
echo '{"sessions":[{"name":"dog-ga0xmxt-2","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-ga0xmxt-2 3600
echo "✽ Thinking… (12m 3s · ↓ 50.0k tokens)" > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-2.txt"
printf '[%s]' "$(make_bead ga-test30 dog-ga0xmxt-2 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test30" "$WORK/city/.gc/state/agent-stuck-escalation-tokens/ga-test30"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test30" "T44: no mail — first token sample for this bead is a grace pass"
log_contains "T44" "contador de tokens" "T44: log notes the token-counter suppression path"
[ "$(cat "$WORK/city/.gc/state/agent-stuck-escalation-tokens/ga-test30" 2>/dev/null)" = "50.0" ] && ok "T44: token baseline stored (50.0)" || bad "T44: token baseline not stored correctly"

echo "T45: SAME bead, second pass with a HIGHER token count → suppressed (ga-0xmxt FIXTURE: rising tokens part 2 — proven rising, not just first-sample)"
echo "✽ Thinking… (18m 40s · ↓ 80.0k tokens)" > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-2.txt"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test30" "T45: no mail — token count rose since last sample (50.0 → 80.0)"
[ "$(cat "$WORK/city/.gc/state/agent-stuck-escalation-tokens/ga-test30" 2>/dev/null)" = "80.0" ] && ok "T45: token baseline updated (80.0) — proves the comparison used the real prior sample, not just presence" || bad "T45: token baseline not updated"

echo "T45b: SAME bead, third pass with a LOWER token count than the previous sample → STILL suppressed (ga-0xmxt gate fix-attempt-2 CONTROLE: a decrease is ALSO life, not just a rise — this is the exact regression the gate caught: comparing current>prev falls through to escalation on a decrease, e.g. the pane's tail switching from the main turn's counter to a fresh subagent's own lower counter mid-turn)"
echo "✽ Thinking… (22m 10s · ↓ 45.0k tokens)" > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-2.txt"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor|Agente travado: ga-test30" "T45b: no mail — token count FELL since last sample (80.0 → 45.0) but a change in either direction proves the pane re-rendered, i.e. alive"
[ "$(cat "$WORK/city/.gc/state/agent-stuck-escalation-tokens/ga-test30" 2>/dev/null)" = "45.0" ] && ok "T45b: token baseline updated to the lower value (45.0) — proves != is being used, not > alone" || bad "T45b: token baseline not updated"

echo "T46: SAME bead, fourth pass with the SAME (flat) token count as T45b → escalation FINALLY fires (ga-0xmxt CONTROLE: a stale/frozen counter is not indefinitely suppressed; also proves the fix isn't >= — equality must NOT suppress)"
seed_resume_state ga-test30   # ga-nrkh92: this is the FIRST pass ga-test30 ever reaches the resume ladder (T44-T45b were all suppressed earlier, by the token-counter check) — see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test30" "T46: escalation fires — token count is flat (45.0 == 45.0), the one value that proves a frozen pane"
rm -f "$LOGS_FIXTURE_DIR/dog-ga0xmxt-2.json" "$PEEK_FIXTURE_DIR/dog-ga0xmxt-2.txt"

echo "T47: transcript frozen, NO active child process, NO token counter, session genuinely absent → escalation still fires (ga-0xmxt CONTROLE: real hang, no regression)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test31 dog-ga0xmxt-dead 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test31" "$WORK/city/.gc/state/agent-stuck-escalation-tokens/ga-test31"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test31" "T47: escalation fires — no session, no activity signals to suppress on"

echo "T48: CONTROLE 3 — active-work case and dead-process case produce DIFFERENT outcomes, asserted together in the same test"
echo '{"sessions":[{"name":"dog-ga0xmxt-4a","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-ga0xmxt-4a 3600
echo "⏺ Running 1 shell command…" > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-4a.txt"
printf '[%s]' "$(make_bead ga-test32 dog-ga0xmxt-4a 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test32"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
_caseA_mailed=0
grep -qF "mail:mayor|Agente travado: ga-test32" "$ACTIONS" && _caseA_mailed=1
rm -f "$LOGS_FIXTURE_DIR/dog-ga0xmxt-4a.json" "$PEEK_FIXTURE_DIR/dog-ga0xmxt-4a.txt"

echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test33 dog-ga0xmxt-4b 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test33"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
_caseB_mailed=0
grep -qF "mail:mayor|Agente travado: ga-test33" "$ACTIONS" && _caseB_mailed=1

if [ "$_caseA_mailed" != "$_caseB_mailed" ]; then
    ok "T48: active-work case (suppressed) and dead-process case (escalated) diverge as required"
else
    bad "T48: expected divergent outcomes — got caseA_mailed=$_caseA_mailed caseB_mailed=$_caseB_mailed (both same, detector is not discriminating)"
fi

echo "T49: 'Running…'/'↓ Nk tokens' text present only in OLD scrollback (outside the tail window) → generic escalation (tail-anchoring holds, mirrors T37)"
echo '{"sessions":[{"name":"dog-ga0xmxt-5","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-ga0xmxt-5 3600
{
    echo "⏺ Running 1 shell command…"
    echo "✽ Thinking… (5m 0s · ↓ 99.0k tokens)"
    for i in $(seq 1 25); do echo "unrelated old scrollback line $i"; done
} > "$PEEK_FIXTURE_DIR/dog-ga0xmxt-5.txt"
printf '[%s]' "$(make_bead ga-test34 dog-ga0xmxt-5 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test34" "$WORK/city/.gc/state/agent-stuck-escalation-tokens/ga-test34"
seed_resume_state ga-test34   # ga-nrkh92: see T14 note above
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-test34" "T49: generic escalation — activity text is stale scrollback, not the pane's current tail"
rm -f "$LOGS_FIXTURE_DIR/dog-ga0xmxt-5.json" "$PEEK_FIXTURE_DIR/dog-ga0xmxt-5.txt"

echo "T50: STUCK_AGENT_SEC unset entirely → script's own internal default is 3600s, not the old 1800s (ga-0xmxt threshold raise)"
_log_before=$(wc -l < "$WORK/city/.gc/logs/agent-stuck-escalation.log" 2>/dev/null || echo 0)
echo "[]" > "$BEADS_FIXTURE"
GC_CITY_PATH="$WORK/city" GC="$SHIM/gc" BD="$SHIM/bd" NOTIFY_BIN="$SHIM/notify" \
    BEADS_FIXTURE="$BEADS_FIXTURE" SESSIONS_FIXTURE="$SESSIONS_FIXTURE" \
    ESCALATION_STORES="$WORK/city" \
    bash "$SCRIPT" > /dev/null 2>&1
_new_lines="$(tail -n "+$((_log_before + 1))" "$WORK/city/.gc/logs/agent-stuck-escalation.log")"
printf '%s' "$_new_lines" | grep -qF "STUCK=3600s" && ok "T50: script's own default is 3600s when STUCK_AGENT_SEC is unset" || bad "T50: expected internal default STUCK=3600s in pass-start log line"

echo "T51: generic escalation mail body leads with confirmation, not destructive action (ga-0xmxt wording change)"
echo '{"sessions":[]}' > "$SESSIONS_FIXTURE"
printf '[%s]' "$(make_bead ga-test35 dog-ga0xmxt-wording 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test35"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente travado: ga-test35" "T51: escalation fires (dead process, sanity check)"
assert_contains "$WORK/last_mail_body.txt" "SÓ DEPOIS de confirmar" "T51: mail body requires peek confirmation before any destructive action"
assert_contains "$WORK/last_mail_body.txt" "raciocínio longo, subagente ativo" "T51: mail body flags the false-positive possibility up front"

# ── T52: BLOQUEADO-EM-PROMPT body must timestamp its evidence and make the
# nudge-ban conditional, not absolute (ga-swmbf). Measured live 2026-08-09:
# by the time a human acted on this exact mail, the pane snapshot was 57min
# stale and the session had already moved on — the body's old wording
# presented "o pane confirma um diálogo interativo aberto" as a PRESENT
# fact and unconditionally said "Não tente nudge aqui", so a reader who
# trusted the mail literally would send a blind keystroke into a live,
# unrelated turn. Same fixture as T34 (fresh dialog, confirmed at scan
# time) — the detection behavior (T34) must be unchanged; only the body's
# wording changes to require re-confirmation and to allow nudge once the
# dialog is gone.
echo "T52: BLOQUEADO-EM-PROMPT body requires reconfirmation before acting and does not unconditionally ban nudge (ga-swmbf)"
echo '{"sessions":[{"name":"dog-test6","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-test6 3600 '[{"type":"assistant","message":{"stop_reason":"tool_use"},"blocks":[{"type":"tool_use","name":"Bash","input":{"command":"rm -rf scripts/__pycache__"}}]}]'
{
    echo "Permission rule Bash(rm -rf:*) requires confirmation for this command."
    echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"
} > "$PEEK_FIXTURE_DIR/dog-test6.txt"
printf '[%s]' "$(make_bead ga-test36 dog-test6 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-test36"
: > "$ACTIONS"
STUCK_AGENT_SEC=1800 TRANSCRIPT_FRESH_SEC=1800 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente BLOQUEADO EM PROMPT (1 tecla resolve): ga-test36" "T52: differentiated escalation subject still fires (detection unchanged)"
assert_contains "$WORK/last_mail_body.txt" "RECONFIRME" "T52: body demands re-confirmation, not trust in the snapshot"
assert_contains "$WORK/last_mail_body.txt" "coletada às" "T52: body timestamps when the pane evidence was collected"
assert_absent "$WORK/last_mail_body.txt" "nudge aqui." "T52: nudge is no longer banned unconditionally"
assert_contains "$WORK/last_mail_body.txt" "nudge é a ferramenta certa" "T52: body allows nudge once the dialog is confirmed gone"
rm -f "$LOGS_FIXTURE_DIR/dog-test6.json" "$PEEK_FIXTURE_DIR/dog-test6.txt"

# ── T53-T56: ga-nrkh92 resume-then-escalate ladder (the core of this bead) ──
# T53 = first idle pass → resume attempted (nudge + tmux send-keys text+Enter
#       as SEPARATE calls), no escalation yet, resume state recorded.
# T54 = second pass within RESUME_GRACE_SEC → still waiting, no re-nudge.
# T55 = grace expires, still frozen, no response → escalates with the
#       differentiated subject (distinct from the plain "Agente travado" used
#       when there's no live session to even attempt a resume against).
# T56 = agent recovers (transcript advances again) before grace expires →
#       resume state cleared, never escalates.

echo "T53: first idle pass with a live session → resume attempted (nudge + tmux send-keys), no escalation yet (ga-nrkh92 critério a)"
echo '{"sessions":[{"name":"dog-idle53","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle53 3600
printf '[%s]' "$(make_bead ga-idle53 dog-idle53 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle53" "$WORK/city/.gc/state/agent-idle-resume/ga-idle53"
# Fake pane PID (need not be a real live process — pane_truly_idle's own
# tri-state treats a `ps`-unresolvable PID as UNKNOWN, which proceeds, not
# suppresses; see T59/T60 for the REAL-process idle/busy corroboration
# itself). This just needs `tmux has-session` to succeed so send_idle_resume
# actually attempts the tmux injection, not only the gc session nudge call.
seed_tmux_pane dog-idle53 999999999
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null
assert_absent  "$ACTIONS" "mail:mayor" "T53: no escalation on first idle pass — resume is attempted first"
assert_contains "$ACTIONS" "nudge:dog-idle53|" "T53: gc session nudge sent to the idle session"
assert_contains "$ACTIONS" "tmux-send-keys:dog-idle53|[AUTO-RESUME]" "T53: tmux send-keys injects the resume message text"
assert_contains "$ACTIONS" "tmux-send-keys:dog-idle53|Enter" "T53: tmux send-keys presses Enter as a SEPARATE call (send-keys without Enter only types, never submits)"
[ -f "$WORK/city/.gc/state/agent-idle-resume/ga-idle53" ] && ok "T53: resume state file recorded" || bad "T53: missing resume state file"
log_contains "T53" "RETOMADA enviada a dog-idle53" "T53: log records the resume attempt for audit (ga-nrkh92 critério d)"
rm -f "$LOGS_FIXTURE_DIR/dog-idle53.json"

echo "T54: second pass within RESUME_GRACE_SEC → still waiting, no re-nudge, no escalation"
echo '{"sessions":[{"name":"dog-idle53","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle53 3600
_prior_nudged_at="$(cat "$WORK/city/.gc/state/agent-idle-resume/ga-idle53")"
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T54: still no escalation — within grace"
assert_absent "$ACTIONS" "nudge:dog-idle53|" "T54: no re-nudge while still within grace"
assert_absent "$ACTIONS" "tmux-send-keys:dog-idle53|" "T54: no re-injection while still within grace"
[ "$(cat "$WORK/city/.gc/state/agent-idle-resume/ga-idle53")" = "$_prior_nudged_at" ] && ok "T54: nudged_at unchanged (not re-armed)" || bad "T54: nudged_at was rewritten unexpectedly"
log_contains "T54" "aguardando resposta" "T54: log notes still waiting for a response"
rm -f "$LOGS_FIXTURE_DIR/dog-idle53.json"

echo "T55: grace expires, still frozen, no response → escalates with the differentiated subject (ga-nrkh92 critério a/d)"
echo '{"sessions":[{"name":"dog-idle53","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle53 3600
seed_resume_state ga-idle53   # simulates the nudge above having been sent long ago
: > "$ACTIONS"
RESUME_GRACE_SEC=1 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-idle53" "T55: escalation fires after grace with no response"
assert_contains "$ACTIONS" "notify" "T55: notify also fires"
assert_contains "$WORK/last_mail_body.txt" "O daemon já tentou acordar esta sessão sozinho" "T55: mail body states a resume was already attempted (ga-nrkh92 critério d — different from the plain no-session body)"
rm -f "$LOGS_FIXTURE_DIR/dog-idle53.json"

echo "T56: agent recovers (transcript starts advancing) before grace expires → state cleared, never escalates"
echo '{"sessions":[{"name":"dog-idle56","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle56 3600
printf '[%s]' "$(make_bead ga-idle56 dog-idle56 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle56" "$WORK/city/.gc/state/agent-idle-resume/ga-idle56"
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null   # pass 1: nudges
[ -f "$WORK/city/.gc/state/agent-idle-resume/ga-idle56" ] && ok "T56: resume state recorded after first nudge" || bad "T56: missing resume state after first nudge"
make_transcript_fixture dog-idle56 30   # agent "wakes up" — transcript now fresh
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null   # pass 2: should see recovery
assert_absent "$ACTIONS" "mail:mayor" "T56: no escalation — agent recovered"
[ ! -f "$WORK/city/.gc/state/agent-idle-resume/ga-idle56" ] && ok "T56: resume state cleared on recovery" || bad "T56: stale resume state left behind after recovery"
log_contains "T56" "RESOLVIDO" "T56: log notes the recovery"
rm -f "$LOGS_FIXTURE_DIR/dog-idle56.json"

# ── T57-T58: gc.active_window metadata (ga-nrkh92 critério f) ───────────────
echo "T57: bead declares gc.active_window and NOW is OUTSIDE it → no nudge, no escalation (ga-nrkh92 critério f)"
echo '{"sessions":[{"name":"dog-idle57","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle57 3600
_now_hm="$(date +%H:%M)"
_now_min=$(( 10#${_now_hm%%:*} * 60 + 10#${_now_hm##*:} ))
_end_min=$(( (_now_min - 2 + 1440) % 1440 ))
_start_min=$(( (_end_min - 60 + 1440) % 1440 ))
_win="$(printf "%02d:%02d-%02d:%02d" $((_start_min/60)) $((_start_min%60)) $((_end_min/60)) $((_end_min%60)))"
printf '[{"id":"ga-idle57","title":"Test bead ga-idle57","assignee":"dog-idle57","status":"in_progress","issue_type":"feature","updated_at":"%s","labels":[],"metadata":{"gc.active_window":"%s"}}]' \
    "$(python3 -c "import time, datetime; e=time.time()-2200; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")" \
    "$_win" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle57" "$WORK/city/.gc/state/agent-idle-resume/ga-idle57"
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null
assert_absent "$ACTIONS" "mail:mayor" "T57: no escalation — outside declared active window"
assert_absent "$ACTIONS" "nudge:dog-idle57|" "T57: no nudge — outside declared active window"
[ ! -f "$WORK/city/.gc/state/agent-idle-resume/ga-idle57" ] && ok "T57: no resume state written — window check happens before any action" || bad "T57: resume state written despite being outside the window"
log_contains "T57" "fora da janela de operação declarada" "T57: log notes the window exemption"
rm -f "$LOGS_FIXTURE_DIR/dog-idle57.json"

echo "T58: bead declares gc.active_window and NOW is INSIDE it → normal resume behavior (ga-nrkh92 critério f, CONTROL)"
echo '{"sessions":[{"name":"dog-idle58","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle58 3600
_now_hm="$(date +%H:%M)"
_now_min=$(( 10#${_now_hm%%:*} * 60 + 10#${_now_hm##*:} ))
_start_min=$(( (_now_min - 30 + 1440) % 1440 ))
_end_min=$(( (_now_min + 30) % 1440 ))
_win="$(printf "%02d:%02d-%02d:%02d" $((_start_min/60)) $((_start_min%60)) $((_end_min/60)) $((_end_min%60)))"
printf '[{"id":"ga-idle58","title":"Test bead ga-idle58","assignee":"dog-idle58","status":"in_progress","issue_type":"feature","updated_at":"%s","labels":[],"metadata":{"gc.active_window":"%s"}}]' \
    "$(python3 -c "import time, datetime; e=time.time()-2200; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")" \
    "$_win" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle58" "$WORK/city/.gc/state/agent-idle-resume/ga-idle58"
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null
assert_contains "$ACTIONS" "nudge:dog-idle58|" "T58: nudge still fires — inside the declared window"
rm -f "$LOGS_FIXTURE_DIR/dog-idle58.json"

# ── T59-T60: pane_truly_idle TIME-based corroboration (ga-nrkh92 critério b) ─
# Uses REAL backgrounded processes (not a stubbed `ps`) so the sampling logic
# is proven against the actual primitive, not a mock of it.
echo "T59: pane_truly_idle CONFIRMS busy (real CPU-consuming process, TIME changes across the sample) → no nudge sent (ga-nrkh92 critério b — %cpu doesn't discriminate but TIME does)"
echo '{"sessions":[{"name":"dog-idle59","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle59 3600
printf '[%s]' "$(make_bead ga-idle59 dog-idle59 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle59" "$WORK/city/.gc/state/agent-idle-resume/ga-idle59"
bash -c 'x=0; end=$((SECONDS+5)); while [ $SECONDS -lt $end ]; do x=$((x+1)); done' &
_busy_pid=$!
seed_tmux_pane dog-idle59 "$_busy_pid"
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 IDLE_CPU_SAMPLE_SEC=1 run_script > /dev/null
wait "$_busy_pid" 2>/dev/null
assert_absent "$ACTIONS" "nudge:dog-idle59|" "T59: no nudge — pane confirmed NOT idle (TIME accumulated during the sample)"
assert_absent "$ACTIONS" "mail:mayor" "T59: no escalation either — this session is genuinely busy"
log_contains "T59" "TIME acumulado do pane mudou" "T59: log notes the TIME-based busy confirmation"
unset TMUX_SESSIONS_DIR
rm -f "$LOGS_FIXTURE_DIR/dog-idle59.json"

echo "T60: pane_truly_idle CONFIRMS idle (real sleeping process, TIME unchanged across the sample) → nudge proceeds (ga-nrkh92 critério b, positive control)"
echo '{"sessions":[{"name":"dog-idle60","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle60 3600
printf '[%s]' "$(make_bead ga-idle60 dog-idle60 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle60" "$WORK/city/.gc/state/agent-idle-resume/ga-idle60"
sleep 30 &
_idle_pid=$!
seed_tmux_pane dog-idle60 "$_idle_pid"
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 IDLE_CPU_SAMPLE_SEC=1 run_script > /dev/null
kill "$_idle_pid" 2>/dev/null; wait "$_idle_pid" 2>/dev/null
assert_contains "$ACTIONS" "nudge:dog-idle60|" "T60: nudge fires — pane confirmed genuinely idle (TIME identical across the sample)"
unset TMUX_SESSIONS_DIR
rm -f "$LOGS_FIXTURE_DIR/dog-idle60.json"

# ── T61-T62: has_unique_work via git cherry, not ref-merged (ga-nrkh92 ──────
# critério e — see memory branch-not-merged-is-not-proof-of-pending-work-
# use-git-cherry). T62 is THE wa-x92yd regression test: a branch whose ref
# is genuinely NOT an ancestor of origin/main (a naive merge-base/--merged
# check says "not merged, at risk") but whose PATCH is already upstream via
# a different commit (git cherry says "-") must NOT be reported as work at
# risk.
echo "T61: has_unique_work — real repo with a commit NOT in origin/main → escalation body states the count (ga-nrkh92 critério e)"
_gitrepo="$WORK/gitrepo61"
mkdir -p "$_gitrepo"
git -C "$_gitrepo" init -q
git -C "$_gitrepo" config user.email t@t.com
git -C "$_gitrepo" config user.name t
echo base > "$_gitrepo/f.txt"; git -C "$_gitrepo" add f.txt; git -C "$_gitrepo" commit -qm base
_base_sha="$(git -C "$_gitrepo" rev-parse HEAD)"
git -C "$_gitrepo" update-ref refs/remotes/origin/main "$_base_sha"
echo unique >> "$_gitrepo/f.txt"; git -C "$_gitrepo" commit -qam "unique local change"
echo '{"sessions":[{"name":"dog-idle61","state":"active","work_dir":"'"$_gitrepo"'"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle61 3600
printf '[%s]' "$(make_bead ga-idle61 dog-idle61 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle61"
seed_resume_state ga-idle61
: > "$ACTIONS"
RESUME_GRACE_SEC=1 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-idle61" "T61: escalation fires"
assert_contains "$WORK/last_mail_body.txt" "1 commit(s) só nesta sessão" "T61: mail body reports the real unique-commit count via git cherry"
rm -f "$LOGS_FIXTURE_DIR/dog-idle61.json"

echo "T62: has_unique_work — branch NOT an ancestor of origin/main by ref, but its patch is ALREADY upstream via a different commit (git cherry '-') → body says NO risk, not a ref-based false alarm (ga-nrkh92 critério e, the wa-x92yd regression)"
_gitrepo="$WORK/gitrepo62"
mkdir -p "$_gitrepo"
git -C "$_gitrepo" init -q
git -C "$_gitrepo" config user.email t@t.com
git -C "$_gitrepo" config user.name t
echo base > "$_gitrepo/f.txt"; git -C "$_gitrepo" add f.txt; git -C "$_gitrepo" commit -qm base
_base_sha="$(git -C "$_gitrepo" rev-parse HEAD)"
echo change >> "$_gitrepo/f.txt"; git -C "$_gitrepo" commit -qam "same-patch-content"
_local_sha="$(git -C "$_gitrepo" rev-parse HEAD)"
# Simulate the SAME patch having landed on origin/main via a DIFFERENT commit
# (e.g. a squash-merge from another slice, as in the real wa-x92yd/wa-si81e
# incident): cherry-pick onto a throwaway branch from the same base, forcing
# a different SHA via an explicit committer/author date override (otherwise
# a fast, conflict-free cherry-pick can reproduce a byte-identical commit and
# this fixture would degenerate into testing plain ref-ancestry instead).
git -C "$_gitrepo" checkout -q -b other-slice "$_base_sha"
GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" \
    git -C "$_gitrepo" cherry-pick "$_local_sha" >/dev/null
git -C "$_gitrepo" update-ref refs/remotes/origin/main other-slice
git -C "$_gitrepo" checkout -q -
_cherry_check="$(git -C "$_gitrepo" cherry origin/main HEAD)"
_naive_ancestor="no"
git -C "$_gitrepo" merge-base --is-ancestor origin/main HEAD 2>/dev/null && _naive_ancestor="yes"
printf '%s' "$_cherry_check" | grep -q '^-' && ok "T62 fixture: git cherry correctly says '-' (already upstream)" || bad "T62 fixture setup failed — git cherry did not report '-' (got: $_cherry_check)"
[ "$_naive_ancestor" = "no" ] && ok "T62 fixture: naive ref-ancestor check says NOT merged — this is the false-alarm shape the fix must not reproduce" || bad "T62 fixture degenerate — origin/main IS a plain ancestor, doesn't exercise the ref-vs-patch-id distinction"
echo '{"sessions":[{"name":"dog-idle62","state":"active","work_dir":"'"$_gitrepo"'"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle62 3600
printf '[%s]' "$(make_bead ga-idle62 dog-idle62 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle62"
seed_resume_state ga-idle62
: > "$ACTIONS"
RESUME_GRACE_SEC=1 run_script > /dev/null
assert_contains "$ACTIONS" "mail:mayor|Agente ocioso nao respondeu a retomada: ga-idle62" "T62: escalation still fires (the session itself IS unresponsive — only the unique-work CLAIM changes)"
assert_contains "$WORK/last_mail_body.txt" "nenhum — HEAD já está inteiramente em origin/main" "T62: body correctly reports NO unique work via git cherry (patch-id), even though the branch ref itself was never an ancestor of origin/main"
rm -f "$LOGS_FIXTURE_DIR/dog-idle62.json"

# ── T63-T64: gate-fix regression tests (ga-nrkh92, gate verdict on ─────────
# bf1f03e46 — both were gaps the T53-T62 suite above did not cover) ────────

# T63 = blocking issue 1: $rf keyed only by bead_id, with no session
# identity, misreads a nudge sent to an OLD (since-reassigned) session as
# proof the CURRENT session was already nudged — skipping straight to
# "grace expired" and escalating on the new session's very first idle
# observation, without this daemon ever attempting to wake it.
echo "T63: resume state recorded for a DIFFERENT (reassigned-away) session → treated as first nudge for the CURRENT session, not an expired grace (ga-nrkh92 gate-fix, blocking issue 1)"
echo '{"sessions":[{"name":"dog-idle63","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle63 3600
printf '[%s]' "$(make_bead ga-idle63 dog-idle63 2200)" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle63" "$WORK/city/.gc/state/agent-idle-resume/ga-idle63"
# Simulate: an EARLIER session (dog-oldsess63 — since killed/respawned or
# manually reassigned away) was nudged long ago and never responded. The
# bead is now live under dog-idle63, which this daemon has never nudged.
seed_resume_state ga-idle63 999999 dog-oldsess63
seed_tmux_pane dog-idle63 999999998
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null
assert_absent  "$ACTIONS" "mail:mayor" "T63: no escalation — the CURRENT session was never actually nudged, despite the stale record for the old session"
assert_contains "$ACTIONS" "nudge:dog-idle63|" "T63: fresh nudge sent to the CURRENT session"
assert_contains "$ACTIONS" "tmux-send-keys:dog-idle63|[AUTO-RESUME]" "T63: tmux send-keys also injects into the current session"
[ "$(sed -n '2p' "$WORK/city/.gc/state/agent-idle-resume/ga-idle63")" = "dog-idle63" ] && ok "T63: resume state now records the CURRENT session" || bad "T63: resume state still references the stale session"
log_contains "T63" "bead foi reatribuido" "T63: log notes the reassignment detection"
rm -f "$LOGS_FIXTURE_DIR/dog-idle63.json"

# T64 = blocking issue 2: now_outside_active_window's format check bounds
# each hour DIGIT independently ([0-2][0-9] accepts 20-29), not the
# two-digit VALUE. A window entirely past 23:59 (e.g. "24:30-25:00") passes
# that check but can never match the real clock — the function then ALWAYS
# returns "outside", permanently suppressing resume+escalation, the
# opposite of its documented fail-OPEN contract for malformed input.
echo "T64: gc.active_window with an out-of-range hour (24:30-25:00) fails OPEN — does not permanently suppress resume/escalation (ga-nrkh92 gate-fix, blocking issue 2)"
echo '{"sessions":[{"name":"dog-idle64","state":"active"}]}' > "$SESSIONS_FIXTURE"
make_transcript_fixture dog-idle64 3600
printf '[{"id":"ga-idle64","title":"Test bead ga-idle64","assignee":"dog-idle64","status":"in_progress","issue_type":"feature","updated_at":"%s","labels":[],"metadata":{"gc.active_window":"24:30-25:00"}}]' \
    "$(python3 -c "import time, datetime; e=time.time()-2200; print(datetime.datetime.utcfromtimestamp(e).strftime('%Y-%m-%dT%H:%M:%SZ'))")" > "$BEADS_FIXTURE"
rm -f "$WORK/city/.gc/state/agent-stuck-escalation/ga-idle64" "$WORK/city/.gc/state/agent-idle-resume/ga-idle64"
seed_tmux_pane dog-idle64 999999997
: > "$ACTIONS"
RESUME_GRACE_SEC=99999 run_script > /dev/null
assert_contains "$ACTIONS" "nudge:dog-idle64|" "T64: nudge still fires — an out-of-range hour must fail OPEN like any other malformed window (pre-fix: [0-2][0-9] accepted hours 20-29 and this window would ALWAYS read as outside, permanently suppressing)"
assert_absent "$WORK/city/.gc/logs/agent-stuck-escalation.log" "XXXNEVERMATCHXXX" "T64: sanity — log file itself is readable (guards against a silently-empty log masking a false pass above)"
log_contains "T64" "RETOMADA enviada a dog-idle64" "T64: log confirms the resume path actually ran (window did not suppress it)"
rm -f "$LOGS_FIXTURE_DIR/dog-idle64.json"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
