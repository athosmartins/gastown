#!/usr/bin/env bash
# gate-e6d-whole-diff-or-park.selftest.sh (ga-5w2gpw item d, 2026-09-30)
#
# CLASS: a reviewer that was shown a PIECE of the diff could PASS, and the branch merged on it.
# The gate capped the reviewer's payload at 2000 lines, truncated on whole-file boundaries, and told the
# reviewer "PARTIAL DIFF — showing 12 of 29 files … DO NOT treat the omitted files as reviewed" — then took
# that reviewer's PASS as the verdict on the WHOLE change. Nothing in the dispatcher read DIFF_COVERAGE (only the
# builder's pre-gate-review.sh did, ga-gnr3tw attempt 3). E4: 182 of 2,628 runs (6.9%) were partial; when the
# reviewer passed, the files nobody read merged with the rest.
#
# MEASURED (E4 dataset, runs2, 182 partial runs): median 2,837 diff lines, p90 6,476, max 13,607 — the 2000-line
# budget was simply too tight. 89% of them fit in 6,000 lines. But the OS argument limit and the reviewer's
# context are in BYTES, not lines: stored tasks reach 193 KB at 2,003 lines, dense diffs run 450 B/line, so a
# line ceiling alone could hand one reviewer 900 KB. Hence a byte ceiling beside the line one.
#
# FIX under test (E6 item d):
#   1. gate_build_diff_payload decides "whole" by BOTH ceilings (lines AND bytes); its default line budget rises
#      2000 → 6000 and GATE_DIFF_BYTE_BUDGET (default 400000) is new. Over either ceiling → coverage=partial.
#   2. The dispatcher builds the payload BEFORE the gate-run bead exists (Step 5c) and, when coverage is partial,
#      PARKS the marker fail-closed (gate-status:error + gate:needs-human:technical, author + Mayor told, event logged)
#      without spawning a reviewer — it neither reviews a piece nor burns a fix attempt.
#   3. The builder's pre-gate-review.sh uses the same default, so the rehearsal and the gate agree on "whole".
#
# Strategy: the lib runs against REAL git (real repo, real diffs). The dispatcher block is extracted between its
# SELFTEST-EXTRACT sentinels and run in a fresh `set -euo pipefail` bash against stubs (git_rig/bd/gc/…), the way the
# live sweep runs it. The harness is mutation-checked (a block without the park condition must read as RED).
# bash 3.2 compatible. Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
LIB="$SELF_DIR/gate-review-task.lib.sh"
PREGATE="$SELF_DIR/pre-gate-review.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
# has <haystack> <needle>: a `case` match, not `printf | grep -q` (SIGPIPE under pipefail made that flaky).
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

echo "== gate-e6d-whole-diff-or-park.selftest =="
[ -f "$DISPATCHER" ] && [ -f "$LIB" ] && [ -f "$PREGATE" ] || { echo "FATAL: dispatcher/lib/pre-gate not found beside the selftest" >&2; exit 2; }
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher parses under /bin/bash (3.2)"; else bad "dispatcher does NOT parse under /bin/bash 3.2"; fi
if /bin/bash -n "$LIB" 2>/dev/null; then ok "lib parses under /bin/bash (3.2)"; else bad "lib does NOT parse under /bin/bash 3.2"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e6d.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── 1. the lib, against real git ─────────────────────────────────────────────────────────────────────────
echo "── 1. gate_build_diff_payload: whole is decided by lines AND bytes ──"
# shellcheck disable=SC1090
. "$LIB"

REPO=""
mkrepo() {
  REPO="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$REPO" init -q
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
  echo base > "$REPO/base.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" checkout -q -b feature
}
# addfile <name> <lines> <width>: a new file of <lines> lines, each <width> characters
addfile() {
  awk -v n="$2" -v w="$3" 'BEGIN { s = ""; for (j = 0; j < w; j++) s = s "x"; for (i = 1; i <= n; i++) print s }' > "$REPO/$1"
}
commit_feature() { git -C "$REPO" add -A; git -C "$REPO" commit -q -m feat; }
gitc() { git -C "$REPO" "$@"; }
files_of() { git -C "$REPO" diff --name-only main...feature; }
# payload <budget-or-empty>  -> runs the lib function for the current $REPO; sets the DIFF_* globals
payload() {
  local cf; cf="$(files_of)"
  gate_build_diff_payload gitc main feature "$cf" "$(printf '%s\n' "$cf" | grep -c .)" "${1:-}" "cd $REPO && git diff main...feature"
}
unset GATE_DIFF_BYTE_BUDGET

