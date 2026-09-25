#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-mlzqg4 regression.
#
# BUG: headofline_stall() counted only sweeps that end 'verdict=QUEUED (retry'. The
# dispatcher has other QUEUED endings, and the one behind the 25/09 gate stall —
# 'QUEUED (merge-tree proven clean, transient failures repeat, staying in bounded
# retry — ga-y5c29l)' — never matches, so the function returned (None, 0) on the very
# first line, by construction, through 30 consecutive sweeps / 82 minutes on ONE branch.
#
# DESIGN UNDER TEST (ga-mlzqg4, option "match, observe, do NOT repair"):
#   * the proven-clean / live-author QUEUED endings are recognised as their own kind
#     (headofline_nonrepair) and only LOGGED — no repair dog: the stale-branch runbook
#     assumes an auto-rebase CONFLICT, and merge-tree already proved that false here.
#   * the '(retry N/M, dead author)' ending keeps its repair signal, unchanged.
#   * the two kinds never inflate each other's consecutive count.
#
# Fixtures are VERBATIM lines from the live quality-gate-dispatcher.log (25/09/2026):
# the real (retry 1/3 / 2/3) lines that preceded the incident on the same branch, the
# first 8 real proven-clean sweeps, the real live-author transient lines, real YIELDED
# lines, and the real 'SUPPRESSED PUSH … QUEUED (…' noise line that carries the verdict
# text but is NOT a sweep-complete line.
#
# Also a producer-side drift guard: it extracts every QUEUED ending straight from
# quality-gate-dispatcher.sh and asserts each one is recognised — so a future new QUEUED
# ending cannot silently reopen this blind spot (the guard reads the producer, it does
# not restate the consumer's pattern).
#
# Run: bash scripts/gate-recovery-watchdog.headofline-queued-vocab.selftest.sh
#      WD_OVERRIDE=<other copy of the watchdog> bash ...   (prove it fails on older code)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
DISPATCHER="${DISPATCHER_OVERRIDE:-$SELF_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }
[ -f "$DISPATCHER" ] || { echo "FATAL: quality-gate-dispatcher.sh not found at $DISPATCHER"; exit 1; }

python3 - "$WD" "$DISPATCHER" <<'PY'
import importlib.util, os, re, sys, tempfile, time

# Hermetic: a stray override in the runner's env must not move the thresholds under test.
for k in list(os.environ):
    if k.startswith("GRW_HOL_"):
        del os.environ[k]

wd_path, dispatcher_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("grw", wd_path)
m = importlib.util.module_from_spec(spec)
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

# The whole point of the bug is that this API did not exist. Say so plainly instead of a
# traceback, and count it as a failure (exit 1), not a skip.
missing = [n for n in ("_scan_headofline", "headofline_scan", "headofline_nonrepair", "_nonrepair_signal",
                       "SWEEP_QUEUED_ANY_RE", "HEADOFLINE_NONREPAIR_MIN_SWEEPS", "HOL_KIND_UNKNOWN",
                       "_read_log_tail_lines", "HEADOFLINE_TAIL_BYTES")
           if not hasattr(m, n)]
if missing:
    print("  BAD: watchdog has no %s — ga-mlzqg4 (recognise the non-conflict QUEUED endings) has not landed"
          % ", ".join(missing))
    print("\nPASS=0 FAIL=1")
    sys.exit(1)

# ── Verbatim fixtures (live dispatcher log, 25/09/2026) ─────────────────────
PFX = "[quality-gate-dispatcher] === Dispatcher sweep complete: "
BR = "crew/wa-worker/wa-wqn2v"
def ts(t): return "[%s] " % t
RETRY_1 = ts("2026-09-25 07:36:22") + PFX + "branch=%s verdict=QUEUED (retry 1/3, dead author) ===" % BR
RETRY_2 = ts("2026-09-25 07:38:53") + PFX + "branch=%s verdict=QUEUED (retry 2/3, dead author) ===" % BR
CLEAN_VERDICT = "QUEUED (merge-tree proven clean, transient failures repeat, staying in bounded retry — ga-y5c29l)"
CLEAN_TS = ["2026-09-25 09:44:40", "2026-09-25 09:48:22", "2026-09-25 09:55:49", "2026-09-25 09:59:10",
            "2026-09-25 10:02:29", "2026-09-25 10:05:08", "2026-09-25 10:08:24", "2026-09-25 10:11:07"]
