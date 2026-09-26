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

# ga-w5jq3d: the watchdog's park now goes through gate_requeue_respecting_external, which
# lives OUTSIDE the SELFTEST-EXTRACT block below. Load the REAL helper (and the rest of the
# lib) via the lib-only entrypoint, exactly like gate-8dehbc-park-external.selftest.sh — a
# hand-written stand-in for the helper would prove nothing about the compare-before-write.
# Sourced BEFORE the stubs below, which then override bd/gc/warn/set_gate_status.
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

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
# ga-w5jq3d — the marker the park writes to is now STATEFUL, because the park reads it back
# (gate_requeue_respecting_external -> `bd show`) to see whether another actor moved it after
# the once-per-sweep snapshot. The snapshot ($MARKERS passed to the sweep) is what the sweep
# READ at the start; MARK_LABELS/MARK_STATUS are what the marker looks like at WRITE time.
# An id that is not the tracked MARK_ID reads back as a clean gate-status:queued marker.
MARK_ID=""; MARK_LABELS=""; MARK_STATUS="open"
MAIL_BODY=""          # -m text of the last `gc mail send`
COMMENT_BODY=""       # text of the last `bd comment`
LABEL_RM_LOG=""       # accumulates every `bd label remove <id> <label>` call
EV_LOG=""             # ordered "mail|write:<id>:<st>|comment:<id>|label:<id>:<l>" — for ORDER assertions
SET_RC=0              # when non-zero, the set_gate_status stub fails with it (helper returns it)

labs_json() { local l first=1 out=""; for l in $1; do [ "$first" = 1 ] || out="$out,"; first=0; out="$out\"$l\""; done; printf '%s' "$out"; }
final_gs() { local out="" l; for l in $MARK_LABELS; do case "$l" in gate-status:*) out="$out $l" ;; esac; done; printf '%s' "${out# }"; }

bd() {
  # bd -C "$GC_CITY" label add "$id" "$label" -q
  # bd -C "$GC_CITY" comment "$id" "text"
  # bd -C "$GC_CITY" show "$id" --json
  # $1=-C $2=city consume the first two slots in every call shape above.
  local out l
  if [ "$3" = "show" ]; then
    if [ "$4" = "$MARK_ID" ]; then
      printf '[{"id":"%s","status":"%s","labels":[%s]}]' "$MARK_ID" "$MARK_STATUS" "$(labs_json "$MARK_LABELS")"
    else
      printf '[{"id":"%s","status":"open","labels":["gate-status:queued"]}]' "$4"
    fi
    return 0
  fi
  if [ "$3" = "label" ] && [ "$4" = "add" ]; then
    LABEL_ADD_LOG="$LABEL_ADD_LOG|$5:$6"
    EV_LOG="$EV_LOG|label:$5:$6"
    [ "$5" = "$MARK_ID" ] && MARK_LABELS="$MARK_LABELS $6"
    return 0
  fi
  if [ "$3" = "label" ] && [ "$4" = "remove" ]; then
    LABEL_RM_LOG="$LABEL_RM_LOG|$5:$6"
    if [ "$5" = "$MARK_ID" ]; then
      out=""; for l in $MARK_LABELS; do [ "$l" = "$6" ] || out="$out $l"; done; MARK_LABELS="${out# }"
    fi
    return 0
  fi
  if [ "$3" = "comment" ]; then
    COMMENT_LOG="$COMMENT_LOG|$4"
    COMMENT_BODY="$5"
    EV_LOG="$EV_LOG|comment:$4"
    return 0
  fi
  return 0
}
gc() {
  # gc --city "$GC_CITY" mail send mayor -s SUBJECT -m BODY
  if [ "$1" = "--city" ] && [ "$3" = "mail" ] && [ "$4" = "send" ]; then
    MAIL_LOG="$MAIL_LOG $5"
    MAIL_BODY="$9"
    EV_LOG="$EV_LOG|mail"
    [ "$MAIL_SHOULD_FAIL" = "1" ] && return 1
    return 0
  fi
  return 0
}
warn() { WARN_LOG="$WARN_LOG|$*"; }
# Same effect as the real one (strip EVERY gate-status:*, write the target) on the tracked marker.
set_gate_status() {
  local out l
  STATUS_LOG="$STATUS_LOG|$1:$2"
  EV_LOG="$EV_LOG|write:$1:$2"
  [ "$SET_RC" = "0" ] || return "$SET_RC"
  if [ "$1" = "$MARK_ID" ]; then
    out=""; for l in $MARK_LABELS; do case "$l" in gate-status:*) ;; *) out="$out $l" ;; esac; done
    MARK_LABELS="${out# } gate-status:$2"
  fi
  return 0
}

