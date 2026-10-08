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

# Scenario B (removed, ga-o3nqy2 gate-fix): used to assert that a `.dolt/
# sql-server.info` marker inside the clone made _offline_backup_sync refuse.
# That check was dead code in the library — a per-db clone (`$data_dir/$db`
# -> `$clone_parent/$db`) can never carry that marker; it lives once, at the
# shared `$data_dir/.dolt/` root (verified live against all 7 running
# databases). This test manufactured the marker AT THE PATH THE CODE CHECKED
# instead of the real path Dolt writes it to, so it passed without ever
# proving the hazard it claimed to cover — a test that could not catch its
# own regression. The check and its file-header claim were removed from the
# library; Scenario C below already proves the actual threat (a clone that
# runs through a live server) via the real, working @@port comparison.

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

# Scenario G (self-audit finding, gate-done pass): `cp -c -R` can exit nonzero
# (e.g. one unreadable file mid-tree) while STILL leaving a partial $clone
# directory behind — confirmed directly: an unreadable file inside the source
# makes `cp` exit 1 but the destination directory exists with the OTHER files
# copied. Checking directory-existence alone would treat that partial clone
# as a clean success and sync it onward. Reproduce the exact mechanism against
# a real dolt repo: chmod a table file unreadable, confirm the sync refuses
# rather than proceeding on a partial copy.
mkdir -p "$DATA_DIR/testdb4" && ( cd "$DATA_DIR/testdb4" && dolt init >/dev/null 2>&1 )
UNREADABLE_FILE="$(find "$DATA_DIR/testdb4/.dolt/noms" -type f 2>/dev/null | head -1)"
DEST_G="$WORK/dest-g"
if [ -n "$UNREADABLE_FILE" ]; then
  chmod 000 "$UNREADABLE_FILE"
  if _offline_backup_sync "testdb4" "$DEST_G"; then
    bad "scenario G (cp exits nonzero on an unreadable file): should have refused, not synced a partial clone"
  else
    ok "scenario G (cp exits nonzero on an unreadable file): refuses"
  fi
  chmod 644 "$UNREADABLE_FILE"
  [ ! -e "$DEST_G" ] \
    && ok "scenario G: dest was never created — a partial clone was never synced onward" \
    || bad "scenario G: dest '$DEST_G' exists despite the partial-copy refusal"
  grep -qF "testdb4: offline-sync: clonefile FAILED (rc=" "$OFFLINE_SYNC_LOG" \
    && ok "scenario G: logged the clonefile-failed line with the nonzero exit code" \
    || bad "scenario G: missing the rc-aware clonefile-failed log line"
else
  bad "scenario G: could not find a noms file under testdb4 to make unreadable — fixture setup broken"
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

# ── ga-a0woau: SEEDED mode — a fresh dest is pre-loaded with clonefile copies of the live store's
# oldgen so sync-url writes only the delta. The scenarios use a real dolt repo big enough that "wrote
# everything" and "wrote the delta" are an order of magnitude apart, and measure the BYTES the sync put
# in the dest that the live oldgen does not already hold (not just the exit code).
echo "── seeded mode (ga-a0woau) — real dolt, GC'd repo ──"