CLEAN = [ts(t) + PFX + "branch=%s verdict=%s ===" % (BR, CLEAN_VERDICT) for t in CLEAN_TS]
LIVE_BR = "crew/wa-worker/wa-rvnkk-reanchor"
LIVE_1 = ts("2026-09-25 00:12:20") + PFX + "branch=%s verdict=QUEUED (transient rebase race, author peter-wa live, retry 1/3) ===" % LIVE_BR
LIVE_2 = ts("2026-09-25 00:16:26") + PFX + "branch=%s verdict=QUEUED (transient rebase race, author peter-wa live, retry 2/3) ===" % LIVE_BR
YIELDED = ts("2026-09-25 18:40:15") + PFX + "branch=crew/wa-worker/wa-x02jx verdict=YIELDED (live sibling ga-hjlkv8, pre-rebase) ==="
# Real noise between sweeps. The SUPPRESSED PUSH line carries the verdict text but is NOT a
# sweep-complete line; the '✓ Added label' line is bd's stdout leaking into the log.
NOISE = [
    "✓ Added label 'gate-status:queued' to ga-g5s956",
    ts("2026-09-25 09:44:40") + "[quality-gate-dispatcher] SUPPRESSED PUSH (wa-uthi non-terminal): branch %s — %s." % (BR, CLEAN_VERDICT),
]
def interleave(lines):
    out = []
    for l in lines:
        out += NOISE + [l]
    return out

MIN_R = m.HEADOFLINE_MIN_SWEEPS
MIN_N = m.HEADOFLINE_NONREPAIR_MIN_SWEEPS
CONFLICT, OTHER = m.HOL_KIND_CONFLICT_RETRY, m.HOL_KIND_QUEUED_OTHER

# ── 1. The real incident: 6+ proven-clean sweeps on one branch ──────────────
print("Scenario 1: replay of the 25/09 incident (proven-clean QUEUED on ONE branch, noise between sweeps)")
inc = interleave(CLEAN)
check(m._scan_headofline(inc) == (OTHER, BR, len(CLEAN)),
      "scan sees the run: kind=queued-other branch=%s count=%d" % (BR, len(CLEAN)))
check(m.SWEEP_QUEUED_RETRY_RE.search(CLEAN[0]) is None,
      "premise pinned: the '(retry' pattern really does NOT match this ending (the original blind spot)")
# Through the I/O wrapper with a fresh log file — the path main() actually calls.
def with_log(lines, age_sec=0, fn=None):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "quality-gate-dispatcher.log")
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    t = time.time() - age_sec
    os.utime(p, (t, t))
    old = m.DISPATCH_LOG
    m.DISPATCH_LOG = p
    try:
        return fn()
    finally:
        m.DISPATCH_LOG = old
check(with_log(inc, fn=m.headofline_nonrepair) == (BR, len(CLEAN)),
      "headofline_nonrepair() reports (branch, count) for the incident on a fresh log")
check(with_log(inc, fn=m.headofline_stall) == (None, 0),
      "headofline_stall() (the REPAIR signal) stays (None, 0) — proven-clean must NOT spawn a repair dog")

# ── 2. The already-covered case is unchanged ────────────────────────────────
print("Scenario 2: '(retry N/M, dead author)' keeps its repair signal, untouched")
check(with_log([RETRY_1, RETRY_2], fn=m.headofline_stall) == (BR, 2),
      "the 2 real '(retry 1/3, 2/3)' sweeps on one branch → repair signal (branch, 2)")
