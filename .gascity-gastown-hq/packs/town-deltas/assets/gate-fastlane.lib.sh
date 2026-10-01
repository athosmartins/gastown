#!/usr/bin/env bash
# gate-fastlane.lib.sh — ga-atsahv: the quality gate's DOC/TEST fast lane (no LLM reviewer).
#
# WHY. Athos, 2026-09-30, verbatim: "O gate só é necessário quando a gente vai colocar código novo em
# produção." Measured by the Mayor over 584 rounds since 16/09: ~96% of diffs touch production code, 2.6% are
# documentation only, 0.5% tests only (+doc), 0.3% prompt/doctrine text only. The 3% that cannot change what
# production does were paying for a full LLM review.
#
# WHAT. Every changed path is classified:
#   DOC     a POSITIVE list: .md/.txt/.csv/.rst inside a docs/ reports/ runbooks/ directory (any depth), and the
#           repository's own TOP-LEVEL README/CHANGELOG/CONTRIBUTING/LICENSE/NOTICE-style files. An .md that is on
#           no list is not a doc — "nobody listed it" must never read as "known harmless"
#   TEST    a tests/ test/ __tests__/ directory, test_* *_test.* *.test.* *.spec.* *.selftest.*
#   PROMPT  SKILL.md *CLAUDE*.md AGENTS.md *GEMINI*.md plugin.md PRIME.md *instructions*.md prompt*.md *.template.md,
#           anything under skills/ commands/ prompts/ template-fragments/ fragments/ formulas/ templates/ plugins/
#           .beads/ .claude/ — text that changes what an AGENT does (or is compiled into what agents run), i.e.
#           production, so it stays in the gate. A second net over known agent-facing places: the positive DOC list,
#           not this one, is what keeps an unlisted file out of the lane
#   CODE    everything else (JSON/TOML/YAML config and deploy_deps.json included; so is a README nested below the
#           top level, a SECRETS.md, a notes.md — anything the DOC list does not name)
# The fast lane is granted ONLY when EVERY file is DOC or TEST AND the mechanical checks pass: the added lines
# carry no run of 8+ digits (CPF, phone, any long id — a deliberately wide rule) and no credential shape
# (gate-fastlane-scan.py states what it does NOT cover), and each new or changed test that has a known
# runner runs and passes. Then the dispatcher merges through the SAME gate_finalize_run (content coherence,
# full-suite regression, merge-time rebase) with zero reviewers.
#
# THE ONE RULE. The fast lane is only ever GRANTED, never a verdict. Every path that is not a clean yes —
# a code file, a prompt file, a finding, a failing test, an unreadable diff, a git error, a missing scanner, a
# symlink, a quoted path, an empty list, the kill-switch — ends in the NORMAL gate, which is today's behavior.
# "Could not tell" and "no" must never produce different outcomes here: three states (yes / no / could not
# tell), and the last one is the inert one. GATE_LANE is reset to "normal" on entry and becomes "fast" on the
# very last line of the only success path, so an early return can never leave a stale "fast" behind.
#
# Source-only: this file defines functions and runs NOTHING at source time. The dispatcher is
# `set -euo pipefail` on macOS bash 3.2, so: no arrays (an empty array is an "unbound variable" error there),
# no ${v,,}, and every command that may fail is guarded — a failing command inside these functions must not be
# able to kill the daemon (ga-q4sadt).
#
# Outputs of gate_fastlane_decide (globals):
#   GATE_LANE         fast | normal
#   GATE_LANE_REASON  one line — why (the clean yes names what was checked). FREE TEXT: for people, free to be reworded.
#   GATE_LANE_REASON_CODE  a short stable token for the SAME decision — what gate-lane-tally.py buckets on, so rewording
#                     a sentence above can never silently move diffs between buckets (the tally once matched on the
#                     sentence, and every code/prompt diff landed in "touches the gate's own policy"). Every code is
#                     listed in gate-lane-tally.py's REASON_CODES: gate-lane-tally.selftest.sh fails when a code emitted here has no
#                     bucket (or a bucket has no producer), and gate-fastlane.selftest.sh §4e runs each decision through the real
#                     tally and fails when its bucket is not the one its code names.
#   GATE_LANE_FILES   "CLASS path" lines — the files that DECIDED (all of them for fast; the blockers for normal)
#   GATE_LANE_COUNTS  "doc=N test=N prompt=N code=N"
#   GATE_LANE_DIGEST  set ONLY with GATE_LANE=fast: the fingerprint of the exact diff that was scanned and whose tests ran
#
# A lane that is GRANTED is granted for a diff, not for a branch name: the merge pushes whatever origin/<branch> is when
# the push runs, minutes after the decision. gate_fastlane_confirm is asked IMMEDIATELY before the push, about the
# commit being pushed, and returns 0 only for the same diff (the gate's round-2 reproduction: a .py commit landing after a
# docs-only decision merged with zero reviewers). Its outputs: GATE_LANE_CONFIRM_CODE (diff-changed | no-longer-fast |
# switched-off | cannot-confirm — for tests and the operator's eye) and GATE_LANE_CONFIRM_WHY (one line, never a matched value).

