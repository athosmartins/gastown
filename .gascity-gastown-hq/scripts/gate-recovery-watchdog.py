#!/usr/bin/env python3
"""Self-healing gate watchdog — SPAWNS A DEDICATED REPAIR AGENT, Athos is FYI-only.

Philosophy (per Athos, 2026-06-07; sharpened 2026-06-11 / ga-afytf): a serious
problem must not merely ping the human who can't fix it. Autonomy does not require
a 100%-automatic fix — it requires WAKING AN AGENT that investigates and resolves
without depending on the Mayor being awake. So on detect this watchdog now SPAWNS
a dedicated repair agent (a gastown.dog) and hands it the runbook + diagnostics;
the agent runs the recovery ladder itself and escalates to the human only if it
fails. The Mayor is a FALLBACK (woken only if a repair agent could not be spawned),
not the primary actor. Athos is notified as a courtesy FYI ("detectei X, despachei
reparo") and paged LOUDLY only as a last resort if recovery never lands.

This is the "automatic crew member" that the 2026-06-07 outage lacked: the gate
died at ~20:00 and was only fixed hours later because a human crew member happened
to notice and mailed the Mayor. This watchdog is that noticer — in minutes — and
now also the dispatcher of the fixer, so recovery does not wait on the Mayor.

DETECTS (gate not producing verdicts — the tonight signature):
  - 2+ "Gate FAILED: TIMEOUT" in the dispatcher log within TIMEOUT_WINDOW, OR
  - a marker stuck gate-status:dispatching past DISPATCH_STUCK_SEC while every
    gate-reviewer session sits non-active (spawned but never materialized).
  Corroborated by Dolt instability lines in the supervisor log (connection reset /
  bead store closed / invalid connection) — the root cause that night.

DETECTS (head-of-line stale-branch block — the ga-hl0gq signature, 2026-06-10):
  - the dispatcher keeps re-picking the SAME oldest branch every sweep, its
    auto-rebase conflicts (dead author), it re-queues gate-status:queued, and the
    whole queue behind it stops draining (zero merges). Signature: the last
    >=HEADOFLINE_MIN_SWEEPS "Dispatcher sweep complete" lines are all
    "verdict=QUEUED (retry ...)" naming the SAME branch.
  This mode is INVISIBLE to the two checks above: no run reaches verdict
  collection, so there is no TIMEOUT and no "Verdicts 0/N" poll line — which is
  exactly why the 2026-06-10 stall ran 49min before a human asked for status.
  Detected here in ~2 sweeps (~6min). The permanent dispatcher-level auto-skip is
  ga-q3ig2; this wake is the detection+recovery bridge until it lands.

DETECTS (orphaned queued marker — the gt-mqkwj signature, 2026-06-12):
  - a gate-status:queued marker created during a dispatcher OUTAGE (a gap with no
    'sweep complete' lines) whose gate_run was dropped, so on recovery the
    dispatcher LEAPFROGS it for newer markers — it never gets dispatched, its
    source bead sits in_progress forever, and the pool reconciler re-spawns a
    worker onto already-finished work ~6x. INVISIBLE to all three checks above:
    not 'dispatching' (stuck_dispatching blind), no TIMEOUT (recent_timeouts
    blind), and not head-of-line (the queue drains for OTHER branches, so
    headofline_stall sees verdicts advancing for those).
  Signature (orphaned_queued_marker): a queued marker that is (a) older than
    ORPHAN_MIN_AGE_SEC, (b) NEVER mentioned in the recent dispatcher log, while
    (c) the dispatcher is actively draining (newest 'sweep complete' is fresh)
    and (d) a strictly-NEWER queued marker's branch IS mentioned — proof the
    dispatcher leapfrogged the older one. The leapfrog proof (d) is what keeps a
    normal FIFO backlog behind a slow run — many markers older than the newest
    completed sweep, but none actually skipped — from false-firing.

ON DETECT:
  1. snapshot diagnostics to /tmp/gate-watchdog-diag-<ts>.txt
  2. SPAWN a dedicated repair agent: route the runbook (referencing the
     gate-reviewer-spawn-failure-playbook memory + the known fix) as a task bead to
     the gastown.dog pool AND spawn a dog directly (gc session new) so recovery does
     not depend on the demand-reconciler, which the gate-down failure mode can itself
     wedge. The agent collects diagnostics, runs the runbook (kickstart supervisor,
     kill+re-convene a frozen reviewer, check rig-path/Dolt), and escalates to Athos
     via notify if it cannot recover. If spawning fails, FALL BACK to waking the Mayor.
  3. notify Athos FYI (low priority): "gate travou, despachei agente de reparo".
  4. cooldown WAKE_COOLDOWN before dispatching another repair cycle.

ESCALATE (last resort): if still broken after ESCALATE_AFTER_WAKES repair-cycles,
fire ntfy 🚨 -p 5 to Athos — autonomous recovery couldn't fix it, a human is needed.

Recovers silently: when a Gate PASSED appears after a dispatch, reset state (solved).
Never crashes (every external call guarded); silence = healthy.
"""
import json, time, datetime, subprocess, os, re, inspect
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _grw_ledger

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
SUPERVISOR_LOG = "/Users/athos/.gc/supervisor.log"
SITE_TOML = os.path.join(CITY, ".gc/site.toml")
NOTIFY = "/Users/athos/.local/bin/notify"
DOG_TEMPLATE = "gastown.dog"   # utility pool the repair agent is spawned into (ga-afytf)
QUOTA_CHECK = os.path.join(CITY, "scripts/claude-quota-check.sh")  # ground-truth quota verdict (ga-wjlv9)
BD_LIST_CACHED = os.path.join(CITY, "scripts/bd-list-cached.sh")  # ga-h199q: read-cache shim (ga-48xcv) — drop-in ["bash", BD_LIST_CACHED] prefix replaces "bd" at read-only (list/show) call sites; only-list/show/query safety boundary lives in the shim itself, so a write accidentally routed through it still passes straight to the real bd, unaffected

POLL_SEC = 120  # ga-8smq3: was 60; all thresholds below are 12-40min, so 120s loses no detection latency while halving this daemon's Dolt poll load
TIMEOUT_WINDOW_SEC = 1800      # 2+ timeouts within 30min = gate not producing verdicts
DISPATCH_STUCK_SEC = 720       # marker dispatching >12min w/ no active reviewers = spawn fail
PILOT_JAM_WINDOW_SEC = 900     # 2+ sweep-aborts within 15min = Pilot jammed on a bad bead
PILOT_STALL_SEC = 2400         # pilot log silent >40min = Pilot dead/not sweeping
GRW_WAKE_GRACE = os.environ.get("GRW_WAKE_GRACE", "1") != "0"  # ga-m1o5: suppress a stall verdict a machine sleep can fully explain (mirrors daemon-presence-watchdog.sh's DPW_WAKE_GRACE)
HEADOFLINE_MIN_SWEEPS = 2      # >=2 consecutive QUEUED-retry sweeps on the SAME branch = head-of-line block
HEADOFLINE_LOG_FRESH_SEC = 600 # ignore if dispatcher log is staler than this (that's ENGINE-STALL's job)
ORPHAN_LOG_FRESH_SEC = 600     # dispatcher log must be live (process still writing) — else ENGINE-STALL's job
ORPHAN_DRAIN_FRESH_SEC = 1200  # newest COMPLETED sweep within 20min = dispatcher actively draining (not wedged on one run)
ORPHAN_MIN_AGE_SEC = 1800      # a queued marker must sit >=30min unmentioned before we call it skipped (rules out a just-created marker)
WAKE_COOLDOWN_SEC = int(os.environ.get("WAKE_COOLDOWN_SEC", "1200"))   # base: don't dispatch a new repair for the SAME condition more than once per 20min
ESCALATE_AFTER_WAKES = int(os.environ.get("ESCALATE_AFTER_WAKES", "2"))  # after N unresolved repair-cycles for one condition, page Athos 🚨

# ---- RUNAWAY GOVERNOR knobs (ga-wisp-q9b3as2: the watchdog spawned ~28 repair
#      dogs — 6 for the SAME marker — because nothing deduped, capped, or backed
#      off; their collective bd/gc poll load became a PRIMARY Dolt-CPU driver that
#      WORSENED the reviewer boot-stall the watchdog was reacting to → it spawned
#      MORE. These bound the loop. All env-overridable; defaults are conservative). ----
GRW_ENABLED = os.environ.get("GRW_ENABLED", "1") != "0"          # kill switch: "0" = detect+log only, never spawn/wake
GRW_DRY_RUN = os.environ.get("GRW_DRY_RUN", "0") == "1"          # "1" = log the spawn decision but do not actually spawn (observability/test)
MAX_ACTIVE_REPAIR_DOGS = int(os.environ.get("MAX_ACTIVE_REPAIR_DOGS", "3"))   # hard cap: never spawn while >= this many watchdog repair dogs are already live
MAX_SPAWNS_PER_CONDITION = int(os.environ.get("MAX_SPAWNS_PER_CONDITION", "3"))  # after N spawns for the SAME condition (no recovery), stop spawning; notify-once only
REPAIR_DOG_STALE_SEC = int(os.environ.get("REPAIR_DOG_STALE_SEC", "3600"))    # a repair dog older than this no longer counts (assumed done/reaped) for dedup+cap
WAKE_BACKOFF_MAX_SEC = int(os.environ.get("WAKE_BACKOFF_MAX_SEC", "7200"))    # exponential per-condition cooldown backoff is capped here (2h)
REPAIR_DUAL_SPAWN = os.environ.get("REPAIR_DUAL_SPAWN", "0") == "1"           # "0" (default) = direct-spawn first, sling durable bead ONLY if direct fails (halves load); "1" = legacy always-both

# ---- DIRECT SELF-HEAL knobs (the two toils the Mayor fixed BY HAND ~6x/day) ----
# Unlike the spawn-a-dog / wake-the-Mayor detectors above, these two features
# perform the recovery MUTATION DIRECTLY (the same `bd close/update/label` +
# `gc session close` the Mayor ran by hand) so the gate self-heals without waiting
# on a dog (which itself can hang) or a Mayor (who may be asleep). Both are bounded,
# fail-SAFE (any query error → skip, never a blind mutation), honor GRW_DRY_RUN
# (log the decision, mutate nothing — used for the live sanity pass) and the
# GRW_ENABLED master kill-switch. They are cheap bd ops, so they run every sweep
# even while the spawn-detectors are infra-throttled (a reap FREES load; a fail-safe
# skip fires automatically if Dolt is wedged and the queries fail).
#
# FIX 1 — auto-reap a HUNG gate-reviewer / stale gate-status:running gate-run.
GRW_REAP_HUNG_ENABLED = os.environ.get("GRW_REAP_HUNG_ENABLED", "1") != "0"
REVIEW_HANG_MINUTES = int(os.environ.get("GRW_REVIEW_HANG_MINUTES", "18"))       # a run must be >this old before reap is even considered — well above a normal 9-min review and below the guard's 55m/90m TTLs so the toil is caught EARLY, not after 30-40m
REAP_MAX_PER_SWEEP = int(os.environ.get("GRW_REAP_MAX_PER_SWEEP", "3"))          # hard cap on hung-run reaps per sweep
LIVENESS_RESAMPLE_SEC = int(os.environ.get("GRW_LIVENESS_RESAMPLE_SEC", "8"))    # gap between the two liveness samples that confirm SUSTAINED-idle (never reap on a single snapshot — a real review can blip asleep between heartbeats)
# FIX 2 — auto-requeue a STUCK gate-status:error marker (error → queued).
GRW_REQUEUE_ERROR_ENABLED = os.environ.get("GRW_REQUEUE_ERROR_ENABLED", "1") != "0"
ERROR_REQUEUE_MINUTES = int(os.environ.get("GRW_ERROR_REQUEUE_MINUTES", "8"))    # a marker must sit in error >this before requeue, so a transient error self-clears on the dispatcher's own next sweep first
ERROR_REQUEUE_MAX_PER_SWEEP = int(os.environ.get("GRW_ERROR_REQUEUE_MAX_PER_SWEEP", "5"))
ERROR_REQUEUE_MAX_ATTEMPTS = int(os.environ.get("GRW_ERROR_REQUEUE_MAX_ATTEMPTS", "3"))  # after K watchdog-requeues of the SAME marker (it keeps re-erroring), STOP and escalate to the Mayor — mirror the gate's own fix-attempt cap philosophy instead of an infinite requeue loop
# FIX 3 — kill a FROZEN gate-reviewer (state=active but last_active silent past the
# threshold). reap_hung_runs (FIX 1) CANNOT catch this: its reviewer reads active, so
# hung_run_verdict returns skip:reviewer-active. The dispatcher's own ga-q8tmn detects
# the freeze and re-convenes, but only MAX_RESPAWNS_PER_SLOT (2) times — after that it
# waits the full 45m outer timeout. That is the ~90-min stall the Mayor cleared by hand
# with `gc session kill` (2026-07-02: reviewer 6ohacd silent 34m, queue starved to
# 531m). A working reviewer refreshes last_active on EVERY tool call, so >this-many
# seconds of silence is a wedged Claude. `gc session kill` makes the reconciler revive
# it in place (same id, fresh runtime → the dispatcher's slot ref stays valid). This is
# the BACKSTOP after the dispatcher gives up, so the threshold sits WELL past its
# ~9-min diff-scaled detection + 2 respawns.
GRW_REAP_FROZEN_ENABLED = os.environ.get("GRW_REAP_FROZEN_ENABLED", "1") != "0"
FROZEN_KILL_SECS = int(os.environ.get("GRW_FROZEN_KILL_SECS", "900"))            # 15min of last_active silence on a STILL-active reviewer = definitively wedged (past the dispatcher's own detect+respawn cycle); SUSTAINED-confirmed on a resample before any kill
FROZEN_KILL_MAX_PER_SWEEP = int(os.environ.get("GRW_FROZEN_KILL_MAX_PER_SWEEP", "2"))  # blast-radius cap: if MANY reviewers are silent at once (systemic Dolt/quota outage) killing them only churns — cap it and let the infra detectors + Mayor escalation handle a mass outage
GRW_FROZEN_REQUEUE_ENABLED = os.environ.get("GRW_FROZEN_REQUEUE_ENABLED", "1") != "0"  # ga-pp5vh: after FIX 3 kills a confirmed-frozen reviewer, ALSO supersede+requeue its now-orphaned run if that reviewer was the run's sole pending one — closing the ~15min(kill)->~29min(dispatcher Phase C timeout) gap that zeroed gate throughput 2026-07-22. Independent toggle from GRW_REAP_FROZEN_ENABLED so the requeue extension can be killed without disabling the frozen-reviewer kill itself.
# FIX 4 — reap a QUEUED marker whose SOURCE is done, and clear a STALE gate:reviewing
# label that STARVES a queued marker. Root (2026-07-02, a 9h head-of-line stall): a
# reviewer that DRAINS during startup leaves `gate:reviewing` on its SOURCE bead with
# NO terminal path to clear it → the dispatcher skips re-dispatch ("already in review")
# → the marker starves forever (wa-ya17c queued 572min). Separately, several markers'
# SOURCES had already CLOSED (work merged) but the queued markers were never reaped —
# phantom queue depth that inflates the "oldest queued" alarm. FIX 1/2 don't cover a
# gate-status:queued marker (they handle running-run reaps + gate-status:error). The
# Mayor cleaned both by hand; this makes it durable.
GRW_REAP_ORPHAN_ENABLED = os.environ.get("GRW_REAP_ORPHAN_ENABLED", "1") != "0"
ORPHAN_MARKER_MIN_MINUTES = int(os.environ.get("GRW_ORPHAN_MARKER_MIN_MINUTES", "15"))  # a marker must be queued >this before FIX4 touches it — so a normal spin-up (source briefly gate:reviewing before the marker flips to dispatching) is never mistaken for a stale leak
ORPHAN_MAX_PER_SWEEP = int(os.environ.get("GRW_ORPHAN_MAX_PER_SWEEP", "8"))
# FIX 5 — recover a STRANDED-VERDICT run: gate-status:running with ALL required verdicts
# DELIVERED but never finalized (the managing dispatcher sweep died post-verdict → the
# run sits 'running' forever, the source keeps a stale gate:reviewing → the kanban shows
# a phantom 'em revisão' with NO live reviewer; wa-99jug 2026-07-02). reap_hung_runs
# (FIX 1) SKIPS this — it requires 0 delivered verdicts (a delivered verdict reads as
# 'producing'). Recovery = supersede the run + clear the source's stale gate:reviewing +
# re-queue the marker so a fresh sweep re-reviews and finalizes cleanly (merge on PASS,
# needs-fix on FAIL — the watchdog never duplicates that crown-jewel logic). Per-marker
# attempt cap → escalate to needs-human if a marker keeps stranding.
GRW_REAP_STRANDED_ENABLED = os.environ.get("GRW_REAP_STRANDED_ENABLED", "1") != "0"
STRANDED_RUN_MINUTES = int(os.environ.get("GRW_STRANDED_RUN_MINUTES", "5"))       # ga-5t5w: minutes since the LAST VERDICT was DELIVERED (not run creation — see stranded_verdict_verdict). A healthy finalize is seconds after the last verdict; 5min (~1-2 dispatcher Phase C sweeps) past = the managing sweep is dead. SUSTAINED-confirmed on a resample first.
STRANDED_MAX_ATTEMPTS = int(os.environ.get("GRW_STRANDED_MAX_ATTEMPTS", "2"))     # after K recoveries of the SAME marker (finalize keeps dying), escalate to needs-human instead of another futile re-review
GRW_STRANDED_LABEL_RE = re.compile(r"^grw-stranded:(\d+)$")                        # restart-safe per-marker stranded-recovery counter
RECOVERY_LOG = os.path.join(CITY, ".gc/logs/gate-recovery-actions.jsonl")        # durable jsonl audit of every direct reap/requeue (evidence)
GRW_REQUEUE_LABEL_RE = re.compile(r"^grw-requeue:(\d+)$")                          # restart-safe per-marker requeue counter, stamped on the marker as a label
# FIX 6 — requeue a STRANDED dispatching|reviewing MARKER whose reviewer DIED leaving
# NO open running gate-run (wa-ppe5v, 3× in one session 2026-07-07: wa-b7z7c/wa-jpuu6/
# wa-u3ay1). When a reviewer dies mid-review (drain / machine-sleep / quota / crash),
# the dispatcher does not always leave a running gate-run for FIX 1/5 to reap — it died
# DURING dispatch (marker gate-status:dispatching, run never created) OR the run was
# already closed while the marker never advanced — so the marker sits dispatching|
# reviewing FOREVER. FIX 1 only reaps running RUNS, FIX 4 only touches queued/ready/
# claimed MARKERS, FIX 3 only kills active-but-silent reviewers, and stuck_dispatching()
# only fires while the dispatcher is ACTIVELY polling a live run. Meanwhile the Pilot's
# _beadid_has_active_gate_artifact counts dispatching|reviewing as ACTIVE → it DROPS the
# gate:needs-fix source bead as 'already gating' → the bead is orphaned (never re-
# dispatched NOR re-reviewed) until the Mayor re-slings by hand. Recovery = requeue the
# marker (→ gate-status:queued: a fresh dispatcher sweep re-reviews the EXISTING branch,
# no rebuild) + clear the source's leaked gate:reviewing. A live/hung RUN (has_open_run)
# hands off to FIX 1/5 untouched; a per-marker attempt cap escalates to needs-human if
# reviewers keep dying on the same branch. Sustained-confirmed on a resample; fail-safe.
GRW_REAP_STALE_REVIEW_ENABLED = os.environ.get("GRW_REAP_STALE_REVIEW_ENABLED", "1") != "0"
STALE_REVIEW_MARKER_MINUTES = int(os.environ.get("GRW_STALE_REVIEW_MARKER_MINUTES", "15"))  # a marker must sit dispatching|reviewing >this WITH NO open run before requeue — well past a normal spin-up (a run is created within seconds), so an in-flight dispatch is never mistaken for a dead one
STALE_REVIEW_MAX_PER_SWEEP = int(os.environ.get("GRW_STALE_REVIEW_MAX_PER_SWEEP", "5"))
STALE_REVIEW_MAX_ATTEMPTS = int(os.environ.get("GRW_STALE_REVIEW_MAX_ATTEMPTS", "3"))  # after K requeues of the SAME marker (reviewers keep dying on this branch), escalate to needs-human instead of an infinite re-review loop
GRW_STALE_REVIEW_LABEL_RE = re.compile(r"^grw-stale-review:(\d+)$")                 # restart-safe per-marker stale-review requeue counter
# FIX 7 — recover a gate-status:deferred marker (ga-y1kk). quality-gate-dispatcher.sh's
# Step 3 (and quality-gate-guard.sh's own Step 5 copy) fail-safes to gate-status:deferred
# when AUTHOR cannot be derived (no gate.submitted_by metadata on the marker, no
# assignee/created_by/owner on the source bead) — and NOTHING else ever re-reads
# gate-status:deferred; only gate-status:queued is swept. Confirmed live: marker
# ga-wisp-5zki27 sat deferred 77+ minutes until a human manually ran
# `bd update --set-metadata gate.submitted_by=...` + relabeled it back to queued —
# exactly the action this FIX now takes automatically. Unlike FIX 2's transient
# gate-status:error, a blind requeue here is unlikely to help — the marker got stuck
# BECAUSE no author field resolved, so a bare retry just dead-ends right back into
# deferred — so this only requeues once the source bead (or the marker itself, via a
# partial manual recovery) actually has a derivable author. If it never grows one
# across DEFERRED_REQUEUE_MAX_ATTEMPTS sweeps, the marker is closed with an explicit
# reason instead of rotting silently — but never on a single sweep's query blip;
# unresolvability must be confirmed sustained across multiple polls first.
GRW_REQUEUE_DEFERRED_ENABLED = os.environ.get("GRW_REQUEUE_DEFERRED_ENABLED", "1") != "0"
DEFERRED_REQUEUE_MINUTES = int(os.environ.get("GRW_DEFERRED_REQUEUE_MINUTES", "8"))    # a marker must sit deferred >this before we even look — gives a human/automation time to write gate.submitted_by first
DEFERRED_REQUEUE_MAX_PER_SWEEP = int(os.environ.get("GRW_DEFERRED_REQUEUE_MAX_PER_SWEEP", "5"))
DEFERRED_REQUEUE_MAX_ATTEMPTS = int(os.environ.get("GRW_DEFERRED_REQUEUE_MAX_ATTEMPTS", "3"))  # after K sweeps with no derivable author found (or K re-defers despite one), stop: close if never resolvable, escalate if it keeps re-deferring anyway
GRW_DEFER_REQUEUE_LABEL_RE = re.compile(r"^grw-defer-requeue:(\d+)$")               # restart-safe per-marker attempt counter — separate budget from FIX 2's grw-requeue: (a marker can pass through error AND deferred across its lifetime)
# FIX 8 — clear a PHANTOM gate:queued/gate:reviewing label on a SOURCE bead: no open
# type:quality-gate-marker references it AT ALL (ga-yzw06). Stronger than FIX 4's
# clear-stale-reviewing, which requires a real QUEUED marker to exist (just contradicted
# by the source's own gate:reviewing). Here there is no marker whatsoever — the label is
# pure phantom, and it strands the bead on BOTH sides: Pilot's ingate filter skips any
# bead carrying a gate:* label (assumes it's already in the gate), and the gate
# dispatcher only drains from markers, sees none, and does nothing. Measured live
# (ga-tje7u): 2 days silent, discovered only because a human happened to ask for a
# status readout. Deliberately label-only — see reap_orphan_gate_labels()'s docstring
# for why story:*/status/assignee are never touched.
GRW_REAP_ORPHAN_GATE_LABEL_ENABLED = os.environ.get("GRW_REAP_ORPHAN_GATE_LABEL_ENABLED", "1") != "0"
ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD = int(os.environ.get("GRW_ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD", "3"))  # consecutive sweeps (>=this many POLL_SEC apart) a (bead,label) pair must be seen unreferenced before FIX 8 clears it — mirrors orphan-sweep.sh's CONFIRM_THRESHOLD hysteresis; a marker gate-done.md JUST created may not yet be visible to this sweep's query (replication lag), so a single miss must never be enough to act. orphan-sweep.sh found its own CONFIRM_THRESHOLD=2 insufficient (ga-kq4jf) and had to add a second signal — FIX 8 has no equivalent second signal available, so it starts one step more conservative at 3.
ORPHAN_GATE_LABEL_MAX_PER_SWEEP = int(os.environ.get("GRW_ORPHAN_GATE_LABEL_MAX_PER_SWEEP", "5"))
# FIX 9 — recover/escalate a permanently-parked gate-status:needs-rebase marker
# (ga-7b19e). Unlike FIX 2's transient gate-status:error, needs-rebase is reached
# ONLY after the gate itself already confirmed a deterministic conflict (dead
# author, or MAX_REBASE_ATTEMPTS exhausted — quality-gate-dispatcher.sh's own
# needs-rebase bounce sites document "a rebase retry fails identically"). A blind
# requeue would therefore just reproduce the IDENTICAL conflict for nothing — so
# this fix NEVER requeues (contrast FIX 2/FIX 7, both safe retries of a plausibly-
# transient state). It only auto-closes the marker when independently proven moot
# (source bead already closed, or the branch already landed/vanished per
# _branch_merged_state), and otherwise ESCALATES once per cooldown window with the
# marker's age — a permanent SILENT park was the actual bug: measured live in the
# gastown rig, 9 markers piled up at needs-rebase, the oldest 10 days, one
# (wa-juety) holding a real Athos-approved bead hostage 5 days with zero signal
# anywhere (not even gate-throughput-stall-watchdog.sh, which deliberately excludes
# needs-rebase from its "active" count by design). pilot-dispatcher.sh's
# _filter_built excludes a needs-rebase-parked bead via TWO INDEPENDENT paths — the
# open marker itself (_beadid_has_open_gate_marker), AND, if mirrored, the source
# bead's own gate:needs-rebase label — so closing the marker alone is not always
# enough; the close path below also best-effort strips that label from the source
# bead (label-only, same FIX 8 scope discipline: never touches story:*/status/
# assignee). Branch deletion/rebuild/re-anchor stays a human/Mayor decision, same
# as the existing dead-author re-anchor doctrine — this fix never pushes/deletes a
# branch; see the FIX 9 selftest's static source guard.
GRW_RECOVER_NEEDS_REBASE_ENABLED = os.environ.get("GRW_RECOVER_NEEDS_REBASE_ENABLED", "1") != "0"
NEEDS_REBASE_AGE_MINUTES = int(os.environ.get("GRW_NEEDS_REBASE_AGE_MINUTES", "15"))    # a marker must sit needs-rebase >this before the FIRST escalation — mirrors FIX2/FIX7's young-skip window (gives an already-in-progress manual fix time to land first). Deliberately short: the measured failure mode is SILENCE OVER DAYS, not noise over minutes — see NEEDS_REBASE_ALERT_COOLDOWN_SEC for the much longer re-escalation spacing.
NEEDS_REBASE_MAX_PER_SWEEP = int(os.environ.get("GRW_NEEDS_REBASE_MAX_PER_SWEEP", "5"))
NEEDS_REBASE_ALERT_COOLDOWN_SEC = int(os.environ.get("GRW_NEEDS_REBASE_ALERT_COOLDOWN_SEC", "21600"))  # 6h — mirrors gate-merge-survival-sweep.sh's ALERT_COOLDOWN for the same "keep reminding about a stuck condition that needs a human DECISION, not a fix-attempt" shape; a 2h default (WAKE_BACKOFF_MAX_SEC) would re-page too often for a marker whose own text says "Needs re-anchor/rebuild or a Mayor decision" — this is not urgent-minute-by-minute, it is P3-with-a-known-workaround (the Mayor's own framing on wa-juety)
# A repair dog's session title (set by the watchdog's --title-hint, and kept by the
# dog after it self-renames because the dog naturally echoes the branch/condition)
# matched broadly so we also catch dogs spawned before this process started (restart
# amnesia) or pre-fix pile-ups. Over-matching is the SAFE direction (more skips).
REPAIR_DOG_TITLE_RE = re.compile(
    r"gate[- ]orphan|gate[- ]watchdog|\bREPAIR\b|\breparo\b|marker stuck|marcador .*travado|"
    r"head[- ]of[- ]line|branch stale|branch travado|pilot trav|pilot .*jam|supervisor init|"
    r"init[- ]failure|init failure|gate stall|gate heartbeat|zero merges|sem revisores",
    re.IGNORECASE)
DOLT_SIG = re.compile(r"connection reset|bead store closed|unexpected EOF|invalid connection|provider-health registry unavailable")
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
# "=== Dispatcher sweep complete: branch=<X> verdict=QUEUED (retry N/M, dead author) ==="
SWEEP_QUEUED_RETRY_RE = re.compile(r"Dispatcher sweep complete: branch=(\S+) verdict=QUEUED \(retry")
SWEEP_COMPLETE_RE = re.compile(r"Dispatcher sweep complete: branch=(\S+) verdict=")
MARKER_BRANCH_RE = re.compile(r"^branch:(.+)$")  # marker label form: branch:crew/<rig>-<name>/<bead>  (gt-mqkwj)
# supervisor init-failure loop (ga-h3w2y): a rig with no `path` in site.toml makes
# the supervisor cycle "init failure #N" / "validate rigs: rig \"X\": path is
# required" and NOTHING spawns town-wide. The supervisor.log lines carry no
# [timestamp] prefix, so freshness is judged by the recent tail + a config cross-
# check (the config is STILL broken now) to avoid firing on stale post-fix tails.
SUP_INIT_FAIL_RE = re.compile(r"init failure #\d+")
SUP_VALIDATE_RIGS_RE = re.compile(r"validate rigs:\s*(.+?)(?:\s+see:|\s*\(skipping\)|$)")
SUP_INIT_FAIL_MIN = 2          # >=2 'init failure #' lines in the recent tail = active loop
RIG_HEADER_RE = re.compile(r"^\s*\[\[\s*rig\s*\]\]\s*$")
RIG_TABLE_RE = re.compile(r"^\s*\[")
RIG_KV_RE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"')


