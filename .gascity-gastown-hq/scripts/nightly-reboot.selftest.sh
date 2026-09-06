#!/usr/bin/env bash
# Selftest for nightly-reboot.sh — proves the merged Guard-2+3 retry loop
# (ga-nnp5b) survives a transient blip in EITHER guard without burning the
# whole night, still fail-closes if the block never clears, re-checks BOTH
# guards on every attempt (no staleness gap), and drives the
# consecutive-skip streak/alarm (ga-nnp5b item 4) correctly. Supersedes the
# narrower ga-g5bzf selftest, which only exercised Guard 2.
#
# SAFETY — read this before changing ANY scenario below: the quality gate
# replays this exact file, UNMODIFIED, against the commit this branch is
# BASED ON (i.e. the pre-fix nightly-reboot.sh) as an automated check that
# the test genuinely depends on the fix (ga-rstae, "arm B"). That older
# script hardcodes `/sbin/shutdown -r now` with NO override hook at all — so
# any scenario here that lets BOTH the gate guard and the hq guard clear at
# once would, when replayed against the pre-fix script, reach a REAL,
# unfaked reboot call on whatever machine runs the gate check. That is
# unacceptable regardless of how likely the gate-runner is to hold root (the
# whole point of this bug is an UNCONTROLLED reboot taking the city down).
#
# So: every full-script scenario below (1-3) keeps the fake `bd` reporting a
# permanent in-progress bead — the hq guard NEVER clears, for either script
# version, so neither can ever reach its reboot line. This is the same
# invariant the original ga-g5bzf selftest relied on (it called Guard 3
# "unconditionally SKIPs... the real /sbin/shutdown line is architecturally
# unreachable regardless of how Guard 2 behaves") — kept here on purpose,
# not an oversight. assert_never_rebooted() checks this two independent
# ways: the fake shutdown's own call log (only meaningful under the NEW
# script) AND the "rebooting now" log line (meaningful under either).
#
# The one behavior that genuinely requires BOTH guards to clear —
# reset_streak() firing on a clean night — is tested separately in Scenario
# 4 via a sentinel-bounded extraction of ONLY the streak functions
# (nightly-reboot.sh's own STREAK-FUNCTIONS-START/END markers), sourced in
# isolation with stubbed log()/notify_athos(). That block contains no Guard
# 1/2/3 code and no reboot call, so sourcing it is safe regardless of which
# script version it's extracted from — and the pre-fix script has no such
# markers at all, so the extraction comes back empty there and the
# subsequent record_skip/reset_streak calls fail with "command not found",
# which is the correct, expected failure for arm B.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/nightly-reboot.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fake PATH: only `date` and `sudo` need shadowing — CITY, BD_BIN,
# GC_BIN, NOTIFY_BIN and NOTIFY_AS_USER already have real env-var
# overrides. -----------------------------------------------------------
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

# --- fake gate-queue-composition.sh: N-th call onward reports clear -------
FAKE_CITY="$TMP/city"
mkdir -p "$FAKE_CITY/.gc/logs" "$FAKE_CITY/scripts"
FAKE_GATE="$FAKE_CITY/scripts/gate-queue-composition.sh"
FAKE_LOG="$FAKE_CITY/.gc/logs/nightly-reboot.log"
STREAK_FILE_PATH="$FAKE_CITY/.gc/logs/nightly-reboot.streak"
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

# --- fake bd: ALWAYS reports 1 in-progress bead in every full-script
# scenario below — see the file header for why this must never change to
# "eventually clears" in a scenario that runs the real script. -------------
FAKE_BD="$TMP/bd"
BD_COUNTER="$TMP/bd-calls"
cat > "$FAKE_BD" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$BD_COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$BD_COUNTER"
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

reset_all() {
  rm -f "$GATE_COUNTER" "$BD_COUNTER" "$STREAK_FILE_PATH"
  : > "$NOTIFY_LOG"; : > "$FAKE_LOG"
}

