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
# ga-gqllbc: hq is an EPHEMERAL-staging db by default (no local backup by design). The legacy cases
# below use "hq" as their example of a db whose local backup is missing / present, so they run with the
# mode OFF; the section at the end turns it on per call. No conf file of the real city is ever read.
export DOLT_BACKUP_EPHEMERAL_DBS=""
export DOLT_BACKUP_EPHEMERAL_CONF="$SCRATCH/no-such-eph.env"
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

echo "── _discover_live_dbs <doltdir> (ga-e01691): the LIVE dbs, not the backup copies ──"
# The weekly job used to enumerate BACKUP directories only, so a live db whose
# backup dir was gone (27/09: low-disk mode freed .dolt-backup/hq, leaving only
# hq.new) never entered the loop and vanished from the summary -- "no backup"
# printed the same thing as "nothing to check". Live discovery is what closes it.
rm -rf "$SCRATCH/live"
mkdir -p "$SCRATCH/live/hq/.dolt" "$SCRATCH/live/gastown/.dolt" \
         "$SCRATCH/live/.dolt" "$SCRATCH/live/.doltcfg" "$SCRATCH/live/.dolt_dropped_databases" \
         "$SCRATCH/live/leftover-no-dolt-dir" \
         "$SCRATCH/live/testdb_abc123/.dolt" "$SCRATCH/live/beads_t9f2/.dolt" "$SCRATCH/live/beads_pt77/.dolt"
: > "$SCRATCH/live/server.log"
FOUND="$(_discover_live_dbs "$SCRATCH/live" | sort | tr '\n' ',')"
[ "$FOUND" = "gastown,hq," ] && ok "lists directories holding a .dolt; skips hidden server dirs, plain files, dirs that are not dolt dbs, and the testdb_/beads_t/beads_pt orphan prefixes" || bad "expected 'gastown,hq,', got '$FOUND'"
mkdir -p "$SCRATCH/live/beads/.dolt"
FOUND="$(_discover_live_dbs "$SCRATCH/live" | sort | tr '\n' ',')"
case "$FOUND" in *"beads,"*) ok "the real 'beads' db is not mistaken for a beads_t*/beads_pt* test orphan" ;; *) bad "'beads' must be discovered, got '$FOUND'" ;; esac
[ -z "$(_discover_live_dbs "$SCRATCH/does-not-exist" 2>/dev/null)" ] && ok "missing live dir -> empty (main() is what decides that is an error, see below)" || bad "missing live dir should produce empty"

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

echo "── _verify_one_db: live db with NO local backup -> NO-BACKUP (ga-e01691), not SKIP ──"
# SKIP means "could not check right now" (disk, no baseline) and is not an alarm.
# A live db with no backup dir at all is a different fact: nothing to restore
# from. Reporting it as SKIP filed it in the same bucket as a transient disk
# squeeze, and a run of "OK + one SKIP" is recorded as a clean, closed chore.
_reset_fixture
rm -rf "$BACKUP_ROOT/hq"
: > "$SCRATCH/fake-dolt.log"
OUT="$(FAKE_DOLT_LOG="$SCRATCH/fake-dolt.log" _verify_one_db hq)"; RC=$?
[ "$OUT" = "hq=NO-BACKUP(sem-backup-local)" ] && ok "live db without a backup dir is reported as NO-BACKUP(sem-backup-local)" || bad "expected 'hq=NO-BACKUP(sem-backup-local)', got '$OUT'"
[ "$RC" -eq 3 ] && ok "NO-BACKUP exits 3: not 0 (SKIP/OK) and not 1 (a backup that was checked and is broken)" || bad "NO-BACKUP should exit 3, got $RC"
[ ! -s "$SCRATCH/fake-dolt.log" ] && ok "no backup means no restore attempt" || bad "should never call dolt when there is no backup to restore"
_reset_fixture
rm -rf "$BACKUP_ROOT/hq"; mkdir -p "$BACKUP_ROOT/hq.new"
OUT="$(_verify_one_db hq)"
[ "$OUT" = "hq=NO-BACKUP(sem-backup-local)" ] && ok "an in-progress hq.new is not a backup: still NO-BACKUP" || bad "expected NO-BACKUP with only hq.new present, got '$OUT'"
grep -q "hq.new" "$RESTORE_VERIFY_LOG" && ok "the log says a hq.new reseed artifact is sitting there (the 27/09 shape), so the reader knows where to look" || bad "expected the log to mention hq.new: $(cat "$RESTORE_VERIFY_LOG")"

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

