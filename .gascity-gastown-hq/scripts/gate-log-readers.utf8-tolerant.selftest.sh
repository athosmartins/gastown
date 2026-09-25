#!/usr/bin/env bash
# Selftest for the three OTHER dispatcher-log readers fixed by ga-b1iulk (the fourth reader,
# gate-recovery-watchdog.py, has its own: gate-recovery-watchdog.utf8-tolerant-readers.selftest.sh).
#
# BUG: production-stall-watchdog.py and pipeline-throughput-heartbeat.py read the dispatcher log through
# a tail_lines() that did `open(path).readlines()[-n:]` under `except Exception: return []`, and
# gate-health-monitor.py's _count_async_start_races() did the same with `return 0`. open() decodes UTF-8
# strictly and readlines() reads the whole 25MB file, so ONE invalid byte anywhere (11 lines since
# 2026-09-15: reviewer output cut mid-multibyte-character) raised, and the callers took the empty answer for
# "nothing to see": merge_stall() / gate_merge_stall() / durable_landing_fail() returned None ("no stall",
# "all fine") and the race counter returned 0, on every poll, for ~10 days. On the live log tail_lines()
# handed those readers 0 lines instead of 2000 / 800.
#
# One case per fixed site, each on a log of the REAL shape (invalid bytes at the head of the file AND inside
# the window), each a POSITIVE fixture — one that alarms on a readable log — so a blind reader cannot pass by
# returning the same None a healthy gate would. Line formats are verbatim from the live log (25/09/2026)
# except the two labelled SYNTHETIC (the live log has no Durable-landing FAILED and no stale_async_start race
# line right now). Timestamps are generated relative to now: every detector here is time-windowed.
#
# Run: bash scripts/gate-log-readers.utf8-tolerant.selftest.sh
#      SCRIPTS_OVERRIDE_DIR=<dir holding OLD copies of the three scripts> bash ...   (prove it fails on older code)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPTS_OVERRIDE_DIR:-$SELF_DIR}"
for f in production-stall-watchdog.py pipeline-throughput-heartbeat.py gate-health-monitor.py; do
  [ -f "$SRC_DIR/$f" ] || { echo "FATAL: $f not found in $SRC_DIR"; exit 1; }
done

python3 - "$SRC_DIR" "$SELF_DIR" <<'PY'
import atexit, importlib.util, os, shutil, subprocess, sys, tempfile, time

src_dir, scripts_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)          # sibling modules (quiet_hours, bead_state, …) resolve even for an override dir

for k in list(os.environ):               # hermetic: no stray threshold overrides
    if k.startswith(("PROD_STALL_", "GRW_", "GATE_REVIEWER_RACE")):
        del os.environ[k]

def load(fname):
    spec = importlib.util.spec_from_file_location(fname.replace("-", "_").replace(".py", ""), os.path.join(src_dir, fname))
    mod = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = [fname]                   # __name__ != "__main__" → nothing runs
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = saved
    return mod

TMP = tempfile.mkdtemp(prefix="glr-utf8-")
atexit.register(shutil.rmtree, TMP, ignore_errors=True)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

NOW = time.time()
def fmt(t): return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
def dl(t, body): return ("[%s] [quality-gate-dispatcher] %s" % (fmt(t), body)).encode("utf-8")
TRUNC = b"\xe2\x80"                                     # an em dash (e2 80 94) cut after 2 bytes
BAD_LINE = dl(NOW - 3000, "  FAIL forensics reviewer 1 bead=ga-64qhxs tail=abc") + TRUNC
NOISE = dl(NOW - 2500, "✓ Added label 'gate:rebase-fail-count:3' to ga-g5s956")

def real_shape(tail):
    """Invalid bytes at the HEAD (outside every window) and INSIDE the last 800 lines, then `tail`.
    2800+ lines in all, so the largest window under test (2000) is completely filled."""
    return [BAD_LINE] + [NOISE] * 2500 + [BAD_LINE] + [NOISE] * 300 + tail

def mklog(name, chunks):
    p = os.path.join(TMP, name)
    with open(p, "wb") as f:
        f.write(b"\n".join(chunks) + b"\n")
    return p

def strict_fails(path):
    try:
        with open(path) as f:
            f.readlines()
        return False
    except UnicodeDecodeError:
        return True

class Patch(object):
    def __init__(self, obj, **kw): self.obj, self.kw = obj, kw
    def __enter__(self):
        self.old = dict((k, getattr(self.obj, k)) for k in self.kw)
        for k, v in self.kw.items(): setattr(self.obj, k, v)
    def __exit__(self, *a):
        for k, v in self.old.items(): setattr(self.obj, k, v)

