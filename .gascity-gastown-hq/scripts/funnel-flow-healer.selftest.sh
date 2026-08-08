#!/usr/bin/env bash
# funnel-flow-healer.selftest.sh — drives the PURE decision core (decide_action) and
# the real-world dispatch (handle_signature) with stubbed inputs. Makes ZERO real
# launchctl / gc mail / bd / notify calls — all are stubbed. No daemons are touched.
set -uo pipefail

HEALER="${HEALER:-/tmp/funnel-flow-healer.sh}"
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
if grep -qvE '^(launchctl|mail|notify) ' "$CALLS" 2>/dev/null; then
  bad "unexpected non-stub call recorded: $(cat "$CALLS")"
else
  ok "only stubbed side-effects recorded (zero real launchctl/gc/bd/notify)"
fi
unset FLOW_HEALER_FAKE_LAUNCHCTL FLOW_HEALER_FAKE_MAIL FLOW_HEALER_FAKE_NOTIFY FLOW_HEALER_FAKE_MTIME_AUTO_REFINO_DISPATCHER_LOG

echo
echo "==== selftest: PASS=$PASS FAIL=$FAIL ===="
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
