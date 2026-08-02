#!/usr/bin/env bash
# gate-marker-status-selfheal.selftest.sh — ga-kgtiw mutation test.
#
# BUG (ga-kgtiw, found by batista-wa, amplified by the Mayor): every exit
# point in the dispatcher's rebase-fail path (Step 4c) removes gate-status:
# dispatching up front, then adds exactly one new terminal/requeue gate-status
# via a SEPARATE, unverified `bd label add ... || true` call. A silently-
# failed add (transient Dolt hiccup) leaves the marker with ZERO gate-status
# labels. That is not "parked" — every phase of this dispatcher selects its
# work via `bd ... -l gate-status:<value>`, so a marker with no such label
# matches no query, ever again. It vanishes permanently, no log, no alert.
# Measured live: 3/3 markers carrying gate:rebase-fail-count:1 had no
# gate-status label at all; one sat invisible for 3 days with 14 commits
# behind it. This is the SAME failure class ga-6dp9 already fixed for the
# gate:rebase-fail-count counter (gate_rebase_attempt_advanced) — falsify the
# write instead of assuming it — but that fix never covered the status label
# itself ([[error-and-empty-must-not-produce-the-same-value]]).
#
# FIX (two independent layers, per the bug's own CONSERTO):
#   (1) gate_marker_status_ensure(): called immediately before every exit
#       point in the rebase-fail path. Re-reads the marker's labels live and,
#       if truly empty, force-writes gate-status:error (safe, retriable) plus
#       a comment and a Mayor alert. The marker can never exit the script
#       invisible again.
#   (2) gate_bead_active_sibling_branch(): the one place in the dispatcher
#       that already walks every marker for a bead regardless of gate-status.
#       Its `[ -z "$status" ] && continue` used to skip an orphaned sibling in
#       total silence; it now emits an ALERT line to stderr first — a safety
#       net independent of fix (1), catching any marker that reaches this
#       broken state through a path this dispatcher version didn't anticipate.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test gate_labels_have_status (pure) and gate_marker_status_ensure
# (bd/gc-backed, driven by in-shell mocks — NO live Dolt/gc/launchd), then
# extends the existing gate-sibling-branch-guard mock-bd harness to prove the
# stderr alert. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for fn in gate_labels_have_status gate_marker_status_ensure gate_bead_active_sibling_branch; do
  type "$fn" >/dev/null 2>&1 \
    || { echo "FATAL: $fn not defined by dispatcher (ga-kgtiw fix missing?)"; exit 1; }
done

# Quiet logging noise from sourced helpers (matches every other selftest in
# this suite) — assertions below use the mock call counters, not log text.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_labels_have_status — pure predicate ───────────────────────────────
echo "── 1. gate_labels_have_status (pure) ──"
eq "empty labels → 0" \
  "$(gate_labels_have_status "")" "0"
eq "only unrelated labels → 0" \
  "$(gate_labels_have_status "type:quality-gate-marker source-bead:wa-x branch:crew/me/wa-x")" "0"
eq "gate-status present among others → 1" \
  "$(gate_labels_have_status "type:quality-gate-marker gate-status:queued source-bead:wa-x")" "1"
eq "gate-status alone → 1" \
  "$(gate_labels_have_status "gate-status:error")" "1"
eq "near-miss (not anchored, e.g. a rig label containing the substring) → 0" \
  "$(gate_labels_have_status "area:not-gate-status:foo")" "0"
eq "gate-status with empty value still counts as present → 1" \
  "$(gate_labels_have_status "gate-status:")" "1"

# ── 2. gate_marker_status_ensure — bd/gc-backed self-heal (mock bd + gc) ──────
echo "── 2. gate_marker_status_ensure (bd show/label/comment + gc mail, mock bd+gc) ──"
MOCK_SHOW_JSON='[]'
MOCK_LABEL_ADD_COUNT=0
MOCK_LABEL_ADD_LAST=""
MOCK_COMMENT_COUNT=0
MOCK_MAIL_COUNT=0
MOCK_MAIL_LAST=""

bd() {
  case " $* " in
    *" show "*)
      printf '%s\n' "$MOCK_SHOW_JSON"
      ;;
    *" label add "*)
      MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1))
      MOCK_LABEL_ADD_LAST="$*"
      ;;
    *" comment "*)
      MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1))
      ;;
    *) : ;;
  esac
  return 0
}
gc() {
  case " $* " in
    *" mail send "*)
      MOCK_MAIL_COUNT=$((MOCK_MAIL_COUNT + 1))
      MOCK_MAIL_LAST="$*"
      ;;
    *) : ;;
  esac
  return 0
}

