#!/usr/bin/env bash
# funnel-flow-healer.selftest.sh — drives the PURE decision core (decide_action) and
# the real-world dispatch (handle_signature) with stubbed inputs. Makes ZERO real
# launchctl / gc mail / bd / notify calls — all are stubbed. No daemons are touched.
set -uo pipefail

# ga-qb6yg gate-feedback: default resolves relative to THIS file's own location,
# matching every other *.selftest.sh sibling in this dir (dolt-hang-watchdog,
# gate-health-monitor, inflight-reclaim-guard, production-drift-guard,
# log-reaper, worktree-reaper, transcript-reaper — verified 7/7). The old
# hardcoded /tmp default doesn't exist on a normal checkout and nothing in the
# repo ever set HEALER before invoking this file, so it failed closed on every
# run (source failed, decide_action/handle_signature left undefined, every
# assertion then compared '' against expected — PASS=3 FAIL=20 of 23,
# unconditionally) for a reason that has nothing to do with the decision logic
# it exists to test. An always-red selftest trains whoever watches it to stop
# reading it, which is how a real regression later slips through.
HEALER="${HEALER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/funnel-flow-healer.sh}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1 (got '$2' want '$3')"; fi; }

# Isolated state + log dirs per run.
WORK="$(mktemp -d /tmp/ffh-selftest.XXXXXX)"
export FLOW_HEALER_STATE_DIR="$WORK/state"
export GC_CITY="$WORK/city"
mkdir -p "$FLOW_HEALER_STATE_DIR" "$GC_CITY/.gc/logs"
# Redirect the JSONL away from prod by pointing logs into the work city.
# (the script writes to $CITY/.gc/logs; GC_CITY override above handles it)

# Knobs (small numbers for fast deterministic tests).
export STALL_CONFIRM_STRIKES=2
export REMEDIATION_COOLDOWN=1800
export MAX_REMEDIATIONS=3
export ESCALATION_NTFY_WINDOW=7200
export FLOW_HEALER_UID=501

# ga-nixb58: the flow-authority marker path defaults to $CITY/.gc/runtime/flow-authority.json and
# honours an ambient FFF_FLOW_AUTHORITY_FILE. Pin it (and the defer knobs) inside $WORK BEFORE
# sourcing so section (h)/(i) can never write a fixture into the LIVE marker, whatever the caller
# exported.
export FFF_FLOW_AUTHORITY_FILE="$WORK/flow-authority.json"
export FFF_FLOW_AUTHORITY_DEFER=1
export FFF_TSW_SUPPRESS_SIGS="gate pilot"

# Source the script's functions WITHOUT running run().
export FLOW_HEALER_SOURCE_ONLY=1
export FLOW_HEALER_NOW=1000000          # fixed clock (script copies into $NOW at source)
# shellcheck disable=SC1090
source "$HEALER"

reset_state() { rm -rf "$FLOW_HEALER_STATE_DIR"; mkdir -p "$FLOW_HEALER_STATE_DIR"; }

echo "== (a) confirmed auto-refino stall → KICKSTART on 2nd consecutive stalled run =="
reset_state
ENABLED=1
r1=$(decide_action "auto-refino" 1)      # strike 1 — not yet confirmed
r2=$(decide_action "auto-refino" 1)      # strike 2 — confirmed → kickstart
eq "run1 = NONE (1 strike, unconfirmed)" "$r1" "NONE"
eq "run2 = KICKSTART (confirmed)" "$r2" "KICKSTART"
eq "remediations recorded = 1" "$(cat "$FLOW_HEALER_STATE_DIR/auto-refino.remediations")" "1"

echo "== (b) transient blip (single strike) → NO action =="
reset_state
b1=$(decide_action "gate" 1)             # 1 strike only
eq "single strike = NONE" "$b1" "NONE"
# next run NOT stalled → strikes cleared, still no action
b2=$(decide_action "gate" 0)
eq "recovery run = NONE" "$b2" "NONE"
eq "strikes cleared to 0" "$(cat "$FLOW_HEALER_STATE_DIR/gate.strikes" 2>/dev/null || echo 0)" "0"

