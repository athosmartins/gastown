#!/usr/bin/env bash
# auto-refino-dispatcher.sh — Autonomous Refino daemon ("Auto-refino", ga-flxp6).
#
# The MOTOR of the triage funnel. Where /refino refines a story interactively
# WITH Athos, THIS daemon refines stories AUTONOMOUSLY (no Athos present) and,
# instead of writing story:needs-approval directly, hands each refined story to
# the REFINO GATE (ga-gpr2v) for an automatic quality review. The backlog
# prepares itself; Athos only sees stories that already cleared the crivo.
#
# Runs every ~5 min via launchd (com.gascity.auto-refino-dispatcher.plist).
#
# WHERE THIS SITS IN THE LIFECYCLE (see skills/refino/references/story-bead-convention.md
# and the ga-gpr2v gate contract in refino-gate-dispatcher.sh):
#
#   story:unrefined / story:triage          ← THIS DAEMON's INPUT (Triagem)
#     │  (only type feature/story; bug/chore/task SKIP the funnel — ga-flxp6 AC)
#     ▼  daemon claims (auto-refino:refining) + spawns a Sonnet refiner
#   [autonomous refino — simplificado mode, reusing /refino's F1/F2/F6/F7/F8]
#     ├─ CAN refine confidently ──► story:refino-review + story.refino_refiner=<daemon>
#     │                              (the 'em revisão' pill; the GATE ga-gpr2v takes it
#     │                               from here — PASS→needs-approval, FAIL→bounce back
#     │                               to THIS daemon, round-limit→escalate to Athos)
#     └─ CANNOT refine confidently ─► auto-refino:escalated + recorded gaps/questions
#                                      (NOT promoted, NOT dispatched — handed to Athos)
#
# THE DAEMON NEVER WRITES story:approved NOR story:needs-approval, and NEVER
# dispatches. It only ever hands off to the gate (story:refino-review) or
# escalates (auto-refino:escalated). Athos remains the sole approver; the gate
# is the sole promoter to needs-approval. (ga-flxp6 AC: "Nenhuma história é
# auto-aprovada nem despachada pelo daemon.")
#
# BOUNCE-BACK CONTRACT WITH THE GATE: when the gate FAILs a review within its
# round budget it sets story:refinement-in-progress + assignee=story.refino_refiner
# (= this daemon) and nudges. So a bounced story returns here and is re-refined —
# bounded by AUTO_REFINO_MAX_ATTEMPTS (defensive cap on top of the gate's own
# REFINO_MAX_ROUNDS) so a daemon↔gate ping-pong can never loop forever.
#
# DESIGN INVARIANTS:
#   - One story per sweep (gentle Dolt load; the launchd interval drains the rest).
#   - Refino judgement is LLM work (drafting F1/F2/F6/F7/F8, can-refine-vs-escalate),
#     so — exactly like the gate — the daemon SPAWNS an independent Sonnet refiner
#     session rather than faking it inline. The pure decision core below is the
#     mechanical part (candidate selection + handoff routing) and is unit-tested.
#   - Reuses /refino's EXISTING simplificado field set + write-back shape verbatim
#     (story.refino_mode=simplificado, skip sentinel on F3/F4/F5).
#   - DRY_RUN=1 → no label transitions / no spawn; logs "WOULD …" instead.
#   - DRAIN-SAFE: this file + its plist + the auto-refiner template are the ONLY
#     artifacts. Does not touch the code gate, the refino gate, city.toml, or skills.
#
# Usage:
#   bash auto-refino-dispatcher.sh            # normal run
#   DRY_RUN=1 bash auto-refino-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

GC_CITY="${AUTO_REFINO_CITY_OVERRIDE:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/auto-refino-dispatcher.log"
AR_LOG="$GC_CITY/.gc/auto-refino.jsonl"

# ── Identity ──────────────────────────────────────────────────────────────────
# Stable actor name the daemon refines AS. Recorded as story.refino_refiner so
# the gate bounces FAILs back to THIS daemon (not into the void). Must be stable
# across sweeps; a fresh refiner session is spawned per story but they all refine
# on behalf of this single logical actor.
AUTO_REFINO_ACTOR="${AUTO_REFINO_ACTOR:-auto-refino}"

