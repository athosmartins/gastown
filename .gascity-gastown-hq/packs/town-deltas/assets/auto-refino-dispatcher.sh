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

# ── Multi-store funnel (Mayor-diagnosed rig-store starvation) ─────────────────
# Feature stories live in THREE separate bead stores: the HQ city store plus the
# WhatsApp-automation (WA) and property-scrapers (PS) rig stores. The original
# daemon only ever queried/wrote HQ ($GC_CITY), so a story created in a rig store
# (e.g. a WA feature in story:triage, or a PS feature in story:unrefined) was
# NEVER ingested into the refino funnel — it sat in the painel's "Triagem" column
# forever, invisible to this daemon.
#
# Fix mirrors the PROVEN multi-store shape of context-check-dispatcher.sh: define
# AUTO_REFINO_STORES (default = HQ + WA + PS), make bd_() target a per-iteration
# store ($AR_STORE, defaulting to $GC_CITY so single-store callers/tests are
# unchanged), and loop Step 0 / Step 0c / Step 1 over each store. The one-story-
# per-sweep cap stays GLOBAL across stores: the FIRST store with an eligible
# candidate is processed and the daemon returns; the launchd interval drains the
# rest (a later sweep moves to the next store). Critically, query AND write-back
# (claim, refiner task heredoc, outcome) all target the bead's OWN store — a WA
# story's labels/comments/metadata land in the WA store, never in HQ.
AUTO_REFINO_STORES="${AUTO_REFINO_STORES:-$GC_CITY /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"

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
# Grace period (seconds) before Step 6 starts trusting a "drained" reading on the
# refiner session (ga-bvbm). A fresh session can take real wall-clock time to
# boot; a drained-adhoc reading during that window is more likely a not-yet-
# indexed roster than a genuine stale_async_start death. After the grace period,
# "asleep" for an adhoc worker is terminal (drain-acked, wake_mode=fresh never
# resumes prior work — same rule as the sibling _session_is_live_builder check).
AUTO_REFINO_DRAINED_GRACE_SECONDS="${AUTO_REFINO_DRAINED_GRACE_SECONDS:-120}"
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
# A no-label bead mutated more recently than this is disqualified from RAW
# ingestion (ga-51ry, 3rd occurrence wa-soe8a): a manual or automated recovery
# transition (e.g. the Mayor clearing gate:needs-human to retry) can clear the
# LAST protective story:*/gate:* label moments before applying its replacement.
# The periodic RAW sweep can land inside that gap (observed: 87s) and mistake
# an already-triaged, already-approved/gated story for genuinely-untriaged raw
# work. Sized above one launchd sweep interval (~5m, see FIX C below) so a
# recovery in flight has a full cycle to land its replacement label; a
# genuinely-fresh raw story is merely delayed one sweep, never starved.
AUTO_REFINO_RAW_MIN_AGE_MINUTES="${AUTO_REFINO_RAW_MIN_AGE_MINUTES:-5}"

# ── DELIVERED-DUPLICATE CHECK (wa-ca4jm) ──────────────────────────────────────
# Before promoting a freshly-refined story to refino-gate, check whether a
# DELIVERED twin already exists in the same store. A twin is "delivered" when
# its status=closed OR it carries gate:passed OR story:done.  If one is found,
# the handoff is blocked: the story is reverted to refino:info-gap +
# auto-refino:escalado and Athos is paged — preventing the gate from re-approving
# already-built work (wa-v3tz, wa-nvn9, wa-cqh5 slipped through this week).
#
# FAIL-OPEN: any error in the dup-check (bad JSON, bd failure) is swallowed and
# the normal handoff proceeds — a false-negative is safer than a false-positive
# blocking a non-dup story.
# ENV:
#   AUTO_REFINO_DUP_CHECK=1    (default ON; set 0 to disable entirely)
#   AUTO_REFINO_DUP_THRESHOLD  similarity threshold passed to find-duplicates
#                              (default 0.5 = bd's own default)
AUTO_REFINO_DUP_CHECK="${AUTO_REFINO_DUP_CHECK:-1}"
AUTO_REFINO_DUP_THRESHOLD="${AUTO_REFINO_DUP_THRESHOLD:-0.5}"

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
  # story:refino-escalado (ga-lfua3) is the painel's canonical escalation label,
  # now ALSO set on escalate so the story surfaces in "Sua vez"; it is terminal here
  # too (waiting on Athos) — a structural belt independent of auto-refino:escalated,
  # so even if the daemon's own marker is stripped the story is still not re-picked.
  case "$csv" in
    *,auto-refino:refining,*|*,auto-refino:escalated,*|*,refino-gate:reviewing,*|\
*,story:refino-escalado,*|\
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
    # imp16: info-gap = thin/duplicate/trivial — technical, not a product decision
    "ESCALATE:info-gap") echo "escalate-info-gap" ;;
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

