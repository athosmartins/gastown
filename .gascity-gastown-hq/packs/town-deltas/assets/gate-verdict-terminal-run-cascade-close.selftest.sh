#!/usr/bin/env bash
# gate-verdict-terminal-run-cascade-close.selftest.sh (ga-hgsqg)
#
# Proves: close_pending_verdicts_for_run() closes a gate-run's own still-OPEN
# verdict bead(s) when called, and that it is actually WIRED into every Vector
# B branch that closes a gate-run bead without checking reviewer liveness
# first (supersede:marker, abort:age, supersede:duplicate) — the three
# branches that previously left a `verdict:pending` bead open forever once
# their parent run went terminal.
#
# THE GAP this closes: close_dead_reviewer_verdicts (ga-g4m18) already
# cascades for supersede:dead-reviewers, and gate-recovery-watchdog.py's
# _close_pending_verdicts_for_run (ga-9as9h, a different file) already
# cascades for that file's FIX 1/FIX 3. Neither touches THIS file's other
# three run-closing branches. Step 0b.1 (ga-u07fn) can't mop up the residue
# either — it requires a non-empty, CONFIRMED-DEAD assignee
# (reconcile_dead_reviewer_verdict_action's own rule 1: reviewer_alive=1 ->
# skip, unconditionally). Nor can Step 0b.2 (ga-qtc16) — it requires the
# parent to be CONFIRMED GONE via bd show (reconcile_orphaned_verdict_action:
# parent "found" -> skip, even if closed). A run closed by supersede:marker/
# abort:age/supersede:duplicate is neither: empty-or-alive assignee, parent
# "found" (just closed, not reaped). The two beads below are exactly that
# shape, MEASURED LIVE 2026-08-10 (ga-hgsqg's own bug report):
#   ga-yv9z9 (parent ga-4z58o, gate-status:superseded) — ~38h stuck
#   ga-ht83i (parent ga-gpiwx, gate-status:superseded) — ~10h stuck
# (Both were actually produced by gate-recovery-watchdog.py's FIX3 before
# ga-9as9h closed that file's version of this same gap — this file's own
# supersede:marker/abort:age/supersede:duplicate branches are a structurally
# identical, independently-reachable gap, which is what this fix closes.
# Real field shapes below are used as fixtures regardless of which mechanism
# originally produced them — the bug class, not the producing file, is what
# this test proves is fixed.)
#
# Strategy mirrors gate-verdict-drained-reviewer-rescue.selftest.sh: extract
# the live "close-pending-verdicts-for-run-fn" and
# "open-verdict-ids-from-json-fn" blocks VERBATIM (real production code) and
# run them under real `set -euo pipefail`, stubbing only the `bd` I/O
# boundary. Separately, a set of TEXT-STRUCTURAL assertions greps the actual
# production source to prove the cascade call is wired into exactly the 3
# intended branches and into none of the file's `skip)` branches — the
# "REGRESSION: an open-run verdict must stay untouched" half of the bug's own
# acceptance criteria, which a call-behavior test alone cannot prove (the
# function itself is intentionally unconditional; the safety comes from
# WHERE it is — and is not — called).
#
# NON-VACUOUSNESS: instead of a synthetic mutation, the wiring assertions run
# against BOTH the current file and the actual pre-fix commit (`git show
# main:...`) and assert the counts differ exactly as expected — the real
# prior HEAD is the mutant, not a guess at one.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-verdict-terminal-run-cascade-close.selftest =="

if [ ! -f "$GUARD" ]; then
  echo "FATAL: guard not found at $GUARD" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_cascade_close <guard-file> <gr_id> <reason> <verdicts_json> <bd_log> -> stdout: rc
