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
if grep -qF '_sync_with_stale_manifest_recovery "$db" "$dest"' "$SCRIPT"; then
  ok "sync step calls _sync_with_stale_manifest_recovery on stale-manifest detection"
else
  bad "sync step does NOT call _sync_with_stale_manifest_recovery — detection is dead code"
fi

# ── _sync_disk_preflight() (ga-odtd3f) — the disk-space gate itself ─────────
# Hermetic: shadows `du` and `df` as plain shell functions. Unlike
# dolt-backup-reseed.sh's _run_reseed (which needs a PATH-based fake `df`
# because it runs as a real subprocess), _sync_disk_preflight is called
# in-process here like every other function in this file, so shadowing
# works directly — no subprocess, no PATH tricks, real disk never touched
# or queried.
echo "── _sync_disk_preflight() (ga-odtd3f) ──"

type _sync_disk_preflight >/dev/null 2>&1 \
  && ok "_sync_disk_preflight defined by lib-mode source" \
  || { bad "_sync_disk_preflight NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

SDP_CITY="$(mktemp -d)"
SDP_LOG="$(mktemp)"
mkdir -p "$SDP_CITY/.beads/dolt/testdb"

# Fake du: only answers for the exact live-db path this function queries
# (keeps the fake honest about what it's asked — real du's output shape is
# "<kb><TAB><path>", matched by the live code's `awk '{print $1}'`).
du() {
  if [ "$2" = "$SDP_CITY/.beads/dolt/testdb" ]; then
    printf '%s\t%s\n' "${SDP_LIVE_KB-0}" "$2"
  else
    command du "$@"
  fi
}
# Fake df: only answers for /System/Volumes/Data (live code calls
# `df -k /System/Volumes/Data`, so $2 is the path), real df's output shape
# (header line + one data line, $4 = available KB — matched by the live
# code's `awk 'NR==2{print $4}'`).
df() {
  if [ "$2" = "/System/Volumes/Data" ]; then
    printf 'Filesystem 512-blocks Used Available Capacity iused ifree %%iused Mounted\n'
    printf '/dev/x 1 1 %s 1%% 1 1 1%% /System/Volumes/Data\n' "${SDP_FREE_KB-0}"
  else
    command df "$@"
  fi
}

_run_sdp() {
  # <live_kb|""> <free_kb|""> <margin_pct> <floor_gb>
  : > "$SDP_LOG"
  SDP_LIVE_KB="$1" SDP_FREE_KB="$2" \
    CITY="$SDP_CITY" LOG="$SDP_LOG" \
    SYNC_DISK_MARGIN_PCT="$3" SYNC_DISK_FLOOR_GB="$4" \
    _sync_disk_preflight "testdb"
}

# Comfortably sufficient: 1GB live, 150% margin needs 1.5GB, 10GB free.
if _run_sdp 1048576 10485760 150 3; then
  ok "sufficient disk (10GB free, needs ~1.5GB): proceeds"
else
  bad "sufficient disk (10GB free, needs ~1.5GB): should have proceeded"
fi
grep -qF "sync preflight OK" "$SDP_LOG" && ok "sufficient disk: logged OK" || bad "sufficient disk: missing OK log line"

# Insufficient: 1GB live, 150% margin needs 1.5GB, only 1GB free.
if _run_sdp 1048576 1048576 150 3; then
  bad "insufficient disk (1GB free, needs ~1.5GB): should have refused"
else
  ok "insufficient disk (1GB free, needs ~1.5GB): refuses"
fi
grep -qF "sync preflight REFUSED" "$SDP_LOG" && grep -qF "disco insuficiente" "$SDP_LOG" \
  && ok "insufficient disk: logged REFUSED with the expected reason text" \
  || bad "insufficient disk: missing REFUSED/disco insuficiente log line"

# Floor protects a tiny db: live=10MB (150% => need ~15MB, would pass on
# percentage alone) but free is only 1GB, well under the 3GB floor — must
# still refuse. Proves the floor is a REAL backstop, not dead code.
if _run_sdp 10240 1048576 150 3; then
  bad "tiny db under the 3GB floor (1GB free): should have refused via the floor"
else
  ok "tiny db under the 3GB floor (1GB free): refuses via the floor"
fi
grep -qF "piso=3GB" "$SDP_LOG" && ok "tiny-db case: log line cites the floor" || bad "tiny-db case: log line does not cite the floor"

# Boundary: free exactly equals need → must proceed (>=, not strict >).
# live=4GB, margin=100% => need=4GB exactly (kept above the 3GB floor on
# purpose, so the floor can never be the thing deciding this case); free=4GB
# exactly.
if _run_sdp 4194304 4194304 100 3; then
  ok "boundary (free == need exactly): proceeds"
else
  bad "boundary (free == need exactly): should have proceeded (>= is inclusive)"
fi

# Fail-closed: du can't read the live db size (simulated as an empty
# answer, e.g. path doesn't exist) → refuse, never guess.
if _run_sdp "" 10485760 150 3; then
  bad "unreadable live size: should refuse (fail-closed), not proceed on a guess"
else
  ok "unreadable live size: refuses (fail-closed)"
fi
grep -qF "could not measure live db size" "$SDP_LOG" \
  && ok "unreadable live size: logged the fail-closed reason" || bad "unreadable live size: missing fail-closed log line"

# Fail-closed: df can't read free space → refuse, never guess.
if _run_sdp 1048576 "" 150 3; then
  bad "unreadable free space: should refuse (fail-closed), not proceed on a guess"
else
  ok "unreadable free space: refuses (fail-closed)"
fi
grep -qF "could not measure free disk space" "$SDP_LOG" \
  && ok "unreadable free space: logged the fail-closed reason" || bad "unreadable free space: missing fail-closed log line"

# Env overrides actually take effect: a case that passes at 150% margin
# must refuse once SYNC_DISK_MARGIN_PCT is cranked way up — same numbers,
# only the env var changes. live=4GB kept above the 3GB floor on purpose
# (see the boundary case above) so this is genuinely testing the margin
# knob, not accidentally testing the floor again.
if _run_sdp 4194304 8388608 150 3; then
  ok "margin override sanity: 8GB free / 4GB live passes at 150% (need 6GB)"
else
  bad "margin override sanity: 8GB free / 4GB live should pass at 150% (need 6GB)"
fi
if _run_sdp 4194304 8388608 1000 3; then
  bad "margin override: same numbers must refuse once margin is 1000% (need 40GB)"
else
  ok "margin override: same numbers correctly refuse once margin is 1000% (need 40GB)"
fi

# Real incident anchor (ga-odtd3f, 2026-09-21 09:xx): hq live ~7.3G,
# free at the worst measured point ~596Mi. At this file's own default
# margin (150%), the preflight MUST have refused — this is the exact
# scenario the fix exists to catch, encoded as a regression anchor the
# same way REAL_ERR/REAL_TIMEOUT_ERR anchor the two detectors above.
HQ_LIVE_KB=$((7654400))   # ~7.3G
HQ_FREE_KB_AT_CRASH=$((596*1024))  # 596Mi
if _run_sdp "$HQ_LIVE_KB" "$HQ_FREE_KB_AT_CRASH" 150 3; then
  bad "ga-odtd3f incident numbers (hq ~7.3G live, 596Mi free): should have refused"
else
  ok "ga-odtd3f incident numbers (hq ~7.3G live, 596Mi free): refuses at default margin — this is the fix"
fi

unset -f du df
rm -rf "$SDP_CITY" 2>/dev/null || true
rm -f "$SDP_LOG" 2>/dev/null || true

# ── drift-guard: disk preflight actually wired into every write attempt ─────
echo "── drift-guard: disk preflight wiring present in live script (ga-odtd3f) ──"
if grep -qF 'if ! _sync_disk_preflight "$db"; then' "$SCRIPT"; then
  ok "at least one guarded call site uses the exact expected shape"
else
  bad "no call site matches the expected '_sync_disk_preflight' guard shape"
fi
callsites="$(grep -cF '_sync_disk_preflight "$db"' "$SCRIPT")"
[ "$callsites" -eq 5 ] \
  && ok "exactly 5 occurrences of _sync_disk_preflight \"\$db\" (1 in the main loop's initial attempt, 1 in the main loop's offline-fallback-after-timeout branch, 1 in the connection-timeout retry loop, 2 in stale-manifest recovery — retry + its own offline fallback)" \
  || bad "expected exactly 5 occurrences of _sync_disk_preflight \"\$db\" (def excluded — this counts call sites only), got $callsites — a guard was added, removed, or a call site's db var name drifted"
if grep -qF 'FAILED_DBS="$FAILED_DBS ${db}(disco)"' "$SCRIPT"; then
  ok "main-loop disk refusals are counted with a distinct (disco) marker, same pattern as (sync)/(s3)"
else
  bad "main-loop disk refusals are not counted with the expected (disco) marker — 'CONTADA' (Mayor's ga-odtd3f requirement) would silently regress"
fi

# ── _sync_with_stale_manifest_recovery() (ga-yct7r1) — exercised live with a
# simulated-failure stub (not just a drift-guard grep): the OLD code physically
# could not pass scenario B below (it had no offline fallback at all, and
# counted the db as failed the moment the reinit-retry failed) — this proves
# the fallback is real, not just declared. Real dolt/network are NEVER called:
# $DOLT is pointed at a fake stub binary, and _offline_backup_sync is shadowed
# by a controllable stub (its own behavior is covered by
# dolt-offline-backup-sync.selftest.sh — here we only need to prove this
# function calls it correctly and reacts to its result).
echo "── _sync_with_stale_manifest_recovery() (ga-yct7r1) — simulated-failure test ──"

type _sync_with_stale_manifest_recovery >/dev/null 2>&1 \
  && ok "_sync_with_stale_manifest_recovery defined by lib-mode source" \
  || { bad "_sync_with_stale_manifest_recovery NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

SMR_STUB_DIR="$(mktemp -d)"
SMR_DOLT_COUNT_FILE="$(mktemp)"
SMR_LOG="$(mktemp)"
SMR_DEST_PARENT="$(mktemp -d)"
SMR_DEST="$SMR_DEST_PARENT/testdb"

cat > "$SMR_STUB_DIR/dolt" <<'STUB'
#!/bin/bash
# Fake `dolt`: the reinit-retry attempt. Fails with the stale-manifest
# signature unless SMR_STUB_RETRY_OK=1.
n=$(( $(cat "$SMR_DOLT_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$SMR_DOLT_COUNT_FILE"
if [ "${SMR_STUB_RETRY_OK:-0}" = "1" ]; then
  echo "ok"
  exit 0
fi
echo "error opening table file: table file not found: /fake/path"
exit 1
STUB
chmod +x "$SMR_STUB_DIR/dolt"

SMR_OFFLINE_CALLS="$(mktemp)"
# Shadow the real _offline_backup_sync (sourced from dolt-offline-backup-sync.sh
# at the top of dolt-s3-backup.sh) for the duration of this scenario block only.
_offline_backup_sync() {
  printf '%s %s\n' "$1" "$2" >> "$SMR_OFFLINE_CALLS"
  [ "${SMR_STUB_OFFLINE_OK:-0}" = "1" ]
}
# Shadow the new disk preflight (ga-odtd3f) too — these scenarios exercise
# the stale-manifest retry/fallback CONTROL FLOW, not disk math (which gets
# its own dedicated hermetic tests below). Defaults to "disk OK" so
# scenarios A-C keep testing exactly what they tested before this gate
# existed; scenario D below flips it to prove the gate itself stops this
# function cold instead of writing into a disk already proven insufficient.
_sync_disk_preflight() { [ "${SMR_STUB_DISK_OK:-1}" = "1" ]; }

_run_smr_scenario() {
  # <retry_ok> <offline_ok> <label> [<disk_ok>]
  local retry_ok="$1" offline_ok="$2" label="$3" disk_ok="${4:-1}"
  echo "  -- scenario: $label --"
  rm -rf "$SMR_DEST"; mkdir -p "$SMR_DEST"; touch "$SMR_DEST/marker"
  echo 0 > "$SMR_DOLT_COUNT_FILE"
  : > "$SMR_LOG"; : > "$SMR_OFFLINE_CALLS"
  DOLT="$SMR_STUB_DIR/dolt" HOST=127.0.0.1 PORT=0 LOG="$SMR_LOG" BACKUP_ROOT="$SMR_DEST_PARENT" \
    SMR_STUB_RETRY_OK="$retry_ok" SMR_STUB_OFFLINE_OK="$offline_ok" SMR_STUB_DISK_OK="$disk_ok" \
    _sync_with_stale_manifest_recovery "testdb" "$SMR_DEST"
}

# Scenario A: reinit-retry succeeds → offline fallback never invoked.
if _run_smr_scenario 1 0 "reinit-retry succeeds"; then
  ok "scenario A (retry succeeds): returns success"
else
  bad "scenario A (retry succeeds): should have returned success"
fi
grep -qF "auto-recover OK after staging reinit" "$SMR_LOG" \
  && ok "scenario A: logged the auto-recover OK line" || bad "scenario A: missing auto-recover OK log line"
[ -s "$SMR_OFFLINE_CALLS" ] \
  && bad "scenario A: offline fallback should NOT be invoked when the retry itself succeeds" \
  || ok "scenario A: offline fallback correctly not invoked"
[ ! -e "$SMR_DEST/marker" ] \
  && ok "scenario A: staging dir was wiped before the retry (auto-reinit ran)" \
  || bad "scenario A: staging dir marker survived — auto-reinit did not run"

# Scenario B (the bug ga-yct7r1 closes): reinit-retry fails, offline fallback
# succeeds → the round finishes OK via the fallback, with BOTH log lines the
# bug's invariant (b) requires (which path failed, which path saved it).
if _run_smr_scenario 0 1 "retry fails, offline fallback succeeds"; then
  ok "scenario B (offline fallback succeeds): returns success — proves the fallback this bug was missing"
else
  bad "scenario B (offline fallback succeeds): should have returned success"
fi
grep -qF "stale-manifest retry FAILED — falling back to offline sync (no server involved)" "$SMR_LOG" \
  && ok "scenario B: logged which path was attempted (falling back)" || bad "scenario B: missing the falling-back log line"
grep -qF "offline-sync fallback OK" "$SMR_LOG" \
  && ok "scenario B: logged offline-sync fallback OK" || bad "scenario B: missing the offline-sync fallback OK log line"
[ "$(cat "$SMR_OFFLINE_CALLS")" = "testdb $SMR_DEST" ] \
  && ok "scenario B: offline fallback invoked with the correct db + dest" \
  || bad "scenario B: offline fallback invoked with unexpected args: $(cat "$SMR_OFFLINE_CALLS")"
grep -qF "DOLT_BACKUP sync FAILED" "$SMR_LOG" \
  && bad "scenario B: must NOT log a FAILED tripwire — it eventually succeeded via the fallback" \
  || ok "scenario B: no FAILED tripwire logged on eventual success"

# Scenario C: reinit-retry AND offline fallback both fail → counts as failed,
# fail-closed with the FAILED tripwire logged (invariant c: never a silent OK).
if _run_smr_scenario 0 0 "retry fails, offline fallback also fails"; then
  bad "scenario C (both fail): should have returned failure"
else
  ok "scenario C (both fail): returns failure"
fi
grep -qF "DOLT_BACKUP sync FAILED (after stale-manifest recovery)" "$SMR_LOG" \
  && ok "scenario C: logged the FAILED tripwire" || bad "scenario C: missing the FAILED tripwire line"
grep -qF "offline-sync fallback OK" "$SMR_LOG" \
  && bad "scenario C: must NOT log a false offline-sync fallback OK line" \
  || ok "scenario C: no false success line when the offline fallback also failed"

# Scenario D (ga-odtd3f): disk preflight refuses right after the rm -rf
# reinit — must fail immediately, must NOT attempt the retry OR the offline
# fallback (both would write into a disk already proven insufficient). Both
# retry_ok and offline_ok are set to 1 (would succeed if attempted) so a
# pass here can only mean the disk gate stopped things BEFORE either ran.
if _run_smr_scenario 1 1 "disk preflight refuses after reinit" 0; then
  bad "scenario D (disk refuses): should have returned failure"
else
  ok "scenario D (disk refuses): returns failure"
fi
grep -qF "DOLT_BACKUP sync FAILED (disk preflight refused after stale-manifest reinit)" "$SMR_LOG" \
  && ok "scenario D: logged the disk-preflight-refused tripwire" || bad "scenario D: missing the disk-preflight-refused tripwire line"
[ "$(cat "$SMR_DOLT_COUNT_FILE")" = "0" ] \
  && ok "scenario D: the reinit retry (_sync_once) was never attempted" \
  || bad "scenario D: _sync_once was called despite the disk preflight refusing first"
[ -s "$SMR_OFFLINE_CALLS" ] \
  && bad "scenario D: offline fallback should NOT be invoked when disk preflight already refused" \
  || ok "scenario D: offline fallback correctly not invoked"

unset -f _offline_backup_sync _sync_disk_preflight
rm -rf "$SMR_STUB_DIR" "$SMR_DEST_PARENT" 2>/dev/null || true
rm -f "$SMR_DOLT_COUNT_FILE" "$SMR_LOG" "$SMR_OFFLINE_CALLS" 2>/dev/null || true

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
# Shadow the new disk preflight (ga-odtd3f) — these scenarios exercise the
# escalating-retry CONTROL FLOW, not disk math (dedicated hermetic tests
# below). Defaults to "disk OK" so scenarios A-C keep testing exactly what
# they tested before this gate existed; scenario D below flips it to prove
# the gate stops the retry loop cold instead of sleeping into a full disk.
_sync_disk_preflight() { [ "${RETRY_STUB_DISK_OK:-1}" = "1" ]; }

_run_retry_scenario() {
  # <fail_until_call> <label> [<disk_ok>]
  local fail_until="$1" label="$2" disk_ok="${3:-1}"
  echo "  -- scenario: $label --"
  echo 0 > "$DOLT_STUB_COUNT_FILE"
  : > "$SLEEP_CALLS"
  : > "$TEST_LOG"
  DOLT="$DOLT_STUB_DIR/dolt" HOST=127.0.0.1 PORT=0 LOG="$TEST_LOG" \
    DOLT_STUB_FAIL_UNTIL_CALL="$fail_until" RETRY_STUB_DISK_OK="$disk_ok" \
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

# Scenario D (ga-odtd3f): disk preflight refuses before the FIRST retry
# attempt (fail_until=0 means the fake dolt would SUCCEED immediately if
# ever called) — must fail right after the first sleep, never call dolt,
# never sleep again for wait #2/#3. A pass here can only mean the disk gate
# stopped the loop, since the stub would otherwise succeed trivially.
if _run_retry_scenario 0 "disk preflight refuses before first retry" 0; then
  bad "scenario D (disk refuses): should have returned failure"
else
  ok "scenario D (disk refuses): returns failure"
fi
[ "$(cat "$SLEEP_CALLS" | tr '\n' ',')" = "20," ] \
  && ok "scenario D: slept once (20s) then stopped — did not proceed to wait #2/#3" \
  || bad "scenario D: expected exactly one sleep (20) — got: $(cat "$SLEEP_CALLS" | tr '\n' ',')"
[ "$(cat "$DOLT_STUB_COUNT_FILE")" = "0" ] \
  && ok "scenario D: the retry's dolt call was never attempted — disk preflight blocked it" \
  || bad "scenario D: dolt was invoked despite the disk preflight refusing first"
grep -qF "DOLT_BACKUP sync FAILED (disk preflight refused before connection-timeout retry)" "$TEST_LOG" \
  && ok "scenario D: logged the disk-preflight-refused tripwire" \
  || bad "scenario D: missing the disk-preflight-refused tripwire line"

unset -f sleep _sync_disk_preflight
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
if sed -E 's/#.*$//' "$SCRIPT" | grep -iE '\bdolt (start|restart)\b|\bsql-server\b' >/dev/null; then
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
if grep -qF 'notify_fail "backup off-box: Dolt inacessível' "$SCRIPT" && grep -cF 'exit 0' "$SCRIPT" | grep -E '^[1-9][0-9]*$' >/dev/null; then
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
if printf '%s' "$JSONL_WIRING_REGION" | grep -F 'jsonl_offsite_sync' >/dev/null; then
  ok "jsonl_offsite_sync is actually called in the live flow, not just defined"
else
  bad "jsonl_offsite_sync is defined but never called — dead code"
fi
if printf '%s' "$JSONL_WIRING_REGION" | grep -F 'if [ "$failed" -eq 0 ]' >/dev/null; then
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

echo ""
echo "── AWS_REQUEST_CHECKSUM_CALCULATION=when_required (ga-tyaozh) ──"
# Root cause: aws-cli/botocore defaults to wrapping every S3 upload body in
# botocore.httpchecksum.AwsChunkedWrapper (checksum trailer). On a dropped
# connection, botocore's retry tries to rewind that wrapper; when the rewind
# raises, botocore reports UnseekableStreamError ("stream is not seekable")
# and aborts instead of completing the retry — this hit hq's backup for real
# on 2026-09-21 and cascaded into a city-wide disk-pressure outage. Setting
# this var to "when_required" skips the wrapper entirely for PutObject/
# UploadPart (requestChecksumRequired=false for both), verified empirically
# against the real bucket via `aws --debug s3 cp` (body becomes a plain,
# genuinely seekable s3transfer.utils.ReadFileChunk; zero AwsChunkedWrapper,
# zero Content-Encoding/Transfer-Encoding/X-Amz-Trailer headers).

if [ "${AWS_REQUEST_CHECKSUM_CALCULATION:-}" = "when_required" ]; then
  ok "AWS_REQUEST_CHECKSUM_CALCULATION=when_required after lib-mode source"
else
  bad "AWS_REQUEST_CHECKSUM_CALCULATION not 'when_required' after lib-mode source (got '${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>}') — the AwsChunkedWrapper 'stream is not seekable' upload defect (ga-tyaozh) is UNPROTECTED"
fi

# Real subprocess proof: a stubbed aws binary records what IT sees in ITS OWN
# environment when invoked by the actual (unmodified) jsonl_offsite_sync's
# real "$AWS" s3 sync call — proves the var is genuinely exported/inherited
# by a child process, not just set in this shell, without reimplementing the
# call site.
CHECKSUM_STUB_DIR="$(mktemp -d)"
CHECKSUM_STUB_ENV="$(mktemp)"
cat > "$CHECKSUM_STUB_DIR/aws" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "s3 sync")
    printf '%s\n' "${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>}" >> "$CHECKSUM_STUB_ENV"
    exit 0
    ;;
  "s3api head-object")
    printf '100\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$CHECKSUM_STUB_DIR/aws"

CHECKSUM_TEST_DIR="$(mktemp -d)"
printf 'x%.0s' $(seq 1 100) > "$CHECKSUM_TEST_DIR/hq.jsonl"
CHECKSUM_TEST_LOG="$(mktemp)"
: > "$CHECKSUM_STUB_ENV"
AWS="$CHECKSUM_STUB_DIR/aws" CHECKSUM_STUB_ENV="$CHECKSUM_STUB_ENV" JSONL_ARCHIVE_DIR="$CHECKSUM_TEST_DIR" \
  JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl" BUCKET=testbucket S3=s3://testbucket \
  LOG="$CHECKSUM_TEST_LOG" S3_TIMEOUT=5 jsonl_offsite_sync >/dev/null 2>&1

SEEN="$(cat "$CHECKSUM_STUB_ENV" 2>/dev/null)"
if [ "$SEEN" = "when_required" ]; then
  ok "a real child 'aws s3 sync' subprocess (via the live jsonl_offsite_sync call site) actually inherits AWS_REQUEST_CHECKSUM_CALCULATION=when_required"
else
  bad "child aws subprocess did not see AWS_REQUEST_CHECKSUM_CALCULATION=when_required (saw '${SEEN:-<nothing captured>}') — the export is not reaching the upload call"
fi

rm -rf "$CHECKSUM_STUB_DIR" "$CHECKSUM_TEST_DIR" 2>/dev/null || true
rm -f "$CHECKSUM_STUB_ENV" "$CHECKSUM_TEST_LOG" 2>/dev/null || true

echo "── drift-guard: export precedes every upload call site in the live script ──"
EXPORT_LINE=$(grep -nF 'export AWS_REQUEST_CHECKSUM_CALCULATION=when_required' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$EXPORT_LINE" ]; then
  bad "export AWS_REQUEST_CHECKSUM_CALCULATION=when_required line not found in live script at all"
else
  ok "export line present in live script (line $EXPORT_LINE)"
  for marker in \
    '"$AWS" s3 sync "$JSONL_ARCHIVE_DIR/"' \
    '"$AWS" s3 sync "$dest/" "$S3/$db/"' \
    '"$AWS" s3 cp "$META" "$S3/_meta/latest.json"' \
    '"$AWS" s3 cp "$META" "$S3/_meta/$(date' \
  ; do
    CALL_LINE=$(grep -nF "$marker" "$SCRIPT" | head -1 | cut -d: -f1)
    if [ -z "$CALL_LINE" ]; then
      bad "drift-guard: upload call site not found (script changed shape?): $marker"
    elif [ "$CALL_LINE" -gt "$EXPORT_LINE" ]; then
      ok "drift-guard: upload call at line $CALL_LINE comes after the export (line $EXPORT_LINE): $marker"
    else
      bad "drift-guard: upload call at line $CALL_LINE comes BEFORE the export (line $EXPORT_LINE) — unprotected: $marker"
    fi
  done
fi

echo ""
echo "── consecutive-failure-night escalation (ga-rt7ljo) ──"

for fn in _backup_fail_streak_note_failure _backup_fail_streak_note_success \
          _backup_fail_note do_mail_mayor notify_escalate _backup_escalate_if_needed; do
  type "$fn" >/dev/null 2>&1 \
    && ok "$fn defined by lib-mode source" \
    || bad "$fn NOT defined — lib mode broken"
done

# ── _backup_fail_streak_note_failure / _success — per-db independent streak,
# separate state/counter from the reseed margin-refusal streak above (this
# one tracks whether the off-box backup ITSELF succeeded on a given run).
echo "── _backup_fail_streak_note_failure / _success (per-db streak) ──"
BFS_STATE_DIR="$(mktemp -d)"

n1="$(BACKUP_FAIL_STREAK_DIR="$BFS_STATE_DIR" _backup_fail_streak_note_failure "hq")"
[ "$n1" = "1" ] && ok "1st failure for hq: streak=1" || bad "1st failure for hq: expected streak=1, got '$n1'"
n2="$(BACKUP_FAIL_STREAK_DIR="$BFS_STATE_DIR" _backup_fail_streak_note_failure "hq")"
[ "$n2" = "2" ] && ok "2nd consecutive failure for hq: streak=2" || bad "2nd consecutive failure for hq: expected streak=2, got '$n2'"

n_other="$(BACKUP_FAIL_STREAK_DIR="$BFS_STATE_DIR" _backup_fail_streak_note_failure "whatsapp_automation")"
[ "$n_other" = "1" ] && ok "a DIFFERENT db's first failure does not inherit hq's streak" || bad "cross-db streak leak: expected 1, got '$n_other'"

BACKUP_FAIL_STREAK_DIR="$BFS_STATE_DIR" _backup_fail_streak_note_success "hq"
n3="$(BACKUP_FAIL_STREAK_DIR="$BFS_STATE_DIR" _backup_fail_streak_note_failure "hq")"
[ "$n3" = "1" ] && ok "success resets hq's streak — next failure starts at 1 again" || bad "success did not reset streak: expected 1, got '$n3'"

rm -rf "$BFS_STATE_DIR" 2>/dev/null || true

# ── persistence failure is its OWN state, never "1" and never a fabricated
# threshold hit (gate feedback ga-c3sqn1): the counter lives on the disk whose
# exhaustion causes these failures, so "couldn't record it" is a likely state.
# Before this fix `echo "$n" > "$f"` was unchecked — a failed write returned
# the freshly-computed $n as if durable, the next night re-read nothing and
# counted 1 again, and the 2+-nights escalation could never fire.
echo "── _backup_fail_streak_note_failure: persistence failure ≠ success (gate ga-c3sqn1) ──"
BFP_ROOT="$(mktemp -d)"
_BFP_SAVE_LOG="$LOG"; LOG="$BFP_ROOT/log"   # never write test lines to the live backup log
_bfp_run() {  # <dir> <db> → BFP_OUT (stdout), BFP_RC (status)
  BFP_OUT="$(BACKUP_FAIL_STREAK_DIR="$1" _backup_fail_streak_note_failure "$2")"; BFP_RC=$?
}
_bfp_count() {  # <dir> [name-glob] → number of entries (dotfiles included) in <dir> whose name matches
  local c=0 e pat="${2:-*}"
  for e in "$1"/* "$1"/.[!.]*; do
    [ -e "$e" ] || continue
    # shellcheck disable=SC2254  # $pat is deliberately an unquoted glob pattern
    case "${e##*/}" in $pat) c=$((c+1)) ;; esac
  done
  echo "$c"
}

# (a) state dir cannot be created (parent component is a regular file).
: > "$BFP_ROOT/afile"
_bfp_run "$BFP_ROOT/afile/sub" hq
{ [ "$BFP_RC" -eq 1 ] && [ -z "$BFP_OUT" ]; } \
  && ok "mkdir failure → rc=1 and NO count on stdout (not a fabricated threshold hit)" \
  || bad "mkdir failure: expected rc=1 + empty stdout, got rc=$BFP_RC out='$BFP_OUT'"

# (b) THE reviewer's scenario: dir exists (mkdir -p trivially succeeds) but the
# write/rename fails. `mv` is shadowed by a function so this is deterministic
# even as root; the previous night's count must survive the failed attempt.
BFP_B="$BFP_ROOT/b"; mkdir -p "$BFP_B"
_bfp_run "$BFP_B" hq
{ [ "$BFP_RC" -eq 0 ] && [ "$BFP_OUT" = "1" ]; } && ok "baseline: 1st failure persisted (rc=0, count 1)" || bad "baseline failed: rc=$BFP_RC out='$BFP_OUT'"
mv() { return 1; }
_bfp_run "$BFP_B" hq
unset -f mv
{ [ "$BFP_RC" -eq 1 ] && [ -z "$BFP_OUT" ]; } \
  && ok "write/rename failure on an EXISTING dir → rc=1, no count (was: returned the unpersisted \$n as if durable)" \
  || bad "write failure on existing dir: expected rc=1 + empty stdout, got rc=$BFP_RC out='$BFP_OUT'"
[ "$(cat "$BFP_B/hq" 2>/dev/null)" = "1" ] \
  && ok "failed write did not destroy the previous night's count (still 1) — temp-file+rename, not truncate-in-place" \
  || bad "previous count damaged by a failed write: '$(cat "$BFP_B/hq" 2>/dev/null)'"
[ "$(_bfp_count "$BFP_B" '*.tmp.*')" = "0" ] && ok "failed write left no temp file behind" || bad "temp file leaked after failed write ($(_bfp_count "$BFP_B" '*.tmp.*') matching entries in $BFP_B)"

# (c) write "succeeds" but the value on disk is not what we computed.
BFP_C="$BFP_ROOT/c"; mkdir -p "$BFP_C"
mv() { printf '99\n' > "$3"; }
_bfp_run "$BFP_C" hq
unset -f mv
{ [ "$BFP_RC" -eq 1 ] && [ -z "$BFP_OUT" ]; } \
  && ok "read-back mismatch → rc=1 (the effect is verified, not the exit code)" \
  || bad "read-back mismatch: expected rc=1 + empty stdout, got rc=$BFP_RC out='$BFP_OUT'"

# (d) an existing counter that cannot be READ is "unknown", not "no history".
BFP_D="$BFP_ROOT/d"; mkdir -p "$BFP_D/hq"      # a directory sits where the counter file should be
_bfp_run "$BFP_D" hq
{ [ "$BFP_RC" -eq 1 ] && [ -z "$BFP_OUT" ]; } \
  && ok "existing-but-unreadable counter → rc=1 (was: silently read as 0 and reset to 1)" \
  || bad "unreadable existing counter: expected rc=1 + empty stdout, got rc=$BFP_RC out='$BFP_OUT'"

# (e) a REAL filesystem refusal (read-only dir), when not root (root bypasses modes).
if [ "$(id -u)" != "0" ]; then
  BFP_E="$BFP_ROOT/e"; mkdir -p "$BFP_E"; chmod 555 "$BFP_E"
  _bfp_run "$BFP_E" hq
  chmod 755 "$BFP_E"
  { [ "$BFP_RC" -eq 1 ] && [ -z "$BFP_OUT" ]; } \
    && ok "real read-only state dir (chmod 555) → rc=1, no count" \
    || bad "read-only state dir: expected rc=1 + empty stdout, got rc=$BFP_RC out='$BFP_OUT'"
else
  echo "  SKIP: real read-only dir case (running as root — modes are bypassed; (b) covers the same path)"
fi

# (f) the healthy path leaves exactly one file per db and no temp litter.
BFP_F="$BFP_ROOT/f"; mkdir -p "$BFP_F"
_bfp_run "$BFP_F" hq; _bfp_run "$BFP_F" hq
{ [ "$BFP_OUT" = "2" ] && [ "$(_bfp_count "$BFP_F")" = "1" ]; } \
  && ok "healthy path: count 2 after 2 failures, exactly one file, no temp litter" \
  || bad "healthy path: out='$BFP_OUT' entries=$(_bfp_count "$BFP_F")"

# (g) an existing counter holding garbage/empty content: the previous streak
# is NOT knowable, so this night is UNKNOWN (rc=1) — not silently "no history"
# (=1). It self-heals: the counter is rewritten to 1, so the next night counts
# 2 and confirms normally instead of alarming as "unknown" forever.
for _bfp_junk in "abc" ""; do
  BFP_G="$BFP_ROOT/g"; mkdir -p "$BFP_G"; printf '%s' "$_bfp_junk" > "$BFP_G/hq"
  _bfp_run "$BFP_G" hq
  { [ "$BFP_RC" -eq 1 ] && [ -z "$BFP_OUT" ]; } \
    && ok "counter holding '${_bfp_junk:-<empty>}' → this night UNKNOWN (rc=1), not silently read as 'no history'" \
    || bad "counter holding '${_bfp_junk:-<empty>}': expected rc=1 + empty stdout, got rc=$BFP_RC out='$BFP_OUT'"
  [ "$(cat "$BFP_G/hq" 2>/dev/null)" = "1" ] && ok "  …and was repaired to 1 (this run's failure)" || bad "  …not repaired: '$(cat "$BFP_G/hq" 2>/dev/null)'"
  _bfp_run "$BFP_G" hq
  { [ "$BFP_RC" -eq 0 ] && [ "$BFP_OUT" = "2" ]; } && ok "  …next night counts 2 and confirms normally (self-healed)" || bad "  …next night: expected rc=0 out=2, got rc=$BFP_RC out='$BFP_OUT'"
done
unset _bfp_junk

# (h) a streak reset that did not take must be VISIBLE (a stale streak would
# survive a successful backup and the next failure would over-claim
# consecutive nights). `rm` is shadowed as a no-op so the file stays.
BFP_H="$BFP_ROOT/h"; mkdir -p "$BFP_H"; printf '1\n' > "$BFP_H/hq"
: > "$LOG"
BACKUP_FAIL_STREAK_DIR="$BFP_H" _backup_fail_streak_note_success hq
[ ! -s "$LOG" ] && [ ! -e "$BFP_H/hq" ] && ok "reset that works: counter gone, nothing logged" || bad "healthy reset: file present or log noisy — log: $(cat "$LOG")"
printf '1\n' > "$BFP_H/hq"; : > "$LOG"
rm() { return 0; }
BACKUP_FAIL_STREAK_DIR="$BFP_H" _backup_fail_streak_note_success hq
unset -f rm
grep -qF "could NOT be reset" "$LOG" && ok "reset that did NOT take is logged (was: swallowed by || true)" || bad "failed reset not logged — log: $(cat "$LOG")"

# _backup_fail_note routes an UNKNOWN streak to its own list — never into
# ESCALATE_DBS (that would claim a confirmed streak nobody counted).
BACKUP_FAIL_STREAK_DIR="$BFP_ROOT/afile/sub"; BACKUP_FAIL_ALARM_THRESHOLD=2
FAILED_DBS_STREAK=""; ESCALATE_DBS=""; UNKNOWN_STREAK_DBS=""
_backup_fail_note "hq"
[ "$FAILED_DBS_STREAK" = " hq(?n)" ] && ok "unknown streak shown as hq(?n) in the summary, not a number" || bad "unexpected FAILED_DBS_STREAK for unknown streak: '$FAILED_DBS_STREAK'"
[ -z "$ESCALATE_DBS" ] && ok "unknown streak is NOT recorded as a confirmed threshold hit (ESCALATE_DBS empty)" || bad "unknown streak leaked into ESCALATE_DBS='$ESCALATE_DBS'"
[ "$UNKNOWN_STREAK_DBS" = " hq" ] && ok "unknown streak recorded in UNKNOWN_STREAK_DBS" || bad "UNKNOWN_STREAK_DBS='$UNKNOWN_STREAK_DBS'"
grep -qF "hq: contador de noites seguidas ilegível" "$LOG" && ok "unknown streak is logged" || bad "unknown streak not logged in $LOG"
unset BACKUP_FAIL_STREAK_DIR BACKUP_FAIL_ALARM_THRESHOLD FAILED_DBS_STREAK ESCALATE_DBS UNKNOWN_STREAK_DBS
LOG="$_BFP_SAVE_LOG"; unset _BFP_SAVE_LOG BFP_OUT BFP_RC
rm -rf "$BFP_ROOT" 2>/dev/null || true

# ── _backup_fail_note() — pure accumulation into FAILED_DBS_STREAK (the
# per-store "quantos dias sem backup OK" the final summary line names) and
# ESCALATE_DBS (only once a streak crosses BACKUP_FAIL_ALARM_THRESHOLD).
echo "── _backup_fail_note() accumulation ──"
BFN_STATE_DIR="$(mktemp -d)"
BACKUP_FAIL_STREAK_DIR="$BFN_STATE_DIR"
BACKUP_FAIL_ALARM_THRESHOLD=2
FAILED_DBS_STREAK=""
ESCALATE_DBS=""
_backup_fail_note "hq"
[ "$FAILED_DBS_STREAK" = " hq(1n)" ] && ok "1st failure recorded as hq(1n) in FAILED_DBS_STREAK" || bad "unexpected FAILED_DBS_STREAK after 1st failure: '$FAILED_DBS_STREAK'"
[ -z "$ESCALATE_DBS" ] && ok "1st failure (streak=1 < threshold=2): ESCALATE_DBS stays empty" || bad "1st failure should NOT escalate — ESCALATE_DBS='$ESCALATE_DBS'"

_backup_fail_note "hq"
[ "$FAILED_DBS_STREAK" = " hq(1n) hq(2n)" ] && ok "2nd consecutive failure appended as hq(2n)" || bad "unexpected FAILED_DBS_STREAK after 2nd failure: '$FAILED_DBS_STREAK'"
[ "$ESCALATE_DBS" = " hq(2n)" ] && ok "2nd consecutive failure (streak=2 >= threshold=2): ESCALATE_DBS names hq" || bad "2nd consecutive failure should escalate — ESCALATE_DBS='$ESCALATE_DBS'"

unset BACKUP_FAIL_STREAK_DIR BACKUP_FAIL_ALARM_THRESHOLD FAILED_DBS_STREAK ESCALATE_DBS
rm -rf "$BFN_STATE_DIR" 2>/dev/null || true

# ── end-to-end routing proof (the bead's own acceptance criterion): 1
# isolated failure must NOT escalate (stays on notify_fail's default digest
# route, untouched by this fix); the SAME store failing 2 CONSECUTIVE runs
# MUST mail the Mayor and force a real push. Real subprocess stubs for both
# `notify` and the mail sender — the notify stub records what IT sees in ITS
# OWN environment (same technique as the AWS_REQUEST_CHECKSUM_CALCULATION
# proof above), proving NOTIFY_FORCE_PUSH is genuinely exported to the
# child, not just asserted in-process.
echo "── end-to-end: 1 falha isolada → sem escalação; 2 seguidas → mail+push forçado (ga-rt7ljo) ──"
ESC_STUB_DIR="$(mktemp -d)"
ESC_NOTIFY_CALLS="$(mktemp)"
ESC_MAIL_CALLS="$(mktemp)"
ESC_STATE_DIR="$(mktemp -d)"
ESC_LOG="$(mktemp)"

cat > "$ESC_STUB_DIR/notify" <<'STUB'
#!/bin/bash
printf 'FORCE=%s ARGS=%s\n' "${NOTIFY_FORCE_PUSH:-<unset>}" "$*" >> "$ESC_NOTIFY_CALLS"
exit 0
STUB
chmod +x "$ESC_STUB_DIR/notify"
cat > "$ESC_STUB_DIR/fake_mail" <<'STUB'
#!/bin/bash
printf 'SUBJECT=%s BODY=%s\n' "$1" "$2" >> "$ESC_MAIL_CALLS"
exit 0
STUB
chmod +x "$ESC_STUB_DIR/fake_mail"
export ESC_NOTIFY_CALLS ESC_MAIL_CALLS

# Plain (non-prefixed) assignments: _backup_fail_note and
# _backup_escalate_if_needed must share FAILED_DBS_STREAK/ESCALATE_DBS
# across the two calls within the same simulated "run" — a `VAR=val cmd`
# prefix does NOT persist a function's mutation past that one command
# (verified: prefixed vars revert once the command returns), so this needs
# real (if temporary, scoped to this block) global assignment, restored
# below.
_ESC_SAVE_NOTIFY="$NOTIFY"; _ESC_SAVE_LOG="$LOG"
NOTIFY="$ESC_STUB_DIR/notify"
BACKUP_FAIL_FAKE_MAIL="$ESC_STUB_DIR/fake_mail"
BACKUP_FAIL_STREAK_DIR="$ESC_STATE_DIR"
BACKUP_FAIL_ALARM_THRESHOLD=2
LOG="$ESC_LOG"

# Night 1: hq fails ONCE (streak becomes 1, below threshold=2).
: > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
FAILED_DBS_STREAK=""; ESCALATE_DBS=""
_backup_fail_note "hq"
_backup_escalate_if_needed
[ ! -s "$ESC_MAIL_CALLS" ] && ok "night 1 (isolated failure): do_mail_mayor NOT called" || bad "night 1: mail should NOT have fired on an isolated failure — got: $(cat "$ESC_MAIL_CALLS")"
[ ! -s "$ESC_NOTIFY_CALLS" ] && ok "night 1 (isolated failure): notify_escalate (forced push) NOT called" || bad "night 1: forced push should NOT have fired on an isolated failure — got: $(cat "$ESC_NOTIFY_CALLS")"

# Night 2: hq fails AGAIN — SAME BACKUP_FAIL_STREAK_DIR, i.e. the same
# on-disk state a second real nightly run would see. Streak reaches 2 →
# MUST escalate: mail naming hq's streak, and notify with a genuinely
# forced push.
: > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
FAILED_DBS_STREAK=""; ESCALATE_DBS=""
_backup_fail_note "hq"
_backup_escalate_if_needed
[ -s "$ESC_MAIL_CALLS" ] && ok "night 2 (2nd consecutive failure): do_mail_mayor WAS called" || bad "night 2: mail should have fired on the 2nd consecutive failure"
grep -qF "hq(2n)" "$ESC_MAIL_CALLS" && ok "night 2: mail content names hq with its streak length (2n)" || bad "night 2: mail content should name hq(2n) — got: $(cat "$ESC_MAIL_CALLS")"
[ -s "$ESC_NOTIFY_CALLS" ] && ok "night 2 (2nd consecutive failure): notify was invoked" || bad "night 2: notify should have fired"
grep -qF "FORCE=1" "$ESC_NOTIFY_CALLS" && ok "night 2: the notify SUBPROCESS actually saw NOTIFY_FORCE_PUSH=1 in its own environment — a genuine forced push, not just an in-process assertion" || bad "night 2: notify subprocess did not see NOTIFY_FORCE_PUSH=1 — got: $(cat "$ESC_NOTIFY_CALLS")"

# Night 3: a SUCCESS resets the streak — a later isolated failure must NOT
# re-escalate immediately (proves the reset actually wires into the
# end-to-end path, not just the unit-level streak counter tested above).
_backup_fail_streak_note_success "hq"
: > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
FAILED_DBS_STREAK=""; ESCALATE_DBS=""
_backup_fail_note "hq"
_backup_escalate_if_needed
[ ! -s "$ESC_MAIL_CALLS" ] && ok "night 3 (after a success reset the streak): a lone new failure does NOT re-escalate" || bad "night 3: streak reset did not take effect — mail fired again on a single post-reset failure"

# ── gate feedback ga-c3sqn1: the counter can't be written. THE reviewer's
# scenario — the state dir EXISTS (so `mkdir -p` trivially succeeds) but the
# write fails, on two nights running. Before the fix each night returned a
# fresh "1", the streak never reached the threshold and the escalation was
# silently defeated exactly when disk pressure was the cause. `mv` is shadowed
# (function) so the failure is deterministic even as root.
echo "── e2e: contador NÃO grava (dir existe, escrita falha) → escala como sequência DESCONHECIDA (gate ga-c3sqn1) ──"
ESC_STATE_DIR_U="$(mktemp -d)"
BACKUP_FAIL_STREAK_DIR="$ESC_STATE_DIR_U"
mv() { return 1; }
for night in 1 2; do
  : > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
  FAILED_DBS_STREAK=""; ESCALATE_DBS=""; UNKNOWN_STREAK_DBS=""
  _backup_fail_note "hq"
  _backup_escalate_if_needed
  [ -s "$ESC_MAIL_CALLS" ] && ok "unwritable counter, night $night: escalation FIRES (was: silently never)" || bad "unwritable counter, night $night: no mail — the escalation is silently defeated"
  grep -qF "DESCONHECIDA" "$ESC_MAIL_CALLS" && ok "unwritable counter, night $night: mail says the streak is DESCONHECIDA" || bad "unwritable counter, night $night: mail does not admit the streak is unknown — got: $(cat "$ESC_MAIL_CALLS")"
  grep -qF "por ${BACKUP_FAIL_ALARM_THRESHOLD}+ noites seguidas" "$ESC_MAIL_CALLS" && bad "unwritable counter, night $night: mail CLAIMS a confirmed ${BACKUP_FAIL_ALARM_THRESHOLD}+ night streak nobody counted" || ok "unwritable counter, night $night: mail does not claim a confirmed streak"
  grep -qF "FORCE=1" "$ESC_NOTIFY_CALLS" && ok "unwritable counter, night $night: forced push fired" || bad "unwritable counter, night $night: no forced push — got: $(cat "$ESC_NOTIFY_CALLS")"
done
unset -f mv

# Mixed run: hq has a CONFIRMED 2-night streak; whatsapp_automation's counter
# can't be written (mv shadow fails only for that db). One mail, both stated,
# the subject leads with the confirmed streak.
echo "── e2e: hq confirmado (2n) + whatsapp_automation desconhecido → 1 mail nomeando os dois ──"
# shellcheck disable=SC2034  # read by the sourced lib's _backup_fail_streak_note_* functions
BACKUP_FAIL_STREAK_DIR="$ESC_STATE_DIR"
_backup_fail_streak_note_success "hq"; _backup_fail_streak_note_success "whatsapp_automation"
FAILED_DBS_STREAK=""; ESCALATE_DBS=""; UNKNOWN_STREAK_DBS=""
_backup_fail_note "hq"; _backup_fail_note "whatsapp_automation"     # night A: both 1, nothing escalates
_backup_escalate_if_needed
: > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
FAILED_DBS_STREAK=""; ESCALATE_DBS=""; UNKNOWN_STREAK_DBS=""
mv() { case "$3" in */whatsapp_automation) return 1 ;; esac; command mv "$@"; }
_backup_fail_note "hq"; _backup_fail_note "whatsapp_automation"     # night B: hq→2n, wa→unknown
unset -f mv
_backup_escalate_if_needed
[ "$ESCALATE_DBS" = " hq(2n)" ] && ok "mixed: only hq is a confirmed streak (ESCALATE_DBS=' hq(2n)')" || bad "mixed: ESCALATE_DBS='$ESCALATE_DBS'"
[ "$UNKNOWN_STREAK_DBS" = " whatsapp_automation" ] && ok "mixed: whatsapp_automation is the unknown one" || bad "mixed: UNKNOWN_STREAK_DBS='$UNKNOWN_STREAK_DBS'"
case "$FAILED_DBS_STREAK" in *"hq(2n)"*"whatsapp_automation(?n)"*) ok "mixed: summary names hq(2n) and whatsapp_automation(?n)" ;; *) bad "mixed: FAILED_DBS_STREAK='$FAILED_DBS_STREAK'" ;; esac
[ "$(wc -l < "$ESC_MAIL_CALLS" | tr -d ' ')" = "1" ] && ok "mixed: exactly ONE mail for the run (not one per db)" || bad "mixed: expected 1 mail, got: $(cat "$ESC_MAIL_CALLS")"
{ grep -qF "SUBJECT=Dolt S3 backup: sem backup off-box há ${BACKUP_FAIL_ALARM_THRESHOLD}+ noites seguidas" "$ESC_MAIL_CALLS" \
  && grep -qF "hq(2n)" "$ESC_MAIL_CALLS" && grep -qF "whatsapp_automation" "$ESC_MAIL_CALLS" && grep -qF "DESCONHECIDA" "$ESC_MAIL_CALLS"; } \
  && ok "mixed: subject leads with the confirmed streak; body names hq(2n) AND the unknown whatsapp_automation" \
  || bad "mixed: mail content wrong — got: $(cat "$ESC_MAIL_CALLS")"

# The push must not claim a mail that did not go out (do_mail_mayor used to
# end in `|| true`, so "mail enviado ao Mayor" was printed unconditionally).
echo "── e2e: mail ao Mayor FALHA → o push não afirma que o mail foi enviado ──"
cat > "$ESC_STUB_DIR/fake_mail_fail" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$ESC_STUB_DIR/fake_mail_fail"
_backup_fail_streak_note_success "hq"
BACKUP_FAIL_FAKE_MAIL="$ESC_STUB_DIR/fake_mail_fail"
: > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
FAILED_DBS_STREAK=""; ESCALATE_DBS=""; UNKNOWN_STREAK_DBS=""
_backup_fail_note "hq"; FAILED_DBS_STREAK=""; ESCALATE_DBS=""
_backup_fail_note "hq"            # 2nd consecutive → confirmed escalation, but the mail send FAILS
_backup_escalate_if_needed
grep -qF "FORCE=1" "$ESC_NOTIFY_CALLS" && ok "mail failed: the forced push still fired (it is the only channel left)" || bad "mail failed: no push — got: $(cat "$ESC_NOTIFY_CALLS")"
grep -qF "mail enviado ao Mayor" "$ESC_NOTIFY_CALLS" && bad "mail failed: push STILL claims 'mail enviado ao Mayor' — a false report" || ok "mail failed: push does not claim the mail was sent"
grep -qF "FALHOU" "$ESC_NOTIFY_CALLS" && ok "mail failed: push states the mail send FAILED" || bad "mail failed: push does not surface the failed mail — got: $(cat "$ESC_NOTIFY_CALLS")"
grep -qF "do_mail_mayor FAILED" "$ESC_LOG" && ok "mail failed: logged" || bad "mail failed: not logged in $ESC_LOG"
# shellcheck disable=SC2034  # read by the sourced lib's do_mail_mayor
BACKUP_FAIL_FAKE_MAIL="$ESC_STUB_DIR/fake_mail"
: > "$ESC_NOTIFY_CALLS"; : > "$ESC_MAIL_CALLS"
FAILED_DBS_STREAK=""; ESCALATE_DBS=" hq(2n)"; UNKNOWN_STREAK_DBS=""
_backup_escalate_if_needed
grep -qF "mail enviado ao Mayor" "$ESC_NOTIFY_CALLS" && ok "mail OK: push says 'mail enviado ao Mayor' (claim matches reality)" || bad "mail OK: push lacks the sent-confirmation — got: $(cat "$ESC_NOTIFY_CALLS")"

# A failed forced push must leave a trail, and "mail AND push both failed" must
# be stated as such in the log — the alarm of last resort can't vanish silently.
echo "── e2e: push FALHA → registrado; mail+push falham → 'NOT DELIVERED on ANY channel' ──"
cat > "$ESC_STUB_DIR/notify_fail" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$ESC_STUB_DIR/notify_fail"
NOTIFY="$ESC_STUB_DIR/notify_fail"
: > "$ESC_LOG"; FAILED_DBS_STREAK=""; ESCALATE_DBS=" hq(2n)"; UNKNOWN_STREAK_DBS=""
_backup_escalate_if_needed          # mail stub (fake_mail) succeeds, push fails
grep -qF "push FAILED but the mail to the Mayor was sent" "$ESC_LOG" && ok "push failed, mail sent: logged as one-channel-delivered" || bad "push-failed/mail-sent not logged — log: $(cat "$ESC_LOG")"
grep -qF "NOT DELIVERED" "$ESC_LOG" && bad "push failed but mail sent: must NOT claim 'NOT DELIVERED' — log: $(cat "$ESC_LOG")" || ok "push failed, mail sent: does not claim total failure"
: > "$ESC_LOG"
BACKUP_FAIL_FAKE_MAIL="$ESC_STUB_DIR/fake_mail_fail"
_backup_escalate_if_needed          # mail fails AND push fails
grep -qF "NOT DELIVERED on ANY channel" "$ESC_LOG" && ok "mail AND push failed: logged as NOT DELIVERED on ANY channel" || bad "double failure not logged — log: $(cat "$ESC_LOG")"
NOTIFY="$ESC_STUB_DIR/notify"
# shellcheck disable=SC2034  # read by the sourced lib's do_mail_mayor
BACKUP_FAIL_FAKE_MAIL="$ESC_STUB_DIR/fake_mail"
unset UNKNOWN_STREAK_DBS

NOTIFY="$_ESC_SAVE_NOTIFY"; LOG="$_ESC_SAVE_LOG"
rm -rf "$ESC_STUB_DIR" "$ESC_STATE_DIR" "$ESC_STATE_DIR_U" 2>/dev/null || true
rm -f "$ESC_NOTIFY_CALLS" "$ESC_MAIL_CALLS" "$ESC_LOG" 2>/dev/null || true
unset BACKUP_FAIL_STREAK_DIR BACKUP_FAIL_ALARM_THRESHOLD BACKUP_FAIL_FAKE_MAIL FAILED_DBS_STREAK ESCALATE_DBS ESC_NOTIFY_CALLS ESC_MAIL_CALLS

# ── drift-guard: live script actually wires the escalation into every
# failure exit + the success path + the final summary, not just declares it ──
echo "── drift-guard: escalation wiring present in live script (ga-rt7ljo) ──"
callsites="$(grep -cF '_backup_fail_note "$db"' "$SCRIPT")"
[ "$callsites" -eq 6 ] \
  && ok "exactly 6 occurrences of _backup_fail_note \"\$db\" (1 per failure exit: disco x2, sync x3, s3 x1 — every FAILED_DBS append site has a matching streak-note call)" \
  || bad "expected exactly 6 occurrences of _backup_fail_note \"\$db\", got $callsites — a failure exit was added/removed without updating the streak wiring"
if grep -qF '_backup_fail_streak_note_success "$db"' "$SCRIPT"; then
  ok "success path resets the per-db streak (_backup_fail_streak_note_success called)"
else
  bad "success path does not call _backup_fail_streak_note_success — a resolved db would keep an old streak forever"
fi
SUCCESS_RESET_LINE=$(grep -nF '_backup_fail_streak_note_success "$db"' "$SCRIPT" | head -1 | cut -d: -f1)
OK_INCR_LINE2=$(grep -nF 'ok=$((ok+1))' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$SUCCESS_RESET_LINE" ] && [ -n "$OK_INCR_LINE2" ] && [ "$SUCCESS_RESET_LINE" -gt "$OK_INCR_LINE2" ]; then
  ok "streak reset happens AFTER ok=\$((ok+1)) — matches the established convention of counting the core outcome before any side-effect helper runs"
else
  bad "streak reset is not positioned after the ok counter increment"
fi
if grep -qF 'notify_fail "backup off-box: $failed/$total store(s) FALHARAM:${FAILED_DBS} — noites seguidas sem backup OK:${FAILED_DBS_STREAK}"' "$SCRIPT"; then
  ok "final summary line names FAILED_DBS_STREAK (the bead's own requirement: which store, how many nights)"
else
  bad "final summary line does not include the per-store nights-without-OK-backup detail"
fi
if grep -qF '_backup_escalate_if_needed' "$SCRIPT"; then
  ESCALATE_CALL_LINE=$(grep -nF '_backup_escalate_if_needed' "$SCRIPT" | tail -1 | cut -d: -f1)
  FAILED_GT0_LINE=$(grep -nF 'if [ "$failed" -gt 0 ]; then' "$SCRIPT" | head -1 | cut -d: -f1)
  if [ -n "$ESCALATE_CALL_LINE" ] && [ -n "$FAILED_GT0_LINE" ] && [ "$ESCALATE_CALL_LINE" -gt "$FAILED_GT0_LINE" ]; then
    ok "_backup_escalate_if_needed is called inside the failed>0 summary block — wiring is live, not dead code"
  else
    bad "_backup_escalate_if_needed call is not positioned inside the failed>0 block as expected"
  fi
else
  bad "_backup_escalate_if_needed is defined but never called in the live flow"
fi
if grep -qF 'total=0; ok=0; failed=0; FAILED_DBS=""; FAILED_DBS_STREAK=""; ESCALATE_DBS=""; UNKNOWN_STREAK_DBS=""' "$SCRIPT"; then
  ok "FAILED_DBS_STREAK/ESCALATE_DBS/UNKNOWN_STREAK_DBS are initialized once per run, alongside FAILED_DBS (set -u safe)"
else
  bad "FAILED_DBS_STREAK/ESCALATE_DBS/UNKNOWN_STREAK_DBS initialization missing or changed shape — set -u would abort the run on first reference"
fi
if grep -qF 'gc mail send mayor' "$SCRIPT"; then
  ok "do_mail_mayor's real (non-stubbed) path actually calls gc mail send mayor"
else
  bad "do_mail_mayor does not wire to gc mail send mayor — escalation would never reach a real Mayor mailbox"
fi
# ── ga-btnq6h: a disk refusal must still mirror the EXISTING staging to S3 ────────
# Measured 2026-09-25: hq's S3 copy was unrestorable for four days because the nightly
# refused hq for disk (22-25/09) and `continue` also skipped the zero-disk mirror step.
echo "── _mirror_staging_after_disk_refusal (ga-btnq6h) ──"
type _mirror_staging_after_disk_refusal >/dev/null 2>&1 \
  && ok "_mirror_staging_after_disk_refusal defined by lib-mode source" \
  || bad "_mirror_staging_after_disk_refusal NOT defined"

MR_DIR="$(mktemp -d)"; MR_LOG="$(mktemp)"; MR_CALLS="$(mktemp)"
_s3proof_repair_then_prove() { echo "prove $1 $2" >> "$MR_CALLS"; return "${MR_STUB_RC:-0}"; }

: > "$MR_CALLS"
LOG="$MR_LOG" _mirror_staging_after_disk_refusal hq "$MR_DIR/does-not-exist"; rc=$?
[ "$rc" -eq 0 ] && ok "no staging dir → returns 0 (nothing to mirror)" || bad "no staging dir returned $rc"
[ ! -s "$MR_CALLS" ] && ok "…and the proof/mirror is NOT attempted for a missing dir" || bad "proof attempted for a missing dir"

mkdir -p "$MR_DIR/hq"; : > "$MR_CALLS"
MR_STUB_RC=0 LOG="$MR_LOG" _mirror_staging_after_disk_refusal hq "$MR_DIR/hq"; rc=$?
[ "$rc" -eq 0 ] && ok "proof passes → returns 0" || bad "proof passing returned $rc"
[ "$(cat "$MR_CALLS")" = "prove $MR_DIR/hq hq" ] && ok "…by asking the shared lib to repair-then-prove exactly this staging dir and db" || bad "unexpected lib call: '$(cat "$MR_CALLS")'"

: > "$MR_LOG"
MR_STUB_RC=1 LOG="$MR_LOG" _mirror_staging_after_disk_refusal hq "$MR_DIR/hq"; rc=$?
[ "$rc" -eq 1 ] && ok "proof fails → returns 1 (the alert can say S3 is NOT sound)" || bad "proof failing returned $rc"
grep -q 'NOT proven' "$MR_LOG" && ok "…and the log says S3 is NOT proven" || bad "failure not logged: $(cat "$MR_LOG")"
unset -f _s3proof_repair_then_prove
rm -rf "$MR_DIR" "$MR_LOG" "$MR_CALLS"

echo "── drift-guard: the refusal branch is wired to the mirror (ga-btnq6h) ──"
# the FIRST (pre-write) preflight in the per-db loop — the block between the step-1 marker
# and the native sync call.
BLOCK="$(awk '/# 1\) native consistent backup/{f=1} f{print} /SYNC_OUT" 2>&1; then/{if(f) exit}' "$SCRIPT")"
printf '%s' "$BLOCK" | grep -qF '_mirror_staging_after_disk_refusal "$db" "$dest"' \
  && ok "step-1 refusal branch calls _mirror_staging_after_disk_refusal \"\$db\" \"\$dest\"" \
  || bad "step-1 refusal branch does NOT call the mirror — S3 repair is skipped on a disk refusal again"
printf '%s' "$BLOCK" | grep -qF 'failed=$((failed+1))' \
  && ok "…and still counts the db as failed (its own backup did not run today)" \
  || bad "refusal branch no longer counts the db as failed"
printf '%s' "$BLOCK" | grep -qF '(disco+s3)' && printf '%s' "$BLOCK" | grep -qF '(disco)' \
  && ok "…and the alert distinguishes disco (S3 sound) from disco+s3 (S3 NOT proven)" \
  || bad "alert text no longer distinguishes S3 state"
M_LN="$(printf '%s\n' "$BLOCK" | grep -nF '_mirror_staging_after_disk_refusal "$db" "$dest"' | head -1 | cut -d: -f1)"
C_LN="$(printf '%s\n' "$BLOCK" | grep -nE '^ +continue$' | head -1 | cut -d: -f1)"
[ -n "$M_LN" ] && [ -n "$C_LN" ] && [ "$M_LN" -lt "$C_LN" ] \
  && ok "…and the mirror runs BEFORE the branch's continue" || bad "mirror not before continue (mirror@${M_LN:-?} continue@${C_LN:-?})"
N_CALLS="$(grep -cF '_mirror_staging_after_disk_refusal "$db" "$dest"' "$SCRIPT")"
[ "$N_CALLS" -eq 1 ] \
  && ok "the mirror has exactly ONE call site — not wired into the post-sync-attempt preflights (a half-written staging must never be mirrored)" \
  || bad "expected exactly 1 call site of the mirror, found $N_CALLS"
FBODY="$(awk '/^_mirror_staging_after_disk_refusal\(\)/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")"
printf '%s' "$FBODY" | grep -qF -- '--delete' \
  && bad "the refusal mirror uses --delete (must be additive on a night with no fresh sync)" \
  || ok "the refusal mirror body never uses --delete"
printf '%s' "$FBODY" | grep -qF '_s3proof_repair_then_prove' \
  && ok "the refusal mirror goes through the shared proof lib (closure-guarded, manifest-last)" \
  || bad "the refusal mirror bypasses the shared proof lib"
grep -qF 'dolt-backup-s3-proof.sh' "$SCRIPT" && ok "the proof lib is sourced by the script" || bad "proof lib not sourced"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
