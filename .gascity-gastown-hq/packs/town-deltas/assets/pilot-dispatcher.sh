#!/usr/bin/env bash
# pilot-dispatcher.sh — Autonomous Pilot Dispatcher ("Pilot" / "P").
#
# Runs every ~300s via launchd (com.gascity.pilot.plist).
# PRIORITY DIRECTIVE (wa-tm2a): PRIORITY DOMINATES; type is only a tiebreak.
#   The dispatcher pulls from ONE merged candidate pool — open BUG beads
#   (type:bug) + tech-debt-labeled beads + story:approved feature stories — none
#   already in-flight/done/assigned. The pool is ordered strictly by:
#       priority (0-4 asc; missing = 99 = last)
#         > type rank (bug → tech-debt → task → chore → feature/story)
#           > created_at (oldest first)
#             > id (final deterministic tiebreak).
#   So a P0 story is dispatched BEFORE a P3 bug (reversal of the old hard
#   bugs-before-stories tiering), and within the same priority a bug still beats
#   a story. epic beads NEVER dispatch (excluded by the epic-type filter). Each
#   bead is dispatched with the prompt/sling template matching ITS OWN type
#   (bug/tech-debt → "fix bug …"; feature/story → "build story …").
# Picks highest-ranked candidate (per the key above), atomically claims it,
# dispatches a builder session via gc sling, then transitions the bead to
# story:in-flight.
#
# TWO-LANE DISPATCH (anti-deadlock):
#   SMALL/fast lane (MAX_SMALL, default 5): small items — merge fast, high concurrency.
#   BIG/slow  lane (MAX_BIG,   default 2): big items  — dedicated lane so they can't
#     hog the small lane and starve fast work.
#   Each lane has its OWN cap. A full big lane does NOT block small dispatches.
#   Lane classification (at dispatch time, in priority order):
#     1. Explicit label: lane:big or lane:small on the bead.
#     2. story.size_check metadata == "epic" → big.
#     3. Acceptance-criteria count >= 5 → big.
#     4. Default → small.
#   Tagged on dispatch (lane:big / lane:small) so in-flight counting works.
#   ESCALATION: a worker may relabel lane:small → lane:big mid-flight to correct
#   accounting; Pilot re-counts each sweep from actual bead labels.
#
# Priority-first ordering (wa-tm2a) is preserved WITHIN each lane.
#
# This is the FRONT HALF of the autonomous delivery loop:
#
#   Pilot (this) → spawns builder → builder implements → /gate-done
#     → G (quality-gate) reviews + merges → ① (story-delivery) deploys + tests
#
# DESIGN INVARIANTS:
#   - Claim is ATOMIC: add pilot:dispatching label + verify before acting.
#     TTL recovery releases stale pilot:dispatching claims after CLAIM_TTL_MINUTES.
#   - Capacity cap: per-lane caps (MAX_SMALL, MAX_BIG). Pilot fills whichever lane
#     has a free slot, up to one dispatch per lane per sweep (or all available slots).
#   - Idempotent: skip beads with story:in-flight, story:done, or already
#     assigned (assignee set). Never dispatch the same bead twice.
#   - Dependency-aware (ga-5ew): skip beads BLOCKED by unresolved (open)
#     dependencies. A story is only dispatchable once every bead it hard-depends
#     on is closed/merged. Uses bd's blocker-aware `bd blocked` set, per-DB,
#     fail-open. See _filter_unblocked.
#   - Explicit-dep-aware (ga-do8jj): ALSO skip beads that declare a still-open
#     dependency via the `story.depends_on_beads` metadata field (space/comma-
#     separated bead IDs). This catches "de-facto" deps documented in prose but
#     never encoded as a formal `bd` edge — the gap that let ga-2e605 dispatch
#     before its base ga-e72kf landed. Auto-clearing, fail-open. See
#     _filter_explicit_deps.
#   - Self-exclusion: never dispatch bead ga-8c1 (the Pilot itself) — it cannot
#     build itself. Excluded by label policy (pilot:self) not hardcode.
#   - Cross-rig aware: reads HQ DB (authoritative for all story beads per
#     convention). Falls back to scanning rig DBs if HQ returns none.
#   - Builder routing: maps story.rig metadata → gc sling target using the
#     RIG_TO_BUILDER table below. Falls back to gastown.dog for unknown rigs.
#   - DRAIN-SAFE: this file + its plist are the ONLY artifacts. Does not touch
#     city.toml, pack.toml, or any crew skill files.
#   - DRY_RUN=1 → shows full pick + would-dispatch, makes zero state changes.
#
# Usage:
#   bash pilot-dispatcher.sh            # normal run
#   DRY_RUN=1 bash pilot-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

# City root. Defaults to the live HQ. PILOT_CITY_OVERRIDE is a TEST-ONLY seam
# (used by pilot-dispatcher.selftest.sh to redirect bd -C / logs / jsonl into a
# throwaway fixture); it is never set in production, where this resolves to the
# hardcoded default. Mirrors the SKILL_AUDIT_* override convention.
GC_CITY="${PILOT_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/pilot-dispatcher.log"
PILOT_LOG="$GC_CITY/.gc/pilot-dispatcher.jsonl"

# ── Two-lane caps ─────────────────────────────────────────────────────────────
# SMALL/fast lane: high concurrency, small items that merge quickly.
MAX_SMALL="${MAX_SMALL:-5}"
# BIG/slow lane: dedicated, prevents big items from blocking small ones.
MAX_BIG="${MAX_BIG:-2}"

# Gate reviewer pool size — observability only (ga-8c1 AC5). The Pilot dispatches
# builders, NOT reviewers; this is read-only so each sweep's log can show the
# whole pipeline's free capacity (builders + gate reviewers) at a glance. Matches
# the gate-reviewer template's max_active_sessions=6.
MAX_REVIEWERS="${MAX_REVIEWERS:-6}"

# Acceptance-criteria count threshold for auto-classifying a story as BIG.
BIG_CRITERIA_THRESHOLD="${BIG_CRITERIA_THRESHOLD:-5}"

# TTL for stuck pilot:dispatching claims (minutes). After this, Pilot recycles them.
CLAIM_TTL_MINUTES="${CLAIM_TTL_MINUTES:-30}"

# ── Dispatch-to-capacity (ga-rk5va) ───────────────────────────────────────────
# When 1 (default), each lane dispatches to fill EVERY free slot in a single sweep
# (looping pick→claim→sling until the lane is full or candidates are exhausted),
# instead of the legacy one-dispatch-per-lane-per-sweep. This is the user's "máxima
# lotação" goal: after a drain, 5 free small slots refill in ONE sweep, not ~5.
# Set 0 to force the legacy single-pick-per-lane behavior.
DISPATCH_TO_CAPACITY="${DISPATCH_TO_CAPACITY:-1}"

# ── Dolt-saturation backoff (ga-rk5va adversarial constraint a) ────────────────
# Dispatch-to-capacity multiplies bd/dolt shellouts per sweep (N× the load that
# drove the fd-leak/CPU incidents). It MUST self-throttle when Dolt is already
# hot, or it widens a wedged pipe. Before filling slots we probe Dolt health once;
# if SATURATED we cap each lane to a single dispatch this sweep (== legacy safe
# behavior, never worse than before). Between dispatches we re-check cheaply and
# bail the moment Dolt crosses the ceiling. Saturation = server response latency
# OR the live dolt-server process CPU% exceeds these ceilings. CPU baseline is
# ~86-90% under normal load (per the gate-falsefail incident); 200 (= ~2 pegged
# cores) is the documented danger zone, latency baseline is sub-second.
PILOT_DOLT_LATENCY_MAX_MS="${PILOT_DOLT_LATENCY_MAX_MS:-2500}"
PILOT_DOLT_CPU_MAX="${PILOT_DOLT_CPU_MAX:-200}"
# TEST-ONLY seams (mirror PILOT_CITY_OVERRIDE): when set, the health probe uses
# these instead of shelling out to `gc dolt health` / `ps`. Never set in prod.
PILOT_DOLT_LATENCY_OVERRIDE_MS="${PILOT_DOLT_LATENCY_OVERRIDE_MS:-}"
PILOT_DOLT_CPU_OVERRIDE="${PILOT_DOLT_CPU_OVERRIDE:-}"

# ── Claude 5h-quota back-off (ga-x3nmz) ───────────────────────────────────────
# A builder dispatched while the Claude 5h window is exhausted dies mid-build
# ("you've hit your session limit") → a wasted lane slot + a phantom in-flight
# bead the dispatcher must later reap. Before filling slots we probe the
# GROUND-TRUTH quota (ga-wjlv9 checker); if LIMITED we PAUSE all dispatch this
# sweep — the candidate stories stay queued and are re-picked automatically once
# the window resets (no marker mutated, nothing lost). FAIL-OPEN: an absent or
# erroring checker never blocks dispatch (the dependency is optional).
# PILOT_QUOTA_OVERRIDE is a TEST-ONLY seam (mirrors PILOT_DOLT_CPU_OVERRIDE):
# "2" = limited, anything else = ok. Never set in prod.
PILOT_QUOTA_OVERRIDE="${PILOT_QUOTA_OVERRIDE:-}"
PILOT_QUOTA_ETA_OVERRIDE="${PILOT_QUOTA_ETA_OVERRIDE:-}"

# ── Cross-stage priority — most-advanced-first / WIP-limit (ga-d0hz3) ──────────
# The 4 stage dispatchers (auto-refino / refino-gate / quality-gate / pilot) are
# INDEPENDENT launchd timers with no cross-stage coordination, so the system pulls
# NEW work into the front (Pilot dispatches new builds) while the back congests
# (Gate reviews pile up). The stages don't share a worker pool, but they DO share
# Dolt + the Claude quota + the human's attention. Athos's order is
# most-advanced-first: review in the Gate (1) > pull ready→Gate (2) > approved→
# execution / Pilot (3, LOWEST). So the Pilot — the lowest stage — must YIELD to a
# congested higher stage ONLY UNDER GENUINE RESOURCE CONTENTION, and otherwise run
# freely (parallel is fine; the pools are different — pointless serialization is a
# bug, not a feature).
#
# Concretely, BEFORE the Pilot dispatches a NEW build it DEFERS this sweep (exit
# cleanly, dispatch nothing, mutate no marker — mirrors the quota PAUSE pattern)
# IFF:
#     (gate is CONGESTED: gate-status:queued markers > 0 OR gate-runs in review > 0)
#   AND
#     (resources are CONTENDED: Claude quota limited OR Dolt hot)
# Resources ABUNDANT (quota OK AND Dolt calm) → never defer (dispatch even with a
# busy gate). Gate empty → never defer. This conditionality is the anti-starvation
# guarantee: the moment Dolt calms or the quota frees, the Pilot dispatches again,
# so it can never be starved indefinitely.
#
# Gated behind CROSS_STAGE_PRIORITY_ENABLED (default 1; =0 → EXACT current
# behavior, the gate never even probes). FAIL-OPEN: any error / indeterminate
# congestion read → PROCEED (dispatch) — this check must never wedge the Pilot.
#
# PILOT_GATE_CONGESTED_OVERRIDE is a TEST-ONLY seam (mirrors PILOT_QUOTA_OVERRIDE /
# PILOT_DOLT_CPU_OVERRIDE): "1" = gate congested, "0" = gate empty, "" = probe the
# real bead store. Never set in prod.
CROSS_STAGE_PRIORITY_ENABLED="${CROSS_STAGE_PRIORITY_ENABLED:-1}"
PILOT_GATE_CONGESTED_OVERRIDE="${PILOT_GATE_CONGESTED_OVERRIDE:-}"

# ── Stale in-flight slot correction (ga-rk5va adversarial constraint c) ────────
# A story:in-flight bead normally occupies a builder slot. But a session can hang
# (the 16h-stuck-session bug) — zero state-transitions for hours while the bead
# still reads in-flight. Such a bead is a PHANTOM occupant: it pins a slot that no
# one is working, so capacity math is wrong (slots sit empty). We treat a bead
# whose last transition (updated_at) is older than this many hours as NOT a live
# occupant — it stops consuming a slot, freeing it for OTHER pending work. The
# stale bead itself is NOT re-dispatched (it keeps story:in-flight and stays
# excluded from candidate queries), so this can never double-dispatch the same
# story; it only stops an abandoned build from starving the lane forever.
PILOT_STUCK_INFLIGHT_HOURS="${PILOT_STUCK_INFLIGHT_HOURS:-2}"

# ── Dead-worker in-flight correction (ga-e5yw2) ───────────────────────────────
# The age cutoff above only frees a slot after PILOT_STUCK_INFLIGHT_HOURS of
# TOTAL silence on the source row. It misses the dominant phantom: a bead whose
# source row was touched recently (label/dispatch churn) but whose BUILDER
# SESSION has already died — crashed, reaped, or killed — without clearing
# story:in-flight. Those read "live" by age yet hold a slot no worker occupies:
# the raw=7-vs-real-4 over-count that makes the Pilot see a full lane and throttle
# dispatch while real capacity sits idle (bug ga-e5yw2). When set to 1 (default)
# the dispatcher resolves each in-flight bead's sling-task assignee and counts the
# bead as a live occupant ONLY if that assignee is a live session in
# `gc session list`; a bead whose worker session is provably gone stops consuming
# a slot. Fail-safe in every unresolved leg (no sling, no assignee, roster
# unreadable/empty) → KEEP, so the worst case is the harmless pre-fix over-count,
# never an over-dispatch. Set to 0 to disable the cross-check entirely.
PILOT_DEADWORKER_CHECK="${PILOT_DEADWORKER_CHECK:-1}"

# ── Never-started in-flight recovery (ga-v3z4z) ───────────────────────────────
# The slot corrections above (age-stale ga-rk5va, dead-worker ga-e5yw2) only stop
# a phantom from COUNTING against the lane cap — they never RE-DISPATCH it. That
# leaves a distinct failure class permanently stuck: a bead marked story:in-flight
# + pilot:dispatched whose builder session never materialized (deferred at the
# session layer, spawn raced, or the worker died before pushing ANYTHING). It has
# NO branch in any rig, NO live worker, and NO gate marker — "dispatched on paper,
# nobody picked it up". The Kanban shows it "em voo sem worker" forever, and no
# sweep ever frees it because pilot:dispatched bars re-pick.
#
# This detector RELEASES such never-started beads (strips story:in-flight +
# pilot:dispatched + claim stamps) so the very next sweep re-dispatches them. It
# is the active counterpart to the passive slot corrections, and it is mechanism-
# agnostic: it does not care HOW the bead reached limbo, only that none of the
# "real work happened" signals are present. FAIL-SAFE by construction — a bead is
# released ONLY when EVERY positive signal is absent (no gate label, no live
# worker, no branch) AND it has aged past the threshold measured from a dedicated
# pilot.dispatched_at stamp (never updated_at — the ga-2azzj Defect-A discipline:
# a missing stamp is stamped-now and never released on first sight). Distinct
# from ga-e5yw2 (dead worker: a worker existed and died) and ga-mtlm6 (deliver to
# existing). Set PILOT_NEVERSTARTED_MINUTES=0 to disable.
PILOT_NEVERSTARTED_MINUTES="${PILOT_NEVERSTARTED_MINUTES:-15}"

# ── Reuse existing crew session, never spawn a 2nd one (gt-4st3n) ─────────────
# A crew identity (e.g. digo-wa, batista-ps) is a single-identity config-agent
# session. Dispatching to it via `gc sling <identity>` + an immediate
# `gc session nudge` had two harmful effects when a session ALREADY existed:
#   1. ASLEEP session → the routed bead made the reconciler RESUME it with
#      --resume (log: origin=flag resume=--resume) and a parallel runtime came up
#      ALONGSIDE the drained one; crew-session-dedup then drained the duplicate,
#      which looks like a "reset" and loses in-progress state (digo/mila 2026-06-13).
#   2. ACTIVE session → the immediate nudge interrupts whatever the crew is doing
#      (possibly work for Athos), duplicating/resetting it.
# The doctrine (Athos + Mayor 2026-06-13): the dispatch signal is the HOOK
# (assignee + routing on the bead) plus an EPHEMERAL, NON-INTERRUPTING nudge —
# never a 2nd session.
#   • ACTIVE session  → hook + `gc session submit --intent follow_up` (queues; the
#     crew picks it up when it next goes idle; never interrupted, never spawned).
#   • ASLEEP session  → `gc session wake` the EXISTING session (no parallel), then
#     hook + follow_up submit. Reuse, not a fresh spawn.
#   • NO session      → legacy `gc sling <identity>` spawn — the only case where a
#     spawn is correct (it is the sole instance, not a duplicate).
# gastown.dog is a DOG POOL (multiple instances by design — IsDogTarget) and is
# exempt: it always takes the spawn path. Fail-open: any error classifying the
# session → fall back to the legacy spawn+nudge path (never deadlock dispatch).
# Set PILOT_REUSE_SESSION=0 to restore the legacy spawn+nudge behaviour.
PILOT_REUSE_SESSION="${PILOT_REUSE_SESSION:-1}"

# ── Ownership / in-flight-collision guard (ga-htjni) ──────────────────────────
# Bug ga-htjni: the Pilot DOUBLE-DISPATCHED wa-zptm to oracle-wa even though
# mila-wa already owned it AND a branch `origin/crew/mila/wa-zptm` already existed
# at the gate. Oracle redid the whole build (wasted cycle) before the collision
# was detected. The flat-pool distribution ignored EXISTING ownership / in-flight
# work and slung a NET-NEW dispatch to a DIFFERENT builder for a bead that was
# already being (or had been) built.
#
# This guard REFUSES a fresh dispatch — at the pre-sling chokepoint, AFTER the
# atomic claim and AFTER all the existing lifecycle/race verify guards — when
# EITHER signal says the work is already real and owned:
#   (a) a branch `origin/crew/*/<bead-id>` ALREADY EXISTS in the bead's rig repo
#       (the STRONGEST signal: code was pushed for this bead → a build happened /
#       is happening → never start a second builder elsewhere), OR
#   (b) the bead's CURRENT assignee is a non-empty NAMED crew whose session is
#       LIVE (it belongs to someone actively working it).
# On a refusal the bead is SKIPPED (claim released, story untouched) so it stays
# with its rightful owner; the next sweep re-evaluates.
#
# RECONCILED WITH RECLAIM — must NOT deadlock a genuinely-abandoned bead:
#   • Condition (a) keys on the SAME "branch exists" signal the never-started
#     (ga-v3z4z) reclaim already uses to KEEP a bead: a branched bead is owned by
#     the gate/its branch, never reclaimed by the Pilot, so refusing a fresh
#     dispatch here can never strand it.
#   • Condition (b) fires ONLY when the assignee's session is LIVE. If the owner
#     is set but its session is DEAD *and* no branch exists, this is the genuine
#     orphan the reclaim paths (ga-e5yw2 dead-worker / ga-v3z4z never-started)
#     release upstream — the guard explicitly does NOT block that case, so the
#     orphan is freed (re-dispatchable) exactly as before.
#   • FAIL-OPEN everywhere: any unresolved leg (no git, repo list empty, roster
#     untrustworthy, jq error) → DO NOT block → dispatch proceeds as pre-guard.
#     The worst case is the pre-fix behaviour (a possible redundant dispatch),
#     never a new deadlock.
# Set PILOT_OWNERSHIP_GUARD=0 to disable (legacy flat-pool behaviour, no redeploy).
PILOT_OWNERSHIP_GUARD="${PILOT_OWNERSHIP_GUARD:-1}"

# ── ctx:ready auto-dispatch — chore/task/debt with a trusted context check ─────
# Final phase of the auto-dispatch architecture. A LIVE, LABEL-ONLY context-check
# daemon now annotates bug/chore/task/debt beads with ctx:ready (context-complete,
# enough spec for a generic builder) or ctx:thin (under-specified). The Pilot's
# legacy queries cover ONLY type:bug + tech-debt + story:approved features —
# chore/task beads fell in NO tier and were never dispatched (~28 sat idle forever:
# the design's known coverage gap). This knob adds a new candidate query for
# chore/task/debt beads (NO story:* label) carrying `-l ctx:ready`, merging them
# into the SAME priority-ordered pool as Tier-1/Tier-2 and passing them through the
# IDENTICAL filter chain (_filter_candidates incl. the empty-veto, _filter_unblocked,
# _filter_explicit_deps, domain-routing, lane:big, dedup). The per-bead dispatch
# template is already type-derived (wa-tm2a) so a chore/task routes to the right
# builder automatically. exec:manual beads ARE excluded — they require physical
# device or human-credential interaction that a crew cannot perform autonomously
# (ga-mfeip AC3). exec:auto and unlabelled beads dispatch normally (conservative
# default: missing exec: label → auto-dispatch is safe, never suppresses work).
#
# DEFAULT 1 (flipped from 0 — Athos directive: the autonomous system must build the
# whole ready backlog itself, not just the funnel). Still env-gated so the Mayor can
# turn it OFF (PILOT_CTX_READY_QUERIES=0 in the launchd plist env) if the ctx:
# labels ever regress. ctx:thin is explicitly excluded as defense-in-depth: an
# under-spec'd bead must NEVER be dispatched even if it somehow also carried
# ctx:ready.
#
# WHY default-on is now SAFE (the original 0 default was a trust gate on the new
# ctx: labels + a flood guard — both are addressed):
#   1. ctx:ready candidates are sourced UPSTREAM of, and merged into, the same
#      ALL_CANDIDATES_JSON pool the existing tiers use. They are therefore bound by
#      the EXACT same Step-3 per-lane caps (MAX_SMALL / MAX_BIG): the Pilot can never
#      dispatch more than the free slots in each lane, regardless of how many
#      ctx:ready beads are queued. A backlog of 28 cannot flood the crews — it drains
#      at the lane-cap rate, one slot per freed slot per sweep, exactly like bugs.
#   2. They are also bound by the ga-d0hz3 cross-stage admission yield, which runs
#      at the TOP of the sweep (before any candidate sourcing): when the Gate is
#      congested AND resources are contended (quota-limited or Dolt hot) the WHOLE
#      sweep defers dispatch — ctx:ready work included — so turning this on can never
#      pile pressure onto an already-congested Gate or a hot Dolt.
#   3. Every existing exclusion is preserved verbatim: non-empty assignee (owned),
#      story:in-flight, story:done, gate:passed, pilot:dispatching, gate:needs-human,
#      needs:engine-window, pilot:dispatched, epics, pre-approval labels, empty
#      description, blocked deps, explicit deps. The query only ADDS a source; it
#      loosens nothing. A bad/empty ctx:ready query fails open to "[]" and can never
#      break the core bug/story dispatch.
PILOT_CTX_READY_QUERIES="${PILOT_CTX_READY_QUERIES:-1}"

# ── ga-mfeip: WA-store ctx:ready dispatch ─────────────────────────────────────
# Extends ctx:ready scanning to rig DBs (whatsapp_automation, etc.). WA-store
# beads (wa-* prefix) live in the rig's own Dolt DB, not in HQ, so the HQ
# ctx:ready query at Step 2a-ctx never sees them. This knob gates an ADDITIONAL
# rig-DB scan that runs alongside the HQ scan whenever PILOT_CTX_READY_QUERIES=1.
#
# Dispatch path for rig-native beads: `gc sling <gascity-crew> <wa-bead>` is
# REFUSED by the engine ("cross-store routes wedge pools — tr-6s7yx"). The
# correct path is `bd -C <rig-db> update --assignee <crew>` to claim the bead,
# then `gc session nudge <crew> <prompt>` to deliver the task. The crew still
# learns of the work and marks it in-flight in the rig DB exactly as the standard
# path does for HQ beads, using the same STORY_BEAD_CITY / pilot:* label writes.
#
# exec:manual beads are EXCLUDED from auto-dispatch (AC3 of ga-mfeip): a bead
# labelled exec:manual requires human action (physical device, gov-portal CAPTCHA,
# human credential) and must NEVER be autonomously built by a crew. The crew would
# be dispatched with no way to complete the task. exec:auto and unlabelled beads
# are dispatched normally (conservative default: missing label = auto is fine).
#
# Env-gated + fail-open: set PILOT_CTX_READY_RIG_QUERIES=0 in the launchd plist
# to disable independently of the HQ query (useful when WA rig DB is unstable
# without blocking HQ ctx:ready dispatch). Defaults to inherit PILOT_CTX_READY_QUERIES.
PILOT_CTX_READY_RIG_QUERIES="${PILOT_CTX_READY_RIG_QUERIES:-$PILOT_CTX_READY_QUERIES}"

# Which rigs the rig ctx:ready scan covers (space-list of rig NAMES). Default
# "whatsapp_automation" — ga-mfeip's stated scope ("rigs além de whatsapp_automation
# não faz parte desta entrega"). Set to "all" to scan every non-HQ rig. Scoping this
# avoids wasted ctx:ready queries against rigs with no dispatchable backlog
# (property_scrapers/marketing/lexbh/gastown/deacon are empty) → lighter Dolt footprint
# per sweep. Expand the list deliberately when another rig is dispatch-ready.
PILOT_CTX_READY_RIGS="${PILOT_CTX_READY_RIGS:-whatsapp_automation}"

# Dry-run mode: show what WOULD happen, make zero changes.
DRY_RUN="${DRY_RUN:-0}"

# Story bead to NEVER dispatch (the Pilot itself — cannot self-build).
SELF_BEAD_ID="ga-8c1"

