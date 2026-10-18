#!/usr/bin/env bash
# gate-render-reasons.selftest.sh (ga-lxm9se)
#
# BUG. A reviewer's comment that quoted the regex `\b` reached the Mayor's "Gate needs-human: <bead> exhausted N fix attempts" mail
# as a RAW 0x08 byte (ga-wisp-28dtr0, ga-wisp-glliyp). The dispatcher rendered FAIL_REASONS with `echo -e`, which expands every
# backslash sequence in the text, not only the dispatcher's own `\n`: `\b` is BS, `\c` cuts the text, `\x1b` is ESC. A control byte
# inside a JSON string is invalid JSON for `jq` (1.8) and python's json, which refuse the whole document. bd 1.1.0 escapes it when
# it prints, so the reader failure ga-lxm9se reported was not reproduced on those two wisps; the byte was wrong text in a mail.
#
# What is executed, not described:
#   1. the premise: `echo -e` on this machine turns those sequences into control bytes / truncates (so the test is about something real);
#   2. gate_render_reasons: `\b \c \d \x1b \t \0` stay as written, `\n` is a line break, `\\` is one backslash, raw control bytes
#      other than tab/CR/LF are dropped, multibyte text is untouched, one trailing newline like `echo -e`;
#   3. gate_reasons_escape + gate_render_reasons round-trip another person's words exactly (a `\n` in a code sample stays two characters);
#   4. gate_suite_tail: ANSI colour and backspace progress bars in a suite log do not reach the mail body;
#   5. drift guards on the dispatcher text: no `echo -e` left on a code line, both reviewer-comment producers escape the comment,
#      every FAIL_REASONS / INTEGRITY_MSG consumer that prints it goes through gate_render_reasons.
#
# GATE_DISPATCHER_UNDER_TEST=<file> points this at another copy. Against a copy from before the fix the functions are missing; the
# test then runs its assertions against the OLD behaviour (echo -e, no escaping) so they go red on the defect itself.
# Exit 0 iff every assertion holds. Needs bash 3.2+.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${GATE_DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2)
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected $(printf '%q' "$3"), got $(printf '%q' "$2")"; fi; }
# has_byte <two-hex-digits> <text>: is that byte in the text (compared as whole bytes, never across two of them)
has_byte() { printf ' %s ' "$(printf '%s' "$2" | LC_ALL=C od -An -v -tx1 | tr '\n' ' ')" | grep -q " $1 "; }
no_byte()  { if has_byte "$2" "$3"; then bad "$1: byte 0x$2 is in the output: $(printf '%q' "$3")"; else ok "$1"; fi; }

echo "== gate-render-reasons.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^\}/ {exit}' "$1"; }
LEGACY=0
for fn in gate_render_reasons gate_reasons_escape gate_suite_tail; do
  body="$(extract_fn "$DISPATCHER" "$fn")"
  if [ -n "$body" ]; then eval "$body"
  else
    bad "$fn is not defined in $DISPATCHER (running the rest against the old behaviour)"; LEGACY=1
    case "$fn" in
      gate_render_reasons) gate_render_reasons() { echo -e "${1-}"; } ;;
      gate_reasons_escape) gate_reasons_escape() { printf '%s' "${1-}"; } ;;
      gate_suite_tail)     gate_suite_tail()     { tail -60 "${1:-/dev/null}" 2>/dev/null; } ;;
    esac
  fi
done

echo "== 1. the premise: echo -e rewrites someone else's backslashes"
old=$($B32 -c 'echo -e "$1"' _ 'regex \bfoo\b')
if has_byte 08 "$old"; then ok "echo -e turns the quoted regex \\b into a raw 0x08"; else bad "premise: echo -e did not produce 0x08 here ($(printf '%q' "$old")) — the test is not about the real defect on this machine"; fi
old=$($B32 -c 'echo -e "$1"' _ 'before \c after')
eq "echo -e cuts the text at \\c" "$old" "before "
old=$($B32 -c 'echo -e "$1"' _ 'color \x1b[0m')
if has_byte 1b "$old"; then ok "echo -e turns \\x1b into a raw ESC"; else bad "premise: echo -e did not produce ESC ($(printf '%q' "$old"))"; fi

