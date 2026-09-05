#!/usr/bin/env bash
# Selftest for nightly-reboot.sh — proves the merged Guard-2+3 retry loop
# (ga-nnp5b) survives a transient blip in EITHER guard without burning the
# whole night, still fail-closes if the block never clears, re-checks BOTH
# guards on every attempt (no staleness gap), and drives the
# consecutive-skip streak/alarm (ga-nnp5b item 4) correctly. Supersedes the
# narrower ga-g5bzf selftest, which only exercised Guard 2 and relied on
# Guard 3 being permanently (and un-testably) blocked.
#
# SAFETY: /sbin/shutdown is never invoked for real. The script's own
# SHUTDOWN_BIN override (added alongside GC_BIN/BD_BIN/NOTIFY_BIN for this
# fix) points it at a fake that only logs its args — this is what makes it
# safe to exercise the actual "reboot" success path here, unlike the
# ga-g5bzf test which avoided that path entirely by keeping Guard 3
# permanently blocked. assert_never_rebooted() double-checks: it looks at
# the fake shutdown's own call log, not just script log text, so a scenario
# that's SUPPOSED to stay blocked really never reached that call. Nothing
# here touches the real CITY, the real bd/gc/notify binaries, or sudo.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/nightly-reboot.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fake PATH: only `date`, `sudo` and `sync` need shadowing — CITY,
# BD_BIN, GC_BIN, NOTIFY_BIN, SHUTDOWN_BIN and NOTIFY_AS_USER already have
# real env-var overrides. ---------------------------------------------------
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

cat > "$FAKEBIN/sync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/sync"

# --- fake gate-queue-composition.sh: N-th call onward reports clear -------
FAKE_CITY="$TMP/city"
mkdir -p "$FAKE_CITY/.gc/logs" "$FAKE_CITY/scripts"
FAKE_GATE="$FAKE_CITY/scripts/gate-queue-composition.sh"
FAKE_LOG="$FAKE_CITY/.gc/logs/nightly-reboot.log"
STREAK_FILE="$FAKE_CITY/.gc/logs/nightly-reboot.streak"
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

# --- fake bd: N-th call onward reports 0 in-progress; 0 = never clears. ---
FAKE_BD="$TMP/bd"
BD_COUNTER="$TMP/bd-calls"
write_fake_bd() {
  local succeed_at="${1:-0}"
  cat > "$FAKE_BD" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$BD_COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$BD_COUNTER"
if [ "$succeed_at" != "0" ] && [ "\$n" -ge "$succeed_at" ]; then
  echo '[]'
else
  echo '[{"id":"fake-inprogress-1"}]'
fi
EOF
  chmod +x "$FAKE_BD"
}

# --- fake gc: only used for record_skip's mail escalation. Logs its args
# instead of touching the real gc binary or a real city. ------------------
FAKE_GC="$TMP/gc"
GC_MAIL_LOG="$TMP/gc-mail.log"
cat > "$FAKE_GC" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GC_MAIL_LOG"
EOF
chmod +x "$FAKE_GC"

# --- fake shutdown: this is what makes it SAFE to let a scenario reach the
# "all clear, reboot now" path. Logs its args; never actually reboots. -----
FAKE_SHUTDOWN="$TMP/shutdown"
SHUTDOWN_CALL_LOG="$TMP/shutdown-calls.log"
cat > "$FAKE_SHUTDOWN" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHUTDOWN_CALL_LOG"
exit 0
EOF
chmod +x "$FAKE_SHUTDOWN"

# --- fake notify: captures calls instead of paging Athos's phone. ---------
NOTIFY_LOG="$TMP/notify.log"
FAKE_NOTIFY="$TMP/notify"
cat > "$FAKE_NOTIFY" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$FAKE_NOTIFY"

# fresh_state: wipes per-run counters/logs but PRESERVES the streak file —
# use between nights within the SAME consecutive-skip scenario group.
# reset_all also clears the streak — use at the start of an independent
# group that must start from "0 consecutive skips".
fresh_state() {
  rm -f "$GATE_COUNTER" "$BD_COUNTER"
  : > "$NOTIFY_LOG"; : > "$FAKE_LOG"; : > "$GC_MAIL_LOG"; : > "$SHUTDOWN_CALL_LOG"
}
reset_all() { fresh_state; rm -f "$STREAK_FILE"; }