check(with_log([RETRY_1], fn=m.headofline_stall) == (None, 0),
      "a single retry sweep is below HEADOFLINE_MIN_SWEEPS(=%d) → no signal" % MIN_R)
check(with_log([RETRY_1, RETRY_2], fn=m.headofline_nonrepair) == (None, 0),
      "the retry kind is NOT reported by the observe-only signal (no double handling)")

# ── 3. Kinds never inflate each other ───────────────────────────────────────
print("Scenario 3: mixed sequences — each kind counts only its own consecutive run")
# The REAL order on 25/09: retry,retry then the proven-clean ones. Newest run is clean.
real_order = [RETRY_1, RETRY_2] + CLEAN[:6]
check(m._scan_headofline(real_order) == (OTHER, BR, 6),
      "real order retry×2 → clean×6: newest run is clean×6 (the 2 retries do not add to it)")
check(with_log(real_order, fn=m.headofline_stall) == (None, 0),
      "…and the repair signal is NOT raised by the older retry sweeps once the newest run is clean")
# Opposite order: a clean run, then a fresh conflict — repair counts only the retries.
flip = CLEAN[:6] + [RETRY_1, RETRY_2]
check(m._scan_headofline(flip) == (CONFLICT, BR, 2),
      "clean×6 → retry×2: newest run is retry×2, NOT 8 (clean sweeps must not inflate the retry count)")
check(with_log(flip, fn=m.headofline_stall) == (BR, 2),
      "…repair signal (branch, 2)")
check(with_log(flip, fn=m.headofline_nonrepair) == (None, 0),
      "…and the observe-only signal is silent")

# ── 4. Thresholds (boundary, both sides) ────────────────────────────────────
print("Scenario 4: HEADOFLINE_NONREPAIR_MIN_SWEEPS boundary")
need = MIN_N
check(with_log((CLEAN * 2)[:need - 1], fn=m.headofline_nonrepair) == (None, 0),
      "%d proven-clean sweeps (threshold-1) → no signal" % (need - 1))
check(with_log((CLEAN * 2)[:need], fn=m.headofline_nonrepair) == (BR, need),
      "%d proven-clean sweeps (== threshold) → signal" % need)

# ── 5. Live-author transient race: bounded (cap 3), so never trips ──────────
print("Scenario 5: live-author 'QUEUED (transient rebase race …)' — real bounded run")
live_real = [LIVE_1, LIVE_2]
check(m._scan_headofline(live_real) == (OTHER, LIVE_BR, 2),
      "the 2 real live-author sweeps are recognised as queued-other on %s" % LIVE_BR)
check(with_log(live_real, fn=m.headofline_nonrepair) == (None, 0),
      "…but 2 sweeps (the dispatcher caps this ending at 3) stay below threshold → no false alarm")
check(with_log(live_real, fn=m.headofline_stall) == (None, 0),
      "…and it is never a repair signal")

# ── 6. Anything else ends the run ───────────────────────────────────────────
print("Scenario 6: a real verdict / another branch / stale log ends or hides the run")
check(with_log(interleave(CLEAN[:6]) + [YIELDED], fn=m.headofline_nonrepair) == (None, 0),
      "6 clean sweeps then a newer YIELDED sweep → newest completion is not QUEUED → no signal")
other_branch = ts("2026-09-25 10:14:00") + PFX + "branch=crew/wa-worker/wa-zzzzz verdict=%s ===" % CLEAN_VERDICT
check(with_log(interleave(CLEAN[:6]) + [other_branch], fn=m.headofline_nonrepair) == (None, 0),
      "6 clean on A then 1 on B → head-of-line moved, run of 1 on B is below threshold → no signal")
check(with_log(inc, age_sec=m.HEADOFLINE_LOG_FRESH_SEC + 60, fn=m.headofline_nonrepair) == (None, 0),
      "a STALE dispatcher log yields no signal (that is ENGINE-STALL's job, not a HOL verdict)")
