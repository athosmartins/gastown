#!/usr/bin/env bash
# gate-8dehbc-park-external.selftest.sh (ga-8dehbc, 2026-09-26)
#
# CLASS: set_gate_status strips EVERY gate-status:* and writes the target, so a
# transition another actor makes while the dispatcher holds a marker (the Mayor's
# needs-rebase at 11:03 on 25/09) is erased by the sweep's own write. ga-a6etc2 fixed
# the 3 rebase-RETRY sites and ga-dl3x9s the 3 other REQUEUE sites, both through
# gate_requeue_respecting_external (compare-before-write). The 7 PARK writers of the
# rebase decision block (`set_gate_status "$MARKER_ID" "needs-rebase"`) were left,
# because a park is not a requeue: after the write each site comments on the marker,
# labels / unassigns / re-routes the SOURCE bead, nudges the author or mails the Mayor.
# If an external transition wins, none of that may run — the marker was not parked, and
# every one of those messages would be a false statement about it.
#
#   S1 pool-author         (ga-tz0op)   returns the bead to the pool: unassign + re-route
#   S2 behind-bounce       (ga-6dp9)    author live, base too far behind main
#   S3 behind-owner        (ga-ivzbuz)  author dead, bead owner live
#   S4 live-conflict       (gt-4tk5m)   author live, genuine merge conflict
#   S5 live-exhausted      (gt-4tk5m)   author live, transient failures exhausted
#   S6 dead-conflict       (ga-q3ig2)   author dead, genuine merge conflict
#   S7 dead-exhausted      (ga-acb)     author dead, retries exhausted / cap / stuck counter
#
# What this file locks, per site (each block is extracted from the LIVE dispatcher by
# sentinel and run under `set -e` against a stateful marker + source-bead stub):
#   * external gate-status (deferred/error/passed/failed/superseded) present at the write
#       -> it survives; NO marker comment, NO source-bead label/unassign/re-route,
#          NO nudge/mail; the verdict says PARK-SKIPPED; the closing self-heal is skipped
#   * marker CLOSED mid-sweep -> left exactly as it is
#   * DECIDED PER SITE (bead ga-8dehbc asked for it): a needs-rebase ALREADY on the marker
#     (the Mayor parked it first) is NOT "foreign" — the helper excludes its own target —
#     so the park runs in full. The side effects are idempotent and the source bead still
#     needs its gate:needs-rebase label / re-route, or the pool would never see it.
#   * write FAILS (rc other than 0/10) -> not narrated as a park, not blamed on another
#     actor, does not abort the block under `set -e`, and the closing self-heal STILL runs
#   * marker unreadable -> legacy write, loudly (UNVERIFIED)
# and the class lock: no raw needs-rebase writer may come back without a waiver
# (`# park-raw-ok: <why>`), with a detector that is itself tested. ga-w5jq3d closed the one
# waived writer (the exile watchdog's park), so the lock now also asserts ZERO waived writers;
# that path's own behaviour is locked in gate-exile-watchdog.selftest.sh (cases 14-23).
#
# Exit 0 iff every assertion holds. Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }   # has <haystack> <needle>

echo "== gate-8dehbc-park-external.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# /bin/bash -n, never bare `bash -n` (Homebrew bash 5.3 accepts what 3.2 rejects).
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then
  ok "dispatcher parses under /bin/bash (3.2) — the interpreter launchd actually runs"
else
  bad "dispatcher does NOT parse under /bin/bash 3.2"
fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

# ── 1. the class lock, and the detector behind it ──────────────────────────────
echo "── 1. no raw needs-rebase PARK writer in the dispatcher ──"
# raw_park_writers < file : prints "<line>:<text>" for every non-comment line that writes
# gate-status:needs-rebase without going through gate_requeue_respecting_external.
PARK_RAW_RE='set_gate_status[[:space:]]+"[^"]*"[[:space:]]+"needs-rebase"|label[[:space:]]+add[[:space:]]+[^#]*gate-status:needs-rebase'
raw_park_writers() {
  grep -nE "$PARK_RAW_RE" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'park-raw-ok'
}
# waived_park_writers < file : the raw writers raw_park_writers skips ONLY because they carry a
# `# park-raw-ok` waiver. Counts real writers, never the word in a comment (the dispatcher's own
# header explains the mechanism and so mentions it).
waived_park_writers() {
  grep -nE "$PARK_RAW_RE" | grep -vE '^[0-9]+:[[:space:]]*#' | grep 'park-raw-ok'
}
# A detector nobody tests is a detector that silently stops detecting.
DET_FIXTURE='    set_gate_status "$MARKER_ID" "needs-rebase"  # ga-7fwt1
  set_gate_status "$marker_id"   "needs-rebase"
