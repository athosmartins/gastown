#!/usr/bin/env bash
# disk-oscillation-breakdown.selftest.sh — Regression harness for ga-lc17m.
#
# Proves the PURE gap-arithmetic core of disk-oscillation-breakdown.sh in
# isolation (no live disk, no du/df calls). It SOURCES the script in
# lib-only mode (DISK_OSCILLATION_LIB=1) so the tested function IS the
# shipped one.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${DISK_OSCILLATION_BREAKDOWN:-$SELF_DIR/disk-oscillation-breakdown.sh}"

# shellcheck disable=SC1090
DISK_OSCILLATION_LIB=1 . "$TARGET"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   — %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL — %s\n' "$1"; }

# summary <desc> <used_kb> <measured_kb> <blocked_n> <expect_substr...>
check_summary() {
  local desc="$1" used="$2" measured="$3" blocked="$4"; shift 4
  local got; got="$(dob_gap_summary "$used" "$measured" "$blocked")"
  local all_found=1 needle
  for needle in "$@"; do
    case "$got" in
      *"$needle"*) ;;
      *) all_found=0 ;;
    esac
  done
  if [ "$all_found" -eq 1 ]; then
    ok "$desc (=$got)"
  else
    bad "$desc: expected to contain [$*], got '$got'"
  fi
}

echo "== dob_gap_summary =="

# Same order of magnitude as ga-lc17m's own reading (~176G used, ~117G
# measured) -> ~33% gap (integer division)
check_summary "gap percentage matches expected magnitude" 184320000 122683392 4 \
  "used=184320000K" "measured=122683392K" "gap=61636608K(33%)"

# No gap: fully measured, nothing blocked
check_summary "zero gap when fully measured" 1000 1000 0 "gap=0K(0%)"

# measured > used (rounding/timing skew across two separate df/du reads):
# gap must clamp to 0, never go negative
check_summary "clamps negative gap to 0" 1000 1200 0 "gap=0K(0%)"

# used=0 must not divide-by-zero
check_summary "used=0 does not divide by zero" 0 0 0 "gap=0K(0%)"

# used=1 is the smallest volume that still gets a percentage (ga-ow127o6, mutant 0a702a32cf: `-gt 0` -> `-gt 1`)
check_summary "used=1K still gets its percentage" 1 0 0 "gap=1K(100%)"

# EQUIVALENT (ga-ow127o6; c7272bdedb `-lt 0` -> `-le 0` and be4a291165 `-lt 0` -> `-lt 1`, both on the gap clamp):
# the clamp only has to turn a NEGATIVE gap into 0, and a gap that is already 0 stays 0 whichever way the
# boundary is written, so `-lt 0`, `-le 0` and `-lt 1` assign 0 to exactly the same inputs: no input separates them.

# blocked_dirs propagates through untouched
check_summary "blocked_dirs count passes through" 500 100 7 "blocked_dirs=7"

echo
echo "== dob_targets (ga-gyzbha) =="

# The root list must never name a TCC-protected tree. A `du` there makes macOS
# show the Athos a permission dialog ("bash would like to access data from other
# apps" / "... files managed by iCloud Drive") and blocks until he clicks —
# measured 2026-09-26: tccd logged that dialog for this script's `du` (hourly
# run at 10:43:01), and 763 of 765 runs never finished anyway. Checked against
# a fake HOME so a match is exact.
if ! declare -F dob_targets >/dev/null; then
  bad "dob_targets is not defined in lib mode — the root list cannot be checked"
else
  targets="$(HOME=/fakehome DARWIN_TMP=/fake/T dob_targets)"
  for protected in "Library/Containers" "Library/Group Containers" \
                   "Library/CloudStorage" "Library/Mobile Documents"; do
    if printf '%s\n' "$targets" | grep -qF "/fakehome/$protected"; then
      bad "dob_targets names TCC-protected root ~/$protected"
    else
      ok "dob_targets leaves out ~/$protected"
    fi
  done
  if printf '%s\n' "$targets" | grep -qxF "/fakehome"; then
    bad "dob_targets walks \$HOME itself (reaches Desktop/Documents/Downloads)"
  else
    ok "dob_targets does not walk \$HOME itself"
  fi
  if printf '%s\n' "$targets" | grep -qxF "/fake/T"; then
    ok "dob_targets still measures DARWIN_TMP"
  else
    bad "dob_targets dropped DARWIN_TMP (got: $(printf '%s' "$targets" | tr '\n' ' '))"
  fi
fi

echo
echo "== whole-script run with stubbed df/du/timeout/getconf (ga-ow127o6, hq-mutants lastro) =="

