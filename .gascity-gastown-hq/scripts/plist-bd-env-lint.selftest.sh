#!/usr/bin/env bash
# plist-bd-env-lint.selftest.sh — regression harness for plist-bd-env-lint.py (ga-d3ryi7k).
#
# The lint refuses a launchd plist that does not set EnvironmentVariables.BEADS_DOLT_AUTO_START to the string "0",
# and its --fix inserts the missing key without touching anything else. The bug class: at the 23/11 23:41 reboot a
# `bd` started by launchd (no such variable in its plist) started a local decoy Dolt for three rigs, every read of
# those rigs answered "database not found", and the Pilot counted its lanes as full for ~12 h. Fixtures live in a
# temp dir; S20 and S27 touch the real tree: the standing guard that no tracked plist source lacks the variable,
# and that the fixer reproduces every real plist from its stripped form.
#
# Check scenarios:
#   S1  compliant plist (one-line style)                                -> 0
#   S2  no EnvironmentVariables at all                                  -> 1, names the file and says why
#   S3  EnvironmentVariables without the key                            -> 1
#   S4  key = "1"                                                       -> 1, the message quotes the value
#   S5  key = "" / "false" / " 0" / "00"                                -> 1 each (only the string "0" passes)
#   S6  the NAME only in an XML comment and in a ProgramArguments string -> 1 (a grep for the name would call it clean)
#   S7  the key at the top level of the plist, not inside EnvironmentVariables -> 1
#   S8  key = <integer>0</integer>                                      -> 1 (launchd env values are strings)
#   S9  malformed XML                                                   -> 2 (undecided; plist-comment-lint owns parse errors)
#   S10 explicit path that does not exist                               -> 2
#   S11 one finding + one missing file                                  -> 1 (a finding wins), the missing one is still reported
#   S12 explicit path under docs/launchd-archive/ or internal/templates/ -> skipped, 0, said out loud
#   S13 discovery root with zero tracked plists                         -> 2
#   S14 discovery root that is not a git repo                           -> 2
#   S15 git cannot start                                                -> 2
#   S16 discovery skips docs/launchd-archive/ and still judges the rest -> 1 for a bad live plist next to a bad archived one, only the live one named
# Fix scenarios:
#   S17 one-line style: exactly ONE line added, in the style of its neighbours, and the result passes
#   S18 two-line style with a comment (holding a literal </dict>) inside the dict: exactly TWO lines added at the end
#   S19 no EnvironmentVariables: a new block, 4-space style, and the result passes
#   S20 the real tree: no tracked live plist lacks the variable (rc 0)
#   S21 idempotent: a second --fix changes no byte
#   S22 key present with a wrong value: --fix refuses (rc 2) and leaves the file byte-identical
#   S23 CRLF file: the inserted lines use CRLF, no bare LF appears
#   S24 malformed and binary-format plists: untouched, rc 2
#   S25 file mode is preserved
#   S26 the parse result of the fixed file equals the original's plus the one key (semantic neutrality), on every fixture
#   S27 round trip over the real tree: strip the key from each tracked live plist, --fix it, get the original bytes back
#   S28 an EnvironmentVariables nested inside another dict: check says "none" (1), --fix refuses (2) and writes nothing
#   S29 a failure inside the lint (stdout that cannot print the name): 2 with "internal error", never the 1 that blocks a push
#   S30 a symlinked plist: --fix edits the target and the link stays a link
#   S31 EnvironmentVariables that is not a dict: 1 and it says so; --fix leaves it
#   S32 mixed one-line/two-line entries: the new pair copies the entry right above it
#   S33 two EnvironmentVariables keys: ambiguous, --fix leaves it to a human
#   S34 --fix leaves no temp file behind
#   S35 --installed: the copies of the tracked plists, by Label; a third-party plist in the same dir is neither read nor touched
#   S36 --installed with a FILE, or with nothing installed there: 2
#   S38 discovery where every tracked plist is archived: 2, zero judged is not clean
#   S37 --installed: a Label with a slash (it would leave the agents dir) is refused and nothing outside is touched; archived plists are not judged
# Every run also asserts there is no traceback on stderr.
#
# Exit 0 iff every scenario behaves as expected.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="${PLIST_BD_ENV_LINT:-$HERE/plist-bd-env-lint.py}"   # the override is for the mutation battery: it points the run at a mutant copy
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
  # an uncaught exception exits 1, the same code as "this plist lacks the variable": never let a crash pass as a finding
  case "$ERR" in *Traceback*) bad "the lint crashed (a traceback is not a verdict)" "$ERR" ;; esac
}
expect_rc() {
  if [ "$RC" = "$1" ]; then ok "$2 (rc=$RC)"; else bad "$2: want rc=$1, got rc=$RC" "stdout: $OUT | stderr: $ERR"; fi
}
# same_bytes <a> <b> <label>
same_bytes() {
  if cmp -s "$1" "$2"; then ok "$3"; else bad "$3: the files differ" "$(diff "$1" "$2" | head -8)"; fi
}

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────
# mk_one <path> [<extra env line>]: one-line style, like com.gascity.dolt-port-pin-guard.plist
mk_one() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.one</string>
  <key>ProgramArguments</key><array>
    <string>/bin/echo</string>
    <string>--dry-run</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin:/bin</string>
    <key>HOME</key><string>/Users/test</string>${2:-}
  </dict>
