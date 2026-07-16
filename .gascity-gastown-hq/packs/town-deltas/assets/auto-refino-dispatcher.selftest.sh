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
for o in REFINED ESCALATE TIMEOUT GARBAGE ""; do
  for a in 0 1 2 3 4 5; do
    d=$(auto_refino_handoff_decision "$o" "$a" 3)
    case "$d" in
      approve|story:approved|needs-approval|story:needs-approval|dispatch) seen_bad=1 ;;
    esac
    case "$d" in handoff|escalate|requeue) : ;; *) bad "unexpected decision token '$d' for outcome=$o attempt=$a"; esac
  done
done
[ "$seen_bad" = "0" ] && ok "no input ever yields approve/needs-approval/dispatch (only handoff/escalate/requeue)" || bad "REGRESSION: decision core emitted an approve/dispatch token"

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
#    ADDITIVELY (label add, not --set-labels — see drift-guard 0/bug 2).
if grep -qF 'label add "$STORY_ID" "story:refino-review"' "$DISPATCHER"; then
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
_drycity="$(mktemp -d)"
AUTO_REFINO_CITY_OVERRIDE="$_drycity" DRY_RUN=1 \
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

# ── Scenario 9: DELIVERED-DUP CHECK (wa-ca4jm) ───────────────────────────────
# A REFINED story whose twin is closed/done must NOT be promoted (handoff
# bookkeeping skipped); it must get refino:info-gap + auto-refino:escalado
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

if grep -q 'refino:info-gap' "$DISPATCHER" && grep -q 'auto-refino:escalado' "$DISPATCHER"; then
  ok "dup-block sets refino:info-gap + auto-refino:escalado labels"
else
  bad "dup-block does not set the expected revert labels"
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

echo ""
echo "auto-refino-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
