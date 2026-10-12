#!/usr/bin/env python3
"""feature_slice_type.py — a slice of a feature is a feature, not a task (ga-2xdj1x).

WHY THIS EXISTS (2026-10-12): slices of a feature were created with `-t task` ("Montar demanda
fatia 9/9", "Nota Predinho fatia 2/5"). `bd create --parent` with no `-t` makes a task, and the E11
refusal told builders to slice without saying so. A task slice loses its turn in the gate order
(priority > type > age, Athos 06/10, kept 12/10) and inflates "tasks" on the painel; the Mayor
retyped 10 open ones by hand. The instruction now sits where slicing is told (quality-gate-guard.sh
E11, commands/gate-done.md, refino); this is the sweep for what still slips through. It runs as a
step of approved-state-reconciler.py — no launchd job of its own.

THE RULE: an open task bead (open / in_progress / blocked / deferred) whose ancestors lead to a
FEATURE is retyped to feature, with a comment. The parent is the bead's `parent` field, else the
dotted id's prefix (`wa-d3ys32.2.1` -> `wa-d3ys32.2`). The climb goes THROUGH task ancestors (a task
slice of a task slice of a feature) and is decided by the nearest ancestor that is not a task:
  feature     the bead is a slice of a feature: retype it.
  no-feature  the climb ended at a root, or at a bug / chore / epic / ...: leave it. A task under a
              task stays a task, a task under a bug stays a task.
  unreadable  an ancestor could not be read (bd failed, gone, no type, a cycle, too deep): leave it
              and COUNT it. "Could not find out" never reads as "no feature above" (root-class:
              error-vs-empty). An epic ancestor is deliberately not enough: refino's split already
              makes an epic's children features, and a promotion moves a bead up the gate queue, so
              the rule stays as narrow as the bead states it.

SAFETY: DRY_RUN writes nothing. A write counts only after a read-back shows the new type (bd's
return code has lied before). At most max_fixes attempts per cycle, so a wrong ancestor reading
cannot mass-promote the backlog. Workflow beads (`molecule_id` / `gc.root_bead_id` metadata) are
not slices and are never touched. A store that cannot be listed is skipped and counted.

USE: sweep(rig_roots, bd, ...) is what the reconciler calls; bd(root, args) returns (rc, stdout) or
None, so a test injects a fake store. `python3 feature_slice_type.py --audit [root ...]` is the
read-only form: per store, how many open tasks still have a feature above them (the acceptance
query of ga-2xdj1x — 0 after 24 h; exit 0 only when that is 0 and nothing was unreadable).
"""
import json
import os
import re
import subprocess
import sys

OPEN_STATUSES = "open,in_progress,blocked,deferred"
MAX_CLIMB = 8          # dotted ids are 2-3 deep; a longer chain is a cycle or garbage -> unreadable
DEFAULT_MAX_FIXES = 25
BD_TIMEOUT = 60

FEATURE = "feature"
NO_FEATURE = "no-feature"
UNREADABLE = "unreadable"

_DOTTED = re.compile(r"^(?P<parent>.+)\.[0-9]+$")
_WORKFLOW_KEYS = ("molecule_id", "gc.root_bead_id")


class _Unreadable(Exception):
    pass


def bead_type(bead):
    """The bead's issue type, lowercased; None when the record does not carry one."""
    t = bead.get("issue_type")
    if t is None:
        t = bead.get("type")
    if not isinstance(t, str) or not t.strip():
        return None
    return t.strip().lower()


def parent_id(bead):
    """Id of the bead's parent: the `parent` field if present, else the dotted id's prefix.
    None = a root (no parent field, no `.N` tail). A `parent` that is present but not a usable
    string raises _Unreadable: a malformed field is not the same as "no parent"."""
    p = bead.get("parent")
    if p not in (None, ""):
        if isinstance(p, str) and p.strip():
            return p.strip()
        raise _Unreadable("parent field is not an id: %r" % (p,))
    m = _DOTTED.match(str(bead.get("id") or ""))
    return m.group("parent") if m else None


