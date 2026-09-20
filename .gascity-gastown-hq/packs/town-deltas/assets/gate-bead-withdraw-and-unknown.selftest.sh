#!/usr/bin/env bash
# gate-bead-withdraw-and-unknown.selftest.sh — Prove the ga-360a7l fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-360a7l): there was no reliable way to stop the merge of an
#   already-reviewed PASS once its owner discovered it should not ship.
#   ga-nkqook: gate:needs-human:technical landed on the source bead at
#   07:05:13; the merge went out anyway at 07:06:19. Two holes:
#   (a) gate_bead_live_merge_block() returned "ok" (release) whenever `bd
#   show` failed or came back empty — error and "no park-worthy label"
#   collapsed to the same value, so a live-read hiccup during merge silently
#   granted permission to push; (b) the ONE live re-check ran once, well
#   before do_merge_ff()'s rebase/push sequence, which itself can take
#   minutes (container-rig worktree dance, retries) — nothing re-checked
#   again right before origin/main actually moved. There was also no
#   explicit "withdraw" label a human could apply that this machinery would
#   honor — next-action:* and pilot:no-auto-dispatch look like they should
#   hold a merge but neither is examined by check_source_bead_park() at all.
#
#   FIX:
#     1. gate_bead_live_merge_block() now returns "unknown" (never "ok") when
#        `bd show` fails, comes back empty, or its JSON doesn't parse. "ok"
#        means "read live, no park-worthy signal"; "unknown" means "could not
#        read live, no opinion" — callers must never treat unknown as
#        permission to merge.
#     2. check_source_bead_park() recognizes gate:withdraw / gate:withdraw:*
#        as an unconditional park (same tier as story:needs-approval) —
#        reused by guard.sh Step 5a, the dispatcher's early Step 10 check, AND
#        the new late check below, so all three can never drift on what
#        counts as withdrawn.
#     3. do_merge_ff() now runs a SECOND, authoritative live re-check
#        immediately before the actual push (after the rebase and the
#        ga-pfgnv branch-content-coherence check), on every retry attempt.
#        "unknown" there is retryable (folds into the existing ga-3b8 retry
#        loop); closed/park:* is not (nothing about retrying a git push
#        un-withdraws a bead).
#     4. Every branch of both live re-checks logs unconditionally (block or
#        release) with the labels seen and a timestamp — the pre-fix release
#        path was silent, which is why the ga-nkqook race was undebuggable.
#
# This harness sources the dispatcher in lib-only mode to unit-test the REAL
# pure decision (check_source_bead_park) and the REAL bd-backed resolver
# (gate_bead_live_merge_block, driven by an in-shell bd mock), then DRIFT-
# GUARDS the live scripts so a future refactor can't silently drop the late
# re-check, put failed_bead_unknown back on the non-retryable list, or lose
# the gate:withdraw wiring. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
hasF()  { if grep -qF "$2" "$1"; then ok "$3"; else bad "$3 — literal not found: $2"; fi; }
lacksF() { if grep -qF "$2" "$1"; then bad "$3 — literal UNEXPECTEDLY found: $2"; else ok "$3"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for fn in check_source_bead_park gate_bead_live_merge_block; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by dispatcher (lib-only)"; exit 1; }
done

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. check_source_bead_park — gate:withdraw (pure) ──────────────────────────
echo "── 1. check_source_bead_park: gate:withdraw (pure) ──"
eq "bare gate:withdraw alone → park:withdraw" \
  "$(check_source_bead_park "gate:withdraw")" "park:withdraw"
eq "gate:withdraw:technical (sub-reason) → park:withdraw" \
  "$(check_source_bead_park "gate:withdraw:technical")" "park:withdraw"
eq "gate:withdraw mixed with other labels → park:withdraw" \
  "$(check_source_bead_park "area:infra gate:withdraw ctx:ready")" "park:withdraw"
eq "gate:withdraw takes priority alongside gate:needs-human (either alone parks; confirms no silent override)" \
  "$(check_source_bead_park "gate:needs-human gate:withdraw")" "park:withdraw"

# ga-nkqook's actual incident shape: next-action:mayor + pilot:no-auto-dispatch
# were BOTH on the bead and neither stopped the merge. Prove that shape still
# reads "ok" — the doc fix documents this as WORKING AS DESIGNED (these were
# never meant to park); the actual fix is that gate:withdraw now exists as
# the label that DOES.
eq "next-action:mayor + pilot:no-auto-dispatch ALONE → ok (documented: neither parks; use gate:withdraw)" \
  "$(check_source_bead_park "next-action:mayor pilot:no-auto-dispatch")" "ok"

# ── 2. gate_bead_live_merge_block — bd-backed resolver (mock bd) ─────────────
echo "── 2. gate_bead_live_merge_block: withdraw + unknown (bd-backed, mock bd) ──"
MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=0
bd() {
  case " $* " in
    *" show "*)
      [ "$MOCK_SHOW_FAIL" = "1" ] && return 1
      printf '%s\n' "$MOCK_SHOW_JSON"
      ;;
    *) : ;;
  esac
  return 0
}

