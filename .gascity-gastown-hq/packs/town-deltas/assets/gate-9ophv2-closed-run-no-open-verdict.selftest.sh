#!/usr/bin/env bash
# gate-9ophv2-closed-run-no-open-verdict.selftest.sh (ga-9ophv2, 2026-10-05)
#
# INCIDENT. 05/10: four type:quality-gate-verdict beads (ga-bo6wbh, ga-qec4tx, ga-uoyfu6,
# ga-qgk8gq) stayed in_progress with verdict:REQUEUED after their gate-run was CLOSED
# (up to 3h50) and paged the Mayor "Agente travado". Others (ga-p3lle9, ga-txiwnn) closed fine.
#
# ROOT CAUSE (measured, not inferred): the failing ones had a reviewer ASSIGNED
# (gate-reviewer-adhoc-*, durable pull ga-67hae); the healthy ones had no assignee. `bd close`
# REFUSES to close an in_progress bead whose assignee is not the caller —
#     cannot close <id>: assignee is "<reviewer>", actor is "<caller>"; reclaim or use --force
# (rc=1, nothing changes; reproduced on the real bd with a throwaway bead). Every dispatcher
# and guard close of a parked verdict was `bd close ... 2>/dev/null || true`, so the refusal was
# invisible; the ga-hwjrlq reaper then hit the same refusal every sweep and logged only "FAILED".
#
# WHY NO TEST CAUGHT IT: the existing selftests stub `bd close` as "always succeeds" — more
# permissive than the real thing. This one models the refusal. The stub is deliberately
# reality-faithful in the ONE respect that matters: an assigned, in_progress bead cannot be
# closed by a different actor without --force.
#
# Strategy (this repo's SELFTEST-EXTRACT convention): the real helper functions come from the
# dispatcher's own lib-only source (which also proves the guard lib is wired into it), and the
# three call sites are the LIVE blocks extracted by sentinel — never hand-copied logic:
#   * dispatcher infra-requeue-block    (dead-reviewer / no-eval / quota-stop parking + run close)
#   * dispatcher phase-c-timeout-close-fn (TIMEOUT parking)
#   * guard parked-verdict-reap         (the ga-hwjrlq reaper that failed silently for hours)
# Only bd/log/warn/notify/set_gate_status/gate_requeue_* are stubbed.
#
# Run it against the pre-fix commit and it must FAIL (it does: close_gate_verdict does not exist
# there and every scenario below ends with the parecer still in_progress).
# Exit 0 iff every assertion holds. Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }   # has <haystack> <needle>

echo "== gate-9ophv2-closed-run-no-open-verdict.selftest =="
[ -f "$DISPATCHER" ] && [ -f "$GUARD" ] || { echo "FATAL: dispatcher/guard not found in $SELF_DIR" >&2; exit 2; }

# /bin/bash -n, never bare `bash -n` (Homebrew bash 5.3 accepts what 3.2 rejects).
if /bin/bash -n "$DISPATCHER" 2>/dev/null && /bin/bash -n "$GUARD" 2>/dev/null; then
  ok "dispatcher and guard parse under /bin/bash (3.2) — the interpreter launchd actually runs"
else
  bad "dispatcher or guard does NOT parse under /bin/bash 3.2"
fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}
# vb_status_action is NOT defined by the dispatcher's lib-only source (it sits below the lib-only return),
# so take the REAL one by sentinel — a stub here would hide whether the parking branches run at all.
eval "$(extract_block "$DISPATCHER" vb-status-action-fn)"
declare -F vb_status_action >/dev/null 2>&1 || { echo "FATAL: vb-status-action-fn sentinel block not found" >&2; exit 2; }

# ── 0. wiring: the dispatcher must actually have the helpers at runtime ────────
echo "── 0. the helpers exist where the dispatcher runs them (merged != live) ──"
for FN in close_gate_verdict close_open_run_verdicts; do
  if declare -F "$FN" >/dev/null 2>&1; then
    ok "$FN is defined after the dispatcher's lib-only source (guard lib wired in)"
  else
    bad "$FN is NOT defined after sourcing the dispatcher — every call site would be 'command not found' hidden by '|| true'"
  fi
done