reset_stubs() {
  LABEL_ADD_LOG=""; COMMENT_LOG=""; MAIL_LOG=""; WARN_LOG=""; STATUS_LOG=""; MAIL_SHOULD_FAIL=0
  MARK_ID=""; MARK_LABELS=""; MARK_STATUS="open"; MAIL_BODY=""; COMMENT_BODY=""; LABEL_RM_LOG=""; EV_LOG=""; SET_RC=0
}

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
if echo "$MAIL_LOG" | grep "mayor" >/dev/null \
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
if echo "$LABEL_ADD_LOG" | grep "fresh_exile:gate:exiled-since:$NOW" >/dev/null \
   && ! echo "$LABEL_ADD_LOG" | grep "under_thresh:gate:exile-escalated" >/dev/null \
   && echo "$LABEL_ADD_LOG" | grep "over_thresh:gate:exile-escalated" >/dev/null \
   && echo "$MAIL_LOG" | grep -v "under_thresh" >/dev/null ; then
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
if echo "$STATUS_LOG" | grep "m10:needs-rebase" >/dev/null; then
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

echo "── (12) drift-guards: shipped dispatcher wires the watchdog into Step 0b, after recovery, before the quiet-hours/headroom gates ──"
# ga-0ye7ar: the watchdog's own MARKERS_JSON input changed from the raw
# $MARKERS_JSON to a $WATCHDOG_MARKERS_JSON filtered by gate_exile_recovery_sweep
# (see quality-gate-dispatcher.sh's own comment at that call site for why: a
# marker gate_exile_recovery_sweep just proved clean and cleared must not be
# re-escalated by the watchdog off a stale pre-recovery label snapshot in the
# same sweep). This selftest still exercises gate_exile_watchdog_sweep()
# directly with hand-built fixtures (unaffected by that rename), so only the
# call-site drift-guards below need updating for it.
grep -q 'gate_exile_watchdog_sweep "\$WATCHDOG_MARKERS_JSON"' "$DISPATCHER" \
  && ok "Step 0b-0 calls gate_exile_watchdog_sweep with the recovery-filtered WATCHDOG_MARKERS_JSON" \
  || bad "call site missing or drifted"
