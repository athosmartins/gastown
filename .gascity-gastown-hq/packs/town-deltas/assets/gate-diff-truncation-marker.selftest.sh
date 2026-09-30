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
# Strategy: extract the dispatcher's LIVE call site VERBATIM (`DIFF_SUMMARY=$(gate_diff_summary ...`
# through the `gate_build_diff_payload ...` call — the stable anchors) and exercise it, with
# gate-review-task.lib.sh sourced, under the SAME `set -euo pipefail` the dispatcher uses, against
# a stubbed git_rig() returning controlled, exact-line-count fake diffs. Then drift-guard the
# shipped source and mutation-test the harness itself (prove it goes RED against the pre-fix
# hardcoded-header shape).
# ga-gnr3tw: the truncation logic moved from the dispatcher into gate_build_diff_payload (the lib the
# builder's pre-gate-review.sh shares), so what the harness executes is now the dispatcher's real call
# site plus the lib function behind it; the header template drift guards below read the lib.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
LIB="$SELF_DIR/gate-review-task.lib.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-diff-truncation-marker.selftest =="

BLOCK="$(awk '/^DIFF_SUMMARY=\$\(gate_diff_summary/{p=1} p{print} /^gate_build_diff_payload /{exit}' "$DISPATCHER")"
if [ -z "$BLOCK" ]; then
  bad "could not locate the dispatcher call site of the diff payload (anchors missing/renamed)"
else
  ok "located the dispatcher call site of the diff payload ($(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ') lines)"
fi
if [ -r "$LIB" ]; then ok "prompt lib present ($LIB)"; else bad "prompt lib missing: $LIB"; fi

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
      source "'"$LIB"'"
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
      ":(top,literal)file_a.py") i=1; while [ "$i" -le 20 ]; do echo "A_LINE_$i"; i=$((i+1)); done ;;
      ":(top,literal)file_b.py") i=1; while [ "$i" -le 20 ]; do echo "B_LINE_$i"; i=$((i+1)); done ;;
      ":(top,literal)file_c.py") i=1; while [ "$i" -le 20 ]; do echo "C_LINE_$i"; i=$((i+1)); done ;;
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
      ":(top,literal)big_file.py") i=1; while [ "$i" -le 30 ]; do echo "BIG_LINE_$i"; i=$((i+1)); done ;;
      ":(top,literal)small_file.py") i=1; while [ "$i" -le 5 ]; do echo "SMALL_LINE_$i"; i=$((i+1)); done ;;
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

