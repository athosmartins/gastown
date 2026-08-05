#!/usr/bin/env bash
# auto-refino-dispatcher.selftest.sh — Regression harness for the Auto-refino
# daemon (ga-flxp6). Proves the PURE decision core in isolation (no live
# Dolt/gc/Claude), then DRIFT-GUARDS the live wiring so a future refactor cannot
# silently break the acceptance criteria.
#
# It SOURCES the dispatcher in lib-only mode (AUTO_REFINO_LIB=1) to unit-test the
# REAL functions the shipped dispatcher calls — auto_refino_type_eligible,
# auto_refino_lifecycle_state, auto_refino_handoff_decision,
# auto_refino_next_attempt — so the tested logic IS the shipped logic.
#
# Acceptance criteria proven (ga-flxp6):
#   AC "só processa feature/story; ignora bug/chore/task"
#        → Scenario 1 (type eligibility) + drift-guard 5.
#   AC "história em Triagem (sem refino) é candidata"
#        → Scenario 2 (lifecycle: fresh) + Scenario 2b (bounce-back).
#   AC "refina → manda pro gate ga-gpr2v com pill 'em revisão' (NÃO needs-approval)"
#        → Scenario 3 (REFINED → handoff) + drift-guard 1 (writes story:refino-review)
#          + drift-guard 2 (writes story.refino_refiner) + drift-guard 3
#          (dispatcher NEVER writes story:needs-approval or story:approved).
#   AC "incerto → anota perguntas/lacunas e escala (NÃO promove)"
#        → Scenario 4 (ESCALATE → escalate) + drift-guard 4 (escalate records
#          gaps + flags auto-refino:escalated + notifies, never promotes).
#   AC "nenhuma história é auto-aprovada nem despachada pelo daemon"
#        → Scenario 6 (decision vocabulary excludes approve/dispatch) + drift-guard 3.
#   AC "reusa o simplificado do /refino"
#        → drift-guard 6 (story.refino_mode=simplificado + the skip sentinel on F3/F4/F5).
#   Loop safety (daemon↔gate ping-pong) → Scenario 5 (attempt cap → escalate).
#   Timeout safety → Scenario 7 (TIMEOUT/unknown → requeue, never promote, no attempt burn).
#   Drained-refiner safety (ga-bvbm: stale_async_start race orphans the spawned
#   refiner before it ever consumes the task, task bead sits assignee=None for
#   the full 25m timeout) → Scenario 10 (auto_refino_session_drained detector +
#   SPAWN_DRAINED → requeue) + spawn-drained wiring drift-guards.
#   Confidence-gate split (imp16: thin/duplicate/trivial input can't be paged to
#   Athos) → Scenario 4a (ESCALATE:info-gap → escalate-info-gap, not in queue).
#   Escalation visibility (ga-lfua3: escalations were rendering in TRIAGEM instead
#   of the painel "Sua vez" human queue, and an escalated-only bead looked RAW and
#   re-ingested forever) → Scenario 11 + drift-guard 4b (story:refino-escalado
#   added in both escalate paths, survives _clear_lifecycle, RAW source excludes it).
#   Policy-gap dispatch gap (ga-xdukc/ga-hd87d: an escalated bead reached Pilot
#   with refino:policy-gap + story:refino-escalado but NEITHER story:needs-human
#   NOR gate:needs-human:* — Pilot dispatched it with "No human review required")
#   → drift-guard 4c (the deterministic escalate case stamps story:needs-human,
#   the label pilot-dispatcher.sh _filter_candidates already excludes on exactly;
#   survives _clear_lifecycle the same way story:refino-escalado does).
#   Multi-store funnel (WA/PS rig-store stories were starving in Triagem because
#   the daemon only read/wrote HQ) → Scenario 12 (AUTO_REFINO_STORES iteration +
#   per-store write-back to $AR_BEAD_STORE).
#   Refiner-cap protection (FIX C: launchd's 5m interval << the 25m refiner
#   timeout, so concurrent sweeps could blow past max_active_sessions) →
#   Scenario 13 (single-instance mkdir-mutex lock: backs off / reclaims stale /
#   kill-switch).
#   Cross-stage anti-starvation (FIX B: refino is the lowest stage and must yield
#   to a congested gate/Pilot under contention, but never serialize when resources
#   are free) → Scenario 14 (yield gate + fail-open + kill-switch).
#   Hold-label guard (bug ga-268cr: RAW sweep re-ingested a story already governed
#   by another authority — blocked:*, needs-human*, pilot:held*, blocked-on:*, and
#   pool:refused:* were all unchecked by either layer) → Scenario 15 (classifier +
#   RAW jq filter, defense in depth + drift-guard 15b).
#   Outcome vocabulary gap (bug ga-9mfnw: an already-resolved policy-gap escalation,
#   executed by the refiner as an epic split, had no terminal outcome of its own —
#   REFINED would revert the --type epic conversion, ESCALATE would re-page Mayor
#   for a decision already made) → Scenario 19 (SPLIT → split, terminal, no attempt
#   cap) + drift-guards 19b (poll loop wiring) / 19c (Step 7 branch's two
#   invariants: no --type flip, no Mayor mail) / 19d (heredoc teaches the refiner
#   to report SPLIT deliberately instead of inventing an unrecognized label).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/auto-refino-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

echo "auto-refino-dispatcher.selftest — pure decision core + drift guards (ga-flxp6)"

# ── Source the dispatcher in lib-only mode (pure functions only, no side effects)
AUTO_REFINO_LIB=1 . "$DISPATCHER"

if declare -F auto_refino_handoff_decision >/dev/null 2>&1; then
  ok "sourced lib-only: auto_refino_handoff_decision is defined"
else
  bad "lib-only source did not expose auto_refino_handoff_decision"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

ACTOR="auto-refino"

# ── Scenario 1: ONLY feature/story enter the funnel ───────────────────────────
echo "Scenario 1: type eligibility — feature/story refine, bug/chore/task bypass"
[ "$(auto_refino_type_eligible feature)" = "yes" ] && ok "feature → yes" || bad "feature → expected yes"
[ "$(auto_refino_type_eligible story)" = "yes" ]   && ok "story → yes"   || bad "story → expected yes"
[ "$(auto_refino_type_eligible bug)" = "no" ]      && ok "bug → no (bypasses funnel)"   || bad "bug → expected no"
[ "$(auto_refino_type_eligible chore)" = "no" ]    && ok "chore → no (bypasses funnel)" || bad "chore → expected no"
[ "$(auto_refino_type_eligible task)" = "no" ]     && ok "task → no (bypasses funnel)"  || bad "task → expected no"
[ "$(auto_refino_type_eligible epic)" = "no" ]     && ok "epic → no" || bad "epic → expected no"

# ── Scenario 1b: build/scraper/config beads are NOT product stories (bug 3) ───
# dc-yla3 (labels custom,scraper) leaked into the funnel and was re-processed every
# sweep. Type-eligibility alone is not enough — a build bead can carry type=feature.
echo "Scenario 1b: product-story filter — build/scraper/config beads excluded (bug 3)"
EX="scraper build infra config deploy migration pipeline"
[ "$(auto_refino_is_product_story "custom,scraper" "$EX")" = "no" ]            && ok "custom,scraper (dc-yla3) → no (excluded)"            || bad "custom,scraper → expected no"
[ "$(auto_refino_is_product_story "story:unrefined,build" "$EX")" = "no" ]     && ok "build label (even with story:* lifecycle) → no"      || bad "build → expected no"
[ "$(auto_refino_is_product_story "config,deploy" "$EX")" = "no" ]            && ok "config,deploy → no"                                  || bad "config,deploy → expected no"
[ "$(auto_refino_is_product_story "story:unrefined,frontend" "$EX")" = "yes" ] && ok "genuine product story (no build label) → yes"        || bad "product story → expected yes"
[ "$(auto_refino_is_product_story "custom" "$EX")" = "yes" ]                   && ok "custom ALONE → yes (custom NOT excluded — ambiguous)" || bad "custom alone → expected yes"
[ "$(auto_refino_is_product_story "scraper" "")" = "yes" ]                     && ok "empty exclude set → yes (no filtering)"              || bad "empty exclude → expected yes"
# The EXACT dc-yla3 RESIDUAL failure mode: old code (--set-labels) had stripped the
# auto-refino:escalated marker, leaving a scraper bead carrying only a lifecycle
# label. The product filter MUST still exclude it — the escalated marker is NOT the
# only thing standing between a scraper bead and the funnel (re-escalation backstop).
[ "$(auto_refino_is_product_story "story:refinement-in-progress,scraper" "$EX")" = "no" ] \
  && ok "scraper bead w/o escalated marker (dc-yla3 residual) → no (product filter still excludes)" \
  || bad "scraper residual → expected no (re-escalation backstop missing)"

# ── Scenario 2: Triagem stories are candidates (fresh); past-states are skipped ─
echo "Scenario 2: lifecycle classification — fresh Triagem input"
[ "$(auto_refino_lifecycle_state "story:triage" "" "$ACTOR")" = "fresh" ] && ok "story:triage → fresh" || bad "story:triage → expected fresh"
[ "$(auto_refino_lifecycle_state "story:unrefined" "" "$ACTOR")" = "fresh" ] && ok "story:unrefined → fresh" || bad "story:unrefined → expected fresh"
echo "Scenario 2b: gate bounce-back (refinement-in-progress assigned to us) → bounce"
[ "$(auto_refino_lifecycle_state "story:refinement-in-progress" "$ACTOR" "$ACTOR")" = "bounce" ] && ok "in-progress assigned to us → bounce" || bad "bounce-back → expected bounce"
[ "$(auto_refino_lifecycle_state "story:refinement-in-progress" "peter-wa" "$ACTOR")" = "skip" ] && ok "in-progress owned by ANOTHER refiner → skip (no double-refine)" || bad "another refiner's in-progress → expected skip"
echo "Scenario 2c: past-the-daemon / terminal states are NEVER candidates"
for L in auto-refino:refining auto-refino:escalated refino-gate:reviewing story:refino-review story:needs-approval story:approved story:in-flight story:done story:cancelled; do
  st=$(auto_refino_lifecycle_state "$L" "" "$ACTOR")
  [ "$st" = "skip" ] && ok "$L → skip" || bad "$L → expected skip, got '$st'"
done
# A bead carrying BOTH a fresh label AND a terminal one must be skipped (terminal wins).
[ "$(auto_refino_lifecycle_state "story:unrefined,story:approved" "" "$ACTOR")" = "skip" ] && ok "unrefined+approved (mid-transition leak) → skip (terminal wins)" || bad "mixed labels → expected skip"
[ "$(auto_refino_lifecycle_state "story:triage,story:refino-review" "" "$ACTOR")" = "skip" ] && ok "triage+refino-review → skip (already handed to gate)" || bad "triage+refino-review → expected skip"

# ── Scenario 3: REFINED within budget → handoff (to the gate, NEVER approve) ──
echo "Scenario 3: REFINED → handoff (to the refino gate)"
D=$(auto_refino_handoff_decision "REFINED" 1 3)
[ "$D" = "handoff" ] && ok "REFINED attempt 1/3 → handoff" || bad "REFINED → expected handoff, got '$D'"
D=$(auto_refino_handoff_decision "REFINED" 3 3)
[ "$D" = "handoff" ] && ok "REFINED at the attempt ceiling still → handoff" || bad "REFINED at ceiling → expected handoff, got '$D'"

# ── Scenario 4: ESCALATE → escalate (never promote) ───────────────────────────
echo "Scenario 4: ESCALATE (can't refine confidently) → escalate"
D=$(auto_refino_handoff_decision "ESCALATE" 1 3)
[ "$D" = "escalate" ] && ok "ESCALATE attempt 1 → escalate" || bad "ESCALATE → expected escalate, got '$D'"
D=$(auto_refino_handoff_decision "ESCALATE" 9 3)
[ "$D" = "escalate" ] && ok "ESCALATE at any attempt → escalate" || bad "ESCALATE → expected escalate, got '$D'"

# ── Scenario 4a: imp16 ESCALATE:info-gap → escalate-info-gap (no human page) ──
echo "Scenario 4a (imp16): ESCALATE:info-gap (thin/duplicate/trivial) → escalate-info-gap"
D=$(auto_refino_handoff_decision "ESCALATE:info-gap" 1 3)
[ "$D" = "escalate-info-gap" ] && ok "ESCALATE:info-gap → escalate-info-gap (not in Athos queue)" || bad "ESCALATE:info-gap → expected escalate-info-gap, got '$D'"
D=$(auto_refino_handoff_decision "ESCALATE:info-gap" 9 3)
[ "$D" = "escalate-info-gap" ] && ok "ESCALATE:info-gap at any attempt → escalate-info-gap" || bad "ESCALATE:info-gap high-attempt → expected escalate-info-gap, got '$D'"

# ── Scenario 4b: escalated flag is durable → re-escalation loop cannot form ────
# BUG 1: the escalate path persists auto-refino:escalated ADDITIVELY (no
# --set-labels clobber). The post-escalate state is story:refinement-in-progress +
# auto-refino:escalated, ASSIGNED TO US — which would otherwise classify as a
# bounce candidate. The escalated flag must win (terminal/skip) so the story is
# NEVER re-selected (dc-yla3 attempt 1→2→3→4/3).
echo "Scenario 4b: post-escalate state → skip forever (escalated wins over bounce; bug 1)"
[ "$(auto_refino_lifecycle_state "story:refinement-in-progress,auto-refino:escalated,custom,scraper" "$ACTOR" "$ACTOR")" = "skip" ] \
  && ok "in-progress+escalated assigned to us → skip (NOT re-picked as bounce)" \
  || bad "post-escalate state → expected skip (re-escalation loop would re-form)"
[ "$(auto_refino_lifecycle_state "story:unrefined,auto-refino:escalated,custom,scraper" "" "$ACTOR")" = "skip" ] \
  && ok "unrefined+escalated (escalated survives) → skip (not re-classified fresh)" \
  || bad "unrefined+escalated → expected skip"

