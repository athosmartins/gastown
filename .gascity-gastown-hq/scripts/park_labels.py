#!/usr/bin/env python3
"""park_labels.py — canonical park/travada label vocabulary.

WHY THIS EXISTS (ga-hzt8s, 2026-07-20): three consumers each hand-maintained
their own copy of "which labels mean this bead is not currently
auto-dispatchable" — approved-state-reconciler.py's _classify(),
imparavel-check.py's PARKING_LABELS, and throughput-stall-watchdog.py's
EXCLUDE_LABELS_BACKLOG. The three drifted out of sync bead-by-bead (a label
added to one was never mirrored to the others), so story:approved lingered on
parked beads and inflated backlog/stall counts (17 all-parked story:approved
beads counted as live queue -> false "GATE THROUGHPUT STALL").

This module is the single place that vocabulary lives. Import it rather than
hardcoding label strings in a new check.

NOT in scope here: painel_visibilidade.py's _TRAVADA_* taxonomy. That file
lives in a separate repo (whatsapp-automation, painel-prod/whatsapp_automation)
and is explicitly out of scope for this consolidation — mirror by hand if its
taxonomy changes (as reconciler's _process_store() already does for the
--status filter, see approved-state-reconciler.py line ~1016).
"""


def label_matches(label, base):
    """A label matches a base if it is the base exactly, or a ":"- or
    "-"-suffixed variant (e.g. base "gate:needs-human" also matches
    "gate:needs-human:product"; base "pilot:held" also matches
    "pilot:held-until:1690000000"). This is imparavel-check.py's original
    _label_matches rule — the most general of the three prior ad-hoc matchers
    (throughput-stall-watchdog's _bead_is_braked only matched the ":" suffix,
    which is why it missed pilot:held-until:* despite listing "pilot:held")."""
    return label == base or label.startswith(base + ":") or label.startswith(base + "-")


def is_labeled(labels, base):
    """True iff any label in `labels` matches `base` (see label_matches)."""
    return any(label_matches(label, base) for label in labels)


def any_labeled(labels, bases):
    """True iff any label in `labels` matches any base in `bases`."""
    return any(is_labeled(labels, base) for base in bases)


# ── individually-named labels ────────────────────────────────────────────────
# Referenced by name at specific call sites (routing tables, single suppress-
# checks) whose CONTROL FLOW is bespoke per consumer (e.g. the reconciler's
# _classify() routes to a target bucket, not just a yes/no). Naming the string
# here still gives it one home even though the surrounding logic isn't shared.
GATE_PASSED_LABEL = "gate:passed"
NEEDS_DEVICE_LABEL = "story:needs-device"
NEEDS_HUMAN_LABEL = "story:needs-human"
GATE_NEEDS_HUMAN_PREFIX = "gate:needs-human"
BLOCKED_LABELS = ("blocked", "story:blocked")
GATE_NEEDS_FIX_LABEL = "gate:needs-fix"
GATE_FAILED_LABEL = "gate:failed"
EXEC_MANUAL_LABEL = "exec:manual"
PILOT_HELD_LABEL = "pilot:held"

# ── grouped sets for consumers that just need "is this bead parked?" ────────

# Human-in-the-loop: a human must act before this bead can proceed.
NEEDS_HUMAN_LABELS = frozenset({
    GATE_NEEDS_HUMAN_PREFIX, NEEDS_HUMAN_LABEL, "needs-human", "needs-label-review",
})

# Manual/device execution — the headless pool cannot build this by design.
MANUAL_EXEC_LABELS = frozenset({
    EXEC_MANUAL_LABEL, "on-device", NEEDS_DEVICE_LABEL, "phone-proxy",
})

# Explicitly blocked, by label or by an external dependency.
BLOCKED_FAMILY_LABELS = frozenset({
    "blocked", "story:blocked", "blocked-on", "blocked-reason", "waiting-on",
    "next-action", "needs:rehome",
})

# Not ready / not current right now: still being refined, under-specified,
# cancelled, parked pending an engine window or an external merge, or a pool
# worker already declined it.
NOT_READY_LABELS = frozenset({
    "story:refinement-in-progress", "ctx:thin", "story:cancelled",
    "framework:engine", "story:awaiting-external-merge", "pool:refused",
})

# Pilot deliberately withheld dispatch — a standing hold or an explicit
# no-dispatch directive. "pilot:held-until:<epoch>" is matched via the "-"
# suffix rule on PILOT_HELD_LABEL (label_matches), not listed separately.
PILOT_HELD_LABELS = frozenset({PILOT_HELD_LABEL, "pilot:no-auto-dispatch"})

# In the gate-fix retry loop, or already inside the gate pipeline — the
# gate/Pilot owns re-dispatch here, so this is not a silent dispatch failure.
GATE_PARK_LABELS = frozenset({
    GATE_NEEDS_FIX_LABEL, GATE_FAILED_LABEL, "gate:needs-rebase",
    "gate:queued", "gate:reviewing",
})

# Already dispatched/building, or finished — not idle backlog. Kept separate
# from PARK_LABELS/GATE_PARK_LABELS on purpose: consumers that already have
# bespoke flowing/in-gate detection (imparavel's classify_bead +
# gate_source_beads, the reconciler's _is_flowing) must not double up on it.
# A consumer that just wants "exclude from backlog count" (the throughput
# watchdog) unions this set in too.
FLOWING_OR_DONE_LABELS = frozenset({
    "story:in-flight", "pilot:dispatched", "pilot:dispatching", "story:done",
})

# The "parked for a real, human/external reason" union — the closest analogue
# to imparavel's original PARKING_LABELS and painel's _TRAVADA_REASON_LABELS.
# Excludes GATE_PARK_LABELS and FLOWING_OR_DONE_LABELS on purpose (see their
# comments above) — callers that need those too must union them in explicitly.
PARK_LABELS = (
    NEEDS_HUMAN_LABELS | MANUAL_EXEC_LABELS | BLOCKED_FAMILY_LABELS
    | NOT_READY_LABELS | PILOT_HELD_LABELS
)

# ── reclaim-count (pilot:reclaim-count:N) ────────────────────────────────────
# Mirrors MAX_RECLAIMS in inflight-reclaim-guard.py and _FILTER_RECLAIM_CAP in
# pilot-dispatcher.sh — no single source of truth across those two either
# (pre-existing, out of scope here). approved-state-reconciler.py keeps its own
# env-overridable RECLAIM_CAP (ARC_RECLAIM_CAP) rather than importing this
# constant, to preserve that override; use DEFAULT_RECLAIM_CAP as the shared
# fallback value for consumers that don't have their own knob yet.
DEFAULT_RECLAIM_CAP = 3


def parse_reclaim_count(labels):
    """Highest N across every pilot:reclaim-count:N label; 0 if none/unparseable."""
    best = 0
    for label in labels:
        if label.startswith("pilot:reclaim-count:"):
            try:
                best = max(best, int(label.rsplit(":", 1)[1]))
            except (ValueError, IndexError):
                pass
    return best


def is_reclaim_exhausted(labels, cap=DEFAULT_RECLAIM_CAP):
    """True iff a pilot:reclaim-count:N label is present with N >= cap — the
    reclaim-guard circuit-broke and gave up retrying (not a live dispatch
    failure to alarm on)."""
    return parse_reclaim_count(labels) >= cap