# ── Rig → Builder routing table ───────────────────────────────────────────────
# Maps story.rig metadata → gc sling target alias.
# Priority: prefer the rig's dedicated builder; fall back to gastown.dog.
#
# Canonical crew-agent naming convention (ga-nkkku): <name>-<sigla>
# Sigla → rig mapping (source of truth):
#   lx = lexbh              (batista-lx)
#   wa = whatsapp_automation (digo-wa, mila-wa, oracle-wa, peter-wa, thies-wa)
#   ps = property_scrapers  (batista-ps)
#   ma = marketing
#   hq = gastown-hq         (system/infra agents)
# rig_to_builders <rig> — print the rig's ORDERED builder POOL (space-separated).
# A rig with >1 interchangeable single-identity crew (e.g. whatsapp_automation:
# digo/mila/oracle/peter/thies-wa) is a POOL: the dispatcher distributes work
# across its members (ga-mtlm6) instead of piling every bead on one. Pool order
# is the dispatch preference (first-eligible wins). Single-member rigs are a pool
# of one — behaviourally identical to the pre-ga-mtlm6 single-target routing.
rig_to_builders() {
  local rig="$1"
  case "$rig" in
    gascity)               echo "gastown.dog"    ;;
    whatsapp_automation|wa) echo "digo-wa mila-wa oracle-wa peter-wa thies-wa" ;;
    property_scrapers|ps)  echo "batista-ps"     ;;
    gastown|gt)            echo "gastown.dog"    ;;
    lexbh|lx)              echo "gastown.dog"    ;;
    marketing|ma)          echo "gastown.dog"    ;;
    *)                     echo "gastown.dog"    ;;
  esac
}

# rig_to_builder <rig> — back-compat single target: the first builder of the pool.
rig_to_builder() {
  set -- $(rig_to_builders "$1")
  echo "${1:-gastown.dog}"
}

# ── wa-root-worktree-isolation: rig-root → worktree dispatch directive ─────────
# Secondary (script-layer) defense for the recurring "production root checked out
# onto crew branches" bug. The WA rig's REGISTERED path IS its production root
# (/Users/athos/gt/whatsapp_automation). When the engine slings a wa- bead to a
# POOL crew, it sets WorkDir = that root (no per-bead worktree in the crew path),
# and the crew's crew-commit then runs `git checkout -b crew/...` IN-PLACE on the
# production root → the root goes off main, breaking daemons/painel/siblings.
#
# The PRIMARY fix is engine-side (sling provisions a per-bead worktree); the
# crew-commit SKILL.md Step-1.5 guard is the load-bearing skill-layer fix. This
# Pilot directive is BEST-EFFORT reinforcement: when a bead would build in a
# rig's bare production root (any pool-crew rig build), inject an explicit
# DO-NOT-BRANCH-IN-ROOT / use-a-worktree instruction into the dispatch prompt so
# the crew runs the guard even if its skill copy is stale. The dispatcher cannot
# itself change the crew's CWD (that is the engine's WorkDir), so this can only
# instruct — it never silently flips state. Fail-open: any lookup miss → no
# directive (identical to pre-change behaviour).

# rig_root_path <rig> — registered production-root path for a rig, or "" if none.
# Memoized across the sweep in PILOT_RIG_PATHS_JSON (one `gc rig list` per run).
PILOT_RIG_PATHS_JSON=""
rig_root_path() {
  local _rig="$1"
  [ -z "$_rig" ] && return 0
  if [ -z "$PILOT_RIG_PATHS_JSON" ]; then
    PILOT_RIG_PATHS_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo '{}')
  fi
  printf '%s' "$PILOT_RIG_PATHS_JSON" \
    | jq -r --arg n "$_rig" '.rigs[]? | select(.name == $n) | .path' 2>/dev/null \
    | head -1
}

