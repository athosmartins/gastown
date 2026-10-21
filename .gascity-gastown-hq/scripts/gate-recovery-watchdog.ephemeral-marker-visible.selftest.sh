#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py + the marker creators — ga-oi8gb4 regression only.
#
# BUG (measured 21/10): four gate markers sat open 7-20 days (ga-wisp-9nif2, -6zysa, -1mohj, -bowuo), all
# gate-status:error, all with a CLOSED source bead and (for two) a branch already gone or merged. The Mayor
# closed them by hand. The watchdog HAS a closer for exactly this (FIX 2, requeue_error_markers →
# close:source-done) and the replay of its verdict on those markers says close:source-done for two of them —
# yet the watchdog log and gate-recovery-actions.jsonl never mention any of the four ids.
#
# ROOT: the four were born `bd create --ephemeral` (pilot-dispatcher.sh, the ga-e2n96 auto-remerge path;
# author "pilot-dispatcher(ga-e2n96-auto-remerge)", ids ga-wisp-*). bd 1.1.0 classifies an ephemeral bead as INFRA
# and hides it from `bd list` unless --include-infra is passed (ga-vm20x, Mayor 07/08: "marker ephemeral ve=0,
# identical non-ephemeral ve=1, same query"). Six of the watchdog's marker queries used `list --all` without it, so
# FIX 2 / FIX 4 / FIX 6 / FIX 7 / FIX 8 / needs-rebase never saw an ephemeral marker. FIX 8 is the dangerous one: it
# clears the gate:* labels of a source bead that "has no open marker" — and cannot see this marker.
#
# FIX: (1) the producer stops creating the marker ephemeral (same as /gate-done and the rehome janitor);
# (2) the six watchdog queries list with --include-infra --limit 0, so a marker that already exists in that shape
# is seen and goes through the SAME three-state verdict as any other (close only when the branch is verified
# merged/gone; unmerged / unknown / unresolved is never closed).
#
# These scenarios drive the real query helpers and requeue_error_markers() against a fake bd that reproduces the
# measured visibility rule (ephemeral hidden without --include-infra) and bd's silent default cut at 50 rows
# (ga-21kmp). No live Dolt, no gc. The last block is a static check of the creators.
#
# Run: bash scripts/gate-recovery-watchdog.ephemeral-marker-visible.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
ROOT="${ROOT_OVERRIDE:-$SELF_DIR/..}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" "$ROOT" <<'PY'
import importlib.util, sys, time, json, re, glob, os

