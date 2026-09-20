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
# The snapshot-baseline query (ga-jsk5p8) is told apart by its SUM(created_at
# ...) so a test can feed it a two-column row while the plain COUNT(*) baseline
# keeps its own one-column output.
case "$*" in
  *"SUM(created_at"*) echo "${FAKE_GC_SQL2_OUTPUT:-}" ;;
  *) echo "${FAKE_GC_SQL_OUTPUT:-}" ;;
esac
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
echo "── GC_CITY_PATH is exported (not just a local var) so a child 'gc dolt sql' inherits it ──"
# Root cause (live, 2026-09-03): the hq one-shot verify runs under launchd
# with no WorkingDirectory set, so CWD-based city auto-discovery fails and
# gc's "dolt" pack-subcommand never registers — "gc dolt sql -q ..." then
# fails in under a second, live_count comes back empty, and the run reports
# SKIP(sem-baseline) even though Dolt itself is healthy.
#
# Testing this needs care: this dog agent's OWN shell (and therefore this
# selftest's shell) already has GC_CITY_PATH exported globally via `gc
# prime`. A same-shell check like `[ "$GC_CITY_PATH" = "$CITY" ]` would pass
# even against the UNFIXED script, because CITY is merely READ from an
# already-exported GC_CITY_PATH — the assignment on its own proves nothing
# about whether the script re-exports it for a CHILD process. Only a real
# process boundary distinguishes "exported" from "local var with the same
# value" — which is exactly the boundary the real "gc dolt sql" call
# crosses. So: start a subshell with GC_CITY_PATH genuinely UNSET (env -u,
# not just unset — inheritance from a launchd-style clean environment, not
# from this shell), source the script there, and inspect the export
# attribute directly via `declare -p`. Against the unfixed script,
# GC_CITY_PATH is never touched at all in that subshell, so `declare -p`
# fails to find it (empty output) and the assertion below correctly fails —
# proving this test does exercise the fix, not just its own shell's
# inherited state.
EXPORT_CHECK="$(env -u GC_CITY_PATH RESTORE_VERIFY_LIB=1 bash -c ". '$SCRIPT'; declare -p GC_CITY_PATH 2>/dev/null")"
case "$EXPORT_CHECK" in
  "declare -x GC_CITY_PATH="*) ok "GC_CITY_PATH is exported after sourcing, even starting from a subshell where it was completely unset ($EXPORT_CHECK)" ;;
  *) bad "expected 'declare -x GC_CITY_PATH=...' (exported) from a clean subshell, got '${EXPORT_CHECK:-<empty - not set at all>}'" ;;
esac

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
  unset FAKE_DOLT_SQL_OUTPUT FAKE_GC_SQL_OUTPUT FAKE_GC_SQL2_OUTPUT FAKE_DOLT_RESTORE_FAIL
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
# 2b. Snapshot baseline (ga-jsk5p8): the backup is charged only for rows that
#     existed when it was taken, and a DEAD backup job is caught explicitly
# ════════════════════════════════════════════════════════════════════════════
# The regression this section exists for (ga-fd84uf, 20/09): the weekly job ran
# 31 min after the backup, ONE bead was created in between, so restored 5107 <
# live 5108 and a perfectly good backup was filed as a P1 FAIL (a row-ID diff
# proved nothing else was missing). Same class as ga-o6e6y: an ad-hoc run 19h
# after the backup, gap 93 with 292 rows created since. The old rule only
# passed on quiet Sundays.
NOW=1789891200                       # 2026-09-20 08:00:00 UTC, pinned as RESTORE_VERIFY_NOW_EPOCH
_set_manifest() {                    # _set_manifest <db> <mtime_epoch>
  mkdir -p "$BACKUP_ROOT/$1"
  : > "$BACKUP_ROOT/$1/manifest"
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or die "utime: $!"' "$2" "$BACKUP_ROOT/$1/manifest"
}

