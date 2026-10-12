#!/usr/bin/env bash
# gate-fastlane.selftest.sh (ga-atsahv)
# SLICE NOTE (ga-atsahv.2 of 3 — removed by ga-atsahv.3): slices 1+2 run items 1-3 and 4 of the list above (the scanner, the path classes, classify_raw, and
# decide / history / confirm on real git history, §4 and its sub-sections except §4e). Items 5-8 (the dispatcher blocks, record + tally, drift guards, mutation
# checks) arrive with ga-atsahv.3; until then this file proves exactly what the slices so far contain.
#
#
# Proves the gate's DOC/TEST fast lane: a diff whose EVERY file is documentation or tests (scan clean, new
# tests green) skips the LLM reviewer; everything else — code, prompt/doctrine text, a finding, a failing test,
# or anything that merely could not be verified — stays in the normal gate.
#
# What is executed, not described:
#   1. the content scanner (gate-fastlane-scan.py): findings, clean, and the three "cannot scan" cases;
#   2. gate_fastlane_path_class on a table of paths (the story's DOC/TEST/PROMPT/CODE definitions);
#   3. gate_fastlane_classify_raw on hand-built `git diff --raw` records (symlink, quoted path, type change,
#      empty, garbage, the rename-a-code-file-into-a-doc trick);
#   4. gate_fastlane_decide against REAL git history in a temp repo — the story's own test (branch with only
#      docs/*.md -> fast) and its controls (a skill .md -> normal; .md + one .py -> normal), plus the
#      third-state cases (git error, missing scanner, binary file, symlink, policy file, kill-switch);
#   5. the dispatcher's LIVE blocks, extracted by SELFTEST-EXTRACT sentinels and run under /bin/bash 3.2
#      (the shell the daemon runs under) with `set -euo pipefail`: lib load, lane decision, the Step 7 bypass;
#   6. drift guards on facts the safety argument depends on (Phase C refuses a zero-verdict run BEFORE it asks
#      whether "all verdicts are in", so 0-of-0 can never read as PASS);
#   7. mutation checks of THIS harness: a lib that loses its symlink guard / that reads "could not scan" as
#      "clean" / whose reason code the tally does not bucket / that has no default arm for an empty runner lookup /
#      that believes a dead scanner's exit code must turn the matching assertion red;
#   8. (§4g) the third state of EVERY lookup the lane makes — the runner and class lookups, the scanner's exit code
#      and output shape, the digest, the PATH filter without HOME, the clock, the kill switch without a location:
#      each is made to answer nothing / garbage / an error and must end in the normal gate with a reason that says
#      it could not tell.
#
# Lines the scanner cannot classify are exit 2, never "adds nothing" (§1, §4b); and every lane decision is run
# through the REAL record and the REAL tally (§4e), so a reason the producer emits and the tally does not bucket
# cannot hide behind a hand-written fixture.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/gate-fastlane.lib.sh"
SCAN="$SELF_DIR/gate-fastlane-scan.py"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2) — never the first `bash` on PATH

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-fastlane.selftest =="
for f in "$LIB" "$SCAN"; do
  if [ -r "$f" ]; then ok "present: $(basename "$f")"; else bad "missing: $f"; fi
done
[ -x "$B32" ] || { echo "FATAL: $B32 not found"; exit 2; }

# The fixtures write absolute paths under $T INTO test files and docs that the lane then scans (and the scan flags any run of 8+ digits, separators
# ignored). A caller whose TMPDIR holds such a run (the gate's reviewer reproduced it with …/506252929262/…: five assertions went red) would turn the
# selftest red for a reason that has nothing to do with the lane — and prod-tests/gascity/story-ga-atsahv.sh runs this file under whatever TMPDIR the
# deploy has. So the fixture base dir is checked against the scanner's OWN rule and moved to /tmp when it would trip it.
# It asks the scanner's OWN regex (imported, not copied: a copy drifts). 0 = carries a run, 1 = does not; python failing to run is neither, so it stops the
# selftest instead of reading as "no run" (a traceback exits 1 too).
has_long_number() {
  python3 - "$SCAN" "$1" <<'PYHLN'
import importlib.util, sys
try:
    spec = importlib.util.spec_from_file_location("gate_fastlane_scan", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    found = mod._LONG_NUMBER.search(sys.argv[2]) is not None
except Exception as e:
    print(f"has_long_number: cannot load the scanner's regex: {e!r}", file=sys.stderr)
    sys.exit(3)
sys.exit(0 if found else 1)
PYHLN
  local r=$?
  case "$r" in 0|1) return "$r" ;; *) echo "FATAL: has_long_number could not run (rc=$r)"; exit 2 ;; esac
}
T="$(mktemp -d "${TMPDIR:-/tmp}/gate-fastlane.XXXXXX")" || { echo "mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
if has_long_number "$T"; then
  rm -rf "$T"
  T="$(mktemp -d /tmp/gate-fastlane.XXXXXX)" || { echo "mktemp failed"; exit 2; }
fi
if has_long_number "$T"; then bad "fixture base dir $T carries an 8+ digit run — fixtures that embed it would trip the lane's own scan"; else ok "fixture base dir carries no 8+ digit run — the fixtures that embed absolute paths cannot trip the lane's own scan, whatever the caller's TMPDIR"; fi
mkdir -p "$T/tmp" "$T/bin"
TAB=$'\t'
# fl_env <ENV=VAL ...> <cmd ...> — `env` for EVERY child that runs the lib. The lane's operator controls and tuning knobs are pinned to their defaults first, so a
# case's result never depends on the caller's environment (gate round 3, blocking issue 2: with GC_CITY exported and <city>/.gc/gate-fastlane.off present — or
# GATE_FASTLANE_ENABLED=0 exported — 102 of 435 assertions went red). Pinned by NAME PATTERN, not by a list, so a knob added later is covered too: every
# GATE_FASTLANE_* the caller exports is unset, GC_CITY is unset (the lib falls back to it for the flag-file path), and the two controls get explicit values.
# A case that WANTS a control (§4d, §4f) passes it as an ENV=VAL argument, which comes after the pin and wins; §5f proves both halves.
fl_env() {
  local a=() v
  for v in $(compgen -e | grep '^GATE_FASTLANE_' || true); do a[${#a[@]}]="-u"; a[${#a[@]}]="$v"; done
  env ${a[@]+"${a[@]}"} -u GC_CITY GATE_FASTLANE_ENABLED=1 GATE_FASTLANE_OFF_FILE="$T/pinned-absent.off" "$@"
}

# ── 1. the scanner ────────────────────────────────────────────────────────────────────────────────────────────
echo "── 1. scanner: findings, clean, and 'could not scan' ──"
mkdiff() { printf 'diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n@@ -0,0 +1,1 @@\n%s\n' "$1"; }
scan_case() { # name body want_rc
  local out rc=0
  out=$(mkdiff "$2" | python3 "$SCAN" 2>&1) || rc=$?
  if [ "$rc" = "$3" ]; then ok "scan: $1 → rc=$3"; else bad "scan: $1 → rc=$rc, want $3 ($out)"; fi
}
scan_case "clean prose"                 '+Este documento descreve o gate.'                       0
scan_case "formatted CPF"               '+cliente 529.982.247-25 ligou'                         1
scan_case "bare 11 digits, valid DV"    '+cpf 52998224725 fim'                                   1
# ONE rule (gate round 4): any run of 8+ digits is a finding, whatever it is. These two used to be 'clean' under the
# per-notation list; they are the accepted false positives — one ordinary review, which is the status quo.
scan_case "11 digits, invalid DV (accepted false positive)"  '+id 12345678901 fim'               1
scan_case "epoch-ms timestamp (accepted false positive)"     '+ts 1790815326123'                 1
scan_case "phone +55"                   '+fone +55 31 99999-8888'                                1
scan_case "phone (DDD) landline"        '+fone (31) 3333-4444'                                   1
scan_case "WhatsApp-style id"           '+jid 5531999998888@s.whatsapp.net'                      1
scan_case "AWS key"                     '+AKIAIOSFODNN7EXAMPLE'                                  1
scan_case "private key header"          '+-----BEGIN RSA PRIVATE KEY-----'                       1
scan_case "secret assignment"           '+API_TOKEN = "a1b2c3d4e5f6g7h8i9j0k1l2"'                1
# a value that opens with < $ or * is not in _ASSIGN's value class, so it is clean BY CONSTRUCTION — not because of _PLACEHOLDER (gate round ga-edhzgb:
# the one row that stood here, `<your-token-here-0123>`, never reached the placeholder skip, so a scanner without it passed the whole selftest)
scan_case "template value <...> (clean by construction)"   '+API_TOKEN = "<your-token-here-0123>"'    0
scan_case "template value \${...} (clean by construction)" '+TOKEN=${MY_SECRET_TOKEN_FROM_ENV_VAR1}'    0
scan_case "masked value ***** (clean by construction)"     '+token: ************************'         0
scan_case "word-like value"             '+token_refresh_policy = some_descriptive_name_value'    0
scan_case "credentials in a URL"        '+mysql://root:hunter2pass@db.local/x'                   1
scan_case "bead id / short sha"         '+commit f8fa11ee6 fix(ga-gnr3tw) bd ga-atsahv'          0
# 1a2. the placeholder skip. Each value below MATCHES _ASSIGN (20+ token characters, letters AND digits, under 8 digits in a row) and is a placeholder, so
# it is clean only because _PLACEHOLDER says so. The mutant scanner (_PLACEHOLDER replaced by a regex that never matches) must flip every one of them to a
# finding — that is the proof the rows exercise the skip (gate round ga-edhzgb, blocking issue 1: the previous row passed with the skip removed).
PLACEHOLDERS=('API_TOKEN = "xxxxxxxxxxxxxxxxxxxxxxxx1"' 'api_key = "example123abcdefghijklmnop"' 'password = "changeme123abcdefghijklmnop"'
              'secret = "your_secret_key_123abcdefghij"' 'token: "your-token-here-123abcdefgh"' 'token = "dummy1234abcdefghijklmnopqrs"'
              'token = "redacted1abcdefghijklmnopqrstu"' 'token = "placeholder12abcdefghijklmnopq"' 'token = "a1b2c3d4....................."')
MUT="$T/scan-no-placeholder.py"
sed 's/^_PLACEHOLDER = .*/_PLACEHOLDER = re.compile(r"(?!x)x")   # mutant: the placeholder skip can never fire/' "$SCAN" > "$MUT"
if grep -qF '_PLACEHOLDER = re.compile(r"(?!x)x")' "$MUT" && ! cmp -s "$SCAN" "$MUT"; then ok "mutant scanner built (the placeholder skip can never fire)"; else bad "mutant scanner was not built — the placeholder rows below prove nothing"; fi
for v in "${PLACEHOLDERS[@]}"; do
  scan_case "placeholder skip: ${v%%[=:]*}… ${v#*[=:] }" "+$v" 0
  mrc=0; mkdiff "+$v" | python3 "$MUT" >/dev/null 2>&1 || mrc=$?
  if [ "$mrc" = "1" ]; then ok "…and the mutant (no placeholder skip) reports it → the row exercises the skip"; else bad "…the mutant scanner answers rc=$mrc for $v, want 1 — the row passes WITHOUT the placeholder skip"; fi
done
# 1a3. `name = value` where the NAME is quoted, backticked or a table cell (gate round ga-edhzgb, blocking issue 2: the closing quote between the key and
# the separator defeated the rule, and JSON / a dict / a table is how a credential usually shows up in a runbook). V is 26 letters+digits, no 8-digit run.
V='a1b2c3d4e5f6g7h8i9j0k1l2m3'
scan_case 'quoted key, JSON'                  "+\"api_key\": \"$V\""                     1
scan_case 'quoted key, no space'              "+\"token\":\"$V\""                        1
scan_case 'quoted key, single quotes'         "+'password': '$V'"                        1
scan_case 'quoted key inside braces'          "+{\"secret\": \"$V\"}"                    1
scan_case 'quoted compound key'               "+\"client_secret\": \"$V\""               1
scan_case 'backticked key'                    "+\`token\`: $V"                           1
scan_case 'backticked value'                  "+token: \`$V\`"                           1
scan_case 'markdown table row'                "+| api_key | $V |"                       1
scan_case 'hash-rocket'                       "+api_key => \"$V\""                       1
scan_case 'key, space, quote, colon'          "+\"token\" : \"$V\""                      1
for k in 'api_key = "V"' 'API_KEY=V' 'export TOKEN=V' 'password: V' 'apiKey: "V"'; do   # what the rule caught before: still caught
  scan_case "unchanged: ${k//V/…}" "+${k//V/$V}" 1
done
scan_case 'quoted key, placeholder value (skip still applies)'  '+"token": "xxxxxxxxxxxxxxxxxxxxxxxx1"'  0
scan_case 'quoted key, word-like value'                         '+"token": "some_descriptive_name_value"' 0
scan_case 'quoted key, short value'                             '+"token": "abc123"'                      0
scan_case 'quoted key, number-only value'                       '+"token_budget": 4096'                   0
scan_case 'table row, template value'                           '+| token | <your-token-here-0123> |'  0
scan_case 'JWT (three dotted segments)'  '+jwt eyJhbGciOiJIUzI1NiIsInR5cCI.eyJzdWIiOiJhYmNkZWZnaGlqIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r' 1
OUT=$(mkdiff '+cliente 529.982.247-25 ligou' | python3 "$SCAN" 2>&1)
case "$OUT" in *529.982*|*52998224725*) bad "scan output echoes the matched value: $OUT" ;; *) ok "scan output carries label/path/line, never the value ($OUT)" ;; esac
printf 'diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n' | python3 "$SCAN" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "binary file in the diff → rc=2 (cannot scan ≠ clean)" || bad "binary → rc=$rc, want 2"
printf '+orphan added line before any header\n' | python3 "$SCAN" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "added line outside any file header → rc=2" || bad "garbled diff → rc=$rc, want 2"
head -c 300 /dev/zero | tr '\0' 'a' | python3 "$SCAN" --max-bytes 100 >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "input over --max-bytes → rc=2" || bad "oversize → rc=$rc, want 2"
printf 'diff --git a/docs/12345678909 b/x\n+++ b/docs/529.982.247-25.md\n@@ -0,0 +1 @@\n+hello\n' | python3 "$SCAN" >/dev/null 2>&1; rc=$?
[ "$rc" = "1" ] && ok "a CPF in the FILE NAME is a finding too" || bad "CPF in a path → rc=$rc, want 1"

# 1b. the parser must never read a line it cannot classify as "adds nothing" (gate round 1, blocking issue 1)
SCAN_OUT=""
raw_scan() { # name want_rc — the diff on stdin; leaves stdout+stderr in SCAN_OUT
  local rc=0; SCAN_OUT=$(python3 "$SCAN" 2>&1) || rc=$?
  if [ "$rc" = "$2" ]; then ok "scan: $1 → rc=$2"; else bad "scan: $1 → rc=$rc, want $2 ($SCAN_OUT)"; fi
}
H1='diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n'
# (a) str.splitlines() also splits on these; the tail of the cut line no longer starts with "+" and was never scanned
for sep in '\xe2\x80\xa8:U+2028' '\xe2\x80\xa9:U+2029' '\xc2\x85:U+0085 NEL' '\x0c:form feed' '\x0b:vertical tab' '\x1c:file separator' '\x1e:record separator'; do
  raw_scan "a secret after ${sep#*:} inside one added line" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+nota${sep%%:*}chave AKIAIOSFODNN7EXAMPLE e mais\n")
done
raw_scan "a phone after U+2028" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+pagina 1\xe2\x80\xa8fone +55 31 99999-8888\n")
raw_scan "U+2028 in clean prose stays clean" 0 < <(printf "${H1}@@ -0,0 +1 @@\n+nota\xe2\x80\xa8so prosa\n")
# (b) an added line whose TEXT starts with "++ " is a "+++ " line on the wire — content, never a file header, never echoed
raw_scan "an added line shaped like a '+++ ' header is scanned as content" 1 < <(printf "${H1}@@ -0,0 +1,2 @@\n+ok\n+++ x AKIAIOSFODNN7EXAMPLE and key sk-abcdefghijklmnopqrstuvwx\n")
case "$SCAN_OUT" in *AKIA*|*sk-abc*) bad "the finding output published the secret value: $SCAN_OUT" ;; *) ok "…and the output carries only label/path/line ($SCAN_OUT)" ;; esac
[ "$SCAN_OUT" = "$(printf 'aws-key\tdocs/x.md\t2\napi-key\tdocs/x.md\t2')" ] && ok "…with the right path and line (docs/x.md:2), not the line's own text as a path" || bad "path/line wrong: $SCAN_OUT"
raw_scan "a removed line shaped like a '--- ' header is not a header" 0 < <(printf "${H1}@@ -1 +0,0 @@\n---- gone\n")
raw_scan "…and a secret on the added line after such removed lines is still found" 1 < <(printf "${H1}@@ -1,2 +1 @@\n--- first\n-- second\n+kept AKIAIOSFODNN7EXAMPLE\n")
# (c) anything the parser cannot place is rc=2: the hunk header is the authority on how many lines follow
raw_scan "a hunk that ends early (truncated diff)" 2 < <(printf "${H1}@@ -0,0 +1,3 @@\n+only one\n")
raw_scan "an added line the hunk header does not account for" 2 < <(printf "${H1}@@ -0,0 +1 @@\n+one\n+two beyond the declared count\n")
raw_scan "a line that is none of the shapes git emits" 2 < <(printf "${H1}@@ -0,0 +1 @@\n+ok\nGARBAGE LINE\n")
raw_scan "an unknown prefix inside a hunk" 2 < <(printf "${H1}@@ -0,0 +1,2 @@\n+ok\n!what\n")
raw_scan "an unparseable hunk header" 2 < <(printf "${H1}@@ nonsense @@\n+ok\n")
raw_scan "a combined-diff header (never produced by a two-ref diff)" 2 < <(printf "${H1}@@@ -1 -1 +1 @@@\n++ok\n")
raw_scan "a blank line where git would print a prefix" 2 < <(printf "${H1}@@ -0,0 +1 @@\n+ok\n\n")
raw_scan "the 'No newline' marker is understood — and does not hide the finding before it" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+key AKIAIOSFODNN7EXAMPLE\n\\ No newline at end of file\n")
raw_scan "the 'No newline' marker after clean prose" 0 < <(printf "${H1}@@ -0,0 +1 @@\n+prose only\n\\ No newline at end of file\n")
raw_scan "CRLF content (the CR is content, the secret is found)" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+key AKIAIOSFODNN7EXAMPLE\r\n")
raw_scan "an empty diff is clean (nothing added)" 0 < <(printf '')
# (d) a file with no +++ line (empty / mode-only / deleted) still gets its NAME scanned — and the name is never printed
raw_scan "a CPF in the name of an EMPTY new file" 1 < <(printf 'diff --git a/docs/529.982.247-25.md b/docs/529.982.247-25.md\nnew file mode 100644\nindex 0000000..e69de29\n')
case "$SCAN_OUT" in *529.982*) bad "the name finding published the CPF: $SCAN_OUT" ;; *) ok "…reported as $(printf '%s' "$SCAN_OUT" | cut -f2), never as the name itself" ;; esac
raw_scan "a mode-only change with a clean name" 0 < <(printf 'diff --git a/docs/ok.md b/docs/ok.md\nold mode 100644\nnew mode 100755\n')
raw_scan "an empty deleted file with a clean name" 0 < <(printf 'diff --git a/docs/ok.md b/docs/ok.md\ndeleted file mode 100644\nindex e69de29..0000000\n')
raw_scan "a content finding in a file whose NAME also matches" 1 < <(printf 'diff --git a/docs/529.982.247-25.md b/docs/529.982.247-25.md\n--- a/docs/529.982.247-25.md\n+++ b/docs/529.982.247-25.md\n@@ -0,0 +1 @@\n+key AKIAIOSFODNN7EXAMPLE\n')
case "$SCAN_OUT" in *529.982*) bad "a path that matched was printed: $SCAN_OUT" ;; *) ok "…the path that matched is withheld in every line of the output" ;; esac
# (d2) a path that holds a space: git ends the `---` and `+++` lines with a TAB (checked with real git, `cat -vte`: `+++ b/docs/a b.md^I`). The TAB is the
# separator, not part of the name — left in, the finding line had 4 TAB-separated fields instead of the 3 of the scanner's contract, and the caller
# read a REAL finding as "the scanner crashed" (gate round ga-oqugor, blocking issue 1: a finding collapsed into an error).
SP='diff --git a/docs/a b.md b/docs/a b.md\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/docs/a b.md\t\n'
raw_scan "a credential in a file whose path holds a space (git's trailing TAB on the '+++ ' line)" 1 < <(printf "${SP}@@ -0,0 +1 @@\n+chave AKIAIOSFODNN7EXAMPLE\n")
[ "$SCAN_OUT" = "$(printf 'aws-key\tdocs/a b.md\t1')" ] && ok "…as exactly 3 TAB-separated fields, the path without git's TAB (docs/a b.md:1)" || bad "finding line for a spaced path is not label<TAB>path<TAB>line: $(printf '%s' "$SCAN_OUT" | cat -vte)"
raw_scan "a clean doc whose path holds a space" 0 < <(printf "${SP}@@ -0,0 +1 @@\n+so prosa\n")
raw_scan "a number finding in a path with a space is reported on the right line" 1 < <(printf "${SP}@@ -0,0 +1,2 @@\n+ok\n+fone 31 99999 8888\n")
[ "$SCAN_OUT" = "$(printf 'numero-longo\tdocs/a b.md\t2')" ] && ok "…docs/a b.md:2, 3 fields" || bad "number finding for a spaced path: $(printf '%s' "$SCAN_OUT" | cat -vte)"
# (e) personal numbers — ONE rule, not a list of notations (gate round 4: four rounds, four new notations). Once the characters
# between digits are ignored, 8+ digits in a row is a finding. Each notation below is a row the PREVIOUS (per-notation) scanner
# read as clean or only partly covered; the first six are the reviewer's own, verbatim.
for n in '(31) 9 9999-8888' '31 9 9999-8888' '+55 31 9 9999-8888' '529 982 247 25' '529.982.247/25' '3333-4444'; do
  raw_scan "reviewer's notation: ${n}" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+lead ${n} fim\n")