def sh(args, timeout=20, stdin=None):
    try:
        return subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def quota_verdict():
    """Ground-truth Claude-quota line for the Mayor's wake-up (ga-wjlv9).

    The 2026-06-10 night was lost diagnosing a gate stall as 'quota exhausted'
    without being able to verify it (it was NOT quota — only 22% used). Every
    wake message below tells the Mayor to go fix the INFRA; lead each one with
    the real quota verdict so the Mayor can rule quota in/out FIRST instead of
    chasing the wrong cause. Fail-safe: any error returns an explicit unknown
    line, never blocks the wake."""
    r = sh([QUOTA_CHECK, "--line"], timeout=18)
    if r is not None and r.returncode in (0, 2):
        line = (r.stdout or "").strip().splitlines()
        if line and line[0].startswith("QUOTA:"):
            tag = "🔴" if r.returncode == 2 else "🟢"
            return "%s %s\n   (fonte: claude-quota-check.sh --line — sinal de verdade do transcript, não chute)\n\n" % (tag, line[0])
    return ("QUOTA: (check indisponível — rode `%s` manualmente p/ confirmar antes de assumir cota)\n\n"
            % QUOTA_CHECK)


def log_ts_epoch(line):
    m = TS_RE.search(line)
    if not m:
        return None
    try:
        # dispatcher log is local time (UTC-3); compare via naive local epoch
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


_SYSCTL_SEC_RE = re.compile(r" sec = (\d+)")  # leading space anchors the `sec` field, not `usec`'s


def secs_since_avail(now):
    """Seconds the machine has been awake-and-up since it last became available,
    i.e. now - max(boot_epoch, wake_epoch). Ports daemon-presence-watchdog.sh's
    _secs_since_avail (ga-m1o5) so the Pilot-silence stall check gets the same
    sleep/wake grace its heartbeat-WEDGE check already has: while asleep, launchd
    suspends every StartInterval timer (Pilot's included), so a stale pilot log
    proves nothing about Pilot's health until the machine has been up at least as
    long as the stall threshold. Returns None if neither sysctl parses (caller
    must fail OPEN — no grace, not a false 'never stalls' suppression)."""
    latest = 0
    for key in ("kern.boottime", "kern.waketime"):
        r = sh(["sysctl", "-n", key], timeout=5)
        if r is None or r.returncode != 0:
            continue
        m = _SYSCTL_SEC_RE.search(r.stdout or "")
        if m:
            v = int(m.group(1))
            if v > latest:
                latest = v
    return (now - latest) if latest > 0 else None


def recent_timeouts():
    """count of 'Gate FAILED: TIMEOUT' in dispatcher log within TIMEOUT_WINDOW_SEC."""
    try:
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-4000:]
    except Exception:
        return 0, None
    now = time.time()
    hits = []
    for l in lines:
        if "Gate FAILED: TIMEOUT" in l:
            e = log_ts_epoch(l)
            if e and now - e < TIMEOUT_WINDOW_SEC:
                hits.append(e)
    return len(hits), (max(hits) if hits else None)


def last_pass_epoch():
    try:
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-4000:]
    except Exception:
        return 0
    for l in reversed(lines):
        if "Gate PASSED:" in l:
            return log_ts_epoch(l) or 0
    return 0


def stuck_dispatching():
    """True only if the dispatcher is ACTIVELY polling a run that is stuck: the most
    recent dispatcher-log line is a 'Verdicts: 0/N (elapsed: Y)' with Y past threshold,
    the log is fresh (dispatcher still polling, not moved on / between runs), AND no
    gate-reviewer session is active. Keying on the LIVE poll (not a marker label) means a
    stranded 'gate-status:dispatching' marker — e.g. left by a killed dispatcher during
    maintenance — does NOT false-fire. A slow-but-working run (reviewers still active) is
    also not flagged here; the consecutive-TIMEOUT signal covers alive-but-not-delivering."""
    try:
        if time.time() - os.path.getmtime(DISPATCH_LOG) > 120:
            return False  # dispatcher not actively writing → between runs (ENGINE-STALL covers dead)
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-15:]
    except Exception:
        return False
    vm = None
    for l in reversed(lines):
        if "sweep complete" in l:   # the most recent run already concluded → not stuck
            return False
        mm = re.search(r"Verdicts:\s*(\d+)/(\d+)\s*received\s*\(elapsed:\s*(\d+)s\)", l)
        if mm:
            vm = mm
            break
    if not vm:
        return False
    got, elapsed = int(vm.group(1)), int(vm.group(3))
    if not (got == 0 and elapsed > DISPATCH_STUCK_SEC):
        return False
    # corroborate: reviewers spawned for this run are NOT active (dead/start-pending)
    rs = sh(["gc", "session", "list", "--json"])
    try:
        sessions = json.loads(rs.stdout).get("sessions", []) if rs else []
    except Exception:
        return False
    active = [s for s in sessions if s.get("template") == "gate-reviewer" and s.get("state") == "active"]
    return len(active) == 0


def gate_infra_throttled():
    """True if the gate dispatcher is ALIVE but currently DEFERRING on INFRA
    (Dolt-CPU hot or quota), i.e. throttled — NOT wedged. A repair dog cannot
    lower Dolt CPU or restore quota, so the gate-repair detectors (gate:down,
    head-of-line, orphan) must NOT fire while this is true — that is the source
    of the futile 'taskless' dogs (ga-htjni follow-up / dog investigation
    2026-06-15). Requires a FRESH log: a dead/wedged dispatcher has a stale log
    → returns False → ENGINE-STALL / gate:down still fire (a real wedge is never
    masked). Reads the most-recent headroom decision: a fresh 'Headroom OK' or
    'sweep complete' seen first means the gate is admitting/progressing → False."""
    try:
        if time.time() - os.path.getmtime(DISPATCH_LOG) > 180:
            return False  # stale log → not actively throttling; let other detectors judge
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-25:]
    except Exception:
        return False
    for l in reversed(lines):
        if "Headroom OK" in l or "sweep complete" in l:
            return False  # most recent decision = admitting / concluded → not throttled now
        if "Headroom DEFER" in l and ("dolt-hot" in l or "quota-limited" in l or "cota=LIMITED" in l):
            return True
    return False


def headofline_stall():
    """Detect the stale-branch FIFO head-of-line block (ga-hl0gq).

    The dispatcher picks the oldest queued marker every sweep; if that branch is
    stale vs origin/main and its auto-rebase conflicts with a dead/empty author,
    the marker is re-queued gate-status:queued and the SAME branch is re-picked
    next sweep — the queue behind it never drains (zero merges). The dispatcher
    keeps logging (no ENGINE-STALL) and no run reaches verdicts (no TIMEOUT, no
    'Verdicts 0/N' poll line), so recent_timeouts()/stuck_dispatching() are blind.

    Signature: walking the dispatcher log's 'sweep complete' lines from newest to
    oldest, the trailing run names the SAME branch with 'verdict=QUEUED (retry'.
    Returns (branch, count) when count >= HEADOFLINE_MIN_SWEEPS, else (None, 0).
    Requires a fresh log (dispatcher actively sweeping) — a stale log is dead-
    engine territory, covered by the health-monitor's ENGINE-STALL."""
    try:
        if time.time() - os.path.getmtime(DISPATCH_LOG) > HEADOFLINE_LOG_FRESH_SEC:
            return (None, 0)
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-400:]
    except Exception:
        return (None, 0)
    branch = None
    count = 0
    for l in reversed(lines):
        if "Dispatcher sweep complete:" not in l:
            continue
        mq = SWEEP_QUEUED_RETRY_RE.search(l)
        if not mq:
            # most-recent completion is NOT a QUEUED-retry (a real PASS/FAIL/merge
            # happened, or a different terminal verdict) → not stalled right now.
            break
        b = mq.group(1)
        if branch is None:
            branch = b
        if b != branch:
            break  # head-of-line moved to a different branch → not a single-branch wedge
        count += 1
    if branch and count >= HEADOFLINE_MIN_SWEEPS:
        return (branch, count)
    return (None, 0)


def _iso_epoch(s):
    """Parse a bd ISO-8601 UTC timestamp ('2026-06-12T23:09:12Z') to a true Unix
    epoch, comparable with log_ts_epoch() (which returns the true epoch of a
    LOCAL dispatcher-log timestamp). Both are absolute Unix epochs, so they
    compare directly across the timezone difference. Returns None on failure."""
    if not s:
        return None
    try:
        dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None


def _last_active_epoch(s):
    """Parse a `gc session list --json` last_active to a true Unix epoch. Unlike bd's
    UTC-'Z' timestamps (handled by _iso_epoch), session last_active carries a tz OFFSET
    ('2026-07-02T16:06:29-03:00') — fromisoformat handles both. Returns None on
    empty/unparseable (fail-safe: a session we cannot age is NEVER treated as frozen)."""
    if not s:
        return None
    try:
        t = s.strip()
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def frozen_reviewer_verdict(state, silence_sec, threshold_sec):
    """PURE decision (no I/O, set -e safe, unit-tested) for FIX 3. 'kill' iff the
    reviewer session is state=active AND has been silent (no last_active refresh) for
    >= threshold; else 'keep'. Fail-safe toward KEEP: a non-active state (the hung-run
    reaper / dispatcher own it), or a None/negative silence (unparseable/future
    last_active) never kills."""
    if str(state or "").lower() != "active":
        return "keep"
    if silence_sec is None or silence_sec < 0:
        return "keep"
    return "kill" if silence_sec >= threshold_sec else "keep"


def frozen_reviewer_run_verdict(pending_names, killed_identities):
    """PURE decision (no I/O, unit-tested) for FIX 3's post-kill run/marker recovery
    (ga-pp5vh): given a gate-run's set of PENDING (not-yet-delivered) reviewer names
    and the just-killed session's set of identifier strings (session_name/name/alias/
    agent_name/id — the same key set _session_index uses), decide whether this run
    should be superseded + its marker requeued right now, or left for FIX 1/timeout.
      'supersede'          — the killed session was pending AND the ONLY pending
                             reviewer on this run — nobody else can ever land a
                             verdict, so the run is provably stuck.
      'skip:not-pending'   — the killed session had already delivered its verdict (or
                             was never assigned to this run) — nothing to recover here.
      'skip:other-pending' — another reviewer is still pending on this run → it may
                             still finish; killing ONE dead reviewer must never
                             terminate a run others are still actively working.
      'skip:query-failed'  — pending_names is None (the verdict query failed) →
                             fail-safe, never supersede blind."""
    if pending_names is None:
        return "skip:query-failed"
    if not (pending_names & killed_identities):
        return "skip:not-pending"
    if len(pending_names) > 1:
        return "skip:other-pending"
    return "supersede"


