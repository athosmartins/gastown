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
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow the harness to be pointed at a COPY of the dispatcher under review while
# still pinning the plist / agent.toml drift-guards at the REAL deployed assets
# (the copy may live in /tmp where the relative ../../../agents path does not
# resolve). Defaults preserve the original in-place behaviour.
DISPATCHER="${AUTO_REFINO_DISPATCHER:-$SELF_DIR/auto-refino-dispatcher.sh}"
AUTO_REFINO_PLIST_OVERRIDE="${AUTO_REFINO_PLIST:-$SELF_DIR/auto-refino-dispatcher.plist}"
AUTO_REFINER_AGENT_TOML_OVERRIDE="${AUTO_REFINER_AGENT_TOML:-$SELF_DIR/../../../agents/auto-refiner/agent.toml}"

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

# ── Scenario 8: ga-lfua3 — escalation reaches the human "Sua vez" queue + no loop
# Two confirmed-live bugs:
#  (a) escalate set only auto-refino:escalated, but the painel "Sua vez" column
#      matches _SUAVEZ_LABELS={story:needs-approval, story:refino-escalado}. Without
#      story:refino-escalado the story rendered in TRIAGEM (invisible to Athos).
#      Fix: escalate ALSO adds story:refino-escalado (keeping auto-refino:escalated).
#  (b) re-ingestion loop: an escalated bead carrying only auto-refino:escalated (no
#      story:*) looked RAW and was re-ingested → re-refined → re-escalated. The RAW
#      source must exclude auto-refino:escalated (defense in depth, holds even if the
#      story:* escalation label is later stripped).
echo "Scenario 8: ga-lfua3 — escalation surfaces in 'Sua vez', no re-ingestion loop"
EX="scraper build infra config deploy migration pipeline"
SUAVEZ="story:needs-approval story:refino-escalado"   # painel_visibilidade.py:135

# 8(a). After Fix 1 an escalated story carries story:refino-escalado — which IS a
#       _SUAVEZ_LABELS member, so the painel renders it in the human queue. Assert
#       the post-escalate label set intersects _SUAVEZ_LABELS.
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

# 8(b). A bead carrying auto-refino:escalated is NOT ingested by the RAW source
#       (loop killed) — the exact ga-m9gt3 shape and the variant where story:* was
#       stripped leaving only the daemon marker.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated" "false" "$EX")" = "no" ] \
  && ok "(b) bead w/ auto-refino:escalated (no story:*) → NOT ingested (loop killed)" \
  || bad "(b) escalated bead → expected NOT ingestable (re-ingestion loop ga-m9gt3 re-forms)"
# After Fix 1 the escalated bead ALSO carries story:refino-escalado (a story:* label),
# so it is doubly non-raw — assert both the has-lifecycle path AND the marker path drop it.
[ "$(auto_refino_is_ingestable_raw "ga-m9gt3" "feature" "auto-refino:escalated,story:refino-escalado" "false" "$EX")" = "no" ] \
  && ok "(b) escalated bead + story:refino-escalado → NOT ingested (story:* present AND marker excluded)" \
  || bad "(b) escalated+refino-escalado → expected NOT ingestable"

# 8(c). A genuinely-fresh raw story (no story:*, no escalated marker) IS still
#       ingested — the fix must not over-reject and re-starve the funnel.
[ "$(auto_refino_is_ingestable_raw "ga-fresh2" "feature" "frontend" "false" "$EX")" = "yes" ] \
  && ok "(c) genuine fresh raw story (no story:*, no escalated) → still ingested (no regression)" \
  || bad "(c) genuine raw story → expected ingestable (funnel re-starved)"
[ "$(auto_refino_is_ingestable_raw "ga-fresh3" "story" "" "false" "$EX")" = "yes" ] \
  && ok "(c) bare raw story type, no labels → still ingested" \
  || bad "(c) bare raw story → expected ingestable"

# 8(d). Flag-off path unchanged: AUTO_REFINO_INGEST_RAW_TRIAGEM=0 restores the EXACT
#       prior labelled-input-only behaviour (no RAW source). Assert the dispatcher
#       still gates the 4th source behind the flag and logs the OFF branch.
if grep -qF 'if [ "$AUTO_REFINO_INGEST_RAW_TRIAGEM" = "1" ]; then' "$DISPATCHER" \
   && grep -qF 'Raw-Triagem ingestion OFF' "$DISPATCHER"; then
  ok "(d) RAW ingestion stays gated behind AUTO_REFINO_INGEST_RAW_TRIAGEM (flag-off path unchanged)"
else
  bad "(d) AUTO_REFINO_INGEST_RAW_TRIAGEM flag gate missing — flag-off behaviour changed"
fi

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
PLIST="$AUTO_REFINO_PLIST_OVERRIDE"
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
#     refiner's task heredoc (bd -C "$GC_CITY" label add "$STORY_ID" ...). Count
#     both occurrences; require at least 2.
_escalado_hits=$(grep -cF 'label add "$STORY_ID" "story:refino-escalado"' "$DISPATCHER")
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
if grep -q '^model = "sonnet"' "$AUTO_REFINER_AGENT_TOML_OVERRIDE" 2>/dev/null; then
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

