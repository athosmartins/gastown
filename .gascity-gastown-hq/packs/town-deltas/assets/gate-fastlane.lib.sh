#!/usr/bin/env bash
# gate-fastlane.lib.sh — ga-atsahv: the quality gate's DOC/TEST fast lane (no LLM reviewer).
# SLICE NOTE (ga-atsahv.2 of 3 — removed by ga-atsahv.3): the gate's 800-line production cap (E11) made this lane arrive in three slices. Slices 1
# and 2 together hold everything through the push-time confirmation (classification, scan, tests, history check, decision, confirm); the dispatcher
# wiring, gate_fastlane_record and the weekly tally arrive with ga-atsahv.3. Nothing sources this file before .3, so merging this slice changes no
# behaviour. The text below describes the finished lane.
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
# (gate_fastlane_history), the lines each added and each commit MESSAGE (the history pass of gate_fastlane_scan), and the message of each MERGE
# commit (its merges pass; gate round ga-5l2ki8: a merge has no diff of its own, so it was the one commit whose words nobody read) — and not only
# about the net diff of the tip, in which a value pasted in one commit and removed in the next, or a production file added and deleted again,
# leaves no trace and sits in main's history for good. The net pass stays as well (a number split over lines that two different commits added is
# one number only there). More commits than GATE_FASTLANE_COMMIT_MAX (30), or a merge commit with changes of its own, go to the normal gate.
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
  s=$(printf '%s' "${GATE_LANE_FILES:-}" | tr '\t' ':' | tr '\n' ';' | sed 's/;/; /g') || s=""
  # a rendering that failed must not read as "no file decided this lane": the line is non-empty exactly when the list is
  if [ -z "$s" ] && [ -n "${GATE_LANE_FILES:-}" ]; then s="(the list of files that decided could not be rendered)"; fi
  if [ "${#s}" -gt 480 ]; then s="$(printf '%s' "$s" | cut -c1-470)…" || s="${s:0:470}…"; fi
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