def _queued_markers():
    """[(id, branch, created_epoch), ...] for every OPEN gate-status:queued
    marker. --all is required to surface the normally-hidden gate-marker type,
    but it also lifts bd's default closed-issue hiding — so a marker closed via
    the ad-hoc withdrawal path (e.g. "WITHDRAWN as duplicate") that kept its
    gate-status:queued label would otherwise be indistinguishable from a
    genuinely stuck open one. Filtered at both the query (--status) and parse
    (status check) layers, since a future query refactor could silently drop
    the CLI flag (ga-huke4). Returns [] on any error (fail-safe: no markers →
    no orphan fire)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "--status", "open,in_progress",  # ga-h199q
            "-l", "type:quality-gate-marker", "-l", "gate-status:queued", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return []
    try:
        rows = json.loads(r.stdout)
    except Exception:
        return []
    out = []
    for row in rows or []:
        if row.get("status") not in ("open", "in_progress"):
            continue  # stale label on a closed/withdrawn marker (ga-huke4)
        branch = None
        for lb in (row.get("labels") or []):
            m = MARKER_BRANCH_RE.match(lb)
            if m:
                branch = m.group(1)
                break
        out.append((row.get("id"), branch, _iso_epoch(row.get("created_at"))))
    return out


def _dispatcher_log_state(tail=3000):
    """(sweep_complete_epochs, log_text, log_fresh) for the dispatcher log.

    sweep_complete_epochs: every 'sweep complete' timestamp in the tail (used to
      judge whether the dispatcher is actively DRAINING vs wedged on one run).
    log_text: the joined tail (scanned for branch mentions — substring match).
    log_fresh: the log file was written within ORPHAN_LOG_FRESH_SEC (process alive)."""
    try:
        fresh = time.time() - os.path.getmtime(DISPATCH_LOG) <= ORPHAN_LOG_FRESH_SEC
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-tail:]
    except Exception:
        return ([], "", False)
    epochs = []
    for l in lines:
        if "sweep complete" in l:
            e = log_ts_epoch(l)
            if e:
                epochs.append(e)
    return (epochs, "".join(lines), fresh)


def _detect_orphan_markers(markers, sweep_epochs, log_text, now):
    """Pure core of orphaned_queued_marker() (separated for the selftest).

    Returns the orphaned queued markers as [(id, branch, age_sec), ...], oldest
    first. A marker is an orphan when ALL hold:
      (drain) the dispatcher is actively draining — the newest 'sweep complete'
              is within ORPHAN_DRAIN_FRESH_SEC. If the last completed sweep is
              stale, the dispatcher is wedged on its CURRENT run (a different
              failure mode: timeout / drained-reviewer / engine-stall), not
              leapfrogging — so we stay silent.
      (a)     the marker has sat queued >= ORPHAN_MIN_AGE_SEC (not just created).
      (b)     its branch is NEVER mentioned in the recent dispatcher log (zero
              dispatch attempts — its gate_run was dropped during the outage).
      (d)     a strictly-NEWER queued marker's branch IS mentioned — PROOF the
              dispatcher leapfrogged this older one. This is the guard that
              distinguishes a true orphan from a normal FIFO backlog stuck behind
              a slow run: in a healthy backlog the OLDEST unmentioned marker is
              simply next-up and no newer marker is being worked ahead of it.
      (head)  ONLY the FIFO-oldest queued marker is eligible. A non-head marker is
              by definition FIFO-blocked behind an older one (the dispatcher takes
              one marker per sweep, oldest-first) — NOT orphaned. This is the guard
              that kills the recurring false positive (wa-68su / ga-te7es: a #2
              marker flagged 'orphan' while the OLDER head was being actively gated
              or yielding to a live sibling run; refs
              [[gate-orphan-watchdog-false-positive-headofline-block]],
              [[ga-te7es-gate-orphan-falsepos-sibling-headofline]]). A true
              gt-mqkwj orphan (its gate_run dropped in an outage) is always the
              oldest still-queued marker, so this loses no real detection."""
    if not sweep_epochs:
        return []
    if now - max(sweep_epochs) > ORPHAN_DRAIN_FRESH_SEC:
        return []  # dispatcher not actively draining → not this failure mode
    valid = [(mid, b, c) for (mid, b, c) in markers if mid and b and c]
    valid.sort(key=lambda m: m[2])  # oldest first
    if not valid:
        return []
    # (head) only the FIFO-oldest queued marker can be an orphan; everything newer
    # is FIFO-blocked behind it, not skipped. Evaluating only valid[0] is what
    # suppresses the head-of-line false positive that drove the 6x-same-marker loop.
    mid, branch, created = valid[0]
    if now - created < ORPHAN_MIN_AGE_SEC:
        return []
    if branch in log_text:
        return []  # head mentioned → being / already dispatched (or actively gated), not orphaned
    leapfrogged = any(c2 > created and b2 != branch and b2 in log_text
                      for (_m2, b2, c2) in valid)
    if not leapfrogged:
        return []
    return [(mid, branch, int(now - created))]


def orphaned_queued_marker():
    """Detect a gate-status:queued marker whose gate_run was dropped during a
    dispatcher outage and is now being leapfrogged (gt-mqkwj). Returns
    (marker_id, branch, age_sec) for the OLDEST orphan, else (None, None, 0).
    Fail-safe: any gather error returns no orphan (never wakes spuriously)."""
    sweep_epochs, log_text, log_fresh = _dispatcher_log_state()
    if not log_fresh or not sweep_epochs:
        return (None, None, 0)  # log not live → dead engine, ENGINE-STALL's job
    orphans = _detect_orphan_markers(_queued_markers(), sweep_epochs, log_text, time.time())
    if not orphans:
        return (None, None, 0)
    orphans.sort(key=lambda o: o[2], reverse=True)  # oldest (largest age) first
    return orphans[0]


def dolt_instability():
    """count of Dolt-instability signature lines in the tail of the supervisor log."""
    try:
        with open(SUPERVISOR_LOG) as f:
            try:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 200000))
            except Exception:
                pass
            tail = f.read()
    except Exception:
        return 0
    return len(DOLT_SIG.findall(tail))


def _rig_paths_invalid():
    """Return a short description of site.toml rig-path problems, or "" if valid.

    Self-contained zero-dependency parse (no tomllib) so this works on the
    plist's /usr/bin/python3. Mirrors the engine's `ValidateRigs` ("path is
    required") plus a path-exists check. Used to cross-check the supervisor
    init-failure tail: we only treat the loop as actionable while the config is
    STILL broken — when the Mayor restores the path, this returns "" and the
    signal clears (recovery)."""
    rigs = []
    cur = None
    try:
        with open(SITE_TOML, errors="replace") as f:
            for line in f:
                if RIG_HEADER_RE.match(line):
                    if cur is not None:
                        rigs.append(cur)
                    cur = {"name": None, "path": None, "has_path": False}
                    continue
                if RIG_TABLE_RE.match(line):
                    if cur is not None:
                        rigs.append(cur)
                    cur = None
                    continue
                if cur is None:
                    continue
                m = RIG_KV_RE.match(line)
                if m:
                    if m.group(1) == "name":
                        cur["name"] = m.group(2)
                    elif m.group(1) == "path":
                        cur["path"] = m.group(2)
                        cur["has_path"] = True
        if cur is not None:
            rigs.append(cur)
    except Exception:
        return ""  # unreadable config → don't fire (avoid false positive)
    probs = []
    for r in rigs:
        name = r.get("name") or "(unnamed)"
        p = r.get("path")
        if not r.get("has_path") or not p:
            probs.append("%s: sem path" % name)
        elif not os.path.isdir(p):
            probs.append("%s: path inexistente (%s)" % (name, p))
    return "; ".join(probs)


def supervisor_init_failure():
    """Detect the ga-h3w2y spawn-outage: the supervisor cycling on init-failure
    because a rig lacks a `path` in site.toml. Returns (reason, detail) when the
    recent supervisor.log tail shows the loop AND the config is STILL invalid
    now; else (None, ""). The config cross-check is what keeps a stale post-fix
    tail (or a non-config init failure already handled elsewhere) from firing."""
    try:
        with open(SUPERVISOR_LOG, errors="replace") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 200000))
            lines = f.read().splitlines()[-400:]
    except Exception:
        return (None, "")
    fails = sum(1 for l in lines if SUP_INIT_FAIL_RE.search(l))
    if fails < SUP_INIT_FAIL_MIN:
        return (None, "")
    invalid = _rig_paths_invalid()
    if not invalid:
        return (None, "")  # loop in tail but config valid now → resolved / not config
    verr = ""
    for l in reversed(lines):
        m = SUP_VALIDATE_RIGS_RE.search(l)
        if m:
            verr = m.group(1).strip()
            break
    return ("supervisor init-failure loop (%s)" % (verr or "validate rigs"), invalid)


def mayor_session():
    rs = sh(["gc", "session", "list", "--json"])
    if not rs or rs.returncode != 0:
        return None
    try:
        for s in json.loads(rs.stdout).get("sessions", []):
            if s.get("template") == "gastown.mayor":
                return s.get("id")
    except Exception:
        return None
    return None


def pilot_stall_verdict(silence_sec, avail_age_sec, threshold_sec, wake_grace=True):
    """PURE decision (no I/O, unit-tested) for the pilot-log-silence half of
    pilot_jammed(). True iff the pilot log has been silent >= threshold_sec AND
    that silence is NOT fully explained by the machine having just woken/booted.
    A wake/boot less than threshold_sec ago (avail_age_sec < threshold_sec) means
    the log could not possibly have advanced yet regardless of Pilot's health —
    suppress (False). avail_age_sec is None (neither sysctl parsed) fails OPEN:
    no grace, judge on silence alone — same fail-safe direction as the other
    *_verdict helpers in this file, just inverted (missing data must never mask
    a real stall)."""
    if silence_sec is None or silence_sec <= threshold_sec:
        return False
    if wake_grace and avail_age_sec is not None and avail_age_sec < threshold_sec:
        return False
    return True


def pilot_jammed():
    """(jammed, reason). Detects the Pilot failing to dispatch — the gap that left a
    jam undetected for ~8h on 2026-06-08. Two modes:
      (a) sweep-abort: 2+ 'aborting dispatch' / 'gc sling failed' lines in the pilot log
          within PILOT_JAM_WINDOW (one bad bead — e.g. accented title — jams every sweep).
      (b) stall: pilot log silent > PILOT_STALL_SEC (Pilot dead / not sweeping), unless
          a machine sleep/wake fully explains the silence (ga-m1o5 — see
          pilot_stall_verdict / secs_since_avail)."""
    try:
        mtime = os.path.getmtime(PILOT_LOG)
    except Exception:
        return (False, "")
    now = time.time()
    if pilot_stall_verdict(now - mtime, secs_since_avail(now), PILOT_STALL_SEC, GRW_WAKE_GRACE):
        return (True, "Pilot parou de varrer (log silencioso >%dmin) — pode estar morto" % (PILOT_STALL_SEC // 60))
    try:
        with open(PILOT_LOG) as f:
            lines = f.readlines()[-80:]
    except Exception:
        return (False, "")
    aborts = 0
    for l in lines:
        if ("aborting dispatch" in l) or ("gc sling failed" in l):
            e = log_ts_epoch(l)
            if e and now - e < PILOT_JAM_WINDOW_SEC:
                aborts += 1
    if aborts >= 2:
        return (True, "Pilot abortou a varredura %dx em %dmin (gc sling falhou num bead) — nao despacha"
                % (aborts, PILOT_JAM_WINDOW_SEC // 60))
    return (False, "")


def snapshot(reason, dolt_hits):
    ts = time.strftime("%Y%m%d-%H%M%S")
    path = "/tmp/gate-watchdog-diag-%s.txt" % ts
    try:
        with open(path, "w") as f:
            f.write("GATE WATCHDOG DIAGNOSTIC %s\nreason: %s\ndolt_instability_lines: %d\n\n"
                    % (ts, reason, dolt_hits))
            for title, args in [
                # ga-xwza2: routed through the read-cache shim, same as the other 13
                # call sites in this file (ga-h199q) — this is a diagnostic dump
                # (triggered only on anomaly detection, not the routine poll path),
                # not a read-after-write.
                ("queued markers", ["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l",
                                    "type:quality-gate-marker", "-l", "gate-status:queued", "--json"]),
                ("dispatching markers", ["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l",
                                         "type:quality-gate-marker", "-l", "gate-status:dispatching", "--json"]),
                ("sessions", ["gc", "session", "list"]),
            ]:
                r = sh(args)
                f.write("== %s ==\n%s\n\n" % (title, (r.stdout if r else "(failed)")))
            r = sh(["tail", "-30", SUPERVISOR_LOG], timeout=10)
            f.write("== supervisor.log tail ==\n%s\n" % (r.stdout if r else "(failed)"))
            r = sh(["tail", "-20", DISPATCH_LOG], timeout=10)
            f.write("== dispatcher.log tail ==\n%s\n" % (r.stdout if r else "(failed)"))
    except Exception:
        pass
    return path


# Prepended to the runbook when it is handed to a freshly-spawned repair dog so it
# knows the bead IS its task (not a formula to look up) and how to close out cleanly.
REPAIR_HEADER = (
    "🔧 TAREFA DE REPARO AUTÔNOMO — despachada automaticamente pelo gate-recovery-watchdog.\n"
    "Você é o agente de reparo dedicado deste incidente. NÃO procure uma fórmula: a sua "
    "tarefa é executar o RUNBOOK abaixo do início ao fim, verificando entre os passos. "
    "Trabalhe sozinho e com autonomia — o Mayor pode estar dormindo, NÃO dependa dele. "
    "Sequência: (1) colete o diagnóstico (já há um snapshot no caminho citado abaixo; "
    "aprofunde com os greps do runbook), (2) rode o runbook, (3) se RESOLVER, avise via "
    "`notify -p 3 'gate recuperado'`, (4) se NÃO conseguir, escale pro humano com "
    "`notify 🚨 -p 5` E mande mail pro Mayor com o diagnóstico. Ao terminar (resolvido OU "
    "escalado), feche este bead (`gc bd close <id> --reason ...`) e saia "
    "(`gc runtime drain-ack && exit`).\n\n"
    "========== RUNBOOK ==========\n"
)


def repair_runbook(reason, diag_path, dolt_hits, kind="gate"):
    """The per-kind recovery runbook text. Shared by spawn_repair_agent() (as the
    repair bead's description) and wake_mayor() (as the fallback nudge body) so the
    instructions never drift between the two paths."""
    if kind == "pilot":
        return (
            "O Pilot parou de despachar trabalho. Motivo detectado: %s.\nDiagnóstico já coletado em: %s\n\n"
            "Causa-raiz mais provável (lição de 2026-06-08): o `gc sling` rejeita títulos com acento/travessão "
            "('Incorrect string value \\xC3 for column title') e o Pilot ABORTA a varredura inteira por causa de "
            "um bead ruim → não despacha nada. Veja a memória [[post-outage-remaining-tech-debt]] item 6.\n\n"
            "CONSERTO (verificando entre os passos):\n"
            "1. tail -20 .gc/logs/pilot-dispatcher.log → ache 'gc sling failed for <bead> — aborting dispatch'.\n"
            "2. Se for charset: bd -C . update <bead-culpado> --title '<versão SEM acento/travessão>' (de-acentue).\n"
            "3. Se o log estiver silencioso (Pilot morto): launchctl kickstart -k gui/$(id -u)/com.gascity.pilot.\n"
            "4. Dispare: launchctl kickstart gui/$(id -u)/com.gascity.pilot ; confirme 'dispatched=N' (N>0) na próxima varredura.\n\n"
            "Se destravar, avise (notify -p 3). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir destravar."
        ) % (reason, diag_path)
    if kind == "gate-loop":
        return (
            "O gate está preso no MESMO branch stale há vários sweeps: %s. "
            "O auto-rebase bate em conflito (autor morto/ausente), o marker re-enfileira gate-status:queued, "
            "e a FILA INTEIRA atrás dele NÃO drena — zero merges. Foi exatamente o stall de 49min de 2026-06-10 (ga-hl0gq).\n\n"
            "CONSERTO (re-anchor OU supersede — memória [[gate-rebase-error-stale-branch]]):\n"
            "1. Ache o marker do branch travado:\n"
            "   bd -C . list --all -l type:quality-gate-marker -l gate-status:queued --json | "
            "jq -r '.[] | select((.labels//[])[]|contains(\"branch:%s\")) | .id'\n"
            "2. DECIDA o caminho:\n"
            "   (a) Branch ainda quer mergear → RE-ANCHOR: num worktree em origin/main, cherry-pick o commit do branch, "
            "keep-both em conflito de teste, verifique diff additivo (0 deleções), force-push sobre o branch stale, e RE-QUEUE o MESMO marker "
            "(remove gate-status:error/queued antigo, add gate-status:queued) — NÃO duplique.\n"
            "   (b) Branch é zombie/obsoleto → SUPERSEDE: set_gate_status do marker p/ superseded + close, e re-despache fresh se a história ainda vale.\n"
            "3. O objetivo imediato é TIRAR o branch quebrado da cabeça da fila pra os markers saudáveis atrás dele drenarem JÁ.\n"
            "4. Confirme: nos próximos sweeps aparecem 'Gate PASSED' / outros branches avançando (não só QUEUED-retry no mesmo branch).\n\n"
            "Diagnóstico salvo em: %s\n"
            "Se destravar, avise (notify -p 4). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir.\n"
            "(Fix permanente do auto-skip no dispatcher = ga-q3ig2 — este reparo é a ponte de detecção+recuperação até ele aterrissar. "
            "Cuidado: o contador gate:rebase-attempt reseta a 0 todo sweep, então o escape de 3-strikes do dispatcher nunca dispara — por isso loopa pra sempre.)"
        ) % (reason, reason, diag_path)
    if kind == "supervisor":
        return (
            "O supervisor está ciclando em init-failure: %s. Config inválido detectado em site.toml: %s.\n"
            "Diagnóstico: %s\n\n"
            "Causa-raiz (incidente ga-h3w2y de 2026-06-10): um rig sem `path` no .gc/site.toml (esquecido numa "
            "migração city.toml→site.toml) faz o supervisor falhar `validate rigs: rig \"X\": path is required` "
            "e entrar em loop → NADA spawna town-wide (gate-reviewers + dogs presos em start-pending). "
            "Achar isso à mão custou ~1h; quota/Dolt/bd-hooks foram pistas FALSAS.\n\n"
            "CONSERTO (verificando entre os passos):\n"
            "1. Confirme o rig culpado: `gc doctor --json | jq '.checks[] | select(.name==\"config-valid\")'` "
            "ou `grep 'validate rigs' ~/.gc/supervisor.log | tail`.\n"
            "2. Restaure o `path` do rig em .gc/site.toml — cada `[[rig]]` precisa de `name=` E "
            "`path=\"/Users/athos/gt/<rig>\"` (o path TEM que existir no disco). NÃO invente; use o diretório canônico.\n"
            "3. Re-valide com `gc doctor` (check config-valid verde) e dispare o supervisor: "
            "`launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor`.\n"
            "4. Confirme: as sessões voltam a spawnar (saem de start-pending). "
            "(O supervisor-config-guard já tenta `gc doctor --fix` sozinho; se a config exige um path que só você "
            "sabe, este wake é pra você restaurá-lo.)\n"
        ) % (reason, dolt_hits, diag_path)
    if kind == "gate-orphan":
        # `reason` carries the orphan branch; `dolt_hits` carries the marker id.
        return (
            "Um marker gate-status:queued ÓRFÃO foi detectado: branch %s (marker %s). "
            "O gate_run dele foi DERRUBADO durante uma janela de outage do dispatcher (um buraco "
            "sem linhas 'sweep complete' no log), então na recuperação o dispatcher PULA esse marker "
            "antigo e despacha os mais novos — ele nunca roda, o bead de origem fica in_progress pra "
            "SEMPRE, e o reconciler re-spawna worker em cima de trabalho já feito ~6x (incidente gt-mqkwj, "
            "irmão de [[ga-hl0gq-gate-stall-detection-fix]]).\n\n"
            "DIAGNÓSTICO (confirme que É órfão antes de agir):\n"
            "1. Veja o marker: `bd -C . show %s --json | jq '.[0]|{id,status,created_at,labels}'` "
            "(deve estar gate-status:queued, antigo, com source-bead:<X>).\n"
            "2. Confirme ZERO menções do branch no log: "
            "`grep -c '%s' .gc/logs/quality-gate-dispatcher.log` → se 0, o dispatcher nunca tentou despachá-lo.\n"
            "3. Confirme que o dispatcher está DRENANDO outros branches (há 'sweep complete' recente p/ branches "
            "DIFERENTES) — senão NÃO é órfão, é o run atual travado (outro modo de falha; não mexa).\n\n"
            "CONSERTO — DECIDA pelo estado do branch:\n"
            "  (a) Branch AINDA quer mergear (código não landou): RE-QUEUE o MESMO marker p/ o dispatcher "
            "redespachá-lo com um run fresco — remova e re-adicione gate-status:queued "
            "(`bd -C . update %s --remove-label gate-status:queued && bd -C . update %s --add-label gate-status:queued`) "
            "pra refrescar o created_at e tirá-lo da cabeça órfã da fila. NÃO duplique o marker. "
            "Confirme no próximo sweep que o branch aparece sendo despachado.\n"
            "  (b) Branch JÁ mergeou / é zumbi (código já está em origin/main): SUPERSEDE — feche o marker "
            "(`bd -C . close %s --reason 'orphan run dropped; work already landed (gt-mqkwj)'`) E feche o "
            "source-bead in_progress (veja o label source-bead:<X> do marker; `bd -C . close <X> --reason "
            "'merged; orphan marker superseded (gt-mqkwj)'`) pra PARAR o reconciler de re-spawnar worker.\n"
            "3. O objetivo é tirar o marker órfão do limbo: ou ele roda (re-queue) ou some (supersede+close) — "
            "em ambos os casos o bead de origem deixa de ficar preso in_progress.\n\n"
            "Diagnóstico salvo em: %s\n"
            "Se resolver, avise (notify -p 3). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir.\n"
            "(Fix permanente seria o dispatcher detectar markers sem gate_run e re-criar o run — esta detecção+reparo "
            "é a ponte até lá.)"
        ) % (reason, dolt_hits, dolt_hits, reason, dolt_hits, dolt_hits, dolt_hits, diag_path)
    return (
        "O gate parou de produzir vereditos. Motivo detectado: %s. "
        "Linhas de instabilidade do Dolt no supervisor.log: %d.\n"
        "Diagnóstico já coletado em: %s\n\n"
        "Causa-raiz mais provável (lição de 2026-06-07): instabilidade de conexão do Dolt da cidade (:52756) "
        "→ supervisor não computa a demanda de gate-reviewer → revisores nascem e morrem (start-pending) → "
        "todo run dá TIMEOUT. Rode o diagnostic ladder COMPLETO da memória [[gate-reviewer-spawn-failure-playbook]].\n\n"
        "CONSERTO (na ordem, verificando entre os passos):\n"
        "0. COTA PRIMEIRO (lição de 2026-06-10, ga-wjlv9): rode `scripts/claude-quota-check.sh --line` (ou --json). "
        "Se disser LIMITED, É cota — espere o reset, NÃO persiga infra (a noite de 2026-06-10 foi perdida diagnosticando "
        "um stall como cota sem poder confirmar — e NÃO era cota). Se 'not limited', NÃO é cota → siga pros passos de infra abaixo.\n"
        "1. Colete diagnóstico: grep -E 'connection reset|bead store closed|invalid connection' ~/.gc/supervisor.log | tail\n"
        "2. Reviewer congelado/boot-wedged? `gc session list | grep gate-reviewer` — se algum está start-pending/asleep "
        "segurando o slot, mate-o (`gc session kill <id>`) e deixe o dispatcher re-convocá-lo; veja [[ga-mepb0]] (re-convene + stagger spawns).\n"
        "3. Menos invasivo: launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor ; espere 30s ; "
        "dispare um gate run (launchctl kickstart gui/$(id -u)/com.gascity.quality-gate-dispatcher) e veja se os "
        "revisores ficam 'active' e os vereditos sobem.\n"
        "4. Ainda quebrado? Cheque rig-path/hooks/binário (passos 1-3 do ladder da memória acima) e então "
        "gc dolt restart (da pasta da cidade) — preserva dados, bd volta na hora — depois kickstart do supervisor de novo, e re-verifique um run.\n"
        "5. Confirme com um run REAL passando ponta-a-ponta (3/3 vereditos → PASS). "
        "Sondas ad-hoc (gc session new sem tarefa) saem sozinhas, não servem de teste.\n\n"
        "Se recuperar, avise (notify -p 3). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir recuperar."
    ) % (reason, dolt_hits, diag_path)


def spawn_repair_agent(reason, diag_path, dolt_hits, kind="gate"):
    """PRIMARY recovery action (ga-afytf): dispatch a dedicated autonomous repair
    agent that runs the runbook itself, instead of depending on the Mayor being
    awake. GUARANTEES that some actor is engaged and returns a short status string
    for the operator notification. Never raises — every external call is guarded.

    Recovery ladder:
      1. Route a DURABLE repair task bead to the dog pool (`gc sling --stdin`:
         first line = title, rest = the runbook the dog executes).
      2. DIRECTLY spawn a repair dog (`gc session new --no-attach`) so recovery does
         not wait on the demand-reconciler — which the gate-down failure mode (Dolt
         instability → supervisor can't compute pool demand) can itself wedge. A
         racing reconciler-spawned dog simply finds no work and exits (claims atomic).
      3. If a worker could NOT be directly materialized, WAKE THE MAYOR as the
         human-judgment fallback. Otherwise a routed-but-unworked bead would sit idle
         behind a wedged reconciler in exactly the failure mode this targets. (The
         earlier version returned on sling-success alone and DISCARDED the direct
         spawn's result, so a failed insurance spawn went unnoticed and the Mayor
         fallback never fired — the gate could stay down with no actor at all.)

    The sling title is kept ASCII — rich/emoji detail lives in the body — because the
    `title` column has rejected non-ASCII before (the Pilot charset abort that aborts
    a whole dispatch sweep; the description body carries no such constraint).

    Returns (status_str, session_id_or_None). The session_id lets the caller record
    the spawned dog in the governor ledger so a follow-up detection for the SAME
    condition dedups against THIS dog instead of spawning a sibling (the 6x-same-
    marker root). When REPAIR_DUAL_SPAWN is off (default) the durable sling bead is
    only routed if the direct spawn FAILED — so a healthy spawn produces ONE dog,
    not two, halving the load this watchdog adds."""
    safe_reason = reason.encode("ascii", "replace").decode("ascii")
    title = "REPAIR gate-watchdog (%s): %s" % (kind, safe_reason)
    payload = title + "\n\n" + REPAIR_HEADER + repair_runbook(reason, diag_path, dolt_hits, kind)

    def _sling():
        r = sh(["gc", "sling", DOG_TEMPLATE, "--stdin", "--json"], stdin=payload, timeout=45)
        return r is not None and r.returncode == 0

    def _direct():
        # ga-0bigf ROOT FIX: a dog spawned via `gc session new` carries ONLY a
        # title hint — NO bead is routed to it, and `gc session new` sets
        # GC_SESSION_ORIGIN=manual, so the dog's Step-1c routed-pool probe is a
        # no-op (the dog peeks confirm: "Routed pool work (1c): skipped — origin=
        # manual"). Step 1a/1b find nothing either, because nothing was assigned to
        # the session. Result: the repair dog boots TASKLESS with an empty hook and
        # sits idle (the exact ga-0bigf complaint), while the real mission lived only
        # in the _sling() payload that — with REPAIR_DUAL_SPAWN off (default) — was
        # never routed because _direct() "succeeded".
        #
        # The three spawners that DO deliver reliably (gate-reviewer, refino-gate
        # reviewer, auto-refiner) all wire the ga-67hae DURABLE-PULL channel after
        # `gc session new`: capture the new session_name, create a task bead, assign
        # it to that session_name (status in_progress) and embed the task as a
        # comment. Step 1a/1b match `assignee` against $GC_SESSION_NAME/$GC_ALIAS and
        # are NOT origin-gated, so a manual-origin session pulls the work durably.
        # Mirror that here: spawn → create durable repair bead → assign to the
        # session_name + embed the runbook. The dog now boots WITH its mission.
        s = sh(["gc", "session", "new", DOG_TEMPLATE, "--no-attach", "--json",
                "--title-hint", "reparo %s: %s" % (kind, safe_reason[:50])], timeout=45)
        if not s or s.returncode != 0:
            return (False, None)
        sid = None
        sname = None
        try:
            j = json.loads(s.stdout) or {}
            sid = j.get("session_id")
            # `gc session new --json` returns session_name; fall back to alias/agent_name.
            sname = j.get("session_name") or j.get("alias") or j.get("agent_name")
        except Exception:
            sid = None
            sname = None
        # ga-0bigf durable-pull wiring: without a session_name we cannot assign the
        # task, so the dog would boot taskless — treat that as a FAILED direct spawn
        # so the caller falls through to _sling() (durable routed bead) + Mayor
        # fallback rather than leaving an idle dog. The spawned session is harmless:
        # finding no work, a dog drain-acks/exits (or, manual-origin, sits idle
        # briefly until reaped) — far better than the silent taskless-forever state.
        if not sname:
            return (False, sid)
        # Create the durable repair bead and assign it to THIS session so the dog's
        # Step 1a/1b deliver it. The runbook is large, so pass the description via
        # --stdin (NOT argv) to dodge arg-length limits and quoting. `bd create` has
        # no --status flag (this bd version), so set in_progress in a follow-up
        # `bd update` — exactly what the gate/refino/auto-refino spawners do. Best-
        # effort + guarded: if the CREATE fails we report the spawn as un-delivered
        # (False) so the caller routes the _sling() insurance bead + Mayor fallback;
        # the in_progress update is non-fatal (an assigned `open` bead is still found
        # by Step 1b — status only affects Step 1a).
        body = REPAIR_HEADER + repair_runbook(reason, diag_path, dolt_hits, kind)
        cr = sh(["bd", "-C", CITY, "create", title, "-t", "task",
                 "--assignee", sname, "--stdin", "--json"], stdin=body, timeout=45)
        if not cr or cr.returncode != 0:
            return (False, sid)
        repair_bead_id = None
        try:
            cj = json.loads(cr.stdout)
            repair_bead_id = (cj[0] if isinstance(cj, list) and cj else cj).get("id")
        except Exception:
            repair_bead_id = None
        if repair_bead_id:
            # in_progress + (re)assert assignee so Step 1a (assigned in-progress) is
            # the dog's first hit, mirroring the verdict-bead durable-pull wiring.
            sh(["bd", "-C", CITY, "update", repair_bead_id,
                "--assignee", sname, "--status", "in_progress", "-q"], timeout=30)
        return (True, sid)

    routed = False
    if REPAIR_DUAL_SPAWN:
        routed = _sling()   # legacy: always route a durable bead first
    materialized, sid = _direct()
    if materialized:
        return ("agente de reparo despachado" + ("" if (routed or not REPAIR_DUAL_SPAWN) else " (aviso: bead nao enfileirou)"), sid)
    # No worker materialized directly — route the durable bead now (insurance) and do
    # NOT trust a possibly-wedged reconciler to pick it up: wake the Mayor as fallback.
    if not routed:
        routed = _sling()
    woke = wake_mayor(reason, diag_path, dolt_hits, kind)
    if woke:
        return ("reparo enfileirado + Mayor acordado (fallback)" if routed else "Mayor acordado (fallback)", None)
    return ("reparo so enfileirado — sem worker, Mayor ausente" if routed else "FALHA: sem worker e sem Mayor", None)


def wake_mayor(reason, diag_path, dolt_hits, kind="gate"):
    """FALLBACK only: used when a dedicated repair agent could NOT be spawned. Wakes
    the Mayor (if awake) and hands off the same runbook for manual recovery."""
    mid = mayor_session()
    if not mid:
        return False
    task = (
        quota_verdict()  # lead the wake with the real quota verdict (ga-wjlv9): rule quota in/out FIRST
        + "🔧 ALERTA AUTOMÁTICO DO WATCHDOG — não consegui spawnar um agente de reparo, "
        "então te acordei como FALLBACK. Conserta agora, não escale pro Athos a menos que falhe.\n\n"
        + repair_runbook(reason, diag_path, dolt_hits, kind)
    )
    sh(["gc", "session", "wake", mid], timeout=20)
    r = sh(["gc", "session", "nudge", mid, task], timeout=25)
    return r is not None and r.returncode == 0


def notify(msg, prio):
    sh([NOTIFY, "-t", "Gate watchdog", "-p", str(prio), msg], timeout=10)


def _session_list_json():
    """[session-dict, ...] or None on query failure (None is distinct from an empty
    list — the governor treats None as 'cannot verify' and fail-safe SKIPS spawning,
    so a Dolt/gc outage can never become a blind-spawn amplifier)."""
    rs = sh(["gc", "session", "list", "--json"])
    if not rs or rs.returncode != 0:
        return None
    try:
        return json.loads(rs.stdout).get("sessions", [])
    except Exception:
        return None


def cond_for(kind, reason, marker_id=None, branch=None):
    """(cond_key, dedup_tokens) for a detected condition. cond_key keys the
    cooldown/backoff/spawn-count state; dedup_tokens are substrings whose presence
    in a LIVE repair-dog title means 'already being worked' (skip). For branch/
    marker-bearing kinds the tokens are the branch + marker id (precise, and they
    survive the dog's self-rename because the dog echoes the branch). For singleton
    kinds the key is fixed (one repair at a time) and tokens are kind signatures."""
    if kind == "gate-orphan":
        key = "gate-orphan:%s" % (branch or marker_id or "?")
        return (key, [t for t in (branch, marker_id) if t])
    if kind == "gate-loop":
        return ("gate-loop:%s" % (branch or reason or "?"), [t for t in (branch,) if t])
    if kind == "pilot":
        return ("pilot:jam", ["pilot"])
    if kind == "supervisor":
        return ("supervisor:initfail", ["supervisor init", "init-failure", "init failure"])
    return ("gate:down", ["marker stuck", "marcador", "sem revisores", "no active reviewer", "stuck"])


def _is_repair_dog(s):
    return s.get("template") == DOG_TEMPLATE and not s.get("closed") \
        and bool(REPAIR_DOG_TITLE_RE.search(s.get("title") or ""))


def _session_fresh(s, now):
    e = _iso_epoch(s.get("created_at"))
    if e is None:
        return True  # unknown age → assume fresh (counts toward cap = safe direction)
    return (now - e) <= REPAIR_DOG_STALE_SEC


class Governor:
    """Bounds watchdog repair-dog spawning: dedup (same condition already worked),
    a hard concurrent cap, and a per-condition cooldown with exponential back-off +
    spawn-count self-limit. Holds in-memory ledger of session_ids it spawned
    (keyed by cond) so dedup is exact go-forward; title matching is the secondary
    net for pre-fix pile-ups / restart amnesia. Pure-decision methods are unit-tested."""

    def __init__(self):
        self.ledger = {}        # cond_key -> [(session_id, spawn_epoch), ...]
        self.last_spawn = {}    # cond_key -> epoch of last spawn
        self.spawn_count = {}   # cond_key -> spawns since last recovery
        self.cooldown = {}      # cond_key -> current effective cooldown sec (back-off)
        self.escalated = {}     # cond_key -> epoch of last 🚨 (rate-limit the page)

    # ---- live repair-dog accounting ----
    def _ledger_live(self, cond_key, sessions, now):
        """session_ids this governor spawned for cond_key that are still present,
        not closed, and not stale."""
        by_id = {s.get("id"): s for s in sessions}
        live = []
        for (sid, _ts) in self.ledger.get(cond_key, []):
            s = by_id.get(sid)
            if s and not s.get("closed") and _session_fresh(s, now):
                live.append(sid)
        return live

    def active_repair_dogs(self, sessions, now):
        """Set of session_ids that are live watchdog repair dogs (ledger ∪ title-
        matched), for the concurrent cap. Union → robust across restart + rename."""
        ids = set()
        for s in sessions:
            if _is_repair_dog(s) and _session_fresh(s, now):
                ids.add(s.get("id"))
        for cond, entries in self.ledger.items():
            by_id = {s.get("id"): s for s in sessions}
            for (sid, _ts) in entries:
                s = by_id.get(sid)
                if s and not s.get("closed") and _session_fresh(s, now):
                    ids.add(sid)
        return ids

    def _dedup_hit(self, cond_key, dedup_tokens, sessions, now):
        if self._ledger_live(cond_key, sessions, now):
            return True
        toks = [t.lower() for t in (dedup_tokens or []) if t]
        if not toks:
            return False
        for s in sessions:
            if s.get("template") != DOG_TEMPLATE or s.get("closed"):
                continue
            if not _session_fresh(s, now):
                continue
            title = (s.get("title") or "").lower()
            if any(t in title for t in toks):
                return True
        return False

    def decide(self, cond_key, dedup_tokens, sessions, now):
        """(allow: bool, reason: str). Order: kill-switch → unavailable-session-list
        fail-safe → cooldown/back-off → per-condition spawn cap (self-limit) → dedup
        → global concurrent cap."""
        if not GRW_ENABLED:
            return (False, "disabled (GRW_ENABLED=0)")
        if sessions is None:
            return (False, "session-list unavailable — fail-safe skip (no blind spawn)")
        cd = self.cooldown.get(cond_key, WAKE_COOLDOWN_SEC)
        last = self.last_spawn.get(cond_key, 0)
        if now - last < cd:
            return (False, "cooldown %ds left" % int(cd - (now - last)))
        if self.spawn_count.get(cond_key, 0) >= MAX_SPAWNS_PER_CONDITION:
            return (False, "maxspawn (%d reached for condition; self-limiting — a repair dog can't fix this root)" % MAX_SPAWNS_PER_CONDITION)
        if self._dedup_hit(cond_key, dedup_tokens, sessions, now):
            return (False, "dedup (live repair dog already targeting %s)" % cond_key)
        n = len(self.active_repair_dogs(sessions, now))
        if n >= MAX_ACTIVE_REPAIR_DOGS:
            return (False, "at repair-dog cap (%d/%d) — deferring" % (n, MAX_ACTIVE_REPAIR_DOGS))
        return (True, "ok")

    def record_spawn(self, cond_key, session_id, now):
        if session_id:
            self.ledger.setdefault(cond_key, []).append((session_id, now))
        self.last_spawn[cond_key] = now
        self.spawn_count[cond_key] = self.spawn_count.get(cond_key, 0) + 1
        # exponential back-off: each repeat for the same condition waits longer
        self.cooldown[cond_key] = min(WAKE_COOLDOWN_SEC * (2 ** (self.spawn_count[cond_key] - 1)),
                                      WAKE_BACKOFF_MAX_SEC)

    def spawns(self, cond_key):
        return self.spawn_count.get(cond_key, 0)

    def should_escalate(self, cond_key, now):
        """True at most once per WAKE_BACKOFF_MAX_SEC for a condition that hit the
        per-condition spawn cap — page the human ONCE, don't spam."""
        if self.spawn_count.get(cond_key, 0) < MAX_SPAWNS_PER_CONDITION:
            return False
        if now - self.escalated.get(cond_key, 0) < WAKE_BACKOFF_MAX_SEC:
            return False
        self.escalated[cond_key] = now
        return True

    def reset_prefix(self, prefix):
        """On recovery, clear all per-condition state for a kind (keys start with
        prefix) so the next genuine incident starts fresh (cooldown + counts)."""
        for d in (self.last_spawn, self.spawn_count, self.cooldown, self.ledger, self.escalated):
            for k in [k for k in d if k.startswith(prefix)]:
                del d[k]


def governed_spawn(gov, sessions, now, kind, reason, diag, dolt_hits, label,
                   marker_id=None, branch=None):
    """Single entry point for every detection block: apply the governor, then spawn
    (or skip / escalate). Returns a short status string for logging, or None if the
    spawn was suppressed. Centralizing this is what makes dedup+cap+back-off apply
    uniformly to all five detectors instead of each re-implementing a coarse per-kind
    cooldown (the old design, which gated by KIND only — so 6 different orphan
    markers, or one marker seen 6 times across cooldown windows, each spawned)."""
    cond_key, dedup_tokens = cond_for(kind, reason, marker_id=marker_id, branch=branch)
    allow, why = gov.decide(cond_key, dedup_tokens, sessions, now)
    if not allow:
        print("[watchdog] %s repair SKIPPED (%s) cond=%s" % (label, why, cond_key), flush=True)
        if gov.should_escalate(cond_key, now):
            notify("🚨 %s: reparo autônomo já tentou %dx p/ %s e não resolveu — precisa de você. Diag: %s"
                   % (label, MAX_SPAWNS_PER_CONDITION, cond_key, diag), 5)
            _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical", "bead_id": "", "reason": "%s: reparo autônomo %dx não resolveu cond=%s" % (label, MAX_SPAWNS_PER_CONDITION, cond_key)}, fail_open=True)
            print("[watchdog] ESCALATED to Athos (%s self-limit reached)" % cond_key, flush=True)
        return None
    if GRW_DRY_RUN:
        print("[watchdog] DRY_RUN would spawn repair: kind=%s cond=%s reason=%s diag=%s"
              % (kind, cond_key, reason, diag), flush=True)
        gov.record_spawn(cond_key, None, now)
        return "DRY_RUN (no spawn)"
    how, sid = spawn_repair_agent(reason, diag, dolt_hits, kind)
    gov.record_spawn(cond_key, sid, now)
    n = gov.spawns(cond_key)
    if n >= ESCALATE_AFTER_WAKES:
        notify("🚨 %s ainda quebrado após %dx de reparo autônomo (cond %s). Precisa de você. Diag: %s"
               % (label, n, cond_key, diag), 5)
        _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical", "bead_id": "", "reason": "%s ainda quebrado após %dx reparo autônomo cond=%s" % (label, n, cond_key)}, fail_open=True)
        print("[watchdog] ESCALATED to Athos (%s, %d cycles)" % (cond_key, n), flush=True)
    else:
        notify("%s (%s) — %s. Você não precisa agir." % (label, reason, how), 3)
    print("[watchdog] repair dispatch (%s) kind=%s cond=%s reason=%s diag=%s"
          % (how, kind, cond_key, reason, diag), flush=True)
    return how


# ═══════════════════════════════════════════════════════════════════════════════
# DIRECT SELF-HEAL — the two toils the Mayor fixed BY HAND ~6x/day
# (1) reap a HUNG gate-reviewer / stale gate-status:running gate-run, and
# (2) auto-requeue a STUCK gate-status:error marker.
# These perform the recovery MUTATION themselves (no dog, no Mayor). Every pure
# DECISION is factored into a *_verdict() function so the selftest unit-tests the
# reap/keep + requeue/close/escalate logic against synthetic fixtures with no live
# Dolt — mirroring reconcile_gaterun_action / classify_sibling_run / gatefix_recovery_decide.
# ═══════════════════════════════════════════════════════════════════════════════

def _recovery_ledger(event, fields):
    """Append a durable jsonl evidence record for every direct reap/requeue.
    Best-effort; never raises (audit must never break recovery)."""
    try:
        rec = {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "event": event}
        rec.update(fields or {})
        with open(RECOVERY_LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def _parse_run_field(desc, field):
    """Extract a `field: value` line from a gate-run bead description (the same
    key=value block the guard/dispatcher write: source_bead, marker_id, started_at,
    required_reviewers). Canonical, whitespace-tolerant. '' if absent."""
    if not desc:
        return ""
    for line in desc.splitlines():
        if line.startswith(field + ":"):
            return line[len(field) + 1:].strip()
    return ""


def _label_value(bead, prefix):
    """First label value for a `prefix` (e.g. 'source-bead:'), or '' — reads the
    label list already present on a bead dict (no extra query)."""
    for lb in (bead.get("labels") or []):
        if lb.startswith(prefix):
            return lb[len(prefix):]
    return ""


def set_gate_status_py(bead_id, new_status):
    """Python mirror of the shell set_gate_status (byte-for-byte SEMANTICS, ga-jhyu):
    strip EVERY gate-status:* label currently on the bead, then add exactly the one
    target — so a bead never leaks two gate-status labels (observed live: done+failed,
    passed+superseded). Best-effort; never raises."""
    if not bead_id:
        return
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "show", bead_id, "--json"])  # ga-h199q
    cur = []
    try:
        j = json.loads(r.stdout) if (r and r.returncode == 0) else None
        row = (j[0] if isinstance(j, list) and j else j) or {}
        cur = [l for l in (row.get("labels") or []) if str(l).startswith("gate-status:")]
    except Exception:
        cur = []
    for lbl in cur:
        if lbl == "gate-status:%s" % new_status:
            continue
        sh(["bd", "-C", CITY, "label", "remove", bead_id, lbl, "-q"])
    sh(["bd", "-C", CITY, "label", "add", bead_id, "gate-status:%s" % new_status, "-q"])


def _bead_is_open(bead_id):
    """True/False if a bead is open; None on query failure (caller fail-safe)."""
    if not bead_id:
        return None
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "show", bead_id, "--json"])  # ga-h199q
    if not r or r.returncode != 0:
        return None
    try:
        j = json.loads(r.stdout)
        row = (j[0] if isinstance(j, list) and j else j) or {}
        return row.get("status") != "closed"
    except Exception:
        return None


def _bead_labels(bead_id):
    """A bead's label list ([] on failure) — used by FIX 5's per-marker stranded cap."""
    if not bead_id:
        return []
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "show", bead_id, "--json"])  # ga-h199q
    if not r or r.returncode != 0:
        return []
    try:
        j = json.loads(r.stdout)
        row = (j[0] if isinstance(j, list) and j else j) or {}
        return row.get("labels") or []
    except Exception:
        return []


def _bead_row(bead_id):
    """A bead's full JSON row ({} on failure/missing) — used by FIX 3's post-kill
    recovery (ga-pp5vh) to fetch a single marker for _requeue_or_escalate_review_marker
    outside a list query (FIX 6 gets its `m` from a list row already; FIX 3 only has a
    marker_id parsed out of the gate-run's description, so it needs its own fetch)."""
    if not bead_id:
        return {}
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "show", bead_id, "--json"])  # ga-h199q
    if not r or r.returncode != 0:
        return {}
    try:
        j = json.loads(r.stdout)
        return (j[0] if isinstance(j, list) and j else j) or {}
    except Exception:
        return {}


_RIG_PATHS = {"ts": 0.0, "map": {}, "by_prefix": {}}


def _rig_paths():
    """{rig_name: repo_path} from `gc rig list`, cached ~10min. A marker's source
    bead lives in its RIG store, not HQ, so resolving 'is the source bead closed'
    needs the rig path (mirrors gatefix-deadworker-recovery). {} on failure."""
    if time.time() - _RIG_PATHS["ts"] < 600 and _RIG_PATHS["map"]:
        return _RIG_PATHS["map"]
    r = sh(["gc", "--city", CITY, "rig", "list", "--json"])
    m, mp = {}, {}
    try:
        j = json.loads(r.stdout) if (r and r.returncode == 0) else {}
        for rg in (j.get("rigs", []) if isinstance(j, dict) else []):
            nm, p, pfx = rg.get("name"), rg.get("path"), rg.get("prefix")
            if nm and p:
                m[nm] = p
            if pfx and p:
                mp[pfx] = p
    except Exception:
        m, mp = {}, {}
    if m:
        _RIG_PATHS["map"] = m
        _RIG_PATHS["by_prefix"] = mp
        _RIG_PATHS["ts"] = time.time()
    return _RIG_PATHS["map"]


def _bead_id_prefix(bead_id):
    """Rig-prefix segment of a bead ID ('wa-10srb' -> 'wa', 'ga-wisp-me6y20' ->
    'ga' — split on the FIRST hyphen only), or '' if bead_id is falsy or has no
    hyphen. Pure (unit-tested); feeds _rig_path_by_prefix's ga-c1s8 fallback."""
    if not bead_id or "-" not in bead_id:
        return ""
    return bead_id.split("-", 1)[0]


