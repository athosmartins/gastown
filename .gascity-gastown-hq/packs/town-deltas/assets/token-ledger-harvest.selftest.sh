#!/usr/bin/env bash
# token-ledger-harvest.selftest.sh — ga-5c3msy: the order wrapper must (1) really run the tool's `harvest`, (2) leave one
# log line per run with rc and duration, (3) hand a failing tool's exit code to the order runner (a harvest that fails
# silently is the "ledger quietly stops filling, then a week of numbers is gone" failure), (4) work with a bare PATH
# (orders do not run in a login shell), (5) with the REAL tool: a transcripts root that cannot be read must reach the order runner
# as a failure and show up in the log line (gate attempt 3: it used to print the normal summary and exit 0 - "nothing to harvest" -
# while the reaper deleted the transcripts 24h later). Hermetic: a fake tool stands in for bead-token-meter.py, except in (5).
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
run() { env -i PATH="/usr/bin:/bin" HOME="$W" GC_CITY_PATH="$W/city" TOKEN_LEDGER_TOOL="$W/fake-tool.py" TOKEN_LEDGER_LOG="$W/city/.gc/logs/h.log" FAKE_ARGV_OUT="$W/argv" "$@" /bin/bash "${WRAP_UNDER_TEST:-$WRAP}"; }
run FAKE_RC=0 >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && ok "tool rc 0 -> wrapper rc 0" || bad "rc=$rc"
[ "$(cat "$W/argv")" = "harvest" ] && ok "the tool is invoked as: <tool> harvest" || bad "argv: $(cat "$W/argv")"
l="$(wc -l < "$W/city/.gc/logs/h.log" | tr -d ' ')"; [ "$l" = "1" ] && grep -Eq '^[0-9T:Z-]+ rc=0 secs=[0-9]+ harvest: fake run second line' "$W/city/.gc/logs/h.log" && ok "one log line per run: timestamp, rc, secs, the tool's own summary (newlines folded)" || bad "log: $(cat "$W/city/.gc/logs/h.log")"
run FAKE_RC=3 >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 3 ] && ok "tool rc 3 -> wrapper rc 3 (the order runner sees the failure)" || bad "failure swallowed: rc=$rc"
grep -q "harvest failed rc=3" "$W/err" && ok "failure text goes to stderr" || bad "no stderr: $(cat "$W/err")"
grep -q "rc=3" "$W/city/.gc/logs/h.log" && [ "$(wc -l < "$W/city/.gc/logs/h.log" | tr -d ' ')" = "2" ] && ok "a failed run is logged too (appends, never rewrites)" || bad "failed run not logged"
[ -x "$WRAP" ] && ok "wrapper is executable (the order execs it directly)" || bad "wrapper not executable"

# ---- (5) the REAL tool through the wrapper: unreadable input must fail loudly
REAL="$SELF_DIR/bead-token-meter.py"
real() { run TOKEN_LEDGER_TOOL="$REAL" BTM_LEDGER="$W/real-ledger/sessions.jsonl" "$@"; }
mkdir -p "$W/okroot/-p"
printf '%s\n' '{"type":"user","timestamp":"2026-09-30T10:00:00Z","message":{"role":"user","content":"[gascity] gastown.dog-1 x"}}' > "$W/okroot/-p/s1.jsonl"
case_real_missing_root() {   # sets MR_RC and MR_LINE
  : > "$W/city/.gc/logs/h.log"
  real BTM_PROJECTS="$W/does-not-exist" >"$W/out" 2>"$W/err"; MR_RC=$?
  MR_LINE="$(tail -n 1 "$W/city/.gc/logs/h.log")"
}
case_real_missing_root
[ "$MR_RC" -eq 6 ] && ok "real tool, transcripts root missing: wrapper exit 6 (the order runner sees it)" || bad "missing root swallowed: wrapper rc=$MR_RC"
case "$MR_LINE" in *" rc=6 "*"SEM ENTRADA"*"não existe"*) ok "the log line carries rc=6 AND the alarm text inside the 500-char cut: ${MR_LINE:0:110}..." ;; *) bad "log line: $MR_LINE" ;; esac
grep -q "harvest failed rc=6" "$W/err" && ok "stderr says the harvest failed (what the order history shows)" || bad "no stderr: $(cat "$W/err")"
real BTM_PROJECTS="$W/okroot" >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && tail -n 1 "$W/city/.gc/logs/h.log" | grep -q ' rc=0 .*harvest: 1 sess' && ok "real tool, readable root: exit 0 and the summary shows 1 session read" || bad "healthy real harvest: rc=$rc | $(tail -n 1 "$W/city/.gc/logs/h.log")"
# mutation control: a wrapper that swallows the tool's exit code must be rejected by the missing-root case
sed 's/^exit "\$rc"$/exit 0/' "$WRAP" > "$W/swallow.sh"
if cmp -s "$W/swallow.sh" "$WRAP"; then bad "mutant 'wrapper swallows the exit code': the sed did not change the wrapper - the control is blind"
else
  WRAP_UNDER_TEST="$W/swallow.sh"; case_real_missing_root; unset WRAP_UNDER_TEST
  [ "$MR_RC" -ne 6 ] && ok "mutant 'wrapper swallows the exit code' rejected (the missing-root case saw rc=$MR_RC, not 6)" || bad "mutant survived"
fi
echo; echo "$PASS ok, $FAIL failed"; [ "$FAIL" -eq 0 ]