# _gate_fastlane_digest_file <git_fn> <diff-file> — prints the fingerprint of a `git diff -U0` / `git log -p -U0` text, or returns 1.
# The text with the lines that legitimately change under a rebase taken out — hunk headers (line numbers shift when main
# edits above), the blob ids on `index` lines (they follow main's version of the file) and, in a `git log -p` stream, the
# `commit <sha>` / `Author:` / `Date:` lines (a rebase rewrites the sha; the other two are not content and are not scanned).
# Everything else is IN, byte for byte: the file names, the modes (the mode stays on the `index` line: a regular file turned
# into a symlink with the same bytes differs only there), every added and removed line, every commit message. So a pure rebase
# keeps the fingerprint, and a changed line — a whitespace change inside a test included, which `git patch-id` would call equal
# — does not. (None of the three extra patterns can match a line of a plain diff: content lines start with + - or a space, the
# rest with `diff `, `index `, `---`, `+++`, `@@`, a mode word or a backslash; a message line starts with four spaces.)
_gate_fastlane_digest_file() {
  local git_fn="$1" f="$2" out
  # pipefail INSIDE the substitution, not inherited from the caller: a `sed` that failed would otherwise hand `hash-object` an
  # empty stream, and the pipeline's status is the LAST command's — so "could not read the diff" would come back as a perfectly
  # valid digest (of nothing), and a later confirm could "match" it. Whoever sources this lib, the digest is either of the text
  # or absent.
  out=$(set -o pipefail; sed -e '/^@@/d' -e '/^commit [0-9a-f]\{40\}/d' -e '/^Author: /d' -e '/^Date:   /d' -e 's/^index [0-9a-f]*\.\.[0-9a-f]*/index/' "$f" | "$git_fn" hash-object --stdin 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

# _gate_fastlane_is_finding_list <text> — 0 iff <text> is a scanner's list of findings: at least one line, EVERY line of the
# shape `label<TAB>path<TAB>line-number`. Anything else — empty, a traceback, a stray message — is not a list of findings. Reads
# nothing that can fail (awk over a here-string), so a doubt is "no".
_gate_fastlane_is_finding_list() {
  printf '%s\n' "$1" | awk -F'\t' '
    { n++; if (NF != 3 || $1 !~ /^[a-z][a-z0-9-]*$/ || $3 !~ /^[0-9]+$/) bad = 1 }
    END { exit ((n > 0 && !bad) ? 0 : 1) }'
}

# _gate_fastlane_scan_range <git_fn> <net|history|merges> <range> — ONE pass of the content scan: runs git for the range, hands the text to the
# scanner, believes the answer only in the shape its exit code promises. Sets GATE_FL_R_RC (0 clean | 1 findings | other = could not
# scan), GATE_FL_R_OUT (label/path/line lines, no values — or the reason it could not scan) and GATE_FL_R_DIGEST (the fingerprint of
# the very text handed to the scanner; "" when it could not be read, and always "" for `merges`: see below).
#   net      `git diff -U0 base...head` — what the TIP adds (the diff the classifier and the tests also read)
#   history  `git log -p -U0 --no-merges base..head` — what EACH COMMIT adds, messages included: this is what the fast-forward PUBLISHES
#            (gate round ga-aa8n6z: a value pasted in one commit and removed in the next was invisible to the net pass, and sat in
#            main's history all the same). The format is pinned (--pretty=medium, no decoration/notes/signature/abbrev, UTF-8, no color/textconv/
#            external diff/renames) so that the usual git config knobs cannot change what the scanner is handed. A knob this list does
#            not name is expected to change only how something is SPELLED (a path prefix, a date format) or to give a shape the
#            scanner refuses (rc 2, the normal gate); a git that cannot take one of these flags fails (rc 2 as well). Not proven for every
#            knob git has — the selftest pins the shapes it refuses (§4h'').
#   merges   `git log --merges --no-abbrev base..head` — what each MERGE commit SAYS (gate round ga-5l2ki8: the history pass lists --no-merges, and
#            a clean merge — the gate's own "Merge origin/main into <branch>" fallback — has an empty `git show --cc`, so nothing asked for its
#            message, which the fast-forward publishes like any other). Same pinned format as `history`, plus --no-abbrev: the `Merge: <parent> <parent>`
#            line is abbreviated (to core.abbrev, 7 by default) even under --no-abbrev-commit, which only reaches the `commit` line, and the scanner
#            reads that line only in its full-sha shape (an abbreviated one is rc 2, the normal gate — the selftest runs the lib without the flag to
#            show it). No diff is asked for: git prints none for a merge under `log -p` unless told -m/-c/--cc (checked on 2.54 and on Apple's
#            2.50, `log.diffMerges` set or not — that key only picks the format of an explicit -m); a git that did would hand the scanner a shape it
#            refuses (rc 2), never a wrong "clean". A merge that carries content of its own is not
#            read here at all: gate_fastlane_history sends it to the normal gate. Whether the range HAS a merge is asked of git (`rev-list
#            --merges --count`), not inferred from the log coming back empty: no merge is a clean "nothing to read" (rc 0), a count git could
#            not give is "could not scan", and a log that is empty for a range git counted merges in is "nothing was read". Its text is NOT part
#            of the fingerprint: the fingerprint says "the same change", and a branch that merged main in after the decision (the ga-qukyp
#            fallback) is the same change; the push-time scan reads the merge messages again instead.
# `-c core.quotepath=off` on both, like the two `--raw` reads: the classifier and the scanner must spell a file name the same way
# (gate round ga-aa8n6z, blocking issue 2: with the default, `migração.md` reached the scanner as `migra\303\247\303\243o.md`, whose
# escapes read as twelve digits — a 'numero-longo' finding that is not in the name).
_gate_fastlane_scan_range() {
  local git_fn="$1" kind="$2" range="$3" tmp errf="" diff_rc=0 scan_rc=0 out_s="" err_s="" n_merges="" empty_why
  GATE_FL_R_RC=2; GATE_FL_R_OUT=""; GATE_FL_R_DIGEST=""
  if [ "$kind" = "merges" ]; then
    n_merges=$("$git_fn" rev-list --merges --count "$range" 2>/dev/null) || n_merges=""
    case "$n_merges" in
      ''|*[!0-9]*) GATE_FL_R_OUT="git could not count the merge commits of the range (rev-list --merges --count gave no number)"; return 0 ;;
    esac
    if [ "$n_merges" -eq 0 ] 2>/dev/null; then GATE_FL_R_RC=0; return 0; fi
  fi
  tmp=$(mktemp "${GATE_FS_TMPDIR:-/tmp}/gc-gate-fl-diff-XXXXXX" 2>/dev/null) || { GATE_FL_R_OUT="could not create a temp file for the ${kind} text"; return 0; }
  case "$kind" in
    net)     "$git_fn" -c core.quotepath=off diff -U0 --no-color --no-ext-diff --no-textconv --no-renames "$range" > "$tmp" 2>/dev/null || diff_rc=$? ;;
    history) "$git_fn" -c core.quotepath=off log --no-merges --topo-order --reverse --no-decorate --no-notes --no-show-signature --no-abbrev-commit \
               --pretty=medium --encoding=UTF-8 -p -U0 --no-color --no-ext-diff --no-textconv --no-renames "$range" > "$tmp" 2>/dev/null || diff_rc=$? ;;
    merges)  "$git_fn" -c core.quotepath=off log --merges --no-abbrev --topo-order --reverse --no-decorate --no-notes --no-show-signature --no-abbrev-commit \
               --pretty=medium --encoding=UTF-8 -p -U0 --no-color --no-ext-diff --no-textconv --no-renames "$range" > "$tmp" 2>/dev/null || diff_rc=$? ;;
    *)       diff_rc=97 ;;
  esac
  if [ "$diff_rc" != "0" ]; then
    GATE_FL_R_OUT="git failed to produce the ${kind} text (rc=$diff_rc)"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  # gate_fastlane_decide gets here only after `diff --raw` listed files, and gate_fastlane_confirm only with a fast decision on record (which listed
  # files); a real `git diff -U0` prints a `diff --git` header for every listed file, and a real `git log -p` prints a `commit` line for every commit it
  # lists (and for `merges`, git itself has just counted the merge commits of the range). No text at all means nothing was read — not that there was
  # nothing to flag — so it stays the inert "could not scan" (RC 2, no fingerprint).
  # The scanner itself still answers empty input with clean: that is its contract as a pure function; the lib knows a file list exists, the scanner does not.
  empty_why="a range whose file list is not empty"; [ "$kind" != "merges" ] || empty_why="a range that has merge commits"
  [ -s "$tmp" ] || { GATE_FL_R_OUT="git returned no ${kind} text for ${empty_why} — nothing was read"; rm -f "$tmp" 2>/dev/null || true; return 0; }
  if [ "$kind" != "merges" ]; then GATE_FL_R_DIGEST=$(_gate_fastlane_digest_file "$git_fn" "$tmp") || GATE_FL_R_DIGEST=""; fi
  # the scanner's stderr goes to its own file (named so the dispatcher's gc-gate-fl-diff-* reaper sweeps a leak); with no file it is
  # discarded, and the reason below then says "no stderr" — the exit code and the shape check do not depend on it
  errf=$(mktemp "${GATE_FS_TMPDIR:-/tmp}/gc-gate-fl-diff-err-XXXXXX" 2>/dev/null) || errf=""
  out_s=$(python3 "$GATE_FASTLANE_DIR/gate-fastlane-scan.py" --max-bytes "${GATE_FASTLANE_SCAN_MAX_BYTES:-2097152}" < "$tmp" 2>"${errf:-/dev/null}") || scan_rc=$?
  # the LAST stderr line, capped: for a traceback it is the exception ("RuntimeError: ..."), not the file paths above it
  if [ -n "$errf" ]; then err_s=$(tail -n 1 "$errf" 2>/dev/null | cut -c1-160) || err_s=""; fi
  rm -f "$tmp" "$errf" 2>/dev/null || true
  case "$scan_rc" in
    0) if [ -n "$out_s" ]; then
         scan_rc=2; GATE_FL_R_OUT="scanner exited 0 but printed output — not a clean answer (stderr: ${err_s:-none})"
       fi ;;
    1) if ! _gate_fastlane_is_finding_list "$out_s"; then
         scan_rc=2; GATE_FL_R_OUT="scanner exited 1 with no label/path/line findings — it crashed, it found nothing (stderr: ${err_s:-none})"
       fi ;;
  esac
  if [ "$scan_rc" = "0" ] || [ "$scan_rc" = "1" ]; then
    GATE_FL_R_OUT="$out_s"
  elif [ -z "$GATE_FL_R_OUT" ]; then
    GATE_FL_R_OUT="${err_s:-scanner exited rc=$scan_rc with no message}"
  fi
  GATE_FL_R_RC="$scan_rc"
  return 0
}

