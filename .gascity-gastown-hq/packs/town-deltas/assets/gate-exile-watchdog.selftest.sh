#!/usr/bin/env bash
# gate-exile-watchdog.selftest.sh (ga-faw5o defeito 3, 2026-09-01)
#
# Proves gate_exile_watchdog_sweep() in quality-gate-dispatcher.sh: a
# has_rebase_fail (gate:exiled-tier5:N) marker only ever advances its retry
# counter when actually RE-SELECTED, but selection only reaches it via the
# very last of 6 tiers — reachable exclusively when every healthy tier is
# empty. In a queue that never fully empties, an exiled marker is never
# re-selected, so it never reaches MAX_REBASE_ATTEMPTS and the existing
# attempt-based escalation (Step 4c, mail-Mayor) never fires. This is a
# SELECTION-INDEPENDENT wall-clock backstop: it scans every queued marker
# every sweep regardless of what (if anything) gets admitted, so it fires
# even when the marker can never win a selection round.
#
# Strategy mirrors gate-dispatcher-author-notify-fallback.selftest.sh: extract
# the LIVE function via its SELFTEST-EXTRACT sentinel (never a hand-copied
# duplicate), eval it into THIS shell (in-process, no subshell boundary to
# cross), then stub bd/gc/warn/set_gate_status as plain bash functions. This
# selftest scopes to gate_exile_watchdog_sweep()'s own logic only — it does
# NOT re-verify set_gate_status()'s own correctness, which is covered by
# quality-gate-reconcile.selftest.sh.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-exile-watchdog.selftest (ga-faw5o defeito 3) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

BLOCK="$(extract_block "$DISPATCHER" "gate-exile-watchdog")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: SELFTEST-EXTRACT gate-exile-watchdog block not found in $DISPATCHER" >&2
  exit 2
fi
eval "$BLOCK"
if ! declare -F gate_exile_watchdog_sweep >/dev/null 2>&1; then
  echo "FATAL: extracted block did not define gate_exile_watchdog_sweep" >&2
  exit 2
fi

# ── stubs ────────────────────────────────────────────────────────────────────
GC_CITY="test-city"
LABEL_ADD_LOG=""     # accumulates every `bd label add <id> <label>` call, in order
COMMENT_LOG=""        # accumulates every `bd comment <id> <text>` call's id
MAIL_LOG=""           # accumulates every `gc mail send` recipient
WARN_LOG=""
STATUS_LOG=""         # accumulates every set_gate_status call as "<id>:<new>"
MAIL_SHOULD_FAIL=0    # when 1, the gc mail stub logs the attempt but returns failure

bd() {
  # bd -C "$GC_CITY" label add "$id" "$label" -q
  # bd -C "$GC_CITY" comment "$id" "text"
  # $1=-C $2=city consume the first two slots in both call shapes above.
  if [ "$3" = "label" ] && [ "$4" = "add" ]; then
    LABEL_ADD_LOG="$LABEL_ADD_LOG|$5:$6"
    return 0
  fi
  if [ "$3" = "comment" ]; then
    COMMENT_LOG="$COMMENT_LOG|$4"
    return 0
  fi
  return 0
}
gc() {
  # gc --city "$GC_CITY" mail send mayor -s ... -m ...
  if [ "$1" = "--city" ] && [ "$3" = "mail" ] && [ "$4" = "send" ]; then
    MAIL_LOG="$MAIL_LOG $5"
    [ "$MAIL_SHOULD_FAIL" = "1" ] && return 1
    return 0
  fi
  return 0
}
warn() { WARN_LOG="$WARN_LOG|$*"; }
set_gate_status() { STATUS_LOG="$STATUS_LOG|$1:$2"; }

reset_stubs() { LABEL_ADD_LOG=""; COMMENT_LOG=""; MAIL_LOG=""; WARN_LOG=""; STATUS_LOG=""; MAIL_SHOULD_FAIL=0; }

# mk <id> <labels-csv> — a queued marker with the given labels
mk() {
  local id="$1" labels="$2"
  jq -cn --arg id "$id" --argjson labels "$(printf '%s' "$labels" | jq -R 'split(",")')" \
    '{id:$id, labels:$labels}'
}

NOW=2000000000
THRESH=86400

echo "── (1) first sweep observing an exiled marker: starts the clock, does NOT escalate yet ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m1 "gate-status:queued,gate:exiled-tier5:2")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if [ "$LABEL_ADD_LOG" = "|m1:gate:exiled-since:$NOW" ] && [ -z "$MAIL_LOG" ] && [ -z "$STATUS_LOG" ]; then
  ok "first-seen exile stamps gate:exiled-since:$NOW, no mail, no status change (log='$LABEL_ADD_LOG')"
else
  bad "expected only an exiled-since stamp, got labels='$LABEL_ADD_LOG' mail='$MAIL_LOG' status='$STATUS_LOG'"
fi

