#!/usr/bin/env bash
# Selftest for machine-utilization-sampler.py — proves an unhandled exception notifies (ga-4zpf).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/machine-utilization-sampler.py"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/notify"

echo "── Scenario: OUT path unwritable → uncaught exception must notify ──"
: > "$TMP/blocker"    # a FILE, not a dir — forces os.makedirs() to raise
UTIL_OUT="$TMP/blocker/sub/out.jsonl" UTIL_NOTIFY="$TMP/notify" PATH="/usr/bin:/bin" \
  python3 "$J" >/dev/null 2>"$TMP/stderr"
rc=$?
[ "$rc" -ne 0 ] && ok "exits nonzero on uncaught exception (crash visible)" || bad "expected nonzero exit on write failure, got $rc"
grep -qi 'machine-utilization-sampler' "$NOTIFY_LOG" 2>/dev/null && ok "notify_fail fired on uncaught exception (ga-4zpf)" || bad "uncaught exception did NOT notify — silent crash (ga-4zpf regression)"
grep -qi 'Traceback' "$TMP/stderr" 2>/dev/null && ok "traceback still visible on stderr (not swallowed)" || bad "traceback missing from stderr — exception was swallowed instead of re-raised"

echo ""
echo "── ga-30xi3: sh() must not collapse a text-decode failure into the same '' a clean"
echo "   empty read produces (truncated-multibyte session title in 'gc session list') ──"
# gc session list's table form truncates titles to fit column width; a cut mid multi-byte
# UTF-8 char makes stdout invalid UTF-8. text=True decodes INSIDE subprocess.run, so a
# strict (default) decode raises UnicodeDecodeError there, caught by sh()'s existing
# `except Exception: return ""` — collapsing "one line had a bad byte" into the SAME ""
# a clean empty read produces. active_sessions() then reports EVERY template as
# zero-active (tmpl_active stays {}), not just the one session with the corrupted title.
PY30XI3_OUT="$(python3 - "$J" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("mus", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["mus"]
spec.loader.exec_module(m)

def _fake_run(args, **kwargs):
    if kwargs.get("errors") != "replace":
        raise UnicodeDecodeError("utf-8", b"\xe2\x80", 0, 2, "invalid continuation byte")
    return types.SimpleNamespace(
        returncode=0,
        stdout=("ID  TEMPLATE       STATE   AGE\n"
                "s1  gate-reviewer  active  wa-mgnkf: Broken capture �\n"
                "s2  gastown.dog    active  5m\n"))

m.subprocess.run = _fake_run
active = m.active_sessions()
want_ok = active.get("gate-reviewer", 0) == 1 and active.get("gastown.dog", 0) == 1
print("RESULT_OK" if want_ok else ("RESULT_BAD got=%r" % (active,)))
PY
)"
if echo "$PY30XI3_OUT" | grep -q "^RESULT_OK"; then
  ok "ga-30xi3: active_sessions() still counts BOTH templates despite one corrupted line"
else
  bad "ga-30xi3: active_sessions() lost session counts to a decode failure ($PY30XI3_OUT)"
fi

echo ""
echo "machine-utilization-sampler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