# `|| true`: a failed cd inside the substitution is a live errexit trigger; with it the dir is just "" and the
# scanner lookup below reads as "scanner missing" (=> normal lane).
GATE_FASTLANE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || GATE_FASTLANE_DIR=""

# ── classification ──────────────────────────────────────────────────────────────────────────────────────────

# gate_fastlane_path_class <path> — pure. Prints DOC | TEST | PROMPT | CODE.
# Order matters: PROMPT first (a SKILL.md is never a "doc", even under tests/), then TEST, then DOC.
#
# DOC is a POSITIVE list; PROMPT and CODE are what is left. The first version made every .md a doc unless a NAME
# list said otherwise, so "nobody listed it" read as "known harmless" — and the gate's round-2 reviewer reproduced
# it with five files that agents load or obey and that were on no list (a go:embed'd polecat-CLAUDE.md template,
# plugins/*/plugin.md, .beads/PRIME.md, copilot-instructions.md): lane=fast, zero reviewers, where before this lane
# every .md got one. A markdown file is a document only when we can say where it lives. The PROMPT lists below are
# a second net over places agents are known to read; they are not what keeps unknown files out of the lane — the
# positive DOC list is.
gate_fastlane_path_class() {
  local p="${1#./}" lc base ext stem
  lc=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  base="${lc##*/}"
  ext=""
  case "$base" in *.*) ext="${base##*.}" ;; esac
  stem="$base"; [ -n "$ext" ] && stem="${base%.*}"

  case "/$lc" in
    */skills/*|*/.claude/*|*/commands/*|*/prompts/*|*/template-fragments/*|*/fragments/*|*/formulas/*|*/templates/*|*/plugins/*|*/.beads/*)
      echo PROMPT; return 0 ;;
  esac
  case "$base" in
    skill.md|*claude*.md|*gemini*.md|agents.md|plugin.md|prime.md|*instructions*.md|prompt*.md|prompt*.txt|system_prompt*|*.prompt|*.prompt.md|*.template.md|*.tmpl)
      echo PROMPT; return 0 ;;
  esac

  case "/$lc" in
    */tests/*|*/test/*|*/__tests__/*) echo TEST; return 0 ;;
  esac
  case "$base" in
    test_*|*_test.*|*.test.*|*.spec.*|*.selftest.*) echo TEST; return 0 ;;
  esac

  # DOC (1/2): a text file inside a docs/ reports/ runbooks/ directory, at any depth
  case "$ext" in
    md|txt|csv|rst)
      case "/$lc" in
        */docs/*|*/reports/*|*/runbooks/*) echo DOC; return 0 ;;
      esac
      ;;
  esac
  # DOC (2/2): the repository's own top-level README / CHANGELOG-style files (no directory part, a known stem, and
  # either no extension or a prose one) — never one nested deeper, where a README can sit beside code that loads it
  case "$p" in
    */*) ;;
    *)
      case "$stem" in
        readme|changelog|changes|history|contributing|license|licence|notice|authors|code_of_conduct)
          case "$ext" in ""|md|txt|rst) echo DOC; return 0 ;; esac ;;
      esac
      ;;
  esac
  echo CODE
  return 0
}

# gate_fastlane_test_runner <path> — pure. For a path already classed TEST, how the fast lane runs it:
#   bash     *.selftest.sh *.test.sh test_*.sh *_test.sh
#   pytest   test_*.py *_test.py *.selftest.py
#   unknown  an executable test in a language with no runner here (js/ts/go/...) — cannot be run => normal gate
#   none     a fixture / helper / data file under tests/ — inert, nothing to run
gate_fastlane_test_runner() {
  local lc base ext
  lc=$(printf '%s' "${1#./}" | tr '[:upper:]' '[:lower:]')
  base="${lc##*/}"
  ext=""
  case "$base" in *.*) ext="${base##*.}" ;; esac
  case "$base" in
    *.selftest.sh|*.test.sh|test_*.sh|*_test.sh) echo bash; return 0 ;;
    test_*.py|*_test.py|*.selftest.py) echo pytest; return 0 ;;
  esac
  case "$ext" in
    js|mjs|cjs|jsx|ts|tsx|go|rb|java|kt|rs|php|swift|cs|c|cc|cpp) echo unknown; return 0 ;;
  esac
  echo none
  return 0
}