# 1a. ~3000 diff lines: above the OLD 2000 budget, well inside 6000 and inside the byte ceiling. The reviewer must get all of it.
mkrepo; addfile a.txt 1000 40; addfile b.txt 1000 40; addfile c.txt 1000 40; commit_feature
payload ""
if [ "${DIFF_RAW_TOTAL_LINES:-0}" -gt 2000 ] && [ "${DIFF_RAW_TOTAL_LINES:-0}" -lt 6000 ]; then ok "fixture sanity: a ${DIFF_RAW_TOTAL_LINES}-line diff (above the old 2000 budget, below 6000)"; else bad "fixture sanity: expected 2000 < lines < 6000, got ${DIFF_RAW_TOTAL_LINES:-unset}"; fi
if [ "${DIFF_COVERAGE:-}" = "full" ]; then ok "1a. default budget: a ~3000-line diff is handed over WHOLE (coverage=full)"; else bad "1a. default budget: a ~3000-line diff is still coverage=${DIFF_COVERAGE:-unset} (the 2000-line budget cut it — 93% of the E4 partial runs fit in 6000)"; fi
if has "$DIFF_HEADER" "FULL DIFF (complete"; then ok "1a. the header says FULL"; else bad "1a. header is not FULL: $(printf '%s' "$DIFF_HEADER" | head -1)"; fi

# 1b. line boundary: exactly the budget is whole, one more line is partial (explicit small budget — independent of the default)
mkrepo; addfile a.txt 50 10; commit_feature
payload ""; EXACT="$DIFF_RAW_TOTAL_LINES"
payload "$EXACT"
if [ "${DIFF_COVERAGE:-}" = "full" ]; then ok "1b. a diff of exactly <budget> lines is whole"; else bad "1b. exact-budget diff read as ${DIFF_COVERAGE:-unset}"; fi
payload "$((EXACT - 1))"
if [ "${DIFF_COVERAGE:-}" = "partial" ]; then ok "1b. one line over the budget is partial"; else bad "1b. budget-1 read as ${DIFF_COVERAGE:-unset}"; fi
# the header of a LINE-driven partial keeps its original wording and does not mention bytes
if has "$DIFF_HEADER" "total diff lines). DO NOT treat the omitted files" && ! has "$DIFF_HEADER" "bytes"; then ok "1b. a line-driven partial keeps the original header wording (no bytes clause)"; else bad "1b. line-driven partial header changed: $(printf '%s' "$DIFF_HEADER" | head -1)"; fi

# 1c. few lines, huge bytes: 200 lines x 3000 chars = ~600 KB. The line count says "whole"; the byte count says it is not.
mkrepo; addfile wide.txt 200 3000; commit_feature
payload ""
if [ "${DIFF_COVERAGE:-}" = "partial" ]; then ok "1c. a 200-line / ~600 KB diff is NOT whole: the byte ceiling applies (coverage=partial)"; else bad "1c. a 200-line / ~600 KB diff read as coverage=${DIFF_COVERAGE:-unset} — a line ceiling alone would send one reviewer ~600 KB (the stored-task maximum so far is 193 KB)"; fi
if [ "${DIFF_RAW_TOTAL_BYTES:-0}" -gt 400000 ]; then ok "1c. DIFF_RAW_TOTAL_BYTES is published (${DIFF_RAW_TOTAL_BYTES})"; else bad "1c. DIFF_RAW_TOTAL_BYTES missing/too small: ${DIFF_RAW_TOTAL_BYTES:-unset}"; fi
if has "$DIFF_HEADER" "bytes"; then ok "1c. a byte-driven partial says so in the header (the reviewer is told why)"; else bad "1c. a byte-driven partial does not mention bytes in the header: $(printf '%s' "$DIFF_HEADER" | head -1)"; fi
RAWB="$(git -C "$REPO" diff main...feature | wc -c | tr -d ' ')"
if [ "${DIFF_RAW_TOTAL_BYTES:-x}" = "$RAWB" ]; then ok "1c. DIFF_RAW_TOTAL_BYTES equals the byte length of git diff ($RAWB)"; else bad "1c. DIFF_RAW_TOTAL_BYTES=${DIFF_RAW_TOTAL_BYTES:-unset} but git diff is $RAWB bytes"; fi
# 0 turns the byte ceiling off (the same "0 = off" convention as the other gate knobs), and only that
GATE_DIFF_BYTE_BUDGET=0 payload ""
if [ "${DIFF_COVERAGE:-}" = "full" ]; then ok "1c. GATE_DIFF_BYTE_BUDGET=0 disables the byte ceiling"; else bad "1c. GATE_DIFF_BYTE_BUDGET=0 still gave coverage=${DIFF_COVERAGE:-unset}"; fi
GATE_DIFF_BYTE_BUDGET=abc payload ""
if [ "${DIFF_COVERAGE:-}" = "partial" ]; then ok "1c. a garbage GATE_DIFF_BYTE_BUDGET falls back to the default ceiling (never to 'no ceiling')"; else bad "1c. garbage byte budget gave coverage=${DIFF_COVERAGE:-unset}"; fi

