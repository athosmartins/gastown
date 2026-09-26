#!/usr/bin/env bash
# gate-dl3x9s-requeue-external.selftest.sh (ga-dl3x9s, 2026-09-25)
#
# CLASS: set_gate_status strips EVERY gate-status:* and writes the target, so a
# transition another actor makes while the dispatcher holds a marker (the Mayor's
# manual needs-rebase, 25/09 11:03) is erased by the dispatcher's own closing
# write. ga-a6etc2 fixed the 3 rebase-retry sites via gate_requeue_respecting_external
# (compare-before-write). Three raw `set_gate_status ... "queued"` writers were left:
#
#   site 1  gate_finalize_run, REQUEUE_REASON=dead-reviewer   (ga-eqjo)
#   site 2  gate_finalize_run, QUOTA_REQUEUE (quota-stop)     (ga-x3nmz)
#   site 3  Step 0a dispatching-TTL recovery                  ($D_ID)
#
# All three hold the marker at `dispatching` (claimed queued->dispatching, unchanged
# until a terminal status; only the gate-RUN bead carries `running`). The
# expected_status argument is the hazard the bead names: pass the wrong one and the
# helper reads this sweep's OWN label as "foreign", writes nothing and strands the
# marker. So this file checks BEHAVIOUR per site, not just that the call exists:
#
#   * external needs-rebase present at the closing write  -> survives (not erased)
#   * only our own `dispatching`                          -> still requeued (normal path)
#   * the messages that follow (marker comment, gate-run comment/close reason, push)
#     do not claim a requeue that did not happen
#   * the respected path (helper rc GATE_REQUEUE_RESPECTED_RC) does not abort the
#     block — every caller runs under `set -e` and must capture that rc
#   * a write that itself FAILS (rc other than 0/10) is a third fact: nothing was
#     requeued, and it is never narrated as "another actor moved it"
#   * the rc of one marker never leaks into the next iteration of the TTL loop
#   * a marker that cannot be read takes the legacy write, loudly (UNVERIFIED)
#   * no raw `set_gate_status ... "queued"` / `label add ... gate-status:queued`
#     may come back (detector + its own self-test); waive with `# requeue-raw-ok: why`
#
# Strategy (this repo's SELFTEST-EXTRACT convention): the two blocks are extracted
# from the LIVE dispatcher by sentinel and run in-process against a stateful marker
# stub — never a hand-copied duplicate of shipped logic. Only bd/notify/log/warn/
# set_gate_status are stubbed. Each case runs in a `set -e` subshell.
#
# Exit 0 iff every assertion holds. Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }   # has <haystack> <needle>

echo "== gate-dl3x9s-requeue-external.selftest =="
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
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ── 1. the class lock, and the detector behind it ──────────────────────────────
echo "── 1. no raw requeue writer of gate-status:queued in the dispatcher ──"
# raw_queued_writers < file : prints "<line>:<text>" for every non-comment line that
# writes queued without going through gate_requeue_respecting_external.
raw_queued_writers() {
  grep -nE 'set_gate_status[[:space:]]+"[^"]*"[[:space:]]+"queued"|label[[:space:]]+add[[:space:]]+[^#]*gate-status:queued' \
    | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'requeue-raw-ok'
}
# Detector self-test: a detector nobody tests is a detector that silently stops
# detecting. It must flag both raw forms and ignore comments, waivers and the helper.
DET_FIXTURE='    set_gate_status "$MARKER_ID" "queued"
  set_gate_status "$D_ID"   "queued"
bd -C "$GC_CITY" label add "$M" "gate-status:queued" -q
    # set_gate_status "$MARKER_ID" "queued"   (a comment)
set_gate_status "$X" "queued"  # requeue-raw-ok: guard Vector A is itself the external actor
gate_requeue_respecting_external "$MARKER_ID" "queued" "dispatching"
set_gate_status "$MARKER_ID" "needs-rebase"'
DET_OUT="$(printf '%s\n' "$DET_FIXTURE" | raw_queued_writers)"
DET_N="$(printf '%s\n' "$DET_OUT" | grep -c .)"
if [ "$DET_N" = "3" ] && has "$DET_OUT" '1:' && has "$DET_OUT" '2:' && has "$DET_OUT" '3:'; then
  ok "detector self-test: flags the 3 raw forms; ignores the comment, the waived line, the helper call and other statuses"
