#!/usr/bin/env bash
# gate-orphaned-label-watchdog.selftest.sh — ga-xzh0lr0. Runs the watchdog's OWN `bash gate-orphaned-label-watchdog.sh --selftest` (the ~300 assertions that
# live inside gate-orphaned-label-watchdog.sh: candidate sweep, park/active/queued buckets, state, cooldown, session liveness, quiet hours, mail) as a member
# of its selftest family. Nothing else ran that block, so a sweep, state or cooldown rule that broke — and every assertion of the block itself — stayed
# invisible to the mutant sweep: two thirds of the file's mutants sit inside the block. Slow by nature (~35 s of process spawns, measured): the fast
# end-to-end checks live in gate-orphaned-label-watchdog.queue.selftest.sh, which sorts first, so a mutant it kills never pays for this one.
# Pass = the block reached its summary line, attempted at least FLOOR assertions, printed exactly the ok/FAIL lines its counters say, failed none and exited 0.
# The block and the lock code read the clock and file times the BSD way (`date -j -f`, `date -r EPOCH`, `stat -f %m`). Where `date -j` is missing (the Linux
# node) a PATH shim answers exactly those forms with GNU date/stat and passes every other call through, so the quiet-hours scenarios (Q1-Q3) run instead of
# failing on "invalid option -- 'j'"; where it exists (the mini) nothing is shimmed. The block builds its own bd/gc/notify/jev stubs under its mktemp dir;
# GOLW_*_BIN below point at a stub that only exits 99, so a broken `--selftest` dispatch (the sweep would then run for real) still reaches no real bd, gc or
# notify. GOLW_SCRIPT_UNDER_TEST=<other copy> proves it fails on other code.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${GOLW_SCRIPT_UNDER_TEST:-$HERE/gate-orphaned-label-watchdog.sh}"
FLOOR=300   # assertions (ok + FAIL) the block attempts today: raise it with a scenario, never lower it to make a run green
# as root the chmod-000 case of scenario 48 is skipped (root reads the file): 1 assertion instead of 4
[ "$(id -u)" = 0 ] && FLOOR=$((FLOOR - 3))
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
# vazio/falhou -> no scratch dir: stop before anything runs (fail closed, nothing to clean)
T="$(mktemp -d)"
[ -n "$T" ] && [ -d "$T" ] || { echo "  FAIL mktemp -d gave no directory"; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/home" "$T/bin" "$T/bsd" || { echo "  FAIL could not create the scratch dirs"; exit 1; }
printf '%s\n' '#!/bin/sh' 'echo "watchdog selftest: a real bd/gc/notify was called: $0 $*" >&2' 'exit 99' > "$T/bin/stub"
chmod +x "$T/bin/stub"

# vazio/falhou -> `date -j` counts as missing and the shim is used; the shim only touches the BSD forms, so a wrong guess costs nothing where date is BSD
PATH_RUN="$PATH"
if ! date -j -f '%Y-%m-%d %H:%M:%S' '2000-01-02 00:00:00' +%s > /dev/null 2>&1; then
  real_date="$(command -v date)"; real_stat="$(command -v stat)"
  printf '%s\n' '#!/bin/sh' "real=$real_date" 'num() { case "$1" in ""|*[!0-9]*) return 1 ;; esac; return 0; }' 'case "$1" in' \
    '  -j) if [ "$2" = -f ]; then case "$3" in %s) arg="@$4" ;; *) arg="$4" ;; esac; exec "$real" -d "$arg" ${5:+"$5"}; fi ;;' \
    '  -r) if num "$2"; then exec "$real" -d "@$2" ${3:+"$3"}; fi ;;' '  -u) if [ "$2" = -r ] && num "$3"; then exec "$real" -u -d "@$3" ${4:+"$4"}; fi ;;' \
    'esac' 'exec "$real" "$@"' > "$T/bsd/date"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = -f ] && [ "$2" = %m ]; then shift 2; exec '"$real_stat"' -c %Y "$@"; fi' 'exec '"$real_stat"' "$@"' > "$T/bsd/stat"
  chmod +x "$T/bsd/date" "$T/bsd/stat"
  PATH_RUN="$T/bsd:$PATH"
