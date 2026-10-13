#!/bin/bash
# log-reaper.selftest.sh — unit + end-to-end tests for log-reaper.sh.
#
# Hermetic: sources the script as a LIBRARY (LOG_REAPER_LIB=1) so main()
# never runs at source time, points LOG at a throwaway path. Every main()
# scenario below points LOG_REAPER_PATHS at synthetic files under a disposable
# tmpdir — never the real six production log paths.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/log-reaper.sh"

export LOG_REAPER_LIB=1
export LOG_REAPER_LOG="/tmp/log-reaper-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

# Captured immediately after the ONLY source of this file, before any test
# below reassigns LOG_REAPER_REAL_DEFAULT_PATHS for hermetic fixture
# scenarios — mirrors scratchpad-reaper.selftest.sh's own
# PRODUCTION_REAL_DEFAULT_ROOT capture (ga-h565g production-constant check
# near the end of this file).
PRODUCTION_REAL_DEFAULT_PATHS="$LOG_REAPER_REAL_DEFAULT_PATHS"
PRODUCTION_CAP_REAL_DEFAULT_PATHS="$LOG_REAPER_CAP_REAL_DEFAULT_PATHS"
# Library mode must come up with NO capped paths (ga-52drsg): a selftest that
# sources the script and runs main() with PROD=1 must never reach the city's
# real logs through the second class.
CAP_PATHS_AT_SOURCE="$LOG_REAPER_CAP_PATHS"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== log-reaper.selftest.sh ==="

# ── _should_rotate: numeric size vs threshold, boundary inclusive ───────────
_should_rotate 100 50          && ok "should_rotate: size > threshold → true"                              || bad "100 vs 50 should rotate"
_should_rotate 50 50           && ok "should_rotate: size == threshold → true (boundary inclusive)"         || bad "exactly-at-threshold should be inclusive"
_should_rotate 49 50           && bad "should_rotate: size < threshold must NOT rotate"                     || ok "should_rotate: 49 vs 50 → false"
_should_rotate "" 50           && bad "should_rotate: empty size must NEVER authorize (fail toward keep)"   || ok "should_rotate: empty size → false"
_should_rotate "abc" 50        && bad "should_rotate: non-numeric size must NEVER authorize"                || ok "should_rotate: non-numeric size → false"
_should_rotate 100 ""          && bad "should_rotate: empty threshold must NEVER authorize"                 || ok "should_rotate: empty threshold → false"
_should_rotate 100 "abc"       && bad "should_rotate: non-numeric threshold must NEVER authorize"           || ok "should_rotate: non-numeric threshold → false"

echo ""
echo "=== _prod_sentinel_active: same ga-h565g pattern as the sibling reapers ==="
_prod_sentinel_active "a
b" "a
b" ""  && ok "prod_sentinel_active: paths==real default, no PROD → active (blocks)"          || bad "paths==default+no PROD should be active"
_prod_sentinel_active "a
b" "a
b" "0" && ok "prod_sentinel_active: paths==real default, PROD=0 → active (blocks)"           || bad "paths==default+PROD=0 should be active"
_prod_sentinel_active "a
b" "a
b" "1" && bad "prod_sentinel_active: PROD=1 must disable the sentinel even when paths==default" || ok "prod_sentinel_active: paths==default+PROD=1 → not active (allowed)"
_prod_sentinel_active "x" "a
b" ""      && bad "prod_sentinel_active: a DIFFERENT (fixture) path list must never trip the sentinel" || ok "prod_sentinel_active: fixture paths != default → not active"

echo ""
echo "=== _file_size_bytes: thin stat wrapper ==="
TESTFILE="$(mktemp /tmp/log-reaper-selftest-size.XXXXXX)"
head -c 12345 /dev/zero > "$TESTFILE"
GOT="$(_file_size_bytes "$TESTFILE")"
[ "$GOT" = "12345" ] && ok "file_size_bytes: reads correct byte count" || bad "file_size_bytes: expected 12345, got '$GOT'"
GOT_MISSING="$(_file_size_bytes "/nonexistent/path-$$")"
[ -z "$GOT_MISSING" ] && ok "file_size_bytes: missing file → empty (not a crash, not zero)" || bad "file_size_bytes: missing file should be empty, got '$GOT_MISSING'"
rm -f "$TESTFILE"

echo ""
echo "=== main(): end-to-end rotation against fixture files (never real paths) ==="
FIXDIR="$(mktemp -d /tmp/log-reaper-selftest-fixture.XXXXXX)"
# Keep this fixture's default DIFFERENT from any real production path so the
# production sentinel never accidentally engages in these ordinary scenarios.
LOG_REAPER_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-marker-$$"
# shellcheck disable=SC2034  # read by main() in the sourced script
THRESHOLD_MB=1
THRESHOLD_BYTES=$(( 1 * 1024 * 1024 ))
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=1
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by _prod_sentinel_active() in the sourced script
PROD=0

BIG="$FIXDIR/big.log"
SMALL="$FIXDIR/small.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$BIG"
head -c $(( THRESHOLD_BYTES - 1024 )) /dev/zero > "$SMALL"
BIG_INODE_BEFORE="$(stat -f %i "$BIG")"

LOG_REAPER_PATHS="$BIG
$SMALL
$FIXDIR/does-not-exist.log"
: > "$LOG_REAPER_LOG"
main

BIG_SIZE_AFTER="$(_file_size_bytes "$BIG")"
[ "$BIG_SIZE_AFTER" = "0" ] && ok "main(): oversized file truncated to 0 bytes" || bad "main(): expected BIG truncated to 0, got '$BIG_SIZE_AFTER'"