run_nightly_reboot() {
  PATH="$FAKEBIN:$PATH" \
    CITY="$FAKE_CITY" \
    BD_BIN="$FAKE_BD" \
    NOTIFY_BIN="$FAKE_NOTIFY" \
    NOTIFY_AS_USER="nobody" \
    NIGHTLY_REBOOT_RETRY_INTERVAL=1 \
    NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS=3 \
    NIGHTLY_REBOOT_ALARM_THRESHOLD=2 \
    timeout 60 bash "$SCRIPT" >"$TMP/stdout.log" 2>"$TMP/stderr.log"
  echo $?
}

assert_never_rebooted() {
  local scenario="$1"
  if grep -q "rebooting now" "$FAKE_LOG" 2>/dev/null; then
    bad "$scenario: SAFETY VIOLATION — log shows 'rebooting now'"
  else
    ok "$scenario: never reached the reboot line (hq fake-bd block held)"
  fi
}

echo "── Scenario 1: gate healthy from the first attempt, hq NEVER clears ──"
reset_all
write_fake_gate 1
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "1: exits 0 (SKIP, not a crash)" || bad "1: expected exit 0, got $rc"
[ "$gcalls" = "3" ] && ok "1: gate re-checked on every attempt (no staleness gap)" || bad "1: expected 3 gate calls, got $gcalls"
[ "$bcalls" = "3" ] && ok "1: hq re-checked on every attempt too" || bad "1: expected 3 bd calls, got $bcalls"
grep -q "hq beads in_progress = 1" "$FAKE_LOG" && ok "1: log attributes the block to hq, not gate" || bad "1: log doesn't show the hq-specific reason"
grep -q "SKIP: guards still blocked after 3/3 attempts" "$FAKE_LOG" && ok "1: log shows fail-closed SKIP after exhausting retries" || bad "1: log missing the fail-closed SKIP line"
grep -q "bloqueado após 3/3 tentativas" "$NOTIFY_LOG" && ok "1: notify_athos fired with the attempt count" || bad "1: notify_athos did not fire (or wrong message)"
assert_never_rebooted "1"
[ "$(cat "$STREAK_FILE_PATH" 2>/dev/null)" = "1" ] && ok "1: skip streak now 1" || bad "1: expected streak=1, got $(cat "$STREAK_FILE_PATH" 2>/dev/null || echo '<missing>')"

echo ""
echo "── Scenario 2: gate blips once then clears — hq NEVER clears, becomes the blocker after ──"
reset_all
write_fake_gate 2
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "2: exits 0 (SKIP, not a crash)" || bad "2: expected exit 0, got $rc"
[ "$gcalls" = "3" ] && ok "2: gate called on every attempt (retried past the transient failure)" || bad "2: expected 3 gate calls, got $gcalls"
[ "$bcalls" = "2" ] && ok "2: hq only checked once gate cleared (attempts 2 and 3)" || bad "2: expected 2 bd calls, got $bcalls"
grep -q "attempt 1/3 blocked (gate-queue-composition.sh failed" "$FAKE_LOG" && ok "2: log shows the first-attempt gate block" || bad "2: log missing the attempt-1 gate-block line"
grep -q "attempt 2/3 blocked (hq beads in_progress = 1)" "$FAKE_LOG" && ok "2: log shows the block reason switching to hq once gate recovered — this is the fix" || bad "2: retry did NOT recover on the gate side, or reason didn't switch"
assert_never_rebooted "2"

echo ""
echo "── Scenario 3: gate never clears — fail-closed must still hold, hq never even checked ──"
reset_all
write_fake_gate 0
rc=$(run_nightly_reboot)
gcalls=$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)
bcalls=$(cat "$BD_COUNTER" 2>/dev/null || echo 0)
[ "$rc" -eq 0 ] && ok "3: exits 0 (SKIP, not a crash)" || bad "3: expected exit 0, got $rc"
[ "$gcalls" = "3" ] && ok "3: gave up after exactly 3 attempts (bounded — no retry storm)" || bad "3: expected 3 gate calls, got $gcalls"
[ "$bcalls" = "0" ] && ok "3: hq never checked — gate short-circuits first" || bad "3: expected 0 bd calls, got $bcalls"
grep -q "SKIP: guards still blocked after 3/3 attempts" "$FAKE_LOG" \
  && ok "3: log shows fail-closed SKIP after exhausting retries" || bad "3: log missing the fail-closed SKIP line"
assert_never_rebooted "3"