# ── Tunables (env-overridable for the selftest) ───────────────────────────────
# How many times THIS daemon will (re-)refine one story before escalating instead
# of re-refining. Defensive cap on top of the gate's REFINO_MAX_ROUNDS so a
# refine→FAIL→bounce→refine loop cannot run forever.
AUTO_REFINO_MAX_ATTEMPTS="${AUTO_REFINO_MAX_ATTEMPTS:-3}"
# Wall-clock minutes to wait for the refiner to finish (reach a terminal state)
# before timing out and re-queuing (does NOT consume an attempt).
AUTO_REFINO_TIMEOUT_MINUTES="${AUTO_REFINO_TIMEOUT_MINUTES:-25}"
# Safety floor — never shorter than 10m regardless of a leftover env var.
if [ "$AUTO_REFINO_TIMEOUT_MINUTES" -lt 10 ] 2>/dev/null; then
  AUTO_REFINO_TIMEOUT_MINUTES=10
fi
# Poll interval (seconds) while waiting for the refiner to reach a terminal state.
AUTO_REFINO_POLL_INTERVAL="${AUTO_REFINO_POLL_INTERVAL:-30}"
# Refiner session template (model = Sonnet; see agents/auto-refiner/agent.toml).
AUTO_REFINO_REFINER_TEMPLATE="${AUTO_REFINO_REFINER_TEMPLATE:-auto-refiner}"
# If a refine claim sits in auto-refino:refining longer than this, the dispatcher
# died mid-run — recover the story back to the Triagem queue. Same spirit as the
# gate's REFINO_REVIEW_TTL_MINUTES.
AUTO_REFINO_REFINING_TTL_MINUTES="${AUTO_REFINO_REFINING_TTL_MINUTES:-50}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(ts)] $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARN: $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] WARN: $*"; }
err()  { echo "[$(ts)] ERROR: $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] ERROR: $*"; }

DRY_RUN="${DRY_RUN:-0}"

# ── PURE DECISION CORE (unit-tested by auto-refino-dispatcher.selftest.sh) ─────
# Deliberately side-effect-free: they take a bead's type/labels/outcome and emit a
# single decision token. The selftest drives them directly, and the dispatcher
# body below calls them, so the tested logic IS the shipped logic (no parallel
# reimplementation). The whole point of the funnel lives here:
#   - only feature/story are candidates (bug/chore/task SKIP the funnel),
#   - only Triagem/unrefined (or a gate bounce-back to us) is eligible,
#   - the handoff can NEVER approve nor dispatch — only hand to the gate or escalate.

# auto_refino_type_eligible <issue_type> — emit "yes" iff feature/story.
#   bug / chore / task are already actionable when opened and bypass the refino
#   funnel entirely (ga-flxp6 fora-de-escopo + Athos's 2026-06-13 adjustment).
auto_refino_type_eligible() {
  case "$1" in
    feature|story) echo "yes" ;;
    *) echo "no" ;;
  esac
}

# auto_refino_lifecycle_state <labels_csv> <assignee> <daemon_actor>
#   Classify a candidate by its lifecycle labels. Emits one of:
#     fresh    — story:triage or story:unrefined, untouched → refine it.
#     bounce   — story:refinement-in-progress assigned to US (gate bounced a FAIL
#                back to the daemon) and NOT currently being refined → re-refine.
#     skip     — anything else: already refining (auto-refino:refining), already
#                handed to the gate (story:refino-review / refino-gate:*),
#                escalated (auto-refino:escalated), in Athos's queue
#                (story:needs-approval), approved/in-flight/done/cancelled, or a
#                refinement-in-progress that is NOT ours (another refiner owns it).
#   GUARANTEE: a story already past the daemon (refino-review, needs-approval,
#   approved, in-flight, done, cancelled, escalated) is NEVER reclassified as a
#   candidate — the daemon cannot re-touch work it (or Athos, or the gate) has
#   already moved forward.
auto_refino_lifecycle_state() {
  local labels="$1" assignee="$2" actor="$3"
  local csv=",$labels,"

  # Terminal / past-the-daemon states are NEVER candidates.
  case "$csv" in
    *,auto-refino:refining,*|*,auto-refino:escalated,*|*,refino-gate:reviewing,*|\
*,story:refino-review,*|*,story:needs-approval,*|*,story:approved,*|\
*,story:in-flight,*|*,story:done,*|*,story:cancelled,*)
      echo "skip"; return ;;
  esac

  # Fresh Triagem input.
  case "$csv" in
    *,story:triage,*|*,story:unrefined,*) echo "fresh"; return ;;
  esac

  # Gate bounce-back: in-progress AND assigned to us → re-refine.
  case "$csv" in
    *,story:refinement-in-progress,*)
      if [ -n "$assignee" ] && [ "$assignee" = "$actor" ]; then
        echo "bounce"; return
      fi ;;
  esac

  echo "skip"
}

