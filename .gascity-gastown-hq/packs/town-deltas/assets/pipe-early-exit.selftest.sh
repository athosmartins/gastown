#!/usr/bin/env bash
# pipe-early-exit.selftest.sh — ga-ebuj6c: sister family to pipefail-grepq.selftest.sh
# (C10/ga-5bxuam). Under `set -e` + pipefail, `<writer> | head|awk-exit|grep -m|sed q`
# lets the reader close the pipe once it has what it wants while the writer may still
# be mid-write; the writer catches SIGPIPE, pipefail elevates that 141 over the
# reader's own 0, and (unlike C10) the CAPTURED VALUE survives correctly either way —
# only the exit code is corrupted. That matters only when a bare `var=$(...)` (or the
# pipeline's own last-statement position) hands that corrupted code to errexit, which
# aborts the whole script. See error-empty-conflation-scan.sh's C11 header comment for
# the full triage note.
#
# This file proves, against the REAL production script (not fixtures):
#   A. the historical ga-8w22n regression suite (pilot-dispatcher-branch-detection-
#      race.selftest.sh) still exists and still passes — NOT re-implemented here.
#      That file already extracts and load-tests the exact 3 functions this bead's
#      --count=1 hardening touches (_beadid_has_branch, _beadid_has_crew_branch,
#      _beadid_matched_crew_branch_ref) against a synthetic multi-thousand-ref repo;
#      duplicating its fixture here would be the same maintenance burden for zero
#      new coverage (its own header notes the race is probabilistic, not guaranteed
#      on every run — a second copy would not make it more deterministic).
#   B. rebase_content_lost_paths (quality-gate-dispatcher.sh, THIS bead's own new
#      finding) — the exact `git diff --name-only ... | head -20` idiom reliably
#      SIGPIPEs (141, every time) against a real >150 KB diff; the function's
#      guard treats that specific code as success (truncated output stays
#      identical) while any OTHER git-diff failure now surfaces this function's
#      own `<could not compute: diff-failed rc=N>` sentinel instead of an empty
#      string indistinguishable from "0 paths differ" (GATE-FEEDBACK on this
#      bead's first submission flagged a bare `|| true` for reopening exactly
#      that could-not-compute-vs-empty conflation — see ga-pgxs78).
#   C. the 3 `--count=1` hardenings this bead added to pilot-dispatcher.sh
#      (for-each-ref call sites) are present in the shipped source.
#   D. the C11 detector (error-empty-conflation-scan.sh) exists, is wired into
#      run_scan, and production's current finding count has not grown past the
#      baseline this bead catalogued (a ratchet against NEW unguarded sites, not a
#      to-zero assertion — C11 findings are expected to persist: see its header
#      for why most of them are already known-safe by size or by call shape).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_DIR="$(cd "$SELF_DIR/../../.." && pwd)"          # .../.gascity-gastown-hq
P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

# extract_fn <file> <name> — the function definition, from '^name() {' to the first '^}'.
extract_fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}/ {exit}' "$1"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

echo "── A. ga-8w22n regression suite (pilot-dispatcher-branch-detection-race.selftest.sh) ──"
RACE_SUITE="$SELF_DIR/pilot-dispatcher-branch-detection-race.selftest.sh"
if [ ! -f "$RACE_SUITE" ]; then
  bad "pilot-dispatcher-branch-detection-race.selftest.sh is missing — the ga-8w22n regression guard for the 3 for-each-ref functions this bead also hardened is gone"
elif bash "$RACE_SUITE" >"$TMPD/race-suite.log" 2>&1; then
  ok "pilot-dispatcher-branch-detection-race.selftest.sh still passes ($(tail -1 "$TMPD/race-suite.log"))"
else
  bad "pilot-dispatcher-branch-detection-race.selftest.sh FAILED — see $TMPD/race-suite.log: $(tail -5 "$TMPD/race-suite.log" | tr '\n' ' ')"
fi

echo "── B. rebase_content_lost_paths (quality-gate-dispatcher.sh) on a >150 KB diff ──"
FIXTURE_REPO="$TMPD/repo"
git init -q "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" config user.email t@t.invalid
git -C "$FIXTURE_REPO" config user.name selftest
echo base > "$FIXTURE_REPO/README.md"
git -C "$FIXTURE_REPO" add README.md
git -C "$FIXTURE_REPO" commit -q -m base
MAIN_SHA="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"