echo "── _file_summary_bead: a live db with no local backup (overall_rc=3) files an OPEN P1 bug, titled for what it is ──"
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" _file_summary_bead "alpha=OK(10) hq=NO-BACKUP(sem-backup-local) " 3
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "a missing backup files a --type=bug, not a clean chore" || bad "expected a bug create call: $(cat "$SCRATCH/fake-bd.log")"
grep -q -- "--priority=1" "$SCRATCH/fake-bd.log" && ok "P1: a live production db with nothing to restore from is unprotected" || bad "expected --priority=1: $(cat "$SCRATCH/fake-bd.log")"
grep -q "gastown.dog" "$SCRATCH/fake-bd.log" && ok "routed to gastown.dog like the other actionable outcomes" || bad "expected gc.routed_to routing metadata"
grep -q "SEM BACKUP LOCAL" "$SCRATCH/fake-bd.log" && ok "title names the condition (SEM BACKUP LOCAL), not the generic FALHOU" || bad "expected a SEM BACKUP LOCAL title: $(cat "$SCRATCH/fake-bd.log")"
grep -q "hq=NO-BACKUP" "$SCRATCH/fake-bd.log" && ok "the affected db is named in the bead" || bad "expected hq=NO-BACKUP in the bead"
grep -q "BD-CALLED.*close" "$SCRATCH/fake-bd.log" && bad "a missing-backup bead must NOT be closed by the job that found it" || ok "left open (no close call)"

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

echo "── main (ga-e01691): the 27/09 shape — live hq, its backup dir gone, only hq.new left — is REPORTED, not dropped ──"
# This is the regression itself. Before the fix main() walked the backup dir, so
# 'hq' (no dir, just hq.new, which _discover_dbs filters out) never entered the
# loop: no OK, no SKIP, no line at all, and the run was filed as a clean chore.
rm -rf "$SCRATCH/city4"
DOLTDIR="$SCRATCH/city4/doltdir"; BACKUP_ROOT="$SCRATCH/city4/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$DOLTDIR/alpha/.dolt" "$BACKUP_ROOT/alpha" "$BACKUP_ROOT/hq.new"
: > "$SCRATCH/fake-bd.log"; : > "$RESTORE_VERIFY_LOG"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 3 ] && ok "a live db with no backup exits 3 (not 0, even though alpha verified OK)" || bad "expected exit 3, got $RC"
grep -q "hq=NO-BACKUP(sem-backup-local)" "$SCRATCH/fake-bd.log" && ok "hq appears in the summary bead as NO-BACKUP — the line that was missing on 27/09" || bad "expected hq=NO-BACKUP in the summary: $(cat "$SCRATCH/fake-bd.log")"
grep -q "alpha=OK" "$SCRATCH/fake-bd.log" && ok "the db that does have a backup is still verified and listed alongside it" || bad "expected alpha=OK in the summary"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && grep -q -- "--priority=1" "$SCRATCH/fake-bd.log" && ok "filed as an OPEN P1 bug, not a clean chore" || bad "expected a P1 bug: $(cat "$SCRATCH/fake-bd.log")"
grep -q "BD-CALLED.*close" "$SCRATCH/fake-bd.log" && bad "the missing-backup run must not close its own bead" || ok "bead left open"

echo "── main (ga-e01691): a live db with no backup at ALL (no hq.new either) is reported the same way ──"
rm -rf "$BACKUP_ROOT/hq.new"
: > "$SCRATCH/fake-bd.log"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 3 ] && grep -q "hq=NO-BACKUP" "$SCRATCH/fake-bd.log" && ok "no hq.new needed: the live db alone is enough to put it in the summary" || bad "expected rc 3 and hq=NO-BACKUP, got rc=$RC: $(cat "$SCRATCH/fake-bd.log")"

echo "── main (ga-e01691): ONLY live dbs and NO backup dir anywhere -> still rc 3, not the 'nothing to verify' no-op ──"
rm -rf "$SCRATCH/city5"
DOLTDIR="$SCRATCH/city5/doltdir"; BACKUP_ROOT="$SCRATCH/city5/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$BACKUP_ROOT"
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 3 ] && ok "empty backup root + a live db is a gap, not a clean no-op (the old code returned 0 here and filed nothing)" || bad "expected rc 3, got $RC"
[ "$(grep -c 'BD-CALLED.*create' "$SCRATCH/fake-bd.log")" = "1" ] && ok "one summary bead filed" || bad "expected one create call: $(cat "$SCRATCH/fake-bd.log")"

