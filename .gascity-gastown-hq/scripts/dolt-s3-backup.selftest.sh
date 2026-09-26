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

# No staging to mirror is NOT "S3 is fine": with the staging gone (released for the dolt_gc
# window) the alert must still report S3's real state, so S3's own closure is read (read-only).
MR_CLOSURE="$(mktemp)"
_s3proof_s3_closure_ok() { echo "closure $1" >> "$MR_CLOSURE"; return "${MR_S3_RC:-0}"; }

: > "$MR_CALLS"; : > "$MR_CLOSURE"; : > "$MR_LOG"
MR_S3_RC=0 LOG="$MR_LOG" _mirror_staging_after_disk_refusal hq "$MR_DIR/does-not-exist"; rc=$?
[ "$rc" -eq 0 ] && ok "no staging + S3 closure proven → returns 0 (S3 restorable)" || bad "no staging + closure OK returned $rc"
[ "$(cat "$MR_CLOSURE")" = "closure hq" ] && ok "…by reading S3's closure for exactly this db (not assuming)" || bad "closure not checked for the missing-staging case: '$(cat "$MR_CLOSURE")'"
[ ! -s "$MR_CALLS" ] && ok "…and the upload/repair proof is NOT attempted for a missing dir (nothing to mirror)" || bad "repair attempted for a missing dir"

: > "$MR_CALLS"; : > "$MR_CLOSURE"; : > "$MR_LOG"
MR_S3_RC=1 LOG="$MR_LOG" _mirror_staging_after_disk_refusal hq "$MR_DIR/does-not-exist"; rc=$?
[ "$rc" -eq 1 ] && ok "no staging + S3 closure NOT proven → returns 1 (alert says disco+s3, never a blind 'disco')" || bad "no staging + closure failing returned $rc (unverified S3 reported as fine)"
grep -q 'NOT proven restorable' "$MR_LOG" && ok "…and the log says S3 is NOT proven restorable" || bad "missing-staging failure not logged: $(cat "$MR_LOG")"
[ ! -s "$MR_CALLS" ] && ok "…without attempting an upload from a dir that does not exist" || bad "repair attempted for a missing dir"

# the closure probe must NOT be consulted when a staging exists — the strong proof covers it
mkdir -p "$MR_DIR/hq"; : > "$MR_CLOSURE"; : > "$MR_CALLS"
MR_S3_RC=1 MR_STUB_RC=0 LOG="$MR_LOG" _mirror_staging_after_disk_refusal hq "$MR_DIR/hq" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$MR_CLOSURE" ] && ok "with a staging present the decision comes from the repair-then-prove lib alone" || bad "staging present: rc=$rc closure_calls='$(cat "$MR_CLOSURE")'"
rmdir "$MR_DIR/hq"
unset -f _s3proof_s3_closure_ok; rm -f "$MR_CLOSURE"

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
# ga-rt7ljo x ga-btnq6h: the refusal branch must ALSO record tonight's failure streak, and BEFORE the
# slow network mirror — so a mirror that stalls or is killed can never lose the night's failure count.
N_LN="$(printf '%s\n' "$BLOCK" | grep -nF '_backup_fail_note "$db"' | head -1 | cut -d: -f1)"
[ -n "$N_LN" ] && [ -n "$M_LN" ] && [ "$N_LN" -lt "$M_LN" ] \
  && ok "…and the failure streak is noted (ga-rt7ljo) BEFORE the mirror runs" \
  || bad "refusal branch: streak note missing or after the mirror (note@${N_LN:-?} mirror@${M_LN:-?})"
# The UNGUARDED mirror is only safe where no sync attempt ran before the refusal. Since ga-ua269q
# it has exactly TWO callers: the step-1 refusal above, and _mirror_staging_after_aborted_sync
# (which gates it on the manifest fingerprint). Any third caller — e.g. pasted into a post-attempt
# preflight — would mirror a possibly half-applied staging with no gate at all.
N_CALLS="$(grep -cF '_mirror_staging_after_disk_refusal "$db" "$dest"' "$SCRIPT")"
[ "$N_CALLS" -eq 2 ] \
  && ok "the unguarded mirror has exactly TWO call sites (step-1 refusal + the fingerprint-gated helper) — none in a post-attempt preflight" \
  || bad "expected exactly 2 call sites of the unguarded mirror (step-1 refusal + _mirror_staging_after_aborted_sync), found $N_CALLS"
H_CALL="$(awk '/^_mirror_staging_after_aborted_sync\(\)/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT" | grep -cF '_mirror_staging_after_disk_refusal "$db" "$dest"')"
[ "$H_CALL" -eq 1 ] && ok "…and one of the two is inside _mirror_staging_after_aborted_sync, after its fingerprint checks" || bad "the gated helper does not call the mirror exactly once (found $H_CALL)"
FBODY="$(awk '/^_mirror_staging_after_disk_refusal\(\)/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")"
printf '%s' "$FBODY" | grep -qF -- '--delete' \
  && bad "the refusal mirror uses --delete (must be additive on a night with no fresh sync)" \
  || ok "the refusal mirror body never uses --delete"
printf '%s' "$FBODY" | grep -qF '_s3proof_repair_then_prove' \
  && ok "the refusal mirror goes through the shared proof lib (closure-guarded, manifest-last)" \
  || bad "the refusal mirror bypasses the shared proof lib"
grep -qF 'dolt-backup-s3-proof.sh' "$SCRIPT" && ok "the proof lib is sourced by the script" || bad "proof lib not sourced"

# ── ga-ua269q: _staging_manifest_fp + _mirror_staging_after_aborted_sync (unit level) ──────
# The end-to-end block at the bottom proves the whole chain; these pin each decision of the
# gate on its own, including the doubtful inputs (no baseline, unreadable, staging vanished).
echo "── _staging_manifest_fp + _mirror_staging_after_aborted_sync (ga-ua269q) ──"
type _staging_manifest_fp >/dev/null 2>&1 && type _mirror_staging_after_aborted_sync >/dev/null 2>&1 \
  && ok "both helpers defined by lib-mode source" \
  || bad "ga-ua269q helpers NOT defined"

FP_DIR="$(mktemp -d)"
mkdir -p "$FP_DIR/a"; printf 'manifest-v1' > "$FP_DIR/a/manifest"
fp1="$(_staging_manifest_fp "$FP_DIR/a")"
case "$fp1" in [0-9]*-[0-9]*) ok "a readable manifest fingerprints as <crc>-<size> ($fp1)" ;; *) bad "unexpected fingerprint '$fp1'" ;; esac
[ "$(_staging_manifest_fp "$FP_DIR/a")" = "$fp1" ] && ok "…the same bytes give the same fingerprint" || bad "fingerprint is not stable"
printf 'manifest-v2' > "$FP_DIR/a/manifest"          # same length, different bytes
[ "$(_staging_manifest_fp "$FP_DIR/a")" != "$fp1" ] && ok "…different bytes (even at the same size) give a different one" || bad "a changed manifest kept its fingerprint"
[ "$(_staging_manifest_fp "$FP_DIR/none")" = absent ] && ok "no manifest / no dir → 'absent' (never a fingerprint)" || bad "a missing manifest was not reported absent"
mkdir -p "$FP_DIR/d/manifest"                        # exists but cannot be read as a file
[ "$(_staging_manifest_fp "$FP_DIR/d" 2>/dev/null)" = unreadable ] \
  && ok "a manifest that cannot be read → 'unreadable' (a third state: not absent, not a fingerprint)" \
  || bad "unreadable manifest mis-reported: '$(_staging_manifest_fp "$FP_DIR/d" 2>/dev/null)'"