QUEUED = dl(NOW - 60, "Found 32 queued marker(s)")     # verbatim format

# ── production-stall-watchdog.py ────────────────────────────────────────────
print("Scenario 1: production-stall-watchdog.py — tail_lines() and merge_stall()")
ps = load("production-stall-watchdog.py")
p = mklog("ps.log", real_shape([QUEUED]))
check(strict_fails(p), "fixture really is invalid UTF-8 under a strict read (the precondition of the bug)")
got = ps.tail_lines(p, 2000)
check(len(got) == 2000, "tail_lines() hands the reader its 2000 lines (got %d; the strict read handed it 0)" % len(got))
with Patch(ps, DISPATCH_LOG=p, sh=lambda args, timeout=20, stdin=None: subprocess.CompletedProcess(args, 0, stdout="[]", stderr="")):
    reason = ps.merge_stall(NOW)
check(isinstance(reason, str) and "Gate sem merge" in reason and "32 marker(s)" in reason,
      "merge_stall() alarms on 32 queued markers and no merge in the tail (got %r; the strict read gave None = 'no stall')" % (reason,))

# ── pipeline-throughput-heartbeat.py ────────────────────────────────────────
print("Scenario 2: pipeline-throughput-heartbeat.py — tail_lines(), gate_merge_stall(), durable_landing_fail()")
hb = load("pipeline-throughput-heartbeat.py")
p = mklog("hb.log", real_shape([QUEUED]))
got = hb.tail_lines(p, 800)
check(len(got) == 800, "tail_lines() hands the reader its 800 lines (got %d; the strict read handed it 0)" % len(got))
with Patch(hb, DISPATCH_LOG=p):
    stall = hb.gate_merge_stall(NOW)
check(isinstance(stall, str) and "32 marker(s) na fila" in stall,
      "gate_merge_stall() alarms on 32 queued markers, zero merges, nothing in flight (got %r; the strict read gave None)" % (stall,))

# SYNTHETIC: the live log has no 'Durable-landing … FAILED' line right now; the wording is what DURABLE_FAIL_RE matches.
DL_FAIL = dl(NOW - 120, "  Durable-landing FAILED: merge 0f70fb34b68e300c45ea29be6a900f81eb83a17f is not ancestor of rig-canonical main")
p = mklog("hb-dl.log", real_shape([DL_FAIL]))
with Patch(hb, DISPATCH_LOG=p):
    dl_res = hb.durable_landing_fail(NOW)
check(isinstance(dl_res, str) and "durable-landing FAILOU 1x" in dl_res,
      "durable_landing_fail() sees the FAILED line (got %r; the strict read gave None = 'all fine')" % (dl_res,))

# ── gate-health-monitor.py ──────────────────────────────────────────────────
print("Scenario 3: gate-health-monitor.py — _count_async_start_races()")
gh = load("gate-health-monitor.py")
# SYNTHETIC: the live log has no 'stale_async_start race' line right now; the substring is what the counter matches.
RACE = lambda t: dl(t, "  reviewer spawn: stale_async_start race detected for session gate-reviewer-adhoc-x")
p = mklog("gh.log", real_shape([RACE(NOW - 300), RACE(NOW - 200)]))
with Patch(gh, DISPATCH_LOG=p):
    races = gh._count_async_start_races()
check(races == 2, "_count_async_start_races() counts the 2 races in the window (got %r; the strict read gave 0 = 'no spike')" % (races,))

# ── all three: identical to the old read on a clean log, neutral on a missing one ─────
print("Scenario 4: on a CLEAN log the new read equals the old one; a MISSING log is still neutral")
clean = mklog("clean.log", [NOISE] * 50 + [QUEUED])
old = lambda n: open(clean).readlines()[-n:]
check(ps.tail_lines(clean, 20) == old(20) and hb.tail_lines(clean, 20) == old(20) and ps.tail_lines(clean, 500) == old(500),
      "tail_lines() == the old readlines()[-n:] on a valid log (same lines, same trailing newlines, same window)")
missing = os.path.join(TMP, "nope.log")
with Patch(gh, DISPATCH_LOG=missing):
    miss_races = gh._count_async_start_races()
check(ps.tail_lines(missing, 5) == [] and hb.tail_lines(missing, 5) == [] and miss_races == 0,
      "a missing log still yields [] / [] / 0 — the unreadable case keeps its neutral value and raises nothing")

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
