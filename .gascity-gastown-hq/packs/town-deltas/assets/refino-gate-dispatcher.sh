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
# targets this gate the same way, ADDITIVELY (ga-xvxvf: never --set-labels — it
# REPLACES the whole label set, dropping guard/qualifier labels like
# story:blocked):
#       bd -C "$GC_CITY" label add <id> story:refino-review
#       bd -C "$GC_CITY" update <id> --set-metadata story.refino_refiner=<refiner-actor>
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

# ── ga-4u16h PORT: mid-wait re-convene of a DRAINED/DEAD reviewer ──────────────
# PROVEN PROBLEM (Mayor live e2e): the refino-gate spawns the Sonnet reviewer and
# delivers the rubric, but the reviewer session can DRAIN/die WITHOUT writing its
# verdict — the verdict bead stays verdict:pending and the session is gone. The
# ONLY recovery today is REFINO_VERDICT_TIMEOUT_MINUTES (20m) → requeue, so every
# drained reviewer costs ~20m and repeated drains cost 20×N min.
#
# This ports the CODE gate's ga-4u16h fix (quality-gate-dispatcher.sh): while
# polling for the verdict, if the reviewer SESSION is confirmed DEAD (gone from
# the session list, or closed) for N consecutive polls past a grace window, and
# the verdict bead is still pending, RE-SPAWN a fresh reviewer for the SAME story
# — reusing the still-pending verdict bead and re-delivering the SAME rubric —
# instead of waiting the full 20m. The 20m timeout stays the OUTER backstop.
#
# The pure liveness helpers (session_is_dead, session_peek_reports_dead) and the
# re-convene decision shape are PORTED from the code gate so the behavior matches
# the gate's proven model. A genuinely slow-but-alive reviewer (present + asleep)
# is NEVER re-convened.
#
# Master flag: 1 = enabled (default). 0 = EXACT pre-port behavior (no re-convene,
# no extra session probing — the original poll loop).
REFINO_RECONVENE_ENABLED="${REFINO_RECONVENE_ENABLED:-1}"
case "$REFINO_RECONVENE_ENABLED" in ''|*[!0-9]*) REFINO_RECONVENE_ENABLED=1 ;; esac

# Max re-spawns of the reviewer for one story before falling through to the outer
# timeout. 0 ALSO disables re-convene (= exact current behavior), floor-guarded at
# 0, ceiling-guarded so a misconfig can't thrash. Mirrors MAX_RESPAWNS_PER_SLOT.
REFINO_REVIEWER_RECONVENE_MAX="${REFINO_REVIEWER_RECONVENE_MAX:-2}"
case "$REFINO_REVIEWER_RECONVENE_MAX" in ''|*[!0-9]*) REFINO_REVIEWER_RECONVENE_MAX=2 ;; esac
if [ "$REFINO_REVIEWER_RECONVENE_MAX" -gt 5 ] 2>/dev/null; then
  REFINO_REVIEWER_RECONVENE_MAX=5   # never thrash >5 cohorts for one story
fi

# Grace window (seconds) a freshly-(re)spawned reviewer gets before it may be
# judged DEAD — covers slow startup/wake so a live-but-slow reviewer is NEVER
# re-convened. Floor-guarded. (= RECONVENE_GRACE_SECS in the code gate.)
REFINO_RECONVENE_GRACE_SECS="${REFINO_RECONVENE_GRACE_SECS:-60}"
case "$REFINO_RECONVENE_GRACE_SECS" in ''|*[!0-9]*) REFINO_RECONVENE_GRACE_SECS=60 ;; esac
[ "$REFINO_RECONVENE_GRACE_SECS" -lt 20 ] 2>/dev/null && REFINO_RECONVENE_GRACE_SECS=20

