#!/usr/bin/env bash
# gate-a6etc2-bounded-retry-hol.selftest.sh (ga-a6etc2, 2026-09-25)
#
# INCIDENT: 09:44-11:06 local the gate reviewed NOTHING with 23-24 markers queued.
# 28+ consecutive sweeps picked the SAME marker (ga-g5s956), its auto-rebase failed,
# ga-y5c29l kept it `queued` ("bounded retry"), and the next sweep picked it again.
# Three defects stacked; this file pins the fix for each:
#
#   1. SELECTION  tier 1 re-admits a has_rebase_fail marker once its own exile passed
#                 GATE_EXILE_OVERDUE_SECONDS, and nothing re-armed that clock after
#                 the attempt failed -> the marker won every sweep. Fix: per-marker
#                 gate:retry-cooldown-until:<epoch>; the selection skips it (every
#                 tier) until it expires.
#   2. THE BOUND  ga-y5c29l's "stay queued" branch had no upper bound (fail-count 32).
#                 Fix: GATE_CLEAN_RETRY_HARD_CAP -> parks at needs-rebase + mails Mayor.
#   3. THE REVERT the Mayor's manual queued->needs-rebase was erased by the sweep's own
#                 closing set_gate_status(queued) (it strips EVERY gate-status:*).
#                 Fix: gate_requeue_respecting_external compares before it writes.
#
# (The 4th piece, the alarm, lives in the watchdog:
#  scripts/gate-throughput-stall-watchdog.sh --selftest, scenarios "HOL-*".)
#
# Strategy: never a hand-copied duplicate of shipped logic. Sections 1-2 EXTRACT the
# live blocks from the dispatcher by their SELFTEST-EXTRACT sentinels and run them;
# section 3 sources the REAL helper functions (GATE_DISPATCHER_LIB_ONLY) and stubs
# only the side-effecting commands (bd/gc/warn/err/set_gate_status/...).
#
# Written so it can also run against the UNFIXED dispatcher: a missing helper is a
# `bad` line, not a FATAL, so the sections that do not need it still report — that
# is how "fails on HEAD, passes with the fix" was demonstrated.
#
# Exit 0 iff every assertion holds.  Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-a6etc2-bounded-retry-hol.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# /bin/bash -n, never bare `bash -n` (Homebrew bash 5.3 accepts what 3.2 rejects —
# the 25/09 outage where the gate could not parse its own fix).
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then
  ok "dispatcher parses under /bin/bash (3.2) — the interpreter launchd actually runs"
else
  bad "dispatcher does NOT parse under /bin/bash 3.2"
fi

# Load the REAL helper functions (lib-only: no live sweep) BEFORE defining this
# file's own helpers, so a same-named function in the dispatcher/guard lib can
# never silently shadow one of them. The dispatcher sets -e at source time; this
# harness asserts on non-zero rcs, so switch it back off.
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# ── 1. SELECTION ──────────────────────────────────────────────────────────────
echo "── 1. selection: a failing marker inside its retry cooldown cannot win the sweep ──"
SELECT_BLOCK="$(sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$DISPATCHER")"
[ -n "$SELECT_BLOCK" ] || { echo "FATAL: marker-select sentinel block not found" >&2; exit 2; }

NOW=1790345405   # 2026-09-25T14:10:05Z — the moment this bead was claimed
# select_marker <markers-json> : prints the selected id when there is one.
# `log`/`warn` are stubbed to print "LOG:..."/"WARN:..." on stdout, because the
# empty-selection branch calls them and its wording is asserted (it exits before
# the trailing `echo`, so an empty selection prints ONLY that line).
# COUNT is what the dispatcher computed from the same list; SEL_COUNT overrides it.
select_marker() {
  local cnt="${SEL_COUNT:-$(printf '%s' "$1" | jq 'length')}"
  MARKERS_JSON="$1" COUNT="$cnt" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW" \
  GATE_MARKER_AGE_PROMOTE_SECONDS=999999999 \
  GATE_MARKER_HARD_AGE_SECONDS=999999999 \
  GATE_EXILE_OVERDUE_SECONDS=5400 \
  bash -c 'log() { echo "LOG:$*"; }; warn() { echo "WARN:$*"; }; '"$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}