GA_CALLS="$(mktemp)"; GA_LOG="$(mktemp)"
_GA_REAL_MIRROR="$(declare -f _mirror_staging_after_disk_refusal)"
_mirror_staging_after_disk_refusal() { echo "mirror $1 $2" >> "$GA_CALLS"; return "${GA_MIRROR_RC:-0}"; }
_s3proof_s3_closure_ok() { echo "closure $1" >> "$GA_CALLS"; return "${GA_S3_RC:-0}"; }
printf 'manifest-v1' > "$FP_DIR/a/manifest"; PRE="$(_staging_manifest_fp "$FP_DIR/a")"

# unchanged manifest → the mirror decides, and only the mirror (S3 is not read separately)
for mrc in 0 1; do
  : > "$GA_CALLS"; : > "$GA_LOG"
  GA_MIRROR_RC=$mrc LOG="$GA_LOG" _mirror_staging_after_aborted_sync hq "$FP_DIR/a" "$PRE"; rc=$?
  [ "$rc" -eq "$mrc" ] && [ "$(cat "$GA_CALLS")" = "mirror hq $FP_DIR/a" ] \
    && ok "manifest unchanged → hands the staging to the mirror and returns ITS verdict ($mrc), nothing else consulted" \
    || bad "unchanged manifest, mirror rc=$mrc: got rc=$rc calls='$(cat "$GA_CALLS")'"
done
grep -q "manifest unchanged by the attempt ($PRE)" "$GA_LOG" && ok "…and the log says why it went ahead" || bad "no reason logged for going ahead: $(cat "$GA_LOG")"

# changed manifest → INERT: no mirror, S3's own state is read instead and reported honestly
printf 'manifest-v2' > "$FP_DIR/a/manifest"
for src in 0 1; do
  : > "$GA_CALLS"; : > "$GA_LOG"
  GA_S3_RC=$src LOG="$GA_LOG" _mirror_staging_after_aborted_sync hq "$FP_DIR/a" "$PRE"; rc=$?
  [ "$rc" -eq "$src" ] && [ "$(cat "$GA_CALLS")" = "closure hq" ] \
    && ok "manifest CHANGED → not mirrored; S3's own closure is read and returned ($src)" \
    || bad "changed manifest, S3 rc=$src: got rc=$rc calls='$(cat "$GA_CALLS")'"
done
grep -q "staging manifest CHANGED during the attempt (before=$PRE after=" "$GA_LOG" && grep -q 'NOT mirroring' "$GA_LOG" \
  && ok "…and the log names the before/after fingerprints and says it did NOT mirror" \
  || bad "changed-manifest reason missing from the log: $(cat "$GA_LOG")"

# no usable baseline → INERT, whatever the staging looks like now ('absent' twice must NOT read as 'unchanged')
rm -f "$FP_DIR/a/manifest"
for nofp in "" absent unreadable; do
  : > "$GA_CALLS"; : > "$GA_LOG"
  GA_S3_RC=1 LOG="$GA_LOG" _mirror_staging_after_aborted_sync hq "$FP_DIR/a" "$nofp"; rc=$?
  [ "$rc" -eq 1 ] && [ "$(cat "$GA_CALLS")" = "closure hq" ] && grep -q 'no usable fingerprint' "$GA_LOG" \
    && ok "baseline '${nofp:-<empty>}' → not mirrored, says so, S3's own state is what gets reported" \
    || bad "baseline '${nofp:-<empty>}': rc=$rc calls='$(cat "$GA_CALLS")' log='$(cat "$GA_LOG")'"
done
# a real baseline but the manifest is GONE now (wiped / released by another job) → changed, inert
: > "$GA_CALLS"; : > "$GA_LOG"
GA_S3_RC=0 LOG="$GA_LOG" _mirror_staging_after_aborted_sync hq "$FP_DIR/a" "$PRE"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$GA_CALLS")" = "closure hq" ] && grep -q 'after=absent' "$GA_LOG" \
  && ok "a real baseline but the manifest is gone now → treated as CHANGED (after=absent), inert" \
  || bad "vanished manifest was not treated as a change: rc=$rc calls='$(cat "$GA_CALLS")'"

unset -f _mirror_staging_after_disk_refusal _s3proof_s3_closure_ok
eval "$_GA_REAL_MIRROR"
rm -rf "$FP_DIR" "$GA_CALLS" "$GA_LOG"

# drift-guards: the wiring in the main loop (lib mode never runs it)
echo "── drift-guard: the aborted-sync mirror is wired where the measured chain lands (ga-ua269q) ──"
LOOP_LN="$(grep -n '^for db in \$DBS; do' "$SCRIPT" | head -1 | cut -d: -f1)"
FIRST_PF_LN="$(awk -v s="$LOOP_LN" 'NR>s && /if ! _sync_disk_preflight "\$db"; then/{print NR; exit}' "$SCRIPT")"
PREFP_LN="$(grep -nF 'pre_fp="$(_staging_manifest_fp "$dest")"' "$SCRIPT" | head -1 | cut -d: -f1)"
[ -n "$LOOP_LN" ] && [ -n "$PREFP_LN" ] && [ -n "$FIRST_PF_LN" ] && [ "$PREFP_LN" -gt "$LOOP_LN" ] && [ "$PREFP_LN" -lt "$FIRST_PF_LN" ] \
  && ok "the baseline fingerprint is taken inside the per-db loop, BEFORE the first preflight/sync attempt" \
  || bad "baseline fingerprint not taken before the first attempt (loop@${LOOP_LN:-?} pre_fp@${PREFP_LN:-?} first-preflight@${FIRST_PF_LN:-?})"
FB_BLOCK="$(awk '/connection-timeout retries exhausted — falling back/{f=1} f{print} /_offline_backup_sync "\$db" "\$dest"; then/{if(f) exit}' "$SCRIPT")"
printf '%s' "$FB_BLOCK" | grep -qF '_mirror_staging_after_aborted_sync "$db" "$dest" "$pre_fp"' \
  && ok "the offline-fallback refusal (where the hq chain ends) calls the fingerprint-gated mirror with the baseline" \
  || bad "the offline-fallback refusal does not call _mirror_staging_after_aborted_sync with \$pre_fp — S3 stays unrepaired on this path"
