#!/usr/bin/env bash
# plist-comment-lint.selftest.sh — regression harness for plist-comment-lint.py (ga-taa25c).
#
# The lint refuses a plist that Python's plist reader cannot parse. The bug class it exists for: a double
# hyphen inside an XML comment (launchd loads it, plutil -lint says OK, plistlib rejects the whole file and
# the WA pre-push lint goes blind to that daemon). Fixtures live in a temp dir; the one scenario that touches
# the real tree (S12) is the standing guard that no tracked plist source carries the defect.
#
# Scenarios:
#   S1  clean plist, flags only OUTSIDE comments (ProgramArguments has a double-hyphen string) -> 0  (false-positive guard)
#   S2  double hyphen inside a comment                    -> 1, names the file and the LINE of the comment text (5)
#   S3  two occurrences in one comment                    -> 1, both lines reported
#   S4  comment that ends in '-' (closes with '--->')     -> 1
#   S5  plain malformed XML (no comment involved)         -> 1, no comment hint invented
#   S6  empty (0-byte) file                               -> 1, an empty file is not "clean"
#   S7  one bad + one clean                               -> 1, only the bad one is named
#   S8  explicit path that does not exist                 -> 2, never "0 fail"
#   S9  bad + missing in the same run                     -> 1 (a finding wins), and the missing one is reported too
#   S10 discovery root with zero tracked plists           -> 2, zero files is not "clean"
#   S11 discovery root that is not a git repo             -> 2
#   S12 the real tree (no args)                           -> 0  (every tracked plist source parses)
#   S13 a comment with ONE hyphen and a hyphenated word   -> 0  (the rule is two in a row, not one)
#
# Exit 0 iff every scenario behaves as expected.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/plist-comment-lint.py"
PY=(python3 -I)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run <args...>: sets RC, OUT (stdout) and ERR (stderr) of one lint run.
run() {
  OUT="$("${PY[@]}" "$LINT" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
# expect <rc> <label>: RC must equal <rc>.
expect_rc() {
  if [ "$RC" = "$1" ]; then ok "$2 (rc=$RC)"; else bad "$2: want rc=$1, got rc=$RC" "stdout: $OUT | stderr: $ERR"; fi
}

# mk <path> <comment text> [extra program argument]: a well-formed plist around the given comment body.
mk() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.fixture</string>
  <!-- $2 -->
  <key>ProgramArguments</key>
  <array>
    <string>/bin/echo</string>
    <string>${3:-hello}</string>
  </array>
</dict>
</plist>
PLIST
}

echo "S1: clean plist; a double-hyphen string outside any comment must NOT trip it"
mk "$TMP/s1.plist" "plain comment, nothing special" "--dry-run"
run "$TMP/s1.plist"; expect_rc 0 "clean plist with a flag in a <string>"

echo "S2: double hyphen inside a comment"
mk "$TMP/s2.plist" "run it with --dry-run first"
run "$TMP/s2.plist"; expect_rc 1 "double hyphen in a comment is refused"
if printf '%s' "$OUT" | grep -q "s2.plist" && printf '%s' "$OUT" | grep -q "line 5:.*--dry-run"; then
  ok "the message names the file and line 5 (where mk puts the comment)"
else
  bad "message should name s2.plist and 'line 5' with the offending text" "$OUT"
fi

echo "S3: two occurrences in one comment"
cat > "$TMP/s3.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.s3</string>
  <!-- first line is fine
       second has --one
       third has --two -->
</dict>
</plist>
PLIST
run "$TMP/s3.plist"; expect_rc 1 "two occurrences are refused"
if printf '%s' "$OUT" | grep -q "line 6:.*--one" && printf '%s' "$OUT" | grep -q "line 7:.*--two"; then
  ok "both lines (6 and 7) are reported"
else
  bad "expected line 6 and line 7 to be reported" "$OUT"
fi

echo "S4: comment ending in a hyphen closes with '--->'"
cat > "$TMP/s4.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.s4</string>
  <!-- ends badly --->
</dict>
</plist>
PLIST
run "$TMP/s4.plist"; expect_rc 1 "'--->' is refused"
printf '%s' "$OUT" | grep -q "line 5:" && ok "the closing line (5) is located" || bad "expected line 5 to be located" "$OUT"

echo "S5: malformed XML with no comment involved"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key></plist>\n' > "$TMP/s5.plist"
run "$TMP/s5.plist"; expect_rc 1 "unclosed tag is refused"
if printf '%s' "$OUT" | grep -q "double hyphen inside an XML comment"; then
  bad "no comment is involved, the message must not blame one" "$OUT"
else
  ok "no comment hint invented"
fi

echo "S6: empty file"
: > "$TMP/s6.plist"
run "$TMP/s6.plist"; expect_rc 1 "a 0-byte file is not clean"

echo "S7: one bad + one clean"
mk "$TMP/s7-good.plist" "fine"
mk "$TMP/s7-bad.plist" "bad --thing here"
run "$TMP/s7-good.plist" "$TMP/s7-bad.plist"; expect_rc 1 "the bad one decides the exit"
if printf '%s' "$OUT" | grep -q "s7-bad.plist" && ! printf '%s' "$OUT" | grep -q "FAIL.*s7-good.plist"; then
  ok "only the bad file is named FAIL"
else
  bad "s7-bad.plist must be FAIL and s7-good.plist must not" "$OUT"
fi

echo "S8: explicit path that does not exist"
run "$TMP/does-not-exist.plist"; expect_rc 2 "a missing file is undecided, not clean"
printf '%s' "$ERR" | grep -q "UNREADABLE" && ok "reported as UNREADABLE on stderr" || bad "expected an UNREADABLE line on stderr" "$ERR"

echo "S9: bad + missing in the same run"
run "$TMP/s7-bad.plist" "$TMP/does-not-exist.plist"; expect_rc 1 "a finding wins over undecided"
printf '%s' "$ERR" | grep -q "UNREADABLE" && ok "the missing file is still reported" || bad "expected the missing file reported too" "$ERR"

echo "S10: discovery root with zero tracked plists"
EMPTY="$TMP/empty-repo"; mkdir -p "$EMPTY"
git -C "$EMPTY" init -q 2>/dev/null
OUT="$(PLIST_LINT_ROOT="$EMPTY" "${PY[@]}" "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "zero tracked plists is not clean"

echo "S11: discovery root that is not a git repo"
NOGIT="$TMP/not-a-repo"; mkdir -p "$NOGIT"
OUT="$(GIT_CEILING_DIRECTORIES="$TMP" PLIST_LINT_ROOT="$NOGIT" "${PY[@]}" "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "git failing is not clean"

echo "S12: the real tree (every tracked plist source must parse)"
run
expect_rc 0 "no tracked plist source carries the defect"
[ "$RC" = 0 ] || printf '%s\n' "$OUT"

echo "S13: one hyphen / hyphenated words in a comment are fine"
mk "$TMP/s13.plist" "pip-unpack-* dirs, a - b, and ~/.local/bin are all fine"
run "$TMP/s13.plist"; expect_rc 0 "single hyphens are not the defect"

echo
echo "plist-comment-lint.selftest: $PASS ok, $FAIL bad"
[ "$FAIL" -eq 0 ]
