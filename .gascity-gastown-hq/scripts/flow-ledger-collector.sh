#!/usr/bin/env bash
# flow-ledger-collector.sh — per-interval flow snapshot + bead transition recorder (imp04)
#
# PURE OBSERVABILITY. No healing. No Dolt calls on the WRITE path.
# Writes to:
#   .gc/logs/flow-ledger.jsonl  — per-interval snapshots + bead transitions
#
# Per-interval snapshot schema:
#   {"ts":"<ISO8601Z>","kind":"interval_snapshot","dispatched":<N>,"merged":<N>,
#    "refined":<N>,"backlog":<N>}
#
# Per-bead transition line schema (written by other daemons via gc_ledger_append):
#   {"ts":"<ISO8601Z>","kind":"bead_transition","bead_id":"<id>","stage":"<stage>",
#    "from_state":"<state>","to_state":"<state>","actor":"<actor>",
#    "source_daemon":"<daemon>"}
#
# Count method (FAIL-OPEN — an unreadable count = 0, never a fake value injected):
#   dispatched: grep pilot-dispatcher.log for "dispatched=N" (N>0) in window
#   merged:     grep quality-gate-dispatcher.log for "Gate PASSED" in window
#   refined:    grep refino-gate-dispatcher.log for "APPROVED" in window
#   backlog:    NOT read from Dolt — read from pilot-dispatcher.log "candidate(s)"
#               This keeps the write path 100% Dolt-independent.
#
# HARD CONSTRAINTS (from imp04 spec):
#   - set -euo pipefail with define-BEFORE-use
#   - WRITE path never calls bd/gc/dolt
#   - --selftest must pass
#   - Does NOT touch pilot-dispatcher.sh or the painel

set -euo pipefail

# ── config (define ALL vars before use — learned from Pilot crash ga-yx2d1) ──
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC_LEDGER_DIR="${GC_LEDGER_DIR:-${CITY}/.gc/logs}"
LEDGER_NAME="flow-ledger"
POLL_SEC="${FLC_POLL_SEC:-300}"          # 5 min default
WINDOW_SEC="${FLC_WINDOW_SEC:-300}"      # look-back window for counts
FLC_ENABLED="${FLC_ENABLED:-1}"
FLC_DRY_RUN="${FLC_DRY_RUN:-0}"
FLC_LOOP="${FLC_LOOP:-1}"               # set to 0 for one-shot (tests)

PILOT_LOG="${CITY}/.gc/logs/pilot-dispatcher.log"
GATE_LOG="${CITY}/.gc/logs/quality-gate-dispatcher.log"
REFINO_LOG="${CITY}/.gc/logs/refino-gate-dispatcher.log"

NOTIFY="${FLC_NOTIFY:-/Users/athos/.local/bin/notify}"
notify_fail() { "$NOTIFY" -t "Flow Ledger Collector" -p 4 "🚨 $*" 2>/dev/null || true; }

# ── source ledger helper ──────────────────────────────────────────────────────
# shellcheck source=gc-ledger.sh
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_SCRIPT_DIR}/gc-ledger.sh" ]]; then
  # shellcheck disable=SC1091
  source "${_SCRIPT_DIR}/gc-ledger.sh"
else
  echo "[flow-ledger-collector] FATAL: gc-ledger.sh not found in ${_SCRIPT_DIR}" >&2
  notify_fail "flow-ledger-collector: gc-ledger.sh nao encontrado em ${_SCRIPT_DIR} — coletor nao pode iniciar"
  exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────
ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Count log-file lines matching a pattern within the last WINDOW_SEC seconds.
# FAIL-OPEN: returns 0 on any error (log missing, grep fails, etc.)
# Does NOT call bd/gc/dolt. Pure log-file read.
_count_log_pattern() {
  local logfile="$1"
  local pattern="$2"
  local window="${3:-$WINDOW_SEC}"

  # File missing or unreadable → 0 (fail-open)
  [[ -r "$logfile" ]] || { echo 0; return 0; }

  # Build a cutoff timestamp (seconds since epoch) for the window
  local cutoff
  cutoff=$(( $(date -u +%s) - window ))

  local count=0
  local line_ts epoch_ts

  # Scan from the tail (most recent) — break when we exceed the window
  # Lines without ISO timestamp are skipped gracefully
  while IFS= read -r line; do
    # Extract leading ISO timestamp: 2026-06-23T10:00:00Z or [2026-06-23T10:00:00Z]
    line_ts="$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | head -1 || true)"
    [[ -n "$line_ts" ]] || continue

    # Parse epoch (BSD date)
    epoch_ts="$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$line_ts" +%s 2>/dev/null || echo 0)"
    [[ "$epoch_ts" -ge "$cutoff" ]] || continue

    # Pattern match
    if echo "$line" | grep -qE "$pattern" 2>/dev/null; then
      count=$((count+1))
    fi
  done < <(tail -2000 "$logfile" 2>/dev/null || true)

  echo "$count"
}