printf '%s' "$FB_BLOCK" | grep -qF '_mirror_staging_after_disk_refusal' \
  && bad "the post-attempt refusal calls the UNGUARDED mirror directly — the fingerprint gate is bypassed" \
  || ok "…and it never calls the unguarded mirror directly"
FA_LN="$(printf '%s\n' "$FB_BLOCK" | grep -nF 'failed=$((failed+1))' | head -1 | cut -d: -f1)"
FN_LN="$(printf '%s\n' "$FB_BLOCK" | grep -nF '_backup_fail_note "$db"' | head -1 | cut -d: -f1)"
FM_LN="$(printf '%s\n' "$FB_BLOCK" | grep -nF '_mirror_staging_after_aborted_sync' | head -1 | cut -d: -f1)"
[ -n "$FA_LN" ] && [ -n "$FN_LN" ] && [ -n "$FM_LN" ] && [ "$FA_LN" -lt "$FN_LN" ] && [ "$FN_LN" -lt "$FM_LN" ] \
  && ok "…it still counts the db failed and notes the streak (ga-rt7ljo) BEFORE the slow mirror" \
  || bad "fallback refusal order wrong (failed@${FA_LN:-?} streak-note@${FN_LN:-?} mirror@${FM_LN:-?})"
printf '%s' "$FB_BLOCK" | grep -qF '(disco+s3)' && printf '%s' "$FB_BLOCK" | grep -qF '(disco)' \
  && ok "…and its alert distinguishes disco (S3 sound) from disco+s3 (S3 NOT proven)" \
  || bad "fallback refusal no longer distinguishes S3 state in the alert"
SM_BODY="$(awk '/^_sync_with_stale_manifest_recovery\(\)/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")"
printf '%s' "$SM_BODY" | grep -qF '_mirror_staging_after' \
  && bad "_sync_with_stale_manifest_recovery mirrors — but it wipes the staging first, so there is nothing valid to mirror" \
  || ok "the stale-manifest recovery (which wipes the staging) stays out of the mirror, by design"
GA_BODY="$(awk '/^_mirror_staging_after_aborted_sync\(\)/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")"
printf '%s' "$GA_BODY" | grep -qF -- '--delete' && bad "the gated mirror mentions --delete (must stay additive)" || ok "the gated mirror never uses --delete"
printf '%s' "$GA_BODY" | grep -qF '_staging_manifest_fp "$dest"' && ok "…and it re-reads the manifest fingerprint itself (does not trust the caller's word)" || bad "the gated mirror does not re-read the staging manifest"

echo "── _build_run_fingerprint() — a db that FAILED stays in _meta/latest.json (ga-gjfe78) ──"
# The nightly fingerprint used to be rebuilt from scratch from the dbs that
# SUCCEEDED, so a failing db (hq, every night since 2026-09-21) simply vanished:
# no entry, no failed mark, no last good date — indistinguishable from a db that
# never existed. Rules under test: every discovered db keeps an entry; a failed
# one is marked failed and keeps the date/values of its last good backup when
# they can be found; and a failed entry carries NO key an old reader would take
# as proof. last_ok null means NOT KNOWN — never "there was none": a db absent
# from the previous file may simply have been dropped by the old writer.
type _build_run_fingerprint >/dev/null 2>&1 \
  && ok "_build_run_fingerprint defined by lib-mode source" \
  || bad "_build_run_fingerprint NOT defined — the fingerprint is still built inline and drops failed dbs"

FPD="$(mktemp -d)"
TAB="$(printf '\t')"
_raw() { : > "$FPD/raw"; for row in "$@"; do printf '%s\n' "$row" | tr '|' "$TAB" >> "$FPD/raw"; done; }
# _build <discovered> <failed_text> <prev_file> [ok failed total]
_build() {
  _build_run_fingerprint "$FPD/raw" "2026-09-25T07:04:02Z" 52756 "${4:-1}" "${5:-0}" "${6:-1}" "$1" "$2" "$3" > "$FPD/out.json" 2> "$FPD/err"
}
# _jt <python expr over d = the built document> — exit 0 iff truthy.
# eval() is deliberate and safe here: every expression passed in is a string
# literal written in THIS test file, and the only data it ever sees is the JSON
# this test just produced in its own mktemp dir. No external or untrusted input
# reaches it, and it is never used outside this hermetic selftest.
_jt() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$FPD/out.json" "$1" 2>/dev/null; }

# the writer exactly as it was before ga-gjfe78, kept here as the compatibility oracle
cat > "$FPD/legacy.py" <<'PY'
import json, sys
raw, run_utc, port, ok, failed, total = sys.argv[1:7]
dbs = {}
try:
    with open(raw) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 4:
                dbs[p[0]] = {"issues": int(p[1]), "head": p[2], "backup_size": p[3]}
except FileNotFoundError:
    pass
json.dump({"run_utc": run_utc, "port": int(port), "bucket": "urblink-dolt-backups",
           "ok": int(ok), "failed": int(failed), "total": int(total),
           "databases": dbs}, sys.stdout, indent=2)
PY

# 1) nothing failed → byte-identical to what the old writer produced
_raw "beads|10|bh1|1M" "gastown|20|gh1|2M"
_build "beads gastown" "" "" 2 0 2
python3 "$FPD/legacy.py" "$FPD/raw" "2026-09-25T07:04:02Z" 52756 2 0 2 > "$FPD/legacy.json"
cmp -s "$FPD/out.json" "$FPD/legacy.json" \
  && ok "no failures → output is BYTE-IDENTICAL to the pre-ga-gjfe78 writer (existing readers see nothing new on a good night)" \
  || bad "no failures → output differs from the old writer: $(diff "$FPD/legacy.json" "$FPD/out.json" | head -5 | tr '\n' ' ')"

# 2) hq failed; previous fingerprint is a legacy one (no per-db run_utc) where hq was ok
cat > "$FPD/prev-legacy.json" <<'JSON'
{"run_utc": "2026-09-20T07:00:00Z", "port": 52756, "bucket": "urblink-dolt-backups", "ok": 2, "failed": 0, "total": 2,
 "databases": {"beads": {"issues": 1, "head": "old-b", "backup_size": "1M"}, "hq": {"issues": 7242, "head": "hq-old", "backup_size": "13G"}}}
