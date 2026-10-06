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
# call sites are the LIVE blocks extracted by sentinel — never hand-copied logic:
#   * dispatcher infra-requeue-block    (dead-reviewer / no-eval / quota-stop parking + run close)
#   * dispatcher phase-c-timeout-close-fn (TIMEOUT parking)
#   * guard parked-verdict-reap         (the ga-hwjrlq reaper that failed silently for hours)
#   * guard close-pending-verdicts-for-run-fn / close-dead-reviewer-verdicts-fn (the guard's own
#     cascade closers — the gate's first verdict on this bead found them still doing the plain close)
# Only bd/log/warn/notify/set_gate_status/gate_requeue_* are stubbed (and the bd-list-cached.sh shim
# call inside close_dead_reviewer_verdicts, which is redirected to the same bd stub — see section 7).
#
# Two static locks keep the CLASS closed, not just the instances fixed here (sections 8 and 9):
#   8. every close of a gate-run, in the dispatcher and in the guard, is followed by a verdict net
#      (or carries a `verdict-net-ok` waiver that says why the run has no verdict beads);
#   9. every `bd … close "$VAR"` whose VAR is not a known NON-verdict bead is flagged — a new
#      verdict variable under any name fails there instead of slipping past a list of names.
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
  local req_all="" req_any="" f id l ok oka out="" show_all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -l) req_all="$req_all $2"; shift 2 ;;
      --label-any) req_any="$2"; shift 2 ;;
      --limit) shift 2 ;;
      --all) show_all=1; shift ;;     # the guard cascades list with --all and filter the open ones themselves
      *) shift ;;
    esac
  done
  [ -n "$LIST_FAIL" ] && { echo "dolt: query timeout" >&2; return 1; }
  [ -n "$LIST_GARBAGE" ] && { echo '{"error":"not a list"}'; return 0; }
  for f in "$T"/*.status; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .status)"
    [ "$show_all" = 0 ] && [ "$(cat "$f")" = closed ] && continue   # bd list hides closed unless --all
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
log()    { echo "$*" >> "$T/log.log"; return 0; }   # recorded, not dropped: an "UNVERIFIED" line is a behavior under test
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
# mk_incident_closed_run <run> <vb> : the same incident AT THE MOMENT THE NET RUNS — the caller has just closed the run
# (the net refuses to force-close pareceres under a run that does not read closed; see section 3).
mk_incident_closed_run() { mk_incident "$@"; printf closed > "$T/$1.status"; }

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
if [ "$RC" = 0 ] && [ "$(st vb1)" = closed ] && [ -z "$(warns)" ] && has "$(cat "$T/log.log" 2>/dev/null)" "UNVERIFIED"; then
  ok "close succeeded but the read-back is unreadable → success, no false alarm (unreadable is not 'still open') — and it is logged UNVERIFIED, never silent (unreadable is not 'verified closed' either)"
else
  bad "unreadable read-back mis-handled: rc=$RC warn=[$(warns)] log=[$(cat "$T/log.log" 2>/dev/null)]"
fi

# ── 3. close_open_run_verdicts ─────────────────────────────────────────────────
echo "── 3. close_open_run_verdicts: a closed run leaves no open parecer behind ──"
new_world; mk_incident_closed_run gr1 vbA
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

new_world; mk_incident_closed_run gr1 vbA; LIST_FAIL=1
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && has "$(warns)" "could not list" && has "$(warns)" "gr1"; then
  ok "a failed LIST is not 'none': returns 1, closes nothing, WARN names the run (error != empty)"
else
  bad "unreadable list collapsed into empty: rc=$RC A=$(st vbA) warn=[$(warns)]"
fi

new_world; mk_incident_closed_run gr1 vbA; LIST_GARBAGE=1
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && has "$(warns)" "not a JSON array"; then
  ok "a non-array answer (error envelope) is not 'none' either"
else
  bad "garbage list mis-handled: rc=$RC warn=[$(warns)]"
fi

new_world; mk_incident_closed_run gr1 vbA; mk vbB in_progress "gate-reviewer-adhoc-q" 30 "$VB_LBL_PENDING" "gate-run:gr1" "verdict:pending"; FORCE_REFUSED=vbA
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && [ "$(st vbB)" = closed ]; then
  ok "one parecer that cannot be closed does not stop the others (vbB closed), and the call reports failure (rc=1)"
else
  bad "partial failure mis-handled: rc=$RC A=$(st vbA) B=$(st vbB)"
fi
# the callers close the run with `2>/dev/null || true`, so the net must not trust that the run is closed: a parecer
# force-closed under a run that is in fact still open leaves the run judged with no verdict (the ga-fi1dh hazard)
new_world; mk_incident gr1 vbA        # gr1 still reads in_progress: its close did not take
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && has "$(warns)" "gr1" && has "$(warns)" "not closed" && ! has "$(cat "$T/calls.log")" "close vbA"; then
  ok "run still open (its close did not persist): returns 1, no parecer is force-closed under it, WARN names the run (the ga-fi1dh hazard)"
else
  bad "pareceres force-closed under a run that is not closed: rc=$RC A=$(st vbA) calls=[$(cat "$T/calls.log")] warn=[$(warns)]"
fi

new_world; mk_incident_closed_run gr1 vbA; SHOW_FAIL=gr1
close_open_run_verdicts gr1 "x"; RC=$?
if [ "$RC" = 1 ] && [ "$(st vbA)" = in_progress ] && has "$(warns)" "unreadable" && ! has "$(cat "$T/calls.log")" "close vbA"; then
  ok "run status unreadable: not 'closed' either — returns 1, closes nothing, WARN says unreadable (three states, not two)"
else
  bad "unreadable run status collapsed into closed: rc=$RC A=$(st vbA) calls=[$(cat "$T/calls.log")] warn=[$(warns)]"
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

# ── 7. the guard's OWN cascade closers (the gate's finding on the first attempt) ───────────────
# close_pending_verdicts_for_run (ga-hgsqg) and close_dead_reviewer_verdicts (ga-g4m18) close verdicts that are
# assigned BY CONSTRUCTION (a dead or still-live reviewer), so the plain `bd close … 2>/dev/null || true` that stood
# there was refused and hidden on exactly the population it exists for. Both are driven from their LIVE source.
echo "── 7. guard cascade closers: an assigned in_progress parecer under a terminal run IS closed ──"
CPV_SRC="$(extract_block "$GUARD" close-pending-verdicts-for-run-fn)"
CDR_SRC="$(extract_block "$GUARD" close-dead-reviewer-verdicts-fn)"
[ -n "$CPV_SRC" ] || { echo "FATAL: close-pending-verdicts-for-run-fn sentinel not found" >&2; exit 2; }
[ -n "$CDR_SRC" ] || { echo "FATAL: close-dead-reviewer-verdicts-fn sentinel not found" >&2; exit 2; }
# close_dead_reviewer_verdicts lists through scripts/bd-list-cached.sh (a TTL cache shim around `bd list`, which a
# test city does not have). Point ONLY that call at the bd stub; everything else in the function stays the live text.
SHIM_CALL='bash "$GC_CITY/scripts/bd-list-cached.sh"'
case "$CDR_SRC" in
  *"$SHIM_CALL"*) CDR_SRC="${CDR_SRC//"$SHIM_CALL"/bd}" ;;
  *) echo "FATAL: close_dead_reviewer_verdicts no longer lists through the bd-list-cached.sh shim — update this redirect" >&2; exit 2 ;;
esac
eval "$CPV_SRC"
eval "$CDR_SRC"

for CASCADE in close_pending_verdicts_for_run close_dead_reviewer_verdicts; do
  case "$CASCADE" in
    close_pending_verdicts_for_run) CARGS=(gr1 "run closed (selftest)") ;;
    *)                              CARGS=(gr1) ;;
  esac

  new_world; mk_incident gr1 vb1
  mk vb2 open "" 30 "$VB_LBL_PENDING" "gate-run:gr1" "reviewer-index:2" "verdict:REQUEUED"        # unassigned sibling
  mk vb3 closed "gate-reviewer-adhoc-z" 30 "$VB_LBL_PENDING" "gate-run:gr1" "verdict:PASS"          # already closed
  printf 'ORIGINAL' > "$T/vb3.reason"
  "$CASCADE" "${CARGS[@]}"
  if [ "$(st vb1)" = closed ] && [ "$(st vb2)" = closed ]; then
    ok "$CASCADE: the assigned in_progress parecer AND the unassigned one are closed (the plain close left vb1 in_progress, rc=0, no trace)"
  else
    bad "$CASCADE: vb1=$(st vb1) vb2=$(st vb2) calls=[$(cat "$T/calls.log")] warn=[$(warns)]"
  fi
  if [ "$(cat "$T/vb3.reason")" = ORIGINAL ] && ! has "$(cat "$T/calls.log")" "close vb3"; then
    ok "$CASCADE: an already-closed parecer is left alone"
  else
    bad "$CASCADE: touched an already-closed parecer: calls=[$(cat "$T/calls.log")]"
  fi
  if [ -s "$T/vb1.comments" ] && has "$(cat "$T/vb1.comments")" "cascade-closed" && [ ! -s "$T/warn.log" ]; then
    ok "$CASCADE: the 'cascade-closed' comment is posted after the close, with no WARN on the happy path"
  else
    bad "$CASCADE: comment/WARN wrong on the happy path: comments=[$(cat "$T/vb1.comments" 2>/dev/null)] warn=[$(warns)]"
  fi

  # a close bd refuses even with --force: visible, with bd's own words, and NO comment claiming a close that never happened
  new_world; mk_incident gr1 vb1; FORCE_REFUSED=vb1
  "$CASCADE" "${CARGS[@]}"
  if [ "$(st vb1)" = in_progress ] && has "$(warns)" "boom: close refused" && [ ! -s "$T/vb1.comments" ]; then
    ok "$CASCADE: a close bd refuses is a WARN carrying the cause, and no 'cascade-closed' comment is left claiming it happened"
  else
    bad "$CASCADE: refusal not surfaced / false comment: vb1=$(st vb1) comments=[$(cat "$T/vb1.comments" 2>/dev/null)] warn=[$(warns)]"
  fi

  # a close that returned rc=0 without persisting: the read-back catches it (effect checked, not the return code)
  new_world; mk_incident gr1 vb1; CLOSE_LIES=vb1
  "$CASCADE" "${CARGS[@]}"
  if [ "$(st vb1)" = in_progress ] && has "$(warns)" "returned success but the bead reads status='in_progress'" && [ ! -s "$T/vb1.comments" ]; then
    ok "$CASCADE: rc=0 without the bead closing is caught and not narrated as a close"
  else
    bad "$CASCADE: a close that did not persist was reported as done: vb1=$(st vb1) warn=[$(warns)]"
  fi

  # error != empty: a failed LIST must not read as 'this run has no verdicts'
  new_world; mk_incident gr1 vb1; LIST_FAIL=1
  "$CASCADE" "${CARGS[@]}"; RC=$?
  if [ "$RC" = 0 ] && [ "$(st vb1)" = in_progress ] && has "$(warns)" "could not list" && has "$(warns)" "gr1"; then
    ok "$CASCADE: a failed LIST is a WARN naming the run (not 'none'); returns 0 on purpose — the guard runs under set -e and Step 0b reapers are the backstop"
  else
    bad "$CASCADE: unreadable list collapsed into empty/aborted: rc=$RC vb1=$(st vb1) warn=[$(warns)]"
  fi
done

# ── 8. coverage lock: a closed gate-run is never left without a verdict net ────────────────────
echo "── 8. every close of a gate-run is followed by a verdict net (or a waiver that says why) ──"
# run_closes_without_net <file> <close-target-regex> <net-regex> : "<line>:<text>" for every non-comment line that
# closes a gate-run and is NOT followed — before the next gate-run close, within 8 non-comment lines — by a net
# call at the start of a line. A same-line `verdict-net-ok` waiver is the only other exit (and states its reason).
# With a 4th argument `count` it prints instead how many gate-run closes it EXAMINED (waived ones included): an empty
# "unnetted" list is only evidence if the scan saw closes at all — a renamed variable or a regex that stopped matching
# would otherwise read as a clean pass (nothing found != found nothing wrong).
run_closes_without_net() {
  awk -v tgt="$2" -v net="$3" -v mode="${4:-}" '
    function is_comment(s) { return s ~ /^[ \t]*#/ }
    { line[NR] = $0 }
    END {
      total = 0
      close_re = "(^|[^A-Za-z_])bd[ \t][^|;#]*[ \t]close[ \t]+\"\\$\\{?(" tgt ")\\}?\""
      for (i = 1; i <= NR; i++) {
        if (is_comment(line[i]) || line[i] !~ close_re) continue
        total++
        if (line[i] ~ /verdict-net-ok/) continue
        found = 0; seen = 0
        for (j = i + 1; j <= NR && seen < 8; j++) {
          if (is_comment(line[j])) continue
          seen++
          if (line[j] ~ close_re) break
          if (line[j] ~ ("^[ \t]*(" net ")[ \t]")) { found = 1; break }
        }
        if (!found && mode != "count") print i ":" line[i]
      }
      if (mode == "count") print total
    }' "$1"
}
# num_or_zero <text> : text when it is a plain number, else 0 (a scan that errored must not read as "plenty")
num_or_zero() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
DISP_RUN_TGT='GATE_RUN_ID|SIBLING_RUN_ID|sibling_id|run_id'
GUARD_RUN_TGT='GR_ID'
DISP_NET='close_open_run_verdicts'
GUARD_NET='close_pending_verdicts_for_run|close_dead_reviewer_verdicts|close_open_run_verdicts'
NET_FIXTURE='  bd -C "$GC_CITY" close "$GR_ID" -r "a" 2>/dev/null || true
  CLOSED="$CLOSED $GR_ID"
  # close_pending_verdicts_for_run only in a comment
  something_else
  bd -C "$GC_CITY" close "$GR_ID" -r "b" 2>/dev/null || true
  CLOSED="$CLOSED $GR_ID"
  close_pending_verdicts_for_run "$GR_ID" "why"
  bd -C "$GC_CITY" close "$GR_ID" -r "c" 2>/dev/null || true  # verdict-net-ok: ZV_TOTAL=0
  bd -C "$GC_CITY" close "$GR_ID" -r "d" 2>/dev/null || true
  bd -C "$GC_CITY" close "$GR_ID" -r "e" 2>/dev/null || true
  close_dead_reviewer_verdicts "$GR_ID"
  # bd -C "$GC_CITY" close "$GR_ID" -r "f (commented out)"
  bd -C "$GC_CITY" close "$OTHER" -r "g"'
NET_FLAGGED="$(printf '%s\n' "$NET_FIXTURE" > "$ROOT/net_fixture.sh"; run_closes_without_net "$ROOT/net_fixture.sh" "$GUARD_RUN_TGT" "$GUARD_NET" | cut -d: -f1 | tr '\n' ' ')"
# line 1 (net comes only in a comment), line 9 (the next close arrives before any net — it must not borrow line 10's)
if [ "$NET_FLAGGED" = "1 9 " ]; then
  ok "detector self-test: flags a close with no net (even when the net is only in a comment, or belongs to the NEXT close); accepts the net, the waiver, the commented-out close"
else
  bad "detector self-test: expected lines '1 9', got '$NET_FLAGGED'"
fi
# floors = how many such closes exist today (10 in the dispatcher, 6 in the guard); more is fine, fewer means the scan lost sight of them
DISP_SEEN="$(num_or_zero "$(run_closes_without_net "$DISPATCHER" "$DISP_RUN_TGT" "$DISP_NET" count)")"
GUARD_SEEN="$(num_or_zero "$(run_closes_without_net "$GUARD" "$GUARD_RUN_TGT" "$GUARD_NET" count)")"
DISP_UNNETTED="$(run_closes_without_net "$DISPATCHER" "$DISP_RUN_TGT" "$DISP_NET")"
if [ "$DISP_SEEN" -ge 10 ] && [ -z "$DISP_UNNETTED" ]; then
  ok "dispatcher: all $DISP_SEEN closes of a gate-run (GATE_RUN_ID / SIBLING_RUN_ID / sibling_id / run_id) are followed by close_open_run_verdicts"
else
  bad "dispatcher: examined $DISP_SEEN gate-run closes (expected >= 10 — fewer means the scan went blind) and these have no verdict net after them — add close_open_run_verdicts or waive with '# verdict-net-ok: <why>': $DISP_UNNETTED"
fi
GUARD_UNNETTED="$(run_closes_without_net "$GUARD" "$GUARD_RUN_TGT" "$GUARD_NET")"
if [ "$GUARD_SEEN" -ge 6 ] && [ -z "$GUARD_UNNETTED" ]; then
  ok "guard: all $GUARD_SEEN closes of a gate-run (GR_ID) are followed by a cascade closer, or waived as a 0-verdict run"
else
  bad "guard: examined $GUARD_SEEN gate-run closes (expected >= 6 — fewer means the scan went blind) and these have no verdict cascade after them — add close_pending_verdicts_for_run / close_dead_reviewer_verdicts or waive with '# verdict-net-ok: <why>': $GUARD_UNNETTED"
fi
# a waiver is only honest where the run really has no verdict beads: the ONLY waived closes must sit under the
# ZV_TOTAL=0 branch, whose count falls back to 1 when unreadable (error is never read as 'none')
WAIVED_LINES="$(grep -nE 'verdict-net-ok' "$GUARD" | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)"
WAIVED_BAD=""
for WL in $WAIVED_LINES; do
  # contained = a preceding `if [ "$ZV_TOTAL" = "0" ]` exists and its own `fi` (same indentation) has not appeared yet
  CONTAINED="$(awk -v n="$WL" '
    NR >= n { exit }
    /^[ ]*if \[ "\$ZV_TOTAL" = "0" \]; then[ ]*$/ { ind = $0; sub(/if.*/, "", ind); open = 1; next }
    open && $0 == (ind "fi") { open = 0 }
    END { print (open ? "yes" : "no") }' "$GUARD")"
  [ "$CONTAINED" = yes ] || WAIVED_BAD="$WAIVED_BAD $WL"
