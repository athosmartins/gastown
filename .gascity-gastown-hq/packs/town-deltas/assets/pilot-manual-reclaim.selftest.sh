#!/usr/bin/env bash
# pilot-manual-reclaim.selftest.sh — gt-1kkgu hermetic test.
#
# Drives the REAL script (packs/town-deltas/assets/pilot-manual-reclaim.sh)
# with a PATH-stubbed bd that logs every mutation, proving:
#   1. STALE (bd reclaim flips status to open): pilot:dispatched,
#      pilot:dispatching, and pilot.dispatched_at are all cleared.
#   2. NOT-STALE (bd reclaim no-ops, bead still in_progress): NO mutation —
#      a still-legitimately in-flight bead is never exposed to re-dispatch.
#
# Falsifiable: against a naive "always strip the labels" script, scenario 2
# would show the same 3 mutations as scenario 1 and its check would fail.
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

# --- stub: bd (logs every mutating call; `show` reflects PMR_SCENARIO) ---
cat >"$BINS/bd" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
case "$sub" in
  reclaim)
    echo "MUT reclaim $*" >>"${PMR_MUT}"
    exit 0 ;;
  show)
    case "${PMR_SCENARIO:-}" in
      stale)     echo '[{"id":"'"$1"'","status":"open"}]' ;;
      not-stale) echo '[{"id":"'"$1"'","status":"in_progress"}]' ;;
      missing)   echo '[]' ;;
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
  PMR_SCENARIO="$1" PATH="$BINS:$PATH" bash "$SCRIPT" "gt-testbead" >"$WORK/out.log" 2>"$WORK/err.log"
  echo $?
}

# STALE: reclaim flips status open -> all 3 Pilot markers cleared
: >"$MUT"
rc=$(run_script stale)
labels_cleared=0
grep -q 'MUT label remove gt-testbead pilot:dispatched'  "$MUT" && \
grep -q 'MUT label remove gt-testbead pilot:dispatching' "$MUT" && \
grep -q 'MUT update gt-testbead --unset-metadata pilot.dispatched_at' "$MUT" && \
labels_cleared=1
ck "STALE: exit code 0" 0 "$rc"
ck "STALE: all 3 Pilot claim markers cleared" 1 "$labels_cleared"

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

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
