#!/usr/bin/env bash
# gate-7vet0v-infra-requeue-cooldown.selftest.sh (ga-7vet0v, 2026-10-05)
#
# INCIDENT: under host load the gate-reviewer cannot start (its engine-appended
# pre_start is killed), the run waits out the 31m verdict timeout, is classed "died
# mid-review", and the dispatcher INFRA-re-queues the marker (ga-eqjo; the no-eval
# twin, ga-5w2gpw, shares the block). That marker is by then the OLDEST overdue one,
# so the overdue tier (priority-blind, oldest-first, ga-ddm76) hands it straight back
# to the next sweep: head-of-line blocking. The FAIL path already stamps
# gate:retry-cooldown-until before its requeue (ga-a6etc2) and the selection already
# drops a marker inside its cooldown from EVERY tier — the infra re-queue just never
# wrote the label. Live 05/10: ga-23d49e was claimed again after each of its 4
# infra/no-eval re-queues (once as the very next claim overall); the log alone does
# not prove the ordering, the HOL test (5. below) does.
#
# What this file pins, by running the SHIPPED blocks (never a copy):
#   1. the infra-requeue-block, for dead-reviewer AND no-eval, stamps the cooldown
#      BEFORE the marker is `queued` (never queued without it), and the words it
#      writes are the outcome of the write (stamped / write FAILED / disabled);
#   2. an external transition that wins (needs-rebase) or a failed requeue write
#      drops the stamp again — it must not ride along on a marker that is not queued;
#   3. a cooldown label that cannot be written is logged and the sweep continues
#      WITHOUT a cooldown (the behaviour of today), never aborts, never blocks;
#   4. the quota-stop path is left alone (the ga-cw4pm headroom gate holds it);
#   5. THE HOL TEST: two overdue markers, the oldest re-queued by the infra block,
#      the NEXT PICK of the real marker-select is the OTHER one — and once the
#      cooldown has expired (or was never written) the old one is eligible again:
#      the cooldown can delay a marker, never park it (the "3rd state").
#
# Strategy (this repo's SELFTEST-EXTRACT convention): infra-requeue-block and
# marker-select are extracted from the LIVE dispatcher by sentinel; the helper
# functions are the real ones (GATE_DISPATCHER_LIB_ONLY). Only bd/notify/log/warn/
# set_gate_status are stubbed, against a stateful marker. Each block runs in a
# `set -e` subshell like the real dispatcher.
#
# Written so it also runs against the UNFIXED dispatcher: every missing behaviour is a
# `bad` line, not a FATAL — that is how "fails on HEAD, passes with the fix" is shown.
#
# Exit 0 iff every assertion holds.  Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }   # has <haystack> <needle>

echo "== gate-7vet0v-infra-requeue-cooldown.selftest =="
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

MARKER_ID="m-7vet0v"; BEAD_ID="bead-7vet0v"; BEAD_CITY="test-city"; GC_CITY="test-city"
GATE_RUN_ID="gr-7vet0v"; BRANCH="fix/ga-fixture"
GATE_RETRY_COOLDOWN_SECONDS=900   # explicit: the test must not depend on the shipped default