# ── ga-gnr3tw (gate ga-46y473, attempt 1): per-file diffs must resolve from ANY cwd ────────────────────────────────────
# `git diff --name-only` prints ROOT-relative names; the gascity rig runs git from `.gascity-gastown-hq/`, a SUBDIRECTORY of
# the toplevel, where a plain per-file pathspec matched nothing: every per-file diff came back empty, and over budget the
# reviewer was told "PARTIAL DIFF - showing N of N files" over a blank body. The builder's pre-gate-review.sh runs git from the
# toplevel, so builder and gate were shown DIFFERENT payloads for exactly the big gascity diffs. Scenarios D and E use a real
# git repository (hermetic: no user config) and the real lib, not a stub that agrees with the fix by construction.
T="$(mktemp -d "${TMPDIR:-/tmp}/gate-trunc.XXXXXX")" || { echo "mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
# .a-outside/ sorts BEFORE .hq/ in git name order, so a file outside the runner's cwd is the FIRST one shown
TOP="$T/top"; mkdir -p "$TOP/.hq/commands" "$TOP/.a-outside"
git -C "$TOP" init -q && git -C "$TOP" symbolic-ref HEAD refs/heads/main
gen() { i=1; while [ "$i" -le "$3" ]; do echo "$2 line $i"; i=$((i+1)); done > "$1"; }   # gen <file> <tag> <n-lines>
gen "$TOP/.hq/commands/a.md" base 3; gen "$TOP/.a-outside/b.md" base 3; gen "$TOP/.hq/c.sh" base 3
git -C "$TOP" add -A && git -C "$TOP" commit -q -m base && git -C "$TOP" update-ref refs/remotes/origin/main HEAD
git -C "$TOP" checkout -q -b feature
gen "$TOP/.hq/commands/a.md" feat 30; gen "$TOP/.a-outside/b.md" feat 8; gen "$TOP/.hq/c.sh" feat 30
git -C "$TOP" add -A && git -C "$TOP" commit -q -m feat && git -C "$TOP" update-ref refs/remotes/origin/feature HEAD
CF_D="$(git -C "$TOP" diff --name-only origin/main...origin/feature)"
NF_D="$(printf '%s\n' "$CF_D" | awk 'NF { n++ } END { print n + 0 }')"
if [ "$NF_D" = "3" ]; then ok "D fixture: a real repo whose 3 changed files sit under .hq/ (the runner's cwd) and .a-outside/ (outside it)"
else bad "D fixture: expected 3 changed files, got $NF_D"; fi
# the gate's runner (git -C <subdirectory>) and the builder's runner (git -C <toplevel>)
STUB_SUB="git_rig() { git -C '$TOP/.hq' \"\$@\"; }"
STUB_TOP="git_rig() { git -C '$TOP' \"\$@\"; }"

run_block "scenario D1 (real git, runner in a SUBDIRECTORY - the gate on the gascity rig)" "$CF_D" "$NF_D" 60 "$STUB_SUB"
OUT_D1="$LAST_BLOCK_OUTPUT"
HEADER_D1="$(extract_section "$OUT_D1" "===HEADER-START===" "===HEADER-END===")"
FULL_D1="$(extract_section "$OUT_D1" "===FULL-START===" "===FULL-END===")"
run_block "scenario D2 (same diff, runner at the TOPLEVEL - the builder)" "$CF_D" "$NF_D" 60 "$STUB_TOP"
OUT_D2="$LAST_BLOCK_OUTPUT"
HEADER_D2="$(extract_section "$OUT_D2" "===HEADER-START===" "===HEADER-END===")"
FULL_D2="$(extract_section "$OUT_D2" "===FULL-START===" "===FULL-END===")"

case "$HEADER_D1" in *"PARTIAL DIFF"*) ok "D1: over budget -> PARTIAL header";; *) bad "D1: expected a PARTIAL header — got: $HEADER_D1";; esac
case "$FULL_D1" in *"diff --git a/.hq/c.sh"*) ok "D1: a file INSIDE the runner's subdirectory is really in the payload (the per-file pathspec resolved)";; *) bad "D1: BLANK BODY under a PARTIAL header — the per-file diff of .hq/c.sh did not resolve from the subdirectory";; esac
case "$FULL_D1" in *"diff --git a/.a-outside/b.md"*) ok "D1: a file OUTSIDE the runner's subdirectory is in the payload too (:(top) names the same file from any cwd)";; *) bad "D1: the per-file diff of .a-outside/b.md did not resolve from the subdirectory";; esac
case "$HEADER_D1" in *"showing 2 of 3 files"*) ok "D1: header counts the two files that are really shown (2 of 3)";; *) bad "D1: expected 'showing 2 of 3 files' — got: $HEADER_D1";; esac
case "$HEADER_D1" in *"showing 0 of"*) bad "D1: header claims 0 files shown — got: $HEADER_D1";; *) ok "D1: header does not claim zero files shown";; esac
if [ "$FULL_D1" = "$FULL_D2" ] && [ "$HEADER_D1" = "$HEADER_D2" ]; then ok "D1 == D2: the gate (subdirectory) and the builder (toplevel) are shown a byte-identical header and payload"
else bad "D: the gate and the builder are shown DIFFERENT payloads for the same diff"; fi

