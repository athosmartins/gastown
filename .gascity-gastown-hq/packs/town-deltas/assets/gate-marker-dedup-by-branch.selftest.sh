#!/usr/bin/env bash
# gate-marker-dedup-by-branch.selftest.sh — Prove the ga-o64z1 fix in isolation,
# with NO live Dolt/gc/launchd:
#
#   BUG: every /gate-done resubmission (gate FAIL -> author fixes -> resubmit)
#   creates a brand-new type:quality-gate-marker bead, but nothing ever closed
#   the PRIOR marker for the SAME branch. Confirmed live: fix/ga-0xmxt-midturn-
#   liveness accumulated 3 simultaneous open markers (23:40 needs-rebase, 00:15,
#   05:46); fix/ga-991au-skip-ineligible and fix/ga-kyxih-gate-rebase-merge-
#   commit-tip 2 each. Not just queue litter: quality-gate-dispatcher.sh's
#   Step 5b (ga-dupnv, "one branch = one authoritative run") sees a live
#   gate-run for the branch and makes the WHOLE sweep YIELD without admitting
#   any other marker, so a duplicate sterilizes sweeps while its sibling runs —
#   and the cost grows with every resubmission (the case that most needs the
#   gate pays the most). FIX: quality-gate-guard.sh Step 4b — right after a
#   marker's branch is validated (Step 4) and before anything else happens for
#   it, supersede any OTHER open marker for the same branch in
#   gate-status:{ready,queued,needs-rebase}. dispatching/running are left
#   alone (a legitimate live run is the dispatcher's own Step 5b's job).
#
# This harness sources the guard in lib-only mode to unit-test the REAL pure
# function (dup_marker_ids_for_branch) and exercise the REAL set_gate_status
# I/O helper against an in-shell bd() mock (file-backed state — the system
# bash is 3.2, no associative arrays, same constraint documented in
# quality-gate-reconvene.selftest.sh), then drift-guards the live script so a
# future refactor can't silently drop the fix. Exit 0 iff every assertion
# holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
absent() { if grep -qE "$2" "$1"; then bad "$3 — pattern unexpectedly found: $2"; else ok "$3"; fi; }

# ── Load the REAL helpers from the guard (lib-only = no live sweep) ──────────
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type dup_marker_ids_for_branch >/dev/null 2>&1 || { echo "FATAL: dup_marker_ids_for_branch not defined by guard"; exit 1; }
type set_gate_status           >/dev/null 2>&1 || { echo "FATAL: set_gate_status not defined by guard"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

GC_CITY="/tmp/gate-marker-dedup-test-city"

# ── 1. dup_marker_ids_for_branch — the pure per-branch filter ────────────────
echo "── 1. dup_marker_ids_for_branch (branch-exact match, self/status/closed guards) ──"

eq "(a) empty marker list -> no duplicates" \
  "$(dup_marker_ids_for_branch '[]' 'fix/ga-x' 'ga-new')" ""

eq "(b) one other open marker, same branch -> matched" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-old","status":"open","description":"branch: fix/ga-x\n"}]' 'fix/ga-x' 'ga-new')" \
  "ga-old"

eq "(c) the marker THIS sweep just claimed is excluded even if same branch" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-new","status":"open","description":"branch: fix/ga-x\n"}]' 'fix/ga-x' 'ga-new')" \
  ""

eq "(d) AC3 — a DIFFERENT branch's marker is never matched" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-other","status":"open","description":"branch: fix/ga-DIFFERENT\n"}]' 'fix/ga-x' 'ga-new')" \
  ""

eq "(e) closed candidate excluded (defense-in-depth, mirrors ga-tgj23)" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-old","status":"closed","description":"branch: fix/ga-x\n"}]' 'fix/ga-x' 'ga-new')" \
  ""

eq "(f) missing status field -> not confirmed open -> excluded" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-old","description":"branch: fix/ga-x\n"}]' 'fix/ga-x' 'ga-new')" \
  ""

eq "(g) substring safety: fix/ga-1 does NOT match fix/ga-10" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-old","status":"open","description":"branch: fix/ga-10\n"}]' 'fix/ga-1' 'ga-new')" \
  ""

eq "(h) multiple siblings for the same branch are all returned" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-m1","status":"open","description":"branch: fix/ga-x\n"},{"id":"ga-m2","status":"open","description":"branch: fix/ga-x\n"}]' 'fix/ga-x' 'ga-new' | sort | tr '\n' ' ')" \
  "ga-m1 ga-m2 "

eq "(i) open + closed + other-branch mixed -> only the one real duplicate" \
  "$(dup_marker_ids_for_branch '[{"id":"ga-dead","status":"closed","description":"branch: fix/ga-x\n"},{"id":"ga-live","status":"open","description":"branch: fix/ga-x\n"},{"id":"ga-elsewhere","status":"open","description":"branch: fix/ga-y\n"}]' 'fix/ga-x' 'ga-new')" \
  "ga-live"

# ── 2. AC4 — fixture: 3 pre-existing markers, submit the 4th, exactly 1 open ──
echo "── 2. AC4 fixture: 3 markers same branch -> after the 4th, exactly 1 open ──"

# File-backed mock state (bash 3.2 has no associative arrays — same pattern as
# quality-gate-reconvene.selftest.sh's BD_ASSIGN_FILE). One file tracks the
# CURRENT gate-status per id (last line wins, via awk); one records closures.
BD_LABELS_FILE="$(mktemp)"
BD_CLOSED_FILE="$(mktemp)"
: > "$BD_LABELS_FILE"
: > "$BD_CLOSED_FILE"
bd_status_of() { awk -v b="$1" '$1==b{v=$2} END{print v}' "$BD_LABELS_FILE"; }

# Seed the 3 pre-existing markers across the exact AC1 target states.
echo "ga-m1 ready" >> "$BD_LABELS_FILE"
echo "ga-m2 queued" >> "$BD_LABELS_FILE"
echo "ga-m3 needs-rebase" >> "$BD_LABELS_FILE"

# bd() mock: index-scan argv for the verb, pull id/value at fixed offsets.
# Handles exactly what set_gate_status + the Step 4b loop call: show, label
# add/remove, close, comment. Plain indexed array (bash 3.2-safe — no -A).
bd() {
  local -a A=("$@")
  local n=${#A[@]} i t verb="" sub="" id="" val=""
  for ((i = 0; i < n; i++)); do
    t="${A[i]}"
    case "$t" in
      show|close|comment|label) [ -z "$verb" ] && verb="$t" ;;
    esac
  done
  case "$verb" in
    show)
      for ((i = 0; i < n; i++)); do [ "${A[i]}" = "show" ] && { id="${A[i+1]}"; break; }; done
      echo "{\"labels\":[\"gate-status:$(bd_status_of "$id")\"]}"
      ;;
    close)
      for ((i = 0; i < n; i++)); do [ "${A[i]}" = "close" ] && { id="${A[i+1]}"; break; }; done
      echo "$id" >> "$BD_CLOSED_FILE"
      ;;
    label)
      for ((i = 0; i < n; i++)); do
        if [ "${A[i]}" = "add" ] || [ "${A[i]}" = "remove" ]; then
          sub="${A[i]}"; id="${A[i+1]}"; val="${A[i+2]}"; break
        fi
      done
      if [ "$sub" = "add" ]; then
        case "$val" in gate-status:*) echo "$id ${val#gate-status:}" >> "$BD_LABELS_FILE" ;; esac
      fi
      # "remove" is a no-op for tracked state: the paired "add" that always
      # follows it in set_gate_status is what the last-write-wins lookup reads.
      ;;
    comment) : ;;  # not asserted on
  esac
  return 0
}