echo "== (c) cooldown respected (kickstart, then stalled again within cooldown → NONE) =="
reset_state
decide_action "pilot" 1 >/dev/null       # strike 1
k=$(decide_action "pilot" 1)             # strike 2 → kickstart (sets last_kick=NOW)
eq "kickstart fired" "$k" "KICKSTART"
# still stalled, same NOW (well within cooldown) → must HOLD
c=$(decide_action "pilot" 1)
eq "within cooldown = NONE" "$c" "NONE"
eq "remediations still 1 (no 2nd kick during cooldown)" "$(cat "$FLOW_HEALER_STATE_DIR/pilot.remediations")" "1"
# advance clock past cooldown → kickstart again allowed
NOW=$((1000000 + 1801))
c2=$(decide_action "pilot" 1)
eq "past cooldown = KICKSTART" "$c2" "KICKSTART"
eq "remediations now 2" "$(cat "$FLOW_HEALER_STATE_DIR/pilot.remediations")" "2"
NOW=1000000

echo "== (d) MAX_REMEDIATIONS exceeded → ESCALATE (mayor), not kickstart =="
reset_state
# Pre-seed state to MAX_REMEDIATIONS already done, confirmed, cooldown elapsed.
echo 5 > "$FLOW_HEALER_STATE_DIR/refino-gate.strikes"
echo 3 > "$FLOW_HEALER_STATE_DIR/refino-gate.remediations"   # == MAX_REMEDIATIONS
echo 0 > "$FLOW_HEALER_STATE_DIR/refino-gate.last_kick"
e=$(decide_action "refino-gate" 1)
eq "bound reached = ESCALATE" "$e" "ESCALATE"
eq "escalated_at stamped" "$(cat "$FLOW_HEALER_STATE_DIR/refino-gate.escalated_at")" "1000000"
# subsequent stalled run, still within NTFY window → NONE (mayor owns it)
e2=$(decide_action "refino-gate" 1)
eq "post-escalate within window = NONE" "$e2" "NONE"
# advance past NTFY window → single NTFY
NOW=$((1000000 + 7201))
e3=$(decide_action "refino-gate" 1)
eq "persisted past window = NTFY" "$e3" "NTFY"
# and only ONCE
e4=$(decide_action "refino-gate" 1)
eq "NTFY only once = NONE" "$e4" "NONE"
NOW=1000000

echo "== (e) FLOW_HEALER_ENABLED=0 → census only, never remediate =="
reset_state
ENABLED=0
d1=$(decide_action "auto-refino" 1)
d2=$(decide_action "auto-refino" 1)      # even confirmed → still NONE
eq "disabled run1 = NONE" "$d1" "NONE"
eq "disabled run2 (confirmed) = NONE" "$d2" "NONE"
eq "no remediation recorded" "$(cat "$FLOW_HEALER_STATE_DIR/auto-refino.remediations" 2>/dev/null || echo 0)" "0"
ENABLED=1

echo "== (f) healthy flow (not stalled) → NO action =="
reset_state
h1=$(decide_action "gate" 0)
h2=$(decide_action "auto-refino" 0)
eq "healthy gate = NONE" "$h1" "NONE"
eq "healthy auto-refino = NONE" "$h2" "NONE"