RECOVERY_CALL_LINE=$(grep -n 'gate_exile_recovery_sweep "\$MARKERS_JSON"' "$DISPATCHER" | head -1 | cut -d: -f1)
WATCHDOG_CALL_LINE=$(grep -n 'gate_exile_watchdog_sweep "\$WATCHDOG_MARKERS_JSON"' "$DISPATCHER" | head -1 | cut -d: -f1)
# "PAUSE new-run admission" is unique to the actual Step 0b heading further down
# the file — a bare "ga-dxyvxr: quiet-hours admission gate" also appears in the
# unrelated top-of-file header/changelog comments (line ~46), which would give a
# false-early line number and silently defeat this ordering check.
QUIET_HOURS_LINE=$(grep -n 'quiet-hours admission gate — PAUSE new-run admission' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$RECOVERY_CALL_LINE" ] && [ -n "$WATCHDOG_CALL_LINE" ] && [ -n "$QUIET_HOURS_LINE" ] \
   && [ "$RECOVERY_CALL_LINE" -lt "$WATCHDOG_CALL_LINE" ] && [ "$WATCHDOG_CALL_LINE" -lt "$QUIET_HOURS_LINE" ]; then
  ok "gate_exile_recovery_sweep (line $RECOVERY_CALL_LINE) runs BEFORE gate_exile_watchdog_sweep (line $WATCHDOG_CALL_LINE), both BEFORE the quiet-hours admission pause (line $QUIET_HOURS_LINE) — ga-0ye7ar: recovery gets first crack at a stale exile before the watchdog can escalate it, and neither is blocked by admission gates"
else
  bad "call ordering drifted (recovery=$RECOVERY_CALL_LINE watchdog=$WATCHDOG_CALL_LINE quiet_hours=$QUIET_HOURS_LINE)"
fi

echo "── (13) gate-review fix: failed mail does NOT set gate:exile-escalated, so a later sweep retries instead of permanently dropping the escalation ──"
reset_stubs
MAIL_SHOULD_FAIL=1
ELAPSED=$((THRESH + 5000))
SINCE=$((NOW-ELAPSED))
MARKERS=$(printf '[%s]' "$(mk m13 "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$SINCE")")
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$NOW"
# ga-faw5o gate_run=ga-eki4f (round 2): STATUS_LOG is asserted empty here too,
# not just LABEL_ADD_LOG. The round-1 fix only gated gate:exile-escalated on
# mail success but left set_gate_status("needs-rebase") unconditional — this
# strips gate-status:queued from the marker regardless of mail outcome, and
# the dispatcher's sole caller (Step 0b-0) scopes $markers_json to
# gate-status:queued at fetch time with no re-fetch inside a sweep, so an
# unconditional status flip on a FAILED attempt would remove the marker from
# the only query that can ever re-select it — permanently dropping the retry
# through a different door than the one round-1 closed. This exact gap is why
# round-1's case (13) passed against the still-buggy code: it never looked at
# STATUS_LOG.
#
# ga-faw5o gate_run=ga-wyejo (round 3): COMMENT_LOG is now asserted empty
# here too. Rounds 1-2 gated the dedup label and the status transition on
# mail success, but the bd comment call — which unconditionally asserted
# "Escalating to Mayor now and parking at gate-status:needs-rebase" as
# accomplished fact — still ran BEFORE the mail if/else, so it fired on
# every failed sweep too, writing a false completed-action claim to the
# bead's audit trail. This exact gap is why round-2's case (13) passed
# against the still-buggy code: it never looked at COMMENT_LOG either.
if echo "$MAIL_LOG" | grep "mayor" >/dev/null \
   && [ -z "$LABEL_ADD_LOG" ] \
   && [ -z "$STATUS_LOG" ] \
   && [ -z "$COMMENT_LOG" ] \
   && echo "$WARN_LOG" | grep -i "could not mail" >/dev/null; then
  ok "mail attempted and failed -> gate:exile-escalated NOT stamped, gate-status left untouched, NO bead comment posted (marker stays gate-status:queued and selectable), failure warned (mail='$MAIL_LOG' labels='$LABEL_ADD_LOG' status='$STATUS_LOG' comment='$COMMENT_LOG')"
else
  bad "expected an attempted-but-failed mail with no dedup label, no status change, and no comment, got mail='$MAIL_LOG' labels='$LABEL_ADD_LOG' status='$STATUS_LOG' comment='$COMMENT_LOG' warn='$WARN_LOG'"
fi
# Same marker (since_epoch untouched by the failed attempt, so elapsed only
# grew) is reconsidered on the NEXT sweep because gate:exile-escalated was
# never applied AND gate-status:queued was never stripped (all three writes
# now gated on the identical success condition). Simulate that sweep with
# mail now succeeding.
MAIL_SHOULD_FAIL=0
LABEL_ADD_LOG=""; MAIL_LOG=""; WARN_LOG=""; STATUS_LOG=""; COMMENT_LOG=""
gate_exile_watchdog_sweep "$MARKERS" "$THRESH" "$((NOW+200))"
if echo "$MAIL_LOG" | grep "mayor" >/dev/null \
   && [ "$LABEL_ADD_LOG" = "|m13:gate:exile-escalated" ] \
   && [ "$STATUS_LOG" = "|m13:needs-rebase" ] \
   && [ "$COMMENT_LOG" = "|m13" ]; then
  ok "later sweep (mail now succeeding) retries, escalates for real, NOW parks at needs-rebase, AND posts the bead comment describing that real action — the failed attempt was retried, not permanently dropped, and no false comment was left behind from the failed sweep (labels='$LABEL_ADD_LOG' status='$STATUS_LOG' comment='$COMMENT_LOG')"
else
  bad "expected retry sweep to succeed, stamp exile-escalated, set gate-status, and post the comment, got mail='$MAIL_LOG' labels='$LABEL_ADD_LOG' status='$STATUS_LOG' comment='$COMMENT_LOG'"
fi

# ══════════════════════════════════════════════════════════════════════════════════
# ga-w5jq3d — the park must respect an external gate-status transition
#
# CLASS (ga-8dehbc, the 25/09 incident): set_gate_status strips EVERY gate-status:* and
# writes the target, so a transition another actor made after the sweep read its snapshot
# was erased by the sweep's own write. The watchdog parks a marker it read ONCE from a
# `-l gate-status:queued` snapshot; between that read and the write pass seconds (the Mayor
# mail send included). ga-8dehbc routed the 7 rebase-decision parks through
# gate_requeue_respecting_external and waived this one, because here the marker sits at
# `queued` (not `dispatching`) and the Mayor mail used to say "Parked" BEFORE the write.
#
# Cases 14-23 run the sweep under `set -e` (like the live dispatcher) against a STATEFUL
# marker: the snapshot says queued, the marker at WRITE time says whatever the case sets.
# ══════════════════════════════════════════════════════════════════════════════════
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
# run_sweep_e <markers-json> [now] — the sweep under `set -e`; no "RC=" line = it aborted.
run_sweep_e() {
  OUT=$( { set -e; gate_exile_watchdog_sweep "$1" "$THRESH" "${2:-$NOW}"; echo "RC=$?"
         echo "GS=$(final_gs)"; echo "STATUS=$STATUS_LOG"; echo "COMMENT=$COMMENT_LOG"
         echo "LABELS=$LABEL_ADD_LOG"; echo "LBLRM=$LABEL_RM_LOG"; echo "MAIL=$MAIL_LOG"
         echo "BODY=$(printf '%s' "$MAIL_BODY" | tr '\n' ' ')"; echo "CBODY=$(printf '%s' "$COMMENT_BODY" | tr '\n' ' ')"
         echo "EV=$EV_LOG"; echo "WARN=$(printf '%s' "$WARN_LOG" | tr '\n' ' ')"; } 2>&1 )
}
hasx() { printf '%s' "$1" | grep -qF -- "$2"; }   # hasx <haystack> <needle>
OVER=$((THRESH + 5000))
# snap <id> — the snapshot the sweep reads: a queued, exiled, past-threshold marker
snap() { printf '[%s]' "$(mk "$1" "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-OVER))")"; }