bd -C "$GC_CITY" label add "$M" "gate-status:needs-rebase" -q
    # set_gate_status "$MARKER_ID" "needs-rebase"   (a comment)
set_gate_status "$X" "needs-rebase"  # park-raw-ok: exile watchdog holds queued, not dispatching
gate_requeue_respecting_external "$MARKER_ID" "needs-rebase" "dispatching"
set_gate_status "$MARKER_ID" "queued"'
DET_OUT="$(printf '%s\n' "$DET_FIXTURE" | raw_park_writers)"
DET_N="$(printf '%s\n' "$DET_OUT" | grep -c .)"
if [ "$DET_N" = "3" ] && has "$DET_OUT" '1:' && has "$DET_OUT" '2:' && has "$DET_OUT" '3:'; then
  ok "detector self-test: flags the 3 raw forms; ignores the comment, the waived line, the helper call and other statuses"
else
  bad "detector self-test: expected exactly fixture lines 1,2,3 flagged, got [$DET_OUT]"
fi
DET_WAIVED="$(printf '%s\n' "$DET_FIXTURE" | waived_park_writers)"
if [ "$(printf '%s\n' "$DET_WAIVED" | grep -c .)" = "1" ] && has "$DET_WAIVED" '5:'; then
  ok "waiver detector self-test: finds exactly the one waived writer (fixture line 5), not the comment or the helper call"
else
  bad "waiver detector self-test: expected exactly fixture line 5, got [$DET_WAIVED]"
fi
LIVE_RAW="$(raw_park_writers < "$DISPATCHER" || true)"
if [ -z "$LIVE_RAW" ]; then
  ok "THE CLASS: the dispatcher has zero unwaived raw needs-rebase writers (was 8: the 7 rebase-decision parks + the exile watchdog)"
else
  bad "raw needs-rebase writer(s) — route through gate_requeue_respecting_external <id> needs-rebase dispatching, or waive with '# park-raw-ok: <why>': $LIVE_RAW"
fi
# ga-w5jq3d closed the LAST waived writer: the exile watchdog's park goes through the helper too
# (expected_status `queued` — it holds a marker from a gate-status:queued snapshot, not a
# `dispatching` claim). A waiver is visible debt, so none may come back unnoticed: adding one
# means editing this assertion on purpose.
LIVE_WAIVED="$(waived_park_writers < "$DISPATCHER" || true)"
if [ -z "$LIVE_WAIVED" ]; then
  ok "THE CLASS, fully closed: zero WAIVED raw needs-rebase writers either — the exile watchdog's park no longer needs its waiver (ga-w5jq3d)"
else
  bad "a waived raw needs-rebase writer is back (ga-w5jq3d removed the last one) — route it through gate_requeue_respecting_external, or justify the waiver by updating this assertion: $LIVE_WAIVED"
fi

# ── 2. the helpers, on their own ────────────────────────────────────────────────
echo "── 2. gate_park_note_skipped, and the 3 early-exit tails' closing self-heal ──"
if declare -F gate_park_note_skipped >/dev/null 2>&1; then
  # rc 10 = an external transition was respected; anything else = the write failed.
  ns() { ( set -e; _REQUEUE_RESPECTED=; REBASE_EVENT=; REBASE_VERDICT=
           gate_park_note_skipped "$@"; echo "RESP=${_REQUEUE_RESPECTED:-} EVENT=$REBASE_EVENT VERDICT=$REBASE_VERDICT RC=0" ) 2>&1; }
  N10="$(ns 10)"; N1="$(ns 1)"; N255="$(ns 255)"; NEMPTY="$(ns "")"; NNONE="$(ns)"
  if has "$N10" "RESP=1 EVENT=dispatcher_park_respected_external" && has "$N10" "PARK-SKIPPED" && has "$N10" "RC=0" \
     && ! has "$N10" "NEEDS_REBASE (" && ! has "$N10" "write returned"; then
    ok "note_skipped 10 (GATE_REQUEUE_RESPECTED_RC): respected → _REQUEUE_RESPECTED=1, PARK-SKIPPED wording, no 'parked' claim"
  else
    bad "note_skipped 10 wrong: [$N10]"
  fi
  for pair in "1|$N1" "255|$N255"; do
    rc="${pair%%|*}"; out="${pair#*|}"
    if has "$out" "RESP= EVENT=dispatcher_park_write_failed" && has "$out" "PARK-FAILED" && has "$out" "rc=$rc" \
       && ! has "$out" "another actor" && has "$out" "RC=0"; then
      ok "note_skipped $rc: a FAILED write leaves _REQUEUE_RESPECTED unset (the closing self-heal must run), named as a failed write, never as 'another actor'"
    else
      bad "note_skipped $rc wrong: [$out]"
    fi
  done
  for pair in "empty|$NEMPTY" "missing|$NNONE"; do
    lbl="${pair%%|*}"; out="${pair#*|}"
    if has "$out" "RESP= EVENT=dispatcher_park_write_failed" && has "$out" "rc=unknown" && has "$out" "RC=0" && ! has "$out" "RESP=1"; then
      ok "note_skipped with a $lbl rc: could-not-tell takes the inert side (no respected claim, rc=unknown), returns 0 under set -e"
    else
      bad "note_skipped with a $lbl rc must not read as respected: [$out]"
    fi
  done
