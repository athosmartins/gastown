#!/usr/bin/env bash
# refino-gate-dispatcher.selftest.sh — Regression harness for the Refino gate
# (ga-gpr2v). Proves the PURE decision core in isolation (no live Dolt/gc/Claude),
# then DRIFT-GUARDS the live wiring so a future refactor cannot silently break the
# acceptance criteria.
#
# It SOURCES the dispatcher in lib-only mode (REFINO_GATE_LIB=1) to unit-test the
# REAL functions the shipped dispatcher calls — refino_gate_decision,
# refino_next_round, refino_resolve_refiner — so the tested logic IS the shipped
# logic (no parallel reimplementation).
#
# Acceptance criteria proven:
#   AC "aprovada → story:needs-approval"      → Scenario 1 (promote) + drift-guard 2.
#   AC "reprovada → devolve ao refinador"     → Scenario 2 (bounce) + drift-guard 3.
#   AC "revisor NUNCA aprova no lugar do Athos"
#        → Scenario 5 (PASS emits 'promote', NEVER 'approve') + drift-guard 1
#          (the dispatcher contains NO `story:approved` write anywhere).
#   AC "bounce-back com limite de rodadas → escala (sem loop infinito)"
#        → Scenario 3 (escalate at the ceiling) + Scenario 4 (round counter).
#   AC "pill 'em revisão' enquanto revisa"
#        → drift-guard 4 (claim adds refino-gate:reviewing, keeps story:refino-review).
#   Timeout safety → Scenario 6 (TIMEOUT/unknown → requeue, never promote, no round burn).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/refino-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

echo "refino-gate-dispatcher.selftest — pure decision core + drift guards (ga-gpr2v)"

# ── Source the dispatcher in lib-only mode (pure functions only, no side effects)
# REFINO_GATE_LIB=1 makes the script `return` before any bd/gc call.
REFINO_GATE_LIB=1 . "$DISPATCHER"

# Confirm the pure functions are now in scope.
if declare -F refino_gate_decision >/dev/null 2>&1; then
  ok "sourced lib-only: refino_gate_decision is defined"
else
  bad "lib-only source did not expose refino_gate_decision"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── Scenario 1: PASS → promote (to needs-approval, NEVER approved) ────────────
echo "Scenario 1: PASS → promote"
D=$(refino_gate_decision "PASS" 1 3)
[ "$D" = "promote" ] && ok "PASS round 1/3 → promote" || bad "PASS → expected promote, got '$D'"
D=$(refino_gate_decision "PASS" 3 3)   # even at the ceiling, PASS still promotes
[ "$D" = "promote" ] && ok "PASS at the round ceiling still → promote" || bad "PASS at ceiling → expected promote, got '$D'"

# ── Scenario 2: FAIL within budget → bounce ───────────────────────────────────
echo "Scenario 2: FAIL within the round budget → bounce"
D=$(refino_gate_decision "FAIL" 1 3)
[ "$D" = "bounce" ] && ok "FAIL round 1/3 → bounce" || bad "FAIL round 1 → expected bounce, got '$D'"
D=$(refino_gate_decision "FAIL" 2 3)
[ "$D" = "bounce" ] && ok "FAIL round 2/3 → bounce" || bad "FAIL round 2 → expected bounce, got '$D'"

# ── Scenario 3: FAIL at/over the budget → escalate (no infinite loop) ─────────
echo "Scenario 3: FAIL once the round budget is spent → escalate"
D=$(refino_gate_decision "FAIL" 3 3)
[ "$D" = "escalate" ] && ok "FAIL round 3/3 (budget spent) → escalate" || bad "FAIL round 3 → expected escalate, got '$D'"
D=$(refino_gate_decision "FAIL" 4 3)
[ "$D" = "escalate" ] && ok "FAIL beyond budget → escalate (never bounces again)" || bad "FAIL round 4 → expected escalate, got '$D'"