JSON
_raw "beads|10|bh1|1M"
_build "beads hq" " hq(sync)" "$FPD/prev-legacy.json" 1 1 2
_jt 'sorted(d["databases"]) == ["beads", "hq"]' && ok "failed db stays LISTED in databases (the bug: it vanished)" || bad "failed db is not listed in databases"
_jt 'd["databases"]["hq"]["status"] == "failed"' && ok "failed db is marked status=failed" || bad "failed db not marked failed"
_jt 'd["databases"]["hq"]["reason"] == "sync"' && ok "reason taken from the run's own failure token (sync)" || bad "reason not carried"
_jt 'd["databases"]["hq"]["last_ok_run_utc"] == "2026-09-20T07:00:00Z"' && ok "last_ok_run_utc = the shared run time of the previous fingerprint where hq was last ok" || bad "last_ok_run_utc wrong"
_jt 'd["databases"]["hq"]["last_ok"] == {"issues": 7242, "head": "hq-old", "backup_size": "13G"}' && ok "last good issues/head/backup_size preserved under last_ok" || bad "last_ok values not preserved"
_jt 'not ({"run_utc", "issues", "head", "backup_size"} & set(d["databases"]["hq"]))' && ok "failed entry carries NO run_utc/issues/head/backup_size at its top level (nothing an old reader takes as proof)" || bad "failed entry still carries a proof-looking key"
_jt 'set(d["databases"]["hq"]) == {"status", "reason", "last_ok_run_utc", "last_ok"}' && ok "failed entry has exactly status/reason/last_ok_run_utc/last_ok (no extra claim such as a known/none flag)" || bad "failed entry key set drifted: $(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["databases"]["hq"]))' "$FPD/out.json" 2>&1)"
_jt 'd["databases"]["beads"] == {"issues": 10, "head": "bh1", "backup_size": "1M"}' && ok "the ok sibling is untouched (no status key, same shape as before)" || bad "ok sibling changed shape"
_jt 'd["ok"] == 1 and d["failed"] == 1 and d["total"] == 2 and d["run_utc"] == "2026-09-25T07:04:02Z" and d["port"] == 52756' && ok "top-level run_utc/port/ok/failed/total pass through unchanged" || bad "top-level fields changed"

# 3) previous entry had its OWN run_utc (an ad hoc reseed refreshed it) → that wins over the shared one
cat > "$FPD/prev-perdb.json" <<'JSON'
{"run_utc": "2026-09-20T07:00:00Z", "databases": {"hq": {"issues": 5, "backup_size": "9G", "run_utc": "2026-09-22T15:30:00Z"}}}
JSON
_raw "beads|10|bh1|1M"
_build "beads hq" " hq(s3)" "$FPD/prev-perdb.json"
_jt 'd["databases"]["hq"]["last_ok_run_utc"] == "2026-09-22T15:30:00Z"' && ok "previous per-db run_utc (ad hoc reseed) wins over the shared top-level time" || bad "per-db run_utc precedence lost"
_jt 'd["databases"]["hq"]["last_ok"]["backup_size"] == "9G" and d["databases"]["hq"]["reason"] == "s3"' && ok "last_ok backup_size + reason=s3 carried" || bad "last_ok/reason wrong for the per-db case"

# 4) SECOND consecutive failed night — the last-ok date must be carried forward, not reset to last night
python3 - "$FPD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/out.json"))
json.dump(d, open(sys.argv[1] + "/prev-failed.json", "w"))
PY
_raw "beads|11|bh2|1M"
_build "beads hq" " hq(sync)" "$FPD/prev-failed.json"
_jt 'd["databases"]["hq"]["last_ok_run_utc"] == "2026-09-22T15:30:00Z" and d["databases"]["hq"]["last_ok"]["backup_size"] == "9G"' && ok "night 2 of failing: the ORIGINAL last-ok date/values are carried forward (not reset to the previous failed night)" || bad "second failed night lost the real last-ok date"

# 5) previous fingerprint UNREADABLE → last ok is NOT KNOWN (null), never a made-up value
_raw "beads|10|bh1|1M"
: > "$FPD/prev-empty.json"
echo '{ not json' > "$FPD/prev-garbage.json"
echo '["a list"]' > "$FPD/prev-list.json"
echo '{"run_utc": "2026-09-20T07:00:00Z", "databases": "x"}' > "$FPD/prev-baddbs.json"
for variant in "" "$FPD/does-not-exist.json" "$FPD/prev-empty.json" "$FPD/prev-garbage.json" "$FPD/prev-list.json" "$FPD/prev-baddbs.json"; do
  _build "beads hq" " hq(sync)" "$variant"
  _jt 'd["databases"]["hq"]["last_ok_run_utc"] is None and d["databases"]["hq"]["last_ok"] is None' \
    && ok "previous fingerprint unusable (${variant:+${variant##*/}}${variant:-<no file given>}) → last_ok null (not known), never a fabricated value" \
    || bad "unusable previous fingerprint (${variant:-<none>}) must give last_ok null"
done

# 6) previous fingerprint readable but has no entry for this db. This is EXACTLY
#    what the old writer left behind for hq, so absence proves nothing about
#    whether hq ever had a good backup — the honest answer is null (not known).
#    A "none"/"never" claim here would be false on the first night after deploy.
cat > "$FPD/prev-nohq.json" <<'JSON'
{"run_utc": "2026-09-20T07:00:00Z", "databases": {"beads": {"issues": 1, "head": "x", "backup_size": "1M"}}}
JSON
_build "beads hq" " hq(sync)" "$FPD/prev-nohq.json"
_jt 'd["databases"]["hq"]["last_ok_run_utc"] is None and d["databases"]["hq"]["last_ok"] is None and d["databases"]["hq"]["status"] == "failed"' \
  && ok "previous readable but WITHOUT the db (what the old writer left for hq) → failed entry with last_ok null = not known, no claim that none ever existed" \
  || bad "db absent from a readable previous file must give last_ok null"

# 7) previous entry present but malformed / unrecognized status → cannot know
cat > "$FPD/prev-odd.json" <<'JSON'
{"run_utc": "2026-09-20T07:00:00Z", "databases": {"hq": "oops", "dc": {"status": "partial", "backup_size": "1M"}}}
JSON
_build "beads hq dc" " hq(sync) dc(sync)" "$FPD/prev-odd.json"
_jt 'd["databases"]["hq"]["last_ok"] is None and d["databases"]["dc"]["last_ok"] is None and d["databases"]["dc"]["last_ok_run_utc"] is None' \
  && ok "previous entry not an object / unrecognized status → last_ok null (does not guess)" \
  || bad "odd previous entries must give last_ok null"

# 8) the discovered list is the source of truth for WHO failed; the text only supplies the reason
_raw "beads|10|bh1|1M"
_build "beads hq" "" "$FPD/prev-legacy.json"
_jt 'd["databases"]["hq"]["status"] == "failed" and d["databases"]["hq"]["reason"] == "unknown"' \
  && ok "db discovered but neither succeeded nor named in the failure text → still listed as failed, reason=unknown" \
  || bad "a db missing from both the success rows and the failure text must not vanish"
_build "beads hq" " hq(sync" "$FPD/prev-legacy.json"
_jt 'd["databases"]["hq"]["status"] == "failed" and d["databases"]["hq"]["reason"] == "unknown"' \
  && ok "malformed failure token → reason=unknown, no crash" || bad "malformed failure token broke the writer"
_build "beads" " hq(disco)" "$FPD/prev-legacy.json"
_jt 'd["databases"]["hq"]["status"] == "failed" and d["databases"]["hq"]["reason"] == "disco"' \
  && ok "db named only in the failure text (discovered list empty of it) → still listed, reason=disco" \
  || bad "a db named in the failure text must be listed even if the discovered list lacks it"