# Two trees, SAME 3000 paths, DIFFERENT content at each (a genuine "content lost"
# shape, and it forces `git diff --name-only` to report exactly those 3000 modified
# paths — same path in both trees rules out rename-pairing, which collapsed an
# earlier draft of this fixture's add+delete pairs down to nothing worth measuring).
BLOB_A="$(printf 'x' | git -C "$FIXTURE_REPO" hash-object -w --stdin)"
BLOB_B="$(printf 'y' | git -C "$FIXTURE_REPO" hash-object -w --stdin)"
{ git -C "$FIXTURE_REPO" ls-tree HEAD
  for i in $(seq -w 1 3000); do printf '100644 blob %s\tpacks/town-deltas/assets/synthetic-fixture-file-%s.txt\n' "$BLOB_A" "$i"; done
} | git -C "$FIXTURE_REPO" update-index --index-info
ORIG_TREE="$(git -C "$FIXTURE_REPO" write-tree)"
ORIG_TIP="$(git -C "$FIXTURE_REPO" commit-tree "$ORIG_TREE" -p "$MAIN_SHA" -m orig)"
git -C "$FIXTURE_REPO" read-tree "$MAIN_SHA"
{ git -C "$FIXTURE_REPO" ls-tree HEAD
  for i in $(seq -w 1 3000); do printf '100644 blob %s\tpacks/town-deltas/assets/synthetic-fixture-file-%s.txt\n' "$BLOB_B" "$i"; done
} | git -C "$FIXTURE_REPO" update-index --index-info
NEW_TREE="$(git -C "$FIXTURE_REPO" write-tree)"
NEW_TIP="$(git -C "$FIXTURE_REPO" commit-tree "$NEW_TREE" -p "$MAIN_SHA" -m newtip)"
git -C "$FIXTURE_REPO" read-tree "$MAIN_SHA"

EXPECTED_TREE="$(git -C "$FIXTURE_REPO" merge-tree --write-tree "$MAIN_SHA" "$ORIG_TIP" 2>/dev/null)"
ACTUAL_TREE="$(git -C "$FIXTURE_REPO" rev-parse "${NEW_TIP}^{tree}")"
DIFF_BYTES=$(git -C "$FIXTURE_REPO" diff --name-only "$ACTUAL_TREE" "$EXPECTED_TREE" 2>/dev/null | wc -c | tr -d ' ')
if [ "$EXPECTED_TREE" = "$ORIG_TREE" ] && [ "$DIFF_BYTES" -gt 100000 ]; then
  ok "fixture diff is a clean merge (merge-tree == orig tree) with a ${DIFF_BYTES}-byte name-only diff"
else
  bad "fixture setup is off: merge-tree='$EXPECTED_TREE' (want '$ORIG_TREE'), diff_bytes=$DIFF_BYTES"
fi

# B1: the exact idiom, isolated — this is the shape that changed in this bead.
old_rc=0
( set -euo pipefail
  git -C "$FIXTURE_REPO" diff --name-only "$ACTUAL_TREE" "$EXPECTED_TREE" 2>/dev/null | head -20 >/dev/null
) || old_rc=$?
if [ "$old_rc" -eq 141 ]; then
  ok "OLD idiom (\`git diff --name-only ... | head -20\`, no guard) SIGPIPEs (rc=141) on the >150 KB diff — this is what makes it a real test, not a tautology"
else
  bad "OLD idiom did not SIGPIPE (rc=$old_rc) — fixture stopped exercising the failure mode; strengthen it before trusting this section"
fi

new_out="$(
  ( set -euo pipefail
    git -C "$FIXTURE_REPO" diff --name-only "$ACTUAL_TREE" "$EXPECTED_TREE" 2>/dev/null | head -20 || true
  )
)"
new_rc=$?
new_lines=$(printf '%s\n' "$new_out" | grep -c .)
if [ "$new_rc" -eq 0 ] && [ "$new_lines" -eq 20 ]; then
  ok "NEW idiom (with \`|| true\`, as shipped) survives (rc=0) and still returns all 20 truncated paths"
else
  bad "NEW idiom: expected rc=0 and 20 lines, got rc=$new_rc lines=$new_lines"
fi