BIG_INODE_AFTER="$(stat -f %i "$BIG")"
[ "$BIG_INODE_AFTER" = "$BIG_INODE_BEFORE" ] && ok "main(): truncate preserves the inode (safe for a live writer's open fd)" || bad "main(): inode changed ($BIG_INODE_BEFORE -> $BIG_INODE_AFTER) — a live writer's fd would now point at the wrong file"

BACKUP_SIZE="$(_file_size_bytes "$BIG.1")"
[ "$BACKUP_SIZE" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): backup .1 holds the pre-truncate content/size" || bad "main(): expected backup size $(( THRESHOLD_BYTES + 1024 )), got '$BACKUP_SIZE'"

SMALL_SIZE_AFTER="$(_file_size_bytes "$SMALL")"
[ "$SMALL_SIZE_AFTER" = "$(( THRESHOLD_BYTES - 1024 ))" ] && ok "main(): under-threshold file left untouched" || bad "main(): SMALL should be untouched, got size '$SMALL_SIZE_AFTER'"

grep -q "does not exist" "$LOG_REAPER_LOG" && ok "main(): missing configured path logged, not a crash" || bad "main(): expected a 'does not exist' log line for the missing fixture path"

grep -q "cycle complete: checked=3 rotated=1 skipped=1 missing=1" "$LOG_REAPER_LOG" && ok "main(): cycle summary counts are correct (checked/rotated/skipped/missing)" || bad "main(): cycle summary mismatch — got: $(grep 'cycle complete' "$LOG_REAPER_LOG")"

echo ""
echo "=== main(): DRY_RUN never mutates ==="
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
BIG="$FIXDIR/big.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$BIG"
LOG_REAPER_PATHS="$BIG"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=1
: > "$LOG_REAPER_LOG"
main
DRY_SIZE="$(_file_size_bytes "$BIG")"
[ "$DRY_SIZE" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): DRY_RUN=1 leaves an oversized file untouched" || bad "main(): DRY_RUN mutated the file — size is now '$DRY_SIZE'"
grep -q "DRY-RUN would rotate" "$LOG_REAPER_LOG" && ok "main(): DRY_RUN logs the intended action" || bad "main(): expected a 'DRY-RUN would rotate' log line"
[ ! -f "$BIG.1" ] && ok "main(): DRY_RUN creates no backup file" || bad "main(): DRY_RUN should not have created $BIG.1"
DRY_RUN=0

echo ""
echo "=== main(): ENABLED=0 is a total no-op ==="
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
BIG="$FIXDIR/big.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$BIG"
LOG_REAPER_PATHS="$BIG"
# shellcheck disable=SC2034  # read by main() in the sourced script
ENABLED=0
main
NOOP_SIZE="$(_file_size_bytes "$BIG")"
[ "$NOOP_SIZE" = "$(( THRESHOLD_BYTES + 1024 )) " ] || [ "$NOOP_SIZE" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): ENABLED=0 leaves an oversized file untouched" || bad "main(): ENABLED=0 should not mutate — size is now '$NOOP_SIZE'"
# shellcheck disable=SC2034  # read by main() in later scenarios below
ENABLED=1

echo ""
echo "=== main(): production sentinel end-to-end (ga-h565g) ==="
# Hermetic trick: reassign LOG_REAPER_REAL_DEFAULT_PATHS to a fixture path so
# this exercises the REAL main() sentinel-forcing logic without ever pointing
# at the actual six production log paths — mirrors scratchpad-reaper's own
# sentinel end-to-end scenario.
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
SENTINEL_FILE="$FIXDIR/sentinel.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$SENTINEL_FILE"
LOG_REAPER_PATHS="$SENTINEL_FILE"
LOG_REAPER_REAL_DEFAULT_PATHS="$SENTINEL_FILE"   # pretend this IS "the real default"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
# shellcheck disable=SC2034  # read by _prod_sentinel_active() in the sourced script
PROD=0
main
[ "$(_file_size_bytes "$SENTINEL_FILE")" = "$(( THRESHOLD_BYTES + 1024 ))" ] && ok "main(): paths==real-default + no PROD opt-in → sentinel blocks truncation" || bad "main(): sentinel FAILED to block — real-default-equal path truncated with no PROD opt-in"

head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$SENTINEL_FILE"
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0   # ga-h565g leak: the PRIOR main() call's sentinel forced DRY_RUN=1
            # INSIDE main() (no `local`, by design — see scratchpad-reaper's
            # own identical re-set between scenarios) and that mutation
            # persists in this shell across calls; must be reset explicitly
            # before every scenario that expects a real mutation.
PROD=1
main
[ "$(_file_size_bytes "$SENTINEL_FILE")" = "0" ] && ok "main(): PROD=1 allows the real launchd path to rotate normally" || bad "main(): PROD=1 should have allowed rotation"
# shellcheck disable=SC2034  # read by _prod_sentinel_active() via the next main() call below
PROD=0

# Non-regression: a fixture path that never equals the real default must
# rotate normally with no PROD opt-in — the sentinel must never fire for
# ordinary test paths.
rm -rf "$FIXDIR"; mkdir -p "$FIXDIR"
NONDEFAULT_FILE="$FIXDIR/nondefault.log"
head -c $(( THRESHOLD_BYTES + 1024 )) /dev/zero > "$NONDEFAULT_FILE"
# shellcheck disable=SC2034  # read by main() in the sourced script
LOG_REAPER_PATHS="$NONDEFAULT_FILE"
LOG_REAPER_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-marker-2-$$"   # deliberately NOT $NONDEFAULT_FILE
# shellcheck disable=SC2034  # read by main() in the sourced script
DRY_RUN=0
main
[ "$(_file_size_bytes "$NONDEFAULT_FILE")" = "0" ] && ok "main(): fixture path (!= real default) rotates normally, sentinel inactive" || bad "main(): fixture path should have rotated — sentinel misfired"

rm -rf "$FIXDIR"