done
# the notation does not matter: any non-letter non-digit between the digits is ignored
for n in '31_99999_8888' '31,99999,8888' '31|99999|8888' '31 / 99999 / 8888' '(**31**) **99999-8888**' '(**31**) **9999**-**8888**' '`31` `99999-8888`' '31 · 99999 · 8888'; do
  raw_scan "other separator: ${n}" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+lead ${n} fim\n")
done
raw_scan "en dash between the groups"          1 < <(printf "${H1}@@ -0,0 +1 @@\n+fone 31\xe2\x80\x9399999\xe2\x80\x938888\n")
raw_scan "non-breaking spaces between the groups" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+fone (31)\xc2\xa099999\xc2\xa08888\n")
raw_scan "zero-width spaces between the groups" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+fone 31\xe2\x80\x8b99999\xe2\x80\x8b8888\n")
raw_scan "fullwidth digits"                    1 < <(printf "${H1}@@ -0,0 +1 @@\n+fone \xef\xbc\x93\xef\xbc\x91\xef\xbc\x99\xef\xbc\x99\xef\xbc\x99\xef\xbc\x99\xef\xbc\x99\xef\xbc\x98\xef\xbc\x98\xef\xbc\x98\xef\xbc\x98\n")
for n in 31999998888 11987654321 3133334444 2133334444 5531999998888@s.whatsapp.net 12345678; do
  raw_scan "bare number ${n}" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+joao,${n}\n")
done
# a number wrapped across a line break is ONE number (a hard-wrapped document); the finding names the line it STARTS on
raw_scan "a phone wrapped across two added lines" 1 < <(printf "${H1}@@ -0,0 +1,2 @@\n+ligar (31) 99999-\n+8888 amanha\n")
[ "$(printf "${H1}@@ -4,0 +5,2 @@\n+ligar (31) 99999-\n+8888 amanha\n" | python3 "$SCAN" 2>&1)" = "$(printf 'numero-longo\tdocs/x.md\t5')" ] && ok "…and is reported on its first line (docs/x.md:5), once" || bad "wrapped-number finding wrong: $(printf "${H1}@@ -4,0 +5,2 @@\n+ligar (31) 99999-\n+8888 amanha\n" | python3 "$SCAN" 2>&1)"
raw_scan "a CPF wrapped across three added lines" 1 < <(printf "${H1}@@ -0,0 +1,3 @@\n+cpf 529.982\n+.247\n+-25\n")
raw_scan "…but two halves in SEPARATE hunks are not adjacent in the new file (documented: not covered)" 0 < <(printf "${H1}@@ -0,0 +1 @@\n+ligar 31 9999\n@@ -5,0 +7 @@\n+8888 amanha\n")
# the price of the rule, said out loud: dates, long ids and numeric rows are findings too (one ordinary review, the status quo)
for n in 2026-10-01 20261001 '2026-10-01 10:56' '1.234.567.890'; do
  raw_scan "accepted false positive: ${n}" 1 < <(printf "${H1}@@ -0,0 +1 @@\n+em ${n} fim\n")
done
raw_scan "a date-stamped FILE NAME is a finding (the name is scanned like content)" 1 < <(printf 'diff --git a/docs/runbooks/reboot-20260929-0645-pre.txt b/docs/runbooks/reboot-20260929-0645-pre.txt\nnew file mode 100644\nindex 0000000..e69de29\n')
# controls: under 8 digits, or a LETTER between the digits, or no digit at all
for n in 9999 1234567 '31 99999' 'v1.2.3' '2026-10' 'f8fa11ee6' '31x99999x8888' 'ga-atsahv' 'trinta e um'; do
  raw_scan "control: ${n} is not a long number" 0 < <(printf "${H1}@@ -0,0 +1 @@\n+valor,${n}\n")