def _rig_path_by_prefix(prefix):
    """repo_path for a rig's bead-ID prefix (e.g. 'wa' -> whatsapp_automation's
    path), from the same `gc rig list` fetch _rig_paths() caches. Fallback
    source-bead-store resolution for markers with no bead-rig: label: markers
    sourced from non-HQ rigs are NOT reliably labeled with their rig (ga-c1s8 —
    marker ga-wisp-me6y20, source wa-10srb, had no bead-rig: label at all, so
    _source_bead_state could only ever check the HQ store, always failed to
    resolve the source bead, and silently bypassed the needs-human requeue
    carve-out — the dispatcher's circuit-break and grw's requeue ping-ponged
    until the oscillation cap tripped). None if prefix is empty/unknown."""
    if not prefix:
        return None
    _rig_paths()  # ensure cache populated/fresh (same TTL, same fetch)
    return _RIG_PATHS["by_prefix"].get(prefix)


def _source_bead_state(bead_id, rig_name=""):
    """(resolved, closed, needs_human) for a marker's source bead. Tries HQ first,
    then the bead's rig store — from rig_name (the marker's bead-rig: label) if
    given, else derived from the bead ID's own prefix (ga-c1s8 fallback: that
    label is only ever set for HQ-native sources, so a non-HQ-rig-sourced marker
    with no label would otherwise never resolve). resolved=False on any failure →
    the caller treats the source as UNKNOWN and proceeds to requeue (fail toward
    recovery; the dispatcher re-validates the branch, and the oscillation cap
    bounds a bad requeue)."""
    if not bead_id:
        return (False, False, False)
    rigp = (_rig_paths().get(rig_name) if rig_name else None) or _rig_path_by_prefix(_bead_id_prefix(bead_id))
    tries = [[CITY]]
    if rigp and rigp != CITY:
        tries.append([rigp])
    for st in tries:
        r = sh(["bash", BD_LIST_CACHED, "-C", st[0], "show", bead_id, "--json"])  # ga-h199q
        if not r or r.returncode != 0:
            continue
        try:
            j = json.loads(r.stdout)
            row = (j[0] if isinstance(j, list) and j else j) or {}
        except Exception:
            continue
        if not row or not row.get("id"):
            continue
        closed = (row.get("status") == "closed")
        nh = any(str(l).startswith("gate:needs-human") for l in (row.get("labels") or []))
        return (True, closed, nh)
    return (False, False, False)


def _source_bead_has_author_fields(bead_id, rig_name=""):
    """True if a marker's source bead has assignee, created_by, or owner set — the
    same three fields quality-gate-dispatcher.sh Step 3 falls back to once a marker's
    OWN gate.submitted_by metadata is absent (FIX 7, ga-y1kk). A lightweight 'is there
    anything to work with' probe — NOT a re-implementation of the dispatcher's full
    derivation (adhoc-suffix stripping, wa-worker routing, etc. stay the dispatcher's
    sole authoritative job); this only decides whether a requeue is worth attempting.
    False on any query failure (fail-safe: never treat an unreadable bead as
    author-bearing, which would wrongly justify a requeue)."""
    if not bead_id:
        return False
    rigp = (_rig_paths().get(rig_name) if rig_name else None) or _rig_path_by_prefix(_bead_id_prefix(bead_id))
    tries = [CITY] + ([rigp] if (rigp and rigp != CITY) else [])
    for st in tries:
        r = sh(["bash", BD_LIST_CACHED, "-C", st, "show", bead_id, "--json"])  # ga-h199q
        if not r or r.returncode != 0:
            continue
        try:
            j = json.loads(r.stdout)
            row = (j[0] if isinstance(j, list) and j else j) or {}
        except Exception:
            continue
        if not row or not row.get("id"):
            continue
        return bool(row.get("assignee") or row.get("created_by") or row.get("owner"))
    return False


def _source_review_state(bead_id, rig_name=""):
    """(resolved, closed, has_reviewing, store) for a marker's source bead — ONE read,
    used by FIX 4 both to decide (close-source-done vs clear-stale-reviewing) and to know
    WHICH store to clear the label in (the source lives in its RIG, not HQ). resolved=
    False on any failure → FIX 4 fail-safe keeps the marker untouched."""
    if not bead_id:
        return (False, False, False, CITY)
    rigp = _rig_paths().get(rig_name) if rig_name else None
    tries = [CITY] + ([rigp] if (rigp and rigp != CITY) else [])
    for st in tries:
        r = sh(["bash", BD_LIST_CACHED, "-C", st, "show", bead_id, "--json"])  # ga-h199q
        if not r or r.returncode != 0:
            continue
        try:
            j = json.loads(r.stdout)
            row = (j[0] if isinstance(j, list) and j else j) or {}
        except Exception:
            continue
        if not row or not row.get("id"):
            continue
        labs = row.get("labels") or []
        return (True, row.get("status") == "closed", "gate:reviewing" in labs, st)
    return (False, False, False, CITY)


def _branch_merged_state(branch, rig_name=""):
    """Classify a marker's branch vs the rig's origin/main — the TRUTH about whether the
    work landed (a source bead being closed does NOT prove it, ga-w5agg/ga-d2jil):
      'merged'   — origin/<branch> is an ancestor of origin/main (landed).
      'unmerged' — origin/<branch> exists but is NOT an ancestor (STRANDED — fix pending).
      'missing'  — git ACTUALLY RAN and confirmed no such branch exists on origin
                   (abandoned/renamed → marker is truly moot).
      'unknown'  — fetch failed, or a git subprocess couldn't be confirmed to have run
                   (sh() returned None on exception/timeout), or rig unresolved → caller
                   MUST NOT treat as done (fail-safe).
    GATE-FEEDBACK (ga-7b19e attempt 2 FAIL): sh() returning None (subprocess exception/
    timeout) on the rev-parse call used to fall into the SAME branch as a confirmed-
    absent ref (returncode != 0) — inconsistent with the merge-base check 4 lines below,
    which already treated its own sh()-returns-None case as 'unknown'. Under this city's
    documented load (Dolt-hot, 100+ concurrent worktrees sharing git state) a transient
    subprocess failure is not hypothetical. Every sh() result is now checked for None
    before its returncode is read, and a failed/timed-out `fetch` short-circuits to
    'unknown' before rev-parse even runs — a stale local view must never stand in for a
    freshly confirmed one.
    Bounded git ops in the branch's rig repo (or HQ if rig unresolved)."""
    if not branch:
        return "unknown"
    repo = (_rig_paths().get(rig_name) if rig_name else None) or CITY
    fetch = sh(["git", "-C", repo, "fetch", "origin", "--quiet"], timeout=30)
    if fetch is None or fetch.returncode != 0:
        return "unknown"
    ex = sh(["git", "-C", repo, "rev-parse", "--verify", "-q", "origin/%s^{commit}" % branch], timeout=15)
    if ex is None:
        return "unknown"
    if ex.returncode != 0 or not (ex.stdout or "").strip():
        return "missing"
    anc = sh(["git", "-C", repo, "merge-base", "--is-ancestor",
              "origin/%s" % branch, "origin/main"], timeout=15)
    if anc is None:
        return "unknown"
    if anc.returncode == 0:
        return "merged"
    if anc.returncode == 1:
        return "unmerged"
    return "unknown"


def orphan_marker_verdict(age_sec, min_sec, resolved, source_closed, source_reviewing,
                          branch_state="unknown"):
    """PURE decision (no I/O, unit-tested) for FIX 4, on a gate-status:queued marker:
      'close-source-done'     — source CLOSED **and the branch actually merged** (or is
                                gone) → the marker is moot; close it (phantom depth).
      'recover-stranded'      — source CLOSED but the branch EXISTS and is NOT merged →
                                a FALSE close (the sling-task-janitor closes fix-task
                                beads as 'orphan' without the branch merging, which used
                                to make FIX 4 false-close the marker as 'merged' and
                                STRAND a complete fix — ga-w5agg/ga-d2jil 2026-07-02).
                                Re-land it, NEVER close.
      'clear-stale-reviewing' — source OPEN + carries gate:reviewing while the marker
                                sits QUEUED (contradictory) → leaked label; clear it.
      'wait'                  — younger than min_sec.
      'keep'                  — source unreadable / branch state unknown (fail-safe) or
                                nothing to do — NEVER close on a can't-verify.
    branch_state ∈ {'merged','unmerged','missing','unknown'}: a source being closed does
    NOT prove the work landed — the branch's ancestry vs origin/main is the truth."""
    if age_sec < min_sec:
        return "wait"
    if not resolved:
        return "keep"
    if source_closed:
        if branch_state in ("merged", "missing"):
            return "close-source-done"   # truly landed, or abandoned (no branch) → close phantom
        if branch_state == "unmerged":
            return "recover-stranded"    # real branch, not merged → stranded fix, never false-close
        return "keep"                    # unknown → fail-safe, NEVER false-close as 'merged'
    if source_reviewing:
        return "clear-stale-reviewing"
    return "keep"


def _session_index(sessions):
    """{identifier: session-dict} across every name field a verdict-bead assignee
    could carry (session_name/name/alias/agent_name/id — verified equal live)."""
    idx = {}
    for s in (sessions or []):
        for k in ("session_name", "name", "alias", "agent_name", "id"):
            v = s.get(k)
            if v:
                idx[str(v)] = s
    return idx


def _any_reviewer_active(sessions, names):
    """True if ANY of a run's reviewer sessions (by verdict-bead assignee name) is
    state=='active' (the authoritative session-manager liveness signal — NOT a
    session-id proc grep, which is unreliable because a reviewer's claude cmdline
    carries no session id). False if all non-active/absent. None if the session
    list is unavailable → caller fail-safe SKIPS (a gc/Dolt outage can never
    become a blind reaper)."""
    if sessions is None:
        return None
    if not names:
        return False
    idx = _session_index(sessions)
    for nm in names:
        s = idx.get(str(nm))
        if s and not s.get("closed") and str(s.get("state", "")).lower() == "active":
            return True
    return False


def _run_verdicts(run_id):
    """(reviewer_names:set, delivered:int, total:int, last_delivered_epoch:float|None)
    for a gate-run's verdict beads (label gate-run:<id>). delivered = CLOSED verdict
    beads (a closed verdict bead = a verdict was recorded; open/in_progress =
    pending). last_delivered_epoch = the newest `updated_at` among the CLOSED
    verdict beads — a proxy for when the LAST verdict was delivered (the anchor
    FIX5's stranded-run check needs; ga-5t5w), or None if nothing has been
    delivered yet or no closed row parsed. Returns (set(), -1, -1, None) on query
    failure so the caller fail-safe skips."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "gate-run:%s" % run_id, "--json"])  # ga-h199q
    if not r or r.returncode != 0:
        return (set(), -1, -1, None)
    try:
        rows = json.loads(r.stdout) or []
    except Exception:
        return (set(), -1, -1, None)
    names, delivered = set(), 0
    last_delivered = None
    for row in rows:
        a = row.get("assignee")
        if a:
            names.add(a)
        if row.get("status") == "closed":
            delivered += 1
            e = _iso_epoch(row.get("updated_at"))
            if e is not None and (last_delivered is None or e > last_delivered):
                last_delivered = e
    return (names, delivered, len(rows), last_delivered)


def _run_pending_reviewers(run_id):
    """Set of reviewer names with a NOT-yet-closed (pending) verdict bead on a
    gate-run (label gate-run:<id>) — the subset of _run_verdicts' names that have NOT
    delivered yet. Used by FIX 3's post-kill recovery (ga-pp5vh) to tell whether a
    just-killed reviewer was the run's SOLE pending one. None on query failure
    (fail-safe: caller never supersedes on unreadable state)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "gate-run:%s" % run_id, "--json"])  # ga-h199q
    if not r or r.returncode != 0:
        return None
    try:
        rows = json.loads(r.stdout) or []
    except Exception:
        return None
    pending = set()
    for row in rows:
        if row.get("status") != "closed":
            a = row.get("assignee")
            if a:
                pending.add(a)
    return pending


def hung_run_verdict(age_sec, hang_sec, n_verdict_beads, n_delivered,
                     reviewer_active, delivered_after_resample):
    """PURE decision: should a gate-status:running gate-run be reaped as HUNG?
    Returns 'reap' or 'skip:<reason>'. Ordered fail-SAFE — every branch that could
    be a genuinely-working (just slow) review returns skip:

      skip:young            — younger than REVIEW_HANG_MINUTES (a real review takes 9+m)
      skip:verdict-query-failed — could not read verdict beads (never reap blind)
      skip:not-a-review-run — 0 verdict beads on an open gate-status:running run. Before
                              ga-f1ngu this was usually the guard's CLAIM-time tracking
                              bead (mislabeled gate-status:running); that bead is now
                              gate-status:claimed and _open_running_runs() never returns
                              it at all. This branch now means the DISPATCHER's own real
                              run bead was created but died before Step 7 ever spawned a
                              reviewer — leave it to the guard's Vector B reconcile
                              (reconcile_zero_verdict_run_action), which handles this
                              case identically regardless of which side created the bead
      skip:producing        — >=1 verdict already delivered → reviewers ARE working
      skip:liveness-unknown — session list unavailable → never reap blind
      skip:reviewer-active  — a reviewer session is state=active → working, not hung
      skip:verdict-landed   — a verdict landed between the two samples → working
      reap                  — old AND a real review run AND 0 delivered AND the reviewer
                              is dead/idle SUSTAINED across both samples.
    """
    if age_sec <= hang_sec:
        return "skip:young"
    if n_verdict_beads < 0:
        return "skip:verdict-query-failed"
    if n_verdict_beads == 0:
        return "skip:not-a-review-run"
    if n_delivered > 0:
        return "skip:producing"
    if reviewer_active is None:
        return "skip:liveness-unknown"
    if reviewer_active:
        return "skip:reviewer-active"
    if delivered_after_resample and delivered_after_resample > 0:
        return "skip:verdict-landed"
    return "reap"


def error_requeue_verdict(age_sec, threshold_sec, source_resolved, source_closed,
                          source_needs_human, requeue_count, max_attempts,
                          branch_state="unknown"):
    """PURE decision for a gate-status:error marker. Returns:
      close:source-done      — the source bead is CLOSED **and branch_state confirms
                               the work actually landed (merged) or the branch is gone
                               (missing)** → the marker is a leftover; close it, do NOT
                               requeue (checked FIRST, before the age gate: a done
                               marker never waits). A closed source bead ALONE does NOT
                               prove this (ga-hckn3 — the textually identical gap FIX 7's
                               deferred_requeue_verdict had before ga-gd706): the normal
                               dog-self-closes-its-sling-bead-on-submission doctrine
                               closes the source immediately after /gate-done, regardless
                               of whether a reviewer ever ran. Same discipline as FIX 4's
                               orphan_marker_verdict (ga-w5agg/ga-d2jil) and FIX 7's
                               post-ga-gd706 deferred_requeue_verdict — branch_state is
                               the truth, a closed source is not.
      skip:young             — in error < threshold; let a transient self-clear first
      skip:parked-needs-human— source bead carries gate:needs-human (ga-acb permanent
                               park) → deliberately awaiting a human; never requeue
      escalate:oscillating   — already requeued max_attempts times and it keeps
                               re-erroring → stop the infinite loop, page the Mayor
      requeue                — genuinely stuck transient error → error→queued. Also the
                               recovery path when the source is CLOSED but branch_state
                               is 'unmerged' (real stranding) or 'unknown' (can't verify)
                               — falls through to here instead of closing, same as FIX 7's
                               post-ga-gd706 fall-through.
    branch_state ∈ {'merged','unmerged','missing','unknown'} (ga-hckn3, porting ga-gd706's
    fix shape from FIX 7): only decides the outcome when source_resolved and
    source_closed are both True — the sole case where 'closed' could lie about 'done'.
    'unmerged' (real stranding) and 'unknown' (can't verify — fail-safe default) both
    fall through to the age/needs-human/oscillation handling below instead of closing;
    NEVER false-close a marker whose branch hasn't actually landed.
    """
    if source_resolved and source_closed and branch_state in ("merged", "missing"):
        return "close:source-done"
    if age_sec <= threshold_sec:
        return "skip:young"
    if source_resolved and source_needs_human:
        return "skip:parked-needs-human"
    if requeue_count >= max_attempts:
        return "escalate:oscillating"
    return "requeue"


def deferred_requeue_verdict(age_sec, threshold_sec, source_resolved, source_closed,
                             source_needs_human, has_derivable_author, attempts, max_attempts,
                             branch_state="unknown"):
    """PURE decision for a gate-status:deferred marker (FIX 7, ga-y1kk). A marker lands
    here when the dispatcher's/guard's own AUTHOR-derivation fail-safe could not resolve
    AUTHOR and nothing else ever re-reads gate-status:deferred. Unlike FIX 2's transient
    gate-status:error, a blind requeue is unlikely to help — the marker got stuck
    BECAUSE no author field resolved, so it only requeues once the source actually has
    something to derive from. Returns:
      close:source-done      — source CLOSED **and branch_state confirms the work
                               actually landed (merged) or the branch is gone
                               (missing)** → close, don't requeue. A closed source
                               bead ALONE does not prove this (ga-gd706): the normal
                               dog-self-closes-its-sling-bead-on-submission doctrine
                               closes the branch-embedded source immediately after
                               /gate-done, regardless of whether a reviewer ever ran
                               — and a marker only reaches gate-status:deferred
                               BECAUSE authorship couldn't be verified in the first
                               place, so "source closed" is the common case here, not
                               a rare one. Same discipline as FIX 4's
                               orphan_marker_verdict (ga-w5agg/ga-d2jil) — branch_state
                               is the truth, a closed source is not.
      skip:young             — deferred < threshold; give gate.submitted_by (written by a
                               human/automation doing a partial manual recovery) or the
                               source bead's own fields time to land before we intervene
      skip:parked-needs-human— source carries gate:needs-human → deliberately parked
      requeue                — has_derivable_author is True (the marker's own
                               gate.submitted_by, set by a partial manual recovery,
                               counts on its own — it does NOT require source_resolved;
                               that's exactly the ga-wisp-5zki27 scenario this fix exists
                               for) → worth another dispatcher pass (it re-derives AUTHOR
                               itself). Also the recovery path when the source is CLOSED
                               but branch_state is 'unmerged' or 'unknown' (ga-gd706
                               stranding, or a git check that couldn't run) — falls
                               through to here instead of closing.
      escalate:oscillating   — attempts exhausted while author WAS derivable (the
                               dispatcher keeps re-deferring for some other reason) →
                               stop looping, page a human
      close:unresolvable     — attempts exhausted while the source was NEVER resolvable
                               or never grew a derivable author (ga-y1kk: "bead também
                               sumiu") → genuinely terminal; close with an explicit
                               reason instead of rotting silently
      skip:unresolvable      — not yet at max_attempts; wait for another sweep before
                               concluding it's genuinely gone (never close on one blip)
    branch_state ∈ {'merged','unmerged','missing','unknown'} (ga-gd706): only decides
    the outcome when source_resolved and source_closed are both True — the sole case
    where 'closed' could lie about 'done'. 'unmerged' (real stranding) and 'unknown'
    (can't verify — fail-safe default) both fall through to the resolvability handling
    below instead of closing; NEVER false-close a marker whose branch hasn't actually
    landed.
    """
    if source_resolved and source_closed and branch_state in ("merged", "missing"):
        return "close:source-done"
    if age_sec <= threshold_sec:
        return "skip:young"
    if source_resolved and source_needs_human:
        return "skip:parked-needs-human"
    # has_derivable_author already folds source_resolved into its own OR (the caller
    # sets it True from EITHER the marker's own gate.submitted_by OR a resolved source
    # bead's author fields) — re-ANDing source_resolved here double-counts that check
    # and wrongly denies resolvability when the source is unresolved but the marker
    # already carries gate.submitted_by (GATE-FEEDBACK ga-wisp-d9fqvt, gate_run
    # ga-y1kk attempt 1: verified false "skip:unresolvable"/"close:unresolvable" with
    # a close reason that falsely claimed gate.submitted_by was absent).
    resolvable = has_derivable_author
    if attempts >= max_attempts:
        return "escalate:oscillating" if resolvable else "close:unresolvable"
    return "requeue" if resolvable else "skip:unresolvable"


class RecoveryState:
    """Tiny in-memory state for the two direct-action features: a per-marker requeue
    counter (backs the durable grw-requeue:N label so oscillation detection survives
    even mid-process) and an escalate-once dedup so a stuck condition pages the Mayor
    at most once per back-off window."""
    def __init__(self):
        self.error_requeues = {}   # marker_id -> requeues this process has done
        self.deferred_requeues = {}  # marker_id -> FIX 7 attempts this process has done (independent budget from error_requeues)
        self.escalated = {}        # key -> last-escalation epoch
        self.orphan_gate_label_hits = {}  # (bead_id, label) -> FIX 8 consecutive-sweep count seen unreferenced

    def escalate_once(self, key, now, window=None):
        w = WAKE_BACKOFF_MAX_SEC if window is None else window
        if now - self.escalated.get(key, 0) < w:
            return False
        self.escalated[key] = now
        return True