else
  bad "gate_park_note_skipped is not defined (the skipped path has no way to word its verdict)"
fi

# The 3 early-exit park sites (pool-author, behind-bounce, behind-owner) each exit 0 on their own,
# so they never reach the shared tail that already honours _REQUEUE_RESPECTED. Their closing
# ga-kgtiw self-heal is guarded inline (sentinel blocks ga-8dehbc-heal-<site>): after an external
# transition was respected gate_marker_status_ensure must NOT run — it never looks at .status and
# would "repair" a closed marker with a gate-status:error and a false Mayor alarm.
ENSURE_LOG="$(mktemp "${TMPDIR:-/tmp}/8dehbc-ensure.XXXXXX")"
SHOW_LOG="$(mktemp "${TMPDIR:-/tmp}/8dehbc-show.XXXXXX")"
trap 'rm -f "$ENSURE_LOG" "$SHOW_LOG"' EXIT
ENSURE_ANSWER="ok"
gate_marker_status_ensure() { printf 'ENSURE:%s|%s\n' "$1" "${2:-}" >> "$ENSURE_LOG"; printf '%s' "$ENSURE_ANSWER"; }
warn() { printf 'WARN:%s\n' "$*"; return 0; }
log()  { printf 'LOG:%s\n' "$*"; return 0; }
for pair in "pool-author|the pool-author rebase return" "behind-bounce|the behind-envelope bounce" "behind-owner|the behind-envelope owner-fallback bounce"; do
  HS="${pair%%|*}"; HWHAT="${pair#*|}"
  HSRC="$(extract_block "$DISPATCHER" "ga-8dehbc-heal-$HS")"
  [ -n "$HSRC" ] || { echo "FATAL: sentinel block ga-8dehbc-heal-$HS not found (moved/renamed?)" >&2; exit 2; }
  eval "run_heal_${HS//-/_}() {
$HSRC
}"
  heal_run() { # heal_run <respected-flag|UNSET> <ensure-answer>  → $OUT (stdout of the block) + $ENSURE_LOG
    : > "$ENSURE_LOG"; ENSURE_ANSWER="$2"
    OUT=$( set -e; MARKER_ID="m-heal"; if [ "$1" = "UNSET" ]; then unset _REQUEUE_RESPECTED; else _REQUEUE_RESPECTED="$1"; fi
           "run_heal_${HS//-/_}"; echo "RC=0" ) 2>&1
  }
  heal_run 1 repaired
  if [ ! -s "$ENSURE_LOG" ] && has "$OUT" "LOG:  ga-kgtiw self-heal skipped for marker m-heal" && ! has "$OUT" "WARN:" && has "$OUT" "RC=0"; then
    ok "$HS tail: external transition respected → ensure is NOT called (even though it would answer 'repaired'), the skip is logged, no false SELF-HEAL warning"
  else
    bad "$HS tail: respected must skip ensure: ensure=[$(cat "$ENSURE_LOG")] out=[$OUT]"
  fi
  heal_run "" ok
  if [ "$(grep -c . "$ENSURE_LOG")" = "1" ] && has "$(cat "$ENSURE_LOG")" "ENSURE:m-heal|$HWHAT" && ! has "$OUT" "WARN:" && ! has "$OUT" "self-heal skipped" && has "$OUT" "RC=0"; then
    ok "$HS tail: marker status was written → the closing ensure runs once, with the description this site always passed ('$HWHAT')"
  else
    bad "$HS tail: normal case must call ensure once with '$HWHAT': ensure=[$(cat "$ENSURE_LOG")] out=[$OUT]"
  fi
  heal_run UNSET ok
  if [ "$(grep -c . "$ENSURE_LOG")" = "1" ] && has "$OUT" "RC=0" && ! has "$OUT" "unbound variable"; then
    ok "$HS tail: _REQUEUE_RESPECTED never set (the flag only exists after a skipped park) → ensure runs, no unbound-variable abort under set -u/-e"
  else
    bad "$HS tail: an unset _REQUEUE_RESPECTED must behave as 'not respected': ensure=[$(cat "$ENSURE_LOG")] out=[$OUT]"
  fi
  heal_run "" repaired
  if has "$OUT" "WARN:ga-kgtiw SELF-HEAL: marker m-heal had no gate-status label after $HWHAT — self-heal force-wrote and verified gate-status:error"; then
    ok "$HS tail: ensure repaired the marker → the SELF-HEAL warning keeps its original wording"
  else
    bad "$HS tail: repaired case lost its SELF-HEAL warning: out=[$OUT]"
  fi
