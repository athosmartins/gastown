#!/usr/bin/env bash
# refino-gate-dispatcher.sh — Autonomous Refino Quality Gate ("Gate de refino", ga-gpr2v).
#
# The SIBLING of quality-gate-dispatcher.sh: where that gate reviews CODE before
# it merges to main, THIS gate reviews REFINED STORIES before they reach Athos's
# approval queue. A Sonnet reviewer atte­sts the QUALITY of the refinement
# (Definition of Refined: fields complete, criteria verifiable, scope coherent,
# not-an-epic). Athos stops being the quality reviewer of refinement; he only
# sees stories that already cleared the crivo.
#
# Runs every ~3 min via launchd (com.gascity.refino-gate-dispatcher.plist).
#
# LIFECYCLE (where this gate sits — see story-bead-convention.md):
#
#   story:unrefined → story:refinement-in-progress → [REFINED] →
#       story:refino-review   ← THIS GATE's INPUT  (the "em revisão" pill keys here, ga-sefot)
#         ├─ PASS → story:needs-approval            (Athos's queue)
#         └─ FAIL → story:refinement-in-progress    (bounced back to the original refiner)
#                      └─ round-limit exceeded → story:needs-approval + refino-gate:escalated
#                                                  (handed to Athos, never looped)
#
# THE GATE NEVER WRITES story:approved. Only Athos approves (he moves
# needs-approval → approved). The reviewer attests quality and PROMOTES to the
# queue; it does not approve in Athos's place (AC: "revisor NUNCA aprova no
# lugar do Athos").
#
# WHAT MARKS A STORY "refined & awaiting refino-gate" (the ga-flxp6 / /refino
# CONTRACT): the refiner sets lifecycle label `story:refino-review` on a refined
# bead (instead of writing story:needs-approval directly). Any refiner — the
# auto-refino daemon (ga-flxp6), Refino Rápido, or a manual /refino session —
# targets this gate the same way:
#       bd -C "$GC_CITY" update <id> --set-labels story:refino-review \
#          --set-metadata story.refino_refiner=<refiner-actor>
# `story.refino_refiner` records WHO to bounce back to. If absent, the dispatcher
# falls back to the bead's current assignee, then created_by.
#
# DESIGN INVARIANTS:
#   - One reviewer session (Sonnet) per story. Refinement review is a single
#     quality judgement, not a 3-lens code quorum.
#   - The reviewer's rubric IS the Definition of Refined (the refino skill's 8
#     fields + result-framed verifiable criteria + not-an-epic check).
#   - Reviewer is GENUINELY INDEPENDENT: a real `gc session new` Claude process,
#     not role-play. It records a verdict bead and exits.
#   - Bounce-back has a ROUND LIMIT (REFINO_MAX_ROUNDS). Exceeded → escalate to
#     Athos (promote to needs-approval + refino-gate:escalated + note), never loop.
#   - DRY_RUN=1 → no label transitions / no spawn; logs "WOULD …" instead.
#   - DRAIN-SAFE: this file + its plist + the refino-gate-reviewer template are
#     the ONLY artifacts. Does not touch the CODE gate, city.toml, or skills.
#
# Usage:
#   bash refino-gate-dispatcher.sh            # normal run
#   DRY_RUN=1 bash refino-gate-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

GC_CITY="${REFINO_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/refino-gate-dispatcher.log"
RG_LOG="$GC_CITY/.gc/refino-gate.jsonl"

# ── Tunables (env-overridable for the selftest) ───────────────────────────────
# Max bounce-back rounds before escalating to Athos (no infinite loop).
REFINO_MAX_ROUNDS="${REFINO_MAX_ROUNDS:-3}"
# Wall-clock minutes to wait for the reviewer verdict before timing out.
REFINO_VERDICT_TIMEOUT_MINUTES="${REFINO_VERDICT_TIMEOUT_MINUTES:-20}"
# Safety floor — never shorter than 10m regardless of a leftover env var.
if [ "$REFINO_VERDICT_TIMEOUT_MINUTES" -lt 10 ] 2>/dev/null; then
  REFINO_VERDICT_TIMEOUT_MINUTES=10