echo "── (2) exiled-since present but under threshold: no-op ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m2 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-1000))")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if [ -z "$LABEL_ADD_LOG" ] && [ -z "$MAIL_LOG" ] && [ -z "$STATUS_LOG" ]; then
  ok "elapsed=1000s < threshold=${THRESH}s — no escalation, no writes at all"
else
  bad "expected total no-op under threshold, got labels='$LABEL_ADD_LOG' mail='$MAIL_LOG' status='$STATUS_LOG'"
fi

echo "── (3) THE BUG, reproduced then fixed: past threshold with no re-selection — escalates ──"
reset_stubs
ELAPSED=$((THRESH + 5000))
MARKERS=$(printf '[%s]' "$(mk m3 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-ELAPSED))")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if echo "$MAIL_LOG" | grep -q "mayor" \
   && [ "$COMMENT_LOG" = "|m3" ] \
   && [ "$LABEL_ADD_LOG" = "|m3:gate:exile-escalated" ] \
   && [ "$STATUS_LOG" = "|m3:needs-rebase" ]; then
  ok "past-threshold marker mails mayor, comments the marker, stamps exile-escalated, parks at needs-rebase (this is the exact scenario ga-faw5o defeito 3 describes: never re-selected, would otherwise sit forever)"
else
  bad "escalation incomplete — mail='$MAIL_LOG' comment='$COMMENT_LOG' labels='$LABEL_ADD_LOG' status='$STATUS_LOG'"
fi

echo "── (4) dedup: already-escalated marker is skipped entirely on a later sweep ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m4 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-999999)),gate:exile-escalated")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if [ -z "$LABEL_ADD_LOG" ] && [ -z "$MAIL_LOG" ] && [ -z "$COMMENT_LOG" ] && [ -z "$STATUS_LOG" ]; then
  ok "gate:exile-escalated already present — filtered out before the loop even starts, zero repeat mail (communication hygiene: escalate once, not every sweep)"
else
  bad "expected already-escalated marker to be completely skipped, got labels='$LABEL_ADD_LOG' mail='$MAIL_LOG'"
fi

echo "── (5) boundary: exactly at threshold is NOT yet over (strict >, matches house convention) ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m5 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-THRESH))")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if [ -z "$MAIL_LOG" ] && [ -z "$STATUS_LOG" ]; then
  ok "elapsed exactly == threshold does not escalate yet (strict >, no boundary flakiness)"
else
  bad "expected no escalation at exact boundary, got mail='$MAIL_LOG' status='$STATUS_LOG'"
fi

echo "── (6) healthy marker (no rebase-fail label at all) is never touched ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m6 "gate-status:queued")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if [ -z "$LABEL_ADD_LOG" ] && [ -z "$MAIL_LOG" ] && [ -z "$STATUS_LOG" ]; then
  ok "a marker with no exile label at all is filtered out before the loop — no false-positive writes on healthy markers"
else
  bad "healthy marker should never be touched, got labels='$LABEL_ADD_LOG' mail='$MAIL_LOG'"
fi

echo "── (7) legacy label name (gate:rebase-attempt:N, pre-2026-07-17 ga-gpcx rename) is still recognized ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m7 "gate-status:queued,gate:rebase-attempt:3")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if [ "$LABEL_ADD_LOG" = "|m7:gate:exiled-since:$NOW" ]; then
  ok "legacy gate:rebase-attempt:N label (matches has_rebase_fail's own regex exactly) still starts the clock — a marker exiled before the ga-gpcx rename is not silently invisible to this watchdog"
else
  bad "legacy label name not recognized, got labels='$LABEL_ADD_LOG'"
fi

echo "── (8) multiple markers in one sweep: each handled independently, none skipped ──"
reset_stubs
ELAPSED=$((THRESH + 100))
MARKERS=$(printf '[%s,%s,%s]' \
  "$(mk fresh_exile "gate-status:queued,gate:exiled-tier5:2")" \
  "$(mk under_thresh "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-500))")" \
  "$(mk over_thresh  "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-ELAPSED))")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if echo "$LABEL_ADD_LOG" | grep -q "fresh_exile:gate:exiled-since:$NOW" \
   && ! echo "$LABEL_ADD_LOG" | grep -q "under_thresh:gate:exile-escalated" \
   && echo "$LABEL_ADD_LOG" | grep -q "over_thresh:gate:exile-escalated" \
   && echo "$MAIL_LOG" | grep -qv "under_thresh" ; then
  ok "3 markers in one sweep each get the correct independent treatment (first-seen stamp / no-op / escalate) — log='$LABEL_ADD_LOG'"
else
  bad "multi-marker sweep mishandled one or more markers — labels='$LABEL_ADD_LOG' mail='$MAIL_LOG'"
fi

echo "── (9) defensive: malformed gate:exiled-since value does not crash the sweep ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m9 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:not-a-number")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$MAIL_LOG" ] && [ -z "$STATUS_LOG" ]; then
  ok "malformed exiled-since value is skipped (continue), not treated as elapsed=0 or crashing the sweep (rc=$RC)"