# worktree_directive_for <rig> <builder> — echo a prompt block (or nothing).
# Emits the directive ONLY when the build would land in the rig's bare root:
#   - a real, on-disk registered rig root exists for $rig, AND
#   - the builder is NOT the gastown.dog pool (dogs build in HQ dog dirs, never a
#     rig production root) — every other pool/single crew of a code rig is at risk.
# HQ/gascity builds never carry a directive (the dog pool is exempt).
worktree_directive_for() {
  local _rig="$1" _builder="$2" _root
  [ "$_builder" = "gastown.dog" ] && return 0
  _root=$(rig_root_path "$_rig")
  [ -z "$_root" ] || [ ! -d "$_root" ] && return 0
  cat <<DIRECTIVE

## ⚠️ Rig-root isolation (MANDATORY before you branch)
Your rig's production root is: $_root
If your shell starts there (\`git rev-parse --show-toplevel\` == that path), DO NOT
\`git checkout -b\` in place — it switches the SHARED production checkout off main
and breaks daemons, the painel, and sibling crews. Instead isolate first:
  git -C "$_root" worktree add "$_root/.gc-worktrees/$STORY_ID-\${GC_ALIAS:-crew}" -b "crew/\${GC_ALIAS:-crew}/$STORY_ID" origin/main
  cd "$_root/.gc-worktrees/$STORY_ID-\${GC_ALIAS:-crew}"
and do ALL branch/commit work THERE. The /crew-commit skill (Step 1.5) automates
this guard — run it. If you are already in a crew clone or worktree (NOT the bare
root), proceed normally. The production root must ALWAYS stay on main.
DIRECTIVE
}

# ── Pool selection state (ga-mtlm6) ───────────────────────────────────────────
# PILOT_BUSY_BUILDERS — builders currently holding LIVE in-flight work (computed
#   once per sweep from IN_FLIGHT_JSON's sling-task assignees). A busy single-
#   identity crew must NOT receive a second task (the wa-1eos duplicate-session /
#   branch-corruption hazard).
# PILOT_USED_BUILDERS — builders given work earlier in THIS sweep, so consecutive
#   picks rotate across distinct idle crew rather than all landing on the first.
# Both are space-padded membership lists, fail-open (empty = no exclusion).
PILOT_BUSY_BUILDERS=""
PILOT_USED_BUILDERS=""

# ── Domain map (gt-s1saw / wa-ihto) ───────────────────────────────────────────
# Route by AREA, not blind. Before picking from a rig's pool the dispatcher
# classifies the bead into a coarse DOMAIN and biases the pick toward that
# domain's owner — and AWAY from a crew KNOWN not to own it. This kills the
# re-dispatch loop where UI bugs touching lib/urblink_design_system.py landed on
# digo-wa (the data/email/financeiro owner), got bounced back to the kanban, and
# were re-dispatched to digo every sweep (wa-tnl5/wa-rctg/wa-2p8i, 2026-06-12/13).
#
# Everything here is FAIL-OPEN: an unknown domain or an unmapped rig yields no
# preference and no exclusion, so the pool rotates EXACTLY as before — domain
# routing can only ever be neutral or better than blind routing, never worse.
# The map is intentionally small and data-driven; extend it as crews declare
# their areas (wa-ihto: "demais áreas a mapear com os crews").

# bead_domain <bead_json> — classify a bead into a coarse domain, or "" if unknown.
# Matches path/keyword signals across title + description + criteria + labels
# (case-insensitive). First match wins; order is most-specific-first.
bead_domain() {
  local bead="$1" hay
  hay=$(echo "$bead" | jq -r '
      [ (.title // ""), (.description // ""),
        (.acceptance_criteria // .metadata["story.criterios"] // ""),
        ((.labels // []) | join(" ")) ] | join("  ")
    ' 2>/dev/null || echo "")
  [ -z "$hay" ] && { echo ""; return 0; }
  if printf '%s' "$hay" | grep -iqE 'urblink_design_system|design[ -]system|painel[ -]?hist|\bfrontend\b|\bui\b|\bux\b|\bkanban\b|\bcss\b|stylesheet|layout'; then
    echo "frontend"; return 0
  fi
  if printf '%s' "$hay" | grep -iqE 'financeiro|\bledger\b|enrichment|scraper|mega data set|net ?imoveis|viva ?real|\bemail\b|pipedrive|property data|\bdados\b'; then
    echo "data"; return 0
  fi
  if printf '%s' "$hay" | grep -iqE '\bdolt\b|gate dispatcher|\breviewer\b|\bdispatcher\b|\bframework\b|headroom|\brefinery\b'; then
    echo "infra"; return 0
  fi
  echo ""
}

# rig_domain_owner <rig> <domain> — the crew that OWNS this domain in this rig
# (preferred pick if idle), or "" if none is mapped. Positive ownership only.
rig_domain_owner() {
  case "$1/$2" in
    whatsapp_automation/data|wa/data) echo "digo-wa" ;;
    *)                                echo ""        ;;
  esac
}

# rig_domain_exclude <rig> <domain> — space-separated crew KNOWN NOT to own this
# domain in this rig (dropped from the pool for a bead of that domain), or "".
# Used when the positive owner isn't mapped yet but a WRONG owner is known — e.g.
# WA frontend: we don't yet have a named frontend owner, but we DO know digo-wa
# (data/email/financeiro) is not it, so frontend work must never land on digo.
rig_domain_exclude() {
  case "$1/$2" in
    whatsapp_automation/frontend|wa/frontend) echo "digo-wa" ;;
    *)                                        echo ""        ;;
  esac
}

# ── Domain-build → owning-rig inference (ga-lfvs6/ga-wgcyk/ga-m3n1x misroute) ──
# ROOT (5+ recurrences today: ga-lfvs6, ga-jazy9, ga-m3n1x, ga-wgcyk, ga-yx2d1's
# property siblings): a DOMAIN build (a property_scrapers scraper, or a WA painel/
# pipedrive feature) is authored as an HQ bead (ga-* prefix) by mila with NO
# story.rig metadata and a null assignee. The early rig-inference (gt-pm55p) maps
# the ga- prefix → rig=gascity → rig_to_builders → the ephemeral gastown.dog pool.
# A dog (~25-min TTL, no domain data access, no rig git checkout, no git-diff for
# the gate) CANNOT build a real domain task, so it circuit-breaks and the sweep
# re-dispatches it — a loop. The lane:big nodog guard (ga-jazy9) only catches
# lane:big; these are lane:small DOMAIN builds, so they slip through.
#
# bead_content_rig <bead_json> — infer the OWNING DOMAIN RIG from the bead's text
# (title + description + criteria + labels + story.* metadata), independent of the
# (wrong) story.rig=gascity. Prints the rig name (property_scrapers /
# whatsapp_automation) for a recognised domain build, or "" for generic/HQ work.
# Keyword sets are deliberately domain-specific (not generic words like "data"):
#   property_scrapers — scraper/cadastro/ITBI/RFB/CNAE/PBH/MotherDuck/Hex notebook/
#     geocod*/lat-lon/lote/imóvel/imovel/pesquisa_mercado/proprietár*/terreno/
#     cartório/matrícula/incorporação. These are the property-data engineering
#     signals on ga-lfvs6/ga-wgcyk/ga-m3n1x (and the -ps rig prefix).
#   whatsapp_automation — painel/whatsapp/whapi/pipedrive/kanban história/
#     urblink_design_system/frota/canais/disparo/mensagem. (A wa- prefixed bead
#     already routes correctly via story.rig; this only catches WA-domain features
#     authored as ga- HQ beads.)
# FAIL-OPEN by design: no domain match → "" → caller leaves routing unchanged, so
# genuine generic/HQ work still flows to the dog pool exactly as today. First match
# wins; property_scrapers is checked first (its signals are the recurring misroute).
bead_content_rig() {
  local bead="$1" hay
  hay=$(echo "$bead" | jq -r '
      [ (.title // ""), (.description // ""),
        (.acceptance_criteria // .metadata["story.criterios"] // ""),
        (.metadata["story.o_que_e"] // ""), (.metadata["story.resumo"] // ""),
        (.metadata["story.dependencias"] // ""), (.metadata["story.notebook"] // ""),
        ((.labels // []) | join(" ")) ] | join("  ")
    ' 2>/dev/null || echo "")
  [ -z "$hay" ] && { echo ""; return 0; }
  # WA-INTEGRATION PRECEDENCE (ga-lt8cw/ga-nq64a, 2026-06-19): the WA orchestration/
  # integration layer — pipedrive deals, whapi/whatsapp messaging, the urblink painel,
  # and the Drive bridges that TRIGGER an existing Hex notebook — CONSUMES property data,
  # so its beads carry property nouns (imóvel/ITBI/Hex/CNPJ) too. Without this guard the
  # property check below wins on first-match and the build misroutes to property_scrapers
  # (batista-ps then circuit-breaks → re-dispatch loop). These signals NEVER occur in a
  # genuine property data-build (scrape/consolidate/classify), so they safely precede it.
  # Narrow on purpose: e.g. "drive bridge" (the WA itbi_drive_bridge), not bare "Hex".
  if printf '%s' "$hay" | grep -iqE 'pipedrive|whapi|whatsapp|urblink_design_system|drive[_ ]bridge'; then
    echo "whatsapp_automation"; return 0
  fi
  # property_scrapers domain (the recurring misroute family).
  if printf '%s' "$hay" | grep -iqE 'scraper|scrape|\bcadastro\b|cadastr[ao]|\bITBI\b|\bRFB\b|receita federal|\bCNAE\b|\bCNPJ\b|\bPBH\b|motherduck|\bHex\b|hex notebook|geocod|georreferenc|lat[ -/]?lon|point-in-polygon|pesquisa_mercado|propriet[áa]ri|\bim[óo]vel\b|\bim[óo]veis\b|\blote\b|\blotes\b|\bterreno\b|terreno_livre|cart[óo]rio|matr[íi]cula|incorpora|índice cadastral|indice cadastral|mega_data_set|mega data set'; then
    echo "property_scrapers"; return 0
  fi
  # whatsapp_automation domain features authored as HQ (ga-) beads.
  if printf '%s' "$hay" | grep -iqE '\bpainel\b|whatsapp|\bwhapi\b|pipedrive|urblink_design_system|design[ -]system|painel-hist|kanban hist|\bfrota\b|\bcanais\b|\bcanal\b de alerta|disparo|envio de mensagem'; then
    echo "whatsapp_automation"; return 0
  fi
  echo ""
}

# rig_domain_default_builder <rig> — the PERSISTENT crew that owns a domain rig's
# builds, or "" if the rig has no single persistent owner. Used by the domain-route
# guard to pick the affirmative target when a domain build resolved to a dog and
# the bead has no live crew owner yet. Only rigs with a known persistent crew are
# listed; everything else → "" → the guard DEFERS rather than guess.
rig_domain_default_builder() {
  case "$1" in
    property_scrapers|ps)   echo "batista-ps" ;;
    *)                      echo ""           ;;
  esac
}

# ── ga-mfeip gate (e): suspended-crew exclusion ───────────────────────────────
# A suspended crew (e.g. digo-wa) must NEVER receive a dispatch: the bead would sit
# assigned-but-unbuilt forever (the wa-n0vv→digo phantom). The authoritative source
# is `gc agent list` (STATUS column == "suspended"). The set is probed ONCE per
# process and cached. Only EXPLICITLY-suspended NAMED crews are excluded — an
# unlisted pool member (e.g. an ephemeral gastown.dog) is never in the suspended set,
# so dog dispatch is untouched. Fail-open: if the probe yields nothing (gc absent or
# errored), the suspended set is empty → no crew is excluded → dispatch never blocks
# on a probe failure. PILOT_SUSPENDED_CREWS_OVERRIDE is a test seam (set it to a
# space-list to inject a suspended roster without calling gc).
_PILOT_SUSPENDED_CREWS=""
_PILOT_SUSPENDED_CREWS_LOADED=0
_pilot_suspended_crews() {
  if [ "$_PILOT_SUSPENDED_CREWS_LOADED" != "1" ]; then
    if [ -n "${PILOT_SUSPENDED_CREWS_OVERRIDE+x}" ]; then
      _PILOT_SUSPENDED_CREWS="$PILOT_SUSPENDED_CREWS_OVERRIDE"
    else
      _PILOT_SUSPENDED_CREWS=$(gc agent list 2>/dev/null \
        | awk '$2=="suspended"{print $1}' | tr '\n' ' ' 2>/dev/null || echo "")
    fi
    _PILOT_SUSPENDED_CREWS_LOADED=1
  fi
  printf '%s' "$_PILOT_SUSPENDED_CREWS"
}
# _crew_is_suspended <crew> — return 0 (true) iff the crew is in the suspended set.
_crew_is_suspended() {
  local crew="$1" susp
  susp=$(_pilot_suspended_crews)
  [ -z "$susp" ] && return 1
  case " $susp " in *" $crew "*) return 0 ;; *) return 1 ;; esac
}

# pick_pool_builder <rig> [prefer] [exclude] — echo an idle crew from the rig's
# pool, or nothing (and return 1) if none is eligible. Pure read of the busy/used
# sets above; the caller records the winner via mark_pool_builder so the next
# pick in the same sweep advances to a different crew.
#   prefer  — a domain owner to take FIRST if idle (rig_domain_owner). Ignored if
#             busy/used, falling through to normal rotation.
#   exclude — space-list of crew to DROP for this bead (rig_domain_exclude). An
#             excluded crew is never picked — even when it's the only idle one —
#             so the bead DEFERS rather than re-enter the wrong-domain loop.
# Both default empty ⇒ pre-gt-s1saw behaviour (rotate across idle crew).
pick_pool_builder() {
  local rig="$1" prefer="${2:-}" exclude="${3:-}" crew
  # 1. Domain owner first, if mapped and eligible.
  if [ -n "$prefer" ]; then
    for crew in $(rig_to_builders "$rig"); do
      [ "$crew" = "$prefer" ] || continue
      _crew_is_suspended "$crew" && continue   # ga-mfeip gate (e): never a suspended crew
      case " $PILOT_BUSY_BUILDERS " in *" $crew "*) continue ;; esac
      case " $PILOT_USED_BUILDERS " in *" $crew "*) continue ;; esac
      echo "$crew"
      return 0
    done
  fi
  # 2. Rotate across idle crew, skipping any domain-excluded member.
  for crew in $(rig_to_builders "$rig"); do
    _crew_is_suspended "$crew" && continue   # ga-mfeip gate (e): never a suspended crew
    case " $PILOT_BUSY_BUILDERS " in *" $crew "*) continue ;; esac
    case " $PILOT_USED_BUILDERS " in *" $crew "*) continue ;; esac
    case " $exclude " in *" $crew "*) continue ;; esac
    echo "$crew"
    return 0
  done
  return 1
}

# mark_pool_builder <builder> — record a builder as used this sweep (idempotent).
# MUST be called in the main shell (never a subshell) so the global persists.
mark_pool_builder() {
  case " $PILOT_USED_BUILDERS " in
    *" $1 "*) : ;;
    *) PILOT_USED_BUILDERS="${PILOT_USED_BUILDERS:+$PILOT_USED_BUILDERS }$1" ;;
  esac
}

# ── Lane classification ───────────────────────────────────────────────────────
# classify_lane <bead_json>
# Prints "big" or "small".
classify_lane() {
  local bead="$1"

  # 1. Explicit label wins.
  local labels
  labels=$(echo "$bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
  if echo "$labels" | grep -q "lane:big";   then echo "big";   return; fi
  if echo "$labels" | grep -q "lane:small"; then echo "small"; return; fi

  # 2. story.size_check metadata == "epic" → big.
  local size_check
  size_check=$(echo "$bead" | jq -r '.metadata["story.size_check"] // ""' 2>/dev/null || echo "")
  if [ "$size_check" = "epic" ]; then echo "big"; return; fi

  # 3. Count acceptance criteria lines (newline-separated) — if ≥ threshold → big.
  local criteria crit_count
  criteria=$(echo "$bead" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""' 2>/dev/null || echo "")
  crit_count=$(printf '%s' "$criteria" | grep -c '^.' 2>/dev/null || echo "0")
  # Strip any whitespace/newlines from count (defensive).
  crit_count=$(printf '%s' "$crit_count" | tr -d '[:space:]')
  crit_count=${crit_count:-0}
  if [ "$crit_count" -ge "$BIG_CRITERIA_THRESHOLD" ] 2>/dev/null; then echo "big"; return; fi

  # 4. Default → small.
  echo "small"
}

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: $*"; }

# ── Single-instance guard (ga-2azzj fix 2; ga-7s0or fd-leak rewrite) ──────────
# Two concurrent sweeps (launchd StartInterval overlap, or a manual run racing
# the timer) can BOTH pass the so-called "atomic claim" — `bd label add` is
# idempotent and the post-claim verify only rejects in-flight/done — and then
# sling the SAME story to two builders (the ga-8nu8x double-build). A whole-run
# lock closes that window: only one sweep proceeds; a second exits cleanly.
#
# PRIOR DESIGN (ga-2azzj): `exec 9>$LOCK; flock -n 9` held an exclusive flock on
# fd 9 for the whole sweep. DEFECT (ga-7s0or, P0): fd 9 had NO close-on-exec, so
# every gc/bd/sling child — and any long-lived daemon they (re)spawned, notably a
# dolt sql-server or the slung builder session — INHERITED fd 9 and held the
# flock for its ENTIRE life (5h+ observed: a dolt pid held the lock inode). Every
# later sweep then logged "backing off" and dispatched ZERO: a silent, unbounded,
# total dispatch deadlock independent of Dolt load (it would deadlock at 0% CPU).
#
# bash 3.2 (the launchd interpreter, /bin/bash) cannot set close-on-exec on a
# numbered fd (`exec {var}>` auto-CLOEXEC is bash 4.1+), and closing fd 9 before
# the sling would drop the guard mid-sweep. So we abandon the inheritable-fd
# flock entirely for an fd-LESS lock that no child can ever hold open:
#   • an atomic `mkdir` mutex for mutual exclusion (POSIX-atomic; no fd, no
#     inheritance — a leaked fd cannot keep a directory "locked"), and
#   • a heartbeat file whose MTIME, written at acquire, marks liveness.
# A held lock whose heartbeat mtime is older than PILOT_LOCK_MAX_AGE is a
# dead/zombie holder (a crashed sweep leaves the dir but stops refreshing it) and
# is recovered automatically WITHOUT rm of any flock inode. PID-liveness is
# deliberately NOT used (PID recycling = TOCTOU false-"alive", per ga-7s0or AC).
# Recovery uses an atomic rename (`mv` of the stale dir aside) so two concurrent
# recoverers can never BOTH proceed — only one rename of a given path can win;
# the loser gets ENOENT and backs off (ga-7s0or AC3, no double-dispatch).
PILOT_LOCK_DIR="${TMPDIR:-/tmp}/pilot-dispatcher$(printf '%s' "$GC_CITY" | tr '/ ' '__').lock.d"
PILOT_LOCK_HB="$PILOT_LOCK_DIR/heartbeat"
# A real sweep finishes in seconds; 600s (10 min) is a vast margin that still
# reclaims a wedged holder within two launchd intervals.
PILOT_LOCK_MAX_AGE="${PILOT_LOCK_MAX_AGE:-600}"
PILOT_LOCK_TOKEN="$$:${RANDOM}${RANDOM}"

# Age (seconds) of the heartbeat file; a huge number if it is missing.
_lock_hb_age() {
  local _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$PILOT_LOCK_HB" 2>/dev/null || stat -c %Y "$PILOT_LOCK_HB" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}

_lock_write_hb() { printf '%s\n' "$PILOT_LOCK_TOKEN" > "$PILOT_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a
# peer that recovered our lock after we were (wrongly) judged stale.
_release_pilot_lock() {
  local _own
  _own=$(head -n1 "$PILOT_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$PILOT_LOCK_TOKEN" ] && rm -rf "$PILOT_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE sweep holds it (back off).
_acquire_pilot_lock() {
  if mkdir "$PILOT_LOCK_DIR" 2>/dev/null; then
    _lock_write_hb
    return 0
  fi
  local _age
  _age=$(_lock_hb_age)
  if [ "$_age" -lt "$PILOT_LOCK_MAX_AGE" ]; then
    return 1   # fresh heartbeat → a live sweep is running.
  fi
  # Stale holder. Atomically claim the recovery by renaming the dir aside; only
  # one concurrent recoverer can win this rename (the rest get ENOENT).
  local _reaped="${PILOT_LOCK_DIR}.reaping.${PILOT_LOCK_TOKEN}"
  if mv "$PILOT_LOCK_DIR" "$_reaped" 2>/dev/null; then
    rm -rf "$_reaped" 2>/dev/null || true
    if mkdir "$PILOT_LOCK_DIR" 2>/dev/null; then
      _lock_write_hb
      log "Recovered STALE Pilot lock (heartbeat age ${_age}s ≥ ${PILOT_LOCK_MAX_AGE}s) — taking over (ga-7s0or)."
      return 0
    fi
  fi
  return 1   # lost the recovery race to a peer, or a fresh sweep beat us.
}

if _acquire_pilot_lock; then
  trap '_release_pilot_lock' EXIT
else
  log "Another Pilot sweep holds $PILOT_LOCK_DIR — backing off (single-instance guard)."
  exit 0
fi

echo ""
log "=== Pilot sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Dolt-saturation probe (ga-rk5va constraint a) ─────────────────────────────
# One health probe per sweep seeds DOLT_PID + DOLT_LATENCY_MS; the cheap CPU
# recheck used inside the dispatch loop reuses DOLT_PID via `ps` (sub-second, no
# extra Dolt round-trips). All probes FAIL-SAFE: if Dolt health can't be read we
# treat it as SATURATED (back off), because adding dispatch load to an unknown /
# wedged data plane is exactly the incident this constraint guards against.
DOLT_PID=""
DOLT_LATENCY_MS=""

# ── ga-x3nmz: Claude 5h-quota probe (mirrors gate's gate_quota_limited) ───────
# _pilot_quota_limited → "1" iff the Claude 5h window is exhausted right now, else
# "0". Uses the ga-wjlv9 ground-truth checker (claude-quota-check.sh --quiet,
# exit 2 = LIMITED) when deployed; FAIL-OPEN ("0") when the checker is absent or
# errors, so an unmerged/flaky dependency never wedges dispatch. Honors the
# PILOT_QUOTA_OVERRIDE test seam ("2"=limited). Bounded by `timeout`. No mutation.
_pilot_quota_limited() {
  if [ -n "$PILOT_QUOTA_OVERRIDE" ]; then
    [ "$PILOT_QUOTA_OVERRIDE" = "2" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf '0'; return 0; }
  local _rc=0
  timeout 15 bash "$_qc" --quiet >/dev/null 2>&1 || _rc=$?
  [ "$_rc" = "2" ] && { printf '1'; return 0; }
  printf '0'; return 0
}

# _pilot_quota_eta → short human ETA ("resets 4:50pm (in 37min)") or "" if
# unknown. Reads the checker JSON (reset_time_text + reset_in_minutes). Honors
# PILOT_QUOTA_ETA_OVERRIDE (test seam). Bounded; fail-soft to "".
_pilot_quota_eta() {
  if [ -n "$PILOT_QUOTA_ETA_OVERRIDE" ]; then printf '%s' "$PILOT_QUOTA_ETA_OVERRIDE"; return 0; fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf ''; return 0; }
  local _j; _j=$(timeout 15 bash "$_qc" --json 2>/dev/null || echo "")
  [ -n "$_j" ] || { printf ''; return 0; }
  printf '%s' "$_j" | jq -r '
    if (.reset_time_text // "") == "" then ""
    else "resets " + .reset_time_text
         + ( if (.reset_in_minutes // null) != null then " (in \(.reset_in_minutes)min)" else "" end )
    end' 2>/dev/null || printf ''
}

# _dolt_probe — populate DOLT_PID + DOLT_LATENCY_MS once. Honors the test seams.
_dolt_probe() {
  if [ -n "$PILOT_DOLT_LATENCY_OVERRIDE_MS" ]; then
    DOLT_LATENCY_MS="$PILOT_DOLT_LATENCY_OVERRIDE_MS"
    DOLT_PID="TEST"
    return 0
  fi
  local _h
  # `gc dolt health` bounds each per-db probe internally; cap total wall time so a
  # wedged server can't stall the sweep. A timeout IS evidence of saturation.
  # NOTE: `gc dolt health` does NOT accept the global `--city` flag (unlike
  # `rig list` / `session list`) — passing it errors with "unknown flag: --city"
  # and the probe returns empty → fail-safe saturated → the feature would be
  # permanently throttled off. Scope the city via the GC_CITY env var instead
  # (the leaf walks up from cwd / honors GC_CITY); this is the form that works.
  _h=$(GC_CITY="$GC_CITY" timeout 15 gc dolt health --json 2>/dev/null || echo "")
  DOLT_LATENCY_MS=$(printf '%s' "$_h" | jq -r '.server.latency_ms // empty' 2>/dev/null || echo "")
  DOLT_PID=$(printf '%s' "$_h" | jq -r '.server.pid // empty' 2>/dev/null || echo "")
}

# _dolt_cpu — echo integer CPU% of the live dolt-server pid (cheap). Honors seam.
# Always returns 0 (an empty echo means "no signal") so a missing pid / dead ps
# can never trip `set -e` in the caller's command substitution.
_dolt_cpu() {
  if [ -n "$PILOT_DOLT_CPU_OVERRIDE" ]; then printf '%s' "$PILOT_DOLT_CPU_OVERRIDE"; return 0; fi
  if [ -z "$DOLT_PID" ] || [ "$DOLT_PID" = "TEST" ]; then printf ''; return 0; fi
  # ps %cpu can exceed 100 (per-core); strip the fraction to an int for -gt tests.
  ps -o %cpu= -p "$DOLT_PID" 2>/dev/null | tr -d ' ' | cut -d. -f1 || true
  return 0
}

# _dolt_saturated — return 0 (saturated → back off) / 1 (healthy). FAIL-SAFE:
# missing latency AND missing cpu (probe failed) → saturated.
_dolt_saturated() {
  local _lat _cpu _have=0
  _lat="$DOLT_LATENCY_MS"
  _cpu="$(_dolt_cpu)"
  if [ -n "$_lat" ] && [ "$_lat" -ge 0 ] 2>/dev/null; then
    _have=1
    [ "$_lat" -gt "$PILOT_DOLT_LATENCY_MAX_MS" ] 2>/dev/null && return 0
  fi
  if [ -n "$_cpu" ] && [ "$_cpu" -ge 0 ] 2>/dev/null; then
    _have=1
    [ "$_cpu" -gt "$PILOT_DOLT_CPU_MAX" ] 2>/dev/null && return 0
  fi
  # No usable signal at all → fail-safe to saturated (conservative backoff).
  [ "$_have" -eq 0 ] && return 0
  return 1
}

# ── ga-d0hz3: cross-stage gate-congestion probe ───────────────────────────────
# _pilot_gate_congested → "1" iff the quality gate currently has work backed up,
# else "0". "Congested" = at least one gate-status:queued marker (work waiting to
# be reviewed) OR at least one gate-run in review (gate-status:running). Mirrors
# exactly the two queries the quality-gate-dispatcher itself uses, so the signal is
# the gate's own bookkeeping — not a heuristic.
#
# CRITICAL — FAIL-OPEN ("0"): this probe gates the LOWEST stage's dispatch. If
# either query errors, returns non-JSON, or is otherwise indeterminate, we report
# "0" (NOT congested) → the caller PROCEEDS to dispatch. An unreadable gate must
# never be allowed to wedge the Pilot. Honors the PILOT_GATE_CONGESTED_OVERRIDE
# test seam ("1"/"0"). No mutation; both queries are bounded by `timeout`.
_pilot_gate_congested() {
  if [ -n "$PILOT_GATE_CONGESTED_OVERRIDE" ]; then
    [ "$PILOT_GATE_CONGESTED_OVERRIDE" = "1" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _q _r _n
  # Queued markers — work waiting at the gate (set by quality-gate-guard.sh).
  _q=$(GC_CITY="$GC_CITY" timeout 15 bd -C "$GC_CITY" list --json --all \
        -l type:quality-gate-marker -l gate-status:queued 2>/dev/null || echo "")
  _n=$(printf '%s' "$_q" | jq 'length' 2>/dev/null || echo "")
  if [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null; then printf '1'; return 0; fi
  # Runs in review — reviews currently in progress (gate-status:running).
  _r=$(GC_CITY="$GC_CITY" timeout 15 bd -C "$GC_CITY" list --json --all \
        -l type:quality-gate-run -l gate-status:running 2>/dev/null || echo "")
  _n=$(printf '%s' "$_r" | jq 'length' 2>/dev/null || echo "")
  if [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null; then printf '1'; return 0; fi
  # No queued markers, no running runs, or indeterminate → not congested / fail-open.
  printf '0'; return 0
}

# ── wa-u5r1: candidate-filter helpers + dispatchable-queue emit (relocated up) ─
# These pure helper/emit definitions were moved ABOVE the early-exit gates (quota
# pause, cross-stage defer, both-lanes-full) so the dispatchable-queue emit can run
# on EVERY sweep path — including those that exit before the candidate-gathering
# step. They have no side effects at definition time; the dispatch queries below
# still call _filter_candidates/_filter_unblocked/_filter_explicit_deps unchanged.

_FILTER_PREAPPROVAL_LABELS='["story:unrefined","story:refinement-in-progress","story:triage","story:cancelled"]'
_filter_candidates() {
  jq --arg self "$SELF_BEAD_ID" --argjson preapproval "$_FILTER_PREAPPROVAL_LABELS" \
    '[.[] | select(
        .id != $self
        and (.assignee == null or .assignee == "")
        and ((.issue_type // .type // "") != "epic")
        and (((.labels // []) | index("story:epic-split")) | not)
        and (((.labels // []) - $preapproval) | length) == ((.labels // []) | length)
        and ((.description // "") | test("\\S"))
     )]' \
    2>/dev/null || echo "[]"
}
# ── context veto (Athos): a bead with an EMPTY/whitespace-only description can
# NEVER dispatch — a generic agent has no context to build it. EMPTY-ONLY by
# design (test("\\S") = keep if any non-whitespace char): NOT a length/byte
# threshold, so a terse-but-complete bead ("CDP 9223 down, restart") still
# passes and a legacy/cross-rig bead is never stranded by length. Measured
# 2026-06-17: 0 false-drops on the current bug/tech-debt/approved pool (none are
# empty); it only holds the ~7 genuinely-empty/mislabeled beads. Thin-but-non-
# empty quality is a separate gate (creation-time ctx:thin), not this floor.

# _filter_unblocked <db_dir>   (reads candidate JSON array from stdin)
# Drops candidates that are currently BLOCKED by unresolved (open) dependencies
# in <db_dir>, using bd's blocker-aware `bd blocked` set. This is the fix for
# bug ga-5ew: the Pilot must NOT dispatch a story whose hard dependency is not
# yet merged/closed (it did — dispatched ga-30v while dep ga-d81 was unmerged).
# A bead is "blocked" iff it has a dependency that is not yet closed; a dep that
# is already closed does NOT block (so we cannot simply filter on dependency_count).
#
# FAIL-OPEN: if `bd blocked` errors, returns nothing, or the jq filter fails,
# candidates pass through UNCHANGED — never worse than the pre-fix behavior.
# Diagnostics go to stderr (which the top-level `exec ... 2>&1` routes to the
# log) so stdout stays pure JSON for the caller's command-substitution capture.
_filter_unblocked() {
  local db_dir="$1"
  local arr blocked_ids blocked_json before after filtered
  arr=$(cat)

  blocked_ids=$(bd -C "$db_dir" blocked --json 2>/dev/null \
    | jq -r '(.[]?.id) // empty' 2>/dev/null || echo "")
  # Nothing blocked in this DB (or probe failed) → pass through unchanged.
  if [ -z "$blocked_ids" ]; then
    printf '%s' "$arr"
    return 0
  fi

  blocked_json=$(printf '%s\n' "$blocked_ids" \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")

  before=$(printf '%s' "$arr" | jq 'length' 2>/dev/null || echo "0")
  filtered=$(printf '%s' "$arr" | jq --argjson blk "$blocked_json" \
    '[.[] | select((.id as $i | $blk | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  after=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo "0")

  if [ "$before" != "$after" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: excluded $((before - after)) blocked candidate(s) in $db_dir (unresolved deps — ga-5ew fix)" >&2
  fi
  printf '%s' "$filtered"
}

# _filter_explicit_deps <db_dir>   (reads candidate JSON array from stdin)
# Drops candidates that declare an EXPLICIT, still-open dependency via the
# `story.depends_on_beads` metadata field — a space/comma/newline-separated list
# of bead IDs that this bead must be built ON TOP OF.
#
# This is the fix for bug ga-do8jj: the Pilot dispatched ga-2e605 BEFORE its
# real dependency ga-e72kf (the canonical painel base) had landed. The
# dependency was real, but it lived only in PROSE ("Construir SOBRE a base
# canônica ga-e72kf …" in story.dependencias) and was never encoded as a formal
# `bd` blocks-edge — so `bd blocked` (and thus _filter_unblocked above) could
# not see it, and the dependent story slipped through. This filter is the
# structured, zero-false-positive realization of the bug's fix-option (b),
# "convenção de dep explícita": a dedicated field the dispatcher enforces.
#
# CONTRACT — deliberately narrow to avoid false-positive deadlocks:
#   * ONLY bead IDs in the dedicated `story.depends_on_beads` field are honored.
#     We do NOT parse the free-form `story.dependencias` prose, which mixes hard
#     deps with coordination/negative references ("coordenar com ga-gzf5a",
#     "NÃO da wa-rlzo") that must NOT block dispatch.
#   * A referenced dep is SATISFIED iff it is closed. Any non-closed dep holds
#     the candidate back for THIS sweep only — AUTO-CLEARING: once the dep
#     closes, the next sweep dispatches. No manual un-hold, no stale state.
#   * Self-references are ignored (a bead never blocks itself).
#
# FAIL-OPEN: any bd error / unresolvable dep status passes the candidate through
# UNCHANGED — never stricter than the pre-fix behavior, so a transient Dolt
# hiccup or a typo'd dep id can never wedge the pipeline. Diagnostics → stderr
# (routed to the log by the top-level `exec … 2>&1`) so stdout stays pure JSON.
_filter_explicit_deps() {
  local db_dir="$1"
  local arr
  arr=$(cat)
  [ -z "$arr" ] && { printf '[]'; return 0; }

  # Fast path: no candidate declares explicit deps → pass through untouched
  # (zero extra bd calls on the common case — Scenarios 1/2 and normal sweeps).
  if ! printf '%s' "$arr" \
      | jq -e 'any(.[]?; (.metadata["story.depends_on_beads"] // "") != "")' \
        >/dev/null 2>&1; then
    printf '%s' "$arr"
    return 0
  fi

  local held_ids="" bead bid deps dep dep_status
  while IFS= read -r bead; do
    [ -z "$bead" ] && continue
    bid=$(printf '%s' "$bead" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$bid" ] && continue
    deps=$(printf '%s' "$bead" \
      | jq -r '.metadata["story.depends_on_beads"] // ""' 2>/dev/null || echo "")
    deps=$(printf '%s' "$deps" | tr ',\n' '  ')
    for dep in $deps; do
      dep=$(printf '%s' "$dep" | tr -d '[:space:]')
      [ -z "$dep" ] && continue
      [ "$dep" = "$bid" ] && continue
      dep_status=$(bd -C "$db_dir" show "$dep" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | .status // ""' \
          2>/dev/null || echo "")
      # Non-closed, resolvable dep → HOLD. Empty status (lookup failed) →
      # fail-open: do not hold on a dep we cannot resolve.
      if [ -n "$dep_status" ] && [ "$dep_status" != "closed" ]; then
        held_ids="$held_ids $bid"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: holding $bid — explicit dep $dep is '$dep_status' (not closed) [story.depends_on_beads — ga-do8jj fix]" >&2
        break
      fi
    done
  done < <(printf '%s' "$arr" | jq -c '.[]?' 2>/dev/null)

  if [ -z "$held_ids" ]; then
    printf '%s' "$arr"
    return 0
  fi

  local held_json filtered
  held_json=$(printf '%s\n' $held_ids \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")
  filtered=$(printf '%s' "$arr" | jq --argjson held "$held_json" \
    '[.[] | select((.id as $i | $held | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  printf '%s' "$filtered"
}

# ── wa-u5r1: emit the Pilot's FULL dispatchable queue for the painel ──────────
# Athos's requirement: the painel's "Aprovadas" column must be a FAITHFUL mirror
# of the Pilot's dispatch queue — EXACTLY the open beads the Pilot would dispatch
# NOW: NOT in-flight, NOT assigned, NOT braked (gate:needs-human / engine-window /
# pre-approval lifecycle), and ONLY the types the Pilot actually queries (type:bug
# + tech-debt + story:approved features; ctx:ready chore/task whenever
# PILOT_CTX_READY_QUERIES=1, which is now the DEFAULT — the painel must not show
# ctx:ready work the Pilot never queries). The PILOT is the single source of truth:
# it computes its own
# eligible set with its own filters and writes it here; the painel renders exactly
# this file. The set is the FULL eligible queue (every dispatchable candidate),
# NOT the lane-cap-limited subset the Pilot picks in one sweep — so the painel
# shows the whole backlog of dispatchable work, independent of how many builder
# slots happen to be free right now.
#
# The emit re-runs the SAME candidate queries (identical --exclude-label set) and
# the SAME filter chain (_filter_candidates → _filter_unblocked →
# _filter_explicit_deps) the real dispatch uses, across HQ + every rig DB. Unlike
# the dispatcher's rig scan (a FALLBACK only when HQ is empty), the emit unions
# HQ + rigs UNCONDITIONALLY: the eligible queue spans all stores, so the painel
# must see all of it. This does NOT change dispatch behaviour in any way — it is a
# read-only ADDITIVE step that only writes a file.
#
# CONTRACT (kept identical on the painel side, daemons/painel_visibilidade.py):
#   {"generated_at": "<ISO8601 UTC>", "ttl_seconds": <int>, "count": <int>,
#    "items": [ {"id","title","type","rig","priority","created_at","assignee",
#                "store"} , … ]}
# Written EVEN WHEN ZERO ({...,"count":0,"items":[]}) so the painel can tell
# "empty queue" (system correctly out of work) from "file stale/missing" (don't
# trust it). Written ATOMICALLY (tmp + mv) so a reader never sees a partial file.
#
# Env-gated PILOT_EMIT_DISPATCHABLE (default 1). FAIL-OPEN by construction: the
# whole body is wrapped so ANY error logs a warning and returns 0 — a failed emit
# must NEVER abort or alter a dispatch sweep. PILOT_DISPATCHABLE_FILE overrides the
# output path (TEST-ONLY seam, mirrors PILOT_CITY_OVERRIDE); production resolves to
# ~/.gc/pilot-dispatchable.json (HOME is set in the launchd plist).
PILOT_EMIT_DISPATCHABLE="${PILOT_EMIT_DISPATCHABLE:-1}"
PILOT_DISPATCHABLE_TTL="${PILOT_DISPATCHABLE_TTL:-600}"
PILOT_DISPATCHABLE_FILE="${PILOT_DISPATCHABLE_FILE:-${HOME}/.gc/pilot-dispatchable.json}"

# _emit_query_one <db_dir> <store_label> — print the fully-filtered eligible
# candidate array for ONE store, with a "store" field stamped on each item.
# Mirrors the Tier-1 (bug + tech-debt), Tier-2 (story:approved) and optional
# ctx:ready queries + the shared filter chain. Pure read; fail-open to "[]".
_emit_query_one() {
  local _db="$1" _store="$2"
  local _bugs _debt _feat _ctx _merged
  _bugs=$(bd -C "$_db" list --json -t bug \
    --exclude-label "story:in-flight" --exclude-label "story:done" \
    --exclude-label "gate:passed" --exclude-label "pilot:dispatching" \
    --exclude-label "gate:needs-human" --exclude-label "needs:engine-window" \
    --exclude-label "pilot:dispatched" --exclude-type epic -n 0 2>/dev/null || echo "[]")
  _debt=$(bd -C "$_db" list --json -l "tech-debt" \
    --exclude-label "story:in-flight" --exclude-label "story:done" \
    --exclude-label "gate:passed" --exclude-label "pilot:dispatching" \
    --exclude-label "gate:needs-human" --exclude-label "needs:engine-window" \
    --exclude-label "pilot:dispatched" --exclude-type epic -n 0 2>/dev/null || echo "[]")
  _feat=$(bd -C "$_db" list --json -l "story:approved" \
    --exclude-label "story:in-flight" --exclude-label "story:done" \
    --exclude-label "gate:passed" --exclude-label "pilot:dispatching" \
    --exclude-label "gate:needs-human" --exclude-label "needs:engine-window" \
    --exclude-label "pilot:dispatched" --exclude-type epic -n 0 2>/dev/null || echo "[]")
  _ctx="[]"
  if [ "$PILOT_CTX_READY_QUERIES" = "1" ]; then
    _ctx=$(bd -C "$_db" list --json -l "ctx:ready" \
      --exclude-label "ctx:thin" --exclude-label "story:approved" \
      --exclude-label "story:unrefined" --exclude-label "story:refinement-in-progress" \
      --exclude-label "story:triage" --exclude-label "story:in-flight" \
      --exclude-label "story:done" --exclude-label "story:cancelled" \
      --exclude-label "gate:passed" --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" --exclude-type epic -n 0 2>/dev/null || echo "[]")
    _ctx=$(echo "$_ctx" | jq '
        [ .[] | select(
            ((.issue_type // .type // "") | ascii_downcase) as $t
            | ($t == "chore" or $t == "task" or $t == "debt" or $t == "tech-debt")
              or (((.labels // []) | index("tech-debt")) != null)
          ) ]' 2>/dev/null || echo "[]")
  fi
  _merged=$(echo "$_bugs $_debt $_feat $_ctx" \
    | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")
  # IDENTICAL filter chain to the real dispatch path.
  _merged=$(echo "$_merged" | _filter_candidates)
  _merged=$(echo "$_merged" | _filter_unblocked "$_db")
  _merged=$(echo "$_merged" | _filter_explicit_deps "$_db")
  # Stamp the originating store on every item (so the painel knows where it lives).
  echo "$_merged" | jq --arg store "$_store" '[ .[] | . + {"_emit_store": $store} ]' 2>/dev/null || echo "[]"
}

# _pilot_emit_dispatchable — compute the full cross-store eligible queue and write
# PILOT_DISPATCHABLE_FILE atomically. Idempotent per sweep (guarded by
# PILOT_EMITTED_DONE). FAIL-OPEN: the entire body runs in a subshell-guarded
# wrapper; any failure logs and returns 0 without touching dispatch state.
PILOT_EMITTED_DONE=0
_pilot_emit_dispatchable() {
  [ "$PILOT_EMIT_DISPATCHABLE" = "1" ] || return 0
  [ "$PILOT_EMITTED_DONE" = "1" ] && return 0
  PILOT_EMITTED_DONE=1
  # Everything below is best-effort; a failure must never break the sweep.
  {
    local _all _rig_paths _rp _items _count _now _tmp _dir
    _all=$(_emit_query_one "$GC_CITY" "hq" 2>/dev/null || echo "[]")
    # Union every non-HQ rig store too (the eligible queue spans all stores).
    _rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
      | jq -r '.rigs[] | select(.hq == false) | "\(.path)\t\(.name)"' 2>/dev/null || echo "")
    while IFS=$'\t' read -r _rp _rname; do
      [ -z "$_rp" ] || [ ! -d "$_rp" ] && continue
      [ "$_rp" = "$GC_CITY" ] && continue
      local _r
      _r=$(_emit_query_one "$_rp" "${_rname:-rig}" 2>/dev/null || echo "[]")
      _all=$(echo "$_all $_r" | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "$_all")
    done <<< "$_rig_paths"

    # Project to the painel contract shape + stable order (priority, created_at, id).
    _items=$(echo "$_all" | jq '
        sort_by([ (.priority // 99), (.created_at // ""), (.id // "") ])
        | [ .[] | {
            id:         .id,
            title:      (.title // .description // "(sem título)"),
            type:       ((.issue_type // .type // "task")),
            rig:        ((.metadata["story.rig"] // "") | tostring),
            priority:   (.priority // 99),
            created_at: (.created_at // ""),
            assignee:   ((.assignee // "") | tostring),
            store:      (._emit_store // "hq")
          } ]' 2>/dev/null || echo "[]")
    [ -z "$_items" ] && _items="[]"
    _count=$(echo "$_items" | jq 'length' 2>/dev/null || echo "0")
    _now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    _dir=$(dirname "$PILOT_DISPATCHABLE_FILE")
    mkdir -p "$_dir" 2>/dev/null || true
    _tmp="${PILOT_DISPATCHABLE_FILE}.tmp.$$"
    if jq -n --arg gen "$_now" --argjson ttl "$PILOT_DISPATCHABLE_TTL" \
         --argjson count "$_count" --argjson items "$_items" \
         '{generated_at:$gen, ttl_seconds:$ttl, count:$count, items:$items}' \
         > "$_tmp" 2>/dev/null; then
      mv -f "$_tmp" "$PILOT_DISPATCHABLE_FILE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
      log "Emitted dispatchable queue → $PILOT_DISPATCHABLE_FILE (count=$_count, ttl=${PILOT_DISPATCHABLE_TTL}s, wa-u5r1)."
    else
      rm -f "$_tmp" 2>/dev/null || true
      warn "Could not write dispatchable-queue emit (jq failed) — leaving previous file untouched (wa-u5r1, fail-open)."
    fi
  } 2>/dev/null || warn "Dispatchable-queue emit errored — ignored (wa-u5r1, fail-open)."
  return 0
}

_dolt_probe
if _dolt_saturated; then
  PILOT_DOLT_SATURATED_AT_START=1
  warn "Dolt SATURATED at sweep start (latency=${DOLT_LATENCY_MS:-?}ms pid=${DOLT_PID:-?} cpu=$(_dolt_cpu)% thresholds: lat>${PILOT_DOLT_LATENCY_MAX_MS} cpu>${PILOT_DOLT_CPU_MAX}). Throttling to 1 dispatch/lane this sweep (ga-rk5va backoff)."
else
  PILOT_DOLT_SATURATED_AT_START=0
  log "Dolt health OK (latency=${DOLT_LATENCY_MS:-?}ms cpu=$(_dolt_cpu)%) — dispatch-to-capacity armed."
fi

# ── wa-u5r1: emit the FULL dispatchable queue for the painel (ALWAYS, fail-open) ─
# Computed here — AFTER the lock + Dolt probe, BEFORE every early-exit gate (quota
# pause, cross-stage defer, both-lanes-full) — so the painel's "Aprovadas" mirror
# is refreshed on EVERY sweep, even the sweeps that dispatch nothing. The eligible
# QUEUE exists independently of whether builder slots are free or the sweep is
# paused; the painel must reflect it regardless. This is purely additive + fully
# fail-open: it can never abort or alter the dispatch decisions that follow.
_pilot_emit_dispatchable

# ── ga-x3nmz: Claude 5h-quota back-off — PAUSE dispatch when the window is dry ─
# Probe once per sweep, AFTER the Dolt gate (cheap when quota is fine: one bounded
# checker call). If the 5h window is exhausted, a builder dispatched now would die
# mid-build, so PAUSE the whole sweep: dispatch nothing, mutate no marker, and let
# the candidate stories be re-picked automatically once the window resets. This is
# a full pause (not a throttle): under exhaustion every new builder dies, so there
# is no safe non-zero dispatch level. FAIL-OPEN via _pilot_quota_limited.
if [ "$(_pilot_quota_limited)" = "1" ]; then
  _q_eta=$(_pilot_quota_eta)
  warn "Claude 5h quota LIMITED — PAUSING all dispatch this sweep (builders would die mid-build). Stories stay queued; auto-resumes when the window resets${_q_eta:+ ($_q_eta)} (ga-x3nmz)."
  notify -t "⏸️ Pilot pausado: cota 5h" -p 3 "Pilot pausado — cota 5h do Claude esgotada; nenhum builder despachado, retoma quando resetar${_q_eta:+ ($_q_eta)} (ga-x3nmz)." 2>/dev/null || true
  log "=== Pilot sweep complete: dispatched=0 (paused: cota 5h limitada${_q_eta:+, $_q_eta}) ==="
  exit 0
fi

# ── ga-d0hz3: CROSS-STAGE admission gate — most-advanced-first / WIP-limit ─────
# The Pilot is the LOWEST stage (approved→execution). It must YIELD to a congested
# higher stage (the Gate) ONLY under genuine resource contention; otherwise it runs
# freely (parallel — the pools differ). DEFER this sweep (dispatch nothing, mutate
# no marker — identical shape to the quota PAUSE above) IFF:
#       gate is CONGESTED  (queued markers > 0 OR runs in review > 0)
#   AND resources CONTENDED (Claude quota limited OR Dolt hot)
#
# Note on the quota arm: the quota PAUSE above already exited the sweep when the
# 5h window is exhausted, so reaching HERE means quota is OK. The resource-contended
# term therefore resolves through the Dolt signal in practice; the quota term is
# kept in the predicate for correctness/defensiveness (so reordering the gates can
# never silently drop it). PILOT_DOLT_SATURATED_AT_START was computed at sweep
# start (latency OR cpu over ceiling, fail-safe-saturated when the probe is blind).
#
# Anti-starvation: the defer is CONDITIONAL on (gate-has-work AND resource-tight).
# It NEVER fires when resources are abundant, so the moment Dolt calms (or the
# quota frees) the Pilot dispatches — it can never be starved indefinitely. Gate
# empty → never defer. FAIL-OPEN: _pilot_gate_congested returns "0" on any error.
# Gated behind CROSS_STAGE_PRIORITY_ENABLED (=0 → this whole block is skipped =
# exact pre-ga-d0hz3 behavior).
if [ "$CROSS_STAGE_PRIORITY_ENABLED" = "1" ]; then
  _xstage_quota_limited="$(_pilot_quota_limited)"          # "1"/"0" (fail-open "0")
  _xstage_dolt_hot="${PILOT_DOLT_SATURATED_AT_START:-0}"   # "1"/"0" (fail-safe "1")
  _xstage_resource_tight=0
  { [ "$_xstage_quota_limited" = "1" ] || [ "$_xstage_dolt_hot" = "1" ]; } \
    && _xstage_resource_tight=1
  # Only pay for the gate-congestion bead query when resources are actually tight —
  # when resources are abundant we dispatch regardless, so the probe is pointless
  # load on a calm Dolt. (Cheap-path: skip two bd round-trips on the common case.)
  if [ "$_xstage_resource_tight" = "1" ]; then
    _xstage_gate_congested="$(_pilot_gate_congested)"      # "1"/"0" (fail-open "0")
    if [ "$_xstage_gate_congested" = "1" ]; then
      warn "Cross-stage YIELD (ga-d0hz3): Gate is CONGESTED and resources are CONTENDED (quota_limited=${_xstage_quota_limited} dolt_hot=${_xstage_dolt_hot}) — DEFERRING new builds this sweep so the more-advanced Gate stage can drain first. Approved stories stay queued; auto-resumes when Dolt calms / quota frees. Most-advanced-first."
      notify -t "⏸️ Pilot cede ao Gate" -p 2 "Pilot adiou despachar builds novos — Gate congestionado + recurso contido (dolt_hot=${_xstage_dolt_hot}, quota_limited=${_xstage_quota_limited}). Retoma quando o recurso aliviar (ga-d0hz3)." 2>/dev/null || true
      log "=== Pilot sweep complete: dispatched=0 (deferred: cross-stage gate-congested + resource-contended, ga-d0hz3) ==="
      exit 0
    fi
    log "Cross-stage check (ga-d0hz3): resources contended (quota_limited=${_xstage_quota_limited} dolt_hot=${_xstage_dolt_hot}) but Gate NOT congested — dispatching normally."
  fi
fi

# ── Step 0: TTL recovery — release stale pilot:dispatching claims (ga-2azzj) ───
# A pilot:dispatching label means a dispatch is (or was) in progress. We may only
# RECYCLE it when it is genuinely STALE — i.e. the dispatcher crashed mid-run.
#
# DEFECT A (ga-2azzj, the bug this rewrite fixes): the previous code measured
# staleness from the bead's updated_at. `bd label add` does NOT bump updated_at
# to claim time, so an OLD bead's FRESH claim read as age >> TTL (observed
# 47433s ≈ 13h for a 5-min-old claim) and got released on the very next sweep →
# the story became re-dispatchable while a builder was already building it →
# the same story went to two dogs (ga-8nu8x double-build, one wasted cycle).
#
# FIX: age is measured from a dedicated metadata stamp `pilot.dispatching_at`,
# written at claim time (see dispatch_one) BEFORE the label, so the label can
# never exist without its stamp. Decision rules:
#   - stamp missing (legacy claim) → DO NOT release; stamp NOW so the clock
#       starts from this sweep. Never fall back to updated_at (that IS Defect A).
#   - stamp present, age <= TTL    → keep (the claim is fresh, build in flight).
#   - stamp present, age >  TTL, but a recorded sling task (pilot.sling_bead) is
#       still OPEN → a builder is actively working a long build; refuse release.
#   - stamp present, age >  TTL, no live sling task → release (truly stale).
#
# gt-pm55p: Also scan rig DBs. After the cross-rig fix, pilot:dispatching labels
# for wa-*/ps-*/etc. beads live in their rig DB, not in GC_CITY. Without rig
# scanning, stale cross-rig claims would never be cleaned up by TTL recovery.

# Helper: scan one DB for stale pilot:dispatching claims and release them.
# Usage: _ttl_recover_db <db_path> <now_epoch> <ttl_secs>
_ttl_recover_db() {
  local _db="$1" _now="$2" _ttl="$3"
  local _stale_json _stale_count
  # ga-mfeip: extend TTL recovery to cover ctx:ready rig-native beads that carry
  # pilot:dispatching but NOT story:approved (chore/task type beads). Query ALL
  # pilot:dispatching beads unconditionally: story:approved + ctx:ready rig beads
  # both wear pilot:dispatching, so a single query covers both. The story:approved
  # constraint is dropped here; it was belt-and-suspenders filtering, not a
  # correctness requirement (the label state machine is the real guard).
  _stale_json=$(bd -C "$_db" list --json --all \
    -l "pilot:dispatching" \
    2>/dev/null || echo "[]")
  _stale_count=$(echo "$_stale_json" | jq 'length' 2>/dev/null || echo "0")
  [ "$_stale_count" -le "0" ] && return 0

  echo "$_stale_json" | jq -c '.[]' | while IFS= read -r bead; do
    local _bid _stamp _sling
    _bid=$(echo "$bead" | jq -r '.id' 2>/dev/null || echo "")
    [ -z "$_bid" ] && continue
    _stamp=$(echo "$bead" | jq -r '.metadata["pilot.dispatching_at"] // ""' 2>/dev/null || echo "")
    _sling=$(echo "$bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")

    if [ -z "$_stamp" ] || ! [ "$_stamp" -ge 0 ] 2>/dev/null; then
      warn "TTL: $_bid has pilot:dispatching but no pilot.dispatching_at stamp (legacy) — stamping now, NOT releasing (Defect A guard)."
      bd -C "$_db" update "$_bid" --set-metadata "pilot.dispatching_at=$_now" -q 2>/dev/null || true
      continue
    fi

    local _age=$((_now - _stamp))
    if [ "$_age" -le "$_ttl" ]; then
      log "TTL: $_bid claim is fresh (age=${_age}s <= TTL=${_ttl}s, stamp-based) — keeping."
      continue
    fi

    if [ -n "$_sling" ]; then
      local _sling_status _sling_db
      # ga-mfeip: for rig-native beads (pilot.sling_bead == bead id itself),
      # the "sling task" lives in $_db, not in GC_CITY. Detect self-referential
      # sling (rig-native dispatch) and look in the correct DB.
      if [ "$_sling" = "$_bid" ]; then
        _sling_db="$_db"
      else
        # Standard HQ sling task beads always live in GC_CITY.
        _sling_db="$GC_CITY"
      fi
      _sling_status=$(bd -C "$_sling_db" show "$_sling" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.status // "")' 2>/dev/null || echo "")
      if [ -n "$_sling_status" ] && [ "$_sling_status" != "closed" ] && [ "$_sling_status" != "done" ]; then
        warn "TTL: $_bid age=${_age}s > TTL but sling task $_sling is still '$_sling_status' (db=$_sling_db) — builder active, refusing to release."
        continue
      fi
    fi

    warn "Releasing stale pilot:dispatching claim on $_bid (age=${_age}s > TTL=${_ttl}s, stamp-based, db=$_db)."
    bd -C "$_db" label remove "$_bid" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
  done
}

TTL_NOW_EPOCH=$(date +%s)
TTL_SECS=$((CLAIM_TTL_MINUTES * 60))

_ttl_recover_db "$GC_CITY" "$TTL_NOW_EPOCH" "$TTL_SECS"

_ttl_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
  | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
while IFS= read -r _ttl_rig; do
  [ -z "$_ttl_rig" ] || [ ! -d "$_ttl_rig" ] && continue
  _ttl_recover_db "$_ttl_rig" "$TTL_NOW_EPOCH" "$TTL_SECS"
done <<< "$_ttl_rig_paths"

# ── Step 1: Per-lane capacity check ──────────────────────────────────────────
# Count in-flight beads per lane by reading their lane:big / lane:small labels.
# Beads without a lane label (manually dispatched) count as small (conservative).

IN_FLIGHT_RAW_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l "story:in-flight" \
  2>/dev/null || echo "[]")

IN_FLIGHT_RAW_TOTAL=$(echo "$IN_FLIGHT_RAW_JSON" | jq 'length' 2>/dev/null || echo "0")

# ── Stale in-flight slot correction (ga-rk5va constraint c) ───────────────────
# Drop PHANTOM occupants — beads whose last state-transition (updated_at) is older
# than PILOT_STUCK_INFLIGHT_HOURS — from the slot count. A hung builder (the
# 16h-stuck-session bug) leaves a bead reading in-flight while no work happens; if
# it kept consuming a slot the lane would starve forever (slots sit empty = the
# exact "sub-max throughput" complaint). FAIL-SAFE: a bead with a missing or
# unparseable updated_at is KEPT as a live occupant (never free a slot we cannot
# evaluate → never over-dispatch). The stale bead is NOT re-dispatched here — it
# keeps story:in-flight and stays out of every candidate query — so freeing its
# slot only lets OTHER pending work flow; it can never double-dispatch that story.
# ── Live-session roster (ga-e5yw2) ────────────────────────────────────────────
# Fetch the session roster ONCE per sweep; reused below for the dead-worker
# in-flight correction AND the gate-reviewer readout (one gc call, not two).
_SESSIONS_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo '{}')
# Newline-delimited identifiers of every session that is NOT closed. A sling
# bead's assignee is a session_name, but index every name field so any form of
# the id resolves. `unique` keeps the membership grep cheap.
_LIVE_SESSION_IDS=$(echo "$_SESSIONS_JSON" \
  | jq -r '[.sessions[]? | select(.closed != true)
           | (.session_name, .name, .alias, .id, .agent_name)]
          | map(select(. != null and . != "")) | unique | .[]' 2>/dev/null || echo "")
# Gate the dead-worker check OFF unless the roster is a readable, NON-EMPTY array.
# An unreadable or empty live set is almost always a failed/racy `session list`
# read, not a town with genuinely zero sessions — disabling the check then is the
# fail-safe (keep every occupant = the harmless pre-fix over-count, never an
# over-dispatch). A healthy town always has ≥1 live session.
_DEADWORKER_OK=1
echo "$_SESSIONS_JSON" | jq -e '.sessions | type=="array"' >/dev/null 2>&1 || _DEADWORKER_OK=0
[ -n "$_LIVE_SESSION_IDS" ] || _DEADWORKER_OK=0

# _session_is_live <identifier> — exit 0 iff <identifier> is a non-closed session.
_session_is_live() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$_LIVE_SESSION_IDS" | grep -Fxq -- "$1"
}

# _beadid_live_crew_owner <bead_id> [db] (ga-9yb5s) — echo the live, named-crew
# owner recorded on this bead and return 0; else return 1. A "named crew owner"
# is a non-empty assignee ON THE BEAD ITSELF that is NOT a dog-pool builder and
# whose session is live in the once-per-sweep roster. This is the reclaim-side
# twin of the ga-htjni dispatch guard's signal (b): a crew claims the STORY bead
# directly, whereas dogs/polecats claim the SLING task (tracked by the separate
# pilot.sling_bead live-worker guards). A crew builder is therefore INVISIBLE to
# the sling-assignee guards, so an active crew-built story reads "no live worker"
# and gets falsely reclaimed → re-dispatched → two builders on one story. This
# helper restores parity so the reclaim guards see a live crew as a live builder.
# FAIL-OPEN: an untrustworthy roster (_DEADWORKER_OK!=1), an empty/unreadable
# assignee, a dog-pool assignee, or a dead session → return 1 (assert NO owner),
# so a genuine orphan is never pinned and the existing recovery paths still fire.
_beadid_live_crew_owner() {
  local _bid="${1:-}" _db="${2:-$GC_CITY}" _asg
  [ -n "$_bid" ] || return 1
  [ "${_DEADWORKER_OK:-0}" = "1" ] || return 1
  _asg=$(bd -C "$_db" show "$_bid" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
  { [ -z "$_asg" ] || [ "$_asg" = "null" ]; } && return 1
  case "$_asg" in gastown.dog|gastown.dog-*) return 1 ;; esac
  _session_is_live "$_asg" || return 1
  printf '%s' "$_asg"
  return 0
}

# _target_session_state <identity> (gt-4st3n) — classify a crew identity's
# existing session from the once-per-sweep `_SESSIONS_JSON` roster, so the
# dispatcher can REUSE it instead of spawning a duplicate. Prints one line:
#   "active <ref>"  — a non-closed, active session matches → reuse, never spawn.
#   "asleep <ref>"  — a non-closed, asleep/drained session matches → wake & reuse.
#   "none"          — no matching non-closed session → spawning is correct.
# <ref> is the session ALIAS when present (e.g. "digo-wa"), else agent_name, else
# session_name, else id — whichever resolves the session for `gc session
# submit/wake`. A session matches the identity when ANY of its alias / agent_name
# / session_name / id equals <identity>. ACTIVE wins over ASLEEP if both exist.
# Fail-open: an unreadable/empty roster or any jq error → "none" (legacy spawn).
_target_session_state() {
  local _id="${1:-}"
  [ -n "$_id" ] || { printf 'none'; return 0; }
  echo "$_SESSIONS_JSON" | jq -e '.sessions | type=="array"' >/dev/null 2>&1 \
    || { printf 'none'; return 0; }
  echo "$_SESSIONS_JSON" | jq -r --arg id "$_id" '
      [ .sessions[]?
        | select(.closed != true)
        | select(.alias == $id or .agent_name == $id
                 or .session_name == $id or .id == $id) ] as $m
      | (if   ([ $m[] | select(.state == "active") ] | length) > 0 then "active"
         elif ($m | length) > 0                                    then "asleep"
         else "none" end) as $st
      | (if $st == "none" then ""
         else ( [ $m[] | select($st == "active" and .state == "active") ]
                + $m | .[0]
                | (.alias // .agent_name // .session_name // .id // "") )
         end) as $ref
      | if $st == "none" then "none" else ($st + " " + $ref) end
    ' 2>/dev/null || printf 'none'
}

# _inflight_drop_dead_workers — read a JSON array of in-flight beads on stdin and
# emit it with CONFIRMED dead-worker phantoms removed. A bead is a confirmed
# phantom iff it carries metadata pilot.sling_bead, that sling task has a
# non-empty assignee, and that assignee is NOT a live session. EVERY unresolved
# leg (no sling, no assignee, roster gated off) → KEEP — the same fail-safe the
# age filter uses: never free a slot we cannot positively evaluate. The dropped
# bead keeps story:in-flight and stays out of every candidate query, so freeing
# its slot can only admit OTHER pending work, never re-run the phantom. Falls
# back to the input on any jq error, so the worst case is the pre-fix count.
_inflight_drop_dead_workers() {
  local _arr _n _i _bead _sling _asg _kept
  _arr=$(cat)
  { [ "${PILOT_DEADWORKER_CHECK:-1}" = "1" ] && [ "${_DEADWORKER_OK:-0}" = "1" ]; } \
    || { printf '%s' "$_arr"; return 0; }
  _n=$(echo "$_arr" | jq 'length' 2>/dev/null || echo "0")
  [ "$_n" -gt 0 ] 2>/dev/null || { printf '%s' "$_arr"; return 0; }
  _kept=""
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _bead=$(echo "$_arr" | jq -c ".[$_i]" 2>/dev/null)
    _i=$((_i + 1))
    [ -n "$_bead" ] || continue
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    if [ -n "$_sling" ]; then
      _asg=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
      if [ -n "$_asg" ] && ! _session_is_live "$_asg"; then
        continue   # confirmed dead worker → free this slot
      fi
    fi
    _kept="${_kept}${_bead}"$'\n'
  done
  printf '%s' "$_kept" | jq -s '.' 2>/dev/null || printf '%s' "$_arr"
}

# ── Step 0c: never-started in-flight recovery (ga-v3z4z) ──────────────────────
# Release beads stuck story:in-flight + pilot:dispatched whose dispatch never
# produced a worker OR a branch (deferred at the session layer / spawn raced /
# worker died before pushing anything). Unlike the slot corrections above, which
# only stop a phantom from COUNTING, this RE-DISPATCHES it: strip the in-flight +
# dispatched labels (story:approved survives) so the next sweep picks it up. Runs
# unconditionally like the TTL recovery (Step 0) — recovering an abandoned
# dispatch is reconciliation, not a dispatch change, so it acts even under
# DRY_RUN (mirrors _ttl_recover_db). FAIL-SAFE: releases ONLY when every positive
# "real work happened" signal is absent.

# _beadid_has_branch <bead_id> — exit 0 iff some git ref (local or remote) in any
# town/rig repo names this bead. A surviving crew branch means work was pushed
# (then the worker died pre-/gate-done); re-dispatch would collide, so KEEP it.
# Fail-safe: no git / no resolved repos / undecidable → exit 0 (treat as "branch
# may exist" → KEEP). Test seam PILOT_TEST_BRANCH_BEADS (space-list of branched
# ids), consulted when DEFINED, keeps the selftest hermetic (no real git).
_beadid_has_branch() {
  local _bid="${1:-}" _repo
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_BRANCH_BEADS+x}" ]; then
    case " $PILOT_TEST_BRANCH_BEADS " in *" $_bid "*) return 0 ;; *) return 1 ;; esac
  fi
  command -v git >/dev/null 2>&1 || return 0
  [ -n "${_NS_BRANCH_REPOS:-}" ] || return 0
  while IFS= read -r _repo; do
    [ -n "$_repo" ] && [ -d "$_repo" ] || continue
    if git -C "$_repo" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null \
        | grep -qiF "$_bid"; then
      return 0
    fi
  done <<< "${_NS_BRANCH_REPOS:-}"
  return 1
}

# ── ga-htjni: ownership / in-flight collision guard helpers ───────────────────
# _ownership_guard_repos — newline list of repos a `crew/<owner>/<bead>` branch
# could live in (the shared town root + every registered rig path), de-duped and
# memoized for the whole sweep. Self-sufficient: it does NOT depend on the
# never-started block's _NS_BRANCH_REPOS (which is only set when that detector is
# enabled), so the guard works even with PILOT_NEVERSTARTED_MINUTES=0. Fail-open:
# any `gc rig list` error yields just the town root (or nothing) → the branch
# probe then simply finds no branch → no false block.
_OWNERSHIP_GUARD_REPOS=""
_OWNERSHIP_GUARD_REPOS_DONE=""
_ownership_guard_repos() {
  if [ -z "$_OWNERSHIP_GUARD_REPOS_DONE" ]; then
    _OWNERSHIP_GUARD_REPOS=$(
      { dirname "$GC_CITY"
        gc --city "$GC_CITY" rig list --json 2>/dev/null \
          | jq -r '.rigs[]?.path // empty' 2>/dev/null
      } | awk 'NF && !seen[$0]++'
    )
    _OWNERSHIP_GUARD_REPOS_DONE=1
  fi
  printf '%s' "$_OWNERSHIP_GUARD_REPOS"
}

# _beadid_has_crew_branch <bead_id> — exit 0 iff a branch named like
# `crew/<owner>/<bead-id>` exists in ANY town/rig repo, local OR remote-tracking,
# AND (best-effort) directly on the rig remote via a bounded `ls-remote`. This is
# the ga-htjni signal-(a): a pushed crew branch means a build is real/in-flight.
# It is STRICTER than _beadid_has_branch (which matches the id anywhere in any
# ref) — here we require the `crew/.../<bead>` shape so a stray tag/note never
# false-fires; the trailing `/<bead>` or exact `<bead>` end-anchor avoids matching
# a longer id that merely contains this one as a prefix.
#
# Test seam: PILOT_TEST_CREW_BRANCH_BEADS (space-list), consulted when DEFINED,
# keeps the selftest hermetic (no real git / network). When undefined we probe
# real git read-only. FAIL-OPEN: no git OR no resolvable repos → return 1 (NOT
# "assume branch") so the guard never blocks on an unprobable environment; the
# distinct dead-worker/never-started reclaim paths still own true-orphan recovery.
_beadid_has_crew_branch() {
  local _bid="${1:-}" _repo
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_CREW_BRANCH_BEADS+x}" ]; then
    case " $PILOT_TEST_CREW_BRANCH_BEADS " in *" $_bid "*) return 0 ;; *) return 1 ;; esac
  fi
  command -v git >/dev/null 2>&1 || return 1
  local _repos _re
  _repos=$(_ownership_guard_repos)
  [ -n "$_repos" ] || return 1
  # crew/<anything>/<bead> at a ref tail, OR a bare crew/<bead> (defensive).
  _re="crew/([^/]+/)?${_bid}\$"
  while IFS= read -r _repo; do
    [ -n "$_repo" ] && [ -d "$_repo" ] || continue
    # 1. Already-fetched local + remote-tracking refs (cheap, offline).
    if git -C "$_repo" for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | grep -qiE "$_re"; then
      return 0
    fi
    # 2. Best-effort authoritative remote probe (bounded; the live origin/crew/*
    #    branch ga-htjni hit may not be fetched locally). A timeout / offline
    #    remote is NOT evidence of a branch → fall through (fail-open), never block.
    if git -C "$_repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
       || git -C "$_repo" remote 2>/dev/null | grep -q .; then
      if timeout 8 git -C "$_repo" ls-remote --heads origin "crew/*/${_bid}" "crew/${_bid}" 2>/dev/null \
          | grep -qiE "refs/heads/${_re}"; then
        return 0
      fi
    fi
  done <<< "$_repos"
  return 1
}

