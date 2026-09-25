#!/bin/bash
# dolt-backup-residue-reclaim.selftest.sh — unit + stubbed-integration tests
# for dolt-backup-residue-reclaim.sh (ga-8f1uh0).
#
# Hermetic: sources the script as a LIBRARY (DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1)
# for the pure-function tests, and uses stub `aws`/`notify` binaries plus a
# throwaway BACKUP_ROOT fixture for the execution-level tests. Real AWS is
# NEVER called; nothing outside a mktemp'd scratch dir is ever touched or
# deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-backup-residue-reclaim.sh"

export DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-backup-residue-reclaim.selftest.sh ==="

for fn in _prod_sentinel_active _size_coherent _should_release_residue _parse_fingerprint_to_file _fingerprint_db_state _reclaim_one_residue _reap_backup_residue; do
  type "$fn" >/dev/null 2>&1 \
    && ok "$fn defined by lib-mode source" \
    || { bad "$fn NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
done

echo ""
echo "── _prod_sentinel_active() (ga-h565g pattern) ──"
_prod_sentinel_active "/real/default" "/real/default" 0 && ok "root==default, prod unset → sentinel active (forces dry-run)" || bad "should be sentinel-active"
_prod_sentinel_active "/real/default" "/real/default" 1 && bad "root==default, prod=1 should NOT be sentinel-active" || ok "root==default, prod=1 → sentinel inactive (opt-in honored)"
_prod_sentinel_active "/fake/test" "/real/default" 0 && bad "overridden root should NOT be sentinel-active" || ok "overridden root, prod unset → sentinel inactive (test root exercises real path)"
_prod_sentinel_active "/fake/test" "/real/default" 1 && bad "overridden root + prod=1 should NOT be sentinel-active" || ok "overridden root, prod=1 → sentinel inactive"

echo ""
echo "── _size_coherent() ──"
_size_coherent 1000 1000 50 && ok "equal sizes → coherent" || bad "equal sizes should be coherent"
_size_coherent 500 1000 50 && ok "exactly at 50% ratio → coherent (inclusive boundary)" || bad "50% boundary should be coherent"
_size_coherent 499 1000 50 && bad "499/1000 (49.9%) should NOT be coherent at 50% floor" || ok "just below 50% ratio → NOT coherent"
_size_coherent 2000 1000 50 && ok "fingerprint LARGER than local → coherent (only shrink direction is suspicious)" || bad "larger fingerprint should be coherent"
_size_coherent "" 1000 50 && bad "empty fingerprint size should fail closed" || ok "empty fingerprint size → fails closed"
_size_coherent 1000 "" 50 && bad "empty local size should fail closed" || ok "empty local size → fails closed"
_size_coherent abc 1000 50 && bad "non-numeric fingerprint size should fail closed" || ok "non-numeric fingerprint size → fails closed"
_size_coherent 1000 0 50 && bad "zero local size must never validate (div-by-zero risk + suspicious reading)" || ok "zero local size → fails closed"

echo ""
echo "── _should_release_residue() ──"
NOW=2000000; OLD=1990000   # 10000s apart — clears any settle <= 10000s
_should_release_residue "$OLD" "$NOW" 7200 2000001 1 1 && ok "happy path: settled + fresher run + manifest ok + size ok → release" || bad "happy path should release"
_should_release_residue "$OLD" "$NOW" 7200 1989999 1 1 && bad "run_epoch OLDER than residue mtime must NOT release" || ok "stale run_epoch (older than residue) → correctly spared"
_should_release_residue "$OLD" "$NOW" 7200 1990000 1 1 && bad "run_epoch EQUAL to residue mtime must NOT release (needs strictly newer)" || ok "run_epoch equal to residue mtime → correctly spared (boundary)"
_should_release_residue "$OLD" "$NOW" 7200 2000001 0 1 && bad "manifest_ok=0 must NOT release" || ok "manifest not confirmed → correctly spared"
_should_release_residue "$OLD" "$NOW" 7200 2000001 1 0 && bad "size_ok=0 must NOT release" || ok "size not coherent → correctly spared"
_should_release_residue "$OLD" "$NOW" 50000 2000001 1 1 && bad "settle window not yet cleared must NOT release" || ok "settle window not yet cleared → correctly spared"
_should_release_residue "" "$NOW" 7200 2000001 1 1 && bad "empty old_mtime should fail closed" || ok "empty old_mtime → fails closed"
_should_release_residue "$OLD" "$NOW" 7200 "" 1 1 && bad "empty run_epoch should fail closed" || ok "empty run_epoch → fails closed"
_should_release_residue "$OLD" "$NOW" 7200 abc 1 1 && bad "non-numeric run_epoch should fail closed" || ok "non-numeric run_epoch → fails closed"

echo ""
echo "── _parse_fingerprint_to_file() ──"
FIX_JSON="$(mktemp)"; FIX_OUT="$(mktemp)"
cat > "$FIX_JSON" <<'JSON'
{
  "run_utc": "2026-09-16T07:08:53Z",
  "databases": {
    "gastown": {"issues": 2622, "head": "abc123", "backup_size": "125M"},
    "hq": {"issues": 7242, "head": "def456", "backup_size": "13G"},
    "small": {"issues": 1, "head": "ghi789", "backup_size": "452K"},
    "nohead": {"issues": 0, "backup_size": "1K"},
    "badsize": {"issues": 0, "head": "x", "backup_size": "not-a-size"},
    "nosize": {"issues": 0, "head": "x"}
  }
}
JSON

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "gastown" "$FIX_OUT"
if [ "$(cat "$FIX_OUT")" = "$(printf '1789542533\t131072000\tabc123')" ]; then
  ok "valid entry (125M) parses to correct epoch/bytes/head"
else
  bad "valid entry (125M) parsed incorrectly: got '$(cat "$FIX_OUT")'"
fi

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "hq" "$FIX_OUT"
if [ "$(cat "$FIX_OUT")" = "$(printf '1789542533\t13958643712\tdef456')" ]; then
  ok "valid entry (13G) parses to correct bytes"
else
  bad "valid entry (13G) parsed incorrectly: got '$(cat "$FIX_OUT")'"
fi

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "small" "$FIX_OUT"
if [ "$(cat "$FIX_OUT")" = "$(printf '1789542533\t462848\tghi789')" ]; then
  ok "valid entry (452K) parses to correct bytes"
else
  bad "valid entry (452K) parsed incorrectly: got '$(cat "$FIX_OUT")'"
fi

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "nohead" "$FIX_OUT"
if [ "$(cat "$FIX_OUT")" = "$(printf '1789542533\t1024\t')" ]; then
  ok "entry missing head → empty head field, still parses size (head is informational only)"
else
  bad "missing-head entry parsed incorrectly: got '$(cat "$FIX_OUT")'"
fi

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "badsize" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "unparseable backup_size should produce EMPTY output (fail closed), got '$(cat "$FIX_OUT")'" || ok "unparseable backup_size → empty output (fails closed)"

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "nosize" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "missing backup_size should produce EMPTY output" || ok "missing backup_size → empty output (fails closed)"

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "does-not-exist" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "unknown db should produce EMPTY output" || ok "unknown db → empty output (fails closed)"

: > "$FIX_OUT"; _parse_fingerprint_to_file "/nonexistent/path.json" "gastown" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "unreadable JSON file should produce EMPTY output" || ok "unreadable JSON file → empty output (fails closed)"

echo '{ this is not json' > "$FIX_JSON"
: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "gastown" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "malformed JSON should produce EMPTY output" || ok "malformed JSON → empty output (fails closed)"

cat > "$FIX_JSON" <<'JSON'
{"run_utc": "not-a-timestamp", "databases": {"gastown": {"head": "x", "backup_size": "1K"}}}
JSON
: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "gastown" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "malformed run_utc should produce EMPTY output" || ok "malformed run_utc → empty output (fails closed)"

rm -f "$FIX_JSON" "$FIX_OUT"

echo ""
echo "── _parse_fingerprint_to_file() — per-db run_utc precedence (ga-6xo4r0) ──"
FIX_JSON="$(mktemp)"; FIX_OUT="$(mktemp)"
cat > "$FIX_JSON" <<'JSON'
{
  "run_utc": "2020-01-01T00:00:00Z",
  "databases": {
    "adhoc": {"issues": 5, "backup_size": "10M", "run_utc": "2026-09-21T15:30:00Z"},
    "untouched": {"issues": 9, "backup_size": "20M"},
    "corrupt": {"issues": 1, "backup_size": "1M", "run_utc": "not-a-timestamp"}
  }
}
JSON

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "adhoc" "$FIX_OUT"
if [ "$(cat "$FIX_OUT")" = "$(printf '1790004600\t10485760\t')" ]; then
  ok "entry WITH its own run_utc → uses the PER-DB timestamp, not the stale shared top-level one"
else
  bad "per-db run_utc should have taken precedence: got '$(cat "$FIX_OUT")'"
fi

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "untouched" "$FIX_OUT"
if [ "$(cat "$FIX_OUT")" = "$(printf '1577836800\t20971520\t')" ]; then
  ok "entry WITHOUT its own run_utc → falls back to the shared top-level one (backward compatible, sibling of an ad hoc-touched db unaffected)"
else
  bad "fallback to top-level run_utc broken: got '$(cat "$FIX_OUT")'"
fi

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "corrupt" "$FIX_OUT"
[ -s "$FIX_OUT" ] && bad "a PRESENT but malformed per-db run_utc must fail closed, not silently substitute the top-level value, got '$(cat "$FIX_OUT")'" || ok "malformed per-db run_utc → empty output (fails closed, never silently guesses)"

rm -f "$FIX_JSON" "$FIX_OUT"

echo ""
echo "── _parse_fingerprint_to_file() — an entry the writer marked FAILED is NEVER proof (ga-gjfe78) ──"
# dolt-s3-backup.sh used to drop a failing db from _meta/latest.json entirely; it
# now publishes it as {"status":"failed", ...}. A consumer that only knew the old
# shape must not read that entry as fresh, and a future writer that "helpfully"
# adds run_utc/backup_size/head to a failed entry (for display) must not turn it
# into proof either. Rule under test: an explicit status other than "ok" means
# NOT PROVEN, whatever other keys sit next to it. No status = legacy ok entry.
FIX_JSON="$(mktemp)"; FIX_OUT="$(mktemp)"
cat > "$FIX_JSON" <<'JSON'
{
  "run_utc": "2026-09-16T07:08:53Z",
  "databases": {
    "okexplicit": {"status": "ok", "issues": 1, "head": "h1", "backup_size": "1M"},
    "legacy": {"issues": 1, "head": "h2", "backup_size": "2M"},
    "failednew": {"status": "failed", "reason": "sync", "last_ok_run_utc": "2026-09-10T07:00:00Z", "last_ok": {"issues": 9, "head": "old", "backup_size": "1M"}},
    "failedproofkeys": {"status": "failed", "run_utc": "2026-09-16T07:08:53Z", "issues": 9, "head": "old", "backup_size": "1M"},
    "failedsizeonly": {"status": "failed", "backup_size": "1M"},
    "statusnull": {"status": null, "backup_size": "1M"},
    "statusweird": {"status": "partial", "backup_size": "1M"},
    "statusnumber": {"status": 1, "backup_size": "1M"},
    "statusempty": {"status": "", "backup_size": "1M"}
  }
}
JSON

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "okexplicit" "$FIX_OUT"
[ "$(cat "$FIX_OUT")" = "$(printf '1789542533\t1048576\th1')" ] && ok "explicit status=ok entry still parses as proof" || bad "explicit status=ok entry should parse: got '$(cat "$FIX_OUT")'"

: > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "legacy" "$FIX_OUT"
[ "$(cat "$FIX_OUT")" = "$(printf '1789542533\t2097152\th2')" ] && ok "legacy entry (no status key) still parses as proof — every fingerprint published before ga-gjfe78 keeps working" || bad "legacy entry should parse: got '$(cat "$FIX_OUT")'"

for pair in \
  "failednew|new-format failed entry (no proof keys)" \
  "failedproofkeys|failed entry that ALSO carries run_utc/head/backup_size" \
  "failedsizeonly|failed entry carrying only a backup_size" \
  "statusnull|status:null" \
  "statusweird|unrecognized status string" \
  "statusnumber|non-string status" \
  "statusempty|empty-string status"; do
  key="${pair%%|*}"; label="${pair#*|}"
  : > "$FIX_OUT"; _parse_fingerprint_to_file "$FIX_JSON" "$key" "$FIX_OUT"
  [ -s "$FIX_OUT" ] && bad "$label must produce EMPTY output (not proven), got '$(cat "$FIX_OUT")'" || ok "$label → empty output (NOT proven; fails closed)"
done
rm -f "$FIX_JSON" "$FIX_OUT"
echo ""

echo "── _fingerprint_db_state() — three answers, not two (ga-gjfe78) ──"
# has proof / provably no proof / could not tell. Diagnostic only: decisions
# stay with _parse_fingerprint_to_file; this exists so a log line can say WHY
# there is no proof instead of just showing empty fields.
FIX_JSON="$(mktemp)"
cat > "$FIX_JSON" <<'JSON'
{
  "run_utc": "2026-09-16T07:08:53Z",
  "databases": {
    "good": {"issues": 1, "head": "h", "backup_size": "1M"},
    "goodexplicit": {"status": "ok", "backup_size": "1M"},
    "failedwithdate": {"status": "failed", "reason": "sync", "last_ok_run_utc": "2026-09-10T07:00:00Z", "last_ok": {"issues": 9, "head": "old", "backup_size": "1M"}},
    "failednull": {"status": "failed", "reason": "s3", "last_ok_run_utc": null, "last_ok": null},
    "failedbare": {"status": "failed"},
    "weird": {"status": "partial"},
    "notadict": "oops"
  }
}
JSON
_st() { _fingerprint_db_state "$FIX_JSON" "$1"; }
[ "$(_st good)" = "$(printf 'ok\t')" ] && ok "legacy entry → ok" || bad "legacy entry state wrong: '$(_st good)'"
[ "$(_st goodexplicit)" = "$(printf 'ok\t')" ] && ok "explicit status=ok → ok" || bad "explicit ok state wrong: '$(_st goodexplicit)'"
[ "$(_st failedwithdate)" = "$(printf 'failed\t2026-09-10T07:00:00Z')" ] && ok "failed entry → failed + the date of the last ok" || bad "failed+date state wrong: '$(_st failedwithdate)'"
[ "$(_st failednull)" = "$(printf 'failed\tunknown')" ] && ok "failed with last_ok_run_utc null → detail 'unknown' (null is NOT KNOWN — the writer never claims a db never had a good backup)" || bad "failed+null state wrong: '$(_st failednull)'"
[ "$(_st failedbare)" = "$(printf 'failed\tunknown')" ] && ok "failed with no last_ok fields at all → 'unknown'" || bad "failed bare state wrong: '$(_st failedbare)'"
[ "$(_st weird)" = "$(printf 'unrecognized\t')" ] && ok "unrecognized status → unrecognized" || bad "unrecognized status state wrong: '$(_st weird)'"
[ "$(_st notadict)" = "$(printf 'unrecognized\t')" ] && ok "entry that is not an object → unrecognized" || bad "non-object entry state wrong: '$(_st notadict)'"
[ "$(_st nosuchdb)" = "$(printf 'absent\t')" ] && ok "readable file, no entry for the db → absent" || bad "absent state wrong: '$(_st nosuchdb)'"
[ "$(_fingerprint_db_state /nonexistent/fp.json good)" = "$(printf 'unreadable\t')" ] && ok "unreadable file → unreadable (not 'absent')" || bad "unreadable-file state wrong"
echo '{ not json' > "$FIX_JSON"
[ "$(_st good)" = "$(printf 'unreadable\t')" ] && ok "malformed JSON → unreadable (not 'absent')" || bad "malformed-JSON state wrong: '$(_st good)'"
echo '["a list"]' > "$FIX_JSON"
[ "$(_st good)" = "$(printf 'unreadable\t')" ] && ok "top-level JSON that is not an object → unreadable" || bad "non-object top-level state wrong: '$(_st good)'"
echo '{"run_utc":"2026-09-16T07:08:53Z","databases":"x"}' > "$FIX_JSON"
[ "$(_st good)" = "$(printf 'unreadable\t')" ] && ok "databases that is not an object → unreadable" || bad "non-object databases state wrong: '$(_st good)'"
rm -f "$FIX_JSON"
echo ""

echo "── _reclaim_one_residue() — stubbed aws/notify, real rm against a throwaway fixture ──"
echo "   (dolt-s3-backup.sh's own _reseed_staging_if_enabled test uses this exact shape:"
echo "    fake binaries + a real function call, never the real AWS/notify.)"

STUB_DIR="$(mktemp -d)"
FIXTURE_ROOT="$(mktemp -d)"
NOTIFY_CALLS_FILE="$(mktemp)"
TEST_LOG="$(mktemp)"

cat > "$STUB_DIR/notify" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTIFY_CALLS_FILE"
exit 0
STUB
chmod +x "$STUB_DIR/notify"
export NOTIFY_CALLS_FILE

# aws stub: dispatches on the FIRST TWO words (mirrors dolt-s3-backup.selftest.sh's
# own aws stub shape). AWS_STUB_FETCH_MODE controls what "s3 cp .../latest.json"
# writes; AWS_STUB_HEAD_MODE controls whether "s3api head-object" succeeds.
cat > "$STUB_DIR/aws" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "s3 cp")
    dest="$4"
    case "${AWS_STUB_FETCH_MODE:-ok}" in
      ok)
        cat > "$dest" <<JSON
{"run_utc": "${AWS_STUB_RUN_UTC:-2026-09-16T07:08:53Z}", "databases": {"testdb": {"head": "stubhead1", "backup_size": "${AWS_STUB_BACKUP_SIZE:-1M}"}}}
JSON
        exit 0
        ;;
      fail) exit 1 ;;
      empty) : > "$dest"; exit 0 ;;
      failed)
        # what dolt-s3-backup.sh publishes for a db that failed tonight (ga-gjfe78)
        cat > "$dest" <<JSON
{"run_utc": "2026-09-16T07:08:53Z", "databases": {"testdb": {"status": "failed", "reason": "sync", "last_ok_run_utc": "2026-09-10T07:00:00Z", "last_ok": {"issues": 9, "head": "stubhead1", "backup_size": "1M"}}}}
JSON
        exit 0
        ;;
      failed-proofkeys)
        # hazardous variant: marked failed BUT still carrying every key a
        # pre-ga-gjfe78 reader treats as proof. Must still be NOT proof.
        cat > "$dest" <<JSON
{"run_utc": "2026-09-16T07:08:53Z", "databases": {"testdb": {"status": "failed", "run_utc": "2026-09-16T07:08:53Z", "head": "stubhead1", "backup_size": "1M"}}}
JSON
        exit 0
        ;;
    esac
    ;;
  "s3api head-object")
    [ "${AWS_STUB_HEAD_MODE:-ok}" = "ok" ] && exit 0 || exit 1
    ;;
  *)
    echo "unhandled aws stub invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_DIR/aws"