# disco+s3 is the token the main loop writes when the disk refused today's sync AND
# the S3 mirror is not proven — the one failure where S3 itself is in doubt. The
# alert distinguishes it from a plain disco; the published reason must too, not
# collapse it to "unknown" because of the '+'.
_build "beads hq" " hq(disco+s3)" "$FPD/prev-legacy.json"
_jt 'd["databases"]["hq"]["status"] == "failed" and d["databases"]["hq"]["reason"] == "disco+s3"' \
  && ok "hq(disco+s3) → reason=disco+s3 (S3 NOT proven stays distinguishable from plain disco)" \
  || bad "the disco+s3 failure token was degraded (expected reason=disco+s3; the '+' must be accepted in a reason token)"

# 9) writer → consumer contract, through the REAL parser (subshell: both scripts define AWS/LOG/…)
RECLAIM_LIB="$HERE/dolt-backup-residue-reclaim.sh"
_consumer_sees() {
  ( export DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1; . "$RECLAIM_LIB"; : > "$FPD/parsed"
    _parse_fingerprint_to_file "$FPD/out.json" "$1" "$FPD/parsed"; cat "$FPD/parsed" )
}
_raw "beads|10|bh1|1M"
_build "beads hq" " hq(sync)" "$FPD/prev-legacy.json" 1 1 2
[ -n "$(_consumer_sees beads)" ] && ok "contract: the real residue-reclaim parser still reads the ok entry as proof" || bad "contract: ok entry no longer parses"
[ -z "$(_consumer_sees hq)" ] && ok "contract: the real residue-reclaim parser reads the failed entry as NO proof" || bad "contract: failed entry parsed as proof: '$(_consumer_sees hq)'"
rm -rf "${FPD:?}" 2>/dev/null || true

echo ""
echo "── drift-guard: the live flow builds the fingerprint through the tested function (ga-gjfe78) ──"
if grep -qF '_build_run_fingerprint "$RAW" "$RUN_UTC" "$PORT" "$ok" "$failed" "$total" "$DBS" "$FAILED_DBS"' "$SCRIPT"; then
  ok "live flow calls _build_run_fingerprint with the discovered list and the failure text"
else
  bad "live flow does not pass \$DBS and \$FAILED_DBS to _build_run_fingerprint — failed dbs would vanish again"
fi
if grep -B1 -F 'PREV_META="$(mktemp)"' "$SCRIPT" | grep -qF 'if [ "$failed" -gt 0 ]; then'; then
  ok "previous fingerprint is fetched ONLY when something failed (a clean night never reads it) so last_ok can be preserved"
else
  bad "previous-fingerprint fetch is missing or no longer gated on failed>0"
fi
if grep -qF 'NOT publishing' "$SCRIPT"; then
  ok "a fingerprint that could not be built/validated is NOT published over the last good one"
else
  bad "no guard against publishing an empty/invalid fingerprint over the last good one"
fi

# ── _publish_run_fingerprint() (ga-dgnpyj) ─────────────────────────────────────
# The two uploads at the end of the run used to end in `|| true`. _meta/latest.json
# is the ONLY "S3 is fresh" proof its consumers have (dolt-backup-residue-reclaim.sh,
# dolt-backup-reseed.sh); when its upload failed, the previous night's file stayed,
# its older run_utc kept those consumers inert, and residue-reclaim files that under
# "SPARED ... expected, self-healing" — which never notifies. A permanent upload
# failure therefore alarmed nobody. Same family as ga-gjfe78: a failed write and
# "nothing to do" read as the same value.
echo ""
echo "── _publish_run_fingerprint() — a failed latest.json upload is never swallowed (ga-dgnpyj) ──"

type _publish_run_fingerprint >/dev/null 2>&1 \
  && ok "_publish_run_fingerprint defined by lib-mode source" \
  || bad "_publish_run_fingerprint NOT defined — the uploads are still inline with '|| true'"

PUB_DIR="$(mktemp -d)"
PUB_CALLS="$PUB_DIR/aws-calls"; PUB_NOTIFY="$PUB_DIR/notify-calls"; PUB_LOG="$PUB_DIR/log"
printf '{"run_utc":"2026-09-25T07:00:00Z"}\n' > "$PUB_DIR/meta.json"
cat > "$PUB_DIR/aws" <<'STUB'
#!/bin/bash
# fake aws: records every call; FAKE_UP_FAIL_LATEST / FAKE_UP_FAIL_DATED make the
# matching s3 cp destination fail (rc 1) — latest.json vs the dated <ts>.json copy.
printf '%s\n' "$*" >> "$PUB_CALLS"
if [ "$1 $2" = "s3 cp" ]; then
  case "$4" in
    */_meta/latest.json) exit "${FAKE_UP_FAIL_LATEST:-0}" ;;
    */_meta/2*.json)     exit "${FAKE_UP_FAIL_DATED:-0}" ;;
  esac
fi
echo "unhandled aws stub invocation: $*" >&2; exit 1
STUB
chmod +x "$PUB_DIR/aws"
cat > "$PUB_DIR/notify" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PUB_NOTIFY"
STUB
chmod +x "$PUB_DIR/notify"
export PUB_CALLS PUB_NOTIFY

# _run_publish <latest-fail 0|1> <dated-fail 0|1> [aws-binary] → rc of the function
_run_publish() {
  : > "$PUB_CALLS"; : > "$PUB_NOTIFY"; : > "$PUB_LOG"
  AWS="${3:-$PUB_DIR/aws}" META="$PUB_DIR/meta.json" S3="s3://testbucket" LOG="$PUB_LOG" \
    NOTIFY="$PUB_DIR/notify" FAKE_UP_FAIL_LATEST="$1" FAKE_UP_FAIL_DATED="$2" \
    _publish_run_fingerprint
}
_upload_count() { grep -c '^s3 cp ' "$PUB_CALLS"; }
_notify_count() { grep -c . "$PUB_NOTIFY"; }

# Scenario A: both uploads work → success, silent, and the log SAYS it published.
_run_publish 0 0 && ok "scenario A (both uploads ok): returns success" || bad "scenario A: should return success"
[ "$(_upload_count)" = "2" ] && ok "scenario A: both latest.json and the dated copy were uploaded" || bad "scenario A: expected 2 uploads, got $(_upload_count)"
[ "$(_notify_count)" = "0" ] && ok "scenario A: no notification on success" || bad "scenario A: notified on success: $(cat "$PUB_NOTIFY")"
grep -qF "published _meta/latest.json" "$PUB_LOG" && ok "scenario A: log positively records the publish" || bad "scenario A: no positive 'published' line in the log"