# ga-360a7l: the label/status side-channel (GATE_LXZ5W_LIVE_*) only survives
# a BARE call (no `$(...)` — that forks a subshell and loses any variable
# the function sets, no matter how). Assert both calling conventions here:
# bare (what the two real call sites now use, for the side-channel) and
# `$(...)` (what every pre-existing caller/selftest uses, for the bare
# result token) — a regression in either convention would be a real bug.
MOCK_SHOW_JSON='[{"id":"ga-x","status":"open","labels":["gate:withdraw"]}]'
gate_bead_live_merge_block city 'ga-x' >/dev/null
eq "bare call: open bead carrying gate:withdraw → GATE_LXZ5W_LIVE_RESULT=park:withdraw" \
  "$GATE_LXZ5W_LIVE_RESULT" "park:withdraw"
eq "  ...and GATE_LXZ5W_LIVE_LABELS captured the label seen" \
  "$GATE_LXZ5W_LIVE_LABELS" "gate:withdraw"
eq "  ...and GATE_LXZ5W_LIVE_STATUS captured the status seen" \
  "$GATE_LXZ5W_LIVE_STATUS" "open"

# THIS IS THE ga-360a7l REGRESSION TEST (AC4, scenario a: withdrawal label
# applied during finalization), via the OTHER calling convention ($(...),
# still the bare-token contract every pre-existing caller relies on). MUST
# FAIL on pre-fix HEAD — pre-fix, check_source_bead_park had no gate:withdraw
# case at all, so this returned "ok", not "park:withdraw".
eq "ga-360a7l AC4(a): withdrawal label during finalization → NOT ok, blocks as park:withdraw" \
  "$(gate_bead_live_merge_block city 'ga-x')" "park:withdraw"

MOCK_SHOW_JSON=''
MOCK_SHOW_FAIL=1
# THIS IS THE ga-360a7l REGRESSION TEST (AC4, scenario b: bd show fails at
# the live reread). MUST FAIL on pre-fix HEAD — pre-fix this returned "ok"
# (fail-open), which is the exact silent-release bug ga-nkqook exposed.
eq "ga-360a7l AC4(b): bd show fails at live reread → NOT ok (unknown), merge must not proceed" \
  "$(gate_bead_live_merge_block city 'ga-x')" "unknown"
gate_bead_live_merge_block city 'ga-x' >/dev/null
eq "  ...bare call agrees: GATE_LXZ5W_LIVE_RESULT=unknown" \
  "$GATE_LXZ5W_LIVE_RESULT" "unknown"
eq "  ...and GATE_LXZ5W_LIVE_LABELS is reset (nothing was read)" \
  "$GATE_LXZ5W_LIVE_LABELS" ""
MOCK_SHOW_FAIL=0

# bd show "succeeds" (exit 0) but the payload is truly empty — same
# error-vs-empty family as a hard failure, must also read unknown.
MOCK_SHOW_JSON=''
eq "bd show exits 0 with empty payload → unknown (not ok)" \
  "$(gate_bead_live_merge_block city 'ga-x')" "unknown"

# bd show returns something that isn't parseable JSON (garbled payload) —
# the jq-parse-failure sibling of the bd-show-failure case; same principle.
MOCK_SHOW_JSON='not valid json {{{'
eq "bd show returns unparseable payload → unknown (not ok)" \
  "$(gate_bead_live_merge_block city 'ga-x')" "unknown"

# ga-360a7l follow-up: raw parses fine and `.status` extracts cleanly (open,
# not closed), but `.labels` is present with a non-array shape — `join(" ")`
# errors on it. This is the narrower sibling of AC4(b): the SAME function's
# labels-extraction line originally kept the file's old `|| echo ""` idiom
# (unlike the raw/status reads a few lines above it, already guarded), so a
# labels-shape error alone — with a perfectly good status read — used to
# fall through to labels="" and check_source_bead_park("") => "ok". Mirrors
# gate_marker_label_snapshot()'s existing guard for this identical jq
# expression (gate-fix-3) — this function should never have been the odd
# one out. MUST FAIL without that guard.
MOCK_SHOW_JSON='[{"id":"ga-x","status":"open","labels":"not-an-array"}]'
eq "bd show ok + status ok, but labels field is malformed (non-array) → unknown, not ok" \
  "$(gate_bead_live_merge_block city 'ga-x')" "unknown"
