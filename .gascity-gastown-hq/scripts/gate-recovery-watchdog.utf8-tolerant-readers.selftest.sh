#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-b1iulk regression.
#
# BUG: the watchdog read the dispatcher log with `open(DISPATCH_LOG).readlines()[-N:]` at five sites.
# open() decodes UTF-8 STRICTLY and readlines() reads the WHOLE 25MB file before slicing, so ONE byte
# that is not valid UTF-8 anywhere in it raised UnicodeDecodeError — swallowed by each caller's
# `except Exception: return <neutral>`. The log has 11 such lines since 15/09 (the dispatcher's
# 'FAIL forensics reviewer' lines carry reviewer output cut mid-multibyte-character), so on the live
# system last_pass_epoch() returned 0 ('never passed') with 13 'Gate PASSED' in the 4000 lines it reads
# (769 in the whole file, 25/09), and
# _dispatcher_log_state() returned ([], "", False) ('log not fresh') on a log written seconds ago.
# Error and empty produced the same value — the detector was blind, not quiet.
#
# THE SITES (one case each below; every one FAILS on the code before ga-b1iulk):
#   last_pass_epoch()        recent_timeouts()        stuck_dispatching()      gate_infra_throttled()
#   _dispatcher_log_state()  (via orphaned_queued_marker() end to end)
# plus two LATENT twins in the same file that read a different log the same strict way:
#   pilot_jammed()  (pilot log)        dolt_instability()  (supervisor log, text-mode seek to a byte offset)
#
# Fixtures: line FORMATS are verbatim from the live logs (25/09/2026); timestamps are generated
# relative to now because every detector under test is time-windowed. The pilot 'aborting dispatch' lines
# are SYNTHETIC (the live pilot log has none right now) — labelled where used. The invalid bytes are the
# real shape: an em dash (e2 80 94) cut after two bytes.
#
# Also pinned: the helper keeps every site's window at N LINES (never widened to N bytes) and equals the
# old readlines()[-N:] on a clean log; and orphaned_queued_marker()'s repair path is OFF by default
# (see GRW_ORPHAN_REPAIR_ENABLED — the detector's leapfrog proof is contradicted by the dispatcher's own
# tiered selection, found by running the fixed reader against the live queue).
#
# Run: bash scripts/gate-recovery-watchdog.utf8-tolerant-readers.selftest.sh
#      WD_OVERRIDE=<other copy of the watchdog> bash ...   (prove it fails on older code)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" "$SELF_DIR" <<'PY'
import atexit, importlib.util, os, re, shutil, subprocess, sys, tempfile, time

wd_path, scripts_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts_dir)          # sibling modules (gc_ledger, …) resolve even when WD_OVERRIDE points elsewhere

# Hermetic: a stray override in the runner's env must not move the thresholds under test.
for k in list(os.environ):
    if k.startswith("GRW_"):
        del os.environ[k]

def load():
    spec = importlib.util.spec_from_file_location("grw", wd_path)
    mod = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["grw"]                   # __name__ != "__main__" → main() never runs
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = saved
    return mod
m = load()

TMP = tempfile.mkdtemp(prefix="grw-utf8-")
atexit.register(shutil.rmtree, TMP, ignore_errors=True)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

HAVE_HELPER = hasattr(m, "_read_log_last_lines")
def need_helper(what):
    if not HAVE_HELPER:
        bad("watchdog has no _read_log_last_lines — %s cannot be checked (ga-b1iulk has not landed)" % what)
    return HAVE_HELPER

# ── fixtures ────────────────────────────────────────────────────────────────
NOW = time.time()
def fmt(t): return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
def dl(t, body): return ("[%s] [quality-gate-dispatcher] %s" % (fmt(t), body)).encode("utf-8")
TRUNC = b"\xe2\x80"                                   # an em dash (e2 80 94) cut after 2 bytes
BAD_LINE = dl(NOW - 3000, "  FAIL forensics reviewer 1 bead=ga-64qhxs tail=abc") + TRUNC
NOISE = dl(NOW - 2500, "✓ Added label 'gate:rebase-fail-count:3' to ga-g5s956")    # real noise line between sweeps