# Consecutive polls the reviewer must read DEAD before re-convene fires (defends
# against a transient/partial `gc session list`). Floor-guarded.
# (= RECONVENE_DEAD_STREAK_MIN in the code gate.)
REFINO_RECONVENE_DEAD_STREAK_MIN="${REFINO_RECONVENE_DEAD_STREAK_MIN:-2}"
case "$REFINO_RECONVENE_DEAD_STREAK_MIN" in ''|*[!0-9]*) REFINO_RECONVENE_DEAD_STREAK_MIN=2 ;; esac
[ "$REFINO_RECONVENE_DEAD_STREAK_MIN" -lt 1 ] 2>/dev/null && REFINO_RECONVENE_DEAD_STREAK_MIN=1

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

# ── ga-4u16h PORT: pure reviewer-liveness helpers (unit-tested in lib mode) ────
# These are PORTED VERBATIM (same logic, same names) from the CODE gate
# (quality-gate-dispatcher.sh) so the refino-gate's re-convene reuses the gate's
# PROVEN deadness model rather than reimplementing it. Pure; no I/O.

# session_is_dead <present 0|1> <closed true|false|1|0> → 1 (dead) | 0 (alive)
# A reviewer session is DEAD iff absent from the session list (present=0) OR
# explicitly closed. A present, non-closed session (active OR asleep) is ALIVE —
# `asleep` is the normal state of a reviewer between turns, so it must NEVER read
# as dead. (Verbatim from the code gate.)
session_is_dead() {
  local present="$1" closed="$2"
  if [ "$present" = "0" ]; then echo 1; return 0; fi
  case "$closed" in true|TRUE|True|1) echo 1 ;; *) echo 0 ;; esac
}

# session_peek_reports_dead <peek_stderr_text> → 1 (peek CONFIRMS the session is
# GONE — drained/ended) | 0 (alive, or inconclusive → never reap). Pure; no I/O.
# A reviewer that DRAINS (its session ends normally instead of being hard-killed)
# STAYS in `gc session list` with closed!=true, so session_is_dead reads it ALIVE.
# `gc session peek` is the discriminator the list lacks: a drained/ended session
# makes peek print "gc session peek: session not found: <id>" on STDERR, while an
# asleep-but-ALIVE reviewer's peek SUCCEEDS with real scrollback. Match ONLY that
# explicit not-found signal — never a live reviewer's scrollback, never a bare
# transient connection error. (Verbatim from the code gate, ga-h9o17.)
session_peek_reports_dead() {
  case "$1" in
    *"session not found"*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# refino_slot_action <bead_closed 0|1> <session_dead 0|1> <budget_remaining int>
#   → received | respawn | wait. Pure; no I/O.
# The single decision for the refino reviewer in one poll iteration (the
# single-reviewer analogue of the code gate's classify_slot_action):
#   received → the verdict bead is closed (PASS/FAIL recorded) — the poll loop's
#              existing logic handles it; NEVER respawn (an explicit FAIL fails
#              immediately, exactly as today).
#   respawn  → bead still pending AND reviewer confirmed dead AND budget remains.
#   wait     → everything else: a live (slow) reviewer, OR a dead reviewer whose
#              budget is spent (the 20m outer timeout is the ultimate backstop).
refino_slot_action() {
  local bead_closed="$1" session_dead="$2" budget="$3"
  case "$budget" in ''|*[!0-9-]*) budget=0 ;; esac
  if [ "$bead_closed" = "1" ]; then echo "received"; return 0; fi
  if [ "$session_dead" = "1" ] && [ "$budget" -gt 0 ] 2>/dev/null; then echo "respawn"; return 0; fi
  echo "wait"
}

# ── TESTABLE I/O HELPER (bd_ is dependency-injected — selftest stubs it) ───────
# Not side-effect-free like the decision core above (it calls bd_), but its
# CALLER-visible behavior is fully exercised in lib mode by having the selftest
# define its own bd_ stub before invoking it — same technique, one indirection
# further out.