done
if [ -n "$WAIVED_LINES" ] && [ -z "$WAIVED_BAD" ] && grep -qE "ZV_TOTAL=1 ;; esac" "$GUARD"; then
  ok "guard: every waived close ($(printf '%s' "$WAIVED_LINES" | tr '\n' ' ')) is inside the still-open ZV_TOTAL=0 branch, and an unreadable count falls back to 1"
else
  bad "guard: a 'verdict-net-ok' waiver is outside the ZV_TOTAL=0 branch (lines:$WAIVED_BAD) or the unreadable→1 fallback is gone"
fi

# ── 9. class lock: no bare close of a verdict bead may come back, under ANY variable name ──────
echo "── 9. no bare 'bd … close' of an unclassified bead variable in the dispatcher/guard ──"
# The first version of this lock grepped four hard-coded names (VB|PC_VB|DV_ID|PV_ID) — the list of instances that had
# been fixed, not the class — and stayed green with two bare closes under `v_id` in the same file. This one inverts it:
# every `bd … close "$VAR"` is flagged unless VAR is a known NON-verdict bead, so a new verdict variable (whatever its
# name) fails here and has to be classified. Waive one line with `# plain-close-ok: <why>`.
#   gate-run:  GATE_RUN_ID SIBLING_RUN_ID sibling_id run_id GR_ID        (section 8 covers their verdict net)
#   marker:    MARKER_ID marker_id NR_MARKER_ID EXT_ID DUP_ID
#   source/wisp bead: bead_id _bead_id _WID
#   verdict, never refused: OV_ID (ga-qtc16 — UNASSIGNED by definition: its parent run was reaped)
#   the helper's own forced close: _vb (inside close_gate_verdict)
NON_VERDICT_TARGETS='GATE_RUN_ID|SIBLING_RUN_ID|sibling_id|run_id|GR_ID|MARKER_ID|marker_id|NR_MARKER_ID|EXT_ID|DUP_ID|bead_id|_bead_id|_WID|OV_ID|_vb'
# all_var_closes < file : every non-comment `bd … close "$VAR"` line (the population the lock classifies)
all_var_closes() {
  grep -nE '(^|[^A-Za-z_])bd[[:space:]][^|;#]*[[:space:]]close[[:space:]]+"\$\{?[A-Za-z_][A-Za-z_0-9]*\}?"' \
    | grep -vE '^[0-9]+:[[:space:]]*#'
}
bare_verdict_closes() {
  all_var_closes | grep -v 'plain-close-ok' \
    | grep -vE 'close[[:space:]]+"\$\{?('"$NON_VERDICT_TARGETS"')\}?"'
}
DET_FIXTURE='          bd -C "$GC_CITY" close "$VB" 2>/dev/null || true
bd -C "$GC_CITY" close "$PC_VB" -r "x" 2>/dev/null
        bd -C "$GC_CITY" close "$DV_ID" -r "y" 2>/dev/null || \