# gate_fastlane_scan <git_fn> <base_ref> <head_ref> — runs the content scan over what the merge would put in main, in THREE passes: the
# NET diff (base...head), the HISTORY (every non-merge commit of base..head, messages included) and the MERGE COMMITS' MESSAGES — see
# _gate_fastlane_scan_range for why each. The net pass is not redundant: a number wrapped across two lines that DIFFERENT commits added side
# by side is one number only in the net diff; the history pass is not redundant either: a value added and removed again never appears in the
# net diff; and the merges pass reads what neither of them does: a merge commit's message (it has no diff of its own to make anyone look).
# Sets GATE_FL_SCAN_RC (0 clean | 1 findings | other = could not scan), GATE_FL_SCAN_OUT (label/path/line, no values) and
# GATE_FL_DIFF_DIGEST ("<net digest>:<history digest>" — the fingerprint of the texts of the first two passes; "" when either could not be
# read; the merges pass is deliberately not in it, see _gate_fastlane_scan_range). A finding from ANY pass is rc 1 even when another pass
# could not run (the finding is true whatever the other pass would have said; both end in the normal gate, and the tally books a real finding
# as a finding); clean needs ALL passes clean.
# The net pass runs first, and a finding there ends the scan: the history pass would only report the same line again as `<sha>:<path>`.
#
# The scanner's exit code is a contract (0 clean / 1 findings / 2 could not scan), and python breaks it: an uncaught exception
# exits 1, and anything that dies at IMPORT time (a syntax error, a module-level exception, a regex that does not compile) never
# reaches the scanner's own "any bug here must read as could not scan" guard, which wraps only main(). So a dead scanner used to
# read as "found personal data" — every doc diff bounced, the weekly tally blamed data hygiene, and the traceback (absolute
# paths) went into the marker metadata. Two rules close it: stdout and stderr are KEPT APART (a traceback is never the findings),
# and an answer is believed only when it has the shape its exit code promises — rc 1 needs a list of
# `label<TAB>path<TAB>line` lines (an empty one is not a list), rc 0 needs no output. A scanner that does not answer in its own
# contract is rc 2 with a reason that says so ("it crashed, it did not find anything"), which decide() books as scan-failed, not
# scan-findings.
gate_fastlane_scan() {
  local git_fn="$1" base="$2" head="$3" net_rc net_out net_dig hist_rc hist_out hist_dig mrg_rc mrg_out
  GATE_FL_SCAN_RC=2; GATE_FL_SCAN_OUT=""; GATE_FL_DIFF_DIGEST=""
  if [ ! -r "${GATE_FASTLANE_DIR:-}/gate-fastlane-scan.py" ]; then
    GATE_FL_SCAN_OUT="scanner gate-fastlane-scan.py is missing or unreadable"
    return 0
  fi
  _gate_fastlane_scan_range "$git_fn" net "$base...$head"
  net_rc="$GATE_FL_R_RC"; net_out="$GATE_FL_R_OUT"; net_dig="$GATE_FL_R_DIGEST"
  if [ "$net_rc" = "1" ]; then
    # a finding in the tip is a finding; the history pass would only repeat it under another path spelling (`<sha>:<path>`)
    GATE_FL_SCAN_RC=1; GATE_FL_SCAN_OUT="$net_out"
    return 0
  fi
  _gate_fastlane_scan_range "$git_fn" history "$base..$head"
  hist_rc="$GATE_FL_R_RC"; hist_out="$GATE_FL_R_OUT"; hist_dig="$GATE_FL_R_DIGEST"
  if [ "$hist_rc" = "1" ]; then
    GATE_FL_SCAN_RC=1; GATE_FL_SCAN_OUT="$hist_out"
    return 0
  fi
  _gate_fastlane_scan_range "$git_fn" merges "$base..$head"
  mrg_rc="$GATE_FL_R_RC"; mrg_out="$GATE_FL_R_OUT"
  if [ "$mrg_rc" = "1" ]; then
    GATE_FL_SCAN_RC=1; GATE_FL_SCAN_OUT="$mrg_out"
    return 0
  fi
  if [ "$net_rc" != "0" ]; then
    GATE_FL_SCAN_OUT="net diff: ${net_out}"
    return 0
  fi
  if [ "$hist_rc" != "0" ]; then
    GATE_FL_SCAN_OUT="commit history: ${hist_out}"
    return 0
  fi
  if [ "$mrg_rc" != "0" ]; then
    GATE_FL_SCAN_OUT="merge commit messages: ${mrg_out}"
    return 0
  fi
  GATE_FL_SCAN_RC=0
  if [ -n "$net_dig" ] && [ -n "$hist_dig" ]; then GATE_FL_DIFF_DIGEST="${net_dig}:${hist_dig}"; fi
  return 0
}