# _ownership_guard_should_refuse <bead_id> <bead_json> <bead_city> — emit a short
# REASON to stdout and return 0 (REFUSE this dispatch) iff signal (a) or (b) holds;
# return 1 (allow) otherwise. Pure read; the caller logs + releases the claim.
#   (a) crew branch exists for <bead_id> (strongest)            → "branch:<...>"
#   (b) live assignee: a non-empty, NON-pilot crew assignee whose session is live
#       in the once-per-sweep roster                            → "owner:<crew>"
# Re-reads the bead's CURRENT assignee (race-safe: the candidate query required an
# EMPTY assignee, but a competing claim could have set one between snapshot and
# now — exactly the ga-htjni double-dispatch window). FAIL-OPEN: an unresolvable
# assignee, an untrustworthy roster (_DEADWORKER_OK!=1, gated like ga-e5yw2), or
# any jq error → no (b) block. (a) is independent and self-fail-open.
_ownership_guard_should_refuse() {
  local _bid="${1:-}" _json="${2:-}" _city="${3:-$GC_CITY}"
  [ -n "$_bid" ] || return 1

  # (a) crew branch — strongest, evaluated first and standalone.
  if _beadid_has_crew_branch "$_bid"; then
    printf 'branch:crew/*/%s' "$_bid"
    return 0
  fi

  # (b) live named-crew owner. Re-read CURRENT assignee from the store (race-safe);
  # fall back to the snapshot's assignee only if the live read is empty/unreadable.
  local _asg
  _asg=$(bd -C "$_city" show "$_bid" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
  if [ -z "$_asg" ] || [ "$_asg" = "null" ]; then
    _asg=$(printf '%s' "$_json" | jq -r '(.assignee // "")' 2>/dev/null || echo "")
  fi
  [ -z "$_asg" ] || [ "$_asg" = "null" ] && return 1   # unowned → allow.
  # An assignee equal to the dispatcher self-bead / a dog pool is not a "named
  # crew owner" in the ga-htjni sense; only block on a real crew identity.
  case "$_asg" in gastown.dog|gastown.dog-*) return 1 ;; esac
  # Roster must be trustworthy to judge liveness; otherwise fail-open (allow), so
  # a racy `session list` read can never deadlock a legitimately-orphaned bead.
  [ "${_DEADWORKER_OK:-0}" = "1" ] || return 1
  if _session_is_live "$_asg"; then
    printf 'owner:%s' "$_asg"
    return 0
  fi
  # Owner set but session DEAD and (a) already proved no branch → genuine orphan:
  # do NOT block — let the upstream reclaim paths (ga-e5yw2 / ga-v3z4z) recover it.
  return 1
}

