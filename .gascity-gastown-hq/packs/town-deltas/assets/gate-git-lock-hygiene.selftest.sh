#!/usr/bin/env bash
# gate-git-lock-hygiene.selftest.sh — Drift-guard for the imp18 gate dispatcher
# integration: per-repo git mutex acquisition + release around auto-rebase.
# Also verifies git-lock-hygiene.sh is present and passes its own selftest.
# Exit 0 = pass.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# assets/ → town-deltas/ → packs/ → .gascity-gastown-hq/
HQ_DIR="$(cd "$SELF_DIR/../../../" && pwd -P)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GLH="${HQ_DIR}/scripts/git-lock-hygiene.sh"
DPW="${HQ_DIR}/scripts/daemon-presence-watchdog.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qE "$2" "$1" && ok "$3" || bad "$3 — pattern not found: $2"; }
not() { grep -qE "$2" "$1" && bad "$3 — unexpected pattern found: $2" || ok "$3"; }

echo "── 1. git-lock-hygiene.sh present and passes selftest ──"
if [ -f "$GLH" ]; then
  ok "git-lock-hygiene.sh exists"
  if bash "$GLH" --selftest >/dev/null 2>&1; then
    ok "git-lock-hygiene.sh --selftest PASS"
  else
    bad "git-lock-hygiene.sh --selftest FAILED"
  fi
else
  bad "git-lock-hygiene.sh NOT FOUND at $GLH"
fi

echo "── 2. gate dispatcher syntax ──"
bash -n "$DISPATCHER" && ok "dispatcher passes bash -n" || bad "dispatcher bash -n FAILED"

echo "── 3. imp18 source integration in dispatcher ──"
# The lib is sourced via a variable (_GLH_SCRIPT) defined on the preceding line.
# Check for the variable definition containing the script name.
has "$DISPATCHER" \
  '_GLH_SCRIPT.*git-lock-hygiene' \
  "dispatcher defines _GLH_SCRIPT pointing to git-lock-hygiene (imp18)"
has "$DISPATCHER" \
  'GIT_LOCK_HYGIENE_LIB=1' \
  "dispatcher sets GIT_LOCK_HYGIENE_LIB=1 before sourcing (imp18)"

echo "── 4. imp18 mutex acquire in auto-rebase path ──"
has "$DISPATCHER" \
  'git_mutex_acquire.*RIG_PATH' \
  "dispatcher calls git_mutex_acquire for RIG_PATH (imp18)"

has "$DISPATCHER" \
  '_REBASE_MUTEX_HELD=1' \
  "dispatcher tracks mutex held flag (imp18)"

echo "── 5. imp18 mutex release after auto-rebase ──"
has "$DISPATCHER" \
  'git_mutex_release.*RIG_PATH' \
  "dispatcher releases per-repo mutex after rebase (imp18)"

echo "── 6. imp18 mutex-busy path sets transient ──"
has "$DISPATCHER" \
  'per-repo git mutex held.*imp18' \
  "mutex-busy fallback sets transient CONFLICT_FILES (imp18)"

has "$DISPATCHER" \
  'CONFLICT_KIND="transient"' \
  "CONFLICT_KIND=transient set in at least one path (covers imp18 mutex-busy)"

echo "── 7. DPW_CRITICAL includes git-lock-hygiene ──"
if [ -f "$DPW" ]; then
  has "$DPW" \
    'com\.gascity\.git-lock-hygiene' \
    "daemon-presence-watchdog DPW_CRITICAL includes git-lock-hygiene (imp18)"
else
  bad "daemon-presence-watchdog.sh not found"
fi

echo "── 8. drift-guard: existing imp22 clean-tree guard preserved ──"
has "$DISPATCHER" \
  'imp22' \
  "imp22 references still present (clean-tree guard not removed)"

has "$DISPATCHER" \
  'index\.lock' \
  "imp22 clean-tree guard still checks index.lock"

echo ""
echo "────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "  RESULT: PASS" && exit 0 || { echo "  RESULT: FAIL"; exit 1; }