# _mk_gcd_repo <name> — a repo with a committed ~3MB table, GC'd (so it has an oldgen), plus a small
# delta written AFTER the GC (lands in the journal/newgen, not in oldgen).
_mk_gcd_repo() {
  local name="$1"
  mkdir -p "$DATA_DIR/$name"
  ( cd "$DATA_DIR/$name" && dolt init >/dev/null 2>&1 \
    && dolt sql -q "CREATE TABLE big (id int primary key, pad varchar(200));" >/dev/null 2>&1 \
    && awk 'BEGIN{srand(7); print "id,pad"; for(i=1;i<=30000;i++){s=""; for(j=0;j<12;j++) s=s sprintf("%08x",int(rand()*4294967295)); print i "," s}}' > "$WORK/$name.csv" \
    && dolt table import -u big "$WORK/$name.csv" >/dev/null 2>&1 \
    && dolt add -A >/dev/null 2>&1 && dolt commit -m "bulk" >/dev/null 2>&1 \
    && dolt gc >/dev/null 2>&1 \
    && dolt sql -q "INSERT INTO big VALUES (100001,'delta-a'),(100002,'delta-b'),(100003,'delta-c');" >/dev/null 2>&1 )
}
# _bytes_outside_oldgen <dest> <oldgen_dir> — bytes of the dest's table files whose names the live oldgen
# manifest does NOT list: what the sync really wrote. vazio (no such file) prints 0 for an empty dest, but
# an unreadable manifest prints "?" so a broken measurement can never read as "wrote nothing".
_bytes_outside_oldgen() {
  local dest="$1" og="$2" names f base n tot=0 skip
  names="$(_offline_sync_oldgen_names "$og/manifest")" || { echo "?"; return 0; }
  for f in "$dest"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"; base="${base%.darc}"
    case "$base" in manifest|LOCK) continue ;; esac
    skip=0; for n in $names; do [ "$n" = "$base" ] && skip=1; done
    [ "$skip" -eq 1 ] || tot=$((tot + $(stat -f '%z' "$f")))
  done
  echo "$tot"
}

_mk_gcd_repo seedhq
OG_H="$DATA_DIR/seedhq/.dolt/noms/oldgen"
if [ -f "$OG_H/manifest" ]; then ok "fixture: the GC'd repo has an oldgen with its own manifest"; else bad "fixture: no oldgen/manifest after dolt gc — the seeded scenarios cannot run"; fi
OG_BYTES="$(du -sk "$OG_H" 2>/dev/null | awk '{print $1*1024}')"
LIVE_COUNT_H="$(cd "$DATA_DIR/seedhq" && dolt sql -q "SELECT COUNT(*) FROM big" --result-format csv 2>/dev/null | tail -1)"
[ "$LIVE_COUNT_H" = "30003" ] && ok "fixture: live count is 30003 (30000 GC'd + 3 after)" || bad "fixture: live count='$LIVE_COUNT_H', expected 30003"

# A recording wrapper around the real dolt: at the moment `backup sync-url` starts it logs what the
# destination already holds (name + inode), then runs the real sync-url. That is the evidence of WHAT
# the seed did — on this repo an unseeded sync-url also ends with the oldgen table names in the dest
# (Dolt copies a table file verbatim when it can), so "the names are there afterwards" proves nothing;
# "they were there BEFORE sync-url ran and it left them alone" does.
RECBIN="$WORK/dolt-rec"
cat > "$RECBIN" <<'EOS'
#!/bin/bash
for a in "$@"; do case "$a" in file://*) d="${a#file://}" ;; esac; done
case "$*" in
  *"backup sync-url"*) ls -i "$d" 2>/dev/null | sed 's/^ *//' | sort -k2 > "$REC_OUT.pre" ;;
esac
dolt "$@"; rc=$?
case "$*" in
  *"backup sync-url"*) ls -i "$d" 2>/dev/null | sed 's/^ *//' | sort -k2 > "$REC_OUT.post" ;;
esac
exit $rc
EOS
chmod +x "$RECBIN"

# H0 (negative control): the same sync WITHOUT the seed — the recorder must show an empty dest at start.
DEST_H0="$WORK/dest-h0"
REC_OUT="$WORK/rec-h0" OFFLINE_SYNC_DOLT_BIN="$RECBIN" _offline_backup_sync "seedhq" "$DEST_H0" >/dev/null 2>&1 \
  && ok "H0: unseeded sync of the GC'd repo succeeds (the baseline)" || bad "H0: unseeded sync failed"
[ -f "$WORK/rec-h0.pre" ] && [ ! -s "$WORK/rec-h0.pre" ] \
  && ok "H0: unseeded — the dest was EMPTY when sync-url started (so the recorder can tell seeded from unseeded)" \
  || bad "H0: the unseeded dest was not empty at sync-url start (recorder cannot discriminate)"