echo ""
echo "── Scenario 4: consecutive-skip streak + alarm, tested in isolation from Guards 1-3 ──"
# Extracted from nightly-reboot.sh between its own sentinel markers — see
# this file's header for why the extraction (not a full script run) is the
# only safe way to exercise the "streak resets on success" behavior.
STREAK_SNIPPET="$TMP/streak-functions.sh"
sed -n '/STREAK-FUNCTIONS-START/,/STREAK-FUNCTIONS-END/p' "$SCRIPT" > "$STREAK_SNIPPET"
if [ ! -s "$STREAK_SNIPPET" ]; then
  bad "4: sentinel extraction found nothing in $SCRIPT — cannot test streak logic (expected on the pre-fix script; see file header)"
else
  ISO_STREAK_FILE="$TMP/iso.streak"
  ISO_LOG="$TMP/iso.log"
  ISO_NOTIFY_LOG="$TMP/iso-notify.log"
  ISO_MAIL_LOG="$TMP/iso-mail.log"
  : > "$ISO_LOG"; : > "$ISO_NOTIFY_LOG"; : > "$ISO_MAIL_LOG"
  rm -f "$ISO_STREAK_FILE"

  # Minimal stubs for the two functions record_skip() calls that live
  # OUTSIDE the extracted block (log(), notify_athos()) — this is what
  # makes the isolation possible without dragging in Guards 1-3.
  log() { echo "$*" >> "$ISO_LOG"; }
  notify_athos() { echo "$1 :: $2 (p${3:-3})" >> "$ISO_NOTIFY_LOG"; }
  GC="$TMP/iso-gc"
  cat > "$GC" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ISO_MAIL_LOG"
EOF
  chmod +x "$GC"
  # shellcheck disable=SC2034  # consumed by the dynamically-sourced snippet below, invisible to static analysis
  CITY="$FAKE_CITY"   # unused by the extracted block beyond the mail call
  # shellcheck disable=SC2034
  STREAK_FILE="$ISO_STREAK_FILE"
  # shellcheck disable=SC2034
  LOG="$ISO_LOG"       # record_skip's escalation message interpolates ${LOG} directly
  # shellcheck disable=SC2034
  NIGHTLY_REBOOT_ALARM_THRESHOLD=2

  # shellcheck source=/dev/null
  source "$STREAK_SNIPPET"

  record_skip "isolated test reason A"
  [ "$(cat "$ISO_STREAK_FILE" 2>/dev/null)" = "1" ] && ok "4a: first record_skip -> streak=1" || bad "4a: expected streak=1"
  [ ! -s "$ISO_MAIL_LOG" ] && ok "4a: no alarm yet (below threshold)" || bad "4a: alarm fired too early"

  record_skip "isolated test reason B"
  [ "$(cat "$ISO_STREAK_FILE" 2>/dev/null)" = "2" ] && ok "4b: second record_skip -> streak=2" || bad "4b: expected streak=2"
  grep -q "nightly-reboot: 2 noites seguidas" "$ISO_MAIL_LOG" && ok "4b: mayor-mail escalation fired at threshold" || bad "4b: mayor-mail did not fire at streak=2"
  grep -q "🚨" "$ISO_NOTIFY_LOG" && ok "4b: high-priority push fired alongside the mail" || bad "4b: escalation push missing"

  reset_streak
  [ "$(cat "$ISO_STREAK_FILE" 2>/dev/null)" = "0" ] && ok "4c: reset_streak zeroes the streak (the clean-night path)" || bad "4c: expected streak reset to 0, got $(cat "$ISO_STREAK_FILE" 2>/dev/null)"
fi

echo ""
echo "── Scenario 5: macOS update install-before-reboot (ga-l5m50), tested in isolation from Guards 1-3 ──"
# Extracted from nightly-reboot.sh between its own sentinel markers — same
# isolation technique and same reason as Scenario 4's streak-functions
# extraction (see this file's header): a full-script run must never let both
# guards clear, so the install-before-reboot logic is exercised via sentinel
# extraction + a faked `softwareupdate` in PATH, never via a full run of the
# real script. On the pre-fix script this extraction comes back empty — the
# correct, expected result for arm B (see Scenario 4's own comment).
MACOS_SNIPPET="$TMP/macos-update-functions.sh"
sed -n '/MACOS-UPDATE-FUNCTIONS-START/,/MACOS-UPDATE-FUNCTIONS-END/p' "$SCRIPT" > "$MACOS_SNIPPET"
if [ ! -s "$MACOS_SNIPPET" ]; then
  bad "5: sentinel extraction found nothing in $SCRIPT — cannot test macOS-update logic (expected on the pre-fix script; see file header)"
