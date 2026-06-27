#!/usr/bin/env bash
# gate-health-monitor.selftest.sh — Regression harness for the async-start race
# regression checks added to gate-health-monitor.py (4f57fbac4 / gc-patched-asyncstart).
#
# Tests the pure helper functions without touching live Dolt / live gc binary / live logs:
#   _binary_has_async_start_fix(path) — CHECK A: binary integrity
#   _count_async_start_races_in_text(lines, window_sec, now) — CHECK B: race rate
#   _disp_log_ts(line) — timestamp parser used by CHECK B
#
# Scenarios:
#   1. Binary contains fix string → _binary_has_async_start_fix → True (no alert)
#   2. Binary lacks fix string   → _binary_has_async_start_fix → False (alert)
#   3. Binary path is None       → _binary_has_async_start_fix → None (fail-open, no alert)
#   4. Binary path doesn't exist → _binary_has_async_start_fix → None (fail-open, no alert)
#   5. Real live gc binary       → _binary_has_async_start_fix → True (fix still present)
#   6. Empty log                 → race count = 0 (no spike)
#   7. Races within window, below threshold → no spike
#   8. Races within window, above threshold → spike detected
#   9. Races outside window (old timestamps) → count = 0 (windowed correctly)
#  10. Log with mixed in/out-of-window races → only in-window races counted
#  11. _disp_log_ts parses valid timestamp correctly
#  12. _disp_log_ts returns None for invalid input (fail-safe)
#  13. Drift guard: all new functions defined + wired into main loop
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$SCRIPT_DIR/gate-health-monitor.py"

/usr/bin/python3 - "$WD" <<'PY'
import sys, importlib.util, os, tempfile, time, datetime

wd_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("gate_health_monitor", wd_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)  # top-level defines only; main loop is guarded by __name__

PASS = 0
FAIL = 0

def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)

def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

FIX_STRING = "async-start (fresh creating)"

# ── Helpers ──────────────────────────────────────────────────────────────────

def tmp_file(content):
    """Write content to a temp file and return its path."""
    fd, path = tempfile.mkstemp(suffix=".bin")
    try:
        os.write(fd, content.encode() if isinstance(content, str) else content)
    finally:
        os.close(fd)
    return path

def fmt_ts(delta_sec):
    """Format a log timestamp for 'now - delta_sec' in local time."""
    t = time.time() - delta_sec
    return "[%s]" % time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))

def race_line(delta_sec=0):
    """Synthetic dispatcher log line carrying a stale_async_start race marker."""
    return ("%s [quality-gate-dispatcher] WARN:   ACK skip (ga-test): reviewer 1 "
            "session=ga-wisp-x drained during startup (stale_async_start race) "
            "— nudge skipped, re-convene will re-spawn\n" % fmt_ts(delta_sec))

# ── Scenario 1: binary WITH fix string → True ────────────────────────────────
print("Scenario 1: binary containing fix string → True (fix present)")
p = tmp_file("some text\n%s\nmore text\n" % FIX_STRING)
try:
    res = m._binary_has_async_start_fix(p)
    if res is True:
        ok("binary with fix string → True")
    else:
        bad("expected True, got %r" % res)
finally:
    os.unlink(p)

# ── Scenario 2: binary WITHOUT fix string → False (regression) ───────────────
print("Scenario 2: binary lacking fix string → False (regression detected)")
p = tmp_file("some text\nunrelated content\nno fix here\n")
try:
    res = m._binary_has_async_start_fix(p)
    if res is False:
        ok("binary without fix string → False (regression signal)")
    else:
        bad("expected False, got %r" % res)
finally:
    os.unlink(p)

# ── Scenario 3: path is None → None (fail-open) ──────────────────────────────
print("Scenario 3: path=None → None (fail-open, no alert)")
res = m._binary_has_async_start_fix(None)
if res is None:
    ok("None path → None (fail-open)")
else:
    bad("expected None, got %r" % res)

# ── Scenario 4: nonexistent path → None (fail-open) ─────────────────────────
print("Scenario 4: nonexistent path → None (fail-open, no alert)")
res = m._binary_has_async_start_fix("/nonexistent/path/to/binary")
if res is None:
    ok("nonexistent path → None (fail-open)")
else:
    bad("expected None, got %r" % res)

# ── Scenario 5: live gc binary → True (fix still present) ───────────────────
print("Scenario 5: live gc binary → True (fix currently in production binary)")
gc_path = m._gc_binary_path()
if gc_path is None:
    ok("gc not in PATH — skip live binary check (acceptable in CI/test env)")
else:
    res = m._binary_has_async_start_fix(gc_path)
    if res is True:
        ok("live gc binary (%s) still contains the async-start fix" % gc_path)
    elif res is False:
        bad("REGRESSION: live gc binary (%s) is missing the async-start fix — "
            "reviewer-spawn flakiness will resurge" % gc_path)
    else:
        ok("live gc binary unreadable by strings (None) — fail-open, no alert")

# ── Scenario 6: empty log → race count = 0 ───────────────────────────────────
print("Scenario 6: empty log → race count = 0 (no spike)")
cnt = m._count_async_start_races_in_text([], window_sec=3600)
if cnt == 0:
    ok("empty log → 0 races")
else:
    bad("expected 0, got %d" % cnt)