# auto_refino_handoff_decision <outcome> <attempts_so_far> <max_attempts>
#   outcome        : REFINED | ESCALATE | TIMEOUT | <anything-else>
#   attempts_so_far: how many refine attempts this story has had INCLUDING the one
#                    that just produced this outcome (>=1).
#   max_attempts   : the daemon's re-refine ceiling (AUTO_REFINO_MAX_ATTEMPTS).
#
#   Emits exactly one of:
#     handoff   — REFINED: hand to the gate (story:refino-review). The GATE, not
#                 the daemon, later promotes to needs-approval. NEVER approves.
#     escalate  — ESCALATE (can't refine confidently) OR the attempt budget is
#                 spent: record gaps + hand to Athos, do NOT promote, do NOT loop.
#     requeue   — TIMEOUT / unknown: leave for a later sweep; do NOT consume an
#                 attempt, do NOT promote.
#
#   GUARANTEE (ga-flxp6 AC "nenhuma história é auto-aprovada nem despachada"):
#   this function can ONLY ever emit handoff/escalate/requeue — there is no token
#   for approve, needs-approval, or dispatch, and no code path writes them.
auto_refino_handoff_decision() {
  local outcome="$1" attempts="$2" maxa="$3"
  case "$outcome" in
    REFINED)
      # Even a successful refine respects the attempt cap: if we've already spent
      # the budget (e.g. repeated gate bounces), stop bouncing and escalate so a
      # daemon↔gate ping-pong terminates.
      if [ "$attempts" -gt "$maxa" ] 2>/dev/null; then
        echo "escalate"
      else
        echo "handoff"
      fi
      ;;
    ESCALATE) echo "escalate" ;;
    *) echo "requeue" ;;   # TIMEOUT, empty, or any unexpected token
  esac
}

# auto_refino_next_attempt <current> — echo current+1 (sanitized; non-numeric→1).
auto_refino_next_attempt() {
  local r="${1:-0}"
  case "$r" in ''|*[!0-9]*) r=0 ;; esac
  echo "$((r + 1))"
}

# If sourced by the selftest, stop here — expose the pure functions only.
if [ "${AUTO_REFINO_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── bd/gc wrappers ────────────────────────────────────────────────────────────
bd_() { bd -C "$GC_CITY" "$@"; }

# ── helper: read one label-CSV from a bead JSON row ───────────────────────────
_labels_csv() { echo "$1" | jq -r '(.labels // []) | join(",")'; }

log "Auto-refino sweep start (actor=$AUTO_REFINO_ACTOR, max_attempts=$AUTO_REFINO_MAX_ATTEMPTS, timeout=${AUTO_REFINO_TIMEOUT_MINUTES}m, dry_run=$DRY_RUN)"

# ── Step 0: TTL recovery — re-queue stories stuck mid-refine ──────────────────
# If a story has been in auto-refino:refining for > TTL, the refiner (or this
# dispatcher) died before reaching a terminal state. Drop the claim so a later
# sweep re-refines it. Mirrors the gate's review-TTL recovery.
STUCK_JSON=$(bd_ list --label auto-refino:refining --status open --json 2>/dev/null || echo "[]")
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
  if [ "$age_min" -ge "$AUTO_REFINO_REFINING_TTL_MINUTES" ]; then
    log "  TTL recovery: $s_id stuck refining ${age_min}m (>${AUTO_REFINO_REFINING_TTL_MINUTES}m) — returning to Triagem"
    if [ "$DRY_RUN" != "1" ]; then
      bd_ label remove "$s_id" "auto-refino:refining" -q 2>/dev/null || true
      bd_ comment "$s_id" "Auto-refino TTL recovery: refine claim was held ${age_min}m (>${AUTO_REFINO_REFINING_TTL_MINUTES}m) with no terminal state — refiner likely died mid-run. Re-queued for re-refine." 2>/dev/null || true
    fi
  fi
done

# ── Step 1: Find candidate stories in Triagem (feature/story only) ────────────
# Primary source query: fresh Triagem stories. We query each lifecycle label and
# union, then classify each candidate with the pure core (defense in depth: the
# query narrows, the classifier disqualifies). Type is restricted to feature at
# the query level; `story` issue_type (if the build models it) is caught by the
# type-eligibility classifier below.
#
# bug/chore/task NEVER carry story:* lifecycle labels and so never appear here —
# but we ALSO assert type-eligibility per candidate so a mislabeled bug cannot leak.
FRESH_JSON=$(bd_ list --label story:triage --type feature --status open \
  --exclude-label auto-refino:refining \
  --exclude-label auto-refino:escalated \
  --exclude-label story:refino-review \
  --exclude-label story:needs-approval \
  --exclude-label story:approved \
  --json 2>/dev/null || echo "[]")
UNREF_JSON=$(bd_ list --label story:unrefined --type feature --status open \
  --exclude-label auto-refino:refining \
  --exclude-label auto-refino:escalated \
  --exclude-label story:refino-review \
  --exclude-label story:needs-approval \
  --exclude-label story:approved \
  --json 2>/dev/null || echo "[]")
# Gate bounce-backs: in-progress stories reassigned to us.
BOUNCE_JSON=$(bd_ list --label story:refinement-in-progress --type feature --status open \
  --assignee "$AUTO_REFINO_ACTOR" \
  --exclude-label auto-refino:refining \
  --exclude-label auto-refino:escalated \
  --json 2>/dev/null || echo "[]")

CANDIDATES=$(jq -s 'add | unique_by(.id)' \
  <(echo "$FRESH_JSON") <(echo "$UNREF_JSON") <(echo "$BOUNCE_JSON") 2>/dev/null || echo "[]")
CCOUNT=$(echo "$CANDIDATES" | jq 'length' 2>/dev/null || echo 0)
if [ "$CCOUNT" -eq 0 ] 2>/dev/null; then
  log "No Triagem stories to auto-refine. Sweep done."
  exit 0
fi
log "$CCOUNT candidate story(ies) in Triagem (pre-classification)."

# Classify with the pure core; keep only fresh/bounce candidates of an eligible
# type. Oldest-first (FIFO) so the backlog drains in arrival order.
STORY=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  c_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$c_id" ] && continue
  c_type=$(echo "$row" | jq -r '.issue_type // .type // "feature"')
  c_labels=$(_labels_csv "$row")
  c_assignee=$(echo "$row" | jq -r '.assignee // empty')
  [ "$(auto_refino_type_eligible "$c_type")" = "yes" ] || { log "  skip $c_id: type '$c_type' not in funnel (bug/chore/task bypass)"; continue; }
  state=$(auto_refino_lifecycle_state "$c_labels" "$c_assignee" "$AUTO_REFINO_ACTOR")
  case "$state" in
    fresh|bounce) STORY="$row"; break ;;
    *) : ;;  # skip
  esac