else
  bad "detector self-test: expected exactly fixture lines 1,2,3 flagged, got [$DET_OUT]"
fi
LIVE_RAW="$(raw_queued_writers < "$DISPATCHER" || true)"
if [ -z "$LIVE_RAW" ]; then
  ok "THE CLASS: the dispatcher has zero raw queued writers (was 3: reviewer-death, quota-stop, dispatching-TTL)"
else
  bad "raw queued writer(s) in the dispatcher — route through gate_requeue_respecting_external <id> queued dispatching, or waive with '# requeue-raw-ok: <why>': $LIVE_RAW"
fi

# ── 2. sites 1 & 2: gate_finalize_run's infra requeue block ───────────────────
echo "── 2. reviewer-death / quota-stop requeue: an external transition survives ──"
MARKER_ID="m-dl3x9s"; BEAD_ID="bead-dl3x9s"; BEAD_CITY="test-city"; GC_CITY="test-city"
GATE_RUN_ID="gr-dl3x9s"; BRANCH="fix/ga-fixture"
# `bd show` is called by the helper inside $(...), where a variable-based log is
# lost with the subshell — so reads of the marker are logged to a file.
SHOW_LOG="$(mktemp "${TMPDIR:-/tmp}/dl3x9s-show.XXXXXX")"
trap 'rm -f "$SHOW_LOG"' EXIT

# ── stateful stubs: one marker whose labels the helper reads AND writes ───────
new_case() { # <marker-labels> [status] [raw-show-output | __FAIL__]
  BD_LOG=""; WARN_LOG=""; STATUS_LOG=""; NOTIFY_LOG=""; COMMENT_LOG=""; CLOSE_LOG=""
  : > "$SHOW_LOG"
  MARK_LABELS="$1"; MARK_STATUS="${2:-open}"; SHOW_RAW="${3:-}"
  MARKER_SET_RC=0   # a case that wants the gate-status WRITE to fail sets this after new_case
}
marker_json() {
  local l first=1 labs=""
  for l in $MARK_LABELS; do
    [ "$first" = 1 ] || labs="$labs,"; first=0; labs="$labs\"$l\""
  done
  printf '[{"id":"%s","status":"%s","labels":[%s]}]' "$MARKER_ID" "$MARK_STATUS" "$labs"
}
strip_gate_status() {
  local out="" l
  for l in $MARK_LABELS; do case "$l" in gate-status:*) ;; *) out="$out $l" ;; esac; done
  MARK_LABELS="${out# }"
  return 0
}
final_gs() { # the marker's gate-status:* labels after the case, space-joined
  local out="" l
  for l in $MARK_LABELS; do case "$l" in gate-status:*) out="$out $l" ;; esac; done
  printf '%s' "${out# }"
}
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
      printf '[{"id":"%s","status":"open","labels":[]}]' "${4:-}"; return 0 ;;
    label)
      if [ "${5:-}" = "$MARKER_ID" ]; then
        case "${4:-}" in
          add) MARK_LABELS="$MARK_LABELS ${6:-}" ;;
          remove) local out="" l
                  for l in $MARK_LABELS; do [ "$l" = "${6:-}" ] || out="$out $l"; done
                  MARK_LABELS="${out# }" ;;
        esac
      fi
      return 0 ;;
    comment) COMMENT_LOG="$COMMENT_LOG|${4:-}: ${5:-}"; return 0 ;;
    close)   CLOSE_LOG="$CLOSE_LOG|${4:-}: ${6:-}"; return 0 ;;
  esac
  return 0
}
set_gate_status() {
  STATUS_LOG="$STATUS_LOG|$1:$2"
  if [ "$1" = "$MARKER_ID" ]; then
    # A failing write changes nothing (the real one adds the new label first, so a
    # failure before that leaves the marker as it was) — only the MARKER fails, so
    # the gate-run bead cleanup after it still runs.
    [ "$MARKER_SET_RC" = "0" ] || return "$MARKER_SET_RC"
    strip_gate_status; MARK_LABELS="$MARK_LABELS gate-status:$2"
  fi
  return 0
}
warn()   { WARN_LOG="$WARN_LOG|$*"; return 0; }
log()    { return 0; }
err()    { WARN_LOG="$WARN_LOG|ERR:$*"; return 0; }
notify() { NOTIFY_LOG="$NOTIFY_LOG|$*"; return 0; }
quota_reset_eta() { printf 'reset em 2h'; }
declare -F vb_status_action >/dev/null 2>&1 || vb_status_action() { printf 'requeue'; }
dump_state() {
  echo "GS=$(final_gs)"
  echo "STATUS=$STATUS_LOG"
  echo "COMMENTS=$COMMENT_LOG"
  echo "CLOSES=$CLOSE_LOG"
  echo "NOTIFY=$NOTIFY_LOG"
  echo "WARN=$WARN_LOG"
  echo "BD=$BD_LOG"
  echo "SHOWS=$(tr '\n' ' ' < "$SHOW_LOG")"
}
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }   # getl <KEY> from $OUT
cmt()  { getl COMMENTS | tr '|' '\n' | grep -F -- "$1: "; }         # cmt <bead-id> -> its comment line(s)