# 1d. the partial payload also honours the byte ceiling, whole files only: 4 files of ~150 KB -> 2 fit, 2 are named as omitted
mkrepo; addfile f1.txt 100 1500; addfile f2.txt 100 1500; addfile f3.txt 100 1500; addfile f4.txt 100 1500; commit_feature
payload ""
if [ "${DIFF_COVERAGE:-}" = "partial" ] && [ "${DIFF_SHOWN_FILES:-x}" = "2" ]; then ok "1d. 4 x ~150 KB files: exactly 2 are shown (whole), coverage=partial"; else bad "1d. expected partial with 2 shown files, got coverage=${DIFF_COVERAGE:-unset} shown=${DIFF_SHOWN_FILES:-unset}"; fi
if has "${DIFF_OMITTED_LIST:-}" "f3.txt" && has "${DIFF_OMITTED_LIST:-}" "f4.txt" && ! has "${DIFF_OMITTED_LIST:-}" "f1.txt"; then ok "1d. the omitted list names f3 and f4 (and not the shown f1)"; else bad "1d. omitted list wrong: $(printf '%s' "${DIFF_OMITTED_LIST:-}" | tr '\n' ' ')"; fi
SHOWN_BYTES="$(printf '%s' "$DIFF_FULL" | wc -c | tr -d ' ')"
if [ "$SHOWN_BYTES" -le 400000 ]; then ok "1d. the shown payload stays under the byte ceiling ($SHOWN_BYTES <= 400000)"; else bad "1d. shown payload is $SHOWN_BYTES bytes, over the 400000 ceiling"; fi

# 1e. the limits actually applied are published, so a caller can quote them without re-deriving the defaults
mkrepo; addfile a.txt 10 10; commit_feature
GATE_DIFF_BYTE_BUDGET=12345 payload 77
if [ "${DIFF_LIMIT_LINES:-x}" = "77" ] && [ "${DIFF_LIMIT_BYTES:-x}" = "12345" ]; then ok "1e. DIFF_LIMIT_LINES / DIFF_LIMIT_BYTES publish the ceilings in force (77 / 12345)"; else bad "1e. limits published as lines=${DIFF_LIMIT_LINES:-unset} bytes=${DIFF_LIMIT_BYTES:-unset}"; fi