echo "── helpers: _epoch_to_utc / _backup_mtime_epoch ──"
[ "$(_epoch_to_utc 1789891200 2>/dev/null)" = "2026-09-20 08:00:00" ] && ok "epoch 1789891200 -> '2026-09-20 08:00:00' (UTC, the timezone bd stores created_at in)" || bad "expected '2026-09-20 08:00:00', got '$(_epoch_to_utc 1789891200 2>&1)'"
[ -z "$(_epoch_to_utc abc 2>/dev/null)" ] && ok "non-numeric epoch -> empty (never a date built from garbage)" || bad "non-numeric epoch should produce empty"
[ -z "$(_epoch_to_utc -5 2>/dev/null)" ] && ok "negative epoch -> empty" || bad "negative epoch should produce empty"
[ -z "$(_epoch_to_utc '' 2>/dev/null)" ] && ok "empty epoch -> empty" || bad "empty epoch should produce empty"
_reset_fixture
[ -z "$(_backup_mtime_epoch hq 2>/dev/null)" ] && ok "no manifest -> empty (UNKNOWN, never 0)" || bad "a missing manifest should produce empty"
_set_manifest hq 1789889341
[ "$(_backup_mtime_epoch hq 2>/dev/null)" = "1789889341" ] && ok "reads the manifest mtime as epoch seconds" || bad "expected 1789889341, got '$(_backup_mtime_epoch hq 2>&1)'"

echo "── a typo'd override falls back to the documented default (never an empty arithmetic operand) ──"
V="$(env RESTORE_VERIFY_LIB=1 RESTORE_VERIFY_LOG="$SCRATCH/override.log" RESTORE_VERIFY_SNAPSHOT_SLACK_SEC=abc RESTORE_VERIFY_MAX_BACKUP_AGE_H= bash -c ". '$SCRIPT'; echo \"\$SNAPSHOT_SLACK_SEC \$MAX_BACKUP_AGE_H\"" 2>/dev/null)"
[ "$V" = "900 36" ] && ok "garbage slack -> 900s and empty max-age -> 36h (documented defaults)" || bad "expected '900 36', got '$V'"
V="$(env RESTORE_VERIFY_LIB=1 RESTORE_VERIFY_LOG="$SCRATCH/override.log" RESTORE_VERIFY_SNAPSHOT_SLACK_SEC=0900 RESTORE_VERIFY_MAX_BACKUP_AGE_H=036 bash -c ". '$SCRIPT'; echo \"\$SNAPSHOT_SLACK_SEC \$MAX_BACKUP_AGE_H \$(( SNAPSHOT_SLACK_SEC + 1 ))\"" 2>/dev/null)"
[ "$V" = "900 36 901" ] && ok "leading zeros ('0900', '036') are forced to base 10, not read as octal inside \$(( ))" || bad "expected '900 36 901', got '$V'"
X="$(RESTORE_VERIFY_NOW_EPOCH=abc _now_epoch 2>/dev/null)"
case "$X" in ''|*[!0-9]*) bad "a garbage NOW hook must fall back to the real clock (numeric), got '$X'" ;; *) ok "a non-numeric RESTORE_VERIFY_NOW_EPOCH is ignored -> real clock ($X)" ;; esac
[ "$(RESTORE_VERIFY_NOW_EPOCH=1789891200 _now_epoch)" = "1789891200" ] && ok "a numeric RESTORE_VERIFY_NOW_EPOCH pins 'now'" || bad "the NOW hook should pin the clock"

echo "── snapshot baseline: ga-fd84uf's exact case (1 bead created after the backup) -> OK, not FAIL ──"
_reset_fixture; _set_manifest hq $(( NOW - 1860 ))    # backup finished 31 min before the run
OUT="$(FAKE_GC_SQL_OUTPUT='| 5108' FAKE_GC_SQL2_OUTPUT='| 5108 | 1 |' FAKE_DOLT_SQL_OUTPUT='| 5107' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=OK(5107)" ] && ok "restored 5107 < live 5108, but the 1 missing row was created after the snapshot -> OK (the false P1 FAIL of 20/09)" || bad "expected 'hq=OK(5107)', got '$OUT'"
[ "$RC" -eq 0 ] && ok "a tolerated post-snapshot gap exits 0" || bad "expected exit 0, got $RC"
grep -q "criadas apos o backup=1" "$RESTORE_VERIFY_LOG" && ok "the tolerated gap is still visible in the log (auditable, not swallowed)" || bad "expected the gap detail in the log: $(cat "$RESTORE_VERIFY_LOG")"

echo "── snapshot baseline: ga-o6e6y's case (ad-hoc run 19h after the backup, 292 rows created since) -> OK ──"
_reset_fixture; _set_manifest hq $(( NOW - 68400 ))
OUT="$(FAKE_GC_SQL_OUTPUT='| 3524' FAKE_GC_SQL2_OUTPUT='| 3524 | 292 |' FAKE_DOLT_SQL_OUTPUT='| 3431' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=OK(3431)" ] && ok "restored 3431 < live 3524 with 292 rows created since the backup -> OK (expected 3232)" || bad "expected 'hq=OK(3431)', got '$OUT'"