echo ""
echo "=== tail-cap class (ga-52drsg): pure helpers ==="
[ -z "$CAP_PATHS_AT_SOURCE" ] && ok "library mode: capped-path list is empty unless a test names it" || bad "library mode must not default to the real capped paths, got '$CAP_PATHS_AT_SOURCE'"
[ "$(_mb_to_bytes 20 7)" = "20971520" ]   && ok "mb_to_bytes: 20 -> 20971520"                                  || bad "mb_to_bytes 20"
[ "$(_mb_to_bytes "" 7)" = "7340032" ]    && ok "mb_to_bytes: empty -> default"                                 || bad "mb_to_bytes empty should use the default"
[ "$(_mb_to_bytes abc 7)" = "7340032" ]   && ok "mb_to_bytes: non-numeric -> default"                           || bad "mb_to_bytes abc should use the default"
[ "$(_mb_to_bytes 0 7)" = "7340032" ]     && ok "mb_to_bytes: 0 -> default (a cap of 0 would empty every log every cycle)" || bad "mb_to_bytes 0 should use the default"
[ "$(_mb_to_bytes -5 7)" = "7340032" ]    && ok "mb_to_bytes: negative -> default"                              || bad "mb_to_bytes -5 should use the default"
CAP20=$(( 20 * 1024 * 1024 ))
[ "$(_cap_keep_bytes 10 "$CAP20")" = "$(( 10 * 1024 * 1024 ))" ] && ok "cap_keep_bytes: 10MB under a 20MB cap -> 10MB"        || bad "cap_keep_bytes 10/20"
[ "$(_cap_keep_bytes 20 "$CAP20")" = "$(( 10 * 1024 * 1024 ))" ] && ok "cap_keep_bytes: keep == cap -> half the cap (never re-trips)" || bad "cap_keep_bytes 20/20"
[ "$(_cap_keep_bytes 30 "$CAP20")" = "$(( 10 * 1024 * 1024 ))" ] && ok "cap_keep_bytes: keep > cap -> half the cap"                  || bad "cap_keep_bytes 30/20"
[ "$(_cap_keep_bytes abc "$CAP20")" = "$(( 10 * 1024 * 1024 ))" ] && ok "cap_keep_bytes: non-numeric -> default 10MB"                     || bad "cap_keep_bytes abc/20"
[ "$(_cap_keep_bytes 10 "$(( 5 * 1024 * 1024 ))")" = "$(( 5 * 1024 * 1024 / 2 ))" ] && ok "cap_keep_bytes: default 10MB over a 5MB cap -> half of 5MB" || bad "cap_keep_bytes 10/5"

echo ""
echo "=== size knobs: a leading zero is the decimal number it looks like (ga-52drsg gate-fix 1) ==="
# Inside $(( )) bash reads "08"/"09" as invalid octal (error, EMPTY result) and
# "010" as 8. Each assertion captures stderr too: the value must come out right
# AND silently. Defaults differ from every expected value so a fallback cannot
# pass for a correct read.
[ "$(_mb_to_bytes 08 7 2>&1)" = "$(( 8 * 1024 * 1024 ))" ]   && ok "mb_to_bytes: 08 -> 8MB (not an octal error, not empty)"        || bad "mb_to_bytes 08 -> '$(_mb_to_bytes 08 7 2>&1)'"
[ "$(_mb_to_bytes 09 7 2>&1)" = "$(( 9 * 1024 * 1024 ))" ]   && ok "mb_to_bytes: 09 -> 9MB"                                        || bad "mb_to_bytes 09 -> '$(_mb_to_bytes 09 7 2>&1)'"
[ "$(_mb_to_bytes 010 7 2>&1)" = "$(( 10 * 1024 * 1024 ))" ] && ok "mb_to_bytes: 010 -> 10MB (octal would silently give 8MB)"       || bad "mb_to_bytes 010 -> '$(_mb_to_bytes 010 7 2>&1)'"
[ "$(_mb_to_bytes 007 3 2>&1)" = "$(( 7 * 1024 * 1024 ))" ]  && ok "mb_to_bytes: 007 -> 7MB (a read, not the default 3)"            || bad "mb_to_bytes 007 -> '$(_mb_to_bytes 007 3 2>&1)'"
[ "$(_mb_to_bytes 0000000000008 7 2>&1)" = "$(( 8 * 1024 * 1024 ))" ] && ok "mb_to_bytes: many leading zeros -> 8MB"                  || bad "mb_to_bytes 0000000000008 -> '$(_mb_to_bytes 0000000000008 7 2>&1)'"
[ "$(_mb_to_bytes 000 7 2>&1)" = "$(( 7 * 1024 * 1024 ))" ]  && ok "mb_to_bytes: 000 is 0, not positive -> default"                 || bad "mb_to_bytes 000 -> '$(_mb_to_bytes 000 7 2>&1)'"
# The same arithmetic wraps on a huge value and hands back a plausible (here
# NEGATIVE) number; an oversized knob must fall to the default instead.
[ "$(_mb_to_bytes 9999999999999 7 2>&1)" = "$(( 7 * 1024 * 1024 ))" ] && ok "mb_to_bytes: 13 digits (would wrap negative) -> default"  || bad "mb_to_bytes 9999999999999 -> '$(_mb_to_bytes 9999999999999 7 2>&1)'"
[ "$(_mb_to_bytes 99999999999 7 2>&1)" = "$(( 7 * 1024 * 1024 ))" ]   && ok "mb_to_bytes: 11 digits (would wrap to a bogus size) -> default" || bad "mb_to_bytes 99999999999 -> '$(_mb_to_bytes 99999999999 7 2>&1)'"
[ "$(_mb_to_bytes 9999999 7 2>&1)" = "$(( 9999999 * 1024 * 1024 ))" ] && ok "mb_to_bytes: 7 digits is the largest accepted"      || bad "mb_to_bytes 9999999 -> '$(_mb_to_bytes 9999999 7 2>&1)'"
[ "$(_mb_to_bytes 10000000 7 2>&1)" = "$(( 7 * 1024 * 1024 ))" ]     && ok "mb_to_bytes: 8 digits is over the limit -> default"    || bad "mb_to_bytes 10000000 -> '$(_mb_to_bytes 10000000 7 2>&1)'"
for v in 1 08 09 010 0000000008 9999999; do
  _mb_valid "$v" && ok "mb_valid: '$v' is a usable size" || bad "mb_valid: '$v' should be usable"
