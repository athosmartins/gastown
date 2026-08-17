#!/usr/bin/env bash
# gate-sibling-hygiene.selftest.sh — Prove the ga-divv8 fix in isolation,
# with NO live Dolt/gc/launchd:
#
#   BUG (ga-divv8, live incident wa-4hzpd): two builders (crew/wa-worker and
#   crew/batista) independently branched the SAME bead and both ran
#   /gate-done. crew/wa-worker's branch FAILED review (gate-sha-failed:<sha>
#   :code + gate:fix-attempt:1 stamped on the bead). crew/batista's branch —
#   already containing the same fix — PASSED minutes later and merged. The
#   existing ga-lxz5w sibling check only looks at ACTIVE siblings, so by the
#   time batista's PASS reached its own pre-merge check, wa-worker's FAILED
#   marker was already terminal and invisible to it. Net result: the bead
#   ended up carrying gate:passed AND gate:fix-attempt:1 simultaneously —
#   automation reading the fix-attempt residue re-routed the (already
#   correctly merged) bead for a THIRD implementation attempt.
#
#   FIX: gate_finalize_pass_label_hygiene(), called from all 3 PASS-path
#   label sites (mirroring the existing ga-tuk26 gate:failed/gate:needs-fix
#   clear): (1) removes any gate:fix-attempt:* label — it is only ever
#   ADDED on FAIL, so leaving it after a PASS is always stale; (2) if a
#   DIFFERENT branch for the same bead reached the terminal gate-status:
#   failed (gate_bead_terminal_failed_sibling_branch — a new sibling-shaped
#   check reusing gate_bead_active_sibling_branch's extracted marker-walk,
#   gate_bead_sibling_status_lines), posts an explanatory comment. It does
#   NOT touch the sibling's gate-sha-failed:<sha>:code stamp (ga-nooaw's
#   permanent-rejection-per-SHA invariant is untouched by design) and does
#   NOT block the merge (unlike ga-lxz5w's still-ACTIVE-sibling case: a
#   terminal FAILED sibling is not ambiguous — the gate itself already
#   adjudicated it, so preferring the currently-passing branch is safe).
#
# This harness SOURCES the dispatcher in lib-only mode to unit-test the REAL
# pure decision (gate_pick_terminal_failed_sibling) and the REAL bd-backed
# resolvers (gate_bead_terminal_failed_sibling_branch,
# gate_finalize_pass_label_hygiene, driven by an in-shell bd mock), then
# DRIFT-GUARDS the live script so a future refactor can't drop or reorder
# the fix silently. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ──────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for fn in gate_pick_terminal_failed_sibling gate_bead_sibling_status_lines \
          gate_bead_active_sibling_branch gate_bead_terminal_failed_sibling_branch \
          gate_finalize_pass_label_hygiene; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by dispatcher (lib-only) — this fires on pre-fix code, proving the test is load-bearing"; exit 1; }
done

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_pick_terminal_failed_sibling — pure multi-line triage ───────────
echo "── 1. gate_pick_terminal_failed_sibling (pure) ──"
eq "empty input → no sibling" \
  "$(gate_pick_terminal_failed_sibling "" "crew/me/x")" ""
eq "only same-branch rows, one failed → no sibling (own history, not a competitor)" \
  "$(gate_pick_terminal_failed_sibling "$(printf 'crew/me/x\tfailed\ncrew/me/x\tpassed')" "crew/me/x")" ""
eq "other branch but ACTIVE (not failed) → no sibling (that's gate_pick_active_sibling's job)" \
  "$(gate_pick_terminal_failed_sibling "$(printf 'crew/them/x\tqueued')" "crew/me/x")" ""
eq "other branch, PASSED (not failed) → no sibling" \
  "$(gate_pick_terminal_failed_sibling "$(printf 'crew/them/x\tpassed')" "crew/me/x")" ""
eq "other branch, terminal FAILED → sibling found (the ga-divv8 signature)" \
  "$(gate_pick_terminal_failed_sibling "$(printf 'crew/them/x\tfailed')" "crew/me/x")" \
  "$(printf 'crew/them/x\tfailed')"
eq "mixed rows: skips own+active+passed, finds the one terminal-failed sibling" \
  "$(gate_pick_terminal_failed_sibling "$(printf 'crew/me/x\tfailed\ncrew/them/x\tpassed\ncrew/other/x\tfailed')" "crew/me/x")" \
  "$(printf 'crew/other/x\tfailed')"

# ── 2. gate_bead_terminal_failed_sibling_branch — bd-backed (mock bd list) ──
echo "── 2. gate_bead_terminal_failed_sibling_branch (bd list, mock bd) ──"
MOCK_LIST_JSON='[]'
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