# _gate_fastlane_test_path — PATH for the tests: the caller's PATH minus every entry under $HOME. The tests need
# git/jq/python3/bash (system + Homebrew). This drops the tools installed under $HOME — on this host `secret` and
# `notify` (~/.local/bin) — so a test no reviewer has read does not find them by name. It is NOT what keeps
# credentials away, and it does NOT cut the test off from the city: bd, gc, dolt, gh, aws, gcloud and bw live in
# /opt/homebrew/bin and stay on this PATH (measured under the exact env the lane builds: `bd -C <city> list` returns
# the live city's beads, `gc --city <city>` runs). The credential shield is the throwaway HOME that
# gate_fastlane_run_tests sets: `bw` finds no vault there and `gh` is logged out. A test that needs a dropped tool
# usually fails, and a failing test sends the diff to the normal gate — the inert outcome. Not always: a test that guards
# itself (`command -v secret >/dev/null || { echo "SKIP: ..."; exit 0; }`, an idiom this repo already uses) exits 0 without
# running anything, and the lane reads only the exit code, so it counts that as passed. The reason text therefore says
# "exited 0", not "ran green". What bounds it: the diff is doc/test-only, and the fast lane still goes through
# gate_finalize_run, whose full-suite check (ga-3wgx8) runs at the merge in a rig that has opted in with a .gate-full-suite.sh.
# With HOME unset the filter has no way to tell which entries are "under $HOME", and passing every entry through would read
# that as "none of them is". It falls back to the system and Homebrew directories alone: a test that needs a tool outside
# them usually fails (and a failing test sends the diff to the normal gate, the inert outcome), unless it skips itself as above.
_gate_fastlane_test_path() {
  local out="" entry IFS=:
  if [ -z "${HOME:-}" ]; then printf '%s' "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; return 0; fi
  for entry in $PATH; do
    [ -z "$entry" ] && continue
    case "$entry" in "$HOME"|"$HOME"/*) continue ;; esac
    out="${out:+$out:}$entry"
  done
  printf '%s' "${out:-/usr/bin:/bin}"
  return 0
}

# _gate_fastlane_now — the clock, as epoch seconds, or return 1 when it cannot be read (no output then). The test budget is
# measured against it; an unreadable clock must not read as "no time has passed", so callers treat 1 as "budget gone".
_gate_fastlane_now() {
  local n
  n=$(date +%s 2>/dev/null) || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
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
# bd/gc/dolt/bw/gh/aws/gcloud) is a possible hardening, not present here. Sets GATE_FL_TEST_RC (0 every test exited 0 — a
# test that skips itself exits 0 too | 1 a test failed | 2 could not run) and GATE_FL_TEST_OUT.
gate_fastlane_run_tests() {
  local git_fn="$1" sha="$2" paths="$3" tmp wt log f runner rc t0 now spent n=0 max budget per_file ok_n=0 tpath
  GATE_FL_TEST_RC=2; GATE_FL_TEST_OUT=""
  max="${GATE_FASTLANE_TEST_MAX_FILES:-6}"; budget="${GATE_FASTLANE_TEST_BUDGET_SECS:-150}"; per_file="${GATE_FASTLANE_TEST_TIMEOUT_SECS:-60}"
  case "$max" in ''|*[!0-9]*) max=6 ;; esac
  case "$budget" in ''|*[!0-9]*) budget=150 ;; esac
  case "$per_file" in ''|*[!0-9]*) per_file=60 ;; esac

  # `[ -z ]` has no failure mode. The count was `grep -c . || n=0`, which turned a grep that FAILED into "no test entry
  # to run" -> rc 0 -> the lane granted without running the changed tests (an error read as empty). The count below is a
  # shell loop over the same list, with no command that can fail. An empty list is a real "nothing to run" ONLY because
  # classify_raw files every changed test it could not place under UNRUNNABLE or unclassifiable (its runner `case` has an inert
  # default), never under "empty" — that is the invariant this early return leans on.
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

  # the two reads the run cannot go on without — the PATH the tests get and the clock the budget is measured on — come BEFORE the
  # worktree exists, so a failure of either leaves nothing to clean up
  tpath=$(_gate_fastlane_test_path) || tpath=""
  if [ -z "$tpath" ]; then GATE_FL_TEST_OUT="could not build a PATH for the tests"; return 0; fi
  t0=$(_gate_fastlane_now) || t0=""
  if [ -z "$t0" ]; then GATE_FL_TEST_OUT="could not read the clock — the test budget cannot be enforced"; return 0; fi

  tmp="${GATE_FS_TMPDIR:-/tmp}"
  wt="$tmp/gc-gate-fs-fastlane-$$"
  log=$(mktemp "$tmp/gc-gate-fs-fastlane-log-XXXXXX" 2>/dev/null) || { GATE_FL_TEST_OUT="could not create a temp log"; return 0; }
  if ! "$git_fn" worktree add --detach "$wt" "$sha" >/dev/null 2>&1; then
    GATE_FL_TEST_OUT="could not create a worktree for $sha"
    rm -f "$log" 2>/dev/null || true
    return 0
  fi

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # a clock that cannot be read mid-run reads as the budget being spent (spent = budget), never as "no time has passed"
    now=$(_gate_fastlane_now) || now=$((t0 + budget)); spent=$((now - t0))
    if [ "$spent" -ge "$budget" ]; then
      GATE_FL_TEST_OUT="test budget of ${budget}s exhausted after $ok_n of $n test file(s)"
      GATE_FL_TEST_RC=2
      "$git_fn" worktree remove --force "$wt" >/dev/null 2>&1 || true
      rm -f "$log" 2>/dev/null || true
      return 0
    fi
    runner=$(gate_fastlane_test_runner "$f") || runner=""
    rc=0
    # </dev/null: this loop reads its own file list from a heredoc, and a test that reads stdin would eat it.
    case "$runner" in
      bash)
        ( cd "$wt" && env -i HOME="$wt" PATH="$tpath" LC_ALL=C TMPDIR="$wt" timeout "$per_file" bash "$f" ) </dev/null >"$log" 2>&1 || rc=$? ;;
      pytest)
        ( cd "$wt" && env -i HOME="$wt" PATH="$tpath" LC_ALL=C TMPDIR="$wt" timeout "$per_file" python3 -m pytest -q -x -p no:cacheprovider "$f" ) </dev/null >"$log" 2>&1 || rc=$? ;;
      *) rc=99 ;;   # no runner for it (the lookup answered anything but bash/pytest, an empty answer included): not a pass
    esac
    if [ "$rc" != "0" ]; then
      # rc 124 = timeout; 99 = no runner for it; 1 = a real failure OR a missing dependency in the scrubbed env. The fast
      # lane cannot tell which, and it does not need to: either way the diff goes to the normal gate, never to a FAIL.
      GATE_FL_TEST_RC=1
      # `|| true`: a substitution inside an assignment is an errexit trigger, and this one only decorates the message
      GATE_FL_TEST_OUT="test $f exited rc=$rc (124 = timed out after ${per_file}s, 99 = no runner) — tail: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ' | cut -c1-240)" || true
      "$git_fn" worktree remove --force "$wt" >/dev/null 2>&1 || true
      rm -f "$log" 2>/dev/null || true
      return 0
    fi
    ok_n=$((ok_n + 1))
  done <<EOF
$paths
EOF
  GATE_FL_TEST_RC=0
  GATE_FL_TEST_OUT="$ok_n test file(s) exited 0"   # exit 0 is all the lane can see: a test that skips itself exits 0 too
  "$git_fn" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -f "$log" 2>/dev/null || true
  return 0
}

# ── the history the push would publish ──────────────────────────────────────────────────────────────────────────

# gate_fastlane_history <git_fn> <base_sha> <head_sha> — the merge is a FAST-FORWARD: it publishes EVERY commit of base..head, not the net
# diff that the classifier and the tests read. A production-code file added in one commit and deleted in the next, or a CPF pasted and
# removed again, leaves no trace in the net diff and stays in main's history for good (gate round ga-aa8n6z: the variable the lane
# DECIDED on was not the variable the push ACTED on). So every commit the push would send is asked the same two questions as the tip:
# are its files DOC/TEST only (here), and does it add anything the scan rejects (gate_fastlane_scan's history pass, messages included).
# Sets (read by decide/confirm; classify_raw's own GATE_FL_* are clobbered here, so callers read their own list AFTER this):
#   GATE_FL_HIST_STATE     ok | blocked (a commit touches CODE/PROMPT/POLICY) | unreadable (anything that could not be established)
#   GATE_FL_HIST_WHY       one line, never a matched value
#   GATE_FL_HIST_N         the number of commits in the range (merge commits included)
#   GATE_FL_HIST_BLOCKERS  "CLASS<TAB>path" lines when blocked
# Three states, the last one inert: no commit listed, a git error, more commits than GATE_FASTLANE_COMMIT_MAX (a branch that long is a
# job for a reviewer), a merge commit that carries changes of its own (a conflict resolution is content nobody scanned), a record this
# lane cannot classify — all `unreadable`, and all end in the normal gate. A MERGE commit with nothing of its own (`git show --cc`
# prints nothing: the gate's own "Merge origin/main into <branch>" fallback is exactly this) adds no FILE content; what its parents brought
# is in the commits listed here, or already in main. Its MESSAGE is another matter and not asked here: it is published all the same, and
# gate_fastlane_scan's merges pass reads it.
gate_fastlane_history() {
  local git_fn="$1" base="$2" head="$3" max ids id n=0 merges m cc raw raw_rc=0
  GATE_FL_HIST_STATE="unreadable"; GATE_FL_HIST_WHY="not evaluated"; GATE_FL_HIST_N=0; GATE_FL_HIST_BLOCKERS=""
  max="${GATE_FASTLANE_COMMIT_MAX:-30}"
  case "$max" in ''|*[!0-9]*) max=30 ;; esac

  ids=$("$git_fn" rev-list "$base..$head" 2>/dev/null) || { GATE_FL_HIST_WHY="git could not list the commits the push would publish"; return 0; }
  while IFS= read -r id; do
    if [ -n "$id" ]; then n=$((n + 1)); fi
  done <<EOF
$ids
EOF
  GATE_FL_HIST_N="$n"
  if [ "$n" -eq 0 ]; then
    GATE_FL_HIST_WHY="no commit lies between the base and the head although the diff lists files — cannot establish what would be published"; return 0
  fi
  if [ "$n" -gt "$max" ]; then
    GATE_FL_HIST_WHY="$n commits would be published, over the fast-lane cap of $max — a branch that long is read by a reviewer"; return 0
  fi

  merges=$("$git_fn" rev-list --merges "$base..$head" 2>/dev/null) || { GATE_FL_HIST_WHY="git could not list the merge commits among the ones the push would publish"; return 0; }
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    cc=$("$git_fn" show --cc --format= --no-color --no-ext-diff --no-textconv "$m" 2>/dev/null) || { GATE_FL_HIST_WHY="git could not show a merge commit among the ones the push would publish"; return 0; }
    if [ -n "$cc" ]; then
      GATE_FL_HIST_WHY="a merge commit among the ones the push would publish carries changes of its own (a conflict resolution nobody scanned)"; return 0
    fi
  done <<EOF
$merges
EOF

  raw=$("$git_fn" -c core.quotepath=off log --no-merges --raw --no-renames --format= "$base..$head" 2>/dev/null) || raw_rc=$?
  if [ "$raw_rc" != "0" ]; then
    GATE_FL_HIST_WHY="git log --raw of the commits the push would publish failed (rc=$raw_rc)"; return 0
  fi
  gate_fastlane_classify_raw "$raw"
  if [ "$GATE_FL_STATE" != "ok" ]; then
    GATE_FL_HIST_WHY="the files the commits touch cannot be classified: ${GATE_FL_WHY}"; return 0
  fi
  if [ -n "$GATE_FL_BLOCKERS" ]; then
    GATE_FL_HIST_STATE="blocked"; GATE_FL_HIST_BLOCKERS="$GATE_FL_BLOCKERS"
    GATE_FL_HIST_WHY="$((GATE_FL_N_CODE + GATE_FL_N_PROMPT + GATE_FL_N_POLICY)) file change(s) across the $n commit(s) the push would publish are production code, prompt/doctrine or the gate's own policy (code=${GATE_FL_N_CODE} prompt=${GATE_FL_N_PROMPT} policy=${GATE_FL_N_POLICY}) — even if a later commit undoes them, they stay in main's history"
    return 0
  fi
  GATE_FL_HIST_STATE="ok"; GATE_FL_HIST_WHY="$n commit(s), every file change in them DOC or TEST"
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
    # (one literal call per code, not one call with a variable: the tally selftest finds the codes a producer emits by grepping for them)
    case "$GATE_FL_OFF_CODE" in
      flag-file)         _gate_fastlane_normal "flag-file" "$GATE_FL_OFF_WHY" ;;
      switch-unreadable) _gate_fastlane_normal "switch-unreadable" "$GATE_FL_OFF_WHY" ;;
      *)                 _gate_fastlane_normal "disabled" "$GATE_FL_OFF_WHY" ;;
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

  # the history first: it reuses classify_raw, which the tip's own classification below must be the LAST to write
  gate_fastlane_history "$git_fn" "$base_sha" "$head_sha"

  raw=$("$git_fn" -c core.quotepath=off diff --raw --no-renames "$base_sha...$head_sha" 2>/dev/null) || raw_rc=$?
  if [ "$raw_rc" != "0" ]; then
    _gate_fastlane_normal "diff-raw-failed" "git diff --raw failed (rc=$raw_rc) — cannot classify, normal gate"; return 0
  fi

  gate_fastlane_classify_raw "$raw"
  GATE_LANE_COUNTS="doc=${GATE_FL_N_DOC} test=${GATE_FL_N_TEST} prompt=${GATE_FL_N_PROMPT} code=${GATE_FL_N_CODE} policy=${GATE_FL_N_POLICY}"
  if [ "$GATE_FL_STATE" != "ok" ]; then
    _gate_fastlane_normal "unclassifiable" "unclassifiable diff: ${GATE_FL_WHY}"; return 0
  fi
  # (the two list renderings below only DECORATE the outcome — whether the lane stays normal is decided by GATE_FL_BLOCKERS /
  # GATE_FL_UNRUNNABLE themselves, never by their rendering — so a rendering that fails just leaves the file list empty)
  blockers=$(printf '%s' "$GATE_FL_BLOCKERS" | _gate_fastlane_cap_lines "${GATE_FASTLANE_LIST_MAX:-30}") || blockers=""
  if [ -n "$GATE_FL_BLOCKERS" ]; then
    _gate_fastlane_normal "code-or-prompt" "$((GATE_FL_N_CODE + GATE_FL_N_PROMPT + GATE_FL_N_POLICY)) file(s) are production code, prompt/doctrine or the gate's own policy (code=${GATE_FL_N_CODE} prompt=${GATE_FL_N_PROMPT} policy=${GATE_FL_N_POLICY}) — normal gate" "$blockers"
    return 0
  fi
  uncls=$(printf '%s' "$GATE_FL_UNRUNNABLE" | _gate_fastlane_cap_lines 10) || uncls=""
  if [ -n "$GATE_FL_UNRUNNABLE" ]; then
    _gate_fastlane_normal "test-unrunnable" "changed test(s) the fast lane cannot run (a language with no runner, a helper script, a file type not on its data list) — normal gate" "$(printf '%s' "$uncls" | sed 's/^/TEST-UNRUNNABLE\t/')"
    return 0
  fi

  # The tip is DOC/TEST only. What the push publishes is every commit on the way to it (gate_fastlane_history): a commit that touched code
  # or prompt text and was undone by a later one is gone from the tip and still in main's history — a production change no reviewer read.
  case "$GATE_FL_HIST_STATE" in
    ok) ;;
    blocked) _gate_fastlane_normal "history-code" "the tip is DOC/TEST only, but ${GATE_FL_HIST_WHY} — normal gate" "$(printf '%s' "$GATE_FL_HIST_BLOCKERS" | _gate_fastlane_cap_lines "${GATE_FASTLANE_LIST_MAX:-30}" | sed 's/^/HISTORY\t/')"
             return 0 ;;
    *) _gate_fastlane_normal "history-unverified" "the commits the push would publish could not be verified: ${GATE_FL_HIST_WHY:-no detail} — unverified is not clean, normal gate"
       return 0 ;;
  esac

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

  # The only success path. Everything above returned. Unlike the two renderings above, THIS list is part of the grant: it is the
  # record of the files that decided it. A list that cannot be produced — or is empty although files were classified — is not a
  # grant with the record missing; it is a lane that could not account for itself, and stays normal.
  GATE_LANE_FILES=$(printf '%s' "$GATE_FL_ALLFILES" | _gate_fastlane_cap_lines "${GATE_FASTLANE_LIST_MAX:-30}") || GATE_LANE_FILES=""
  if [ -z "$GATE_LANE_FILES" ]; then
    _gate_fastlane_normal "unclassifiable" "could not render the list of files that decided the lane — a grant that cannot name its files is not a grant, normal gate"
    return 0
  fi
  GATE_LANE_REASON="every file is DOC or TEST (${GATE_LANE_COUNTS}), in all ${GATE_FL_HIST_N} commit(s) the push publishes too; content scan of the tip, of each commit and of every commit message (merge commits' included) clean; ${GATE_FL_TEST_OUT} — merged without an LLM reviewer"
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
# Three states, like everything here: the switch is ON, OFF, or its location is UNKNOWN. Neither GATE_FASTLANE_OFF_FILE nor GC_CITY
# set used to read as a path under a made-up city that never exists — i.e. "the switch is not thrown" — so a process that could
# not even find the switch ran the lane as if the operator had left it on. That is the one reading that must not be the default
# for a control whose whole job is to stop the lane: the unknown location answers "off" (code switch-unreadable). The dispatcher
# always has GC_CITY (it sets it at the top), so this only ever fires for a lib sourced somewhere that does not.
# What it does NOT cover: `[ -e ]` is false both for "absent" and for "cannot stat" (a permission error on the city's own .gc/),
# so an unreadable directory still reads as "not thrown".
_gate_fastlane_is_off() {
  local flag
  GATE_FL_OFF_CODE=""; GATE_FL_OFF_WHY=""
  if [ "${GATE_FASTLANE_ENABLED:-1}" != "1" ]; then
    GATE_FL_OFF_CODE="disabled"; GATE_FL_OFF_WHY="fast lane disabled (GATE_FASTLANE_ENABLED=0)"; return 0
  fi
  flag="${GATE_FASTLANE_OFF_FILE:-}"
  if [ -z "$flag" ] && [ -n "${GC_CITY:-}" ]; then flag="$GC_CITY/.gc/gate-fastlane.off"; fi
  if [ -z "$flag" ]; then
    GATE_FL_OFF_CODE="switch-unreadable"; GATE_FL_OFF_WHY="fast lane cannot find its kill switch (GC_CITY and GATE_FASTLANE_OFF_FILE are both unset) — a switch that cannot be read is not a switch that is off, normal gate"; return 0
  fi
  if [ -e "$flag" ]; then
    GATE_FL_OFF_CODE="flag-file"; GATE_FL_OFF_WHY="fast lane switched off by the flag file (.gc/gate-fastlane.off) — normal gate"; return 0
  fi
  return 1
}

# _gate_fastlane_revoke <code> <why> — the inert outcome of a failed confirmation: the lane is "normal" afterwards and no
# fingerprint is left behind for a later call to trust. Always returns 0 (the caller returns 1).
# What described the GRANT is cleared with it — the reason text, the file list and the counts ("every file is DOC or TEST…" beside lane=normal
# is a contradiction a reader can act on); the failure is in GATE_LANE_CONFIRM_CODE/WHY. GATE_LANE_REASON_CODE is left to the caller: the
# vocabulary of reason codes belongs to the record and the tally, and the dispatcher (which records the revocation as a NORMAL decision)
# sets it, with the reason text, when it books this outcome.
_gate_fastlane_revoke() {
  GATE_LANE="normal"; GATE_LANE_DIGEST=""
  GATE_LANE_REASON=""; GATE_LANE_FILES=""; GATE_LANE_COUNTS=""
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
  if [ "$GATE_FL_SCAN_RC" = "1" ]; then
    # a finding ends the scan before a fingerprint exists (see gate_fastlane_scan), but a finding is an answer, not a failure to read: what would
    # land is not what was checked — the decision was a CLEAN scan. (Labels only, never the matched text: this reason goes to bead comments.)
    _gate_fastlane_revoke "diff-changed" "the diff that would land is not the diff the lane checked (the branch tip moved, or its content changed, after the decision) — and the content scan now rejects it ($(printf '%s' "$GATE_FL_SCAN_OUT" | cut -f1 | sort | uniq -c | awk '{printf "%s%s×%s", (NR>1?", ":""), $2, $1}'))"; return 1
  fi
  if [ -z "$GATE_FL_DIFF_DIGEST" ]; then
    _gate_fastlane_revoke "cannot-confirm" "the diff that would land could not be read (${GATE_FL_SCAN_OUT:-no detail})"; return 1
  fi
  if [ "$GATE_FL_DIFF_DIGEST" != "$decided" ]; then
    _gate_fastlane_revoke "diff-changed" "the diff that would land is not the diff the lane checked (the branch tip moved, or its content changed, after the decision) — no scan or test ever ran on it"; return 1
  fi

  # The same bytes mean the same files, added lines and tests. These two do not lean on that inference: they ask the
  # commit that lands, again, directly — the tip's files AND the files of every commit the push would publish.
  gate_fastlane_history "$git_fn" "$base" "$head"
  case "$GATE_FL_HIST_STATE" in
    ok) ;;
    blocked) _gate_fastlane_revoke "no-longer-fast" "the commits that would land are not DOC/TEST-only any more: ${GATE_FL_HIST_WHY}"; return 1 ;;
    *) _gate_fastlane_revoke "cannot-confirm" "the commits that would land could not be verified: ${GATE_FL_HIST_WHY:-no detail}"; return 1 ;;
  esac
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
