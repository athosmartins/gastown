#!/usr/bin/env bash
# pilot-manual-reclaim.selftest.sh — gt-1kkgu hermetic test.
#
# Drives the REAL script (packs/town-deltas/assets/pilot-manual-reclaim.sh)
# with a PATH-stubbed bd that logs every mutation, proving:
#   1. STALE (bd reclaim flips status to open, markers actually clear):
#      pilot:dispatched, pilot:dispatching, and pilot.dispatched_at are all
#      removed, and the script reports success.
#   2. NOT-STALE (bd reclaim no-ops, bead still in_progress): NO mutation —
#      a still-legitimately in-flight bead is never exposed to re-dispatch.
#   3. MISSING (bad bead id): NO mutation, graceful exit.
#   4. STUCK (status flips open, but the label/metadata removal doesn't
#      stick — e.g. a transient Dolt hiccup): the script does NOT claim
#      success — it verifies the post-state and reports failure honestly
#      instead of trusting the removal commands' suppressed exit codes.
#   5. VERIFY-EMPTY (status flips open, removal fires, but the POST-removal
#      verification read itself returns nothing): the script must not
#      collapse "confirmed zero markers remain" and "could not read the
#      confirmation" into the same success claim.
#   6. VERIFY-GARBAGE (same as 5, but the verification read returns a
#      not-found-shaped error object instead of empty output): same
#      requirement, exercised via the jq-parse-failure path instead of the
#      empty-string path.
#
# Falsifiable: against a naive "always print success after the removal
# attempts" script (no post-state verification), scenario 4 would still
# print "markers cleared" and exit 0 — its check would fail. Against a naive
# "always strip the labels regardless of status" script, scenario 2 would
# show the same mutations as scenario 1 and its check would fail. Against
# the actual pre-fix gt-1kkgu script (verification read piped straight into
# jq with no read-failure guard), scenarios 5 and 6 both fail — confirmed by
# running this exact suite against that script before writing the fix.
#
# Run:  bash packs/town-deltas/assets/pilot-manual-reclaim.selftest.sh
set -u

# Resolve relative to this selftest's own location (not a hardcoded main-
# checkout path) so it exercises whichever tree it's actually sitting in —
# a dev worktree before merge, or the live HQ checkout after.
SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELFTEST_DIR/pilot-manual-reclaim.sh"
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (want=$2 got=$3)"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pmr.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BINS="$WORK/bin"; MUT="$WORK/mutations.log"; mkdir -p "$BINS"; : >"$MUT"
export PMR_MUT="$MUT"

# --- stub: bd (logs every mutating call; `show` reflects PMR_SCENARIO and
#     tracks its own call count, since the real script now calls `show`
#     twice per run: once to check status after reclaim, once to verify
#     the labels/metadata actually cleared) ---
cat >"$BINS/bd" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
case "$sub" in
  reclaim)
    echo "MUT reclaim $*" >>"${PMR_MUT}"
    exit 0 ;;
  show)
    _CF="${PMR_MUT}.showcount"
    _N=$(( $(cat "$_CF" 2>/dev/null || echo 0) + 1 ))
    echo "$_N" >"$_CF"
    case "${PMR_SCENARIO:-}" in
      stale)
        if [ "$_N" -eq 1 ]; then
          echo '[{"id":"'"$1"'","status":"open","labels":["pilot:dispatched","pilot:dispatching"],"metadata":{"pilot.dispatched_at":"123"}}]'
        else
          echo '[{"id":"'"$1"'","status":"open","labels":[],"metadata":{}}]'
        fi ;;
      stuck)
        # status flips open, but the markers never actually clear (simulates
        # a transient failure in the label-remove/metadata-unset commands)
        echo '[{"id":"'"$1"'","status":"open","labels":["pilot:dispatched"],"metadata":{}}]' ;;
      not-stale) echo '[{"id":"'"$1"'","status":"in_progress","labels":["pilot:dispatched"],"metadata":{}}]' ;;
      missing)   echo '[]' ;;
      verify-empty)
        # status flips open on the 1st read; the 2nd read (post-removal
        # verification) returns NOTHING — simulates a transient Dolt read
        # hiccup on exactly the call the gt-1kkgu gate-fail was about.
        if [ "$_N" -eq 1 ]; then
          echo '[{"id":"'"$1"'","status":"open","labels":["pilot:dispatched","pilot:dispatching"],"metadata":{"pilot.dispatched_at":"123"}}]'
        fi ;;
      verify-garbage)
        # status flips open on the 1st read; the 2nd read returns a
        # not-found-shaped error object instead of a 1-element array (the
        # real bd show response shape observed live for an unreadable id).
        if [ "$_N" -eq 1 ]; then
          echo '[{"id":"'"$1"'","status":"open","labels":["pilot:dispatched","pilot:dispatching"],"metadata":{"pilot.dispatched_at":"123"}}]'
        else
          echo '{"error":"no issue found","schema_version":1}'
        fi ;;
    esac
    exit 0 ;;
  label)
    echo "MUT label $*" >>"${PMR_MUT}"
    exit 0 ;;
  update)
    echo "MUT update $*" >>"${PMR_MUT}"
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BINS"/*