# Feeds ONE close_pending_verdicts_for_run() call a mocked `bd list` response
# for <gr_id> and captures every `bd comment`/`bd close` call it makes.
run_cascade_close() {
  local file="$1" gr_id="$2" reason="$3" verdicts_json="$4" bd_log="$5"
  local fn_close fn_open_ids
  fn_close="$(extract_block "$file" "close-pending-verdicts-for-run-fn")"
  fn_open_ids="$(extract_block "$file" "open-verdict-ids-from-json-fn")"
  if [ -z "$fn_close" ] || [ -z "$fn_open_ids" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    BD_LOG="$1"; GR_ID="$2"; REASON="$3"; VERDICTS_JSON="$4"

    bd() {
      case " $* " in
        *" list "*"gate-run:$GR_ID "*) printf "%s" "$VERDICTS_JSON"; return 0 ;;
        *" comment "*)                echo "$*" >> "$BD_LOG"; return 0 ;;
        *" close "*)                  echo "$*" >> "$BD_LOG"; return 0 ;;
      esac
      echo "UNEXPECTED:$*" >> "$BD_LOG"
      return 0
    }

    '"$fn_open_ids"'
    '"$fn_close"'

    close_pending_verdicts_for_run "$GR_ID" "$REASON"
  ' _ "$bd_log" "$gr_id" "$reason" "$verdicts_json"
  return $?
}

echo "── 1. ga-yv9z9 fixture (real shape: empty assignee, verdict:pending, parent ga-4z58o gate-status:superseded) ──"
VB_YV9Z9='[{"id":"ga-yv9z9","status":"open","assignee":null,"labels":["gate-run:ga-4z58o","reviewer-index:1","type:quality-gate-verdict","verdict:pending"]}]'
BD_LOG="$(mktemp)"
run_cascade_close "$GUARD" "ga-4z58o" "companion marker ga-vksgt is terminal/gone, ga-tmug" "$VB_YV9Z9" "$BD_LOG" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "close_pending_verdicts_for_run runs to completion for ga-4z58o (rc=0)"
else
  bad "call failed (rc=$RC) — bd_log: $(tr '\n' ';' < "$BD_LOG")"
fi
grep -q "close ga-yv9z9" "$BD_LOG" \
  && ok "ga-yv9z9 (pending, empty-assignee, parent superseded) was closed" \
  || bad "ga-yv9z9 was NOT closed — bd_log: $(tr '\n' ';' < "$BD_LOG")"
grep -q "comment ga-yv9z9" "$BD_LOG" \
  && ok "ga-yv9z9 got an explanatory comment before closing" \
  || bad "ga-yv9z9 was closed with no comment — bd_log: $(tr '\n' ';' < "$BD_LOG")"
case "$(grep "close ga-yv9z9" "$BD_LOG" || true)" in
  *"ga-hgsqg"*) ok "close reason cites ga-hgsqg (traceable to this fix)" ;;
  *) bad "close reason does not cite ga-hgsqg — $(grep "close ga-yv9z9" "$BD_LOG" || true)" ;;
esac
rm -f "$BD_LOG"

echo "── 2. ga-ht83i fixture (real shape: empty assignee, verdict:pending, parent ga-gpiwx gate-status:superseded) ──"
VB_HT83I='[{"id":"ga-ht83i","status":"open","assignee":null,"labels":["gate-run:ga-gpiwx","reviewer-index:1","type:quality-gate-verdict","verdict:pending"]}]'
BD_LOG="$(mktemp)"
run_cascade_close "$GUARD" "ga-gpiwx" "aborted by guard TTL fallback, age=95m > 90m, ga-tmug" "$VB_HT83I" "$BD_LOG" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "close_pending_verdicts_for_run runs to completion for ga-gpiwx (rc=0)" \
  || bad "call failed (rc=$RC) — bd_log: $(tr '\n' ';' < "$BD_LOG")"
grep -q "close ga-ht83i" "$BD_LOG" \
  && ok "ga-ht83i (pending, empty-assignee, parent superseded) was closed" \
  || bad "ga-ht83i was NOT closed — bd_log: $(tr '\n' ';' < "$BD_LOG")"
rm -f "$BD_LOG"

