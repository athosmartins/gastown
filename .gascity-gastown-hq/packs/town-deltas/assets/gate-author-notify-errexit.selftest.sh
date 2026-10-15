#!/usr/bin/env bash
# gate-author-notify-errexit.selftest.sh (ga-4n5ktn)
#
# Proves EVERY call of notify_author_with_fallback / nudge_author_with_fallback in
# quality-gate-dispatcher.sh survives the helper's `return 1` under `set -e`.
#
# Why this exists: both helpers return 1 when no author candidate could be reached
# (they have ALREADY mailed the Mayor and left a bd comment by then — "the caller
# needs no further fallback of its own"). The dispatcher runs under
# `set -euo pipefail`, so a bare call turns that routine, already-handled outcome
# into the death of the shell that made it. 2026-10-13 16:51Z that shell was the
# async post-merge tail of wa-smp3gh (daemon-hold: postmerge-verify, reap-wrapper
# and notify never ran); before the tail was async, the same call killed the whole
# sweep (2026-10-11 15:54 wa-xf730y.2, 2026-10-10 09:45 ga-m9x0lb.2.2). The 3 nudge
# sites were guarded by ga-o2caab (selftest gate-dispatcher-author-nudge-fallback);
# the 6 mail sites never were.
#
# Strategy — the CLASS, not the 6 known lines: awk walks the dispatcher and cuts out
# every statement that STARTS with a helper call (backslash continuations joined),
# so a seventh call site added next month is covered without anyone registering it.
# Each statement is run VERBATIM in its own `bash -e` with both helpers stubbed to
# `return 1`; the run counts as safe only if a marker printed AFTER the statement is
# reached ("exit 0" alone would also be true for a snippet that exits early).
# `-u` is left off on purpose: the statements reference ~15 dispatcher variables and
# an unset one would abort the snippet for a reason unrelated to the defect.
#
# Three guards keep this from passing by accident:
#   - harness sanity: a bare helper call MUST abort here (else the harness is blind);
#   - mutation: every guarded statement, with its `|| …` tail cut, MUST abort;
#   - coverage: the number of statements found must equal the number of non-comment,
#     non-definition lines that mention a helper. A call in a form this scan does not
#     cut out (`if helper …`, inside `$(…)`) fails the count instead of being skipped
#     — "not found" must never read the same as "found and safe".
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-author-notify-errexit.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ga-4n5ktn.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT

# ── cut out every call statement ─────────────────────────────────────────────
# A statement starts at a line whose first token is a helper name followed by
# whitespace (a definition is `name() {`, a comment starts with `#`, so neither
# matches) and runs until a line that does not end in a backslash.
# index: "<n> <first line number> <helper>" per statement; stmt.<n> holds its text.
awk -v out="$TMPD" '
  !in_stmt && match($0, /^[[:space:]]*(notify|nudge)_author_with_fallback[[:space:]]/) {
    in_stmt = 1; n++; file = out "/stmt." n; start = NR
    name = ($0 ~ /notify_author_with_fallback/) ? "notify_author_with_fallback" : "nudge_author_with_fallback"
  }
  in_stmt {
    print $0 > file
    if ($0 !~ /\\[[:space:]]*$/) {
      close(file); in_stmt = 0
      print n, start, name >> (out "/index")
    }
  }
  END { if (in_stmt) { print "FATAL: statement starting at line " start " never terminated" > "/dev/stderr"; exit 3 } }
' "$DISPATCHER" || { echo "FATAL: could not cut call statements out of $DISPATCHER" >&2; exit 2; }

[ -s "$TMPD/index" ] || { echo "FATAL: no helper call statement found in $DISPATCHER — the scan is blind, not the dispatcher clean" >&2; exit 2; }
N_STMT="$(wc -l < "$TMPD/index" | tr -d ' ')"