# B2: the real, full production function, end to end (not a copy) — a correctness
# regression check. NOTE: calling it as a pipe stage (rebase_content_lost_paths ...
# | tr ..., its actual call shape at every production call site) did not reproduce
# the abort even with the OLD idiom during this bead's own investigation, for a
# reason that investigation could not fully pin down (isolated in a controlled
# shell to rule out git specifics, packed-vs-loose refs, and 2- vs 3-stage pipes).
# The `|| true` fix is correct and harmless regardless (it can only ever suppress
# an abort that would otherwise happen, never cause a new one); this section
# confirms the function itself still behaves correctly today, it does not re-assert
# the abort at the full-function-as-pipe-stage level.
GD="$SELF_DIR/quality-gate-dispatcher.sh"
FN1="$(extract_fn "$GD" rebase_wt_git_dir)"
FN2="$(extract_fn "$GD" rebase_git_attributes_file)"
FN3="$(extract_fn "$GD" rebase_content_lost_paths)"
if [ -z "$FN1" ] || [ -z "$FN2" ] || [ -z "$FN3" ]; then
  bad "rebase_wt_git_dir / rebase_git_attributes_file / rebase_content_lost_paths: one or more not found in $GD"
else
  if ! printf '%s\n' "$FN3" | grep -qF '<could not compute: diff-failed rc='; then
    bad "rebase_content_lost_paths no longer contains the diff-failed sentinel — did the rc-discriminating fix get reverted or reworded?"
  else
    ok "rebase_content_lost_paths carries the shipped diff-failed sentinel"
  fi
  full_out="$(
    ( set -euo pipefail
      eval "$FN1"; eval "$FN2"; eval "$FN3"
      rebase_content_lost_paths "$FIXTURE_REPO" "$MAIN_SHA" "$ORIG_TIP" "$NEW_TIP" | tr '\n' ' '
    ) 2>"$TMPD/b2-stderr"
  )"
  full_rc=$?
  full_words=$(printf '%s' "$full_out" | grep -oE 'synthetic-fixture-file-[0-9]+\.txt' | wc -l | tr -d ' ')
  if [ "$full_rc" -eq 0 ] && [ "$full_words" -eq 20 ]; then
    ok "rebase_content_lost_paths end-to-end on the same >150 KB diff: rc=0, 20 paths returned"
  else
    bad "rebase_content_lost_paths end-to-end: expected rc=0 and 20 paths, got rc=$full_rc paths=$full_words stderr=$(head -c 300 "$TMPD/b2-stderr" 2>/dev/null)"
  fi

  # B3: the GATE-FEEDBACK case — a genuine (non-SIGPIPE) git-diff failure
  # must surface the function's own sentinel, never an empty string that
  # reads as "0 paths differ". Shadow `git` so ONLY the `diff` call inside
  # rebase_content_lost_paths fails (rc=17, an arbitrary non-141 marker);
  # every other git subcommand the function chain needs (rev-parse,
  # merge-tree, show) has no "diff" argument and passes through untouched
  # (verified above: rebase_wt_git_dir uses rev-parse, rebase_git_attributes_file
  # uses show, and this function's own earlier calls use merge-tree/rev-parse).
  sentinel_out="$(
    ( set -euo pipefail
      eval "$FN1"; eval "$FN2"; eval "$FN3"
      git() {
        for _a in "$@"; do [ "$_a" = "diff" ] && return 17; done
        command git "$@"
      }
      rebase_content_lost_paths "$FIXTURE_REPO" "$MAIN_SHA" "$ORIG_TIP" "$NEW_TIP"
    ) 2>"$TMPD/b3-stderr"
  )"
  sentinel_rc=$?
  if [ "$sentinel_rc" -eq 0 ] && [ "$sentinel_out" = "<could not compute: diff-failed rc=17>" ]; then
    ok "genuine (non-SIGPIPE) git-diff failure returns the diff-failed sentinel, not an empty/successful-looking result"
  else
    bad "expected rc=0 and '<could not compute: diff-failed rc=17>', got rc=$sentinel_rc out='$sentinel_out' stderr=$(head -c 300 "$TMPD/b3-stderr" 2>/dev/null)"
  fi
fi

echo "── C. the 3 --count=1 hardenings (pilot-dispatcher.sh) are present ──"
PD="$SELF_DIR/pilot-dispatcher.sh"
if [ ! -f "$PD" ]; then
  # Third state: `grep -c` on a missing file prints NOTHING (not "0") and
  # exits 2 — feeding that straight into `-ge 3` below would crash with
  # "integer expression expected" instead of reporting a clean failure.
  bad "pilot-dispatcher.sh not found at $PD — cannot check the --count=1 hardenings"
else
  count_hits=$(grep -c 'for-each-ref --count=1' "$PD" 2>/dev/null)
  if [ "$count_hits" -ge 3 ]; then
    ok "pilot-dispatcher.sh has $count_hits 'for-each-ref --count=1' site(s) (expected >= 3)"
  else
    bad "pilot-dispatcher.sh has only $count_hits 'for-each-ref --count=1' site(s), expected >= 3 — a hardening may have been reverted"
  fi