done
raw_scan "control: short numbers on adjacent lines separated by prose" 0 < <(printf "${H1}@@ -0,0 +1,3 @@\n+item 1234\n+texto corrido\n+item 5678\n")
# (f) the scan runs while the dispatcher holds the citywide gate lock: no input may make it hang
LONG="$T/long.diff"
python3 - "$LONG" <<'PYGEN'
import sys
n = 1_500_000
hdr = "diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n"
with open(sys.argv[1], "w") as f:
    # bodies 5-7 stress the long-number rule: a digit followed by a huge separator run, seven-digit near misses by the
    # million, and seven digits joined by 1000-long separator runs (the worst case for a regex that backtracks over them)
    for i, body in enumerate(("a" * n, "token" * (n // 5), "ab12." * (n // 5), "x" * 1000 + "://" + "u" * n,
                              "1" + "-" * n + "x", "1234567a" * (n // 8), (("1" + "-" * 1000) * 7 + "x") * (n // 8000),
                              # a start token that repeats inside its own run: the jwt pattern walked the rest of the run from EVERY `eyJ`
                              # (quadratic: 48 KB took 1 s of CPU, 192 KB took 17 s — gate round ga-edhzgb); and the quote / table-pipe / whitespace
                              # the key-value rule now allows between a keyword and its separator
                              "eyJ" * (n // 3), "eyJ." * (n // 4), 'token"' * (n // 6), "token|" * (n // 6), "token" + " " * n + "x"), 1):
        f.write(hdr.replace("x.md", f"x{i}.md") + "@@ -0,0 +1 @@\n+" + body + "\n")
PYGEN
# CPU seconds, not wall-clock: the gate runs on a machine shared with dozens of agents, where this scan took 64 s of wall time for 8 s of CPU. A quadratic
# regex burns minutes to hours of CPU on these inputs (the jwt pattern on repeated `eyJ` was past 90 s), so 40 CPU s still separates "linear" from "hung"; the
# 300 s wall limit only stops a scanner that is stuck. A python that cannot report leaves rc/cpu empty, which is a red row, never a green one.
LONG_RC=""; LONG_CPU=""
read -r LONG_RC LONG_CPU < <(python3 - "$SCAN" "$LONG" <<'PYCPU'
import resource, subprocess, sys
try:
    rc = subprocess.run([sys.executable, sys.argv[1], "--max-bytes", "20000000"], stdin=open(sys.argv[2]),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300).returncode
except subprocess.TimeoutExpired:
    rc = 124
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
print(rc, int(ru.ru_utime + ru.ru_stime))
PYCPU
)
{ [ "$LONG_RC" = "0" ] && [ -n "$LONG_CPU" ] && [ "$LONG_CPU" -lt 40 ]; } && ok "twelve 1.5 MB single-line adds (word run, repeated keyword, dotted run, scheme run, separator run, 7-digit near misses, 7 digits over 1000-long separator runs, repeated eyJ, repeated eyJ., repeated key+quote, repeated key+pipe, key+whitespace run) scan clean in ${LONG_CPU}s of CPU — no quadratic regex" || bad "long-line scan: rc=${LONG_RC:-<none>} after ${LONG_CPU:-<none>} CPU s (rc 124 = hung past 300 s wall; this was 18 s per 32 KB before)"

# (h) the history mode against REAL git (gate round ga-edhzgb: nothing in this slice ran it). The story's reason for it: a value pasted in one commit and
# removed in the next is not in the NET diff, but the fast-forward publishes every commit. Commit 2 pastes a JSON credential, commit 3 removes it (and adds a
# harmless line) with a message whose phone number wraps across two lines. The git output goes to a FILE first: a git that died would feed the scanner an
# empty stdin, which it answers with "clean" — so the producer's status and a non-empty text are asserted before any scanner verdict is believed.
GR="$T/hist-repo"
gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_DATE="2026-10-11T10:56:00+0000" GIT_COMMITTER_DATE="2026-10-11T10:56:00+0000" \
         git -C "$GR" -c user.name=T -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
if mkdir -p "$GR/docs" && gitq init -q . 2>/dev/null; then
  printf 'prosa\n' > "$GR/docs/a.md"; gitq add docs/a.md && gitq commit -q -m 'docs: inicio'
  H_BASE=$(gitq rev-parse HEAD)
  printf 'prosa\n{"api_key": "a1b2c3d4e5f6g7h8i9j0k1l2m3"}\n' > "$GR/docs/a.md"; gitq commit -q -a -m 'docs: exemplo de configuracao'
  H_PASTE=$(gitq rev-parse HEAD)
  printf 'prosa\nmais prosa\n' > "$GR/docs/a.md"; gitq commit -q -a -m $'docs: contato\n\nligar (31) 99999-\n8888 amanha'
  H_FIX=$(gitq rev-parse HEAD)
  gitq diff -U0 --no-color --no-renames "$H_BASE...$H_FIX" > "$T/net.diff" 2>/dev/null; net_rc=$?
  gitq log -p -U0 --no-merges --pretty=medium --no-decorate --no-abbrev-commit --no-color --no-renames "$H_BASE..$H_FIX" > "$T/hist.diff" 2>/dev/null; hist_rc=$?
  if [ "$net_rc" = "0" ] && [ "$hist_rc" = "0" ] && [ -s "$T/net.diff" ] && [ -s "$T/hist.diff" ] && [ -n "$H_BASE" ] && [ -n "$H_PASTE" ] && [ -n "$H_FIX" ]; then
    ok "real git: the net diff and the history were produced (rc 0, non-empty)"
    raw_scan "real git, NET diff of base...head: the pasted credential is gone, so the net pass is clean" 0 < "$T/net.diff"
    raw_scan "real git, HISTORY of base..head: the credential pasted in commit 2 and the wrapped phone in commit 3's message are both found" 1 < "$T/hist.diff"
    want=$(printf 'numero-longo\t%s:commit-message\t3\nsecret-assignment\t%s:docs/a.md\t2\n' "${H_FIX:0:9}" "${H_PASTE:0:9}" | sort)
    [ "$(printf '%s\n' "$SCAN_OUT" | sort)" = "$want" ] && ok "…as <sha9>:docs/a.md:2 and <sha9>:commit-message:3 — the commit to look at, never the value (the Author/Date header is not scanned)" || bad "history findings wrong: $(printf '%s' "$SCAN_OUT" | cat -vte)"
    case "$SCAN_OUT" in *a1b2c3d4*|*99999*) bad "the history finding published the value: $SCAN_OUT" ;; *) ok "…and the history output carries no matched text" ;; esac
  else
    bad "real git could not produce the net diff / history (net rc=$net_rc, history rc=$hist_rc) — the history rows below prove nothing"
  fi
else
  bad "could not create the temp git repo — the real-git history rows did not run"
fi
FAKE_SHA=0123456789abcdef0123456789abcdef01234567
raw_scan "a commit header line that is not Author:/Date:" 2 < <(printf "commit $FAKE_SHA\nAuthor: T <t@example.invalid>\nbogus header line\n\n    msg\n")
raw_scan "a stream that ends inside a commit header (truncated)" 2 < <(printf "commit $FAKE_SHA\nAuthor: T <t@example.invalid>\nDate:   Sun Oct 11 10:56:00 2026 +0000\n")
raw_scan "a commit whose message holds a phone, no diff" 1 < <(printf "commit $FAKE_SHA\nAuthor: T <t@example.invalid>\nDate:   Sun Oct 11 10:56:00 2026 +0000\n\n    fone 31 99999 8888\n")
raw_scan "a clean commit message; the Date header's digits are not content" 0 < <(printf "commit $FAKE_SHA\nAuthor: T <t@example.invalid>\nDate:   Sun Oct 11 10:56:00 2026 +0000\n\n    docs: so prosa\n")

# ── 2. path classes ───────────────────────────────────────────────────────────────────────────────────────────
echo "── 2. path classes (the story's DOC / TEST / PROMPT / CODE) ──"
cls() { "$B32" -c 'source "$1"; gate_fastlane_path_class "$2"' _ "$LIB" "$1"; }
path_case() { # want path...
  local want="$1" p got; shift
  for p in "$@"; do
    got=$(cls "$p")
    if [ "$got" = "$want" ]; then ok "$want  $p"; else bad "$p → $got, want $want"; fi
  done
}
# DOC is a POSITIVE list (gate round 2, blocking issue 1): a text file under docs/ reports/ runbooks/, or a top-level
# README/CHANGELOG-style file. An .md nobody listed is NOT a doc — "unknown" must not read as "known harmless".
path_case DOC    docs/runbooks/a.md README.md reports/2026-09/relatorio.md docs/x.txt reports/leads.csv runbooks/a.rst \
                 docs/deep/er/x.md whatsapp_automation/docs/data_dictionary.md README.MD \
                 CHANGELOG.md CONTRIBUTING.md LICENSE license.txt README.rst NOTICE AUTHORS.md CODE_OF_CONDUCT.md reports/x/y.txt
path_case TEST   tests/test_a.py tests/fixtures/x.json test_foo.py foo_test.go web/app.test.ts web/app.spec.js \
                 packs/town-deltas/assets/gate-x.selftest.sh tests/conftest.py __tests__/a.js packs/x/assets/tests/daemon-refresh.test.sh
path_case PROMPT skills/foo/SKILL.md .claude/skills/x/SKILL.md CLAUDE.md docs/CLAUDE.md AGENTS.md agents/mayor/prompt.template.md \
                 commands/gate-done.md .claude/commands/x.md packs/town-deltas/template-fragments/a.md prompts/x.txt \
                 formulas/mol-x.toml prompt_v2.md docs/fragments/x.md skill.md Skills/Foo/Skill.MD
# …the five files the gate's round-2 reviewer reproduced as "fast" (agents obey or load these; none is on the old name list)
path_case PROMPT internal/templates/polecat-CLAUDE.md templates/polecat-CLAUDE.md templates/witness-CLAUDE.md \
                 plugins/deacon-patrol/plugin.md .beads/PRIME.md internal/hooks/templates/copilot/copilot-instructions.md \
                 GEMINI.md docs/guides/copilot-instructions.md plugins/x/anything.go
path_case CODE   scripts/foo.py packs/x/assets/quality-gate-dispatcher.sh deploy_deps.json config.toml city.toml \
                 .github/workflows/ci.yml requirements.txt data/leads.csv docs/x.patch docs/run.sh docs/x.json docs/x.html \
                 packs/x/assets/prod-tests/wa/story-1.sh Makefile app/prompt_loader.py docs/img/x.png
# …and the class: a markdown file that is NOT on the positive list is code until someone says otherwise
path_case CODE   .github/PULL_REQUEST_TEMPLATE.md packs/x/NOTES.md SECRETS.md daemons/README.md internal/foo/design.md \
                 design.md sub/CHANGELOG.md README.sh license.py docs.md src/docs.md notes.txt

# ── 3. classify_raw on hand-built records ─────────────────────────────────────────────────────────────────────
echo "── 3. raw diff records: the third state and the rename trick ──"
raw_case() { # name want_state want_blockers(0|1|any) raw
  local out
  out=$("$B32" -c '
    set -euo pipefail
    source "$1"
    gate_fastlane_classify_raw "$2"
    printf "%s|%s|%s|%s\n" "$GATE_FL_STATE" "$GATE_FL_N_CODE" "$([ -n "$GATE_FL_BLOCKERS" ] && echo 1 || echo 0)" "$GATE_FL_WHY"
  ' _ "$LIB" "$4") || { bad "raw: $1 — the call itself failed under set -euo pipefail"; return; }
  local st="${out%%|*}" rest="${out#*|}" blk
  blk=$(printf '%s' "$rest" | cut -d'|' -f2)
  if [ "$st" = "$2" ]; then ok "raw: $1 → $st"; else bad "raw: $1 → $out, want state=$2"; fi
  if [ "$3" != "any" ] && [ "$blk" != "$3" ]; then bad "raw: $1 → blockers=$blk, want $3"; fi
}
rec() { printf ':%s %s %s %s %s\t%s' "$1" "$2" aaaaaaa bbbbbbb "$3" "$4"; }
raw_case "docs + tests only"                 ok             0   "$(rec 000000 100644 A docs/a.md)"$'\n'"$(rec 000000 100755 A tests/x.selftest.sh)"
raw_case "empty list"                        unclassifiable any ""
raw_case "garbage line"                      unclassifiable any "hello world"
raw_case "symlink doc (mode 120000)"         unclassifiable any "$(rec 000000 120000 A docs/link.md)"
raw_case "submodule (mode 160000)"           unclassifiable any "$(rec 000000 160000 A docs/sub.md)"
raw_case "type change T"                     unclassifiable any "$(rec 100644 120000 T docs/a.md)"
raw_case "path needing quotes"               unclassifiable any "$(rec 000000 100644 A '"docs/a\tb.md"')"
raw_case "record without a path"             unclassifiable any ":100644 100644 a b M"
raw_case "unmerged status U"                 unclassifiable any "$(rec 100644 100644 U docs/a.md)"
raw_case "DELETED code file + added doc (rename trick)" ok  1   "$(rec 100644 000000 D scripts/run.py)"$'\n'"$(rec 000000 100644 A docs/run.md)"
raw_case "a gate selftest among docs (policy by path)" ok 1   "$(rec 000000 100644 A docs/a.md)"$'\n'"$(rec 000000 100755 A tests/quality-gate-foo.selftest.sh)"
raw_case "one code file among docs"          ok             1   "$(rec 000000 100644 A docs/a.md)"$'\n'"$(rec 100644 100644 M app/x.py)"

# ── 4. decide() against real git history ──────────────────────────────────────────────────────────────────────
echo "── 4. decide() on real git history (the story's test + controls + third-state cases) ──"
REPO="$T/repo"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO"; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t; git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/app" "$REPO/docs" "$REPO/skills/x" "$REPO/tests"
echo 'print(1)' > "$REPO/app/main.py"; echo base > "$REPO/docs/a.md"; echo skill > "$REPO/skills/x/SKILL.md"
echo 'exit 0' > "$REPO/tests/test_base.selftest.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

mkbr() { # mkbr <branch> <spec>...  spec: path=content (printf %b) | -path (delete) -> prints the tip sha
  local br="$1" s p c; shift
  git -C "$REPO" checkout -q -b "$br" main || return 1
  for s in "$@"; do
    case "$s" in
      -*) git -C "$REPO" rm -q -- "${s#-}" ;;
      *=*) p="${s%%=*}"; c="${s#*=}"; mkdir -p "$REPO/$(dirname "$p")"; printf '%b' "$c" > "$REPO/$p"; git -C "$REPO" add -- "$p" ;;
    esac
  done
  git -C "$REPO" commit -q -m "$br" || return 1
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
}

D_LANE=""; D_REASON=""; D_FILES=""; D_CODE=""
decide() { # decide <head> <policy> [ENV=VAL ...]  -> D_LANE / D_REASON / D_FILES / D_CODE
  local head="$1" policy="$2" out; shift 2
  out=$(fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="${FL_LIB_OVERRIDE:-$LIB}" FL_REPO="$REPO" FL_BASE="${FL_BASE:-main}" FL_HEAD="$head" FL_POLICY="$policy" \
            "$@" \
        "$B32" -c '
    set -euo pipefail
    source "${FL_LIB_OVERRIDE:-$FL_LIB}"   # an override may arrive as a prefix assignment or as an env arg
    gfn() { git -C "$FL_REPO" "$@"; }
    gate_fastlane_decide gfn "$FL_BASE" "$FL_HEAD" "$FL_POLICY"
    printf "%s\n%s\n%s\n%s\n" "$GATE_LANE" "$GATE_LANE_REASON" "$(gate_fastlane_files_oneline)" "$GATE_LANE_REASON_CODE"
  ' 2>"$T/decide.err") || { D_LANE="ABORTED"; D_REASON="decide() aborted under set -euo pipefail: $(cat "$T/decide.err")"; D_FILES=""; D_CODE=""; return; }
  D_LANE=$(printf '%s\n' "$out" | sed -n 1p); D_REASON=$(printf '%s\n' "$out" | sed -n 2p); D_FILES=$(printf '%s\n' "$out" | sed -n 3p); D_CODE=$(printf '%s\n' "$out" | sed -n 4p)
}
check() { # name want_lane [needle-in-reason-or-files]
  if [ "$D_LANE" = "$2" ]; then ok "$1 → $2"; else bad "$1: lane=$D_LANE, want $2 — $D_REASON"; fi
  if [ -n "${3:-}" ]; then
    case "$D_REASON $D_FILES" in *"$3"*) ok "$1: says '$3'" ;; *) bad "$1: expected '$3' in: $D_REASON | $D_FILES" ;; esac
  fi
}
no_leftovers() { # name
  local n; n=$(git -C "$REPO" worktree list | grep -c gc-gate-fs-fastlane || true)
  local m; m=$(ls "$T/tmp" 2>/dev/null | grep -c -E 'gc-gate-fs-fastlane|gc-gate-fl-diff' || true)
  if [ "$n" = "0" ] && [ "$m" = "0" ]; then ok "$1: no worktree / temp file left behind"; else bad "$1: leaked worktrees=$n temp files=$m"; fi
}

# 4a. the story's own test (#5): docs-only is fast — and the controls
S=$(mkbr s-docs 'docs/new.md=hello\n' 'docs/second.md=world\n');            decide "$S" "";  check "story #5: branch with only docs/*.md" fast "DOC or TEST"
S=$(mkbr s-skill 'docs/new.md=hello\n' 'skills/x/SKILL.md=changed\n');       decide "$S" "";  check "control: a skill .md stays in the gate" normal "PROMPT"
S=$(mkbr s-mdpy 'docs/new.md=hello\n' 'app/other.py=print(2)\n');            decide "$S" "";  check "control: .md + one .py stays in the gate" normal "CODE"
S=$(mkbr s-claude 'CLAUDE.md=doctrine\n');                                   decide "$S" "";  check "CLAUDE.md alone stays in the gate" normal "PROMPT"
S=$(mkbr s-config 'docs/new.md=x\n' 'deploy_deps.json={}\n');                decide "$S" "";  check "deploy_deps.json (config) stays in the gate" normal "CODE"
# gate round 2, blocking issue 1: markdown that AGENTS load or obey, none on the old name list — each was "lane=fast, 0 reviewers"
S=$(mkbr s-tpl   'internal/templates/polecat-CLAUDE.md=agent text\n');       decide "$S" "";  check "go:embed'd polecat CLAUDE template (basename *-CLAUDE.md) stays in the gate" normal "PROMPT"
S=$(mkbr s-tpl2  'templates/witness-CLAUDE.md=agent text\n');                decide "$S" "";  check "templates/witness-CLAUDE.md stays in the gate" normal "PROMPT"
S=$(mkbr s-plug  'plugins/deacon-patrol/plugin.md=patrol steps\n');          decide "$S" "";  check "a patrol's plugin.md (read by deacon and dogs) stays in the gate" normal "PROMPT"
S=$(mkbr s-prime '.beads/PRIME.md=prime text\n');                            decide "$S" "";  check ".beads/PRIME.md (read by bd prime) stays in the gate" normal "PROMPT"
S=$(mkbr s-cop   'internal/hooks/templates/copilot/copilot-instructions.md=x\n'); decide "$S" "";  check "copilot-instructions.md stays in the gate" normal "PROMPT"
# …and the CLASS behind the five: a markdown file nobody listed is not a doc
S=$(mkbr s-unkmd 'packs/x/NOTES.md=who knows who reads this\n');             decide "$S" "";  check "an .md outside every known doc place is unknown, and unknown stays in the gate" normal "CODE"
S=$(mkbr s-unkmd2 'docs/ok.md=hello\n' 'daemons/README.md=nested readme\n');  decide "$S" "";  check "docs/ok.md + a nested README.md (not top-level) stays in the gate" normal "daemons/README.md"
# controls: what the story calls documentation is still fast
S=$(mkbr s-readme 'README.md=hello\n' 'CHANGELOG.md=- entry\n');             decide "$S" "";  check "control: top-level README.md + CHANGELOG.md is still fast" fast "DOC or TEST"
S=$(mkbr s-rep 'reports/2026-10/a.md=r\n' 'runbooks/b.md=r\n' 'docs/c.txt=r\n');  decide "$S" "";  check "control: reports/ + runbooks/ + docs/ text is still fast" fast "DOC or TEST"
# 4b. mechanical scan
S=$(mkbr s-cpf 'docs/c.md=cliente 529.982.247-25 ligou\n');                  decide "$S" "";  check "a CPF on an added line" normal "numero-longo"
case "$D_REASON $D_FILES" in *529.982*|*52998224725*) bad "the lane output echoes the CPF value" ;; *) ok "the lane output never echoes the matched value" ;; esac
S=$(mkbr s-phone 'docs/p.md=ligar +55 31 99999-8888\n');                     decide "$S" "";  check "a phone number on an added line" normal "numero-longo"
# gate round 4, blocking issue 1, END TO END through the lane (main + ONE appended line in docs/lead-notes.md): the spaced mobile notation
# merged with zero reviewers; the unspaced one went to the gate. Both go to the gate now, and so does every notation the single rule covers.
S=$(mkbr s-ph-spaced 'docs/lead-notes.md=ligar (31) 9 9999-8888\n');          decide "$S" "";  check "a spaced mobile '(31) 9 9999-8888' (was: content scan clean → fast)" normal "numero-longo"
S=$(mkbr s-ph-plain  'docs/lead-notes.md=ligar (31) 99999-8888\n');           decide "$S" "";  check "…and the unspaced '(31) 99999-8888' (control, was already normal)" normal "numero-longo"
S=$(mkbr s-cpf-sp    'docs/lead-notes.md=cpf 529 982 247 25\n');               decide "$S" "";  check "a CPF with spaces '529 982 247 25' (was: fast)" normal "numero-longo"
S=$(mkbr s-cpf-sl    'docs/lead-notes.md=cpf 529.982.247/25\n');               decide "$S" "";  check "a CPF with a slash '529.982.247/25' (was: fast)" normal "numero-longo"
S=$(mkbr s-landline  'docs/lead-notes.md=fixo 3333-4444\n');                   decide "$S" "";  check "a landline without DDD '3333-4444' (was: fast)" normal "numero-longo"
S=$(mkbr s-wrapped   'docs/lead-notes.md=ligar (31) 99999-\n8888 amanha\n');   decide "$S" "";  check "a phone wrapped across two added lines" normal "numero-longo"
S=$(mkbr s-datefile  'docs/runbooks/reboot-20260929-0645-pre.txt=x\n');        decide "$S" "";  check "accepted false positive: a date-stamped file NAME goes to the ordinary gate (status quo)" normal "numero-longo"
S=$(mkbr s-prose7    'docs/lead-notes.md=versao 1.2.3, ligar ate 31 99999, item 1234567\n');   decide "$S" "";  check "control: prose with numbers under 8 digits stays fast" fast "DOC or TEST"
S=$(mkbr s-key 'docs/k.md=chave AKIAIOSFODNN7EXAMPLE\n');                    decide "$S" "";  check "a credential on an added line" normal "aws-key"
# the gate's round-1 reproductions, end to end with real git: text pasted from a web page / PDF carries U+2028, NEL, FF
S=$(mkbr s-u2028 'docs/leak.md=nota chave AKIAIOSFODNN7EXAMPLE e cliente 529.982.247-25\n' $'docs/leak2.md=pagina 1\xe2\x80\xa8fone +55 31 99999-8888\n')
decide "$S" "";  check "a secret and a phone after a U+2028 are found (was: 'content scan clean' → fast)" normal "numero-longo"
S=$(mkbr s-u2028b $'docs/leak.md=nota\xe2\x80\xa8chave AKIAIOSFODNN7EXAMPLE e cliente 529.982.247-25\n');   decide "$S" "";  check "a secret after a U+2028 inside ONE line" normal "aws-key"
S=$(mkbr s-ff $'docs/ff.md=pagina 1\x0cchave AKIAIOSFODNN7EXAMPLE\n');       decide "$S" "";  check "a secret after a form feed" normal "aws-key"
S=$(mkbr s-nel $'docs/nel.md=linha\xc2\x85chave AKIAIOSFODNN7EXAMPLE\n');    decide "$S" "";  check "a secret after a NEL (U+0085)" normal "aws-key"
S=$(mkbr s-plusplus 'docs/pp.md=ok\n++ x AKIAIOSFODNN7EXAMPLE and key sk-abcdefghijklmnopqrstuvwx\n');   decide "$S" "";  check "an added line that starts with '++ ' (a '+++ ' line on the wire)" normal "aws-key"
case "$D_REASON $D_FILES" in *AKIA*|*sk-abc*) bad "the lane output published the secret value: $D_REASON | $D_FILES" ;; *) ok "…and the lane output (reason + files, which go to bead comments) never carries the value" ;; esac
S=$(mkbr s-bare 'reports/leads.csv=joao,31999998888\nmaria,11987654321\njoao,3133334444\n');   decide "$S" "";  check "a CSV in reports/ with bare, unformatted phone numbers" normal "numero-longo"
S=$(mkbr s-cpfname 'docs/529.982.247-25.md=');                                decide "$S" "";  check "an EMPTY file whose NAME is a CPF" normal "numero-longo"
case "$D_REASON $D_FILES" in *529.982*) bad "the lane output published the CPF found in a file name: $D_REASON | $D_FILES" ;; *) ok "…and the file name that matched is withheld from the lane output" ;; esac
# gate round ga-oqugor, blocking issue 1, END TO END with real git: a REAL finding in a path with a space was booked as "the scanner crashed"
# (scan-failed, rc=2) — the outcome was still the normal gate, but the reason and the tally bucket said the checks were broken, not that they caught something
S=$(mkbr s-sp-find 'docs/a b.md=chave AKIAIOSFODNN7EXAMPLE\n');               decide "$S" "";  check "a credential in 'docs/a b.md' (a path with a space) is a FINDING" normal "aws-key"
[ "$D_CODE" = "scan-findings" ] && ok "…booked as scan-findings" || bad "…booked as '$D_CODE', want scan-findings ($D_REASON)"
case "$D_REASON" in *crash*|*"rc=2"*|*"could not run"*) bad "…the reason calls a finding a crash: $D_REASON" ;; *) ok "…and the reason does not say the scanner crashed" ;; esac
S=$(mkbr s-sp-clean 'docs/My Notes/x y.md=hello\n');                           decide "$S" "";  check "control: a clean doc under 'docs/My Notes/x y.md' stays fast" fast "DOC or TEST"
# 4c. tests: run, env scrubbed, stdin closed, bounded
S=$(mkbr s-testok 'docs/n.md=x\n' 'tests/ok.selftest.sh=exit 0\n');          decide "$S" "";  check "docs + a new green test" fast "exited 0"; no_leftovers "green test"
S=$(mkbr s-testbad 'tests/bad.selftest.sh=exit 3\n');                        decide "$S" "";  check "a new test that FAILS stays in the gate (never a FAIL verdict)" normal "rc=3"; no_leftovers "failing test"
S=$(mkbr s-scrub 'tests/scrub.selftest.sh=[ -z "${FL_SECRET:-}" ] || exit 1\ncase "$HOME" in */gc-gate-fs-fastlane-*) ;; *) exit 1 ;; esac\n')
decide "$S" "" FL_SECRET=hunter2;  check "tests run with a scrubbed env (inherited secret absent, HOME inside the worktree)" fast "exited 0"
# the tests' PATH must not reach tools installed under $HOME (`secret`, `notify` in ~/.local/bin). This is ALL the PATH filter does: bd, gc, dolt, gh, aws,
# gcloud and bw live in /opt/homebrew/bin and stay reachable (gate round 4, blocking issue 2) — the credential shield is the throwaway HOME (§4c scrub case)
mkdir -p "$T/fakehome/.local/bin"; printf '#!/bin/sh\necho VAULT-REACHED\n' > "$T/fakehome/.local/bin/secret"; chmod +x "$T/fakehome/.local/bin/secret"
[ "$(PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" command -v secret)" = "$T/fakehome/.local/bin/secret" ] && ok "premise: a stub 'secret' IS on the caller's PATH under \$HOME" || bad "premise broken: the stub 'secret' is not findable"
S=$(mkbr s-nosecret 'tests/nosecret.selftest.sh=if command -v secret >/dev/null 2>&1; then exit 12; fi\ncommand -v git >/dev/null || exit 13\ncommand -v jq >/dev/null || exit 14\nexit 0\n')
# a controlled PATH: the stub dir under the (fake) HOME first, then only system/Homebrew dirs — so the REAL ~/.local/bin cannot leak in
decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin";  check "tests run WITHOUT the tools under \$HOME on PATH (no 'secret') but with git/jq" fast "exited 0"
# …and it is NOT a boundary around the city (gate round 4, blocking issue 2): a control-plane tool installed OUTSIDE $HOME (bd, gc, dolt in /opt/homebrew/bin on the
# real host) survives the filter. Pinned here so the comment in the lib cannot drift back to claiming otherwise.
mkdir -p "$T/sysbin"; printf '#!/bin/sh\necho CITY-REACHED\n' > "$T/sysbin/bd"; chmod +x "$T/sysbin/bd"
S=$(mkbr s-ctlplane 'tests/ctl.selftest.sh=[ "$(command -v bd)" = "'"$T"'/sysbin/bd" ] || exit 15\n')
decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:$T/sysbin:/opt/homebrew/bin:/usr/bin:/bin";  check "a tool outside \$HOME ('bd') STAYS reachable from the tests: the PATH filter is no boundary around the city" fast "exited 0"
# a test that SKIPS ITSELF exits 0 (this repo's own idiom: `command -v jq ... || { echo "SKIP: ..."; exit 0; }`). The lane reads only the exit code, so it cannot
# tell a skip from a pass — and must not SAY the test "ran green" (gate round ga-oqugor, non-blocking medium). The reason says what it saw: exit 0.
S=$(mkbr s-skip 'tests/skip.selftest.sh=command -v no-such-tool-xyz >/dev/null 2>&1 || { echo "SKIP: no-such-tool-xyz missing"; exit 0; }\nfalse\n')
decide "$S" "";  check "a test that skips itself exits 0, and the lane says exactly that" fast "1 test file(s) exited 0"
case "$D_REASON" in *"ran green"*) bad "the reason claims a skipping test 'ran green': $D_REASON" ;; *) ok "…and never claims it 'ran green'" ;; esac
RAN="$T/ran.log"; : > "$RAN"
S=$(mkbr s-stdin 'tests/a.selftest.sh=cat >/dev/null\n' "tests/b.selftest.sh=echo b >> $RAN\n")
decide "$S" "";  check "two tests; the first reads stdin" fast "2 test file(s) exited 0"
grep -q '^b$' "$RAN" 2>/dev/null && ok "the second test RAN — a stdin-reading test cannot swallow the file list" || bad "the second test never ran: the first ate the file list"
S=$(mkbr s-slow 'tests/slow.selftest.sh=sleep 30\n'); SECONDS=0
decide "$S" "" GATE_FASTLANE_TEST_TIMEOUT_SECS=1;  check "a test that outruns its timeout stays in the gate" normal "124"
# 30s sleep vs a 1s timeout: "cut" means well under 30s even on a heavily loaded host (git/python/worktree overhead is not the point)
[ "$SECONDS" -lt 25 ] && ok "…and was cut at the timeout (${SECONDS}s, not the 30s the test sleeps)" || bad "timeout did not cut the test (${SECONDS}s)"
no_leftovers "timed-out test"
S=$(mkbr s-js 'web/app.test.ts=x\n');                                        decide "$S" "";  check "a changed test with no runner (ts) stays in the gate" normal "cannot run"
S=$(mkbr s-many 'tests/1.selftest.sh=exit 0\n' 'tests/2.selftest.sh=exit 0\n' 'tests/3.selftest.sh=exit 0\n')
decide "$S" "" GATE_FASTLANE_TEST_MAX_FILES=2;  check "more tests than the cap stays in the gate" normal "exceeds"
S=$(mkbr s-deltest -tests/test_base.selftest.sh);                            decide "$S" "";  check "deleting a test: nothing to run, test-only → fast" fast
S=$(mkbr s-notests 'tests/x.selftest.sh=exit 0\n');                          decide "$S" "" GATE_FASTLANE_RUN_TESTS=0;  check "tests changed but running them is disabled" normal "disabled"
# 4d. third states
S=$(mkbr s-docs2 'docs/z.md=hello\n')
decide "$S" "packs/x/quality-gate-foo.sh";                                   check "a gate policy file in the diff (self-protection)" normal "self-protection"
decide "$S" "" GATE_FASTLANE_ENABLED=0;                                      check "kill-switch GATE_FASTLANE_ENABLED=0" normal "disabled"
touch "$T/fastlane.off"
decide "$S" "" GATE_FASTLANE_OFF_FILE="$T/fastlane.off";                     check "kill-switch FLAG FILE present (no launchd reload needed)" normal "flag file"
decide "$S" "" GATE_FASTLANE_OFF_FILE="$T/fastlane.absent";                  check "…and with the flag file absent the same diff is fast again" fast "DOC or TEST"
# self-protection read from the diff's OWN file list: the caller passes policy="" (as it does when ITS git call failed)
S2=$(mkbr s-pol1 'tests/quality-gate-x.selftest.sh=exit 0\n');              decide "$S2" "";  check "a test of the gate itself (path has quality-gate), caller passed NO policy" normal "POLICY"
S2=$(mkbr s-pol2 'tests/gate-fastlane-y.selftest.sh=exit 0\n');             decide "$S2" "";  check "a test of the FAST LANE itself" normal "POLICY"
S2=$(mkbr s-pol3 'docs/gate-lane-notes.md=hello\n');                        decide "$S2" "";  check "a doc named for the lane's own files" normal "POLICY"
S2=$(mkbr s-pol4 'docs/review-merge-policy.md=rules\n');                    decide "$S2" "";  check "the review/merge policy doc" normal "POLICY"
FL_BASE=no-such-ref decide "$S" "";                                          check "git cannot diff (bad base ref) — unreadable is not empty" normal "failed"
decide "$BASE_SHA" "";                                                       check "empty diff (head == base)" normal "no files"
mkdir -p "$T/libonly"; cp "$LIB" "$T/libonly/"
FL_LIB_OVERRIDE="$T/libonly/gate-fastlane.lib.sh" decide "$S" "";            check "scanner missing next to the lib — unverified is not clean" normal "could not run"
S=$(mkbr s-bin 'docs/bin.md=a\0b\n');                                        decide "$S" "";  check "a binary file named .md (cannot be scanned)" normal "could not run"
git -C "$REPO" checkout -q -b s-link main; ln -s ../app/main.py "$REPO/docs/link.md"; git -C "$REPO" add docs/link.md; git -C "$REPO" commit -q -m link
S=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
decide "$S" "";                                                              check "a symlink named .md (points at code)" normal "symlink"
S=$(mkbr s-delcode -app/main.py 'docs/z2.md=x\n');                           decide "$S" "";  check "deleting a CODE file next to a doc" normal "CODE"
git -C "$REPO" checkout -q -b s-rename main; git -C "$REPO" mv app/main.py docs/main.md; git -C "$REPO" commit -q -m rename
S=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
decide "$S" "";                                                              check "renaming a code file into a doc is still the code file" normal "CODE"
S=$(mkbr s-accent 'docs/relatório final.md=ok\n');                           decide "$S" "";  check "an accented file name is classified, not mistaken for 'quoted'" fast
S=$(mkbr s-tabname $'docs/a\tb.md=ok\n');                                    decide "$S" "";  check "a file name with a real TAB (git must quote it) is not vouched for" normal "quoting"