def mklog(name, chunks):
    p = os.path.join(TMP, name)
    with open(p, "wb") as f:
        f.write(b"\n".join(chunks) + b"\n")
    return p

def real_shape(tail):
    """BAD at the HEAD (outside every small window) and another INSIDE the last 4000 lines, then `tail`."""
    return [BAD_LINE] + [NOISE] * 2000 + [BAD_LINE] + [NOISE] * 2500 + tail

def strict_fails(path):
    try:
        with open(path) as f:
            f.readlines()
        return False
    except UnicodeDecodeError:
        return True

class Patch(object):
    def __init__(self, **kw): self.kw = kw
    def __enter__(self):
        self.old = dict((k, getattr(m, k, None)) for k in self.kw)
        for k, v in self.kw.items(): setattr(m, k, v)
    def __exit__(self, *a):
        for k, v in self.old.items(): setattr(m, k, v)

def fake_sh(stdout):
    return lambda args, timeout=20, stdin=None: subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")

# ── 1. The five dispatcher-log sites, each on a log of the REAL shape ───────
print("Scenario 1: dispatcher-log detectors read a log that contains invalid UTF-8")

p = mklog("d-pass.log", real_shape([dl(NOW - 120, "Gate PASSED: branch=fix/ga-wlhd07 tier=CODE merge_sha=ea08e4ad55efb886a5605788a9304fa79f38d40e elapsed=716s"),
                                    dl(NOW - 60, "Headroom OK: gate em 1 runs (Dolt cpu=69% lat=272ms / cota=ok / swap_free=1702MB) — dolt-calm; ceiling=6 reviewers, admitting a new run (ga-cw4pm).")]))
check(strict_fails(p), "fixture really is invalid UTF-8 under a strict read (the precondition of the bug)")
with Patch(DISPATCH_LOG=p):
    lp = m.last_pass_epoch()
check(abs(lp - (NOW - 120)) < 2,
      "last_pass_epoch() finds the 'Gate PASSED' 2min ago (got %r; the strict read returned 0 = 'never passed')" % (lp,))

p = mklog("d-timeout.log", real_shape([dl(NOW - 600, "Gate FAILED: TIMEOUT: reviewers did not submit verdicts within 29 minutes."),
                                       dl(NOW - 300, "Gate FAILED: TIMEOUT: reviewers did not submit verdicts within 29 minutes.")]))
with Patch(DISPATCH_LOG=p):
    n_to, last_to = m.recent_timeouts()
check(n_to == 2 and last_to is not None and abs(last_to - (NOW - 300)) < 2,
      "recent_timeouts() counts the 2 timeouts inside the window (got %r, %r; strict read gave (0, None))" % (n_to, last_to))

p = mklog("d-stuck.log", real_shape([dl(NOW - 30, "Phase C: gate-run ga-gc2ba8 (branch=fix/ga-x) still in flight (0/1 verdicts, 900s/1560s) — leaving for a future sweep.")]))
with Patch(DISPATCH_LOG=p, sh=fake_sh('{"sessions": []}')):
    stuck = m.stuck_dispatching()
check(stuck is True, "stuck_dispatching() sees the 0/1-verdicts poll at 900s with no active reviewer (got %r; strict read gave False)" % (stuck,))

p = mklog("d-throttle.log", real_shape([dl(NOW - 30, "Headroom DEFER: gate em 0 runs (Dolt cpu=141% lat=75ms / cota=LIMITED / swap_free=1067MB) — quota-limited; ceiling=0 reviewers, leaving 5 marker(s) queued (ga-cw4pm).")]))
with Patch(DISPATCH_LOG=p):
    thr = m.gate_infra_throttled()
check(thr is True, "gate_infra_throttled() sees the newest decision is a quota DEFER (got %r; strict read gave False = repair dogs NOT suppressed)" % (thr,))