gate_bead_live_merge_block city 'ga-x' >/dev/null
eq "  ...bare call agrees: GATE_LXZ5W_LIVE_RESULT=unknown" \
  "$GATE_LXZ5W_LIVE_RESULT" "unknown"
eq "  ...GATE_LXZ5W_LIVE_STATUS still reflects the status read that DID succeed (open)" \
  "$GATE_LXZ5W_LIVE_STATUS" "open"
eq "  ...and GATE_LXZ5W_LIVE_LABELS was never populated (the failing line never assigned it)" \
  "$GATE_LXZ5W_LIVE_LABELS" ""

# Unaffected regression guard: empty bead_id is still legitimately "ok" —
# there is no bead to fail to read.
eq "empty bead_id → ok (unaffected; never calls bd)" \
  "$(gate_bead_live_merge_block city '')" "ok"

# ── 3. DRIFT GUARD: the late (pre-push) re-check is wired into do_merge_ff ───
echo "── 3. drift guard: late live re-check exists, wired between rebase-check and push ──"
CALL_LINES=$(grep -n 'gate_bead_live_merge_block "$BEAD_CITY" "$BEAD_ID"' "$DISPATCHER" | cut -d: -f1)
CALL_COUNT=$(printf '%s\n' "$CALL_LINES" | grep -c . || true)
if [ "$CALL_COUNT" -eq 2 ]; then
  ok "gate_bead_live_merge_block \$BEAD_CITY/\$BEAD_ID called exactly twice (early Step 10 + late pre-push)"
else
  bad "expected gate_bead_live_merge_block(\$BEAD_CITY,\$BEAD_ID) called exactly twice, found $CALL_COUNT"
fi
# ga-360a7l: both real call sites MUST call this bare (redirected to
# /dev/null), never via `$(...)` — a subshell capture would silently lose
# GATE_LXZ5W_LIVE_STATUS/LABELS (see the function's own header comment; this
# exact mistake was caught live while writing this fix).
lacksF "$DISPATCHER" 'GATE_LXZ5W_BLOCK="$(gate_bead_live_merge_block' \
  "early call site does not re-introduce the subshell-capturing form"
lacksF "$DISPATCHER" 'GATE_360A7L_LATE="$(gate_bead_live_merge_block' \
  "late call site does not re-introduce the subshell-capturing form"
BARE_CALLS=$(grep -cF 'gate_bead_live_merge_block "$BEAD_CITY" "$BEAD_ID" >/dev/null' "$DISPATCHER" || true)
if [ "$BARE_CALLS" -eq 2 ]; then
  ok "both call sites invoke gate_bead_live_merge_block bare, redirected to /dev/null (found $BARE_CALLS)"
else
  bad "expected exactly 2 bare >/dev/null calls to gate_bead_live_merge_block, found $BARE_CALLS"
fi

EARLY_LN=$(printf '%s\n' "$CALL_LINES" | sed -n '1p')
LATE_LN=$(printf '%s\n' "$CALL_LINES" | sed -n '2p')
PFGNV_LN=$(grep -n 'FF push refused (ga-pfgnv)' "$DISPATCHER" | head -1 | cut -d: -f1)
PUSH_LN=$(grep -nF 'git_rig push origin "${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH"' "$DISPATCHER" | head -1 | cut -d: -f1)

if [ -n "$EARLY_LN" ] && [ -n "$PFGNV_LN" ] && [ "$EARLY_LN" -lt "$PFGNV_LN" ]; then
  ok "early live re-check (line $EARLY_LN) precedes the ga-pfgnv branch-content-coherence check (line $PFGNV_LN)"
else
  bad "expected early live re-check before ga-pfgnv check (early=$EARLY_LN pfgnv=$PFGNV_LN)"
fi
if [ -n "$PFGNV_LN" ] && [ -n "$LATE_LN" ] && [ "$PFGNV_LN" -lt "$LATE_LN" ]; then
  ok "ga-pfgnv branch-content-coherence check (line $PFGNV_LN) precedes the late live re-check (line $LATE_LN)"
else
  bad "expected ga-pfgnv check before late live re-check (pfgnv=$PFGNV_LN late=$LATE_LN)"
fi
if [ -n "$LATE_LN" ] && [ -n "$PUSH_LN" ] && [ "$LATE_LN" -lt "$PUSH_LN" ]; then
  ok "late live re-check (line $LATE_LN) precedes the actual FF push (line $PUSH_LN)"