done < <(echo "$CANDIDATES" | jq -c 'sort_by(.created_at // .id) | .[]')

if [ -z "$STORY" ]; then
  log "No eligible candidate after classification (all skipped). Sweep done."
  exit 0
fi

STORY_ID=$(echo "$STORY" | jq -r '.id')
STORY_TITLE=$(echo "$STORY" | jq -r '.title // ""')
STORY_DESC=$(echo "$STORY" | jq -r '.description // ""')
STORY_TYPE=$(echo "$STORY" | jq -r '.issue_type // .type // "feature"')
STORY_LABELS=$(_labels_csv "$STORY")
STORY_ASSIGNEE=$(echo "$STORY" | jq -r '.assignee // empty')
STATE=$(auto_refino_lifecycle_state "$STORY_LABELS" "$STORY_ASSIGNEE" "$AUTO_REFINO_ACTOR")
log "Selected story for auto-refino: $STORY_ID ($STATE) — $STORY_TITLE"

# ── Step 2: Atomic claim — mark as being refined ──────────────────────────────
# Set story:refinement-in-progress (lifecycle) + auto-refino:refining (claim
# marker) + assignee=us. Re-read to confirm we own the claim (no double-refine
# across parallel sweeps / other refiners).
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD claim $STORY_ID (set story:refinement-in-progress + auto-refino:refining, assignee=$AUTO_REFINO_ACTOR) — DRY_RUN"
else
  bd_ update "$STORY_ID" --set-labels story:refinement-in-progress --assignee "$AUTO_REFINO_ACTOR" -q 2>/dev/null || true
  bd_ label add "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
  VERIFY=$(bd_ show "$STORY_ID" --json 2>/dev/null || echo "[]")
  V() { echo "$VERIFY" | jq -r "if type==\"array\" then .[0] else . end | $1"; }
  HAS=$(V '(.labels // []) | index("auto-refino:refining") // empty')
  OWNS=$(V '.assignee // empty')
  if [ -z "$HAS" ] || [ "$OWNS" != "$AUTO_REFINO_ACTOR" ]; then
    warn "Could not confirm refine claim on $STORY_ID (has=$HAS owner=$OWNS) — another sweep may own it. Skipping."
    exit 0
  fi
