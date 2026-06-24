#!/usr/bin/env bash
# gc-ledger.sh — shared append-only JSONL ledger helper (imp04)
#
# Provides ONE public function + a standalone entry point:
#   gc_ledger_append <ledger-name> <json-string>
#
# ATOMICITY: each call does exactly ONE O_APPEND write (bash printf + fd redirect).
# A single write to a pipe-backed file descriptor is atomic up to PIPE_BUF bytes on
# POSIX (4096+ bytes). JSON ledger lines are well under that limit. No lock files.
# No partial lines possible from concurrent callers.
#
# DOLT-INDEPENDENT: NEVER calls bd, gc, dolt, or any network service.
# FAIL-OPEN: if the log dir cannot be created or written, the function returns 1
# but never aborts the caller (callers should use || true when desired).
#
# LEDGER DIR selection (stable — imp02/imp24/imp25 rely on this):
#   Always: /Users/athos/gt/.gascity-gastown-hq/.gc/logs/
#   (The .gc/logs dir is the canonical city logs dir, used by every daemon.)
#
# Usage:
#   source gc-ledger.sh
#   gc_ledger_append flow-ledger '{"ts":"2026-06-23T10:00:00Z","event":"test"}'
#
# Or as a standalone binary:
#   gc-ledger.sh flow-ledger '{"ts":"2026-06-23T10:00:00Z","event":"test"}'
#   gc-ledger.sh --selftest
#
# Stable names (imp02/imp24/imp25 import by these):
#   bash function: gc_ledger_append
#   bash entry:    gc-ledger.sh <ledger-name> <json-string>
#   ledger dir:    GC_LEDGER_DIR (default below)

set -uo pipefail

# ── config ───────────────────────────────────────────────────────────────────
GC_LEDGER_DIR="${GC_LEDGER_DIR:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs}"

# ── public function ──────────────────────────────────────────────────────────
# gc_ledger_append <ledger-name> <json-string>
#   ledger-name: base filename, e.g. "flow-ledger"  →  flow-ledger.jsonl
#   json-string: a single valid JSON object (must be one line, no embedded newlines)
#   Returns: 0 on success, 1 on error (writes error to stderr, never aborts caller)
gc_ledger_append() {
  local ledger_name="${1:-}"
  local json_line="${2:-}"

  if [[ -z "$ledger_name" ]] || [[ -z "$json_line" ]]; then
    echo "[gc-ledger] ERROR: usage: gc_ledger_append <ledger-name> <json-string>" >&2
    return 1
  fi

  # Remove any embedded newlines — each ledger line MUST be one line
  json_line="${json_line//$'\n'/ }"
  json_line="${json_line//$'\r'/ }"

  local ledger_file="${GC_LEDGER_DIR}/${ledger_name}.jsonl"

  # Ensure dir exists (fail gracefully)
  if ! mkdir -p "$GC_LEDGER_DIR" 2>/dev/null; then
    echo "[gc-ledger] ERROR: cannot create ledger dir: $GC_LEDGER_DIR" >&2
    return 1
  fi

  # Single atomic O_APPEND write: printf produces exactly one \n-terminated line.
  # On macOS/Linux, a single write() to an O_APPEND fd is atomic for any write
  # ≤ PIPE_BUF (typically 65536 bytes). JSON lines are always well under this.
  if ! printf '%s\n' "$json_line" >> "$ledger_file" 2>/dev/null; then
    echo "[gc-ledger] ERROR: cannot write to ledger: $ledger_file" >&2
    return 1
  fi

  return 0
}