# _mk_fixture <settle_secs_override> — (re)creates FIXTURE_ROOT/testdb (the
# "live" current backup, sized so ok-mode's default 1M fingerprint is
# comfortably >= 50% of it) and FIXTURE_ROOT/testdb.old (the residue,
# mtime forced safely in the past so the default 7200s settle window is
# already cleared unless a scenario overrides SETTLE_SECS upward itself).
_mk_fixture() {
  rm -rf "${FIXTURE_ROOT:?}/testdb" "${FIXTURE_ROOT:?}/testdb.old"
  mkdir -p "$FIXTURE_ROOT/testdb" "$FIXTURE_ROOT/testdb.old"
  # ~900K of real content in each — comfortably coherent against a 1M fingerprint at the 50% floor.
  dd if=/dev/zero of="$FIXTURE_ROOT/testdb/data.bin" bs=1024 count=900 >/dev/null 2>&1
  dd if=/dev/zero of="$FIXTURE_ROOT/testdb.old/data.bin" bs=1024 count=900 >/dev/null 2>&1
  touch -t 202601010000 "$FIXTURE_ROOT/testdb.old"
}

# NOTE: this file sources dolt-backup-residue-reclaim.sh ONCE, at the top, as
# a library. Every DOLT_BACKUP_RESIDUE_RECLAIM_* env var is read exactly once
# at THAT source time to resolve a plain variable (e.g. BACKUP_ROOT, AWS,
# SETTLE_SECS) — calling a function afterward with a
# DOLT_BACKUP_RESIDUE_RECLAIM_*=... prefix does nothing, because the function
# body reads the already-resolved plain variable, not the env var again. To
# override behavior for one call, prefix the RESOLVED variable name itself
# (BACKUP_ROOT=, SETTLE_SECS=, DRY_RUN=, PROD=, AWS=, NOTIFY=, LOG=) — bash
# gives a function call this exact "temporary environment" semantics for the
# duration of that one call, then reverts it. This is the same idiom dolt-s3-
# backup.selftest.sh's own `AWS="$AWS_STUB_DIR/aws" ... jsonl_offsite_sync`
# and `RESEED_SCRIPT="..." ... _reseed_staging_if_enabled "testdb"` calls rely
# on for the exact same reason.
_run_reclaim() {
  AWS="$STUB_DIR/aws" NOTIFY="$STUB_DIR/notify" LOG="$TEST_LOG" \
  BACKUP_ROOT="$FIXTURE_ROOT" \
  SETTLE_SECS="${TEST_SETTLE_SECS:-7200}" \
  DRY_RUN="${TEST_DRY_RUN:-0}" \
  PROD="${TEST_PROD:-0}" \
    _reclaim_one_residue "$FIXTURE_ROOT/testdb.old"
}