# 1g. error must not read as "within budget": the old check was `[ lines -le budget ]`, which FAILS CLOSED (a count that did not
# come back as a number made `[` error, and the code fell into the partial branch). A rewrite to `-gt` inverts that and reads the
# same garbage as "whole". Drive it with a `wc` that answers garbage / nothing, for the lines and for the bytes.
mkrepo; addfile a.txt 20 10; commit_feature
SHIM="$TMP/shim"; mkdir -p "$SHIM"
REAL_WC="$(command -v wc)"
printf '#!/bin/bash\nexec "%s" "$@" | sed "s/^.*$/garbage/"\n' "$REAL_WC" > "$SHIM/wc"; chmod +x "$SHIM/wc"
OLDPATH="$PATH"; PATH="$SHIM:$PATH"
payload ""
PATH="$OLDPATH"
if [ "${DIFF_COVERAGE:-}" = "partial" ]; then ok "1g. a line/byte count that is not a number is coverage=partial, as the old -le check read it (fail closed)"; else bad "1g. garbage counts read as coverage=${DIFF_COVERAGE:-unset} — an error must read as NOT within budget (partial), never full or unknown"; fi
if [ "${DIFF_SHOWN_FILES:-x}" = "0" ] && has "${DIFF_OMITTED_LIST:-}" "a.txt" && has "${DIFF_OMITTED_LIST:-}" "could not be measured"; then ok "1g. a file whose size cannot be measured is listed as omitted (never counted as shown) and the shell survives set -u"; else bad "1g. unmeasurable file handled wrong: shown=${DIFF_SHOWN_FILES:-unset} omitted='$(printf '%s' "${DIFF_OMITTED_LIST:-}" | tr '\n' ' ')'"; fi
printf '#!/bin/bash\nif [ "${1:-}" = "-c" ]; then exit 1; fi\nexec "%s" "$@"\n' "$REAL_WC" > "$SHIM/wc"
PATH="$SHIM:$PATH"
payload ""
PATH="$OLDPATH"
if [ "${DIFF_COVERAGE:-}" = "partial" ]; then ok "1g. a failing byte count (wc -c fails, lines fine) is coverage=partial, not full"; else bad "1g. an unreadable byte count read as coverage=${DIFF_COVERAGE:-unset} (must be partial)"; fi
payload ""
if [ "${DIFF_COVERAGE:-}" = "full" ]; then ok "1g. control: with the real wc the same small diff IS full (the shim, not the fixture, caused the above)"; else bad "1g. control failed: the small diff is coverage=${DIFF_COVERAGE:-unset} with the real wc"; fi

# 1f. third state unchanged: a git that FAILS reads as unknown, never full and never partial (a separate bead owns that limit)
gitfail() { return 1; }
gate_build_diff_payload gitfail main feature "a.txt" 1 "" "esc"
if [ "${DIFF_COVERAGE:-}" = "unknown" ]; then ok "1f. a failing git read is coverage=unknown (unchanged)"; else bad "1f. failing git read gave coverage=${DIFF_COVERAGE:-unset}"; fi

# ── 2. the three defaults agree ──────────────────────────────────────────────────────────────────────────
echo "── 2. gate, lib and pre-gate use the SAME default ceilings ──"
D_LINES="$(sed -n 's/^GATE_DIFF_LINE_BUDGET="\${GATE_DIFF_LINE_BUDGET:-\([0-9][0-9]*\)}".*/\1/p' "$DISPATCHER" | head -1)"
L_LINES="$(sed -n 's/.*_budget="\${6:-\([0-9][0-9]*\)}".*/\1/p' "$LIB" | head -1)"
P_LINES="$(sed -n 's/.*"\${GATE_DIFF_LINE_BUDGET:-\([0-9][0-9]*\)}".*/\1/p' "$PREGATE" | head -1)"
D_BYTES="$(sed -n 's/^GATE_DIFF_BYTE_BUDGET="\${GATE_DIFF_BYTE_BUDGET:-\([0-9][0-9]*\)}".*/\1/p' "$DISPATCHER" | head -1)"
L_BYTES="$(sed -n 's/.*_byte_budget="\${GATE_DIFF_BYTE_BUDGET:-\([0-9][0-9]*\)}".*/\1/p' "$LIB" | head -1)"
if [ -n "$D_LINES" ] && [ "$D_LINES" = "$L_LINES" ] && [ "$D_LINES" = "$P_LINES" ]; then ok "line budget default agrees: dispatcher=$D_LINES lib=$L_LINES pre-gate=$P_LINES"; else bad "line budget defaults DISAGREE or are missing: dispatcher='$D_LINES' lib='$L_LINES' pre-gate='$P_LINES' — the builder would rehearse a different 'whole' than the gate enforces"; fi
if [ -n "$D_BYTES" ] && [ "$D_BYTES" = "$L_BYTES" ]; then ok "byte budget default agrees: dispatcher=$D_BYTES lib=$L_BYTES"; else bad "byte budget defaults DISAGREE or are missing: dispatcher='$D_BYTES' lib='$L_BYTES'"; fi
if [ -n "$D_LINES" ] && [ "$D_LINES" -gt 2000 ]; then ok "the line default is above the old 2000 that cut 93% of the E4 partial runs ($D_LINES)"; else bad "the line default is still '$D_LINES' (old value 2000)"; fi

