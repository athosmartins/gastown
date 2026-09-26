#!/bin/bash
# scratchpad-sweep.selftest.sh (ga-hynohs) — the wrapper, its order file, and the whole
# chain wrapper → scratchpad-reaper.sh → safe-clean against a fixture root.
#
# Hermetic: the reaper's root is a throwaway dir under /private/tmp/claude-selftest-*
# (a name safe-clean's allowlist recognises, and never the real /private/tmp/claude-<uid>),
# `gc` and `ps` are fakes, the log and the lock are throwaway paths. Nothing real is read
# or deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$HERE/../.." && pwd)"                 # .../packs/town-deltas
WRAPPER="$HERE/scratchpad-sweep.sh"
ORDER="$PACK/orders/scratchpad-sweep.toml"
REAPER="$(cd "$PACK/../.." && pwd)/scripts/scratchpad-reaper.sh"
SAFE_CLEAN_PY="$HERE/safe-clean.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d /tmp/scratchpad-sweep-selftest.XXXXXX)"
CHAIN_ROOT="/private/tmp/claude-selftest-sweep-$$"
trap 'rm -rf "$WORK" "$CHAIN_ROOT"' EXIT

echo "=== scratchpad-sweep.selftest.sh ==="

echo ""
echo "=== wrapper: what it hands to the reaper ==="
cat > "$WORK/stub-reaper.sh" <<'EOF'
#!/bin/bash
echo "PROD=${SCRATCHPAD_REAPER_PROD-unset} IDLE=${SCRATCHPAD_REAPER_MIN_IDLE_MINUTES-unset}"
exit "${STUB_EXIT:-0}"
EOF
out="$(SCRATCHPAD_SWEEP_REAPER="$WORK/stub-reaper.sh" bash "$WRAPPER" 2>&1)"
[ "$out" = "PROD=1 IDLE=30" ] && ok "wrapper: sets the production opt-in and a 30-minute idle gate" || bad "wrapper env wrong: '$out'"
out="$(SCRATCHPAD_SWEEP_MIN_IDLE_MINUTES=45 SCRATCHPAD_SWEEP_REAPER="$WORK/stub-reaper.sh" bash "$WRAPPER" 2>&1)"
[ "$out" = "PROD=1 IDLE=45" ] && ok "wrapper: the idle gate is overridable (SCRATCHPAD_SWEEP_MIN_IDLE_MINUTES)" || bad "wrapper override wrong: '$out'"
STUB_EXIT=7 SCRATCHPAD_SWEEP_REAPER="$WORK/stub-reaper.sh" bash "$WRAPPER" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "wrapper: the reaper's exit code is the wrapper's (a failed cycle stays visible to the order runner)" || bad "wrapper swallowed the reaper's exit code (rc=$rc)"
err="$(SCRATCHPAD_SWEEP_REAPER="$WORK/does-not-exist.sh" bash "$WRAPPER" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q "not found"; } && ok "wrapper: a missing reaper is a FAILED sweep (nonzero + stderr), not a quiet success" || bad "wrapper: missing reaper mishandled (rc=$rc err='$err')"

echo ""
echo "=== order file ==="
[ -f "$ORDER" ] && ok "order: $ORDER exists" || bad "order file missing"
trigger="$(sed -n 's/^trigger *= *"\(.*\)"/\1/p' "$ORDER")"
interval="$(sed -n 's/^interval *= *"\(.*\)"/\1/p' "$ORDER")"
timeout_s="$(sed -n 's/^timeout *= *"\(.*\)"/\1/p' "$ORDER")"
exec_line="$(sed -n 's/^exec *= *"\(.*\)"/\1/p' "$ORDER")"
[ "$trigger" = "cooldown" ] && ok "order: trigger is cooldown" || bad "order trigger is '$trigger'"
case "$interval" in *m) interval_secs=$(( ${interval%m} * 60 )) ;; *h) interval_secs=$(( ${interval%h} * 3600 )) ;; *s) interval_secs=${interval%s} ;; *) interval_secs=0 ;; esac
case "$timeout_s" in *s) timeout_secs=${timeout_s%s} ;; *m) timeout_secs=$(( ${timeout_s%m} * 60 )) ;; *) timeout_secs=0 ;; esac
[ "$timeout_secs" -ge 200 ] && ok "order: timeout ${timeout_s} covers the measured worst run (1m50s at load ~60) with margin" || bad "order timeout '${timeout_s}' is under the measured worst-case run"
[ "$interval_secs" -gt "$timeout_secs" ] && ok "order: interval ${interval} > timeout ${timeout_s} — a run cannot overlap the next even without the lock" || bad "order interval '${interval}' does not exceed timeout '${timeout_s}'"
[ "$exec_line" = '$PACK_DIR/assets/scripts/scratchpad-sweep.sh' ] && [ -x "$WRAPPER" ] && ok "order: exec points at the (executable) wrapper" || bad "order exec is '$exec_line' or wrapper not executable"