echo "── main (ga-e01691): NO-BACKUP and a real FAIL in the same run -> rc 1 (FALHOU), and the NO-BACKUP db is still named ──"
rm -rf "$SCRATCH/city6"
DOLTDIR="$SCRATCH/city6/doltdir"; BACKUP_ROOT="$SCRATCH/city6/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$DOLTDIR/alpha/.dolt" "$BACKUP_ROOT/alpha"
: > "$SCRATCH/fake-bd.log"
FAKE_GC_SQL_OUTPUT='| 500' FAKE_DOLT_SQL_OUTPUT='| 499' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 1 ] && ok "a proven integrity FAIL keeps rc 1" || bad "expected rc 1, got $RC"
grep -q "hq=NO-BACKUP" "$SCRATCH/fake-bd.log" && grep -q "alpha=FAIL" "$SCRATCH/fake-bd.log" && ok "both results are in the one summary" || bad "expected hq=NO-BACKUP and alpha=FAIL: $(cat "$SCRATCH/fake-bd.log")"

echo "── main (ga-e01691): an orphan backup (no live db) is still LISTED, as SKIP(sem-banco-vivo) — the union keeps it visible ──"
rm -rf "$SCRATCH/city7"
DOLTDIR="$SCRATCH/city7/doltdir"; BACKUP_ROOT="$SCRATCH/city7/backup"
mkdir -p "$DOLTDIR/alpha/.dolt" "$BACKUP_ROOT/alpha" "$BACKUP_ROOT/fixdepkeys_0d16"
: > "$SCRATCH/fake-bd.log"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && ok "alpha OK + an orphan backup SKIP is still a clean run (an orphan backup is not an alarm)" || bad "expected rc 0, got $RC"
grep -q "fixdepkeys_0d16=SKIP(sem-banco-vivo)" "$SCRATCH/fake-bd.log" && ok "the orphan backup is reported, as before" || bad "expected fixdepkeys_0d16=SKIP(sem-banco-vivo): $(cat "$SCRATCH/fake-bd.log")"

echo "── main (ga-e01691): test-orphan live dirs (testdb_*, beads_t*, beads_pt*) are NOT demanded to have a backup ──"
rm -rf "$SCRATCH/city8"
DOLTDIR="$SCRATCH/city8/doltdir"; BACKUP_ROOT="$SCRATCH/city8/backup"
mkdir -p "$DOLTDIR/alpha/.dolt" "$DOLTDIR/testdb_abc/.dolt" "$DOLTDIR/beads_t1/.dolt" "$DOLTDIR/beads_pt2/.dolt" "$BACKUP_ROOT/alpha"
: > "$SCRATCH/fake-bd.log"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && ok "orphans from tests do not raise a NO-BACKUP alarm" || bad "expected rc 0, got $RC: $(cat "$SCRATCH/fake-bd.log")"
grep -q -E "testdb_abc|beads_t1|beads_pt2" "$SCRATCH/fake-bd.log" && bad "orphan dbs must not appear in the summary" || ok "and they are not listed"

echo "── main (ga-e01691): the LIVE dir cannot be read -> incomplete (rc 2), never a clean OK and never a silent no-op ──"
rm -rf "$SCRATCH/city9"
DOLTDIR="$SCRATCH/city9/no-such-doltdir"; BACKUP_ROOT="$SCRATCH/city9/backup"
mkdir -p "$BACKUP_ROOT/alpha"
: > "$SCRATCH/fake-bd.log"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
# alpha itself is SKIP(sem-banco-vivo) here (its live dir is the missing one);
# what matters is that the run is not filed as clean and says why.
[ "$RC" -eq 2 ] && ok "unreadable live dir -> rc 2" || bad "expected rc 2, got $RC"
grep -q "vivos=SKIP(sem-diretorio-vivo)" "$SCRATCH/fake-bd.log" && ok "the summary says the live list could not be read" || bad "expected vivos=SKIP(sem-diretorio-vivo): $(cat "$SCRATCH/fake-bd.log")"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "filed as an open bug" || bad "expected a bug create"
rm -rf "$SCRATCH/city10"
DOLTDIR="$SCRATCH/city10/no-such-doltdir"; BACKUP_ROOT="$SCRATCH/city10/empty-backup"
mkdir -p "$BACKUP_ROOT"
: > "$SCRATCH/fake-bd.log"
FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 2 ] && grep -q "vivos=SKIP(sem-diretorio-vivo)" "$SCRATCH/fake-bd.log" && ok "unreadable live dir AND empty backup root: still rc 2 with a bead — 'could not list' is not 'nothing to check'" || bad "expected rc 2 + a bead, got rc=$RC: $(cat "$SCRATCH/fake-bd.log")"

