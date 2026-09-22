#!/bin/bash
# Selftest for claude-credential-preflight.sh (ga-tkd2ll).
#
# Fully hermetic: NO real `claude` binary call, NO real `notify`, NO real
# `gc mail send mayor`. The auth-status check is a stub script whose output
# and exit code are staged per-test; notify/mail are stubs that just record
# whether they were invoked, so each test can assert alert-fired vs
# alert-silent precisely.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/claude-credential-preflight.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

SBX="$(mktemp -d /tmp/cred-preflight-selftest.XXXXXX)"
trap 'rm -rf "$SBX"' EXIT

AUTH_OUT="$SBX/auth_out.json"
AUTH_RC="$SBX/auth_rc"
NOTIFY_LOG="$SBX/notify.log"
MAIL_LOG="$SBX/mail.log"

AUTH_STUB="$SBX/auth-status-stub.sh"
cat > "$AUTH_STUB" <<EOF
#!/bin/bash
cat "$AUTH_OUT" 2>/dev/null
exit "\$(cat "$AUTH_RC" 2>/dev/null || echo 0)"
EOF
chmod +x "$AUTH_STUB"

SLOW_AUTH_STUB="$SBX/auth-status-slow-stub.sh"
cat > "$SLOW_AUTH_STUB" <<'EOF'
#!/bin/bash
sleep 5
echo '{"loggedIn":true,"email":"athosmartins@gmail.com"}'
EOF
chmod +x "$SLOW_AUTH_STUB"

NOTIFY_STUB="$SBX/notify-stub.sh"
cat > "$NOTIFY_STUB" <<EOF
#!/bin/bash
echo "called: \$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_STUB"

MAIL_STUB="$SBX/mail-stub.sh"
cat > "$MAIL_STUB" <<EOF
#!/bin/bash
echo "called: \$*" >> "$MAIL_LOG"
EOF
chmod +x "$MAIL_STUB"

stage_auth() { # <rc> <json-body>
  echo "$1" > "$AUTH_RC"
  printf '%s' "$2" > "$AUTH_OUT"
}

# Isolated bin dir containing only bash+timeout (no jq) — for the
# jq-missing UNKNOWN case. printf/command/[ are bash builtins, so this is
# sufficient without dragging in the rest of the real PATH.
JQLESS_BIN="$SBX/jqless-bin"
mkdir -p "$JQLESS_BIN"
ln -sf "$(command -v timeout)" "$JQLESS_BIN/timeout"
ln -sf "$(command -v bash)" "$JQLESS_BIN/bash"

run() { # extra env assignments as NAME=value args, then nothing else
  rm -f "$NOTIFY_LOG" "$MAIL_LOG"
  # ALERT_COOLDOWN_SEC=0 + a sandboxed STATE_DIR are defaults here, not
  # baked into the SUT: cooldown=0 means "the window always elapsed", so
  # every pre-existing test below keeps firing an alert on every run() call
  # regardless of the new dedup state shared across calls in this same
  # $SBX (env-assignment last-wins lets the rate-limit-specific tests
  # override both to exercise the real behavior).
  OUT=$(env \
    CLAUDE_CRED_PREFLIGHT_AUTH_STATUS_CMD="$AUTH_STUB" \
    CLAUDE_CRED_PREFLIGHT_NOTIFY_CMD="$NOTIFY_STUB" \
    CLAUDE_CRED_PREFLIGHT_MAIL_CMD="$MAIL_STUB" \
    CLAUDE_CRED_PREFLIGHT_BUDGET_SEC=3 \
    CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC=0 \
    CLAUDE_CRED_PREFLIGHT_STATE_DIR="$SBX/state" \
    "$@" bash "$SUT" 2>&1)
  RC=$?
}

alerted() { [ -s "$NOTIFY_LOG" ] && [ -s "$MAIL_LOG" ]; }
silent()  { [ ! -s "$NOTIFY_LOG" ] && [ ! -s "$MAIL_LOG" ]; }

echo "claude-credential-preflight selftest"