# H: seeded.
DEST_H="$WORK/dest-h"
if REC_OUT="$WORK/rec-h" OFFLINE_SYNC_DOLT_BIN="$RECBIN" OFFLINE_SYNC_SEED_OLDGEN=1 _offline_backup_sync "seedhq" "$DEST_H"; then ok "H: seeded sync succeeds"; else bad "H: seeded sync failed"; fi
grep -qF "seedhq: offline-sync: OK ($DATA_DIR/seedhq -> $DEST_H, server-free, seeded from oldgen)" "$OFFLINE_SYNC_LOG" \
  && ok "H: the OK line says the copy was seeded from oldgen" || bad "H: missing the 'seeded from oldgen' OK line"
# (a) at sync-url start the (still private) seed already held manifest + every oldgen table…
SEED_MISSING=0
for n in $(_offline_sync_oldgen_names "$OG_H/manifest"); do grep -qE " $n(\.darc)?$" "$WORK/rec-h.pre" || SEED_MISSING=$((SEED_MISSING+1)); done
grep -qE ' manifest$' "$WORK/rec-h.pre" || SEED_MISSING=$((SEED_MISSING+1))
[ "$SEED_MISSING" -eq 0 ] && ok "H: when sync-url started, the dest already held the manifest and every oldgen table (seeded, not built)" || bad "H: $SEED_MISSING seed file(s) missing when sync-url started"
# (b) …and sync-url left those files alone (same inode before and after: not rewritten, not replaced)…
REWRITTEN=0
while read -r ino name; do
  case "$name" in manifest|LOCK) continue ;; esac
  post_ino="$(awk -v n="$name" '$2==n{print $1}' "$WORK/rec-h.post")"
  [ "$post_ino" = "$ino" ] || REWRITTEN=$((REWRITTEN+1))