# ── runs one snippet in a real nested `bash -e` ──────────────────────────────
# Both helpers return 1 (total failure — the routine "author unreachable" outcome).
safe_under_errexit() {
  local snippet="$1" out rc
  out="$(printf '%s\n' \
    'notify_author_with_fallback() { return 1; }' \
    'nudge_author_with_fallback() { return 1; }' \
    'gate_needs_human_clause() { printf "needs-human clause"; }' \
    'NOTIFY_AUTHOR="batista"; BEAD_ID="wa-smp3gh"; AUTHOR="some-author"' \
    'BRANCH="crew/batista/wa-smp3gh"; BRANCH_SHA="abc123"; FAIL_REASONS="reason"' \
    'GATE_RUN_ID="gr1"; NEW_ATTEMPT=1; GATE_FIX_CAP=3; RIG="wa"; DEFAULT_BRANCH="main"' \
    '_NH_STATUS="armed"; _NH_MAIL_SUBJ="subject"' \
    'GATE_LXZ5W_SIB_BRANCH="sib"; GATE_LXZ5W_SIB_STATUS="running"' \
    'MERGE_SHA="def456"; SCOPE_HOLD_WEAK_SIGNAL_NOTE="n"; PARTIAL_EVIDENCE="e"; SCOPE_HOLD_ALWAYS_CHECK="c"' \
    'DAEMON_HOLD_VERDICT="v"; DAEMON_HOLD_REASON="r"; DAEMON_HOLD_ACTION="a"' \
    "$snippet" \
    'echo MARKER_REACHED' \
    | bash -eo pipefail 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep "MARKER_REACHED" >/dev/null
}

# ── S0: harness sanity — a bare call must abort, else nothing below proves anything ──
echo "S0: harness sanity — a BARE helper call aborts under set -e"
if safe_under_errexit 'notify_author_with_fallback a b c d e f'; then
  bad "a bare helper call survived — the harness cannot see the defect, every result below is meaningless"
else
  ok "a bare helper call aborts, so the harness can tell guarded from unguarded"
fi

# ── S1: every call statement survives total failure ──────────────────────────
echo "S1: each of the $N_STMT helper call statements survives the helper returning 1 under set -e"
UNGUARDED_COUNT=0
while read -r n line helper; do
  stmt="$(cat "$TMPD/stmt.$n")"
  if safe_under_errexit "$stmt"; then
    ok "line $line ($helper) ran to completion with every candidate failing"
  else
    bad "line $line ($helper) ABORTED under set -e when the helper returned 1 — the shell that made the call dies (ga-4n5ktn)"
    UNGUARDED_COUNT=$((UNGUARDED_COUNT+1))
  fi
done < "$TMPD/index"

# ── S2: mutation — cut the guard, the statement must abort ───────────────────
# Proves each S1 result is sensitive to the guard and not satisfied by something
# else in the snippet. Only statements that carry a `|| …` tail on the last line.
echo "S2 (mutation): with its '|| …' guard cut, each guarded statement must abort"
while read -r n line helper; do
  last="$(sed -n '$p' "$TMPD/stmt.$n")"
  case "$last" in
    *"||"*) ;;
    *) continue ;;
  esac
  mutated="$(sed '$d' "$TMPD/stmt.$n"; printf '%s\n' "$last" | sed 's/[[:space:]]*||.*$//')"
  if safe_under_errexit "$mutated"; then
    bad "line $line ($helper) with its guard cut still survived — S1 would not catch this site regressing"
  else
    ok "line $line ($helper) aborts once its guard is cut — the S1 result is real"
  fi
done < "$TMPD/index"

# ── S3: coverage — every mention is a statement this scan cut out ────────────
echo "S3: every non-comment, non-definition mention of a helper is one of the $N_STMT statements cut out"
N_MENTIONS="$(grep -E '(notify|nudge)_author_with_fallback' "$DISPATCHER" \
  | grep -vE '^[[:space:]]*#' \
  | grep -vE '^(notify|nudge)_author_with_fallback\(\)' \
  | wc -l | tr -d ' ')"
if [ "$N_MENTIONS" -eq "$N_STMT" ]; then
  ok "$N_MENTIONS mention(s) == $N_STMT statement(s): no call form escapes the scan"
else
  bad "$N_MENTIONS mention(s) but $N_STMT statement(s): a call in a form this scan does not cut out (e.g. 'if helper …', or inside \$(…)) — guard it explicitly and teach the scan about it"
fi

echo ""; echo "gate-author-notify-errexit.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