echo "── (14) THE BUG: another actor moved the marker after the snapshot — that transition survives ──"
reset_stubs
mark_set() { MARK_ID="$1"; MARK_LABELS="$2"; MARK_STATUS="${3:-open}"; }
mark_set m14 "gate:exiled-tier5:2 gate:exiled-since:$((NOW-OVER)) gate-status:error"
run_sweep_e "$(snap m14)"
if [ "$(getl RC)" = "0" ] && [ "$(getl GS)" = "gate-status:error" ] && [ -z "$(getl STATUS)" ]; then
  ok "marker moved to gate-status:error after the snapshot: it is STILL gate-status:error, set_gate_status was never called, the sweep did not abort under set -e"
else
  bad "external gate-status:error was overwritten or the sweep aborted — rc='$(getl RC)' final='$(getl GS)' writes='$(getl STATUS)'"
fi
if [ -z "$(getl COMMENT)" ] && [ -z "$(getl LABELS)" ]; then
  ok "no marker comment and NO gate:exile-escalated dedup label for a marker that was not parked (the escalation premise is stale; if it comes back to queued it is re-evaluated)"
else
  bad "a skipped park still commented/stamped the dedup label — comment='$(getl COMMENT)' labels='$(getl LABELS)'"
fi
if hasx "$(getl WARN)" "m14" && hasx "$(getl WARN)" "NOT park"; then
  ok "the skip is never silent: warn names the marker and says it was NOT parked"