# ── standalone entry point ───────────────────────────────────────────────────
_gc_ledger_main() {
  if [[ "${1:-}" == "--selftest" ]]; then
    _gc_ledger_selftest
    return $?
  fi

  if [[ $# -lt 2 ]]; then
    echo "Usage: gc-ledger.sh <ledger-name> <json-string>" >&2
    echo "       gc-ledger.sh --selftest" >&2
    exit 1
  fi

  gc_ledger_append "$1" "$2"
}

# ── selftest ─────────────────────────────────────────────────────────────────
_gc_ledger_selftest() {
  local PASS=0 FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

  local TMP
  TMP="$(mktemp -d)"
  # Use a non-local name in the trap to avoid set -u complaints after function return
  _GC_LEDGER_SELFTEST_TMP="$TMP"
  trap 'rm -rf "${_GC_LEDGER_SELFTEST_TMP:-}"' EXIT

  export GC_LEDGER_DIR="$TMP/ledgers"

  echo "=== gc-ledger.sh --selftest ==="

  # T1: basic append creates file + line is valid JSON
  local line1='{"ts":"2026-06-23T10:00:00Z","event":"test","val":1}'
  gc_ledger_append "test-ledger" "$line1"
  local f="$TMP/ledgers/test-ledger.jsonl"
  if [[ -f "$f" ]]; then
    ok "T1a: ledger file created"
  else
    bad "T1a: ledger file not created"
  fi
  if python3 -c "import json,sys; json.loads(open('$f').read().strip())" 2>/dev/null; then
    ok "T1b: line parses as JSON"
  else
    bad "T1b: line does not parse as JSON"
  fi

  # T2: second append → exactly 2 lines
  local line2='{"ts":"2026-06-23T10:00:01Z","event":"test","val":2}'
  gc_ledger_append "test-ledger" "$line2"
  local count
  count="$(wc -l < "$f" | tr -d ' ')"
  if [[ "$count" == "2" ]]; then
    ok "T2: two lines after two appends"
  else
    bad "T2: expected 2 lines, got $count"
  fi

  # T3: each line is independently valid JSON (JSONL format)
  local bad_lines=0
  while IFS= read -r ln; do
    python3 -c "import json; json.loads('$ln')" 2>/dev/null || bad_lines=$((bad_lines+1))
  done < "$f"
  if [[ "$bad_lines" == "0" ]]; then
    ok "T3: all lines parse as JSON (JSONL valid)"
  else
    bad "T3: $bad_lines line(s) fail JSON parse"
  fi

  # T4: different ledger → separate file
  gc_ledger_append "other-ledger" '{"ts":"2026-06-23T10:00:02Z","event":"other"}'
  if [[ -f "$TMP/ledgers/other-ledger.jsonl" ]]; then
    ok "T4: separate ledger name → separate file"
  else
    bad "T4: separate file not created"
  fi

  # T5: embedded newline stripped (no partial-line risk)
  local multiline
  multiline="$(printf '{"ts":"2026-06-23T10:00:03Z","msg":"line1\nline2"}')"
  gc_ledger_append "newline-test" "$multiline"
  local nl_count
  nl_count="$(wc -l < "$TMP/ledgers/newline-test.jsonl" | tr -d ' ')"
  if [[ "$nl_count" == "1" ]]; then
    ok "T5: embedded newlines stripped → exactly 1 line"
  else
    bad "T5: embedded newline not stripped (got $nl_count lines)"
  fi

  # T6: missing args returns non-zero
  if gc_ledger_append "" "" 2>/dev/null; then
    bad "T6: should fail on empty args"
  else
    ok "T6: empty args returns non-zero"
  fi

  # T7: concurrent writes (10 parallel appends) → 10 lines, all valid JSON
  local cledger="concurrent-test"
  for i in $(seq 1 10); do
    gc_ledger_append "$cledger" "{\"ts\":\"2026-06-23T10:00:0${i}Z\",\"seq\":$i}" &
  done
  wait
  local cfile="$TMP/ledgers/${cledger}.jsonl"
  local ccount
  ccount="$(wc -l < "$cfile" | tr -d ' ')"
  if [[ "$ccount" == "10" ]]; then
    ok "T7a: concurrent appends → correct line count (10)"
  else
    bad "T7a: concurrent appends → expected 10 lines, got $ccount"
  fi
  local cbad=0
  while IFS= read -r ln; do
    python3 -c "import json; json.loads('$ln')" 2>/dev/null || cbad=$((cbad+1))
  done < "$cfile"
  if [[ "$cbad" == "0" ]]; then
    ok "T7b: all concurrent lines parse as JSON (no partial writes)"
  else
    bad "T7b: $cbad partial/invalid lines from concurrent writes"
  fi

  echo ""
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  [[ "$FAIL" == "0" ]]
}

# ── run if executed directly (not sourced) ───────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _gc_ledger_main "$@"
fi