echo "── main (ga-e01691): a healthy fully-verified run is STILL clean (rc 0, closed chore) — the new checks did not over-alarm ──"
rm -rf "$SCRATCH/city11"
DOLTDIR="$SCRATCH/city11/doltdir"; BACKUP_ROOT="$SCRATCH/city11/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$DOLTDIR/alpha/.dolt" "$BACKUP_ROOT/hq" "$BACKUP_ROOT/alpha"
: > "$SCRATCH/fake-bd.log"
FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && grep -q "hq=OK" "$SCRATCH/fake-bd.log" && grep -q "alpha=OK" "$SCRATCH/fake-bd.log" && grep -q "BD-CALLED.*close" "$SCRATCH/fake-bd.log" && ok "live+backup for every db -> rc 0, both listed, closed chore" || bad "expected a clean run, got rc=$RC: $(cat "$SCRATCH/fake-bd.log")"

# ═══ ga-gqllbc: a db with EPHEMERAL local staging (hq) has no local backup by design → S3 is checked ═══
echo "── _verify_one_db: ephemeral-staging db → S3-OK / SKIP / FAIL from S3's own state, never NO-BACKUP (ga-gqllbc) ──"
FB="$SCRATCH/bucket"; export FB
FAKE_AWS="$SCRATCH/fake-aws.sh"
cat > "$FAKE_AWS" <<'EOF'
#!/bin/bash
echo "aws $*" >> "${FAKE_AWS_LOG:-/dev/null}"
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
    [ "$op" = cp ] || exit 99
    case "$1" in s3://*) key="${1#s3://*/}"; [ -f "$FB/$key" ] || exit 1; cp "$FB/$key" "$2"; exit 0 ;; esac
    exit 99 ;;
esac
exit 99
EOF
chmod +x "$FAKE_AWS"
AWS="$FAKE_AWS"; BUCKET="testbucket"; S3PROOF_TIMEOUT=20
_E_LOCKH="0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; _E_ROOTH="0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; _E_GCG="00000000000000000000000000000000"
e_tid() { printf '%032d' "$1"; }
e_s3_backup() { # <db> <n_tables> — a CLOSED backup under the fake bucket
  local d="$FB/$1" n="$2" i s="5:__DOLT__:$_E_LOCKH:$_E_ROOTH:$_E_GCG"
  mkdir -p "$d"; for i in $(seq 1 "$n"); do s="$s:$(e_tid "$i"):$((i*7))"; printf 'tbl%s' "$i" > "$d/$(e_tid "$i").darc"; done
  printf '%s' "$s" > "$d/manifest"
}
e_iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
e_fp() { # <hq entry json> — writes S3's run fingerprint
  mkdir -p "$FB/_meta"; printf '{"run_utc":"%s","databases":{"hq":%s}}' "$(e_iso "$(date +%s)")" "$1" > "$FB/_meta/latest.json"
}
e_reset() { _reset_fixture; rm -rf "$BACKUP_ROOT/hq" "$FB"; mkdir -p "$FB"; : > "$SCRATCH/fake-dolt.log"; : > "$SCRATCH/fake-gc.log"; }
NOW="$(date +%s)"
e_run() { DOLT_BACKUP_EPHEMERAL_DBS="${E_DBS-hq}" FAKE_DOLT_LOG="$SCRATCH/fake-dolt.log" FAKE_GC_LOG="$SCRATCH/fake-gc.log" _verify_one_db "$@"; }

e_reset; e_s3_backup hq 4; e_fp "{\"issues\":9,\"run_utc\":\"$(e_iso $((NOW - 7200)))\"}"
OUT="$(e_run hq)"; RC=$?
[ "$OUT" = "hq=S3-OK(fecho-do-manifest,backup-com-2h)" ] && [ "$RC" -eq 0 ] && ok "no local backup + closed S3 manifest + a 2h-old fingerprint → hq=S3-OK(…), rc 0" || bad "expected hq=S3-OK(fecho-do-manifest,backup-com-2h) rc 0, got '$OUT' rc=$RC"
[ ! -s "$SCRATCH/fake-dolt.log" ] && [ ! -s "$SCRATCH/fake-gc.log" ] && ok "…without a restore and without a live query (it is not, and does not claim to be, a restore)" || bad "an S3-only check called dolt/gc: $(cat "$SCRATCH/fake-dolt.log" "$SCRATCH/fake-gc.log")"
case "$OUT" in "hq=OK("*) bad "the S3-only check reported itself as OK(n)" ;; *) ok "…and its result word is S3-OK, never OK( — main() must not count it as a verified restore" ;; esac

