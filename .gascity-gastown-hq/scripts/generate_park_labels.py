#!/usr/bin/env python3
"""generate_park_labels.py — builds park_labels.py and park_labels.sh from the
single source of truth in park_labels.json (ga-r150x9, Phase 1).

WHY THIS EXISTS: park_labels.py and park_labels.sh used to be two copies of
the park/hold/veto label vocabulary, hand-kept in sync -- park_labels.sh's own
header admitted "there is no build step that generates one from the other, so
a label added to one MUST be added to the other too". This script is that
build step. The label VOCABULARY (which labels exist, how they're grouped)
now lives in exactly one place, park_labels.json; park_labels.py and
park_labels.sh are generated outputs.

Usage:
    python3 scripts/generate_park_labels.py --check   # exit 1 + diff if the
                                                        # committed files are
                                                        # stale (CI / pre-push)
    python3 scripts/generate_park_labels.py --write    # regenerate them

Scope note (Phase 1, per ga-r150x9's acceptance criteria): this script
generates park_labels.py and park_labels.sh ONLY. It does not touch any of
the ~34 consumers that hand-roll their own label lists -- migrating those is
explicitly out of scope for this bead and comes later, one at a time, each
through its own review.
"""
import argparse
import difflib
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_PATH = os.path.join(SCRIPT_DIR, "park_labels.json")
PY_TARGET = os.path.join(SCRIPT_DIR, "park_labels.py")
SH_TARGET = os.path.join(SCRIPT_DIR, "park_labels.sh")


def load_source(path=SOURCE_PATH):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _py_token(member):
    """The exact token generate_park_labels.py's frozenset literals use for
    this member: a bare reference to an individually-named constant when the
    source says so, else a quoted string literal. This mirrors the *original*
    hand-written file, which does not always prefer the named constant even
    when one exists for a given value (e.g. NEEDS_HUMAN_LABELS' third member
    is the literal "needs-human", not a reference to NEEDS_HUMAN_BARE_LABEL,
    which is named individually below for a different consumer's benefit) --
    py_token in the source captures that per-member choice explicitly rather
    than guessing at it."""
    tok = member.get("py_token")
    if tok:
        return tok
    return json.dumps(member["label"])


def _wrap_lines(items, breaks):
    """Split the flat `items` list into chunks per `breaks` (list of chunk
    sizes). If `breaks` doesn't account for every item (e.g. a label was
    added to the source without updating the hint), the remainder is
    appended as one extra final chunk -- deterministic, no guessing at the
    "ideal" wrap column for content nobody has hand-tuned yet."""
    chunks = []
    i = 0
    for n in breaks:
        chunks.append(items[i:i + n])
        i += n
    if i < len(items):
        chunks.append(items[i:])
    return [c for c in chunks if c]


def render_group_py(group):
    """Render one group's frozenset assignment (with its trailing blank line
    left to the caller) -- either the "exploded" multi-line form or the
    "compact" single-line form the source's py_style says to use."""
    tokens = [_py_token(m) for m in group["members"]]
    const = group["py_const"]
    if group["py_style"] == "compact":
        return f"{const} = frozenset({{{', '.join(tokens)}}})"
    lines = _wrap_lines(tokens, group["py_line_breaks"])
    body = "\n".join("    " + ", ".join(chunk) + "," for chunk in lines)
    return f"{const} = frozenset({{\n{body}\n}})"


def render_park_labels_py(data):
    comp = data["park_labels_composition"]
    by_id = {g["id"]: g for g in data["groups"]}
    consts = [by_id[gid]["py_const"] for gid in comp["order"]]
    lines = _wrap_lines(consts, comp["line_breaks"])
    rendered = []
    for idx, chunk in enumerate(lines):
        joined = " | ".join(chunk)
        if idx == 0:
            rendered.append(f"    {joined}")
        else:
            rendered.append(f"    | {joined}")
    body = "\n".join(rendered)
    return f"PARK_LABELS = (\n{body}\n)"


def render_group_sh(group):
    quoted = [json.dumps(m["label"]) for m in group["members"]]
    lines = _wrap_lines(quoted, group["sh_line_breaks"])
    rendered = [f"  # {group['sh_comment']}"]
    for chunk in lines:
        rendered.append("  " + " ".join(chunk))
    return "\n".join(rendered)