# ---------------------------------------------------------------------------
# 1. GOOD: known account, logged in -> exit 0, silent.
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":true,"email":"athosmartins@gmail.com","authMethod":"claude.ai"}'
run
if [ "$RC" = 0 ] && silent; then
  ok "GOOD: known account, exit 0, no alert"
else
  bad "GOOD: known account" "rc=$RC out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 2. BAD + shadow mode (default): loggedIn=false -> exit 0 (not blocked),
#    but alert fires (both notify and mail).
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":false}'
run
if [ "$RC" = 0 ] && alerted; then
  ok "BAD + shadow mode: exit 0, alert fires"
else
  bad "BAD + shadow mode" "rc=$RC out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 3. BAD + enforce mode: loggedIn=false, ENFORCE=1 -> exit 1 (blocked),
#    alert fires. This is the core regression this bead demands: today
#    (no preflight script exists at all) a spawn with loggedIn=false
#    proceeds unconditionally. This proves the new script actually blocks
#    it once armed.
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":false}'
run CLAUDE_CRED_PREFLIGHT_ENFORCE=1
if [ "$RC" = 1 ] && alerted; then
  ok "BAD + enforce mode: exit 1 (blocks spawn), alert fires"
else
  bad "BAD + enforce mode" "rc=$RC (want 1) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 4. WARN: logged in, but email not in known pool -> exit 0 EVEN WITH
#    enforce=1 (never blocks on an unrecognized-but-logged-in account —
#    the known list can go stale), alert fires.
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":true,"email":"some-other-account@gmail.com"}'
run CLAUDE_CRED_PREFLIGHT_ENFORCE=1
if [ "$RC" = 0 ] && alerted; then
  ok "WARN: unrecognized account never blocks even when enforced, alert fires"
else
  bad "WARN: unrecognized account" "rc=$RC (want 0) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 5. UNKNOWN: auth-status command times out -> exit 0 even when enforced,
#    NO alert (too noisy for a possibly-transient boot blip).
# ---------------------------------------------------------------------------
rm -f "$NOTIFY_LOG" "$MAIL_LOG"
OUT=$(env \
  CLAUDE_CRED_PREFLIGHT_AUTH_STATUS_CMD="$SLOW_AUTH_STUB" \
  CLAUDE_CRED_PREFLIGHT_NOTIFY_CMD="$NOTIFY_STUB" \
  CLAUDE_CRED_PREFLIGHT_MAIL_CMD="$MAIL_STUB" \
  CLAUDE_CRED_PREFLIGHT_BUDGET_SEC=1 \
  CLAUDE_CRED_PREFLIGHT_ENFORCE=1 \
  bash "$SUT" 2>&1)
RC=$?
if [ "$RC" = 0 ] && silent; then
  ok "UNKNOWN: timeout -> exit 0 even when enforced, no alert"
else
  bad "UNKNOWN: timeout" "rc=$RC (want 0) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 6. UNKNOWN: auth-status exits nonzero -> exit 0, no alert.
# ---------------------------------------------------------------------------
stage_auth 1 'some error text, not JSON'
run CLAUDE_CRED_PREFLIGHT_ENFORCE=1
if [ "$RC" = 0 ] && silent; then
  ok "UNKNOWN: nonzero exit from check -> exit 0, no alert"
else
  bad "UNKNOWN: nonzero exit from check" "rc=$RC (want 0) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 7. UNKNOWN: auth-status exits 0 but the loggedIn field is missing entirely
#    (unparseable/unexpected shape) -> exit 0, no alert. This is the
#    presence-vs-value regression case: a genuinely-absent field must not
#    be treated the same as a confirmed loggedIn:false.
# ---------------------------------------------------------------------------
stage_auth 0 '{"someOtherField":true}'
run CLAUDE_CRED_PREFLIGHT_ENFORCE=1
if [ "$RC" = 0 ] && silent; then
  ok "UNKNOWN: loggedIn field absent -> exit 0, no alert (not misread as BAD)"