echo "== 2. gate_render_reasons"
BS=$'\x08'; ESC=$'\x1b'; BEL=$'\x07'; TAB=$'\t'; CR=$'\r'; NL=$'\n'
r=$(gate_render_reasons 'regex \bfoo\b and \d+')
eq "a quoted regex comes back as written" "$r" 'regex \bfoo\b and \d+'
no_byte "no 0x08 for \\b" 08 "$r"
eq "\\c does not cut the text" "$(gate_render_reasons 'before \c after')" 'before \c after'
r=$(gate_render_reasons 'color \x1b[0m and \033[1m')
eq "\\x1b and \\033 stay as written" "$r" 'color \x1b[0m and \033[1m'
no_byte "no ESC for \\x1b" 1b "$r"
eq "\\t, \\r and \\f are not control bytes either" "$(gate_render_reasons 'C:\tmp\run\file')" 'C:\tmp\run\file'
eq "unescaped, a \\n IS the dispatcher's line break (that is what gate_reasons_escape is for)" "$(gate_render_reasons 'C:\new')" "C:${NL}ew"
eq "\\0 and \\a stay as written" "$(gate_render_reasons 'nul \0 bell \a')" 'nul \0 bell \a'
eq "the dispatcher's own \\n is a line break" "$(gate_render_reasons 'one\ntwo')" "one${NL}two"
eq "\\\\ is one backslash" "$(gate_render_reasons 'a\\b')" 'a\b'
eq "\\\\n is a backslash and an n, not a line break" "$(gate_render_reasons 'a\\nb')" 'a\nb'
eq "four backslashes are two" "$(gate_render_reasons '\\\\')" '\\'
eq "a trailing lone backslash stays" "$(gate_render_reasons 'abc\')" 'abc\'
eq "empty text renders as empty" "$(gate_render_reasons '')" ""
eq "a raw BS, ESC and BEL are dropped" "$(gate_render_reasons "a${BS}b${ESC}[31mc${BEL}d")" 'ab[31mcd'
eq "tab and CR survive" "$(gate_render_reasons "a${TAB}b${CR}c")" "a${TAB}b${CR}c"
eq "real line breaks survive" "$(gate_render_reasons "a${NL}b")" "a${NL}b"
eq "multibyte text is untouched" "$(gate_render_reasons 'ação — ü 日本')" 'ação — ü 日本'
eq "one trailing newline, as echo -e gave" "$(gate_render_reasons 'abc'; echo END)" "abc${NL}END"
eq "the dispatcher's trailing \\n gives a blank line, as before" "$(gate_render_reasons 'Reviewer 1 FAIL: x\n'; echo END)" "Reviewer 1 FAIL: x${NL}${NL}END"
# the pipelines the dispatcher puts it in
eq "| head -1 | tr | cut (the dispatcher_complete reason)" "$(gate_render_reasons 'first \bline\nsecond' | head -1 | tr '\n' ' ' | cut -c1-200)" 'first \bline '
eq "| head -3 keeps three lines" "$(gate_render_reasons 'a\nb\nc\nd\ne' | head -3 | tr '\n' ',')" 'a,b,c,'
if [ "$LEGACY" = 0 ]; then
  r=$(bash -c 'LC_ALL=en_US.UTF-8; '"$(extract_fn "$DISPATCHER" gate_render_reasons)"'; gate_render_reasons "$1"' _ 'ação \b' 2>&1)
  eq "same under a UTF-8 locale" "$r" 'ação \b'
  r=$($B32 -c "$(extract_fn "$DISPATCHER" gate_render_reasons)"'; gate_render_reasons "$1"' _ 'x \b y\nz' 2>&1)
  eq "same under /bin/bash 3.2" "$r" "x \\b y${NL}z"
fi

echo "== 3. gate_reasons_escape + gate_render_reasons: someone else's words, back exactly as written"
roundtrip() {  # roundtrip <label> <their words>
  local reasons rendered
  reasons="Reviewer 1 FAIL: $(gate_reasons_escape "$2")\n"
  rendered=$(gate_render_reasons "$reasons")
  eq "round trip: $1" "$rendered" "Reviewer 1 FAIL: $2"
}
roundtrip "the regex that started it" 'the pattern \bword\b misses \d+'
roundtrip "a \\n inside a code sample" 'printf "a\nb" prints two lines'
roundtrip "an escaped backslash in a code sample" 'path = "C:\\temp\\new"'
roundtrip "a Windows path (\\n and \\t in it)" 'C:\new\tab'
roundtrip "a trailing backslash" 'ends with a backslash \'
roundtrip "ANSI escape written out" 'saw \x1b[31m in the output'
roundtrip "\\c" 'echo -e "stop here\c" cuts'
roundtrip "a multi-line comment" "line one \\b${NL}line two \\n kept${NL}line three"
roundtrip "plain text" 'nothing special here'
eq "the escape alone doubles each backslash" "$(gate_reasons_escape 'a\b\\c')" 'a\\b\\\\c'
eq "the escape of nothing is nothing" "$(gate_reasons_escape '')" ""
# the dispatcher's own \n between two reviewers still breaks the line
r=$(gate_render_reasons "Reviewer 1 FAIL: $(gate_reasons_escape 'a \b')\nReviewer 2 FAIL: $(gate_reasons_escape 'b \n c')\n")
eq "two reviewers: own line breaks kept, their backslashes kept" "$r" "Reviewer 1 FAIL: a \\b${NL}Reviewer 2 FAIL: b \\n c"
no_byte "and nothing in it is a control byte" 08 "$r"

echo "== 4. gate_suite_tail: a suite log's colour codes and progress bars"
LOG="$(mktemp "${TMPDIR:-/tmp}/gate-render-reasons-log.XXXXXX")"; trap 'rm -f "$LOG"' EXIT
{ printf 'plain line\n'; printf '\033[31mFAIL\033[0m test_x\n'; printf 'progress 10%%\b\b\b20%%\n'; printf 'tab\there\n'; } > "$LOG"
r=$(gate_suite_tail "$LOG")
no_byte "no ESC from the colour codes" 1b "$r"
no_byte "no BS from the progress bar" 08 "$r"
case "$r" in *"[31mFAIL"*"[0m test_x"*) ok "the words around the codes are kept" ;; *) bad "the words around the codes were lost: $(printf '%q' "$r")" ;; esac
case "$r" in *"tab${TAB}here"*) ok "a tab is kept" ;; *) bad "a tab was lost: $(printf '%q' "$r")" ;; esac
seq 1 100 > "$LOG"
eq "only the last 60 lines" "$(gate_suite_tail "$LOG" | head -1)" "41"
eq "a log that cannot be read is empty, not an error" "$(gate_suite_tail /nonexistent/log; echo rc=$?)" "rc=0"