done
unset -f gate_marker_status_ensure warn log

# ── 3. the 7 sites, behaviour ────────────────────────────────────────────────────
echo "── 3. per-site behaviour: an external transition survives, the park narrates only what happened ──"
MARKER_ID="m-8dehbc"; BEAD_ID="bead-8dehbc"; BEAD_CITY="bead-city"; GC_CITY="test-city"
BRANCH="fix/ga-8dehbc-fixture"; REBASE_AUTHOR="crew-author"; OWNER="crew-owner"; AUTHOR="crew-author"
REBASE_BEHIND=99; GATE_REBASE_BEHIND_MAX=50; DEFAULT_BRANCH="main"; MAIN_HEAD_SHA="abc1234"
CONFLICT_FILES="a.sh b.sh"; BRANCH_HAS_MERGE_IN_RANGE=0; REBASE_LIVENESS_TRACE="trace"
MAX_REBASE_ATTEMPTS=3; NEXT_ATTEMPT=3; _PUSH_DIAG="push failed; cause not captured"
_CAP_NOTE=""; _ESC_SUBJ="Gate escalation: fixture"; RIG="rig-fixture"
_TZ0OP_ROUTE="gastown.dog"; _TZ0OP_ROUTE_UNKNOWN=0
SHOW_LOG="${SHOW_LOG:-$(mktemp "${TMPDIR:-/tmp}/8dehbc-show.XXXXXX")}"
trap 'rm -f "$SHOW_LOG" "${ENSURE_LOG:-}"' EXIT

