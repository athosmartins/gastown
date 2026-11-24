#!/usr/bin/env python3
"""
child-priority-janitor.py — a slice (child bead) never waits behind its own parent:
raise the child's priority to its parent's when the child is LESS urgent (ga-p7hymz).

PROBLEM: `bd create --parent <pai>` does not inherit the parent's priority (the child gets the
default P2), and whoever slices forgets to pass `-p`. Measured 18/10: the 4 cuts of ga-w7qwl1.1
(P0) were born P2, ga-2hd02v.1.5.9 was born P1 under a P0, and 11 more open slices sat below their
parent (wa-7y34xx.5, wa-h4d019.2.2, wa-h5dd0l.2, wa-hpr4gm.4, wa-r4ehy.4, ga-c0939v.5, ...). The
Pilot orders by priority, so P0 work was dispatched as P2 while P1 backlog went first; the Mayor
bumped them by hand. Athos 18/10: "por que temos beads P2 recém-entregues se há inúmeras P1
aprovadas?".

OPERATION per sweep (MAX_PER_SWEEP cap): read every non-closed bead of each store (HQ + rig stores).
For each child whose parent is in the same listing, compute the parent's EFFECTIVE priority (the
parent may itself be raised in this very sweep, so a P0 grandparent → P2 parent → P2 child converges
in one pass) and, if the child is numerically LARGER (= less urgent), `bd update -p <parent's>`.
The raise is only ever UPWARD: a child MORE urgent than its parent (a P0 bug cut out of a P2 epic)
is deliberate and is never lowered.

The write is VERIFIED by re-reading the bead (a `bd update` can exit 0 without persisting —
ga-9tgos). Every raise stamps metadata `gc.prio_inherited` and leaves one comment, so the change
is auditable and the janitor raises a given bead AT MOST ONCE: if a human lowers it again after the
stamp, that is a decision and is respected (no flapping).

LEFT ALONE (fail-toward-KEEP; "keep" is the inert state, so an over-broad exemption only means a
bead is not raised, never a wrong raise):
  - child priority or parent priority unreadable (missing/non-integer/out of 0..4) — the third
    state is never read as "P0" or "P2"
  - parent not in the non-closed listing (closed, missing, other store) — a follow-up filed under a
    story that is already done is exactly the non-blocking debt that must stay where it is
  - child type outside {feature, bug, task, chore, epic} — step/molecule/message/marker beads
    carry their own ordering
  - child status outside {open, hooked, in_progress, blocked}
  - label `followup:nonblocking`, or a title that says "não-bloqueante"/"non-blocking" (a follow-up
    born from the gate's non-blocking findings; the issue names both forms)
  - label `priority:pinned` (generic opt-out) or an existing `gc.prio_inherited` stamp
NOTE: `gate:nonblocking-findings` is NOT an exemption — it sits on the SOURCE bead of the findings
(measured on ga-w7qwl1.1.5, a plain P0 slice), not on the follow-up.

LOCK: single instance (flock) — a detector costs poll (ga-y0g5x): overlapping runs would be the load.
KILL-SWITCH: CHILD_PRIORITY_JANITOR_ENABLED=0 → no-op. DRY_RUN: CHILD_PRIORITY_JANITOR_DRY_RUN=1 →
logs what it would do, mutates nothing (use it before the first live sweep).
SELFTEST: `python3 child-priority-janitor.py --selftest`.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")
LOCK_PATH = os.environ.get("CHILD_PRIORITY_JANITOR_LOCK", os.path.join(CITY, ".gc", "child-priority-janitor.lock"))

ENABLED = os.environ.get("CHILD_PRIORITY_JANITOR_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("CHILD_PRIORITY_JANITOR_DRY_RUN", "0") == "1"
MAX_PER_SWEEP = int(os.environ.get("CHILD_PRIORITY_JANITOR_MAX_PER_SWEEP", "15"))
BD_TIMEOUT = int(os.environ.get("CHILD_PRIORITY_JANITOR_BD_TIMEOUT", "60"))

STAMP_KEY = "gc.prio_inherited"
EXEMPT_LABELS = {"followup:nonblocking", "priority:pinned"}
# "não-bloqueante(s)" / "nao bloqueante" / "non-blocking" / "nonblocking" in the TITLE only: a
# description may mention the phrase on a perfectly ordinary slice.
EXEMPT_TITLE_RE = re.compile(r"n[ãa]o[\s-]*bloqueantes?|non[\s-]*blocking", re.I)
CHILD_TYPES = {"feature", "bug", "task", "chore", "epic"}
CHILD_STATUSES = {"open", "hooked", "in_progress", "blocked"}
MAX_DEPTH = 12  # parent-chain walk bound (also the cycle guard)

# ga-vjybz8 convention: static fallback when `gc rig list` cannot be read.
_STATIC_FALLBACK_RIG_STORES = [
    ("whatsapp_automation", "/Users/athos/gt/whatsapp_automation"),
    ("property_scrapers", "/Users/athos/gt/property_scrapers"),
]

# ── test seams (monkeypatched in --selftest) ───────────────────────────────────
_stores_fn = None    # () -> list[(name, path, suspended)] | None
_list_fn = None      # (store_path) -> list[dict] | None   (None = could not read)
_update_fn = None    # (store_path, id, prio, stamp) -> bool
_show_fn = None      # (store_path, id) -> dict | None
_comment_fn = None   # (store_path, id, text) -> bool
_notify_fn = None    # (msg, prio) -> None


def _log(msg):
    print("[child-priority] %s" % msg, flush=True)


def _sh(args, timeout):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        _log("WARN: subprocess failed: %r (%r)" % (args[:4], e))
        return None


def _notify(msg, prio=3):
    if _notify_fn is not None:
        _notify_fn(msg, prio)
        return
    if DRY_RUN:
        _log("DRY_RUN: would notify: %s" % msg)
        return
    _sh([NOTIFY_BIN, "-t", "child-priority-janitor", "-p", str(prio), msg], 15)


# ── pure planning ──────────────────────────────────────────────────────────────
def _prio(v):
    """0..4 as int, else None. A bool, a string, None or a missing key is NOT a priority:
    "unreadable" must never be mistaken for P0 (the falsy zero) or for the P2 default."""
    if isinstance(v, bool) or not isinstance(v, int):
        return None
    return v if 0 <= v <= 4 else None


def _labels(rec):
    ls = rec.get("labels")
    return set(x for x in ls if isinstance(x, str)) if isinstance(ls, list) else set()


def _stamped(rec):
    md = rec.get("metadata")
    return isinstance(md, dict) and bool(md.get(STAMP_KEY))


def skip_reason(rec):
    """Why this child is not eligible to be raised, or None when it is. Does NOT look at the
    parent. Order = cheapest/most specific first; every reason is a KEEP."""
    if rec.get("issue_type") not in CHILD_TYPES:
        return "type"
    if rec.get("status") not in CHILD_STATUSES:
        return "status"
    if _labels(rec) & EXEMPT_LABELS:
        return "exempt-label"
    if EXEMPT_TITLE_RE.search(rec.get("title") or ""):
        return "exempt-title"
    if _stamped(rec):
        return "already-raised"  # raised once; a lower value now is a human decision
    return None


def plan_raises(recs):
    """recs: the non-closed beads of ONE store. Returns (changes, stats).
    changes: [{"id","from","to","parent"}]; stats: {reason: count} for everything left alone that
    WOULD have been a candidate (child with a parent), so a sweep can say why it did nothing."""
    by_id = {}
    for r in recs:
        if isinstance(r, dict) and isinstance(r.get("id"), str):
            by_id[r["id"]] = r
    memo = {}
    stats = {}

    def bump(k):
        stats[k] = stats.get(k, 0) + 1

    def target(bid, depth, seen):
        """Priority this bead will have after the sweep (None = unreadable). Memoised;
        `seen`/`depth` stop a parent cycle or a runaway chain at the CURRENT value."""
        if bid in memo:
            return memo[bid]
        rec = by_id[bid]
        cur = _prio(rec.get("priority"))
        if cur is None:
            memo[bid] = None
            return None
        res = cur
        parent = rec.get("parent")
        if (isinstance(parent, str) and parent in by_id and parent != bid
                and parent not in seen and depth < MAX_DEPTH and skip_reason(rec) is None):
            ptarget = target(parent, depth + 1, seen | {bid})
            if ptarget is not None and ptarget < cur:
                res = ptarget
        memo[bid] = res
        return res

    changes = []
    for bid in sorted(by_id):
        rec = by_id[bid]
        parent = rec.get("parent")
        if not isinstance(parent, str) or not parent:
            continue
        cur = _prio(rec.get("priority"))
        if cur is None:
            bump("child-priority-unreadable")
            continue
        if parent not in by_id:
            bump("parent-not-open")
            continue
        why = skip_reason(rec)
        if why is not None:
            bump(why)
            continue
        # A parent whose own priority is unreadable cannot be compared with: keep, and say why.
        # (An unreadable ANCESTOR further up just stops the chain at the last readable value.)
        if _prio(by_id[parent].get("priority")) is None:
            bump("parent-priority-unreadable")
            continue
        want = target(bid, 0, frozenset())
        if want is not None and want < cur:
            changes.append({"id": bid, "from": cur, "to": want, "parent": parent})
        else:
            bump("already-ok")
    return changes, stats


# ── I/O ────────────────────────────────────────────────────────────────────────
def _parse_list(raw):
    # vazio → []  (store with nothing open); falhou/ilegível → None (caller skips the store, never
    # reads "could not tell" as "no children").
    if raw is None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    try:
        d = json.loads(raw)
    except Exception:
        return None
    return d if isinstance(d, list) else None


def _one_line(text, cap):
    """`text` on ONE line, cut to `cap` chars. A failure cause goes into the log, which is one line per event and the
    watchdog's heartbeat: a multi-line stderr would tear it, an unbounded one would drown it."""
    return " ".join(str(text or "").split())[:cap]


