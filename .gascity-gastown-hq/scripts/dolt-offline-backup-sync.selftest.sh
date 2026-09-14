#!/bin/bash
# dolt-offline-backup-sync.selftest.sh (ga-o3nqy2) — tests for the server-free
# APFS-clonefile backup sync shared by dolt-s3-backup.sh and
# dolt-backup-reseed.sh.
#
# Two kinds of coverage:
#   1. Real, hermetic integration tests of _offline_backup_sync() itself,
#      against a tiny THROWAWAY `dolt init` repo under a fresh mktemp dir —
#      never the live city databases. This is deliberate: the whole point of
#      this mechanism is "does clonefile + the embedded CLI actually dodge
#      the server", which a stubbed fake `dolt` binary cannot prove either
#      way. Real dolt, real clonefile, real sync-url/restore round trip.
#   2. Drift-guards proving dolt-s3-backup.sh and dolt-backup-reseed.sh
#      actually call this function at the right point, not just that it
#      exists — same convention as dolt-s3-backup.selftest.sh's own
#      drift-guards.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/dolt-offline-backup-sync.sh"
S3_SCRIPT="$HERE/dolt-s3-backup.sh"
RESEED_SCRIPT="$HERE/dolt-backup-reseed.sh"

# shellcheck disable=SC1090
. "$LIB"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-offline-backup-sync.selftest.sh ==="

