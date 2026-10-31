#!/usr/bin/env python3
"""
child-cycle-labels-sweep.py — ONE-SHOT sweep: strip the FALSE "already done" labels a slice was born with
because `bd create --parent` copied them from its parent (ga-y5z6hzh).

PROBLEM: `bd create --parent <pai>` copies the parent's labels onto the new child. When the parent is closed
the child is born gate:passed / story:done and the Pilot skips it as finished, in silence (wa-93uf5c.4/.5,
wa-zmxywv.30.1, wa-xmpoab.2.1, ga-2hd02v.3.x, ga-p7hymz.1). The ROOT fix is in bd itself
(docs/pending-engine-window/ga-y5z6hzh-*: stop copying cycle labels) and waits for an engine window; this
tool cleans up what was already born wrong, and is the detector to re-run until that fix is live.

WHAT IT STRIPS (and only this): a label that CLAIMS the work is finished (DONE_CLAIM_*: gate:passed,
story:done, gate-approved:<sha>, delivery:tested, ...) on an OPEN child, when ALL of this holds:
  1. the child is open and was created within --days (default 14);
  2. a parent-child edge points at a parent that carries the SAME label today;
  3. the child's event log shows the label added exactly once, within BIRTH_WINDOW_S of the child's own
     creation (born with it), and never removed — a label somebody removed and put back is a decision;
  4. the gate never reviewed the child: no `source-bead:<child>` marker label exists (in the child's store
     or in HQ). A child the gate DID review may have earned its gate:passed.
  5. nobody removed a label from the child by hand in the last 6 h (a bead somebody is curating is theirs).
Anything else that is a never-inherit label on a child (exec:manual, pilot:*, next-action:*, story:in-flight,
blocked:*, counters...) is only REPORTED: removing a hold or a park label RELEASES work, which is not the
inert direction (a human or the Mayor decides), and `pilot:no-auto-dispatch` is the town's creation default.

DEFAULT IS DRY-RUN. `--apply` removes (one label per `bd label remove` — multi-arg is a silent no-op),
re-reads the store to CONFIRM each removal (a `bd` write can exit 0 without persisting), and leaves one
comment on the child. At most --max removals per run. Single instance (flock): a detector costs poll
(ga-y0g5x).

READ FAILURES ARE NOT EMPTY (E12): a store whose query fails/garbles is reported UNREADABLE and exit code 2 —
never "no candidates". An unreadable marker lookup downgrades every strip in that store to report-only.

POLICY MIRROR: NON_INHERITABLE_* below must equal internal/types/label_inherit.go in the bd patch; the
selftest compares the two so they cannot drift.

USAGE:
  python3 child-cycle-labels-sweep.py                  # dry-run, every rig from `gc rig list`
  python3 child-cycle-labels-sweep.py --path DIR ...   # only these stores (HQ is always used for markers)
  python3 child-cycle-labels-sweep.py --apply --max 25
  python3 child-cycle-labels-sweep.py --json
EXIT: 0 ran, all stores readable and every removal confirmed · 2 a store/lookup was unreadable (nothing applied
there) or a removal failed/was not confirmed · 3 bad usage
KILL-SWITCH: CHILD_CYCLE_LABELS_SWEEP_ENABLED=0 → no-op (exit 0).
"""
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
BD_BIN = os.environ.get("BD_BIN", "bd")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_TIMEOUT = int(os.environ.get("CHILD_CYCLE_LABELS_SWEEP_BD_TIMEOUT", "90"))
LOCK_PATH = os.environ.get("CHILD_CYCLE_LABELS_SWEEP_LOCK", os.path.join(CITY, ".gc", "child-cycle-labels-sweep.lock"))
ENABLED = os.environ.get("CHILD_CYCLE_LABELS_SWEEP_ENABLED", "1") == "1"

