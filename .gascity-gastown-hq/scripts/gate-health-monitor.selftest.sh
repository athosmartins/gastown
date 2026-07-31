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
#   1. Binary contains fix string (original wording) → _binary_has_async_start_fix → True
#  1b. Binary contains fix string (current post-ee6999666 wording, ga-4bai6) → True
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

# ga-4bai6: ee6999666 generalized the config-drift-drain exemption from
# gate-reviewer-only to all wake_mode=fresh ephemeral workers, inserting
# ", wake_mode=fresh)" between "fresh creating" and the closing paren. The
# probe used to match through the closing paren, so it broke the moment this
# landed (~275 false [ASYNC-START-REGRESS] alerts before it was noticed).
# This is the exact current-production wording — kept alongside FIX_STRING
# (the original wording) so both shapes are covered deterministically,
# without depending on Scenario 5's live-binary check (which no-ops if `gc`
# isn't on PATH).
CURRENT_FIX_STRING = "ephemeral worker in async-start (fresh creating, wake_mode=fresh)"

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

# ── Scenario 1b: binary WITH CURRENT (post-ee6999666) fix string → True ──────
print("Scenario 1b: binary containing CURRENT wording (ga-4bai6) → True (fix present)")
p = tmp_file("some text\n%s\nmore text\n" % CURRENT_FIX_STRING)
try:
    res = m._binary_has_async_start_fix(p)
    if res is True:
        ok("binary with current (wake_mode=fresh) wording → True")
    else:
        bad("REGRESSION (ga-4bai6): expected True for current wording, got %r" % res)
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

# ── Scenarios 14-19: ga-kpv48 emit() cooldown ─────────────────────────────────
# emit() had no dedup: a condition that stays true re-fired every loop (120s)
# forever, because the upstream first-seen trackers gate only the START of an
# alert. Measured 2026-07-30: ~5-8k notifies/day (~96k since 06-06) from ~7
# persistent conditions x 720 cycles/day. That rate-limited the city's ENTIRE
# ntfy channel into 429s (alerting 100% blind from 04:03), and — since notify
# BLOCKS when transport is dead (measured 76s/call) — it also ate ~100% of this
# monitor's wall-clock: it queued on curl instead of watching the gate.
# Scenarios 13's binary_regress_alerted / race_spike_alerted are the same idea
# applied ad-hoc to 2 of the 10 emit sites; this generalizes it to all of them
# at the single choke point.
JAM = "[REAL-JAM] gate marker ga-wisp-abc stuck 140min (queued, no completion)"
CD = 3600

print("Scenario 14: a first-seen alert notifies")
if m.emit_should_notify(JAM, 1000.0, {}, CD) is True:
    ok("empty state -> notify")
else:
    bad("first-seen alert was suppressed")

print("Scenario 15: an immediate repeat is suppressed")
state = {m.emit_key(JAM): 1000.0}
for label, now in (("+0s", 1000.0), ("+120s (one loop)", 1120.0)):
    if m.emit_should_notify(JAM, now, state, CD) is False:
        ok("same alert %s -> suppress" % label)
    else:
        bad("same alert %s was NOT suppressed" % label)

print("Scenario 16: a drifting counter does not defeat dedup")
# This is the scenario that decides whether the fix bites in production: every
# real alert embeds a minute count that increments each cycle, so exact-string
# dedup would never match and the flood would continue unchanged.
for newv in ("142min", "9999min"):
    drifted = JAM.replace("140min", newv)
    if m.emit_should_notify(drifted, 1120.0, state, CD) is False:
        ok("counter drifted 140min -> %s still suppressed" % newv)
    else:
        bad("counter drift to %s defeated dedup (flood would continue)" % newv)

print("Scenario 17: suppression is per-alert, never global")
cases = [
    ("[GATE FAIL] ga-wisp-abc crew/x/y - tests failed", "different alert TAG"),
    # Same tag, DIFFERENT marker: the digit-normalizing key must not collapse
    # distinct entities, or a second stuck marker would go unreported.
    ("[REAL-JAM] gate marker ga-wisp-zzz stuck 140min (queued, no completion)",
     "same tag, different entity"),
]
for msg, desc in cases:
    if m.emit_should_notify(msg, 1000.0, state, CD) is True:
        ok("%s -> notify" % desc)
    else:
        bad("%s was wrongly suppressed by an unrelated alert" % desc)

print("Scenario 18: the alert returns once the cooldown elapses")
for delta, want, label in ((3599, False, "just inside"), (3600, True, "exactly at"),
                           (7200, True, "well past")):
    got = m.emit_should_notify(JAM, 1000.0 + delta, state, CD)
    if got is want:
        ok("+%ds (%s) -> %s" % (delta, label, "notify" if want else "suppress"))
    else:
        bad("+%ds (%s): expected %r, got %r" % (delta, label, want, got))

print("Scenario 19: stdout stays unconditional (suppression costs no log line)")
# Drive the REAL emit() twice with notify stubbed: both must PRINT (the local
# log and the digest keep full fidelity) while only the first reaches notify.
import io, contextlib
_calls = []
_real_subprocess = m.subprocess
m.subprocess = type("S", (), {"run": staticmethod(lambda *a, **k: _calls.append(a))})()
m._emit_last_notified.clear()
_buf = io.StringIO()
try:
    with contextlib.redirect_stdout(_buf):
        m.emit(JAM)
        m.emit(JAM.replace("140min", "142min"))
finally:
    m.subprocess = _real_subprocess
    m._emit_last_notified.clear()
_lines = [l for l in _buf.getvalue().splitlines() if l.strip()]
if len(_lines) == 2:
    ok("both cycles printed to stdout (2 lines)")
else:
    bad("expected 2 stdout lines, got %d — suppression ate a log line" % len(_lines))
if len(_calls) == 1:
    ok("only the first cycle reached notify (1 call)")
else:
    bad("expected 1 notify call, got %d" % len(_calls))

print("Scenario 20: drift guard — cooldown is defined and wired into emit()")
for needle, desc in [
    ("def emit_key(", "emit_key() normalizer is defined"),
    ("def emit_should_notify(", "emit_should_notify() pure decision is defined"),
    ("EMIT_COOLDOWN_SEC", "EMIT_COOLDOWN_SEC constant is defined"),
    ("GATE_HEALTH_EMIT_COOLDOWN_SEC", "env override knob is present"),
    ("_emit_last_notified", "per-alert cooldown state is present"),
]:
    ok(desc) if needle in src else bad("MISSING: %s (needle %r)" % (desc, needle))
_emit_src = src[src.index("def emit(msg):"):]
_emit_src = _emit_src[:_emit_src.index("\ndef ", 1)]
if "emit_should_notify" in _emit_src:
    ok("emit() consults the cooldown before notifying")
else:
    bad("emit() does NOT call emit_should_notify — the flood would return")
if "print(msg" in _emit_src:
    ok("emit() still prints unconditionally")
else:
    bad("emit() no longer prints unconditionally — log fidelity lost")

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