# Extract the most recent "N candidate(s)" backlog count from pilot log.
# Returns 0 on any failure.
_read_pilot_backlog() {
  [[ -r "$PILOT_LOG" ]] || { echo 0; return 0; }
  local last_candidates
  last_candidates="$(tail -2000 "$PILOT_LOG" 2>/dev/null \
    | grep -oE '[0-9]+ candidate\(s\)' \
    | tail -1 \
    | grep -oE '^[0-9]+' \
    || echo 0)"
  echo "${last_candidates:-0}"
}

# ── snapshot writer ───────────────────────────────────────────────────────────
write_snapshot() {
  local ts
  ts="$(ts_now)"

  # Count from log files — NEVER from Dolt
  local dispatched merged refined backlog
  dispatched="$(_count_log_pattern "$PILOT_LOG" 'dispatched=[1-9]')"
  merged="$(_count_log_pattern "$GATE_LOG" 'Gate PASSED')"
  refined="$(_count_log_pattern "$REFINO_LOG" 'APPROVED')"
  backlog="$(_read_pilot_backlog)"

  local json
  json="$(printf '{"ts":"%s","kind":"interval_snapshot","dispatched":%s,"merged":%s,"refined":%s,"backlog":%s}' \
    "$ts" "$dispatched" "$merged" "$refined" "$backlog")"

  if [[ "$FLC_DRY_RUN" == "1" ]]; then
    echo "[flow-ledger-collector] DRY-RUN: would append: $json" >&2
    return 0
  fi

  gc_ledger_append "$LEDGER_NAME" "$json" || {
    echo "[flow-ledger-collector] WARN: ledger write failed (continuing)" >&2
    notify_fail "flow-ledger-collector: falha ao escrever no ledger (snapshot perdido, coletor continua)"
  }
}

# ── main loop ─────────────────────────────────────────────────────────────────
run_loop() {
  if [[ "$FLC_ENABLED" != "1" ]]; then
    echo "[flow-ledger-collector] disabled (FLC_ENABLED!=1)" >&2
    return 0
  fi

  echo "[flow-ledger-collector] started. POLL_SEC=$POLL_SEC WINDOW_SEC=$WINDOW_SEC" >&2

  while true; do
    write_snapshot || true
    if [[ "$FLC_LOOP" != "1" ]]; then
      break
    fi
    sleep "$POLL_SEC"
  done
}

