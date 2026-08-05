#!/usr/bin/env bash
# pilot-dispatcher.assignee-liveness.selftest.sh
#
# Regression guard for ga-46wq5: "Atribuir dono DRENA a fila de construcao em
# silencio" — the Mayor hand-assigned 4 beads to named crews (mila-wa,
# oracle-wa, peter-wa, batista-*) whose sessions stayed non-closed but did
# nothing for 6h/14h/21h/72h. _filter_candidates excluded every one of them
# unconditionally on ".assignee != \"\"" (no liveness check at all), and
# _ownership_guard_should_refuse's signal (b) — the function that DOES already
# know "dead owner ⇒ don't block" — never even got a chance to evaluate them,
# because _filter_candidates dropped them before dispatch_one() ever ran.
# Neither of this file's three PRE-EXISTING liveness helpers (_session_is_live,
# _session_is_asleep, _session_is_live_builder) is idle-TIME-aware; a named
# crew that is technically state=="active" (not asleep, not closed) but has
# touched nothing in 72h reads as "live" under all three.
#
# FIX: a new predicate, _session_is_active_owner, requires not-closed AND
# not-asleep AND (idle-minutes-since-last_active unknown OR under
# PILOT_ASSIGNEE_IDLE_MINUTES). Folding in state=="asleep" directly (not just
# idle-minutes) matters on its own: an asleep session's last_active IS the Go
# zero-time sentinel by design (confirmed live against the real roster — every
# currently-asleep session, adhoc AND named/core alike, reports
# last_active="0001-01-01T00:00:00Z"), so an idle-minutes-only check would
# silently never flag a merely-asleep owner — failing the bug's own first
# acceptance fixture ("sessão está asleep... É despachado"). Both
# _filter_candidates and _ownership_guard_should_refuse's signal (b) now
# consult this SAME predicate — see those functions' own comments for why
# using two independently-drifting checks would make the fix a no-op (a bead
# _filter_candidates re-admits just gets refused again downstream).
#
# This test extracts the REAL helper defs from the dispatcher (never a copy)
# and exercises _session_is_active_owner directly, plus re-confirms the three
# pre-existing helpers it sits alongside are unchanged.
set -u
SRC="$(cd "$(dirname "$0")" && pwd)/pilot-dispatcher.sh"
[ -r "$SRC" ] || { echo "FATAL: cannot read $SRC"; exit 2; }

# Pull the real set-building assignments + all four liveness helpers out of
# the dispatcher (from the _LIVE_SESSION_IDS assignment through the close of
# _session_is_active_owner) so we test shipped code, never a copy. This range
# also covers _DEADWORKER_OK, _ASLEEP_SESSION_IDS, _session_is_live,
# _session_is_asleep and _session_is_live_builder — all real dependencies of
# _session_is_active_owner, not just its own body.
SNIP="$(awk '/^_LIVE_SESSION_IDS=\$\(echo "\$_SESSIONS_JSON" \\/{f=1}
             f{print}
             /^_session_is_active_owner\(\)/{g=1}
             g&&/^}/{exit}' "$SRC")"
case "$SNIP" in
  *_session_is_active_owner*) : ;;
  *) echo "FATAL: could not extract liveness helpers — did they move/rename?"; exit 2 ;;
esac
case "$SNIP" in
  *_SESSIONS_IDLE_JSON*python3*) : ;;
  *) echo "FATAL: extracted snippet lost the python3 idle-enrichment step — awk markers drifted"; exit 2 ;;
esac

FAILS=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }

_t() { # desc id want(active|not-active)
  _session_is_active_owner "$2"; local rc=$? got="not-active"
  [ "$rc" -eq 0 ] && got="active"
  if [ "$got" = "$3" ]; then ok "$1 → $got"
  else bad "$1 → got=$got want=$3"; fi
}

now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
ago_iso_h() { date -u -v-"${1}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }
ago_iso_m() { date -u -v-"${1}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

RECENT="$(now_iso)"
IDLE_72H="$(ago_iso_h 72)"
IDLE_6H="$(ago_iso_h 6)"
IDLE_14H="$(ago_iso_h 14)"
IDLE_21H="$(ago_iso_h 21)"
IDLE_UNDER_THRESH="$(ago_iso_m 10)"    # under the 180min default — must stay active
IDLE_OVER_THRESH="$(ago_iso_m 200)"    # over the 180min default — must flip

export _SESSIONS_JSON='{"sessions":[
  {"session_name":"mila-wa","state":"active","closed":false,"last_active":"'"$RECENT"'"},
  {"session_name":"oracle-wa","state":"active","closed":false,"last_active":"'"$IDLE_72H"'"},
  {"session_name":"peter-wa","state":"asleep","closed":false,"last_active":"0001-01-01T00:00:00Z"},
  {"session_name":"batista-ps","state":"active","closed":false,"last_active":"'"$IDLE_6H"'"},
  {"session_name":"digo-wa","state":"active","closed":false,"last_active":"'"$IDLE_14H"'"},
  {"session_name":"thies-wa","state":"asleep","closed":false,"last_active":"'"$IDLE_21H"'"},
  {"session_name":"oracle-closed","state":"active","closed":true,"last_active":"'"$RECENT"'"},
  {"session_name":"real-just-under","state":"active","closed":false,"last_active":"'"$IDLE_UNDER_THRESH"'"},
  {"session_name":"real-just-over","state":"active","closed":false,"last_active":"'"$IDLE_OVER_THRESH"'"},
  {"session_name":"ps-worker-adhoc-AWAKE01","state":"active","closed":false,"last_active":"0001-01-01T00:00:00Z"},
  {"session_name":"ps-worker-adhoc-b942bd1523","state":"asleep","closed":false,"last_active":"0001-01-01T00:00:00Z"}
]}'
eval "$SNIP"

