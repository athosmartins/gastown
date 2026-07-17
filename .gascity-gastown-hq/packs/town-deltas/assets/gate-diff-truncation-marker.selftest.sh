#!/usr/bin/env bash
# gate-diff-truncation-marker.selftest.sh (ga-p4g6)
#
# Proves the silent-truncation fix: the reviewer-facing diff text used to be cut
# with `head -2000` (mid-hunk, mid-file) under a header that ALWAYS said "FULL
# DIFF (first 2000 lines)" — a 500-line (truly complete) diff and a 4439-line
# (55%-shown) diff rendered IDENTICAL header text. Measured live: 3/21 sampled
# branches (14%) truncated silently; the worst cases showed reviewers as little
# as 25-38% of the real change, and the one real bug caught that night lived in
# the omitted 45%.
#
# ROOT CAUSE it guards: quality-gate-dispatcher.sh:4930 (`head -2000 || true`)
# fed into a hardcoded header at :5028/:5092 that never varied with truncation
# state.
#
# Strategy: extract the live diff-truncation block VERBATIM from the dispatcher
# (DIFF_SUMMARY=... through the closing `fi`, bounded by the stable anchors
# `DIFF_SUMMARY=$(git_rig diff --stat` and `VERDICT_BEAD_IDS=()`), and exercise
# it under the SAME `set -euo pipefail` the dispatcher uses, against a stubbed
# git_rig() returning controlled, exact-line-count fake diffs. Then drift-guard
# the shipped source and mutation-test the harness itself (prove it goes RED
# against the pre-fix hardcoded-header shape).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-diff-truncation-marker.selftest =="

BLOCK="$(awk '/^DIFF_SUMMARY=\$\(git_rig diff --stat/{p=1} /^VERDICT_BEAD_IDS=\(\)$/{p=0} p' "$DISPATCHER")"
if [ -z "$BLOCK" ]; then
  bad "could not locate the diff-truncation block in dispatcher (anchors missing/renamed)"
else
  ok "located live diff-truncation block ($(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ') lines)"
fi

# run_block <label> <changed_files> <file_count> <budget> <full_diff_lines> <stub_body>
# Sources a fresh bash with set -euo pipefail (matching the dispatcher), a stubbed
# git_rig(), the scenario's env, then the live BLOCK, then dumps DIFF_HEADER /
# DIFF_FULL between markers this harness parses back out.
# NOTE: called as a plain function call (never inside `$(...)`) so the ok/bad
# calls below hit the REAL global PASS/FAIL counters — a command-substitution
# call would run this in a subshell and silently drop both the counters and any
# diagnostic echo (swallowed into the caller's captured string instead of
# reaching the terminal). Result is handed back via the global LAST_BLOCK_OUTPUT,
# not a return value.
run_block() {
  _label="$1"; _changed_files="$2"; _file_count="$3"; _budget="$4"; _stub_body="$5"
  LAST_BLOCK_OUTPUT="$(
    bash -c '
      set -euo pipefail
      DEFAULT_BRANCH="main"
      BRANCH="feature"
      CHANGED_FILES="'"$_changed_files"'"
      DIFF_FILE_COUNT='"$_file_count"'
      GATE_DIFF_LINE_BUDGET='"$_budget"'
      IS_CONTAINER_RIG=0
      RIG_PATH="/fake/rig/path"
      GIT_DIR_PATH="/fake/rig/path"
      '"$_stub_body"'
      '"$BLOCK"'
      echo "===HEADER-START==="
      printf "%s\n" "$DIFF_HEADER"
      echo "===HEADER-END==="
      echo "===FULL-START==="
      printf "%s\n" "$DIFF_FULL"
      echo "===FULL-END==="
    ' 2>&1
  )"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    bad "$_label: block aborted under set -e (rc=$RC)"
    echo "    --- captured output ---"
    printf '%s\n' "$LAST_BLOCK_OUTPUT" | sed 's/^/    /'
    return 1
  fi
  ok "$_label: block ran to completion under set -euo pipefail"
}

extract_section() {
  # extract_section <blob> <start-marker> <end-marker>
  printf '%s\n' "$1" | awk -v s="$2" -v e="$3" '$0==s{p=1;next} $0==e{p=0} p'
}