# auto_refino_is_ingestable_raw <id> <issue_type> <labels_csv> <ephemeral> <exclude_labels> <age_minutes> <min_age_minutes> <assignee> <has_children> <has_refino_metadata>
#   Emit "yes" iff this bead is a RAW Triagem story eligible for AUTO-INGESTION
#   into the funnel — i.e. it qualifies the way the painel's _qualifies_for_triagem
#   does, restricted to the funnel's product-story scope. ALL must hold:
#     - type is feature/story (auto_refino_type_eligible) — bug/chore/task bypass;
#     - NO story:* lifecycle label yet (auto_refino_has_lifecycle_label == no) —
#       a bead that already owns a lifecycle column is NOT raw;
#     - NOT an automation/identity/ephemeral bead: ephemeral!=true, id not dc-*,
#       id not *-wisp-*, no gt:agent / gt:rig label (mirror painel _is_automation_bead);
#     - it is a product story (auto_refino_is_product_story — build/scraper/config
#       excluded just like a labelled candidate would be);
#     - NOT too-freshly-mutated (ga-51ry): age_minutes (caller-computed minutes
#       since updated_at) must be >= min_age_minutes. age_minutes/min_age_minutes
#       are OPTIONAL (trailing, default ""/0) so every pre-existing call site
#       keeps its exact prior behaviour unless it opts in by passing them.
#     - NOT already claimed / already split / already escalated by refino's own
#       policy-gap (bug ga-blron: auto-refino swallowed already-owned work as if
#       it were a raw idea — lost dispatch, and re-asked Athos decisions already
#       made or already executed, 3+ occurrences in one day). assignee/
#       has_children are ALSO OPTIONAL trailing params (default ""/"no"), same
#       backward-compat convention as age_minutes/min_age_minutes:
#         - assignee non-empty → someone already owns this bead. Cheap, but NOT
#           sufficient alone — the lifecycle-coherence-janitor's R4 rule clears
#           assignee on ctx:ready/story:approved beads without checking
#           liveness, so a genuinely-claimed bead can arrive here with an empty
#           assignee (measured live on wa-ku5j1). has_children is the robust
#           fallback for exactly that gap.
#         - has_children="yes" (caller MUST compute via `bd children <id>
#           --json`, length>0 — NOT dependent_count: measured live to disagree
#           with itself between `bd list` and `bd show`, and it does not track
#           PARENT relationships at all, only `dep add` edges) → already split
#           into sub-work; refining/re-splitting the parent re-asks a decision
#           already taken (wa-ku5j1's children were all closed — already
#           delivered, not just decided).
#           CAVEAT (bug ga-8bjhl, wa-pxvox): both this check AND the story:*
#           label check above are defeated if a split is executed WITHOUT the
#           Epic Split Convention (skills/refino/references/story-bead-
#           convention.md: --type epic --set-labels story:epic-split on the
#           umbrella, --parent on each child) — e.g. a split recorded only via
#           free-text comment + sibling `blocks` deps between the children
#           leaves `bd children` empty AND no story:* label, so the umbrella
#           looks untouched again. Not fixable from inside this pure
#           classifier (it has no way to know a split happened with zero
#           structural trace). The actual fix is upstream, at the point a
#           POLICY-GAP escalation gets resolved: see the escalate-time
#           reminder next to the `story:needs-human` stamp below.
#         - has_refino_metadata="yes" (caller MUST compute via `bd show <id>
#           --json` checking whether ANY of the story.refino_mode /
#           story.refino_gate_rounds / story.criterios metadata keys is
#           non-empty) → this bead already carries real refino output,
#           independent of its CURRENT label state (bug ga-mk6ve, 9th
#           confirmed re-ingestion — ga-m3n1x: refined, gate-approved,
#           Athos-approved TWICE, still got re-ingested as a fresh idea).
#           Every prior fix in this function enumerated a SPECIFIC label or
#           mechanism that zeroed the bead's story:* tags — reclaim-guard
#           clearing story:in-flight, a namespaced needs-human variant, an
#           unexplained label loss, and finally a HUMAN clearing block labels
#           via the painel. A blocklist can never be exhaustive against "the
#           label is simply absent" — that is not a label prefix to add to
#           the list, it is the absence of any label at all. Metadata written
#           once at refino time is untouched by any of those label-clearing
#           paths, so it is the first POSITIVE, not-label-based signal that
#           this bead was already refined.
#   Status (open) is enforced at the query level (--status open), exactly as the
#   labelled queries already are; this pure predicate covers the rest.
auto_refino_is_ingestable_raw() {
  local id="$1" itype="$2" labels="$3" ephemeral="$4" ex="${5:-}"
  local age_min="${6:-}" min_age="${7:-0}"
  local assignee="${8:-}" has_children="${9:-no}" has_refino_metadata="${10:-no}"
  # Sanitize like auto_refino_next_attempt: garbage/empty age_min fails OPEN
  # (treated as ancient, i.e. never age-excluded) so a missing/unparseable
  # updated_at can never silently starve the RAW funnel. Garbage min_age
  # disables the guard (0 minutes — nothing is ever "too fresh").
  case "$age_min" in ''|*[!0-9]*) age_min=999999 ;; esac
  case "$min_age" in ''|*[!0-9]*) min_age=0 ;; esac
  local csv=",$labels,"
  # type must be in the funnel (feature/story).
  [ "$(auto_refino_type_eligible "$itype")" = "yes" ] || { echo "no"; return; }
  # must be RAW — no story:* lifecycle label.
  [ "$(auto_refino_has_lifecycle_label "$labels")" = "no" ] || { echo "no"; return; }
  # already carries real refino output (bug ga-mk6ve, 9th confirmed
  # re-ingestion): a positive signal independent of current label state — see
  # the has_refino_metadata param doc above for why labels alone can never be
  # sufficient here.
  [ "$has_refino_metadata" = "yes" ] && { echo "no"; return; }
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
  # already in the BUILD/GATE pipeline (ga-dt6bu / ga-oonk3 thrash): /gate-done +
  # circuit-break can leave a gate:* label but NO story:* label, so the bead looks
  # RAW and gets re-ingested every sweep. Any gate:* label disqualifies it (the RAW
  # jq query also drops it; classifier-side defense in depth). csv is comma-wrapped.
  case "$csv" in *,gate:*) echo "no"; return ;; esac
  # already flagged by refino's OWN policy-gap escalation (bug ga-blron, 4th
  # occurrence, wa-ku5j1): a bead carrying refino:policy-gap already went
  # through refino and is waiting on a human decision (e.g. "approve this
  # split") — re-ingesting it loops the same already-answered/already-executed
  # ask (the RAW jq query mirrors this too; classifier-side defense in depth).
  case "$csv" in *,refino:policy-gap,*) echo "no"; return ;; esac
  # under an active hold from another authority (bug ga-268cr, occurrences
  # 2/3/5/6): blocked:*, needs-human*, pilot:held* (bare or -until:<epoch>),
  # blocked-on:* (hyphenated — a DISTINCT prefix from blocked:*, not a typo),
  # and pool:refused:* all mean Oracle/Mayor/a builder has deliberately parked
  # this story — the RAW sweep must never override that hold (the RAW jq query
  # also drops these; classifier-side defense in depth). csv is comma-wrapped
  # so *,prefix* matches any label starting with prefix.
  case "$csv" in *,blocked:*|*,needs-human*|*,pilot:held*|*,blocked-on:*|*,pool:refused:*) echo "no"; return ;; esac
  # too-freshly-mutated (ga-51ry): this bead was updated inside the last
  # min_age minutes — likely mid a non-atomic recovery transition (a
  # story:*/gate:* protective label was JUST cleared and the replacement has
  # not landed yet). Wait it out rather than mistake it for genuinely-raw work
  # (the RAW jq query mirrors this too; classifier-side defense in depth).
  [ "$age_min" -lt "$min_age" ] && { echo "no"; return; }
  # already-ASSIGNED (bug ga-blron, occurrences 1-3): someone already claimed
  # this bead — not an orphan idea waiting for triage, it is dispatched work.
  # The RAW jq query mirrors this too; classifier-side defense in depth. NOT
  # sufficient alone (see has_children below and the param doc above).
  [ -n "$assignee" ] && { echo "no"; return; }
  # already SPLIT (bug ga-blron, occurrence 3, wa-ku5j1: 4 children, all
  # closed). NOT mirrored in the RAW jq query — that layer is pure jq and
  # cannot make the live `bd children` call this needs; this classifier call is
  # the only enforcement point.
  [ "$has_children" = "yes" ] && { echo "no"; return; }
  # build/scraper/non-product beads are excluded just like labelled candidates.
  [ "$(auto_refino_is_product_story "$labels" "$ex")" = "yes" ] || { echo "no"; return; }
  echo "yes"
}

# auto_refino_session_drained <sessions_json> <session_id>
#   ga-bvbm: the refiner is spawned as an ephemeral …-adhoc-… worker, which can
#   hit the stale_async_start race and drain during its OWN startup — before
#   ever consuming the queued refine task. Step 6 previously had no way to tell
#   that apart from "still working"; it just burned the full timeout every time.
#
#   Emits "yes" iff <session_id> names an entry in <sessions_json> ("gc session
#   list --json" shape) that has PROVABLY drained and will NEVER resume:
#     - closed == true, OR
#     - state == "asleep" AND the entry is an …-adhoc-… worker (drain-acked;
#       wake_mode=fresh means a later wake re-claims from the pool, it does NOT
#       resume this build — same rule as the sibling _session_is_live_builder
#       check / ga-mrfb).
#   Emits "no" for a live session, for an id not (yet) present in the roster
#   (absence of evidence is not evidence of death — a brand-new session may not
#   be indexed instantly), and for empty/malformed input (fail open: the worst
#   case is falling back to the pre-fix behaviour of waiting out the timeout,
#   never a false kill of a healthy refine).
auto_refino_session_drained() {
  local sessions_json="${1:-}" sid="${2:-}"
  [ -n "$sid" ] || { echo "no"; return; }
  echo "$sessions_json" | jq -e '.sessions | type=="array"' >/dev/null 2>&1 || { echo "no"; return; }
  echo "$sessions_json" | jq -r --arg id "$sid" '
    ([.sessions[]? | select(.id == $id)] | .[0]) as $s
    | if ($s == null) then "no"
      elif ($s.closed == true) then "yes"
      elif ($s.state == "asleep") and
           ([$s.session_name, $s.name, $s.alias, $s.agent_name]
             | map(select(. != null)) | any(test("-adhoc-"))) then "yes"
      else "no"
      end
  ' 2>/dev/null || echo "no"
}