fi
# Poll interval (seconds) while waiting for the verdict.
REFINO_VERDICT_POLL_INTERVAL="${REFINO_VERDICT_POLL_INTERVAL:-30}"
# Reviewer session template (model = Sonnet; see agents/refino-gate-reviewer/agent.toml).
REFINO_REVIEWER_TEMPLATE="${REFINO_REVIEWER_TEMPLATE:-refino-gate-reviewer}"
# If a review claim sits in refino-gate:reviewing longer than this, the dispatcher
# died mid-run — recover the story back to the queue. Same spirit as the code
# gate's DISPATCHING_TTL.
REFINO_REVIEW_TTL_MINUTES="${REFINO_REVIEW_TTL_MINUTES:-40}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(ts)] $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARN: $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] WARN: $*"; }
err()  { echo "[$(ts)] ERROR: $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] ERROR: $*"; }

DRY_RUN="${DRY_RUN:-0}"

# ── PURE DECISION CORE (unit-tested by refino-gate-dispatcher.selftest.sh) ─────
# These functions are deliberately side-effect-free: they take the verdict and
# the round count and emit a single decision token. The selftest drives them
# directly, and the dispatcher body below calls them so the tested logic IS the
# shipped logic (no parallel reimplementation).

# refino_gate_decision <verdict> <rounds_so_far> <max_rounds>
#   verdict        : PASS | FAIL | TIMEOUT | <anything-else>
#   rounds_so_far  : how many review rounds this story has ALREADY had (>=0;
#                    this current round is counted, i.e. after incrementing).
#   max_rounds     : the bounce-back ceiling (REFINO_MAX_ROUNDS).
#
#   Emits exactly one of:
#     promote   — PASS: promote to story:needs-approval (Athos's queue).
#     bounce    — FAIL within the round budget: send back to the refiner.
#     escalate  — FAIL but the round budget is spent: hand to Athos (no loop).
#     requeue   — TIMEOUT / unknown: leave for a later sweep, do NOT promote.
#
#   GUARANTEE (AC "revisor NUNCA aprova no lugar do Athos"): this function can
#   only ever emit `promote` (→ needs-approval) — NEVER story:approved. There is
#   no code path anywhere that writes story:approved.
refino_gate_decision() {
  local verdict="$1" rounds="$2" maxr="$3"
  case "$verdict" in
    PASS) echo "promote" ;;
    FAIL)
      # rounds is the count INCLUDING the round that just produced this FAIL.
      # Once we have spent the budget, a further FAIL must not bounce again.
      if [ "$rounds" -ge "$maxr" ] 2>/dev/null; then
        echo "escalate"
      else
        echo "bounce"
      fi
      ;;
    *) echo "requeue" ;;   # TIMEOUT, empty, or any unexpected token
  esac
}

# refino_next_round <current_rounds> — echo current+1 (sanitized; non-numeric→1).
refino_next_round() {
  local r="${1:-0}"
  case "$r" in ''|*[!0-9]*) r=0 ;; esac
  echo "$((r + 1))"
}

# refino_resolve_refiner <refiner_meta> <assignee> <created_by> — echo who to
# bounce a FAIL back to. Precedence: explicit story.refino_refiner > assignee >
# created_by. Empty if none known (caller then escalates rather than bouncing
# into the void).
refino_resolve_refiner() {
  local meta="$1" assignee="$2" created_by="$3"
  if [ -n "$meta" ] && [ "$meta" != "null" ]; then echo "$meta"; return 0; fi
  if [ -n "$assignee" ] && [ "$assignee" != "null" ]; then echo "$assignee"; return 0; fi
  if [ -n "$created_by" ] && [ "$created_by" != "null" ]; then echo "$created_by"; return 0; fi
  echo ""
}

