#!/usr/bin/env bash
# Selftest for nightly-reboot.sh — proves Guard 2's retry survives a single
# transient gate-queue-composition.sh blip (ga-g5bzf) instead of burning the
# whole night, while fail-closed still holds if BOTH attempts fail.
#
# SAFETY: bd is faked to ALWAYS report 1 in-progress bead, so Guard 3
# unconditionally SKIPs in every scenario below — the real
# `/sbin/shutdown -r now` line is architecturally unreachable from this test
# regardless of how Guard 2 behaves. assert_never_rebooted() is a second,
# independent proof of the same thing (greps the run log for the line that
# only appears immediately before the shutdown call). Nothing here touches
# the real CITY, the real bd/notify binaries, or sudo.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/nightly-reboot.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fake PATH: only `date` and `sudo` need shadowing — CITY, BD_BIN,
# NOTIFY_BIN and NOTIFY_AS_USER already have real env-var overrides. -------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/date" <<'EOF'
#!/usr/bin/env bash
# Pins Guard 1's window check to 01:05 so every scenario clears it
# regardless of when the selftest actually runs. Anything else (the log()
# timestamp, the notify %H:%M text) delegates to the real date.
case "$1" in
  +%-H) echo 1 ;;
  +%-M) echo 5 ;;
  *) exec /bin/date "$@" ;;
esac
EOF
chmod +x "$FAKEBIN/date"

cat > "$FAKEBIN/sudo" <<'EOF'
#!/usr/bin/env bash
# Fake sudo, this sandbox PATH only: drop `-u <user>` and exec directly. A
# real sudo -u here would need privilege escalation this test must never
# attempt, and notify_athos's `|| true` would silently swallow the failure —
# hiding exactly the notify assertions this test needs to make.
[ "$1" = "-u" ] && shift 2
exec "$@"
EOF
chmod +x "$FAKEBIN/sudo"

# --- fake bd: ALWAYS reports 1 in-progress bead, so Guard 3 blocks no
# matter what Guard 2 decided. This is what makes it safe to exercise Guard
# 2's failure path below without any risk of reaching the reboot line. -----
FAKE_BD="$TMP/bd"
cat > "$FAKE_BD" <<'EOF'
#!/usr/bin/env bash
echo '[{"id":"fake-inprogress-1"}]'
EOF
chmod +x "$FAKE_BD"

# --- fake notify: captures calls instead of paging Athos's phone. ---------
NOTIFY_LOG="$TMP/notify.log"
FAKE_NOTIFY="$TMP/notify"
cat > "$FAKE_NOTIFY" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$FAKE_NOTIFY"

# --- fake CITY: isolated sandbox, never touches the real one. -------------
FAKE_CITY="$TMP/city"
mkdir -p "$FAKE_CITY/.gc/logs" "$FAKE_CITY/scripts"
FAKE_GATE="$FAKE_CITY/scripts/gate-queue-composition.sh"
FAKE_LOG="$FAKE_CITY/.gc/logs/nightly-reboot.log"
GATE_COUNTER="$TMP/gate-calls"

# $1 = attempt number (1-based) at which the fake gate script starts
#      succeeding; 0 (or omitted) = never succeeds.
write_fake_gate() {
  local succeed_at="${1:-0}"
  cat > "$FAKE_GATE" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$GATE_COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$GATE_COUNTER"
if [ "$succeed_at" != "0" ] && [ "\$n" -ge "$succeed_at" ]; then
  echo '{"total":0,"real":0,"phantom":0,"unknown":0}'
  exit 0
fi
echo "ERRO: fake failure on attempt \$n" >&2
exit 2
EOF
  chmod +x "$FAKE_GATE"
}

run_nightly_reboot() {
  rm -f "$GATE_COUNTER"; : > "$NOTIFY_LOG"; : > "$FAKE_LOG"
  PATH="$FAKEBIN:$PATH" \
    CITY="$FAKE_CITY" \
    BD_BIN="$FAKE_BD" \
    NOTIFY_BIN="$FAKE_NOTIFY" \
    NOTIFY_AS_USER="nobody" \
    NIGHTLY_REBOOT_GATE_RETRY_SLEEP=1 \
    timeout 30 bash "$SCRIPT" >"$TMP/stdout.log" 2>"$TMP/stderr.log"
  echo $?
}

assert_never_rebooted() {
  local scenario="$1"
  if grep -q "rebooting now" "$FAKE_LOG" 2>/dev/null; then
    bad "$scenario: SAFETY VIOLATION — log shows 'rebooting now', /sbin/shutdown may have been reached"
  else
    ok "$scenario: never reached the reboot line (Guard 3 fake-bd block held)"
  fi
}

echo "── Scenario 1: gate-queue-composition succeeds on the FIRST try (no retry needed) ──"
write_fake_gate 1
rc=$(run_nightly_reboot)
calls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "1: exits 0" || bad "1: expected exit 0, got $rc"
[ "$calls" = "1" ] && ok "1: gate-queue-composition.sh called exactly once (no spurious retry)" || bad "1: expected 1 call, got $calls"
grep -q "gate check OK" "$FAKE_LOG" && ok "1: log shows gate check OK" || bad "1: log missing 'gate check OK'"
assert_never_rebooted "1"

echo ""
echo "── Scenario 2: fails once, succeeds on retry — THE ga-g5bzf regression ──"
write_fake_gate 2
rc=$(run_nightly_reboot)
calls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "2: exits 0" || bad "2: expected exit 0, got $rc"
[ "$calls" = "2" ] && ok "2: gate-queue-composition.sh retried exactly once after the transient failure" || bad "2: expected 2 calls, got $calls"
grep -q "attempt 1/2 failed" "$FAKE_LOG" && ok "2: log shows the first-attempt failure" || bad "2: log missing the attempt-1 failure line"
grep -q "gate check OK" "$FAKE_LOG" && ok "2: log shows the retry recovered (gate check OK) — this is the fix" || bad "2: retry did NOT recover — ga-g5bzf regression"
assert_never_rebooted "2"

echo ""
echo "── Scenario 3: fails on BOTH attempts — fail-closed must still hold ──"
write_fake_gate 0
rc=$(run_nightly_reboot)
calls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "3: exits 0 (SKIP, not a crash)" || bad "3: expected exit 0, got $rc"
[ "$calls" = "2" ] && ok "3: gave up after exactly 2 attempts (bounded — no retry storm)" || bad "3: expected 2 calls, got $calls"
grep -q "SKIP: gate-queue-composition.sh failed after 2/2 attempts" "$FAKE_LOG" \
  && ok "3: log shows fail-closed SKIP after exhausting retries" || bad "3: log missing the fail-closed SKIP line"
grep -q "gate-queue-composition.sh falhou (2/2 tentativas)" "$NOTIFY_LOG" \
  && ok "3: notify_athos fired with the attempt count" || bad "3: notify_athos did not fire (or wrong message)"
assert_never_rebooted "3"

echo ""
echo "nightly-reboot selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
