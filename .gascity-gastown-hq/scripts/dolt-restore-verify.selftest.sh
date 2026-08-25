#!/bin/bash
# dolt-restore-verify.selftest.sh — unit + orchestration tests for
# dolt-restore-verify.sh (ga-jz7gg, scope items 3+4).
#
# Hermetic: sources the script as a LIBRARY (RESTORE_VERIFY_LIB=1), so main()
# never runs. DOLT_BIN/GC_BIN/BD_BIN point at fake, scratch-local binaries —
# the real dolt CLI, real bd, and real gc are NEVER invoked. All paths
# (DOLTDIR, BACKUP_ROOT, LOG) point at a throwaway scratch dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-restore-verify.sh"

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export RESTORE_VERIFY_LIB=1
export RESTORE_VERIFY_LOG="$SCRATCH/restore-verify.log"
# shellcheck disable=SC1090
. "$SCRIPT"

DOLTDIR="$SCRATCH/city/doltdir"
BACKUP_ROOT="$SCRATCH/city/backup"

GC_BIN="$SCRATCH/fake-gc.sh"
cat > "$GC_BIN" <<'EOF'
#!/bin/bash
echo "GC-CALLED $*" >> "${FAKE_GC_LOG:-/dev/null}"
if [ "$3" = "SELECT COUNT(*) FROM \`${FAKE_LIVE_DB:-nonexistent}\`.issues" ]; then :; fi
echo "${FAKE_GC_SQL_OUTPUT:-}"
exit "${FAKE_GC_EXIT:-0}"
EOF
chmod +x "$GC_BIN"

DOLT_BIN="$SCRATCH/fake-dolt.sh"
cat > "$DOLT_BIN" <<'EOF'
#!/bin/bash
echo "DOLT-CALLED $*" >> "${FAKE_DOLT_LOG:-/dev/null}"
if [ "$1" = "backup" ] && [ "$2" = "restore" ]; then
  [ "${FAKE_DOLT_RESTORE_FAIL:-0}" = "1" ] && exit 1
  mkdir -p "$4" 2>/dev/null
  exit 0
fi
if [ "$1" = "sql" ]; then
  echo "${FAKE_DOLT_SQL_OUTPUT:-}"
  exit 0
fi
exit 0
EOF
chmod +x "$DOLT_BIN"

BD_BIN="$SCRATCH/fake-bd.sh"
cat > "$BD_BIN" <<'EOF'
#!/bin/bash
echo "BD-CALLED $*" >> "${FAKE_BD_LOG:-/dev/null}"
case "$1" in
  -C) shift 2 ;;
esac
case "$1" in
  create) echo "${FAKE_BD_NEW_ID:-fake-bead-1}" ;;
  close)  ;;
esac
exit 0
EOF
chmod +x "$BD_BIN"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-restore-verify.selftest.sh ==="

# ════════════════════════════════════════════════════════════════════════════
# 1. Pure functions
# ════════════════════════════════════════════════════════════════════════════
echo "── _avail_gb (real filesystem — /System/Volumes/Data must exist on macOS CI) ──"
AVAIL="$(_avail_gb)"
case "$AVAIL" in
  ''|*[!0-9]*) bad "expected a numeric GB value, got '$AVAIL'" ;;
  *) ok "real avail GB is numeric ($AVAIL)" ;;
esac

echo "── _need_gb <live_kb> <margin_pct> ──"
[ "$(_need_gb 1048576 200 2>/dev/null)" = "3" ] && ok "1GB live at 200% margin -> 3GB needed (2x + 1 rounding floor)" || bad "expected 3, got '$(_need_gb 1048576 200)'"
[ -z "$(_need_gb '' 200 2>/dev/null)" ] && ok "empty live_kb -> empty (fail-closed, not silently 0)" || bad "empty live_kb should produce empty"
[ -z "$(_need_gb abc 200 2>/dev/null)" ] && ok "non-numeric live_kb -> empty" || bad "non-numeric live_kb should produce empty"
[ -z "$(_need_gb 1048576 '' 2>/dev/null)" ] && ok "empty margin_pct -> empty" || bad "empty margin_pct should produce empty"

echo "── _headroom_ok <avail_gb> <need_gb> ──"
_headroom_ok 10 5 && ok "10 >= 5 -> ok" || bad "10 vs 5 should pass"
_headroom_ok 4 5 && bad "4 < 5 should fail" || ok "4 < 5 -> refuse"
_headroom_ok 5 5 && ok "boundary: exactly equal -> ok (>=, not >)" || bad "boundary 5==5 should pass"
_headroom_ok '' 5 && bad "empty avail should fail-closed" || ok "empty avail -> refuse"
_headroom_ok 10 '' && bad "empty need should fail-closed" || ok "empty need -> refuse"
_headroom_ok abc 5 && bad "non-numeric avail should fail-closed" || ok "non-numeric avail -> refuse"

