#!/usr/bin/env bash
# Selftest wrapper for jev_recomecar_experiment.py, its order wrapper and the report guard it
# depends on (ga-aijm2v.8). Pure python/bash, no network, no real gc/bd/tmux/Jev: seams are
# injected, all state lives in temp dirs. Runs at low priority (renice +15) so it never competes with
# Dolt / the supervisor for CPU.
# Also runs the harness (jev_experiment.py) and the generic report selftest, since the "recomecar"
# rows share their log and the report's mode guard was generalised for them, and the daily-report
# wrapper suite, which now carries the recomecar section (T10-T13).
# Exit: 0 = all pass, non-zero = any failure.
set -uo pipefail
renice -n 15 $$ >/dev/null 2>&1 || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="${JEV_RECOMECAR_SELFTEST_PYTHON:-python3}"
FAIL=0

"$PY" "$SCRIPT_DIR/jev_experiment.py" selftest >/dev/null || { echo "FAIL: jev_experiment.py selftest"; FAIL=1; }
"$PY" "$SCRIPT_DIR/jev_experiment_report.py" selftest >/dev/null || { echo "FAIL: jev_experiment_report.py selftest"; FAIL=1; }
"$PY" "$SCRIPT_DIR/jev_recomecar_experiment.selftest.py" "$@" || FAIL=1
bash "$HQ/packs/town-deltas/assets/tests/jev-daily-report.test.sh" >/dev/null || { echo "FAIL: jev-daily-report.test.sh"; FAIL=1; }

# ── the order wrapper (assets/scripts/jev-recomecar.sh) ─────────────────────────────────────
WRAP="$HQ/packs/town-deltas/assets/scripts/jev-recomecar.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ok()  { echo "  ok   - $1"; }
nok() { echo "  FAIL - $1: $2"; FAIL=1; }
cat >"$T/stub-ok.py" <<'EOF'
#!/usr/bin/env python3
import sys
print('{"rows": 3}' if sys.argv[1:] == ["run"] else "WRONG ARGV %s" % sys.argv[1:])
EOF
cat >"$T/stub-fail.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("boom", file=sys.stderr)
sys.exit(3)
EOF
cat >"$T/stub-hang.py" <<'EOF'
#!/usr/bin/env python3
import time
time.sleep(5)
print("SHOULD NOT PRINT")
EOF
runw() {  # runw <stub> [timeout]; sets RC and OUT
  OUT=$(GC_CITY_PATH="$T" JEV_RECOMECAR_SCRIPT="$1" JEV_RECOMECAR_LOG_FILE="$T/wrap.log" JEV_RECOMECAR_TIMEOUT_S="${2:-30}" bash "$WRAP" 2>&1)
  RC=$?
}
runw "$T/stub-ok.py"
[ "$RC" -eq 0 ] && [ "$OUT" = '{"rows": 3}' ] && ok "wrapper: runs the script with the 'run' subcommand and passes its output and rc through" || nok "wrapper ok" "rc=$RC out=$OUT"
grep -q ' rc=0 {"rows": 3}' "$T/wrap.log" && ok "wrapper: one log line per run with the rc and the script's summary" || nok "wrapper log" "$(cat "$T/wrap.log" 2>&1)"
runw "$T/stub-fail.py"
[ "$RC" -eq 3 ] && grep -q ' rc=3 boom' "$T/wrap.log" && ok "wrapper: a failing script keeps its exit code and the error reaches the log" || nok "wrapper fail" "rc=$RC log=$(cat "$T/wrap.log")"
runw "$T/stub-hang.py" 1
[ "$RC" -eq 124 ] && grep -q 'TIMEOUT after 1s' "$T/wrap.log" && ! grep -q 'SHOULD NOT PRINT' "$T/wrap.log" \
  && ok "wrapper: a hung script is killed by the bound (rc 124, logged as TIMEOUT, never finished)" || nok "wrapper hang" "rc=$RC log=$(cat "$T/wrap.log")"
ORDER="$HQ/packs/town-deltas/orders/jev-recomecar.toml"
grep -q '^trigger = "cooldown"' "$ORDER" && grep -q '^interval = "15m"' "$ORDER" && grep -q 'assets/scripts/jev-recomecar.sh' "$ORDER" \
  && ok "order: cooldown 15m, runs the wrapper" || nok "order" "$(cat "$ORDER")"

if [ "$FAIL" -eq 0 ]; then echo "jev-recomecar selftest: ALL PASS"; else echo "jev-recomecar selftest: FAILURES"; fi
exit "$FAIL"