BEAD_LABELS0="story:in-flight gate:queued"; BEAD_ASSIGNEE0="worker-x"; BEAD_ROUTE0="wa-worker"
new_case() { # <marker-labels> [status] [raw-show-output | __FAIL__]
  BD_LOG=""; WARN_LOG=""; STATUS_LOG=""; MC_LOG=""; BC_LOG=""; GC_LOG=""
  : > "$SHOW_LOG"
  MARK_LABELS="$1"; MARK_STATUS="${2:-open}"; SHOW_RAW="${3:-}"
  MARKER_SET_RC=0
  BEAD_LABELS="$BEAD_LABELS0"; BEAD_ASSIGNEE="$BEAD_ASSIGNEE0"; BEAD_ROUTE="$BEAD_ROUTE0"
  REBASE_EVENT="PRESET-EVENT"; REBASE_VERDICT="PRESET-VERDICT"; _REQUEUE_RESPECTED=""
}
labs_json() { local l first=1 out=""; for l in $1; do [ "$first" = 1 ] || out="$out,"; first=0; out="$out\"$l\""; done; printf '%s' "$out"; }
marker_json() { printf '[{"id":"%s","status":"%s","labels":[%s]}]' "$MARKER_ID" "$MARK_STATUS" "$(labs_json "$MARK_LABELS")"; }
bead_json()   { printf '[{"id":"%s","status":"open","assignee":"%s","labels":[%s],"metadata":{"gc.routed_to":"%s"}}]' "$BEAD_ID" "$BEAD_ASSIGNEE" "$(labs_json "$BEAD_LABELS")" "$BEAD_ROUTE"; }
strip_gate_status() {
  local out="" l
  for l in $MARK_LABELS; do case "$l" in gate-status:*) ;; *) out="$out $l" ;; esac; done
  MARK_LABELS="${out# }"; return 0
}
final_gs() { local out="" l; for l in $MARK_LABELS; do case "$l" in gate-status:*) out="$out $l" ;; esac; done; printf '%s' "${out# }"; }
flat() { printf '%s' "$1" | tr '\n' ' '; }
bd() {
  BD_LOG="$BD_LOG|$*"
  case "${3:-}" in
    show)
      printf 'show:%s\n' "${4:-}" >> "$SHOW_LOG"
      if [ "${4:-}" = "$MARKER_ID" ]; then
        [ "$SHOW_RAW" = "__FAIL__" ] && return 1
        if [ -n "$SHOW_RAW" ]; then printf '%s' "$SHOW_RAW"; return 0; fi
        marker_json; return 0
      fi
      if [ "${4:-}" = "$BEAD_ID" ]; then bead_json; return 0; fi
      printf '[{"id":"%s","status":"open","labels":[]}]' "${4:-}"; return 0 ;;
    label)
      local out l
      if [ "${5:-}" = "$MARKER_ID" ]; then
        case "${4:-}" in
          add) MARK_LABELS="$MARK_LABELS ${6:-}" ;;
          remove) out=""; for l in $MARK_LABELS; do [ "$l" = "${6:-}" ] || out="$out $l"; done; MARK_LABELS="${out# }" ;;
        esac
      elif [ "${5:-}" = "$BEAD_ID" ]; then
        case "${4:-}" in
          add) BEAD_LABELS="$BEAD_LABELS ${6:-}" ;;
          remove) out=""; for l in $BEAD_LABELS; do [ "$l" = "${6:-}" ] || out="$out $l"; done; BEAD_LABELS="${out# }" ;;
        esac
      fi
      return 0 ;;
    assign) [ "${4:-}" = "$BEAD_ID" ] && BEAD_ASSIGNEE="${5:-}"; return 0 ;;
    update)
      if [ "${4:-}" = "$BEAD_ID" ] && [ "${5:-}" = "--set-metadata" ]; then
        case "${6:-}" in gc.routed_to=*) BEAD_ROUTE="${6#gc.routed_to=}" ;; esac
      fi
      return 0 ;;
    comment)
      if [ "${4:-}" = "$MARKER_ID" ]; then MC_LOG="$MC_LOG|$(flat "${5:-}")"; else BC_LOG="$BC_LOG|$(flat "${5:-}")"; fi
      return 0 ;;
  esac
  return 0
}
gc() { GC_LOG="$GC_LOG|$(flat "$*")"; return 0; }
set_gate_status() {
  STATUS_LOG="$STATUS_LOG|$1:$2"
  if [ "$1" = "$MARKER_ID" ]; then
    [ "$MARKER_SET_RC" = "0" ] || return "$MARKER_SET_RC"
    strip_gate_status; MARK_LABELS="$MARK_LABELS gate-status:$2"
  fi
  return 0
}
warn() { WARN_LOG="$WARN_LOG|$*"; return 0; }
log()  { return 0; }
err()  { WARN_LOG="$WARN_LOG|ERR:$*"; return 0; }
dump_state() {
  echo "GS=$(final_gs)"
  echo "STATUS=$STATUS_LOG"
  echo "MC=$MC_LOG"
  echo "BC=$BC_LOG"
  echo "BL=$BEAD_LABELS"
  echo "BA=$BEAD_ASSIGNEE"
  echo "BR=$BEAD_ROUTE"
  echo "GCL=$GC_LOG"
  echo "WARN=$WARN_LOG"
  echo "EVENT=$REBASE_EVENT"
  echo "VERDICT=$REBASE_VERDICT"
  echo "RESP=${_REQUEUE_RESPECTED:-}"
  echo "SHOWS=$(tr '\n' ' ' < "$SHOW_LOG")"
}
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

SITES="pool-author behind-bounce behind-owner live-conflict live-exhausted dead-conflict dead-exhausted"
for S in $SITES; do
  SRC="$(extract_block "$DISPATCHER" "ga-8dehbc-park-$S")"
  [ -n "$SRC" ] || { echo "FATAL: sentinel block ga-8dehbc-park-$S not found (moved/renamed?)" >&2; exit 2; }
  eval "run_block_${S//-/_}() {