# ── 3. the dispatcher's Step 5c: whole diff -> proceed, partial -> park before any reviewer ──────────────
echo "── 3. dispatcher Step 5c (extracted, run under stubs) ──"
BUDGET_SRC="$(sed -n '/^# SELFTEST-EXTRACT gate-diff-budget: BEGIN/,/^# SELFTEST-EXTRACT gate-diff-budget: END/p' "$DISPATCHER")"
BLOCK_SRC="$(sed -n '/^# SELFTEST-EXTRACT gate-diff-park: BEGIN/,/^# SELFTEST-EXTRACT gate-diff-park: END/p' "$DISPATCHER")"
if [ -n "$BUDGET_SRC" ] && [ -n "$BLOCK_SRC" ]; then
  ok "located the dispatcher's budget block and Step 5c block by their SELFTEST-EXTRACT sentinels"
else
  bad "could not locate the dispatcher's Step 5c (budget='${#BUDGET_SRC}' bytes, block='${#BLOCK_SRC}' bytes) — the park is not wired"
fi
printf '%s\n' "$BUDGET_SRC" > "$TMP/budget.sh"
printf '%s\n' "$BLOCK_SRC" > "$TMP/block.sh"
# the dispatcher's real defaults, read the way the live script reads them
LINE_DEF=6000; BYTE_DEF=400000
if [ -n "$BUDGET_SRC" ]; then
  LINE_DEF="$(bash -c ". '$TMP/budget.sh'; echo \"\$GATE_DIFF_LINE_BUDGET\"" 2>/dev/null)"
  BYTE_DEF="$(bash -c ". '$TMP/budget.sh'; echo \"\${GATE_DIFF_BYTE_BUDGET:-}\"" 2>/dev/null)"
fi
case "$LINE_DEF" in ''|*[!0-9]*) LINE_DEF=6000 ;; esac
case "$BYTE_DEF" in ''|*[!0-9]*) BYTE_DEF=400000 ;; esac

cat > "$TMP/stubs.sh" <<'STUBS'
# stubs for the Step 5c block: every side effect is appended to $LOGDIR/calls.log
gen() { awk -v n="$1" -v w="$2" 'BEGIN { s = "+"; for (j = 1; j < w; j++) s = s "x"; for (i = 1; i <= n; i++) print s }'; }
git_rig() {
  case "$*" in
    "diff --stat "*) echo " $SC_FILES files changed, $SC_LINES insertions(+)"; return 0 ;;
    *"-- :(top,literal)"*) gen "$((SC_LINES / SC_FILES))" "$SC_WIDTH"; return 0 ;;
    "diff "*"...origin/"*) [ "${SC_GITFAIL:-0}" = "1" ] && return 1; gen "$SC_LINES" "$SC_WIDTH"; return 0 ;;
  esac
  return 0
}
rec() { printf '%s|%s\n' "$1" "$2" >> "$LOGDIR/calls.log"; }
bd()  { rec bd "$*"; return 0; }
gc()  { rec gc "$*"; return 0; }
set_gate_status() { rec set_gate_status "$1 $2"; return 0; }
gate_apply_needs_human() { rec gate_apply_needs_human "$*"; echo "${SC_NH_STATUS:-armed}"; return 0; }
gate_needs_human_clause() { echo "NH-CLAUSE[$1]"; return 0; }
log()  { rec log "$*"; return 0; }
warn() { rec warn "$*"; return 0; }
err()  { rec err "$*"; return 0; }
notify() { rec notify "$*"; return 0; }
STUBS