BRANCH="fix/ga-ac4-test"
NEW_MARKER_ID="ga-m4"
MOCK_MARKERS_JSON='[
  {"id":"ga-m1","status":"open","description":"branch: fix/ga-ac4-test\nbead_id: ga-src\n"},
  {"id":"ga-m2","status":"open","description":"branch: fix/ga-ac4-test\nbead_id: ga-src\n"},
  {"id":"ga-m3","status":"open","description":"branch: fix/ga-ac4-test\nbead_id: ga-src\n"},
  {"id":"ga-m4","status":"open","description":"branch: fix/ga-ac4-test\nbead_id: ga-src\n"}
]'

DUP_IDS=$(dup_marker_ids_for_branch "$MOCK_MARKERS_JSON" "$BRANCH" "$NEW_MARKER_ID")
DUP_COUNT=$(printf '%s\n' "$DUP_IDS" | grep -c . || true)
eq "AC4: submitting the 4th finds exactly 3 pre-existing duplicates" "$DUP_COUNT" "3"

# Apply the REAL supersede effect (set_gate_status + close) — mirrors Step 4b's
# wiring exactly, against the file-backed mock above.
printf '%s\n' "$DUP_IDS" | while IFS= read -r DUP_ID; do
  [ -z "$DUP_ID" ] && continue
  set_gate_status "$DUP_ID" "superseded"
  bd close "$DUP_ID" -r "test: superseded by $NEW_MARKER_ID" >/dev/null 2>&1 || true
done

eq "AC4: ga-m1 (was ready) is now gate-status:superseded"       "$(bd_status_of ga-m1)" "superseded"
eq "AC4: ga-m2 (was queued) is now gate-status:superseded"      "$(bd_status_of ga-m2)" "superseded"
eq "AC4: ga-m3 (was needs-rebase) is now gate-status:superseded" "$(bd_status_of ga-m3)" "superseded"

CLOSED_COUNT=$(sort -u "$BD_CLOSED_FILE" | grep -c . || true)
eq "AC4: exactly 3 markers closed" "$CLOSED_COUNT" "3"
if grep -qx "ga-m4" "$BD_CLOSED_FILE"; then
  bad "AC4: the NEW (4th) marker must stay open — it was closed"
else
  ok "AC4: the NEW (4th) marker stays open (never closed) — exactly 1 open after the 4th submission"
fi

