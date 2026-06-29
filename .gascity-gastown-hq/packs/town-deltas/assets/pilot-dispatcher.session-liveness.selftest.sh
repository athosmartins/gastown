#!/usr/bin/env bash
# pilot-dispatcher.session-liveness.selftest.sh
#
# Regression guard for the "drained ephemeral worker counts as live" wedge
# (ga-mrfb / ps-mrfb + ps-joc0 stuck story:in-flight 80+min behind asleep
# ps-worker-adhoc sessions that `gc session peek` reported "not found").
#
# ROOT CAUSE: _LIVE_SESSION_IDS selects every session with .closed != true. An
# ephemeral pool worker (…-adhoc-…, wake_mode=fresh) goes state=="asleep" after it
# drain-acks but keeps .closed==false for a while, so the broad _session_is_live
# counted it "live" → (a) NEVERSTARTED's live-worker guard KEPT its in-flight bead
# (never reclaimed) and (b) the dead-worker slot-correction KEPT its pool slot
# (falsely full) — a deadlock: the bead is in-flight (never a dispatch candidate,
# so never woken/reused) yet never released.
#
# FIX: _session_is_live_builder("…-adhoc-…") returns DEAD when the worker is asleep,
# while _session_is_live (used by the ownership/crew-owner guards and the gt-4st3n
# REUSE wake path) keeps its full not-closed semantics — an asleep NAMED crew is
# still live. This test extracts the REAL helper defs from the dispatcher and
# exercises every case.
set -u
SRC="$(cd "$(dirname "$0")" && pwd)/pilot-dispatcher.sh"
[ -r "$SRC" ] || { echo "FATAL: cannot read $SRC"; exit 2; }

# Pull the real set-building assignments + the three liveness helpers out of the
# dispatcher (from the _LIVE_SESSION_IDS assignment through the close of
# _session_is_live_builder) so we test shipped code, never a copy.
SNIP="$(awk '/^_LIVE_SESSION_IDS=\$\(echo "\$_SESSIONS_JSON" \\/{f=1}
             f{print}
             /^_session_is_live_builder\(\)/{g=1}
             g&&/^}/{exit}' "$SRC")"
case "$SNIP" in
  *_session_is_live_builder*) : ;;
  *) echo "FATAL: could not extract liveness helpers — did they move/rename?"; exit 2 ;;
esac

FAILS=0
_t() { # desc id want(live|dead)
  _session_is_live_builder "$2"; local rc=$? got="dead"
  [ "$rc" -eq 0 ] && got="live"
  if [ "$got" = "$3" ]; then echo "  ok   $1 → $got"
  else echo "  FAIL $1 → got=$got want=$3"; FAILS=$((FAILS+1)); fi
}

export _SESSIONS_JSON='{"sessions":[
  {"session_name":"mila-wa","state":"active","closed":false},
  {"session_name":"thies-wa","state":"asleep","closed":false},
  {"session_name":"oracle-wa","state":"active","closed":true},
  {"session_name":"ps-worker-adhoc-AWAKE01","state":"active","closed":false},
  {"session_name":"ps-worker-adhoc-b942bd1523","state":"asleep","closed":false},
  {"session_name":"wa-worker-adhoc-8ba5da233e","state":"asleep","closed":false}
]}'
eval "$SNIP"

echo "Scenario: _session_is_live_builder — drained adhoc worker is NOT a live builder"
_t "awake named crew"                       "mila-wa"                    "live"
_t "ASLEEP named crew (preserved live)"     "thies-wa"                   "live"
_t "closed crew"                            "oracle-wa"                  "dead"
_t "awake adhoc worker"                     "ps-worker-adhoc-AWAKE01"    "live"
_t "ASLEEP adhoc ps-worker (the wedge)"     "ps-worker-adhoc-b942bd1523" "dead"
_t "ASLEEP adhoc wa-worker"                 "wa-worker-adhoc-8ba5da233e" "dead"
_t "unknown id"                             "ghost-xyz"                  "dead"

echo "Scenario: _session_is_live UNCHANGED (broad not-closed semantics intact)"
if _session_is_live "ps-worker-adhoc-b942bd1523"; then
  echo "  ok   _session_is_live(asleep adhoc)=live — ownership/REUSE semantics preserved"
else
  echo "  FAIL _session_is_live no longer treats asleep adhoc as live (ownership/REUSE regression)"; FAILS=$((FAILS+1))
fi
if _session_is_asleep "ps-worker-adhoc-b942bd1523" && ! _session_is_asleep "mila-wa"; then
  echo "  ok   _session_is_asleep distinguishes asleep from active"
else
  echo "  FAIL _session_is_asleep misclassified"; FAILS=$((FAILS+1))
fi

echo ""
if [ "$FAILS" -eq 0 ]; then echo "SELFTEST PASS"; exit 0
else echo "SELFTEST FAIL ($FAILS)"; exit 1; fi