DEFAULT_DAYS = 14
DEFAULT_MAX = 25
# A label added within this many seconds of the child's creation was born with it. The events of one
# create share the child's own timestamp (measured on ga-2hd02v.3.24: all six label_added events carry the
# `created` second); the margin covers the clock reading of a slow transaction.
BIRTH_WINDOW_S = 10
CHUNK = 50
# A child whose labels somebody removed by hand within this window is being curated right now: leave it to them
# (the dry-run is a snapshot: a bead may be edited by hand before --apply gets to it).
CURATED_WINDOW_S = 6 * 3600
# ids and labels are interpolated into SQL (bd sql has no bind parameters): anything outside this alphabet
# is refused rather than escaped.
# fullmatch, not ^...$: "$" also matches just before a trailing newline, which would let "ga-1\n" through.
SAFE_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9:._@+=/-]*")

# ── policy mirror of internal/types/label_inherit.go (bd patch ga-y5z6hzh) ──────────────────────────────
NON_INHERITABLE_PREFIXES = (
    "gate:", "gate-", "pilot:", "pool:", "lifecycle:", "delivery:", "next-action:",
    "blocked:", "blocked-", "audit:", "auto-refino:", "refino:", "impacto:",
)
NON_INHERITABLE_EXACT = frozenset({
    "exec:manual", "needs-human", "needs-human-decision", "ctx:thin", "scope:needs-review",
})
STORY_NAMESPACE = "story:"
STORY_INHERITABLE = frozenset({
    "story:approved", "story:unrefined", "story:needs-refino", "story:needs-device",
})

# ── what is safe to strip: labels that CLAIM completion ──────────────────────────────────────────────────
DONE_CLAIM_EXACT = frozenset({
    "gate:passed", "gate:nonblocking-findings", "story:done", "story:gate",
    "audit:passed", "audit:passed-minor",
    "delivery:tested", "delivery:done", "delivery:daemon-unverified",
    "delivery:daemon-stale-closure-only", "delivery:untracked",
})
DONE_CLAIM_PREFIXES = ("gate-approved:",)


def is_inheritable(label):
    if label in NON_INHERITABLE_EXACT:
        return False
    if label.startswith(STORY_NAMESPACE):
        return label in STORY_INHERITABLE
    return not any(label.startswith(p) for p in NON_INHERITABLE_PREFIXES)


def is_done_claim(label):
    return label in DONE_CLAIM_EXACT or any(label.startswith(p) for p in DONE_CLAIM_PREFIXES)


class Unreadable(Exception):
    """A read that could not answer. Distinct from an answer of 'nothing': callers must not conflate them."""