# ── Scenario 7: races within window, below threshold → no spike ───────────────
print("Scenario 7: 3 races in window, threshold=8 → below threshold (no alert)")
lines = [race_line(60 * i) for i in range(3)]   # 3 races, 0-2 min ago
now = time.time()
cnt = m._count_async_start_races_in_text(lines, window_sec=3600, now=now)
if cnt == 3:
    ok("3 races in window counted correctly (below threshold 8)")
else:
    bad("expected 3, got %d" % cnt)

# ── Scenario 8: races within window, above threshold → spike ─────────────────
print("Scenario 8: 10 races in window, threshold=8 → spike detected (alert)")
lines = [race_line(60 * i) for i in range(10)]  # 10 races, 0-9 min ago
now = time.time()
cnt = m._count_async_start_races_in_text(lines, window_sec=3600, now=now)
if cnt == 10:
    ok("10 races in window counted correctly (above threshold 8 → alert)")
else:
    bad("expected 10, got %d" % cnt)

# ── Scenario 9: races OUTSIDE window → count = 0 ─────────────────────────────
print("Scenario 9: races older than window → count = 0 (correctly windowed)")
lines = [race_line(3700 + 60 * i) for i in range(5)]  # all > 1h old
now = time.time()
cnt = m._count_async_start_races_in_text(lines, window_sec=3600, now=now)
if cnt == 0:
    ok("races outside window → 0 (windowed correctly)")
else:
    bad("expected 0 (all outside window), got %d" % cnt)

# ── Scenario 10: mixed in/out-of-window races → only in-window counted ────────
print("Scenario 10: 3 in-window + 4 out-of-window races → count = 3")
lines  = [race_line(300 * i) for i in range(3)]       # 3 recent (0, 5, 10 min ago)
lines += [race_line(3700 + 60 * i) for i in range(4)] # 4 old (>1h)
lines += ["[2026-01-01 00:00:00] [dispatcher] unrelated line\n"]  # noise
now = time.time()
cnt = m._count_async_start_races_in_text(lines, window_sec=3600, now=now)
if cnt == 3:
    ok("3 in-window + 4 out-of-window → 3 (window boundary respected)")
else:
    bad("expected 3, got %d" % cnt)

# ── Scenario 11: _disp_log_ts parses valid timestamp ──────────────────────────
print("Scenario 11: _disp_log_ts parses '[YYYY-MM-DD HH:MM:SS]' correctly")
line = "[2026-06-24 20:33:20] [dispatcher] WARN: stale_async_start race\n"
ts = m._disp_log_ts(line)
if ts is None:
    bad("_disp_log_ts returned None for a valid log line")
else:
    # Reconstruct the same epoch the function should return and compare
    want = time.mktime(time.strptime("2026-06-24 20:33:20", "%Y-%m-%d %H:%M:%S"))
    if abs(ts - want) < 1:
        ok("_disp_log_ts parsed local timestamp correctly (epoch diff < 1s)")
    else:
        bad("epoch mismatch: got %.0f want %.0f" % (ts, want))

# ── Scenario 12: _disp_log_ts returns None for bad input ──────────────────────
print("Scenario 12: _disp_log_ts returns None for malformed/empty input")
for bad_input, label in [
    ("", "empty string"),
    ("no bracket", "no leading bracket"),
    ("[not-a-date] rest", "invalid date"),
    (None, "None input"),
]:
    try:
        result = m._disp_log_ts(bad_input)
    except Exception:
        result = None
    if result is None:
        ok("bad input (%s) → None (fail-safe)" % label)
    else:
        bad("expected None for bad input (%s), got %r" % (label, result))

# ── Scenario 13: Drift guard — functions defined + wired into main loop ────────
print("Scenario 13: drift guard — new functions defined and wired into the main loop")
src = open(wd_path).read()
checks = [
    ("def _disp_log_ts(", "_disp_log_ts() timestamp parser is defined"),
    ("def _gc_binary_path(", "_gc_binary_path() resolver is defined"),
    ("def _binary_has_async_start_fix(", "_binary_has_async_start_fix() check is defined"),
    ("def _count_async_start_races_in_text(", "_count_async_start_races_in_text() pure core is defined"),
    ("def _count_async_start_races(", "_count_async_start_races() log reader is defined"),
    ("_gc_binary_path()", "_gc_binary_path() is called in main loop"),
    ("_binary_has_async_start_fix(_gc_path)", "_binary_has_async_start_fix() is called in main loop"),
    ("_count_async_start_races()", "_count_async_start_races() is called in main loop"),
    ("ASYNC-START-REGRESS", "[ASYNC-START-REGRESS] alert tag is present"),
    ("ASYNC-START-RACE", "[ASYNC-START-RACE] alert tag is present"),
    ("GATE_REVIEWER_RACE_CHECK", "GATE_REVIEWER_RACE_CHECK env knob is present"),
    ("GATE_REVIEWER_RACE_MAX", "GATE_REVIEWER_RACE_MAX env knob is present"),
    ("if __name__ == \"__main__\":", "__main__ guard present (module is importable for testing)"),
    ("binary_regress_alerted", "binary_regress_alerted cooldown state is present"),
    ("race_spike_alerted", "race_spike_alerted cooldown state is present"),
    ("RACE_WINDOW_SEC", "RACE_WINDOW_SEC constant is defined"),
]
for needle, desc in checks:
    if needle in src:
        ok(desc)
    else:
        bad("MISSING: %s (needle %r not found in source)" % (desc, needle))

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
