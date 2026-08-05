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

# ── wa-worker spawn cap (ga-v3o6i runaway fix) ────────────────────────────────
# Max concurrent live (active + creating) wa-worker sessions. Mirrors the agent's
# max_active_sessions=4. Before spawning, Pilot counts live sessions via `gc
# session list`; if >= cap, it skips the spawn and relies on the supervisor
# reconciler to start a session once a slot is free. This prevents the runaway
# that spawned 39 sessions when earlier sweeps' workers hadn't drained yet.
# Override via plist env or test seam: PILOT_WA_WORKER_MAX=4
PILOT_WA_WORKER_MAX="${PILOT_WA_WORKER_MAX:-4}"
# TEST-ONLY seam: when set, overrides the live `gc session list` count.
# Format: a raw integer (e.g. "0" = pool empty, "4" = pool full).
PILOT_TEST_WA_WORKER_LIVE_COUNT="${PILOT_TEST_WA_WORKER_LIVE_COUNT:-}"
# ps-worker ephemeral pool cap (mirror of wa-worker; property_scrapers rig).
PILOT_PS_WORKER_MAX="${PILOT_PS_WORKER_MAX:-2}"
# TEST-ONLY seam: override live gc session list count for ps-worker pool.
PILOT_TEST_PS_WORKER_LIVE_COUNT="${PILOT_TEST_PS_WORKER_LIVE_COUNT:-}"

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

# ── Owner-grace for never-started release (ga-mfeip in-flight pileup) ──────────
# The live-crew-owner guard below (ga-9yb5s) KEEPS any bead whose story.assignee is a
# live named crew — it assumes "owner alive == actively building this bead". But the
# rig ctx:ready dispatch ASSIGNS + marks story:in-flight on a busy crew that may never
# pick the bead up (declined operational/blocked work, or a queue it never drains).
# Such a bead has NO branch yet sits story:in-flight forever, inflating the in-flight
# count / painel (12 WA beads, 0 branches — wa-zybp 41h). After a generous OWNER GRACE
# window, release a still-branchless owned bead ONLY when the owner has DEMONSTRABLY
# progressed elsewhere (pushed branches for OTHER beads since this one's dispatch) — i.e.
# the crew is working but SKIPPED this bead, so it was declined, not slow-built. Without
# that proof we KEEP (a genuinely slow build that hasn't branched yet is never reclaimed).
# Conservative by construction: 24h default, dual-signal, fail-safe to KEEP.
PILOT_NEVERSTARTED_OWNER_GRACE_HOURS="${PILOT_NEVERSTARTED_OWNER_GRACE_HOURS:-24}"

# ── Phantom-claim guard threshold (FOLLOW-UP #1, ga-9yb5s+) ──────────────────
# How long a crew-assigned bead may sit with NO branch before it is treated as a
# phantom claim (crew took the assignee slot but never started). Default 2700 = 45min.
# A branch OR a fresh updated_at (within this window) always overrides the threshold.
PILOT_PHANTOM_STALE_SECS="${PILOT_PHANTOM_STALE_SECS:-2700}"

# ── Mayor out-of-band hold grace window (ga-pd7j) ────────────────────────────
# Pilot auto-redispatches any gate:needs-fix bead once no pilot:held/held-until
# label is present. But the Mayor's hold-disposition comment can land moments
# AFTER Pilot's candidate snapshot and BEFORE the pilot:held label is stamped
# (ga-z6uo/ga-06um: dispatch fired 16:30:34Z, Mayor's comment landed 16:32:16Z,
# no label yet — a diligent dog self-corrected that time, but Pilot itself raced
# the hold). Default 300 = one sweep interval (Pilot runs every ~300s), matching
# the bug's own "defer one cycle" fix direction: a gastown__mayor comment newer
# than this is grounds to skip dispatch for THIS sweep only, not to hold forever.
PILOT_MAYOR_HOLD_GRACE_SECS="${PILOT_MAYOR_HOLD_GRACE_SECS:-300}"

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
#   (a) a branch `origin/crew/*/<bead-id>` OR `origin/fix/<bead-id>-*` ALREADY
#       EXISTS in the bead's rig repo (the STRONGEST signal: code was pushed for
#       this bead → a build happened / is happening → never start a second
#       builder elsewhere — ga-6jqr closed the fix/* blind spot: dog builders
#       push fix/<bead>-<slug>, not crew/*/<bead>), OR
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

# ── ga-8jxe1: branch-exists ≠ in-flight (ownership guard signal (a) refinement) ─
# Bug ga-8jxe1: signal (a) above treated "a crew/fix branch exists" as an
# unconditional, permanent in-flight signal. Two real cases (fix/ga-opyus-...,
# fix/ga-50m2-...) proved that assumption false: both branches were ABANDONED —
# 1 real commit each, last touched 3 and 12 days ago, bead unassigned, no live
# session — yet the guard vetoed every sweep forever (branch existed → veto →
# nobody works it → branch still exists → veto...). The code comment that
# introduced (a) explicitly delegated recovery to "the distinct dead-worker/
# never-started reclaim paths" — those paths only examine story:in-flight
# beads, and a ready/unassigned candidate with a stray old branch is outside
# their domain, so nothing ever actually recovered it.
# How long an UNMERGED matched branch may sit with no new commits before its
# bead (candidate query already guarantees it's unassigned) is treated as
# ABANDONED rather than "in-flight, just hasn't pushed lately." The two real
# cases sat 3 and 12 days; 48h is comfortably inside that margin while safely
# outside any normal single build — and "branch recente... continua vetando"
# (a RECENT unmerged branch, regardless of assignee) is preserved exactly:
# only a branch OLDER than this threshold is even eligible to be an orphan.
PILOT_ORPHAN_BRANCH_STALE_HOURS="${PILOT_ORPHAN_BRANCH_STALE_HOURS:-48}"

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
#   wa = whatsapp_automation (wa-worker pool — ephemeral; 4 virtual slots wa-worker-1..4)
#   ps = property_scrapers  (batista-ps)
#   ma = marketing
#   hq = gastown-hq         (system/infra agents)
# rig_to_builders <rig> — print the rig's ORDERED builder POOL (space-separated).
# A rig with >1 interchangeable single-identity crew is a POOL: the dispatcher
# distributes work across its members (ga-mtlm6) instead of piling every bead on
# one. Pool order is the dispatch preference (first-eligible wins). Single-member
# rigs are a pool of one — behaviourally identical to the pre-ga-mtlm6 routing.
#
# pilot-rewire: WA now uses 4 VIRTUAL SLOTS (wa-worker-1..4) instead of named crews.
# Each slot maps to the wa-worker agent template via wa_worker_template(). PILOT_USED_BUILDERS
# tracks slots so up to 4 WA beads can dispatch in one sweep (one per slot). The actual
# sling/assign/nudge target is always "wa-worker" (the template), never a slot name.
rig_to_builders() {
  local rig="$1"
  case "$rig" in
    gascity)               echo "gastown.dog"                                  ;;
    whatsapp_automation|wa) echo "wa-worker-1 wa-worker-2 wa-worker-3 wa-worker-4" ;;
    property_scrapers|ps)  echo "ps-worker"                                    ;;
    gastown|gt)            echo "gastown.dog"                                  ;;
    lexbh|lx)              echo "gastown.dog"                                  ;;
    marketing|ma)          echo "gastown.dog"                                  ;;
    *)                     echo "gastown.dog"                                  ;;
  esac
}

# rig_to_builder <rig> — back-compat single target: the first builder of the pool.
rig_to_builder() {
  set -- $(rig_to_builders "$1")
  echo "${1:-gastown.dog}"
}

# wa_worker_template <slot> — map a wa-worker-N pool slot to the actual agent template.
# Pool slots (wa-worker-1..4) are virtual identities used ONLY for PILOT_USED_BUILDERS
# tracking so distinct slots can be used in one sweep. The real agent template is
# "wa-worker"; `gc session nudge` and `bd update --assignee` must use this name.
# For any non-wa-worker identity, the identity itself is returned unchanged.
wa_worker_template() {
  case "$1" in
    wa-worker-[0-9]*) echo "wa-worker" ;;
    *)                echo "$1"        ;;
  esac
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
  # real-estate BEFORE data: property enrichment carries "enrichment" (a data keyword) but
  # is a real-estate build (ArcGIS/zoneamento/ITBI/quarteirão/imóvel) owned by peter-wa,
  # NOT oracle (warming) or thies (satmap visual layer only). This is the wa-nvn9/wa-o65d
  # round-robin-to-oracle loop oracle hit, and the wa-nvn9 misroute-to-thies when peter was
  # human-engaged.
  if printf '%s' "$hay" | grep -iqE 'arcgis|zoneamento|geometria|geo-?match|quarteir|cadastr|\bitbi\b|[ií]ndice cadastral|im[oó]ve(l|is)|funil[ _-]?im[oó]vel|deals?.*(fora de bh|im[oó]ve)'; then
    echo "real-estate"; return 0
  fi
  if printf '%s' "$hay" | grep -iqE 'warming|warm-?up|aquecimento|\bchip(s)?\b|ban-?prevention|ban-?risk|on-?device send|group-?send'; then
    echo "warming"; return 0
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
    whatsapp_automation/data|wa/data)               echo "digo-wa"   ;;
    whatsapp_automation/real-estate|wa/real-estate) echo "peter-wa"  ;;
    whatsapp_automation/warming|wa/warming)         echo "oracle-wa" ;;
    *)                                              echo ""          ;;
  esac
}

# rig_domain_exclude <rig> <domain> — space-separated crew KNOWN NOT to own this
# domain in this rig (dropped from the pool for a bead of that domain), or "".
# Used when the positive owner isn't mapped yet but a WRONG owner is known — e.g.
# WA frontend: we don't yet have a named frontend owner, but we DO know digo-wa
# (data/email/financeiro) is not it, so frontend work must never land on digo.
rig_domain_exclude() {
  case "$1/$2" in
    whatsapp_automation/frontend|wa/frontend)       echo "digo-wa" ;;
    whatsapp_automation/real-estate|wa/real-estate) echo "oracle-wa digo-wa thies-wa" ;;
    whatsapp_automation/warming|wa/warming)         echo "digo-wa mila-wa peter-wa thies-wa" ;;  # warming → SÓ oracle-wa (dono) ou DEFER; nunca mila/digo (ga-wisp-jmrn5q)
    *)                                              echo ""        ;;
  esac
}

# rig_domain_requires_persistent_owner <rig> <domain> — true (0) iff this
# domain's work STRUCTURALLY cannot run on a disposable ephemeral pool worker
# and must go to its rig_domain_owner crew directly instead. WA warming/
# on-device chip management needs a live, continuous device/session that a
# fresh headless wa-worker cannot hold — Athos's 2026-07-17 decision that
# oracle-wa is the executor for this domain (ga-uvfs6: wa-srgv/wa-ys0cy were
# misrouted to the generic wa-worker pool and refused there in a loop).
# DELIBERATELY NARROW/allowlist-only: rig_domain_owner ALSO maps data→digo-wa
# and real-estate→peter-wa, but per pilot-dispatcher.selftest.sh Scenario 17b
# ("pilot-rewire: domain prefer for digo-wa is now a no-op") those are
# intentionally pool-routed — ordinary code builds the wa-worker pool is
# designed to absorb. Do not add a domain here without an explicit Athos/
# Mayor decision that it is likewise structurally pool-incompatible.
rig_domain_requires_persistent_owner() {
  case "$1/$2" in
    whatsapp_automation/warming|wa/warming) return 0 ;;
    *)                                      return 1 ;;
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
  # ga-l5ud0 FIX #1: strip launchd bundle-ID tokens (e.g. "com.whatsapp.peter-predeploy-check",
  # "com.gascity.pilot-dispatcher") from the haystack BEFORE any domain regex fires.
  # A launchd bundle-ID is an infra/config reference, NOT a domain-content signal — it names a
  # daemon, not the work's subject. Without this strip, a bead about repointar peter's plist
  # contains "com.whatsapp.peter-predeploy-check" and the bare `whatsapp` substring falsely wins
  # the WA-INTEGRATION PRECEDENCE check below, routing a peter/infra bead to mila-wa.
  # Pattern: com.<word>.<word...> — matches dotted reverse-DNS bundle IDs only.
  # BSD sed: use -E for extended regex; the substitution is global (/g).
  # FAIL-OPEN: if sed fails (never observed), hay is left intact — same as pre-fix behaviour.
  hay=$(printf '%s' "$hay" | sed -E 's/com\.[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_.-]+)+//g' 2>/dev/null || printf '%s' "$hay")
  # WA-INTEGRATION PRECEDENCE (ga-lt8cw/ga-nq64a, 2026-06-19; +painel/kanban 2026-06-22):
  # the WA orchestration/integration layer — pipedrive deals, whapi/whatsapp messaging, the
  # urblink PAINEL (painel.urblink.com.br: kanban, filter pills, dashboards), and the Drive
  # bridges that TRIGGER an existing Hex notebook — CONSUMES property data, so its beads carry
  # property nouns (imóvel/ITBI/Hex/CNPJ) AND counting words ("contagem") too. Without this
  # guard the property check below wins on first-match and the build misroutes to
  # property_scrapers (batista-ps circuit-breaks → re-dispatch loop — ga-wm12t "multi-rig
  # kanban ... com contagem" hit exactly this). painel/kanban/filter-pills NEVER occur in a
  # genuine property data-build (scrape/consolidate/classify), so they safely precede it.
  # The painel UI is mila's (WA) domain; property_scrapers builds the SCRAPERS, not the UI.
  # Narrow on purpose: "drive bridge" (the WA itbi_drive_bridge) not bare "Hex"; "painel"/
  # "kanban"/"filter pills" not bare "dashboard" (a Hex-notebook dashboard stays property).
  if printf '%s' "$hay" | grep -iqE 'pipedrive|whapi|whatsapp|urblink_design_system|drive[_ ]bridge|\bpainel\b|painel\.urblink|\bkanban\b|filter[ -]?pills'; then
    echo "whatsapp_automation"; return 0
  fi
  # property_scrapers domain (the recurring misroute family).
  if printf '%s' "$hay" | grep -iqE 'scraper|scrape|\bcadastro\b|cadastr[ao]|\bITBI\b|\bRFB\b|receita federal|\bCNAE\b|\bCNPJ\b|\bPBH\b|motherduck|\bHex\b|hex notebook|geocod|georreferenc|lat[ -/]?lon|point-in-polygon|pesquisa_mercado|propriet[áa]ri|\bim[óo]vel\b|\bim[óo]veis\b|\blote\b|\blotes\b|\bterreno\b|terreno_livre|cart[óo]rio|matr[íi]cula|incorpora|índice cadastral|indice cadastral|mega_data_set|mega data set'; then
    echo "property_scrapers"; return 0
  fi
  # whatsapp_automation domain features authored as HQ (ga-) beads.
  # ga-r4jnu/ga-zfe51: word-boundary "disparo(s)" — bare substring matching also hit
  # "disparou"/"disparar"/"disparando" (ordinary Portuguese verb forms meaning "fired/
  # triggered", ubiquitous in ops prose: "o watchdog disparou", "dispara em description
  # vazia"). Audited: EVERY historical match of dispar* across this HQ's bead corpus
  # (open + closed) was this false cognate, never the genuine WA noun ("disparo de
  # mensagem"). \b on both sides keeps the real signal, drops the verb collision.
  if printf '%s' "$hay" | grep -iqE '\bpainel\b|whatsapp|\bwhapi\b|pipedrive|urblink_design_system|design[ -]system|painel-hist|kanban hist|\bfrota\b|\bcanais\b|\bcanal\b de alerta|\bdisparos?\b|envio de mensagem'; then
    echo "whatsapp_automation"; return 0
  fi
  echo ""
}