# ── Scenario 9: MULTI-STORE funnel (rig-store ingestion fix) ──────────────────
# The daemon must query AND write back to all THREE bead stores (HQ + WA + PS),
# not just HQ, so feature stories living in the whatsapp_automation / property_
# scrapers rig stores are ingested into the refino funnel instead of starving in
# the painel's "Triagem" column forever. Mirrors the proven multi-store shape of
# context-check-dispatcher.sh. These are drift guards + a hermetic iteration proof.
echo ""
echo "── Scenario 9: multi-store funnel (HQ + WA + PS rig stores) ──"

# 9a. AUTO_REFINO_STORES env exists and defaults to the 3 store paths.
if grep -qE '^AUTO_REFINO_STORES="\$\{AUTO_REFINO_STORES:-\$GC_CITY .*whatsapp_automation .*property_scrapers\}"' "$DISPATCHER"; then
  ok "AUTO_REFINO_STORES defaults to HQ + WA + PS store paths"
else
  bad "AUTO_REFINO_STORES env missing or does not default to the 3 store paths"
fi

# 9b. bd_() targets the per-iteration store ($AR_STORE), defaulting to $GC_CITY
#     (so single-store callers / the lib-mode unit tests are unchanged).
if grep -qE 'bd_\(\) \{ bd -C "\$\{AR_STORE:-\$GC_CITY\}" "\$@"; \}' "$DISPATCHER"; then
  ok "bd_() targets \${AR_STORE:-\$GC_CITY} (per-store, HQ-default)"
else
  bad "bd_() does not target the per-iteration store with a GC_CITY fallback"
fi

# 9c. The candidate-gather loop iterates each store.
if grep -qE 'for AR_STORE in \$AUTO_REFINO_STORES' "$DISPATCHER"; then
  ok "candidate gather loops over AUTO_REFINO_STORES"
else
  bad "candidate gather does not iterate AUTO_REFINO_STORES"
fi

# 9d. CRITICAL CORRECTNESS: the refiner task heredoc writes back via $AR_BEAD_STORE
#     (the selected bead's OWN store), NOT $GC_CITY — a WA story's labels/comments
#     must land in the WA store. No bd -C "$GC_CITY" may survive in the heredoc.
if grep -q 'bd -C "$AR_BEAD_STORE"' "$DISPATCHER" \
   && ! grep -q 'bd -C "$GC_CITY"' "$DISPATCHER"; then
  ok "refiner write-back targets the bead's own store (\$AR_BEAD_STORE), never HQ"
else
  bad "refiner heredoc still writes to \$GC_CITY (would land rig-store writes in HQ)"
fi

# 9e. The refiner SESSION spawn stays city-coupled on HQ (gc --city "$GC_CITY"):
#     sessions live in the HQ city; only the bead writes are store-scoped. Mirrors
#     context-check-dispatcher.sh.
if grep -q 'gc --city "$GC_CITY" session new' "$DISPATCHER"; then
  ok "refiner session spawn stays on the HQ city (gc --city \$GC_CITY)"
else
  bad "refiner session spawn no longer uses gc --city \$GC_CITY"
fi

# 9f. HERMETIC iteration proof: point AUTO_REFINO_STORES at TWO temp store dirs and
#     confirm the DRY_RUN sweep visits BOTH (the log emits a per-store header for
#     each). This proves the loop actually iterates every store — the regression
#     that a WA/PS store is now reached, not just HQ. No live Dolt is touched
#     (empty temp dirs → bd list returns [] → harmless DRY_RUN).
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

# ── Scenario 10: FIX C — single-instance mkdir-mutex lock ─────────────────────
# WHY: the refiner timeout (25m) >> the launchd interval (~5m), so without a lock
# launchd stacks up to 5 concurrent sweeps, each spawning a Sonnet refiner, blowing
# past the auto-refiner cap (max_active_sessions=3). The lock caps it at ONE live
# sweep. These are drift guards + a live concurrency proof using the DRY_RUN harness.
echo ""
echo "── Scenario 10: FIX C — single-instance lock (refiner-cap protection) ──"

# 10a. Drift guards: the lock primitives exist (mkdir mutex + heartbeat + trap +
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

# 10b. LIVE: a second concurrent sweep BACKS OFF while a fresh lock is held.
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

# 10c. LIVE: a STALE lock (heartbeat mtime older than MAX_AGE) is RECLAIMED — the
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

# 10d. Kill-switch: AUTO_REFINO_LOCK=0 runs the sweep even with a fresh lock held
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

# ── Scenario 11: FIX B — cross-stage contention-yield ─────────────────────────
# WHY: refino is the LOWEST stage and must yield to a congested gate / waiting Pilot
# when resources are contended, but NEVER serialize pointlessly when resources are
# free (anti-starvation). Drift guards + live behavioural proofs via the override
# test seams (no live gate/Dolt/quota touched).
echo ""
echo "── Scenario 11: FIX B — cross-stage contention-yield (anti-starvation) ──"

# 11a. Drift guards: the yield gate + its env kill-switch + the four probes exist,
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

# 11b. LIVE DEFER: gate congested + quota limited → the sweep DEFERS, mutating
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

# 11c. LIVE DEFER via the PILOT arm: pilot-has-work + Dolt hot → DEFERS (proves the
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

# 11d. ANTI-STARVATION (resources FREE): gate congested but quota OK + Dolt calm →
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

# 11e. FAIL-OPEN: a blind Dolt probe (no signal) resolves to NOT-hot, and with quota
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

# 11f. Kill-switch: AUTO_REFINO_YIELD=0 disables the gate (no defer even when
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

echo ""
echo "auto-refino-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
