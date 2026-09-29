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
# FAKE_HOUR overrides the pinned hour: Scenario 7 (--check-guards) runs at 14h,
# OUTSIDE the 01:00-01:19 window, on purpose — see that scenario's comment.
case "$1" in
  +%-H) echo "${FAKE_HOUR:-1}" ;;
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
echo "── Scenario 5: macOS update install-before-reboot (ga-l5m50 / ga-i8n6s), tested in isolation from Guards 1-3 ──"
# Extracted from nightly-reboot.sh between its own sentinel markers — same
# isolation technique and same reason as Scenario 4's streak-functions
# extraction (see this file's header): a full-script run must never let both
# guards clear, so the install-before-reboot logic is exercised via sentinel
# extraction + a faked `softwareupdate`/`df` in-process, never via a full run
# of the real script. On the pre-fix script this extraction comes back empty
# — the correct, expected result for arm B (see Scenario 4's own comment).
MACOS_SNIPPET="$TMP/macos-update-functions.sh"
sed -n '/MACOS-UPDATE-FUNCTIONS-START/,/MACOS-UPDATE-FUNCTIONS-END/p' "$SCRIPT" > "$MACOS_SNIPPET"
if [ ! -s "$MACOS_SNIPPET" ]; then
  bad "5: sentinel extraction found nothing in $SCRIPT — cannot test macOS-update logic (expected on the pre-fix script; see file header)"