# mk <id> <age-seconds> <extra-labels-csv>  — a queued marker created <age> ago.
mk() {
  local id="$1" age="$2" extra="${3:-}" labs='"gate-status:queued","type:quality-gate-marker"'
  local l; local IFS=','
  for l in $extra; do [ -n "$l" ] && labs="$labs,\"$l\""; done
  printf '{"id":"%s","created_at":"%s","description":"branch: crew/wa-worker/%s","labels":[%s]}' \
    "$id" "$(iso $((NOW - age)))" "$id" "$labs"
}

# The incident's shape: A is the oldest, exiled 6000s ago (> the 5400s ceiling, so
# tier 1 admits it), fail-count 5. B and C are healthy and newer.
A_EXILE="gate:exiled-tier5:5,gate:rebase-fail-count:5,gate:exiled-since:$((NOW - 6000))"
FIX="[$(mk A 20000 "$A_EXILE"),$(mk B 600),$(mk C 300)]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "A" ] \
  && ok "baseline (no cooldown): overdue-exile A still wins tier 1 — the ga-0ye7ar 'an exiled marker must eventually get an attempt' guarantee is intact" \
  || bad "baseline: expected A (tier-1 exile promotion), got '$SEL'"

FIX="[$(mk A 20000 "$A_EXILE,gate:retry-cooldown-until:$((NOW + 600))"),$(mk B 600),$(mk C 300)]"
SEL="$(select_marker "$FIX")"
case "$SEL" in
  B|C) ok "THE INCIDENT: same A, now inside its retry cooldown -> a healthy marker ($SEL) is claimed instead (fails on the unfixed dispatcher: A wins every sweep)" ;;
  *)   bad "A is inside its cooldown yet the sweep selected '$SEL' (want B or C) — head-of-line blocking is back" ;;
esac
[ "$SEL" = "C" ] \
  && ok "healthy tiers keep their order: newest healthy (C) — cooldown removes A without disturbing the tiebreak" \
  || bad "expected the newest healthy marker C, got '$SEL'"

FIX="[$(mk A 20000 "$A_EXILE,gate:retry-cooldown-until:$((NOW - 1))"),$(mk B 600),$(mk C 300)]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "A" ] \
  && ok "cooldown expired (until = now-1) -> A is eligible again and wins tier 1 (the guarantee resumes)" \
  || bad "expired cooldown must re-admit A, got '$SEL'"

FIX="[$(mk A 20000 "$A_EXILE,gate:retry-cooldown-until:$NOW"),$(mk B 600),$(mk C 300)]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "A" ] \
  && ok "boundary: until == now is NOT in cooldown (strictly-less-than) — never held past its own deadline" \
  || bad "until == now must be eligible, got '$SEL'"

FIX="[$(mk A 20000 "$A_EXILE,gate:retry-cooldown-until:abc,gate:retry-cooldown-until:"),$(mk B 600)]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "A" ] \
  && ok "malformed cooldown labels (non-numeric / empty) are ignored, not read as a cooldown" \
  || bad "a garbage cooldown label must not hold the marker out, got '$SEL'"

FIX="[$(mk A 20000 "$A_EXILE,gate:retry-cooldown-until:$((NOW - 5000)),gate:retry-cooldown-until:$((NOW + 700))"),$(mk B 600)]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "B" ] \
  && ok "two cooldown labels (stale + current): the newest deadline decides (max), so a leftover label can never SHORTEN a cooldown" \
  || bad "expected B (newest deadline still in the future), got '$SEL'"

FIX="[$(mk H1 900 'gate:retry-cooldown-until:'"$((NOW + 300))"),$(mk H2 800)]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "H2" ] \
  && ok "the cooldown excludes from EVERY tier — a healthy (not-exiled) marker carrying the label is skipped too" \
  || bad "expected H2, got '$SEL'"

FIX="[$(mk A 20000 "$A_EXILE,gate:retry-cooldown-until:$((NOW + 600))"),$(mk B 600 'gate:retry-cooldown-until:'"$((NOW + 60))")]"
SEL="$(select_marker "$FIX")"
case "$SEL" in
  "LOG:All 2 queued marker(s) are inside their retry cooldown"*)
    ok "every queued marker inside its cooldown -> nothing claimed, a clean exit, and the log CONFIRMS the cause with an independent count (never the literal string 'null' fed to the claim step)" ;;
  *) bad "all markers in cooldown must select nothing and say why, got '$SEL'" ;;
