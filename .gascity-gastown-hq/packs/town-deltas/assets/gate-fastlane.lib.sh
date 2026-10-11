#!/usr/bin/env bash
# gate-fastlane.lib.sh — ga-atsahv: the quality gate's DOC/TEST fast lane (no LLM reviewer).
# SLICE NOTE (ga-atsahv.1 of 3 — removed by ga-atsahv.3): the gate's 800-line production cap (E11) made this lane arrive in three slices. This
# one holds ONLY the classification (gate_fastlane_path_class / _test_runner / _classify_raw); the scan, the tests, the history check, the
# decision and the push-time confirmation arrive with ga-atsahv.2, and the dispatcher wiring, the record and the weekly tally with
# ga-atsahv.3. Nothing sources this file before .3, so merging this slice changes no behaviour. The text below describes the finished lane.
#
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
# WHAT THE MERGE PUBLISHES, NOT WHAT THE TIP LOOKS LIKE (gate round ga-aa8n6z; Mayor re-scope 11/10). The merge is a fast-forward: it puts EVERY
# commit of base..head into main, so the file classes and the content scan are asked about each of those commits too — their files
# (gate_fastlane_history), the lines each added and each commit MESSAGE (the history pass of gate_fastlane_scan) — and not only about the net
# diff of the tip, in which a value pasted in one commit and removed in the next, or a production file added and deleted again, leaves no
# trace and sits in main's history for good. The net pass stays as well (a number split over lines that two different commits added is one
# number only there). More commits than GATE_FASTLANE_COMMIT_MAX (30), or a merge commit with changes of its own, go to the normal gate.
#
# THE ONE RULE. The fast lane is only ever GRANTED, never a verdict. Every path that is not a clean yes —
# a code file, a prompt file, a finding, a failing test, an unreadable diff, a git error, a missing scanner, a
# symlink, a quoted path, an empty list, the kill-switch — ends in the NORMAL gate, which is today's behavior.
# "Could not tell" and "no" must never produce different outcomes here: three states (yes / no / could not
# tell), and the last one is the inert one. GATE_LANE is reset to "normal" on entry and becomes "fast" on the
# very last line of the only success path, so an early return can never leave a stale "fast" behind.
#
# The same rule at every READ (gate round 6 swept the whole lib for it, after a reviewer found one `case` over a lookup that had
# no default arm, so an EMPTY answer fell through exactly like the real answer "none"): a lookup whose answer is anything the
# code did not name — empty, garbage, a failed command substitution — lands in the inert arm (unclassifiable / unrunnable /
# scan-failed / normal), and that arm SAYS it was "could not tell" in its reason, so the log and the tally can tell a blind lane
# from a lane that looked and said no. Every `$(...)` that feeds a decision is `|| var=""`-guarded for the same reason it is
# errexit-guarded below. The list of the points reviewed is in the bead comment of the round that did the sweep.
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
#   GATE_LANE_DIGEST  set ONLY with GATE_LANE=fast: the fingerprint of the exact diff AND history that were scanned (tests ran on the tip)
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
  # `|| lc=""`: a lowercase that failed leaves nothing for any pattern below to match, and "matched nothing" ends in CODE — the
  # inert class — so a failed read cannot be a DOC or a TEST
  lc=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]') || lc=""
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
#   none     a DATA file under tests/ — a fixture whose extension is on the positive list below: inert, nothing to run
#   unknown  everything else: an executable test in a language with no runner here (js/ts/go/lua/...), a helper script or module
#            (setup.sh, conftest.py), a file with no extension — cannot be run, so it goes to the normal gate
# `none` is the ONLY answer that lets a changed test pass without running, so it is a POSITIVE list, like the DOC class: the first
# version listed the executable languages it knew (js ts go ...) and answered `none` for the rest, so "nobody listed it" read as
# "known harmless" — a tests/test_widget.lua or a tests/helpers/setup.sh was granted unrun. A lowercase that failed (lc empty)
# answers `unknown` too: "could not tell" is never `none`.
gate_fastlane_test_runner() {
  local lc base ext
  lc=$(printf '%s' "${1#./}" | tr '[:upper:]' '[:lower:]') || lc=""
  [ -n "$lc" ] || { echo unknown; return 0; }
  base="${lc##*/}"
  ext=""
  case "$base" in *.*) ext="${base##*.}" ;; esac
  case "$base" in
    *.selftest.sh|*.test.sh|test_*.sh|*_test.sh) echo bash; return 0 ;;
    test_*.py|*_test.py|*.selftest.py) echo pytest; return 0 ;;
  esac
  case "$ext" in
    json|yaml|yml|toml|txt|md|csv|tsv|xml|html|ini|cfg|snap|golden|expected|diff|patch|sql|svg|png|jpg|jpeg|gif) echo none; return 0 ;;
  esac
  echo unknown
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
    # Only a REGULAR file is classified. The case used to name the two bad modes (symlink, submodule) and let everything else
    # through, so an empty or unknown mode field passed as "a regular file" — the same collapse as everywhere else in this lane.
    case "$eff" in
      100644|100755) ;;
      120000|160000) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="$path is a symlink or submodule — what it points at is not in this diff"; return 0 ;;
      *) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="$path has a file mode this lane does not know ('${eff:0:12}') — only regular files are classified"; return 0 ;;
    esac

    # A classifier that answered anything but one of the four classes (nothing at all, when its command substitution failed) is
    # "could not tell", and says so — it is not quietly counted as CODE, which would give the same normal-gate outcome with the
    # blind lane and the looking lane indistinguishable in the log.
    cls=$(gate_fastlane_path_class "$path") || cls=""
    case "$cls" in
      DOC|TEST|PROMPT|CODE) ;;
      *) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="could not classify $path (the classifier answered '${cls:0:40}')"; return 0 ;;
    esac
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
                # The gate's round-6 blocker: this `case` had arms for bash|pytest and unknown ONLY. An EMPTY answer (the lookup's
                # command substitution failing) matched none of them, so the changed test landed neither in RUN nor in UNRUNNABLE,
                # and run_tests answered "no test entry to run" -> the lane was granted on a test nobody ran. `none` is now an
                # arm of its own — the lookup SAYING "an inert fixture" — and everything else is "could not tell", the inert state.
                runner=$(gate_fastlane_test_runner "$path") || runner=""
                case "$runner" in
                  bash|pytest) GATE_FL_RUN="${GATE_FL_RUN}${path}"$'\n' ;;
                  unknown)     GATE_FL_UNRUNNABLE="${GATE_FL_UNRUNNABLE}${path}"$'\n' ;;
                  none)        ;;
                  *) GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="could not tell how to run the changed test $path (the runner lookup answered '${runner:0:40}')"; return 0 ;;
                esac
              fi ;;
      POLICY) GATE_FL_N_POLICY=$((GATE_FL_N_POLICY + 1)); GATE_FL_BLOCKERS="${GATE_FL_BLOCKERS}POLICY"$'\t'"${path}"$'\n' ;;
      PROMPT) GATE_FL_N_PROMPT=$((GATE_FL_N_PROMPT + 1)); GATE_FL_BLOCKERS="${GATE_FL_BLOCKERS}${cls}"$'\t'"${path}"$'\n' ;;
      *)      GATE_FL_N_CODE=$((GATE_FL_N_CODE + 1));     GATE_FL_BLOCKERS="${GATE_FL_BLOCKERS}CODE"$'\t'"${path}"$'\n' ;;
    esac
  done <<EOF
$raw
EOF
  # "every file is a DOC or a TEST" is vacuously true of ZERO files. A non-empty list whose records were all skipped would reach
  # here with nothing classified, and the decision would read the empty BLOCKERS/UNRUNNABLE as "nothing stands in the way".
  if [ "$GATE_FL_STATE" = "ok" ] && [ -z "$GATE_FL_ALLFILES" ]; then
    GATE_FL_STATE="unclassifiable"; GATE_FL_WHY="the diff list was not empty but no record in it was classified — nothing was read"
  fi
  return 0
}