# ── 4f. confirm(): the diff that LANDS is the diff that was CHECKED ──────────────────────────────────────────────
# Gate round 2, blocking issue 2: the lane judged $BRANCH_SHA, but the merge pushes whatever origin/$BRANCH is when the
# push runs (do_merge_ff re-resolves it) — a commit added after the decision would have merged with zero reviewers and no
# scan, and the old selftest line that claimed otherwise only grepped the call's argument text. gate_fastlane_confirm is
# asked, immediately before the push, about the exact commit being pushed. Every case below takes a REAL decision first,
# then moves the tip / rebases / merges / flips the kill-switch / swaps a file for a symlink, and asks again.
# SLICE NOTE (ga-atsahv.2 of 3 — replaced by ga-atsahv.3): the record and the tally are not in this slice, so e2e_case below
# checks the DECISION's code only; slice 3 brings §4e back, where the same call also runs the real record and the real tally.
head_of() { git -C "$REPO" rev-parse "$1"; }
e2e_case() { # <name> <want_code> <head> <policy> [ENV=VAL ...]
  local name="$1" want="$2" head="$3" policy="$4"; shift 4
  decide "$head" "$policy" "$@"
  if [ "$D_CODE" = "$want" ]; then ok "e2e: $name → code=$want"
  else bad "e2e: $name → code='$D_CODE'; want code=$want (reason: $D_REASON)"; fi
}
# ── 4e'. an EMPTY diff text for a non-empty file list is "read nothing", not "clean" (gate round 3, low finding) ────────
# The scanner is a pure function and rightly calls empty input clean (§1). The lib is not: it only scans after `diff --raw` listed files, and a real
# `git diff -U0` prints a `diff --git` header for every one of them. A runner that returns 0 with NO text for that range read nothing — and "nothing
# read" must not share a value with "nothing to flag" (error and empty are different states; the inert one is the normal gate).
echo "── 4e'. empty diff text for a non-empty file list = read nothing, never clean ──"
null_scan() { # <head> [lib] -> "<lane>|<reason code>" from the real decide, with a git runner that answers `diff -U0` with success and NO output
  fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="${2:-$LIB}" FL_REPO="$REPO" FL_HEAD="$1" "$B32" -c '
    set -euo pipefail
    source "$FL_LIB"
    nogit() { case " $* " in *" -U0 "*) return 0 ;; esac; git -C "$FL_REPO" "$@"; }
    gate_fastlane_decide nogit main "$FL_HEAD" ""
    printf "%s|%s\n" "$GATE_LANE" "$GATE_LANE_REASON_CODE"
  ' 2>&1 | tail -1
}
NS_OUT=$(null_scan "$(head_of s-docs)")
[ "$NS_OUT" = "normal|scan-failed" ] && ok "a diff -U0 that succeeds with no text for a docs-only branch → normal gate, scan-failed (not a clean scan)" || bad "empty diff text for a listed file read as '$NS_OUT' (want normal|scan-failed)"
NS_CTL=$(fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="$LIB" FL_REPO="$REPO" FL_HEAD="$(head_of s-docs)" "$B32" -c '
  set -euo pipefail
  source "$FL_LIB"
  realgit() { git -C "$FL_REPO" "$@"; }
  gate_fastlane_decide realgit main "$FL_HEAD" ""
  printf "%s|%s\n" "$GATE_LANE" "$GATE_LANE_REASON_CODE"' 2>&1 | tail -1)
case "$NS_CTL" in fast\|*) ok "control: the same branch with the real git is still fast" ;; *) bad "control: the docs-only branch with the real git read '$NS_CTL'" ;; esac