esac
SEL="$(SEL_COUNT=5 select_marker "$FIX")"
case "$SEL" in
  WARN:*"came back EMPTY with 5 queued marker(s), but only 2 of them carry an unexpired retry cooldown"*"UNKNOWN"*)
    ok "empty selection whose cause does NOT reconcile (5 queued, only 2 in cooldown) -> claims nothing and WARNS 'cause UNKNOWN' instead of asserting a comforting explanation" ;;
  *) bad "an unreconciled empty selection must warn, got '$SEL'" ;;
esac

FIX="[$(mk LONE 20000 "$A_EXILE")]"
SEL="$(select_marker "$FIX")"
[ "$SEL" = "LONE" ] \
  && ok "a lone failing marker with NO cooldown is still selected (retried, never ignored)" \
  || bad "expected LONE, got '$SEL'"

# ── 2. THE BOUND + cooldown stamp, on the LIVE ga-y5c29l decision block ────────
echo "── 2. bounded retry: cap parks the marker; below the cap it is stamped and requeued ──"
BLOCK="$(extract_block "$DISPATCHER" ga-y5c29l-retry-dead-decision)"
[ -n "$BLOCK" ] || { echo "FATAL: ga-y5c29l-retry-dead-decision block not found" >&2; exit 2; }
eval "retry_dead_decision() { $BLOCK
}"

BD_LOG=""; GC_LOG=""; WARN_LOG=""; ERR_LOG=""; STATUS_LOG=""; SHOW_JSON=""
BD_FAIL_ADD=""
bd() {
  BD_LOG="$BD_LOG|$*"
  if [ "${3:-}" = "show" ]; then [ -n "$SHOW_JSON" ] && printf '%s' "$SHOW_JSON"; return 0; fi
  if [ "${3:-}" = "label" ] && [ "${4:-}" = "add" ] && [ -n "$BD_FAIL_ADD" ]; then return 1; fi
  return 0
}
gc()  { if [ "${3:-}" = "mail" ] && [ "${4:-}" = "send" ]; then GC_LOG="$GC_LOG|$5:$7"; fi; return 0; }
warn() { WARN_LOG="$WARN_LOG|$*"; }
err()  { ERR_LOG="$ERR_LOG|$*"; }
set_gate_status() { STATUS_LOG="$STATUS_LOG|$1:$2"; }
gate_apply_needs_human() { printf 'armed'; }
gate_needs_human_clause() { printf 'needs-human armed'; }
reset_stubs() { BD_LOG=""; GC_LOG=""; WARN_LOG=""; ERR_LOG=""; STATUS_LOG=""; SHOW_JSON=""; }

MARKER_ID="m-a6etc2"; BEAD_ID="bead-a6etc2"; BEAD_CITY="test-city"; GC_CITY="test-city"
BRANCH="crew/wa-worker/wa-fixture"; DEFAULT_BRANCH="main"; RIG="whatsapp_automation"
MAIN_HEAD_SHA="deadbeef"; AUTHOR=""; REBASE_LIVENESS_TRACE="wa-worker-adhoc-1:dead"
CONFLICT_FILES="auto-rebase push failed (exit=1): gate refused to push: rebase_content_verdict=unknown:merge-tree-conflict"
GATE_REBASE_AHEAD_MAX=10; MAX_REBASE_ATTEMPTS=3; REBASE_AUTHOR_ALIVE=0; REBASE_MERGE_TREE_PROVEN_CLEAN=1

if ! declare -F gate_retry_cooldown_stamp >/dev/null 2>&1 || ! declare -F gate_requeue_respecting_external >/dev/null 2>&1; then
  bad "dispatcher lacks gate_retry_cooldown_stamp / gate_requeue_respecting_external (the unfixed dispatcher)"