# ── selftest ──────────────────────────────────────────────────────────────────
_selftest() {
  local PASS=0 FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

  local TMP
  TMP="$(mktemp -d)"
  _FLC_SELFTEST_TMP="$TMP"
  trap 'rm -rf "${_FLC_SELFTEST_TMP:-}"' EXIT

  export GC_LEDGER_DIR="$TMP/logs"
  export FLC_DRY_RUN="0"
  export FLC_LOOP="0"
  export FLC_ENABLED="1"
  export WINDOW_SEC="3600"   # broad window for test log fixtures

  NOTIFY_LOG="$TMP/notify.log"
  cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
  chmod +x "$TMP/notify"
  export NOTIFY="$TMP/notify"

  echo "=== flow-ledger-collector.sh --selftest ==="

  # Create fake log files with matching patterns
  mkdir -p "$TMP/logs"
  PILOT_LOG="$TMP/logs/pilot-dispatcher.log"
  GATE_LOG="$TMP/logs/quality-gate-dispatcher.log"
  REFINO_LOG="$TMP/logs/refino-gate-dispatcher.log"

  local NOW
  NOW="$(ts_now)"

  # T1: dispatched count from pilot log
  printf '%s Pilot sweep complete: dispatched=3 (tier=approved)\n' "$NOW" >> "$PILOT_LOG"
  printf '%s Pilot sweep complete: dispatched=0\n' "$NOW" >> "$PILOT_LOG"
  printf '%s Pilot sweep complete: dispatched=1\n' "$NOW" >> "$PILOT_LOG"
  local d_count
  d_count="$(_count_log_pattern "$PILOT_LOG" 'dispatched=[1-9]')"
  if [[ "$d_count" == "2" ]]; then
    ok "T1: dispatched count = 2 (ignores dispatched=0)"
  else
    bad "T1: expected dispatched=2, got $d_count"
  fi

  # T2: merged count from gate log
  printf '%s Gate PASSED for wa-abc1\n' "$NOW" >> "$GATE_LOG"
  printf '%s Gate PASSED for ga-xyz2\n' "$NOW" >> "$GATE_LOG"
  local m_count
  m_count="$(_count_log_pattern "$GATE_LOG" 'Gate PASSED')"
  if [[ "$m_count" == "2" ]]; then
    ok "T2: merged count = 2"
  else
    bad "T2: expected merged=2, got $m_count"
  fi

  # T3: refined count from refino log
  printf '%s APPROVED wa-def3\n' "$NOW" >> "$REFINO_LOG"
  local r_count
  r_count="$(_count_log_pattern "$REFINO_LOG" 'APPROVED')"
  if [[ "$r_count" == "1" ]]; then
    ok "T3: refined count = 1"
  else
    bad "T3: expected refined=1, got $r_count"
  fi

  # T4: backlog from pilot log candidates
  printf '%s Dispatch tier: approved (5 candidate(s)) free_slots=3\n' "$NOW" >> "$PILOT_LOG"
  local b_count
  b_count="$(_read_pilot_backlog)"
  if [[ "$b_count" == "5" ]]; then
    ok "T4: backlog extracted from pilot log candidates"
  else
    bad "T4: expected backlog=5, got $b_count"
  fi

  # T5: fail-open on missing log → returns 0
  local missing_count
  missing_count="$(_count_log_pattern "/nonexistent/path.log" 'pattern')"
  if [[ "$missing_count" == "0" ]]; then
    ok "T5: missing log file → fail-open returns 0"
  else
    bad "T5: expected 0 from missing log, got $missing_count"
  fi

  # T6: write_snapshot produces a valid JSON line in the ledger
  write_snapshot
  local ledger_file="$TMP/logs/flow-ledger.jsonl"
  if [[ -f "$ledger_file" ]]; then
    ok "T6a: flow-ledger.jsonl created"
  else
    bad "T6a: flow-ledger.jsonl not created"
  fi
  local snapshot_line
  snapshot_line="$(tail -1 "$ledger_file" 2>/dev/null || echo '')"
  if python3 -c "import json; d=json.loads('$snapshot_line'); assert d['kind']=='interval_snapshot'" 2>/dev/null; then
    ok "T6b: snapshot line parses as JSON with kind=interval_snapshot"
  else
    bad "T6b: snapshot line is not valid interval_snapshot JSON: $snapshot_line"
  fi

  # T7: snapshot has all required fields
  if python3 -c "
import json
d = json.loads(open('$ledger_file').readlines()[-1])
required = {'ts','kind','dispatched','merged','refined','backlog'}
missing = required - d.keys()
assert not missing, f'missing: {missing}'
print('fields:', list(d.keys()))
" 2>/dev/null; then
    ok "T7: snapshot has all required fields (ts,kind,dispatched,merged,refined,backlog)"
  else
    bad "T7: snapshot missing required fields"
  fi

  # T8: DRY_RUN mode writes nothing to disk
  export FLC_DRY_RUN="1"
  local before_size
  before_size="$(wc -l < "$ledger_file" | tr -d ' ')"
  write_snapshot
  local after_size
  after_size="$(wc -l < "$ledger_file" | tr -d ' ')"
  if [[ "$before_size" == "$after_size" ]]; then
    ok "T8: DRY_RUN=1 → no new line written"
  else
    bad "T8: DRY_RUN=1 wrote unexpectedly ($before_size→$after_size lines)"
  fi
  export FLC_DRY_RUN="0"

  # T9: ledger write failure → must notify (ga-4zpf), not silently swallow
  : > "$NOTIFY_LOG"
  gc_ledger_append() { return 1; }  # force a write failure
  write_snapshot
  if grep -qi 'flow-ledger-collector' "$NOTIFY_LOG" 2>/dev/null; then
    ok "T9: ledger write failure → notified (ga-4zpf)"
  else
    bad "T9: ledger write failure did NOT notify — silent data loss (ga-4zpf regression)"
  fi

  # T10: gc-ledger.sh missing at startup → must notify (ga-4zpf). This FATAL check runs
  # at top-level script load, before _selftest is reachable, so exercise it via a real
  # subprocess in an isolated dir that lacks the sibling gc-ledger.sh.
  : > "$NOTIFY_LOG"
  local ISO_TMP; ISO_TMP="$(mktemp -d)"
  cp "${BASH_SOURCE[0]}" "$ISO_TMP/flow-ledger-collector.sh"
  FLC_NOTIFY="$TMP/notify" bash "$ISO_TMP/flow-ledger-collector.sh" --once >/dev/null 2>&1 || true
  if grep -qi 'gc-ledger' "$NOTIFY_LOG" 2>/dev/null; then
    ok "T10: gc-ledger.sh missing at startup → notified (ga-4zpf)"
  else
    bad "T10: gc-ledger.sh missing did NOT notify — silent startup failure (ga-4zpf regression)"
  fi
  rm -rf "$ISO_TMP"

  echo ""
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  [[ "$FAIL" == "0" ]]
}

# ── entry point ───────────────────────────────────────────────────────────────
case "${1:-}" in
  --selftest) _selftest; exit $? ;;
  --once)     FLC_LOOP=0 run_loop ;;
  --dry-run)  FLC_DRY_RUN=1 FLC_LOOP=0 run_loop ;;
  "")         run_loop ;;
  *) echo "Usage: flow-ledger-collector.sh [--selftest|--once|--dry-run]" >&2; exit 1 ;;
esac
