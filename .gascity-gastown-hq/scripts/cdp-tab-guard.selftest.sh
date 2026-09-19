#!/usr/bin/env bash
# Selftest wrapper for cdp-tab-guard.py (ga-w7rcut).
#
# Runs cdp-tab-guard.selftest.py: pure-logic tests plus end-to-end tests against a REAL
# throwaway headless Chrome on a private port (default 9333, private --user-data-dir).
# The production Chrome (:9222) is never contacted. Needs /Applications/Google Chrome.app.
# Takes a few minutes on a loaded machine (each end-to-end test opens ~260 MB pages).
#
# Optional: CDP_TAB_GUARD_SELFTEST_PORT=<port>, CDP_TAB_GUARD_SELFTEST_SHOW_LOG=1 (print the
# guard's log per test), CDP_TAB_GUARD_UNDER_TEST=<path> (run the suite against another copy
# of the guard — used for mutation checks).
#
# Exit: 0 = all pass, non-zero = any failure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${CDP_TAB_GUARD_SELFTEST_PYTHON:-/opt/homebrew/bin/python3}"
[ -x "$PY" ] || PY="$(command -v python3)"
exec "$PY" "$SCRIPT_DIR/cdp-tab-guard.selftest.py" "$@"