fi
CAP="${GATE_CLEAN_RETRY_HARD_CAP:-<unset>}"
COOL="${GATE_RETRY_COOLDOWN_SECONDS:-<unset>}"
[ "$CAP" = "7" ] && ok "GATE_CLEAN_RETRY_HARD_CAP defaults to 7 (3 ordinary attempts + 4 spaced by the cooldown)" \
                 || bad "GATE_CLEAN_RETRY_HARD_CAP default is '$CAP', expected 7"
[ "$COOL" = "900" ] && ok "GATE_RETRY_COOLDOWN_SECONDS defaults to 900 (15 min)" \
                    || bad "GATE_RETRY_COOLDOWN_SECONDS default is '$COOL', expected 900"

echo "  · 2a. proven clean, attempt 6 (< cap 7) → stays queued, stamped with a cooldown, no mail"
reset_stubs; NEXT_ATTEMPT=6; unset REBASE_EVENT 2>/dev/null
T0=$(date +%s); retry_dead_decision; T1=$(date +%s)
UNTIL=$(printf '%s' "$BD_LOG" | sed -n 's/.*label add m-a6etc2 gate:retry-cooldown-until:\([0-9]*\).*/\1/p' | head -1)
if [ "${REBASE_EVENT:-}" = "dispatcher_autorebase_retry_clean_exhausted" ] && [ "$STATUS_LOG" = "|$MARKER_ID:queued" ] && [ -z "$GC_LOG" ]; then
  ok "attempt 6/7 stays gate-status:queued, no mail (event=$REBASE_EVENT)"
else
  bad "attempt 6 should stay queued quietly, got event='${REBASE_EVENT:-}' status='$STATUS_LOG' mail='$GC_LOG'"
fi
if [ -n "$UNTIL" ] && [ "$UNTIL" -ge $((T0 + 900)) ] && [ "$UNTIL" -le $((T1 + 900)) ]; then
  ok "…and carries gate:retry-cooldown-until = now+900 (got $UNTIL) — this is what keeps it out of the next 15 minutes of sweeps"
else
  bad "no gate:retry-cooldown-until:<now+900> label written (until='$UNTIL', bd='$BD_LOG')"
fi
echo "  · 2b. proven clean, attempt 7 (== cap) → parks at needs-rebase and mails the Mayor"
reset_stubs; NEXT_ATTEMPT=7; unset REBASE_EVENT 2>/dev/null
retry_dead_decision
if [ "${REBASE_EVENT:-}" = "dispatcher_needs_rebase_clean_retry_cap" ] && [ "$STATUS_LOG" = "|$MARKER_ID:needs-rebase" ]; then
  ok "attempt 7 (the cap) leaves the queue: gate-status:needs-rebase (event=$REBASE_EVENT)"
else
  bad "attempt at the cap must park at needs-rebase, got event='${REBASE_EVENT:-}' status='$STATUS_LOG' (unfixed dispatcher: stays queued forever)"
fi
printf '%s' "$GC_LOG" | grep -q 'mayor:.*bounded retry spent' \
  && ok "Mayor is mailed, with a subject that says the bounded retry is spent (not 'stranded conflict' — merge-tree proved it clean)" \
  || bad "expected a Mayor mail naming the spent bounded retry, got '$GC_LOG'"
printf '%s' "$BD_LOG" | grep -q 'label add bead-a6etc2 gate:needs-rebase' \
  && ok "source bead is labelled gate:needs-rebase (the existing escalation contract)" \
  || bad "source bead not labelled gate:needs-rebase: '$BD_LOG'"
printf '%s' "$BD_LOG" | grep -q 'gate:retry-cooldown-until' \
  && bad "a parked marker must not be stamped with a fresh cooldown" \
  || ok "no cooldown stamp on a marker that is leaving the queue"

echo "  · 2c. the incident's own number (fail-count 32) → parked, never queued"
reset_stubs; NEXT_ATTEMPT=32; unset REBASE_EVENT 2>/dev/null
retry_dead_decision
[ "${REBASE_EVENT:-}" = "dispatcher_needs_rebase_clean_retry_cap" ] && [ "$STATUS_LOG" = "|$MARKER_ID:needs-rebase" ] \
  && ok "attempt 32 (ga-g5s956) is parked — no attempt count above the cap can ever return to queued" \
  || bad "attempt 32 must park, got event='${REBASE_EVENT:-}' status='$STATUS_LOG'"