INFRA_SRC="$(extract_block "$DISPATCHER" infra-requeue-block)"
TTL_SRC="$(extract_block "$DISPATCHER" dispatching-ttl-recovery)"
[ -n "$INFRA_SRC" ] || { echo "FATAL: infra-requeue-block sentinel block not found (moved/renamed?)" >&2; exit 2; }
[ -n "$TTL_SRC" ]   || { echo "FATAL: dispatching-ttl-recovery sentinel block not found (moved/renamed?)" >&2; exit 2; }
eval "run_infra_block() {
$INFRA_SRC
}"
eval "run_ttl_block() {
$TTL_SRC
}"

# run_infra <REQUEUE_REASON>  (QUOTA_REQUEUE=1). Runs under `set -e` like the real
# dispatcher: if the block exits early, "RC=" never prints — that is the signal.
run_infra() {
  OUT=$( set -e; QUOTA_REQUEUE=1; REQUEUE_REASON="$1"; VERDICT_BEAD_IDS=("vb-dl3x9s")
         run_infra_block; echo "RC=$?"; dump_state ) 2>&1
}

for REASON in dead-reviewer quota; do
  if [ "$REASON" = "dead-reviewer" ]; then
    LBL="reviewer-death (ga-eqjo)"; RQ_PHRASE="re-queued for a fresh attempt"; MK_OK="INFRA re-queue (ga-eqjo): reviewer session(s) died"; MK_SKIP="INFRA re-queue (ga-eqjo) NOT applied"
  else
    LBL="quota-stop (ga-x3nmz)"; RQ_PHRASE="re-queued for re-run post-reset"; MK_OK="QUOTA-STOP re-queue (ga-x3nmz)"; MK_SKIP="QUOTA-STOP re-queue (ga-x3nmz) NOT applied"
  fi

  # normal path — only our own dispatching label
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_infra "$REASON"
  if [ "$(getl GS)" = "gate-status:queued" ] && has "$OUT" "RC=0" && ! has "$OUT" "unbound variable"; then
    ok "$LBL: normal case (only our own dispatching) → marker ends exactly at gate-status:queued, block returns 0 under set -e"
  else
    bad "$LBL: normal case must requeue: GS='$(getl GS)' out=[$OUT]"
  fi
  if has "$(getl COMMENTS)" "$MK_OK" && has "$(getl COMMENTS)" "Marker re-queued" \
     && has "$(getl COMMENTS)" "marker $MARKER_ID $RQ_PHRASE" && has "$(getl CLOSES)" "marker $MARKER_ID $RQ_PHRASE" \
     && has "$(getl NOTIFY)" "re-enfileirado"; then
    ok "$LBL: normal case keeps the original wording — marker comment, gate-run comment, close reason and push all say re-queued"
  else
    bad "$LBL: normal-path messages changed: comments=[$(getl COMMENTS)] closes=[$(getl CLOSES)] notify=[$(getl NOTIFY)]"
  fi
  has "$(getl BD)" "label remove $BEAD_ID gate:reviewing" \
    && ok "$LBL: normal case still clears gate:reviewing on the source bead (ga-n2cpe)" \
    || bad "$LBL: gate:reviewing no longer cleared: bd=[$(getl BD)]"
  has "$(getl COMMENTS)" "|vb-dl3x9s: VERDICT: REQUEUED" && has "$(getl COMMENTS)" "unless another actor moved it first" \
    && ok "$LBL: the verdict-bead comment (written BEFORE the requeue outcome is known) states no marker fate — true on both paths" \
    || bad "$LBL: verdict-bead comment missing or still asserts the marker was re-queued: [$(getl COMMENTS)]"

  # THE INCIDENT SHAPE — the Mayor's needs-rebase is present when the closing write runs
  new_case "type:quality-gate-marker gate-status:dispatching gate-status:needs-rebase"
  run_infra "$REASON"
  if [ "$(getl GS)" = "gate-status:needs-rebase" ] && ! has "$(getl STATUS)" "$MARKER_ID:queued" && has "$OUT" "RC=0"; then
    ok "$LBL: THE 25/09 REVERT — needs-rebase present at the closing write survives; only our dispatching label is dropped; block still returns 0 under set -e (fails on the raw write: it overwrites with queued)"
  else
    bad "$LBL: external needs-rebase must survive: GS='$(getl GS)' STATUS='$(getl STATUS)' out=[$OUT]"
  fi
  if has "$(getl WARN)" "respecting it"; then
    ok "$LBL: the skipped write is logged (a decision nobody can see is one nobody can audit)"
  else
    bad "$LBL: no 'respecting it' log line when the external transition won: warn=[$(getl WARN)]"
  fi
  # Per-target views: the verdict-bead comment is written BEFORE the outcome is
  # known and is neutral by design (asserted above), so it is judged on its own.
  MKC="$(cmt "$MARKER_ID")"; GRC="$(cmt "$GATE_RUN_ID")"; CLS="$(getl CLOSES)"
  if has "$MKC" "$MK_SKIP" && ! has "$MKC" "Marker re-queued" && has "$MKC" "was left where they put it" \
     && has "$GRC" "marker $MARKER_ID NOT re-queued" && has "$CLS" "marker $MARKER_ID NOT re-queued" \
     && ! has "$MKC$GRC$CLS" "$RQ_PHRASE"; then
    ok "$LBL: no message claims a requeue that did not happen (marker comment, gate-run comment and close reason all say NOT re-queued)"
  else
    bad "$LBL: messages still claim a requeue: marker=[$MKC] run=[$GRC] closes=[$CLS]"
  fi
  if [ -z "$(getl NOTIFY)" ]; then
    ok "$LBL: no 'Gate re-enfileirado' push when the marker was not re-queued"
  else
    bad "$LBL: pushed a re-enfileirado notice for a marker that was not re-queued: [$(getl NOTIFY)]"
  fi
  if has "$(getl CLOSES)" "$GATE_RUN_ID: " && has "$(getl STATUS)" "$GATE_RUN_ID:superseded" && has "$(getl BD)" "label remove $BEAD_ID gate:reviewing"; then
    ok "$LBL: the rest of the cleanup still runs when the transition is respected (gate-run superseded+closed, gate:reviewing cleared)"
  else
    bad "$LBL: respecting the external transition skipped the run/label cleanup: status=[$(getl STATUS)] closes=[$(getl CLOSES)]"
  fi

  # every other gate-status an external actor can leave is respected too (class, not the one instance)
  for ext in error passed failed superseded deferred; do
    new_case "type:quality-gate-marker gate-status:dispatching gate-status:$ext"
    run_infra "$REASON"
    [ "$(getl GS)" = "gate-status:$ext" ] \
      && ok "$LBL: external gate-status:$ext is respected (class fix)" \
      || bad "$LBL: external gate-status:$ext was overwritten: GS='$(getl GS)'"
  done

  new_case "type:quality-gate-marker gate-status:dispatching" closed
  run_infra "$REASON"
  [ -z "$(getl GS)" ] || [ "$(getl GS)" = "gate-status:dispatching" ] && ! has "$(getl STATUS)" "$MARKER_ID:queued" \
    && ok "$LBL: a marker closed mid-sweep is not resurrected with a queued label" \
    || bad "$LBL: closed marker got a queued write: GS='$(getl GS)' STATUS='$(getl STATUS)'"

  # the guard's Vector A requeued it mid-sweep: dispatching+queued is NOT foreign
  new_case "type:quality-gate-marker gate-status:dispatching gate-status:queued"
  run_infra "$REASON"
  [ "$(getl GS)" = "gate-status:queued" ] \
    && ok "$LBL: dispatching+queued (already requeued by the guard mid-sweep) converges to queued, not stranded" \
    || bad "$LBL: dispatching+queued must converge to queued: GS='$(getl GS)'"

  # unreadable marker: third state, never a synonym for "nothing external happened"
  for variant in __FAIL__ "this is not json" '{"error":"database is locked"}'; do
    new_case "type:quality-gate-marker gate-status:dispatching" open "$variant"
    run_infra "$REASON"
    if [ "$(getl GS)" = "gate-status:queued" ] && has "$(getl WARN)" "UNVERIFIED" && has "$(getl COMMENTS)" "Marker re-queued"; then
      ok "$LBL: unreadable marker [$variant] → legacy write (never stranded at dispatching) AND a visible UNVERIFIED warning"
    else
      bad "$LBL: unreadable marker [$variant] must requeue with a warning: GS='$(getl GS)' warn=[$(getl WARN)]"
    fi
  done

  # the gate-status WRITE itself fails (rc 1): the third fact, neither "requeued"
  # nor "an external transition was respected" — and never folded into either.
  new_case "type:quality-gate-marker gate-status:dispatching"
  MARKER_SET_RC=1
  run_infra "$REASON"
  MKC="$(cmt "$MARKER_ID")"; GRC="$(cmt "$GATE_RUN_ID")"; CLS="$(getl CLOSES)"
  if has "$OUT" "RC=0" && ! has "$OUT" "unbound variable" && [ "$(getl GS)" = "gate-status:dispatching" ]; then
    ok "$LBL: a FAILED marker write does not abort the block under set -e, and the marker's label is left exactly as it was"
  else
    bad "$LBL: failed marker write must not abort or relabel: GS='$(getl GS)' out=[$OUT]"
  fi
  if has "$MKC" "$MK_SKIP" && has "$MKC" "write itself failed (rc=1)" && ! has "$MKC" "Marker re-queued" \
     && ! has "$MKC" "another actor" && ! has "$MKC" "was left where they put it" \
     && has "$GRC" "marker $MARKER_ID NOT re-queued (the gate-status write failed, rc=1" \
     && has "$CLS" "marker $MARKER_ID NOT re-queued (the gate-status write failed, rc=1" \
     && ! has "$MKC$GRC$CLS" "$RQ_PHRASE" && ! has "$GRC" "reset em 2h"; then
    ok "$LBL: a failed write is narrated as a failed write — no message claims a requeue, none blames another actor, no quota ETA is promised"
  else
    bad "$LBL: failed-write messages wrong: marker=[$MKC] run=[$GRC] closes=[$CLS]"
  fi
  if [ -z "$(getl NOTIFY)" ] && has "$(getl CLOSES)" "$GATE_RUN_ID: " && has "$(getl STATUS)" "$GATE_RUN_ID:superseded" \
     && has "$(getl BD)" "label remove $BEAD_ID gate:reviewing"; then
    ok "$LBL: failed write → no 'Gate re-enfileirado' push, and the run/label cleanup still runs"
  else
    bad "$LBL: failed-write side effects wrong: notify=[$(getl NOTIFY)] status=[$(getl STATUS)] closes=[$(getl CLOSES)]"
  fi