echo "== (g) end-to-end handle_signature with STUBBED side-effects (zero real calls) =="
reset_state
CALLS="$WORK/calls.log"; : > "$CALLS"
stub_launchctl() { echo "launchctl $*" >> "$CALLS"; return 0; }
stub_mail()      { echo "mail subj=$1" >> "$CALLS"; return 0; }
stub_notify()    { echo "notify title=$1" >> "$CALLS"; return 0; }
export -f stub_launchctl stub_mail stub_notify
export FLOW_HEALER_FAKE_LAUNCHCTL=stub_launchctl
export FLOW_HEALER_FAKE_MAIL=stub_mail
export FLOW_HEALER_FAKE_NOTIFY=stub_notify
# demand=1, frozen via fake mtime way in the past for the auto-refino log basename.
export FLOW_HEALER_FAKE_MTIME_AUTO_REFINO_DISPATCHER_LOG=0   # epoch 0 → ancient → frozen
# run1: strike, no action; run2: confirmed → KICKSTART → stub_launchctl called.
handle_signature "auto-refino" "com.gascity.auto-refino-dispatcher" \
   "/x/auto-refino-dispatcher.log" 15 1 "census-blob" >/dev/null
handle_signature "auto-refino" "com.gascity.auto-refino-dispatcher" \
   "/x/auto-refino-dispatcher.log" 15 1 "census-blob" >/dev/null
if grep -q "launchctl kickstart -k gui/501/com.gascity.auto-refino-dispatcher" "$CALLS"; then
  ok "handle_signature dispatched real-looking kickstart through stub"
else
  bad "expected stubbed kickstart call; calls=$(cat "$CALLS")"
fi
# Confirm NO real binaries were invoked: the only recorded calls are stubs.
# ga-qb6yg self-review before resubmission: `grep -qv` on an EMPTY $CALLS also
# finds zero non-stub lines, so this passed identically whether the stubs
# fired correctly or the stub seam was broken entirely (env var typo, sourcing
# failure) and never invoked FLOW_HEALER_FAKE_* at all — the exact
# "always-green trains you to stop reading it" failure this file's own header
# already calls out for a different bug. Require at least one recorded call.
if [ -s "$CALLS" ] && ! grep -qvE '^(launchctl|mail|notify) ' "$CALLS" 2>/dev/null; then
  ok "only stubbed side-effects recorded (zero real launchctl/gc/bd/notify)"
else
  bad "expected only stub calls recorded, got: calls=$(cat "$CALLS" 2>/dev/null || echo '(empty)')"
fi
unset FLOW_HEALER_FAKE_LAUNCHCTL FLOW_HEALER_FAKE_MAIL FLOW_HEALER_FAKE_NOTIFY FLOW_HEALER_FAKE_MTIME_AUTO_REFINO_DISPATCHER_LOG