# ── ga-j0f6: beads-repo bug-fix doctrine gap ──────────────────────────────────
# A bug/feature whose fix target is the beads CLI's own repo (/Users/athos/gt/beads,
# fork athosmartins/beads, upstream gastownhall/beads) is NOT a registered gc rig
# (`gc rig list` never returns "beads") and has no /gate-done path — a branch
# pushed there is invisible to the gate (STORY_RIG defaults to "gascity" for any
# unrecognized bead-ID prefix, and the gate only ever looks inside registered rig
# roots). The REAL, already-established convention for this class of fix is:
# commit in the beads checkout, push to the fork remote, gh pr create against
# upstream — a PR that awaits HUMAN review/merge, not an autonomous gate. Without
# this detector the normal "No human review required" doctrine text is dispatched
# verbatim, which is actively false and risks a builder treating an open,
# unreviewed upstream PR as done (concrete instance: ga-clgh/ga-svyw/PR #4865).
#
# bead_targets_beads_repo <bead_json> — "1" when the bead's own text names the
# beads CLI repo as its fix target, else "" (fail-open: no signal → normal
# doctrine, unchanged from pre-fix behaviour). Keyword-only (mirrors
# bead_content_rig/bead_domain above) since "beads" has no registered rig root to
# path-probe against. Deliberately narrow: explicit repo names/paths only, never
# bare "bd"/"beads" — those appear constantly in unrelated bug text (bd commands,
# bead terminology) and would false-positive on nearly every bug in this file.
bead_targets_beads_repo() {
  local bead="$1" hay
  hay=$(echo "$bead" | jq -r '
      [ (.title // ""), (.description // ""),
        ((.labels // []) | join(" ")) ] | join("  ")
    ' 2>/dev/null || echo "")
  [ -z "$hay" ] && { echo ""; return 0; }
  # ga-yn5w8: added bd-binary-separate-from-gascity-engine — the HQ memory slug
  # that IS the beads-CLI/gascity-engine distinction, cited verbatim by bugs
  # that describe the beads-repo symptom in "bd binary" terms instead of
  # naming the repo. Same false-positive profile as the six literals above:
  # a specific, narrow, stable compound string, not a bare "bd"/"beads" mention.
  if printf '%s' "$hay" | grep -iqE 'steveyegge/beads|gastownhall/beads|athosmartins/beads|\bgt/beads\b|\bbeads repo\b|\bbeads-repo\b|\bbd-binary-separate-from-gascity-engine\b'; then
    echo "1"; return 0
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
    whatsapp_automation|wa) echo ""           ;;  # WA uses the pool (wa-worker), not a named-crew domain default — no spurious pilot:held
    *)                      echo ""           ;;
  esac
}

# ── ga-xzfl: PATH-authoritative rig inference (the router-sabotages-itself bug) ─
# ROOT: rig inference uses KEYWORDS (bead_content_rig/bead_domain), so a bead ABOUT
# the routing machinery — cites packs/town-deltas/assets/pilot-dispatcher.sh +
# scripts/auto-rehome-janitor.py, mentions "scraper"/"property_scrapers" in prose —
# is keyword-classified property_scrapers and mis-dispatched to batista-ps, which
# cannot build framework files → NEVERSTART. The file PATHS a bead names are far
# more authoritative than the words it uses. These helpers extract those paths and
# map them to the owning rig. Everything here is FAIL-OPEN, ADDITIVE and KNOB-GATED
# (PILOT_PATH_RIG_GUARD / PILOT_MISSING_FILE_GUARD, default-on): no path signal ⇒ the
# existing keyword/owner/explicit routing runs byte-for-byte unchanged.

# _bead_path_haystack <bead_json> — the title+desc+criteria+story.*+labels blob used
# for path extraction, with URLs stripped so a hostname (painel.urblink.com.br/…) is
# never mistaken for a repo path. FAIL-OPEN: jq error → "".
_bead_path_haystack() {
  local bead="$1" hay
  hay=$(echo "$bead" | jq -r '
      [ (.title // ""), (.description // ""),
        (.acceptance_criteria // .metadata["story.criterios"] // ""),
        (.metadata["story.o_que_e"] // ""), (.metadata["story.resumo"] // ""),
        (.metadata["story.dependencias"] // ""), (.metadata["story.notebook"] // ""),
        ((.labels // []) | join(" ")) ] | join("  ")
    ' 2>/dev/null || echo "")
  [ -z "$hay" ] && { printf ''; return 0; }
  printf '%s' "$hay" | sed -E 's#https?://[^[:space:]]*##g' 2>/dev/null || printf '%s' "$hay"
}

# bead_cited_paths <bead_json> — echo the concrete file paths a bead names, one per
# line (deduped). A "concrete path" is a slash-joined token ending in a known code/
# config extension (.py/.sh/.toml/…). Empty when none. Used by the missing-file guard
# to probe whether a routed rig actually contains the files the bead is about.
# FAIL-OPEN: any jq/grep error or no match → "".
bead_cited_paths() {
  local bead="$1" hay out
  hay=$(_bead_path_haystack "$bead")
  [ -z "$hay" ] && { printf ''; return 0; }
  out=$(printf '%s' "$hay" \
        | grep -oE '\.?[A-Za-z0-9_-]+(/[A-Za-z0-9_.-]+)+' 2>/dev/null \
        | grep -iE '\.(py|sh|js|ts|tsx|jsx|toml|md|json|ya?ml|sql|txt|cfg|ini|go|rb|html|css|plist|conf)$' 2>/dev/null \
        | sort -u 2>/dev/null || true)
  printf '%s' "$out"
}

# bead_cited_basenames <bead_json> — echo BARE filenames (no directory) a bead names,
# one per line (deduped): a known code/config extension with NO slash anywhere in the
# token. ga-hn3kh: bead_cited_paths requires a slash, so a bead that names a real script
# by filename alone (e.g. "root-class-count.sh", never "scripts/root-class-count.sh")
# extracts NO candidate at all — the ga-zzqza HQ-only-path check then has nothing to
# probe and silently no-ops, even when the file is genuinely HQ-exclusive. This is the
# companion extractor _rig_has_any_basename consumes.
# The token may contain INTERIOR dots, and the extension is everything after the LAST
# one — '(\.[A-Za-z0-9_-]+)+' consumes the whole dotted run so a name like
# "pilot-dispatcher.selftest.sh" is captured whole and the whitelist below sees the REAL
# final extension "sh" (a single '\.[A-Za-z0-9]+' segment would stop at "selftest",
# which then fails the whitelist and silently drops the candidate — the *.selftest.sh /
# *.spec.ts / *.test.js convention is pervasive in this repo, including this dispatcher's
# own selftest file). Non-file noise still gets filtered because the whitelist anchors on
# that last segment: "0.5.0", "v22.17.0", "e.g", "painel.urblink.com.br" all fail it.
# FAIL-OPEN: any jq/grep error or no match → "".
bead_cited_basenames() {
  local bead="$1" hay out
  hay=$(_bead_path_haystack "$bead")
  [ -z "$hay" ] && { printf ''; return 0; }
  out=$(printf '%s' "$hay" \
        | grep -oE '\b[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\b' 2>/dev/null \
        | grep -iE '\.(py|sh|js|ts|tsx|jsx|toml|md|json|ya?ml|sql|txt|cfg|ini|go|rb|html|css|plist|conf)$' 2>/dev/null \
        | sort -u 2>/dev/null || true)
  printf '%s' "$out"
}

# bead_path_rig <bead_json> — infer the OWNING RIG from the FILE PATHS a bead names.
# Prints one of:
#   gascity              — an UNAMBIGUOUS HQ/framework path (packs//skills//agents//
#                          .claude//city.toml/pack.toml/town-deltas), OR an ambiguous
#                          scripts/ path when the bead carries NO product-content
#                          keyword. Consumed by the framework-dog-exempt (below) which
#                          clears the rig so the bead fails OPEN to the dog pool.
#   whatsapp_automation  — a WA-owned path: crew/<*-wa>/, outreach/, painel/, shared/.
#   property_scrapers    — a PS-owned path: crew/<*-ps>/, scrapers/.
#   ""                   — no path signal → caller leaves routing UNCHANGED (fail-open).
# scripts/ is INTENTIONALLY treated as ambiguous: it is a top-level dir in HQ *and*
# property_scrapers *and* whatsapp_automation (verified via git ls-files), so a bare
# scripts/ citation only implies gascity when no product keyword is present — otherwise
# a product script (e.g. scripts/itbi_drive_bridge.py, a WA file — Scenario 18h) would
# be wrongly force-routed to the dog. First match wins; framework paths win over
# product paths (a bead touching packs/ IS framework even if it also names outreach/).
bead_path_rig() {
  local bead="$1" hay _crew
  hay=$(_bead_path_haystack "$bead")
  [ -z "$hay" ] && { echo ""; return 0; }
  # (1) UNAMBIGUOUS HQ/framework paths (do NOT exist in any product rig).
  if printf '%s' "$hay" | grep -qE '(^|[^[:alnum:]._/-])(packs|skills|agents)/|(^|[^[:alnum:]._/-])\.claude/|(city|pack)\.toml|town-deltas' 2>/dev/null; then
    echo "gascity"; return 0
  fi
  # (2) crew/<name>/ → owning rig by crew-name suffix (mirror the *-wa/*-ps owner map).
  _crew=$(printf '%s' "$hay" | grep -oE '(^|[^[:alnum:]._/-])crew/[A-Za-z0-9._-]+' 2>/dev/null | grep -oE 'crew/[A-Za-z0-9._-]+' 2>/dev/null | sed -E 's#^crew/##' 2>/dev/null | head -1 || true)
  if [ -n "$_crew" ]; then
    case "$_crew" in
      *-wa|*-wa-*|whatsapp_automation*|wa-worker*) echo "whatsapp_automation"; return 0 ;;
      *-ps|*-ps-*|property_scrapers*|ps-worker*)   echo "property_scrapers";   return 0 ;;
    esac
  fi
  # (3) WA-domain product paths. outreach//painel/ are WA concepts absent from
  #     property_scrapers. shared/ is DELIBERATELY EXCLUDED (ga-xzfl review FINDING 3):
  #     it exists on disk in BOTH whatsapp_automation AND property_scrapers, so a shared/
  #     citation is AMBIGUOUS and must fall through to owner/content, never force WA.
  if printf '%s' "$hay" | grep -qE '(^|[^[:alnum:]._/-])(outreach|painel)/' 2>/dev/null; then
    echo "whatsapp_automation"; return 0
  fi
  # (4) property_scrapers product path (scrapers/ is a PS-exclusive top-level dir).
  if printf '%s' "$hay" | grep -qE '(^|[^[:alnum:]._/-])scrapers/' 2>/dev/null; then
    echo "property_scrapers"; return 0
  fi
  # (5) DELIBERATELY NO bare-scripts/ rule (ga-xzfl review FINDING 1): scripts/ is a top-level
  #     dir in HQ *and* property_scrapers *and* whatsapp_automation, so a bare scripts/ citation
  #     is too ambiguous to name a rig. Forcing gascity here overrode the ga-nlh79 owner signal
  #     — a *-wa/*-ps/-worker-owned scripts/ bead with no product keyword got dogged → NEVERSTART.
  #     So we return "" and let the owner-authoritative/content inference below decide. (A
  #     scripts/-only bead with no owner and no keyword still reaches the dog via bead_content_rig="".)
  echo ""
}

# _rig_has_any_path <rig> <newline-or-space-separated-paths> — return 0 (true) when the
# bead cites no paths, when the rig root is unknown/off-disk, or when at least ONE cited
# path exists in the rig's repo. Return 1 (false) ONLY when the rig root is known AND
# NONE of the cited paths exist there. So `! _rig_has_any_path …` fires only on a
# confident "this rig is missing every file the bead names". Test seam:
# PILOT_TEST_RIG_HAS_FILE ("1"=treat all present, "0"=treat all absent). FAIL-OPEN.
_rig_has_any_path() {
  local _rig="$1" _paths="$2" _root _p _rc
  [ -z "$_paths" ] && return 0
  # Test seam: PILOT_TEST_RIG_HAS_FILE, when non-empty, forces the verdict:
  #   "1"            → every rig has the files;  "0" → NO rig has them (create-file);
  #   "<rig> [rig…]" → only the listed rigs have them (per-rig, for mislocation tests).
  # Empty/unset ⇒ seam inactive ⇒ real probe (a harness passing it through as "" never
  # accidentally arms the guard).
  if [ -n "${PILOT_TEST_RIG_HAS_FILE:-}" ]; then
    case "$PILOT_TEST_RIG_HAS_FILE" in
      1) return 0 ;;
      0) return 1 ;;
      *) case " $PILOT_TEST_RIG_HAS_FILE " in *" $_rig "*) return 0 ;; *) return 1 ;; esac ;;
    esac
  fi
  _root=$(rig_root_path "$_rig" 2>/dev/null || echo "")
  [ -z "$_root" ] && return 0
  [ -d "$_root" ] || return 0
  for _p in $_paths; do
    [ -z "$_p" ] && continue
    # FINDING 4: NEVER conflate a probe FAILURE with "file absent". git ls-files
    # --error-unmatch exits 0=tracked, 1=cleanly-not-tracked; anything else (124 timeout,
    # 128 not-a-repo, 127 no-git, spawn error) is a PROBE FAILURE ⇒ fail-OPEN (present).
    _rc=0; timeout 5 git -C "$_root" ls-files --error-unmatch -- "$_p" >/dev/null 2>&1 || _rc=$?
    case "$_rc" in
      0) return 0 ;;                          # tracked → present
      1)
        # ga-hn3kh: a path under .gc/ is NEVER genuine rig-owned content — every rig gets
        # a RUNTIME MIRROR of the HQ scripts/skills/agents tree at <rig>/.gc/ (verified:
        # whatsapp_automation/.gc/scripts/root-class-count.sh is a byte-identical, UNTRACKED
        # copy of the HQ canonical scripts/root-class-count.sh). The raw disk-fallback below
        # would treat that mirror copy as "whatsapp_automation has this file", defeating the
        # ga-zzqza HQ-only-path check for any bead whose cited path collides with a mirrored
        # relative form. Skip the disk-fallback rescue for a .gc/-rooted candidate; git-tracked
        # .gc/ content (if it ever existed) is still honored above via the ls-files check, so
        # this only removes the untracked-mirror false positive, not genuine tracked content.
        case "$_p" in
          .gc/*|*/.gc/*) : ;;
          *) [ -e "$_root/$_p" ] && return 0 ;;   # cleanly not tracked → check disk
        esac
        ;;
      *) return 0 ;;                          # probe FAILED → fail-open (present, never refuse)
    esac
  done
  return 1  # every cited path is CLEANLY absent (not tracked AND not on disk)
}

# _rig_has_any_basename <rig> <newline-or-space-separated-filenames> — return 0 (true)
# when the bead cites no bare filenames, when the rig root is unknown/off-disk, or when
# at least one cited filename matches the BASENAME of some file GIT-TRACKED anywhere in
# the rig's repo. Return 1 (false) ONLY when the rig root is known AND none of the cited
# filenames match any tracked basename. ga-hn3kh companion to _rig_has_any_path: a bare
# filename (no directory) can't be checked via a pathspec — it has no path to match — so
# this does a basename search over `git ls-files` instead of `ls-files --error-unmatch`.
# DELIBERATELY git-tracked-only, no disk-fallback: unlike a full relative path (where an
# untracked-but-on-disk hit is plausibly a just-created file), a bare-filename disk walk
# would need a recursive search and would resurrect the exact untracked-mirror problem
# this guard exists to close (every <rig>/.gc/ mirror would match by basename on disk).
# Test seam: PILOT_TEST_RIG_HAS_FILE (same contract as _rig_has_any_path). FAIL-OPEN.
_rig_has_any_basename() {
  local _rig="$1" _names="$2" _root _n _list _grc
  [ -z "$_names" ] && return 0
  if [ -n "${PILOT_TEST_RIG_HAS_FILE:-}" ]; then
    case "$PILOT_TEST_RIG_HAS_FILE" in
      1) return 0 ;;
      0) return 1 ;;
      *) case " $PILOT_TEST_RIG_HAS_FILE " in *" $_rig "*) return 0 ;; *) return 1 ;; esac ;;
    esac
  fi
  _root=$(rig_root_path "$_rig" 2>/dev/null || echo "")
  [ -z "$_root" ] && return 0
  [ -d "$_root" ] || return 0
  _list=$(timeout 5 git -C "$_root" ls-files 2>/dev/null); _grc=$?
  [ "$_grc" != "0" ] && return 0   # probe FAILED (timeout/not-a-repo) → fail-open (present)
  for _n in $_names; do
    [ -z "$_n" ] && continue
    printf '%s\n' "$_list" | grep -qE "(^|/)$(printf '%s' "$_n" | sed -E 's/\./\\./g')\$" 2>/dev/null && return 0
  done
  return 1  # every cited filename is absent from every tracked path in the rig
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

# ── ga-7ti1t (Mayor re-scope, 2026-07-29 16:06): owner-inferred crew fallback ──
# A DOMAIN build with no rig-wide persistent-crew default (rig_domain_default_builder
# returns "" — e.g. whatsapp_automation, which deliberately has none: several crews
# share the domain) was refused to the dog pool and stamped pilot:held for 1h, forever,
# with no successor (ga-2n7xw invariant violation) — the bead never reached a crew
# that could actually build it. created_by already carries the session-origin form
# <crew-alias>-<session-suffix> (oracle-wa-ganav3, mila-wa-gawisphchfmo); the prefix
# before the suffix IS the crew that filed the bead — a reasonable fallback owner,
# exactly how ga-h7qje (oracle-wa-ganav3 → oracle-wa) and ga-50m2
# (mila-wa-gawisphchfmo → mila-wa) were routed by hand during the investigation.
# This is the happy-path shortcut ONLY: _pilot_infer_crew_from_owner never holds,
# escalates, or mutates a bead — on no confident match it echoes "" and the caller
# (ga-lfvs6, below) falls through to the UNCHANGED _pilot_hold_or_escalate (ga-2n7xw)
# safety net.

# _pilot_crew_aliases — the live <name>-<code> crew-alias roster (gc agent list),
# cached once per process, same pattern as _pilot_suspended_crews above. Test seam:
# PILOT_CREW_ALIASES_OVERRIDE (space-separated), mirroring
# PILOT_SUSPENDED_CREWS_OVERRIDE. FAIL-OPEN: any error → "" → no inference.
_PILOT_CREW_ALIASES=""
_PILOT_CREW_ALIASES_LOADED=0
_pilot_crew_aliases() {
  if [ "$_PILOT_CREW_ALIASES_LOADED" != "1" ]; then
    if [ -n "${PILOT_CREW_ALIASES_OVERRIDE+x}" ]; then
      _PILOT_CREW_ALIASES="$PILOT_CREW_ALIASES_OVERRIDE"
    else
      _PILOT_CREW_ALIASES=$(gc agent list 2>/dev/null \
        | awk '{print $1}' | grep -E '^[a-z0-9]+-(wa|ps|lx|ma)$' | tr '\n' ' ' 2>/dev/null || echo "")
    fi
    _PILOT_CREW_ALIASES_LOADED=1
  fi
  printf '%s' "$_PILOT_CREW_ALIASES"
}

# _pilot_infer_crew_from_owner <owner> — echo the crew alias that is the LONGEST
# live-roster prefix of $owner (so "oracle-wa-ganav3" only ever resolves to a crew
# that actually exists, never a coincidental guess), or "" on no confident match.
# Excludes suspended crews (routing there would just leave the bead assigned-but-
# unbuilt) and pool/ephemeral identities, which are never persistent owners.
_pilot_infer_crew_from_owner() {
  local _owner="$1" _roster _c _best=""
  [ -z "$_owner" ] && { printf ''; return 0; }
  case "$_owner" in gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) printf ''; return 0 ;; esac
  _roster=$(_pilot_crew_aliases)
  for _c in $_roster; do
    case "$_owner" in
      "$_c"|"$_c"-*) [ "${#_c}" -gt "${#_best}" ] && _best="$_c" ;;
    esac
  done
  [ -n "$_best" ] && _crew_is_suspended "$_best" && _best=""
  printf '%s' "$_best"
}

# ── per-crew in-flight CAP (over-assignment / load-balance) ───────────────────
# The Pilot picks an idle-THIS-SWEEP crew without seeing the crew's ACCUMULATED
# in-flight backlog, so over many sweeps one crew piles up beads it builds
# sequentially (observed: mila-wa 7 in-flight, builds ~2 at a time → 5 queued ~a day)
# while peers sit idle. _crew_at_inflight_cap caps how many story:in-flight beads a
# crew may own (PILOT_MAX_INFLIGHT_PER_CREW, default 3); the rotation loop in
# pick_pool_builder then SKIPS a full crew so the bead lands on a less-loaded peer (or
# defers if all are full — better than piling on one). Counts are memoized per rig-DB
# for the sweep (1 bd query per rig). Matches the crew by exact name, short name
# (mila-wa→mila) and session-id forms (mila-wa-<sid>). PILOT_MAX_INFLIGHT_PER_CREW=0
# disables. FAIL-OPEN: no rig context / probe error → not capped (never blocks dispatch).
PILOT_MAX_INFLIGHT_PER_CREW="${PILOT_MAX_INFLIGHT_PER_CREW:-3}"
_PILOT_INFLIGHT_RIGS_DONE=""
_PILOT_INFLIGHT_MAP=""
_crew_inflight_count() {
  local crew="$1" rig="$2" short="${1%-*}" kv rows
  [ -z "$crew" ] || [ -z "$rig" ] && { echo 0; return; }
  # Test seam: PILOT_TEST_INFLIGHT_COUNTS="crew:N crew:N" (hermetic, no bd).
  if [ -n "${PILOT_TEST_INFLIGHT_COUNTS+x}" ]; then
    for kv in $PILOT_TEST_INFLIGHT_COUNTS; do
      case "$kv" in "$crew:"*) echo "${kv#*:}"; return ;; esac
    done
    echo 0; return
  fi
  case " $_PILOT_INFLIGHT_RIGS_DONE " in
    *" $rig "*) : ;;
    *)
      rows=$(bd -C "$rig" list --json -l story:in-flight -n 0 2>/dev/null \
        | jq -r '.[] | (.assignee // "") | select(length>0)' 2>/dev/null \
        | awk -v r="$rig" '{print r"\t"$0}')
      _PILOT_INFLIGHT_MAP="${_PILOT_INFLIGHT_MAP}${rows}"$'\n'
      _PILOT_INFLIGHT_RIGS_DONE="$_PILOT_INFLIGHT_RIGS_DONE $rig"
      ;;
  esac
  printf '%s\n' "$_PILOT_INFLIGHT_MAP" | awk -F'\t' -v r="$rig" -v c="$crew" -v s="$short" '
    $1==r { a=$2; if (a==c || a==s || index(a,c"-")==1 || index(a,s"-")==1) n++ }
    END { print n+0 }'
}
_crew_at_inflight_cap() {
  local crew="$1" rig="${PILOT_INFLIGHT_RIG_OVERRIDE:-${STORY_BEAD_CITY:-}}" n
  [ "${PILOT_MAX_INFLIGHT_PER_CREW:-0}" -gt 0 ] 2>/dev/null || return 1   # disabled
  [ -n "$rig" ] || return 1                                              # no rig → fail-open
  n="$(_crew_inflight_count "$crew" "$rig")"
  [ "${n:-0}" -ge "$PILOT_MAX_INFLIGHT_PER_CREW" ] 2>/dev/null
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
# _crew_session_human_engaged <crew> — return 0 iff a tmux session for this crew is ATTACHED
# (a human — almost always Athos — is viewing/typing in it RIGHT NOW). Dispatching into such a
# session derails that live conversation: even the "non-interrupting" follow_up submit surfaces
# at the next turn boundary and hijacks the human's thread (2026-06-22: a dispatch of wa-oxkg to
# peter-wa landed mid-conversation while Athos was working WITH peter). So the dispatcher treats
# an attached crew as ineligible — the bead simply waits a sweep. PILOT_PROTECT_ATTACHED=0
# disables; test seam PILOT_TEST_ATTACHED_CREWS (space-sep crews to treat as attached).
_crew_session_human_engaged() {
  [ "${PILOT_PROTECT_ATTACHED:-1}" = "1" ] || return 1
  local _crew="${1:-}"; [ -n "$_crew" ] || return 1
  if [ -n "${PILOT_TEST_ATTACHED_CREWS+x}" ]; then
    case " $PILOT_TEST_ATTACHED_CREWS " in *" $_crew "*) return 0 ;; *) return 1 ;; esac
  fi
  command -v tmux >/dev/null 2>&1 || return 1
  tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
    | awk -v c="$_crew" 'index($1, c)==1 && ($2+0)>=1 { f=1 } END { exit(f?0:1) }'
}

pick_pool_builder() {
  local rig="$1" prefer="${2:-}" exclude="${3:-}" crew
  # 1. Domain owner first, if mapped and eligible.
  if [ -n "$prefer" ]; then
    for crew in $(rig_to_builders "$rig"); do
      [ "$crew" = "$prefer" ] || continue
      _crew_session_human_engaged "$crew" && continue   # NEVER interrupt a human-attached crew (Athos conversing)
      _crew_is_suspended "$crew" && continue   # ga-mfeip gate (e): never a suspended crew
      case " $PILOT_BUSY_BUILDERS " in *" $crew "*) continue ;; esac
      case " $PILOT_USED_BUILDERS " in *" $crew "*) continue ;; esac
      echo "$crew"
      return 0
    done
  fi
  # 2. Rotate across idle crew, skipping any domain-excluded member.
  for crew in $(rig_to_builders "$rig"); do
    _crew_session_human_engaged "$crew" && continue   # NEVER interrupt a human-attached crew (Athos conversing)
    _crew_is_suspended "$crew" && continue   # ga-mfeip gate (e): never a suspended crew
    _crew_at_inflight_cap "$crew" && continue   # per-crew in-flight cap (load-balance over-assignment)
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
# ga-hzt7: set by _dolt_saturated on every call — "healthy"/"latency"/"cpu"/
# "unreadable" — so callers can log a genuine-saturation message distinctly
# from a probe-failure message. Purely diagnostic: the throttle DECISION stays
# fail-safe (unreadable → treated as saturated) either way.
DOLT_SAT_REASON=""

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
# missing latency AND missing cpu (probe failed) → saturated. Also sets
# DOLT_SAT_REASON ("healthy"/"latency"/"cpu"/"unreadable") — ga-hzt7: a probe
# failure and a genuine over-threshold reading used to log as the identical
# "Dolt SATURATED ... latency=?ms" line, so an operator reading the log after
# the fact couldn't tell "Dolt was actually hot" from "the health probe itself
# broke". The DECISION stays fail-safe in both cases (see header comment above
# this section) — only the reason exposed to callers changes, so they can log
# accordingly.
_dolt_saturated() {
  local _lat _cpu
  _lat="$DOLT_LATENCY_MS"
  _cpu="$(_dolt_cpu)"
  # Latency is the AUTHORITATIVE health signal. When present it DECIDES: a healthy
  # latency with high CPU means Dolt is working efficiently (chronically 150-300% on
  # this 10-core box, especially under memory pressure) — NOT saturated. CPU is
  # consulted ONLY as a fallback when the latency probe is blind. (2026-06-22: cpu>200
  # was false-tripping at latency=62ms cpu=303%, throttling ALL dispatch to 0 → the
  # whole pipeline stalled overnight. Same chronic-CPU-not-latency class as the gate's
  # GATE_DOLT_CPU_HOT recalibration.)
  if [ -n "$_lat" ] && [ "$_lat" -ge 0 ] 2>/dev/null; then
    if [ "$_lat" -gt "$PILOT_DOLT_LATENCY_MAX_MS" ] 2>/dev/null; then
      DOLT_SAT_REASON="latency"; return 0
    fi
    DOLT_SAT_REASON="healthy"; return 1   # latency healthy → NOT saturated, regardless of CPU
  fi
  if [ -n "$_cpu" ] && [ "$_cpu" -ge 0 ] 2>/dev/null; then
    if [ "$_cpu" -gt "$PILOT_DOLT_CPU_MAX" ] 2>/dev/null; then
      DOLT_SAT_REASON="cpu"; return 0
    fi
    DOLT_SAT_REASON="healthy"; return 1
  fi
  # No usable signal at all (both probes blind) → fail-safe to saturated.
  DOLT_SAT_REASON="unreadable"
  return 0
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
  _q=$(GC_CITY="$GC_CITY" timeout 15 bd -C "$GC_CITY" list --json \
        -l type:quality-gate-marker -l gate-status:queued 2>/dev/null || echo "")
  _n=$(printf '%s' "$_q" | jq 'length' 2>/dev/null || echo "")
  if [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null; then printf '1'; return 0; fi
  # Runs in review — reviews currently in progress (gate-status:running).
  _r=$(GC_CITY="$GC_CITY" timeout 15 bd -C "$GC_CITY" list --json \
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

# ── ga-yolmi PASSO 1: per-bead exclusion trace helper ─────────────────────────
# Every _filter_* stage in the dispatch chain (_filter_exec_manual, _filter_candidates,
# _filter_dispatch_gates, _filter_built, _filter_unblocked, _filter_explicit_deps) now
# logs ONE line per bead it drops, naming the bead id, the filter, and the specific
# reason — the fix for the class of incident where an aggregate "dispatched=0" or a
# missing bead from the candidate pool gave no trail (ga-f7bek: ~2h of manual jq replay
# to find a single next-action: label veto; see docs on root-class:error-vs-empty).
# DELTA-ONLY: each caller computes its real (unchanged) filtered output first, then
# separately identifies which ids were dropped and why, and pipes "id<TAB>reason" rows
# through this helper. In a healthy sweep (nothing excluded) no caller produces any
# rows, so this is silent — AC2 (no log-volume explosion) holds by construction, not by
# an env-gate. Writes to STDERR ONLY (routed to $LOG by the top-level `exec >> $LOG
# 2>&1`, ga-1298) — a filter's STDOUT is a live JSON pipe consumed by the next filter
# in the chain via command substitution; anything this helper wrote to stdout would
# corrupt that JSON and silently change dispatch behavior. Never call it other than
# piped/redirected so its own stdout stays empty.
_log_exclusions() {
  local _fname="$1" _id _reason
  while IFS=$'\t' read -r _id _reason; do
    [ -z "$_id" ] && continue
    log "[pilot] EXCLUÍDO $_id por $_fname: $_reason" >&2
  done
}

_FILTER_PREAPPROVAL_LABELS='["story:unrefined","story:refinement-in-progress","story:triage","story:cancelled"]'
# ga-am6h: mirrors MAX_RECLAIMS in scripts/inflight-reclaim-guard.py (line ~101) —
# keep the two in sync by hand; there is no shared bash/python helper (see that
# script's own reclaim_decision(), which is Python-private and not import-safe
# from a bash filter).
_FILTER_RECLAIM_CAP=3

# ga-46wq5: active-owner roster globals, EARLY safe-default. _filter_candidates
# is called from _pilot_emit_dispatchable (~line 2515, the painel-preview path)
# BEFORE the real session roster is fetched (~line 2708) — the same
# before-its-dependency-is-defined shape that already crash-looped this file
# once under `set -u` (see "ga-wisp-1gdiik" a few hundred lines down). Default
# to "no known active owners, not yet safe to loosen the veto" so the early
# call site is a no-op (identical to pre-fix behavior) instead of an unbound
# variable; the real block near _LIVE_SESSION_IDS overwrites both before any
# call site that matters for actual dispatch decisions runs.
_ACTIVE_OWNER_IDS_JSON='[]'
_ROSTER_OK_FOR_FILTER=0
PILOT_ASSIGNEE_IDLE_MINUTES="${PILOT_ASSIGNEE_IDLE_MINUTES:-180}"

# ── ga-2n7xw: refusal-successor invariant — shared hold/escalate counter ──────
# Every Pilot refusal must ROUTE, ESCALATE, or TERMINATE — never silently
# "defer and retry the same" forever (the pattern behind 3 real incidents:
# ga-8jxe1 branch-veto deadlock, ga-q640n permission-dialog stall, ga-7ti1t
# unmapped-crew hold renewed forever). This is the shared cap+escalate
# mechanic for the 3 pre-dispatch refusal sites in this file: ga-lfvs6
# (domain build, no idle crew), ga-jazy9 (lane:big, no dog pool), ga-4zqwm
# (Mayor-deferred hold).
#
# DELIBERATELY separate from pilot:reclaim-count (ga-am6h, owned by
# inflight-reclaim-guard.py): that counter tracks POST-dispatch stranding of
# an assigned/in-flight bead, recovered by a different daemon on a different
# lifecycle. This one tracks PRE-dispatch holds on a bead that was never
# assigned at all — same sticky-label shape (survives hold expiry), its own
# namespace, its own cap.
PILOT_HOLD_ESCALATE_CAP="${PILOT_HOLD_ESCALATE_CAP:-3}"

# _pilot_hold_or_escalate <db> <bead_id> <slug> <reason> <unblock_hint> <labels_json> [<cap>]
#   db          bd -C target for THIS bead (its own rig store or $GC_CITY)
#   bead_id     the held/refused bead
#   slug        short stable site tag — keeps each site's counter independent
#               and makes the escalation trail attributable to the specific
#               refusal that caused it (ga-lfvs6 / ga-jazy9 / ga-4zqwm)
#   reason      literal, human-readable reason for THIS hold (AC2)
#   unblock_hint human-readable "what would unblock this" (AC2)
#   labels_json JSON array of the bead's CURRENT labels — the caller already
#               has this in memory ($STORY / $_bead from its own candidate
#               query), so no extra bd round-trip happens here
#   cap         optional override of PILOT_HOLD_ESCALATE_CAP for this call
#               (ga-4zqwm passes 1 — AC4: a hold that depends on a human must
#               escalate on the FIRST occurrence, not the 3rd)
#
# Side effects only — no stdout contract; callers must not command-substitute
# this. Always stamps the bumped sticky pilot:held-count:<slug>:<n> label
# (same imp19 atomicity convention as pilot:held-until elsewhere in this
# file: add the new stamp FIRST, then purge older stamps of the same slug, so
# a mid-crash never loses the count). The purge reads the SAME in-memory
# labels_json passed in rather than issuing a fresh `bd show` — a stale purge
# can at worst leave one extra inert label behind (harmless: readers always
# take the MAX of the prefix, never an exact match) — an acceptable tradeoff
# for not adding a bd round-trip to every dispatch-refusal sweep.
#
# At/above cap: comments the bead, adds gate:needs-human + gate:needs-human:
# technical (a Pilot-dispatch refusal is a technical/scoping circuit-breaker
# park, not a product decision — mirrors do_escalate()'s rationale in
# inflight-reclaim-guard.py; reusing the SAME sub-label means the existing
# quorum-convergence-watchdog safety net also picks this up if the Mayor
# doesn't respond), mails the Mayor once (via $GC_CITY — mail always routes
# through the HQ regardless of which store `db` is, matching every other
# `mail send mayor` call site in this pack), and logs ESCALATED. Respects
# DRY_RUN (logs WOULD-* only, no mutation) exactly like every other mutation
# in this file.
_pilot_hold_or_escalate() {
  local _phe_db="$1" _phe_id="$2" _phe_slug="$3" _phe_reason="$4" _phe_unblock="$5"
  local _phe_labels="${6:-[]}" _phe_cap="${7:-$PILOT_HOLD_ESCALATE_CAP}"

  # ga-1mqdz AC3: a bead already parked by an EXPLICIT human/Mayor decision
  # (pilot:no-auto-dispatch, or any needs-human/needs-approval human-gate
  # label) is out of flow ON PURPOSE — this counter's 3-strikes-then-escalate
  # treatment exists for beads that SHOULD be flowing and genuinely aren't
  # (e.g. "no idle crew this sweep"), not for beads a human already told the
  # Pilot to leave alone. Confirmed live (dolt_diff, ga-t8274/ga-i0n83): both
  # carried pilot:no-auto-dispatch for 5 days before EVER reaching this
  # function, then were held/escalated 3 times over ~2h40m — pure noise, since
  # AC1 (this same fix) means such a bead should never be a candidate in the
  # first place. This is the defense-in-depth layer: even if some OTHER,
  # not-yet-found candidacy gap lets an explicitly-parked bead through, it
  # still must not burn the hold-count/escalate cycle. Skip silently — no
  # stamp, no mail, no comment; the bead is already the Mayor's to unpark.
  # Checked against the SAME in-memory labels_json callers already pass in (no
  # extra bd round-trip), mirroring _filter_candidates' equivalent clauses.
  if printf '%s' "$_phe_labels" | jq -e '
      (. // []) | any(
        . == "pilot:no-auto-dispatch"
        or startswith("gate:needs-human")
        or startswith("needs-human")
        or . == "story:needs-human"
        or . == "story:needs-approval"
      )
    ' >/dev/null 2>&1; then
    log "[pilot-hold] $_phe_slug: $_phe_id already parked by explicit decision (no-auto-dispatch/needs-human) — skipping hold-count/escalation (ga-1mqdz AC3)"
    return 0
  fi

  local _phe_prefix="pilot:held-count:${_phe_slug}:"
  local _phe_cur _phe_new
  _phe_cur=$(printf '%s' "$_phe_labels" | jq -r --arg p "$_phe_prefix" \
    '(. // []) | map(select(startswith($p)) | ltrimstr($p) | tonumber) | if length > 0 then max else 0 end' \
    2>/dev/null)
  case "$_phe_cur" in ''|*[!0-9]*) _phe_cur=0 ;; esac
  _phe_new=$((_phe_cur + 1))

  if [ "$DRY_RUN" = "1" ]; then
    if [ "$_phe_new" -ge "$_phe_cap" ]; then
      log "[pilot-hold] WOULD ESCALATE $_phe_id ($_phe_slug, hold $_phe_new/$_phe_cap) to Mayor: $_phe_reason"
    else
      log "[pilot-hold] WOULD stamp ${_phe_prefix}${_phe_new} on $_phe_id (hold $_phe_new/$_phe_cap)"
    fi
    return 0
  fi

  bd -C "$_phe_db" label add "$_phe_id" "${_phe_prefix}${_phe_new}" -q 2>/dev/null || true
  local _phe_stale
  for _phe_stale in $(printf '%s' "$_phe_labels" | jq -r --arg p "$_phe_prefix" '(. // [])[] | select(startswith($p))' 2>/dev/null); do
    [ "$_phe_stale" = "${_phe_prefix}${_phe_new}" ] || bd -C "$_phe_db" label remove "$_phe_id" "$_phe_stale" -q 2>/dev/null || true
  done

  if [ "$_phe_new" -lt "$_phe_cap" ]; then
    log "[pilot-hold] $_phe_slug: $_phe_id held ($_phe_new/$_phe_cap) — $_phe_reason"
    return 0
  fi

  bd -C "$_phe_db" label add "$_phe_id" "gate:needs-human" -q 2>/dev/null || true
  bd -C "$_phe_db" label add "$_phe_id" "gate:needs-human:technical" -q 2>/dev/null || true
  bd -C "$_phe_db" comment "$_phe_id" \
    "pilot-dispatcher ($_phe_slug / ga-2n7xw): ESCALATED after $_phe_new consecutive holds for the same reason (cap=$_phe_cap). Reason: $_phe_reason. What would unblock: $_phe_unblock. Not auto-closing — routing to the Mayor for a decision." \
    2>/dev/null || true
  gc --city "$GC_CITY" mail send mayor \
    -s "Pilot hold escalation ($_phe_slug): $_phe_id" \
    -m "$(printf 'Bead %s has been held/deferred %s time(s) for the same reason with no successor (ga-2n7xw invariant: every refusal must route, escalate, or terminate).\n\n  site:      %s\n  reason:    %s\n  unblock:   %s\n\nNot auto-closed. gate:needs-human(:technical) added; please route, unblock, or terminally close.' \
      "$_phe_id" "$_phe_new" "$_phe_slug" "$_phe_reason" "$_phe_unblock")" \
    2>/dev/null || true
  log "[pilot-hold] $_phe_slug: $_phe_id ESCALATED to Mayor after $_phe_new holds (cap=$_phe_cap)"
}

_filter_candidates() {
  # imp19: pilot:held is now a TIMED hold — pass a bead with pilot:held only if a
  # pilot:held-until:<epoch> label exists AND the epoch is in the past (expired hold).
  # The janitor R6 removes expired labels on its next sweep; this filter lets the
  # Pilot bypass the hold without waiting for the janitor when the expiry is clear.
  local _now_ts; _now_ts=$(date +%s)
  local _cf_in; _cf_in=$(cat)
  local _cf_out _cf_kept
  # ga-46wq5: local, self-defending defaults for the active-owner globals —
  # NOT just the early top-of-file default (that one only protects the real
  # dispatcher's first in-process call site; a test or any other caller that
  # extracts/evals this function body in isolation, without ever sourcing the
  # lines that set the globals, would otherwise pass literal empty strings to
  # --argjson, which is invalid JSON and makes the WHOLE jq call error out —
  # collapsing _cf_out to "[]" for every bead, not just assignee-holding ones.
  # Mirrors this function's own existing "$([ -z "$_cf_out" ] && ...)" fallback
  # philosophy: never let a missing dependency silently zero out the output.
  local _cf_roster_ok="${_ROSTER_OK_FOR_FILTER:-0}"
  local _cf_active_owner_ids_json="${_ACTIVE_OWNER_IDS_JSON:-[]}"
  _cf_out=$(printf '%s' "$_cf_in" | jq --arg self "$SELF_BEAD_ID" --argjson preapproval "$_FILTER_PREAPPROVAL_LABELS" \
     --argjson now_ts "$_now_ts" --argjson reclaim_cap "$_FILTER_RECLAIM_CAP" \
     --argjson roster_ok "$_cf_roster_ok" --argjson active_owner_ids "$_cf_active_owner_ids_json" \
    '[.[] | select(
        .id != $self
        # ga-46wq5: an assignee alone is no longer an unconditional veto. It
        # still is when the roster is untrustworthy ($roster_ok != 1 — jq
        # treats bare 0 as truthy, so this MUST be an explicit comparison, not
        # `$roster_ok and ...`) or the assignee IS a confirmed active owner
        # (live, not asleep, not idle beyond PILOT_ASSIGNEE_IDLE_MINUTES — see
        # _session_is_active_owner). Otherwise (closed / asleep / idle-beyond-
        # threshold) the bead is a candidate again, same as if unassigned —
        # this is the ga-46wq5 fix: a Mayor-assigned bead whose owner went
        # quiet no longer drains the dispatch queue in silence.
        and (.assignee == null or .assignee == ""
             or (($roster_ok == 1) and (.assignee as $a | ($active_owner_ids | index($a)) == null)))
        and ((.issue_type // .type // "") != "epic")
        and (((.labels // []) | index("story:epic-split")) | not)
        # ga-iu9m/ga-enfe: a bead belonging to a graph.v2 formula/workflow is a
        # direct-execution runbook (run the listed commands, close the bead),
        # not a code-build story — there is no repo to branch in, so the bug/
        # feature "implement -> /gate-done" doctrine this filter feeds into can
        # never be satisfied. Every dispatch times out, gets reclaimed, and
        # re-dispatches (the ga-knfh 8x/5.25h thrash). Such beads are already
        # serviced directly by whichever pool their gc.routed_to names (see
        # .gc/system/packs/core/assets/prompts/graph-worker.md) — exclude both
        # the steps (gc.root_bead_id set on every step) and the root itself
        # (gc.formula_contract / gc.kind=workflow, no root_bead_id since it IS
        # the root) at this one chokepoint so every tier/path (HQ bugs/debt/
        # features, ctx:ready, rig DBs) is covered without touching each call site.
        and ((.metadata["gc.root_bead_id"] // "") | test("\\S") | not)
        and ((.metadata["gc.formula_contract"] // "") | test("\\S") | not)
        and (((.metadata["gc.kind"] // "") as $k
              | ["workflow","scope","ralph","retry","check","fanout","retry-eval","scope-check","workflow-finalize"]
              | index($k)) == null)
        and (
          (((.labels // []) | index("pilot:held")) | not)
          or
          # ga-4aree: use the MAX (latest) held-until epoch, NOT .[0]. held-until labels
          # ACCUMULATE (the stamp adds one per hold without pruning), so .[0] was the
          # OLDEST/expired stamp → the filter judged an actively-held bead "expired" →
          # re-selected it every sweep → refused → re-stamped → the clog loop. The bead is
          # still held iff its LATEST hold is in the future.
          ((.labels // []) | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber) |
            if length > 0
            then (max < $now_ts)
            else false end)
        )
        and (
          # ga-am6h: pilot:reclaim-count is STICKY, independent of pilot:held. Once
          # reclaim_decision() in inflight-reclaim-guard.py sees reclaim_count >=
          # MAX_RECLAIMS it stops reclaiming and escalates to gate:needs-human — but
          # that escalation label can land arbitrarily late (observed ~1h41m gap in
          # the ga-knfh incident, ga-iu9m), and the pilot:held cooldown on the same
          # bead can expire first. Exclude on the count alone so a capped-out bead
          # does not slip back into the candidate pool just because a timer ran out.
          # Nothing decrements this label — only a human or mayor, or the escalation
          # labels the guard sets on its own, re-admit the bead.
          ((.labels // []) | map(select(startswith("pilot:reclaim-count:")) | ltrimstr("pilot:reclaim-count:") | tonumber) |
            if length > 0
            then (max < $reclaim_cap)
            else true end)
        )
        and (((.labels // []) - $preapproval) | length) == ((.labels // []) | length)
        and ((.labels // []) | map(select(
          startswith("gate:needs-human")
          # ga-3lsy1: bugs/tech-debt (issue_type=bug, -l tech-debt) never carry the
          # story:* refino labeling convention, so their human-gate signal is the BARE
          # needs-human label instead of story:needs-human — which this filter did not
          # check at all, so a bug carrying needs-human sailed through untouched
          # (ga-jwnye: dispatched 4x via BUGS_JSON/_filter_candidates despite carrying
          # needs-human from creation, incl. once AFTER a dog had re-affirmed the label
          # following investigation). startswith (not exact match, mirroring
          # gate:needs-human above) also catches the needs-human-decision sub-variant,
          # already treated as an equivalent human-gate signal elsewhere in this file
          # (WA gate1 check, ~line 283) and already excluded at CTXREADY_JSONs own
          # query site — this brings BUGS_JSON/DEBT_JSON/TIER2_JSON and every RIG_*
          # variant (all of which rely on this shared chokepoint, not a per-query
          # --exclude-label) up to the same standard.
          or startswith("needs-human")
          # ga-y8qh: pool:refused[:<reason-slug>] is the pool-worker-refusal
          # counterpart to gate:needs-human — same prefix-sub-variant shape,
          # same reason to catch it here (upstream, at selection time) rather
          # than only downstream: a refused-and-parked bead keeps its
          # gc.routed_to (nothing clears it), so without this it can be
          # re-selected as a fresh dispatch candidate on a later sweep and
          # re-routed into the same refusal loop the parking label was meant
          # to end.
          or startswith("pool:refused")
          # ga-uvfs6: pilot:refused-reason:<slug> is the PERMANENT audit label
          # that inflight-reclaim-guard.py promotes pool:refused[:reason] INTO
          # (consuming/removing the ephemeral one) via _promote_refusal_labels().
          # A bead that survived past its first reclaim cycle carries this
          # instead, and without this clause it re-enters open/unassigned
          # candidacy exactly like a never-refused bead (wa-ys0cy:
          # pilot:refused-reason:oracle-named-executor, no pool:refused,
          # re-selected and burned another dispatch).
          or startswith("pilot:refused-reason:")
          or . == "story:needs-human"
          # ga-nf4x5: story:needs-approval is the Athos MERIT/legal sign-off gate
          # (refino-gate-dispatcher.sh applies it once code-gate passed but a human
          # decision on merit/risk is still pending — e.g. wa-6xn82, a real LAI legal
          # filing dispatched to the generic wa-worker pool with "No human review
          # required" before a worker happened to read the comment and refuse by
          # hand). It is semantically distinct from story:needs-human (an INFO-GAP:
          # the bead is unbuildable/underspecified) but must be excluded the same
          # way: this is a human decision gate, not a code-quality gate that
          # gate-done/autonomous review can ever clear.
          or . == "story:needs-approval"
          # ga-1mqdz AC1: pilot:no-auto-dispatch is a direct Mayor/human "stop
          # dispatching this" signal (used to defer/park a bead without a
          # full story:* refino lifecycle) but this filter — the single
          # chokepoint every candidate source funnels through — never
          # checked it, so only the pilot:held-until 1h backoff between
          # attempts kept re-selecting it. Confirmed live (dolt_diff on
          # ga-t8274/ga-i0n83): pilot:no-auto-dispatch was added 5 DAYS
          # before either bead was first selected as a dispatch candidate,
          # attempted, refused, and held — 3 times over ~2h40m — before the
          # hold-cap escalation itself (a SEPARATE mechanism) finally added
          # gate:needs-human and stopped it. The label alone must hold, per
          # the memory this fixes (pilot-no-auto-dispatch-not-respected-by-
          # pilot-dispatcher / wa-0sk7n): "strip ctx:ready+exec:auto" was
          # never meant to be the ONLY way to pause a bead.
          or . == "pilot:no-auto-dispatch"
          or . == "story:needs-device"
          or . == "on-device"
          or . == "story:blocked"
          # ga-2lqv: engine-window:pending means Phase-1 (code fix) is DONE and
          # Phase-2 (deploy) is deliberately batched with sibling bugs (see
          # docs/runbooks/ga-ftmci-dolt-cpu-engine-window.md) — it is NOT "not
          # started". Before this clause the scan could not tell the two apart
          # and re-dispatched a fresh builder onto the bead every sweep
          # (observed on ga-sm5p: re-dispatched ~3 min after the prior
          # dispatch closed, burning a full dog-pool cycle on a pure no-op
          # re-verify). Whoever performs the batched deploy removes the
          # label, so the bead re-enters the pool on the very next sweep —
          # a plain static exclude needs no extra timer/expiry state here,
          # mirroring how needs:engine-window is a static --exclude-label at
          # the bd list call sites for the opposite side of the same window.
          or . == "engine-window:pending"
          # ga-vhyd: framework:engine is the manual, human/dog-applied marker
          # for "this needs a gascity engine rebuild" (already in live use —
          # e.g. ga-g7yt — alongside pool:refused:engine-rebuild-required, but
          # nothing previously excluded it from re-selection). Honor it the
          # same static way as engine-window:pending/needs:engine-window.
          or . == "framework:engine"
          # ga-spux4: story:awaiting-external-merge is the manual marker for
          # "the fix already exists as an open PR against an external
          # (non-rig) repo — e.g. a fork -> PR -> upstream-review flow with
          # no Gas Town gate watching it — so this is NOT untouched, fresh
          # work" (root-class:comment-only-signal-not-encoded: the signal
          # previously lived only in a bead comment, invisible to this scan,
          # so Pilot kept re-dispatching a fresh builder onto work that was
          # already done and awaiting human/upstream merge — see ga-hqchm, 3
          # dispatches across ~4h for one fix). Apply it (plus `external_ref`
          # set to the PR URL) on the STORY bead whenever a dispatch closes
          # its sling bead by pointing at an external, not-yet-merged PR
          # instead of a rig gate. A human/Mayor sweep removes the label once
          # the PR merges, same as engine-window:pending above — no daemon
          # watches external PRs for merge yet, so removal is manual.
          or . == "story:awaiting-external-merge"
        )) | length) == 0
        and ((.description // "") | test("\\S"))
        # ga-vhyd: needs:engine-window (excluded above via --exclude-label at
        # every bd list call site) only protects a bead AFTER something labels
        # it. Nothing does that at creation time, so a freshly-filed bug whose
        # OWN body already says it needs a gascity (gc binary) rebuild + swap
        # + town bounce can win a dispatch sweep before any human/system gets
        # to label it (occurrences: ga-n9bw, ga-g7yt — both caught only by the
        # dispatched dog/builder reading the body and standing down, burning a
        # sling+session each time). Catch the same signal straight from the
        # title/description text at selection time — the pre-label safety net
        # for the identical case needs:engine-window covers once applied.
        # Deliberately narrow/compound phrases requiring "gascity"/"binary"/
        # "binário" to co-occur (not bare "engine" or "rebuild" alone, which
        # false-positive on "search engine", "rebuild index", etc.) — checked
        # both word orders, since real bug bodies say both "rebuild...gascity"
        # and "gascity engine rebuild".
        # ga-w3vn3: a lone "engine[ -]window" alternative used to live in this
        # list too — removed because it IS the own name of the needs:engine-window
        # label, so any bead merely CITING that label (e.g. a bug report whose
        # scope section lists labels a related defect drops) got vetoed as if
        # it were requesting the operation itself — ga-xvxvf blocked 13 sweeps
        # straight for describing its own bug. The already-labeled case stays
        # covered independently: every bd list/bd ready call site above already
        # passes its own --exclude-label flag for this same label name; a
        # genuine pre-label rebuild request still matches one of the
        # co-occurring alternatives here. Do not re-add a standalone
        # label-name alternative to this pattern — same failure class this
        # comment already warns against.
        and (((.title // "") + " " + (.description // ""))
             | test("gascity.*rebuild|rebuild.*gascity|swap.*bin[áa]rio|swap.*binary|binary swap|town bounce"; "i")
             | not)
        # ga-xdukc/ga-hd87d: independent safety net (defense-in-depth), same
        # shape as the engine-rebuild veto directly above. A bead whose TITLE
        # BEGINS WITH DECISAO/DECISION, or whose title+description contains
        # "so o Athos decide", is a human-decision-only bead by its own text —
        # regardless of whether refinos escalation labels (story:needs-human,
        # gate:needs-human:*) actually landed on it. wa-5ch02 (a real
        # Athos-money decision: DECISAO (Athos): classificacao deve pagar
        # conexoes...) proved neither label reached the bead before Pilot
        # dispatched it with No human review required — manual refusal by a
        # dispatched worker was the only thing that stopped an agent from
        # deciding a spend policy alone. The escalate-path fix
        # (auto-refino-dispatcher.sh, story:needs-human) closes the gap at its
        # source; this is the belt to that suspenders — cheap to keep (worst
        # case: one extra bead waits for a human that did not strictly need to).
        # NOTE: no literal apostrophes anywhere in this comment block — this
        # whole clause lives inside ONE bash single-quoted jq argument, so a
        # stray apostrophe (even inside a # comment) prematurely closes the
        # bash string and desyncs everything after it (caught live while
        # writing this fix — do not reintroduce one here).
        and (((.title // "") | test("^\\s*(DECIS[ÃA]O|DECISION)\\b"; "i")) | not)
        and (((.title // "") + " " + (.description // ""))
             | test("s[óo] o athos decide"; "i")
             | not)
        # ga-fnnyy: same belt-and-suspenders shape as the two vetoes directly
        # above, for a third failure mode in the identical class — a signal
        # that lives only in prose might never get labeled. Here the prose
        # signal is an agent-authored compliance/safety gate (e.g. "🚨 PORTÃO
        # DE COMPLIANCE — LGPD: ..."), and the label never arriving is not
        # hypothetical: the auto-refino --description rewrite (see
        # auto-refino-dispatcher.sh REFINE_TASK write-back) is what deletes
        # it, so the one thing the label-based vetoes above depend on
        # (needs-human / pilot:no-auto-dispatch actually landing) can be
        # destroyed by that same daemon write-back before this filter ever
        # runs. Scan title+description directly, same as the two vetoes
        # above, so dispatch cannot proceed on an unresolved 🚨 marker
        # regardless of whether the label side of the fix held. Self-clears
        # once a human either labels the bead (existing vetoes above then
        # hold it) or resolves/removes the marker text. Marker-specific
        # (the literal emoji), not keyword-based — deliberately narrow to
        # avoid false-positiving on ordinary safety-adjacent prose.
        # NOTE: no literal apostrophes anywhere in this comment block —
        # same reason as the DECISAO comment above (single-quoted jq arg).
        and (((.title // "") + " " + (.description // "")) | test("🚨") | not)
     )]' \
    2>/dev/null)
  [ -z "$_cf_out" ] && _cf_out="[]"

  _cf_kept=$(printf '%s' "$_cf_out" | jq -c '[.[].id]' 2>/dev/null); [ -z "$_cf_kept" ] && _cf_kept="[]"

  # ga-46wq5 FIX PEDIDO #2: alarm for beads admitted specifically because their
  # assignee is NOT a confirmed active owner (closed / asleep / idle beyond
  # PILOT_ASSIGNEE_IDLE_MINUTES). Pre-fix, .assignee!="" was excluded
  # unconditionally, so no such entry could ever appear in $_cf_out — its mere
  # presence here IS the alarm signal (no separate scan/query needed), and it
  # fires every sweep the condition persists, not only after the queue empties.
  printf '%s' "$_cf_out" | jq -r '.[] | select((.assignee // "") != "") | "\(.id)\t\(.assignee)"' 2>/dev/null \
    | while IFS=$'\t' read -r _aid _aowner; do
        [ -z "$_aid" ] && continue
        warn "[pilot] ALERTA ga-46wq5: $_aid tem assignee '$_aowner' que NÃO é dono ativo (closed/asleep/idle>${PILOT_ASSIGNEE_IDLE_MINUTES}min) — readmitido à fila de dispatch." >&2
      done

  # ── ga-yolmi PASSO 1: per-bead exclusion trace (see _log_exclusions). This pass
  # NEVER influences $_cf_out — it independently mirrors each clause above, read-only,
  # restricted (via $kept) to ids already known to be dropped. A bug in this mirror
  # can only under-report a reason, never change what actually gets dispatched.
  printf '%s' "$_cf_in" | jq -r --arg self "$SELF_BEAD_ID" --argjson preapproval "$_FILTER_PREAPPROVAL_LABELS" \
      --argjson now_ts "$_now_ts" --argjson reclaim_cap "$_FILTER_RECLAIM_CAP" --argjson kept "$_cf_kept" \
      --argjson roster_ok "$_cf_roster_ok" --argjson active_owner_ids "$_cf_active_owner_ids_json" '
      .[] | . as $b | ($b.id // "") as $id | ($b.labels // []) as $L
      | select($id != "" and (($kept | index($id)) | not))
      | [
          (if $id == $self then "self-bead" else empty end),
          # ga-46wq5: explicit liveness detail (FIX PEDIDO #3) instead of the
          # bare name — a human/detector reading this log no longer has to
          # infer whether the exclusion means "owner is working" or "roster
          # was untrustworthy this sweep, failed safe".
          (if (($b.assignee // "") != "") then
             (if ($roster_ok == 1) then "assignee:\($b.assignee):active-owner"
              else "assignee:\($b.assignee):roster-untrustworthy-failsafe" end)
           else empty end),
          (if ((($b.issue_type // $b.type // "")) == "epic") then "issue_type:epic" else empty end),
          (if ($L | index("story:epic-split")) then "label:story:epic-split" else empty end),
          (if (($b.metadata["gc.root_bead_id"] // "") | test("\\S")) then "graph.v2-step:gc.root_bead_id" else empty end),
          (if (($b.metadata["gc.formula_contract"] // "") | test("\\S")) then "graph.v2-root:gc.formula_contract" else empty end),
          (if ((($b.metadata["gc.kind"] // "") as $k
                | ["workflow","scope","ralph","retry","check","fanout","retry-eval","scope-check","workflow-finalize"]
                | index($k)) != null) then "gc.kind:\($b.metadata["gc.kind"] // "")" else empty end),
          (if ( ($L | index("pilot:held"))
                and (($L | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber)) |
                     if length > 0 then (max >= $now_ts) else true end) )
           then "pilot:held(not-expired)" else empty end),
          (if ( ($L | map(select(startswith("pilot:reclaim-count:")) | ltrimstr("pilot:reclaim-count:") | tonumber)) |
                if length > 0 then (max >= $reclaim_cap) else false end )
           then "pilot:reclaim-count>=cap(\($reclaim_cap))" else empty end),
          ( ($L | map(select(. as $x | $preapproval | index($x)))) as $pa
            | if ($pa | length) > 0 then "preapproval-label:\($pa | join(","))" else empty end ),
          ( ($L | map(select(
              startswith("gate:needs-human")
              or startswith("needs-human")
              or startswith("pool:refused")
              or startswith("pilot:refused-reason:")
              or . == "story:needs-human"
              or . == "story:needs-approval"
              or . == "story:needs-device"
              or . == "on-device"
              or . == "story:blocked"
              or . == "engine-window:pending"
              or . == "framework:engine"
              or . == "story:awaiting-external-merge"
            ))) as $bl
            | if ($bl | length) > 0 then "blocking-label:\($bl | join(","))" else empty end ),
          (if ((($b.description // "") | test("\\S")) | not) then "empty-description" else empty end),
          (if ( ((($b.title // "") + " " + ($b.description // ""))
                 | test("gascity.*rebuild|rebuild.*gascity|swap.*bin[áa]rio|swap.*binary|binary swap|town bounce|engine[ -]window"; "i")) )
           then "engine-rebuild-text-pattern" else empty end),
          (if (($b.title // "") | test("^\\s*(DECIS[ÃA]O|DECISION)\\b"; "i"))
           then "decisao-title-text-pattern"
           elif ( ((($b.title // "") + " " + ($b.description // ""))
                   | test("s[óo] o athos decide"; "i")) )
           then "athos-decide-phrase-text-pattern"
           else empty end),
          (if ( ((($b.title // "") + " " + ($b.description // "")) | test("🚨")) )
           then "compliance-marker-text-pattern" else empty end)
        ] as $reasons
      | select(($reasons | length) > 0)
      | [$id, ($reasons | join(";"))] | @tsv
    ' 2>/dev/null | _log_exclusions "_filter_candidates"

  printf '%s' "$_cf_out"
}
# ── parking-label pre-filter (upstream of dispatch, additive to ga-zzrts) ─────
# The bd list queries use exact --exclude-label matching. Labels like
# gate:needs-human:mayor-fixing and gate:needs-human:on-device are SUB-VARIANTS
# that do NOT match the exact "gate:needs-human" exclude — they leak through the
# query and are only caught at dispatch time (ga-zzrts fix b, grep-based prefix
# match), causing selected-and-released every sweep → dispatched=0 stalls.
# The jq condition above moves this filter UPSTREAM into _filter_candidates so
# sub-variants are excluded at SELECTION time (prefix startswith match), matching
# the dispatch-time behavior. The ga-zzrts(b) check is PRESERVED as defense-in-
# depth for genuine races; this is purely additive. All tiers and the emitted
# pilot-dispatchable.json flow through _filter_candidates, so one change here
# covers all paths (HQ bugs/debt/features, HQ ctx:ready, rig ctx:ready, rig
# story:approved) and fixes the painel Aprovadas inflation simultaneously.
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
    # ga-yolmi PASSO 1: name each dropped id (dropped == member of $blk, the
    # exact predicate `filtered` above already applied — pure re-read, no
    # influence on $filtered).
    printf '%s' "$arr" | jq -r --argjson blk "$blocked_json" \
      '.[] | select((.id as $i | $blk | index($i))) | [.id, "blocked by unresolved dependency (bd blocked — ga-5ew)"] | @tsv' \
      2>/dev/null | _log_exclusions "_filter_unblocked"
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
        # ga-yolmi PASSO 1: standardized per-bead exclusion line (alongside the
        # existing WARN above, unchanged for anything already parsing it).
        log "[pilot] EXCLUÍDO $bid por _filter_explicit_deps: dep $dep status=$dep_status (story.depends_on_beads)" >&2
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
# _filter_exec_manual — drop any bead labelled exec:manual from a JSON array.
# exec:manual means the task requires physical device interaction, gov-portal
# CAPTCHAs, or human credentials that a crew cannot supply autonomously (ga-mfeip
# AC3). Crews SKIP such beads; dispatching them is wasted capacity + a stuck
# pilot:dispatching claim. exec:auto and unlabelled beads pass through unchanged
# (conservative default: absent exec: label → dispatch is fine, never suppress).
# Pure read (no side effects); fail-open → pass through unchanged on jq error.
_filter_exec_manual() {
  local _em_in _em_out
  _em_in=$(cat)
  _em_out=$(printf '%s' "$_em_in" | jq '[ .[] | select(((.labels // []) | index("exec:manual")) == null) ]' 2>/dev/null)
  if [ -z "$_em_out" ]; then
    printf '%s' "$_em_in"
    return
  fi
  # ga-yolmi PASSO 1: single-clause filter, so every dropped id shares one reason.
  printf '%s' "$_em_in" | jq -r --argjson kept "$(printf '%s' "$_em_out" | jq -c '[.[].id]' 2>/dev/null || echo '[]')" '
      .[] | . as $b | ($b.id // "") as $id
      | select($id != "" and (($kept | index($id)) | not))
      | [$id, "label:exec:manual"] | @tsv
    ' 2>/dev/null | _log_exclusions "_filter_exec_manual"
  printf '%s' "$_em_out"
}
# _filter_dispatch_gates — ga-mfeip dispatch quality gates (a)+(b)+(c)+(d). Drop
# ctx:ready candidates that are not safely auto-buildable by a crew:
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
#   (c) AN UNSATISFIED PRECONDITION LABEL. A `blocked-on:*`, `blocked:*`, or `depends-on:*`
#       label is a free-text precondition the bd dep-graph can't see (e.g.
#       blocked-on:ata-dedicada, blocked:needs-pregao-deployed, depends-on:contact-sync).
#       `blocked:*` (ga-yavyq) is the bare-prefix sibling of blocked-on: — used when
#       there's a reason but no single blocking bead id to name. Such a bead is not
#       ready regardless of ctx:ready.
#   (d) WAITING ON ANOTHER ACTOR — except refino's crew-routing convention (ga-f7bek).
#       `waiting-on:*` always means "blocked on X" → always veto. But `next-action:*`
#       is OVERLOADED with two opposite meanings: the original one (added 5de1ce1c7,
#       2026-06-29) means "blocked on Athos/a dependency" (e.g. next-action:athos+oracle,
#       bare next-action:mayor — no build verb, still vetoed below); refino's newer
#       convention writes next-action:<crew>-constroi/-reconstroi/-corrige-gate to mean
#       the OPPOSITE — "this is READY, <crew> is who builds it" — a ROUTING label, not
#       a blocker. Before ga-f7bek this collision silently vetoed every refined WA story
#       carrying a next-action, starving 10/15 approved beads up to 24h with zero
#       per-bead signal (only the aggregate dispatchable count read "0"). Fix: only
#       next-action forms WITHOUT a build-verb suffix still veto; next-action forms
#       naming a human/decision/approval (next-action:athos-*, next-action:*-decide,
#       next-action:*-aprova) are unaffected and keep blocking, same as before.
# Pure read, no side effects on the default path; fail-open → pass through unchanged
# on any jq error. Set PILOT_DISPATCH_GATES_DEBUG=1 to additionally `log` which bead
# was vetoed by which clause (ga-f7bek AC5) — the aggregate count alone cost ~2h to
# root-cause once, with no per-bead trail to shortcut the next investigation.
_filter_dispatch_gates() {
  local floor="${PILOT_CTX_MIN_SPEC_CHARS:-20}"
  local _gate_filter='[ .[] | select(
      (((.status) // "open") as $s | ($s != "blocked" and $s != "closed" and $s != "deferred"))
      and ( (((.metadata["story.criterios"]) // "") | test("\\S"))
        or (((.description) // "") | length) >= $floor )
      and (((.labels // []) | map(select(test("^(blocked-on|blocked|depends-on):"))) | length) == 0)
      and ((((.title) // "") + " " + ((.description) // "")) | ascii_downcase | test("design[ -]?first") | not)
      and (((.labels // []) | map(select(
            test("^waiting-on:")
            or (test("^next-action:") and (test("(constroi|corrige-gate|corrige)$") | not))
          )) | length) == 0)
    )]'
  local _dg_input _dg_out _dg_reasons
  _dg_input=$(cat)
  _dg_out=$(printf '%s' "$_dg_input" | jq --argjson floor "$floor" "$_gate_filter" 2>/dev/null)
  if [ -z "$_dg_out" ]; then
    printf '%s' "$_dg_input"
    return
  fi

  # ── ga-yolmi PASSO 1 (supersedes the old PILOT_DISPATCH_GATES_DEBUG-only trace,
  # ga-f7bek): per-bead veto reasons, mirroring each clause of $_gate_filter
  # individually. Read-only — never influences $_dg_out above. Always computed
  # (not gated) so a delta produces a trace unconditionally; PILOT_DISPATCH_GATES_DEBUG=1
  # additionally emits the older verbose single-line-per-bead form for anything
  # already parsing that exact format.
  _dg_reasons=$(printf '%s' "$_dg_input" | jq --argjson floor "$floor" -r '
      .[] | . as $b
      | [
          (if ((($b.status) // "open") as $s | ($s == "blocked" or $s == "closed" or $s == "deferred")) then "status:\($b.status // "open")" else empty end),
          (if ( ((($b.metadata["story.criterios"]) // "") | test("\\S")) or ((($b.description) // "") | length) >= $floor ) then empty else "no-spec(empty-criterios,desc<\($floor)chars)" end),
          ( ((($b.labels) // []) | map(select(test("^(blocked-on|blocked|depends-on):")))) as $pl
            | if ($pl | length) == 0 then empty else "precondition-label:\($pl | join(","))" end ),
          (if (((($b.title) // "") + " " + (($b.description) // "")) | ascii_downcase | test("design[ -]?first")) then "design-first" else empty end),
          ( ((($b.labels) // []) | map(select(
                test("^waiting-on:")
                or (test("^next-action:") and (test("(constroi|corrige-gate|corrige)$") | not))
              ))) as $wl
            | if ($wl | length) == 0 then empty else "blocking-label:\($wl | join(","))" end )
        ] as $reasons
      | select(($reasons | length) > 0)
      | [$b.id, ($reasons | join(";"))] | @tsv
    ' 2>/dev/null)
  printf '%s\n' "$_dg_reasons" | _log_exclusions "_filter_dispatch_gates"
  if [ "${PILOT_DISPATCH_GATES_DEBUG:-0}" = "1" ]; then
    printf '%s\n' "$_dg_reasons" | while IFS=$'\t' read -r _vid _vreasons; do
      [ -z "$_vid" ] && continue
      log "_filter_dispatch_gates veto id=$_vid reasons=$_vreasons" >&2
    done
  fi

  printf '%s' "$_dg_out"
}
# _filter_built — drop ctx:ready candidates that ALREADY have a crew OR dog fix/ branch
# (built work awaiting gate/delivery, NOT a fresh dispatch candidate; ga-6jqr: the branch
# probe used to match ONLY crew/*/<id>, blind to the fix/<id>-* shape dog builders push —
# so a bead a dog already branched still read "no branch" and got dispatched AGAIN).
# Such a bead — if it kept or re-acquired ctx:ready (lost story:in-flight, or gate-failed)
# — is picked first by
# priority, REFUSED by the ownership guard (its branch exists), and HEAD-OF-LINE-BLOCKS
# the lane every sweep (the wa-xrdv / wa-vn5o stall: dispatched=0 while fresh beads wait).
# Self-sufficient repo list (does not need the never-started block). FAIL-OPEN to KEEP:
# no git / no repo set / jq error → keep the candidate (never drop a real one on an
# unresolved probe — the opposite of the reclaim-side fail-open).
# ga-rcees: "branch exists" alone is no longer an unconditional veto here either — a
# matched ref is classified via _beadid_branch_signal, and an "orphan" (unmerged,
# stale, unassigned) is kept as a candidate instead of vetoed forever. Without this,
# ga-8jxe1's own orphan classifier could never fire for its primary case: this filter
# runs UPSTREAM of dispatch_one() and dropped the bead before the classifier ever saw
# it. See _beadid_branch_signal's doc for the classification detail.
_filter_built() {
  local repos arr id r built_ids="" ingate_ids="" _bounced _glabel
  local built_reasons="" ingate_reasons="" _matched_ref _out _kept_sp _bid _breason
  local _bf_json _bf_signal
  arr=$(cat)

  # ── (wa-8y45 leak) GATE-MARKER + GATE-LABEL consultation ─────────────────────
  # The branch probe below is BLIND to a bead whose crew branch was PRUNED while it
  # sits in the quality gate: when the gate parks a marker at needs-rebase/error it
  # prunes the crew branch, so the branch check reads "no branch → not built" and
  # LEAKS the bead back as a FRESH candidate — even though it is already built and
  # OWNED by the gate (the wa-8y45 leak: open marker ga-wisp-* @ needs-rebase,
  # source-bead:wa-8y45, branch gone; the downstream imparavel-check was already
  # hardened for this in c9a8413f1, now the Pilot must stop emitting it too).
  #
  # Mirrors imparavel-check.classify_bead + ownership-guard signal (d): a candidate
  # is ALREADY-BUILT / IN-GATE (⇒ drop) when an OPEN type:quality-gate-marker names
  # it (source-bead:<id>, ANY gate-status — needs-rebase/error are non-active but the
  # bead is still in the pipeline) OR it carries a gate:* lifecycle label — EXCEPT
  # gate:needs-fix, the gate-fix RE-DISPATCH loop, which stays a candidate UNLESS a
  # marker is ACTIVELY re-gating it right now. That needs-fix carve-out reuses
  # _beadid_has_active_gate_artifact (the exact signal-(d) semantics), so a needs-fix
  # bead whose only marker is failed/error/needs-rebase still dispatches and we never
  # reintroduce the rig-scan/held-until deadlock. Gate artifacts always live in the HQ
  # store (GC_CITY) regardless of the bead's rig. FAIL-OPEN throughout: every gate
  # read returns "not in gate" on any error, so an unreadable query NEVER drops a
  # candidate (never wedge dispatch on a bad read).
  while IFS=$'\t' read -r id _bounced _glabel; do
    [ -z "$id" ] && continue
    if [ "$_bounced" = "1" ]; then
      # gate:needs-fix → re-dispatchable; drop ONLY if a marker is actively re-gating now.
      if _beadid_has_active_gate_artifact "$id"; then
        ingate_ids="${ingate_ids:+$ingate_ids }$id"
        ingate_reasons="${ingate_reasons}${id}"$'\t'"gate:needs-fix + actively re-gating (open marker)"$'\n'
      fi
    elif [ "$_glabel" = "1" ] || _beadid_has_open_gate_marker "$id"; then
      # a gate:* lifecycle label OR any OPEN quality-gate-marker → built / in the gate.
      ingate_ids="${ingate_ids:+$ingate_ids }$id"
      if [ "$_glabel" = "1" ]; then
        ingate_reasons="${ingate_reasons}${id}"$'\t'"gate:* lifecycle label present"$'\n'
      else
        ingate_reasons="${ingate_reasons}${id}"$'\t'"open quality-gate-marker (source-bead)"$'\n'
      fi
    fi
  done < <(printf '%s' "$arr" | jq -r '
      .[]? | (.labels // []) as $L | (.id // "") as $id | select($id != "")
      | [ $id,
          (if (($L | index("gate:needs-fix")) or ($L | any(startswith("gate:fix-attempt:")))) then "1" else "0" end),
          (if (($L | map(select(
                (. == "gate" or startswith("gate:"))
                and (. != "gate:needs-fix") and (startswith("gate:needs-fix:") | not)
                and (. != "gate:needs-human") and (startswith("gate:needs-human") | not)
                and (startswith("gate:fix-attempt:") | not)
              )) | length) > 0) then "1" else "0" end)
        ] | @tsv' 2>/dev/null)

  # ── Branch consultation (the original built-check) ───────────────────────────
  # Hermetic test seam: PILOT_TEST_BRANCH_BEADS lists ids treated as "built" (no git) —
  # the same seam _beadid_has_branch uses. No git / no repo set → no branch drops
  # (fail-open to KEEP; the gate consultation above still applies independently).
  if [ -n "${PILOT_TEST_BRANCH_BEADS+x}" ]; then
    built_ids="$PILOT_TEST_BRANCH_BEADS"
    for id in $built_ids; do
      built_reasons="${built_reasons}${id}"$'\t'"branch exists (PILOT_TEST_BRANCH_BEADS test seam)"$'\n'
    done
  elif command -v git >/dev/null 2>&1; then
    repos="$(_ownership_guard_repos)"
    if [ -n "$repos" ]; then
      while IFS= read -r id; do
        [ -z "$id" ] && continue
        while IFS= read -r r; do
          [ -n "$r" ] && [ -d "$r" ] || continue
          _matched_ref=$(git -C "$r" for-each-ref --format='%(refname)' \
               "refs/remotes/origin/crew/*/$id" "refs/heads/crew/*/$id" \
               "refs/remotes/origin/fix/$id-*" "refs/heads/fix/$id-*" 2>/dev/null | head -1)
          if [ -n "$_matched_ref" ]; then
            # ga-rcees: a matched ref is no longer an UNCONDITIONAL veto. Classify
            # it via _beadid_branch_signal (ga-8jxe1) and let "orphan" (unmerged +
            # stale + unassigned) fall through instead of vetoing forever — the same
            # carve-out _ownership_guard_should_refuse already applies inside
            # dispatch_one(), just too late: a bead with an orphan branch never
            # survives THIS filter to reach that check. Deliberately narrow: only
            # "orphan" changes behavior here. "block"/"merged"/unclassifiable all
            # preserve the EXACT pre-fix veto, so a classification miss (no git, no
            # match via the independent _beadid_matched_crew_branch_ref lookup, etc.)
            # fails toward the old behavior, never toward a new one.
            _bf_json=$(printf '%s' "$arr" | jq -c --arg i "$id" '.[] | select(.id == $i)' 2>/dev/null | head -1)
            _bf_signal="$(_beadid_branch_signal "$id" "$_bf_json")"
            if [ "${_bf_signal%%$'\t'*}" = "orphan" ]; then
              _ownership_guard_flag_orphan_branch "$id" "$GC_CITY" "${_bf_signal#*$'\t'}"
              built_reasons="${built_reasons}${id}"$'\t'"branch $_matched_ref orphaned (unmerged+stale+unassigned) — not vetoing, flagged pilot:orphan-branch"$'\n'
            else
              built_ids="${built_ids:+$built_ids }$id"
              built_reasons="${built_reasons}${id}"$'\t'"branch $_matched_ref exists"$'\n'
            fi
            break
          fi
        done <<< "$repos"
      done < <(printf '%s' "$arr" | jq -r '.[]?.id // empty' 2>/dev/null)
    fi
  fi

  # ── Combine: drop a candidate that is branch-built (except gate:needs-fix OR
  #    gate:fix-attempt:N, whose own fix-branch is expected) OR in-gate (ingate_ids
  #    already encodes both carve-outs, so an id is present here ONLY when actively
  #    re-gated). FAIL-OPEN to the unfiltered array on any jq error.
  #
  # ga-ltjdx: this OR used to check ONLY the literal "gate:needs-fix" label — a
  # DIFFERENT, narrower check than the _bounced computation two blocks up (which
  # ga-d3eg2 already widened to ALSO match gate:fix-attempt:N). A bead bounced via
  # fix-attempt:N alone (gate:fix-attempt:1 + gate-sha-failed:<sha>, no needs-fix —
  # exactly what a gate FAIL leaves behind) correctly avoided ingate_ids here, but
  # then still lost to this OR's narrower label check whenever its own fix branch
  # existed — the normal, expected state of a bead mid gate-fix-loop. Net effect
  # (measured live, ga-ub8yq): _filter_built excluded it from EVERY sweep, so no
  # fixer was ever (re-)dispatched. Widening this OR to the same startswith match
  # closes the gap; ingate_ids (unchanged) still independently vetoes an ACTIVELY
  # re-gated bead of either flavor, so the ga-htjni double-dispatch protection is
  # preserved.
  if [ -z "$built_ids" ] && [ -z "$ingate_ids" ]; then
    printf '%s' "$arr"; return
  fi
  _out=$(printf '%s' "$arr" | jq --arg b "$built_ids" --arg g "$ingate_ids" '
      ($b|split(" ")) as $bi | ($g|split(" ")) as $gi
      | [ .[] | select(
            ( ((.id as $i | $bi | index($i)) | not)
              or ((.labels // []) | any(. == "gate:needs-fix" or startswith("gate:fix-attempt:"))) )
            and ((.id as $i | $gi | index($i)) | not)
        ) ]' \
    2>/dev/null || printf '%s' "$arr")

  # ── ga-yolmi PASSO 1: per-bead exclusion trace. Read-only re-derivation of why
  # an id present in $arr is absent from $_out, using the reason strings already
  # collected above (built_reasons / ingate_reasons — including the gate:needs-fix
  # carve-out, since a needs-fix id only ends up in ingate_reasons when actively
  # re-gated). Never influences $_out.
  _kept_sp=" $(printf '%s' "$_out" | jq -r '.[].id' 2>/dev/null | tr '\n' ' ')"
  { printf '%s' "$built_reasons"; printf '%s' "$ingate_reasons"; } | while IFS=$'\t' read -r _bid _breason; do
    [ -z "$_bid" ] && continue
    case "$_kept_sp" in
      *" $_bid "*) continue ;;
    esac
    log "[pilot] EXCLUÍDO $_bid por _filter_built: $_breason" >&2
  done

  printf '%s' "$_out"
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
  # IDENTICAL filter chain to the real dispatch path (ga-aprov: the emit feeds BOTH the
  # painel "Aprovadas" column AND the imparavel-check, so it MUST exclude exactly what
  # real dispatch excludes. Previously it ran only _filter_candidates|_unblocked|_explicit_deps,
  # leaking exec:manual + status=blocked/deferred + blocked-on:* + design-first into
  # "dispatchable" — so blocked/manual work showed as READY in Aprovadas. Now matches the
  # real chain: + _filter_exec_manual + _filter_dispatch_gates + _filter_built.)
  _merged=$(echo "$_merged" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built | _filter_unblocked "$_db" | _filter_explicit_deps "$_db")
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
  if [ "$DOLT_SAT_REASON" = "unreadable" ]; then
    warn "Dolt health UNREADABLE at sweep start (latency=${DOLT_LATENCY_MS:-?}ms pid=${DOLT_PID:-?} cpu=$(_dolt_cpu)% — probe returned no signal, NOT a measured value). Fail-safe: throttling to 1 dispatch/lane this sweep same as genuine saturation, since adding load to an unknown/possibly-wedged Dolt is the incident this guards against (ga-hzt7; ga-rk5va backoff)."
  else
    warn "Dolt SATURATED at sweep start (latency=${DOLT_LATENCY_MS:-?}ms pid=${DOLT_PID:-?} cpu=$(_dolt_cpu)% thresholds: lat>${PILOT_DOLT_LATENCY_MAX_MS} cpu>${PILOT_DOLT_CPU_MAX}). Throttling to 1 dispatch/lane this sweep (ga-rk5va backoff)."
  fi
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
  _stale_json=$(bd -C "$_db" list --json \
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
        if _sling_is_live "$_sling" "$_sling_db" "$_bid"; then
          warn "TTL: $_bid age=${_age}s > TTL but sling task $_sling is still '$_sling_status' (db=$_sling_db) + LIVE (branch/fresh activity) — builder active, refusing to release."
          continue
        fi
        warn "TTL: $_bid age=${_age}s > TTL, sling $_sling open ('$_sling_status') but STALE (no crew branch, idle >${STALE_SLING_SECONDS}s) — DEAD sling (worker leaked it open), closing it + releasing the claim."
        bd -C "$_sling_db" close "$_sling" --reason "Stale sling auto-closed by Pilot TTL-release: open but idle >${STALE_SLING_SECONDS}s with no crew branch — was HOL-blocking $_bid (dead-builder leak)." -q 2>/dev/null || true
        # fall through to release the claim below
      fi
    fi

    warn "Releasing stale pilot:dispatching claim on $_bid (age=${_age}s > TTL=${_ttl}s, stamp-based, db=$_db)."
    bd -C "$_db" label remove "$_bid" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
  done
}

# ── TTL claim-recovery — INVOCATION RELOCATED below (ga-wisp-1gdiik crash-loop fix) ──
# _ttl_recover_db calls _sling_is_live / uses STALE_SLING_SECONDS / _ownership_guard_repos,
# all defined ~290 lines down. Invoking here aborted under `set -u` (STALE_SLING_SECONDS
# unbound) the moment a stale sling existed → Pilot exit=1 crash-loop. The whole block now
# runs right after those helpers are defined — search "TTL claim-recovery (relocated)".

# ── Step 1: Per-lane capacity check ──────────────────────────────────────────
# Count in-flight beads per lane by reading their lane:big / lane:small labels.
# Beads without a lane label (manually dispatched) count as small (conservative).

# ga-mfeip: fan-out to HQ + every non-HQ rig store so rig-native in-flight beads
# (wa-*/ps-*/lx-* prefixes, living in rig-own Dolt stores) are visible to the
# dead-worker detector and busy-builder tracker below. Attach _rig_db to each bead
# so store-aware sling lookups can route to the right Dolt instance.
_IN_FLIGHT_HQ=$(bd -C "$GC_CITY" list --json -l "story:in-flight" 2>/dev/null \
  | jq --arg db "$GC_CITY" '[ .[] | . + {"_rig_db": $db} ]' 2>/dev/null || echo "[]")
IN_FLIGHT_RAW_JSON="$_IN_FLIGHT_HQ"
_in_flight_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
  | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
while IFS= read -r _in_flight_rig; do
  [ -z "$_in_flight_rig" ] || [ ! -d "$_in_flight_rig" ] && continue
  _rig_inflight=$(bd -C "$_in_flight_rig" list --json -l "story:in-flight" 2>/dev/null \
    | jq --arg db "$_in_flight_rig" '[ .[] | . + {"_rig_db": $db} ]' 2>/dev/null || echo "[]")
  IN_FLIGHT_RAW_JSON=$(printf '%s\n%s' "$IN_FLIGHT_RAW_JSON" "$_rig_inflight" \
    | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "$IN_FLIGHT_RAW_JSON")
done <<< "$_in_flight_rig_paths"
unset _IN_FLIGHT_HQ _in_flight_rig_paths _in_flight_rig _rig_inflight

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

# ── Asleep-session roster (ga-mrfb: drained ephemeral worker ≠ live builder) ───
# A non-closed session whose state is "asleep". An EPHEMERAL pool worker
# (…-adhoc-…, wake_mode=fresh) goes state=="asleep" once it drain-acks — it has
# finished and will NEVER resume THIS build (a fresh wake re-claims from the pool,
# it does not continue prior work). But it keeps closed!=true for a while, so the
# broad _session_is_live counts it "live" → its in-flight bead wedges (NEVERSTARTED
# keeps it) AND its pool slot stays falsely occupied (dead-worker slot-correction
# keeps it). Observed: ps-mrfb/ps-joc0 stuck story:in-flight 80+min behind asleep
# adhoc workers that `gc session peek` reports "not found". Indexed here so the
# "is this worker ACTIVELY building?" checks can treat such a worker as dead.
# NOTE: named crews that are merely asleep are NOT dead-builders — the dispatch
# REUSE path (gt-4st3n) wakes asleep sessions on purpose — so this set is consulted
# ONLY for …-adhoc-… workers (see _session_is_live_builder); _session_is_live and
# the ownership/crew-owner guards keep their full not-closed semantics.
_ASLEEP_SESSION_IDS=$(echo "$_SESSIONS_JSON" \
  | jq -r '[.sessions[]? | select(.closed != true) | select(.state == "asleep")
           | (.session_name, .name, .alias, .id, .agent_name)]
          | map(select(. != null and . != "")) | unique | .[]' 2>/dev/null || echo "")

# _session_is_live <identifier> — exit 0 iff <identifier> is a non-closed session.
_session_is_live() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$_LIVE_SESSION_IDS" | grep -Fxq -- "$1"
}

# _session_is_asleep <identifier> — exit 0 iff <identifier> is a non-closed, asleep session.
_session_is_asleep() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$_ASLEEP_SESSION_IDS" | grep -Fxq -- "$1"
}

# _session_is_live_builder <identifier> — exit 0 iff the session is a worker that
# is ACTIVELY building right now: non-closed AND not a drained ephemeral pool
# worker. A …-adhoc-… worker that has gone asleep has drain-acked (wake_mode=fresh
# → it will never resume the in-flight build it was dispatched for); treating it as
# a live builder wedges its bead (NEVERSTARTED) and falsely holds its pool slot.
# Named/non-adhoc sessions keep full _session_is_live semantics (an asleep crew is
# still its bead's owner, and the dispatch REUSE path wakes it deliberately).
_session_is_live_builder() {
  [ -n "${1:-}" ] || return 1
  _session_is_live "$1" || return 1
  case "$1" in
    *-adhoc-*) _session_is_asleep "$1" && return 1 ;;   # drained ephemeral worker → dead builder
  esac
  return 0
}

# ── Active-owner roster (ga-46wq5: idle/asleep-but-not-closed owner ≠ active
# owner). last_active is RFC3339 with a NUMERIC offset (e.g. "-03:00"), not a
# literal "Z" — confirmed live that jq's fromdateiso8601 in this environment
# REJECTS that format outright (only accepts "...Z"), so this file's existing
# created_at truncate-and-append-Z trick (used elsewhere for bd-native
# timestamps, which ARE always "Z"-suffixed) cannot be reused here: applied to
# an offset string it would silently misinterpret local time as UTC. Compute
# idle-minutes in python3 instead — the same approach
# scripts/adhoc-session-reaper.sh already uses for this exact field — once per
# sweep over the WHOLE roster (not per-assignee), mirroring how _SESSIONS_JSON
# itself is fetched once above.
_SESSIONS_IDLE_JSON=$(printf '%s' "$_SESSIONS_JSON" | python3 -c '
import sys, json, datetime
data = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
for s in data.get("sessions") or []:
    la = s.get("last_active") or ""
    idle = None
    if la and not la.startswith("0001-01-01"):
        try:
            t = la[:-1] + "+00:00" if la.endswith("Z") else la
            idle = int((now - datetime.datetime.fromisoformat(t)).total_seconds() // 60)
        except Exception:
            idle = None
    s["idle_minutes"] = idle
json.dump(data, sys.stdout)
' 2>/dev/null)
[ -n "$_SESSIONS_IDLE_JSON" ] || _SESSIONS_IDLE_JSON="$_SESSIONS_JSON"

# "Active owner" = live AND NOT asleep AND NOT idle beyond threshold. Folding
# in state=="asleep" directly (not just idle-minutes) matters: an asleep
# session's last_active IS the Go zero-time sentinel by design (confirmed live
# — every currently-asleep session in this roster, adhoc AND named/core alike,
# reports last_active="0001-01-01T00:00:00Z"; this is routine per this file's
# own REUSE-not-respawn doctrine a few hundred lines up, not an edge case), so
# an idle-minutes-only check would silently NEVER flag a merely-asleep owner —
# failing the bug's own first fixture ("sessão está asleep... É despachado").
PILOT_ASSIGNEE_IDLE_MINUTES="${PILOT_ASSIGNEE_IDLE_MINUTES:-180}"
_ACTIVE_OWNER_IDS=$(echo "$_SESSIONS_IDLE_JSON" \
  | jq -r --argjson thresh "$PILOT_ASSIGNEE_IDLE_MINUTES" \
    '[.sessions[]? | select(.closed != true) | select(.state != "asleep")
             | select((.idle_minutes == null) or (.idle_minutes < $thresh))
             | (.session_name, .name, .alias, .id, .agent_name)]
            | map(select(. != null and . != "")) | unique | .[]' 2>/dev/null || echo "")
_ACTIVE_OWNER_IDS_JSON=$(printf '%s' "$_ACTIVE_OWNER_IDS" \
  | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")
_ROSTER_OK_FOR_FILTER=$_DEADWORKER_OK

# _session_is_active_owner <identifier> — exit 0 iff <identifier> is a
# confirmed active owner: not closed, not asleep, and (idle-time unknown OR
# under PILOT_ASSIGNEE_IDLE_MINUTES). Unknown idle-time deliberately resolves
# to "still active" (fail toward NO behavior change vs pre-fix) — most
# unknowns are fresh -adhoc- pool workers that never populated last_active at
# all, and mass-reclaiming THEIR beads was never what ga-46wq5 asked for.
_session_is_active_owner() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$_ACTIVE_OWNER_IDS" | grep -Fxq -- "$1"
}

# ── Stale-sling liveness (dead-builder HOL-block fix) ─────────────────────────
# An OPEN sling/wrapper whose worker DIED leaks open forever, and both the TTL-release
# and the dedup guard trusted open-ness as "builder active" → the bead is HOL-blocked
# indefinitely (ga-gbu87/ga-vp0c3 sat open 3 DAYS with no session/branch/activity,
# blocking ga-wm12t/ga-a3lmo — the "beads travadas em execução"). _sling_is_live tells a
# live sling from a dead one. Default idle window 180min (4-6× a normal build) so a slow
# live builder is NEVER false-released.
STALE_SLING_SECONDS="${PILOT_STALE_SLING_SECONDS:-10800}"
case "$STALE_SLING_SECONDS" in ''|*[!0-9]*) STALE_SLING_SECONDS=10800 ;; esac

# _iso_to_epoch <iso8601> — best-effort ISO→epoch (BSD then GNU); echoes "" on failure.
_iso_to_epoch() {
  local _t="${1%%.*}"; _t="${_t%Z}"
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$_t" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null || echo ""
}

# _target_has_real_branch <bead_id> — return 0 ONLY if a crew or dog fix/ branch for the
# bead actually exists (ga-6jqr: was crew/*/<id>-only, blind to the fix/<id>-* shape dog
# builders push). Self-contained repo list. Any uncertainty → return 1 (assert NO branch)
# so this only ever ADDS a keep-signal, never forces a release.
_target_has_real_branch() {
  command -v git >/dev/null 2>&1 || return 1
  local _repos _r
  _repos="$(_ownership_guard_repos 2>/dev/null)" || return 1
  [ -n "$_repos" ] || return 1
  while IFS= read -r _r; do
    [ -n "$_r" ] && [ -d "$_r" ] || continue
    git -C "$_r" for-each-ref --format='%(refname)' \
        "refs/remotes/origin/crew/*/$1" "refs/heads/crew/*/$1" \
        "refs/remotes/origin/fix/$1-*" "refs/heads/fix/$1-*" 2>/dev/null | grep -q . && return 0
  done <<< "$_repos"
  return 1
}

# _sling_is_live <sling_id> <sling_db> <target_bead_id> — return 0 iff an OPEN sling is backed
# by a REAL live builder: a crew branch for its target (work in progress) OR sling activity
# within STALE_SLING_SECONDS. FAIL-OPEN to LIVE — any unreadable/unparseable signal → assume
# live, so a genuine active builder is NEVER false-released; only a provably-idle, branch-less
# sling is declared dead. Test seam: PILOT_TEST_DEAD_SLINGS (space-sep ids treated as dead).
_sling_is_live() {
  local _sid="${1:-}" _sdb="${2:-$GC_CITY}" _tid="${3:-}" _upd _epoch _nowts
  [ -n "$_sid" ] || return 0
  if [ -n "${PILOT_TEST_DEAD_SLINGS+x}" ]; then
    case " $PILOT_TEST_DEAD_SLINGS " in *" $_sid "*) return 1 ;; *) return 0 ;; esac
  fi
  [ -n "$_tid" ] && _target_has_real_branch "$_tid" && return 0
  _upd=$(bd -C "$_sdb" show "$_sid" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.updated_at // "")' 2>/dev/null || echo "")
  _epoch="$(_iso_to_epoch "$_upd")"
  [ -z "$_epoch" ] && return 0                       # unparseable → cannot prove idle → LIVE
  _nowts="${_now:-$(date +%s)}"
  [ $(( _nowts - _epoch )) -le "$STALE_SLING_SECONDS" ] && return 0
  return 1                                            # no branch + idle beyond window → DEAD
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
#
# PHANTOM-AWARE (FOLLOW-UP #1, ga-9yb5s+): a crew session may be live yet the
# bead was never started — no crew/<crew>/<bead> branch AND stale > 45min. In
# that case return 1 (phantom) so the bead releases and flows to the wa-worker
# pool. Only releases when BOTH confirmed: no branch + stale. Fail-conservative:
# git/repos undecidable, or updated_at missing/unparseable → KEEP (return owner).
# Knob: PILOT_PHANTOM_STALE_SECS (default 2700 = 45min).
# Test seam: PILOT_TEST_PHANTOM_STALE_BEADS (space-list of ids treated as stale).
_beadid_live_crew_owner() {
  local _bid="${1:-}" _db="${2:-$GC_CITY}" _asg _bead_json
  [ -n "$_bid" ] || return 1
  [ "${_DEADWORKER_OK:-0}" = "1" ] || return 1
  _bead_json=$(bd -C "$_db" show "$_bid" --json 2>/dev/null || echo "")
  _asg=$(printf '%s' "$_bead_json" \
    | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
  { [ -z "$_asg" ] || [ "$_asg" = "null" ]; } && return 1
  case "$_asg" in gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) return 1 ;; esac
  _session_is_live "$_asg" || return 1

  # ── Phantom-claim guard ─────────────────────────────────────────────────────
  local _is_stale=0
  if [ -n "${PILOT_TEST_PHANTOM_STALE_BEADS+x}" ]; then
    # Hermetic test seam: bead ids listed here are treated as stale (>45min).
    case " $PILOT_TEST_PHANTOM_STALE_BEADS " in *" $_bid "*) _is_stale=1 ;; esac
  else
    local _upd_epoch _phantom_now
    _upd_epoch=$(printf '%s' "$_bead_json" | jq -r \
      'if type=="array" then .[0] else . end | (.updated_at // "")
       | if . == "" then "0" else (try (fromdateiso8601 | tostring) catch "0") end' \
      2>/dev/null || echo "0")
    _phantom_now=$(date +%s)
    [ "$_upd_epoch" != "0" ] \
      && [ "$(( _phantom_now - _upd_epoch ))" -gt "${PILOT_PHANTOM_STALE_SECS:-2700}" ] \
      2>/dev/null && _is_stale=1
  fi
  if [ "$_is_stale" = "1" ] \
     && command -v git >/dev/null 2>&1 \
     && [ -n "$(_ownership_guard_repos 2>/dev/null)" ] \
     && ! _beadid_has_crew_branch "$_bid"; then
    return 1   # phantom: stale + no branch → release for wa-worker re-dispatch
  fi
  # ── end phantom-claim guard ─────────────────────────────────────────────────

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
  local _arr _n _i _bead _sling _asg _kept _ddw_bid _ddw_bead_db _ddw_sling_db
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
      # ga-mfeip cross-DB fix: a self-referential sling (pilot.sling_bead == bead id) is the
      # routed-pool pattern — the "sling" IS the rig-native bead, living in its own store
      # (_rig_db field attached when IN_FLIGHT_RAW_JSON was built), NOT in HQ ($GC_CITY).
      # Reading it from $GC_CITY returns a null assignee → dead-worker false-drop of a live
      # rig-native worker whose session is still active. Mirror the _neverstarted_recover_db guard.
      _ddw_sling_db="$GC_CITY"
      _ddw_bid=$(echo "$_bead" | jq -r '.id // ""' 2>/dev/null || echo "")
      _ddw_bead_db=$(echo "$_bead" | jq -r '._rig_db // ""' 2>/dev/null || echo "")
      [ -n "$_ddw_bead_db" ] && [ -n "$_ddw_bid" ] && [ "$_sling" = "$_ddw_bid" ] && _ddw_sling_db="$_ddw_bead_db"
      _asg=$(bd -C "$_ddw_sling_db" show "$_sling" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
      if [ -n "$_asg" ] && ! _session_is_live_builder "$_asg"; then
        continue   # confirmed dead worker (incl. drained-asleep adhoc) → free this slot
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

# _crew_progressed_since <crew> <since_epoch> — true (0) iff the crew has pushed a
# branch (crew/<crew>/* or crew/<crew-short>/* in any _NS_BRANCH_REPOS) whose latest
# commit is NEWER than <since_epoch>. Proof the crew is actively building (producing
# branches) — so a bead it OWNS but never branched, past the owner-grace window, was
# SKIPPED/declined rather than slow-built. Hermetic test seam: PILOT_TEST_CREW_PROGRESSED
# (space-list of crews treated as "progressed"). FAIL-SAFE: any error / no repos / no
# git → return 1 (cannot prove progress → caller KEEPS the bead — the conservative side).
_crew_progressed_since() {
  local _crew="${1:-}" _since="${2:-}" _repo _short _pat _latest
  [ -n "$_crew" ] && [ -n "$_since" ] || return 1
  if [ -n "${PILOT_TEST_CREW_PROGRESSED+x}" ]; then
    case " $PILOT_TEST_CREW_PROGRESSED " in *" $_crew "*) return 0 ;; *) return 1 ;; esac
  fi
  command -v git >/dev/null 2>&1 || return 1
  [ -n "${_NS_BRANCH_REPOS:-}" ] || return 1
  _short="${_crew%-*}"   # mila-wa -> mila (the crew/<short>/<bead> branch convention)
  while IFS= read -r _repo; do
    [ -n "$_repo" ] && [ -d "$_repo" ] || continue
    for _pat in "crew/$_crew/" "crew/$_short/"; do
      _latest=$(git -C "$_repo" for-each-ref --sort=-committerdate \
        --format='%(committerdate:unix)' \
        "refs/remotes/origin/${_pat}*" "refs/heads/${_pat}*" 2>/dev/null | head -1)
      [ -n "$_latest" ] && [ "$_latest" -gt "$_since" ] 2>/dev/null && return 0
    done
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

# ── TTL claim-recovery (relocated from ~L1586, ga-wisp-1gdiik) ────────────────
# Runs HERE, after the stale-sling helpers + _ownership_guard_repos are defined, so
# _ttl_recover_db has every symbol it needs (was a define-after-use crash under set -u).
# Still runs before the candidate/dispatch queries, so released claims flow this sweep.
TTL_NOW_EPOCH=$(date +%s)
TTL_SECS=$((CLAIM_TTL_MINUTES * 60))

_ttl_recover_db "$GC_CITY" "$TTL_NOW_EPOCH" "$TTL_SECS"

_ttl_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
  | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
while IFS= read -r _ttl_rig; do
  [ -z "$_ttl_rig" ] || [ ! -d "$_ttl_rig" ] && continue
  _ttl_recover_db "$_ttl_rig" "$TTL_NOW_EPOCH" "$TTL_SECS"
done <<< "$_ttl_rig_paths"

# _beadid_has_crew_branch <bead_id> — exit 0 iff a branch named like
# `crew/<owner>/<bead-id>` OR `fix/<bead-id>-<slug>` exists in ANY town/rig repo,
# local OR remote-tracking, AND (best-effort) directly on the rig remote via a
# bounded `ls-remote`. This is the ga-htjni signal-(a): a pushed crew/fix branch
# means a build is real/in-flight. It is STRICTER than _beadid_has_branch (which
# matches the id anywhere in any ref) — here we require one of the two KNOWN
# builder-branch shapes so a stray tag/note never false-fires; the end-anchor
# avoids matching a longer id that merely contains this one as a prefix.
# ga-6jqr: originally crew/-only, blind to the fix/<id>-* shape dog builders
# push — a dog-built bead read "no branch" here and got double-dispatched.
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
  # crew/<anything>/<bead> at a ref tail, OR a bare crew/<bead> (defensive), OR
  # a dog-built fix/<bead>-<slug> (ga-6jqr — the DOG builder branch shape; the
  # trailing "-" requires a real slug so a longer id sharing this one as a
  # prefix, e.g. "${_bid}2", never false-matches).
  _re="(crew/([^/]+/)?${_bid}|fix/${_bid}-[^/]+)\$"
  while IFS= read -r _repo; do
    [ -n "$_repo" ] && [ -d "$_repo" ] || continue
    # 1. Already-fetched local + remote-tracking refs (cheap, offline).
    if git -C "$_repo" for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | grep -qiE "$_re"; then
      return 0
    fi
    # 2. Best-effort authoritative remote probe (bounded; the live origin/crew/*
    #    or origin/fix/* branch ga-htjni hit may not be fetched locally). A
    #    timeout / offline remote is NOT evidence of a branch → fall through
    #    (fail-open), never block.
    if git -C "$_repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
       || git -C "$_repo" remote 2>/dev/null | grep -q .; then
      if timeout 8 git -C "$_repo" ls-remote --heads origin "crew/*/${_bid}" "crew/${_bid}" "fix/${_bid}-*" 2>/dev/null \
          | grep -qiE "refs/heads/${_re}"; then
        return 0
      fi
    fi
  done <<< "$_repos"
  return 1
}

# _beadid_matched_crew_branch_ref <bead_id> — ga-8jxe1 AC2 companion to
# _beadid_has_crew_branch above. Deliberately a SEPARATE function (not a
# refactor of it) — this file's established pattern for branch-existence
# checks is several independently-testable functions with overlapping probe
# logic (_filter_built / _target_has_real_branch / _beadid_has_crew_branch
# itself; ga-6jqr), so a 4th here follows the grain rather than risking the
# existing selftest coverage of _beadid_has_crew_branch's exact source shape.
# Prints "<repo>\t<ref>" on a match (ref is EMPTY when the match came only from
# the ls-remote fallback — no local ref object exists to inspect further, e.g.
# for merge/staleness below); exit 0/1 exactly like _beadid_has_crew_branch.
# Lets a caller report the REAL matched ref (e.g. "fix/ga-8jxe1-slug") instead
# of a hardcoded "crew/*/<bead>" guess — the old WARN message lied about the
# evidence whenever a dog's fix/* branch, not a crew/* branch, was what
# actually matched (cost real diagnosis time on ga-8jxe1 itself).
_beadid_matched_crew_branch_ref() {
  local _bid="${1:-}" _repo
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_CREW_BRANCH_BEADS+x}" ]; then
    case " $PILOT_TEST_CREW_BRANCH_BEADS " in
      *" $_bid "*) printf '%s\t%s' "${PILOT_TEST_CREW_BRANCH_REPO:-.}" "${PILOT_TEST_CREW_BRANCH_REF:-fix/${_bid}-test}"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  command -v git >/dev/null 2>&1 || return 1
  local _repos _re _match
  _repos=$(_ownership_guard_repos)
  [ -n "$_repos" ] || return 1
  _re="(crew/([^/]+/)?${_bid}|fix/${_bid}-[^/]+)\$"
  while IFS= read -r _repo; do
    [ -n "$_repo" ] && [ -d "$_repo" ] || continue
    _match=$(git -C "$_repo" for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
        | grep -iE "$_re" | head -1)
    if [ -n "$_match" ]; then
      printf '%s\t%s' "$_repo" "$_match"
      return 0
    fi
    if git -C "$_repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
       || git -C "$_repo" remote 2>/dev/null | grep -q .; then
      if timeout 8 git -C "$_repo" ls-remote --heads origin "crew/*/${_bid}" "crew/${_bid}" "fix/${_bid}-*" 2>/dev/null \
          | grep -qiE "refs/heads/${_re}"; then
        printf '%s\t' "$_repo"   # repo known, ref unresolved locally (ls-remote-only)
        return 0
      fi
    fi
  done <<< "$_repos"
  return 1
}

# _beadid_branch_signal <bead_id> <bead_json> — ga-8jxe1: classifies a matched
# crew/fix branch instead of treating "branch exists" as an unconditional
# in-flight signal. FAIL-OPEN toward the PRE-FIX behaviour, never toward a NEW
# failure mode: any unresolvable merge-base/log probe classifies "block" with
# the matched ref — exactly what the old boolean-only signal (a) would have
# done. Silent by design (matches every other signal-helper in this file —
# ONLY the top-level dispatch_one() logs); MUST NOT write to stdout/stderr
# beyond its own final printf, because both call sites capture this chain via
# `_OWN_REASON=$(_ownership_guard_should_refuse ...)` — a stray log line here
# would corrupt that captured string (the exact hazard the dispatch_one()
# DISPATCHED-mutation comment above warns about, for the same $(...) reason).
#
# Prints "<class>\t<detail>" to stdout, exit 0 iff a branch matched at all
# (exit 1 = no branch — identical to _beadid_has_crew_branch's original
# "no signal" case):
#   block  \t <real ref>                 — unmerged and NOT stale (or matched
#                                           only via ls-remote, no local ref to
#                                           inspect) → preserve the EXACT
#                                           pre-fix behaviour: refuse.
#   merged \t <ref>                      — AC1a: `git merge-base --is-ancestor
#                                           <ref> origin/main` succeeds → the
#                                           build already shipped, this is NOT
#                                           an in-flight signal.
#   orphan \t <repo>\t<ref>\t<age_days>   — AC1b: unmerged, last commit older
#                                           than PILOT_ORPHAN_BRANCH_STALE_HOURS,
#                                           AND the bead's OWN snapshot assignee
#                                           ($_json — the candidate query
#                                           already required it empty) is empty
#                                           → abandoned, not active.
# Test seams (space-lists of bead ids, hermetic — consulted only when the
# underlying branch match already succeeded via PILOT_TEST_CREW_BRANCH_BEADS):
#   PILOT_TEST_BRANCH_MERGED_BEADS  — force the "merged" classification.
#   PILOT_TEST_ORPHAN_BRANCH_BEADS  — force "orphan" (else falls to "block").
_beadid_branch_signal() {
  local _bid="${1:-}" _json="${2:-}" _repo _ref _rt
  [ -n "$_bid" ] || return 1
  _rt="$(_beadid_matched_crew_branch_ref "$_bid")" || return 1
  _repo="${_rt%%$'\t'*}"
  _ref="${_rt#*$'\t'}"
  if [ -z "$_ref" ]; then
    printf 'block\tcrew/*/%s' "$_bid"
    return 0
  fi
  if [ -n "${PILOT_TEST_BRANCH_MERGED_BEADS+x}" ]; then
    case " $PILOT_TEST_BRANCH_MERGED_BEADS " in
      *" $_bid "*) printf 'merged\t%s' "$_ref"; return 0 ;;
    esac
  elif command -v git >/dev/null 2>&1 \
     && git -C "$_repo" merge-base --is-ancestor "$_ref" origin/main 2>/dev/null; then
    printf 'merged\t%s' "$_ref"
    return 0
  fi
  # Unmerged. Snapshot assignee is a defensive re-check, not the primary
  # discriminator — the candidate query already guarantees it empty for
  # virtually every caller; kept for the (theoretical) path that doesn't.
  local _asg_snapshot
  _asg_snapshot=$(printf '%s' "$_json" | jq -r '(.assignee // "")' 2>/dev/null || echo "")
  if [ -n "$_asg_snapshot" ] && [ "$_asg_snapshot" != "null" ]; then
    printf 'block\t%s' "$_ref"
    return 0
  fi
  if [ -n "${PILOT_TEST_ORPHAN_BRANCH_BEADS+x}" ]; then
    case " $PILOT_TEST_ORPHAN_BRANCH_BEADS " in
      *" $_bid "*) printf 'orphan\t%s\t%s\ttest' "$_repo" "$_ref"; return 0 ;;
      *) printf 'block\t%s' "$_ref"; return 0 ;;
    esac
  fi
  local _age_secs _commit_epoch _now
  _commit_epoch=$(git -C "$_repo" log -1 --format=%ct "$_ref" 2>/dev/null || echo "")
  if [ -z "$_commit_epoch" ]; then
    printf 'block\t%s' "$_ref"   # unresolvable → fail toward pre-fix behaviour
    return 0
  fi
  _now=$(date +%s)
  _age_secs=$(( _now - _commit_epoch ))
  if [ "$_age_secs" -gt "$(( PILOT_ORPHAN_BRANCH_STALE_HOURS * 3600 ))" ]; then
    printf 'orphan\t%s\t%s\t%s' "$_repo" "$_ref" "$(( _age_secs / 86400 ))"
  else
    printf 'block\t%s' "$_ref"
  fi
  return 0
}

# _beadid_needs_remerge_branch <bead_id> — ga-e2n96 companion to
# _beadid_matched_crew_branch_ref above: the gate-fix re-dispatch path (a bead
# carrying gate:needs-fix/gate:needs-remerge with ZERO reviewer feedback) needs
# an ACTUAL branch name to resubmit to the gate, not just a repo+existence
# signal — that function's own ref can be EMPTY on an ls-remote-only match (see
# its doc comment), which isn't enough to build a gate marker. Scoped ONLY to
# the bug-tier convention dispatch_one() itself tells builders to use
# (fix/<bead>-<slug>, see the "Steps" section of DISPATCH_TASK below) — narrower
# than the crew-branch checker's crew/*/<bead> OR fix/<bead>-* union, since a
# re-merge candidate is by definition a bug/task bead (GAP-2's own "bugtask"
# verdict), never a fresh crew assignment. A 4th sibling function rather than a
# refactor of the existing three, following this file's established pattern
# (ga-8jxe1's own comment) of several independently-testable functions with
# overlapping probe logic, rather than risking their existing selftest coverage.
#
# Prints "<repo>\t<ref>" on a match (ref is ALWAYS populated — the whole reason
# for a dedicated helper); exit 0/1. Test seam: PILOT_TEST_REMERGE_BEADS
# (space-list), PILOT_TEST_REMERGE_REPO, PILOT_TEST_REMERGE_REF — consulted
# when PILOT_TEST_REMERGE_BEADS is DEFINED, keeps the selftest hermetic (no
# real git/network). FAIL-OPEN when undecidable: no git / no repos / no match
# → return 1 (caller falls back to human escalation, never a silent re-dispatch).
_beadid_needs_remerge_branch() {
  local _bid="${1:-}" _repo _match
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_REMERGE_BEADS+x}" ]; then
    case " $PILOT_TEST_REMERGE_BEADS " in
      *" $_bid "*) printf '%s\t%s' "${PILOT_TEST_REMERGE_REPO:-.}" "${PILOT_TEST_REMERGE_REF:-fix/${_bid}-test}"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  command -v git >/dev/null 2>&1 || return 1
  local _repos
  _repos=$(_ownership_guard_repos)
  [ -n "$_repos" ] || return 1
  while IFS= read -r _repo; do
    [ -n "$_repo" ] && [ -d "$_repo" ] || continue
    _match=$(git -C "$_repo" for-each-ref --format='%(refname:short)' "refs/heads/fix/${_bid}-*" "refs/remotes/origin/fix/${_bid}-*" 2>/dev/null | head -1)
    if [ -n "$_match" ]; then
      printf '%s\t%s' "$_repo" "${_match#origin/}"
      return 0
    fi
    if git -C "$_repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
       || git -C "$_repo" remote 2>/dev/null | grep -q .; then
      _match=$(timeout 8 git -C "$_repo" ls-remote --heads origin "fix/${_bid}-*" 2>/dev/null | head -1 | awk '{print $2}')
      if [ -n "$_match" ]; then
        printf '%s\t%s' "$_repo" "${_match#refs/heads/}"
        return 0
      fi
    fi
  done <<< "$_repos"
  return 1
}