echo "── snapshot baseline: rows that EXISTED at the snapshot are missing from the restore -> still FAIL ──"
_reset_fixture; _set_manifest hq $(( NOW - 1860 ))
OUT="$(FAKE_GC_SQL_OUTPUT='| 5108' FAKE_GC_SQL2_OUTPUT='| 5108 | 1 |' FAKE_DOLT_SQL_OUTPUT='| 5100' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=FAIL(restaurado:5100<esperado:5107,vivo:5108,pos-backup:1)" ] && ok "a real shortfall (5100 < 5107 expected at the snapshot) is FAIL and names restored, expected, live AND post-backup (auditable from the summary bead alone)" || bad "expected 'hq=FAIL(restaurado:5100<esperado:5107,vivo:5108,pos-backup:1)', got '$OUT'"
[ "$RC" -ne 0 ] && ok "a real shortfall exits nonzero" || bad "a real shortfall should exit nonzero"
_reset_fixture; _set_manifest hq $(( NOW - 600 ))
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_GC_SQL2_OUTPUT='| 500 | 0 |' FAKE_DOLT_SQL_OUTPUT='| 499' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=FAIL(restaurado:499<esperado:500,vivo:500,pos-backup:0)" ] && ok "nothing created since the backup and restored is 1 short -> FAIL (strictness intact when nothing explains the gap)" || bad "expected 'hq=FAIL(restaurado:499<esperado:500,vivo:500,pos-backup:0)', got '$OUT'"

echo "── freshness: backup OLDER than the limit and the db CHANGED since -> FAIL(defasado) (a dead backup job) ──"
# The old restored>=live rule caught a dead backup job only by accident (old
# backup => restored < live). Tolerating post-snapshot rows must not open that
# blind spot, so the same situation is now an explicit FAIL of its own.
_reset_fixture; _set_manifest hq $(( NOW - 180000 ))   # 50h old
OUT="$(FAKE_GC_SQL_OUTPUT='| 1000' FAKE_GC_SQL2_OUTPUT='| 1000 | 40 |' FAKE_DOLT_SQL_OUTPUT='| 960' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=FAIL(defasado:50h>36h,pos-backup:40)" ] && ok "50h-old backup of a db that gained 40 rows since -> FAIL(defasado:50h>36h,pos-backup:40)" || bad "expected 'hq=FAIL(defasado:50h>36h,pos-backup:40)', got '$OUT'"
[ "$RC" -ne 0 ] && ok "a stale backup exits nonzero" || bad "a stale backup should exit nonzero"
_reset_fixture; _set_manifest hq $(( NOW - 129600 ))   # exactly 36h: the limit is inclusive
OUT="$(FAKE_GC_SQL_OUTPUT='| 1000' FAKE_GC_SQL2_OUTPUT='| 1000 | 40 |' FAKE_DOLT_SQL_OUTPUT='| 960' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=OK(960)" ] && ok "a backup exactly at the age limit is still OK (only strictly older fails)" || bad "expected 'hq=OK(960)', got '$OUT'"
echo "── freshness: an OLD backup of a QUIET db (nothing created since) -> OK ──"
_reset_fixture; _set_manifest hq $(( NOW - 720000 ))   # 200h old, nothing new
OUT="$(FAKE_GC_SQL_OUTPUT='| 5' FAKE_GC_SQL2_OUTPUT='| 5 | 0 |' FAKE_DOLT_SQL_OUTPUT='| 5' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=OK(5)" ] && ok "a quiet db may keep an old backup: nothing is missing from it" || bad "expected 'hq=OK(5)', got '$OUT'"

