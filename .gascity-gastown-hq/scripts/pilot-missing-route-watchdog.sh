#!/usr/bin/env bash
# pilot-missing-route-watchdog.sh — detects beads that are ARMED (carry both
# ctx:ready AND exec:auto) and OPEN, but carry NO gc.routed_to metadata, for
# longer than a configurable grace period. Attempts to SELF-HEAL each one
# (ga-9tgos) before falling back to alert-only — see "WHY AUTO-REPAIR IS NOW
# SAFE" below.
#
# WHY THIS EXISTS (ga-f54ui): a bead only becomes visible to a pool worker's
# own self-serve discovery (`bd ready --metadata-field gc.routed_to=<target>
# --unassigned`, the same shape every dog/wa-worker/ps-worker Step-1c probe
# uses) once gc.routed_to is set — normally stamped by pilot-dispatcher.sh
# itself as part of dispatching. If that field is missing (dispatch step
# skipped/failed) or gets CLEARED later without being restored (reclaim,
# manual re-arm, and circuit-break all appear to return a bead to the ready
# queue without re-stamping the route — ga-f54ui's own "investigate why"
# note), the bead can carry ctx:ready+exec:auto — looking READY in the panel
# and in any plain `bd list` — and never be picked up by anything, forever.
# Not slow, not lane-saturated: invisible, the same
# root-class:armed-but-unreachable shape as ga-5jyo8's
# root-class:unreachable-by-construction, just on the metadata side of
# dispatch instead of the label side of gate review.
#
# Real incidents (Mayor, 2026-08-06, two separate sweeps same day, ALL with
# real unmerged work — branch existed, 1-3 commits ahead of main): ga-o9uvc
# (armed, no-route, plus a 13-day-stale pilot.dispatched_at compounding the
# invisibility — the Pilot read "already dispatched" and skipped, two
# blockers stacked), ga-yp9r8, wa-vcd01 (crew/peter/wa-vcd01-v5, fix-attempt
# 3/3 — its LAST attempt before circuit-break), wa-6cx36 (9.5 days),
# wa-444cn, wa-nh37r (26h), wa-ys0cy (13.4 days), wa-ge50x (10.6 days). Lane
# capacity was NOT the limit in either sweep (lane:small had headroom both
# times) — this is pure invisibility, not queue pressure. Causally confirmed,
# not theory: manually setting gc.routed_to on ga-o9uvc and wa-pqsar got both
# picked up within minutes.
#
# SCOPE — MULTI-STORE, unlike ga-5jyo8's gate-marker-missing-status-watchdog
# (GMMSW): gate markers/runs are only ever created in the HQ store, but armed
# beads missing their route span every rig (the incident list above mixes
# ga-* HQ beads and wa-* whatsapp_automation beads). This script sweeps the
# same PMRW_STORES set gate-orphaned-label-watchdog.sh (GOLW) uses — static,
# env-overridable, not a live `gc rig list` call every cycle (that call runs
# 8-17s under Dolt load, not worth paying every sweep for a set that changes
# rarely; override PMRW_STORES if a rig is added).
#
# QUERY (ga-f54ui's own prescription: "a consulta e o complemento da do
# Pilot — nao replique o filtro dele, INVERTA-O" — same instruction GMMSW
# followed for the gate side). This does NOT attempt to replicate
# pilot-dispatcher.sh's full _filter_candidates chain (7000+ lines, session-
# liveness-roster-dependent in places) — that answers "should this be
# dispatched at all", a much bigger question than this watchdog needs. It
# mirrors only the CHEAP, purely label/metadata exclusions that mean "this
# bead is intentionally not routed for a DIFFERENT, already-understood
# reason" (so this watchdog doesn't cry wolf on those), confirmed by reading
# _filter_candidates directly (packs/town-deltas/assets/pilot-dispatcher.sh):
#   - issue_type == epic                                   → excluded
#   - gate:needs-human* (startswith, catches the -decision  → excluded
#     sub-variant too, mirroring _filter_candidates exactly)
#   - pilot:held WITHOUT an expired pilot:held-until:<epoch> → excluded
#     (ga-4aree semantics reproduced exactly: labels accumulate, so this
#     uses the MAX held-until, not the first one found)
#   - a graph.v2 formula step or root (gc.root_bead_id or                 → excluded
#     gc.formula_contract set, or gc.kind in the workflow-ish set) — these
#     are already serviced by a DIFFERENT dispatch mechanism entirely (see
#     .gc/system/packs/core/assets/prompts/graph-worker.md); a route gap
#     there is a different bug, not this one
#   - a Pilot-created sling/dispatch-wrapper bead                        → excluded
#     (metadata pilot.sling_for set — ga-nimyz) — not real work
#
# FIVE MORE exclusions, added after the FIRST live dry-run against the real
# HQ + rig stores flagged 54 candidates against a bug report whose own
# confirmed count was 8 — a ~7x gap large enough to mean "conflating two
# populations," not "found a bigger problem than known." All five are cheap
# label/metadata checks (no session-liveness lookups), same standard as the
# clauses above:
#   - story:* (any prefix) present                                      → excluded.
#     pilot-dispatcher.sh's OWN header is explicit that the ctx:ready
#     auto-dispatch mechanism this bug is about targets "chore/task/debt
#     beads (NO story:* label)" (packs/town-deltas/assets/pilot-dispatcher.sh
#     ~L362) — a story:approved/story:in-flight/etc. bead is dispatched via
#     a SEPARATE tier-2 feature path with its own timing (only reached once
#     tier-1 bug/debt work is exhausted), so sitting armed-without-a-route
#     for a while is its NORMAL waiting state, not this bug. This one
#     exclusion accounted for the majority of the 54.
#   - pilot:refusal-count:* (any) present                                → excluded.
#     already individually evaluated and explicitly parked with a
#     pilot:refused-reason:* — a deliberate decision already made, not an
#     undetected routing gap.
#   - needs:engine-window OR framework:engine present                   → excluded.
#     both explicitly gated on a Mayor-coordinated engine-rebuild window —
#     same "refuse, don't build, don't re-flag" doctrine this dog itself
#     follows for pool:refused:engine-rebuild-required work (framework:engine
#     is this town's own documented engine-rebuild-required trigger label,
#     8 of the first 19 real-world flags after adding the other four
#     exclusions carried it — all legitimately engine-window-gated, not
#     ga-f54ui instances).
#   - no-auto-dispatch OR pilot:no-auto-dispatch present                 → excluded.
#     an explicit, documented dispatch brake
#     ([[pilot-no-auto-dispatch-not-respected-by-pilot-dispatcher]]) — this
#     watchdog must not defeat a deliberate hold.
#   - blocked-on:*, blocked-by:*, or blocked: (any, startswith)          → excluded.
#     an explicit unresolved-dependency marker — status can still read
#     "open" while one of these is present (confirmed live: wa-v66xt), so
#     the status=open check alone does not catch it. Same "park" signal
#     class GOLW already treats as intentional (its own header: 4 of 11
#     known intentional parks carry status=blocked with no gate:needs-human
#     label at all — labels, not just status, carry this signal here).
#   - an ACTIVE (open, gate-status:{ready,claimed,queued,dispatching,
#     reviewing,running}) gate marker/run currently names this bead as
#     source-bead                                                        → excluded.
#     mirrors gate-orphaned-label-watchdog.sh's _gate_artifact_probe
#     EXACTLY (same query shape, same active-state set) rather than a
#     blanket "any gate:* label" exclusion — a bead can carry STALE
#     gate:failed/gate:needs-fix/gate:fix-attempt:N labels from a PAST
#     cycle while genuinely being a fresh instance of THIS bug (re-armed
#     for retry, route never restored — ga-f54ui's own hypothesis); only an
#     ACTIVE marker means "already dispatched, built, and submitted right
#     now" (the exact ga-5jyo8/ga-elvua trap this same dog session hit
#     twice earlier reading its OWN pool-probe candidates), so only an
#     active marker excludes, not label residue.
# TWELFTH exclusion (ga-hhj7u): pilot.dispatched_at RECENT (within
# PMRW_DISPATCH_RECENCY_MINUTES, default 240/4h) → excluded. Root cause:
# Pilot's own chore/task/debt dispatch path (pilot-dispatcher.sh) does NOT
# stamp gc.routed_to on the TARGET bead itself — only on the Pilot-created
# sling/dispatch-wrapper bead (the eleventh exclusion above, pilot.sling_for,
# already excludes the WRAPPER; this is the mirror-image gap on the TARGET
# side). So every freshly-dispatched chore/task/debt bead legitimately reads
# armed+open+unrouted for the bead's entire in-flight duration — normal,
# by-design behavior, not a routing gap. Measured directly against this
# bug's own incident (Mayor, 2026-08-07): of 13 beads flagged that sweep, 6
# had a dispatched_at under 4h old and were ALL confirmed still-legitimate
# in-flight work; the 4h line cleanly separated them from the one genuinely-
# stuck case (dispatched_at > 4h old). This default is that measured split,
# not a blind guess — PMRW_DISPATCH_RECENCY_MINUTES remains env-overridable
# if a future sweep's data suggests tightening or loosening it.
#   ⚠️ dispatched_at OLD (>= the window) or ABSENT is NOT exonerating — it's
#   the opposite. ga-o9uvc (cited above) was a 13-day-stale dispatched_at
#   COMPOUNDING the invisibility (Pilot read "already dispatched", skipped
#   re-dispatch, two blockers stacked). This clause only fires on RECENT
#   dispatched_at; old-or-absent falls through to every other check exactly
#   as before this fix — the discriminator is the AGE of dispatched_at,
#   never merely its presence.
#   BONUS OVERRIDE (cheap, one extra per-candidate query, only paid when the
#   recency clause would otherwise exclude): if pilot.sling_bead is also
#   set, the sling wrapper bead's OWN status is checked
#   (_pmrw_sling_status_probe). A CLOSED sling wrapper while the target is
#   still open+armed+unrouted is a STRONG signal independent of dispatch
#   recency (the dispatch attempt concluded one way or another, yet the
#   target was never claimed/routed/closed) — this overrides the recency
#   exclusion back to a flag. A query failure or a still-OPEN sling does
#   NOT override (fails toward keeping the recency exclusion in effect — an
#   unreliable bonus probe must not undermine the primary fix's
#   reliability).
#
# THIRTEENTH exclusion (ga-8bcc5m): a non-empty .assignee → excluded. Root
# cause: this is THIS watchdog's own instance of the crew+pool double-dispatch
# bug ga-8bcc5m reports (wa-snzzo: dispatched to crew oracle-wa AND slung to
# wa-worker via gc.routed_to at the same time — ~2h of duplicated work, only
# caught at git push). pilot-dispatcher.sh's own ownership guard
# (_ownership_guard_should_refuse) already refuses to dispatch onto a bead with
# a live assignee — but this watchdog's repair path is a SEPARATE writer of
# gc.routed_to that never consulted it (by design, per this file's own header:
# it deliberately does not source pilot-dispatcher.sh's 7000+ line filter
# chain). Before this fix, none of the twelve exclusions above looked at
# .assignee at all: a bead the Mayor/a crew had already claimed (assignee set,
# e.g. mid hand-off before the crew flips status to in_progress) but that
# still read open+armed+unrouted got gc.routed_to auto-repaired anyway —
# handing a SECOND builder (the pool) a bead a crew already owned. Zero extra
# cost: .assignee is already present on every candidate row this sweep already
# read, no new query. Deliberately no exception for pool-worker-shaped
# assignees (gastown.dog-*/wa-worker-*/ps-worker-*, the way
# _ownership_guard_should_refuse's signal (c) exempts them) — a genuinely
# in-flight pool claim already flips status to in_progress at claim time
# (this watchdog's own first filter, status=open, already excludes it on that
# basis alone), so the ONLY way an assignee survives here with status still
# open is a hand-off/hand-assignment gap, which is exactly the "already
# owned, don't also route to the pool" state this exclusion exists to catch.
# See this script's own --selftest scenario 46.
#
# What's left: status=open, NOT epic, ctx:ready AND exec:auto BOTH present
# (the "looks ready in the panel" signal ga-f54ui's own text uses),
# gc.routed_to empty/absent, no story:* label, unassigned, aged past grace,
# none of the thirteen holds/wrappers/graph-steps/parks/active-gates/
# recent-dispatches/ownership above applying.
#
# GRACE PERIOD (PMRW_GRACE_MINUTES, default 10): unlike GMMSW's gate-status
# loss (happens once, atomically, at marker creation — 5min grace), an armed
# bead can lose its route at MULTIPLE points in its lifecycle per ga-f54ui's
# own note (dispatch-time skip, OR a later reclaim/re-arm/circuit-break that
# clears it without restoring it) — closer in shape to GOLW's orphaned-label
# case than GMMSW's create-time-only case, so this uses `updated_at //
# created_at` (GOLW's fallback order) rather than GMMSW's `created_at //
# updated_at`. Grace is short by design regardless — the bug's own acceptance
# criterion is "detected in minutes, not days," and every real incident above
# was hours-to-days old, so a defensive few-minute buffer costs nothing.
#
# WHY AUTO-REPAIR IS NOW SAFE (ga-9tgos, 2026-08-09) — this section used to
# say DETECTION-ONLY and explain why NOT to auto-repair; both the objection
# and the population it applied to have since changed. Rewritten instead of
# left stale: a comment describing code that no longer matches is the exact
# defect class this city's own gate reviews most often bounce (a promise the
# code beside it doesn't keep is worse than no comment at all).
#
# THE ORIGINAL OBJECTION DOESN'T APPLY TO THIS REPAIR. It was: deriving a
# route requires PARSING a branch name (crew/<name>/<bead> -> <name>-wa) and
# INFERRING an owner/pool target — more surface for a wrong guess than
# GMMSW's "add back one well-known label". This repair does neither. It calls
# _pmrw_default_route_for_store(), a pure, already-vetted, already-shipped
# function — the EXACT mapping quality-gate-dispatcher.sh's own
# default_pool_route_for_rig() already uses in production to restore
# gc.routed_to on its gate-FAIL-return-to-pool path (ga-f54ui). Nothing here
# reads a branch name or guesses; the mapping is a static 3-way switch
# (whatsapp_automation->wa-worker, property_scrapers->ps-worker, else->
# gastown.dog) already trusted to write real bead metadata today.
#
# UPDATE (ga-no6qa, 2026-08-19): the paragraph above is no longer the WHOLE
# story — kept rather than rewritten because the store-keyed mapping it
# describes is still exactly correct as a FALLBACK, just no longer the only
# step. _pmrw_default_route_for_store() alone keyed the restored route on the
# bead's STORE, which is wrong for a domain-feature bead that lives in the HQ
# store because a rig-scoped identity (e.g. digo-wa-<session-suffix>) filed it
# there directly — confirmed live (ga-ypa6u) as this watchdog's own self-heal
# mechanism restoring gc.routed_to=gastown.dog on a WA-owned bead, 11 minutes
# after creation. _pmrw_resolve_route() now checks the bead's own created_by
# FIRST (_pmrw_owner_rig_route(), a faithful subset of pilot-dispatcher.sh's
# already-vetted ga-nlh79 owner-authoritative guard — see that function's own
# header for the exact scope tradeoff), falling back to
# _pmrw_default_route_for_store() only when created_by carries no *-wa/
# ps-worker signal. Still not a guess: created_by is a bead field this
# watchdog already reads elsewhere (_bead_recheck_status), not parsed from a
# branch name or inferred from content keywords.
#
# WHY REPAIR, NOT JUST A BETTER DETECTOR: ga-9tgos's own investigation (2026-
# 08-06 through 09, 29 comments) found the population this bug touches is
# much larger than "a handful of known cases a human fixes by hand" — the
# Mayor's own overnight count went 8 -> 10 -> 12 -> 20 armed-but-unrouted
# beads, several of them beads the Mayor had JUST manually re-routed hours
# earlier, silently losing the route again. Re-routing by hand is Sisyphean
# under a cause that keeps rewriting the fix (this city's own doctrine:
# "quando um problema aparece 2x, pare de limpar e construa o guard") — and
# unlike GMMSW's create-time-only defect, this one recurs at MULTIPLE points
# in a bead's lifecycle (ga-f54ui's own note: dispatch-time skip, or ANY
# later bd update — see below), so a one-time manual fix is never durable.
# Detection alone cannot keep the count from climbing; only repair can.
#
# WHY EVEN THE "SAFE" WRITE FORM NEEDS A RETRY LOOP, NOT ONE ATTEMPT:
# quality-gate-dispatcher.sh's existing restore-on-gate-FAIL path already
# writes via --set-metadata and verifies the result — but does NOT retry on
# a confirmed-not-stuck write, just logs "needs investigation" and moves on.
# ga-9tgos's own concurrent-write reproduction (100 concurrent --set-metadata
# writers against one disposable bead) found only a handful survived — the
# per-key-safe form is measurably BETTER than the bare --metadata form (zero
# of 100 concurrent bare writes survived the same run) but not immune to the
# underlying race. _pmrw_repair_route() retries up to
# PMRW_REPAIR_MAX_ATTEMPTS times specifically because the race is transient
# (a moment-in-time pre-read landing empty) — a later attempt's pre-read is
# not guaranteed to lose the same race twice.
#
# WHAT REMAINS UNKNOWN, STATED PLAINLY RATHER THAN OVERCLAIMED: the exact
# trigger for a TITLE-ONLY `bd update` wiping unrelated metadata (reproduced
# live twice by the Mayor: `bd update <id> --title "..."`, no --metadata flag
# at all, gc.routed_to still flipped to none while the CLI reported "✓
# Updated issue") is NOT explained by the one confirmed client-side bug
# (third_party/beads/cmd/bd/update.go's mergeMetadata() skip, gated behind
# `regularUpdates["metadata"]` being present — which a title-only call never
# populates). Source reading (both the prior investigation and a fresh pass
# for this fix, via GitHub MCP against the vendored tree) ruled out the `gc`
# CLI wrapper (cmd/gc/cmd_bd.go is a byte-for-byte argv passthrough to `bd`,
# confirmed by reading it directly — not a read-modify-write) and left a
# server/proxy-side write path (third_party/beads/internal/storage/dbproxy)
# unexamined and plausible, since this HQ runs `bd` against a shared managed
# Dolt server rather than an embedded store. THIS REPAIR IS A MITIGATION, NOT
# A ROOT-CAUSE FIX — closing that gap needs upstream/engine-side
# investigation, already explicitly out of scope for a dog session (Mayor's
# own 2026-08-09 05:41Z decision: no local `bd` rebuild, since the vendored
# tree already matches the live binary commit and would ship the identical
# bug).
#
# SAFETY BOUNDS KEPT: repair only ever fires on a candidate that ALREADY
# survived every one of the twelve exclusion filters above — same population
# a human would have fixed by hand, nothing broader. PMRW_AUTO_REPAIR=0 is an
# independent kill switch (separate from PMRW_ENABLED) for instant rollback
# to pure detection-only if this ever misbehaves in production, with no code
# change needed. Retries are bounded (PMRW_REPAIR_MAX_ATTEMPTS, default 3),
# never a spin loop. A write is never trusted from the CLI's exit code alone
# — every attempt re-reads the bead before declaring success, failure, or
# unverified (ga-p5q3: an unreadable state is its own third state).
#
# ALERTING (repair-failed/unverified beads only — a REPAIRED bead never
# reaches this path, see next paragraph): per-bead durable `bd comment`
# (new-or-cooldown-expired only, via --stdin — never a positional-arg
# `bd comment <id> <text>` invocation, which silently fuzzy-matches an
# invalid id and lands on an unrelated bead; --stdin has no id/text
# positional ambiguity to mis-derive) + aggregate `notify -p 2` +
# `gc mail send mayor`, cooldown-gated. Same shape as GMMSW/GOLW.
#
# REPAIR AUDIT TRAIL (ga-9tgos, separate from ALERTING above and NOT
# cooldown-gated — repair is attempted every sweep regardless of whether a
# prior sweep already alerted on the same bead): a SUCCESSFULLY repaired
# bead gets its own one-time `bd comment` ("SELF-HEALED...") posted directly
# on it and is logged, but deliberately does NOT trigger notify/mail — a
# repair is the routine, expected outcome this whole mechanism exists to
# produce, not an event that should page anyone (same "no side effect for a
# routine outcome" convention scenario 2 already established for a bead that
# was never broken in the first place).
#
# MULTI-STORE RESOLUTION CORRECTNESS (mirrors GOLW's ga-tqe4j fix exactly):
# a bead tracked in state that's absent from THIS sweep's flagged set is only
# declared RESOLVED after an INDIVIDUAL recheck directly against the store it
# was found in (recorded per-id in state) confirms one of: gc.routed_to is
# now set, the bead closed, the bead is no longer armed (ctx:ready or
# exec:auto stripped — someone else intervened), or the bead is gone. If that
# recheck query itself fails, or confirms the bead is STILL exactly in the
# bad state, it stays tracked and UNVERIFIED, never silently pruned — a
# per-store read failure (one of seven stores, any sweep) must never be
# conflated with "confirmed fixed" (ga-p5q3 defense (a), same as every other
# watchdog in this family).
#
# FAIL-OPEN: any single store's bd/jq query failing skips ONLY that store
# (WARN logged) — the other stores in PMRW_STORES still get swept. A total
# inability to run (bd/jq missing) skips the whole sweep, touches nothing.
#
# KILL-SWITCH: PMRW_ENABLED=0 → no-op.
# DRY-RUN: PMRW_DRY_RUN=1 → log findings, skip comment/notify/mail/state-write.
#
# Selftest: bash pilot-missing-route-watchdog.sh --selftest
set -uo pipefail