done
for v in "" abc 0 00 000 -5 1.5 " 5" "5 " 10000000 99999999999999999999; do
  _mb_valid "$v" && bad "mb_valid: '$v' must NOT be usable" || ok "mb_valid: '$v' is not a usable size"
done
[ "$(_cap_keep_bytes 08 "$CAP20" 2>&1)" = "$(( 8 * 1024 * 1024 ))" ]  && ok "cap_keep_bytes: 08 -> 8MB (was an octal error and an empty keep)" || bad "cap_keep_bytes 08 -> '$(_cap_keep_bytes 08 "$CAP20" 2>&1)'"
[ "$(_cap_keep_bytes 010 "$CAP20" 2>&1)" = "$(( 10 * 1024 * 1024 ))" ] && ok "cap_keep_bytes: 010 -> 10MB (was 8MB)"                              || bad "cap_keep_bytes 010 -> '$(_cap_keep_bytes 010 "$CAP20" 2>&1)'"

echo ""
echo "=== _cap_limits_usable: the cap/keep pair is checked before any file is touched ==="
_cap_limits_usable 20971520 10485760 && ok "cap_limits_usable: 20MB cap / 10MB keep -> usable"           || bad "cap_limits_usable: a sane pair was refused"
_cap_limits_usable 2 1               && ok "cap_limits_usable: smallest pair (2/1) -> usable"             || bad "cap_limits_usable 2/1"
refuse_limits() { _cap_limits_usable "$1" "$2" && bad "cap_limits_usable: cap='$1' keep='$2' must be refused" || ok "cap_limits_usable: cap='$1' keep='$2' refused"; }
refuse_limits ""    5      # empty cap: an unreadable value is not a number
refuse_limits 5     ""     # empty keep: this is the reviewer's repro (tail -c "" -> "no room" -> file emptied)
refuse_limits abc   5
refuse_limits 5     abc
refuse_limits "1 2" 1
refuse_limits 0     0
refuse_limits 5     0      # keep 0 would empty the file on purpose
refuse_limits 0     5
refuse_limits 100   100    # keep == cap: the file would be over the cap again right after
refuse_limits 100   200
refuse_limits -5    -9
refuse_limits 100   -5

echo ""
echo "=== tail-cap class: _tail_cap_one keeps the END of the file, in place ==="
CAPDIR="$(mktemp -d /tmp/log-reaper-selftest-cap.XXXXXX)"
: > "$LOG_REAPER_LOG"
mkfile() { awk -v n="$2" 'BEGIN{for(i=1;i<=n;i++) printf "line %07d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i}' > "$1"; }
KEEP=$(( 1024 * 1024 ))
F1="$CAPDIR/one.log"
mkfile "$F1" 50400                         # 54 bytes a line -> ~2.7MB
EXPECT_TAIL="$CAPDIR/expect.tail"
tail -c "$KEEP" "$F1" > "$EXPECT_TAIL"
INODE1="$(stat -f %i "$F1")"
_tail_cap_one "$F1" "$KEEP"
[ "$?" = "0" ] && ok "tail_cap_one: returns 0 (tail kept)" || bad "tail_cap_one: nonzero return"
[ "$(_file_size_bytes "$F1")" = "$KEEP" ] && ok "tail_cap_one: file is exactly keep-bytes long" || bad "tail_cap_one: size is '$(_file_size_bytes "$F1")', expected $KEEP"
cmp -s "$F1" "$EXPECT_TAIL" && ok "tail_cap_one: what stays is the LAST keep-bytes of the original, byte for byte" || bad "tail_cap_one: kept content is not the original tail"
[ "$(stat -f %i "$F1")" = "$INODE1" ] && ok "tail_cap_one: inode preserved" || bad "tail_cap_one: inode changed"
[ ! -e "$F1.tailcap.tmp" ] && ok "tail_cap_one: no side file left behind" || bad "tail_cap_one: left $F1.tailcap.tmp"
tail -n 1 "$F1" | grep -q 'line 0050400 ' && ok "tail_cap_one: newest line is still the last line" || bad "tail_cap_one: newest line lost"