fi

echo "── D. the C11 detector exists, is wired in, and production findings stay at/under baseline ──"
SCANNER="$SELF_DIR/error-empty-conflation-scan.sh"
if [ -f "$SCANNER" ]; then
  # shellcheck disable=SC1090
  CONFLATION_SCAN_LIB_ONLY=1 . "$SCANNER" || true
fi
if ! type scan_pipe_early_exit_files >/dev/null 2>&1; then
  bad "error-empty-conflation-scan.sh has no C11 detector (scan_pipe_early_exit_files) — nothing to ratchet with"
else
  if grep -q 'scan_pipe_early_exit "\$f"' "$SCANNER"; then
    ok "run_scan calls scan_pipe_early_exit (the silent-ignorance monitor will alert on NEW occurrences)"
  else
    bad "run_scan does not call scan_pipe_early_exit — new occurrences would go unseen"
  fi

  PROD_LIST="$(cd "$CITY_DIR" 2>/dev/null && find packs scripts -type f -name '*.sh' \
      -not -name '*.selftest.sh' -not -name '*.test.sh' -not -path '*/tests/*' \
      -not -path '*/.gc/*' -not -path '*/backup/*' -not -path '*/node_modules/*' -not -path '*/venv/*' \
      -not -path '*/__pycache__/*' -not -path '*/.local-patches/*' 2>/dev/null | sort)"
  n_files=$(grep -c . <<<"$PROD_LIST")
  if [ "$n_files" -lt 50 ]; then
    bad "ratchet scanned only $n_files production files (expected >= 50) — an empty scan must not read as 'clean'"
  else
    ok "ratchet scans $n_files production-class scripts under packs/ and scripts/"
    # Baseline captured 20/09/2026 while writing ga-ebuj6c, after the 4 fixes in
    # this bead landed: 33 findings, all manually triaged safe (size-bounded
    # producer, or a full-drain filter ahead of the reader — see C11's own
    # header). This is a RATCHET against new unguarded sites, not a to-zero
    # assertion; C11 findings are expected to persist. Bump this only after
    # triaging exactly what grew and confirming it is ALSO safe — never bump it
    # to silence a failure without reading the new finding first.
    #
    # Bumped to 34 (GATE-FEEDBACK fix-attempt, gate_run ga-fk9g4k): the C11
    # scanner's own guard is purely textual — it skips any buffered statement
    # containing a literal `||` (error-empty-conflation-scan.sh, C11AWK:
    # `buf !~ /\|\|/`), which is why the OLD `| head -20 || true` line in
    # rebase_content_lost_paths (quality-gate-dispatcher.sh) was never
    # flagged. The gate's fix replaced that bare `|| true` (which masked
    # genuine git-diff failures, not just SIGPIPE) with
    # `if _diff_out=$(... | head -20); then` — a strictly SAFER shape (still
    # immune to `set -e` because it is an if-condition, but now also branches
    # on the real exit code instead of discarding it) that just happens to
    # carry no literal `||` on its own line, so the scanner's heuristic now
    # sees it as a new, unguarded-looking site. Triaged manually: it is safe
    # by construction (see the function's own comment above the fix). Not
    # fixing the scanner's `||`-only suppression heuristic here — that is a
    # separate, shared-file change out of scope for this fix-attempt.
    BASELINE=34
    # Third state, explicit: a `cd` failure here must never fall through to
    # comparing an empty string with `-le` (bash would throw "integer
    # expression expected" — a confusing crash, not a reported failure). Keep
    # the failure-to-cd and the counted-findings paths fully separate so
    # "could not run the ratchet" and "ran it, 0 findings" can never collapse
    # into the same outcome.
    if ! cd "$CITY_DIR" 2>/dev/null; then
      bad "could not cd to CITY_DIR ($CITY_DIR) to run the C11 ratchet — treating as UNKNOWN, not as a passing 0-findings result"
    else
      # shellcheck disable=SC2046
      PROD_FINDINGS="$(scan_pipe_early_exit_files $(printf '%s ' $PROD_LIST) | grep -c ':C11:')"
      cd "$SELF_DIR" 2>/dev/null || true
      if [ "$PROD_FINDINGS" -le "$BASELINE" ]; then
        ok "$PROD_FINDINGS C11 finding(s) in production (baseline $BASELINE) — no growth"
      else
        bad "$PROD_FINDINGS C11 finding(s) in production, up from the $BASELINE baseline — a NEW unguarded head/awk-exit/grep-m/sed-q site landed; triage it before bumping the baseline"
      fi
    fi
  fi
fi

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