# ── stateful stubs: one marker whose labels the helpers read AND write ────────
new_case() { # <marker-labels> [status]
  BD_LOG=""; WARN_LOG=""; STATUS_LOG=""; NOTIFY_LOG=""; COMMENT_LOG=""; CLOSE_LOG=""
  MARK_LABELS="$1"; MARK_STATUS="${2:-open}"
  MARKER_SET_RC=0     # a case that wants the gate-status WRITE to fail sets this
  CD_ADD_RC=0         # a case that wants the cooldown LABEL write to fail sets this
  CD_AT_REQUEUE=""    # did the marker already carry a cooldown when it was set to queued?
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
final_gs() {
  local out="" l
  for l in $MARK_LABELS; do case "$l" in gate-status:*) out="$out $l" ;; esac; done
  printf '%s' "${out# }"
}
cd_labels() { # the marker's gate:retry-cooldown-until:* labels, space-joined
  local out="" l
  for l in $MARK_LABELS; do case "$l" in gate:retry-cooldown-until:*) out="$out $l" ;; esac; done
  printf '%s' "${out# }"
}
bd() {
  BD_LOG="$BD_LOG|$*"
  case "${3:-}" in
    show)
      if [ "${4:-}" = "$MARKER_ID" ]; then marker_json; return 0; fi
      printf '[{"id":"%s","status":"open","labels":[]}]' "${4:-}"; return 0 ;;
    label)
      if [ "${5:-}" = "$MARKER_ID" ]; then
        case "${4:-}" in
          add)
            case "${6:-}" in gate:retry-cooldown-until:*) [ "$CD_ADD_RC" = "0" ] || return "$CD_ADD_RC" ;; esac
            MARK_LABELS="$MARK_LABELS ${6:-}" ;;
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
    [ "$MARKER_SET_RC" = "0" ] || return "$MARKER_SET_RC"
    if [ "$2" = "queued" ]; then
      if [ -n "$(cd_labels)" ]; then CD_AT_REQUEUE=yes; else CD_AT_REQUEUE=no; fi
    fi
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
  echo "CD=$(cd_labels)"
  echo "CDWAS=$CD_AT_REQUEUE"
  echo "LABELS=$MARK_LABELS"
  echo "STATUS=$STATUS_LOG"
  echo "COMMENTS=$COMMENT_LOG"
  echo "WARN=$WARN_LOG"
}
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }   # getl <KEY> from $OUT
cmt()  { getl COMMENTS | tr '|' '\n' | grep -F -- "$1: "; }         # cmt <bead-id> -> its comment line(s)

INFRA_SRC="$(extract_block "$DISPATCHER" infra-requeue-block)"
[ -n "$INFRA_SRC" ] || { echo "FATAL: infra-requeue-block sentinel block not found (moved/renamed?)" >&2; exit 2; }
eval "run_infra_block() {
$INFRA_SRC
}"

# run_infra <REQUEUE_REASON>  (QUOTA_REQUEUE=1). Runs under `set -e` like the real
# dispatcher: if the block exits early, "RC=" never prints — that is the signal.
run_infra() {
  OUT=$( set -e; QUOTA_REQUEUE=1; REQUEUE_REASON="$1"; VERDICT_BEAD_IDS=("vb-7vet0v")
         run_infra_block; echo "RC=$?"; dump_state ) 2>&1
}
now_s() { date +%s; }