echo "== (h) flow-authority marker parsing (imp14): a Python-float expires_at must not abort (ga-nixb58) =="
# The marker path comes from env and a selftest must never touch the LIVE marker: it is pinned
# inside $WORK above - refuse to write a single marker if that ever stops being true.
case "$FLOW_AUTHORITY_FILE" in
  "$WORK"/*) ok "marker path is isolated inside \$WORK" ;;
  *) bad "marker path escapes \$WORK ($FLOW_AUTHORITY_FILE) - refusing to write markers"
     rm -rf "$WORK"; exit 1 ;;
esac

# probe_authority: run _tsw_flow_authority_active in a SUBSHELL and report how it ended.
#   "rc=<n>" -> it returned normally with status n
#   ""       -> the shell was ABORTED inside it (the ga-nixb58 failure: a failed $(( )) expansion
#               abandons the command, so the echo below never runs). Without this sentinel an
#               abort exits 1 and is indistinguishable from a legitimate "not active".
probe_authority() { ( _tsw_flow_authority_active; echo "rc=$?" ) 2>"$WORK/probe.err"; }
write_marker()    { printf '%s\n' "$1" > "$FLOW_AUTHORITY_FILE"; }
marker_at()       { printf '{"authority":"throughput-stall-watchdog","expires_at":%s}' "$1"; }
ev_count()        { touch "$JSONL"; grep -c '"event":"tsw-authority-unreadable"' "$JSONL" || true; }
real_now=$(date +%s)
FUT=$((real_now + 3600)); PAST=$((real_now - 3600))    # the function reads the real clock, not $NOW

ev0=$(ev_count)
write_marker "$(marker_at "$FUT")"
eq "integer expires_at in the future = active" "$(probe_authority)" "rc=0"
write_marker "$(marker_at "$FUT.938316")"
eq "FLOAT expires_at in the future = active (the shape the Python writers emit)" "$(probe_authority)" "rc=0"
write_marker "$(marker_at "$PAST.938316")"
eq "FLOAT expires_at in the past = expired (returns, does not abort)" "$(probe_authority)" "rc=1"
write_marker "$(marker_at "$PAST")"
eq "integer expires_at in the past = expired" "$(probe_authority)" "rc=1"
write_marker '{"escalated_at": 1750000000.0, "dimension": "x", "authority": "approved-state-reconciler", "expires_at": 1750003600.0}'
eq "the fixture shape found in the live marker (float, long expired) = expired" "$(probe_authority)" "rc=1"
write_marker "$(marker_at "\"$FUT.5\"")"
eq "float carried as a JSON string, in the future = active (Python float() accepts it too)" "$(probe_authority)" "rc=0"
rm -f "$FLOW_AUTHORITY_FILE"
eq "no marker file = not active" "$(probe_authority)" "rc=1"
write_marker "$(marker_at "$FUT.5")"
FFF_FLOW_AUTHORITY_DEFER=0
eq "defer switched off = not active even with a live marker" "$(probe_authority)" "rc=1"
FFF_FLOW_AUTHORITY_DEFER=1
eq "readable / absent markers raise no unreadable event" "$(ev_count)" "$ev0"

# An UNREADABLE marker is NOT active (FFF acts on its own, like PTH/PSW) - but never an abort and never silent.
unreadable_case() {  # unreadable_case <label> <raw marker text>
  local label="$1" before after
  before=$(ev_count); write_marker "$2"
  eq "$label: returns not-active, no abort" "$(probe_authority)" "rc=1"
  after=$(ev_count)
  eq "$label: the doubt is logged as an event" "$after" "$((before + 1))"
  if grep -q 'flow-authority marker unreadable' "$WORK/probe.err"; then ok "$label: and on stderr"; else bad "$label: nothing on stderr"; fi
}
unreadable_case "garbage, not JSON"    'this is not json'
unreadable_case "empty marker"         ''
unreadable_case "expires_at is text"   '{"expires_at": "soon"}'
unreadable_case "expires_at missing"   '{"authority": "throughput-stall-watchdog"}'
unreadable_case "expires_at null"      '{"expires_at": null}'
unreadable_case "expires_at is a list" '{"expires_at": [1789000000, 2]}'
unreadable_case "expires_at negative"  '{"expires_at": -5}'
unreadable_case "expires_at boolean"   '{"expires_at": true}'

# The awk fallback (jq missing): a PATH that has awk/tr/head/date but no jq. `hash -r` because the
# parent shell may have jq cached in its command hash table, which the subshell inherits.
NOJQ_BIN="$WORK/nojq-bin"; mkdir -p "$NOJQ_BIN"
for t in awk tr head date; do ln -sf "$(command -v "$t")" "$NOJQ_BIN/$t"; done
probe_authority_nojq() { ( hash -r; PATH="$NOJQ_BIN"; _tsw_flow_authority_active; echo "rc=$?" ) 2>"$WORK/probe.err"; }
if ( hash -r; PATH="$NOJQ_BIN"; command -v jq >/dev/null 2>&1 ); then
  bad "jq is still visible on the restricted PATH - the awk fallback is not being exercised"
else
  write_marker "$(marker_at "$FUT")"
  eq "no jq: integer expires_at in the future = active" "$(probe_authority_nojq)" "rc=0"
  write_marker "$(marker_at "$FUT.938316")"
  eq "no jq: FLOAT expires_at in the future = active" "$(probe_authority_nojq)" "rc=0"
  write_marker "$(marker_at "$PAST.938316")"
  eq "no jq: FLOAT expires_at in the past = expired" "$(probe_authority_nojq)" "rc=1"
  before=$(ev_count); write_marker '{"expires_at": "soon"}'
  eq "no jq: text expires_at = not active, no abort" "$(probe_authority_nojq)" "rc=1"
  eq "no jq: and the doubt is logged" "$(ev_count)" "$((before + 1))"
fi

echo "== (i) end-to-end: a float marker must not abandon run() (ga-nixb58) =="
export FLOW_HEALER_FAKE_LAUNCHCTL=stub_launchctl FLOW_HEALER_FAKE_MAIL=stub_mail FLOW_HEALER_FAKE_NOTIFY=stub_notify
export FLOW_HEALER_FAKE_MTIME_GATE_LOG=0 FLOW_HEALER_FAKE_MTIME_PILOT_LOG=0    # epoch 0 => ancient => frozen
# run_two mimics run(): the gate signature, then the pilot one, then a sentinel. Both signatures
# are in FFF_TSW_SUPPRESS_SIGS, so both consult the marker once they decide to act.
run_two() {
  handle_signature "gate"  "com.gascity.quality-gate-dispatcher" "/x/gate.log"  10 1 "census-blob"
  handle_signature "pilot" "com.gascity.pilot"                    "/x/pilot.log" 15 1 "census-blob"
  echo "reached-end"
}
seed_confirmed_gate() {   # gate already has 5 strikes, so its next decision is KICKSTART (ESCALATE at the bound)
  reset_state; : > "$CALLS"; : > "$JSONL"
  echo 5 > "$FLOW_HEALER_STATE_DIR/gate.strikes"
}

# i-1: TSW is active (float marker in the future): the kickstart is deferred AND logged, and the
# run carries on to the pilot signature instead of being abandoned at the gate one.
seed_confirmed_gate; write_marker "$(marker_at "$FUT.938316")"
out=$(run_two 2>/dev/null)
eq "TSW active, float marker: run reaches its end" "$out" "reached-end"
eq "TSW active, float marker: the pilot signature was still evaluated" "$([ -f "$FLOW_HEALER_STATE_DIR/pilot.strikes" ] && echo yes || echo no)" "yes"
eq "TSW active, float marker: kickstart deferred (no launchctl call)" "$(grep -c '^launchctl' "$CALLS" || true)" "0"
eq "TSW active, float marker: the deferral is logged (tsw-defer)" "$(grep -c '"event":"tsw-defer"' "$JSONL" || true)" "1"

# i-2: the float marker is EXPIRED: nothing to defer to, so the kickstart must really happen.
seed_confirmed_gate; write_marker "$(marker_at "$PAST.938316")"
out=$(run_two 2>/dev/null)
eq "expired float marker: run reaches its end" "$out" "reached-end"
eq "expired float marker: the gate kickstart is really performed" "$(grep -c 'launchctl kickstart -k gui/501/com.gascity.quality-gate-dispatcher' "$CALLS" || true)" "1"

# i-3: same, at the MAX_REMEDIATIONS bound: the Mayor escalation must really go out (it used to be
# recorded as escalated - which later let the last-resort NTFY claim "after Mayor escalation" - without being sent).
seed_confirmed_gate; echo 3 > "$FLOW_HEALER_STATE_DIR/gate.remediations"      # == MAX_REMEDIATIONS
write_marker "$(marker_at "$PAST.938316")"
out=$(run_two 2>/dev/null)
eq "expired float marker at the bound: run reaches its end" "$out" "reached-end"
eq "expired float marker at the bound: the Mayor escalation mail is really sent" "$(grep -c '^mail subj=' "$CALLS" || true)" "1"
unset FLOW_HEALER_FAKE_LAUNCHCTL FLOW_HEALER_FAKE_MAIL FLOW_HEALER_FAKE_NOTIFY FLOW_HEALER_FAKE_MTIME_GATE_LOG FLOW_HEALER_FAKE_MTIME_PILOT_LOG

echo
echo "==== selftest: PASS=$PASS FAIL=$FAIL ===="
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