# (a) empty marker_id → no-op, never touches bd/gc.
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
gate_marker_status_ensure '' 'test context' && _RC=0 || _RC=$?
eq "(a) empty marker_id → return 0" "$_RC" "0"
eq "(a) empty marker_id → bd label add never called" "$MOCK_LABEL_ADD_COUNT" "0"
eq "(a) empty marker_id → gc mail send never called" "$MOCK_MAIL_COUNT" "0"

# (b) marker already carries a gate-status → fast path, no repair, no mail.
MOCK_SHOW_JSON='[{"id":"m1","labels":["gate-status:queued","source-bead:wa-x"]}]'
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
gate_marker_status_ensure 'm1' 'test context' && _RC=0 || _RC=$?
eq "(b) status present → return 0 (healthy, no repair)" "$_RC" "0"
eq "(b) status present → bd label add NOT called" "$MOCK_LABEL_ADD_COUNT" "0"
eq "(b) status present → bd comment NOT called" "$MOCK_COMMENT_COUNT" "0"
eq "(b) status present → gc mail send NOT called (no spam on the healthy path)" "$MOCK_MAIL_COUNT" "0"

# (c) THE BUG: marker has labels but NO gate-status → self-heal fires.
MOCK_SHOW_JSON='[{"id":"m2","labels":["source-bead:wa-x","branch:crew/me/wa-x"]}]'
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
gate_marker_status_ensure 'm2' 'the transient-retry queue write' && _RC=0 || _RC=$?
eq "(c) status missing → return 1 (repair happened, caller can tell)" "$_RC" "1"
eq "(c) status missing → bd label add called exactly once" "$MOCK_LABEL_ADD_COUNT" "1"
case "$MOCK_LABEL_ADD_LAST" in
  *"m2"*"gate-status:error"*) ok "(c) repair wrote gate-status:error onto the right marker" ;;
  *) bad "(c) expected label add m2 gate-status:error, got: $MOCK_LABEL_ADD_LAST" ;;
esac
eq "(c) status missing → bd comment called exactly once (durable trail on the marker)" "$MOCK_COMMENT_COUNT" "1"
eq "(c) status missing → gc mail send called exactly once (Mayor alerted)" "$MOCK_MAIL_COUNT" "1"
case "$MOCK_MAIL_LAST" in
  *"mayor"*"m2"*) ok "(c) mail addressed to mayor, names the marker" ;;
  *) bad "(c) expected mail to mayor naming m2, got: $MOCK_MAIL_LAST" ;;
esac

# (d) marker JSON returned as a bare object (not array) — same shape gate_bead_live_merge_block tolerates.
MOCK_SHOW_JSON='{"id":"m3","labels":["gate-status:running"]}'
MOCK_LABEL_ADD_COUNT=0; MOCK_MAIL_COUNT=0
gate_marker_status_ensure 'm3' 'test context' && _RC=0 || _RC=$?
eq "(d) bare-object show JSON, status present → return 0, no repair" "$_RC" "0"
eq "(d) bare-object show JSON, status present → no label add" "$MOCK_LABEL_ADD_COUNT" "0"

# (e) bd show fails entirely (transient) → labels read as empty → treated as
# missing → self-heals rather than trusting an unreadable marker as "fine".
# This is the deliberately conservative side of the fail path: an unverifiable
# marker gets the same safe gate-status:error treatment as a proven-empty one.
MOCK_SHOW_JSON=''
bd() {
  case " $* " in
    *" show "*) return 1 ;;
    *" label add "*) MOCK_LABEL_ADD_COUNT=$((MOCK_LABEL_ADD_COUNT + 1)) ;;
    *" comment "*) MOCK_COMMENT_COUNT=$((MOCK_COMMENT_COUNT + 1)) ;;
    *) : ;;
  esac
  return 0
}
MOCK_LABEL_ADD_COUNT=0; MOCK_COMMENT_COUNT=0; MOCK_MAIL_COUNT=0
gate_marker_status_ensure 'm4' 'test context' && _RC=0 || _RC=$?
eq "(e) bd show fails → return 1 (repaired defensively)" "$_RC" "1"
eq "(e) bd show fails → still force-writes gate-status:error" "$MOCK_LABEL_ADD_COUNT" "1"

# ── 3. gate_bead_active_sibling_branch — orphaned sibling now ALERTS, never silently vanishes ──
echo "── 3. gate_bead_active_sibling_branch: no-status sibling logs to stderr, genuine sibling still found ──"
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