# ── 1+2+3. the block, per reason ─────────────────────────────────────────────
for REASON in dead-reviewer no-eval; do
  if [ "$REASON" = "dead-reviewer" ]; then LBL="INFRA re-queue (ga-eqjo)"; else LBL="NO-EVAL re-queue (ga-5w2gpw)"; fi
  echo "── $LBL ──"

  # 1. normal path: stamped, and stamped BEFORE the marker is queued
  new_case "type:quality-gate-marker gate-status:dispatching"
  T0=$(now_s); run_infra "$REASON"; T1=$(now_s)
  CDL="$(getl CD)"; CDE="${CDL#gate:retry-cooldown-until:}"
  if [ "$(getl GS)" = "gate-status:queued" ] && has "$OUT" "RC=0"; then
    ok "$LBL: the marker is still re-queued (gate-status:queued), block returns 0 under set -e"
  else
    bad "$LBL: requeue broke: GS='$(getl GS)' out=[$OUT]"
  fi
  case "$CDE" in
    ''|*[!0-9]*) bad "$LBL: THE FIX — no gate:retry-cooldown-until:<epoch> label on the re-queued marker (got [$CDL]); it returns to the head of the overdue tier" ;;
    *) if [ "$CDE" -ge $((T0 + GATE_RETRY_COOLDOWN_SECONDS)) ] && [ "$CDE" -le $((T1 + GATE_RETRY_COOLDOWN_SECONDS)) ]; then
         ok "$LBL: THE FIX — the re-queued marker carries gate:retry-cooldown-until = now + ${GATE_RETRY_COOLDOWN_SECONDS}s"
       else
         bad "$LBL: cooldown epoch $CDE is not now+${GATE_RETRY_COOLDOWN_SECONDS}s (window $((T0 + GATE_RETRY_COOLDOWN_SECONDS))..$((T1 + GATE_RETRY_COOLDOWN_SECONDS)))"
       fi ;;
  esac
  [ "$(getl CDWAS)" = "yes" ] \
    && ok "$LBL: cooldown FIRST, requeue second — the marker is never queued without its cooldown (no sweep can pick it up in the gap)" \
    || bad "$LBL: the marker was set to queued WITHOUT its cooldown label already in place (CDWAS='$(getl CDWAS)')"
  MKC="$(cmt "$MARKER_ID")"
  if has "$MKC" "Marker re-queued" && has "$MKC" "${GATE_RETRY_COOLDOWN_SECONDS}s retry cooldown" && ! has "$MKC" "WITHOUT a retry cooldown" && ! has "$MKC" "NO retry cooldown"; then
    ok "$LBL: the marker comment says it sits behind the cooldown (the audit trail states what was written)"
  else
    bad "$LBL: marker comment does not state the cooldown it just stamped: [$MKC]"
  fi
  has "$(getl COMMENTS)" "|vb-7vet0v: VERDICT: REQUEUED" \
    && ok "$LBL: the rest of the block is untouched (verdict bead still parked REQUEUED)" \
    || bad "$LBL: verdict-bead handling changed: [$(getl COMMENTS)]"

  # 2a. an external transition wins: needs-rebase present at the closing write
  new_case "type:quality-gate-marker gate-status:dispatching gate-status:needs-rebase"
  run_infra "$REASON"
  if [ "$(getl GS)" = "gate-status:needs-rebase" ] && [ -z "$(getl CD)" ]; then
    ok "$LBL: the Mayor's needs-rebase survives AND no cooldown rides along on the parked marker (a manual requeue would otherwise be silently held out)"
  else
    bad "$LBL: external transition case: GS='$(getl GS)' CD='$(getl CD)' (want needs-rebase, no cooldown label)"
  fi
  MKC="$(cmt "$MARKER_ID")"
  if ! has "$MKC" "retry cooldown"; then
    ok "$LBL: no cooldown is claimed on a marker that was not re-queued"
  else
    bad "$LBL: the NOT-applied comment still talks about a cooldown: [$MKC]"
  fi

  # 2b. the gate-status write itself fails: nothing requeued, so no stamp left behind
  new_case "type:quality-gate-marker gate-status:dispatching"
  MARKER_SET_RC=1
  run_infra "$REASON"
  if has "$OUT" "RC=0" && [ "$(getl GS)" = "gate-status:dispatching" ] && [ -z "$(getl CD)" ]; then
    ok "$LBL: a FAILED requeue write leaves the marker as it was, aborts nothing under set -e, and drops the stamp it had just written"
  else
    bad "$LBL: failed-write case: GS='$(getl GS)' CD='$(getl CD)' out=[$OUT]"
  fi

  # 3a. the cooldown label write fails: logged, sweep continues WITHOUT a cooldown (as today)
  new_case "type:quality-gate-marker gate-status:dispatching"
  CD_ADD_RC=1
  run_infra "$REASON"
  MKC="$(cmt "$MARKER_ID")"
  if has "$OUT" "RC=0" && [ "$(getl GS)" = "gate-status:queued" ] && [ -z "$(getl CD)" ]; then
    ok "$LBL: a cooldown label that cannot be written does NOT block or abort the requeue — the marker is queued without one, exactly as before this fix"
  else
    bad "$LBL: cooldown-write-failure case: GS='$(getl GS)' CD='$(getl CD)' out=[$OUT]"
  fi
  if has "$(getl WARN)" "FAILED to write gate:retry-cooldown-until"; then
    ok "$LBL: the failed cooldown write is logged (nobody has to guess why the marker came straight back)"
  else
    bad "$LBL: failed cooldown write not logged: warn=[$(getl WARN)]"
  fi
  if has "$MKC" "WITHOUT a retry cooldown" && ! has "$MKC" "sits behind"; then
    ok "$LBL: and the audit trail says WITHOUT a cooldown — it never narrates one that was not written"
  else
    bad "$LBL: comment misstates a failed cooldown write: [$MKC]"
  fi

  # 3b. cooldown disabled (GATE_RETRY_COOLDOWN_SECONDS=0): requeue as before, worded as such
  new_case "type:quality-gate-marker gate-status:dispatching"
  GATE_RETRY_COOLDOWN_SECONDS=0
  run_infra "$REASON"
  GATE_RETRY_COOLDOWN_SECONDS=900
  MKC="$(cmt "$MARKER_ID")"
  if has "$OUT" "RC=0" && [ "$(getl GS)" = "gate-status:queued" ] && [ -z "$(getl CD)" ] && has "$MKC" "NO retry cooldown" && ! has "$MKC" "sits behind"; then
    ok "$LBL: GATE_RETRY_COOLDOWN_SECONDS=0 disables it — requeued with no label, and the comment says NO cooldown"
  else
    bad "$LBL: disabled-cooldown case: GS='$(getl GS)' CD='$(getl CD)' comment=[$MKC] out=[$OUT]"
  fi