# _refino_gate_relabel <story_id> <target_lifecycle_label>
#   Move OFF the gate's own input label (story:refino-review) ONTO
#   <target_lifecycle_label> — ADDITIVELY. ga-xvxvf: the old
#   `bd_ update <id> --set-labels <target>` REPLACED THE ENTIRE LABEL SET,
#   silently dropping every other label the bead carried — including guard/
#   qualifier labels (story:blocked, area:infra, pilot:no-auto-dispatch,
#   needs:engine-window, ...) that exist specifically to PREVENT dispatch.
#   This is exactly how an Athos-deferred story (ga-sb11i.4 — "NÃO DEVE SER
#   INICIADA SÓ POR ESTAR APROVADA NO FUNIL") became dispatchable: promotion
#   silently wiped its story:blocked guard. Add-then-remove instead: every
#   unrelated label survives, and only the gate's own input label is retired.
#   Gate re-dispatch (fix attempt 1/3): a prior version of this helper issued
#   the add and remove as two INDEPENDENT `bd_ label` calls, each swallowing
#   its own error via `|| true`. If the add succeeded but the remove failed
#   (or vice versa, e.g. a transient Dolt hiccup between the two OS-level
#   invocations), the bead could end up with BOTH labels or NEITHER — silently
#   stranded, invisible to both the refino-review and needs-approval queues,
#   while the caller's log/comment lines still claimed success. `bd update`
#   supports `--add-label`/`--remove-label` as repeatable flags on ONE call
#   (confirmed via `bd update --help`), so the add and remove land in a single
#   invocation instead of two independently-failable ones.
_refino_gate_relabel() {
  local sid="$1" target="$2"
  bd_ update "$sid" --add-label "$target" --remove-label "story:refino-review" -q 2>/dev/null || true
}

# If sourced by the selftest, stop here — expose the pure functions only.
if [ "${REFINO_GATE_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── bd/gc wrappers ────────────────────────────────────────────────────────────
# Multi-store: the refino-gate must scan ALL rig stores — WA/PS features live in
# their OWN stores, not HQ. A hardwired `bd -C HQ` left 13 WA features stuck in
# refino-review purgatory for DAYS (never promoted → never approved → never
# dispatched = 0 throughput). bd_ targets the store of the story currently being
# processed (REFINO_GATE_STORE), set per-story after selection (and per stuck bead
# in the TTL loop). Default = HQ.
REFINO_GATE_STORES="${REFINO_GATE_STORES:-$GC_CITY /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
REFINO_GATE_STORE="${REFINO_GATE_STORE:-$GC_CITY}"
_refino_store_for() {  # resolve a bead's store from its id prefix
  case "${1%%-*}" in
    wa) echo "/Users/athos/gt/whatsapp_automation" ;;
    ps) echo "/Users/athos/gt/property_scrapers" ;;
    *)  echo "$GC_CITY" ;;
  esac
}
bd_() { bd -C "$REFINO_GATE_STORE" "$@"; }

# ── Step 0: TTL recovery — re-queue stories stuck mid-review ──────────────────
# If a story has been in refino-gate:reviewing for > TTL, the dispatcher that
# claimed it died before recording a verdict. Return it to the queue so this (or
# a later) sweep re-reviews it. Mirrors the code gate's dispatching-TTL recovery.
log "Refino gate sweep start (max_rounds=$REFINO_MAX_ROUNDS, timeout=${REFINO_VERDICT_TIMEOUT_MINUTES}m, dry_run=$DRY_RUN)"

STUCK_JSON="[]"
for _s in $REFINO_GATE_STORES; do
  [ -d "$_s" ] || continue
  _st=$(bd -C "$_s" list --label story:refino-review --label refino-gate:reviewing \
    --type feature --status open --json 2>/dev/null || echo "[]")
  STUCK_JSON=$(printf '%s\n%s' "$STUCK_JSON" "$_st" | jq -s 'add // []' 2>/dev/null || echo "$STUCK_JSON")