def is_workflow_bead(bead):
    md = bead.get("metadata")
    return isinstance(md, dict) and any(md.get(k) for k in _WORKFLOW_KEYS)


def ancestor_verdict(bead, lookup):
    """-> (verdict, detail). lookup(id) -> ("ok", record) | ("missing", None) | ("error", None).
    verdict is FEATURE (detail = the feature ancestor's id), NO_FEATURE or UNREADABLE."""
    seen = {str(bead.get("id") or "")}
    cur = bead
    for _ in range(MAX_CLIMB):
        try:
            pid = parent_id(cur)
        except _Unreadable as e:
            return UNREADABLE, str(e)
        if pid is None:
            return NO_FEATURE, "raiz"
        if pid in seen:
            return UNREADABLE, "ciclo em %s" % pid
        seen.add(pid)
        status, rec = lookup(pid)
        if status != "ok" or not isinstance(rec, dict):
            return UNREADABLE, "ancestral %s: %s" % (pid, "nao encontrado" if status == "missing" else "ilegivel")
        t = bead_type(rec)
        if t is None:
            return UNREADABLE, "ancestral %s sem tipo" % pid
        if t == "feature":
            return FEATURE, pid
        if t != "task":
            return NO_FEATURE, "%s e %s" % (pid, t)
        cur = rec
    return UNREADABLE, "cadeia com mais de %d niveis" % MAX_CLIMB


def _parse_list(raw):
    """bd list/show --json -> list of dicts, or None when the payload is not JSON of a known shape.
    An empty list is a real answer (nothing there); None is "could not read"."""
    if raw is None or not raw.strip():
        return None
    try:
        d = json.loads(raw)
    except ValueError:
        return None
    if isinstance(d, dict):
        d = [d] if "id" in d else (d.get("issues") or d.get("beads") or d.get("items"))
    if not isinstance(d, list):
        return None
    return [x for x in d if isinstance(x, dict)]


def _make_lookup(root, bd):
    memo = {}

    def lookup(bead_id):
        if bead_id not in memo:
            r = bd(root, ["show", bead_id, "--json"])
            if r is None or r[0] != 0:
                memo[bead_id] = ("error", None)
            else:
                rows = _parse_list(r[1])
                if rows is None:
                    memo[bead_id] = ("error", None)
                elif not rows:
                    memo[bead_id] = ("missing", None)
                else:
                    memo[bead_id] = ("ok", rows[0])
        return memo[bead_id]

    return lookup


def _comment(ancestor):
    return ("ga-2xdj1x: tipo task -> feature. Esta bead e fatia de %s (feature), e fatia de feature "
            "nasce e fica feature: como task ela perdia a vez na fila do gate (prioridade > tipo > idade) "
            "e inflava 'tasks' no painel. Ao criar fatias: bd create --parent <pai> -t <tipo do pai>."
            % ancestor)


def _retype(root, bead_id, ancestor, bd, log):
    """Retype one bead and READ IT BACK. True only when the read-back shows feature."""
    r = bd(root, ["update", bead_id, "--type", "feature"])
    if r is None or r[0] != 0:
        log("  [%s] %s: bd update --type feature FAILED (rc=%s) — left as task" % (
            root, bead_id, "none" if r is None else r[0]))
        return False
    back = bd(root, ["show", bead_id, "--json"])
    rows = _parse_list(back[1]) if back is not None and back[0] == 0 else None
    if not rows or bead_type(rows[0]) != "feature":
        log("  [%s] %s: update returned ok but the read-back does NOT show feature — counted as failed" % (
            root, bead_id))
        return False
    c = bd(root, ["comment", bead_id, _comment(ancestor)])
    if c is None or c[0] != 0:
        log("  [%s] %s: retyped, but the explanatory comment did not land" % (root, bead_id))
    return True