PY_HEADER = '''#!/usr/bin/env python3
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
# ga-m0ksy: the BARE spelling, named individually (not folded into the
# NEEDS_HUMAN_LABELS grouped set's consumption below) so a consumer that
# wants exactly {bare, gate:needs-human*, story:needs-human} — and NOT the
# grouped set's 4th member "needs-label-review", a distinct signal this bead
# never measured or asked about — can reference it without silently
# adopting label semantics beyond what was verified. Already present in
# NEEDS_HUMAN_LABELS below (has been since ga-hzt8s) — that set's other
# consumers (imparavel-check.py, throughput-stall-watchdog.py) already
# recognize it; approved-state-reconciler.py's _classify() is the one
# consumer with its own bespoke routing table that had fallen out of sync.
NEEDS_HUMAN_BARE_LABEL = "needs-human"
BLOCKED_LABELS = ("blocked", "story:blocked")
GATE_NEEDS_FIX_LABEL = "gate:needs-fix"
GATE_FAILED_LABEL = "gate:failed"
EXEC_MANUAL_LABEL = "exec:manual"
# ga-it3e8: named individually (already a member of NOT_READY_LABELS below,
# same as NEEDS_HUMAN_BARE_LABEL's relationship to NEEDS_HUMAN_LABELS above)
# so approved-state-reconciler.py's starve-alarm suppress-check — a bespoke
# single-label check, same shape as its EXEC_MANUAL_LABEL check right below
# this constant's own consumer — has a canonical name to reference instead of
# a bare "ctx:thin" string. A ctx:thin bead (too little context to build,
# awaiting refino) alarmed "dispatch path failing" every cycle forever before
# this fix — the Pilot was correctly declining to dispatch it.
CTX_THIN_LABEL = "ctx:thin"
PILOT_HELD_LABEL = "pilot:held"

# ── grouped sets for consumers that just need "is this bead parked?" ────────
'''

PY_FOOTER_TEMPLATE = '''
# ── reclaim-count (pilot:reclaim-count:N) ────────────────────────────────────
# Mirrors MAX_RECLAIMS in inflight-reclaim-guard.py and _FILTER_RECLAIM_CAP in
# pilot-dispatcher.sh — no single source of truth across those two either
# (pre-existing, out of scope here). approved-state-reconciler.py keeps its own
# env-overridable RECLAIM_CAP (ARC_RECLAIM_CAP) rather than importing this
# constant, to preserve that override; use DEFAULT_RECLAIM_CAP as the shared
# fallback value for consumers that don't have their own knob yet.
DEFAULT_RECLAIM_CAP = {reclaim_cap}


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
'''

# Per-group leading comment (rich, py-specific prose) and trailing blank-line
# behavior — keyed by group id. Fixed template text: the WHY for each group
# doesn't change when a label is added to it, so this stays hand-written
# rather than derived from park_labels.json.
PY_GROUP_COMMENTS = {
    "needs_human": "\n# Human-in-the-loop: a human must act before this bead can proceed.\n",
    "manual_exec": "\n# Manual/device execution — the headless pool cannot build this by design.\n",
    "blocked_family": "\n# Explicitly blocked, by label or by an external dependency.\n",
    "not_ready": (
        "\n# Not ready / not current right now: still being refined, under-specified,\n"
        "# cancelled, parked pending an engine window or an external merge, or a pool\n"
        "# worker already declined it.\n"
    ),
    "pilot_held": (
        "\n# Pilot deliberately withheld dispatch — a standing hold or an explicit\n"
        "# no-dispatch directive. \"pilot:held-until:<epoch>\" is matched via the \"-\"\n"
        "# suffix rule on PILOT_HELD_LABEL (label_matches), not listed separately.\n"
    ),
    "gate_park": (
        "\n# In the gate-fix retry loop, or already inside the gate pipeline — the\n"
        "# gate/Pilot owns re-dispatch here, so this is not a silent dispatch failure.\n"
    ),
    "flowing_or_done": (
        "\n# Already dispatched/building, or finished — not idle backlog. Kept separate\n"
        "# from PARK_LABELS/GATE_PARK_LABELS on purpose: consumers that already have\n"
        "# bespoke flowing/in-gate detection (imparavel's classify_bead +\n"
        "# gate_source_beads, the reconciler's _is_flowing) must not double up on it.\n"
        "# A consumer that just wants \"exclude from backlog count\" (the throughput\n"
        "# watchdog) unions this set in too.\n"
    ),
}

PARK_LABELS_COMMENT = (
    "\n# The \"parked for a real, human/external reason\" union — the closest analogue\n"
    "# to imparavel's original PARKING_LABELS and painel's _TRAVADA_REASON_LABELS.\n"
    "# Excludes GATE_PARK_LABELS and FLOWING_OR_DONE_LABELS on purpose (see their\n"
    "# comments above) — callers that need those too must union them in explicitly.\n"
)