else
  bad "expected a warn naming m14 and saying it was NOT parked, got warn='$(getl WARN)'"
fi

echo "── (15) a foreign gate-status:dispatching (another sweep's claim) counts as external — expected_status is queued, not dispatching ──"
reset_stubs
mark_set m15 "gate:exiled-tier5:2 gate-status:queued gate-status:dispatching"
run_sweep_e "$(snap m15)"
if [ "$(getl RC)" = "0" ] && [ "$(getl GS)" = "gate-status:dispatching" ] && [ -z "$(getl STATUS)" ] \
   && [ "$(getl LBLRM)" = "|m15:gate-status:queued" ]; then
  ok "claim in flight (queued+dispatching both present): dispatching survives, only the transient gate-status:queued the sweep saw is dropped, nothing parked"
else
  bad "a dispatching marker was parked over — final='$(getl GS)' writes='$(getl STATUS)' removed='$(getl LBLRM)'"
fi

echo "── (16) marker CLOSED after the snapshot is left exactly as it is ──"
reset_stubs
mark_set m16 "gate:exiled-tier5:2 gate-status:queued" closed
run_sweep_e "$(snap m16)"
if [ "$(getl RC)" = "0" ] && [ "$(getl GS)" = "gate-status:queued" ] && [ -z "$(getl STATUS)" ] \
   && [ -z "$(getl LBLRM)" ] && [ -z "$(getl COMMENT)" ] && [ -z "$(getl LABELS)" ]; then
  ok "closed marker: no status write, no label touched (stripping its only gate-status label would make ensure 'repair' it with a false error), no comment, no dedup label"
else
  bad "a closed marker was touched — final='$(getl GS)' writes='$(getl STATUS)' removed='$(getl LBLRM)' comment='$(getl COMMENT)' labels='$(getl LABELS)'"
fi

echo "── (17) DECIDED: a needs-rebase ALREADY on the marker (the Mayor parked it first) is not foreign — the park completes ──"
reset_stubs
mark_set m17 "gate:exiled-tier5:2 gate-status:needs-rebase"
run_sweep_e "$(snap m17)"
if [ "$(getl RC)" = "0" ] && [ "$(getl GS)" = "gate-status:needs-rebase" ] && [ "$(getl STATUS)" = "|m17:needs-rebase" ] \
   && [ "$(getl COMMENT)" = "|m17" ] && [ "$(getl LABELS)" = "|m17:gate:exile-escalated" ]; then
  ok "Mayor already parked it: the write is idempotent, the marker IS at needs-rebase, so the comment and the dedup label are true and are written (the helper excludes its own target, same as ga-8dehbc)"
else
  bad "needs-rebase already present must count as parked — final='$(getl GS)' writes='$(getl STATUS)' comment='$(getl COMMENT)' labels='$(getl LABELS)'"
fi

echo "── (18) normal case: nothing external — parks, and only THEN comments and stamps the dedup label ──"
reset_stubs
mark_set m18 "gate:exiled-tier5:2 gate-status:queued"
run_sweep_e "$(snap m18)"
if [ "$(getl RC)" = "0" ] && [ "$(getl GS)" = "gate-status:needs-rebase" ] && [ "$(getl STATUS)" = "|m18:needs-rebase" ]; then
  ok "no external transition: the marker ends at gate-status:needs-rebase through one write"
else
  bad "the normal park regressed — final='$(getl GS)' writes='$(getl STATUS)'"