if bd -C "$GC_CITY" close "$PV_ID" -r "z" 2>/dev/null; then
bd -C "$GC_CITY" close "$v_id" -r "w" 2>/dev/null || true
bd -C "$GC_CITY" close "${SOME_NEW_PARECER}" 2>/dev/null
    # bd -C "$GC_CITY" close "$VB" (a comment)
bd -C "$GC_CITY" close "$VB" 2>/dev/null  # plain-close-ok: unassigned by construction
close_gate_verdict "$VB" "ok"
bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "run" 2>/dev/null || true
bd -C "$GC_CITY" close "$OV_ID" -r "qtc16" 2>/dev/null'
DET_N="$(printf '%s\n' "$DET_FIXTURE" | bare_verdict_closes | grep -c .)"
if [ "$DET_N" = "6" ]; then
  ok "detector self-test: flags the 6 bare forms (incl. v_id — the name the first lock missed — and an unknown new name); ignores the comment, the waived line, the helper, the gate-run close and OV_ID"
else
  bad "detector self-test: expected exactly 6 flagged fixture lines, got $DET_N"
fi
LIVE_BARE="$( { bare_verdict_closes < "$DISPATCHER"; bare_verdict_closes < "$GUARD"; } || true)"
# an empty LIVE_BARE only counts if the scan SAW the closes: there are 34 today (20 dispatcher + 14 guard); a regex that
# stopped matching would print nothing too
LIVE_SEEN="$(num_or_zero "$( { all_var_closes < "$DISPATCHER"; all_var_closes < "$GUARD"; } | grep -c . || true)")"
if [ "$LIVE_SEEN" -ge 30 ] && [ -z "$LIVE_BARE" ]; then
  ok "THE CLASS: of $LIVE_SEEN bd closes by variable, none is an unclassified bead (the verdict closes were 8: 4 dispatcher + 2 guard reapers + the 2 guard cascades the first attempt missed)"
else
  bad "class lock: examined $LIVE_SEEN closes (expected >= 30 — fewer means the scan went blind) and/or found a bare close of an unclassified bead variable — a verdict goes through close_gate_verdict; a non-verdict bead is added to NON_VERDICT_TARGETS with its reason; or waive with '# plain-close-ok: <why>': $LIVE_BARE"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