# _ownership_guard_flag_orphan_branch <bead_id> <bead_city> <detail> — ga-8jxe1
# AC3: give an ownership-guard ORPHAN verdict (_beadid_branch_signal's "orphan"
# class) a path to resolution instead of a silent forever-veto. <detail> is
# "<repo>\t<ref>\t<age_days>" from _beadid_branch_signal. Idempotent (gated on
# the pilot:orphan-branch label itself — a later sweep finding the SAME orphan
# is a no-op, not a repeat comment) and NON-DESTRUCTIVE (never touches the
# branch — see the bug's own warning: deleting it would lose the unmerged
# work). Does NOT decide merge-worthy vs. dead — that judgment call is
# explicitly out of scope here (see the bug's "Triagem paralela" note) and
# belongs to a human/dog triage pass querying `bd list -l pilot:orphan-branch`.
# Best-effort: any bd failure here must never block the caller's dispatch
# decision. Every command output is suppressed (stdout AND stderr) — this runs
# inside the same $(...)-captured chain as _beadid_branch_signal above and
# must not leak a byte into _OWN_REASON/_RP_OWN_REASON.
# Test seam: PILOT_TEST_NOOP_ORPHAN_FLAG=1 skips all bd I/O (selftest hermeticity).
_ownership_guard_flag_orphan_branch() {
  local _bid="${1:-}" _city="${2:-$GC_CITY}" _detail="${3:-}" _repo _ref _age _cur_labels
  [ -n "$_bid" ] || return 0
  [ "${PILOT_TEST_NOOP_ORPHAN_FLAG:-0}" = "1" ] && return 0
  command -v bd >/dev/null 2>&1 || return 0
  _repo="${_detail%%$'\t'*}"; _detail="${_detail#*$'\t'}"
  _ref="${_detail%%$'\t'*}"; _age="${_detail#*$'\t'}"
  _cur_labels=$(bd -C "$_city" show "$_bid" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
  case ",$_cur_labels," in
    *,pilot:orphan-branch,*) return 0 ;;   # already flagged — idempotent, no repeat comment
  esac
  bd -C "$_city" label add "$_bid" "pilot:orphan-branch" -q >/dev/null 2>&1 || true
  bd -C "$_city" comment "$_bid" "ga-8jxe1: ownership-guard found an unmerged branch ('$_ref', repo $(basename "$_repo" 2>/dev/null || printf '%s' "$_repo")) idle ~${_age}d with no live owner — treating as an abandoned build, no longer auto-vetoing dispatch on it. Branch left untouched (never auto-deleted). Needs a triage judgment call: re-arm the gate off this branch if the work looks complete, or delete the branch and remove this label to free the bead for a fresh build. Queryable via: bd list -l pilot:orphan-branch" >/dev/null 2>&1 || true
  return 0
}