$SRC
}"
done
run_site() { # run_site <site> — under `set -e` like the live dispatcher; no "RC=" line means the block aborted
  local fn="run_block_${1//-/_}"
  OUT=$( set -e; $fn; echo "RC=$?"; dump_state ) 2>&1
}
# site_conf <site> → S_MK (marker comment when parked), S_EVENT (event on a normal park),
# S_GC (a substring the author/Mayor notice must contain on a normal park; "" = none)
site_conf() {
  case "$1" in
    pool-author)    S_MK="Gate BLOCKED (ga-tz0op)";            S_EVENT="dispatcher_needs_rebase_pool_author";                     S_GC="" ;;
    behind-bounce)  S_MK="Gate BLOCKED (ga-6dp9)";             S_EVENT="dispatcher_needs_rebase_behind_envelope";                  S_GC="session nudge crew-author" ;;
    behind-owner)   S_MK="Gate BLOCKED (ga-ivzbuz";            S_EVENT="dispatcher_needs_rebase_behind_envelope_owner_fallback";   S_GC="session nudge crew-owner" ;;
    live-conflict)  S_MK="Gate BLOCKED: branch";               S_EVENT="dispatcher_needs_rebase";                                  S_GC="session nudge crew-author" ;;
    live-exhausted) S_MK="Gate ESCALATED (gt-4tk5m)";          S_EVENT="dispatcher_needs_rebase_transient_escalated";              S_GC="mail send mayor" ;;
    dead-conflict)  S_MK="Gate SKIPPED + ESCALATED (ga-q3ig2)"; S_EVENT="dispatcher_needs_rebase_immediate";                       S_GC="mail send mayor" ;;
    dead-exhausted) S_MK="Gate ESCALATED: branch";             S_EVENT="PRESET-EVENT";                                             S_GC="mail send mayor" ;;
  esac
}
# assert that NO park side effect happened (the marker was not parked)
no_effects() {
  [ -z "$(getl MC)" ] && [ -z "$(getl BC)" ] && [ -z "$(getl GCL)" ] \
    && [ "$(getl BL)" = "$BEAD_LABELS0" ] && [ "$(getl BA)" = "$BEAD_ASSIGNEE0" ] && [ "$(getl BR)" = "$BEAD_ROUTE0" ]
}
effects_summary() { echo "MC=[$(getl MC)] BC=[$(getl BC)] GC=[$(getl GCL)] BL=[$(getl BL)] BA=[$(getl BA)] BR=[$(getl BR)]"; }