echo "── 4f. gate_fastlane_confirm: what lands is what was decided ──"
REPO_MAIN="$REPO"; REPO="$T/repo2"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO"; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t; git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/app" "$REPO/docs" "$REPO/tests"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$REPO/docs/a.md"; echo 'print(1)' > "$REPO/app/main.py"; echo 'exit 0' > "$REPO/tests/test_base.selftest.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m base
M0_R2=$(git -C "$REPO" rev-parse HEAD)
mkon() { # mkon <base-ref> <new-branch> <spec>... (spec as in mkbr) -> prints the tip sha
  local base="$1" br="$2" s p c; shift 2
  git -C "$REPO" checkout -q -b "$br" "$base" || return 1
  for s in "$@"; do
    case "$s" in
      -*) git -C "$REPO" rm -q -- "${s#-}" ;;
      LINK:*) p="${s#LINK:}"; mkdir -p "$REPO/$(dirname "${p%%=*}")"; ln -s "${p#*=}" "$REPO/${p%%=*}"; git -C "$REPO" add -- "${p%%=*}" ;;
      *=*) p="${s%%=*}"; c="${s#*=}"; mkdir -p "$REPO/$(dirname "$p")"; printf '%b' "$c" > "$REPO/$p"; git -C "$REPO" add -- "$p" ;;
    esac
  done
  git -C "$REPO" commit -q -m "$br" || return 1
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
}
FA=$(mkon main fa 'docs/new.md=hello\n')                                   # the branch the lane decides on: docs only
FB_PY=$(mkon fa fb-py 'app/x.py=print(2)\n')                               # …then one more commit adds code
FB_DOC=$(mkon fa fb-doc 'docs/second.md=world\n')                          # …or one more, harmless-looking doc (no test/scan ever saw it)
FB_CPF=$(mkon fa fb-cpf 'docs/c.md=cliente 529.982.247-25 ligou\n')        # …or a doc carrying a CPF
FC=$(mkon main fc "docs/a.md=l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8-edited\n")     # edits the BOTTOM of an existing doc
FT=$(mkon main ft 'tests/ok.selftest.sh=exit 0\n')                        # a test that is run at decision time
FT_EDIT=$(mkon ft ft-edit 'tests/ok.selftest.sh=exit 3\n')                # …and edited afterwards
FW=$(mkon main fw 'tests/w.selftest.sh=[ "a  b" = "a  b" ]\n')            # whitespace inside a test
FW_EDIT=$(mkon fw fw-edit 'tests/w.selftest.sh=[ "a b" = "a b" ]\n')      # …changed by whitespace only
FS_REG=$(mkon main fs-reg 'docs/l.md=../app/main.py')                      # a regular file…
FS_LNK=$(mkon main fs-lnk 'LINK:docs/l.md=../app/main.py')                 # …and a SYMLINK with the very same content
# main moves on: an unrelated code commit, then a doc commit that inserts a line at the TOP of docs/a.md
git -C "$REPO" checkout -q main
echo 'print(99)' > "$REPO/app/main.py"; git -C "$REPO" commit -q -am 'main moves: app'
printf 'top\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$REPO/docs/a.md"; git -C "$REPO" commit -q -am 'main moves: docs/a.md grows at the top'
git -C "$REPO" checkout -q -b fa-rb fa  && git -C "$REPO" rebase -q main && FA_RB=$(git -C "$REPO" rev-parse HEAD) && git -C "$REPO" checkout -q main
git -C "$REPO" checkout -q -b fc-rb fc  && git -C "$REPO" rebase -q main && FC_RB=$(git -C "$REPO" rev-parse HEAD) && git -C "$REPO" checkout -q main
git -C "$REPO" checkout -q -b fa-mg fa  && git -C "$REPO" merge -q --no-edit main && FA_MG=$(git -C "$REPO" rev-parse HEAD) && git -C "$REPO" checkout -q main
MAIN2=$(git -C "$REPO" rev-parse main)
[ -n "${FA_RB:-}" ] && [ -n "${FC_RB:-}" ] && [ -n "${FA_MG:-}" ] && ok "premise: main moved twice and the branches were rebased / merged cleanly onto it" || bad "premise broken: rebase/merge setup failed"

C_L0=""; C_DIG0=""; C_RC=""; C_CODE=""; C_L1=""; C_WHY=""
dconf() { # dconf <decide-head|""> <confirm-base> <confirm-head> [ENV=VAL ...] -> C_L0 C_DIG0 C_RC C_CODE C_L1 C_WHY
  local dh="$1" cb="$2" ch="$3" out; shift 3
  out=$(fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="${FL_LIB_OVERRIDE:-$LIB}" FL_REPO="$REPO" FL_DH="$dh" FL_CB="$cb" FL_CH="$ch" "$@" "$B32" -c '
    set -euo pipefail
    source "$FL_LIB"
    gfn() { git -C "$FL_REPO" "$@"; }
    if [ -n "$FL_DH" ]; then gate_fastlane_decide gfn main "$FL_DH" ""; fi
    printf "%s\n%s\n" "${GATE_LANE:-}" "${GATE_LANE_DIGEST:+set}"
    [ -n "${FL_TOUCH:-}" ] && : > "$FL_TOUCH"
    c_rc=0; gate_fastlane_confirm gfn "$FL_CB" "$FL_CH" || c_rc=$?
    printf "%s\n%s\n%s\n%s\n" "$c_rc" "${GATE_LANE_CONFIRM_CODE:-}" "${GATE_LANE:-}" "${GATE_LANE_CONFIRM_WHY:-}"
  ' 2>"$T/conf.err") || { C_L0="ABORTED"; C_DIG0=""; C_RC=""; C_CODE=""; C_L1=""; C_WHY="aborted under set -euo pipefail: $(tr '\n' ' ' < "$T/conf.err")"; return; }
  C_L0=$(printf '%s\n' "$out" | sed -n 1p); C_DIG0=$(printf '%s\n' "$out" | sed -n 2p); C_RC=$(printf '%s\n' "$out" | sed -n 3p)
  C_CODE=$(printf '%s\n' "$out" | sed -n 4p); C_L1=$(printf '%s\n' "$out" | sed -n 5p); C_WHY=$(printf '%s\n' "$out" | sed -n 6p)
}
conf_check() { # name want_rc want_code [needle-in-why]
  if [ "$C_L0" = "ABORTED" ]; then bad "confirm: $1 — $C_WHY"; return; fi
  # want_code "*" = any non-empty code (the cause may legitimately be reported under either of two names)
  if [ "$C_RC" = "$2" ] && { [ "$C_CODE" = "$3" ] || { [ "$3" = "*" ] && [ -n "$C_CODE" ]; }; }; then ok "confirm: $1 → rc=$2${3:+ code=$C_CODE}"; else bad "confirm: $1 → rc=$C_RC code='$C_CODE' ($C_WHY), want rc=$2 code='$3'"; fi
  if [ "$2" = "0" ]; then [ "$C_L1" = "fast" ] && ok "confirm: $1 — the lane is still fast" || bad "confirm: $1 — lane after a yes is '$C_L1'"
  else [ "$C_L1" = "normal" ] && ok "confirm: $1 — the lane is NORMAL afterwards (a no can never leave 'fast' behind)" || bad "confirm: $1 — lane after a no is '$C_L1', want normal"; fi
  if [ -n "${4:-}" ]; then case "$C_WHY" in *"$4"*) ok "confirm: $1 — says '$4'" ;; *) bad "confirm: $1 — expected '$4' in: $C_WHY" ;; esac; fi
}
dconf "$FA" main "$FA";
[ "$C_L0" = "fast" ] && [ "$C_DIG0" = "set" ] && ok "premise: the decision on the docs-only branch is fast AND records the fingerprint of the diff it checked" || bad "premise: decide → lane=$C_L0 digest=$C_DIG0 ($C_WHY)"
conf_check "the tip did not move (the common case)" 0 ""
dconf "$FA" main "$FB_PY";   conf_check "the gate's reproduction: a .py commit lands on the branch after the decision" 1 diff-changed "not the diff"
dconf "$FA" main "$FB_DOC";  conf_check "…a second, harmless-looking doc after the decision (no scan and no test ever ran on it)" 1 diff-changed
dconf "$FA" main "$FB_CPF";  conf_check "…a doc carrying a CPF after the decision" 1 diff-changed
case "$C_WHY" in *529.982*|*52998224725*) bad "the revocation reason published the CPF: $C_WHY" ;; *) ok "…and the revocation reason never carries the value" ;; esac
dconf "$FA" "$MAIN2" "$FA_RB"; conf_check "a pure rebase onto the moved main (the merge-time rebase) is the same change" 0 ""
dconf "$FA" "$MAIN2" "$FA_MG"; conf_check "a merge of the moved main into the branch (the ga-qukyp fallback shape) is the same change" 0 ""
dconf "$FC" "$MAIN2" "$FC_RB"; conf_check "a rebase that shifts every hunk's line numbers (main grew docs/a.md at the top) is the same change" 0 ""
dconf "$FT" main "$FT_EDIT";   conf_check "a test edited after it ran green" 1 diff-changed
dconf "$FW" main "$FW_EDIT";   conf_check "a whitespace-only change inside a test (patch-id would call it equal)" 1 diff-changed
dconf "$FS_REG" main "$FS_LNK"; conf_check "the same bytes, but a SYMLINK now (the mode is part of the fingerprint)" 1 "*"
dconf "$FA" main "$FA" GATE_FASTLANE_OFF_FILE="$T/flip.off" FL_TOUCH="$T/flip.off"; conf_check "the operator switches the lane off AFTER the decision (flag file)" 1 switched-off "flag file"
rm -f "$T/flip.off"
dconf "" main "$FA";            conf_check "no decision on record in this run → cannot confirm" 1 cannot-confirm "no fast-lane decision"
dconf "$FA" no-such-ref "$FA";  conf_check "git cannot diff the commit that would land (bad base) — unreadable is not 'unchanged'" 1 cannot-confirm
dconf "$FA" main "";            conf_check "no commit to confirm" 1 cannot-confirm
dconf "$FB_PY" main "$FB_PY";   # a decision that was NORMAL (code) leaves nothing to confirm
[ "$C_L0" = "normal" ] && [ -z "$C_DIG0" ] && ok "a normal decision records NO fingerprint (nothing for a later confirm to wrongly accept)" || bad "normal decision: lane=$C_L0 digest='$C_DIG0'"
conf_check "confirming after a NORMAL decision is refused" 1 cannot-confirm
REPO="$REPO_MAIN"