done

# ── 3. site 3: the dispatching-TTL recovery ──────────────────────────────────
echo "── 3. dispatching-TTL recovery: an external transition survives ──"
# run_ttl <age-minutes> [live-run-json]. DISPATCHING_JSON models the (up to ~5s
# stale) cached list the real code reads: it always says `dispatching`; the LIVE
# marker store is whatever new_case set — that gap is the race being fixed.
run_ttl() {
  OUT=$( set -e; DISPATCHING_TTL_MINUTES=30; LIVE_RUN_MARKER_IDS_JSON="${2:-[]}"
         DISPATCHING_JSON="[{\"id\":\"$MARKER_ID\",\"updated_at\":\"$(iso $(( $(date +%s) - $1 * 60 )))\",\"labels\":[\"type:quality-gate-marker\",\"gate-status:dispatching\"]}]"
         DISPATCHING_COUNT=1
         run_ttl_block; echo "RC=$?"; dump_state ) 2>&1
}
if [ -z "$(iso 0)" ]; then
  bad "date cannot format an epoch (neither BSD -r nor GNU -d) — TTL cases cannot run"
else
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_ttl 45
  if [ "$(getl GS)" = "gate-status:queued" ] && has "$OUT" "RC=0" && has "$(getl COMMENTS)" "Re-queuing for re-processing" \
     && ! has "$OUT" "unbound variable" && has "$(getl SHOWS)" "show:$MARKER_ID"; then
    ok "TTL: a 45m zombie in dispatching (no live run) → requeued, original wording, and the marker was re-read LIVE before the write"
  else
    bad "TTL: normal zombie recovery broke: GS='$(getl GS)' out=[$OUT]"
  fi

  new_case "type:quality-gate-marker gate-status:dispatching gate-status:needs-rebase"
  run_ttl 45
  if [ "$(getl GS)" = "gate-status:needs-rebase" ] && ! has "$(getl STATUS)" "$MARKER_ID:queued" && has "$OUT" "RC=0"; then
    ok "TTL: the cached list said dispatching but the Mayor's needs-rebase landed since → it survives (fails on the raw write)"
  else
    bad "TTL: external needs-rebase was overwritten by the recovery: GS='$(getl GS)' STATUS='$(getl STATUS)' out=[$OUT]"
  fi
  if has "$(getl COMMENTS)" "NOT re-queued" && ! has "$(getl COMMENTS)" "Re-queuing for re-processing" && ! has "$(getl COMMENTS)" "Dispatcher process died mid-run"; then
    ok "TTL: when the transition is respected the comment does not claim a requeue or a dead dispatcher"
  else
    bad "TTL: comment still claims a requeue/dead dispatcher: [$(getl COMMENTS)]"
  fi
  has "$(getl WARN)" "respecting it" \
    && ok "TTL: the respected transition is logged" \
    || bad "TTL: no 'respecting it' log line: [$(getl WARN)]"

  # interrupted transition: the dispatcher's OWN earlier add landed, its remove did not
  new_case "type:quality-gate-marker gate-status:dispatching gate-status:deferred"
  run_ttl 45
  [ "$(getl GS)" = "gate-status:deferred" ] \
    && ok "TTL: dispatching+deferred (an interrupted transition) keeps the newer status — the recovery no longer undoes the dispatcher's own earlier decision" \
    || bad "TTL: dispatching+deferred should keep deferred: GS='$(getl GS)'"

  # the gate-status WRITE itself fails (rc 1): not a requeue, not "another actor"
  new_case "type:quality-gate-marker gate-status:dispatching"
  MARKER_SET_RC=1
  run_ttl 45
  TC="$(cmt "$MARKER_ID")"
  if has "$OUT" "RC=0" && ! has "$OUT" "unbound variable" && [ "$(getl GS)" = "gate-status:dispatching" ] \
     && has "$TC" "NOT re-queued" && has "$TC" "write itself failed (rc=1)" \
     && ! has "$TC" "Re-queuing for re-processing" && ! has "$TC" "Dispatcher process died mid-run" \
     && ! has "$TC" "another actor"; then
    ok "TTL: a FAILED write neither aborts the sweep nor is narrated as a requeue or as 'another actor moved it'"
  else
    bad "TTL: failed-write handling wrong: GS='$(getl GS)' comment=[$TC] out=[$OUT]"
  fi

  # The rc of one marker must never leak into the next iteration of this loop: the
  # helper's rc is captured with `|| _RQ_RC=$?`, which only ASSIGNS on failure, so a
  # loop that does not reset it per marker narrates marker 2 with marker 1's rc.
  run_ttl_two() { # two 45m zombies in the cached list: $MARKER_ID first, m-second after it
    OUT=$( set -e; DISPATCHING_TTL_MINUTES=30; LIVE_RUN_MARKER_IDS_JSON="[]"
           _t="$(iso $(( $(date +%s) - 45 * 60 )))"
           DISPATCHING_JSON="[{\"id\":\"$MARKER_ID\",\"updated_at\":\"$_t\",\"labels\":[\"type:quality-gate-marker\",\"gate-status:dispatching\"]},{\"id\":\"m-second\",\"updated_at\":\"$_t\",\"labels\":[\"type:quality-gate-marker\",\"gate-status:dispatching\"]}]"
           DISPATCHING_COUNT=2
           run_ttl_block; echo "RC=$?"; dump_state ) 2>&1
  }
  new_case "type:quality-gate-marker gate-status:dispatching gate-status:needs-rebase"
  run_ttl_two
  T1="$(cmt "$MARKER_ID")"; T2="$(cmt m-second)"
  if has "$OUT" "RC=0" && has "$T1" "NOT re-queued" && has "$T2" "Re-queuing for re-processing" \
     && ! has "$T2" "NOT re-queued" && has "$(getl STATUS)" "m-second:queued"; then
    ok "TTL loop: marker 1's respected transition does not leak into marker 2 — marker 2 is still requeued and narrated as requeued"
  else
    bad "TTL loop: per-marker state leaked between iterations: m1=[$T1] m2=[$T2] status=[$(getl STATUS)] out=[$OUT]"
  fi
  new_case "type:quality-gate-marker gate-status:dispatching"
  MARKER_SET_RC=1
  run_ttl_two
  T1="$(cmt "$MARKER_ID")"; T2="$(cmt m-second)"
  if has "$OUT" "RC=0" && has "$T1" "write itself failed" && has "$T2" "Re-queuing for re-processing" \
     && ! has "$T2" "NOT re-queued" && ! has "$T2" "write itself failed"; then
    ok "TTL loop: marker 1's FAILED write does not leak into marker 2 either"
  else
    bad "TTL loop: a failed write leaked into the next marker: m1=[$T1] m2=[$T2] out=[$OUT]"
  fi

  new_case "type:quality-gate-marker gate-status:dispatching" closed
  run_ttl 45
  ! has "$(getl STATUS)" "$MARKER_ID:queued" \
    && ok "TTL: a marker closed since the cached read is left closed" \
    || bad "TTL: closed marker got a queued write: [$(getl STATUS)]"

  for variant in __FAIL__ "this is not json"; do
    new_case "type:quality-gate-marker gate-status:dispatching" open "$variant"
    run_ttl 45
    if [ "$(getl GS)" = "gate-status:queued" ] && has "$(getl WARN)" "UNVERIFIED"; then
      ok "TTL: unreadable marker [$variant] → legacy requeue (a stranded zombie is the worse default) AND a visible UNVERIFIED warning"
    else
      bad "TTL: unreadable marker [$variant] must requeue with a warning: GS='$(getl GS)' warn=[$(getl WARN)]"
    fi
  done

  # the two reasons NOT to touch a marker at all must still hold
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_ttl 45 '[{"id":"gr-live","description":"type: run\nmarker_id: m-dl3x9s\nx"}]'
  if [ "$(getl GS)" = "gate-status:dispatching" ] && [ -z "$(getl STATUS)" ] && ! has "$(getl SHOWS)" "show:$MARKER_ID"; then
    ok "TTL: a marker with a LIVE gate-run (Phase B in progress, ga-eqjo) is not touched, not even read"
  else
    bad "TTL: live-run guard broken: GS='$(getl GS)' STATUS='$(getl STATUS)'"
  fi
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_ttl 10
  if [ "$(getl GS)" = "gate-status:dispatching" ] && [ -z "$(getl STATUS)" ] && ! has "$(getl SHOWS)" "show:$MARKER_ID"; then
    ok "TTL: a 10m marker (< 30m TTL) is not touched"
  else
    bad "TTL: young marker was touched: GS='$(getl GS)' STATUS='$(getl STATUS)'"
  fi