# run_block <lines> <width> <files> [VAR=val ...]: a fresh `set -euo pipefail` bash, the block SOURCED (so the real `exit 0`
# of the park ends the whole shell and the REACHED_AFTER marker after it is never printed — the way the live sweep behaves).
run_block() {
  local L="$1" W="$2" NF="$3"; shift 3
  LOGDIR="$(mktemp -d "$TMP/run.XXXXXX")"; : > "$LOGDIR/calls.log"
  local cf="" i=1
  while [ "$i" -le "$NF" ]; do cf="${cf}f${i}.py
"; i=$((i+1)); done
  cf="${cf%
}"
  OUT="$(
    env SC_LINES="$L" SC_WIDTH="$W" SC_FILES="$NF" LOGDIR="$LOGDIR" CF="$cf" \
        TMP="$TMP" LIBPATH="$LIB" ${1+"$@"} \
      bash -c '
        set -euo pipefail
        . "$TMP/stubs.sh"
        . "$LIBPATH"
        . "$TMP/budget.sh"
        DEFAULT_BRANCH="main"; BRANCH="crew/x/bead-1"; RIG="whatsapp_automation"; RIG_PATH="/fake/rig"; GIT_DIR_PATH="/fake/rig"
        IS_CONTAINER_RIG=0; MARKER_ID="m-1"; BEAD_ID="${SC_BEAD_ID-bead-1}"; BEAD_CITY="bead-city"; GC_CITY="gc-city"
        AUTHOR="${SC_AUTHOR-crew/author}"; QG_LOG="$LOGDIR/qg.log"
        CHANGED_FILES="$CF"; DIFF_FILE_COUNT="$SC_FILES"
        . "$TMP/block.sh"
        echo "REACHED_AFTER=1"
        echo "COVERAGE=${DIFF_COVERAGE:-unset}"
        echo "FULLBYTES=$(printf "%s" "${DIFF_FULL:-}" | wc -c | tr -d " ")"
      ' 2>&1
  )"
  RC=$?
  CALLS="$(cat "$LOGDIR/calls.log" 2>/dev/null)"
  QGLINE="$(tail -1 "$LOGDIR/qg.log" 2>/dev/null)"
}
reached() { has "$OUT" "REACHED_AFTER=1"; }

