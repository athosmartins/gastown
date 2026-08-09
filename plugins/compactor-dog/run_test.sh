#!/usr/bin/env bash
# Tests for compactor-dog/run.sh helper functions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILURES=0

# Source just the helper functions from run.sh by extracting them.
# We can't source the whole script (it runs immediately), so redefine here.
log() { echo "[test] $*"; }

# --- Copy validate_hash from run.sh (must stay in sync) ---
validate_hash() {
  local hash="$1"
  local context="$2"
  if [[ ! "$hash" =~ ^[a-v0-9]+$ ]]; then
    log "ERROR: Unsafe $context hash rejected: '$hash'"
    return 1
  fi
  return 0
}

# Verify our copy matches run.sh (guard against drift).
# ga-wxwao: -oP (PCRE) -> -oE (POSIX ERE). Found while adding this file's own
# new checks below: this line crashes ("grep: invalid option -- P") the instant
# the script runs as a plain subprocess (`bash run_test.sh`) on stock macOS
# grep, which has no -P support — it only ever appeared to work inside an
# interactive Claude Code shell, whose `grep` is itself a function wrapping
# ugrep (PCRE-capable). Every new assertion appended after this line was
# unreachable without fixing it first. No behavior change: the pattern
# (`\^\[.*\]\+\$` — literal ^, [, ], +, $ with a .* wildcard between) uses no
# PCRE-only construct, so -E produces byte-identical output (verified against
# the real validate_hash source line before switching).
RUN_SH_REGEX=$(sed -n '/^validate_hash/,/^}/p' "$SCRIPT_DIR/run.sh" | grep -oE '\^\[.*\]\+\$')
TEST_REGEX=$(sed -n '/^validate_hash/,/^}/p' "$0" | grep -oE '\^\[.*\]\+\$')
if [[ "$RUN_SH_REGEX" != "$TEST_REGEX" ]]; then
  echo "FAIL: validate_hash regex in test ($TEST_REGEX) doesn't match run.sh ($RUN_SH_REGEX)"
  echo "      Update the test to match run.sh"
  exit 1
fi

assert_valid() {
  local hash="$1"
  if ! validate_hash "$hash" "test" >/dev/null 2>&1; then
    echo "FAIL: expected valid hash: '$hash'"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_invalid() {
  local hash="$1"
  if validate_hash "$hash" "test" >/dev/null 2>&1; then
    echo "FAIL: expected invalid hash: '$hash'"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Tests ---

echo "=== validate_hash tests ==="

# Dolt base32 hashes (real examples)
assert_valid "aecqtmbdbabpalqnamq8atfv86ehjf7r"
assert_valid "0123456789abcdefghijklmnopqrstuv"
assert_valid "abc123"
assert_valid "00000000"

# Hex-only hashes should still pass (subset of base32)
assert_valid "deadbeef"
assert_valid "abcdef0123456789"

# Invalid: characters outside base32 range
assert_invalid "xyz"
assert_invalid "ABCDEF"
assert_invalid "hash-with-dashes"
assert_invalid "hash_with_underscores"
assert_invalid "hash with spaces"
assert_invalid ""
assert_invalid "../../../etc/passwd"
assert_invalid "'; DROP TABLE issues; --"

echo ""
echo "=== ga-wxwao: integrity-failure escalation drift-guards ==="

# ga-wxwao: static checks, not dynamic — the integrity-failure branch lives
# deep inside a real-Dolt compaction loop (dolt_query/dolt_exec against a live
# server) that this file's existing tests don't exercise at all (they only
# cover the validate_hash helper in isolation). Building a full mock-Dolt
# harness for the compaction loop is out of scope for this bead; the CLI
# invocation itself was smoke-tested directly with ESCALATE_DRY_RUN=1 during
# development. What matters here is that the wiring didn't silently drift.
assert_contains_once() {
  local pattern="$1" desc="$2"
  local count
  # `if ! count=$(cmd); then count=0; fi`, not a bare assignment: under this
  # file's `set -euo pipefail`, `grep -c` returning rc=1 on a genuine
  # zero-match regression would otherwise abort the WHOLE script right here,
  # silently, before ever reaching the check below that's supposed to report
  # "FAIL: ...". A test that can only pass, never actually fail-and-report,
  # isn't a test — verified live (this exact assignment shape, this exact
  # flag set, killed a throwaway script with no output at all).
  if ! count=$(grep -c -- "$pattern" "$SCRIPT_DIR/run.sh"); then
    count=0
  fi
  if [[ "$count" -ge 1 ]]; then
    echo "  ok: $desc"
  else
    echo "FAIL: $desc — pattern not found: $pattern"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains_once "escalate_emergency\.py" \
  "integrity-failure branch calls escalate_emergency.py (ga-wxwao case 1 — gt escalate alone never reaches a human, empty contacts in escalation.json)"
assert_contains_once "--class data-security" \
  "escalate_emergency call uses --class data-security (correct sanctioned class for a Dolt integrity failure)"
assert_contains_once 'gt escalate "compactor-dog: integrity failure' \
  "original gt escalate call is PRESERVED alongside the new one (its bead-tracking side effect is still worth keeping — this was an ADD, not a replace)"

echo ""
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES test(s) failed"
  exit 1
else
  echo "PASSED: all tests passed"
fi