else
  bad "expected late live re-check to precede the actual FF push (late=$LATE_LN push=$PUSH_LN)"
fi

# ── 4. DRIFT GUARD: retry classification — blocked=non-retryable, unknown=retryable ─
echo "── 4. drift guard: failed_bead_blocked_late non-retryable, failed_bead_unknown retryable ──"
RETRY_BLOCK_START=$(grep -n 'Only retry on push-race or stale-after-rebase' "$DISPATCHER" | head -1 | cut -d: -f1)
RETRY_BLOCK_END=$(grep -n 'Non-retryable failure' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$RETRY_BLOCK_START" ] && [ -n "$RETRY_BLOCK_END" ]; then
  RETRY_BLOCK_TEXT=$(sed -n "${RETRY_BLOCK_START},${RETRY_BLOCK_END}p" "$DISPATCHER")
  if printf '%s' "$RETRY_BLOCK_TEXT" | grep -F 'failed_bead_blocked_late' >/dev/null; then
    ok "failed_bead_blocked_late is in the non-retryable break-list"
  else
    bad "failed_bead_blocked_late NOT found in the non-retryable break-list — a withdrawn/closed bead would be retried pointlessly"
  fi
  # Match the actual comparison syntax, not a bare substring — this file's
  # own explanatory comments legitimately NAME failed_bead_unknown in prose
  # right next to this block (to say why it's excluded), and a bare-substring
  # check can't tell that apart from a real `[ "$MERGE_RESULT" = "..." ]`
  # condition. Caught live while writing this test.
  if printf '%s' "$RETRY_BLOCK_TEXT" | grep -F '"$MERGE_RESULT" = "failed_bead_unknown"' >/dev/null; then
    bad "failed_bead_unknown UNEXPECTEDLY found as a real condition in the non-retryable break-list — this must stay retryable (a transient read failure should get the existing ga-3b8 retries, not an immediate hold)"
  else
    ok "failed_bead_unknown correctly absent as a condition from the non-retryable break-list (stays retryable; prose mentions of the name are fine)"
  fi
else
  bad "could not locate the retry-classification block (markers moved?) start=$RETRY_BLOCK_START end=$RETRY_BLOCK_END"
fi
hasF "$DISPATCHER" 'MERGE_RESULT="failed_bead_unknown"' \
  "failed_bead_unknown is actually assigned as a MERGE_RESULT (reachable)"
hasF "$DISPATCHER" 'MERGE_RESULT="failed_bead_blocked_late"' \
  "failed_bead_blocked_late is actually assigned as a MERGE_RESULT (reachable)"
hasF "$DISPATCHER" 'failed_bead_blocked_late" ] || [ "$MERGE_RESULT" = "failed_bead_unknown"' \
  "post-loop FAIL_REASONS composition special-cases both new MERGE_RESULT values"

# ── 5. DRIFT GUARD: gate:withdraw wired into guard.sh's Step 5a messaging too ─
echo "── 5. drift guard: gate:withdraw reaches guard.sh Step 5a (pre-review park) ──"
hasF "$GUARD" 'gate:withdraw|gate:withdraw:*) echo "park:withdraw"; return ;;' \
  "check_source_bead_park (guard.sh) recognizes gate:withdraw/gate:withdraw:*"
hasF "$GUARD" 'park:withdraw)' \
  "guard.sh Step 5a has at least one park:withdraw case arm"
WITHDRAW_ARMS=$(grep -cF 'park:withdraw)' "$GUARD" || true)
if [ "$WITHDRAW_ARMS" -ge 2 ]; then
  ok "guard.sh Step 5a has park:withdraw arms in BOTH PARK_REASON and UNBLOCK_HINT (found $WITHDRAW_ARMS)"
else
  bad "expected >=2 park:withdraw) arms in guard.sh (PARK_REASON + UNBLOCK_HINT), found $WITHDRAW_ARMS"
fi

# ── 6. DRIFT GUARD: every branch of both live re-checks logs (AC3) ───────────
echo "── 6. drift guard: release path (not just block) logs at both call sites (AC3) ──"
hasF "$DISPATCHER" 'no park/withdraw/closed signal, proceeding toward merge' \
  "early live re-check logs on release, not just on block"
hasF "$DISPATCHER" 'no park/withdraw/closed signal, proceeding to push' \
  "late live re-check logs on release, not just on block"

# ── 7. syntax ──────────────────────────────────────────────────────────────
echo "── 7. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi
if bash -n "$GUARD"; then ok "guard passes bash -n"; else bad "guard bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