e_reset; e_s3_backup hq 4; rm -f "$FB/hq/$(e_tid 3).darc"; e_fp "{\"issues\":9,\"run_utc\":\"$(e_iso $((NOW - 7200)))\"}"
OUT="$(e_run hq)"; RC=$?
[ "$OUT" = "hq=FAIL(s3-nao-restauravel)" ] && [ "$RC" -eq 1 ] && ok "S3's manifest names a table the bucket lacks (the hq 2026-09-25 shape) → FAIL(s3-nao-restauravel), rc 1" || bad "unrestorable S3 copy not failed: '$OUT' rc=$RC"

e_reset; e_s3_backup hq 4   # no _meta/latest.json at all
OUT="$(e_run hq)"; RC=$?
[ "$OUT" = "hq=SKIP(s3-fingerprint-ilegivel)" ] && [ "$RC" -eq 0 ] && ok "S3's fingerprint cannot be read → SKIP (could not look), rc 0 — an unreachable S3 is not a broken backup" || bad "unreadable fingerprint: '$OUT' rc=$RC"

e_reset; e_s3_backup hq 4; mkdir -p "$FB/_meta"; printf '{"run_utc":"%s","databases":{"lexbh":{"issues":1}}}' "$(e_iso "$NOW")" > "$FB/_meta/latest.json"
OUT="$(e_run hq)"; RC=$?
[ "$OUT" = "hq=FAIL(s3-sem-entrada-no-fingerprint)" ] && [ "$RC" -eq 1 ] && ok "the fingerprint has no entry for hq → FAIL (a real absence is reported)" || bad "absent entry: '$OUT' rc=$RC"

e_reset; e_s3_backup hq 4; e_fp "{\"issues\":9,\"run_utc\":\"$(e_iso $((NOW - 180000)))\"}"
OUT="$(e_run hq)"; RC=$?
case "$OUT" in "hq=FAIL(defasado:50h>36h)") [ "$RC" -eq 1 ] && ok "a 50h-old S3 backup (limit 36h) → FAIL(defasado:50h>36h): the backup job is not keeping up" || bad "stale: rc=$RC" ;; *) bad "stale S3 backup: '$OUT' rc=$RC" ;; esac

e_reset; e_s3_backup hq 4; e_fp "{\"status\":\"failed\",\"reason\":\"disco\",\"last_ok_run_utc\":\"$(e_iso $((NOW - 36000)))\",\"last_ok\":{\"issues\":9}}"
OUT="$(e_run hq)"; RC=$?
[ "$OUT" = "hq=S3-OK(fecho-do-manifest,backup-com-10h,ultima-noite-falhou)" ] && [ "$RC" -eq 0 ] && ok "last night failed but the last good backup is 10h old and S3 closes → S3-OK, with 'ultima-noite-falhou' in the word (not hidden)" || bad "failed-recent: '$OUT' rc=$RC"

e_reset; e_s3_backup hq 4; e_fp '{"status":"failed","reason":"disco","last_ok_run_utc":null,"last_ok":null}'
OUT="$(e_run hq)"; RC=$?
[ "$OUT" = "hq=FAIL(s3-ultima-noite-falhou-sem-ultima-boa)" ] && [ "$RC" -eq 1 ] && ok "failed last night and no recorded last-good time → FAIL (freshness cannot be proven)" || bad "failed-unknown: '$OUT' rc=$RC"