echo "── _discover_dbs <backup_root> ──"
mkdir -p "$SCRATCH/discover/hq" "$SCRATCH/discover/gastown" "$SCRATCH/discover/hq.new" "$SCRATCH/discover/lexbh.old"
FOUND="$(_discover_dbs "$SCRATCH/discover" | sort | tr '\n' ',' )"
[ "$FOUND" = "gastown,hq," ] && ok "discovers real dbs, excludes .new/.old in-progress reseed artifacts" || bad "expected 'gastown,hq,', got '$FOUND'"
[ -z "$(_discover_dbs "$SCRATCH/does-not-exist")" ] && ok "missing backup root -> empty, not an error" || bad "missing root should produce empty"

# ════════════════════════════════════════════════════════════════════════════
# 2. _verify_one_db — one db's full restore+compare cycle
# ════════════════════════════════════════════════════════════════════════════
_reset_fixture() {
  rm -rf "$DOLTDIR" "$BACKUP_ROOT"
  mkdir -p "$DOLTDIR/hq" "$BACKUP_ROOT/hq"
  : > "$RESTORE_VERIFY_LOG"
  unset FAKE_DOLT_SQL_OUTPUT FAKE_GC_SQL_OUTPUT FAKE_DOLT_RESTORE_FAIL
}

echo "── _verify_one_db: no live db -> SKIP, never touches dolt/backup ──"
_reset_fixture
rm -rf "$DOLTDIR/hq"
OUT="$(_verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=SKIP(sem-banco-vivo)" ] && ok "missing live db correctly reported as SKIP" || bad "expected 'hq=SKIP(sem-banco-vivo)', got '$OUT'"
[ "$RC" -eq 0 ] && ok "SKIP is not a failure exit code" || bad "SKIP should exit 0"

echo "── _verify_one_db: no backup -> SKIP ──"
_reset_fixture
rm -rf "$BACKUP_ROOT/hq"
OUT="$(_verify_one_db hq)"
[ "$OUT" = "hq=SKIP(sem-backup)" ] && ok "missing backup correctly reported as SKIP" || bad "expected 'hq=SKIP(sem-backup)', got '$OUT'"

echo "── _verify_one_db: live query fails -> SKIP(sem-baseline), never attempts restore ──"
_reset_fixture
: > "$SCRATCH/fake-dolt.log"
OUT="$(FAKE_GC_SQL_OUTPUT="" FAKE_DOLT_LOG="$SCRATCH/fake-dolt.log" _verify_one_db hq)"
[ "$OUT" = "hq=SKIP(sem-baseline)" ] && ok "unreadable live count -> SKIP(sem-baseline)" || bad "expected 'hq=SKIP(sem-baseline)', got '$OUT'"
[ ! -s "$SCRATCH/fake-dolt.log" ] && ok "no baseline means no restore attempt at all (nothing to compare against)" || bad "should never call dolt when there's no baseline"

echo "── _verify_one_db: disk insufficient -> SKIP(disco), never attempts restore ──"
_reset_fixture
: > "$SCRATCH/fake-dolt.log"
# Shadow _avail_gb, but SAVE+RESTORE the real definition via declare -f —
# `unset -f` alone would delete it permanently and break every later test
# that calls it (caught live writing this test: it did exactly that).
_avail_gb_REAL="$(declare -f _avail_gb)"
# 0, not 1: the fixture's near-empty DOLTDIR/hq rounds up to need_gb=1 (the
# "+1" floor in _need_gb), so an avail of 1 is >= need — genuinely
# sufficient, not insufficient (caught live: this exact off-by-one let the
# test fall through to a real restore attempt instead of skipping).
_avail_gb() { echo 0; }   # pretend NO disk free at all
OUT="$(FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_LOG="$SCRATCH/fake-dolt.log" _verify_one_db hq)"
case "$OUT" in
  hq=SKIP\(disco:*) ok "insufficient disk correctly reported as SKIP(disco:...)" ;;
  *) bad "expected 'hq=SKIP(disco:...)', got '$OUT'" ;;
esac
[ ! -s "$SCRATCH/fake-dolt.log" ] && ok "insufficient disk means no restore attempt (this IS the 25/08 lesson — check BEFORE, not after)" || bad "should never call dolt restore without headroom"
eval "$_avail_gb_REAL"   # restore the real one sourced from the script

echo "── _verify_one_db: backup does not restore -> FAIL ──"
_reset_fixture
OUT="$(FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_RESTORE_FAIL=1 _verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=FAIL(nao-restaura-ou-sem-leitura)" ] && ok "a backup that fails to restore is FAIL, not silently skipped" || bad "expected FAIL, got '$OUT'"
[ "$RC" -ne 0 ] && ok "FAIL propagates a nonzero exit" || bad "FAIL should exit nonzero"