echo "── 3. mixed run: an already-closed sibling verdict is left alone (idempotent, no redundant close) ──"
VB_MIXED='[{"id":"vb-open-1","status":"open","assignee":null,"labels":["gate-run:gr-mix","type:quality-gate-verdict","verdict:pending"]},{"id":"vb-closed-1","status":"closed","assignee":"gate-reviewer-adhoc-1","labels":["gate-run:gr-mix","type:quality-gate-verdict","verdict:PASS"]}]'
BD_LOG="$(mktemp)"
run_cascade_close "$GUARD" "gr-mix" "stale duplicate — a newer running gate-run supersedes it, ga-o57gn dedup" "$VB_MIXED" "$BD_LOG" >/dev/null 2>&1
grep -q "close vb-open-1" "$BD_LOG" \
  && ok "vb-open-1 (still open) was closed" \
  || bad "vb-open-1 was NOT closed — bd_log: $(tr '\n' ';' < "$BD_LOG")"
if grep -q "close vb-closed-1" "$BD_LOG"; then
  bad "vb-closed-1 (already closed) was redundantly re-closed"
else
  ok "vb-closed-1 (already closed) was left alone — no redundant close call"
fi
rm -f "$BD_LOG"

echo "── 4. edge cases: empty gr_id and zero-verdict runs make no bd mutation calls ──"
BD_LOG="$(mktemp)"
run_cascade_close "$GUARD" "" "irrelevant" '[]' "$BD_LOG" >/dev/null 2>&1
if [ -s "$BD_LOG" ]; then
  bad "empty gr_id still produced bd calls — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "empty gr_id -> no bd calls at all (defensive early-return)"
fi
rm -f "$BD_LOG"

BD_LOG="$(mktemp)"
run_cascade_close "$GUARD" "gr-empty" "irrelevant" '[]' "$BD_LOG" >/dev/null 2>&1
if [ -s "$BD_LOG" ]; then
  bad "zero-verdict run still produced bd calls — bd_log: $(tr '\n' ';' < "$BD_LOG")"
else
  ok "run with 0 verdict beads -> no bd calls (nothing to close)"
fi
rm -f "$BD_LOG"

echo "── 5. WIRING: the cascade call reaches exactly the 3 intended branches, no others ──"
CALL_COUNT=$(grep -c 'close_pending_verdicts_for_run "' "$GUARD")
[ "$CALL_COUNT" = "3" ] \
  && ok "close_pending_verdicts_for_run is called exactly 3 times (supersede:duplicate, supersede:marker, abort:age)" \
  || bad "expected exactly 3 call sites, found $CALL_COUNT"

DUP_BLOCK=$(sed -n '/if \[ "\$DEDUP_ACTION" = "supersede:duplicate" \]; then/,/^    fi$/p' "$GUARD")
case "$DUP_BLOCK" in
  *'close_pending_verdicts_for_run "'*) ok "supersede:duplicate branch calls the cascade" ;;
  *) bad "supersede:duplicate branch does NOT call the cascade" ;;
esac

MARKER_BLOCK=$(sed -n '/^      supersede:marker)$/,/^        ;;$/p' "$GUARD")
case "$MARKER_BLOCK" in
  *'close_pending_verdicts_for_run "'*) ok "supersede:marker branch calls the cascade" ;;
  *) bad "supersede:marker branch does NOT call the cascade" ;;
esac

ABORT_BLOCK=$(sed -n '/^      abort:age)$/,/^        ;;$/p' "$GUARD")
case "$ABORT_BLOCK" in
  *'close_pending_verdicts_for_run "'*) ok "abort:age branch calls the cascade" ;;
  *) bad "abort:age branch does NOT call the cascade" ;;
esac

echo "── 6. REGRESSION: no skip) branch anywhere in the file calls the cascade (an open/live run/verdict is never touched) ──"
SKIP_BLOCKS=$(sed -n '/^      skip)$/,/^        ;;$/p' "$GUARD")
case "$SKIP_BLOCKS" in
  *'close_pending_verdicts_for_run'*) bad "a skip) branch calls the cascade — an in-flight run/verdict could be closed" ;;
  *) ok "no skip) branch (Vector A, Vector B, Step 0b.1, Step 0b.2) calls the cascade" ;;
esac

