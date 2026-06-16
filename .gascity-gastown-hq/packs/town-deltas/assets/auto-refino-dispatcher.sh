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
# Labels that mark a bead as BUILD / INFRA / SCRAPER-CONFIG work — NOT a refinable
# product story. A candidate carrying ANY of these is excluded from the funnel even
# if it (mis)carries a story:* lifecycle label. This is what keeps scraper-config
# beads (e.g. dc-yla3: labels custom,scraper) out of the product-refino funnel.
# JUDGEMENT CALL (bug 3) — env-overridable so the Mayor can tune the set without a
# code edit. Default is the clearly-non-product set; "custom" is deliberately NOT
# excluded (too ambiguous — could be a legit product tag).
AUTO_REFINO_EXCLUDE_LABELS="${AUTO_REFINO_EXCLUDE_LABELS:-scraper build infra config deploy migration pipeline}"

# ── RAW TRIAGEM INGESTION (Mayor-diagnosed funnel starvation) ─────────────────
# Raw stories enter the board with type=feature/story and NO story:* lifecycle
# label (the painel "Triagem" column). The original Step-1 candidate query only
# fetched beads ALREADY labelled story:triage / story:unrefined /
# story:refinement-in-progress, so these raw stories were NEVER fetched → the
# classifier never saw them → the funnel starved while ~37 stories piled up in
# Triagem and never reached Athos's "Sua vez" approval queue.
#
# With this flag ON (default), a 4th candidate source picks up raw no-label
# feature/story beads, applies story:unrefined at SELECTION (the entry label),
# and lets them flow through the EXISTING "fresh" path (refine simplificado →
# story:refino-review → gate → needs-approval → Sua vez). Mirrors the painel's
# _qualifies_for_triagem: open + visible work type + NO story:* label, excluding
# ephemeral / dc- / *-wisp- / gt:agent|gt:rig automation/identity beads, AND the
# existing build/non-product exclude set (AUTO_REFINO_EXCLUDE_LABELS).
#
# Set AUTO_REFINO_INGEST_RAW_TRIAGEM=0 to restore the EXACT prior behaviour
# (labelled-input only — no raw ingestion).
AUTO_REFINO_INGEST_RAW_TRIAGEM="${AUTO_REFINO_INGEST_RAW_TRIAGEM:-1}"

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

# auto_refino_is_product_story <labels_csv> <exclude_labels_space_separated>
#   Emit "no" iff the bead carries ANY label in the exclude set (build/infra/
#   scraper/config work — not a refinable product story); else "yes".
#   BUG 3 (dc-yla3): a scraper-config bead (labels custom,scraper) leaked into the
#   funnel and was repeatedly re-processed. Type-eligibility alone is not enough —
#   a build bead can carry type=feature + a story:* lifecycle label. The exclude
#   set is the discriminator. Empty exclude set ⇒ everything is a product story.
auto_refino_is_product_story() {
  local labels=",$1," ex="${2:-}" l
  for l in $ex; do
    [ -z "$l" ] && continue
    case "$labels" in *",$l,"*) echo "no"; return ;; esac
  done
  echo "yes"
}

# auto_refino_has_lifecycle_label <labels_csv>
#   Emit "yes" iff the bead carries ANY story:* lifecycle label (story:triage,
#   story:unrefined, story:refinement-in-progress, story:refino-review,
#   story:needs-approval, story:approved, story:in-flight, story:done,
#   story:cancelled, or any future story:* tag). Used to detect RAW Triagem
#   stories (no lifecycle label yet) for ingestion. Mirrors the painel's
#   `any(str(lbl).startswith("story:") ...)` test verbatim.
auto_refino_has_lifecycle_label() {
  local l
  # Split on commas and test each token for a story: prefix.
  local IFS=,
  for l in $1; do
    case "$l" in story:*) echo "yes"; return ;; esac
  done
  echo "no"
}