def _why(r, what):
    """Why a `bd` call gave no usable answer, in one line; None when it ran and exited 0. `r` is None when the process
    could not run at all (timeout, missing binary, undecodable output): _sh has already logged the exception, this
    names the call it belongs to."""
    if r is None:
        return "%s did not run (see the subprocess WARN above)" % what
    if r.returncode != 0:
        # vazio → "(empty stderr)"; falhou → the stderr text on one line, cut at 300: the cause the log used to throw away (ga-u4z4hwb)
        return "%s rc=%d: %s" % (what, r.returncode, _one_line(r.stderr, 300) or "(empty stderr)")
    return None


def _read_store(path):
    """(recs, why). recs: the store's non-closed beads ([] = a store with nothing open); None = the store could NOT be
    read, and `why` says why in one line. A failed read is never []: "could not tell" is not "no children"."""
    if _list_fn is not None:
        recs = _list_fn(path)
        return recs, (None if recs is not None else "the list seam returned None")
    r = _sh([BD_BIN, "-C", path, "list", "--limit", "0", "--json"], BD_TIMEOUT)
    why = _why(r, "bd list")
    if why is not None:
        return None, why
    # vazio (rc 0, no output) → (None, cause), NEVER []; falhou/ilegível (not JSON, or JSON that is not a list) → the same
    recs = _parse_list(r.stdout)
    if recs is None:
        return None, "bd list rc=0 but stdout is not a JSON list: %s" % (_one_line(r.stdout, 120) or "(empty)")
    return recs, None


