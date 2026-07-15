#!/bin/bash
# disk-ballast-guard.selftest.sh — tests for disk-ballast-guard.sh (ga-pzgr / ga-iyv4):
# a disk guard that can ONLY help, never kill. Pure decision functions are tested
# hermetically (stubbed inputs, no real disk). Execution functions (ballast
# create/delete, notify) are tested against REAL small scratch files with a REAL
# `df` before/after comparison — this is deliberate: the story's acceptance
# criteria demand proof that space genuinely returns, not just that a function
# was called (ga-p5q3: falsify every check whose emptiness is load-bearing).
#
# Hermetic: sources the script as a LIBRARY (DISK_BALLAST_GUARD_LIB=1) so main()
# never runs on load. All side-effecting tests operate ONLY inside a throwaway
# scratch dir under $TMPDIR; nothing outside it is ever touched. `notify`, `gc`,
# and `bd` are stubbed via a scratch bin dir prepended to PATH — no real push is
# ever sent, and `gc`/`bd` are made to FAIL (exit 127) to prove the alarm path
# has zero dependency on them (simulates "Dolt down").
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/disk-ballast-guard.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/disk-ballast-guard-selftest.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

export DISK_BALLAST_GUARD_LIB=1
export DISK_BALLAST_GUARD_LOG="$SCRATCH/guard.log"
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== disk-ballast-guard.selftest.sh ==="

# ── _avail_kb: real df parsing (NOT stubbed — proves the -k math matches this
#    machine's actual df output format; decision-function tests below stub
#    avail directly and don't depend on this) ─────────────────────────────────
k="$(_avail_kb "$SCRATCH")"
case "$k" in
  ''|*[!0-9]*) bad "_avail_kb(\$SCRATCH) did not return an integer (got: '$k')" ;;
  *) [ "$k" -gt 0 ] && ok "_avail_kb(\$SCRATCH) returns a positive integer KB ($k)" || bad "_avail_kb(\$SCRATCH) returned non-positive: $k" ;;
esac

# ── _avail_kb: nonexistent path → "" (surfaces as UNKNOWN, never a silent 0 —
#    ga-p5q3: error and empty must not collapse to the same value as "fine") ──
k="$(_avail_kb "$SCRATCH/does-not-exist/$$")"
[ "$k" = "" ] && ok "_avail_kb(nonexistent path) → '' (df failure surfaces, not masked)" || bad "_avail_kb(nonexistent) got: '$k' (expected empty)"

# ── _ballast_class: CRITICAL / HEALTHY / MID / UNKNOWN boundaries
#    (floor=2097152KB=2GB, healthy=15728640KB=15GB) ────────────────────────────
FLOOR_KB=2097152
HEALTHY_KB=15728640
[ "$(_ballast_class 1000000 "$FLOOR_KB" "$HEALTHY_KB")" = "CRITICAL" ]  && ok "class: well below floor → CRITICAL" || bad "class 1000000 wrong: $(_ballast_class 1000000 "$FLOOR_KB" "$HEALTHY_KB")"
[ "$(_ballast_class "$FLOOR_KB" "$FLOOR_KB" "$HEALTHY_KB")" = "CRITICAL" ] && ok "class: avail==floor → CRITICAL (boundary inclusive)" || bad "class avail==floor wrong: $(_ballast_class "$FLOOR_KB" "$FLOOR_KB" "$HEALTHY_KB")"
[ "$(_ballast_class 5000000 "$FLOOR_KB" "$HEALTHY_KB")" = "MID" ]      && ok "class: between floor and healthy → MID" || bad "class 5000000 wrong: $(_ballast_class 5000000 "$FLOOR_KB" "$HEALTHY_KB")"
[ "$(_ballast_class "$HEALTHY_KB" "$FLOOR_KB" "$HEALTHY_KB")" = "HEALTHY" ] && ok "class: avail==healthy → HEALTHY (boundary inclusive)" || bad "class avail==healthy wrong: $(_ballast_class "$HEALTHY_KB" "$FLOOR_KB" "$HEALTHY_KB")"
[ "$(_ballast_class 99999999 "$FLOOR_KB" "$HEALTHY_KB")" = "HEALTHY" ] && ok "class: well above healthy → HEALTHY" || bad "class 99999999 wrong: $(_ballast_class 99999999 "$FLOOR_KB" "$HEALTHY_KB")"
[ "$(_ballast_class "" "$FLOOR_KB" "$HEALTHY_KB")" = "UNKNOWN" ]       && ok "class: empty avail (df failed) → UNKNOWN, never MID/HEALTHY" || bad "class empty wrong: $(_ballast_class "" "$FLOOR_KB" "$HEALTHY_KB")"
[ "$(_ballast_class abc "$FLOOR_KB" "$HEALTHY_KB")" = "UNKNOWN" ]      && ok "class: non-numeric avail → UNKNOWN" || bad "class abc wrong: $(_ballast_class abc "$FLOOR_KB" "$HEALTHY_KB")"