</dict></plist>
PLIST
}
# mk_two <path>: two-line style, a comment holding a literal closing tag inside the env dict
mk_two() {
  cat > "$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.two</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin</string>
    <!-- not the end of the dict: </dict> in a comment, and a second one </dict> -->
    <key>COOLDOWN_SEC</key>
    <string>10800</string>
  </dict>
</dict>
</plist>
PLIST
}
# mk_noenv <path>: no EnvironmentVariables, 4-space two-line style, like cloudflared-dns-reconcile.plist
mk_noenv() {
  cat > "$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.noenv</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>180</integer>
</dict>
</plist>
PLIST
}
# mk_val <path> <xml for the value>: env dict holding the key with the given value element
mk_val() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.val</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin</string>
    <key>BEADS_DOLT_AUTO_START</key>$2
  </dict>
</dict></plist>
PLIST
}

# ═════════════════════════ check ═════════════════════════
echo "S1: compliant plist"
mk_one "$TMP/s1.plist" '
    <key>BEADS_DOLT_AUTO_START</key><string>0</string>'
run "$TMP/s1.plist"; expect_rc 0 "BEADS_DOLT_AUTO_START=0 in EnvironmentVariables passes"

echo "S2: no EnvironmentVariables at all"
mk_noenv "$TMP/s2.plist"
run "$TMP/s2.plist"; expect_rc 1 "a plist with no environment is refused"
if printf '%s' "$OUT" | grep -q "FAIL.*s2.plist" && printf '%s' "$OUT" | grep -qi "no EnvironmentVariables"; then
  ok "the message names the file and says there is no EnvironmentVariables"
else
  bad "expected 'FAIL ...s2.plist' and 'no EnvironmentVariables'" "$OUT"
fi
if printf '%s' "$OUT" | grep -q -- "--fix" && printf '%s' "$OUT" | grep -q "bd-dolt-auto-start"; then
  ok "the message says how to fix it and where the why is written"
else
  bad "expected the --fix hint and the runbook name in the output" "$OUT"
fi

echo "S3: EnvironmentVariables without the key"
mk_one "$TMP/s3.plist"
run "$TMP/s3.plist"; expect_rc 1 "an environment without the key is refused"

echo "S4: key = 1"
mk_val "$TMP/s4.plist" '<string>1</string>'
run "$TMP/s4.plist"; expect_rc 1 "BEADS_DOLT_AUTO_START=1 is refused"
printf '%s' "$OUT" | grep -q "'1'" && ok "the message quotes the offending value" || bad "expected the value '1' quoted" "$OUT"

echo "S5: only the string 0 passes"
for v in '' 'false' ' 0' '00' 'FALSE' '0 '; do
  mk_val "$TMP/s5.plist" "<string>$v</string>"
  run "$TMP/s5.plist"; expect_rc 1 "value '$v' is refused"
done

echo "S6: the name only in a comment and in a ProgramArguments string"
cat > "$TMP/s6.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <!-- BEADS_DOLT_AUTO_START=0 is mentioned here but never set -->
  <key>Label</key><string>com.test.s6</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/env</string>
    <string>BEADS_DOLT_AUTO_START=0</string>
    <string>/bin/echo</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin</string>
  </dict>
</dict></plist>
PLIST
run "$TMP/s6.plist"; expect_rc 1 "a mention is not a setting (a grep would pass this file)"

echo "S7: the key at the top level, not inside EnvironmentVariables"
cat > "$TMP/s7.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.s7</string>
  <key>BEADS_DOLT_AUTO_START</key><string>0</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin</string>
  </dict>
</dict></plist>
PLIST
run "$TMP/s7.plist"; expect_rc 1 "launchd only reads the key inside EnvironmentVariables"

echo "S8: integer 0"
mk_val "$TMP/s8.plist" '<integer>0</integer>'
run "$TMP/s8.plist"; expect_rc 1 "<integer>0</integer> is refused"