# auto_refino_is_ingestable_raw <id> <issue_type> <labels_csv> <ephemeral> <exclude_labels>
#   Emit "yes" iff this bead is a RAW Triagem story eligible for AUTO-INGESTION
#   into the funnel — i.e. it qualifies the way the painel's _qualifies_for_triagem
#   does, restricted to the funnel's product-story scope. ALL must hold:
#     - type is feature/story (auto_refino_type_eligible) — bug/chore/task bypass;
#     - NO story:* lifecycle label yet (auto_refino_has_lifecycle_label == no) —
#       a bead that already owns a lifecycle column is NOT raw;
#     - NOT an automation/identity/ephemeral bead: ephemeral!=true, id not dc-*,
#       id not *-wisp-*, no gt:agent / gt:rig label (mirror painel _is_automation_bead);
#     - it is a product story (auto_refino_is_product_story — build/scraper/config
#       excluded just like a labelled candidate would be).
#   Status (open) is enforced at the query level (--status open), exactly as the
#   labelled queries already are; this pure predicate covers the rest.
auto_refino_is_ingestable_raw() {
  local id="$1" itype="$2" labels="$3" ephemeral="$4" ex="${5:-}"
  local csv=",$labels,"
  # type must be in the funnel (feature/story).
  [ "$(auto_refino_type_eligible "$itype")" = "yes" ] || { echo "no"; return; }
  # must be RAW — no story:* lifecycle label.
  [ "$(auto_refino_has_lifecycle_label "$labels")" = "no" ] || { echo "no"; return; }
  # ephemeral beads are engine coordination, never human stories.
  [ "$ephemeral" = "true" ] && { echo "no"; return; }
  # dc-* (deacon coordination) and *-wisp-* (reconciler wisps) ids are automation.
  case "$id" in dc-*) echo "no"; return ;; esac
  case "$id" in *-wisp-*) echo "no"; return ;; esac
  # gt:agent / gt:rig identity beads are scaffolding, not work.
  case "$csv" in *,gt:agent,*|*,gt:rig,*) echo "no"; return ;; esac
  # already-ESCALATED stories are terminal (bug ga-it11w): terminal-escalate
  # strips all story:* labels, so an escalated story looks RAW (no lifecycle
  # label) — re-ingesting it loops forever. Disqualify it here too (the RAW jq
  # query already drops it; this is the classifier-side defense in depth).
  case "$csv" in *,auto-refino:escalated,*) echo "no"; return ;; esac
  # build/scraper/non-product beads are excluded just like labelled candidates.
  [ "$(auto_refino_is_product_story "$labels" "$ex")" = "yes" ] || { echo "no"; return; }
  echo "yes"
}