# ── _create_ballast: REAL allocation, must be non-sparse (this is load-bearing —
#    a sparse "2GB" file that doesn't occupy real blocks provides ZERO ballast).
#    20MB, not 2GB, so the test stays fast; same code path as production. ──────
BALLAST="$SCRATCH/ballast.bin"
_create_ballast "$BALLAST" 20
rc=$?
[ "$rc" -eq 0 ] && ok "_create_ballast: exit 0" || bad "_create_ballast: nonzero exit ($rc)"
[ -f "$BALLAST" ] && ok "_create_ballast: file exists" || bad "_create_ballast: file missing"
du_kb="$(du -sk "$BALLAST" 2>/dev/null | awk '{print $1}')"
case "$du_kb" in
  ''|*[!0-9]*) bad "_create_ballast: du -sk did not return an integer (got: '$du_kb')" ;;
  *) [ "$du_kb" -ge 19000 ] && ok "_create_ballast: real on-disk size ~20MB, NOT sparse (du=${du_kb}KB)" || bad "_create_ballast: on-disk size too small — file is SPARSE (du=${du_kb}KB, expected >=19000KB)" ;;
esac
rm -f "$BALLAST"

# ── _burn_ballast_if_present: THE core acceptance-criterion-1 behavior. Real
#    df-before/after comparison proves REAL space returns — this exact
#    assertion is the one the mutation-test (remove the `rm`) must turn RED. ──
_create_ballast "$BALLAST" 20
avail_before="$(_avail_kb "$SCRATCH")"
_burn_ballast_if_present "$BALLAST"
rc=$?
[ "$rc" -eq 0 ] && ok "_burn_ballast_if_present: exit 0 (did burn)" || bad "_burn_ballast_if_present: nonzero exit ($rc)"
[ ! -e "$BALLAST" ] && ok "_burn_ballast_if_present: file deleted" || bad "_burn_ballast_if_present: file still present"
avail_after="$(_avail_kb "$SCRATCH")"
delta=$(( avail_after - avail_before ))
[ "$delta" -ge 18000 ] && ok "_burn_ballast_if_present: real avail grew by ~20MB (delta=${delta}KB) — space GENUINELY returned" || bad "_burn_ballast_if_present: avail did not grow as expected (delta=${delta}KB, expected >=18000KB) — THIS is the mutation-test assertion"

# already-absent → distinct "nothing to burn" signal (rc=1), no error
_burn_ballast_if_present "$BALLAST"
rc=$?
[ "$rc" -eq 1 ] && ok "_burn_ballast_if_present: already-absent path → exit 1 (nothing to burn)" || bad "_burn_ballast_if_present: already-absent path gave exit $rc (expected 1)"

# ── _recreate_ballast_if_absent: acceptance-criterion-2 companion — recreate
#    only when absent, never clobber an existing ballast (no needless re-burn
#    churn during a crisis). $BALLAST is already absent here (burned above). ──
[ ! -e "$BALLAST" ] || bad "test setup: \$BALLAST should be absent before this block"
_recreate_ballast_if_absent "$BALLAST" 20
rc=$?
[ "$rc" -eq 0 ] && ok "_recreate_ballast_if_absent: exit 0 (did create)" || bad "_recreate_ballast_if_absent: nonzero exit ($rc)"
du_kb="$(du -sk "$BALLAST" 2>/dev/null | awk '{print $1}')"
[ "${du_kb:-0}" -ge 19000 ] 2>/dev/null && ok "_recreate_ballast_if_absent: real on-disk size ~20MB (du=${du_kb}KB)" || bad "_recreate_ballast_if_absent: bad on-disk size (du=${du_kb:-<empty>}KB)"