_saved_log = m.DISPATCH_LOG
m.DISPATCH_LOG = os.path.join(tempfile.mkdtemp(), "does-not-exist.log")
try:
    missing_res = m.headofline_nonrepair()
    missing_scan = m.headofline_scan()
finally:
    m.DISPATCH_LOG = _saved_log
check(missing_res == (None, 0),
      "an unreadable/missing log yields (None, 0), never an exception")

# ── 6b. Third state: 'could not read' is NOT 'read it, no run' ──────────────
print("Scenario 6b: unreadable/stale log is UNKNOWN — distinct from a log that was read and shows no run")
check(missing_scan == (m.HOL_KIND_UNKNOWN, None, 0),
      "missing log → headofline_scan() == (HOL_KIND_UNKNOWN, None, 0)")
check(with_log(inc, age_sec=m.HEADOFLINE_LOG_FRESH_SEC + 60, fn=m.headofline_scan) == (m.HOL_KIND_UNKNOWN, None, 0),
      "stale log (even one whose tail IS an ongoing run) → UNKNOWN, not an empty verdict")
read_no_run = with_log(interleave(CLEAN[:6]) + [YIELDED], fn=m.headofline_scan)
check(read_no_run == (None, None, 0) and read_no_run[0] != m.HOL_KIND_UNKNOWN,
      "a log that WAS read whose newest sweep is not QUEUED → (None, None, 0): a KNOWN 'no run', not UNKNOWN")
check(m._nonrepair_signal(m.HOL_KIND_UNKNOWN, BR, 999) == (None, 0),
      "UNKNOWN never produces a signal, whatever count rides along (inert default)")

# ── 6c. The LIVE log is not a clean file (found by running against real data) ──
print("Scenario 6c: real-log shape — invalid UTF-8 anywhere, and ~90 noise lines between sweeps")
def with_log_bytes(data, fn, tail_bytes=None):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "quality-gate-dispatcher.log")
    with open(p, "wb") as f:
        f.write(data)
    old, old_tail = m.DISPATCH_LOG, m.HEADOFLINE_TAIL_BYTES
    m.DISPATCH_LOG = p
    if tail_bytes is not None:
        m.HEADOFLINE_TAIL_BYTES = tail_bytes
    try:
        return fn()
    finally:
        m.DISPATCH_LOG, m.HEADOFLINE_TAIL_BYTES = old, old_tail
enc = lambda ls: ("\n".join(ls) + "\n").encode("utf-8")
# The dispatcher's own 'FAIL forensics reviewer' lines carry reviewer output cut mid-multibyte
# character: an em dash is e2 80 94, cut after 2 bytes. Real occurrence: 11 lines since 15/09.
BAD_LINE = (ts("2026-09-25 15:02:17") + "[quality-gate-dispatcher]   FAIL forensics reviewer 1 bead=ga-64qhxs tail=abc").encode("utf-8") + b"\xe2\x80"
# (a) invalid bytes INSIDE the region we read, incident run after it
data_a = enc(NOISE) + BAD_LINE + b"\n" + enc(interleave(CLEAN[:6]))
check(with_log_bytes(data_a, m.headofline_nonrepair) == (BR, 6),
      "a log with a truncated multibyte char in the middle still yields the run (old strict read → UnicodeDecodeError → no signal)")
check(with_log_bytes(data_a, m.headofline_scan)[0] != m.HOL_KIND_UNKNOWN,
      "…and it is NOT reported as UNKNOWN (the log was readable)")
# (b) invalid bytes at the HEAD of a file bigger than the tail window: never even read now
old_sweeps = enc([RETRY_1, RETRY_2]) * 200          # plenty of older content, other kind
data_b = BAD_LINE + b"\n" + old_sweeps + enc(interleave(CLEAN[:6]))
check(len(data_b) > 40000, "fixture is larger than the tail window used below (%d bytes)" % len(data_b))
check(with_log_bytes(data_b, m.headofline_nonrepair, tail_bytes=20000) == (BR, 6),
      "invalid bytes at the head of a file larger than the tail window are never read → run found")
