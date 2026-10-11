#!/usr/bin/env bash
# gate-fastlane.selftest.sh (ga-atsahv)
# SLICE NOTE (ga-atsahv.1 of 3 — removed by ga-atsahv.3): this slice runs items 1-3 of the list above only (the scanner, the path classes, classify_raw).
# Items 4-8 (decide / history / confirm, the dispatcher blocks, record, tally, drift guards, mutation checks) arrive with ga-atsahv.2 and ga-atsahv.3;
# until then this file proves exactly what the slice contains.
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
has_long_number() { python3 -c 'import re,sys; sys.exit(0 if re.search(r"\d(?:[\W_]*\d){7,}", sys.argv[1]) else 1)' "$1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/gate-fastlane.XXXXXX")" || { echo "mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
if has_long_number "$T"; then
  rm -rf "$T"
  T="$(mktemp -d /tmp/gate-fastlane.XXXXXX)" || { echo "mktemp failed"; exit 2; }
fi
if has_long_number "$T"; then bad "fixture base dir $T carries an 8+ digit run — fixtures that embed it would trip the lane's own scan"; else ok "fixture base dir carries no 8+ digit run — the fixtures that embed absolute paths cannot trip the lane's own scan, whatever the caller's TMPDIR"; fi
mkdir -p "$T/tmp" "$T/bin"
TAB=$'\t'

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
scan_case "placeholder assignment"      '+API_TOKEN = "<your-token-here-0123>"'                  0
scan_case "word-like value"             '+token_refresh_policy = some_descriptive_name_value'    0
scan_case "credentials in a URL"        '+mysql://root:hunter2pass@db.local/x'                   1
scan_case "bead id / short sha"         '+commit f8fa11ee6 fix(ga-gnr3tw) bd ga-atsahv'          0
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
    # the last three stress the long-number rule: a digit followed by a huge separator run, seven-digit near misses by the
    # million, and seven digits joined by 1000-long separator runs (the worst case for a regex that backtracks over them)
    for i, body in enumerate(("a" * n, "token" * (n // 5), "ab12." * (n // 5), "x" * 1000 + "://" + "u" * n,
                              "1" + "-" * n + "x", "1234567a" * (n // 8), (("1" + "-" * 1000) * 7 + "x") * (n // 8000)), 1):
        f.write(hdr.replace("x.md", f"x{i}.md") + "@@ -0,0 +1 @@\n+" + body + "\n")
PYGEN
SECONDS=0; rc=0; timeout 90 python3 "$SCAN" --max-bytes 20000000 < "$LONG" >/dev/null 2>&1 || rc=$?
{ [ "$rc" = "0" ] && [ "$SECONDS" -lt 60 ]; } && ok "seven 1.5 MB single-line adds (word run, repeated keyword, dotted run, scheme run, separator run, 7-digit near misses, 7 digits over 1000-long separator runs) scan clean in ${SECONDS}s — no quadratic regex" || bad "long-line scan: rc=$rc after ${SECONDS}s (124 = hung; this was 18 s per 32 KB before)"

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

echo
echo "== gate-fastlane.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