else
  bad "UNKNOWN: loggedIn field absent" "rc=$RC (want 0) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 8. The jq-false-vs-empty regression, positive side: loggedIn is the JSON
#    boolean `false` (not a string, not absent) -> must still be read as a
#    real BAD, not silently downgraded to UNKNOWN. (jq's `// empty`
#    alternative operator treats JSON false as falsy -- a naive
#    `.loggedIn // empty` would wrongly emit "" here. This proves the
#    has()+tostring approach in the SUT avoids that collapse.)
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":false,"email":"nobody@example.com"}'
run CLAUDE_CRED_PREFLIGHT_ENFORCE=1
if [ "$RC" = 1 ] && alerted; then
  ok "JSON false loggedIn is read as real BAD, not collapsed to UNKNOWN"
else
  bad "JSON false loggedIn regression" "rc=$RC (want 1) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 9. UNKNOWN: jq missing from PATH -> exit 0, no alert, no crash.
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":true,"email":"athosmartins@gmail.com"}'
rm -f "$NOTIFY_LOG" "$MAIL_LOG"
OUT=$(env -i PATH="$JQLESS_BIN" HOME="$HOME" \
  CLAUDE_CRED_PREFLIGHT_AUTH_STATUS_CMD="$AUTH_STUB" \
  CLAUDE_CRED_PREFLIGHT_NOTIFY_CMD="$NOTIFY_STUB" \
  CLAUDE_CRED_PREFLIGHT_MAIL_CMD="$MAIL_STUB" \
  CLAUDE_CRED_PREFLIGHT_BUDGET_SEC=3 \
  CLAUDE_CRED_PREFLIGHT_ENFORCE=1 \
  bash "$SUT" 2>&1)
RC=$?
if [ "$RC" = 0 ] && silent; then
  ok "UNKNOWN: jq missing from PATH -> exit 0, no alert"
else
  bad "UNKNOWN: jq missing" "rc=$RC (want 0) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 10. Known-email allowlist override via env var: a custom single email,
#     not in the hardcoded default list, is accepted as GOOD when supplied
#     via CLAUDE_CRED_PREFLIGHT_KNOWN_EMAILS.
# ---------------------------------------------------------------------------
stage_auth 0 '{"loggedIn":true,"email":"custom-pool-account@example.com"}'
run CLAUDE_CRED_PREFLIGHT_KNOWN_EMAILS="custom-pool-account@example.com"
if [ "$RC" = 0 ] && silent; then
  ok "known-email allowlist override accepts a custom account as GOOD"
else
  bad "known-email allowlist override" "rc=$RC (want 0) out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 11. SECURITY REGRESSION: a malicious `email` value (attacker-shaped as a
#     shell single-quote breakout, e.g. from a compromised/spoofed
#     `claude auth status` response) must NOT achieve command execution via
#     the alert path. Confirmed exploitable against an earlier draft that
#     built one string via `bash -c "$_NOTIFY_CMD ... '$msg'"` -- that hands
#     the already-expanded string to a SECOND shell parse, so a literal `'`
#     inside $msg's data closes the intended quoted argument early and lets
#     text after it run as real shell syntax (verified live in a throwaway
#     repro against that exact pattern before writing this test: the canary
#     file WAS created). The current code invokes $_NOTIFY_CMD/$_MAIL_CMD
#     directly with $msg as one double-quoted argv entry -- no second parse,
#     so this payload must land as inert data only.
# ---------------------------------------------------------------------------
CANARY="$SBX/pwned-canary"
rm -f "$CANARY"
PAYLOAD="x'; touch $CANARY #"
stage_auth 0 "$(printf '{"loggedIn":true,"email":"%s"}' "$PAYLOAD")"
run CLAUDE_CRED_PREFLIGHT_ENFORCE=1
if [ ! -e "$CANARY" ] && [ "$RC" = 0 ] && alerted; then
  ok "malicious email payload does not achieve command injection via alert path"
else
  bad "command injection regression" "canary_exists=$([ -e "$CANARY" ] && echo YES-VULNERABLE || echo no) rc=$RC out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi
rm -f "$CANARY"