else
  SU_CALLS_LOG="$TMP/su-calls.log"
  SU_LIST_BEFORE_FILE="$TMP/su-list-before.txt"
  SU_LIST_AFTER_FILE="$TMP/su-list-after.txt"
  SU_INSTALL_OUTPUT_FILE="$TMP/su-install-output.txt"
  INSTALL_MARKER="$TMP/su-install-called"
  FAKE_SU="$TMP/softwareupdate"

  # $1 = --list output BEFORE --install runs
  # $2 = exit code for --install (default 0)
  # $3 = stdout/stderr text --install should print (default empty)
  # $4 = --list output AFTER --install runs (default: same as $1, i.e.
  #      "nothing actually changed" — the correct fake for every failure
  #      scenario, including the rc=0-but-lying live bug; a genuine-success
  #      scenario passes a listing with no Action:restart entry here, to
  #      simulate the update really clearing).
  write_fake_su() {
    printf '%s\n' "$1" > "$SU_LIST_BEFORE_FILE"
    local install_rc="${2:-0}"
    printf '%s' "${3:-}" > "$SU_INSTALL_OUTPUT_FILE"
    printf '%s\n' "${4:-$1}" > "$SU_LIST_AFTER_FILE"
    rm -f "$INSTALL_MARKER"
    cat > "$FAKE_SU" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SU_CALLS_LOG"
case "\$1" in
  --list)
    if [ -f "$INSTALL_MARKER" ]; then cat "$SU_LIST_AFTER_FILE"; else cat "$SU_LIST_BEFORE_FILE"; fi
    exit 0
    ;;
  --install)
    touch "$INSTALL_MARKER"
    cat "$SU_INSTALL_OUTPUT_FILE"
    exit $install_rc
    ;;
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

  # The exact failure mode measured live in ga-i8n6s: --install exits 0 but
  # prints this, and nothing is actually installed.
  DISK_FAIL_OUTPUT='Not enough free disk space: a total of 17.13 GB is required.'

  ISO5_LOG="$TMP/iso5.log"
  ISO5_NOTIFY_LOG="$TMP/iso5-notify.log"
  : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  log() { echo "$*" >> "$ISO5_LOG"; }
  notify_athos() { echo "$1 :: $2 (p${3:-3})" >> "$ISO5_NOTIFY_LOG"; }
  # shellcheck disable=SC2034  # consumed by the dynamically-sourced snippet
  LOG="$ISO5_LOG"
  SOFTWAREUPDATE_BIN="$FAKE_SU"

  # `df` override: fixed HIGH free space by default so 5a/5b/5c/5d never
  # depend on how much space this test machine actually has free (it
  # fluctuates 5-15GB in production per this very bug's own report) — only
  # 5e below deliberately lowers it to exercise the pre-check.
  FAKE_DF_AVAIL_KB=$((50 * 1024 * 1024))  # 50GB
  df() {
    echo "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted"
    echo "/dev/disk3s5 999999999 999999999 ${FAKE_DF_AVAIL_KB} 50% 1 1 1% /System/Volumes/Data"
  }

  # shellcheck source=/dev/null
  source "$MACOS_SNIPPET"

  echo "  -- 5a: update ready (Action: restart), install succeeds and takes effect --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$RESTART_LISTING" 0 "" "$NO_UPDATE_LISTING"
  macos_update_install_if_ready
  RC5A=$?
  [ "$RC5A" -eq 0 ] && ok "5a: returns 0 (never blocks the caller's reboot)" || bad "5a: expected return 0, got $RC5A"
  [ "$(grep -c '^--list --no-scan$' "$SU_CALLS_LOG" 2>/dev/null)" = "2" ] && ok "5a: verified with --list --no-scan before AND after install — this is the fix" || bad "5a: expected exactly 2 --list calls, got $(grep -c '^--list --no-scan$' "$SU_CALLS_LOG" 2>/dev/null)"
  grep -q '^--install --all --no-scan --agree-to-license$' "$SU_CALLS_LOG" && ok "5a: attempted install with the right flags" || bad "5a: install was not attempted with expected flags"
  grep -qi "instalando" "$ISO5_LOG" && ok "5a: logged the install attempt before running it" || bad "5a: missing pre-install log line"
  grep -qi "sucesso" "$ISO5_LOG" && ok "5a: logged install success" || bad "5a: missing success log line"
  grep -qi "ERROR" "$ISO5_LOG" && bad "5a: logged an ERROR on a genuine, verified success" || ok "5a: no false ERROR on genuine success"

  echo "  -- 5b: update ready, install FAILS outright (rc=1, nothing changes) — must not abort --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$RESTART_LISTING" 1 "some generic failure" "$RESTART_LISTING"
  macos_update_install_if_ready
  RC5B=$?
  [ "$RC5B" -eq 0 ] && ok "5b: function returns 0 even when install failed (never blocks the reboot)" || bad "5b: function returned $RC5B — this would abort the caller's reboot"
  grep -qi "ERROR" "$ISO5_LOG" && ok "5b: logged the install failure" || bad "5b: missing failure log line"
  grep -qi "sucesso" "$ISO5_LOG" && bad "5b: falsely logged success" || ok "5b: did not claim success"
  [ -s "$ISO5_NOTIFY_LOG" ] && ok "5b: alarmed athos about the install failure" || bad "5b: no notify on install failure"

  echo "  -- 5c: no update pending — install must NEVER be attempted --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$NO_UPDATE_LISTING" 0 "" "$NO_UPDATE_LISTING"
  macos_update_install_if_ready
  grep -q '^--install' "$SU_CALLS_LOG" && bad "5c: install was attempted with nothing pending" || ok "5c: install correctly skipped — nothing with Action: restart pending"
  grep -qi "reboot normal" "$ISO5_LOG" && ok "5c: logged the skip reason" || bad "5c: missing skip-reason log line"

  echo "  -- 5d: THE LIVE BUG (ga-i8n6s) — install exits rc=0 but 'Not enough free disk space', installs nothing --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$RESTART_LISTING" 0 "$DISK_FAIL_OUTPUT" "$RESTART_LISTING"
  macos_update_install_if_ready
  RC5D=$?
  [ "$RC5D" -eq 0 ] && ok "5d: function returns 0 even on this silent failure (never blocks the reboot)" || bad "5d: function returned $RC5D"
  grep -qi "sucesso" "$ISO5_LOG" && bad "5d: THE BUG — logged 'sucesso' even though softwareupdate never actually installed anything (rc=0 lied)" || ok "5d: correctly did NOT log success"
  grep -qi "ERROR" "$ISO5_LOG" && ok "5d: logged ERROR despite rc=0" || bad "5d: missing ERROR log line — rc=0 was trusted blindly"
  grep -qi "disco" "$ISO5_LOG" && ok "5d: log names disk space as the cause" || bad "5d: log doesn't call out disk space as the reason"
  grep -q "17.13" "$ISO5_LOG" && ok "5d: log captures the exact shortfall softwareupdate reported" || bad "5d: log doesn't capture how much disk was needed"
  grep -q "17.13" "$ISO5_NOTIFY_LOG" && ok "5d: alarmed athos with a disk-specific message (not just the generic pre-install heads-up)" || bad "5d: notify never mentioned the disk shortfall — old code's generic pre-install notify alone isn't enough"

  echo "  -- 5e: obviously-insufficient free disk BEFORE attempting — skip the install outright --"
  : > "$SU_CALLS_LOG"; : > "$ISO5_LOG"; : > "$ISO5_NOTIFY_LOG"
  write_fake_su "$RESTART_LISTING" 0 "" "$RESTART_LISTING"
  FAKE_DF_AVAIL_KB=$((3 * 1024 * 1024))  # 3GB free — obviously hopeless
  macos_update_install_if_ready
  RC5E=$?
  FAKE_DF_AVAIL_KB=$((50 * 1024 * 1024))  # restore default for any scenario added after this one
  [ "$RC5E" -eq 0 ] && ok "5e: returns 0 (never blocks the reboot)" || bad "5e: expected return 0, got $RC5E"
  grep -q '^--install' "$SU_CALLS_LOG" && bad "5e: install was attempted despite obviously-insufficient free space" || ok "5e: install correctly skipped before ever attempting — didn't waste the time"
  [ "$(grep -c '^--list --no-scan$' "$SU_CALLS_LOG" 2>/dev/null)" = "1" ] && ok "5e: only the initial ready-check ran (no wasted second --list)" || bad "5e: unexpected --list call count"
  grep -qi "3GB" "$ISO5_LOG" && ok "5e: log names the actual free space measured" || bad "5e: log doesn't show the measured free space"
  [ -s "$ISO5_NOTIFY_LOG" ] && ok "5e: notified athos the install was skipped for disk space" || bad "5e: no notify on precheck skip"