# ── 3. AC3 — two DIFFERENT branches with simultaneous markers stay untouched ──
echo "── 3. AC3 non-regression: two different branches, each keeps its own siblings ──"
MOCK_TWO_BRANCHES='[
  {"id":"ga-a-old","status":"open","description":"branch: fix/ga-branch-A\n"},
  {"id":"ga-a-new","status":"open","description":"branch: fix/ga-branch-A\n"},
  {"id":"ga-b-old","status":"open","description":"branch: fix/ga-branch-B\n"},
  {"id":"ga-b-new","status":"open","description":"branch: fix/ga-branch-B\n"}
]'
DUP_A=$(dup_marker_ids_for_branch "$MOCK_TWO_BRANCHES" "fix/ga-branch-A" "ga-a-new")
DUP_B=$(dup_marker_ids_for_branch "$MOCK_TWO_BRANCHES" "fix/ga-branch-B" "ga-b-new")
eq "AC3: branch A's dedup finds only ga-a-old (never touches branch B)" "$DUP_A" "ga-a-old"
eq "AC3: branch B's dedup finds only ga-b-old (never touches branch A)" "$DUP_B" "ga-b-old"

# ── 4. DRIFT GUARD: Step 4b wired between Step 4 (validation) and Step 5 ─────
echo "── 4. drift guard: Step 4b present, ordered, and scoped correctly ──"
STEP4_LN=$(grep -n '# ── Step 4: Input validation' "$GUARD" | head -1 | cut -d: -f1)
STEP4B_LN=$(grep -n '# ── Step 4b (ga-o64z1)' "$GUARD" | head -1 | cut -d: -f1)
STEP5_LN=$(grep -n '# ── Step 5: Derive author' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$STEP4_LN" ] && [ -n "$STEP4B_LN" ] && [ -n "$STEP5_LN" ] \
   && [ "$STEP4_LN" -lt "$STEP4B_LN" ] && [ "$STEP4B_LN" -lt "$STEP5_LN" ]; then
  ok "Step 4b (line $STEP4B_LN) sits between Step 4 (line $STEP4_LN) and Step 5 (line $STEP5_LN)"
else
  bad "Step 4b must sit between Step 4 and Step 5 (got Step4=$STEP4_LN Step4b=$STEP4B_LN Step5=$STEP5_LN)"
fi
has "$GUARD" 'DUP_IDS=\$\(dup_marker_ids_for_branch' "Step 4b calls the real dup_marker_ids_for_branch (not a re-inlined query)"

# ── 5. DRIFT GUARD: AC1 — only ready/queued/needs-rebase are queried; ────────
#    dispatching/running (a legitimate live run) are never touched by Step 4b.
echo "── 5. drift guard: AC1 scope — dispatching/running excluded from the query ──"
STEP4B_BLOCK=$(sed -n "${STEP4B_LN},${STEP5_LN}p" "$GUARD")
echo "$STEP4B_BLOCK" | grep -q -- '--label-any gate-status:ready'        && ok "queries gate-status:ready"        || bad "missing gate-status:ready in query"
echo "$STEP4B_BLOCK" | grep -q -- '--label-any gate-status:queued'       && ok "queries gate-status:queued"       || bad "missing gate-status:queued in query"
echo "$STEP4B_BLOCK" | grep -q -- '--label-any gate-status:needs-rebase' && ok "queries gate-status:needs-rebase" || bad "missing gate-status:needs-rebase in query"
if echo "$STEP4B_BLOCK" | grep -q 'gate-status:dispatching\|gate-status:running'; then
  bad "AC1 violation: Step 4b's block references dispatching/running — a legitimate live run must never be touched here"
else
  ok "AC1: Step 4b never references gate-status:dispatching or gate-status:running"
fi

# ── 6. DRIFT GUARD: AC2 — query-failed vs no-duplicates-found are DISTINCT ───
echo "── 6. drift guard: AC2 — error and empty outcomes log different text ──"
has "$GUARD" "dedup check SKIPPED \(non-fatal, distinct from '0 duplicates found'\)" \
  "distinct log line exists for the QUERY-FAILED outcome"
has "$GUARD" 'no pre-existing open marker for branch \$BRANCH — nothing to supersede' \
  "distinct log line exists for the NO-DUPLICATES-FOUND outcome"
has "$GUARD" 'has \$DUP_COUNT pre-existing open marker\(s\).*superseding by \$MARKER_ID' \
  "distinct log line exists for the FOUND-AND-SUPERSEDED outcome (carries the count)"
# The three must not collapse to the same literal string (root-class check).
MSG_ERR="dedup check SKIPPED"
MSG_EMPTY="nothing to supersede"
MSG_FOUND="superseding by"
if [ "$MSG_ERR" != "$MSG_EMPTY" ] && [ "$MSG_EMPTY" != "$MSG_FOUND" ] && [ "$MSG_ERR" != "$MSG_FOUND" ]; then
  ok "error / empty / found-and-fixed outcomes are three textually distinct root-classes"
else
  bad "outcome messages collapsed to the same text — error==empty risk (see memory: error-and-empty-must-not-produce-the-same-value)"
fi

# ── 7. syntax ──────────────────────────────────────────────────────────────
echo "── 7. syntax ──"
if bash -n "$GUARD"; then ok "guard passes bash -n"; else bad "guard bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