# If sourced by the selftest, stop here — expose the pure functions only.
if [ "${REFINO_GATE_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── bd/gc wrappers ────────────────────────────────────────────────────────────
bd_() { bd -C "$GC_CITY" "$@"; }

# ── Step 0: TTL recovery — re-queue stories stuck mid-review ──────────────────
# If a story has been in refino-gate:reviewing for > TTL, the dispatcher that
# claimed it died before recording a verdict. Return it to the queue so this (or
# a later) sweep re-reviews it. Mirrors the code gate's dispatching-TTL recovery.
log "Refino gate sweep start (max_rounds=$REFINO_MAX_ROUNDS, timeout=${REFINO_VERDICT_TIMEOUT_MINUTES}m, dry_run=$DRY_RUN)"

STUCK_JSON=$(bd_ list --label story:refino-review --label refino-gate:reviewing \
  --type feature --status open --json 2>/dev/null || echo "[]")
NOW_EPOCH=$(date +%s)
echo "$STUCK_JSON" | jq -c '.[]?' 2>/dev/null | while IFS= read -r row; do
  s_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$s_id" ] && continue
  s_upd=$(echo "$row" | jq -r '.updated_at // empty')
  [ -z "$s_upd" ] && continue
  upd_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$s_upd" +%s 2>/dev/null \
    || date -u -d "$s_upd" +%s 2>/dev/null || echo 0)
  [ "$upd_epoch" = "0" ] && continue
  age_min=$(( (NOW_EPOCH - upd_epoch) / 60 ))
  if [ "$age_min" -ge "$REFINO_REVIEW_TTL_MINUTES" ]; then
    log "  TTL recovery: $s_id stuck reviewing ${age_min}m (>${REFINO_REVIEW_TTL_MINUTES}m) — returning to queue"
    if [ "$DRY_RUN" != "1" ]; then
      bd_ label remove "$s_id" "refino-gate:reviewing" -q 2>/dev/null || true
      bd_ comment "$s_id" "Refino-gate TTL recovery: review claim was held ${age_min}m (>${REFINO_REVIEW_TTL_MINUTES}m) with no verdict — dispatcher likely died mid-run. Re-queued for re-review." 2>/dev/null || true
    fi
  fi
done

# ── Step 1: Find queued stories (refined, awaiting refino-gate) ───────────────
# Eligible = story:refino-review, NOT already being reviewed, NOT escalated, and
# NOT already promoted. FIFO by creation: oldest refined story first.
QUEUE_JSON=$(bd_ list --label story:refino-review --type feature --status open \
  --exclude-label refino-gate:reviewing \
  --exclude-label story:needs-approval \
  --exclude-label story:approved \
  --json 2>/dev/null || echo "[]")

QCOUNT=$(echo "$QUEUE_JSON" | jq 'length' 2>/dev/null || echo 0)
if [ "$QCOUNT" -eq 0 ] 2>/dev/null; then
  log "No stories awaiting refino-gate. Sweep done."
  exit 0
fi
log "$QCOUNT story(ies) awaiting refino-gate."

# Oldest-first (FIFO). One story per sweep keeps Dolt load gentle and mirrors the
# code gate's one-marker-per-sweep cadence; the launchd interval drains the rest.
STORY=$(echo "$QUEUE_JSON" | jq -c 'sort_by(.created_at // .id) | .[0]')
STORY_ID=$(echo "$STORY" | jq -r '.id')
STORY_TITLE=$(echo "$STORY" | jq -r '.title // ""')
log "Selected story for review: $STORY_ID — $STORY_TITLE"

# ── Step 2: Atomic claim — mark as under review (pill 'em revisão' keys here) ──
# Add refino-gate:reviewing alongside story:refino-review (do NOT drop the
# lifecycle label — the ga-sefot pill renders the 'em revisão' state off the
# combination). Re-read to confirm we own the claim (no double-review).
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD claim $STORY_ID (add refino-gate:reviewing) — DRY_RUN"
else
  bd_ label add "$STORY_ID" "refino-gate:reviewing" -q 2>/dev/null || true
  VERIFY=$(bd_ show "$STORY_ID" --json 2>/dev/null || echo "[]")
  HAS=$(echo "$VERIFY" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | index("refino-gate:reviewing") // empty')
  if [ -z "$HAS" ]; then
    warn "Could not confirm review claim on $STORY_ID — another sweep may own it. Skipping."
    exit 0
  fi
fi

# Round bookkeeping: how many review rounds this story has had. Stored as
# story.refino_gate_rounds; incremented per review.
PRIOR_ROUNDS=$(echo "$STORY" | jq -r '.metadata["story.refino_gate_rounds"] // "0"')
case "$PRIOR_ROUNDS" in ''|*[!0-9]*) PRIOR_ROUNDS=0 ;; esac
THIS_ROUND=$(refino_next_round "$PRIOR_ROUNDS")
log "  Review round $THIS_ROUND (max $REFINO_MAX_ROUNDS) for $STORY_ID"

# Who to bounce a FAIL back to.
REFINER_META=$(echo "$STORY" | jq -r '.metadata["story.refino_refiner"] // empty')
S_ASSIGNEE=$(echo "$STORY" | jq -r '.assignee // empty')
S_CREATED_BY=$(echo "$STORY" | jq -r '.created_by // empty')
REFINER=$(refino_resolve_refiner "$REFINER_META" "$S_ASSIGNEE" "$S_CREATED_BY")
log "  Original refiner (bounce-back target): ${REFINER:-<unknown>}"

# ── Step 3: Build the reviewer rubric (= Definition of Refined) ───────────────
# Pull the refined fields so the reviewer judges the ACTUAL content, not a stub.
STORY_FULL=$(bd_ show "$STORY_ID" --json 2>/dev/null || echo "{}")
J() { echo "$STORY_FULL" | jq -r "if type==\"array\" then .[0] else . end | $1 // \"\""; }
M_RESUMO=$(J '.metadata["story.resumo"]')
M_OQUEE=$(J '.metadata["story.o_que_e"]')
M_ESTRELA=$(J '.metadata["story.estrela_guia"]')
M_EQUILIB=$(J '.metadata["story.equilibrios"]')
M_DASH=$(J '.metadata["story.dashboard"]')
M_CRIT=$(J '.metadata["story.criterios"]')
M_DEPS=$(J '.metadata["story.dependencias"]')
M_FORA=$(J '.metadata["story.fora_de_escopo"]')
M_SIZE=$(J '.metadata["story.size_check"]')
M_MODE=$(J '.metadata["story.refino_mode"]')
S_TYPE=$(J '.issue_type')
[ -z "$S_TYPE" ] && S_TYPE=$(J '.type')

# ── Step 4: Create the verdict bead the reviewer will close ───────────────────
REFINO_RUN_ID="refino-$(date -u +%Y%m%dT%H%M%SZ)-$STORY_ID"
VERDICT_BEAD_ID=""
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD create verdict bead for $STORY_ID (run $REFINO_RUN_ID) — DRY_RUN"
  VERDICT_BEAD_ID="dry-verdict"
else
  VERDICT_BEAD_ID=$(bd_ create \
    "refino-verdict: $STORY_ID (round $THIS_ROUND)" \
    -t chore --ephemeral \
    -l type:refino-gate-verdict \
    -l "refino-run:$REFINO_RUN_ID" \
    -l "refino-story:$STORY_ID" \
    -l verdict:pending \
    -d "Verdict bead for refino-gate review of $STORY_ID (round $THIS_ROUND).
story: $STORY_ID
title: $STORY_TITLE
refiner: ${REFINER:-unknown}
The reviewer closes this bead with verdict:PASS or verdict:FAIL + notes." \
    --json 2>/dev/null | jq -r '.id // empty')
  if [ -z "$VERDICT_BEAD_ID" ]; then
    err "Failed to create verdict bead for $STORY_ID — releasing claim, will retry next sweep."
    bd_ label remove "$STORY_ID" "refino-gate:reviewing" -q 2>/dev/null || true
    exit 1
  fi
  log "  Verdict bead: $VERDICT_BEAD_ID"
fi

# The review task = the rubric (Definition of Refined) + the exact bd commands.
REVIEW_TASK=$(cat <<TASK
REFINO QUALITY GATE — You review the QUALITY of a refined product story.
You do NOT approve it (only Athos approves). You attest that the refinement is
good enough to reach Athos's approval queue. Be a rigorous but fair product
reviewer. Conduct your notes in Portuguese.

STORY: $STORY_ID — $STORY_TITLE
Refino mode: ${M_MODE:-completo}   (simplificado skips F3/F4/F5; their absence is OK)
Type: ${S_TYPE:-feature}

REFINED FIELDS (Definition of Refined — the rubric):
  F1 Resumo: $M_RESUMO
  F2 O que é + por que importa: $M_OQUEE
  F3 Estrela-guia: $M_ESTRELA
  F4 Equilíbrios: $M_EQUILIB
  F5 Dashboard pós-entrega: $M_DASH
  F6 Critérios de aceitação:
$M_CRIT
  F7 Dependências: $M_DEPS | Fora de escopo: $M_FORA
  F8 Checagem história/épico: $M_SIZE

EVALUATE (PASS only if ALL hold):
  1. FIELDS COMPLETE for the declared mode. Completo needs all 8; simplificado
     needs F1, F2, F6, F7, F8 (F3/F4/F5 may carry "— pulado no refino
     simplificado" — that is correct, NOT a gap). Empty/placeholder mandatory
     fields = FAIL.
  2. CRITERIA VERIFIABLE: F6 has >=2 acceptance criteria, each written as an
     observable RESULT (not an implementation "how"), each checkable by a human
     tester without reading source. Vague criteria ("melhorar performance") = FAIL.
  3. SCOPE COHERENT: F2/F6/F7 tell one consistent story; fora-de-escopo names at
     least one explicit exclusion; resumo (F1) matches the criteria.
  4. NOT AN EPIC: F8 = "story" and the criteria are deliverable as one unit. If
     it reads like an epic (6+ criteria across multiple flows, 3+ component deps),
     FAIL with "should be split".

RECORD YOUR VERDICT with EXACTLY these commands, then exit:

bd -C "$GC_CITY" label remove "$VERDICT_BEAD_ID" "verdict:pending"
# If the refinement is good enough for Athos's queue:
bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:PASS"
bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: PASS
Resumo: <1-2 frases do que você checou e por que passa>"
bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

# If it needs more refinement (bounced back to the refiner):
# bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:FAIL"
# bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: FAIL
# Problema 1: <o que corrigir, concreto e acionável>
# Problema 2: <...>"
# bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

Do not start other work. Record the verdict and exit.
TASK
)

# ── Step 5: Spawn the Sonnet reviewer session ─────────────────────────────────
# A genuinely independent Claude session on the refino-gate-reviewer template
# (model = Sonnet; provider = claude-headless so it never grabs Remote Control).
SESSION_ID=""
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD spawn reviewer ($REFINO_REVIEWER_TEMPLATE) for $STORY_ID and deliver rubric — DRY_RUN"
  log "DRY_RUN: no verdict to collect; leaving $STORY_ID claimed for the next real sweep."
  # In DRY_RUN we do not loop on a verdict; just emit the audit line and stop.
  jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --arg round "$THIS_ROUND" \
    '{ts:$ts, event:"dry_run_review", story:$story, round:($round|tonumber)}' \
    >> "$RG_LOG" 2>/dev/null || true
  exit 0
fi

_spawn_err_file="/tmp/refino-reviewer-spawn-err-$$"
SESSION_JSON=$(gc --city "$GC_CITY" session new "$REFINO_REVIEWER_TEMPLATE" \
  --no-attach \
  --title "refino-reviewer: $STORY_ID (round $THIS_ROUND)" \
  --json \
  2>"$_spawn_err_file" || echo "{}")
_spawn_err=$(head -c 300 "$_spawn_err_file" 2>/dev/null || echo "")
rm -f "$_spawn_err_file"
SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  err "Failed to spawn refino reviewer for $STORY_ID — releasing claim (retry next sweep). spawn_err=${_spawn_err:-none}"
  bd_ label remove "$STORY_ID" "refino-gate:reviewing" -q 2>/dev/null || true
  bd_ close "$VERDICT_BEAD_ID" 2>/dev/null || true
  jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --arg e "${_spawn_err:-none}" \
    '{ts:$ts, event:"spawn_fail", story:$story, spawn_err:$e}' >> "$RG_LOG" 2>/dev/null || true
  exit 1
fi
log "  Reviewer session spawned: $SESSION_ID"

gc --city "$GC_CITY" session wake "$SESSION_ID" 2>/dev/null || true

# Durable pull channel + fast nudge (ga-67hae pattern): assign the verdict bead
# to the reviewer and embed the rubric as a comment, then nudge.
SESSION_NAME=$(echo "$SESSION_JSON" | jq -r '.session_name // empty')
if [ -n "$SESSION_NAME" ]; then
  bd_ update "$VERDICT_BEAD_ID" --assignee "$SESSION_NAME" --status in_progress -q 2>/dev/null || true
  bd_ comment "$VERDICT_BEAD_ID" "$REVIEW_TASK" 2>/dev/null || true
fi
gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REVIEW_TASK" --delivery queue 2>/dev/null \
  || gc --city "$GC_CITY" session submit "$SESSION_ID" "$REVIEW_TASK" 2>/dev/null \
  || warn "  Initial queue/submit to reviewer failed — durable pull channel still active."
log "  Rubric delivered to reviewer for $STORY_ID."

# ── Step 6: Poll the verdict bead until PASS/FAIL or timeout ──────────────────
DEADLINE=$(( $(date +%s) + REFINO_VERDICT_TIMEOUT_MINUTES * 60 ))
VERDICT="TIMEOUT"
FAIL_NOTES=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  VB=$(bd_ show "$VERDICT_BEAD_ID" --json 2>/dev/null || echo "[]")
  VB_LABELS=$(echo "$VB" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")')
  if echo "$VB_LABELS" | grep -q "verdict:PASS"; then
    VERDICT="PASS"; break
  elif echo "$VB_LABELS" | grep -q "verdict:FAIL"; then
    VERDICT="FAIL"
    FAIL_NOTES=$(bd_ show "$VERDICT_BEAD_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.comments // [])[]?.text' 2>/dev/null \
      | grep -A50 "VERDICT: FAIL" | tail -n +2 | head -40 || echo "")
    break
  fi
  sleep "$REFINO_VERDICT_POLL_INTERVAL"
done
log "  Verdict for $STORY_ID: $VERDICT"

# ── Step 7: Act on the verdict via the PURE decision core ─────────────────────
DECISION=$(refino_gate_decision "$VERDICT" "$THIS_ROUND" "$REFINO_MAX_ROUNDS")
log "  Decision: $DECISION (verdict=$VERDICT round=$THIS_ROUND/$REFINO_MAX_ROUNDS)"

# Always clear the review claim and persist the round count.
bd_ label remove "$STORY_ID" "refino-gate:reviewing" -q 2>/dev/null || true
bd_ update "$STORY_ID" --set-metadata "story.refino_gate_rounds=$THIS_ROUND" -q 2>/dev/null || true

case "$DECISION" in
  promote)
    # PASS → Athos's queue. NEVER story:approved (only Athos approves).
    bd_ update "$STORY_ID" --set-labels story:needs-approval -q 2>/dev/null || true
    bd_ comment "$STORY_ID" "Refino-gate: APROVADO na revisão de qualidade (round $THIS_ROUND). Promovido para 'Aguardando Aprovação' (story:needs-approval). O Athos faz a aprovação final." 2>/dev/null || true
    log "  $STORY_ID → story:needs-approval (Athos's queue)."
    ;;
  bounce)
    # FAIL within budget → back to the refiner with concrete notes.
    bd_ update "$STORY_ID" --set-labels story:refinement-in-progress -q 2>/dev/null || true
    if [ -n "$REFINER" ]; then
      bd_ update "$STORY_ID" --assignee "$REFINER" -q 2>/dev/null || true
    fi
    bd_ comment "$STORY_ID" "Refino-gate: DEVOLVIDO para refino (round $THIS_ROUND/$REFINO_MAX_ROUNDS). Corrija os pontos abaixo e re-marque story:refino-review quando pronto:
${FAIL_NOTES:-(sem notas — ver verdict bead $VERDICT_BEAD_ID)}" 2>/dev/null || true
    [ -n "$REFINER" ] && gc --city "$GC_CITY" nudge "$REFINER" "Refino-gate devolveu $STORY_ID para ajuste (round $THIS_ROUND). Veja as notas no bead." 2>/dev/null || true
    log "  $STORY_ID → bounced to refiner ${REFINER:-<unknown>} (round $THIS_ROUND)."
    ;;
  escalate)
    # FAIL but round budget spent → hand to Athos, do not loop. Promote to the
    # queue so it is VISIBLE to Athos, flagged escalated with the history.
    bd_ update "$STORY_ID" --set-labels story:needs-approval -q 2>/dev/null || true
    bd_ label add "$STORY_ID" "refino-gate:escalated" -q 2>/dev/null || true
    bd_ comment "$STORY_ID" "Refino-gate: ESCALADO ao Athos. Estourou o limite de $REFINO_MAX_ROUNDS rodadas de revisão sem passar. Última reprovação:
${FAIL_NOTES:-(sem notas)}
Athos: decida manualmente (aprovar, ajustar, ou cancelar)." 2>/dev/null || true
    notify -t "Refino-gate escalou $STORY_ID" -p 3 "Refino-gate: $STORY_ID estourou $REFINO_MAX_ROUNDS rodadas sem passar — precisa de você." 2>/dev/null || true
    gc --city "$GC_CITY" mail send mayor -s "Refino-gate escalou $STORY_ID" \
      -m "$STORY_ID estourou $REFINO_MAX_ROUNDS rodadas de revisão de refino sem passar. Promovido para needs-approval + refino-gate:escalated para o Athos decidir." 2>/dev/null || true
    log "  $STORY_ID → ESCALATED to Athos (round budget $REFINO_MAX_ROUNDS spent)."
    ;;
  requeue|*)
    # TIMEOUT / unknown → leave for a later sweep. Restore the gate-input state
    # (we already removed refino-gate:reviewing; the bead keeps story:refino-review
    # so the next sweep re-reviews it). Roll back the round increment so a timeout
    # does NOT burn a bounce-back round.
    bd_ update "$STORY_ID" --set-metadata "story.refino_gate_rounds=$PRIOR_ROUNDS" -q 2>/dev/null || true
    bd_ comment "$STORY_ID" "Refino-gate: revisão expirou (timeout ${REFINO_VERDICT_TIMEOUT_MINUTES}m) sem verdito. Re-enfileirada — não consumiu rodada." 2>/dev/null || true
    log "  $STORY_ID → re-queued (verdict $VERDICT; round not consumed)."
    ;;
esac

# ── Step 8: audit line ────────────────────────────────────────────────────────
jq -c -n \
  --arg ts "$(ts)" --arg story "$STORY_ID" --arg verdict "$VERDICT" \
  --arg decision "$DECISION" --arg refiner "${REFINER:-}" \
  --argjson round "$THIS_ROUND" --argjson maxr "$REFINO_MAX_ROUNDS" \
  '{ts:$ts, event:"review", story:$story, verdict:$verdict, decision:$decision, round:$round, max_rounds:$maxr, refiner:$refiner}' \
  >> "$RG_LOG" 2>/dev/null || true

log "Refino gate sweep done for $STORY_ID."
exit 0