def _show(path, bid):
    if _show_fn is not None:
        return _show_fn(path, bid)
    r = _sh([BD_BIN, "-C", path, "show", bid, "--json"], BD_TIMEOUT)
    why = _why(r, "bd show")
    if why is not None:
        _log("WARN: %s (%s)" % (why, bid))
        return None
    d = _parse_list(r.stdout)
    return d[0] if d and isinstance(d[0], dict) else None


def _update(path, bid, prio, stamp):
    if _update_fn is not None:
        return _update_fn(path, bid, prio, stamp)
    r = _sh([BD_BIN, "-C", path, "update", bid, "-p", str(prio), "--set-metadata", "%s=%s" % (STAMP_KEY, stamp)],
            BD_TIMEOUT)
    why = _why(r, "bd update")
    if why is not None:
        _log("WARN: %s (%s)" % (why, bid))
        return False
    return True


def _comment(path, bid, text):
    if _comment_fn is not None:
        return _comment_fn(path, bid, text)
    r = _sh([BD_BIN, "-C", path, "comment", bid, text], BD_TIMEOUT)
    why = _why(r, "bd comment")
    if why is not None:
        _log("WARN: %s (%s)" % (why, bid))
        return False
    return True


def _stores():
    """[(name, path, suspended)] — HQ first, then every non-HQ rig. `suspended` is True only when `gc rig list --json`
    says `"suspended": true`; a missing key or any other value is "not known to be suspended" and keeps the alarm on
    (the HQ never is). None when the live rig list could not be derived (the caller falls back to the static list and
    says so)."""
    if _stores_fn is not None:
        return _stores_fn()
    r = _sh([GC_BIN, "--city", CITY, "rig", "list", "--json"], BD_TIMEOUT)
    if r is None or r.returncode != 0:
        _log("WARN: gc rig list failed/timed out — cannot derive rig store list")
        return None
    try:
        rigs = json.loads(r.stdout).get("rigs") or []
    except Exception as e:
        _log("WARN: gc rig list parse: %r" % e)
        return None
    out = [("hq", CITY, False)]
    for rig in rigs:
        if not isinstance(rig, dict) or rig.get("hq") is True:
            continue
        p = rig.get("path")
        if p and p != CITY and os.path.isdir(p):
            # vazio (no "suspended" key) → active, the alarm stays on; ilegível (anything but the JSON boolean true) → active too
            out.append((rig.get("name") or os.path.basename(p), p, rig.get("suspended") is True))
    return out if len(out) > 1 else None


def _fmt(p):
    return "P%d" % p