echo "  · 2d. GATE_CLEAN_RETRY_HARD_CAP=0 restores the pre-ga-y5c29l terminal behaviour (kill-switch)"
reset_stubs; NEXT_ATTEMPT=3; unset REBASE_EVENT 2>/dev/null
GATE_CLEAN_RETRY_HARD_CAP=0 retry_dead_decision
[ "$STATUS_LOG" = "|$MARKER_ID:needs-rebase" ] \
  && ok "cap=0: an exhausted proven-clean marker escalates at once (operators can disable the extension)" \
  || bad "cap=0 should escalate, got status='$STATUS_LOG'"

echo "  · 2e. GATE_RETRY_COOLDOWN_SECONDS=0 disables the stamp but the retry stays bounded"
reset_stubs; NEXT_ATTEMPT=4; unset REBASE_EVENT 2>/dev/null
GATE_RETRY_COOLDOWN_SECONDS=0 retry_dead_decision
if [ "$STATUS_LOG" = "|$MARKER_ID:queued" ] && ! printf '%s' "$BD_LOG" | grep -q 'gate:retry-cooldown-until'; then
  ok "cooldown=0: requeued with no cooldown label (opt-out), still capped"
else
  bad "cooldown=0 should requeue without a stamp, got status='$STATUS_LOG' bd='$BD_LOG'"
fi

echo "  · 2f. NOT proven clean + GATE_AUTO_CIRCUIT_BREAK=0 → the original legacy escalation, unchanged"
reset_stubs; NEXT_ATTEMPT=3; REBASE_MERGE_TREE_PROVEN_CLEAN=0; unset REBASE_EVENT 2>/dev/null
GATE_AUTO_CIRCUIT_BREAK=0 retry_dead_decision
if [ "${REBASE_EVENT:-}" = "dispatcher_needs_rebase_escalated" ] && [ "$STATUS_LOG" = "|$MARKER_ID:needs-rebase" ] \
   && printf '%s' "$GC_LOG" | grep -q 'mayor:Gate escalation: crew/wa-worker/wa-fixture stranded conflict'; then
  ok "unproven-clean legacy path keeps its event name and its 'stranded conflict' subject — no regression"
else
  bad "legacy path changed: event='${REBASE_EVENT:-}' status='$STATUS_LOG' mail='$GC_LOG'"
fi
REBASE_MERGE_TREE_PROVEN_CLEAN=1