eq "(a) empty bead_id → '' (never calls bd)" \
  "$(gate_bead_terminal_failed_sibling_branch city '' 'crew/batista/wa-4hzpd')" ""

# wa-4hzpd shape: wa-worker's marker already FAILED; batista's own marker
# (same branch as $this_branch) must never be read back as its own sibling.
MOCK_LIST_JSON='[
  {"id":"m-wa-worker","status":"open","labels":["gate-status:failed","source-bead:wa-4hzpd","branch:crew/wa-worker/wa-4hzpd"],"description":""},
  {"id":"m-batista","status":"open","labels":["gate-status:queued","source-bead:wa-4hzpd","branch:crew/batista/wa-4hzpd"],"description":""}
]'
eq "(b) wa-4hzpd shape: terminal-failed sibling on a DIFFERENT branch is found" \
  "$(gate_bead_terminal_failed_sibling_branch city 'wa-4hzpd' 'crew/batista/wa-4hzpd')" \
  "$(printf 'crew/wa-worker/wa-4hzpd\tfailed')"

# Same-branch resubmission history (fix-attempt 1 failed, fix-attempt 2 is
# THIS run, same branch name) must never flag itself.
MOCK_LIST_JSON='[{"id":"m1","status":"open","labels":["gate-status:failed","source-bead:wa-9999","branch:crew/solo/wa-9999"],"description":""}]'
eq "(c) same-branch earlier FAIL (normal fix-and-resubmit) → '' (not a sibling of itself)" \
  "$(gate_bead_terminal_failed_sibling_branch city 'wa-9999' 'crew/solo/wa-9999')" ""

MOCK_LIST_JSON='[]'
eq "(d) no markers at all → ''" \
  "$(gate_bead_terminal_failed_sibling_branch city 'wa-4hzpd' 'crew/batista/wa-4hzpd')" ""

# ── 3. gate_finalize_pass_label_hygiene — bd-backed (mock bd show/label/comment) ──
echo "── 3. gate_finalize_pass_label_hygiene (bd show + label remove + comment, mock bd) ──"
CALL_LOG=""
MOCK_SHOW_JSON='[]'
MOCK_LIST_JSON='[]'
bd() {
  CALL_LOG="${CALL_LOG}$*
"
  case " $* " in
    *" show "*) printf '%s\n' "$MOCK_SHOW_JSON" ;;
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

# (a) The exact wa-4hzpd live label shape: gate:passed already added by the
# caller (this function runs AFTER that add — see the 3 call sites), plus
# the stale residue this fix targets.
CALL_LOG=""
MOCK_SHOW_JSON='[{"id":"wa-4hzpd","status":"open","labels":["gate-sha-failed:9c63d1f78d21ef90a7bbf4bed189e3d616579728:code","gate:fix-attempt:1","gate:passed","gate:queued"]}]'
MOCK_LIST_JSON='[{"id":"m-wa-worker","status":"open","labels":["gate-status:failed","source-bead:wa-4hzpd","branch:crew/wa-worker/wa-4hzpd"],"description":""}]'
gate_finalize_pass_label_hygiene "bead-city" "wa-4hzpd" "crew/batista/wa-4hzpd"

if printf '%s' "$CALL_LOG" | grep -q 'label remove wa-4hzpd gate:fix-attempt:1'; then
  ok "clears gate:fix-attempt:1 residue on PASS"
else
  bad "did NOT clear gate:fix-attempt:1 — CALL_LOG:
$CALL_LOG"
fi

if printf '%s' "$CALL_LOG" | grep -q 'label remove wa-4hzpd gate-sha-failed:9c63d1f78d21ef90a7bbf4bed189e3d616579728:code'; then
  bad "must NOT touch gate-sha-failed:*:code — that stamp is ga-nooaw's permanent-rejection invariant for the FAILED branch's own SHA, unrelated to this bead-level cleanup"
else
  ok "leaves gate-sha-failed:*:code untouched (ga-nooaw invariant preserved)"
fi

if printf '%s' "$CALL_LOG" | grep -q 'comment wa-4hzpd'; then
  ok "posts a comment when a terminal-failed sibling branch is found"
else
  bad "did NOT comment on the terminal-failed-sibling case — CALL_LOG:
$CALL_LOG"
fi

# (b) No fix-attempt label present (bead never failed) → no label remove call
# for it, and no sibling → no comment. Must be a true no-op, not an error.
CALL_LOG=""
MOCK_SHOW_JSON='[{"id":"wa-clean","status":"open","labels":["gate:passed","gate:queued"]}]'
MOCK_LIST_JSON='[]'
gate_finalize_pass_label_hygiene "bead-city" "wa-clean" "crew/solo/wa-clean"
if printf '%s' "$CALL_LOG" | grep -q 'label remove'; then
  bad "clean bead (no fix-attempt label, no sibling) triggered an unexpected label remove — CALL_LOG:
$CALL_LOG"
else
  ok "clean bead (no residue, no sibling) → no label remove calls (true no-op)"
fi
if printf '%s' "$CALL_LOG" | grep -q 'comment'; then
  bad "clean bead triggered an unexpected comment — CALL_LOG:
$CALL_LOG"
else
  ok "clean bead → no comment posted"
fi

# (c) empty bead_id → immediate no-op, never calls bd at all.
CALL_LOG=""
gate_finalize_pass_label_hygiene "bead-city" "" "crew/solo/x"
eq "empty bead_id → no bd calls at all" "$CALL_LOG" ""

# ── 4. DRIFT GUARD: new helpers are selftest-sourceable (defined before lib-only cutoff) ──
echo "── 4. drift guard: new helpers defined before the lib-only cutoff ──"
CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
for fn in gate_bead_terminal_failed_sibling_branch gate_finalize_pass_label_hygiene; do
  DEF_LN=$(grep -n "^${fn}() {" "$DISPATCHER" | head -1 | cut -d: -f1)
  if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
    ok "$fn (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
  else
    bad "$fn must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
  fi
done

# ga-0m6tgc: gate_bead_sibling_status_lines moved OUT of the dispatcher into
# quality-gate-guard.sh (so story-delivery.sh can reach it too, via its own
# existing GATE_GUARD_LIB_ONLY source) — check it against GUARD's own cutoff,
# not the dispatcher's. type() above already proved it is transitively
# reachable through the dispatcher's lib-only source of guard.sh; this
# proves the more specific claim (right file, right side of ITS cutoff).
GUARD_CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_GUARD_LIB_ONLY:-}" \]; then' "$GUARD" | head -1 | cut -d: -f1)
GUARD_DEF_LN=$(grep -n '^gate_bead_sibling_status_lines() {' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$GUARD_DEF_LN" ] && [ -n "$GUARD_CUTOFF_LN" ] && [ "$GUARD_DEF_LN" -lt "$GUARD_CUTOFF_LN" ]; then
  ok "gate_bead_sibling_status_lines (guard.sh line $GUARD_DEF_LN) defined before guard's lib-only cutoff (line $GUARD_CUTOFF_LN)"
else
  bad "gate_bead_sibling_status_lines must be defined in quality-gate-guard.sh before its GATE_GUARD_LIB_ONLY cutoff (def=$GUARD_DEF_LN cutoff=$GUARD_CUTOFF_LN)"
fi
if grep -q '^gate_bead_sibling_status_lines() {' "$DISPATCHER" 2>/dev/null; then
  bad "gate_bead_sibling_status_lines should no longer be (re-)defined directly in quality-gate-dispatcher.sh — it would silently shadow guard.sh's copy (ga-0m6tgc: exactly the drift this move exists to prevent)"
else
  ok "gate_bead_sibling_status_lines has no shadowing re-definition in quality-gate-dispatcher.sh"
fi

# ── 5. DRIFT GUARD: all 3 PASS-path sites call the new hygiene function ─────
echo "── 5. drift guard: all 3 known PASS-path label sites call gate_finalize_pass_label_hygiene ──"
CALL_COUNT=$(grep -c 'gate_finalize_pass_label_hygiene "\$BEAD_CITY"' "$DISPATCHER" || true)
eq "gate_finalize_pass_label_hygiene is called from exactly 3 sites (the 3 known PASS-label sites, ga-tuk26 siblings)" \
  "$CALL_COUNT" "3"

# Each call site must appear AFTER its own gate:needs-fix removal on the
# same bead — i.e. hygiene runs once the PASS labels are already settled,
# never before.
NEEDS_FIX_LNS=$(grep -n 'label remove "\$BEAD_ID" "gate:needs-fix"' "$DISPATCHER" | cut -d: -f1)
HYGIENE_LNS=$(grep -n 'gate_finalize_pass_label_hygiene "\$BEAD_CITY"' "$DISPATCHER" | cut -d: -f1)
ALL_AFTER="yes"
for h in $HYGIENE_LNS; do
  nearest_before=""
  for n in $NEEDS_FIX_LNS; do
    if [ "$n" -lt "$h" ]; then nearest_before="$n"; fi
  done
  if [ -z "$nearest_before" ] || [ $((h - nearest_before)) -gt 5 ]; then
    ALL_AFTER="no"
  fi
done
eq "every hygiene call sits immediately after its site's gate:needs-fix removal" "$ALL_AFTER" "yes"

# ── 6. syntax ────────────────────────────────────────────────────────────
echo "── 6. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