echo "S9: malformed XML"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key></plist>\n' > "$TMP/s9.plist"
run "$TMP/s9.plist"; expect_rc 2 "a plist this lint cannot read is undecided, not clean and not a finding"
printf '%s' "$ERR" | grep -q "UNREADABLE" && ok "reported as UNREADABLE on stderr" || bad "expected UNREADABLE on stderr" "$ERR"

echo "S10: explicit path that does not exist"
run "$TMP/does-not-exist.plist"; expect_rc 2 "a missing file is undecided"

echo "S11: a finding and a missing file in one run"
run "$TMP/s2.plist" "$TMP/does-not-exist.plist"; expect_rc 1 "the finding wins"
printf '%s' "$ERR" | grep -q "UNREADABLE" && ok "the missing file is still reported" || bad "expected the missing file reported too" "$ERR"

echo "S12: archive and template paths are not live plists"
mkdir -p "$TMP/x/docs/launchd-archive/retired" "$TMP/x/internal/templates/launchd"
mk_noenv "$TMP/x/docs/launchd-archive/retired/old.plist"
mk_noenv "$TMP/x/internal/templates/launchd/tpl.plist"
run "$TMP/x/docs/launchd-archive/retired/old.plist" "$TMP/x/internal/templates/launchd/tpl.plist"
expect_rc 0 "archived and template plists are skipped"
printf '%s' "$OUT" | grep -qi "skip" && ok "the skip is said out loud" || bad "expected a 'skip' line" "$OUT"

echo "S13: discovery root with zero tracked plists"
EMPTY="$TMP/empty-repo"; mkdir -p "$EMPTY"; git -C "$EMPTY" init -q 2>/dev/null
OUT="$(PLIST_LINT_ROOT="$EMPTY" "${PY[@]}" "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "zero tracked plists is not clean"
printf '%s' "$ERR" | grep -q "no plist tracked under" && ok "and it says there is no tracked plist at all (not the all-archived message)" || bad "expected 'no plist tracked under'" "$ERR"

echo "S14: discovery root that is not a git repo"
NOGIT="$TMP/not-a-repo"; mkdir -p "$NOGIT"
OUT="$(GIT_CEILING_DIRECTORIES="$TMP" PLIST_LINT_ROOT="$NOGIT" "${PY[@]}" "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "git failing is not clean"

echo "S15: git cannot start"
NOGITBIN="$TMP/no-git-bin"; mkdir -p "$NOGITBIN"
PYABS="$(command -v python3)"
OUT="$(PATH="$NOGITBIN" PLIST_LINT_ROOT="$HERE/.." "$PYABS" -I "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "git missing is undecided"
printf '%s' "$ERR" | grep -q "cannot list the plists" && ok "reported on stderr, no traceback" || bad "expected 'cannot list the plists'" "$ERR"

echo "S16: discovery skips docs/launchd-archive/ and still judges the rest"
D="$TMP/disc"; mkdir -p "$D/scripts" "$D/docs/launchd-archive/retired"
git -C "$D" init -q 2>/dev/null
mk_noenv "$D/scripts/live-bad.plist"
mk_noenv "$D/docs/launchd-archive/retired/archived-bad.plist"
mk_one "$D/scripts/live-good.plist" '
    <key>BEADS_DOLT_AUTO_START</key><string>0</string>'
git -C "$D" add -A 2>/dev/null
OUT="$(PLIST_LINT_ROOT="$D" "${PY[@]}" "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 1 "the live bad plist decides"
if printf '%s' "$OUT" | grep -q "FAIL.*live-bad.plist" && ! printf '%s' "$OUT" | grep -q "archived-bad" && ! printf '%s' "$OUT" | grep -q "FAIL.*live-good"; then
  ok "only the live bad plist is a FAIL; the archived one is not judged"
else
  bad "expected FAIL for live-bad only" "$OUT"
fi
printf '%s' "$OUT" | grep -q "2 file(s), 1 fail" && ok "the summary counts the two live plists" || bad "expected '2 file(s), 1 fail' in the summary" "$OUT"

# ═════════════════════════ fix ═════════════════════════
echo "S17: --fix, one-line style"
mk_one "$TMP/f1.plist"; cp "$TMP/f1.plist" "$TMP/f1.orig"
run --fix "$TMP/f1.plist"; expect_rc 0 "fixed"
ADDED="$(diff "$TMP/f1.orig" "$TMP/f1.plist" | grep -c '^>')"; REMOVED="$(diff "$TMP/f1.orig" "$TMP/f1.plist" | grep -c '^<')"
if [ "$ADDED" = 1 ] && [ "$REMOVED" = 0 ] && grep -qx '    <key>BEADS_DOLT_AUTO_START</key><string>0</string>' "$TMP/f1.plist"; then
  ok "exactly one line added, in the neighbours' style and indentation"
else
  bad "expected exactly one added one-line pair" "added=$ADDED removed=$REMOVED $(diff "$TMP/f1.orig" "$TMP/f1.plist")"