echo ""
echo "=== tail-cap class: outcomes that are NOT 'tail kept' are reported as what they are ==="
# No room to copy the tail aside: simulated by putting a directory where the side
# file must go. Space outranks history, so the file is emptied -- and the return
# code and the log line must say EMPTY, never "last N kept".
F4="$CAPDIR/noroom.log"
mkfile "$F4" 50400
mkdir "$F4.tailcap.tmp"
_tail_cap_one "$F4" "$KEEP"; RC4=$?
[ "$RC4" = "2" ] && [ "$(_file_size_bytes "$F4")" = "0" ] && ok "tail_cap_one: tail cannot be copied aside -> file emptied, rc 2" || bad "tail_cap_one: no-room case rc=$RC4 size='$(_file_size_bytes "$F4")'"
rmdir "$F4.tailcap.tmp"
CAP_MB=2; KEEP_MB=1; LOG_REAPER_PATHS=""; LOG_REAPER_CAP_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-cap-marker-$$"; ENABLED=1; DRY_RUN=0; PROD=0
mkfile "$F4" 60000
mkdir "$F4.tailcap.tmp"
LOG_REAPER_CAP_PATHS="$F4"; : > "$LOG_REAPER_LOG"
main
grep -q "capped: $F4 .*EMPTY: the tail could not be copied aside (no room?)" "$LOG_REAPER_LOG" && ! grep -q "last .* kept" "$LOG_REAPER_LOG" && ok "main(): the no-room cut is logged as EMPTY, not as a kept tail" || bad "main(): no-room outcome mislabelled — log: $(cat "$LOG_REAPER_LOG")"
rmdir "$F4.tailcap.tmp"
# A path that vanished after the stat must not be re-created by the truncate.
_tail_cap_one "$CAPDIR/vanished.log" "$KEEP"; RCV=$?
[ "$RCV" = "1" ] && [ ! -e "$CAPDIR/vanished.log" ] && ok "tail_cap_one: a vanished file is not re-created as an empty one (rc 1)" || bad "tail_cap_one: vanished file rc=$RCV exists=$([ -e "$CAPDIR/vanished.log" ] && echo yes || echo no)"

echo ""
echo "=== tail-cap class: a keep that is not a positive byte count never reaches the 'no room' cut (ga-52drsg gate-fix 1) ==="
# `tail -c ""` fails like a full disk does, and the failure branch EMPTIES the
# file and says "no room". A keep nobody could read is "do not know what to keep",
# not "keep nothing": refuse (rc 4) before the file or the side file is touched.
F5="$CAPDIR/badkeep.log"
for badkeep in "" abc 0 -5 08 "1 2" 1.5; do
  mkfile "$F5" 50400; SUM5="$(cksum < "$F5")"
  _tail_cap_one "$F5" "$badkeep"; RC5=$?
  [ "$RC5" = "4" ] && [ "$(cksum < "$F5")" = "$SUM5" ] && [ ! -e "$F5.tailcap.tmp" ] && ok "tail_cap_one: keep='$badkeep' -> rc 4, file byte-identical, no side file" || bad "tail_cap_one: keep='$badkeep' rc=$RC5 size='$(_file_size_bytes "$F5")' (expected rc 4 and the file untouched)"
done

echo ""
echo "=== tail-cap class: a writer that holds the file open (O_APPEND) keeps working ==="
F2="$CAPDIR/live.log"
mkfile "$F2" 50400
exec 7>>"$F2"                              # `>>` opens O_APPEND, like launchd StandardOutPath and the scripts' own logs
_tail_cap_one "$F2" "$KEEP"
echo "written after the cap" >&7
exec 7>&-
[ "$(_file_size_bytes "$F2")" = "$(( KEEP + 22 ))" ] && ok "live O_APPEND writer: file is keep + the one new line, not sparse" || bad "live O_APPEND writer: size is '$(_file_size_bytes "$F2")', expected $(( KEEP + 22 ))"
[ "$(tail -n 1 "$F2")" = "written after the cap" ] && ok "live O_APPEND writer: its post-cap line is the last line (no restart needed)" || bad "live O_APPEND writer: post-cap line missing"
[ "$(tr -d '\000' < "$F2" | wc -c | tr -d ' ')" = "$(_file_size_bytes "$F2")" ] && ok "live O_APPEND writer: no NUL holes" || bad "live O_APPEND writer: file has NUL bytes (sparse)"

echo ""
echo "=== tail-cap class: CONTROL — a writer that does NOT open O_APPEND turns the file sparse ==="
# This is the failure the header tells people to check before adding a path. If
# this scenario ever stops showing the hole, the O_APPEND warning (and this
# selftest's ability to see the problem) is stale.
F3="$CAPDIR/nonappend.log"
mkfile "$F3" 50400
exec 8>"$F3"                               # NOT append: holds its own offset
head -c 2000000 /dev/zero >&8              # writer is now at offset 2MB
_tail_cap_one "$F3" "$KEEP"
echo "x" >&8
exec 8>&-
# Writer was at offset 2,000,000 when the file was cut to 1MB; its next write
# lands there, so the file is 2,000,002 bytes again and the gap is NULs.
NONAPP_SIZE="$(_file_size_bytes "$F3")"
NONAPP_REAL="$(tr -d '\000' < "$F3" | wc -c | tr -d ' ')"
[ "$NONAPP_SIZE" = "2000002" ] && [ "$NONAPP_REAL" -lt "$NONAPP_SIZE" ] && ok "control: a non-append writer puts the file back at its old offset, with a NUL hole (documented limitation)" || bad "control: expected a sparse file of 2000002 bytes, got size '$NONAPP_SIZE', non-NUL bytes '$NONAPP_REAL'"

