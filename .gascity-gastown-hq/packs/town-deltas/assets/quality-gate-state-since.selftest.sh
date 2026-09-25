#!/usr/bin/env bash
# quality-gate-state-since.selftest.sh — ga-jmmcjn: prove the "false zombie
# dispatching marker" fix, with NO live Dolt/gc/launchd.
#
# THE BUG (measured 2026-09-25 on bd 1.1.0, ga-jmmcjn): the guard's Vector A
# (and the dispatcher's Step 0a TTL) decide "this marker has been stuck in
# gate-status:dispatching/claimed for N minutes" from the marker's
# `updated_at`. But bd bumps `updated_at` ONLY on `bd update` — `label add`,
# `label remove` and `comment` leave it untouched, and those are the ONLY
# writes that move a marker into dispatching (dispatcher claim) or claimed
# (guard claim). So `updated_at` is "time since the last bd update", NOT
# "time in the current state": a marker that waited >30m in `queued` and is
# claimed during a guard sweep — or one bouncing queued→dispatching→
# needs-rebase→queued every ~3m, as ga-g5s956 did for 30+ cycles — reads as a
# 30m+ zombie while a live dispatcher is actively working it, is re-queued,
# and burns one of MAX_RECLAIMS=3 (at 3 it goes to terminal gate-status:error).
#
# THE FIX: stamp the moment a marker ENTERS a transient state
# (metadata gate.state_since=<status>@<epoch>, written BEFORE the label add,
# via `bd update` — the one write type that persists) and read the age of the
# current state as the SMALLER of (age by updated_at, age by a matching stamp).
# Absent / mismatched / unreadable / future stamp => exactly today's
# updated_at age (never worse than before).
#
# Sources the guard in lib-only mode (single source of truth, no copy-drift),
# unit-tests every branch, then DRIFT-GUARDS the wiring in the real scripts.
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

# Fixed clock so every age below is exact, not "about".
NOW=1790352534
# ts_ago <minutes> -> bead-style UTC timestamp that many minutes before NOW.
ts_ago() {
  date -u -r "$((NOW - $1 * 60))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$((NOW - $1 * 60))" "+%Y-%m-%dT%H:%M:%SZ"
}
# marker_json <status> <updated_min_ago> [state_since_meta] -> shape of one
# element of `bd list --json --include-infra` (metadata omitted when unset,
# exactly as bd does).
marker_json() {
  local st="$1" upd; upd="$(ts_ago "$2")"
  if [ "$#" -ge 3 ]; then
    printf '{"id":"ga-g5s956","status":"open","created_at":"%s","updated_at":"%s","labels":["type:quality-gate-marker","gate-status:%s"],"metadata":{"gate.submitted_by":"wa-worker-x","gate.state_since":"%s"}}' \
      "$(ts_ago 400)" "$upd" "$st" "$3"
  else
    printf '{"id":"ga-g5s956","status":"open","created_at":"%s","updated_at":"%s","labels":["type:quality-gate-marker","gate-status:%s"],"metadata":{"gate.submitted_by":"wa-worker-x"}}' \
      "$(ts_ago 400)" "$upd" "$st"
  fi
}

echo "== 0. the helpers exist and share one key"
HAVE_AGE=0; HAVE_STAMP=0
type marker_state_age_minutes >/dev/null 2>&1 && HAVE_AGE=1
type stamp_marker_state_since >/dev/null 2>&1 && HAVE_STAMP=1
[ "$HAVE_AGE" = 1 ]   && ok "marker_state_age_minutes defined by the guard lib"   || bad "marker_state_age_minutes NOT defined by the guard lib"
[ "$HAVE_STAMP" = 1 ] && ok "stamp_marker_state_since defined by the guard lib"   || bad "stamp_marker_state_since NOT defined by the guard lib"
eq "metadata key constant" "${GATE_STATE_SINCE_KEY:-<unset>}" "gate.state_since"