echo "── _verify_one_db: restored count regressed below live -> FAIL ──"
_reset_fixture
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_DOLT_SQL_OUTPUT='| 499' _verify_one_db hq)"
[ "$OUT" = "hq=FAIL(restaurado:499<vivo:500)" ] && ok "restored < live is FAIL and names both counts" || bad "expected 'hq=FAIL(restaurado:499<vivo:500)', got '$OUT'"

echo "── _verify_one_db: happy path -> OK ──"
_reset_fixture
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_DOLT_SQL_OUTPUT='| 500' _verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=OK(500)" ] && ok "clean restore >= live is OK and names the restored count" || bad "expected 'hq=OK(500)', got '$OUT'"
[ "$RC" -eq 0 ] && ok "OK exits 0" || bad "OK should exit 0"

echo "── _verify_one_db: restored count GREW during verification -> still OK (>=, not ==) ──"
_reset_fixture
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_DOLT_SQL_OUTPUT='| 503' _verify_one_db hq)"
[ "$OUT" = "hq=OK(503)" ] && ok "the city writes continuously — restored > live (not just ==) is still OK, same rule as dolt-backup-reseed.sh" || bad "expected 'hq=OK(503)', got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
# 3. _file_summary_bead
# ════════════════════════════════════════════════════════════════════════════
echo "── _file_summary_bead: clean run files a chore and closes it ──"
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" _file_summary_bead "hq=OK(500) " 0
grep -q "BD-CALLED.*create.*--type=chore" "$SCRATCH/fake-bd.log" && ok "clean run files a --type=chore bead" || bad "expected a chore create call: $(cat "$SCRATCH/fake-bd.log")"
grep -q "BD-CALLED.*close" "$SCRATCH/fake-bd.log" && ok "clean run closes the bead immediately (pure record, matches the digest's own Incidents convention)" || bad "expected a close call"

echo "── _file_summary_bead: a failing run files an OPEN bug, routed to gastown.dog ──"
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" _file_summary_bead "hq=FAIL(nao-restaura-ou-sem-leitura) " 1
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "a failure files a --type=bug (actionable, not a silent record)" || bad "expected a bug create call: $(cat "$SCRATCH/fake-bd.log")"
grep -q "gastown.dog" "$SCRATCH/fake-bd.log" && ok "failure is routed to gastown.dog via gc.routed_to metadata" || bad "expected gc.routed_to routing metadata"
grep -q "BD-CALLED.*close" "$SCRATCH/fake-bd.log" && bad "a failed run must NOT close its own bead — it needs to stay open and actionable" || ok "failure bead is left open (no close call)"

# ════════════════════════════════════════════════════════════════════════════
# 4. main() orchestration
# ════════════════════════════════════════════════════════════════════════════
echo "── main: loops over every discovered db, aggregates results, files ONE summary bead ──"
rm -rf "$SCRATCH/city2"
DOLTDIR="$SCRATCH/city2/doltdir"; BACKUP_ROOT="$SCRATCH/city2/backup"
mkdir -p "$DOLTDIR/alpha" "$DOLTDIR/beta" "$BACKUP_ROOT/alpha" "$BACKUP_ROOT/beta"
: > "$SCRATCH/fake-bd.log"; : > "$RESTORE_VERIFY_LOG"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && ok "all-OK run exits 0" || bad "expected exit 0 when every db is OK, got $RC"
grep -q "alpha=OK" "$SCRATCH/fake-bd.log" && grep -q "beta=OK" "$SCRATCH/fake-bd.log" && ok "summary bead body names BOTH dbs' results" || bad "expected both alpha and beta in the summary: $(cat "$SCRATCH/fake-bd.log")"
[ "$(grep -c 'BD-CALLED.*create' "$SCRATCH/fake-bd.log")" = "1" ] && ok "exactly ONE summary bead filed per run, not one per db (avoids bead spam)" || bad "expected exactly 1 create call"

echo "── main: one db failing makes the WHOLE run report failure (aggregation), while the other db's result still appears ──"
: > "$SCRATCH/fake-bd.log"; : > "$RESTORE_VERIFY_LOG"
FAKE_GC_SQL_OUTPUT='| 500' FAKE_DOLT_SQL_OUTPUT='| 499' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -ne 0 ] && ok "any single db FAIL makes the aggregate exit nonzero" || bad "expected nonzero exit when a db regressed"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "aggregate failure files the bug-type summary" || bad "expected a bug-type summary bead"

echo "── main: empty backup root -> clean no-op, no bead filed ──"
rm -rf "$SCRATCH/city3"; DOLTDIR="$SCRATCH/city3/doltdir"; BACKUP_ROOT="$SCRATCH/city3/backup"
mkdir -p "$DOLTDIR" "$BACKUP_ROOT"
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && ok "nothing to verify -> clean exit 0" || bad "empty backup root should not be treated as failure"
[ ! -s "$SCRATCH/fake-bd.log" ] && ok "nothing to verify -> no summary bead filed (no fabricated record for a no-op)" || bad "should not file a bead when there was nothing to check"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