echo ""
echo "=== tail-cap class: main() end-to-end against fixtures ==="
CAP_MB=2
KEEP_MB=1
LOG_REAPER_PATHS=""                         # first class idle for these scenarios
LOG_REAPER_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-marker-$$"
LOG_REAPER_CAP_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-cap-marker-$$"
ENABLED=1; DRY_RUN=0; PROD=0
BIGC="$CAPDIR/big-cap.log"; SMALLC="$CAPDIR/small-cap.log"; EDGEC="$CAPDIR/edge-cap.log"
mkfile "$BIGC" 60000                        # ~3.1MB, over the 2MB cap
mkfile "$SMALLC" 30000                      # ~1.5MB, under
head -c $(( 2 * 1024 * 1024 )) /dev/zero > "$EDGEC"   # exactly the cap -> inclusive boundary
tail -c "$KEEP" "$BIGC" > "$EXPECT_TAIL"
SMALLC_SUM="$(cksum < "$SMALLC")"
BIGC_SIZE="$(_file_size_bytes "$BIGC")"
LOG_REAPER_CAP_PATHS="$BIGC
$SMALLC
$EDGEC
$CAPDIR/gone.log"
: > "$LOG_REAPER_LOG"
main
[ "$(_file_size_bytes "$BIGC")" = "$KEEP" ] && cmp -s "$BIGC" "$EXPECT_TAIL" && ok "main(): over-cap file is cut to its last keep-MB" || bad "main(): BIG not cut to its tail, size '$(_file_size_bytes "$BIGC")'"
[ "$(cksum < "$SMALLC")" = "$SMALLC_SUM" ] && ok "main(): under-cap file untouched" || bad "main(): under-cap file changed"
[ "$(_file_size_bytes "$EDGEC")" = "$KEEP" ] && ok "main(): a file exactly at the cap is capped (boundary inclusive)" || bad "main(): at-cap file size '$(_file_size_bytes "$EDGEC")'"
grep -q "log-cap: $CAPDIR/gone.log does not exist" "$LOG_REAPER_LOG" && ok "main(): missing capped path logged, not a crash" || bad "main(): no 'does not exist' line for the missing capped path"
grep -q "cap cycle complete: checked=4 capped=2 skipped=1 missing=1 unreadable=0 failed=0 freed_bytes=$(( BIGC_SIZE - KEEP + 2 * 1024 * 1024 - KEEP )) cap_mb=2 keep_mb=1 dry_run=0" "$LOG_REAPER_LOG" && ok "main(): cap summary counts and freed bytes are right" || bad "main(): cap summary mismatch — got: $(grep 'cap cycle complete' "$LOG_REAPER_LOG")"

echo ""
echo "=== tail-cap class: DRY_RUN, ENABLED=0 and the production sentinel never mutate ==="
mkfile "$BIGC" 60000; DRY_SUM="$(cksum < "$BIGC")"
DRY_RUN=1; LOG_REAPER_CAP_PATHS="$BIGC"; : > "$LOG_REAPER_LOG"
main
[ "$(cksum < "$BIGC")" = "$DRY_SUM" ] && ok "main(): DRY_RUN=1 leaves a capped-class file untouched" || bad "main(): DRY_RUN mutated a capped-class file"
grep -q "DRY-RUN would cap" "$LOG_REAPER_LOG" && ok "main(): DRY_RUN logs the intended cap" || bad "main(): no 'DRY-RUN would cap' line"
[ ! -e "$BIGC.tailcap.tmp" ] && ok "main(): DRY_RUN creates no side file" || bad "main(): DRY_RUN left a side file"
DRY_RUN=0

ENABLED=0; main; ENABLED=1
[ "$(cksum < "$BIGC")" = "$DRY_SUM" ] && ok "main(): ENABLED=0 is a total no-op for the capped class too" || bad "main(): ENABLED=0 still capped a file"

LOG_REAPER_CAP_REAL_DEFAULT_PATHS="$BIGC"    # pretend this IS the real capped list
PROD=0; DRY_RUN=0; : > "$LOG_REAPER_LOG"
main
[ "$(cksum < "$BIGC")" = "$DRY_SUM" ] && ok "main(): capped list == real default + no PROD opt-in -> sentinel blocks the cap" || bad "main(): sentinel failed to block the capped class"
grep -q "SENTINEL: capped-log list" "$LOG_REAPER_LOG" && ok "main(): the sentinel says so in the log" || bad "main(): no capped-class SENTINEL line"
DRY_RUN=0; PROD=1
main
[ "$(_file_size_bytes "$BIGC")" = "$KEEP" ] && ok "main(): PROD=1 lets the real capped list through" || bad "main(): PROD=1 did not cap, size '$(_file_size_bytes "$BIGC")'"
PROD=0

echo ""
echo "=== size knobs end to end: '08' is 8, an unreadable limit touches NO file (ga-52drsg gate-fix 1) ==="
# Reset what the sentinel scenarios above left behind, so these fixtures are
# ordinary (non-production) paths. Every main() here runs in a subshell: on the
# pre-fix script an octal error aborts the run, and it must not take the
# selftest down with it.
LOG_REAPER_CAP_REAL_DEFAULT_PATHS="/tmp/log-reaper-nonexistent-cap-marker-3-$$"
LOG_REAPER_PATHS=""; ENABLED=1; DRY_RUN=0; PROD=0
ERRF="$CAPDIR/stderr.out"

# CAP_MB=08: pre-fix cap_bytes came back EMPTY, the file was counted "skipped" and
# the cycle read like a healthy one. 9,000,000 bytes is over 8 MiB (8,388,608).
F6="$CAPDIR/cap08.log"; head -c 9000000 /dev/zero > "$F6"
CAP_MB=08; KEEP_MB=1; LOG_REAPER_CAP_PATHS="$F6"; : > "$LOG_REAPER_LOG"
( main ) 2>"$ERRF"
[ "$(_file_size_bytes "$F6")" = "$KEEP" ] && ok "CAP_MB=08: a 9,000,000-byte file is over the 8MB cap and is cut to keep" || bad "CAP_MB=08: file is '$(_file_size_bytes "$F6")' bytes, expected $KEEP — log: $(grep 'cap cycle' "$LOG_REAPER_LOG")"
[ ! -s "$ERRF" ] && ok "CAP_MB=08: no arithmetic error on stderr" || bad "CAP_MB=08: stderr says: $(cat "$ERRF")"