for S in $SITES; do
  site_conf "$S"
  echo "  — site: $S —"

  # normal: only our own dispatching label → the park happens exactly as before
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_site "$S"
  if [ "$(getl GS)" = "gate-status:needs-rebase" ] && has "$OUT" "RC=0" && ! has "$OUT" "unbound variable" \
     && has "$(getl SHOWS)" "show:$MARKER_ID" && [ -z "$(getl RESP)" ]; then
    ok "$S: normal case → marker ends exactly at gate-status:needs-rebase, block returns 0 under set -e, marker re-read live before the write"
  else
    bad "$S: normal case must park: GS='$(getl GS)' RESP='$(getl RESP)' out=[$OUT]"
  fi
  if has "$(getl MC)" "$S_MK" && [[ "$(getl BL)" == *"gate:needs-rebase"* ]] \
     && [ "$(getl EVENT)" = "$S_EVENT" ] && has "$(getl VERDICT)" "NEEDS_REBASE"; then
    ok "$S: normal case keeps the original park effects — marker comment, source-bead gate:needs-rebase, event and verdict"
  else
    bad "$S: normal-path park effects changed: EVENT='$(getl EVENT)' VERDICT='$(getl VERDICT)' $(effects_summary)"
  fi
  if [ -z "$S_GC" ] || has "$(getl GCL)" "$S_GC"; then
    ok "$S: normal case still notifies (${S_GC:-no author/Mayor notice at this site})"
  else
    bad "$S: normal case lost its notice '$S_GC': gc=[$(getl GCL)]"
  fi
  if [ "$S" = "pool-author" ]; then
    if [ -z "$(getl BA)" ] && [ "$(getl BR)" = "gastown.dog" ] && [[ "$(getl BL)" != *"story:in-flight"* ]]; then
      ok "$S: normal case still returns the bead to the pool (unassigned, re-routed to gastown.dog, story:in-flight dropped)"
    else
      bad "$S: pool return changed: $(effects_summary)"
    fi
  fi

  # THE INCIDENT SHAPE, and the rest of the class: every external status survives, nothing is narrated
  for ext in deferred error passed failed superseded; do
    new_case "type:quality-gate-marker gate-status:dispatching gate-status:$ext"
    run_site "$S"
    if [ "$(getl GS)" = "gate-status:$ext" ] && has "$OUT" "RC=0" && ! has "$OUT" "unbound variable" \
       && ! has "$(getl STATUS)" "$MARKER_ID:needs-rebase" && has "$(getl WARN)" "respecting it"; then
      ok "$S: external gate-status:$ext survives the park write; only our dispatching label is dropped, and the skip is logged"
    else
      bad "$S: external gate-status:$ext was overwritten or not logged: GS='$(getl GS)' STATUS='$(getl STATUS)' warn=[$(getl WARN)] out=[$OUT]"
    fi
    if no_effects; then
      ok "$S: with gate-status:$ext external, NO marker comment, NO source-bead label/unassign/re-route, NO nudge/mail"
    else
      bad "$S: park side effects ran although the marker was not parked (external $ext): $(effects_summary)"
    fi
    if [ "$(getl RESP)" = "1" ] && [ "$(getl EVENT)" = "dispatcher_park_respected_external" ] \
       && has "$(getl VERDICT)" "PARK-SKIPPED" && ! has "$(getl VERDICT)" "NEEDS_REBASE ("; then
      ok "$S: external $ext → verdict says PARK-SKIPPED (never NEEDS_REBASE) and the closing self-heal is flagged to be skipped"
    else
      bad "$S: skipped-path verdict/flags wrong (external $ext): RESP='$(getl RESP)' EVENT='$(getl EVENT)' VERDICT='$(getl VERDICT)'"
    fi
  done

  new_case "type:quality-gate-marker gate-status:dispatching" closed
  run_site "$S"
  if [ "$(getl GS)" = "gate-status:dispatching" ] && ! has "$(getl STATUS)" "$MARKER_ID:needs-rebase" && no_effects \
     && [ "$(getl RESP)" = "1" ] && has "$OUT" "RC=0"; then
    ok "$S: a marker closed mid-sweep is left exactly as it is — not parked, no effects, self-heal skipped"
  else
    bad "$S: closed marker was touched: GS='$(getl GS)' STATUS='$(getl STATUS)' RESP='$(getl RESP)' $(effects_summary)"
  fi

  # DECIDED PER SITE: a needs-rebase the Mayor already wrote is not foreign; the park still runs in full
  for pre in "gate-status:dispatching gate-status:needs-rebase" "gate-status:needs-rebase"; do
    new_case "type:quality-gate-marker $pre"
    run_site "$S"
    if [ "$(getl GS)" = "gate-status:needs-rebase" ] && has "$(getl MC)" "$S_MK" && [[ "$(getl BL)" == *"gate:needs-rebase"* ]] \
       && [ -z "$(getl RESP)" ] && has "$OUT" "RC=0"; then
      ok "$S: needs-rebase ALREADY on the marker (labels: $pre) is not 'foreign' — the park still runs in full (source bead needs its label/re-route)"
    else
      bad "$S: a pre-existing needs-rebase must not skip the park: GS='$(getl GS)' RESP='$(getl RESP)' $(effects_summary)"
    fi
  done

  # unreadable marker: third state — legacy write, never silent
  for variant in __FAIL__ "this is not json" '{"error":"database is locked"}'; do
    new_case "type:quality-gate-marker gate-status:dispatching" open "$variant"
    run_site "$S"
    if [ "$(getl GS)" = "gate-status:needs-rebase" ] && has "$(getl WARN)" "UNVERIFIED" && has "$(getl MC)" "$S_MK"; then
      ok "$S: unreadable marker [$variant] → legacy park (never stranded at dispatching) AND a visible UNVERIFIED warning"
    else
      bad "$S: unreadable marker [$variant] must park with a warning: GS='$(getl GS)' warn=[$(getl WARN)]"
    fi
  done

  # the gate-status WRITE itself fails: not a park, not "another actor", and no abort under set -e
  new_case "type:quality-gate-marker gate-status:dispatching"
  MARKER_SET_RC=1
  run_site "$S"
  if has "$OUT" "RC=0" && ! has "$OUT" "unbound variable" && [ "$(getl GS)" = "gate-status:dispatching" ]; then
    ok "$S: a FAILED marker write does not abort the block under set -e, and the label is left exactly as it was"
  else
    bad "$S: failed marker write must not abort or relabel: GS='$(getl GS)' out=[$OUT]"
  fi
  if no_effects && [ -z "$(getl RESP)" ] && [ "$(getl EVENT)" = "dispatcher_park_write_failed" ] \
     && has "$(getl VERDICT)" "PARK-FAILED" && has "$(getl VERDICT)" "rc=1" && ! has "$(getl VERDICT)" "another actor"; then
    ok "$S: a failed write is narrated as a failed write (PARK-FAILED, rc=1) with NO park effects, and the self-heal is NOT skipped"
  else
    bad "$S: failed-write handling wrong: RESP='$(getl RESP)' EVENT='$(getl EVENT)' VERDICT='$(getl VERDICT)' $(effects_summary)"
  fi
done