# Everything below `dob_targets` in the script (argument parsing, the lib-mode guard, the collection loop and
# the output) was only ever sourced past, never executed here. The stubs make the run hermetic: no real
# df/du/timeout/getconf, with fixed numbers so each branch shows up in the summary line or in the log.
#   $DRT/T            du -> 500K, no errors                     (a clean root)
#   $HOME/shared/data du -> 1000K and ONE stderr line           (summed, but counted as blocked)
#   $HOME/.cache      timeout -> rc 124                         (TIMEOUT, not summed, blocked)
#   $HOME/Library/Caches du -> 250K, no errors                  (a second clean root: the clean ones outnumber the
#                                                                erroring one, so counting the wrong side shows)
#   $HOME/gt          du -> rc 0 and nothing printed            (UNREADABLE, not summed, blocked)
DRT="$(mktemp -d "${TMPDIR:-/tmp}/dob.XXXXXX")"
trap 'rm -rf "$DRT"' EXIT
mkdir -p "$DRT/bin" "$DRT/home/shared/data" "$DRT/home/.cache" "$DRT/home/Library/Caches" "$DRT/home/gt" "$DRT/T"
cat >"$DRT/bin/getconf" <<'EOF'
#!/bin/sh
echo "${DOB_TMP_ROOT:?}/"
EOF
cat >"$DRT/bin/df" <<'EOF'
#!/bin/sh
echo called >>"${DOB_DF_MARK:-/dev/null}"
if [ "$1" = "-k" ]; then
  printf 'Filesystem 1K-blocks Used Available Capacity Mounted\n/dev/d1 20000 10000 10000 50%% /System/Volumes/Data\n'
else
  printf 'Filesystem Size Used Avail Capacity Mounted\n/dev/d1 20G 10G 7.5G 50%% /System/Volumes/Data\n'
fi
EOF
cat >"$DRT/bin/du" <<'EOF'
#!/bin/sh
for a; do p=$a; done
case "$p" in
  */T) printf '500\t%s\n' "$p" ;;
  */shared/data) printf '1000\t%s\n' "$p"; echo "du: $p/x: Operation not permitted" >&2 ;;
  */Library/Caches) printf '250\t%s\n' "$p" ;;
  */gt) : ;;
  *) echo "du: $p: No such file or directory" >&2; exit 1 ;;
esac
EOF
cat >"$DRT/bin/timeout" <<'EOF'
#!/bin/sh
shift
case "$*" in *"/.cache"*) exit 124 ;; esac
exec "$@"
EOF
chmod +x "$DRT/bin/getconf" "$DRT/bin/df" "$DRT/bin/du" "$DRT/bin/timeout"

dob_run() {   # "$@" = arguments of the script; leaves DOB_RC and the captured streams in $DRT/out.txt / $DRT/err.txt
  : >"$DRT/df.mark"
  env -u DISK_OSCILLATION_LIB HOME="$DRT/home" PATH="$DRT/bin:$PATH" DOB_DF_MARK="$DRT/df.mark" DOB_TMP_ROOT="${DOB_TMP_ROOT:-$DRT/T}" \
    bash "$TARGET" "$@" >"$DRT/out.txt" 2>"$DRT/err.txt"
  DOB_RC=$?
}
want_summary="used=10000K measured=1750K gap=8250K(82%) blocked_dirs=3"
want_json='{"used_kb":10000,"measured_kb":1750,"blocked_dirs":3}'

# default run: the summary line on stdout. mutants 071a05e875 b31737e0da e8766b2e36 (argument parsing, the default
# must NOT be json), 2683e20a59 5f92c9db66 (the lib guard must not fire here), f824a17009 (the target list is read),
# 9f59831d9e 29bc7faf68 2b67dd3db3 (a non-empty target is not skipped by the empty-target guard), 60a2a6a9bb 8e485a046c
# (present dirs are measured; the missing one is skipped in the run further down), e8696aafb9 e73e7ff858 cc2428a6e1 4305bf2b22 332cf48af6 (only a root WITH permission errors
# is blocked: the clean root, the one-line-of-errors root), fa07ff7749 4b76eb3cb2 8fc5fe1bc8 (summary vs json)
dob_run
# vazio → o cat devolve "" e a igualdade reprova; ilegível (arquivo ausente) → idem
[ "$DOB_RC" -eq 0 ] && [ "$(cat "$DRT/out.txt" 2>/dev/null)" = "$want_summary" ] \
  && ok "default run prints the summary line (=$want_summary)" \
  || bad "default run: expected rc 0 + '$want_summary', got rc=$DOB_RC '$(cat "$DRT/out.txt" 2>/dev/null)'"