BR = "crew/wa-worker/wa-newer"
p = mklog("d-state.log", real_shape([dl(NOW - 400, "=== Dispatcher sweep complete: branch=crew/oracle/wa-old verdict=YIELDED (live sibling ga-4jau8q, pre-rebase) ==="),
                                     dl(NOW - 100, "=== Dispatcher sweep complete: branch=%s verdict=QUEUED (retry 1/3, dead author) ===" % BR)]))
with Patch(DISPATCH_LOG=p):
    epochs, text, fresh = m._dispatcher_log_state()
check(len(epochs) == 2 and fresh is True and BR in text,
      "_dispatcher_log_state() returns both sweeps, fresh=True and the tail text (got %d epochs, fresh=%r; strict read gave ([], '', False))" % (len(epochs), fresh))

# End to end: the orphan detector is fed by _dispatcher_log_state, so a blind reader also blinds it.
p = mklog("d-orphan.log", real_shape([dl(NOW - 100, "=== Dispatcher sweep complete: branch=%s verdict=QUEUED (retry 1/3, dead author) ===" % BR)]))
with Patch(DISPATCH_LOG=p, _queued_markers=lambda: [("ga-head", "crew/x/head", NOW - 7200), ("ga-new", BR, NOW - 3600)]):
    orphan = m.orphaned_queued_marker()
check(orphan[0] == "ga-head" and orphan[1] == "crew/x/head",
      "orphaned_queued_marker() gets a live log (got %r; strict read gave (None, None, 0) for every input)" % (orphan,))

# ── 2. Latent twins: pilot log + supervisor log ─────────────────────────────
print("Scenario 2: the same strict read on the pilot log and the supervisor log")
# SYNTHETIC lines: the live pilot log has no 'aborting dispatch' right now; the marker strings are the ones pilot_jammed() matches.
pl = mklog("pilot.log", [BAD_LINE] + [NOISE] * 200 +
           [dl(NOW - 120, "pilot: aborting dispatch — gc sling failed for bead x-1"),
            dl(NOW - 60, "pilot: aborting dispatch — gc sling failed for bead x-2")])
check(strict_fails(pl), "pilot fixture is invalid UTF-8 under a strict read")
with Patch(PILOT_LOG=pl, daemon_deliberately_stopped=lambda label: False, secs_since_avail=lambda now: None):
    pj = m.pilot_jammed()
check(pj[0] is True, "pilot_jammed() sees the 2 sweep-aborts (got %r; strict read gave (False, '') = 'Pilot fine')" % (pj,))

def sup_ts(t): return time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(t))
sl = mklog("supervisor.log", [b"2026/09/10 08:00:00 provider-health cut " + TRUNC] + [b"raw untimestamped line"] * 50 +
           [("%s bead store closed while reconciling" % sup_ts(NOW - 90)).encode(),
            ("%s connection reset by peer" % sup_ts(NOW - 60)).encode()])
check(strict_fails(sl), "supervisor fixture is invalid UTF-8 under a strict read")
with Patch(SUPERVISOR_LOG=sl):
    dh = m.dolt_instability()
check(dh == 2, "dolt_instability() counts the 2 signature lines in the window (got %r; strict read gave 0 = 'no instability')" % (dh,))

# A text-mode seek to an arbitrary byte offset can land in the MIDDLE of a character. Force that: 200000 bytes of
# 2-byte chars, so the seek offset (size-200000) is odd relative to the char boundaries.
pre = "é".encode("utf-8") * 150001                        # 300002 valid bytes, ONE long line
tail_txt = ("%s connection reset by peer\n%s bead store closed\n" % (sup_ts(NOW - 50), sup_ts(NOW - 40))).encode()
for pad in (b"", b"x"):                                   # pad AFTER the long line: moves the window offset against the char grid
    data = pre + pad + b"\n" + tail_txt
    off = len(data) - 200000
    if (data[off] & 0xC0) == 0x80:
        break
sl2 = os.path.join(TMP, "supervisor-midchar.log")
with open(sl2, "wb") as f:
    f.write(data)
