#!/usr/bin/env bash
# Selftest wrapper for jev_preambulo_claim.py (ga-aijm2v.13), the claim-time loader of the per-task preamble.
# Pure python, no network, no real bd/gc/git/Jev: Jev and the bead read are injected fakes and the record goes to a
# temp file. The policy under test is the repo's real manifest + fragment (read-only); `pool-preamble-build.py check`
# runs first because the loader refuses to decide on a manifest that fails it. Also runs the modules the loader
# imports (the harness and the gate-verdict front): a break in either would break the loader. Runs at low priority
# (renice +15) so it never competes with Dolt / the supervisor for CPU.
# Exit: 0 = all pass, non-zero = any failure.
set -euo pipefail
renice -n 15 $$ >/dev/null 2>&1 || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${JEV_PREAMBULO_SELFTEST_PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1
"$PY" "$SCRIPT_DIR/../packs/town-deltas/assets/pool-preamble-build.py" check >/dev/null
"$PY" "$SCRIPT_DIR/jev_experiment.py" selftest >/dev/null
"$PY" "$SCRIPT_DIR/jev_gate_verdict_experiment.py" selftest >/dev/null
exec "$PY" "$SCRIPT_DIR/jev-preambulo-claim.selftest.py" "$@"