fi
run "$TMP/f1.plist"; expect_rc 0 "the fixed file passes the check"

echo "S18: --fix, two-line style with a literal </dict> inside a comment"
mk_two "$TMP/f2.plist"; cp "$TMP/f2.plist" "$TMP/f2.orig"
run --fix "$TMP/f2.plist"; expect_rc 0 "fixed"
ADDED="$(diff "$TMP/f2.orig" "$TMP/f2.plist" | grep -c '^>')"; REMOVED="$(diff "$TMP/f2.orig" "$TMP/f2.plist" | grep -c '^<')"
LASTTWO="$(grep -n 'BEADS_DOLT_AUTO_START' "$TMP/f2.plist" | cut -d: -f1 | head -1)"
if [ "$ADDED" = 2 ] && [ "$REMOVED" = 0 ] \
   && sed -n "${LASTTWO},$((LASTTWO+1))p" "$TMP/f2.plist" | tr -d '\n' | grep -qx '    <key>BEADS_DOLT_AUTO_START</key>    <string>0</string>' \
   && sed -n "$((LASTTWO-1))p" "$TMP/f2.plist" | grep -q '10800'; then
  ok "exactly two lines added, right after the last real entry, not at the comment's fake </dict>"
else
  bad "expected two added lines after the 10800 entry" "added=$ADDED removed=$REMOVED $(diff "$TMP/f2.orig" "$TMP/f2.plist")"
fi
grep -q 'not the end of the dict' "$TMP/f2.plist" && ok "the comment is untouched" || bad "the comment was lost" ""
run "$TMP/f2.plist"; expect_rc 0 "the fixed file passes the check"

echo "S19: --fix, no EnvironmentVariables"
mk_noenv "$TMP/f3.plist"; cp "$TMP/f3.plist" "$TMP/f3.orig"
run --fix "$TMP/f3.plist"; expect_rc 0 "fixed"
ADDED="$(diff "$TMP/f3.orig" "$TMP/f3.plist" | grep -c '^>')"; REMOVED="$(diff "$TMP/f3.orig" "$TMP/f3.plist" | grep -c '^<')"
WANT="$(printf '    <key>EnvironmentVariables</key>\n    <dict>\n        <key>BEADS_DOLT_AUTO_START</key>\n        <string>0</string>\n    </dict>')"
GOT="$(diff "$TMP/f3.orig" "$TMP/f3.plist" | grep '^>' | sed 's/^> //')"
if [ "$ADDED" = 5 ] && [ "$REMOVED" = 0 ] && [ "$GOT" = "$WANT" ]; then
  ok "a new EnvironmentVariables block, in the file's own 4-space style, before the closing </dict>"
else
  bad "expected the 5-line block" "added=$ADDED removed=$REMOVED got: $GOT"
fi
run "$TMP/f3.plist"; expect_rc 0 "the fixed file passes the check"

echo "S20: the real tree"
run
expect_rc 0 "no tracked live plist source lacks BEADS_DOLT_AUTO_START=0"
[ "$RC" = 0 ] || printf '%s\n' "$OUT" | head -20

echo "S21: idempotent"
cp "$TMP/f1.plist" "$TMP/f1.once"; cp "$TMP/f2.plist" "$TMP/f2.once"; cp "$TMP/f3.plist" "$TMP/f3.once"
run --fix "$TMP/f1.plist" "$TMP/f2.plist" "$TMP/f3.plist"; expect_rc 0 "second --fix is a no-op"
same_bytes "$TMP/f1.once" "$TMP/f1.plist" "one-line file unchanged by the second run"
same_bytes "$TMP/f2.once" "$TMP/f2.plist" "two-line file unchanged by the second run"
same_bytes "$TMP/f3.once" "$TMP/f3.plist" "no-env file unchanged by the second run"
printf '%s' "$OUT" | grep -q "0 fixed" && ok "the summary says nothing was fixed" || bad "expected '0 fixed' in the summary" "$OUT"

echo "S22: key present with a wrong value"
mk_val "$TMP/w.plist" '<string>1</string>'; cp "$TMP/w.plist" "$TMP/w.orig"
run --fix "$TMP/w.plist"; expect_rc 2 "--fix will not rewrite an explicit value"
same_bytes "$TMP/w.orig" "$TMP/w.plist" "the file is byte-identical after the refusal"

