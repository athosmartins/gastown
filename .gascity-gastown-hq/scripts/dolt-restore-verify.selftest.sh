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
  create)
    [ "${FAKE_BD_CREATE_FAIL:-0}" = "1" ] && exit 1
    echo "${FAKE_BD_NEW_ID:-fake-bead-1}"
    ;;
  close)  ;;
esac
exit 0
EOF
chmod +x "$BD_BIN"

NOTIFY="$SCRATCH/fake-notify.sh"
cat > "$NOTIFY" <<'EOF'
#!/bin/bash
echo "NOTIFY-CALLED $*" >> "${FAKE_NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$NOTIFY"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-restore-verify.selftest.sh ==="

# ════════════════════════════════════════════════════════════════════════════
# 0. Environment export (ga-ymsl0 regression)
# ════════════════════════════════════════════════════════════════════════════
echo "── GC_CITY_PATH is exported so a child 'gc dolt sql' can discover the city ──"
# Root cause (live, 2026-09-03): the hq one-shot verify runs under launchd
# with no WorkingDirectory set, so CWD-based city auto-discovery fails and
# gc's "dolt" pack-subcommand never registers — "gc dolt sql -q ..." then
# fails in under a second, live_count comes back empty, and the run reports
# SKIP(sem-baseline) even though Dolt itself is healthy. Exporting
# GC_CITY_PATH (not just setting the local CITY var) fixes it regardless of
# the caller's CWD. This is a hermetic sourcing-time check — FAKE_GC_BIN
# doesn't care about env vars either way, so it can't mask a regression here.
[ "$GC_CITY_PATH" = "$CITY" ] && ok "GC_CITY_PATH exported to match CITY, so child 'gc' invocations can discover the city with no CWD dependency" || bad "expected GC_CITY_PATH='$CITY', got '${GC_CITY_PATH:-<unset>}'"

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
# Gate-caught (ga-jz7gg fix-attempt 1): a live db UNDER 1GB used to truncate
# to 0 before margin_pct was ever applied, flooring need_gb to a flat 1
# regardless of margin. 806912 KB (~788MB) is whatsapp_automation's real
# size per this city's own docs -- a size class that actually exists in
# production, not a synthetic edge case.
[ "$(_need_gb 806912 200 2>/dev/null)" = "2" ] && ok "788MB live (real prod size, sub-1GB) at 200% margin -> 2GB needed, not floored to 1 by early truncation" || bad "expected 2, got '$(_need_gb 806912 200)'"
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

echo "── _file_summary_bead: an all-SKIP run (nothing verified) files an OPEN bug, distinct from OK ──"
# Gate-caught (ga-jz7gg fix-attempt 1): overall_rc=2 means every db SKIPped —
# e.g. dolt unreachable, or disk tight city-wide. This must NOT be filed
# identically to a genuine overall_rc=0 (at least one real verification) —
# that would record "checked, all clean" for a run that checked nothing.
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" _file_summary_bead "hq=SKIP(sem-baseline) " 2
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "an all-SKIP run files a --type=bug (not silently recorded as clean)" || bad "expected a bug create call: $(cat "$SCRATCH/fake-bd.log")"
grep -q "gastown.dog" "$SCRATCH/fake-bd.log" && ok "all-SKIP run is routed to gastown.dog like a real failure" || bad "expected gc.routed_to routing metadata"
grep -q "BD-CALLED.*close" "$SCRATCH/fake-bd.log" && bad "an all-SKIP run must NOT close its own bead — nothing was actually verified" || ok "all-SKIP bead is left open (no close call)"
grep -q "SEM VERIFICACAO" "$SCRATCH/fake-bd.log" && ok "title is textually distinct from the OK case, not just same-title-different-type" || bad "expected a distinguishing title for the all-SKIP case"

echo "── _file_summary_bead: bd itself is unreachable — the summary bead-create call fails ──"
# Self-audit finding (ga-jz7gg /gate-done pre-flight sweep): the summary bead
# IS the only channel the digest reads (mol-digest-generate.toml's
# restore-verify section queries beads, not this log file). If bd is down
# specifically at THIS step, a log-only warning is invisible to anything
# that isn't tailing this exact file — an independent channel (notify, which
# doesn't depend on bd/Dolt at all) must also fire, or a real integrity
# result silently never reaches anyone.
: > "$SCRATCH/fake-notify.log"; : > "$RESTORE_VERIFY_LOG"
FAKE_BD_CREATE_FAIL=1 FAKE_NOTIFY_LOG="$SCRATCH/fake-notify.log" _file_summary_bead "hq=OK(500) " 0
grep -q "NOTIFY-CALLED" "$SCRATCH/fake-notify.log" && ok "bd being unreachable for the summary bead fires an independent notify (not just a log line nobody watches)" || bad "expected a notify call when bd create fails: $(cat "$SCRATCH/fake-notify.log" 2>/dev/null)"
grep -q "restore-verify" "$RESTORE_VERIFY_LOG" && ok "the failure is still recorded in the log too (belt and suspenders, not notify-only)" || bad "expected the failure logged to $RESTORE_VERIFY_LOG as well"

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

echo "── main: every db legitimately SKIPs -> overall_rc=2, distinct from OK(0) and FAIL(1) ──"
# Gate-caught (ga-jz7gg fix-attempt 1): reuses city2's alpha/beta (both have
# live+backup dirs from the block above), but with no FAKE_GC_SQL_OUTPUT ->
# live_count is unreadable for both -> both legitimately SKIP(sem-baseline).
# Before the fix, main() only ever set overall_rc on a FAIL, so this exact
# shape (every db SKIP, zero FAIL) silently exited 0 and filed a "clean" bead.
: > "$SCRATCH/fake-bd.log"; : > "$RESTORE_VERIFY_LOG"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 2 ] && ok "all-SKIP run exits 2, distinct from both OK(0) and FAIL(1)" || bad "expected exit 2 when every db SKIPs, got $RC"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "main's all-SKIP run files the bug-type summary, not a clean chore" || bad "expected a bug-type summary bead for an all-SKIP main() run: $(cat "$SCRATCH/fake-bd.log")"

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