run_script() {
  rm -f "${MUT}.showcount"
  PMR_SCENARIO="$1" PATH="$BINS:$PATH" bash "$SCRIPT" "gt-testbead" >"$WORK/out.log" 2>"$WORK/err.log"
  echo $?
}

# STALE: reclaim flips status open, removal verified -> all 3 markers
# cleared AND the script reports success.
: >"$MUT"
rc=$(run_script stale)
labels_cleared=0
grep -q 'MUT label remove gt-testbead pilot:dispatched'  "$MUT" && \
grep -q 'MUT label remove gt-testbead pilot:dispatching' "$MUT" && \
grep -q 'MUT update gt-testbead --unset-metadata pilot.dispatched_at' "$MUT" && \
labels_cleared=1
ck "STALE: exit code 0" 0 "$rc"
ck "STALE: all 3 Pilot claim markers cleared" 1 "$labels_cleared"
ck "STALE: reports success" 1 "$(grep -qc 'markers cleared' "$WORK/out.log" >/dev/null 2>&1 && echo 1 || echo 0)"

# NOT-STALE: reclaim no-ops (still in_progress) -> NO label/metadata mutation
: >"$MUT"
rc=$(run_script not-stale)
no_label_mutation=1
grep -q '^MUT label ' "$MUT" && no_label_mutation=0
grep -q '^MUT update ' "$MUT" && no_label_mutation=0
ck "NOT-STALE: exit code 0 (graceful no-op)" 0 "$rc"
ck "NOT-STALE: no Pilot claim marker touched (still in-flight, real work)" 1 "$no_label_mutation"

# MISSING: bd show returns nothing (bad id) -> NO mutation, no crash
: >"$MUT"
rc=$(run_script missing)
no_mutation_missing=1
[ -s "$MUT" ] && grep -qE '^MUT (label|update) ' "$MUT" && no_mutation_missing=0
ck "MISSING: exit code 0 (graceful, no crash)" 0 "$rc"
ck "MISSING: no Pilot claim marker touched" 1 "$no_mutation_missing"

# STUCK: status flips open, but the markers never actually clear -> the
# script must NOT claim success. This is the case a naive "|| true and
# print cleared unconditionally" implementation gets wrong.
: >"$MUT"
rc=$(run_script stuck)
ck "STUCK: exit code 1 (does not silently succeed)" 1 "$rc"
ck "STUCK: does NOT claim markers cleared" 0 "$(grep -qc 'markers cleared' "$WORK/out.log" >/dev/null 2>&1 && echo 1 || echo 0)"
ck "STUCK: reports which marker is still present" 1 "$(grep -qc 'pilot:dispatched' "$WORK/err.log" >/dev/null 2>&1 && echo 1 || echo 0)"

# VERIFY-EMPTY: status flips open and the label/metadata removal calls DO
# fire, but the post-removal verification read (2nd bd show) returns
# nothing — simulating a transient Dolt read hiccup. The script must not
# collapse "confirmed zero remaining" and "could not read the confirmation"
# into the same success claim (the gate-failed bug from gt-1kkgu attempt 1;
# none of the 4 scenarios above exercise a failing 2nd read — MISSING fails
# at the earlier STATUS gate before the verification read ever runs).
: >"$MUT"
rc=$(run_script verify-empty)
ck "VERIFY-EMPTY: exit code 1 (does not silently succeed)" 1 "$rc"
ck "VERIFY-EMPTY: does NOT claim markers cleared" 0 "$(grep -qc 'markers cleared' "$WORK/out.log" >/dev/null 2>&1 && echo 1 || echo 0)"

# VERIFY-GARBAGE: same setup, but the 2nd read returns a not-found-shaped
# error object instead of empty output or a 1-element array. Exercises the
# jq-parse-failure guard specifically (distinct code path from the
# empty-string guard above).
: >"$MUT"
rc=$(run_script verify-garbage)
ck "VERIFY-GARBAGE: exit code 1 (does not silently succeed)" 1 "$rc"
ck "VERIFY-GARBAGE: does NOT claim markers cleared" 0 "$(grep -qc 'markers cleared' "$WORK/out.log" >/dev/null 2>&1 && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
