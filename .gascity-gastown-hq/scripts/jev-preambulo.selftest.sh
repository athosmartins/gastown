#!/usr/bin/env bash
# Selftest wrapper for jev_preambulo_experiment.py + jev_preambulo_report.py (ga-aijm2v.7).
# Pure python, no network, no real bd/gc/git/Jev: the experiment's single external-call seam is
# faked and state lives in a temp dir. The policy under test is the repo's real manifest + fragment
# (read-only); `pool-preamble-build.py check` runs first because the experiment refuses to run on a
# manifest that fails it. Runs at low priority (renice +15) so it never competes with Dolt / the
# supervisor for CPU. Also runs the modules this one imports (the harness, the gate-verdict front and
# quem-pensa): a break in any of them would break the preambulo run, so it should fail here.
# Exit: 0 = all pass, non-zero = any failure.
set -euo pipefail
renice -n 15 $$ >/dev/null 2>&1 || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JEV_PREAMBULO_SELFTEST_PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1
"$PY" "$SCRIPT_DIR/../packs/town-deltas/assets/pool-preamble-build.py" check >/dev/null
"$PY" "$SCRIPT_DIR/jev_experiment.py" selftest >/dev/null
"$PY" "$SCRIPT_DIR/jev_gate_verdict_experiment.py" selftest >/dev/null
exec "$PY" "$SCRIPT_DIR/jev-preambulo.selftest.py" "$@"
