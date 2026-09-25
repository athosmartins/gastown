#!/usr/bin/env bash
# Selftest wrapper for portaria_shadow.py + its report section (ga-aijm2v.4).
# Pure python, no network, no real bd/gc/Jev: seams are injected, state lives in a temp dir.
# Runs at low priority (renice +15) so it never competes with Dolt / the supervisor for CPU.
# Also runs the harness (jev_experiment.py, now with call_jev_multi) and report selftests, since
# the Portaria changes both.
# Exit: 0 = all pass, non-zero = any failure.
set -euo pipefail
renice -n 15 $$ >/dev/null 2>&1 || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PORTARIA_SELFTEST_PYTHON:-python3}"
"$PY" "$SCRIPT_DIR/jev_experiment.py" selftest >/dev/null
"$PY" "$SCRIPT_DIR/jev_experiment_report.py" selftest >/dev/null
exec "$PY" "$SCRIPT_DIR/portaria-shadow.selftest.py" "$@"