# the kill switch and the other dbs keep the legacy behaviour
e_reset; e_s3_backup hq 4; e_fp "{\"issues\":9,\"run_utc\":\"$(e_iso "$NOW")\"}"
OUT="$(E_DBS="" e_run hq)"; RC=$?
[ "$OUT" = "hq=NO-BACKUP(sem-backup-local)" ] && [ "$RC" -eq 3 ] && ok "mode off (empty list) → NO-BACKUP(sem-backup-local), rc 3, exactly as before (S3 is not even asked)" || bad "kill switch: '$OUT' rc=$RC"
e_reset; mkdir -p "$DOLTDIR/lexbh"; e_s3_backup lexbh 3
OUT="$(E_DBS=hq e_run lexbh)"; RC=$?
[ "$OUT" = "lexbh=NO-BACKUP(sem-backup-local)" ] && [ "$RC" -eq 3 ] && ok "a db that is NOT on the list keeps the NO-BACKUP verdict even if S3 happens to hold a copy" || bad "non-ephemeral db: '$OUT' rc=$RC"
e_reset; mkdir -p "$BACKUP_ROOT/hq"
OUT="$(FAKE_GC_SQL_OUTPUT='| 500' FAKE_DOLT_SQL_OUTPUT='| 500' e_run hq)"; RC=$?
[ "$OUT" = "hq=OK(500)" ] && [ "$RC" -eq 0 ] && ok "an ephemeral db that DOES have a local backup dir (first night / a held-back release) is restored and verified as always" || bad "local copy of an ephemeral db: '$OUT' rc=$RC"

echo "── main: ephemeral hq alongside a really-verified db → clean run; hq is listed as S3-OK ──"
rm -rf "$SCRATCH/city12" "$FB"; mkdir -p "$FB"
DOLTDIR="$SCRATCH/city12/doltdir"; BACKUP_ROOT="$SCRATCH/city12/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$DOLTDIR/alpha/.dolt" "$BACKUP_ROOT/alpha"
e_s3_backup hq 4; e_fp "{\"issues\":9,\"run_utc\":\"$(e_iso $((NOW - 7200)))\"}"
: > "$SCRATCH/fake-bd.log"; : > "$RESTORE_VERIFY_LOG"
DOLT_BACKUP_EPHEMERAL_DBS=hq FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
if [ "$RC" -eq 0 ] && grep -q 'alpha=OK' "$SCRATCH/fake-bd.log" && grep -q 'hq=S3-OK(' "$SCRATCH/fake-bd.log" && grep -q 'BD-CALLED.*close' "$SCRATCH/fake-bd.log"; then
  ok "rc 0, closed chore, alpha=OK(real restore) and hq=S3-OK(…) side by side — the weaker check is visible in the summary"
else bad "expected a clean run listing both (rc=$RC): $(cat "$SCRATCH/fake-bd.log")"; fi

echo "── main: ephemeral hq ALONE is S3-OK → nothing was RESTORED → rc 2, not a clean 'restore OK' (a documented consequence) ──"
rm -rf "$SCRATCH/city13"; DOLTDIR="$SCRATCH/city13/doltdir"; BACKUP_ROOT="$SCRATCH/city13/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$BACKUP_ROOT"
: > "$SCRATCH/fake-bd.log"
DOLT_BACKUP_EPHEMERAL_DBS=hq FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 2 ] && grep -q 'hq=S3-OK(' "$SCRATCH/fake-bd.log" && ok "only an S3-only check ran → rc 2 (SEM VERIFICACAO), never filed as a clean restore-verify" || bad "S3-OK alone was counted as a verified restore (rc=$RC): $(cat "$SCRATCH/fake-bd.log")"

echo "── main: ephemeral hq whose S3 copy does not close → the WHOLE run fails (rc 1, open bug) ──"
rm -rf "$SCRATCH/city14" "$FB"; mkdir -p "$FB"; DOLTDIR="$SCRATCH/city14/doltdir"; BACKUP_ROOT="$SCRATCH/city14/backup"
mkdir -p "$DOLTDIR/hq/.dolt" "$DOLTDIR/alpha/.dolt" "$BACKUP_ROOT/alpha"
e_s3_backup hq 4; rm -f "$FB/hq/$(e_tid 2).darc"; e_fp "{\"issues\":9,\"run_utc\":\"$(e_iso "$NOW")\"}"
: > "$SCRATCH/fake-bd.log"
DOLT_BACKUP_EPHEMERAL_DBS=hq FAKE_GC_SQL_OUTPUT='| 10' FAKE_DOLT_SQL_OUTPUT='| 10' FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 1 ] && grep -q 'hq=FAIL(s3-nao-restauravel)' "$SCRATCH/fake-bd.log" && grep -q 'BD-CALLED.*create.*--type=bug' "$SCRATCH/fake-bd.log" && ok "an unrestorable S3 copy of an ephemeral db fails the run and files an open bug naming hq" || bad "unrestorable S3 copy did not fail the run (rc=$RC): $(cat "$SCRATCH/fake-bd.log")"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