fi
if [ "$(getl EV)" = "|mail|write:m18:needs-rebase|comment:m18|label:m18:gate:exile-escalated" ]; then
  ok "ORDER: mail -> park write -> comment -> dedup label. The park stays AFTER the mail (ga-faw5o round 2: a failed mail must not drop the marker out of the queued rotation), and what is written on the marker describes a park that already happened"
else
  bad "order drifted — expected '|mail|write:m18:needs-rebase|comment:m18|label:m18:gate:exile-escalated', got '$(getl EV)'"
fi
if hasx "$(getl CBODY)" "PARKED"; then
  ok "the marker comment says the marker WAS parked (past tense, written after the write)"
else
  bad "marker comment does not report the park as done: '$(getl CBODY)'"
fi

echo "── (19) the Mayor mail is sent BEFORE the write, so it must not assert a park it cannot know about ──"
if ! printf '%s' "$(getl BODY)" | grep -qiE 'parked at|has been parked|was parked'; then
  ok "mail body does not claim 'Parked at gate-status:needs-rebase' (it goes out before the write; if the write is skipped that sentence would be false)"
else
  bad "mail body still asserts an accomplished park: '$(getl BODY)'"
fi
if hasx "$(getl BODY)" "m18" && hasx "$(getl BODY)" "needs-rebase" && hasx "$(getl BODY)" "bd show"; then
  ok "…and it still names the marker, the needs-rebase target and where to look (bd show), so the Mayor keeps what he needs to act"
else
  bad "mail body lost its actionable content: '$(getl BODY)'"
fi
# the same mail on the SKIPPED path: still sent (it precedes the write), still no park claim
reset_stubs
mark_set m19 "gate:exiled-tier5:2 gate-status:error"
run_sweep_e "$(snap m19)"
if [ -n "$(getl MAIL)" ] && ! printf '%s' "$(getl BODY)$(getl CBODY)" | grep -qiE 'parked at|has been parked|was parked'; then
  ok "skipped park: no message anywhere (mail body, marker comment) says the marker was parked"
else
  bad "a skipped park left a message claiming a park — mail='$(getl MAIL)' body='$(getl BODY)' comment='$(getl CBODY)'"
fi

echo "── (20) the write itself FAILS (rc other than 0/10): not narrated as a park, not blamed on another actor, sweep survives set -e ──"
reset_stubs
mark_set m20 "gate:exiled-tier5:2 gate-status:queued"
SET_RC=7
run_sweep_e "$(snap m20)"
if [ "$(getl RC)" = "0" ] && [ -z "$(getl COMMENT)" ] && [ -z "$(getl LABELS)" ] \
   && hasx "$(getl WARN)" "rc=7" && ! hasx "$(getl WARN)" "another actor"; then
  ok "failed write (rc=7): the block does not abort under set -e, no comment, no dedup label, warned as a failed write and never as 'another actor'"
else
  bad "failed write mishandled — rc='$(getl RC)' comment='$(getl COMMENT)' labels='$(getl LABELS)' warn='$(getl WARN)'"
fi

echo "── (21) one skipped marker does not stop the sweep: a later marker in the same snapshot is still parked ──"
reset_stubs
mark_set skipme "gate:exiled-tier5:2 gate-status:error"
MARKERS=$(printf '[%s,%s]' \
  "$(mk skipme "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-OVER))")" \
  "$(mk parkme "gate-status:queued,gate:exiled-tier5:2,gate:exiled-since:$((NOW-OVER))")")
run_sweep_e "$MARKERS"
if [ "$(getl RC)" = "0" ] && [ "$(getl GS)" = "gate-status:error" ] && [ "$(getl STATUS)" = "|parkme:needs-rebase" ] \
   && [ "$(getl LABELS)" = "|parkme:gate:exile-escalated" ]; then
  ok "skipme kept its external gate-status:error; parkme (clean) was parked and stamped — per-marker outcomes, no early exit"
else
  bad "multi-marker sweep wrong — rc='$(getl RC)' skipme='$(getl GS)' writes='$(getl STATUS)' labels='$(getl LABELS)'"