done < "$WORK/rec-h.pre"
[ "$REWRITTEN" -eq 0 ] && ok "H: sync-url left every seeded table file untouched (same inode before/after)" || bad "H: sync-url replaced $REWRITTEN seeded table file(s)"
# (c) …the seeded files are copies, not the live files themselves (a hardlink would let a later rm of the
# staging, or Dolt's GC, reach into the live store)…
LIVE_INO_SHARED=0
for f in "$DEST_H"/*.darc "$DEST_H"/[0-9a-v]*; do
  [ -f "$f" ] || continue
  [ -f "$OG_H/$(basename "$f")" ] && [ "$(stat -f '%i' "$f")" = "$(stat -f '%i' "$OG_H/$(basename "$f")")" ] && LIVE_INO_SHARED=$((LIVE_INO_SHARED+1))
done
[ "$LIVE_INO_SHARED" -eq 0 ] && ok "H: no seeded file shares an inode with the live store (clones, not hardlinks)" || bad "H: $LIVE_INO_SHARED seeded file(s) are hardlinks into the live store"
# …and cmp says they hold exactly the live bytes.
CMP_BAD=0
for n in $(_offline_sync_oldgen_names "$OG_H/manifest"); do
  for ext in "" ".darc"; do [ -f "$OG_H/$n$ext" ] && { cmp -s "$OG_H/$n$ext" "$DEST_H/$n$ext" || CMP_BAD=$((CMP_BAD+1)); }; done
done
[ "$CMP_BAD" -eq 0 ] && ok "H: every seeded table is byte-identical to the live oldgen file" || bad "H: $CMP_BAD seeded table(s) differ from the live oldgen"
# (d) no consolidated rewrite next to the seeded files (what a seed that sync-url ignored looks like).
B_SEEDED="$(_bytes_outside_oldgen "$DEST_H" "$OG_H")"
case "$B_SEEDED" in \?|'') bad "H: could not measure the bytes outside oldgen" ;;
  *) [ "$B_SEEDED" -lt $((OG_BYTES / 5)) ] \
       && ok "H: only ${B_SEEDED}B of new table data next to ${OG_BYTES}B of seeded oldgen — the delta, not a second copy of the store" \
       || bad "H: ${B_SEEDED}B of new table data vs ${OG_BYTES}B oldgen — a full rewrite sits next to the seed" ;;
esac
SEEDED_OK=1
for n in $(_offline_sync_oldgen_names "$OG_H/manifest"); do
  grep -q "$n" "$DEST_H/manifest" || SEEDED_OK=0
done
[ "$SEEDED_OK" = 1 ] && ok "H: the dest's manifest still lists every oldgen table (they are referenced, not rewritten)" || bad "H: the dest manifest lost an oldgen table"
VERIFY_H="$WORK/verify-h"; mkdir -p "$VERIFY_H"
( cd "$VERIFY_H" && dolt backup restore "file://$DEST_H" "restored" >/dev/null 2>&1 )
REST_H="$(cd "$VERIFY_H/restored" 2>/dev/null && dolt sql -q "SELECT COUNT(*) FROM big" --result-format csv 2>/dev/null | tail -1)"
[ "$REST_H" = "$LIVE_COUNT_H" ] \
  && ok "H: restaurado=$REST_H vs vivo=$LIVE_COUNT_H — the seeded copy restores to the live row count (the actual proof)" \
  || bad "H: restaurado='$REST_H' vs vivo='$LIVE_COUNT_H'"
# the restored delta rows are really there (not just the GC'd bulk)
DELTA_H="$(cd "$VERIFY_H/restored" 2>/dev/null && dolt sql -q "SELECT COUNT(*) FROM big WHERE id > 100000" --result-format csv 2>/dev/null | tail -1)"
[ "$DELTA_H" = "3" ] && ok "H: the 3 rows written after the GC are in the restored copy" || bad "H: delta rows in the restored copy='$DELTA_H', expected 3"

# I: the caller REQUIRES the seed (its disk gate counted on it) but the store was never GC'd -> REFUSE, and
# leave no dest (the full build would write GBs nobody reserved).
mkdir -p "$DATA_DIR/seednogc" && ( cd "$DATA_DIR/seednogc" && dolt init >/dev/null 2>&1 )
DEST_I="$WORK/dest-i"
if OFFLINE_SYNC_SEED_OLDGEN=1 OFFLINE_SYNC_REQUIRE_SEED=1 _offline_backup_sync "seednogc" "$DEST_I"; then
  bad "I: REQUIRE_SEED with nothing to seed from must refuse, not do the full build"
else
  ok "I: REQUIRE_SEED with no oldgen -> refuses"
fi
[ ! -e "$DEST_I" ] && ok "I: no dest was created by the refusal" || bad "I: dest exists after the refusal"
grep -qF "seednogc: offline-sync: REFUSING — the caller's disk gate counted on the oldgen seed but the seed is not available (no:no-oldgen)" "$OFFLINE_SYNC_LOG" \
  && ok "I: the log says why (no:no-oldgen) — a reason, not a silent skip" || bad "I: missing the REFUSING line with its reason"

# J: seeding is wanted but not required and there is nothing to seed from -> the legacy full sync, and it works.
DEST_J="$WORK/dest-j"
if OFFLINE_SYNC_SEED_OLDGEN=1 _offline_backup_sync "seednogc" "$DEST_J"; then ok "J: no oldgen, seed not required -> falls back to the plain sync"; else bad "J: the plain fallback failed"; fi
[ -s "$DEST_J/manifest" ] && ok "J: the fallback dest has a manifest" || bad "J: the fallback dest has no manifest"

# K: the seeded sync-url FAILS -> rc 1 and NO dest is left behind (a seeded dir whose manifest names a
# zero root would pass a closure proof and restore empty).
FAILBIN="$WORK/dolt-failsync"
cat > "$FAILBIN" <<'EOS'
#!/bin/bash
case "$*" in *"backup sync-url"*) echo "simulated sync-url failure" >&2; exit 1 ;; esac
exec dolt "$@"
EOS
chmod +x "$FAILBIN"
DEST_K="$WORK/dest-k"
if OFFLINE_SYNC_DOLT_BIN="$FAILBIN" OFFLINE_SYNC_SEED_OLDGEN=1 _offline_backup_sync "seedhq" "$DEST_K"; then
  bad "K: a failing sync-url must make the seeded sync fail"
else
  ok "K: seeded sync-url failure -> reports failure"
fi
[ ! -e "$DEST_K" ] && ok "K: no dest left behind after the failed seeded sync (no closing-but-zero-root manifest)" || bad "K: dest '$DEST_K' exists after a failed seeded sync"

# L: dest already holds a copy (the incremental night) -> never seeded; REQUIRE_SEED refuses.
DEST_L="$WORK/dest-l"
OFFLINE_SYNC_SEED_OLDGEN=1 _offline_backup_sync "seedhq" "$DEST_L" >/dev/null 2>&1
LM_BEFORE="$(cksum < "$DEST_L/manifest" 2>/dev/null)"
if OFFLINE_SYNC_SEED_OLDGEN=1 _offline_backup_sync "seedhq" "$DEST_L"; then ok "L: a dest that already holds a copy syncs incrementally"; else bad "L: incremental sync into an existing copy failed"; fi
grep -qF "not seeding (no:dest-has-content)" "$OFFLINE_SYNC_LOG" && ok "L: the incremental night says why it did not seed" || bad "L: missing 'not seeding (no:dest-has-content)'"
if OFFLINE_SYNC_SEED_OLDGEN=1 OFFLINE_SYNC_REQUIRE_SEED=1 _offline_backup_sync "seedhq" "$DEST_L"; then bad "L: REQUIRE_SEED into a dest with content must refuse"; else ok "L: REQUIRE_SEED into a dest with content -> refuses"; fi
[ -s "$DEST_L/manifest" ] && [ -n "$LM_BEFORE" ] && ok "L: the existing copy was left in place" || bad "L: the existing copy's manifest vanished"

# M: _offline_sync_seed_state — each word, and failed != empty.
DEST_M="$WORK/dest-m-absent"
[ "$(_offline_sync_seed_state seedhq "$DEST_M")" = "no:disabled" ] && ok "M: mode off -> no:disabled" || bad "M: mode off should say no:disabled"
export OFFLINE_SYNC_SEED_OLDGEN=1
case "$(_offline_sync_seed_state seedhq "$DEST_M")" in "ok "[1-9]*) ok "M: GC'd store, absent dest -> ok <kb>" ;; *) bad "M: GC'd store, absent dest should be 'ok <kb>' (got '$(_offline_sync_seed_state seedhq "$DEST_M")')" ;; esac
mkdir -p "$WORK/dest-m-empty"
case "$(_offline_sync_seed_state seedhq "$WORK/dest-m-empty")" in "ok "[1-9]*) ok "M: an EMPTY existing dest dir is still seedable" ;; *) bad "M: an empty dest dir should be seedable" ;; esac
[ "$(_offline_sync_seed_state seedhq "$DEST_H")" = "no:dest-has-content" ] && ok "M: a dest with a copy -> no:dest-has-content" || bad "M: dest with content should say no:dest-has-content"
[ "$(_offline_sync_seed_state seednogc "$DEST_M")" = "no:no-oldgen" ] && ok "M: a never-GC'd store -> no:no-oldgen (empty by nature)" || bad "M: never-GC'd store should say no:no-oldgen"
[ "$(OFFLINE_SYNC_TMP_ROOT="/definitely/does/not/exist/$$" _offline_sync_seed_state seedhq "$DEST_M")" = "no:volume" ] && ok "M: a tmp root whose volume cannot be established -> no:volume" || bad "M: unresolvable tmp root should say no:volume"
[ "$(OFFLINE_SYNC_DOLT_CFG="$MISSING_CFG" _offline_sync_seed_state seedhq "$DEST_M")" = "no:no-data-dir" ] && ok "M: no data_dir in the config -> no:no-data-dir" || bad "M: config without data_dir should say no:no-data-dir"
# failed != empty: an oldgen whose manifest names a table that is not there is "unreadable", NOT "no-oldgen".
cp -R "$DATA_DIR/seedhq" "$DATA_DIR/seedbroken"
BROKEN_FILE="$(ls "$DATA_DIR/seedbroken/.dolt/noms/oldgen" | grep -v -E '^(manifest|LOCK)$' | head -1)"
rm -f "$DATA_DIR/seedbroken/.dolt/noms/oldgen/$BROKEN_FILE"
[ "$(_offline_sync_seed_state seedbroken "$DEST_M")" = "no:unreadable" ] && ok "M: an oldgen missing a table its manifest names -> no:unreadable (failed is not 'empty')" || bad "M: broken oldgen should say no:unreadable, got '$(_offline_sync_seed_state seedbroken "$DEST_M")'"
unset OFFLINE_SYNC_SEED_OLDGEN

# N: REQUIRE_SEED against that broken oldgen refuses and leaves nothing.
DEST_N="$WORK/dest-n"
if OFFLINE_SYNC_SEED_OLDGEN=1 OFFLINE_SYNC_REQUIRE_SEED=1 _offline_backup_sync "seedbroken" "$DEST_N"; then bad "N: a broken oldgen under REQUIRE_SEED must refuse"; else ok "N: broken oldgen under REQUIRE_SEED -> refuses"; fi
[ ! -e "$DEST_N" ] && ok "N: no dest was created" || bad "N: dest exists"

# O: _offline_sync_seed_build — a seed that does not close is removed, not used.
mkdir -p "$WORK/og-short"
cp "$OG_H/manifest" "$WORK/og-short/manifest"
if _offline_sync_seed_build "$WORK/og-short" "$WORK/seed-o" 2>/dev/null; then bad "O: a seed whose manifest names tables that are absent must not build"; else ok "O: seed_build refuses an oldgen whose tables are missing"; fi
[ ! -e "$WORK/seed-o" ] && ok "O: the half-built seed dir was removed" || bad "O: the half-built seed dir was left behind"

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
# ga-yct7r1: dolt-s3-backup.sh now has a SECOND, earlier call site for
# `_offline_backup_sync "$db"` — inside _sync_with_stale_manifest_recovery's
# own definition, which (like every function def) sits textually before the
# main per-db loop this drift-guard actually cares about. `head -1` would
# grab that new, earlier call site and false-positive-fail this check even
# though the connection-timeout branch's own wiring is untouched. The main
# loop's call is always the LAST occurrence in the file (function defs
# precede the loop that uses them), so `tail -1` re-targets the same call
# site this check originally meant to verify.
OFFLINE_CALL_LINE=$(grep -nF '_offline_backup_sync "$db"' "$S3_SCRIPT" | tail -1 | cut -d: -f1)
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
# Order the three steps inside _run_reseed only (ga-7vmcr1). The file carries
# other 'backup restore' calls above it -- _maybe_promote_new_after_primary_release
# (ga-qh8gkw) verifies with its own restore -- so a file-wide `head -1` picks up
# that one instead of the reseed flow's Passo 2 restore. The body is printed as
# "<file line>:<text>" so the reported numbers stay real file lines. If
# _run_reseed is missing the body is empty, every line comes back empty and the
# guard goes red instead of passing on nothing.
RESEED_BODY=$(awk '/^_run_reseed\(\)/ {f=1} f {print NR ":" $0} f && /^}/ {exit}' "$RESEED_SCRIPT")
SYNC_CALL_LINE=$(printf '%s\n' "$RESEED_BODY" | grep -F '_offline_backup_sync "$DB" "$NEW_DIR"' | head -1 | cut -d: -f1)
RESTORE_LINE=$(printf '%s\n' "$RESEED_BODY" | grep -F 'backup restore' | head -1 | cut -d: -f1)
MV_LINE=$(printf '%s\n' "$RESEED_BODY" | grep -F 'mv "$BACKUP_DIR" "$OLD_DIR"' | head -1 | cut -d: -f1)
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