for fn in _offline_sync_log _offline_sync_data_dir _offline_sync_live_port _offline_backup_sync; do
  type "$fn" >/dev/null 2>&1 \
    && ok "$fn defined by sourcing the lib" \
    || { bad "$fn NOT defined — lib source broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
done

# ── _offline_sync_data_dir() — pure config parsing ────────────────────────────
echo "── _offline_sync_data_dir() ──"
CFG_DIR="$(mktemp -d "$HERE/../.gc-worktrees/.offline-sync-selftest-cfg.XXXXXX" 2>/dev/null || mktemp -d)"
GOOD_CFG="$CFG_DIR/good.yaml"
cat > "$GOOD_CFG" <<'YAML'
listener:
  port: 52756
data_dir: "/fake/city/.beads/dolt"
YAML
[ "$(OFFLINE_SYNC_DOLT_CFG="$GOOD_CFG" _offline_sync_data_dir)" = "/fake/city/.beads/dolt" ] \
  && ok "parses data_dir out of a well-formed config" \
  || bad "did not parse data_dir correctly"

MISSING_CFG="$CFG_DIR/missing.yaml"
cat > "$MISSING_CFG" <<'YAML'
listener:
  port: 52756
YAML
[ -z "$(OFFLINE_SYNC_DOLT_CFG="$MISSING_CFG" _offline_sync_data_dir)" ] \
  && ok "config without data_dir: line -> empty (not a guess)" \
  || bad "should have returned empty when data_dir: is absent"

[ -z "$(OFFLINE_SYNC_DOLT_CFG="$CFG_DIR/does-not-exist.yaml" _offline_sync_data_dir)" ] \
  && ok "nonexistent config file -> empty" \
  || bad "should have returned empty for a nonexistent config file"

# ── _offline_sync_live_port() — pure config parsing (primary path) ───────────
echo "── _offline_sync_live_port() ──"
[ "$(OFFLINE_SYNC_DOLT_CFG="$GOOD_CFG" _offline_sync_live_port)" = "52756" ] \
  && ok "parses listener.port out of a well-formed config" \
  || bad "did not parse listener.port correctly"

# ── _offline_backup_sync() — real dolt, real clonefile, throwaway repo ───────
echo "── _offline_backup_sync() — real dolt end-to-end ──"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/offline-sync-selftest.XXXXXX")"
DATA_DIR="$WORK/data"
mkdir -p "$DATA_DIR"

FAKE_LIVE_PORT=54011   # arbitrary, != the embedded CLI's default (3306)
TEST_CFG="$WORK/dolt-config.yaml"
cat > "$TEST_CFG" <<YAML
listener:
  port: $FAKE_LIVE_PORT
data_dir: "$DATA_DIR"
YAML

export OFFLINE_SYNC_DOLT_CFG="$TEST_CFG"
export OFFLINE_SYNC_TMP_ROOT="$WORK"
export OFFLINE_SYNC_LOG="$WORK/offline-sync.log"

# Scenario A: happy path — clone -> sync-url -> restore -> count matches.
# This is the RED/GREEN proof the bead's acceptance criteria asks for: before
# this function existed, nothing could turn a connection-timeout-failed sync
# into a restorable backup; now this scenario proves it end-to-end with real
# dolt, no server involved anywhere in the call chain.
( mkdir -p "$DATA_DIR/testdb" && cd "$DATA_DIR/testdb" \
    && dolt init >/dev/null 2>&1 \
    && dolt sql -q "CREATE TABLE issues (id int primary key, title varchar(100)); INSERT INTO issues VALUES (1,'a'),(2,'b'),(3,'c');" >/dev/null 2>&1 )
SRC_COUNT="$(cd "$DATA_DIR/testdb" && dolt sql -q "SELECT COUNT(*) FROM issues" --result-format csv 2>/dev/null | tail -1)"
[ "$SRC_COUNT" = "3" ] || { bad "test fixture setup broken (source count=$SRC_COUNT, expected 3) — aborting suite"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

DEST_A="$WORK/dest-a"
if _offline_backup_sync "testdb" "$DEST_A"; then
  ok "scenario A (happy path): returns success"
else
  bad "scenario A (happy path): should have returned success"
fi
if [ -d "$DEST_A" ]; then
  VERIFY_A="$WORK/verify-a"
  mkdir -p "$VERIFY_A"
  ( cd "$VERIFY_A" && dolt backup restore "file://$DEST_A" "restored" >/dev/null 2>&1 )
  RESTORED_COUNT="$(cd "$VERIFY_A/restored" 2>/dev/null && dolt sql -q "SELECT COUNT(*) FROM issues" --result-format csv 2>/dev/null | tail -1)"
  [ "$RESTORED_COUNT" = "3" ] \
    && ok "scenario A: restored backup count (3) matches source (3) — the actual proof, not just exit code" \
    || bad "scenario A: restored count='$RESTORED_COUNT', expected 3"
else
  bad "scenario A: dest dir '$DEST_A' was never created"
fi
grep -qF "testdb: offline-sync: OK" "$OFFLINE_SYNC_LOG" \
  && ok "scenario A: logged the OK line" \
  || bad "scenario A: missing the OK log line"

# Scenario B: source directory carries a (cloned) sql-server.info marker ->
# must refuse before ever touching dolt, and must never create the dest.
mkdir -p "$DATA_DIR/testdb2/.dolt"
: > "$DATA_DIR/testdb2/.dolt/sql-server.info"   # existence is all the guard checks
DEST_B="$WORK/dest-b"
if _offline_backup_sync "testdb2" "$DEST_B"; then
  bad "scenario B (sql-server.info present): should have refused"
else
  ok "scenario B (sql-server.info present): refuses"
fi
[ ! -e "$DEST_B" ] \
  && ok "scenario B: dest was never created — refusal happened before any sync attempt" \
  || bad "scenario B: dest '$DEST_B' exists despite the refusal — sync ran when it should not have"
grep -qF "testdb2: offline-sync: REFUSING — cloned sql-server.info present" "$OFFLINE_SYNC_LOG" \
  && ok "scenario B: logged the specific refusal reason" \
  || bad "scenario B: missing the sql-server.info refusal log line"

# Scenario C: embedded @@port collides with the (fake) live port — the
# not-actually-isolated case. Real dolt's embedded default is always 3306, so
# set the fake "live" port to 3306 too: a genuine collision, no stub needed.
COLLIDE_CFG="$WORK/dolt-config-collide.yaml"
cat > "$COLLIDE_CFG" <<'YAML'
listener:
  port: 3306
data_dir: "REPLACED"
YAML
# shellcheck disable=SC2016
sed -i '' "s#REPLACED#$DATA_DIR#" "$COLLIDE_CFG"
mkdir -p "$DATA_DIR/testdb3" && ( cd "$DATA_DIR/testdb3" && dolt init >/dev/null 2>&1 )
DEST_C="$WORK/dest-c"
if OFFLINE_SYNC_DOLT_CFG="$COLLIDE_CFG" _offline_backup_sync "testdb3" "$DEST_C"; then
  bad "scenario C (embedded port collides with live port): should have refused"
else
  ok "scenario C (embedded port collides with live port): refuses"
fi
[ ! -e "$DEST_C" ] \
  && ok "scenario C: dest was never created" \
  || bad "scenario C: dest '$DEST_C' exists despite the refusal"

# Scenario D: data_dir cannot be determined (malformed config) -> refuses
# without attempting any filesystem operation on a guessed path.
DEST_D="$WORK/dest-d"
if OFFLINE_SYNC_DOLT_CFG="$MISSING_CFG" _offline_backup_sync "testdb" "$DEST_D"; then
  bad "scenario D (no data_dir in config): should have refused"
else
  ok "scenario D (no data_dir in config): refuses"
fi
[ ! -e "$DEST_D" ] && ok "scenario D: dest was never created" || bad "scenario D: dest '$DEST_D' exists despite refusal"

# Scenario E: source db does not exist under data_dir -> clonefile fails -> refuses.
DEST_E="$WORK/dest-e"
if _offline_backup_sync "no-such-db" "$DEST_E"; then
  bad "scenario E (source db missing): should have refused"
else
  ok "scenario E (source db missing): refuses"
fi

# ── _offline_sync_same_volume() — the ga-o3nqy2 gate-fix: `man cp` on -c says
# a cross-volume cp -c does NOT error, it silently falls back to a slow full
# copy. Reliably reproducing an actual second volume isn't portable across
# environments, so this tests the function directly: the trivial same-path
# true case, and the "can't stat one side" refuse-on-uncertainty case (a
# real, portable way to exercise the false branch).
echo "── _offline_sync_same_volume() ──"
_offline_sync_same_volume "$WORK" "$WORK" \
  && ok "same path compared to itself -> same volume" \
  || bad "same path compared to itself should be the same volume"
_offline_sync_same_volume "$WORK" "/definitely/does/not/exist/$$" \
  && bad "a path stat can't resolve should NOT report as the same volume" \
  || ok "a path stat can't resolve -> not the same volume (can't tell = refuse)"

# Scenario F: tmp root stat can't resolve at all -> _offline_backup_sync must
# refuse via the same-volume gate before ever calling mktemp/cp.
DEST_F="$WORK/dest-f"
if OFFLINE_SYNC_TMP_ROOT="/definitely/does/not/exist/$$" _offline_backup_sync "testdb" "$DEST_F"; then
  bad "scenario F (tmp root not on a resolvable volume): should have refused"
else
  ok "scenario F (tmp root not on a resolvable volume): refuses"
fi
[ ! -e "$DEST_F" ] && ok "scenario F: dest was never created" || bad "scenario F: dest '$DEST_F' exists despite the refusal"

# No leftover clone directories: every scenario above must clean up after itself.
LEFTOVER="$(find "$WORK" -mindepth 1 -maxdepth 1 -name 'offline-sync-*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEFTOVER" = "0" ] \
  && ok "no leftover clone directories after any scenario (success, failure, or refusal)" \
  || { bad "found $LEFTOVER leftover offline-sync-* clone dir(s) under $WORK — cleanup is not happening on every exit path"; find "$WORK" -mindepth 1 -maxdepth 1 -name 'offline-sync-*' >&2; }

unset OFFLINE_SYNC_DOLT_CFG OFFLINE_SYNC_TMP_ROOT OFFLINE_SYNC_LOG
rm -rf "$WORK" "$CFG_DIR" 2>/dev/null || true

# ── drift-guard: timeout wrapping present in the lib itself ──────────────────
echo "── drift-guard: clone + sync-url calls are timeout-bounded ──"
if grep -qF 'timeout "$clone_timeout" cp -c -R' "$LIB"; then
  ok "the clonefile step is wrapped in a timeout (never hangs forever even on local I/O)"
else
  bad "the clonefile step is not timeout-wrapped"
fi
if grep -qF 'timeout "$sync_timeout" "$dolt_bin" --data-dir "$clone" backup sync-url' "$LIB"; then
  ok "the sync-url step is wrapped in a timeout"
else
  bad "the sync-url step is not timeout-wrapped"
fi
if grep -qF 'sync_timeout="${OFFLINE_SYNC_TIMEOUT:-1800}"' "$LIB"; then
  ok "sync timeout is caller-overridable via OFFLINE_SYNC_TIMEOUT (default 1800, matching the old reseed budget)"
else
  bad "OFFLINE_SYNC_TIMEOUT override wiring missing or changed shape"
fi

# ── drift-guard: dolt-s3-backup.sh wiring ─────────────────────────────────────
echo "── drift-guard: dolt-s3-backup.sh wires the offline fallback in ──"
if grep -qE '^\. .*dolt-offline-backup-sync\.sh"?$|^source .*dolt-offline-backup-sync\.sh"?$' "$S3_SCRIPT"; then
  ok "dolt-s3-backup.sh sources dolt-offline-backup-sync.sh"
else
  bad "dolt-s3-backup.sh does not source dolt-offline-backup-sync.sh"
fi
RETRY_LINE=$(grep -nF '_sync_with_connection_timeout_retry "$db"' "$S3_SCRIPT" | head -1 | cut -d: -f1)
OFFLINE_CALL_LINE=$(grep -nF '_offline_backup_sync "$db"' "$S3_SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$RETRY_LINE" ] && [ -n "$OFFLINE_CALL_LINE" ] && [ "$OFFLINE_CALL_LINE" -gt "$RETRY_LINE" ]; then
  ok "offline fallback is called AFTER the connection-timeout retry, not before/instead of it"
else
  bad "offline fallback call missing, or not positioned after the connection-timeout retry"
fi
if grep -qF 'failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(sync)"' "$S3_SCRIPT"; then
  ok "a db still only counts as failed if the offline fallback ALSO fails (existing failure accounting reused, not bypassed)"
else
  bad "failure accounting for the connection-timeout branch looks different than expected"
fi
if grep -qF 'OFFLINE_SYNC_TIMEOUT="$SYNC_TIMEOUT"' "$S3_SCRIPT"; then
  ok "dolt-s3-backup.sh keeps its own SYNC_TIMEOUT budget for the offline fallback (not silently changed)"
else
  bad "dolt-s3-backup.sh does not pin OFFLINE_SYNC_TIMEOUT to its own SYNC_TIMEOUT"
fi

# ── drift-guard: dolt-backup-reseed.sh wiring ─────────────────────────────────
echo "── drift-guard: dolt-backup-reseed.sh wires the offline sync in ──"
if grep -qE '^\. .*dolt-offline-backup-sync\.sh"?$|^source .*dolt-offline-backup-sync\.sh"?$' "$RESEED_SCRIPT"; then
  ok "dolt-backup-reseed.sh sources dolt-offline-backup-sync.sh"
else
  bad "dolt-backup-reseed.sh does not source dolt-offline-backup-sync.sh"
fi
if grep -qF '_offline_backup_sync "$DB" "$NEW_DIR"' "$RESEED_SCRIPT"; then
  ok "reseed's 'new backup' step calls _offline_backup_sync against NEW_DIR"
else
  bad "reseed does not call _offline_backup_sync against NEW_DIR"
fi
if grep -qE "CALL DOLT_BACKUP\('(add|sync)'" "$RESEED_SCRIPT"; then
  bad "reseed still calls the server-mediated CALL DOLT_BACKUP add/sync — dead server path not removed"
else
  ok "reseed no longer calls the server-mediated CALL DOLT_BACKUP add/sync for its new-backup step"
fi
if grep -qF 'OFFLINE_SYNC_TIMEOUT=1800' "$RESEED_SCRIPT"; then
  ok "reseed keeps its old 1800s sync budget for the offline path (not silently changed)"
else
  bad "reseed does not pin OFFLINE_SYNC_TIMEOUT to its old 1800s budget"
fi
SYNC_CALL_LINE=$(grep -nF '_offline_backup_sync "$DB" "$NEW_DIR"' "$RESEED_SCRIPT" | head -1 | cut -d: -f1)
RESTORE_LINE=$(grep -nF 'backup restore' "$RESEED_SCRIPT" | head -1 | cut -d: -f1)
MV_LINE=$(grep -nF 'mv "$BACKUP_DIR" "$OLD_DIR"' "$RESEED_SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$SYNC_CALL_LINE" ] && [ -n "$RESTORE_LINE" ] && [ -n "$MV_LINE" ] \
   && [ "$RESTORE_LINE" -gt "$SYNC_CALL_LINE" ] && [ "$MV_LINE" -gt "$RESTORE_LINE" ]; then
  ok "order preserved: sync new backup -> restore + verify -> swap (nothing deleted before verification, per the file's own non-negotiable rule)"
else
  bad "step order looks wrong: sync=$SYNC_CALL_LINE restore=$RESTORE_LINE mv=$MV_LINE (expected sync < restore < mv)"
fi
if grep -qF 'REMOTE="reseed-$DB"' "$RESEED_SCRIPT"; then
  bad "dead REMOTE variable (server-mediated remote name) still present — cleanup incomplete"
else
  ok "the now-unused REMOTE variable was removed along with the server-mediated path"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