fi

# ── 3b. gate_requeue_narrate on its own: only the literal "0" is a requeue ───────
echo "── 3b. gate_requeue_narrate: an rc it cannot read is never narrated as a requeue ──"
narr() { # narr [rc...] -> "SKIPPED=<n> NOTE=<..> WHY=<..> RC=<returned>" under set -e, note preset
  ( set -e; _RQ_NOTE="re-queued for a fresh attempt"; gate_requeue_narrate "$@"; echo "SKIPPED=$_RQ_SKIPPED NOTE=$_RQ_NOTE WHY=$_RQ_WHY RC=0" ) 2>&1
}
N0="$(narr 0)"; N10="$(narr 10)"; N1="$(narr 1)"; N255="$(narr 255)"; NEMPTY="$(narr "")"; NNONE="$(narr)"
if has "$N0" "SKIPPED=0 NOTE=re-queued for a fresh attempt WHY= RC=0"; then
  ok "narrate 0: requeued — the caller's own note is kept, no reason clause"
else
  bad "narrate 0 wrong: [$N0]"
fi
if has "$N10" "SKIPPED=1" && has "$N10" "another actor" && ! has "$N10" "write failed"; then
  ok "narrate 10 (GATE_REQUEUE_RESPECTED_RC): NOT requeued, blamed on the external transition, not on a failed write"