# already-present → no-op (rc=1), does not error, file untouched
_recreate_ballast_if_absent "$BALLAST" 20
rc=$?
[ "$rc" -eq 1 ] && ok "_recreate_ballast_if_absent: already-present path → exit 1 (no-op)" || bad "_recreate_ballast_if_absent: already-present path gave exit $rc (expected 1)"
[ -f "$BALLAST" ] && ok "_recreate_ballast_if_absent: file still present after no-op" || bad "_recreate_ballast_if_absent: file vanished after no-op"
rm -f "$BALLAST"

# ── _notify_critical: composes + sends the final, no-cooldown alarm. `notify`
#    is stubbed (writes its argv to a marker file, sends nothing real). ────────
NOTIFY_MARKER="$SCRATCH/notify-called.txt"
cat > "$SCRATCH/fake-notify" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "${NOTIFY_MARKER_PATH}"
STUB
chmod +x "$SCRATCH/fake-notify"
export NOTIFY_MARKER_PATH="$NOTIFY_MARKER"
export DISK_BALLAST_GUARD_NOTIFY_BIN="$SCRATCH/fake-notify"

rm -f "$NOTIFY_MARKER"
_notify_critical 1048576 "50MB  /some/offender/file.bin"
[ -f "$NOTIFY_MARKER" ] && ok "_notify_critical: notify WAS invoked (marker written)" || bad "_notify_critical: notify was never called"
if [ -f "$NOTIFY_MARKER" ]; then
  grep -q "LASTRO QUEIMADO" "$NOTIFY_MARKER" && ok "_notify_critical: message contains 'LASTRO QUEIMADO'" || bad "_notify_critical: message missing 'LASTRO QUEIMADO' text"
  grep -q "^5$" "$NOTIFY_MARKER" && ok "_notify_critical: priority 5 (no-cooldown final alarm) was passed" || bad "_notify_critical: priority 5 not found in argv"
  grep -q "offender/file.bin" "$NOTIFY_MARKER" && ok "_notify_critical: offenders text included in message" || bad "_notify_critical: offenders text missing from message"
fi

# ── _top_offenders: bounded, best-effort, TCC/CloudStorage-safe recent-file
#    scan. MUST prune anything under a "CloudStorage" dir (network/FUSE mount —
#    can hang indefinitely per this town's operational doctrine) even if it's
#    nominally the biggest file. MUST never error/hang on a bad root. ─────────
mkdir -p "$SCRATCH/offenders/Library/CloudStorage/fake-drive"
dd if=/dev/zero of="$SCRATCH/offenders/file-small.bin" bs=1m count=1 2>/dev/null
dd if=/dev/zero of="$SCRATCH/offenders/file-big.bin" bs=1m count=3 2>/dev/null
dd if=/dev/zero of="$SCRATCH/offenders/Library/CloudStorage/fake-drive/huge-but-excluded.bin" bs=1m count=5 2>/dev/null

out="$(_top_offenders "$SCRATCH/offenders" 5 10)"
echo "$out" | grep -q "file-big.bin" && ok "_top_offenders: includes recently-created file" || bad "_top_offenders: missing expected file in output (got: $out)"
first_line="$(echo "$out" | head -1)"
echo "$first_line" | grep -q "file-big.bin" && ok "_top_offenders: largest (non-excluded) file sorted first" || bad "_top_offenders: sort order wrong (first line: $first_line)"
echo "$out" | grep -q "huge-but-excluded" && bad "_top_offenders: CloudStorage-path file LEAKED into output (TCC/hang-safety violation)" || ok "_top_offenders: CloudStorage-like path correctly pruned"

out2="$(_top_offenders "$SCRATCH/does-not-exist-$$" 5 10)"
[ -z "$out2" ] && ok "_top_offenders: nonexistent root → empty (best-effort, never errors)" || bad "_top_offenders: nonexistent root gave: $out2"
rm -rf "$SCRATCH/offenders"

