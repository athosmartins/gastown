#!/usr/bin/env bash
# Selftest for pipeline-throughput-heartbeat.py — ga-30xi3 regression only.
#
# NOT a general test harness for this file (none existed before this bead); scoped
# narrowly to the one fix this bead makes. See imparavel-check.selftest.sh and
# gate-recovery-watchdog.selftest.sh for the sibling regressions of the same bug.
#
# Run: bash scripts/pipeline-throughput-heartbeat.selftest.sh   (exit 0 = all pass)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HB="$SELF_DIR/pipeline-throughput-heartbeat.py"
[ -f "$HB" ] || { echo "FATAL: pipeline-throughput-heartbeat.py not found at $HB"; exit 1; }

python3 - "$HB" <<'PY'
import importlib.util, sys, types, os
spec = importlib.util.spec_from_file_location("pth", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["pth"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

print("Scenario ga-30xi3: snapshot()'s sessions dump must not collapse a text-decode "
      "failure into the same '(failed)' a genuine command failure produces")
# gc session list's table form truncates titles to fit column width; a cut mid
# multi-byte UTF-8 char makes stdout invalid UTF-8. text=True decodes INSIDE
# subprocess.run, so a strict (default) decode raises UnicodeDecodeError there —
# caught by sh()'s existing `except Exception: return None`, which snapshot()
# renders as the SAME "(failed)" a genuinely dead command produces. Exactly
# backwards for a diagnostic: read by a human after an alert, as proof of state,
# right when a corrupted-but-still-live session most needs to show up.
def _fake_run_30xi3(args, **kwargs):
    if kwargs.get("errors") != "replace":
        raise UnicodeDecodeError("utf-8", b"\xe2\x80", 0, 2, "invalid continuation byte")
    if len(args) >= 3 and args[0] == "gc" and args[1] == "session" and args[2] == "list":
        return types.SimpleNamespace(
            returncode=0,
            stdout="s1  gate-reviewer  active  wa-mgnkf: Broken capture �\n")
    return types.SimpleNamespace(returncode=0, stdout="")

_orig_run_30xi3 = m.subprocess.run
_orig_tail_lines_30xi3 = m.tail_lines
m.subprocess.run = _fake_run_30xi3
m.tail_lines = lambda path, n: []   # log tails are unrelated to this fix; keep them inert
_snap_path_30xi3 = m.snapshot("30xi3test", "ga-30xi3 selftest")
m.subprocess.run = _orig_run_30xi3
m.tail_lines = _orig_tail_lines_30xi3

with open(_snap_path_30xi3) as _f:
    _content_30xi3 = _f.read()
os.unlink(_snap_path_30xi3)

if "gate-reviewer" in _content_30xi3 and "(failed)" not in _content_30xi3:
    ok("ga-30xi3: sessions section shows the real (corrupted-but-live) session, no '(failed)'")
else:
    bad("ga-30xi3: a decode failure hid the sessions dump behind '(failed)' (content: %r)" % (_content_30xi3,))

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