# Scenario A: everything checks out, root is overridden (not the real
# default) with DRY_RUN=0 → real deletion fires against the safe fixture.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=ok AWS_STUB_HEAD_MODE=ok _run_reclaim
[ ! -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario A (all checks pass): residue actually DELETED" || bad "scenario A: residue should have been deleted"
grep -qF "VERIFIED SAFE" "$TEST_LOG" && ok "scenario A: logged VERIFIED SAFE with the proof" || bad "scenario A: missing VERIFIED SAFE log line"
grep -qF "DELETED" "$TEST_LOG" && ok "scenario A: logged DELETED" || bad "scenario A: missing DELETED log line"
[ -s "$NOTIFY_CALLS_FILE" ] && bad "scenario A: notify_fail should NOT fire when everything is verified safe" || ok "scenario A: notify correctly not called"

# Scenario B (Mayor's ACEITE #6 — MANDATORY): the manifest HEAD probe FAILS
# (simulates the S3 verify failing). Prove nothing is deleted.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=ok AWS_STUB_HEAD_MODE=fail _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario B (S3 manifest verify FAILS): residue STILL PRESENT — nothing deleted" || bad "scenario B: FAIL-CLOSED VIOLATED — residue was deleted despite a failed S3 verify"
grep -qF "SPARED" "$TEST_LOG" && ok "scenario B: logged SPARED" || bad "scenario B: missing SPARED log line"
[ -s "$NOTIFY_CALLS_FILE" ] && ok "scenario B: notify_fail correctly fired (real verification gap, not a settle-window miss)" || bad "scenario B: notify_fail should have fired when the manifest probe fails"

# Scenario C: the S3 fetch call itself fails outright (network blip, bucket
# unreachable) — same fail-closed requirement as scenario B, different cause.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=fail AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario C (S3 fetch fails outright): residue STILL PRESENT" || bad "scenario C: FAIL-CLOSED VIOLATED — residue deleted despite an unreachable S3 fingerprint"
[ -s "$NOTIFY_CALLS_FILE" ] && ok "scenario C: notify_fail fired (no fingerprint at all is a real gap, not a settle-window miss)" || bad "scenario C: notify_fail should have fired"

# Scenario D: fingerprint fetch succeeds but is EMPTY/unparseable (e.g. a
# truncated download) — must behave the same as an outright fetch failure.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=empty AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario D (empty/truncated fingerprint): residue STILL PRESENT" || bad "scenario D: FAIL-CLOSED VIOLATED — residue deleted despite an empty fingerprint fetch"

# Scenario E: fingerprint run_utc is OLDER than the residue's own mtime — the
# replacement backup has not yet been S3-synced since the swap. Expected,
# self-healing (retried next cycle): must NOT delete, and must NOT notify_fail
# (this is not an error, unlike scenarios B/C/D).
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=ok AWS_STUB_RUN_UTC="2020-01-01T00:00:00Z" AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario E (fingerprint older than residue): residue STILL PRESENT" || bad "scenario E: residue deleted despite a stale (pre-swap) fingerprint"
grep -qF "expected, self-healing" "$TEST_LOG" && ok "scenario E: logged as expected/self-healing, not an alarm" || bad "scenario E: should log the expected/self-healing framing"
[ -s "$NOTIFY_CALLS_FILE" ] && bad "scenario E: notify_fail should NOT fire for an expected settle/freshness miss" || ok "scenario E: notify correctly not called (this is not an error)"

# Scenario F: size incoherent — fingerprint reports a suspiciously tiny size
# next to what is actually on disk.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=ok AWS_STUB_BACKUP_SIZE="1K" AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario F (size incoherent): residue STILL PRESENT" || bad "scenario F: FAIL-CLOSED VIOLATED — residue deleted despite an incoherent size"
[ -s "$NOTIFY_CALLS_FILE" ] && ok "scenario F: notify_fail fired (size incoherence is a real gap)" || bad "scenario F: notify_fail should have fired"

# Scenario G: settle window not yet cleared (residue too fresh) — expected,
# self-healing, no notify, even though S3 verify would otherwise pass.
_mk_fixture
touch "$FIXTURE_ROOT/testdb.old"   # mtime = now
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
TEST_SETTLE_SECS=999999 AWS_STUB_FETCH_MODE=ok AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario G (settle window not cleared): residue STILL PRESENT" || bad "scenario G: residue deleted before its settle window cleared"
[ -s "$NOTIFY_CALLS_FILE" ] && bad "scenario G: notify_fail should NOT fire for an unelapsed settle window" || ok "scenario G: notify correctly not called"

# Scenario H: DRY_RUN=1 override — even with every check passing, nothing is
# deleted, and the log says so.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
TEST_DRY_RUN=1 AWS_STUB_FETCH_MODE=ok AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario H (DRY_RUN=1): residue STILL PRESENT" || bad "scenario H: DRY_RUN=1 should never delete"
grep -qF "DRY-RUN" "$TEST_LOG" && ok "scenario H: logged DRY-RUN" || bad "scenario H: missing DRY-RUN log line"

# Scenario I: production sentinel — BACKUP_ROOT resolves to the REAL default
# (simulated by pointing BACKUP_ROOT_REAL_DEFAULT at the SAME fixture root,
# never the actual production path) with no PROD opt-in: must force dry-run
# even though every check would otherwise pass. Overrides the resolved
# variables directly (see _run_reclaim's own note above) rather than
# re-sourcing in a subshell — simpler, and exercises the identical
# _prod_sentinel_active call _reclaim_one_residue makes internally.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS="$STUB_DIR/aws" NOTIFY="$STUB_DIR/notify" LOG="$TEST_LOG" \
BACKUP_ROOT="$FIXTURE_ROOT" BACKUP_ROOT_REAL_DEFAULT="$FIXTURE_ROOT" \
SETTLE_SECS=7200 DRY_RUN=0 PROD=0 \
AWS_STUB_FETCH_MODE=ok AWS_STUB_HEAD_MODE=ok \
  _reclaim_one_residue "$FIXTURE_ROOT/testdb.old"
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario I (PROD sentinel, root==real default, no opt-in): residue STILL PRESENT" || bad "scenario I: PROD SENTINEL VIOLATED — deleted the 'default-rooted' fixture without PROD=1"
grep -qF "DRY-RUN" "$TEST_LOG" && ok "scenario I: logged DRY-RUN (sentinel forced it)" || bad "scenario I: missing DRY-RUN log line for the sentinel case"

# Scenario J: same as I, but WITH the production opt-in — deletion proceeds.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS="$STUB_DIR/aws" NOTIFY="$STUB_DIR/notify" LOG="$TEST_LOG" \
BACKUP_ROOT="$FIXTURE_ROOT" BACKUP_ROOT_REAL_DEFAULT="$FIXTURE_ROOT" \
SETTLE_SECS=7200 DRY_RUN=0 PROD=1 \
AWS_STUB_FETCH_MODE=ok AWS_STUB_HEAD_MODE=ok \
  _reclaim_one_residue "$FIXTURE_ROOT/testdb.old"
[ ! -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario J (PROD=1 opt-in at real-default root): residue DELETED" || bad "scenario J: PROD=1 opt-in should have authorized deletion"

# Scenario K (ga-gjfe78): the published fingerprint marks THIS db as FAILED
# (the shape dolt-s3-backup.sh now writes). Manifest present, size fine, settle
# window cleared — everything except the fingerprint would allow deletion. A
# failed db has no proof that the S3 copy is current, so the residue must stay,
# it must alarm (a real gap, not a settle miss), and the log must say WHY.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=failed AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario K (fingerprint marks the db FAILED): residue STILL PRESENT — a failed entry is not proof" || bad "scenario K: FAIL-CLOSED VIOLATED — residue deleted on the strength of a FAILED fingerprint entry"
grep -qF "fingerprint_state=failed" "$TEST_LOG" && ok "scenario K: log names the reason (fingerprint_state=failed)" || bad "scenario K: log does not say the fingerprint marks the db failed"
grep -qF "last_ok=2026-09-10T07:00:00Z" "$TEST_LOG" && ok "scenario K: log carries the date of the last good backup" || bad "scenario K: log does not carry the last-ok date"
[ -s "$NOTIFY_CALLS_FILE" ] && ok "scenario K: notify_fail fired (real gap, not an expected settle miss)" || bad "scenario K: notify_fail should have fired for a failed fingerprint entry"
grep -qF "expected, self-healing" "$TEST_LOG" && bad "scenario K: a FAILED entry must not be logged as an expected/self-healing settle miss" || ok "scenario K: not mislabeled as expected/self-healing"

# Scenario L (ga-gjfe78): the hazardous variant — status:failed but with
# run_utc, head and backup_size still present (exactly what an old reader takes
# as a fresh, coherent proof). Before the fix this deleted the residue.
_mk_fixture
: > "$NOTIFY_CALLS_FILE"; : > "$TEST_LOG"
AWS_STUB_FETCH_MODE=failed-proofkeys AWS_STUB_HEAD_MODE=ok _run_reclaim
[ -e "$FIXTURE_ROOT/testdb.old" ] && ok "scenario L (failed entry that still carries proof-looking keys): residue STILL PRESENT" || bad "scenario L: FAIL-CLOSED VIOLATED — a status:failed entry with run_utc/backup_size was read as fresh proof and the residue was deleted"
[ -s "$NOTIFY_CALLS_FILE" ] && ok "scenario L: notify_fail fired" || bad "scenario L: notify_fail should have fired"

rm -f "$NOTIFY_CALLS_FILE" "$TEST_LOG" 2>/dev/null || true
unset NOTIFY_CALLS_FILE

echo ""
echo "── _reap_backup_residue() — path-safety guard, no candidates, missing root ──"

# STUB_DIR/aws is still alive here (cleaned up at the very end of this file) —
# _reap_backup_residue's own "aws CLI not found" precondition check needs a
# real, executable path to pass before it can reach the sweep logic below.
EMPTY_ROOT="$(mktemp -d)"
NO_CANDIDATES_LOG="$(mktemp)"
BACKUP_ROOT="$EMPTY_ROOT" LOG="$NO_CANDIDATES_LOG" AWS="$STUB_DIR/aws" _reap_backup_residue 2>/dev/null
grep -qF "no *.old residue" "$NO_CANDIDATES_LOG" && ok "no .old candidates → clean no-op log line" || bad "expected a 'no *.old residue' log line for an empty root"
rm -rf "$EMPTY_ROOT"; rm -f "$NO_CANDIDATES_LOG"

MISSING_LOG="$(mktemp)"
BACKUP_ROOT="/definitely/does/not/exist/$$" LOG="$MISSING_LOG" _reap_backup_residue
grep -qF "not found" "$MISSING_LOG" && ok "missing BACKUP_ROOT → SKIP logged, no crash" || bad "expected a 'not found' SKIP log line for a missing root"
rm -f "$MISSING_LOG"

echo ""
echo "── ENABLED=0 kill switch ──"
KILL_LOG="$(mktemp)"
ENABLED=0 LOG="$KILL_LOG" _reap_backup_residue
grep -qF "ENABLED=0" "$KILL_LOG" && ok "ENABLED=0 → skips entirely, logs why" || bad "expected an ENABLED=0 SKIP log line"
rm -f "$KILL_LOG"

rm -rf "$STUB_DIR" "$FIXTURE_ROOT" 2>/dev/null || true

echo ""
echo "── drift-guard: wiring present in the live script ──"
if grep -qF '_should_release_residue "$old_mtime" "$now" "$SETTLE_SECS"' "$SCRIPT"; then
  ok "_reclaim_one_residue actually calls _should_release_residue (wiring is live, not dead code)"
else
  bad "_should_release_residue wiring missing from _reclaim_one_residue"
fi
if grep -qF '_fingerprint_db_state "$fp_file" "$db"' "$SCRIPT"; then
  ok "_reclaim_one_residue asks _fingerprint_db_state why there is no proof (ga-gjfe78 wiring is live, not dead code)"
else
  bad "_fingerprint_db_state is not wired into _reclaim_one_residue — the failed-entry reason never reaches the log"
fi
if grep -qF '"$BACKUP_ROOT"/*.old)' "$SCRIPT"; then
  ok "the real rm -rf is guarded by a \$BACKUP_ROOT/*.old path-safety case"
else
  bad "path-safety guard on the real rm -rf is missing"
fi
if grep -qF 'for dir in "$BACKUP_ROOT"/*.old; do' "$SCRIPT"; then
  ok "the sweep only ever globs \$BACKUP_ROOT/*.old (never .beads/dolt, never live staging, never ballast)"
else
  bad "sweep glob shape changed or missing — re-verify scope safety"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
