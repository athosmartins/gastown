#!/usr/bin/env bash
# hooks-lock-guard.selftest.sh — Regression tests for the hooks-lock-guard (ga-tctky)
# embedded in config-drift-watcher.sh.
#
# Sources config-drift-watcher in lib mode (CONFIG_DRIFT_WATCHER_LIB=1), which
# skips the exec log redirect and the daemon loop, giving us check_hooks_guard
# as a pure function to drive against throwaway temp dirs.
#
# What it pins:
#   1. Clean (empty + uchg) → no remediation, silent return 0 (zero-noise guarantee)
#   2. Hooks dir missing → dir created + uchg applied
#   3. uchg flag missing → uchg re-applied
#   4. Non-empty dir (bd reinstalled hooks) → files removed, dir re-locked
#   5. Worst-case: non-empty + uchg missing → both fixed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WATCHER="$SCRIPT_DIR/config-drift-watcher.sh"

TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hlg-selftest.XXXXXX")" && pwd -P)"
trap 'chflags -R nouchg "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Source as a library, retargeting CITY at the throwaway tree so HOOKS_DIR
# = $TMP/.beads/hooks (no production filesystem touched).
export CONFIG_DRIFT_WATCHER_LIB=1
export CITY="$TMP"
# shellcheck disable=SC1090
source "$WATCHER"

# Sanity-check the seam worked: HOOKS_DIR must point into the temp tree.
if [[ "$HOOKS_DIR" != "$TMP"* ]]; then
    echo "FATAL: HOOKS_DIR=$HOOKS_DIR does not point into TMP=$TMP — lib seam broken" >&2
    exit 2
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  BAD: $*"; }

is_empty() { [ "$(find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; }
is_uchg()  { stat -f '%Sf' "$HOOKS_DIR" 2>/dev/null | grep -q uchg; }

# Reset HOOKS_DIR to a clean (empty + uchg) state.
reset_clean() {
    chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
    rm -rf "$HOOKS_DIR"
    mkdir -p "$HOOKS_DIR"
    chflags uchg "$HOOKS_DIR"
}

# ── Scenario 1: already clean → no action, silent ─────────────────────────────
echo "Scenario 1: clean (empty + uchg) → no remediation, returns 0"
reset_clean
output=$(check_hooks_guard 2>&1)
rc=$?
[ "$rc" -eq 0 ]    && ok "returns 0"              || bad "returned $rc"
[ -z "$output" ]   && ok "silent (no HOOKS-GUARD log)" || bad "unexpected output: $output"
is_empty           && ok "still empty"             || bad "dir unexpectedly modified"
is_uchg            && ok "still uchg-locked"       || bad "uchg flag missing after clean run"

# ── Scenario 2: hooks dir missing → create + lock ─────────────────────────────
echo "Scenario 2: hooks dir missing → created + uchg-locked"
chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
rm -rf "$HOOKS_DIR"
check_hooks_guard >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ]    && ok "returns 0"       || bad "returned $rc"
[ -d "$HOOKS_DIR" ] && ok "dir created"    || bad "dir still missing"
is_empty            && ok "new dir empty"  || bad "new dir non-empty"
is_uchg             && ok "new dir uchg"   || bad "new dir missing uchg"

# ── Scenario 3: uchg flag missing → re-lock ───────────────────────────────────
echo "Scenario 3: uchg missing (unlocked by gc doctor --fix / reinstall) → re-lock"
chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
rm -rf "$HOOKS_DIR"; mkdir -p "$HOOKS_DIR"
# deliberately do NOT set uchg
is_uchg && bad "precondition: should NOT have uchg" || ok "precondition: no uchg (as expected)"
check_hooks_guard >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "returns 0"              || bad "returned $rc"
is_empty        && ok "still empty"             || bad "dir non-empty after remediation"
is_uchg         && ok "uchg flag re-applied"    || bad "uchg still missing"

# ── Scenario 4: non-empty dir (bd reinstalled hooks) → empty + re-lock ────────
echo "Scenario 4: non-empty dir (bd reinstalled hooks) → emptied + re-locked"
chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
rm -rf "$HOOKS_DIR"; mkdir -p "$HOOKS_DIR"
touch "$HOOKS_DIR/on_create" "$HOOKS_DIR/on_update" "$HOOKS_DIR/on_close"
# Lock the dir after inserting files (simulates: bd writes files, then gc locks dir again).
# uchg on the directory allows existing files to be deleted only after chflags nouchg.
chflags uchg "$HOOKS_DIR"
check_hooks_guard >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "returns 0"           || bad "returned $rc"
is_empty        && ok "hook files removed"   || bad "files still present after remediation"
is_uchg         && ok "dir re-locked"        || bad "dir not re-locked after emptying"

# ── Scenario 5: non-empty + uchg missing (worst-case) → empty + lock ──────────
echo "Scenario 5: non-empty + uchg missing (bd fully undid the fix) → emptied + re-locked"
chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
rm -rf "$HOOKS_DIR"; mkdir -p "$HOOKS_DIR"
touch "$HOOKS_DIR/on_create" "$HOOKS_DIR/on_update"
# no chflags uchg — both problems present simultaneously
check_hooks_guard >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "returns 0"           || bad "returned $rc"
is_empty        && ok "hook files removed"   || bad "files still present after remediation"
is_uchg         && ok "dir re-locked"        || bad "dir not locked after remediation"

echo ""
echo "──────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