if [ "$HAVE_AGE" = 1 ]; then
  # stderr is the helper's "I ignored a corrupt stamp" channel; section 3c
  # asserts it directly, so keep the value checks quiet.
  age() { marker_state_age_minutes "$1" "$2" "$NOW" 2>/dev/null; }
  age_err() { marker_state_age_minutes "$1" "$2" "$NOW" 2>&1 >/dev/null; }

  echo "== 1. THE INCIDENT: stale updated_at, fresh stamp => the stamp wins"
  # ga-g5s956 at 11:01:30 local: updated_at frozen 32m back while the dispatcher
  # had claimed it seconds ago.
  eq "incident: updated 32m ago, claimed 10s ago"        "$(age dispatching "$(marker_json dispatching 32 "dispatching@$((NOW-10))")")" 0
  # The wider variant: waited 3h in queued, claimed 1m ago, guard sweeps now.
  eq "long queue wait: updated 180m ago, claimed 1m ago" "$(age dispatching "$(marker_json dispatching 180 "dispatching@$((NOW-60))")")" 1
  eq "claimed state uses a claimed@ stamp"                "$(age claimed "$(marker_json claimed 90 "claimed@$((NOW-120))")")" 2

  echo "== 2. REAL zombies are still detected"
  eq "dispatcher died at claim: stamp as old as updated_at" "$(age dispatching "$(marker_json dispatching 331 "dispatching@$((NOW-331*60))")")" 331
  eq "no stamp at all (legacy marker) = plain updated_at"   "$(age dispatching "$(marker_json dispatching 180)")" 180
  eq "stamp OLDER than updated_at: updated_at wins (min)"   "$(age dispatching "$(marker_json dispatching 2 "dispatching@$((NOW-90*60))")")" 2

  echo "== 3. untrustworthy stamps fall back to updated_at, never to 'fresh'"
  eq "stamp for a DIFFERENT status (queued@) ignored"  "$(age dispatching "$(marker_json dispatching 180 "queued@$((NOW-5))")")" 180
  eq "dispatching stamp on a claimed marker ignored"   "$(age claimed "$(marker_json claimed 180 "dispatching@$((NOW-5))")")" 180
  eq "non-numeric epoch ignored"                       "$(age dispatching "$(marker_json dispatching 180 "dispatching@abc")")" 180
  eq "empty epoch ignored"                             "$(age dispatching "$(marker_json dispatching 180 "dispatching@")")" 180
  eq "no @ at all ignored"                             "$(age dispatching "$(marker_json dispatching 180 "garbage")")" 180
  eq "empty stamp ignored"                             "$(age dispatching "$(marker_json dispatching 180 "")")" 180
  eq "future-dated stamp (corrupt) ignored"            "$(age dispatching "$(marker_json dispatching 180 "dispatching@$((NOW+3600))")")" 180

  echo "== 3c. an unusable stamp for THIS status is reported (not silent); benign cases stay quiet"
  has_ignore_msg() { case "$1" in *"ignoring"*"gate.state_since"*) return 0 ;; *) return 1 ;; esac; }
  for bad_stamp in "dispatching@abc" "dispatching@" "dispatching@$((NOW+3600))" "dispatching@1234567890123456"; do
    if has_ignore_msg "$(age_err dispatching "$(marker_json dispatching 180 "$bad_stamp")")"; then ok "corrupt stamp [$bad_stamp] is reported on stderr"; else bad "corrupt stamp [$bad_stamp] was ignored SILENTLY"; fi
  done
  eq "no stamp at all: quiet"                  "$(age_err dispatching "$(marker_json dispatching 180)")" ""
  eq "good stamp: quiet"                       "$(age_err dispatching "$(marker_json dispatching 180 "dispatching@$((NOW-60))")")" ""
  eq "other-status stamp (queued@): quiet"     "$(age_err dispatching "$(marker_json dispatching 180 "queued@$((NOW-60))")")" ""

  echo "== 3b. JSON shapes: bd show returns an ARRAY (Vector B reads it), bd list an object"
  eq "array-wrapped marker (bd show --json) uses the stamp"  "$(age dispatching "[$(marker_json dispatching 180 "dispatching@$((NOW-60))")]")" 1
  eq "array-wrapped marker without stamp = updated_at"       "$(age dispatching "[$(marker_json dispatching 180)]")" 180
  eq "empty array -> age 0 (inert, same as legacy empty ts)" "$(age dispatching "[]")" 0
  eq "unparseable JSON -> age 0 (inert, same as legacy)"     "$(age dispatching "not json")" 0
  eq "EMPTY status (ambiguous labels) never trusts a stamp"  "$(age "" "$(marker_json dispatching 180 "@$((NOW-5))")")" 180
  eq "EMPTY status, well-formed stamp: still legacy age"     "$(age "" "$(marker_json dispatching 180 "dispatching@$((NOW-5))")")" 180
  eq "leading-zero epoch does not blow up (10# guard)"       "$(age dispatching "$(marker_json dispatching 180 "dispatching@0$((NOW-60))")")" 1

  echo "== 4. decision level: what reconcile_marker_action now does with these ages"
  A_INCIDENT="$(age dispatching "$(marker_json dispatching 32 "dispatching@$((NOW-10))")")"
  A_ZOMBIE="$(age dispatching "$(marker_json dispatching 331 "dispatching@$((NOW-331*60))")")"
  eq "incident marker (reclaims=1) -> skip"            "$(reconcile_marker_action dispatching "$A_INCIDENT" 30 1 3 0)" skip
  eq "real zombie (reclaims=0)     -> requeue:queued"  "$(reconcile_marker_action dispatching "$A_ZOMBIE" 30 0 3 0)" requeue:queued
  eq "real zombie, reclaims spent  -> error"           "$(reconcile_marker_action dispatching "$A_ZOMBIE" 30 3 3 0)" error
  eq "the pre-fix age (32m) WOULD have requeued it"    "$(reconcile_marker_action dispatching 32 30 1 3 0)" requeue:queued

  echo "== 4b. Vector B (zero-verdict gate-run) reads the SAME marker age — same class, same fix"
  # Its comment used to claim updated_at "is refreshed at each real state
  # transition"; it is not. A stale age there answers supersede:requeue-marker:
  # close the gate-run and re-queue a marker that is mid-dispatch.
  if type reconcile_zero_verdict_run_action >/dev/null 2>&1; then
    B_LEGACY="$(age dispatching "[$(marker_json dispatching 180)]")"
    B_STAMPED="$(age dispatching "[$(marker_json dispatching 180 "dispatching@$((NOW-60))")]")"
    B_STRANDED="$(age dispatching "[$(marker_json dispatching 180 "dispatching@$((NOW-180*60))")]")"
    eq "pre-fix age (180m) would requeue a mid-dispatch marker" "$(reconcile_zero_verdict_run_action "$B_LEGACY" 20 dispatching)" supersede:requeue-marker
    eq "stamped age (1m): mid-dispatch marker left alone"       "$(reconcile_zero_verdict_run_action "$B_STAMPED" 20 dispatching)" skip
    eq "genuinely stranded (stamp 180m old): still requeued"    "$(reconcile_zero_verdict_run_action "$B_STRANDED" 20 dispatching)" supersede:requeue-marker
    eq "claimed state, stamped: left alone"                     "$(reconcile_zero_verdict_run_action "$(age claimed "[$(marker_json claimed 180 "claimed@$((NOW-30))")]")" 20 claimed)" skip
  else
    bad "reconcile_zero_verdict_run_action not defined by the guard lib"
  fi