done

# ── 4. the quota-stop path is deliberately NOT changed ───────────────────────
echo "── quota-stop (ga-x3nmz) is left alone ──"
new_case "type:quality-gate-marker gate-status:dispatching"
OUT=$( set -e; QUOTA_REQUEUE=1; REQUEUE_REASON=quota; VERDICT_BEAD_IDS=("vb-7vet0v")
       run_infra_block; echo "RC=$?"; dump_state ) 2>&1
if [ "$(getl GS)" = "gate-status:queued" ] && [ -z "$(getl CD)" ] && has "$OUT" "RC=0"; then
  ok "quota-stop: re-queued with NO cooldown stamp — the ga-cw4pm headroom gate already holds the whole queue until the window resets, and a cooldown would only delay the resume"
else
  bad "quota-stop path changed: GS='$(getl GS)' CD='$(getl CD)' out=[$OUT]"
fi

# ── 5. THE HOL TEST: the next pick is the OTHER marker ───────────────────────
echo "── THE HOL TEST: two overdue markers, the oldest re-queued by infra ──"
SELECT_BLOCK="$(extract_block "$DISPATCHER" marker-select)"
[ -n "$SELECT_BLOCK" ] || { echo "FATAL: marker-select sentinel block not found" >&2; exit 2; }
# select_marker <markers-json> <now-epoch> : the selected id (empty when nothing is eligible).
select_marker() {
  local cnt; cnt="$(printf '%s' "$1" | jq 'length')"
  MARKERS_JSON="$1" COUNT="$cnt" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$2" \
  GATE_MARKER_AGE_PROMOTE_SECONDS=1800 \
  GATE_MARKER_HARD_AGE_SECONDS=5400 \
  GATE_EXILE_OVERDUE_SECONDS=5400 \
  GATE_EXILE_RETRY_CEILING=3 \
  GATE_PRIORITY_AUTHORS="" \
  bash -c 'log() { echo "LOG:$*"; }; warn() { echo "WARN:$*"; }; '"$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}
# mk_json <id> <created-epoch> <labels-space-separated> — a marker as the selection reads it.
mk_json() {
  local id="$1" created="$2" l first=1 labs=""
  for l in $3; do [ "$first" = 1 ] || labs="$labs,"; first=0; labs="$labs\"$l\""; done
  printf '{"id":"%s","created_at":"%s","description":"branch: crew/wa-worker/%s","labels":[%s]}' \
    "$id" "$(iso "$created")" "$id" "$labs"
}