check((data[off] & 0xC0) == 0x80 and off > 0,
      "fixture precondition: the 200000-byte tail window starts on a UTF-8 continuation byte (mid-character) of an otherwise VALID log")
with Patch(SUPERVISOR_LOG=sl2):
    dh2 = m.dolt_instability()
check(dh2 == 2, "dolt_instability() survives it (got %r; a text-mode seek there raises UnicodeDecodeError → 0)" % (dh2,))

# ── 3. The helper itself ────────────────────────────────────────────────────
print("Scenario 3: _read_log_last_lines() keeps the window at N LINES and equals the old readlines()[-N:]")
if need_helper("the helper's unit tests"):
    R = m._read_log_last_lines
    rows = []
    for i in range(1, 9001):
        rows.append(("line %05d " % i) + ("x" * (i % 97)) + (" — é ✓" if i % 7 == 0 else ""))
    rows[4000] = "long " + "L" * 3000                    # a 'forensics'-sized line inside the window
    clean = os.path.join(TMP, "clean.log")
    with open(clean, "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + "\n")
    old = lambda n: [l.rstrip("\n") for l in open(clean, encoding="utf-8").readlines()[-n:]]
    ns = (1, 15, 25, 80, 3000, 4000, len(rows) - 1, len(rows), len(rows) + 5)
    check(all(R(clean, n) == old(n) for n in ns),
          "equals the old readlines()[-N:] (newline stripped) for N in %s" % (ns,))
    check(len(R(clean, 15)) == 15 and len(R(clean, 25)) == 25,
          "the window is N LINES, not widened to a byte budget (15 → %d lines, 25 → %d lines)" % (len(R(clean, 15)), len(R(clean, 25))))
    check(R(clean, 0) == [] and R(clean, -3) == [], "N <= 0 → [] (never the whole file, which [-0:] would return)")

    short = mklog("short.log", [b"only one", b"only two"])
    check(R(short, 25) == ["only one", "only two"], "a file shorter than N is returned whole — the first line is NOT dropped as 'partial'")

    with Patch(LAST_LINES_MIN_BYTES=64, LAST_LINES_BYTES_PER_LINE=1):
        check(all(R(clean, n) == old(n) for n in (15, 80, 3000, 4000)),
              "with a tiny starting budget the window grows x4 until it holds N whole lines (still equals readlines()[-N:], incl. the 3000-char line)")

    budgets = []
    real_tail = m._read_log_tail_lines
    def spy(path, max_bytes):
        budgets.append(max_bytes)
        return real_tail(path, max_bytes)
    with Patch(_read_log_tail_lines=spy):
        R(clean, 15)
    check(len(budgets) == 1 and budgets[0] <= 4 * m.LAST_LINES_MIN_BYTES,
          "a 15-line read of a %dKB file asks for one small window (%s bytes), never the whole file" % (os.path.getsize(clean) // 1024, budgets))

    # a tail that starts INSIDE a multibyte char and INSIDE a line must drop that partial line, not crash or fabricate a line
    mb = mklog("mb.log", [("é" * 60).encode("utf-8")] * 40 + [b"last one"])
    with Patch(LAST_LINES_MIN_BYTES=101, LAST_LINES_BYTES_PER_LINE=1):
        got = R(mb, 3)
    check(got[-1] == "last one" and len(got) == 3 and all(g == "é" * 60 for g in got[:-1]),
          "a byte window that starts mid-character still yields whole lines (%r…)" % (got[:1],))

    # missing file: the helper raises, so each detector's own `except` still means 'could not read' (3rd state)
    try:
        R(os.path.join(TMP, "nope.log"), 5); raised = False
    except OSError:
        raised = True
    check(raised, "a missing file still raises OSError (callers' `except Exception` is reached only by a REAL I/O failure)")

# The unreadable state stays distinguishable from a clean 'nothing here' — the detectors keep their neutral value.
missing = os.path.join(TMP, "does-not-exist.log")
with Patch(DISPATCH_LOG=missing, PILOT_LOG=missing, SUPERVISOR_LOG=missing, daemon_deliberately_stopped=lambda label: False):
    neutral = (m.last_pass_epoch(), m.recent_timeouts(), m.stuck_dispatching(), m.gate_infra_throttled(),
               m._dispatcher_log_state(), m.pilot_jammed(), m.dolt_instability())
check(neutral == (0, (0, None), False, False, ([], "", False), (False, ""), 0),
      "a MISSING log still yields each detector's neutral value and never an exception")

# ── 4. _dispatcher_log_state re-joins lines: no fused text ──────────────────
print("Scenario 4: the re-joined log text keeps line boundaries (no false 'branch mentioned')")
if need_helper("the separator check"):
    # Line A ends with 'crew/x/wa-' and line B starts with 'yzump': joined WITHOUT a separator the text would contain
    # 'crew/x/wa-yzump' — a branch that is mentioned on NO line. (readlines() kept each '\n'; the helper strips it.)
    p = mklog("d-fuse.log", [dl(NOW - 100, "=== Dispatcher sweep complete: branch=crew/oracle/wa-old verdict=YIELDED ==="),
                             b"trailing text crew/x/wa-", b"yzump more text"])
    with Patch(DISPATCH_LOG=p):
        _e, text, _f = m._dispatcher_log_state()
    check("crew/oracle/wa-old" in text and "crew/x/wa-yzump" not in text and text.endswith("\n"),
          "adjacent lines are separated by a newline in log_text (branch substring matching cannot straddle a join)")

# ── 5. Design pins ──────────────────────────────────────────────────────────
print("Scenario 5: orphan repair is OFF by default and log-only; no strict read of the three logs remains")
check(getattr(m, "GRW_ORPHAN_REPAIR_ENABLED", "missing") is False,
      "GRW_ORPHAN_REPAIR_ENABLED defaults to False (found live: the fixed reader flagged a marker the dispatcher claimed ~3min later)")
os.environ["GRW_ORPHAN_REPAIR_ENABLED"] = "1"
try:
    m_on = load()
finally:
    del os.environ["GRW_ORPHAN_REPAIR_ENABLED"]
check(getattr(m_on, "GRW_ORPHAN_REPAIR_ENABLED", None) is True, "GRW_ORPHAN_REPAIR_ENABLED=1 turns the repair path back on (explicit opt-in)")

src = open(wd_path, encoding="utf-8").read()
a = src.find("orphan_id, orphan_branch, orphan_age = orphaned_queued_marker()")
b = src.find("except Exception as e:\n        print(\"[watchdog] loop error", a if a >= 0 else 0)
check(a >= 0 and b > a, "found the orphan block boundaries in main() (non-vacuous slice)")
block = src[a:b] if (a >= 0 and b > a) else ""
code = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
i_log = code.find("if orphan_id and not infra and not GRW_ORPHAN_REPAIR_ENABLED:")
i_rep = code.find("elif orphan_id and not infra:")
check(0 <= i_log < i_rep, "the log-only branch comes first and the repair branch is its `elif` — the flag decides, not the order of luck")
logonly, repair = (code[i_log:i_rep], code[i_rep:]) if 0 <= i_log < i_rep else ("", "")
check("governed_spawn(" not in logonly and "snapshot(" not in logonly and "notify(" not in logonly and "print(" in logonly,
      "the log-only branch calls print() and none of governed_spawn( / snapshot( / notify(")
check("governed_spawn(" in repair, "the repair branch still exists behind the flag (re-enable is a flag flip, not a rewrite)")

strict = []
for mm in re.finditer(r"open\((DISPATCH_LOG|PILOT_LOG|SUPERVISOR_LOG)\b[^)]*\)", src):
    if "errors=" not in mm.group(0) and '"rb"' not in mm.group(0):
        strict.append(mm.group(0))
check(not strict, "no strict text-mode open() of the dispatcher / pilot / supervisor log remains%s"
      % ("" if not strict else " — FOUND: %r" % strict))

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
