#!/usr/bin/env bash
# pilot-sweep-pause-state.selftest.sh (ga-nq0jo)
#
# Proves _pilot_write_sweep_pause_state() in pilot-dispatcher.sh — the writer
# half of the fix that stops approved-state-reconciler.py from alarming
# "dispatch path failing" on a bead that's healthy, front-of-queue, and
# simply caught in a sweep the Pilot deliberately paused (quota-limited
# ga-x3nmz, cross-stage yield ga-d0hz3). See the reconciler's own --selftest
# scenarios (ga-nq0jo-a..d) for the READER half; this file only covers the
# WRITER, extracted via its own SELFTEST-EXTRACT sentinel so this is never a
# hand-copied duplicate of the live function.
#
# REAL BUG CAUGHT WRITING THIS TEST (worth recording): the first version used
# `jq --argjson active "$_active"` with a bash "1"/"0" string, which jq
# parses as the JSON INTEGER 1/0, not a JSON BOOLEAN. The reconciler's Python
# side checks `.get("active") is not True` — an IDENTITY check — which never
# matches the integer 1 (1 is not True in Python, despite 1 == True). This
# was invisible to Python-only unit tests using hand-authored dicts with real
# Python `True`/`False` literals; only a real cross-language (bash → JSON →
# Python) functional test surfaced it. Fixed: `--arg active_raw "$_active"`
# + `($active_raw == "1")` inside the jq filter, producing a genuine boolean
# regardless of what the caller passes.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== pilot-sweep-pause-state.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

BLOCK="$(extract_block "$DISPATCHER" "pilot-write-sweep-pause-state")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: SELFTEST-EXTRACT pilot-write-sweep-pause-state block not found in $DISPATCHER" >&2
  exit 2
fi

warn() { echo "WARN: $*" >&2; }   # stub — the real one lives earlier in pilot-dispatcher.sh
eval "$BLOCK"
if ! declare -F _pilot_write_sweep_pause_state >/dev/null 2>&1; then
  echo "FATAL: extracted block did not define _pilot_write_sweep_pause_state" >&2
  exit 2
fi

TESTFILE="$(mktemp /tmp/nq0jo-sweep-pause-selftest.XXXXXX)"
trap 'rm -f "$TESTFILE"' EXIT

echo "S1: active=1 writes a genuine JSON BOOLEAN true (not the integer 1 — THE bug this test exists to catch)"
PILOT_SWEEP_PAUSE_STATE_FILE="$TESTFILE"
_pilot_write_sweep_pause_state 1 "cross-stage-yield" "gate_congested=1 quota_limited=0 dolt_hot=1"
if command -v python3 >/dev/null 2>&1; then
  _py_check=$(python3 -c "
import json
d = json.load(open('$TESTFILE'))
print('OK' if d.get('active') is True else 'FAIL:%r' % (d.get('active'),))
" 2>&1)
  if [ "$_py_check" = "OK" ]; then
    ok "active=1 -> JSON true, Python parses as real bool True (not the integer 1)"
  else
    bad "active=1 -> $_py_check (expected Python True; a bare jq --argjson of a bash '1' string produces the JSON integer 1, which Python's 'is True' identity check never matches)"
  fi
else
  # jq-only fallback check: the literal string "true" (unquoted) must appear,
  # not "1" — a weaker check than the Python identity test above but still
  # catches the exact regression if python3 is unavailable.
  if grep -q '"active": true' "$TESTFILE"; then
    ok "active=1 -> JSON true (jq-only check; python3 unavailable for the stronger identity check)"
  else
    bad "active=1 -> $(cat "$TESTFILE") (expected literal JSON true)"
  fi
fi

echo "S2: active=0 writes JSON boolean false"
_pilot_write_sweep_pause_state 0 "" ""
if grep -q '"active": false' "$TESTFILE"; then
  ok "active=0 -> JSON false"
else
  bad "active=0 -> $(cat "$TESTFILE") (expected literal JSON false)"
fi

echo "S3: reason and detail round-trip through jq unescaped/unmangled"
_pilot_write_sweep_pause_state 1 "cross-stage-yield" 'gate_congested=1 quota_limited=0 dolt_hot=1'
if command -v python3 >/dev/null 2>&1; then
  _py_check=$(python3 -c "
import json
d = json.load(open('$TESTFILE'))
ok = d.get('reason') == 'cross-stage-yield' and 'gate_congested=1' in (d.get('detail') or '')
print('OK' if ok else 'FAIL:%r' % (d,))
" 2>&1)
  if [ "$_py_check" = "OK" ]; then
    ok "reason/detail fields round-trip correctly"
  else
    bad "reason/detail round-trip -> $_py_check"
  fi
fi

echo "S4: write is atomic (no partial/tmp file left behind on success)"
if [ ! -e "${TESTFILE}.tmp."* ] 2>/dev/null; then
  ok "no leftover .tmp.* file after a successful write"
else
  bad "leftover tmp file(s) found: ${TESTFILE}.tmp.*"
fi

echo "S5: write is non-fatal when the target directory cannot be created (fail-open, never aborts the sweep)"
_UNWRITABLE_PARENT="$(mktemp -d /tmp/nq0jo-unwritable.XXXXXX)"
chmod 000 "$_UNWRITABLE_PARENT" 2>/dev/null
PILOT_SWEEP_PAUSE_STATE_FILE="$_UNWRITABLE_PARENT/nested/pilot-sweep-pause-state.json"
_out=$(_pilot_write_sweep_pause_state 1 "test" "test" 2>&1)
_rc=$?
chmod 755 "$_UNWRITABLE_PARENT" 2>/dev/null
rm -rf "$_UNWRITABLE_PARENT" 2>/dev/null
if [ "$_rc" -eq 0 ]; then
  ok "unwritable target directory: function still returns 0 (fail-open, never aborts the calling sweep)"
else
  bad "unwritable target directory: function returned non-zero ($_rc) — a write failure must never propagate as a sweep-aborting error"
fi

echo ""; echo "pilot-sweep-pause-state.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
