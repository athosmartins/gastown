#!/usr/bin/env bash
# Selftest wrapper for jev_quem_pensa_experiment.py + jev_quem_pensa_report.py (ga-aijm2v.9).
# Pure python, no network, no real bd/gc/git/Jev: the experiment's single external-call seam is
# faked and state lives in a temp dir. Runs at low priority (renice +15) so it never competes with
# Dolt / the supervisor for CPU. Also runs the two modules this one imports (the harness and the
# gate-verdict front): a break in either would break the quem-pensa run, so it should fail here.
# Exit: 0 = all pass, non-zero = any failure.
set -euo pipefail
renice -n 15 $$ >/dev/null 2>&1 || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JEV_QUEM_PENSA_SELFTEST_PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1
"$PY" "$SCRIPT_DIR/jev_experiment.py" selftest >/dev/null
"$PY" "$SCRIPT_DIR/jev_gate_verdict_experiment.py" selftest >/dev/null
exec "$PY" "$SCRIPT_DIR/jev-quem-pensa.selftest.py" "$@"