# Both markers are past the hard-age ceiling (overdue tier, oldest-first): OLD is 3h
# old, OTHER is 2h old. Before any re-queue the oldest wins — that is the HOL.
HNOW=$(now_s)
OLD_CREATED=$((HNOW - 10800)); OTHER_CREATED=$((HNOW - 7200))
OTHER_LABELS="gate-status:queued type:quality-gate-marker"
BASE="[$(mk_json OLD "$OLD_CREATED" "gate-status:queued type:quality-gate-marker"),$(mk_json OTHER "$OTHER_CREATED" "$OTHER_LABELS")]"
SEL="$(select_marker "$BASE" "$HNOW")"
[ "$SEL" = "OLD" ] \
  && ok "baseline: with no cooldown anywhere the OLDEST overdue marker wins the overdue tier — the head-of-line shape this bead fixes" \
  || bad "baseline: expected OLD (oldest overdue), got '$SEL' — the fixture is not the HOL shape"

# Re-queue OLD through the SHIPPED infra block, then read back the labels it left.
# A queued marker is never carrying a gate-status other than queued, so the fixture
# labels are exactly what the block produced.
for REASON in dead-reviewer no-eval; do
  new_case "type:quality-gate-marker gate-status:dispatching"
  run_infra "$REASON"
  RQ_LABELS="$(getl LABELS)"
  RN=$(now_s)
  AFTER="[$(mk_json OLD "$OLD_CREATED" "$RQ_LABELS"),$(mk_json OTHER "$OTHER_CREATED" "$OTHER_LABELS")]"
  SEL="$(select_marker "$AFTER" "$RN")"
  if [ "$SEL" = "OTHER" ]; then
    ok "THE HOL TEST ($REASON): the just-re-queued OLD marker no longer wins — the next pick is OTHER (fails on the unfixed dispatcher: OLD is picked again and again)"
  else
    bad "THE HOL TEST ($REASON): next pick after the infra re-queue is '$SEL' (want OTHER) — labels left on OLD: [$RQ_LABELS]"
  fi
  # the 3rd state: the cooldown delays, it never parks
  LATER=$((RN + GATE_RETRY_COOLDOWN_SECONDS + 1))
  SEL="$(select_marker "$AFTER" "$LATER")"
  [ "$SEL" = "OLD" ] \
    && ok "never forever ($REASON): once the cooldown has expired OLD is the oldest overdue marker again and is picked — it was delayed, not parked" \
    || bad "never forever ($REASON): OLD is still held out after the cooldown expired (pick='$SEL')"
  # only one marker in the queue, and it is cooling down: nothing to claim, said out loud, not a stuck state
  SOLO="[$(mk_json OLD "$OLD_CREATED" "$RQ_LABELS")]"
  SOLO_OUT="$(select_marker "$SOLO" "$RN")"
  if has "$SOLO_OUT" "inside their retry cooldown" && ! has "$SOLO_OUT" "WARN:"; then
    ok "single queued marker cooling down ($REASON): the sweep ends cleanly and says why (all queued markers are inside their retry cooldown), no 'cause UNKNOWN' warning"
  else
    bad "single cooling-down marker ($REASON) was not handled as the known cooldown case: [$SOLO_OUT]"
  fi
done

# A cooldown label that could not be written leaves today's behaviour: OLD comes straight back.
new_case "type:quality-gate-marker gate-status:dispatching"
CD_ADD_RC=1
run_infra dead-reviewer
AFTER="[$(mk_json OLD "$OLD_CREATED" "$(getl LABELS)"),$(mk_json OTHER "$OTHER_CREATED" "$OTHER_LABELS")]"
SEL="$(select_marker "$AFTER" "$(now_s)")"
[ "$SEL" = "OLD" ] \
  && ok "documented limit: when the cooldown label write failed the selection is exactly today's (OLD again) — the failure is logged, the marker is never blocked" \
  || bad "unexpected pick '$SEL' after a failed cooldown write"

echo ""
echo "gate-7vet0v-infra-requeue-cooldown.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