fi

echo "── (22) a skipped marker is NOT dedup-stamped, so when it comes back to queued a later sweep re-evaluates it ──"
reset_stubs
mark_set m22 "gate:exiled-tier5:2 gate:exiled-since:$((NOW-OVER)) gate-status:error"
run_sweep_e "$(snap m22)"
FIRST_LABELS="$(getl LABELS)"; FIRST_GS="$(getl GS)"
# the Mayor requeues it by hand: back to queued, still carrying the exile labels
reset_stubs
mark_set m22 "gate:exiled-tier5:2 gate:exiled-since:$((NOW-OVER)) gate-status:queued"
run_sweep_e "$(snap m22)" "$((NOW+300))"
if [ -z "$FIRST_LABELS" ] && [ "$FIRST_GS" = "gate-status:error" ] \
   && [ "$(getl GS)" = "gate-status:needs-rebase" ] && [ "$(getl LABELS)" = "|m22:gate:exile-escalated" ]; then
  ok "sweep 1 skipped (no dedup label); after a hand requeue, sweep 2 escalates and parks for real and stamps the dedup label — a skip never silences the watchdog for good"
else
  bad "skip/retry lifecycle wrong — sweep1 labels='$FIRST_LABELS' final='$FIRST_GS'; sweep2 final='$(getl GS)' labels='$(getl LABELS)'"
fi

echo "── (23) mail FAILS: the park write is never attempted (the ga-faw5o round-2 guarantee survives the rewrite) ──"
reset_stubs
mark_set m23 "gate:exiled-tier5:2 gate-status:queued"
MAIL_SHOULD_FAIL=1
run_sweep_e "$(snap m23)"
if [ "$(getl RC)" = "0" ] && [ -z "$(getl STATUS)" ] && [ "$(getl GS)" = "gate-status:queued" ] \
   && [ -z "$(getl COMMENT)" ] && [ -z "$(getl LABELS)" ] && [ "$(getl EV)" = "|mail" ]; then
  ok "failed mail: the only event is the mail attempt — no read-back, no write, no comment, no label; the marker stays gate-status:queued and is retried"
else
  bad "a failed mail still parked/commented — final='$(getl GS)' events='$(getl EV)'"
fi

echo "── (24) can't-know: the helper and its rc constant are not loaded, under set -eu → inert FAILED branch, the sweep survives ──"
# The dispatcher runs `set -euo pipefail`. GATE_REQUEUE_RESPECTED_RC is defined far below this
# function; if it were ever unbound here, comparing against it would abort the WHOLE dispatcher
# sweep instead of taking the inert branch. "I cannot tell respected from failed" must answer
# "not known to be parked" (write nothing more), never crash the sweep.
reset_stubs
mark_set m24 "gate:exiled-tier5:2 gate-status:queued"
OUT=$( { set -eu; unset -f gate_requeue_respecting_external; unset GATE_REQUEUE_RESPECTED_RC
         gate_exile_watchdog_sweep "$(snap m24)" "$THRESH" "$NOW"; echo "RC=$?"
         echo "COMMENT=$COMMENT_LOG"; echo "LABELS=$LABEL_ADD_LOG"; echo "STATUS=$STATUS_LOG"
         echo "WARN=$(printf '%s' "$WARN_LOG" | tr '\n' ' ')"; } 2>&1 )
if [ "$(getl RC)" = "0" ] && [ -z "$(getl COMMENT)" ] && [ -z "$(getl LABELS)" ] && [ -z "$(getl STATUS)" ] \
   && hasx "$(getl WARN)" "FAILED (rc=127)" && ! hasx "$OUT" "unbound variable"; then
  ok "helper missing (rc=127) and the constant unbound: warned as a FAILED write, nothing written, no comment, no dedup label, and no 'unbound variable' abort of the sweep"
else
  bad "an unloadable helper/constant crashed or mis-narrated the sweep — out=[$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)]"
fi

echo ""; echo "gate-exile-watchdog.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