def _run(args, timeout=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout or BD_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Unreadable("%s: %s" % (args[0], e))
    return p.returncode, p.stdout, p.stderr


def sql(store, query):
    # vazio → []; falhou/ilegível (rc≠0, saída que não é lista JSON, timeout) → Unreadable, nunca []
    rc, out, err = _run([BD_BIN, "-C", store, "sql", "--json", query])
    if rc != 0:
        raise Unreadable("bd sql rc=%s in %s: %s" % (rc, store, (err or out).strip()[:200]))
    try:
        rows = json.loads(out)
    except ValueError:
        raise Unreadable("bd sql returned non-JSON in %s: %r" % (store, out[:120]))
    if not isinstance(rows, list):
        raise Unreadable("bd sql returned a non-list in %s: %r" % (store, out[:120]))
    return rows


def _quote(token):
    if not isinstance(token, str) or not SAFE_TOKEN.fullmatch(token):
        raise Unreadable("refusing to interpolate unsafe token %r" % (token,))
    return "'" + token + "'"


def _chunks(items, n):
    items = list(items)
    for i in range(0, len(items), n):
        yield items[i:i + n]


def list_stores():
    # vazio → Unreadable (a city always has at least HQ); falhou/ilegível → Unreadable
    rc, out, err = _run([GC_BIN, "rig", "list", "--json"], timeout=120)
    if rc != 0:
        raise Unreadable("gc rig list rc=%s: %s" % (rc, err.strip()[:200]))
    try:
        rigs = json.loads(out).get("rigs") or []
    except (ValueError, AttributeError):
        raise Unreadable("gc rig list returned unreadable JSON: %r" % out[:120])
    paths = [r.get("path") for r in rigs if isinstance(r, dict) and r.get("path")]
    if not paths:
        raise Unreadable("gc rig list returned no rigs")
    return paths


def child_edges(store, days):
    """[(child, parent, status)] for NOT-closed children created within `days` that have a parent-child edge.

    Kept to ONE join on the small dependency table: the 4-way join over labels (measured on the live hq store,
    31/10) blew the driver's ~14 s read timeout, and a detector must be cheap (ga-y0g5x). Edges whose parent is
    not an issue row (wisp/external: depends_on_issue_id is NULL) are not slices of a durable parent and are
    skipped."""
    # vazio → no recent slice in this store; falhou/ilegível → Unreadable
    rows = sql(store, (
        "SELECT d.issue_id AS child, d.depends_on_issue_id AS parent, c.status AS status "
        "FROM dependencies d JOIN issues c ON c.id = d.issue_id "
        "WHERE d.type = 'parent-child' AND c.status <> 'closed' "
        "AND c.created_at >= DATE_SUB(NOW(), INTERVAL %d DAY)" % int(days)
    ))
    return [(r["child"], r["parent"], r.get("status")) for r in rows if r.get("child") and r.get("parent")]


def labels_by_issue(store, ids):
    """{issue_id: set(labels)}; an issue with no label rows is simply absent (use .get(id, set()))."""
    out = {}
    for chunk in _chunks(sorted(ids), CHUNK):
        in_list = ",".join(_quote(i) for i in chunk)
        # vazio → none of these issues carries a label; falhou/ilegível → Unreadable (never "no labels")
        for r in sql(store, "SELECT issue_id, label FROM labels WHERE issue_id IN (%s)" % in_list):
            out.setdefault(r["issue_id"], set()).add(r["label"])
    return out


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def birth_evidence(store, children):
    """-> ({(child, label): (added_deltas, removed_count)}, {child: epoch of its latest label removal}).
    deltas = seconds after creation (None when either timestamp could not be read: such an event never proves
    "born with"). A removal whose time could not be read is stamped NOW: unknown is treated as "just curated"."""
    ev, last_removed = {}, {}
    for chunk in _chunks(sorted(children), CHUNK):
        in_list = ",".join(_quote(c) for c in chunk)
        # vazio → none of these children exist (so nothing is proven born-with); falhou/ilegível → Unreadable
        created = {r["id"]: _num(r.get("ts")) for r in sql(
            store, "SELECT id, UNIX_TIMESTAMP(created_at) AS ts FROM issues WHERE id IN (%s)" % in_list)}
        # vazio → the children have no label events (so nothing is proven born-with); falhou/ilegível → Unreadable
        rows = sql(store, (
            "SELECT issue_id AS child, event_type AS ev, comment, UNIX_TIMESTAMP(created_at) AS ts "
            "FROM events WHERE issue_id IN (%s) AND event_type IN ('label_added', 'label_removed')" % in_list
        ))
        for r in rows:
            comment = r.get("comment") or ""
            child, ts, t0 = r["child"], _num(r.get("ts")), created.get(r["child"])
            if r.get("ev") == "label_added" and comment.startswith("Added label: "):
                label = comment[len("Added label: "):]
                dt = int(round(ts - t0)) if ts is not None and t0 is not None else None
                ev.setdefault((child, label), ([], 0))[0].append(dt)
            elif r.get("ev") == "label_removed" and comment.startswith("Removed label: "):
                label = comment[len("Removed label: "):]
                added, removed = ev.get((child, label), ([], 0))
                ev[(child, label)] = (added, removed + 1)
                last_removed[child] = max(last_removed.get(child, 0.0), ts if ts is not None else time.time())
    return ev, last_removed


def gate_seen(store, children):
    """Children the gate has a marker for: `source-bead:<child>` exists in `store`."""
    seen = set()
    for chunk in _chunks(sorted(children), CHUNK):
        tokens = ",".join(_quote("source-bead:" + c) for c in chunk)
        # vazio → the gate never reviewed these children; falhou/ilegível → Unreadable (never "not seen")
        for r in sql(store, "SELECT DISTINCT label FROM labels WHERE label IN (%s)" % tokens):
            seen.add(str(r.get("label", ""))[len("source-bead:"):])
    return seen


def born_with(evidence, child, label):
    added, removed = evidence.get((child, label), ([], 0))
    if removed or len(added) != 1:
        return False
    dt = added[0]
    return isinstance(dt, int) and -2 <= dt <= BIRTH_WINDOW_S


def analyze_store(store, days, hq):
    """-> (items, notes). Raises Unreadable if the store itself cannot be read."""
    items, notes = [], []
    edges = child_edges(store, days)
    if not edges:
        return items, notes
    labels = labels_by_issue(store, {c for c, _, _ in edges} | {p for _, p, _ in edges})
    cand = []
    for child, parent, status in edges:
        # the label must be on the child AND on its parent today (copied, not merely similar)
        for label in sorted(labels.get(child, set()) & labels.get(parent, set())):
            if not is_inheritable(label):
                cand.append({"child": child, "parent": parent, "status": status, "label": label})
    if not cand:
        return items, notes
    children = {r["child"] for r in cand}
    evidence, last_removed = birth_evidence(store, children)
    now = time.time()
    marker_ok, seen = True, set()
    try:
        seen = gate_seen(store, children)
        if hq and os.path.realpath(hq) != os.path.realpath(store):
            seen |= gate_seen(hq, children)
    except Unreadable as e:
        marker_ok = False
        notes.append("marker lookup unreadable (%s): every strip in this store downgraded to report-only" % e)
    for r in cand:
        child, label = r["child"], r["label"]
        claim = is_done_claim(label)
        why = []
        if not claim:
            why.append("not a completion claim: removing it could release work")
        if not born_with(evidence, child, label):
            why.append("not proven born-with (added late, more than once, or removed since)")
        if child in last_removed and now - last_removed[child] <= CURATED_WINDOW_S:
            why.append("labels of this child were hand-edited in the last %dh (someone is on it)" % (CURATED_WINDOW_S // 3600))
        if not marker_ok:
            why.append("gate marker lookup unreadable")
        elif child in seen:
            why.append("the gate reviewed this child (source-bead marker exists)")
        items.append({
            "store": store, "child": child, "parent": r.get("parent"), "status": r.get("status"),
            "label": label, "class": "done-claim" if claim else "state",
            "action": "strip" if not why else "report", "why": why,
        })
    return items, notes


def apply_strip(item):
    """Remove one label, CONFIRM it is gone, leave an audit comment. -> (ok, message)"""
    store, child, label = item["store"], item["child"], item["label"]
    try:
        # an id/label outside the safe alphabet raises Unreadable here, BEFORE any write: nothing is removed
        probe = "SELECT 1 AS n FROM labels WHERE issue_id = %s AND label = %s" % (_quote(child), _quote(label))
        # vazio → somebody removed it since the analysis (leave the bead alone: no remove, no "removed" comment);
        # falhou/ilegível → do NOT write blind
        if not sql(store, probe):
            return True, "already gone (removed by someone else since the analysis); nothing done"
    except Unreadable as e:
        return False, "pre-check unreadable, nothing removed (%s)" % e
    rc, out, err = _run([BD_BIN, "-C", store, "label", "remove", child, label])
    if rc != 0:
        return False, "label remove rc=%s: %s" % (rc, (err or out).strip()[:160])
    try:
        # vazio → the label is gone (the write persisted); falhou/ilegível → NOT confirmed
        still = sql(store, probe)
    except Unreadable as e:
        return False, "removal not confirmed (re-read failed: %s)" % e
    if still:
        return False, "bd exited 0 but the label is still there"
    note = ("child-cycle-labels-sweep (ga-y5z6hzh): removed %s — copied from parent %s at creation by "
            "`bd create --parent` (label_added within %ds of the child's creation, never removed, no gate marker "
            "for this child). Re-add it by hand if the claim was true." % (label, item["parent"], BIRTH_WINDOW_S))
    crc, _, cerr = _run([BD_BIN, "-C", store, "comment", child, note])
    return True, "removed" + ("" if crc == 0 else " (comment failed rc=%s)" % crc)


def render(items, unreadable, notes, applied):
    out = []
    strips = [i for i in items if i["action"] == "strip"]
    reports = [i for i in items if i["action"] == "report"]
    out.append("child-cycle-labels-sweep: %d strip candidate(s), %d report-only, %d unreadable store(s)" %
               (len(strips), len(reports), len(unreadable)))
    for title, group in (("STRIP (false completion claim, born with the child)", strips),
                         ("REPORT-ONLY (needs a human decision or lacks proof)", reports)):
        if not group:
            continue
        out.append("")
        out.append("## " + title)
        for i in sorted(group, key=lambda x: (x["store"], x["child"], x["label"])):
            res = applied.get((i["child"], i["label"]))
            extra = ("  -> " + res) if res else ""
            why = ("  [" + "; ".join(i["why"]) + "]") if i["why"] else ""
            out.append("- %s  %s  (parent %s, %s)  %s%s%s" % (
                os.path.basename(i["store"].rstrip("/")), i["child"], i["parent"], i["status"], i["label"], why, extra))
    for store, msg in unreadable:
        out.append("")
        out.append("UNREADABLE %s: %s" % (store, msg))
    for n in notes:
        out.append("NOTE: " + n)
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(description="Strip false completion labels copied onto new slices by bd create --parent")
    ap.add_argument("--path", action="append", default=[], help="store (rig) path; repeatable. Default: every rig of the city")
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS)
    ap.add_argument("--max", type=int, default=DEFAULT_MAX, help="max removals per run (--apply)")
    ap.add_argument("--apply", action="store_true", help="actually remove (default is a dry-run)")
    ap.add_argument("--json", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 3 if e.code else 0
    if args.days < 1 or args.max < 0:
        print("--days must be >= 1 and --max >= 0", file=sys.stderr)
        return 3
    if not ENABLED:
        print("child-cycle-labels-sweep: disabled (CHILD_CYCLE_LABELS_SWEEP_ENABLED=0)")
        return 0

    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    lock = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("child-cycle-labels-sweep: another instance holds the lock; nothing done")
        return 0

    unreadable, notes, items = [], [], []
    try:
        stores = args.path or list_stores()
    except Unreadable as e:
        print("child-cycle-labels-sweep: cannot list stores: %s" % e, file=sys.stderr)
        return 2
    for store in stores:
        try:
            got, n = analyze_store(store, args.days, CITY)
            items.extend(got)
            notes.extend(n)
        except Unreadable as e:
            unreadable.append((store, str(e)))

    applied = {}
    if args.apply:
        done = 0
        for i in [x for x in items if x["action"] == "strip"]:
            if done >= args.max:
                applied[(i["child"], i["label"])] = "skipped (--max %d reached)" % args.max
                continue
            ok, msg = apply_strip(i)
            applied[(i["child"], i["label"])] = ("OK " if ok else "FAILED ") + msg
            done += 1 if (ok and msg.startswith("removed")) else 0
            if not ok:
                notes.append("%s %s: %s" % (i["child"], i["label"], msg))

    if args.json:
        print(json.dumps({"items": items, "unreadable": unreadable, "notes": notes,
                          "applied": {"%s|%s" % k: v for k, v in applied.items()}}, indent=2))
    else:
        print(render(items, unreadable, notes, applied))
    failed_apply = any(v.startswith("FAILED") for v in applied.values())
    return 2 if (unreadable or failed_apply or any("unreadable" in n for n in notes)) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