# (c) real spacing: ~90 noise lines between sweeps; 8 sweeps => ~720+ lines, far past the old 400-line window
SPACER = ["✓ Added label 'gate:rebase-fail-count:3' to ga-g5s956"] * 90
spaced = []
for c in CLEAN:                                      # all 8 real incident sweeps
    spaced += SPACER + [c]
check(len(spaced) > 400 + 8, "fixture spans %d lines (> the old 400-line window)" % len(spaced))
check(with_log(spaced, fn=m.headofline_nonrepair) == (BR, len(CLEAN)),
      "8 real sweeps at ~90 noise lines apart are ALL counted (the old 400-line window saw ~4 and could never reach %d)" % MIN_N)
# (d) a seek into the middle of a line must not turn the cut line into a fake sweep or crash
cut = enc(CLEAN[:6])                                 # begins with a sweep line, so the seek lands INSIDE one
check(with_log_bytes(cut, m.headofline_nonrepair, tail_bytes=len(cut) - 30) == (BR, 5),
      "tail read that starts mid-way through the first SWEEP line drops that partial line (5 whole sweeps remain, no crash)")
# (e) file smaller than the window: nothing dropped
check(with_log_bytes(cut, m.headofline_nonrepair) == (BR, 6),
      "file smaller than the window is read whole (first line NOT dropped)")

# ── 7. Producer-side drift guard ────────────────────────────────────────────
print("Scenario 7: every QUEUED ending the DISPATCHER can emit is recognised (read from the producer)")
src = open(dispatcher_path, encoding="utf-8").read()
endings = re.findall(r'REBASE_VERDICT="(QUEUED \([^"]*\))"', src)
# Render shell variables into plausible values: ${X:-y}/${X}/$X → "1".
render = lambda s: re.sub(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*", "1", s)
check(len(endings) >= 3,
      "extracted %d QUEUED endings from quality-gate-dispatcher.sh (>=3, so an empty extraction cannot pass vacuously)"
      % len(endings))
unrecognised = []
for e in endings:
    line = PFX + "branch=some/branch verdict=%s ===" % render(e)
    if m._scan_headofline([line])[0] is None:
        unrecognised.append(e)
check(not unrecognised,
      "every dispatcher QUEUED ending is classified as one of the two kinds%s"
      % ("" if not unrecognised else " — UNRECOGNISED: %r" % unrecognised))
check(any("merge-tree proven clean" in e for e in endings),
      "the ga-y5c29l proven-clean ending is among the extracted endings (the 25/09 one)")

# ── 8. Design pin: the log-only block in main() must not spawn ──────────────
print("Scenario 8: main()'s non-repair block is log-only (no snapshot, no governed_spawn)")
wd_src = open(wd_path, encoding="utf-8").read()
a = wd_src.find("HEAD-OF-LINE, non-conflict QUEUED endings (ga-mlzqg4)")
b = wd_src.find("--- SUPERVISOR init-failure loop", a if a >= 0 else 0)
check(a >= 0 and b > a, "found the non-repair block boundaries in main() (non-vacuous slice)")
block = wd_src[a:b] if (a >= 0 and b > a) else ""
# CODE lines only: the block's own explanatory comment names snapshot()/governed_spawn() to say
# it does not call them, and a text scan must not read that as a call.
code = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
check("_nonrepair_signal(" in code and "headofline_scan()" in code,
      "the block is driven by headofline_scan() + _nonrepair_signal()")
check("governed_spawn(" not in code and "snapshot(" not in code and "notify(" not in code,
      "the block's code contains no governed_spawn( / snapshot( / notify( call — it only logs (option (b) would break this)")
check("elif hk != HOL_KIND_UNKNOWN" in code and code.count(".clear()") == 1,
      "the rate-limit dict is cleared ONLY behind the `!= HOL_KIND_UNKNOWN` guard — an unreadable log never ends an episode")

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