else
  bad "malformed exiled-since should skip safely, got rc=$RC mail='$MAIL_LOG' status='$STATUS_LOG'"
fi

echo "── (10) default threshold: unset/malformed \$2 falls back to 86400s (24h), matching the Step 0b-0 call site's default ──"
reset_stubs
MARKERS=$(printf '[%s]' "$(mk m10 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-90000))")")
gate_exile_watchdog_sweep "$MARKERS" "" "$NOW"
if echo "$STATUS_LOG" | grep -q "m10:needs-rebase"; then
  ok "empty threshold arg defaults to 86400s — 90000s elapsed correctly escalates"
else
  bad "default threshold not applied correctly, status='$STATUS_LOG'"
fi

# ── MUTATION check — proves case (3) is not vacuous ─────────────────────────
echo "── (11) mutation: swapping the mail-then-label order would not change the FINAL state this test asserts on — assert INTERMEDIATE call presence instead, not just log content, to catch a 'silently skip the mail' mutation"
reset_stubs
ELAPSED=$((THRESH + 5000))
MARKERS=$(printf '[%s]' "$(mk m11 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-ELAPSED))")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
MAIL_COUNT=$(echo "$MAIL_LOG" | tr ' ' '\n' | grep -c '^mayor$' || true)
if [ "$MAIL_COUNT" -eq 1 ]; then
  ok "exactly one mail-to-mayor call per escalation (a mutation dropping the gc call, or looping it twice, would fail this)"
else
  bad "expected exactly 1 mayor mail, got $MAIL_COUNT (mail_log='$MAIL_LOG')"
fi

echo "── (12) drift-guards: shipped dispatcher wires the watchdog into Step 0b, before the quiet-hours/headroom gates ──"
grep -q "gate_exile_watchdog_sweep \"\$MARKERS_JSON\"" "$DISPATCHER" \
  && ok "Step 0b-0 calls gate_exile_watchdog_sweep with the live MARKERS_JSON" \
  || bad "call site missing or drifted"
WATCHDOG_CALL_LINE=$(grep -n 'gate_exile_watchdog_sweep "\$MARKERS_JSON"' "$DISPATCHER" | head -1 | cut -d: -f1)
# "PAUSE new-run admission" is unique to the actual Step 0b heading further down
# the file — a bare "ga-dxyvxr: quiet-hours admission gate" also appears in the
# unrelated top-of-file header/changelog comments (line ~46), which would give a
# false-early line number and silently defeat this ordering check.
QUIET_HOURS_LINE=$(grep -n 'quiet-hours admission gate — PAUSE new-run admission' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$WATCHDOG_CALL_LINE" ] && [ -n "$QUIET_HOURS_LINE" ] && [ "$WATCHDOG_CALL_LINE" -lt "$QUIET_HOURS_LINE" ]; then
  ok "watchdog call (line $WATCHDOG_CALL_LINE) runs BEFORE the quiet-hours admission pause (line $QUIET_HOURS_LINE) — escalation is not blocked by admission gates"
else
  bad "watchdog call ordering drifted relative to quiet-hours gate (watchdog=$WATCHDOG_CALL_LINE quiet_hours=$QUIET_HOURS_LINE)"
fi

echo "── (13) gate-review fix: failed mail does NOT set gate:exile-escalated, so a later sweep retries instead of permanently dropping the escalation ──"
reset_stubs
MAIL_SHOULD_FAIL=1
ELAPSED=$((THRESH + 5000))
SINCE=$((NOW-ELAPSED))
MARKERS=$(printf '[%s]' "$(mk m13 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$SINCE")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
if echo "$MAIL_LOG" | grep -q "mayor" \
   && [ -z "$LABEL_ADD_LOG" ] \
   && echo "$WARN_LOG" | grep -qi "could not mail"; then
  ok "mail attempted and failed -> gate:exile-escalated NOT stamped, failure warned (mail='$MAIL_LOG' labels='$LABEL_ADD_LOG')"
else
  bad "expected an attempted-but-failed mail with no dedup label, got mail='$MAIL_LOG' labels='$LABEL_ADD_LOG' warn='$WARN_LOG'"
fi
# Same marker (since_epoch untouched by the failed attempt, so elapsed only
# grew) is reconsidered on the NEXT sweep because gate:exile-escalated was
# never applied. Simulate that sweep with mail now succeeding.
MAIL_SHOULD_FAIL=0
LABEL_ADD_LOG=""; MAIL_LOG=""; WARN_LOG=""; STATUS_LOG=""; COMMENT_LOG=""
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$((NOW+200))"
if echo "$MAIL_LOG" | grep -q "mayor" && [ "$LABEL_ADD_LOG" = "|m13:gate:exile-escalated" ]; then
  ok "later sweep (mail now succeeding) retries and escalates for real — the failed attempt was retried, not permanently dropped"
else
  bad "expected retry sweep to succeed and stamp exile-escalated, got mail='$MAIL_LOG' labels='$LABEL_ADD_LOG'"
fi

echo ""; echo "gate-exile-watchdog.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
