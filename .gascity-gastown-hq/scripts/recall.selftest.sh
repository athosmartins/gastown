#!/usr/bin/env bash
# recall.selftest.sh -- runs test_recall.py under the recall-venv (ga-ps28g).
# Hermetic: no live bd/Dolt/network calls (see test_recall.py docstring).
set -euo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
VENV_PY="$CITY/.gc/recall-venv/bin/python3"
SCRIPTS_DIR="$CITY/scripts"

if [ ! -x "$VENV_PY" ]; then
  echo "recall.selftest: venv not found at $VENV_PY (see recall-requirements.txt for setup)" >&2
  exit 1
fi

cd "$SCRIPTS_DIR"
exec "$VENV_PY" -m unittest test_recall -v
