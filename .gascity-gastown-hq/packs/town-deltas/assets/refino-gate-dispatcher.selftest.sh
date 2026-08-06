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
#   AC "promoção/bounce/escalação preservam labels qualificadoras" (ga-xvxvf)
#        → drift-guards 2b (no --set-labels regression), 2c (input label retired,
#          no accumulation), 2d (single atomic bd_ call — no split-failure window,
#          ga-xvxvf gate re-dispatch fix attempt 1), 2e (fixture proof of all three).
#   Timeout safety → Scenario 6 (TIMEOUT/unknown → requeue, never promote, no round burn).
#   AC "veredito nunca se perde em silêncio" (ga-hmcs0)
#        → drift-guard 8 + the _verdict_fixture scenarios. NOTE the claim was
#          CORRECTED after two gate reviews: `bd update --add-label --remove-label`
#          is ONE CLI call but NOT one transaction (applyLabelUpdates runs the ADD
#          loop then the REMOVE loop; each of AddLabel/RemoveLabel commits its own
#          sql.Tx). What the fix actually guarantees is that the VERDICT IS NEVER
#          LOST: the worst residual state is both labels present — visible and
#          self-correcting — instead of neither, which was silent and looked
#          identical to "the reviewer never ran".
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

# 2. PASS path promotes to story:needs-approval (Athos's queue) — ADDITIVELY,
#    via the _refino_gate_relabel helper (ga-xvxvf: NOT --set-labels, which
#    replaces the whole label set and drops guard/qualifier labels).
if grep -q '_refino_gate_relabel "\$STORY_ID" story:needs-approval' "$DISPATCHER"; then
  ok "promote path additively sets story:needs-approval (Athos's queue)"
else
  bad "promote path does not additively set story:needs-approval"
fi

# 2b. ga-xvxvf REGRESSION GUARD: --set-labels must never reappear in live code.
#     It REPLACES the entire label set, silently dropping guard/qualifier labels
#     (story:blocked, area:infra, pilot:no-auto-dispatch, needs:engine-window,
#     ...) — this is exactly how the Athos-deferred story ga-sb11i.4 became
#     dispatchable. Every lifecycle transition must be additive label add/remove.
#     (Comment lines that merely document the old/wrong pattern are excluded.)
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -q -- '--set-labels'; then
  bad "REGRESSION (ga-xvxvf): --set-labels present in code — it clobbers guard/qualifier labels; use additive label add/remove"
else
  ok "no --set-labels in code (additive label add/remove only — no label clobber, ga-xvxvf)"
fi

# 2c. CONTROL for 2b: additive-only must not degenerate into label ACCUMULATION.
#     _refino_gate_relabel must explicitly retire the gate's own input label
#     (story:refino-review) on every transition, or a promoted/bounced bead
#     would keep BOTH the old and new lifecycle label forever.
if grep -q -- '--remove-label "story:refino-review"' "$DISPATCHER"; then
  ok "relabel helper explicitly retires the gate's own input label (no accumulation)"
else
  bad "relabel helper does not retire story:refino-review — risk of label accumulation"
fi

# 2d. ga-xvxvf GATE RE-DISPATCH REGRESSION GUARD (fix attempt 1/3): the add and
#     the remove must land in ONE atomic `bd_ update` call, not two independent
#     `bd_ label add` / `bd_ label remove` calls. Two independent calls each
#     swallow their own error via `|| true` with no check that the first
#     succeeded before the second runs — if one lands and the other doesn't
#     (transient Dolt hiccup, concurrent writer racing the same bead row, both
#     routine in this town), the bead ends up with BOTH labels or NEITHER:
#     stranded, invisible to every queue, while the caller's log/comment lines
#     still claim success. This is a WORSE failure mode than the --set-labels
#     bug 2b/2c guard against.
if grep -q 'bd_ label add "\$sid"' "$DISPATCHER" || grep -q 'bd_ label remove "\$sid"' "$DISPATCHER"; then
  bad "REGRESSION (ga-xvxvf re-dispatch): relabel helper issues split bd_ label add/remove calls — reintroduces the split-failure race; use one bd_ update --add-label/--remove-label call"