# _beadid_has_active_gate_artifact <bead_id> — ga-wisp gate-handoff signal (d).
# Exit 0 iff an OPEN quality-gate artifact in the HQ store (GC_CITY) references
# <bead_id> as its source-bead AND is ACTIVELY processing its branch right now.
# Gate artifacts are HQ-store beads (ga-wisp-*):
#   • type:quality-gate-marker — labels source-bead:<bead> + branch:crew/<crew>/<bead>
#     + gate-status:<state>. ACTIVE marker states (the gate is holding/working the
#     branch): ready → claimed → queued → dispatching → reviewing (the guard→queue→
#     dispatch→review pipeline).
#   • type:quality-gate-run — labels source-bead:<bead> + gate-status:running (reviewer live).
# NON-active (parked/terminal → the bead may LEGITIMATELY need re-dispatch): error,
# needs-rebase, passed, failed, superseded, done, deferred, parked-needs-human, OR a
# CLOSED artifact. Critically, the gate:needs-fix RE-FIX loop's only marker is
# failed/error → NON-active → this returns 1 (allow), so (d) NEVER deadlocks re-fix
# (the rig-scan / held-until fixes stay intact). Matches on the EXACT source-bead:<bead>
# label (no id-prefix collision), in ONE read of the HQ store.
# Test seam: PILOT_TEST_GATE_ACTIVE_BEADS (space-list), consulted when DEFINED, keeps the
# selftest hermetic (no live Dolt). FAIL-OPEN: no bd, any bd/jq error, or an empty/
# ambiguous read → return 1 (allow) — a bad gate-artifact read must never wedge dispatch.
_beadid_has_active_gate_artifact() {
  local _bid="${1:-}"
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_GATE_ACTIVE_BEADS+x}" ]; then
    case " $PILOT_TEST_GATE_ACTIVE_BEADS " in *" $_bid "*) return 0 ;; *) return 1 ;; esac
  fi
  command -v bd >/dev/null 2>&1 || return 1
  local _arts _hit
  _arts=$(bd -C "$GC_CITY" list -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null || echo "")
  [ -n "$_arts" ] || return 1
  # Count OPEN gate markers/runs for this source-bead carrying an ACTIVELY-processing
  # gate-status. index() yields a number (truthy, incl. 0) when present, null when
  # absent; a parked/terminal or closed artifact contributes 0.
  _hit=$(printf '%s' "$_arts" | jq -r '
      [ .[]
        | select(.status == "open")
        | (.labels // []) as $l
        | select( ($l | index("type:quality-gate-marker")) or ($l | index("type:quality-gate-run")) )
        | select(
            ($l | index("gate-status:ready"))       or
            ($l | index("gate-status:claimed"))     or
            ($l | index("gate-status:queued"))      or
            ($l | index("gate-status:dispatching")) or
            ($l | index("gate-status:reviewing"))   or
            ($l | index("gate-status:running"))
          )
      ] | length' 2>/dev/null || echo "0")
  case "$_hit" in ''|0) return 1 ;; *) return 0 ;; esac
}

# _beadid_has_open_gate_marker <bead_id> — (wa-8y45) broader sibling of
# _beadid_has_active_gate_artifact. Exit 0 iff an OPEN type:quality-gate-marker in the
# HQ store (GC_CITY) names <bead_id> via source-bead:<id>, at ANY gate-status. Unlike
# signal (d)'s ACTIVELY-processing filter, this ALSO counts parked/terminal marker
# states (needs-rebase / error / passed / …): such a bead is ALREADY BUILT and sitting
# in the gate pipeline — the crew branch is often PRUNED, so _filter_built's git probe
# can't see it, yet the durable marker persists. Mirrors imparavel-check._gate_source_beads
# (the downstream fix c9a8413f1). MARKER-only (runs are ephemeral); the exact
# source-bead:<id> label (no id-prefix collision) in ONE read of the HQ store.
# Test seam: PILOT_TEST_GATE_OPEN_BEADS (space-list), consulted when DEFINED, keeps the
# selftest hermetic. FAIL-OPEN: no bd, any bd/jq error, or an empty read → return 1
# (allow) — a bad gate-marker read must NEVER drop a candidate / wedge dispatch.
_beadid_has_open_gate_marker() {
  local _bid="${1:-}"
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_GATE_OPEN_BEADS+x}" ]; then
    case " $PILOT_TEST_GATE_OPEN_BEADS " in *" $_bid "*) return 0 ;; *) return 1 ;; esac
  fi
  command -v bd >/dev/null 2>&1 || return 1
  local _arts _hit
  _arts=$(bd -C "$GC_CITY" list -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null || echo "")
  [ -n "$_arts" ] || return 1
  # Count OPEN quality-gate-markers for this source-bead, ANY gate-status. A closed
  # or non-marker artifact contributes 0.
  _hit=$(printf '%s' "$_arts" | jq -r '
      [ .[]
        | select(.status == "open")
        | (.labels // []) as $l
        | select( $l | index("type:quality-gate-marker") )
      ] | length' 2>/dev/null || echo "0")
  case "$_hit" in ''|0) return 1 ;; *) return 0 ;; esac
}

# ── Attached-session live-mention (ga-48vb) ───────────────────────────────────
# Pilot's approved-story auto-dispatch and a live ATTACHED framework session
# (Mayor, or any other human-interactive session — NOT a pool worker/dog, which
# is never attached) deciding in-conversation to hand-implement the SAME story
# have no cross-visibility: the attached session's manual pickup never touches
# the bd bead's assignee/status at all. Concrete instance (2026-07-16, ga-n9bw):
# Mayor's attached session (gastown.mayor) delegated implementation to a
# background subagent while Pilot independently dispatched a builder for the
# same story — zero bd footprint on Mayor's side, so signals (a)-(d) (all keyed
# off branch/assignee/status/gate-marker) were structurally blind to it. This is
# a heuristic text match on recent transcript output, NOT an authoritative claim
# signal like (a)-(d) — a session merely discussing a bead without building it
# is a possible false-positive, but that only costs one deferred sweep, versus
# the alternative of a silent double-write into a shared, non-worktree-isolated
# source tree.
#
# ga-lluq1 (2026-07-21): the Mayor session itself is EXEMPT from this scan. By
# doctrine the Mayor never hand-builds — it only triages/holds/comments/
# escalates ('Mayor delega toda impl') — so a mention in the Mayor's own
# transcript is coordination chatter, never "an attached session is actively
# building this", and must not be read as an owner to leave the bead for.
# Without the exemption, every approved bead the Mayor merely discusses gets
# refused on every sweep for as long as the mention stays in its recent
# transcript window (observed: ga-t1ub9 starved ~30h). A live CREW/builder
# attached session mentioning the bead is unaffected — that is a real
# candidate owner and must still refuse. The exemption is applied once, at
# the shared cache in _attached_session_peek_cache below, so it covers every
# caller of this heuristic without needing to be repeated per call site.
#
# _gc_session_peek_output <session_id> — thin wrapper around the bounded, real
# `gc session peek` call so tests can stub this ONE function directly (a
# `timeout <bin>` pipeline can't be intercepted by shadowing a shell function
# named after the binary — `timeout` execs its argument directly, bypassing the
# calling shell's function table). Echoes the peek's `.output` field, or "" on
# any failure/timeout.
_gc_session_peek_output() {
  local _sess="${1:-}"
  [ -n "$_sess" ] || return 1
  timeout 8 gc --city "$GC_CITY" session peek "$_sess" --lines 80 --json 2>/dev/null \
    | jq -r '.output // empty' 2>/dev/null || echo ""
}