# D3 mutation control: the previous pathspec (plain <name>) must reproduce the blank body from the subdirectory — else D1
# is green for the wrong reason and cannot tell the fix from the bug.
sed 's/-- ":(top,literal)\$_df"/-- "$_df"/' "$LIB" > "$T/lib.oldpathspec.sh"
if cmp -s "$LIB" "$T/lib.oldpathspec.sh"; then
  bad "D3 mutation control: the pathspec line in the lib was not found, so the mutation did not apply"
else
  LIB_SAVED="$LIB"; LIB="$T/lib.oldpathspec.sh"
  run_block "scenario D3 (MUTANT: the previous plain pathspec, runner in a subdirectory)" "$CF_D" "$NF_D" 60 "$STUB_SUB"
  LIB="$LIB_SAVED"
  FULL_D3="$(extract_section "$LAST_BLOCK_OUTPUT" "===FULL-START===" "===FULL-END===")"
  case "$FULL_D3" in
    *"diff --git"*) bad "D3 mutation control: the old pathspec unexpectedly produced diff text from a subdirectory — D1 cannot discriminate" ;;
    *)              ok "D3 mutation control: the previous plain pathspec gives a BLANK body from the subdirectory (the bug the gate found), so D1 is load-bearing" ;;
  esac
fi

# ── Scenario E: a per-file diff that comes back EMPTY is listed as omitted, never counted as shown ─────────────────────
# (third state: "shown, and there was nothing to see" is not the same answer as "could not get it")
STUB_E='
git_rig() {
  if [ "${3:-}" = "--" ]; then
    case "${4:-}" in
      ":(top,literal)file_e.py") : ;;
      ":(top,literal)file_a.py") i=1; while [ "$i" -le 20 ]; do echo "A_LINE_$i"; i=$((i+1)); done ;;
      ":(top,literal)file_f.py") i=1; while [ "$i" -le 5 ]; do echo "F_LINE_$i"; i=$((i+1)); done ;;
    esac
  else
    i=1; while [ "$i" -le 20 ]; do echo "A_LINE_$i"; i=$((i+1)); done
    i=1; while [ "$i" -le 5 ]; do echo "F_LINE_$i"; i=$((i+1)); done
  fi
}
'
run_block "scenario E (first file's per-file diff is empty)" "file_e.py
file_a.py
file_f.py" 3 10 "$STUB_E"
OUT_E="$LAST_BLOCK_OUTPUT"
HEADER_E="$(extract_section "$OUT_E" "===HEADER-START===" "===HEADER-END===")"
FULL_E="$(extract_section "$OUT_E" "===FULL-START===" "===FULL-END===")"
case "$HEADER_E" in *"1 of 3 files"*) ok "E: the empty file is NOT counted as shown (1 of 3)";; *) bad "E: header counts an empty diff as shown — got: $HEADER_E";; esac
case "$HEADER_E" in *"file_e.py (its per-file diff came back empty"*) ok "E: the empty file is named in the header with the reason";; *) bad "E: the empty file is not explained — got: $HEADER_E";; esac
case "$HEADER_E" in *"OMITTED FILES (2)"*) ok "E: OMITTED FILES count (2) matches what is listed (empty file + over-budget file)";; *) bad "E: OMITTED FILES count is wrong — got: $HEADER_E";; esac
case "$FULL_E" in *"A_LINE_20"*) ok "E: the first NON-EMPTY file is still taken whole";; *) bad "E: the first non-empty file was not taken whole";; esac
case "$FULL_E" in *"F_LINE"*) bad "E: an over-budget file leaked into the payload";; *) ok "E: the over-budget file stays out";; esac

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
if grep -Eq '^\$DIFF_HEADER$' "$LIB"; then
  ok "shipped task template embeds \$DIFF_HEADER (not a hardcoded string)"
else
  bad "shipped task template no longer embeds \$DIFF_HEADER — drift"
fi
if grep -Eq '^FULL DIFF \(first 2000 lines\):$' "$LIB" "$DISPATCHER"; then
  bad "shipped source still contains the old unconditional 'FULL DIFF (first 2000 lines):' template line (lib or dispatcher)"
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
