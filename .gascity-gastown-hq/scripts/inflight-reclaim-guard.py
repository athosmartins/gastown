#!/usr/bin/env python3
"""Pilot in-flight bead zombie reclaim guard (ga-se62o, ga-7m191, ga-vw26y, ga-64usm).

Detects beads stranded in story:in-flight whose builder DIED / never engaged /
got churned by a controller restart, and reclaims them so the Pilot can
re-dispatch. This is the Pilot-side analog of quality-gate-guard.sh Vector A.

ga-7m191 (board-honesty): the guard now keys on story:in-flight ALONE and
treats a bead parked under an always-on COORDINATOR session (mayor/deacon) as
NOT having a live owning builder. Previously two failure modes left phantom
in-flight beads permanently un-reclaimable: (1) the query required BOTH
story:in-flight AND pilot:dispatched, so a bead that lost pilot:dispatched was
invisible; (2) a bead reassigned to / parked under the always-live Mayor looked
'owned by a healthy session' forever. Either lied about throughput on the
Kanban.

ga-vw26y (status blind spot): `bd list` defaults to OPEN-only status. That hid
a whole stranding class — a story stuck in status:in_progress that lost its
story:in-flight label. It was invisible to BOTH this guard's label query AND to
the Pilot's open-only re-dispatch query, so it stranded forever (3 stories sat
16-19h post-outage). Two changes close it: (1) the queries now explicitly
include in_progress, and a scoped in_progress sweep (list_stranded_inprogress_
beads) catches Pilot stories that lost story:in-flight but kept a durable Pilot
marker (pilot:dispatched / pilot:reclaim-count); (2) do_reclaim now RESETS
status to open, so a reclaimed bead is actually re-dispatchable (clearing the
labels/assignee alone left it in_progress → still invisible to the Pilot).

ga-64usm (alive != working): the guard used "is the assignee's session alive?"
as a proxy for "is a builder still working it?" — but a credit-limited or hung
session stays state=active in `gc session list` while producing zero output, so
session_is_live() returned True forever and the bead was NEVER reclaimable (one
sat story:in-flight for 3h46 on 2026-06-09). The fix: a matched live session is
treated as a HEALTHY owner only if it shows a fresh progress signal — its
last_active is within STALE_ACTIVITY_TTL (30min), OR the bead itself had a bd
update within that window (workers should bd-update during long work). A live
session that is stale on BOTH is a frozen zombie and falls through to the normal
reclaim rails (no recent branch + continuous stranding past RECLAIM_TTL). The
check is conservative: a missing/unparseable last_active keeps the pre-fix
"treat as live" behavior — we never reclaim on the strength of an absent field.

ga-nlaa (paused-for-human != frozen): a builder that pauses mid-task on an
interactive human prompt (AskUserQuestion) produces the exact SAME telemetry
as a frozen/credit-limited zombie — no new terminal output, no bd update — so
ga-64usm's own staleness check misclassified it as dead (2 false-reclaims in
~5h on wa-y39v2, one mid-zoning-question). "Paused-waiting-for-human" and
"session-dead" are the same signal wearing two different truths (ga-p5q3's
root class). The fix: when both staleness signals are exhausted,
session_awaiting_human_input() peeks the session's actual pane (`gc session
peek`) — independent of commit cadence — before concluding zombie. A pane
still showing an AskUserQuestion prompt keeps the session classified healthy.
Peek only runs once the cheap activity/bd-update checks are already
exhausted, so it stays off the hot path for the common fresh-activity case.
Fails safe: any peek error/timeout/non-zero exit does NOT grant the
exemption — it falls through to the pre-fix staleness rails, so a genuinely
frozen zombie (ga-64usm) is still reclaimed on schedule.

Poll loop (~5min). Silence = healthy. Emits on action only:
  [INFLIGHT-RECLAIM] [RECLAIMED]   cleared in-flight labels + reset <id> to open
  [INFLIGHT-RECLAIM] [RECLAIM-FAILED] label ops failed; bead may need manual cleanup
  [INFLIGHT-RECLAIM] [ESCALATED]   reclaim cap hit — needs human/Mayor review
  [INFLIGHT-RECLAIM] [SELF-HEALED] restored a claim order:orphan-sweep wrongfully reset
  [INFLIGHT-RECLAIM] [STARTUP]     initial state snapshot

Safety invariants (CRITICAL — actuates on real work beads):
  - Operates on beads carrying story:in-flight (pilot:dispatched NOT required;
    it can be lost or stripped by a partial prior reclaim). Epics excluded.
  - A bead assigned to an always-on coordinator (mayor/deacon) is treated as
    PARKED, not owned by a live builder — reclaimable on the usual rails.
  - Hysteresis: bead must be CONTINUOUSLY stranded >= RECLAIM_TTL (25min)
    before any action is taken (transient blips ignored).
  - NEVER reclaims gate:needs-human beads (parked deliberately by a human/gate).
  - NEVER reclaims beads with a live owning session (assignee matches active session).
    Checks session.id, .name, .session_name, .alias, .agent_name because bd typically
    assigns session_name (e.g. 'dog-gawispy8c0mr') not session.name ('gastown.dog-3').
    This also protects the ORIGINAL bug/story of a sling-dispatched fix whose live
    builder session is assigned to the SLING bead, not the original's — the
    original's own assignee is legitimately empty the whole time it's being built.
    list_live_sling_source_beads() resolves that back-reference from the sling's
    own title (ga-qfo3; same pattern as the gate-marker back-reference below).
  - NEVER reclaims beads with recent branch progress (commit within RECLAIM_TTL).
    Checks any remote branch whose final segment matches <bead-id> (incl.
    crew/<pool>/<bead-id>, feat/<id>*, fix/<id>*, feature/<id>*, polecat/<id>*)
    in both HQ and WA repos. Fails safe on git error (→ branch-might-exist).
  - NEVER reclaims beads with a gate-status:ready|dispatching|queued|claimed
    marker (bead is actively being processed by the gate pipeline; "ready" is
    the fresh-marker state /gate-done writes before a separate sweep promotes
    it to queued, so it must count as active too — ga-cxzby). This also
    protects the ORIGINAL bug/story of a sling-dispatched fix whose marker is
    keyed on the SLING bead's id, not the original's — list_gate_active_
    source_beads() resolves that back-reference from the sling's own title
    (ga-lrglm).
  - ga-vw26y: the in_progress sweep is SCOPED to Pilot stories — a bead must
    carry a durable Pilot marker (pilot:dispatched or pilot:reclaim-count) and
    NO terminal/parked label (story:done, gate:passed, …) to qualify. Crew,
    gate, and dog task beads carry no Pilot marker → never touched.
  - Thrash cap: after MAX_RECLAIMS (3) reclaims, escalation marks the bead
    gate:needs-human and RETAINS story:in-flight (ga-6ow4v) — it does NOT
    re-clear, which would loop the bead through dispatch↔reclaim forever. The
    has_needs_human rail then parks it quietly until a human re-queues it.
  - Fails safe on bad/empty/unparseable data — skips the entire cycle.
  - Only modifies pilot/lifecycle labels (+ gate:needs-human on escalation) and
    assignee. Never deletes beads, never touches gate markers or verdicts.
  - ga-nlaa: a matched live session that is stale on both ga-64usm signals is
    STILL not reclaimed if `gc session peek` shows it paused on an
    AskUserQuestion prompt (session_awaiting_human_input()) — waiting on a
    human decision is not death. Fails safe: a failed/ambiguous peek does NOT
    grant the exemption, so a genuinely frozen zombie is still reclaimed.

ga-seuh4 / ga-a8t68 (self-heal a DIFFERENT component's false reset): a
separate, non-Python mechanism — the `order:orphan-sweep` engine order
(default source go:embed'd into the `gc` binary, but THIS city overrides it
via packs/town-deltas/orders/orphan-sweep.toml, which points at the
git-tracked, freely-editable packs/town-deltas/assets/scripts/orphan-sweep.sh
— NOT go:embed'd here, no engine rebuild needed; an earlier version of this
paragraph said otherwise and that claim was WRONG, see ga-114ll) independently
resets in_progress dog/wa-worker-pool claims it judges orphaned. It already
carries a CONFIRM_THRESHOLD=2-consecutive-sweep hysteresis (docs/runbooks/
ga-u0vzx-orphan-sweep-hysteresis-engine-window.md), but that has proven
insufficient: confirmed live re-occurrences (ga-adkny, ga-kq4jf x2, ga-0fw8g,
ga-114ll) show the underlying `gc session list --json` transient can persist
across 2+ consecutive ~5min sweeps for a pool session, wrongfully resetting
(status=open, assignee cleared) a claim whose session is still genuinely
alive. Its reset never touches the bead's gc.* metadata
(gc.session_name/gc.work_dir/gc.routed_to, written at claim time), so that
metadata surviving alongside an empty assignee is a reliable tell.
heal_orphan_sweep_false_resets() (called once per cycle, below) finds beads
matching that tell and — ONLY if the stale gc.session_name still resolves to
a live session — restores status=in_progress + assignee, AND (ga-114ll)
stamps orphan-sweep:shielded-until:<epoch> so orphan-sweep.sh skips the same
bead for ORPHAN_SWEEP_SELFHEAL_SHIELD_SECS instead of re-deriving liveness
from the exact read that just missed it — widening RECENT_UPDATE_GRACE_SECS/
CONFIRM_THRESHOLD again would only lengthen the wrongful-reset cycle, not
close it, since the read itself (not the threshold) is what's unreliable.
This is a compensating heal, not a prevention: it cannot stop orphan-sweep's
own is_known_agent() check from failing, but it closes the window before a
competing worker races into the reopened bead, and it self-limits (a
genuinely dead session is correctly left alone for normal re-dispatch, and
never carries a shield since it was never healed).

ga-f6igb (self-heal can't tell DELIBERATE release from ORPHAN-SWEEP's
accident): confirmed live 2026-08-05 (ga-wgvca) and 2026-08-08 (ga-wzl83) —
the heal above restores ANY candidate whose stale gc.session_name still
resolves to a live session, but "the claiming session is still alive" is
also exactly what's true the instant that SAME session deliberately releases
a claim it has no intention of resuming (an explicit refuse-then-reclaim, or
a deliberate park like ga-wzl83's "done, just waiting on an external merge").
Both look identical to a check that only asks "does this session still
answer to that name?" — self-heal answered yes and restored the claim in
both cases, undoing a correct, intentional release ~2 minutes after it was
made. The bug's own suggested fix (compare the session's instance_token/
generation at restore time) does NOT actually close this: ga-wgvca and
ga-wzl83 were both the SAME generation deliberately releasing its own claim,
so a generation check still says "still the original owner, still alive" and
would still wrongly restore it — confirmed by ga-wzl83's own investigation
notes before this fix landed. What DOES distinguish the two cases: a
deliberate release is never silent — it leaves a label behind explaining WHY
(pool:refused[:reason], gate:needs-human[:*], pilot:no-auto-dispatch,
pilot:held[-until:*], story:awaiting-external-merge), because that is
already this city's standing doctrine for how a worker stands down (see
CLAUDE.md's engine-fix-refuse recipe and do_reclaim()'s own has_explicit_
refusal handling above). order:orphan-sweep's blind reset never adds any of
these — it only clears status+assignee. _has_deliberate_release_signal()
below checks for that narrow, curated label set (NOT bead_state.py's full
PARK_PREFIXES/PARK_EXACT union — see that function's own docstring for why
the broader vocabulary would over-block: a bead merely carrying an unrelated
park label, e.g. ctx:thin from a totally different process, would then sit
open+unassigned+ctx:ready+exec:auto and become newly exposed to routed-pool
re-dispatch, the exact double-claim harm this whole mechanism exists to
prevent, just moved to a different trigger) and skips the restore entirely
when present, regardless of how live the session still reads. Two audit
trails were investigated and ruled out as of 2026-08-13: the flat-file
.beads/interactions.jsonl (actor-per-mutation log a related memory
recommends) has been silently stale since 2026-08-07 — bd migrated fully to
a Dolt-native `interactions` table per commit 5184b2a0c, and that table is
confirmed EMPTY (0 rows) on this city's live hq database, so per-mutation
actor attribution is not currently recoverable at all, not just slow.

ga-f6igb, round 2 (GATE-FEEDBACK gate_run=ga-2esd2, 2026-08-13, both blocking):
issue 2 was a straight downgrade — the SELF-HEAL-SKIPPED branch above used
emit(), which pages (-p4 notify) unconditionally on every run_cycle() pass
(POLL_SEC, default 600s) for as long as a labeled bead sits open+unassigned,
routinely 8-27 days per this bug's own comment thread — 100+ redundant pages/
day for a correctly-skipped, non-actionable event. Now print(), matching this
function's other skip/warn paths.

Issue 1 was sharper: round 1's label set is real but provably incomplete in
general, not just in this one instance. dog-ga3wack's 2026-08-08 21:08
comment on THIS bead (ga-5ksp5, a legitimately-finished, unlabeled release)
is on-thread precedent — the labeled-release theory has a live counterexample
in its own history. And it cannot be patched by adding more labels to the
recognized set: order:orphan-sweep's own reset (orphan-sweep.sh:~315) is
*always* unlabeled by construction, so the unlabeled bucket unavoidably
contains BOTH every genuine accident (which this guard exists to heal) AND
any deliberate release that happens to skip labeling (which it must not
heal) — no labeling vocabulary, however complete, can separate two things
that are label-identical by definition. Confirmed (not assumed) that no
per-mutation actor signal closes this instead, beyond the two already ruled
out above: `gc order history orphan-sweep --json` tracking beads carry no
captured stdout (checked ga-wisp-5vpn58f, description+comments both empty);
no durable orphan-sweep execution log exists on disk (`orphan-sweep:
resetting $bead_id` never lands anywhere greppable — its echo is not
persisted); orphan-sweep.sh's own CONFIRM_THRESHOLD ledger
(orphan-sweep-counts.json) deletes a bead's entry at the exact moment it
resets it (`jq 'del(.[$id])'`, Step 3), so there is nothing left to read
post-hoc; `issues.actor` exists in the Dolt schema but is populated for
event/order-dispatch rows, not general issue-mutation attribution (verified
via `DESCRIBE issues`); dolt_log's committer/email is a generic service
identity for bd-tool writes regardless of caller (this repo's own doctrine,
corroborated — queries against it timed out on the live hq database rather
than returning a useful answer). Inference from EXISTING state cannot close
this gap. So this fix closes it from the other side: orphan-sweep.sh now
stamps `orphan-sweep:reset` in the SAME `bd update` call that performs its
reset (atomic, one invocation) — symmetric with the shield labels this guard
already stamps in the other direction (orphan-sweep:shielded[-until:],
below, which orphan-sweep.sh already honors unconditionally). Healing now
requires this POSITIVE marker, not merely the absence of a deliberate-release
label — collapsing "cannot determine" into "assume accident" is exactly the
third-state failure GATE-FEEDBACK's mandatory check exists to catch. The
marker is single-use: `_has_orphan_sweep_reset_marker()` is checked and the
label is stripped immediately for every candidate this function evaluates,
regardless of which branch ultimately decides the outcome — so a leftover
marker from one incident can never be replayed as false evidence for a
LATER, unrelated release of the same bead id (the same additive-residue
trap documented against gate-sha-failed-style permanent labels elsewhere in
this city's doctrine).
"""
import json
import os
import re
import subprocess
import time
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _irg_ledger
import datetime as _irg_datetime
# ga-x3e7p: single-source vocabulary/safeguards absorbed into bead_state.py —
# this consumer was more careful than that module before ga-x3e7p (canonical
# liveness source, ALIVE != WORKING staleness, pool-template matching,
# provably-dead classifier); these names are now DEFINED there and imported
# here unchanged, so every existing reference below (and in _selftest())
# keeps working with zero behavior change. See bead_state.py's own docstrings
# for the full incident history (ga-64usm, ga-7m191, ga-nlaa, gt-fppb0).
from bead_state import (
    COORDINATOR_MARKERS, LIVE_SESSION_STATES as LIVE_STATES,
    DEAD_SESSION_STATES as _POOL_DEAD_STATES, STALE_ACTIVITY_TTL,
    EPHEMERAL_POOL_TEMPLATES as EPHEMERAL_POOL_ASSIGNEES,
    is_coordinator, parse_iso_epoch, session_activity_age,
    session_owner_is_healthy, claimant_provably_dead, is_needs_human,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RECLAIM_TTL = 1500       # 25min: branch "recent" threshold AND hysteresis window
# STALE_ACTIVITY_TTL (ga-64usm: alive != working) is now canonical in
# bead_state.py — imported above, same value (1800 = 30min), same meaning.
MAX_RECLAIMS = 3         # escalate instead of looping after this many reclaims

# ga-be4x: a worker that EXPLICITLY refuses a bead (pool:refused[:reason] label,
# set deliberately before draining) is a STATED conclusion, not an inferred one —
# categorically different from an unexplained drain/crash, which MAX_RECLAIMS
# above exists to handle. Two independent workers reaching the identical
# stated conclusion is already sufficient signal; a 3rd re-dispatch cannot
# out-argue an already-reasoned refusal, so this threshold is intentionally
# lower than MAX_RECLAIMS. See reclaim_decision()'s has_explicit_refusal param.
REFUSAL_ESCALATE_THRESHOLD = 2
POLL_SEC = int(os.environ.get("RECLAIM_POLL_SEC", "600"))  # default 10min; was 5min
REALERT_SEC = 900        # 15min re-alert cadence for escalated beads

# Pool-dead alert configuration (ga-dbibq)
# Emit a [POOL-DEAD] Mayor mail when >= POOL_DEAD_MIN beads from the SAME pool
# are zombie (no branch + dead session + stranded > TTL) for 2 consecutive cycles.
POOL_DEAD_MIN      = int(os.environ.get("IRG_POOL_DEAD_MIN", "3"))
POOL_DEAD_COOLDOWN = int(os.environ.get("IRG_POOL_DEAD_COOLDOWN_SEC", "1800"))

# ga-hkpwv: bare pool-template assignee names (NOT concrete session names like
# 'wa-worker-adhoc-<hash>'). A bead in_progress with one of these assignees is
# a Pilot pool dispatch that never engaged — no Pilot markers (pilot:dispatched /
# story:in-flight) are required to qualify for the in_progress sweep.
#
# gt-fppb0: 'gastown.dog' IS a bare pool-template assignee. A dog claims work
# through `gc hook` by setting assignee=$GC_ALIAS, and GC_ALIAS for the dog pool
# is the BARE pool name 'gastown.dog' (stable across wake_mode=fresh respawns),
# NOT a concrete session name. The earlier assumption (dogs get a concrete name)
# was the NEVERSTART root: when a claimant dog died, the bead stayed
# in_progress + assignee=gastown.dog, and the next fresh dog's Tier-1 work_query
# (`bd list --status in_progress --assignee gastown.dog`) RE-ADOPTED the zombie,
# burning pool workers in a respawn loop and polluting APROVADAS. Treating it as
# a bare pool template routes it through pool_has_live_worker() (template match)
# + the provably-dead fast-path (reclaim_decision) so a dead dog's claim is
# reclaimed rather than re-offered. Dog branches follow the crew/gastown.dog/<id>
# convention, already honored by get_branch_recent()'s segment matcher.
# ga-x3e7p: this set is now canonical in bead_state.py (EPHEMERAL_POOL_TEMPLATES)
# — imported above under this same name, same two members, zero behavior change.

# ga-hkpwv: minimum stranding window for bare-template pool zombies.
# Longer than RECLAIM_TTL (25min): no Pilot marker is a weaker signal, and a
# genuine build (even slow) won't go branchless for 2h.
POOL_ZOMBIE_TTL = 7200  # 2 hours

# ga-114ll: orphan-sweep.sh's own liveness check (is_known_agent(), bash-side) has
# no staleness/health notion at all — just "does this identifier appear in a
# snapshot of `gc session list --json`" — and that snapshot has repeatedly (if
# rarely) missed a genuinely-live claimant for 2+ consecutive sweeps (ga-u0vzx,
# ga-kq4jf, ga-114ll). Its own CONFIRM_THRESHOLD + RECENT_UPDATE_GRACE_SECS
# (30min) mitigations still weren't enough to stop a ~45min wrongful-reset/
# self-heal cycle recurring for hours. Widening those two knobs a third time
# would only lengthen the cycle, not close it — the read is what's unreliable,
# not the threshold. Instead, every successful self-heal restore stamps this
# much longer, EXPLICIT protection window (orphan-sweep:shielded-until:<epoch>)
# on the bead; orphan-sweep.sh honors it unconditionally, trusting this guard's
# fresh verdict over re-deriving liveness from the same read that just missed
# it. Reuses POOL_ZOMBIE_TTL's already-validated 2h horizon by default rather
# than inventing a new number.
ORPHAN_SWEEP_SELFHEAL_SHIELD_SECS = int(os.environ.get("ORPHAN_SWEEP_SELFHEAL_SHIELD_SECS", "7200"))

# ga-hkpwv: session states that definitively prove a non-working session.
# Used in pool_has_live_worker() to distinguish dead vs unknown states.
# ga-x3e7p: now canonical in bead_state.py (DEAD_SESSION_STATES) — imported
# above under this same name (_POOL_DEAD_STATES), same 6 members.

STATE_FILE = ".gc/state/inflight-reclaim-guard.json"
GC_CITY = "/Users/athos/gt/.gascity-gastown-hq"

# ga-ufr7: ground-truth Claude quota check (ga-wjlv9) — reused here (not
# reimplemented, per Gas Town's own "don't build what already exists" rule) to
# distinguish a THROTTLED-but-alive builder from a genuinely DEAD one. The
# original bug's root cause: reclaims fired for "no progress" during an
# account-wide rate-limit — workers were alive but had zero API tokens to
# commit with, and got reclaimed as if dead.
QUOTA_CHECK = os.environ.get(
    "IRG_QUOTA_CHECK", os.path.join(GC_CITY, "scripts/claude-quota-check.sh"))


def _list_rig_stores():
    """Return list of (name, path) for non-HQ rig stores, or None on a
    genuine query failure — distinct from a genuine empty result ([]).

    ga-mfeip: used by list_inflight_beads / list_stranded_inprogress_beads to
    fan-out queries across every Dolt store so rig-native in-flight beads
    (wa-*/ps-*/lx-*/ma-* prefixes, living in rig-own stores) are visible to
    the cross-store reclaim sweep. HQ-native beads are unaffected.

    ga-u8fly: this used to collapse "gc rig list failed/timed out" and
    "there are genuinely zero non-HQ rigs" into the same [] return. Callers
    then treated [] as "scan complete, nothing else to look at" and
    proceeded — silently dropping every non-HQ-rig bead from that cycle's
    result with no error signal. Combined with run_cycle's end-of-cycle
    state prune (state.pop for any bead not seen that cycle), a single
    transient `gc rig list` hiccup wiped a pool-zombie bead's ENTIRE
    accumulated stranded-clock progress, forcing it to restart from zero.
    Live-confirmed: wa-m4j75's clock only started tracking 2h05m after its
    actual claim began. None now propagates as a whole-cycle skip in both
    callers, matching every other fail-safe query in this file.
    """
    try:
        result = subprocess.run(
            ["gc", "--city", GC_CITY, "rig", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        rigs = data.get("rigs", [])
        return [
            (r.get("name", ""), r["path"])
            for r in rigs
            if not r.get("hq", False)
            and r.get("path")
            and os.path.isdir(r.get("path", ""))
        ]
    except Exception:
        return None

# Repos to search for builder branches
REPOS = [
    "/Users/athos/gt",
    "/Users/athos/gt/whatsapp_automation",
]

# Session states that indicate a live active builder.
# Always-on COORDINATOR roles (ga-7m191): a story bead whose assignee names one
# of these is PARKED, not being actively built — these sessions never die, so
# without this exclusion a dead-builder bead parked under the Mayor would look
# 'owned by a healthy session' forever and never get reclaimed. Substring,
# case-insensitive match against assignee/session identifiers.
# ga-x3e7p: both are now canonical in bead_state.py (LIVE_SESSION_STATES /
# COORDINATOR_MARKERS) — imported above under these same names.

# Gate pipeline states that mean a bead is actively being processed
# (includes queued + claimed as belt-and-suspenders beyond what the spec names)
GATE_ACTIVE_LABELS = {
    "gate-status:dispatching",
    "gate-status:queued",
    "gate-status:claimed",
}

# ga-vw26y: durable Pilot-story markers. The in_progress sweep keeps ONLY beads
# carrying one of these (or a pilot:reclaim-count:N label — see
# is_reclaimable_inprogress_story) so it can never touch a crew/gate/dog task
# bead that merely happens to be in_progress. pilot:dispatched survives the
# documented failure mode where story:in-flight is stripped (crash/race); the
# Pilot stamps both on every dispatch.
PILOT_STORY_MARKERS = ("pilot:dispatched", "story:in-flight")

# ga-vw26y: terminal / deliberately-parked states. A bead carrying ANY of these
# is NOT a reclaimable stranded story — it is done, merged, human-parked,
# engine-queued, or has a claim already in progress. Mirrors the pilot-dispatcher's
# own exclude set so the guard never resurrects completed or intentionally-held work.
TERMINAL_PARKED_LABELS = frozenset({
    "story:done",
    "gate:passed",
    "gate:superseded",
    "gate:needs-human",
    "needs:engine-window",
    "pilot:dispatching",
})


# ---------------------------------------------------------------------------
# Notify helper (matches gate-health-monitor.py / crew-session-dedup.py exactly)
# ---------------------------------------------------------------------------

def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash on failure)."""
    print(msg, flush=True)
    try:
        subprocess.run(
            ["/Users/athos/.local/bin/notify", "-t", "Inflight reclaim", "-p", "4", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


def account_is_rate_limited():
    """True only on a CONFIRMED active Claude session-limit (ga-ufr7).

    Delegates to claude-quota-check.sh --quiet, the ground-truth check (ga-wjlv9)
    that scans session transcripts for Anthropic's own exhaustion event rather
    than guessing from wall-clock time. Contract: exit 2 = LIMITED (an active
    session-scope exhaustion event whose reset time is still in the future);
    exit 0 = not limited; anything else (weekly-only advisory, missing script,
    timeout, non-zero-but-not-2) is treated as NOT confirmed limited.

    Fail-open by design, matching the underlying tool's own philosophy ("absence
    of the ground-truth signal = reliable NOT limited", see its header doc): this
    check is an ADDITIONAL veto on top of the existing reclaim rails, so a flaky
    or missing quota script must fall back to the pre-fix behavior (proceed with
    the normal branch/session checks) rather than inventing a new way for the
    whole reclaim mechanism to stall. The failure mode this guards against is
    the opposite one — reclaiming a throttled-but-alive worker — which is only
    prevented when the check POSITIVELY confirms a live limit.
    """
    try:
        r = subprocess.run([QUOTA_CHECK, "--quiet"], capture_output=True, timeout=18)
        return r.returncode == 2
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] quota check failed (treating as NOT limited): {exc}",
              flush=True)
        return False


def _has_needs_human_label(labels):
    """True if labels contain "gate:needs-human" or "needs-human" — exact, any
    ":"-suffixed variant (gate:needs-human:technical), or (ga-x3e7p, see the
    correction below) any "-"-suffixed variant (needs-human-followup).

    ga-hkpwv / bead-spec: the Mayor's circuit-breaker uses sub-labels like
    gate:needs-human:on-device, :routing, :technical. An exact-match check misses
    these, allowing pool-zombie sweep to re-reclaim a deliberately-parked bead —
    a safety-critical false reclaim. Prefix check closes the gap.

    ga-u8fly: the bare "needs-human" label (no gate: prefix) is the
    general-purpose "a human must look at this" marker used citywide —
    including by Pilot's own pool-dispatch exclusion filters — but was
    invisible here. wa-fvmo8 (legitimately parked pending Athos's phone
    call to Assertiva support) carried only the bare form and was
    incorrectly auto-reclaimed as a result. Same bug class already fixed
    in production-stall-watchdog.py under ga-m0ksy.

    ga-x3e7p: delegates to bead_state.is_needs_human, now shared with
    derive()'s PARK step instead of living only here.

    ⚠️ CORREÇÃO (gate_run=ga-b5y6y, code review): an earlier version of this
    note claimed bead_state.py had NO classification at all for these labels
    before this absorption — false, a sibling of the same false claim caught
    and fixed in bead_state.py's own is_needs_human() docstring. derive()'s
    PARK_PREFIXES already covered bare 'gate:needs-human' (any suffix) and
    bare 'needs-human' via raw startswith, since the direct parent commit
    (cfc0da088/ga-7qsxr) — so a bead with only these labels already resolved
    to derive()["state"]=="parked" before is_needs_human() existed. What was
    actually missing: a STANDALONE predicate this consumer could call
    directly (without invoking the full derive() state machine) — this
    function had its own private copy of that exact check, which is the real
    gap ga-x3e7p closed.

    ⚠️ CORREÇÃO 2 (ga-x3e7p GATE-FAIL attempt 3/3): this note (and this
    function's own docstring, before this fix) claimed the delegation was
    "same vocabulary this function has always used" / "zero behavior
    change" — FALSE, verified empirically: the ORIGINAL body of this
    function (before delegating) matched exact or ":"-suffix only;
    is_needs_human() (via park_labels.label_matches) also matches
    "-"-suffix. Concretely: this function returned False for
    ["needs-human-followup"] before the delegation, True after — a real,
    already-used label (ga-3lsy1, bugs/tech-debt), not a hypothetical. This
    reaches reclaim_decision()'s FIRST safety guard directly (line ~571 as
    of this writing) — a stranded bead carrying that label now correctly
    blocks auto-reclaim, where before it didn't. Intentional widening, not
    a regression: derive() already treated this label as parked via
    PARK_PREFIXES's own (broader) raw-startswith match, so this only
    brings the guard's direct call in line with what the rest of the
    system already did — never narrows protection, only closes a gap. See
    bead_state.py's is_needs_human() docstring for the full correction, and
    test_is_needs_human_reconhece_sufixo_hifen /
    test_reclaim_decision_needs_human_hifen_sufixado_e_noop (this file's
    own selftest) for the regression coverage that was missing.
    """
    return is_needs_human(labels)


def _has_refusal_label(labels):
    """True if labels carry an explicit worker refusal marker (ga-be4x).

    pool:refused[:<reason-slug>] is a TERMINAL signal a worker sets on the bead
    BEFORE draining, once it has determined — through actual analysis — that
    the bead is not buildable by it (wrong domain, no completion path, etc.).

    This is categorically different from reading session state (drained /
    asleep / closed): a session-state read is an INFERENCE made after the
    session is already gone and cannot distinguish "refused" from "crashed" —
    that is the exact conflation ga-be4x reports. An explicit label can only
    be set by a worker that reached a real conclusion, so it is never
    ambiguous the way session state is.
    """
    return any(
        lbl == "pool:refused" or lbl.startswith("pool:refused:")
        for lbl in labels
    )


def _refusal_slug_of_label(lbl):
    """Return the reason slug a single label contributes, or None if it isn't
    a pool:refused[:<slug>] marker. Bare 'pool:refused' -> 'unspecified'.

    Single-label primitive factored out of _refusal_reason_slugs() (ga-9d80l
    gate-fix-2) so _promote_refusal_labels() can match a label being removed
    from the ORIGINAL bead back to the bridge-source entry that produced it,
    without duplicating the slug-extraction rule in two places.
    """
    if lbl == "pool:refused":
        return "unspecified"
    if lbl.startswith("pool:refused:"):
        slug = lbl[len("pool:refused:"):].strip()
        return slug if slug else "unspecified"
    return None


def _refusal_reason_slugs(labels):
    """Extract reason slugs from pool:refused[:<slug>] labels, in label order.

    A bare 'pool:refused' (no reason) contributes 'unspecified'. Used to seed
    the persistent pilot:refused-reason:<slug> audit trail (ga-be4x) so a
    Mayor reviewing an escalated bead sees WHY without re-investigating.
    """
    slugs = []
    for lbl in labels:
        slug = _refusal_slug_of_label(lbl)
        if slug is not None:
            slugs.append(slug)
    return slugs


def _is_ephemeral_pool_assignee(assignee):
    """True if assignee is an ephemeral-pool bead assignee (bare template,
    concrete adhoc form, or dog-pool concrete session form).

    Covers:
    - Bare template in EPHEMERAL_POOL_ASSIGNEES (e.g. 'wa-worker', 'gastown.dog')
    - Concrete adhoc form: '<template>-adhoc-<hex>' (e.g. 'wa-worker-adhoc-faac43db2d')
    - ga-9vi19: dog-pool concrete session form 'dog-<suffix>' (e.g. 'dog-ga2rkia') —
      the assignee shape `gc bd update --claim` sets for a dog pool slot, distinct
      from both forms above. Mirrors _pool_of()'s existing 'al.startswith("dog-")'
      rule (ga-dbibq) so the two classification paths agree on what belongs to the
      gastown.dog pool, instead of _pool_of() alone recognizing it. Deliberately
      NOT folded into the generic '-adhoc-' loop above: the dog pool's concrete
      form is 'dog-<suffix>', not 'gastown.dog-adhoc-<hex>'.

    ga-hkpwv gap fix: the Pilot pool dispatcher assigns concrete adhoc session names
    like 'wa-worker-adhoc-<hash>' to beads rather than the bare template 'wa-worker'.
    Both forms must qualify as ephemeral pool dispatches so that the pool-zombie reclaim
    path (POOL_ZOMBIE_TTL + per-session liveness) handles them correctly.
    """
    if not assignee:
        return False
    if assignee in EPHEMERAL_POOL_ASSIGNEES:
        return True
    al = assignee.lower()
    for template in EPHEMERAL_POOL_ASSIGNEES:
        if al.startswith(template + "-adhoc-"):
            return True
    if al.startswith("dog-"):
        return True
    return False


# ---------------------------------------------------------------------------
# Pure decision function (unit-testable, zero side effects)
# ---------------------------------------------------------------------------

def reclaim_decision(has_live_session, has_recent_branch, seconds_stranded,
                     reclaim_count, has_needs_human, has_dispatching_marker,
                     min_stranding_secs=None, account_rate_limited=False,
                     provably_dead=False, has_explicit_refusal=False,
                     refusal_count=0, has_suspended_owner=False):
    """Compute the reclaim action for one stranded in-flight bead.

    Args:
        has_live_session:        True if assignee matches an active/awake session
        has_recent_branch:       True if any origin branch for bead has commit within TTL
        seconds_stranded:        seconds since first seen as stranded (0.0 if not tracked yet)
        reclaim_count:           current pilot:reclaim-count:N from bead labels (int)
        has_needs_human:         True if bead carries gate:needs-human (or :* variant)
        has_dispatching_marker:  True if quality-gate-marker with active gate state exists
        has_suspended_owner:     True if the bead's assignee is a deliberately-suspended
                                 agent/crew (gc agent list --json → suspended==true). A
                                 DELIBERATE administrative stop, not a crash — the bead is
                                 parked, not stranded, and must HOLD (wait for the crew to
                                 resume) rather than be reclaimed or re-pooled, regardless
                                 of session liveness, branch recency, or refusal count.
                                 ga-vu718 gate-fix-3: previously this signal had NO path
                                 into this function at all — it only drove an indirect
                                 fetch-skip optimization (should_fetch_branch_for_reclaim)
                                 and a strand-clock pin in run_cycle, both of which sit
                                 downstream of the has_explicit_refusal escalate check
                                 added by gate-fix-1. Once that check started firing ahead
                                 of has_live_session/hysteresis, a suspended owner whose
                                 refusal count had already crossed REFUSAL_ESCALATE_THRESHOLD
                                 could reach "escalate" without either downstream mechanism
                                 ever being consulted. Promoted to an explicit, top-tier
                                 guard (same tier as has_needs_human/has_dispatching_marker)
                                 so it outranks every other check unconditionally, closing
                                 that gap at its root instead of patching each downstream
                                 symptom. Defaults False: callers that don't pass it keep
                                 the pre-fix behavior exactly.
        min_stranding_secs:      minimum continuous stranding before action; defaults to
                                 RECLAIM_TTL (25min). Pass POOL_ZOMBIE_TTL (2h) for
                                 bare-template pool-zombie beads (ga-hkpwv).
        account_rate_limited:    True if account_is_rate_limited() confirmed an active
                                 Claude session-limit THIS cycle (ga-ufr7). A throttled
                                 builder produces no commits/output through no fault of
                                 its own — reclaiming it as "dead" is the exact root
                                 cause this param closes. Defaults False (pre-fix
                                 behavior unchanged when the caller doesn't pass it).
        provably_dead:           True if the claimant session is PROVABLY gone (gt-fppb0):
                                 absent from `gc session list`, or the only matching
                                 session(s) are in _POOL_DEAD_STATES. This is STRICTLY
                                 STRONGER than `not has_live_session` — the latter is also
                                 False for a merely-quiet / frozen-but-live-state session
                                 (ga-64usm), which must KEEP the hysteresis. When True (and
                                 every safety guard above is clear), the min_stranding_secs
                                 hysteresis is bypassed and the bead is reclaimed at once —
                                 a provably-dead claimant has no live builder to protect, so
                                 the 25min/2h wait only lets a fresh pool worker re-adopt the
                                 zombie and burn (the NEVERSTART respawn loop). Defaults
                                 False: callers that don't pass it keep the pre-fix
                                 hysteresis behavior exactly.
        has_explicit_refusal:    True if the bead carries a pool:refused[:reason] label
                                 (ga-be4x) — a worker's STATED conclusion that this bead
                                 is not buildable by it, as opposed to an unexplained
                                 drain/crash that provably_dead infers from session state.
                                 A session-state read can NEVER distinguish "refused" from
                                 "crashed" (both end up drained) — that conflation is the
                                 root cause ga-be4x reports: a correctly-refusing worker
                                 got re-dispatched forever because the guard could only see
                                 "drained", identical to a real death. An explicit label
                                 closes that gap because it can only be set by a worker
                                 that reached an actual conclusion. Like provably_dead, it
                                 bypasses the stranding hysteresis (the worker already told
                                 us definitively; waiting teaches us nothing new). Unlike
                                 provably_dead, once refusal_count crosses
                                 REFUSAL_ESCALATE_THRESHOLD it short-circuits straight to
                                 "escalate" ahead of the generic MAX_RECLAIMS thrash cap —
                                 repeated re-dispatch cannot out-argue an already-reasoned,
                                 already-corroborated refusal. ga-vu718: also short-circuits
                                 ahead of has_live_session (see the ordering comment at the
                                 escalate check itself for why) — deliberately NOT ahead of
                                 has_recent_branch, which is left exactly as designed.
                                 Defaults False: callers that don't pass it keep the pre-fix
                                 behavior exactly.
        refusal_count:           current pilot:refusal-count:N from bead labels (int) — the
                                 number of PRIOR explicit refusals already recorded for this
                                 bead, NOT counting the one has_explicit_refusal signals for
                                 the current cycle. Ignored unless has_explicit_refusal=True.

    Returns:
        action in {"reclaim", "escalate", "noop"}
    """
    if min_stranding_secs is None:
        min_stranding_secs = RECLAIM_TTL
    # Safety guards: never touch deliberately-parked or in-progress beads
    if has_needs_human:
        return "noop"
    if has_dispatching_marker:
        return "noop"
    # ga-vu718 gate-fix-3: a deliberately-suspended owner HOLDs unconditionally —
    # checked here, at the same tier as has_needs_human/has_dispatching_marker
    # above, so it outranks has_recent_branch, the refusal-escalate check, AND
    # has_live_session/hysteresis below, not just the branch-fetch optimization
    # in should_fetch_branch_for_reclaim(). See this param's docstring for the
    # incident (2nd GATE-FEEDBACK, gate_run=ga-0uwrm) this closes.
    if has_suspended_owner:
        return "noop"
    # ga-ufr7: a confirmed account-wide rate-limit means NO builder anywhere can
    # be making progress right now — "no progress" is not evidence of death.
    # Defer the whole decision rather than reclaim; the next cycle re-evaluates.
    if account_rate_limited:
        return "noop"
    if has_recent_branch:
        return "noop"

    # ga-be4x: an explicit refusal is a STATED conclusion, not an inferred one.
    # Once REFUSAL_ESCALATE_THRESHOLD independent workers reach the identical
    # verdict, escalate immediately — checked ahead of the generic MAX_RECLAIMS
    # thrash cap (which exists for *unexplained* death, a different failure
    # class) so a bead never has to wait out a 3rd death-style reclaim when 2
    # refusals already answered the question definitively.
    #
    # ga-vu718: this check must run BEFORE has_live_session, not after it (as
    # it did pre-fix). has_live_session answers "is this session still trying
    # right now?" — but a session that has already posted an explicit refusal
    # is, by definition, no longer trying; it told us so. The pre-fix ordering
    # conflated the two questions: a session that stayed continuously "active"
    # across 2 independent refusals (busy posting the refusal comment itself,
    # or a pool slot whose session name is regenerated deterministically and
    # so never reads as absent) made has_live_session return "noop" on every
    # single guard poll, so this branch was never reached even after the
    # refusal count crossed REFUSAL_ESCALATE_THRESHOLD — the one safety net
    # meant to catch exactly that case silently never fired (3 corroborated
    # live incidents). Deliberately NOT reordered relative to has_recent_branch
    # above, which stays ahead of this check unchanged: a fresh commit is
    # evidence of new work, unlike mere liveness, and no incident reports that
    # guard misfiring the same way.
    if has_explicit_refusal and (refusal_count + 1) >= REFUSAL_ESCALATE_THRESHOLD:
        return "escalate"

    if has_live_session:
        return "noop"

    # Bead is stranded — enforce hysteresis (wait for continuous stranding).
    # gt-fppb0 fast-path: a PROVABLY-DEAD claimant (session absent / in a
    # definitively-dead state) has no live builder the hysteresis could be
    # protecting, so skip the wait and reclaim immediately (TTL ~ 0). A merely-
    # quiet claimant (provably_dead=False) still serves the full window so a
    # live-but-idle builder (ga-64usm) is never reclaimed out from under itself.
    # ga-be4x: an explicit refusal bypasses the same hysteresis for the same
    # reason — the worker already told us it is done, waiting adds no signal.
    if not provably_dead and not has_explicit_refusal and seconds_stranded < min_stranding_secs:
        return "noop"
    # Stranded past TTL (or provably dead / explicitly refused) — thrash cap
    if reclaim_count >= MAX_RECLAIMS:
        return "escalate"
    return "reclaim"


def should_fetch_branch_for_reclaim(has_live_session, has_needs_human,
                                     has_dispatching_marker, has_suspended_owner,
                                     has_explicit_refusal, refusal_count):
    """Whether a reclaim_decision() caller should pay for the (potentially
    slow) branch-recency git fetch, vs. defaulting has_recent_branch to False
    as a fast-path. Pure, no I/O — unit-testable, same pattern as
    update_strand_clock below.

    ga-vu718 gate-fix-2: run_cycle()'s has_live_session=True fast-path (skip
    the fetch, default has_recent_branch=False) was provably safe pre-fix,
    because reclaim_decision's has_live_session noop-check fired
    unconditionally right after has_recent_branch was consulted — so a
    defaulted-False value could never change the final outcome. Reordering
    the refusal-escalate check ahead of has_live_session (ga-vu718's own fix)
    broke that invariant for one sub-case: a live session that has ALSO just
    crossed REFUSAL_ESCALATE_THRESHOLD now hits the escalate check BEFORE
    has_live_session is even consulted, so a defaulted-False has_recent_branch
    can wrongly escalate a bead that actually has a fresh commit — exactly
    the false-escalation-during-active-work outcome the branch rail exists to
    prevent. Extracted as its own function (not left inline in run_cycle)
    specifically so a regression test can call it directly: GATE-FEEDBACK on
    the first attempt at this bead noted run_cycle() itself is never invoked
    by _selftest() (only its own def and main() reference it), so a bug in
    exactly this wiring could hide behind an all-green selftest suite
    indefinitely otherwise.

    Mirrors reclaim_decision()'s own short-circuit order: has_needs_human /
    has_dispatching_marker / has_suspended_owner always noop regardless of
    has_recent_branch, all three now checked first in reclaim_decision itself
    (ga-vu718 gate-fix-3 promoted has_suspended_owner to an explicit top-tier
    parameter there too — it used to be "handled outside" via an indirect
    fetch-skip + strand-clock pin, which the 2nd GATE-FEEDBACK found did NOT
    actually protect the escalate branch; see reclaim_decision()'s
    has_suspended_owner docstring for the incident), so the fetch stays
    skipped for those unconditionally AND the underlying decision agrees.
    """
    if has_needs_human or has_dispatching_marker or has_suspended_owner:
        return False
    if not has_live_session:
        return True
    would_cross_refusal_threshold = (
        has_explicit_refusal
        and (refusal_count + 1) >= REFUSAL_ESCALATE_THRESHOLD
    )
    return would_cross_refusal_threshold


def update_strand_clock(bead_state, is_currently_stranded, assignee, now):
    """Update a bead's per-cycle strand clock in bead_state; return
    (seconds_stranded, event).  Mutates only the passed bead_state dict — no
    I/O — so it is unit-testable.

    wa-og36j (born-stale reclaim fix): RESET the strand clock whenever a FRESH
    claim lands — i.e. the bead's assignee changed to a new non-empty value
    since the last cycle. Previously the clock only reset when a LIVE builder
    session or recent branch progress was observed (is_currently_stranded=False).
    But a reclaimed->re-dispatched bead whose new builder is not YET visible as
    live in this sweep (session-list race) OR NEVERSTARTS immediately stayed
    is_currently_stranded=True and INHERITED the prior claim's first_seen_stranded
    -> seconds_stranded was already past RECLAIM_TTL -> it was reclaimed within
    minutes, cycle after cycle, so no builder could ever hold the claim long
    enough to engage (structural churn; pilot.dispatched_at frozen across cycles).
    Anchoring the reset on claim identity (assignee change) gives every fresh
    claim a full window regardless of live-session detection timing.

    events: "fresh_claim_reset" | "started" | "progress_reset" | None
    """
    prev_assignee = bead_state.get("last_assignee")
    assignee = assignee or ""
    # A fresh claim = assignee changed to a new non-empty value. prev_assignee
    # is None on first-see: do NOT treat the original claim as "fresh" — the
    # normal is_currently_stranded path below starts its clock.
    fresh_claim = (
        bool(assignee)
        and prev_assignee is not None
        and assignee != prev_assignee
    )
    bead_state["last_assignee"] = assignee
    event = None
    if fresh_claim and "first_seen_stranded" in bead_state:
        bead_state.pop("first_seen_stranded", None)
        event = "fresh_claim_reset"
    if is_currently_stranded:
        if "first_seen_stranded" not in bead_state:
            bead_state["first_seen_stranded"] = now
            if event is None:
                event = "started"
        return now - bead_state["first_seen_stranded"], event
    # Live builder or recent progress -> reset stranded clock.
    if "first_seen_stranded" in bead_state:
        bead_state.pop("first_seen_stranded", None)
        if event is None:
            event = "progress_reset"
    return 0.0, event


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def load_state():
    """Load guard state from file. Returns empty dict on any error."""
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    """Persist guard state. Best-effort; never crashes the loop."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] state save failed: {exc}", flush=True)


# ---------------------------------------------------------------------------
# Pool-dead detection state (ga-dbibq)
# Per-pool state file: ${STATE_FILE}.pool-dead/<safe_pool_name>
# Stores {"pool": "<name>", "consecutive_cycles": N, "last_alert_epoch": T}
# ---------------------------------------------------------------------------

def _pool_dead_state_path(pool):
    """Path to per-pool dead-detection state file (alongside the main state file)."""
    safe = pool.replace("/", "_").replace(".", "_")
    return os.path.join(STATE_FILE + ".pool-dead", safe)


def _load_pool_dead_state(pool):
    """Load pool-dead state. Returns default dict on any error."""
    try:
        with open(_pool_dead_state_path(pool)) as f:
            return json.load(f)
    except Exception:
        return {"consecutive_cycles": 0, "last_alert_epoch": 0}


def _save_pool_dead_state(pool, ps):
    """Save pool-dead state. Best-effort; never crashes."""
    try:
        path = _pool_dead_state_path(pool)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(ps, f)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] pool-dead state save failed (pool={pool}): {exc}",
              flush=True)


def _check_pool_dead(pool_zombies, now):
    """Emit a [POOL-DEAD] Mayor alert when a whole worker pool produces nothing.

    Called in run_cycle BEFORE per-bead actuation, with the set of beads already
    classified as zombie this cycle (no live session + no recent branch + stranded
    > TTL, regardless of whether they'll be reclaimed or escalated).

    pool_zombies: dict mapping pool-name → list[bead_id] for THIS cycle.

    Hysteresis: pool must have >= POOL_DEAD_MIN zombie beads for 2 consecutive
    cycles before an alert is emitted. Cooldown: at most one alert per pool per
    POOL_DEAD_COOLDOWN seconds. Fail-open: any error (including mail failure) is
    logged and the cycle continues — never crashes.
    """
    pool_dead_dir = STATE_FILE + ".pool-dead"
    seen_pools = set(pool_zombies.keys())

    # Reset consecutive_cycles for pools that had state but are NOT zombie this cycle
    # (recovery: the pool started building again — don't alert after a 1-cycle blip).
    try:
        if os.path.isdir(pool_dead_dir):
            for fname in os.listdir(pool_dead_dir):
                fpath = os.path.join(pool_dead_dir, fname)
                try:
                    with open(fpath) as fh:
                        ps = json.load(fh)
                    pool_name = ps.get("pool", "")
                    if pool_name and pool_name not in seen_pools and ps.get("consecutive_cycles", 0) > 0:
                        ps["consecutive_cycles"] = 0
                        with open(fpath, "w") as fh:
                            json.dump(ps, fh)
                except Exception:
                    pass
    except Exception:
        pass

    for pool, bead_ids in pool_zombies.items():
        n = len(bead_ids)
        ps = _load_pool_dead_state(pool)
        ps["pool"] = pool  # stored for recovery-reset lookups above

        if n >= POOL_DEAD_MIN:
            ps["consecutive_cycles"] = ps.get("consecutive_cycles", 0) + 1
        else:
            # Below threshold — reset; might be a transient single-bead stale.
            ps["consecutive_cycles"] = 0
            _save_pool_dead_state(pool, ps)
            continue

        if (ps["consecutive_cycles"] >= 2
                and now - ps.get("last_alert_epoch", 0) > POOL_DEAD_COOLDOWN):
            ids_str = " ".join(bead_ids)
            emit(f"[INFLIGHT-RECLAIM] [POOL-DEAD] pool={pool} zombies={n} "
                 f"(no branch + dead session, stranded > TTL)")
            # Fail-open: mail failure is logged, never crashes the cycle.
            try:
                result = subprocess.run(
                    ["gc", "mail", "send", "mayor",
                     "-s", f"[POOL-DEAD] {pool} producing nothing",
                     "-m", (f"{n} beads dispatched to {pool} are in_progress with no branch "
                            f"and no live worker for >TTL: {ids_str}. The pool is not building. "
                            f"Existing healers notified via flow-authority.")],
                    timeout=20, capture_output=True)
                if result.returncode != 0:
                    print(f"[INFLIGHT-RECLAIM] [POOL-DEAD] mail non-zero exit (pool={pool} rc={result.returncode}): "
                          f"{result.stderr.decode(errors='replace').strip()}", flush=True)
            except Exception as exc:
                print(f"[INFLIGHT-RECLAIM] [POOL-DEAD] mail failed (pool={pool}): {exc}",
                      flush=True)
            ps["last_alert_epoch"] = now

        _save_pool_dead_state(pool, ps)


# ---------------------------------------------------------------------------
# Data queries (all fail-safe: return None on error → caller skips cycle)
# ---------------------------------------------------------------------------

def list_inflight_beads():
    """List open beads carrying story:in-flight from HQ + all rig stores.

    ga-7m191: keys on story:in-flight ALONE (NOT story:in-flight AND
    pilot:dispatched). pilot:dispatched can be absent — never set, or stripped
    by a partial prior reclaim — leaving a phantom in-flight bead the old
    both-labels query could never see. The reclaim rails (no live builder + no
    recent branch + stranded past TTL) are what gate actuation, not the
    pilot:dispatched label.

    ga-vw26y: the status filter is EXPLICIT (open,in_progress). `bd list`
    defaults to open-only, so without this an in_progress story:in-flight bead
    (dispatched, builder set in_progress, then died) was invisible to the guard
    that is supposed to reclaim it.

    ga-mfeip (cross-store): also queries non-HQ rig stores so rig-native in-flight
    beads (wa-*/ps-*/lx-*/ma-* prefixes, living in rig-own Dolt stores) are
    visible. Attaches rig_root to each bead dict for store-aware bd routing in
    do_reclaim(). Once the rig list itself is known, a query error on one
    INDIVIDUAL rig store still fails open (skips that store, never aborts
    the cycle). ga-u8fly: failing to even ENUMERATE the rigs (gc rig list
    itself errors/times out) is different — that now aborts the whole
    function (returns None, same as an HQ failure) instead of silently
    proceeding as if there were zero non-HQ rigs.
    Returns list of bead dicts (each with a rig_root key), or None on error.
    """
    # HQ query — fail-safe: return None on error per existing contract.
    try:
        result = subprocess.run(
            ["bd", "list",
             "--label", "story:in-flight",
             "--status", "open,in_progress",
             "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return None
    except Exception:
        return None

    # Tag HQ beads: rig_root=None (HQ-native, bd mutations need no -C override)
    merged = {}
    for b in data:
        bid = b.get("id", "")
        if bid:
            b.setdefault("rig_root", None)
            merged[bid] = b

    # Rig stores — ga-u8fly: a failed/timed-out rig-list enumeration must
    # propagate as a whole-function failure (None), matching the HQ-query
    # contract above. Previously this silently degraded to "zero non-HQ
    # rigs" and returned whatever HQ-only results it had, letting a
    # transient `gc rig list` hiccup masquerade as "scan complete".
    _rig_stores = _list_rig_stores()
    if _rig_stores is None:
        return None
    for _rig_name, rig_path in _rig_stores:
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path,
                 "list",
                 "--label", "story:in-flight",
                 "--status", "open,in_progress",
                 "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            for b in rig_data:
                bid = b.get("id", "")
                if bid and bid not in merged:
                    b["rig_root"] = rig_path
                    merged[bid] = b
        except Exception:
            continue   # fail-open: skip this rig

    return list(merged.values())


def is_reclaimable_inprogress_story(labels, assignee=None):
    """Pure predicate: True if an in_progress bead is a Pilot story stranded
    WITHOUT its story:in-flight label (the ga-vw26y blind spot), and is thus a
    candidate for the in_progress sweep.

    Requires a durable Pilot marker — pilot:dispatched, story:in-flight, or any
    pilot:reclaim-count:N (the last proves the guard itself already touched this
    bead, so it is unambiguously a Pilot story whose in-flight label was since
    stripped). Rejects any bead carrying a terminal/parked label so completed or
    intentionally-held work is never resurrected.

    ga-hkpwv (pool-zombie path): also qualifies when assignee is a bare pool
    template in EPHEMERAL_POOL_ASSIGNEES (e.g. 'wa-worker') OR a concrete adhoc
    session name of that pool (e.g. 'wa-worker-adhoc-faac43db2d'). The Pilot's pool
    dispatch stamps assignee=<session-name> but NO pilot:dispatched / story:in-flight —
    these beads are unambiguously pool dispatches, so requiring a Pilot marker
    would leave them permanently invisible. The reclaim rails (pool_has_live_worker
    / concrete_adhoc_session_is_live + POOL_ZOMBIE_TTL + branch check) gate
    actuation conservatively.

    SCOPE-CRITICAL: this is the only thing standing between the in_progress
    sweep and arbitrary in_progress work (crew, gate, dog task beads). Those
    carry NO Pilot marker AND have no EPHEMERAL_POOL_ASSIGNEES assignee →
    this returns False → they are never actuated on.

    ga-hkpwv / prefix fix: gate:needs-human:* variants (e.g. :on-device, :routing)
    are treated identically to the bare gate:needs-human — deliberately parked.
    """
    is_pool_zombie_candidate = (
        assignee is not None and _is_ephemeral_pool_assignee(assignee)
    )
    has_marker = (
        is_pool_zombie_candidate
        or any(lbl in PILOT_STORY_MARKERS for lbl in labels)
        or any(lbl.startswith("pilot:reclaim-count:") for lbl in labels)
    )
    if not has_marker:
        return False
    # Reject any terminal/parked label (exact OR gate:needs-human:* prefix)
    if any(
        lbl in TERMINAL_PARKED_LABELS or lbl.startswith("gate:needs-human:")
        for lbl in labels
    ):
        return False
    return True


def list_stranded_inprogress_beads():
    """List in_progress Pilot stories stranded WITHOUT a story:in-flight label.

    ga-vw26y: `bd list` defaults to open-only, so a story stuck in
    status:in_progress that lost story:in-flight is invisible to BOTH
    list_inflight_beads() AND the Pilot's open-only re-dispatch query — it
    strands forever (3 stories sat 16-19h post-outage). This sweep scans
    in_progress explicitly and keeps only Pilot-marked beads
    (is_reclaimable_inprogress_story), so it never touches crew, gate, or dog
    task beads. The reclaim rails (no live builder + no recent branch + stranded
    past TTL) still gate every actuation.

    ga-mfeip (cross-store): also queries non-HQ rig stores for the same reason
    as list_inflight_beads(). Attaches rig_root to each qualifying bead.
    A query error on one individual rig store still fails open (skips that
    store). ga-u8fly: failing to even ENUMERATE the rigs (gc rig list itself
    errors/times out) now aborts the whole function (returns None, same as
    an HQ failure) instead of silently proceeding as if there were zero
    non-HQ rigs — see _list_rig_stores()'s docstring for the incident this
    closes (a transient rig-list hiccup was repeatedly wiping a pool-zombie
    bead's entire accumulated stranded-clock progress via the end-of-cycle
    state prune in run_cycle, preventing it from ever crossing its TTL).
    Returns list of bead dicts (each with a rig_root key), or None on error.
    """
    # HQ query — fail-safe: return None on error per existing contract.
    try:
        result = subprocess.run(
            ["bd", "list",
             "--status", "in_progress",
             "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return None
    except Exception:
        return None

    # Tag HQ beads: rig_root=None; filter to Pilot stories
    merged = {}
    for b in data:
        if not is_reclaimable_inprogress_story(b.get("labels", []), b.get("assignee")):
            continue
        bid = b.get("id", "")
        if bid:
            b.setdefault("rig_root", None)
            merged[bid] = b

    # Rig stores — ga-u8fly: rig-list enumeration failure propagates as a
    # whole-function failure (None); see docstring above.
    _rig_stores = _list_rig_stores()
    if _rig_stores is None:
        return None
    for _rig_name, rig_path in _rig_stores:
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path,
                 "list",
                 "--status", "in_progress",
                 "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            for b in rig_data:
                if not is_reclaimable_inprogress_story(b.get("labels", []), b.get("assignee")):
                    continue
                bid = b.get("id", "")
                if bid and bid not in merged:
                    b["rig_root"] = rig_path
                    merged[bid] = b
        except Exception:
            continue   # fail-open: skip this rig

    return list(merged.values())


def list_active_sessions():
    """Return all non-closed sessions from gc session list.
    Returns list of session dicts, or None on any error (fail-safe).
    """
    try:
        result = subprocess.run(
            ["gc", "session", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        stdout = result.stdout.strip()
        # gc can emit WARN lines before the JSON object — find the first '{'
        idx = stdout.find("{")
        if idx < 0:
            return None
        if idx > 0:
            stdout = stdout[idx:]
        data = json.loads(stdout)
        sessions = data.get("sessions", [])
        return [s for s in sessions if not s.get("closed", False)]
    except Exception:
        return None


def list_suspended_agents():
    """Return the set of agent NAMES that are deliberately SUSPENDED
    (gc agent list --json → agents[].suspended == true).

    A suspended crew's in-flight beads must NOT be reclaimed. Suspension is a
    DELIBERATE stop (the human paused the crew), not a crash — the work should WAIT
    for the crew to resume, not re-pool into the Pilot's ctx:ready queue where another
    crew picks it up and (correctly) declines it. That re-pool churn is the wa-wbub /
    digo-wa bug: digo-wa was suspended, its in-flight beads lost their owner and got
    re-dispatched repeatedly.

    The set includes BOTH the full agent name ("digo-wa") and its short form with the
    trailing -<rig> suffix stripped ("digo"), because beads are assigned by either
    form. Returns an EMPTY set on any error (fail-open: a failed probe must never
    cause a bead to be held — that would re-introduce the un-reclaimable-zombie class
    this guard exists to kill).
    """
    try:
        result = subprocess.run(
            ["gc", "agent", "list", "--json"],
            capture_output=True, text=True, timeout=20)
        out = (result.stdout or "").strip()
        idx = out.find("{")
        if result.returncode != 0 or idx < 0:
            return set()
        data = json.loads(out[idx:])
        names = {
            a.get("name") for a in data.get("agents", [])
            if isinstance(a, dict) and a.get("suspended") and a.get("name")
        }
        expanded = set(names)
        for nm in names:
            # short form: drop a single trailing -<rig> suffix (digo-wa -> digo).
            if "-" in nm:
                expanded.add(nm.rsplit("-", 1)[0])
        return expanded
    except Exception:
        return set()


# ga-lrglm: matches the Pilot dispatch-title convention set in pilot-dispatcher.sh's
# SLING_TITLE ("fix bug <ID>: ..." for bug/tech-debt, "build story <ID>: ..." for
# feature/story), so a sling bead's own title can be resolved back to the ORIGINAL
# bug/story it was dispatched to fix. See list_gate_active_source_beads() below.
_SLING_TITLE_RE = re.compile(r'^(?:fix bug|build story)\s+(\S+):')


def list_gate_active_source_beads():
    """Return set of source-bead IDs that currently have an active gate marker
    (gate-status:ready, dispatching, queued, or claimed).

    "ready" is included because /gate-done writes a fresh marker in that state;
    promotion to "queued" happens later via a separate sweep, so omitting
    "ready" opens a race window where a just-submitted fix's marker is
    invisible to this check (ga-cxzby).

    ga-lrglm: a bug/story dispatched through the standard sling-task wrapper
    ("fix bug <ID>: ..." / "build story <ID>: ...") gets its gate marker keyed
    on the SLING bead's id (source-bead:<sling-id>), never the ORIGINAL bug's
    id — so a plain `bead_id in <result>` membership check can never protect
    the original bead while its sling sits queued/dispatching/claimed at the
    gate, and this guard reclaims (re-dispatches) it out from under a fix
    that's already built and sitting healthy at the gate. For each directly-
    active source-bead this resolves ITS OWN title and parses the dispatch-
    title convention back out; the referenced original bead is added to the
    returned set alongside the sling bead itself. Resolving from the ACTIVE
    MARKER side — not the bug's own pilot.sling_bead metadata, which is
    single-valued and gets overwritten on every redispatch — keeps this
    correct across multiple historical re-dispatches of the same bug:
    whichever historical sling currently owns the live marker, its own title
    alone resolves the original, no dispatch-history metadata required.
    Title resolution is best-effort / fail-OPEN per lookup (a bd error or
    unparseable title just skips that one back-reference); it never widens
    the fail-safe contract below.

    Returns a frozenset, or None on error (fail-safe: caller treats None as unknown
    and skips the cycle rather than risking a false reclaim).
    """
    active_source_beads = set()
    for gate_lbl in ("gate-status:ready", "gate-status:dispatching", "gate-status:queued", "gate-status:claimed"):
        try:
            result = subprocess.run(
                # --include-infra (ga-vm20x, Mayor 07/08): gate markers are
                # born --ephemeral, which bd 1.1.0 classifies as INFRA and
                # hides from `bd list` by default. Without this flag every
                # gate_lbl here reads as zero matches, so this reclaim guard
                # could not see a bead's own ACTIVE gate marker and would
                # reclaim it as if no gate work were in flight.
                ["bd", "list",
                 "--include-infra",
                 "--label", "type:quality-gate-marker",
                 "--label", gate_lbl,
                 "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=20)
            if result.returncode != 0:
                # A sub-query FAILURE (e.g. transient Dolt contention) is not the
                # same as "no beads matched" — conflating them silently drops that
                # gate_lbl's markers from the active set without tripping the
                # fail-safe (ga-ap7od). Match the documented contract: any error
                # fails the whole function safe, not just this one label.
                return None
            if not result.stdout.strip():
                continue
            data = json.loads(result.stdout)
            if not isinstance(data, list):
                return None  # Unparseable → fail-safe
            for m in data:
                for lbl in m.get("labels", []):
                    if lbl.startswith("source-bead:"):
                        active_source_beads.add(lbl[len("source-bead:"):])
        except Exception:
            return None  # Any exception → fail-safe

    # ga-lrglm: resolve sling → original-bug back-references. Best-effort/fail-open —
    # a lookup failure here must never turn into a whole-cycle fail-safe skip; it just
    # means this cycle stays as protective as it was before this back-reference existed.
    if active_source_beads:
        try:
            result = subprocess.run(
                ["bd", "show", *sorted(active_source_beads), "--json"],
                capture_output=True, text=True, timeout=20)
            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                if isinstance(data, list):
                    for b in data:
                        title = b.get("title") or ""
                        match = _SLING_TITLE_RE.match(title)
                        if match:
                            active_source_beads.add(match.group(1))
        except Exception:
            pass  # best-effort: keep the directly-active set as-is

    return frozenset(active_source_beads)


# ---------------------------------------------------------------------------
# Liveness helpers
# ---------------------------------------------------------------------------
# ga-x3e7p: is_coordinator, parse_iso_epoch, session_activity_age, and
# session_owner_is_healthy (ga-7m191 / ga-64usm / ga-nlaa) are now canonical
# in bead_state.py — imported above under these exact names. Every call site
# below is unchanged; only the definition moved, so this consumer and every
# future one share one implementation instead of a private copy.


def session_awaiting_human_input(session_ref, lines=40):
    """True if `session_ref`'s pane is currently paused on an interactive
    human prompt (ga-nlaa), via `gc session peek`.

    A session blocked on AskUserQuestion produces no new terminal output
    until a human answers — the exact same "stale last_active, no bd update"
    signal a genuinely frozen/credit-limited zombie produces (ga-64usm).
    Callers should invoke this ONLY once the cheap activity/bd-update checks
    in session_owner_is_healthy() have already concluded "stale" — a peek
    shells out to `gc`, which is comparatively expensive, so it must stay off
    the hot path for the common fresh-activity case.

    Because the prompt is blocking, its tool-call marker is still the most
    recent thing rendered whenever the session is actually paused there, so
    a bounded tail (`lines`) is enough — no need to capture the full pane.

    Fails safe: any error/timeout/non-zero exit/missing marker → False. A
    failed or inconclusive probe falls through to the pre-fix staleness
    rails, which is still correct for the true-zombie case this guard exists
    to catch — we only grant the exemption on a POSITIVE confirmation.
    """
    if not session_ref:
        return False
    try:
        result = subprocess.run(
            ["gc", "session", "peek", session_ref, "--json", "--lines", str(lines)],
            capture_output=True, text=True, timeout=15)
        if result.returncode != 0 or not result.stdout.strip():
            return False
        stdout = result.stdout.strip()
        # gc can emit WARN lines before the JSON object — find the first '{'.
        idx = stdout.find("{")
        if idx < 0:
            return False
        data = json.loads(stdout[idx:])
        return "AskUserQuestion" in data.get("output", "")
    except Exception:
        return False


def session_is_live(assignee, sessions, now=None, bead_update_age=None):
    """Return True if assignee matches a live (active/awake) BUILDER session.

    Checks session.id, .name, .session_name, .alias, .agent_name because
    bd typically sets the assignee to session_name (e.g. 'dog-gawispy8c0mr')
    not to the human-readable session.name ('gastown.dog-3'). Checking only
    id + name (as quality-gate-guard.sh does) would miss this case and produce
    a false-positive stranded detection on a live dog/builder session.

    ga-7m191: an assignee naming an always-on COORDINATOR (mayor/deacon), or a
    match against a coordinator session, is a PARKED bead — NOT a live builder.
    Returning True there left dead-builder beads parked under the Mayor
    permanently un-reclaimable. Such matches now return False so the bead is
    reclaimable on the usual rails (no recent branch + stranded past TTL).

    ga-64usm: alive != working. A credit-limited / hung builder keeps
    state=active but produces no output → its last_active goes stale. A matched
    live session therefore counts as a live owner only if session_owner_is_healthy
    confirms a fresh progress signal (recent last_active, OR a recent bd update
    on the bead — passed via bead_update_age). `now` defaults to time.time();
    callers in tests inject a fixed reference.

    CORRECTNESS-CRITICAL: this is the primary guard against reclaiming
    a bead that a live builder actually owns.
    """
    if not assignee or assignee == "null":
        return False
    # An assignee naming a coordinator role is parked, never a live builder.
    if is_coordinator(assignee):
        return False
    if now is None:
        now = time.time()
    for s in sessions:
        state = s.get("state", "").lower()
        if state not in LIVE_STATES:
            continue
        identifiers = {
            s.get("id", ""),
            s.get("name", ""),
            s.get("session_name", ""),
            s.get("alias", ""),
            s.get("agent_name", ""),
        }
        identifiers.discard("")
        if assignee in identifiers:
            # Matched a live session — but a coordinator session is never an
            # owning builder, even if the assignee string itself is opaque.
            if any(is_coordinator(idv) for idv in identifiers):
                return False
            # ga-64usm: a matched live-state session is only a HEALTHY owner if
            # it isn't a frozen/credit-limited zombie. Gate on activity freshness
            # (+ recent bead progress as a secondary signal).
            activity_age = session_activity_age(s, now)
            if session_owner_is_healthy(True, activity_age, bead_update_age):
                return True
            # ga-nlaa: stale on both cheap signals — before writing this off as
            # a frozen zombie, peek its pane for an independent-of-commit-
            # cadence signal (paused on an interactive human prompt).
            return session_owner_is_healthy(
                True, activity_age, bead_update_age,
                awaiting_human_input=session_awaiting_human_input(assignee))
    return False


def pool_has_live_worker(pool_template, sessions, now=None, bead_update_age=None):
    """Return True if any session from pool_template is live and working.

    ga-hkpwv: for bare pool-template assignees (e.g. 'wa-worker'), bead.assignee
    equals the template name, NOT a concrete session name like 'wa-worker-adhoc-<hash>'.
    The existing session_is_live() matches assignee against session identifiers
    (id, name, session_name, alias, agent_name) — none of which equals the bare
    template — so it always returns False for bare-template beads even when the
    pool is actively building. This function uses session.template to detect live
    pool workers instead.

    Conservative (aligns with ga-64usm):
    - Missing/unparseable last_active → treated alive (session_owner_is_healthy).
    - Unknown/unrecognized state (not in _POOL_DEAD_STATES, not in LIVE_STATES) →
      treated alive (return True immediately). Never reclaim on unclear state.
    - Only _POOL_DEAD_STATES = {asleep, drained, closed} are definitively dead.

    CORRECTNESS-CRITICAL: overly conservative — ANY active session from the pool
    (even if building a different bead) blocks ALL bare-template reclaims from
    that pool. Belt-and-suspenders: POOL_ZOMBIE_TTL (2h) ensures no live build
    is false-reclaimed even if the pool-worker→bead mapping is imperfect.
    """
    if now is None:
        now = time.time()
    for s in sessions:
        if s.get("template", "") != pool_template:
            continue
        state = s.get("state", "").lower()
        if state in _POOL_DEAD_STATES:
            continue  # definitively dead/sleeping — skip
        if state in LIVE_STATES:
            # Active/awake — apply ga-64usm staleness check
            activity_age = session_activity_age(s, now)
            if session_owner_is_healthy(True, activity_age, bead_update_age):
                return True
            # ga-nlaa: stale on both cheap signals — peek this specific
            # session's pane before writing it off as a frozen zombie.
            _ref = s.get("session_name") or s.get("name") or s.get("id", "")
            if session_owner_is_healthy(
                    True, activity_age, bead_update_age,
                    awaiting_human_input=session_awaiting_human_input(_ref)):
                return True
            continue  # stale active (frozen zombie) — check remaining sessions
        # Unknown/unrecognized/missing state — conservative: treat pool as alive
        return True
    return False


def concrete_adhoc_session_is_live(assignee, sessions, now=None, bead_update_age=None):
    """Per-session liveness for concrete ephemeral-adhoc workers (e.g. 'wa-worker-adhoc-<hex>').

    Unlike pool_has_live_worker() (pool-wide: any live pool worker blocks ALL reclaims),
    this checks ONLY the session named exactly by assignee — more precise because the
    specific session identity is known at dispatch time.

    Conservative (ga-64usm / ga-hkpwv gap fix):
    - Session found, state in _POOL_DEAD_STATES → keep scanning (a live successor wins)
    - Session found, state in LIVE_STATES → apply session_owner_is_healthy() staleness check
    - Session found, state unknown (not in either set) → True (ambiguous → NOOP)
    - Session not found (gone / never started / purged) → False (dead → eligible)
    - Missing/unparseable last_active on a LIVE session → True (conservative;
      can't prove staleness per ga-64usm: NEVER reclaim on absent field)
    - Duplicate identifier: dead first, live later → live wins (scan-all hardening)

    Coordinator exclusion (ga-7m191): assignee naming mayor/deacon → False.

    CORRECTNESS-CRITICAL: this is the primary guard against false-reclaiming a bead
    whose concrete adhoc builder session is still alive.
    """
    if not assignee or is_coordinator(assignee):
        return False
    if now is None:
        now = time.time()

    found_dead = False
    for s in sessions:
        identifiers = {
            s.get("id", ""),
            s.get("name", ""),
            s.get("session_name", ""),
            s.get("alias", ""),
            s.get("agent_name", ""),
        }
        identifiers.discard("")
        if assignee not in identifiers:
            continue
        # Found the matching session — skip coordinator identities.
        if any(is_coordinator(idv) for idv in identifiers):
            return False

        state = s.get("state", "").lower()
        if state in _POOL_DEAD_STATES:
            found_dead = True
            continue  # Keep scanning — a live successor with the same identifier must win
        if state in LIVE_STATES:
            # Apply ga-64usm staleness check: alive != working
            activity_age = session_activity_age(s, now)
            if session_owner_is_healthy(True, activity_age, bead_update_age):
                return True
            # ga-nlaa: stale on both cheap signals — peek before concluding zombie.
            return session_owner_is_healthy(
                True, activity_age, bead_update_age,
                awaiting_human_input=session_awaiting_human_input(assignee))
        # Unknown/unrecognized state — conservative: treat as alive (NOOP).
        # NEVER reclaim on ambiguous session state.
        return True

    # No live session found. Whether session was dead (found_dead) or gone
    # (no match at all) → eligible for reclaim. Mirrors pool_has_live_worker.
    return False


# ga-x3e7p: claimant_provably_dead (gt-fppb0) is now canonical in
# bead_state.py — imported above under this same name, byte-for-byte the same
# algorithm (verified against this file's own CPD-1..10 selftests before and
# after the move). Every call site below (reclaim_decision fast-path,
# run_cycle, reclaim_dead_dog_claims) is unchanged.


def list_live_sling_source_beads(sessions, now):
    """Return set of ORIGINAL bug/story bead IDs whose SLING/task bead is
    in_progress and assigned to a live builder session (ga-qfo3).

    Pilot's dispatch flow marks the ORIGINAL bug/story bead story:in-flight,
    but assigns the actual build work — and thus the live builder's session —
    to a separate SLING bead (title "fix bug <id>: ..." / "build story <id>:
    ..."). The original bead's own `assignee` is therefore legitimately empty
    while a live session is actively building it, so
    session_is_live(original_bead_assignee, ...) checks the wrong bead's
    field and can never see the real owner.

    Root-caused from the ga-qfo3 incident's launchd log: the guard's own
    "started stranded clock" line showed assignee='' for the ORIGINAL bug
    (ga-z6uo) throughout, while its sling bead (ga-vw39) carried the live dog
    session's assignee the whole time — ga-vw39 never even appeared in the
    guard's query results. The bead was reclaimed at 31min idle with a fully
    live, actively-committing builder.

    Mirrors list_gate_active_source_beads()'s sling→original title
    back-reference resolution (_SLING_TITLE_RE), but protects the
    LIVE-SESSION rail instead of the gate-marker rail. Simpler than that
    function: a sling bead's liveness is resolved directly off the same
    in_progress query result (no separate marker-bead indirection to
    bootstrap from), so multi-redispatch is handled for free — only a
    CURRENTLY in_progress sling can ever contribute a protected id; closed/
    superseded historical slings are absent from the query and contribute
    nothing.

    Fail-safe: returns None on HQ query error (caller skips the cycle,
    matching the existing contract for the other list_* functions in this
    file). Rig-store fan-out is fail-open per store (ga-mfeip pattern).
    """
    try:
        result = subprocess.run(
            ["bd", "list", "--status", "in_progress", "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return None
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            return None
    except Exception:
        return None

    def _collect(candidate_beads, into):
        for b in candidate_beads:
            title = b.get("title") or ""
            match = _SLING_TITLE_RE.match(title)
            if not match:
                continue
            assignee = b.get("assignee") or ""
            if not assignee:
                continue
            bead_update_epoch = parse_iso_epoch(b.get("updated_at", ""))
            bead_update_age = (
                (now - bead_update_epoch) if bead_update_epoch is not None else None
            )
            if session_is_live(assignee, sessions, now, bead_update_age):
                into.add(match.group(1))

    protected = set()
    _collect(data, protected)

    # Rig stores — fail-open per store (ga-mfeip cross-store consistency).
    # ga-u8fly: _list_rig_stores() can now return None (enumeration failure,
    # distinct from a genuine empty result) — `or []` preserves this
    # function's own documented fail-open contract unchanged (a rig-list
    # hiccup here just means fewer sling-protections apply for one cycle,
    # not a whole-cycle abort; this function computes a fresh, non-persisted
    # set each cycle, so there is no accumulated state for a hiccup to wipe).
    # ga-1qqoi: that fallback was silent — a genuine `gc rig list` failure
    # was indistinguishable from a real zero-non-HQ-rigs cycle in every log
    # this guard writes. Signal it before falling back; behavior unchanged.
    _rig_stores = _list_rig_stores()
    if _rig_stores is None:
        print("[INFLIGHT-RECLAIM] warn: gc rig list failed — sling-owner "
              "protection covers HQ only this cycle", flush=True)
        _rig_stores = []
    for _rig_name, rig_path in _rig_stores:
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path, "list", "--status", "in_progress",
                 "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            _collect(rig_data, protected)
        except Exception:
            continue  # fail-open: skip this rig

    return frozenset(protected)


def list_refused_sling_source_beads():
    """Return {original_bead_id: [(reason_slug, sling_id, sling_rig_root,
    raw_label), ...]} bridging an explicit pool:refused[:reason] label
    stamped on a SLING/task bead back onto the ORIGINAL bug/story bead it
    was dispatched to fix (ga-9d80l).

    ga-be4x's explicit-refusal awareness (_has_refusal_label(),
    REFUSAL_ESCALATE_THRESHOLD, the pilot:refused-reason:* audit trail) only
    ever reads a bead's OWN labels. For Pilot's standard HQ dispatch shape,
    `gc sling` creates a SEPARATE wrapper task bead ("fix bug <id>: ..." /
    "build story <id>: ...") distinct from the original bug/story, and a
    refusing worker stamps pool:refused[:reason] on THAT WRAPPER, never on
    the original — so the refusal signal never reached the original's
    reclaim_decision() at all. The original bead instead fell through to the
    generic no-live-session/no-recent-branch hysteresis path and got
    blind-reclaimed (re-dispatchable) up to MAX_RECLAIMS times, each one
    requiring a fresh worker to re-derive the identical refusal conclusion
    from scratch, before the GENERIC (reason-less) escalate finally parked
    it. Concrete incident: ga-dp15j / its sling ga-u5y7y — ga-u5y7y was
    correctly refused (pool:refused:mayor-deferred) but ga-dp15j's own
    labels never carried any pool:refused*/pilot:refused-reason:*/
    pilot:refusal-count:* marker, and it was reclaimed via the generic path
    well before the refusal-aware REFUSAL_ESCALATE_THRESHOLD fast path could
    ever fire.

    Mirrors list_live_sling_source_beads() almost exactly: queries BOTH
    status=open AND status=in_progress (ga-vw26y: a refused sling's status
    varies by how/when it was refused — neither alone is safe to assume)
    across the HQ store and every rig store, filters by _SLING_TITLE_RE
    match on title, and for any match whose OWN labels carry
    pool:refused[:reason], resolves the original bead id from the title
    capture group.

    ga-9d80l GATE-FEEDBACK FIX (fix-attempt 2): fix-attempt 1 returned bare
    reason slugs and discarded the sling's own bead id, so the only thing
    downstream could do with a bridged reason was synthesize it into the
    ORIGINAL's in-memory effective_labels — nothing ever consumed the REAL
    pool:refused[:reason] label at its actual source (the sling). That let
    a single stale sling refusal re-bridge and re-promote on every
    subsequent cycle forever, including against later, unrelated, healthy
    re-dispatches of the same original (a false escalate). Each entry now
    also carries the sling's own id and rig_root (None=HQ store, else the
    rig path it was queried from) so a caller that actually PROMOTES a
    bridged reason (_promote_refusal_labels, called only when
    do_reclaim()/do_escalate() actuate this cycle) can also clear
    pool:refused[:reason] at the sling — consumed exactly once, exactly
    when applied, same contract as a native (non-bridged) refusal label
    already had.

    Fail-OPEN: returns {} (never None) on any query error — unlike
    list_live_sling_source_beads()/list_gate_active_source_beads()'s
    fail-CLOSED (None -> skip the whole cycle) contract. This signal only
    ever makes reclaim_decision MORE conservative (it can only ADD a
    refusal a caller would otherwise miss, never remove a real guard), so
    degrading gracefully to "no bridge found" on a transient fetch failure
    is the safer choice — a whole-cycle skip would needlessly also drop the
    unrelated, otherwise-healthy reclaims/escalates this cycle would
    correctly make.

    ga-9d80l GATE-FEEDBACK FIX (fix-attempt 3): gate-fix-2 added the sling id
    + rig_root to each entry but still discarded the sling's own RAW label
    text, keeping only the normalized reason slug. _promote_refusal_labels()
    then reconstructed a colon-form label (f"pool:refused:{slug}") to remove
    at the source — correct for a reasoned refusal (where the raw text IS
    that colon form), but wrong for a bare 'pool:refused' (no reason): its
    slug is 'unspecified', so the reconstructed text is
    'pool:refused:unspecified', which the sling never actually carried (its
    real label is bare 'pool:refused'). `bd label remove` matches exact
    text, so that removal silently no-op'd and a bare-refused sling's label
    survived forever, re-bridging (and re-promoting) on every later cycle.
    Each entry now carries the sling's own raw label text too, so the
    consumer can remove EXACTLY what the sling carries instead of
    reconstructing it from the lossy normalized slug.
    """
    bridged = {}

    def _collect(candidate_beads, rig_root):
        for b in candidate_beads:
            title = b.get("title") or ""
            match = _SLING_TITLE_RE.match(title)
            if not match:
                continue
            sling_labels = b.get("labels", [])
            if not _has_refusal_label(sling_labels):
                continue
            sling_id = b.get("id") or ""
            if not sling_id:
                continue
            original_id = match.group(1)
            raw_refusal_labels = [
                lbl for lbl in sling_labels
                if lbl == "pool:refused" or lbl.startswith("pool:refused:")
            ]
            if not raw_refusal_labels:
                continue
            existing = bridged.setdefault(original_id, [])
            for raw_lbl in raw_refusal_labels:
                slug = _refusal_slug_of_label(raw_lbl)
                entry = (slug, sling_id, rig_root, raw_lbl)
                if entry not in existing:
                    existing.append(entry)

    for status in ("open", "in_progress"):
        try:
            result = subprocess.run(
                ["bd", "list", "--status", status, "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=20)
            if result.returncode != 0 or not result.stdout.strip():
                continue
            data = json.loads(result.stdout)
            if not isinstance(data, list):
                continue
            _collect(data, None)
        except Exception:
            continue  # fail-open per query

    # ga-u8fly: `or []` preserves this function's own documented fail-open
    # contract when _list_rig_stores() reports a genuine enumeration
    # failure (None) — see the sibling comment in list_live_sling_source_beads.
    # ga-1qqoi: that fallback was silent — signal it before falling back;
    # behavior (fail-open, HQ-only this cycle) is unchanged.
    _rig_stores = _list_rig_stores()
    if _rig_stores is None:
        print("[INFLIGHT-RECLAIM] warn: gc rig list failed — refused-sling "
              "bridge covers HQ only this cycle", flush=True)
        _rig_stores = []
    for _rig_name, rig_path in _rig_stores:
        for status in ("open", "in_progress"):
            try:
                r = subprocess.run(
                    ["bd", "-C", rig_path, "list", "--status", status,
                     "--json", "--limit", "0"],
                    capture_output=True, text=True, timeout=20)
                if r.returncode != 0 or not r.stdout.strip():
                    continue
                rig_data = json.loads(r.stdout)
                if not isinstance(rig_data, list):
                    continue
                _collect(rig_data, rig_path)
            except Exception:
                continue  # fail-open per rig/status

    return bridged


def _branch_segment_matches_bead(segment, bead_id):
    """True if a ref's final path segment identifies bead_id: exact match, or
    bead_id followed by a separator ('-', '_', '.'). Prefix-collision guard —
    e.g. bead 'wa-oly' must NOT match segment 'wa-oly1'.

    Shared by get_branch_recent() (origin refs) and preserve_unpushed_branch()
    (local refs, ga-ufr7) so the two branch-identification rails can never
    silently diverge.
    """
    return (segment == bead_id
            or segment.startswith(bead_id + "-")
            or segment.startswith(bead_id + "_")
            or segment.startswith(bead_id + "."))


def preserve_unpushed_branch(bead_id):
    """Push-before-reclaim safety net (ga-ufr7).

    A builder that goes quiet from THROTTLING (not death) can still have real
    committed work sitting only in a LOCAL branch inside its worktree. Once
    do_reclaim() clears the bead's ownership, the Pilot may re-dispatch it to a
    new builder / new worktree — nothing in this guard (or its callers) guarantees
    the old worktree survives that. Without a durable ref, that work is one
    `git gc --prune` away from permanent loss — the wa-ffeje incident: 6 commits,
    1064 insertions, survived only as un-GC'd dangling git objects.

    For each LOCAL branch across REPOS whose final path segment identifies
    bead_id (via the shared _branch_segment_matches_bead() predicate) and that
    carries a commit not already reachable from any origin ref:
      1. Try `git push origin <sha>:refs/heads/<branch>` — recoverable under its
         own familiar name, immediately resumable by a human or the next builder.
      2. If that is rejected (a same-named origin branch already diverged),
         fall back to `git push origin <sha>:refs/reclaimed/<bead_id>/<sha>` — a
         ref whose name embeds the sha, so it can never collide and the push
         always succeeds if the remote is reachable at all.

    Best-effort / never raises: any git error is logged and the scan continues
    to the next repo/branch. This is a SAFETY NET, not a correctness gate —
    do_reclaim() proceeds regardless of this function's outcome. A network blip
    must not block reclaiming a genuinely dead bead forever (that would just
    trade one stranding failure mode for another).

    Returns a list of human-readable "what was preserved" strings (possibly
    empty — most reclaims have no local unpushed branch at all, e.g. a builder
    that never got as far as committing).
    """
    preserved = []
    for repo in REPOS:
        # Refresh remote-tracking refs so the "already on origin?" check below
        # isn't working off a stale fetch. Fail-safe: a fetch error here just
        # means the later --contains check may under-detect "already safe" and
        # attempt a redundant (harmless) push — never a reason to skip the repo.
        try:
            subprocess.run(
                ["git", "-C", repo, "fetch", "origin", "--prune", "--quiet"],
                capture_output=True, timeout=30)
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] preserve-branch: fetch failed for {repo}: {exc}",
                  flush=True)

        try:
            r = subprocess.run(
                ["git", "-C", repo, "for-each-ref",
                 "--format=%(refname) %(objectname)", "refs/heads/"],
                capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                continue
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] preserve-branch: local ref-list failed for {repo}: {exc}",
                  flush=True)
            continue

        for line in r.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            refname, sha = parts
            branch = refname[len("refs/heads/"):]
            segment = branch.rsplit("/", 1)[-1]
            if not _branch_segment_matches_bead(segment, bead_id):
                continue

            # Already reachable from some origin ref (pushed earlier, or merged)?
            try:
                chk = subprocess.run(
                    ["git", "-C", repo, "branch", "-r", "--contains", sha],
                    capture_output=True, text=True, timeout=30)
                if chk.returncode == 0 and chk.stdout.strip():
                    continue  # already safe on origin — nothing to preserve
            except Exception:
                pass  # can't confirm safety → fall through and attempt the push anyway

            pushed = False
            try:
                p = subprocess.run(
                    ["git", "-C", repo, "push", "origin", f"{sha}:refs/heads/{branch}"],
                    capture_output=True, text=True, timeout=30)
                if p.returncode == 0:
                    pushed = True
                    preserved.append(f"{branch}@{sha[:8]} pushed to origin/{branch}")
            except Exception as exc:
                print(f"[INFLIGHT-RECLAIM] preserve-branch: push {branch} failed: {exc}",
                      flush=True)

            if not pushed:
                tag_ref = f"refs/reclaimed/{bead_id}/{sha}"
                try:
                    p2 = subprocess.run(
                        ["git", "-C", repo, "push", "origin", f"{sha}:{tag_ref}"],
                        capture_output=True, text=True, timeout=30)
                    if p2.returncode == 0:
                        preserved.append(f"{branch}@{sha[:8]} tagged {tag_ref}")
                    else:
                        print(f"[INFLIGHT-RECLAIM] preserve-branch: FAILED to preserve "
                              f"{branch}@{sha[:8]} in {repo}: {p2.stderr.strip()[:300]}",
                              flush=True)
                except Exception as exc:
                    print(f"[INFLIGHT-RECLAIM] preserve-branch: tag-push {branch} failed: {exc}",
                          flush=True)
    return preserved


def get_branch_recent(bead_id, fetch=True, window_seconds=None):
    """Return True if any remote branch whose final path segment equals <bead-id>
    (or starts with <bead-id> followed by '-'/'_'/'.') has a commit within
    window_seconds (default RECLAIM_TTL) seconds of now.

    fetch=False skips the `git fetch` (gt-fppb0): the dog pre_start preflight must
    be FAST and must never block a spawn on a slow network fetch, so it reads the
    already-fetched remote-tracking refs (refreshed by run_cycle's 10-min sweep).
    Slightly staler, but fails the SAME safe way — a recent local ref still blocks
    the reclaim — and the authoritative run_cycle sweep (fetch=True) is the
    backstop. run_cycle keeps fetch=True; all existing callers are unchanged.

    window_seconds (ga-nxgxz): defaults to None, which preserves the original
    RECLAIM_TTL (~25min) behavior for every existing caller. Callers outside this
    guard's own domain — e.g. throughput-stall-watchdog.py's delivery-stall
    check, whose staleness window is hours, not minutes — pass an explicit,
    larger window so "does this bead's branch show real progress" is evaluated
    against the CALLER's own staleness definition, not this guard's reclaim TTL.

    Matches ALL branch naming conventions regardless of prefix:
      crew/<pool>/<bead-id>     (dominant: 416 branches, e.g. crew/wa-worker/wa-quoy)
      feat/<bead-id>*           (30 branches)
      fix/<bead-id>*
      feature/<bead-id>*
      polecat/<bead-id>*
    Prefix-collision guard: segment must equal bead_id EXACTLY or be followed by
    a separator char ('-', '_', '.') — so bead 'wa-oly' does NOT match 'wa-oly1'.

    Fetches both HQ and WA repos. Fail-safe: ANY git error (fetch or list)
    → return True (branch-might-exist, do NOT reclaim). Logs on error.

    CORRECTNESS-CRITICAL: this is the secondary guard against reclaiming beads
    where a builder is actively pushing but their session has a different name
    than the bead's assignee field.
    """
    now = time.time()
    window = RECLAIM_TTL if window_seconds is None else window_seconds
    for repo in REPOS:
        # Fetch to update remote-tracking refs.
        # Fail-safe: fetch error → branch might exist → do NOT reclaim.
        if fetch:
            try:
                subprocess.run(
                    ["git", "-C", repo, "fetch", "origin", "--prune", "--quiet"],
                    capture_output=True, timeout=30)
            except Exception as _fe:
                print(
                    f"[INFLIGHT-RECLAIM] branch-rail: fetch failed for {repo}: {_fe}"
                    " — treating as branch-might-exist (fail-safe)",
                    flush=True)
                return True

        # List all remote refs with timestamps in a single pass.
        # Fail-safe: ref-list error → branch might exist → do NOT reclaim.
        try:
            r = subprocess.run(
                ["git", "-C", repo, "for-each-ref",
                 "--sort=-committerdate",
                 "--format=%(refname) %(committerdate:unix)",
                 "refs/remotes/origin/"],
                capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                print(
                    f"[INFLIGHT-RECLAIM] branch-rail: for-each-ref failed"
                    f" (rc={r.returncode}) for {repo}"
                    " — treating as branch-might-exist (fail-safe)",
                    flush=True)
                return True
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.rsplit(None, 1)
                if len(parts) != 2:
                    continue
                refname, ts_str = parts
                # Final path segment of the ref (e.g. 'wa-quoy' from
                # refs/remotes/origin/crew/wa-worker/wa-quoy).
                segment = refname.rsplit("/", 1)[-1]
                if not _branch_segment_matches_bead(segment, bead_id):
                    continue
                try:
                    ts = float(ts_str)
                    if now - ts < window:
                        return True
                except ValueError:
                    continue
        except Exception as _re:
            print(
                f"[INFLIGHT-RECLAIM] branch-rail: ref-list failed for {repo}: {_re}"
                " — treating as branch-might-exist (fail-safe)",
                flush=True)
            return True
    return False


def parse_reclaim_count(labels):
    """Extract pilot:reclaim-count:N from labels. Returns int (0 if absent or invalid)."""
    for lbl in labels:
        if lbl.startswith("pilot:reclaim-count:"):
            try:
                return int(lbl[len("pilot:reclaim-count:"):])
            except ValueError:
                pass
    return 0


def parse_refusal_count(labels):
    """Extract pilot:refusal-count:N from labels. Returns int (0 if absent or invalid).

    ga-be4x: tracked SEPARATELY from pilot:reclaim-count — a bead may thrash
    through unexplained deaths and explicit refusals in any mix, and only the
    latter must trip the faster REFUSAL_ESCALATE_THRESHOLD circuit-breaker.
    """
    for lbl in labels:
        if lbl.startswith("pilot:refusal-count:"):
            try:
                return int(lbl[len("pilot:refusal-count:"):])
            except ValueError:
                pass
    return 0


def _pool_of(assignee):
    """Normalize a bead assignee to its worker-pool name for pool-dead tracking (ga-dbibq).

    wa-worker / wa-worker-* → 'wa-worker'
    gastown.dog / dog-*     → 'gastown.dog'
    anything else           → the assignee as-is (crew name)
    empty / None            → '' (callers skip empty pool)
    """
    if not assignee:
        return ""
    a = str(assignee)
    al = a.lower()
    if al == "wa-worker" or al.startswith("wa-worker-"):
        return "wa-worker"
    if al == "gastown.dog" or al.startswith("dog-"):
        return "gastown.dog"
    return a


# ---------------------------------------------------------------------------
# Actuation helpers (label + assignee ops on real beads — CONSERVATIVE)
# ---------------------------------------------------------------------------

def _promote_refusal_labels(bead_id, labels, refusal_count, rig_root=None, bridge_sources=None):
    """Consume fresh pool:refused[:reason] label(s), promote each into a
    PERMANENT pilot:refused-reason:<slug> audit label, and bump
    pilot:refusal-count:N. Shared by do_reclaim() and do_escalate() (ga-be4x
    gate-fix-2) so this exact sequence runs regardless of which function
    actuates a refusal-triggered bead.

    Why do_escalate() needs this too, not just do_reclaim(): reclaim_decision()
    jumps straight to "escalate" — bypassing do_reclaim() entirely — the
    moment (refusal_count + 1) >= REFUSAL_ESCALATE_THRESHOLD. Before this
    fix, ONLY do_reclaim() ran this promotion, so the 2nd (triggering)
    worker's fresh pool:refused:<reason> label was never consumed, never
    promoted, and never surfaced — do_escalate()'s reason-derivation read
    only already-promoted pilot:refused-reason:<slug> labels, silently
    dropping the exact reason that caused the escalation (and permanently
    under-counting pilot:refusal-count by one, since its bump lived only in
    this same do_reclaim()-only path).

    ga-9d80l gate-fix-2: bridge_sources, when provided, is the
    (slug, sling_id, sling_rig_root, raw_label) list run_cycle's Pass 1
    attached to this bead (from list_refused_sling_source_beads(), via the
    classified tuple). For every pool:refused[:reason] label consumed below
    that matches a bridged slug, the REAL label is ALSO removed at its
    actual source — the sling bead, via bd -C sling_rig_root — not just
    from `bead_id` (the ORIGINAL). Removing it only from `bead_id` was a
    no-op on a bridged reason: the original never carried it natively in
    bd, only in this call's in-memory `labels` (synthesized by Pass 1).
    Left uncleared, the sling's label survives forever and
    list_refused_sling_source_beads() re-bridges the SAME stale refusal on
    every later cycle — including against a later, unrelated, healthy
    re-dispatch of the same original (a false escalate: fix-attempt-1's
    gate-review finding). Consuming at the source makes a bridged refusal
    behave exactly like a native one: read once, promoted once, never
    re-applied.

    ga-9d80l gate-fix-3: the source-side removal uses each bridge source's
    own `raw_label` — the sling's ACTUAL label text — not the `lbl` being
    consumed on `bead_id` (which is always the colon-form
    "pool:refused:<slug>" Pass 1 synthesized into effective_labels). Those
    two differ whenever the sling's real label was bare 'pool:refused' (no
    reason): its slug is 'unspecified', so `lbl` reads
    "pool:refused:unspecified" — text the sling never actually carried.
    gate-fix-2 removed `lbl` from the sling too, which silently no-op'd for
    that shape (bd label remove matches exact text) and let a bare-refused
    sling's label survive every later cycle.

    Returns (new_refusal_count, fresh_slugs, all_slugs):
      - new_refusal_count: refusal_count + 1.
      - fresh_slugs:  reasons newly promoted THIS call (from pool:refused[:reason]
                      labels present in `labels`).
      - all_slugs:    fresh_slugs plus any pilot:refused-reason:<slug> already
                      present in `labels`, deduplicated, first-seen order — the
                      complete accumulated reason history a human/Mayor needs.
    """
    _bd = ["bd", "-C", rig_root] if rig_root else ["bd"]
    fresh_slugs = _refusal_reason_slugs(labels)

    # ga-9d80l gate-fix-2/3: index bridge sources by slug so a label removed
    # from `bead_id` below can find every sling that actually carries it —
    # keyed by the sling's own RAW label text (gate-fix-3), not a
    # reconstructed colon-form string.
    _sources_by_slug = {}
    for _slug, _sling_id, _sling_rig_root, _raw_lbl in (bridge_sources or []):
        _sources_by_slug.setdefault(_slug, []).append((_sling_id, _sling_rig_root, _raw_lbl))

    for lbl in labels:
        if lbl == "pool:refused" or lbl.startswith("pool:refused:"):
            try:
                subprocess.run(
                    _bd + ["label", "remove", bead_id, lbl, "-q"],
                    capture_output=True, text=True, timeout=15)
            except Exception as exc:
                print(f"[INFLIGHT-RECLAIM] warn: remove {lbl} from {bead_id}: {exc}",
                      flush=True)
            # ga-9d80l gate-fix-2/3: also consume the label AT ITS SOURCE
            # when it was bridged from a sling — otherwise the sling keeps
            # carrying it forever and a later cycle re-bridges the same
            # stale refusal (see docstring above). Use the sling's own raw
            # label text (_raw_lbl), NOT `lbl` — `lbl` is the synthesized
            # colon-form text, which does not match a bare-source sling's
            # actual label (gate-fix-3).
            _slug = _refusal_slug_of_label(lbl)
            for _sling_id, _sling_rig_root, _raw_lbl in _sources_by_slug.get(_slug, []):
                _sling_bd = ["bd", "-C", _sling_rig_root] if _sling_rig_root else ["bd"]
                try:
                    subprocess.run(
                        _sling_bd + ["label", "remove", _sling_id, _raw_lbl, "-q"],
                        capture_output=True, text=True, timeout=15)
                except Exception as exc:
                    print(f"[INFLIGHT-RECLAIM] warn: remove {_raw_lbl} from bridge "
                          f"source {_sling_id}: {exc}", flush=True)
    for slug in fresh_slugs:
        try:
            subprocess.run(
                _bd + ["label", "add", bead_id, f"pilot:refused-reason:{slug}", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] warn: add pilot:refused-reason:{slug} {bead_id}: {exc}",
                  flush=True)

    new_refusal_count = refusal_count + 1
    if refusal_count > 0:
        try:
            subprocess.run(
                _bd + ["label", "remove", bead_id, f"pilot:refusal-count:{refusal_count}", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass  # old label may already be missing; ignore
    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, f"pilot:refusal-count:{new_refusal_count}", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: set refusal-count label {bead_id}: {exc}", flush=True)

    existing_slugs = [
        l[len("pilot:refused-reason:"):] for l in labels
        if l.startswith("pilot:refused-reason:")
    ]
    all_slugs = list(existing_slugs)
    for slug in fresh_slugs:
        if slug not in all_slugs:
            all_slugs.append(slug)
    return new_refusal_count, fresh_slugs, all_slugs


def _remove_label_verified(bd_prefix, bead_id, label, attempts=4, delay_secs=1.0):
    """Remove `label` from `bead_id` and confirm via read-back that it is
    actually gone, retrying on failure (ga-jzye0; mirrors the read-back +
    retry-x4 pattern quality-gate-dispatcher.sh already uses for verified
    assignee writes — assign_verdict_bead_verified).

    Verification reads the CURRENT label set off the bead, not the remove
    command's own returncode: a `bd label remove` can report success on a
    race (label already gone) or failure on a transient Dolt hiccup that
    landed anyway — the only fact that matters is whether the label is
    present NOW, not what the command claimed.

    Returns True once a read-back confirms the label is absent (including if
    it was already absent — the label-remove call is then simply skipped by
    the caller, which only invokes this when the label was in the last-known
    label set). Returns False if, after `attempts` tries, a read-back still
    shows the label present, or the read-back cannot be trusted at all (bd
    show failed, returned unparseable JSON, or returned something that isn't
    a real bead object) — fail toward "could not confirm", so a caller never
    proceeds to clear ownership on the strength of an unverified removal.

    ga-jzye0 self-audit: an error envelope (bead not found, transient query
    failure) is NOT a bead with an empty labels list — collapsing the two
    would read "couldn't check" as "confirmed gone", the same third-state bug
    this whole fix exists to close elsewhere. `bead.get("labels")` alone
    can't tell the two apart (both yield `None`/missing -> `[]`), so the
    shape is checked explicitly: only a dict that actually carries a
    "labels" key counts as a real read-back.
    """
    for attempt in range(1, attempts + 1):
        try:
            subprocess.run(bd_prefix + ["label", "remove", bead_id, label, "-q"],
                            capture_output=True, text=True, timeout=15)
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] warn: label remove {label} on {bead_id} "
                  f"attempt {attempt}/{attempts}: {exc}", flush=True)
        current_labels = None
        try:
            r = subprocess.run(bd_prefix + ["show", bead_id, "--json"],
                                capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                raise RuntimeError(f"bd show rc={r.returncode}: {(r.stderr or '').strip()[:200]}")
            data = json.loads(r.stdout)
            bead = data[0] if isinstance(data, list) else data
            if not isinstance(bead, dict) or "labels" not in bead:
                raise RuntimeError(f"bd show did not return a bead object with a labels "
                                    f"field (got: {str(data)[:200]})")
            current_labels = bead.get("labels") or []
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] warn: read-back verify {label} on {bead_id} "
                  f"attempt {attempt}/{attempts}: {exc}", flush=True)
        if current_labels is not None and label not in current_labels:
            return True
        if attempt < attempts:
            time.sleep(delay_secs)
    return False


def _close_orphaned_sling(bd_prefix, sling_bead_id, target_bead_id, hold_secs):
    """Close sling_bead_id if it is still open and unclaimed (ga-xlnkf).

    Called only when do_reclaim() reclaims AND HOLDS a target bead (pilot:held
    stamped, step 3b below). The sling wrapper `gc sling` minted for the
    dispatch that just got reclaimed now points at a bead sitting in a
    reloop-cooldown hold — nothing can claim it productively for the hold's
    duration — but this guard only ever watches the TARGET's progress, never
    the sling's own claim status, so pre-fix the sling stayed open+unassigned
    for the full cooldown. A pool worker's self-serve probe
    (`bd ready --metadata-field gc.routed_to=... --unassigned`) can claim that
    orphaned sling, discover the target is held, and burn a whole pool cycle
    recognizing it as stale before closing it by hand. The existing
    sling-task-janitor daemon is a backstop for this same class of orphan, but
    it never acts on a stub younger than 60min (SLING_MIN_AGE_MIN) and only
    sweeps every 15min — far slower than a pool worker can respawn and
    re-claim. Closing the sling HERE, synchronously with the hold, removes the
    race instead of just waiting it out.

    Returns True only if this call actually closed the sling. False covers
    every other outcome — no sling metadata, already claimed/in_progress,
    already closed, or a probe/close error — and is the expected, harmless
    result in most of those cases, not a failure signal. Never raises:
    mirrors this file's fail-open contract so a sling-cleanup hiccup can never
    block or corrupt the target's own reclaim.

    CONTROL (ga-xlnkf AC2): a sling already in_progress may have a live
    worker on it RIGHT NOW — reclaiming live work out from under a worker is
    the single most expensive mistake in this domain. This only ever acts on
    status=="open" with an empty assignee, read FRESH via `bd show` — the
    sling was never part of Pass 1's bead snapshot (that query only ever
    fetches TARGET beads), so there is no stale-snapshot risk here, but the
    live read-back is also what makes the in_progress guard trustworthy.

    CONTROL (ga-xlnkf AC3): a target reclaimed without sling metadata
    (sling_bead_id falsy) is a normal case — not every in-flight bead was
    dispatched via `gc sling` — and must not raise or otherwise disturb the
    caller's own reclaim.
    """
    if not sling_bead_id:
        return False  # ga-xlnkf AC3: no sling metadata is normal, not an error
    try:
        r = subprocess.run(bd_prefix + ["show", sling_bead_id, "--json"],
                            capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            raise RuntimeError(f"bd show rc={r.returncode}: {(r.stderr or '').strip()[:200]}")
        data = json.loads(r.stdout)
        sling = data[0] if isinstance(data, list) else data
        if not isinstance(sling, dict) or "status" not in sling:
            raise RuntimeError(f"bd show did not return a bead object with a status "
                                f"field (got: {str(data)[:200]})")
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: could not read sling {sling_bead_id} "
              f"(target {target_bead_id}) — leaving it alone: {exc}", flush=True)
        return False

    # ga-xlnkf AC2: status must still be open with nobody claiming it — a
    # sling in_progress may have a live worker RIGHT NOW; a closed sling
    # needs no action either. Only the exact open+unassigned shape qualifies.
    if sling.get("status") != "open" or (sling.get("assignee") or ""):
        return False

    try:
        r = subprocess.run(
            bd_prefix + ["close", sling_bead_id, "--reason",
             f"superseded-by-reclaim-hold: target bead {target_bead_id} was reclaimed "
             f"and held (pilot:held, {hold_secs // 60}min cooldown) by "
             f"inflight-reclaim-guard (ga-xlnkf) while this sling sat open and "
             f"unclaimed — closing here avoids a pool worker later self-claiming it "
             f"and burning a cycle discovering the held target."],
            capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            print(f"[INFLIGHT-RECLAIM] warn: close orphaned sling {sling_bead_id} "
                  f"(target {target_bead_id}) rc={r.returncode}: "
                  f"{(r.stderr or '').strip()[:200]}", flush=True)
            return False
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: close orphaned sling {sling_bead_id} "
              f"(target {target_bead_id}): {exc}", flush=True)
        return False

    print(f"[INFLIGHT-RECLAIM] ga-xlnkf: closed orphaned sling {sling_bead_id} "
          f"(superseded-by-reclaim-hold, target {target_bead_id})", flush=True)
    return True


def do_reclaim(bead_id, bead_title, reclaim_count, idle_min, labels, rig_root=None,
                has_explicit_refusal=False, refusal_count=0, bridge_sources=None,
                sling_bead_id=None):
    """Strip story:in-flight (+pilot:dispatched if present), clear assignee,
    bump reclaim label.

    ga-mfeip (cross-store): rig_root, when set, routes every bd mutation to the
    bead's own rig store (bd -C rig_root) instead of defaulting to HQ. HQ-native
    beads pass rig_root=None and use plain bd (existing behavior unchanged).

    ga-be4x: when has_explicit_refusal is True, this reclaim was triggered by a
    worker's STATED refusal (not an unexplained drain). In addition to the
    normal reclaim mechanics, the ephemeral pool:refused[:reason] marker(s) are
    consumed (removed — so a stale marker never gets mistaken for a FRESH
    refusal by a later, unrelated drain) and folded into a permanent
    pilot:refused-reason:<slug> audit label per reason, plus a bumped
    pilot:refusal-count:N. Both counters advance together because a
    refusal-triggered reclaim is still a reclaim (MAX_RECLAIMS stays a valid
    backstop) — refusal_count just ALSO feeds the faster
    REFUSAL_ESCALATE_THRESHOLD circuit-breaker in reclaim_decision.

    ga-jzye0: label removal (step 1) is now verified-with-retry, and this
    function returns False WITHOUT touching assignee/status/reclaim-count if
    it cannot confirm removal. Previously each label-remove was a single
    unverified attempt; a transient Dolt hiccup hitting JUST that call (while
    the separate assignee-clear/status-open/reclaim-count-bump calls below
    still succeeded) left a bead with assignee cleared, status=open,
    pilot:reclaim-count bumped — YET story:in-flight/pilot:dispatched still
    attached. That combination is invisible to re-dispatch (still reads
    in-flight) AND invisible to every dead-worker/lane-occupancy check
    (they only evaluate a NON-EMPTY assignee; an empty one is deliberately
    treated as an unresolved leg -> keep). Confirmed live: wa-zly4n sat in
    exactly this state — pilot:reclaim-count:1, assignee cleared,
    story:in-flight still present — hours after the reclaim that produced it.
    Aborting before assignee/status are touched means a failed reclaim now
    leaves the bead exactly as it was (still reads in-flight+assigned, safe,
    retried next sweep) instead of half-done.

    ga-xlnkf: sling_bead_id, when given, is this bead's OWN
    metadata.pilot.sling_bead — the dispatch-sling wrapper `gc sling` minted
    to hand this bead to a builder. On a reclaim that also stamps pilot:held
    (reclaim_count >= 1, step 3b below), that sling is now orphaned — see
    _close_orphaned_sling()'s docstring — and gets closed here if it is still
    open and unclaimed. Optional: most in-flight beads were never dispatched
    via `gc sling`, and this parameter is simply absent for those (AC3).

    Returns True if all bd ops succeeded, False if any failed (still best-effort).
    """
    new_count = reclaim_count + 1
    ok = True

    # 0. ga-ufr7: push-before-reclaim safety net. A builder that went quiet from
    #    throttling (not death) may still have committed-but-unpushed work sitting
    #    in a local worktree branch. Preserve it durably BEFORE clearing ownership
    #    below — nothing past this point guarantees the local worktree survives.
    #    Best-effort: never blocks the reclaim itself on a git/network failure.
    _preserved = preserve_unpushed_branch(bead_id)
    if _preserved:
        print(f"[INFLIGHT-RECLAIM] preserve-branch: {bead_id} — " + "; ".join(_preserved),
              flush=True)

    # Build the bd prefix: rig-native beads route to their own store.
    _bd = ["bd", "-C", rig_root] if rig_root else ["bd"]

    # 1. Remove lifecycle labels that are actually present. ga-7m191:
    #    pilot:dispatched may be absent (stripped by a partial prior reclaim);
    #    skipping it avoids a spurious RECLAIM-FAILED on a successful reclaim.
    #    ga-jzye0: verified-with-retry (see _remove_label_verified) — abort
    #    HERE, before assignee/status/reclaim-count are touched, if a label
    #    still can't be confirmed gone. Never leave in-flight labels and
    #    cleared ownership out of sync.
    for lbl in ("story:in-flight", "pilot:dispatched"):
        if lbl not in labels:
            continue
        if not _remove_label_verified(_bd, bead_id, lbl):
            print(f"[INFLIGHT-RECLAIM] warn: could not confirm removal of {lbl} from "
                  f"{bead_id} after retries — aborting this reclaim before assignee/status "
                  f"are touched (ga-jzye0); will retry next sweep", flush=True)
            return False

    # 1b. ga-be4x: consume the ephemeral refusal marker(s) and fold each reason
    #     into a PERMANENT audit label, via the helper shared with do_escalate()
    #     (ga-be4x gate-fix-2). Consuming (removing) pool:refused[:reason] here
    #     is load-bearing: if left in place, a later UNRELATED drain (e.g. a
    #     genuine crash on the next dispatch) would be misread as a fresh
    #     refusal by _has_refusal_label() on the next cycle, double-counting it
    #     against REFUSAL_ESCALATE_THRESHOLD. pilot:refused-reason:<slug> is
    #     never removed — it accumulates so an eventual escalation can quote
    #     every reason a worker ever gave, verbatim, without re-investigation.
    refused_reason_slugs = []
    new_refusal_count = refusal_count
    if has_explicit_refusal:
        new_refusal_count, refused_reason_slugs, _all_reason_slugs = _promote_refusal_labels(
            bead_id, labels, refusal_count, rig_root=rig_root, bridge_sources=bridge_sources)

    # 2. Reset status to open so the Pilot can actually re-dispatch (ga-vw26y).
    #    bd list — and the Pilot's re-dispatch query — default to open-only. A
    #    bead reclaimed but left in_progress is invisible to re-dispatch and
    #    simply strands again (the exact loop this guard exists to break).
    #    Idempotent: a harmless no-op on an already-open bead.
    #
    #    ga-u8fly: this MUST run BEFORE the assignee clear (step 2b) below.
    #    `bd assign` refuses to overwrite another actor's live in_progress
    #    claim without --force (bd-98s5c). While status is still
    #    in_progress, clearing the assignee is silently refused — this
    #    code never checked the subprocess returncode — leaving the bead
    #    "open but still assigned" once this status flip ran anyway, which
    #    any --unassigned dispatch query then excludes forever. Live-
    #    confirmed: wa-m4j75 and wa-fvmo8 both "reclaimed" today (status
    #    flipped to open) but kept their dead session as assignee. Once
    #    status is no longer in_progress, bd assign's refusal condition no
    #    longer applies (empirically verified against the live bd binary),
    #    so step 2b below succeeds without needing --force — no broader
    #    override of bd's own safety check is required.
    try:
        r = subprocess.run(
            _bd + ["update", bead_id, "--status", "open"],
            capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            print(f"[INFLIGHT-RECLAIM] warn: reset status open {bead_id} "
                  f"rc={r.returncode}: {(r.stderr or '').strip()[:200]}", flush=True)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: reset status open {bead_id}: {exc}", flush=True)
        # Non-fatal: the next cycle re-finds the bead (still in_progress +
        # pilot:reclaim-count) and retries.

    # 2b. Clear assignee so Pilot can claim it fresh.
    try:
        r = subprocess.run(
            _bd + ["assign", bead_id, ""],
            capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            print(f"[INFLIGHT-RECLAIM] warn: clear assignee {bead_id} "
                  f"rc={r.returncode}: {(r.stderr or '').strip()[:200]}", flush=True)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: clear assignee {bead_id}: {exc}", flush=True)
        # Non-fatal: Pilot can still re-dispatch without assignee being empty

    # 3. Bump reclaim count label (remove old, add new)
    if reclaim_count > 0:
        try:
            subprocess.run(
                _bd + ["label", "remove", bead_id, f"pilot:reclaim-count:{reclaim_count}", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass  # old label may already be missing; ignore
    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, f"pilot:reclaim-count:{new_count}", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: set reclaim-count label {bead_id}: {exc}", flush=True)

    # 3a. [ga-be4x gate-fix-2: refusal-count bump now happens inside
    #      _promote_refusal_labels(), called at step 1b above — no separate
    #      step needed here; kept as a numbered marker for continuity with the
    #      audit comment below, which still references new_refusal_count.]

    # 3b. ga-l5ud0 FIX #2: re-loop cooldown — stamp pilot:held + pilot:held-until:<now+1h>
    #     on the 2nd+ reclaim (reclaim_count >= 1) to prevent the Pilot from immediately
    #     re-dispatching to the same crew pool before the underlying routing issue is resolved.
    #     ROOT: a bead repeatedly dispatched→abandoned (no branch, crew declines or is off-domain)
    #     re-enters the open pool on reclaim and Pilot picks the same crew again on the next
    #     3-min sweep — the re-stamp loop. imp19's pilot:held mechanism exists in the Pilot's
    #     domain-route-guard (for the DEFER path), but is never stamped after a reclaim.
    #     Stamping it here closes the gap: the Pilot's _filter_candidates honors pilot:held,
    #     so the bead is invisible to auto-dispatch for 1h, giving a Mayor sweep time to
    #     triage and re-route or assign an explicit owner.
    #     THRESHOLD: only on reclaim_count >= 1 (2nd+ reclaim without progress). A first-time
    #     reclaim may be a transient crew churn (config drift, restart); we don't hold on that.
    #     FAIL-OPEN: if the bd calls fail, the hold is not stamped — identical to pre-fix
    #     behaviour (Pilot may re-dispatch, which is acceptable on a first-time transient).
    #     Env-gate: RECLAIM_RELOOP_HOLD_SECS (default 3600 = 1h). Set 0 to disable.
    _reloop_hold = int(os.environ.get("RECLAIM_RELOOP_HOLD_SECS", "3600"))
    _sling_closed = False
    if reclaim_count >= 1 and _reloop_hold > 0:
        _held_until = int(time.time()) + _reloop_hold
        try:
            subprocess.run(
                _bd + ["label", "add", bead_id, "pilot:held", "-q"],
                capture_output=True, text=True, timeout=15)
            subprocess.run(
                _bd + ["label", "add", bead_id, f"pilot:held-until:{_held_until}", "-q"],
                capture_output=True, text=True, timeout=15)
            print(f"[INFLIGHT-RECLAIM] ga-l5ud0: {bead_id} stamped pilot:held (reloop-cooldown, reclaim {new_count}, hold {_reloop_hold}s until {_held_until})",
                  flush=True)
        except Exception as _exc:
            print(f"[INFLIGHT-RECLAIM] warn: could not stamp pilot:held cooldown on {bead_id}: {_exc}",
                  flush=True)

        # ga-xlnkf: the sling wrapper that dispatched THIS attempt is now
        # orphaned — the hold above means nothing can claim it productively
        # until it expires. Close it now instead of leaving it for a pool
        # worker to discover and waste a cycle on, or for the much-slower
        # sling-task-janitor backstop (60min min-age, 15min sweep) to catch.
        _sling_closed = _close_orphaned_sling(_bd, sling_bead_id, bead_id, _reloop_hold)

    # 4. Audit comment
    cleared = " + ".join(l for l in ("story:in-flight", "pilot:dispatched")
                         if l in labels) or "(no in-flight label)"
    _hold_note = (f" pilot:held stamped for {_reloop_hold//60}min cooldown to prevent re-loop (reclaim {new_count-1}+)."
                  if reclaim_count >= 1 and _reloop_hold > 0 else "")
    _sling_note = (f" Its dispatch sling {sling_bead_id} was also closed "
                   f"(superseded-by-reclaim-hold, ga-xlnkf)."
                   if _sling_closed else "")
    _preserve_note = (" Preserved unpushed work (ga-ufr7): " + "; ".join(_preserved) + "."
                       if _preserved else "")
    _refusal_note = (
        f" ga-be4x: this reclaim was an EXPLICIT worker refusal (reason(s): "
        f"{', '.join(refused_reason_slugs) or 'unspecified'}) — not an unexplained "
        f"drain. refusal {new_refusal_count}/{REFUSAL_ESCALATE_THRESHOLD}; one more "
        f"independent refusal escalates to gate:needs-human regardless of reclaim cap."
        if has_explicit_refusal else "")
    try:
        subprocess.run(
            _bd + ["comment", bead_id,
             f"inflight-reclaim-guard (ga-se62o): reclaimed — no live builder and "
             f"no recent branch progress for {idle_min:.0f}min "
             f"(> {RECLAIM_TTL//60}min TTL). {cleared} "
             f"cleared; assignee unset; status reset to open (ga-vw26y)."
             f"{_hold_note}"
             f"{_sling_note}"
             f"{_preserve_note}"
             f"{_refusal_note} "
             f"Pilot will re-dispatch. (reclaim {new_count}/{MAX_RECLAIMS})"],
            capture_output=True, text=True, timeout=15)
    except Exception:
        pass  # comment failure is non-fatal

    return ok


def do_escalate(bead_id, bead_title, reclaim_count, idle_min, labels, rig_root=None,
                 has_explicit_refusal=False, refusal_count=0, bridge_sources=None):
    """Mark a permanently-failing bead gate:needs-human — do NOT re-clear it.

    ga-6ow4v: the reclaim cap is exhausted (MAX_RECLAIMS reclaims of the SAME
    bead all failed to produce a healthy builder). Per spec we must NOT clear
    story:in-flight again: clearing lets the Pilot re-dispatch the bead, and
    because the pilot:reclaim-count label persists at the cap, the guard would
    re-escalate on the very next cycle — an endless dispatch↔reclaim loop that
    fires a ntfy every REALERT_SEC and never converges.

    Instead we ADD gate:needs-human and leave story:in-flight + assignee intact.
    This (a) hands the bead to a human/Mayor with an unambiguous flag, and (b)
    trips the guard's OWN has_needs_human safety rail next cycle (reclaim_decision
    returns "noop" for needs-human beads), so the bead parks quietly: no loop,
    no repeat ntfy. One held lane slot is the deliberate tradeoff for a story
    that has proven un-buildable; a human investigates and re-queues it.

    ga-mfeip (cross-store): rig_root routes bd mutations to the bead's own rig
    store when set. HQ-native beads pass rig_root=None (existing behavior).

    ga-be4x: has_explicit_refusal=True means THIS escalation was triggered by
    REFUSAL_ESCALATE_THRESHOLD independent workers explicitly refusing the
    bead — a different circuit-breaker class than the generic MAX_RECLAIMS
    thrash cap. It ADDS gate:needs-human:refused alongside (not instead of)
    the existing gate:needs-human:technical: quorum-convergence-watchdog.py's
    Fallback trigger B does an EXACT `--label gate:needs-human:technical`
    query (not a prefix scan) to auto-convene a 3-crew quorum vote on any
    bead an automation circuit-breaker parked and a human hasn't addressed
    within MAYOR_STALE_SEC — swapping the sub-label instead of adding to it
    would silently drop refusal-escalated beads out of that safety net
    (worst case: a named-crew assignee, which gets no immediate Mayor mail
    below, parked forever with nothing to re-evaluate it). :technical
    remains an accurate description regardless — a refusal is still a
    technical/scoping circuit-breaker park, not a product decision. The
    comment additionally quotes every accumulated pilot:refused-reason:<slug>
    label verbatim so a Mayor can act without re-discovering the reason from
    scratch (ga-be4x fix item 3).

    ga-be4x gate-fix-2: reclaim_decision() reaches "escalate" WITHOUT ever
    calling do_reclaim() — the only function that used to promote a fresh
    pool:refused:<reason> label into the permanent pilot:refused-reason:<slug>
    form. That left the 2nd (triggering) worker's own reason un-promoted,
    un-consumed, and absent from both this comment and the
    [POOL-REFUSED-ESCALATED] Mayor-mail run_cycle() sends right after calling
    this function. Fixed by calling the shared _promote_refusal_labels() helper
    here FIRST, before deriving the reason text, so the triggering reason is
    folded in exactly like any prior one. Returns the complete list of reason
    slugs (empty list on the non-refusal path) so run_cycle() can reuse it
    for its own mail body instead of re-deriving (and re-dropping) it.
    """
    # Build the bd prefix: rig-native beads route to their own store.
    _bd = ["bd", "-C", rig_root] if rig_root else ["bd"]

    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, "gate:needs-human", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human {bead_id}: {exc}",
              flush=True)
    # imp13: sub-label classifies this as a TECHNICAL circuit-breaker park (not
    # a product decision). Always added — see ga-be4x note above re: the
    # quorum-convergence-watchdog dependency on this exact label surviving.
    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, "gate:needs-human:technical", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human:technical {bead_id}: {exc}",
              flush=True)
    # ga-be4x: ADDITIONAL sub-label — never a replacement — naming the more
    # specific circuit-breaker class so a human sees WHY at a glance.
    if has_explicit_refusal:
        try:
            subprocess.run(
                _bd + ["label", "add", bead_id, "gate:needs-human:refused", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] warn: add gate:needs-human:refused {bead_id}: {exc}",
                  flush=True)

    if has_explicit_refusal:
        # ga-be4x gate-fix-2: promote THIS cycle's still-fresh
        # pool:refused:<reason> label — the very one that crossed
        # REFUSAL_ESCALATE_THRESHOLD and triggered this escalation — BEFORE
        # reading reasons for the comment. reclaim_decision() short-circuits
        # straight to "escalate" without ever calling do_reclaim(), so without
        # this call the triggering reason was silently dropped (never
        # promoted, never consumed, never read).
        new_refusal_count, _fresh_reason_slugs, all_reason_slugs = _promote_refusal_labels(
            bead_id, labels, refusal_count, rig_root=rig_root, bridge_sources=bridge_sources)
        _reason_text = ", ".join(all_reason_slugs) if all_reason_slugs else "unspecified"
        try:
            subprocess.run(
                _bd + ["comment", bead_id,
                 f"inflight-reclaim-guard (ga-be4x): ESCALATED — "
                 f"{new_refusal_count} independent workers EXPLICITLY REFUSED this "
                 f"bead (reason(s): {_reason_text}). This is not an unexplained "
                 f"death — re-dispatching again cannot succeed where "
                 f"{new_refusal_count} workers already reached the same reasoned "
                 f"conclusion. Marked gate:needs-human:refused; story:in-flight "
                 f"RETAINED (not re-cleared) to avoid a dispatch↔reclaim loop. "
                 f"Human/Mayor must re-route or re-scope, then re-queue."],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass
        return all_reason_slugs

    # ga-egd5av (2026-08-15): reset pilot:reclaim-count so a human clearing
    # gate:needs-human automatically grants a genuinely FRESH reclaim budget —
    # mirroring the gate:fix-attempt:0 reset convention quality-gate-
    # dispatcher.sh already supports for its own, separate retry cap. Without
    # this, the label stays pinned at MAX_RECLAIMS forever: a human clears
    # gate:needs-human (the only guard that makes reclaim_decision() noop —
    # see has_needs_human at the top of that function), but reclaim_count is
    # UNCHANGED, so the very next time this bead is found stranded past TTL
    # for ANY reason — even one unrelated to the original reclaims, e.g. the
    # newly re-routed owner simply hasn't started yet — reclaim_decision()
    # skips straight back to "escalate" (reclaim_count >= MAX_RECLAIMS is
    # still true) and silently re-adds gate:needs-human, undoing the human's
    # fix. Measured live on wa-uknuq (ga-egd5av): Mayor cleared
    # gate:needs-human + set gc.routed_to=mila-wa at 05:39Z; this exact
    # stale-count replay re-escalated at 09:02:18Z with NO new reclaim in
    # between — reclaim_count was 3 both times, since do_reclaim() never
    # fires again once capped (reclaim_decision always returns "escalate",
    # never "reclaim", once the count reaches the cap), so the sticky label
    # can never organically grow past MAX_RECLAIMS on its own.
    #
    # Swap the numeric pilot:reclaim-count:<N> label for a non-numeric
    # "spent" marker rather than deleting it outright (keeps a permanent,
    # readable audit trail of the escalation on the bead, and mirrors
    # do_reclaim()'s own remove-old/add-new bump shape immediately below).
    # parse_reclaim_count() already treats an unparseable suffix as "keep
    # looking, default 0" (`except ValueError: pass`, falls through to the
    # trailing `return 0`), so once this is the only pilot:reclaim-count:*
    # label left, the NEXT reclaim_decision() call reads reclaim_count=0 —
    # genuinely fresh, not a replay — and a future stranding reclaims
    # normally (up to MAX_RECLAIMS more times) instead of instantly
    # re-escalating on the same exhausted count. Only reached from the
    # non-refusal cap path (has_explicit_refusal already returned above): a
    # refusal escalation is inherently fresh evidence every time it fires
    # (it requires a NEW pool:refused label posted THIS cycle), so
    # pilot:refusal-count is intentionally left untouched here.
    if reclaim_count > 0:
        try:
            subprocess.run(
                _bd + ["label", "remove", bead_id, f"pilot:reclaim-count:{reclaim_count}", "-q"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass  # old label may already be missing; ignore
    try:
        subprocess.run(
            _bd + ["label", "add", bead_id, f"pilot:reclaim-count:escalated-at-{reclaim_count}", "-q"],
            capture_output=True, text=True, timeout=15)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: mark reclaim-count spent {bead_id}: {exc}", flush=True)

    try:
        subprocess.run(
            _bd + ["comment", bead_id,
             f"inflight-reclaim-guard (ga-6ow4v): ESCALATED — reclaim cap "
             f"({MAX_RECLAIMS}) exhausted. Bead stranded {idle_min:.0f}min with no "
             f"live builder or branch progress across {reclaim_count} reclaims. "
             f"Marked gate:needs-human; story:in-flight RETAINED (not re-cleared) "
             f"to avoid a dispatch↔reclaim loop. pilot:reclaim-count reset "
             f"(ga-egd5av) — clearing gate:needs-human alone now grants a fresh "
             f"reclaim budget, no extra manual step needed. Human/Mayor must "
             f"investigate and re-queue."],
            capture_output=True, text=True, timeout=15)
    except Exception:
        pass
    return []


# ---------------------------------------------------------------------------
# ga-seuh4 / ga-a8t68: self-heal order:orphan-sweep's false resets
# ---------------------------------------------------------------------------

def list_orphan_sweep_false_resets():
    """List beads that look like a wrongful order:orphan-sweep reset:
    status=open, no assignee, but gc.session_name/gc.routed_to metadata
    (written at claim time) still intact — from HQ + all rig stores.

    order:orphan-sweep resets a bead via `gc bd update <id> --status=open
    --assignee=""` — it clears ONLY status+assignee, never the gc.* metadata
    a dog/wa-worker-pool claim writes at claim time. A bead carrying that
    metadata combination is therefore either (a) a claim orphan-sweep JUST
    wrongfully reset while the session was still alive, or (b) a claim
    orphan-sweep correctly reset because the session really did die. Both
    look identical from this query alone — heal_orphan_sweep_false_resets()
    disambiguates by checking live session state before acting on either.

    Returns [] on query error (fail-safe: caller skips healing this cycle —
    never worse than not healing at all, which was the pre-fix status quo).

    NOTE: `bd list --has-metadata-key` is a single-value flag, not repeatable
    — passing it twice silently keeps only the LAST occurrence (confirmed
    live: `--has-metadata-key A --has-metadata-key B` returns exactly the
    same set as `--has-metadata-key B` alone), it does NOT AND the two keys
    together. So this only asks bd to filter on gc.session_name server-side;
    the gc.routed_to requirement is enforced locally in the loop below.
    """
    def _has_both_keys(b):
        meta = b.get("metadata") or {}
        return bool(meta.get("gc.session_name")) and bool(meta.get("gc.routed_to"))

    candidates = {}
    try:
        result = subprocess.run(
            ["bd", "list", "--status", "open",
             "--has-metadata-key", "gc.session_name",
             "--no-assignee", "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            if isinstance(data, list):
                for b in data:
                    bid = b.get("id", "")
                    if bid and _has_both_keys(b):
                        b.setdefault("rig_root", None)
                        candidates[bid] = b
    except Exception:
        pass  # HQ failure just yields fewer candidates; rig loop below is independent

    # ga-u8fly: `or []` preserves this function's own documented fail-open
    # contract ("[] on query error... never worse than not healing at all")
    # when _list_rig_stores() reports a genuine enumeration failure (None).
    # ga-1qqoi: that fallback was silent — signal it before falling back;
    # behavior (fail-open, HQ-only this cycle) is unchanged.
    _rig_stores = _list_rig_stores()
    if _rig_stores is None:
        print("[INFLIGHT-RECLAIM] warn: gc rig list failed — orphan-sweep "
              "self-heal scan covers HQ only this cycle", flush=True)
        _rig_stores = []
    for _rig_name, rig_path in _rig_stores:
        try:
            r = subprocess.run(
                ["bd", "-C", rig_path, "list", "--status", "open",
                 "--has-metadata-key", "gc.session_name",
                 "--no-assignee", "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=20)
            if r.returncode != 0 or not r.stdout.strip():
                continue
            rig_data = json.loads(r.stdout)
            if not isinstance(rig_data, list):
                continue
            for b in rig_data:
                bid = b.get("id", "")
                if bid and bid not in candidates and _has_both_keys(b):
                    b["rig_root"] = rig_path
                    candidates[bid] = b
        except Exception:
            continue  # fail-open per rig store

    return list(candidates.values())


def _has_deliberate_release_signal(labels):
    """True if labels show a DELIBERATE decision already stood this claim
    down — the claiming session's own explicit refusal/park, or an
    authority's active hold/escalation — as opposed to order:orphan-sweep's
    blind, unexplained status/assignee reset (ga-f6igb; see the module
    docstring's own "ga-f6igb" section for the two confirmed live incidents
    this closes: ga-wgvca's refuse-then-reclaim, ga-wzl83's deliberate park).

    heal_orphan_sweep_false_resets() must NEVER restore a claim when this is
    True: doing so would silently undo an intentional decision rather than
    compensate for an accidental one.

    Reuses this file's own _has_refusal_label() (pool:refused[:reason]) and
    _has_needs_human_label() (gate:needs-human[:*] / bare needs-human — also
    covers the bead already having been escalated by this guard's own
    do_escalate(), which must never be silently re-opened by this heal).
    Adds three more markers by name, matching the exact literal strings
    do_reclaim()/do_escalate() elsewhere in this file already stamp, rather
    than importing bead_state.py's PARK_EXACT/PARK_PREFIXES wholesale:
    pilot:no-auto-dispatch (explicit stand-down, ga-wzl83), pilot:held /
    pilot:held-until:<epoch> (an active hold already governs re-dispatch —
    checked as bare-exact + a distinct ":"-prefix, NOT a blanket "pilot:held"
    prefix, because bead_state.py's own PARK_EXACT comment documents that a
    raw prefix there collides with the never-cleared pilot:held-count:
    <slug>:<n> bookkeeping counter), and story:awaiting-external-merge
    (explicit "done, blocked on an outside event" park).

    Deliberately NOT the full PARK_PREFIXES/PARK_EXACT union: labels like
    ctx:thin/blocked/story:cancelled/on-device describe OTHER reasons a bead
    might be unready, unrelated to whether THIS specific claim's release was
    deliberate. Treating them as heal-blockers would leave a genuinely
    orphan-sweep-false-reset bead sitting open+unassigned — its
    ctx:ready/exec:auto/story:in-flight labels untouched by the reset, per
    list_orphan_sweep_false_resets()'s own docstring — and newly exposed to
    routed-pool re-dispatch: the exact double-claim harm ga-seuh4 exists to
    prevent, just moved to a different trigger.
    """
    if _has_refusal_label(labels) or _has_needs_human_label(labels):
        return True
    for lbl in labels:
        if lbl in ("pilot:no-auto-dispatch", "pilot:held", "story:awaiting-external-merge"):
            return True
        if lbl.startswith("pilot:held-until:"):
            return True
    return False


def _has_orphan_sweep_reset_marker(labels):
    """True if labels carry "orphan-sweep:reset" — orphan-sweep.sh's own,
    positive, same-call-atomic stamp that IT (not some other mechanism, not
    a deliberate release) performed the status/assignee reset this candidate
    is being evaluated for (ga-f6igb round 2, GATE-FEEDBACK gate_run=ga-2esd2
    blocking issue 1).

    This exists because labels describing DELIBERATE intent
    (_has_deliberate_release_signal() above) cannot, even in principle, cover
    every deliberate release: order:orphan-sweep's own reset is always
    unlabeled, so "unlabeled" can never be read as "therefore accidental" —
    it is also exactly what an unlabeled deliberate release looks like (the
    on-thread ga-5ksp5 precedent). Flipping the source of truth to a marker
    orphan-sweep.sh stamps ON ITSELF closes the gap from the side that CAN be
    made reliable: orphan-sweep.sh is a single, fully-owned call site
    (packs/town-deltas/assets/scripts/orphan-sweep.sh, Step 3), unlike every
    OTHER place in this city a deliberate release can originate from.

    See heal_orphan_sweep_false_resets() for the single-use contract (this
    marker is stripped the moment it's read, for every candidate evaluated,
    regardless of outcome — never trust a leftover instance of this label as
    fresh evidence).
    """
    return "orphan-sweep:reset" in labels


def heal_orphan_sweep_false_resets(sessions, now):
    """Restore beads whose claim was wrongfully reset by order:orphan-sweep
    (ga-seuh4/ga-a8t68) while the claiming session was still genuinely alive.

    See the module docstring's "ga-seuh4 / ga-a8t68" section for the full
    root-cause writeup. In short: orphan-sweep.sh's own is_known_agent() check
    (bash-side, packs/town-deltas/assets/scripts/orphan-sweep.sh — a
    git-tracked override, NOT go:embed'd in this city) has no staleness/health
    notion, just raw presence-in-a-snapshot, and that snapshot has repeatedly
    missed a genuinely-live claimant despite two prior hardening layers
    (ga-u0vzx, ga-kq4jf). This is a compensating self-heal, not a prevention:
    it cannot stop orphan-sweep's own check from failing, but it detects the
    reset within one of THIS guard's own poll cycles (same ~5min cadence as
    orphan-sweep's own sweep), restores the claim before a competing worker
    can race into the reopened bead, and (ga-114ll) stamps a much longer
    explicit shield so the SAME transient can't immediately re-trigger the
    same wrongful reset — provided the original session is still alive when
    this check runs.

    Reuses concrete_adhoc_session_is_live() for the liveness check — the same
    multi-field identifier matching + staleness/awaiting-human-input handling
    already relied on elsewhere in this file, so a session that is
    live-but-quiet (long extended-thinking turn, sub-agent tool call) is
    correctly treated as alive, not left unhealed by this guard's own logic.

    Fails safe in every direction: a candidate-query error yields []
    (nothing healed, never worse than the pre-fix status quo); a bead already
    re-claimed by someone else since the reset no longer matches the
    --no-assignee query and is left alone; a session that is genuinely dead
    (concrete_adhoc_session_is_live → False) is left open for normal
    re-dispatch, exactly as orphan-sweep intended.

    ga-f6igb: also never restores a candidate carrying an explicit deliberate-
    release label (_has_deliberate_release_signal()) — a live session is
    necessary but NOT sufficient evidence the reset was orphan-sweep's
    accident; the SAME live session may have just deliberately stood the
    claim down. See that helper's own docstring for the exact label set and
    why it is a narrow, curated subset rather than every known park label.

    ga-f6igb round 2 (GATE-FEEDBACK gate_run=ga-2esd2): the label check above
    is necessary but, on its own, NOT sufficient — order:orphan-sweep's own
    reset is always unlabeled, so "no recognized label" cannot be read as
    "therefore accidental" (see _has_orphan_sweep_reset_marker()'s docstring
    and the module docstring's round-2 section for why no labeling vocabulary
    can close this, and why no other attribution signal in this codebase
    does either). Restoring a claim now ALSO requires orphan-sweep.sh's own
    positive "orphan-sweep:reset" marker to be present — collapsing "cannot
    determine whether this was deliberate" into "proceed as if it wasn't" is
    the exact third-state failure this fix closes. The marker is read and
    stripped (single-use) for every candidate this function evaluates,
    whether or not that candidate goes on to heal.

    Returns count of beads healed this cycle.
    """
    candidates = list_orphan_sweep_false_resets()
    if not candidates:
        return 0
    healed = 0
    for b in candidates:
        bead_id = b.get("id", "")
        if not bead_id:
            continue
        meta = b.get("metadata") or {}
        stale_assignee = meta.get("gc.session_name") or ""
        if not stale_assignee:
            continue
        labels = b.get("labels") or []
        rig_root = b.get("rig_root")
        _bd = ["bd", "-C", rig_root] if rig_root else ["bd"]

        # ga-f6igb round 2: read + immediately consume the positive
        # orphan-sweep marker BEFORE any of the checks below, independent of
        # which branch ultimately decides this candidate's outcome. This is
        # deliberate, not incidental ordering — if the strip only happened
        # inside the eventual heal branch, a marker attached to a candidate
        # that gets skipped for an UNRELATED reason (e.g. it also happens to
        # carry a stale deliberate-release label from a much earlier,
        # already-resolved incident on the same bead id) would survive to be
        # wrongly read as fresh evidence on some LATER, unrelated reset of
        # that same id. Uses _remove_label_verified() (ga-jzye0), not a bare
        # subprocess.run — this is the same risk class do_reclaim() already
        # hardened elsewhere in this file: a `bd label remove` that reports
        # rc=0 without durably landing (Dolt replication lag / transient
        # hiccup) would leave the marker readable again on a later cycle,
        # silently reopening the exact stale-residue window this consumption
        # step exists to close. A confirmed-failed removal does NOT change
        # THIS cycle's decision below (has_orphan_sweep_marker already
        # reflects what was true at read time) — it only means a future
        # cycle might see the marker again, which is logged honestly rather
        # than silently assumed away.
        has_orphan_sweep_marker = _has_orphan_sweep_reset_marker(labels)
        if has_orphan_sweep_marker:
            if not _remove_label_verified(_bd, bead_id, "orphan-sweep:reset"):
                print(f"[INFLIGHT-RECLAIM] warn: could not confirm removal of "
                      f"orphan-sweep:reset on bead={bead_id} after retries — "
                      f"proceeding with this cycle's decision anyway; a future "
                      f"cycle may still see this marker", flush=True)

        # ga-f6igb: a deliberate stand-down (explicit refusal, park, active
        # hold, or prior escalation) looks IDENTICAL to an orphan-sweep false
        # reset from this point on — both leave gc.* metadata intact with the
        # claiming session still live. Only a label can tell them apart; see
        # _has_deliberate_release_signal()'s own docstring for the two
        # confirmed live incidents (ga-wgvca, ga-wzl83) this check closes.
        if _has_deliberate_release_signal(labels):
            # GATE-FEEDBACK (gate_run=ga-2esd2, blocking issue 2): this branch
            # is reached on every unconditional run_cycle() pass (POLL_SEC,
            # default 600s) for as long as the bead sits open+unassigned+
            # labeled — routinely 8-27 days per this bug's own thread (see
            # Mayor's 2026-08-13 comments on this bead). emit() doesn't just
            # log, it fires a real -p4 (high-priority) push notification —
            # that's 100+ redundant pages/day for a correctly-skipped,
            # non-actionable event. print() matches this same function's own
            # convention for its other skip/warn paths a few lines below
            # (self-heal update failed/exception) — informational, not
            # page-worthy.
            print(f"[INFLIGHT-RECLAIM] [SELF-HEAL-SKIPPED] bead={bead_id} "
                  f"carries a deliberate-release label — NOT restoring "
                  f"assignee={stale_assignee!r} (ga-f6igb)", flush=True)
            continue
        # Freshness guard: this metadata shape (open + unassigned + stale
        # gc.session_name of a still-live session) is NOT unique to an
        # orphan-sweep false-reset — a session that deliberately releases a
        # duplicate claim (`bd update <id> -a "" -s open`, the standard
        # stand-down move documented in dog-pool-slot-inherits-prior-
        # incarnation-work precedent) leaves the identical shape behind,
        # since a stand-down clears assignee/status but not gc.* metadata
        # either. Healing THAT would silently undo a deliberate release.
        # Bounding to beads updated within RECLAIM_TTL keeps this guard
        # useful for its actual job (catching a reset within the next
        # cycle or two after it happens) while limiting a wrong heal's
        # blast radius: past this window, a stale claim is no longer a
        # "just happened" event, and the normal stranding hysteresis below
        # in run_cycle() already owns cleaning it up correctly either way.
        bead_update_epoch = parse_iso_epoch(b.get("updated_at", ""))
        if bead_update_epoch is None or (now - bead_update_epoch) > RECLAIM_TTL:
            continue
        if not concrete_adhoc_session_is_live(stale_assignee, sessions, now):
            continue  # genuinely dead — leave for normal re-dispatch
        if not has_orphan_sweep_marker:
            # ga-f6igb round 2 (GATE-FEEDBACK blocking issue 1): no positive
            # attribution to orphan-sweep — this reset could equally be an
            # unlabeled deliberate release (the ga-5ksp5 shape). Absence of
            # evidence is not evidence of absence: default to NOT healing.
            print(f"[INFLIGHT-RECLAIM] [SELF-HEAL-SKIPPED] bead={bead_id} "
                  f"no orphan-sweep:reset marker — cannot positively "
                  f"attribute this reset to orphan-sweep, NOT restoring "
                  f"assignee={stale_assignee!r} (ga-f6igb)", flush=True)
            continue
        try:
            r = subprocess.run(
                _bd + ["update", bead_id, "--status", "in_progress",
                       "--assignee", stale_assignee],
                capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                print(f"[INFLIGHT-RECLAIM] warn: self-heal update failed "
                      f"bead={bead_id} rc={r.returncode}", flush=True)
                continue
        except Exception as exc:
            print(f"[INFLIGHT-RECLAIM] warn: self-heal update exception "
                  f"bead={bead_id}: {exc}", flush=True)
            continue
        healed += 1
        # ga-114ll: stamp an explicit, much-longer protection window on top of
        # the restore itself. RECENT_UPDATE_GRACE_SECS (30min, bash-side) already
        # treats this restore's own bd-update as "recently touched," but that
        # alone proved insufficient — the same read that missed this claim once
        # can miss it again after the grace period lapses. This shield is a
        # distinct, purpose-built signal orphan-sweep.sh honors unconditionally
        # (see label_matches-style "-until:<epoch>" convention already used for
        # pilot:held-until elsewhere in this file); it accumulates rather than
        # overwrites (ga-4aree class), so readers must take the MAX, never the
        # first/last.
        _shield_until = int(now) + ORPHAN_SWEEP_SELFHEAL_SHIELD_SECS
        _shield_ok = False
        try:
            _r1 = subprocess.run(
                _bd + ["label", "add", bead_id, "orphan-sweep:shielded", "-q"],
                capture_output=True, text=True, timeout=15)
            _r2 = subprocess.run(
                _bd + ["label", "add", bead_id,
                       f"orphan-sweep:shielded-until:{_shield_until}", "-q"],
                capture_output=True, text=True, timeout=15)
            _shield_ok = (_r1.returncode == 0 and _r2.returncode == 0)
        except Exception:
            pass  # shield-stamp failure is non-fatal — the claim restore above already landed
        # ga-114ll / ga-ogvyk (third-state audit): the comment/log below must say
        # what actually happened, not what was attempted — a claimed-but-failed
        # shield read back later as "protected" would be worse than no claim at
        # all (the exact "comment promises more than the code delivers" class).
        if _shield_ok:
            _shield_note = (f"Stamped orphan-sweep:shielded-until:{_shield_until} (ga-114ll, "
                             f"{ORPHAN_SWEEP_SELFHEAL_SHIELD_SECS}s) so orphan-sweep skips "
                             f"this bead for a while instead of re-deriving liveness from "
                             f"the same read that just missed it.")
        else:
            _shield_note = ("Shield stamp FAILED (label add error) — no extra protection "
                             "beyond the claim restore itself; orphan-sweep.sh's own check "
                             "can re-fail this exact bead on the next post-grace sweep.")
        try:
            subprocess.run(
                _bd + ["comment", bead_id,
                       f"inflight-reclaim-guard self-heal (ga-seuh4/ga-a8t68): "
                       f"restored to assignee={stale_assignee!r}, status=in_progress "
                       f"after order:orphan-sweep wrongfully reset this claim while "
                       f"the owning session was still live. {_shield_note} This is a "
                       f"compensating heal, not a prevention — orphan-sweep.sh's own "
                       f"check can still fail the same way once the shield expires."],
                capture_output=True, text=True, timeout=15)
        except Exception:
            pass  # comment failure is non-fatal
        emit(f"[INFLIGHT-RECLAIM] [SELF-HEALED] bead={bead_id} "
             f"restored assignee={stale_assignee!r} (order:orphan-sweep false-reset), "
             f"shielded={_shield_ok}" + (f" until {_shield_until}" if _shield_ok else ""))
    return healed


# ---------------------------------------------------------------------------
# gt-fppb0: dog-pool pre_start preflight driver
# ---------------------------------------------------------------------------

# The exact pool alias a dog uses as GC_ALIAS when it claims work via `gc hook`
# (bd list --status in_progress --assignee gastown.dog). A module constant so the
# preflight query and the fresh dog's Tier-1 work_query can never drift apart.
DOG_POOL_ALIAS = "gastown.dog"


def reclaim_dead_dog_claims(exclude_session_ids=None, sessions=None,
                            now=None, dry_run=False):
    """Reclaim PROVABLY-DEAD dog-pool claims (gt-fppb0). Returns reclaimed ids.

    Intended as the dog agent's pre_start preflight — run immediately before a
    fresh dog executes `gc hook`, whose Tier-1 work_query is
    `bd list --status in_progress --assignee gastown.dog`. If a previous claimant
    dog died mid-claim, that query still returns the zombie bead and the fresh dog
    RE-ADOPTS it, burning pool workers in a respawn loop (the NEVERSTART root that
    pollutes APROVADAS). This driver reclaims the zombie FIRST — resetting it to
    open + clearing the dog assignee — so the fresh dog's query no longer sees it
    and the Pilot re-dispatches it cleanly, to ONE worker, not N.

    Targets EXACTLY the set the fresh dog would re-adopt: in_progress beads whose
    assignee is the bare pool alias 'gastown.dog'. Reuses run_cycle's liveness +
    guard rails verbatim (zero divergence). A bead is reclaimed only when it is
    provably-dead-owned AND every safety guard is clear:
      - claimant provably gone (claimant_provably_dead) — NOT merely quiet;
      - no live pool worker owns it (pool_has_live_worker) and it is not a live
        sling source (list_live_sling_source_beads, ga-qfo3);
      - no recent branch progress (get_branch_recent, fetch=False for speed);
      - not gate:needs-human / :* (parked);
      - no active quality-gate marker (list_gate_active_source_beads);
      - owner not deliberately suspended (list_suspended_agents);
      - account not rate-limited (account_is_rate_limited, ga-ufr7).

    FAIL-OPEN, ALWAYS: any probe error / timeout / unexpected data → returns the
    reclaims done so far (usually none) WITHOUT raising. A pre_start hook must
    never block or delay a spawn. `sessions`/`now` may be injected (tests);
    otherwise fetched. `exclude_session_ids` drops those identifiers from the
    liveness view — belt-and-suspenders: pre_start runs BEFORE the fresh dog's own
    session exists, but if that ever changes, excluding self keeps the preflight
    from reading itself as the pool being alive.

    Only ever fast-reclaims; escalation (reclaim cap exhausted) is left to
    run_cycle — a capped bead needs the manual reset the gt-fppb0 note describes.
    """
    reclaimed = []
    try:
        if now is None:
            now = time.time()

        # Fast healthy path: exactly the fresh dog's Tier-1 query. No candidates
        # → nothing to do; pay for nothing else. Dog hook-claims are HQ-native.
        try:
            r = subprocess.run(
                ["bd", "list", "--status", "in_progress",
                 "--assignee", DOG_POOL_ALIAS, "--json", "--limit", "0"],
                capture_output=True, text=True, timeout=15)
        except Exception:
            return reclaimed  # fail-open
        if r.returncode != 0 or not r.stdout.strip():
            return reclaimed
        try:
            beads = json.loads(r.stdout)
        except Exception:
            return reclaimed
        if not isinstance(beads, list) or not beads:
            return reclaimed

        # Sessions view (fetched unless injected). None → cannot assess → bail.
        if sessions is None:
            sessions = list_active_sessions()
        if sessions is None:
            return reclaimed
        if exclude_session_ids:
            drop = set(exclude_session_ids)
            sessions = [
                s for s in sessions
                if not ({s.get("id", ""), s.get("name", ""),
                         s.get("session_name", ""), s.get("alias", ""),
                         s.get("agent_name", "")} & drop)
            ]

        # Guard rails, computed once. A fail-SAFE None (query error) → bail:
        # without a trustworthy guard set we must NOT reclaim (the gate-guard
        # failsafe class — a probe failure must never weaken a guard).
        gate_active = list_gate_active_source_beads()
        if gate_active is None:
            return reclaimed
        live_sling = list_live_sling_source_beads(sessions, now)
        if live_sling is None:
            return reclaimed
        suspended = list_suspended_agents()        # fail-open: set() on error
        rate_limited = account_is_rate_limited()   # fail-open: False on error

        for b in beads:
            bead_id = b.get("id", "")
            if not bead_id:
                continue
            if (b.get("issue_type") or b.get("type") or "") == "epic":
                continue
            labels = b.get("labels", [])
            assignee = b.get("assignee") or ""
            # suspended-owner HOLD (mirrors run_cycle): never reclaim a parked crew.
            if assignee and assignee in suspended:
                continue

            bead_update_epoch = parse_iso_epoch(b.get("updated_at", ""))
            bead_update_age = (
                (now - bead_update_epoch) if bead_update_epoch is not None else None)

            # Liveness: pool-wide live worker OR live sling source (ga-qfo3).
            has_live_session = (
                pool_has_live_worker(assignee, sessions, now, bead_update_age)
                or bead_id in live_sling
            )
            # Branch rail, fast (no fetch — reads run_cycle's already-fetched refs).
            has_recent_branch = (
                False if has_live_session
                else get_branch_recent(bead_id, fetch=False))

            provably_dead = claimant_provably_dead(assignee, sessions)
            reclaim_count = parse_reclaim_count(labels)
            # ga-be4x: same explicit-refusal awareness as run_cycle — without
            # this, a dog bead already at its 2nd independent refusal would get
            # a 3rd fast RECLAIM here instead of the ESCALATE run_cycle owns,
            # since this preflight only acts on action=="reclaim" (see docstring:
            # "escalate / noop → left for run_cycle").
            has_explicit_refusal = _has_refusal_label(labels)
            refusal_count = parse_refusal_count(labels)

            action = reclaim_decision(
                has_live_session=has_live_session,
                has_recent_branch=has_recent_branch,
                # preflight has no strand clock — the provably_dead fast-path is
                # the ONLY path that can fire here (0 < any hysteresis window).
                seconds_stranded=0.0,
                reclaim_count=reclaim_count,
                has_needs_human=_has_needs_human_label(labels),
                has_dispatching_marker=(bead_id in gate_active),
                min_stranding_secs=POOL_ZOMBIE_TTL,
                account_rate_limited=rate_limited,
                provably_dead=provably_dead,
                has_explicit_refusal=has_explicit_refusal,
                refusal_count=refusal_count,
            )

            if action == "reclaim":
                if dry_run:
                    reclaimed.append(bead_id)
                    print(f"[DOG-PREFLIGHT] gt-fppb0: reclaimed provably-dead dog "
                          f"claim bead={bead_id} assignee={assignee!r} "
                          f"reclaim={reclaim_count + 1}/{MAX_RECLAIMS} (dry-run)", flush=True)
                else:
                    # ga-jzye0 GATE-FEEDBACK (gate_run=ga-dr98s): do_reclaim() can now
                    # return False without mutating anything (label removal unconfirmed
                    # — e.g. a Dolt hiccup). This caller used to discard that return
                    # value and report success unconditionally, same as run_cycle did
                    # before ga-vw26y. That meant a bead left completely untouched
                    # (assignee still gastown.dog, status still in_progress) got logged
                    # as "reclaimed" and counted in `reclaimed` anyway — so the fresh
                    # dog's own Tier-1 query re-adopted the SAME zombie next cycle: the
                    # exact NEVERSTART respawn loop this preflight exists to prevent,
                    # reintroduced under its own trigger condition. Mirror run_cycle's
                    # audited pattern (below, "ok = do_reclaim(...)"): only count/log a
                    # reclaim that actually happened.
                    # ga-xlnkf: this fast-reclaim path can ALSO hit reclaim_count >= 1
                    # (a bead can zombie multiple times across either reclaim path) and
                    # trigger do_reclaim's own pilot:held stamp — thread the same sling
                    # resolution run_cycle's Pass 1 does so that path's orphan-sling
                    # cleanup fires here too, not just from run_cycle.
                    _sling_bead_id = (b.get("metadata") or {}).get("pilot.sling_bead") or ""
                    ok = do_reclaim(bead_id, b.get("title", "")[:60], reclaim_count,
                                     0.0, labels, rig_root=b.get("rig_root"),
                                     has_explicit_refusal=has_explicit_refusal,
                                     refusal_count=refusal_count,
                                     sling_bead_id=_sling_bead_id)
                    if ok:
                        reclaimed.append(bead_id)
                        print(f"[DOG-PREFLIGHT] gt-fppb0: reclaimed provably-dead dog "
                              f"claim bead={bead_id} assignee={assignee!r} "
                              f"reclaim={reclaim_count + 1}/{MAX_RECLAIMS}", flush=True)
                    else:
                        print(f"[DOG-PREFLIGHT] gt-fppb0: reclaim attempt unconfirmed for "
                              f"bead={bead_id} assignee={assignee!r} — label removal could "
                              f"not be confirmed; leaving bead untouched, will retry next "
                              f"sweep", flush=True)
            # escalate / noop → left for run_cycle; the preflight only fast-reclaims.
    except Exception as exc:
        # Absolute fail-open contract: never propagate out of a pre_start hook.
        print(f"[DOG-PREFLIGHT] fail-open (no spawn block): {exc}", flush=True)
    return reclaimed


# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

def run_cycle(state, escalated_alerted):
    """Single poll cycle. Mutates state and escalated_alerted in place.
    Returns (inflight_count, stranded_count) for diagnostics.
    """
    now = time.time()

    # --- Query in-flight beads (fail-safe: skip cycle on error) ---
    beads = list_inflight_beads()
    if beads is None:
        print("[INFLIGHT-RECLAIM] bd list failed — skipping cycle", flush=True)
        return 0, 0

    # --- ga-vw26y: also sweep in_progress Pilot stories that lost story:in-flight
    #     (invisible to the label query above AND to the Pilot's open-only
    #     re-dispatch query). Fail-safe: None → skip cycle. ---
    inprogress = list_stranded_inprogress_beads()
    if inprogress is None:
        print("[INFLIGHT-RECLAIM] in_progress sweep failed — skipping cycle (safe)", flush=True)
        return len(beads), 0

    # Merge + dedup by id (a bead can match both queries).
    merged = {}
    for b in beads + inprogress:
        bid = b.get("id", "")
        if bid:
            merged[bid] = b
    beads = list(merged.values())

    # --- Query live sessions (fail-safe: skip cycle on error) ---
    sessions = list_active_sessions()
    if sessions is None:
        print("[INFLIGHT-RECLAIM] session list failed — skipping cycle", flush=True)
        return len(beads), 0

    # ga-seuh4/ga-a8t68: self-heal any bead order:orphan-sweep wrongfully
    # reset while its session was still alive. Independent of the rest of
    # this cycle's reclaim logic below (different candidate set: OPEN beads
    # with a stale gc.session_name breadcrumb, not in-flight beads) — runs
    # even if a later query in this cycle fails, since a stranded false-reset
    # left unhealed only gets harder to recover the longer it waits.
    try:
        heal_orphan_sweep_false_resets(sessions, now)
    except Exception as exc:
        print(f"[INFLIGHT-RECLAIM] warn: self-heal pass failed: {exc}", flush=True)

    # Deliberately-suspended crews: their in-flight beads HOLD (wait for resume), never
    # re-pool. Fail-open: empty set on probe error (current reclaim behavior preserved).
    suspended_agents = list_suspended_agents()

    # --- Query gate active markers (fail-safe: None → skip cycle entirely) ---
    gate_active_beads = list_gate_active_source_beads()
    if gate_active_beads is None:
        print("[INFLIGHT-RECLAIM] gate-marker query failed — skipping cycle (safe)", flush=True)
        return len(beads), 0

    # --- Query live sling-owner source beads (ga-qfo3, fail-safe: None → skip
    #     cycle entirely — same contract as the gate-marker query above) ---
    live_sling_owner_beads = list_live_sling_source_beads(sessions, now)
    if live_sling_owner_beads is None:
        print("[INFLIGHT-RECLAIM] sling-owner query failed — skipping cycle (safe)", flush=True)
        return len(beads), 0

    # --- Query refused sling-source beads (ga-9d80l). Fail-OPEN contract —
    #     unlike the two queries above, a lookup error here degrades to {}
    #     rather than skipping the cycle (see list_refused_sling_source_beads'
    #     docstring for why that's the safer choice for this signal). ---
    refused_sling_source_beads = list_refused_sling_source_beads()

    # ga-ufr7: one ground-truth quota check per cycle (not per-bead — it's an
    # account-wide, not per-builder, signal). Computed after the fail-safe
    # early-returns above so a cycle that's skipping anyway doesn't pay for it.
    account_rate_limited = account_is_rate_limited()
    if account_rate_limited:
        print("[INFLIGHT-RECLAIM] account-wide Claude rate-limit confirmed active "
              "(claude-quota-check.sh) — deferring all reclaims this cycle (ga-ufr7)",
              flush=True)

    stranded_count = 0
    active_bead_ids = set()
    # ga-dbibq: two-pass structure so pool-dead alert fires BEFORE per-bead actuation.
    classified = []    # (bead_id, title, labels, assignee, action, idle_min, reclaim_count, rig_root, bridge_sources, sling_bead_id)
    pool_zombies = {}  # pool -> [bead_id] for beads classified zombie this cycle

    # --- Pass 1: classify all beads (no actuation yet) ---
    for bead in beads:
        bead_id = bead.get("id", "")
        if not bead_id:
            continue
        # Never actuate on epics — they are containers, never dispatched builds.
        if (bead.get("issue_type") or bead.get("type") or "") == "epic":
            continue
        active_bead_ids.add(bead_id)

        labels = bead.get("labels", [])
        # ga-9d80l: bridge a refusal stamped on this bead's SLING wrapper onto
        # this bead's OWN view of its labels, when its own labels don't
        # already carry one. effective_labels is a pure superset of labels
        # (only ever adds synthetic pool:refused:<slug> entries), so every
        # existing label-membership check below and downstream (do_reclaim /
        # do_escalate / _promote_refusal_labels) stays correct unchanged —
        # see list_refused_sling_source_beads()'s docstring for the incident
        # this closes. bridge_sources (the full (slug, sling_id, rig_root,
        # raw_label) entries, empty when nothing was bridged) rides along in
        # the classified tuple so Pass 2 can pass it to do_reclaim/do_escalate,
        # which consume pool:refused[:reason] AT THE SLING once a bridged
        # reason is actually promoted onto this bead this cycle — never
        # here at discovery time, since bridging alone doesn't guarantee
        # this bead gets actuated this cycle (ga-9d80l GATE-FEEDBACK: an
        # un-actuated bead — e.g. gate:needs-human or a live dispatch marker
        # wins this cycle — must still see the same bridged reason next
        # cycle, not have it silently consumed and lost).
        bridge_sources = []
        if not _has_refusal_label(labels):
            bridge_sources = refused_sling_source_beads.get(bead_id, [])
            if bridge_sources:
                _bridged_slugs = []
                for _slug, _sling_id, _sling_rig_root, _raw_lbl in bridge_sources:
                    if _slug not in _bridged_slugs:
                        _bridged_slugs.append(_slug)
                labels = labels + [f"pool:refused:{_slug}" for _slug in _bridged_slugs]
        assignee = bead.get("assignee") or ""
        title = bead.get("title", "")[:60]
        rig_root = bead.get("rig_root")  # ga-mfeip: None=HQ-native, path=rig store
        # ga-xlnkf: resolve the sling wrapper `gc sling` minted for this
        # bead's dispatch (if any) so Pass 2 can close it should this cycle
        # reclaim+HOLD the target — see _close_orphaned_sling()'s docstring.
        sling_bead_id = (bead.get("metadata") or {}).get("pilot.sling_bead") or ""

        # --- Safety flags ---
        # ga-hkpwv: catch gate:needs-human:* prefix variants (e.g. :on-device, :routing)
        # in addition to the bare gate:needs-human — all are deliberately-parked beads.
        has_needs_human      = _has_needs_human_label(labels)
        has_dispatching_marker = bead_id in gate_active_beads
        # Owner deliberately SUSPENDED → the bead is parked, not stranded. Holds (waits
        # for the crew to resume) instead of re-pooling — the wa-wbub / digo-wa churn.
        has_suspended_owner  = bool(assignee) and assignee in suspended_agents
        # ga-64usm: the bead's own last-update age is the secondary progress
        # signal that rescues a stale-activity session whose builder is still
        # touching the bead (workers should bd-update during long work).
        bead_update_epoch = parse_iso_epoch(bead.get("updated_at", ""))
        bead_update_age = (now - bead_update_epoch) if bead_update_epoch is not None else None
        # ga-hkpwv: ephemeral pool assignees come in two forms:
        #   - Bare template (e.g. 'wa-worker'): no concrete session matches this name.
        #     Use pool_has_live_worker() — pool-wide: ANY live wa-worker session
        #     blocks ALL bare-template reclaims (conservative/coarse-grained).
        #   - Concrete adhoc (e.g. 'wa-worker-adhoc-faac43db2d'): a specific session
        #     was named at dispatch time. Use concrete_adhoc_session_is_live() for a
        #     per-session check — more precise; only THAT session's liveness matters.
        is_bare_pool_zombie = assignee in EPHEMERAL_POOL_ASSIGNEES
        is_adhoc_pool_zombie = (
            not is_bare_pool_zombie
            and _is_ephemeral_pool_assignee(assignee)
        )
        is_pool_zombie_bead = is_bare_pool_zombie or is_adhoc_pool_zombie
        if is_bare_pool_zombie:
            has_live_session = pool_has_live_worker(assignee, sessions, now, bead_update_age)
        elif is_adhoc_pool_zombie:
            has_live_session = concrete_adhoc_session_is_live(
                assignee, sessions, now, bead_update_age)
        else:
            has_live_session = session_is_live(assignee, sessions, now, bead_update_age)

        # ga-qfo3: this bead's OWN assignee may be empty because Pilot assigned
        # the live builder session to its SLING wrapper bead instead (see
        # list_live_sling_source_beads' docstring). Treat it as owned when the
        # sling bead's session is live — closes the false-reclaim gap that let
        # ga-z6uo get reclaimed out from under a fully live, actively-building
        # dog session.
        if not has_live_session and bead_id in live_sling_owner_beads:
            has_live_session = True

        # ga-be4x: explicit refusal is a label read — pure, cheap, and, unlike
        # provably_dead, not scoped to bare-pool-zombie assignees. A worker's
        # STATED conclusion is unambiguous regardless of what kind of assignee
        # held the bead, so any assignee shape (bare pool, concrete adhoc, or a
        # named crew) can carry and benefit from this signal. Computed here
        # (ahead of has_recent_branch, moved up from its old spot further down)
        # because should_fetch_branch_for_reclaim() below needs it.
        has_explicit_refusal = _has_refusal_label(labels)
        refusal_count = parse_refusal_count(labels)

        # Branch check is potentially slow (git fetch); only run when needed.
        # ga-vu718 gate-fix-2: see should_fetch_branch_for_reclaim()'s
        # docstring for why has_live_session=True alone is no longer
        # sufficient to skip this safely.
        has_recent_branch = False
        if should_fetch_branch_for_reclaim(
                has_live_session=has_live_session,
                has_needs_human=has_needs_human,
                has_dispatching_marker=has_dispatching_marker,
                has_suspended_owner=has_suspended_owner,
                has_explicit_refusal=has_explicit_refusal,
                refusal_count=refusal_count):
            has_recent_branch = get_branch_recent(bead_id)

        # --- Update stranded timestamp in state ---
        bead_state = state.setdefault(bead_id, {})
        is_currently_stranded = (
            not has_live_session and
            not has_recent_branch and
            not has_needs_human and
            not has_dispatching_marker and
            not has_suspended_owner
        )
        if has_suspended_owner:
            if not bead_state.get("suspended_hold_logged"):
                print(f"[INFLIGHT-RECLAIM] HOLD (suspended owner): bead={bead_id} "
                      f"assignee={assignee!r} — not re-pooling; waits for crew resume "
                      f"or human reassign", flush=True)
                bead_state["suspended_hold_logged"] = True
        else:
            bead_state.pop("suspended_hold_logged", None)

        seconds_stranded, _strand_event = update_strand_clock(
            bead_state, is_currently_stranded, assignee, now)
        if _strand_event == "started":
            print(f"[INFLIGHT-RECLAIM] started stranded clock: bead={bead_id} "
                  f"assignee={assignee!r}", flush=True)
        elif _strand_event == "fresh_claim_reset":
            print(f"[INFLIGHT-RECLAIM] reset stranded clock (fresh claim, wa-og36j): "
                  f"bead={bead_id} assignee={assignee!r} — new claim gets a full "
                  f"RECLAIM_TTL window (not born-stale)", flush=True)
        elif _strand_event == "progress_reset":
            print(f"[INFLIGHT-RECLAIM] reset stranded clock: bead={bead_id} "
                  f"live_session={has_live_session} recent_branch={has_recent_branch}",
                  flush=True)
        if is_currently_stranded:
            stranded_count += 1

        reclaim_count = parse_reclaim_count(labels)

        # has_explicit_refusal / refusal_count: computed earlier now (see the
        # has_recent_branch block above) — ga-vu718 gate-fix-2 needs them
        # ahead of that computation, not here.

        # ga-hkpwv: pool-zombie beads (bare template AND concrete adhoc forms) use
        # POOL_ZOMBIE_TTL (2h) instead of the standard RECLAIM_TTL (25min) — a longer
        # window compensates for the weaker signal (no Pilot marker) and prevents
        # false reclaims on slow-starting builds.
        min_stranding_secs = POOL_ZOMBIE_TTL if is_pool_zombie_bead else RECLAIM_TTL

        # gt-fppb0: grant the provably-dead fast-path (reclaim at TTL~0) ONLY to
        # BARE pool-template zombies (assignee ∈ EPHEMERAL_POOL_ASSIGNEES, e.g.
        # 'gastown.dog' / 'wa-worker'). Their assignee is a STABLE pool name that
        # does not change on re-dispatch, so "claimant absent from gc session
        # list" can never be the wa-og36j born-stale race (a fresh CONCRETE claim
        # whose new session isn't visible yet) — that race only afflicts concrete
        # per-dispatch assignees, which are excluded here and keep the full
        # POOL_ZOMBIE_TTL wait. A deliberately-SUSPENDED owner is also excluded:
        # its bead HOLDS for resume and must never be reclaimed even when its
        # session is (expectedly) gone. All other reclaim guards live inside
        # reclaim_decision and still veto the fast-path before it can fire.
        provably_dead = (
            is_bare_pool_zombie
            and not has_suspended_owner
            and claimant_provably_dead(assignee, sessions)
        )

        # --- Pure decision ---
        action = reclaim_decision(
            has_live_session=has_live_session,
            has_recent_branch=has_recent_branch,
            seconds_stranded=seconds_stranded,
            reclaim_count=reclaim_count,
            has_needs_human=has_needs_human,
            has_dispatching_marker=has_dispatching_marker,
            min_stranding_secs=min_stranding_secs,
            account_rate_limited=account_rate_limited,
            provably_dead=provably_dead,
            has_explicit_refusal=has_explicit_refusal,
            refusal_count=refusal_count,
            has_suspended_owner=has_suspended_owner,
        )

        idle_min = seconds_stranded / 60.0

        # Bucket zombie beads by pool for pool-dead detection (ga-dbibq).
        # "Zombie" = would-reclaim or would-escalate: no live session, no recent
        # branch, stranded past TTL. Per-bead actuation follows in Pass 2.
        # ga-hkpwv: pool-zombie beads feed into this bucket automatically since
        # _pool_of("wa-worker") == "wa-worker".
        if action in ("reclaim", "escalate"):
            pool = _pool_of(assignee)
            if pool:
                pool_zombies.setdefault(pool, []).append(bead_id)

        # Include assignee + rig_root in classified tuple for Pass 2 (ga-hkpwv, ga-mfeip).
        # bridge_sources (ga-9d80l gate-fix-2) lets Pass 2 consume a bridged
        # refusal at its sling source when it actually promotes it. sling_bead_id
        # (ga-xlnkf) lets Pass 2 close this bead's OWN dispatch sling if this
        # cycle reclaims+holds it — a different sling than bridge_sources', which
        # is about a refusal LABEL bridged FROM a sling, not the sling's identity.
        classified.append((bead_id, title, labels, assignee, action, idle_min, reclaim_count,
                            rig_root, bridge_sources, sling_bead_id))

    # --- Pool-dead alert (BEFORE per-bead actuation, ga-dbibq) ---
    # Emits [POOL-DEAD] Mayor mail when >= POOL_DEAD_MIN beads from the same pool
    # are zombie for 2 consecutive cycles. Fail-open; never crashes the cycle.
    _check_pool_dead(pool_zombies, now)

    # --- Pass 2: per-bead actuation (logic unchanged from prior single-pass) ---
    for (bead_id, title, labels, assignee, action, idle_min, reclaim_count,
         rig_root, bridge_sources, sling_bead_id) in classified:
        # ga-be4x: re-derive from labels (already in the tuple — no new fields
        # needed) so actuation makes the SAME refusal-vs-death distinction
        # Pass 1 used to classify the action in the first place.
        has_explicit_refusal = _has_refusal_label(labels)
        refusal_count = parse_refusal_count(labels)

        if action == "reclaim":
            ok = do_reclaim(bead_id, title, reclaim_count, idle_min, labels, rig_root=rig_root,
                             has_explicit_refusal=has_explicit_refusal, refusal_count=refusal_count,
                             bridge_sources=bridge_sources, sling_bead_id=sling_bead_id)
            status = "RECLAIMED" if ok else "RECLAIM-FAILED"
            _refusal_tag = (f" refusal={refusal_count + 1}/{REFUSAL_ESCALATE_THRESHOLD}"
                             if has_explicit_refusal else "")
            emit(
                f"[INFLIGHT-RECLAIM] [{status}] bead={bead_id} "
                f"idle={idle_min:.0f}min no_live_session no_recent_branch "
                f"reclaim={reclaim_count + 1}/{MAX_RECLAIMS}{_refusal_tag} title={title!r}"
            )
            # Reset state clock — bead left in-flight (or will be re-tracked if partially failed)
            state.pop(bead_id, None)

        elif action == "escalate":
            # Rate-limit to avoid repeat ntfy on the same bead within REALERT_SEC
            last_alert = escalated_alerted.get(bead_id, 0)
            if now - last_alert > REALERT_SEC:
                _escalated_reason_slugs = do_escalate(
                    bead_id, title, reclaim_count, idle_min, labels, rig_root=rig_root,
                    has_explicit_refusal=has_explicit_refusal, refusal_count=refusal_count,
                    bridge_sources=bridge_sources)
                _escalate_reason = (
                    f"{refusal_count + 1} independent EXPLICIT REFUSALS"
                    if has_explicit_refusal else f"reclaimed {reclaim_count}x")
                emit(
                    f"[INFLIGHT-RECLAIM] [ESCALATED] bead={bead_id} "
                    f"{_escalate_reason} idle={idle_min:.0f}min — "
                    f"needs human/Mayor intervention title={title!r}"
                )
                _irg_ledger("human-touch", {"ts": _irg_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "inflight-reclaim-guard", "stage": "executa", "kind": "technical", "bead_id": bead_id, "reason": f"{_escalate_reason} — needs human intervention"}, fail_open=True)
                # ga-hkpwv: pool-zombie escalation also mails Mayor directly
                # (POOL-DEAD handles pool-level alerts; this covers single-bead cap exhaustion)
                if _is_ephemeral_pool_assignee(assignee):
                    try:
                        if has_explicit_refusal:
                            # ga-be4x gate-fix-2: reuse do_escalate's own
                            # returned (complete, post-promotion) reason list
                            # instead of re-deriving from the stale `labels`
                            # local here — at this point `labels` still shows
                            # this cycle's triggering reason as an un-promoted
                            # pool:refused:<reason> label, so an independent
                            # re-derivation from it would silently drop the
                            # exact same reason do_escalate() itself used to.
                            _reasons = _escalated_reason_slugs or []
                            subprocess.run(
                                ["gc", "mail", "send", "mayor",
                                 "-s", f"[POOL-REFUSED-ESCALATED] {assignee}: bead {bead_id} refused {refusal_count + 1}x",
                                 "-m", (f"Bead {bead_id!r} ({title!r}) was EXPLICITLY REFUSED by "
                                        f"{refusal_count + 1} independent {assignee!r} workers — "
                                        f"reason(s): {', '.join(_reasons) or 'unspecified'}. Not an "
                                        f"unexplained death: re-dispatching again cannot succeed where "
                                        f"{refusal_count + 1} workers already agreed it isn't buildable "
                                        f"as specified. Marked gate:needs-human:refused. Needs human "
                                        f"re-route/re-scope, then re-queue.")],
                                timeout=20, capture_output=True)
                        else:
                            subprocess.run(
                                ["gc", "mail", "send", "mayor",
                                 "-s", f"[POOL-ZOMBIE-ESCALATED] {assignee}: bead {bead_id} reclaimed {reclaim_count}x",
                                 "-m", (f"Pool-zombie bead {bead_id!r} ({title!r}) exhausted reclaim cap "
                                        f"({reclaim_count}/{MAX_RECLAIMS}) with assignee={assignee!r}, "
                                        f"no branch, no active pool session. Marked gate:needs-human. "
                                        f"Needs human investigation + re-queue.")],
                                timeout=20, capture_output=True)
                    except Exception as _exc:
                        print(f"[INFLIGHT-RECLAIM] warn: pool-zombie escalation mail ({bead_id}): {_exc}",
                              flush=True)
                escalated_alerted[bead_id] = now
            # Bead now carries gate:needs-human → next cycle's has_needs_human
            # rail returns "noop". It stays in the in-flight query but parks
            # quietly (no further actuation). Drop its stranded-clock state.
            state.pop(bead_id, None)

        # action == "noop" → silence

    # Prune state entries for beads no longer in the in-flight+dispatched query
    gone = set(state.keys()) - active_bead_ids
    for bid in gone:
        state.pop(bid, None)
        escalated_alerted.pop(bid, None)

    return len(beads), stranded_count


# ---------------------------------------------------------------------------
# Hermetic selftest (ga-dbibq) — python3 inflight-reclaim-guard.py --selftest
# Tests _pool_of() and _check_pool_dead() cycle behavior.
# Does NOT call bd, gc, git, or notify live.
# ---------------------------------------------------------------------------

def _selftest():
    """Run hermetic POOL-DEAD selftest. Returns True if all checks pass."""
    import tempfile as _tempfile
    import shutil as _shutil

    PASS = 0
    FAIL = 0

    def check(name, cond, detail=""):
        nonlocal PASS, FAIL
        if cond:
            print(f"PASS: {name}")
            PASS += 1
        else:
            print(f"FAIL: {name}" + (f" — {detail}" if detail else ""))
            FAIL += 1

    # -----------------------------------------------------------------------
    # Section 1: _pool_of() pure function
    # -----------------------------------------------------------------------
    check("_pool_of: wa-worker exact",         _pool_of("wa-worker")             == "wa-worker")
    check("_pool_of: wa-worker-adhoc",         _pool_of("wa-worker-adhoc-x")     == "wa-worker")
    check("_pool_of: wa-worker-adhoc-long",    _pool_of("wa-worker-adhoc-123abc")== "wa-worker")
    check("_pool_of: gastown.dog exact",       _pool_of("gastown.dog")           == "gastown.dog")
    check("_pool_of: dog- prefix",             _pool_of("dog-gawispy8c0mr")      == "gastown.dog")
    check("_pool_of: dog-short",               _pool_of("dog-3")                 == "gastown.dog")
    check("_pool_of: crew name passthrough",   _pool_of("oracle-wa")             == "oracle-wa")
    check("_pool_of: mila-wa passthrough",     _pool_of("mila-wa")               == "mila-wa")
    check("_pool_of: batista-ps passthrough",  _pool_of("batista-ps")            == "batista-ps")
    check("_pool_of: empty string",            _pool_of("") == "")

    # -----------------------------------------------------------------------
    # Section 2: _check_pool_dead() cycle behavior with temp state dir
    # -----------------------------------------------------------------------
    _tmpdir = _tempfile.mkdtemp(prefix="irg-selftest-")
    try:
        global STATE_FILE
        _orig_state = STATE_FILE
        STATE_FILE = os.path.join(_tmpdir, "state.json")

        _mail_log = []
        _orig_run = subprocess.run

        def _stub_run(cmd, **kw):
            """Capture gc mail calls; silently swallow everything else (notify, etc.)."""
            if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "gc" and cmd[1] == "mail":
                assert len(cmd) >= 3 and cmd[2] == "send", f"gc mail missing 'send' subcommand: {cmd}"
                _mail_log.append(list(cmd))
            class _R:
                returncode = 0
            return _R()

        subprocess.run = _stub_run
        try:
            T = 1_782_400_000.0  # fixed epoch for determinism

            # --- Scenario POOL-DEAD-1: 1 cycle with 3 wa-worker zombies → NO alert ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T)
            check("POOL-DEAD-1: 1 cycle → no alert (2-cycle hysteresis required)",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-2: 2nd cycle → [POOL-DEAD] alert fires ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 10)
            check("POOL-DEAD-2: 2 cycles → [POOL-DEAD] mail emitted",
                  len(_mail_log) == 1,
                  f"mail_log={_mail_log}")
            check("POOL-DEAD-2: mail subject contains [POOL-DEAD]",
                  len(_mail_log) == 1 and "[POOL-DEAD]" in " ".join(_mail_log[0]),
                  f"mail_log={_mail_log}")
            check("POOL-DEAD-2: mail subject names wa-worker",
                  len(_mail_log) == 1 and "wa-worker" in " ".join(_mail_log[0]),
                  f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-3: 3rd cycle within cooldown → NO repeat alert ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 20)
            check("POOL-DEAD-3: within cooldown → no repeat alert",
                  len(_mail_log) == 1, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-4: after cooldown expires → alert fires again ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]},
                             T + POOL_DEAD_COOLDOWN + 30)
            check("POOL-DEAD-4: after cooldown → second alert fires",
                  len(_mail_log) == 2, f"mail_log={_mail_log}")

            # Reset state for remaining scenarios
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()

            # --- Scenario POOL-DEAD-5: <POOL_DEAD_MIN zombies → no alert even after 2 cycles ---
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T)        # 2 < POOL_DEAD_MIN=3
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T + 10)
            check("POOL-DEAD-5: below threshold (<3 zombies) → no alert",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-6: pool recovers between cycles → counter resets ---
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T)        # cycle 1: zombie
            _check_pool_dead({}, T + 10)                                             # cycle 2: recovered (0 zombies)
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 20)  # cycle 3: zombie again
            check("POOL-DEAD-6: recovery resets counter → no premature alert",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-7: gastown.dog pool also triggers correctly ---
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()
            _check_pool_dead({"gastown.dog": ["d1", "d2", "d3", "d4"]}, T)
            _check_pool_dead({"gastown.dog": ["d1", "d2", "d3", "d4"]}, T + 10)
            check("POOL-DEAD-7: gastown.dog pool fires after 2 cycles",
                  len(_mail_log) == 1 and "gastown.dog" in " ".join(_mail_log[0]),
                  f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-8: live session bead excluded (not in zombie list) ---
            # Simulate: pool has 2 real zombies + 1 live-session bead (not passed in)
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T)        # 2 zombies (live bead excluded)
            _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2"]}, T + 10)
            check("POOL-DEAD-8: live-session bead excluded → stays below threshold",
                  len(_mail_log) == 0, f"mail_log={_mail_log}")

            # --- Scenario POOL-DEAD-9: mail non-zero exit → failure log is emitted ---
            import io as _io
            _shutil.rmtree(STATE_FILE + ".pool-dead", ignore_errors=True)
            _mail_log.clear()

            def _stub_run_fail(cmd, **kw):
                """Like _stub_run but gc mail returns rc=1 (simulate Dolt down / args rejected)."""
                if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "gc" and cmd[1] == "mail":
                    assert len(cmd) >= 3 and cmd[2] == "send", f"gc mail missing 'send' subcommand: {cmd}"
                    _mail_log.append(list(cmd))
                    class _RF:
                        returncode = 1
                        stderr = b"dolt: connection refused"
                    return _RF()
                class _R:
                    returncode = 0
                return _R()

            subprocess.run = _stub_run_fail
            _cap = _io.StringIO()
            _orig_stdout = _sys.stdout
            _sys.stdout = _cap
            try:
                _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T)         # cycle 1
                _check_pool_dead({"wa-worker": ["wa-b1", "wa-b2", "wa-b3"]}, T + 10)    # cycle 2 → fires
            finally:
                _sys.stdout = _orig_stdout
                subprocess.run = _stub_run  # restore main test stub

            _out = _cap.getvalue()
            check("POOL-DEAD-9: mail non-zero exit → failure log emitted",
                  "[POOL-DEAD] mail non-zero exit" in _out,
                  f"captured={_out!r}")
            check("POOL-DEAD-9: failure log names the pool",
                  "wa-worker" in _out and "rc=1" in _out,
                  f"captured={_out!r}")

        finally:
            subprocess.run = _orig_run
            STATE_FILE = _orig_state
    finally:
        _shutil.rmtree(_tmpdir, ignore_errors=True)

    # -----------------------------------------------------------------------
    # Section 3: ga-hkpwv pool-zombie reclaim scenarios (pure-function tests)
    # Tests is_reclaimable_inprogress_story(), pool_has_live_worker(),
    # reclaim_decision(), and _has_needs_human_label(). No bd/gc/git calls.
    # -----------------------------------------------------------------------

    T_pz = 1_782_500_000.0  # fixed epoch for determinism

    # --- PZ-1: bare pool-template assignee qualifies WITHOUT Pilot markers ---
    check("PZ-1a: bare wa-worker assignee qualifies without Pilot markers",
          is_reclaimable_inprogress_story([], assignee="wa-worker"))
    check("PZ-1b: non-pool assignee without markers → False (scope unchanged)",
          not is_reclaimable_inprogress_story([], assignee="oracle-wa"))
    check("PZ-1c: no assignee, no markers → False",
          not is_reclaimable_inprogress_story([], assignee=None))

    # --- PZ-2: gate:needs-human / prefix variants block pool-zombie reclaim ---
    check("PZ-2a: wa-worker + gate:needs-human (exact) → False (parked)",
          not is_reclaimable_inprogress_story(["gate:needs-human"], assignee="wa-worker"))
    check("PZ-2b: wa-worker + gate:needs-human:on-device → False (prefix variant)",
          not is_reclaimable_inprogress_story(["gate:needs-human:on-device"], assignee="wa-worker"))
    check("PZ-2c: wa-worker + gate:needs-human:routing → False (prefix variant)",
          not is_reclaimable_inprogress_story(["gate:needs-human:routing"], assignee="wa-worker"))
    check("PZ-2d: _has_needs_human_label exact match",
          _has_needs_human_label(["gate:needs-human"]))
    check("PZ-2e: _has_needs_human_label prefix variant",
          _has_needs_human_label(["gate:needs-human:technical"]))
    check("PZ-2f: _has_needs_human_label absent → False",
          not _has_needs_human_label(["story:in-flight", "pilot:dispatched"]))

    # --- PZ-3: pool_has_live_worker — asleep/drained sessions → pool dead ---
    _asleep_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-aaa",
         "agent_name": "wa-worker-adhoc-aaa", "state": "asleep",
         "id": "sid-s1", "name": "wa-worker-adhoc-1", "alias": "",
         "last_active": "0001-01-01T00:00:00Z"},
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-bbb",
         "agent_name": "wa-worker-adhoc-bbb", "state": "drained",
         "id": "sid-s2", "name": "wa-worker-adhoc-2", "alias": "",
         "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("PZ-3a: pool_has_live_worker: all asleep → False (reclaim eligible)",
          not pool_has_live_worker("wa-worker", _asleep_sessions, T_pz))
    check("PZ-3b: pool_has_live_worker: drained included → False",
          not pool_has_live_worker("wa-worker",
              [_asleep_sessions[1]], T_pz))

    # --- PZ-4: pool_has_live_worker — active session with recent last_active → True ---
    _active_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_pz - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _active_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-ccc",
         "agent_name": "wa-worker-adhoc-ccc", "state": "active",
         "id": "sid-a1", "name": "wa-worker-adhoc-3", "alias": "",
         "last_active": _active_fresh_ts},
    ]
    check("PZ-4: pool_has_live_worker: active + fresh last_active → True (NOT reclaimed)",
          pool_has_live_worker("wa-worker", _active_sessions, T_pz))

    # --- PZ-5: pool_has_live_worker — unparseable last_active → conservative → True ---
    _active_bad_ts_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-ddd",
         "agent_name": "wa-worker-adhoc-ddd", "state": "active",
         "id": "sid-b1", "name": "wa-worker-adhoc-4", "alias": "",
         "last_active": "not-a-timestamp"},
    ]
    check("PZ-5: pool_has_live_worker: active + unparseable last_active → True (conservative)",
          pool_has_live_worker("wa-worker", _active_bad_ts_sessions, T_pz))

    # --- PZ-5b: pool_has_live_worker — unknown session state → conservative → True ---
    _unknown_state_sessions = [
        {"template": "wa-worker", "session_name": "wa-worker-adhoc-eee",
         "agent_name": "wa-worker-adhoc-eee", "state": "unknown_state",
         "id": "sid-c1", "name": "wa-worker-adhoc-5", "alias": "",
         "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("PZ-5b: pool_has_live_worker: unknown state → True (conservative, NOT reclaimed)",
          pool_has_live_worker("wa-worker", _unknown_state_sessions, T_pz))

    # --- PZ-6: reclaim_decision with POOL_ZOMBIE_TTL, stranded 2h+ → reclaim ---
    check("PZ-6a: reclaim_decision: pool zombie, stranded>POOL_ZOMBIE_TTL → reclaim",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")
    check("PZ-6b: reclaim_decision: pool zombie, stranded<POOL_ZOMBIE_TTL → noop (still waiting)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL - 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- PZ-7: has_recent_branch → noop (safety rail, even for pool zombies) ---
    check("PZ-7: reclaim_decision: branch exists → noop (branch safety rail holds)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=True,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- PZ-8: has_live_session → noop (live pool worker blocks reclaim) ---
    check("PZ-8: reclaim_decision: live session → noop (live pool worker safety rail)",
          reclaim_decision(
              has_live_session=True, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- PZ-9: 3 thrashes → escalate (no 4th reclaim) ---
    check("PZ-9: reclaim_decision: reclaim_count=MAX_RECLAIMS(3) → escalate",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=MAX_RECLAIMS,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "escalate")
    check("PZ-9b: reclaim_decision: reclaim_count=2 (< MAX_RECLAIMS) → reclaim not yet escalate",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1, reclaim_count=MAX_RECLAIMS - 1,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")

    # --- PZ-10: non-wa-worker pool not affected ---
    check("PZ-10: pool_has_live_worker: no matching template → False (empty pool)",
          not pool_has_live_worker("wa-worker",
              [{"template": "oracle-wa", "state": "active", "id": "x",
                "name": "x", "session_name": "x", "alias": "", "agent_name": "x",
                "last_active": _active_fresh_ts}],
              T_pz))

    # -----------------------------------------------------------------------
    # Section 4: get_branch_recent — segment-based matching (BR-*)
    # Verifies that crew/<pool>/<id> branches are correctly matched, that
    # prefix-collisions are rejected, and that git errors fail safe.
    # Uses monkeypatched subprocess.run — no real git calls.
    # -----------------------------------------------------------------------
    T_br = 1_782_500_000.0  # fixed epoch for determinism

    _orig_run_br = subprocess.run
    _orig_time_fn = time.time

    def _make_git_stub(refs_lines, fetch_ok=True):
        """Return a subprocess.run stub serving fake git ref output."""
        def _stub(cmd, **kw):
            class _R:
                returncode = 0
                stdout = ""
                stderr = b""
            if not isinstance(cmd, (list, tuple)):
                return _R()
            if "fetch" in cmd:
                if not fetch_ok:
                    raise OSError("simulated fetch failure")
                return _R()
            if "for-each-ref" in cmd:
                r = _R()
                r.stdout = ("\n".join(refs_lines) + "\n") if refs_lines else ""
                return r
            return _R()
        return _stub

    try:
        time.time = lambda: T_br  # freeze "now" so age comparisons are deterministic

        # BR-1: crew/wa-worker/<id> with recent commit → True (branch rail blocks reclaim).
        # This is the previously-broken false-reclaim scenario (ga-hkpwv):
        # before the fix, only fix/* / feature/* prefixes were checked, so this
        # branch was invisible and the bead would have been reclaimed (RED → GREEN).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-quoy {int(T_br - 60)}"
        ])
        check("BR-1: crew/wa-worker/<id> recent branch → True (branch rail blocks reclaim; was RED before fix)",
              get_branch_recent("wa-quoy"))

        # BR-2: prefix-collision — bead wa-oly, branch crew/wa-worker/wa-oly1 → False.
        # wa-oly1 must NOT match wa-oly (no separator after the bead-id).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-oly1 {int(T_br - 60)}"
        ])
        check("BR-2: prefix-collision wa-oly vs wa-oly1 → False (no false match, still reclaimable)",
              not get_branch_recent("wa-oly"))

        # BR-3: feat/<id> branch → True (new prefix, previously unchecked).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/feat/wa-quoy {int(T_br - 60)}"
        ])
        check("BR-3: feat/<id> recent branch → True",
              get_branch_recent("wa-quoy"))

        # BR-4: fix/<id> branch → True (legacy pattern; preserved).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/fix/wa-quoy {int(T_br - 60)}"
        ])
        check("BR-4: fix/<id> recent branch → True (legacy pattern preserved)",
              get_branch_recent("wa-quoy"))

        # BR-5: for-each-ref returns non-zero → True (fail-safe: do NOT reclaim).
        def _fail_on_for_each_ref(cmd, **kw):
            class _Err:
                returncode = 1
                stdout = ""
                stderr = b"error"
            class _OK:
                returncode = 0
                stdout = ""
                stderr = b""
            if isinstance(cmd, (list, tuple)) and "for-each-ref" in cmd:
                return _Err()
            return _OK()
        subprocess.run = _fail_on_for_each_ref
        check("BR-5: for-each-ref non-zero exit → True (fail-safe: do NOT reclaim)",
              get_branch_recent("wa-quoy"))

        # BR-6: fetch raises exception → True (fail-safe: do NOT reclaim).
        subprocess.run = _make_git_stub([], fetch_ok=False)
        check("BR-6: fetch exception → True (fail-safe: do NOT reclaim)",
              get_branch_recent("wa-quoy"))

        # BR-7: branch exists but commit is stale (> RECLAIM_TTL ago) → False.
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-quoy {int(T_br - RECLAIM_TTL - 100)}"
        ])
        check("BR-7: stale branch (>RECLAIM_TTL old) → False (reclaim allowed)",
              not get_branch_recent("wa-quoy"))

        # BR-8: no branch matching bead-id at all → False (reclaim allowed).
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/other-bead {int(T_br - 60)}"
        ])
        check("BR-8: no matching branch → False (reclaim allowed)",
              not get_branch_recent("wa-quoy"))

        # BR-9 (ga-nxgxz): window_seconds overrides RECLAIM_TTL for callers with a
        # different staleness definition (e.g. throughput-stall-watchdog.py's
        # multi-hour delivery-stall window). A commit older than RECLAIM_TTL but
        # newer than a caller-supplied larger window must read as recent under
        # that larger window, and default (window_seconds omitted) must be
        # unaffected — same fixture as BR-7, both assertions against it.
        subprocess.run = _make_git_stub([
            f"refs/remotes/origin/crew/wa-worker/wa-quoy {int(T_br - RECLAIM_TTL - 100)}"
        ])
        check("BR-9a: commit stale for default RECLAIM_TTL but within a custom "
              "3h window_seconds → True",
              get_branch_recent("wa-quoy", window_seconds=3 * 3600))
        check("BR-9b: same fixture, window_seconds omitted → still False "
              "(default RECLAIM_TTL unaffected by the new parameter)",
              not get_branch_recent("wa-quoy"))

    finally:
        time.time = _orig_time_fn
        subprocess.run = _orig_run_br

    # -----------------------------------------------------------------------
    # Section 5: ga-hkpwv gap fix — concrete wa-worker-adhoc-<hex> scenarios
    # Tests _is_ephemeral_pool_assignee(), concrete_adhoc_session_is_live(),
    # is_reclaimable_inprogress_story() for concrete adhoc, and the full
    # reclaim pipeline for concrete adhoc assignees. No bd/gc/git calls.
    # -----------------------------------------------------------------------

    T_az = 1_782_600_000.0  # fixed epoch for determinism

    # --- AZ-0: _is_ephemeral_pool_assignee() — covers bare template + concrete adhoc ---
    check("AZ-0a: _is_ephemeral_pool_assignee: bare wa-worker → True",
          _is_ephemeral_pool_assignee("wa-worker"))
    check("AZ-0b: _is_ephemeral_pool_assignee: wa-worker-adhoc-deadbeef → True",
          _is_ephemeral_pool_assignee("wa-worker-adhoc-deadbeef"))
    check("AZ-0c: _is_ephemeral_pool_assignee: gastown.dog → True (gt-fppb0: bare dog pool alias now in scope)",
          _is_ephemeral_pool_assignee("gastown.dog"))
    check("AZ-0d: _is_ephemeral_pool_assignee: oracle-wa (crew) → False",
          not _is_ephemeral_pool_assignee("oracle-wa"))

    # --- AZ-1: concrete adhoc qualifies in is_reclaimable_inprogress_story without Pilot markers ---
    check("AZ-1a: is_reclaimable_inprogress_story: wa-worker-adhoc-deadbeef without markers → True",
          is_reclaimable_inprogress_story([], assignee="wa-worker-adhoc-deadbeef"))
    check("AZ-1b: _pool_of: wa-worker-adhoc-deadbeef → wa-worker (feeds POOL-DEAD bucket)",
          _pool_of("wa-worker-adhoc-deadbeef") == "wa-worker")

    # --- AZ-2: concrete_adhoc_session_is_live — asleep session → False (eligible for reclaim) ---
    _adhoc_dead_session = [
        {"id": "sid-x1", "name": "wa-worker-adhoc-1",
         "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "asleep", "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("AZ-2: concrete_adhoc_session_is_live: session asleep → False (eligible for reclaim)",
          not concrete_adhoc_session_is_live(
              "wa-worker-adhoc-deadbeef", _adhoc_dead_session, T_az))

    # --- AZ-3: full pipeline — concrete adhoc + dead session + stranded 2h+ → reclaim ---
    check("AZ-3: reclaim_decision: adhoc+dead session, no branch, stranded>POOL_ZOMBIE_TTL → reclaim",
          reclaim_decision(
              has_live_session=concrete_adhoc_session_is_live(
                  "wa-worker-adhoc-deadbeef", _adhoc_dead_session, T_az),
              has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1,
              reclaim_count=0,
              has_needs_human=False,
              has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")

    # --- AZ-4: concrete_adhoc_session_is_live — ACTIVE + fresh last_active → True (no false reclaim) ---
    _adhoc_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_az - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _adhoc_live_session = [
        {"id": "sid-x2", "name": "wa-worker-adhoc-2",
         "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "active", "last_active": _adhoc_fresh_ts},
    ]
    check("AZ-4: concrete_adhoc_session_is_live: active + fresh last_active → True (NOOP; no false reclaim)",
          concrete_adhoc_session_is_live(
              "wa-worker-adhoc-deadbeef", _adhoc_live_session, T_az))

    # --- AZ-5: branch rail — concrete adhoc + branch exists → NOOP ---
    check("AZ-5: reclaim_decision: adhoc dead session BUT branch exists → noop (branch rail)",
          reclaim_decision(
              has_live_session=False,
              has_recent_branch=True,
              seconds_stranded=POOL_ZOMBIE_TTL + 1,
              reclaim_count=0,
              has_needs_human=False,
              has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- AZ-6: conservatism — unknown state → ALIVE → NOOP ---
    _adhoc_unknown_state_session = [
        {"id": "sid-x3", "name": "wa-worker-adhoc-3",
         "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "unknown_state", "last_active": "0001-01-01T00:00:00Z"},
    ]
    check("AZ-6: concrete_adhoc_session_is_live: unknown state → True (conservative; NOOP)",
          concrete_adhoc_session_is_live(
              "wa-worker-adhoc-deadbeef", _adhoc_unknown_state_session, T_az))

    # --- AZ-7: session gone (not in session list at all) → dead → eligible for reclaim ---
    check("AZ-7: concrete_adhoc_session_is_live: session gone (empty list) → False (eligible)",
          not concrete_adhoc_session_is_live("wa-worker-adhoc-deadbeef", [], T_az))

    # --- AZ-8: dog-pool concrete session form IS swept (ga-9vi19) ---
    # Was "→ False (not in scope)" until ga-9vi19: dog-<suffix> is the assignee
    # shape `gc bd update --claim` actually sets for a dog pool slot (confirmed
    # directly — a live session's own assignee took this exact form), and
    # _pool_of() already normalized it to "gastown.dog" for POOL-DEAD bucketing
    # (ga-dbibq) — only this reclaim-classification path had failed to agree.
    # Flipped alongside the code fix, not left stale (verify-fix-against-
    # deliberate-design: the old assertion's own rationale, "scope stays
    # wa-worker family", was superseded the moment gt-fppb0 put 'gastown.dog'
    # itself in EPHEMERAL_POOL_ASSIGNEES; no comment anywhere justified
    # excluding this sibling concrete form specifically).
    check("AZ-8: _is_ephemeral_pool_assignee: dog-gawispy8c0mr → True (ga-9vi19: dog-pool concrete form in scope)",
          _is_ephemeral_pool_assignee("dog-gawispy8c0mr"))
    check("AZ-8b: is_reclaimable_inprogress_story: dog-gawispy8c0mr without markers → True (ga-9vi19)",
          is_reclaimable_inprogress_story([], assignee="dog-gawispy8c0mr"))
    check("AZ-8c: _pool_of/_is_ephemeral_pool_assignee now agree on dog-gawispy8c0mr (ga-9vi19)",
          _pool_of("dog-gawispy8c0mr") == "gastown.dog" and
          _is_ephemeral_pool_assignee("dog-gawispy8c0mr"))
    check("AZ-8d: _is_ephemeral_pool_assignee: dog-gawispy8c0mr is adhoc-only, not bare (is_bare_pool_zombie stays False)",
          "dog-gawispy8c0mr" not in EPHEMERAL_POOL_ASSIGNEES and
          _is_ephemeral_pool_assignee("dog-gawispy8c0mr"))
    check("AZ-8e: _is_ephemeral_pool_assignee: dogwatcher-wa (no hyphen after 'dog') stays False (prefix precision)",
          not _is_ephemeral_pool_assignee("dogwatcher-wa"))

    # --- AZ-9c: full pipeline — dog-pool concrete session, dead, stranded 2h+ → reclaim (ga-9vi19) ---
    # Mirrors AZ-3 (wa-worker-adhoc) for the dog-pool concrete form: proves the
    # classification fix changes an end-to-end outcome, not just an isolated predicate.
    check("AZ-9c: reclaim_decision: dog-<suffix>+dead session, no branch, stranded>POOL_ZOMBIE_TTL → reclaim (ga-9vi19)",
          reclaim_decision(
              has_live_session=concrete_adhoc_session_is_live(
                  "dog-ga2rkia", [], T_az),
              has_recent_branch=False,
              seconds_stranded=POOL_ZOMBIE_TTL + 1,
              reclaim_count=0,
              has_needs_human=False,
              has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "reclaim")

    # --- AZ-9d: dog-<suffix> now needs the LONGER POOL_ZOMBIE_TTL wait, not RECLAIM_TTL ---
    # ga-9vi19 behavior change: pre-fix this assignee fell to the generic `else`
    # branch and only needed RECLAIM_TTL (25min); post-fix is_pool_zombie_bead=True
    # grants (and requires) the same 2h patience wa-worker-adhoc-<hex> already gets.
    check("AZ-9d: reclaim_decision: dog-<suffix> stranded 30min (<POOL_ZOMBIE_TTL) → noop (ga-9vi19: needs full 2h now)",
          reclaim_decision(
              has_live_session=False,
              has_recent_branch=False,
              seconds_stranded=1800,  # 30min: > RECLAIM_TTL (25min), < POOL_ZOMBIE_TTL (2h)
              reclaim_count=0,
              has_needs_human=False,
              has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL,
          ) == "noop")

    # --- AZ-9: bare wa-worker regression — existing pool-wide behavior unchanged ---
    check("AZ-9: _is_ephemeral_pool_assignee: bare wa-worker still detected (regression check)",
          _is_ephemeral_pool_assignee("wa-worker"))
    check("AZ-9b: is_reclaimable_inprogress_story: bare wa-worker still qualifies (regression check)",
          is_reclaimable_inprogress_story([], assignee="wa-worker"))

    # --- AZ-DUP: duplicate identifier — dead first, live second → live wins (scan-all hardening) ---
    # Scenario: two sessions share the same concrete adhoc identifier.
    # The FIRST is asleep/drained (dead). The SECOND is active with a fresh last_active.
    # Before the fix an early `return False` on the dead session would declare the bead
    # reclaimable even though a live successor exists → false reclaim that kills a live build.
    # After the fix: continue scanning; the live session wins → bead is NOT reclaimed.
    _fresh_az_dup = _irg_datetime.datetime.fromtimestamp(
        T_az - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _adhoc_dup_sessions = [
        {"id": "sid-dup1", "name": "wa-worker-adhoc-dupbeef",
         "session_name": "wa-worker-adhoc-dupbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-dupbeef",
         "state": "asleep",
         "last_active": "0001-01-01T00:00:00Z"},
        {"id": "sid-dup2", "name": "wa-worker-adhoc-dupbeef",
         "session_name": "wa-worker-adhoc-dupbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-dupbeef",
         "state": "active",
         "last_active": _fresh_az_dup},
    ]
    check("AZ-DUP: concrete_adhoc_session_is_live: dead first + live second → True (live successor wins; no false reclaim)",
          concrete_adhoc_session_is_live(
              "wa-worker-adhoc-dupbeef", _adhoc_dup_sessions, T_az))

    # -----------------------------------------------------------------------
    # Section 6: ga-lrglm — list_gate_active_source_beads() sling
    # back-reference resolution (SB-*). Stubs subprocess.run to serve canned
    # `bd list --label type:quality-gate-marker ...` and `bd show <ids>`
    # responses; no real bd/network calls.
    # -----------------------------------------------------------------------

    _orig_run_sb = subprocess.run

    def _stub_bd(markers_by_gatelbl, titles_by_id, list_fails=False, show_fails=False):
        """Build a subprocess.run stub for list_gate_active_source_beads().

        markers_by_gatelbl: {gate_lbl: [[marker_labels...], ...]} — for each
          gate-status label queried, the marker beads (each a list of its own
          labels) to return.
        titles_by_id: {bead_id: title} — canned `bd show` response titles.
        """
        class _R:
            def __init__(self, rc, out):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""

        def _run(cmd, **kw):
            if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "bd" and cmd[1] == "list":
                if list_fails:
                    # rc=0 + unparseable stdout simulates a parse failure (SB-7:
                    # fail-SAFE → None). A bare non-zero exit is a separate scenario,
                    # stubbed directly in SB-7b below — also fail-SAFE → None as of
                    # ga-ap7od (a non-zero exit means the query FAILED; real `bd list`
                    # returns rc=0 + "[]" for zero matches, verified live).
                    return _R(0, "{not valid json")
                # cmd shape: ["bd","list",...,"--label","type:quality-gate-marker","--label",gate_lbl,...]
                # gate_lbl is the value after the SECOND "--label" flag (the first is
                # always type:quality-gate-marker). Found by flag name, not fixed
                # position (ga-vm20x): a hardcoded cmd[5] broke the instant
                # list_gate_active_source_beads() gained a new flag ahead of --label
                # (--include-infra at index 2) — searching by flag survives the next one.
                _label_positions = [i for i, a in enumerate(cmd) if a == "--label"]
                gate_lbl = cmd[_label_positions[1] + 1] if len(_label_positions) >= 2 and _label_positions[1] + 1 < len(cmd) else ""
                markers = markers_by_gatelbl.get(gate_lbl, [])
                payload = [{"id": f"marker-{i}", "labels": lbls} for i, lbls in enumerate(markers)]
                return _R(0, json.dumps(payload))
            if isinstance(cmd, (list, tuple)) and len(cmd) >= 2 and cmd[0] == "bd" and cmd[1] == "show":
                if show_fails:
                    return _R(1, "")
                ids = [a for a in cmd[2:] if a != "--json"]
                payload = [{"id": i, "title": titles_by_id.get(i, "")} for i in ids]
                return _R(0, json.dumps(payload))
            return _R(0, "")
        return _run

    try:
        # --- SB-1: no active markers at all → empty set (and no back-ref lookup needed) ---
        subprocess.run = _stub_bd({}, {})
        _sb1 = list_gate_active_source_beads()
        check("SB-1: no active markers → empty frozenset",
              _sb1 == frozenset(), f"got={_sb1!r}")

        # --- SB-2: direct source-bead whose title does NOT follow the sling
        # convention (e.g. a rig-native bug bead) → only itself in the set ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-native1", "type:quality-gate-marker"]]},
            {"ga-native1": "some rig-native title with no sling convention"},
        )
        _sb2 = list_gate_active_source_beads()
        check("SB-2: non-sling source-bead → set contains only itself (no spurious back-ref)",
              _sb2 == frozenset({"ga-native1"}), f"got={_sb2!r}")

        # --- SB-3: sling-dispatched fix ("fix bug X: ...") → set contains BOTH
        # the sling bead AND the original bug it names ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-djjeq", "type:quality-gate-marker"]]},
            {"ga-djjeq": "fix bug ga-d2jil: Pilot NEVERSTARTED gate-marker guard checks..."},
        )
        _sb3 = list_gate_active_source_beads()
        check("SB-3: sling 'fix bug' title → set contains sling id AND original bug id",
              _sb3 == frozenset({"ga-djjeq", "ga-d2jil"}), f"got={_sb3!r}")

        # --- SB-4: 'build story' convention (feature/story tier) also resolves ---
        subprocess.run = _stub_bd(
            {"gate-status:ready": [["source-bead:ga-slingA", "type:quality-gate-marker"]]},
            {"ga-slingA": "build story ga-storyX: Add the frobnicator widget"},
        )
        _sb4 = list_gate_active_source_beads()
        check("SB-4: sling 'build story' title → set contains sling id AND original story id",
              _sb4 == frozenset({"ga-slingA", "ga-storyX"}), f"got={_sb4!r}")

        # --- SB-5: multi-redispatch robustness (ga-d2jil's real 4-dispatch chain).
        # Only the FIRST historical sling (ga-djjeq) still has an active marker;
        # the bug's OWN pilot.sling_bead metadata would by now point at a LATER
        # sling (ga-7q8x1) that has no marker at all. Resolution must succeed
        # from ga-djjeq's title alone — it never reads pilot.sling_bead. ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-djjeq", "type:quality-gate-marker"]]},
            {"ga-djjeq": "fix bug ga-d2jil: Pilot NEVERSTARTED gate-marker guard..."},
            # Deliberately no entry for ga-7q8x1 — proves resolution doesn't need it.
        )
        _sb5 = list_gate_active_source_beads()
        check("SB-5: multi-redispatch — 1st-of-4 sling still resolves original bug (metadata-independent)",
              "ga-d2jil" in _sb5 and "ga-djjeq" in _sb5, f"got={_sb5!r}")

        # --- SB-6: bd-show (title-resolution) failure → fail-OPEN, keeps the
        # directly-active set, does NOT collapse the whole cycle to None ---
        subprocess.run = _stub_bd(
            {"gate-status:queued": [["source-bead:ga-djjeq", "type:quality-gate-marker"]]},
            {}, show_fails=True,
        )
        _sb6 = list_gate_active_source_beads()
        check("SB-6: bd-show failure during back-ref resolution → fail-OPEN (direct set preserved, not None)",
              _sb6 == frozenset({"ga-djjeq"}), f"got={_sb6!r}")

        # --- SB-7: bd-list returning unparseable JSON → fail-SAFE, whole cycle → None
        # (pre-existing contract; regression check — the back-ref addition must not
        # weaken it) ---
        subprocess.run = _stub_bd({}, {}, list_fails=True)
        _sb7 = list_gate_active_source_beads()
        check("SB-7: bd-list unparseable JSON → fail-SAFE None (pre-existing contract unchanged)",
              _sb7 is None, f"got={_sb7!r}")

        # --- SB-7b: bd-list non-zero exit → fail-SAFE None (ga-ap7od). Real `bd list`
        # returns rc=0 + "[]" for zero matches (verified live); a non-zero exit only
        # ever signals a query FAILURE (e.g. transient Dolt contention), so it must
        # trip the same fail-safe as SB-7 rather than being silently treated as "no
        # results". This inverts what this check locked in prior to ga-ap7od — that
        # old assumption was itself the bug: a real query failure on just one
        # gate_lbl silently dropped that label's active markers from the set. ---
        def _stub_bd_nonzero(cmd, **kw):
            class _RC:
                returncode = 1
                stdout = ""
                stderr = ""
            return _RC()
        subprocess.run = _stub_bd_nonzero
        _sb7b = list_gate_active_source_beads()
        check("SB-7b: bd-list non-zero exit → fail-SAFE None (ga-ap7od: was wrongly treated as empty)",
              _sb7b is None, f"got={_sb7b!r}")

        # --- SB-8: multiple active markers, only SOME are slings → mixed
        # resolution (direct ids + resolved back-refs, no cross-contamination) ---
        subprocess.run = _stub_bd(
            {
                "gate-status:queued": [
                    ["source-bead:ga-djjeq", "type:quality-gate-marker"],
                    ["source-bead:ga-native1", "type:quality-gate-marker"],
                ],
            },
            {
                "ga-djjeq": "fix bug ga-d2jil: ...",
                "ga-native1": "a directly-dispatched bead, no sling wrapper",
            },
        )
        _sb8 = list_gate_active_source_beads()
        check("SB-8: mixed direct + sling markers → union is correct, no cross-contamination",
              _sb8 == frozenset({"ga-djjeq", "ga-d2jil", "ga-native1"}), f"got={_sb8!r}")
    finally:
        subprocess.run = _orig_run_sb

    # --- SB-9: _SLING_TITLE_RE pure-regex edge cases (no subprocess involved) ---
    check("SB-9a: 'fix bug' matches and captures id up to colon",
          bool(_SLING_TITLE_RE.match("fix bug ga-abc12: some title")) and
          _SLING_TITLE_RE.match("fix bug ga-abc12: some title").group(1) == "ga-abc12")
    check("SB-9b: 'build story' matches and captures id up to colon",
          bool(_SLING_TITLE_RE.match("build story wa-xyz9: some title")) and
          _SLING_TITLE_RE.match("build story wa-xyz9: some title").group(1) == "wa-xyz9")
    check("SB-9c: unrelated title does not match",
          _SLING_TITLE_RE.match("investigate: something weird happened") is None)
    check("SB-9d: title missing the colon separator does not match",
          _SLING_TITLE_RE.match("fix bug ga-abc12 no colon here") is None)

    # -----------------------------------------------------------------------
    # Section 7: ga-qfo3 — list_live_sling_source_beads() sling→original
    # live-session resolution (SL-*). Stubs subprocess.run to serve canned
    # `bd list --status in_progress --json` responses; no real bd calls.
    #
    # Root cause (confirmed from the ga-qfo3 incident's launchd log): Pilot's
    # dispatch flow marks the ORIGINAL bug/story bead story:in-flight but
    # assigns the live builder session to a separate SLING bead instead
    # (title "fix bug <id>: ..." / "build story <id>: ..."). The guard's own
    # "started stranded clock" log line showed assignee='' for the ORIGINAL
    # bead (ga-z6uo) the whole time it was being live-built via its sling
    # (ga-vw39) — session_is_live() was checking the wrong bead's assignee
    # field, so a bead with a genuinely live builder got reclaimed at 31min
    # idle ("no_live_session no_recent_branch").
    # -----------------------------------------------------------------------

    _orig_run_sl = subprocess.run

    def _stub_inprogress(beads, list_fails=False, nonzero=False):
        """Build a subprocess.run stub for list_live_sling_source_beads()'s
        `bd list --status in_progress --json` query.

        beads: list of bead dicts (id/title/assignee/updated_at) to return.
        """
        class _R:
            def __init__(self, rc, out):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""

        def _run(cmd, **kw):
            if (isinstance(cmd, (list, tuple)) and len(cmd) >= 2
                    and cmd[0] == "bd" and cmd[1] == "list"):
                if nonzero:
                    return _R(1, "")
                if list_fails:
                    return _R(0, "{not valid json")
                return _R(0, json.dumps(beads))
            return _R(0, "")
        return _run

    _sl_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_pz - 30, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _sl_live_sessions = [
        {"id": "sid-sl1", "name": "gastown.dog-2", "session_name": "dog-ga5e06",
         "alias": "gastown.dog-2", "agent_name": "dog-ga5e06",
         "state": "active", "last_active": _sl_fresh_ts},
    ]

    try:
        # --- SL-1: sling bead in_progress + live-session assignee →
        # original id resolved into the protected set ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl1 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-1: live sling assignee → original bug id resolved into protected set",
              _sl1 == frozenset({"ga-z6uo"}), f"got={_sl1!r}")

        # --- SL-2: sling bead in_progress but assignee's session is DEAD →
        # original NOT protected (correctly reclaimable) ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl2 = list_live_sling_source_beads([], T_pz)  # no live sessions at all
        check("SL-2: sling assignee's session is dead/gone → original NOT protected",
              _sl2 == frozenset(), f"got={_sl2!r}")

        # --- SL-3: in_progress bead whose title does NOT follow the sling
        # convention (e.g. a plain crew/dog task) → no spurious protection ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-plain1", "title": "run the weekly Dolt backup",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl3 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-3: non-sling title → empty set (no spurious protection)",
              _sl3 == frozenset(), f"got={_sl3!r}")

        # --- SL-4: sling bead in_progress but UNCLAIMED (empty assignee) →
        # not protected (matches the pre-claim window; nothing to protect yet) ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "", "updated_at": ""},
        ])
        _sl4 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-4: unclaimed sling (empty assignee) → not protected",
              _sl4 == frozenset(), f"got={_sl4!r}")

        # --- SL-5: 'build story' convention also resolves (feature/story tier) ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-slingB", "title": "build story ga-storyY: Add the frobnicator",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl5 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-5: sling 'build story' title → original story id resolved",
              _sl5 == frozenset({"ga-storyY"}), f"got={_sl5!r}")

        # --- SL-6: bd-list non-zero exit → fail-SAFE None (mirrors ga-ap7od) ---
        subprocess.run = _stub_inprogress([], nonzero=True)
        _sl6 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-6: bd-list non-zero exit → fail-SAFE None",
              _sl6 is None, f"got={_sl6!r}")

        # --- SL-7: bd-list unparseable JSON → fail-SAFE None ---
        subprocess.run = _stub_inprogress([], list_fails=True)
        _sl7 = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        check("SL-7: bd-list unparseable JSON → fail-SAFE None",
              _sl7 is None, f"got={_sl7!r}")

        # --- SL-8: END-TO-END regression for the actual ga-qfo3 incident shape.
        # The ORIGINAL bug bead (ga-z6uo) carries story:in-flight with its OWN
        # assignee empty (exactly as the launchd log showed); its live builder
        # is only visible via the sling bead's assignee. Verify the full
        # has_live_session computation — session_is_live() on the empty
        # assignee alone (the pre-fix behavior) plus the sling-owner set OR'd
        # in (the fix) — now correctly protects it, so reclaim_decision is
        # "noop" instead of the "reclaim" the incident actually produced. ---
        subprocess.run = _stub_inprogress([
            {"id": "ga-vw39", "title": "fix bug ga-z6uo: chronic Dolt handle bug",
             "assignee": "dog-ga5e06", "updated_at": ""},
        ])
        _sl8_live_sling_owners = list_live_sling_source_beads(_sl_live_sessions, T_pz)
        _sl8_own_assignee_live = session_is_live("", _sl_live_sessions, T_pz)
        check("SL-8a: pre-fix signal — original bead's OWN (empty) assignee never matches a live session",
              _sl8_own_assignee_live is False, f"got={_sl8_own_assignee_live!r}")
        _sl8_has_live_session = _sl8_own_assignee_live or ("ga-z6uo" in _sl8_live_sling_owners)
        check("SL-8b: fix — OR'ing in the sling-owner set makes has_live_session True for ga-z6uo",
              _sl8_has_live_session is True, f"got={_sl8_has_live_session!r}")
        _sl8_decision = reclaim_decision(
            has_live_session=_sl8_has_live_session,
            has_recent_branch=False,  # ga-vw39 had no branch yet either, per the incident report
            seconds_stranded=RECLAIM_TTL + 60,  # past the 25min TTL, like the real incident (31min)
            reclaim_count=0,
            has_needs_human=False,
            has_dispatching_marker=False,
        )
        check("SL-8c: reclaim_decision — noop instead of the false 'reclaim' seen in the incident",
              _sl8_decision == "noop", f"got={_sl8_decision!r}")
    finally:
        subprocess.run = _orig_run_sl

    # -----------------------------------------------------------------------
    # Section 8: ga-ufr7 — push-before-reclaim + throttled-vs-dead (RL-*, PB-*)
    #
    # RL-*: account_is_rate_limited() delegates to claude-quota-check.sh --quiet
    # (exit 2 = LIMITED); reclaim_decision(account_rate_limited=...) must defer
    # (noop) a confirmed-limited cycle even when every other rail says reclaim
    # or escalate. PB-*: preserve_unpushed_branch() must push a local branch's
    # unpushed commit to origin under its own name, fall back to a
    # refs/reclaimed/<bead>/<sha> tag on rejection, and touch nothing when the
    # commit is already reachable from origin or no branch matches. All stub
    # subprocess.run — no real git/bd calls.
    # -----------------------------------------------------------------------

    class _FakeGitResult:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    # --- RL-1..3: account_is_rate_limited() exit-code contract ---
    _orig_run_rl = subprocess.run

    def _stub_quota(returncode=0, raise_exc=False):
        def _run(cmd, **kw):
            if raise_exc:
                raise TimeoutError("simulated quota-check timeout")
            assert cmd[0] == QUOTA_CHECK and "--quiet" in cmd, f"unexpected cmd: {cmd}"
            return _FakeGitResult(returncode)
        return _run

    try:
        subprocess.run = _stub_quota(returncode=2)
        check("RL-1: account_is_rate_limited: exit 2 → True (confirmed limited)",
              account_is_rate_limited() is True)

        subprocess.run = _stub_quota(returncode=0)
        check("RL-2: account_is_rate_limited: exit 0 → False (not limited)",
              account_is_rate_limited() is False)

        subprocess.run = _stub_quota(raise_exc=True)
        check("RL-3: account_is_rate_limited: script raises → False (fail-open, not a new stall)",
              account_is_rate_limited() is False)
    finally:
        subprocess.run = _orig_run_rl

    # --- RL-4..6: reclaim_decision() gated on account_rate_limited ---
    check("RL-4: reclaim_decision: rate-limited + otherwise-reclaimable → noop",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=RECLAIM_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              account_rate_limited=True,
          ) == "noop")
    check("RL-5: reclaim_decision: NOT rate-limited, same conditions → reclaim (default unchanged)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=RECLAIM_TTL + 1, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              account_rate_limited=False,
          ) == "reclaim")
    check("RL-6: reclaim_decision: rate-limited overrides escalate too (cap already hit)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=RECLAIM_TTL + 1, reclaim_count=MAX_RECLAIMS,
              has_needs_human=False, has_dispatching_marker=False,
              account_rate_limited=True,
          ) == "noop")

    # --- PB-*: preserve_unpushed_branch() ---
    global REPOS
    _orig_repos = REPOS
    _orig_run_pb = subprocess.run
    REPOS = ["/fake/repo"]
    _FAKE_SHA = "aaaa1111bbbb2222cccc3333dddd4444eeee5555"

    def _stub_preserve(branches, contains_origin=None, own_push_ok=True, tag_push_ok=True):
        contains_origin = contains_origin or set()

        def _run(cmd, **kw):
            if "fetch" in cmd:
                return _FakeGitResult(0)
            if "for-each-ref" in cmd:
                lines = "\n".join(f"refs/heads/{b} {s}" for b, s in branches)
                return _FakeGitResult(0, stdout=lines)
            if "branch" in cmd and "--contains" in cmd:
                sha = cmd[-1]
                return _FakeGitResult(0, stdout=("origin/x\n" if sha in contains_origin else ""))
            if "push" in cmd:
                refspec = cmd[-1]
                target = refspec.split(":", 1)[1]
                if target.startswith("refs/reclaimed/"):
                    return _FakeGitResult(0 if tag_push_ok else 1, stderr="" if tag_push_ok else "tag rejected")
                return _FakeGitResult(0 if own_push_ok else 1, stderr="" if own_push_ok else "! [rejected] non-fast-forward")
            return _FakeGitResult(0)
        return _run

    try:
        # PB-1: matching local branch, not on origin, own-name push succeeds.
        subprocess.run = _stub_preserve(
            branches=[("fix/ga-fakebead-my-fix", _FAKE_SHA)])
        res = preserve_unpushed_branch("ga-fakebead")
        check("PB-1: unpushed branch, own-name push succeeds → preserved via origin push",
              len(res) == 1 and "pushed to origin/fix/ga-fakebead-my-fix" in res[0],
              f"got={res!r}")

        # PB-2: own-name push rejected (diverged same-named branch) → falls back to tag.
        subprocess.run = _stub_preserve(
            branches=[("fix/ga-fakebead-my-fix", _FAKE_SHA)], own_push_ok=False, tag_push_ok=True)
        res = preserve_unpushed_branch("ga-fakebead")
        check("PB-2: own-name push rejected → falls back to refs/reclaimed/<bead>/<sha> tag",
              len(res) == 1 and f"tagged refs/reclaimed/ga-fakebead/{_FAKE_SHA}" in res[0],
              f"got={res!r}")

        # PB-3: commit already reachable from an origin ref → nothing to preserve.
        subprocess.run = _stub_preserve(
            branches=[("fix/ga-fakebead-my-fix", _FAKE_SHA)], contains_origin={_FAKE_SHA})
        res = preserve_unpushed_branch("ga-fakebead")
        check("PB-3: commit already on origin → preserved list empty (nothing to do)",
              res == [], f"got={res!r}")

        # PB-4: no local branch's segment matches this bead_id → nothing to preserve.
        subprocess.run = _stub_preserve(
            branches=[("fix/ga-someotherbead-fix", _FAKE_SHA)])
        res = preserve_unpushed_branch("ga-fakebead")
        check("PB-4: no matching branch segment → preserved list empty",
              res == [], f"got={res!r}")

        # PB-5: both own-name and tag push fail → best-effort, empty result, no raise.
        subprocess.run = _stub_preserve(
            branches=[("fix/ga-fakebead-my-fix", _FAKE_SHA)], own_push_ok=False, tag_push_ok=False)
        try:
            res = preserve_unpushed_branch("ga-fakebead")
            check("PB-5: both pushes fail → best-effort empty result, does not raise",
                  res == [], f"got={res!r}")
        except Exception as exc:
            check("PB-5: both pushes fail → best-effort empty result, does not raise",
                  False, f"raised {exc!r} instead of returning []")
    finally:
        subprocess.run = _orig_run_pb
        REPOS = _orig_repos

    # -----------------------------------------------------------------------
    # Section 9: gt-fppb0 — provably-dead fast-path in reclaim_decision (FP-*).
    # A PROVABLY-DEAD claimant reclaims at seconds_stranded=0 (bypasses the
    # hysteresis); a merely-quiet one still serves the full window; every safety
    # guard still vetoes before the fast-path fires; the thrash cap still holds.
    # Pure function — no bd/gc/git. (min_stranding_secs=POOL_ZOMBIE_TTL: the dog
    # pool's window, so seconds_stranded=0 is unambiguously "before hysteresis".)
    # -----------------------------------------------------------------------
    def _rd(**kw):
        base = dict(has_live_session=False, has_recent_branch=False,
                    seconds_stranded=0.0, reclaim_count=0,
                    has_needs_human=False, has_dispatching_marker=False,
                    min_stranding_secs=POOL_ZOMBIE_TTL)
        base.update(kw)
        return reclaim_decision(**base)

    check("FP-1: provably_dead + stranded=0 + all clear → reclaim (fast-path; was noop pre-fix)",
          _rd(provably_dead=True) == "reclaim")
    check("FP-2: NOT provably_dead + stranded=0 → noop (merely-quiet keeps hysteresis)",
          _rd(provably_dead=False) == "noop")
    check("FP-3: provably_dead BUT has_needs_human → noop (park guard wins)",
          _rd(provably_dead=True, has_needs_human=True) == "noop")
    check("FP-4: provably_dead BUT has_dispatching_marker → noop (gate guard wins)",
          _rd(provably_dead=True, has_dispatching_marker=True) == "noop")
    check("FP-5: provably_dead BUT account_rate_limited → noop (ga-ufr7 guard wins)",
          _rd(provably_dead=True, account_rate_limited=True) == "noop")
    check("FP-6: provably_dead BUT has_live_session → noop (live builder guard wins)",
          _rd(provably_dead=True, has_live_session=True) == "noop")
    check("FP-7: provably_dead BUT has_recent_branch → noop (branch rail wins)",
          _rd(provably_dead=True, has_recent_branch=True) == "noop")
    check("FP-8: provably_dead + reclaim_count=MAX_RECLAIMS → escalate (cap still holds)",
          _rd(provably_dead=True, reclaim_count=MAX_RECLAIMS) == "escalate")
    check("FP-8b: provably_dead + reclaim_count=MAX-1 → reclaim (still below cap)",
          _rd(provably_dead=True, reclaim_count=MAX_RECLAIMS - 1) == "reclaim")
    check("FP-9: DEFAULT (provably_dead unset) + stranded=0 → noop (backward-compat unchanged)",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=0.0, reclaim_count=0,
              has_needs_human=False, has_dispatching_marker=False,
              min_stranding_secs=POOL_ZOMBIE_TTL) == "noop")

    # -----------------------------------------------------------------------
    # Section 9b: ga-be4x — explicit refusal signal (RF-*).
    # A worker's STATED refusal (pool:refused[:reason] label, set deliberately
    # before draining) is a categorically different signal from an INFERRED
    # drain/crash: reclaim_decision escalates after REFUSAL_ESCALATE_THRESHOLD
    # independent refusals of the SAME bead — well before the generic
    # MAX_RECLAIMS thrash cap would fire — while an unexplained death (no
    # refusal label ever set) is completely unaffected (AC2). Pure-function
    # checks first, then do_reclaim()/do_escalate() bookkeeping (consume
    # marker → permanent audit label → counter bump → refusal-specific
    # escalate message) verified via a minimal subprocess.run stub.
    # -----------------------------------------------------------------------

    # --- Pure helpers ---
    check("RFH-1: _has_refusal_label: bare 'pool:refused' → True",
          _has_refusal_label(["pool:refused"]) is True)
    check("RFH-2: _has_refusal_label: 'pool:refused:<reason>' → True",
          _has_refusal_label(["story:in-flight", "pool:refused:cross-rig-framework"]) is True)
    check("RFH-3: _has_refusal_label: no marker present → False",
          _has_refusal_label(["story:in-flight", "pilot:dispatched"]) is False)
    check("RFH-4: _has_refusal_label: unrelated 'pool:' label does not false-positive",
          _has_refusal_label(["pool:something-else"]) is False)
    check("RFRS-1: _refusal_reason_slugs: extracts the reason",
          _refusal_reason_slugs(["pool:refused:cross-rig-framework"]) == ["cross-rig-framework"])
    check("RFRS-2: _refusal_reason_slugs: bare marker → 'unspecified'",
          _refusal_reason_slugs(["pool:refused"]) == ["unspecified"])
    check("RFRS-3: _refusal_reason_slugs: no marker → empty list",
          _refusal_reason_slugs(["story:in-flight"]) == [])
    check("PRC-1: parse_refusal_count: present → int",
          parse_refusal_count(["pilot:refusal-count:2"]) == 2)
    check("PRC-2: parse_refusal_count: absent → 0",
          parse_refusal_count(["story:in-flight"]) == 0)
    check("PRC-3: parse_refusal_count: malformed → 0 (fail-safe)",
          parse_refusal_count(["pilot:refusal-count:nan"]) == 0)

    # --- RF-1/2: the core AC1 behavior — escalate on the 2nd independent
    #     refusal, faster than (and independent of) the generic thrash cap ---
    check("RF-1: reclaim_decision: 1st explicit refusal (refusal_count=0) → reclaim, not escalate yet",
          _rd(has_explicit_refusal=True, refusal_count=0) == "reclaim")
    check("RF-2: reclaim_decision: 2nd independent refusal (refusal_count=1) → escalate "
          "(reclaim_count=1 is nowhere near MAX_RECLAIMS=3 — proves this is FASTER than the generic cap)",
          _rd(has_explicit_refusal=True, refusal_count=1, reclaim_count=1) == "escalate")
    check("RF-3: refusal_count>=threshold but has_explicit_refusal=False THIS cycle → unaffected "
          "(a stale/historical counter must not retroactively trigger anything without a fresh signal)",
          _rd(has_explicit_refusal=False, refusal_count=5) == "noop")

    # --- RF-4 (REVISED by ga-vu718 — was "has_live_session wins"): a live
    #     session no longer masks a refusal that has crossed the escalate
    #     threshold; see the reclaim_decision() ordering comment for why. This
    #     assertion is an intentional reversal of the pre-fix expectation, not
    #     a silent overwrite — pre-fix this exact input produced "noop" (that
    #     was the bug: a continuously-alive session could refuse forever
    #     without ever tripping REFUSAL_ESCALATE_THRESHOLD; 3 corroborated
    #     live incidents). RF-4b anchors AC3: the original live-builder
    #     protection stays fully intact for a refusal that has NOT yet
    #     crossed the threshold. RF-5..8: every OTHER existing safety guard
    #     still outranks refusal-escalate, unchanged. ---
    check("RF-4: 2nd refusal + has_live_session → escalate (ga-vu718: liveness no longer "
          "masks an already-crossed refusal threshold; was 'noop' pre-fix)",
          _rd(has_explicit_refusal=True, refusal_count=1, has_live_session=True) == "escalate")
    check("RF-4b (ga-vu718 AC3 anchor): 1st refusal (not yet crossing threshold) + "
          "has_live_session → still noop (original live-builder protection intact)",
          _rd(has_explicit_refusal=True, refusal_count=0, has_live_session=True) == "noop")
    check("RF-5: 2nd refusal BUT has_needs_human → noop (park guard wins)",
          _rd(has_explicit_refusal=True, refusal_count=1, has_needs_human=True) == "noop")
    check("RF-6: 2nd refusal BUT has_dispatching_marker → noop (gate guard wins)",
          _rd(has_explicit_refusal=True, refusal_count=1, has_dispatching_marker=True) == "noop")
    check("RF-7: 2nd refusal BUT account_rate_limited → noop (ga-ufr7 guard wins)",
          _rd(has_explicit_refusal=True, refusal_count=1, account_rate_limited=True) == "noop")
    check("RF-8 (ga-vu718: deliberately UNCHANGED): 2nd refusal BUT has_recent_branch → "
          "noop (branch rail still wins — a fresh commit is evidence of new work, unlike "
          "mere liveness, and no incident reports this guard misfiring the same way)",
          _rd(has_explicit_refusal=True, refusal_count=1, has_recent_branch=True) == "noop")

    # --- RFB-*: should_fetch_branch_for_reclaim() — the run_cycle CALLER-side
    #     wiring bug from the first ga-vu718 gate attempt (gate_run=ga-qzciy).
    #     RF-4 above proves reclaim_decision() itself has the right truth
    #     table; it does NOT prove run_cycle() feeds it an accurate
    #     has_recent_branch. The gate reviewer's exact finding: run_cycle
    #     defaulted has_recent_branch=False whenever has_live_session=True (a
    #     perf shortcut, skips a real git fetch) — safe pre-fix (has_live_session
    #     always noop'd regardless), but NOT safe once escalate could fire
    #     ahead of has_live_session for an already-crossed refusal, and
    #     invisible to _selftest() because run_cycle() itself is never called
    #     by it. These tests exercise the extracted decision function
    #     directly, closing exactly that blind spot. ---
    check("RFB-1 (GATE-FEEDBACK regression anchor): has_live_session=True AND refusal "
          "about to cross threshold → MUST fetch (this is the exact scenario the gate "
          "reviewer found: a pool-slot worker's 2nd refusal, still reading as live, "
          "with a real recent commit the pre-fix shortcut would have hidden)",
          should_fetch_branch_for_reclaim(
              has_live_session=True, has_needs_human=False, has_dispatching_marker=False,
              has_suspended_owner=False, has_explicit_refusal=True, refusal_count=1) is True)
    check("RFB-2 (AC3 preserved): has_live_session=True AND 1st refusal (not yet crossing) "
          "→ skip fetch (original fast-path unchanged — matches RF-4b's noop outcome)",
          should_fetch_branch_for_reclaim(
              has_live_session=True, has_needs_human=False, has_dispatching_marker=False,
              has_suspended_owner=False, has_explicit_refusal=True, refusal_count=0) is False)
    check("RFB-3: has_live_session=True AND no refusal at all → skip fetch (base case, "
          "unaffected by this bug or its fix)",
          should_fetch_branch_for_reclaim(
              has_live_session=True, has_needs_human=False, has_dispatching_marker=False,
              has_suspended_owner=False, has_explicit_refusal=False, refusal_count=0) is False)
    check("RFB-4: has_live_session=False → always fetch regardless of refusal state "
          "(pre-existing behavior, this fix must not touch the non-live path)",
          should_fetch_branch_for_reclaim(
              has_live_session=False, has_needs_human=False, has_dispatching_marker=False,
              has_suspended_owner=False, has_explicit_refusal=False, refusal_count=0) is True)
    check("RFB-5: has_needs_human=True wins even with a live session AND a crossing "
          "refusal → skip fetch (park guard outranks everything, matches RF-5)",
          should_fetch_branch_for_reclaim(
              has_live_session=True, has_needs_human=True, has_dispatching_marker=False,
              has_suspended_owner=False, has_explicit_refusal=True, refusal_count=1) is False)
    check("RFB-6: has_dispatching_marker=True wins even with a live session AND a "
          "crossing refusal → skip fetch (gate guard outranks everything, matches RF-6)",
          should_fetch_branch_for_reclaim(
              has_live_session=True, has_needs_human=False, has_dispatching_marker=True,
              has_suspended_owner=False, has_explicit_refusal=True, refusal_count=1) is False)
    check("RFB-7: has_suspended_owner=True wins even with a live session AND a crossing "
          "refusal → skip fetch (this only proves the fetch-SKIP decision; it does NOT "
          "prove reclaim_decision()'s actual downstream action — see RFB-9 for that)",
          should_fetch_branch_for_reclaim(
              has_live_session=True, has_needs_human=False, has_dispatching_marker=False,
              has_suspended_owner=True, has_explicit_refusal=True, refusal_count=1) is False)

    # --- RFB-8: END-TO-END closure of the gate reviewer's concrete failure
    #     scenario — ties RFB-1 (the caller decides to fetch) and RF-8 (the
    #     pure function honors a True result) into one assertion under the
    #     reviewer's own labeling, so a future reader can confirm the exact
    #     cited scenario is covered without combining two other tests by
    #     hand. Precondition asserted first: this only proves anything if
    #     should_fetch_branch_for_reclaim actually decides to fetch for these
    #     inputs (the first gate attempt's code always defaulted False here,
    #     which is precisely what RFB-1 catches independently). ---
    assert should_fetch_branch_for_reclaim(
        has_live_session=True, has_needs_human=False, has_dispatching_marker=False,
        has_suspended_owner=False, has_explicit_refusal=True, refusal_count=1) is True, (
        "RFB-8 precondition failed: should_fetch_branch_for_reclaim must fetch here "
        "(same inputs as RFB-1) or this test isn't exercising the real wiring")
    check("RFB-8 (end-to-end GATE-FEEDBACK closure): live session, 2nd refusal, AND a "
          "real recent commit the fetch would have found → noop, NOT escalate (the "
          "'branch rail still wins' guarantee this diff promises, actually delivered "
          "through the full run_cycle wiring, not just the pure function in isolation)",
          _rd(has_explicit_refusal=True, refusal_count=1, has_live_session=True,
              has_recent_branch=True) == "noop")

    # --- RFB-9 (2nd GATE-FEEDBACK regression anchor, gate_run=ga-0uwrm): the
    #     suspended-owner analog of RFB-8. RFB-7 above proves only that the
    #     branch FETCH is skipped for a suspended owner — it says nothing
    #     about reclaim_decision()'s actual downstream action, which is
    #     exactly the gap the 2nd gate reviewer found: has_suspended_owner
    #     had no path into reclaim_decision() at all (it only drove the
    #     fetch-skip decision and the strand-clock pin), so a suspended
    #     owner whose refusal has just crossed REFUSAL_ESCALATE_THRESHOLD
    #     fell through to the escalate check — which now runs ahead of
    #     has_live_session and the hysteresis check, the only two places
    #     has_suspended_owner used to matter — and escalated. That is
    #     exactly what must never happen to a parked crew (do_escalate()'s
    #     own docstring: "must NOT be reclaimed... should WAIT for the crew
    #     to resume, not re-pool"). has_suspended_owner is now its own
    #     top-tier reclaim_decision() guard (same tier as has_needs_human /
    #     has_dispatching_marker, checked ahead of has_recent_branch and the
    #     escalate branch), so this must be noop regardless of
    #     has_live_session or an already-crossed refusal count. ---
    check("RFB-9 (GATE-FEEDBACK regression anchor #2): has_suspended_owner=True, live "
          "session, 2nd refusal (crossed threshold) → noop, NOT escalate (suspended-"
          "owner HOLD actually outranks the escalate branch itself, not just the "
          "fetch-skip decision RFB-7 tests)",
          _rd(has_suspended_owner=True, has_explicit_refusal=True, refusal_count=1,
              has_live_session=True) == "noop")
    check("RFB-9b: has_suspended_owner=True also outranks the plain reclaim/thrash-cap "
          "path (no refusal in play at all) — same guard, non-escalate branch",
          _rd(has_suspended_owner=True, reclaim_count=MAX_RECLAIMS) == "noop")

    # --- RF-9: generic MAX_RECLAIMS cap still holds as a backstop even on a
    #     bead's FIRST refusal (defense-in-depth: refusal and unexplained-death
    #     cycles can interleave on the same bead) ---
    check("RF-9: 1st refusal BUT reclaim_count=MAX_RECLAIMS (interleaved deaths) → escalate (generic cap)",
          _rd(has_explicit_refusal=True, refusal_count=0, reclaim_count=MAX_RECLAIMS) == "escalate")

    # --- RF-10 (AC2 regression anchor): an UNEXPLAINED death — provably_dead
    #     but no refusal label EVER set — is completely unaffected by this fix.
    #     Still re-dispatches exactly as before, all the way to MAX_RECLAIMS. ---
    check("RF-10 (AC2): provably_dead, no refusal label, reclaim_count=1 → still reclaim (no regression)",
          _rd(provably_dead=True, has_explicit_refusal=False, reclaim_count=1) == "reclaim")
    check("RF-10b (AC2): provably_dead, no refusal label, reclaim_count=MAX_RECLAIMS → still escalate via generic cap",
          _rd(provably_dead=True, has_explicit_refusal=False, reclaim_count=MAX_RECLAIMS) == "escalate")

    # --- RF-11 MUTATION TEST (AC3): "revert the distinction" = the caller
    #     never passes has_explicit_refusal (its default, exactly what run_cycle
    #     did pre-fix). Same inputs as RF-2 — including provably_dead=True,
    #     because a bare-pool-zombie session that drained after refusing really
    #     IS provably_dead under the pre-existing session-state machinery —
    #     but with the discriminator withheld. Pre-fix, this bead's 2nd
    #     independent refusal was indistinguishable from its 2nd unexplained
    #     death: it just got reclaimed a 3rd time and re-dispatched — the exact
    #     infinite loop ga-be4x reports. The outcome MUST differ from RF-2
    #     (escalate) for RF-2 to mean anything.
    check("RF-11 MUTATION: identical 2nd-refusal-and-provably-dead inputs but has_explicit_refusal "
          "withheld (reverted) → reclaim, NOT escalate — proves the ga-be4x guard has teeth "
          "(this bead would loop forever pre-fix)",
          _rd(has_explicit_refusal=False, refusal_count=1, reclaim_count=1, provably_dead=True) == "reclaim")

    # --- RF-12: do_reclaim() consumes the ephemeral pool:refused:<reason>
    #     marker, promotes it to a PERMANENT pilot:refused-reason:<slug> audit
    #     label, and bumps pilot:refusal-count — while still performing the
    #     normal reclaim mechanics unchanged. ---
    _rf_mutations = []
    # ga-jzye0 fix-attempt-2: lazily tracks each bead's label set so `bd show`
    # read-backs (_remove_label_verified) see a real bead shape reflecting
    # prior add/remove calls, instead of unconditionally looking like an
    # unreadable error envelope. Pre-fix this stub always returned empty
    # stdout for `bd show`, so EVERY do_reclaim() call in RF-12/RS-12/RS-14
    # aborted at step 1 (label removal never confirmable) before ever
    # reaching the code these tests exist to exercise — a latent regression
    # from fix-attempt-1 itself, uncaught because /gate-done didn't run this
    # file's own --selftest before submitting.
    _rf_labels = {}

    def _stub_run_rf(cmd, **kw):
        class _R:
            def __init__(self, rc=0, out=""):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""
        if not isinstance(cmd, (list, tuple)):
            return _R()
        _rf_mutations.append(list(cmd))
        args = list(cmd)
        if args and args[0] == "bd":
            rest = args[1:]
            if len(rest) >= 2 and rest[0] == "-C":
                rest = rest[2:]
            if len(rest) >= 4 and rest[0] == "label" and rest[1] in ("add", "remove"):
                bead_id, label = rest[2], rest[3]
                cur = _rf_labels.setdefault(bead_id, set())
                (cur.discard if rest[1] == "remove" else cur.add)(label)
            elif len(rest) >= 2 and rest[0] == "show":
                bead_id = rest[1]
                return _R(0, json.dumps(
                    {"id": bead_id, "labels": sorted(_rf_labels.get(bead_id, set()))}))
        return _R()

    _orig_run_rf = subprocess.run
    subprocess.run = _stub_run_rf
    try:
        do_reclaim(
            "ga-refused1", "some bead", reclaim_count=0, idle_min=5.0,
            labels=["story:in-flight", "pilot:dispatched", "pool:refused:cross-rig-framework"],
            has_explicit_refusal=True, refusal_count=0,
        )
        check("RF-12a: do_reclaim removes the ephemeral pool:refused:<reason> marker (consumed, not left stale)",
              ["bd", "label", "remove", "ga-refused1", "pool:refused:cross-rig-framework", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-12b: do_reclaim adds a PERMANENT pilot:refused-reason:<slug> audit label",
              ["bd", "label", "add", "ga-refused1", "pilot:refused-reason:cross-rig-framework", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-12c: do_reclaim bumps pilot:refusal-count 0 → 1",
              ["bd", "label", "add", "ga-refused1", "pilot:refusal-count:1", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-12d: do_reclaim still performs the normal story:in-flight cleanup (base behavior unchanged)",
              ["bd", "label", "remove", "ga-refused1", "story:in-flight", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
    finally:
        subprocess.run = _orig_run_rf

    # --- RF-13: do_escalate() ADDS gate:needs-human:refused ALONGSIDE (never
    #     instead of) the existing gate:needs-human:technical — swapping it
    #     would silently drop the bead out of quorum-convergence-watchdog's
    #     exact `--label gate:needs-human:technical` fallback query — and
    #     quotes every accumulated refusal reason verbatim.
    #
    #     ga-be4x GATE-FEEDBACK FIX: the fixture below matches the REAL call
    #     shape reclaim_decision()/run_cycle() produce on the triggering
    #     escalation cycle — one reason ALREADY promoted from a prior reclaim
    #     (pilot:refused-reason:cross-rig-framework) plus the CURRENT (2nd,
    #     triggering) refusal still sitting as a fresh, un-promoted
    #     pool:refused:<reason> label (pool:refused:hex-notebook-native) and
    #     matching pilot:refusal-count:1. The PRIOR version of this test
    #     hand-fabricated BOTH reasons as already-promoted
    #     pilot:refused-reason:* labels — a shape that can never actually
    #     occur on an escalating cycle — and so it passed even though
    #     do_escalate() silently dropped the triggering reason from both its
    #     own comment and run_cycle()'s [POOL-REFUSED-ESCALATED] Mayor mail
    #     (found by gate review on fix-attempt 1). ---
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        _rf13_result = do_escalate(
            "ga-refused1", "some bead", reclaim_count=1, idle_min=10.0,
            labels=["story:in-flight", "pilot:refused-reason:cross-rig-framework",
                    "pilot:refusal-count:1", "pool:refused:hex-notebook-native"],
            has_explicit_refusal=True, refusal_count=1,
        )
        check("RF-13a: do_escalate adds gate:needs-human:refused when refusal-triggered",
              ["bd", "label", "add", "ga-refused1", "gate:needs-human:refused", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-13b: do_escalate STILL adds gate:needs-human:technical too (quorum-watchdog safety net preserved)",
              ["bd", "label", "add", "ga-refused1", "gate:needs-human:technical", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        _rf_comment_calls = [m for m in _rf_mutations if len(m) >= 2 and m[1] == "comment"]
        check("RF-13c: do_escalate emits exactly ONE comment (not both the generic and refusal-specific text)",
              len(_rf_comment_calls) == 1,
              f"comment_calls={_rf_comment_calls!r}")
        check("RF-13d (GATE-FEEDBACK regression anchor): do_escalate's comment quotes BOTH "
              "the already-promoted reason AND the still-fresh triggering reason verbatim "
              "(pre-fix, hex-notebook-native — the reason that CAUSED this escalation — was "
              "silently absent here)",
              len(_rf_comment_calls) == 1
              and "cross-rig-framework" in _rf_comment_calls[0][-1]
              and "hex-notebook-native" in _rf_comment_calls[0][-1],
              f"comment_calls={_rf_comment_calls!r}")
        check("RF-13e: do_escalate consumes the fresh pool:refused:<reason> marker (removed, not left stale)",
              ["bd", "label", "remove", "ga-refused1", "pool:refused:hex-notebook-native", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-13f: do_escalate promotes the fresh marker into a PERMANENT pilot:refused-reason:<slug> label",
              ["bd", "label", "add", "ga-refused1", "pilot:refused-reason:hex-notebook-native", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-13g (GATE-FEEDBACK regression anchor): do_escalate bumps pilot:refusal-count "
              "1 → 2 on the triggering cycle (pre-fix this bump lived ONLY inside do_reclaim(), "
              "which never runs on an escalating cycle — refusal-count stayed permanently "
              "under-counted by one)",
              ["bd", "label", "remove", "ga-refused1", "pilot:refusal-count:1", "-q"] in _rf_mutations
              and ["bd", "label", "add", "ga-refused1", "pilot:refusal-count:2", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-13h: do_escalate returns the complete reason list (both reasons) so run_cycle's "
              "[POOL-REFUSED-ESCALATED] Mayor mail can reuse it instead of re-deriving (and "
              "re-dropping) it from the stale pre-promotion labels",
              isinstance(_rf13_result, list)
              and "cross-rig-framework" in _rf13_result
              and "hex-notebook-native" in _rf13_result,
              f"result={_rf13_result!r}")
    finally:
        subprocess.run = _orig_run_rf

    # --- RF-14: do_escalate() on a NON-refusal (generic MAX_RECLAIMS) escalation
    #     — gate:needs-human:technical, generic comment text, no :refused label
    #     (AC2 regression anchor for do_escalate specifically, mirroring
    #     RF-10/RF-10b at the reclaim_decision layer). RF-14e/f/g (ga-egd5av)
    #     additionally anchor the reclaim-count RESET this escalation now
    #     performs — see that fix's docstring on do_escalate() for the full
    #     incident (wa-uknuq re-escalated on a stale, never-reset count). ---
    # ga-egd5av: realistic starting labels include the numeric counter this
    # escalation is triggered by (the wa-uknuq bead genuinely carried
    # pilot:reclaim-count:3 when it escalated) — needed so RF-14g below can
    # derive the true post-escalation label set from do_escalate()'s own
    # recorded mutations instead of a hand-typed literal.
    _rf14_start_labels = ["story:in-flight", "pilot:dispatched", f"pilot:reclaim-count:{MAX_RECLAIMS}"]
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        _rf14_result = do_escalate(
            "ga-dead1", "some other bead", reclaim_count=MAX_RECLAIMS, idle_min=40.0,
            labels=_rf14_start_labels,
        )
        check("RF-14a: do_escalate (no refusal) does NOT add gate:needs-human:refused",
              ["bd", "label", "add", "ga-dead1", "gate:needs-human:refused", "-q"] not in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-14b: do_escalate (no refusal) still adds gate:needs-human:technical (unchanged)",
              ["bd", "label", "add", "ga-dead1", "gate:needs-human:technical", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        _rf_comment_calls2 = [m for m in _rf_mutations if len(m) >= 2 and m[1] == "comment"]
        check("RF-14c: do_escalate (no refusal) comment still names ga-6ow4v + reclaim cap",
              len(_rf_comment_calls2) == 1 and "ga-6ow4v" in _rf_comment_calls2[0][-1]
              and "reclaim cap" in _rf_comment_calls2[0][-1],
              f"comment_calls={_rf_comment_calls2!r}")
        check("RF-14d: do_escalate (no refusal) returns an empty reason list (no promotion helper call)",
              _rf14_result == [], f"result={_rf14_result!r}")
        # ga-egd5av: the escalation must consume the stale numeric counter so
        # a later human clearing gate:needs-human gets a genuinely fresh
        # budget, not an instant re-escalation on the same exhausted count.
        check("RF-14e (ga-egd5av): do_escalate removes the OLD numeric pilot:reclaim-count label",
              ["bd", "label", "remove", "ga-dead1", f"pilot:reclaim-count:{MAX_RECLAIMS}", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
        check("RF-14f (ga-egd5av): do_escalate adds a non-numeric 'spent' reclaim-count marker",
              ["bd", "label", "add", "ga-dead1", f"pilot:reclaim-count:escalated-at-{MAX_RECLAIMS}", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")

        # --- RF-14g (ga-egd5av): FALSIFIABLE end-to-end proof, per the bug's
        #     own AC3 ("remover gate:needs-human, disparar o mecanismo
        #     suspeito, e provar que o label NAO volta sem causa nova").
        #     Derives the post-escalation label set from do_escalate()'s OWN
        #     recorded mutations (never hand-typed — a literal would pass
        #     unchanged even if do_escalate regressed back to leaving the
        #     stale label in place, defeating the point of an integration
        #     test), then simulates a human clearing gate:needs-human (that
        #     label is simply excluded — do_escalate never removes it itself,
        #     only a human/Mayor does) and the bead stranding again with ZERO
        #     new reclaims in between — the exact wa-uknuq sequence. Before
        #     this fix, reclaim_decision would see the untouched
        #     pilot:reclaim-count:3 and return "escalate" again on pure
        #     replay; after the fix it must return "reclaim" — attempt 1 of a
        #     genuinely fresh budget, not a resurrection. ---
        _post_escalate_labels = set(_rf14_start_labels)
        for _m in _rf_mutations:
            if len(_m) == 6 and _m[0] == "bd" and _m[1] == "label" and _m[3] == "ga-dead1":
                if _m[2] == "add":
                    _post_escalate_labels.add(_m[4])
                elif _m[2] == "remove":
                    _post_escalate_labels.discard(_m[4])
        check("RF-14g-setup (ga-egd5av): derived post-escalation labels no longer carry the "
              "OLD numeric pilot:reclaim-count (proves the derivation isn't vacuous)",
              f"pilot:reclaim-count:{MAX_RECLAIMS}" not in _post_escalate_labels,
              f"labels={_post_escalate_labels!r}")
        _post_escalate_count = parse_reclaim_count(list(_post_escalate_labels))
        check("RF-14g (ga-egd5av): parse_reclaim_count reads 0 from the REAL post-escalation labels "
              "(gate:needs-human cleared by a human is now sufficient — no separate manual reset needed)",
              _post_escalate_count == 0, f"parsed={_post_escalate_count!r} labels={_post_escalate_labels!r}")
        _second_strand_decision = reclaim_decision(
            has_live_session=False, has_recent_branch=False, seconds_stranded=RECLAIM_TTL + 60,
            reclaim_count=_post_escalate_count, has_needs_human=False, has_dispatching_marker=False,
        )
        check("RF-14g (ga-egd5av) FALSIFIABLE: bead stranding again right after a human-granted fresh "
              "attempt reclaims (attempt 1 of a NEW budget) instead of instantly re-escalating on the "
              "stale cap — this is the exact wa-uknuq resurrection this fix closes",
              _second_strand_decision == "reclaim", f"decision={_second_strand_decision!r}")
    finally:
        subprocess.run = _orig_run_rf

    # -----------------------------------------------------------------------
    # Section 9c: ga-9d80l — refused-sling bridge (RS-*).
    #
    # ga-be4x's explicit-refusal awareness (Section 9b, above) only ever reads
    # a bead's OWN labels. For Pilot's standard HQ dispatch shape, the sling
    # wrapper bead ("fix bug <id>: ..." / "build story <id>: ...") is what a
    # refusing worker actually stamps pool:refused[:reason] on — never the
    # original bug/story. list_refused_sling_source_beads() bridges that
    # signal back onto the original so run_cycle's Pass 1 can build
    # effective_labels (labels + synthesized pool:refused:<slug> entries) and
    # feed it wherever plain labels used to flow. Stubs subprocess.run to
    # serve canned `bd list --status open/in_progress --json` responses; no
    # real bd calls. RS-1..7 test the bridge function in isolation (mirrors
    # Section 7's SL-1..7); RS-8 reproduces the actual ga-dp15j/ga-u5y7y
    # incident end-to-end, including the FALSIFY criterion from ga-9d80l's
    # own bug report.
    #
    # ga-9d80l GATE-FEEDBACK FIX (fix-attempt 2): fix-attempt 1's gate review
    # found that the bridge synthesized pool:refused:<slug> into the
    # ORIGINAL's in-memory effective_labels but never consumed the REAL
    # label at its source (the sling) — do_reclaim()/do_escalate() only ever
    # removed it from the original, a no-op since the original never
    # natively carried it in bd. A single stale sling's refusal therefore
    # re-bridged forever, including against a later, unrelated, healthy
    # re-dispatch (a false escalate). list_refused_sling_source_beads() now
    # returns {original_id: [(slug, sling_id, sling_rig_root), ...]} instead
    # of bare slugs, threaded through run_cycle's classified tuple into
    # do_reclaim/do_escalate/_promote_refusal_labels as `bridge_sources`, so
    # a bridged reason can be cleared at its actual source exactly when (and
    # only when) it is promoted. RS-1..8 below are updated for the new tuple
    # shape (same scenarios, same intent); RS-9..12 are new and cover the
    # gate-feedback fix specifically.
    #
    # ga-9d80l GATE-FEEDBACK FIX (fix-attempt 3): gate-fix-2's own gate
    # review found the tuple shape above was STILL lossy exactly where it
    # needed to be lossless: a bare 'pool:refused' source normalizes to slug
    # 'unspecified', and the source-side removal reconstructed a colon-form
    # "pool:refused:unspecified" string that the sling never actually
    # carried (its real label is bare), so that removal silently no-op'd.
    # Each entry now carries a 4th element, the sling's own RAW label text,
    # and _promote_refusal_labels() removes THAT instead of a reconstructed
    # string. RS-1..12 below are updated for the new 4-tuple shape (same
    # scenarios, same intent, mechanical update only); RS-13/14 are new and
    # cover the bare-refusal x consumption intersection specifically — the
    # exact untested gap gate-fix-2's reviewer identified as the shipping
    # cause.
    # -----------------------------------------------------------------------

    _orig_run_rs = subprocess.run

    def _stub_bd_refused(beads_by_status, list_fails=False, nonzero=False):
        """Build a subprocess.run stub for list_refused_sling_source_beads()'s
        `bd list --status open|in_progress --json` queries. The unmatched
        fallback (rc=0, empty stdout) also satisfies _list_rig_stores()'s own
        `gc rig list --json` probe — empty stdout reads as "no rigs", so the
        rig fan-out loop contributes nothing and every case below exercises
        the HQ-store query path only.

        beads_by_status: {"open": [...], "in_progress": [...]} — bead dicts
          (id/title/labels) to return for each status query.
        """
        class _R:
            def __init__(self, rc, out):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""

        def _run(cmd, **kw):
            if (isinstance(cmd, (list, tuple)) and len(cmd) >= 4
                    and cmd[0] == "bd" and cmd[1] == "list" and cmd[2] == "--status"):
                if nonzero:
                    return _R(1, "")
                if list_fails:
                    return _R(0, "{not valid json")
                status = cmd[3]
                return _R(0, json.dumps(beads_by_status.get(status, [])))
            return _R(0, "")  # e.g. 'gc rig list' → empty stdout → no rigs
        return _run

    def _bridged_slugs_of(entries):
        """Dedup (slug, sling_id, rig_root, raw_label) entries down to unique
        slugs, in first-seen order — exactly what run_cycle's Pass 1 does to
        build effective_labels from a bridge lookup. Shared here so RS-8's
        manual reproduction can't silently drift from the production dedup
        logic.
        """
        slugs = []
        for _slug, _sling_id, _sling_rig_root, _raw_lbl in entries:
            if _slug not in slugs:
                slugs.append(_slug)
        return slugs

    try:
        # --- RS-1: refused sling ('fix bug') resolves to its original id,
        # with the reason slug + sling id + rig_root (None=HQ) + raw label
        # text extracted ---
        subprocess.run = _stub_bd_refused({
            "in_progress": [
                {"id": "ga-u5y7y", "title": "fix bug ga-dp15j: Pilot dispatch ignores Mayor's deferral",
                 "labels": ["pool:refused:mayor-deferred"]},
            ],
        })
        _rs1 = list_refused_sling_source_beads()
        check("RS-1: refused sling ('fix bug') resolves to its original id with "
              "reason slug + sling id + rig_root + raw label text",
              _rs1 == {"ga-dp15j": [("mayor-deferred", "ga-u5y7y", None,
                                      "pool:refused:mayor-deferred")]}, f"got={_rs1!r}")

        # --- RS-2: non-refused sling → contributes nothing ---
        subprocess.run = _stub_bd_refused({
            "in_progress": [
                {"id": "ga-u5y7y", "title": "fix bug ga-dp15j: Pilot dispatch ignores Mayor's deferral",
                 "labels": ["story:in-flight"]},
            ],
        })
        _rs2 = list_refused_sling_source_beads()
        check("RS-2: non-refused sling → contributes nothing",
              _rs2 == {}, f"got={_rs2!r}")

        # --- RS-3: non-sling title never spuriously matches, even if refused ---
        subprocess.run = _stub_bd_refused({
            "in_progress": [
                {"id": "ga-plain1", "title": "run the weekly Dolt backup",
                 "labels": ["pool:refused:out-of-scope"]},
            ],
        })
        _rs3 = list_refused_sling_source_beads()
        check("RS-3: non-sling title (even if refused) → never spuriously matches",
              _rs3 == {}, f"got={_rs3!r}")

        # --- RS-4: 'build story' convention also resolves ---
        subprocess.run = _stub_bd_refused({
            "open": [
                {"id": "ga-slingC", "title": "build story ga-storyZ: Add the frobnicator widget",
                 "labels": ["pool:refused:cross-rig-framework"]},
            ],
        })
        _rs4 = list_refused_sling_source_beads()
        check("RS-4: sling 'build story' title → original story id resolved",
              _rs4 == {"ga-storyZ": [("cross-rig-framework", "ga-slingC", None,
                                       "pool:refused:cross-rig-framework")]}, f"got={_rs4!r}")

        # --- RS-5 (ga-vw26y): status=open ALSO bridges, not just in_progress —
        # a refused sling's status varies by how/when it was refused ---
        subprocess.run = _stub_bd_refused({
            "open": [
                {"id": "ga-slingD", "title": "fix bug ga-bugD: some other bug",
                 "labels": ["pool:refused"]},
            ],
            "in_progress": [],
        })
        _rs5 = list_refused_sling_source_beads()
        check("RS-5 (ga-vw26y): status=open sling also bridges (not just in_progress)",
              _rs5 == {"ga-bugD": [("unspecified", "ga-slingD", None, "pool:refused")]},
              f"got={_rs5!r}")

        # --- RS-6a: bd-list non-zero exit → fail-OPEN {} (never None — unlike
        # the sibling functions' fail-CLOSED/None contract) ---
        subprocess.run = _stub_bd_refused({}, nonzero=True)
        _rs6a = list_refused_sling_source_beads()
        check("RS-6a: bd-list non-zero exit → fail-OPEN {} (never None)",
              _rs6a == {}, f"got={_rs6a!r}")

        # --- RS-6b: bd-list unparseable JSON → fail-OPEN {} (never None) ---
        subprocess.run = _stub_bd_refused({}, list_fails=True)
        _rs6b = list_refused_sling_source_beads()
        check("RS-6b: bd-list unparseable JSON → fail-OPEN {} (never None)",
              _rs6b == {}, f"got={_rs6b!r}")

        # --- RS-7: bare 'pool:refused' (no reason) → 'unspecified' slug ---
        subprocess.run = _stub_bd_refused({
            "in_progress": [
                {"id": "ga-slingE", "title": "fix bug ga-bugE: some bug",
                 "labels": ["pool:refused"]},
            ],
        })
        _rs7 = list_refused_sling_source_beads()
        check("RS-7: bare 'pool:refused' (no reason) → 'unspecified' slug, raw "
              "label text preserved verbatim",
              _rs7 == {"ga-bugE": [("unspecified", "ga-slingE", None, "pool:refused")]},
              f"got={_rs7!r}")

        # --- RS-8: END-TO-END regression for the actual ga-dp15j/ga-u5y7y
        # incident shape (the FALSIFY criterion from ga-9d80l's own bug
        # report). ga-u5y7y (the sling) carries pool:refused:cross-rig-
        # framework; ga-dp15j (the original) carries NONE of pool:refused*/
        # pilot:refused-reason:*/pilot:refusal-count:* — exactly the
        # incident's confirmed live state. ---
        subprocess.run = _stub_bd_refused({
            "in_progress": [
                {"id": "ga-u5y7y", "title": "fix bug ga-dp15j: Pilot dispatch ignores Mayor's deferral",
                 "labels": ["pool:refused:cross-rig-framework"]},
            ],
        })
        _rs8_bridge = list_refused_sling_source_beads()
        check("RS-8a: bridge resolves the incident's sling refusal onto the original id",
              _rs8_bridge == {"ga-dp15j": [("cross-rig-framework", "ga-u5y7y", None,
                                             "pool:refused:cross-rig-framework")]},
              f"got={_rs8_bridge!r}")

        # ga-dp15j's OWN labels — confirmed live incident state: no refusal
        # marker of any kind, despite its sling having been explicitly refused.
        _rs8_own_labels = ["story:in-flight", "pilot:dispatched"]
        _rs8_pre_fix_has_refusal = _has_refusal_label(_rs8_own_labels)
        check("RS-8b: pre-fix signal — original bead's OWN labels never show the "
              "refusal (confirmed live: ga-dp15j never carried "
              "pool:refused*/pilot:refused-reason:*)",
              _rs8_pre_fix_has_refusal is False, f"got={_rs8_pre_fix_has_refusal!r}")
        _rs8_pre_fix_decision = _rd(
            has_explicit_refusal=_rs8_pre_fix_has_refusal, refusal_count=0,
            seconds_stranded=RECLAIM_TTL + 60, min_stranding_secs=RECLAIM_TTL,
            reclaim_count=1,
        )
        check("RS-8c: pre-fix — falls through to the GENERIC hysteresis path and "
              "reclaims blindly (no refusal awareness at all) — the exact loop "
              "ga-9d80l reports: up to MAX_RECLAIMS blind re-dispatches",
              _rs8_pre_fix_decision == "reclaim", f"got={_rs8_pre_fix_decision!r}")

        # Fix — bridge the sling's refusal onto ga-dp15j's effective_labels,
        # exactly as run_cycle's Pass 1 now does (dedup entries down to
        # unique slugs via the shared _bridged_slugs_of helper above).
        _rs8_bridge_entries = _rs8_bridge.get("ga-dp15j", [])
        _rs8_effective_labels = _rs8_own_labels + [
            f"pool:refused:{slug}" for slug in _bridged_slugs_of(_rs8_bridge_entries)
        ]
        _rs8_has_refusal = _has_refusal_label(_rs8_effective_labels)
        _rs8_refusal_count = parse_refusal_count(_rs8_effective_labels)
        check("RS-8d: fix — effective_labels now carries the bridged refusal",
              _rs8_has_refusal is True, f"got={_rs8_has_refusal!r}")
        _rs8_first_decision = _rd(
            has_explicit_refusal=_rs8_has_refusal, refusal_count=_rs8_refusal_count,
            reclaim_count=1,
        )
        check("RS-8e: fix — 1st bridged refusal → reclaim (refusal-aware, not yet "
              "at REFUSAL_ESCALATE_THRESHOLD) — do_reclaim's has_explicit_refusal=True "
              "path now promotes the audit trail that pre-fix was silently dropped",
              _rs8_first_decision == "reclaim", f"got={_rs8_first_decision!r}")

        # Simulate the 2ND independent refusal: a fresh re-dispatch's sling
        # (ga-newsl) is ALSO refused, and ga-dp15j's own labels now natively
        # carry pilot:refusal-count:1 (promoted by the 1st bridged reclaim's
        # do_reclaim, via the existing _promote_refusal_labels machinery).
        subprocess.run = _stub_bd_refused({
            "in_progress": [
                {"id": "ga-newsl", "title": "fix bug ga-dp15j: Pilot dispatch ignores Mayor's deferral",
                 "labels": ["pool:refused:cross-rig-framework"]},
            ],
        })
        _rs8_bridge2 = list_refused_sling_source_beads()
        _rs8_own_labels2 = ["story:in-flight", "pilot:dispatched", "pilot:refusal-count:1",
                             "pilot:refused-reason:cross-rig-framework"]
        _rs8_bridge2_entries = _rs8_bridge2.get("ga-dp15j", [])
        _rs8_effective_labels2 = _rs8_own_labels2 + [
            f"pool:refused:{slug}" for slug in _bridged_slugs_of(_rs8_bridge2_entries)
        ]
        _rs8_has_refusal2 = _has_refusal_label(_rs8_effective_labels2)
        _rs8_refusal_count2 = parse_refusal_count(_rs8_effective_labels2)
        _rs8_second_decision = _rd(
            has_explicit_refusal=_rs8_has_refusal2, refusal_count=_rs8_refusal_count2,
            reclaim_count=1,
        )
        check("RS-8f (FALSIFY): fix — 2nd independent bridged refusal escalates "
              "(REFUSAL_ESCALATE_THRESHOLD=2) instead of blind-reclaiming a 3rd "
              "time — the exact criterion ga-9d80l's own bug report asks to confirm",
              _rs8_second_decision == "escalate", f"got={_rs8_second_decision!r}")
    finally:
        subprocess.run = _orig_run_rs

    # -----------------------------------------------------------------------
    # RS-9..12 (ga-9d80l gate-fix-2): the sling-side consumption the fix-
    # attempt-1 gate review found missing. RS-9/10 exercise
    # _promote_refusal_labels()'s bridge_sources parameter directly (mutation
    # tracking, mirrors Section 9b's RF-12/13/14 style); RS-11 is the
    # regression guard proving a NATIVE (non-bridged) refusal never touches
    # any bead other than itself; RS-12 is the end-to-end FALSIFY for THIS
    # fix — reproduces the reviewer's exact false-escalate scenario and
    # proves it no longer happens once the source label is consumed.
    # -----------------------------------------------------------------------
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        _promote_refusal_labels(
            "ga-dp15j", ["pool:refused:cross-rig-framework"], 0,
            bridge_sources=[("cross-rig-framework", "ga-u5y7y", None,
                              "pool:refused:cross-rig-framework")],
        )
        check("RS-9a: _promote_refusal_labels still (no-op) attempts removal on the "
              "ORIGINAL bead (unchanged base behavior)",
              ["bd", "label", "remove", "ga-dp15j", "pool:refused:cross-rig-framework", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
        check("RS-9b (GATE-FEEDBACK FIX): _promote_refusal_labels ALSO clears the label "
              "AT ITS SOURCE — the sling bead ga-u5y7y — so it can never be re-bridged "
              "on a later cycle (fix-attempt-1's gate review finding)",
              ["bd", "label", "remove", "ga-u5y7y", "pool:refused:cross-rig-framework", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
        check("RS-9c: _promote_refusal_labels still promotes the permanent audit label "
              "on the original (unchanged base behavior)",
              ["bd", "label", "add", "ga-dp15j", "pilot:refused-reason:cross-rig-framework", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
    finally:
        subprocess.run = _orig_run_rs

    # --- RS-10: rig-store sling — the source removal must route through the
    # SLING's own rig_root (bd -C <rig_path>), independent of whatever store
    # the ORIGINAL bead itself lives in (here: HQ, rig_root=None for
    # bead_id's own removal at RS-10a) ---
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        _promote_refusal_labels(
            "ga-dp15j", ["pool:refused:mayor-deferred"], 0,
            bridge_sources=[("mayor-deferred", "wa-slingR", "/rigs/whatsapp_automation",
                              "pool:refused:mayor-deferred")],
        )
        check("RS-10a: original-bead removal still uses the ORIGINAL's own rig_root (HQ, plain bd)",
              ["bd", "label", "remove", "ga-dp15j", "pool:refused:mayor-deferred", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
        check("RS-10b: source removal routes through the SLING's own rig_root "
              "(bd -C /rigs/whatsapp_automation), not the original's store",
              ["bd", "-C", "/rigs/whatsapp_automation", "label", "remove", "wa-slingR",
               "pool:refused:mayor-deferred", "-q"] in _rf_mutations,
              f"mutations={_rf_mutations!r}")
    finally:
        subprocess.run = _orig_run_rs

    # --- RS-11 (regression guard): a NATIVE (non-bridged) refusal —
    # bridge_sources=None, the default every pre-existing caller (RF-12/13/14)
    # already uses — must NEVER attempt a removal against any bead other than
    # bead_id itself. Guards against the bridge machinery over-firing on a
    # refusal that was never bridged in the first place. ---
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        _promote_refusal_labels(
            "ga-solo1", ["pool:refused:out-of-scope"], 0,
        )
        _rs11_other_bead_removals = [
            m for m in _rf_mutations
            if len(m) >= 4 and m[0] == "bd" and m[1] == "label" and m[2] == "remove"
            and m[3] != "ga-solo1"
        ]
        check("RS-11: native (non-bridged) refusal touches ONLY bead_id — no "
              "cross-bead removal attempted without an explicit bridge_sources entry",
              _rs11_other_bead_removals == [], f"got={_rs11_other_bead_removals!r}")
    finally:
        subprocess.run = _orig_run_rs

    # --- RS-12 (FALSIFY, gate-fix-2): end-to-end reproduction of the exact
    # false-escalate the gate review described — proven FIXED. Cycle N: the
    # stale sling ga-u5y7y is bridged and do_reclaim() promotes+consumes it.
    # Cycle N+1: a FRESH, otherwise-healthy re-dispatch's session isn't
    # visible yet (the wa-og36j race — has_live_session=False, seconds_
    # stranded still small). Pre-fix, ga-u5y7y's label was never cleared, so
    # it re-bridges every cycle forever and the fresh dispatch is escalated
    # within seconds despite being perfectly healthy. Post-fix, the source
    # was already consumed at cycle N, so cycle N+1's bridge query finds
    # nothing for ga-dp15j and the fresh dispatch is correctly left alone. ---
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        do_reclaim(
            "ga-dp15j", "Pilot dispatch ignores Mayor's deferral", reclaim_count=0, idle_min=26.0,
            # effective_labels as run_cycle's Pass 1 would actually build it: own
            # labels + the synthetic pool:refused:<slug> bridged in from ga-u5y7y.
            labels=["story:in-flight", "pilot:dispatched", "pool:refused:cross-rig-framework"],
            has_explicit_refusal=True, refusal_count=0,
            bridge_sources=[("cross-rig-framework", "ga-u5y7y", None,
                              "pool:refused:cross-rig-framework")],
        )
        check("RS-12a: cycle N — do_reclaim (threaded bridge_sources end-to-end, not just "
              "the internal helper) clears the source label on the sling",
              ["bd", "label", "remove", "ga-u5y7y", "pool:refused:cross-rig-framework", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
    finally:
        subprocess.run = _orig_run_rs

    # Cycle N+1: ga-u5y7y's label is now cleared (proven above) — simulate
    # that live state (no pool:refused* on ga-u5y7y at all) plus a brand new,
    # healthy, unrefused sling for the fresh re-dispatch.
    subprocess.run = _stub_bd_refused({
        "in_progress": [
            {"id": "ga-u5y7y", "title": "fix bug ga-dp15j: Pilot dispatch ignores Mayor's deferral",
             "labels": ["story:in-flight"]},  # cleared: no refusal label survives
            {"id": "ga-freshdispatch", "title": "fix bug ga-dp15j: Pilot dispatch ignores Mayor's deferral",
             "labels": ["story:in-flight", "pilot:dispatched"]},  # fresh, healthy, NOT refused
        ],
    })
    try:
        _rs12_bridge_n1 = list_refused_sling_source_beads()
    finally:
        subprocess.run = _orig_run_rs
    check("RS-12b (FALSIFY): cycle N+1 — with the source consumed, the bridge query "
          "finds NOTHING for ga-dp15j (the cleared sling no longer qualifies, the "
          "fresh sling was never refused)",
          _rs12_bridge_n1.get("ga-dp15j", []) == [], f"got={_rs12_bridge_n1!r}")

    # ga-dp15j's own labels after cycle N's promotion: native audit trail
    # present, but no pool:refused* of its own (never had one natively).
    _rs12_own_labels = ["story:in-flight", "pilot:dispatched", "pilot:refusal-count:1",
                         "pilot:refused-reason:cross-rig-framework"]
    _rs12_bridge_entries_n1 = _rs12_bridge_n1.get("ga-dp15j", [])
    _rs12_effective_labels = _rs12_own_labels + [
        f"pool:refused:{slug}" for slug in _bridged_slugs_of(_rs12_bridge_entries_n1)
    ]
    _rs12_has_refusal = _has_refusal_label(_rs12_effective_labels)
    check("RS-12c (FALSIFY): cycle N+1 — effective_labels carries NO fresh refusal "
          "signal (the stale sling can no longer contribute one)",
          _rs12_has_refusal is False, f"got={_rs12_has_refusal!r}")
    _rs12_refusal_count = parse_refusal_count(_rs12_effective_labels)
    _rs12_decision = _rd(
        has_explicit_refusal=_rs12_has_refusal, refusal_count=_rs12_refusal_count,
        has_live_session=False,  # wa-og36j race: fresh dispatch's session not visible yet
        seconds_stranded=60.0,   # barely stranded — nowhere near any hysteresis window
        min_stranding_secs=RECLAIM_TTL, reclaim_count=0,
    )
    check("RS-12d (FALSIFY, GATE-FEEDBACK regression anchor): the fresh, healthy "
          "re-dispatch is left alone (noop) — NOT escalated. Pre-fix, ga-u5y7y's "
          "uncleared label would have re-bridged here (has_explicit_refusal=True, "
          "refusal_count=1 >= REFUSAL_ESCALATE_THRESHOLD-1) and escalated a dispatch "
          "barely 60s old, before its builder's session was even visible",
          _rs12_decision == "noop", f"got={_rs12_decision!r}")

    # -----------------------------------------------------------------------
    # RS-13/14 (ga-9d80l gate-fix-3): bare-refusal source consumption. The
    # gate-fix-2 gate review found that a bridged BARE 'pool:refused' (no
    # reason) source label was never actually cleared: Pass 1 always
    # synthesizes the bridged slug back into effective_labels in COLON form
    # (f"pool:refused:{slug}" -> "pool:refused:unspecified" for a bare
    # source), and gate-fix-2's consumption loop reused THAT synthesized
    # text for the sling-side removal call instead of the sling's actual raw
    # label text. "pool:refused:unspecified" != "pool:refused" (bd label
    # remove matches exact text, no fuzzy/prefix matching), so the removal
    # silently no-op'd and the sling's bare label survived forever —
    # re-bridging (and re-promoting) on every later cycle, including against
    # a later, unrelated, healthy re-dispatch. RS-9..12 all used reasoned
    # slugs only — the bare/"unspecified" x consumption intersection was
    # untested, which is why the mismatch shipped. RS-13 is the direct unit
    # test (mirrors RS-9's style); RS-14 is the end-to-end FALSIFY (mirrors
    # RS-12's two-cycle reproduction) for this specific shape.
    # -----------------------------------------------------------------------
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        _promote_refusal_labels(
            "ga-dp15j", ["pool:refused:unspecified"], 0,
            bridge_sources=[("unspecified", "ga-slingBare", None, "pool:refused")],
        )
        check("RS-13a: bridged BARE refusal — original-bead removal still uses the "
              "synthesized colon-form text (unchanged base behavior; a no-op against "
              "live bd since the original never natively carries this label, but the "
              "call itself is unaffected by this fix)",
              ["bd", "label", "remove", "ga-dp15j", "pool:refused:unspecified", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
        check("RS-13b (GATE-FEEDBACK FIX, gate-fix-3): source removal uses the "
              "sling's own RAW label text ('pool:refused', bare) — not the "
              "reconstructed colon-form 'pool:refused:unspecified', which the sling "
              "never actually carried and which gate-fix-2 mistakenly sent",
              ["bd", "label", "remove", "ga-slingBare", "pool:refused", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
        check("RS-13c (FALSIFY, gate-fix-2 regression anchor): the WRONG (reconstructed "
              "colon-form) text is never sent to the sling — proves the fix sends the "
              "CORRECT text instead of ALSO sending an incorrect one",
              ["bd", "label", "remove", "ga-slingBare", "pool:refused:unspecified", "-q"]
              not in _rf_mutations, f"mutations={_rf_mutations!r}")
    finally:
        subprocess.run = _orig_run_rs

    # --- RS-14 (FALSIFY, gate-fix-3): end-to-end reproduction of the bare-
    # refusal false-escalate, mirroring RS-12 exactly but for the untested
    # bare/"unspecified" shape. Cycle N: sling ga-slingBare2 carries bare
    # 'pool:refused' (no reason); do_reclaim() promotes it onto ga-bugBare2
    # and must consume it AT THE SLING using the sling's raw bare text.
    # Cycle N+1: a fresh, otherwise-healthy re-dispatch's sling
    # (ga-freshbare) is unrefused; pre-gate-fix-3 the stale bare label would
    # have survived (wrong-text removal), re-bridged, and escalated the
    # fresh dispatch within seconds; post-fix it's correctly left alone. ---
    _rf_mutations.clear()
    subprocess.run = _stub_run_rf
    try:
        do_reclaim(
            "ga-bugBare2", "Some other bug with a bare refusal", reclaim_count=0, idle_min=26.0,
            labels=["story:in-flight", "pilot:dispatched", "pool:refused:unspecified"],
            has_explicit_refusal=True, refusal_count=0,
            bridge_sources=[("unspecified", "ga-slingBare2", None, "pool:refused")],
        )
        check("RS-14a: cycle N — do_reclaim clears the BARE source label on the sling "
              "using its raw text, not a reconstructed colon form",
              ["bd", "label", "remove", "ga-slingBare2", "pool:refused", "-q"]
              in _rf_mutations, f"mutations={_rf_mutations!r}")
    finally:
        subprocess.run = _orig_run_rs

    subprocess.run = _stub_bd_refused({
        "in_progress": [
            {"id": "ga-slingBare2", "title": "fix bug ga-bugBare2: Some other bug with a bare refusal",
             "labels": ["story:in-flight"]},  # cleared: bare label consumed at its source
            {"id": "ga-freshbare", "title": "fix bug ga-bugBare2: Some other bug with a bare refusal",
             "labels": ["story:in-flight", "pilot:dispatched"]},  # fresh, healthy, NOT refused
        ],
    })
    try:
        _rs14_bridge_n1 = list_refused_sling_source_beads()
    finally:
        subprocess.run = _orig_run_rs
    check("RS-14b (FALSIFY): cycle N+1 — with the bare source consumed, the bridge "
          "query finds NOTHING for ga-bugBare2",
          _rs14_bridge_n1.get("ga-bugBare2", []) == [], f"got={_rs14_bridge_n1!r}")

    _rs14_own_labels = ["story:in-flight", "pilot:dispatched", "pilot:refusal-count:1",
                         "pilot:refused-reason:unspecified"]
    _rs14_bridge_entries_n1 = _rs14_bridge_n1.get("ga-bugBare2", [])
    _rs14_effective_labels = _rs14_own_labels + [
        f"pool:refused:{slug}" for slug in _bridged_slugs_of(_rs14_bridge_entries_n1)
    ]
    _rs14_has_refusal = _has_refusal_label(_rs14_effective_labels)
    check("RS-14c (FALSIFY): cycle N+1 — effective_labels carries NO fresh refusal "
          "signal (the stale bare sling can no longer contribute one)",
          _rs14_has_refusal is False, f"got={_rs14_has_refusal!r}")
    _rs14_refusal_count = parse_refusal_count(_rs14_effective_labels)
    _rs14_decision = _rd(
        has_explicit_refusal=_rs14_has_refusal, refusal_count=_rs14_refusal_count,
        has_live_session=False, seconds_stranded=60.0,
        min_stranding_secs=RECLAIM_TTL, reclaim_count=0,
    )
    check("RS-14d (FALSIFY, gate-fix-3 regression anchor): the fresh, healthy "
          "re-dispatch is left alone (noop) — NOT escalated off a stale bare refusal "
          "that gate-fix-2 failed to actually clear at its source",
          _rs14_decision == "noop", f"got={_rs14_decision!r}")

    # -----------------------------------------------------------------------
    # Section 10: gt-fppb0 — claimant_provably_dead() classifier (CPD-*).
    # STRICTLY STRONGER than "not live": provably dead only when the claimant is
    # absent, or every match is in _POOL_DEAD_STATES. A live-but-quiet (stale)
    # session, an unknown-state session, an empty session list, and a coordinator
    # assignee are all NOT provably dead. Pure function — no bd/gc/git.
    # -----------------------------------------------------------------------
    T_cpd = 1_782_700_000.0
    _cpd_fresh = _irg_datetime.datetime.fromtimestamp(
        T_cpd - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _cpd_stale = _irg_datetime.datetime.fromtimestamp(
        T_cpd - (STALE_ACTIVITY_TTL + 600), tz=_irg_datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    _other_live = {"id": "ga-nav3", "name": "oracle-wa", "session_name": "oracle-wa-x",
                   "alias": "oracle-wa", "agent_name": "oracle-wa",
                   "template": "oracle-wa", "state": "active", "last_active": _cpd_fresh}
    _dog_active = {"id": "d1", "name": "gastown.dog-2", "session_name": "dog-ga5e06",
                   "alias": "gastown.dog-2", "agent_name": "dog-ga5e06",
                   "template": "gastown.dog", "state": "active", "last_active": _cpd_fresh}
    _dog_asleep = {"id": "d2", "name": "gastown.dog-3", "session_name": "dog-gaXXXX",
                   "alias": "gastown.dog-3", "agent_name": "dog-gaXXXX",
                   "template": "gastown.dog", "state": "asleep", "last_active": _cpd_stale}
    _dog_unknown = dict(_dog_active); _dog_unknown["state"] = "booting"
    _dog_frozen = dict(_dog_active); _dog_frozen["last_active"] = _cpd_stale  # active but stale

    check("CPD-1: 'gastown.dog' absent from a non-empty session list → True (gone)",
          claimant_provably_dead("gastown.dog", [_other_live]) is True)
    check("CPD-2: live fresh dog present (template match) → False (not provably dead)",
          claimant_provably_dead("gastown.dog", [_dog_active]) is False)
    check("CPD-3: only dead-state dog (asleep, template match) → True (provably dead)",
          claimant_provably_dead("gastown.dog", [_dog_asleep]) is True)
    check("CPD-4: unknown-state dog (booting) → False (ambiguous, never fast-path)",
          claimant_provably_dead("gastown.dog", [_dog_unknown]) is False)
    check("CPD-5: active-but-STALE dog (frozen/quiet, ga-64usm) → False (keeps hysteresis)",
          claimant_provably_dead("gastown.dog", [_dog_frozen]) is False)
    check("CPD-6: empty session list → False (unknown, cannot prove death — fail-safe)",
          claimant_provably_dead("gastown.dog", []) is False)
    check("CPD-7: coordinator assignee (gastown.mayor) → False (parked, other rail)",
          claimant_provably_dead("gastown.mayor", [_other_live]) is False)
    check("CPD-8: concrete dead match (wa-worker-adhoc-x, closed) → True",
          claimant_provably_dead("wa-worker-adhoc-x", [
              {"id": "s", "name": "n", "session_name": "wa-worker-adhoc-x",
               "alias": "", "agent_name": "wa-worker-adhoc-x", "template": "wa-worker",
               "state": "closed", "last_active": _cpd_stale}]) is True)
    check("CPD-9: empty assignee → False",
          claimant_provably_dead("", [_other_live]) is False)
    check("CPD-10: one live dog + one dead dog → False (any live match wins)",
          claimant_provably_dead("gastown.dog", [_dog_asleep, _dog_active]) is False)

    # -----------------------------------------------------------------------
    # Section 11: gt-fppb0 — reclaim_dead_dog_claims() end-to-end (DD-*).
    # The falsifiable "reclaimed within 1 hook cycle, not re-offered to N
    # workers" test. Stubs subprocess.run to serve the full call graph
    # (bd list/show, gc session/agent/rig list, git, quota-check) and CAPTURES
    # bd mutations, so a real reclaim is provable by its bd assign/update calls.
    # time.time is frozen so get_branch_recent + do_reclaim are deterministic.
    # -----------------------------------------------------------------------
    T_dd = 1_782_800_000.0
    _dd_fresh = _irg_datetime.datetime.fromtimestamp(
        T_dd - 60, tz=_irg_datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _dd_other = {"id": "ga-nav3", "name": "oracle-wa", "session_name": "oracle-wa-x",
                 "alias": "oracle-wa", "agent_name": "oracle-wa",
                 "template": "oracle-wa", "state": "active", "last_active": _dd_fresh}
    # A live dog whose identifier matches a sling assignee but NOT template — so
    # only the sling rail (not pool_has_live_worker) can protect via it.
    _dd_sling_dog = {"id": "d9", "name": "gastown.dog-2", "session_name": "dog-ga5e06",
                     "alias": "gastown.dog-2", "agent_name": "dog-ga5e06",
                     "template": "", "state": "active", "last_active": _dd_fresh}

    def _make_dd_stub(dog_beads, sessions, inprogress=None, markers=None,
                      titles=None, agents=None, refs=None, quota_rc=0,
                      sessions_fail=False, never_confirm_removal=False):
        inprogress = inprogress if inprogress is not None else []
        markers = markers or {}
        titles = titles or {}
        agents = agents or []
        refs = refs or []
        mutations = []
        calls = []
        # ga-jzye0 fix-attempt-2: seeded from dog_beads' own "labels" so `bd
        # show` read-backs (_remove_label_verified) reflect a real bead shape
        # and can actually confirm a removal. Pre-fix this stub's `show`
        # response never carried a "labels" key at all, so after the
        # self-audit commit (042a08ea4) tightened the shape check, EVERY
        # removal looked unconfirmable and do_reclaim() aborted before ever
        # reaching the assign/status mutations DD-1b/DD-1c check for.
        # never_confirm_removal=True keeps the old (label-less) shape on
        # purpose, to simulate a genuine Dolt hiccup (DD-11).
        labels_state = {b["id"]: set(b.get("labels", [])) for b in dog_beads if b.get("id")}

        class _R:
            def __init__(self, rc=0, out=""):
                self.returncode = rc
                self.stdout = out
                self.stderr = ""

        def _run(cmd, **kw):
            if not isinstance(cmd, (list, tuple)):
                return _R(0, "")
            calls.append(list(cmd))
            if cmd and cmd[0] == QUOTA_CHECK:
                return _R(quota_rc, "")
            if cmd[0] == "gc":
                if len(cmd) >= 3 and cmd[1] == "session" and cmd[2] == "list":
                    if sessions_fail:
                        return _R(1, "")
                    return _R(0, json.dumps({"sessions": sessions}))
                if len(cmd) >= 3 and cmd[1] == "agent" and cmd[2] == "list":
                    return _R(0, json.dumps({"agents": agents}))
                if len(cmd) >= 3 and cmd[1] == "rig" and cmd[2] == "list":
                    return _R(0, json.dumps({"rigs": []}))
                return _R(0, "")
            if cmd[0] == "git":
                if "for-each-ref" in cmd:
                    return _R(0, ("\n".join(refs) + "\n") if refs else "")
                return _R(0, "")
            if cmd[0] == "bd":
                args = list(cmd[1:])
                if len(args) >= 2 and args[0] == "-C":
                    args = args[2:]
                sub = args[0] if args else ""
                if sub == "list":
                    if "--assignee" in args:                       # dog Tier-1 query
                        return _R(0, json.dumps(dog_beads))
                    if "type:quality-gate-marker" in args:         # gate-marker query
                        labs = [args[i + 1] for i, a in enumerate(args)
                                if a == "--label" and i + 1 < len(args)]
                        gate_lbl = labs[1] if len(labs) > 1 else (labs[0] if labs else "")
                        payload = [{"id": f"marker-{i}", "labels": lbls}
                                   for i, lbls in enumerate(markers.get(gate_lbl, []))]
                        return _R(0, json.dumps(payload))
                    if "in_progress" in args:                      # sling in_progress query
                        return _R(0, json.dumps(inprogress))
                    return _R(0, "[]")
                if sub == "show":
                    ids = [a for a in args[1:] if a != "--json"]
                    if never_confirm_removal:
                        return _R(0, json.dumps(
                            [{"id": i, "title": titles.get(i, "")} for i in ids]))
                    return _R(0, json.dumps([
                        {"id": i, "title": titles.get(i, ""),
                         "labels": sorted(labels_state.get(i, set()))}
                        for i in ids
                    ]))
                if sub in ("label", "assign", "update", "comment"):
                    mutations.append(list(cmd))
                    if sub == "label" and len(args) >= 4 and args[1] in ("add", "remove"):
                        bead_id, lbl = args[2], args[3]
                        cur = labels_state.setdefault(bead_id, set())
                        (cur.discard if args[1] == "remove" else cur.add)(lbl)
                    return _R(0, "")
                return _R(0, "")
            return _R(0, "")
        return _run, mutations, calls

    def _mut_has(muts, *needle):
        needle = list(needle)
        return any(needle == [a for a in m if a not in ("-C",)][:len(needle)]
                   or needle == m[-len(needle):] for m in muts)

    _orig_run_dd = subprocess.run
    _orig_time_dd = time.time
    try:
        time.time = lambda: T_dd

        _X = {"id": "ga-zomb1", "title": "chronic Dolt handle refactor",
              "assignee": "gastown.dog", "labels": ["story:in-flight"],
              "updated_at": _dd_fresh}

        # DD-1: DEAD claimant → reclaim within one preflight, mutations prove it.
        subprocess.run, muts, calls = _make_dd_stub([_X], [_dd_other], inprogress=[_X])
        _r1 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-1: provably-dead dog claim → reclaimed in ONE preflight (was re-offered pre-fix)",
              _r1 == ["ga-zomb1"], f"got={_r1!r}")
        check("DD-1b: reclaim cleared the dog assignee (bd assign ga-zomb1 '')",
              any(m[:2] == ["bd", "assign"] and "ga-zomb1" in m for m in muts),
              f"muts={muts!r}")
        check("DD-1c: reclaim reset status to open (bd update ga-zomb1 --status open)",
              any(m[:2] == ["bd", "update"] and "ga-zomb1" in m and "open" in m for m in muts),
              f"muts={muts!r}")

        # DD-2: live SLING owner → protected (noop), even though the classifier
        # would call the bare 'gastown.dog' claimant absent (has_live_session wins).
        _sling = {"id": "ga-sling1", "title": "fix bug ga-zomb1: chronic Dolt handle",
                  "assignee": "dog-ga5e06", "labels": [], "updated_at": _dd_fresh}
        subprocess.run, muts, calls = _make_dd_stub(
            [_X], [_dd_sling_dog], inprogress=[_X, _sling])
        _r2 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-2: live sling source (ga-qfo3) protects the original → noop",
              _r2 == [] and muts == [], f"got={_r2!r} muts={muts!r}")

        # DD-3: gate:needs-human → parked → noop even though provably dead.
        _Xnh = dict(_X); _Xnh["labels"] = ["story:in-flight", "gate:needs-human"]
        subprocess.run, muts, calls = _make_dd_stub([_Xnh], [_dd_other], inprogress=[_Xnh])
        _r3 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-3: gate:needs-human guard → noop (provably dead but parked)",
              _r3 == [] and muts == [], f"got={_r3!r} muts={muts!r}")

        # DD-4: active quality-gate marker on the bead → noop.
        subprocess.run, muts, calls = _make_dd_stub(
            [_X], [_dd_other], inprogress=[_X],
            markers={"gate-status:queued": [["source-bead:ga-zomb1", "type:quality-gate-marker"]]},
            titles={"ga-zomb1": "chronic Dolt handle refactor"})
        _r4 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-4: active gate marker guard → noop",
              _r4 == [] and muts == [], f"got={_r4!r} muts={muts!r}")

        # DD-5: account rate-limited (quota exit 2) → defer → noop.
        subprocess.run, muts, calls = _make_dd_stub([_X], [_dd_other], inprogress=[_X], quota_rc=2)
        _r5 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-5: account rate-limited (ga-ufr7) → noop (deferred)",
              _r5 == [] and muts == [], f"got={_r5!r} muts={muts!r}")

        # DD-6: deliberately-suspended owner HOLD → noop.
        subprocess.run, muts, calls = _make_dd_stub(
            [_X], [_dd_other], inprogress=[_X],
            agents=[{"name": "gastown.dog", "suspended": True}])
        _r6 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-6: suspended-owner HOLD → noop (waits for resume, never re-pooled)",
              _r6 == [] and muts == [], f"got={_r6!r} muts={muts!r}")

        # DD-7: session probe fails → fail-safe → noop (do nothing, never block).
        subprocess.run, muts, calls = _make_dd_stub([_X], [], inprogress=[_X], sessions_fail=True)
        _r7 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-7: gc session list fails → fail-safe noop (no reclaim on unknown liveness)",
              _r7 == [] and muts == [], f"got={_r7!r} muts={muts!r}")

        # DD-8: no candidate dog beads → fast healthy path, no session fetch at all.
        subprocess.run, muts, calls = _make_dd_stub([], [_dd_other])
        _r8 = reclaim_dead_dog_claims(now=T_dd)
        _fetched_sessions = any(c[:3] == ["gc", "session", "list"] for c in calls)
        check("DD-8: no dog candidates → noop AND no gc session list call (fast healthy path)",
              _r8 == [] and muts == [] and not _fetched_sessions,
              f"got={_r8!r} calls={calls!r}")

        # DD-9: recent branch progress → noop (branch rail, fetch=False path).
        subprocess.run, muts, calls = _make_dd_stub(
            [_X], [_dd_other], inprogress=[_X],
            refs=[f"refs/remotes/origin/crew/gastown.dog/ga-zomb1 {int(T_dd - 60)}"])
        _r9 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-9: recent crew/gastown.dog/<id> branch → noop (branch rail holds)",
              _r9 == [] and muts == [], f"got={_r9!r} muts={muts!r}")
        _no_fetch = not any(c[:1] == ["git"] and "fetch" in c for c in calls)
        check("DD-9b: preflight branch check did NOT run git fetch (fast, fetch=False)",
              _no_fetch, f"calls={[c for c in calls if c[:1]==['git']]!r}")

        # DD-10: dry_run → reports the reclaim but performs NO bd mutation.
        subprocess.run, muts, calls = _make_dd_stub([_X], [_dd_other], inprogress=[_X])
        _r10 = reclaim_dead_dog_claims(now=T_dd, dry_run=True)
        check("DD-10: dry_run → identifies zombie but performs no bd mutation",
              _r10 == ["ga-zomb1"] and muts == [], f"got={_r10!r} muts={muts!r}")

        # DD-11 (GATE-FEEDBACK regression anchor, gate_run=ga-dr98s, fix-attempt-2):
        # when do_reclaim() cannot confirm label removal (Dolt hiccup — the exact
        # condition fix-attempt-1 targets), it returns False and touches NOTHING
        # (assignee/status untouched). Pre-fix-attempt-2, this caller ignored that
        # return value and still reported success — reclaimed=[bead_id] plus a
        # "[DOG-PREFLIGHT]...reclaimed..." log line — even though the bead was
        # left completely untouched. The fresh dog's own Tier-1 query (bd list
        # --status in_progress --assignee gastown.dog) would then re-adopt the
        # SAME zombie next cycle: the exact NEVERSTART respawn loop this
        # preflight exists to prevent, reintroduced under its own trigger
        # condition. Fixed by mirroring run_cycle's audited "ok = do_reclaim(...)"
        # pattern instead of discarding the return value.
        subprocess.run, muts, calls = _make_dd_stub(
            [_X], [_dd_other], inprogress=[_X], never_confirm_removal=True)
        _r11 = reclaim_dead_dog_claims(now=T_dd)
        check("DD-11a (GATE-FEEDBACK): unconfirmable label removal → NOT reported "
              "as reclaimed (reclaimed list stays accurate, was ['ga-zomb1'] pre-fix)",
              _r11 == [], f"got={_r11!r}")
        check("DD-11b (GATE-FEEDBACK): unconfirmable label removal → NO assign/update "
              "mutation — bead left exactly as found, never half-done",
              not any(m[:2] in (["bd", "assign"], ["bd", "update"]) for m in muts),
              f"muts={muts!r}")
    finally:
        subprocess.run = _orig_run_dd
        time.time = _orig_time_dd

    # -----------------------------------------------------------------------
    # Section: ga-nlaa — session_awaiting_human_input() + the
    # awaiting_human_input param on session_owner_is_healthy(). A session
    # paused at an AskUserQuestion prompt produces the SAME telemetry (stale
    # last_active, no bd update) as a frozen/credit-limited zombie (ga-64usm)
    # — these checks give the guard an independent-of-commit-cadence signal
    # to tell the two apart. No real bd/gc/git calls (subprocess.run stubbed).
    # -----------------------------------------------------------------------

    T_ah = 1_782_800_000.0  # fixed epoch for determinism
    _ah_stale_ts = _irg_datetime.datetime.fromtimestamp(
        T_ah - STALE_ACTIVITY_TTL - 600, tz=_irg_datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")  # 40min ago: stale on both ga-64usm signals
    _ah_fresh_ts = _irg_datetime.datetime.fromtimestamp(
        T_ah - 60, tz=_irg_datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")

    # --- AH-1/1b: session_owner_is_healthy() — pure predicate contract ---
    check("AH-1: session_owner_is_healthy: stale activity+bead, awaiting_human_input=True → healthy",
          session_owner_is_healthy(True, STALE_ACTIVITY_TTL + 600, None,
                                    awaiting_human_input=True) is True)
    check("AH-1b: session_owner_is_healthy: identical staleness, awaiting_human_input omitted "
          "(pre-fix default) → zombie — the contrast AH-7-MUT relies on below",
          session_owner_is_healthy(True, STALE_ACTIVITY_TTL + 600, None) is False)

    # --- AH-2..6: session_awaiting_human_input() — direct I/O-probe contract ---
    _orig_run_ah = subprocess.run

    def _stub_peek(output_text="", rc=0, raise_exc=False, expect_ref=None):
        def _run(cmd, **kw):
            if raise_exc:
                raise TimeoutError("simulated peek timeout")
            assert cmd[:3] == ["gc", "session", "peek"], f"unexpected cmd: {cmd}"
            if expect_ref is not None:
                assert cmd[3] == expect_ref, f"peeked wrong session: {cmd[3]!r} != {expect_ref!r}"
            if rc != 0:
                return _FakeGitResult(rc, "", "peek failed")
            return _FakeGitResult(0, json.dumps({"ok": True, "output": output_text}))
        return _run

    try:
        subprocess.run = _stub_peek(output_text="⏺ AskUserQuestion(Which zoning class applies?)\n❯ 1. ...")
        check("AH-2: session_awaiting_human_input: peek shows AskUserQuestion → True",
              session_awaiting_human_input("thies") is True)

        subprocess.run = _stub_peek(output_text="⏺ Bash(pytest -q)\n  ⎿  3 passed\n❯ ")
        check("AH-3: session_awaiting_human_input: peek shows ordinary output (no prompt) → False",
              session_awaiting_human_input("thies") is False)

        subprocess.run = _stub_peek(rc=1)
        check("AH-4: session_awaiting_human_input: peek non-zero exit → False (fail-safe)",
              session_awaiting_human_input("thies") is False)

        subprocess.run = _stub_peek(raise_exc=True)
        check("AH-5: session_awaiting_human_input: peek raises/times out → False (fail-safe)",
              session_awaiting_human_input("thies") is False)

        subprocess.run = _stub_peek(output_text="whatever")
        check("AH-6: session_awaiting_human_input: empty ref → False (no call attempted)",
              session_awaiting_human_input("") is False)
    finally:
        subprocess.run = _orig_run_ah

    # --- AH-7/8: session_is_live() end-to-end — the actual wa-y39v2 shape ---
    _ah_live_paused = [
        {"id": "sid-thies", "name": "thies-wa", "session_name": "thies",
         "alias": "thies", "agent_name": "thies-wa",
         "state": "active", "last_active": _ah_stale_ts},
    ]
    try:
        # AH-7: live session, stale on both signals, peek shows AskUserQuestion.
        subprocess.run = _stub_peek(output_text="⏺ AskUserQuestion(zoning?)", expect_ref="thies")
        check("AH-7: session_is_live: stale+paused-on-AskUserQuestion → True (ga-nlaa: NOT false-reclaimed)",
              session_is_live("thies", _ah_live_paused, now=T_ah) is True)

        # AH-7-MUT (mutation-test, ga-nlaa acceptance criterion 3): identical
        # scenario to AH-7, but the peek probe now reports "nothing to see" —
        # simulating the awaiting-human check being removed/disabled. AH-7
        # must flip to False; if it doesn't, the fix isn't actually
        # load-bearing for the wa-y39v2 scenario it was written to close.
        subprocess.run = _stub_peek(output_text="", expect_ref="thies")
        check("AH-7-MUT: same scenario with the peek check reporting nothing → reverts to False "
              "(removing/disabling the check flips AH-7 red, as required)",
              session_is_live("thies", _ah_live_paused, now=T_ah) is False)

        # AH-8: stale on both signals, peek shows ordinary output → still a
        # frozen/credit-limited zombie (ga-64usm) — NOT protected. No regression.
        subprocess.run = _stub_peek(output_text="⏺ Bash(sleep 1)\n❯ ", expect_ref="thies")
        check("AH-8: session_is_live: stale+genuinely-frozen (no AskUserQuestion) → False (ga-64usm preserved)",
              session_is_live("thies", _ah_live_paused, now=T_ah) is False)
    finally:
        subprocess.run = _orig_run_ah

    # AH-9: no matching session at all (tmux gone) → False, and peek is never
    # attempted — ga-nlaa acceptance criterion 2: truly-dead claimants must
    # still be reclaimable.
    _ah_peek_calls = []

    def _stub_peek_counting(cmd, **kw):
        _ah_peek_calls.append(list(cmd))
        return _FakeGitResult(0, json.dumps({"ok": True, "output": ""}))

    subprocess.run = _stub_peek_counting
    try:
        check("AH-9: session_is_live: no matching session at all → False (still reclaimable; ga-nlaa AC2)",
              session_is_live("thies", [], now=T_ah) is False)
        check("AH-9b: ...and no peek call was made for a bead with no matching session",
              _ah_peek_calls == [], f"calls={_ah_peek_calls!r}")
    finally:
        subprocess.run = _orig_run_ah

    # AH-10: FRESH last_active never reaches the peek probe at all — the cheap
    # activity check alone already proves health, so peek (comparatively
    # expensive) must stay off the hot path.
    _ah_live_fresh = [
        {"id": "sid-thies2", "name": "thies-wa", "session_name": "thies",
         "alias": "thies", "agent_name": "thies-wa",
         "state": "active", "last_active": _ah_fresh_ts},
    ]
    _ah_peek_calls2 = []

    def _stub_peek_counting2(cmd, **kw):
        _ah_peek_calls2.append(list(cmd))
        return _FakeGitResult(0, json.dumps({"ok": True, "output": ""}))

    subprocess.run = _stub_peek_counting2
    try:
        check("AH-10: session_is_live: fresh activity → True via the cheap rail alone",
              session_is_live("thies", _ah_live_fresh, now=T_ah) is True)
        check("AH-10b: ...and peek was never called (stays off the hot path)",
              _ah_peek_calls2 == [], f"calls={_ah_peek_calls2!r}")
    finally:
        subprocess.run = _orig_run_ah

    # --- AH-11/12: pool_has_live_worker() / concrete_adhoc_session_is_live()
    # wiring — the same false-reclaim can hit a bare pool-template dog or a
    # concrete wa-worker-adhoc session mid-AskUserQuestion; both call sites
    # share the session_owner_is_healthy() predicate and need the same fix. ---
    _ah_pool_session = [
        {"id": "sid-dog1", "name": "gastown.dog-9", "session_name": "dog-gaxyz",
         "alias": "gastown.dog-9", "agent_name": "gastown.dog-9",
         "template": "gastown.dog",
         "state": "active", "last_active": _ah_stale_ts},
    ]
    subprocess.run = _stub_peek(output_text="⏺ AskUserQuestion(proceed?)")
    try:
        check("AH-11: pool_has_live_worker: stale+paused-on-AskUserQuestion dog → True (NOT reclaimed)",
              pool_has_live_worker("gastown.dog", _ah_pool_session, now=T_ah) is True)
    finally:
        subprocess.run = _orig_run_ah

    _ah_adhoc_session = [
        {"id": "sid-wa1", "name": "wa-worker-adhoc-1", "session_name": "wa-worker-adhoc-deadbeef",
         "alias": "", "agent_name": "wa-worker-adhoc-deadbeef",
         "state": "active", "last_active": _ah_stale_ts},
    ]
    subprocess.run = _stub_peek(output_text="⏺ AskUserQuestion(proceed?)")
    try:
        check("AH-12: concrete_adhoc_session_is_live: stale+paused-on-AskUserQuestion → True (NOT reclaimed)",
              concrete_adhoc_session_is_live(
                  "wa-worker-adhoc-deadbeef", _ah_adhoc_session, now=T_ah) is True)
    finally:
        subprocess.run = _orig_run_ah

    # -----------------------------------------------------------------------
    # Section SH: heal_orphan_sweep_false_resets() / list_orphan_sweep_false_resets()
    # ga-seuh4/ga-a8t68: order:orphan-sweep (packs/town-deltas/assets/scripts/
    # orphan-sweep.sh — git-tracked here, not go:embed'd) wrongfully resets live
    # dog-pool claims; these two functions are a compensating self-heal added to
    # this guard instead. ga-114ll extends the heal with a shield-label stamp.
    # -----------------------------------------------------------------------
    global _list_rig_stores
    _orig_list_rig_stores = _list_rig_stores
    _list_rig_stores = lambda: []  # no rig stores in these hermetic tests
    _orig_run_sh = subprocess.run

    _sh_live_sessions = [
        {"id": "sid-live1", "name": "gastown.dog-1", "session_name": "dog-galive1",
         "alias": "gastown.dog-1", "agent_name": "gastown.dog-1", "state": "active"},
    ]
    T_sh = 2_000_000_000.0

    def _sh_ts(seconds_ago):
        return _irg_datetime.datetime.utcfromtimestamp(T_sh - seconds_ago).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _sh_bead(bead_id, stale_assignee, seconds_ago=60, labels=None):
        return {"id": bead_id, "status": "open", "assignee": "",
                "updated_at": _sh_ts(seconds_ago),
                "labels": list(labels) if labels else [],
                "metadata": {"gc.routed_to": "gastown.dog",
                             "gc.session_name": stale_assignee,
                             "gc.work_dir": "/fake/work/dir"}}

    # SH-1: candidate whose stale gc.session_name matches a LIVE session → healed.
    _sh_update_calls = []
    _sh_label_calls = []
    _sh_comment_calls = []

    def _stub_sh_heal(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            # ga-f6igb round 2: the orphan-sweep:reset marker is what makes
            # this a genuine, healable orphan-sweep reset post-fix — see
            # SH-11/SH-12 below for the marker-absent/marker-present pair
            # this file's docstring calls out explicitly.
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest1", "dog-galive1", labels=["orphan-sweep:reset"])]))
        if cmd[:2] == ["bd", "update"]:
            _sh_update_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "label"]:
            _sh_label_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "comment"]:
            _sh_comment_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "show"]:
            # ga-f6igb round 2: _remove_label_verified()'s read-back — confirm
            # removal landed (label gone) so it returns True on attempt 1
            # instead of retrying x4 with real sleeps (ga-jzye0 stub trap:
            # an unstubbed `bd show` here reads as "can never confirm").
            return _FakeGitResult(0, json.dumps({"id": "ga-shtest1", "labels": []}))
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_heal
    try:
        _healed = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-1: heals a candidate whose stale gc.session_name is still live",
              _healed == 1, f"healed={_healed}")
        check("SH-1b: issues bd update --status in_progress --assignee <stale-assignee>",
              any(c[:2] == ["bd", "update"] and "in_progress" in c and "dog-galive1" in c
                  for c in _sh_update_calls),
              f"calls={_sh_update_calls!r}")
        # ga-114ll: every successful heal also stamps a shield the next
        # orphan-sweep pass must honor unconditionally.
        _expected_shield_until = int(T_sh) + ORPHAN_SWEEP_SELFHEAL_SHIELD_SECS
        check("SH-1c (ga-114ll): stamps orphan-sweep:shielded on the healed bead",
              any(c[:2] == ["bd", "label"] and "ga-shtest1" in c and "orphan-sweep:shielded" in c
                  for c in _sh_label_calls),
              f"label calls={_sh_label_calls!r}")
        check("SH-1d (ga-114ll): stamps orphan-sweep:shielded-until:<now+SHIELD_SECS>",
              any(c[:2] == ["bd", "label"] and "ga-shtest1" in c
                  and f"orphan-sweep:shielded-until:{_expected_shield_until}" in c
                  for c in _sh_label_calls),
              f"expected_until={_expected_shield_until} label calls={_sh_label_calls!r}")
        check("SH-1e (ga-114ll): self-heal comment cites the shield stamp",
              any(c[:2] == ["bd", "comment"] and "ga-shtest1" in c
                  and any(f"shielded-until:{_expected_shield_until}" in arg for arg in c)
                  for c in _sh_comment_calls),
              f"comment calls={_sh_comment_calls!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-1f (ga-114ll third-state audit): if the label-add calls themselves FAIL,
    # the claim restore still counts as healed, but the comment must NOT claim a
    # shield that never landed — "attempted" and "succeeded" are different facts.
    _sh_comment_calls_f = []

    def _stub_sh_heal_label_fails(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            # ga-f6igb round 2: marker required to heal post-fix (see SH-1 above).
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest1f", "dog-galive1", labels=["orphan-sweep:reset"])]))
        if cmd[:2] == ["bd", "update"]:
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "label"]:
            return _FakeGitResult(1, "")  # label add/remove reports failure...
        if cmd[:2] == ["bd", "show"]:
            # ...but this stub's read-back shows it landed anyway (the exact
            # race _remove_label_verified exists to catch — ga-jzye0) so the
            # marker-removal step confirms quickly (attempt 1, no real sleep)
            # and this test stays focused on ITS OWN purpose (shield-label
            # failure must not block the heal / must not be misreported).
            return _FakeGitResult(0, json.dumps({"id": "ga-shtest1f", "labels": []}))
        if cmd[:2] == ["bd", "comment"]:
            _sh_comment_calls_f.append(list(cmd))
            return _FakeGitResult(0, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_heal_label_fails
    try:
        _healedf = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-1f: still counts as healed even when the shield label-add fails",
              _healedf == 1, f"healed={_healedf}")
        check("SH-1f (ga-114ll): comment does NOT falsely claim a shield that failed to land",
              not any("shielded-until:" in arg for c in _sh_comment_calls_f for arg in c),
              f"comment calls={_sh_comment_calls_f!r}")
        check("SH-1f (ga-114ll): comment instead reports the shield stamp failure honestly",
              any("Shield stamp FAILED" in arg for c in _sh_comment_calls_f for arg in c),
              f"comment calls={_sh_comment_calls_f!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-2: candidate whose stale gc.session_name matches no live session → left alone
    # (genuinely dead — orphan-sweep's reset was correct, normal re-dispatch applies).
    _sh_update_calls2 = []
    _sh_label_calls2 = []

    def _stub_sh_dead(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps([_sh_bead("ga-shtest2", "dog-galong-gone")]))
        if cmd[:2] == ["bd", "update"]:
            _sh_update_calls2.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "label"]:
            _sh_label_calls2.append(list(cmd))
            return _FakeGitResult(0, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_dead
    try:
        _healed2 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-2: does NOT heal a candidate whose stale gc.session_name matches no live session",
              _healed2 == 0 and _sh_update_calls2 == [],
              f"healed={_healed2} calls={_sh_update_calls2!r}")
        check("SH-2b (ga-114ll): a genuinely-dead candidate is never shielded either",
              _sh_label_calls2 == [], f"label calls={_sh_label_calls2!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-3: no candidates at all → 0 healed, zero bd update calls.
    _sh_update_calls3 = []

    def _stub_sh_empty(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, "[]")
        if cmd[:2] == ["bd", "update"]:
            _sh_update_calls3.append(list(cmd))
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_empty
    try:
        _healed3 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-3: no candidates → 0 healed, no bd update calls",
              _healed3 == 0 and _sh_update_calls3 == [])
    finally:
        subprocess.run = _orig_run_sh

    # SH-4: candidate query itself fails (bd list errors) → fails safe, 0 healed.
    def _stub_sh_query_fail(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(1, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_query_fail
    try:
        _healed4 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-4: candidate query failure fails safe (0 healed, no crash)",
              _healed4 == 0)
    finally:
        subprocess.run = _orig_run_sh

    # SH-5: bd update itself fails for a live-matched candidate → not counted
    # healed, no crash (the next cycle will retry — session is still live).
    def _stub_sh_update_fail(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps([_sh_bead("ga-shtest5", "dog-galive1")]))
        if cmd[:2] == ["bd", "update"]:
            return _FakeGitResult(1, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_update_fail
    try:
        _healed5 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-5: bd update failure for a live candidate is not counted healed (no crash)",
              _healed5 == 0)
    finally:
        subprocess.run = _orig_run_sh

    # SH-6: candidate missing gc.session_name (defensive — the --has-metadata-key
    # query should always populate it, but never act on an empty assignee).
    def _stub_sh_no_meta(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps(
                [{"id": "ga-shtest6", "status": "open", "assignee": "", "metadata": {}}]))
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_no_meta
    try:
        _healed6 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-6: candidate with no gc.session_name metadata is skipped, not crashed",
              _healed6 == 0)
    finally:
        subprocess.run = _orig_run_sh

    # SH-6b regression (real-data find): `bd list --has-metadata-key` is a
    # single-value flag — passing it twice for two DIFFERENT keys silently
    # keeps only the LAST one (confirmed against live data: a bead carrying
    # ONLY gc.routed_to, e.g. a manually-routed non-pool task with no dog/
    # wa-worker claim ever taken, matched a naive `--has-metadata-key
    # gc.session_name --has-metadata-key gc.routed_to` query). Both keys
    # must be required in Python, not left to the CLI flag alone.
    def _stub_sh_routed_only(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps(
                [{"id": "ga-shtest6b", "status": "open", "assignee": "",
                  "updated_at": _sh_ts(60),
                  "metadata": {"gc.routed_to": "batista-lx"}}]))
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_routed_only
    try:
        _healed6b = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-6b: candidate with gc.routed_to but NO gc.session_name is skipped "
              "(regression: --has-metadata-key does not AND across two keys)",
              _healed6b == 0)
    finally:
        subprocess.run = _orig_run_sh

    # SH-7: candidate whose updated_at is OLDER than RECLAIM_TTL is NOT healed,
    # even though its stale gc.session_name still resolves to a live session —
    # the freshness guard bounds this against silently undoing an old,
    # deliberate stand-down release (same bd shape as an orphan-sweep false
    # reset; see the guard's own comment in heal_orphan_sweep_false_resets).
    def _stub_sh_stale_ts(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest7", "dog-galive1", seconds_ago=RECLAIM_TTL + 60)]))
        if cmd[:2] == ["bd", "update"]:
            raise AssertionError("must not update a bead past the freshness window")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh_stale_ts
    try:
        _healed7 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-7: candidate older than RECLAIM_TTL is NOT healed (freshness guard)",
              _healed7 == 0)
    finally:
        subprocess.run = _orig_run_sh

    # SH-8 (ga-f6igb, AC2): a candidate carrying an explicit deliberate-release
    # label must NEVER be healed, even though its stale gc.session_name still
    # resolves to a live session and the update is fresh — this is the exact
    # regression ga-wgvca/ga-wzl83 reported: self-heal reverted a correct,
    # intentional stand-down within ~2 minutes because liveness alone can't
    # distinguish it from orphan-sweep's blind reset. One sub-case per label
    # _has_deliberate_release_signal() recognizes.
    _sh8_labels = [
        "pool:refused",                          # ga-wgvca: bare refusal
        "pool:refused:engine-rebuild-required",  # ga-wgvca: refusal w/ reason
        "gate:needs-human",                      # already escalated by do_escalate()
        "gate:needs-human:technical",            # ":"-suffixed escalation sub-label
        "needs-human",                           # bare, no gate: prefix
        "pilot:no-auto-dispatch",                # ga-wzl83: deliberate park
        "pilot:held",                            # active hold (do_reclaim's own stamp)
        "pilot:held-until:9999999999",           # active hold, "-until:" prefix form
        "story:awaiting-external-merge",         # done, blocked on an outside event
    ]
    for _sh8_label in _sh8_labels:
        _sh8_update_calls = []

        def _stub_sh8(cmd, _label=_sh8_label, _calls=_sh8_update_calls, **kw):
            if cmd[:2] == ["bd", "list"]:
                return _FakeGitResult(0, json.dumps(
                    [_sh_bead("ga-shtest8", "dog-galive1", labels=[_label])]))
            if cmd[:2] == ["bd", "update"]:
                _calls.append(list(cmd))
            return _FakeGitResult(0, "")

        subprocess.run = _stub_sh8
        try:
            _healed8 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
            check(f"SH-8 ({_sh8_label!r}): deliberate-release label blocks "
                  f"self-heal (ga-f6igb AC2)",
                  _healed8 == 0 and _sh8_update_calls == [],
                  f"healed={_healed8} calls={_sh8_update_calls!r}")
        finally:
            subprocess.run = _orig_run_sh

    # SH-9 (ga-f6igb, AC3): a candidate WITHOUT any deliberate-release label —
    # just the normal in-flight labels a genuinely-live builder's bead
    # carries — is STILL healed. This is ga-seuh4's original protection;
    # ga-f6igb must not regress it while fixing the false-restore case above.
    _sh9_update_calls = []

    def _stub_sh9(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            # ga-f6igb round 2: marker required to heal post-fix (see SH-1 above);
            # this test's own point (in-flight labels don't block healing) is
            # orthogonal to the marker requirement, so both are present here.
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest9", "dog-galive1",
                          labels=["ctx:ready", "exec:auto", "story:in-flight",
                                  "orphan-sweep:reset"])]))
        if cmd[:2] == ["bd", "update"]:
            _sh9_update_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "show"]:
            # ga-f6igb round 2: confirm marker-removal read-back (see SH-1 above).
            return _FakeGitResult(0, json.dumps({"id": "ga-shtest9", "labels": []}))
        if cmd[:2] in (["bd", "label"], ["bd", "comment"]):
            return _FakeGitResult(0, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh9
    try:
        _healed9 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-9 (ga-f6igb AC3): normal in-flight labels (no deliberate-release "
              "marker) do NOT block self-heal — preserves ga-seuh4's original case",
              _healed9 == 1 and len(_sh9_update_calls) == 1,
              f"healed={_healed9} calls={_sh9_update_calls!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-10 (ga-f6igb precision guard): an UNRELATED park label (ctx:thin —
    # not in _has_deliberate_release_signal()'s curated set) must NOT block
    # self-heal either. Proves the fix did not adopt bead_state.py's full
    # PARK_PREFIXES/PARK_EXACT union — see that helper's own docstring for
    # why the broader vocabulary would over-block a genuine orphan-sweep
    # false-reset (leaving it open+unassigned+ctx:ready+exec:auto, newly
    # exposed to routed-pool re-dispatch).
    _sh10_update_calls = []

    def _stub_sh10(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            # ga-f6igb round 2: marker required to heal post-fix (see SH-1 above);
            # this test's own point (ctx:thin doesn't block healing) is
            # orthogonal to the marker requirement, so both are present here.
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest10", "dog-galive1",
                          labels=["ctx:thin", "ctx:ready", "exec:auto",
                                  "orphan-sweep:reset"])]))
        if cmd[:2] == ["bd", "update"]:
            _sh10_update_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "show"]:
            # ga-f6igb round 2: confirm marker-removal read-back (see SH-1 above).
            return _FakeGitResult(0, json.dumps({"id": "ga-shtest10", "labels": []}))
        if cmd[:2] in (["bd", "label"], ["bd", "comment"]):
            return _FakeGitResult(0, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh10
    try:
        _healed10 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-10 (ga-f6igb precision guard): unrelated park label (ctx:thin) "
              "does NOT block self-heal — curated set, not the full park vocabulary",
              _healed10 == 1 and len(_sh10_update_calls) == 1,
              f"healed={_healed10} calls={_sh10_update_calls!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-11 (ga-f6igb round 2, GATE-FEEDBACK gate_run=ga-2esd2 blocking issue 1):
    # a candidate with NEITHER a recognized deliberate-release label NOR the
    # orphan-sweep:reset marker must NOT be healed. This is the exact gap the
    # round-1 fix missed: order:orphan-sweep's own reset is always unlabeled,
    # so "no recognized label" alone was silently read as "therefore
    # accidental" (SH-9 above). Reproduces the ga-5ksp5 shape on-thread
    # (dog-ga3wack's 2026-08-08 21:08 comment on this bead) — a legitimately-
    # finished, unlabeled release that would have been WRONGLY restored by
    # round-1's code. Also asserts emit()/notify is never reached on this
    # path (would double as a regression guard for blocking issue 2 even if
    # SH-8 above didn't already cover the labeled-skip case).
    _sh11_update_calls = []
    _sh11_notify_calls = []

    def _stub_sh11(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest11", "dog-galive1", labels=[])]))
        if cmd[:2] == ["bd", "update"]:
            _sh11_update_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd and "notify" in cmd[0]:
            _sh11_notify_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh11
    try:
        _healed11 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-11 (ga-f6igb round 2, AC2 unlabeled case): no deliberate-release "
              "label AND no orphan-sweep:reset marker -> NOT healed (closes the "
              "ga-5ksp5 gap round 1 missed)",
              _healed11 == 0 and _sh11_update_calls == [],
              f"healed={_healed11} calls={_sh11_update_calls!r}")
        check("SH-11b (ga-f6igb round 2, blocking issue 2 regression guard): "
              "SELF-HEAL-SKIPPED path never calls notify (print(), not emit())",
              _sh11_notify_calls == [],
              f"notify calls={_sh11_notify_calls!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-12 (ga-f6igb round 2, AC2 positive path): a candidate carrying the
    # orphan-sweep:reset marker — the real shape orphan-sweep.sh now produces
    # on every genuine reset (Step 3's own bd update, this fix's other half)
    # — IS healed, and the marker is consumed (stripped) as part of
    # processing it, so it can never be replayed as stale evidence for a
    # later, unrelated reset of the same bead id.
    _sh12_update_calls = []
    _sh12_label_calls = []

    def _stub_sh12(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest12", "dog-galive1", labels=["orphan-sweep:reset"])]))
        if cmd[:2] == ["bd", "update"]:
            _sh12_update_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "label"]:
            _sh12_label_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "show"]:
            # ga-f6igb round 2: confirm marker-removal read-back (see SH-1 above).
            return _FakeGitResult(0, json.dumps({"id": "ga-shtest12", "labels": []}))
        if cmd[:2] == ["bd", "comment"]:
            return _FakeGitResult(0, "")
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh12
    try:
        _healed12 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-12 (ga-f6igb round 2, AC2 positive path): orphan-sweep:reset "
              "marker present -> healed",
              _healed12 == 1 and len(_sh12_update_calls) == 1,
              f"healed={_healed12} calls={_sh12_update_calls!r}")
        check("SH-12b (ga-f6igb round 2): marker is consumed (bd label remove "
              "orphan-sweep:reset), single-use, not left to be replayed stale",
              any(c[:2] == ["bd", "label"] and c[2:5] == ["remove", "ga-shtest12", "orphan-sweep:reset"]
                  for c in _sh12_label_calls),
              f"label calls={_sh12_label_calls!r}")
    finally:
        subprocess.run = _orig_run_sh

    # SH-13 (ga-f6igb round 2, marker-strip is unconditional): a candidate
    # that carries BOTH the orphan-sweep:reset marker AND a deliberate-
    # release label must still have the marker stripped, even though the
    # deliberate-release label wins and blocks the heal — otherwise the
    # marker would survive this pass and could be misread as fresh evidence
    # on a LATER, unrelated reset of the same bead id (see
    # heal_orphan_sweep_false_resets()'s own comment on why the strip happens
    # before, not inside, the eventual heal branch).
    _sh13_update_calls = []
    _sh13_label_calls = []

    def _stub_sh13(cmd, **kw):
        if cmd[:2] == ["bd", "list"]:
            return _FakeGitResult(0, json.dumps(
                [_sh_bead("ga-shtest13", "dog-galive1",
                          labels=["orphan-sweep:reset", "pool:refused"])]))
        if cmd[:2] == ["bd", "update"]:
            _sh13_update_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "label"]:
            _sh13_label_calls.append(list(cmd))
            return _FakeGitResult(0, "")
        if cmd[:2] == ["bd", "show"]:
            # ga-f6igb round 2: confirm marker-removal read-back (see SH-1 above).
            return _FakeGitResult(0, json.dumps({"id": "ga-shtest13", "labels": ["pool:refused"]}))
        return _FakeGitResult(0, "")

    subprocess.run = _stub_sh13
    try:
        _healed13 = heal_orphan_sweep_false_resets(_sh_live_sessions, T_sh)
        check("SH-13 (ga-f6igb round 2, precedence): deliberate-release label "
              "still wins over a present marker -> NOT healed",
              _healed13 == 0 and _sh13_update_calls == [],
              f"healed={_healed13} calls={_sh13_update_calls!r}")
        check("SH-13b (ga-f6igb round 2): marker is still stripped even on the "
              "label-wins-skip path (unconditional consumption, not tied to "
              "the heal branch)",
              any(c[:2] == ["bd", "label"] and c[2:5] == ["remove", "ga-shtest13", "orphan-sweep:reset"]
                  for c in _sh13_label_calls),
              f"label calls={_sh13_label_calls!r}")
    finally:
        subprocess.run = _orig_run_sh

    _list_rig_stores = _orig_list_rig_stores

    # -----------------------------------------------------------------------
    # Section 12: ga-u8fly — three independent defects found while chasing
    # "ephemeral wa-worker zombie claims never reclaimed": (1) needs-human
    # bare-label recognition gap, (2) _list_rig_stores() silent fail-open
    # wipes accumulated stranded-clock progress via the end-of-cycle prune,
    # (3) do_reclaim() clears the assignee BEFORE flipping status to open,
    # but `bd assign` refuses to overwrite another actor's live in_progress
    # claim without --force (bd-98s5c) — so the clear is silently ignored
    # (returncode never checked) and the bead ends up open-but-still-
    # assigned, which --unassigned dispatch queries then exclude forever.
    # -----------------------------------------------------------------------

    # --- NH-*: _has_needs_human_label must recognize the bare "needs-human"
    # label, not just the gate:needs-human[:*] circuit-breaker variant. Live
    # incident: wa-fvmo8 carries bare "needs-human" (Athos mid phone call to
    # Assertiva support) and was incorrectly auto-reclaimed today because
    # this check missed it entirely. ---
    check("NH-1 (ga-u8fly): _has_needs_human_label recognizes bare 'needs-human'",
          _has_needs_human_label(["exec:manual", "needs-human"]))
    check("NH-2: still recognizes gate:needs-human (no regression)",
          _has_needs_human_label(["gate:needs-human"]))
    check("NH-3: still recognizes gate:needs-human:<variant> (no regression)",
          _has_needs_human_label(["gate:needs-human:on-device"]))
    check("NH-4: unrelated labels → False",
          not _has_needs_human_label(["ctx:ready", "exec:manual"]))
    # --- NH-5/6 (ga-x3e7p GATE-FAIL attempt 3/3): the ORIGINAL body of this
    # function (pre-migration) matched exact/":"-suffix only — "-"-suffixed
    # forms like "needs-human-followup" (real label, ga-3lsy1) returned False.
    # The delegation to bead_state.is_needs_human widened this to also match
    # "-"-suffix, which the diff's own comments falsely claimed was "zero
    # behavior change". NH-5 locks in the new (intentional) behavior at the
    # label level; NH-6 proves it all the way through reclaim_decision()'s
    # actual safety guard — the real consumer, not a reimplementation of it.
    check("NH-5: recognizes '-'-suffixed variant (needs-human-followup) — was False pre-ga-x3e7p, now True by design",
          _has_needs_human_label(["needs-human-followup"]))
    check("NH-6: reclaim_decision noops on a would-otherwise-reclaim bead once has_needs_human is computed from the '-'-suffixed label",
          reclaim_decision(
              has_live_session=False, has_recent_branch=False,
              seconds_stranded=RECLAIM_TTL + 1, reclaim_count=0,
              has_needs_human=_has_needs_human_label(["needs-human-followup"]),
              has_dispatching_marker=False,
          ) == "noop")

    # --- CTRL-1: explicit pointer to ga-u8fly's own acceptance control (2) —
    # a FRESH claim (assignee changed since last cycle) must get a full TTL
    # window, never inherit the prior claim's already-elapsed clock. Preexisting
    # mechanism (wa-og36j); asserted here directly for this bead's audit trail. ---
    _ctrl_state = {"first_seen_stranded": 1000.0, "last_assignee": "wa-worker-adhoc-old"}
    _ctrl_secs, _ctrl_event = update_strand_clock(
        _ctrl_state, is_currently_stranded=True,
        assignee="wa-worker-adhoc-new", now=1000.0 + 3 * 3600)
    check("CTRL-1 (ga-u8fly control 2): a fresh claim (assignee changed) resets the "
          "clock instead of inheriting 3h of the prior claim's staleness",
          _ctrl_event == "fresh_claim_reset" and _ctrl_secs == 0.0,
          f"event={_ctrl_event} secs={_ctrl_secs}")

    # --- RGL-*: _list_rig_stores() must distinguish a genuine query FAILURE
    # (gc rig list errors/times out) from a genuine empty result, and that
    # failure must propagate as a whole-cycle skip — never a silent partial
    # scan. Live incident: wa-m4j75's stranded clock only started tracking
    # 2h05m after its actual claim began — ~12 consecutive cycles treated a
    # rig-list hiccup as "zero non-HQ rigs", and run_cycle's end-of-cycle
    # state prune (state.pop for any bead not seen that cycle) repeatedly
    # wiped its accumulated progress before it could ever cross
    # POOL_ZOMBIE_TTL. ---
    class _RglResult:
        def __init__(self, rc=0, out=""):
            self.returncode = rc
            self.stdout = out
            self.stderr = ""

    def _rgl_stub(rig_list_rc, rig_list_out, hq_inprogress=None):
        hq_inprogress = hq_inprogress if hq_inprogress is not None else []
        calls = []

        def _run(cmd, **kw):
            if not isinstance(cmd, (list, tuple)):
                return _RglResult(0, "")
            calls.append(list(cmd))
            if cmd[0] == "gc" and "rig" in cmd and "list" in cmd:
                return _RglResult(rig_list_rc, rig_list_out)
            if cmd[0] == "bd":
                args = list(cmd[1:])
                if args and args[0] == "list":
                    return _RglResult(0, json.dumps(hq_inprogress))
                return _RglResult(0, "[]")
            return _RglResult(0, "")
        return _run, calls

    _orig_run_rgl = subprocess.run

    # RGL-1: gc rig list fails (rc=1) → _list_rig_stores() returns None, not []
    subprocess.run, _ = _rgl_stub(1, "")
    try:
        _rgl_result = _list_rig_stores()
    finally:
        subprocess.run = _orig_run_rgl
    check("RGL-1 (ga-u8fly): _list_rig_stores() returns None (not []) when "
          "gc rig list fails",
          _rgl_result is None, f"got {_rgl_result!r}")

    # RGL-2: a genuinely successful, genuinely-empty rig list → [] (still
    # distinct from failure — the fix must not over-correct the success path)
    subprocess.run, _ = _rgl_stub(0, json.dumps({"rigs": []}))
    try:
        _rgl_result2 = _list_rig_stores()
    finally:
        subprocess.run = _orig_run_rgl
    check("RGL-2: _list_rig_stores() returns [] (not None) on a genuine "
          "empty-but-successful result",
          _rgl_result2 == [], f"got {_rgl_result2!r}")

    # RGL-3: rig-list failure must make list_stranded_inprogress_beads() skip
    # the WHOLE cycle (return None) rather than silently returning HQ-only
    # results — this is what stops the amnesia/prune mechanism from firing.
    subprocess.run, _rgl_calls3 = _rgl_stub(1, "", hq_inprogress=[
        {"id": "wa-hq1", "status": "in_progress", "assignee": "wa-worker",
         "labels": [], "issue_type": "bug"}])
    try:
        _rgl_result3 = list_stranded_inprogress_beads()
    finally:
        subprocess.run = _orig_run_rgl
    check("RGL-3 (ga-u8fly): list_stranded_inprogress_beads() returns None "
          "(skips cycle) when the rig-store scan fails, instead of silently "
          "returning HQ-only results",
          _rgl_result3 is None, f"got {_rgl_result3!r}")

    # RGL-4: same contract for list_inflight_beads()
    subprocess.run, _rgl_calls4 = _rgl_stub(1, "")
    try:
        _rgl_result4 = list_inflight_beads()
    finally:
        subprocess.run = _orig_run_rgl
    check("RGL-4 (ga-u8fly): list_inflight_beads() returns None (skips cycle) "
          "when the rig-store scan fails",
          _rgl_result4 is None, f"got {_rgl_result4!r}")

    # RGL-5: when the rig list DOES succeed, the per-rig bd list call must
    # carry --limit 0 (ga-21kmp class — bd list --json silently truncates at
    # 50 with no JSON-visible signal; the HQ-scoped queries in this same
    # file were already fixed by 848fb99b6, but the -C <rig_path>
    # cross-store queries use a structurally different call shape and were
    # missed).
    subprocess.run, _rgl_calls5 = _rgl_stub(
        0, json.dumps({"rigs": [{"name": "whatsapp_automation",
                                  "path": "/tmp", "hq": False}]}))
    _orig_isdir = os.path.isdir
    os.path.isdir = lambda p: True
    try:
        list_stranded_inprogress_beads()
    finally:
        subprocess.run = _orig_run_rgl
        os.path.isdir = _orig_isdir
    _rig_bd_list_calls = [c for c in _rgl_calls5
                           if c and c[0] == "bd" and "-C" in c and "list" in c]
    _rig_calls_have_limit_0 = bool(_rig_bd_list_calls) and all(
        any(c[i:i + 2] == ["--limit", "0"] for i in range(len(c) - 1))
        for c in _rig_bd_list_calls
    )
    check("RGL-5 (ga-u8fly): rig-store bd list call includes --limit 0",
          _rig_calls_have_limit_0, f"calls={_rig_bd_list_calls}")

    # --- RGL-6..8 (ga-1qqoi, sibling of ga-x3e7p): three more list_*
    # functions call _list_rig_stores() via `... or []`, deliberately
    # preserving their OWN fail-open contract (ga-u8fly: each computes a
    # fresh, non-persisted result every cycle, unlike list_inflight_beads/
    # list_stranded_inprogress_beads above, so a rig-list hiccup here isn't
    # the amnesia/prune hazard RGL-1..4 guard against) — but did so with zero
    # signal. A genuine `gc rig list` failure was indistinguishable from a
    # real zero-non-HQ-rigs cycle in every log this guard writes. Each check
    # below confirms BOTH halves: the warning now fires, AND the fail-open
    # return value/type is unchanged (no over-correction to None/abort —
    # that would be the wrong fix, per ga-u8fly's own documented reasoning
    # for why these three stay fail-open). ---
    import io as _io

    # RGL-6: list_live_sling_source_beads()
    subprocess.run, _ = _rgl_stub(1, "")
    _cap = _io.StringIO()
    _orig_stdout = _sys.stdout
    _sys.stdout = _cap
    try:
        _rgl_result6 = list_live_sling_source_beads({}, time.time())
    finally:
        _sys.stdout = _orig_stdout
        subprocess.run = _orig_run_rgl
    _out6 = _cap.getvalue()
    check("RGL-6 (ga-1qqoi): list_live_sling_source_beads warns when gc rig "
          "list fails",
          "gc rig list failed" in _out6, f"captured={_out6!r}")
    check("RGL-6 (ga-1qqoi): list_live_sling_source_beads still returns its "
          "normal fail-open type (frozenset, not None) — behavior unchanged",
          isinstance(_rgl_result6, frozenset), f"got {_rgl_result6!r}")

    # RGL-7: list_refused_sling_source_beads()
    subprocess.run, _ = _rgl_stub(1, "")
    _cap = _io.StringIO()
    _orig_stdout = _sys.stdout
    _sys.stdout = _cap
    try:
        _rgl_result7 = list_refused_sling_source_beads()
    finally:
        _sys.stdout = _orig_stdout
        subprocess.run = _orig_run_rgl
    _out7 = _cap.getvalue()
    check("RGL-7 (ga-1qqoi): list_refused_sling_source_beads warns when gc "
          "rig list fails",
          "gc rig list failed" in _out7, f"captured={_out7!r}")
    check("RGL-7 (ga-1qqoi): list_refused_sling_source_beads still returns "
          "its normal fail-open type (dict, not None) — behavior unchanged",
          isinstance(_rgl_result7, dict), f"got {_rgl_result7!r}")

    # RGL-8: list_orphan_sweep_false_resets()
    subprocess.run, _ = _rgl_stub(1, "")
    _cap = _io.StringIO()
    _orig_stdout = _sys.stdout
    _sys.stdout = _cap
    try:
        _rgl_result8 = list_orphan_sweep_false_resets()
    finally:
        _sys.stdout = _orig_stdout
        subprocess.run = _orig_run_rgl
    _out8 = _cap.getvalue()
    check("RGL-8 (ga-1qqoi): list_orphan_sweep_false_resets warns when gc "
          "rig list fails",
          "gc rig list failed" in _out8, f"captured={_out8!r}")
    check("RGL-8 (ga-1qqoi): list_orphan_sweep_false_resets still returns "
          "its normal fail-open type (list, not None) — behavior unchanged",
          isinstance(_rgl_result8, list), f"got {_rgl_result8!r}")

    # --- RCO-*: do_reclaim() must actually free the bead for re-dispatch.
    # bd assign refuses to overwrite another actor's live in_progress claim
    # without --force (bd-98s5c) — do_reclaim cleared the assignee BEFORE
    # flipping status to open, so the assign was silently refused
    # (returncode checked nowhere) and the bead ended up open-but-still-
    # assigned, which --unassigned dispatch queries exclude. Live incident:
    # wa-m4j75 and wa-fvmo8 both "reclaimed" today (status→open) but
    # retained their dead assignee. This reproduces bd's real refusal
    # semantics and checks the END STATE, not just call presence. ---
    class _RcoResult:
        def __init__(self, rc=0, out="", err=""):
            self.returncode = rc
            self.stdout = out
            self.stderr = err

    def _make_rco_stub(initial_assignee="wa-worker-adhoc-dead"):
        state = {"status": "in_progress", "assignee": initial_assignee, "labels": []}

        def _run(cmd, **kw):
            if not isinstance(cmd, (list, tuple)):
                return _RcoResult(0, "")
            if cmd[0] == "git":
                return _RcoResult(0, "")
            if cmd[0] == "bd":
                args = list(cmd[1:])
                sub = args[0] if args else ""
                if sub == "assign":
                    if state["status"] == "in_progress" and "--force" not in args:
                        return _RcoResult(1, "", "refuses to overwrite live in_progress claim")
                    state["assignee"] = args[2] if len(args) > 2 else ""
                    return _RcoResult(0, "")
                if sub == "update" and "--status" in args:
                    i = args.index("--status")
                    state["status"] = args[i + 1]
                    return _RcoResult(0, "")
                if sub in ("label", "comment"):
                    return _RcoResult(0, "")
                if sub == "show":
                    return _RcoResult(0, json.dumps([{"id": "wa-x", "labels": state["labels"]}]))
            return _RcoResult(0, "")
        return _run, state

    _orig_run_rco = subprocess.run
    subprocess.run, _rco_state = _make_rco_stub()
    try:
        do_reclaim("wa-x", "title", reclaim_count=0, idle_min=125, labels=[])
    finally:
        subprocess.run = _orig_run_rco
    check("RCO-1 (ga-u8fly): do_reclaim actually clears the assignee even "
          "though bd assign refuses while status is still in_progress",
          _rco_state["assignee"] == "", f"final state={_rco_state}")
    check("RCO-2: status ends as open",
          _rco_state["status"] == "open", f"final state={_rco_state}")

    # RCO-3 (ga-u8fly control 3): a dead session holding TWO beads must
    # release BOTH independently — mirrors the real incident where
    # wa-worker-adhoc-b979abfb35 held both wa-fvmo8 and wa-m4j75 at once.
    subprocess.run, _rco_state_a = _make_rco_stub()
    try:
        do_reclaim("wa-bead-a", "title a", reclaim_count=0, idle_min=130, labels=[])
    finally:
        subprocess.run = _orig_run_rco
    subprocess.run, _rco_state_b = _make_rco_stub()
    try:
        do_reclaim("wa-bead-b", "title b", reclaim_count=0, idle_min=130, labels=[])
    finally:
        subprocess.run = _orig_run_rco
    check("RCO-3 (ga-u8fly control 3): two independent beads held by the "
          "same dead session both end up fully released",
          _rco_state_a["assignee"] == "" and _rco_state_b["assignee"] == "",
          f"a={_rco_state_a} b={_rco_state_b}")

    # -----------------------------------------------------------------------
    # Section 13: ga-xlnkf — inflight-reclaim-guard orphans the dispatch SLING
    # when it reclaims+HOLDS a target bead. The guard only ever watches the
    # TARGET's own progress; it never touched the SLING wrapper `gc sling`
    # minted for that dispatch, so a reclaimed+held target left its sling
    # open+unassigned for the full cooldown — a pool worker's self-serve
    # probe could claim that stale sling, discover the target is held, and
    # burn a cycle recognizing it as stale before closing it by hand.
    # do_reclaim() now resolves the target's metadata.pilot.sling_bead and,
    # ONLY on a reclaim that also stamps pilot:held (reclaim_count >= 1),
    # closes it IF it is still open and unclaimed (SLC-*).
    # -----------------------------------------------------------------------
    class _SlcResult:
        def __init__(self, rc=0, out="", err=""):
            self.returncode = rc
            self.stdout = out
            self.stderr = err

    def _make_slc_stub(sling_id, sling_status="open", sling_assignee=""):
        """Only the SLING's state is modeled (status/assignee, mutated by a
        `close`). Any `bd show` for a DIFFERENT id — i.e. do_reclaim's own
        _remove_label_verified() read-back on the TARGET bead itself — reports
        the label already gone, so step 1 verifies clean and execution reaches
        step 3b, the thing this section actually exercises (Section 9b/12
        already cover the target's own label/status/assignee mechanics)."""
        sling_state = {"status": sling_status, "assignee": sling_assignee}
        calls = []

        def _run(cmd, **kw):
            if not isinstance(cmd, (list, tuple)):
                return _SlcResult(0, "")
            calls.append(list(cmd))
            if cmd and cmd[0] == "bd":
                args = list(cmd[1:])
                sub = args[0] if args else ""
                if sub == "show" and len(args) >= 2:
                    if args[1] == sling_id:
                        return _SlcResult(0, json.dumps([
                            {"id": sling_id, "status": sling_state["status"],
                             "assignee": sling_state["assignee"]}]))
                    return _SlcResult(0, json.dumps([{"id": args[1], "labels": []}]))
                if sub == "close" and len(args) >= 2 and args[1] == sling_id:
                    sling_state["status"] = "closed"
                    return _SlcResult(0, "")
                return _SlcResult(0, "")  # label/update/assign/comment: accept, no-op
            return _SlcResult(0, "")      # e.g. git, from preserve_unpushed_branch
        return _run, calls, sling_state

    _orig_run_slc = subprocess.run
    # Hermetic regardless of the real operator shell's environment (this var
    # is unset by default, but a stray export must never make this section
    # flaky) — save/restore around every SLC-* call below.
    _orig_reloop_env = os.environ.get("RECLAIM_RELOOP_HOLD_SECS")
    os.environ["RECLAIM_RELOOP_HOLD_SECS"] = "3600"
    try:
        # SLC-1 (AC1): reclaim_count=1 (2nd reclaim -> hold fires this cycle)
        # + sling open, unassigned -> the sling gets closed, citing the
        # target id and the superseded-by-reclaim-hold reason.
        subprocess.run, _slc_calls1, _ = _make_slc_stub("ga-sling1", "open", "")
        try:
            do_reclaim("ga-target1", "some bead", reclaim_count=1, idle_min=40.0,
                        labels=["story:in-flight"], sling_bead_id="ga-sling1")
        finally:
            subprocess.run = _orig_run_slc
        _slc1_close = [c for c in _slc_calls1 if len(c) >= 3 and c[0] == "bd"
                       and c[1] == "close" and c[2] == "ga-sling1"]
        check("SLC-1a (ga-xlnkf AC1): reclaim+hold closes the open+unassigned sling",
              len(_slc1_close) == 1, f"calls={_slc_calls1!r}")
        check("SLC-1b: close reason cites superseded-by-reclaim-hold and the target id",
              len(_slc1_close) == 1
              and "superseded-by-reclaim-hold" in _slc1_close[0][-1]
              and "ga-target1" in _slc1_close[0][-1],
              f"close_call={_slc1_close!r}")

        # SLC-2 (AC2 control): sling already in_progress — a live worker may
        # be on it RIGHT NOW — must NEVER be touched, even though this reclaim
        # holds the target.
        subprocess.run, _slc_calls2, _ = _make_slc_stub("ga-sling2", "in_progress", "dog-live")
        try:
            do_reclaim("ga-target2", "some bead", reclaim_count=1, idle_min=40.0,
                        labels=["story:in-flight"], sling_bead_id="ga-sling2")
        finally:
            subprocess.run = _orig_run_slc
        _slc2_close = [c for c in _slc_calls2 if len(c) >= 2 and c[0] == "bd" and c[1] == "close"]
        check("SLC-2 (ga-xlnkf AC2): sling in_progress with a live assignee is NEVER closed",
              len(_slc2_close) == 0, f"calls={_slc_calls2!r}")

        # SLC-3 (idempotency): sling already closed (e.g. by an earlier
        # reclaim cycle) -> no redundant close attempt, no crash, and the
        # target's own reclaim still completes normally.
        subprocess.run, _slc_calls3, _ = _make_slc_stub("ga-sling3", "closed", "")
        try:
            _slc3_ok = do_reclaim("ga-target3", "some bead", reclaim_count=1, idle_min=40.0,
                                   labels=["story:in-flight"], sling_bead_id="ga-sling3")
        finally:
            subprocess.run = _orig_run_slc
        _slc3_close = [c for c in _slc_calls3 if len(c) >= 2 and c[0] == "bd" and c[1] == "close"]
        check("SLC-3: an already-closed sling is left alone (no redundant close) "
              "and the reclaim itself still succeeds",
              _slc3_ok is True and len(_slc3_close) == 0, f"ok={_slc3_ok} calls={_slc_calls3!r}")

        # SLC-4 (AC3 control): target reclaimed with NO sling metadata at all
        # — the common case, since not every in-flight bead was dispatched
        # via `gc sling` — must not crash, must not attempt any show/close
        # against a sling, and the reclaim itself must still complete.
        subprocess.run, _slc_calls4, _ = _make_slc_stub("ga-sling4-unused")
        try:
            _slc4_ok = do_reclaim("ga-target4", "some bead", reclaim_count=1, idle_min=40.0,
                                   labels=["story:in-flight"], sling_bead_id=None)
        finally:
            subprocess.run = _orig_run_slc
        _slc4_sling_calls = [c for c in _slc_calls4
                             if len(c) >= 3 and c[0] == "bd" and c[1] in ("show", "close")
                             and c[2] == "ga-sling4-unused"]
        check("SLC-4 (ga-xlnkf AC3): no sling metadata -> no show/close attempted, "
              "guard unaffected, reclaim still succeeds",
              _slc4_ok is True and len(_slc4_sling_calls) == 0,
              f"ok={_slc4_ok} calls={_slc_calls4!r}")

        # SLC-5 (scope boundary): reclaim_count=0 is the FIRST reclaim —
        # do_reclaim's own step 3b gate (reclaim_count >= 1) means pilot:held
        # is NOT stamped this cycle. The bug this bead fixes is specifically
        # "reclaimed AND HELD" (see the bead body's repro), so the sling-close
        # must not fire here either, even though the sling is open+unassigned
        # and would otherwise qualify — proves the fix is scoped to the hold,
        # not to every reclaim.
        subprocess.run, _slc_calls5, _ = _make_slc_stub("ga-sling5", "open", "")
        try:
            do_reclaim("ga-target5", "some bead", reclaim_count=0, idle_min=30.0,
                        labels=["story:in-flight"], sling_bead_id="ga-sling5")
        finally:
            subprocess.run = _orig_run_slc
        _slc5_sling_calls = [c for c in _slc_calls5
                             if len(c) >= 3 and c[0] == "bd" and c[1] in ("show", "close")
                             and c[2] == "ga-sling5"]
        check("SLC-5 (ga-xlnkf scope): a FIRST reclaim (no hold stamped) never touches "
              "the sling, even if it is open+unassigned — this fix is scoped to "
              "reclaim+HOLD, not every reclaim",
              len(_slc5_sling_calls) == 0, f"calls={_slc_calls5!r}")
    finally:
        subprocess.run = _orig_run_slc
        if _orig_reloop_env is None:
            os.environ.pop("RECLAIM_RELOOP_HOLD_SECS", None)
        else:
            os.environ["RECLAIM_RELOOP_HOLD_SECS"] = _orig_reloop_env

    print(f"\nResults: {PASS} passed, {FAIL} failed")
    return FAIL == 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    emit(
        f"[INFLIGHT-RECLAIM] [STARTUP] reclaim_ttl={RECLAIM_TTL}s ({RECLAIM_TTL // 60}min) "
        f"max_reclaims={MAX_RECLAIMS} poll={POLL_SEC}s"
    )

    state = load_state()
    escalated_alerted = {}  # bead_id -> last escalation alert timestamp

    # Initial snapshot for diagnostics
    beads   = list_inflight_beads()
    sessions = list_active_sessions()
    bead_count    = len(beads)    if beads    is not None else -1
    session_count = len(sessions) if sessions is not None else -1
    print(
        f"[INFLIGHT-RECLAIM] [STARTUP] inflight={bead_count} "
        f"live_sessions={session_count} state_entries={len(state)}",
        flush=True)

    while True:
        try:
            inflight_count, stranded_count = run_cycle(state, escalated_alerted)
            save_state(state)
            # Per-cycle summary (goes to launchd .out log — low noise, high observability)
            print(
                f"[INFLIGHT-RECLAIM] cycle: inflight={inflight_count} "
                f"stranded={stranded_count}",
                flush=True)
        except Exception as exc:
            # Never crash the guard loop
            print(f"[INFLIGHT-RECLAIM] cycle exception: {exc}", flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    if "--selftest" in _sys.argv:
        ok = _selftest()
        _sys.exit(0 if ok else 1)
    main()
