#!/usr/bin/env bash
# gate-conflict-crash.selftest.sh — Drift-guard for the ga-mzc3h follow-up crash.
#
# Bug: quality-gate-dispatcher.sh runs under `set -euo pipefail`. The conflict-
# handling line built CONFLICT_FILES from a pipeline whose FIRST command,
# `git merge-tree --write-tree`, returns rc=1 on a genuine conflict. `pipefail`
# propagated that non-zero through the pipe, so the bare `CONFLICT_FILES=$(...)`
# assignment tripped `set -e` and SILENTLY killed the dispatcher mid-conflict-
# handling. Because the dispatcher processes the first queued marker each sweep,
# ONE conflicting branch head-of-line-blocked the entire gate (no log, marker
# stuck dispatching, reclaim-thrash to needs-human).
#
# Fix: append `|| true` so the pipeline's non-zero exit can't trip `set -e`
# (matches every other cmdsub-pipeline in the dispatcher).
#
# This harness (1) reproduces the crash class in isolation to prove `|| true`
# is load-bearing, and (2) drift-guards the real line. Exit 0 iff all hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate conflict-crash drift-guard (ga-mzc3h follow-up) ──"

# 1. Reproduce the crash class: an UNGUARDED cmdsub-pipeline whose first command
#    fails MUST kill a `set -euo pipefail` script (proves the bug is real).
unguarded_rc=0
bash -c 'set -euo pipefail; X=$(false 2>/dev/null | tail -n +2 | head -5 | cut -c1-300); echo "$X"' >/dev/null 2>&1 || unguarded_rc=$?
if [ "$unguarded_rc" -ne 0 ]; then
  ok "unguarded conflict-pipeline crashes under set -euo pipefail (rc=$unguarded_rc) — bug is real"
else
  bad "unguarded conflict-pipeline did NOT crash — test environment cannot detect the bug"
fi

# 2. Prove the fix: the SAME pipeline with `|| true` survives.
guarded_rc=0
bash -c 'set -euo pipefail; X=$(false 2>/dev/null | tail -n +2 | head -5 | cut -c1-300 || true); echo "reached:[$X]"' >/dev/null 2>&1 || guarded_rc=$?
if [ "$guarded_rc" -eq 0 ]; then
  ok "guarded conflict-pipeline (|| true) survives under set -euo pipefail"
else
  bad "guarded conflict-pipeline still crashed (rc=$guarded_rc) — || true is not sufficient"
fi

# 3. Drift-guard the real line: the CONFLICT_FILES merge-tree pipeline must end
#    with `|| true` (the assignment spans two lines; join continuations first).
CF_BLOCK="$(awk '/CONFLICT_FILES=\$\(git/{c=1} c{printf "%s ", $0} /cut -c1-300/{if(c){print ""; c=0}}' "$GATE" 2>/dev/null || true)"
if printf '%s' "$CF_BLOCK" | grep -q 'cut -c1-300 || true'; then
  ok "CONFLICT_FILES pipeline is guarded with '|| true'"
else
  bad "CONFLICT_FILES pipeline is NOT guarded with '|| true' (silent-crash regression)"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