# ── 4g. a read that cannot answer is "could not tell" — the inert arm — never "none", "clean" or "on" ──────────────
# Gate round 6. The reviewer's blocker: gate_fastlane_classify_raw asked gate_fastlane_test_runner what to do with a changed test and had arms for
# bash|pytest and unknown ONLY, so an EMPTY answer (the substitution failing) fell through exactly like the real answer "none" (an inert fixture): the test
# landed in neither RUN nor UNRUNNABLE, run_tests said "no test entry to run", and the lane was granted on a test nobody ran. The re-arm asked for the CLASS,
# not the instance, so every lookup the lane makes is exercised the same way: ONE lookup (or the tool under it) is made to answer nothing / garbage / an error,
# through the REAL decision on REAL git, and the outcome must be the normal gate WITH a reason that says it could not tell. Each case goes red against the
# lib of 49addf4ad (the round-5 head) — the claim is "these fail before", not "these pass after".
echo "── 4g. every lookup that cannot answer lands in the inert arm (gate round 6: the class, not the instance) ──"
stub_decide() { # <head> <stub shell code, run after the lib is sourced> [ENV=VAL ...] -> "<lane>|<reason code>|<reason>" (or ABORTED|aborted|… when the decision died)
  local head="$1" stub="$2" out rc=0; shift 2
  out=$(fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="${FL_LIB_OVERRIDE:-$LIB}" FL_REPO="$REPO" FL_HEAD="$head" FL_STUB="$stub" "$@" "$B32" -c '
    set -euo pipefail
    source "$FL_LIB"
    eval "$FL_STUB"
    gfn() { git -C "$FL_REPO" "$@"; }
    gate_fastlane_decide gfn main "$FL_HEAD" ""
    printf "%s|%s|%s\n" "$GATE_LANE" "$GATE_LANE_REASON_CODE" "$GATE_LANE_REASON"
  ' 2>&1) || rc=$?
  if [ "$rc" != "0" ]; then printf 'ABORTED|aborted|rc=%s: %s\n' "$rc" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 0; fi
  printf '%s\n' "$out" | tail -1
}
sd_case() { # <name> <head> <stub> <want_lane> <want_code> <needle-in-reason|""> [ENV=VAL ...]
  local name="$1" head="$2" stub="$3" wl="$4" wc="$5" needle="$6" out lane rest code reason; shift 6
  out=$(stub_decide "$head" "$stub" "$@")
  lane="${out%%|*}"; rest="${out#*|}"; code="${rest%%|*}"; reason="${rest#*|}"
  if [ "$lane" = "$wl" ] && [ "$code" = "$wc" ]; then ok "$name → $wl/$wc"; else bad "$name → lane=$lane code=$code, want $wl/$wc — $reason"; fi
  if [ -n "$needle" ]; then case "$reason" in *"$needle"*) ok "$name: the reason says '$needle'" ;; *) bad "$name: expected '$needle' in: $reason" ;; esac; fi
}
chk_code() { # <name> <want_lane> <want_code> [needle-in-reason] — on the last decide()
  if [ "$D_LANE" = "$2" ] && [ "$D_CODE" = "$3" ]; then ok "$1 → $2/$3"; else bad "$1: lane=$D_LANE code=$D_CODE, want $2/$3 — $D_REASON"; fi
  if [ -n "${4:-}" ]; then case "$D_REASON" in *"$4"*) ok "$1: the reason says '$4'" ;; *) bad "$1: expected '$4' in: $D_REASON" ;; esac; fi
}
S_D=$(head_of s-docs); S_TO=$(head_of s-testok)
S_T2=$(mkbr s-g6-tests 'tests/test_core.py=x = 1\n' 'tests/foo.test.js=x\n')    # the reviewer's own pair: a python test and a js test
S_FX=$(mkbr s-g6-fixture 'tests/fixtures/data.json={}\n')                        # an inert fixture: the real lookup says `none`
# (a) the runner lookup — the blocker itself
sd_case "runner lookup answers NOTHING (the reviewer's tests/test_core.py + tests/foo.test.js)" "$S_T2" 'gate_fastlane_test_runner() { :; }' normal unclassifiable "could not tell how to run"
sd_case "runner lookup answers NOTHING (one changed test)"        "$S_TO" 'gate_fastlane_test_runner() { :; }'        normal unclassifiable "could not tell how to run"
sd_case "runner lookup answers GARBAGE"                           "$S_TO" 'gate_fastlane_test_runner() { echo banana; }' normal unclassifiable "'banana'"
sd_case "runner lookup FAILS (rc 7, no answer)"                   "$S_TO" 'gate_fastlane_test_runner() { return 7; }' normal unclassifiable "could not tell how to run"
sd_case "control: a fixture whose lookup SAYS 'none' is still granted — 'none' is an answer, an empty one is not" "$S_FX" '' fast fast "DOC or TEST"
sd_case "control: the same two tests with the REAL lookup go to the gate because the js one has no runner" "$S_T2" '' normal test-unrunnable "cannot run"
# (a') the lookup's OWN default. `none` (nothing to run, still granted) is a POSITIVE list of data extensions; the first version listed the executable
# languages it knew and answered `none` for the rest, so a test in a language nobody listed — or a helper script — was granted without being run.
rn() { "$B32" -c 'source "$1"; gate_fastlane_test_runner "$2"' _ "$LIB" "$1"; }
runner_case() { # <want> <path>...
  local want="$1" p got; shift
  for p in "$@"; do got=$(rn "$p"); if [ "$got" = "$want" ]; then ok "runner: $want  $p"; else bad "runner: $p → '$got', want $want"; fi; done
}
runner_case bash    tests/x.selftest.sh tests/run.test.sh tests/test_a.sh tests/a_test.sh
runner_case pytest  tests/test_a.py tests/a_test.py tests/x.selftest.py
runner_case none    tests/fixtures/data.json tests/fixtures/a.YML tests/golden/out.txt tests/x.snap tests/img/a.png tests/f.csv
runner_case unknown web/app.test.ts tests/test_widget.lua tests/helpers/setup.sh tests/conftest.py tests/run.pl tests/fixtures/NOEXT tests/Makefile tests/foo.test.R tests/e2e.spec.zsh
S_LUA=$(mkbr s-g6-lua 'tests/test_widget.lua=print(1)\n');           sd_case "a changed test in a language nobody listed (lua) is not 'none': it goes to the gate, unrun" "$S_LUA" '' normal test-unrunnable "cannot run"
S_HLP=$(mkbr s-g6-helper 'tests/helpers/setup.sh=echo hi\n');       sd_case "a helper script under tests/ is not an inert fixture" "$S_HLP" '' normal test-unrunnable "cannot run"
# classify asks (for the history's files and for the tip's) and run_tests asks again, for the same file: an answer that vanishes in run_tests must not be a pass (pins run_tests' own default arm).
# The stub tells run_tests from classify by the CALL STACK, not by counting calls — how many times classify asks is not what this case is about.
sd_case "runner lookup answers in classify and then NOTHING in run_tests: rc=99, not a pass" "$S_TO" 'gate_fastlane_test_runner() { local f; for f in "${FUNCNAME[@]}"; do if [ "$f" = gate_fastlane_run_tests ]; then return 0; fi; done; echo bash; }' normal test-failed "rc=99"
# (b) the class lookup — the sibling two lines above it, which the reviewer called correct: it defaulted to CODE, i.e. to normal, but silently
sd_case "classifier answers NOTHING"     "$S_D" 'gate_fastlane_path_class() { :; }'         normal unclassifiable "could not classify"
sd_case "classifier answers GARBAGE"     "$S_D" 'gate_fastlane_path_class() { echo MAYBE; }' normal unclassifiable "'MAYBE'"
sd_case "classifier FAILS (rc 3)"        "$S_D" 'gate_fastlane_path_class() { return 3; }'   normal unclassifiable "could not classify"
# (c) a non-empty diff list from which nothing was classified: "every file is DOC or TEST" is vacuously true of zero files
raw_case "a non-empty list of blank records (nothing classified)" unclassifiable any $'\n\n'
# the mode `case` named the two BAD modes and let everything else through: an unknown mode passed as "a regular file"
raw_case "an unknown file mode (100664)"                    unclassifiable any "$(rec 000000 100664 A docs/a.md)"
raw_case "a tree entry (mode 040000)"                       unclassifiable any "$(rec 000000 040000 A docs/sub)"
raw_case "control: a 100755 test among docs is still classified" ok 0 "$(rec 000000 100644 A docs/a.md)"$'\n'"$(rec 000000 100755 A tests/x.selftest.sh)"
# (d) the success path's record of the files that decided the grant
sd_case "the success path cannot render the files that decided: a grant that cannot name them is not a grant" "$S_D" '_gate_fastlane_cap_lines() { :; }' normal unclassifiable "could not render"
FO_BAD=$("$B32" -c 'source "$1"; tr() { return 1; }; GATE_LANE_FILES=$(printf "DOC\tdocs/a.md\n"); gate_fastlane_files_oneline' _ "$LIB")
case "$FO_BAD" in *"could not be rendered"*) ok "files_oneline: a rendering that failed says so — it does not read as 'no file decided this lane'" ;; *) bad "files_oneline with a failing tr answered '$FO_BAD'" ;; esac
FO_OK=$("$B32" -c 'source "$1"; GATE_LANE_FILES=$(printf "DOC\tdocs/a.md\n"); gate_fastlane_files_oneline' _ "$LIB")
[ "$FO_OK" = "DOC:docs/a.md" ] && ok "control: files_oneline renders the list when tr works" || bad "files_oneline control answered '$FO_OK'"
# (e) the scanner: a python that dies at IMPORT time exits 1, which is the contract's "findings" (blocker 2)
SCANLIB=""
mk_scan_lib() { # <name> <python source> -> SCANLIB: a copy of the lib with a scanner of our own next to it
  local d="$T/scanlib-$1"; mkdir -p "$d"; cp "$LIB" "$d/gate-fastlane.lib.sh"; printf '%s\n' "$2" > "$d/gate-fastlane-scan.py"; SCANLIB="$d/gate-fastlane.lib.sh"
}
# the reviewer's own repro: the REAL scanner with one line in front of it that raises at module level
mk_scan_lib import-raise "$(printf 'raise RuntimeError("boom at import")\n'; cat "$SCAN")"; SL_IMPORT="$SCANLIB"
FL_LIB_OVERRIDE="$SL_IMPORT" decide "$S_D" "";  chk_code "a scanner that raises at import time (python exits 1)" normal scan-failed "it crashed"
case "$D_REASON $D_FILES" in *Traceback*|*'File "'*|*"$T"*) bad "a traceback / an absolute path reached the lane's reason or files (marker metadata): $D_REASON | $D_FILES" ;; *) ok "…and no traceback or absolute path reaches the reason or the files (they are written into marker metadata)" ;; esac
case "$D_REASON" in *"found personal data"*) bad "a dead scanner was reported as 'found personal data': $D_REASON" ;; *) ok "…and a dead scanner is NOT reported as 'found personal data'" ;; esac
mk_scan_lib import-syntax $'def (:\n';                                                        FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "a scanner with a syntax error (python exits 1)" normal scan-failed "it crashed"
mk_scan_lib rc1-garbage $'import sys\nprint("hello world")\nsys.exit(1)\n';                     FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "exit 1 with a line that is not a finding" normal scan-failed "it crashed"
mk_scan_lib rc1-empty $'import sys\nsys.exit(1)\n';                                            FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "exit 1 with NO findings (an empty list is not a list of findings)" normal scan-failed "it crashed"
mk_scan_lib rc1-mixed $'import sys\nprint("numero-longo\\tdocs/x.md\\t3")\nprint("Traceback junk")\nsys.exit(1)\n'; FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "exit 1 with one finding and one stray line (every line must be a finding)" normal scan-failed "it crashed"
mk_scan_lib rc0-output $'import sys\nprint("numero-longo\\tdocs/x.md\\t1")\nsys.exit(0)\n';  FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "exit 0 that printed output is not a clean answer" normal scan-failed "not a clean answer"
mk_scan_lib rc2-msg $'import sys\nprint("diff is not valid UTF-8", file=sys.stderr)\nsys.exit(2)\n'; FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "control: exit 2 is 'could not scan', with the scanner's own message" normal scan-failed "not valid UTF-8"
mk_scan_lib rc1-valid $'import sys\nprint("numero-longo\\tdocs/x.md\\t3")\nsys.exit(1)\n';    FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "control: exit 1 with a well-formed finding IS scan-findings" normal scan-findings "numero-longo×1"
mk_scan_lib rc0-clean $'import sys\nsys.exit(0)\n';                                           FL_LIB_OVERRIDE="$SCANLIB" decide "$S_D" "";  chk_code "control: exit 0 with no output IS a clean scan" fast fast
e2e_case "a scanner that dies at import is booked as scan-failed, not as personal data (was: scan-findings)" scan-failed "$S_D" "" FL_LIB_OVERRIDE="$SL_IMPORT"
# (f) the digest: a `sed` that failed must not hand back the digest of an empty stream
DGF="$T/dg.diff"; printf 'diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n@@ -0,0 +1 @@\n+hello\n' > "$DGF"
cp "$DGF" "$T/dg-unreadable.diff"; chmod 000 "$T/dg-unreadable.diff"
dg_out() { FL_REPO="$REPO" "$B32" -c 'set -u; source "$1"; gfn() { git -C "$FL_REPO" "$@"; }; if out=$(_gate_fastlane_digest_file gfn "$2"); then echo "rc=0 digest=[$out]"; else echo "rc=1 digest=[]"; fi' _ "$LIB" "$1"; }
case "$(dg_out "$DGF")" in "rc=0 digest=["????????*) ok "control: a readable diff has a digest" ;; *) bad "control: digest of a readable diff: $(dg_out "$DGF")" ;; esac
if [ -r "$T/dg-unreadable.diff" ]; then ok "(skipped: this user can read a mode-000 file, so the unreadable-diff case cannot be staged)"
else
  [ "$(dg_out "$T/dg-unreadable.diff")" = "rc=1 digest=[]" ] && ok "a diff file that cannot be READ has NO digest — not the digest of an empty stream (the caller here has no pipefail)" || bad "an unreadable diff produced: $(dg_out "$T/dg-unreadable.diff")"