fi

# Attempt bookkeeping: how many times the daemon has refined this story. Stored as
# story.auto_refino_attempts, incremented per attempt.
PRIOR_ATTEMPTS=$(echo "$STORY" | jq -r '.metadata["story.auto_refino_attempts"] // "0"')
case "$PRIOR_ATTEMPTS" in ''|*[!0-9]*) PRIOR_ATTEMPTS=0 ;; esac
THIS_ATTEMPT=$(auto_refino_next_attempt "$PRIOR_ATTEMPTS")
log "  Refine attempt $THIS_ATTEMPT (max $AUTO_REFINO_MAX_ATTEMPTS) for $STORY_ID"

# Carry the gate's last bounce notes (if any) into the refiner's task so a
# re-refine actually addresses the feedback rather than repeating the mistake.
GATE_NOTES=$(echo "$STORY" | jq -r '(.comments // [])[]?.text' 2>/dev/null \
  | grep -A40 "Refino-gate: DEVOLVIDO" | tail -n +1 | head -40 || echo "")

# ── Step 3: Create the task bead the refiner reports its outcome on ───────────
# Mirrors the gate's verdict bead: the dispatcher polls THIS bead's labels for a
# terminal outcome (outcome:REFINED / outcome:ESCALATE), which decouples the
# poll from the refiner's exact write timing on the story.
AR_RUN_ID="autorefino-$(date -u +%Y%m%dT%H%M%SZ)-$STORY_ID"
TASK_BEAD_ID=""
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD create task bead for $STORY_ID (run $AR_RUN_ID) — DRY_RUN"
  TASK_BEAD_ID="dry-task"