# ── Scenario 4: round counter increments correctly + sanitizes garbage ────────
echo "Scenario 4: refino_next_round increments and sanitizes"
[ "$(refino_next_round 0)" = "1" ] && ok "0 → 1" || bad "0 → expected 1"
[ "$(refino_next_round 2)" = "3" ] && ok "2 → 3" || bad "2 → expected 3"
[ "$(refino_next_round '')" = "1" ] && ok "empty → 1 (sanitized)" || bad "empty → expected 1"
[ "$(refino_next_round 'xyz')" = "1" ] && ok "non-numeric → 1 (sanitized)" || bad "non-numeric → expected 1"

# Prove the round limit actually terminates the loop: simulate consecutive FAILs.
echo "Scenario 4b: a chain of FAILs escalates at the ceiling (terminates, no infinite loop)"
rounds=0; maxr=3; escalated=0; bounces=0
for _ in 1 2 3 4 5 6; do
  rounds=$(refino_next_round "$rounds")
  d=$(refino_gate_decision "FAIL" "$rounds" "$maxr")
  case "$d" in
    bounce) bounces=$((bounces+1)) ;;
    escalate) escalated=1; break ;;
  esac
done
if [ "$escalated" = "1" ] && [ "$bounces" -eq $((maxr-1)) ]; then
  ok "chain of FAILs: $bounces bounce(s) then escalate at round $maxr (loop terminates)"
else
  bad "round-limit loop did not terminate as expected (bounces=$bounces escalated=$escalated)"
fi

# ── Scenario 5: NEVER self-approve — the decision vocabulary excludes 'approve' ─
echo "Scenario 5: the decision core can NEVER emit 'approve' (AC: revisor nunca aprova)"
seen_approve=0
for v in PASS FAIL TIMEOUT GARBAGE ""; do
  for r in 0 1 2 3 4 5; do
    d=$(refino_gate_decision "$v" "$r" 3)
    case "$d" in approve|story:approved) seen_approve=1 ;; esac
    case "$d" in promote|bounce|escalate|requeue) : ;; *) bad "unexpected decision token '$d' for verdict=$v round=$r"; esac
  done
done
[ "$seen_approve" = "0" ] && ok "no input ever yields 'approve' (only promote/bounce/escalate/requeue)" || bad "REGRESSION: decision core emitted an approve token"

# ── Scenario 6: TIMEOUT / unknown verdict → requeue (never promote) ───────────
echo "Scenario 6: TIMEOUT / unknown → requeue (never promote, never approve)"
D=$(refino_gate_decision "TIMEOUT" 1 3)
[ "$D" = "requeue" ] && ok "TIMEOUT → requeue" || bad "TIMEOUT → expected requeue, got '$D'"
D=$(refino_gate_decision "" 2 3)
[ "$D" = "requeue" ] && ok "empty verdict → requeue" || bad "empty → expected requeue, got '$D'"
D=$(refino_gate_decision "weird" 1 3)
[ "$D" = "requeue" ] && ok "garbage verdict → requeue" || bad "garbage → expected requeue, got '$D'"

# ── Scenario 7: refiner resolution precedence ─────────────────────────────────
echo "Scenario 7: refino_resolve_refiner precedence (meta > assignee > created_by)"
[ "$(refino_resolve_refiner "digo-wa" "peter-wa" "mila-wa")" = "digo-wa" ] && ok "explicit meta wins" || bad "meta precedence wrong"
[ "$(refino_resolve_refiner "" "peter-wa" "mila-wa")" = "peter-wa" ] && ok "falls back to assignee" || bad "assignee fallback wrong"
[ "$(refino_resolve_refiner "" "" "mila-wa")" = "mila-wa" ] && ok "falls back to created_by" || bad "created_by fallback wrong"
[ "$(refino_resolve_refiner "" "" "")" = "" ] && ok "none known → empty (caller escalates)" || bad "expected empty when no refiner known"
[ "$(refino_resolve_refiner "null" "peter-wa" "")" = "peter-wa" ] && ok "literal 'null' meta is ignored" || bad "did not skip literal null meta"