# KEEP_MB=08 (CAP_MB=10): pre-fix keep came back EMPTY, `tail -c ""` failed, the
# "no room" branch emptied the WHOLE file and logged an invented cause.
F7="$CAPDIR/keep08.log"; head -c 11000000 /dev/zero > "$F7"
CAP_MB=10; KEEP_MB=08; LOG_REAPER_CAP_PATHS="$F7"; : > "$LOG_REAPER_LOG"
( main ) 2>"$ERRF"
[ "$(_file_size_bytes "$F7")" = "$(( 8 * 1024 * 1024 ))" ] && ok "KEEP_MB=08: the file keeps its last 8MB — not emptied" || bad "KEEP_MB=08: file is '$(_file_size_bytes "$F7")' bytes, expected $(( 8 * 1024 * 1024 )) — log: $(grep -E 'capped|cap cycle' "$LOG_REAPER_LOG")"
! grep -q "EMPTY" "$LOG_REAPER_LOG" && ok "KEEP_MB=08: the log does not report an emptied file or blame a full disk" || bad "KEEP_MB=08: log reports an emptied file: $(grep 'EMPTY' "$LOG_REAPER_LOG")"
[ ! -s "$ERRF" ] && ok "KEEP_MB=08: no arithmetic error on stderr" || bad "KEEP_MB=08: stderr says: $(cat "$ERRF")"

# KEEP_MB=010: pre-fix this was octal -> silently 8MB.
F8="$CAPDIR/keep010.log"; head -c 13000000 /dev/zero > "$F8"
CAP_MB=12; KEEP_MB=010; LOG_REAPER_CAP_PATHS="$F8"; : > "$LOG_REAPER_LOG"
( main ) 2>"$ERRF"
[ "$(_file_size_bytes "$F8")" = "$(( 10 * 1024 * 1024 ))" ] && ok "KEEP_MB=010: kept 10MB (octal would have kept 8MB)" || bad "KEEP_MB=010: file is '$(_file_size_bytes "$F8")' bytes, expected $(( 10 * 1024 * 1024 ))"

# A limit nobody can read is neither "under the cap" nor "disk full": no file is
# touched, the cause is named, and every configured path is COUNTED as failed so
# the summary cannot read like a healthy cycle. (The helper is overridden in a
# subshell to force the one state the fixed readers can no longer produce.)
F9="$CAPDIR/unusable.log"; mkfile "$F9" 60000; SUM9="$(cksum < "$F9")"
CAP_MB=2; KEEP_MB=1; LOG_REAPER_CAP_PATHS="$F9
$CAPDIR/unusable-gone.log"; : > "$LOG_REAPER_LOG"
# shellcheck disable=SC2329  # overrides the sourced function inside this subshell; main() calls it
( _cap_keep_bytes() { echo ""; }; main ) 2>/dev/null
[ "$(cksum < "$F9")" = "$SUM9" ] && [ ! -e "$F9.tailcap.tmp" ] && ok "unusable limits: the over-cap file is left byte-identical (not emptied)" || bad "unusable limits: file touched — size '$(_file_size_bytes "$F9")'"
grep -q "limits are not usable" "$LOG_REAPER_LOG" && ok "unusable limits: the log names the cause" || bad "unusable limits: no 'limits are not usable' line — log: $(cat "$LOG_REAPER_LOG")"
grep -q "cap cycle complete: checked=2 capped=0 skipped=0 missing=0 unreadable=0 failed=2 " "$LOG_REAPER_LOG" && ok "unusable limits: every configured path is counted as failed, none as skipped" || bad "unusable limits: summary mismatch — got: $(grep 'cap cycle complete' "$LOG_REAPER_LOG")"
! grep -q "^\[[^]]*\] capped: " "$LOG_REAPER_LOG" && ok "unusable limits: nothing is reported as capped" || bad "unusable limits: log claims a cap: $(grep ' capped: ' "$LOG_REAPER_LOG")"

# Second layer: with the pair check bypassed, _tail_cap_one's own refusal (rc 4)
# still keeps the file, and main() reports it as what it is -- this is also the
# end-to-end run of main()'s "FAILED to cap" arm.
: > "$LOG_REAPER_LOG"
# shellcheck disable=SC2329  # overrides the sourced functions inside this subshell; main() calls them
( _cap_limits_usable() { return 0; }; _cap_keep_bytes() { echo ""; }; main ) 2>/dev/null
[ "$(cksum < "$F9")" = "$SUM9" ] && [ ! -e "$F9.tailcap.tmp" ] && ok "pair check bypassed: _tail_cap_one still leaves the file byte-identical" || bad "pair check bypassed: file touched — size '$(_file_size_bytes "$F9")'"
grep -q "FAILED to cap: $F9 (keep_bytes='' is not a usable byte count — file NOT touched)" "$LOG_REAPER_LOG" && ok "pair check bypassed: main() logs the refusal, not 'no room'" || bad "pair check bypassed: log says: $(cat "$LOG_REAPER_LOG")"
grep -q "cap cycle complete: checked=2 capped=0 skipped=0 missing=1 unreadable=0 failed=1 " "$LOG_REAPER_LOG" && ok "pair check bypassed: the refusal is counted as failed" || bad "pair check bypassed: summary mismatch — got: $(grep 'cap cycle complete' "$LOG_REAPER_LOG")"

# A typo'd knob falls back to the default (documented), but the fallback is
# SAID, so a summary showing the raw value cannot hide which limit really ran.
F10="$CAPDIR/typo.log"; mkfile "$F10" 60000; SUM10="$(cksum < "$F10")"
CAP_MB=abc; KEEP_MB=-3; LOG_REAPER_CAP_PATHS="$F10"; : > "$LOG_REAPER_LOG"
( main ) 2>/dev/null
grep -q "LOG_REAPER_CAP_MB='abc' is not a usable size" "$LOG_REAPER_LOG" && grep -q "LOG_REAPER_KEEP_MB='-3' is not a usable size" "$LOG_REAPER_LOG" && ok "typo'd knobs: each fallback to the default is logged" || bad "typo'd knobs: fallback not logged — log: $(cat "$LOG_REAPER_LOG")"
[ "$(cksum < "$F10")" = "$SUM10" ] && ok "typo'd knobs: a 3MB file under the default 20MB cap is left alone" || bad "typo'd knobs: file changed"