STDERR_FILE=$(mktemp)
cleanup_stderr_file() { rm -f "$STDERR_FILE"; }
trap cleanup_stderr_file EXIT

# (a) ONLY a broken (no gate-status) sibling present.
MOCK_LIST_JSON='[{"id":"m-orphan","status":"open","labels":["source-bead:wa-kgtiw-test","branch:crew/ghost/wa-kgtiw-test"],"description":""}]'
: > "$STDERR_FILE"
RESULT=$(gate_bead_active_sibling_branch city 'wa-kgtiw-test' 'crew/me/wa-kgtiw-test' 2>"$STDERR_FILE")
eq "(a) only an orphaned no-status sibling → '' (unchanged external contract)" "$RESULT" ""
if grep -q "ALERT" "$STDERR_FILE" && grep -q "m-orphan" "$STDERR_FILE" && grep -q "gate-status" "$STDERR_FILE"; then
  ok "(a) orphaned sibling produced a stderr ALERT naming the marker (ga-kgtiw safety net fired)"
else
  bad "(a) expected a stderr ALERT naming m-orphan and gate-status, got: $(cat "$STDERR_FILE")"
fi

# (b) a broken sibling AND a genuine active sibling together — the orphan must
# not swallow or short-circuit detection of the real one.
MOCK_LIST_JSON='[{"id":"m-orphan","status":"open","labels":["source-bead:wa-kgtiw-test","branch:crew/ghost/wa-kgtiw-test"],"description":""},{"id":"m-real","status":"open","labels":["gate-status:running","source-bead:wa-kgtiw-test","branch:crew/oracle/wa-kgtiw-test"],"description":""}]'
: > "$STDERR_FILE"
RESULT=$(gate_bead_active_sibling_branch city 'wa-kgtiw-test' 'crew/me/wa-kgtiw-test' 2>"$STDERR_FILE")
eq "(b) orphan + genuine sibling → genuine one still found" "$RESULT" "$(printf 'crew/oracle/wa-kgtiw-test\trunning')"
if grep -q "m-orphan" "$STDERR_FILE"; then
  ok "(b) orphan still alerted even though a real sibling was also present"
else
  bad "(b) expected an alert mentioning m-orphan, got: $(cat "$STDERR_FILE")"
fi

# (c) no orphan at all → no stderr output (no false alarms on the healthy path).
MOCK_LIST_JSON='[{"id":"m-real","status":"open","labels":["gate-status:running","source-bead:wa-kgtiw-test","branch:crew/oracle/wa-kgtiw-test"],"description":""}]'
: > "$STDERR_FILE"
RESULT=$(gate_bead_active_sibling_branch city 'wa-kgtiw-test' 'crew/me/wa-kgtiw-test' 2>"$STDERR_FILE")
eq "(c) healthy sibling only → still found" "$RESULT" "$(printf 'crew/oracle/wa-kgtiw-test\trunning')"
if [ -s "$STDERR_FILE" ]; then
  bad "(c) expected NO stderr output on the healthy path, got: $(cat "$STDERR_FILE")"
else
  ok "(c) no false-alarm stderr output when every sibling has a status"
fi

cleanup_stderr_file
trap - EXIT

# ── 4. Drift guard: gate_marker_status_ensure wired at every rebase-fail exit ─
echo "── 4. drift guard: self-heal called before every rebase-fail exit point ──"
CALL_COUNT=$(grep -c 'gate_marker_status_ensure "\$MARKER_ID"' "$DISPATCHER")
eq "gate_marker_status_ensure called exactly 6 times (one per rebase-fail exit point)" "$CALL_COUNT" "6"

for context in \
  "the main-ref-unresolvable guard" \
  "the merge-tree-undeterminable guard" \
  "the ahead_dead circuit-break" \
  "the behind_dead circuit-break" \
  "the behind-envelope bounce" \
  "the auto-rebase decision \(merge-conflict/transient-retry/circuit-break\)"; do
  has "$DISPATCHER" "gate_marker_status_ensure \"\\\$MARKER_ID\" \"${context}\"" \
    "self-heal wired at: ${context}"
done

CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
for fn in gate_labels_have_status gate_marker_status_ensure; do
  DEF_LN=$(grep -n "^${fn}() {" "$DISPATCHER" | head -1 | cut -d: -f1)
  if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
    ok "$fn (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
  else
    bad "$fn must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
  fi
done

# ── 5. syntax ──────────────────────────────────────────────────────────────
echo "── 5. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