# ── Scenario A: 3 files (20 lines each = 60 total), budget=50 → PARTIAL, 2/3 shown
STUB_A='
git_rig() {
  if [ "${3:-}" = "--" ]; then
    case "${4:-}" in
      file_a.py) i=1; while [ "$i" -le 20 ]; do echo "A_LINE_$i"; i=$((i+1)); done ;;
      file_b.py) i=1; while [ "$i" -le 20 ]; do echo "B_LINE_$i"; i=$((i+1)); done ;;
      file_c.py) i=1; while [ "$i" -le 20 ]; do echo "C_LINE_$i"; i=$((i+1)); done ;;
    esac
  else
    i=1; while [ "$i" -le 20 ]; do echo "A_LINE_$i"; i=$((i+1)); done
    i=1; while [ "$i" -le 20 ]; do echo "B_LINE_$i"; i=$((i+1)); done
    i=1; while [ "$i" -le 20 ]; do echo "C_LINE_$i"; i=$((i+1)); done
  fi
}
'
run_block "scenario A (partial, 3 files)" "file_a.py
file_b.py
file_c.py" 3 50 "$STUB_A"
OUT_A="$LAST_BLOCK_OUTPUT"
HEADER_A="$(extract_section "$OUT_A" "===HEADER-START===" "===HEADER-END===")"
FULL_A="$(extract_section "$OUT_A" "===FULL-START===" "===FULL-END===")"

case "$HEADER_A" in *"PARTIAL DIFF"*) ok "A: header says PARTIAL DIFF";; *) bad "A: header missing PARTIAL DIFF — got: $HEADER_A";; esac
case "$HEADER_A" in *"2 of 3 files"*) ok "A: header reports correct file count (2 of 3)";; *) bad "A: wrong file count — got: $HEADER_A";; esac
case "$HEADER_A" in *"40 of 60 total diff lines"*) ok "A: header reports correct line count (40 of 60)";; *) bad "A: wrong line count — got: $HEADER_A";; esac
case "$HEADER_A" in *"file_c.py"*) ok "A: omitted file (file_c.py) named in header";; *) bad "A: omitted file not named — got: $HEADER_A";; esac
case "$FULL_A" in *"A_LINE_20"*) ok "A: file_a captured WHOLE (last line present, not cut mid-file)";; *) bad "A: file_a truncated mid-file";; esac
case "$FULL_A" in *"B_LINE_20"*) ok "A: file_b captured WHOLE (last line present)";; *) bad "A: file_b truncated mid-file";; esac
case "$FULL_A" in *"C_LINE"*) bad "A: omitted file_c leaked into DIFF_FULL — got a C_LINE";; *) ok "A: omitted file_c entirely absent from DIFF_FULL (whole-file cut, not partial)";; esac

# ── Scenario B: 1 file (10 lines), budget=50 → regression, COMPLETE, no PARTIAL
STUB_B='
git_rig() {
  if [ "${3:-}" = "--" ]; then
    i=1; while [ "$i" -le 10 ]; do echo "X_LINE_$i"; i=$((i+1)); done
  else
    i=1; while [ "$i" -le 10 ]; do echo "X_LINE_$i"; i=$((i+1)); done
  fi
}
'
run_block "scenario B (regression, complete)" "file_x.py" 1 50 "$STUB_B"
OUT_B="$LAST_BLOCK_OUTPUT"
HEADER_B="$(extract_section "$OUT_B" "===HEADER-START===" "===HEADER-END===")"
FULL_B="$(extract_section "$OUT_B" "===FULL-START===" "===FULL-END===")"

case "$HEADER_B" in *"FULL DIFF"*"complete"*) ok "B: header says FULL DIFF (complete)";; *) bad "B: header wrong for a within-budget diff — got: $HEADER_B";; esac
case "$HEADER_B" in *"PARTIAL"*) bad "B: header wrongly says PARTIAL on a complete diff";; *) ok "B: header correctly omits PARTIAL";; esac
case "$HEADER_B" in *"nothing omitted"*) ok "B: header states nothing omitted";; *) bad "B: header missing 'nothing omitted' — got: $HEADER_B";; esac
case "$FULL_B" in *"X_LINE_10"*) ok "B: complete diff content present";; *) bad "B: complete diff content missing";; esac

