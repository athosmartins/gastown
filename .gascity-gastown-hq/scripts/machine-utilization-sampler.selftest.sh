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
echo "machine-utilization-sampler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