def render_py(data):
    by_id = {g["id"]: g for g in data["groups"]}
    order = ["needs_human", "manual_exec", "blocked_family", "not_ready", "pilot_held",
             "gate_park", "flowing_or_done"]
    assert set(by_id) == set(order), "park_labels.json group ids changed shape — update generate_park_labels.py's fixed group order/comments"

    parts = [PY_HEADER]
    for gid in order:
        parts.append(PY_GROUP_COMMENTS[gid])
        parts.append(render_group_py(by_id[gid]))
        parts.append("\n")
    parts.append(PARK_LABELS_COMMENT)
    parts.append(render_park_labels_py(data))
    parts.append("\n")
    parts.append(PY_FOOTER_TEMPLATE.format(reclaim_cap=data["default_reclaim_cap"]))
    return "".join(parts)


SH_HEADER = '''#!/usr/bin/env bash
# park_labels.sh — shell-sourceable mirror of park_labels.py's PARK_LABELS +
# GATE_PARK_LABELS + FLOWING_OR_DONE_LABELS union and matching rule.
#
# WHY THIS EXISTS (ga-hzt8s, 2026-07-20): park_labels.py is canonical for the
# three Python consumers (approved-state-reconciler.py, imparavel-check.py,
# throughput-stall-watchdog.py). This file exists so a future shell daemon
# (e.g. quality-gate-dispatcher.sh) can check the same vocabulary without
# reimplementing its own list. Hand-kept in sync with park_labels.py — there is
# no build step that generates one from the other, so a label added to one
# MUST be added to the other too (this is exactly the drift this bug fixed;
# don't recreate it here).
#
# Usage:
#   source scripts/park_labels.sh
#   if bead_is_parked "${labels[@]}"; then ...; fi

PARK_LABEL_BASES=(
'''

SH_FOOTER_TEMPLATE = ''')

PARK_LABEL_DEFAULT_RECLAIM_CAP={reclaim_cap}

# park_label_matches <label> <base> — exact match, or a ":"- or "-"-suffixed
# variant (mirrors park_labels.py's label_matches).
park_label_matches() {{
  local label="$1" base="$2"
  [ "$label" = "$base" ] && return 0
  case "$label" in
    "$base":*|"$base"-*) return 0 ;;
  esac
  return 1
}}

# bead_is_parked <label1> [label2 ...] — true (exit 0) if any label matches a
# PARK_LABEL_BASES entry, or is a pilot:reclaim-count:N with N >= the cap.
bead_is_parked() {{
  local label base n
  for label in "$@"; do
    for base in "${{PARK_LABEL_BASES[@]}}"; do
      park_label_matches "$label" "$base" && return 0
    done
    case "$label" in
      pilot:reclaim-count:*)
        n="${{label##*:}}"
        case "$n" in
          ''|*[!0-9]*) : ;;
          *) [ "$n" -ge "$PARK_LABEL_DEFAULT_RECLAIM_CAP" ] && return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}}
'''


def render_sh(data):
    order = ["needs_human", "manual_exec", "blocked_family", "not_ready", "pilot_held",
             "gate_park", "flowing_or_done"]
    by_id = {g["id"]: g for g in data["groups"]}
    body = "\n".join(render_group_sh(by_id[gid]) for gid in order)
    return SH_HEADER + body + "\n" + SH_FOOTER_TEMPLATE.format(reclaim_cap=data["default_reclaim_cap"])


def _diff(name, expected, actual):
    if expected == actual:
        return None
    return "".join(difflib.unified_diff(
        expected.splitlines(keepends=True),
        actual.splitlines(keepends=True),
        fromfile=f"{name} (committed)",
        tofile=f"{name} (generated)",
    ))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="write generated content to park_labels.py/.sh")
    ap.add_argument("--check", action="store_true", help="exit 1 + print diff if generated output differs from committed files (default action)")
    args = ap.parse_args()

    data = load_source()
    py_out = render_py(data)
    sh_out = render_sh(data)

    if args.write:
        with open(PY_TARGET, "w", encoding="utf-8") as f:
            f.write(py_out)
        with open(SH_TARGET, "w", encoding="utf-8") as f:
            f.write(sh_out)
        print(f"wrote {PY_TARGET}\nwrote {SH_TARGET}")
        return 0

    # --check is the default when neither flag is given.
    with open(PY_TARGET, "r", encoding="utf-8") as f:
        py_committed = f.read()
    with open(SH_TARGET, "r", encoding="utf-8") as f:
        sh_committed = f.read()

    diffs = []
    d = _diff("scripts/park_labels.py", py_committed, py_out)
    if d:
        diffs.append(d)
    d = _diff("scripts/park_labels.sh", sh_committed, sh_out)
    if d:
        diffs.append(d)

    if diffs:
        sys.stderr.write(
            "park_labels.py / park_labels.sh are STALE relative to park_labels.json.\n"
            "Run: python3 scripts/generate_park_labels.py --write\n\n"
        )
        for d in diffs:
            sys.stderr.write(d)
            sys.stderr.write("\n")
        return 1

    print("OK: park_labels.py and park_labels.sh match park_labels.json exactly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