echo "== 5. drift guards on the dispatcher text"
n=$(grep -cE '^[^#]*echo -e' "$DISPATCHER" || true)
eq "no echo -e on a code line (a comment may name it)" "$n" "0"
n=$(grep -cE 'FAIL_REASONS="\$\{FAIL_REASONS\}Reviewer .*FAIL: \$\(gate_reasons_escape "\$FAIL_COMMENT"\)\\n"' "$DISPATCHER" || true)
eq "both reviewer-comment producers escape the comment" "$n" "2"
n=$(grep -cE 'FAIL: \$FAIL_COMMENT|FAIL: \$\{FAIL_COMMENT' "$DISPATCHER" || true)
eq "and none appends it bare" "$n" "0"
n=$(grep -cE 'INTEGRITY_MSG=.*File \$f:' "$DISPATCHER" || true)
eq "the integrity message escapes the file name" "$n" "0"
n="$(grep -c 'gate_render_reasons "\$FAIL_REASONS"\|gate_render_reasons "\$INTEGRITY_MSG"' "$DISPATCHER")"
if [ "$n" -ge 8 ]; then ok "the 8 sites that used echo -e now call gate_render_reasons ($n)"; else bad "expected at least 8 gate_render_reasons call sites, found $n"; fi
if grep -q 'gate_suite_tail "\$branch_log"' "$DISPATCHER"; then ok "the full-suite detail takes its tail through gate_suite_tail"; else bad "the full-suite detail still takes a raw tail -60"; fi

echo
echo "gate-render-reasons.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