# Sibling of the same read in the FIRST class: THRESHOLD_MB=08 aborted main()
# before it logged anything or reached the capped class at all.
F11="$CAPDIR/thr08.log"; head -c 9000000 /dev/zero > "$F11"
LOG_REAPER_PATHS="$F11"; LOG_REAPER_CAP_PATHS=""; THRESHOLD_MB=08; CAP_MB=2; KEEP_MB=1; : > "$LOG_REAPER_LOG"
( main ) 2>"$ERRF"
[ "$(_file_size_bytes "$F11")" = "0" ] && ok "THRESHOLD_MB=08: a 9,000,000-byte file is over the 8MB threshold and is rotated" || bad "THRESHOLD_MB=08: file is '$(_file_size_bytes "$F11")' bytes — log: $(cat "$LOG_REAPER_LOG")"
grep -q "cap cycle complete" "$LOG_REAPER_LOG" && ok "THRESHOLD_MB=08: main() still reaches the capped class" || bad "THRESHOLD_MB=08: main() died before the capped class — log: $(cat "$LOG_REAPER_LOG")"
[ ! -s "$ERRF" ] && ok "THRESHOLD_MB=08: no arithmetic error on stderr" || bad "THRESHOLD_MB=08: stderr says: $(cat "$ERRF")"
# shellcheck disable=SC2034  # read by main() in the sourced script
THRESHOLD_MB=1; LOG_REAPER_PATHS=""

# The real entry point (the script run, not sourced) with the reviewer's knob.
F12="$CAPDIR/standalone-keep08.log"; head -c 11000000 /dev/zero > "$F12"
SA2="$CAPDIR/standalone2.log"; : > "$SA2"
env -u LOG_REAPER_LIB -u LOG_REAPER_PROD LOG_REAPER_LOG="$SA2" LOG_REAPER_PATHS="$CAPDIR/none.log" LOG_REAPER_CAP_PATHS="$F12" LOG_REAPER_CAP_MB=10 LOG_REAPER_KEEP_MB=08 /bin/bash "$SCRIPT" 2>"$ERRF"
[ "$(_file_size_bytes "$F12")" = "$(( 8 * 1024 * 1024 ))" ] && [ ! -s "$ERRF" ] && ok "standalone run, LOG_REAPER_KEEP_MB=08: keeps 8MB, silently" || bad "standalone run, KEEP_MB=08: file '$(_file_size_bytes "$F12")' bytes, stderr: $(cat "$ERRF")"
CAP_MB=2; KEEP_MB=1

echo ""
echo "=== tail-cap class: script run standalone (non-library) never reaches the real city logs ==="
# The true production shape: the script itself, with the first-class list pointed
# at a fixture and nothing said about the capped list. With PROD unset the
# sentinel must turn the capped class into a dry-run, so this cannot truncate
# any of the seven real files whatever their size.
SA_LOG="$CAPDIR/standalone.log"
: > "$SA_LOG"
env -u LOG_REAPER_LIB -u LOG_REAPER_CAP_PATHS -u LOG_REAPER_PROD LOG_REAPER_LOG="$SA_LOG" LOG_REAPER_PATHS="$CAPDIR/none.log" bash "$SCRIPT"
grep -q "SENTINEL: capped-log list" "$SA_LOG" && grep -q "cap cycle complete: .* dry_run=1" "$SA_LOG" && ! grep -q "^\[[^]]*\] capped: " "$SA_LOG" && ok "standalone run, no PROD opt-in: capped class is forced to dry-run" || bad "standalone run did not dry-run the capped class — log: $(cat "$SA_LOG")"

rm -rf "$CAPDIR"

echo ""
echo "=== production constant sanity (ga-h565g) ==="
# Uses the value captured immediately after this file's ONLY source (top of
# file), before any scenario above overrode LOG_REAPER_REAL_DEFAULT_PATHS —
# confirms the six paths actually shipped in production match what this
# bead's incident measured (catches drift between the default list and
# whatever a future edit changes it to).
EXPECTED_PATHS="/private/tmp/appium_server.log
/Users/athos/shared/logs/db_sync_stdout.log
/Users/athos/shared/logs/db_sync.log
/Users/athos/shared/logs/daemon_dashboard.log
/Users/athos/shared/logs/daemon_dashboard_stderr.log
/Users/athos/shared/logs/classification_dashboard_stderr.log"
[ "$PRODUCTION_REAL_DEFAULT_PATHS" = "$EXPECTED_PATHS" ] && ok "production constant: default path list matches the six paths from the bead's own incident" || bad "production constant drifted: got '$PRODUCTION_REAL_DEFAULT_PATHS'"

EXPECTED_CAP_PATHS="/Users/athos/gt/.gascity-gastown-hq/.gc/runtime/control-dispatcher-trace.log
/Users/athos/.gc/supervisor.log
/Users/athos/gt/.gascity-gastown-hq/.gc/logs/scratchpad-reaper.log
/Users/athos/gt/.gascity-gastown-hq/.gc/logs/gate-merge-survival-sweep.log
/Users/athos/gt/.gascity-gastown-hq/.gc/logs/gate-merge-survival-sweep-launchd.out
/Users/athos/gt/.gascity-gastown-hq/.gc/logs/lifecycle-coherence-janitor.log
/Users/athos/gt/.gascity-gastown-hq/.gc/logs/production-drift-guard-launchd.err"
[ "$PRODUCTION_CAP_REAL_DEFAULT_PATHS" = "$EXPECTED_CAP_PATHS" ] && ok "production constant: capped-log list matches the seven files from ga-52drsg" || bad "production constant drifted (capped list): got '$PRODUCTION_CAP_REAL_DEFAULT_PATHS'"

rm -f "$LOG_REAPER_LOG"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