# ── config (all env-overridable) ────────────────────────────────────────────
PMRW_ENABLED="${PMRW_ENABLED:-1}"
PMRW_DRY_RUN="${PMRW_DRY_RUN:-0}"
PMRW_GRACE_MINUTES="${PMRW_GRACE_MINUTES:-10}"
PMRW_ALERT_COOLDOWN_S="${PMRW_ALERT_COOLDOWN_S:-21600}"   # 6h — matches GMMSW/GOLW precedent
PMRW_NOTIFY_PRIORITY="${PMRW_NOTIFY_PRIORITY:-2}"
# ga-hhj7u: window during which a RECENT pilot.dispatched_at excludes a
# candidate (route intentionally lives on the sling wrapper, not the target
# — see header). Default 240min/4h — the measured split from this bug's own
# incident, not a guess (see header for the full derivation).
PMRW_DISPATCH_RECENCY_MINUTES="${PMRW_DISPATCH_RECENCY_MINUTES:-240}"
# ga-9tgos: auto-repair config (see header "WHY AUTO-REPAIR IS NOW SAFE").
# Default ON — a candidate that survives every exclusion above gets a
# write+verify repair attempt BEFORE falling back to alert-only.
PMRW_AUTO_REPAIR="${PMRW_AUTO_REPAIR:-1}"
# The underlying race (ga-9tgos) is transient by nature (a moment-in-time
# pre-read landing empty), so a bounded retry has real recovery odds — one
# attempt alone (what quality-gate-dispatcher.sh's own restore-on-gate-FAIL
# path already does) does not.
PMRW_REPAIR_MAX_ATTEMPTS="${PMRW_REPAIR_MAX_ATTEMPTS:-3}"
PMRW_REPAIR_RETRY_SLEEP_S="${PMRW_REPAIR_RETRY_SLEEP_S:-1}"

HQ="${PMRW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
# Same store set as GOLW (gate-orphaned-label-watchdog.sh), same rationale:
# static default matching `gc rig list` at authoring time, env-overridable.
PMRW_STORES="${PMRW_STORES:-$HQ /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers /Users/athos/gt/marketing /Users/athos/gt/lexbh /Users/athos/gt/gastown /Users/athos/gt/deacon}"

LOG="${PMRW_LOG:-$HQ/.gc/logs/pilot-missing-route-watchdog.log}"
NOTIFY_BIN="${PMRW_NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
GC_BIN="${PMRW_GC_BIN:-gc}"
BD_BIN="${PMRW_BD_BIN:-bd}"

PMRW_STATE_DIR="${PMRW_STATE_DIR:-$HOME/.gastown/state}"
STATE_FILE="${PMRW_STATE_FILE:-$PMRW_STATE_DIR/pilot-missing-route-watchdog.state.json}"

# ── helpers ──────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [pmrw] $*" >> "$LOG" 2>/dev/null || true; }
_store_name() { basename "$1"; }