fi

echo "run: bash $SCRIPT --selftest"
env PATH="$PATH_RUN" TMPDIR="$T/tmp" HOME="$T/home" GOLW_BD_BIN="$T/bin/stub" GOLW_GC_BIN="$T/bin/stub" GOLW_NOTIFY_BIN="$T/bin/stub" GOLW_HQ="$T/home" \
  GOLW_STORES="$T/home" GOLW_LOG="$T/golw.log" GOLW_STATE_DIR="$T/state" GOLW_STATE_FILE="$T/state/golw.state.json" \
  bash "$SCRIPT" --selftest > "$T/out" 2>&1
rc=$?

# vazio -> no summary line (the block never finished): sum_n is 0 and the check below fails; falhou/ilegivel -> grep exits 2 with nothing counted: the same, never "ran"
sum_n="$(grep -c -E '^gate-orphaned-label-watchdog selftest: PASS=[0-9]+ FAIL=[0-9]+$' "$T/out")"
[ "$sum_n" = 1 ] && ok "the in-file selftest ran to its summary line" || bad "no (or more than one) summary line: ${sum_n:-?} (rc $rc); last lines: $(tail -n 3 "$T/out" | tr '\n' '|')"
sum="$(grep -E '^gate-orphaned-label-watchdog selftest: PASS=[0-9]+ FAIL=[0-9]+$' "$T/out" | tail -n 1)"
p="${sum#*PASS=}"; p="${p%% *}"; f="${sum##*FAIL=}"
case "$p$f" in ''|*[!0-9]*) p=0; f=0; bad "the summary line has no readable counters: '$sum'" ;; esac

[ $((p + f)) -ge "$FLOOR" ] && ok "it attempted $((p + f)) assertions (floor $FLOOR)" || bad "it attempted only $((p + f)) assertions (floor $FLOOR): scenarios or checks were skipped"
# vazio -> 0 lines; falhou/ilegivel -> grep exits 2 and the count comes back empty: the comparison with the counter fails
n_ok="$(grep -c -E '^  ok  ' "$T/out")"; n_bad="$(grep -c -E '^  FAIL ' "$T/out")"
[ "$n_ok" = "$p" ] && ok "the ok lines ($n_ok) match its PASS counter" || bad "ok lines ${n_ok:-?} != PASS=$p"
[ "$n_bad" = "$f" ] && ok "the FAIL lines ($n_bad) match its FAIL counter" || bad "FAIL lines ${n_bad:-?} != FAIL=$f"
[ "$f" -eq 0 ] && ok "no assertion failed" || bad "$f assertion(s) failed: $(grep -E '^  FAIL ' "$T/out" | head -n 4 | tr '\n' '|')"
if [ "$f" -eq 0 ]; then want_rc=0; else want_rc=1; fi
[ "$rc" -eq "$want_rc" ] && ok "it exited $rc for FAIL=$f" || bad "it exited $rc for FAIL=$f (0 when nothing failed, 1 when something did)"
# vazio -> 0 (clean); falhou/ilegivel -> grep exits 2 and the count is empty: the comparison fails
n_nf="$(grep -c 'command not found' "$T/out")"
[ "$n_nf" = 0 ] && ok "the run raised no 'command not found' (a function called before the script defines it)" || bad "the run raised ${n_nf:-?} 'command not found' error(s)"
# vazio -> clean; falhou/ilegivel -> ls prints its error, which is not empty: the check fails. The block removes its own dir on exit; a block that falls through into the sweep replaces that trap.
left="$(ls -A "$T/tmp" 2>&1)"
[ -z "$left" ] && ok "the run left nothing in its TMPDIR" || bad "the run left in its TMPDIR: $(printf '%s' "$left" | head -n 3 | tr '\n' ' ')"

echo ""
echo "gate-orphaned-label-watchdog.selftest.sh (runs the in-file --selftest): PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