def _open_running_runs():
    """[gate-run dicts] with type:quality-gate-run + gate-status:running + open.
    None on query failure (fail-safe: caller skips — never reap during a Dolt glitch)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-run",  # ga-h199q
            "-l", "gate-status:running", "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout) or []
    except Exception:
        return None


def reap_hung_runs(sessions, now, rstate, open_running_runs):
    """FIX 1: reap a HUNG gate-reviewer. For every open gate-status:running gate-run
    past REVIEW_HANG_MINUTES with 0 verdicts delivered whose reviewer session is
    dead/idle SUSTAINED across two samples, do the FULL manual reap the Mayor did by
    hand: drain the zombie reviewer session(s), supersede+close the run, and re-queue
    its marker so a fresh run reviews it. Bounded, dry-run-aware, fully fail-safe."""
    if not GRW_ENABLED or not GRW_REAP_HUNG_ENABLED:
        return
    runs = open_running_runs
    if runs is None:
        print("[watchdog] reap: gate-run query unavailable — fail-safe skip (no blind reap)", flush=True)
        return
    reaped = 0
    for run in runs:
        if reaped >= REAP_MAX_PER_SWEEP:
            break
        rid = run.get("id")
        if not rid:
            continue
        desc = run.get("description") or ""
        started = _parse_run_field(desc, "started_at")
        se = _iso_epoch(started)
        if not se:
            continue  # no parseable started_at → cannot age → fail-safe skip
        age = int(now - se)
        if age <= REVIEW_HANG_MINUTES * 60:
            continue  # too young — a real review can take 9+ min; never reap early
        names, delivered, total, _ldv = _run_verdicts(rid)
        active1 = _any_reviewer_active(sessions, names)
        v1 = hung_run_verdict(age, REVIEW_HANG_MINUTES * 60, total, delivered, active1, 0)
        if v1 != "reap":
            if GRW_DRY_RUN:
                print("[watchdog] reap DRY skip run=%s (%s) age=%dm beads=%d delivered=%d reviewers=%r"
                      % (rid, v1, age // 60, total, delivered, sorted(names)), flush=True)
            continue
        # CANDIDATE — confirm SUSTAINED-idle: re-sample liveness + verdicts after a gap.
        # A genuinely-working reviewer that blipped asleep will read active on the
        # second sample, or will have LANDED a verdict — either aborts the reap.
        time.sleep(LIVENESS_RESAMPLE_SEC)
        sessions2 = _session_list_json()
        names2, delivered2, total2, _ldv2 = _run_verdicts(rid)
        active2 = _any_reviewer_active(sessions2, names2)
        both_active = None if (active1 is None or active2 is None) else (active1 or active2)
        eff_total = total2 if total2 >= 0 else total
        eff_delivered = delivered2 if delivered2 >= 0 else delivered
        v2 = hung_run_verdict(age, REVIEW_HANG_MINUTES * 60, eff_total, eff_delivered,
                              both_active, eff_delivered)
        if v2 != "reap":
            print("[watchdog] reap: run=%s NOT reaped after resample (%s) age=%dm — fail-safe KEPT (working/slow review)"
                  % (rid, v2, age // 60), flush=True)
            continue
        marker_id = _parse_run_field(desc, "marker_id")
        source_bead = _parse_run_field(desc, "source_bead") or _label_value(run, "source-bead:")
        if GRW_DRY_RUN:
            print("[watchdog] REAP DRY-RUN would reap HUNG run=%s age=%dm 0/%d verdicts reviewers=%r → supersede+close run, drain session(s), re-queue marker=%s"
                  % (rid, age // 60, eff_total, sorted(names), marker_id), flush=True)
            _recovery_ledger("would_reap_hung_run", {"run": rid, "age_min": age // 60,
                             "verdict_beads": eff_total, "delivered": eff_delivered,
                             "reviewers": sorted(names), "marker": marker_id, "dry_run": True})
            reaped += 1
            continue
        # 1) drain the zombie reviewer session(s) — only the NON-active ones (freeing
        #    the max_active_sessions / LIVE_REVIEWERS slot the hung reviewer occupied).
        idx = _session_index(sessions2 if sessions2 is not None else sessions)
        drained = []
        for nm in names:
            s = idx.get(str(nm))
            if s and not s.get("closed") and str(s.get("state", "")).lower() != "active":
                sid = s.get("id")
                if sid:
                    sh(["gc", "session", "close", sid], timeout=20)
                    drained.append(sid)
        # 2) supersede + close the run (mirrors the dispatcher's own ga-jhyu close).
        set_gate_status_py(rid, "superseded")
        sh(["bd", "-C", CITY, "comment", rid,
            "gate-recovery-watchdog: reaped HUNG run (age=%dm, 0/%d verdicts delivered, reviewer session(s) [%s] dead/idle SUSTAINED across 2 samples %ds apart). Superseding + closing so marker %s re-reviews fresh. (grw hung-reviewer self-heal — the manual toil the Mayor did ~6x/day)"
            % (age // 60, eff_total, ",".join(sorted(names)) or "none", LIVENESS_RESAMPLE_SEC, marker_id or "unknown")], timeout=25)
        sh(["bd", "-C", CITY, "close", rid,
            "-r", "gate-run superseded: reviewer hung (grw auto-reap — 0 verdicts, dead reviewer, age %dm)" % (age // 60)], timeout=25)
        # 3) re-queue the marker (with the same carve-outs as FIX 2).
        marker_action = "no-marker"
        if marker_id:
            m_open = _bead_is_open(marker_id)
            if m_open is False:
                marker_action = "marker-already-closed"
            elif m_open is None:
                marker_action = "marker-state-unknown-skip"
            else:
                resolved, sclosed, needs_human = _source_bead_state(
                    source_bead, _label_value(run, "bead-rig:"))
                if resolved and sclosed:
                    set_gate_status_py(marker_id, "superseded")
                    sh(["bd", "-C", CITY, "close", marker_id,
                        "-r", "source bead %s closed — gate work done/abandoned; marker superseded (grw)" % source_bead], timeout=25)
                    marker_action = "closed:source-done"
                elif resolved and needs_human:
                    marker_action = "left:needs-human"
                else:
                    set_gate_status_py(marker_id, "queued")
                    sh(["bd", "-C", CITY, "comment", marker_id,
                        "gate-recovery-watchdog: re-queued (→gate-status:queued) after reaping its HUNG run %s (reviewer dead, 0 verdicts, %dm). A fresh dispatcher sweep will re-review this branch. (grw hung-reviewer self-heal)"
                        % (rid, age // 60)], timeout=25)
                    marker_action = "requeued"
        _recovery_ledger("reap_hung_run", {"run": rid, "age_min": age // 60,
                         "verdict_beads": eff_total, "delivered": eff_delivered,
                         "reviewers": sorted(names), "drained_sessions": drained,
                         "marker": marker_id, "marker_action": marker_action,
                         "source_bead": source_bead})
        notify("Gate self-heal: revisor travado reapado (run %s, %dmin, 0 vereditos) — marker %s %s. Você não precisa agir."
               % (rid, age // 60, marker_id or "?", marker_action), 3)
        print("[watchdog] REAPED hung run=%s age=%dm 0/%d verdicts reviewers=%r drained=%r marker=%s action=%s"
              % (rid, age // 60, eff_total, sorted(names), drained, marker_id, marker_action), flush=True)
        reaped += 1
    if reaped:
        print("[watchdog] reap sweep: %d hung run(s) reaped%s" % (reaped, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def stranded_verdict_verdict(age_sec, threshold_sec, delivered, total):
    """PURE decision (unit-tested) for FIX 5: should a gate-status:running run be
    RECOVERED as a STRANDED-VERDICT run — all required verdicts DELIVERED but the run
    never finalized (managing sweep died post-verdict; wa-99jug 2026-07-02)? Returns
    'recover' or 'skip:<reason>'. Fail-safe: any ambiguity → skip.

    ga-5t5w: age_sec is seconds since the LAST VERDICT was DELIVERED — never since
    the run was created. A slow-but-healthy review and a genuinely wedged finalize
    both keep a run open a long time; only recency of the last verdict tells them
    apart. Measuring from run-creation made a review that simply took 16 minutes
    indistinguishable from a dead finalizer, and this reaper discarded 11
    COMPLETE, delivered verdicts in a single day (4 escalated to a human) as a
    result. age_sec may be None when delivered==total but no delivery timestamp
    parsed — never invent a recency signal.
      skip:query-failed          verdict counts unreadable (never act blind)
      skip:not-a-run             0 verdict beads (a guard claim-tracking run, not a review)
      skip:collecting            delivered < total (a REAL in-progress review still gathering verdicts)
      skip:verdict-time-unknown  all verdicts delivered but delivery time didn't parse
      skip:young                 younger than threshold (a healthy finalize is seconds after the
                                 last verdict — wait well past so a mid-finalize run is never touched)
      recover                    total>=1 AND delivered==total AND age_sec>=threshold since the
                                 LAST verdict landed (still running, stale)
    """
    if total < 0 or delivered < 0:
        return "skip:query-failed"
    if total == 0:
        return "skip:not-a-run"
    if delivered < total:
        return "skip:collecting"
    if age_sec is None:
        return "skip:verdict-time-unknown"
    if age_sec < threshold_sec:
        return "skip:young"
    return "recover"


def stranded_escalation_needs_human_targets(marker_id, source_bead):
    """PURE (ga-mwsg): which bead(s) must carry gate:needs-human when FIX 5's
    stranded-cap escalates. FIX 2's error_requeue_verdict skip:parked-needs-human
    carve-out reads ONLY the SOURCE bead's label (_source_bead_state), not the
    marker's — labeling just the marker leaves FIX 2 free to requeue right back
    over the escalation (observed live: marker ga-wisp-0uxxi5 escalated
    08:51:59Z, requeued by FIX 2 08:52:03Z, 4s later — the circuit breaker never
    actually broke the circuit). Marker is always labeled too (existing
    behavior — the marker's own gate-status:error is what makes it visible as
    parked); source_bead is appended only if resolvable (some marker rows lack
    one: fail-safe no-op there, not a crash)."""
    targets = [marker_id]
    if source_bead:
        targets.append(source_bead)
    return targets


def reap_stranded_verdict_runs(now, open_running_runs):
    """FIX 5: recover a STRANDED-VERDICT run (all required verdicts delivered, still
    gate-status:running, managing sweep dead). See stranded_verdict_verdict. Anchored
    on time since the LAST VERDICT was DELIVERED (ga-5t5w) — NOT run creation time;
    the run's own age conflates a slow-but-healthy review with a genuinely wedged
    finalize, which is exactly why this reaper used to supersede runs whose reviewers
    had JUST finished on time (11 delivered-and-discarded verdicts in a single day, 4
    escalated to a human, before this fix). Supersede the run + clear the source's
    stale gate:reviewing (the phantom 'em revisão') + re-queue the marker so a fresh
    sweep re-reviews and finalizes cleanly. The watchdog NEVER duplicates the
    dispatcher's merge/FAIL finalization — it hands the completed branch back to the
    gate. Per-marker cap → escalate to needs-human on repeat. No reviewer-liveness
    needed (the reviewers already delivered). Bounded, dry-run-aware, fully fail-safe
    (query failure / run finalized between samples / unparseable verdict-delivery
    time → skip)."""
    if not GRW_ENABLED or not GRW_REAP_STRANDED_ENABLED:
        return
    runs = open_running_runs
    if runs is None:
        return  # gate-run query unavailable → fail-safe skip
    acted = 0
    for run in runs:
        if acted >= REAP_MAX_PER_SWEEP:
            break
        rid = run.get("id")
        if not rid:
            continue
        desc = run.get("description") or ""
        _names, delivered, total, last_delivered = _run_verdicts(rid)
        age = int(now - last_delivered) if last_delivered is not None else None
        if stranded_verdict_verdict(age, STRANDED_RUN_MINUTES * 60, delivered, total) != "recover":
            continue
        # SUSTAINED confirm: re-read after a gap. If the run finalized (no longer open),
        # or verdict counts changed, a live sweep is handling it → abort (never race it).
        time.sleep(LIVENESS_RESAMPLE_SEC)
        if _bead_is_open(rid) is False:
            print("[watchdog] FIX5: run=%s finalized between samples — a live sweep handled it, no action" % rid, flush=True)
            continue
        _n2, delivered2, total2, last_delivered2 = _run_verdicts(rid)
        eff_delivered = delivered2 if delivered2 >= 0 else delivered
        eff_total = total2 if total2 >= 0 else total
        eff_last_delivered = last_delivered2 if last_delivered2 is not None else last_delivered
        age2 = int(now - eff_last_delivered) if eff_last_delivered is not None else None
        if stranded_verdict_verdict(age2, STRANDED_RUN_MINUTES * 60, eff_delivered, eff_total) != "recover":
            print("[watchdog] FIX5: run=%s not stranded after resample — kept (fail-safe)" % rid, flush=True)
            continue
        # recover is only reachable with a non-None age (stranded_verdict_verdict
        # returns skip:verdict-time-unknown otherwise) — age2 is safe to use below.
        age = age2
        marker_id = _parse_run_field(desc, "marker_id")
        source_bead = _parse_run_field(desc, "source_bead") or _label_value(run, "source-bead:")
        rig = _label_value(run, "bead-rig:")
        if GRW_DRY_RUN:
            print("[watchdog] FIX5 DRY would recover STRANDED run=%s age=%dm %d/%d verdicts → supersede + clear gate:reviewing + re-queue marker=%s"
                  % (rid, age // 60, delivered, total, marker_id), flush=True)
            _recovery_ledger("would_recover_stranded_run", {"run": rid, "age_min": age // 60,
                             "delivered": delivered, "total": total, "marker": marker_id, "dry_run": True})
            acted += 1
            continue
        # 1) supersede + close the stranded run.
        set_gate_status_py(rid, "superseded")
        sh(["bd", "-C", CITY, "comment", rid,
            "gate-recovery-watchdog FIX5: STRANDED-VERDICT run — %d/%d required verdicts DELIVERED but the run stayed gate-status:running %dm (managing sweep died post-verdict; SUSTAINED across 2 samples). Superseding + re-queuing marker %s so a fresh sweep re-reviews and finalizes cleanly. (the wa-99jug phantom-'em revisão' class)"
            % (delivered, total, age // 60, marker_id or "unknown")], timeout=25)
        sh(["bd", "-C", CITY, "close", rid,
            "-r", "gate-run superseded: stranded verdict (grw FIX5 — %d/%d delivered, never finalized, %dm)" % (delivered, total, age // 60)], timeout=25)
        # 2) clear the stale gate:reviewing on the source (the phantom 'em revisão').
        resolved, sclosed, reviewing, store = _source_review_state(source_bead, rig)
        cleared_reviewing = False
        if resolved and reviewing:
            sh(["bd", "-C", store, "label", "remove", source_bead, "gate:reviewing", "-q"], timeout=20)
            cleared_reviewing = True
        # 3) re-queue the marker (source-state carve-outs + per-marker stranded cap).
        marker_action = "no-marker"
        if marker_id:
            m_open = _bead_is_open(marker_id)
            if m_open is False:
                marker_action = "marker-already-closed"
            elif m_open is None:
                marker_action = "marker-state-unknown-skip"
            elif resolved and sclosed:
                set_gate_status_py(marker_id, "superseded")
                sh(["bd", "-C", CITY, "close", marker_id, "-r",
                    "source bead %s closed — gate work done; stranded marker superseded (grw FIX5)" % source_bead], timeout=25)
                marker_action = "closed:source-done"
            else:
                n = 0
                for lb in _bead_labels(marker_id):
                    m = GRW_STRANDED_LABEL_RE.match(str(lb))
                    if m:
                        n = max(n, int(m.group(1)))
                if n + 1 >= STRANDED_MAX_ATTEMPTS:
                    set_gate_status_py(marker_id, "error")
                    # ga-mwsg: also label the SOURCE bead — FIX 2's skip:parked-needs-human
                    # carve-out (error_requeue_verdict) reads ONLY the source bead's label,
                    # never the marker's; a marker-only label left FIX 2 free to requeue
                    # right back over this escalation (see stranded_escalation_needs_human_targets).
                    needs_human_targets = stranded_escalation_needs_human_targets(marker_id, source_bead if resolved else "")
                    sh(["bd", "-C", CITY, "label", "add", marker_id, "gate:needs-human", "-q"], timeout=20)
                    if len(needs_human_targets) > 1:
                        sh(["bd", "-C", store, "label", "add", source_bead, "gate:needs-human", "-q"], timeout=20)
                    sh(["bd", "-C", CITY, "comment", marker_id,
                        "gate-recovery-watchdog FIX5: stranded-verdict recovery hit the cap (%d) — this marker's run keeps delivering verdicts then failing to finalize. Escalating to gate:needs-human (%s); a human/Mayor must finalize by hand (the finalize path itself is likely broken)."
                        % (STRANDED_MAX_ATTEMPTS, "marker + source bead %s" % source_bead if len(needs_human_targets) > 1 else "marker")], timeout=25)
                    notify("Gate: marker %s estranha repetidamente (veredito entregue mas run não finaliza, %dx) — escalado p/ needs-human. Precisa de você." % (marker_id, STRANDED_MAX_ATTEMPTS), 4)
                    marker_action = "escalated:needs-human"
                else:
                    if n > 0:
                        sh(["bd", "-C", CITY, "label", "remove", marker_id, "grw-stranded:%d" % n, "-q"], timeout=15)
                    sh(["bd", "-C", CITY, "label", "add", marker_id, "grw-stranded:%d" % (n + 1), "-q"], timeout=15)
                    set_gate_status_py(marker_id, "queued")
                    sh(["bd", "-C", CITY, "comment", marker_id,
                        "gate-recovery-watchdog FIX5: re-queued (->queued) after superseding its STRANDED run %s (%d/%d verdicts delivered but never finalized, %dm). A fresh sweep re-reviews + finalizes. (recovery %d/%d)"
                        % (rid, delivered, total, age // 60, n + 1, STRANDED_MAX_ATTEMPTS)], timeout=25)
                    marker_action = "requeued"
        _recovery_ledger("recover_stranded_run", {"run": rid, "age_min": age // 60,
                         "delivered": delivered, "total": total, "marker": marker_id,
                         "marker_action": marker_action, "source_bead": source_bead,
                         "cleared_gate_reviewing": cleared_reviewing})
        notify("Gate self-heal: run com veredito órfão recuperado (%s, %d/%d entregues, %dmin, nunca finalizou) — marker %s %s. Você não precisa agir."
               % (rid, delivered, total, age // 60, marker_id or "?", marker_action), 3)
        print("[watchdog] FIX5 RECOVERED stranded run=%s age=%dm %d/%d verdicts marker=%s action=%s cleared_reviewing=%s"
              % (rid, age // 60, delivered, total, marker_id, marker_action, cleared_reviewing), flush=True)
        acted += 1
    if acted:
        print("[watchdog] FIX5 stranded-verdict sweep: %d run(s) recovered%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def reap_frozen_reviewers(sessions, now, rstate, open_running_runs):
    """FIX 3: kill a FROZEN gate-reviewer — state=active but last_active silent past
    FROZEN_KILL_SECS. This is the gap reap_hung_runs (FIX 1) can't see: a frozen
    reviewer reads active, so hung_run_verdict returns skip:reviewer-active and the
    run is KEPT; meanwhile the dispatcher's ga-q8tmn re-convene runs out of respawn
    budget (2) and waits the full 45m outer timeout — the exact 90-min stall the Mayor
    cleared by hand (2026-07-02: 6ohacd silent 34m, queue starved to 531m). `gc session
    kill` makes the reconciler revive the reviewer in place. SUSTAINED-confirmed (a
    reviewer mid-think that resumes between samples is never killed) + bounded +
    dry-run-aware + fully fail-safe (unparseable/future/fresh last_active → never
    killed; a gc/Dolt outage returns sessions=None → skip).

    ga-pp5vh: after a confirmed kill, also hands the (session, run-set) to
    _requeue_run_after_frozen_kill — killing the session alone left its gate-run
    orphaned at gate-status:running for up to the dispatcher's own ~29min Phase C
    timeout, zeroing throughput on a single-item queue. rstate/open_running_runs are
    threaded through only for that extension (mirrors reap_hung_runs' signature)."""
    if not GRW_ENABLED or not GRW_REAP_FROZEN_ENABLED:
        return
    if sessions is None:
        return  # cannot verify liveness → fail-safe skip (never a blind kill)
    # candidates: active gate-reviewer sessions silent past the threshold
    cand = []
    for s in sessions:
        if s.get("template") != "gate-reviewer" or s.get("closed"):
            continue
        la = _last_active_epoch(s.get("last_active"))
        if la is None:
            continue
        silence = int(now - la)
        if frozen_reviewer_verdict(s.get("state"), silence, FROZEN_KILL_SECS) == "kill":
            # ga-pp5vh: keep the FULL session dict (was: id/last_active/silence scalars
            # only) — the post-kill run/marker recovery needs every identity field a
            # verdict-bead assignee could carry (session_name/alias/agent_name), not
            # just id, to correlate the killed session against a run's pending reviewers.
            cand.append((s, silence))
    if not cand:
        return
    # SUSTAINED confirm: re-sample after a gap. A reviewer whose last_active ADVANCED
    # (it was mid-think, not wedged) is dropped — only STILL-silent sessions are killed.
    time.sleep(LIVENESS_RESAMPLE_SEC)
    s2 = _session_list_json()
    idx2 = {str(s.get("id")): s for s in s2} if s2 else None
    killed = 0
    for s0, silence in cand:
        if killed >= FROZEN_KILL_MAX_PER_SWEEP:
            break
        sid = s0.get("id")
        la_iso = s0.get("last_active")
        if not sid:
            continue
        s_fresh = s0
        if idx2 is not None:
            s = idx2.get(str(sid))
            if s is None:
                continue  # session gone on its own (reconciler/dispatcher acted) → done
            la2 = _last_active_epoch(s.get("last_active"))
            now2 = time.time()
            if frozen_reviewer_verdict(s.get("state"),
                                       (int(now2 - la2) if la2 is not None else None),
                                       FROZEN_KILL_SECS) != "kill":
                print("[watchdog] frozen-reviewer %s RESUMED/changed on resample — NOT killing (fail-safe)" % sid, flush=True)
                continue
            s_fresh = s
        if GRW_DRY_RUN:
            print("[watchdog] FROZEN DRY-RUN would kill reviewer %s (last_active=%s, silent %dm) → reconciler revives fresh"
                  % (sid, la_iso, silence // 60), flush=True)
            _recovery_ledger("would_kill_frozen_reviewer",
                             {"session": sid, "last_active": la_iso, "silent_min": silence // 60, "dry_run": True})
        else:
            sh(["gc", "session", "kill", sid], timeout=20)
            _recovery_ledger("kill_frozen_reviewer",
                             {"session": sid, "last_active": la_iso, "silent_min": silence // 60})
            notify("Gate self-heal: revisor CONGELADO morto (%s, %dmin sem atividade, active-mas-mudo) — reconciler sobe fresco. Você não precisa agir."
                   % (sid, silence // 60), 3)
            print("[watchdog] KILLED frozen reviewer %s (last_active=%s, silent %dm) — reconciler revives fresh (grw FIX3 frozen-reviewer self-heal)"
                  % (sid, la_iso, silence // 60), flush=True)
        killed += 1
        # ga-pp5vh: run in BOTH branches — GRW_DRY_RUN is a global flag, so a dry-run
        # sweep hits this function's OWN internal dry-run guard (read-only preview,
        # never mutates) instead of skipping the extension outright. Without this a
        # dry run would never preview the cascading supersede+requeue effect.
        try:
            _requeue_run_after_frozen_kill(s_fresh, sid, now, rstate, open_running_runs)
        except Exception as e:
            print("[watchdog] FIX3-requeue error for killed reviewer %s (continuing): %r" % (sid, e), flush=True)
    if killed:
        print("[watchdog] frozen-reviewer sweep: %d killed%s" % (killed, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def _requeue_run_after_frozen_kill(killed_session, sid, now, rstate, open_running_runs):
    """FIX 3 extension (ga-pp5vh): after reap_frozen_reviewers kills a confirmed-frozen
    reviewer, close the gap between that kill (~FROZEN_KILL_SECS) and the dispatcher's
    own Phase C run-timeout (~29min) that used to be the only thing re-queuing the
    orphaned run — on a single-item queue that gap zeroed gate throughput for the full
    interval (the 2026-07-22 incident this bug fixes). If the killed session was the
    run's ONLY pending reviewer, the run is now provably stuck (nobody left who could
    ever deliver a verdict): supersede it and hand its marker to the SAME requeue-or-
    escalate path FIX 6 uses for a dead reviewer with no run — same underlying symptom
    (this branch keeps drawing a dead reviewer), same shared grw-stale-review:<n>
    counter. A run where another reviewer is still pending is left untouched for FIX
    1/timeout — one dead reviewer must never terminate a run others are still working.
    Boot-grace is inherited for free: this only ever runs on a session
    reap_frozen_reviewers already SUSTAINED-confirmed frozen (state=active, silent
    >=FROZEN_KILL_SECS), which a booting reviewer (state=creating) can never be.
    Best-effort; never raises on its own (the caller also wraps it, since a bug here
    must not turn a successful kill into an unhandled sweep exception)."""
    if not GRW_ENABLED or not GRW_FROZEN_REQUEUE_ENABLED:
        return
    if open_running_runs is None:
        return  # run query unavailable this sweep → fail-safe skip (no blind supersede)
    identities = set(_session_index([killed_session]).keys()) if killed_session else {str(sid)}
    if not identities:
        return
    for run in open_running_runs:
        rid = run.get("id")
        if not rid:
            continue
        pending = _run_pending_reviewers(rid)
        if frozen_reviewer_run_verdict(pending, identities) != "supersede":
            continue
        # SUSTAINED-confirm: re-read after a gap — a verdict landing or another
        # reviewer joining between the kill and here must abort (never race a live run).
        time.sleep(LIVENESS_RESAMPLE_SEC)
        if _bead_is_open(rid) is False:
            print("[watchdog] FIX3-requeue: run=%s finalized/closed between samples — no action" % rid, flush=True)
            continue
        pending2 = _run_pending_reviewers(rid)
        if frozen_reviewer_run_verdict(pending2, identities) != "supersede":
            print("[watchdog] FIX3-requeue: run=%s no longer solely-pending-on-killed-session after resample — fail-safe KEPT" % rid, flush=True)
            continue
        desc = run.get("description") or ""
        marker_id = _parse_run_field(desc, "marker_id")
        if GRW_DRY_RUN:
            print("[watchdog] FIX3-requeue DRY would supersede run=%s (sole pending reviewer %s just killed) → requeue marker=%s"
                  % (rid, sid, marker_id), flush=True)
            _recovery_ledger("would_requeue_run_after_frozen_kill",
                             {"run": rid, "session": sid, "marker": marker_id, "dry_run": True})
            return
        # 1) supersede + close the now-provably-stuck run.
        set_gate_status_py(rid, "superseded")
        sh(["bd", "-C", CITY, "comment", rid,
            "gate-recovery-watchdog FIX3: sole pending reviewer session %s was just killed as FROZEN (active but silent — see kill_frozen_reviewer above). No other reviewer can land a verdict on this run. Superseding + handing marker %s to the FIX6 requeue path instead of waiting for the dispatcher's ~29min Phase C timeout. (ga-pp5vh)"
            % (sid, marker_id or "unknown")], timeout=25)
        sh(["bd", "-C", CITY, "close", rid,
            "-r", "gate-run superseded: sole pending reviewer frozen+killed (grw FIX3 requeue, ga-pp5vh)"], timeout=25)
        # 2) hand the marker to the shared FIX6 requeue-or-escalate mechanism.
        marker_action = "no-marker"
        if marker_id:
            m_open = _bead_is_open(marker_id)
            if m_open is False:
                marker_action = "marker-already-closed"
            elif m_open is None:
                marker_action = "marker-state-unknown-skip"
            else:
                m = _bead_row(marker_id)
                status = _label_value(m, "gate-status:") or "reviewing"
                action, attempts_shown, cleared_reviewing = _requeue_or_escalate_review_marker(
                    marker_id, m, status,
                    "its sole pending reviewer session %s froze (active but last_active silent >=%dm) and was killed by FIX 3; the run was superseded since no one else could ever deliver a verdict"
                    % (sid, FROZEN_KILL_SECS // 60),
                    now, rstate, "FIX3")
                marker_action = action
                if action == "requeued":
                    notify("Gate self-heal: run com único revisor CONGELADO morto foi encerrado — marker %s re-enfileirado p/ re-revisão. Você não precisa agir."
                           % marker_id, 3)
                print("[watchdog] FIX3-requeue: run=%s superseded (sole pending reviewer %s killed) marker=%s action=%s cleared_reviewing=%s"
                      % (rid, sid, marker_id, action, cleared_reviewing), flush=True)
        _recovery_ledger("requeue_run_after_frozen_kill",
                         {"run": rid, "session": sid, "marker": marker_id, "marker_action": marker_action})
        return  # a session reviews at most one run at a time — done


def reap_orphan_and_stale_markers(now):
    """FIX 4: for each open gate-status:queued/ready/claimed marker older than
    ORPHAN_MARKER_MIN_MINUTES, either close it (SOURCE already closed → orphaned/phantom
    depth) or clear a leaked gate:reviewing on its OPEN source (the head-of-line
    STARVATION root — a reviewer drained during startup and left the label, so the
    dispatcher skips re-dispatch forever). FIX 1/2 don't cover this (they handle
    running-run reaps + gate-status:error). Bounded, dry-run-aware, fully fail-safe:
    an unreadable source → keep; a query failure → skip the whole sweep."""
    if not GRW_ENABLED or not GRW_REAP_ORPHAN_ENABLED:
        return
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",  # ga-h199q
            "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return  # query failure → fail-safe skip (no blind action)
    try:
        markers = json.loads(r.stdout) or []
    except Exception:
        return
    acted = 0
    for m in markers:
        if acted >= ORPHAN_MAX_PER_SWEEP:
            break
        mid = m.get("id")
        if not mid:
            continue
        if _label_value(m, "gate-status:") not in ("queued", "ready", "claimed"):
            continue
        age = int(now - (_iso_epoch(m.get("updated_at")) or now))
        src = _label_value(m, "source-bead:")
        rig = _label_value(m, "bead-rig:") or _label_value(m, "rig:")
        resolved, closed, reviewing, store = _source_review_state(src, rig)
        branch = _label_value(m, "branch:")
        # Pay for the git-ancestry check ONLY when the source is CLOSED — the sole case
        # where 'source closed' could be a FALSE 'merged' (the sling-task-janitor closes
        # fix-task beads without the branch landing). Otherwise it's irrelevant.
        branch_state = _branch_merged_state(branch, rig) if (resolved and closed) else "unknown"
        v = orphan_marker_verdict(age, ORPHAN_MARKER_MIN_MINUTES * 60, resolved, closed,
                                  reviewing, branch_state)
        if v in ("wait", "keep"):
            continue
        if GRW_DRY_RUN:
            print("[watchdog] FIX4 DRY would %s marker=%s src=%s age=%dm" % (v, mid, src, age // 60), flush=True)
            _recovery_ledger("would_" + v.replace("-", "_"),
                             {"marker": mid, "source_bead": src, "age_min": age // 60, "dry_run": True})
            acted += 1
            continue
        if v == "recover-stranded":
            # Source CLOSED but branch NOT merged → a FALSE 'merged' close stranded a
            # complete fix (ga-w5agg/ga-d2jil). Re-land it: reopen the source (so the
            # janitor/dispatcher treat it as live) + re-queue the marker so a fresh sweep
            # re-reviews and merges. NEVER close a marker whose fix hasn't landed.
            if src:
                sh(["bd", "-C", store, "update", src, "--status", "open"], timeout=20)
            set_gate_status_py(mid, "queued")
            sh(["bd", "-C", CITY, "comment", mid,
                "gate-recovery-watchdog FIX4-recover: source %s is CLOSED but branch %s is NOT merged into origin/main — a false-'merged' close (the janitor orphaned the fix-task without it landing). Reopened the source + re-queued so the fix RE-LANDS instead of being stranded. (the ga-w5agg/ga-d2jil class)" % (src, branch or "?")], timeout=25)
            _recovery_ledger("recover_stranded_marker", {"marker": mid, "source_bead": src,
                             "branch": branch, "age_min": age // 60})
            notify("Gate self-heal: fix ENCALHADO recuperado (marker %s — fonte %s fechada mas branch %s NÃO-mergeado) — reaberto + re-enfileirado. Você não precisa agir." % (mid, src, branch or "?"), 3)
            print("[watchdog] FIX4-recover RE-LANDED stranded marker=%s (source %s closed but branch %s unmerged) — reopened+requeued" % (mid, src, branch), flush=True)
        elif v == "close-source-done":
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid, "-r",
                "source bead %s CLOSED and branch %s VERIFIED merged/absent (grw FIX4 phantom-depth self-heal — merge confirmed via git ancestry, not assumed from a closed source)" % (src, branch or "?")], timeout=25)
            _recovery_ledger("close_orphan_marker", {"marker": mid, "source_bead": src, "branch": branch, "branch_state": branch_state, "age_min": age // 60})
            notify("Gate self-heal: marker órfão fechado (%s — fonte %s concluída, merge confirmado). Profundidade-fantasma removida." % (mid, src), 3)
            print("[watchdog] FIX4 CLOSED orphan marker=%s (source %s closed, branch %s, %dm) — phantom depth removed" % (mid, src, branch_state, age // 60), flush=True)
        else:  # clear-stale-reviewing
            sh(["bd", "-C", store, "label", "remove", src, "gate:reviewing", "-q"], timeout=20)
            sh(["bd", "-C", store, "comment", src,
                "grw FIX4: cleared STALE gate:reviewing (marker %s sat QUEUED %dm while source carried gate:reviewing — a reviewer drained during startup and left the label, no terminal path cleared it). The dispatcher can re-dispatch this branch now (was head-of-line starved)." % (mid, age // 60)], timeout=20)
            _recovery_ledger("clear_stale_reviewing", {"marker": mid, "source_bead": src, "store": store, "age_min": age // 60})
            notify("Gate self-heal: gate:reviewing fantasma limpo em %s (marker %s estava faminto %dmin). Volta a despachar." % (src, mid, age // 60), 3)
            print("[watchdog] FIX4 CLEARED stale gate:reviewing on %s (marker %s starved %dm) — starvation self-heal" % (src, mid, age // 60), flush=True)
        acted += 1
    if acted:
        print("[watchdog] FIX4 orphan/stale sweep: %d marker(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def stale_review_marker_verdict(status, age_sec, min_sec, has_open_run):
    """PURE decision (no I/O, unit-tested) for FIX 6, on an OPEN gate-marker whose
    gate-status is dispatching|reviewing:
      'requeue'                — sits dispatching|reviewing past min_sec with NO open
                                 running run (reviewer dead, no hung RUN for FIX 1/5 to
                                 own) → requeue so the dispatcher re-reviews the branch.
      'wait'                   — younger than min_sec (normal dispatch→run-create spin-up).
      'skip:not-review-status' — not a dispatching|reviewing marker (FIX 4 owns queued/
                                 ready/claimed; every other state is terminal).
      'skip:live-run'          — an open running run exists for it → FIX 1/5 own the reap;
                                 FIX 6 never double-handles a live/hung review.
      'skip:run-query-failed'  — has_open_run is None (the run query failed) → fail-safe,
                                 NEVER requeue blind (a Dolt glitch must not duplicate a
                                 live review by falsely concluding 'no run')."""
    if status not in ("dispatching", "reviewing"):
        return "skip:not-review-status"
    if age_sec < min_sec:
        return "wait"
    if has_open_run is None:
        return "skip:run-query-failed"
    if has_open_run:
        return "skip:live-run"
    return "requeue"


def _markers_with_open_run(runs):
    """Set of marker_ids that currently have an OPEN gate-status:running gate-run
    (parsed from each run's `marker_id:` description field). None if runs is None
    (query failure) so the caller fail-safe treats liveness as UNKNOWN and skips."""
    if runs is None:
        return None
    out = set()
    for run in runs:
        mid = _parse_run_field(run.get("description") or "", "marker_id")
        if mid:
            out.add(mid)
    return out


def _requeue_or_escalate_review_marker(mid, m, status, reason, now, rstate, context):
    """Shared dead-reviewer recovery for a review marker: either requeue it back to
    gate-status:queued (clearing its source's leaked gate:reviewing) so a fresh
    dispatcher sweep re-reviews the EXISTING branch — or, once
    STALE_REVIEW_MAX_ATTEMPTS reviewers have died on the SAME marker, escalate to
    parked-needs-human instead of an infinite re-review loop. Shared by FIX 6 (a dead
    reviewer left no open run to reap) and FIX 3 (ga-pp5vh: a frozen reviewer WAS just
    killed and its now-orphaned run superseded) — both are the same underlying symptom
    (this branch keeps drawing a dead reviewer), so they share ONE
    grw-stale-review:<n> counter: a reviewer dying via one path counts toward the
    other's cap too. `reason` is the caller-specific why-clause folded into the bd
    comment/escalation message; `context` is a short provenance tag ('FIX6'/'FIX3')
    for logs/ledger. `m` must carry at least id/labels/updated_at (a list row or a
    _bead_row() fetch both qualify). Returns (action, attempts_shown,
    cleared_reviewing) — action is 'requeued'|'escalated'."""
    src = _label_value(m, "source-bead:")
    rig = _label_value(m, "bead-rig:") or _label_value(m, "rig:")
    branch = _label_value(m, "branch:")
    age = int(now - (_iso_epoch(m.get("updated_at")) or now))
    attempts = 0
    for lb in (m.get("labels") or []):
        mm = GRW_STALE_REVIEW_LABEL_RE.match(str(lb))
        if mm:
            try:
                attempts = int(mm.group(1))
            except Exception:
                attempts = 0
    resolved, sclosed, reviewing, store = _source_review_state(src, rig)
    if attempts >= STALE_REVIEW_MAX_ATTEMPTS:
        # reviewers keep dying on this branch → stop re-reviewing, hand to a human.
        set_gate_status_py(mid, "parked-needs-human")
        sh(["bd", "-C", CITY, "comment", mid,
            "gate-recovery-watchdog %s: marker re-stranded %d× (reviewers keep dying mid-review — %s) — escalating to parked-needs-human instead of another futile re-review. Cleared the phantom gate:reviewing so the Pilot stops seeing a live review. (grw stale-review cap, shared FIX3+FIX6)"
            % (context, attempts, reason)], timeout=25)
        if resolved and reviewing:
            sh(["bd", "-C", store, "label", "remove", src, "gate:reviewing", "-q"], timeout=20)
        _recovery_ledger("escalate_stale_review_marker",
                         {"marker": mid, "source_bead": src, "status": status, "age_min": age // 60,
                          "attempts": attempts, "branch": branch, "context": context})
        if rstate.escalate_once("stale-review-osc:%s" % mid, now):
            notify("🚨 Gate: marker %s encalhou %d× (revisor morre repetido) — parkeado p/ needs-human. Precisa de você (branch %s)."
                   % (mid, attempts, branch or "?"), 5)
            _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical",
                        "bead_id": src or "", "reason": "stale-review marker %s re-stranded %d× — parked needs-human" % (mid, attempts)}, fail_open=True)
        return ("escalated", attempts, False)
    # 1) stamp the restart-safe counter FIRST (a crash mid-op must not lose the
    #    oscillation history and loop forever), then requeue the marker → the
    #    dispatcher re-reviews the EXISTING branch (no rebuild).
    for lb in (m.get("labels") or []):
        if GRW_STALE_REVIEW_LABEL_RE.match(str(lb)):
            sh(["bd", "-C", CITY, "label", "remove", mid, str(lb), "-q"])
    sh(["bd", "-C", CITY, "label", "add", mid, "grw-stale-review:%d" % (attempts + 1), "-q"])
    set_gate_status_py(mid, "queued")
    sh(["bd", "-C", CITY, "comment", mid,
        "gate-recovery-watchdog %s: %s. Re-queued (→gate-status:queued) so a fresh dispatcher sweep re-reviews branch %s (the existing fix, no rebuild). attempt %d/%d."
        % (context, reason, branch or "?", attempts + 1, STALE_REVIEW_MAX_ATTEMPTS)], timeout=25)
    # 2) clear the source's leaked gate:reviewing (the phantom 'em revisão').
    cleared_reviewing = False
    if resolved and reviewing:
        sh(["bd", "-C", store, "label", "remove", src, "gate:reviewing", "-q"], timeout=20)
        cleared_reviewing = True
    _recovery_ledger("requeue_stale_review_marker",
                     {"marker": mid, "source_bead": src, "status": status, "age_min": age // 60,
                      "attempt": attempts + 1, "cleared_gate_reviewing": cleared_reviewing,
                      "branch": branch, "context": context})
    return ("requeued", attempts + 1, cleared_reviewing)


def reap_stale_review_markers(now, rstate, open_running_runs):
    """FIX 6: requeue a marker STRANDED at gate-status:dispatching|reviewing whose
    reviewer DIED leaving NO open running run — the wa-ppe5v orphan (the Pilot counts
    dispatching|reviewing as active and DROPS the gate:needs-fix source forever). Each
    sweep, for an open dispatching|reviewing marker older than STALE_REVIEW_MARKER_MINUTES
    with NO open running run (confirmed across a resample): requeue → gate-status:queued
    (the dispatcher re-reviews the EXISTING branch, no rebuild) + clear the source's
    leaked gate:reviewing. A per-marker attempt cap escalates to needs-human. Bounded,
    dry-run-aware, fully fail-safe (unreadable → skip; a live/hung run → defer to FIX 1/5)."""
    if not GRW_ENABLED or not GRW_REAP_STALE_REVIEW_ENABLED:
        return
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",  # ga-h199q
            "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return  # query failure → fail-safe skip (no blind action)
    try:
        markers = json.loads(r.stdout) or []
    except Exception:
        return
    open_run_markers = _markers_with_open_run(open_running_runs)
    acted = 0
    for m in markers:
        if acted >= STALE_REVIEW_MAX_PER_SWEEP:
            break
        mid = m.get("id")
        if not mid:
            continue
        status = _label_value(m, "gate-status:")
        if status not in ("dispatching", "reviewing"):
            continue
        age = int(now - (_iso_epoch(m.get("updated_at")) or now))
        has_open_run = None if open_run_markers is None else (mid in open_run_markers)
        v = stale_review_marker_verdict(status, age, STALE_REVIEW_MARKER_MINUTES * 60, has_open_run)
        if v != "requeue":
            if GRW_DRY_RUN and v != "skip:not-review-status":
                print("[watchdog] FIX6 DRY skip marker=%s status=%s age=%dm (%s)"
                      % (mid, status, age // 60, v), flush=True)
            continue
        # SUSTAINED-confirm: a dispatch CREATING its run right now (or a transient
        # run-query blip) will show an open run — or the marker will have advanced —
        # on a second sample after a short gap → abort. Never requeue a live review.
        time.sleep(LIVENESS_RESAMPLE_SEC)
        open_run_markers2 = _markers_with_open_run(_open_running_runs())
        if open_run_markers2 is None or (mid in open_run_markers2):
            print("[watchdog] FIX6 marker=%s NOT requeued after resample (run appeared / query failed) — fail-safe KEPT"
                  % mid, flush=True)
            continue
        status2 = _label_value({"labels": _bead_labels(mid)}, "gate-status:")
        if status2 not in ("dispatching", "reviewing"):
            print("[watchdog] FIX6 marker=%s advanced to '%s' during resample — fail-safe KEPT"
                  % (mid, status2 or "?"), flush=True)
            continue
        src = _label_value(m, "source-bead:")
        if GRW_DRY_RUN:
            attempts = 0
            for lb in (m.get("labels") or []):
                mm = GRW_STALE_REVIEW_LABEL_RE.match(str(lb))
                if mm:
                    try:
                        attempts = int(mm.group(1))
                    except Exception:
                        attempts = 0
            print("[watchdog] FIX6 DRY would %s STALE %s marker=%s src=%s age=%dm attempts=%d"
                  % ("ESCALATE" if attempts >= STALE_REVIEW_MAX_ATTEMPTS else "requeue",
                     status, mid, src, age // 60, attempts), flush=True)
            _recovery_ledger("would_requeue_stale_review_marker",
                             {"marker": mid, "source_bead": src, "status": status,
                              "age_min": age // 60, "attempts": attempts, "dry_run": True})
            acted += 1
            continue
        action, attempts_shown, cleared_reviewing = _requeue_or_escalate_review_marker(
            mid, m, status,
            "reviewer died mid-review (drain/sleep/quota/crash) leaving no hung RUN for FIX 1/5 to own; sat gate-status:%s %dm. The Pilot was DROPPING the gate:needs-fix source %s as 'actively gating' on this dead marker (wa-ppe5v)"
            % (status, age // 60, src or "?"),
            now, rstate, "FIX6")
        if action == "escalated":
            print("[watchdog] FIX6 ESCALATED marker=%s (re-stranded %d× at %s) → parked-needs-human"
                  % (mid, attempts_shown, status), flush=True)
        else:
            notify("Gate self-heal: marker travado em %s reapado (%s, %dmin, revisor morto sem run) — re-enfileirado p/ re-revisão. Você não precisa agir."
                   % (status, mid, age // 60), 3)
            print("[watchdog] FIX6 REQUEUED stale %s marker=%s src=%s age=%dm attempt=%d cleared_reviewing=%s"
                  % (status, mid, src, age // 60, attempts_shown, cleared_reviewing), flush=True)
        acted += 1
    if acted:
        print("[watchdog] FIX6 stale-review sweep: %d marker(s) requeued/escalated%s"
              % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def _open_error_markers():
    """[marker dicts] type:quality-gate-marker + gate-status:error + open, in HQ (the
    dispatcher's domain — it only re-processes HQ queued markers). None on query
    failure (fail-safe skip)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",  # ga-h199q
            "-l", "gate-status:error", "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout) or []
    except Exception:
        return None


def _mail_oscillating_error_marker(mid, branch, source_bead, rig_name, req_count,
                                    max_attempts, age_sec, resolved):
    """ga-rwzj: durable, actionable escalation for a gate-status:error marker that
    exhausted its requeue cap. notify() (the caller's other escalation) is a
    transient push — if the Mayor is away when it fires, the signal is gone with
    nothing left to act on; that gap stranded 4 markers 9.9-11.6h until a human
    counted them by hand. This mail is SECONDARY (best-effort, never blocks the
    notify) but persists in the inbox with the branch, a source-clean check, and
    the ready-to-run re-submit command already spelled out, so whoever reads it
    hours later doesn't have to reconstruct context from scratch."""
    clean_desc = (
        "source bead NÃO resolvido (query falhou ou bead sumiu) — confirme o estado "
        "do source ANTES de reenfileirar"
    ) if not resolved else (
        "source aberto e sem gate:needs-human — reenfileirar é seguro SE a causa raiz "
        "(root) já foi corrigida; senão vai re-errorar de novo"
    )
    resubmit_cmd = (
        "bd -C %s label remove %s gate-status:error -q && "
        "bd -C %s label add %s gate-status:queued -q"
    ) % (CITY, mid, CITY, mid)
    subject = "Gate: marker %s preso oscilando em gate-status:error" % mid
    body = (
        "Marker %s esgotou o cap de auto-requeue (%d/%d tentativas) e continua "
        "re-errorando. O watchdog PAROU — não é mais transiente, precisa de você.\n\n"
        "Branch: %s\n"
        "Source bead: %s (%s)\n"
        "Idade em gate-status:error: %dmin\n"
        "Source-clean-check: %s\n\n"
        "Comando de re-submit pronto (rode DEPOIS de confirmar a causa raiz):\n"
        "  %s\n\n"
        "(gate-recovery-watchdog FIX 2 — escalação de oscillating-error, ga-rwzj)"
    ) % (mid, req_count, max_attempts, branch or "?", source_bead or "?", rig_name or "?",
         age_sec // 60, clean_desc, resubmit_cmd)
    r = sh(["gc", "mail", "send", "mayor", "-s", subject, "-m", body], timeout=45)
    if not (r and r.returncode == 0):
        print("[watchdog] WARN: gc mail send mayor FAILED for oscillating marker %s — notify still sent (grw)"
              % mid, flush=True)


def requeue_error_markers(now, rstate):
    """FIX 2: auto-requeue a STUCK gate-status:error marker (error → queued) — the
    error→queued flip the Mayor did by hand ~6x today. Bounded per sweep, dry-run
    aware, fully fail-safe. Carve-outs: a marker whose SOURCE BEAD is closed is
    closed (not requeued); a ga-acb needs-human park is left alone; a marker that
    keeps re-erroring past ERROR_REQUEUE_MAX_ATTEMPTS is escalated to the Mayor
    instead of looped forever."""
    if not GRW_ENABLED or not GRW_REQUEUE_ERROR_ENABLED:
        return
    markers = _open_error_markers()
    if markers is None:
        print("[watchdog] requeue: error-marker query unavailable — fail-safe skip", flush=True)
        return
    # oldest-error first (created_at asc) so the longest-stuck marker is served first
    markers.sort(key=lambda m: _iso_epoch(m.get("created_at")) or 0.0)
    acted = 0
    for mk in markers:
        if acted >= ERROR_REQUEUE_MAX_PER_SWEEP:
            break
        mid = mk.get("id")
        if not mid:
            continue
        upd = _iso_epoch(mk.get("updated_at")) or _iso_epoch(mk.get("created_at"))
        age = int(now - upd) if upd else 0
        labels = mk.get("labels") or []
        source_bead = _label_value(mk, "source-bead:")
        rig_name = _label_value(mk, "bead-rig:")
        branch = _label_value(mk, "branch:")
        label_count = 0
        for l in labels:
            m = GRW_REQUEUE_LABEL_RE.match(l)
            if m:
                try:
                    label_count = int(m.group(1))
                except Exception:
                    label_count = 0
        req_count = max(label_count, rstate.error_requeues.get(mid, 0))
        resolved, sclosed, needs_human = _source_bead_state(source_bead, rig_name)
        # Pay for the git-ancestry check ONLY when the source is CLOSED — the sole case
        # where 'source closed' could be a FALSE 'done' (ga-hckn3, porting ga-gd706: the
        # normal dog-self-closes-its-sling-bead-on-submission doctrine closes the source
        # immediately after /gate-done, regardless of whether a reviewer ever ran).
        # Mirrors reap_orphan_and_stale_markers' FIX 4 gating exactly.
        branch_state = _branch_merged_state(branch, rig_name) if (resolved and sclosed) else "unknown"
        verdict = error_requeue_verdict(age, ERROR_REQUEUE_MINUTES * 60, resolved,
                                        sclosed, needs_human, req_count, ERROR_REQUEUE_MAX_ATTEMPTS,
                                        branch_state)

        if verdict == "skip:young":
            continue
        if verdict == "skip:parked-needs-human":
            if rstate.escalate_once("error-parked:%s" % mid, now):
                print("[watchdog] error marker %s parked (source %s needs-human) — left for human (grw)"
                      % (mid, source_bead), flush=True)
            continue

        if verdict == "close:source-done":
            if GRW_DRY_RUN:
                print("[watchdog] requeue DRY-RUN would CLOSE error marker %s (source bead %s closed, branch %s VERIFIED merged/absent — work done)"
                      % (mid, source_bead, branch_state), flush=True)
                _recovery_ledger("would_close_done_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "branch_state": branch_state, "dry_run": True})
                acted += 1
                continue
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid,
                "-r", "source bead %s closed and branch %s VERIFIED merged/absent (%s) — error marker superseded (grw error-marker self-heal, ga-hckn3 hardening — merge confirmed via git ancestry, not assumed from a closed source)"
                % (source_bead, branch or "?", branch_state)], timeout=25)
            _recovery_ledger("closed_done_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "branch_state": branch_state})
            print("[watchdog] CLOSED done error marker %s (source %s closed, branch %s)" % (mid, source_bead, branch_state), flush=True)
            acted += 1
            continue

        if verdict == "escalate:oscillating":
            if rstate.escalate_once("error-osc:%s" % mid, now):
                notify("🚨 Gate: marker %s (branch %s) re-erra em loop — já re-enfileirei %dx e continua falhando. Precisa de você (não é transiente). (grw)"
                       % (mid, branch or "?", req_count), 5)
                _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                            "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical",
                            "bead_id": source_bead or "", "reason": "error marker %s oscillating (%d watchdog requeues, still re-errors) — needs human" % (mid, req_count)}, fail_open=True)
                _mail_oscillating_error_marker(mid, branch, source_bead, rig_name, req_count,
                                                ERROR_REQUEUE_MAX_ATTEMPTS, age, resolved)
                print("[watchdog] ESCALATED oscillating error marker %s (%d requeues, still re-errors) — NOT requeued again" % (mid, req_count), flush=True)
            continue

        # verdict == "requeue"
        if GRW_DRY_RUN:
            print("[watchdog] requeue DRY-RUN would re-queue error marker %s (branch %s, %dm in error, attempt %d/%d) → gate-status:queued"
                  % (mid, branch or "?", age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS), flush=True)
            _recovery_ledger("would_requeue_error", {"marker": mid, "branch": branch, "age_min": age // 60,
                             "attempt": req_count + 1, "dry_run": True})
            acted += 1
            continue
        # stamp the restart-safe counter FIRST (so a crash mid-op cannot lose the
        # oscillation history and loop forever), then flip error→queued.
        for l in labels:
            if GRW_REQUEUE_LABEL_RE.match(l):
                sh(["bd", "-C", CITY, "label", "remove", mid, l, "-q"])
        sh(["bd", "-C", CITY, "label", "add", mid, "grw-requeue:%d" % (req_count + 1), "-q"])
        rstate.error_requeues[mid] = req_count + 1
        set_gate_status_py(mid, "queued")
        sh(["bd", "-C", CITY, "comment", mid,
            "gate-recovery-watchdog: auto-requeued gate-status:error→queued after %dm stuck in error (attempt %d/%d). A transient dispatcher error/ghost-yield/reclaim left this marker stranded; the dispatcher only re-processes queued markers. (grw error-marker self-heal — the manual error→queued the Mayor did ~6x/day)"
            % (age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS)], timeout=25)
        _recovery_ledger("requeue_error", {"marker": mid, "branch": branch, "source_bead": source_bead,
                         "age_min": age // 60, "attempt": req_count + 1})
        notify("Gate self-heal: marker %s re-enfileirado (error→queued, branch %s, %dmin travado, tentativa %d/%d). Você não precisa agir."
               % (mid, branch or "?", age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS), 3)
        print("[watchdog] REQUEUED error marker %s (branch %s, %dm, attempt %d/%d)"
              % (mid, branch or "?", age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS), flush=True)
        acted += 1
    if acted:
        print("[watchdog] error-requeue sweep: %d marker(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def _open_deferred_markers():
    """[marker dicts] type:quality-gate-marker + gate-status:deferred + open, in HQ.
    None on query failure (fail-safe skip)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",  # ga-h199q
            "-l", "gate-status:deferred", "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout) or []
    except Exception:
        return None


def _mail_oscillating_deferred_marker(mid, branch, source_bead, rig_name, attempts,
                                       max_attempts, age_sec):
    """ga-76kc: durable, actionable escalation for a gate-status:deferred marker that
    exhausted DEFERRED_REQUEUE_MAX_ATTEMPTS while its author WAS derivable —
    deferred_requeue_verdict() only returns escalate:oscillating when
    has_derivable_author is True (an unresolvable marker takes close:unresolvable
    instead, a separate path), so there is no "unresolved" branch to describe here
    the way _mail_oscillating_error_marker's clean_desc has. Mirrors that function
    (added in the ga-rwzj fix) for the deferred path: notify() (the caller's other
    escalation) is a transient push — if the Mayor is away when it fires, the
    signal is gone with nothing left to act on. This mail is SECONDARY
    (best-effort, never blocks the notify) but persists in the inbox with the
    branch and the ready-to-run re-submit command already spelled out, so whoever
    reads it hours later doesn't have to reconstruct context from scratch."""
    author_desc = (
        "author JÁ era derivável (gate.submitted_by do marker OU os campos do "
        "source bead) quando o watchdog esgotou o cap de requeue — o requeue "
        "automático não é o problema; o dispatcher/guard está re-deferindo por "
        "outro motivo. Investigue esse motivo antes de reenfileirar de novo"
    )
    resubmit_cmd = (
        "bd -C %s label remove %s gate-status:deferred -q && "
        "bd -C %s label add %s gate-status:queued -q"
    ) % (CITY, mid, CITY, mid)
    subject = "Gate: marker %s preso oscilando em gate-status:deferred" % mid
    body = (
        "Marker %s esgotou o cap de auto-requeue (%d/%d tentativas) e continua "
        "voltando pra gate-status:deferred. O watchdog PAROU — não é mais "
        "transiente, precisa de você.\n\n"
        "Branch: %s\n"
        "Source bead: %s (%s)\n"
        "Idade em gate-status:deferred: %dmin\n"
        "Author-derivability-check: %s\n\n"
        "Comando de re-submit pronto (rode DEPOIS de investigar por que ele re-defere):\n"
        "  %s\n\n"
        "(gate-recovery-watchdog FIX 7 — escalação de oscillating-deferred, ga-76kc)"
    ) % (mid, attempts, max_attempts, branch or "?", source_bead or "?", rig_name or "?",
         age_sec // 60, author_desc, resubmit_cmd)
    r = sh(["gc", "mail", "send", "mayor", "-s", subject, "-m", body], timeout=45)
    if not (r and r.returncode == 0):
        print("[watchdog] WARN: gc mail send mayor FAILED for oscillating deferred marker %s — notify still sent (grw)"
              % mid, flush=True)


def requeue_deferred_markers(now, rstate):
    """FIX 7 (ga-y1kk): recover a gate-status:deferred marker — the dead-end nothing
    else re-reads (quality-gate-dispatcher.sh Step 3's AUTHOR-derivation fail-safe, and
    quality-gate-guard.sh Step 5's own copy, both dead-end here). A blind requeue rarely
    helps (the marker got stuck precisely because AUTHOR couldn't be derived), so this
    only requeues once the marker's own gate.submitted_by metadata (set by a partial
    manual recovery) or the source bead's assignee/created_by/owner now resolves. If it
    never does across DEFERRED_REQUEUE_MAX_ATTEMPTS sweeps, the marker is closed with an
    explicit reason — but never on a single sweep's query blip. Bounded per sweep,
    dry-run aware, fully fail-safe."""
    if not GRW_ENABLED or not GRW_REQUEUE_DEFERRED_ENABLED:
        return
    markers = _open_deferred_markers()
    if markers is None:
        print("[watchdog] requeue: deferred-marker query unavailable — fail-safe skip", flush=True)
        return
    # oldest-deferred first (created_at asc) so the longest-stuck marker is served first
    markers.sort(key=lambda m: _iso_epoch(m.get("created_at")) or 0.0)
    acted = 0
    for mk in markers:
        if acted >= DEFERRED_REQUEUE_MAX_PER_SWEEP:
            break
        mid = mk.get("id")
        if not mid:
            continue
        upd = _iso_epoch(mk.get("updated_at")) or _iso_epoch(mk.get("created_at"))
        age = int(now - upd) if upd else 0
        labels = mk.get("labels") or []
        source_bead = _label_value(mk, "source-bead:")
        rig_name = _label_value(mk, "bead-rig:")
        branch = _label_value(mk, "branch:")
        label_count = 0
        for l in labels:
            m = GRW_DEFER_REQUEUE_LABEL_RE.match(l)
            if m:
                try:
                    label_count = int(m.group(1))
                except Exception:
                    label_count = 0
        attempts = max(label_count, rstate.deferred_requeues.get(mid, 0))
        marker_meta = mk.get("metadata") or {}
        resolved, sclosed, needs_human = _source_bead_state(source_bead, rig_name)
        has_author = bool(marker_meta.get("gate.submitted_by")) or (
            resolved and _source_bead_has_author_fields(source_bead, rig_name))
        # Pay for the git-ancestry check ONLY when the source is CLOSED — the sole case
        # where 'source closed' could be a FALSE 'done' (ga-gd706: the normal
        # dog-self-closes-its-sling-bead-on-submission doctrine closes the source
        # immediately after /gate-done, regardless of whether a reviewer ever ran).
        # Mirrors reap_orphan_and_stale_markers' FIX 4 gating exactly.
        branch_state = _branch_merged_state(branch, rig_name) if (resolved and sclosed) else "unknown"
        verdict = deferred_requeue_verdict(age, DEFERRED_REQUEUE_MINUTES * 60, resolved,
                                           sclosed, needs_human, has_author, attempts,
                                           DEFERRED_REQUEUE_MAX_ATTEMPTS, branch_state)

        if verdict == "skip:young":
            continue
        if verdict == "skip:parked-needs-human":
            if rstate.escalate_once("deferred-parked:%s" % mid, now):
                print("[watchdog] deferred marker %s parked (source %s needs-human) — left for human (grw)"
                      % (mid, source_bead), flush=True)
            continue

        if verdict == "close:source-done":
            if GRW_DRY_RUN:
                print("[watchdog] requeue DRY-RUN would CLOSE deferred marker %s (source bead %s closed — work done)"
                      % (mid, source_bead), flush=True)
                _recovery_ledger("would_close_done_deferred_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "dry_run": True})
                acted += 1
                continue
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid,
                "-r", "source bead %s closed and branch %s VERIFIED merged/absent (%s) — deferred marker superseded (grw deferred-marker self-heal, ga-gd706 hardening of ga-y1kk — merge confirmed via git ancestry, not assumed from a closed source)"
                % (source_bead, branch or "?", branch_state)], timeout=25)
            _recovery_ledger("closed_done_deferred_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "branch_state": branch_state})
            print("[watchdog] CLOSED done deferred marker %s (source %s closed)" % (mid, source_bead), flush=True)
            acted += 1
            continue

        if verdict == "skip:unresolvable":
            if not GRW_DRY_RUN:
                for l in labels:
                    if GRW_DEFER_REQUEUE_LABEL_RE.match(l):
                        sh(["bd", "-C", CITY, "label", "remove", mid, l, "-q"])
                sh(["bd", "-C", CITY, "label", "add", mid, "grw-defer-requeue:%d" % (attempts + 1), "-q"])
                rstate.deferred_requeues[mid] = attempts + 1
            print("[watchdog] deferred marker %s source %s still unresolvable (attempt %d/%d)%s"
                  % (mid, source_bead or "?", attempts + 1, DEFERRED_REQUEUE_MAX_ATTEMPTS,
                     " (DRY_RUN, not persisted)" if GRW_DRY_RUN else ""), flush=True)
            continue

        if verdict == "close:unresolvable":
            if GRW_DRY_RUN:
                print("[watchdog] requeue DRY-RUN would CLOSE unresolvable deferred marker %s (source %s — no derivable author after %d attempts)"
                      % (mid, source_bead or "?", attempts), flush=True)
                _recovery_ledger("would_close_unresolvable_deferred_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "dry_run": True})
                acted += 1
                continue
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid,
                "-r", "gate-recovery-watchdog: source bead %s unresolvable (no assignee/created_by/owner/gate.submitted_by) after %d attempts over %dm in gate-status:deferred — closing so it does not rot silently (ga-y1kk); re-submit /gate-done if branch %s still needs review"
                % (source_bead or "?", attempts, age // 60, branch or "?")], timeout=25)
            _recovery_ledger("closed_unresolvable_deferred_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "attempts": attempts})
            notify("Gate: marker %s (branch %s) ficou %dmin em deferred sem author derivável (source %s) — fechei após %d tentativas pra não apodrecer em silêncio. Re-submeta /gate-done se o branch ainda precisa de review. (grw, ga-y1kk)"
                   % (mid, branch or "?", age // 60, source_bead or "?", attempts), 4)
            print("[watchdog] CLOSED unresolvable deferred marker %s (source %s, %d attempts)" % (mid, source_bead, attempts), flush=True)
            acted += 1
            continue

        if verdict == "escalate:oscillating":
            if rstate.escalate_once("deferred-osc:%s" % mid, now):
                notify("🚨 Gate: marker %s (branch %s) volta pra deferred mesmo com author derivável em %s — já re-enfileirei %dx e continua falhando. Precisa de você. (grw)"
                       % (mid, branch or "?", source_bead or "?", attempts), 5)
                _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                            "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical",
                            "bead_id": source_bead or "", "reason": "deferred marker %s oscillating (%d watchdog requeues, still re-defers despite derivable author) — needs human" % (mid, attempts)}, fail_open=True)
                _mail_oscillating_deferred_marker(mid, branch, source_bead, rig_name, attempts,
                                                   DEFERRED_REQUEUE_MAX_ATTEMPTS, age)
                print("[watchdog] ESCALATED oscillating deferred marker %s (%d attempts, still re-defers) — NOT requeued again" % (mid, attempts), flush=True)
            continue

        # verdict == "requeue"
        if GRW_DRY_RUN:
            print("[watchdog] requeue DRY-RUN would re-queue deferred marker %s (branch %s, %dm deferred, attempt %d/%d) → gate-status:queued"
                  % (mid, branch or "?", age // 60, attempts + 1, DEFERRED_REQUEUE_MAX_ATTEMPTS), flush=True)
            _recovery_ledger("would_requeue_deferred", {"marker": mid, "branch": branch, "age_min": age // 60,
                             "attempt": attempts + 1, "dry_run": True})
            acted += 1
            continue
        for l in labels:
            if GRW_DEFER_REQUEUE_LABEL_RE.match(l):
                sh(["bd", "-C", CITY, "label", "remove", mid, l, "-q"])
        sh(["bd", "-C", CITY, "label", "add", mid, "grw-defer-requeue:%d" % (attempts + 1), "-q"])
        rstate.deferred_requeues[mid] = attempts + 1
        set_gate_status_py(mid, "queued")
        sh(["bd", "-C", CITY, "comment", mid,
            "gate-recovery-watchdog: auto-requeued gate-status:deferred→queued after %dm stuck deferred (source %s now has a derivable author; attempt %d/%d). The dispatcher's own AUTHOR fail-safe dead-ends at deferred with nothing re-reading it (ga-y1kk) — this sweep is that re-read. (grw deferred-marker self-heal)"
            % (age // 60, source_bead or "?", attempts + 1, DEFERRED_REQUEUE_MAX_ATTEMPTS)], timeout=25)
        _recovery_ledger("requeue_deferred", {"marker": mid, "branch": branch, "source_bead": source_bead,
                         "age_min": age // 60, "attempt": attempts + 1})
        notify("Gate self-heal: marker %s re-enfileirado (deferred→queued, branch %s, %dmin travado, tentativa %d/%d). Você não precisa agir."
               % (mid, branch or "?", age // 60, attempts + 1, DEFERRED_REQUEUE_MAX_ATTEMPTS), 3)
        print("[watchdog] REQUEUED deferred marker %s (branch %s, %dm, attempt %d/%d)"
              % (mid, branch or "?", age // 60, attempts + 1, DEFERRED_REQUEUE_MAX_ATTEMPTS), flush=True)
        acted += 1
    if acted:
        print("[watchdog] deferred-requeue sweep: %d marker(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def _open_quality_gate_marker_sources():
    """set() of every source-bead: value referenced by an OPEN type:quality-gate-marker,
    ANY gate-status (queued/ready/claimed/dispatching/running/error/deferred all count —
    FIX 8 only needs to know SOMETHING still tracks the bead, not which phase). None on
    query failure (fail-safe: caller aborts the whole sweep rather than risk treating a
    bead as unreferenced because we simply failed to see its marker)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",  # ga-h199q
            "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        rows = json.loads(r.stdout) or []
    except Exception:
        return None
    out = set()
    for row in rows:
        src = _label_value(row, "source-bead:")
        if src:
            out.add(src)
    return out


def _beads_with_gate_label(label):
    """[(bead_id, store), ...] for every open/in_progress bead across HQ + every known
    rig carrying `label` (gate:queued or gate:reviewing) — a marker's source bead can
    live in any rig, not just HQ (mirrors FIX 4's _source_review_state rig resolution).
    None on ANY store query failure (fail-safe: FIX 8 aborts the whole sweep rather than
    scan a partial rig population and risk false-clearing based on incomplete data)."""
    stores = [CITY] + [p for p in _rig_paths().values() if p and p != CITY]
    out = []
    for store in stores:
        r = sh(["bash", BD_LIST_CACHED, "-C", store, "list", "-l", label,  # ga-h199q
                "--status", "open,in_progress", "--json"], timeout=25)
        if not r or r.returncode != 0:
            return None
        try:
            rows = json.loads(r.stdout) or []
        except Exception:
            return None
        for row in rows:
            if label in (row.get("labels") or []):
                out.append((row.get("id"), store))
    return out


def orphan_gate_label_verdict(confirm_hits, confirm_threshold):
    """PURE decision (no I/O, unit-tested) for FIX 8: has a (bead, gate:queued-or-
    -reviewing label) pair now been seen unreferenced by any open marker across enough
    CONSECUTIVE sweeps to act?
      'clear' — confirm_hits >= confirm_threshold: safe to strip the phantom label.
      'wait'  — not yet confirmed; could still be a marker-visibility race."""
    return "clear" if confirm_hits >= confirm_threshold else "wait"


def _update_orphan_gate_label_hits(hits_state, candidate_keys):
    """PURE (no I/O, unit-tested): the CONSECUTIVE-sweep counting rule in one place.
    hits_state is the current {(bead_id, label): consecutive_count}; candidate_keys is
    the SET of (bead_id, label) pairs detected as orphan-candidates THIS sweep (label
    present, no open marker references it). Returns the NEXT hits_state: every
    candidate's count +1, and — critically — every key NOT in candidate_keys this sweep
    is DROPPED, not merely frozen. A pair that was a candidate for 2 sweeps and then
    isn't (a marker appeared, or the label was cleared some other way) starts over from
    0 if it ever reappears, rather than resuming from 2. That drop-not-freeze rule is
    what makes ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD a CONSECUTIVE-sweep guard against the
    marker-visibility race (a marker gate-done.md just created may not be queryable yet)
    rather than a cumulative "seen enough times ever" counter, which a single missed
    sweep would already have satisfied via unrelated intermittent hits."""
    return {key: hits_state.get(key, 0) + 1 for key in candidate_keys}


def reap_orphan_gate_labels(now, rstate):
    """FIX 8 (ga-yzw06): clear a SOURCE bead's gate:queued/gate:reviewing label when NO
    open quality-gate-marker references it at all — see the FIX 8 constants-block
    docstring above for the full incident/rationale. This function owns HOW (candidate
    gather, hysteresis bookkeeping, apply); the constants block owns WHY.

    Scope is deliberately label-only: never touches story:*/status/assignee. Verified
    against the live board's own source (whatsapp_automation/daemons/painel_visibilidade.py,
    function _load_kanban and its helpers _qualifies_for_triagem/_is_auto_dispatch_card/
    _is_automation_bead) — grepped for "gate:queued": ZERO hits. Column placement keys
    on story:*/status/assignee/live-session only; gate:* labels are never read for it, and
    the dedicated Gate column is populated from live MARKERS (_place_gate_cards), not from
    the source's label either. gate-done.md only ADDS gate:queued on marker creation; it
    never removes story:*. So story:*/status/assignee are already intact on every orphan
    this function will ever see, and clearing the phantom gate:* label cannot drop a bead
    off the board — there is nothing to "restore". A stale ASSIGNEE (dead builder session)
    is a separate, already-solved problem: packs/town-deltas/assets/scripts/orphan-sweep.sh
    resets in-progress beads assigned to dead agents on its own 5min-cooldown sweep,
    independent of gate:* labels — this function does not duplicate that.

    Hysteresis via rstate.orphan_gate_label_hits (see orphan_gate_label_verdict): a
    (bead_id, label) pair must be re-detected as a candidate on ORPHAN_GATE_LABEL_
    CONFIRM_THRESHOLD consecutive sweeps before it is cleared. Any pair NOT re-detected
    this sweep (label gone, or a marker now references it) is pruned from the ledger —
    that pruning is what makes the count consecutive rather than "seen N times ever"
    (same shape as packs/town-deltas orphan-sweep.sh's CONFIRM_THRESHOLD ledger).

    Bounded, dry-run-aware, fully fail-safe: any store query failure this sweep (HQ or
    any rig, for either the marker-source set or a labeled-bead scan) aborts the WHOLE
    sweep — never act on a partial population."""
    if not GRW_ENABLED or not GRW_REAP_ORPHAN_GATE_LABEL_ENABLED:
        return
    referenced = _open_quality_gate_marker_sources()
    if referenced is None:
        return  # query failure → fail-safe skip (no blind action)
    candidates = {}  # (bead_id, label) -> store, for every unreferenced sighting this sweep
    for label in ("gate:queued", "gate:reviewing"):
        beads = _beads_with_gate_label(label)
        if beads is None:
            return  # a store failed to answer → abort the WHOLE sweep, never act on a partial scan
        for bid, store in beads:
            if not bid or bid in referenced:
                continue
            candidates[(bid, label)] = store
    rstate.orphan_gate_label_hits = _update_orphan_gate_label_hits(rstate.orphan_gate_label_hits, set(candidates))
    to_clear = [(bid, candidates[(bid, label)], label, hits)
                for (bid, label), hits in rstate.orphan_gate_label_hits.items()
                if orphan_gate_label_verdict(hits, ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD) == "clear"]
    acted = 0
    for bid, store, label, hits in to_clear:
        if acted >= ORPHAN_GATE_LABEL_MAX_PER_SWEEP:
            break
        if GRW_DRY_RUN:
            print("[watchdog] FIX8 DRY would clear orphan %s on %s (confirmed %d/%d sweeps, no open marker)"
                  % (label, bid, hits, ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD), flush=True)
            _recovery_ledger("would_clear_orphan_gate_label",
                             {"bead": bid, "label": label, "store": store, "hits": hits, "dry_run": True})
            acted += 1
            continue
        sh(["bd", "-C", store, "label", "remove", bid, label, "-q"], timeout=20)
        sh(["bd", "-C", store, "comment", bid,
            "grw FIX8: cleared PHANTOM %s (no open quality-gate-marker referenced this bead across %d consecutive sweeps — Pilot's ingate filter was skipping it and the gate dispatcher had nothing to drain; the ga-yzw06 class). Bead is a dispatch candidate again. If it is still assigned to a dead session, orphan-sweep.sh resets that separately on its own sweep."
            % (label, hits)], timeout=20)
        _recovery_ledger("clear_orphan_gate_label", {"bead": bid, "label": label, "store": store, "confirm_hits": hits})
        notify("Gate self-heal: label fantasma %s limpo em %s (sem marker há %d sweeps seguidos — ga-yzw06). Virou candidato de novo pro Pilot." % (label, bid, hits), 3)
        print("[watchdog] FIX8 CLEARED orphan %s on %s (no marker across %d consecutive sweeps) — Pilot/gate candidacy restored"
              % (label, bid, hits), flush=True)
        del rstate.orphan_gate_label_hits[(bid, label)]
        acted += 1
    if acted:
        print("[watchdog] FIX8 orphan gate-label sweep: %d bead(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def _open_needs_rebase_markers():
    """[marker dicts] type:quality-gate-marker + gate-status:needs-rebase + open, in
    HQ (the dispatcher's domain — mirrors _open_error_markers/_open_deferred_markers).
    None on query failure (fail-safe skip)."""
    r = sh(["bash", BD_LIST_CACHED, "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",  # ga-h199q
            "-l", "gate-status:needs-rebase", "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout) or []
    except Exception:
        return None


def needs_rebase_verdict(age_sec, threshold_sec, source_resolved, source_closed,
                          source_needs_human, branch_state):
    """PURE decision (no I/O, unit-tested) for a gate-status:needs-rebase marker
    (FIX 9, ga-7b19e). See the FIX 9 constants-block docstring for the full
    rationale; in short, this never re-queues the marker — unlike FIX 2's
    transient gate-status:error, needs-rebase means the gate already confirmed a
    deterministic conflict, so blindly flipping it back to queued would reproduce
    that conflict identically.
      skip:young          — parked <= threshold. Checked FIRST, before branch_state
                            is ever consulted (GATE-FEEDBACK attempt 2 FAIL: a
                            marker created moments ago can't yet be trusted to act
                            on — mirrors FIX 4's identical young-marker guard,
                            which also runs before anything else).
      close:branch-landed — branch_state == 'merged' (positive proof of ancestry —
                            closes ALONE, no corroboration needed) OR branch_state
                            == 'missing' AND source_closed (absence of evidence
                            needs corroboration: GATE-FEEDBACK attempt 2 FAIL —
                            'missing' alone was closing markers on a single
                            sweep's git result, the same single-signal shape this
                            bug's own history already rejected once for
                            source_closed; requiring source_closed alongside
                            'missing' mirrors FIX 4's orphan_marker_verdict
                            exactly). `source_closed` ALONE — with branch_state
                            'unmerged' or 'unknown' — is still NEVER enough to
                            close: a source bead being closed does not prove the
                            work landed (ga-w5agg/ga-d2jil). A closed source with
                            a real unmerged branch is a STRANDED fix, not a
                            leftover — it falls through to 'escalate' below,
                            exactly like an open source would.
      skip:parked-needs-human — source already carries gate:needs-human; a
                            different mechanism (gate-needs-human-divergence-
                            sweep) owns escalation for that bead.
      escalate             — genuinely stuck: branch neither landed nor
                            corroborated-gone (unmerged = real branch pending a
                            human rebase/rebuild decision; unknown = can't
                            verify; missing-without-source_closed = uncorroborated)
                            — fail-safe toward visibility, past the age threshold
                            → mail+notify with age. Fires regardless of source
                            status (open, closed, or unresolvable) whenever the
                            branch signal alone isn't conclusive enough to close.
                            ga-7b19e's acceptance OR-clause (dispatchable-again OR
                            an alert) is satisfied via this branch — dispatch is
                            deliberately NOT force-resumed, since that would just
                            re-hit the identical conflict.
    branch_state ∈ {'merged','unmerged','missing','unknown'} (_branch_merged_state).
    An unresolvable source (source_resolved=False) still reaches 'escalate' once
    old enough — fail TOWARD visibility, never toward silence (the bug this fix
    exists to close)."""
    if age_sec <= threshold_sec:
        return "skip:young"
    if branch_state == "merged":
        return "close:branch-landed"
    if branch_state == "missing" and source_closed:
        return "close:branch-landed"
    if source_resolved and source_needs_human:
        return "skip:parked-needs-human"
    return "escalate"


def _mail_stuck_needs_rebase_marker(mid, branch, source_bead, rig_name, age_sec, resolved):
    """ga-7b19e: durable, actionable escalation for a gate-status:needs-rebase
    marker that has been silently parked past the age threshold. Unlike FIX 2's
    oscillating-error mail, there is no safe one-line resubmit command here —
    needs-rebase means the gate already confirmed a deterministic conflict, so
    the fix requires a human DECISION (re-anchor vs fresh rebuild vs abandon),
    the same doctrine as the dead-author re-anchor case. This mail exists so
    that decision point is never silent again (measured: 9 markers piled up in
    the gastown rig, the oldest 10 days, before a human happened to look)."""
    subject = "Gate: marker %s preso em needs-rebase (%dmin, ninguém foi avisado)" % (mid, age_sec // 60)
    body = (
        "Marker %s está parkeado em gate-status:needs-rebase há %dmin e ninguém "
        "tinha sido avisado até agora — o watchdog detectou e está avisando "
        "(grw FIX9, ga-7b19e).\n\n"
        "Branch: %s\n"
        "Source bead: %s (%s)\n"
        "Source resolvido: %s\n\n"
        "O gate já confirmou um conflito determinístico (autor morto, ou tentativas "
        "de rebase esgotadas) — um requeue automático reproduziria o MESMO conflito, "
        "então o watchdog NÃO tenta. Precisa de uma decisão sua: re-anchor (se ainda "
        "fizer sentido) ou rebuild (RESET pro origin/main atual e reaplicar o fix). "
        "Se o branch já não presta, apague-o (arquive antes com uma tag) e o marker "
        "será fechado automaticamente num sweep futuro (source-done ou branch-landed) "
        "— o watchdog nunca apaga/força-push um branch sozinho.\n\n"
        "(gate-recovery-watchdog FIX 9 — needs-rebase silent-park escalation, ga-7b19e)"
    ) % (mid, age_sec // 60, branch or "?", source_bead or "?", rig_name or "?",
         "sim" if resolved else "não (query falhou ou bead sumiu)")
    r = sh(["gc", "mail", "send", "mayor", "-s", subject, "-m", body], timeout=45)
    if not (r and r.returncode == 0):
        print("[watchdog] WARN: gc mail send mayor FAILED for stuck needs-rebase marker %s — notify still sent (grw)"
              % mid, flush=True)


def recover_needs_rebase_markers(now, rstate):
    """FIX 9 (ga-7b19e): close a gate-status:needs-rebase marker when proven moot
    (source closed, or branch landed/gone), else escalate once per cooldown with
    age — NEVER requeue (see needs_rebase_verdict / constants-block docstring for
    why a blind requeue is unsafe here, unlike FIX 2/FIX 7). Bounded per sweep,
    dry-run aware, fully fail-safe."""
    if not GRW_ENABLED or not GRW_RECOVER_NEEDS_REBASE_ENABLED:
        return
    markers = _open_needs_rebase_markers()
    if markers is None:
        print("[watchdog] needs-rebase: marker query unavailable — fail-safe skip", flush=True)
        return
    # oldest-parked first so the longest-silent marker is served first
    markers.sort(key=lambda m: _iso_epoch(m.get("created_at")) or 0.0)
    acted = 0
    for mk in markers:
        if acted >= NEEDS_REBASE_MAX_PER_SWEEP:
            break
        mid = mk.get("id")
        if not mid:
            continue
        upd = _iso_epoch(mk.get("updated_at")) or _iso_epoch(mk.get("created_at"))
        age = int(now - upd) if upd else 0
        source_bead = _label_value(mk, "source-bead:")
        rig_name = _label_value(mk, "bead-rig:")
        branch = _label_value(mk, "branch:")
        resolved, sclosed, needs_human = _source_bead_state(source_bead, rig_name)
        branch_state = _branch_merged_state(branch, rig_name)
        verdict = needs_rebase_verdict(age, NEEDS_REBASE_AGE_MINUTES * 60, resolved,
                                        sclosed, needs_human, branch_state)

        if verdict == "skip:young":
            continue
        if verdict == "skip:parked-needs-human":
            continue

        if verdict == "close:branch-landed":
            reason = ("branch %s state=%s (already landed or gone) — needs-rebase marker is moot"
                       % (branch or "?", branch_state))
            if GRW_DRY_RUN:
                print("[watchdog] needs-rebase DRY-RUN would CLOSE marker %s (%s)" % (mid, reason), flush=True)
                _recovery_ledger("would_close_needs_rebase",
                                 {"marker": mid, "source_bead": source_bead, "branch": branch,
                                  "verdict": verdict, "dry_run": True})
                acted += 1
                continue
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid, "-r",
                "grw FIX9: %s (ga-7b19e). Closed by watchdog self-heal." % reason], timeout=25)
            # Best-effort: also strip a mirrored gate:needs-rebase label off the SOURCE
            # bead, if it's still open — closing the marker alone leaves _filter_built's
            # OTHER independent exclusion path (the bead's own gate:* label) in place.
            # Label-only, same FIX 8 scope discipline (never touches story:*/status/assignee).
            if source_bead and resolved and not sclosed:
                store = ((_rig_paths().get(rig_name) if rig_name else None)
                         or _rig_path_by_prefix(_bead_id_prefix(source_bead)) or CITY)
                sh(["bd", "-C", store, "label", "remove", source_bead, "gate:needs-rebase", "-q"], timeout=20)
            _recovery_ledger("closed_needs_rebase_marker",
                             {"marker": mid, "source_bead": source_bead, "branch": branch, "verdict": verdict})
            notify("Gate self-heal: marker %s (needs-rebase) fechado — %s. (grw FIX9)" % (mid, reason), 3)
            print("[watchdog] CLOSED needs-rebase marker %s (%s)" % (mid, verdict), flush=True)
            acted += 1
            continue

        # verdict == "escalate"
        if rstate.escalate_once("needs-rebase:%s" % mid, now, window=NEEDS_REBASE_ALERT_COOLDOWN_SEC):
            notify("🚨 Gate: marker %s (branch %s) preso em needs-rebase há %dmin, ninguém tinha sido avisado. Precisa de uma decisão (re-anchor/rebuild). (grw FIX9)"
                   % (mid, branch or "?", age // 60), 4)
            _grw_ledger("human-touch",
                        {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical",
                         "bead_id": source_bead or "",
                         "reason": "needs-rebase marker %s silently parked %dmin — needs a Mayor decision (ga-7b19e)"
                                   % (mid, age // 60)}, fail_open=True)
            _mail_stuck_needs_rebase_marker(mid, branch, source_bead, rig_name, age, resolved)
            _recovery_ledger("escalated_needs_rebase",
                             {"marker": mid, "source_bead": source_bead, "branch": branch, "age_min": age // 60})
            print("[watchdog] ESCALATED stuck needs-rebase marker %s (%dm, branch %s)"
                  % (mid, age // 60, branch or "?"), flush=True)
    if acted:
        print("[watchdog] needs-rebase sweep: %d marker(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def main():
  # ---- state ----
  gov = Governor()       # dedup + concurrent cap + per-condition cooldown/back-off
  rstate = RecoveryState()  # direct self-heal: per-marker requeue count + escalate-once
  saw_gate = False       # we dispatched at least one gate-down repair since last recovery
  saw_pilot = False
  saw_loop = False
  saw_sup = False
  saw_orphan = False
  last_gate_spawn = 0
  last_pilot_spawn = 0
  last_loop_spawn = 0
  last_orphan_spawn = 0

  print("[watchdog] gate+pilot watchdog started — governed repair-agent spawner "
        "(dedup + cap=%d + per-condition back-off + self-limit=%d; enabled=%s dry_run=%s) "
        "on gate-down OR pilot-jam OR head-of-line block OR supervisor init-failure OR orphaned queued marker"
        % (MAX_ACTIVE_REPAIR_DOGS, MAX_SPAWNS_PER_CONDITION, GRW_ENABLED, GRW_DRY_RUN), flush=True)
  print("[watchdog] + DIRECT self-heal each sweep: reap HUNG reviewers (run>%dm, 0 verdicts, dead reviewer sustained; enabled=%s) "
        "AND recover STRANDED-VERDICT runs (verdicts complete>%dm ago, all delivered but stuck running/unfinalized, cap %d attempts; enabled=%s) "
        "AND kill FROZEN reviewers (active-but-last_active-silent>%ds, cap %d/sweep, sustained-confirmed; enabled=%s), THEN supersede+requeue its run if that reviewer was the sole pending one (ga-pp5vh; enabled=%s) "
        "AND reap ORPHAN/STALE markers (queued>%dm w/ source closed→close, or leaked gate:reviewing→clear, cap %d/sweep; enabled=%s) "
        "AND requeue STRANDED dispatching|reviewing markers w/ NO open run (dead reviewer, >%dm, cap %d/sweep, esc after %d; enabled=%s) "
        "AND auto-requeue STUCK gate-status:error markers (>%dm in error, cap %d/sweep, osc-escalate after %d; enabled=%s) "
        "AND recover/close STUCK gate-status:deferred markers (>%dm deferred w/ derivable author→requeue, else close after %d attempts, ga-y1kk; cap %d/sweep, enabled=%s) "
        "AND clear PHANTOM gate:queued/gate:reviewing source labels w/ NO open marker at all (confirmed %dx consecutive sweeps, cap %d/sweep, ga-yzw06; enabled=%s) "
        "AND close/escalate permanently-parked gate-status:needs-rebase markers (>%dm parked, close only if branch landed/gone else escalate w/ age every %dm cooldown, cap %d/sweep, NEVER requeue, ga-7b19e; enabled=%s). "
        "All bounded + fail-safe + dry_run=%s."
        % (REVIEW_HANG_MINUTES, GRW_REAP_HUNG_ENABLED, STRANDED_RUN_MINUTES, STRANDED_MAX_ATTEMPTS, GRW_REAP_STRANDED_ENABLED,
           FROZEN_KILL_SECS, FROZEN_KILL_MAX_PER_SWEEP, GRW_REAP_FROZEN_ENABLED, GRW_FROZEN_REQUEUE_ENABLED,
           ORPHAN_MARKER_MIN_MINUTES, ORPHAN_MAX_PER_SWEEP, GRW_REAP_ORPHAN_ENABLED,
           STALE_REVIEW_MARKER_MINUTES, STALE_REVIEW_MAX_PER_SWEEP, STALE_REVIEW_MAX_ATTEMPTS, GRW_REAP_STALE_REVIEW_ENABLED,
           ERROR_REQUEUE_MINUTES, ERROR_REQUEUE_MAX_PER_SWEEP, ERROR_REQUEUE_MAX_ATTEMPTS, GRW_REQUEUE_ERROR_ENABLED,
           DEFERRED_REQUEUE_MINUTES, DEFERRED_REQUEUE_MAX_ATTEMPTS, DEFERRED_REQUEUE_MAX_PER_SWEEP, GRW_REQUEUE_DEFERRED_ENABLED,
           ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD, ORPHAN_GATE_LABEL_MAX_PER_SWEEP, GRW_REAP_ORPHAN_GATE_LABEL_ENABLED,
           NEEDS_REBASE_AGE_MINUTES, NEEDS_REBASE_ALERT_COOLDOWN_SEC // 60, NEEDS_REBASE_MAX_PER_SWEEP, GRW_RECOVER_NEEDS_REBASE_ENABLED,
           GRW_DRY_RUN), flush=True)

  while True:
    try:
        now = time.time()
        # One session-list query per loop, shared by every detector's governor check
        # (replaces the per-block coarse cooldown; bounds this daemon's own gc load).
        sessions = _session_list_json()
        # One gate-run query per loop, shared by FIX 1/5/6's first-look sample (ga-7e7a:
        # each independently issued an identical `bd list --json` every cycle — same
        # data, 3 fresh connections). FIX 6's SUSTAINED-confirm resample (after
        # LIVENESS_RESAMPLE_SEC, inside reap_stale_review_markers) intentionally keeps
        # its OWN fresh _open_running_runs() call — its whole purpose is detecting a run
        # that appeared since this snapshot, so it must not reuse it.
        open_running_runs = _open_running_runs()
        lp = last_pass_epoch()

        # ===== DIRECT SELF-HEAL (no dog, no Mayor) — runs EVERY sweep, independent
        # of the infra-throttle gate below (these are cheap bounded bd mutations that
        # DIRECTLY heal the two toils the Mayor fixed by hand; a reap FREES load, and
        # if Dolt is wedged the queries fail → fail-safe skip). Each is fully guarded.
        try:
            reap_hung_runs(sessions, now, rstate, open_running_runs)
        except Exception as e:
            print("[watchdog] reap_hung_runs error (continuing): %r" % e, flush=True)
        try:
            reap_stranded_verdict_runs(now, open_running_runs)
        except Exception as e:
            print("[watchdog] reap_stranded_verdict_runs error (continuing): %r" % e, flush=True)
        try:
            reap_frozen_reviewers(sessions, now, rstate, open_running_runs)
        except Exception as e:
            print("[watchdog] reap_frozen_reviewers error (continuing): %r" % e, flush=True)
        try:
            reap_orphan_and_stale_markers(now)
        except Exception as e:
            print("[watchdog] reap_orphan_and_stale_markers error (continuing): %r" % e, flush=True)
        try:
            reap_orphan_gate_labels(now, rstate)
        except Exception as e:
            print("[watchdog] reap_orphan_gate_labels error (continuing): %r" % e, flush=True)
        try:
            reap_stale_review_markers(now, rstate, open_running_runs)
        except Exception as e:
            print("[watchdog] reap_stale_review_markers error (continuing): %r" % e, flush=True)
        try:
            requeue_error_markers(now, rstate)
        except Exception as e:
            print("[watchdog] requeue_error_markers error (continuing): %r" % e, flush=True)
        try:
            requeue_deferred_markers(now, rstate)
        except Exception as e:
            print("[watchdog] requeue_deferred_markers error (continuing): %r" % e, flush=True)
        try:
            recover_needs_rebase_markers(now, rstate)
        except Exception as e:
            print("[watchdog] recover_needs_rebase_markers error (continuing): %r" % e, flush=True)

        # ga-htjni follow-up (dog investigation 2026-06-15): if the gate is
        # ALIVE-but-infra-throttled (Dolt-hot or quota DEFER), a repair dog cannot
        # fix CPU/quota — suppress the three GATE-repair detectors (gate:down /
        # head-of-line / orphan) this cycle so we stop spawning futile taskless
        # dogs. Pilot + supervisor detectors are unaffected (different conditions).
        # A truly wedged dispatcher has a stale log → infra=False → detectors fire.
        infra = gate_infra_throttled()
        if infra:
            print("[watchdog] gate infra-throttled (Dolt-hot/quota DEFER) — alive but throttled; "
                  "skipping gate-repair detectors this cycle (a dog can't fix infra).", flush=True)

        # ===== gate down: 2+ timeouts OR a marker stuck dispatching w/ no reviewers =====
        n_to, last_to = recent_timeouts()
        stuck = stuck_dispatching()
        problem = ((n_to >= 2) or stuck) and not infra
        if saw_gate and lp and lp > last_gate_spawn:
            print("[watchdog] gate recovered (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Gate recuperou (agente de reparo/Mayor) — voltou a passar revisões. Tudo certo.", 3)
            gov.reset_prefix("gate:"); saw_gate = False
        if problem:
            reason = ("%d timeouts em %dmin" % (n_to, TIMEOUT_WINDOW_SEC // 60)) if n_to >= 2 \
                     else "marcador dispatching travado sem revisores ativos"
            dolt_hits = dolt_instability()
            diag = snapshot(reason, dolt_hits)
            how = governed_spawn(gov, sessions, now, "gate", reason, diag, dolt_hits, "Gate travou")
            if how is not None:
                last_gate_spawn = now; saw_gate = True

        # --- PILOT coverage (closes the gap that hid the 2026-06-08 ~8h jam) ---
        pj, pj_reason = pilot_jammed()
        if saw_pilot and not pj:
            print("[watchdog] pilot recovered — resetting", flush=True)
            notify("Pilot voltou a despachar — resolvido.", 3)
            gov.reset_prefix("pilot:"); saw_pilot = False
        if pj:
            pdiag = snapshot(pj_reason, 0)
            phow = governed_spawn(gov, sessions, now, "pilot", pj_reason, pdiag, 0, "Pilot travou")
            if phow is not None:
                last_pilot_spawn = now; saw_pilot = True

        # --- HEAD-OF-LINE block (closes the ga-hl0gq blind spot: 49min undetected) ---
        hb, hcount = headofline_stall()
        if saw_loop and lp and lp > last_loop_spawn:
            print("[watchdog] head-of-line cleared (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Gate destravou — fila voltou a drenar (head-of-line resolvido).", 3)
            gov.reset_prefix("gate-loop:"); saw_loop = False
        if hb and not infra:
            ldiag = snapshot("head-of-line block: %dx QUEUED-retry no branch %s" % (hcount, hb), 0)
            lhow = governed_spawn(gov, sessions, now, "gate-loop", hb, ldiag, 0,
                                  "Gate preso em branch stale (head-of-line)", branch=hb)
            if lhow is not None:
                last_loop_spawn = now; saw_loop = True

        # --- SUPERVISOR init-failure loop (closes the ga-h3w2y blind spot:
        #     a rig with no path in site.toml → spawn-outage town-wide, ~1h to
        #     find by hand). First-class durable signal; the proactive guard is
        #     supervisor-config-guard, this is the always-on backstop. ---
        sup_reason, sup_detail = supervisor_init_failure()
        if saw_sup and not sup_reason:
            print("[watchdog] supervisor recovered (config valid, no init-failure loop) — resetting", flush=True)
            notify("Supervisor voltou — config válido e spawn normalizado.", 3)
            gov.reset_prefix("supervisor:"); saw_sup = False
        if sup_reason:
            sdiag = snapshot("%s | config inválido: %s" % (sup_reason, sup_detail), 0)
            # 3rd positional carries the config-invalid detail for the kind=supervisor task
            show = governed_spawn(gov, sessions, now, "supervisor", sup_reason, sdiag, sup_detail,
                                  "Supervisor em init-failure (spawn-outage)")
            if show is not None:
                saw_sup = True

        # --- ORPHANED queued marker (closes the gt-mqkwj blind spot: a marker
        #     whose gate_run was dropped in an outage is leapfrogged forever →
        #     bead stuck in_progress → reconciler re-spawns a worker ~6x). The
        #     leapfrog proof + FIFO-head guard keep a normal backlog / head-of-line
        #     block from false-firing (the 6x-same-marker driver). ---
        orphan_id, orphan_branch, orphan_age = orphaned_queued_marker()
        if saw_orphan and lp and lp > last_orphan_spawn:
            print("[watchdog] orphaned marker cleared (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Marker órfão resolvido — gate voltou a passar (gt-mqkwj).", 3)
            gov.reset_prefix("gate-orphan:"); saw_orphan = False
        if orphan_id and not infra:
            odiag = snapshot("orphaned queued marker %s (branch %s, %dmin sem despacho)"
                             % (orphan_id, orphan_branch, orphan_age // 60), 0)
            # reason=branch (title), marker id carried for the runbook + dedup key
            ohow = governed_spawn(gov, sessions, now, "gate-orphan", orphan_branch, odiag, orphan_id,
                                  "Marker órfão (run derrubado num outage)",
                                  marker_id=orphan_id, branch=orphan_branch)
            if ohow is not None:
                last_orphan_spawn = now; saw_orphan = True
    except Exception as e:
        print("[watchdog] loop error (continuing): %r" % e, flush=True)
    time.sleep(POLL_SEC)


def _selftest():
    """Pure-logic regression checks for FIX 2/3/4/5/6/7 (no I/O). Run: --selftest."""
    p = f = 0
    def ok(c, m):
        nonlocal p, f
        if c: p += 1; print("  ✓", m)
        else: f += 1; print("  ✗", m)
    # frozen_reviewer_verdict — the kill/keep core
    ok(frozen_reviewer_verdict("active", 900, 900) == "kill", "active + silent==threshold → kill")
    ok(frozen_reviewer_verdict("active", 2040, 900) == "kill", "active + silent 34m (the live incident) → kill")
    ok(frozen_reviewer_verdict("active", 300, 900) == "keep", "active + silent 5m (< threshold) → keep")
    ok(frozen_reviewer_verdict("asleep", 5000, 900) == "keep", "non-active state → keep (hung-run reaper/dispatcher own it)")
    ok(frozen_reviewer_verdict("active", None, 900) == "keep", "unparseable silence → keep (fail-safe)")
    ok(frozen_reviewer_verdict("active", -10, 900) == "keep", "future last_active (negative silence) → keep (fail-safe)")
    ok(frozen_reviewer_verdict("", 5000, 900) == "keep", "empty state → keep")
    # _last_active_epoch — must parse the tz-OFFSET form (session JSON), not just UTC-Z
    ok(_last_active_epoch("2026-07-02T16:06:29-03:00") is not None, "tz-offset last_active parses (the session-JSON form)")
    ok(_last_active_epoch("2026-07-02T19:06:29Z") is not None, "UTC-Z last_active parses too")
    ok(_last_active_epoch("") is None and _last_active_epoch("garbage") is None, "empty/garbage → None (never frozen)")
    # the two forms above name the SAME instant → equal epochs (offset math correct)
    a = _last_active_epoch("2026-07-02T16:06:29-03:00"); b = _last_active_epoch("2026-07-02T19:06:29Z")
    ok(a is not None and b is not None and abs(a - b) < 1, "-03:00 and its UTC-Z equivalent map to the same epoch")
    # FIX 4 — orphan_marker_verdict (queued-marker cleanup; now branch-merge-aware)
    M = 15 * 60
    ok(orphan_marker_verdict(9 * 60, M, True, True, True, "merged") == "wait", "young marker (9m<15m) → wait (spin-up race window)")
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "merged") == "close-source-done", "old + source CLOSED + branch MERGED → close orphan")
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "missing") == "close-source-done", "old + source CLOSED + branch MISSING (abandoned) → close orphan")
    ok(orphan_marker_verdict(600 * 60, M, True, True, True, "merged") == "close-source-done", "closed+merged WINS over reviewing (done regardless)")
    # the ga-w5agg/ga-d2jil bug: source closed by janitor but branch NOT merged → NEVER false-close
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "unmerged") == "recover-stranded", "old + source CLOSED but branch UNMERGED → recover, NEVER false-close (the ga-w5agg/ga-d2jil bug)")
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "unknown") == "keep", "source closed but branch state UNKNOWN → keep (fail-safe, never blind-close as merged)")
    ok(orphan_marker_verdict(572 * 60, M, True, False, True) == "clear-stale-reviewing", "old + source OPEN + gate:reviewing → clear stale (the wa-ya17c case)")
    ok(orphan_marker_verdict(572 * 60, M, True, False, False) == "keep", "old + source open + no reviewing → keep (nothing stale)")
    ok(orphan_marker_verdict(600 * 60, M, False, False, False) == "keep", "source UNREADABLE → keep (fail-safe, never blind-close)")
    # _branch_merged_state (shared by FIX 4 + FIX 9) — ga-7b19e attempt 3 root-cause fix.
    # GATE-FEEDBACK (attempt 2 FAIL): sh() returning None (subprocess exception/timeout)
    # on the rev-parse call fell into the SAME branch as a confirmed-absent ref, so a
    # transient git failure under this city's documented load (Dolt-hot, 100+ concurrent
    # worktrees) was silently reported as "missing" instead of "unknown" — letting FIX 4
    # or FIX 9 auto-close a marker (and strip a source bead's label) for a branch that
    # was actually still real and unmerged. These monkeypatch sh() itself since
    # _branch_merged_state's whole job is interpreting subprocess results.
    _CP = subprocess.CompletedProcess
    _bms_calls = []
    def _fake_sh_bms(fetch_is_none=False, fetch_rc=0, rev_is_none=False, rev_rc=0,
                      rev_stdout="abc123\n", merge_rc=0):
        def _f(args, timeout=20, stdin=None):
            _bms_calls.append(list(args))
            if "fetch" in args:
                return None if fetch_is_none else _CP(args=args, returncode=fetch_rc, stdout="")
            if "rev-parse" in args:
                return None if rev_is_none else _CP(args=args, returncode=rev_rc, stdout=rev_stdout)
            if "merge-base" in args:
                return _CP(args=args, returncode=merge_rc, stdout="")
            return None
        return _f
    _real_sh = globals()["sh"]
    try:
        globals()["sh"] = _fake_sh_bms(rev_is_none=True)
        ok(_branch_merged_state("br") == "unknown",
           "GATE-FEEDBACK regression (ga-7b19e attempt 2 FAIL): sh() returns None on rev-parse (timeout/exception) → unknown, NOT missing — mirrors the anc-is-None handling a few lines below in the same function")

        _bms_calls.clear()
        globals()["sh"] = _fake_sh_bms(fetch_is_none=True)
        ok(_branch_merged_state("br") == "unknown",
           "sh() returns None on fetch (timeout/exception) → unknown; a wedged fetch must never let a stale local view masquerade as ground truth")
        ok(not any("rev-parse" in c for c in _bms_calls),
           "a failed fetch short-circuits BEFORE rev-parse runs — never trust local refs when fetch itself couldn't confirm them fresh")

        _bms_calls.clear()
        globals()["sh"] = _fake_sh_bms(fetch_rc=1)
        ok(_branch_merged_state("br") == "unknown",
           "fetch runs but returns nonzero (network hiccup etc.) → unknown, same as sh()-returns-None — a failed fetch is a failed fetch regardless of failure mode")
        ok(not any("rev-parse" in c for c in _bms_calls),
           "nonzero-returncode fetch also short-circuits before rev-parse")

        globals()["sh"] = _fake_sh_bms(rev_rc=1, rev_stdout="")
        ok(_branch_merged_state("br") == "missing",
           "fetch OK + rev-parse ACTUALLY RAN and confirmed the ref doesn't resolve (returncode!=0, empty stdout) → missing is still reachable — the fix narrows what counts as missing, it doesn't remove the state")

        globals()["sh"] = _fake_sh_bms(merge_rc=0)
        ok(_branch_merged_state("br") == "merged", "fetch OK + rev-parse OK + merge-base ancestor(rc=0) → merged (unchanged happy path)")

        globals()["sh"] = _fake_sh_bms(merge_rc=1)
        ok(_branch_merged_state("br") == "unmerged", "fetch OK + rev-parse OK + merge-base not-ancestor(rc=1) → unmerged (unchanged happy path)")

        ok(_branch_merged_state("") == "unknown", "empty branch name → unknown (unchanged guard, no sh() call at all)")
    finally:
        globals()["sh"] = _real_sh
    # FIX 5 — stranded_verdict_verdict (delivered==total stuck run recovery)
    S = 15 * 60
    ok(stranded_verdict_verdict(9 * 60, S, 1, 1) == "skip:young", "young run (9m<15m) → skip (a finalize is seconds after last verdict)")
    ok(stranded_verdict_verdict(38 * 60, S, 1, 1) == "recover", "old + 1/1 delivered → recover (the wa-99jug case)")
    ok(stranded_verdict_verdict(38 * 60, S, 3, 3) == "recover", "old + 3/3 delivered → recover")
    ok(stranded_verdict_verdict(38 * 60, S, 0, 1) == "skip:collecting", "0/1 delivered → skip (still collecting — a real in-progress review)")
    ok(stranded_verdict_verdict(38 * 60, S, 1, 3) == "skip:collecting", "1/3 delivered → skip (partial — not fully terminal-ready)")
    ok(stranded_verdict_verdict(38 * 60, S, 0, 0) == "skip:not-a-run", "0 verdict beads → skip (guard claim-tracking run, not a review)")
    ok(stranded_verdict_verdict(38 * 60, S, -1, -1) == "skip:query-failed", "unreadable verdict counts → skip (never act blind)")
    # boundary: FIX 1 (delivered==0) and FIX 5 (delivered==total) are mutually exclusive
    ok(stranded_verdict_verdict(38 * 60, S, 0, 2) != "recover", "delivered==0 is FIX 1's domain, NOT FIX 5 (no double-handling)")
    # ga-mwsg: FIX 5's stranded-cap escalation must label the SOURCE bead too, not just
    # the marker — FIX 2's skip:parked-needs-human carve-out (asserted above) reads ONLY
    # the source bead's gate:needs-human label. A marker-only label leaves FIX 2 free to
    # requeue right back over the escalation (observed live: marker ga-wisp-0uxxi5
    # escalated 08:51:59Z, requeued by FIX 2 08:52:03Z, 4s later — the circuit breaker
    # never actually broke the circuit).
    ok(set(stranded_escalation_needs_human_targets("ga-wisp-mk1", "ga-4cb2")) == {"ga-wisp-mk1", "ga-4cb2"},
       "stranded-cap escalation must label BOTH marker AND source bead (ga-mwsg)")
    ok(stranded_escalation_needs_human_targets("ga-wisp-mk1", "") == ["ga-wisp-mk1"],
       "no resolvable source bead → label marker only (fail-safe, never crash on empty source)")
    # FIX 6 — stale_review_marker_verdict (dispatching|reviewing marker, dead reviewer, NO run)
    R = 15 * 60
    ok(stale_review_marker_verdict("reviewing", 9 * 60, R, False) == "wait", "young reviewing marker (9m<15m) → wait (dispatch→run-create spin-up)")
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, False) == "requeue", "old reviewing + NO open run → requeue (the wa-b7z7c dead-reviewer orphan)")
    ok(stale_review_marker_verdict("dispatching", 40 * 60, R, False) == "requeue", "old dispatching + NO open run → requeue (reviewer never materialized)")
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, True) == "skip:live-run", "reviewing + OPEN running run → skip (FIX 1/5 own it)")
    ok(stale_review_marker_verdict("dispatching", 40 * 60, R, True) == "skip:live-run", "dispatching + open run → skip (a live review, not stale)")
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, None) == "skip:run-query-failed", "run-query failed (None) → skip (never requeue blind on a Dolt glitch)")
    ok(stale_review_marker_verdict("queued", 40 * 60, R, False) == "skip:not-review-status", "queued marker → not FIX 6's domain (FIX 4 owns queued/ready/claimed)")
    ok(stale_review_marker_verdict("passed", 40 * 60, R, False) == "skip:not-review-status", "terminal (passed) marker → skip")
    # boundary: FIX 6 (no run) and FIX 1/5 (open run) partition the dead-reviewer space
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, True) != "requeue", "an OPEN run is FIX 1/5's domain, NOT FIX 6 (no double-handling)")
    # FIX 3 extension (ga-pp5vh) — frozen_reviewer_run_verdict: post-kill run/marker recovery
    ok(frozen_reviewer_run_verdict({"sess-A"}, {"sess-A", "alias-A"}) == "supersede",
       "killed session is the SOLE pending reviewer (matched via any identity field) → supersede + requeue (ga-pp5vh)")
    ok(frozen_reviewer_run_verdict({"sess-A", "sess-B"}, {"sess-A"}) == "skip:other-pending",
       "another reviewer still pending on the run → skip, leave to FIX 1/timeout (never end a run others are still working)")
    ok(frozen_reviewer_run_verdict({"sess-B"}, {"sess-A"}) == "skip:not-pending",
       "killed session isn't in the run's pending set (never assigned, or already delivered) → skip")
    ok(frozen_reviewer_run_verdict(set(), {"sess-A"}) == "skip:not-pending",
       "no pending reviewers at all (verdicts already fully delivered) → skip, nothing to recover")
    ok(frozen_reviewer_run_verdict(None, {"sess-A"}) == "skip:query-failed",
       "pending-reviewer query failed (None) → fail-safe skip, never supersede blind")
    # AC3 guard-rail: a BOOTING reviewer (state=creating, per quality-gate-dispatcher.sh's
    # session_is_booting) must never be killed nor have its run superseded/marker
    # re-queued. frozen_reviewer_verdict's state!="active" fail-safe already covers this
    # (a booting session is never "active"), so FIX 3's extension inherits the guard for
    # free — this pins that inheritance explicitly rather than relying on the general
    # non-active-state case above.
    ok(frozen_reviewer_verdict("creating", 5000, 900) == "keep", "booting session (state=creating) → keep, NEVER killed (boot-grace inherited for free, AC3 ga-pp5vh)")
    # FIX 2 — error_requeue_verdict (gate-status:error marker requeue decision; now
    # branch-merge-aware, ga-hckn3 — ports FIX 4's orphan_marker_verdict/FIX 7's
    # deferred_requeue_verdict branch_state discipline to the sibling gate-status:error
    # path, which had the textually identical gap)
    E = 8 * 60
    ok(error_requeue_verdict(300, E, True, True, False, 0, 3, "merged") == "close:source-done", "source resolved+CLOSED+branch MERGED → close regardless of age (checked first)")
    ok(error_requeue_verdict(300, E, True, True, False, 0, 3, "missing") == "close:source-done", "source resolved+CLOSED+branch MISSING (abandoned) → close regardless of age")
    # the ga-w5agg/ga-d2jil bug class (ga-hckn3: FIX 2 had the same gap as pre-fix FIX 7/
    # ga-gd706): a closed source bead ALONE does NOT prove the branch landed — the normal
    # dog-self-closes-its-sling-bead-on-submission doctrine closes it immediately after
    # /gate-done regardless of whether a reviewer ever ran. branch_state UNMERGED or
    # UNKNOWN must fall through to the normal age/needs-human/oscillation handling below,
    # NEVER silently close-as-done.
    ok(error_requeue_verdict(600, E, True, True, False, 0, 3, "unmerged") == "requeue", "source CLOSED but branch UNMERGED (real stranding) → falls through to requeue, NEVER false-close (ga-hckn3)")
    ok(error_requeue_verdict(600, E, True, True, False, 0, 3, "unknown") == "requeue", "source CLOSED but branch state UNKNOWN (can't verify) → falls through to requeue, fail-safe (ga-hckn3)")
    ok(error_requeue_verdict(300, E, True, True, False, 0, 3, "unmerged") == "skip:young", "source CLOSED + branch UNMERGED but still in error < threshold → falls through to skip:young, not an immediate close (ga-hckn3)")
    ok(error_requeue_verdict(600, E, True, True, False, 3, 3, "unmerged") == "escalate:oscillating", "source CLOSED + branch UNMERGED + attempts exhausted → falls through to escalate, not a silent close (ga-hckn3)")
    ok(error_requeue_verdict(600, E, True, True, True, 0, 3, "unmerged") == "skip:parked-needs-human", "source CLOSED + branch UNMERGED but source ALSO needs-human → parked carve-out still wins over a bare requeue fall-through (ga-hckn3)")
    ok(error_requeue_verdict(600, E, True, True, False, 0, 3) == "requeue", "branch_state omitted → defaults to 'unknown' (fail-safe default, never close-as-done without explicit verification)")
    ok(error_requeue_verdict(60, E, True, False, False, 0, 3) == "skip:young", "in error < threshold → skip:young (let transient self-clear)")
    ok(error_requeue_verdict(600, E, True, False, True, 0, 3) == "skip:parked-needs-human", "source resolved + needs-human → NEVER requeue (the ga-c1s8 circuit-break carve-out)")
    ok(error_requeue_verdict(600, E, False, False, False, 0, 3) == "requeue", "source UNRESOLVABLE → fail-toward-recovery requeue (bounded by the oscillation cap below — the ga-c1s8 failure mode when rig resolution silently fails)")
    ok(error_requeue_verdict(600, E, True, False, False, 3, 3) == "escalate:oscillating", "requeue_count hit max_attempts → escalate, stop looping")
    ok(error_requeue_verdict(600, E, True, False, False, 2, 3) == "requeue", "requeue_count below max → requeue (one attempt left)")
    # FIX 7 — deferred_requeue_verdict (gate-status:deferred marker recovery, ga-y1kk)
    D = 8 * 60
    ok(deferred_requeue_verdict(300, D, True, True, False, True, 0, 3, branch_state="merged") == "close:source-done", "source resolved+CLOSED+branch MERGED → close regardless of age/author (checked first; ga-gd706 fix-attempt-2: branch_state now required to reach this verdict)")
    ok(deferred_requeue_verdict(600, D, True, True, False, True, 0, 3, branch_state="unmerged") == "requeue", "source resolved+CLOSED but branch UNMERGED (real stranding, ga-gd706) → falls through to requeue, never silently superseded")
    ok(deferred_requeue_verdict(600, D, True, True, False, True, 0, 3) == "requeue", "branch_state omitted → fail-safe default 'unknown' → falls through same as unmerged, never a silent close-by-omission (ga-gd706)")
    ok(deferred_requeue_verdict(600, D, True, True, False, True, 0, 3, branch_state="missing") == "close:source-done", "source resolved+CLOSED and branch MISSING (deleted/renamed) → close, safe to treat as abandoned")
    ok(deferred_requeue_verdict(60, D, True, False, False, True, 0, 3) == "skip:young", "deferred < threshold → skip:young (give gate.submitted_by/a human time to land)")
    ok(deferred_requeue_verdict(600, D, True, False, True, True, 0, 3) == "skip:parked-needs-human", "source needs-human → never requeue")
    ok(deferred_requeue_verdict(600, D, True, False, False, True, 0, 3) == "requeue", "source resolved + derivable author now present → requeue (the ga-y1kk fix)")
    ok(deferred_requeue_verdict(600, D, True, False, False, True, 3, 3) == "escalate:oscillating", "derivable author present but attempts exhausted → escalate, not another requeue")
    ok(deferred_requeue_verdict(600, D, True, False, False, False, 0, 3) == "skip:unresolvable", "source resolved but STILL no derivable author, attempts remain → wait, don't requeue blind")
    ok(deferred_requeue_verdict(600, D, False, False, False, False, 0, 3) == "skip:unresolvable", "source unresolved (bead lookup failed), attempts remain → wait, never close on one blip")
    ok(deferred_requeue_verdict(600, D, False, False, False, False, 3, 3) == "close:unresolvable", "source unresolved across max_attempts sweeps → genuinely gone (ga-y1kk: 'bead também sumiu') → close with explicit reason")
    ok(deferred_requeue_verdict(600, D, True, False, False, False, 3, 3) == "close:unresolvable", "source resolved but NEVER grew a derivable author across max_attempts → also terminal close (never oscillate — it never had one to lose)")
    ok(deferred_requeue_verdict(600, D, False, False, False, True, 0, 3) == "requeue", "GATE-FEEDBACK gate_run=ga-wisp-d9fqvt attempt 1: source UNRESOLVED (transient query failure or genuinely gone) but marker already carries gate.submitted_by (has_derivable_author=True from the marker's OWN metadata, independent of source resolution — exactly ga-wisp-5zki27's manual-recovery scenario) → requeue, NOT skip:unresolvable")
    ok(deferred_requeue_verdict(600, D, False, False, False, True, 3, 3) == "escalate:oscillating", "same source-unresolved+gate.submitted_by-present marker, attempts now exhausted → escalate (an author WAS derivable the whole time), never close:unresolvable with a reason that would falsely claim gate.submitted_by is absent")
    # ga-c1s8 — _bead_id_prefix, the fallback rig-resolution key when bead-rig: is absent
    ok(_bead_id_prefix("wa-10srb") == "wa", "wa-10srb -> wa (the ga-c1s8 marker's WA-rig source bead)")
    ok(_bead_id_prefix("ga-wisp-me6y20") == "ga", "ga-wisp-me6y20 -> ga (split on the FIRST hyphen only)")
    ok(_bead_id_prefix("") == "" and _bead_id_prefix(None) == "", "empty/None -> '' (fail-safe, never crashes)")
    ok(_bead_id_prefix("noHyphenId") == "", "no hyphen -> '' (unknown prefix, fails safe to HQ-only lookup)")
    # FIX 8 — orphan_gate_label_verdict (phantom gate:queued/gate:reviewing, NO marker at all)
    T = ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD
    ok(orphan_gate_label_verdict(T - 1, T) == "wait", "one sweep short of threshold -> wait")
    ok(orphan_gate_label_verdict(T, T) == "clear", "exactly at threshold -> clear")
    ok(orphan_gate_label_verdict(T + 5, T) == "clear", "past threshold -> still clear")
    ok(orphan_gate_label_verdict(0, T) == "wait", "never seen (0 hits) -> wait")
    ok(orphan_gate_label_verdict(1, 1) == "clear", "sanity: WITHOUT any hysteresis (threshold=1) a single sighting fires immediately — proving ORPHAN_GATE_LABEL_CONFIRM_THRESHOLD=%d is the ONLY thing standing between a marker-visibility race (sweep 1 misses a just-created marker) and a false clear" % T)
    # FIX 8 — _update_orphan_gate_label_hits (the CONSECUTIVE-sweep counting rule)
    ok(_update_orphan_gate_label_hits({}, {("ga-x", "gate:queued")}) == {("ga-x", "gate:queued"): 1},
       "first sighting of a candidate -> hits=1")
    ok(_update_orphan_gate_label_hits({("ga-x", "gate:queued"): 1}, {("ga-x", "gate:queued")}) == {("ga-x", "gate:queued"): 2},
       "re-detected next sweep -> hits increments (consecutive)")
    ok(_update_orphan_gate_label_hits({("ga-x", "gate:queued"): 2}, set()) == {},
       "the ga-yzw06 race guard: NOT re-detected this sweep (a marker appeared, or the label's gone) -> DROPPED entirely, not merely frozen at 2")
    ok(_update_orphan_gate_label_hits({("ga-x", "gate:queued"): 2, ("ga-y", "gate:reviewing"): 5},
                                       {("ga-x", "gate:queued")}) == {("ga-x", "gate:queued"): 3},
       "unrelated pair (ga-y) drops out independently when not re-detected; the still-candidate pair (ga-x) keeps accumulating")
    ok(_update_orphan_gate_label_hits({("ga-x", "gate:queued"): 9}, {("ga-x", "gate:queued")}) != {("ga-x", "gate:queued"): 9},
       "re-detection always increments — a candidate never plateaus (guards against an off-by-one that silently stops counting)")
    # FIX 8 scenario: the exact marker-visibility race the bug (ga-yzw06) asks for —
    # sweep 1 sees a bead as unreferenced (marker just created by gate-done.md, not yet
    # queryable), sweep 2 sees the SAME marker now visible -> must NOT have fired.
    race = _update_orphan_gate_label_hits({}, {("ga-race", "gate:queued")})
    ok(orphan_gate_label_verdict(race[("ga-race", "gate:queued")], T) == "wait",
       "sweep 1 of a fresh candidate -> wait, never clear on a single sighting")
    race = _update_orphan_gate_label_hits(race, set())  # sweep 2: marker now visible, not a candidate
    ok(("ga-race", "gate:queued") not in race,
       "sweep 2 (marker now visible) resets the streak to gone — confirms hysteresis actually prevented the false clear, not just delayed it")
    # FIX 8 scope guard: reap_orphan_gate_labels must NEVER touch story:*/assignee — the
    # ga-yzw06 trap this bug explicitly warns against (an over-eager fix that repositions
    # lifecycle state instead of just clearing the phantom label). Static source-inspection
    # mutation guard: if this invariant is ever violated by a future edit, this goes RED.
    _fix8_src = inspect.getsource(reap_orphan_gate_labels)
    ok('"story:' not in _fix8_src and "'story:" not in _fix8_src,
       "FIX 8 source never references a story:* label literal (label-only fix; painel's column derivation never reads gate:* labels, so there is nothing to 'restore')")
    ok("--assignee" not in _fix8_src and '"update"' not in _fix8_src,
       "FIX 8 source never reassigns/updates the bead (dead-assignee reset is orphan-sweep.sh's job, not this fix's — no double-handling)")
    ok('"label", "remove"' in _fix8_src,
       "sanity: the guard above isn't vacuous — FIX 8 does perform its OWN real mutation (label remove)")
    # FIX 9 — needs_rebase_verdict (permanent gate-status:needs-rebase park recovery,
    # ga-7b19e). Unlike FIX2/FIX7, this verdict NEVER returns "requeue" — needs-rebase
    # is reached only after the gate itself already confirmed a deterministic conflict
    # (dead author, or MAX_REBASE_ATTEMPTS exhausted), so a blind requeue would just
    # reproduce the identical conflict for nothing.
    NR = 15 * 60
    ok(needs_rebase_verdict(300, NR, True, True, False, "merged") == "skip:young",
       "GATE-FEEDBACK regression (ga-7b19e attempt 2 FAIL): a brand-new marker (age < threshold) never closes on sweep 1 even when branch_state is already MERGED — the age gate now runs before branch_state is ever consulted, mirroring FIX 4's own young-marker guard instead of letting a single sweep act on a signal that may not have replicated yet")
    ok(needs_rebase_verdict(600 * 60, NR, True, True, False, "unmerged") == "escalate",
       "GATE-FEEDBACK regression (ga-7b19e attempt 1 FAIL): source resolved+CLOSED but branch UNMERGED (stranded fix) must NEVER close — a closed source does not prove the work landed (mirrors FIX 4's orphan_marker_verdict recover-stranded guard, ga-w5agg/ga-d2jil class). The original FIX 9 draft closed here unconditionally; this is the falsifying case for that exact bug.")
    ok(needs_rebase_verdict(600 * 60, NR, True, False, False, "merged") == "close:branch-landed",
       "source OPEN but branch MERGED → close (work landed some other way)")
    ok(needs_rebase_verdict(600 * 60, NR, True, True, False, "missing") == "close:branch-landed",
       "branch MISSING (abandoned) + source CLOSED → close (moot, corroborated) — mirrors FIX 4's orphan_marker_verdict: missing needs source_closed alongside it, merged doesn't")
    ok(needs_rebase_verdict(600 * 60, NR, True, False, False, "missing") == "escalate",
       "GATE-FEEDBACK regression (ga-7b19e attempt 2 FAIL): branch MISSING but source still OPEN → does NOT close, falls through to escalate. 'missing' is absence of evidence — closing on it ALONE would reproduce the exact silent-stranding class (ga-w5agg/ga-d2jil) this fix exists to prevent; only 'merged' is positive-enough proof to close unaccompanied")
    ok(needs_rebase_verdict(60, NR, True, False, False, "unmerged") == "skip:young",
       "parked < threshold → skip:young (give a human time to react organically first)")
    ok(needs_rebase_verdict(600 * 60, NR, True, False, True, "unmerged") == "skip:parked-needs-human",
       "source needs-human → a different mechanism (needs-human-divergence-sweep) owns escalation")
    ok(needs_rebase_verdict(600 * 60, NR, True, False, False, "unmerged") == "escalate",
       "the wa-juety case: old + source open + branch real & unmerged → escalate, NEVER requeue (would reproduce the identical gate-confirmed conflict)")
    ok(needs_rebase_verdict(600 * 60, NR, True, False, False, "unknown") == "escalate",
       "branch state unknown (git/rig error) → escalate (the safe direction), NEVER auto-close blind")
    ok(needs_rebase_verdict(600 * 60, NR, False, False, False, "unmerged") == "escalate",
       "source unresolvable (query failed) but old → escalate rather than silently do nothing (fail toward visibility, not silence)")
    # ga-7b19e FALSIFYING TEST — the exact wa-juety scenario from the bug's acceptance
    # criteria: marker at gate-status:needs-rebase (open), branch on origin (real work,
    # unmerged), source bead ctx:ready/exec:auto/story:approved (open, no needs-human).
    # Before this fix NOTHING ever revisited this marker — it aged silently (measured:
    # wa-juety sat 5 days, the oldest of 9 sibling markers sat 10, before a human
    # happened to look). The bead must exit limbo via one of ga-7b19e's two sanctioned
    # outcomes — dispatchable again (deliberately NOT attempted, see FIX 9's constants
    # docstring for why that's unsafe) OR a visible alert carrying its age. This asserts
    # the escalate path fires for that exact shape — proving silence is no longer the
    # outcome. Without this fix, the deadlock stays intact — exactly what happened for
    # 5 real days.
    ok(needs_rebase_verdict(7 * 24 * 3600, NR, True, False, False, "unmerged") == "escalate",
       "ga-7b19e falsifying test: wa-juety-shaped scenario (5d parked, source open+approved, real unmerged branch on origin) → escalate, the bead exits limbo instead of staying silent")
    _nr_src = inspect.getsource(needs_rebase_verdict)
    ok('"requeue"' not in _nr_src,
       "needs_rebase_verdict source never returns 'requeue' — the entire point of FIX 9 (a blind requeue would reproduce a gate-confirmed deterministic conflict, unlike FIX2's transient error)")
    _nr_action_src = inspect.getsource(recover_needs_rebase_markers)
    ok("push" not in _nr_action_src and "--force" not in _nr_action_src,
       "FIX 9 action never pushes/force-pushes the branch — branch deletion/rebuild stays a human/Mayor decision (never autonomous), matching the dead-author re-anchor doctrine")
    print("gate-recovery-watchdog FIX2+FIX3+FIX4+FIX5+FIX6+FIX7+FIX8+FIX9 selftest: PASS=%d FAIL=%d" % (p, f))
    return 0 if f == 0 else 1


if __name__ == "__main__":
    if "--selftest" in _sys.argv:
        _sys.exit(_selftest())
    main()