echo "── 7. REGRESSION: the pre-existing supersede:dead-reviewers cascade (ga-g4m18) is untouched ──"
DEAD_REVIEWERS_BLOCK=$(sed -n '/^      supersede:dead-reviewers)$/,/^        ;;$/p' "$GUARD")
case "$DEAD_REVIEWERS_BLOCK" in
  *'close_dead_reviewer_verdicts "$GR_ID"'*) ok "supersede:dead-reviewers still calls close_dead_reviewer_verdicts (ga-g4m18, unmodified)" ;;
  *) bad "supersede:dead-reviewers no longer calls close_dead_reviewer_verdicts — regression" ;;
esac
PRE_FIX_DEAD_REVIEWERS_FN=$(git -C "$SELF_DIR" show main:.gascity-gastown-hq/packs/town-deltas/assets/quality-gate-guard.sh 2>/dev/null \
  | sed -n '/^close_dead_reviewer_verdicts() {$/,/^}$/p')
CUR_DEAD_REVIEWERS_FN=$(sed -n '/^close_dead_reviewer_verdicts() {$/,/^}$/p' "$GUARD")
if [ -n "$PRE_FIX_DEAD_REVIEWERS_FN" ] && [ "$PRE_FIX_DEAD_REVIEWERS_FN" = "$CUR_DEAD_REVIEWERS_FN" ]; then
  ok "close_dead_reviewer_verdicts() body is byte-for-byte unchanged vs main (ga-g4m18 untouched)"
else
  bad "close_dead_reviewer_verdicts() body differs from main — should be untouched by this fix"
fi

echo "── 8. REGRESSION: Step 0b.1/0b.2 decision functions (ga-u07fn/ga-qtc16) are untouched ──"
for fn in reconcile_dead_reviewer_verdict_action reconcile_orphaned_verdict_action; do
  PRE=$(git -C "$SELF_DIR" show main:.gascity-gastown-hq/packs/town-deltas/assets/quality-gate-guard.sh 2>/dev/null \
    | sed -n "/^${fn}() {\$/,/^}\$/p")
  CUR=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$GUARD")
  if [ -n "$PRE" ] && [ "$PRE" = "$CUR" ]; then
    ok "$fn() body unchanged vs main"
  else
    bad "$fn() body differs from main — should be untouched by this fix"
  fi
done

echo "── 9. NON-VACUOUSNESS: the wiring assertions actually distinguish pre-fix HEAD from the fix ──"
# ga-hgsqg self-audit: `git show ... || true` on a FAILED read (bad ref, not a
# git repo, detached this file from history) leaves grep reading EMPTY stdin,
# which prints "0" and exits 1 — caught by the same `|| true` and therefore
# indistinguishable from "read real content, genuinely found zero matches".
# Both collapse to PRE_FIX_COUNT=0, and a false "0" would report this
# non-vacuousness proof as PASSING when it never actually read anything —
# exactly the error-vs-empty defect class this whole self-audit step exists
# to catch. Capture git's own exit code before anything can discard it.
if PRE_FIX_CONTENT=$(git -C "$SELF_DIR" show main:.gascity-gastown-hq/packs/town-deltas/assets/quality-gate-guard.sh 2>/dev/null) \
    && [ -n "$PRE_FIX_CONTENT" ]; then
  PRE_FIX_COUNT=$(printf '%s\n' "$PRE_FIX_CONTENT" | grep -c 'close_pending_verdicts_for_run' || true)
  if [ "$PRE_FIX_COUNT" = "0" ]; then
    ok "pre-fix HEAD (main) has ZERO occurrences of close_pending_verdicts_for_run — proves assertion #5 (count=3) would have FAILED there, not vacuous"
  else
    bad "pre-fix HEAD already contains close_pending_verdicts_for_run ($PRE_FIX_COUNT×) — wiring test would not discriminate, INVESTIGATE (branch may be stale vs main)"
  fi
else
  bad "could not read main:.../quality-gate-guard.sh via git show — cannot verify non-vacuousness (this is a query failure, NOT confirmed-zero; treat as FAIL rather than silently passing)"
fi

echo ""
echo "== gate-verdict-terminal-run-cascade-close: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