echo ""
echo "=== whole chain: wrapper → reaper → safe-clean on a fixture root ==="
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gc" <<'EOF'
#!/bin/bash
[ "$1 $2" = "session list" ] && echo '{"sessions":[{"session_key":"live-in-gc"}]}' && exit 0
exit 1
EOF
cat > "$WORK/bin/ps" <<'EOF'
#!/bin/bash
cat <<'OUT'
    1 /sbin/launchd
  201 claude --dangerously-skip-permissions --session-id live-in-ps-0000-4000-8000-000000000001
OUT
EOF
chmod +x "$WORK/bin/gc" "$WORK/bin/ps"
PS_UUID="11111111-2222-4333-8444-555555555555"
sed -i '' "s/live-in-ps-0000-4000-8000-000000000001/$PS_UUID/" "$WORK/bin/ps"

mk() {  # mk <sid> <age_minutes>
  mkdir -p "$CHAIN_ROOT/proj/$1/scratchpad/tree"; : > "$CHAIN_ROOT/proj/$1/scratchpad/tree/copy"
  touch -t "$(date -v-"$2"M +%Y%m%d%H%M.%S)" "$CHAIN_ROOT/proj/$1/scratchpad"
}
mk dead-45m 45
mk dead-10m 10
mk live-in-gc 45
mk "$PS_UUID" 45
LOG="$WORK/reaper.log"
PATH="$WORK/bin:$PATH" \
  GC_BIN="$WORK/bin/gc" \
  SCRATCHPAD_SWEEP_REAPER="$REAPER" \
  SCRATCHPAD_REAPER_ROOT="$CHAIN_ROOT" \
  SCRATCHPAD_REAPER_LOG="$LOG" \
  SCRATCHPAD_REAPER_LOCK_DIR="$WORK/lock.d" \
  SCRATCHPAD_REAPER_SAFE_CLEAN="$SAFE_CLEAN_PY" \
  bash "$WRAPPER"; rc=$?
[ "$rc" -eq 0 ] && ok "chain: cycle exits 0" || bad "chain: cycle exited $rc — log: $(cat "$LOG" 2>/dev/null)"
[ ! -d "$CHAIN_ROOT/proj/dead-45m/scratchpad" ] && ok "chain: dead + 45min idle scratchpad (with a tree/ copy inside) is gone" || bad "chain: dead 45min scratchpad survived — log: $(cat "$LOG" 2>/dev/null)"
[ -d "$CHAIN_ROOT/proj/dead-45m" ] && ok "chain: its session dir is left in place (leaf-only removal)" || bad "chain: session dir removed with the leaf"
[ -d "$CHAIN_ROOT/proj/dead-10m/scratchpad" ] && ok "chain: dead but only 10min idle → kept" || bad "chain: reaped a 10min-old scratchpad"
[ -d "$CHAIN_ROOT/proj/live-in-gc/scratchpad" ] && ok "chain: session listed by gc → kept" || bad "chain: reaped a gc-live session's scratchpad"
[ -d "$CHAIN_ROOT/proj/$PS_UUID/scratchpad" ] && ok "chain: session known only from a running claude's --session-id → kept" || bad "chain: reaped a scratchpad whose claude process is running"
grep -q "reaped (idle): proj/dead-45m/scratchpad" "$LOG" && grep -q "elapsed=" "$LOG" && ok "chain: log names the reap reason and carries elapsed=" || bad "chain: log lacks 'reaped (idle)'/elapsed= — got: $(cat "$LOG")"
[ ! -d "$WORK/lock.d" ] && ok "chain: the lock is released when the cycle ends" || bad "chain: lock left behind"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