# gate_fastlane_classify_raw <raw> — `git diff --raw --no-renames` text (lines
# `:oldmode newmode oldsha newsha STATUS<TAB>path`). Sets:
#   GATE_FL_STATE      ok | unclassifiable
#   GATE_FL_WHY        set when unclassifiable
#   GATE_FL_N_{DOC,TEST,PROMPT,CODE,POLICY}
#   GATE_FL_BLOCKERS   "CLASS<TAB>path" lines for POLICY/PROMPT/CODE files
#   GATE_FL_ALLFILES   "CLASS<TAB>path" lines for every file
#   GATE_FL_RUN        paths of added/modified test ENTRY files to run (one per line)
#   GATE_FL_UNRUNNABLE paths of executable tests with no runner (one per line)
# --no-renames on purpose: a rename shows as D+A, so a CODE file renamed to look like a doc still counts as the
# CODE file it deleted.
gate_fastlane_classify_raw() {
  local raw="$1" line meta path cls status oldmode newmode eff runner
  GATE_FL_STATE="ok"; GATE_FL_WHY=""
  GATE_FL_N_DOC=0; GATE_FL_N_TEST=0; GATE_FL_N_PROMPT=0; GATE_FL_N_CODE=0; GATE_FL_N_POLICY=0
  GATE_FL_BLOCKERS=""; GATE_FL_ALLFILES=""; GATE_FL_RUN=""; GATE_FL_UNRUNNABLE=""

  if [ -z "$raw" ]; then
    GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="the diff lists no files — nothing to classify"
    return 0
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      :*) ;;
      *) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="unparseable diff line (not a --raw record)"; return 0 ;;
    esac
    meta="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    if [ "$path" = "$line" ] || [ -z "$path" ]; then
      GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="diff record without a path"; return 0
    fi
    # git C-quotes a path with a tab/newline/quote/backslash; a path that cannot be read back reliably is not
    # one this lane can vouch for.
    case "$path" in
      \"*) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="a path needs quoting (control character, quote or backslash)"; return 0 ;;
    esac
    # shellcheck disable=SC2086
    set -- $meta
    oldmode="${1#:}"; newmode="${2:-}"; status="${5:-}"
    case "$status" in
      A|M|D) ;;
      *) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="change type '$status' on $path (type change / unmerged / unknown)"; return 0 ;;
    esac
    eff="$newmode"; [ "$status" = "D" ] && eff="$oldmode"
    case "$eff" in
      120000|160000) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="$path is a symlink or submodule — what it points at is not in this diff"; return 0 ;;
    esac

    cls=$(gate_fastlane_path_class "$path")
    # Self-protection, read from THIS diff's own file list (not from a variable the caller derived and may have
    # collapsed to "" on a git error): the gate's policy/classifier files and the fast lane's own files are never
    # fast-laned, even when they are "tests". The first two alternatives are the dispatcher's own POLICY_FILES
    # regex (the selftest pins them together); the last two are this lane's files.
    case "$path" in
      *review-merge-policy*|*quality-gate*|*gate-fastlane*|*gate-lane*) cls="POLICY" ;;
    esac
    GATE_FL_ALLFILES="${GATE_FL_ALLFILES}${cls}"$'\t'"${path}"$'\n'
    case "$cls" in
      DOC)    GATE_FL_N_DOC=$((GATE_FL_N_DOC + 1)) ;;
      TEST)   GATE_FL_N_TEST=$((GATE_FL_N_TEST + 1))
              if [ "$status" != "D" ]; then
                runner=$(gate_fastlane_test_runner "$path")
                case "$runner" in
                  bash|pytest) GATE_FL_RUN="${GATE_FL_RUN}${path}"$'\n' ;;
                  unknown)     GATE_FL_UNRUNNABLE="${GATE_FL_UNRUNNABLE}${path}"$'\n' ;;
                esac
              fi ;;
      POLICY) GATE_FL_N_POLICY=$((GATE_FL_N_POLICY + 1)); GATE_FL_BLOCKERS="${GATE_FL_BLOCKERS}POLICY"$'\t'"${path}"$'\n' ;;
      PROMPT) GATE_FL_N_PROMPT=$((GATE_FL_N_PROMPT + 1)); GATE_FL_BLOCKERS="${GATE_FL_BLOCKERS}${cls}"$'\t'"${path}"$'\n' ;;
      *)      GATE_FL_N_CODE=$((GATE_FL_N_CODE + 1));     GATE_FL_BLOCKERS="${GATE_FL_BLOCKERS}CODE"$'\t'"${path}"$'\n' ;;
    esac
  done <<EOF
$raw
EOF
  return 0
}

# ── helpers for the outputs ─────────────────────────────────────────────────────────────────────────────────

# _gate_fastlane_cap_lines <max> — stdin -> at most <max> lines, then "... (+N more)".
_gate_fastlane_cap_lines() {
  local max="$1" n=0 line out="" extra=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$n" -lt "$max" ]; then out="${out}${line}"$'\n'; n=$((n + 1)); else extra=$((extra + 1)); fi
  done
  [ "$extra" -gt 0 ] && out="${out}... (+${extra} more)"$'\n'
  printf '%s' "$out"
  return 0
}

# gate_fastlane_files_oneline — GATE_LANE_FILES as one metadata-safe line ("CLASS:path; CLASS:path; ..."), <= 480 chars.
gate_fastlane_files_oneline() {
  local s
  s=$(printf '%s' "${GATE_LANE_FILES:-}" | tr '\t' ':' | tr '\n' ';' | sed 's/;/; /g')
  if [ "${#s}" -gt 480 ]; then s="$(printf '%s' "$s" | cut -c1-470)…"; fi
  printf '%s' "$s"
  return 0
}

# _gate_fastlane_normal <code> <reason> [files] — the inert outcome. Always returns 0.
_gate_fastlane_normal() {
  GATE_LANE="normal"
  GATE_LANE_REASON_CODE="$1"
  GATE_LANE_REASON="$2"
  GATE_LANE_FILES="${3:-}"
  return 0
}

# ── the mechanical checks ───────────────────────────────────────────────────────────────────────────────────