def sweep(rig_roots, bd, dry_run=False, log=None, max_fixes=DEFAULT_MAX_FIXES, apply=True):
    """One pass over every store. Returns a counters dict (see the keys below). apply=False is the
    audit form: classify only, never write (independent of dry_run, which is the operator switch)."""
    log = log or (lambda m: None)
    out = {"stores": 0, "stores_unreadable": 0, "tasks": 0, "with_parent": 0, "feature": 0,
           "fixed": 0, "would_fix": 0, "write_failed": 0, "deferred": 0, "no_feature": 0,
           "unreadable": 0, "skipped_workflow": 0, "unreadable_ids": [], "feature_ids": []}
    for root in rig_roots:
        root = root.strip()
        if not root:
            continue
        out["stores"] += 1
        r = bd(root, ["list", "--status", OPEN_STATUSES, "--type", "task", "--limit", "0", "--json"])
        rows = _parse_list(r[1]) if r is not None and r[0] == 0 else None
        if rows is None:
            out["stores_unreadable"] += 1
            log("  [%s] task listing FAILED or unreadable — store skipped (counted, not 'zero tasks')" % root)
            continue
        lookup = _make_lookup(root, bd)
        for bead in rows:
            if bead_type(bead) != "task":
                continue
            out["tasks"] += 1
            if is_workflow_bead(bead):
                out["skipped_workflow"] += 1
                continue
            try:
                has_parent = parent_id(bead) is not None
            except _Unreadable:
                has_parent = True      # let ancestor_verdict report it as unreadable
            if not has_parent:
                continue
            out["with_parent"] += 1
            verdict, detail = ancestor_verdict(bead, lookup)
            bid = str(bead.get("id"))
            if verdict == NO_FEATURE:
                out["no_feature"] += 1
            elif verdict == UNREADABLE:
                out["unreadable"] += 1
                out["unreadable_ids"].append(bid)
                log("  [%s] %s: %s — left as task (unreadable, counted)" % (root, bid, detail))
            else:
                out["feature"] += 1
                out["feature_ids"].append(bid)
                if not apply:
                    continue
                if dry_run:
                    out["would_fix"] += 1
                    log("DRY_RUN: would retype %s task -> feature (slice of %s)" % (bid, detail))
                elif out["fixed"] + out["write_failed"] >= max_fixes:
                    out["deferred"] += 1
                    log("  [%s] %s: slice of %s, NOT retyped this cycle (cap of %d per cycle)" % (
                        root, bid, detail, max_fixes))
                elif _retype(root, bid, detail, bd, log):
                    out["fixed"] += 1
                    log("  [%s] %s: task -> feature (slice of %s)" % (root, bid, detail))
                else:
                    out["write_failed"] += 1
    return out


def summary_line(c):
    return ("slice-type: stores=%d (unreadable=%d) tasks=%d with_parent=%d feature_above=%d fixed=%d "
            "would_fix=%d write_failed=%d deferred=%d no_feature=%d unreadable=%d workflow_skipped=%d" % (
                c["stores"], c["stores_unreadable"], c["tasks"], c["with_parent"], c["feature"],
                c["fixed"], c["would_fix"], c["write_failed"], c["deferred"], c["no_feature"],
                c["unreadable"], c["skipped_workflow"]))


def real_bd(root, args, bd_bin=None):
    """The production adapter: (rc, stdout) or None when bd could not be run at all."""
    try:
        p = subprocess.run([bd_bin or os.environ.get("BD_BIN", "bd"), "-C", root] + list(args),
                           capture_output=True, text=True, timeout=BD_TIMEOUT)
    except Exception:
        return None
    return p.returncode, p.stdout


def _main(argv):
    if not argv or argv[0] != "--audit":
        print(__doc__)
        return 2
    roots = argv[1:] or [r for r in os.environ.get(
        "ARC_RIG_ROOTS",
        "/Users/athos/gt/.gascity-gastown-hq:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers",
    ).split(":") if r]
    c = sweep(roots, real_bd, log=lambda m: print(m), apply=False)
    print(summary_line(c))
    print("AUDIT feature_above=%d unreadable=%d stores_unreadable=%d" % (
        c["feature"], c["unreadable"], c["stores_unreadable"]))
    for bid in c["feature_ids"]:
        print("  task with a feature above: %s" % bid)
    return 0 if (c["feature"] == 0 and c["unreadable"] == 0 and c["stores_unreadable"] == 0) else 1


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