# _neverstarted_recover_db <db_path> <now_epoch> — scan one DB for never-started
# in-flight beads and release them. Decision rules (ALL must hold to release):
#   - has story:in-flight AND pilot:dispatched (query selects both)
#   - NO gate:* label (any gate marker = it reached the gate = it was built)
#   - pilot.dispatched_at present AND age > threshold (missing stamp → stamp NOW,
#       never release on first sight — the ga-2azzj Defect-A discipline)
#   - NO live worker: a recorded pilot.sling_bead whose assignee is a live session
#       means a build is in flight (just slow to push) → KEEP. Roster untrustworthy
#       (_DEADWORKER_OK!=1) → KEEP (cannot prove the worker dead).
#   - NO branch in any repo (_beadid_has_branch).
_neverstarted_recover_db() {
  local _db="$1" _now="$2"
  local _thresh=$(( PILOT_NEVERSTARTED_MINUTES * 60 ))
  local _json _count
  _json=$(bd -C "$_db" list --json --all \
    -l "story:in-flight" \
    -l "pilot:dispatched" \
    2>/dev/null || echo "[]")
  _count=$(echo "$_json" | jq 'length' 2>/dev/null || echo "0")
  [ "${_count:-0}" -le "0" ] 2>/dev/null && return 0

  echo "$_json" | jq -c '.[]' | while IFS= read -r _bead; do
    local _bid _labels _stamp _age _sling _asg _crew_owner
    _bid=$(echo "$_bead" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$_bid" ] && continue
    _labels=$(echo "$_bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")

    # gate-marker guard — any gate:* label (comma-framed so "investigate:" can't
    # false-match) means the bead was built and reached the gate. KEEP.
    case ",$_labels," in *,gate:*) continue ;; esac

    # stamp/age guard (Defect-A discipline) — never updated_at, never first-sight.
    _stamp=$(echo "$_bead" | jq -r '.metadata["pilot.dispatched_at"] // ""' 2>/dev/null || echo "")
    if [ -z "$_stamp" ] || ! [ "$_stamp" -ge 0 ] 2>/dev/null; then
      warn "NEVERSTARTED: $_bid is in-flight+dispatched but has no pilot.dispatched_at stamp (legacy) — stamping now, NOT releasing (Defect-A guard, ga-v3z4z)."
      bd -C "$_db" update "$_bid" --set-metadata "pilot.dispatched_at=$_now" -q 2>/dev/null || true
      continue
    fi
    _age=$(( _now - _stamp ))
    if [ "$_age" -le "$_thresh" ]; then
      continue   # too fresh — give the dispatch time to materialize a worker/branch.
    fi

    # live-worker guard — a sling whose assignee is a live session = active build.
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    if [ -n "$_sling" ]; then
      if [ "${_DEADWORKER_OK:-0}" != "1" ]; then
        continue   # roster untrustworthy → cannot prove worker dead → KEEP.
      fi
      _asg=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
      if [ -n "$_asg" ] && _session_is_live "$_asg"; then
        continue   # worker alive → not never-started.
      fi
    fi

    # live-crew-owner guard (ga-9yb5s) — a crew claims the STORY bead directly, so
    # it is invisible to the sling-assignee guard above. If the bead's own current
    # assignee is a live named crew, an active crew builder owns it → KEEP (parity
    # with the ga-htjni dispatch guard). FAIL-OPEN: untrustworthy roster / no owner
    # / dead session → no keep, so genuine orphans still recover.
    _crew_owner=$(_beadid_live_crew_owner "$_bid" "$_db") && {
      warn "NEVERSTARTED: $_bid is owned by live crew '$_crew_owner' (story.assignee) — active crew builder, refusing to release (ga-9yb5s parity with ga-htjni)."
      continue
    }

    # branch guard — a surviving crew branch means real work landed. KEEP.
    if _beadid_has_branch "$_bid"; then
      continue
    fi

    # Aged past threshold, no gate marker, no live worker, no branch → genuinely
    # never-started limbo. Release so the next sweep re-dispatches it.
    warn "NEVERSTARTED: releasing never-started in-flight bead $_bid (age=${_age}s > ${_thresh}s, no live worker, no branch, no gate marker, db=$_db) — back to story:approved for re-dispatch (ga-v3z4z)."
    bd -C "$_db" label  remove "$_bid" "story:in-flight"   -q 2>/dev/null || true
    bd -C "$_db" label  remove "$_bid" "pilot:dispatched"  -q 2>/dev/null || true
    bd -C "$_db" label  remove "$_bid" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatched_at"  -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.sling_bead"     -q 2>/dev/null || true
  done
}

if [ "${PILOT_NEVERSTARTED_MINUTES:-15}" != "0" ]; then
  _NS_NOW_EPOCH=$(date +%s)
  # Repos a crew branch could live in: the shared town root (HQ ga-* branches) +
  # every rig repo (wa-*/ps-*/lx-* crew branches). Resolved once per sweep.
  _NS_BRANCH_REPOS=$(
    { dirname "$GC_CITY"
      gc --city "$GC_CITY" rig list --json 2>/dev/null \
        | jq -r '.rigs[]?.path // empty' 2>/dev/null
    } | awk 'NF && !seen[$0]++'
  )
  _neverstarted_recover_db "$GC_CITY" "$_NS_NOW_EPOCH"
  _ns_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
  while IFS= read -r _ns_rig; do
    [ -z "$_ns_rig" ] || [ ! -d "$_ns_rig" ] && continue
    _neverstarted_recover_db "$_ns_rig" "$_NS_NOW_EPOCH"
  done <<< "$_ns_rig_paths"
fi