# ── Scenario 4c: RAW ingestion never re-captures an ESCALATED story (bug ga-it11w)
# Terminal-escalate strips ALL story:* labels, so an escalated story is left with
# only auto-refino:escalated and NO story:* — which makes it look RAW (no lifecycle
# label) to the 4th candidate source. Without the escalated guard it was re-ingested
# with story:unrefined every sweep → infinite loop (regression: ga-m9gt3, attempts
# 1/2/3 then re-ingest). is_ingestable_raw MUST disqualify it. (The RAW jq query
# drops it too — drift-guard 0c below.)
EX="scraper build infra config deploy migration pipeline"
echo "Scenario 4c: RAW ingestion excludes escalated stories (bug ga-it11w)"
# The exact ga-m9gt3 shape: feature, no story:* label, only auto-refino:escalated.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated" "false" "$EX")" = "no" ] \
  && ok "escalated story (only auto-refino:escalated, no story:*) → no (NOT re-ingested)" \
  || bad "escalated RAW story → expected no (re-ingestion loop ga-it11w would re-form)"
# escalated alongside an incidental product label is still terminal.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated,frontend" "false" "$EX")" = "no" ] \
  && ok "escalated + product label → no (escalated wins)" \
  || bad "escalated+product → expected no"
# A genuine RAW Triagem story (no story:*, no escalated) is STILL ingestable —
# the guard must not over-reject and starve the funnel.
[ "$(auto_refino_is_ingestable_raw "ga-fresh1" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "genuine raw story (no story:*, no escalated) → yes (funnel not starved)" \
  || bad "genuine raw story → expected yes"

# ── Scenario 4d: RAW min-age guard (bug ga-51ry, 3rd occurrence wa-soe8a) ──────
# A manual/automated recovery transition (e.g. the Mayor clearing gate:needs-human
# to retry) can clear the LAST protective story:*/gate:* label moments before
# applying its replacement — the RAW sweep can land inside that gap (observed:
# 87s) and mistake an already-triaged, already-approved/gated story for genuinely
# untriaged raw work. age_minutes/min_age_minutes are the two new OPTIONAL
# trailing params; every Scenario 4c call above omits them and must be unaffected
# (proven by 4c still passing green).
echo "Scenario 4d: RAW min-age guard — freshly-mutated no-label bead is NOT ingested (ga-51ry)"
[ "$(auto_refino_is_ingestable_raw "wa-soe8a" "feature" "" "false" "$EX" "1" "5")" = "no" ] \
  && ok "no-label bead updated 1m ago (<5m floor) → no (too fresh, likely mid-recovery)" \
  || bad "freshly-mutated no-label bead → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-soe8a" "feature" "" "false" "$EX" "10" "5")" = "yes" ] \
  && ok "same bead, now updated 10m ago (>=5m floor) → yes (quiet long enough to trust)" \
  || bad "aged-past-floor bead → expected yes"
[ "$(auto_refino_is_ingestable_raw "wa-soe8a" "feature" "" "false" "$EX" "5" "5")" = "yes" ] \
  && ok "age_minutes == min_age_minutes (boundary) → yes (>= floor, not strictly less)" \
  || bad "boundary age == floor → expected yes"
[ "$(auto_refino_is_ingestable_raw "wa-soe8a" "feature" "" "false" "$EX" "" "5")" = "yes" ] \
  && ok "missing age_minutes (unparseable updated_at upstream) → yes (fails OPEN, never starves funnel)" \
  || bad "missing age_minutes → expected yes (fail-open)"
[ "$(auto_refino_is_ingestable_raw "wa-soe8a" "feature" "" "false" "$EX" "garbage" "5")" = "yes" ] \
  && ok "non-numeric age_minutes → yes (sanitized to fail-open, mirrors auto_refino_next_attempt idiom)" \
  || bad "garbage age_minutes → expected yes (fail-open)"
[ "$(auto_refino_is_ingestable_raw "wa-soe8a" "feature" "" "false" "$EX" "0" "")" = "yes" ] \
  && ok "non-numeric min_age_minutes → yes (guard disabled, sanitized to 0-minute floor)" \
  || bad "garbage min_age_minutes → expected yes (guard disabled)"
# The age guard must not override the escalated/gate:* guards — a too-fresh
# ESCALATED bead is still disqualified for being escalated, not merely re-admitted
# because it also happens to fail the age check for a different reason.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated" "false" "$EX" "10" "5")" = "no" ] \
  && ok "escalated bead that is ALSO old enough → still no (escalated guard independent of age)" \
  || bad "escalated+aged → expected no"

# ── Scenario 5: attempt cap terminates a daemon↔gate ping-pong ────────────────
echo "Scenario 5: REFINED beyond the attempt budget → escalate (loop terminates)"
D=$(auto_refino_handoff_decision "REFINED" 4 3)
[ "$D" = "escalate" ] && ok "REFINED attempt 4 (budget spent) → escalate (no infinite ping-pong)" || bad "REFINED beyond budget → expected escalate, got '$D'"
echo "Scenario 5b: attempt counter increments and sanitizes"
[ "$(auto_refino_next_attempt 0)" = "1" ] && ok "0 → 1" || bad "0 → expected 1"
[ "$(auto_refino_next_attempt 2)" = "3" ] && ok "2 → 3" || bad "2 → expected 3"
[ "$(auto_refino_next_attempt '')" = "1" ] && ok "empty → 1 (sanitized)" || bad "empty → expected 1"
[ "$(auto_refino_next_attempt 'xyz')" = "1" ] && ok "non-numeric → 1 (sanitized)" || bad "non-numeric → expected 1"
echo "Scenario 5c: a chain of gate-bounces terminates at the cap (no infinite loop)"
attempts=0; maxa=3; escalated=0; handoffs=0
for _ in 1 2 3 4 5 6; do
  attempts=$(auto_refino_next_attempt "$attempts")
  d=$(auto_refino_handoff_decision "REFINED" "$attempts" "$maxa")
  case "$d" in
    handoff) handoffs=$((handoffs+1)) ;;
    escalate) escalated=1; break ;;
  esac
done
if [ "$escalated" = "1" ] && [ "$handoffs" -eq "$maxa" ]; then
  ok "chain of REFINED→bounce: $handoffs handoff(s) then escalate at attempt $((maxa+1)) (loop terminates)"
else
  bad "attempt-cap loop did not terminate as expected (handoffs=$handoffs escalated=$escalated)"
fi

# ── Scenario 6: NEVER approve / NEVER dispatch — decision vocabulary is bounded ─
echo "Scenario 6: the decision core can NEVER emit approve/needs-approval/dispatch (ga-flxp6 AC)"
seen_bad=0
for o in REFINED ESCALATE SPLIT TIMEOUT GARBAGE ""; do
  for a in 0 1 2 3 4 5; do
    d=$(auto_refino_handoff_decision "$o" "$a" 3)
    case "$d" in
      approve|story:approved|needs-approval|story:needs-approval|dispatch) seen_bad=1 ;;
    esac
    case "$d" in handoff|escalate|split|requeue) : ;; *) bad "unexpected decision token '$d' for outcome=$o attempt=$a"; esac
  done
done
[ "$seen_bad" = "0" ] && ok "no input ever yields approve/needs-approval/dispatch (only handoff/escalate/split/requeue)" || bad "REGRESSION: decision core emitted an approve/dispatch token"

# ── Scenario 7: TIMEOUT / unknown → requeue (never promote) ───────────────────
echo "Scenario 7: TIMEOUT / unknown → requeue (never promote, never approve)"
D=$(auto_refino_handoff_decision "TIMEOUT" 1 3)
[ "$D" = "requeue" ] && ok "TIMEOUT → requeue" || bad "TIMEOUT → expected requeue, got '$D'"
D=$(auto_refino_handoff_decision "" 2 3)
[ "$D" = "requeue" ] && ok "empty outcome → requeue" || bad "empty → expected requeue, got '$D'"
D=$(auto_refino_handoff_decision "weird" 1 3)
[ "$D" = "requeue" ] && ok "garbage outcome → requeue" || bad "garbage → expected requeue, got '$D'"

# ── DRIFT GUARDS: static assertions on the shipped dispatcher ─────────────────
echo "Drift guards: live wiring matches the acceptance criteria"

# 1. The refine handoff sets story:refino-review (the gate's input / 'em revisão')
#    ADDITIVELY (label add, not --set-labels — see drift-guard 0/bug 2). ga-78tut:
#    now written via the atomic `--add-label` flag form (one bd update call per
#    transition), not the old independent `label add`/`label remove` subcommand
#    sequence — match either shape.
if grep -qE 'label add "\$STORY_ID" "story:refino-review"|--add-label "story:refino-review"' "$DISPATCHER"; then
  ok "refine handoff adds story:refino-review (gate input / 'em revisão' pill, additive)"
else
  bad "refine handoff does not add story:refino-review"
fi

# 0. BUG 2: no --set-labels in actual CODE. --set-labels REPLACES the whole label
#    set, silently dropping unrelated labels (custom/scraper) AND the
#    auto-refino:escalated skip marker (bug 1). Every transition must be additive
#    label add / label remove. (Comment lines that mention the token are ignored —
#    grep only the non-comment lines.)
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -q -- '--set-labels'; then
  bad "REGRESSION (bug 2): --set-labels present in code — it clobbers unrelated labels; use additive label add/remove"
else
  ok "no --set-labels in code (additive label add/remove only — no label clobber)"
fi