def run_cycle():
    """One sweep. Returns (raised, failed, unreadable, unreadable_active): `unreadable` counts every store that could not
    be read, `unreadable_active` only those whose rig is not known to be suspended. `failed` and `unreadable_active`
    are what make the sweep fail (see main)."""
    stores = _stores()
    if stores is None:
        _log("DEGRADED stores: using HQ + static fallback (%s)" % ", ".join(n for n, _ in _STATIC_FALLBACK_RIG_STORES))
        stores = [("hq", CITY, False)] + [(n, p, False) for n, p in _STATIC_FALLBACK_RIG_STORES
                                          if os.path.isdir(p) or _list_fn is not None]
    raised = failed = unreadable = unreadable_active = 0
    capped = False
    for name, path, suspended in stores:
        recs, why = _read_store(path)
        if recs is None:
            unreadable += 1
            if suspended:
                # ga-u4z4hwb criterion: a failed read of a SUSPENDED rig is logged with its cause but is not the sweep's
                # failure. An unreadable ACTIVE rig, or the HQ, is.
                _log("WARN: bd list failed/unreadable in %s (rig SUSPENDED) — store skipped, not counted toward the exit code: %s" % (name, why))
            else:
                unreadable_active += 1
                _log("WARN: bd list failed/unreadable in %s — store skipped (NOT read as 'no children'): %s" % (name, why))
            continue
        changes, stats = plan_raises(recs)
        _log("store=%s open=%d raise=%d kept=%s" % (
            name, len(recs), len(changes), ",".join("%s:%d" % kv for kv in sorted(stats.items())) or "-"))
        for c in changes:
            if raised + failed >= MAX_PER_SWEEP:
                capped = True
                _log("(MAX_PER_SWEEP=%d reached — remaining raises deferred to next sweep)" % MAX_PER_SWEEP)
                break
            line = "%s %s: %s -> %s (pai %s)" % (name, c["id"], _fmt(c["from"]), _fmt(c["to"]), c["parent"])
            if DRY_RUN:
                _log("DRY_RUN: would raise %s" % line)
                raised += 1
                continue
            stamp = "%s->%s from %s @%s" % (_fmt(c["from"]), _fmt(c["to"]), c["parent"], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
            ok = _update(path, c["id"], c["to"], stamp)
            back = _show(path, c["id"])
            # Verify the EFFECT, not the exit code: a write can report success without persisting.
            if not ok or back is None or _prio(back.get("priority")) != c["to"]:
                _log("WARN: raise NOT confirmed on re-read — %s (update_ok=%s, reread=%s)" % (
                    line, ok, None if back is None else back.get("priority")))
                failed += 1
                continue
            raised += 1
            _log("RAISED %s" % line)
            if not _comment(path, c["id"], "child-priority-janitor (ga-p7hymz): prioridade %s -> %s, igualada à do pai %s "
                            "(a fatia não espera atrás do próprio pai). Para manter a prioridade menor de propósito: "
                            "volte o valor à mão (o janitor sobe cada bead uma vez só) ou ponha o label priority:pinned."
                            % (_fmt(c["from"]), _fmt(c["to"]), c["parent"])):
                _log("WARN: raised %s but the audit comment failed" % c["id"])
        if capped:
            break
    if capped:
        _notify("child-priority-janitor bateu o teto de %d por varredura — resta backlog, segue no próximo ciclo" % MAX_PER_SWEEP, 3)
    if failed:
        _notify("child-priority-janitor: %d subida(s) de prioridade NÃO confirmadas na releitura (ver .gc/logs/child-priority-janitor.out)" % failed, 4)
    _log("sweep done: raised=%d failed=%d unreadable_stores=%d (active=%d suspended=%d) dry_run=%s" % (
        raised, failed, unreadable, unreadable_active, unreadable - unreadable_active, DRY_RUN))
    return raised, failed, unreadable, unreadable_active


def main():
    # Log unconditionally first: daemon-presence-watchdog reads the launchd .out as the heartbeat.
    _log("start enabled=%s dry_run=%s max_per_sweep=%d" % (ENABLED, DRY_RUN, MAX_PER_SWEEP))
    if not ENABLED:
        _log("kill-switch CHILD_PRIORITY_JANITOR_ENABLED=0 — no-op")
        return 0
    try:
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        lock = open(LOCK_PATH, "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        _log("another instance holds the lock — exiting (single-instance)")
        return 0
    except OSError as e:
        _log("WARN: cannot take the lock (%r) — NOT running unguarded" % e)
        return 1
    # ga-u4z4hwb: `bd` must never start a Dolt server of its own from this job. On 23/11 (reboot, 23:43) a `bd` under
    # launchd without this variable started a local decoy Dolt for three rigs and wrote its port into their
    # dolt-server.port; it had no database and answered "database not found" to every job that read those rigs, this one
    # included. No `gc` wraps these calls to set the variable (the plist runs this script directly), so it is set here.
    # Forced, not setdefault: a 1 inherited from the environment must not win. The plist carries the same value.
    os.environ["BEADS_DOLT_AUTO_START"] = "0"
    t0 = time.time()
    _, failed, _, unreadable_active = run_cycle()
    _log("elapsed=%.1fs" % (time.time() - t0))
    # Exit 1 = the sweep did not do its whole job: a raise was not confirmed, or an ACTIVE store (the HQ included) could
    # not be read. Before ga-u4z4hwb it was `unreadable and not raised`, which let one raise in a store hide another store
    # that was never read (r1 unreadable + 1 raise in the HQ exited 0); now only SUSPENDED rigs are exempt, and they say why.
    return 1 if failed or unreadable_active else 0


# ── selftest ───────────────────────────────────────────────────────────────────
def _selftest():
    ok, bad = [0], [0]

    def check(name, cond):
        if cond:
            ok[0] += 1
            print("  ok   %s" % name)
        else:
            bad[0] += 1
            print("  FAIL %s" % name)

    def B(bid, prio, parent=None, typ="feature", status="open", labels=None, title="t", meta=None, drop_prio=False):
        r = {"id": bid, "issue_type": typ, "status": status, "labels": labels or [], "title": title}
        if not drop_prio:
            r["priority"] = prio
        if parent is not None:
            r["parent"] = parent
        if meta is not None:
            r["metadata"] = meta
        return r

    def plan(*recs):
        ch, st = plan_raises(list(recs))
        return {c["id"]: (c["from"], c["to"]) for c in ch}, st

    print("== child-priority-janitor selftest ==")
    # the filed bug: P2 slice of a P0 parent → P0
    ch, _ = plan(B("p", 0), B("c", 2, "p"))
    check("filha P2 de pai P0 -> P0", ch == {"c": (2, 0)})
    # numeric trap: P0 is falsy; a child P1 under P0 must still be raised, and a P0 child must not be touched
    ch, _ = plan(B("p", 0), B("c", 1, "p"), B("d", 0, "p"))
    check("P1 sob P0 sobe; P0 sob P0 fica", ch == {"c": (1, 0)})
    # never lower
    ch, _ = plan(B("p", 2), B("c", 0, "p"))
    check("filha MAIS urgente que o pai nunca desce", ch == {})
    ch, _ = plan(B("p", 1), B("c", 1, "p"))
    check("prioridade igual -> intacta", ch == {})
    # chain converges in ONE pass, regardless of id order
    ch, _ = plan(B("a", 0), B("m", 2, "a"), B("z", 3, "m"))
    check("avô P0 -> pai P2 -> neto P3: os dois sobem a P0 numa varredura", ch == {"m": (2, 0), "z": (3, 0)})
    ch, _ = plan(B("z", 0), B("m", 2, "z"), B("a", 3, "m"))
    check("mesma cadeia com ids em outra ordem", ch == {"m": (2, 0), "a": (3, 0)})
    ch, _ = plan(B("g", 1), B("m", 0, "g"), B("l", 3, "m"))
    check("pai MAIS urgente que o avô não é rebaixado e o neto sobe ao valor dele (P0), não ao do avô (P1)", ch == {"l": (3, 0)})
    # follow-up exemptions: label, title; they keep their value AND their kids compare against it
    ch, _ = plan(B("p", 0), B("f", 2, "p", labels=["followup:nonblocking"]))
    check("rótulo followup:nonblocking -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("f", 2, "p", title="X: achados não-bloqueantes do gate da .3"))
    check("título 'achados não-bloqueantes do gate' -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("f", 2, "p", title="non-blocking findings of slice 4"))
    check("título 'non-blocking' -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("f", 2, "p", labels=["priority:pinned"]))
    check("priority:pinned -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("f", 2, "p", labels=["gate:nonblocking-findings"]))
    check("gate:nonblocking-findings (rótulo da FONTE) NÃO isenta a fatia", ch == {"f": (2, 0)})
    ch, _ = plan(B("p", 0), B("f", 2, "p", labels=["followup:nonblocking"]), B("g", 3, "f"))
    check("neto de um follow-up isento compara com o valor REAL do follow-up (P2), não com o avô", ch == {"g": (3, 2)})
    # fail-closed on unreadable
    ch, st = plan(B("p", 0, drop_prio=True), B("c", 2, "p"))
    check("pai sem prioridade legível -> intacta", ch == {} and st.get("parent-priority-unreadable") == 1)
    ch, st = plan(B("p", 0), B("c", 2, "p", drop_prio=True))
    check("filha sem prioridade legível -> intacta (ausente não vira P0 nem P2)", ch == {} and st.get("child-priority-unreadable") == 1)
    ch, _ = plan(dict(B("p", 0), priority="0"), B("c", 2, "p"))
    check("prioridade em texto ('0') não é lida como P0", ch == {})
    ch, _ = plan(dict(B("p", 0), priority=True), B("c", 2, "p"))
    check("prioridade booleana não é lida como número", ch == {})
    ch, _ = plan(B("p", 9), B("c", 2, "p"))
    check("prioridade fora de 0..4 -> ilegível", ch == {})
    # parent not open / absent
    ch, st = plan(B("c", 2, "ghost"))
    check("pai fora da listagem (fechado/ausente) -> intacta", ch == {} and st.get("parent-not-open") == 1)
    # type / status gates
    ch, _ = plan(B("p", 0), B("s", 2, "p", typ="step"))
    check("tipo step (passo de fórmula) -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("s", 2, "p", typ="molecule"))
    check("tipo molecule -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("s", 2, "p", status="deferred"))
    check("status deferred -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("s", 2, "p", status="closed"))
    check("filha fechada -> intacta", ch == {})
    ch, _ = plan(B("p", 0), B("s", 2, "p", status="in_progress"), B("t", 2, "p", status="hooked"))
    check("in_progress e hooked sobem", ch == {"s": (2, 0), "t": (2, 0)})
    # once-only stamp
    ch, _ = plan(B("p", 0), B("c", 2, "p", meta={STAMP_KEY: "P2->P0 from p"}))
    check("já subida uma vez (carimbo) e baixada depois -> respeita a decisão", ch == {})
    ch, _ = plan(B("p", 0), B("c", 2, "p", meta={"outra": "x"}))
    check("metadata sem o carimbo não isenta", ch == {"c": (2, 0)})
    # cycles / self-parent
    ch, _ = plan(B("a", 2, "b"), B("b", 0, "a"))
    check("ciclo de pais não trava nem inventa subida infinita", isinstance(ch, dict))
    ch, _ = plan(B("a", 2, "a"))
    check("auto-pai -> intacta", ch == {})
    # junk records do not blow up
    ch, _ = plan({"id": 5}, {"nope": 1}, B("p", 0), B("c", 2, "p"))
    check("registros sem id string são ignorados", ch == {"c": (2, 0)})

    # ── end-to-end through the seams ──
    global _stores_fn, _list_fn, _update_fn, _show_fn, _comment_fn, _notify_fn, _sh, DRY_RUN, MAX_PER_SWEEP
    saved = (_stores_fn, _list_fn, _update_fn, _show_fn, _comment_fn, _notify_fn, _sh, DRY_RUN, MAX_PER_SWEEP)
    try:
        store = {"hq": [B("p", 0), B("c1", 2, "p"), B("c2", 2, "p")], "wa": [B("q", 1), B("d1", 3, "q")], "bad": None}
        writes, comments, notes = [], [], []
        persist = [True]

        def fake_update(path, bid, prio, stamp):
            writes.append((path, bid, prio, stamp))
            if persist[0]:
                for r in store[path]:
                    if r["id"] == bid:
                        r["priority"] = prio
            return True

        _stores_fn = lambda: [("hq", "hq", False), ("wa", "wa", False), ("bad", "bad", False)]
        _list_fn = lambda path: None if store[path] is None else [dict(r) for r in store[path]]
        _update_fn = fake_update
        _show_fn = lambda path, bid: next((dict(r) for r in store[path] if r["id"] == bid), None)
        _comment_fn = lambda path, bid, text: comments.append((path, bid)) or True
        _notify_fn = lambda msg, prio: notes.append((msg, prio))
        DRY_RUN = False
        MAX_PER_SWEEP = 15
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: 3 subidas em 2 lojas, loja ilegível pulada e contada", (raised, failed, unread, unread_act) == (3, 0, 1, 1))
        check("e2e: -p e carimbo gravados, 1 comentário por subida",
              sorted((w[1], w[2]) for w in writes) == [("c1", 0), ("c2", 0), ("d1", 1)]
              and all(w[3].startswith("P") and "from" in w[3] for w in writes) and len(comments) == 3)
        writes.clear(); comments.clear()
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: segunda varredura sobre o estado já corrigido não escreve nada", raised == 0 and not writes)

        # a write that exits 0 but does not persist is a FAILURE, with an alarm
        store["hq"] = [B("p", 0), B("c1", 2, "p")]
        persist[0] = False
        writes.clear(); comments.clear(); notes.clear()
        raised, failed, _, _ = run_cycle()
        check("e2e: update que não persiste -> falha contada, sem comentário, com alarme",
              (raised, failed) == (0, 1) and not comments and any(p == 4 for _, p in notes))
        persist[0] = True

        # cap
        store["hq"] = [B("p", 0)] + [B("c%d" % i, 2, "p") for i in range(5)]
        MAX_PER_SWEEP = 2
        writes.clear(); notes.clear()
        raised, failed, _, _ = run_cycle()
        check("e2e: teto por varredura respeitado e avisado", raised == 2 and len(writes) == 2 and any("teto" in m for m, _ in notes))
        MAX_PER_SWEEP = 15

        # dry run mutates nothing
        store["hq"] = [B("p", 0), B("c1", 2, "p")]
        DRY_RUN = True
        writes.clear(); comments.clear()
        raised, failed, _, _ = run_cycle()
        check("e2e: DRY_RUN conta mas não escreve", raised == 1 and not writes and not comments)
        DRY_RUN = False

        # unreadable everywhere → nothing raised, reported as unreadable (exit-1 material), never "no children"
        _stores_fn = lambda: [("bad", "bad", False)]
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: todas as lojas ilegíveis -> 0 subidas, unreadable=1 e a ativa conta", (raised, failed, unread, unread_act) == (0, 0, 1, 1))

        # ga-u4z4hwb: a SUSPENDED rig is read like any other; when it cannot be read it is logged, but only the ACTIVE ones count
        store["hq"] = [B("p", 0), B("c1", 2, "p")]
        store["wa"] = [B("q", 1), B("d1", 3, "q")]
        writes.clear()
        _stores_fn = lambda: [("hq", "hq", False), ("wa", "wa", True)]
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: rig suspensa legível é varrida e sobe como qualquer outra",
              (raised, failed, unread, unread_act) == (2, 0, 0, 0) and sorted(w[1] for w in writes) == ["c1", "d1"])
        _stores_fn = lambda: [("hq", "hq", False), ("bad", "bad", True)]
        store["hq"] = [B("p", 0), B("c1", 2, "p")]
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: rig suspensa ilegível -> contada em unreadable mas não nas ativas", (raised, failed, unread, unread_act) == (1, 0, 1, 0))
        _stores_fn = lambda: [("bad", "bad", True), ("hq", "hq", False), ("wa", "wa", True)]
        store["hq"] = [B("p", 0), B("c1", 2, "p")]
        store["wa"] = None
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: duas suspensas ilegíveis e o HQ lido -> unreadable=2, nenhuma ativa", (unread, unread_act) == (2, 0))
        _stores_fn = lambda: [("bad", "bad", False), ("hq", "hq", False)]
        store["hq"] = [B("p", 0), B("c1", 2, "p")]
        raised, failed, unread, unread_act = run_cycle()
        check("e2e: loja ativa ilegível + uma subida feita em outra -> a ativa ainda conta (nada a esconde)",
              (raised, unread, unread_act) == (1, 1, 1))
    finally:
        (_stores_fn, _list_fn, _update_fn, _show_fn, _comment_fn, _notify_fn, _sh, DRY_RUN, MAX_PER_SWEEP) = saved

    # ── the readers with a fake `bd`/`gc` process: what a failure says reaches the log (ga-u4z4hwb) ──
    import contextlib
    import io
    import tempfile
    saved_io = (_sh, _stores_fn, _list_fn, _update_fn, _show_fn, _comment_fn)
    try:
        _stores_fn = _list_fn = _update_fn = _show_fn = _comment_fn = None

        def proc(rc, out="", err=""):
            return subprocess.CompletedProcess(["bd"], rc, out, err)

        def read_with(r):
            global _sh
            _sh = lambda args, timeout: r
            return _read_store("/x")

        check("leitura: rc 0 + lista JSON -> as beads, sem causa", read_with(proc(0, '[{"id": "a"}]')) == ([{"id": "a"}], None))
        check("leitura: rc 0 + [] -> ([], None): loja sem nada aberto não é leitura que falhou", read_with(proc(0, "[]")) == ([], None))
        check("leitura: rc 1 -> None e o stderr como causa",
              read_with(proc(1, "", "Error: database not found: marketing\n")) == (None, "bd list rc=1: Error: database not found: marketing"))
        check("leitura: rc 1 com lista no stdout continua ilegível; stderr vazio é dito",
              read_with(proc(1, "[]", "")) == (None, "bd list rc=1: (empty stderr)"))
        recs, why = read_with(proc(1, "", "a\n  b\t\tc\n" + "x" * 400))
        check("leitura: a causa vem numa linha só, espremida e cortada em 300 caracteres",
              recs is None and why == "bd list rc=1: a b c " + "x" * 294)
        check("leitura: processo que não rodou -> None e 'did not run'",
              read_with(None) == (None, "bd list did not run (see the subprocess WARN above)"))
        check("leitura: rc 0 sem nenhuma saída NÃO é []", read_with(proc(0, "")) == (None, "bd list rc=0 but stdout is not a JSON list: (empty)"))
        recs, why = read_with(proc(0, "garbage{{{\n" + "y" * 200))
        check("leitura: rc 0 com lixo -> None, a cabeça do stdout (120 caracteres, uma linha) é a causa",
              recs is None and why == "bd list rc=0 but stdout is not a JSON list: garbage{{{ " + "y" * 109)
        check("leitura: rc 0 com JSON que não é lista -> None", read_with(proc(0, '{"issues": []}'))[0] is None)
        check("leitura: processo morto por sinal (rc -9) é leitura que falhou, nunca 'ok'",
              read_with(proc(-9, "[]")) == (None, "bd list rc=-9: (empty stderr)"))
        _list_fn = lambda path: None
        check("leitura: a costura de lista devolvendo None é leitura que falhou, com causa",
              _read_store("/x") == (None, "the list seam returned None"))
        # gc rig list failed (`_stores()` is None): nothing says who is suspended, so the HQ and every fallback store are ACTIVE
        _stores_fn = lambda: None
        with contextlib.redirect_stdout(io.StringIO()):
            res = run_cycle()
        n = len(_STATIC_FALLBACK_RIG_STORES) + 1
        check("degradado: sem lista de rigs, o HQ e todas as lojas de reserva ilegíveis contam como ativos", res == (0, 0, n, n))
        _stores_fn = None
        _list_fn = None

        def cause_logged(fn, r, *args):
            global _sh
            _sh = lambda a, timeout: r
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                res = fn(*args)
            return res, buf.getvalue()

        res, out = cause_logged(_update, proc(1, "", "Error: update refused"), "/x", "c1", 0, "stamp")
        check("update: rc 1 -> False e a causa vai ao log com o id da bead",
              res is False and "[child-priority] WARN: bd update rc=1: Error: update refused (c1)\n" in out)
        res, out = cause_logged(_update, proc(0), "/x", "c1", 0, "stamp")
        check("update: rc 0 -> True e nada no log", res is True and out == "")
        res, out = cause_logged(_update, None, "/x", "c1", 0, "stamp")
        check("update: processo que não rodou -> False, 'did not run' no log", res is False and "bd update did not run" in out)
        res, out = cause_logged(_show, proc(1, "", "Error: show refused"), "/x", "c1")
        check("show: rc 1 -> None e a causa vai ao log", res is None and "WARN: bd show rc=1: Error: show refused (c1)" in out)
        res, out = cause_logged(_show, proc(0, '[{"id": "c1", "priority": 0}]'), "/x", "c1")
        check("show: rc 0 + lista -> a bead, nada no log", res == {"id": "c1", "priority": 0} and out == "")
        res, out = cause_logged(_comment, proc(1, "", "Error: comment refused"), "/x", "c1", "texto")
        check("comment: rc 1 -> False e a causa vai ao log", res is False and "WARN: bd comment rc=1: Error: comment refused (c1)" in out)
        res, out = cause_logged(_comment, proc(0), "/x", "c1", "texto")
        check("comment: rc 0 -> True e nada no log", res is True and out == "")

        # `suspended` is read from `gc rig list --json` and only a real JSON true counts
        with tempfile.TemporaryDirectory(prefix="cpj-st.") as tmp:
            dirs = {n: os.path.join(tmp, n) for n in "abcde"}
            for d in dirs.values():
                os.mkdir(d)
            rig_json = json.dumps({"rigs": [
                {"name": "gascity", "hq": True, "path": CITY, "suspended": True},
                {"name": "a", "path": dirs["a"], "suspended": True},
                {"name": "b", "path": dirs["b"], "suspended": False},
                {"name": "c", "path": dirs["c"]},
                {"name": "d", "path": dirs["d"], "suspended": "true"},
                {"name": "e", "path": dirs["e"], "suspended": 1}]})
            _sh = lambda args, timeout: proc(0, rig_json)
            check("lojas: só `suspended: true` de verdade marca a rig; o HQ nunca; texto, número e chave ausente ficam ativos",
                  _stores() == [("hq", CITY, False), ("a", dirs["a"], True), ("b", dirs["b"], False),
                                ("c", dirs["c"], False), ("d", dirs["d"], False), ("e", dirs["e"], False)])

        # a whole sweep through the fake process: each store line carries its own cause and the summary splits active from suspended
        def sh_by_store(args, timeout):
            if args[2] == "hq":
                return proc(0, "[]")
            return proc(1, "", "Error: database not found: %s" % args[2])
        _sh = sh_by_store
        _stores_fn = lambda: [("hq", "hq", False), ("sus", "sus", True), ("act", "act", False)]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            res = run_cycle()
        out = buf.getvalue()
        check("varredura: ativa + suspensa ilegíveis -> (0, 0, 2, 1)", res == (0, 0, 2, 1))
        check("varredura: a linha da suspensa diz SUSPENDED, que não conta no rc, e a causa",
              "WARN: bd list failed/unreadable in sus (rig SUSPENDED) — store skipped, not counted toward the exit code: "
              "bd list rc=1: Error: database not found: sus\n" in out)
        check("varredura: a linha da ativa diz que NÃO é 'sem filhos' e traz a causa",
              "WARN: bd list failed/unreadable in act — store skipped (NOT read as 'no children'): "
              "bd list rc=1: Error: database not found: act\n" in out)
        check("varredura: o resumo separa ativas de suspensas", "unreadable_stores=2 (active=1 suspended=1) dry_run=" in out)
    finally:
        (_sh, _stores_fn, _list_fn, _update_fn, _show_fn, _comment_fn) = saved_io

    # parser three states
    check("parse: vazio -> None (não é 'sem filhos')", _parse_list("") is None and _parse_list("   ") is None)
    check("parse: lixo -> None", _parse_list("{nope") is None and _parse_list('{"a":1}') is None)
    check("parse: [] -> [] (loja sem nada aberto)", _parse_list("[]") == [])

    print("\n[child-priority selftest] %d passed, %d failed" % (ok[0], bad[0]))
    return 1 if bad[0] else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    sys.exit(main())