# ── Scenario C: file 1 (30 lines) ALONE exceeds budget=10 → still shown WHOLE
#    (never cut mid-hunk); file 2 (5 lines) fully omitted.
STUB_C='
git_rig() {
  if [ "${3:-}" = "--" ]; then
    case "${4:-}" in
      big_file.py) i=1; while [ "$i" -le 30 ]; do echo "BIG_LINE_$i"; i=$((i+1)); done ;;
      small_file.py) i=1; while [ "$i" -le 5 ]; do echo "SMALL_LINE_$i"; i=$((i+1)); done ;;
    esac
  else
    i=1; while [ "$i" -le 30 ]; do echo "BIG_LINE_$i"; i=$((i+1)); done
    i=1; while [ "$i" -le 5 ]; do echo "SMALL_LINE_$i"; i=$((i+1)); done
  fi
}
'
run_block "scenario C (first file exceeds budget alone)" "big_file.py
small_file.py" 2 10 "$STUB_C"
OUT_C="$LAST_BLOCK_OUTPUT"
HEADER_C="$(extract_section "$OUT_C" "===HEADER-START===" "===HEADER-END===")"
FULL_C="$(extract_section "$OUT_C" "===FULL-START===" "===FULL-END===")"

case "$HEADER_C" in *"1 of 2 files"*) ok "C: header reports 1 of 2 files shown";; *) bad "C: wrong file count — got: $HEADER_C";; esac
case "$HEADER_C" in *"30 of 35 total diff lines"*) ok "C: header reports correct line count (30 of 35)";; *) bad "C: wrong line count — got: $HEADER_C";; esac
case "$FULL_C" in *"BIG_LINE_30"*) ok "C: oversized first file still captured WHOLE (last line present)";; *) bad "C: first file was cut instead of shown whole";; esac
case "$FULL_C" in *"SMALL_LINE"*) bad "C: omitted small_file leaked into DIFF_FULL";; *) ok "C: second file cleanly omitted (whole-file cut)";; esac
case "$HEADER_C" in *"small_file.py"*) ok "C: omitted file named in header";; *) bad "C: omitted file not named — got: $HEADER_C";; esac

# ── Mutation control: prove this harness actually detects the pre-fix shape.
# Reproduce the ORIGINAL bug (header hardcoded to "FULL"/"first 2000 lines"
# regardless of truncation) and confirm scenario A's assertions would have
# caught it — i.e. this test is not vacuously green.
MUTATED_BLOCK='DIFF_FULL=$(git_rig diff "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | head -2000 || true)
DIFF_HEADER="FULL DIFF (first 2000 lines):"'
MUT_OUT="$(
  bash -c '
    set -euo pipefail
    DEFAULT_BRANCH="main"; BRANCH="feature"
    '"$STUB_A"'
    '"$MUTATED_BLOCK"'
    echo "===HEADER-START==="; printf "%s\n" "$DIFF_HEADER"; echo "===HEADER-END==="
  ' 2>&1
)"
MUT_HEADER="$(extract_section "$MUT_OUT" "===HEADER-START===" "===HEADER-END===")"
case "$MUT_HEADER" in
  *"PARTIAL"*) bad "mutation control: pre-fix header unexpectedly contains PARTIAL — harness cannot distinguish fixed from broken" ;;
  *)           ok "mutation control: pre-fix hardcoded header correctly does NOT say PARTIAL (proves scenario A's assertion is load-bearing, not vacuous)" ;;
esac

# ── Drift guards on the shipped source ────────────────────────────────────────
if grep -Eq '^\$DIFF_HEADER$' "$DISPATCHER"; then
  ok "shipped task template embeds \$DIFF_HEADER (not a hardcoded string)"
else
  bad "shipped task template no longer embeds \$DIFF_HEADER — drift"
fi
if grep -Eq '^FULL DIFF \(first 2000 lines\):$' "$DISPATCHER"; then
  bad "shipped source still contains the old unconditional 'FULL DIFF (first 2000 lines):' template line"
else
  ok "old unconditional 'FULL DIFF (first 2000 lines):' template line is gone"
fi
if grep -q 'GATE_DIFF_LINE_BUDGET="\${GATE_DIFF_LINE_BUDGET:-2000}"' "$DISPATCHER"; then
  ok "GATE_DIFF_LINE_BUDGET tunable present with the original 2000-line default (no behavior change beyond the fix)"
else
  bad "GATE_DIFF_LINE_BUDGET default missing/changed — drift"
fi

echo "== gate-diff-truncation-marker: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