# the log (stderr) says which branch each root took. mutants 6ccf1d862c 4f810b27e4 73701f697d (rc 124 is the timeout
# and nothing else) and 3539136ece e393074f76 (no parseable du total is UNREADABLE, a total is summed)
# vazio → cada grep -F falha e o check reprova; ilegível → idem
grep -qF "TIMEOUT (60s): $DRT/home/.cache" "$DRT/err.txt" \
  && ok "a root whose du times out is logged as TIMEOUT" || bad "no TIMEOUT line for $DRT/home/.cache: $(grep -c . "$DRT/err.txt" 2>/dev/null) log lines"
grep -qF "UNREADABLE (rc=0): $DRT/home/gt" "$DRT/err.txt" \
  && ok "a root whose du prints no total is logged as UNREADABLE" || bad "no UNREADABLE line for $DRT/home/gt"
grep -qF "1000K  $DRT/home/shared/data  (permission-errors: 1)" "$DRT/err.txt" \
  && grep -qF "500K  $DRT/T  (permission-errors: 0)" "$DRT/err.txt" \
  && ok "measured roots are logged with their permission-error count" || bad "missing measured-root lines (shared/data with 1 error, T with 0)"

# a root that does not exist is skipped, not measured and not blocked (mutants 60a2a6a9bb 8e485a046c, the -d test).
# The tmp root points at a path that is not there; every other root is as above, so only that one drops out.
DOB_TMP_ROOT="$DRT/nope" dob_run
# vazio → o cat devolve "" e a igualdade reprova; ilegível → idem
[ "$DOB_RC" -eq 0 ] && [ "$(cat "$DRT/out.txt" 2>/dev/null)" = "used=10000K measured=1250K gap=8750K(87%) blocked_dirs=3" ] \
  && grep -qF "skip (not a dir): $DRT/nope" "$DRT/err.txt" \
  && ok "a root that is not a directory is logged as skipped and left out of the numbers" \
  || bad "missing tmp root: expected the skip line + 'measured=1250K ... blocked_dirs=3', got rc=$DOB_RC '$(cat "$DRT/out.txt" 2>/dev/null)'"

# --json: only the json object on stdout (mutants 071a05e875 b31737e0da e8766b2e36 fa07ff7749 4b76eb3cb2 8fc5fe1bc8)
dob_run --json
# vazio → o cat devolve "" e a igualdade reprova; ilegível → idem
[ "$DOB_RC" -eq 0 ] && [ "$(cat "$DRT/out.txt" 2>/dev/null)" = "$want_json" ] \
  && ok "--json prints only the json object (=$want_json)" \
  || bad "--json run: expected rc 0 + '$want_json', got rc=$DOB_RC '$(cat "$DRT/out.txt" 2>/dev/null)'"

# DISK_OSCILLATION_LIB=1 executed directly: returns at once, touches no disk. mutants e648c37bd7 2d45c89790 (the `|| exit 0`
# that stands in for `return` outside a sourced file) and daeb0cca26 (its status)
: >"$DRT/df.mark"
env DISK_OSCILLATION_LIB=1 HOME="$DRT/home" PATH="$DRT/bin:$PATH" DOB_DF_MARK="$DRT/df.mark" \
  bash "$TARGET" >"$DRT/out.txt" 2>"$DRT/err.txt"
rc=$?
# vazio → é o esperado aqui (nenhum df, nenhuma saída); arquivo ausente também passaria o `! -s`, mas os três foram criados
# por esta linha e pelas redireções acima, e o rc 0 exige que o bash tenha mesmo rodado o script
[ "$rc" -eq 0 ] && [ ! -s "$DRT/df.mark" ] && [ ! -s "$DRT/out.txt" ] && [ ! -s "$DRT/err.txt" ] \
  && ok "DISK_OSCILLATION_LIB=1 run exits 0 before any df/du call and prints nothing" \
  || bad "DISK_OSCILLATION_LIB=1 run: rc=$rc, df called $(grep -c called "$DRT/df.mark" 2>/dev/null) time(s), stdout '$(head -c 80 "$DRT/out.txt" 2>/dev/null)'"

# ... and SOURCED the guard hands control back with status 0 (mutant 0ef73e1f3e: `return 0` -> `return 1`)
rc_src="$(DISK_OSCILLATION_LIB=1 bash -c '. "$1"; echo "$?"' _ "$TARGET" 2>/dev/null)"
[ "$rc_src" = "0" ] && ok "sourcing in lib mode returns status 0" || bad "sourcing in lib mode: expected status 0, got '$rc_src'"

echo
echo "== summary: ${pass} ok, ${fail} failed =="
[ "$fail" -eq 0 ]