# ── 3. THE REVERT: gate_requeue_respecting_external / gate_retry_cooldown_stamp ─
echo "── 3. an external transition made while the sweep held the marker is not erased ──"
show_json() { # status labels-csv
  local l labs="" first=1 IFS=','
  for l in $2; do [ "$first" = 1 ] || labs="$labs,"; first=0; labs="$labs\"$l\""; done
  printf '[{"id":"m-a6etc2","status":"%s","labels":[%s]}]' "$1" "$labs"
}
if declare -F gate_requeue_respecting_external >/dev/null 2>&1; then
  reset_stubs; SHOW_JSON="$(show_json open 'gate-status:dispatching,type:quality-gate-marker')"
  gate_requeue_respecting_external m-a6etc2 queued dispatching
  [ "$STATUS_LOG" = "|m-a6etc2:queued" ] \
    && ok "normal case (only our own dispatching label) → requeued exactly as before" \
    || bad "normal case must requeue, got '$STATUS_LOG'"

  reset_stubs; SHOW_JSON="$(show_json open 'gate-status:dispatching,gate-status:needs-rebase')"
  gate_requeue_respecting_external m-a6etc2 queued dispatching
  if [ -z "$STATUS_LOG" ] && printf '%s' "$BD_LOG" | grep -q 'label remove m-a6etc2 gate-status:dispatching'; then
    ok "THE 11:03 REVERT: Mayor's needs-rebase landed mid-sweep → NOT overwritten with queued; only our dispatching label is dropped"
  else
    bad "needs-rebase set mid-sweep must survive the sweep's closing write, got status='$STATUS_LOG' bd='$BD_LOG'"
  fi
  printf '%s' "$WARN_LOG" | grep -q 'respecting it' \
    && ok "the skipped write is logged (a decision nobody can see is a decision nobody can audit)" \
    || bad "no log line when an external transition is respected"

  for ext in error passed failed superseded deferred; do
    reset_stubs; SHOW_JSON="$(show_json open "gate-status:dispatching,gate-status:$ext")"
    gate_requeue_respecting_external m-a6etc2 queued dispatching
    [ -z "$STATUS_LOG" ] && ok "external gate-status:$ext is respected too (class fix — not just needs-rebase)" \
                         || bad "external gate-status:$ext was overwritten: '$STATUS_LOG'"
  done

  reset_stubs; SHOW_JSON="$(show_json open 'gate-status:dispatching,gate-status:queued')"
  gate_requeue_respecting_external m-a6etc2 queued dispatching
  [ "$STATUS_LOG" = "|m-a6etc2:queued" ] \
    && ok "dispatching+queued (the guard's Vector A requeued it mid-sweep) is NOT foreign → converges to queued" \
    || bad "dispatching+queued should converge to queued, got '$STATUS_LOG'"

  reset_stubs; SHOW_JSON="$(show_json closed 'gate-status:dispatching')"
  gate_requeue_respecting_external m-a6etc2 queued dispatching
  [ -z "$STATUS_LOG" ] && ok "a marker closed mid-sweep is left closed (no queued label resurrected onto it)" \
                       || bad "closed marker got a status write: '$STATUS_LOG'"

  # UNREADABLE is a third state, not a synonym for "nothing external happened":
  # every variant must (a) take the legacy overwrite — never a crash, never a silent
  # no-write that would strand the marker at `dispatching` — and (b) SAY it could
  # not verify, so the log can tell "unverified" from "verified clean".
  for variant in "" "this is not json" '{"error":"database is locked"}' '[]'; do
    reset_stubs; SHOW_JSON="$variant"
    gate_requeue_respecting_external m-a6etc2 queued dispatching
    if [ "$STATUS_LOG" = "|m-a6etc2:queued" ] && printf '%s' "$WARN_LOG" | grep -q 'UNVERIFIED'; then
      ok "unreadable read [${variant:-<empty>}] → legacy overwrite AND a visible UNVERIFIED warning (a Dolt hiccup behaves as before, but is never silent)"
    else
      bad "unreadable read [${variant:-<empty>}] must fall back to the legacy write WITH a warning, got status='$STATUS_LOG' warn='$WARN_LOG'"
    fi
  done
  reset_stubs; SHOW_JSON="$(show_json open 'gate-status:dispatching')"
  gate_requeue_respecting_external m-a6etc2 queued dispatching
  printf '%s' "$WARN_LOG" | grep -q 'UNVERIFIED' \
    && bad "a CLEAN read must not warn UNVERIFIED (the warning has to mean something)" \
    || ok "a clean, verified read is silent — the UNVERIFIED warning is not noise"

  reset_stubs; SHOW_JSON="$(show_json open 'gate-status:running')"
  gate_requeue_respecting_external m-a6etc2 queued running
  [ "$STATUS_LOG" = "|m-a6etc2:queued" ] \
    && ok "expected_status is a parameter: a marker legitimately at 'running' is not foreign when running is what the caller holds" \
    || bad "expected=running must treat running as our own label, got '$STATUS_LOG'"
else
  bad "gate_requeue_respecting_external missing — the sweep's closing write would still erase an external needs-rebase"