echo "S23: CRLF file"
mk_one "$TMP/crlf.plist"; awk '{ printf "%s\r\n", $0 }' "$TMP/crlf.plist" > "$TMP/crlf2.plist"   # awk, not sed: BSD sed (macOS) does not read \r in a replacement
run --fix "$TMP/crlf2.plist"; expect_rc 0 "fixed"
BARE="$(LC_ALL=C grep -c -v $'\r$' "$TMP/crlf2.plist")"
[ "$BARE" = 0 ] && ok "every line of the fixed file still ends in CRLF" || bad "$BARE line(s) lost their CR" "$(LC_ALL=C grep -n -v $'\r$' "$TMP/crlf2.plist" | head -3)"
run "$TMP/crlf2.plist"; expect_rc 0 "the CRLF file passes the check"

echo "S24: malformed and binary plists are left alone"
cp "$TMP/s9.plist" "$TMP/m.plist"; cp "$TMP/m.plist" "$TMP/m.orig"
run --fix "$TMP/m.plist"; expect_rc 2 "a malformed plist cannot be fixed"
same_bytes "$TMP/m.orig" "$TMP/m.plist" "malformed file untouched"
"${PY[@]}" -c '
import plistlib, sys
plistlib.dump({"Label": "com.test.bin", "EnvironmentVariables": {"PATH": "/usr/bin"}}, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)
' "$TMP/b.plist"
cp "$TMP/b.plist" "$TMP/b.orig"
run --fix "$TMP/b.plist"; expect_rc 2 "a binary plist cannot be fixed textually"
same_bytes "$TMP/b.orig" "$TMP/b.plist" "binary file untouched"
printf '%s' "$ERR" | grep -qi "binary" && ok "the refusal says it is a binary plist (and what to do)" || bad "expected the word 'binary' in the refusal" "$ERR"

echo "S25: file mode preserved"
mk_one "$TMP/mode.plist"; chmod 0640 "$TMP/mode.plist"
run --fix "$TMP/mode.plist"
if [ "$(stat -c '%a' "$TMP/mode.plist" 2>/dev/null || stat -f '%Lp' "$TMP/mode.plist")" = "640" ]; then ok "mode 0640 kept"; else bad "mode changed" "$(ls -l "$TMP/mode.plist")"; fi

echo "S26: the fix is semantically neutral (parse result == original + the one key)"
for f in f1 f2 f3; do
  SEM="$("${PY[@]}" - "$TMP/$f.orig" "$TMP/$f.plist" <<'PYEOF'
import plistlib, sys, copy
a = plistlib.load(open(sys.argv[1], "rb"))
b = plistlib.load(open(sys.argv[2], "rb"))
want = copy.deepcopy(a)
want.setdefault("EnvironmentVariables", {})["BEADS_DOLT_AUTO_START"] = "0"
print("same" if b == want else "DIFFERENT")
PYEOF
)"
  [ "$SEM" = same ] && ok "$f: only the one key differs" || bad "$f: the parse result changed beyond the one key" "$SEM"
done

echo "S27: round trip over the real tree (strip the key, --fix, get the original bytes back)"
RT="$TMP/rt"; mkdir -p "$RT"
LIVE_LIST="$TMP/live.list"
git -C "$HERE/.." ls-files -z -- '*.plist' 2>/dev/null | tr '\0' '\n' | grep -v '^docs/launchd-archive/' > "$LIVE_LIST"
N_LIVE="$(wc -l < "$LIVE_LIST" | tr -d ' ')"
if [ "$N_LIVE" -lt 50 ]; then
  bad "expected the city to track dozens of live plists, found $N_LIVE" "$(cat "$LIVE_LIST" | head -3)"
else
  "${PY[@]}" - "$HERE/.." "$LIVE_LIST" "$RT" <<'PYEOF'
import os, re, sys
root, lst, out = sys.argv[1:4]
# strip what --fix writes: the key/string pair (one or two lines), or, for the files that had no environment at all, the whole block
pair = re.compile(r"^[ \t]*<key>BEADS_DOLT_AUTO_START</key>(?:[ \t]*<string>0</string>|[ \t]*\r?\n[ \t]*<string>0</string>)[ \t]*\r?\n", re.M)
block = re.compile(r"^[ \t]*<key>EnvironmentVariables</key>(?:[ \t]*\r?\n[ \t]*)?<dict>[ \t]*\r?\n"
                   r"[ \t]*<key>BEADS_DOLT_AUTO_START</key>(?:[ \t]*<string>0</string>|[ \t]*\r?\n[ \t]*<string>0</string>)[ \t]*\r?\n"
                   r"[ \t]*</dict>[ \t]*\r?\n", re.M)
n = 0
for rel in open(lst).read().split("\n"):
    if not rel:
        continue
    t = open(os.path.join(root, rel), encoding="utf-8", newline="").read()
    s = block.sub("", t, count=1) if block.search(t) else pair.sub("", t, count=1)
    d = os.path.join(out, "stripped", os.path.dirname(rel)); os.makedirs(d, exist_ok=True)
    open(os.path.join(out, "stripped", rel), "w", encoding="utf-8", newline="").write(s)
    n += 1