# _gate_artifact_probe <bead_id>
# Prints "1" if an OPEN type:quality-gate-marker/-run bead currently names
# $1 as source-bead AND carries an active gate-status:* label (ready,
# claimed, queued, dispatching, reviewing, running) — "0" otherwise, "error"
# if the query itself failed. Mirrors gate-orphaned-label-watchdog.sh's
# _gate_artifact_probe exactly (same query shape: `bd list -l
# "source-bead:<id>"` against the HQ store — gate markers/runs are ALWAYS
# created there regardless of which rig store the source bead lives in).
# FAIL-OPEN semantics for THIS watchdog's purpose: "error" is treated by the
# caller as "don't exclude" (a probe failure must not silently suppress a
# real finding — the opposite fail-direction from GOLW, where "error" means
# "don't prune from state"; here it means "don't let an unknown active-gate
# status hide a candidate").
_gate_artifact_probe() {
  local _bid="$1" _arts _rc
  # --include-infra (ga-vm20x, Mayor 07/08): mirrors gate-orphaned-label-
  # watchdog.sh's _gate_artifact_probe — gate markers/runs are born
  # --ephemeral (INFRA), hidden from `bd list` by default under bd 1.1.0.
  # Without this flag a genuinely active gate artifact reads as absent
  # (gate_active="0"), which skips the caller's SKIP-if-active branch
  # (~L541 below) and wrongly FLAGS an already-dispatched, gate-tracked
  # bead as a false-positive missing-route finding.
  _arts=$("$BD_BIN" -C "$HQ" list --include-infra -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'error\n'
    return 1
  fi
  if [ -z "${_arts:-}" ] || [ "$_arts" = "null" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s' "$_arts" | jq -r '
      [ .[] | select(.status == "open")
            | select( ((.labels // []) | index("type:quality-gate-marker"))
                      or ((.labels // []) | index("type:quality-gate-run")) )
            | select( ((.labels // []) | index("gate-status:ready"))       or
                      ((.labels // []) | index("gate-status:claimed"))     or
                      ((.labels // []) | index("gate-status:queued"))      or
                      ((.labels // []) | index("gate-status:dispatching")) or
                      ((.labels // []) | index("gate-status:reviewing"))   or
                      ((.labels // []) | index("gate-status:running")) )
      ] | if length > 0 then "1" else "0" end
    ' 2>/dev/null
}

# _pmrw_sling_status_probe <sling_bead_id> <store>
# ga-hhj7u bonus check: prints "closed" if the named sling/dispatch-wrapper
# bead is closed, "open" if it's still open, "error" if the query failed or
# the bead is gone/unresolvable. Uses the exact-match `list --id <id>` flag
# form, never a positional `bd show <id>` (same
# [[bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently]] hygiene as
# _bead_recheck_status). FAIL-OPEN direction is the OPPOSITE of
# _gate_artifact_probe's on purpose: this probe only ever OVERRIDES an
# exclusion the recency clause already granted, it does not gate the
# primary detector — so "error"/"gone" must not flip a normal recent
# dispatch into a false alarm. Caller treats anything other than a
# confirmed "closed" as "don't override."
_pmrw_sling_status_probe() {
  local _sid="$1" _store="$2" _out _rc
  _out=$("$BD_BIN" -C "$_store" list --id "$_sid" --all --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "${_out:-}" ] || [ "$_out" = "null" ]; then
    printf 'error\n'
    return 1
  fi
  printf '%s' "$_out" | jq -r --arg id "$_sid" '
      ([ .[] | select(.id == $id) ] | .[0]) as $b
      | if $b == null then "error"
        elif ($b.status // "") == "closed" then "closed"
        else "open"
        end
    ' 2>/dev/null
}

# _state_load — prints the current state JSON (or "{}" on missing/corrupt file, fail-open)
_state_load() {
  if [ -f "$STATE_FILE" ]; then
    jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# _bead_recheck_status <id> <store>
# Individually re-verifies ONE bead's current armed-but-unrouted status
# directly against the store it was tracked under (ga-tqe4j pattern). Uses
# the exact-match `list --id <id>` flag form, never a positional `bd show
# <id>` (immune to bd's fuzzy positional-id matching —
# [[bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently]]). Prints ONE
# token:
#   error     — query itself failed: UNKNOWN, caller must NOT resolve.
#   gone      — store has no record for this id: treated as resolved.
#   closed    — status=closed: no longer armed by definition, resolved.
#   routed    — gc.routed_to is now non-empty: the FIX landed, resolved.
#   not-armed — still open, but no longer carries BOTH ctx:ready AND
#               exec:auto (someone/something else intervened — claimed,
#               parked, gate-failed off the ready queue): out of THIS
#               watchdog's scope now, resolved.
#   present   — still open, still armed, still unrouted: dropped from this
#               sweep for some OTHER reason (transient read blip, etc.) —
#               NOT resolved.
# KNOWN SCOPE LIMIT: this recheck deliberately does NOT re-test the five
# label-based exclusions added to the main sweep filter (story:*,
# pilot:refusal-count:*, needs:engine-window, no-auto-dispatch, active-gate
# probe) — only the core armed/routed/closed/gone signals. A bead that
# newly acquires one of those five AFTER being tracked stays in state as
# "present"/UNVERIFIED indefinitely rather than being pruned as resolved.
# Harmless: cooldown already suppresses re-alerting regardless of state, so
# this is a state-file hygiene gap only, never a false-alert or missed-alert
# risk. Not worth duplicating the full filter here for that payoff.
_bead_recheck_status() {
  local _id="$1" _store="$2" _out _rc
  _out=$("$BD_BIN" -C "$_store" list --id "$_id" --all --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "${_out:-}" ] || [ "$_out" = "null" ]; then
    printf 'error\n'
    return 1
  fi
  printf '%s' "$_out" | jq -r --arg id "$_id" '
      ([ .[] | select(.id == $id) ] | .[0]) as $b
      | if $b == null then "gone"
        elif ($b.status // "") == "closed" then "closed"
        elif (($b.metadata["gc.routed_to"] // "") | test("\\S")) then "routed"
        elif ( (($b.labels // []) | index("ctx:ready")) and (($b.labels // []) | index("exec:auto")) ) then "present"
        else "not-armed"
        end
    ' 2>/dev/null
}

# _pmrw_default_route_for_store <store_path>
# ga-9tgos: what gc.routed_to should be RESTORED to for a candidate this
# sweep already confirmed is armed+open+unrouted+aged and survived every
# exclusion filter. Mirrors quality-gate-dispatcher.sh's
# default_pool_route_for_rig() / pilot-dispatcher.sh's
# rig_to_builder()+wa_worker_template() EXACTLY (same three-way split) —
# duplicated on purpose, not sourced, same tradeoff that function's own
# header already documents (independently-running daemons, no shared-lib
# chokepoint today; confirmed absent again for THIS fix by direct source
# search, not assumed). Keyed on the STORE's basename rather than a $RIG
# variable, since PMRW_STORES is a set of filesystem paths, not rig names —
# same unit _store_name() already uses everywhere else in this script.
_pmrw_default_route_for_store() {
  local _s; _s="$(_store_name "$1")"
  case "$_s" in
    whatsapp_automation|wa) printf 'wa-worker' ;;
    property_scrapers|ps)   printf 'ps-worker' ;;
    *)                      printf 'gastown.dog' ;;
  esac
}

# _pmrw_owner_rig_route <created_by>
# ga-no6qa: owner-authoritative rig inference for the repair fallback, a
# faithful SUBSET of pilot-dispatcher.sh's own already-vetted ga-nlh79 guard
# (packs/town-deltas/assets/pilot-dispatcher.sh, "OWNER-AUTHORITATIVE rig
# precedence") — created_by carrying a *-wa/ps-worker crew identity is a
# stronger domain-rig signal than the bead's STORE: a domain-feature bead
# authored by a rig crew but filed directly against the HQ store (e.g.
# digo-wa-<session-suffix>, mila-wa-<session-suffix> — created_by always
# carries a session-id suffix, so `*-wa` alone would miss it; match `*-wa-*`
# too, same ga-nlh79 fix) must not fall through to the gastown.dog wildcard
# just because its store is HQ.
#
# Only created_by is checked, not assignee: this function is only ever called
# on candidates from run_sweep's own sel_json filter, which already excludes
# every bead with a non-empty assignee (a bead this watchdog acts on is
# always unassigned by definition) — an assignee check here could never fire
# and would be dead code, unlike ga-nlh79's original guard, whose candidate
# population has no such precondition.
#
# Deliberately does NOT replicate ga-nlh79's ga-zzqza HQ-exclusive-path-
# existence override (a bead citing a path that exists ONLY in HQ overrides
# the owner signal back to framework/dog-routed) — that override needs to
# parse the bead's cited file paths/basenames and probe every rig's live tree
# for existence, infrastructure this watchdog does not have, and a materially
# larger change than this bug's lane:small scope. Tradeoff, not an oversight:
# a pure-framework bead authored by a *-wa identity that also cites an
# HQ-only path will be owner-routed to wa-worker here instead of staying on
# gastown.dog — rare (a rig crew filing pure-framework work) and
# non-destructive (wa-worker can still see/triage/reroute it, nothing is
# lost) — against the status quo, which unconditionally misroutes the far
# more common case this bug tracks.
#
# Prints 'wa-worker' or 'ps-worker' on a match, empty on no signal (caller
# falls through to the per-store default).
_pmrw_owner_rig_route() {
  local _created_by="$1"
  case "$_created_by" in
    *-wa|*-wa-*|wa-worker*) printf 'wa-worker' ;;
    ps-worker*)             printf 'ps-worker' ;;
  esac
}

# _pmrw_resolve_route <created_by> <store_path>
# ga-no6qa: the actual value this watchdog restores gc.routed_to to —
# owner-authoritative signal (_pmrw_owner_rig_route) first, falling back to
# the store-keyed default (_pmrw_default_route_for_store) only when
# created_by carries no *-wa/ps-worker signal. See _pmrw_owner_rig_route's
# own header for the full rationale and scope tradeoff.
_pmrw_resolve_route() {
  local _created_by="$1" _store="$2" _owner_route
  _owner_route="$(_pmrw_owner_rig_route "$_created_by")"
  if [ -n "$_owner_route" ]; then
    printf '%s' "$_owner_route"
  else
    _pmrw_default_route_for_store "$_store"
  fi
}

# _pmrw_repair_route <bead_id> <store> [created_by]
# ga-no6qa: optional 3rd param threads the bead's created_by through to
# _pmrw_resolve_route so an owner-authoritative signal can override the
# store-keyed default before this function's own retry/verify loop runs.
# Omitted (or empty) falls straight through to the pre-existing store-only
# behavior — every pre-ga-no6qa caller and selftest scenario that doesn't
# pass it is unaffected.
# ga-9tgos: attempts to RESTORE gc.routed_to on a candidate run_sweep's
# per-bead loop already confirmed survived every exclusion filter (called
# from there only — never speculatively). Writes via --set-metadata (the
# per-key-safe form this whole script family already standardizes on — see
# _GFAIL_ROUTE in quality-gate-dispatcher.sh), THEN VERIFIES via a fresh
# read through the exact same _bead_recheck_status this script already uses
# for resolve-tracking. Never trusts the CLI's own exit code alone: ga-9tgos's
# own core finding, reproduced live by the Mayor (bd update <id> --title "..."
# — untouched metadata — flipped gc.routed_to to none while the CLI reported
# "✓ Updated issue"), is that a write can report success while silently not
# persisting. Retries up to PMRW_REPAIR_MAX_ATTEMPTS times on a confirmed-
# not-stuck write: the underlying race is transient (a moment-in-time
# pre-read landing empty), so a later attempt's pre-read is not guaranteed to
# lose the same race — and even the "safe" --set-metadata form is not immune
# (ga-9tgos's own concurrent-write repro: of 100 concurrent --set-metadata
# writers against one bead, only a handful survived), so a single attempt
# with no retry (quality-gate-dispatcher.sh's existing gate-FAIL restore path)
# is not enough on its own either.
# Prints ONE token to stdout, nothing else:
#   repaired         — write verified stuck; bead now carries gc.routed_to.
#   already-resolved — bead closed/gone/no-longer-armed between detection and
#                       repair (something else already handled it, or it
#                       simply isn't armed anymore) — not a failure, just
#                       moot; caller must not alert on this.
#   failed            — exhausted retries; gc.routed_to confirmed still empty
#                       (a verify read succeeded and said "present" every
#                       time).
#   unverified        — exhausted retries; every verify read itself failed
#                       (ga-p5q3 discipline: an unreadable state is its own
#                       third state, never folded into "failed" — the write
#                       may well have stuck; this watchdog just could not
#                       confirm it).
# Never touches state or alert plumbing — the caller (run_sweep) decides what
# to do with the outcome.
_pmrw_repair_route() {
  local _bid="$1" _store="$2" _created_by="${3:-}" _route _attempt _status
  _route="$(_pmrw_resolve_route "$_created_by" "$_store")"
  _status="error"
  _attempt=1
  while [ "$_attempt" -le "${PMRW_REPAIR_MAX_ATTEMPTS:-3}" ]; do
    "$BD_BIN" -C "$_store" update "$_bid" --set-metadata "gc.routed_to=$_route" -q 2>/dev/null || true
    _status="$(_bead_recheck_status "$_bid" "$_store")"
    case "$_status" in
      routed)
        printf 'repaired'
        return 0
        ;;
      closed|gone|not-armed)
        printf 'already-resolved'
        return 0
        ;;
      present)
        log "  - REPAIR $_bid ($(_store_name "$_store")): attempt ${_attempt}/${PMRW_REPAIR_MAX_ATTEMPTS} wrote gc.routed_to=$_route but verify still shows it absent — retrying"
        ;;
      *)
        log "  - REPAIR $_bid ($(_store_name "$_store")): attempt ${_attempt}/${PMRW_REPAIR_MAX_ATTEMPTS} verify read failed (error) — retrying"
        ;;
    esac
    _attempt=$((_attempt + 1))
    if [ "$_attempt" -le "${PMRW_REPAIR_MAX_ATTEMPTS:-3}" ] && [ "${PMRW_REPAIR_RETRY_SLEEP_S:-0}" != "0" ]; then
      sleep "$PMRW_REPAIR_RETRY_SLEEP_S"
    fi
  done
  # Exhausted retries — distinguish failed (confirmed still empty) from
  # unverified (last read errored) using the LAST $_status observed above.
  if [ "$_status" = "present" ]; then
    printf 'failed'
  else
    printf 'unverified'
  fi
  return 1
}

# _pmrw_resolve_tracked_state <state_json> <flagged_ids_json>
# ga-tqe4j pattern: the single choke point run_sweep funnels through before
# pruning anything from state. For every id in <state_json> NOT present in
# <flagged_ids_json>, individually re-verifies via _bead_recheck_status
# before deciding resolved-vs-still-broken-but-missed. Prints one JSON object
# on stdout: {"state": <pruned-state>, "resolved_ids": [...]}.
_pmrw_resolve_tracked_state() {
  local _state="$1" _keep="$2"
  local _candidates
  _candidates="$(printf '%s' "$_state" | jq -r --argjson keep "$_keep" 'keys - $keep | .[]' 2>/dev/null)"
  local _resolved="" _rid _rstore _rstatus _unverified_count=0
  if [ -n "${_candidates:-}" ]; then
    while IFS= read -r _rid; do
      [ -z "$_rid" ] && continue
      _rstore="$(printf '%s' "$_state" | jq -r --arg id "$_rid" '.[$id].store // empty' 2>/dev/null)"
      if [ -z "${_rstore:-}" ]; then
        log "UNVERIFIED: $_rid absent from this sweep but no store on record (pre-fix state entry) — cannot re-check, keeping (fail-safe)"
        _unverified_count=$((_unverified_count + 1))
        continue
      fi
      _rstatus="$(_bead_recheck_status "$_rid" "$_rstore")"
      case "$_rstatus" in
        gone|closed|routed|not-armed)
          log "RESOLVED: $_rid re-checked individually (${_rstatus}) — no longer armed-but-unrouted — cleared from state"
          _resolved="${_resolved}${_rid}"$'\n'
          ;;
        present)
          log "UNVERIFIED: $_rid re-checked and is STILL armed+unrouted (dropped from this sweep for another reason) — keeping in state, NOT resolved"
          _unverified_count=$((_unverified_count + 1))
          ;;
        *)
          log "UNVERIFIED: $_rid re-check query failed (store '$_rstore') — fail-safe, keeping in state, NOT declaring resolved"
          _unverified_count=$((_unverified_count + 1))
          ;;
      esac
    done <<< "$_candidates"
  fi
  if [ "$_unverified_count" -gt 0 ]; then
    log "UNVERIFIED total this sweep: ${_unverified_count} bead(s) absent from the flagged set but not positively confirmed cleared — kept in state"
  fi
  local _resolved_json
  _resolved_json="$(printf '%s' "$_resolved" | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
  [ -z "${_resolved_json:-}" ] && _resolved_json="[]"
  local _new_state
  _new_state="$(printf '%s' "$_state" | jq -c --argjson gone "$_resolved_json" 'with_entries(select(.key as $k | ($gone | index($k)) == null))' 2>/dev/null)"
  [ -z "${_new_state:-}" ] && _new_state="$_state"
  jq -nc --argjson st "$_new_state" --argjson rid "$_resolved_json" '{state: $st, resolved_ids: $rid}' 2>/dev/null
}

run_sweep() {
  if [ "${PMRW_ENABLED:-1}" != "1" ]; then
    log "disabled (PMRW_ENABLED=0) — no-op"
    return 0
  fi
  if [ -z "${PMRW_TEST_MODE:-}" ]; then
    command -v "$BD_BIN" >/dev/null 2>&1 || { log "WARN: bd not on PATH — fail-open, no sweep"; return 0; }
    command -v jq >/dev/null 2>&1 || { log "WARN: jq not on PATH — fail-open, no sweep"; return 0; }
  fi

  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - PMRW_GRACE_MINUTES * 60 ))

  local state; state="$(_state_load)"

  # Accumulate flagged candidates as TSV: id, store, age_min, labels, issue_type
  local flagged_tsv=""
  local repaired_tsv=""
  # ga-9tgos: computed once — under PMRW_AUTO_REPAIR=1 and not dry-run, EVERY
  # candidate that reaches the alert path below did so via a failed/
  # unverified repair attempt (the per-bead loop's repair block only ever
  # falls through to flagged_tsv on those two outcomes) — so the alert
  # wording only needs to know the MODE, never a per-bead lookup.
  local _pmrw_repair_was_active=0
  if [ "${PMRW_AUTO_REPAIR:-1}" = "1" ] && [ "${PMRW_DRY_RUN:-0}" != "1" ]; then
    _pmrw_repair_was_active=1
  fi
  # ga-qpfza: coverage counters — the final verdict must be a function of how
  # many stores were actually readable this sweep, not just what was found in
  # the ones that were (7/7 unreadable previously still logged "OK: 0", the
  # same false all-clear a totally-blind sweep gives a normal one). stores_total
  # counts loop iterations; stores_read only advances past BOTH fail-open
  # checks below (cand_json parse AND the sel_json filter) — a store that
  # silently produced garbage counts as unread, same as one bd/jq errored on
  # outright. A legitimately-empty read (sel_json=="[]", zero candidates) is
  # NOT a failure and still advances stores_read.
  local stores_total=0 stores_read=0
  local store cand_json sel_json
  for store in $PMRW_STORES; do
    stores_total=$((stores_total + 1))
    # Re-stamp the lock heartbeat once per store (mirrors quality-gate-
    # dispatcher.sh's per-verdict-poll re-stamp — see header). Guarded via
    # `command -v`: during in-process selftest scenarios (run_sweep called
    # directly, before the script reaches the lock section below in file
    # order) this function doesn't exist yet and the call is a silent no-op;
    # in the real script and in the lock-race selftest scenarios (which
    # invoke a full subprocess) it's already defined by the time run_sweep
    # executes for real.
    command -v _pmrw_lock_write_hb >/dev/null 2>&1 && _pmrw_lock_write_hb
    cand_json=$("$BD_BIN" -C "$store" list --json --limit 0 2>/dev/null \
      | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
    if [ -z "${cand_json:-}" ] || [ "$cand_json" = "null" ]; then
      log "WARN: could not read store '$store' (bd query or jq parse failed) — skipping this store (fail-open, other stores still swept)"
      continue
    fi

    sel_json=$(printf '%s' "$cand_json" | jq -c --argjson cut "$cutoff" --argjson now_ts "$now" '
        [ .[] | select((.status // "") == "open")
              | select((.issue_type // .type // "") != "epic")
              | select((.labels // []) | index("ctx:ready"))
              | select((.labels // []) | index("exec:auto"))
              | select(((.metadata["gc.routed_to"] // "") | test("\\S")) | not)
              | select(((.labels // []) | any(startswith("gate:needs-human"))) | not)
              | select(
                  (((.labels // []) | index("pilot:held")) | not)
                  or
                  ((.labels // []) | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber) |
                    if length > 0 then (max < $now_ts) else false end)
                )
              | select(((.metadata["gc.root_bead_id"] // "") | test("\\S")) | not)
              | select(((.metadata["gc.formula_contract"] // "") | test("\\S")) | not)
              | select((((.metadata["gc.kind"] // "") as $k
                        | ["workflow","scope","ralph","retry","check","fanout","retry-eval","scope-check","workflow-finalize"]
                        | index($k)) == null))
              | select(((.metadata["pilot.sling_for"] // "") | test("\\S")) | not)
              | select(((.labels // []) | any(startswith("story:"))) | not)
              | select(((.labels // []) | any(startswith("pilot:refusal-count:"))) | not)
              | select(((.labels // []) | (index("needs:engine-window") or index("framework:engine"))) | not)
              | select(((.labels // []) | (index("no-auto-dispatch") or index("pilot:no-auto-dispatch"))) | not)
              | select(((.labels // []) | any(startswith("blocked-on:") or startswith("blocked-by:") or startswith("blocked:"))) | not)
              | select(((.assignee // "") | test("\\S")) | not)
              | select( ((( .updated_at // .created_at // "") | fromdateiso8601?) // 9999999999) < $cut )
        ]
      ' 2>/dev/null)
    if [ -z "${sel_json:-}" ]; then
      log "WARN: filter jq failed for store '$store' — skipping this store (fail-open)"
      continue
    fi
    stores_read=$((stores_read + 1))

    local rows
    # ga-no6qa: joined with an explicit unit-separator byte (octal 037 / US),
    # not @tsv/tab. Bash's `read` treats tab as IFS "whitespace" (like space or
    # newline) and COLLAPSES consecutive whitespace delimiters regardless of what
    # IFS is set to -- so a run of empty fields (pilot.dispatched_at and
    # pilot.sling_bead are both routinely empty) silently shifts every field
    # after them one slot left. Harmless before this fix (both were last in the
    # list, so the shift only ate trailing emptiness); NOT harmless once
    # created_by follows them -- caught live by ga-no6qa selftest scenarios
    # 50/51 (the correct route computed empty and the write silently fell back
    # to the store default). US is not IFS-whitespace, so `read` preserves
    # empty fields correctly regardless of position (verified directly: comma
    # behaves this way, tab does not).
    local _pmrw_fs; _pmrw_fs="$(printf '\037')"
    rows=$(printf '%s' "$sel_json" | jq -r --argjson now_ts "$now" --arg fs "$_pmrw_fs" '
        .[] | . as $b
        | ($b.labels // []) as $L
        | ( (($b.updated_at // $b.created_at // "") | fromdateiso8601?) // null ) as $epoch
        | [ $b.id,
            ($L | join(",")),
            ($b.issue_type // $b.type // "?"),
            ( if $epoch then (((($now_ts) - $epoch) / 60) | floor | tostring) else "?" end ),
            ($b.metadata["pilot.dispatched_at"] // ""),
            ($b.metadata["pilot.sling_bead"] // ""),
            ($b.created_by // "")
          ] | join($fs)
      ' 2>/dev/null)
    [ -z "${rows:-}" ] && continue
    local gate_active dispatched_at sling_bead dispatch_age_s recency_threshold_s sling_status sling_override sling_note repair_status
    while IFS="$_pmrw_fs" read -r bid blabels btype age_min dispatched_at sling_bead created_by; do
      [ -z "${bid:-}" ] && continue

      # ga-hhj7u: recent pilot.dispatched_at → normally excluded (route
      # intentionally lives on the sling wrapper, not this bead — see
      # header). Bash-only, no query, so it's checked first (cheapest).
      case "${dispatched_at:-}" in
        ''|*[!0-9]*) ;;  # absent/non-numeric — not exonerating, fall through unchanged
        *)
          dispatch_age_s=$(( now - dispatched_at ))
          recency_threshold_s=$(( PMRW_DISPATCH_RECENCY_MINUTES * 60 ))
          if [ "$dispatch_age_s" -ge 0 ] && [ "$dispatch_age_s" -lt "$recency_threshold_s" ]; then
            sling_override=0
            sling_note=""
            if [ -n "${sling_bead:-}" ]; then
              sling_status="$(_pmrw_sling_status_probe "$sling_bead" "$store")"
              if [ "$sling_status" = "closed" ]; then
                sling_override=1
              else
                # ga-hhj7u self-audit: name the actual sling_status (open vs
                # error) rather than folding "confirmed open" and "couldn't
                # tell" into one identical SKIP line — a reader of the log
                # later must be able to tell which happened.
                sling_note=" (sling $sling_bead checked: $sling_status, not overriding)"
              fi
            fi
            if [ "$sling_override" -ne 1 ]; then
              log "  - SKIP $bid ($(_store_name "$store")): pilot.dispatched_at ${dispatch_age_s}s ago (< ${PMRW_DISPATCH_RECENCY_MINUTES}m recency window) — route intentionally lives on the sling wrapper, not a routing gap (ga-hhj7u)${sling_note}"
              continue
            fi
            log "  - $bid ($(_store_name "$store")): recently dispatched (${dispatch_age_s}s ago) but sling wrapper $sling_bead is CLOSED while still armed+unrouted — strong signal, NOT excluded (ga-hhj7u bonus)"
          fi
          ;;
      esac

      gate_active="$(_gate_artifact_probe "$bid")"
      if [ "$gate_active" = "1" ]; then
        log "  - SKIP $bid ($(_store_name "$store")): active gate marker/run in flight — already dispatched+built+submitted, not a routing gap"
        continue
      fi

      # ga-9tgos: repair before falling back to alert-only. Skipped entirely
      # in DRY_RUN (dry-run's whole contract is detect-but-touch-nothing —
      # see scenario 16) and via PMRW_AUTO_REPAIR=0 (independent rollback
      # switch, kept separate from PMRW_DRY_RUN so an operator can force
      # detection-only in production without also silencing alerts).
      if [ "$_pmrw_repair_was_active" = "1" ]; then
        repair_status="$(_pmrw_repair_route "$bid" "$store" "$created_by")"
        case "$repair_status" in
          repaired)
            repaired_tsv="${repaired_tsv}${bid}\t${store}\t$(_pmrw_resolve_route "$created_by" "$store")\n"
            log "  - REPAIRED $bid ($(_store_name "$store")): gc.routed_to restored to $(_pmrw_resolve_route "$created_by" "$store") and verified — not flagging this sweep"
            continue
            ;;
          already-resolved)
            log "  - SKIP $bid ($(_store_name "$store")): no longer armed/open by the time repair ran — moot, not flagging"
            continue
            ;;
          failed)
            log "  - REPAIR FAILED $bid ($(_store_name "$store")): exhausted ${PMRW_REPAIR_MAX_ATTEMPTS} attempt(s), gc.routed_to confirmed still absent — falling through to alert"
            ;;
          *)
            log "  - REPAIR UNVERIFIED $bid ($(_store_name "$store")): exhausted ${PMRW_REPAIR_MAX_ATTEMPTS} attempt(s), could not confirm outcome — falling through to alert"
            ;;
        esac
      fi

      flagged_tsv="${flagged_tsv}${bid}\t${store}\t${age_min}\t${blabels}\t${btype}\n"
    done <<< "$rows"
  done

  # ── ga-9tgos: log + comment the repaired set (audit trail only — never
  # alarms; a repaired bead is working again, same "no side effect for a
  # routine, expected outcome" convention as e.g. scenario 2's routed-bead-
  # never-flags). Runs regardless of whether flagged_tsv ends up empty or
  # not — a sweep can both repair some candidates AND still have others fall
  # through to alert. ─────────────────────────────────────────────────────
  local repaired_count; repaired_count="$(printf '%b' "${repaired_tsv:-}" | grep -c . || true)"
  [ -z "${repaired_count:-}" ] && repaired_count=0
  if [ "${repaired_count:-0}" -gt 0 ]; then
    log "REPAIRED: ${repaired_count} bead(s) had gc.routed_to auto-restored this sweep (ga-9tgos)"
    local rbid rstore2 rroute
    while IFS=$'\t' read -r rbid rstore2 rroute; do
      [ -z "${rbid:-}" ] && continue
      log "  - $rbid ($(_store_name "$rstore2")): gc.routed_to -> $rroute"
      if [ -n "${PMRW_TEST_COMMENTS_LOG:-}" ]; then
        echo "repaired:${rbid}" >> "$PMRW_TEST_COMMENTS_LOG" 2>/dev/null || true
      else
        printf '%s' "pilot-missing-route-watchdog (ga-f54ui/ga-9tgos): this bead was armed (ctx:ready + exec:auto) and open, but gc.routed_to had gone missing. SELF-HEALED this sweep: restored to '${rroute}' and verified by re-reading the bead after the write — not assumed from the CLI's exit code (ga-9tgos's own finding is that a write can report success while silently not persisting). No human action needed; recorded here for the audit trail." \
          | "$BD_BIN" -C "$rstore2" comment "$rbid" --stdin 2>/dev/null || log "WARN: bd comment (repair audit) failed for $rbid"
      fi
    done < <(printf '%b' "$repaired_tsv")
  fi

  # Build the flagged-ids set once, used both for the empty-branch prune pass
  # and the non-empty branch below — always run resolution, even when this
  # sweep found nothing (that's the degenerate "everything got fixed, or
  # every store failed" case, and those two must not collapse to one verdict
  # either — see _pmrw_resolve_tracked_state's per-id fail-safe).
  local flagged_ids_json="[]"
  if [ -n "${flagged_tsv:-}" ]; then
    flagged_ids_json="$(printf '%b' "$flagged_tsv" | cut -f1 | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
    [ -z "${flagged_ids_json:-}" ] && flagged_ids_json="[]"
  fi

  local resolve_out; resolve_out="$(_pmrw_resolve_tracked_state "$state" "$flagged_ids_json")"
  local resolved_ids_json; resolved_ids_json="$(printf '%s' "$resolve_out" | jq -c '.resolved_ids // []' 2>/dev/null)"
  [ -z "${resolved_ids_json:-}" ] && resolved_ids_json="[]"
  state="$(printf '%s' "$resolve_out" | jq -c '.state // {}' 2>/dev/null)"
  [ -z "${state:-}" ] && state="{}"
  local resolved_count; resolved_count="$(printf '%s' "$resolved_ids_json" | jq 'length' 2>/dev/null)"
  [ -z "${resolved_count:-}" ] && resolved_count=0

  if [ -z "${flagged_tsv:-}" ]; then
    # ga-qpfza: the verdict is a function of COVERAGE first, count second —
    # "found nothing" and "couldn't check anything" must never print the same
    # line (real incident: 7/7 stores unreadable during a Dolt restart still
    # logged "OK: 0 armed-but-unrouted bead(s)", an all-clear a blind sweep
    # has no right to claim). stores_read/stores_total come from the loop
    # above; UNKNOWN and PARTIAL never use the bare "OK:" prefix so a reader
    # scanning only for that word can't mistake either for a clean sweep.
    if [ "$stores_read" -eq 0 ]; then
      log "UNKNOWN: sweep cego (0/${stores_total} stores legíveis) — nenhuma conclusão possível"
    elif [ "$stores_read" -lt "$stores_total" ]; then
      log "PARTIAL: ${stores_read}/${stores_total} stores lidas; resultado cobre apenas essas (0 armed-but-unrouted nas stores lidas, ${resolved_count} resolved, ${repaired_count:-0} auto-repaired)"
    elif [ "$resolved_count" -eq 0 ] && [ "${repaired_count:-0}" -eq 0 ] && [ "$state" = "{}" ]; then
      log "OK: 0 armed-but-unrouted bead(s) found across ${stores_total} store(s)"
    else
      log "OK: 0 armed-but-unrouted bead(s) this sweep (${resolved_count} resolved, ${repaired_count:-0} auto-repaired)"
    fi
    if [ "${PMRW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$PMRW_STATE_DIR" 2>/dev/null || true
      if [ "$state" = "{}" ] && [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE" 2>/dev/null || true
      elif [ "$state" != "{}" ]; then
        printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
      fi
    fi
    # Explicit if/else, not a chained &&/|| — this file's own lock-section
    # header documents a real regression from exactly this collapsed-OR
    # shape ("faz quanto tempo?" vs "ainda existe?" are different
    # questions; same family here: "resolved something?" vs "repaired
    # something?" must both independently make this a non-trivial sweep).
    # A totally-blind sweep (stores_read==0) gets its own exit code (2),
    # distinct from both "ran clean" (0) and "ran, something changed" (1) —
    # ga-qpfza's own acceptance criterion — checked FIRST, ahead of the
    # resolved/repaired signal. That signal is NOT guaranteed zero here:
    # _pmrw_resolve_tracked_state's per-id recheck (_bead_recheck_status) is
    # an independent targeted query per previously-tracked bead, not gated
    # on the bulk per-store reads this counts, so resolved_count could in
    # principle be nonzero even on a blind sweep — "the sweep couldn't read
    # anything this round" is still the more operationally significant fact
    # and must win regardless of what one side-channel recheck turned up.
    if [ "$stores_read" -eq 0 ]; then
      return 2
    elif [ "$resolved_count" -gt 0 ] || [ "${repaired_count:-0}" -gt 0 ]; then
      return 1
    else
      return 0
    fi
  fi

  # ── cooldown/state: alert only new-or-cooldown-expired, log the FULL
  # current flagged set. Process-substitution, NOT a pipe, so `state`
  # mutations survive the loop. ────────────────────────────────────────────
  local to_alert_tsv=""
  local bid store2 age_min labels btype last_alert
  while IFS=$'\t' read -r bid store2 age_min labels btype; do
    [ -z "${bid:-}" ] && continue
    last_alert="$(printf '%s' "$state" | jq -r --arg id "$bid" '.[$id].last_alert // 0' 2>/dev/null)"
    case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
    if [ "$last_alert" -eq 0 ] || [ $(( now - last_alert )) -ge "$PMRW_ALERT_COOLDOWN_S" ]; then
      to_alert_tsv="${to_alert_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${btype}\n"
      state="$(printf '%s' "$state" | jq -c --arg id "$bid" --arg store "$store2" --argjson now "$now" \
        '.[$id] = {store: $store, first_seen: (.[$id].first_seen // $now), last_alert: $now}' 2>/dev/null)"
    fi
  done < <(printf '%b' "$flagged_tsv")

  local total_flagged; total_flagged="$(printf '%b' "$flagged_tsv" | grep -c . || true)"
  local new_count; new_count="$(printf '%b' "$to_alert_tsv" | grep -c . || true)"

  log "FLAGGED: ${total_flagged} armed-but-unrouted bead(s) (>=${PMRW_GRACE_MINUTES}min old), ${resolved_count} resolved since last sweep"
  printf '%b' "$flagged_tsv" | while IFS=$'\t' read -r bid store2 age_min labels btype; do
    [ -z "${bid:-}" ] && continue
    log "  - $bid ($(_store_name "$store2"), ${btype}) age=${age_min}min labels=[${labels}]"
  done

  if [ "${new_count:-0}" -eq 0 ] && [ "${resolved_count:-0}" -eq 0 ]; then
    # ga-qpfza: same bare-"OK:" collapse as the empty-flagged branch above,
    # one branch over — total_flagged only reflects stores that were
    # actually read this sweep, so an unread store's own candidates are
    # silently absent from it. stores_read==0 can't reach this branch
    # (flagged_tsv would be empty), so only the partial tier applies here.
    if [ "$stores_read" -lt "$stores_total" ]; then
      log "PARTIAL: ${stores_read}/${stores_total} stores lidas; ${total_flagged} flagged bead(s) (from stores read) already alerted within cooldown — coverage incomplete, unread stores may hold more"
    else
      log "OK: all ${total_flagged} flagged bead(s) already alerted within cooldown (${PMRW_ALERT_COOLDOWN_S}s) — no new notification"
    fi
    if [ "${PMRW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$PMRW_STATE_DIR" 2>/dev/null || true
      printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
    fi
    return 1
  fi

  if [ "${PMRW_DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would comment on new/due bead(s), notify (-p ${PMRW_NOTIFY_PRIORITY}), and mail mayor; state not persisted"
    return 1
  fi

  # ── per-bead durable comment (new-or-cooldown-expired only), via --stdin ──
  local msg
  while IFS=$'\t' read -r bid store2 age_min labels btype; do
    [ -z "${bid:-}" ] && continue
    if [ "$_pmrw_repair_was_active" = "1" ]; then
      # ga-9tgos: every bead reaching this loop under active-repair mode
      # already went through a failed/unverified write+verify repair
      # attempt in the per-bead loop above — "no metadata was changed" is
      # no longer true here and must not be claimed (this codebase's own
      # doctrine: a comment promising something the code doesn't do is
      # worse than none).
      msg="pilot-missing-route-watchdog (ga-f54ui): this bead is armed (ctx:ready + exec:auto, labels=[${labels}]) and open, but carries NO gc.routed_to metadata. ARMED BUT UNREACHABLE: a pool worker's self-serve discovery (bd ready --metadata-field gc.routed_to=<target> --unassigned) will never find it without that field, and the Pilot's own re-dispatch pass may separately skip it if a stale pilot.dispatched_at is present — this can look 'ready' in every listing and the panel while nothing ever picks it up. age=${age_min}min type=${btype} store=$(_store_name "$store2"). AUTO-REPAIR WAS ATTEMPTED this sweep (up to ${PMRW_REPAIR_MAX_ATTEMPTS} write+verify tries, ga-9tgos) and did NOT verifiably stick — see the watchdog log for per-attempt detail; this likely means sustained write contention specific to this bead, not a one-off blip. A human/Mayor should investigate and set gc.routed_to to un-strand this bead (commonly derivable from an existing crew/<name>/<bead> branch owner, or wa-worker/ps-worker/dog for pool-eligible work)."
    else
      msg="pilot-missing-route-watchdog (ga-f54ui): this bead is armed (ctx:ready + exec:auto, labels=[${labels}]) and open, but carries NO gc.routed_to metadata. ARMED BUT UNREACHABLE: a pool worker's self-serve discovery (bd ready --metadata-field gc.routed_to=<target> --unassigned) will never find it without that field, and the Pilot's own re-dispatch pass may separately skip it if a stale pilot.dispatched_at is present — this can look 'ready' in every listing and the panel while nothing ever picks it up. age=${age_min}min type=${btype} store=$(_store_name "$store2"). Detection-only this sweep (auto-repair disabled via PMRW_AUTO_REPAIR=0 or suppressed by PMRW_DRY_RUN=1) — no metadata was changed by this watchdog. A human/Mayor should confirm the intended route (commonly derivable from an existing crew/<name>/<bead> branch owner, or wa-worker/ps-worker/dog for pool-eligible work) and set gc.routed_to to un-strand this bead."
    fi
    if [ -n "${PMRW_TEST_COMMENTS_LOG:-}" ]; then
      echo "comment:${bid}" >> "$PMRW_TEST_COMMENTS_LOG" 2>/dev/null || true
    else
      printf '%s' "$msg" | "$BD_BIN" -C "$store2" comment "$bid" --stdin 2>/dev/null || log "WARN: bd comment failed for $bid"
    fi
  done < <(printf '%b' "$to_alert_tsv")

  # ── aggregate notify + mail ─────────────────────────────────────────────
  local unchanged_count=$(( total_flagged - new_count ))
  local summary="ARMED BUT UNROUTED: ${new_count} new/due, ${resolved_count} resolved, ${unchanged_count} unchanged-already-reported — ${total_flagged} total currently flagged (>=${PMRW_GRACE_MINUTES}min old)."

  if [ -n "${PMRW_TEST_NOTIFIED:-}" ]; then
    echo "notify:$summary" >> "$PMRW_TEST_NOTIFIED" 2>/dev/null || true
  else
    command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
      "${NOTIFY_BIN}" -t "Pilot: armed bead(s) missing route" -p "${PMRW_NOTIFY_PRIORITY}" "$summary" 2>/dev/null || true
  fi

  local mail_body
  if [ "$_pmrw_repair_was_active" = "1" ]; then
    mail_body="PILOT MISSING-ROUTE WATCHDOG — auto-repair report (ga-f54ui/ga-9tgos). Every bead below already had a failed/unverified repair attempt.

${summary}
"
  else
    mail_body="PILOT MISSING-ROUTE WATCHDOG — detection-only report (ga-f54ui).

${summary}
"
  fi
  if [ "${new_count:-0}" -gt 0 ]; then
    local new_lines; new_lines="$(printf '%b' "$to_alert_tsv" | while IFS=$'\t' read -r bid store2 age_min labels btype; do
      [ -z "${bid:-}" ] && continue
      echo "  ${bid}  ($(_store_name "$store2"), ${btype})  age=${age_min}min  labels=[${labels}]"
    done)"
    mail_body="${mail_body}
NEW/DUE (${new_count}) — why this cycle alerted:
${new_lines}
"
  fi
  if [ "${resolved_count:-0}" -gt 0 ]; then
    local resolved_lines; resolved_lines="$(printf '%s' "$resolved_ids_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r rid; do
      [ -z "${rid:-}" ] && continue
      echo "  ${rid}  (routed, closed, no longer armed, or gone)"
    done)"
    mail_body="${mail_body}
RESOLVED (${resolved_count}) since last alert:
${resolved_lines}
"
  fi
  if [ "${unchanged_count:-0}" -gt 0 ]; then
    mail_body="${mail_body}
+${unchanged_count} already reported previously, unchanged — see the log for the full current list.
"
  fi
  if [ "$_pmrw_repair_was_active" = "1" ]; then
    mail_body="${mail_body}
AUTO-REPAIR (ga-9tgos) was ACTIVE this sweep: every bead listed above already
had a write+verify repair attempt (up to ${PMRW_REPAIR_MAX_ATTEMPTS} tries)
that did NOT verifiably stick before being reported here — this is the
residual AFTER repair, not a detection-only list."
    if [ "${repaired_count:-0}" -gt 0 ]; then
      mail_body="${mail_body} ${repaired_count} other bead(s) this
sweep WERE successfully self-healed and are intentionally not listed above
(each carries its own 'SELF-HEALED' comment; see the log for the full
repaired list)."
    fi
  else
    mail_body="${mail_body}
This is DETECTION-ONLY this sweep (PMRW_AUTO_REPAIR=0 or PMRW_DRY_RUN=1) — no
gc.routed_to was set on any bead by this watchdog."
  fi
  mail_body="${mail_body}
Per-bead detail for NEW/DUE beads is also posted as a comment on each bead.
Re-alerts for an already-flagged bead are suppressed for ${PMRW_ALERT_COOLDOWN_S}s
(state: ${STATE_FILE}). Full current list always in the log: ${LOG}"

  if [ -n "${PMRW_TEST_MAILED:-}" ]; then
    { echo "mail:pilot-missing-route:$summary"; printf '%s\n' "$mail_body"; } >> "$PMRW_TEST_MAILED" 2>/dev/null || true
  else
    command -v "$GC_BIN" >/dev/null 2>&1 && \
      "$GC_BIN" mail send mayor \
        -s "Watchdog: ${total_flagged} armed bead(s) missing gc.routed_to (invisible to pool dispatch)" \
        -m "$mail_body" 2>/dev/null || true
  fi

  mkdir -p "$PMRW_STATE_DIR" 2>/dev/null || true
  printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true

  return 1
}

# ── selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${PMRW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  PMRW_TEST_MODE=1
  LOG="$TMP/pmrw.log"
  NOTIFY_BIN="$TMP/notify"
  GC_BIN="$TMP/gc"
  BD_BIN="$TMP/bd"
  PMRW_ENABLED=1
  PMRW_DRY_RUN=0
  PMRW_GRACE_MINUTES=10
  PMRW_ALERT_COOLDOWN_S=21600
  # ga-9tgos: repair defaults to ON in production (matches PMRW_AUTO_REPAIR's
  # own default), but with retry sleep forced to 0 here — a real 1s-per-
  # attempt sleep would otherwise add many real seconds across the dozens of
  # scenarios below that now also exercise the (by-default-failing, see the
  # bd stub's `update)` case) repair path before falling through to alert.
  PMRW_AUTO_REPAIR=1
  PMRW_REPAIR_MAX_ATTEMPTS=3
  PMRW_REPAIR_RETRY_SLEEP_S=0
  PMRW_STATE_DIR="$TMP/state"
  STATE_FILE="$TMP/state/pmrw.state.json"
  HQ="$TMP/hq"
  STORE_A="$TMP/store-a"
  STORE_B="$TMP/store-b"
  PMRW_STORES="$STORE_A $STORE_B"

  mkdir -p "$TMP/fixtures-a" "$TMP/fixtures-b" "$PMRW_STATE_DIR"

  # Fake bd: routes on the -C store path AND verb, since this script queries
  # MULTIPLE stores and each needs its own independent fixture + failure mode.
  cat > "$BD_BIN" <<'BDSTUB'
#!/usr/bin/env bash
store=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-C" ]; then store="${args[$((i+1))]}"; fi
done
verb="$3"
storekey=$(basename "$store")
case "$verb" in
  list)
    if [ "${args[3]:-}" = "--id" ]; then
      # recheck form: bd -C <store> list --id <id> --all --json
      idval="${args[4]:-}"
      f="$PMRW_TEST_RECHECK_DIR/${storekey}-${idval}.json"
      if [ -f "$f" ]; then
        if grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
          echo "simulated bd failure: connection refused" >&2
          exit 1
        fi
        cat "$f"
      else
        # ga-9tgos: no DEDICATED recheck fixture for this id — fall back to
        # reflecting the id's current entry in the MAIN store fixture,
        # rather than unconditionally "[]" (which _bead_recheck_status reads
        # as "gone"). Realistic default: a recheck against the SAME live
        # store should normally see the SAME thing the main sweep just saw,
        # unless a scenario explicitly seeds a dedicated recheck fixture to
        # simulate drift between sweeps (scenarios 13/14/33/34/35 already
        # do this and are unaffected — this fallback only fires in the
        # absent case). Without this, every scenario whose bead now also
        # goes through the repair path (any "flagged" scenario, since
        # repair is attempted before every alert) would read as "gone" on
        # its FIRST verify call and be wrongly treated as already-resolved.
        mainf="$PMRW_TEST_FIXTURES_DIR/${storekey}.json"
        if [ -f "$mainf" ] && ! grep -qx '__BD_FAIL__' "$mainf" 2>/dev/null; then
          jq -c --arg id "$idval" '[.[] | select(.id==$id)]' "$mainf" 2>/dev/null || echo "[]"
        else
          echo "[]"
        fi
      fi
    elif { sbid=""; for ((j=0; j<${#args[@]}; j++)); do
             if [ "${args[$j]}" = "-l" ] && [[ "${args[$((j+1))]:-}" == source-bead:* ]]; then
               sbid="${args[$((j+1))]#source-bead:}"; break
             fi
           done; [ -n "$sbid" ]; }; then
      # gate-artifact-probe form: bd -C <store> list [--include-infra] -l
      # "source-bead:<id>" --json. Scans the FULL args array for "-l
      # source-bead:*" instead of assuming a fixed position — a fixed-index
      # check (was: args[3]/args[4]) broke the instant the real caller
      # gained a flag (--include-infra) ahead of -l (ga-vm20x).
      f="$PMRW_TEST_GATEPROBE_DIR/${sbid}.json"
      [ -f "$f" ] && cat "$f" || echo "[]"
    else
      f="$PMRW_TEST_FIXTURES_DIR/${storekey}.json"
      if [ -f "$f" ] && grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
        echo "simulated bd failure: connection refused" >&2
        exit 1
      fi
      [ -f "$f" ] && cat "$f" || echo "[]"
    fi
    ;;
  comment)
    bid="$4"
    echo "comment:${bid}" >> "${PMRW_TEST_COMMENTS_LOG:-/dev/null}"
    ;;
  update)
    # ga-9tgos: bd -C <store> update <id> --set-metadata k=v -q — the ONLY
    # form _pmrw_repair_route() calls. Tracked unconditionally (even when
    # PMRW_TEST_REPAIR_FAILCOUNT_DIR isn't set) so a kill-switch scenario can
    # assert ZERO update calls were even attempted.
    bid="$4"
    echo "update:${bid}" >> "${PMRW_TEST_UPDATE_CALLS_LOG:-/dev/null}"
    kv=""
    for ((i=0; i<${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--set-metadata" ]; then kv="${args[$((i+1))]}"; fi
    done
    key="${kv%%=*}"; val="${kv#*=}"
    # Default behavior (no failcount fixture seeded for this store+id): a
    # SILENT NO-OP — the CLI still exits 0, but the write never persists.
    # This mirrors this bug's own worst-case, measured signature ("todas as
    # escritas sairam com exit 0. Ninguem soube que perdeu.") and is
    # deliberately the DEFAULT so every EXISTING selftest scenario (written
    # before repair existed) keeps exercising the OLD alert-path outcome
    # unchanged — repair is attempted, silently fails every time by default,
    # falls through to alert exactly as before. Scenarios that want to
    # exercise a SUCCESSFUL (immediate or after-N-retries) repair opt in
    # explicitly via a countdown file at
    # PMRW_TEST_REPAIR_FAILCOUNT_DIR/<storekey>-<id> containing the number
    # of times to keep failing before succeeding (0 = succeed immediately).
    persist=0
    if [ -n "${PMRW_TEST_REPAIR_FAILCOUNT_DIR:-}" ] && [ -n "$key" ]; then
      fcfile="$PMRW_TEST_REPAIR_FAILCOUNT_DIR/${storekey}-${bid}"
      if [ -f "$fcfile" ]; then
        n="$(cat "$fcfile" 2>/dev/null || echo 0)"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        if [ "$n" -le 0 ]; then
          persist=1
        else
          echo $((n - 1)) > "$fcfile"
        fi
      fi
    fi
    if [ "$persist" = "1" ]; then
      base="$PMRW_TEST_RECHECK_DIR/${storekey}-${bid}.json"
      cur=""
      if [ -f "$base" ] && ! grep -qx '__BD_FAIL__' "$base" 2>/dev/null; then
        cur="$(jq -c '.[0] // empty' "$base" 2>/dev/null)"
      fi
      if [ -z "$cur" ]; then
        mainf="$PMRW_TEST_FIXTURES_DIR/${storekey}.json"
        [ -f "$mainf" ] && cur="$(jq -c --arg id "$bid" '[.[] | select(.id==$id)][0] // empty' "$mainf" 2>/dev/null)"
      fi
      [ -z "$cur" ] && cur="{\"id\":\"${bid}\",\"status\":\"open\",\"labels\":[\"ctx:ready\",\"exec:auto\"],\"issue_type\":\"bug\",\"metadata\":{}}"
      printf '[%s]' "$(printf '%s' "$cur" | jq -c --arg k "$key" --arg v "$val" '.metadata[$k] = $v')" > "$base"
    fi
    ;;
  *) echo "[]" ;;
esac
BDSTUB
  chmod +x "$BD_BIN"
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$PMRW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$NOTIFY_BIN"
  printf '#!/usr/bin/env bash\n[ "$1" = "mail" ] && echo "mail:$*" >> "$PMRW_TEST_MAILED" 2>/dev/null; exit 0\n' > "$GC_BIN"
  chmod +x "$NOTIFY_BIN" "$GC_BIN"

  export PMRW_TEST_FIXTURES_DIR="$TMP/fixtures"
  export PMRW_TEST_RECHECK_DIR="$TMP/recheck"
  export PMRW_TEST_GATEPROBE_DIR="$TMP/gateprobe"
  export PMRW_TEST_REPAIR_FAILCOUNT_DIR="$TMP/repair-failcount"
  mkdir -p "$PMRW_TEST_FIXTURES_DIR" "$PMRW_TEST_RECHECK_DIR" "$PMRW_TEST_GATEPROBE_DIR" "$PMRW_TEST_REPAIR_FAILCOUNT_DIR"

  OLD_TS="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  FRESH_TS="$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
  # ga-hhj7u: epoch (not ISO) timestamps for pilot.dispatched_at fixtures —
  # a separate concept from the updated_at/created_at aging above.
  DISPATCH_RECENT_EPOCH=$(( $(date +%s) - 1800 ))    # 30min ago — within the 240min default window
  DISPATCH_OLD_EPOCH=$(( $(date +%s) - 18000 ))      # 5h ago — past the 240min default window

  mk() {  # id status labels_csv updated_at [metadata_json] [created_by]
    local id="$1" status="$2" labels="$3" updated="$4" meta="${5:-}" created_by="${6:-}"
    [ -z "$meta" ] && meta='{}'
    local labels_json; labels_json="$(printf '%s' "$labels" | tr ',' '\n' | jq -R . | jq -s -c .)"
    printf '{"id":"%s","status":"%s","updated_at":"%s","labels":%s,"issue_type":"bug","metadata":%s,"created_by":"%s"}' \
      "$id" "$status" "$updated" "$labels_json" "$meta" "$created_by"
  }
  reset_stores() {
    echo '[]' > "$TMP/fixtures/store-a.json"
    echo '[]' > "$TMP/fixtures/store-b.json"
    rm -f "$STATE_FILE" 2>/dev/null
  }

  # ── Scenario 1: armed + unrouted + aged, store-a → FLAGGED ────────────────
  echo "Scenario 1: armed (ctx:ready+exec:auto), no gc.routed_to, aged → flagged"
  reset_stores
  printf '[%s]' "$(mk ga-1 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N1="$TMP/notif1"; M1="$TMP/mail1"; C1="$TMP/comm1"; : > "$N1"; : > "$M1"; : > "$C1"
  PMRW_TEST_NOTIFIED="$N1" PMRW_TEST_MAILED="$M1" PMRW_TEST_COMMENTS_LOG="$C1" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 1: flagged (return 1)" || bad "scenario 1: should return 1 (flagged), got $rc"
  grep -q "comment:ga-1" "$C1" 2>/dev/null && ok "scenario 1: bd comment posted (via --stdin)" || bad "scenario 1: no comment posted"
  grep -q "notify:" "$N1" 2>/dev/null && ok "scenario 1: notify fired" || bad "scenario 1: notify did NOT fire"
  grep -q "mail:" "$M1" 2>/dev/null && ok "scenario 1: mayor mailed" || bad "scenario 1: mayor NOT mailed"

  # ── Scenario 2 (core ACEITE requirement): armed + ROUTED → NEVER flags ────
  echo "Scenario 2: armed AND gc.routed_to set → NOT flagged, even though old"
  reset_stores
  printf '[%s]' "$(mk ga-2 open 'ctx:ready,exec:auto' "$OLD_TS" '{"gc.routed_to":"wa-worker"}')" > "$TMP/fixtures/store-a.json"
  N2="$TMP/notif2"; M2="$TMP/mail2"; C2="$TMP/comm2"; : > "$N2"; : > "$M2"; : > "$C2"
  PMRW_TEST_NOTIFIED="$N2" PMRW_TEST_MAILED="$M2" PMRW_TEST_COMMENTS_LOG="$C2" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 2: routed bead never flags (return 0)" || bad "scenario 2: a routed bead must not flag, got $rc"
  [ ! -s "$C2" ] && ok "scenario 2: no comment posted" || bad "scenario 2 (false positive): comment posted on a routed bead"

  # ── Scenario 3: armed + unrouted but too FRESH → NOT flagged yet ─────────
  echo "Scenario 3: unrouted, only 1min old → NOT flagged (below grace)"
  reset_stores
  printf '[%s]' "$(mk ga-3 open 'ctx:ready,exec:auto' "$FRESH_TS")" > "$TMP/fixtures/store-a.json"
  N3="$TMP/notif3"; M3="$TMP/mail3"; C3="$TMP/comm3"; : > "$N3"; : > "$M3"; : > "$C3"
  PMRW_TEST_NOTIFIED="$N3" PMRW_TEST_MAILED="$M3" PMRW_TEST_COMMENTS_LOG="$C3" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 3: fresh bead not yet flagged (return 0)" || bad "scenario 3: should not flag within grace, got $rc"
  [ ! -s "$C3" ] && ok "scenario 3: no comment (still in grace)" || bad "scenario 3: comment posted before grace elapsed"

  # ── Scenario 4: CLOSED + unrouted → never touched ─────────────────────────
  echo "Scenario 4: closed bead, unrouted → never touched (defense-in-depth)"
  reset_stores
  printf '[%s]' "$(mk ga-4 closed 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N4="$TMP/notif4"; M4="$TMP/mail4"; C4="$TMP/comm4"; : > "$N4"; : > "$M4"; : > "$C4"
  PMRW_TEST_NOTIFIED="$N4" PMRW_TEST_MAILED="$M4" PMRW_TEST_COMMENTS_LOG="$C4" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 4: closed bead ignored (return 0)" || bad "scenario 4: closed bead must never flag, got $rc"
  [ ! -s "$C4" ] && ok "scenario 4: no comment on closed bead" || bad "scenario 4 (ACEITE violation): commented on a CLOSED bead"

  # ── Scenario 5: only ONE of ctx:ready/exec:auto present → NOT armed ───────
  echo "Scenario 5: only exec:auto (no ctx:ready) → not considered armed, not flagged"
  reset_stores
  printf '[%s]' "$(mk ga-5 open 'exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N5="$TMP/notif5"; M5="$TMP/mail5"; C5="$TMP/comm5"; : > "$N5"; : > "$M5"; : > "$C5"
  PMRW_TEST_NOTIFIED="$N5" PMRW_TEST_MAILED="$M5" PMRW_TEST_COMMENTS_LOG="$C5" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5: half-armed bead not flagged (return 0)" || bad "scenario 5: needs BOTH labels, got $rc"

  # ── Scenario 6: gate:needs-human* → excluded ──────────────────────────────
  echo "Scenario 6: armed+unrouted+aged but gate:needs-human-decision → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-6 open 'ctx:ready,exec:auto,gate:needs-human-decision' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N6="$TMP/notif6"; M6="$TMP/mail6"; C6="$TMP/comm6"; : > "$N6"; : > "$M6"; : > "$C6"
  PMRW_TEST_NOTIFIED="$N6" PMRW_TEST_MAILED="$M6" PMRW_TEST_COMMENTS_LOG="$C6" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 6: gate:needs-human* excluded (return 0)" || bad "scenario 6: needs-human bead should be excluded, got $rc"

  # ── Scenario 7: pilot:held (unexpired, no held-until) → excluded ─────────
  echo "Scenario 7: pilot:held with no held-until label → still held → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-7 open 'ctx:ready,exec:auto,pilot:held' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N7="$TMP/notif7"; M7="$TMP/mail7"; C7="$TMP/comm7"; : > "$N7"; : > "$M7"; : > "$C7"
  PMRW_TEST_NOTIFIED="$N7" PMRW_TEST_MAILED="$M7" PMRW_TEST_COMMENTS_LOG="$C7" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 7: unexpired pilot:held excluded (return 0)" || bad "scenario 7: held bead should be excluded, got $rc"

  # ── Scenario 8: pilot:held-until EXPIRED → no longer excluded ────────────
  echo "Scenario 8: pilot:held but held-until already in the past → eligible again"
  reset_stores
  printf '[%s]' "$(mk ga-8 open 'ctx:ready,exec:auto,pilot:held,pilot:held-until:1000000000' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N8="$TMP/notif8"; M8="$TMP/mail8"; C8="$TMP/comm8"; : > "$N8"; : > "$M8"; : > "$C8"
  PMRW_TEST_NOTIFIED="$N8" PMRW_TEST_MAILED="$M8" PMRW_TEST_COMMENTS_LOG="$C8" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 8: expired hold no longer excludes (return 1, flagged)" || bad "scenario 8: expired hold should flag, got $rc"

  # ── Scenario 9: epic → excluded ───────────────────────────────────────────
  echo "Scenario 9: issue_type=epic, armed+unrouted+aged → excluded"
  reset_stores
  printf '[{"id":"ga-9","status":"open","updated_at":"%s","labels":["ctx:ready","exec:auto"],"issue_type":"epic","metadata":{}}]' "$OLD_TS" > "$TMP/fixtures/store-a.json"
  N9="$TMP/notif9"; M9="$TMP/mail9"; C9="$TMP/comm9"; : > "$N9"; : > "$M9"; : > "$C9"
  PMRW_TEST_NOTIFIED="$N9" PMRW_TEST_MAILED="$M9" PMRW_TEST_COMMENTS_LOG="$C9" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 9: epic excluded (return 0)" || bad "scenario 9: epic should be excluded, got $rc"

  # ── Scenario 10: graph.v2 step (gc.root_bead_id set) → excluded ──────────
  echo "Scenario 10: graph.v2 formula step (gc.root_bead_id) → excluded (different dispatch mechanism)"
  reset_stores
  printf '[%s]' "$(mk ga-10 open 'ctx:ready,exec:auto' "$OLD_TS" '{"gc.root_bead_id":"ga-root1"}')" > "$TMP/fixtures/store-a.json"
  N10="$TMP/notif10"; M10="$TMP/mail10"; C10="$TMP/comm10"; : > "$N10"; : > "$M10"; : > "$C10"
  PMRW_TEST_NOTIFIED="$N10" PMRW_TEST_MAILED="$M10" PMRW_TEST_COMMENTS_LOG="$C10" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 10: graph.v2 step excluded (return 0)" || bad "scenario 10: graph.v2 step should be excluded, got $rc"

  # ── Scenario 11: pilot.sling_for wrapper bead → excluded ──────────────────
  echo "Scenario 11: Pilot-created sling wrapper (pilot.sling_for set) → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-11 open 'ctx:ready,exec:auto' "$OLD_TS" '{"pilot.sling_for":"ga-parent"}')" > "$TMP/fixtures/store-a.json"
  N11="$TMP/notif11"; M11="$TMP/mail11"; C11="$TMP/comm11"; : > "$N11"; : > "$M11"; : > "$C11"
  PMRW_TEST_NOTIFIED="$N11" PMRW_TEST_MAILED="$M11" PMRW_TEST_COMMENTS_LOG="$C11" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 11: sling wrapper excluded (return 0)" || bad "scenario 11: sling wrapper should be excluded, got $rc"

  # ── Scenario 12: cooldown suppresses re-alert on second sweep ────────────
  echo "Scenario 12: same bead flagged twice in a row within cooldown → only FIRST sweep alerts"
  reset_stores
  printf '[%s]' "$(mk ga-12 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N12a="$TMP/notif12a"; M12a="$TMP/mail12a"; C12a="$TMP/comm12a"; : > "$N12a"; : > "$M12a"; : > "$C12a"
  PMRW_TEST_NOTIFIED="$N12a" PMRW_TEST_MAILED="$M12a" PMRW_TEST_COMMENTS_LOG="$C12a" run_sweep >/dev/null
  grep -q "comment:ga-12" "$C12a" 2>/dev/null && ok "scenario 12: first sweep alerts" || bad "scenario 12: first sweep should alert"
  N12b="$TMP/notif12b"; M12b="$TMP/mail12b"; C12b="$TMP/comm12b"; : > "$N12b"; : > "$M12b"; : > "$C12b"
  PMRW_TEST_NOTIFIED="$N12b" PMRW_TEST_MAILED="$M12b" PMRW_TEST_COMMENTS_LOG="$C12b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 12: second sweep still reports flagged (return 1)" || bad "scenario 12: still-broken bead should still return 1, got $rc"
  [ ! -s "$C12b" ] && ok "scenario 12: second sweep does NOT re-comment (cooldown)" || bad "scenario 12: cooldown did not suppress re-comment"

  # ── Scenario 13: resolution — gc.routed_to added between sweeps → RESOLVED
  echo "Scenario 13: gc.routed_to added between sweeps → RESOLVED, pruned, individually rechecked"
  reset_stores
  printf '[%s]' "$(mk ga-13 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  : > "$TMP/notif13a"; : > "$TMP/mail13a"; : > "$TMP/comm13a"
  PMRW_TEST_NOTIFIED="$TMP/notif13a" PMRW_TEST_MAILED="$TMP/mail13a" PMRW_TEST_COMMENTS_LOG="$TMP/comm13a" run_sweep >/dev/null
  grep -q '"ga-13"' "$STATE_FILE" 2>/dev/null && ok "scenario 13: ga-13 tracked in state after first sweep" || bad "scenario 13: ga-13 should be tracked after first sweep"
  echo '[]' > "$TMP/fixtures/store-a.json"   # simulates: no longer matches the query (route now set)
  printf '[%s]' "$(mk ga-13 open 'ctx:ready,exec:auto' "$OLD_TS" '{"gc.routed_to":"wa-worker"}')" > "$TMP/recheck/store-a-ga-13.json"
  : > "$LOG"
  : > "$TMP/notif13b"; : > "$TMP/mail13b"; : > "$TMP/comm13b"
  PMRW_TEST_NOTIFIED="$TMP/notif13b" PMRW_TEST_MAILED="$TMP/mail13b" PMRW_TEST_COMMENTS_LOG="$TMP/comm13b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 13: sweep reports resolution activity (return 1)" || bad "scenario 13: a resolution should still be reported, got $rc"
  grep -q '"ga-13"' "$STATE_FILE" 2>/dev/null && bad "scenario 13: ga-13 still in state after being resolved" || ok "scenario 13: ga-13 pruned from state"
  grep -q "RESOLVED: ga-13 re-checked individually (routed)" "$LOG" 2>/dev/null && ok "scenario 13: RESOLVED(routed) logged for ga-13" || bad "scenario 13: no RESOLVED(routed) log line for ga-13"

  # ── Scenario 14: recheck query FAILS → stays UNVERIFIED, not wrongly resolved
  echo "Scenario 14: bead vanishes from sweep AND its individual recheck query fails → stays in state (fail-safe)"
  reset_stores
  printf '[%s]' "$(mk ga-14 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  : > "$TMP/notif14a"; : > "$TMP/mail14a"; : > "$TMP/comm14a"
  PMRW_TEST_NOTIFIED="$TMP/notif14a" PMRW_TEST_MAILED="$TMP/mail14a" PMRW_TEST_COMMENTS_LOG="$TMP/comm14a" run_sweep >/dev/null
  grep -q '"ga-14"' "$STATE_FILE" 2>/dev/null && ok "scenario 14: ga-14 tracked after first sweep" || bad "scenario 14: ga-14 should be tracked after first sweep"
  echo '[]' > "$TMP/fixtures/store-a.json"
  echo '__BD_FAIL__' > "$TMP/recheck/store-a-ga-14.json"
  : > "$LOG"
  : > "$TMP/notif14b"; : > "$TMP/mail14b"; : > "$TMP/comm14b"
  PMRW_TEST_NOTIFIED="$TMP/notif14b" PMRW_TEST_MAILED="$TMP/mail14b" PMRW_TEST_COMMENTS_LOG="$TMP/comm14b" run_sweep
  grep -q '"ga-14"' "$STATE_FILE" 2>/dev/null && ok "scenario 14: ga-14 STILL in state (fail-safe, not wrongly resolved)" || bad "scenario 14 (ga-p5q3 violation): ga-14 pruned despite a failed recheck"
  grep -q "UNVERIFIED: ga-14 re-check query failed" "$LOG" 2>/dev/null && ok "scenario 14: UNVERIFIED logged" || bad "scenario 14: no UNVERIFIED log line"

  # ── Scenario 15: multi-store — store A fails, store B still swept ─────────
  echo "Scenario 15: store-a query fails, store-b has a real finding → store-b still flagged (per-store fail-open)"
  reset_stores
  echo '__BD_FAIL__' > "$TMP/fixtures/store-a.json"
  printf '[%s]' "$(mk wa-15 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-b.json"
  : > "$LOG"
  N15="$TMP/notif15"; M15="$TMP/mail15"; C15="$TMP/comm15"; : > "$N15"; : > "$M15"; : > "$C15"
  PMRW_TEST_NOTIFIED="$N15" PMRW_TEST_MAILED="$M15" PMRW_TEST_COMMENTS_LOG="$C15" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 15: store-b finding still flagged despite store-a failure (return 1)" || bad "scenario 15: store-b should still flag, got $rc"
  grep -q "comment:wa-15" "$C15" 2>/dev/null && ok "scenario 15: comment posted for store-b bead" || bad "scenario 15: no comment for store-b bead"
  grep -q "WARN.*store-a.*fail-open" "$LOG" 2>/dev/null && ok "scenario 15: WARN logged for failed store-a" || bad "scenario 15: no WARN for store-a failure"

  # ── Scenario 16: dry-run → detects but does not mutate/alert/persist ─────
  echo "Scenario 16: PMRW_DRY_RUN=1 → logs the finding, fires nothing, persists nothing"
  reset_stores
  printf '[%s]' "$(mk ga-16 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N16="$TMP/notif16"; M16="$TMP/mail16"; C16="$TMP/comm16"; : > "$N16"; : > "$M16"; : > "$C16"
  PMRW_DRY_RUN=1 PMRW_TEST_NOTIFIED="$N16" PMRW_TEST_MAILED="$M16" PMRW_TEST_COMMENTS_LOG="$C16" run_sweep
  rc=$?
  PMRW_DRY_RUN=0
  [ "$rc" -eq 1 ] && ok "scenario 16: dry-run still reports flagged (return 1)" || bad "scenario 16: dry-run should still report flagged, got $rc"
  [ ! -s "$C16" ] && [ ! -s "$N16" ] && [ ! -s "$M16" ] && ok "scenario 16: no comment/notify/mail fired in dry-run" || bad "scenario 16: dry-run must not fire any side effect"
  [ ! -f "$STATE_FILE" ] && ok "scenario 16: no state file written in dry-run" || bad "scenario 16: dry-run must not persist state"

  # ── Scenario 17: kill-switch → complete no-op ─────────────────────────────
  echo "Scenario 17: PMRW_ENABLED=0 → complete no-op"
  reset_stores
  printf '[%s]' "$(mk ga-17 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N17="$TMP/notif17"; M17="$TMP/mail17"; C17="$TMP/comm17"; : > "$N17"; : > "$M17"; : > "$C17"
  PMRW_ENABLED=0 PMRW_TEST_NOTIFIED="$N17" PMRW_TEST_MAILED="$M17" PMRW_TEST_COMMENTS_LOG="$C17" run_sweep
  rc=$?
  PMRW_ENABLED=1
  [ "$rc" -eq 0 ] && ok "scenario 17: kill-switch returns 0" || bad "scenario 17: kill-switch should return 0, got $rc"
  [ ! -s "$C17" ] && [ ! -s "$N17" ] && [ ! -s "$M17" ] && ok "scenario 17: no side effect while disabled" || bad "scenario 17: disabled watchdog fired a side effect"

  # ── Scenario 19: story:* label → excluded (separate tier-2 dispatch path) ─
  echo "Scenario 19: story:approved present → excluded (managed by the feature tier, not this bug)"
  reset_stores
  printf '[%s]' "$(mk ga-19 open 'ctx:ready,exec:auto,story:approved' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N19="$TMP/notif19"; M19="$TMP/mail19"; C19="$TMP/comm19"; : > "$N19"; : > "$M19"; : > "$C19"
  PMRW_TEST_NOTIFIED="$N19" PMRW_TEST_MAILED="$M19" PMRW_TEST_COMMENTS_LOG="$C19" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 19: story:* excluded (return 0)" || bad "scenario 19: story:* bead should be excluded, got $rc"

  # ── Scenario 20: pilot:refusal-count:* → excluded (already parked) ───────
  echo "Scenario 20: pilot:refusal-count:1 present → excluded (already explicitly refused/parked)"
  reset_stores
  printf '[%s]' "$(mk ga-20 open 'ctx:ready,exec:auto,pilot:refusal-count:1,pilot:refused-reason:some-reason' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N20="$TMP/notif20"; M20="$TMP/mail20"; C20="$TMP/comm20"; : > "$N20"; : > "$M20"; : > "$C20"
  PMRW_TEST_NOTIFIED="$N20" PMRW_TEST_MAILED="$M20" PMRW_TEST_COMMENTS_LOG="$C20" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 20: refusal-count excluded (return 0)" || bad "scenario 20: refused bead should be excluded, got $rc"

  # ── Scenario 21: needs:engine-window / framework:engine / no-auto-dispatch → excluded
  echo "Scenario 21: needs:engine-window + no-auto-dispatch present → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-21 open 'ctx:ready,exec:auto,needs:engine-window,no-auto-dispatch' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N21="$TMP/notif21"; M21="$TMP/mail21"; C21="$TMP/comm21"; : > "$N21"; : > "$M21"; : > "$C21"
  PMRW_TEST_NOTIFIED="$N21" PMRW_TEST_MAILED="$M21" PMRW_TEST_COMMENTS_LOG="$C21" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 21: engine-window/no-auto-dispatch excluded (return 0)" || bad "scenario 21: should be excluded, got $rc"

  echo "Scenario 21b: framework:engine alone (no needs:engine-window) → also excluded"
  reset_stores
  printf '[%s]' "$(mk ga-21b open 'ctx:ready,exec:auto,framework:engine' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N21b="$TMP/notif21b"; M21b="$TMP/mail21b"; C21b="$TMP/comm21b"; : > "$N21b"; : > "$M21b"; : > "$C21b"
  PMRW_TEST_NOTIFIED="$N21b" PMRW_TEST_MAILED="$M21b" PMRW_TEST_COMMENTS_LOG="$C21b" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 21b: framework:engine excluded (return 0)" || bad "scenario 21b: framework:engine bead should be excluded, got $rc"

  # ── Scenario 22: ACTIVE gate marker in flight → excluded ─────────────────
  echo "Scenario 22: armed+unrouted+aged, but an OPEN gate marker with gate-status:reviewing already names it as source-bead → excluded (already dispatched+built+submitted)"
  reset_stores
  printf '[%s]' "$(mk ga-22 open 'ctx:ready,exec:auto,gate:queued' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  printf '[{"id":"ga-wisp-x","status":"open","labels":["type:quality-gate-marker","gate-status:reviewing","source-bead:ga-22"]}]' > "$TMP/gateprobe/ga-22.json"
  N22="$TMP/notif22"; M22="$TMP/mail22"; C22="$TMP/comm22"; : > "$N22"; : > "$M22"; : > "$C22"
  PMRW_TEST_NOTIFIED="$N22" PMRW_TEST_MAILED="$M22" PMRW_TEST_COMMENTS_LOG="$C22" run_sweep
  rc=$?
  rm -f "$TMP/gateprobe/ga-22.json"
  [ "$rc" -eq 0 ] && ok "scenario 22: active gate marker excludes (return 0)" || bad "scenario 22: bead with an active gate marker should be excluded, got $rc"

  # ── Scenario 23 (contrast to 22): STALE gate:* labels but NO active marker
  # → still flagged. This is the case scenario 22 must NOT be allowed to
  # over-exclude: a bead re-armed for retry after a past gate:failed cycle,
  # with the route never restored, is exactly ga-f54ui's own hypothesis and
  # must still be caught. ─────────────────────────────────────────────────
  echo "Scenario 23: stale gate:failed/gate:needs-fix labels but NO active marker for it → still flagged (re-armed-without-route-restore case)"
  reset_stores
  printf '[%s]' "$(mk ga-23 open 'ctx:ready,exec:auto,gate:failed,gate:needs-fix,gate:fix-attempt:2' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  # no gateprobe fixture for ga-23 → probe returns "[]" → 0 active → not excluded
  N23="$TMP/notif23"; M23="$TMP/mail23"; C23="$TMP/comm23"; : > "$N23"; : > "$M23"; : > "$C23"
  PMRW_TEST_NOTIFIED="$N23" PMRW_TEST_MAILED="$M23" PMRW_TEST_COMMENTS_LOG="$C23" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 23: stale gate:* labels without an active marker still flags (return 1)" || bad "scenario 23 (would hide a real re-arm case): got $rc"
  grep -q "comment:ga-23" "$C23" 2>/dev/null && ok "scenario 23: comment posted despite stale gate:* labels" || bad "scenario 23: no comment — over-excluded on label residue alone"

  # ── Scenario 25: blocked-on:* → excluded even though status is still "open"
  echo "Scenario 25: blocked-on:<other-bead> present, status still open → excluded (explicit dependency marker, live wa-v66xt shape)"
  reset_stores
  printf '[%s]' "$(mk ga-25 open 'ctx:ready,exec:auto,blocked-on:ga-other' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N25="$TMP/notif25"; M25="$TMP/mail25"; C25="$TMP/comm25"; : > "$N25"; : > "$M25"; : > "$C25"
  PMRW_TEST_NOTIFIED="$N25" PMRW_TEST_MAILED="$M25" PMRW_TEST_COMMENTS_LOG="$C25" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 25: blocked-on excluded (return 0)" || bad "scenario 25: blocked-on bead should be excluded, got $rc"

  # ── Scenario 26: bash -n syntax check ──────────────────────────────────────
  echo "Scenario 26: bash -n syntax check"
  bash -n "$0" 2>/dev/null && ok "scenario 26: bash -n passes" || bad "scenario 26: bash -n FAILED — syntax error"

  # ── Scenario 27 (ga-y0g5x): single-instance lock — two REAL concurrent
  # invocations of the actual script ENTRY POINT (the lock guards the entry
  # point, not the run_sweep function, so this must fire real subprocesses —
  # a background `&` job is a genuine separate OS process — not call
  # run_sweep in-process like every scenario above). AC: the second run must
  # exit without working AND without alarming (no comment/notify/mail — not
  # exercised here beyond "did it even reach run_sweep", which the other
  # scenarios already cover exhaustively for alarm behavior).
  echo "Scenario 27 (ga-y0g5x): two concurrent real invocations — exactly one proceeds, the other backs off silently"
  reset_stores
  LOCKTEST27="$TMP/locktest27"; mkdir -p "$LOCKTEST27/tmp" "$LOCKTEST27/state"
  SHARED_LOG27="$LOCKTEST27/pmrw.log"; : > "$SHARED_LOG27"
  run_pmrw_race27() {
    env -i \
      PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
      HOME="$HOME" \
      TMPDIR="$LOCKTEST27/tmp" \
      PMRW_ENABLED=1 PMRW_LOCK_ENABLED=1 PMRW_DRY_RUN=0 \
      PMRW_TEST_MODE=1 \
      PMRW_HQ="$HQ" \
      PMRW_LOG="$SHARED_LOG27" \
      PMRW_NOTIFY_BIN="$NOTIFY_BIN" \
      PMRW_GC_BIN="$GC_BIN" \
      PMRW_BD_BIN="$BD_BIN" \
      PMRW_STATE_DIR="$LOCKTEST27/state" \
      PMRW_STORES="$STORE_A $STORE_B" \
      PMRW_TEST_FIXTURES_DIR="$PMRW_TEST_FIXTURES_DIR" \
      PMRW_TEST_RECHECK_DIR="$PMRW_TEST_RECHECK_DIR" \
      PMRW_TEST_GATEPROBE_DIR="$PMRW_TEST_GATEPROBE_DIR" \
      bash "$0" >/dev/null 2>&1 || true
  }
  run_pmrw_race27 &
  RP27_1=$!
  run_pmrw_race27 &
  RP27_2=$!
  wait "$RP27_1" "$RP27_2"
  RAN27=$(grep -cE "OK:|FLAGGED:" "$SHARED_LOG27" 2>/dev/null | tr -d ' '); RAN27=${RAN27:-0}
  BACKOFF27=$(grep -c "backing off (single-instance guard" "$SHARED_LOG27" 2>/dev/null | tr -d ' '); BACKOFF27=${BACKOFF27:-0}
  [ "$RAN27" -eq 1 ] && ok "scenario 27: exactly one of two concurrent runs executed the sweep ($RAN27)" || bad "scenario 27: expected exactly 1 run to execute the sweep, got $RAN27 — double-run or zero-run"
  [ "$BACKOFF27" -eq 1 ] && ok "scenario 27: exactly one run backed off on the live lock, silently ($BACKOFF27)" || bad "scenario 27: expected exactly 1 back-off, got $BACKOFF27"
  rm -rf "$LOCKTEST27"

  # ── Scenario 28 (ga-y0g5x): a lock held by a DEAD pid, with a FRESH
  # heartbeat mtime, is reclaimed IMMEDIATELY — proving the reclaim is
  # PID-liveness-gated, not merely age-gated. An age-only check would let a
  # killed run's lock block every future sweep for PMRW_LOCK_MAX_AGE (up to
  # 900s default) — the exact failure mode the bug calls out ("o modo de
  # falha que troca 'sobreposicao' por 'nunca mais roda'").
  echo "Scenario 28 (ga-y0g5x): lock held by a DEAD pid (fresh mtime) is reclaimed immediately, not after MAX_AGE"
  reset_stores
  LOCKTEST28="$TMP/locktest28"; mkdir -p "$LOCKTEST28/tmp"
  LOCK28_DIR="$LOCKTEST28/tmp/pilot-missing-route-watchdog$(printf '%s' "$HQ" | tr '/ ' '__').lock.d"
  mkdir -p "$LOCK28_DIR"
  ( : ) & DEADPID28=$!
  wait "$DEADPID28" 2>/dev/null
  printf '%s:1\n' "$DEADPID28" > "$LOCK28_DIR/heartbeat"   # fresh mtime, dead pid
  LOG28="$LOCKTEST28/pmrw.log"; : > "$LOG28"
  env -i \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    HOME="$HOME" \
    TMPDIR="$LOCKTEST28/tmp" \
    PMRW_ENABLED=1 PMRW_LOCK_ENABLED=1 PMRW_DRY_RUN=0 \
    PMRW_LOCK_MAX_AGE=900 \
    PMRW_TEST_MODE=1 \
    PMRW_HQ="$HQ" \
    PMRW_LOG="$LOG28" \
    PMRW_NOTIFY_BIN="$NOTIFY_BIN" \
    PMRW_GC_BIN="$GC_BIN" \
    PMRW_BD_BIN="$BD_BIN" \
    PMRW_STATE_DIR="$LOCKTEST28/state" \
    PMRW_STORES="$STORE_A $STORE_B" \
    PMRW_TEST_FIXTURES_DIR="$PMRW_TEST_FIXTURES_DIR" \
    PMRW_TEST_RECHECK_DIR="$PMRW_TEST_RECHECK_DIR" \
    PMRW_TEST_GATEPROBE_DIR="$PMRW_TEST_GATEPROBE_DIR" \
    bash "$0" >/dev/null 2>&1
  grep -qE "OK:|FLAGGED:" "$LOG28" 2>/dev/null && ok "scenario 28: dead-pid lock reclaimed immediately, sweep ran" || bad "scenario 28: dead-pid lock blocked the run — a killed holder would wedge the watchdog forever"
  grep -q "Recovered STALE/DEAD lock" "$LOG28" 2>/dev/null && ok "scenario 28: reclaim logged" || bad "scenario 28: no reclaim log line"
  rm -rf "$LOCKTEST28"

  # ── Scenario 29 (ga-y0g5x GATE-FEEDBACK, mirror of 28): a lock held by an
  # ALIVE pid, with a heartbeat mtime backdated PAST PMRW_LOCK_MAX_AGE, must
  # NOT be reclaimed by a second run — proving reclaim is gated on PID
  # liveness alone, never on age. This is the exact case the gate reviewer
  # found unexercised: scenario 28 only proved "dead + fresh mtime →
  # reclaim"; this proves the missing mirror, "alive + stale mtime → NEVER
  # reclaim" — the case where the original bug's fix-attempt-1 broke.
  echo "Scenario 29 (ga-y0g5x GATE-FEEDBACK): lock held by an ALIVE pid with a heartbeat mtime OLDER than MAX_AGE is NEVER reclaimed (age must not override liveness)"
  reset_stores
  LOCKTEST29="$TMP/locktest29"; mkdir -p "$LOCKTEST29/tmp"
  LOCK29_DIR="$LOCKTEST29/tmp/pilot-missing-route-watchdog$(printf '%s' "$HQ" | tr '/ ' '__').lock.d"
  mkdir -p "$LOCK29_DIR"
  sleep 30 & ALIVEPID29=$!
  printf '%s:1\n' "$ALIVEPID29" > "$LOCK29_DIR/heartbeat"
  OLD29="$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null || date -d '20 minutes ago' +%Y%m%d%H%M.%S)"
  touch -t "$OLD29" "$LOCK29_DIR/heartbeat"
  LOG29="$LOCKTEST29/pmrw.log"; : > "$LOG29"
  env -i \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    HOME="$HOME" \
    TMPDIR="$LOCKTEST29/tmp" \
    PMRW_ENABLED=1 PMRW_LOCK_ENABLED=1 PMRW_DRY_RUN=0 \
    PMRW_LOCK_MAX_AGE=900 \
    PMRW_TEST_MODE=1 \
    PMRW_HQ="$HQ" \
    PMRW_LOG="$LOG29" \
    PMRW_NOTIFY_BIN="$NOTIFY_BIN" \
    PMRW_GC_BIN="$GC_BIN" \
    PMRW_BD_BIN="$BD_BIN" \
    PMRW_STATE_DIR="$LOCKTEST29/state" \
    PMRW_STORES="$STORE_A $STORE_B" \
    PMRW_TEST_FIXTURES_DIR="$PMRW_TEST_FIXTURES_DIR" \
    PMRW_TEST_RECHECK_DIR="$PMRW_TEST_RECHECK_DIR" \
    PMRW_TEST_GATEPROBE_DIR="$PMRW_TEST_GATEPROBE_DIR" \
    bash "$0" >/dev/null 2>&1
  kill "$ALIVEPID29" 2>/dev/null; wait "$ALIVEPID29" 2>/dev/null
  grep -qE "OK:|FLAGGED:" "$LOG29" 2>/dev/null && bad "scenario 29: sweep RAN despite a live holder with a stale heartbeat — age wrongly overrode liveness (the exact GATE-FEEDBACK regression)" || ok "scenario 29: sweep did NOT run — live holder protected despite a stale heartbeat"
  grep -q "backing off (single-instance guard" "$LOG29" 2>/dev/null && ok "scenario 29: second run backed off silently, as required" || bad "scenario 29: no back-off log line — second run may not have deferred correctly"
  rm -rf "$LOCKTEST29"

  # ── Scenario 30 (ga-hhj7u): RECENT pilot.dispatched_at, no sling_bead →
  # excluded. The core false-positive this bug reports: a freshly-dispatched
  # chore/task/debt bead legitimately reads armed+unrouted for its whole
  # in-flight duration (route lives on the sling wrapper, not this bead).
  echo "Scenario 30 (ga-hhj7u): armed+unrouted+aged but pilot.dispatched_at RECENT (30min ago) → excluded, not a routing gap"
  reset_stores
  printf '[%s]' "$(mk ga-30 open 'ctx:ready,exec:auto' "$OLD_TS" "$(printf '{"pilot.dispatched_at":"%s"}' "$DISPATCH_RECENT_EPOCH")")" > "$TMP/fixtures/store-a.json"
  N30="$TMP/notif30"; M30="$TMP/mail30"; C30="$TMP/comm30"; : > "$N30"; : > "$M30"; : > "$C30"
  PMRW_TEST_NOTIFIED="$N30" PMRW_TEST_MAILED="$M30" PMRW_TEST_COMMENTS_LOG="$C30" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 30: recent dispatch excluded (return 0)" || bad "scenario 30: recent dispatch should be excluded, got $rc"
  [ ! -s "$C30" ] && ok "scenario 30: no comment posted" || bad "scenario 30 (false positive): comment posted on a recently-dispatched bead"

  # ── Scenario 31 (ga-hhj7u): OLD pilot.dispatched_at → still flags. The
  # bug's own core discriminator: age exonerates nothing — an OLD
  # dispatched_at is aggravating (ga-o9uvc precedent), never exonerating.
  echo "Scenario 31 (ga-hhj7u): pilot.dispatched_at OLD (5h ago, past the 240min window) → still flagged — age is not exonerating"
  reset_stores
  printf '[%s]' "$(mk ga-31 open 'ctx:ready,exec:auto' "$OLD_TS" "$(printf '{"pilot.dispatched_at":"%s"}' "$DISPATCH_OLD_EPOCH")")" > "$TMP/fixtures/store-a.json"
  N31="$TMP/notif31"; M31="$TMP/mail31"; C31="$TMP/comm31"; : > "$N31"; : > "$M31"; : > "$C31"
  PMRW_TEST_NOTIFIED="$N31" PMRW_TEST_MAILED="$M31" PMRW_TEST_COMMENTS_LOG="$C31" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 31: old dispatch still flags (return 1)" || bad "scenario 31: old dispatch should still flag, got $rc"
  grep -q "comment:ga-31" "$C31" 2>/dev/null && ok "scenario 31: comment posted despite dispatched_at being present" || bad "scenario 31: no comment — old dispatched_at wrongly treated as exonerating"

  # ── Scenario 32 (ga-hhj7u): NO pilot.dispatched_at (never dispatched) →
  # still flags. The other real-signal population from the bug's own count
  # (6 of 13: never dispatched, armed and invisible).
  echo "Scenario 32 (ga-hhj7u): no pilot.dispatched_at at all (never dispatched) → still flagged"
  reset_stores
  printf '[%s]' "$(mk ga-32 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N32="$TMP/notif32"; M32="$TMP/mail32"; C32="$TMP/comm32"; : > "$N32"; : > "$M32"; : > "$C32"
  PMRW_TEST_NOTIFIED="$N32" PMRW_TEST_MAILED="$M32" PMRW_TEST_COMMENTS_LOG="$C32" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 32: never-dispatched bead still flags (return 1)" || bad "scenario 32: never-dispatched bead should still flag, got $rc"
  grep -q "comment:ga-32" "$C32" 2>/dev/null && ok "scenario 32: comment posted for never-dispatched bead" || bad "scenario 32: no comment for never-dispatched bead"

  # ── Scenario 33 (ga-hhj7u bonus): RECENT dispatch + sling_bead present +
  # sling still OPEN → still excluded (the override must NOT fire on a
  # merely-open sling, only on a CONFIRMED-closed one).
  echo "Scenario 33 (ga-hhj7u bonus): recent dispatch, sling wrapper present and still OPEN → still excluded"
  reset_stores
  printf '[%s]' "$(mk ga-33 open 'ctx:ready,exec:auto' "$OLD_TS" "$(printf '{"pilot.dispatched_at":"%s","pilot.sling_bead":"ga-33-sling"}' "$DISPATCH_RECENT_EPOCH")")" > "$TMP/fixtures/store-a.json"
  printf '[{"id":"ga-33-sling","status":"open"}]' > "$TMP/recheck/store-a-ga-33-sling.json"
  N33="$TMP/notif33"; M33="$TMP/mail33"; C33="$TMP/comm33"; : > "$N33"; : > "$M33"; : > "$C33"
  PMRW_TEST_NOTIFIED="$N33" PMRW_TEST_MAILED="$M33" PMRW_TEST_COMMENTS_LOG="$C33" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 33: open sling does not override recency exclusion (return 0)" || bad "scenario 33: open sling must not override, got $rc"
  [ ! -s "$C33" ] && ok "scenario 33: no comment posted" || bad "scenario 33: comment posted despite sling still open"
  grep -q "sling ga-33-sling checked: open" "$LOG" 2>/dev/null && ok "scenario 33: log names the confirmed-open sling explicitly (not folded into the error case)" || bad "scenario 33: log does not distinguish confirmed-open from probe-failed"

  # ── Scenario 34 (ga-hhj7u bonus): RECENT dispatch + sling_bead present +
  # sling CLOSED while target still armed+unrouted → overrides back to
  # flagged. The strong-signal case Mayor called out explicitly.
  echo "Scenario 34 (ga-hhj7u bonus): recent dispatch, sling wrapper CLOSED while target still armed+unrouted → overrides recency, still flags"
  reset_stores
  printf '[%s]' "$(mk ga-34 open 'ctx:ready,exec:auto' "$OLD_TS" "$(printf '{"pilot.dispatched_at":"%s","pilot.sling_bead":"ga-34-sling"}' "$DISPATCH_RECENT_EPOCH")")" > "$TMP/fixtures/store-a.json"
  printf '[{"id":"ga-34-sling","status":"closed"}]' > "$TMP/recheck/store-a-ga-34-sling.json"
  N34="$TMP/notif34"; M34="$TMP/mail34"; C34="$TMP/comm34"; : > "$N34"; : > "$M34"; : > "$C34"
  PMRW_TEST_NOTIFIED="$N34" PMRW_TEST_MAILED="$M34" PMRW_TEST_COMMENTS_LOG="$C34" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 34: closed sling overrides recency exclusion (return 1)" || bad "scenario 34: closed sling should override and flag, got $rc"
  grep -q "comment:ga-34" "$C34" 2>/dev/null && ok "scenario 34: comment posted (override fired)" || bad "scenario 34: no comment — override did not fire on a closed sling"

  # ── Scenario 35 (ga-hhj7u bonus, fail-safe): RECENT dispatch + sling_bead
  # present but the sling status query FAILS → stays excluded (an
  # unreliable bonus probe must not undermine the primary fix's precision;
  # see _pmrw_sling_status_probe's documented fail-open direction).
  echo "Scenario 35 (ga-hhj7u bonus, fail-safe): sling status query fails → recency exclusion still holds, no false alarm"
  reset_stores
  printf '[%s]' "$(mk ga-35 open 'ctx:ready,exec:auto' "$OLD_TS" "$(printf '{"pilot.dispatched_at":"%s","pilot.sling_bead":"ga-35-sling"}' "$DISPATCH_RECENT_EPOCH")")" > "$TMP/fixtures/store-a.json"
  echo '__BD_FAIL__' > "$TMP/recheck/store-a-ga-35-sling.json"
  N35="$TMP/notif35"; M35="$TMP/mail35"; C35="$TMP/comm35"; : > "$N35"; : > "$M35"; : > "$C35"
  PMRW_TEST_NOTIFIED="$N35" PMRW_TEST_MAILED="$M35" PMRW_TEST_COMMENTS_LOG="$C35" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 35: sling probe failure fails open toward no-alarm (return 0)" || bad "scenario 35: a failed sling probe must not force a flag, got $rc"
  [ ! -s "$C35" ] && ok "scenario 35: no comment posted despite probe failure" || bad "scenario 35: comment posted off an unconfirmed (failed) sling probe"
  grep -q "sling ga-35-sling checked: error" "$LOG" 2>/dev/null && ok "scenario 35: log names the probe failure explicitly (not folded into the confirmed-open case)" || bad "scenario 35: log does not distinguish probe-failed from confirmed-open"

  # ── Scenario 36 (ga-9tgos): repair succeeds IMMEDIATELY → self-healed,
  # never reaches the alert path at all (no comment/notify/mail for the
  # ARMED-BUT-UNREACHABLE alarm — only its own one-time audit comment).
  echo "Scenario 36 (ga-9tgos): armed+unrouted+aged, repair write persists immediately → self-healed, not alerted"
  reset_stores
  printf '[%s]' "$(mk ga-36 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  echo 0 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/store-a-ga-36"
  N36="$TMP/notif36"; M36="$TMP/mail36"; C36="$TMP/comm36"; U36="$TMP/upd36"; : > "$N36"; : > "$M36"; : > "$C36"; : > "$U36"
  PMRW_TEST_NOTIFIED="$N36" PMRW_TEST_MAILED="$M36" PMRW_TEST_COMMENTS_LOG="$C36" PMRW_TEST_UPDATE_CALLS_LOG="$U36" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 36: repair-only sweep still returns 1 (noteworthy activity)" || bad "scenario 36: expected return 1, got $rc"
  grep -qx "update:ga-36" "$U36" 2>/dev/null && ok "scenario 36: a repair write was attempted" || bad "scenario 36: no update call attempted"
  grep -qx "repaired:ga-36" "$C36" 2>/dev/null && ok "scenario 36: self-heal audit comment posted" || bad "scenario 36: no self-heal audit comment"
  grep -q "^comment:ga-36$" "$C36" 2>/dev/null && bad "scenario 36 (false alarm): the ARMED-BUT-UNREACHABLE alert comment fired for a bead that was self-healed" || ok "scenario 36: no alarm comment fired"
  [ ! -s "$N36" ] && ok "scenario 36: no notify fired for a routine self-heal" || bad "scenario 36: notify fired for a routine self-heal"
  [ ! -s "$M36" ] && ok "scenario 36: no mail fired for a routine self-heal" || bad "scenario 36: mail fired for a routine self-heal"
  grep -q "REPAIRED: 1 bead(s)" "$LOG" 2>/dev/null && ok "scenario 36: REPAIRED summary logged" || bad "scenario 36: no REPAIRED summary in log"
  grep -q "ga-36 (store-a): gc.routed_to -> gastown.dog" "$LOG" 2>/dev/null && ok "scenario 36: default (non-wa/ps) store maps to gastown.dog" || bad "scenario 36: wrong or missing route in log"

  # ── Scenario 37 (ga-9tgos): store->route mapping mirrors quality-gate-
  # dispatcher.sh's default_pool_route_for_rig() exactly for the two named
  # rigs. Overrides PMRW_STORES for this call only, restored after.
  echo "Scenario 37 (ga-9tgos): store basename 'whatsapp_automation' -> wa-worker, 'property_scrapers' -> ps-worker"
  STORE_WA="$TMP/whatsapp_automation"; STORE_PS="$TMP/property_scrapers"
  mkdir -p "$STORE_WA" "$STORE_PS"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk wa-37 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/whatsapp_automation.json"
  printf '[%s]' "$(mk ps-37 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/property_scrapers.json"
  echo 0 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/whatsapp_automation-wa-37"
  echo 0 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/property_scrapers-ps-37"
  N37="$TMP/notif37"; M37="$TMP/mail37"; C37="$TMP/comm37"; : > "$N37"; : > "$M37"; : > "$C37"
  PMRW_STORES="$STORE_WA $STORE_PS" PMRW_TEST_NOTIFIED="$N37" PMRW_TEST_MAILED="$M37" PMRW_TEST_COMMENTS_LOG="$C37" run_sweep >/dev/null
  grep -q "wa-37 (whatsapp_automation): gc.routed_to -> wa-worker" "$LOG" 2>/dev/null && ok "scenario 37: whatsapp_automation -> wa-worker" || bad "scenario 37: wrong/missing route for whatsapp_automation store"
  grep -q "ps-37 (property_scrapers): gc.routed_to -> ps-worker" "$LOG" 2>/dev/null && ok "scenario 37: property_scrapers -> ps-worker" || bad "scenario 37: wrong/missing route for property_scrapers store"
  rm -f "$TMP/fixtures/whatsapp_automation.json" "$TMP/fixtures/property_scrapers.json"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 38 (ga-9tgos): repair write fails twice, succeeds on the 3rd
  # (last) attempt within the default PMRW_REPAIR_MAX_ATTEMPTS=3 budget —
  # proves retry actually recovers from the bug's own transient-race shape,
  # not just that a first-try success path exists.
  echo "Scenario 38 (ga-9tgos): repair write fails 2x, succeeds on attempt 3/3 → self-healed via retry"
  reset_stores
  printf '[%s]' "$(mk ga-38 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  echo 2 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/store-a-ga-38"
  : > "$LOG"
  N38="$TMP/notif38"; M38="$TMP/mail38"; C38="$TMP/comm38"; : > "$N38"; : > "$M38"; : > "$C38"
  PMRW_TEST_NOTIFIED="$N38" PMRW_TEST_MAILED="$M38" PMRW_TEST_COMMENTS_LOG="$C38" run_sweep >/dev/null
  grep -qx "repaired:ga-38" "$C38" 2>/dev/null && ok "scenario 38: eventually self-healed after retries" || bad "scenario 38: retry did not recover the repair"
  [ "$(grep -c "REPAIR ga-38.*retrying" "$LOG" 2>/dev/null)" -eq 2 ] && ok "scenario 38: exactly 2 retry attempts logged before success" || bad "scenario 38: expected exactly 2 retry log lines"

  # ── Scenario 39 (ga-9tgos): repair exhausts all attempts, write never
  # sticks → falls through to alert, with the UPDATED (not "no metadata was
  # changed") wording path and a distinct FAILED log line.
  echo "Scenario 39 (ga-9tgos): repair exhausts all attempts (write never persists) → falls through to alert"
  reset_stores
  printf '[%s]' "$(mk ga-39 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  : > "$LOG"
  N39="$TMP/notif39"; M39="$TMP/mail39"; C39="$TMP/comm39"; U39="$TMP/upd39"; : > "$N39"; : > "$M39"; : > "$C39"; : > "$U39"
  PMRW_TEST_NOTIFIED="$N39" PMRW_TEST_MAILED="$M39" PMRW_TEST_COMMENTS_LOG="$C39" PMRW_TEST_UPDATE_CALLS_LOG="$U39" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 39: exhausted repair still flags (return 1)" || bad "scenario 39: expected return 1, got $rc"
  [ "$(grep -cx "update:ga-39" "$U39" 2>/dev/null)" -eq 3 ] && ok "scenario 39: exactly 3 repair write attempts made" || bad "scenario 39: expected exactly 3 update attempts"
  grep -q "^comment:ga-39$" "$C39" 2>/dev/null && ok "scenario 39: alert comment posted after exhausted repair" || bad "scenario 39: no alert comment"
  grep -q "REPAIR FAILED ga-39.*exhausted 3 attempt(s), gc.routed_to confirmed still absent" "$LOG" 2>/dev/null && ok "scenario 39: REPAIR FAILED logged with confirmed-absent detail" || bad "scenario 39: no REPAIR FAILED log line"

  # ── Scenario 40 (ga-9tgos): every verify-read during repair itself fails
  # (not just the write) → UNVERIFIED, distinct from FAILED, ga-p5q3
  # discipline — still falls through to alert (fail-safe: never silently
  # drop a candidate just because verification was unreadable).
  echo "Scenario 40 (ga-9tgos): repair verify-read fails every attempt → UNVERIFIED, falls through to alert"
  reset_stores
  printf '[%s]' "$(mk ga-40 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  echo '__BD_FAIL__' > "$TMP/recheck/store-a-ga-40.json"
  : > "$LOG"
  N40="$TMP/notif40"; M40="$TMP/mail40"; C40="$TMP/comm40"; : > "$N40"; : > "$M40"; : > "$C40"
  PMRW_TEST_NOTIFIED="$N40" PMRW_TEST_MAILED="$M40" PMRW_TEST_COMMENTS_LOG="$C40" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 40: unverified repair still flags (return 1)" || bad "scenario 40: expected return 1, got $rc"
  grep -q "^comment:ga-40$" "$C40" 2>/dev/null && ok "scenario 40: alert comment posted after unverified repair" || bad "scenario 40: no alert comment"
  grep -q "REPAIR UNVERIFIED ga-40.*exhausted 3 attempt(s), could not confirm outcome" "$LOG" 2>/dev/null && ok "scenario 40: REPAIR UNVERIFIED logged" || bad "scenario 40: no REPAIR UNVERIFIED log line"
  rm -f "$TMP/recheck/store-a-ga-40.json"

  # ── Scenario 41 (ga-9tgos): bead resolves (closes) between detection and
  # the repair attempt → already-resolved, moot — no alert, no false
  # self-heal claim either (nothing to heal).
  echo "Scenario 41 (ga-9tgos): bead closes between detection and repair attempt → already-resolved, no alert"
  reset_stores
  printf '[%s]' "$(mk ga-41 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  printf '[{"id":"ga-41","status":"closed"}]' > "$TMP/recheck/store-a-ga-41.json"
  : > "$LOG"
  N41="$TMP/notif41"; M41="$TMP/mail41"; C41="$TMP/comm41"; : > "$N41"; : > "$M41"; : > "$C41"
  PMRW_TEST_NOTIFIED="$N41" PMRW_TEST_MAILED="$M41" PMRW_TEST_COMMENTS_LOG="$C41" run_sweep
  [ ! -s "$C41" ] && ok "scenario 41: no comment at all (neither alarm nor self-heal)" || bad "scenario 41: unexpected comment posted for an already-resolved bead"
  grep -q "SKIP ga-41.*no longer armed/open by the time repair ran — moot" "$LOG" 2>/dev/null && ok "scenario 41: already-resolved logged as moot" || bad "scenario 41: no already-resolved log line"
  rm -f "$TMP/recheck/store-a-ga-41.json"

  # ── Scenario 42 (ga-9tgos): PMRW_AUTO_REPAIR=0 kill switch → ZERO update
  # calls attempted, detection-only alert still fires exactly as before this
  # fix existed — the independent rollback path.
  echo "Scenario 42 (ga-9tgos): PMRW_AUTO_REPAIR=0 → no repair attempted at all, old detection-only alert still fires"
  reset_stores
  printf '[%s]' "$(mk ga-42 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  : > "$LOG"
  N42="$TMP/notif42"; M42="$TMP/mail42"; C42="$TMP/comm42"; U42="$TMP/upd42"; : > "$N42"; : > "$M42"; : > "$C42"; : > "$U42"
  PMRW_AUTO_REPAIR=0 PMRW_TEST_NOTIFIED="$N42" PMRW_TEST_MAILED="$M42" PMRW_TEST_COMMENTS_LOG="$C42" PMRW_TEST_UPDATE_CALLS_LOG="$U42" run_sweep
  rc=$?
  PMRW_AUTO_REPAIR=1
  [ "$rc" -eq 1 ] && ok "scenario 42: kill-switched sweep still flags (return 1)" || bad "scenario 42: expected return 1, got $rc"
  [ ! -s "$U42" ] && ok "scenario 42: zero update calls attempted with the kill switch off" || bad "scenario 42 (kill switch violated): a repair write was attempted"
  grep -q "^comment:ga-42$" "$C42" 2>/dev/null && ok "scenario 42: alert comment still posted" || bad "scenario 42: no alert comment"
  grep -q "notify:" "$N42" 2>/dev/null && ok "scenario 42: notify still fires" || bad "scenario 42: notify did not fire"

  # ── Scenario 43 (ga-9tgos): PMRW_DRY_RUN=1 also suppresses repair (not
  # just comment/notify/mail/state, already covered by scenario 16) — dry-
  # run's contract is detect-but-touch-NOTHING, and a repair write is a
  # touch.
  echo "Scenario 43 (ga-9tgos): PMRW_DRY_RUN=1 → no repair write attempted either"
  reset_stores
  printf '[%s]' "$(mk ga-43 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  U43="$TMP/upd43"; : > "$U43"
  PMRW_DRY_RUN=1 PMRW_TEST_UPDATE_CALLS_LOG="$U43" run_sweep >/dev/null
  PMRW_DRY_RUN=0
  [ ! -s "$U43" ] && ok "scenario 43: dry-run attempted zero repair writes" || bad "scenario 43 (dry-run violated): a repair write was attempted"

  # _pmrw_s44_fetch_vocab <bead_state.py-path>: classifies the outcome of
  # invoking `<path> --export-vocab` into one of four disjoint states, set in
  # $_S44_STATUS (unavailable/crash/malformed/ok) with the parsed JSON (when
  # ok) in $_S44_VOCAB_JSON. Factored out of scenario 44 so scenario 45 can
  # exercise this EXACT classification code against a deliberately-broken
  # fixture — a hand-copied duplicate of the logic could pass while the real
  # scenario 44 check stayed broken, proving nothing (ga-8mzgn gate feedback,
  # fix attempt 1/3).
  _pmrw_s44_fetch_vocab() {
    _S44_BEAD_STATE_PY="$1"
    _S44_VOCAB_JSON=""
    _S44_STATUS=""
    _S44_DETAIL=""
    if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$_S44_BEAD_STATE_PY" ]; then
      _S44_STATUS="unavailable"
      return
    fi
    _S44_VOCAB_JSON=$(python3 "$_S44_BEAD_STATE_PY" --export-vocab 2>/dev/null)
    _S44_RC=$?
    if [ "$_S44_RC" -ne 0 ]; then
      # Present but non-zero exit — a crash/exception (e.g. --export-vocab
      # dereferencing a constant that got renamed), NOT "not installed". Must
      # be its own state: collapsing this into "unavailable" was the exact
      # bug the gate caught — a present-but-broken bead_state.py also
      # produces empty stdout, and empty stdout alone used to mean "skip,
      # don't fail".
      _S44_STATUS="crash"; _S44_DETAIL="exited $_S44_RC"
    elif [ -z "$_S44_VOCAB_JSON" ]; then
      # exit 0 with zero bytes of output never happens on the success path
      # (--export-vocab always json.dumps()'s a 2-key dict) — treat it as
      # broken rather than trust a silence that shouldn't be possible.
      _S44_STATUS="crash"; _S44_DETAIL="exited 0 but produced no output"
    elif ! printf '%s' "$_S44_VOCAB_JSON" | jq empty >/dev/null 2>&1; then
      _S44_STATUS="malformed"
    else
      _S44_STATUS="ok"
    fi
  }

  # ── Scenario 44 (ga-8mzgn): vocabulary drift-check — every label this
  # file's own jq filter hardcodes (gate:needs-human, pilot:held,
  # pilot:held-until:, needs:engine-window, framework:engine,
  # no-auto-dispatch, pilot:no-auto-dispatch, blocked:/blocked-on:/
  # blocked-by:) must still be present in scripts/bead_state.py's canonical
  # vocabulary (`--export-vocab`). This is NOT a live bridge — running
  # derive() from bash is a bigger decision, deliberately deferred (see
  # ga-4oc2k, still open as of this writing). This is the cheap half: catch
  # DRIFT at test time if bead_state.py ever renames/removes one of these,
  # instead of this watchdog silently disagreeing with the canonical model
  # in production. Skips (never fails) only when python3/bead_state.py are
  # genuinely unavailable — this checks CONSISTENCY between two files, it is
  # not a runtime dependency of the watchdog itself, which must keep working
  # with no Python present at all. A present-but-crashing bead_state.py is a
  # DIFFERENT state (see _pmrw_s44_fetch_vocab above) and fails loud instead.
  echo "Scenario 44 (ga-8mzgn): hardcoded park vocabulary still matches bead_state.py's canonical export"
  # NOT "$HQ" — the selftest setup above reassigns HQ to a throwaway $TMP/hq
  # fixture dir for test isolation. NOT the static PMRW_HQ/HQ default either
  # (that resolves to the shared main-branch checkout, which is a DIFFERENT
  # tree than whichever branch/worktree is currently running this very
  # script — verified live: running --selftest from a feature-branch
  # worktree whose bead_state.py had NOT yet merged to main produced a
  # bogus "exited 0 but produced no output" scenario 44 FAIL, because
  # main's bead_state.py doesn't have --export-vocab yet even though THIS
  # worktree's copy does). This check's entire premise is consistency
  # between two files that ship together in the same commit, so resolve
  # bead_state.py relative to THIS script's own location — always the copy
  # actually paired with the hardcoded labels below, in production
  # (self-location == HQ there, so no behavior change) and in any worktree.
  # PMRW_HQ, if a caller sets it explicitly, still wins (e.g. a future
  # scenario that wants to point at a specific fixture tree on purpose).
  BEAD_STATE_PY="${PMRW_HQ:+$PMRW_HQ/scripts/bead_state.py}"
  if [ -z "$BEAD_STATE_PY" ]; then
    _PMRW_S44_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    BEAD_STATE_PY="${_PMRW_S44_SCRIPT_DIR:-/Users/athos/gt/.gascity-gastown-hq/scripts}/bead_state.py"
  fi
  _pmrw_s44_fetch_vocab "$BEAD_STATE_PY"
  case "$_S44_STATUS" in
    unavailable)
      echo "  skip scenario 44: python3 or bead_state.py unavailable — consistency check needs both, the watchdog itself does not"
      ;;
    crash)
      bad "scenario 44 (COULD NOT VERIFY): --export-vocab $_S44_DETAIL — bead_state.py may be broken (crash/exception), not just drifted"
      ;;
    malformed)
      # Distinct from "confirmed missing" below: this is "couldn't verify at
      # all" (malformed output from --export-vocab), not "checked and it's
      # gone" — collapsing the two would report all 10 labels as individually
      # MISSING for what is actually a parse failure, misleading whoever reads
      # the log about what's actually wrong.
      bad "scenario 44 (COULD NOT VERIFY): --export-vocab produced unparseable output — bead_state.py may be broken, not just drifted"
      ;;
    ok)
      _MISSING=""
      for _LBL in "gate:needs-human" "pilot:held" "pilot:held-until:" "needs:engine-window" \
                  "framework:engine" "no-auto-dispatch" "pilot:no-auto-dispatch" \
                  "blocked:" "blocked-on:" "blocked-by:"; do
        _FOUND=$(printf '%s' "$_S44_VOCAB_JSON" | jq --arg l "$_LBL" \
          '(.PARK_PREFIXES // []) + (.PARK_EXACT // []) | index($l) != null' 2>/dev/null)
        if [ "$_FOUND" != "true" ]; then
          _MISSING="${_MISSING}${_LBL} "
        fi
      done
      if [ -z "$_MISSING" ]; then
        ok "scenario 44: all hardcoded park labels still present in bead_state.py's canonical vocabulary"
      else
        bad "scenario 44 (DRIFT DETECTED): bead_state.py no longer carries: $_MISSING — this file's jq filter is now a private, diverging interpreter for these"
      fi
      ;;
    *)
      # Unreachable today — _pmrw_s44_fetch_vocab's if/elif/.../else chain
      # always sets one of the four cases above before returning. Kept as a
      # fail-loud backstop, not a silent no-op, in case the function ever
      # grows a new status without this dispatch being updated to match —
      # the exact "third state nobody handled" shape this whole bead is
      # about, applied to this dispatch itself.
      bad "scenario 44 (INTERNAL ERROR): _pmrw_s44_fetch_vocab returned unrecognized status '$_S44_STATUS' — this case arm is missing, treat as broken, not as pass"
      ;;
  esac

  # ── Scenario 45 (ga-8mzgn, gate fix-attempt 1/3): regression test for the
  # exact gap the gate reviewer found — a present-but-CRASHING bead_state.py
  # must classify as "crash" (COULD NOT VERIFY → bad), never "unavailable"
  # (silent skip). Before this fix both cases produced empty $VOCAB_JSON and
  # were indistinguishable, so a real break in the canonical vocabulary
  # source could report FAIL=0. Runs _pmrw_s44_fetch_vocab — the identical
  # function scenario 44 uses — against a fixture that always raises, so this
  # proves the ACTUAL check discriminates, not a reimplementation of it that
  # could silently drift out of sync and pass on its own.
  echo "Scenario 45 (ga-8mzgn): crashing bead_state.py classifies as COULD NOT VERIFY, never silently skipped"
  if command -v python3 >/dev/null 2>&1; then
    CRASH_PY="$TMP/crashing_bead_state.py"
    cat > "$CRASH_PY" <<'CRASHPY'
#!/usr/bin/env python3
import sys
if "--export-vocab" in sys.argv:
    raise RuntimeError("simulated drift: a renamed constant blew up --export-vocab")
CRASHPY
    _pmrw_s44_fetch_vocab "$CRASH_PY"
    if [ "$_S44_STATUS" = "crash" ]; then
      ok "scenario 45: crashing bead_state.py classified as crash, not unavailable — scenario 44 will fail loud, not skip"
    else
      bad "scenario 45 (REGRESSION): crashing bead_state.py classified as '$_S44_STATUS', not crash — scenario 44 would silently skip a real break"
    fi
  else
    echo "  skip scenario 45: python3 unavailable — same precondition scenario 44 itself skips on"
  fi

  # ── Scenario 46 (ga-8bcc5m): armed + unrouted + aged but ASSIGNED (a crew
  # owns it) → excluded, gc.routed_to never written. This is the watchdog's
  # own instance of the crew+pool double-dispatch bug ga-8bcc5m reports: the
  # twelve exclusions before this fix never checked .assignee, so a bead the
  # Mayor/a crew had already claimed (assignee set, e.g. mid hand-off before
  # the crew flips status to in_progress) but that still read
  # open+armed+unrouted got its gc.routed_to silently auto-repaired anyway —
  # handing a SECOND builder (the pool) a bead a crew already owned. Mirrors
  # scenario 2's "already has an owning signal → never flags" shape, one
  # level earlier — .assignee is free (already on every candidate row, no
  # extra query), unlike gc.routed_to which IS the thing being repaired.
  # Asserts on PMRW_TEST_UPDATE_CALLS_LOG (not just rc/comment) so a future
  # refactor can't silently reintroduce a write-then-suppress-the-alert
  # variant of the same bug — the repair WRITE itself must never fire.
  echo "Scenario 46 (ga-8bcc5m): armed+unrouted+aged but ASSIGNED (crew owner) → excluded, no repair write, no flag"
  reset_stores
  printf '[%s]' "$(mk ga-46 open 'ctx:ready,exec:auto' "$OLD_TS" | jq -c '. + {assignee:"oracle-wa-awisp9x"}')" > "$TMP/fixtures/store-a.json"
  N46="$TMP/notif46"; M46="$TMP/mail46"; C46="$TMP/comm46"; U46="$TMP/upd46"
  : > "$N46"; : > "$M46"; : > "$C46"; : > "$U46"
  PMRW_TEST_NOTIFIED="$N46" PMRW_TEST_MAILED="$M46" PMRW_TEST_COMMENTS_LOG="$C46" PMRW_TEST_UPDATE_CALLS_LOG="$U46" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 46: assigned bead excluded (return 0)" || bad "scenario 46: assigned (crew-owned) bead must be excluded, got $rc"
  [ ! -s "$U46" ] && ok "scenario 46: NO gc.routed_to write attempted (would double-dispatch onto a crew's bead)" || bad "scenario 46 (REGRESSION ga-8bcc5m): watchdog wrote gc.routed_to on an ASSIGNED bead — this IS the double-dispatch bug"
  [ ! -s "$C46" ] && ok "scenario 46: no comment posted" || bad "scenario 46: comment posted on an assigned bead"
  [ ! -s "$N46" ] && ok "scenario 46: no notify fired" || bad "scenario 46: notify fired on an assigned bead"

  # ── Scenario 47 (ga-qpfza): ALL stores unreadable → the reported incident.
  # Real case (2026-08-08, Dolt mid-restart): 7/7 stores failed to read and
  # the sweep still logged "OK: 0 armed-but-unrouted bead(s)" — a blind sweep
  # printing the exact same verdict as a genuinely clean one. This is the
  # bead's own mandatory acceptance test: confirmed RED against the pre-fix
  # source (bare "OK: 0" present, return 0) before this scenario was added
  # to the fixed file; GREEN here. ─────────────────────────────────────────
  echo "Scenario 47 (ga-qpfza): ALL stores fail to read → UNKNOWN verdict (never bare OK), exit 2"
  reset_stores
  echo '__BD_FAIL__' > "$TMP/fixtures/store-a.json"
  echo '__BD_FAIL__' > "$TMP/fixtures/store-b.json"
  : > "$LOG"
  N47="$TMP/notif47"; M47="$TMP/mail47"; C47="$TMP/comm47"; : > "$N47"; : > "$M47"; : > "$C47"
  PMRW_TEST_NOTIFIED="$N47" PMRW_TEST_MAILED="$M47" PMRW_TEST_COMMENTS_LOG="$C47" run_sweep
  rc=$?
  [ "$rc" -eq 2 ] && ok "scenario 47: totally blind sweep returns 2 (distinct from both 'ran clean' and 'ran, something changed')" || bad "scenario 47 (ga-qpfza REGRESSION): expected return 2 for a fully-blind sweep, got $rc"
  grep -q "UNKNOWN: sweep cego (0/2 stores" "$LOG" 2>/dev/null && ok "scenario 47: UNKNOWN verdict logged with 0/2 coverage" || bad "scenario 47 (ga-qpfza REGRESSION): no UNKNOWN verdict logged"
  grep -q "OK: 0 armed-but-unrouted" "$LOG" 2>/dev/null && bad "scenario 47 (ga-qpfza REGRESSION — THE ORIGINAL BUG): a fully-blind sweep printed a bare 'OK: 0' line, the exact false all-clear this bead reports" || ok "scenario 47: no bare 'OK: 0' line printed while blind"
  [ ! -s "$C47" ] && ok "scenario 47: no comment posted (nothing to report on)" || bad "scenario 47: comment posted despite total blindness"
  [ ! -s "$N47" ] && ok "scenario 47: no notify fired" || bad "scenario 47: notify fired despite total blindness"

  # ── Scenario 48 (ga-qpfza): PARTIAL coverage (1 of 2 stores read), zero
  # findings among the readable ones → must say PARTIAL, never bare OK —
  # "found nothing in what I could see" is not the same claim as "found
  # nothing" when part of the city was never even checked. ─────────────────
  echo "Scenario 48 (ga-qpfza): partial coverage (1/2 stores read), 0 findings among readable → PARTIAL verdict, never bare OK"
  reset_stores
  echo '__BD_FAIL__' > "$TMP/fixtures/store-a.json"
  echo '[]' > "$TMP/fixtures/store-b.json"
  : > "$LOG"
  N48="$TMP/notif48"; M48="$TMP/mail48"; C48="$TMP/comm48"; : > "$N48"; : > "$M48"; : > "$C48"
  PMRW_TEST_NOTIFIED="$N48" PMRW_TEST_MAILED="$M48" PMRW_TEST_COMMENTS_LOG="$C48" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 48: partial-coverage zero-finding sweep still returns 0 (only total blindness gets the distinct code)" || bad "scenario 48: expected return 0, got $rc"
  grep -q "PARTIAL: 1/2 stores lidas" "$LOG" 2>/dev/null && ok "scenario 48: PARTIAL verdict logged with 1/2 coverage" || bad "scenario 48 (ga-qpfza REGRESSION): no PARTIAL verdict logged"
  grep -q "OK: 0 armed-but-unrouted" "$LOG" 2>/dev/null && bad "scenario 48 (ga-qpfza REGRESSION): partial-coverage sweep printed a bare 'OK: 0' line" || ok "scenario 48: no bare 'OK: 0' line printed under partial coverage"

  # ── Scenario 49 (ga-qpfza): the SAME bare-OK collapse one branch over — a
  # bead already alerted+cooling-down, but THIS sweep only has partial
  # coverage. total_flagged only reflects stores actually read, so "OK: all
  # N already alerted" would silently claim full coverage it doesn't have. ──
  echo "Scenario 49 (ga-qpfza): flagged bead already alerted, but THIS sweep has partial coverage → PARTIAL, never bare 'OK: all'"
  reset_stores
  printf '[%s]' "$(mk ga-49 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  echo '[]' > "$TMP/fixtures/store-b.json"
  N49a="$TMP/notif49a"; M49a="$TMP/mail49a"; C49a="$TMP/comm49a"; : > "$N49a"; : > "$M49a"; : > "$C49a"
  PMRW_TEST_NOTIFIED="$N49a" PMRW_TEST_MAILED="$M49a" PMRW_TEST_COMMENTS_LOG="$C49a" run_sweep >/dev/null
  # First sweep: full coverage, real finding — establishes the baseline alert (not under test).
  echo '__BD_FAIL__' > "$TMP/fixtures/store-b.json"
  : > "$LOG"
  N49b="$TMP/notif49b"; M49b="$TMP/mail49b"; C49b="$TMP/comm49b"; : > "$N49b"; : > "$M49b"; : > "$C49b"
  PMRW_TEST_NOTIFIED="$N49b" PMRW_TEST_MAILED="$M49b" PMRW_TEST_COMMENTS_LOG="$C49b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 49: still-cooling-down alert with partial coverage returns 1 (unchanged)" || bad "scenario 49: expected return 1, got $rc"
  grep -q "PARTIAL: 1/2 stores lidas" "$LOG" 2>/dev/null && ok "scenario 49: PARTIAL verdict logged on the already-alerted path under partial coverage" || bad "scenario 49 (ga-qpfza REGRESSION): no PARTIAL verdict on the already-alerted path"
  grep -q "OK: all" "$LOG" 2>/dev/null && bad "scenario 49 (ga-qpfza REGRESSION): partial-coverage already-alerted sweep printed bare 'OK: all ... already alerted'" || ok "scenario 49: no bare 'OK: all ...' line printed under partial coverage"

  # ── Scenario 50 (ga-no6qa): owner-authoritative created_by overrides the
  # store-keyed default — a domain-feature bead created by a *-wa identity
  # but living in a non-wa/ps store (e.g. HQ) must repair to wa-worker, not
  # fall through to the store's own gastown.dog wildcard. Mirrors the live,
  # confirmed instance (ga-ypa6u, created_by=digo-wa-gawisp7iqcpw).
  echo "Scenario 50 (ga-no6qa): created_by=*-wa-* on a non-wa/ps store → repairs to wa-worker, not the store default"
  reset_stores
  printf '[%s]' "$(mk ga-50 open 'ctx:ready,exec:auto' "$OLD_TS" '{}' 'digo-wa-gawisp7iqcpw')" > "$TMP/fixtures/store-a.json"
  echo 0 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/store-a-ga-50"
  : > "$LOG"
  C50="$TMP/comm50"; U50="$TMP/upd50"; : > "$C50"; : > "$U50"
  PMRW_TEST_COMMENTS_LOG="$C50" PMRW_TEST_UPDATE_CALLS_LOG="$U50" run_sweep >/dev/null
  grep -qx "repaired:ga-50" "$C50" 2>/dev/null && ok "scenario 50: self-healed (owner signal, not store default)" || bad "scenario 50: repair did not self-heal"
  grep -q "ga-50 (store-a): gc.routed_to -> wa-worker" "$LOG" 2>/dev/null && ok "scenario 50: created_by owner signal routed to wa-worker despite non-wa store" || bad "scenario 50 (ga-no6qa REGRESSION): expected wa-worker route from owner signal, not logged"

  # ── Scenario 51 (ga-no6qa): same owner-authoritative signal for a
  # ps-worker* creator — mirrors ga-nlh79's PS branch exactly (created_by
  # only, ps-worker* prefix, no *-ps/*-ps-* form — faithful subset, not a
  # redesign).
  echo "Scenario 51 (ga-no6qa): created_by=ps-worker* on a non-wa/ps store → repairs to ps-worker"
  reset_stores
  printf '[%s]' "$(mk ga-51 open 'ctx:ready,exec:auto' "$OLD_TS" '{}' 'ps-worker-3')" > "$TMP/fixtures/store-a.json"
  echo 0 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/store-a-ga-51"
  : > "$LOG"
  C51="$TMP/comm51"; : > "$C51"
  PMRW_TEST_COMMENTS_LOG="$C51" run_sweep >/dev/null
  grep -q "ga-51 (store-a): gc.routed_to -> ps-worker" "$LOG" 2>/dev/null && ok "scenario 51: ps-worker* created_by routed to ps-worker despite non-ps store" || bad "scenario 51 (ga-no6qa REGRESSION): expected ps-worker route from owner signal, not logged"

  # ── Scenario 52 (ga-no6qa): NO regression — a created_by with no *-wa/ps
  # signal (e.g. a dog or the mayor filed it directly) still falls through to
  # the plain store default exactly as before this fix (gastown.dog for a
  # non-wa/ps store) — the owner check must never invent a false signal.
  echo "Scenario 52 (ga-no6qa): created_by with no owner signal → unchanged store-default behavior (no false positive)"
  reset_stores
  printf '[%s]' "$(mk ga-52 open 'ctx:ready,exec:auto' "$OLD_TS" '{}' 'dog-ga8co7e')" > "$TMP/fixtures/store-a.json"
  echo 0 > "$PMRW_TEST_REPAIR_FAILCOUNT_DIR/store-a-ga-52"
  : > "$LOG"
  C52="$TMP/comm52"; : > "$C52"
  PMRW_TEST_COMMENTS_LOG="$C52" run_sweep >/dev/null
  grep -q "ga-52 (store-a): gc.routed_to -> gastown.dog" "$LOG" 2>/dev/null && ok "scenario 52: non-owner-signal created_by still falls through to store default" || bad "scenario 52 (ga-no6qa REGRESSION): store-default fallback broken for a plain/dog creator"

  echo ""
  echo "pilot-missing-route-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ── Single-instance lock (ga-y0g5x) ────────────────────────────────────────
# REGRESSION 2026-08-06 (Mayor): StartInterval (300s) < one full sweep's
# duration (scans every PMRW_STORES entry), so launchd does NOT serialize —
# it fires the next run regardless of whether the previous one finished.
# Measured: 4 simultaneous instances, 6 Dolt queries >10s stacked, bd
# throwing i/o timeouts city-wide. Proven by causality (unload+pkill dropped
# slow queries 6->2->0 in ~40s, no other variable changed), not correlation.
# The gate-orphaned-label-watchdog.sh sibling has the SAME defect (3
# simultaneous instances measured in the same incident) and gets the
# identical fix below.
#
# Same lock shape quality-gate-dispatcher.sh already uses in this city (don't
# invent another, per the bug's own instruction): an atomic mkdir mutex +
# heartbeat mtime for staleness + PID-liveness for a KILLED holder (mtime
# alone would still look "fresh" for up to PMRW_LOCK_MAX_AGE after a kill —
# ga-T1 #7's own lesson) + a sentinel-gated reclaim that overwrites the stale
# heartbeat IN PLACE — the lock dir is never renamed away, so there is no
# window where the path is briefly absent for a TOCTOU double-acquisition
# (ga-T1 #4's own lesson; the simpler mv-then-recreate shape used by
# pilot-dispatcher.sh/auto-refino-dispatcher.sh does have that window — see
# ga-byd3u/ga-bong5 — this sentinel variant doesn't need that fix because it
# never creates the window in the first place).
#
# GATE-FEEDBACK FIX (gate_run=ga-wisp-ohox1gs, fix-attempt 1): the first cut
# of this lock gated reclaim on `age < MAX_AGE && holder alive` — which backs
# off ONLY when BOTH are true, so an old-but-genuinely-ALIVE holder (a
# legitimately slow multi-store sweep under sustained Dolt degradation —
# exactly the condition that caused the original 4-instance incident) fell
# through to reclaim and got its lock STOLEN, reproducing the double-run bug
# this fix exists to prevent. Reviewer + Mayor both confirmed: this is a
# collapsed-OR bug in the same family that dominated this day's other fixes
# ("faz quanto tempo?" and "ainda existe?" are DIFFERENT questions). Three
# states, resolved by PID-liveness ALONE — age is NOT a gating input at all:
#   holder ALIVE   → NEVER reclaim, regardless of heartbeat age. Age doesn't
#                    kill anyone; only a confirmed-dead PID does.
#   holder DEAD    → reclaim immediately, regardless of heartbeat age (a
#                    killed run's lock must not wedge the watchdog forever —
#                    proven by scenario 28's dead-pid+fresh-mtime case).
#   liveness UNKNOWN (malformed/empty heartbeat token) → treated as ALIVE by
#                    _pmrw_lock_holder_dead's own existing safe default →
#                    never reclaim. The safe direction under doubt: at worst
#                    the watchdog loses a cycle; stealing a live lock
#                    corrupts the other run.
# quality-gate-dispatcher.sh's own age-gated fallback is safe ONLY because its
# live holder re-stamps the heartbeat every verdict poll, so MAX_AGE is
# practically unreachable while genuinely progressing — that compensating
# mechanism was the one piece that did NOT get ported when this lock was
# first written here, despite the file's own comment claiming an exact
# mirror. This fix does two things, not one: (1) drops age as a reclaim
# GATE entirely — liveness is the sole authority — and (2) still adds the
# heartbeat re-stamp during run_sweep's per-store loop (mirroring the
# reference file for real this time), so a genuinely-progressing multi-store
# sweep keeps proving itself roughly once per store rather than only once at
# acquisition. (2) is defense-in-depth / diagnostic value only — (1) alone
# already closes the reported hole completely, since a hung single bd call
# mid-sweep would otherwise let heartbeat age cross MAX_AGE while the holder
# is still legitimately (if silently) alive, and age must never be fatal to
# that holder either way.
#
# A LIVE holder makes the second run exit 0 SILENTLY — not an error, pure
# serialization, no comment/notify/mail (the ACEITE requirement: the second
# run must not alarm). A DEAD holder (PID no longer running) is reclaimed
# immediately regardless of heartbeat age — an age-only check would let a
# killed run's zombie lock block every future sweep for up to
# PMRW_LOCK_MAX_AGE, trading "overlap" for "never runs again" (the failure
# mode the bug explicitly calls out to avoid).
PMRW_LOCK_ENABLED="${PMRW_LOCK_ENABLED:-1}"
PMRW_LOCK_DIR="${TMPDIR:-/tmp}/pilot-missing-route-watchdog$(printf '%s' "$HQ" | tr '/ ' '__').lock.d"
PMRW_LOCK_HB="$PMRW_LOCK_DIR/heartbeat"
# A full multi-store sweep normally takes seconds; this margin still reclaims
# a wedged holder within a couple of launchd intervals.
PMRW_LOCK_MAX_AGE="${PMRW_LOCK_MAX_AGE:-900}"
PMRW_LOCK_REAP_TTL="${PMRW_LOCK_REAP_TTL:-10}"
PMRW_LOCK_TOKEN="${PMRW_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"

_pmrw_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}
_pmrw_lock_hb_age() { _pmrw_lock_path_age "$PMRW_LOCK_HB"; }

# Empty/non-numeric token → treat as ALIVE (do not fast-reclaim); PID reuse
# only falls back to the (still-bounded) mtime path, never a wrong reclaim of
# a genuinely live holder.
_pmrw_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$PMRW_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null && return 1
  return 0
}

_pmrw_lock_write_hb() { printf '%s\n' "$PMRW_LOCK_TOKEN" > "$PMRW_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a
# peer that recovered our lock after we were (wrongly) judged stale.
_release_pmrw_lock() {
  local _own
  _own=$(head -n1 "$PMRW_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$PMRW_LOCK_TOKEN" ] && rm -rf "$PMRW_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE run holds it (caller backs off).
_acquire_pmrw_lock() {
  if mkdir "$PMRW_LOCK_DIR" 2>/dev/null; then
    _pmrw_lock_write_hb
    if [ ! -s "$PMRW_LOCK_HB" ]; then
      rm -rf "$PMRW_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  local _age
  _age=$(_pmrw_lock_hb_age)
  # Liveness ALONE gates reclaim — age is never a gating input (see header:
  # age-OR-dead let an old-but-alive holder get its lock stolen). _age is
  # still computed/logged below purely for diagnostics.
  if ! _pmrw_lock_holder_dead; then
    return 1   # holder is ALIVE (or liveness unreadable, treated as alive by design) → never reclaim, no matter how old the heartbeat is.
  fi
  # An absent/empty heartbeat on an existing dir is a holder caught in the µs
  # window between its mkdir and its hb write (a write-failed acquire tears
  # its own dir down above, so this is only ever transient) — treat as LIVE
  # and back off.
  if [ ! -s "$PMRW_LOCK_HB" ]; then
    return 1
  fi
  # Single-winner stale reclaim: gate the recovery on ONE atomic sentinel at a
  # FIXED path, and take the stale dir over IN PLACE (heartbeat overwritten,
  # dir never removed) so no entry-mkdir gap is ever exposed to a racing
  # acquirer — mirrors quality-gate-dispatcher.sh's _acquire_gate_lock exactly.
  local _reaping="${PMRW_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    if [ "$(_pmrw_lock_path_age "$_reaping")" -ge "$PMRW_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${PMRW_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then
        rm -rf "$_dead" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1   # another reclaimer owns the recovery → back off (no double-win).
    fi
  fi
  # Re-check UNDER the sentinel: if the lock turned live while we waited, an
  # earlier reclaimer already took over — back off rather than clobber it.
  # Same liveness-only gate as the initial check above — age plays no part.
  if ! _pmrw_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  _pmrw_lock_write_hb
  if [ ! -s "$PMRW_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE/DEAD lock (heartbeat age ${_age}s) — taking over (ga-y0g5x)."
  return 0
}

if [ "$PMRW_LOCK_ENABLED" = "1" ]; then
  if _acquire_pmrw_lock; then
    trap '_release_pmrw_lock' EXIT
  else
    log "Another pilot-missing-route-watchdog run holds the lock — backing off (single-instance guard, ga-y0g5x)."
    exit 0
  fi
fi

run_sweep; _pmrw_sweep_rc=$?
# ga-qpfza: findings (if any) are still communicated via comment+notify+mail,
# never via this process's own exit code — that design is unchanged (see the
# comment this replaces). The ONE exception is a totally-blind sweep
# (stores_read==0, run_sweep return 2): that isn't "ran OK and found
# something", it's "ran but could not do its job at all", worth surfacing to
# anything watching this daemon's exit status (e.g. `launchctl list`), not
# just the log. Every other outcome (0 or 1) still exits 0, same as before.
if [ "$_pmrw_sweep_rc" = "2" ]; then
  exit 2  # sweep cego — distinct from "ran OK", see run_sweep's UNKNOWN verdict in the log
fi
exit 0  # daemon health = "ran OK"; findings (if any) already sent via comment+notify+mail