if [ -n "$BLOCK_SRC" ]; then
  # 3a. a whole diff goes on to spawn reviewers; the block has no side effect at all
  run_block "$LINE_DEF" 30 3
  if reached && [ "$RC" = "0" ]; then ok "3a. a diff of exactly $LINE_DEF lines falls through to the gate-run (REACHED_AFTER)"; else bad "3a. a within-ceiling diff did not fall through (rc=$RC): $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"; fi
  if has "$OUT" "COVERAGE=full"; then ok "3a. coverage=full and the payload is the whole diff"; else bad "3a. coverage was not full: $(printf '%s' "$OUT" | grep COVERAGE)"; fi
  if ! has "$CALLS" "set_gate_status" && ! has "$CALLS" "gate_apply_needs_human" && ! has "$CALLS" "mail send"; then ok "3a. no park side effect on a whole diff (no status write, no needs-human, no mail)"; else bad "3a. a whole diff triggered a park side effect: $CALLS"; fi

  # 3b. one line over the ceiling: parked before any reviewer
  run_block "$((LINE_DEF + 1))" 30 3
  if ! reached && [ "$RC" = "0" ]; then ok "3b. ${LINE_DEF}+1 lines: the block ENDS the sweep for this marker (exit 0, never reaches the gate-run)"; else bad "3b. an over-ceiling diff fell through to the gate-run (rc=$RC) — a reviewer would be handed a piece and its PASS would merge"; fi
  if has "$CALLS" "set_gate_status|m-1 error"; then ok "3b. marker parked at gate-status:error"; else bad "3b. marker NOT parked at error: $CALLS"; fi
  if has "$CALLS" "gate_apply_needs_human|bead-city bead-1 gate:needs-human:technical"; then ok "3b. gate:needs-human:technical armed on the source bead"; else bad "3b. needs-human not armed on the bead: $CALLS"; fi
  if has "$CALLS" "label remove bead-1 story:in-flight" && has "$CALLS" "label remove bead-1 gate:reviewing" && has "$CALLS" "label remove bead-1 pilot:dispatched" && has "$CALLS" "assign bead-1"; then ok "3b. bead released from the Pilot lane (in-flight/reviewing/dispatched stripped, assignee cleared)"; else bad "3b. bead lane labels not stripped: $CALLS"; fi
  if has "$CALLS" "ga-5w2gpw" && has "$CALLS" "$((LINE_DEF + 1)) lines" && has "$CALLS" "$LINE_DEF lines" && has "$CALLS" "$BYTE_DEF bytes"; then ok "3b. the bead comment names the ticket, the diff size and BOTH ceilings"; else bad "3b. bead comment lacks ticket/size/ceilings: $CALLS"; fi
  if has "$CALLS" "NH-CLAUSE[armed]"; then ok "3b. the comment carries the verified needs-human clause"; else bad "3b. the needs-human clause is missing from the comments"; fi
  if has "$CALLS" "split"; then ok "3b. the builder is told what to do (split the branch)"; else bad "3b. no instruction to split the branch"; fi
  if has "$CALLS" "mail send mayor" && has "$CALLS" "mail send crew/author"; then ok "3b. Mayor AND the author are mailed"; else bad "3b. mail missing (mayor/author): $CALLS"; fi
  if has "$QGLINE" "dispatcher_park_diff_too_large" && has "$QGLINE" "bead-1"; then ok "3b. a dispatcher_park_diff_too_large event is logged"; else bad "3b. no park event in the QG log: '$QGLINE'"; fi
  # Assert on the CALLS (a bd label write / a bd create), not on prose: the park's own comments legitimately say "no fix attempt".
  # grep -c (no early exit) rather than grep -q: under pipefail a SIGPIPE on the printf would turn a match into a miss.
  N_FIXLBL="$(printf '%s\n' "$CALLS" | grep -c -E '^bd\|.* label (add|remove) [^ ]+ gate:(needs-fix|fix-attempt|failed)')"
  N_CREATE="$(printf '%s\n' "$CALLS" | grep -c -E '^bd\|.* create ')"
  if [ "$N_FIXLBL" = "0" ] && [ "$N_CREATE" = "0" ]; then ok "3b. no fix attempt consumed (no gate:needs-fix / fix-attempt / failed label write) and no gate-run bead created — nothing was reviewed, nothing judged"; else bad "3b. the park wrote a fix-state label ($N_FIXLBL) or created a bead ($N_CREATE): $CALLS"; fi
  # the same check must be able to FAIL: a synthetic call log with a needs-fix write is counted
  N_SYN="$(printf '%s\n' 'bd|-C bead-city label add bead-1 gate:needs-fix -q' | grep -c -E '^bd\|.* label (add|remove) [^ ]+ gate:(needs-fix|fix-attempt|failed)')"
  if [ "$N_SYN" = "1" ]; then ok "3b. (the fix-state matcher does detect a needs-fix write — it is not vacuous)"; else bad "3b. the fix-state matcher missed a synthetic needs-fix write"; fi

  # 3c. bytes alone park it: few lines, very wide
  run_block 100 "$((BYTE_DEF / 100 + 50))" 2
  if ! reached && has "$CALLS" "set_gate_status|m-1 error"; then ok "3c. 100 lines but over the byte ceiling: parked"; else bad "3c. a byte-heavy diff was not parked (rc=$RC): $(printf '%s' "$CALLS" | head -3 | tr '\n' ' ')"; fi
  # exactly at the byte ceiling is whole (each line is W+1 bytes with its newline; 100 lines x (BYTE_DEF/100) = BYTE_DEF)
  if [ "$((BYTE_DEF % 100))" = "0" ]; then
    run_block 100 "$((BYTE_DEF / 100 - 1))" 2
    if reached && has "$OUT" "COVERAGE=full"; then ok "3c. exactly at the byte ceiling is whole"; else bad "3c. a diff of exactly $BYTE_DEF bytes was not whole: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"; fi
  fi

  # 3d. an unreadable diff (git fails) is the third state: unchanged, it is not parked here (that limit belongs to a separate bead)
  run_block 10 30 2 SC_GITFAIL=1
  if reached && has "$OUT" "COVERAGE=unknown" && ! has "$CALLS" "set_gate_status"; then ok "3d. a failing git read is coverage=unknown and is NOT parked by this change (unchanged behaviour)"; else bad "3d. unknown coverage handled differently: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"; fi

  # 3e. a needs-human write that did not verify still parks, and says so
  run_block "$((LINE_DEF + 1))" 30 3 SC_NH_STATUS=failed
  if ! reached && has "$CALLS" "NH-CLAUSE[failed]" && has "$CALLS" "set_gate_status|m-1 error"; then ok "3e. needs-human write failed: still parked at error, and the comments say the breaker is NOT armed"; else bad "3e. failed needs-human write not handled: $(printf '%s' "$CALLS" | head -3 | tr '\n' ' ')"; fi

  # 3f. no author / no bead id: still parks, never crashes under set -e
  run_block "$((LINE_DEF + 1))" 30 3 SC_AUTHOR=
  if ! reached && [ "$RC" = "0" ] && has "$CALLS" "mail send mayor" && ! has "$CALLS" "mail send crew/"; then ok "3f. no author: parked, Mayor mailed, nobody else addressed"; else bad "3f. no-author case wrong (rc=$RC): $(printf '%s' "$CALLS" | head -3 | tr '\n' ' ')"; fi
  run_block "$((LINE_DEF + 1))" 30 3 SC_BEAD_ID=
  if ! reached && [ "$RC" = "0" ] && has "$CALLS" "set_gate_status|m-1 error" && ! has "$CALLS" "gate_apply_needs_human"; then ok "3f. no source bead id: marker still parked, no bead write attempted"; else bad "3f. no-bead case wrong (rc=$RC): $(printf '%s' "$CALLS" | head -3 | tr '\n' ' ')"; fi

  # 3g. MUTATION: without the park condition the harness must see the over-ceiling diff fall through
  sed 's/= "partial" \]/= "never-partial" ]/' "$TMP/block.sh" > "$TMP/block.mut.sh"
  if cmp -s "$TMP/block.sh" "$TMP/block.mut.sh"; then
    bad "3g. mutation did not apply (the park condition no longer reads = \"partial\" ]) — the harness cannot prove it detects a missing park"
  else
    cp "$TMP/block.sh" "$TMP/block.orig.sh"; cp "$TMP/block.mut.sh" "$TMP/block.sh"
    run_block "$((LINE_DEF + 1))" 30 3
    if reached; then ok "3g. mutation check: with the park condition removed the over-ceiling diff FALLS THROUGH — the 3b assertions are not vacuous"; else bad "3g. mutated block still parked — the harness cannot tell a park from no park"; fi
    cp "$TMP/block.orig.sh" "$TMP/block.sh"
  fi