print(n)
PYEOF
  PLIST_FILES=(); while IFS= read -r rel; do [ -n "$rel" ] && PLIST_FILES+=("$RT/stripped/$rel"); done < "$LIVE_LIST"
  run --fix "${PLIST_FILES[@]}"; expect_rc 0 "the fixer repaired all $N_LIVE stripped plists"
  MISMATCH=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! cmp -s "$HERE/../$rel" "$RT/stripped/$rel"; then MISMATCH=$((MISMATCH+1)); [ "$MISMATCH" -le 3 ] && printf '     differs: %s\n' "$rel"; fi
  done < "$LIVE_LIST"
  [ "$MISMATCH" = 0 ] && ok "all $N_LIVE plists come back byte-identical (so the committed edit is exactly what --fix writes)" || bad "$MISMATCH plist(s) did not round-trip" ""
fi

echo "S28: an EnvironmentVariables that lives inside another dict is not launchd's environment"
cat > "$TMP/nest.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.nest</string>
  <key>KeepAlive</key><dict>
    <key>EnvironmentVariables</key><dict>
      <key>PATH</key><string>/usr/bin</string>
    </dict>
  </dict>
</dict></plist>
PLIST
cp "$TMP/nest.plist" "$TMP/nest.orig"
run "$TMP/nest.plist"; expect_rc 1 "only the top-level environment counts"
run --fix "$TMP/nest.plist"; expect_rc 2 "--fix will not write the key into the wrong dict (the parse-check refuses it)"
same_bytes "$TMP/nest.orig" "$TMP/nest.plist" "the file is byte-identical after the refusal"
printf '%s' "$ERR" | grep -q "cannot fix" && ok "the refusal says why (cannot fix), it is not a crash" || bad "expected 'cannot fix' in the refusal" "$ERR"

echo "S31: EnvironmentVariables that is not a dict"
cat > "$TMP/notdict.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.notdict</string>
  <key>EnvironmentVariables</key><string>BEADS_DOLT_AUTO_START=0</string>
</dict></plist>
PLIST
run "$TMP/notdict.plist"; expect_rc 1 "a string that mentions the name is not an environment"
printf '%s' "$OUT" | grep -q "not a dict" && ok "the message says it is not a dict" || bad "expected 'not a dict'" "$OUT"
cp "$TMP/notdict.plist" "$TMP/notdict.orig"
run --fix "$TMP/notdict.plist"; expect_rc 2 "--fix does not touch it"
same_bytes "$TMP/notdict.orig" "$TMP/notdict.plist" "byte-identical"

echo "S32: the new pair copies the style of the entry right above it (the LAST one), not the first"
cat > "$TMP/mix1.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.mix1</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin</string>
    <key>HOME</key>
    <string>/Users/test</string>
  </dict>
</dict></plist>
PLIST
cat > "$TMP/mix2.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.mix2</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key>
    <string>/usr/bin</string>
    <key>HOME</key><string>/Users/test</string>
  </dict>
</dict></plist>
PLIST
run --fix "$TMP/mix1.plist" "$TMP/mix2.plist"; expect_rc 0 "both fixed"
if grep -A1 'BEADS_DOLT_AUTO_START' "$TMP/mix1.plist" | tr -d '\n' | grep -q '<key>BEADS_DOLT_AUTO_START</key>    <string>0</string>'; then
  ok "first pair one-line, last pair two-line: the new pair is two-line"
else
  bad "expected a two-line pair after a two-line last entry" "$(cat "$TMP/mix1.plist")"
fi
if grep -qx '    <key>BEADS_DOLT_AUTO_START</key><string>0</string>' "$TMP/mix2.plist"; then
  ok "first pair two-line, last pair one-line: the new pair is one-line"
else
  bad "expected a one-line pair after a one-line last entry" "$(cat "$TMP/mix2.plist")"
fi

echo "S33: two EnvironmentVariables keys in one file are ambiguous: --fix leaves it to a human"
cat > "$TMP/two-env.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.twoenv</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin</string>
  </dict>
  <key>KeepAlive</key><dict>
    <key>EnvironmentVariables</key><dict>
      <key>PATH</key><string>/bin</string>
    </dict>
  </dict>
</dict></plist>
PLIST
cp "$TMP/two-env.plist" "$TMP/two-env.orig"
run --fix "$TMP/two-env.plist"; expect_rc 2 "ambiguous structure is refused"
same_bytes "$TMP/two-env.orig" "$TMP/two-env.plist" "byte-identical"
printf '%s' "$ERR" | grep -q "appears 2 times" && ok "the refusal names the cause" || bad "expected 'appears 2 times'" "$ERR"