else
  TASK_BEAD_ID=$(bd_ create \
    "auto-refino-task: $STORY_ID (attempt $THIS_ATTEMPT)" \
    -t chore --ephemeral \
    -l type:auto-refino-task \
    -l "auto-refino-run:$AR_RUN_ID" \
    -l "auto-refino-story:$STORY_ID" \
    -l outcome:pending \
    -d "Task bead for autonomous refino of $STORY_ID (attempt $THIS_ATTEMPT).
story: $STORY_ID
title: $STORY_TITLE
The refiner records outcome:REFINED (refined + handed to gate) or
outcome:ESCALATE (could not refine confidently; gaps recorded) and closes this." \
    --json 2>/dev/null | jq -r '.id // empty')
  if [ -z "$TASK_BEAD_ID" ]; then
    err "Failed to create task bead for $STORY_ID — releasing claim, will retry next sweep."
    bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
    exit 1
  fi
  log "  Task bead: $TASK_BEAD_ID"
fi

# ── Step 4: Build the autonomous refino task (= /refino simplificado, no Athos) ─
# This is the /refino skill's simplificado mode, adapted for autonomy: the refiner
# DRAFTS each essential field from the title/description (there is no Athos to
# confirm per-field), self-judges confidence, and either hands to the gate or
# escalates. It reuses the EXACT field set + write-back shape from
# skills/refino/references/story-bead-convention.md (F1/F2/F6/F7/F8 + skip
# sentinel on F3/F4/F5 + story.refino_mode=simplificado).
SKIP_SENTINEL="— pulado no refino simplificado"
# Precompute the optional gate-feedback block as a plain string (avoids a fragile
# multiline ${VAR:+...} expansion inside the heredoc).
GATE_NOTES_BLOCK=""
if [ -n "$GATE_NOTES" ]; then
  GATE_NOTES_BLOCK="
PREVIOUS GATE FEEDBACK (a prior round was bounced — ADDRESS these, do not repeat):
$GATE_NOTES"
fi
# Capture via `read -r -d ''` (NOT $(cat <<…)): bash 3.2's command-substitution
# scanner mis-balances the backslash line-continuations in the embedded bd
# examples below. read -d '' reads the whole heredoc to EOF (returns non-zero at
# EOF, hence `|| true`) with no paren/quote scanning.
IFS= read -r -d '' REFINE_TASK <<TASK || true
AUTO-REFINO (autonomous) — You refine a product story WITHOUT Athos present,
reusing the /refino skill's SIMPLIFICADO mode. You do NOT approve it and you do
NOT dispatch it. On success you hand it to the refino quality gate (ga-gpr2v);
when you cannot refine it confidently you escalate with concrete questions —
you NEVER guess a product decision. Conduct all written content in Portuguese.

Read the rubric first: skills/refino/SKILL.md (Mode Selection + Fields) and
skills/refino/references/story-bead-convention.md (metadata keys + write-back).

STORY: $STORY_ID — $STORY_TITLE
Type: $STORY_TYPE   |   Attempt: $THIS_ATTEMPT/$AUTO_REFINO_MAX_ATTEMPTS
Description / context:
$STORY_DESC
$GATE_NOTES_BLOCK

SIMPLIFICADO FIELD SET (fill F1, F2, F6, F7, F8; F3/F4/F5 are skipped):
  F1 story.resumo       — headline em 1 frase (<=15 palavras, orientada a ação,
                          sem "sistema deve"/voz passiva).
  F2 story.o_que_e      — o que é + por que importa (duas partes; linguagem de
                          produto, não de engenharia).
  F6 story.criterios    — >=2 critérios de aceitação, cada um um RESULTADO
                          observável e verificável por um humano sem ler código
                          (não um "como"/implementação). Newline-separated.
  F7 story.dependencias + story.fora_de_escopo — dependências (pode ser "nenhuma")
                          e >=1 exclusão explícita de escopo.
  F8 story.size_check   — "story" se cabe em uma entrega; "epic" se grande demais.

CONFIDENCE GATE — decide REFINE vs ESCALATE (do NOT guess):
  REFINE only if you can write ALL of F1, F2, F6 (>=2 verifiable criteria), F7,
  F8 from the title/description WITHOUT inventing product scope or making a
  product/priority/tradeoff decision that only Athos can make.
  ESCALATE (do NOT promote) if ANY of:
    - the "what" or "why" (F2) is unclear / not derivable from the given context;
    - the scope is ambiguous and resolving it is a product decision (not a
      wording choice);
    - you cannot produce >=2 concrete verifiable acceptance criteria without
      guessing;
    - F8 says "epic" (needs an Athos-driven split decision).

IF YOU CAN REFINE — write back to the STORY and hand to the gate (NOT
needs-approval), then close the task bead:

bd -C "$GC_CITY" update "$STORY_ID" \\
  --description "<F2: o que é + por que importa>" \\
  --acceptance "<F6 criteria, newline or - bullets>" \\
  --set-metadata "story.resumo=<F1>" \\
  --set-metadata "story.o_que_e=<F2>" \\
  --set-metadata "story.criterios=<F6, newline-separated>" \\
  --set-metadata "story.dependencias=<F7a>" \\
  --set-metadata "story.fora_de_escopo=<F7b, >=1 exclusão>" \\
  --set-metadata "story.size_check=story" \\
  --set-metadata "story.estrela_guia=$SKIP_SENTINEL" \\
  --set-metadata "story.equilibrios=$SKIP_SENTINEL" \\
  --set-metadata "story.dashboard=$SKIP_SENTINEL" \\
  --set-metadata "story.refino_mode=simplificado" \\
  --set-metadata "story.refino_refiner=$AUTO_REFINO_ACTOR"
# Hand to the refino gate (the 'em revisão' pill keys off story:refino-review).
# This REPLACES story:refinement-in-progress; it does NOT set needs-approval.
bd -C "$GC_CITY" update "$STORY_ID" --set-labels story:refino-review
bd -C "$GC_CITY" label remove "$STORY_ID" "auto-refino:refining"
bd -C "$GC_CITY" comment "$STORY_ID" "Auto-refino: refinado autonomamente (simplificado, attempt $THIS_ATTEMPT). Enviado ao gate de refino (ga-gpr2v) para revisão de qualidade."
# Signal the dispatcher:
bd -C "$GC_CITY" label add "$TASK_BEAD_ID" "outcome:REFINED"
bd -C "$GC_CITY" label remove "$TASK_BEAD_ID" "outcome:pending"
bd -C "$GC_CITY" close "$TASK_BEAD_ID"

IF YOU CANNOT REFINE CONFIDENTLY — record the gaps/questions, escalate, do NOT
promote and do NOT dispatch, then close the task bead:

bd -C "$GC_CITY" update "$STORY_ID" \\
  --set-metadata "story.auto_refino_gaps=<perguntas/lacunas concretas, uma por linha — o que falta para refinar>"
bd -C "$GC_CITY" label add "$STORY_ID" "auto-refino:escalated"
bd -C "$GC_CITY" label remove "$STORY_ID" "auto-refino:refining"
bd -C "$GC_CITY" comment "$STORY_ID" "Auto-refino NÃO conseguiu refinar com confiança (attempt $THIS_ATTEMPT). Perguntas/lacunas para o Athos:
<liste as perguntas — decisões de produto que só o Athos toma>
NÃO promovido, NÃO despachado."
bd -C "$GC_CITY" label add "$TASK_BEAD_ID" "outcome:ESCALATE"
bd -C "$GC_CITY" label remove "$TASK_BEAD_ID" "outcome:pending"
bd -C "$GC_CITY" close "$TASK_BEAD_ID"

RULES: Never write story:approved or story:needs-approval. Never dispatch.
Never invent a product decision — when in doubt, ESCALATE. Do not start any
other work. Record the outcome and exit.
TASK

# ── Step 5: Spawn the Sonnet refiner session ──────────────────────────────────
SESSION_ID=""
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD spawn refiner ($AUTO_REFINO_REFINER_TEMPLATE) for $STORY_ID and deliver simplificado task — DRY_RUN"
  log "DRY_RUN: no outcome to collect; leaving $STORY_ID claimed for the next real sweep."
  jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --arg attempt "$THIS_ATTEMPT" \
    '{ts:$ts, event:"dry_run_refine", story:$story, attempt:($attempt|tonumber)}' \
    >> "$AR_LOG" 2>/dev/null || true
  exit 0
fi

_spawn_err_file="/tmp/auto-refiner-spawn-err-$$"
SESSION_JSON=$(gc --city "$GC_CITY" session new "$AUTO_REFINO_REFINER_TEMPLATE" \
  --no-attach \
  --title "auto-refiner: $STORY_ID (attempt $THIS_ATTEMPT)" \
  --json \
  2>"$_spawn_err_file" || echo "{}")
_spawn_err=$(head -c 300 "$_spawn_err_file" 2>/dev/null || echo "")
rm -f "$_spawn_err_file"
SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  err "Failed to spawn refiner for $STORY_ID — releasing claim (retry next sweep). spawn_err=${_spawn_err:-none}"
  bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
  bd_ close "$TASK_BEAD_ID" 2>/dev/null || true
  jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --arg e "${_spawn_err:-none}" \
    '{ts:$ts, event:"spawn_fail", story:$story, spawn_err:$e}' >> "$AR_LOG" 2>/dev/null || true
  exit 1
fi
log "  Refiner session spawned: $SESSION_ID"

gc --city "$GC_CITY" session wake "$SESSION_ID" 2>/dev/null || true

# Durable pull channel + fast nudge: assign the task bead to the refiner and embed
# the task as a comment, then nudge.
SESSION_NAME=$(echo "$SESSION_JSON" | jq -r '.session_name // empty')
if [ -n "$SESSION_NAME" ]; then
  bd_ update "$TASK_BEAD_ID" --assignee "$SESSION_NAME" --status in_progress -q 2>/dev/null || true
  bd_ comment "$TASK_BEAD_ID" "$REFINE_TASK" 2>/dev/null || true
fi
gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REFINE_TASK" --delivery queue 2>/dev/null \
  || gc --city "$GC_CITY" session submit "$SESSION_ID" "$REFINE_TASK" 2>/dev/null \
  || warn "  Initial queue/submit to refiner failed — durable pull channel still active."
log "  Simplificado task delivered to refiner for $STORY_ID."

# ── Step 6: Poll the task bead until REFINED/ESCALATE or timeout ──────────────
DEADLINE=$(( $(date +%s) + AUTO_REFINO_TIMEOUT_MINUTES * 60 ))
OUTCOME="TIMEOUT"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  TB=$(bd_ show "$TASK_BEAD_ID" --json 2>/dev/null || echo "[]")
  TB_LABELS=$(echo "$TB" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")')
  if echo "$TB_LABELS" | grep -q "outcome:REFINED"; then
    OUTCOME="REFINED"; break
  elif echo "$TB_LABELS" | grep -q "outcome:ESCALATE"; then
    OUTCOME="ESCALATE"; break
  fi
  sleep "$AUTO_REFINO_POLL_INTERVAL"
done
log "  Outcome for $STORY_ID: $OUTCOME"

# ── Step 7: Act on the outcome via the PURE decision core ─────────────────────
DECISION=$(auto_refino_handoff_decision "$OUTCOME" "$THIS_ATTEMPT" "$AUTO_REFINO_MAX_ATTEMPTS")
log "  Decision: $DECISION (outcome=$OUTCOME attempt=$THIS_ATTEMPT/$AUTO_REFINO_MAX_ATTEMPTS)"

# Persist the attempt count (except on requeue, which must not burn an attempt).
case "$DECISION" in
  handoff)
    # The refiner already wrote story:refino-review + removed auto-refino:refining.
    # The daemon only records the attempt + an audit comment. It does NOT promote
    # to needs-approval — that is the GATE's job. It does NOT dispatch.
    bd_ update "$STORY_ID" --set-metadata "story.auto_refino_attempts=$THIS_ATTEMPT" -q 2>/dev/null || true
    # Defensive: ensure the claim marker is gone even if the refiner forgot.
    bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
    log "  $STORY_ID → handed to refino gate (story:refino-review). Gate decides promotion."
    ;;
  escalate)
    # Either the refiner said ESCALATE, or the attempt budget is spent. Make sure
    # the bead is flagged + NOT promoted + NOT dispatched, record the attempt,
    # and tell Athos/Mayor. (If the refiner already escalated, these are idempotent.)
    bd_ update "$STORY_ID" --set-metadata "story.auto_refino_attempts=$THIS_ATTEMPT" -q 2>/dev/null || true
    bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
    bd_ label add "$STORY_ID" "auto-refino:escalated" -q 2>/dev/null || true
    # Keep a PRE-approval lifecycle so the Pilot never dispatches it and it is not
    # in Athos's approval queue. refinement-in-progress = "needs human input".
    bd_ update "$STORY_ID" --set-labels story:refinement-in-progress -q 2>/dev/null || true
    if [ "$OUTCOME" != "ESCALATE" ]; then
      # Budget-exhaustion escalation (the refiner kept producing REFINED but the
      # gate kept bouncing). Record why.
      bd_ comment "$STORY_ID" "Auto-refino: ESCALADO ao Athos. Estourou $AUTO_REFINO_MAX_ATTEMPTS tentativas de refino sem passar no gate. Precisa de decisão/ajuste manual." 2>/dev/null || true
    fi
    notify -t "Auto-refino escalou $STORY_ID" -p 3 "Auto-refino: $STORY_ID precisa de você (não deu pra refinar com confiança / estourou tentativas)." 2>/dev/null || true
    gc --city "$GC_CITY" mail send mayor -s "Auto-refino escalou $STORY_ID" \
      -m "$STORY_ID não pôde ser refinado autonomamente com confiança (outcome=$OUTCOME, attempt $THIS_ATTEMPT/$AUTO_REFINO_MAX_ATTEMPTS). Flagged auto-refino:escalated, mantido pré-aprovação (NÃO promovido, NÃO despachado). Veja story.auto_refino_gaps / comentários para as perguntas." 2>/dev/null || true
    log "  $STORY_ID → ESCALATED to Athos (outcome=$OUTCOME)."
    ;;
  requeue|*)
    # TIMEOUT / unknown → leave for a later sweep. Drop the claim marker and
    # restore the Triagem-input state so the next sweep re-selects it. Roll the
    # attempt count back (a timeout must NOT burn an attempt).
    bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
    bd_ update "$STORY_ID" --set-metadata "story.auto_refino_attempts=$PRIOR_ATTEMPTS" -q 2>/dev/null || true
    # Return to a fresh-eligible lifecycle so Step 1 re-picks it. If this was a
    # gate bounce-back (assigned to us), keeping refinement-in-progress + our
    # assignee is correct; if it was fresh, restore unrefined.
    if [ "$STATE" = "bounce" ]; then
      bd_ update "$STORY_ID" --set-labels story:refinement-in-progress --assignee "$AUTO_REFINO_ACTOR" -q 2>/dev/null || true
    else
      bd_ update "$STORY_ID" --set-labels story:unrefined -q 2>/dev/null || true
    fi
    bd_ comment "$STORY_ID" "Auto-refino: refino expirou (timeout ${AUTO_REFINO_TIMEOUT_MINUTES}m) sem desfecho. Re-enfileirada — não consumiu tentativa." 2>/dev/null || true
    log "  $STORY_ID → re-queued (outcome $OUTCOME; attempt not consumed)."
    ;;
esac

# ── Step 8: audit line ────────────────────────────────────────────────────────
jq -c -n \
  --arg ts "$(ts)" --arg story "$STORY_ID" --arg outcome "$OUTCOME" \
  --arg decision "$DECISION" --arg state "$STATE" \
  --argjson attempt "$THIS_ATTEMPT" --argjson maxa "$AUTO_REFINO_MAX_ATTEMPTS" \
  '{ts:$ts, event:"refine", story:$story, state:$state, outcome:$outcome, decision:$decision, attempt:$attempt, max_attempts:$maxa}' \
  >> "$AR_LOG" 2>/dev/null || true

log "Auto-refino sweep done for $STORY_ID."
exit 0