# _attached_session_peek_cache — lazy, ONCE-per-sweep cache: recent output from
# every currently ATTACHED, non-closed session (reusing the already-loaded
# _SESSIONS_JSON roster — no extra `gc session list` call), EXCLUDING the
# Mayor session (ga-lluq1 — the Mayor only coordinates, never builds, so its
# own mentions must never be read as "an attached session owns this"; see the
# doc comment above). Both known resolved-identity forms are excluded:
# "gastown.mayor" (alias/name/agent_name — what the id-resolution below
# actually yields today) and "gastown__mayor" (the double-underscore
# session_name form used elsewhere in this codebase, e.g. quality-gate-guard.sh's
# session_matches_author) — belt-and-suspenders against the exact
# alias-vs-session_name mismatch class already fixed there (ga-ipf6). Reused by
# every _ownership_guard_should_refuse call this sweep so N candidates never
# multiply into N × attached-count peek calls. Mirrors the _ownership_guard_repos
# lazy-cache idiom above. FAIL-OPEN: no `gc`, zero attached sessions, or any
# read error → empty cache (the caller's grep then naturally finds nothing).
_attached_session_peek_cache() {
  if [ -z "${_ATTACHED_PEEK_DONE:-}" ]; then
    _ATTACHED_PEEK_CACHE=""
    if command -v gc >/dev/null 2>&1; then
      local _sess _out _attached_ids
      _attached_ids=$(printf '%s' "$_SESSIONS_JSON" | jq -r '
          [.sessions[]? | select(.closed != true) | select(.attached == true)
           | (.alias // .name // .session_name // empty)]
          | map(select(. != null and . != "" and . != "gastown.mayor" and . != "gastown__mayor"))
          | unique | .[]' 2>/dev/null || echo "")
      while IFS= read -r _sess; do
        [ -n "$_sess" ] || continue
        _out=$(_gc_session_peek_output "$_sess")
        [ -n "$_out" ] && _ATTACHED_PEEK_CACHE="${_ATTACHED_PEEK_CACHE}
${_out}"
      done <<< "$_attached_ids"
    fi
    _ATTACHED_PEEK_DONE=1
  fi
  printf '%s' "$_ATTACHED_PEEK_CACHE"
}

# _beadid_mentioned_in_attached_session <bead_id> — exit 0 iff a live ATTACHED
# session's recent output mentions <bead_id> as a whole token (boundary-safe:
# a longer id sharing the same prefix/suffix never false-matches). The Mayor's
# own session is excluded from the scan (ga-lluq1 — see
# _attached_session_peek_cache above): a mention that appears ONLY in the
# Mayor's transcript never fires this signal, while a mention in any other
# live attached (crew/builder) session still does.
# Test seam: PILOT_TEST_ATTACHED_MENTION_BEADS (space-list), consulted when
# DEFINED, keeps the selftest hermetic (no live gc / sessions). FAIL-OPEN: no
# gc, no attached sessions, any read error, or no match → return 1 (allow) —
# this signal must never wedge a genuinely-free dispatch.
_beadid_mentioned_in_attached_session() {
  local _bid="${1:-}"
  [ -n "$_bid" ] || return 1
  if [ -n "${PILOT_TEST_ATTACHED_MENTION_BEADS+x}" ]; then
    case " $PILOT_TEST_ATTACHED_MENTION_BEADS " in *" $_bid "*) return 0 ;; *) return 1 ;; esac
  fi
  local _cache
  _cache=$(_attached_session_peek_cache)
  [ -n "$_cache" ] || return 1
  printf '%s' "$_cache" | grep -qE "(^|[^A-Za-z0-9_-])${_bid}([^A-Za-z0-9_-]|\$)"
}

# _ownership_guard_should_refuse <bead_id> <bead_json> <bead_city> — emit a short
# REASON to stdout and return 0 (REFUSE this dispatch) iff signal (a), (b), (c),
# (d), or (e) holds; return 1 (allow) otherwise. Pure read; the caller logs +
# releases the claim.
#   (a) crew branch exists for <bead_id> (strongest)            → "branch:<...>"
#   (d) a live gate marker/run is ACTIVELY gating its branch    → "gating:active"
#   (c) fresh rig-DB re-read shows an EXTERNAL active claim      → "external-claim:<...>"
#   (b) live assignee: a non-empty, NON-pilot crew assignee whose session is live
#       in the once-per-sweep roster                            → "owner:<crew>"
#   (e) a live ATTACHED session's recent output mentions <bead_id> (ga-48vb;
#       heuristic, not authoritative — same needs-fix carve-out as (a); the
#       Mayor's own session is exempt from this scan per ga-lluq1)
#                                                                 → "attached-session:mention"
# Re-reads the bead's CURRENT assignee (race-safe: the candidate query required an
# EMPTY assignee, but a competing claim could have set one between snapshot and
# now — exactly the ga-htjni double-dispatch window). FAIL-OPEN: an unresolvable
# assignee, an untrustworthy roster (_DEADWORKER_OK!=1, gated like ga-e5yw2), or
# any jq error → no (b) block. (a) is independent and self-fail-open.
_ownership_guard_should_refuse() {
  local _bid="${1:-}" _json="${2:-}" _city="${3:-$GC_CITY}"
  local _bs _bs_class _bs_detail
  [ -n "$_bid" ] || return 1

  # gate:needs-fix exemption (ga-htjni × autonomous gate-fix loop). A bead the gate
  # FAILed carries gate:needs-fix and OWNS the branch crew/*/<bead> from its prior
  # attempt — that branch is EXPECTED to exist, and the re-dispatch IS the loop
  # re-fixing it, not a competing owner. The gate also cleared the assignee + story:
  # in-flight on FAIL, so there is NO live owner to "leave it for". Without this,
  # signal (a) refuses EVERY fix attempt forever (observed: ps-2w5d attempt 3 refused
  # every sweep for 40+min). Skip the standalone branch refusal for gate:needs-fix;
  # signal (b) below still blocks a genuinely LIVE crew owner (an in-flight fixer).
  #
  # ga-d3eg2: ALSO exempt on gate:fix-attempt:<N> alone (needs-fix may be absent).
  # Measured live (ga-xv78c, dolt_diff_labels forensics): a single commit stripped
  # gate:failed + gate:needs-fix together (root mechanism not attributable to any
  # daemon script found — see bead comment) while gate:fix-attempt:1 and
  # gate-sha-failed:<sha> survived untouched. The label-only carve-out above then
  # silently deactivated: signal (a) fell through to _beadid_branch_signal, which
  # blocks any unmerged branch not yet past PILOT_ORPHAN_BRANCH_STALE_HOURS (48h
  # default) — refusing EVERY sweep for the bead's remaining lifetime short of that
  # window (observed: ~20h, until a human hand-fixed the label). gate:fix-attempt:N
  # is exactly as durable a "this bead is in the gate-fix loop" fingerprint as
  # gate:needs-fix — _ns_label_blocks_release below documents both as persisting
  # "across a bead's ENTIRE redispatch cycle by design" — so trusting it here is
  # consistent with existing doctrine, not a new risk class. Deliberately does NOT
  # widen to "branch exists + no assignee" alone: that would refuse nothing
  # differently for a bead with NO gate history (ga-8jxe1(a3)'s gj8-recent fixture:
  # a branch pushed moments ago, assignee not yet set) — the exact ga-6jqr/ga-htjni
  # push-then-metadata-lag double-dispatch race this file already protects against.
  # Requiring proof of a PRIOR gate FAIL (the attempt counter) is what distinguishes
  # "abandoned mid-fix-cycle" from "just claimed, metadata still catching up".
  local _og_labels
  _og_labels=$(printf '%s' "$_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
  case ",$_og_labels," in
    *,gate:needs-fix,*|*,gate:fix-attempt:*,*)
      : ;;   # in the gate-fix loop → its own branch is not a competing owner
    *)
      # (a) crew branch — strongest, evaluated first and standalone. ga-8jxe1:
      # "branch exists" alone is no longer treated as an unconditional
      # in-flight signal — classify it first (see _beadid_branch_signal doc).
      _bs="$(_beadid_branch_signal "$_bid" "$_json")"
      if [ -n "$_bs" ]; then
        _bs_class="${_bs%%$'\t'*}"
        _bs_detail="${_bs#*$'\t'}"
        case "$_bs_class" in
          block)
            printf 'branch:%s' "$_bs_detail"
            return 0
            ;;
          merged)
            : # AC1a — build already shipped, not an in-flight signal; keep checking.
            ;;
          orphan)
            # AC1b/AC3 — unmerged but abandoned (stale + unassigned): surface
            # for triage instead of vetoing forever; never touches the branch.
            _ownership_guard_flag_orphan_branch "$_bid" "$_city" "$_bs_detail"
            ;;
        esac
      fi
      # (e) attached-session live mention (ga-48vb) — see function doc above.
      # Same needs-fix carve-out as (a): a soft heuristic signal must not
      # reintroduce the ps-2w5d 40-minute re-fix stall (Scenario 22h).
      if _beadid_mentioned_in_attached_session "$_bid"; then
        printf 'attached-session:mention'
        return 0
      fi
      ;;
  esac

  # ── (d) LIVE GATE HAND-OFF (wa-0hnsi / wa-62qbd / wa-xnuxd / wa-1tb9b) ────────
  # The recurring "open-during-gate-handoff" race: when a fix-worker RELEASES its bead
  # (status=open, assignee="") and the gate-submit is in flight, there is a window
  # where the bead reads open + unassigned + buildable — signals (a)/(b)/(c) are all
  # structurally blind to it (no live assignee, non-terminal status, and the git-branch
  # probe (a) FAILS-OPEN under a slow/offline rig remote). A pool-worker probe samples
  # it and slings a PARALLEL worker that then discovers the in-flight gate-run and
  # stands down — low harm, but it recurs and burns spin-up cycles. (d) closes it with
  # a RELIABLE Dolt read (not a network git probe): if a live quality-gate marker OR run
  # is ACTIVELY processing this bead's branch RIGHT NOW, the work is already in the gate
  # → refuse the duplicate. ACTIVELY-PROCESSING ONLY (ready/claimed/queued/dispatching/
  # reviewing marker, running run); a parked/terminal artifact (error/needs-rebase/
  # passed/failed/superseded/done/…) is NOT gating and the bead may legitimately need
  # re-dispatch — in particular the gate:needs-fix re-fix loop, whose ONLY marker is
  # failed/error, MUST still dispatch, so (d) never regresses the rig-scan/held-until
  # re-fix fixes. Independent of the pilot fingerprint on purpose: an ACTIVE artifact is
  # a definitive "being-gated-now" discriminator regardless of pilot:dispatched (the bug
  # bead is itself pilot-dispatched, so gating (d) behind the fingerprint would skip the
  # very race we close). It composes with — never conflicts with — signal (c)'s
  # fingerprint/needs-fix carve-out below: that carve-out only gates (c)'s status/
  # assignee refusal, whereas (d) refuses on a DISJOINT artifact signal. FAIL-OPEN by
  # construction (an unreadable gate-artifact query never blocks dispatch).
  if _beadid_has_active_gate_artifact "$_bid"; then
    printf 'gating:active'
    return 0
  fi

  # ── Fresh, rig-DB-aware re-read (race-safe) — serves (c) AND (b) ──────────────
  # ONE authoritative read of the bead from its OWNING store ($_city == the rig DB
  # for wa-*/ps-* beads, HQ for ga-*). The candidate snapshot required an EMPTY
  # assignee + non-terminal status, but a competing claim can land BETWEEN snapshot
  # and now (the ga-htjni double-dispatch window). Both (c) and (b) judge on THIS
  # read, not the stale snapshot. FAIL-OPEN: an unreadable field falls back to the
  # snapshot / allows.
  local _fresh _asg _cur_status _has_pilot_fp
  _fresh=$(bd -C "$_city" show "$_bid" --json 2>/dev/null \
    | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
  _asg=$(printf '%s' "$_fresh" | jq -r '(.assignee // "")' 2>/dev/null || echo "")
  if [ -z "$_asg" ] || [ "$_asg" = "null" ]; then
    _asg=$(printf '%s' "$_json" | jq -r '(.assignee // "")' 2>/dev/null || echo "")
  fi
  _cur_status=$(printf '%s' "$_fresh" | jq -r '(.status // "")' 2>/dev/null || echo "")
  [ -z "$_cur_status" ] && _cur_status=$(printf '%s' "$_json" | jq -r '(.status // "")' 2>/dev/null || echo "")
  # Pilot's OWN dispatch fingerprint — a bead the Pilot itself slung/dispatched (or a
  # dead-worker orphan of one) carries pilot:dispatched / pilot.dispatched_at /
  # pilot.sling_bead. That is NOT a fresh EXTERNAL claim; the reclaim paths
  # (NEVERSTARTED / ga-e5yw2 / ga-v3z4z) own it, so (c) must NOT block it (else
  # re-dispatch of a legitimately-released bead would deadlock). gate:needs-fix is
  # likewise the Pilot's own gate-fix loop (assignee already cleared by the gate);
  # ga-d3eg2: same for gate:fix-attempt:N alone — see the signal-(a) carve-out
  # above for why this is a durable-enough fingerprint on its own.
  _has_pilot_fp=$(printf '%s' "$_fresh" | jq -r '
      (((.labels // []) | index("pilot:dispatched")) != null)
      or (((.metadata["pilot.dispatched_at"]) // "") != "")
      or (((.metadata["pilot.sling_bead"]) // "") != "")
      | if . then "1" else "0" end' 2>/dev/null || echo "0")
  case ",$_og_labels," in *,gate:needs-fix,*|*,gate:fix-attempt:*,*) _has_pilot_fp="1" ;; esac

  # ── (c) EXTERNAL ACTIVE CLAIM (ga-htjni ext; wa-5wv49 / wa-xnuxd) ─────────────
  # The reported systemic double-dispatch: a crew/human creates a bead intending to
  # build it THEMSELVES and claims it (status=in_progress + assignee=<self>) — yet
  # the Pilot still slung a PARALLEL wa-worker on the same bead. Signal (b) below
  # MISSES this: it blocks ONLY an assignee that resolves to a LIVE gc SESSION via a
  # grep -Fxq EXACT match, but a self-claiming crew's assignee is session-suffixed
  # (observed: created_by=thies-wa-awispr9ofspp on both repro beads) so it never
  # matches — and (b) also needs a trustworthy roster (_DEADWORKER_OK=1). STATUS —
  # the decisive "someone is actively building this" signal — was never consulted at
  # dispatch time. (c) closes the gap: judge on the FRESH rig-DB status+assignee and
  # skip the roster entirely. Runs BEFORE the HQ/rig path split, so it covers BOTH
  # ga-* (HQ) and wa-*/ps-* (rig-native) dispatch. Distinguished from the states that
  # MUST still dispatch:
  #   • Mayor explicit-assignee routing (imp20): assignee set but status=OPEN → allow.
  #   • Pilot's own dispatch / dead-worker orphan: has fingerprint → allow (reclaim owns it).
  #   • NEVERSTARTED-released residue: assignee cleared to "" → allow (re-dispatchable).
  # FAIL-OPEN: an unreadable status → no (c) block.
  if [ "$_has_pilot_fp" != "1" ]; then
    # A status that raced into terminal/blocked past the _filter_dispatch_gates snapshot.
    case "$_cur_status" in
      blocked|closed|deferred) printf 'status:%s' "$_cur_status"; return 0 ;;
    esac
    # Actively being built by a REAL external crew (not a pool worker / dog / self).
    if [ "$_cur_status" = "in_progress" ] && [ -n "$_asg" ] && [ "$_asg" != "null" ]; then
      case "$_asg" in
        gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) : ;;
        "$SELF_BEAD_ID") : ;;
        *) printf 'external-claim:%s@in_progress' "$_asg"; return 0 ;;
      esac
    fi
  fi

  # (b) live named-crew owner. Judge on the fresh $_asg captured above (race-safe).
  [ -z "$_asg" ] || [ "$_asg" = "null" ] && return 1   # unowned → allow.
  # An assignee equal to the dispatcher self-bead / a dog pool is not a "named
  # crew owner" in the ga-htjni sense; only block on a real crew identity.
  case "$_asg" in gastown.dog|gastown.dog-*) return 1 ;; esac
  # Roster must be trustworthy to judge liveness; otherwise fail-open (allow), so
  # a racy `session list` read can never deadlock a legitimately-orphaned bead.
  [ "${_DEADWORKER_OK:-0}" = "1" ] || return 1
  # ga-46wq5: was bare _session_is_live (not-closed only) — a crew that went
  # asleep or has sat idle for hours still read as "live", so a bead a human
  # hand-assigned to a quiet crew could never be reclaimed by THIS guard either
  # (moot pre-fix, since _filter_candidates never let it reach here at all —
  # see that function's comment for the incident). _session_is_active_owner
  # adds the same not-asleep / not-idle-beyond-PILOT_ASSIGNEE_IDLE_MINUTES
  # check _filter_candidates now applies upstream — the two chokepoints must
  # agree, or a bead _filter_candidates re-admits just gets refused again
  # here, a silent no-op that looks fixed but isn't.
  if _session_is_active_owner "$_asg"; then
    printf 'owner:%s' "$_asg"
    return 0
  fi
  # Owner set but session DEAD/asleep/idle-past-threshold and (a) already proved no branch → genuine orphan:
  # do NOT block — let the upstream reclaim paths (ga-e5yw2 / ga-v3z4z) recover it.
  return 1
}

# _ns_label_blocks_release <labels_csv> — exit 0 (BLOCK release / KEEP) iff any
# gate:* label OTHER than the story-level history markers gate:needs-fix /
# gate:fix-attempt:N is present in the comma-joined label list. gate:needs-fix
# and gate:fix-attempt:N persist across a bead's ENTIRE redispatch cycle by
# design (Pilot deliberately redispatches any gate:needs-fix bead — see the
# PILOT_MAYOR_HOLD_GRACE_SECS doc above — and does not clear them until the fix
# PASSES or the next FAIL bumps the attempt count), so their mere presence proves
# only that SOME prior attempt once reached the gate — not that THIS dispatch
# attempt did. Treating them as an unconditional "reached the gate, KEEP" signal
# made a bead invisible to recovery FOREVER after its first gate FAIL: a
# brand-new dispatch attempt whose builder died before reaching the gate again
# read identically to "still building," and no other path caught it either
# (ga-e5yw2's dead-worker correction deliberately never mutates labels — see its
# doc above). Real incident: ga-tje7u sat stuck 2h+, invisible to the Pilot,
# until a human noticed and manually re-slung it (ga-pb8z5). Every OTHER gate:*
# label (queued, reviewing, passed, failed, needs-human) still means "definitely
# active or needs a human" and keeps blocking — matching this function's
# fail-safe-to-KEEP default. Split out of _neverstarted_recover_db so this
# predicate is independently testable (see pilot-dispatcher.selftest.sh
# Scenario 16d/16d2-16d7).
#
# Checks each label as its own token (one per line via `tr ','  '\n'`), not via
# comma-paired sed substitution — a prior version stripped history labels with
# `sed 's/,gate:needs-fix,/,/g; s/,gate:fix-attempt:[0-9]\{1,\},/,/g'`, which
# breaks when TWO gate:fix-attempt:N labels coexist (a documented, routine
# residue — see quality-gate-dispatcher.sh's own MAX-over-surviving-values
# handling of the same `{1,2}` race, ga-wisp-198xqe): the first match's
# trailing comma is the second match's leading delimiter, so non-overlapping
# `/g` semantics consume it once and leave one counter unstripped, which then
# falsely matches the `*,gate:*)` KEEP case — silently reproducing the exact
# stuck-forever bug this function exists to fix. Per-token matching has no
# shared delimiters to consume, so it is immune regardless of how many
# gate:fix-attempt:N labels are present at once.
_ns_label_blocks_release() {
  local _label
  while IFS= read -r _label; do
    case "$_label" in
      ""|gate:needs-fix) continue ;;
    esac
    printf '%s\n' "$_label" | grep -q '^gate:fix-attempt:[0-9]\{1,\}$' && continue
    case "$_label" in
      gate:*) return 0 ;;
    esac
  done <<EOF
$(printf '%s' "$1" | tr ',' '\n')
EOF
  return 1
}