# If sourced by the selftest, stop here — expose the pure functions only.
if [ "${AUTO_REFINO_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── bd/gc wrappers ────────────────────────────────────────────────────────────
bd_() { bd -C "$GC_CITY" "$@"; }

# ── helper: read one label-CSV from a bead JSON row ───────────────────────────
_labels_csv() { echo "$1" | jq -r '(.labels // []) | join(",")'; }

# ── helper: additive lifecycle transition (NEVER --set-labels) ────────────────
# The mutually-exclusive story:* lifecycle labels. Exactly one should be present.
AUTO_REFINO_LIFECYCLE_LABELS="story:triage story:unrefined story:refinement-in-progress story:refino-review story:needs-approval story:approved story:in-flight story:done story:cancelled"

# _set_lifecycle <story_id> <new_lifecycle_label>
#   Move a bead to <new_lifecycle_label> WITHOUT clobbering unrelated labels.
#   BUG 2: the old `--set-labels X` REPLACED the entire label set, wiping custom /
#   scraper markers AND — critically (BUG 1) — the auto-refino:escalated skip flag
#   that the escalate path had just set, so escalated stories looked fresh again
#   and were re-picked every sweep (dc-yla3: attempt 1→2→3→4/3). This removes only
#   the OTHER known lifecycle labels then adds the target — additive, so escalate
#   markers and any non-lifecycle labels survive.
_set_lifecycle() {
  local sid="$1" want="$2" l
  for l in $AUTO_REFINO_LIFECYCLE_LABELS; do
    [ "$l" = "$want" ] && continue
    bd_ label remove "$sid" "$l" -q 2>/dev/null || true
  done
  bd_ label add "$sid" "$want" -q 2>/dev/null || true
}

# _clear_lifecycle <story_id>
#   Remove EVERY candidate lifecycle label (story:triage / story:unrefined /
#   story:refinement-in-progress + the rest) WITHOUT adding any back. Non-lifecycle
#   labels (auto-refino:escalated, domain tags) are untouched — additive, never
#   --set-labels.
#   ESCALATE-LOOP RE-FIX: the prior fix's escalate path KEPT story:refinement-in-
#   progress and relied SOLELY on the auto-refino:escalated marker to exclude the
#   bead from the BOUNCE query (--label story:refinement-in-progress --assignee us).
#   That is a single point of failure: the moment auto-refino:escalated is stripped
#   for ANY reason (old-code --set-labels residue, a manual edit, the Step-0 TTL
#   recovery dropping auto-refino:refining and leaving a bare in-progress bead) the
#   story is STRUCTURALLY a bounce candidate again and re-escalates. dc-yla3 reached
#   attempt 5/3 exactly this way: after the fix deployed, TTL recovery restored a
#   clean in-progress+assigned bead with NO escalated marker, so the next sweep
#   re-selected it as state=bounce and escalated again. Removing the lifecycle label
#   entirely means NO candidate query (FRESH/UNREF/BOUNCE) can match the bead — the
#   structural belt to the escalated-marker suspenders.
_clear_lifecycle() {
  local sid="$1" l
  for l in $AUTO_REFINO_LIFECYCLE_LABELS; do
    bd_ label remove "$sid" "$l" -q 2>/dev/null || true
  done
}

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

# ── 4th source: RAW Triagem stories with NO story:* lifecycle label ───────────
# (Mayor-diagnosed starvation fix; gated by AUTO_REFINO_INGEST_RAW_TRIAGEM.)
# `bd list` has no "missing-label" filter, so we fetch ALL open feature/story
# beads and filter IN JQ to those carrying NO label matching ^story:, dropping
# automation/identity/ephemeral beads (dc-/-wisp-/gt:agent/gt:rig/ephemeral) the
# way the painel's _qualifies_for_triagem does. The pure
# auto_refino_is_ingestable_raw predicate re-asserts every rule per candidate
# below (defense in depth: query narrows in jq, classifier disqualifies). These
# raw candidates carry no lifecycle label, so the classifier alone would skip
# them — they are PRE-LABELLED story:unrefined at selection (Step 1b) so they
# flow through the existing "fresh" path unchanged.
RAW_JSON="[]"
if [ "$AUTO_REFINO_INGEST_RAW_TRIAGEM" = "1" ]; then
  # feature type (and `story` if the build models it as a distinct type).
  _RAW_FEATURE=$(bd_ list --type feature --status open --json 2>/dev/null || echo "[]")
  _RAW_STORY=$(bd_ list --type story --status open --json 2>/dev/null || echo "[]")
  RAW_JSON=$(jq -s '
    (.[0] + .[1])
    | unique_by(.id)
    # RAW = carries NO story:* lifecycle label (the painel Triagem criterion).
    | map(select(((.labels // []) | any(type=="string" and startswith("story:"))) | not))
    # Drop automation / identity / ephemeral beads (painel _is_automation_bead).
    | map(select((.ephemeral // false) != true))
    | map(select(((.id // "") | (startswith("dc-") or contains("-wisp-"))) | not))
    | map(select(((.labels // []) | any(. == "gt:agent" or . == "gt:rig")) | not))
    # Drop already-ESCALATED stories (bug ga-it11w): terminal-escalate strips all
    # story:* labels, so an escalated story (only auto-refino:escalated, no
    # story:*) would otherwise be re-captured by this RAW source and re-ingested
    # with story:unrefined every sweep → infinite re-ingestion loop (see ga-m9gt3).
    | map(select(((.labels // []) | any(. == "auto-refino:escalated")) | not))
  ' <(echo "$_RAW_FEATURE") <(echo "$_RAW_STORY") 2>/dev/null || echo "[]")
  _RAWCOUNT=$(echo "$RAW_JSON" | jq 'length' 2>/dev/null || echo 0)
  log "Raw-Triagem ingestion ON: $_RAWCOUNT no-lifecycle-label feature/story bead(s) eligible (pre-classification)."
else
  log "Raw-Triagem ingestion OFF (AUTO_REFINO_INGEST_RAW_TRIAGEM=0) — labelled input only."
fi

CANDIDATES=$(jq -s 'add | unique_by(.id)' \
  <(echo "$FRESH_JSON") <(echo "$UNREF_JSON") <(echo "$BOUNCE_JSON") <(echo "$RAW_JSON") 2>/dev/null || echo "[]")
CCOUNT=$(echo "$CANDIDATES" | jq 'length' 2>/dev/null || echo 0)
if [ "$CCOUNT" -eq 0 ] 2>/dev/null; then
  log "No Triagem stories to auto-refine. Sweep done."
  exit 0
fi
log "$CCOUNT candidate story(ies) in Triagem (pre-classification)."

# Classify with the pure core; keep only fresh/bounce candidates of an eligible
# type. Oldest-first (FIFO) so the backlog drains in arrival order.
STORY=""
RAW_INGEST=0   # set to 1 when the selected candidate is a raw no-label story to pre-label
while IFS= read -r row; do
  [ -z "$row" ] && continue
  c_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$c_id" ] && continue
  c_type=$(echo "$row" | jq -r '.issue_type // .type // "feature"')
  c_labels=$(_labels_csv "$row")
  c_assignee=$(echo "$row" | jq -r '.assignee // empty')
  c_ephemeral=$(echo "$row" | jq -r 'if (.ephemeral // false)==true then "true" else "false" end')
  [ "$(auto_refino_type_eligible "$c_type")" = "yes" ] || { log "  skip $c_id: type '$c_type' not in funnel (bug/chore/task bypass)"; continue; }
  [ "$(auto_refino_is_product_story "$c_labels" "$AUTO_REFINO_EXCLUDE_LABELS")" = "yes" ] || { log "  skip $c_id: carries build/non-product label (auto-refino excludes: $AUTO_REFINO_EXCLUDE_LABELS) — not a product story"; continue; }
  state=$(auto_refino_lifecycle_state "$c_labels" "$c_assignee" "$AUTO_REFINO_ACTOR")
  case "$state" in
    fresh|bounce) STORY="$row"; RAW_INGEST=0; break ;;
    *)
      # Not a labelled candidate. If raw-ingestion is on and this bead is a RAW
      # Triagem story (no story:* label, not automation/build), INGEST it: select
      # it and flag it for story:unrefined pre-labelling (Step 1b), after which it
      # flows through the identical "fresh" path. The labelled-input behaviour
      # above is untouched — this branch only ever fires for no-label beads.
      if [ "$AUTO_REFINO_INGEST_RAW_TRIAGEM" = "1" ] \
         && [ "$(auto_refino_is_ingestable_raw "$c_id" "$c_type" "$c_labels" "$c_ephemeral" "$AUTO_REFINO_EXCLUDE_LABELS")" = "yes" ]; then
        STORY="$row"; RAW_INGEST=1
        log "  ingest $c_id: raw Triagem story (no story:* label) → applying story:unrefined entry label"
        break
      fi
      : ;;  # skip
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

# ── Step 1b: INGESTION — pre-label a raw Triagem story story:unrefined ─────────
# A raw candidate (RAW_INGEST=1) carries NO story:* label, so the classifier
# would call it "skip". Apply story:unrefined NOW (the entry label) so it becomes
# an ordinary "fresh" candidate and flows through the EXACT existing fresh path
# (claim → refine simplificado → story:refino-review → gate → needs-approval).
# Additive (label add, not --set-labels) so any domain/non-lifecycle labels
# survive. Update the in-memory STORY JSON too so STATE below resolves to "fresh".
if [ "$RAW_INGEST" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    log "WOULD ingest $STORY_ID: add story:unrefined entry label (raw Triagem) — DRY_RUN"
  else
    bd_ label add "$STORY_ID" "story:unrefined" -q 2>/dev/null || true
    bd_ comment "$STORY_ID" "Auto-refino: história crua da Triagem (sem label de ciclo) ingerida no funil — story:unrefined aplicado. Vai passar pelo refino simplificado → gate → aprovação." 2>/dev/null || true
    log "  Ingested $STORY_ID into the funnel (story:unrefined applied)."
  fi
  # Reflect the new entry label in the in-memory row so the lifecycle classifier
  # (and every downstream consumer of STORY) sees a fresh, labelled story.
  STORY=$(echo "$STORY" | jq -c '.labels = ((.labels // []) + ["story:unrefined"] | unique)')
fi

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
  _set_lifecycle "$STORY_ID" "story:refinement-in-progress"
  bd_ update "$STORY_ID" --assignee "$AUTO_REFINO_ACTOR" -q 2>/dev/null || true
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
# Transition ADDITIVELY (remove the in-progress lifecycle, add refino-review) so
# unrelated labels are preserved; do NOT use --set-labels (it would clobber them).
# This does NOT set needs-approval — only the gate promotes.
bd -C "$GC_CITY" label remove "$STORY_ID" "story:refinement-in-progress"
bd -C "$GC_CITY" label add "$STORY_ID" "story:refino-review"
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
# TERMINAL escalate: remove EVERY lifecycle label so no candidate query can re-pick
# this story (the dispatcher reconciles this too, but be terminal here as well).
bd -C "$GC_CITY" label remove "$STORY_ID" "story:refinement-in-progress"
bd -C "$GC_CITY" label remove "$STORY_ID" "story:triage"
bd -C "$GC_CITY" label remove "$STORY_ID" "story:unrefined"
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
    # TERMINAL escalate (ga-flxp6 re-fix). The story now waits on Athos: it must
    # NOT be dispatchable (Pilot only dispatches story:approved, so removing the
    # lifecycle label is safe) and — critically — it must NOT match ANY candidate
    # query again. The prior fix KEPT story:refinement-in-progress and leaned only
    # on the auto-refino:escalated marker to exclude it; that single marker getting
    # stripped (old-code residue / manual edit / TTL recovery) re-armed the bounce
    # query and re-escalated the bead (dc-yla3 → attempt 5/3). _clear_lifecycle
    # removes EVERY lifecycle label additively (auto-refino:escalated + domain tags
    # survive), so the FRESH/UNREF/BOUNCE queries can no longer structurally return
    # it — structural belt to the escalated-marker + product-filter suspenders.
    _clear_lifecycle "$STORY_ID"
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
      _set_lifecycle "$STORY_ID" "story:refinement-in-progress"
      bd_ update "$STORY_ID" --assignee "$AUTO_REFINO_ACTOR" -q 2>/dev/null || true
    else
      _set_lifecycle "$STORY_ID" "story:unrefined"
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