_NOW_EPOCH=$(date +%s)
_STUCK_CUTOFF=$(( _NOW_EPOCH - PILOT_STUCK_INFLIGHT_HOURS * 3600 ))
# Stage 1 — drop age-stale occupants (ga-rk5va constraint c).
IN_FLIGHT_AGE_JSON=$(echo "$IN_FLIGHT_RAW_JSON" | jq --argjson cutoff "$_STUCK_CUTOFF" '
  [ .[]
    | ( ((.updated_at // "") | if . == "" then null else (try fromdateiso8601 catch null) end) ) as $e
    | select($e == null or $e > $cutoff) ]' 2>/dev/null || echo "$IN_FLIGHT_RAW_JSON")
# Defensive: if the filter produced nothing usable, fall back to the raw set.
[ -z "$IN_FLIGHT_AGE_JSON" ] && IN_FLIGHT_AGE_JSON="$IN_FLIGHT_RAW_JSON"
_AGE_TOTAL=$(echo "$IN_FLIGHT_AGE_JSON" | jq 'length' 2>/dev/null || echo "0")
STALE_AGE=$(( IN_FLIGHT_RAW_TOTAL - _AGE_TOTAL ))
[ "$STALE_AGE" -lt 0 ] 2>/dev/null && STALE_AGE=0

# Stage 2 — drop dead-worker phantoms (ga-e5yw2).
IN_FLIGHT_JSON=$(echo "$IN_FLIGHT_AGE_JSON" | _inflight_drop_dead_workers)
[ -z "$IN_FLIGHT_JSON" ] && IN_FLIGHT_JSON="$IN_FLIGHT_AGE_JSON"

IN_FLIGHT_TOTAL=$(echo "$IN_FLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")
DEAD_WORKER=$(( _AGE_TOTAL - IN_FLIGHT_TOTAL ))
[ "$DEAD_WORKER" -lt 0 ] 2>/dev/null && DEAD_WORKER=0
STALE_INFLIGHT=$(( IN_FLIGHT_RAW_TOTAL - IN_FLIGHT_TOTAL ))
[ "$STALE_INFLIGHT" -lt 0 ] 2>/dev/null && STALE_INFLIGHT=0

if [ "$STALE_AGE" -gt 0 ] 2>/dev/null; then
  warn "Stale in-flight: ${STALE_AGE} bead(s) untouched > ${PILOT_STUCK_INFLIGHT_HOURS}h (hung builder?) — NOT counted as live occupants, freeing their slot(s) for pending work (ga-rk5va constraint c). Stale ids: $(echo "$IN_FLIGHT_RAW_JSON" | jq -r --argjson cutoff "$_STUCK_CUTOFF" '[.[] | ((.updated_at // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $e | select($e != null and $e <= $cutoff) | .id] | join(",")' 2>/dev/null || echo "?")"
fi

if [ "$DEAD_WORKER" -gt 0 ] 2>/dev/null; then
  warn "Dead-worker in-flight: ${DEAD_WORKER} bead(s) whose builder session is gone — NOT counted as live occupants, freeing their slot(s) for pending work (ga-e5yw2). Dead ids: $(jq -rn --argjson a "$IN_FLIGHT_AGE_JSON" --argjson b "$IN_FLIGHT_JSON" '(($a|map(.id)) - ($b|map(.id))) | join(",")' 2>/dev/null || echo "?")"
fi

IN_FLIGHT_BIG=$(echo "$IN_FLIGHT_JSON" | jq '[.[] | select((.labels // []) | contains(["lane:big"]))] | length' 2>/dev/null || echo "0")
IN_FLIGHT_SMALL=$((IN_FLIGHT_TOTAL - IN_FLIGHT_BIG))

log "In-flight: live=$IN_FLIGHT_TOTAL (raw=$IN_FLIGHT_RAW_TOTAL stale=$STALE_INFLIGHT age=$STALE_AGE dead=$DEAD_WORKER)  small=$IN_FLIGHT_SMALL/${MAX_SMALL}  big=$IN_FLIGHT_BIG/${MAX_BIG}"

# ── Per-builder busy set (ga-mtlm6) ───────────────────────────────────────────
# For a POOLED rig (multiple interchangeable crew), a builder is BUSY iff it
# currently holds a LIVE in-flight task — so it must be excluded from this sweep's
# selection (a second task to a busy single-identity crew is the wa-1eos branch-
# corruption hazard). Resolve each live in-flight bead's sling-task assignee (the
# builder identity the crew recorded via `bd assign`) from the SAME, already
# dead-worker-filtered IN_FLIGHT_JSON the slot math trusts. Best-effort + fail-
# open per leg: an in-flight bead with no sling task or no resolvable assignee
# simply omits that builder (the USED-this-sweep set + global lane cap still bound
# dispatch), mirroring the dead-worker check's never-over-free philosophy.
_compute_busy_builders() {
  local _n _i _bead _sling _asg _forms _f
  _n=$(echo "$IN_FLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")
  [ "${_n:-0}" -gt 0 ] 2>/dev/null || return 0
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _bead=$(echo "$IN_FLIGHT_JSON" | jq -c ".[$_i]" 2>/dev/null)
    _i=$((_i + 1))
    [ -n "$_bead" ] || continue
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    [ -n "$_sling" ] || continue
    _asg=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
    [ -n "$_asg" ] || continue
    # Normalize to ALL of that session's identifiers (session_name/name/alias/id/
    # agent_name). A crew claims its sling task with its GC_SESSION_NAME (verified
    # live: 'digo-wa-gawispcze4o4'), but the pool lists the alias ('digo-wa'); add
    # every form so pick_pool_builder's alias match still excludes the busy crew.
    # Fall back to the raw assignee when the roster can't resolve it (still
    # excludes by that exact string — never worse than the un-normalized set).
    _forms=$(echo "$_SESSIONS_JSON" | jq -r --arg a "$_asg" '
      [ .sessions[]?
        | select((.session_name==$a) or (.name==$a) or (.alias==$a) or (.id==$a) or (.agent_name==$a))
        | (.session_name,.name,.alias,.id,.agent_name) ]
      | map(select(. != null and . != "")) | unique | .[]' 2>/dev/null)
    [ -n "$_forms" ] || _forms="$_asg"
    for _f in $_forms; do
      case " $PILOT_BUSY_BUILDERS " in
        *" $_f "*) : ;;
        *) PILOT_BUSY_BUILDERS="${PILOT_BUSY_BUILDERS:+$PILOT_BUSY_BUILDERS }$_f" ;;
      esac
    done
  done
}
_compute_busy_builders
[ -n "$PILOT_BUSY_BUILDERS" ] && log "Busy builders (live in-flight): $PILOT_BUSY_BUILDERS"

SMALL_SLOTS=$((MAX_SMALL - IN_FLIGHT_SMALL))
BIG_SLOTS=$((MAX_BIG - IN_FLIGHT_BIG))

[ "$SMALL_SLOTS" -lt "0" ] && SMALL_SLOTS=0
[ "$BIG_SLOTS"   -lt "0" ] && BIG_SLOTS=0

log "Available slots: small=$SMALL_SLOTS  big=$BIG_SLOTS"

# ── ga-8c1 AC5: gate reviewer slot readout (observability) ───────────────────
# Surface free gate-reviewer slots every sweep so the log shows the WHOLE
# pipeline's capacity (builders + reviewers), not just the builder lanes. Read
# only — counts live gate-reviewer sessions exactly as quality-gate-dispatcher
# does (.template=="gate-reviewer"). Reuses the roster fetched once above for the
# dead-worker correction (ga-e5yw2) — no second `session list` call. Guarded for
# set -euo pipefail.
REVIEWERS_ACTIVE=$(echo "$_SESSIONS_JSON" \
  | jq '[.sessions[]? | select(.template=="gate-reviewer")] | length' 2>/dev/null || echo "0")
[ -z "$REVIEWERS_ACTIVE" ] && REVIEWERS_ACTIVE=0
REVIEWER_SLOTS=$((MAX_REVIEWERS - REVIEWERS_ACTIVE))
[ "$REVIEWER_SLOTS" -lt "0" ] && REVIEWER_SLOTS=0
log "Gate reviewers: active=${REVIEWERS_ACTIVE}/${MAX_REVIEWERS}  free=${REVIEWER_SLOTS}"

if [ "$SMALL_SLOTS" -eq "0" ] && [ "$BIG_SLOTS" -eq "0" ]; then
  # ga-8c1 AC5: even when backing off, surface the dispatch-queue depth so every
  # sweep's log reports what's waiting (cheap count — no full tier scan).
  WAITING_APPROVED=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    --exclude-label "story:in-flight" \
    --exclude-label "story:done" \
    --exclude-label "pilot:dispatched" \
    -n 0 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
  log "Dispatch queue: ${WAITING_APPROVED} story:approved waiting (HQ; both lanes full — none can dispatch this sweep)."
  log "Both lanes full (small=${IN_FLIGHT_SMALL}/${MAX_SMALL}, big=${IN_FLIGHT_BIG}/${MAX_BIG}). Pilot backing off."
  exit 0
fi

# ── Step 2: Tier 1 — Find open bugs + tech-debt beads in HQ DB ───────────────
# Tier 1 = type:bug OR label:tech-debt, NOT in-flight/done/dispatching, no assignee.
# Bugs do NOT require story:approved — they are always dispatchable when open.
# tech-debt label: use "tech-debt" as canonical label for debt items.
#
# Helper: filter out self-bead + already-assigned from a JSON array.
#
# gt-14nya: ALSO drop split-epic shells. A type=epic (or story:epic-split-labeled)
# bead is a non-buildable container — dispatching it produces an empty diff that
# gate FAILs / the dog refuses, and the Pilot then re-dispatched it every sweep
# (ga-z0icp was slung 5×). This ports the SAME guard the Mayor's startup probe
# uses ((issue_type // type) != "epic") into the candidate path. Every candidate
# array (Tier 1/2, HQ + rig) flows through this helper, so one guard here covers
# all paths and any future query. The split epic's CHILDREN are ordinary tasks
# with their own type — they remain dispatchable, exactly as the AC requires.
#
# ga-w7wvm: ALSO drop beads carrying a PRE-APPROVAL (or terminal-cancelled)
# story lifecycle label. The story lifecycle (story-bead-convention.md) runs
# story:unrefined → story:refinement-in-progress → story:approved → story:in-flight
# → story:done, with story:cancelled as a terminal off-ramp. Only story:approved
# is dispatchable. The Tier 2 feature queries already require `-l story:approved`,
# but that is a single source-gate: a bead mid-transition (or mislabeled) can
# carry BOTH story:approved AND a pre-approval label, and would then leak through
# the query. This guard is the defense-in-depth backstop — it disqualifies any
# candidate still wearing a not-yet-approved lifecycle label, at the one chokepoint
# every tier flows through, so unrefined/in-triage stories are NEVER dispatched
# (epic ga-z0icp triage funnel; "story:triage" in the AC is the conceptual
# pre-approval umbrella — the concrete labels are unrefined/refinement-in-progress,
# with story:triage recognized too for forward-compat).
#
# FAIL-OPEN, by design: the guard is a BLOCKLIST of disqualifying labels, not an
# allowlist requiring story:approved. So (a) bugs/chores/tasks — which never carry
# story:* lifecycle labels and bypass the refino funnel entirely — pass through
# untouched; and (b) a feature with NO lifecycle label at all is not dropped here
# (it simply fails the Tier 2 `-l story:approved` source-query and so is never
# dispatched as a feature). Approved stories are never blocked.

BUGS_JSON=$(bd -C "$GC_CITY" list --json \
  -t bug \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "gate:passed" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  --exclude-label "needs:engine-window" \
  --exclude-label "pilot:dispatched" \
  --exclude-type epic \
  -n 0 \
  2>/dev/null || echo "[]")
BUGS_JSON=$(echo "$BUGS_JSON" | _filter_candidates)

DEBT_JSON=$(bd -C "$GC_CITY" list --json \
  -l "tech-debt" \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "gate:passed" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  --exclude-label "needs:engine-window" \
  --exclude-label "pilot:dispatched" \
  --exclude-type epic \
  -n 0 \
  2>/dev/null || echo "[]")
DEBT_JSON=$(echo "$DEBT_JSON" | _filter_candidates)

# Merge bugs + debt, deduplicate by id
TIER1_JSON=$(echo "$BUGS_JSON $DEBT_JSON" \
  | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

# Drop candidates blocked by unresolved deps (ga-5ew). Filtering BEFORE the count
# means an all-blocked Tier 1 correctly falls through to Tier 2 features.
TIER1_JSON=$(echo "$TIER1_JSON" | _filter_unblocked "$GC_CITY")
# Also drop candidates with an open EXPLICIT dep (ga-do8jj). Same fall-through
# semantics: an all-held Tier 1 correctly cascades to Tier 2.
TIER1_JSON=$(echo "$TIER1_JSON" | _filter_explicit_deps "$GC_CITY")

TIER1_COUNT=$(echo "$TIER1_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Bugs + tech-debt: $TIER1_COUNT open candidate(s) in HQ DB"

ALL_CANDIDATES_JSON="[]"
# ALL_CANDIDATES_TIER is retained ONLY as a hint for downstream log lines; the
# actual per-bead dispatch template is derived from each bead's own type (see
# _bead_tier / the dispatch loop). With a merged pool the sweep is no longer a
# single homogeneous tier, so this is informational only ("mixed" when both
# types are present).
ALL_CANDIDATES_TIER=""

# ── Step 2b: story:approved feature stories — ALWAYS queried (wa-tm2a) ────────
# Dispatchable = story:approved AND NOT story:in-flight AND NOT story:done
#                AND NOT gate:passed (merged, delivery in progress — ga-3h8l)
#                AND NOT pilot:dispatching (claim in progress)
#
# wa-tm2a: stories are NO LONGER suppressed while bugs exist. Bugs/tech-debt and
# stories are merged into ONE pool and ordered by priority>type>created_at>id, so
# a P0 story outranks a P3 bug while a same-priority bug still beats a story.
TIER2_JSON=$(bd -C "$GC_CITY" list --json \
  -l "story:approved" \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "gate:passed" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  --exclude-label "needs:engine-window" \
  --exclude-label "pilot:dispatched" \
  --exclude-type epic \
  -n 0 \
  2>/dev/null || echo "[]")
TIER2_JSON=$(echo "$TIER2_JSON" | _filter_candidates)
# Drop features blocked by unresolved deps (ga-5ew) or an open explicit dep (ga-do8jj).
TIER2_JSON=$(echo "$TIER2_JSON" | _filter_unblocked "$GC_CITY")
TIER2_JSON=$(echo "$TIER2_JSON" | _filter_explicit_deps "$GC_CITY")

TIER2_COUNT=$(echo "$TIER2_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Story:approved features: $TIER2_COUNT candidate(s) in HQ DB"

# ── Step 2a-ctx: ctx:ready chore/task/debt beads — ON by default ──────────────
# Final auto-dispatch phase (PILOT_CTX_READY_QUERIES). A context-check daemon now
# labels bug/chore/task/debt beads ctx:ready (context-complete) or ctx:thin
# (under-specified). The Pilot's legacy queries cover type:bug + tech-debt +
# story:approved features but NEVER chore/task — the design's known gap that left
# ~28 ready chore/task beads idle forever. This query closes it: chore/task/debt
# beads that carry `-l ctx:ready` (and NO story:* label, so this is strictly the
# non-funnel work) become candidates, merged into the SAME pool below and run
# through the IDENTICAL filter chain. ctx:thin is excluded explicitly (defense-in-
# depth) so an under-spec'd bead never dispatches even if it somehow also wore
# ctx:ready. tech-debt overlap with Tier-1 is harmless: the union dedups by id, so a
# ctx:ready tech-debt bead already in Tier-1 is not double-listed.
#
# GATED ON (PILOT_CTX_READY_QUERIES default 1) → these candidates flow every sweep.
# Set the env to 0 (Mayor, in the plist) to disable if the ctx: labels regress. The
# new candidates are bound by the SAME Step-3 lane caps + the ga-d0hz3 cross-stage
# yield as every other tier, so turning this on cannot flood the Gate or the crews:
# a 28-deep backlog drains one-per-free-slot, never faster. The same lifecycle/
# in-flight/engine-window/epic exclusions as every other query are applied so a
# ctx:ready bead that is already in-flight, dispatched, or human-gated is skipped.
CTXREADY_JSON="[]"
CTXREADY_COUNT="0"
# _filter_exec_manual — drop any bead labelled exec:manual from a JSON array.
# exec:manual means the task requires physical device interaction, gov-portal
# CAPTCHAs, or human credentials that a crew cannot supply autonomously (ga-mfeip
# AC3). Crews SKIP such beads; dispatching them is wasted capacity + a stuck
# pilot:dispatching claim. exec:auto and unlabelled beads pass through unchanged
# (conservative default: absent exec: label → dispatch is fine, never suppress).
# Pure read (no side effects); fail-open → pass through unchanged on jq error.
_filter_exec_manual() {
  jq '[ .[] | select(((.labels // []) | index("exec:manual")) == null) ]' \
    2>/dev/null || cat
}
# _filter_dispatch_gates — ga-mfeip dispatch quality gates (a)+(b)+(c). Drop ctx:ready
# candidates that are not safely auto-buildable by a crew:
#   (a) BLOCKED / TERMINAL STATUS. A bead whose `status` FIELD is "blocked" (a crew or
#       triage gated it — e.g. design-first awaiting Athos: wa-tozk F11, wa-1my1 F2) or
#       "closed" must NEVER dispatch. `bd list -l ctx:ready` does NOT filter the status
#       field (only labels), so a status=blocked bead leaks past the label exclusions —
#       this jq check is the belt+suspenders that makes a crew/triage lock HOLD.
#       ALSO drops beads whose title/description carries a "design-first" marker (a
#       deliberate "spec needs Athos's approval before coding" gate: wa-1my1, wa-tozk) —
#       narrow literal phrase, not ambiguous-noun matching, so ~zero false positives.
#   (b) NO ACTIONABLE SPEC. A refined story carries story.criterios; a context-ready
#       task carries its spec in the description. A bead with empty story.criterios
#       AND a description below the spec floor (PILOT_CTX_MIN_SPEC_CHARS, default 20)
#       is "not refined → can't build" (the wa-tozk empty-AC regression). The floor is
#       deliberately low: real WA tasks run 180–2200 chars, so only one-liner/stub
#       beads are dropped; it never false-drops a genuine task. Raise it in the plist
#       to enforce a stricter spec minimum.
#   (c) AN UNSATISFIED PRECONDITION LABEL. A `blocked-on:*` or `depends-on:*` label is
#       a free-text precondition the bd dep-graph can't see (e.g. blocked-on:ata-dedicada,
#       depends-on:contact-sync). Such a bead is not ready regardless of ctx:ready.
# Pure read, no side effects; fail-open → pass through unchanged on any jq error.
_filter_dispatch_gates() {
  jq --argjson floor "${PILOT_CTX_MIN_SPEC_CHARS:-20}" '[ .[] | select(
      (((.status) // "open") as $s | ($s != "blocked" and $s != "closed"))
      and ( (((.metadata["story.criterios"]) // "") | test("\\S"))
        or (((.description) // "") | length) >= $floor )
      and (((.labels // []) | map(select(test("^(blocked-on|depends-on):"))) | length) == 0)
      and ((((.title) // "") + " " + ((.description) // "")) | ascii_downcase | test("design[ -]?first") | not)
    )]' 2>/dev/null || cat
}
if [ "$PILOT_CTX_READY_QUERIES" = "1" ]; then
  CTXREADY_RAW=$(bd -C "$GC_CITY" list --json \
    -l "ctx:ready" \
    --exclude-label "ctx:thin" \
    --exclude-label "exec:manual" \
    --exclude-label "story:blocked" \
    --exclude-label "type:future" \
    --exclude-label "needs-human" \
    --exclude-label "needs-human-decision" \
    --exclude-label "cost-decision" \
    --exclude-label "prod-experiment" \
    --exclude-label "ban-risk" \
    --exclude-label "phone-proxy" \
    --exclude-label "story:approved" \
    --exclude-label "story:unrefined" \
    --exclude-label "story:refinement-in-progress" \
    --exclude-label "story:triage" \
    --exclude-label "story:in-flight" \
    --exclude-label "story:done" \
    --exclude-label "story:cancelled" \
    --exclude-label "gate:passed" \
    --exclude-label "pilot:dispatching" \
    --exclude-label "gate:needs-human" \
    --exclude-label "needs:engine-window" \
    --exclude-label "pilot:dispatched" \
    --exclude-type epic \
    -n 0 \
    2>/dev/null || echo "[]")
  # Restrict to the chore/task/debt types this phase covers (a ctx:ready bug is
  # already a Tier-1 candidate; a ctx:ready feature without story:approved is NOT
  # dispatchable — only the funnel approves features). tech-debt is kept (label or
  # type) so context-ready debt the funnel skips can dispatch.
  CTXREADY_JSON=$(echo "$CTXREADY_RAW" | jq '
      [ .[] | select(
          ((.issue_type // .type // "") | ascii_downcase) as $t
          | ($t == "chore" or $t == "task" or $t == "debt" or $t == "tech-debt")
            or (((.labels // []) | index("tech-debt")) != null)
        ) ]' 2>/dev/null || echo "[]")
  # SAME filter chain as Tier-1/Tier-2 (empty-veto, lifecycle blocklist, epic guard,
  # self-exclusion, unresolved deps, explicit deps). exec:manual safety belt applied
  # even though the query already excludes that label (defense-in-depth, fail-open).
  CTXREADY_JSON=$(echo "$CTXREADY_JSON" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates)
  CTXREADY_JSON=$(echo "$CTXREADY_JSON" | _filter_unblocked "$GC_CITY")
  CTXREADY_JSON=$(echo "$CTXREADY_JSON" | _filter_explicit_deps "$GC_CITY")
  CTXREADY_COUNT=$(echo "$CTXREADY_JSON" | jq 'length' 2>/dev/null || echo "0")
  log "ctx:ready chore/task/debt: $CTXREADY_COUNT candidate(s) in HQ DB (PILOT_CTX_READY_QUERIES=1)."
fi

# ── Step 2b-ctx-rig: ctx:ready scan for rig DBs (ga-mfeip) ───────────────────
# The HQ ctx:ready query above NEVER sees rig-native beads (wa-*, ps-* etc.)
# because those live in each rig's own Dolt DB, not in HQ. This step runs the
# IDENTICAL ctx:ready query against every non-HQ rig DB, merging results into
# CTXREADY_JSON alongside the HQ candidates.
#
# Dispatch path for rig-native beads is different: `gc sling <crew> <wa-bead>`
# is REFUSED by the engine ("cross-store routes wedge pools — tr-6s7yx"). The
# dispatch_one function detects STORY_BEAD_CITY != GC_CITY and uses the
# rig-native path: `bd -C <rig-db> update --assignee <crew>` + crew nudge.
#
# Gated independently via PILOT_CTX_READY_RIG_QUERIES (defaults to inheriting
# PILOT_CTX_READY_QUERIES). Set to 0 in the plist to disable rig scanning
# without affecting HQ ctx:ready dispatch. Fail-open: any rig-DB error → skip
# that rig, never break the sweep. exec:manual beads are excluded (GA-MFEIP AC3).
CTXREADY_RIG_JSON="[]"
CTXREADY_RIG_COUNT="0"
if [ "$PILOT_CTX_READY_RIG_QUERIES" = "1" ]; then
  _rig_ctx_rows=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | "\(.name)\t\(.path)"' 2>/dev/null || echo "")
  while IFS=$'\t' read -r _rig_ctx_name _rig_ctx_path; do
    [ -z "$_rig_ctx_path" ] || [ ! -d "$_rig_ctx_path" ] && continue
    # ga-mfeip scope gate: only scan rigs in PILOT_CTX_READY_RIGS (default WA-only).
    case " $PILOT_CTX_READY_RIGS " in
      *" all "*) : ;;
      *" $_rig_ctx_name "*) : ;;
      *) continue ;;
    esac
    _rig_ctx_raw=$(bd -C "$_rig_ctx_path" list --json \
      -l "ctx:ready" \
      --exclude-label "ctx:thin" \
      --exclude-label "exec:manual" \
      --exclude-label "story:blocked" \
      --exclude-label "type:future" \
      --exclude-label "needs-human" \
      --exclude-label "needs-human-decision" \
      --exclude-label "cost-decision" \
      --exclude-label "prod-experiment" \
      --exclude-label "ban-risk" \
      --exclude-label "phone-proxy" \
      --exclude-label "story:approved" \
      --exclude-label "story:unrefined" \
      --exclude-label "story:refinement-in-progress" \
      --exclude-label "story:triage" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "story:cancelled" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      --exclude-type epic \
      -n 0 \
      2>/dev/null || echo "[]")
    # Same type restriction: chore/task/debt only (not features, not bugs).
    _rig_ctx_typed=$(echo "$_rig_ctx_raw" | jq '
        [ .[] | select(
            ((.issue_type // .type // "") | ascii_downcase) as $t
            | ($t == "chore" or $t == "task" or $t == "debt" or $t == "tech-debt")
              or (((.labels // []) | index("tech-debt")) != null)
          ) ]' 2>/dev/null || echo "[]")
    # Same filter chain + exec:manual safety belt + ga-mfeip dispatch quality gates.
    _rig_ctx_typed=$(echo "$_rig_ctx_typed" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates)
    _rig_ctx_typed=$(echo "$_rig_ctx_typed" | _filter_unblocked "$_rig_ctx_path")
    _rig_ctx_typed=$(echo "$_rig_ctx_typed" | _filter_explicit_deps "$_rig_ctx_path")
    _rig_ctx_n=$(echo "$_rig_ctx_typed" | jq 'length' 2>/dev/null || echo "0")
    if [ "${_rig_ctx_n:-0}" -gt 0 ] 2>/dev/null; then
      log "ctx:ready rig DB $_rig_ctx_path: $_rig_ctx_n candidate(s) (ga-mfeip, PILOT_CTX_READY_RIG_QUERIES=1)."
      CTXREADY_RIG_JSON=$(echo "$CTXREADY_RIG_JSON $_rig_ctx_typed" \
        | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "$CTXREADY_RIG_JSON")
    fi
  done <<< "$_rig_ctx_rows"
  CTXREADY_RIG_COUNT=$(echo "$CTXREADY_RIG_JSON" | jq 'length' 2>/dev/null || echo "0")
  [ "${CTXREADY_RIG_COUNT:-0}" -gt 0 ] 2>/dev/null \
    && log "ctx:ready rig candidates total: $CTXREADY_RIG_COUNT (across all rig DBs, ga-mfeip)."
fi

# Merge all pools into ONE candidate stream (wa-tm2a). dedup by id keeps a bead
# that somehow matched more than one query from being double-counted. The merge is
# the UNION — eligibility prefilters were applied identically to each pool above, so
# concatenation preserves them; only the ordering (Step 3, _top_candidate) now
# decides who goes first. CTXREADY_JSON is "[]" unless PILOT_CTX_READY_QUERIES=1,
# CTXREADY_RIG_JSON is "[]" unless PILOT_CTX_READY_RIG_QUERIES=1 (ga-mfeip).
ALL_CANDIDATES_JSON=$(echo "$TIER1_JSON $TIER2_JSON $CTXREADY_JSON $CTXREADY_RIG_JSON" \
  | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")
HQ_MERGED_COUNT=$(echo "$ALL_CANDIDATES_JSON" | jq 'length' 2>/dev/null || echo "0")
if [ "$HQ_MERGED_COUNT" -gt "0" ]; then
  if [ "$TIER1_COUNT" -gt "0" ] && [ "$TIER2_COUNT" -gt "0" ]; then
    ALL_CANDIDATES_TIER="mixed"
  elif [ "$TIER1_COUNT" -gt "0" ]; then
    ALL_CANDIDATES_TIER="bug"
  else
    ALL_CANDIDATES_TIER="feature"
  fi
  _ctx_total=$(( ${CTXREADY_COUNT:-0} + ${CTXREADY_RIG_COUNT:-0} )) || _ctx_total=0
  if [ "${_ctx_total:-0}" -gt 0 ] 2>/dev/null; then
    log "Merged candidate pool: $HQ_MERGED_COUNT (bugs/debt + stories + ${_ctx_total} ctx:ready chore/task [HQ=${CTXREADY_COUNT} rig=${CTXREADY_RIG_COUNT}], priority-ordered)."
  else
    log "Merged candidate pool: $HQ_MERGED_COUNT (bugs/debt + stories, priority-ordered)."
  fi
fi

# ── Step 2c: Fallback — scan rig DBs if HQ returned nothing ──────────────────
# Per convention all story beads live in HQ, but check rig DBs as a fallback.
# Only reached when the merged HQ pool is empty.

if [ -z "$ALL_CANDIDATES_TIER" ]; then
  log "HQ returned no candidates (bugs/debt + stories) — scanning rig DBs as fallback ..."
  RIG_PATHS=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")

  ALL_RIG_TIER1="[]"
  ALL_RIG_TIER2="[]"
  while IFS= read -r rig_path; do
    [ -z "$rig_path" ] || [ ! -d "$rig_path" ] && continue

    # Tier 1: bugs from rig DB
    RIG_BUGS=$(bd -C "$rig_path" list --json -t bug \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      --exclude-type epic \
      -n 0 2>/dev/null || echo "[]")
    RIG_BUGS=$(echo "$RIG_BUGS" | _filter_candidates | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_BUGS" | jq -s 'add // []' 2>/dev/null || echo "[]")

    # Tier 1: tech-debt from rig DB
    RIG_DEBT=$(bd -C "$rig_path" list --json -l "tech-debt" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      --exclude-type epic \
      -n 0 2>/dev/null || echo "[]")
    RIG_DEBT=$(echo "$RIG_DEBT" | _filter_candidates | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_DEBT" | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

    # Tier 2: story:approved features from rig DB
    RIG_FEATURES=$(bd -C "$rig_path" list --json -l "story:approved" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      --exclude-type epic \
      -n 0 2>/dev/null || echo "[]")
    RIG_FEATURES=$(echo "$RIG_FEATURES" | _filter_candidates | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER2=$(echo "$ALL_RIG_TIER2 $RIG_FEATURES" | jq -s 'add // []' 2>/dev/null || echo "[]")
  done <<< "$RIG_PATHS"

  RIG_TIER1_COUNT=$(echo "$ALL_RIG_TIER1" | jq 'length' 2>/dev/null || echo "0")
  RIG_TIER2_COUNT=$(echo "$ALL_RIG_TIER2" | jq 'length' 2>/dev/null || echo "0")

  # wa-tm2a: merge rig bugs/debt + features into ONE pool, same as HQ. Ordering
  # (priority>type>created_at>id) — not tier — decides who dispatches first.
  RIG_MERGED_JSON=$(echo "$ALL_RIG_TIER1 $ALL_RIG_TIER2" \
    | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")
  RIG_MERGED_COUNT=$(echo "$RIG_MERGED_JSON" | jq 'length' 2>/dev/null || echo "0")
  if [ "$RIG_MERGED_COUNT" -gt "0" ]; then
    ALL_CANDIDATES_JSON="$RIG_MERGED_JSON"
    if [ "$RIG_TIER1_COUNT" -gt "0" ] && [ "$RIG_TIER2_COUNT" -gt "0" ]; then
      ALL_CANDIDATES_TIER="mixed"
    elif [ "$RIG_TIER1_COUNT" -gt "0" ]; then
      ALL_CANDIDATES_TIER="bug"
    else
      ALL_CANDIDATES_TIER="feature"
    fi
    log "Rig DBs: $RIG_MERGED_COUNT merged candidate(s) (bug/debt=$RIG_TIER1_COUNT, feature=$RIG_TIER2_COUNT) — priority-ordered."
  fi
fi

ALL_CANDIDATES_COUNT=$(echo "$ALL_CANDIDATES_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$ALL_CANDIDATES_COUNT" = "0" ]; then
  log "No dispatchable candidates (Tier 1 or Tier 2). Exiting."
  exit 0
fi

log "Dispatch tier: $ALL_CANDIDATES_TIER (${ALL_CANDIDATES_COUNT} candidate(s))"

# ── Step 3: Split candidates by lane, pick one per available lane ─────────────
# For each candidate classify its lane. Build two sorted candidate lists.
# Pick highest priority (P0>P1>P2..., tie-break oldest) from each.
# Only dispatch into a lane if it has a free slot.

SMALL_CANDIDATES="[]"
BIG_CANDIDATES="[]"

while IFS= read -r bead; do
  lane=$(classify_lane "$bead")
  if [ "$lane" = "big" ]; then
    BIG_CANDIDATES=$(echo "$BIG_CANDIDATES" | jq --argjson b "$bead" '. + [$b]' 2>/dev/null || echo "$BIG_CANDIDATES")
  else
    SMALL_CANDIDATES=$(echo "$SMALL_CANDIDATES" | jq --argjson b "$bead" '. + [$b]' 2>/dev/null || echo "$SMALL_CANDIDATES")
  fi
done < <(echo "$ALL_CANDIDATES_JSON" | jq -c '.[]')

SMALL_COUNT=$(echo "$SMALL_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
BIG_COUNT=$(echo "$BIG_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
log "Candidates split: small=${SMALL_COUNT}  big=${BIG_COUNT}"

# wa-tm2a: ordering key shared by _top_candidate and _queue_preview.
# Sort strictly by:  priority (0-4 asc; missing = 99 = last)
#                      > type rank (bug → tech-debt → task → chore → feature/story)
#                        > created_at (oldest first)
#                          > id (final deterministic tiebreak).
# Type rank derives from the bead's OWN type — issue_type (or legacy .type),
# overridden to "tech-debt" when the tech-debt LABEL is present (tech-debt beads
# carry issue_type=task/chore but the tech-debt label, and are queried via -l).
# epic is excluded upstream (by the epic-type query filter) so it never reaches this sort;
# an unknown/missing type sorts last among same-priority beads (rank 5).
#
# The jq program is a string constant so both call sites stay byte-identical.
_PILOT_SORT_JQ='
  def trank:
    ( (.labels // []) ) as $lbls
    | if ($lbls | index("tech-debt")) then 1
      else ( (.issue_type // .type // "") | ascii_downcase ) as $t
        | if   $t == "bug"      then 0
          elif $t == "tech-debt" then 1
          elif $t == "task"     then 2
          elif $t == "chore"    then 3
          elif ($t == "feature" or $t == "story") then 4
          else 5 end
      end;
  sort_by([ (.priority // 99), (. | trank), (.created_at // ""), (.id // "") ])
'

# Sort the pool by the wa-tm2a key and return the single top candidate.
_top_candidate() {
  local arr="$1"
  echo "$arr" | jq "$_PILOT_SORT_JQ"' | .[0]' 2>/dev/null
}

# wa-tm2a: derive the dispatch TIER for a SINGLE bead from its own type, so a
# merged pool dispatches each bead with the correct prompt/sling template:
#   "bug"     → bugs and tech-debt ("fix bug …")
#   "feature" → everything else, incl. story/feature ("build story …")
# (Mirrors the bug/feature branches in dispatch_one. Replaces the old sweep-level
# tier which is no longer homogeneous once the pools are merged.)
_bead_tier() {
  echo "$1" | jq -r '
    if ((.labels // []) | index("tech-debt")) then "bug"
    else ((.issue_type // .type // "") | ascii_downcase) as $t
      | if ($t == "bug" or $t == "tech-debt") then "bug" else "feature" end
    end' 2>/dev/null || echo "feature"
}

SMALL_PICK="null"
BIG_PICK="null"

[ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ] && \
  SMALL_PICK=$(_top_candidate "$SMALL_CANDIDATES")
[ "$BIG_SLOTS"   -gt "0" ] && [ "$BIG_COUNT"   -gt "0" ] && \
  BIG_PICK=$(_top_candidate "$BIG_CANDIDATES")

log "Lane picks — small: $(echo "$SMALL_PICK" | jq -r '.id // "none"')  big: $(echo "$BIG_PICK" | jq -r '.id // "none"')"

# ── ga-8c1 AC5: dispatch-queue preview ───────────────────────────────────────
# Log the next stories queued for dispatch (priority order, top 3 per lane) so
# every sweep makes the backlog visible — not just the single bead picked now.
# Read-only formatting of already-gathered candidates. Guarded for pipefail.
_queue_preview() {
  # wa-tm2a: same ordering key as _top_candidate so the preview is the real order.
  echo "$1" | jq -r --arg lane "$2" "$_PILOT_SORT_JQ"' | .[:3][]
       | "  [\($lane)] \(.id) P\(.priority // "?") — \(.title)"' 2>/dev/null || true
}
_QUEUE_LINES=$( { _queue_preview "$SMALL_CANDIDATES" small; _queue_preview "$BIG_CANDIDATES" big; } )
if [ -n "$_QUEUE_LINES" ]; then
  log "Dispatch queue (next up, priority order):"
  while IFS= read -r _q; do [ -n "$_q" ] && log "$_q"; done <<< "$_QUEUE_LINES"
fi

# ── Dispatch helper ───────────────────────────────────────────────────────────
# dispatch_one <story_json> <lane> <dispatch_tier>
# Handles: claim, verify, builder routing, sling, bead transitions, logging, ntfy.
dispatch_one() {
  local STORY="$1"
  local LANE="$2"
  local DISPATCH_TIER="$3"

  local STORY_ID STORY_TITLE STORY_PRIORITY STORY_LABELS STORY_RIG STORY_BEAD_CITY
  local STORY_ESTRELA STORY_CRITERIA STORY_EQUILIBRIOS
  STORY_ID=$(echo "$STORY" | jq -r '.id')
  STORY_TITLE=$(echo "$STORY" | jq -r '.title // .description // "untitled"' | head -c 100)
  STORY_PRIORITY=$(echo "$STORY" | jq -r '.priority // 99')
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')
  STORY_RIG=$(echo "$STORY" | jq -r '.metadata["story.rig"] // ""')
  STORY_ESTRELA=$(echo "$STORY" | jq -r '.metadata["story.estrela_guia"] // ""' | head -c 200)
  STORY_CRITERIA=$(echo "$STORY" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""')
  STORY_EQUILIBRIOS=$(echo "$STORY" | jq -r '.metadata["story.equilibrios"] // ""')

  # ── gt-pm55p: Early rig resolution + STORY_BEAD_CITY ────────────────────────
  # Infer rig from bead ID prefix if not set in metadata, then derive
  # STORY_BEAD_CITY — the rig's Dolt DB directory for ALL bd ops on $STORY_ID.
  #
  # WHY: bd -C "$GC_CITY" silently no-ops for cross-rig beads (wa-*, ps-*, etc.)
  # because those beads live in their rig's own Dolt DB, not in HQ. When all
  # label/metadata writes use GC_CITY, story:in-flight and pilot:dispatched are
  # NEVER written on cross-rig beads — so the bead stays re-dispatchable on
  # every sweep → dispatcher keeps re-assigning it in a loop (the dc-io31
  # incident: deacon/builder kept receiving the same slung work over and over).
  #
  # Must happen BEFORE the atomic claim so all claim/verify/transition ops route
  # to the correct DB. STORY_BEAD_CITY == GC_CITY for ga-* (HQ) beads; only
  # cross-rig beads (wa-*, ps-*, etc.) get a different path.
  if [ -z "$STORY_RIG" ] || [ "$STORY_RIG" = "null" ]; then
    local _early_prefix
    _early_prefix=$(echo "$STORY_ID" | cut -d'-' -f1)
    case "$_early_prefix" in
      ga) STORY_RIG="gascity" ;;
      ps) STORY_RIG="property_scrapers" ;;
      wa) STORY_RIG="whatsapp_automation" ;;
      gt) STORY_RIG="gastown" ;;
      lx) STORY_RIG="lexbh" ;;
      ma) STORY_RIG="marketing" ;;
      *)  STORY_RIG="gascity" ;;
    esac
    log "  story.rig inferred from bead prefix '$_early_prefix': $STORY_RIG"
  fi
  STORY_BEAD_CITY=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r --arg name "$STORY_RIG" '.rigs[] | select(.name == $name) | .path' \
    2>/dev/null | head -1 || echo "")
  if [ -z "$STORY_BEAD_CITY" ] || [ ! -d "$STORY_BEAD_CITY" ]; then
    STORY_BEAD_CITY="$GC_CITY"
  fi
  log "  rig=$STORY_RIG  bead_city=$STORY_BEAD_CITY"

  # ── ga-jb4l: gate re-dispatch — surface reviewer feedback for needs-fix beads ──
  # A bead labeled gate:needs-fix previously FAILED the quality gate. The gate
  # attached the FAILing reviewers' reasons to it as a "GATE-FEEDBACK" comment.
  # Pull the latest such comment and the attempt counter so the builder prompt
  # tells the re-dispatched builder to fix THE SPECIFIC issues (not redo the work).
  local STORY_GATE_FEEDBACK="" STORY_FIX_ATTEMPT="" GATE_FIX_SECTION=""
  if echo "$STORY_LABELS" | grep -q "gate:needs-fix"; then
    STORY_FIX_ATTEMPT=$(echo "$STORY_LABELS" | tr ',' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
    STORY_GATE_FEEDBACK=$(bd -C "$STORY_BEAD_CITY" comments "$STORY_ID" --json 2>/dev/null \
      | jq -r '[ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""' \
      2>/dev/null || echo "")
    log "  $STORY_ID is gate:needs-fix (attempt=${STORY_FIX_ATTEMPT:-?}) — injecting reviewer feedback (${#STORY_GATE_FEEDBACK} chars)."
    if [ -n "$STORY_GATE_FEEDBACK" ]; then
      GATE_FIX_SECTION=$(cat <<FIXSEC

## ⚠️ GATE RE-DISPATCH — fix THESE specific issues (fix attempt ${STORY_FIX_ATTEMPT:-?}/3)
This bead previously FAILED the autonomous quality gate. You are being re-dispatched
to fix the EXACT blocking issues the reviewers found below — do NOT redo unrelated
work. After fixing, run /gate-done to re-gate. If you genuinely cannot resolve these,
explain why in a bead comment; after 3 failed attempts the machine escalates to a human.

$STORY_GATE_FEEDBACK
FIXSEC
)
    fi
  fi

  log "Selected $DISPATCH_TIER [$LANE] $STORY_ID (priority=$STORY_PRIORITY): $STORY_TITLE"
  log "  labels=$STORY_LABELS  lane=$LANE  tier=$DISPATCH_TIER"

  # ── Atomic claim ────────────────────────────────────────────────────────────
  log "Attempting atomic claim on $STORY_ID (lane=$LANE tier=$DISPATCH_TIER) ..."

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD: stamp pilot.dispatching_at then bd label add $STORY_ID pilot:dispatching"
  else
    # ga-2azzj fix 3: write the claim-time stamp BEFORE the label, so a
    # pilot:dispatching label can never exist without a pilot.dispatching_at
    # stamp for TTL recovery to measure age from (Defect A). updated_at is NOT a
    # reliable claim clock — bd label add does not bump it.
    local CLAIM_EPOCH
    CLAIM_EPOCH=$(date +%s)
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.dispatching_at=$CLAIM_EPOCH" -q 2>/dev/null || true
    bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || {
      warn "Could not add pilot:dispatching to $STORY_ID (race condition or bd error). Skipping."
      return 1
    }
  fi

  # Verify we won the race — and apply ga-zzrts eligibility guards.
  if [ "$DRY_RUN" != "1" ]; then
    local VERIFY_JSON VERIFY_LABELS VERIFY_STATUS VERIFY_SOURCEBEAD
    VERIFY_JSON=$(bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null || echo "[]")
    VERIFY_LABELS=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' \
      2>/dev/null || echo "")
    VERIFY_STATUS=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.status // "")' \
      2>/dev/null || echo "")
    VERIFY_SOURCEBEAD=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.metadata["source-bead"] // .metadata["source_bead"] // "")' \
      2>/dev/null || echo "")

    if echo "$VERIFY_LABELS" | grep -q "story:in-flight"; then
      log "Story $STORY_ID is already in-flight (race condition). Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    if echo "$VERIFY_LABELS" | grep -q "story:done"; then
      log "Story $STORY_ID is already done. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix b) gate:needs-human — bead deliberately parked for human/engine path.
    # The bd list queries already exclude this label; this guard catches the race where
    # gate:needs-human is added BETWEEN the query-time snapshot and claim acquisition.
    if echo "$VERIFY_LABELS" | grep -q "gate:needs-human"; then
      warn "ga-zzrts(b): $STORY_ID has gate:needs-human at dispatch time — race or stale query. Releasing claim and skipping."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix c) Duplicate-in-flight guard: already dispatched in a prior sweep.
    # bd list excludes pilot:dispatched; this is the last-resort guard for the case where
    # story:in-flight was stripped (crash/race) but pilot:dispatched survived — without
    # this check the Pilot would emit a second sling for the same source bead (ga-2aigc).
    if echo "$VERIFY_LABELS" | grep -q "pilot:dispatched"; then
      warn "ga-zzrts(c): $STORY_ID already has pilot:dispatched — prior-sweep duplicate guard. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix a) Closed-bead guard: STATUS is closed but story:done label absent.
    # Delivery inconsistency can leave a bead closed without the label; never dispatch it.
    if [ "$VERIFY_STATUS" = "closed" ]; then
      warn "ga-zzrts(a): $STORY_ID is STATUS:closed without story:done label. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix a) Orphan-sling guard: if this bead carries a source-bead metadata
    # reference (i.e. it is a sling/task bead, not a source story), and the referenced
    # source bead is already closed, skip — the underlying work is done. This is the
    # "closed-source sling" class of flood: dogs re-claim sling beads whose source was
    # closed without the sling being retired.
    if [ -n "$VERIFY_SOURCEBEAD" ] && [ "$VERIFY_SOURCEBEAD" != "null" ]; then
      local SOURCE_BEAD_STATUS
      SOURCE_BEAD_STATUS=$(bd -C "$STORY_BEAD_CITY" show "$VERIFY_SOURCEBEAD" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.status // "")' \
        2>/dev/null || echo "")
      if [ "$SOURCE_BEAD_STATUS" = "closed" ]; then
        warn "ga-zzrts(a): $STORY_ID is a sling/task whose source $VERIFY_SOURCEBEAD is STATUS:closed — orphan sling. Releasing claim."
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
        return 1
      fi
    fi
  fi

  log "Claim acquired on $STORY_ID."

  # ── ga-htjni: ownership / in-flight collision guard ──────────────────────────
  # REFUSE a NET-NEW dispatch when the work is already real and owned: (a) a crew
  # branch exists for this bead, or (b) the bead has a live named-crew owner. This
  # runs AFTER the atomic claim + every lifecycle/race verify above so it composes
  # with them (it is the LAST gate before builder routing), and BEFORE any sling so
  # no second builder is ever spawned. Reconciled with the reclaim paths above
  # (genuine orphans — dead owner AND no branch — are released upstream and NOT
  # blocked here, see _ownership_guard_should_refuse). On refusal we release the
  # claim and skip; the rightful owner keeps the bead. FAIL-OPEN by construction.
  if [ "${PILOT_OWNERSHIP_GUARD:-1}" = "1" ]; then
    local _OWN_REASON
    _OWN_REASON=$(_ownership_guard_should_refuse "$STORY_ID" "$STORY" "$STORY_BEAD_CITY" || echo "")
    if [ -n "$_OWN_REASON" ]; then
      warn "ga-htjni: REFUSING dispatch of $STORY_ID — already owned/in-flight ($_OWN_REASON). Leaving it for its rightful owner; releasing claim (set PILOT_OWNERSHIP_GUARD=0 to disable)."
      if [ "$DRY_RUN" != "1" ]; then
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
        bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      fi
      return 1
    fi
  fi

  # ── ga-cnvy1: live-wrapper dedup — never mint a 2nd sling for the same target ──
  # ROOT (convoy storm): the Pilot stamps pilot.sling_bead=<id> on a STORY when it
  # first slings a builder task for it (see the dispatch transition below). If that
  # sling/convoy wrapper is STILL OPEN, the work is already dispatched — yet a later
  # sweep that re-acquired the claim (story:in-flight stripped by a crash/race, or a
  # bead that re-entered a candidate query) would `gc sling` a SECOND wrapper for the
  # SAME target. Repeated every 5-min sweep, one bug (e.g. wa-uhpy) accumulates ~15
  # redundant open convoy wrappers. This guard reads the story's CURRENT
  # pilot.sling_bead and, if that wrapper bead is still open, SKIPS — the existing
  # wrapper already carries the dispatch. Same family as the ga-9yb5s/ga-htjni
  # double-dispatch guards: detect "already dispatched" at the pre-sling chokepoint
  # and refuse the duplicate. FAIL-OPEN by construction: a missing/unreadable
  # pilot.sling_bead, a closed wrapper, or any bd/jq error → fall through and
  # dispatch exactly as today (a transient glitch never blocks a real dispatch).
  if [ "${PILOT_DEDUP_GUARD:-1}" = "1" ]; then
    local _EXISTING_SLING _EXISTING_SLING_STATUS
    _EXISTING_SLING=$(bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.metadata["pilot.sling_bead"] // "")' \
      2>/dev/null || echo "")
    if [ -n "$_EXISTING_SLING" ] && [ "$_EXISTING_SLING" != "null" ]; then
      # The sling/wrapper task bead always lives in GC_CITY (created by gc sling in HQ).
      _EXISTING_SLING_STATUS=$(bd -C "$GC_CITY" show "$_EXISTING_SLING" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.status // "")' \
        2>/dev/null || echo "")
      if [ "$_EXISTING_SLING_STATUS" = "open" ] || [ "$_EXISTING_SLING_STATUS" = "in_progress" ]; then
        warn "ga-cnvy1: SKIPPING dispatch of $STORY_ID — a live wrapper ($_EXISTING_SLING, status=$_EXISTING_SLING_STATUS) already exists for this target; work is already dispatched. Releasing claim, NOT minting a 2nd sling (set PILOT_DEDUP_GUARD=0 to disable)."
        if [ "$DRY_RUN" != "1" ]; then
          bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
          bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
        fi
        return 1
      fi
    fi
  fi

  # ── Determine builder target ─────────────────────────────────────────────────
  # STORY_RIG and STORY_BEAD_CITY already resolved above (gt-pm55p early rig fix).
  local BUILDER_TARGET _POOL _POOL_N
  _POOL=$(rig_to_builders "$STORY_RIG")
  _POOL_N=$(echo "$_POOL" | wc -w | tr -d ' ')

  if [ "${_POOL_N:-1}" -gt 1 ]; then
    # ── ga-mtlm6: pooled rig — distribute across idle crew, deliver to existing ──
    # A rig with several interchangeable single-identity crew (WA: digo/mila/
    # oracle/peter/thies-wa). Pick a crew that is NEITHER busy with live in-flight
    # work (PILOT_BUSY_BUILDERS) NOR already loaded this sweep (PILOT_USED_BUILDERS),
    # so M bugs fan out to M crew instead of all piling on digo-wa. An idle crew
    # that already has a live session RECEIVES the task — `gc sling` routes the
    # task bead to it and `--nudge`/session nudge wakes the existing session — it
    # is NOT deferred. (The pre-ga-mtlm6 path routed every WA bug to one pinned
    # builder, then the wa-1eos "active session → defer" mutex deferred it forever
    # while 4 idle crew sat starved.) When every crew is busy/used → defer (release
    # the claim, retry next sweep): correct backpressure, never a duplicate spawn.
    #
    # gt-s1saw: route by AREA, not just rotation. Classify the bead's domain, then
    # PREFER its mapped owner and EXCLUDE any crew known not to own it — so a UI
    # bug never re-lands on digo-wa (data owner) and loops. Fail-open: unknown
    # domain ⇒ empty prefer/exclude ⇒ identical to the pre-gt-s1saw rotation.
    local _DOMAIN _PREFER _EXCLUDE
    _DOMAIN=$(bead_domain "$STORY")
    _PREFER=$(rig_domain_owner   "$STORY_RIG" "$_DOMAIN")
    _EXCLUDE=$(rig_domain_exclude "$STORY_RIG" "$_DOMAIN")
    BUILDER_TARGET=$(pick_pool_builder "$STORY_RIG" "$_PREFER" "$_EXCLUDE" || echo "")
    if [ -z "$BUILDER_TARGET" ]; then
      log "POOL($STORY_RIG): all crew busy/used this sweep or domain-excluded (domain=${_DOMAIN:-none} prefer=${_PREFER:-none} exclude=${_EXCLUDE:-none} pool=[$_POOL] busy=[${PILOT_BUSY_BUILDERS:-none}] used=[${PILOT_USED_BUILDERS:-none}]) — deferring $STORY_ID to next sweep. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    mark_pool_builder "$BUILDER_TARGET"
    log "  Builder target: $BUILDER_TARGET (rig=$STORY_RIG bead_city=$STORY_BEAD_CITY lane=$LANE domain=${_DOMAIN:-none}) [pool: $_POOL]"
  else
    # ── Single-member rig (gastown.dog pool, or a lone single-identity crew) ─────
    BUILDER_TARGET="$_POOL"
    log "  Builder target: $BUILDER_TARGET (rig=$STORY_RIG bead_city=$STORY_BEAD_CITY lane=$LANE)"

    # ── wa-1eos: per-builder mutex (single-identity, single-member rigs only) ────
    # A lone single-identity builder (e.g. batista-ps) must have AT MOST ONE live
    # session. Dispatching a 2nd bead to a busy one makes `gc sling` spawn a
    # duplicate (batista-ps → batista-ps-1) that works the SAME crew branch —
    # branch corruption. If already live, defer (release the claim so it stays
    # dispatchable). gastown.dog is a shared pool (multiple instances by design) —
    # exempt. Pooled rigs (WA) are handled above by the busy-set, not this mutex.
    # Fail-safe: any error → count 0 → dispatch proceeds (never halts on a `gc` hiccup).
    #
    # gt-4st3n: when PILOT_REUSE_SESSION=1 (default), this defer is SUPERSEDED — a
    # live crew session is no longer a reason to defer, because the delivery block
    # below REUSES it (hook + non-interrupting follow_up submit) instead of letting
    # `gc sling` spawn a duplicate. The mutex only fires in the legacy (reuse=0)
    # path, where spawn-on-sling is still the delivery mechanism and the duplicate
    # hazard is real.
    if [ "${PILOT_REUSE_SESSION:-1}" != "1" ] && [ "$DRY_RUN" != "1" ] && [ "$BUILDER_TARGET" != "gastown.dog" ]; then
      local LIVE_BUILDER_SESSIONS
      LIVE_BUILDER_SESSIONS=$(gc --city "$GC_CITY" session list 2>/dev/null \
        | awk -v t="$BUILDER_TARGET" '$2==t && $3=="active"' | wc -l | tr -d ' ')
      if [ "${LIVE_BUILDER_SESSIONS:-0}" -ge 1 ] 2>/dev/null; then
        log "MUTEX(wa-1eos): builder $BUILDER_TARGET already has ${LIVE_BUILDER_SESSIONS} live session(s) — deferring $STORY_ID to next sweep (no duplicate spawn). Releasing claim."
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
        return 1
      fi
    fi
  fi


  # ── ga-lfvs6/ga-wgcyk/ga-m3n1x: DOMAIN builds must NOT go to the dog pool ─────
  # ROOT (5+ recurrences today): a property_scrapers scraper / data-build (or a WA
  # painel/pipedrive feature) authored as an HQ ga- bead with story.rig unset and
  # assignee null is rig-inferred → gascity → rig_to_builders → gastown.dog. A dog
  # (~25-min TTL, no domain data access, no rig git checkout, no git-diff for the
  # gate) cannot build a real domain task, so it circuit-breaks and the sweep
  # re-dispatches it — a loop. The lane:big nodog guard (ga-jazy9, below) only catches
  # lane:big and only DEFERS; these misroutes are mostly lane:small DOMAIN builds and
  # need affirmative re-routing to the owning crew. This guard GENERALISES the nodog
  # protection to ANY lane via content-based domain inference, and runs BEFORE the
  # lane:big guard so a lane:big DOMAIN build is re-routed to its crew here rather
  # than blindly deferred there. After this guard, any residual dog-targeted lane:big
  # work is generic (no domain) and the lane:big guard correctly defers it. Acts only
  # when the resolved target is STILL a dog.
  #
  # Rules, in order, when BUILDER_TARGET is a dog:
  #   0. Skip if the bead is NOT a domain build (bead_content_rig == "") → generic/
  #      HQ work keeps flowing to the dog pool exactly as today (FAIL-OPEN).
  #   1. Honor an explicit LIVE persistent-crew owner (assignee on the bead) — route
  #      there, never a dog (ga-9yb5s/ga-htjni ownership family). The ownership guard
  #      earlier already DEFERS most such cases; this is the affirmative fallback.
  #   2. Else route to the inferred domain's PERSISTENT crew (rig_domain_default_builder)
  #      — but ONLY if that crew is not busy/used this sweep (so we never spawn a 2nd
  #      session on a single-identity crew). If busy/used → DEFER.
  #   3. Else (no persistent crew for the domain, or it's busy) → DEFER (leave queued)
  #      rather than burn the build on a dog that will circuit-break it.
  # FAIL-OPEN: a non-dog target, an unresolvable domain, or any error → no change.
  # Disable with PILOT_DOMAIN_ROUTE_GUARD=0.
  if [ "${PILOT_DOMAIN_ROUTE_GUARD:-1}" = "1" ]; then
    case "$BUILDER_TARGET" in
      gastown.dog|gastown.dog-*)
        local _DOMAIN_RIG=""
        _DOMAIN_RIG=$(bead_content_rig "$STORY" 2>/dev/null || echo "")
        if [ -n "$_DOMAIN_RIG" ] && [ "$_DOMAIN_RIG" != "gascity" ]; then
          # (1) explicit live crew owner wins.
          local _DOM_CREW_OWNER=""
          _DOM_CREW_OWNER=$(_beadid_live_crew_owner "$STORY_ID" "$STORY_BEAD_CITY" 2>/dev/null || echo "")
          if [ -n "$_DOM_CREW_OWNER" ]; then
            log "ga-lfvs6: $STORY_ID is a $_DOMAIN_RIG domain build with a live persistent-crew owner ($_DOM_CREW_OWNER) — honoring it over the dog pool (was target=$BUILDER_TARGET)."
            BUILDER_TARGET="$_DOM_CREW_OWNER"
            STORY_RIG="$_DOMAIN_RIG"
          else
            # (2) route to the domain's persistent crew if mapped AND idle.
            local _DOM_DEFAULT=""
            _DOM_DEFAULT=$(rig_domain_default_builder "$_DOMAIN_RIG" 2>/dev/null || echo "")
            local _DOM_BUSY=0
            if [ -n "$_DOM_DEFAULT" ]; then
              case " $PILOT_BUSY_BUILDERS " in *" $_DOM_DEFAULT "*) _DOM_BUSY=1 ;; esac
              case " $PILOT_USED_BUILDERS " in *" $_DOM_DEFAULT "*) _DOM_BUSY=1 ;; esac
            fi
            if [ -n "$_DOM_DEFAULT" ] && [ "$_DOM_BUSY" = "0" ]; then
              log "ga-lfvs6: $STORY_ID is a $_DOMAIN_RIG domain build mis-routed to the dog pool (was target=$BUILDER_TARGET, story.rig=$STORY_RIG) — routing to the owning persistent crew $_DOM_DEFAULT instead."
              BUILDER_TARGET="$_DOM_DEFAULT"
              STORY_RIG="$_DOMAIN_RIG"
              mark_pool_builder "$_DOM_DEFAULT"
            else
              # (3) no idle persistent crew for the domain → DEFER, never a dog.
              warn "ga-lfvs6: REFUSING to dispatch $_DOMAIN_RIG domain build $STORY_ID to the ephemeral dog pool ($BUILDER_TARGET) — a dog cannot build a real domain task (no domain data, no rig checkout, no git-diff for the gate). Owning crew ${_DOM_DEFAULT:-none} is ${_DOM_DEFAULT:+busy/unavailable}${_DOM_DEFAULT:-unmapped}. Deferring (leaving queued) until a persistent crew is available; releasing claim (set PILOT_DOMAIN_ROUTE_GUARD=0 to disable)."
              if [ "$DRY_RUN" != "1" ]; then
                bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
                bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
              fi
              return 1
            fi
          fi
        fi
        ;;
    esac
  fi

  # ── ga-jazy9: lane:big must NOT go to the ephemeral dog pool ──────────────────
  # ROOT: a lane:big daemon/subsystem story (ga-jazy9) was repeatedly dispatched to
  # the gastown.dog adhoc pool. Dogs have a ~25-min TTL — they cannot build a
  # lane:big subsystem — so each dog circuit-broke it, and the cycle re-dispatched
  # it (3+ times), ignoring the Mayor's explicit assignee=batista-ps routing. The
  # dog pool is for lane:small / ephemeral work ONLY; lane:big needs a PERSISTENT
  # crew. This guard runs AFTER builder routing (so the dog target is visible) and
  # BEFORE any sling. Rules, in order:
  #   1. If the story has an explicit, LIVE persistent-crew owner (assignee), honor
  #      it — route there, never reroute a crew-owned big story to a dog
  #      (ga-9yb5s/ga-htjni ownership family). (The ownership guard above already
  #      DEFERS most such cases; this is the affirmative routing fallback.)
  #   2. Else, if BUILDER_TARGET is the dog pool, DEFER (leave queued) — a lane:big
  #      item must wait for a persistent crew rather than burn on a 25-min dog.
  # FAIL-OPEN: a non-big lane, a non-dog target, or any error → no change (dispatch
  # exactly as today). Disable with PILOT_BIG_NODOG_GUARD=0.
  if [ "${PILOT_BIG_NODOG_GUARD:-1}" = "1" ] && [ "$LANE" = "big" ]; then
    case "$BUILDER_TARGET" in
      gastown.dog|gastown.dog-*)
        # (1) honor an explicit live crew owner before deferring.
        local _BIG_CREW_OWNER=""
        _BIG_CREW_OWNER=$(_beadid_live_crew_owner "$STORY_ID" "$STORY_BEAD_CITY" 2>/dev/null || echo "")
        if [ -n "$_BIG_CREW_OWNER" ]; then
          log "ga-jazy9: $STORY_ID is lane:big with a live persistent-crew owner ($_BIG_CREW_OWNER) — honoring it over the dog pool (was target=$BUILDER_TARGET)."
          BUILDER_TARGET="$_BIG_CREW_OWNER"
        else
          # (2) no live crew owner → DEFER; a dog cannot build a lane:big subsystem.
          warn "ga-jazy9: REFUSING to dispatch lane:big $STORY_ID to the ephemeral dog pool ($BUILDER_TARGET) — dogs (~25-min TTL) cannot build a big subsystem. Deferring (leaving queued) until a persistent crew is available; releasing claim (set PILOT_BIG_NODOG_GUARD=0 to disable)."
          if [ "$DRY_RUN" != "1" ]; then
            bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
            bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
          fi
          return 1
        fi
        ;;
    esac
  fi

  # ── wa-root-worktree-isolation: rig-root → worktree directive (best-effort) ───
  # Compute once; injected into either prompt below. Empty unless this build would
  # land in a rig's bare production root (see worktree_directive_for). Fail-open.
  local WORKTREE_DIRECTIVE
  WORKTREE_DIRECTIVE=$(worktree_directive_for "$STORY_RIG" "$BUILDER_TARGET" 2>/dev/null || echo "")

  # ── Build task prompt ────────────────────────────────────────────────────────
  local DISPATCH_TASK
  if [ "$DISPATCH_TIER" = "bug" ]; then
    DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — Bug/tech-debt assigned for autonomous fix

Bead ID: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: BUG / TECH-DEBT (Tier 1 — dispatched BEFORE new features)
Lane: $LANE
Rig: $STORY_RIG
City: $GC_CITY
Bead DB: $STORY_BEAD_CITY

## Your job
Fix this bug or tech-debt item completely. Do NOT wait for a human.
"Só depois do sistema perfeito é que a gente faz novas features." — system quality first.
$GATE_FIX_SECTION

## Description / Acceptance Criteria
$STORY_CRITERIA

## Additional Context
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your fix is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just fix, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → bead closed.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.
$WORKTREE_DIRECTIVE
## Steps
1. Read the full bead: bd -C "$STORY_BEAD_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Diagnose root cause, implement fix on a branch (name: fix/$STORY_ID).
4. Add a regression test if applicable.
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$STORY_BEAD_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$STORY_BEAD_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  else
    DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — Story assigned for autonomous build

Story ID: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: FEATURE (Tier 2 — dispatched only because no open bugs/tech-debt)
Lane: $LANE
Rig: $STORY_RIG
City: $GC_CITY
Bead DB: $STORY_BEAD_CITY

## Your job
Build this story from acceptance criteria to /gate-done. Do NOT wait for a human.
$GATE_FIX_SECTION

## Acceptance Criteria
$STORY_CRITERIA

## Estrela Guia (north star)
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your implementation is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just build, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → story:done.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.
$WORKTREE_DIRECTIVE
## Steps
1. Read the full story bead: bd -C "$STORY_BEAD_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Implement the story on a feature branch (name: feat/$STORY_ID or story/$STORY_ID).
4. Add a story-specific prod test at the required path (see delivery-runbooks.toml).
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$STORY_BEAD_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$STORY_BEAD_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  fi

  log "  Task prompt built (${#DISPATCH_TASK} chars)"

  # ── gt-4st3n: classify the builder's existing session → REUSE vs SPAWN ────────
  # Decide BEFORE dispatch whether the target already has a session we must reuse
  # rather than spawn a second one alongside. gastown.dog is a dog POOL (multiple
  # instances by design) → always spawn. Any non-dog crew identity with a live
  # session → reuse it (hook + non-interrupting follow_up submit); asleep → wake
  # the existing session first; none → legacy spawn. Read-only classification, so
  # it runs in dry-run too (the actions below are still gated by DRY_RUN).
  # Fail-open: classification errors leave _DISPATCH_REUSE=0 → legacy spawn path.
  local _DISPATCH_REUSE=0 _DISPATCH_SESS_STATE="none" _DISPATCH_SESS_REF=""
  if [ "${PILOT_REUSE_SESSION:-1}" = "1" ] && [ "$BUILDER_TARGET" != "gastown.dog" ]; then
    local _sess_line
    _sess_line=$(_target_session_state "$BUILDER_TARGET" 2>/dev/null || echo "none")
    _DISPATCH_SESS_STATE="${_sess_line%% *}"
    case "$_DISPATCH_SESS_STATE" in
      active|asleep)
        _DISPATCH_REUSE=1
        _DISPATCH_SESS_REF="${_sess_line#* }"
        [ "$_DISPATCH_SESS_REF" = "$_sess_line" ] && _DISPATCH_SESS_REF="$BUILDER_TARGET"
        log "  REUSE(gt-4st3n): $BUILDER_TARGET has an existing $_DISPATCH_SESS_STATE session ($_DISPATCH_SESS_REF) — will hook + non-interrupting follow_up, NOT spawn a 2nd session." ;;
      *)
        _DISPATCH_SESS_STATE="none" ;;
    esac
  fi

  # ── ga-mfeip: rig-native vs cross-store dispatch path selector ────────────────
  # When STORY_BEAD_CITY != GC_CITY (a rig-native bead, e.g. wa-*), `gc sling
  # <crew> <bead>` is REFUSED by the engine ("cross-store routes wedge pools —
  # tr-6s7yx"). Use the rig-native path instead: `bd update --assignee` + nudge.
  # When STORY_BEAD_CITY == GC_CITY (HQ bead), use the standard gc sling path.
  local _IS_RIG_NATIVE=0
  [ "$STORY_BEAD_CITY" != "$GC_CITY" ] && _IS_RIG_NATIVE=1

  # ── Dispatch via gc sling (HQ beads) or bd assign (rig-native beads) ─────────
  local DISPATCH_EPOCH DISPATCH_RESULT SLING_BEAD_ID NOW
  DISPATCH_EPOCH=$(date +%s)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$DRY_RUN" = "1" ]; then
    local SLING_TITLE_DRY
    SLING_TITLE_DRY="$([ "$DISPATCH_TIER" = "bug" ] && echo "fix bug" || echo "build story") $STORY_ID: $STORY_TITLE"
    log "DRY_RUN=1 — WOULD DISPATCH (tier=$DISPATCH_TIER lane=$LANE rig_native=$_IS_RIG_NATIVE):"
    if [ "$_IS_RIG_NATIVE" = "1" ]; then
      log "  RIG-NATIVE path (ga-mfeip): bd -C $STORY_BEAD_CITY update $STORY_ID --assignee $BUILDER_TARGET"
      log "  WOULD: gc --city $GC_CITY session nudge $BUILDER_TARGET <task_prompt>"
    elif [ "$_DISPATCH_REUSE" = "1" ]; then
      [ "$_DISPATCH_SESS_STATE" = "asleep" ] \
        && log "  WOULD: gc session wake $_DISPATCH_SESS_REF (reuse existing asleep session — gt-4st3n)"
      log "  gc --city $GC_CITY sling $BUILDER_TARGET <task_bead>   (reuse: routes to existing $_DISPATCH_SESS_STATE session, no spawn)"
      log "  WOULD: gc session submit $_DISPATCH_SESS_REF <task> --intent follow_up   (non-interrupting hook+nudge — gt-4st3n)"
    else
      log "  gc --city $GC_CITY sling $BUILDER_TARGET <task_bead> --nudge   (spawn: no existing session)"
    fi
    log "  Task title: '$SLING_TITLE_DRY'"
    log "  Rig: $STORY_RIG → builder: $BUILDER_TARGET"
    log "  WOULD: bd label add $STORY_ID lane:${LANE}"
    log "  WOULD: bd label add $STORY_ID story:in-flight (verify durable BEFORE releasing claim)"
    log "  WOULD: bd label remove $STORY_ID pilot:dispatching"
    log "  WOULD: bd label add $STORY_ID pilot:dispatched"
    log "  WOULD: bd comment $STORY_ID 'Pilot dispatched builder $BUILDER_TARGET at $NOW'"
    SLING_BEAD_ID="DRY_RUN_NO_SLING"
    DISPATCH_RESULT="dry_run"
  elif [ "$_IS_RIG_NATIVE" = "1" ]; then
    # ── ga-mfeip: rig-native dispatch path — bd assign + nudge ─────────────────
    # The bead lives in the rig's own Dolt DB. Cross-store sling is refused, so
    # we assign the bead directly in the rig DB and nudge the crew. The bead ID
    # itself acts as the task hook (no separate sling task created). pilot.sling_bead
    # is set to STORY_ID so TTL recovery can track builder activity via assignee.
    log "  RIG-NATIVE dispatch (ga-mfeip): assigning $STORY_ID → $BUILDER_TARGET in $STORY_BEAD_CITY"
    # ── ga-mfeip gate (f): dedup — never put two crews on one bead ─────────────
    # The candidate snapshot was taken at the top of the sweep; a sibling claim may have
    # assigned this bead since. Re-read its CURRENT assignee straight from the rig DB.
    # A DIFFERENT crew already owns it ⇒ abort and release our claim (the wa-6m6h
    # two-crew regression). null/own assignee ⇒ proceed. Fail-open: a failed re-read
    # yields empty → we proceed (never block a dispatch on a probe error).
    _cur_asg=$(timeout 10 bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | .assignee // ""' 2>/dev/null || echo "")
    if [ -n "$_cur_asg" ] && [ "$_cur_asg" != "$BUILDER_TARGET" ]; then
      warn "ga-mfeip gate-f: $STORY_ID already assigned to $_cur_asg — skipping dispatch to $BUILDER_TARGET (dedup)."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      DISPATCH_RESULT="rig_dedup_skip"
      return 1
    fi
    if ! timeout 15 bd -C "$STORY_BEAD_CITY" update "$STORY_ID" \
        --assignee "$BUILDER_TARGET" -q 2>/dev/null; then
      warn "ga-mfeip: bd update --assignee failed for $STORY_ID → $BUILDER_TARGET. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      DISPATCH_RESULT="rig_assign_failed"
      return 1
    fi
    # Record the rig bead itself as the "sling bead" for TTL compatibility.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.sling_bead=$STORY_ID" -q 2>/dev/null || true
    SLING_BEAD_ID="$STORY_ID"
    DISPATCH_RESULT="rig_native_ok"
    log "  ga-mfeip: rig assign OK — $STORY_ID.assignee=$BUILDER_TARGET. Nudging crew."
    timeout 15 gc --city "$GC_CITY" session nudge "$BUILDER_TARGET" "$DISPATCH_TASK" \
      2>/dev/null \
      || warn "ga-mfeip: Could not nudge $BUILDER_TARGET — crew will see $STORY_ID on next hook cycle"
    log "Dispatch complete (rig-native): bead=$STORY_ID target=$BUILDER_TARGET (ga-mfeip)"
  else
    local SLING_TITLE SLING_OUT
    if [ "$DISPATCH_TIER" = "bug" ]; then
      SLING_TITLE="fix bug $STORY_ID: $STORY_TITLE"
    else
      SLING_TITLE="build story $STORY_ID: $STORY_TITLE"
    fi

    # ── gt-4st3n: wake an ASLEEP crew session BEFORE routing, so we reuse it ─────
    # rather than letting the reconciler resume it into a parallel runtime (the
    # "origin=flag resume=--resume" duplicate that crew-session-dedup then drains,
    # which reads as a reset). `gc session wake` acts on the EXISTING session only;
    # it never creates a second one. Best-effort + bounded: a failed/slow wake is
    # non-fatal — the routed bead is still a durable hook the crew picks up on its
    # next cycle. ACTIVE sessions need no wake. gastown.dog never reaches here.
    if [ "$_DISPATCH_REUSE" = "1" ] && [ "$_DISPATCH_SESS_STATE" = "asleep" ]; then
      log "  REUSE(gt-4st3n): waking existing asleep session $_DISPATCH_SESS_REF (no parallel spawn) ..."
      if timeout 15 gc --city "$GC_CITY" session wake "$_DISPATCH_SESS_REF" >/dev/null 2>&1; then
        # Bounded poll so the sling below routes to a LIVE session (reuse) instead
        # of racing the reconciler's resume. Each probe is a runtime `session list`
        # (no Dolt). Falls through after the budget: the routed bead is still a
        # durable hook and the follow_up submit can wake the session on its own.
        local _wake_i _wake_max="${PILOT_WAKE_POLL_TRIES:-4}" _wake_sleep="${PILOT_WAKE_POLL_SLEEP:-2}"
        for _wake_i in $(seq 1 "$_wake_max"); do
          if gc --city "$GC_CITY" session list --json 2>/dev/null \
              | jq -e --arg r "$_DISPATCH_SESS_REF" \
                  '[.sessions[]? | select(.closed != true)
                    | select(.alias==$r or .agent_name==$r or .session_name==$r or .id==$r)
                    | select(.state=="active")] | length > 0' >/dev/null 2>&1; then
            log "  REUSE(gt-4st3n): $_DISPATCH_SESS_REF is now active (woke after ${_wake_i} probe(s))."
            break
          fi
          [ "$_wake_i" -lt "$_wake_max" ] && [ "${_wake_sleep:-0}" -gt 0 ] 2>/dev/null && sleep "$_wake_sleep"
        done
      else
        warn "Could not wake $_DISPATCH_SESS_REF — routed bead remains a durable hook; crew picks it up on next cycle."
      fi
    fi

    # ── ga-eu8vr: resilient sling with correct failure attribution ──────────────
    # The live gc binary (gc-patched-connfix) emits a CONSTANT benign warning on
    # stderr for EVERY invocation:
    #   WARN native_store_unavailable gate=version_compat reason="bd/beads version
    #        compatibility could not be confirmed"
    # It is present on success AND failure alike (verified 20/20), so it is NOT a
    # failure signal — the real sling error, when one occurs, is the structured
    # JSON on STDOUT. The prior code made a SINGLE attempt and, on an empty
    # bead_id, logged only STDERR (the benign warning), misattributing
    # intermittent, fast-failing sling-write blips to the warning and permanently
    # aborting the sweep. A sole-candidate P1 then stalled the whole backlog for
    # ~2.5h while the SAME sling op succeeded moments/sweeps later. Fix:
    #   (1) RETRY the sling — a transient empty bead_id is no longer fatal;
    #   (2) attribute failures to the REAL stdout error, probing store
    #       reachability so the benign version_compat warning is non-blocking.
    local _sling_err_file _sling_err _sling_attempt _sling_max _sling_sleep
    _sling_err_file="/tmp/pilot-sling-err.$$"
    _sling_max="${PILOT_SLING_RETRIES:-3}"
    _sling_sleep="${PILOT_SLING_SLEEP:-2}"
    SLING_OUT=""
    SLING_BEAD_ID=""
    _sling_attempt=0
    while [ "$_sling_attempt" -lt "$_sling_max" ]; do
      _sling_attempt=$((_sling_attempt + 1))
      SLING_OUT=$(gc --city "$GC_CITY" sling "$BUILDER_TARGET" \
        "$SLING_TITLE" \
        --json \
        2>"$_sling_err_file" || echo "{}")
      SLING_BEAD_ID=$(echo "$SLING_OUT" | jq -r '.bead_id // .id // empty' 2>/dev/null || echo "")
      [ -n "$SLING_BEAD_ID" ] && break
      if [ "$_sling_attempt" -lt "$_sling_max" ]; then
        log "  gc sling returned no bead_id for $STORY_ID (attempt ${_sling_attempt}/${_sling_max}) — retrying in ${_sling_sleep}s (version_compat warning is benign)"
        [ "${_sling_sleep:-0}" -gt 0 ] 2>/dev/null && sleep "$_sling_sleep"
      fi
    done
    # Keep only REAL stderr warnings — strip the constant benign version_compat line.
    _sling_err=$(grep -v 'native_store_unavailable gate=version_compat' "$_sling_err_file" 2>/dev/null | head -c 300 || echo "")
    rm -f "$_sling_err_file"

    DISPATCH_RESULT="sling_ok"

    # gt-q0hon: fail-hard if sling returned no bead ID — do NOT continue with
    # phantom state. ga-eu8vr: distinguish a transient sling-write failure (store
    # reachable → retry next sweep) from a genuine store outage, and report the
    # REAL stdout error — never the benign version_compat warning.
    if [ -z "$SLING_BEAD_ID" ]; then
      local _sling_real_err _store_ok
      _sling_real_err=$(echo "$SLING_OUT" | jq -r '.error.message // empty' 2>/dev/null | head -c 200 || echo "")
      [ -z "$_sling_real_err" ] && _sling_real_err="${_sling_err:-no stdout error}"
      _store_ok=0
      bd -C "$GC_CITY" list --limit 1 >/dev/null 2>&1 && _store_ok=1
      if [ "$_store_ok" = "1" ]; then
        warn "gc sling returned no bead_id for $STORY_ID after ${_sling_max} attempts — store ACCESSIBLE, transient sling-write failure; releasing claim, will retry next sweep (real-err: ${_sling_real_err}) [version_compat warning is benign, not the cause]"
      else
        warn "gc sling failed for $STORY_ID after ${_sling_max} attempts — store UNREACHABLE (real-err: ${_sling_real_err})"
      fi
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      DISPATCH_RESULT="sling_no_bead_id"
      return 1
    fi

    # gt-q0hon: post-sling Dolt verify — guard against phantom bead (hook set but bead
    # never committed to Dolt). Retry up to 3x with 2s gap for propagation lag.
    # SLING_BEAD_ID lives in GC_CITY (sling always creates task beads in HQ).
    local _verify_ok=0 _verify_i
    for _verify_i in 1 2 3; do
      if bd -C "$GC_CITY" show "$SLING_BEAD_ID" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0].id else .id end' >/dev/null 2>&1; then
        _verify_ok=1; break
      fi
      [ "$_verify_i" -lt 3 ] && sleep 2
    done

    if [ "$_verify_ok" = "0" ]; then
      warn "PHANTOM BEAD: gc sling returned $SLING_BEAD_ID but not found in Dolt after 3 attempts. Aborting dispatch for $STORY_ID (gt-q0hon)."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      DISPATCH_RESULT="sling_phantom_bead"
      return 1
    fi

    # ga-2azzj fix 3: record the slung builder task so TTL recovery can tell a
    # genuinely-stuck claim (sling task closed/gone) from an active long build
    # (sling task still open) and refuse to recycle the latter. Set now — before
    # finalization — so it survives even the degraded in-flight-unconfirmed path.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.sling_bead=$SLING_BEAD_ID" -q 2>/dev/null || true

    # ── Deliver the dispatch prompt ──────────────────────────────────────────
    # gt-4st3n: when reusing an existing crew session, deliver with `gc session
    # submit --intent follow_up` — a NON-INTERRUPTING, semantic submit. The
    # runtime queues it and the crew picks it up when it next goes idle, so we
    # never interrupt work the crew may be doing for Athos and never reset it.
    # The routed task bead (the HOOK) is the durable signal; this submit is the
    # ephemeral nudge. Target the resolved session ref (alias/id), not the bare
    # identity, so it lands on the SAME session we classified — never a 2nd one.
    # When spawning (no prior session), keep the legacy nudge to the identity.
    if [ "$_DISPATCH_REUSE" = "1" ]; then
      timeout 15 gc --city "$GC_CITY" session submit "$_DISPATCH_SESS_REF" "$DISPATCH_TASK" --intent follow_up \
        2>/dev/null \
        || warn "Could not submit to $_DISPATCH_SESS_REF — builder will see the task bead (hook) on next cycle"
    else
      timeout 15 gc --city "$GC_CITY" session nudge "$BUILDER_TARGET" "$DISPATCH_TASK" \
        2>/dev/null \
        || warn "Could not nudge $BUILDER_TARGET — builder will see the task bead on next hook cycle"
    fi

    log "Dispatch complete: sling_bead=$SLING_BEAD_ID target=$BUILDER_TARGET reuse=${_DISPATCH_REUSE} session_state=${_DISPATCH_SESS_STATE}"
  fi

  # ── Transition bead: lane tag + DURABLE story:in-flight (ga-2azzj fix 1) ──────
  # ORDER IS LOAD-BEARING. The candidate queries EXCLUDE story:in-flight; that
  # label is the ONLY thing that makes a slung bead non-re-dispatchable. So:
  #   1. lane tag (cosmetic accounting — non-fatal).
  #   2. add story:in-flight and VERIFY it stuck (read-after-write retry). This
  #      write is NOT swallowed — a slung-but-unmarked bead is the dangerous
  #      state that caused the ga-8nu8x double-dispatch.
  #   3. ONLY after in-flight is confirmed durable, remove the pilot:dispatching
  #      claim. (The old code removed the claim FIRST, then added in-flight with
  #      `|| true` — a transient Dolt blip or a set -e exit between the two left
  #      NEITHER marker, so the bead stayed re-dispatchable.)
  #   4. pilot:dispatched tag (cosmetic — non-fatal).
  # If in-flight cannot be confirmed (Dolt down): abort HARD and WARN, leaving
  # pilot:dispatching ON so TTL recovery — not a fresh sweep — owns the claim.
  # The builder is already slung; an unmarked re-dispatchable bead is worse than
  # a claim that TTL recovery cleans up once the sling task is closed.
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "lane:${LANE}" -q 2>/dev/null || true

    local _inflight_ok=0 _inflight_i=1
    local _inflight_retries="${PILOT_INFLIGHT_RETRIES:-5}"
    local _inflight_sleep="${PILOT_INFLIGHT_SLEEP:-2}"
    while [ "$_inflight_i" -le "$_inflight_retries" ]; do
      bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "story:in-flight" -q 2>/dev/null || true
      if bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0] else . end | (.labels // []) | any(. == "story:in-flight")' \
          >/dev/null 2>&1; then
        _inflight_ok=1; break
      fi
      [ "$_inflight_i" -lt "$_inflight_retries" ] && sleep "$_inflight_sleep"
      _inflight_i=$((_inflight_i + 1))
    done

    if [ "$_inflight_ok" = "0" ]; then
      err "DURABLE-INFLIGHT FAILED on $STORY_ID after ${_inflight_retries} attempts (Dolt down?). Builder '$BUILDER_TARGET' was ALREADY slung (bead=$SLING_BEAD_ID). Leaving pilot:dispatching ON so TTL recovery owns this claim; NOT releasing it (prevents 2nd-builder dispatch, ga-2azzj)."
      DISPATCH_RESULT="inflight_unconfirmed"
      mkdir -p "$(dirname "$PILOT_LOG")" 2>/dev/null || true
      jq -c -n \
        --arg ts "$NOW" --arg story_id "$STORY_ID" --arg builder "$BUILDER_TARGET" \
        --arg sling_bead "$SLING_BEAD_ID" --arg lane "$LANE" --arg tier "$DISPATCH_TIER" \
        '{ts:$ts, event:"pilot_dispatch_degraded", story_id:$story_id, builder:$builder,
          sling_bead:$sling_bead, lane:$lane, tier:$tier, result:"inflight_unconfirmed",
          note:"slung but story:in-flight unconfirmed; pilot:dispatching left on for TTL recovery"}' \
        >> "$PILOT_LOG" 2>/dev/null || true
      notify -t "⚠️ Pilot dispatch degraded" -p 4 \
        "$STORY_ID slung to $BUILDER_TARGET but story:in-flight unconfirmed (Dolt?). Claim left for TTL recovery — check pilot-dispatcher.log" \
        2>/dev/null || true
      return 1
    fi

    # in-flight is durable — NOW safe to release the claim and tag dispatched.
    bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$STORY_BEAD_CITY" label add    "$STORY_ID" "pilot:dispatched"  -q 2>/dev/null || true
    # ga-v3z4z: stamp the dispatch instant so the never-started detector can age
    # this bead from a dedicated clock, never updated_at (the ga-2azzj Defect-A
    # discipline). Written right next to the pilot:dispatched label so the two
    # always travel together: a dispatched bead carries the clock that decides
    # when an abandoned dispatch becomes re-dispatchable.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.dispatched_at=$(date +%s)" -q 2>/dev/null || true
    # Claim stamps are now moot (bead is in-flight, excluded from TTL query). Clear
    # them so a later re-dispatch (gate:needs-fix) starts from a clean slate.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true

    # ga-ms1jm: a SOURCE bead must NEVER carry gc.routed_to. The builder is
    # dispatched via the separate sling TASK bead created above — this source
    # bead is selected only by the Pilot's own tier/label queries, never by
    # routing. If any path (legacy sling-by-id, manual edit, future regression)
    # leaves gc.routed_to=<dog-pool> on this now-in-flight source bead, the dog
    # pool's engine ready-query (`bd ready --metadata-field gc.routed_to=...
    # --unassigned`, which does NOT exclude story:in-flight) would re-claim it →
    # double-dispatch, spawning a duplicate builder and pinning dog slots on
    # already-fixed work. The ga-zzrts guards above stop the PILOT re-dispatching;
    # this stops the DOG engine query re-claiming. Idempotent (no-op when absent);
    # || true keeps set -euo pipefail safe.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata gc.routed_to -q >/dev/null 2>&1 || true

    local DISPATCH_COMMENT
    if [ "$DISPATCH_TIER" = "bug" ]; then
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=bug/tech-debt, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: fix bug → /gate-done → autonomous gate+delivery → bead closed.
No human review required. SYSTEM QUALITY FIRST."
    else
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=feature, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: implement → /gate-done → autonomous gate+delivery → story:done.
No human review required."
    fi

    bd -C "$STORY_BEAD_CITY" comment "$STORY_ID" "$DISPATCH_COMMENT" \
      2>/dev/null || warn "Could not post dispatch comment to $STORY_ID"
  fi

  local DISPATCH_END_EPOCH ELAPSED_S
  DISPATCH_END_EPOCH=$(date +%s)
  ELAPSED_S=$((DISPATCH_END_EPOCH - DISPATCH_EPOCH))

  log "$DISPATCH_TIER [$LANE] $STORY_ID → story:in-flight (builder=$BUILDER_TARGET elapsed=${ELAPSED_S}s)"

  # ── Log to pilot-dispatcher.jsonl ───────────────────────────────────────────
  mkdir -p "$(dirname "$PILOT_LOG")"
  jq -c -n \
    --arg ts "$NOW" \
    --arg story_id "$STORY_ID" \
    --arg story_title "$STORY_TITLE" \
    --arg tier "$DISPATCH_TIER" \
    --arg lane "$LANE" \
    --arg rig "$STORY_RIG" \
    --arg builder "$BUILDER_TARGET" \
    --arg sling_bead "$SLING_BEAD_ID" \
    --arg result "$DISPATCH_RESULT" \
    --argjson priority "$STORY_PRIORITY" \
    --argjson elapsed_s "$ELAPSED_S" \
    --arg dry_run "$DRY_RUN" \
    '{ts: $ts, event: "pilot_dispatch", story_id: $story_id, story_title: $story_title,
      tier: $tier, lane: $lane, rig: $rig, builder: $builder, sling_bead: $sling_bead,
      result: $result, priority: $priority, elapsed_s: $elapsed_s, dry_run: $dry_run}' \
    >> "$PILOT_LOG" 2>/dev/null || true

  # ── Notify ───────────────────────────────────────────────────────────────────
  if [ "$DRY_RUN" = "1" ]; then
    local TIER_LABEL
    TIER_LABEL="$([ "$DISPATCH_TIER" = "bug" ] && echo "BUG/DEBT" || echo "feature")"
    notify -t "Pilot DRY-RUN" -p 1 \
      "Would dispatch $STORY_ID [$TIER_LABEL/$LANE] (P${STORY_PRIORITY}) → $BUILDER_TARGET [DRY_RUN]" \
      2>/dev/null || true
  else
    notify -t "✨ Pilot pegou uma história" -p 3 \
      "✨ $STORY_TITLE ($STORY_ID, P${STORY_PRIORITY}, lane=$LANE → $BUILDER_TARGET)" \
      2>/dev/null || true
  fi
}

# ── Step 4: Dispatch-to-capacity per lane (ga-rk5va) ──────────────────────────
# Fill EVERY free slot in each lane this sweep — not one pick per lane. After a
# drain this refills all 5 small slots in ONE sweep (~the user's "máxima lotação")
# instead of ~5 sweeps. Each lane is independent: a full big lane never blocks
# small dispatches. Caps (MAX_SMALL/MAX_BIG), dedup, and the per-bead atomic claim
# inside dispatch_one are all preserved, so a lane can never exceed its cap.
#
# Throttle (constraint a): when Dolt was SATURATED at sweep start, or the operator
# disabled the feature, each lane caps at a single dispatch (== legacy behavior —
# never adds load beyond the old code). Between dispatches we re-check Dolt CPU
# cheaply and bail the instant it crosses the ceiling, so dispatch-to-capacity
# can never WIDEN a wedged pipe (the fd-leak/CPU-incident class this guards).

DISPATCHED=0

# dispatch_lane <lane> <candidates_json> <free_slots>
# Loops pick→dispatch→remove until the lane is full or candidates are exhausted.
# Mutates the global DISPATCHED (NOT via command-substitution — the script's
# top-level `exec >> LOG 2>&1` means $(...) would swallow dispatch_one's log lines).
dispatch_lane() {
  local lane="$1" pool="$2" slots="$3"
  local cap="$slots"
  # Constraint a: saturated-at-start OR feature disabled → throttle to 1 (legacy).
  if [ "$DISPATCH_TO_CAPACITY" != "1" ] || [ "${PILOT_DOLT_SATURATED_AT_START:-0}" = "1" ]; then
    cap=1
  fi

  # Hard iteration ceiling: at most one attempt per candidate plus a small margin.
  # Defense-in-depth so a (near-impossible) jq pool-removal failure — which would
  # otherwise let a perpetually-skipping pick be re-tried forever — can never spin.
  local _iter=0 _iter_max
  _iter_max=$(( $(echo "$pool" | jq 'length' 2>/dev/null || echo "0") + 2 ))

  local filled=0
  while [ "$filled" -lt "$cap" ] && [ "$slots" -gt 0 ]; do
    _iter=$((_iter + 1))
    if [ "$_iter" -gt "$_iter_max" ]; then
      warn "Lane $lane: iteration guard hit (${_iter}>${_iter_max}) — stopping loop (pool-removal anomaly?)."
      break
    fi
    local n
    n=$(echo "$pool" | jq 'length' 2>/dev/null || echo "0")
    [ "${n:-0}" -le 0 ] 2>/dev/null && break

    local pick pick_id
    pick=$(_top_candidate "$pool")
    { [ -z "$pick" ] || [ "$pick" = "null" ]; } && break
    pick_id=$(echo "$pick" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$pick_id" ] && break

    # Remove from the IN-MEMORY pool BEFORE dispatch: a skipped pick (lost claim,
    # builder-mutex defer, race) must not be re-picked (no infinite loop), and
    # DRY_RUN — which makes zero state changes — still advances through the pool.
    pool=$(echo "$pool" | jq --arg id "$pick_id" '[.[] | select(.id != $id)]' 2>/dev/null || echo "$pool")

    # wa-tm2a: derive the tier from THIS bead's own type (the pool is mixed), so a
    # story gets the "build story" template and a bug gets "fix bug" — independent
    # of what else is in the pool this sweep.
    local pick_tier
    pick_tier=$(_bead_tier "$pick")

    # Only a SUCCESSFUL dispatch consumes a slot; a skip leaves the slot free and
    # simply moves to the next candidate. dispatch_one is the atomic-claim owner.
    if dispatch_one "$pick" "$lane" "$pick_tier"; then
      filled=$((filled + 1))
      slots=$((slots - 1))
      DISPATCHED=$((DISPATCHED + 1))
    fi

    # Mid-loop Dolt backoff (constraint a): if work remains, re-check the cheap CPU
    # signal and stop the moment Dolt is hot, so we never drive a saturated server.
    if [ "$filled" -lt "$cap" ] && [ "$slots" -gt 0 ]; then
      local _more
      _more=$(echo "$pool" | jq 'length' 2>/dev/null || echo "0")
      if [ "${_more:-0}" -gt 0 ] 2>/dev/null && _dolt_saturated; then
        warn "Dolt saturated mid-sweep (cpu=$(_dolt_cpu)% lat=${DOLT_LATENCY_MS:-?}ms) — stopping $lane loop after ${filled} dispatch(es) (ga-rk5va backoff)."
        break
      fi
    fi
  done

  log "Lane $lane: dispatched ${filled} this sweep (cap=${cap}, slots_left=${slots})."
}

# Small + big lanes are independent. Dispatch the full pool for each (the loop is
# a no-op when a lane has no slots or no candidates).
if [ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ]; then
  dispatch_lane "small" "$SMALL_CANDIDATES" "$SMALL_SLOTS"
fi

if [ "$BIG_SLOTS" -gt "0" ] && [ "$BIG_COUNT" -gt "0" ]; then
  dispatch_lane "big" "$BIG_CANDIDATES" "$BIG_SLOTS"
fi

if [ "$DISPATCHED" -eq "0" ]; then
  log "No dispatches this sweep (lane slots may have been won by a concurrent process, or all picks skipped)."
fi

log "=== Pilot sweep complete: dispatched=$DISPATCHED (small_slots=$SMALL_SLOTS big_slots=$BIG_SLOTS dolt_saturated_at_start=${PILOT_DOLT_SATURATED_AT_START:-0}) ==="