# Scenario B: latest.json upload FAILS (dated ok) → must fail, notify once, log FAILED,
# and must NOT log the success line (the run does not report the fingerprint as published).
_run_publish 1 0 && bad "scenario B (latest.json upload fails): returned success — the failure was swallowed" || ok "scenario B (latest.json upload fails): returns failure"
[ "$(_notify_count)" = "1" ] && ok "scenario B: notify_fail fired exactly once" || bad "scenario B: expected 1 notification, got $(_notify_count)"
grep -qF "latest.json" "$PUB_NOTIFY" && ok "scenario B: the notification names _meta/latest.json (actionable)" || bad "scenario B: notification does not name latest.json: $(cat "$PUB_NOTIFY")"
grep -qF "FAILED" "$PUB_LOG" && ok "scenario B: log records the failed upload" || bad "scenario B: nothing logged about the failed upload"
grep -qF "published _meta/latest.json" "$PUB_LOG" && bad "scenario B: log claims the fingerprint was published although its upload failed" || ok "scenario B: no 'published' line when latest.json did not upload"
[ "$(_upload_count)" = "2" ] && ok "scenario B: the dated copy is still attempted (independent of latest.json)" || bad "scenario B: expected the dated upload to still be attempted (2 uploads), got $(_upload_count)"

# Scenario C: only the dated (audit-only) copy fails → the freshness proof IS current,
# so success and NO alarm — but the failure is still logged, not silently dropped.
_run_publish 0 1 && ok "scenario C (only the dated copy fails): returns success — the proof is current" || bad "scenario C: latest.json uploaded, should be success"
[ "$(_notify_count)" = "0" ] && ok "scenario C: no notification for an audit-only copy" || bad "scenario C: notified for the dated copy: $(cat "$PUB_NOTIFY")"
grep -qF "dated" "$PUB_LOG" && ok "scenario C: the dated-copy failure is logged" || bad "scenario C: dated-copy failure vanished from the log"

# Scenario D: BOTH fail → still exactly ONE notification per run (not one per upload).
_run_publish 1 1 && bad "scenario D (both fail): returned success" || ok "scenario D (both fail): returns failure"
[ "$(_notify_count)" = "1" ] && ok "scenario D: one notification per run, not one per failed upload" || bad "scenario D: expected 1 notification, got $(_notify_count)"

# Scenario E: the aws binary itself is missing (rc 127) — "could not run" is a failure
# too, not a silent pass.
_run_publish 0 0 "$PUB_DIR/no-such-aws" 2>/dev/null && bad "scenario E (aws missing): returned success" || ok "scenario E (aws missing): returns failure"
[ "$(_notify_count)" = "1" ] && ok "scenario E: a missing aws binary still notifies" || bad "scenario E: expected 1 notification, got $(_notify_count)"

# drift-guard: the live flow calls it exactly once (one alarm per night) and no
# latest.json upload line is left swallowed by '|| true'.
CALLS=$(grep -c '^ *_publish_run_fingerprint *\(#.*\)\?$' "$SCRIPT")
[ "$CALLS" = "1" ] && ok "drift-guard: the live flow calls _publish_run_fingerprint exactly once" || bad "drift-guard: expected exactly 1 call site of _publish_run_fingerprint, got $CALLS"
if grep -F '_meta/latest.json' "$SCRIPT" | grep -F 's3 cp' | grep -qF '|| true'; then
  bad "drift-guard: an 's3 cp ... _meta/latest.json' line still ends in '|| true' — the upload result is swallowed again"
else
  ok "drift-guard: no s3 cp of _meta/latest.json ends in '|| true'"
fi
rm -f "$PUB_DIR"/aws "$PUB_DIR"/notify "$PUB_DIR"/meta.json "$PUB_CALLS" "$PUB_NOTIFY" "$PUB_LOG" 2>/dev/null || true

# ── ga-ua269q: the nightly's REAL failure sequence, end to end ──────────────────────────
# Measured 2026-09-26 04:01:13 → 04:02:05 (hq): the disk preflight passes by a thin margin,
# the server-mediated sync starts, the connection is cut ("connection was closed") after the
# aborted sync already wrote ~2.1GB into the staging, and then BOTH the retry's preflight and
# the offline fallback's preflight refuse. The mirror added for the FIRST refusal site
# (ga-btnq6h) never ran on that path, so S3 stayed at an old manifest — 5 nights in a row.
# The unit tests above stub the helpers; the wiring that was missing lives in the main loop,
# which lib mode never runs. So this runs the WHOLE script (/bin/bash, like launchd) as a
# subprocess against a throwaway city, with stub dolt/df/aws/notify/gc/sleep first on PATH.
# Nothing real is touched: the city, the bucket, the notifier and the mailer are all fakes.
echo "── end-to-end: disk refusal AFTER an aborted sync (ga-ua269q) — real subprocess, stubbed dolt/df/aws ──"
E2E_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/s3backup-e2e.XXXXXX")"
trap '[ -n "${E2E_KEEP:-}" ] || rm -rf "$E2E_ROOT"' EXIT   # E2E_KEEP=1 keeps the throwaway cities for debugging

e2e_tid() { printf '%032d' "$1"; }                       # 32 chars of [0-9] = a valid table id
_E_LOCKH="0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; _E_ROOTH="0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; _E_GCG="00000000000000000000000000000000"
e2e_mkmanifest() { # <file> <n_tables> — names tables 1..n; no trailing newline, like Dolt's
  local f="$1" n="$2" i s="5:__DOLT__:$_E_LOCKH:$_E_ROOTH:$_E_GCG"
  for i in $(seq 1 "$n"); do s="$s:$(e2e_tid "$i"):$((i*7))"; done
  printf '%s' "$s" > "$f"
}
e2e_mkbackup() { # <dir> <n_tables> — a CLOSED backup dir (every named table present)
  local d="$1" n="$2" i; mkdir -p "$d"; e2e_mkmanifest "$d/manifest" "$n"
  for i in $(seq 1 "$n"); do printf 'table%s' "$i" > "$d/$(e2e_tid "$i").darc"; done
}

e2e_write_stubs() { # <bin dir>
  local b="$1"; mkdir -p "$b"
  cat > "$b/dolt" <<'STUB'
#!/bin/bash
# fake dolt: answers only the queries dolt-s3-backup.sh makes. E2E_SYNC_MODE:
#   ok                      — sync succeeds, touches nothing
#   abort                   — writes an EXTRA table into the staging, leaves the manifest
#                             alone, eats the disk headroom, then the connection is cut
#   abort_changes_manifest  — same, but the manifest is also replaced (a half-applied sync)
q=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && q="$2"; shift; done
echo "dolt: $q" >> "$E2E_CALLS"
case "$q" in
  "SHOW DATABASES") printf 'Database\nhq\ninformation_schema\n' ;;
  "SELECT 1") echo 1 ;;
  *"CALL DOLT_BACKUP('add'"*) : ;;
  *"dolt_log ORDER BY date"*) printf 'commit_hash\nabc123\n' ;;
  *"SELECT COUNT(*)"*) printf 'COUNT(*)\n5\n' ;;
  *"CALL DOLT_BACKUP('sync'"*)
    case "${E2E_SYNC_MODE:-ok}" in
      abort|abort_changes_manifest)
        printf 'partial-table-bytes' > "$E2E_STAGING/$(printf '%032d' 99).darc"
        [ "$E2E_SYNC_MODE" = abort_changes_manifest ] && cp "$E2E_STATE/new_manifest" "$E2E_STAGING/manifest"
        : > "$E2E_STATE/disk_full"
        echo "error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): connection was closed"
        exit 1 ;;
    esac ;;
