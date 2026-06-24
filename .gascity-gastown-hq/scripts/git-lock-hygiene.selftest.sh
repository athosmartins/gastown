#!/usr/bin/env bash
# git-lock-hygiene.selftest.sh — standalone regression harness for imp18
# Delegates to the --selftest flag built into git-lock-hygiene.sh.
# Exit 0 = pass.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/git-lock-hygiene.sh" --selftest "$@"