echo "Scenario: _session_is_active_owner — CONTROL, recently-active named crew stays active (anti-double-dispatch)"
_t "recently-active named crew"             "mila-wa"        "active"

echo "Scenario: _session_is_active_owner — real incident shape (active state, idle beyond threshold)"
_t "active but idle 72h (shortest real incident value: 6h-72h)" "oracle-wa"  "not-active"
_t "active but idle 6h"                     "batista-ps"     "not-active"
_t "active but idle 14h"                    "digo-wa"        "not-active"

echo "Scenario: _session_is_active_owner — literal 'asleep' fixture (bug's own FIX PEDIDO #1 wording)"
_t "asleep named crew, zero-sentinel last_active" "peter-wa" "not-active"
_t "asleep named crew, WITH a real (stale) last_active — state check must not depend on last_active being present" "thies-wa" "not-active"

echo "Scenario: _session_is_active_owner — closed crew (already true via _session_is_live alone; confirm composition)"
_t "closed crew"                            "oracle-closed"  "not-active"

echo "Scenario: _session_is_active_owner — unknown identifier"
_t "unknown id"                             "ghost-xyz"      "not-active"

echo "Scenario: _session_is_active_owner — threshold boundary (PILOT_ASSIGNEE_IDLE_MINUTES default 180)"
_t "idle 10min — under threshold, stays active"   "real-just-under" "active"
_t "idle 200min — over threshold, flips"          "real-just-over"  "not-active"

echo "Scenario: 5-idle-crew incident-shaped fixture (ga-46wq5's own re-run acceptance criterion) — ALL must read not-active"
INCIDENT_FAILS=0
for id in oracle-wa peter-wa batista-ps digo-wa thies-wa; do
  _session_is_active_owner "$id" && INCIDENT_FAILS=$((INCIDENT_FAILS+1))
done
[ "$INCIDENT_FAILS" -eq 0 ] \
  && ok "all 5 incident-shaped assignees (mila/oracle/peter/batista/digo-analog) read not-active — would have been flagged/re-admitted before the queue emptied" \
  || bad "$INCIDENT_FAILS of 5 incident-shaped assignees still read active — re-run against the real incident would NOT have caught them"

echo "Scenario: pre-existing helpers UNCHANGED (regression guard — this block was inserted adjacent to them)"
_session_is_live "oracle-wa" \
  && ok "_session_is_live(active-but-idle)=live — broad not-closed semantics untouched by the new predicate" \
  || bad "_session_is_live regressed for an active-but-idle session (should still be 'live' under its own, narrower semantics)"
_session_is_live "peter-wa" \
  && ok "_session_is_live(asleep named crew)=live — REUSE/ownership semantics for asleep crews untouched" \
  || bad "_session_is_live regressed for an asleep named crew"
if _session_is_live_builder "ps-worker-adhoc-b942bd1523"; then
  bad "_session_is_live_builder regressed — asleep adhoc worker should still be dead (ga-mrfb wedge)"
else
  ok "_session_is_live_builder(asleep adhoc)=dead — ga-mrfb fix untouched"
fi

echo "Scenario: PILOT_ASSIGNEE_IDLE_MINUTES is env-overridable"
(
  export PILOT_ASSIGNEE_IDLE_MINUTES=5
  eval "$SNIP"
  if _session_is_active_owner "real-just-under"; then
    echo "  FAIL threshold override: idle 10min should flip to not-active when threshold=5min"; exit 1
  else
    echo "  ok   threshold override: idle 10min correctly flips to not-active when PILOT_ASSIGNEE_IDLE_MINUTES=5"; exit 0
  fi
) || FAILS=$((FAILS+1))

echo ""
if [ "$FAILS" -eq 0 ]; then echo "SELFTEST PASS"; exit 0
else echo "SELFTEST FAIL ($FAILS)"; exit 1
fi