esac
exit 0
STUB
  cat > "$b/df" <<'STUB'
#!/bin/bash
# fake df: plenty of room until the aborted sync flips $E2E_STATE/disk_full
if [ -e "$E2E_STATE/disk_full" ]; then avail=1000000; else avail=5000000; fi
printf 'Filesystem 1024-blocks Used Available Capacity iused ifree %%iused Mounted\n/dev/fake 9999999 1 %s 1%% 1 1 1%% /System/Volumes/Data\n' "$avail"
STUB
  printf '#!/bin/bash\nexit 0\n' > "$b/sleep"
  printf '#!/bin/bash\necho "$*" >> "$E2E_NOTIFY_CALLS"\n' > "$b/notify"
  printf '#!/bin/bash\necho "gc $*" >> "$E2E_CALLS"\nexit 0\n' > "$b/gc"
  printf '#!/bin/bash\necho "mail $*" >> "$E2E_CALLS"\n' > "$b/fake_mail"
  # fake aws: the bucket is a directory ($FB/<db>/<object>) — same shape as the proof lib's own selftest
  cat > "$b/aws" <<'STUB'
#!/bin/bash
echo "aws $*" >> "$CALLS"
[ "$1" = "--version" ] && { echo "aws-cli/fake"; exit 0; }
sub="$1"; shift
case "$sub" in
  s3api)
    prefix=""; while [ $# -gt 0 ]; do [ "$1" = "--prefix" ] && prefix="$2"; shift; done
    d="$FB/${prefix%/}"
    if [ ! -d "$d" ] || [ -z "$(ls -A "$d" 2>/dev/null)" ]; then echo "None"; exit 0; fi
    out=""; for f in "$d"/*; do out="${out:+$out	}${prefix}$(basename "$f")"; done
    echo "$out"; exit 0 ;;
  s3)
    op="$1"; shift
    case "$op" in
      cp)
        src="$1"; dst="$2"
        case "$src" in
          s3://*) key="${src#s3://*/}"; [ -f "$FB/$key" ] || exit 1; cp "$FB/$key" "$dst"; exit 0 ;;
          *)      key="${dst#s3://*/}"; mkdir -p "$FB/$(dirname "$key")"; cp "$src" "$FB/$key"; exit 0 ;;
        esac ;;
      sync)
        dir="${1%/}"; dst="$2"; shift 2
        dry=0; excl=""
        while [ $# -gt 0 ]; do
          case "$1" in --dryrun) dry=1 ;; --exclude) excl="$excl $2"; shift ;; esac; shift
        done
        key="${dst#s3://*/}"; key="${key%/}"; mkdir -p "$FB/$key"
        for f in "$dir"/*; do
          [ -f "$f" ] || continue; n="$(basename "$f")"
          skip=0; for e in $excl; do [ "$e" = "$n" ] && skip=1; done; [ $skip = 1 ] && continue
          if [ ! -f "$FB/$key/$n" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$FB/$key/$n")" ]; then
            if [ "$dry" = 1 ]; then echo "(dryrun) upload: $f to $dst$n"; else cp "$f" "$FB/$key/$n"; fi
          fi
        done
        exit 0 ;;
    esac ;;
esac
exit 99
STUB
  chmod +x "$b"/*
}

# e2e_case <name> <staging: closed|broken> <sync mode> <disk at start: ok|full>
# Leaves the run's paths in E2E_DIR / E2E_LOG and the script's exit code in E2E_RC.
e2e_case() {
  local name="$1" staging="$2" mode="$3" disk0="$4" E
  E="$E2E_ROOT/$name"; E2E_DIR="$E"
  # Fail-safe: this runs the script for real. A script WITHOUT the CITY/NOTIFY overrides (e.g. the
  # gate's base-commit check re-running this selftest against code from before the seam existed)
  # would use its hardcoded real city — the real log, the real failure-streak counter, a real push.
  # Refuse to run it at all; the assertions below then fail cleanly against a run that never happened.
  if ! grep -qF 'CITY="${DOLT_S3_BACKUP_CITY:-' "$SCRIPT" || ! grep -qF 'NOTIFY="${DOLT_S3_BACKUP_NOTIFY:-' "$SCRIPT"; then
    mkdir -p "$E"; E2E_LOG="$E/never-ran.log"; E2E_RC=99
    bad "e2e $name: the script under test has no DOLT_S3_BACKUP_CITY/NOTIFY override — running it would touch the REAL city (log, streak counter, push); NOT run"
    return 0
  fi
  mkdir -p "$E/state" "$E/tmp" "$E/home" "$E/city/.gc/logs" "$E/city/.gc/runtime/packs/dolt" "$E/city/.beads/dolt/hq" "$E/bucket"
  e2e_write_stubs "$E/bin"
  printf 'listener:\n  port: 43210\ndata_dir: "%s"\n' "$E/city/.beads/dolt" > "$E/city/.gc/runtime/packs/dolt/dolt-config.yaml"
  echo live > "$E/city/.beads/dolt/hq/blob"
  e2e_mkbackup "$E/city/.dolt-backup/hq" 4                 # local staging: 4 tables, closed
  [ "$staging" = broken ] && rm -f "$E/city/.dolt-backup/hq/$(e2e_tid 3).darc"
  e2e_mkbackup "$E/bucket/hq" 2                            # S3: the older copy from the last repair (closed)
  e2e_mkmanifest "$E/state/new_manifest" 3                 # what a half-applied sync leaves (tables 1-3, all present)
  [ "$disk0" = full ] && : > "$E/state/disk_full"
  E2E_LOG="$E/city/.gc/logs/dolt-s3-backup.log"
  env -i HOME="$E/home" TMPDIR="$E/tmp" PATH="$E/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    DOLT_S3_BACKUP_CITY="$E/city" DOLT_S3_BACKUP_NOTIFY="$E/bin/notify" BACKUP_FAIL_FAKE_MAIL="$E/bin/fake_mail" \
    RESEED_AFTER_UPLOAD=0 FB="$E/bucket" CALLS="$E/aws.calls" \
    E2E_STAGING="$E/city/.dolt-backup/hq" E2E_STATE="$E/state" E2E_CALLS="$E/dolt.calls" \
    E2E_NOTIFY_CALLS="$E/notify.calls" E2E_SYNC_MODE="$mode" \
    timeout 120 /bin/bash "$SCRIPT" > "$E/run.out" 2>&1
  E2E_RC=$?
  : >> "$E/notify.calls"; : >> "$E/aws.calls"; : >> "$E/dolt.calls"
}
e2e_same() { cmp -s "$1" "$2"; }                            # byte-identical files

# ── A: the measured sequence — preflight OK, sync cut, retry refused, fallback refused ──
e2e_case case-a closed abort ok
if [ "$E2E_RC" -eq 0 ] && [ "$(grep -c 'hq: sync preflight OK' "$E2E_LOG")" = 1 ] \
   && [ "$(grep -c 'hq: sync preflight REFUSED' "$E2E_LOG")" = 2 ] \
   && grep -q 'connection-timeout on sync — retrying' "$E2E_LOG" \
   && [ "$(grep -c "DOLT_BACKUP('sync'" "$E2E_DIR/dolt.calls")" = 1 ]; then
  ok "e2e A: the harness reproduces the measured chain (preflight OK → sync cut → retry refused → fallback refused)"
else
  bad "e2e A: harness did not reproduce the 04:01:13→04:02:05 chain (rc=$E2E_RC) — $(tail -5 "$E2E_LOG" | tr '\n' '|')"
fi
grep -q 'existing staging mirrored to S3 anyway' "$E2E_LOG" \
  && ok "e2e A: the log says the existing staging was mirrored to S3 anyway (the bead's acceptance line)" \
  || bad "e2e A: no 'existing staging mirrored to S3 anyway' line — S3 was left at the old copy (the ga-ua269q bug)"
e2e_same "$E2E_DIR/bucket/hq/manifest" "$E2E_DIR/city/.dolt-backup/hq/manifest" \
  && ok "e2e A: the S3 manifest advanced to the staging's manifest" \
  || bad "e2e A: the S3 manifest did NOT advance — still the old 2-table copy"
missing=""; for i in 1 2 3 4 99; do [ -f "$E2E_DIR/bucket/hq/$(e2e_tid "$i").darc" ] || missing="$missing $i"; done
[ -z "$missing" ] && ok "e2e A: every table the new manifest names is in the bucket" || bad "e2e A: tables missing from the bucket:$missing"
grep -q 'hq(disco)' "$E2E_DIR/notify.calls" && ! grep -q 'hq(disco+s3)' "$E2E_DIR/notify.calls" \
  && ok "e2e A: the alert says (disco) — the disk refusal, with S3 proven sound (not disco+s3)" \
  || bad "e2e A: alert tag wrong: $(cat "$E2E_DIR/notify.calls")"
grep -q -- '--delete' "$E2E_DIR/aws.calls" \
  && bad "e2e A: an aws call used --delete — the mirror on a failed night must be additive" \
  || ok "e2e A: no aws call used --delete (additive mirror only)"

# ── B: a half-applied sync CHANGED the manifest — the fingerprint gate must keep it inert ──
# Its new manifest is CLOSED (tables 1-3 exist), so the closure proof alone would let it
# through: only the before/after fingerprint stops it.
e2e_case case-b closed abort_changes_manifest ok
e2e_mkmanifest "$E2E_ROOT/old-s3-manifest" 2                # what S3 held BEFORE the run, rebuilt independently
if ! grep -q 'mirrored to S3 anyway' "$E2E_LOG" && e2e_same "$E2E_DIR/bucket/hq/manifest" "$E2E_ROOT/old-s3-manifest" \
   && ! e2e_same "$E2E_DIR/bucket/hq/manifest" "$E2E_DIR/city/.dolt-backup/hq/manifest" \
   && [ ! -f "$E2E_DIR/bucket/hq/$(e2e_tid 99).darc" ]; then
  ok "e2e B: manifest changed by the aborted sync → NOTHING mirrored (S3 untouched, extra table not uploaded)"
else
  bad "e2e B: a staging whose manifest the aborted sync changed was mirrored to S3 anyway"
fi
grep -q '\] hq: disk refusal after an aborted sync — staging manifest CHANGED' "$E2E_LOG" \
  && ok "e2e B: the log says WHY it is inert (manifest changed during the attempt)" \
  || bad "e2e B: inert but silent — the log gives no reason: $(grep -i 'hq:' "$E2E_LOG" | tail -3 | tr '\n' '|')"
grep -q 'hq(disco' "$E2E_DIR/notify.calls" \
  && ok "e2e B: the failure is still reported (hq(disco…) in the alert)" \
  || bad "e2e B: alert lost the hq failure: $(cat "$E2E_DIR/notify.calls")"

# ── C: manifest untouched but the staging is NOT closed — the closure proof must refuse ──
e2e_case case-c broken abort ok
if ! grep -q 'mirrored to S3 anyway' "$E2E_LOG" && [ "$(ls "$E2E_DIR/bucket/hq" | wc -l | tr -d ' ')" = 3 ] \
   && e2e_same "$E2E_DIR/bucket/hq/manifest" "$E2E_ROOT/old-s3-manifest"; then
  ok "e2e C: staging whose manifest names a missing table → nothing uploaded (S3 keeps its 2 tables + old manifest)"
else
  bad "e2e C: a non-closed staging was mirrored: $(ls "$E2E_DIR/bucket/hq" | tr '\n' ' ')"
fi
grep -q 'hq(disco+s3)' "$E2E_DIR/notify.calls" \
  && ok "e2e C: the alert says (disco+s3) — S3 was not brought up to date and that is not hidden" \
  || bad "e2e C: alert tag wrong: $(cat "$E2E_DIR/notify.calls")"

# ── F: the FIRST refusal site (ga-btnq6h) is unchanged: refused before any sync is attempted ──
e2e_case case-f closed ok full
if grep -q 'existing staging mirrored to S3 anyway' "$E2E_LOG" \
   && e2e_same "$E2E_DIR/bucket/hq/manifest" "$E2E_DIR/city/.dolt-backup/hq/manifest" \
   && [ "$(grep -c "DOLT_BACKUP('sync'" "$E2E_DIR/dolt.calls")" = 0 ]; then
  ok "e2e F: first-site refusal (no sync attempted) still mirrors the staging — ga-btnq6h behaviour intact"
else
  bad "e2e F: first-site refusal regressed: $(grep 'hq:' "$E2E_LOG" | tail -3 | tr '\n' '|')"
fi

# ── H: a healthy night — the harness itself is sound, and no mirror-after-refusal noise ──
e2e_case case-h closed ok ok
if [ "$E2E_RC" -eq 0 ] && grep -q 'hq: OK (issues=5' "$E2E_LOG" && [ ! -s "$E2E_DIR/notify.calls" ] \
   && ! grep -q 'disk refusal' "$E2E_LOG" && e2e_same "$E2E_DIR/bucket/hq/manifest" "$E2E_DIR/city/.dolt-backup/hq/manifest"; then
  ok "e2e H: a healthy night is untouched (hq OK, no alert, no refusal lines, S3 in step with staging)"
else
  bad "e2e H: healthy night misbehaved (rc=$E2E_RC): $(tail -6 "$E2E_LOG" | tr '\n' '|')"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