spec = importlib.util.spec_from_file_location("grw", sys.argv[1])
m = importlib.util.module_from_spec(spec)
ROOT = sys.argv[2]
WD_PATH = sys.argv[1]
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def ok(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1; print("  ok: %s" % msg)
    else:
        FAIL += 1; print("  BAD: %s" % msg)

NOW = time.time()

class CP:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err

def bead(mid, status_label, ephemeral, source="ga-src", rig="gascity", branch="fix/x", created="2026-10-01T08:00:00Z",
         bstatus="open", anchor_status=None):
    # anchor 1h old, so the age gate is never what decides — only the verdict inputs are under test
    meta = {m.GRW_STATUS_ANCHOR_KEY: "%s@%d" % (anchor_status or status_label.split(":", 1)[1], NOW - 3600),
            "gate.submitted_by": "wa-worker"}
    return {"id": mid, "ephemeral": ephemeral, "status": bstatus, "created_at": created, "metadata": meta,
            "labels": ["type:quality-gate-marker", status_label, "source-bead:%s" % source,
                       "bead-rig:%s" % rig, "branch:%s" % branch]}

class Store:
    """A fake `bd list` that reproduces what was MEASURED (bd 1.1.0): an ephemeral bead is INFRA and is omitted
    unless --include-infra is passed; without --limit the result is silently cut at 50 (newest first)."""
    def __init__(self, beads):
        self.beads = beads; self.calls = []; self.listed = []
    def sh(self, args, timeout=20, stdin=None):
        args = list(args); self.calls.append(args)
        if "list" in args and "show" not in args:
            labels = [args[i + 1] for i, a in enumerate(args) if a == "-l"]
            sts = args[args.index("--status") + 1].split(",") if "--status" in args else None
            infra = "--include-infra" in args
            lim = 50
            for flag in ("--limit", "-n"):
                if flag in args:
                    lim = int(args[args.index(flag) + 1])
            rows = [b for b in self.beads
                    if (infra or not b.get("ephemeral")) and all(l in b["labels"] for l in labels)
                    and (sts is None or b["status"] in sts)]
            rows.sort(key=lambda b: b["created_at"], reverse=True)
            if lim:
                rows = rows[:lim]
            self.listed.append((args, [b["id"] for b in rows]))
            return CP(0, json.dumps(rows))
        if "comments" in args:
            return CP(0, "[]")
        return CP(0)
    def find(self, *needles):
        return [c for c in self.calls if all(n in c for n in needles)]
    def saw(self, mid):
        return any(mid in ids for _, ids in self.listed)

PATCH = ("sh", "_source_bead_state", "_branch_merged_state", "set_gate_status_py", "notify", "_recovery_ledger",
         "GRW_DRY_RUN", "GRW_ENABLED", "GRW_REQUEUE_ERROR_ENABLED", "GRW_REQUEUE_DEFERRED_ENABLED",
         "GRW_RECOVER_NEEDS_REBASE_ENABLED", "GRW_REAP_ORPHAN_ENABLED", "GRW_REAP_STALE_REVIEW_ENABLED",
         "_rig_paths")
SAVED = {k: getattr(m, k) for k in PATCH if hasattr(m, k)}
def world(st, source=(True, True, False), branch_state="merged"):
    m.sh = st.sh
    m._source_bead_state = lambda *a, **k: source
    m._branch_merged_state = lambda *a, **k: branch_state
    m._rig_paths = lambda: {}
    m.set_gate_status_py = lambda mid, s: st.calls.append(["set_gate_status", mid, s])
    st.notifies = []; st.ledger = []
    m.notify = lambda msg, prio: st.notifies.append((msg, prio))
    m._recovery_ledger = lambda ev, fields: st.ledger.append((ev, fields))
    m.GRW_DRY_RUN = False; m.GRW_ENABLED = True
    for flag in ("GRW_REQUEUE_ERROR_ENABLED", "GRW_REQUEUE_DEFERRED_ENABLED", "GRW_RECOVER_NEEDS_REBASE_ENABLED",
                 "GRW_REAP_ORPHAN_ENABLED", "GRW_REAP_STALE_REVIEW_ENABLED"):
        if hasattr(m, flag):
            setattr(m, flag, True)
def restore():
    for k, v in SAVED.items():
        setattr(m, k, v)

def ids(rows):
    return sorted(r["id"] for r in (rows or []))

# ── 1. The marker readers must SEE an ephemeral marker ──────────────────────────────────────
print("[1] every watchdog marker reader sees a ga-wisp-* (ephemeral) marker")
EPH = [bead("ga-wisp-err", "gate-status:error", True, source="ga-5c3msy", branch="fix/ga-5c3msy-token-meter"),
       bead("ga-wisp-dfr", "gate-status:deferred", True, source="ga-dfr"),
       bead("ga-wisp-nrb", "gate-status:needs-rebase", True, source="wa-nrb", rig="whatsapp_automation"),
       bead("ga-wisp-que", "gate-status:queued", True, source="wa-bnoifn.1", rig="whatsapp_automation",
            created="2026-10-13T13:21:15Z"),
       bead("ga-plain-err", "gate-status:error", False, source="ga-plain")]
st = Store(EPH)
world(st)
try:
    ok("ga-wisp-err" in ids(m._open_error_markers()), "FIX 2  _open_error_markers sees the ephemeral error marker")
    ok("ga-plain-err" in ids(m._open_error_markers()), "FIX 2  …and still sees the ordinary one (control)")
    ok("ga-wisp-dfr" in ids(m._open_deferred_markers()), "FIX 7  _open_deferred_markers sees the ephemeral deferred marker")
    ok("ga-wisp-nrb" in ids(m._open_needs_rebase_markers()), "FIX 9  _open_needs_rebase_markers sees the ephemeral needs-rebase marker")
    srcs = m._open_quality_gate_marker_sources()
    ok(srcs is not None and "wa-bnoifn.1" in srcs,
       "FIX 8  _open_quality_gate_marker_sources lists the ephemeral marker's source — else FIX 8 clears gate:* labels "
       "of a bead whose marker is open")
    for fn_name, call in (("FIX 4  reap_orphan_and_stale_markers", lambda: m.reap_orphan_and_stale_markers(NOW)),
                          ("FIX 6  reap_stale_review_markers", lambda: m.reap_stale_review_markers(NOW, m.RecoveryState(), []))):
        st.listed.clear()
        try:
            call()
        except Exception as e:                      # what happens AFTER the read is not under test here
            print("      (note: %s raised %r after its query — irrelevant to what it could see)" % (fn_name.split()[2], e))
        ok(st.saw("ga-wisp-que"), "%s: its query returns the ephemeral queued marker" % fn_name)
finally:
    restore()

print("[1b] default 50-row cut: an old ephemeral marker is not lost behind newer ones")
many = [bead("ga-new%02d" % i, "gate-status:error", False, created="2026-10-20T10:%02d:00Z" % i) for i in range(60)]
old = bead("ga-wisp-old", "gate-status:error", True, created="2026-10-01T04:54:42Z")
st = Store(many + [old]); world(st)
try:
    got = ids(m._open_error_markers())
    ok(len(got) == 61 and "ga-wisp-old" in got, "FIX 2  61 open error markers → all 61 read (got %d)" % len(got))
finally:
    restore()

# ── 2. A phantom that is VERIFIED gone/merged is closed; anything else is not ──────────────────
print("[2] requeue_error_markers: the closer reaches an ephemeral marker, and keeps its three-state verdict")
def closes(st):
    return [c for c in st.calls if "close" in c and "bd" in c[:1]]
def requeued(st):
    return (any(c[:1] == ["set_gate_status"] and c[2] == "queued" for c in st.calls)
            or bool(st.find("label", "add", "gate-status:queued")))

for name, branch_state in (("merged", "merged"), ("deleted from origin", "missing")):
    st = Store([bead("ga-wisp-1mohj", "gate-status:error", True, source="ga-5c3msy",
                     branch="fix/ga-5c3msy-token-meter")])
    world(st, source=(True, True, False), branch_state=branch_state)
    try:
        m.requeue_error_markers(NOW, m.RecoveryState())
    finally:
        restore()
    cl = closes(st)
    ok(len(cl) == 1 and "ga-wisp-1mohj" in cl[0], "2a source closed + branch %s → the ephemeral marker is CLOSED" % name)
    ok(cl and any("VERIFIED" in str(a) for a in cl[0]), "2a …and the close reason says the merge/absence was verified")
    ok(any(ev == "closed_done_marker" for ev, _ in st.ledger), "2a …and the action is written to the recovery ledger")
    ok(not requeued(st), "2a …and it is not requeued")

for label, source, branch_state in (
        ("source closed but branch UNMERGED (the ga-wisp-6zysa shape: a stranded fix is not 'done')", (True, True, False), "unmerged"),
        ("source closed but branch state UNKNOWN (fetch failed)", (True, True, False), "unknown"),
        ("source bead could not be resolved (rig store unreadable)", (False, False, False), "unknown"),
        ("source still OPEN, branch merged", (True, False, False), "merged")):
    st = Store([bead("ga-wisp-x", "gate-status:error", True)])
    world(st, source=source, branch_state=branch_state)
    try:
        m.requeue_error_markers(NOW, m.RecoveryState())
    finally:
        restore()
    ok(not closes(st), "2b NOT closed: %s" % label)

st = Store([bead("ga-wisp-1mohj", "gate-status:error", True)])
world(st, source=(True, True, False), branch_state="merged")
m.GRW_DRY_RUN = True
try:
    m.requeue_error_markers(NOW, m.RecoveryState())
finally:
    restore()
ok(not closes(st) and any(ev == "would_close_done_marker" for ev, _ in st.ledger),
   "2c DRY-RUN: reports it would close, closes nothing")

# ── 3. Static: no marker list in the watchdog may be blind to ephemeral beads ────────────────────
print("[3] static: every watchdog `list` of type:quality-gate-marker carries --include-infra and --limit 0")
src = open(WD_PATH, encoding="utf-8", errors="replace").read()
flags = re.search(r'^MARKER_LIST_FLAGS\s*=\s*\[(.*?)\]', src, re.S | re.M)
flags_txt = flags.group(1) if flags else ""
if flags:
    ok('"--include-infra"' in flags_txt and '"--limit"' in flags_txt and '"0"' in flags_txt,
       "MARKER_LIST_FLAGS carries --include-infra and --limit 0")
# (?!\bsh\() keeps one match from swallowing the next call: a span runs from ONE sh([ to ITS closing ], timeout=N)
calls = [c for c in re.findall(r'\bsh\(\[((?:(?!\bsh\().)*?)\],\s*timeout=\d+\)', src, re.S)
         if '"list"' in c and 'type:quality-gate-marker' in c]
ok(len(calls) == 7, "found the 7 marker list calls to check (found %d; a regex that matches nothing proves nothing, "
                    "and a new query must be added to this count on purpose)" % len(calls))
for c in calls:
    head = re.sub(r"\s+", " ", c)[:120]
    infra = '"--include-infra"' in c or "MARKER_LIST_FLAGS" in c
    lim = '"--limit"' in c or '"-n"' in c or "MARKER_LIST_FLAGS" in c
    ok(infra and lim, "list carries --include-infra and --limit: %s…" % head)

# ── 4. Static: nothing creates a gate marker with --ephemeral ───────────────────────────────────
print("[4] static: no creator may birth a type:quality-gate-marker bead with --ephemeral")
files = []
for pat in ("packs/town-deltas/assets/*.sh", "scripts/*.sh", "scripts/*.py"):
    files += [p for p in glob.glob(os.path.join(ROOT, pat))
              if ".selftest." not in os.path.basename(p) and not os.path.basename(p).endswith("selftest.sh")]
ok(len(files) > 50, "scanned the creator sources (%d files)" % len(files))
offenders = []
for p in sorted(files):
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        continue
    for i, ln in enumerate(lines):
        if not re.search(r'-l\s+["\']?type:quality-gate-marker', ln) or ln.lstrip().startswith("#"):
            continue
        start = None
        for j in range(i, max(-1, i - 9), -1):
            if re.search(r'\bcreate\b', lines[j]) and not lines[j].lstrip().startswith("#"):
                start = j; break
        if start is None:
            continue
        span = [l for l in lines[start:i + 12] if not l.lstrip().startswith("#")]
        if any("--ephemeral" in l for l in span):
            offenders.append("%s:%d" % (os.path.relpath(p, ROOT), start + 1))
ok(not offenders, "no marker creator passes --ephemeral (bd 1.1.0 hides ephemeral = INFRA from `bd list`)%s"
   % ("" if not offenders else " — OFFENDERS: " + ", ".join(offenders)))

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