fi
chmod 600 "$T/dg-unreadable.diff"
# (g) the PATH filter with HOME unknown, and the clock
TP_UNSET=$(env -i PATH="$T/fakehome/.local/bin:/usr/bin:/bin" "$B32" -c 'source "$1"; _gate_fastlane_test_path' _ "$LIB")
case "$TP_UNSET" in *fakehome*) bad "HOME unset: the PATH filter passed every entry through ($TP_UNSET) — 'cannot tell where HOME is' read as 'nothing is under it'" ;; *) ok "HOME unset: the tests' PATH is the system dirs alone, not the caller's whole PATH ($TP_UNSET)" ;; esac
TP_SET=$(env -i HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:/usr/bin:/bin" "$B32" -c 'source "$1"; _gate_fastlane_test_path' _ "$LIB")
[ "$TP_SET" = "/usr/bin:/bin" ] && ok "control: HOME set → the entry under it is dropped and the rest kept" || bad "PATH filter with HOME set answered '$TP_SET'"
mkdir -p "$T/baddate"; printf '#!/bin/sh\nexit 1\n' > "$T/baddate/date"; chmod +x "$T/baddate/date"
decide "$S_TO" "" PATH="$T/baddate:$PATH";  chk_code "the clock cannot be read (date fails): the test budget cannot be enforced, so no test runs and the lane is not granted" normal test-failed "could not read the clock"
mkdir -p "$T/flakydate"; rm -f "$T/date-state"
printf '#!/bin/sh\nif [ -e "%s" ]; then exit 1; fi\n: > "%s"\nexec /bin/date "$@"\n' "$T/date-state" "$T/date-state" > "$T/flakydate/date"; chmod +x "$T/flakydate/date"
decide "$(head_of s-stdin)" "" PATH="$T/flakydate:$PATH";  chk_code "the clock reads once and then fails: that is the budget SPENT, not 'no time has passed'" normal test-failed "budget"
rm -f "$T/date-state"
# (h) the kill switch whose LOCATION is unknown: neither GC_CITY nor GATE_FASTLANE_OFF_FILE
S_D2=$(head_of s-docs2)
decide "$S_D2" "" GATE_FASTLANE_OFF_FILE=;  chk_code "no GC_CITY and no off-file path: the kill switch cannot be found, so the lane is off" normal switch-unreadable "kill switch"
mkdir -p "$T/city-ok/.gc"
decide "$S_D2" "" GATE_FASTLANE_OFF_FILE= GC_CITY="$T/city-ok";  chk_code "control: GC_CITY set and no flag file in it → the lane is on" fast fast
: > "$T/city-ok/.gc/gate-fastlane.off"
decide "$S_D2" "" GATE_FASTLANE_OFF_FILE= GC_CITY="$T/city-ok";  chk_code "control: GC_CITY set and the flag file there → off, as before" normal flag-file
rm -f "$T/city-ok/.gc/gate-fastlane.off"
e2e_case "kill switch whose location is unknown" switch-unreadable "$S_D2" "" GATE_FASTLANE_OFF_FILE=

# ── 4h. the lane decides on what the push PUBLISHES: every commit, messages included (gate round ga-aa8n6z; Mayor re-scope 11/10) ──────────
# The scan used to read the NET diff (base...head) and the classifier the net file list, while the merge is a fast-forward that publishes EVERY commit
# of base..head. So a CPF pasted in one commit and deleted in the next, or a production file added and removed again, was invisible to the lane and sat
# in main's history with zero reviewers (the reviewer reproduced it with a CPF + phone, 2 commits, net diff = one harmless line). Every case below is a
# REAL branch of several commits, a REAL decision, and — where it matters — the REAL record and tally; each "was fast" case is also run against a mutant
# lib/scanner that lacks the new check (§8t-8x), so the claim is "this goes red without the fix", not "this passes with it".
# (SLICE NOTE, ga-atsahv.2 — replaced by ga-atsahv.3: the record, the tally and the §8 mutant runs arrive with slice 3. In THIS slice the cases below prove the
# decision and its reason code; the "run against a mutant" claim is slice 3's to make, and one mutant is already here, in §4h' — the confirm without its digest test.)
echo "── 4h. history: the lane reads every commit the push publishes (the net diff is not what lands) ──"
mkseq_on() { # mkseq_on <base-ref> <branch> <spec>... — one commit per group; spec as mkbr, plus MSG:<message> (for the commit being built) and `--` (ends a commit)
  local base="$1" br="$2" s p c msg="$2" n=1; shift 2
  git -C "$REPO" checkout -q -b "$br" "$base" || return 1
  for s in "$@"; do
    case "$s" in
      --)     git -C "$REPO" commit -q -m "$msg" || return 1; n=$((n + 1)); msg="$br c$n" ;;
      MSG:*)  msg="${s#MSG:}" ;;
      -*)     git -C "$REPO" rm -q -- "${s#-}" ;;
      *=*)    p="${s%%=*}"; c="${s#*=}"; mkdir -p "$REPO/$(dirname "$p")"; printf '%b' "$c" > "$REPO/$p"; git -C "$REPO" add -- "$p" ;;
    esac
  done
  git -C "$REPO" commit -q -m "$msg" || return 1
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" checkout -q main
}
mkseq() { mkseq_on main "$@"; }

# (a) the reviewer's own reproduction: commit 1 pastes a CPF + a phone into docs/a.md, commit 2 deletes the line. The NET diff is one harmless added line.
S_H1=$(mkseq h-cpf 'docs/a.md=base\nlead: Maria CPF 123.456.789-09 tel (31) 99999-8888\n' -- 'docs/a.md=base\nok line\n')
[ "$(git -C "$REPO" diff -U0 main...h-cpf | grep -c -E '^\+[^+]')" = "1" ] && ok "premise: the NET diff of the reproduction adds exactly one line (the harmless one)" || bad "premise broken: the net diff of h-cpf is not one added line"
[ "$(git -C "$REPO" log -p main..h-cpf | grep -c '123.456.789-09')" -ge "2" ] && ok "premise: the CPF IS in the history the push would publish (git log -p shows it)" || bad "premise broken: the CPF is not in the branch's history"
decide "$S_H1" "";  chk_code "a CPF + phone added in commit 1 and removed in commit 2 (net diff harmless) is a FINDING, not 'fast'" normal scan-findings "numero-longo"
case "$D_FILES" in *":docs/a.md:"*) ok "…and the finding names the COMMIT and the file (<sha9>:docs/a.md), so the author knows where to look" ;; *) bad "the finding does not name the commit: $D_FILES" ;; esac
case "$D_REASON $D_FILES" in *123.456*|*12345678909*|*99999-8888*) bad "the history finding published the CPF/phone: $D_REASON | $D_FILES" ;; *) ok "…and never carries the value" ;; esac
S_H1B=$(mkseq h-cpf-ok 'docs/a.md=base\nok line\n' -- 'docs/a.md=base\nok line\nsecond line\n');  decide "$S_H1B" "";  check "control: the same two-commit shape with nothing to hide is fast" fast "2 commit(s)"
# (b) a production file added in commit 1 and deleted in commit 2, next to a doc: the tip is DOC-only, the history is not
S_H2=$(mkseq h-code 'app/tmp.py=print(2)\n' -- '-app/tmp.py' 'docs/new.md=hello\n')
decide "$S_H2" "";  chk_code "a .py added in commit 1 and removed in commit 2 (tip: one doc) stays in the gate" normal history-code "stay in main's history"
case "$D_FILES" in *"app/tmp.py"*) ok "…and the files that decided name it (HISTORY:CODE:app/tmp.py)" ;; *) bad "history-code does not name the file: $D_FILES" ;; esac
S_H2B=$(mkseq h-code2 'app/main.py=print(99)\n' -- 'app/main.py=print(1)\n' 'docs/new2.md=hello\n')
decide "$S_H2B" "";  chk_code "an existing .py edited in commit 1 and restored in commit 2 (net: nothing for that file) stays in the gate" normal history-code
S_H2C=$(mkseq h-prompt 'skills/x/SKILL.md=changed\n' -- 'skills/x/SKILL.md=skill\n' 'docs/new3.md=hello\n')
decide "$S_H2C" "";  chk_code "a SKILL.md changed in commit 1 and restored in commit 2 stays in the gate (prompt text is production)" normal history-code
# the Mayor's own wording: 2 commits, the 2nd undoes the 1st — the net diff is EMPTY, which was already the normal gate (unclassifiable), and must stay so
S_H2D=$(mkseq h-undo 'app/tmp.py=print(2)\n' -- '-app/tmp.py')
decide "$S_H2D" "";  chk_code "the Mayor's case, literally: commit 2 undoes commit 1 (code) → net diff empty → not fast" normal unclassifiable "no files"
# (c) the MESSAGES are published too
S_H3=$(mkseq h-msg 'MSG:docs: ligar para (31) 99999-8888' 'docs/n.md=hello\n')
decide "$S_H3" "";  chk_code "a phone number in a commit MESSAGE is a finding" normal scan-findings "numero-longo"
case "$D_FILES" in *"commit-message"*) ok "…reported as <sha9>:commit-message" ;; *) bad "message finding not named: $D_FILES" ;; esac
S_H3B=$(mkseq h-msg2 $'MSG:docs: nota\n\nligar (31) 99999-\n8888 amanha' 'docs/n.md=hello\n')
decide "$S_H3B" "";  chk_code "…also when the number is wrapped across two message lines" normal scan-findings "numero-longo"
S_H3C=$(mkseq h-msg3 $'MSG:docs: nota\n\nitem 31 9999\n\nitem 8888 fim' 'docs/n.md=hello\n')
decide "$S_H3C" "";  chk_code "control: two short numbers separated by a blank message line are not one number" fast fast
S_H3D=$(mkseq h-msg4 'MSG:docs(ga-atsahv): explain the lane — see f7f733c40 and bd ga-xnw2o3' 'docs/n.md=hello\n')
decide "$S_H3D" "";  chk_code "control: a message with a bead id and a short sha is clean" fast fast
S_H3E=$(mkseq h-msg5 'MSG:docs: runbook of the 2026-10-11 reboot' 'docs/n.md=hello\n')
decide "$S_H3E" "";  chk_code "accepted false positive (the same price as a dated file name): a date in a commit message goes to the ordinary gate" normal scan-findings "numero-longo"
S_H3F=$(mkseq h-msg6 'MSG:docs: aws key AKIAIOSFODNN7EXAMPLE pasted' 'docs/n.md=hello\n')
decide "$S_H3F" "";  chk_code "a credential in a commit message is a finding" normal scan-findings "aws-key"
# (d) a number split over two lines that DIFFERENT commits added side by side is one number only in the net diff — the net pass stays
S_H4=$(mkseq h-split 'docs/n.md=ligar (31) 9999\n' -- 'docs/n.md=ligar (31) 9999\n8888 amanha\n')
decide "$S_H4" "";  chk_code "a phone whose halves were added by two different commits (adjacent lines) is a finding" normal scan-findings "numero-longo"
# (e) controls: the shapes that are legitimately fast must stay fast, with the commit count in the reason
S_H5=$(mkseq h-ok3 'docs/a1.md=one\n' -- 'docs/a2.md=two\n' -- 'docs/a3.md=three\n');  decide "$S_H5" "";  check "control: three docs-only commits are fast" fast "3 commit(s)"
S_H5B=$(mkseq h-ok-t 'docs/a4.md=one\n' -- 'tests/ok4.selftest.sh=exit 0\n');            decide "$S_H5B" "";  check "control: a doc commit then a green-test commit is fast" fast "2 commit(s)"
S_H5C=$(mkseq h-ok-del 'docs/a5.md=x\n' -- '-docs/a5.md' 'docs/a6.md=y\n');               decide "$S_H5C" "";  check "control: a doc added and removed again (harmless text) is still fast" fast
# (f) the cap: a branch of N commits above GATE_FASTLANE_COMMIT_MAX is a job for a reviewer
decide "$S_H5" "" GATE_FASTLANE_COMMIT_MAX=2;  chk_code "3 commits over a cap of 2 stay in the gate" normal history-unverified "cap of 2"
decide "$S_H5" "" GATE_FASTLANE_COMMIT_MAX=3;  chk_code "…and exactly at the cap it is fast again" fast fast
decide "$S_H5" "" GATE_FASTLANE_COMMIT_MAX=banana;  chk_code "a cap that is not a number falls back to the default (30), not to 0 or to 'no cap'" fast fast
# (g) names with adjacent non-ASCII letters (gate round ga-aa8n6z, blocking issue 2): git's default quoting turned `ção` into twelve digits
S_H6=$(mkseq h-cao 'docs/migração.md=ok\n' 'docs/integração-ões.md=ok\n' 'docs/relatório.md=ok\n')
decide "$S_H6" "";  check "a docs-only branch named with ção/ões/ório is fast (was: 'numero-longo' for a name that holds no number)" fast "DOC or TEST"
S_H6B=$(mkseq h-cao-num 'docs/relatório-52998224725.md=ok\n')
decide "$S_H6B" "";  chk_code "…and an accented name that REALLY carries a CPF is still a finding (its digits are plain ASCII)" normal scan-findings "numero-longo"
# (h) the third state, at every read the history makes. (stub_decide defines its gfn AFTER the stub, so a stub of gfn needs this own helper)
S_HG=$(head_of h-ok3)
hist_stub() { # <name> <head> <stub-body-run-after-gfn-defined> <want_code> <needle>
  local out lane code reason
  out=$(fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="$LIB" FL_REPO="$REPO" FL_HEAD="$2" FL_STUB="$3" "$B32" -c '
    set -euo pipefail
    source "$FL_LIB"
    gfn() { git -C "$FL_REPO" "$@"; }
    eval "$FL_STUB"
    gate_fastlane_decide gfn main "$FL_HEAD" ""
    printf "%s|%s|%s\n" "$GATE_LANE" "$GATE_LANE_REASON_CODE" "$GATE_LANE_REASON"
  ' 2>&1 | tail -1) || out="ABORTED|aborted|$out"
  lane="${out%%|*}"; reason="${out#*|}"; code="${reason%%|*}"; reason="${reason#*|}"
  if [ "$lane" = "normal" ] && [ "$code" = "$4" ]; then ok "$1 → normal/$4"; else bad "$1 → lane=$lane code=$code, want normal/$4 — $reason"; fi
  case "$reason" in *"$5"*) ok "$1: the reason says '$5'" ;; *) bad "$1: expected '$5' in: $reason" ;; esac
}
hist_stub "git cannot list the commits (rev-list fails)" "$S_HG" 'gfn() { case " $* " in *" rev-list "*) return 5 ;; esac; git -C "$FL_REPO" "$@"; }' history-unverified "could not list the commits"
hist_stub "git lists NO commit although the diff lists files" "$S_HG" 'gfn() { case " $* " in *" rev-list "*) return 0 ;; esac; git -C "$FL_REPO" "$@"; }' history-unverified "no commit lies"
hist_stub "git log --raw fails for the history" "$S_HG" 'gfn() { case " $* " in *" log "*"--raw"*) return 3 ;; esac; git -C "$FL_REPO" "$@"; }' history-unverified "git log --raw"
hist_stub "git log --raw answers success with NO records (the history's files were not read)" "$S_HG" 'gfn() { case " $* " in *" log "*"--raw"*) return 0 ;; esac; git -C "$FL_REPO" "$@"; }' history-unverified "cannot be classified"
hist_stub "git log -p answers success with NO text (the history was not read ≠ history clean)" "$S_HG" 'gfn() { case " $* " in *" log "*" -p "*) return 0 ;; esac; git -C "$FL_REPO" "$@"; }' scan-failed "nothing was read"
hist_stub "git log -p FAILS" "$S_HG" 'gfn() { case " $* " in *" log "*" -p "*) return 9 ;; esac; git -C "$FL_REPO" "$@"; }' scan-failed "git failed to produce the history text"
# (h2) the same class, other shapes of "in an intermediate commit and gone from the tip": a BINARY file (nothing the scanner can read), a SYMLINK (what it
# points at is not in the diff). The net diff of either shows nothing of them; the history does, and a doubt is the normal gate.
S_HB=$(mkseq h-bin 'docs/bin.md=a\0b\n' -- '-docs/bin.md' 'docs/okb.md=x\n')
decide "$S_HB" "";  chk_code "a binary file added in commit 1 and removed in commit 2 (net diff: one clean doc) cannot be scanned → not fast" normal scan-failed "binary"
git -C "$REPO" checkout -q -b h-link main; ln -s ../app/main.py "$REPO/docs/lnk.md"; git -C "$REPO" add docs/lnk.md; git -C "$REPO" commit -q -m 'link'
git -C "$REPO" rm -q docs/lnk.md; printf 'x\n' > "$REPO/docs/okl.md"; git -C "$REPO" add docs/okl.md; git -C "$REPO" commit -q -m 'unlink'
S_HL=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
decide "$S_HL" "";  chk_code "a symlink added in commit 1 and removed in commit 2 is not vouched for (history-unverified)" normal history-unverified "symlink"
# (i) merge commits: a clean one (the gate's own "merge main into the branch" fallback) adds nothing; one with a conflict resolution carries content nobody scanned
REPO_H="$REPO"; REPO="$T/repo2"
decide "$FA_MG" "";  chk_code "a branch with a CLEAN merge of main in it (the gate's ga-qukyp fallback shape; \`git show --cc\` is empty) is still fast" fast fast
git -C "$REPO" checkout -q -b cf-main "$M0_R2"; printf 'l1\nl2\nl3\nl4\nMAIN-SIDE\nl6\nl7\nl8\n' > "$REPO/docs/a.md"; git -C "$REPO" commit -q -am 'cf main side'
git -C "$REPO" checkout -q -b cf-br "$M0_R2";   printf 'l1\nl2\nl3\nl4\nBRANCH-SIDE\nl6\nl7\nl8\n' > "$REPO/docs/a.md"; git -C "$REPO" commit -q -am 'cf branch side'
git -C "$REPO" merge -q --no-edit cf-main >/dev/null 2>&1 || true
printf 'l1\nl2\nl3\nl4\nRESOLVED-BY-HAND\nl6\nl7\nl8\n' > "$REPO/docs/a.md"; git -C "$REPO" add docs/a.md; git -C "$REPO" commit -q -m 'merge cf-main (resolved by hand)'
CF_MG=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
[ "$(git -C "$REPO" rev-list --parents -n1 "$CF_MG" | wc -w | tr -d ' ')" = "3" ] && ok "premise: the conflict-resolution branch tip is a merge commit (two parents)" || bad "premise broken: cf-mg is not a merge"
FL_BASE=cf-main decide "$CF_MG" "";  chk_code "a merge commit that carries its own conflict resolution stays in the gate (content nobody scanned)" normal history-unverified "conflict resolution"
REPO="$REPO_H"
# (j) one more producer/consumer check: the two new codes go through the REAL record and the REAL tally into the bucket their code names
#     (in this slice e2e_case checks that the decision emits the code; the record and the tally that bucket it arrive with ga-atsahv.3)
e2e_case "a code file added then removed (history)"           history-code       "$S_H2"  ""
e2e_case "more commits than the cap"                           history-unverified "$S_H5"  "" GATE_FASTLANE_COMMIT_MAX=2
e2e_case "a CPF added then removed (history scan)"            scan-findings      "$S_H1"  ""
e2e_case "a docs-only branch named with ção/ões (was: scan-findings)" fast       "$S_H6"  ""