else
  bad "narrate 10 wrong: [$N10]"
fi
for pair in "1|$N1" "255|$N255"; do
  rc="${pair%%|*}"; out="${pair#*|}"
  if has "$out" "SKIPPED=1" && has "$out" "write failed, rc=$rc" && has "$out" "write itself failed (rc=$rc)" && ! has "$out" "another actor"; then
    ok "narrate $rc: NOT requeued, named as a failed write, never as 'another actor moved it'"
  else
    bad "narrate $rc wrong: [$out]"
  fi
done
for pair in "empty|$NEMPTY" "missing|$NNONE"; do
  lbl="${pair%%|*}"; out="${pair#*|}"
  if has "$out" "SKIPPED=1" && has "$out" "rc=unknown" && has "$out" "RC=0" && ! has "$out" "SKIPPED=0" && ! has "$out" "another actor"; then
    ok "narrate with a $lbl rc: could-not-tell takes the inert side — NOT requeued, rc=unknown, returns 0 under set -e (fails on a '\${1:-0}' default, which reads it as success)"
  else
    bad "narrate with a $lbl rc must not read as a requeue: [$out]"
  fi
done

# ── 4. drift-guards on the literals the behaviour depends on ─────────────────
echo "── 4. source drift-guards ──"
# The hazard the bead names: a WRONG expected_status makes the helper read this
# sweep's own label as foreign and strand the marker. Every call must pass the
# label the marker really holds.
NONCOMMENT="$(grep -nE 'gate_requeue_respecting_external[[:space:]]+"[^"]*"[[:space:]]+"queued"' "$DISPATCHER" | grep -vE '^[0-9]+:[[:space:]]*#')"
N_SITES="$(printf '%s\n' "$NONCOMMENT" | grep -c .)"
WRONG_EXPECT="$(printf '%s\n' "$NONCOMMENT" | grep -v '"queued" "dispatching"' || true)"
if [ -z "$WRONG_EXPECT" ]; then
  ok "every gate_requeue_respecting_external <id> queued call passes expected_status=dispatching"
else
  bad "a requeue call passes a different expected_status — it would strand the marker: $WRONG_EXPECT"
fi
[ "$N_SITES" -ge 6 ] \
  && ok "at least 6 requeue sites go through the helper (3 rebase-retry + reviewer-death + quota-stop + TTL): found $N_SITES" \
  || bad "expected >= 6 helper requeue sites, found $N_SITES — a site lost its compare-before-write"
INFRA_CALLS="$(printf '%s\n' "$INFRA_SRC" | grep -cE 'gate_requeue_respecting_external "\$MARKER_ID" "queued" "dispatching"')"
TTL_CALLS="$(printf '%s\n' "$TTL_SRC" | grep -cE 'gate_requeue_respecting_external "\$D_ID" "queued" "dispatching"')"
[ "$INFRA_CALLS" = "2" ] && [ "$TTL_CALLS" = "1" ] \
  && ok "the extracted blocks hold exactly the intended calls (infra block: 2, TTL block: 1)" \
  || bad "unexpected call counts in the extracted blocks (infra=$INFRA_CALLS want 2, ttl=$TTL_CALLS want 1)"
# expected_status=dispatching is only true while the claim puts the MARKER at
# dispatching and nothing between claim and finalize re-labels it. If either
# changes, the literal above silently becomes the wrong one.
grep -qE 'label add "\$MARKER_ID" "gate-status:dispatching"' "$DISPATCHER" \
  && ok "the claim still labels the marker gate-status:dispatching (the state the requeue sites hold)" \
  || bad "the claim no longer adds gate-status:dispatching to the marker — every expected_status literal is now wrong"
if grep -nE 'label add[[:space:]]+"\$MARKER_ID"[[:space:]]+"gate-status:running"|set_gate_status "\$MARKER_ID" "running"' "$DISPATCHER" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  bad "the marker itself is now labelled gate-status:running somewhere — reviewer-death/quota-stop no longer hold dispatching"
else
  ok "the marker itself is never labelled gate-status:running (only the gate-run bead is)"
fi
grep -qE '^[[:space:]]+-l gate-status:dispatching \\$' "$DISPATCHER" \
  && ok "the TTL pass still selects only markers CARRYING gate-status:dispatching (so expected_status=dispatching holds by construction)" \
  || bad "the TTL pass no longer filters on -l gate-status:dispatching"

echo ""
echo "gate-dl3x9s-requeue-external.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