# If sourced by the selftest, stop here — expose the pure functions only.
if [ "${AUTO_REFINO_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── FIX C: single-instance mkdir-mutex (mirrors the Pilot daemon, ga-7s0or) ──
# WHY: the refiner timeout (AUTO_REFINO_TIMEOUT_MINUTES, default 25m) is FAR longer
# than the launchd interval (~5m). Without a lock, launchd starts a fresh sweep
# every 5m while the previous one is still polling its refiner — so up to 5 sweeps
# stack concurrently, each spawning a Sonnet refiner, blowing past the
# auto-refiner template cap (max_active_sessions=3 in agents/auto-refiner/agent.toml).
# Caught live running 5 refiners against a cap of 3 = real Sonnet + Dolt over-spend
# while the higher stages sit idle. A single-instance lock caps it at ONE live
# sweep: a second launchd invocation finds the lock held by a LIVE holder and
# exits 0 mutating nothing, so the refiner count can never exceed 1-in-flight from
# this daemon (≤ the cap).
#
# Mechanism copied verbatim in spirit from the Pilot daemon's fd-LESS lock:
#   • atomic `mkdir` mutex (POSIX-atomic; no fd, so a leaked fd in the spawned
#     refiner can never keep the dir "locked");
#   • a heartbeat file whose MTIME marks liveness — a crashed sweep leaves the dir
#     but stops refreshing it, so a stale holder (mtime age ≥ MAX_AGE) is recovered
#     automatically via an atomic rename (only one recoverer can win the rename);
#   • released on EXIT via trap, only if WE still own it (token match).
# Env kill-switch: AUTO_REFINO_LOCK=0 disables the guard entirely (exact prior
# behaviour). FAIL-OPEN: any error in the lock SYSTEM (mkdir/stat unavailable) must
# never wedge the funnel — on an unexpected lock-internal failure we proceed.
AUTO_REFINO_LOCK="${AUTO_REFINO_LOCK:-1}"
AUTO_REFINO_LOCK_DIR="${TMPDIR:-/tmp}/auto-refino-dispatcher$(printf '%s' "$GC_CITY" | tr '/ ' '__').lock.d"
AUTO_REFINO_LOCK_HB="$AUTO_REFINO_LOCK_DIR/heartbeat"
# A real sweep can run up to the refiner timeout; size MAX_AGE above that so a
# genuinely-busy sweep is never judged stale, while a crashed one is still reclaimed
# within a couple of launchd intervals. Default = timeout + 10m headroom (seconds).
AUTO_REFINO_LOCK_MAX_AGE="${AUTO_REFINO_LOCK_MAX_AGE:-$(( (AUTO_REFINO_TIMEOUT_MINUTES + 10) * 60 ))}"
AUTO_REFINO_LOCK_TOKEN="$$:${RANDOM}${RANDOM}"

# Age (seconds) of the heartbeat file; a huge number if it is missing.
_ar_lock_hb_age() {
  local _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$AUTO_REFINO_LOCK_HB" 2>/dev/null || stat -c %Y "$AUTO_REFINO_LOCK_HB" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}

_ar_lock_write_hb() { printf '%s\n' "$AUTO_REFINO_LOCK_TOKEN" > "$AUTO_REFINO_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a peer
# that recovered our lock after we were (wrongly) judged stale.
_release_ar_lock() {
  local _own
  _own=$(head -n1 "$AUTO_REFINO_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$AUTO_REFINO_LOCK_TOKEN" ] && rm -rf "$AUTO_REFINO_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE sweep holds it (back off).
_acquire_ar_lock() {
  if mkdir "$AUTO_REFINO_LOCK_DIR" 2>/dev/null; then
    _ar_lock_write_hb
    return 0
  fi
  local _age
  _age=$(_ar_lock_hb_age)
  if [ "$_age" -lt "$AUTO_REFINO_LOCK_MAX_AGE" ] 2>/dev/null; then
    return 1   # fresh heartbeat → a live sweep is running.
  fi
  # Stale holder. Atomically claim the recovery by renaming the dir aside; only one
  # concurrent recoverer can win this rename (the rest get ENOENT).
  local _reaped="${AUTO_REFINO_LOCK_DIR}.reaping.${AUTO_REFINO_LOCK_TOKEN}"
  if mv "$AUTO_REFINO_LOCK_DIR" "$_reaped" 2>/dev/null; then
    rm -rf "$_reaped" 2>/dev/null || true
    if mkdir "$AUTO_REFINO_LOCK_DIR" 2>/dev/null; then
      _ar_lock_write_hb
      log "Recovered STALE auto-refino lock (heartbeat age ${_age}s ≥ ${AUTO_REFINO_LOCK_MAX_AGE}s) — taking over."
      return 0
    fi
  fi
  return 1   # lost the recovery race to a peer, or a fresh sweep beat us.
}

if [ "$AUTO_REFINO_LOCK" = "1" ]; then
  if _acquire_ar_lock; then
    trap '_release_ar_lock' EXIT
  else
    log "Another auto-refino sweep holds $AUTO_REFINO_LOCK_DIR — backing off (single-instance guard, FIX C). Refiner cap protected."
    exit 0
  fi
fi

# ── bd/gc wrappers ────────────────────────────────────────────────────────────
# Targets the current per-iteration store ($AR_STORE), defaulting to $GC_CITY so
# any caller outside the per-store loop (and the selftest) keeps single-store HQ
# behaviour. Mirrors context-check-dispatcher.sh's `bd -C "${CC_STORE:-$GC_CITY}"`.
bd_() { bd -C "${AR_STORE:-$GC_CITY}" "$@"; }

# ── FIX B: cross-stage contention-yield (mirrors the Pilot daemon, ga-d0hz3) ─
# WHY: the 3 autonomous daemons run stage-DESCENDING priority — gate-review
# (highest) > execute-approved (Pilot) > refine-triage (THIS, lowest). The Pilot
# already YIELDs to a congested Gate under resource contention (ga-d0hz3); refino,
# the LOWEST stage, had no such guard and kept refining (Sonnet + Dolt churn) even
# while the gate was backed up and the quota/Dolt were strained. This block makes
# refino DEFER a sweep (log, exit 0, mutate NOTHING) IFF a higher stage has work
# AND resources are contended — so the scarce Claude quota + Dolt go to the more
# advanced stages first.
#
# DEFER iff:
#   ( gate CONGESTED  [queued markers>0 OR running runs>0]
#     OR the Pilot has approved work waiting [open story:approved, unassigned] )
#   AND
#   ( resources CONTENDED [Claude 5h quota limited OR Dolt hot/saturated] )
#
# ANTI-STARVATION: the defer is CONDITIONAL on resource-tight. When the quota is OK
# AND Dolt is calm it NEVER defers — a calm, gate-empty, quota-OK moment ALWAYS
# runs refino. The instant Dolt calms / the quota frees, refino resumes; it can
# never be starved indefinitely.
# FAIL-OPEN: every probe returns the NON-deferring value ("0") on any error, so a
# bad/blind check can never wedge the refino funnel.
# Env kill-switch: AUTO_REFINO_YIELD=0 disables the whole gate (exact prior behaviour).
AUTO_REFINO_YIELD="${AUTO_REFINO_YIELD:-1}"
# Thresholds + test seams mirror the Pilot's verbatim so both daemons read the same
# saturation signal. Defaults match the Pilot daemon (lat>2500ms, cpu>200%).
AUTO_REFINO_DOLT_LATENCY_MAX_MS="${AUTO_REFINO_DOLT_LATENCY_MAX_MS:-2500}"
AUTO_REFINO_DOLT_CPU_MAX="${AUTO_REFINO_DOLT_CPU_MAX:-200}"
AUTO_REFINO_DOLT_LATENCY_OVERRIDE_MS="${AUTO_REFINO_DOLT_LATENCY_OVERRIDE_MS:-}"
AUTO_REFINO_DOLT_CPU_OVERRIDE="${AUTO_REFINO_DOLT_CPU_OVERRIDE:-}"
AUTO_REFINO_QUOTA_OVERRIDE="${AUTO_REFINO_QUOTA_OVERRIDE:-}"
AUTO_REFINO_GATE_CONGESTED_OVERRIDE="${AUTO_REFINO_GATE_CONGESTED_OVERRIDE:-}"
AUTO_REFINO_PILOT_WORK_OVERRIDE="${AUTO_REFINO_PILOT_WORK_OVERRIDE:-}"

# _ar_quota_limited → "1" iff the Claude 5h window is exhausted right now, else "0".
# Mirrors the Pilot's _pilot_quota_limited (ga-x3nmz): ga-wjlv9 ground-truth
# checker (exit 2 = LIMITED). FAIL-OPEN "0" when the checker is absent/errors.
# Honors AUTO_REFINO_QUOTA_OVERRIDE ("2"=limited) test seam. Bounded. No mutation.
_ar_quota_limited() {
  if [ -n "$AUTO_REFINO_QUOTA_OVERRIDE" ]; then
    [ "$AUTO_REFINO_QUOTA_OVERRIDE" = "2" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf '0'; return 0; }
  local _rc=0
  timeout 15 bash "$_qc" --quiet >/dev/null 2>&1 || _rc=$?
  [ "$_rc" = "2" ] && { printf '1'; return 0; }
  printf '0'; return 0
}

# _ar_dolt_hot → "1" iff Dolt is saturated (latency OR cpu over ceiling), else "0".
# Mirrors the Pilot's _dolt_probe/_dolt_saturated (ga-rk5va). NOTE the
# deliberate difference: the Pilot fail-SAFEs a blind probe to SATURATED because it
# is about to ADD heavy build load; refino (the lowest stage) instead fail-OPENs a
# blind probe to "0" (NOT hot) per the FIX-B fail-open contract — a daemon that
# can't read Dolt must keep refining, not wedge. Honors the latency/cpu test seams.
_ar_dolt_hot() {
  local _lat="" _cpu="" _pid="" _h
  if [ -n "$AUTO_REFINO_DOLT_LATENCY_OVERRIDE_MS" ]; then
    _lat="$AUTO_REFINO_DOLT_LATENCY_OVERRIDE_MS"
  else
    _h=$(GC_CITY="$GC_CITY" timeout 15 gc dolt health --json 2>/dev/null || echo "")
    _lat=$(printf '%s' "$_h" | jq -r '.server.latency_ms // empty' 2>/dev/null || echo "")
    _pid=$(printf '%s' "$_h" | jq -r '.server.pid // empty' 2>/dev/null || echo "")
  fi
  if [ -n "$AUTO_REFINO_DOLT_CPU_OVERRIDE" ]; then
    _cpu="$AUTO_REFINO_DOLT_CPU_OVERRIDE"
  elif [ -n "$_pid" ]; then
    _cpu=$(ps -o %cpu= -p "$_pid" 2>/dev/null | tr -d ' ' | cut -d. -f1 || true)
  fi
  if [ -n "$_lat" ] && [ "$_lat" -ge 0 ] 2>/dev/null; then
    [ "$_lat" -gt "$AUTO_REFINO_DOLT_LATENCY_MAX_MS" ] 2>/dev/null && { printf '1'; return 0; }
  fi
  if [ -n "$_cpu" ] && [ "$_cpu" -ge 0 ] 2>/dev/null; then
    [ "$_cpu" -gt "$AUTO_REFINO_DOLT_CPU_MAX" ] 2>/dev/null && { printf '1'; return 0; }
  fi
  # Blind or healthy → "0" (NOT hot). FAIL-OPEN: refino keeps running.
  printf '0'; return 0
}

# _ar_gate_congested → "1" iff the quality gate has work backed up, else "0".
# Mirrors the Pilot's _pilot_gate_congested (ga-d0hz3): the gate's OWN
# bookkeeping queries (type:quality-gate-marker + gate-status:queued, then
# type:quality-gate-run + gate-status:running) against the HQ store where the gate
# lives. The store is held in a local var (_hq) rather than an inline HQ-store
# literal so the read here is not confused with the refiner heredoc's store-scoped
# writes by the selftest's static drift-guard. FAIL-OPEN "0" on any error. Honors
# AUTO_REFINO_GATE_CONGESTED_OVERRIDE.
_ar_gate_congested() {
  if [ -n "$AUTO_REFINO_GATE_CONGESTED_OVERRIDE" ]; then
    [ "$AUTO_REFINO_GATE_CONGESTED_OVERRIDE" = "1" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _hq="$GC_CITY" _q _r _n
  _q=$(GC_CITY="$_hq" timeout 15 bd -C "$_hq" list --json --all \
        -l type:quality-gate-marker -l gate-status:queued 2>/dev/null || echo "")
  _n=$(printf '%s' "$_q" | jq 'length' 2>/dev/null || echo "")
  if [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null; then printf '1'; return 0; fi
  _r=$(GC_CITY="$_hq" timeout 15 bd -C "$_hq" list --json --all \
        -l type:quality-gate-run -l gate-status:running 2>/dev/null || echo "")
  _n=$(printf '%s' "$_r" | jq 'length' 2>/dev/null || echo "")
  if [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null; then printf '1'; return 0; fi
  printf '0'; return 0
}

# _ar_pilot_has_work → "1" iff the Pilot has approved work waiting to execute,
# else "0". "Dispatchable" = an OPEN story:approved bead with a NULL assignee (the
# Pilot skips any bead with a non-null assignee). Queried across ALL refino stores
# (the same store set the daemon already ingests from) so an approved WA/PS story
# counts too. Cheap read-only label count; first hit wins (short-circuit). FAIL-OPEN
# "0" on any error. Honors AUTO_REFINO_PILOT_WORK_OVERRIDE ("1"/"0") test seam.
_ar_pilot_has_work() {
  if [ -n "$AUTO_REFINO_PILOT_WORK_OVERRIDE" ]; then
    [ "$AUTO_REFINO_PILOT_WORK_OVERRIDE" = "1" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _store _j _n
  for _store in $AUTO_REFINO_STORES; do
    _j=$(timeout 15 bd -C "$_store" list --label story:approved --status open --json 2>/dev/null || echo "")
    # Count open approved beads with NO assignee (the Pilot's dispatchable shape).
    _n=$(printf '%s' "$_j" | jq '[.[] | select((.assignee // "") == "")] | length' 2>/dev/null || echo "")
    if [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null; then printf '1'; return 0; fi
  done
  printf '0'; return 0
}

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

# ── Maintenance passes (Step 0 + 0c) run across ALL stores ────────────────────
# TTL recovery and phantom-assignee reconcile are cheap, bounded, self-healing
# passes. Run them for EVERY store each sweep (not just the one we end up refining
# from) so a stuck/leaked claim in any rig store heals promptly. bd_ targets the
# current $AR_STORE inside this loop.
for AR_STORE in $AUTO_REFINO_STORES; do
log "── maintenance store: $AR_STORE ──"

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

# ── Step 0c: PHANTOM-ASSIGNEE reconcile — self-heal leaked claims ─────────────
# Defensive belt for the phantom-assignee bug: the claim step sets
# assignee=auto-refino so parallel refiners don't collide, but a story that has
# ALREADY advanced past active refining (handed to the gate, approved, in-flight,
# escalated, …) must NOT keep that assignee — the Pilot skips any bead with a
# non-null assignee, so an approved feature stuck with assignee=auto-refino is
# PERMANENTLY undispatchable (a launchd daemon can never "build" it).
#
# Query every open bead assigned to us, then clear the assignee on any that is NO
# LONGER actively refining (i.e. does NOT carry both auto-refino:refining AND
# story:refinement-in-progress). This heals the pre-existing leaks (ga-b9xn1,
# ga-yx2d1, ga-m3n1x, ga-wgcyk) and any future one the terminal-clear missed.
# Bounded by the assignee filter (only our own claims), idempotent, fail-open.
RECONCILE_JSON=$(bd_ list --assignee "$AUTO_REFINO_ACTOR" --status open --json 2>/dev/null || echo "[]")
echo "$RECONCILE_JSON" | jq -c '.[]?' 2>/dev/null | while IFS= read -r row; do
  r_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$r_id" ] && continue
  r_labels=$(echo "$row" | jq -r '(.labels // []) | join(",")')
  # Still actively refining (claim marker + in-progress lifecycle) → leave it.
  case ",$r_labels," in
    *,auto-refino:refining,*)
      case ",$r_labels," in *,story:refinement-in-progress,*) continue ;; esac ;;
  esac
  # Advanced past refining but still wearing assignee=auto-refino → phantom. Clear.
  log "  Phantom-assignee reconcile: $r_id no longer actively refining but assignee=$AUTO_REFINO_ACTOR — clearing."
  if [ "$DRY_RUN" != "1" ]; then
    bd_ update "$r_id" --assignee "" -q 2>/dev/null || true
  fi
done
done  # end maintenance per-store loop (Step 0 + 0c)

# ── FIX B: CROSS-STAGE contention-yield (mirrors the Pilot daemon, ga-d0hz3) ─
# Refino is the LOWEST stage. BEFORE gathering candidates / spawning a refiner,
# DEFER this sweep (mutate NOTHING, exit 0) when a more-advanced stage has work AND
# resources are contended, so the scarce Claude quota + Dolt drain the higher stages
# first. Probed AFTER the cheap self-healing maintenance passes (which are safe to
# run every sweep) and BEFORE any candidate query / claim / spawn.
#
# Order (cheap-path first): only pay for the gate/pilot bead queries when resources
# are ACTUALLY tight — when the quota is OK and Dolt is calm we run refino regardless,
# so the higher-stage probes are skipped on the common (abundant) case. This is the
# same cheap-path the Pilot uses (skip the congestion query when resources abundant).
if [ "$AUTO_REFINO_YIELD" = "1" ]; then
  _yield_quota_limited="$(_ar_quota_limited)"     # "1"/"0" (fail-open "0")
  _yield_dolt_hot="$(_ar_dolt_hot)"               # "1"/"0" (fail-open "0")
  _yield_resource_tight=0
  { [ "$_yield_quota_limited" = "1" ] || [ "$_yield_dolt_hot" = "1" ]; } \
    && _yield_resource_tight=1
  if [ "$_yield_resource_tight" = "1" ]; then
    # Resources are tight — now check whether a HIGHER stage actually has work.
    _yield_gate_congested="$(_ar_gate_congested)"   # "1"/"0" (fail-open "0")
    _yield_pilot_has_work="$(_ar_pilot_has_work)"   # "1"/"0" (fail-open "0")
    if [ "$_yield_gate_congested" = "1" ] || [ "$_yield_pilot_has_work" = "1" ]; then
      warn "Cross-stage YIELD (FIX B / ga-d0hz3): a higher stage has work (gate_congested=${_yield_gate_congested} pilot_has_work=${_yield_pilot_has_work}) and resources are CONTENDED (quota_limited=${_yield_quota_limited} dolt_hot=${_yield_dolt_hot}) — DEFERRING refino this sweep so the more-advanced stage drains first. Triagem stays queued; auto-resumes when Dolt calms / quota frees. Most-advanced-first."
      notify -t "⏸️ Auto-refino cede aos estágios mais avançados" -p 2 "Auto-refino adiou refinar — estágio mais avançado com trabalho (gate=${_yield_gate_congested} pilot=${_yield_pilot_has_work}) + recurso contido (dolt_hot=${_yield_dolt_hot}, quota=${_yield_quota_limited}). Retoma quando o recurso aliviar (FIX B)." 2>/dev/null || true
      log "Auto-refino sweep deferred (cross-stage yield: higher-stage work + resource-contended, FIX B). No mutation."
      exit 0
    fi
    log "Cross-stage check (FIX B): resources contended (quota_limited=${_yield_quota_limited} dolt_hot=${_yield_dolt_hot}) but NO higher-stage work (gate_congested=${_yield_gate_congested} pilot_has_work=${_yield_pilot_has_work}) — refining normally."
  fi
fi

# ── Step 1: Find candidate stories in Triagem (feature/story only) ────────────
# Primary source query: fresh Triagem stories. We query each lifecycle label and
# union, then classify each candidate with the pure core (defense in depth: the
# query narrows, the classifier disqualifies). Type is restricted to feature at
# the query level; `story` issue_type (if the build models it) is caught by the
# type-eligibility classifier below.
#
# bug/chore/task NEVER carry story:* lifecycle labels and so never appear here —
# but we ALSO assert type-eligibility per candidate so a mislabeled bug cannot leak.
#
# MULTI-STORE: gather + select across each store in turn (HQ, then WA, then PS).
# The one-story-per-sweep cap is GLOBAL: the FIRST store that yields an eligible
# candidate wins, we break out with $AR_STORE pinned to that store, and every
# downstream write (claim, refiner task, outcome) targets THAT store via bd_. A
# later sweep advances to the next store. Stores after the winner are simply not
# visited this sweep (no work multiplied by 3).
STORY=""
RAW_INGEST=0   # set to 1 when the selected candidate is a raw no-label story to pre-label
for AR_STORE in $AUTO_REFINO_STORES; do
log "── candidate store: $AR_STORE ──"
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
  RAW_JSON=$(jq -s --argjson min_age_sec "$(( AUTO_REFINO_RAW_MIN_AGE_MINUTES * 60 ))" '
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
    # Drop beads already in the BUILD/GATE pipeline (ga-dt6bu / ga-oonk3 thrash fix).
    # /gate-done + the gate circuit-break can leave a bead carrying a gate:* label but
    # NO story:* label (gate:needs-human after circuit-break strips story:in-flight;
    # gate:reviewing; gate:passed; gate:needs-rebase). The story:* filter above misses
    # those, so they were re-ingested as raw Triagem every sweep → wasted refino cycles
    # (ga-oonk3 re-ingested 3x). Any gate:* label means NOT a raw Triagem story.
    # Mirrors the auto-refino:escalated guard directly above.
    | map(select(((.labels // []) | any(type=="string" and startswith("gate:"))) | not))
    # Drop beads already flagged by an existing refino policy-gap escalation
    # (bug ga-blron, 4th occurrence, wa-ku5j1): refino:policy-gap means this
    # bead already went through refino and is waiting on a human decision —
    # re-ingesting loops the same already-answered/already-executed ask.
    # Mirrors the classifier-side guard in auto_refino_is_ingestable_raw.
    | map(select(((.labels // []) | any(. == "refino:policy-gap")) | not))
    # Drop already-ASSIGNED beads (bug ga-blron, occurrences 1-3): someone
    # already claimed this bead — it is dispatched work, not an orphan idea
    # waiting for triage. Mirrors the classifier-side guard in
    # auto_refino_is_ingestable_raw. NOT sufficient alone (a claimed bead can
    # have its assignee cleared by the lifecycle-coherence-janitor R4 rule
    # without checking liveness) — the classifier has_children check is the
    # robust fallback for that gap; it needs a live `bd children` call this
    # pure jq layer cannot make, so it is NOT mirrored here.
    | map(select(((.assignee // "") | length) == 0))
    # has_refino_metadata (bug ga-mk6ve, 9th confirmed re-ingestion) is ALSO
    # classifier-only, same reason as has_children directly above: it needs a
    # live `bd show <id>` call this pure jq layer cannot make, so a bead
    # already carrying real refino metadata still passes this jq stage and
    # relies on the classifier has_refino_metadata check to be excluded.
    # Drop beads under an active hold from another authority (bug ga-268cr,
    # occurrences 2/3/5/6): blocked:*, needs-human*, pilot:held* (bare or
    # -until:<epoch>), blocked-on:* (hyphenated — distinct prefix from
    # blocked:*, not a typo), and pool:refused:* all signal a deliberate hold
    # this sweep must not override. Mirrors the classifier-side guard in
    # auto_refino_is_ingestable_raw (defense in depth).
    | map(select(((.labels // []) | any(type=="string" and (
        startswith("blocked:") or startswith("needs-human") or
        startswith("pilot:held") or startswith("blocked-on:") or
        startswith("pool:refused:")
      ))) | not))
    # Drop beads mutated too recently (ga-51ry, 3rd occurrence wa-soe8a): a
    # manual/automated recovery transition (e.g. the Mayor clearing
    # gate:needs-human to retry) can clear the LAST protective story:*/gate:*
    # label moments before applying its replacement — this sweep can land inside
    # that gap (observed: 87s) and mistake an already-triaged story for genuinely
    # untriaged raw work. Require updated_at at least min_age_sec old. A
    # missing/unparseable updated_at ($upd == null) fails OPEN (kept) so a
    # malformed timestamp can never silently starve the RAW funnel. Mirrors the
    # classifier-side guard in auto_refino_is_ingestable_raw (defense in depth).
    | map(select(
        (((.updated_at // "") | try fromdateiso8601 catch null)) as $upd
        | ($upd == null) or ((now - $upd) >= $min_age_sec)
      ))
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
  log "  No Triagem stories in this store — next store."
  continue
fi
log "  $CCOUNT candidate story(ies) in Triagem (pre-classification)."

# Classify with the pure core; keep only fresh/bounce candidates of an eligible
# type. Oldest-first (FIFO) so the backlog drains in arrival order.
NOW_EPOCH=$(date +%s)
while IFS= read -r row; do
  [ -z "$row" ] && continue
  c_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$c_id" ] && continue
  c_type=$(echo "$row" | jq -r '.issue_type // .type // "feature"')
  c_labels=$(_labels_csv "$row")
  c_assignee=$(echo "$row" | jq -r '.assignee // empty')
  c_ephemeral=$(echo "$row" | jq -r 'if (.ephemeral // false)==true then "true" else "false" end')
  # Age since last update, in minutes (ga-51ry RAW min-age guard input). Same
  # BSD/GNU date-parsing fallback as the TTL-recovery pass above; unparseable
  # timestamp → epoch 0 → huge age → guard fails open (never age-excludes).
  c_updated=$(echo "$row" | jq -r '.updated_at // empty')
  c_upd_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$c_updated" +%s 2>/dev/null \
    || date -u -d "$c_updated" +%s 2>/dev/null || echo 0)
  c_age_min=$(( (NOW_EPOCH - c_upd_epoch) / 60 ))
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
      if [ "$AUTO_REFINO_INGEST_RAW_TRIAGEM" = "1" ]; then
        # has_children (bug ga-blron, occurrence 3, wa-ku5j1): computed HERE,
        # lazily, only for the specific candidate reaching this branch — never
        # upfront for every RAW_JSON row — so a normal sweep costs at most one
        # extra `bd children` call (the loop breaks on the first eligible
        # candidate). Uses `bd children` (the PARENT relationship), NOT
        # dependent_count, which measured live to disagree with itself between
        # `bd list` and `bd show` and does not track PARENT edges at all (see
        # the param doc on auto_refino_is_ingestable_raw). A failed/empty `bd
        # children` call fails OPEN (c_has_children stays "no") — never a new
        # starvation vector for a genuinely childless raw bead.
        c_has_children="no"
        if bd_ children "$c_id" --json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
          c_has_children="yes"
        fi
        # has_refino_metadata (bug ga-mk6ve, 9th confirmed re-ingestion of
        # ga-m3n1x): computed HERE, lazily, same rationale as c_has_children
        # directly above — one extra `bd show` call at most per sweep, only
        # for the specific candidate reaching this branch. A bead already
        # carrying real refino output (story.refino_mode / .criterios /
        # .refino_gate_rounds metadata) is NOT raw regardless of current
        # label state — labels are mutable and get zeroed by daemon
        # side-effects AND human painel actions (9 confirmed occurrences);
        # this metadata is the first POSITIVE, not-label-based signal. A
        # failed/empty `bd show` call fails OPEN (c_has_refino_metadata stays
        # "no") — never a new starvation vector for a genuinely-raw bead with
        # no refino metadata yet.
        c_has_refino_metadata="no"
        if bd_ show "$c_id" --json 2>/dev/null | jq -e '
              (if type=="array" then .[0] else . end) as $b
              | ($b.metadata // {}) as $m
              | (($m["story.refino_mode"] // "") | tostring | length > 0) or
                (($m["story.refino_gate_rounds"] // "") | tostring | length > 0) or
                (($m["story.criterios"] // "") | tostring | length > 0)
            ' >/dev/null 2>&1; then
          c_has_refino_metadata="yes"
        fi
        if [ "$(auto_refino_is_ingestable_raw "$c_id" "$c_type" "$c_labels" "$c_ephemeral" "$AUTO_REFINO_EXCLUDE_LABELS" "$c_age_min" "$AUTO_REFINO_RAW_MIN_AGE_MINUTES" "$c_assignee" "$c_has_children" "$c_has_refino_metadata")" = "yes" ]; then
          STORY="$row"; RAW_INGEST=1
          log "  ingest $c_id: raw Triagem story (no story:* label) → applying story:unrefined entry label"
          break
        fi
      fi
      : ;;  # skip
  esac
done < <(echo "$CANDIDATES" | jq -c 'sort_by(.created_at // .id) | reverse | .[]')  # newest-first tiebreak (Athos prioridade 2026-06-24)

# This store yielded an eligible candidate → stop here. $AR_STORE stays pinned to
# this store so every downstream write targets the bead's own store.
[ -n "$STORY" ] && { log "  Candidate selected from store $AR_STORE."; break; }
log "  No eligible candidate in this store after classification — next store."
done  # end candidate per-store loop (Step 1)

if [ -z "$STORY" ]; then
  log "No eligible candidate after classification across all stores. Sweep done."
  exit 0
fi

# Pin the selected bead's store for ALL downstream writes (claim, refiner task
# heredoc, outcome handling). bd_ already targets $AR_STORE; the refiner heredoc
# below uses $AR_BEAD_STORE explicitly so the spawned Sonnet writes to the right
# store rather than HQ.
AR_BEAD_STORE="$AR_STORE"

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

  ESCALATE as INFO-GAP (technical gap — NOT a product decision; no human page) if:
    - the story has NO description or only placeholder text (thin spec);
    - the story appears to be a DUPLICATE of an existing story;
    - the story is TRIVIAL or MIS-PASTED (no meaningful product intent visible).
    → Use the INFO-GAP escalation path below. Do NOT page Athos.

  ESCALATE as POLICY-GAP (genuine product decision — needs Athos) if ANY of:
    - the "what" or "why" (F2) exists but needs a product decision to resolve;
    - scope ambiguity that only Athos can decide (not just a wording choice);
    - you cannot produce >=2 verifiable criteria WITHOUT guessing product scope;
    - F8 says "epic" (needs an Athos-driven split decision).
    → Use the POLICY-GAP escalation path below. Page Athos.

IF YOU CAN REFINE — write back to the STORY and hand to the gate (NOT
needs-approval), then close the task bead:

bd -C "$AR_BEAD_STORE" update "$STORY_ID" \\
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
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:refinement-in-progress"
bd -C "$AR_BEAD_STORE" label add "$STORY_ID" "story:refino-review"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "auto-refino:refining"
bd -C "$AR_BEAD_STORE" comment "$STORY_ID" "Auto-refino: refinado autonomamente (simplificado, attempt $THIS_ATTEMPT). Enviado ao gate de refino (ga-gpr2v) para revisão de qualidade."
# Signal the dispatcher:
bd -C "$AR_BEAD_STORE" label add "$TASK_BEAD_ID" "outcome:REFINED"
bd -C "$AR_BEAD_STORE" label remove "$TASK_BEAD_ID" "outcome:pending"
bd -C "$AR_BEAD_STORE" close "$TASK_BEAD_ID"

IF YOU CANNOT REFINE CONFIDENTLY — choose the escalation path (imp16):

[PATH A — INFO-GAP: thin/duplicate/trivial — technical gap, NOT a product decision]
Use this when the story lacks enough information to refine (no description, duplicate,
trivial, or mis-pasted). Do NOT page Athos — this is a technical context gap.

bd -C "$AR_BEAD_STORE" update "$STORY_ID" \\
  --set-metadata "story.auto_refino_gaps=<what context is missing — one item per line>"
bd -C "$AR_BEAD_STORE" label add "$STORY_ID" "refino:info-gap"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "auto-refino:refining"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:refinement-in-progress"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:triage"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:unrefined"
bd -C "$AR_BEAD_STORE" comment "$STORY_ID" "Auto-refino INFO-GAP: história sem contexto suficiente (attempt $THIS_ATTEMPT). Lacuna técnica — não é decisão de produto. Aguardando mais contexto."
bd -C "$AR_BEAD_STORE" label add "$TASK_BEAD_ID" "outcome:ESCALATE:info-gap"
bd -C "$AR_BEAD_STORE" label remove "$TASK_BEAD_ID" "outcome:pending"
bd -C "$AR_BEAD_STORE" close "$TASK_BEAD_ID"

[PATH B — POLICY-GAP: genuine product decision — needs Athos]
Use this when the story has intent but resolving it requires a product decision
that only Athos can make. Page Athos via story:refino-escalado.

bd -C "$AR_BEAD_STORE" update "$STORY_ID" \\
  --set-metadata "story.auto_refino_gaps=<perguntas/lacunas concretas, uma por linha — o que falta para refinar>"
bd -C "$AR_BEAD_STORE" label add "$STORY_ID" "refino:policy-gap"
bd -C "$AR_BEAD_STORE" label add "$STORY_ID" "gate:needs-human:product"
bd -C "$AR_BEAD_STORE" label add "$STORY_ID" "auto-refino:escalated"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "auto-refino:refining"
# TERMINAL escalate: remove EVERY lifecycle label so no candidate query can re-pick
# this story (the dispatcher reconciles this too, but be terminal here as well).
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:refinement-in-progress"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:triage"
bd -C "$AR_BEAD_STORE" label remove "$STORY_ID" "story:unrefined"
# SURFACE in the painel "Sua vez" human queue (ga-lfua3): story:refino-escalado
bd -C "$AR_BEAD_STORE" label add "$STORY_ID" "story:refino-escalado"
bd -C "$AR_BEAD_STORE" comment "$STORY_ID" "Auto-refino POLICY-GAP: não conseguiu refinar — precisa de decisão de produto do Athos (attempt $THIS_ATTEMPT). Perguntas/lacunas:
<liste as perguntas — decisões de produto que só o Athos toma>
NÃO promovido, NÃO despachado."
bd -C "$AR_BEAD_STORE" label add "$TASK_BEAD_ID" "outcome:ESCALATE"
bd -C "$AR_BEAD_STORE" label remove "$TASK_BEAD_ID" "outcome:pending"
bd -C "$AR_BEAD_STORE" close "$TASK_BEAD_ID"

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
else
  # ga-bvbm forensic: session_name is REQUIRED by `gc session new --json`'s own
  # schema on success, so an empty read here means either a live contract
  # violation or a malformed capture — either way the task bead's assignee (and
  # so its durable pull-channel fallback) silently never gets set. Log the raw
  # response verbatim so the next occurrence has real evidence instead of
  # another "assignee=None, no clue why" report.
  warn "  session_name missing from 'gc session new --json' for $SESSION_ID (ga-bvbm) — raw response: $SESSION_JSON"
fi
gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REFINE_TASK" --delivery queue 2>/dev/null \
  || gc --city "$GC_CITY" session submit "$SESSION_ID" "$REFINE_TASK" 2>/dev/null \
  || warn "  Initial queue/submit to refiner failed — durable pull channel still active."
log "  Simplificado task delivered to refiner for $STORY_ID."

# ── Step 6: Poll the task bead until REFINED/ESCALATE or timeout ──────────────
DEADLINE=$(( $(date +%s) + AUTO_REFINO_TIMEOUT_MINUTES * 60 ))
_LAST_DRAINED_CHECK=$(date +%s)
OUTCOME="TIMEOUT"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  TB=$(bd_ show "$TASK_BEAD_ID" --json 2>/dev/null || echo "[]")
  TB_LABELS=$(echo "$TB" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")')
  if echo "$TB_LABELS" | grep -q "outcome:REFINED"; then
    OUTCOME="REFINED"; break
  elif echo "$TB_LABELS" | grep -q "outcome:ESCALATE:info-gap"; then
    OUTCOME="ESCALATE:info-gap"; break
  elif echo "$TB_LABELS" | grep -q "outcome:ESCALATE"; then
    OUTCOME="ESCALATE"; break
  fi
  # ga-bvbm: past the boot grace period, periodically check whether the refiner
  # itself has already drained (stale_async_start race) — if so it will NEVER
  # produce a terminal label, so waiting out the rest of the (25m default)
  # timeout is pure waste. Detect it and requeue instead. Falls through
  # auto_refino_handoff_decision's existing `*) requeue` catch-all — no
  # decision-vocabulary change needed. Reuses the grace tunable as the RECHECK
  # interval too (one knob): at most one extra `gc session list` call per grace
  # window, not one per (30s default) bead-poll tick — Dolt has a documented
  # history of poll-frequency-driven CPU/latency issues, so this stays a
  # low-frequency check layered on the existing bead poll, not a second loop
  # running at the same cadence.
  _now=$(date +%s)
  if [ $(( _now - _LAST_DRAINED_CHECK )) -ge "$AUTO_REFINO_DRAINED_GRACE_SECONDS" ]; then
    _LAST_DRAINED_CHECK=$_now
    _SESSIONS_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo '{}')
    if [ "$(auto_refino_session_drained "$_SESSIONS_JSON" "$SESSION_ID")" = "yes" ]; then
      OUTCOME="SPAWN_DRAINED"
      warn "  Refiner session $SESSION_ID drained before delivering an outcome for $STORY_ID (stale_async_start race, ga-bvbm) — requeuing now instead of waiting out the full timeout."
      break
    fi
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

    # ── DELIVERED-DUPLICATE CHECK (wa-ca4jm) ────────────────────────────────
    # Before completing the handoff, verify no DELIVERED twin exists in this
    # store. FAIL-OPEN: any error → _dup_twin="" → proceed normally.
    _dup_twin=""
    if [ "${AUTO_REFINO_DUP_CHECK:-1}" = "1" ]; then
      _dt="${AUTO_REFINO_DUP_THRESHOLD:-0.5}"
      _dup_raw=$(bd_ find-duplicates --method mechanical --threshold "$_dt" --json 2>/dev/null || echo "")
      if [ -n "$_dup_raw" ]; then
        # Extract all twins of STORY_ID from the pairs list.
        _twin_ids=$(printf '%s' "$_dup_raw" | jq -r --arg id "$STORY_ID" \
          '(.pairs // [])[] | select(.issue_a_id==$id or .issue_b_id==$id) |
           if .issue_a_id==$id then .issue_b_id else .issue_a_id end' 2>/dev/null || echo "")
        for _twin in $_twin_ids; do
          [ -z "$_twin" ] && continue
          _twin_json=$(bd_ show "$_twin" --json 2>/dev/null || echo "")
          [ -z "$_twin_json" ] && continue
          # A twin is "delivered" if status=closed OR it carries gate:passed or story:done.
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
    fi

    if [ -n "$_dup_twin" ]; then
      # DELIVERED duplicate found — block the handoff.
      log "  $STORY_ID → DUP-BLOCKED: delivered twin $_dup_twin found — reverting to refino:info-gap + escalating to Athos."
      bd_ label remove "$STORY_ID" "story:refino-review" -q 2>/dev/null || true
      bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
      bd_ label add "$STORY_ID" "refino:info-gap" -q 2>/dev/null || true
      bd_ label add "$STORY_ID" "auto-refino:escalado" -q 2>/dev/null || true
      bd_ update "$STORY_ID" --set-metadata "story.auto_refino_attempts=$THIS_ATTEMPT" -q 2>/dev/null || true
      bd_ update "$STORY_ID" --assignee "" -q 2>/dev/null || true
      bd_ comment "$STORY_ID" "Auto-refino: história BLOQUEADA — twin entregue detectado: $_dup_twin. Se for distinta, remova refino:info-gap + auto-refino:escalado e re-submeta." 2>/dev/null || true
      bd_ dolt commit -m "auto-refino: dup-block $STORY_ID (twin=$_dup_twin)" 2>/dev/null || true
      notify -t "Auto-refino: dup bloqueado $STORY_ID" -p 3 "Não promovi $STORY_ID ao gate — twin entregue: $_dup_twin. Verifique se são histórias distintas." 2>/dev/null || true
      gc --city "$GC_CITY" mail send mayor -s "Auto-refino: dup-block em $STORY_ID" \
        -m "$STORY_ID (refinada, pronta pro gate) bloqueada: twin entregue encontrado ($_dup_twin). Labels: refino:info-gap + auto-refino:escalado. Se forem histórias distintas, remova esses labels e o gate retomará." 2>/dev/null || true
    else
      # No delivered twin — complete the normal handoff.
      bd_ update "$STORY_ID" --set-metadata "story.auto_refino_attempts=$THIS_ATTEMPT" -q 2>/dev/null || true
      # Normalize issue_type story→feature: gate + Pilot only ever query --type
      # feature, so a story-typed bead would stay invisible forever after this
      # handoff (ga-oe7e). Done here, not inside the refiner's heredoc, so it's
      # guaranteed regardless of what the spawned session executes.
      bd_ update "$STORY_ID" --type feature -q 2>/dev/null || true
      # Defensive: ensure the claim marker is gone even if the refiner forgot.
      bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
      # PHANTOM-ASSIGNEE FIX: the claim step set assignee=auto-refino so parallel
      # refiners would not collide. The daemon is a launchd job, NOT a live crew —
      # it can never "build". Once the story leaves our hands (handed to the gate),
      # it must carry a NULL assignee, or the Pilot (which skips any bead with a
      # non-null assignee) treats it as already-owned and NEVER dispatches the
      # approved feature. Clear it at the terminal handoff. Idempotent / fail-open.
      bd_ update "$STORY_ID" --assignee "" -q 2>/dev/null || true
      log "  $STORY_ID → handed to refino gate (story:refino-review). Gate decides promotion."
    fi
    ;;
  escalate-info-gap)
    # imp16: info-gap escalation — story is thin/duplicate/trivial (technical gap,
    # NOT a product decision). Do NOT page Athos. The refiner already set refino:info-gap;
    # ensure cleanup + skip markers. Story waits for context without a human page.
    bd_ update "$STORY_ID" --set-metadata "story.auto_refino_attempts=$THIS_ATTEMPT" -q 2>/dev/null || true
    bd_ label remove "$STORY_ID" "auto-refino:refining" -q 2>/dev/null || true
    bd_ label add "$STORY_ID" "auto-refino:escalated" -q 2>/dev/null || true
    bd_ label add "$STORY_ID" "refino:info-gap" -q 2>/dev/null || true
    _clear_lifecycle "$STORY_ID"
    bd_ update "$STORY_ID" --assignee "" -q 2>/dev/null || true
    # NOT story:refino-escalado (not in Athos's queue), NOT notify, NOT mail mayor
    log "  $STORY_ID → INFO-GAP (thin/duplicate/trivial) — refino:info-gap set, no human page."
    ;;
  escalate)
    # Either the refiner said ESCALATE (policy-gap), or the attempt budget is spent.
    # Make sure the bead is flagged + NOT promoted + NOT dispatched, record the attempt,
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
    # PHANTOM-ASSIGNEE FIX: clear the claim assignee on escalate too. The story
    # now waits on Athos (story:refino-escalado); leaving assignee=auto-refino
    # would make it undispatchable forever should Athos approve it later, since
    # the Pilot skips any non-null-assignee bead. Idempotent / fail-open.
    bd_ update "$STORY_ID" --assignee "" -q 2>/dev/null || true
    # BUG ga-lfua3: SURFACE the escalation in the painel's "Sua vez" human queue.
    # _SUAVEZ_LABELS (painel_visibilidade.py:135) = {story:needs-approval,
    # story:refino-escalado}. The daemon's own bookkeeping label
    # (auto-refino:escalated) is NOT one of them, so an escalated story carrying
    # only auto-refino:escalated rendered in TRIAGEM (looks un-triaged) and was
    # invisible to Athos. Add the painel's CANONICAL escalation label so it shows
    # in "Sua vez". This is ADDED AFTER _clear_lifecycle — and story:refino-escalado
    # is deliberately NOT in AUTO_REFINO_LIFECYCLE_LABELS, so _clear_lifecycle never
    # strips it and the candidate classifier (auto_refino_lifecycle_state) treats it
    # as skip (not fresh/bounce), so it is NOT re-picked. Keep auto-refino:escalated
    # (the daemon's durable skip/attempt-tracking marker) alongside it.
    bd_ label add "$STORY_ID" "story:refino-escalado" -q 2>/dev/null || true
    # ga-xdukc/ga-hd87d: a POLICY-GAP escalation is a human-decision gate, same
    # class as story:needs-approval — but until now nothing in this DETERMINISTIC
    # bash path stamped a label Pilot's _filter_candidates actually excludes on.
    # The spawned refiner's own PATH B heredoc instructs it to add
    # gate:needs-human:product (also excluded, via startswith), but that's an LLM
    # agentic tool call — best-effort, not guaranteed to run every time. wa-5ch02
    # (a real Athos-money DECISÃO bead) proved the gap: it carried refino:policy-gap
    # + story:refino-escalado but reached Pilot with NEITHER story:needs-human NOR
    # gate:needs-human:product, and was dispatched with "No human review required"
    # — only a worker's manual refusal caught it. Stamp story:needs-human HERE,
    # in code that runs unconditionally on every escalate (policy-gap AND
    # budget-exhaustion — both already mean "stop auto-dispatching, wait for
    # Athos" per the surrounding comments), so the guarantee no longer depends on
    # the refiner sub-agent's prompt-following. Pilot's own candidate filter
    # (_filter_candidates) already excludes this exact label — no Pilot-side
    # change is needed to close this gap, only this stamp.
    # Not in AUTO_REFINO_LIFECYCLE_LABELS (same reasoning as story:refino-escalado
    # above), so _clear_lifecycle never strips it.
    bd_ label add "$STORY_ID" "story:needs-human" -q 2>/dev/null || true
    # bug ga-8bjhl: a POLICY-GAP resolved by SPLITTING the story into
    # sub-stories only leaves a durable trace if whoever executes the split
    # applies the EXISTING Epic Split Convention (skills/refino/references/
    # story-bead-convention.md: --type epic --set-labels story:epic-split on
    # the umbrella, --parent on each child). Reproduced live (wa-pxvox): a
    # split recorded only via free-text comment + sibling `blocks` deps
    # between the children (no --parent to the umbrella) is invisible to
    # BOTH defenses auto_refino_is_ingestable_raw has (no story:* label AND
    # `bd children` returns empty) — the umbrella looks untouched and gets
    # re-ingested as fresh raw work. Same fragility class as the
    # story:needs-human stamp above (ga-xdukc/ga-hd87d): relying on the
    # refiner's own LLM-composed comment to remember this is best-effort,
    # not guaranteed. Stamp the reminder HERE instead, in code that runs
    # unconditionally on every escalate, independent of the refiner's
    # prompt-following AND of whoever ends up resolving the gap (Mayor or
    # Athos) already knowing the convention exists.
    bd_ comment "$STORY_ID" "Lembrete (bug ga-8bjhl): se a resolução desta escalação envolver DIVIDIR esta história em sub-histórias, aplique o Epic Split Convention NA PRÓPRIA história — não só em comentário — skills/refino/references/story-bead-convention.md: a história-mãe fica com type=epic e o label de lifecycle TROCADO para story:epic-split, e cada filha nasce com --parent apontando pra ela, ex.:
  bd -C \"$AR_BEAD_STORE\" create \"<sub-história>\" --type feature --parent $STORY_ID --label story:unrefined --no-inherit-labels
Sem o --parent + o label story:epic-split na história-mãe, o guard de RAW-ingestion não enxerga o split (bd children continua vazio, sem label story:*) e esta história volta a ser ingerida como ideia crua." 2>/dev/null || true
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

    # ga-1wc5: Step 6 only watches the TASK bead's own outcome:* labels, never
    # the STORY's — so a refiner that finishes the handoff (or a gate that then
    # advances the story) but is slow to close its own wisp bead produces a
    # TIMEOUT here even though the story already moved past the daemon. $STATE
    # was captured once at cycle-start (Step 1, well before this poll) and can be
    # stale by now. Re-read the story's CURRENT labels/assignee and run them back
    # through the SAME classifier the GUARANTEE above relies on — if it now says
    # "skip" (refino-review/needs-approval/approved/in-flight/done/cancelled/
    # escalated, a gate actively reviewing, or reassigned away from us while we
    # waited), leave the lifecycle exactly as-is instead of resetting it; only
    # the claim marker (already dropped above) was ever ours to release. A
    # bd_ show read failure degrades to the SAME branch (empty labels are
    # classified "skip" by the classifier's own catch-all) — deliberately
    # fail-safe, never destructive on uncertainty, and harmless: Step 2's claim
    # already left the story refinement-in-progress+us (bounce-shaped), so a
    # skipped reset still leaves it re-pickable next sweep either way.
    _RQ=$(bd_ show "$STORY_ID" --json 2>/dev/null || echo "[]")
    _RQV() { echo "$_RQ" | jq -r "if type==\"array\" then .[0] else . end | $1"; }
    _rq_labels=$(_RQV '(.labels // []) | join(",")')
    _rq_assignee=$(_RQV '.assignee // empty')
    if [ "$(auto_refino_lifecycle_state "$_rq_labels" "$_rq_assignee" "$AUTO_REFINO_ACTOR")" = "skip" ]; then
      bd_ comment "$STORY_ID" "Auto-refino: o wisp do refiner só encerrou após o timeout (${AUTO_REFINO_TIMEOUT_MINUTES}m), mas a história já avançou pra um estado pós-daemon ($_rq_labels) enquanto o dispatcher esperava — lifecycle preservado, claim liberado." 2>/dev/null || true
      log "  $STORY_ID → timeout, but already past-daemon ($_rq_labels) — lifecycle NOT reset (ga-1wc5)."
    else
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
    fi
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