fi

# ── 4. wiring in the real file ───────────────────────────────────────────────────────────────────────────
echo "── 4. wiring: the diff is built once, before the gate-run exists ──"
L_PARK="$(grep -n '^# SELFTEST-EXTRACT gate-diff-park: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)"
L_RUN="$(grep -n '^GATE_RUN_ID=\$(bd -C "\$GC_CITY" create' "$DISPATCHER" | head -1 | cut -d: -f1)"
# The guard runs twice (Step 4b-1, the primary check, long before; Step 5b, the safety net, right before Step 6). Step 5c must
# follow the LAST one before the gate-run is created — a yielded marker should never pay for a diff it will not review.
L_SIB="$(grep -n 'live_sibling_run_for_branch "\$BRANCH" "\$RIG" "\$BRANCH_SHA"' "$DISPATCHER" | awk -F: -v r="${L_RUN:-0}" '$1 < r { l = $1 } END { print l }')"
if [ -n "$L_SIB" ] && [ -n "$L_PARK" ] && [ -n "$L_RUN" ] && [ "$L_SIB" -lt "$L_PARK" ] && [ "$L_PARK" -lt "$L_RUN" ]; then
  ok "4a. Step 5c sits after the live-sibling guard ($L_SIB) and before the gate-run bead is created ($L_PARK < $L_RUN): a parked run leaves no orphan gate-run"
else
  bad "4a. ordering wrong or anchors missing: sibling-guard=${L_SIB:-none} park-block=${L_PARK:-none} gate-run-create=${L_RUN:-none}"
fi
N_CALLS="$(grep -c '^gate_build_diff_payload ' "$DISPATCHER")"
if [ "$N_CALLS" = "1" ]; then ok "4b. exactly one gate_build_diff_payload call site in the dispatcher (the park decision and the reviewers' payload cannot diverge)"; else bad "4b. $N_CALLS gate_build_diff_payload call sites (expected exactly 1)"; fi
L_CALL="$(grep -n '^gate_build_diff_payload ' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$L_CALL" ] && [ -n "$L_RUN" ] && [ "$L_CALL" -lt "$L_RUN" ]; then ok "4b. that one call precedes the gate-run bead"; else bad "4b. the payload is still built after the gate-run bead (call=${L_CALL:-none} run=${L_RUN:-none})"; fi
# nothing may render a reviewer task from a payload built for a DIFFERENT purpose: the reviewers still get DIFF_HEADER/DIFF_FULL
if grep -q '"\$DIFF_HEADER" "\$DIFF_FULL"' "$DISPATCHER"; then ok "4c. the reviewer task is still rendered from the same DIFF_HEADER/DIFF_FULL"; else bad "4c. the reviewer task no longer consumes DIFF_HEADER/DIFF_FULL"; fi

echo
echo "== gate-e6d: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