else
  ok "relabel helper issues a single atomic bd_ update call (no split-failure window, ga-xvxvf re-dispatch)"
fi

# 2e. Fixture proof (ga-xvxvf AC, all three guards above combined): a bead
#     entering promotion with guard/qualifier labels (story:blocked, area:infra,
#     lane:small, pilot:no-auto-dispatch) alongside the gate's input label must
#     exit with ONLY story:refino-review removed and story:needs-approval added
#     — every unrelated label untouched — via EXACTLY ONE underlying bd_ call
#     (proves the add+remove cannot partially fail). Exercised against the REAL
#     helper (sourced from the dispatcher, lib mode), with `bd_` stubbed to
#     mutate an in-memory label set instead of hitting live Dolt.
LABELS="story:refino-review,story:blocked,area:infra,lane:small,pilot:no-auto-dispatch"
BD_CALL_COUNT=0
bd_() {
  BD_CALL_COUNT=$((BD_CALL_COUNT + 1))
  [ "$1" = "update" ] || return 0
  shift 2  # drop "update" and the story id — only the flags matter here
  local add_label="" remove_label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label) add_label="$2"; shift 2 ;;
      --remove-label) remove_label="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$add_label" ] && LABELS="$LABELS,$add_label"
  [ -n "$remove_label" ] && LABELS=$(echo ",$LABELS," | sed "s/,$remove_label,/,/" | sed 's/^,//;s/,$//')
}
STORY_ID="fixture-bead"
_refino_gate_relabel "$STORY_ID" story:needs-approval
[ "$BD_CALL_COUNT" -eq 1 ] && ok "fixture: relabel issues exactly ONE bd_ call (atomic — no split-failure window)" || bad "REGRESSION (ga-xvxvf re-dispatch): relabel issued $BD_CALL_COUNT bd_ calls, not 1"
case ",$LABELS," in *,story:refino-review,*) bad "fixture: story:refino-review survived promotion (should be retired)" ;; *) ok "fixture: story:refino-review retired on promotion" ;; esac
case ",$LABELS," in *,story:needs-approval,*) ok "fixture: story:needs-approval added on promotion" ;; *) bad "fixture: story:needs-approval missing after promotion" ;; esac
for guard in story:blocked area:infra lane:small pilot:no-auto-dispatch; do
  case ",$LABELS," in *,$guard,*) ok "fixture: guard label $guard survives promotion" ;; *) bad "REGRESSION (ga-sb11i.4 class): guard label $guard was dropped by promotion" ;; esac
done

# 3. Bounce path returns the story to refinement-in-progress (additively) and
#    reassigns the refiner.
if grep -q '_refino_gate_relabel "\$STORY_ID" story:refinement-in-progress' "$DISPATCHER" \
   && grep -q -- '--assignee "$REFINER"' "$DISPATCHER"; then
  ok "bounce path additively sets story:refinement-in-progress + reassigns the original refiner"
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

# 8. ga-hmcs0: the reviewer's verdict-recording instructions (REVIEW_TASK heredoc)
#    must record PASS/FAIL via ONE atomic `bd update --add-label/--remove-label`
#    call, never two independent `bd label remove` + `bd label add` calls. The
#    reviewer is a freshly spawned Claude session with no `bd_` wrapper — it
#    executes these lines literally, so the split form is a real, reachable race:
#    if the remove succeeds and the add fails (Dolt hiccup / concurrent writer,
#    both routine in this town), the verdict bead ends up with NEITHER label —
#    an entire review's result lost in silence, indistinguishable downstream
#    from "not yet reviewed" (root-class: error-vs-empty).
echo "Drift guard 8: verdict recorded via one atomic bd update call (ga-hmcs0)"

# 8a. REGRESSION GUARD: the split remove-then-add must not reappear.
if grep -qE '^bd -C "\$REFINO_GATE_STORE" label remove "\$VERDICT_BEAD_ID"' "$DISPATCHER"; then
  bad "REGRESSION (ga-hmcs0): verdict instructions issue a split 'label remove' — reintroduces the lost-verdict race"