# ── reality-faithful bd stub ───────────────────────────────────────────────────
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-9ophv2.XXXXXX")"
trap '[ -n "${ROOT:-}" ] && rm -rf "$ROOT"' EXIT
ACTOR="gate-dispatcher"          # who bd sees as the caller (never equal to a reviewer session)
NOW=1791143706                   # fixed instant, 2026-10-04T19:55:06Z
ts_ago() { date -u -r $(( NOW - $1 * 60 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( NOW - $1 * 60 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
WORLD_N=0
new_world() {   # fresh state dir + failure-injection switches cleared
  WORLD_N=$((WORLD_N+1)); T="$ROOT/w$WORLD_N"; mkdir -p "$T"
  : > "$T/calls.log"; : > "$T/warn.log"
  LIST_FAIL=""; LIST_GARBAGE=""; FORCE_REFUSED=""; CLOSE_LIES=""; SHOW_FAIL=""
}
mk() {          # mk <id> <status> <assignee> <age-min> <label>...
  local id="$1" st="$2" as="$3" age="$4"; shift 4
  printf '%s' "$st" > "$T/$id.status"; printf '%s' "$as" > "$T/$id.assignee"
  printf '%s' "$(ts_ago "$age")" > "$T/$id.updated"
  printf '%s\n' "$@" > "$T/$id.labels"; : > "$T/$id.reason"
}
st() { cat "$T/$1.status" 2>/dev/null; }
labels_of() { tr '\n' ' ' < "$T/$1.labels" 2>/dev/null; }
bead_json() {
  local id="$1" labs
  labs=$(awk 'NF{printf "%s\"%s\"", (n++?",":""), $0}' "$T/$id.labels")
  printf '{"id":"%s","status":"%s","assignee":"%s","updated_at":"%s","labels":[%s]}' \
    "$id" "$(cat "$T/$id.status")" "$(cat "$T/$id.assignee")" "$(cat "$T/$id.updated")" "$labs"
}
bd_list() {
  local req_all="" req_any="" f id l ok oka out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -l) req_all="$req_all $2"; shift 2 ;;
      --label-any) req_any="$2"; shift 2 ;;
      --limit) shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$LIST_FAIL" ] && { echo "dolt: query timeout" >&2; return 1; }
  [ -n "$LIST_GARBAGE" ] && { echo '{"error":"not a list"}'; return 0; }
  for f in "$T"/*.status; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .status)"
    [ "$(cat "$f")" = closed ] && continue          # bd list hides closed by default
    ok=1
    for l in $req_all; do grep -qxF "$l" "$T/$id.labels" || ok=0; done
    if [ -n "$req_any" ]; then
      oka=0
      for l in $(printf '%s' "$req_any" | tr ',' ' '); do grep -qxF "$l" "$T/$id.labels" && oka=1; done
      [ "$oka" = 1 ] || ok=0
    fi
    [ "$ok" = 1 ] && out="$out${out:+,}$(bead_json "$id")"
  done
  printf '[%s]' "$out"
}
bd_close() {
  local id="" force=0 reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -r) reason="$2"; shift 2 ;;
      -q) shift ;;
      *) [ -z "$id" ] && id="$1"; shift ;;
    esac
  done
  echo "close $id force=$force" >> "$T/calls.log"
  [ -f "$T/$id.status" ] || { echo "no issue $id" >&2; return 1; }
  [ "$(st "$id")" = closed ] && return 0
  local as; as="$(cat "$T/$id.assignee")"
  # THE REAL REFUSAL (reproduced on the real bd, 2026-10-05):
  if [ -n "$as" ] && [ "$as" != "$ACTOR" ] && [ "$force" = 0 ]; then
    echo "cannot close $id: assignee is \"$as\", actor is \"$ACTOR\"; reclaim or use --force to override" >&2
    return 1
  fi
  [ "$FORCE_REFUSED" = "$id" ] && { echo "boom: close refused for $id even with --force" >&2; return 1; }
  [ "$CLOSE_LIES" = "$id" ] && return 0                    # rc=0, nothing persisted
  printf closed > "$T/$id.status"; printf '%s' "$reason" > "$T/$id.reason"
  echo "✓ Closed $id"
}
bd() {
  [ "${1:-}" = "-C" ] && shift 2
  local verb="${1:-}"; shift
  case "$verb" in
    show)
      [ -f "$T/${1:-}.status" ] || return 1
      [ "$SHOW_FAIL" = "${1:-}" ] && { echo "dolt hiccup" >&2; return 1; }
      printf '[%s]' "$(bead_json "$1")" ;;
    list)  bd_list "$@"; return $? ;;    # propagate bd's rc: a swallowed rc is exactly the bug under test
    close) bd_close "$@"; return $? ;;
    label)
      local op="$1" id="$2" lbl="$3"
      [ -f "$T/$id.labels" ] || return 0
      case "$op" in
        add)    grep -qxF "$lbl" "$T/$id.labels" || printf '%s\n' "$lbl" >> "$T/$id.labels" ;;
        remove) grep -vxF "$lbl" "$T/$id.labels" > "$T/$id.labels.n"; mv "$T/$id.labels.n" "$T/$id.labels" ;;
      esac ;;
    comment) printf '%s\n' "${2:-}" >> "$T/${1:-}.comments" ;;
  esac
  return 0
}
# non-bd stubs (after sourcing, so they override the real ones; state in files — blocks run in subshells)
log()    { return 0; }
warn()   { echo "$*" >> "$T/warn.log"; return 0; }
notify() { return 0; }
quota_reset_eta() { printf 'reset em 2h'; }
set_gate_status() { # replace the gate-status:* label on a bead
  [ -f "$T/${1}.labels" ] || return 0
  grep -v '^gate-status:' "$T/$1.labels" > "$T/$1.labels.n"; mv "$T/$1.labels.n" "$T/$1.labels"
  printf 'gate-status:%s\n' "$2" >> "$T/$1.labels"
}
gate_requeue_respecting_external() { return 0; }
gate_requeue_narrate() { _RQ_SKIPPED=0; _RQ_WHY=""; }
warns() { cat "$T/warn.log"; }

VB_LBL_PENDING="type:quality-gate-verdict"
# mk_incident <run> <vb> : the exact 05/10 shape — assigned reviewer, in_progress, still verdict:pending
mk_incident() {
  mk "$1" in_progress "" 30 "type:quality-gate-run" "gate-status:running"
  mk "$2" in_progress "gate-reviewer-adhoc-7a8e470a15" 30 "$VB_LBL_PENDING" "gate-run:$1" "reviewer-index:1" "verdict:pending"
}

# ── 1. the premise: the model matches the real bd ──────────────────────────────
echo "── 1. premise: a plain close of an assigned in_progress bead is refused (as the real bd does) ──"
new_world; mk_incident gr1 vb1
ERR="$(bd -C x close vb1 2>&1 >/dev/null)"; RC=$?
if [ "$RC" != 0 ] && has "$ERR" "cannot close vb1" && [ "$(st vb1)" = in_progress ]; then
  ok "stub refuses the plain close exactly like bd: rc=$RC, '$ERR', bead unchanged"
else
  bad "stub does not model the refusal (rc=$RC err='$ERR' status=$(st vb1)) — every test below would be vacuous"
fi

# ── 2. close_gate_verdict ──────────────────────────────────────────────────────
echo "── 2. close_gate_verdict ──"
new_world; mk_incident gr1 vb1
close_gate_verdict vb1 "because reasons"; RC=$?
if [ "$RC" = 0 ] && [ "$(st vb1)" = closed ] && has "$(cat "$T/vb1.reason")" "because reasons" && has "$(cat "$T/calls.log")" "close vb1 force=1"; then
  ok "an assigned in_progress parecer IS closed (forced), with the given reason — the 05/10 shape"
else
  bad "assigned parecer not closed: rc=$RC status=$(st vb1) reason=[$(cat "$T/vb1.reason")] calls=[$(cat "$T/calls.log")]"
fi

new_world; mk_incident gr1 vb1; FORCE_REFUSED=vb1
close_gate_verdict vb1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vb1)" = in_progress ] && has "$(warns)" "vb1" && has "$(warns)" "FAILED" && has "$(warns)" "boom: close refused"; then
  ok "a close bd really refuses returns 1 and the WARN carries bd's OWN error text (no more silent '|| true')"
else
  bad "refused close not surfaced: rc=$RC warn=[$(warns)]"
fi

new_world; mk_incident gr1 vb1; CLOSE_LIES=vb1
close_gate_verdict vb1 "x"; RC=$?
if [ "$RC" = 1 ] && has "$(warns)" "returned success but the bead reads status='in_progress'"; then
  ok "rc=0 without the bead actually closing is caught by reading it back (effect verified, not the return code)"
else
  bad "a close that did not persist was reported as done: rc=$RC warn=[$(warns)]"
fi

new_world; mk_incident gr1 vb1; SHOW_FAIL=vb1
close_gate_verdict vb1 "x"; RC=$?
if [ "$RC" = 0 ] && [ "$(st vb1)" = closed ] && [ -z "$(warns)" ]; then
  ok "close succeeded but the read-back is unreadable → success, no false alarm (unreadable is not 'still open')"
else
  bad "unreadable read-back mis-handled: rc=$RC warn=[$(warns)]"
fi

# ── 3. close_open_run_verdicts ─────────────────────────────────────────────────
echo "── 3. close_open_run_verdicts: a closed run leaves no open parecer behind ──"
new_world; mk_incident gr1 vbA
mk vbB open ""  30 "$VB_LBL_PENDING" "gate-run:gr1" "reviewer-index:2" "verdict:REQUEUED"     # unassigned, other label
mk vbC closed "gate-reviewer-adhoc-z" 30 "$VB_LBL_PENDING" "gate-run:gr1" "verdict:PASS"     # already closed
mk vbD in_progress "gate-reviewer-adhoc-y" 30 "$VB_LBL_PENDING" "gate-run:gr2" "verdict:pending"  # ANOTHER run
printf 'ORIGINAL' > "$T/vbC.reason"
close_open_run_verdicts gr1 "infra re-queue"; RC=$?
if [ "$RC" = 0 ] && [ "$(st vbA)" = closed ] && [ "$(st vbB)" = closed ]; then
  ok "both open pareceres of gr1 closed (the assigned in_progress one AND the unassigned open one)"
else
  bad "gr1's open pareceres not all closed: A=$(st vbA) B=$(st vbB) rc=$RC warn=[$(warns)]"
fi
if [ "$(st vbD)" = in_progress ]; then ok "a parecer of a DIFFERENT run (gr2) is untouched"; else bad "scoping broke: vbD=$(st vbD)"; fi
if [ "$(cat "$T/vbC.reason")" = ORIGINAL ] && ! has "$(cat "$T/calls.log")" "close vbC"; then
  ok "an already-closed parecer is not re-closed (its original close reason survives)"
else
  bad "closed parecer was touched: reason=[$(cat "$T/vbC.reason")] calls=[$(cat "$T/calls.log")]"
fi
if has "$(cat "$T/vbA.reason")" "gate-run gr1 closed (infra re-queue)" && has "$(cat "$T/vbA.reason")" "ga-9ophv2"; then
  ok "the close reason names the run, the path and the bead (auditable)"
else
  bad "close reason not auditable: [$(cat "$T/vbA.reason")]"
fi

new_world; mk_incident gr1 vbA; LIST_FAIL=1
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && has "$(warns)" "could not list" && has "$(warns)" "gr1"; then
  ok "a failed LIST is not 'none': returns 1, closes nothing, WARN names the run (error != empty)"
else
  bad "unreadable list collapsed into empty: rc=$RC A=$(st vbA) warn=[$(warns)]"
fi

new_world; mk_incident gr1 vbA; LIST_GARBAGE=1
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && has "$(warns)" "not a JSON array"; then
  ok "a non-array answer (error envelope) is not 'none' either"
else
  bad "garbage list mis-handled: rc=$RC warn=[$(warns)]"
fi

new_world; mk_incident gr1 vbA; mk vbB in_progress "gate-reviewer-adhoc-q" 30 "$VB_LBL_PENDING" "gate-run:gr1" "verdict:pending"; FORCE_REFUSED=vbA
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && [ "$(st vbB)" = closed ]; then
  ok "one parecer that cannot be closed does not stop the others (vbB closed), and the call reports failure (rc=1)"
else
  bad "partial failure mis-handled: rc=$RC A=$(st vbA) B=$(st vbB)"
fi
new_world
close_open_run_verdicts unknown "x"; RC1=$?; close_open_run_verdicts "" "x"; RC2=$?
if [ "$RC1" = 0 ] && [ "$RC2" = 0 ] && [ ! -s "$T/calls.log" ]; then
  ok "run id 'unknown'/empty (the dispatcher's own sentinel) is a no-op that touches nothing"
else
  bad "unknown/empty run id queried bd: rc=$RC1/$RC2 calls=[$(cat "$T/calls.log")]"
fi

# ── 4. THE INCIDENT through the live dispatcher blocks ─────────────────────────
echo "── 4. gate_finalize_run's infra-requeue block: run closed ⇒ parecer closed ──"
INFRA_SRC="$(extract_block "$DISPATCHER" infra-requeue-block)"
TIMEOUT_SRC="$(extract_block "$DISPATCHER" phase-c-timeout-close-fn)"
[ -n "$INFRA_SRC" ]   || { echo "FATAL: infra-requeue-block sentinel not found" >&2; exit 2; }
[ -n "$TIMEOUT_SRC" ] || { echo "FATAL: phase-c-timeout-close-fn sentinel not found" >&2; exit 2; }
eval "run_infra_block() {
$INFRA_SRC
}"
eval "run_timeout_block() {
$TIMEOUT_SRC
}"
MARKER_ID="m-9ophv2"; BEAD_ID="bead-9ophv2"; BEAD_CITY="test-city"; GC_CITY="test-city"
BRANCH="fix/ga-fixture"; PC_TIMEOUT_MIN=30

run_infra() {   # run_infra <REQUEUE_REASON> — under `set -e` like the dispatcher; RC= printed only if the block returns
  OUT=$( set -e; QUOTA_REQUEUE=1; REQUEUE_REASON="$1"; GATE_RUN_ID="gr1"; VERDICT_BEAD_IDS=("vb1")
         run_infra_block; echo "RC=$?" ) 2>&1
}
for REASON in dead-reviewer no-eval quota; do
  new_world; mk_incident gr1 vb1
  run_infra "$REASON"
  if [ "$(st vb1)" = closed ] && [ "$(st gr1)" = closed ] && has "$OUT" "RC=0"; then
    ok "$REASON: parecer (assigned reviewer, in_progress) AND its gate-run are both closed after the requeue — the 05/10 failure is gone"
  else
    bad "$REASON: vb1=$(st vb1) gr1=$(st gr1) out=[$OUT] warn=[$(warns)] — the parecer outlived its run"
  fi
  if has "$(labels_of vb1)" "verdict:REQUEUED" && ! has "$(labels_of vb1)" "verdict:pending"; then
    ok "$REASON: the parecer is labeled verdict:REQUEUED (and no longer verdict:pending)"
  else
    bad "$REASON: wrong verdict labels: $(labels_of vb1)"
  fi

  # the SKIP path: the parecer's status is unreadable during the loop (`continue`, "retry next sweep") —
  # but the run is closed in this same call, so there IS no next sweep. The net must catch it.
  new_world; mk_incident gr1 vb1; SHOW_FAIL=vb1
  run_infra "$REASON"
  if [ "$(st vb1)" = closed ] && [ "$(st gr1)" = closed ]; then
    ok "$REASON: status unreadable in the loop (skipped) → the run-close net still closes the parecer (no 'next sweep' exists for a closed run)"
  else
    bad "$REASON: skipped parecer left open under a closed run: vb1=$(st vb1) gr1=$(st gr1) warn=[$(warns)]"
  fi
done

echo "── 5. Phase C TIMEOUT parking (same refused close) ──"
new_world; mk_incident gr1 vb1
OUT=$( set -e; VERDICT_BEAD_IDS=("vb1"); run_timeout_block; echo "RC=$?" ) 2>&1
if [ "$(st vb1)" = closed ] && has "$(labels_of vb1)" "verdict:TIMEOUT" && has "$OUT" "RC=0"; then
  ok "TIMEOUT park: the assigned in_progress parecer is labeled verdict:TIMEOUT AND closed"
else
  bad "TIMEOUT park left the parecer open: vb1=$(st vb1) labels=[$(labels_of vb1)] out=[$OUT] warn=[$(warns)]"
fi

# ── 6. the ga-hwjrlq reaper (the thing that failed silently for hours) ─────────
echo "── 6. guard Step 0b.3 reaper against a reviewer-assigned REQUEUED parecer ──"
REAP_SRC="$(extract_block "$GUARD" parked-verdict-reap)"
[ -n "$REAP_SRC" ] || { echo "FATAL: parked-verdict-reap sentinel not found" >&2; exit 2; }
eval "run_reaper_block() {
$REAP_SRC
}"
NOW_EPOCH="$NOW"; GATE_DEAD_VERDICT_GRACE_MINUTES="${GATE_DEAD_VERDICT_GRACE_MINUTES:-15}"
reaper_world() {   # 4 beads like 05/10: REQUEUED, in_progress, reviewer assigned, parent run closed+superseded, 60m old
  new_world
  local r v
  for r in 1 2; do
    mk "gr$r" closed "" 60 "type:quality-gate-run" "gate-status:superseded"
    mk "vb$r" in_progress "gate-reviewer-adhoc-dead$r" 60 "$VB_LBL_PENDING" "gate-run:gr$r" "reviewer-index:1" "verdict:REQUEUED"
  done
}
reaper_world
OUT=$( set -e; run_reaper_block; echo "RC=$?" ) 2>&1
if [ "$(st vb1)" = closed ] && [ "$(st vb2)" = closed ] && has "$OUT" "RC=0"; then
  ok "reaper: both reviewer-assigned REQUEUED pareceres with a terminal parent are now closed (they were refused forever before)"
else
  bad "reaper still cannot close an assigned parecer: vb1=$(st vb1) vb2=$(st vb2) out=[$OUT] warn=[$(warns)]"
fi
if ! has "$(warns)" "FAILED"; then ok "reaper: no 'FAILED' WARN on the happy path"; else bad "reaper warned FAILED despite closing: [$(warns)]"; fi

reaper_world; FORCE_REFUSED=vb1
OUT=$( set -e; run_reaper_block; echo "RC=$?" ) 2>&1
if [ "$(st vb1)" = in_progress ] && [ "$(st vb2)" = closed ] && has "$(warns)" "boom: close refused" && has "$(warns)" "ga-hwjrlq: close of parked verdict vb1 FAILED"; then
  ok "reaper: a close bd refuses is a visible WARN WITH the cause (bd's text), and the sweep still closes the next parecer"
else
  bad "reaper failure not diagnosable: vb1=$(st vb1) vb2=$(st vb2) warn=[$(warns)]"
fi

# ── 7. class lock: no bare close of a verdict bead may come back ──────────────
echo "── 7. no bare 'bd … close' of a verdict-bead variable in the dispatcher/guard ──"
# bare_verdict_closes < file : "<line>:<text>" for every non-comment line that closes a verdict-bead variable
# without close_gate_verdict. OV_ID (ga-qtc16) is deliberately NOT listed: that population is UNASSIGNED by
# definition (parent run reaped) and is never refused. Waive a line with `# plain-close-ok: <why>`.
bare_verdict_closes() {
  grep -nE 'bd[[:space:]]+-C[[:space:]]+"\$[A-Za-z_]+"[[:space:]]+close[[:space:]]+"\$\{?(VB|PC_VB|DV_ID|PV_ID)\}?"' \
    | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'plain-close-ok'
}
DET_FIXTURE='          bd -C "$GC_CITY" close "$VB" 2>/dev/null || true
bd -C "$GC_CITY" close "$PC_VB" -r "x" 2>/dev/null
        bd -C "$GC_CITY" close "$DV_ID" -r "y" 2>/dev/null || \
if bd -C "$GC_CITY" close "$PV_ID" -r "z" 2>/dev/null; then
    # bd -C "$GC_CITY" close "$VB" (a comment)
bd -C "$GC_CITY" close "$VB" 2>/dev/null  # plain-close-ok: unassigned by construction
close_gate_verdict "$VB" "ok"
bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "run" 2>/dev/null || true
bd -C "$GC_CITY" close "$OV_ID" -r "qtc16" 2>/dev/null'
DET_N="$(printf '%s\n' "$DET_FIXTURE" | bare_verdict_closes | grep -c .)"
if [ "$DET_N" = "4" ]; then
  ok "detector self-test: flags the 4 bare forms; ignores the comment, the waived line, the helper, the gate-run close and OV_ID"
else
  bad "detector self-test: expected exactly 4 flagged fixture lines, got $DET_N"
fi
LIVE_BARE="$( { bare_verdict_closes < "$DISPATCHER"; bare_verdict_closes < "$GUARD"; } || true)"
if [ -z "$LIVE_BARE" ]; then
  ok "THE CLASS: zero bare closes of VB/PC_VB/DV_ID/PV_ID remain (was 6: 4 in the dispatcher, 2 in the guard reapers)"
else
  bad "bare verdict close(s) came back — route through close_gate_verdict, or waive with '# plain-close-ok: <why>': $LIVE_BARE"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