fi

echo "== 5. stamp_marker_state_since (mock bd)"
if [ "$HAVE_STAMP" = 1 ]; then
  BD_LOG=""; BD_RC=0
  bd() { BD_LOG="$BD_LOG|$*"; return "$BD_RC"; }
  warn() { :; }   # the writer may warn on failure; keep the harness quiet
  stamp_marker_state_since ga-x dispatching
  case "$BD_LOG" in
    *"update ga-x --set-metadata gate.state_since=dispatching@"[0-9]*) ok "writes gate.state_since=<status>@<epoch> via bd update" ;;
    *) bad "unexpected bd call: [$BD_LOG]" ;;
  esac
  BD_LOG=""; stamp_marker_state_since "" dispatching
  eq "empty id is a no-op (no bd call)" "$BD_LOG" ""
  BD_LOG=""; BD_RC=1
  if stamp_marker_state_since ga-x claimed; then bad "failed bd write must return non-zero"; else ok "failed bd write returns non-zero (caller decides), does not exit"; fi
  unset -f bd warn
fi

echo "== 6. WIRING drift-guards on the real scripts"
# awk always exits 0, so a miss yields "" (a reportable FAIL) instead of
# tripping set -e/pipefail and silently aborting the harness mid-run.
lineof() { awk -v pat="$2" 'index($0, pat) && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$1"; }

G_STAMP="$(lineof "$GUARD" 'stamp_marker_state_since "$MARKER_ID" claimed')"
G_LABEL="$(lineof "$GUARD" 'label add "$MARKER_ID" "gate-status:claimed"')"
if [ -n "$G_STAMP" ] && [ -n "$G_LABEL" ] && [ "$G_STAMP" -lt "$G_LABEL" ]; then ok "guard stamps claimed BEFORE the claim label add (L$G_STAMP < L$G_LABEL)"; else bad "guard must stamp claimed before its label add (stamp=[$G_STAMP] label=[$G_LABEL])"; fi

D_STAMP="$(lineof "$DISPATCHER" 'stamp_marker_state_since "$MARKER_ID" dispatching')"
D_LABEL="$(lineof "$DISPATCHER" 'label add "$MARKER_ID" "gate-status:dispatching"')"
if [ -n "$D_STAMP" ] && [ -n "$D_LABEL" ] && [ "$D_STAMP" -lt "$D_LABEL" ]; then ok "dispatcher stamps dispatching BEFORE the claim label add (L$D_STAMP < L$D_LABEL)"; else bad "dispatcher must stamp dispatching before its label add (stamp=[$D_STAMP] label=[$D_LABEL])"; fi

# The stamp must never be able to abort a claim: it is best-effort (fallback =
# today's behaviour), so both call sites must swallow a non-zero return.
grep -F 'stamp_marker_state_since "$MARKER_ID" claimed' "$GUARD" | grep -F '|| true' >/dev/null \
  && ok "guard stamp call is best-effort (|| true)" || bad "guard stamp call must end in || true"
grep -F 'stamp_marker_state_since "$MARKER_ID" dispatching' "$DISPATCHER" | grep -F '|| true' >/dev/null \
  && ok "dispatcher stamp call is best-effort (|| true)" || bad "dispatcher stamp call must end in || true"

# Readers: Vector A (guard) and the TTL recovery (dispatcher) must both age the
# marker through the shared helper, not raw updated_at.
grep -E '^[[:space:]]*T_AGE=.*marker_state_age_minutes' "$GUARD" >/dev/null \
  && ok "guard Vector A ages the marker via marker_state_age_minutes" || bad "guard Vector A T_AGE must come from marker_state_age_minutes"
grep -F 'D_AGE_STATE=$(marker_state_age_minutes dispatching "$D_MARKER"' "$DISPATCHER" >/dev/null \
  && grep -F 'D_AGE_MINUTES="$D_AGE_STATE"' "$DISPATCHER" >/dev/null \
  && ok "dispatcher Step 0a ages the marker via marker_state_age_minutes and feeds D_AGE_MINUTES" || bad "dispatcher Step 0a must feed D_AGE_MINUTES from marker_state_age_minutes"
grep -F 'MARKER_AGE=$(marker_state_age_minutes' "$GUARD" >/dev/null \
  && ok "guard Vector B (zero-verdict) ages the marker via marker_state_age_minutes" || bad "guard Vector B MARKER_AGE must come from marker_state_age_minutes"
# ...and no un-stamped reader of a marker's updated_at may remain in either
# script for the transient-state age (the class, not just the cited instance).
if grep -nE 'age_minutes_of +"\$(T_UPDATED|MARKER_UPDATED)"' "$GUARD" | grep -v 'T_AGE_UPDATED=' | grep -q .; then
  bad "a raw age_minutes_of(updated_at) reader of a marker's transient-state age remains in the guard"
else
  ok "no raw age_minutes_of(updated_at) marker-state reader remains in the guard (only the log-only T_AGE_UPDATED)"
fi
# Dispatcher degrades to the legacy age if the guard sibling lacks the helper
# (partial deploy) — a missing function inside $(...) under set -e would
# otherwise kill the dispatcher's whole sweep.
grep -F 'type marker_state_age_minutes' "$DISPATCHER" >/dev/null \
  && ok "dispatcher falls back to the legacy age when the helper is undefined" || bad "dispatcher must guard the helper call with 'type marker_state_age_minutes'"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