done
NOW_EPOCH=$(date +%s)
echo "$STUCK_JSON" | jq -c '.[]?' 2>/dev/null | while IFS= read -r row; do
  s_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$s_id" ] && continue
  REFINO_GATE_STORE=$(_refino_store_for "$s_id")   # TTL ops hit the stuck bead's own store
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
QUEUE_JSON="[]"
for _s in $REFINO_GATE_STORES; do
  [ -d "$_s" ] || continue
  _q=$(bd -C "$_s" list --label story:refino-review --type feature --status open \
    --exclude-label refino-gate:reviewing \
    --exclude-label story:needs-approval \
    --exclude-label story:approved \
    --json 2>/dev/null || echo "[]")
  QUEUE_JSON=$(printf '%s\n%s' "$QUEUE_JSON" "$_q" | jq -s 'add // []' 2>/dev/null || echo "$QUEUE_JSON")
done

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
REFINO_GATE_STORE=$(_refino_store_for "$STORY_ID")   # claim/review/promote hit the story's OWN store
log "  Story store: $REFINO_GATE_STORE (prefix ${STORY_ID%%-*})"

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

# PASS — good enough for Athos's queue. ONE command instead of two (ga-hmcs0).
#
# What this DOES buy: the reviewing session cannot die *between* two separate
# commands and leave the bead with no verdict at all. That window was real and is
# now closed — a single invocation either runs or does not.
#
# What it does NOT buy, and do not let this comment claim otherwise: it is NOT one
# transaction. Traced in the live beads source — cmd/bd/update.go calls
# applyLabelUpdates (cmd/bd/show_unit_helpers.go), which runs the entire ADD loop
# to completion and THEN the REMOVE loop; internal/storage/dolt/labels.go has
# AddLabel and RemoveLabel each opening and committing their OWN sql.Tx. This town
# runs dolt_mode="server" against a live dolt sql-server with no `bd serve` proxy,
# which is exactly that code path. So a mid-call failure still leaves a partial
# state — it just moved: the surviving half is now "verdict:PASS added, pending
# NOT removed" (both labels present) instead of "pending removed, PASS never
# added" (no verdict at all).
#
# Both-labels-present is the strictly better failure: it is VISIBLE and
# self-correcting on inspection, whereas no-verdict-at-all is silent and
# indistinguishable from "the reviewer never ran" — the error-vs-empty collapse
# this bead exists to kill. That is the real win here, not atomicity.
bd -C "$REFINO_GATE_STORE" update "$VERDICT_BEAD_ID" --add-label verdict:PASS --remove-label verdict:pending
bd -C "$REFINO_GATE_STORE" comment "$VERDICT_BEAD_ID" "VERDICT: PASS
Resumo: <1-2 frases do que você checou e por que passa>"
bd -C "$REFINO_GATE_STORE" close "$VERDICT_BEAD_ID"

# If it needs more refinement (bounced back to the refiner):
# bd -C "$REFINO_GATE_STORE" update "$VERDICT_BEAD_ID" --add-label verdict:FAIL --remove-label verdict:pending
# bd -C "$REFINO_GATE_STORE" comment "$VERDICT_BEAD_ID" "VERDICT: FAIL
# Problema 1: <o que corrigir, concreto e acionável>
# Problema 2: <...>"
# bd -C "$REFINO_GATE_STORE" close "$VERDICT_BEAD_ID"

Do not start other work. Record the verdict and exit.
TASK
)

