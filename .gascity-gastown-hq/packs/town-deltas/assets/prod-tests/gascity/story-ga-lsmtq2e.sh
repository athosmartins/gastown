#!/usr/bin/env bash
# prod-tests/gascity/story-ga-lsmtq2e.sh — prod test for ga-lsmtq2e: the sticky-ENOSPC fix of the
# managed Dolt (gascity #7976 / e8547dc572, ENOSPC piece only), ported to the LOCAL pack copies.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-lsmtq2e). Exits 0 on pass. `df` is a stub on PATH, so
# the test needs no real disk pressure and never touches Dolt, a database, `gc`, or the city's own dolt.log.
#
# Rule under test: ENOSPC in the dolt.log tail keeps refusing recovery/restart ONLY while the Dolt data
# dir has less than GC_DOLT_WARN_FREE_BYTES (default 2 GiB) free. Free >= floor -> allowed. Free below
# the floor, or unreadable -> keeps refusing (the inert state).
#
# What it runs on: the `bd` pack is REQUIRED here, so gc re-materializes dolt-enospc.sh and gc-beads-bd.sh from its
# binary and an edit there is put back within seconds (seen 28/11): the port cannot live in .gc/system/packs until
# the engine window. So: if the live packs carry the port (the engine brought it), test them; if they carry none,
# apply the tracked patch to a scratch copy of the live files and test that (this also proves the patch still
# applies to the deployed base); a half-applied or unapplicable state fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
PACKS="${PACKS_UNDER_TEST:-$CITY/.gc/system/packs}"
PATCH="${PATCH_UNDER_TEST:-$HERE/../../../../../docs/pending-engine-window/ga-lsmtq2e-dolt-enospc-headroom.patch}"
FILES="bd/assets/scripts/dolt-enospc.sh bd/assets/scripts/gc-beads-bd.sh dolt/commands/restart/run.sh"

log()  { echo "[prod-test:gascity ga-lsmtq2e] $*"; }
fail() { echo "[prod-test:gascity ga-lsmtq2e] FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-lsmtq2e.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

for f in $FILES; do
  [ -r "$PACKS/$f" ] || fail "missing: $PACKS/$f"
  sh -n "$PACKS/$f" || fail "does not parse: $PACKS/$f"
done
ported=0
grep -q 'enospc_disk_has_headroom' "$PACKS/bd/assets/scripts/dolt-enospc.sh" && ported=$((ported + 1))
grep -q 'enospc_disk_has_headroom' "$PACKS/bd/assets/scripts/gc-beads-bd.sh" && ported=$((ported + 1))
grep -q 'GC_DOLT_WARN_FREE_BYTES' "$PACKS/dolt/commands/restart/run.sh" && ported=$((ported + 1))
case "$ported" in
  3) log "the packs carry the port (engine window done): testing them as they are" ;;
  0) [ -r "$PATCH" ] || fail "the packs carry no port and the tracked patch is unreadable: $PATCH"
     for f in $FILES; do mkdir -p "$TMP/pk/$(dirname "$f")" && cp -p "$PACKS/$f" "$TMP/pk/$f" || fail "cannot copy $f"; done
     (cd "$TMP/pk" && patch -s -p1 < "$PATCH") || fail "the packs carry no port AND the tracked patch no longer applies to them"
     PACKS="$TMP/pk"; log "the packs carry no port (expected before the engine window): testing the tracked patch applied to a scratch copy" ;;
  *) fail "the packs carry the port in $ported of 3 files: half applied" ;;