# 0a2. ga-78tut: the OPPOSITE anti-pattern — a single state transition split into
#      N INDEPENDENT `label add`/`label remove` subcommand invocations inside the
#      REFINE_TASK heredoc (the prompt template instructing the spawned refiner).
#      Each invocation swallows its own error independently (`|| true` at the
#      shell level, or simply no checking at the LLM-instruction level) without
#      checking the previous one — if one fails mid-sequence, the bead is left in
#      a state neither the refine queue nor the escalation queue recognizes,
#      while the log still claims the transition succeeded. The gate caught this
#      exact class in a sibling file (ga-xvxvf, refino-gate-dispatcher.sh) first.
#      Fix: consolidate every transition into ONE atomic
#      `bd update <id> --add-label A --add-label B --remove-label C` call — the
#      two flags are repeatable and the whole call is one bd/Dolt operation, so
#      a failure leaves ALL labels unchanged instead of a partial mix.
#      Isolate the heredoc body first (grep -v the case/type declarations method
#      above scans the WHOLE file, but this anti-pattern is specifically about
#      the PROMPT TEXT — a live daemon-side single `label remove` call, like the
#      Step-0 TTL recovery pass, is a single op already and is not in scope).
_heredoc_start=$(grep -n "IFS= read -r -d '' REFINE_TASK <<TASK" "$DISPATCHER" | head -1 | cut -d: -f1)
_heredoc_end=$(grep -n '^TASK$' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$_heredoc_start" ] && [ -n "$_heredoc_end" ]; then
  _heredoc_body=$(sed -n "${_heredoc_start},${_heredoc_end}p" "$DISPATCHER")
  if printf '%s' "$_heredoc_body" | grep -qE '"\$(AR_BEAD_STORE)" label (add|remove)'; then
    bad "REGRESSION (ga-78tut): REFINE_TASK heredoc still contains independent 'label add'/'label remove' subcommand invocations — consolidate each transition into one 'bd update --add-label/--remove-label' call (same class as ga-xvxvf, caught by the gate)"
  else
    ok "ga-78tut: REFINE_TASK heredoc has no independent label add/remove invocations — every transition is one atomic bd update call"
  fi
else
  bad "ga-78tut: could not locate the REFINE_TASK heredoc boundaries to check for independent label writes"
fi

# 0b. BUG 1: the escalate path durably persists auto-refino:escalated (additively)
#     AND the lifecycle classifier's skip-set honours it — so an escalated story is
#     NEVER re-selected (dc-yla3 re-escalation loop 1→2→3→4/3).
if grep -qF 'label add "$STORY_ID" "auto-refino:escalated"' "$DISPATCHER" \
   && grep -qF '*,auto-refino:escalated,*' "$DISPATCHER"; then
  ok "escalate persists auto-refino:escalated (additive) + classifier skip-set honours it (no re-escalation)"
else
  bad "escalate marker not durably persisted, or not in the classifier skip-set"
fi

# 0c. BUG 3: candidate selection filters out build/scraper/non-product beads via the
#     pure auto_refino_is_product_story classifier + an env-overridable exclude set.
if grep -qF 'auto_refino_is_product_story "$c_labels"' "$DISPATCHER" \
   && grep -q 'AUTO_REFINO_EXCLUDE_LABELS=' "$DISPATCHER"; then
  ok "candidate selection excludes build/scraper/non-product beads (bug 3)"
else
  bad "candidate selection does not filter out build/non-product beads"
fi

# 0d. BUG ga-it11w: the RAW Triagem source (4th candidate source) MUST drop
#     already-escalated stories in its jq filter, AND the is_ingestable_raw
#     classifier MUST disqualify them. Terminal-escalate strips all story:*
#     labels, so an escalated story looks RAW — both layers must exclude it or it
#     re-ingests forever (ga-m9gt3). Defense in depth: query drops + classifier
#     disqualifies (mirrors guards 0b/0c).
if grep -qF 'any(. == "auto-refino:escalated")) | not' "$DISPATCHER" \
   && grep -qF '*,auto-refino:escalated,*) echo "no"' "$DISPATCHER"; then
  ok "RAW ingestion drops escalated stories — jq query AND is_ingestable_raw (bug ga-it11w)"
else
  bad "RAW ingestion does not exclude escalated stories — re-ingestion loop ga-it11w can re-form"
fi

# 0d. ESCALATE-LOOP RE-FIX: the escalate path must be TERMINAL — it removes the
#     lifecycle label (via _clear_lifecycle) so NO candidate query (FRESH/UNREF/
#     BOUNCE) can re-pick the bead, instead of leaving story:refinement-in-progress
#     and relying solely on the auto-refino:escalated marker (the single point of
#     failure that re-escalated dc-yla3 to attempt 5/3 after the prior fix).
if grep -qF '_clear_lifecycle "$STORY_ID"' "$DISPATCHER"; then
  ok "escalate path is terminal: _clear_lifecycle removes the lifecycle label (no re-pick)"
else
  bad "escalate path does not clear the lifecycle label — re-escalation loop can re-form"
fi
# _clear_lifecycle must iterate the FULL lifecycle set and REMOVE (never add) each.
if awk '/^_clear_lifecycle\(\)/{f=1} f&&/for l in \$AUTO_REFINO_LIFECYCLE_LABELS/{loop=1} f&&/label remove/{rm=1} f&&/^}/&&NR>1{if(f)f=0} END{exit !(loop&&rm)}' "$DISPATCHER"; then
  ok "_clear_lifecycle iterates AUTO_REFINO_LIFECYCLE_LABELS and removes each"
else
  bad "_clear_lifecycle does not remove the full lifecycle set"
fi
# The plist must pin AUTO_REFINO_EXCLUDE_LABELS so launchd never runs the daemon
# with an empty exclude set (defense for bug 3 at the deployment layer).
PLIST="$SELF_DIR/auto-refino-dispatcher.plist"
if grep -q 'AUTO_REFINO_EXCLUDE_LABELS' "$PLIST" 2>/dev/null \
   && grep -A1 'AUTO_REFINO_EXCLUDE_LABELS' "$PLIST" 2>/dev/null | grep -q 'scraper'; then
  ok "plist pins AUTO_REFINO_EXCLUDE_LABELS incl. scraper (deployment-layer defense)"
else
  bad "plist does not pin AUTO_REFINO_EXCLUDE_LABELS"
fi

# 2. The handoff records story.refino_refiner so the gate bounces FAILs back to us.
if grep -q 'story.refino_refiner=' "$DISPATCHER"; then
  ok "handoff records story.refino_refiner (gate bounce-back target)"
else
  bad "handoff does not record story.refino_refiner"
fi

# 3. The dispatcher NEVER writes story:needs-approval NOR story:approved
#    (ga-flxp6 AC: nenhuma história é auto-aprovada; só chega em needs-approval
#    DEPOIS de passar no gate, escrito pelo GATE, não pelo daemon).
if grep -qE 'set-labels[[:space:]]+story:approved|label add[^\n]*story:approved' "$DISPATCHER"; then
  bad "REGRESSION: dispatcher writes story:approved — the daemon must NEVER approve"
else
  ok "dispatcher never writes story:approved (AC: nunca auto-aprova)"
fi
if grep -qE 'set-labels[[:space:]]+story:needs-approval|label add[^\n]*story:needs-approval' "$DISPATCHER"; then
  bad "REGRESSION: dispatcher writes story:needs-approval — only the GATE may promote"
else
  ok "dispatcher never writes story:needs-approval (only the gate promotes)"
fi

# 3b. The daemon must NOT dispatch (no gc sling / pilot dispatch from here).
if grep -qE 'gc[^\n]*sling|pilot[^\n]*dispatch' "$DISPATCHER"; then
  bad "REGRESSION: dispatcher contains a dispatch/sling call — the daemon must NEVER dispatch"
else
  ok "dispatcher never dispatches (no gc sling / pilot dispatch)"
fi

# 4. The escalate path records gaps, flags auto-refino:escalated, and notifies
#    Athos/Mayor — without promoting.
if grep -q 'auto-refino:escalated' "$DISPATCHER" && grep -q 'mail send mayor' "$DISPATCHER" \
   && grep -q 'story.auto_refino_gaps' "$DISPATCHER"; then
  ok "escalate path flags auto-refino:escalated + records story.auto_refino_gaps + notifies Mayor"
else
  bad "escalate path missing the escalated flag, gaps metadata, or Mayor notify"
fi

# 4b. ga-lfua3 BUG 1: the escalate path must ALSO add story:refino-escalado (the
#     painel _SUAVEZ_LABELS member) so escalations surface in the human "Sua vez"
#     queue instead of rendering in TRIAGEM. It must appear in BOTH escalate paths:
#     the inline daemon escalate (bd_ label add "$STORY_ID" ...) AND the spawned
#     refiner's task heredoc. Count both occurrences; require at least 2.
#     ga-78tut: the heredoc path now writes this via the atomic
#     `--add-label "story:refino-escalado"` form (not the subcommand form), so
#     match either shape — the inline path is untouched and still uses the
#     subcommand form.
_escalado_hits=$(grep -cE 'label add "\$STORY_ID" "story:refino-escalado"|--add-label "story:refino-escalado"' "$DISPATCHER")
if [ "$_escalado_hits" -ge 2 ]; then
  ok "escalate adds story:refino-escalado in BOTH paths ($_escalado_hits hits) → surfaces in 'Sua vez' (ga-lfua3 bug 1)"
elif [ "$_escalado_hits" -eq 1 ]; then
  bad "story:refino-escalado added in only ONE escalate path — the other path still hides the escalation"
else
  bad "escalate path does NOT add story:refino-escalado — escalations stay invisible in TRIAGEM (ga-lfua3 bug 1)"
fi
# story:refino-escalado must NOT be in AUTO_REFINO_LIFECYCLE_LABELS, otherwise
# _clear_lifecycle would strip the label we just added to surface the escalation.
if grep -q '^AUTO_REFINO_LIFECYCLE_LABELS=' "$DISPATCHER" \
   && grep '^AUTO_REFINO_LIFECYCLE_LABELS=' "$DISPATCHER" | grep -q 'story:refino-escalado'; then
  bad "story:refino-escalado is in AUTO_REFINO_LIFECYCLE_LABELS — _clear_lifecycle would strip the escalation label"
else
  ok "story:refino-escalado is NOT in AUTO_REFINO_LIFECYCLE_LABELS (survives _clear_lifecycle)"
fi
# Classifier skip-set honours story:refino-escalado as terminal (structural belt
# independent of the auto-refino:escalated marker).
if grep -qF '*,story:refino-escalado,*' "$DISPATCHER"; then
  ok "classifier skip-set treats story:refino-escalado as terminal (structural belt)"
else
  bad "classifier skip-set does not list story:refino-escalado — could be re-picked if marker stripped"
fi

# 4c. ga-xdukc/ga-hd87d BUG: the escalate path must ALSO add story:needs-human —
#     the exact label pilot-dispatcher.sh _filter_candidates already excludes on
#     (. == "story:needs-human"), so no Pilot change is required once this daemon
#     stamps it reliably. Before this fix, the deterministic bash escalate case
#     added ONLY auto-refino:escalated + story:refino-escalado; the spawned
#     refiners own PATH B heredoc separately instructs it to add
#     gate:needs-human:product, but that is an LLM agentic tool call — best
#     effort, not guaranteed on every run. wa-5ch02 proved the gap live: escalated
#     with refino:policy-gap + story:refino-escalado, reached Pilot with NEITHER
#     needs-human label, dispatched with "No human review required." This check
#     is scoped to the DETERMINISTIC bash path only (must appear at least once,
#     unlike the story:refino-escalado check above which requires 2 hits across
#     both the bash path and the heredoc — story:needs-human is a NEW label this
#     fix introduces only in the bash path, not in the heredocs gate:needs-human:
#     product convention).
if grep -qF 'label add "$STORY_ID" "story:needs-human"' "$DISPATCHER"; then
  ok "escalate path (deterministic bash) adds story:needs-human — Pilot _filter_candidates already excludes this exact label (ga-xdukc/ga-hd87d)"
else
  bad "escalate path does NOT add story:needs-human — a policy-gap escalation can still reach Pilot with no label it excludes on (ga-xdukc/ga-hd87d REGRESSION)"
fi
# story:needs-human must NOT be in AUTO_REFINO_LIFECYCLE_LABELS, otherwise
# _clear_lifecycle (called earlier in the same escalate case) would strip it
# right back off before it ever reached Dolt.
if grep -q '^AUTO_REFINO_LIFECYCLE_LABELS=' "$DISPATCHER" \
   && grep '^AUTO_REFINO_LIFECYCLE_LABELS=' "$DISPATCHER" | grep -q 'story:needs-human'; then
  bad "story:needs-human is in AUTO_REFINO_LIFECYCLE_LABELS — _clear_lifecycle would strip the label this fix just added"
else
  ok "story:needs-human is NOT in AUTO_REFINO_LIFECYCLE_LABELS (survives _clear_lifecycle)"
fi
# Ordering: the label add must appear AFTER _clear_lifecycle in the escalate
# case, not before (else the strip could race/overwrite an in-flight add on a
# re-escalation). Both this label and story:refino-escalado follow the same
# convention; assert story:needs-human is not accidentally placed upstream of
# the _clear_lifecycle call within the same case block.
_esc_block=$(awk '/^  escalate\)$/{f=1} f{print} f&&/^    ;;$/{exit}' "$DISPATCHER")
_clear_line=$(printf '%s\n' "$_esc_block" | grep -n '_clear_lifecycle "\$STORY_ID"' | head -1 | cut -d: -f1)
_needshuman_line=$(printf '%s\n' "$_esc_block" | grep -n 'label add "\$STORY_ID" "story:needs-human"' | head -1 | cut -d: -f1)
if [ -n "$_clear_line" ] && [ -n "$_needshuman_line" ] && [ "$_needshuman_line" -gt "$_clear_line" ]; then
  ok "story:needs-human is added AFTER _clear_lifecycle within the escalate case (correct ordering)"
else
  bad "story:needs-human ordering relative to _clear_lifecycle is wrong or indeterminate (clear_line=$_clear_line needshuman_line=$_needshuman_line) — could be stripped by the same case that adds it"
fi

# 5. Candidate selection is restricted to feature/story (bug/chore/task bypass):
#    every fresh source query carries --type feature, and the type classifier is
#    asserted per candidate before claiming.
if grep -q 'auto_refino_type_eligible "$c_type"' "$DISPATCHER" && grep -q -- '--type feature' "$DISPATCHER"; then
  ok "candidate selection restricted to feature/story (type query + per-candidate classifier)"
else
  bad "candidate selection does not restrict to feature/story"
fi

# 6. Reuses /refino simplificado: sets story.refino_mode=simplificado and writes
#    the skip sentinel on F3/F4/F5.
if grep -q 'story.refino_mode=simplificado' "$DISPATCHER" \
   && grep -q 'pulado no refino simplificado' "$DISPATCHER" \
   && grep -q 'story.estrela_guia=' "$DISPATCHER"; then
  ok "reuses /refino simplificado (refino_mode=simplificado + skip sentinel on F3/F4/F5)"
else
  bad "does not reuse the /refino simplificado field set / skip sentinel"
fi

# 7. The refiner is spawned on the Sonnet auto-refiner template (LLM judgement).
if grep -q 'session new "$AUTO_REFINO_REFINER_TEMPLATE"' "$DISPATCHER"; then
  ok "refiner spawned via gc session new on the auto-refiner template"
else
  bad "refiner spawn does not use the auto-refiner template"
fi
if grep -q '^model = "sonnet"' "$SELF_DIR/../../../agents/auto-refiner/agent.toml" 2>/dev/null; then
  ok "auto-refiner template pins model = sonnet"
else
  bad "auto-refiner template does not pin model = sonnet"
fi

# 8. DRY_RUN must not transition labels or spawn (proof-mode safety). With no live
#    bd the queue is empty → it exits 0 without spawning, logging the dry-run.
#    AUTO_REFINO_STORES is pinned to the temp city so the test is HERMETIC (does
#    not query the live WA/PS rig stores that the multi-store default points at).
_drycity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_drycity" AUTO_REFINO_STORES="$_drycity" DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_dryrc=$?
_drylog=$(cat "$_drycity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_dryrc" -eq 0 ] && echo "$_drylog" | grep -qiE 'Auto-refino sweep start.*dry_run=1'; then
  ok "DRY_RUN executes the sweep harness cleanly (exit 0, proof mode, no spawn)"
else
  bad "DRY_RUN did not run cleanly in proof mode (rc=$_dryrc)"
fi
rm -rf "$_drycity"

# ── Drift-guard ga-fnnyy: 🚨 compliance/safety block preservation ────────────
# Bug ga-fnnyy: auto-refino's --description rewrite (step 4 REFINE_TASK,
# "IF YOU CAN REFINE" path) silently dropped a 🚨-marked compliance gate the
# Mayor had written into a story's description (wa-qgft5, LGPD/PII exposure),
# and nothing blocked the resulting bead from being auto-dispatched — the
# reconciler even alarmed that it WASN'T being dispatched. These are
# grep-based drift-guards (same idiom as guards 1-8 above): the actual
# preserve-or-not decision is made by the spawned LLM refiner reading this
# heredoc as a prompt, not by testable shell logic, so the guarantee here is
# "the instruction ships in the prompt", not "the behavior is unit-testable".
_flat_task="$(tr '\n' ' ' < "$DISPATCHER")"
if grep -q '🚨' "$DISPATCHER"; then
  ok "ga-fnnyy: REFINE_TASK heredoc mentions the 🚨 compliance marker"
else
  bad "ga-fnnyy: REFINE_TASK heredoc has no mention of the 🚨 marker — nothing tells the refiner to preserve it"
fi
if printf '%s' "$_flat_task" | grep -qiF 'must not let --description silently drop it'; then
  ok "ga-fnnyy: REFINE_TASK heredoc has an explicit preserve-verbatim instruction for 🚨 blocks"
else
  bad "ga-fnnyy: REFINE_TASK heredoc does not explicitly instruct verbatim preservation of 🚨 blocks"
fi
# ga-78tut: both labels now ship as one atomic `bd update --add-label ... --add-label ...`
# call rather than two independent `label add` invocations — match either shape.
if grep -qE 'label add "\$STORY_ID" "needs-human"|--add-label "needs-human"' "$DISPATCHER" \
   && grep -qE 'label add "\$STORY_ID" "pilot:no-auto-dispatch"|--add-label "pilot:no-auto-dispatch"' "$DISPATCHER"; then
  ok "ga-fnnyy: REFINE_TASK heredoc example includes needs-human + pilot:no-auto-dispatch label-add commands"
else
  bad "ga-fnnyy: REFINE_TASK heredoc does not show needs-human + pilot:no-auto-dispatch as commands to run"
fi
_rules_block=$(awk '/^RULES:/{f=1} f{print}' "$DISPATCHER")
if printf '%s' "$_rules_block" | grep -q '🚨'; then
  ok "ga-fnnyy: RULES section (final checklist read by the refiner) restates the 🚨 rule"
else
  bad "ga-fnnyy: RULES section does not restate the 🚨 rule — easy to miss on a long prompt"
fi

# ── Scenario 9: DELIVERED-DUP CHECK (wa-ca4jm) ───────────────────────────────
# A REFINED story whose twin is closed/done must NOT be promoted (handoff
# bookkeeping skipped); it must get refino:info-gap + auto-refino:escalated
# instead.  We mock bd_ using a stub that:
#   • returns a JSON pairs array containing STORY_ID paired with a twin
#   • returns a closed bead JSON for the twin on `bd show`
# Then drive the handoff) case directly by calling the shell code with the
# mocked bd_.
echo "Scenario 9: DELIVERED-DUP CHECK — refined story whose twin is closed → NOT promoted"

# Build a tmp city dir so LOG/AR_LOG write paths resolve.
_dc9city="$(mktemp -d)"
mkdir -p "$_dc9city/.gc/logs"

# Dummy STORY_ID for this scenario.
_s9id="ga-dup-test"

# We need to exercise the handoff) block in isolation. Source the dispatcher in
# lib-only mode (already done above), then manually call the block as a function
# by wrapping it.  The cleanest shim: set up env vars and a mock bd_ then eval
# the relevant code path.

_dup_blocked=""
_dup_no_block=""

# ── 9a: twin is delivered (status=closed) → handoff BLOCKED ──────────────────
(
  # Override bd_ to our mock.
  bd_() {
    case "$*" in
      "find-duplicates --method mechanical --threshold 0.5 --json")
        # Return a pairs list where ga-dup-test is paired with ga-twin-closed.
        printf '{"pairs":[{"issue_a_id":"ga-dup-test","issue_a_title":"Foo","issue_b_id":"ga-twin-closed","issue_b_title":"Foo delivered","method":"mechanical","similarity":0.9}]}\n'
        ;;
      "show ga-twin-closed --json")
        # Closed delivered twin.
        printf '[{"id":"ga-twin-closed","status":"closed","labels":["story:done"]}]\n'
        ;;
      *) true ;;
    esac
  }
  notify() { true; }
  gc()     { true; }

  STORY_ID="$_s9id"
  THIS_ATTEMPT=1
  AUTO_REFINO_DUP_CHECK=1
  AUTO_REFINO_DUP_THRESHOLD=0.5
  GC_CITY="$_dc9city"
  AR_STORE="$_dc9city"
  LOG="$_dc9city/.gc/logs/ar-s9.log"

  _dup_twin=""
  _dt="${AUTO_REFINO_DUP_THRESHOLD:-0.5}"
  _dup_raw=$(bd_ find-duplicates --method mechanical --threshold "$_dt" --json 2>/dev/null || echo "")
  if [ -n "$_dup_raw" ]; then
    _twin_ids=$(printf '%s' "$_dup_raw" | jq -r --arg id "$STORY_ID" \
      '(.pairs // [])[] | select(.issue_a_id==$id or .issue_b_id==$id) |
       if .issue_a_id==$id then .issue_b_id else .issue_a_id end' 2>/dev/null || echo "")
    for _twin in $_twin_ids; do
      [ -z "$_twin" ] && continue
      _twin_json=$(bd_ show "$_twin" --json 2>/dev/null || echo "")
      [ -z "$_twin_json" ] && continue
      _is_delivered=$(printf '%s' "$_twin_json" | jq -r '
        (if type=="array" then .[0] else . end) |
        ( .status == "closed" ) or
        ( (.labels // []) | any(. == "gate:passed" or . == "story:done") )
        | if . then "yes" else "no" end' 2>/dev/null || echo "no")
      if [ "$_is_delivered" = "yes" ]; then
        _dup_twin="$_twin"
        break
      fi
    done
  fi

  if [ -n "$_dup_twin" ]; then
    echo "BLOCKED:$_dup_twin"
  else
    echo "NOT_BLOCKED"
  fi
) > "$_dc9city/s9a.out" 2>/dev/null

_s9a=$(cat "$_dc9city/s9a.out" 2>/dev/null || echo "")
if echo "$_s9a" | grep -q "^BLOCKED:ga-twin-closed"; then
  ok "9a: refined story with closed twin → handoff BLOCKED (twin=ga-twin-closed detected)"
else
  bad "9a: refined story with closed twin → expected BLOCKED, got: $_s9a"
fi

# ── 9b: no delivered twin → handoff proceeds normally ────────────────────────
(
  bd_() {
    case "$*" in
      "find-duplicates --method mechanical --threshold 0.5 --json")
        # Pair exists but twin is open (not delivered).
        printf '{"pairs":[{"issue_a_id":"ga-dup-test","issue_a_title":"Foo","issue_b_id":"ga-twin-open","issue_b_title":"Similar open","method":"mechanical","similarity":0.8}]}\n'
        ;;
      "show ga-twin-open --json")
        printf '[{"id":"ga-twin-open","status":"open","labels":["story:in-flight"]}]\n'
        ;;
      *) true ;;
    esac
  }

  STORY_ID="$_s9id"
  THIS_ATTEMPT=1
  AUTO_REFINO_DUP_CHECK=1
  AUTO_REFINO_DUP_THRESHOLD=0.5

  _dup_twin=""
  _dt="${AUTO_REFINO_DUP_THRESHOLD:-0.5}"
  _dup_raw=$(bd_ find-duplicates --method mechanical --threshold "$_dt" --json 2>/dev/null || echo "")
  if [ -n "$_dup_raw" ]; then
    _twin_ids=$(printf '%s' "$_dup_raw" | jq -r --arg id "$STORY_ID" \
      '(.pairs // [])[] | select(.issue_a_id==$id or .issue_b_id==$id) |
       if .issue_a_id==$id then .issue_b_id else .issue_a_id end' 2>/dev/null || echo "")
    for _twin in $_twin_ids; do
      [ -z "$_twin" ] && continue
      _twin_json=$(bd_ show "$_twin" --json 2>/dev/null || echo "")
      [ -z "$_twin_json" ] && continue
      _is_delivered=$(printf '%s' "$_twin_json" | jq -r '
        (if type=="array" then .[0] else . end) |
        ( .status == "closed" ) or
        ( (.labels // []) | any(. == "gate:passed" or . == "story:done") )
        | if . then "yes" else "no" end' 2>/dev/null || echo "no")
      if [ "$_is_delivered" = "yes" ]; then
        _dup_twin="$_twin"
        break
      fi
    done
  fi

  if [ -n "$_dup_twin" ]; then
    echo "BLOCKED:$_dup_twin"
  else
    echo "NOT_BLOCKED"
  fi
) > "$_dc9city/s9b.out" 2>/dev/null

_s9b=$(cat "$_dc9city/s9b.out" 2>/dev/null || echo "")
if [ "$_s9b" = "NOT_BLOCKED" ]; then
  ok "9b: refined story whose twin is OPEN → handoff NOT blocked (non-dup proceeds normally)"
else
  bad "9b: non-delivered twin should NOT block handoff, got: $_s9b"
fi

# ── 9c: gate:passed label (not closed status) → BLOCKED ──────────────────────
(
  bd_() {
    case "$*" in
      "find-duplicates --method mechanical --threshold 0.5 --json")
        printf '{"pairs":[{"issue_a_id":"ga-dup-test","issue_a_title":"Foo","issue_b_id":"ga-twin-gatepassed","issue_b_title":"Gate-passed twin","method":"mechanical","similarity":0.75}]}\n'
        ;;
      "show ga-twin-gatepassed --json")
        # Open status but carries gate:passed — still delivered.
        printf '[{"id":"ga-twin-gatepassed","status":"open","labels":["gate:passed","story:approved"]}]\n'
        ;;
      *) true ;;
    esac
  }

  STORY_ID="$_s9id"
  THIS_ATTEMPT=1
  AUTO_REFINO_DUP_CHECK=1
  AUTO_REFINO_DUP_THRESHOLD=0.5

  _dup_twin=""
  _dt="${AUTO_REFINO_DUP_THRESHOLD:-0.5}"
  _dup_raw=$(bd_ find-duplicates --method mechanical --threshold "$_dt" --json 2>/dev/null || echo "")
  if [ -n "$_dup_raw" ]; then
    _twin_ids=$(printf '%s' "$_dup_raw" | jq -r --arg id "$STORY_ID" \
      '(.pairs // [])[] | select(.issue_a_id==$id or .issue_b_id==$id) |
       if .issue_a_id==$id then .issue_b_id else .issue_a_id end' 2>/dev/null || echo "")
    for _twin in $_twin_ids; do
      [ -z "$_twin" ] && continue
      _twin_json=$(bd_ show "$_twin" --json 2>/dev/null || echo "")
      [ -z "$_twin_json" ] && continue
      _is_delivered=$(printf '%s' "$_twin_json" | jq -r '
        (if type=="array" then .[0] else . end) |
        ( .status == "closed" ) or
        ( (.labels // []) | any(. == "gate:passed" or . == "story:done") )
        | if . then "yes" else "no" end' 2>/dev/null || echo "no")
      if [ "$_is_delivered" = "yes" ]; then
        _dup_twin="$_twin"
        break
      fi
    done
  fi

  if [ -n "$_dup_twin" ]; then
    echo "BLOCKED:$_dup_twin"
  else
    echo "NOT_BLOCKED"
  fi
) > "$_dc9city/s9c.out" 2>/dev/null

_s9c=$(cat "$_dc9city/s9c.out" 2>/dev/null || echo "")
if echo "$_s9c" | grep -q "^BLOCKED:ga-twin-gatepassed"; then
  ok "9c: twin with gate:passed label (even if status=open) → BLOCKED"
else
  bad "9c: gate:passed twin should block — got: $_s9c"
fi

# ── 9d: find-duplicates fails (error) → FAIL-OPEN, not blocked ───────────────
(
  bd_() {
    case "$*" in
      "find-duplicates --method mechanical --threshold 0.5 --json")
        # Simulate bd_ failure (exit 1, empty output).
        return 1
        ;;
      *) true ;;
    esac
  }

  STORY_ID="$_s9id"
  AUTO_REFINO_DUP_CHECK=1
  AUTO_REFINO_DUP_THRESHOLD=0.5

  _dup_twin=""
  _dt="${AUTO_REFINO_DUP_THRESHOLD:-0.5}"
  _dup_raw=$(bd_ find-duplicates --method mechanical --threshold "$_dt" --json 2>/dev/null || echo "")
  if [ -n "$_dup_raw" ]; then
    _twin_ids=$(printf '%s' "$_dup_raw" | jq -r --arg id "$STORY_ID" \
      '(.pairs // [])[] | select(.issue_a_id==$id or .issue_b_id==$id) |
       if .issue_a_id==$id then .issue_b_id else .issue_a_id end' 2>/dev/null || echo "")
    for _twin in $_twin_ids; do
      [ -z "$_twin" ] && continue
      _twin_json=$(bd_ show "$_twin" --json 2>/dev/null || echo "")
      [ -z "$_twin_json" ] && continue
      _is_delivered=$(printf '%s' "$_twin_json" | jq -r '
        (if type=="array" then .[0] else . end) |
        ( .status == "closed" ) or
        ( (.labels // []) | any(. == "gate:passed" or . == "story:done") )
        | if . then "yes" else "no" end' 2>/dev/null || echo "no")
      if [ "$_is_delivered" = "yes" ]; then
        _dup_twin="$_twin"
        break
      fi
    done
  fi

  if [ -n "$_dup_twin" ]; then
    echo "BLOCKED:$_dup_twin"
  else
    echo "NOT_BLOCKED"
  fi
) > "$_dc9city/s9d.out" 2>/dev/null

_s9d=$(cat "$_dc9city/s9d.out" 2>/dev/null || echo "")
if [ "$_s9d" = "NOT_BLOCKED" ]; then
  ok "9d: find-duplicates failure → FAIL-OPEN, handoff NOT blocked (error safety)"
else
  bad "9d: find-duplicates failure should be fail-open, got: $_s9d"
fi

rm -rf "$_dc9city"

# ── Drift guards for dup-check wiring ─────────────────────────────────────────
echo "Drift guards: dup-check wiring"

if grep -q 'AUTO_REFINO_DUP_CHECK' "$DISPATCHER" \
   && grep -q 'AUTO_REFINO_DUP_THRESHOLD' "$DISPATCHER"; then
  ok "dup-check env vars defined (AUTO_REFINO_DUP_CHECK + AUTO_REFINO_DUP_THRESHOLD)"
else
  bad "dup-check env vars not found in dispatcher"
fi

if grep -q 'find-duplicates --method mechanical' "$DISPATCHER"; then
  ok "dup-check calls find-duplicates --method mechanical"
else
  bad "dup-check does not call find-duplicates --method mechanical"
fi

# Scoped to the dup-block branch itself (not a blanket file grep) — the English
# auto-refino:escalated string already appears elsewhere in the file (PATH B,
# escalate-info-gap), so an unscoped grep would pass even if dup-block itself
# were never fixed. ga-64u1b: dup-block previously set the Portuguese
# auto-refino:escalado (missing final 'd'), which the classifier's
# auto-refino:escalated check (line ~429, English-only) never recognized —
# defeating DUP-BLOCKED's own re-ingestion-loop protection.
_dupblock=$(awk '/if \[ -n "\$_dup_twin" \]/{f=1} f{print} /No delivered twin/{exit}' "$DISPATCHER")
if printf '%s' "$_dupblock" | grep -q 'refino:info-gap' && printf '%s' "$_dupblock" | grep -q 'auto-refino:escalated'; then
  ok "dup-block sets refino:info-gap + auto-refino:escalated labels (ga-64u1b: fixed from the 'escalado' typo)"
else
  bad "dup-block does not set the expected revert labels (refino:info-gap + auto-refino:escalated)"
fi
if printf '%s' "$_dupblock" | grep -q 'auto-refino:escalado\b'; then
  bad "ga-64u1b: dup-block still carries the auto-refino:escalado (Portuguese) typo — defeats the escalated-marker classifier check, re-ingestion loop reproduces"
else
  ok "ga-64u1b: dup-block does not carry the auto-refino:escalado typo"
fi

# The normal handoff bookkeeping (attempt metadata + assignee clear) must be
# wrapped inside the no-dup branch — confirm it appears after the _dup_twin check.
if awk '/if \[ -n "\$_dup_twin" \]/{found=1} found && /No delivered twin/{nf=1} found && nf && /auto_refino_attempts=\$THIS_ATTEMPT/{hit=1} END{exit !hit}' "$DISPATCHER"; then
  ok "normal handoff bookkeeping is inside the no-dup branch"
else
  bad "normal handoff bookkeeping may not be correctly gated by dup-check"
fi

# ── Scenario 10: SPAWN-DRAINED DETECTION (ga-bvbm) ────────────────────────────
# The refiner is an ephemeral …-adhoc-… worker; it can hit the stale_async_start
# race and drain during its OWN startup before ever consuming the queued refine
# task. Step 6 previously had no way to tell that apart from "still working" —
# it just burned the full AUTO_REFINO_TIMEOUT_MINUTES every time (25m default).
# auto_refino_session_drained is the pure detector Step 6 now polls after a
# grace period; prove it directly against gc-session-list-shaped fixtures.
echo "Scenario 10: spawn-drained detection (ga-bvbm) — pure auto_refino_session_drained"

SJ_DRAINED='{"sessions":[{"id":"ga-wisp-x1","session_name":"auto-refiner-adhoc-abc123","state":"asleep","closed":false}]}'
[ "$(auto_refino_session_drained "$SJ_DRAINED" "ga-wisp-x1")" = "yes" ] \
  && ok "adhoc worker asleep (drain-acked) → drained=yes" \
  || bad "adhoc worker asleep → expected drained=yes"

SJ_ACTIVE='{"sessions":[{"id":"ga-wisp-x1","session_name":"auto-refiner-adhoc-abc123","state":"active","closed":false}]}'
[ "$(auto_refino_session_drained "$SJ_ACTIVE" "ga-wisp-x1")" = "no" ] \
  && ok "adhoc worker still active → drained=no (genuinely working, not a false kill)" \
  || bad "adhoc worker active → expected drained=no"

SJ_CLOSED='{"sessions":[{"id":"ga-wisp-x1","session_name":"auto-refiner-adhoc-abc123","state":"active","closed":true}]}'
[ "$(auto_refino_session_drained "$SJ_CLOSED" "ga-wisp-x1")" = "yes" ] \
  && ok "closed session (any state) → drained=yes" \
  || bad "closed session → expected drained=yes"

SJ_NAMEDCREW='{"sessions":[{"id":"ga-wisp-x1","session_name":"thies-wa","state":"asleep","closed":false}]}'
[ "$(auto_refino_session_drained "$SJ_NAMEDCREW" "ga-wisp-x1")" = "no" ] \
  && ok "named (non-adhoc) session asleep → drained=no (an asleep crew is still its bead's owner, ga-mrfb)" \
  || bad "named session asleep → expected drained=no (must not treat asleep crews as dead)"

SJ_OTHERID='{"sessions":[{"id":"ga-wisp-OTHER","session_name":"auto-refiner-adhoc-abc123","state":"asleep","closed":false}]}'
[ "$(auto_refino_session_drained "$SJ_OTHERID" "ga-wisp-x1")" = "no" ] \
  && ok "session id not (yet) in the roster → drained=no (fail open, not a false kill)" \
  || bad "id not in roster → expected drained=no (absence of evidence != evidence of death)"

[ "$(auto_refino_session_drained '{}' 'ga-wisp-x1')" = "no" ] \
  && ok "malformed/empty sessions payload → drained=no (fail open)" \
  || bad "malformed payload → expected drained=no"

[ "$(auto_refino_session_drained 'not json' 'ga-wisp-x1')" = "no" ] \
  && ok "unparseable payload → drained=no (fail open)" \
  || bad "unparseable payload → expected drained=no"

# A new SPAWN_DRAINED outcome token must still land on requeue — proves the
# decision core's existing `*) requeue` catch-all covers it with ZERO changes
# to auto_refino_handoff_decision (ga-flxp6 AC: only handoff/escalate/requeue).
D=$(auto_refino_handoff_decision "SPAWN_DRAINED" 1 3)
[ "$D" = "requeue" ] && ok "SPAWN_DRAINED outcome → requeue (same safe path as TIMEOUT, no attempt burn)" || bad "SPAWN_DRAINED → expected requeue, got '$D'"

# ── Drift guards: spawn-drained wiring (ga-bvbm) ──────────────────────────────
echo "Drift guards: spawn-drained detection wiring"

if grep -qF 'auto_refino_session_drained "$_SESSIONS_JSON" "$SESSION_ID"' "$DISPATCHER"; then
  ok "Step 6 poll loop calls auto_refino_session_drained with the live session roster"
else
  bad "Step 6 does not call auto_refino_session_drained — drained-refiner detection not wired"
fi

if grep -q 'AUTO_REFINO_DRAINED_GRACE_SECONDS' "$DISPATCHER"; then
  ok "grace-period tunable AUTO_REFINO_DRAINED_GRACE_SECONDS is defined"
else
  bad "AUTO_REFINO_DRAINED_GRACE_SECONDS not found — no boot grace period"
fi

# The grace-period comparison must sit just above the drained-check call — a
# session-list lookup on every 30s poll tick (no gate) would be wasteful AND
# risk a false-positive kill against a session still legitimately booting.
_GATE_LN=$(grep -n -F -- '-ge "$AUTO_REFINO_DRAINED_GRACE_SECONDS" ]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
_CALL_LN=$(grep -n -F -- 'auto_refino_session_drained "$_SESSIONS_JSON" "$SESSION_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$_GATE_LN" ] && [ -n "$_CALL_LN" ] && [ "$_CALL_LN" -gt "$_GATE_LN" ] && [ "$_CALL_LN" -le "$((_GATE_LN + 5))" ]; then
  ok "drained check is gated by the grace-period comparison (call sits inside the grace-period if-block)"
else
  bad "drained check does not appear gated by the grace period"
fi

if grep -qF 'session_name missing from' "$DISPATCHER"; then
  ok "empty session_name is logged verbatim for forensics (ga-bvbm suggested next step)"
else
  bad "empty session_name path has no forensic logging"
fi

# ── Drift guards: requeue must not clobber a story that raced past the daemon
#    while the dispatcher was polling (ga-1wc5) ────────────────────────────────
echo "Drift guards: timeout/requeue re-checks CURRENT story state before lifecycle reset (ga-1wc5)"

# The poll loop (Step 6) only watches the TASK bead's outcome:* labels — it never
# re-reads the STORY. So the requeue branch (Step 7) is the last line of defense:
# it must re-read the story and run it back through the SAME classifier the
# GUARANTEE (Scenario 2c) relies on before ever touching lifecycle labels.
if grep -qF 'auto_refino_lifecycle_state "$_rq_labels" "$_rq_assignee" "$AUTO_REFINO_ACTOR"' "$DISPATCHER"; then
  ok "requeue path re-classifies the story's CURRENT labels via the GUARANTEE-backed classifier"
else
  bad "requeue path does not re-check current story state before resetting lifecycle — ga-1wc5 regression"
fi

# Ordering: the re-check must run BEFORE both lifecycle-mutating targets of the
# requeue branch (bounce → refinement-in-progress, fresh → unrefined) — a check
# performed after the reset would be a no-op.
_RQ_CHECK_LN=$(grep -n -F 'auto_refino_lifecycle_state "$_rq_labels" "$_rq_assignee" "$AUTO_REFINO_ACTOR"' "$DISPATCHER" | head -1 | cut -d: -f1)
_RQ_BOUNCE_RESET_LN=$(grep -n -F '_set_lifecycle "$STORY_ID" "story:refinement-in-progress"' "$DISPATCHER" | tail -1 | cut -d: -f1)
_RQ_FRESH_RESET_LN=$(grep -n -F '_set_lifecycle "$STORY_ID" "story:unrefined"' "$DISPATCHER" | tail -1 | cut -d: -f1)
if [ -n "$_RQ_CHECK_LN" ] && [ -n "$_RQ_BOUNCE_RESET_LN" ] && [ -n "$_RQ_FRESH_RESET_LN" ] \
   && [ "$_RQ_CHECK_LN" -lt "$_RQ_BOUNCE_RESET_LN" ] && [ "$_RQ_CHECK_LN" -lt "$_RQ_FRESH_RESET_LN" ]; then
  ok "the re-check precedes both requeue reset targets (bounce and fresh), not an after-the-fact no-op"
else
  bad "the re-check does not precede the requeue lifecycle resets"
fi

# The preserved-lifecycle path must leave an audit trail (comment + log), not
# silently drop the timeout on the floor — same accountability bar as every
# other terminal branch in the dispatcher.
if grep -qF 'lifecycle NOT reset (ga-1wc5)' "$DISPATCHER"; then
  ok "past-daemon requeue is audited (comment/log) instead of silently absorbed"
else
  bad "no audit trail for the preserved-lifecycle requeue branch"
fi

# ── Scenario 11: ga-lfua3 — escalation reaches the human "Sua vez" queue + no loop
# Two confirmed-live bugs:
#  (a) escalate set only auto-refino:escalated, but the painel "Sua vez" column
#      matches _SUAVEZ_LABELS={story:needs-approval, story:refino-escalado}. Without
#      story:refino-escalado the story rendered in TRIAGEM (invisible to Athos).
#      Fix: escalate ALSO adds story:refino-escalado (keeping auto-refino:escalated).
#  (b) re-ingestion loop: an escalated bead carrying only auto-refino:escalated (no
#      story:*) looked RAW and was re-ingested → re-refined → re-escalated. The RAW
#      source must exclude auto-refino:escalated (defense in depth, holds even if the
#      story:* escalation label is later stripped).
echo "Scenario 11: ga-lfua3 — escalation surfaces in 'Sua vez', no re-ingestion loop"
EX="scraper build infra config deploy migration pipeline"
SUAVEZ="story:needs-approval story:refino-escalado"   # painel_visibilidade.py:135

# 11(a). After Fix 1 an escalated story carries story:refino-escalado — which IS a
#        _SUAVEZ_LABELS member, so the painel renders it in the human queue. Assert
#        the post-escalate label set intersects _SUAVEZ_LABELS.
_post_escalate_labels="auto-refino:escalated,story:refino-escalado"
_in_suavez="no"
for _l in $SUAVEZ; do case ",$_post_escalate_labels," in *",$_l,"*) _in_suavez="yes" ;; esac; done
[ "$_in_suavez" = "yes" ] \
  && ok "(a) post-escalate labels carry a _SUAVEZ_LABELS member (story:refino-escalado) → visible in 'Sua vez'" \
  || bad "(a) post-escalate labels do NOT intersect _SUAVEZ_LABELS — escalation stays invisible in TRIAGEM"
# story:refino-escalado must be terminal/skip in the classifier (never re-picked as
# fresh/bounce) even though it is a story:* label.
[ "$(auto_refino_lifecycle_state "auto-refino:escalated,story:refino-escalado" "$ACTOR" "$ACTOR")" = "skip" ] \
  && ok "(a) escalated+story:refino-escalado → skip (terminal, not re-picked)" \
  || bad "(a) escalated+story:refino-escalado → expected skip"
# Belt independent of the daemon marker: even if auto-refino:escalated is stripped,
# story:refino-escalado ALONE must still classify as skip (structural belt).
[ "$(auto_refino_lifecycle_state "story:refino-escalado" "" "$ACTOR")" = "skip" ] \
  && ok "(a) story:refino-escalado alone (escalated marker stripped) → skip (structural belt)" \
  || bad "(a) story:refino-escalado alone → expected skip"

# 11(b). A bead carrying auto-refino:escalated is NOT ingested by the RAW source
#        (loop killed) — the exact ga-m9gt3 shape and the variant where story:* was
#        stripped leaving only the daemon marker.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated" "false" "$EX")" = "no" ] \
  && ok "(b) bead w/ auto-refino:escalated (no story:*) → NOT ingested (loop killed)" \
  || bad "(b) escalated bead → expected NOT ingestable (re-ingestion loop ga-m9gt3 re-forms)"
# After Fix 1 the escalated bead ALSO carries story:refino-escalado (a story:* label),
# so it is doubly non-raw — assert both the has-lifecycle path AND the marker path drop it.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated,story:refino-escalado" "false" "$EX")" = "no" ] \
  && ok "(b) escalated bead + story:refino-escalado → NOT ingested (story:* present AND marker excluded)" \
  || bad "(b) escalated+refino-escalado → expected NOT ingestable"

# 11(c). A genuinely-fresh raw story (no story:*, no escalated marker) IS still
#        ingested — the fix must not over-reject and re-starve the funnel.
[ "$(auto_refino_is_ingestable_raw "ga-fresh2" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "(c) genuine fresh raw story (no story:*, no escalated) → still ingested (no regression)" \
  || bad "(c) genuine raw story → expected ingestable (funnel re-starved)"
[ "$(auto_refino_is_ingestable_raw "ga-fresh3" "story" "" "false" "$EX")" = "yes" ] \
  && ok "(c) bare raw story type, no labels → still ingested" \
  || bad "(c) bare raw story → expected ingestable"

# 11(d). Flag-off path unchanged: AUTO_REFINO_INGEST_RAW_TRIAGEM=0 restores the EXACT
#        prior labelled-input-only behaviour (no RAW source). Assert the dispatcher
#        still gates the 4th source behind the flag and logs the OFF branch.
if grep -qF 'if [ "$AUTO_REFINO_INGEST_RAW_TRIAGEM" = "1" ]; then' "$DISPATCHER" \
   && grep -qF 'Raw-Triagem ingestion OFF' "$DISPATCHER"; then
  ok "(d) RAW ingestion stays gated behind AUTO_REFINO_INGEST_RAW_TRIAGEM (flag-off path unchanged)"
else
  bad "(d) AUTO_REFINO_INGEST_RAW_TRIAGEM flag gate missing — flag-off behaviour changed"
fi

# ── Drift-guard ga-64u1b: PATH A (INFO-GAP) heredoc must add auto-refino:escalated ──
# Bug ga-64u1b (2nd confirmed occurrence, ps-d6xv): PATH A (the spawned refiner's
# INFO-GAP escalation instructions, REFINE_TASK heredoc) stripped every story:*
# lifecycle label and added only refino:info-gap — a label
# auto_refino_is_ingestable_raw() never checks. Unlike PATH B (which explicitly
# re-adds auto-refino:escalated, mirrored a few lines below in this same
# heredoc), PATH A had no equivalent line, so the very next RAW sweep read the
# now label-free story as fresh and re-ingested it, looping the same
# already-answered INFO-GAP verdict forever. The actual bd command is executed
# by the spawned LLM refiner reading this heredoc as a prompt, not by testable
# shell logic — same idiom as the ga-fnnyy guards above: the guarantee here is
# "the instruction ships in the prompt", not "the behavior is unit-testable".
_patha_block=$(awk '/^\[PATH A/{f=1} /^\[PATH B/{f=0} f{print}' "$DISPATCHER")
# ga-78tut: PATH A's label writes now ship as one atomic
# `bd update --add-label ... --remove-label ...` call rather than independent
# `label add`/`label remove` invocations — match either shape.
if printf '%s' "$_patha_block" | grep -qE 'label add "\$STORY_ID" "auto-refino:escalated"|--add-label "auto-refino:escalated"'; then
  ok "ga-64u1b: PATH A (INFO-GAP) heredoc adds auto-refino:escalated (re-ingestion loop killed)"
else
  bad "ga-64u1b: PATH A (INFO-GAP) heredoc does NOT add auto-refino:escalated — re-ingestion loop reproduces"
fi

# Functional companion: once a story carries PATH A's fixed post-escalate label
# set (refino:info-gap + auto-refino:escalated, story:* stripped), it must NOT
# be re-ingestible by the RAW source — mirrors Scenario 11(b)'s PATH B proof.
[ "$(auto_refino_is_ingestable_raw "ga-64u1b-fixed" "feature" "refino:info-gap,auto-refino:escalated" "false" "$EX")" = "no" ] \
  && ok "ga-64u1b: PATH A post-INFO-GAP label set (refino:info-gap+escalated) → NOT ingested (loop killed)" \
  || bad "ga-64u1b: PATH A post-INFO-GAP label set → expected NOT ingestable (re-ingestion loop reproduces)"

# Regression proof: refino:info-gap ALONE (the pre-fix label shape — no escalated
# marker) WAS ingestible — this is exactly why the loop reproduced twice live,
# and guards against a future refactor mistaking that shape for already safe.
[ "$(auto_refino_is_ingestable_raw "ga-64u1b-prefix" "feature" "refino:info-gap" "false" "$EX")" = "yes" ] \
  && ok "ga-64u1b: refino:info-gap ALONE (no escalated marker) is still ingestible — confirms why the marker is required" \
  || bad "ga-64u1b: refino:info-gap alone → expected ingestable (re-check the loop-kill mechanism if this changed)"

# ── Scenario 12: MULTI-STORE funnel (rig-store ingestion fix) ──────────────────
# The daemon must query AND write back to all THREE bead stores (HQ + WA + PS),
# not just HQ, so feature stories living in the whatsapp_automation / property_
# scrapers rig stores are ingested into the refino funnel instead of starving in
# the painel's "Triagem" column forever. Mirrors the proven multi-store shape of
# context-check-dispatcher.sh. These are drift guards + a hermetic iteration proof.
echo ""
echo "── Scenario 12: multi-store funnel (HQ + WA + PS rig stores) ──"

# 12a. AUTO_REFINO_STORES env exists and defaults to the 3 store paths.
if grep -qE '^AUTO_REFINO_STORES="\$\{AUTO_REFINO_STORES:-\$GC_CITY .*whatsapp_automation .*property_scrapers\}"' "$DISPATCHER"; then
  ok "AUTO_REFINO_STORES defaults to HQ + WA + PS store paths"
else
  bad "AUTO_REFINO_STORES env missing or does not default to the 3 store paths"
fi

# 12b. bd_() targets the per-iteration store ($AR_STORE), defaulting to $GC_CITY
#      (so single-store callers / the lib-mode unit tests are unchanged).
if grep -qE 'bd_\(\) \{ bd -C "\$\{AR_STORE:-\$GC_CITY\}" "\$@"; \}' "$DISPATCHER"; then
  ok "bd_() targets \${AR_STORE:-\$GC_CITY} (per-store, HQ-default)"
else
  bad "bd_() does not target the per-iteration store with a GC_CITY fallback"
fi

# 12c. The candidate-gather loop iterates each store.
if grep -qE 'for AR_STORE in \$AUTO_REFINO_STORES' "$DISPATCHER"; then
  ok "candidate gather loops over AUTO_REFINO_STORES"
else
  bad "candidate gather does not iterate AUTO_REFINO_STORES"
fi

# 12d. CRITICAL CORRECTNESS: the refiner task heredoc writes back via $AR_BEAD_STORE
#      (the selected bead's OWN store), NOT $GC_CITY — a WA story's labels/comments
#      must land in the WA store. No bd -C "$GC_CITY" may survive in the heredoc.
if grep -q 'bd -C "$AR_BEAD_STORE"' "$DISPATCHER" \
   && ! grep -q 'bd -C "$GC_CITY"' "$DISPATCHER"; then
  ok "refiner write-back targets the bead's own store (\$AR_BEAD_STORE), never HQ"
else
  bad "refiner heredoc still writes to \$GC_CITY (would land rig-store writes in HQ)"
fi

# 12e. The refiner SESSION spawn stays city-coupled on HQ (gc --city "$GC_CITY"):
#      sessions live in the HQ city; only the bead writes are store-scoped. Mirrors
#      context-check-dispatcher.sh.
if grep -q 'gc --city "$GC_CITY" session new' "$DISPATCHER"; then
  ok "refiner session spawn stays on the HQ city (gc --city \$GC_CITY)"
else
  bad "refiner session spawn no longer uses gc --city \$GC_CITY"
fi

# 12f. HERMETIC iteration proof: point AUTO_REFINO_STORES at TWO temp store dirs and
#      confirm the DRY_RUN sweep visits BOTH (the log emits a per-store header for
#      each). This proves the loop actually iterates every store — the regression
#      that a WA/PS store is now reached, not just HQ. No live Dolt is touched
#      (empty temp dirs → bd list returns [] → harmless DRY_RUN).
_ms_a="$(mktemp -d)"; _ms_b="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_ms_a" AUTO_REFINO_STORES="$_ms_a $_ms_b" DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_msrc=$?
_mslog=$(cat "$_ms_a/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_msrc" -eq 0 ] \
   && echo "$_mslog" | grep -q "candidate store: $_ms_a" \
   && echo "$_mslog" | grep -q "candidate store: $_ms_b"; then
  ok "DRY_RUN sweep iterates every store (both temp stores visited)"
else
  bad "DRY_RUN sweep did not visit all stores (rc=$_msrc; multi-store loop broken)"
fi
rm -rf "$_ms_a" "$_ms_b"

# ── Scenario 13: FIX C — single-instance mkdir-mutex lock ─────────────────────
# WHY: the refiner timeout (25m) >> the launchd interval (~5m), so without a lock
# launchd stacks up to 5 concurrent sweeps, each spawning a Sonnet refiner, blowing
# past the auto-refiner cap (max_active_sessions=3). The lock caps it at ONE live
# sweep. These are drift guards + a live concurrency proof using the DRY_RUN harness.
echo ""
echo "── Scenario 13: FIX C — single-instance lock (refiner-cap protection) ──"

# 13a. Drift guards: the lock primitives exist (mkdir mutex + heartbeat + trap +
#      env kill-switch), mirroring the Pilot's proven shape.
if grep -qF 'AUTO_REFINO_LOCK="${AUTO_REFINO_LOCK:-1}"' "$DISPATCHER"; then
  ok "(C) AUTO_REFINO_LOCK env kill-switch present (defaults ON)"
else
  bad "(C) AUTO_REFINO_LOCK kill-switch missing"
fi
if grep -qF 'mkdir "$AUTO_REFINO_LOCK_DIR"' "$DISPATCHER" \
   && grep -qF "trap '_release_ar_lock' EXIT" "$DISPATCHER"; then
  ok "(C) atomic mkdir mutex + release-on-EXIT trap present (fd-less lock)"
else
  bad "(C) mkdir mutex or release trap missing"
fi
# The lock must live AFTER the lib-mode early-return so sourcing for unit tests
# never acquires it (otherwise the harness above would have left a lock dir / hung).
if awk '/AUTO_REFINO_LIB:-0/{libline=NR} /AUTO_REFINO_LOCK="\$\{AUTO_REFINO_LOCK/{lockline=NR} END{exit !(libline>0 && lockline>libline)}' "$DISPATCHER"; then
  ok "(C) lock block sits AFTER the lib-mode guard (pure-fn sourcing never locks)"
else
  bad "(C) lock block is not strictly after the AUTO_REFINO_LIB early-return"
fi

# 13b. LIVE: a second concurrent sweep BACKS OFF while a fresh lock is held.
#      Pre-create the lock dir with a FRESH heartbeat (age 0) in the temp city's
#      TMPDIR, then run a DRY_RUN sweep — it must find the live holder and exit 0
#      WITHOUT logging a sweep start (mutated nothing).
_lkcity="$(mktemp -d)"; _lktmp="$(mktemp -d)"
# Reconstruct the lock-dir path the dispatcher computes for this GC_CITY.
_lk_san="$(printf '%s' "$_lkcity" | tr '/ ' '__')"
_lk_dir="$_lktmp/auto-refino-dispatcher${_lk_san}.lock.d"
mkdir -p "$_lk_dir"
printf 'someoneelse:999\n' > "$_lk_dir/heartbeat"   # fresh mtime = live holder
TMPDIR="$_lktmp" AUTO_REFINO_CITY_OVERRIDE="$_lkcity" AUTO_REFINO_STORES="$_lkcity" DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_lkrc=$?
_lklog=$(cat "$_lkcity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_lkrc" -eq 0 ] \
   && echo "$_lklog" | grep -qiF 'backing off (single-instance guard' \
   && ! echo "$_lklog" | grep -qiE 'Auto-refino sweep start'; then
  ok "(C) second concurrent sweep BACKS OFF on a fresh lock (no second refiner; cap protected)"
else
  bad "(C) second sweep did not back off on a held lock (rc=$_lkrc) — 5-vs-3 stacking not prevented"
fi
# The live holder's lock dir must be untouched (the backing-off sweep owns nothing).
[ -d "$_lk_dir" ] && ok "(C) live holder's lock dir left intact (back-off mutated nothing)" \
                  || bad "(C) back-off clobbered the live holder's lock dir"
rm -rf "$_lkcity" "$_lktmp"

# 13c. LIVE: a STALE lock (heartbeat mtime older than MAX_AGE) is RECLAIMED — the
#      sweep takes over and proceeds (so a crashed sweep can't wedge refino forever).
_skcity="$(mktemp -d)"; _sktmp="$(mktemp -d)"
_sk_san="$(printf '%s' "$_skcity" | tr '/ ' '__')"
_sk_dir="$_sktmp/auto-refino-dispatcher${_sk_san}.lock.d"
mkdir -p "$_sk_dir"
printf 'deadholder:111\n' > "$_sk_dir/heartbeat"
# Age the heartbeat far past any MAX_AGE (set a tiny MAX_AGE to make it stale).
touch -t 200001010000 "$_sk_dir/heartbeat" 2>/dev/null || true
TMPDIR="$_sktmp" AUTO_REFINO_CITY_OVERRIDE="$_skcity" AUTO_REFINO_STORES="$_skcity" \
  AUTO_REFINO_LOCK_MAX_AGE=5 DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_skrc=$?
_sklog=$(cat "$_skcity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_skrc" -eq 0 ] \
   && echo "$_sklog" | grep -qiF 'Recovered STALE auto-refino lock' \
   && echo "$_sklog" | grep -qiE 'Auto-refino sweep start'; then
  ok "(C) STALE lock RECLAIMED — sweep takes over and proceeds (crashed sweep can't wedge refino)"
else
  bad "(C) stale lock not reclaimed (rc=$_skrc) — a dead holder would wedge the funnel"
fi
rm -rf "$_skcity" "$_sktmp"

# 13d. Kill-switch: AUTO_REFINO_LOCK=0 runs the sweep even with a fresh lock held
#      (exact prior behaviour; the guard is fully bypassable).
_kscity="$(mktemp -d)"; _kstmp="$(mktemp -d)"
_ks_san="$(printf '%s' "$_kscity" | tr '/ ' '__')"
_ks_dir="$_kstmp/auto-refino-dispatcher${_ks_san}.lock.d"
mkdir -p "$_ks_dir"; printf 'held:1\n' > "$_ks_dir/heartbeat"
TMPDIR="$_kstmp" AUTO_REFINO_CITY_OVERRIDE="$_kscity" AUTO_REFINO_STORES="$_kscity" \
  AUTO_REFINO_LOCK=0 DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_kslog=$(cat "$_kscity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if echo "$_kslog" | grep -qiE 'Auto-refino sweep start' \
   && ! echo "$_kslog" | grep -qiF 'backing off (single-instance guard'; then
  ok "(C) AUTO_REFINO_LOCK=0 bypasses the guard (sweep runs despite a held lock — prior behaviour)"
else
  bad "(C) kill-switch did not bypass the lock"
fi
rm -rf "$_kscity" "$_kstmp"

# ── Scenario 14: FIX B — cross-stage contention-yield ─────────────────────────
# WHY: refino is the LOWEST stage and must yield to a congested gate / waiting Pilot
# when resources are contended, but NEVER serialize pointlessly when resources are
# free (anti-starvation). Drift guards + live behavioural proofs via the override
# test seams (no live gate/Dolt/quota touched).
echo ""
echo "── Scenario 14: FIX B — cross-stage contention-yield (anti-starvation) ──"

# 14a. Drift guards: the yield gate + its env kill-switch + the four probes exist,
#      mirroring the Pilot's ga-d0hz3 shape.
if grep -qF 'AUTO_REFINO_YIELD="${AUTO_REFINO_YIELD:-1}"' "$DISPATCHER"; then
  ok "(B) AUTO_REFINO_YIELD env kill-switch present (defaults ON)"
else
  bad "(B) AUTO_REFINO_YIELD kill-switch missing"
fi
if grep -q '_ar_quota_limited()' "$DISPATCHER" && grep -q '_ar_dolt_hot()' "$DISPATCHER" \
   && grep -q '_ar_gate_congested()' "$DISPATCHER" && grep -q '_ar_pilot_has_work()' "$DISPATCHER"; then
  ok "(B) all four contention probes defined (quota / dolt / gate / pilot-work)"
else
  bad "(B) a contention probe is missing"
fi
# The yield must defer (exit) only under (higher-stage-work AND resource-tight).
if grep -qF '_yield_resource_tight=1' "$DISPATCHER" \
   && grep -qF 'DEFERRING refino this sweep' "$DISPATCHER"; then
  ok "(B) defer is conditional on resource-tight AND higher-stage work (anti-starvation gate)"
else
  bad "(B) defer condition not wired as resource-tight AND higher-stage-work"
fi

# 14b. LIVE DEFER: gate congested + quota limited → the sweep DEFERS, mutating
#      nothing (no claim, no spawn) and logging the yield. Driven purely by seams.
_ydcity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_ydcity" AUTO_REFINO_STORES="$_ydcity" DRY_RUN=1 \
  AUTO_REFINO_QUOTA_OVERRIDE=2 AUTO_REFINO_GATE_CONGESTED_OVERRIDE=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_ydrc=$?
_ydlog=$(cat "$_ydcity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_ydrc" -eq 0 ] \
   && echo "$_ydlog" | grep -qiF 'sweep deferred (cross-stage yield' \
   && ! echo "$_ydlog" | grep -qiF 'candidate store:'; then
  ok "(B) DEFERS when gate-congested + quota-limited (no candidate gather, mutated nothing)"
else
  bad "(B) did not defer under gate-congested + quota-limited (rc=$_ydrc)"
fi
rm -rf "$_ydcity"

# 14c. LIVE DEFER via the PILOT arm: pilot-has-work + Dolt hot → DEFERS (proves the
#      'higher stage has work' disjunct covers the Pilot, not just the gate).
_ypcity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_ypcity" AUTO_REFINO_STORES="$_ypcity" DRY_RUN=1 \
  AUTO_REFINO_DOLT_CPU_OVERRIDE=999 AUTO_REFINO_DOLT_LATENCY_OVERRIDE_MS=9999 \
  AUTO_REFINO_GATE_CONGESTED_OVERRIDE=0 AUTO_REFINO_PILOT_WORK_OVERRIDE=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_yplog=$(cat "$_ypcity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if echo "$_yplog" | grep -qiF 'sweep deferred (cross-stage yield'; then
  ok "(B) DEFERS when Pilot has approved work + Dolt hot (pilot disjunct works)"
else
  bad "(B) did not defer under pilot-has-work + Dolt hot"
fi
rm -rf "$_ypcity"

# 14d. ANTI-STARVATION (resources FREE): gate congested but quota OK + Dolt calm →
#      MUST NOT defer. A calm, quota-OK moment always runs refino even with a busy
#      gate. The sweep proceeds to the candidate gather (logs a candidate-store header).
_yfcity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_yfcity" AUTO_REFINO_STORES="$_yfcity" DRY_RUN=1 \
  AUTO_REFINO_QUOTA_OVERRIDE=0 AUTO_REFINO_DOLT_CPU_OVERRIDE=5 AUTO_REFINO_DOLT_LATENCY_OVERRIDE_MS=10 \
  AUTO_REFINO_GATE_CONGESTED_OVERRIDE=1 AUTO_REFINO_PILOT_WORK_OVERRIDE=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_yfrc=$?
_yflog=$(cat "$_yfcity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_yfrc" -eq 0 ] \
   && ! echo "$_yflog" | grep -qiF 'sweep deferred (cross-stage yield' \
   && echo "$_yflog" | grep -qiF 'candidate store:'; then
  ok "(B) ANTI-STARVATION: resources FREE (quota OK + Dolt calm) → does NOT defer, refines (even w/ busy gate)"
else
  bad "(B) deferred when resources were free — anti-starvation violated (rc=$_yfrc)"
fi
rm -rf "$_yfcity"

# 14e. FAIL-OPEN: a blind Dolt probe (no signal) resolves to NOT-hot, and with quota
#      OK the sweep proceeds (a daemon that can't read Dolt keeps refining, never
#      wedges). Drive resource_tight off by leaving all seams unset but quota OK,
#      gate congested — must NOT defer (resources not tight ⇒ skip higher-stage probe).
_fecity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_fecity" AUTO_REFINO_STORES="$_fecity" DRY_RUN=1 \
  AUTO_REFINO_QUOTA_OVERRIDE=0 AUTO_REFINO_GATE_CONGESTED_OVERRIDE=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_ferc=$?
_felog=$(cat "$_fecity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if [ "$_ferc" -eq 0 ] && ! echo "$_felog" | grep -qiF 'sweep deferred (cross-stage yield'; then
  ok "(B) FAIL-OPEN: blind Dolt probe → not-hot; quota OK ⇒ no defer (funnel never wedged)"
else
  bad "(B) blind probe wedged the sweep / deferred without contention (rc=$_ferc)"
fi
rm -rf "$_fecity"

# 14f. Kill-switch: AUTO_REFINO_YIELD=0 disables the gate (no defer even when
#      gate-congested + quota-limited — exact prior behaviour).
_ykcity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_ykcity" AUTO_REFINO_STORES="$_ykcity" DRY_RUN=1 \
  AUTO_REFINO_YIELD=0 AUTO_REFINO_QUOTA_OVERRIDE=2 AUTO_REFINO_GATE_CONGESTED_OVERRIDE=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_yklog=$(cat "$_ykcity/.gc/logs/auto-refino-dispatcher.log" 2>/dev/null || echo "")
if ! echo "$_yklog" | grep -qiF 'sweep deferred (cross-stage yield'; then
  ok "(B) AUTO_REFINO_YIELD=0 bypasses the yield gate (prior behaviour)"
else
  bad "(B) kill-switch did not bypass the yield gate"
fi
rm -rf "$_ykcity"

# ── Scenario 15: hold-label guard — RAW sweep must not override another ───────
# authority's explicit hold (bug ga-268cr). 6 confirmed same-day occurrences
# (2026-07-17, whatsapp_automation store) of the RAW Triagem source re-ingesting
# a story an authority (Oracle/Mayor/a builder) had deliberately parked.
# Occurrences 2 (wa-5b6yw) and 3 (wa-gunqu) carried blocked:needs-oracle-approval;
# occurrence 5 (wa-ic45e, worst — a builder had REFUSED to implement on ban-risk
# grounds and the Oracle formally deferred) carried blocked-on:wa-4e2m8,
# blocked-on:wa-qfp58, blocked:needs-oracle-approval AND
# pool:refused:deferred-by-plan-v6 simultaneously. Verified directly against the
# live code (not from memory, 2026-07-17) that NEITHER layer (is_ingestable_raw
# NOR the RAW_JSON jq filter) checked blocked:*, needs-human*, pilot:held*,
# blocked-on:*, or pool:refused:* before this fix. blocked-on: is a DISTINCT
# hyphenated prefix from blocked: (not a typo — a blocked:* guard alone does not
# match it), and pilot:held can carry a -until:<epoch> suffix (mirrors the
# dog-pool probe's own startswith("pilot:held") precedent) that a bare
# exact-match would miss.
EX="scraper build infra config deploy migration pipeline"
echo "Scenario 15: hold-label guard — active hold from another authority blocks RAW ingestion (bug ga-268cr)"
[ "$(auto_refino_is_ingestable_raw "wa-5b6yw" "feature" "blocked:needs-oracle-approval" "false" "$EX")" = "no" ] \
  && ok "blocked:needs-oracle-approval (occurrence 2) → no (Mayor's hold respected)" \
  || bad "blocked:* label → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-x1" "feature" "needs-human" "false" "$EX")" = "no" ] \
  && ok "needs-human (bare) → no" \
  || bad "needs-human bare → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-x2" "feature" "needs-human-priority" "false" "$EX")" = "no" ] \
  && ok "needs-human-priority (prefixed variant) → no (prefix match, not exact-only)" \
  || bad "needs-human-priority → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-x3" "feature" "pilot:held" "false" "$EX")" = "no" ] \
  && ok "pilot:held (bare) → no" \
  || bad "pilot:held bare → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-x4" "feature" "pilot:held-until:1784315109" "false" "$EX")" = "no" ] \
  && ok "pilot:held-until:<epoch> (timed variant) → no (prefix match catches the suffix form too)" \
  || bad "pilot:held-until:* → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-qfp58-blocker" "feature" "blocked-on:wa-qfp58" "false" "$EX")" = "no" ] \
  && ok "blocked-on:wa-qfp58 (occurrence 5, hyphenated prefix) → no" \
  || bad "blocked-on:* → expected no"
[ "$(auto_refino_is_ingestable_raw "wa-x5" "feature" "pool:refused:deferred-by-plan-v6" "false" "$EX")" = "no" ] \
  && ok "pool:refused:deferred-by-plan-v6 (occurrence 5) → no" \
  || bad "pool:refused:* → expected no"
# The exact wa-ic45e regression: all four hold labels the Oracle actually set,
# simultaneously — the 5th and worst occurrence (a builder had already REFUSED
# on ban-risk grounds; RAW ingested it anyway as attempt 2).
[ "$(auto_refino_is_ingestable_raw "wa-ic45e" "feature" "blocked-on:wa-4e2m8,blocked-on:wa-qfp58,blocked:needs-oracle-approval,pool:refused:deferred-by-plan-v6" "false" "$EX")" = "no" ] \
  && ok "wa-ic45e exact regression shape (4 hold labels at once) → no (5th occurrence cannot re-form)" \
  || bad "wa-ic45e regression shape → expected no"
# Anchoring: a label that merely CONTAINS "blocked" as a substring but is not
# actually hold-prefixed (comma-bounded false-positive check) must NOT trip the
# guard — the csv comma-wrap anchors prefix matches to real label boundaries.
[ "$(auto_refino_is_ingestable_raw "wa-x6" "feature" "unblocked-reason,frontend" "false" "$EX")" = "yes" ] \
  && ok "unblocked-reason (near-miss substring, not a real hold label) → yes (no false-positive over-reject)" \
  || bad "near-miss substring label → expected yes (funnel over-rejected)"
# Regression: a genuinely raw story with none of these labels is still ingested.
[ "$(auto_refino_is_ingestable_raw "wa-fresh4" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "genuine raw story (no hold label) → still yes (funnel not starved)" \
  || bad "genuine raw story → expected yes"

# 15b. Drift-guard: BOTH layers (RAW_JSON jq filter AND the is_ingestable_raw
#      classifier) must carry the new hold-label guard — defense in depth,
#      mirrors drift-guard 0d's structure for the escalated-story guard above.
if grep -qF 'startswith("blocked-on:")' "$DISPATCHER" \
   && grep -qF 'startswith("pool:refused:")' "$DISPATCHER" \
   && grep -qF '*,blocked-on:*' "$DISPATCHER" \
   && grep -qF '*,pool:refused:*' "$DISPATCHER"; then
  ok "15b. hold-label guard present in BOTH the RAW jq filter and is_ingestable_raw classifier (bug ga-268cr)"
else
  bad "15b. hold-label guard missing from jq filter or classifier — occurrences 2/3/5 can re-form"
fi

# ── Scenario 16: already-claimed/already-split/already-escalated RAW beads are
#    NOT swallowed as fresh ideas (bug ga-blron: 3+ occurrences in one day —
#    wa-ngn08/wa-4uh2w lost their dispatch entirely; wa-ku5j1 was asked to
#    approve a split that was already decided AND already delivered [all 4
#    children closed], then RE-ingested a 4th time despite carrying escalation
#    labels). is_ingestable_raw gained two new OPTIONAL trailing params
#    (assignee, has_children) — every prior call site above (Scenarios
#    4c/4d/11/15) omits them and must stay green (backward-compat proof).
EX="scraper build infra config deploy migration pipeline"
echo "Scenario 16: claimed/split/escalated RAW beads are excluded (bug ga-blron)"

# (a) assignee non-empty → excluded (occurrences 1-3 shape: assignee still set
#     at the moment of ingestion).
[ "$(auto_refino_is_ingestable_raw "wa-ngn08" "feature" "frontend" "false" "$EX" "" "" "mila-wa")" = "no" ] \
  && ok "(a) assignee filled (mila-wa) → no (already claimed, not an orphan idea)" \
  || bad "(a) assignee filled → expected no"
[ "$(auto_refino_is_ingestable_raw "ga-fresh5" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "(a) assignee param omitted → yes (backward-compat default, funnel not starved)" \
  || bad "(a) omitted assignee → expected yes"

# (b) has_children="yes" → excluded. Mirrors the wa-ku5j1 3rd-occurrence shape
#     where assignee was ALREADY CLEARED by the lifecycle-coherence-janitor R4
#     rule before this sweep ran — assignee alone (a) is NOT enough here,
#     has_children must independently exclude it.
[ "$(auto_refino_is_ingestable_raw "wa-ku5j1" "feature" "frontend" "false" "$EX" "" "" "" "yes")" = "no" ] \
  && ok "(b) has_children=yes, assignee EMPTY (wa-ku5j1 shape, janitor already cleared it) → no (already split)" \
  || bad "(b) has_children=yes → expected no (wa-ku5j1 regression would re-form)"
[ "$(auto_refino_is_ingestable_raw "wa-upd15" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "(b) has_children param omitted (wa-upd15, 0 children) → yes (no false-positive over-reject)" \
  || bad "(b) omitted has_children → expected yes"
[ "$(auto_refino_is_ingestable_raw "wa-upd15" "feature" "frontend" "false" "$EX" "" "" "" "no")" = "yes" ] \
  && ok "(b) has_children=no explicit (wa-upd15) → yes" \
  || bad "(b) has_children=no explicit → expected yes"
# has_children/assignee guards are independent of the age guard — a freshly
# mutated (age=0 < floor=5) bead with children is still excluded for HAVING
# children, not merely admitted because it also happens to pass the age check
# (mirrors the escalated+aged independence check in Scenario 4d).
[ "$(auto_refino_is_ingestable_raw "wa-ku5j1" "feature" "frontend" "false" "$EX" "0" "5" "" "yes")" = "no" ] \
  && ok "(d) has_children=yes + freshly-mutated (age=0 < floor=5) → still no (children guard independent of age)" \
  || bad "(d) has_children+fresh-age → expected no"

# (c) refino:policy-gap label → excluded (occurrence 4: wa-ku5j1 was
#     RE-ingested at 22:11:43Z despite already carrying this label — the
#     cheapest, first-line-of-defense signal after live-measuring occurrence 4).
[ "$(auto_refino_is_ingestable_raw "wa-ku5j1" "feature" "refino:policy-gap" "false" "$EX")" = "no" ] \
  && ok "(c) refino:policy-gap label alone → no (already escalated by refino itself, re-ask loop killed)" \
  || bad "(c) refino:policy-gap → expected no (4th occurrence would re-form)"
[ "$(auto_refino_is_ingestable_raw "wa-ku5j1" "feature" "gate:needs-human:product,refino:policy-gap,auto-refino:escalated" "false" "$EX")" = "no" ] \
  && ok "(c) full 4th-occurrence label shape (gate:*+refino:policy-gap+escalated) → no" \
  || bad "(c) 4th-occurrence label shape → expected no"

# Regression: a genuinely orphan, childless, unescalated raw story is STILL
# ingested — the starvation the RAW-ingestion fix originally solved must not
# return (falsification required in this direction too, per the story bead).
[ "$(auto_refino_is_ingestable_raw "ga-fresh6" "feature" "frontend" "false" "$EX" "" "" "" "no")" = "yes" ] \
  && ok "genuine orphan raw story (no assignee, no children, no escalation) → still yes (funnel not starved)" \
  || bad "genuine orphan raw story → expected yes (starvation regression)"

# 16b. Drift-guard: assignee + refino:policy-gap are mirrored in BOTH the RAW
#      jq filter and the classifier (defense in depth, same structure as 15b).
#      has_children/has_refino_metadata are classifier-ONLY by design (jq
#      cannot shell out to `bd children`/`bd show`) — assert the
#      classification loop actually wires BOTH through.
if grep -qF 'map(select(((.assignee // "") | length) == 0))' "$DISPATCHER" \
   && grep -qF 'any(. == "refino:policy-gap")) | not' "$DISPATCHER" \
   && grep -qF '*,refino:policy-gap,*) echo "no"' "$DISPATCHER" \
   && grep -qF 'bd_ children "$c_id" --json' "$DISPATCHER" \
   && grep -qF 'bd_ show "$c_id" --json' "$DISPATCHER" \
   && grep -qF '"$c_assignee" "$c_has_children" "$c_has_refino_metadata")' "$DISPATCHER"; then
  ok "16b. claimed/split/escalated guard present in jq filter (assignee+policy-gap) AND classifier (all 3 + has_children + has_refino_metadata wiring) (bug ga-blron, ga-mk6ve)"
else
  bad "16b. claimed/split/escalated guard missing from jq filter or classifier wiring — occurrences 1-4 (or the 9th, ga-mk6ve) can re-form"
fi

# ── Scenario 17: POLICY-GAP escalations stamp an Epic Split Convention
#    reminder, so a split executed comment-only (bug ga-8bjhl, wa-pxvox: 3
#    children created via free-text comment + sibling `blocks` deps, no
#    --parent, no story:epic-split) doesn't defeat BOTH of
#    is_ingestable_raw's existing defenses (story:* label check +
#    has_children — see Scenario 16b). The reminder is stamped in
#    DETERMINISTIC bash on every escalate — same fix shape as the
#    story:needs-human stamp (ga-xdukc/ga-hd87d) — not left to the refiner's
#    own best-effort LLM comment.
echo "Scenario 17: escalate stamps the Epic Split Convention reminder (bug ga-8bjhl)"

if grep -qF 'Lembrete (bug ga-8bjhl)' "$DISPATCHER" \
   && grep -qF 'story:epic-split' "$DISPATCHER" \
   && grep -qF -- '--parent $STORY_ID --label story:unrefined --no-inherit-labels' "$DISPATCHER"; then
  ok "17. escalate path stamps the Epic Split Convention reminder (story:epic-split + --parent) (bug ga-8bjhl)"
else
  bad "17. escalate path missing the ga-8bjhl split-convention reminder"
fi

# 17b. Drift-guard: the reminder must run UNCONDITIONALLY, at the same
#      line-position class as the story:needs-human stamp right above it —
#      NOT nested inside the OUTCOME!=ESCALATE budget-exhaustion branch,
#      which would mean POLICY-GAP escalations (OUTCOME=ESCALATE, the one
#      case this bug actually needs it for) never see it.
_reminder_line=$(grep -nF 'Lembrete (bug ga-8bjhl)' "$DISPATCHER" | head -1 | cut -d: -f1)
_outcome_if_line=$(grep -nF 'if [ "$OUTCOME" != "ESCALATE" ]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$_reminder_line" ] && [ -n "$_outcome_if_line" ] && [ "$_reminder_line" -lt "$_outcome_if_line" ]; then
  ok "17b. reminder fires BEFORE the OUTCOME!=ESCALATE branch — reaches POLICY-GAP escalations, not just budget-exhaustion"
else
  bad "17b. reminder is gated behind OUTCOME!=ESCALATE (or missing) — POLICY-GAP escalations would never see it"
fi

# ── Scenario 18: positive already-refined signal — a bead already carrying
#    real refino output (story.refino_mode / story.refino_gate_rounds /
#    story.criterios metadata) is NOT raw, independent of current label state
#    (bug ga-mk6ve, 9th confirmed re-ingestion). ga-m3n1x was refined
#    simplificado, gate-approved, and Athos-approved TWICE — then a human
#    clearing block labels via the painel zeroed every story:* tag and the RAW
#    sweep re-ingested it as if it were a brand-new Triagem idea, even though
#    its refino metadata was intact the entire time. Every PRIOR fix in this
#    function (occurrences 1-8) enumerated a specific label/mechanism that
#    zeroed labels; this is the first check that does not depend on labels at
#    all. has_refino_metadata is a NEW OPTIONAL trailing (10th) param, same
#    backward-compat convention as has_children directly above — every prior
#    call site in this file (Scenarios 1-17) omits it and must stay green.
EX="scraper build infra config deploy migration pipeline"
echo "Scenario 18: already-refined metadata excludes RAW re-ingestion (bug ga-mk6ve)"

# (e) the exact ga-m3n1x 9th-occurrence shape: zero story:* labels (painel
#     manual unblock cleared them all) but has_refino_metadata=yes → no.
[ "$(auto_refino_is_ingestable_raw "ga-m3n1x" "feature" "" "false" "$EX" "" "" "" "" "yes")" = "no" ] \
  && ok "(e) has_refino_metadata=yes, zero story:* labels (ga-m3n1x 9th-occurrence shape) → no (already refined, not raw)" \
  || bad "(e) has_refino_metadata=yes → expected no (9th occurrence would re-form)"
[ "$(auto_refino_is_ingestable_raw "ga-fresh7" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "(e) has_refino_metadata param omitted → yes (backward-compat default, funnel not starved)" \
  || bad "(e) omitted has_refino_metadata → expected yes"
[ "$(auto_refino_is_ingestable_raw "ga-fresh7" "feature" "frontend" "false" "$EX" "" "" "" "no" "no")" = "yes" ] \
  && ok "(e) has_refino_metadata=no explicit → yes" \
  || bad "(e) has_refino_metadata=no explicit → expected yes"

# (f) the metadata guard excludes even when EVERY other guard would
#     independently pass — isolates that this is its own, new gate, not a
#     side effect of the age/assignee/children checks (age 10 >= floor 5
#     passes on its own; has_refino_metadata=yes must still force "no").
[ "$(auto_refino_is_ingestable_raw "ga-m3n1x" "feature" "" "false" "$EX" "10" "5" "" "no" "yes")" = "no" ] \
  && ok "(f) has_refino_metadata=yes even though the age guard independently passes (10>=5) → no (metadata guard is its own gate)" \
  || bad "(f) has_refino_metadata isolated from age guard → expected no"

# Regression: a genuinely raw story with no refino metadata is STILL ingested
# — the starvation the RAW-ingestion fix originally solved must not return.
[ "$(auto_refino_is_ingestable_raw "ga-fresh8" "feature" "frontend" "false" "$EX" "" "" "" "no" "no")" = "yes" ] \
  && ok "genuine orphan raw story (no refino metadata) → still yes (funnel not starved)" \
  || bad "genuine orphan raw story (no refino metadata) → expected yes (starvation regression)"

# 18b. Drift-guard: the param, its gate check, the bd-show metadata predicate
#      (all 3 keys), and the caller-side computation are all wired through —
#      same structure as 16b/17b above.
if grep -qF 'has_refino_metadata="${10:-no}"' "$DISPATCHER" \
   && grep -qF '[ "$has_refino_metadata" = "yes" ] && { echo "no"; return; }' "$DISPATCHER" \
   && grep -qF 'story.refino_mode' "$DISPATCHER" \
   && grep -qF 'story.refino_gate_rounds' "$DISPATCHER" \
   && grep -qF 'story.criterios' "$DISPATCHER" \
   && grep -qF 'c_has_refino_metadata="no"' "$DISPATCHER" \
   && grep -qF 'bd_ show "$c_id" --json' "$DISPATCHER"; then
  ok "18b. has_refino_metadata param + gate check + bd-show metadata predicate + caller computation all present (bug ga-mk6ve)"
else
  bad "18b. has_refino_metadata wiring incomplete — 9th occurrence (ga-m3n1x) can re-form"
fi

# ── Scenario 19 (bug ga-9mfnw): SPLIT — an already-resolved policy-gap
#    escalation, executed by the refiner as an epic split, is its own
#    terminal decision — distinct from handoff/escalate. Before this fix the
#    vocabulary had no SPLIT token: REFINED would misfire (the dispatcher's
#    unconditional `bd update --type feature` would revert the --type epic
#    the refiner had just applied) and ESCALATE would misfire (re-paging
#    Mayor for a decision already made and executed). The live mitigation
#    (attempt 2 on ga-sb11i) sidestepped both by using a label the poll loop
#    didn't recognize at all — safe by accident (falls through to TIMEOUT →
#    requeue), but silent and undocumented. This scenario proves the real
#    fix: the vocabulary, the poll wiring, the Step 7 branch's two
#    invariants (no --type flip, no Mayor mail), and the heredoc guidance
#    that lets a refiner report SPLIT deliberately instead of inventing it.
echo "Scenario 19 (ga-9mfnw): SPLIT — already-resolved policy-gap executed as an epic split"
D=$(auto_refino_handoff_decision "SPLIT" 1 3)
[ "$D" = "split" ] && ok "SPLIT attempt 1 → split" || bad "SPLIT → expected split, got '$D'"
D=$(auto_refino_handoff_decision "SPLIT" 9 3)
[ "$D" = "split" ] && ok "SPLIT beyond the attempt budget → still split (terminal, no gate-bounce analog, no cap)" || bad "SPLIT beyond budget → expected split, got '$D'"

# 19b. Drift-guard: the Step 6 poll loop actually recognizes outcome:SPLIT —
#      else it falls through to TIMEOUT/requeue, the exact silent-mitigation
#      shape the bug reported.
if grep -qF 'grep -q "outcome:SPLIT"' "$DISPATCHER" \
   && grep -qF 'OUTCOME="SPLIT"; break' "$DISPATCHER"; then
  ok "19b. Step 6 poll loop recognizes outcome:SPLIT (breaks immediately, not just at TIMEOUT)"
else
  bad "19b. Step 6 poll loop does not recognize outcome:SPLIT — falls through to TIMEOUT/requeue (ga-9mfnw regression)"
fi

# 19c. Drift-guard: the Step 7 'split' branch exists and does NOT flip
#      --type (would revert the refiner's own epic conversion) and does NOT
#      mail Mayor (the decision was already made and executed — nothing
#      left for a human to do). Isolate the branch's OWN source lines
#      (between 'split)' and the next top-level case arm) rather than
#      grepping the whole file — the escalate branch right above it
#      deliberately DOES both, so a whole-file grep would false-pass by
#      matching the WRONG branch.
_split_branch=$(awk '/^  split\)$/{flag=1} flag{print} /^  requeue\|\*\)$/{if(flag)exit}' "$DISPATCHER")
if [ -n "$_split_branch" ] && printf '%s' "$_split_branch" | grep -qF 'outcome SPLIT registrado'; then
  ok "19c. Step 7 split branch is present"
else
  bad "19c. Step 7 split branch missing or unrecognizable"
fi
# Match the actual dangerous SHAPE (an update call carrying --type), not the
# bare substring — the branch's own explanatory comments and audit-comment
# string legitimately discuss "--type" in prose (documenting that it does
# NOT touch it), and a naive substring match on those is a false positive.
if printf '%s' "$_split_branch" | grep -qF 'update "$STORY_ID" --type'; then
  bad "19c. split branch touches --type — would revert the refiner's own epic conversion (ga-9mfnw)"
else
  ok "19c. split branch does NOT touch --type (epic conversion preserved)"
fi
if printf '%s' "$_split_branch" | grep -qF 'mail send mayor'; then
  bad "19c. split branch mails Mayor — re-pages a decision already made and executed (ga-9mfnw)"
else
  ok "19c. split branch does NOT mail Mayor (decision already made and executed)"
fi

# 19d. Drift-guard: the REFINE_TASK heredoc teaches the refiner to check for
#      an already-resolved escalation FIRST and report it via outcome:SPLIT
#      (PATH C) instead of inventing a label — the gap ga-9mfnw's suggestion
#      2 flagged (the heredoc used to only teach REFINE vs ESCALATE).
if grep -qF 'FIRST — check whether this story is a RE-ATTEMPT on an ALREADY-RESOLVED' "$DISPATCHER" \
   && grep -qF '[PATH C — SPLIT:' "$DISPATCHER" \
   && grep -qF 'outcome:SPLIT"' "$DISPATCHER"; then
  ok "19d. REFINE_TASK heredoc teaches the refiner the SPLIT report-back path (PATH C, ga-9mfnw)"
else
  bad "19d. REFINE_TASK heredoc missing the SPLIT pre-check / PATH C — refiner still has to invent the mitigation"
fi

echo ""
echo "auto-refino-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