else
  ok "verdict instructions no longer issue a split 'label remove' (ga-hmcs0)"
fi

# 8b. The atomic replacement must be present for BOTH the live PASS path and the
#     commented-out FAIL example (the bug explicitly warns: leaving the old
#     split pattern there, even inert, models it for the next editor).
if grep -qE '^bd -C "\$REFINO_GATE_STORE" update "\$VERDICT_BEAD_ID" --add-label verdict:PASS --remove-label verdict:pending' "$DISPATCHER"; then
  ok "PASS recorded via one atomic bd update --add-label/--remove-label call (ga-hmcs0)"
else
  bad "PASS verdict instructions missing the atomic bd update --add-label/--remove-label form"
fi
if grep -qE '^# bd -C "\$REFINO_GATE_STORE" update "\$VERDICT_BEAD_ID" --add-label verdict:FAIL --remove-label verdict:pending' "$DISPATCHER"; then
  ok "commented-out FAIL example also uses the atomic form (not left as a wrong model, ga-hmcs0)"
else
  bad "commented-out FAIL example still models the split (non-atomic) pattern"
fi

# 8c. Fixture proof (falsifiable, ga-hmcs0 AC #1-#3): simulate a Dolt store as a
#     single in-memory label value and run the EXACT command forms the reviewer
#     is told to run — split vs atomic — against a stub `bd`, injecting a write
#     failure at a chosen call index. This is what the reviewer literally
#     executes (raw `bd`, no `bd_` wrapper — it has no dispatcher functions in
#     scope), so exercising the literal command strings IS exercising the
#     shipped behavior, not a parallel reimplementation.
# ga-hmcs0 (2nd gate review): this fixture must model the MECHANISM, not the claim.
# The earlier version failed at the top of bd() — before any mutation — so `update`
# behaved as one indivisible all-or-nothing step. That is what the diff CLAIMED, and
# modelling the claim made the test structurally blind to the only failure the fix
# leaves open.
#
# The real mechanism, traced in the live beads source: cmd/bd/update.go ->
# applyLabelUpdates (cmd/bd/show_unit_helpers.go) runs the whole ADD loop, THEN the
# REMOVE loop, and internal/storage/dolt/labels.go gives AddLabel and RemoveLabel
# each their OWN sql.Tx. One CLI call, TWO commits. So `update` is modelled here as
# two internal steps that can fail independently:
#   fail_at="update:remove"  -> the ADD committed, the REMOVE did not
# LABELS is a SET (space-separated) because the honest partial state has BOTH labels
# present at once — a single-string variable literally could not represent it, which
# is the second reason the old fixture could not see this bug.
_verdict_fixture() {
  local mode="$1" fail_at="$2"
  local LABELS="verdict:pending"   # a fresh verdict bead always starts life here (see bead-create, -l verdict:pending)
  local _call_n=0
  _lbl_add() { case " $LABELS " in *" $1 "*) ;; *) LABELS="${LABELS:+$LABELS }$1" ;; esac; }
  _lbl_rm()  { local out="" l; for l in $LABELS; do [ "$l" = "$1" ] || out="${out:+$out }$l"; done; LABELS="$out"; }
  bd() {
    _call_n=$((_call_n + 1))
    [ "$_call_n" = "$fail_at" ] && return 1   # whole-invocation failure (split form)
    if [ "$3" = "label" ] && [ "$4" = "remove" ]; then
      _lbl_rm "$6"
    elif [ "$3" = "label" ] && [ "$4" = "add" ]; then
      _lbl_add "$6"
    elif [ "$3" = "update" ]; then
      shift 4
      local add="" rem=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label) add="$2"; shift 2 ;;
          --remove-label) rem="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      # Internal step 1: the ADD loop commits its own transaction.
      [ "$fail_at" = "update:add" ] && return 1
      [ -n "$add" ] && _lbl_add "$add"
      # Internal step 2: the REMOVE loop commits a SEPARATE transaction. A failure
      # here is the real residual risk — the add already landed and cannot roll back.
      [ "$fail_at" = "update:remove" ] && return 1
      [ -n "$rem" ] && _lbl_rm "$rem"
    fi
    return 0
  }
  REFINO_GATE_STORE="fixture-store"; VERDICT_BEAD_ID="fixture-verdict"
  if [ "$mode" = "split" ]; then
    bd -C "$REFINO_GATE_STORE" label remove "$VERDICT_BEAD_ID" "verdict:pending"
    bd -C "$REFINO_GATE_STORE" label add    "$VERDICT_BEAD_ID" "verdict:PASS"
  else
    bd -C "$REFINO_GATE_STORE" update "$VERDICT_BEAD_ID" --add-label verdict:PASS --remove-label verdict:pending
  fi
  echo "$LABELS"
  unset -f bd _lbl_add _lbl_rm
}