fi
if declare -F gate_retry_cooldown_stamp >/dev/null 2>&1; then
  reset_stubs; SHOW_JSON="$(show_json open 'gate-status:dispatching,gate:retry-cooldown-until:100')"
  gate_retry_cooldown_stamp m-a6etc2 5000
  ADD_AT="$(printf '%s' "$BD_LOG" | grep -bo 'label add m-a6etc2 gate:retry-cooldown-until:5900' | head -1 | cut -d: -f1)"
  RM_AT="$(printf '%s' "$BD_LOG" | grep -bo 'label remove m-a6etc2 gate:retry-cooldown-until:100' | head -1 | cut -d: -f1)"
  if [ -n "$ADD_AT" ] && [ -n "$RM_AT" ] && [ "$ADD_AT" -lt "$RM_AT" ]; then
    ok "stamp = now+900 (5000+900=5900), the stale label is removed, and the ADD precedes the REMOVE (interrupted-transition invariant)"
  else
    bad "expected add(5900) before remove(100), got bd='$BD_LOG'"
  fi
  reset_stubs; BD_FAIL_ADD=1; SHOW_JSON="$(show_json open 'gate-status:dispatching,gate:retry-cooldown-until:100')"
  gate_retry_cooldown_stamp m-a6etc2 5000
  BD_FAIL_ADD=""
  if printf '%s' "$WARN_LOG" | grep -q 'FAILED to write gate:retry-cooldown-until:5900' \
     && ! printf '%s' "$BD_LOG" | grep -q 'label remove m-a6etc2 gate:retry-cooldown-until:100'; then
    ok "a FAILED cooldown write is logged (head-of-line protection is off for that attempt) and the old label is left alone — never a silent success"
  else
    bad "failed cooldown write must warn and must not remove the old label, got warn='$WARN_LOG' bd='$BD_LOG'"
  fi
else
  bad "gate_retry_cooldown_stamp missing"
fi

# ── 4. source drift-guards ─────────────────────────────────────────────────────
echo "── 4. source drift-guards ──"
# The 3 rebase-retry sites (live-author, dead-author, proven-clean) carry the
# ga-7fwt1 tag on the call line; ga-dl3x9s later added 2 finalize sites (reviewer
# death, quota-stop) and 1 TTL site ($D_ID) that use the same call WITHOUT it —
# count the rebase-retry ones by that tag so this guard keeps meaning "these 3".
# (gate-dl3x9s-requeue-external.selftest.sh locks the other 3 and the whole class.)
N_WRAP=$(grep -c 'gate_requeue_respecting_external "\$MARKER_ID" "queued" "dispatching"  # ga-7fwt1' "$DISPATCHER")
[ "$N_WRAP" = "3" ] \
  && ok "all 3 rebase-retry sites (live-author, dead-author, proven-clean) close through gate_requeue_respecting_external" \
  || bad "expected 3 guarded requeue sites, found $N_WRAP"
BLOCK_LINES="$(extract_block "$DISPATCHER" ga-y5c29l-retry-dead-decision)"
STAMP_LN=$(printf '%s\n' "$BLOCK_LINES" | grep -n 'gate_retry_cooldown_stamp "\$MARKER_ID"' | head -1 | cut -d: -f1)
REQ_LN=$(printf '%s\n' "$BLOCK_LINES" | grep -n 'gate_requeue_respecting_external "\$MARKER_ID" "queued"' | head -1 | cut -d: -f1)
if [ -n "$STAMP_LN" ] && [ -n "$REQ_LN" ] && [ "$STAMP_LN" -lt "$REQ_LN" ]; then
  ok "in the proven-clean branch the cooldown stamp (block line $STAMP_LN) precedes the requeue (line $REQ_LN)"
else
  bad "cooldown stamp must precede the requeue in the proven-clean branch (stamp=$STAMP_LN requeue=$REQ_LN)"
fi
grep -q 'elif \[ "\$REBASE_MERGE_TREE_PROVEN_CLEAN" = "1" \] && \[ "\$NEXT_ATTEMPT" -lt "\$GATE_CLEAN_RETRY_HARD_CAP" \]' "$DISPATCHER" \
  && ok "the proven-clean branch is guarded by NEXT_ATTEMPT < GATE_CLEAN_RETRY_HARD_CAP (the bound ga-y5c29l removed)" \
  || bad "the proven-clean branch lost its cap guard"
grep -q 'map(select(in_retry_cooldown | not)) |' "$DISPATCHER" \
  && ok "selection pre-filters cooldown markers BEFORE the tier sum (every tier, not just tier 1)" \
  || bad "selection no longer pre-filters in_retry_cooldown"
grep -q "jq -r '.id // empty')" "$DISPATCHER" \
  && ok "MARKER_ID is read with '.id // empty' (an empty selection is empty, never the string 'null')" \
  || bad "MARKER_ID read can still yield the literal string 'null'"

echo ""
echo "gate-a6etc2-bounded-retry-hol.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
