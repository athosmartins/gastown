#!/usr/bin/env bash
# token-ledger-harvest.selftest.sh — ga-5c3msy: the order wrapper must (1) really run the tool's `harvest`, (2) leave one
# log line per run with rc and duration, (3) hand a failing tool's exit code to the order runner (a harvest that fails
# silently is the "ledger quietly stops filling, then a week of numbers is gone" failure), (4) work with a bare PATH
# (orders do not run in a login shell). Hermetic: a fake tool stands in for bead-token-meter.py.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$SELF_DIR/scripts/token-ledger-harvest.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/token-ledger-harvest-selftest.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cat > "$W/fake-tool.py" <<'PY'
import os, sys
open(os.environ["FAKE_ARGV_OUT"], "w").write(" ".join(sys.argv[1:]))
print("harvest: fake run"); print("second line")
sys.exit(int(os.environ.get("FAKE_RC", "0")))
PY
run() { env -i PATH="/usr/bin:/bin" HOME="$W" GC_CITY_PATH="$W/city" TOKEN_LEDGER_TOOL="$W/fake-tool.py" TOKEN_LEDGER_LOG="$W/city/.gc/logs/h.log" FAKE_ARGV_OUT="$W/argv" "$@" /bin/bash "$WRAP"; }
run FAKE_RC=0 >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && ok "tool rc 0 -> wrapper rc 0" || bad "rc=$rc"
[ "$(cat "$W/argv")" = "harvest" ] && ok "the tool is invoked as: <tool> harvest" || bad "argv: $(cat "$W/argv")"
l="$(wc -l < "$W/city/.gc/logs/h.log" | tr -d ' ')"; [ "$l" = "1" ] && grep -Eq '^[0-9T:Z-]+ rc=0 secs=[0-9]+ harvest: fake run second line' "$W/city/.gc/logs/h.log" && ok "one log line per run: timestamp, rc, secs, the tool's own summary (newlines folded)" || bad "log: $(cat "$W/city/.gc/logs/h.log")"
run FAKE_RC=3 >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 3 ] && ok "tool rc 3 -> wrapper rc 3 (the order runner sees the failure)" || bad "failure swallowed: rc=$rc"
grep -q "harvest failed rc=3" "$W/err" && ok "failure text goes to stderr" || bad "no stderr: $(cat "$W/err")"
grep -q "rc=3" "$W/city/.gc/logs/h.log" && [ "$(wc -l < "$W/city/.gc/logs/h.log" | tr -d ' ')" = "2" ] && ok "a failed run is logged too (appends, never rewrites)" || bad "failed run not logged"
[ -x "$WRAP" ] && ok "wrapper is executable (the order execs it directly)" || bad "wrapper not executable"
echo; echo "$PASS ok, $FAIL failed"; [ "$FAIL" -eq 0 ]