esac
ENOSPC_SH="$PACKS/bd/assets/scripts/dolt-enospc.sh"
BEADS_BD="$PACKS/bd/assets/scripts/gc-beads-bd.sh"
RESTART="$PACKS/dolt/commands/restart/run.sh"
for f in $FILES; do
  case "$f" in dolt/*) grep -q 'GC_DOLT_WARN_FREE_BYTES' "$PACKS/$f" ;; *) grep -q 'enospc_disk_has_headroom' "$PACKS/$f" ;; esac \
    || fail "no free-space check in $PACKS/$f"
done
log "the three files parse and carry the free-space check"

mkdir -p "$TMP/bin" "$TMP/data"

# `df` stub: DF_AVAIL_KB is the answer; DF_MODE=empty prints nothing and fails, =garbage prints text.
# It records the directory it was asked about, so the test can tell WHICH dir the check measured.
cat > "$TMP/bin/df" <<'EOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "$last" > "${DF_ASKED:?}"
case "${DF_MODE:-ok}" in
  empty)   exit 1 ;;
  garbage) echo "df: weird"; echo "x y z not-a-number"; exit 0 ;;
esac
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/stub 999999999 1 ${DF_AVAIL_KB:?} 1% /"
EOF
chmod +x "$TMP/bin/df"
export DF_ASKED="$TMP/df-asked"
LOG_ENOSPC="$TMP/enospc.log";  printf 'ok\nError: no space left on device\n' > "$LOG_ENOSPC"
LOG_CLEAN="$TMP/clean.log";    printf 'started\nlistening\n' > "$LOG_CLEAN"
GIB=$((1024 * 1024))   # KiB in one GiB

# skip <logfile> <avail_kb|-> [env...]: runs the detector in a clean subshell; echoes "skip" (0) or "allow" (1).
# $SRC is the file that defines recovery_should_skip_due_to_enospc.
verdict() {
  local logf="$1" kb="$2"; shift 2
  ( export PATH="$TMP/bin:$PATH" LOG_FILE="$logf" DATA_DIR="$TMP/data" DF_AVAIL_KB="$kb"
    unset GC_DOLT_WARN_FREE_BYTES; for kv in "$@"; do export "${kv?}"; done
    . "$SRC"
    if recovery_should_skip_due_to_enospc; then echo skip; else echo allow; fi )
}
expect() { # expect <want> <what> <logf> <kb> [env...]
  local want="$1" what="$2"; shift 2
  local got; got=$(verdict "$@")
  [ "$got" = "$want" ] || fail "[$LABEL] $what: wanted '$want', got '$got'"
}

table() {
  # the Mayor's required cases
  expect allow "ENOSPC in the tail, 3 GiB free (>= 2 GiB floor) -> recovery allowed" "$LOG_ENOSPC" $((3 * GIB))
  expect allow "exactly the floor (2 GiB) free -> allowed"                           "$LOG_ENOSPC" $((2 * GIB))
  expect skip  "ENOSPC, 1 GiB free (< floor) -> keeps refusing"                      "$LOG_ENOSPC" $((1 * GIB))
  expect skip  "ENOSPC, 2 GiB minus 1 KiB free -> keeps refusing"                    "$LOG_ENOSPC" $((2 * GIB - 1))
  DF_MODE=empty   expect skip "ENOSPC, df fails -> keeps refusing (free space unreadable)"   "$LOG_ENOSPC" 1
  DF_MODE=garbage expect skip "ENOSPC, df answers garbage -> keeps refusing"                 "$LOG_ENOSPC" 1
  expect allow "no ENOSPC in the tail -> allowed whatever the disk"                  "$LOG_CLEAN" 1
  expect allow "no ENOSPC, even with df unreadable"                                  "$LOG_CLEAN" 1 DF_MODE=empty
  expect allow "log file missing -> allowed (nothing to refuse on)"                  "$TMP/nope.log" $((1 * GIB))
  # the floor knob and its sanitising: a bad value must never switch the refusal off
  expect allow "floor 1 GiB (GC_DOLT_WARN_FREE_BYTES) and 1 GiB free -> allowed"     "$LOG_ENOSPC" $((1 * GIB)) GC_DOLT_WARN_FREE_BYTES=1073741824
  expect skip  "floor 8 GiB and 3 GiB free -> keeps refusing"                        "$LOG_ENOSPC" $((3 * GIB)) GC_DOLT_WARN_FREE_BYTES=8589934592
  expect skip  "floor 0 means default, not 'no floor': 1 GiB free keeps refusing"    "$LOG_ENOSPC" $((1 * GIB)) GC_DOLT_WARN_FREE_BYTES=0
  expect skip  "floor 'abc' means default: 1 GiB free keeps refusing"                "$LOG_ENOSPC" $((1 * GIB)) GC_DOLT_WARN_FREE_BYTES=abc
  expect skip  "floor with 19 digits means default (no overflow)"                    "$LOG_ENOSPC" $((1 * GIB)) GC_DOLT_WARN_FREE_BYTES=9999999999999999999
  expect skip  "floor 02147483648 is decimal, not octal: 1 GiB free keeps refusing"  "$LOG_ENOSPC" $((1 * GIB)) GC_DOLT_WARN_FREE_BYTES=02147483648
  expect allow "floor 010 is decimal 10 bytes, not octal 8: allowed with 1 GiB"      "$LOG_ENOSPC" $((1 * GIB)) GC_DOLT_WARN_FREE_BYTES=010
  # which dir is measured: DATA_DIR when it is a directory, else the dir of the log
  : > "$DF_ASKED"; verdict "$LOG_ENOSPC" $((3 * GIB)) >/dev/null
  [ "$(cat "$DF_ASKED")" = "$TMP/data" ] || fail "[$LABEL] measured '$(cat "$DF_ASKED")', wanted the data dir $TMP/data"
  : > "$DF_ASKED"; ( DATA_DIR="$TMP/no-such-dir"; verdict "$LOG_ENOSPC" $((3 * GIB)) DATA_DIR="$TMP/no-such-dir" ) >/dev/null
  [ "$(cat "$DF_ASKED")" = "$TMP" ] || fail "[$LABEL] with no data dir it measured '$(cat "$DF_ASKED")', wanted the log's dir $TMP"
}

LABEL="dolt-enospc.sh"; SRC="$ENOSPC_SH"; table
log "dolt-enospc.sh: the table holds (allow >= floor; refuse < floor, unreadable, bad floor)"

# the inline fallback of gc-beads-bd.sh (used when the helper is not readable) must answer the same
FALLBACK="$TMP/fallback.sh"
awk '/^    recovery_should_skip_due_to_enospc\(\) \{/ {on=1} on && /^fi$/ {exit} on {sub(/^    /,""); print}' "$BEADS_BD" > "$FALLBACK"
grep -q 'enospc_disk_has_headroom()' "$FALLBACK" && grep -q '^recovery_should_skip_due_to_enospc()' "$FALLBACK" \
  || fail "could not extract the inline fallback from gc-beads-bd.sh"
LABEL="gc-beads-bd.sh fallback"; SRC="$FALLBACK"; table
log "gc-beads-bd.sh inline fallback: same table"

# restart/run.sh end to end, with a stub gc-beads-bd that only records stop/start
mkdir -p "$TMP/city/stub" "$TMP/city/.gc/runtime"
cp "$ENOSPC_SH" "$TMP/city/stub/dolt-enospc.sh"
printf '#!/bin/sh\necho "$1" >> "%s"\nexit 0\n' "$TMP/calls" > "$TMP/city/stub/gc-beads-bd.sh"
chmod +x "$TMP/city/stub/gc-beads-bd.sh"
run_restart() { # run_restart <avail_kb> [args...] -> sets RC, ERR; $TMP/calls has what was called
  local kb="$1"; shift; : > "$TMP/calls"
  ERR=$(PATH="$TMP/bin:$PATH" DF_AVAIL_KB="$kb" GC_CITY_PATH="$TMP/city" GC_BEADS_BD_SCRIPT="$TMP/city/stub/gc-beads-bd.sh" \
        GC_DOLT_LOG_FILE="$LOG_ENOSPC" GC_DOLT_DATA_DIR="$TMP/data" sh "$RESTART" "$@" 2>&1 >/dev/null); RC=$?
}
run_restart $((1 * GIB))
[ "$RC" = 1 ] && [ ! -s "$TMP/calls" ] || fail "restart: ENOSPC + 1 GiB free must refuse before any stop (rc=$RC, calls: $(cat "$TMP/calls"))"
case "$ERR" in *GC_DOLT_WARN_FREE_BYTES*) ;; *) fail "restart refusal does not say when it lifts: $ERR" ;; esac
run_restart $((3 * GIB))
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$TMP/calls")" = "stop start " ] || fail "restart: ENOSPC + 3 GiB free must restart (rc=$RC, calls: $(cat "$TMP/calls"), err: $ERR)"
run_restart $((1 * GIB)) --force
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$TMP/calls")" = "stop start " ] || fail "restart --force still overrides the refusal (rc=$RC, err: $ERR)"
DF_MODE=empty run_restart 1
[ "$RC" = 1 ] && [ ! -s "$TMP/calls" ] || fail "restart: df unreadable + ENOSPC must keep refusing (rc=$RC)"
[ "$(cat "$DF_ASKED")" = "$TMP/data" ] || fail "restart measured '$(cat "$DF_ASKED")', wanted GC_DOLT_DATA_DIR $TMP/data"
log "restart/run.sh: refuses <floor and unreadable, restarts >= floor, --force still overrides"

log "PASS"
exit 0