# _gate_fastlane_digest_file <git_fn> <diff-file> — prints the fingerprint of a `git diff -U0` text, or returns 1.
# The text with the lines that legitimately change under a rebase taken out — hunk headers (line numbers shift when main
# edits above) and the blob ids on `index` lines (they follow main's version of the file). Everything else is IN, byte
# for byte: the file names, the modes (the mode stays on the `index` line: a regular file turned into a symlink with the
# same bytes differs only there), every added and removed line. So a pure rebase keeps the fingerprint, and a changed
# line — a whitespace change inside a test included, which `git patch-id` would call equal — does not.
_gate_fastlane_digest_file() {
  local git_fn="$1" f="$2" out
  out=$(sed -e '/^@@/d' -e 's/^index [0-9a-f]*\.\.[0-9a-f]*/index/' "$f" | "$git_fn" hash-object --stdin 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

# gate_fastlane_scan <git_fn> <base_ref> <head_ref> — runs the content scan over the ADDED lines. Sets
# GATE_FL_SCAN_RC (0 clean | 1 findings | other = could not scan), GATE_FL_SCAN_OUT (label/path/line, no values) and
# GATE_FL_DIFF_DIGEST (the fingerprint of the very diff text that was handed to the scanner; "" when it could not be read).
gate_fastlane_scan() {
  local git_fn="$1" base="$2" head="$3" tmp diff_rc=0 scan_rc=0
  GATE_FL_SCAN_RC=2; GATE_FL_SCAN_OUT=""; GATE_FL_DIFF_DIGEST=""
  if [ ! -r "${GATE_FASTLANE_DIR:-}/gate-fastlane-scan.py" ]; then
    GATE_FL_SCAN_OUT="scanner gate-fastlane-scan.py is missing or unreadable"
    return 0
  fi
  tmp=$(mktemp "${GATE_FS_TMPDIR:-/tmp}/gc-gate-fl-diff-XXXXXX" 2>/dev/null) || { GATE_FL_SCAN_OUT="could not create a temp file for the diff"; return 0; }
  "$git_fn" diff -U0 --no-color --no-ext-diff --no-renames "$base...$head" > "$tmp" 2>/dev/null || diff_rc=$?
  if [ "$diff_rc" != "0" ]; then
    GATE_FL_SCAN_OUT="git diff -U0 failed (rc=$diff_rc)"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  # gate_fastlane_decide gets here only after `diff --raw` listed files, and gate_fastlane_confirm only with a fast decision on record (which listed
  # files); a real `git diff -U0` prints a `diff --git` header for every listed file. No text at all means nothing was read — not that there was
  # nothing to flag — so it stays the inert "could not scan" (RC 2, no fingerprint). The scanner itself still answers empty input with clean: that is
  # its contract as a pure function; the lib knows a file list exists, the scanner does not.
  [ -s "$tmp" ] || { GATE_FL_SCAN_OUT="git diff -U0 returned no text for a range whose file list is not empty — nothing was read"; rm -f "$tmp" 2>/dev/null || true; return 0; }
  GATE_FL_DIFF_DIGEST=$(_gate_fastlane_digest_file "$git_fn" "$tmp") || GATE_FL_DIFF_DIGEST=""
  GATE_FL_SCAN_OUT=$(python3 "$GATE_FASTLANE_DIR/gate-fastlane-scan.py" --max-bytes "${GATE_FASTLANE_SCAN_MAX_BYTES:-2097152}" < "$tmp" 2>&1) || scan_rc=$?
  GATE_FL_SCAN_RC="$scan_rc"
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# _gate_fastlane_test_path — PATH for the tests: the caller's PATH minus every entry under $HOME. The tests need
# git/jq/python3/bash (system + Homebrew). This drops the tools installed under $HOME — on this host `secret` and
# `notify` (~/.local/bin) — so a test no reviewer has read does not find them by name. It is NOT what keeps
# credentials away, and it does NOT cut the test off from the city: bd, gc, dolt, gh, aws, gcloud and bw live in
# /opt/homebrew/bin and stay on this PATH (measured under the exact env the lane builds: `bd -C <city> list` returns
# the live city's beads, `gc --city <city>` runs). The credential shield is the throwaway HOME that
# gate_fastlane_run_tests sets: `bw` finds no vault there and `gh` is logged out. A test that needs a dropped tool
# fails, and a failing test sends the diff to the normal gate — the inert outcome.
_gate_fastlane_test_path() {
  local out="" entry IFS=:
  for entry in $PATH; do
    [ -z "$entry" ] && continue
    case "$entry" in "${HOME:-/nonexistent-home}"|"${HOME:-/nonexistent-home}"/*) continue ;; esac
    out="${out:+$out:}$entry"
  done
  printf '%s' "${out:-/usr/bin:/bin}"
  return 0
}

# gate_fastlane_run_tests <git_fn> <head_sha> <paths_nl> — runs each new/changed test entry in a throwaway
# detached worktree, env scrubbed (HOME inside the worktree, no inherited credentials, no user bin dirs on
# PATH), each under `timeout`, the whole under one budget: this runs while the dispatcher holds the citywide
# gate lock. NOT a sandbox: the control plane (bd, gc, dolt) is reachable from PATH, and nothing stops a test from
# using the network or writing outside the worktree. NOT the same as the full-suite check either:
# .gate-full-suite.sh also runs branch code, but only after reviewers have read it, whereas here nobody has. What
# bounds the exposure is that the branch author already runs this same code, as the same user, in its own session —
# the gate's threat model is a worker's mistake, not a hostile worker — plus the throwaway HOME (the credential
# shield; see _gate_fastlane_test_path for what PATH does and does not do), the timeouts and the budget. A
# stricter boundary (sandbox-exec denying network and writes outside the worktree, or a PATH allowlist without
# bd/gc/dolt/bw/gh/aws/gcloud) is a possible hardening, not present here. Sets GATE_FL_TEST_RC (0 all green | 1 a
# test failed | 2 could not run) and GATE_FL_TEST_OUT.
gate_fastlane_run_tests() {
  local git_fn="$1" sha="$2" paths="$3" tmp wt log f runner rc t0 now spent n=0 max budget per_file ok_n=0 tpath
  GATE_FL_TEST_RC=2; GATE_FL_TEST_OUT=""
  max="${GATE_FASTLANE_TEST_MAX_FILES:-6}"; budget="${GATE_FASTLANE_TEST_BUDGET_SECS:-150}"; per_file="${GATE_FASTLANE_TEST_TIMEOUT_SECS:-60}"
  case "$max" in ''|*[!0-9]*) max=6 ;; esac
  case "$budget" in ''|*[!0-9]*) budget=150 ;; esac
  case "$per_file" in ''|*[!0-9]*) per_file=60 ;; esac

  # `[ -z ]` has no failure mode. The count was `grep -c . || n=0`, which turned a grep that FAILED into "no test entry
  # to run" -> rc 0 -> the lane granted without running the changed tests (an error read as empty). The count below is a
  # shell loop over the same list, with no command that can fail.
  if [ -z "$paths" ]; then GATE_FL_TEST_RC=0; GATE_FL_TEST_OUT="no test entry to run"; return 0; fi
  n=0
  while IFS= read -r f; do
    if [ -n "$f" ]; then n=$((n + 1)); fi
  done <<EOF
$paths
EOF
  if [ "$n" -gt "$max" ]; then
    GATE_FL_TEST_OUT="$n test files to run exceeds the fast-lane cap of $max"
    return 0
  fi
  if [ "${GATE_FASTLANE_RUN_TESTS:-1}" != "1" ]; then
    GATE_FL_TEST_OUT="running tests is disabled (GATE_FASTLANE_RUN_TESTS=0) but $n test file(s) changed"
    return 0
  fi
  # an earlier interrupted sweep may have leaked a worktree of this family (the reaper also matches gc-gate-fs-fastlane-*)
  if declare -F gate_full_suite_reap_stale >/dev/null 2>&1; then gate_full_suite_reap_stale || true; fi

  tmp="${GATE_FS_TMPDIR:-/tmp}"
  wt="$tmp/gc-gate-fs-fastlane-$$"
  log=$(mktemp "$tmp/gc-gate-fs-fastlane-log-XXXXXX" 2>/dev/null) || { GATE_FL_TEST_OUT="could not create a temp log"; return 0; }
  if ! "$git_fn" worktree add --detach "$wt" "$sha" >/dev/null 2>&1; then
    GATE_FL_TEST_OUT="could not create a worktree for $sha"
    rm -f "$log" 2>/dev/null || true
    return 0
  fi

  tpath=$(_gate_fastlane_test_path)
  t0=$(date +%s)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    now=$(date +%s); spent=$((now - t0))
    if [ "$spent" -ge "$budget" ]; then
      GATE_FL_TEST_OUT="test budget of ${budget}s exhausted after $ok_n of $n test file(s)"
      GATE_FL_TEST_RC=2
      "$git_fn" worktree remove --force "$wt" >/dev/null 2>&1 || true
      rm -f "$log" 2>/dev/null || true
      return 0
    fi
    runner=$(gate_fastlane_test_runner "$f")
    rc=0
    # </dev/null: this loop reads its own file list from a heredoc, and a test that reads stdin would eat it.
    case "$runner" in
      bash)
        ( cd "$wt" && env -i HOME="$wt" PATH="$tpath" LC_ALL=C TMPDIR="$wt" timeout "$per_file" bash "$f" ) </dev/null >"$log" 2>&1 || rc=$? ;;
      pytest)
        ( cd "$wt" && env -i HOME="$wt" PATH="$tpath" LC_ALL=C TMPDIR="$wt" timeout "$per_file" python3 -m pytest -q -x -p no:cacheprovider "$f" ) </dev/null >"$log" 2>&1 || rc=$? ;;
      *) rc=99 ;;
    esac
    if [ "$rc" != "0" ]; then
      # rc 124 = timeout; 1 = a real failure OR a missing dependency in the scrubbed env. The fast lane cannot
      # tell which, and it does not need to: either way the diff goes to the normal gate, never to a FAIL.
      GATE_FL_TEST_RC=1
      GATE_FL_TEST_OUT="test $f exited rc=$rc (124 = timed out after ${per_file}s) — tail: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ' | cut -c1-240)"
      "$git_fn" worktree remove --force "$wt" >/dev/null 2>&1 || true
      rm -f "$log" 2>/dev/null || true
      return 0
    fi
    ok_n=$((ok_n + 1))
  done <<EOF
$paths
EOF
  GATE_FL_TEST_RC=0
  GATE_FL_TEST_OUT="$ok_n test file(s) ran green"
  "$git_fn" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -f "$log" 2>/dev/null || true
  return 0
}

# ── the decision ────────────────────────────────────────────────────────────────────────────────────────────

# gate_fastlane_decide <git_fn> <base_ref> <head_sha> <policy_files>
#   git_fn        the dispatcher's git runner (git_rig — knows container rigs)
#   base_ref      e.g. origin/main            head_sha  the commit the RUN CLAIMED. Not assumed to be what lands: the merge
#                 pushes whatever the branch is at push time, so gate_fastlane_confirm asks again about that commit.
#                 Both refs are resolved to a commit ONCE, here, and every later git call (the raw list, the scan, the
#                 test worktree) uses those shas — a symbolic origin/main could move between two of them.
#   policy_files  non-empty when the diff touches the gate's own policy/classifier (the dispatcher computes it
#                 once for its own self-protection; the fast lane honors the SAME answer)
gate_fastlane_decide() {
  local git_fn="$1" base="$2" head="$3" policy="${4:-}" raw raw_rc=0 blockers uncls base_sha head_sha
  GATE_LANE="normal"; GATE_LANE_REASON="not evaluated"; GATE_LANE_REASON_CODE="not-evaluated"; GATE_LANE_FILES=""; GATE_LANE_COUNTS=""
  GATE_LANE_DIGEST=""

  if _gate_fastlane_is_off; then
    # (two literal calls, not one with a variable: the tally selftest finds the codes a producer emits by grepping for them)
    case "$GATE_FL_OFF_CODE" in
      flag-file) _gate_fastlane_normal "flag-file" "$GATE_FL_OFF_WHY" ;;
      *)         _gate_fastlane_normal "disabled" "$GATE_FL_OFF_WHY" ;;
    esac
    return 0
  fi
  if [ -z "$git_fn" ] || [ -z "$base" ] || [ -z "$head" ]; then
    _gate_fastlane_normal "no-input" "fast lane could not decide: missing git runner / base / head"; return 0
  fi
  if [ -n "$policy" ]; then
    _gate_fastlane_normal "policy" "the diff touches the gate's own policy/classifier — self-protection keeps it in the normal gate" "$(printf '%s\n' "$policy" | sed 's/^/POLICY\t/')"
    return 0
  fi

  base_sha=$("$git_fn" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null) || base_sha=""
  head_sha=$("$git_fn" rev-parse --verify --quiet "${head}^{commit}" 2>/dev/null) || head_sha=""
  if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
    _gate_fastlane_normal "diff-raw-failed" "git rev-parse failed to resolve the base or head to a commit — cannot classify, normal gate"; return 0
  fi

  raw=$("$git_fn" -c core.quotepath=off diff --raw --no-renames "$base_sha...$head_sha" 2>/dev/null) || raw_rc=$?
  if [ "$raw_rc" != "0" ]; then
    _gate_fastlane_normal "diff-raw-failed" "git diff --raw failed (rc=$raw_rc) — cannot classify, normal gate"; return 0
  fi

  gate_fastlane_classify_raw "$raw"
  GATE_LANE_COUNTS="doc=${GATE_FL_N_DOC} test=${GATE_FL_N_TEST} prompt=${GATE_FL_N_PROMPT} code=${GATE_FL_N_CODE} policy=${GATE_FL_N_POLICY}"
  if [ "$GATE_FL_STATE" != "ok" ]; then
    _gate_fastlane_normal "unclassifiable" "unclassifiable diff: ${GATE_FL_WHY}"; return 0
  fi
  blockers=$(printf '%s' "$GATE_FL_BLOCKERS" | _gate_fastlane_cap_lines "${GATE_FASTLANE_LIST_MAX:-30}")
  if [ -n "$GATE_FL_BLOCKERS" ]; then
    _gate_fastlane_normal "code-or-prompt" "$((GATE_FL_N_CODE + GATE_FL_N_PROMPT + GATE_FL_N_POLICY)) file(s) are production code, prompt/doctrine or the gate's own policy (code=${GATE_FL_N_CODE} prompt=${GATE_FL_N_PROMPT} policy=${GATE_FL_N_POLICY}) — normal gate" "$blockers"
    return 0
  fi
  uncls=$(printf '%s' "$GATE_FL_UNRUNNABLE" | _gate_fastlane_cap_lines 10)
  if [ -n "$GATE_FL_UNRUNNABLE" ]; then
    _gate_fastlane_normal "test-unrunnable" "changed test(s) in a language the fast lane cannot run — normal gate" "$(printf '%s' "$uncls" | sed 's/^/TEST-UNRUNNABLE\t/')"
    return 0
  fi

  gate_fastlane_scan "$git_fn" "$base_sha" "$head_sha"
  case "$GATE_FL_SCAN_RC" in
    0) # clean — but a lane that cannot LATER prove the diff is unchanged (gate_fastlane_confirm) must not be granted
       if [ -z "$GATE_FL_DIFF_DIGEST" ]; then
         _gate_fastlane_normal "scan-failed" "content scan ran but the diff it read could not be fingerprinted — unverified is not clean, normal gate"
         return 0
       fi ;;
    1) _gate_fastlane_normal "scan-findings" "content scan found personal data / a credential on added lines ($(printf '%s' "$GATE_FL_SCAN_OUT" | cut -f1 | sort | uniq -c | awk '{printf "%s%s×%s", (NR>1?", ":""), $2, $1}')) — normal gate" "$(printf '%s\n' "$GATE_FL_SCAN_OUT" | head -10 | awk -F'\t' '{printf "SCAN\t%s %s:%s\n", $1, $2, $3}')"
       return 0 ;;
    *) _gate_fastlane_normal "scan-failed" "content scan could not run (rc=${GATE_FL_SCAN_RC}: $(printf '%s' "$GATE_FL_SCAN_OUT" | head -1 | cut -c1-160)) — unverified is not clean, normal gate"
       return 0 ;;
  esac

  gate_fastlane_run_tests "$git_fn" "$head_sha" "$GATE_FL_RUN"
  if [ "$GATE_FL_TEST_RC" != "0" ]; then
    _gate_fastlane_normal "test-failed" "fast-lane test check did not pass: ${GATE_FL_TEST_OUT} — normal gate decides" "$(printf '%s' "$GATE_FL_RUN" | _gate_fastlane_cap_lines 10 | sed 's/^/TEST\t/')"
    return 0
  fi

  # The only success path. Everything above returned.
  GATE_LANE_FILES=$(printf '%s' "$GATE_FL_ALLFILES" | _gate_fastlane_cap_lines "${GATE_FASTLANE_LIST_MAX:-30}")
  GATE_LANE_REASON="every file is DOC or TEST (${GATE_LANE_COUNTS}); content scan clean; ${GATE_FL_TEST_OUT} — merged without an LLM reviewer"
  GATE_LANE_REASON_CODE="fast"
  GATE_LANE_DIGEST="$GATE_FL_DIFF_DIGEST"
  GATE_LANE="fast"
  return 0
}

# ── the push-time confirmation ──────────────────────────────────────────────────────────────────────────────────

# _gate_fastlane_is_off — 0 (with GATE_FL_OFF_CODE / GATE_FL_OFF_WHY set) when an operator has switched the lane off, 1
# when it is on. An operator can stop the lane instantly with `touch <city>/.gc/gate-fastlane.off` (and re-enable it by
# removing the file): the dispatcher is a fresh process every sweep, so a flag file needs no launchd reload, unlike an env
# var. Asked at the decision AND again at the push, so that "off" also stops a run that was granted a minute ago.
_gate_fastlane_is_off() {
  GATE_FL_OFF_CODE=""; GATE_FL_OFF_WHY=""
  if [ "${GATE_FASTLANE_ENABLED:-1}" != "1" ]; then
    GATE_FL_OFF_CODE="disabled"; GATE_FL_OFF_WHY="fast lane disabled (GATE_FASTLANE_ENABLED=0)"; return 0
  fi
  if [ -e "${GATE_FASTLANE_OFF_FILE:-${GC_CITY:-/nonexistent-city}/.gc/gate-fastlane.off}" ]; then
    GATE_FL_OFF_CODE="flag-file"; GATE_FL_OFF_WHY="fast lane switched off by the flag file (.gc/gate-fastlane.off) — normal gate"; return 0
  fi
  return 1
}

# _gate_fastlane_revoke <code> <why> — the inert outcome of a failed confirmation: the lane is "normal" afterwards and no
# fingerprint is left behind for a later call to trust. Always returns 0 (the caller returns 1).
_gate_fastlane_revoke() {
  GATE_LANE="normal"; GATE_LANE_DIGEST=""
  GATE_LANE_CONFIRM_CODE="$1"
  GATE_LANE_CONFIRM_WHY="$2"
  return 0
}

# gate_fastlane_confirm <git_fn> <base_sha> <head_sha> — asked IMMEDIATELY before the push, with the very commit that is
# about to be pushed and the main it fast-forwards from. Returns 0 only for a clean yes: the lane is still on, and the
# diff that would land is, byte for byte (see _gate_fastlane_digest_file), the diff the decision scanned and ran the tests
# on — or the same change rebased/merged onto a newer main. Everything else returns 1 with GATE_LANE=normal: the tip moved,
# the content changed, the operator switched the lane off, or it could not be read (three states: yes / no / could not
# tell, and the last two are the inert one). The caller does NOT turn a no into a FAIL — it re-queues the marker so the
# normal gate decides; the lane only ever grants.
# Not repeated here: the tests. They ran on the decided diff, and a digest that matches means the changed test files are the
# same bytes (the full-suite check still runs after a rebase).
gate_fastlane_confirm() {
  local git_fn="$1" base="$2" head="$3" decided raw raw_rc=0
  GATE_LANE_CONFIRM_CODE=""; GATE_LANE_CONFIRM_WHY=""
  decided="${GATE_LANE_DIGEST:-}"
  if [ "${GATE_LANE:-normal}" != "fast" ] || [ -z "$decided" ]; then
    _gate_fastlane_revoke "cannot-confirm" "no fast-lane decision with a diff fingerprint is on record in this run"; return 1
  fi
  if [ -z "$git_fn" ] || [ -z "$base" ] || [ -z "$head" ]; then
    _gate_fastlane_revoke "cannot-confirm" "missing git runner / base / head for the push-time confirmation"; return 1
  fi
  if _gate_fastlane_is_off; then
    _gate_fastlane_revoke "switched-off" "the fast lane was switched off after it was granted: ${GATE_FL_OFF_WHY}"; return 1
  fi

  gate_fastlane_scan "$git_fn" "$base" "$head"
  if [ -z "$GATE_FL_DIFF_DIGEST" ]; then
    _gate_fastlane_revoke "cannot-confirm" "the diff that would land could not be read (${GATE_FL_SCAN_OUT:-no detail})"; return 1
  fi
  if [ "$GATE_FL_DIFF_DIGEST" != "$decided" ]; then
    _gate_fastlane_revoke "diff-changed" "the diff that would land is not the diff the lane checked (the branch tip moved, or its content changed, after the decision) — no scan or test ever ran on it"; return 1
  fi

  # The same bytes mean the same files, added lines and tests. These two do not lean on that inference: they ask the
  # commit that lands, again, directly.
  raw=$("$git_fn" -c core.quotepath=off diff --raw --no-renames "$base...$head" 2>/dev/null) || raw_rc=$?
  if [ "$raw_rc" != "0" ]; then
    _gate_fastlane_revoke "cannot-confirm" "git diff --raw of the commit that would land failed (rc=$raw_rc)"; return 1
  fi
  gate_fastlane_classify_raw "$raw"
  if [ "$GATE_FL_STATE" != "ok" ] || [ -n "$GATE_FL_BLOCKERS" ] || [ -n "$GATE_FL_UNRUNNABLE" ]; then
    _gate_fastlane_revoke "no-longer-fast" "the commit that would land is not classifiable as DOC/TEST-only any more"; return 1
  fi
  if [ "$GATE_FL_SCAN_RC" != "0" ]; then
    _gate_fastlane_revoke "no-longer-fast" "the content scan of the commit that would land is not clean (rc=${GATE_FL_SCAN_RC})"; return 1
  fi
  return 0
}

# ── recording (marker + jsonl) ──────────────────────────────────────────────────────────────────────────────

# gate_fastlane_record <city> <marker_id> <bead> <branch> <rig> <would_have_reviewers> <qg_log>
# Writes the lane and the files that decided it on the MARKER (metadata gate.lane / gate.lane_reason /
# gate.lane_files) and appends a `gate_lane` event (with reason_code, and dry_run so the tally can leave a DRY_RUN=1
# sweep out of its counts) to the jsonl the weekly tally reads. Observability only: a
# failed write is logged and never changes the lane. The marker write is READ BACK, because "the command ran" is
# not "the field is there".
gate_fastlane_record() {
  local city="$1" marker="$2" bead="$3" branch="$4" rig="$5" would="$6" qg_log="$7" back=""
  case "$would" in ''|*[!0-9]*) would=0 ;; esac
  if [ -n "$marker" ]; then
    bd -C "$city" update "$marker" --set-metadata "gate.lane=${GATE_LANE}" -q >/dev/null 2>&1 || true
    bd -C "$city" update "$marker" --set-metadata "gate.lane_reason=$(printf '%s' "$GATE_LANE_REASON" | cut -c1-300)" -q >/dev/null 2>&1 || true
    bd -C "$city" update "$marker" --set-metadata "gate.lane_files=$(gate_fastlane_files_oneline)" -q >/dev/null 2>&1 || true
    back=$(bd -C "$city" show "$marker" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .metadata["gate.lane"] // ""' 2>/dev/null) || back=""
    if [ "$back" != "$GATE_LANE" ]; then
      echo "[gate-fastlane] WARN: lane '${GATE_LANE}' NOT confirmed on marker $marker after write (read back: '${back:-unreadable}') — the jsonl event below is still written" >&2
    fi
  fi
  if [ -n "$qg_log" ]; then
    mkdir -p "$(dirname "$qg_log")" 2>/dev/null || true
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg branch "$branch" --arg bead "$bead" --arg rig "${rig:-unknown}" --arg marker "$marker" \
      --arg lane "$GATE_LANE" --arg reason "$GATE_LANE_REASON" --arg code "${GATE_LANE_REASON_CODE:-}" \
      --arg counts "$GATE_LANE_COUNTS" --arg dry_run "${DRY_RUN:-0}" \
      --arg files "$(gate_fastlane_files_oneline)" --argjson would "$would" \
      '{ts: $ts, event: "gate_lane", lane: $lane, branch: $branch, bead: $bead, rig: $rig, marker: $marker,
        counts: $counts, reason: $reason, reason_code: $code, files: $files, would_have_reviewers: $would,
        dry_run: $dry_run}' \
      >> "$qg_log" 2>/dev/null \
      || echo "[gate-fastlane] WARN: could not append the gate_lane event to $qg_log — the weekly tally will under-count this decision" >&2
  fi
  return 0
}