run_nightly_reboot() {
  PATH="$FAKEBIN:$PATH" \
    CITY="$FAKE_CITY" \
    BD_BIN="$FAKE_BD" \
    GC_BIN="$FAKE_GC" \
    NOTIFY_BIN="$FAKE_NOTIFY" \
    NOTIFY_AS_USER="nobody" \
    SHUTDOWN_BIN="$FAKE_SHUTDOWN" \
    NIGHTLY_REBOOT_RETRY_INTERVAL=1 \
    NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS=3 \
    NIGHTLY_REBOOT_ALARM_THRESHOLD=2 \
    timeout 30 bash "$SCRIPT" >"$TMP/stdout.log" 2>"$TMP/stderr.log"
  echo $?
}

assert_never_rebooted() {
  local scenario="$1"
  if [ -s "$SHUTDOWN_CALL_LOG" ] || grep -q "rebooting now" "$FAKE_LOG" 2>/dev/null; then
    bad "$scenario: SAFETY VIOLATION — shutdown was invoked or log shows 'rebooting now'"
  else
    ok "$scenario: never reached the reboot line"
  fi
}

echo "── Scenario 1: gate + hq both healthy on the FIRST attempt ──"
reset_all
write_fake_gate 1; write_fake_bd 1
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
# exit 1 here is the CORRECT observed outcome, not a bug: in production,
# reaching the post-shutdown "ERROR: shutdown returned" line at all means
# /sbin/shutdown returned control instead of the machine actually
# rebooting — the fake can only ever "return" (it has no way to truly
# reboot the test host), so it deterministically exercises that same
# fall-through path. The real evidence of success is the fake shutdown
# call + the guards-OK log line, not the exit code.
[ "$rc" -eq 1 ] && ok "1: exits 1 (fake shutdown returned instead of truly rebooting — expected)" || bad "1: expected exit 1, got $rc"
[ "$gcalls" = "1" ] && ok "1: gate checked exactly once (no spurious retry)" || bad "1: expected 1 gate call, got $gcalls"
[ "$bcalls" = "1" ] && ok "1: hq checked exactly once" || bad "1: expected 1 bd call, got $bcalls"
grep -q "guards OK on attempt 1/3" "$FAKE_LOG" && ok "1: log shows guards OK on attempt 1" || bad "1: log missing guards-OK line"
if [ -s "$SHUTDOWN_CALL_LOG" ] && grep -q -- "-r now" "$SHUTDOWN_CALL_LOG"; then
  ok "1: fake shutdown -r now was invoked"
else
  bad "1: shutdown was never invoked"
fi
grep -q "ERROR: shutdown returned 0" "$FAKE_LOG" && ok "1: log shows the post-shutdown fall-through, as expected from a mock" || bad "1: missing the expected post-shutdown ERROR line"
[ "$(cat "$STREAK_FILE" 2>/dev/null || echo x)" = "0" ] && ok "1: streak stays 0 on a clean night" || bad "1: streak not reset/zero after success"

echo ""
echo "── Scenario 2: gate blips once then clears, hq healthy — the ga-g5bzf case, now inside the merged retry ──"
reset_all
write_fake_gate 2; write_fake_bd 1
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
# See scenario 1's comment: exit 1 is the expected outcome with a fake
# shutdown that returns instead of truly rebooting.
[ "$rc" -eq 1 ] && ok "2: exits 1 (fake shutdown returned instead of truly rebooting — expected)" || bad "2: expected exit 1, got $rc"
[ "$gcalls" = "2" ] && ok "2: gate retried exactly once after the transient failure" || bad "2: expected 2 gate calls, got $gcalls"
[ "$bcalls" = "1" ] && ok "2: hq checked once, only after gate cleared" || bad "2: expected 1 bd call, got $bcalls"
grep -q "attempt 1/3 blocked" "$FAKE_LOG" && ok "2: log shows the first-attempt block" || bad "2: log missing the attempt-1 block line"
grep -q "guards OK on attempt 2/3" "$FAKE_LOG" && ok "2: log shows recovery on attempt 2 — this is the fix" || bad "2: retry did NOT recover"
[ -s "$SHUTDOWN_CALL_LOG" ] && ok "2: fake shutdown was invoked" || bad "2: shutdown was never invoked"