else
  SU_CALLS_LOG="$TMP/su-calls.log"
  SU_LIST_FILE="$TMP/su-list-output.txt"
  FAKE_SU="$TMP/softwareupdate"

  # $1 = --list output body, $2 = exit code for --install (default 0)
  write_fake_su() {
    printf '%s\n' "$1" > "$SU_LIST_FILE"
    local install_rc="${2:-0}"
    cat > "$FAKE_SU" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SU_CALLS_LOG"
case "\$1" in
  --list) cat "$SU_LIST_FILE"; exit 0 ;;
  --install) exit $install_rc ;;
esac
EOF
    chmod +x "$FAKE_SU"
  }

  RESTART_LISTING='Software Update Tool

Software Update found the following new or updated software:
* Label: macOS Tahoe 26.6.2-25G83
	Title: macOS Tahoe 26.6.2, Version: 26.6.2, Size: 2824636KiB, Recommended: YES, Action: restart,'

  NO_UPDATE_LISTING='Software Update Tool

No new software available.'

  ISO5_LOG="$TMP/iso5.log"
  ISO5_NOTIFY_LOG="$TMP/iso5-notify.log"
  : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  log() { echo "$*" >> "$ISO5_LOG"; }
  notify_athos() { echo "$1 :: $2 (p${3:-3})" >> "$ISO5_NOTIFY_LOG"; }
  # shellcheck disable=SC2034  # consumed by the dynamically-sourced snippet
  LOG="$ISO5_LOG"
  SOFTWAREUPDATE_BIN="$FAKE_SU"

  # shellcheck source=/dev/null
  source "$MACOS_SNIPPET"

  echo "  -- 5a: update ready (Action: restart), install succeeds --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$RESTART_LISTING" 0
  macos_update_install_if_ready
  RC5A=$?
  [ "$RC5A" -eq 0 ] && ok "5a: returns 0 (never blocks the caller's reboot)" || bad "5a: expected return 0, got $RC5A"
  [ "$(grep -c '^--list --no-scan$' "$SU_CALLS_LOG" 2>/dev/null)" = "1" ] && ok "5a: checked --list --no-scan exactly once" || bad "5a: expected exactly 1 --list call"
  grep -q '^--install --all --no-scan --agree-to-license$' "$SU_CALLS_LOG" && ok "5a: attempted install with the right flags" || bad "5a: install was not attempted with expected flags"
  grep -qi "instalando" "$ISO5_LOG" && ok "5a: logged the install attempt before running it" || bad "5a: missing pre-install log line"
  grep -qi "sucesso" "$ISO5_LOG" && ok "5a: logged install success" || bad "5a: missing success log line"

  echo "  -- 5b: update ready, install FAILS — must not abort (caller still proceeds to reboot) --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$RESTART_LISTING" 1
  macos_update_install_if_ready
  RC5B=$?
  [ "$RC5B" -eq 0 ] && ok "5b: function returns 0 even when install failed (never blocks the reboot)" || bad "5b: function returned $RC5B — this would abort the caller's reboot"
  grep -qi "ERROR" "$ISO5_LOG" && ok "5b: logged the install failure" || bad "5b: missing failure log line"
  [ -s "$ISO5_NOTIFY_LOG" ] && ok "5b: alarmed athos about the install failure" || bad "5b: no notify on install failure"

  echo "  -- 5c: no update pending — install must NEVER be attempted --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$NO_UPDATE_LISTING" 0
  macos_update_install_if_ready
  grep -q '^--install' "$SU_CALLS_LOG" && bad "5c: install was attempted with nothing pending" || ok "5c: install correctly skipped — nothing with Action: restart pending"
  grep -qi "reboot normal" "$ISO5_LOG" && ok "5c: logged the skip reason" || bad "5c: missing skip-reason log line"
fi

echo ""
echo "nightly-reboot selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