fi

echo ""
echo "── Scenario 6: scraper daily still running blocks the reboot (ps-70jq), tested in isolation ──"
# 2026-09-06..16: this reboot fired at 01:00 every night while the
# property_scrapers daily (00:01 → ~02:30) was still scraping, killing it
# mid-run 10 nights in a row. Guard 4 reads that daily's own per-rodada marker
# files. Same sentinel-extraction isolation as Scenarios 4/5 — never a full run.
SCRAPER_SNIPPET="$TMP/scraper-daily-guard.sh"
sed -n '/SCRAPER-DAILY-GUARD-START/,/SCRAPER-DAILY-GUARD-END/p' "$SCRIPT" > "$SCRAPER_SNIPPET"
if [ ! -s "$SCRAPER_SNIPPET" ]; then
  bad "6: sentinel extraction found nothing in $SCRIPT — cannot test the scraper-daily guard (expected on the pre-fix script)"
else
  # shellcheck source=/dev/null
  source "$SCRAPER_SNIPPET"
  RDIR="$TMP/rodada_status"
  DEAD_PID=$(bash -c 'echo $$')   # a subshell that has already exited
  LIVE_PID=$$
  NOW_EPOCH=$(/bin/date +%s)
  BOOT_EPOCH_FAKE=$((NOW_EPOCH - 7200))           # "booted 2h ago"
  AFTER_BOOT=$(/bin/date -r $((NOW_EPOCH - 3600)) +%Y-%m-%dT%H:%M:%S.000000)
  BEFORE_BOOT=$(/bin/date -r $((NOW_EPOCH - 90000)) +%Y-%m-%dT%H:%M:%S.000000)
  mk() { printf '{"rodada_id":"%s","pid":%s,"phase":"scraping","status":"%s","started_at":"%s"}' "$1" "$2" "$3" "$4" > "$RDIR/$1.json"; }
  check() { SCRAPER_RODADA_DIR="$RDIR" SCRAPER_BOOT_EPOCH="$BOOT_EPOCH_FAKE" scraper_daily_state; }

  rm -rf "$RDIR"
  check
  [ "$SCRAPER_DAILY_STATE" = "clear" ] && ok "6a: no marker dir -> clear (box without the scraper rig must still reboot)" || bad "6a: expected clear, got $SCRAPER_DAILY_STATE"

  mkdir -p "$RDIR"; mk live "$LIVE_PID" running "$AFTER_BOOT"
  check
  [ "$SCRAPER_DAILY_STATE" = "running" ] && ok "6b: running marker + live pid started this boot -> running (THE fix)" || bad "6b: expected running, got $SCRAPER_DAILY_STATE ($SCRAPER_DAILY_REASON)"
  printf '%s' "$SCRAPER_DAILY_REASON" | grep "live" >/dev/null && ok "6b: reason names the rodada" || bad "6b: reason missing rodada id: $SCRAPER_DAILY_REASON"

  rm -f "$RDIR"/*.json; mk dead "$DEAD_PID" running "$AFTER_BOOT"
  check
  [ "$SCRAPER_DAILY_STATE" = "clear" ] && ok "6c: running marker but pid gone -> clear (a dead daily must not block reboots forever)" || bad "6c: expected clear, got $SCRAPER_DAILY_STATE"

  rm -f "$RDIR"/*.json; mk reused "$LIVE_PID" running "$BEFORE_BOOT"
  check
  [ "$SCRAPER_DAILY_STATE" = "clear" ] && ok "6d: marker from BEFORE this boot with a now-reused pid -> clear (pid reuse)" || bad "6d: expected clear, got $SCRAPER_DAILY_STATE"

  rm -f "$RDIR"/*.json; mk done "$LIVE_PID" complete "$AFTER_BOOT"
  check
  [ "$SCRAPER_DAILY_STATE" = "clear" ] && ok "6e: complete marker -> clear" || bad "6e: expected clear, got $SCRAPER_DAILY_STATE"

  rm -f "$RDIR"/*.json; printf '{not json' > "$RDIR/corrupt.json"
  check
  [ "$SCRAPER_DAILY_STATE" = "unknown" ] && ok "6f: unreadable marker -> unknown (never collapsed into clear)" || bad "6f: expected unknown, got $SCRAPER_DAILY_STATE"

  # 6g: o CAMINHO REAL de produção — sem SCRAPER_BOOT_EPOCH injetado, a função
  # lê o relógio de boot do `sysctl` sozinha. Os casos 6a-6f injetam a data e
  # por isso NUNCA exercitaram essa leitura: foi assim que uma regex gulosa
  # (`.*sec = ([0-9]+)`) passou no selftest inteiro devolvendo os
  # MICROSSEGUNDOS de "usec = " em vez dos segundos — quatro ordens de grandeza
  # abaixo, o que torna a proteção contra pid reusado inerte em silêncio.
  echo "  -- 6g: sem SCRAPER_BOOT_EPOCH: a leitura do sysctl é exercitada de verdade --"
  cat > "$FAKEBIN/sysctl" <<'SYSCTL'
#!/usr/bin/env bash
# Formato real do macOS, com o "usec" que a regex gulosa capturava por engano.
echo "{ sec = 1789579812, usec = 958892 } Wed Sep 16 14:30:12 2026"
SYSCTL
  chmod +x "$FAKEBIN/sysctl"
  rm -f "$RDIR"/*.json
  # Marker iniciado DEPOIS desse boot (1789579812) e com pid vivo -> running.
  DEPOIS=$(/bin/date -r 1789583412 +%Y-%m-%dT%H:%M:%S.000000)
  mk pos_boot "$LIVE_PID" running "$DEPOIS"
  PATH="$FAKEBIN:$PATH" SCRAPER_RODADA_DIR="$RDIR" scraper_daily_state
  [ "$SCRAPER_DAILY_STATE" = "running" ] && ok "6g: rodada iniciada APÓS o boot lido do sysctl -> running" || bad "6g: esperava running, veio $SCRAPER_DAILY_STATE ($SCRAPER_DAILY_REASON)"

  # Marker iniciado ANTES desse boot: só é excluído se o epoch lido for os
  # SEGUNDOS. Com os microssegundos (958892), todo started_at real é maior e a
  # exclusão nunca dispara — este é o assert que reprova a versão com a regex.
  rm -f "$RDIR"/*.json
  ANTES=$(/bin/date -r 1789576212 +%Y-%m-%dT%H:%M:%S.000000)
  mk pre_boot "$LIVE_PID" running "$ANTES"
  PATH="$FAKEBIN:$PATH" SCRAPER_RODADA_DIR="$RDIR" scraper_daily_state
  [ "$SCRAPER_DAILY_STATE" = "clear" ] && ok "6g: rodada iniciada ANTES do boot -> clear (pid reusado, epoch lido em SEGUNDOS)" || bad "6g: esperava clear, veio $SCRAPER_DAILY_STATE — o epoch de boot provavelmente veio em microssegundos ($SCRAPER_DAILY_REASON)"
  rm -f "$FAKEBIN/sysctl"
fi

echo ""
echo "── Scenario 7: --check-guards (ga-7e3fwa) — read-only preflight for the Mayor's MANUAL reboot ──"
# Os reboots manuais de 26/09, 27/09, 28/09 e 29/09 mataram o noturno do
# scraper porque o caminho manual nao passa pelo Guard 4 — e o script nao tinha
# modo de so CHECAR. --check-guards roda os mesmos Guards 2+3+4 do noturno, uma
# vez, sem reiniciar, sem tocar o streak, sem mail, sem notify, sem log.
#
# SEGURANCA (mesma doutrina do cabecalho): todo run completo daqui roda com a
# hora falsa em 14h, FORA da janela 01:00-01:19. Contra o script ANTERIOR ao fix
# (que ignora --check-guards) isso cai no Guard 1 e sai com SKIP — o reboot fica
# estruturalmente inalcancavel, mesmo com bd/gate/scraper todos "limpos". Nao e
# acaso: --check-guards tambem tem que funcionar a qualquer hora (o reboot do
# Mayor nao e as 01:05), entao 14h e o caso que prova as duas coisas de uma vez.
# SHUTDOWN_BIN e SOFTWAREUPDATE_BIN vao pra fakes por cinto-e-suspensorio.
FAKE_SHUTDOWN="$TMP/shutdown7"; SHUTDOWN_CALLS="$TMP/shutdown7.calls"
cat > "$FAKE_SHUTDOWN" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHUTDOWN_CALLS"
EOF
chmod +x "$FAKE_SHUTDOWN"
FAKE_SU7="$TMP/softwareupdate7"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_SU7"; chmod +x "$FAKE_SU7"
MAIL7_LOG="$TMP/mail7.log"; FAKE_GC7="$TMP/gc7"
cat > "$FAKE_GC7" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MAIL7_LOG"
EOF
chmod +x "$FAKE_GC7"

# fake bd controlado por arquivo: modo "fail" -> rc=1 (estado DESCONHECIDO),
# senao devolve o JSON pedido (ex.: '[]' = zero in_progress).
FAKE_BD7="$TMP/bd7"; BD7_MODE="$TMP/bd7.mode"; BD7_JSON="$TMP/bd7.json"; BD7_COUNTER="$TMP/bd7-calls"
cat > "$FAKE_BD7" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$BD7_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$BD7_COUNTER"
if [ "\$(cat "$BD7_MODE" 2>/dev/null)" = "fail" ]; then echo "fake bd: dolt unreachable" >&2; exit 1; fi
cat "$BD7_JSON"
EOF
chmod +x "$FAKE_BD7"
set_bd7() { printf '%s' "$1" > "$BD7_MODE"; printf '%s\n' "$2" > "$BD7_JSON"; }

R7DIR="$TMP/rodada7"
LIVE7=$$
BOOT7=$(( $(/bin/date +%s) - 7200 ))
AFTER7=$(/bin/date -r $(( $(/bin/date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%S.000000)
mk7() { printf '{"rodada_id":"%s","pid":%s,"phase":"scraping","status":"%s","started_at":"%s"}' "$1" "$2" "$3" "$4" > "$R7DIR/$1.json"; }

reset7() {
  rm -f "$GATE_COUNTER" "$BD7_COUNTER" "$STREAK_FILE_PATH" "$SHUTDOWN_CALLS"
  : > "$NOTIFY_LOG"; : > "$FAKE_LOG"; : > "$MAIL7_LOG"
  rm -rf "$R7DIR"; mkdir -p "$R7DIR"
}
run_cg() {
  PATH="$FAKEBIN:$PATH" FAKE_HOUR=14 \
    CITY="$FAKE_CITY" BD_BIN="$FAKE_BD7" GC_BIN="$FAKE_GC7" \
    NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_AS_USER="nobody" \
    SHUTDOWN_BIN="$FAKE_SHUTDOWN" SOFTWAREUPDATE_BIN="$FAKE_SU7" \
    SCRAPER_RODADA_DIR="$R7DIR" SCRAPER_BOOT_EPOCH="$BOOT7" \
    NIGHTLY_REBOOT_RETRY_INTERVAL=1 NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS=3 \
    timeout 60 bash "$SCRIPT" "$@" >"$TMP/cg.out" 2>"$TMP/cg.err"
  echo $?
}
# Nada de efeito colateral: sem shutdown, sem log do noturno, sem notify, sem
# mail, e o streak exatamente como estava ($2 = valor esperado; vazio = ausente).
assert_read_only7() {
  local label="$1" want_streak="$2" got_streak
  got_streak=$(cat "$STREAK_FILE_PATH" 2>/dev/null || true)
  [ ! -s "$SHUTDOWN_CALLS" ] && ok "$label: nenhuma chamada de shutdown" || bad "$label: SAFETY — shutdown foi chamado: $(cat "$SHUTDOWN_CALLS")"
  [ ! -s "$FAKE_LOG" ] && ok "$label: log do noturno intocado" || bad "$label: escreveu no log do noturno: $(head -3 "$FAKE_LOG")"
  [ ! -s "$NOTIFY_LOG" ] && ok "$label: nenhum notify" || bad "$label: mandou notify: $(cat "$NOTIFY_LOG")"
  [ ! -s "$MAIL7_LOG" ] && ok "$label: nenhum mail" || bad "$label: mandou mail: $(cat "$MAIL7_LOG")"
  [ "$got_streak" = "$want_streak" ] && ok "$label: streak intocado (${want_streak:-ausente})" || bad "$label: streak mudou: esperava '${want_streak}', veio '${got_streak}'"
}
line_count7() { wc -l < "$TMP/cg.out" | tr -d ' '; }
has_line7() { grep -Fx -- "$1" "$TMP/cg.out" >/dev/null; }
line_of7() { grep -F -- "$1" "$TMP/cg.out" | head -1; }

echo "  -- 7a: tudo limpo (fora da janela de 01h) -> exit 0, tres linhas ok, streak intocado --"
reset7; write_fake_gate 1; set_bd7 json '[]'
printf '1\n' > "$STREAK_FILE_PATH"
rc=$(run_cg --check-guards)
[ "$rc" = "0" ] && ok "7a: exit 0 quando todos os guards estao ok" || bad "7a: esperava exit 0, veio $rc ($(head -3 "$TMP/cg.out" | tr '\n' '|'))"
[ "$(line_count7)" = "3" ] && ok "7a: exatamente uma linha por guard" || bad "7a: esperava 3 linhas, veio $(line_count7): $(tr '\n' '|' < "$TMP/cg.out")"
has_line7 "guard2 gate-markers: ok" && ok "7a: guard 2 ok" || bad "7a: falta 'guard2 gate-markers: ok'"
has_line7 "guard3 hq-in-progress: ok" && ok "7a: guard 3 ok" || bad "7a: falta 'guard3 hq-in-progress: ok'"
has_line7 "guard4 scraper-daily: ok" && ok "7a: guard 4 ok" || bad "7a: falta 'guard4 scraper-daily: ok'"
assert_read_only7 "7a" "1"

echo "  -- 7b: hq bloqueia E scraper rodando -> os DOIS aparecem (sem curto-circuito), sem retry --"
reset7; write_fake_gate 1; set_bd7 json '[{"id":"fake-inprogress-1"}]'
mk7 live "$LIVE7" running "$AFTER7"
printf '1\n' > "$STREAK_FILE_PATH"
rc=$(run_cg --check-guards)
[ "$rc" != "0" ] && ok "7b: exit != 0 com guard bloqueando (rc=$rc)" || bad "7b: exit 0 com hq em andamento e scraper rodando"
has_line7 "guard2 gate-markers: ok" && ok "7b: guard 2 ok" || bad "7b: falta 'guard2 gate-markers: ok'"
line_of7 "guard3 hq-in-progress:" | grep -F "BLOCK hq beads in_progress = 1" >/dev/null && ok "7b: guard 3 = BLOCK com o motivo" || bad "7b: linha do guard 3: '$(line_of7 'guard3 hq-in-progress:')'"
line_of7 "guard4 scraper-daily:" | grep -F "BLOCK" >/dev/null && ok "7b: guard 4 avaliado mesmo com o 3 bloqueado (sem curto-circuito)" || bad "7b: guard 4 nao foi avaliado apos o bloqueio do 3: '$(line_of7 'guard4 scraper-daily:')'"
line_of7 "guard4 scraper-daily:" | grep -F "live" >/dev/null && ok "7b: guard 4 nomeia a rodada" || bad "7b: guard 4 sem o id da rodada"
[ "$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)" = "1" ] && ok "7b: gate consultado uma vez (sem loop de retry)" || bad "7b: gate consultado $(cat "$GATE_COUNTER" 2>/dev/null || echo 0)x"
[ "$(cat "$BD7_COUNTER" 2>/dev/null || echo 0)" = "1" ] && ok "7b: hq consultado uma vez (sem loop de retry)" || bad "7b: bd consultado $(cat "$BD7_COUNTER" 2>/dev/null || echo 0)x"
assert_read_only7 "7b" "1"

echo "  -- 7c: SO a rodada do scraper (o incidente real) -> BLOCK no guard 4, 2 e 3 ok --"
reset7; write_fake_gate 1; set_bd7 json '[]'
mk7 bc6496e8 "$LIVE7" running "$AFTER7"
rc=$(run_cg --check-guards)
[ "$rc" != "0" ] && ok "7c: exit != 0 so por causa do scraper" || bad "7c: exit 0 com rodada do scraper rodando — reboot manual mataria o noturno de novo"
has_line7 "guard2 gate-markers: ok" && has_line7 "guard3 hq-in-progress: ok" && ok "7c: guards 2 e 3 ok" || bad "7c: guards 2/3 deviam estar ok: $(tr '\n' '|' < "$TMP/cg.out")"
line_of7 "guard4 scraper-daily:" | grep -F "BLOCK" | grep -F "bc6496e8" >/dev/null && ok "7c: guard 4 = BLOCK citando a rodada bc6496e8" || bad "7c: linha do guard 4: '$(line_of7 'guard4 scraper-daily:')'"
assert_read_only7 "7c" ""

echo "  -- 7d: estado DESCONHECIDO nos tres guards -> 'unknown', nunca 'ok' nem 'BLOCK' --"
reset7; write_fake_gate 0; set_bd7 fail ''
printf '{not json' > "$R7DIR/corrupt.json"
rc=$(run_cg --check-guards)
[ "$rc" != "0" ] && ok "7d: exit != 0 (unknown nao e ok)" || bad "7d: exit 0 com estado desconhecido — erro colapsado em ok"
[ "$(line_count7)" = "3" ] && ok "7d: uma linha por guard mesmo com stderr multilinha dos comandos" || bad "7d: esperava 3 linhas, veio $(line_count7): $(tr '\n' '|' < "$TMP/cg.out")"
line_of7 "guard2 gate-markers:" | grep -F ": unknown" >/dev/null && ok "7d: guard 2 = unknown" || bad "7d: linha do guard 2: '$(line_of7 'guard2 gate-markers:')'"
line_of7 "guard3 hq-in-progress:" | grep -F ": unknown" >/dev/null && ok "7d: guard 3 = unknown" || bad "7d: linha do guard 3: '$(line_of7 'guard3 hq-in-progress:')'"
line_of7 "guard4 scraper-daily:" | grep -F ": unknown" >/dev/null && ok "7d: guard 4 = unknown" || bad "7d: linha do guard 4: '$(line_of7 'guard4 scraper-daily:')'"
grep -E ": (ok|BLOCK)" "$TMP/cg.out" >/dev/null && bad "7d: um estado desconhecido foi rotulado ok/BLOCK: $(tr '\n' '|' < "$TMP/cg.out")" || ok "7d: nenhum desconhecido rotulado como ok ou BLOCK"
assert_read_only7 "7d" ""

echo "  -- 7e: argumento desconhecido -> recusa (exit 2), nao cai no fluxo real do reboot --"
reset7; write_fake_gate 1; set_bd7 json '[]'
rc=$(run_cg --check-guard)
[ "$rc" = "2" ] && ok "7e: typo em --check-guards sai com exit 2" || bad "7e: esperava exit 2, veio $rc — um typo cairia no fluxo real do reboot"
[ ! -s "$TMP/cg.out" ] && ok "7e: nenhuma saida de guard" || bad "7e: imprimiu saida de guard: $(head -3 "$TMP/cg.out" | tr '\n' '|')"
[ "$(cat "$GATE_COUNTER" 2>/dev/null || echo 0)" = "0" ] && [ "$(cat "$BD7_COUNTER" 2>/dev/null || echo 0)" = "0" ] && ok "7e: nenhum guard executado" || bad "7e: guards rodaram com argumento invalido"
assert_read_only7 "7e" ""

echo "  -- 7f: caminho do NOTURNO preservado apos extrair os guards (BLOCK_REASON identico), isolado por extracao --"
GUARDS_SNIPPET="$TMP/guards-functions.sh"
sed -n '/GUARDS-FUNCTIONS-START/,/GUARDS-FUNCTIONS-END/p' "$SCRIPT" > "$GUARDS_SNIPPET"
if [ ! -s "$GUARDS_SNIPPET" ]; then
  bad "7f: sentinel extraction found nothing in $SCRIPT — cannot test check_guards_once (expected on the pre-fix script)"
else
  # shellcheck disable=SC2034  # consumidas pelo snippet carregado dinamicamente
  CITY="$FAKE_CITY"
  # shellcheck disable=SC2034
  BD="$FAKE_BD7"
  # shellcheck disable=SC2034
  GATE_ERR="$TMP/gate-err7"
  # shellcheck disable=SC2034
  HQ_ERR="$TMP/hq-err7"
  # shellcheck source=/dev/null
  source "$SCRAPER_SNIPPET"
  # shellcheck source=/dev/null
  source "$GUARDS_SNIPPET"
  g7() { SCRAPER_RODADA_DIR="$R7DIR" SCRAPER_BOOT_EPOCH="$BOOT7" check_guards_once; }

  reset7; write_fake_gate 1; set_bd7 json '[]'
  g7; [ $? -eq 0 ] && ok "7f: tudo limpo -> check_guards_once retorna 0" || bad "7f: esperava 0 com tudo limpo"

  reset7; write_fake_gate 0; set_bd7 json '[]'
  g7; rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$BLOCK_REASON" | grep -F "gate-queue-composition.sh failed" >/dev/null && ok "7f: gate falhando -> mesma BLOCK_REASON de sempre" || bad "7f: rc=$rc reason='$BLOCK_REASON'"

  reset7; write_fake_gate 1; set_bd7 json '[{"id":"x"},{"id":"y"}]'
  g7; rc=$?
  [ "$rc" -eq 1 ] && [ "$BLOCK_REASON" = "hq beads in_progress = 2" ] && ok "7f: hq em andamento -> 'hq beads in_progress = 2'" || bad "7f: rc=$rc reason='$BLOCK_REASON'"

  reset7; write_fake_gate 1; set_bd7 json '[]'; mk7 live "$LIVE7" running "$AFTER7"
  g7; rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$BLOCK_REASON" | grep -F "property_scrapers daily em execução" >/dev/null && ok "7f: scraper rodando -> mesma BLOCK_REASON de sempre" || bad "7f: rc=$rc reason='$BLOCK_REASON'"

  reset7; write_fake_gate 1; set_bd7 json '[]'; printf '{not json' > "$R7DIR/corrupt.json"
  g7; rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$BLOCK_REASON" | grep -F "estado desconhecido" >/dev/null && ok "7f: scraper desconhecido -> continua NAO seguro" || bad "7f: rc=$rc reason='$BLOCK_REASON'"

  # curto-circuito do noturno preservado: gate falhando nao consulta o bd.
  reset7; write_fake_gate 0; set_bd7 json '[]'
  g7
  [ "$(cat "$BD7_COUNTER" 2>/dev/null || echo 0)" = "0" ] && ok "7f: noturno continua curto-circuitando (gate falho -> bd nao consultado)" || bad "7f: bd consultado apos falha do gate"
fi

echo ""
echo "nightly-reboot selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