echo ""
echo "── Scenario 3: gate never clears — fail-closed must still hold, hq never even checked ──"
reset_all
write_fake_gate 0; write_fake_bd 1
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "3: exits 0 (SKIP, not a crash)" || bad "3: expected exit 0, got $rc"
[ "$gcalls" = "3" ] && ok "3: gave up after exactly 3 attempts (bounded — no retry storm)" || bad "3: expected 3 gate calls, got $gcalls"
[ "$bcalls" = "0" ] && ok "3: hq never checked — gate short-circuits first" || bad "3: expected 0 bd calls, got $bcalls"
grep -q "SKIP: guards still blocked after 3/3 attempts" "$FAKE_LOG" \
  && ok "3: log shows fail-closed SKIP after exhausting retries" || bad "3: log missing the fail-closed SKIP line"
grep -q "bloqueado após 3/3 tentativas" "$NOTIFY_LOG" \
  && ok "3: notify_athos fired with the attempt count" || bad "3: notify_athos did not fire (or wrong message)"
assert_never_rebooted "3"
[ "$(cat "$STREAK_FILE" 2>/dev/null)" = "1" ] && ok "3: skip streak now 1" || bad "3: expected streak=1, got $(cat "$STREAK_FILE" 2>/dev/null || echo '<missing>')"
[ ! -s "$GC_MAIL_LOG" ] && ok "3: no mayor-mail yet (threshold is 2, streak is 1)" || bad "3: mayor-mail fired before threshold"

echo ""
echo "── Scenario 4: gate always healthy, hq never clears — proves Guard 3 is still enforced ──"
reset_all
write_fake_gate 1; write_fake_bd 0
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "4: exits 0 (SKIP, not a crash)" || bad "4: expected exit 0, got $rc"
[ "$gcalls" = "3" ] && ok "4: gate re-checked on every attempt (no staleness gap)" || bad "4: expected 3 gate calls, got $gcalls"
[ "$bcalls" = "3" ] && ok "4: hq re-checked on every attempt too" || bad "4: expected 3 bd calls, got $bcalls"
grep -q "hq beads in_progress = 1" "$FAKE_LOG" && ok "4: log attributes the block to hq, not gate" || bad "4: log doesn't show the hq-specific reason"
assert_never_rebooted "4"

echo ""
echo "── Scenario 5: consecutive-skip streak reaches the alarm threshold, then a clean night resets it ──"
reset_all
write_fake_gate 0; write_fake_bd 1
rc1=$(run_nightly_reboot)
[ "$rc1" -eq 0 ] && ok "5a: a skip night still exits 0 (SKIP, not a crash)" || bad "5a: expected exit 0, got $rc1"
[ "$(cat "$STREAK_FILE" 2>/dev/null)" = "1" ] && ok "5a: first bad night -> streak=1" || bad "5a: expected streak=1"
[ ! -s "$GC_MAIL_LOG" ] && ok "5a: no alarm yet (below threshold)" || bad "5a: alarm fired too early"
fresh_state   # new night, SAME streak file — do NOT reset_all here
write_fake_gate 0; write_fake_bd 1
rc2=$(run_nightly_reboot)
[ "$rc2" -eq 0 ] && ok "5b: a skip night still exits 0 (SKIP, not a crash)" || bad "5b: expected exit 0, got $rc2"
[ "$(cat "$STREAK_FILE" 2>/dev/null)" = "2" ] && ok "5b: second consecutive bad night -> streak=2" || bad "5b: expected streak=2"
grep -q "nightly-reboot: 2 noites seguidas" "$GC_MAIL_LOG" && ok "5b: mayor-mail escalation fired at threshold" || bad "5b: mayor-mail did not fire at streak=2"
grep -q "🚨" "$NOTIFY_LOG" && ok "5b: high-priority push fired alongside the mail" || bad "5b: escalation push missing"
fresh_state   # new night, SAME streak file
write_fake_gate 1; write_fake_bd 1
rc3=$(run_nightly_reboot)
[ "$(cat "$STREAK_FILE" 2>/dev/null)" = "0" ] && ok "5c: a clean night resets the streak to 0" || bad "5c: expected streak reset to 0, got $(cat "$STREAK_FILE" 2>/dev/null)"

echo ""
echo "nightly-reboot selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