# ---------------------------------------------------------------------------
# 12. ga-2g6w4s AC1: athosb85@gmail.com (added to claude_usage_collector.py's
#     ACCOUNTS by wa-b741h) must be in the default known-pool list -- 3
#     consecutive sessions logged in as it produce zero "unrecognized
#     account" alerts, not the WARN this bead reports.
# ---------------------------------------------------------------------------
for i in 1 2 3; do
  stage_auth 0 '{"loggedIn":true,"email":"athosb85@gmail.com","authMethod":"claude.ai"}'
  run
  if [ "$RC" = 0 ] && silent; then
    ok "ga-2g6w4s AC1: athosb85@gmail.com known account, exit 0, no alert (run $i/3)"
  else
    bad "ga-2g6w4s AC1: athosb85@gmail.com (run $i/3)" "rc=$RC out=$OUT notify_log=$(cat "$NOTIFY_LOG" 2>/dev/null) mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
  fi
done

# ---------------------------------------------------------------------------
# 13. ga-2g6w4s AC2: repeated "unrecognized account" triggers for the SAME
#     account within the cooldown window collapse into a single alert
#     instead of firing once per spawn (the reported symptom: 170 identical
#     messages in one night). Isolated state dir + a distinct fake email so
#     this doesn't cross-talk with test 4's WARN case (which shares $SBX/state
#     but runs with cooldown=0, so it never writes a state that could leak
#     in here -- this is belt-and-suspenders isolation, not a dependency).
# ---------------------------------------------------------------------------
RL_STATE="$SBX/ratelimit-state"
rm -rf "$RL_STATE"
stage_auth 0 '{"loggedIn":true,"email":"ratelimit-test@example.com"}'
run CLAUDE_CRED_PREFLIGHT_STATE_DIR="$RL_STATE" CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC=3600
FIRST_ALERTED=no; alerted && FIRST_ALERTED=yes
run CLAUDE_CRED_PREFLIGHT_STATE_DIR="$RL_STATE" CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC=3600
SECOND_ALERTED=no; alerted && SECOND_ALERTED=yes
run CLAUDE_CRED_PREFLIGHT_STATE_DIR="$RL_STATE" CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC=3600
THIRD_ALERTED=no; alerted && THIRD_ALERTED=yes
if [ "$FIRST_ALERTED" = yes ] && [ "$SECOND_ALERTED" = no ] && [ "$THIRD_ALERTED" = no ]; then
  ok "ga-2g6w4s AC2: repeated unrecognized-account alerts within cooldown collapse to 1 message (not 3)"
else
  bad "ga-2g6w4s AC2: repeat collapse" "first=$FIRST_ALERTED(want yes) second=$SECOND_ALERTED(want no) third=$THIRD_ALERTED(want no)"
fi

# ---------------------------------------------------------------------------
# 14. ga-2g6w4s AC2, "com contagem": once the cooldown window has elapsed,
#     the NEXT trigger sends again AND the message reports how many
#     occurrences (incl. itself) it collapsed -- 2 suppressed in test 13
#     plus this one = 3. Backdate the state file instead of sleeping 1h.
# ---------------------------------------------------------------------------
SENT_STATE_FILE=$(find "$RL_STATE" -name '*.last_sent' 2>/dev/null | head -1)
if [ -n "$SENT_STATE_FILE" ]; then
  echo $(( $(date +%s) - 3700 )) > "$SENT_STATE_FILE"
fi
run CLAUDE_CRED_PREFLIGHT_STATE_DIR="$RL_STATE" CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC=3600
if [ -n "$SENT_STATE_FILE" ] && alerted && grep -q 'x3 in the last' "$MAIL_LOG" 2>/dev/null; then
  ok "ga-2g6w4s AC2: after cooldown elapses, next trigger sends WITH a count of suppressed repeats"
else
  bad "ga-2g6w4s AC2: post-cooldown resend with count" "state_file=$SENT_STATE_FILE rc=$RC mail_log=$(cat "$MAIL_LOG" 2>/dev/null)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