echo "── unknown baseline: manifest present but the snapshot query fails or is garbled -> STRICT rule (never weaker) ──"
_reset_fixture; _set_manifest hq $(( NOW - 600 ))
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_GC_SQL2_OUTPUT='' FAKE_DOLT_SQL_OUTPUT='| 499' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=FAIL(restaurado:499<vivo:500)" ] && ok "snapshot query failed -> falls back to the strict live-count rule" || bad "expected 'hq=FAIL(restaurado:499<vivo:500)', got '$OUT'"
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_GC_SQL2_OUTPUT='| abc | def |' FAKE_DOLT_SQL_OUTPUT='| 499' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=FAIL(restaurado:499<vivo:500)" ] && ok "garbled snapshot output -> strict rule (a bad read never widens the tolerance)" || bad "expected 'hq=FAIL(restaurado:499<vivo:500)', got '$OUT'"
OUT="$(FAKE_GC_SQL_OUTPUT='| 100' FAKE_GC_SQL2_OUTPUT='| 100 | 250 |' FAKE_DOLT_SQL_OUTPUT='| 99' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=FAIL(restaurado:99<vivo:100)" ] && ok "an impossible reading (250 post-snapshot rows > 100 live rows) is not a measurement -> strict rule, never a widened tolerance" || bad "expected 'hq=FAIL(restaurado:99<vivo:100)', got '$OUT'"
OUT="$(FAKE_GC_SQL_OUTPUT='' FAKE_GC_SQL2_OUTPUT='' FAKE_DOLT_SQL_OUTPUT='| 499' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=SKIP(sem-baseline)" ] && ok "both baselines unreadable -> SKIP(sem-baseline), the honest third state" || bad "expected 'hq=SKIP(sem-baseline)', got '$OUT'"

echo "── no manifest at all: the snapshot instant is UNKNOWN -> a widening answer must not even be consulted (STRICT rule) ──"
# The cases above have a manifest and a bad/failed read. This one has NO manifest
# (bead ga-jsk5p8, point 5: "manifest ausente => regra ESTRITA"). The fake gc
# would happily answer '| 500 | 3 |' (3 post-snapshot rows => expected 497 =>
# restored 499 would PASS); the verdict has to stay the strict live-count one,
# because without a manifest there is no cutoff to charge those rows against.
_reset_fixture
: > "$SCRATCH/fake-gc.log"
OUT="$(FAKE_GC_LOG="$SCRATCH/fake-gc.log" FAKE_GC_SQL_OUTPUT='| 500' FAKE_GC_SQL2_OUTPUT='| 500 | 3 |' FAKE_DOLT_SQL_OUTPUT='| 499' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq)"
[ "$OUT" = "hq=FAIL(restaurado:499<vivo:500)" ] && ok "no manifest -> the snapshot answer is ignored and the strict rule applies (unknown never weakens the check)" || bad "expected 'hq=FAIL(restaurado:499<vivo:500)', got '$OUT'"
[ "$(grep -c 'SUM(created_at' "$SCRATCH/fake-gc.log")" = "0" ] && ok "and the snapshot query is never even issued (there is no cutoff to put in it)" || bad "the snapshot query must not run without a manifest: $(cat "$SCRATCH/fake-gc.log")"

echo "── the cutoff sent to SQL is the manifest mtime minus SNAPSHOT_SLACK_SEC, in UTC, in ONE statement ──"
_reset_fixture; _set_manifest hq $NOW                  # manifest 08:00:00Z, default slack 900s -> 07:45:00
: > "$SCRATCH/fake-gc.log"
FAKE_GC_LOG="$SCRATCH/fake-gc.log" FAKE_GC_SQL_OUTPUT='| 10' FAKE_GC_SQL2_OUTPUT='| 10 | 0 |' FAKE_DOLT_SQL_OUTPUT='| 10' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq >/dev/null
grep -q "created_at > '2026-09-20 07:45:00'" "$SCRATCH/fake-gc.log" && ok "default slack: cutoff = 08:00:00Z - 900s = 07:45:00" || bad "expected cutoff 07:45:00 in the SQL: $(cat "$SCRATCH/fake-gc.log")"
[ "$(grep -c 'GC-CALLED' "$SCRATCH/fake-gc.log")" = "1" ] && ok "live count and post-snapshot count come from ONE statement (both describe the same instant)" || bad "expected exactly 1 gc call, got $(grep -c 'GC-CALLED' "$SCRATCH/fake-gc.log")"
SAVED_SLACK="$SNAPSHOT_SLACK_SEC"; SNAPSHOT_SLACK_SEC=0
: > "$SCRATCH/fake-gc.log"
FAKE_GC_LOG="$SCRATCH/fake-gc.log" FAKE_GC_SQL_OUTPUT='| 10' FAKE_GC_SQL2_OUTPUT='| 10 | 0 |' FAKE_DOLT_SQL_OUTPUT='| 10' RESTORE_VERIFY_NOW_EPOCH=$NOW _verify_one_db hq >/dev/null
SNAPSHOT_SLACK_SEC="$SAVED_SLACK"
grep -q "created_at > '2026-09-20 08:00:00'" "$SCRATCH/fake-gc.log" && ok "slack 0: cutoff = the manifest time itself" || bad "expected cutoff 08:00:00 in the SQL: $(cat "$SCRATCH/fake-gc.log")"

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