# ── DRIFT GUARDS: static assertions on the shipped dispatcher ─────────────────
echo "Drift guards: live wiring matches the acceptance criteria"

# 1. The dispatcher NEVER writes story:approved (AC: revisor nunca aprova).
if grep -qE 'set-labels[[:space:]]+story:approved|label add[^\n]*story:approved' "$DISPATCHER"; then
  bad "REGRESSION: dispatcher writes story:approved — the gate must NEVER self-approve"
else
  ok "dispatcher never writes story:approved anywhere (AC: nunca aprova no lugar do Athos)"
fi

# 2. PASS path promotes to story:needs-approval (Athos's queue).
if grep -q 'set-labels story:needs-approval' "$DISPATCHER"; then
  ok "promote path sets story:needs-approval (Athos's queue)"
else
  bad "promote path does not set story:needs-approval"
fi

# 3. Bounce path returns the story to refinement-in-progress and reassigns the refiner.
if grep -q 'set-labels story:refinement-in-progress' "$DISPATCHER" \
   && grep -q -- '--assignee "$REFINER"' "$DISPATCHER"; then
  ok "bounce path sets story:refinement-in-progress + reassigns the original refiner"
else
  bad "bounce path missing refinement-in-progress transition or refiner reassignment"
fi

# 4. Claim KEEPS the gate-input label and ADDS the review pill key (ga-sefot
#    renders 'em revisão' off refino-gate:reviewing). It must NOT --set-labels
#    away story:refino-review at claim time (that would drop the pill key).
if grep -q 'label add "$STORY_ID" "refino-gate:reviewing"' "$DISPATCHER"; then
  ok "claim adds refino-gate:reviewing (pill 'em revisão' key, ga-sefot)"
else
  bad "claim does not add the refino-gate:reviewing pill key"
fi

# 5. Round limit + escalation are wired: escalate adds refino-gate:escalated and
#    notifies Athos/Mayor.
if grep -q 'refino-gate:escalated' "$DISPATCHER" && grep -q 'mail send mayor' "$DISPATCHER"; then
  ok "escalation path flags refino-gate:escalated + notifies Athos/Mayor"
else
  bad "escalation path missing refino-gate:escalated flag or Athos/Mayor notify"
fi

# 6. The reviewer is spawned on a Sonnet template (AC: revisor usa modelo Sonnet).
if grep -q 'session new "$REFINO_REVIEWER_TEMPLATE"' "$DISPATCHER"; then
  ok "reviewer spawned via gc session new on the refino reviewer template"
else
  bad "reviewer spawn does not use the refino reviewer template"
fi
if grep -q '^model = "sonnet"' "$SELF_DIR/../../../agents/refino-gate-reviewer/agent.toml" 2>/dev/null; then
  ok "refino-gate-reviewer template pins model = sonnet"
else
  bad "refino-gate-reviewer template does not pin model = sonnet"
fi

# 7. DRY_RUN must not transition labels or spawn (proof-mode safety). The
#    dispatcher logs to $GC_CITY/.gc/logs/…, not stdout, so assert on the log
#    file. With no live bd, the queue is empty → it exits 0 without spawning.
_drycity="$(mktemp -d)"
REFINO_CITY_OVERRIDE="$_drycity" DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_dryrc=$?
_drylog=$(cat "$_drycity/.gc/logs/refino-gate-dispatcher.log" 2>/dev/null || echo "")
if [ "$_dryrc" -eq 0 ] && echo "$_drylog" | grep -qiE 'Refino gate sweep start.*dry_run=1'; then
  ok "DRY_RUN executes the sweep harness cleanly (exit 0, proof mode, no spawn)"
else
  bad "DRY_RUN did not run cleanly in proof mode (rc=$_dryrc)"
fi
rm -rf "$_drycity"

echo ""
echo "refino-gate-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