echo "S34: --fix leaves no temp file behind"
LEFT="$(find "$TMP" -name '.plist-fix-*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEFT" = 0 ] && ok "no .plist-fix-* file left anywhere under the fixture dir" || bad "$LEFT stray temp file(s)" "$(find "$TMP" -name '.plist-fix-*' | head -3)"

echo "S35: --installed judges the copies of the tracked plists, found by Label, and nothing else in the directory"
IR="$TMP/inst-repo"; AG="$TMP/inst-agents"; mkdir -p "$IR/scripts" "$AG"
git -C "$IR" init -q 2>/dev/null
mk_one "$IR/scripts/a.plist"; sed -i.bak 's/com.test.one/com.test.a/' "$IR/scripts/a.plist"
mk_one "$IR/scripts/b.plist" '
    <key>BEADS_DOLT_AUTO_START</key><string>0</string>'; sed -i.bak 's/com.test.one/com.test.b/' "$IR/scripts/b.plist"
mk_one "$IR/scripts/c.plist"; sed -i.bak 's/com.test.one/com.test.c/' "$IR/scripts/c.plist"
rm -f "$IR"/scripts/*.bak
git -C "$IR" add -A 2>/dev/null
cp "$IR/scripts/a.plist" "$AG/com.test.a.plist"      # installed, lacks the variable
cp "$IR/scripts/b.plist" "$AG/com.test.b.plist"      # installed, has it
mk_noenv "$AG/com.thirdparty.updater.plist"          # NOT ours: lacks it too, and must be neither named nor touched
cp "$AG/com.thirdparty.updater.plist" "$TMP/third.orig"
OUT="$(PLIST_LINT_ROOT="$IR" PLIST_LINT_AGENTS_DIR="$AG" "${PY[@]}" "$LINT" --installed 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 1 "an installed copy without the variable is a finding"
if printf '%s' "$OUT" | grep -q "FAIL.*com.test.a.plist" && ! printf '%s' "$OUT" | grep -q "thirdparty" && ! printf '%s' "$OUT" | grep -q "FAIL.*com.test.b.plist"; then
  ok "only the installed copy that lacks it is named; the third-party plist is not even read"
else
  bad "expected FAIL for com.test.a.plist only" "$OUT"
fi
printf '%s' "$OUT" | grep -q "2 file(s), 1 fail" && printf '%s' "$OUT" | grep -q "1 tracked plist(s) not installed" && ok "the summary counts 2 judged and 1 not installed" || bad "expected '2 file(s), 1 fail' and '1 tracked plist(s) not installed'" "$OUT"
printf '%s' "$OUT" | grep -q "com.test.c" && ok "the not-installed label is listed" || bad "expected the label com.test.c in the not-installed list" "$OUT"
OUT="$(PLIST_LINT_ROOT="$IR" PLIST_LINT_AGENTS_DIR="$AG" "${PY[@]}" "$LINT" --installed --fix 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 0 "--installed --fix repairs the installed copy"
OUT="$(PLIST_LINT_ROOT="$IR" PLIST_LINT_AGENTS_DIR="$AG" "${PY[@]}" "$LINT" --installed 2>"$TMP/err")"; RC=$?
expect_rc 0 "and the check is clean afterwards"
same_bytes "$TMP/third.orig" "$AG/com.thirdparty.updater.plist" "the third-party plist is byte-identical after --fix"
cmp -s "$IR/scripts/a.plist" "$AG/com.test.a.plist" && bad "the installed copy was fixed but the TRACKED file was touched too?" "" || ok "the tracked source is left alone (the installed copy differs from it until the repo is fixed)"

echo "S36: --installed with a FILE, and with nothing installed"
OUT="$(PLIST_LINT_ROOT="$IR" PLIST_LINT_AGENTS_DIR="$AG" "${PY[@]}" "$LINT" --installed "$IR/scripts/b.plist" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "--installed takes no FILE (even where the installed copy exists and would have passed)"
EMPTYAG="$TMP/inst-empty"; mkdir -p "$EMPTYAG"
OUT="$(PLIST_LINT_ROOT="$IR" PLIST_LINT_AGENTS_DIR="$EMPTYAG" "${PY[@]}" "$LINT" --installed 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "an agents dir with none of our plists is not clean (wrong directory?)"
printf '%s' "$ERR" | grep -q "no installed copy of any tracked plist" && ok "and it says WHY (no installed copy), not the archive message of the discovery guard" || bad "expected 'no installed copy of any tracked plist'" "$ERR"
OUT="$(PLIST_LINT_ROOT="$IR" PLIST_LINT_AGENTS_DIR="$TMP/no-such-dir" "${PY[@]}" "$LINT" --installed 2>"$TMP/err")"; RC=$?
expect_rc 2 "an agents dir that does not exist is not clean either"

echo "S37: --installed never leaves the agents dir (a Label with a slash) and ignores archived plists"
TR="$TMP/trav-repo"; TAG="$TMP/trav-agents"; mkdir -p "$TR/scripts" "$TR/docs/launchd-archive/retired" "$TAG/sub/real"
git -C "$TR" init -q 2>/dev/null
mk_one "$TR/scripts/evil.plist"; sed -i.bak 's#com.test.one#../outside#' "$TR/scripts/evil.plist"
mk_one "$TR/scripts/evil2.plist"; sed -i.bak 's#com.test.one#real/../../outside#' "$TR/scripts/evil2.plist"       # resolves to $TAG/outside.plist from $TAG/sub
mk_one "$TR/scripts/empty.plist"; sed -i.bak 's#<string>com.test.one</string>#<string></string>#' "$TR/scripts/empty.plist"   # an empty Label names no file
mk_one "$TR/scripts/fine.plist" '
    <key>BEADS_DOLT_AUTO_START</key><string>0</string>'; sed -i.bak 's/com.test.one/com.test.fine/' "$TR/scripts/fine.plist"
mk_noenv "$TR/docs/launchd-archive/retired/old.plist"; sed -i.bak 's#com.test.noenv#com.test.retired#' "$TR/docs/launchd-archive/retired/old.plist"
rm -f "$TR"/scripts/*.bak "$TR"/docs/launchd-archive/retired/*.bak
git -C "$TR" add -A 2>/dev/null
cp "$TR/scripts/fine.plist" "$TAG/sub/com.test.fine.plist"
mk_noenv "$TAG/outside.plist"; cp "$TAG/outside.plist" "$TMP/outside.orig"        # what the Label "../outside" would reach from $TAG/sub
mk_noenv "$TAG/sub/com.test.retired.plist"; cp "$TAG/sub/com.test.retired.plist" "$TMP/retired.orig"
OUT="$(PLIST_LINT_ROOT="$TR" PLIST_LINT_AGENTS_DIR="$TAG/sub" "${PY[@]}" "$LINT" --installed --fix 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
[ "$(printf '%s' "$ERR" | grep -c "no usable Label")" = 3 ] && ok "both traversal Labels and the empty one are refused as unusable, no guess at a path (rc 2, not 'not installed')" || bad "expected 'no usable Label' three times (../outside, real/../../outside, empty)" "$ERR"
same_bytes "$TMP/outside.orig" "$TAG/outside.plist" "the file a ../ Label would have reached is byte-identical"
same_bytes "$TMP/retired.orig" "$TAG/sub/com.test.retired.plist" "the installed copy of an ARCHIVED plist is not judged or touched"

echo "S38: discovery where EVERY tracked plist is archived judges nothing, and zero judged is not clean"
AR="$TMP/all-archived"; mkdir -p "$AR/docs/launchd-archive/retired"; git -C "$AR" init -q 2>/dev/null
mk_noenv "$AR/docs/launchd-archive/retired/old.plist"; git -C "$AR" add -A 2>/dev/null
OUT="$(PLIST_LINT_ROOT="$AR" "${PY[@]}" "$LINT" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "no live plist among the tracked ones is not a clean 0"
printf '%s' "$ERR" | grep -q "refusing to call that clean" && ok "and it says so" || bad "expected 'refusing to call that clean'" "$ERR"

echo "S29: a failure inside the lint is 'could not decide' (2), never a finding (1)"
mk_noenv "$TMP/ação.plist"
OUT="$(PYTHONIOENCODING=ascii:strict python3 "$LINT" "$TMP/ação.plist" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
expect_rc 2 "stdout that cannot print the file name (an ascii-only stream) ends in 2, not in the 1 that blocks a push"
printf '%s' "$ERR" | grep -q "internal error" && ok "the stderr line says it was an internal error" || bad "expected 'internal error' on stderr" "$ERR"

echo "S30: a symlinked plist (LaunchAgents -> the repo) keeps its link; the TARGET is edited"
mkdir -p "$TMP/real" "$TMP/links"
mk_one "$TMP/real/target.plist"
ln -s "$TMP/real/target.plist" "$TMP/links/job.plist"
run --fix "$TMP/links/job.plist"; expect_rc 0 "fixed through the link"
if [ -L "$TMP/links/job.plist" ]; then ok "the link is still a link"; else bad "the symlink was replaced by a regular file" "$(ls -l "$TMP/links")"; fi
run "$TMP/real/target.plist"; expect_rc 0 "the target carries the variable now"

echo
echo "plist-bd-env-lint.selftest: $PASS ok, $FAIL bad"
[ "$FAIL" -eq 0 ]