# multi-root (production default passes 3 space-separated roots — this exact
# shape) — regression coverage for a word-splitting edge case caught during
# manual verification (an interactive-shell find-wrapper artifact masked as a
# real bug; confirmed via a fresh non-interactive script invocation that the
# actual code path splits and searches all roots correctly).
mkdir -p "$SCRATCH/multiA" "$SCRATCH/multiB"
dd if=/dev/zero of="$SCRATCH/multiA/a.bin" bs=1m count=2 2>/dev/null
dd if=/dev/zero of="$SCRATCH/multiB/b.bin" bs=1m count=4 2>/dev/null
out3="$(_top_offenders "$SCRATCH/multiA $SCRATCH/multiB" 5 10)"
echo "$out3" | grep -q "a\.bin" && echo "$out3" | grep -q "b\.bin" && ok "_top_offenders: multi-root (space-separated) searches ALL roots" || bad "_top_offenders: multi-root did not find both roots' files (got: $out3)"
rm -rf "$SCRATCH/multiA" "$SCRATCH/multiB"

# ── main(): full orchestration, acceptance criteria 1 and 2. Thresholds are set
#    to absurd extremes (floor=99999999GB / healthy=0GB) so the REAL avail on
#    this machine — whatever it happens to be — deterministically forces the
#    CRITICAL or HEALTHY branch, without stubbing df itself. gc/bd are replaced
#    with always-fail (exit 127) stubs on PATH to simulate "Dolt down" — proves
#    zero dependency on gc/bd/Dolt anywhere in the alarm path (criterion 4). ──
MAIN_BALLAST="$SCRATCH/main-ballast.bin"
FAKEBIN="$SCRATCH/fakebin-dolt-down"
mkdir -p "$FAKEBIN"
printf '#!/bin/bash\nexit 127\n' > "$FAKEBIN/gc"
printf '#!/bin/bash\nexit 127\n' > "$FAKEBIN/bd"
chmod +x "$FAKEBIN/gc" "$FAKEBIN/bd"

export DISK_BALLAST_GUARD_BALLAST_PATH="$MAIN_BALLAST"
export DISK_BALLAST_GUARD_CHECK_PATH="$SCRATCH"
export DISK_BALLAST_GUARD_SCAN_ROOTS="$SCRATCH"
export DISK_BALLAST_GUARD_ENABLED=1

echo "--- criterion 1: disk below floor ---"
_create_ballast "$MAIN_BALLAST" 20
avail_before="$(_avail_kb "$SCRATCH")"
export DISK_BALLAST_GUARD_FLOOR_GB=99999999    # forces CRITICAL regardless of real avail
export DISK_BALLAST_GUARD_HEALTHY_GB=999999999
rm -f "$NOTIFY_MARKER"
OLDPATH="$PATH"; PATH="$FAKEBIN:$PATH"
main
PATH="$OLDPATH"

[ ! -e "$MAIN_BALLAST" ] && ok "main(): CRITICAL — ballast deleted" || bad "main(): CRITICAL — ballast still present"
avail_after="$(_avail_kb "$SCRATCH")"
delta=$(( avail_after - avail_before ))
[ "$delta" -ge 18000 ] && ok "main(): CRITICAL — real avail grew (delta=${delta}KB), space genuinely returned" || bad "main(): CRITICAL — avail did not grow (delta=${delta}KB)"
[ -f "$NOTIFY_MARKER" ] && ok "main(): CRITICAL — notify fired WITH gc/bd broken (Dolt-down simulated)" || bad "main(): CRITICAL — notify never fired"
[ -f "$NOTIFY_MARKER" ] && grep -q "LASTRO QUEIMADO" "$NOTIFY_MARKER" && ok "main(): CRITICAL — notify message correct" || bad "main(): CRITICAL — notify message wrong/missing"

echo "--- criterion 2: disk healthy ---"
_create_ballast "$MAIN_BALLAST" 20
export DISK_BALLAST_GUARD_FLOOR_GB=2
export DISK_BALLAST_GUARD_HEALTHY_GB=0          # forces HEALTHY regardless of real avail
rm -f "$NOTIFY_MARKER"
OLDPATH="$PATH"; PATH="$FAKEBIN:$PATH"
main
PATH="$OLDPATH"

[ -f "$MAIN_BALLAST" ] && ok "main(): HEALTHY — ballast EXISTS, not deleted (no regression)" || bad "main(): HEALTHY — ballast was wrongly deleted"
[ ! -f "$NOTIFY_MARKER" ] && ok "main(): HEALTHY — no alarm notify sent" || bad "main(): HEALTHY — spuriously notified"
rm -rf "$MAIN_BALLAST" "$FAKEBIN"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