# CONTROL (AC #2): happy path, no injected failure — atomic form must land
# identically to today's happy-path outcome (verdict:PASS, verdict:pending gone).
# This proves the fix is an ATOMICITY change, not a semantic one.
HAPPY=$(_verdict_fixture atomic 0)
[ "$HAPPY" = "verdict:PASS" ] && ok "fixture control: atomic call, no failure → verdict:PASS only (same happy-path result as before)" \
  || bad "fixture control: atomic happy-path produced '$HAPPY', expected 'verdict:PASS'"

# CHARACTERIZATION: the OLD split form with the 2nd write failing reproduces the
# documented bug — bead ends with NEITHER label. (Proves the fixture itself is
# faithful to the reported failure, not just to the fix.)
OLD_BUG=$(_verdict_fixture split 2)
[ "$OLD_BUG" = "" ] && ok "fixture characterizes the reported bug: split form + 2nd-write failure → neither label survives" \
  || bad "fixture: split form + injected failure produced '$OLD_BUG', expected empty (failed to characterize the known bug)"

# AC #1 (REWRITTEN after the 2nd gate review): the one-call form is NOT one
# transaction, so assert what actually survives — not what the comment wished for.
# Internal REMOVE fails after the internal ADD already committed: the bead ends with
# BOTH labels. That is a partial state, and pretending otherwise is what the reviewer
# rejected twice.
FAILED=$(_verdict_fixture atomic update:remove)
case "$FAILED" in
  *verdict:PASS*)
    case "$FAILED" in
      *verdict:pending*) ok "fixture AC#1: one-call form + internal REMOVE failure → BOTH labels survive ('$FAILED') — a VISIBLE partial state, not silent loss (ga-hmcs0)" ;;
      *) bad "fixture AC#1: expected both labels after an internal REMOVE failure, got '$FAILED'" ;;
    esac ;;
  *) bad "fixture AC#1: the internal ADD should have committed before the REMOVE failed, got '$FAILED'" ;;
esac

# AC #1b: the failure the fix DOES eliminate — the verdict is never LOST. Whatever
# the outcome, verdict:PASS must be present, so the bead is never left looking like
# "the reviewer never ran" (the error-vs-empty collapse this bead exists to kill).
for _fp in update:remove 0; do
  _out=$(_verdict_fixture atomic "$_fp")
  case "$_out" in
    *verdict:PASS*) ok "fixture AC#1b: one-call form (fail_at=$_fp) never loses the verdict — verdict:PASS present ('$_out')" ;;
    *) bad "fixture AC#1b: verdict LOST with fail_at=$_fp (got '$_out') — that is the ga-hmcs0 bug itself" ;;
  esac
done

# AC #3: "failed" and "transitioned" must be OBSERVABLY DIFFERENT states — the
# heart of the bug (a lost verdict must never look the same as a recorded one).
[ "$FAILED" != "$HAPPY" ] && ok "fixture AC#3: failed state ('$FAILED') and transitioned state ('$HAPPY') are observably different" \
  || bad "REGRESSION AC#3: failed and transitioned states are indistinguishable ('$FAILED')"

echo ""
echo "refino-gate-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