# ── 4. drift-guards on the literals the behaviour depends on ─────────────────────
echo "── 4. source drift-guards ──"
# The hazard bead ga-dl3x9s names: a WRONG expected_status makes the helper read this
# sweep's own label as foreign and strand the marker. Every park call must pass the label
# the marker really holds where it parks: `dispatching` for the 7 rebase-decision sites (the
# marker was claimed queued->dispatching), and `queued` for the ONE exile-watchdog park
# (ga-w5jq3d: it holds a marker read from a gate-status:queued snapshot, never a claim).
PARK_CALLS="$(grep -nE 'gate_requeue_respecting_external[[:space:]]+"[^"]*"[[:space:]]+"needs-rebase"' "$DISPATCHER" | grep -vE '^[0-9]+:[[:space:]]*#')"
QUEUED_PARKS="$(printf '%s\n' "$PARK_CALLS" | grep '"needs-rebase" "queued"' || true)"
REBASE_PARKS="$(printf '%s\n' "$PARK_CALLS" | grep -v '"needs-rebase" "queued"' || true)"
N_PARK="$(printf '%s\n' "$REBASE_PARKS" | grep -c .)"
WRONG_EXPECT="$(printf '%s\n' "$REBASE_PARKS" | grep -v '"needs-rebase" "dispatching"' || true)"
[ "$N_PARK" = "7" ] && ok "exactly 7 park writes go through gate_requeue_respecting_external" \
  || bad "expected 7 park writes through the helper, found $N_PARK — a site lost (or gained) its compare-before-write"
[ -z "$WRONG_EXPECT" ] && ok "every rebase-decision park call passes expected_status=dispatching" \
  || bad "a park call passes a different expected_status — it would strand the marker: $WRONG_EXPECT"
WD_SRC="$(extract_block "$DISPATCHER" "gate-exile-watchdog")"
WD_CALLS="$(printf '%s\n' "$WD_SRC" | grep -E 'gate_requeue_respecting_external[[:space:]]+"[^"]*"[[:space:]]+"needs-rebase"' | grep -vE '^[[:space:]]*#' || true)"
N_WD="$(printf '%s\n' "$WD_CALLS" | grep -c .)"
N_QUEUED="$(printf '%s\n' "$QUEUED_PARKS" | grep -c .)"
if [ "$N_WD" = "1" ] && has "$WD_CALLS" '"needs-rebase" "queued"' && [ "$N_QUEUED" = "1" ]; then
  ok "the exile watchdog's ONE park goes through the helper with expected_status=queued, and no other site uses queued (ga-w5jq3d)"
else
  bad "watchdog park wrong: $N_WD helper park call(s) in its block (want 1, expected_status queued), $N_QUEUED queued-expecting park call(s) in the file (want 1) — expected_status=dispatching there would make its own queued label 'foreign' and it would never park: [$WD_CALLS]"
fi
for S in $SITES; do
  SRC="$(extract_block "$DISPATCHER" "ga-8dehbc-park-$S")"
  C="$(printf '%s\n' "$SRC" | grep -cE 'gate_requeue_respecting_external "\$MARKER_ID" "needs-rebase" "dispatching"')"
  R="$(printf '%s\n' "$SRC" | raw_park_writers | grep -c .)"
  [ "$C" = "1" ] && [ "$R" = "0" ] \
    && ok "$S: its block holds exactly one helper park call and no raw writer" \
    || bad "$S: block has $C helper call(s) (want 1) and $R raw writer(s) (want 0)"
done
# The 3 sites that exit 0 themselves must not run gate_marker_status_ensure after an external
# transition (ensure never looks at .status; it would "repair" a closed marker). Each tail's guard
# lives in its own sentinel block; the block must hold the flag test AND the one ensure call.
for pair in "pool-author|the pool-author rebase return" "behind-bounce|the behind-envelope bounce" "behind-owner|the behind-envelope owner-fallback bounce"; do
  HS="${pair%%|*}"; HWHAT="${pair#*|}"
  HSRC="$(extract_block "$DISPATCHER" "ga-8dehbc-heal-$HS")"
  G="$(printf '%s\n' "$HSRC" | grep -cF '_REQUEUE_RESPECTED:-0')"
  E="$(printf '%s\n' "$HSRC" | grep -cF "gate_marker_status_ensure \"\$MARKER_ID\" \"$HWHAT\"")"
  [ "$G" = "1" ] && [ "$E" = "1" ] \
    && ok "$HS: the early-exit tail guards its self-heal on _REQUEUE_RESPECTED and still calls ensure once" \
    || bad "$HS: tail guard=$G (want 1), ensure calls=$E (want 1) in its ga-8dehbc-heal block"
done
# The literal is only true while the claim puts the marker at dispatching.
grep -qE 'label add "\$MARKER_ID" "gate-status:dispatching"' "$DISPATCHER" \
  && ok "the claim still labels the marker gate-status:dispatching (the state the park sites hold)" \
  || bad "the claim no longer adds gate-status:dispatching to the marker — every expected_status literal is now wrong"

echo ""
echo "gate-8dehbc-park-external.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
