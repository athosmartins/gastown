#!/bin/bash
# dolt-s3-backup.selftest.sh — unit tests for is_stale_manifest_error(), the pure
# detection logic behind the ga-b5h83 staging-auto-reinit hardening.
#
# Hermetic: sources dolt-s3-backup.sh as a LIBRARY (DOLT_S3_BACKUP_LIB=1) so the
# live backup flow (lock, PORT probe, DOLT_BACKUP, aws s3 sync) never runs. Real
# Dolt/AWS are NEVER called; nothing is deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-s3-backup.sh"

export DOLT_S3_BACKUP_LIB=1
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-s3-backup.selftest.sh ==="

type is_stale_manifest_error >/dev/null 2>&1 \
  && ok "is_stale_manifest_error defined by lib-mode source" \
  || { bad "is_stale_manifest_error NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

# ── real captured failure (ga-b5h83, 2026-07-28 04:00 hq run) → MUST match ───────
REAL_ERR="error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): error opening table file: table file not found: /Users/athos/gt/.gascity-gastown-hq/.dolt-backup/hq/vljre1ianoi9rv9j7429njjiosmr1ior"
is_stale_manifest_error "$REAL_ERR" && ok "real captured error → detected" || bad "real captured error NOT detected"

# ── unrelated failures → must NOT match (never mask a different root cause) ──────
is_stale_manifest_error "connection refused" && bad "unrelated 'connection refused' should NOT match" || ok "unrelated 'connection refused' → not detected"
is_stale_manifest_error "context deadline exceeded" && bad "unrelated timeout should NOT match" || ok "unrelated timeout → not detected"
is_stale_manifest_error "" && bad "empty string should NOT match" || ok "empty string → not detected"
is_stale_manifest_error "no such file or directory" && bad "unrelated 'no such file' should NOT match" || ok "unrelated 'no such file or directory' → not detected"

# ── substring anywhere in a multi-line blob still matches (log captures full output) ─
MULTI="line one
line two: error opening table file: table file not found: /some/path
line three"
is_stale_manifest_error "$MULTI" && ok "substring mid-multiline blob → detected" || bad "multiline blob NOT detected"

# ── drift-guard: live script must actually wire the retry into the sync step ─────
echo "── drift-guard: wiring present in live script ──"
if grep -qF 'is_stale_manifest_error "$(cat "$SYNC_OUT")"' "$SCRIPT"; then
  ok "sync step calls is_stale_manifest_error on the captured sync output"
else
  bad "sync step does NOT call is_stale_manifest_error — detection is dead code"
fi
if grep -qF 'rm -rf "${dest:?}"' "$SCRIPT"; then
  ok "auto-reinit clears the per-db staging dir on detection"
else
  bad "auto-reinit rm -rf wiring missing — staging never gets reinitialized"
fi
if grep -qF '"$BACKUP_ROOT"/*)' "$SCRIPT"; then
  ok "auto-reinit path-safety guard present (dest must be under BACKUP_ROOT)"
else
  bad "auto-reinit path-safety guard missing"
fi
if grep -qF 'after auto-recover retry' "$SCRIPT"; then
  ok "retry is bounded to once (no infinite retry loop)"
else
  bad "bounded-retry-once wiring missing"
fi

# ── is_connection_timeout_error() — ga-gdsq5 transient-timeout retry mitigation ──
echo "── is_connection_timeout_error() (ga-gdsq5) ──"

type is_connection_timeout_error >/dev/null 2>&1 \
  && ok "is_connection_timeout_error defined by lib-mode source" \
  || { bad "is_connection_timeout_error NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

# ── real captured failure (ga-gdsq5, 2026-09-02 04:00:45 hq run) → MUST match ────
REAL_TIMEOUT_ERR="error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): connection was closed"
is_connection_timeout_error "$REAL_TIMEOUT_ERR" && ok "real captured error → detected" || bad "real captured error NOT detected"

# ── unrelated failures, INCLUDING the sibling detector's own case → must NOT match ─
is_connection_timeout_error "connection refused" && bad "unrelated 'connection refused' should NOT match" || ok "unrelated 'connection refused' → not detected"
is_connection_timeout_error "context deadline exceeded" && bad "unrelated timeout should NOT match" || ok "unrelated timeout → not detected"
is_connection_timeout_error "" && bad "empty string should NOT match" || ok "empty string → not detected"
is_connection_timeout_error "$REAL_ERR" && bad "stale-manifest error should NOT match connection-timeout detector" || ok "stale-manifest error → not detected by connection-timeout detector"
is_stale_manifest_error "$REAL_TIMEOUT_ERR" && bad "connection-timeout error should NOT match stale-manifest detector" || ok "connection-timeout error → not detected by stale-manifest detector"

# ── substring anywhere in a multi-line blob still matches (log captures full output) ─
MULTI_TIMEOUT="line one
line two: Error 1105 (HY000): connection was closed
line three"
is_connection_timeout_error "$MULTI_TIMEOUT" && ok "substring mid-multiline blob → detected" || bad "multiline blob NOT detected"

# ── drift-guard: live script must actually wire the retry into the sync step ─────
echo "── drift-guard: connection-timeout retry wiring present in live script ──"
if grep -qF 'is_connection_timeout_error "$(cat "$SYNC_OUT")"' "$SCRIPT"; then
  ok "sync step calls is_connection_timeout_error on the captured sync output"
else
  bad "sync step does NOT call is_connection_timeout_error — detection is dead code"
fi
if grep -qF '_sync_with_connection_timeout_retry "$db"' "$SCRIPT"; then
  ok "sync step calls _sync_with_connection_timeout_retry on connection-timeout"
else
  bad "sync step does NOT call _sync_with_connection_timeout_retry — retry escalation is dead code"
fi
if grep -qF 'RETRY_WAITS_SEC="20 60 120"' "$SCRIPT"; then
  ok "escalating retry waits configured as 20s/60s/120s (Mayor decision, ga-gdsq5, 2026-09-11)"
else
  bad "RETRY_WAITS_SEC no longer set to the decided 20/60/120 escalation"
fi

# ── _sync_with_connection_timeout_retry() — ga-gdsq5 escalating retry, exercised
# live with a simulated-failure stub (not just a drift-guard grep): the OLD
# single-retry code physically could not pass the "succeeds on 2nd retry"
# case below (it only ever tried once) — this proves the escalation is real,
# not just declared. Real dolt/network are NEVER called: $DOLT is pointed at
# a fake stub binary, and `sleep` is shadowed to record its argument instead
# of actually waiting (200s of real sleep across 3 waits would make this
# selftest suite unusably slow).
echo "── _sync_with_connection_timeout_retry() (ga-gdsq5) — simulated-failure test ──"

type _sync_with_connection_timeout_retry >/dev/null 2>&1 \
  && ok "_sync_with_connection_timeout_retry defined by lib-mode source" \
  || { bad "_sync_with_connection_timeout_retry NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

DOLT_STUB_DIR="$(mktemp -d)"
DOLT_STUB_COUNT_FILE="$(mktemp)"
TEST_LOG="$(mktemp)"
SLEEP_CALLS="$(mktemp)"
cat > "$DOLT_STUB_DIR/dolt" <<'STUB'
#!/bin/bash
# Fake `dolt`: fails with the ga-gdsq5 connection-timeout signature for the
# first DOLT_STUB_FAIL_UNTIL_CALL invocations, then succeeds.
n=$(( $(cat "$DOLT_STUB_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$DOLT_STUB_COUNT_FILE"
if [ "$n" -le "${DOLT_STUB_FAIL_UNTIL_CALL:-0}" ]; then
  echo "error on line 1 for query CALL DOLT_BACKUP('sync', 'testdb-backup'): Error 1105 (HY000): connection was closed"
  exit 1
fi
echo "ok"
STUB
chmod +x "$DOLT_STUB_DIR/dolt"
sleep() { printf '%s\n' "$1" >> "$SLEEP_CALLS"; }
export DOLT_STUB_COUNT_FILE

_run_retry_scenario() {
  # <fail_until_call> <label>
  local fail_until="$1" label="$2"
  echo "  -- scenario: $label --"
  echo 0 > "$DOLT_STUB_COUNT_FILE"
  : > "$SLEEP_CALLS"
  : > "$TEST_LOG"
  DOLT="$DOLT_STUB_DIR/dolt" HOST=127.0.0.1 PORT=0 LOG="$TEST_LOG" \
    DOLT_STUB_FAIL_UNTIL_CALL="$fail_until" \
    _sync_with_connection_timeout_retry "testdb"
}

# Scenario A: succeeds on the FIRST retry (0 prior failures within this call).
if _run_retry_scenario 0 "first retry succeeds"; then
  ok "scenario A (succeeds on 1st retry): returns success"
else
  bad "scenario A (succeeds on 1st retry): should have returned success"
fi
[ "$(cat "$SLEEP_CALLS")" = "20" ] \
  && ok "scenario A: slept exactly once, 20s, before the single needed attempt" \
  || bad "scenario A: expected one sleep call of 20 — got: $(cat "$SLEEP_CALLS" | tr '\n' ',')"

# Scenario B: fails once, succeeds on the SECOND retry. The old single-retry
# code could never reach this — it had no second attempt to succeed on.
if _run_retry_scenario 1 "second retry succeeds"; then
  ok "scenario B (succeeds on 2nd retry): returns success — proves escalation beyond a single retry"
else
  bad "scenario B (succeeds on 2nd retry): should have returned success"
fi
[ "$(cat "$SLEEP_CALLS" | tr '\n' ',')" = "20,60," ] \
  && ok "scenario B: slept 20s then 60s (one failed attempt, one successful attempt)" \
  || bad "scenario B: expected sleeps 20,60 — got: $(cat "$SLEEP_CALLS" | tr '\n' ',')"
grep -qF "sync OK after connection-timeout retry" "$TEST_LOG" \
  && ok "scenario B: logged the success line" \
  || bad "scenario B: missing the success log line"
grep -qF "DOLT_BACKUP sync FAILED" "$TEST_LOG" \
  && bad "scenario B: must NOT log a FAILED line — it eventually succeeded" \
  || ok "scenario B: no FAILED tripwire logged on eventual success"

# Scenario C: every attempt fails — all 3 waits exhausted, then gives up.
if _run_retry_scenario 999 "all retries exhausted"; then
  bad "scenario C (all retries exhausted): should have returned failure"
else
  ok "scenario C (all retries exhausted): returns failure after exhausting retries"
fi
[ "$(cat "$SLEEP_CALLS" | tr '\n' ',')" = "20,60,120," ] \
  && ok "scenario C: slept 20s, 60s, then 120s — all three configured waits used, none skipped" \
  || bad "scenario C: expected sleeps 20,60,120 — got: $(cat "$SLEEP_CALLS" | tr '\n' ',')"
grep -qF "DOLT_BACKUP sync FAILED (after connection-timeout retries)" "$TEST_LOG" \
  && ok "scenario C: logged the FAILED tripwire dolt-compact-routine.sh's precondition greps for" \
  || bad "scenario C: missing the FAILED tripwire line — compact's backup precondition would misread this as a pass"
[ "$(grep -cF 'sync OK' "$TEST_LOG")" -eq 0 ] \
  && ok "scenario C: no false 'sync OK' line when every attempt failed" \
  || bad "scenario C: logged a success line despite every attempt failing"

unset -f sleep
rm -rf "$DOLT_STUB_DIR" 2>/dev/null || true
rm -f "$DOLT_STUB_COUNT_FILE" "$TEST_LOG" "$SLEEP_CALLS" 2>/dev/null || true

# ── preflight-unreachable retry (ga-abrbt) — a transient blip in reachability
# at 04:00 used to cost the whole day (no retry at all: FATAL + exit 0 on the
# very first probe). Not independently unit-testable without a real Dolt
# connection (unlike the two pure detectors above), so — same convention as
# the drift-guards below — assert the live script actually wires the retry
# in, rather than skip coverage entirely.
echo "── drift-guard: preflight-unreachable retry wiring present in live script (ga-abrbt) ──"
if grep -qF '_dolt_reachable' "$SCRIPT"; then
  ok "reachability probe factored into a named function (reused by first check + each retry, not copy-pasted)"
else
  bad "_dolt_reachable helper missing — reachability check should be a single reused function"
fi
if grep -qF 'PREFLIGHT_RETRY_WAITS_MIN' "$SCRIPT" && grep -qE 'sleep "\$\(\( *wait_min \* 60 *\)\)"' "$SCRIPT"; then
  ok "retry loop actually sleeps using the configured wait-minutes list"
else
  bad "preflight retry does not wire PREFLIGHT_RETRY_WAITS_MIN into a real sleep"
fi
if grep -qF 'for wait_min in $PREFLIGHT_RETRY_WAITS_MIN' "$SCRIPT"; then
  ok "retry iterates the configured waits (not a single hardcoded attempt)"
else
  bad "retry loop over PREFLIGHT_RETRY_WAITS_MIN missing"
fi
# The ONLY two `_dolt_reachable` call sites must remain: the first probe and
# the retry-loop re-probe. A 3rd call site would mean the check drifted back
# into an inline duplicate somewhere (exactly the copy-paste this refactor
# exists to prevent).
callsites="$(grep -cF '_dolt_reachable' "$SCRIPT")"
[ "$callsites" -eq 3 ] \
  && ok "exactly 3 occurrences of _dolt_reachable (1 definition + 2 call sites: first probe, retry re-probe)" \
  || bad "expected exactly 3 occurrences of _dolt_reachable (def + 2 calls), got $callsites — check for a reintroduced duplicate inline probe"
# Safety invariant, unchanged by this fix: still NEVER attempts to start/
# restart Dolt anywhere in this script, retry included. Strip comments first
# (sed 's/#.*$//') — the script legitimately MENTIONS "dolt sql-server" twice
# in prose (a fallback-port comment, and the RESTORE section's own
# description), neither of which is an invocation; a plain grep over the
# whole file would false-positive on those two pre-existing comments.
if sed -E 's/#.*$//' "$SCRIPT" | grep -qiE '\bdolt (start|restart)\b|\bsql-server\b'; then
  bad "found a Dolt start/restart/sql-server invocation (outside comments) — this script must remain READ + export only, retry must never escalate to a restart"
else
  ok "no Dolt start/restart/sql-server invocation anywhere in the script (mentions in comments don't count) — retry only re-probes, never restarts"
fi
# The exhausted-retries message must still read as FATAL+unreachable so
# dolt-compact-routine.sh's _backup_today_ok() (ga-abrbt fix) can surface it
# verbatim as the reason a run never reached "run complete".
if grep -qE 'FATAL: Dolt server unreachable on \$HOST:\$PORT after retries' "$SCRIPT"; then
  ok "final give-up message still says FATAL + unreachable (so the compact routine's precondition message can quote it)"
else
  bad "final give-up message no longer identifiable as FATAL+unreachable — downstream _backup_today_ok parsing would degrade"
fi
if grep -qF 'notify_fail "backup off-box: Dolt inacessível' "$SCRIPT" && grep -cF 'exit 0' "$SCRIPT" | grep -qE '^[1-9][0-9]*$'; then
  ok "give-up path still notifies and exits 0 (never restarts, never a nonzero exit that could trip an external supervisor into restarting Dolt)"
else
  bad "give-up path's notify/exit-0 wiring looks different than expected"
fi

# ── is_disk_margin_refusal() (ga-8f1uh0) ──────────────────────────────────────
echo ""
echo "── is_disk_margin_refusal() (ga-8f1uh0) ──"

type is_disk_margin_refusal >/dev/null 2>&1 \
  && ok "is_disk_margin_refusal defined by lib-mode source" \
  || { bad "is_disk_margin_refusal NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

# ── real captured refusal text (dolt-backup-reseed.sh's own die() message) → MUST match ──
REAL_DISK_ERR="ABORTADO: disco insuficiente. NÃO iniciando: um sync que enche o disco no meio é exatamente como se corrompe o Dolt (precedente: ga-vs55, 14/07)."
is_disk_margin_refusal "$REAL_DISK_ERR" && ok "real captured disk-margin refusal → detected" || bad "real captured disk-margin refusal NOT detected"

# ── other reseed failure reasons → must NOT match (these are real data-integrity
# signals and must still reach notify_fail, never get swallowed as "benign") ──
is_disk_margin_refusal "o backup novo NÃO RESTAURA. Nada foi trocado; o antigo segue intacto." \
  && bad "restore-failure message should NOT match disk-margin detector" \
  || ok "restore-failure message → not detected (stays a real notify_fail)"
is_disk_margin_refusal "o backup novo tem MENOS dado que a origem (100 < 200). Nada foi trocado." \
  && bad "count-mismatch message should NOT match disk-margin detector" \
  || ok "count-mismatch message → not detected (stays a real notify_fail)"
is_disk_margin_refusal "" && bad "empty string should NOT match" || ok "empty string → not detected"

# ── substring anywhere in a multi-line blob still matches (captured output is multi-line) ──
MULTI_DISK="line one
espaço: preciso ~11701MB, livre 5455MB
ABORTADO: disco insuficiente. NÃO iniciando: ...
line three"
is_disk_margin_refusal "$MULTI_DISK" && ok "substring mid-multiline blob → detected" || bad "multiline blob NOT detected"

# ── is_stale_residue_refusal() (ga-8f1uh0) ────────────────────────────────────
echo ""
echo "── is_stale_residue_refusal() (ga-8f1uh0) ──"

type is_stale_residue_refusal >/dev/null 2>&1 \
  && ok "is_stale_residue_refusal defined by lib-mode source" \
  || { bad "is_stale_residue_refusal NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

REAL_RESIDUE_ERR="ABORTADO: /Users/athos/gt/.gascity-gastown-hq/.dolt-backup/gastown.old já existe — resíduo de uma execução anterior. Investigue antes."
is_stale_residue_refusal "$REAL_RESIDUE_ERR" && ok "real captured residue refusal → detected" || bad "real captured residue refusal NOT detected"
is_stale_residue_refusal "$REAL_DISK_ERR" && bad "disk-margin message should NOT match residue detector" || ok "disk-margin message → not detected by residue detector"
is_disk_margin_refusal "$REAL_RESIDUE_ERR" && bad "residue message should NOT match disk-margin detector" || ok "residue message → not detected by disk-margin detector"
is_stale_residue_refusal "" && bad "empty string should NOT match" || ok "empty string → not detected"

# ── drift-guard: live script must actually define the constant + wire the helper ──
echo "── drift-guard: reseed-after-upload wiring present in live script (ga-8f1uh0) ──"
if grep -qF 'RESEED_AFTER_UPLOAD="${RESEED_AFTER_UPLOAD:-1}"' "$SCRIPT"; then
  ok "RESEED_AFTER_UPLOAD defaults to enabled (1) — the P1 fix is on by default, not just available"
else
  bad "RESEED_AFTER_UPLOAD default changed or missing — was the P1 fix silently disabled?"
fi
if grep -qF '_reseed_staging_if_enabled "$db"' "$SCRIPT"; then
  ok "per-db loop calls _reseed_staging_if_enabled — wiring is live, not dead code"
else
  bad "_reseed_staging_if_enabled is defined but never called in the per-db loop"
fi
RESEED_CALL_LINE=$(grep -nF '_reseed_staging_if_enabled "$db"' "$SCRIPT" | head -1 | cut -d: -f1)
OK_INCR_LINE=$(grep -nF 'ok=$((ok+1))' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$RESEED_CALL_LINE" ] && [ -n "$OK_INCR_LINE" ] && [ "$RESEED_CALL_LINE" -gt "$OK_INCR_LINE" ]; then
  ok "reseed call happens AFTER ok=\$((ok+1)) — its own outcome never corrupts the core backup's ok/failed counters"
else
  bad "reseed call is not positioned after the ok counter increment"
fi
if grep -qF 'RESEED_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-backup-reseed.sh"' "$SCRIPT"; then
  ok "RESEED_SCRIPT resolves relative to this script's own directory (not a hardcoded absolute path)"
else
  bad "RESEED_SCRIPT wiring missing or changed shape"
fi

# ── _reseed_staging_if_enabled() (ga-8f1uh0) — exercised live with a stub reseed
# script and a stub notify binary (not just a drift-guard grep): proves the
# disk-margin/other-failure split actually gates notify_fail, and that the
# opt-out flag works. Real dolt-backup-reseed.sh and real notify are NEVER called.
echo "── _reseed_staging_if_enabled() (ga-8f1uh0) — simulated stub test ──"

type _reseed_staging_if_enabled >/dev/null 2>&1 \
  && ok "_reseed_staging_if_enabled defined by lib-mode source" \
  || { bad "_reseed_staging_if_enabled NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

RESEED_STUB_DIR="$(mktemp -d)"
NOTIFY_STUB_CALLS="$(mktemp)"
RESEED_TEST_LOG="$(mktemp)"
cat > "$RESEED_STUB_DIR/reseed.sh" <<'STUB'
#!/bin/bash
case "${RESEED_STUB_MODE:-ok}" in
  ok) echo "=== re-seed de '$1' concluído com sucesso ==="; exit 0 ;;
  disk) echo "ABORTADO: disco insuficiente. NÃO iniciando: ..."; exit 1 ;;
  residue) echo "ABORTADO: .dolt-backup/$1.old já existe — resíduo de uma execução anterior. Investigue antes."; exit 1 ;;
  other) echo "ABORTADO: o backup novo NÃO RESTAURA. Nada foi trocado."; exit 1 ;;
esac
STUB
chmod +x "$RESEED_STUB_DIR/reseed.sh"
cat > "$RESEED_STUB_DIR/notify" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTIFY_STUB_CALLS"
exit 0
STUB
chmod +x "$RESEED_STUB_DIR/notify"
export NOTIFY_STUB_CALLS

# Scenario A: reseed succeeds → logged OK, notify NOT called.
: > "$NOTIFY_STUB_CALLS"; : > "$RESEED_TEST_LOG"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=ok LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  _reseed_staging_if_enabled "testdb"
RC=$?
[ "$RC" -eq 0 ] && ok "scenario A (reseed OK): returns success" || bad "scenario A (reseed OK): expected success, got rc=$RC"
grep -qF "staging reseed OK" "$RESEED_TEST_LOG" && ok "scenario A: logged the OK line" || bad "scenario A: missing OK log line"
[ -s "$NOTIFY_STUB_CALLS" ] && bad "scenario A: notify should NOT fire on success" || ok "scenario A: notify correctly not called"

# Scenario B: reseed refuses for disk margin → logged skip, notify NOT called
# (expected/benign — would be daily noise until space recovers on its own).
: > "$NOTIFY_STUB_CALLS"; : > "$RESEED_TEST_LOG"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=disk LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  _reseed_staging_if_enabled "testdb"
RC=$?
[ "$RC" -eq 0 ] && ok "scenario B (disk-margin refusal): returns success (soft-skip, not a failure)" || bad "scenario B (disk-margin refusal): expected soft-skip rc=0, got rc=$RC"
grep -qF "skipped — insufficient disk margin" "$RESEED_TEST_LOG" && ok "scenario B: logged the skip line" || bad "scenario B: missing skip log line"
[ -s "$NOTIFY_STUB_CALLS" ] && bad "scenario B: notify should NOT fire on an expected disk-margin refusal" || ok "scenario B: notify correctly not called"

# Scenario B2 (ga-i99qsp, invariant d): a margin refusal that REPEATS must
# escalate to one notify_fail per streak (MARGIN_REFUSAL_ALARM_THRESHOLD),
# not stay silent forever — the old scenario B above only proves the FIRST
# occurrence stays quiet; this proves the streak actually gets tracked, one
# db's streak doesn't bleed into another's, and success resets it.
echo "── margin-refusal streak counter (ga-i99qsp, invariant d) ──"
MARGIN_STATE_DIR="$(mktemp -d)"
: > "$NOTIFY_STUB_CALLS"; : > "$RESEED_TEST_LOG"
for i in 1 2; do
  RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
    RESEED_STUB_MODE=disk LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
    MARGIN_REFUSAL_STATE_DIR="$MARGIN_STATE_DIR" MARGIN_REFUSAL_ALARM_THRESHOLD=3 \
    _reseed_staging_if_enabled "streakdb"
done
[ -s "$NOTIFY_STUB_CALLS" ] && bad "scenario B2: notify should NOT have fired yet after only 2 of 3 consecutive refusals" || ok "scenario B2: notify correctly silent through refusals 1-2 of 3"
grep -qF "1/3 rodadas" "$RESEED_TEST_LOG" && ok "scenario B2: log shows the streak count (1/3) on the first refusal" || bad "scenario B2: missing the streak-count log line"

RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=disk LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  MARGIN_REFUSAL_STATE_DIR="$MARGIN_STATE_DIR" MARGIN_REFUSAL_ALARM_THRESHOLD=3 \
  _reseed_staging_if_enabled "streakdb"
[ -s "$NOTIFY_STUB_CALLS" ] && ok "scenario B2: notify FIRES on the 3rd consecutive refusal (streak reached threshold)" || bad "scenario B2: notify should have fired on the 3rd consecutive refusal"
grep -qF "3 rodadas seguidas" "$NOTIFY_STUB_CALLS" && ok "scenario B2: notify message names the streak length" || bad "scenario B2: notify message should name the streak length"

: > "$NOTIFY_STUB_CALLS"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=disk LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  MARGIN_REFUSAL_STATE_DIR="$MARGIN_STATE_DIR" MARGIN_REFUSAL_ALARM_THRESHOLD=3 \
  _reseed_staging_if_enabled "streakdb"
[ -s "$NOTIFY_STUB_CALLS" ] && bad "scenario B2: notify should NOT fire again immediately after alarming — the streak must reset" || ok "scenario B2: streak resets after alarming (4th refusal alone doesn't re-fire)"

: > "$NOTIFY_STUB_CALLS"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=disk LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  MARGIN_REFUSAL_STATE_DIR="$MARGIN_STATE_DIR" MARGIN_REFUSAL_ALARM_THRESHOLD=3 \
  _reseed_staging_if_enabled "otherdb"
[ -s "$NOTIFY_STUB_CALLS" ] && bad "scenario B2: a DIFFERENT db's first refusal must not inherit streakdb's count" || ok "scenario B2: per-db streaks are independent (otherdb's 1st refusal doesn't alarm)"

RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=ok LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  MARGIN_REFUSAL_STATE_DIR="$MARGIN_STATE_DIR" MARGIN_REFUSAL_ALARM_THRESHOLD=3 \
  _reseed_staging_if_enabled "otherdb"
: > "$NOTIFY_STUB_CALLS"
for i in 1 2; do
  RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
    RESEED_STUB_MODE=disk LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
    MARGIN_REFUSAL_STATE_DIR="$MARGIN_STATE_DIR" MARGIN_REFUSAL_ALARM_THRESHOLD=3 \
    _reseed_staging_if_enabled "otherdb"
done
[ -s "$NOTIFY_STUB_CALLS" ] && bad "scenario B2: a success in between must reset the streak (2 refusals after an OK should not alarm at threshold 3)" || ok "scenario B2: a reseed success resets the streak — a later run of failures needs the full streak again"
rm -rf "$MARGIN_STATE_DIR" 2>/dev/null || true

# Scenario C: reseed fails for a NON-disk reason → logged FAILED, notify_fail DOES fire.
: > "$NOTIFY_STUB_CALLS"; : > "$RESEED_TEST_LOG"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=other LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  _reseed_staging_if_enabled "testdb"
RC=$?
[ "$RC" -eq 1 ] && ok "scenario C (non-disk failure): returns failure" || bad "scenario C (non-disk failure): expected rc=1, got rc=$RC"
grep -qF "staging reseed FAILED" "$RESEED_TEST_LOG" && ok "scenario C: logged the FAILED line" || bad "scenario C: missing FAILED log line"
[ -s "$NOTIFY_STUB_CALLS" ] && ok "scenario C: notify_fail correctly fired for a real (non-disk) failure" || bad "scenario C: notify_fail should have fired — a data-integrity signal must never go silent"

# Scenario C2: reseed refuses for stale .old/.new residue → logged BLOCKED,
# notify_fail DOES fire (not self-healing — needs a human to clear it once)
# with a message naming the specific path to remove.
: > "$NOTIFY_STUB_CALLS"; : > "$RESEED_TEST_LOG"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=1 \
  RESEED_STUB_MODE=residue LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  BACKUP_ROOT="/fake/.dolt-backup" \
  _reseed_staging_if_enabled "testdb"
RC=$?
[ "$RC" -eq 1 ] && ok "scenario C2 (residue refusal): returns failure" || bad "scenario C2 (residue refusal): expected rc=1, got rc=$RC"
grep -qF "staging reseed BLOCKED" "$RESEED_TEST_LOG" && ok "scenario C2: logged the BLOCKED line" || bad "scenario C2: missing BLOCKED log line"
grep -qF "resíduo (.old ou .new)" "$NOTIFY_STUB_CALLS" && ok "scenario C2: notify message names the residue cause specifically (actionable, not generic)" || bad "scenario C2: notify message should name the residue cause"

# Scenario D: RESEED_AFTER_UPLOAD=0 → reseed script never even invoked.
: > "$NOTIFY_STUB_CALLS"; : > "$RESEED_TEST_LOG"
RESEED_MARKER_FILE="$(mktemp -u)"   # deliberately not created — its existence after the call is the tell
export RESEED_MARKER_FILE
cat > "$RESEED_STUB_DIR/reseed_marker.sh" <<'STUB'
#!/bin/bash
touch "$RESEED_MARKER_FILE"
exit 0
STUB
chmod +x "$RESEED_STUB_DIR/reseed_marker.sh"
RESEED_SCRIPT="$RESEED_STUB_DIR/reseed_marker.sh" RESEED_TIMEOUT_SECS=5 RESEED_AFTER_UPLOAD=0 \
  LOG="$RESEED_TEST_LOG" NOTIFY="$RESEED_STUB_DIR/notify" \
  _reseed_staging_if_enabled "testdb"
RC=$?
[ "$RC" -eq 0 ] && ok "scenario D (opt-out): returns success (no-op)" || bad "scenario D (opt-out): expected rc=0, got rc=$RC"
[ -e "$RESEED_MARKER_FILE" ] && bad "scenario D: RESEED_AFTER_UPLOAD=0 must skip invoking the reseed script entirely" || ok "scenario D: reseed script correctly never invoked when disabled"
rm -f "$RESEED_MARKER_FILE" 2>/dev/null || true
unset RESEED_MARKER_FILE

rm -rf "$RESEED_STUB_DIR" 2>/dev/null || true
rm -f "$NOTIFY_STUB_CALLS" "$RESEED_TEST_LOG" 2>/dev/null || true
unset NOTIFY_STUB_CALLS

echo ""
echo "── jsonl_sizes_match() (ga-7gfd34) ──"

type jsonl_sizes_match >/dev/null 2>&1 \
  && ok "jsonl_sizes_match defined by lib-mode source" \
  || { bad "jsonl_sizes_match NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

jsonl_sizes_match "100" "100" && ok "equal sizes → match" || bad "equal sizes should match"
jsonl_sizes_match "100" "99" && bad "different sizes should NOT match" || ok "different sizes → no match"
jsonl_sizes_match "" "100" && bad "empty local size should NOT match" || ok "empty local size → no match"
jsonl_sizes_match "100" "" && bad "empty s3 size should NOT match" || ok "empty s3 size → no match"
jsonl_sizes_match "" "" && bad "two empty sizes should NOT match" || ok "two empty sizes → no match"
jsonl_sizes_match "abc" "100" && bad "non-numeric local size should NOT match" || ok "non-numeric local size → no match"
jsonl_sizes_match "100" "None" && bad "non-numeric s3 size (e.g. aws CLI 'None') should NOT match" || ok "non-numeric s3 size → no match"
jsonl_sizes_match "0" "0" && ok "zero equals zero → match" || bad "zero should equal zero"

echo ""
echo "── jsonl_offsite_sync() (ga-7gfd34) — simulated aws stub, real bucket NEVER touched ──"

type jsonl_offsite_sync >/dev/null 2>&1 \
  && ok "jsonl_offsite_sync defined by lib-mode source" \
  || { bad "jsonl_offsite_sync NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

AWS_STUB_DIR="$(mktemp -d)"
AWS_STUB_CALLS="$(mktemp)"
export AWS_STUB_CALLS
cat > "$AWS_STUB_DIR/aws" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$AWS_STUB_CALLS"
case "$1 $2" in
  "s3 sync")
    exit "${AWS_STUB_SYNC_EXIT:-0}"
    ;;
  "s3api head-object")
    if [ "${AWS_STUB_HEAD_EXIT:-0}" != "0" ]; then
      exit "$AWS_STUB_HEAD_EXIT"
    fi
    printf '%s\n' "${AWS_STUB_S3_SIZE:-0}"
    exit 0
    ;;
  *)
    echo "unhandled aws stub invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$AWS_STUB_DIR/aws"

JSONL_TEST_DIR="$(mktemp -d)"
printf 'x%.0s' $(seq 1 100) > "$JSONL_TEST_DIR/hq.jsonl"   # exactly 100 bytes
JSONL_TEST_LOG="$(mktemp)"

# Scenario A: sync succeeds, sizes match → overall success.
: > "$AWS_STUB_CALLS"; : > "$JSONL_TEST_LOG"
if AWS="$AWS_STUB_DIR/aws" JSONL_ARCHIVE_DIR="$JSONL_TEST_DIR" JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl" \
    BUCKET=testbucket S3=s3://testbucket LOG="$JSONL_TEST_LOG" S3_TIMEOUT=5 \
    AWS_STUB_SYNC_EXIT=0 AWS_STUB_S3_SIZE=100 \
    jsonl_offsite_sync; then
  ok "scenario A (sync ok, sizes match): returns success"
else
  bad "scenario A (sync ok, sizes match): should have returned success"
fi
grep -qF "verify OK" "$JSONL_TEST_LOG" && ok "scenario A: logged verify OK" || bad "scenario A: missing verify OK log line"
grep -qF -- '--exclude .git/*' "$AWS_STUB_CALLS" && ok "scenario A: sync call excluded .git" || bad "scenario A: sync call did NOT pass --exclude .git/*"
grep -qF -- '--delete' "$AWS_STUB_CALLS" && ok "scenario A: sync call prunes orphans (--delete), matching the per-db pattern" || bad "scenario A: sync call missing --delete"

# Scenario B: sync succeeds, sizes MISMATCH → failure, third-state-safe (never a silent pass).
: > "$AWS_STUB_CALLS"; : > "$JSONL_TEST_LOG"
if AWS="$AWS_STUB_DIR/aws" JSONL_ARCHIVE_DIR="$JSONL_TEST_DIR" JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl" \
    BUCKET=testbucket S3=s3://testbucket LOG="$JSONL_TEST_LOG" S3_TIMEOUT=5 \
    AWS_STUB_SYNC_EXIT=0 AWS_STUB_S3_SIZE=999 \
    jsonl_offsite_sync; then
  bad "scenario B (sizes mismatch): should have returned failure"
else
  ok "scenario B (sizes mismatch): returns failure"
fi
grep -qF "verify FAILED" "$JSONL_TEST_LOG" && ok "scenario B: logged verify FAILED" || bad "scenario B: missing verify FAILED log line"

# Scenario C: aws s3 sync itself fails → failure, verify (head-object) never attempted.
: > "$AWS_STUB_CALLS"; : > "$JSONL_TEST_LOG"
if AWS="$AWS_STUB_DIR/aws" JSONL_ARCHIVE_DIR="$JSONL_TEST_DIR" JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl" \
    BUCKET=testbucket S3=s3://testbucket LOG="$JSONL_TEST_LOG" S3_TIMEOUT=5 \
    AWS_STUB_SYNC_EXIT=1 \
    jsonl_offsite_sync; then
  bad "scenario C (sync fails): should have returned failure"
else
  ok "scenario C (sync fails): returns failure"
fi
grep -qF "aws s3 sync FAILED" "$JSONL_TEST_LOG" && ok "scenario C: logged aws s3 sync FAILED" || bad "scenario C: missing sync-failed log line"
grep -qF "head-object" "$AWS_STUB_CALLS" && bad "scenario C: verify (head-object) should NOT run when sync itself failed" || ok "scenario C: verify correctly skipped after sync failure"

# Scenario D: verify file absent locally (source looks empty/unpopulated) →
# the destructive --delete sync must be REFUSED entirely (return 2/skip), not
# attempted — an empty source with --delete would wipe the offsite copy.
: > "$AWS_STUB_CALLS"; : > "$JSONL_TEST_LOG"
EMPTY_JSONL_DIR="$(mktemp -d)"
AWS="$AWS_STUB_DIR/aws" JSONL_ARCHIVE_DIR="$EMPTY_JSONL_DIR" JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl" \
    BUCKET=testbucket S3=s3://testbucket LOG="$JSONL_TEST_LOG" S3_TIMEOUT=5 \
    AWS_STUB_SYNC_EXIT=0 \
    jsonl_offsite_sync
JSONL_SCENARIO_D_RC=$?
[ "$JSONL_SCENARIO_D_RC" -eq 2 ] \
  && ok "scenario D (verify file absent): returns skip(2) — refuses a --delete sync against an unpopulated source" \
  || bad "scenario D (verify file absent): expected return code 2 (skip), got $JSONL_SCENARIO_D_RC"
grep -qF "SKIP" "$JSONL_TEST_LOG" && ok "scenario D: logged a SKIP line" || bad "scenario D: missing SKIP log line"
grep -qF "sync" "$AWS_STUB_CALLS" \
  && bad "scenario D: aws s3 sync should NEVER be invoked against an unpopulated source (--delete would wipe the offsite copy)" \
  || ok "scenario D: aws was never invoked — destructive sync correctly refused before running"
rm -rf "$EMPTY_JSONL_DIR" 2>/dev/null || true

# Scenario E: head-object itself errors (permissions/network) → treated as a
# verify FAILURE, never a silent pass — the "can't tell" case must fail closed.
: > "$AWS_STUB_CALLS"; : > "$JSONL_TEST_LOG"
if AWS="$AWS_STUB_DIR/aws" JSONL_ARCHIVE_DIR="$JSONL_TEST_DIR" JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl" \
    BUCKET=testbucket S3=s3://testbucket LOG="$JSONL_TEST_LOG" S3_TIMEOUT=5 \
    AWS_STUB_SYNC_EXIT=0 AWS_STUB_HEAD_EXIT=1 \
    jsonl_offsite_sync; then
  bad "scenario E (head-object errors): should have returned failure, not a silent pass"
else
  ok "scenario E (head-object errors): returns failure — 'can't verify' fails closed"
fi
grep -qF "verify FAILED" "$JSONL_TEST_LOG" && ok "scenario E: logged verify FAILED" || bad "scenario E: missing verify FAILED log line"

rm -rf "$AWS_STUB_DIR" "$JSONL_TEST_DIR" 2>/dev/null || true
rm -f "$AWS_STUB_CALLS" "$JSONL_TEST_LOG" 2>/dev/null || true
unset AWS_STUB_CALLS

echo ""
echo "── drift-guard: jsonl offsite step wiring present in live script (ga-7gfd34) ──"
LOOP_DONE_LINE=$(grep -nF 'ok=$((ok+1))' "$SCRIPT" | head -1 | cut -d: -f1)
JSONL_CALL_LINE=$(grep -nF 'JSONL archive offsite mirror (ga-7gfd34)' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$LOOP_DONE_LINE" ] && [ -n "$JSONL_CALL_LINE" ] && [ "$JSONL_CALL_LINE" -gt "$LOOP_DONE_LINE" ]; then
  ok "jsonl offsite step is wired in AFTER the per-db loop ends (never inside it)"
else
  bad "jsonl offsite step position relative to the per-db loop looks wrong (or missing)"
fi
JSONL_WIRING_REGION="$(sed -n '/JSONL archive offsite mirror (ga-7gfd34)/,/publish a run fingerprint/p' "$SCRIPT")"
if printf '%s' "$JSONL_WIRING_REGION" | grep -qF 'jsonl_offsite_sync'; then
  ok "jsonl_offsite_sync is actually called in the live flow, not just defined"
else
  bad "jsonl_offsite_sync is defined but never called — dead code"
fi
if printf '%s' "$JSONL_WIRING_REGION" | grep -qF 'if [ "$failed" -eq 0 ]'; then
  bad "jsonl offsite step is gated on the per-db loop's success — must run even when a db backup FAILED"
else
  ok "jsonl offsite step is unconditional — runs even when a db backup above FAILED"
fi
if grep -qF 'jsonl_offsite=$JSONL_OFFSITE_STATUS' "$SCRIPT"; then
  ok "final run-complete summary counts jsonl offsite status separately from ok/failed/total"
else
  bad "final summary line does not report jsonl offsite status separately"
fi
if grep -qF 'notify_fail "backup off-box: cópia offsite do JSONL não subiu' "$SCRIPT"; then
  ok "jsonl offsite failure alerts via the SAME notify_fail channel, with the required message"
else
  bad "jsonl offsite failure does not notify with the expected message"
fi
if grep -qF 'if [ "$JSONL_OFFSITE_STATUS" = "failed" ]; then' "$SCRIPT"; then
  ok "jsonl offsite notify fires only on failed status (never on ok/skipped)"
else
  bad "jsonl offsite notify gating missing or changed shape"
fi
if grep -qF -- '--exclude ".git/*"' "$SCRIPT"; then
  ok "live script's jsonl sync excludes .git (~1.1GB of history no restore needs)"
else
  bad "live script's jsonl sync does not exclude .git"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