# ── Step 5: Spawn the Sonnet reviewer session ─────────────────────────────────
# A genuinely independent Claude session on the refino-gate-reviewer template
# (model = Sonnet; provider = claude-headless so it never grabs Remote Control).
#
# ga-mo7q: sibling of quality-gate-dispatcher.sh's assign_verdict_bead_verified
# (ga-vdurb) — this dispatcher had the SAME durable-pull assignment as a single
# unverified `bd_ update --assignee ... || true` with no read-back and no retry
# at all (strictly more fragile than the code-gate's already-hardened version).
# Verify + retry + label-on-final-failure so a lost write is never silent.
# Args: <verdict_bead_id> <session_name> <context-label-for-logs>
refino_assign_verdict_bead_verified() {
  local _vb="$1" _sname="$2" _ctx="${3:-}" _seen _try
  [ -z "$_vb" ] && return 1
  [ -z "$_sname" ] && { warn "  Verdict-assign (${_ctx}): empty session name for bead ${_vb} — durable channel NOT wired."; return 1; }
  for _try in 1 2 3 4; do
    bd_ update "$_vb" --assignee "$_sname" --status in_progress -q 2>/dev/null || true
    _seen=$(bd_ show "$_vb" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .assignee // empty' 2>/dev/null || echo "")
    if [ "$_seen" = "$_sname" ]; then
      [ "$_try" -gt 1 ] && log "  Verdict-assign (${_ctx}): bead ${_vb} → ${_sname} verified on retry ${_try}."
      return 0
    fi
    [ "$_try" -lt 4 ] && sleep 1
  done
  warn "  Verdict-assign (${_ctx}): bead ${_vb} assignee read back as [${_seen:-None}], expected [${_sname}] after ${_try} attempts — durable pull channel DEGRADED (ga-mo7q). Labeling bead verdict:assignee-degraded (session_name-fallback + detector backstop)."
  bd_ label add "$_vb" "verdict:assignee-degraded" -q 2>/dev/null || true
  return 1
}
#
# refino_spawn_reviewer <reason-label> — spawn a reviewer for THIS story, wake it,
# wire the ga-67hae DURABLE-PULL channel (assign the verdict bead to the new
# session_name + embed the rubric as a comment), and nudge. Used by BOTH the
# initial spawn and the ga-4u16h mid-wait re-convene, so the durable-pull wiring
# is IDENTICAL on every (re)spawn — a fresh re-convened reviewer pulls its task
# from the bead, not from the transient nudge a stillborn session would miss.
# Sets SESSION_ID / SESSION_NAME in place; returns 0 on a fresh session, 1 if the
# spawn itself failed (caller decides whether to abort or fall through to timeout).
# Reuses $REVIEW_TASK / $VERDICT_BEAD_ID / $STORY_ID / $THIS_ROUND from scope.
refino_spawn_reviewer() {
  local _reason="${1:-spawn}"
  local _title_suffix=""
  [ "$_reason" = "reconvene" ] && _title_suffix=" (re-convened)"
  local _spawn_err_file="/tmp/refino-reviewer-spawn-err-$$.${_reason}"
  SESSION_JSON=$(gc --city "$GC_CITY" session new "$REFINO_REVIEWER_TEMPLATE" \
    --no-attach \
    --title "refino-reviewer: $STORY_ID (round $THIS_ROUND)${_title_suffix}" \
    --json \
    2>"$_spawn_err_file" || echo "{}")
  _spawn_err=$(head -c 300 "$_spawn_err_file" 2>/dev/null || echo "")
  rm -f "$_spawn_err_file" 2>/dev/null || true
  SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')
  if [ -z "$SESSION_ID" ]; then
    return 1
  fi

  gc --city "$GC_CITY" session wake "$SESSION_ID" 2>/dev/null || true
  # Pin the reviewer drain-exempt (mirrors the code gate's reviewer pin) so a
  # CopyFiles config-drift supervisor event can't drain it mid-review.
  gc --city "$GC_CITY" session pin "$SESSION_ID" 2>/dev/null || true

  # Durable pull channel (ga-67hae): assign the verdict bead to the (new) reviewer
  # and embed the rubric as a comment, THEN nudge. The nudge is a fast-path; the
  # bead assignment is the reliable channel a fresh reviewer pulls from durably.
  SESSION_NAME=$(echo "$SESSION_JSON" | jq -r '.session_name // empty')
  if [ -n "$SESSION_NAME" ]; then
    refino_assign_verdict_bead_verified "$VERDICT_BEAD_ID" "$SESSION_NAME" "$_reason" || true
    bd_ comment "$VERDICT_BEAD_ID" "$REVIEW_TASK" 2>/dev/null || true
  fi
  gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REVIEW_TASK" --delivery queue 2>/dev/null \
    || gc --city "$GC_CITY" session submit "$SESSION_ID" "$REVIEW_TASK" 2>/dev/null \
    || warn "  Initial queue/submit to reviewer failed — durable pull channel still active."
  return 0
}

SESSION_ID=""
SESSION_NAME=""
SESSION_JSON=""
if [ "$DRY_RUN" = "1" ]; then
  log "WOULD spawn reviewer ($REFINO_REVIEWER_TEMPLATE) for $STORY_ID and deliver rubric — DRY_RUN"
  log "DRY_RUN: no verdict to collect; leaving $STORY_ID claimed for the next real sweep."
  # In DRY_RUN we do not loop on a verdict; just emit the audit line and stop.
  jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --arg round "$THIS_ROUND" \
    '{ts:$ts, event:"dry_run_review", story:$story, round:($round|tonumber)}' \
    >> "$RG_LOG" 2>/dev/null || true
  exit 0
fi

if ! refino_spawn_reviewer "spawn"; then
  err "Failed to spawn refino reviewer for $STORY_ID — releasing claim (retry next sweep). spawn_err=${_spawn_err:-none}"
  bd_ label remove "$STORY_ID" "refino-gate:reviewing" -q 2>/dev/null || true
  bd_ close "$VERDICT_BEAD_ID" 2>/dev/null || true
  jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --arg e "${_spawn_err:-none}" \
    '{ts:$ts, event:"spawn_fail", story:$story, spawn_err:$e}' >> "$RG_LOG" 2>/dev/null || true
  exit 1
fi
log "  Reviewer session spawned: $SESSION_ID"
log "  Rubric delivered to reviewer for $STORY_ID (durable pull, ga-67hae)."

# ── Step 6: Poll the verdict bead until PASS/FAIL, re-convene, or timeout ──────
# ga-4u16h PORT: per-story re-convene state. RECONVENE_BUDGET caps re-spawns;
# SLOT_SPAWN_EPOCH anchors the grace window (reset on every re-spawn so a fresh
# reviewer gets a fair start); SLOT_DEAD_STREAK requires consecutive DEAD reads
# before acting (transient-list-failure guard). All inert when re-convene is off.
RECONVENE_BUDGET="$REFINO_REVIEWER_RECONVENE_MAX"
[ "$REFINO_RECONVENE_ENABLED" = "1" ] || RECONVENE_BUDGET=0
SLOT_SPAWN_EPOCH=$(date +%s)
SLOT_DEAD_STREAK=0

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

  # ── ga-4u16h PORT: mid-wait re-convene of a DRAINED/DEAD reviewer ───────────
  # The verdict bead is still pending. If the reviewer SESSION is confirmed DEAD
  # (gone from the session list / closed, OR drained-but-listed per the peek
  # discriminator) for RECONVENE_DEAD_STREAK_MIN consecutive polls past the grace
  # window, and budget remains, RE-SPAWN a fresh reviewer for THIS story (reusing
  # the still-pending verdict bead + re-delivering the SAME rubric) instead of
  # waiting the full 20m. A live-but-slow reviewer (present + asleep) is NEVER
  # re-convened. Fully gated by RECONVENE_BUDGET>0 (= enabled + budget left).
  if [ "$RECONVENE_BUDGET" -gt 0 ] 2>/dev/null; then
    _now=$(date +%s)
    _spawn_age=$(( _now - SLOT_SPAWN_EPOCH ))
    # Snapshot session liveness once. Fail-safe: an unparseable/failed list leaves
    # _list_ok=0 → NO re-convene this poll (a transient glitch must never re-spawn
    # a live reviewer).
    _sess_json=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo "")
    _list_ok=0
    if [ -n "$_sess_json" ] && echo "$_sess_json" \
         | jq -e 'if type=="array" then true else has("sessions") end' >/dev/null 2>&1; then
      _list_ok=1
    fi
    if [ "$_list_ok" = "1" ]; then
      _present_n=$(echo "$_sess_json" \
        | jq -r --arg s "$SESSION_ID" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | length' 2>/dev/null || echo 1)
      case "$_present_n" in ''|*[!0-9]*) _present_n=1 ;; esac
      if [ "$_present_n" -ge 1 ]; then
        _present_flag=1
        _closed_flag=$(echo "$_sess_json" \
          | jq -r --arg s "$SESSION_ID" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | .[0].closed // false' 2>/dev/null || echo false)
      else
        _present_flag=0
        _closed_flag=false
      fi
      _dead=$(session_is_dead "$_present_flag" "$_closed_flag")
      # ga-h9o17 PORT: a reviewer that DRAINED stays listed+not-closed (_dead=0).
      # `gc session peek` is the discriminator: a drained/ended session answers
      # "session not found" on STDERR. Only probe past the grace window and while
      # the list still says alive (one cheap peek per suspicious poll). 2>&1
      # >/dev/null routes ONLY stderr into the capture so a live reviewer's
      # scrollback can never false-trigger the not-found match.
      if [ "$_dead" = "0" ] && [ "$_spawn_age" -ge "$REFINO_RECONVENE_GRACE_SECS" ]; then
        _peek_stderr=$(gc --city "$GC_CITY" session peek "$SESSION_ID" --lines 5 2>&1 >/dev/null || true)
        if [ "$(session_peek_reports_dead "$_peek_stderr")" = "1" ]; then
          _dead=1
          log "  Drained reviewer detected (ga-h9o17): session=$SESSION_ID listed+not-closed but peek reports session-gone; treating as DEAD (verdict bead $VERDICT_BEAD_ID still pending)."
        fi
      fi
      # Grace gate: never call a freshly-(re)spawned reviewer dead too early.
      if [ "$_dead" = "1" ] && [ "$_spawn_age" -ge "$REFINO_RECONVENE_GRACE_SECS" ]; then
        SLOT_DEAD_STREAK=$(( SLOT_DEAD_STREAK + 1 ))
      else
        SLOT_DEAD_STREAK=0
      fi
      _confirmed_dead=0
      if [ "$_dead" = "1" ] && [ "$SLOT_DEAD_STREAK" -ge "$REFINO_RECONVENE_DEAD_STREAK_MIN" ]; then
        _confirmed_dead=1
      fi
      _action=$(refino_slot_action 0 "$_confirmed_dead" "$RECONVENE_BUDGET")
      if [ "$_action" = "respawn" ]; then
        RECONVENE_BUDGET=$(( RECONVENE_BUDGET - 1 ))
        _respawn_k=$(( REFINO_REVIEWER_RECONVENE_MAX - RECONVENE_BUDGET ))
        log "Re-convening dead refino reviewer (respawn ${_respawn_k}/${REFINO_REVIEWER_RECONVENE_MAX}) — session $SESSION_ID dead, verdict bead $VERDICT_BEAD_ID still pending (story $STORY_ID)."
        SLOT_SPAWN_EPOCH="$_now"   # reset the grace clock for the fresh reviewer
        SLOT_DEAD_STREAK=0
        if refino_spawn_reviewer "reconvene"; then
          log "  Re-convene: fresh reviewer $SESSION_ID spawned + rubric re-delivered (verdict bead reused, durable pull)."
          jq -c -n --arg ts "$(ts)" --arg story "$STORY_ID" --argjson k "$_respawn_k" \
            '{ts:$ts, event:"reconvene", story:$story, respawn:$k}' >> "$RG_LOG" 2>/dev/null || true
        else
          warn "  Re-convene: spawn failed — outer ${REFINO_VERDICT_TIMEOUT_MINUTES}m timeout is the backstop. spawn_err=${_spawn_err:-none}"
        fi
      fi
    fi
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
    _refino_gate_relabel "$STORY_ID" story:needs-approval
    bd_ comment "$STORY_ID" "Refino-gate: APROVADO na revisão de qualidade (round $THIS_ROUND). Promovido para 'Aguardando Aprovação' (story:needs-approval). O Athos faz a aprovação final." 2>/dev/null || true
    log "  $STORY_ID → story:needs-approval (Athos's queue)."
    ;;
  bounce)
    # FAIL within budget → back to the refiner with concrete notes.
    _refino_gate_relabel "$STORY_ID" story:refinement-in-progress
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
    _refino_gate_relabel "$STORY_ID" story:needs-approval
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