# ── 4h'. confirm(): the same property at the push — what lands is what was decided, history included ────────────────────────────────────────────
echo "── 4h'. gate_fastlane_confirm on a multi-commit branch ──"
REPO_H="$REPO"; REPO="$T/repo2"
MC=$(mkseq_on "$M0_R2" mc 'docs/m1.md=one\n' -- 'docs/m2.md=two\n')                         # the branch the lane decides on: two doc commits
MC_UNDO=$(mkseq_on "$MC" mc-undo 'app/y.py=print(3)\n' -- '-app/y.py')                      # …then a commit adds code and the next removes it: the TIP is identical to MC's
MC_CPF=$(mkseq_on "$MC" mc-cpf 'docs/m3.md=cpf 529.982.247-25\n' -- '-docs/m3.md')           # …or a CPF is pasted and removed
git -C "$REPO" checkout -q -b mc-rb "$MC" && git -C "$REPO" rebase -q main && MC_RB=$(git -C "$REPO" rev-parse HEAD) && git -C "$REPO" checkout -q main
[ "$(git -C "$REPO" diff main...mc-undo --stat | tail -1)" = "$(git -C "$REPO" diff main...mc --stat | tail -1)" ] && ok "premise: mc-undo has the SAME tip diff as mc (the extra commits cancel out)" || bad "premise broken: mc-undo's tip differs from mc's"
[ -n "${MC_RB:-}" ] && [ "$MC_RB" != "$MC" ] && ok "premise: mc was rebased onto the moved main (new shas, same commits)" || bad "premise broken: mc-rb"
dconf "$MC" main "$MC";          conf_check "two doc commits, tip did not move (the common case)" 0 ""
[ "$C_L0" = "fast" ] && [ "$C_DIG0" = "set" ] && ok "premise: the decision on the two-commit docs branch is fast and records the fingerprint of tip AND history" || bad "premise: decide → lane=$C_L0 digest=$C_DIG0 ($C_WHY)"
dconf "$MC" "$MAIN2" "$MC_RB";   conf_check "…a pure REBASE of the two commits onto the moved main (every sha new) is the same change" 0 ""
dconf "$MC" main "$MC_UNDO";     conf_check "the same TIP, but two more commits on the way (code added, then removed) — the history differs" 1 diff-changed
dconf "$MC" main "$MC_CPF";      conf_check "the same TIP, but a CPF pasted and removed in two more commits" 1 diff-changed
case "$C_WHY" in *529.982*|*52998224725*) bad "the revocation reason published the CPF: $C_WHY" ;; *) ok "…and the revocation reason never carries the value" ;; esac
# the history check at the push is asked directly too, not only inferred from the fingerprint: take away the digest comparison and the
# history classification alone must still refuse (mutant lib: the confirm's digest test never fires)
sed 's/^  if \[ "\$GATE_FL_DIFF_DIGEST" != "\$decided" \]; then$/  if false; then/' "$LIB" > "$T/mut-nodigest.lib.sh"; cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-nodigest.lib.sh"; then bad "mutation (no digest compare) did not change the lib (sed pattern drifted)"; else
  FL_LIB_OVERRIDE="$T/mut-nodigest.lib.sh" dconf "$MC" main "$MC_UNDO"
  [ "$C_RC" = "1" ] && [ "$C_CODE" = "no-longer-fast" ] && ok "without the fingerprint test, the push-time history classification ALONE still refuses the code-then-removed branch (no-longer-fast)" || bad "history classification at the push is not independent of the digest: rc=$C_RC code=$C_CODE ($C_WHY)"
fi
REPO="$REPO_H"

# ── 4h''. the scanner on a `git log -p` stream (hand-built, so each shape is pinned) ───────────────────────────────────────────────────────────
echo "── 4h''. scanner: git log -p streams ──"
SHA1=1111111111111111111111111111111111111111; SHA2=2222222222222222222222222222222222222222
LOGHDR() { printf 'commit %s\nAuthor: t <t@example.invalid>\nDate:   Sun Oct 11 07:08:02 2026 -0300\n\n' "$1"; }
FILEHDR='diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n'
log_case() { # name want_rc <stdin: the stream>
  local rc=0; SCAN_OUT=$(python3 "$SCAN" 2>&1) || rc=$?
  if [ "$rc" = "$2" ]; then ok "log stream: $1 → rc=$2"; else bad "log stream: $1 → rc=$rc, want $2 ($SCAN_OUT)"; fi
}
log_case "a clean commit (the Date: line's digits are not content)" 0 < <({ LOGHDR $SHA1; printf '    docs: explain\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+prose only\n"; })
log_case "a CPF in the message" 1 < <({ LOGHDR $SHA1; printf '    cliente 529.982.247-25 ligou\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+prose only\n"; })
[ "$SCAN_OUT" = "$(printf 'numero-longo\t111111111:commit-message\t1')" ] && ok "…named <sha9>:commit-message, line 1, no value" || bad "message finding wrong: $(printf '%s' "$SCAN_OUT" | cat -vte)"
log_case "a phone wrapped across two message lines" 1 < <({ LOGHDR $SHA1; printf '    ligar (31) 99999-\n    8888 amanha\n'; })
[ "$SCAN_OUT" = "$(printf 'numero-longo\t111111111:commit-message\t1')" ] && ok "…reported on the line it starts on (1), once" || bad "wrapped message finding wrong: $SCAN_OUT"
log_case "two short numbers around an EMPTY message line (four spaces) are not one number" 0 < <({ LOGHDR $SHA1; printf '    item 31 9999\n    \n    item 8888 fim\n'; })
log_case "a secret in the message" 1 < <({ LOGHDR $SHA1; printf '    key AKIAIOSFODNN7EXAMPLE\n'; })
log_case "a message line shaped like a diff header is message text, never a header" 0 < <({ LOGHDR $SHA1; printf '    diff --git a/x b/x\n    +++ b/x\n    @@ -1 +1 @@\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+prose only\n"; })
log_case "…and a secret on such a line is still found" 1 < <({ LOGHDR $SHA1; printf '    +++ b/x AKIAIOSFODNN7EXAMPLE\n'; })
log_case "a finding in the SECOND commit's file carries the second sha" 1 < <({ LOGHDR $SHA1; printf '    one\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+ok\n\n"; LOGHDR $SHA2; printf '    two\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+key AKIAIOSFODNN7EXAMPLE\n"; })
[ "$SCAN_OUT" = "$(printf 'aws-key\t222222222:docs/x.md\t1')" ] && ok "…222222222:docs/x.md:1" || bad "second-commit finding wrong: $SCAN_OUT"
log_case "an empty commit (header + message, no diff) followed by a real one" 0 < <({ LOGHDR $SHA1; printf '    empty\n\n'; LOGHDR $SHA2; printf '    real\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+prose\n"; })
log_case "a trailing 'No newline' marker after a commit's last hunk still understood" 0 < <({ LOGHDR $SHA1; printf '    m\n\n'; printf "${FILEHDR}@@ -0,0 +1 @@\n+prose\n\\\\ No newline at end of file\n"; })
log_case "a commit with a path holding a space (git's TAB on the +++ line) keeps its 3-field finding" 1 < <({ LOGHDR $SHA1; printf '    m\n\n'; printf 'diff --git a/docs/a b.md b/docs/a b.md\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/docs/a b.md\t\n@@ -0,0 +1 @@\n+chave AKIAIOSFODNN7EXAMPLE\n'; })
[ "$SCAN_OUT" = "$(printf 'aws-key\t111111111:docs/a b.md\t1')" ] && ok "…111111111:docs/a b.md:1, 3 fields" || bad "spaced path in a log stream: $(printf '%s' "$SCAN_OUT" | cat -vte)"
# the shapes that are NOT git log --pretty=medium are refused, never read as clean
log_case "a decorated commit line (git log --decorate)" 2 < <(printf 'commit %s (HEAD -> main)\nAuthor: t <t@x>\nDate:   Sun Oct 11 07:08:02 2026 -0300\n\n    m\n' $SHA1)
log_case "a 'Merge:' header (a merge commit must not reach the scan: the caller passes --no-merges)" 2 < <(printf 'commit %s\nMerge: aaaaaaa bbbbbbb\nAuthor: t <t@x>\nDate:   x\n\n    m\n' $SHA1)
log_case "a header line that is neither Author nor Date" 2 < <(printf 'commit %s\nCommit: t\nDate:   x\n\n    m\n' $SHA1)
log_case "a commit header that ends the input (truncated stream)" 2 < <(printf 'commit %s\nAuthor: t <t@x>\n' $SHA1)
log_case "an unindented line inside a message that is not a diff or commit line" 2 < <({ LOGHDR $SHA1; printf '    m\nGARBAGE\n'; })
log_case "a 'commit' line that is not a full sha" 2 < <(printf 'commit abc123\nAuthor: t\n\n    m\n')
log_case "a stray 'commit <sha>' line in a plain diff (no header after it)" 2 < <(printf "commit %s\n${FILEHDR}@@ -0,0 +1 @@\n+x\n" $SHA1)
log_case "a plain diff with no commit lines is read exactly as before" 0 < <(printf "${FILEHDR}@@ -0,0 +1 @@\n+prose\n")
log_case "a blank line at the top level of a PLAIN diff is still refused (only a log stream has them)" 2 < <(printf "${FILEHDR}@@ -0,0 +1 @@\n+prose\n\n")
# git's C-quoting (core.quotepath on, the default): the escapes are not the name (gate round ga-aa8n6z, blocking issue 2)
QN='diff --git "a/docs/migra\\303\\247\\303\\243o.md" "b/docs/migra\\303\\247\\303\\243o.md"\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ "b/docs/migra\\303\\247\\303\\243o.md"\n@@ -0,0 +1 @@\n+so prosa\n'
raw_scan "a git-quoted name with two adjacent non-ASCII letters (octal escapes only) is NOT a long number" 0 < <(printf "$QN")
raw_scan "…a quoted name whose accented letters sit inside a real CPF is still a finding" 1 < <(printf 'diff --git "a/docs/relat\\303\\263rio-52998224725.md" "b/docs/relat\\303\\263rio-52998224725.md"\nnew file mode 100644\nindex 0000000..e69de29\n')
case "$SCAN_OUT" in *52998224725*) bad "the quoted-name finding published the CPF: $SCAN_OUT" ;; *) ok "…and still withholds the name" ;; esac
raw_scan "an octal escape beyond 255 is not something git writes: cannot read it, rc=2" 2 < <(printf 'diff --git "a/docs/x\\777.md" "b/docs/x\\777.md"\nnew file mode 100644\nindex 0000000..e69de29\n')

echo
echo "== gate-fastlane.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