# _neverstarted_recover_db <db_path> <now_epoch> — scan one DB for never-started
# in-flight beads and release them. Decision rules (ALL must hold to release):
#   - has story:in-flight AND pilot:dispatched (query selects both)
#   - NO active gate:* marker on this bead OR its recorded pilot.sling_bead (a
#       marker such as gate:reviewing/queued/passed/failed/needs-human = an
#       attempt actually reached the gate or needs a human = KEEP; ga-d2jil:
#       Pilot's "fix bug"/"build story" sling-task dispatch writes gate:* onto
#       the SLING bead, never mirrored back onto this one, so both must be
#       checked). gate:needs-fix / gate:fix-attempt:N ALONE do NOT block — see
#       _ns_label_blocks_release above (ga-pb8z5).
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
  _json=$(bd -C "$_db" list --json \
    -l "story:in-flight" \
    -l "pilot:dispatched" \
    2>/dev/null || echo "[]")
  _count=$(echo "$_json" | jq 'length' 2>/dev/null || echo "0")
  [ "${_count:-0}" -le "0" ] 2>/dev/null && return 0

  echo "$_json" | jq -c '.[]' | while IFS= read -r _bead; do
    local _bid _labels _stamp _age _sling _sling_json _sling_labels _asg _crew_owner
    _bid=$(echo "$_bead" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$_bid" ] && continue
    _labels=$(echo "$_bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")

    # gate-marker guard — any ACTIVE gate:* label means an attempt reached the
    # gate or needs a human. KEEP. gate:needs-fix/gate:fix-attempt:N are STORY-
    # LEVEL HISTORY, not proof THIS attempt got there — see _ns_label_blocks_release
    # above (ga-pb8z5). (The sling/task bead's OWN labels are checked separately
    # below — ga-d2jil.)
    _ns_label_blocks_release "$_labels" && continue

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
    # ga-d2jil: ALSO check the sling/task bead's OWN labels for gate:* here. Pilot's
    # "fix bug"/"build story" sling-task dispatch shape writes the gate:* progress
    # label onto the SLING bead (e.g. ga-vi7z2), never mirrored back onto this
    # story/bug bead — so the gate-marker guard above is structurally blind to it.
    # Label reads are always trustworthy (unlike the session-roster liveness check
    # below), so this fires regardless of _DEADWORKER_OK: an adhoc dog builder that
    # FINISHED and drain-acked is CORRECTLY reported not-live by
    # _session_is_live_builder (an adhoc worker never resumes), which would
    # otherwise let a bead that already reached the gate fall through to release
    # (root cause of the ga-tgo7q double-dispatch incident).
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    if [ -n "$_sling" ]; then
      # ga-mfeip cross-DB fix: a self-referential sling (pilot.sling_bead == bead id) is the
      # routed-pool pattern — the "sling" IS the rig-native bead, living in $_db (the rig DB),
      # NOT in HQ ($GC_CITY). Reading it from $GC_CITY returns a null assignee → false
      # NEVERSTARTED release of a LIVE ps-worker/wa-worker build that just hasn't pushed a
      # branch yet (>thresh, no gate label). Read the sling from the bead's own DB.
      local _sling_db="$GC_CITY"
      [ "$_sling" = "$_bid" ] && _sling_db="$_db"
      _sling_json=$(bd -C "$_sling_db" show "$_sling" --json 2>/dev/null \
        | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null || echo "null")

      _sling_labels=$(echo "$_sling_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
      # ga-pb8z5 attempt 2: the self-referential routed-pool pattern above (_sling ==
      # $_bid) re-reads THIS SAME bead's labels here, so an unconditional "any gate:*
      # blocks" re-KEEPs on the exact gate:needs-fix/gate:fix-attempt:N history Guard 1
      # (L3520) just released — net effect zero. Same predicate, same fail-safe default.
      _ns_label_blocks_release "$_sling_labels" && continue

      _asg=$(echo "$_sling_json" | jq -r '(.assignee // "")' 2>/dev/null || echo "")
      if [ -z "$_asg" ]; then
        # ga-l7pp: an UNCLAIMED sling (no assignee yet) means the dispatch already
        # materialized a task bead — it is QUEUED in its target pool, not "never
        # started". The pool may simply be backlogged. Judge it the SAME way the
        # dispatch-time dedup guard does (ga-cnvy1): still open/in_progress and not
        # yet stale (_sling_is_live, same STALE_SLING_SECONDS window) → KEEP, the
        # pool just hasn't served it. Only a PROVEN-stale unclaimed sling is a
        # genuine orphan. Releasing here without this check unsets pilot.sling_bead
        # (below) and leaves the queued sling bead ORPHANED — the very next sweep
        # then mints a SIBLING sling for the same story, and both can be claimed
        # independently (the ga-kuuk double-dispatch: ga-k4uh got 5 sling beads in
        # ~3h, two of which were claimed by two different dogs within 46s).
        local _sling_status
        _sling_status=$(echo "$_sling_json" | jq -r '(.status // "")' 2>/dev/null || echo "")
        case "$_sling_status" in
          open|in_progress)
            if _sling_is_live "$_sling" "$_sling_db" "$_bid"; then
              continue   # still queued and not stale — pool hasn't served it yet.
            fi
            warn "NEVERSTARTED: $_bid's sling $_sling is unclaimed AND stale (idle >${STALE_SLING_SECONDS}s, no branch) — closing orphaned sling before release (ga-l7pp)."
            bd -C "$_sling_db" close "$_sling" --reason "Stale unclaimed sling auto-closed by Pilot NEVERSTARTED release: story never started and sling sat open >${STALE_SLING_SECONDS}s with no crew branch — avoids orphaning it while the story re-dispatches (ga-l7pp)." -q 2>/dev/null || true
            ;;
        esac
      elif [ "${_DEADWORKER_OK:-0}" != "1" ]; then
        continue   # roster untrustworthy → cannot prove worker dead → KEEP.
      elif _session_is_live_builder "$_asg"; then
        continue   # worker actively building → not never-started (asleep adhoc = drained/dead).
      fi
    fi

    # live-crew-owner guard (ga-9yb5s) — a crew claims the STORY bead directly, so
    # it is invisible to the sling-assignee guard above. If the bead's own current
    # assignee is a live named crew, an active crew builder owns it → KEEP (parity
    # with the ga-htjni dispatch guard). FAIL-OPEN: untrustworthy roster / no owner
    # / dead session → no keep, so genuine orphans still recover.
    _crew_owner=$(_beadid_live_crew_owner "$_bid" "$_db") && {
      # ga-mfeip owner-grace: a live crew may OWN a bead it never started (assigned via
      # the rig ctx:ready dispatch but the busy crew never picked it up). Release ONLY
      # when ALL hold: aged past the owner-grace window AND no branch for this bead AND
      # the owner pushed branches for OTHER beads since this dispatch (working but skipped
      # it). Otherwise KEEP (the conservative ga-9yb5s default — a slow build is safe).
      _owner_grace=$(( ${PILOT_NEVERSTARTED_OWNER_GRACE_HOURS:-24} * 3600 ))
      if [ "$_age" -gt "$_owner_grace" ] 2>/dev/null \
         && ! _beadid_has_branch "$_bid" \
         && _crew_progressed_since "$_crew_owner" "$_stamp"; then
        warn "NEVERSTARTED: $_bid owned by live crew '$_crew_owner' but NEVER started (no branch, age=${_age}s > owner-grace ${_owner_grace}s, owner pushed other branches since dispatch) — releasing as declined/skipped (ga-mfeip owner-grace)."
      else
        warn "NEVERSTARTED: $_bid is owned by live crew '$_crew_owner' (story.assignee) — active crew builder, refusing to release (ga-9yb5s parity with ga-htjni)."
        continue
      fi
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
    # ga-mrfb: CLEAR the dead worker's assignee. _filter_candidates requires an empty
    # assignee (it never re-dispatches a bead someone "owns"); a never-started bead still
    # carries its dead builder's assignee, so without this it is released back to
    # story:approved yet stays INVISIBLE to every candidate query forever (ps-mrfb/ps-joc0
    # sat assigned to drained ps-worker-adhoc sessions). The gate-FAIL path already does
    # this unassign; NEVERSTARTED must too (beads that drained BEFORE reaching the gate).
    bd -C "$_db" assign "$_bid" "" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatched_at"  -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.sling_bead"     -q 2>/dev/null || true
  done
}

# _mayor_deferred_hold_db <db_path> <now_epoch> — scan one DB for stories whose
# sling task was refused specifically because a coordinator (Mayor) explicitly
# deferred the work in a comment, and stamp a timed pilot:held so
# _filter_candidates (which already respects pilot:held/pilot:held-until — see
# the ga-lfvs6/imp20 block below) stops re-dispatching it.
#
# ga-4zqwm: a coordinator's deferral is expressed only as prose in a bd
# comment — no queryable label lands on the STORY itself. When Pilot
# re-dispatches anyway, the refusing worker's pool:refused:mayor-deferred
# label lands on the throwaway SLING bead (gc sling's wrapper: "fix bug
# $STORY_ID: ..." / "build story $STORY_ID: ..."), never on the story —
# so _filter_candidates's own pool:refused check (which reads only the
# CANDIDATE's own labels, line ~1326) never sees it, and the story is
# re-dispatched again on the very next sweep. Concretely: ga-dp15j (Mayor
# deferred it 15:23) got dispatched at 23:32 anyway, sling ga-u5y7y was
# refused with pool:refused:mayor-deferred, and ga-dp15j itself remained
# completely unlabeled/re-dispatchable. Mirrors the sling→story label
# resolution _neverstarted_recover_db already does for gate:* (ga-d2jil) —
# same shape, different label, same reason (a signal that lives on the
# sling wrapper is invisible to any check that only reads the story).
#
# Hold duration is deliberately long (24h default, vs. the 1h capacity-defer
# default at ga-lfvs6 below) because this is an open-ended "not now" from the
# story's own decision-maker ("Pego quando a poeira assentar" — no fixed
# timeframe was given), not a transient capacity gap expected to clear
# within the hour. 24h stops the re-dispatch thrash (which had been
# recurring roughly every 8h) without holding silently for so long that a
# genuinely-forgotten deferral never resurfaces.
MAYOR_DEFERRED_HOLD_SECS="${MAYOR_DEFERRED_HOLD_SECS:-86400}"

_mayor_deferred_hold_db() {
  local _db="$1" _now="$2"
  local _json _count
  _json=$(bd -C "$_db" list --json \
    -l "story:in-flight" \
    -l "pilot:dispatched" \
    2>/dev/null || echo "[]")
  _count=$(echo "$_json" | jq 'length' 2>/dev/null || echo "0")
  [ "${_count:-0}" -le "0" ] 2>/dev/null && return 0

  echo "$_json" | jq -c '.[]' | while IFS= read -r _bead; do
    local _bid _labels _sling _sling_json _sling_labels
    _bid=$(echo "$_bead" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$_bid" ] && continue

    # Already held (by this check or any other) — nothing to do.
    _labels=$(echo "$_bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
    case ",$_labels," in *,pilot:held,*) continue ;; esac

    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    if [ -z "$_sling" ]; then
      continue
    fi
    if [ "$_sling" = "$_bid" ]; then
      continue   # self-referential sling = routed-pool pattern (rig-native bead), not a
                 # "fix bug $STORY_ID" sling wrapper — nothing to cross-reference.
    fi

    # Slings are always HQ-native for this dispatch shape (gc sling creates the
    # wrapper in $GC_CITY regardless of which DB the story itself lives in).
    _sling_json=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
      | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null || echo "null")
    _sling_labels=$(echo "$_sling_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
    case ",$_sling_labels," in
      *,pool:refused:mayor-deferred,*) : ;;
      *) continue ;;
    esac

    local _hold_until; _hold_until=$(( _now + MAYOR_DEFERRED_HOLD_SECS ))
    # imp19 atomicity convention (same as ga-lfvs6/imp20 below): held-until FIRST
    # so a mid-crash never leaves the bead as pilot:held-without-until (which
    # _filter_candidates treats as skip-forever).
    bd -C "$_db" label add "$_bid" "pilot:held-until:${_hold_until}" -q 2>/dev/null || true
    bd -C "$_db" label add "$_bid" "pilot:held" -q 2>/dev/null || true
    for _stale in $(bd -C "$_db" show "$_bid" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[] | select(startswith("pilot:held-until:"))' 2>/dev/null); do
      [ "$_stale" = "pilot:held-until:${_hold_until}" ] || bd -C "$_db" label remove "$_bid" "$_stale" -q 2>/dev/null || true
    done
    log "ga-4zqwm: $_bid stamped pilot:held-until:${_hold_until} then pilot:held (${MAYOR_DEFERRED_HOLD_SECS}s — sling $_sling carries pool:refused:mayor-deferred) — Pilot stops re-dispatching until the hold expires or a human clears it"
    # ga-2n7xw AC4: this hold's OWN log line says "until the hold expires OR A
    # HUMAN CLEARS IT" — but nothing ever told the human. cap=1 so it escalates
    # on the FIRST hold, not the 3rd: passive 24h waiting is not escalation.
    _pilot_hold_or_escalate "$_db" "$_bid" "ga-4zqwm" \
      "Mayor-deferred hold (sling $_sling carries pool:refused:mayor-deferred) — this hold is designed to require a human to clear it" \
      "have the Mayor/a human review $_bid and either clear the hold, route it, or close it" \
      "$(echo "$_bead" | jq -c '.labels // []' 2>/dev/null || echo '[]')" \
      1
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

if [ "${PILOT_MAYOR_DEFERRED_HOLD:-1}" != "0" ]; then
  _MDH_NOW_EPOCH=$(date +%s)
  _mayor_deferred_hold_db "$GC_CITY" "$_MDH_NOW_EPOCH"
  _mdh_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
  while IFS= read -r _mdh_rig; do
    [ -z "$_mdh_rig" ] || [ ! -d "$_mdh_rig" ] && continue
    _mayor_deferred_hold_db "$_mdh_rig" "$_MDH_NOW_EPOCH"
  done <<< "$_mdh_rig_paths"
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

# ga-4uhrp: a gate-resident in-flight bead (any gate:* lifecycle label OTHER
# than the needs-fix/needs-human/fix-attempt:N redispatch markers — same
# carve-out _filter_built applies at ~L2244-2250; duplicated here rather than
# shared as a jq function because the two run as separate jq invocations over
# differently-shaped inputs and _filter_built's own history — ga-d3eg2,
# ga-ltjdx, ga-ub8yq — shows this classification is worth keeping textually
# obvious at each call site, not one line of bash/jq-quoting indirection away)
# has ALREADY FINISHED BUILDING; no builder session is attached to it.
# Counting it against the lane cap starves builders exactly when the gate is
# slow — measured live 2026-08-05: 7 story:in-flight beads, only 3 actually
# building, small lane read 7/5, 3 consecutive sweeps logged dispatched=0
# with a P0 waiting behind it (the gate slowing down throttles builders,
# which slows the gate further — a deadlock attractor, not just a slowdown).
# This does NOT reopen the bead for redispatch — that's a SEPARATE filter
# (_filter_built independently vetoes any candidate carrying a gate:* label),
# so freeing its lane slot here can only let a DIFFERENT, fresh bead use it.
IN_FLIGHT_GATE_RESIDENT_JSON=$(echo "$IN_FLIGHT_JSON" | jq '
  [ .[] | select((.labels // []) | any(
      (. == "gate" or startswith("gate:"))
      and (. != "gate:needs-fix") and (startswith("gate:needs-fix:") | not)
      and (. != "gate:needs-human") and (startswith("gate:needs-human") | not)
      and (startswith("gate:fix-attempt:") | not)
    )) ]' 2>/dev/null || echo "[]")
[ -z "$IN_FLIGHT_GATE_RESIDENT_JSON" ] && IN_FLIGHT_GATE_RESIDENT_JSON="[]"
GATE_RESIDENT=$(echo "$IN_FLIGHT_GATE_RESIDENT_JSON" | jq 'length' 2>/dev/null || echo "0")
[ -z "$GATE_RESIDENT" ] 2>/dev/null && GATE_RESIDENT=0

if [ "$GATE_RESIDENT" -gt 0 ] 2>/dev/null; then
  warn "Gate-resident in-flight: ${GATE_RESIDENT} bead(s) already built, waiting in the quality gate — NOT counted against the lane cap, freeing their slot(s) for pending work (ga-4uhrp; still excluded from redispatch by _filter_built's own gate:* veto). Gate-resident ids: $(echo "$IN_FLIGHT_GATE_RESIDENT_JSON" | jq -r '[.[].id] | join(",")' 2>/dev/null || echo "?")"
fi

IN_FLIGHT_BIG=$(echo "$IN_FLIGHT_JSON" | jq --argjson gr "$IN_FLIGHT_GATE_RESIDENT_JSON" '
    ($gr | map(.id)) as $gate_ids
    | [ .[] | select((.labels // []) | contains(["lane:big"]))
             | select((.id as $i | $gate_ids | index($i)) | not) ]
    | length' 2>/dev/null || echo "0")
[ -z "$IN_FLIGHT_BIG" ] && IN_FLIGHT_BIG=0
IN_FLIGHT_SMALL=$((IN_FLIGHT_TOTAL - GATE_RESIDENT - IN_FLIGHT_BIG))
[ "$IN_FLIGHT_SMALL" -lt 0 ] 2>/dev/null && IN_FLIGHT_SMALL=0

# ga-wtqli: IN_FLIGHT_SMALL above is a RESIDUE (total minus every other named
# category), not a classification — a bead with NEITHER lane:big NOR lane:small
# (never classified, for any reason) lands here exactly like a deliberately-
# tagged lane:small bead, and nothing distinguished the two until now. Audited
# (ga-wtqli AC#1): not just stale data — dispatch_one()'s lane:${LANE} stamp is
# a best-effort `bd label add ... || true` with no retry or read-after-write
# check, unlike the story:in-flight write two lines later (retries 5x,
# durability-confirmed), so a Dolt blip in that narrow window is a LIVE path to
# this state (real fix filed separately per AC#5 — this block is observability
# only and does not touch IN_FLIGHT_SMALL or SMALL_SLOTS below).
IN_FLIGHT_UNCLASSIFIED_JSON=$(echo "$IN_FLIGHT_JSON" | jq --argjson gr "$IN_FLIGHT_GATE_RESIDENT_JSON" '
    ($gr | map(.id)) as $gate_ids
    | [ .[] | select((.id as $i | $gate_ids | index($i)) | not)
             | select((.labels // []) | (contains(["lane:big"]) or contains(["lane:small"])) | not) ]' 2>/dev/null || echo "[]")
[ -z "$IN_FLIGHT_UNCLASSIFIED_JSON" ] && IN_FLIGHT_UNCLASSIFIED_JSON="[]"
IN_FLIGHT_UNCLASSIFIED=$(echo "$IN_FLIGHT_UNCLASSIFIED_JSON" | jq 'length' 2>/dev/null || echo "0")
[ -z "$IN_FLIGHT_UNCLASSIFIED" ] 2>/dev/null && IN_FLIGHT_UNCLASSIFIED=0

if [ "$IN_FLIGHT_UNCLASSIFIED" -gt 0 ] 2>/dev/null; then
  warn "Unclassified-lane in-flight: ${IN_FLIGHT_UNCLASSIFIED} bead(s) with NEITHER lane:big NOR lane:small — still counted against the small lane cap by residue (SMALL_SLOTS unchanged, ga-wtqli AC#5), but NOT provably the same as a deliberately-classified lane:small bead. Unclassified ids: $(echo "$IN_FLIGHT_UNCLASSIFIED_JSON" | jq -r '[.[].id] | join(",")' 2>/dev/null || echo "?")"
fi

# Log-only breakdown of the residue: small=N still means "occupies a small
# cap slot" (SMALL_SLOTS below still subtracts the full IN_FLIGHT_SMALL
# residue, unchanged) — IN_FLIGHT_SMALL_CLASSIFIED further splits THAT same
# number into explicit-vs-unclassified so small=N stops silently absorbing
# unclassified_lane=N (ga-wtqli AC#2-4). Non-negative by construction: the
# unclassified set above is a subset of the same gate-resident-excluded,
# non-big beads IN_FLIGHT_SMALL sums — so small_classified + big +
# unclassified_lane always equals live - gate_resident exactly.
IN_FLIGHT_SMALL_CLASSIFIED=$((IN_FLIGHT_SMALL - IN_FLIGHT_UNCLASSIFIED))
[ "$IN_FLIGHT_SMALL_CLASSIFIED" -lt 0 ] 2>/dev/null && IN_FLIGHT_SMALL_CLASSIFIED=0

log "In-flight: live=$IN_FLIGHT_TOTAL (raw=$IN_FLIGHT_RAW_TOTAL stale=$STALE_INFLIGHT age=$STALE_AGE dead=$DEAD_WORKER)  gate_resident=$GATE_RESIDENT  small=$IN_FLIGHT_SMALL_CLASSIFIED/${MAX_SMALL}  unclassified_lane=$IN_FLIGHT_UNCLASSIFIED  big=$IN_FLIGHT_BIG/${MAX_BIG}"

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
  local _n _i _bead _sling _asg _forms _f _cbb_bid _cbb_bead_db _cbb_sling_db
  _n=$(echo "$IN_FLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")
  [ "${_n:-0}" -gt 0 ] 2>/dev/null || return 0
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _bead=$(echo "$IN_FLIGHT_JSON" | jq -c ".[$_i]" 2>/dev/null)
    _i=$((_i + 1))
    [ -n "$_bead" ] || continue
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    [ -n "$_sling" ] || continue
    # ga-mfeip cross-DB fix: self-referential sling means the bead IS the rig-native task;
    # look it up in its own store (_rig_db), not in $GC_CITY (where it doesn't exist).
    _cbb_sling_db="$GC_CITY"
    _cbb_bid=$(echo "$_bead" | jq -r '.id // ""' 2>/dev/null || echo "")
    _cbb_bead_db=$(echo "$_bead" | jq -r '._rig_db // ""' 2>/dev/null || echo "")
    [ -n "$_cbb_bead_db" ] && [ -n "$_cbb_bid" ] && [ "$_sling" = "$_cbb_bid" ] && _cbb_sling_db="$_cbb_bead_db"
    _asg=$(bd -C "$_cbb_sling_db" show "$_sling" --json 2>/dev/null \
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
  log "Both lanes full (small=${IN_FLIGHT_SMALL_CLASSIFIED}/${MAX_SMALL} unclassified_lane=${IN_FLIGHT_UNCLASSIFIED}, big=${IN_FLIGHT_BIG}/${MAX_BIG}). Pilot backing off."
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
TIER2_JSON=$(echo "$TIER2_JSON" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built)
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
    --exclude-label "gate:failed" \
    --exclude-label "gate:needs-fix" \
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
  CTXREADY_JSON=$(echo "$CTXREADY_JSON" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built)
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
    # Type restriction: chore/task/debt/bug (NOT features — features flow via refino-gate→approved).
    # Bugs are ctx-complete (ctx:ready) and skip the refinement funnel, so they dispatch here.
    # ga-4aree/wa-iy9s8: gate:failed/gate:needs-fix are deliberately NOT excluded above — a rig-store
    # bug that FAILED the gate needs a re-fix dispatch, exactly as the HQ bug query allows (which is
    # why HQ re-fixes worked but rig ones stranded forever). _filter_built exempts gate:needs-fix so
    # it re-dispatches; gate:reviewing/gate:passed beads stay held by _filter_built (built branch).
    _rig_ctx_typed=$(echo "$_rig_ctx_raw" | jq '
        [ .[] | select(
            ((.issue_type // .type // "") | ascii_downcase) as $t
            | ($t == "chore" or $t == "task" or $t == "debt" or $t == "tech-debt" or $t == "bug")
              or (((.labels // []) | index("tech-debt")) != null)
          ) ]' 2>/dev/null || echo "[]")
    # Same filter chain + exec:manual safety belt + ga-mfeip dispatch quality gates.
    _rig_ctx_typed=$(echo "$_rig_ctx_typed" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built)
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

# ── Step 2b-rig-tier2: WA rig story:approved features — UNCONDITIONAL (Bug A fix)
# WA-native story:approved FEATURES live in rig DBs (e.g. whatsapp_automation), NOT
# in HQ. Step 2b above queries HQ only — it never sees wa-zybp, wa-0gs8, wa-0z8e, etc.
# The old Step 2c fallback (below) only runs when HQ returns NOTHING, so these beads
# were invisible on every sweep where HQ had any candidates at all (which is almost
# always). Fix: scan the same rig DBs UNCONDITIONALLY here, in the primary merge path,
# exactly like CTXREADY_RIG_JSON does for ctx:ready tasks.
#
# Same PILOT_CTX_READY_RIGS scoping (default "whatsapp_automation") so the allowlist
# controls both the ctx:ready rig scan and the story:approved rig scan — one knob.
# Same filter chain (type/lifecycle/deps/unblocked) as the HQ TIER2_JSON query above.
# Gated by PILOT_WA_RIG_APPROVED_QUERIES (default 1). Set to 0 in the plist to
# disable independently (e.g. if the WA rig DB is unstable). Fail-open: any rig-DB
# error → skip that rig, never break the sweep.
# Test seam: PILOT_WA_RIG_TIER2_OVERRIDE — when set, bypass the gc/bd loop and use
# this JSON directly (hermetic selftest; no real gc/bd needed).
WA_RIG_TIER2_JSON="[]"
WA_RIG_TIER2_COUNT="0"
PILOT_WA_RIG_APPROVED_QUERIES="${PILOT_WA_RIG_APPROVED_QUERIES:-1}"
if [ "$PILOT_WA_RIG_APPROVED_QUERIES" = "1" ]; then
  if [ -n "${PILOT_WA_RIG_TIER2_OVERRIDE+x}" ]; then
    # Hermetic test seam: use the override JSON directly (skips gc/bd, no rig loop).
    # Apply the FULL filter chain — same as the real loop — so tests exercise the gates.
    WA_RIG_TIER2_JSON=$(echo "$PILOT_WA_RIG_TIER2_OVERRIDE" \
      | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built \
      | _filter_unblocked "${GC_CITY}" | _filter_explicit_deps "${GC_CITY}")
  else
    _wa_rig2_rows=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
      | jq -r '.rigs[] | select(.hq == false) | "\(.name)\t\(.path)"' 2>/dev/null || echo "")
    while IFS=$'\t' read -r _wa_rig2_name _wa_rig2_path; do
      [ -z "$_wa_rig2_path" ] || [ ! -d "$_wa_rig2_path" ] && continue
      # Same scope gate as ctx:ready rig scan: only rigs in PILOT_CTX_READY_RIGS.
      case " $PILOT_CTX_READY_RIGS " in
        *" all "*) : ;;
        *" $_wa_rig2_name "*) : ;;
        *) continue ;;
      esac
      _wa_rig2_raw=$(bd -C "$_wa_rig2_path" list --json \
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
      # Apply full filter chain: exec:manual + quality-gates + built-check + lifecycle.
      # Mirrors ctx:ready rig path (_filter_exec_manual | _filter_candidates |
      # _filter_dispatch_gates | _filter_built | _filter_unblocked | _filter_explicit_deps).
      # Without _filter_exec_manual + _filter_dispatch_gates, underspecified and
      # human-dependent approved features (e.g. wa-i02u Fala.BR CPF, wa-0z8e R&D device)
      # dispatch autonomously instead of deferring (gap reported mila mail ga-wisp-a1radr).
      _wa_rig2_filtered=$(echo "$_wa_rig2_raw" \
        | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built \
        | _filter_unblocked "$_wa_rig2_path" | _filter_explicit_deps "$_wa_rig2_path")
      _wa_rig2_n=$(echo "$_wa_rig2_filtered" | jq 'length' 2>/dev/null || echo "0")
      if [ "${_wa_rig2_n:-0}" -gt 0 ] 2>/dev/null; then
        log "story:approved rig DB $_wa_rig2_path: $_wa_rig2_n feature(s) (Bug A fix, WA_RIG_TIER2)."
        WA_RIG_TIER2_JSON=$(echo "$WA_RIG_TIER2_JSON $_wa_rig2_filtered" \
          | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "$WA_RIG_TIER2_JSON")
      fi
    done <<< "$_wa_rig2_rows"
  fi
  WA_RIG_TIER2_COUNT=$(echo "$WA_RIG_TIER2_JSON" | jq 'length' 2>/dev/null || echo "0")
  [ "${WA_RIG_TIER2_COUNT:-0}" -gt 0 ] 2>/dev/null \
    && log "story:approved rig features total: $WA_RIG_TIER2_COUNT (across all rig DBs, Bug A fix)."
fi

# Merge all pools into ONE candidate stream (wa-tm2a). dedup by id keeps a bead
# that somehow matched more than one query from being double-counted. The merge is
# the UNION — eligibility prefilters were applied identically to each pool above, so
# concatenation preserves them; only the ordering (Step 3, _top_candidate) now
# decides who goes first. CTXREADY_JSON is "[]" unless PILOT_CTX_READY_QUERIES=1,
# CTXREADY_RIG_JSON is "[]" unless PILOT_CTX_READY_RIG_QUERIES=1 (ga-mfeip).
# WA_RIG_TIER2_JSON is "[]" unless PILOT_WA_RIG_APPROVED_QUERIES=1 (Bug A fix).
ALL_CANDIDATES_JSON=$(echo "$TIER1_JSON $TIER2_JSON $CTXREADY_JSON $CTXREADY_RIG_JSON $WA_RIG_TIER2_JSON" \
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
    log "Merged candidate pool: $HQ_MERGED_COUNT (bugs/debt + stories + ${_ctx_total} ctx:ready chore/task [HQ=${CTXREADY_COUNT} rig=${CTXREADY_RIG_COUNT}] + ${WA_RIG_TIER2_COUNT} WA rig story:approved, priority-ordered)."
  else
    log "Merged candidate pool: $HQ_MERGED_COUNT (bugs/debt + stories + ${WA_RIG_TIER2_COUNT} WA rig story:approved, priority-ordered)."
  fi
fi

# ── Step 2c: Fallback — scan rig DBs if HQ returned nothing ──────────────────
# Per convention all story beads live in HQ, but check rig DBs as a fallback.
# Reached in TWO cases (ga-y1m40): (1) the merged HQ pool is empty (original
# behavior, unchanged below); or (2) Step 4b, near the end of the sweep, finds
# HQ was non-empty but dispatched NOTHING (e.g. every HQ candidate was vetoed
# by the ownership guard). Case (2) used to be invisible: a non-empty pool
# meant this block never ran at all, so the rig backlog (wa-*, ps-*) stayed
# unscanned for the ENTIRE sweep even with free slots (measured live: ~4h
# stall, 2026-07-31 03:50-07:50 — a human noticed, no alarm fired).
#
# _scan_rig_fallback_pool: scan every non-HQ rig DB for Tier1 (bug/tech-debt)
# + Tier2 (story:approved feature) candidates, same filter chain as the HQ
# queries. Sets RIG_MERGED_JSON / RIG_MERGED_COUNT / RIG_TIER1_COUNT /
# RIG_TIER2_COUNT as globals (direct mutation, not via $(...) — same
# convention as dispatch_lane's DISPATCHED: the script's top-level
# `exec >> LOG 2>&1` means command-substituting this function would swallow
# its own log lines). Called from Step 2c below AND from Step 4b (ga-y1m40).
# Test seam: PILOT_RIG_FALLBACK_OVERRIDE — when set, bypass the gc/bd loop and
# use this JSON array directly (hermetic selftest; no real gc/bd needed).
# Mirrors PILOT_WA_RIG_TIER2_OVERRIDE (Step 2b-rig-tier2).
_scan_rig_fallback_pool() {
  if [ -n "${PILOT_RIG_FALLBACK_OVERRIDE+x}" ]; then
    local _rfp_filtered
    _rfp_filtered=$(echo "$PILOT_RIG_FALLBACK_OVERRIDE" \
      | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built \
      | _filter_unblocked "${GC_CITY}" | _filter_explicit_deps "${GC_CITY}")
    RIG_TIER1_COUNT=$(echo "$_rfp_filtered" | jq '[ .[] | select(
        (((.issue_type // .type // "") | ascii_downcase) == "bug")
        or (((.labels // []) | index("tech-debt")) != null)
      ) ] | length' 2>/dev/null || echo "0")
    RIG_MERGED_JSON="$_rfp_filtered"
    RIG_MERGED_COUNT=$(echo "$RIG_MERGED_JSON" | jq 'length' 2>/dev/null || echo "0")
    RIG_TIER2_COUNT=$((RIG_MERGED_COUNT - RIG_TIER1_COUNT))
    return 0
  fi

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
    RIG_BUGS=$(echo "$RIG_BUGS" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
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
    RIG_DEBT=$(echo "$RIG_DEBT" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
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
    RIG_FEATURES=$(echo "$RIG_FEATURES" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER2=$(echo "$ALL_RIG_TIER2 $RIG_FEATURES" | jq -s 'add // []' 2>/dev/null || echo "[]")
  done <<< "$RIG_PATHS"

  RIG_TIER1_COUNT=$(echo "$ALL_RIG_TIER1" | jq 'length' 2>/dev/null || echo "0")
  RIG_TIER2_COUNT=$(echo "$ALL_RIG_TIER2" | jq 'length' 2>/dev/null || echo "0")

  # wa-tm2a: merge rig bugs/debt + features into ONE pool, same as HQ. Ordering
  # (priority>type>created_at>id) — not tier — decides who dispatches first.
  RIG_MERGED_JSON=$(echo "$ALL_RIG_TIER1 $ALL_RIG_TIER2" \
    | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")
  RIG_MERGED_COUNT=$(echo "$RIG_MERGED_JSON" | jq 'length' 2>/dev/null || echo "0")
}

# STEP2C_RAN (ga-y1m40): set when the block below actually scans rigs, so
# Step 4b (much later) can tell "already tried this sweep, don't repeat" apart
# from "never got the chance" — a non-empty pool that dispatched nothing.
STEP2C_RAN=""
if [ -z "$ALL_CANDIDATES_TIER" ]; then
  log "HQ returned no candidates (bugs/debt + stories) — scanning rig DBs as fallback ..."
  STEP2C_RAN=1
  _scan_rig_fallback_pool
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

# _split_candidates_by_lane <json>: classify each candidate into SMALL/BIG
# lanes via classify_lane. Sets SMALL_CANDIDATES/BIG_CANDIDATES/SMALL_COUNT/
# BIG_COUNT globals (same direct-mutation convention as _scan_rig_fallback_pool
# above). Factored into a function (ga-y1m40) because Step 4b re-splits a
# fresh rig-only pool after the primary lanes already ran once this sweep.
_split_candidates_by_lane() {
  local _scbl_json="$1" _scbl_bead _scbl_lane
  SMALL_CANDIDATES="[]"
  BIG_CANDIDATES="[]"
  while IFS= read -r _scbl_bead; do
    _scbl_lane=$(classify_lane "$_scbl_bead")
    if [ "$_scbl_lane" = "big" ]; then
      BIG_CANDIDATES=$(echo "$BIG_CANDIDATES" | jq --argjson b "$_scbl_bead" '. + [$b]' 2>/dev/null || echo "$BIG_CANDIDATES")
    else
      SMALL_CANDIDATES=$(echo "$SMALL_CANDIDATES" | jq --argjson b "$_scbl_bead" '. + [$b]' 2>/dev/null || echo "$SMALL_CANDIDATES")
    fi
  done < <(echo "$_scbl_json" | jq -c '.[]')
  SMALL_COUNT=$(echo "$SMALL_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
  BIG_COUNT=$(echo "$BIG_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
}

_split_candidates_by_lane "$ALL_CANDIDATES_JSON"
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
  sort_by([ (.priority // 99), (. | trank), -(((.created_at // "1970-01-01T00:00:00Z")[0:19] + "Z") | fromdateiso8601? // 0), (.id // "") ])
'  # created_at DESC = newest-first tiebreak (Athos prioridade 2026-06-24); prio+trank(bug>story) unchanged

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
  local STORY_ESTRELA STORY_CRITERIA STORY_EQUILIBRIOS STORY_RIG_EXPLICIT
  STORY_ID=$(echo "$STORY" | jq -r '.id')
  STORY_TITLE=$(echo "$STORY" | jq -r '(.title // .description // "untitled") | .[0:100]')
  STORY_PRIORITY=$(echo "$STORY" | jq -r '.priority // 99')
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')
  STORY_RIG=$(echo "$STORY" | jq -r '.metadata["story.rig"] // ""')
  # imp20: track whether story.rig was explicitly set in metadata vs inferred from prefix.
  # An explicit rig wins over bead_content_rig inference in the domain routing guard.
  STORY_RIG_EXPLICIT="0"
  [ -n "$STORY_RIG" ] && [ "$STORY_RIG" != "null" ] && STORY_RIG_EXPLICIT="1"
  STORY_ESTRELA=$(echo "$STORY" | jq -r '(.metadata["story.estrela_guia"] // "") | .[0:200]')
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

  # ga-j0f6: detect a bug/feature whose fix target is the beads CLI's own repo —
  # not a registered rig, no /gate-done path (see bead_targets_beads_repo above).
  local IS_BEADS_REPO_FIX
  IS_BEADS_REPO_FIX=$(bead_targets_beads_repo "$STORY")
  [ -n "$IS_BEADS_REPO_FIX" ] && log "  ga-j0f6: $STORY_ID targets the beads repo — using upstream-PR doctrine, not gate-done."

  # ── ga-jb4l: gate re-dispatch — surface reviewer feedback for needs-fix beads ──
  # A bead labeled gate:needs-fix previously FAILED the quality gate. The gate
  # attached the FAILing reviewers' reasons to it as a "GATE-FEEDBACK" comment.
  # Pull the latest such comment and the attempt counter so the builder prompt
  # tells the re-dispatched builder to fix THE SPECIFIC issues (not redo the work).
  local STORY_GATE_FEEDBACK="" STORY_FIX_ATTEMPT="" GATE_FIX_SECTION=""
  if echo "$STORY_LABELS" | grep -q "gate:needs-fix"; then
    # ga-26df: `:0` reset sentinel wins, else MAX — mirrors the dispatcher-side reader.
    # This label is READ here only (for the feedback banner), never written; but it must
    # match the dispatcher's semantics or the banner would show a different attempt number
    # than the cap logic acts on. Plain MIN stalls on a {1,2} automatic residue (a failed
    # `|| true` label-removal in the bump loop); see the dispatcher comment (ga-wisp-198xqe).
    _PA=$(echo "$STORY_LABELS" | tr ',' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p')
    if printf '%s\n' "$_PA" | grep -qx 0; then
      STORY_FIX_ATTEMPT=0
    else
      STORY_FIX_ATTEMPT=$(printf '%s\n' "$_PA" | sort -n | tail -1)
    fi
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

  # ── ga-e2n96: gate:needs-fix / gate:needs-remerge with ZERO feedback — do NOT
  # blind-dispatch a builder with an empty brief. This happens when a reconciler
  # (ga-pa36 GAP-2) re-arms the label purely to trigger a re-submission to the
  # gate — no reviewer ever rejected the code, so STORY_GATE_FEEDBACK above is
  # "". A builder given zero context tends to either reimplement already-working
  # code from scratch (a second, colliding branch) or spin until TTL-reclaim —
  # both burn a full session and the real fix still never reaches the gate.
  #
  # Detected on TWO signals: the source-level label gate:needs-remerge (the
  # reconciler's pure re-merge arm sets this ALONGSIDE gate:needs-fix, additive
  # so every existing gate:needs-fix consumer/filter in this file and elsewhere
  # keeps working unchanged) and, defensively, the bare gate:needs-fix + 0-char-
  # feedback shape (covers beads already in this state before this fix shipped,
  # and any other producer that ends up with nothing to say). Either way: never
  # sling a builder here. Try to resubmit the bead's OWN existing branch
  # straight to the gate (correct when a branch exists — no code is broken,
  # only a resubmission is needed) or escalate to a human when no such branch
  # can be found. Whichever path runs, gate:needs-fix/needs-remerge is stripped
  # so the bead never sits ambiguous — it moves into gate:queued or
  # gate:needs-human, both pre-existing, independently-monitored states.
  if echo "$STORY_LABELS" | grep -q "gate:needs-remerge" \
     || { echo "$STORY_LABELS" | grep -q "gate:needs-fix" && [ -z "$STORY_GATE_FEEDBACK" ]; }; then
    log "  ga-e2n96: $STORY_ID carries gate:needs-fix/needs-remerge with ZERO feedback — will NOT dispatch a builder with an empty brief. Searching for an existing branch to resubmit..."

    local REMERGE_MATCH="" REMERGE_REPO="" REMERGE_REF=""
    if REMERGE_MATCH=$(_beadid_needs_remerge_branch "$STORY_ID"); then
      REMERGE_REPO="${REMERGE_MATCH%%$'\t'*}"
      REMERGE_REF="${REMERGE_MATCH#*$'\t'}"
    fi

    if [ "$DRY_RUN" = "1" ]; then
      if [ -n "$REMERGE_REF" ]; then
        log "  ga-e2n96: DRY_RUN=1 — WOULD: resubmit $STORY_ID branch '$REMERGE_REF' directly to the gate (skip builder dispatch)"
      else
        log "  ga-e2n96: DRY_RUN=1 — WOULD: escalate $STORY_ID to gate:needs-human (no existing branch found, zero feedback)"
      fi
      return 1
    fi

    if [ -n "$REMERGE_REF" ]; then
      log "  ga-e2n96: found existing branch '$REMERGE_REF' for $STORY_ID (repo=$REMERGE_REPO) — resubmitting directly to the gate (no builder needed)."
      local REMERGE_BASE_SHA REMERGE_MARKER_ID
      REMERGE_BASE_SHA=$(git -C "$REMERGE_REPO" rev-parse origin/main 2>/dev/null || echo "unknown")
      REMERGE_MARKER_ID=$(bd -C "$GC_CITY" create \
        "ready-for-gate: $REMERGE_REF" \
        -t chore --ephemeral \
        -l type:quality-gate-marker \
        -l gate-status:ready \
        -l "branch:$REMERGE_REF" \
        -l "source-bead:$STORY_ID" \
        -l "bead-rig:$STORY_RIG" \
        -d "branch: $REMERGE_REF
bead_id: $STORY_ID
author: pilot-dispatcher(ga-e2n96-auto-remerge)
base_commit: $REMERGE_BASE_SHA
rig: $STORY_RIG
bead_rig: $STORY_RIG
submitted_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --json 2>/dev/null | jq -r '.id // empty')
      if [ -n "$REMERGE_MARKER_ID" ]; then
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "gate:needs-fix"     -q 2>/dev/null || true
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "gate:needs-remerge" -q 2>/dev/null || true
        bd -C "$STORY_BEAD_CITY" label add    "$STORY_ID" "gate:queued"        -q 2>/dev/null || true
        bd -C "$STORY_BEAD_CITY" comment "$STORY_ID" "ga-e2n96: Pilot auto-resubmitted existing branch '$REMERGE_REF' to the quality gate (marker $REMERGE_MARKER_ID) instead of dispatching a builder with an empty brief — gate:needs-fix/needs-remerge carried zero reviewer feedback, so no code fix was needed, only a resubmission." 2>/dev/null || true
        log "  ga-e2n96: gate marker $REMERGE_MARKER_ID created for $STORY_ID branch $REMERGE_REF — skipping builder dispatch this sweep."
      else
        warn "ga-e2n96: found branch $REMERGE_REF for $STORY_ID but FAILED to create gate marker — leaving labels as-is for next sweep to retry."
      fi
    else
      warn "ga-e2n96: $STORY_ID carries gate:needs-fix/needs-remerge with zero feedback and NO existing fix/$STORY_ID-* branch found — escalating to human instead of blind-dispatching a builder."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "gate:needs-fix"     -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "gate:needs-remerge" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" label add    "$STORY_ID" "gate:needs-human"   -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" comment "$STORY_ID" "ga-e2n96: Pilot found gate:needs-fix/needs-remerge with zero reviewer feedback and no existing fix/$STORY_ID-* branch to resubmit — escalating to gate:needs-human rather than dispatching a builder with an empty brief." 2>/dev/null || true
    fi
    return 1
  fi

  # ── ga-qm7u: prior zero-progress attempt(s) — nudge builder to verify live first ──
  # A bead carrying pilot:reclaim-count:N (N>=1, scripts/inflight-reclaim-guard.py)
  # already burned at least one full dispatch+TTL cycle on a builder that made ZERO
  # progress (no branch/commit) before the 25min inactivity reclaim-guard caught it.
  # The single most common cause observed (ga-qm7u): the reported symptom was already
  # fixed LIVE, outside the bd/gate flow, so the bead was never closed and kept
  # re-dispatching blind — 3 full cycles (~2h) were burned before the existing
  # _FILTER_RECLAIM_CAP=3 cap (ga-am6h) finally stopped it. Rather than let the next
  # builder discover this the same slow way, tell it up front to verify the symptom
  # still reproduces FIRST and close immediately via the existing "no-changes"
  # convention (internal/templates/commands/bodies/done.md) if it doesn't — before
  # spending any time on implementation. This does NOT change whether a bead
  # redispatches (_FILTER_RECLAIM_CAP still governs that); it only makes the 2nd/3rd
  # attempt fast instead of blind.
  local STORY_RECLAIM_COUNT="" LIVE_VERIFY_SECTION=""
  STORY_RECLAIM_COUNT=$(echo "$STORY_LABELS" | tr ',' '\n' \
    | sed -n 's/^pilot:reclaim-count:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
  if [ -n "$STORY_RECLAIM_COUNT" ] && [ "$STORY_RECLAIM_COUNT" -ge 1 ]; then
    log "  $STORY_ID has pilot:reclaim-count:$STORY_RECLAIM_COUNT — injecting live-verify-first section."
    LIVE_VERIFY_SECTION=$(cat <<LIVESEC

## ⚠️ PRIOR ZERO-PROGRESS ATTEMPT(S) — verify live BEFORE building (reclaim_count=$STORY_RECLAIM_COUNT)
A prior builder was dispatched to this bead and made ZERO progress (no branch or
commit) before the inactivity reclaim-guard reclaimed it ($STORY_RECLAIM_COUNT
time(s) so far). The most common cause: the reported symptom was already fixed
LIVE, outside the bd/gate flow, and this bead was simply never closed.

BEFORE writing any code: quickly verify the reported symptom still reproduces
against the current code/running system. If it does NOT reproduce (fix already
present), close immediately with evidence — do not attempt to build:
  bd -C "$STORY_BEAD_CITY" close "$STORY_ID" --reason="no-changes: verified live, symptom already fixed (cite commit/evidence)"
Only proceed to implement once you have confirmed, with evidence, that the bug
still reproduces.
LIVESEC
)
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
  # branch exists, (d) a live gate marker/run is ACTIVELY gating its branch (the
  # open-during-gate-handoff race), (c) an external active claim, or (b) a live
  # named-crew owner. This
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
      # ga-8jxe1 AC4: sweep-wide counter (mutated directly, NOT via $(...) — same
      # non-subshell requirement as the DISPATCHED global below) so a "dispatched=0"
      # sweep summary can report HOW MANY candidates the guard vetoed, instead of
      # requiring a code read to even suspect this guard was the cause.
      OWNERSHIP_GUARD_VETO_COUNT=$((OWNERSHIP_GUARD_VETO_COUNT + 1))
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
        if _sling_is_live "$_EXISTING_SLING" "$GC_CITY" "$STORY_ID"; then
          warn "ga-cnvy1: SKIPPING dispatch of $STORY_ID — a LIVE wrapper ($_EXISTING_SLING, status=$_EXISTING_SLING_STATUS, branch/fresh) already exists for this target; work is already dispatched. Releasing claim, NOT minting a 2nd sling (set PILOT_DEDUP_GUARD=0 to disable)."
          if [ "$DRY_RUN" != "1" ]; then
            bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
            bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
          fi
          return 1
        fi
        warn "ga-cnvy1: existing wrapper ($_EXISTING_SLING, status=$_EXISTING_SLING_STATUS) for $STORY_ID is STALE (no crew branch, idle >${STALE_SLING_SECONDS}s) — DEAD wrapper (worker leaked it open), closing it + dispatching fresh (NOT a duplicate)."
        if [ "$DRY_RUN" != "1" ]; then
          bd -C "$GC_CITY" close "$_EXISTING_SLING" --reason "Stale wrapper auto-closed by Pilot dedup-guard: open but idle >${STALE_SLING_SECONDS}s with no crew branch — was HOL-blocking $STORY_ID (dead-builder leak)." -q 2>/dev/null || true
        fi
        # fall through to dispatch a fresh sling for this still-pending target
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
    # ga-uvfs6: a domain whose owner is STRUCTURALLY REQUIRED (not just a rotation
    # preference — see rig_domain_requires_persistent_owner) dispatches to that
    # owner directly, bypassing the ephemeral pool-slot rotation entirely.
    # BUILDER_TARGET becomes the named crew itself (never a wa-worker-N/
    # ps-worker-N slot), so the bead never receives gc.routed_to=<pool> at all.
    # If the owner is busy/suspended/at-cap/human-engaged, fall through to the
    # normal pool rotation below UNCHANGED (same as any other domain) — this
    # never blocks dispatch, it only redirects it when the owner is available.
    if [ -n "$_PREFER" ] && rig_domain_requires_persistent_owner "$STORY_RIG" "$_DOMAIN"; then
      local _OWNER_BUSY=0
      _crew_session_human_engaged "$_PREFER" && _OWNER_BUSY=1
      _crew_is_suspended "$_PREFER" && _OWNER_BUSY=1
      _crew_at_inflight_cap "$_PREFER" && _OWNER_BUSY=1
      case " $PILOT_BUSY_BUILDERS " in *" $_PREFER "*) _OWNER_BUSY=1 ;; esac
      case " $PILOT_USED_BUILDERS " in *" $_PREFER "*) _OWNER_BUSY=1 ;; esac
      if [ "$_OWNER_BUSY" = "0" ]; then
        BUILDER_TARGET="$_PREFER"
        log "ga-uvfs6: $STORY_ID domain=$_DOMAIN requires persistent owner $_PREFER — dispatching directly, bypassing wa-worker pool rotation."
      fi
    fi
    if [ -z "${BUILDER_TARGET:-}" ]; then
      BUILDER_TARGET=$(pick_pool_builder "$STORY_RIG" "$_PREFER" "$_EXCLUDE" || echo "")
    fi
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
        local _DOMAIN_RIG="" _PATH_RIG=""
        # imp20: if story.rig is EXPLICITLY set in metadata (STORY_RIG_EXPLICIT=1), honor it
        # as authoritative over content-based inference. bead_content_rig uses keyword matching
        # which can false-positive on WA features that mention property/CNAE/ITBI nouns.
        if [ "$STORY_RIG_EXPLICIT" = "1" ] && [ "$STORY_RIG" != "gascity" ] && [ "$STORY_RIG" != "null" ] && [ -n "$STORY_RIG" ]; then
          _DOMAIN_RIG="$STORY_RIG"
          log "imp20: $STORY_ID story.rig=$STORY_RIG is explicit — using authoritative rig over bead_content_rig inference"
        else
          # ── FIX 1 (ga-xzfl): PATH-authoritative rig derivation, BEFORE owner/keyword ──
          # The FILE PATHS a bead names beat the words it uses. A concrete PRODUCT path
          # (crew/<*-wa|*-ps>/, outreach//painel//shared/ → WA; scrapers/ → PS) is used
          # directly, overriding the owner/keyword inference below. A gascity/framework
          # path (packs//scripts//…) is NOT resolved here — it is recorded in _PATH_RIG
          # and handled by the framework-dog-exempt (FIX 2) so its "clear → fail-open to
          # the dog" still logs and still honors PILOT_FRAMEWORK_DOG_EXEMPT (keeps the
          # ga-tgo7q/ga-evjs2 exemption scenarios intact). This placement lets a concrete
          # framework path WIN over a *-wa owner (the guard below never sets a product rig
          # for it). Fail-open: PILOT_PATH_RIG_GUARD=0 or no path extracted ⇒ _PATH_RIG=""
          # ⇒ the owner/keyword block runs byte-for-byte unchanged.
          if [ "${PILOT_PATH_RIG_GUARD:-1}" = "1" ]; then
            _PATH_RIG=$(bead_path_rig "$STORY" 2>/dev/null || echo "")
          fi
          if [ -n "$_PATH_RIG" ] && [ "$_PATH_RIG" != "gascity" ]; then
            _DOMAIN_RIG="$_PATH_RIG"
            log "ga-xzfl: $STORY_ID path-authoritative rig=$_PATH_RIG (from cited file paths) — overriding owner/keyword inference (a bead's file paths beat its words). Disable with PILOT_PATH_RIG_GUARD=0."
          else
          # ga-nlh79: OWNER-AUTHORITATIVE rig precedence — a bead whose creator (created_by)
          # or assignee is a *-wa crew belongs to whatsapp_automation by definition, BEFORE
          # any content-keyword inference. bead_content_rig's keyword match fails when the
          # bead title/description has no WA magic keyword (e.g. "code-mode MCP servers",
          # "Contagem cadastre bulk-load") but DOES have property-ish nouns (ITBI, Contagem,
          # Hex) that trigger the property_scrapers branch — the root of the ga-wuzeg/ga-nq64a/
          # ga-lt8cw/wa-86jr misroute-to-batista-ps infinite loop. The owner signal is more
          # authoritative than keyword inference: whoever CREATED or is ASSIGNED to a bead
          # is the ground-truth rig signal. Gated by PILOT_OWNER_RIG_GUARD (default 1).
          # Fail-open: if the jq extract fails or the field is empty, fall through to the
          # normal bead_content_rig path (behavior unchanged).
          if [ "${PILOT_OWNER_RIG_GUARD:-1}" = "1" ]; then
            local _BEAD_CREATED_BY _BEAD_ASSIGNEE_RAW _OWNER_RIG_SIGNAL=""
            _BEAD_CREATED_BY=$(echo "$STORY" | jq -r '(.created_by // "") | select(length>0)' 2>/dev/null || echo "")
            _BEAD_ASSIGNEE_RAW=$(echo "$STORY" | jq -r '(.assignee // "") | select(length>0)' 2>/dev/null || echo "")
            # Strip dog-pool and ephemeral-worker assignees — only persistent named-crew owners count.
            # wa-worker* and ps-worker* are ephemeral (not named crews) so must not be domain signals.
            case "$_BEAD_ASSIGNEE_RAW" in gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) _BEAD_ASSIGNEE_RAW="" ;; esac
            # Check created_by first (the FILER = true domain owner), then assignee as fallback.
            # wa-worker* as creator also signals WA domain (it ran a WA build that created this bead).
            # ga-nlh79 fix: created_by/assignee carry a session-id suffix (e.g. mila-wa-gawispsqpzr0),
            # so `*-wa` alone MISSES the suffixed form → fell through to content-rig → property-noun
            # beads (ITBI/CNPJ/sócios) owned by mila-wa misrouted to batista-ps. Match `*-wa-*` too.
            case "$_BEAD_CREATED_BY" in *-wa|*-wa-*|wa-worker*) _OWNER_RIG_SIGNAL="whatsapp_automation" ;; esac
            if [ -z "$_OWNER_RIG_SIGNAL" ]; then
              case "$_BEAD_ASSIGNEE_RAW" in *-wa|*-wa-*|wa-worker*) _OWNER_RIG_SIGNAL="whatsapp_automation" ;; esac
            fi
            # ps-worker* as creator signals PS domain (it ran a PS build that created this bead).
            if [ -z "$_OWNER_RIG_SIGNAL" ]; then
              case "$_BEAD_CREATED_BY" in ps-worker*) _OWNER_RIG_SIGNAL="property_scrapers" ;; esac
            fi
            if [ -n "$_OWNER_RIG_SIGNAL" ]; then
              # ── ga-zzqza (Mayor ruling, 2026-07-24, AC4 follow-up to ga-uvfs6): HQ-EXCLUSIVE
              # path EXISTENCE outranks the owner-authoritative signal just computed above.
              # bead_path_rig (FIX 1) is PATTERN-matching (dir-name prefixes) and deliberately
              # returns "" for a bare scripts/ citation because that directory name exists in HQ
              # *and* both product rigs — but a bead can cite a SPECIFIC file (e.g.
              # scripts/root-class-count.sh) that genuinely exists ONLY in HQ, even though
              # "scripts/" as a bare prefix is ambiguous. Prior to this fix, such a bead
              # (created_by=*-wa/ps-worker, zero product keyword — ga-shqn/ga-9oyvj, Mayor sweep
              # 2026-07-19) hit _OWNER_RIG_SIGNAL above and was permanently misrouted to a product
              # rig, looping refuse→hold forever (the ga-zzqza conflict: an earlier attempt to
              # gate bead_content_rig on a product keyword FIXED this but broke Scenarios
              # 18k2/18y/18y2, so it was reverted rather than shipped blind — see ga-zzqza).
              # MAYOR RULING: created_by-based inference YIELDS to file existence — a path that
              # resolves to a REAL file under HQ and under NO product rig is unambiguous framework
              # work, dog-routed regardless of who created it. created_by remains the tie-breaker
              # ONLY when cited paths are ABSENT everywhere or AMBIGUOUS (present in HQ AND a
              # product rig, or the probe can't tell) — so this check is scoped to ONLY the
              # owner-authoritative branch, deliberately NOT the plain bead_content_rig fallback
              # below (an ownerless keyword-guessed misroute is already a separate, already-solved
              # problem: the FIX 3 missing-file guard further down catches it post-hoc; touching
              # that path here would be an unrelated behavior change beyond this ruling's scope).
              # Reuses the ga-xzfl missing-file guard's own _rig_has_any_path (identical fail-open
              # semantics: an unresolvable rig root or a probe error reads as "present", never
              # manufacturing a false HQ-only verdict). Gated by PILOT_HQ_PATH_EXISTS_GUARD
              # (default 1). Fail-open: no cited path, or _rig_has_any_path unable to confirm
              # absence from EVERY product rig ⇒ _HQ_ONLY_PATH stays 0 ⇒ the owner signal commits
              # exactly as before.
              #
              # ga-hn3kh: ALSO check bare-filename citations (_rig_has_any_basename), not just
              # slash-joined paths. ga-shqn (the motivating case: root-class-count.sh, cited by
              # bare filename only, never "scripts/root-class-count.sh") proved bead_cited_paths
              # alone leaves this guard permanently inert for any bead that names a real HQ
              # script without its directory — _EXIST_CITED_PATHS is empty, the guard below
              # never runs, and _OWNER_RIG_SIGNAL commits unchallenged even though the file is
              # genuinely HQ-only. Each rig-hit is computed explicitly (not via `||` across two
              # fail-open-on-empty predicates, which would short-circuit true and defeat the
              # absence checks) so a bead can supply either signal, both, or neither.
              # NOTE (scope decision): a bare ga-* PREFIX is deliberately NOT used as a tie-
              # breaker here (contrast the story's AC2 wording) — Scenario 18k2's mila-wa-owned
              # "code-mode MCP servers" bead is ga-* prefixed, has zero path/keyword evidence,
              # and must STILL route to WA (ga-nlh79). It is structurally indistinguishable from
              # a content-free ga-* WA-owner POV bead (e.g. ga-9oyvj) that this story also names
              # as affected — prefix-vs-owner is a genuine policy conflict between two already-
              # adjudicated rulings, not a bug this existence-based guard can resolve; it needs
              # an explicit Mayor call, not a builder's unilateral pick between the two.
              local _HQ_ONLY_PATH=0 _EXIST_CITED_PATHS="" _EXIST_CITED_NAMES=""
              if [ "${PILOT_HQ_PATH_EXISTS_GUARD:-1}" = "1" ]; then
                _EXIST_CITED_PATHS=$(bead_cited_paths "$STORY" 2>/dev/null || echo "")
                _EXIST_CITED_NAMES=$(bead_cited_basenames "$STORY" 2>/dev/null || echo "")
                if [ -n "$_EXIST_CITED_PATHS" ] || [ -n "$_EXIST_CITED_NAMES" ]; then
                  local _HQZ_HQ_HIT=0 _HQZ_WA_HIT=0 _HQZ_PS_HIT=0
                  [ -n "$_EXIST_CITED_PATHS" ] && _rig_has_any_path "gascity" "$_EXIST_CITED_PATHS" && _HQZ_HQ_HIT=1
                  [ -n "$_EXIST_CITED_NAMES" ] && _rig_has_any_basename "gascity" "$_EXIST_CITED_NAMES" && _HQZ_HQ_HIT=1
                  [ -n "$_EXIST_CITED_PATHS" ] && _rig_has_any_path "whatsapp_automation" "$_EXIST_CITED_PATHS" && _HQZ_WA_HIT=1
                  [ -n "$_EXIST_CITED_NAMES" ] && _rig_has_any_basename "whatsapp_automation" "$_EXIST_CITED_NAMES" && _HQZ_WA_HIT=1
                  [ -n "$_EXIST_CITED_PATHS" ] && _rig_has_any_path "property_scrapers" "$_EXIST_CITED_PATHS" && _HQZ_PS_HIT=1
                  [ -n "$_EXIST_CITED_NAMES" ] && _rig_has_any_basename "property_scrapers" "$_EXIST_CITED_NAMES" && _HQZ_PS_HIT=1
                  if [ "$_HQZ_HQ_HIT" = "1" ] && [ "$_HQZ_WA_HIT" = "0" ] && [ "$_HQZ_PS_HIT" = "0" ]; then
                    _HQ_ONLY_PATH=1
                  fi
                fi
              fi
              if [ "$_HQ_ONLY_PATH" = "1" ]; then
                _DOMAIN_RIG=""
                log "ga-zzqza: $STORY_ID cites path(s) present in HQ (gascity) and absent from every known product rig (paths=[$(printf '%s' "$_EXIST_CITED_PATHS" | tr '\n' ' ')] basenames=[$(printf '%s' "$_EXIST_CITED_NAMES" | tr '\n' ' ')]) — unambiguous framework work per Mayor ruling (ga-hn3kh: basename-only citations count too); overriding owner-authoritative (created_by='$_BEAD_CREATED_BY' assignee='$_BEAD_ASSIGNEE_RAW' would have routed $_OWNER_RIG_SIGNAL). Disable with PILOT_HQ_PATH_EXISTS_GUARD=0."
              else
                _DOMAIN_RIG="$_OWNER_RIG_SIGNAL"
                log "ga-nlh79: $STORY_ID owner-authoritative rig (created_by='$_BEAD_CREATED_BY' assignee='$_BEAD_ASSIGNEE_RAW') → $_DOMAIN_RIG (BEFORE content-keyword inference, preventing misroute to property_scrapers)"
              fi
            else
              _DOMAIN_RIG=$(bead_content_rig "$STORY" 2>/dev/null || echo "")
            fi
          else
            _DOMAIN_RIG=$(bead_content_rig "$STORY" 2>/dev/null || echo "")
          fi
          fi  # end FIX 1 (ga-xzfl) path-authoritative if/else — falls through to owner/keyword inference above
        fi
        # ── framework-dog-exempt (ga-tgo7q/ga-evjs2, 2026-07-02): gascity-framework
        # work is DOG-APPROPRIATE — must NOT be refused. ──────────────────────────
        # bead_content_rig is CONTENT-keyword inference and can false-positive to a
        # PRODUCT rig on an INCIDENTAL token: an infra bead that merely NAMES the rig
        # it reproduces on ("this repro is on whatsapp_automation, 5 active crews")
        # or uses a Portuguese verb overlapping a WA keyword ("Disparou o watchdog" ⊃
        # "disparo") gets _DOMAIN_RIG=whatsapp_automation. WA has no
        # rig_domain_default_builder (→ ""), so such a mis-inferred bead falls to rule
        # (3): REFUSING to the dog pool + stamping a 1h pilot:held EVERY sweep — the
        # ga-tgo7q/ga-evjs2 stall (336 select→refuse→hold→re-select loops, 2026-07-01/02),
        # dispatching NOTHING while these were the ONLY buildable beads in the queue.
        #
        # ROOT INSIGHT: gate/dispatcher/dolt/reviewer/headroom/refinery/framework work is
        # gascity-FRAMEWORK, and the ephemeral gastown.dog pool is its CORRECT builder — a
        # dog HAS the HQ/gascity checkout, git-diff, and gate access this work needs. That
        # is the OPPOSITE of a PRODUCT-domain build (property scraper / WA feature), which
        # needs a rig repo + domain data the dog lacks. So an HQ/gascity infra bead reaching
        # the dog pool must FAIL-OPEN (dispatch) — exactly as this guard's header promises
        # for an unmapped/unknown domain — never be refused.
        #
        # FIX (minimal, fail-open): if the bead's COARSE domain is infra (bead_domain, which
        # checks the four PRODUCT domains frontend/real-estate/warming/data FIRST and infra
        # LAST — so it returns "infra" ONLY when NO product keyword matched), it is framework
        # work: CLEAR the mis-inferred product rig so the routing block below is skipped and
        # dispatch to the dog proceeds. A genuine product build (property scraper, WA warming/
        # real-estate/data/painel) is classified as that PRODUCT by bead_domain — NEVER
        # "infra" — so it is untouched here and still steered to its owning crew (rule 2) or
        # held away from the dog (rule 3). Gated by PILOT_FRAMEWORK_DOG_EXEMPT (default 1);
        # fail-open: any bead_domain error → empty → no exemption → prior behaviour.
        if [ -n "$_DOMAIN_RIG" ] && [ "$_DOMAIN_RIG" != "gascity" ] && [ "${PILOT_FRAMEWORK_DOG_EXEMPT:-1}" = "1" ]; then
          local _FW_DOMAIN="" _FW_EXEMPT=0 _FW_REASON=""
          _FW_DOMAIN=$(bead_domain "$STORY" 2>/dev/null || echo "")
          # (a) coarse domain is infra — bead_domain checks the 4 PRODUCT domains FIRST,
          #     so "infra" means NO product keyword matched (the original ga-tgo7q key).
          if [ "$_FW_DOMAIN" = "infra" ]; then _FW_EXEMPT=1; _FW_REASON="bead_domain=infra"; fi
          # (b) ga-xzfl: a concrete HQ/framework PATH is authoritative even when bead_domain
          #     mis-classifies. bead_domain matches 'scraper' ⊂ 'property_scrapers' (a data
          #     keyword) BEFORE it can reach "infra", so a bead ABOUT the router — cites
          #     packs//scripts/ AND says "property_scrapers"/"scraper" in prose — is NEVER
          #     infra and slipped this exemption (the ga-xzfl self-sabotage). _PATH_RIG==gascity
          #     (bead_path_rig) is the path-level proof it is framework work for the dog.
          #     (_PATH_RIG is only non-empty when PILOT_PATH_RIG_GUARD=1 — so this clause is
          #     naturally gated by that knob too.)
          if [ "$_FW_EXEMPT" = "0" ] && [ "$_PATH_RIG" = "gascity" ]; then _FW_EXEMPT=1; _FW_REASON="bead_path_rig=gascity"; fi
          # (c) ga-xzfl: an explicit framework / pack:town-deltas / dog-pool LABEL is a direct
          #     Mayor/refino signal that this is dog-pool framework work. jq -e any(); fail-open.
          if [ "$_FW_EXEMPT" = "0" ] && echo "$STORY" | jq -e '(.labels // []) | any(. == "framework" or . == "pack:town-deltas" or . == "dog-pool")' >/dev/null 2>&1; then _FW_EXEMPT=1; _FW_REASON="framework-label"; fi
          # (d) ga-r4jnu/ga-zfe51: an explicit area:infra LABEL is a direct Mayor/refino
          #     signal that a human already classified this bead as infrastructure —
          #     covers the case bead_domain's own infra keywords (a) miss. bead_domain's
          #     "infra" branch is a narrow, curated allowlist (dolt/gate dispatcher/
          #     reviewer/dispatcher/framework/headroom/refinery); an infra bead written in
          #     different ops vocabulary (disk-floor-guard/reaper/scratch/transcript) isn't
          #     "infra" by (a), has no cited path for (b), and isn't literally labeled
          #     framework/pack:town-deltas/dog-pool for (c) — yet still needs the exemption
          #     when bead_content_rig trips on an incidental keyword (e.g. "disparou" ⊃
          #     "disparo" before the ga-r4jnu word-boundary fix; the next unforeseen false
          #     cognate after it). area:infra is an established label (5 live HQ beads at
          #     time of fix) already meaning exactly this. jq -e any(); fail-open.
          if [ "$_FW_EXEMPT" = "0" ] && echo "$STORY" | jq -e '(.labels // []) | any(. == "area:infra")' >/dev/null 2>&1; then _FW_EXEMPT=1; _FW_REASON="area-infra-label"; fi
          # (e) ga-mhbyc: an explicit "digest" LABEL is a direct signal that this bead is
          #     an archived activity report (mol-digest-generate's generate-and-send step
          #     stamps every digest bead --label=digest,{{period}}), not a domain build.
          #     A digest's own auto-generated "By Rig" table NAMES every product rig
          #     (property_scrapers, whatsapp_automation) to report its filed/closed counts
          #     — an INCIDENTAL mention, not the bead's subject. This defeats (a) twice
          #     over: bead_content_rig's WA-INTEGRATION PRECEDENCE matches bare "whatsapp"
          #     before bead_domain is ever consulted, AND bead_domain itself never reaches
          #     its "infra" branch (checked LAST) because "scraper" ⊂ "property_scrapers"
          #     is also an (earlier-checked) data-domain keyword — so a digest classifies
          #     "data", never "infra". No cited file path (b) and no framework/area:infra
          #     label (c/d) apply to a plain digest bead either (ga-j54v3: labels were only
          #     ["daily","digest"]) — the ga-tgo7q/ga-evjs2 stall recurring in a 5th shape
          #     (REFUSE+1h-hold, every sweep, on the ONLY buildable bead in queue). Unlike
          #     area:infra, "digest" is not a discretionary human label — it is stamped by
          #     the formula on every digest bead, daily and weekly, by construction. jq -e
          #     any(); fail-open.
          if [ "$_FW_EXEMPT" = "0" ] && echo "$STORY" | jq -e '(.labels // []) | any(. == "digest")' >/dev/null 2>&1; then _FW_EXEMPT=1; _FW_REASON="digest-label"; fi
          # (f) ga-1mqdz (AC2): the bead's text ALSO matches bead_domain's infra
          #     keyword set, even though bead_domain returned an EARLIER-checked
          #     PRODUCT domain instead. bead_domain checks frontend/real-estate/
          #     warming/data BEFORE infra (by design, for its OTHER caller —
          #     rig_domain_owner/exclude crew-picking — where "most-specific
          #     product domain wins" is correct), so any earlier match SHADOWS an
          #     infra signal that is also genuinely present, hiding it from
          #     exemption (a). Concrete case: ga-t8274/ga-i0n83, two genuine Pilot/
          #     gate-dispatcher framework bugs (cite "gate dispatcher"/"dispatcher"
          #     in prose) that ALSO describe a SYMPTOM — "o painel mostra N beads
          #     presos" — tripping \bkanban\b/\bpainel\b, bead_domain's FRONTEND
          #     check (checked first). bead_domain returns "frontend", never
          #     reaches "infra", and the bead is REFUSED+held every sweep for 3
          #     cycles although it is unmistakably dog-appropriate framework work
          #     (confirmed live via dolt_diff: pilot:no-auto-dispatch predates the
          #     first hold by 5 days — see AC1 above — so this is a genuinely
          #     stuck framework bug, not a misfiled product build). Re-checks
          #     bead_domain's OWN infra regex directly (duplicated here — keep in
          #     sync with the "infra" branch inside bead_domain() above) rather
          #     than reordering bead_domain's precedence globally, which would
          #     change rig_domain_owner/exclude's crew-pick behaviour for every
          #     OTHER caller, an unrelated blast radius this fix does not need.
          #     jq -e any(); fail-open.
          if [ "$_FW_EXEMPT" = "0" ] && echo "$STORY" | jq -r '
              [ (.title // ""), (.description // ""),
                (.acceptance_criteria // .metadata["story.criterios"] // ""),
                ((.labels // []) | join(" ")) ] | join("  ")
            ' 2>/dev/null | grep -iqE '\bdolt\b|gate dispatcher|\breviewer\b|\bdispatcher\b|\bframework\b|headroom|\brefinery\b'; then
            _FW_EXEMPT=1; _FW_REASON="infra-keyword-shadowed(bead_domain=$_FW_DOMAIN)"
          fi
          if [ "$_FW_EXEMPT" = "1" ]; then
            log "framework-dog-exempt: $STORY_ID is gascity-framework work ($_FW_REASON) but bead_content_rig mis-inferred rig=$_DOMAIN_RIG from an incidental keyword — the dog pool ($BUILDER_TARGET) IS its correct builder (HQ checkout, git-diff, gate access). Clearing product-rig inference so the domain-route guard FAILS OPEN (dispatch, not REFUSE+1h-hold). Disable with PILOT_FRAMEWORK_DOG_EXEMPT=0."
            _DOMAIN_RIG=""
          fi
        fi
        # ── FIX 3 (ga-xzfl): missing-file guard ──────────────────────────────────────
        # Before routing to a NON-DOG product rig, verify that rig actually contains the
        # files the bead names. If the bead cites concrete file paths and NONE exist in
        # $_DOMAIN_RIG's repo, that rig is WRONG for this bead — dispatching there
        # NEVERSTARTS (the builder has no files to touch, circuit-breaks, and the bead
        # re-queues forever: the ga-xzfl failure). Clear the inference so the bead falls
        # OPEN to the dog instead. This one check guards BOTH reroute sites (rules 1 & 2
        # below) since both build in $_DOMAIN_RIG. Gated by PILOT_MISSING_FILE_GUARD
        # (default 1). FAIL-OPEN: no cited paths, an unknown/off-disk rig root, or any probe
        # error ⇒ _rig_has_any_path succeeds ⇒ no refuse ⇒ routing proceeds exactly as
        # today. Reuses the PILOT_RIG_PATHS_JSON cache (no fresh `gc rig list` per bead).
        if [ -n "$_DOMAIN_RIG" ] && [ "$_DOMAIN_RIG" != "gascity" ] && [ "${PILOT_MISSING_FILE_GUARD:-1}" = "1" ]; then
          local _CITED_PATHS=""
          _CITED_PATHS=$(bead_cited_paths "$STORY" 2>/dev/null || echo "")
          # FINDING 2: only DOG a missing-file bead when the cited files are GENUINELY
          # MISLOCATED — absent in $_DOMAIN_RIG but PRESENT IN HQ (gascity), where the dog
          # actually builds. If HQ ALSO lacks them, this is a CREATE-FILE bead (the file
          # doesn't exist anywhere yet) and $_DOMAIN_RIG is the CORRECT rig to create it in —
          # dogging it would NEVERSTART on the dog too (HQ has no such file). So require BOTH:
          # R lacks every cited path AND HQ holds ≥1. Both probes are fail-open (see
          # _rig_has_any_path FINDING 4), so a probe hiccup never manufactures a refuse.
          if [ -n "$_CITED_PATHS" ] \
             && ! _rig_has_any_path "$_DOMAIN_RIG" "$_CITED_PATHS" \
             && _rig_has_any_path "gascity" "$_CITED_PATHS"; then
            warn "ga-xzfl missing-file guard: $STORY_ID cites file path(s) present in HQ but in NONE of rig $_DOMAIN_RIG — MISLOCATED to the wrong rig (routing there NEVERSTARTS: no files to build). Clearing inference so the bead falls OPEN to the dog (which builds in HQ, where the files are). Cited: $(printf '%s' "$_CITED_PATHS" | tr '\n' ' '). Disable with PILOT_MISSING_FILE_GUARD=0."
            _DOMAIN_RIG=""
          fi
        fi
        if [ -n "$_DOMAIN_RIG" ] && [ "$_DOMAIN_RIG" != "gascity" ]; then
          # (1) explicit live crew owner wins.
          # imp20: honor an EXPLICIT story.assignee (Mayor-set persistent-crew owner) even
          # when the dead-worker roster is unavailable (_DEADWORKER_OK!=1). The roster is
          # only needed to DISCOVER liveness — but an explicit Mayor-set assignee is
          # authoritative by definition. "Roster unavailable" must NOT silently drop the
          # owner; only "roster available AND assignee confirmed dead" should fall through.
          # We extract the assignee from the already-loaded STORY JSON (no extra bd call)
          # and use it directly when the roster is unavailable. When the roster IS
          # available, _beadid_live_crew_owner already handles the liveness check correctly
          # (returns 1 for a dead session → correct fall-through to pilot:held).
          local _DOM_CREW_OWNER=""
          local _EXPLICIT_ASSIGNEE=""
          _EXPLICIT_ASSIGNEE=$(echo "$STORY" | jq -r '(.assignee // "") | select(length>0)' 2>/dev/null || echo "")
          # Strip dog-pool and ephemeral-worker assignees — not authoritative persistent-crew owners.
          case "$_EXPLICIT_ASSIGNEE" in gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) _EXPLICIT_ASSIGNEE="" ;; esac
          # ITEM 6 (pilot-rewire): strip suspended explicit assignees — dispatching to a
          # suspended crew leaves the bead assigned-but-unbuilt. Clear the assignee so the
          # bead falls through to pool routing (pick_pool_builder) instead.
          # Applied BEFORE the imp20 roster-unavailable path to prevent suspended-crew routing
          # even when the roster is absent. Fail-open: _crew_is_suspended is already fail-open.
          if [ -n "$_EXPLICIT_ASSIGNEE" ] && _crew_is_suspended "$_EXPLICIT_ASSIGNEE"; then
            log "pilot-rewire: $STORY_ID has explicit assignee=$_EXPLICIT_ASSIGNEE but that crew is SUSPENDED — clearing to allow pool routing"
            _EXPLICIT_ASSIGNEE=""
          fi
          # CREW PM-CHOICE ESCAPE HATCH (pilot-rewire spec §8):
          # A crew sets story.assignee=<self> in its PM session to claim a bead.
          # This explicit-assignee path dispatches to it, bypassing the wa-worker pool.
          # Example: `bd assign wa-1234 mila-wa` from mila-wa's session → this guard
          # honors it and slings to mila-wa, not to wa-worker-*.
          # Suspended-crew check is applied BEFORE honoring (item 6 above).
          if [ "${_DEADWORKER_OK:-0}" != "1" ] && [ -n "$_EXPLICIT_ASSIGNEE" ]; then
            # Roster unavailable: trust the explicit Mayor-set assignee as authoritative.
            _DOM_CREW_OWNER="$_EXPLICIT_ASSIGNEE"
            log "imp20: $STORY_ID has explicit assignee=$_EXPLICIT_ASSIGNEE but roster unavailable (_DEADWORKER_OK!=1) — honoring the Mayor-set owner authoritatively (roster needed only to confirm death, not to discover owner)."
          else
            _DOM_CREW_OWNER=$(_beadid_live_crew_owner "$STORY_ID" "$STORY_BEAD_CITY" 2>/dev/null || echo "")
          fi
          if [ -n "$_DOM_CREW_OWNER" ]; then
            log "ga-lfvs6: $STORY_ID is a $_DOMAIN_RIG domain build with a live persistent-crew owner ($_DOM_CREW_OWNER) — honoring it over the dog pool (was target=$BUILDER_TARGET)."
            BUILDER_TARGET="$_DOM_CREW_OWNER"
            STORY_RIG="$_DOMAIN_RIG"
          else
            # (2) route to the domain's persistent crew if mapped AND idle.
            local _DOM_DEFAULT=""
            _DOM_DEFAULT=$(rig_domain_default_builder "$_DOMAIN_RIG" 2>/dev/null || echo "")
            # ga-7ti1t (Mayor re-scope): no rig-wide default — infer one from the
            # bead's creator before falling to hold/escalate. Filling _DOM_DEFAULT
            # (rather than a parallel variable) means the idle/busy check and the
            # routing/hold logic below apply UNCHANGED to an inferred owner too.
            if [ -z "$_DOM_DEFAULT" ] && [ "${PILOT_OWNER_INFER_GUARD:-1}" = "1" ]; then
              _DOM_DEFAULT=$(_pilot_infer_crew_from_owner "$(echo "$STORY" | jq -r '(.created_by // "")' 2>/dev/null || echo "")")
              [ -n "$_DOM_DEFAULT" ] && log "ga-7ti1t: $STORY_ID has no rig-default crew for $_DOMAIN_RIG — inferred owner $_DOM_DEFAULT from creator (created_by). Disable with PILOT_OWNER_INFER_GUARD=0."
            fi
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
              # (3) no idle persistent crew for the domain → DEFER with timed hold.
              # imp20: stamp pilot:held + pilot:held-until:<epoch+3600> instead of just
              # returning 1 (plain defer). Without a timed hold, the bead is queued
              # immediately and Pilot re-dispatches on the next sweep — the claim-but-park
              # loop that required gate:needs-human (which release re-strips) to stop.
              # A 1h hold prevents the re-dispatch loop while the owning crew becomes
              # available; the janitor R6 clears it when expired.
              warn "ga-lfvs6: REFUSING to dispatch $_DOMAIN_RIG domain build $STORY_ID to the ephemeral dog pool ($BUILDER_TARGET) — a dog cannot build a real domain task (no domain data, no rig checkout, no git-diff for the gate). Owning crew ${_DOM_DEFAULT:-none} is ${_DOM_DEFAULT:+busy/unavailable}${_DOM_DEFAULT:-unmapped}. Stamping timed pilot:held (1h) to prevent re-dispatch loop; releasing claim (set PILOT_DOMAIN_ROUTE_GUARD=0 to disable)."
              if [ "$DRY_RUN" != "1" ]; then
                bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
                bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
                local _hold_until; _hold_until=$(( $(date +%s) + 3600 ))
                # imp19: atomicity — stamp pilot:held-until:<epoch> FIRST so that if the
                # process dies between the two label ops the bead is never left as
                # pilot:held-without-until (which _filter_candidates treats as skip-forever).
                # The until label alone is harmless (no skip); pilot:held alone is the trap.
                bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "pilot:held-until:${_hold_until}" -q 2>/dev/null || true
                bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "pilot:held" -q 2>/dev/null || true
                # ga-4aree: purge PRIOR held-until stamps (keep only the just-added one) so they
                # don't accumulate unboundedly. Safe order: the fresh held-until + pilot:held are
                # already present (above), so removing OLD stamps never leaves the
                # pilot:held-without-until trap even if this loop dies partway.
                for _stale in $(bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[] | select(startswith("pilot:held-until:"))' 2>/dev/null); do
                  [ "$_stale" = "pilot:held-until:${_hold_until}" ] || bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "$_stale" -q 2>/dev/null || true
                done
                log "ga-lfvs6/imp20: $STORY_ID stamped pilot:held-until:${_hold_until} then pilot:held (1h timed hold; prior held-until stamps purged — ga-4aree)"
              fi
              # ga-2n7xw: count this hold toward the shared refusal-successor
              # escalation cap — a domain build stuck with no idle crew must
              # eventually reach the Mayor, not hold-and-retry forever.
              _pilot_hold_or_escalate "$STORY_BEAD_CITY" "$STORY_ID" "ga-lfvs6" \
                "$_DOMAIN_RIG domain build with no idle persistent-crew owner (owning crew: ${_DOM_DEFAULT:-unmapped})" \
                "map/free a persistent crew for $_DOMAIN_RIG, or set a live explicit assignee on $STORY_ID" \
                "$(echo "$STORY" | jq -c '.labels // []' 2>/dev/null || echo '[]')"
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
          # ga-2n7xw: this was the WORST of the 3 refusal sites — it used to
          # defer with NO label at all, no trace, no counter. At minimum,
          # stamp the shared counter so a bead stuck here forever eventually
          # escalates to the Mayor instead of vanishing silently.
          _pilot_hold_or_escalate "$STORY_BEAD_CITY" "$STORY_ID" "ga-jazy9" \
            "lane:big story with no live persistent-crew owner — dogs (~25-min TTL) cannot build a big subsystem" \
            "assign a live persistent crew to $STORY_ID, or route it off lane:big" \
            "$(echo "$STORY" | jq -c '.labels // []' 2>/dev/null || echo '[]')"
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

  # ── ga-j0f6: beads-repo fix ⇒ different DOCTRINE (upstream PR, not gate-done) ──
  # Computed once, used by both heredocs below. Normal-path text (both branches
  # below) is byte-identical to the pre-fix hardcoded doctrine — verified by the
  # fact this is a straight copy-out, not a rewrite. IS_BEADS_REPO_FIX (set above,
  # right after STORY_RIG) overrides both variables afterward, only when
  # bead_targets_beads_repo fired. Fail-open: unset/empty ⇒ no behavior change.
  local DOCTRINE_BLOCK DISPATCH_STEP5 YOUR_JOB_LINE
  if [ "$DISPATCH_TIER" = "bug" ]; then
    DOCTRINE_BLOCK="## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your fix is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just fix, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → bead closed.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry."
    YOUR_JOB_LINE='Fix this bug or tech-debt item completely. Do NOT wait for a human.
"Só depois do sistema perfeito é que a gente faz novas features." — system quality first.'
  else
    DOCTRINE_BLOCK="## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your implementation is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just build, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → story:done.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry."
    YOUR_JOB_LINE="Build this story from acceptance criteria to /gate-done. Do NOT wait for a human."
  fi
  DISPATCH_STEP5="5. Commit, push, then run /gate-done."
  if [ -n "$IS_BEADS_REPO_FIX" ]; then
    DOCTRINE_BLOCK="## DOCTRINE — read carefully (beads repo — different from normal doctrine)
- This work lives in the beads CLI's own repo (/Users/athos/gt/beads) — NOT a registered gc rig. /gate-done CANNOT find or merge a branch there. Do not run it.
- Real path: commit in /Users/athos/gt/beads, push to the fork remote, then gh pr create against upstream. Read the upstream org from: git -C /Users/athos/gt/beads remote get-url origin — do not hardcode an org name, it has been renamed before.
- This DOES need human review: the PR awaits upstream-maintainer review/merge. It is NOT autonomous.
- Leave $STORY_ID OPEN. Comment the PR URL on it once opened. Do NOT close the bead — it closes only after the PR merges."
    DISPATCH_STEP5="5. Commit, push to the fork remote, then gh pr create against upstream (see doctrine above for the exact remote command). Comment the PR URL on $STORY_ID. Do NOT run /gate-done. Do NOT close $STORY_ID — it closes only after the PR merges."
    YOUR_JOB_LINE="Fix this completely. This work targets the beads CLI's own repo — see DOCTRINE below for the real path (upstream PR, human review required, NOT /gate-done)."
  fi

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
$YOUR_JOB_LINE
$GATE_FIX_SECTION
$LIVE_VERIFY_SECTION

## Description / Acceptance Criteria
$STORY_CRITERIA

## Additional Context
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

$DOCTRINE_BLOCK
$WORKTREE_DIRECTIVE
## Steps
1. Read the full bead: bd -C "$STORY_BEAD_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Diagnose root cause, implement fix on a branch (name: fix/$STORY_ID).
4. Add a regression test if applicable.
$DISPATCH_STEP5

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
$YOUR_JOB_LINE
$GATE_FIX_SECTION
$LIVE_VERIFY_SECTION

## Acceptance Criteria
$STORY_CRITERIA

## Estrela Guia (north star)
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

$DOCTRINE_BLOCK
$WORKTREE_DIRECTIVE
## Steps
1. Read the full story bead: bd -C "$STORY_BEAD_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Implement the story on a feature branch (name: feat/$STORY_ID or story/$STORY_ID).
4. Add a story-specific prod test at the required path (see delivery-runbooks.toml).
$DISPATCH_STEP5

## Claim your work (do this first)
bd -C "$STORY_BEAD_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$STORY_BEAD_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  fi

  log "  Task prompt built (${#DISPATCH_TASK} chars)"

  # ── pilot-rewire: compute _SLING_TARGET (slot → template mapping) ─────────────
  # wa-worker-N are VIRTUAL POOL SLOTS tracked in PILOT_USED_BUILDERS. The real agent
  # template name is "wa-worker". All dispatch operations (gc sling, bd --assignee, gc
  # session nudge) must use _SLING_TARGET (the template), while BUILDER_TARGET continues
  # tracking the slot identity for per-sweep pool distribution. For non-wa-worker identities
  # _SLING_TARGET == BUILDER_TARGET (unchanged). Computed here, before the reuse block,
  # so it is available for session classification and all dispatch paths below.
  local _SLING_TARGET
  _SLING_TARGET=$(wa_worker_template "$BUILDER_TARGET")

  # ── gt-4st3n: classify the builder's existing session → REUSE vs SPAWN ────────
  # Decide BEFORE dispatch whether the target already has a session we must reuse
  # rather than spawn a second one alongside. gastown.dog and wa-worker* are ephemeral
  # pools (multiple instances by design, or short-lived) → always spawn. Any non-dog,
  # non-ephemeral crew identity with a live session → reuse it (hook + non-interrupting
  # follow_up submit); asleep → wake the existing session first; none → legacy spawn.
  # Read-only classification, so it runs in dry-run too (actions below are DRY_RUN gated).
  # Fail-open: classification errors leave _DISPATCH_REUSE=0 → legacy spawn path.
  local _DISPATCH_REUSE=0 _DISPATCH_SESS_STATE="none" _DISPATCH_SESS_REF=""
  local _skip_reuse=0
  case "$BUILDER_TARGET" in gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*) _skip_reuse=1 ;; esac
  if [ "${PILOT_REUSE_SESSION:-1}" = "1" ] && [ "$_skip_reuse" = "0" ]; then
    local _sess_line
    _sess_line=$(_target_session_state "$_SLING_TARGET" 2>/dev/null || echo "none")
    _DISPATCH_SESS_STATE="${_sess_line%% *}"
    case "$_DISPATCH_SESS_STATE" in
      active|asleep)
        _DISPATCH_REUSE=1
        _DISPATCH_SESS_REF="${_sess_line#* }"
        [ "$_DISPATCH_SESS_REF" = "$_sess_line" ] && _DISPATCH_SESS_REF="$_SLING_TARGET"
        log "  REUSE(gt-4st3n): $_SLING_TARGET has an existing $_DISPATCH_SESS_STATE session ($_DISPATCH_SESS_REF) — will hook + non-interrupting follow_up, NOT spawn a 2nd session." ;;
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

  # ── ga-88g2: pre-dispatch freshness re-check (candidate-to-dispatch TOCTOU) ───
  # The ga-zzrts verify above (~L3316) re-fetches immediately after the atomic
  # claim, but everything since — ga-htjni ownership guard, ga-cnvy1 dedup guard,
  # domain routing, pool-builder selection, session classification — runs several
  # more bd/gc calls deep and can take real wall-clock time. A bead that flips to
  # a terminal/escalated state DURING that window (e.g. inflight-reclaim-guard's
  # do_escalate() landing gate:needs-human + retained story:in-flight once the
  # MAX_RECLAIMS cap is hit) is never re-checked, so Pilot still dispatches
  # against a stale snapshot. Confirmed via ga-w5agg's 9th dispatch: dog-gab3fg
  # observed gate:needs-human + gate:needs-human:technical + retained
  # story:in-flight already present at 2026-07-02T17:22:11Z, yet Pilot posted a
  # dispatch comment for the SAME bead at 2026-07-02T17:26:24Z — 4+ minutes
  # later, well after the escalation was durable. Re-fetch ONE more time here,
  # immediately before the first externally-visible dispatch action (sling / bd
  # assign / session wake / nudge), so the circuit breaker can't be raced by
  # builder-target-resolution latency. This is the SAME class of fix as
  # ga-sndpm's late re-verification below (~L4005) — that one re-checks
  # ownership right before the wa-worker/ps-worker pool write; this one
  # re-checks the escalation labels right before ANY dispatch path (sling,
  # rig-native, or pool). FAIL-OPEN by construction: an unreadable re-check
  # never blocks a real dispatch.
  if [ "$DRY_RUN" != "1" ]; then
    local _PREDISPATCH_JSON _PREDISPATCH_LABELS
    _PREDISPATCH_JSON=$(bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null || echo "[]")
    _PREDISPATCH_LABELS=$(echo "$_PREDISPATCH_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' \
      2>/dev/null || echo "")
    if echo "$_PREDISPATCH_LABELS" | grep -q "gate:needs-human"; then
      warn "ga-88g2: $STORY_ID now has gate:needs-human (escalated during builder-target resolution, after the ga-zzrts claim-verify passed clean). Releasing claim and skipping — NOT dispatching a builder onto a circuit-broken bead."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      return 1
    fi
    if echo "$_PREDISPATCH_LABELS" | grep -q "story:in-flight"; then
      warn "ga-88g2: $STORY_ID now has story:in-flight (raced by a concurrent dispatch/reclaim during builder-target resolution). Releasing claim and skipping."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      return 1
    fi
    if echo "$_PREDISPATCH_LABELS" | grep -q "story:done"; then
      warn "ga-88g2: $STORY_ID now has story:done (completed during builder-target resolution). Releasing claim and skipping."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      return 1
    fi
    if echo "$_PREDISPATCH_LABELS" | grep -q "pilot:dispatched"; then
      warn "ga-88g2: $STORY_ID now has pilot:dispatched (dispatched via another path during builder-target resolution). Releasing claim and skipping."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      return 1
    fi

    # ── ga-pd7j: Mayor out-of-band hold grace window ─────────────────────────
    # Same TOCTOU class as the checks above, for a signal that ISN'T a label yet:
    # the Mayor can post a hold-disposition comment on a gate:needs-fix bead in
    # the same window this function is resolving the builder target (ga-z6uo/
    # ga-06um: dispatch fired 16:30:34Z, Mayor's comment landed 16:32:16Z, still
    # no pilot:held label). Only relevant for gate:needs-fix — that is the
    # label Pilot auto-redispatches without waiting for a human/Mayor beat.
    # Fail-open: an unreadable/empty comments fetch never blocks a real dispatch.
    if echo "$_PREDISPATCH_LABELS" | grep -q "gate:needs-fix"; then
      local _mayor_hold_active _predispatch_now
      _predispatch_now=$(date +%s)
      _mayor_hold_active=$(bd -C "$STORY_BEAD_CITY" comments "$STORY_ID" --json 2>/dev/null | jq -r \
        --argjson now "$_predispatch_now" --argjson grace "${PILOT_MAYOR_HOLD_GRACE_SECS:-300}" \
        'if type == "array" then . else [] end
         | any(.[]; .author == "gastown__mayor"
               and ((try (.created_at | fromdateiso8601) catch 0) > ($now - $grace)))' \
        2>/dev/null || echo "false")
      if [ "$_mayor_hold_active" = "true" ]; then
        warn "ga-pd7j: $STORY_ID is gate:needs-fix with a gastown__mayor comment inside the ${PILOT_MAYOR_HOLD_GRACE_SECS:-300}s grace window — deferring this sweep so an out-of-band hold isn't raced onto a builder. Releasing claim and skipping."
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
        bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
        return 1
      fi
    fi
  fi

  # ── Dispatch via gc sling (HQ beads) or bd assign (rig-native beads) ─────────
  local DISPATCH_EPOCH DISPATCH_RESULT SLING_BEAD_ID NOW
  DISPATCH_EPOCH=$(date +%s)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$DRY_RUN" = "1" ]; then
    local SLING_TITLE_DRY
    SLING_TITLE_DRY="$([ "$DISPATCH_TIER" = "bug" ] && echo "fix bug" || echo "build story") $STORY_ID: $STORY_TITLE"
    log "DRY_RUN=1 — WOULD DISPATCH (tier=$DISPATCH_TIER lane=$LANE rig_native=$_IS_RIG_NATIVE):"
    if [ "$_IS_RIG_NATIVE" = "1" ]; then
      log "  RIG-NATIVE path (ga-mfeip): bd -C $STORY_BEAD_CITY update $STORY_ID --assignee $_SLING_TARGET (slot=$BUILDER_TARGET)"
      case "$_SLING_TARGET" in
        wa-worker*) log "  WOULD: gc --city $GC_CITY session new wa-worker --no-attach --title-hint 'build $STORY_ID: ...' (pilot-spawn: ephemeral worker, not nudge)" ;;
        ps-worker*) log "  WOULD: gc --city $GC_CITY session new ps-worker --no-attach --title-hint 'build $STORY_ID: ...' (pilot-spawn: ephemeral worker, not nudge)" ;;
        *)          log "  WOULD: gc --city $GC_CITY session nudge $_SLING_TARGET <task_prompt>" ;;
      esac
    elif [ "$_DISPATCH_REUSE" = "1" ]; then
      [ "$_DISPATCH_SESS_STATE" = "asleep" ] \
        && log "  WOULD: gc session wake $_DISPATCH_SESS_REF (reuse existing asleep session — gt-4st3n)"
      log "  gc --city $GC_CITY sling $_SLING_TARGET <task_bead>   (reuse: routes to existing $_DISPATCH_SESS_STATE session, no spawn)"
      log "  WOULD: gc session submit $_DISPATCH_SESS_REF <task> --intent follow_up   (non-interrupting hook+nudge — gt-4st3n)"
    else
      log "  gc --city $GC_CITY sling $_SLING_TARGET <task_bead> --nudge   (spawn: no existing session)"
    fi
    log "  Task title: '$SLING_TITLE_DRY'"
    log "  Rig: $STORY_RIG → builder: $_SLING_TARGET (slot=$BUILDER_TARGET)"
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
    # _SLING_TARGET is already computed above (before the reuse block).
    # For wa-worker-N slots, _SLING_TARGET = "wa-worker"; for others, = BUILDER_TARGET.
    log "  RIG-NATIVE dispatch (ga-mfeip): assigning $STORY_ID → $_SLING_TARGET (slot=$BUILDER_TARGET) in $STORY_BEAD_CITY"
    # ── ga-mfeip gate (f): dedup — never put two crews on one bead ─────────────
    # The candidate snapshot was taken at the top of the sweep; a sibling claim may have
    # assigned this bead since. Re-read its CURRENT assignee straight from the rig DB.
    # A DIFFERENT crew already owns it ⇒ abort and release our claim (the wa-6m6h
    # two-crew regression). null/own assignee ⇒ proceed. Fail-open: a failed re-read
    # yields empty → we proceed (never block a dispatch on a probe error).
    _cur_asg=$(timeout 10 bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | .assignee // ""' 2>/dev/null || echo "")
    if [ -n "$_cur_asg" ] && [ "$_cur_asg" != "$_SLING_TARGET" ]; then
      warn "ga-mfeip gate-f: $STORY_ID already assigned to $_cur_asg — skipping dispatch to $_SLING_TARGET (dedup)."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
      DISPATCH_RESULT="rig_dedup_skip"
      return 1
    fi
    # ga-dbibq: POOL targets (wa-worker*) vs NAMED CREWS need DIFFERENT ownership.
    #   • Pool (wa-worker*): leave the bead UNASSIGNED + open. The ephemeral worker finds it
    #     via RoutedPoolQuery (`bd ready --metadata-field gc.routed_to=wa-worker --unassigned`,
    #     routed_to set in the spawn block below) and CLAIMS it (assignee = its session id).
    #     The prior ga-v3o6i code assigned the bead to the bare TEMPLATE name "wa-worker"
    #     + in_progress, on the WRONG assumption that the worker queries `--assignee=wa-worker`.
    #     It actually queries --assignee=$GC_SESSION_ID/NAME/ALIAS (never the template) AND the
    #     routed-pool query requires --unassigned → an assigned+in_progress bead was invisible
    #     to BOTH → the worker spawned, found nothing, drained WITHOUT building (the exact stall;
    #     confirmed via worker transcript 2026-06-27). story:in-flight (added post-dispatch) still
    #     blocks Pilot re-selection; NEVERSTARTED still releases it if no worker ever claims.
    #   • Named crew (mila-wa, oracle-wa, …): assign directly — their GC_ALIAS == the crew name,
    #     so --assignee=<crew> matches the crew session's identity (unchanged behaviour).
    case "$_SLING_TARGET" in
      wa-worker*|ps-worker*)
        # ── ga-sndpm: re-verify ownership guard before routing to the pool ──────
        # The ga-htjni guard (~L3392) ran ONCE, early in this dispatch_one() call —
        # BEFORE the pool-distribution/crew-availability logic above, which runs
        # several bd/gc calls deep and can take real wall-clock time. RoutedPoolQuery
        # (`bd ready --metadata-field gc.routed_to=$target --unassigned`) is later
        # self-claimed by a SEPARATE worker/dog session that has NO ownership-guard
        # logic of its own — it just grabs the first unassigned+routed bead it finds.
        # If a crew branch or an active gate marker appears for STORY_ID in the
        # window since the early check — a parallel dispatch, or the actual incident
        # pattern (wa-ya17c, wa-1tb9b 2x, wa-6j2b6): a stale gc.routed_to=wa-worker
        # surviving from a PRIOR pool attempt while the bead is mid gate-handoff
        # (momentarily open+unassigned with its gate-run ACTIVE) — stamping
        # gc.routed_to here hands a live pool worker a bead someone already owns.
        # Re-run the SAME fail-open guard (signals a/b/c/d; a=branch and
        # d=active-gate-marker are the ones that actually fired in the reported
        # incidents) right before the write, so the check can never be tens-of-
        # seconds stale. Same kill switch as the main guard: PILOT_OWNERSHIP_GUARD=0
        # disables both.
        if [ "${PILOT_OWNERSHIP_GUARD:-1}" = "1" ]; then
          local _RP_OWN_REASON
          _RP_OWN_REASON=$(_ownership_guard_should_refuse "$STORY_ID" "$STORY" "$STORY_BEAD_CITY" || echo "")
          if [ -n "$_RP_OWN_REASON" ]; then
            OWNERSHIP_GUARD_VETO_COUNT=$((OWNERSHIP_GUARD_VETO_COUNT + 1))   # ga-8jxe1 AC4
            warn "ga-sndpm: REFUSING routed-pool dispatch of $STORY_ID to $_SLING_TARGET — already owned/in-flight ($_RP_OWN_REASON). NOT stamping gc.routed_to (would let the pool self-claim collide with active crew work). Releasing claim (set PILOT_OWNERSHIP_GUARD=0 to disable)."
            bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
            bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
            DISPATCH_RESULT="pool_ownership_refuse"
            return 1
          fi
        fi
        : # pool: leave UNASSIGNED + open so RoutedPoolQuery finds it (claim happens worker-side)
        ;;
      *)
        if ! timeout 15 bd -C "$STORY_BEAD_CITY" update "$STORY_ID" \
            --assignee "$_SLING_TARGET" --status in_progress -q 2>/dev/null; then
          warn "ga-mfeip: bd update --assignee failed for $STORY_ID → $_SLING_TARGET. Releasing claim."
          bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
          bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
          DISPATCH_RESULT="rig_assign_failed"
          return 1
        fi
        ;;
    esac
    # Record the rig bead itself as the "sling bead" for TTL compatibility.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.sling_bead=$STORY_ID" -q 2>/dev/null || true
    SLING_BEAD_ID="$STORY_ID"
    DISPATCH_RESULT="rig_native_ok"
    # ── pilot-spawn: ephemeral pool worker vs persistent crew ──────────────────
    # wa-worker has min_active_sessions=0 and wake_mode=fresh — there is NO running
    # session to nudge and NO hook cycle to "see it next time". Spawn a fresh headless
    # session; it starts immediately, runs its startup protocol (prompt.template.md),
    # and finds the bead via RoutedPoolQuery (gc.routed_to=wa-worker, set below;
    # bead is UNASSIGNED per ga-dbibq fix — worker self-claims on first find).
    # Named crew (mila-wa, oracle-wa, …) remain on the nudge path: they have persistent
    # sessions with a running hook cycle. Set PILOT_SPAWN_WA_WORKER=0 to disable spawning
    # and revert to nudge-only (for debugging; bead stays unassigned+routed until manual start).
    case "$_SLING_TARGET" in
      wa-worker*)
        # Set gc.routed_to so RoutedPoolQuery finds the unassigned bead AND the supervisor
        # scale_check counts it as pool demand (capped at max_active_sessions=4).
        bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "gc.routed_to=wa-worker" -q 2>/dev/null || true
        if [ "${PILOT_SPAWN_WA_WORKER:-1}" = "1" ]; then
          # ── ga-v3o6i: max-cap guard — count live sessions before spawning ──────
          # Each sweep dispatches a bead then spawns a session. Without a cap check,
          # rapid re-sweeps (or slow session startup) spawn N sessions for M beads
          # where N >> M (the prior 39-session runaway). Count active + creating
          # sessions; skip the spawn if at cap (gc.routed_to=wa-worker set —
          # the supervisor picks it up on its next scale_check tick). Fail-open on probe error.
          if [ -n "${PILOT_TEST_WA_WORKER_LIVE_COUNT:-}" ]; then
            _live_wa_count="$PILOT_TEST_WA_WORKER_LIVE_COUNT"
          else
            _live_wa_count=$(timeout 10 gc --city "$GC_CITY" session list --json 2>/dev/null \
              | jq '[.sessions[]? | select(.template=="wa-worker" and (.state=="active" or .state=="creating"))] | length' 2>/dev/null || echo "0")
          fi
          _live_wa_count="${_live_wa_count:-0}"
          if [ "${_live_wa_count:-0}" -ge "${PILOT_WA_WORKER_MAX:-4}" ] 2>/dev/null; then
            log "  ga-mfeip: wa-worker pool at session cap ($_live_wa_count active/creating >= ${PILOT_WA_WORKER_MAX:-4} max) — skip spawn for $STORY_ID (gc.routed_to=wa-worker set; supervisor picks it up when slot frees)"
          else
            log "  ga-mfeip: spawning wa-worker for $STORY_ID (slot=$BUILDER_TARGET, live=$_live_wa_count < ${PILOT_WA_WORKER_MAX:-4})."
            # spawn timeout raised 30→60 (env PILOT_SPAWN_TIMEOUT_SECS): under a HOT Dolt
            # (~300% CPU) `gc session new` routinely took >30s → 157 "Could not spawn" in one
            # session → routed beads starved waiting for the supervisor fallback (2026-06-30).
            if timeout "${PILOT_SPAWN_TIMEOUT_SECS:-60}" gc --city "$GC_CITY" session new wa-worker --no-attach \
                --title-hint "build $STORY_ID: $STORY_TITLE" \
                >/dev/null 2>&1; then
              log "  ga-mfeip: wa-worker session spawned for $STORY_ID (slot=$BUILDER_TARGET)."
            else
              warn "ga-mfeip: Could not spawn wa-worker for $STORY_ID — gc.routed_to=wa-worker set; supervisor reconcile will pick it up"
            fi
          fi
        else
          log "  ga-mfeip: PILOT_SPAWN_WA_WORKER=0 — skipping auto-spawn for $STORY_ID (gc.routed_to=wa-worker set; bead unassigned until worker claims)"
        fi
        ;;
      ps-worker*)
        # Set gc.routed_to so RoutedPoolQuery finds the unassigned bead AND the supervisor
        # scale_check counts it as pool demand (capped at max_active_sessions=2).
        bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "gc.routed_to=ps-worker" -q 2>/dev/null || true
        if [ "${PILOT_SPAWN_PS_WORKER:-1}" = "1" ]; then
          if [ -n "${PILOT_TEST_PS_WORKER_LIVE_COUNT:-}" ]; then
            _live_ps_count="$PILOT_TEST_PS_WORKER_LIVE_COUNT"
          else
            _live_ps_count=$(timeout 10 gc --city "$GC_CITY" session list --json 2>/dev/null \
              | jq '[.sessions[]? | select(.template=="ps-worker" and (.state=="active" or .state=="creating"))] | length' 2>/dev/null || echo "0")
          fi
          _live_ps_count="${_live_ps_count:-0}"
          if [ "${_live_ps_count:-0}" -ge "${PILOT_PS_WORKER_MAX:-2}" ] 2>/dev/null; then
            log "  ga-mfeip: ps-worker pool at session cap ($_live_ps_count active/creating >= ${PILOT_PS_WORKER_MAX:-2} max) — skip spawn for $STORY_ID (gc.routed_to=ps-worker set; supervisor picks it up when slot frees)"
          else
            log "  ga-mfeip: spawning ps-worker for $STORY_ID (live=$_live_ps_count < ${PILOT_PS_WORKER_MAX:-2})."
            if timeout "${PILOT_SPAWN_TIMEOUT_SECS:-60}" gc --city "$GC_CITY" session new ps-worker --no-attach \
                --title-hint "build $STORY_ID: $STORY_TITLE" \
                >/dev/null 2>&1; then
              log "  ga-mfeip: ps-worker session spawned for $STORY_ID."
            else
              warn "ga-mfeip: Could not spawn ps-worker for $STORY_ID — gc.routed_to=ps-worker set; supervisor reconcile will pick it up"
            fi
          fi
        else
          log "  ga-mfeip: PILOT_SPAWN_PS_WORKER=0 — skipping auto-spawn for $STORY_ID (gc.routed_to=ps-worker set; bead unassigned until worker claims)"
        fi
        ;;
      *)
        log "  ga-mfeip: rig assign OK — $STORY_ID.assignee=$_SLING_TARGET (slot=$BUILDER_TARGET). Nudging crew."
        timeout 15 gc --city "$GC_CITY" session nudge "$_SLING_TARGET" "$DISPATCH_TASK" \
          2>/dev/null \
          || warn "ga-mfeip: Could not nudge $_SLING_TARGET — crew will see $STORY_ID on next hook cycle"
        ;;
    esac
    log "Dispatch complete (rig-native): bead=$STORY_ID target=$_SLING_TARGET slot=$BUILDER_TARGET (ga-mfeip)"
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
      # ga-e2n96 AC3: pass the full dispatch prompt via --stdin (first line =
      # title, rest = description) instead of a bare title argument, so the
      # DURABLE sling bead itself carries real content. Before this fix the
      # created bead's Description was unconditionally "" — the rich prompt
      # only ever reached the builder via the one-shot ephemeral nudge/submit
      # below, so a scrolled/missed terminal message left `bd show` on the
      # bead with nothing to go on.
      SLING_OUT=$(printf '%s\n%s\n' "$SLING_TITLE" "$DISPATCH_TASK" \
        | gc --city "$GC_CITY" sling "$_SLING_TARGET" \
        --stdin \
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
      timeout 15 gc --city "$GC_CITY" session nudge "$_SLING_TARGET" "$DISPATCH_TASK" \
        2>/dev/null \
        || warn "Could not nudge $_SLING_TARGET — builder will see the task bead on next hook cycle"
    fi

    log "Dispatch complete: sling_bead=$SLING_BEAD_ID target=$_SLING_TARGET slot=$BUILDER_TARGET reuse=${_DISPATCH_REUSE} session_state=${_DISPATCH_SESS_STATE}"
  fi

  # ── Transition bead: DURABLE lane tag + DURABLE story:in-flight (ga-2azzj fix 1,
  #    lane durability ga-05604.2) ────────────────────────────────────────────
  # ORDER IS LOAD-BEARING. The candidate queries EXCLUDE story:in-flight; that
  # label is the ONLY thing that makes a slung bead non-re-dispatchable. So:
  #   1. lane tag — retry + VERIFY (read-after-write), same treatment as
  #      story:in-flight below (ga-05604.2). Unlike in-flight, an unconfirmed
  #      lane write does NOT abort the dispatch on exhaustion — only WARN (see
  #      below) — because the builder may already be slung and a late-aborted
  #      dispatch is worse (ga-2azzj).
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
    # ga-05604.2: lane tag write used to be a single fire-and-forget
    # `label add ... || true` — no retry, no verification — while the
    # story:in-flight write 5 lines below it already had both. A transient
    # Dolt blip landing exactly in this window silently dropped the lane
    # write while story:in-flight (which retries) typically survived the
    # same blip, leaving the bead durably story:in-flight with NO lane:*
    # label — misread downstream as an "unclassified" residual
    # (ga-wtqli/ga-05604.1) even though classify_lane() never actually
    # returned empty; the WRITE just lost the race. This loop gives the
    # lane write the SAME retry+verify treatment as story:in-flight. On
    # exhaustion it only WARNs (does not abort/return 1) — the
    # unclassified_lane residual (ga-wtqli) already surfaces the bead for
    # observability when this genuinely happens; this fix just narrows the
    # failure window instead of reinventing that observability path.
    local _lane_ok=0 _lane_i=1
    local _lane_retries="${PILOT_INFLIGHT_RETRIES:-5}"
    local _lane_sleep="${PILOT_INFLIGHT_SLEEP:-2}"
    while [ "$_lane_i" -le "$_lane_retries" ]; do
      bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "lane:${LANE}" -q 2>/dev/null || true
      if bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null \
          | jq -e --arg lane "lane:${LANE}" 'if type=="array" then .[0] else . end | (.labels // []) | any(. == $lane)' \
          >/dev/null 2>&1; then
        _lane_ok=1; break
      fi
      [ "$_lane_i" -lt "$_lane_retries" ] && sleep "$_lane_sleep"
      _lane_i=$((_lane_i + 1))
    done
    if [ "$_lane_ok" = "0" ]; then
      warn "LANE WRITE UNCONFIRMED on $STORY_ID after ${_lane_retries} attempts (Dolt down?). NOT aborting dispatch — builder '$BUILDER_TARGET' already slung or about to be (bead=$SLING_BEAD_ID). Bead will surface via the unclassified_lane residual (ga-wtqli) until relabeled."
    fi

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

    # ga-ms1jm: strip gc.routed_to from non-rig-native source beads only.
    # For the sling path (_IS_RIG_NATIVE=0), the source bead lives in HQ — the
    # same DB that dog-pool queries via `bd ready --metadata-field gc.routed_to=...
    # --unassigned` (which does NOT exclude story:in-flight). Leaving gc.routed_to
    # on a HQ source bead would allow dog re-claiming → double-dispatch.
    # For rig-native wa-worker beads (_IS_RIG_NATIVE=1): the source bead lives in
    # the WA rig's own Dolt DB, which dog-pool never queries — no re-claim risk.
    # Moreover, gc.routed_to=wa-worker MUST survive here so: (a) the spawned
    # worker's RoutedPoolQuery finds the unassigned bead (ga-dbibq fix), and (b)
    # the supervisor's scale_check counts live demand for spawn gating.
    if [ "${_IS_RIG_NATIVE:-0}" != "1" ]; then
      bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata gc.routed_to -q >/dev/null 2>&1 || true
    fi

    local DISPATCH_COMMENT
    if [ -n "$IS_BEADS_REPO_FIX" ]; then
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=$DISPATCH_TIER, lane=$LANE, rig=$STORY_RIG, target=beads-repo).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: commit → push to fork → gh pr create against upstream beads repo.
beads is NOT a registered gc rig — /gate-done cannot find this branch, do not run it.
PR awaits HUMAN REVIEW (upstream maintainer). Bead stays OPEN until the PR merges."
    elif [ "$DISPATCH_TIER" = "bug" ]; then
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
    # ga-opyus: force digest/infra — orchestration is the Mayor's radar, not Athos's.
    # Plain allowlist routing isn't enough: $STORY_TITLE is free text the Pilot doesn't
    # control, and can accidentally match a push-trigger keyword (e.g. "needs-human").
    NOTIFY_FORCE_DIGEST=1 notify -t "✨ Pilot pegou uma história" -p 3 \
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
OWNERSHIP_GUARD_VETO_COUNT=0   # ga-8jxe1 AC4 — see the two increment sites in dispatch_one()

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
        if [ "$DOLT_SAT_REASON" = "unreadable" ]; then
          warn "Dolt health UNREADABLE mid-sweep (cpu=$(_dolt_cpu)% lat=${DOLT_LATENCY_MS:-?}ms — probe returned no signal, NOT a measured value) — stopping $lane loop after ${filled} dispatch(es), same fail-safe as genuine saturation (ga-hzt7; ga-rk5va backoff)."
        else
          warn "Dolt saturated mid-sweep (cpu=$(_dolt_cpu)% lat=${DOLT_LATENCY_MS:-?}ms) — stopping $lane loop after ${filled} dispatch(es) (ga-rk5va backoff)."
        fi
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

# ── Step 4b: Fallback — scan rigs if HQ pool was non-empty but dispatched=0
# this sweep (ga-y1m40) ───────────────────────────────────────────────────────
# Step 2c (above) only fires when the merged pool was EMPTY. A non-empty pool
# that is 100% undispatchable this sweep (e.g. every candidate vetoed by the
# ownership guard) still leaves Step 2c permanently skipped — DISPATCHED==0
# here means BOTH lane loops exhausted their ENTIRE original pool without one
# success, so retrying the SAME HQ candidates would fail identically; only a
# rig scan can find NEW work. Skip when Step 2c already ran this sweep (same
# rigs, already tried and found equally undispatchable — re-scanning would
# just repeat the same failed picks, not fix anything) or when DISPATCHED!=0
# (HQ got at least one success this sweep — HQ keeps precedence, no rig scan).
# Because DISPATCHED==0 implies neither lane consumed a slot, SMALL_SLOTS/
# BIG_SLOTS (computed once in Step 1) are still the FULL free capacity here.
if [ "$DISPATCHED" -eq "0" ] && [ -z "$STEP2C_RAN" ] && { [ "$SMALL_SLOTS" -gt "0" ] || [ "$BIG_SLOTS" -gt "0" ]; }; then
  log "ga-y1m40: HQ pool had candidate(s) but dispatched=0 this sweep (all vetoed/skipped?) — scanning rig DBs as fallback ..."
  _scan_rig_fallback_pool
  if [ "$RIG_MERGED_COUNT" -gt "0" ]; then
    log "ga-y1m40: Rig DBs: $RIG_MERGED_COUNT merged candidate(s) (bug/debt=$RIG_TIER1_COUNT, feature=$RIG_TIER2_COUNT) — retrying lanes with rig pool."
    _split_candidates_by_lane "$RIG_MERGED_JSON"
    if [ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ]; then
      dispatch_lane "small" "$SMALL_CANDIDATES" "$SMALL_SLOTS"
    fi
    if [ "$BIG_SLOTS" -gt "0" ] && [ "$BIG_COUNT" -gt "0" ]; then
      dispatch_lane "big" "$BIG_CANDIDATES" "$BIG_SLOTS"
    fi
  else
    log "ga-y1m40: rig DB fallback scan found no additional candidates."
  fi
fi

if [ "$OWNERSHIP_GUARD_VETO_COUNT" -gt "0" ] 2>/dev/null; then
  # ga-8jxe1 AC4 — the log excerpt that made this bug hard to diagnose was
  # exactly "Lane small: dispatched 0 this sweep (cap=5, slots_left=5)" with NO
  # indication the ownership guard vetoed every candidate. This line answers
  # "how many" in one grep instead of a code read.
  log "ga-8jxe1: ownership-guard vetoed ${OWNERSHIP_GUARD_VETO_COUNT} candidate(s) this sweep."
fi

if [ "$DISPATCHED" -eq "0" ]; then
  log "No dispatches this sweep (lane slots may have been won by a concurrent process, or all picks skipped)."
fi

# ── Step 5: Stall observability (ga-y1m40) ────────────────────────────────────
# No alarm existed for "lane(s) had free slots and nothing dispatched, sweep
# after sweep" — the exact shape of the 4h-invisible outage this bug fixes
# (measured 2026-07-31 03:50-07:50; a human noticed, not an alarm). A single
# sweep with dispatched=0 is routine (genuinely no work this sweep); only a
# STREAK across consecutive sweeps is the signal. pilot-dispatcher.sh is not a
# long-lived daemon — launchd spawns a fresh process every 300s (its plist) —
# so the streak must be file-persisted, not an in-process variable. State
# lives under $GC_CITY/.gc/ so PILOT_CITY_OVERRIDE redirects it into the
# selftest fixture exactly like LOG/PILOT_LOG already do (hermetic, no new
# test seam needed). Gated on DRY_RUN (mirrors every other mutation in this
# file — "makes zero state changes").
PILOT_STALL_STATE="$GC_CITY/.gc/pilot-dispatcher-stall.count"
PILOT_STALL_ALERT_CAP="${PILOT_STALL_ALERT_CAP:-3}"
if [ "$DRY_RUN" != "1" ] && [ "$DISPATCHED" -eq "0" ] && { [ "$SMALL_SLOTS" -gt "0" ] || [ "$BIG_SLOTS" -gt "0" ]; }; then
  _stall_count=0
  [ -f "$PILOT_STALL_STATE" ] && _stall_count=$(cat "$PILOT_STALL_STATE" 2>/dev/null || echo "0")
  case "$_stall_count" in ''|*[!0-9]*) _stall_count=0 ;; esac
  _stall_count=$((_stall_count + 1))
  echo "$_stall_count" > "$PILOT_STALL_STATE" 2>/dev/null || true
  warn "ga-y1m40: dispatched=0 with free slots (small=$SMALL_SLOTS big=$BIG_SLOTS) — ${_stall_count} consecutive sweep(s)."
  if [ $((_stall_count % PILOT_STALL_ALERT_CAP)) -eq 0 ]; then
    notify -t "⚠️ Pilot estagnado" -p 4 "Pilot: ${_stall_count} varreduras consecutivas com vaga livre e 0 despachos (ga-y1m40). Ver pilot-dispatcher.log." || true
  fi
elif [ "$DRY_RUN" != "1" ] && [ -f "$PILOT_STALL_STATE" ]; then
  rm -f "$PILOT_STALL_STATE" 2>/dev/null || true
fi

log "=== Pilot sweep complete: dispatched=$DISPATCHED (small_slots=$SMALL_SLOTS big_slots=$BIG_SLOTS dolt_saturated_at_start=${PILOT_DOLT_SATURATED_AT_START:-0}) ==="
