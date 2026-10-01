#!/usr/bin/env bash
# gate-fastlane.selftest.sh (ga-atsahv)
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
#      "clean" / whose reason code the tally does not bucket must turn the matching assertion red.
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
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2) — never the first `bash` on PATH

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-fastlane.selftest =="
for f in "$LIB" "$SCAN" "$DISPATCHER"; do
  if [ -r "$f" ]; then ok "present: $(basename "$f")"; else bad "missing: $f"; fi
done
[ -x "$B32" ] || { echo "FATAL: $B32 not found"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-fastlane.XXXXXX")" || { echo "mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/bin"
TAB=$'\t'
TALLY="$SELF_DIR/gate-lane-tally.py"
# a stub `bd` for gate_fastlane_record (§4e, §7): logs its argv, answers `show` with the lane FAKE_BD_LANE
cat > "$T/bin/bd" <<'EOF'
#!/bin/bash
echo "$@" >> "$FAKE_BD_LOG"
case "$*" in *" show "*) printf '[{"metadata":{"gate.lane":"%s"}}]\n' "${FAKE_BD_LANE:-}" ;; esac
exit 0
EOF
chmod +x "$T/bin/bd"
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

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
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
  # FL_QG_LOG=<file> [FL_MARKER=<id>] also runs the REAL gate_fastlane_record on the decision (stub bd), as the dispatcher does
  local head="$1" policy="$2" out; shift 2
  out=$(fl_env GATE_FS_TMPDIR="$T/tmp" FL_LIB="${FL_LIB_OVERRIDE:-$LIB}" FL_REPO="$REPO" FL_BASE="${FL_BASE:-main}" FL_HEAD="$head" FL_POLICY="$policy" \
            FL_BIN="$T/bin" FAKE_BD_LOG="$T/bd.log" "$@" \
        "$B32" -c '
    set -euo pipefail
    source "${FL_LIB_OVERRIDE:-$FL_LIB}"   # an override may arrive as a prefix assignment or as an env arg
    gfn() { git -C "$FL_REPO" "$@"; }
    gate_fastlane_decide gfn "$FL_BASE" "$FL_HEAD" "$FL_POLICY"
    printf "%s\n%s\n%s\n%s\n" "$GATE_LANE" "$GATE_LANE_REASON" "$(gate_fastlane_files_oneline)" "$GATE_LANE_REASON_CODE"
    if [ -n "${FL_QG_LOG:-}" ]; then
      PATH="$FL_BIN:$PATH" gate_fastlane_record /city "${FL_MARKER:-m-e2e}" ga-e2e feat/e2e gascity 1 "$FL_QG_LOG" >/dev/null 2>&1 || true
    fi
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
# 4c. tests: run, env scrubbed, stdin closed, bounded
S=$(mkbr s-testok 'docs/n.md=x\n' 'tests/ok.selftest.sh=exit 0\n');          decide "$S" "";  check "docs + a new green test" fast "ran green"; no_leftovers "green test"
S=$(mkbr s-testbad 'tests/bad.selftest.sh=exit 3\n');                        decide "$S" "";  check "a new test that FAILS stays in the gate (never a FAIL verdict)" normal "rc=3"; no_leftovers "failing test"
S=$(mkbr s-scrub 'tests/scrub.selftest.sh=[ -z "${FL_SECRET:-}" ] || exit 1\ncase "$HOME" in */gc-gate-fs-fastlane-*) ;; *) exit 1 ;; esac\n')
decide "$S" "" FL_SECRET=hunter2;  check "tests run with a scrubbed env (inherited secret absent, HOME inside the worktree)" fast "ran green"
# the tests' PATH must not reach tools installed under $HOME (`secret`, `notify` in ~/.local/bin). This is ALL the PATH filter does: bd, gc, dolt, gh, aws,
# gcloud and bw live in /opt/homebrew/bin and stay reachable (gate round 4, blocking issue 2) — the credential shield is the throwaway HOME (§4c scrub case)
mkdir -p "$T/fakehome/.local/bin"; printf '#!/bin/sh\necho VAULT-REACHED\n' > "$T/fakehome/.local/bin/secret"; chmod +x "$T/fakehome/.local/bin/secret"
[ "$(PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" command -v secret)" = "$T/fakehome/.local/bin/secret" ] && ok "premise: a stub 'secret' IS on the caller's PATH under \$HOME" || bad "premise broken: the stub 'secret' is not findable"
S=$(mkbr s-nosecret 'tests/nosecret.selftest.sh=if command -v secret >/dev/null 2>&1; then exit 12; fi\ncommand -v git >/dev/null || exit 13\ncommand -v jq >/dev/null || exit 14\nexit 0\n')
# a controlled PATH: the stub dir under the (fake) HOME first, then only system/Homebrew dirs — so the REAL ~/.local/bin cannot leak in
decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin";  check "tests run WITHOUT the tools under \$HOME on PATH (no 'secret') but with git/jq" fast "ran green"
# …and it is NOT a boundary around the city (gate round 4, blocking issue 2): a control-plane tool installed OUTSIDE $HOME (bd, gc, dolt in /opt/homebrew/bin on the
# real host) survives the filter. Pinned here so the comment in the lib cannot drift back to claiming otherwise.
mkdir -p "$T/sysbin"; printf '#!/bin/sh\necho CITY-REACHED\n' > "$T/sysbin/bd"; chmod +x "$T/sysbin/bd"
S=$(mkbr s-ctlplane 'tests/ctl.selftest.sh=[ "$(command -v bd)" = "'"$T"'/sysbin/bd" ] || exit 15\n')
decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:$T/sysbin:/opt/homebrew/bin:/usr/bin:/bin";  check "a tool outside \$HOME ('bd') STAYS reachable from the tests: the PATH filter is no boundary around the city" fast "ran green"
RAN="$T/ran.log"; : > "$RAN"
S=$(mkbr s-stdin 'tests/a.selftest.sh=cat >/dev/null\n' "tests/b.selftest.sh=echo b >> $RAN\n")
decide "$S" "";  check "two tests; the first reads stdin" fast "2 test file(s) ran green"
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

# ── 4e. every decision, run through the REAL record and the REAL tally ──────────────────────────────────────────
# Gate round 1, blocking issue 2: the tally matched a sentence the lib never emitted, so ~96% of decisions landed in
# the wrong bucket — and its selftest was green because its fixture was hand-written to match. Here nothing is
# hand-written: the decision is the lib's, the event is gate_fastlane_record's, the bucket is the tally's.
echo "── 4e. decision → gate_lane event → tally, all real ──"
label_of() { python3 "$TALLY" --list-codes | awk -F'\t' -v c="$1" '$1==c{print $2}'; }
E_BUCKET=""; E_FAST=""
e2e_probe() { # <head> <policy> [ENV=VAL ...] — decides, records, tallies ONE decision -> D_CODE / E_BUCKET / E_FAST
  local head="$1" policy="$2" log="$T/e2e-$RANDOM$RANDOM.jsonl" j; shift 2
  decide "$head" "$policy" FL_QG_LOG="$log" FL_MARKER="m-e2e" "$@"
  j=$(python3 "$TALLY" --log "$log" --days 1 --json 2>/dev/null) || j='{}'
  E_FAST=$(printf '%s' "$j" | jq -r '.fast // "?"' 2>/dev/null)
  E_BUCKET=$(printf '%s' "$j" | jq -r '(.normal_reasons // {}) | keys | if length == 1 then .[0] elif length == 0 then "none" else "MANY" end' 2>/dev/null)
  rm -f "$log"
}
e2e_ok() { # <want_code> — 0 iff the last probe produced that code AND the tally put it in that code's bucket
  local want="$1" label
  [ "$D_CODE" = "$want" ] || return 1
  if [ "$want" = "fast" ]; then [ "$E_FAST" = "1" ] && [ "$E_BUCKET" = "none" ]; return; fi
  label=$(label_of "$want"); [ -n "$label" ] && [ "$E_BUCKET" = "$label" ]
}
e2e_case() { # <name> <want_code> <head> <policy> [ENV=VAL ...]
  local name="$1" want="$2" head="$3" policy="$4"; shift 4
  e2e_probe "$head" "$policy" "$@"
  if e2e_ok "$want"; then ok "e2e: $name → code=$want, tally bucket '$(label_of "$want")'"
  else bad "e2e: $name → code='$D_CODE' bucket='$E_BUCKET' fast=$E_FAST; want code=$want / bucket '$(label_of "$want")' (reason: $D_REASON)"; fi
}
head_of() { git -C "$REPO" rev-parse "$1"; }
e2e_case "docs-only branch (the fast lane itself)"           fast             "$(head_of s-docs)"    ""
e2e_case "a .py file (the case the gate cited: ~96% of diffs)" code-or-prompt  "$(head_of s-mdpy)"    ""
e2e_case "a skill .md (prompt/doctrine)"                      code-or-prompt  "$(head_of s-skill)"   ""
e2e_case "CLAUDE.md alone"                                    code-or-prompt  "$(head_of s-claude)"  ""
e2e_case "deploy_deps.json (config is code)"                  code-or-prompt  "$(head_of s-config)"  ""
e2e_case "a go:embed'd agent template (*-CLAUDE.md)"          code-or-prompt  "$(head_of s-tpl)"     ""
e2e_case "an .md outside every known doc place"               code-or-prompt  "$(head_of s-unkmd)"   ""
e2e_case "a CPF on an added line"                             scan-findings   "$(head_of s-cpf)"     ""
e2e_case "a secret after a U+2028"                            scan-findings   "$(head_of s-u2028b)"  ""
e2e_case "scanner missing next to the lib"                    scan-failed     "$(head_of s-docs)"    "" FL_LIB_OVERRIDE="$T/libonly/gate-fastlane.lib.sh"
e2e_case "a binary file named .md"                            scan-failed     "$(head_of s-bin)"     ""
e2e_case "a new test that fails"                              test-failed     "$(head_of s-testbad)" ""
e2e_case "tests changed but running them is disabled"         test-failed     "$(head_of s-notests)" "" GATE_FASTLANE_RUN_TESTS=0
e2e_case "a changed test with no runner (ts)"                 test-unrunnable "$(head_of s-js)"      ""
e2e_case "a symlink named .md"                                unclassifiable  "$(head_of s-link)"    ""
e2e_case "an empty diff (head == base)"                       unclassifiable  "$BASE_SHA"            ""
e2e_case "a gate policy file in the diff"                     policy          "$(head_of s-docs2)"   "packs/x/quality-gate-foo.sh"
e2e_case "kill-switch env GATE_FASTLANE_ENABLED=0"            disabled        "$(head_of s-docs2)"   "" GATE_FASTLANE_ENABLED=0
e2e_case "kill-switch flag file"                              flag-file       "$(head_of s-docs2)"   "" GATE_FASTLANE_OFF_FILE="$T/fastlane.off"
e2e_case "git cannot diff (bad base ref)"                     diff-raw-failed "$(head_of s-docs2)"   "" FL_BASE=no-such-ref
e2e_case "no head to decide on"                               no-input        ""                     ""
# the cited bug, said directly: a code diff must NOT read as "touches the gate's own policy"
e2e_probe "$(head_of s-mdpy)" ""
[ "$E_BUCKET" != "$(label_of policy)" ] && [ "$E_BUCKET" = "$(label_of code-or-prompt)" ] && ok "a diff that went to the gate because of a .py file is bucketed as code/prompt — not as the gate's own policy" || bad "the cited misbucketing is back: '$E_BUCKET'"
# and every code the lib can set is one the harness above exercised or the tally lists (no producer/consumer drift)
EXERCISED="fast code-or-prompt scan-findings scan-failed test-failed test-unrunnable unclassifiable policy disabled flag-file diff-raw-failed no-input"
for c in $(grep -o '_gate_fastlane_normal "[a-z-]*"' "$LIB" | sed 's/.*"\(.*\)"/\1/' | sort -u); do
  case " $EXERCISED " in *" $c "*) ok "lib code '$c' is exercised end to end above" ;; *) bad "lib emits code '$c' that §4e never ran through the tally" ;; esac
done

# ── 4f. confirm(): the diff that LANDS is the diff that was CHECKED ──────────────────────────────────────────────
# Gate round 2, blocking issue 2: the lane judged $BRANCH_SHA, but the merge pushes whatever origin/$BRANCH is when the
# push runs (do_merge_ff re-resolves it) — a commit added after the decision would have merged with zero reviewers and no
# scan, and the old selftest line that claimed otherwise only grepped the call's argument text. gate_fastlane_confirm is
# asked, immediately before the push, about the exact commit being pushed. Every case below takes a REAL decision first,
# then moves the tip / rebases / merges / flips the kill-switch / swaps a file for a symlink, and asks again.
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

# ── 5. the dispatcher's live blocks, under bash 3.2 + set -euo pipefail ───────────────────────────────────────
echo "── 5. dispatcher wiring (extracted, executed under $B32 + set -euo pipefail) ──"
LOADBLK="$(extract_block "$DISPATCHER" fastlane-lib-load)"
DECBLK="$(extract_block "$DISPATCHER" fastlane-decide)"
BYPBLK="$(extract_block "$DISPATCHER" fastlane-bypass)"
for n in LOADBLK DECBLK BYPBLK; do
  if [ -n "${!n}" ]; then ok "located the dispatcher block $n ($(printf '%s\n' "${!n}" | wc -l | tr -d ' ') lines)"; else bad "dispatcher block $n not found (sentinels missing/renamed)"; fi
done

# 5a. lib load: present / missing / unreadable / syntax error — the daemon must survive all four
load_case() { # name setup-cmd want
  local d="$T/load-$1" out
  mkdir -p "$d"
  { printf 'set -euo pipefail\n'; printf '%s\n' "$LOADBLK"; printf 'if declare -F gate_fastlane_decide >/dev/null 2>&1; then echo LOADED; else echo ABSENT; fi\necho ALIVE\n'; } > "$d/disp.sh"
  eval "$2"
  out=$("$B32" "$d/disp.sh" 2>/dev/null | tr '\n' ' ') || out="DIED($out)"
  case "$out" in "$3 ALIVE ") ok "lib load: $1 → $3, daemon alive" ;; *) bad "lib load: $1 → '$out', want '$3 ALIVE'" ;; esac
}
load_case present   'cp "$LIB" "$d/gate-fastlane.lib.sh"'                                         LOADED
load_case missing   ':'                                                                           ABSENT
load_case unreadable 'cp "$LIB" "$d/gate-fastlane.lib.sh"; chmod 000 "$d/gate-fastlane.lib.sh"'    ABSENT
load_case syntaxerr 'printf "if then fi\n" > "$d/gate-fastlane.lib.sh"'                           ABSENT
load_case truncated 'head -c 900 "$LIB" > "$d/gate-fastlane.lib.sh"; printf "gate_fastlane_x() {\n" >> "$d/gate-fastlane.lib.sh"'  ABSENT

# 5b. the lane decision block
dec_case() { # name stub want_lane want_tier want_rev
  local out
  { cat <<'HDR'
set -euo pipefail
git_rig() { :; }
DEFAULT_BRANCH=main; BRANCH_SHA=abc123; POLICY_FILES=""; TIER="NON-CODE"; REQUIRED_REVIEWERS=1
CHANGED_FILES="docs/a.md"
GATE_LANE="normal"; GATE_LANE_REASON=""
HDR
    printf '%s\n' "$2"
    printf '%s\n' "$DECBLK"
    printf 'echo "RESULT lane=$GATE_LANE tier=$TIER rev=$REQUIRED_REVIEWERS"\n'
  } > "$T/dec.sh"
  out=$("$B32" "$T/dec.sh" 2>&1 | tail -1) || out="DIED"
  if [ "$out" = "RESULT lane=$3 tier=$4 rev=$5" ]; then ok "decide block: $1 → $3"; else bad "decide block: $1 → '$out', want 'RESULT lane=$3 tier=$4 rev=$5'"; fi
}
dec_case "lib says fast"                         'gate_fastlane_decide() { GATE_LANE=fast; GATE_LANE_REASON=stub; }'                  fast   FAST-LANE 0
dec_case "lib says normal"                       'gate_fastlane_decide() { GATE_LANE=normal; GATE_LANE_REASON=stub; }'                normal NON-CODE  1
dec_case "lib returns garbage as the lane"       'gate_fastlane_decide() { GATE_LANE=banana; }'                                       normal NON-CODE  1
dec_case "lib ERRORS after setting fast"         'gate_fastlane_decide() { GATE_LANE=fast; return 7; }'                               normal NON-CODE  1
dec_case "lib not loaded at all"                 ':'                                                                                  normal NON-CODE  1
dec_case "dispatcher's own file list EMPTY (git error) even though the lib would say fast" 'CHANGED_FILES=""; gate_fastlane_decide() { GATE_LANE=fast; GATE_LANE_REASON=stub; }' normal NON-CODE 1

# 5b'. the REAL extracted block + the REAL lib + REAL git: the story's own test at the dispatcher level
git -C "$REPO" update-ref refs/remotes/origin/main main
real_dec() { # <head sha> -> the RESULT line the dispatcher's own Step 5 block produces
  { cat <<'HDR'
set -euo pipefail
git_rig() { git -C "$FL_REPO" "$@"; }
DEFAULT_BRANCH=main; POLICY_FILES=""; TIER="NON-CODE"; REQUIRED_REVIEWERS=1
CHANGED_FILES="docs/a.md"
GATE_LANE="normal"; GATE_LANE_REASON=""
source "$FL_LIB"
HDR
    printf 'BRANCH_SHA=%s\n' "$1"
    printf '%s\n' "$DECBLK"
    printf 'echo "RESULT lane=$GATE_LANE tier=$TIER rev=$REQUIRED_REVIEWERS"\n'
  } > "$T/realdec.sh"
  fl_env FL_REPO="$REPO" FL_LIB="$LIB" GATE_FS_TMPDIR="$T/tmp" "$B32" "$T/realdec.sh" 2>&1 | tail -1
}
real_case() { # name branch want
  local got; got=$(real_dec "$(git -C "$REPO" rev-parse "$2")")
  if [ "$got" = "$3" ]; then ok "real Step 5 block + real lib + real git: $1 → ${3#RESULT }"; else bad "real Step 5 block: $1 → '$got', want '$3'"; fi
}
real_case "branch with only docs/*.md takes the fast lane (0 reviewers)"  s-docs   "RESULT lane=fast tier=FAST-LANE rev=0"
real_case "control: a skill .md stays in the normal gate"                  s-skill  "RESULT lane=normal tier=NON-CODE rev=1"
real_case "control: .md + one .py stays in the normal gate"                s-mdpy   "RESULT lane=normal tier=NON-CODE rev=1"
real_case "docs with a CPF stays in the normal gate"                       s-cpf    "RESULT lane=normal tier=NON-CODE rev=1"

# 5b''. the lib did not load, so there is no recorder: the dispatcher must still leave the tally ONE event for that diff
RECBLK="$(extract_block "$DISPATCHER" fastlane-record)"
[ -n "$RECBLK" ] && ok "located the dispatcher block RECBLK ($(printf '%s\n' "$RECBLK" | wc -l | tr -d ' ') lines)" || bad "dispatcher block fastlane-record not found (sentinels missing/renamed)"
recfb() { # <qg_log> <would> [DRY_RUN] — the block exactly as the dispatcher runs it, lib NOT sourced
  { cat <<'HDR'
set -euo pipefail
GC_CITY=/city; MARKER_ID=mk-9; BEAD_ID=ga-x; BRANCH=feat/x; RIG=gascity
GATE_LANE=normal; GATE_LANE_REASON="fast-lane lib not loaded (gate-fastlane.lib.sh missing or unreadable) — normal gate"; GATE_LANE_REASON_CODE=lib-not-loaded
HDR
    printf 'QG_LOG=%q; GATE_LANE_WOULD_REVIEWERS=%q; DRY_RUN=%q\n' "$1" "$2" "${3:-0}"
    printf '%s\n' "$RECBLK"
    printf 'echo RECORD-DONE\n'
  } > "$T/recfb.sh"
  "$B32" "$T/recfb.sh" 2>&1
}
RFLOG="$T/rf.jsonl"; rm -f "$RFLOG"
RFOUT=$(recfb "$RFLOG" 3)
case "$RFOUT" in *RECORD-DONE*) ok "lib not loaded: the record block survives set -euo pipefail under bash 3.2" ;; *) bad "record block died: $RFOUT" ;; esac
[ "$(jq -r '[.event,.lane,.reason_code,.would_have_reviewers,.dry_run,.marker]|join("|")' "$RFLOG" 2>/dev/null)" = "gate_lane|normal|lib-not-loaded|3|0|mk-9" ] && ok "lib not loaded: ONE gate_lane event is written by the dispatcher itself (code lib-not-loaded, the reviewers a normal run uses, the marker)" || bad "fallback event: $(cat "$RFLOG" 2>/dev/null)"
[ "$(python3 "$TALLY" --log "$RFLOG" --days 1 --json | jq -r '.normal_reasons["lib da fast-lane não carregou"] // 0')" = "1" ] && ok "…and the tally buckets it as 'lib da fast-lane não carregou' (was: unreachable, the diff was simply absent)" || bad "the tally does not see the broken-lib decision"
rm -f "$RFLOG"; recfb "$RFLOG" "not-a-number" >/dev/null
[ "$(jq -r '.would_have_reviewers' "$RFLOG" 2>/dev/null)" = "0" ] && ok "a non-numeric reviewer count is written as 0, not an event lost to a jq error" || bad "non-numeric would-have-reviewers lost the event: $(cat "$RFLOG" 2>/dev/null)"
rm -f "$RFLOG"; recfb "$RFLOG" 1 1 >/dev/null
[ "$(jq -r '.dry_run' "$RFLOG" 2>/dev/null)" = "1" ] && [ "$(python3 "$TALLY" --log "$RFLOG" --days 1 --json | jq -r '.decisions')" = "0" ] && ok "a DRY_RUN=1 sweep's event carries dry_run=1 and the tally leaves it out" || bad "dry-run event: $(cat "$RFLOG" 2>/dev/null)"
RFOUT=$(recfb "/nonexistent-dir-$$/qg.jsonl" 1)
case "$RFOUT" in *RECORD-DONE*) ok "an unwritable log does not kill the daemon (the line is lost, the sweep goes on)" ;; *) bad "unwritable QG_LOG killed the block: $RFOUT" ;; esac

# 5c. the Step 7 bypass
byp_case() { # name lane
  { cat <<'HDR'
set -euo pipefail
BRANCH="b"; GATE_LANE_REASON="r"
log() { echo "LOG: $*"; }
GATE_LOCK_ENABLED=0
_gate_lock_write_hb() { :; }
cleanup_reviewer_sessions() { :; }
gate_finalize_run() { echo "FINALIZE overall=$OVERALL_VERDICT quota=$QUOTA_REQUEUE verdicts=${#VERDICT_BEAD_IDS[@]} sessions=${#SESSION_IDS[@]} fail=[$FAIL_REASONS]"; }
gc() { echo "GC-CALLED $*"; }
bd() { echo "BD-CALLED $*"; }
HDR
    printf 'GATE_LANE=%s\n' "$2"
    printf '%s\n' "${BYPBLK_USE:-$BYPBLK}"
    printf 'echo AFTER-BLOCK\n'
  } > "$T/byp.sh"
  BYP_OUT=$("$B32" "$T/byp.sh" 2>&1); BYP_RC=$?
}
byp_case fast fast
case "$BYP_OUT" in *"FINALIZE overall=PASS quota=0 verdicts=0 sessions=0 fail=[]"*) ok "bypass (fast): finalize runs with PASS, no quota re-queue, ZERO verdicts, ZERO sessions" ;; *) bad "bypass (fast): $BYP_OUT" ;; esac
case "$BYP_OUT" in *GC-CALLED*) bad "bypass (fast): a gc call was made — a reviewer session may have been spawned" ;; *) ok "bypass (fast): no gc call — no reviewer session spawned" ;; esac
case "$BYP_OUT" in *BD-CALLED*) bad "bypass (fast): a bd call was made inside the bypass itself" ;; *) ok "bypass (fast): the bypass itself creates no verdict bead" ;; esac
case "$BYP_OUT" in *AFTER-BLOCK*) bad "bypass (fast): execution fell through to Step 7 (reviewers) after finalize" ;; *) ok "bypass (fast): ends the sweep after finalize — never reaches Step 7" ;; esac
[ "$BYP_RC" = "0" ] && ok "bypass (fast): exit 0 under set -euo pipefail with empty reviewer arrays (bash 3.2)" || bad "bypass (fast): rc=$BYP_RC — $BYP_OUT"
byp_case normal normal
case "$BYP_OUT" in *FINALIZE*) bad "bypass (normal lane): finalize ran without reviewers!" ;; *AFTER-BLOCK*) ok "bypass (normal lane): skipped — the normal gate continues to Step 7" ;; *) bad "bypass (normal): $BYP_OUT" ;; esac
byp_case '""' ""   # an empty/unset-looking lane value must not enter the bypass
case "$BYP_OUT" in *FINALIZE*) bad "bypass (empty lane): entered the bypass" ;; *) ok "bypass (empty lane value): skipped" ;; esac

# 5c'. the REAL cleanup_reviewer_sessions (Step 9 of finalize calls it) with EMPTY reviewer arrays, bash 3.2 + set -u
CLEANFN="$(awk '/^cleanup_reviewer_sessions\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$DISPATCHER")"
if [ -n "$CLEANFN" ]; then ok "located the real cleanup_reviewer_sessions ($(printf '%s\n' "$CLEANFN" | wc -l | tr -d ' ') lines)"; else bad "cleanup_reviewer_sessions not found in the dispatcher"; fi
{ cat <<'HDR'
set -euo pipefail
log() { echo "LOG: $*"; }
gc() { echo "GC-CALLED $*"; }
_release_gate_lock() { echo "LOCK-RELEASED"; }
GC_CITY=/city; GATE_RUN_ID=r1
_gate_cleanup_done=0
SESSION_IDS=()
HDR
  printf '%s\n' "$CLEANFN"
  printf 'cleanup_reviewer_sessions\necho CLEANUP-DONE\n'
} > "$T/clean.sh"
CL_OUT=$("$B32" "$T/clean.sh" 2>&1); CL_RC=$?
if [ "$CL_RC" = "0" ] && case "$CL_OUT" in *CLEANUP-DONE*LOCK*|*LOCK*CLEANUP-DONE*) true ;; *) false ;; esac; then ok "real cleanup with ZERO reviewer sessions: exits 0 under bash 3.2 set -u and releases the lock"; else bad "real cleanup with empty SESSION_IDS: rc=$CL_RC $CL_OUT"; fi
case "$CL_OUT" in *GC-CALLED*) bad "cleanup closed a session that does not exist" ;; *) ok "…and closes no session (there is none)" ;; esac

# 5c''. the bypass keeps the citywide gate lock through the WHOLE finalize (gate round 3, blocking issue 1).
# gate_finalize_run's Step 9 calls cleanup_reviewer_sessions, which releases the lock unless GATE_SWEEP_HAS_MORE_WORK=1 (Phase C sets it for
# exactly this reason) — and the rig's full-suite check and the merge both come AFTER Step 9. So a bypass that leaves the flag unset runs the
# heavy check and the merge with the lock already gone, which the lock's own log line ("holds the citywide gate lock until END") says never happens.
# Step 9 also consumes _gate_cleanup_done, so the EXIT trap's cleanup is a no-op afterwards: whoever keeps the lock must also release it.
# First the invariant the bypass leans on, on the REAL function: with the flag set, cleanup closes its sessions but leaves the lock alone.
{ cat <<'HDR'
set -euo pipefail
log() { echo "LOG: $*"; }
gc() { echo "GC-CALLED $*"; }
_release_gate_lock() { echo "LOCK-RELEASED"; }
GC_CITY=/city; GATE_RUN_ID=r1
_gate_cleanup_done=0
SESSION_IDS=()
GATE_SWEEP_HAS_MORE_WORK=1
HDR
  printf '%s\n' "$CLEANFN"
  printf 'cleanup_reviewer_sessions\necho CLEANUP-DONE\n'
} > "$T/clean-more.sh"
CM_OUT=$("$B32" "$T/clean-more.sh" 2>&1); CM_RC=$?
if [ "$CM_RC" = "0" ] && case "$CM_OUT" in *CLEANUP-DONE*) true ;; *) false ;; esac && case "$CM_OUT" in *LOCK-RELEASED*) false ;; *) true ;; esac; then ok "real cleanup with GATE_SWEEP_HAS_MORE_WORK=1 leaves the lock held (the property the bypass relies on)"; else bad "real cleanup with the flag set: rc=$CM_RC $CM_OUT"; fi
# …then the bypass itself: the REAL cleanup as Step 9, then a finalize that reports whether the lock is still held at the full-suite and the merge.
byp_lock_case() { # <finalize rc> -> BL_OUT / BL_RC
  { cat <<'HDR'
set -euo pipefail
BRANCH="b"; GATE_LANE_REASON="r"; GC_CITY=/city; GATE_RUN_ID=r1; GATE_LOCK_ENABLED=1
LOCK_HELD=1
log() { :; }
gc() { echo "GC-CALLED $*"; }
bd() { echo "BD-CALLED $*"; }
_gate_lock_write_hb() { echo "HB-REFRESHED"; }
_release_gate_lock() { echo "LOCK-RELEASED"; LOCK_HELD=0; }
HDR
    printf '%s\n' "$CLEANFN"
    cat <<'FIN'
gate_finalize_run() {
  cleanup_reviewer_sessions                                       # Step 9 — before the full-suite check and the merge, as in the dispatcher
  if [ "$LOCK_HELD" = "1" ]; then echo "AT-FULL-SUITE lock=held"; else echo "AT-FULL-SUITE lock=RELEASED"; fi
  if [ "$LOCK_HELD" = "1" ]; then echo "AT-MERGE lock=held"; else echo "AT-MERGE lock=RELEASED"; fi
  return "$FIN_RC"
}
FIN
    printf 'FIN_RC=%q\nGATE_LANE=fast\n' "$1"
    printf '%s\n' "${BYPBLK_USE:-$BYPBLK}"
    printf 'echo AFTER-BLOCK\n'
  } > "$T/bypl.sh"
  BL_OUT=$("$B32" "$T/bypl.sh" 2>&1); BL_RC=$?
}
bl_line() { printf '%s\n' "$BL_OUT" | grep -n -m1 -x -- "$1" | cut -d: -f1; }   # line number of an exact output line ("" when absent)
bl_count() { printf '%s\n' "$BL_OUT" | grep -c -x -- "$1" || true; }
byp_lock_case 0
case "$BL_OUT" in *"AT-FULL-SUITE lock=held"*) ok "bypass: the citywide lock is still held when the full-suite check runs (after Step 9)" ;; *) bad "bypass: lock gone at the full-suite check — $BL_OUT" ;; esac
case "$BL_OUT" in *"AT-MERGE lock=held"*) ok "bypass: …and still held at the merge" ;; *) bad "bypass: lock gone at the merge — $BL_OUT" ;; esac
[ "$(bl_count LOCK-RELEASED)" = "1" ] && ok "bypass: the lock is released exactly once" || bad "bypass: LOCK-RELEASED seen $(bl_count LOCK-RELEASED) times — $BL_OUT"
L_BM=$(bl_line "AT-MERGE lock=held"); L_BR=$(bl_line LOCK-RELEASED)
if [ -n "$L_BM" ] && [ -n "$L_BR" ] && [ "$L_BM" -lt "$L_BR" ]; then ok "bypass: …and only AFTER the merge point (the release is the sweep's true end, not Step 9)"; else bad "bypass: release order wrong (merge line=$L_BM, release line=$L_BR) — $BL_OUT"; fi
L_HB=$(bl_line HB-REFRESHED); L_FS=$(bl_line "AT-FULL-SUITE lock=held")
if [ -n "$L_HB" ] && [ -n "$L_FS" ] && [ "$L_HB" -lt "$L_FS" ]; then ok "bypass: the lock heartbeat is refreshed before the heavy part, as Phase C does for each run (a held lock with a stale heartbeat is reclaimed by a second sweep)"; else bad "bypass: no heartbeat refresh before the full-suite check — $BL_OUT"; fi
[ "$BL_RC" = "0" ] && case "$BL_OUT" in *AFTER-BLOCK*|*GC-CALLED*|*BD-CALLED*) false ;; *) true ;; esac && ok "bypass: exit 0, nothing after the block, no gc/bd call of its own" || bad "bypass: rc=$BL_RC — $BL_OUT"
byp_lock_case 1   # finalize fails under set -e: the abort goes straight to the EXIT trap, and the lock must still be freed
[ "$(bl_count LOCK-RELEASED)" = "1" ] && ok "bypass: a finalize that fails (set -e abort) still frees the lock, exactly once" || bad "bypass: after a failing finalize LOCK-RELEASED seen $(bl_count LOCK-RELEASED) times — $BL_OUT"

# 5d. the BSD seq hazard this design routes around (informational on GNU userland)
if [ "$(seq 1 0 | wc -l | tr -d ' ')" = "2" ]; then ok "this host's seq counts DOWN (seq 1 0 prints 2 lines) — hence an explicit branch, not REQUIRED_REVIEWERS=0"
else ok "seq 1 0 prints nothing here (GNU) — the explicit bypass is still the contract"; fi

# ── 5e. the push-time confirmation (do_merge_ff) and the revoked-run handling (gate_finalize_run) ─────────────────
# Gate round 2, blocking issue 2, at the dispatcher level: the REAL extracted push step, the REAL lib, REAL git. "Move the
# tip after the decision and assert no push" — the push step is a function whose last line is PUSH-REACHED; a revoked lane
# must return before it, with MERGE_RESULT=failed_lane_revoked.
echo "── 5e. push-time confirm + revoked-run requeue (extracted blocks, real lib, real git) ──"
PCBLK="$(extract_block "$DISPATCHER" fastlane-push-confirm)"
LRBLK="$(extract_block "$DISPATCHER" fastlane-lane-revoked)"
NARRFN="$(awk '/^gate_requeue_narrate\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$DISPATCHER")"
for n in PCBLK LRBLK NARRFN; do
  if [ -n "${!n}" ]; then ok "located $n ($(printf '%s\n' "${!n}" | wc -l | tr -d ' ') lines)"; else bad "$n not found in the dispatcher (sentinels missing/renamed)"; fi
done
PC_OUT=""
pc_case() { # <decide-head|""> <cur-main> <cur-branch> [prelude] — the decision is the lib's own; the push step is the dispatcher's own
  { cat <<'HDR'
set -euo pipefail
git_rig() { git -C "$FL_REPO" "$@"; }
err() { echo "ERR: $*"; }
log() { echo "LOG: $*"; }
source "$FL_LIB"
MERGE_RESULT=""; GATE_LANE=normal; MERGE_ATTEMPT=0   # (do_merge_ff always has MERGE_ATTEMPT: the loop that calls it sets it)
HDR
    [ -n "$1" ] && printf 'gate_fastlane_decide git_rig main %q ""\n' "$1"
    printf '%s\n' "${4:-:}"
    printf 'push_step() {\n%s\n  echo PUSH-REACHED\n}\n' "${PCBLK_USE:-$PCBLK}"
    printf 'rc=0; CUR_MAIN=%q; CUR_BRANCH=%q; push_step || rc=$?\necho "STEP rc=$rc result=${MERGE_RESULT:-none} lane=$GATE_LANE"\n' "$2" "$3"
  } > "$T/pc.sh"
  PC_OUT=$(fl_env FL_REPO="$T/repo2" FL_LIB="${FL_LIB_OVERRIDE:-$LIB}" GATE_FS_TMPDIR="$T/tmp" "$B32" "$T/pc.sh" 2>&1) || true
}
pc_reached() { case "$PC_OUT" in *PUSH-REACHED*) return 0 ;; *) return 1 ;; esac; }
pc_case "$FA" "$M0_R2" "$FA"
{ pc_reached && case "$PC_OUT" in *"STEP rc=0 result=none lane=fast"*) true ;; *) false ;; esac; } && ok "push step: the commit that was decided is pushed (lane stays fast)" || bad "push step, same tip: $PC_OUT"
pc_case "$FA" "$M0_R2" "$FB_PY"
if pc_reached; then bad "THE REPRODUCTION: a .py commit landed after the decision and the push step was REACHED — it would merge with zero reviewers: $PC_OUT"
else case "$PC_OUT" in *"STEP rc=1 result=failed_lane_revoked lane=normal"*) ok "tip moved after the decision (a .py commit): NO push — returns 1, MERGE_RESULT=failed_lane_revoked, lane=normal" ;; *) bad "tip moved: unexpected outcome: $PC_OUT" ;; esac; fi
case "$PC_OUT" in *"ERR: "*[Rr]evoked*) ok "…and the refusal is said out loud, with the cause" ;; *) bad "the refusal was silent: $PC_OUT" ;; esac
pc_case "$FA" "$M0_R2" "$FB_DOC"
pc_reached && bad "a second doc after the decision reached the push (no scan, no test ever ran on it)" || ok "a harmless-looking second doc after the decision: NO push either"
pc_case "$FA" "$MAIN2" "$FA_RB"
{ pc_reached && case "$PC_OUT" in *"STEP rc=0 result=none lane=fast"*) true ;; *) false ;; esac; } && ok "the merge-time rebase onto the moved main is pushed (same change, new tip)" || bad "a pure rebase was refused: $PC_OUT"
pc_case "" "$M0_R2" "$FB_PY"
{ pc_reached && case "$PC_OUT" in *"STEP rc=0 result=none lane=normal"*) true ;; *) false ;; esac; } && ok "control: a NORMAL-lane (reviewed) run never meets the lane check — the step is a no-op for it" || bad "normal-lane run was touched by the lane check: $PC_OUT"
pc_case "$FA" "$M0_R2" "$FA" 'unset -f gate_fastlane_confirm'
pc_reached && bad "confirm function missing: the push step was reached (fail OPEN)" || ok "the confirm function is missing → NO push (a lane nobody can confirm is not granted)"
pc_case "$FA" "$M0_R2" "$FA" 'gate_fastlane_confirm() { return 7; }'
pc_reached && bad "confirm errored (rc 7): the push step was reached" || ok "a confirm that ERRORS (rc 7) → NO push (only a clean yes is a yes)"
pc_case "$FA" "$M0_R2" "$FB_PY" 'gate_fastlane_confirm() { return 0; }'
pc_reached && ok "premise: a confirm that says yes DOES reach the push step, so the refusals above are the confirm's doing, not the harness's" || bad "premise broken: even a yes does not reach the push step: $PC_OUT"

LR_OUT=""
lr_case() { # <merge_result> <requeue-rc>
  { cat <<'HDR'
set -euo pipefail
log() { echo "LOG: $*"; }; warn() { echo "WARN: $*"; }; err() { echo "ERR: $*"; }
bd() { echo "BD $*"; }
notify() { echo "NOTIFY $*"; }
set_gate_status() { echo "SET-STATUS $*"; }
gate_requeue_respecting_external() { echo "REQUEUE $*"; return "$RQ_RC"; }
gate_fastlane_record() { echo "RECORD lane=$GATE_LANE code=$GATE_LANE_REASON_CODE files=[$GATE_LANE_FILES] would=$6 log=$7"; }
GATE_REQUEUE_RESPECTED_RC=10
GC_CITY=/city; BEAD_CITY=/bcity; MARKER_ID=mk-7; GATE_RUN_ID=run-7; BEAD_ID=ga-x; BRANCH=feat/x; RIG=gascity; QG_LOG=/qg.jsonl
GATE_LANE=fast; GATE_LANE_WOULD_REVIEWERS=2; GATE_LANE_FILES="DOC:docs/a.md"
GATE_LANE_CONFIRM_CODE=diff-changed; GATE_LANE_CONFIRM_WHY="the diff that would land is not the diff the lane checked"
HDR
    printf '%s\n' "$NARRFN"
    printf 'MERGE_RESULT=%q; RQ_RC=%q\n' "$1" "$2"
    printf 'fin() {\n%s\n  echo FELL-THROUGH\n}\n' "${LRBLK_USE:-$LRBLK}"
    printf 'rc=0; fin || rc=$?; echo "FIN rc=$rc"\n'
  } > "$T/lr.sh"
  LR_OUT=$("$B32" "$T/lr.sh" 2>&1) || true
}
lr_has() { case "$LR_OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lr_case failed_lane_revoked 0
lr_has "REQUEUE mk-7 queued dispatching" && ok "revoked run: the marker goes back to queued (from dispatching) through the external-transition-respecting helper" || bad "revoked run: no requeue — $LR_OUT"
lr_has "BD -C /bcity label remove ga-x gate:reviewing" && ok "…the source bead's gate:reviewing is cleared (no head-of-line starvation)" || bad "gate:reviewing not cleared — $LR_OUT"
lr_has "SET-STATUS run-7 superseded" && lr_has "BD -C /city close run-7" && ok "…the gate-run bead is superseded and closed (Phase C must not re-pick it)" || bad "gate-run bead left open — $LR_OUT"
lr_has "RECORD lane=normal code=revoked-at-push files=[] would=2 log=/qg.jsonl" && ok "…the decision is re-recorded as NORMAL with code revoked-at-push (marker metadata + jsonl) — not left saying 'fast'" || bad "revocation not recorded — $LR_OUT"
lr_has "FIN rc=0" && ! lr_has "FELL-THROUGH" && ok "…and the function RETURNS 0 before the FAIL block: a revoked lane is never a verdict on the author's code" || bad "revoked run fell through to the FAIL/merged handling — $LR_OUT"
lr_has "NOTIFY" && bad "a routine revocation paged someone" || ok "…no notification (it is routine, not an alarm)"
lr_case failed_lane_revoked 10
lr_has "BD -C /city comment mk-7" && lr_has "another actor" && ! lr_has "re-queued for the normal gate" && ok "revoked run, but another actor moved the marker: the marker comment says WHY it was not re-queued, and never claims the requeue" || bad "a skipped requeue was narrated as a requeue (or not narrated) — $LR_OUT"
lr_has "FIN rc=0" && ! lr_has "FELL-THROUGH" && ok "…and it still ends cleanly, never as a FAIL" || bad "skipped-requeue run fell through — $LR_OUT"
lr_case failed_push_race 0
lr_has "FELL-THROUGH" && ! lr_has "REQUEUE" && ok "control: any OTHER merge failure is untouched by the revoked-run block (falls through to the existing handling)" || bad "the revoked-run block swallowed a different failure — $LR_OUT"

# ── 5f. hermetic: the operator's own kill switch is ambient state ──────────────────────────────────────────────
# (gate round 3, blocking issue 2.) `touch <city>/.gc/gate-fastlane.off` and GATE_FASTLANE_ENABLED=0 are the operator controls this very story ships,
# and GC_CITY is exported in every agent session. Every helper above that feeds the lib hands it a child environment; one that INHERITS the caller's
# makes every case in this file read "lane switched off" the moment the switch is on — 100+ failures that look like a lane regression, on exactly the
# day a worker's gate-done self-audit runs this file. The class is "a case's result depends on the caller's operator controls", so each of the four
# helpers that spawn the lib (decide — and through it e2e_probe and the mutation checks —, dconf, real_dec, pc_case) is probed with each control ON.
# The explicit per-case overrides (§4d, §4f: GATE_FASTLANE_OFF_FILE=…, GATE_FASTLANE_ENABLED=0) are the control: they must still win over the pin.
echo "── 5f. hermetic: the operator's kill switch in the CALLER's environment must not reach a case ──"
HC="$T/hostile-city"; mkdir -p "$HC/.gc"; : > "$HC/.gc/gate-fastlane.off"; : > "$T/hostile.off"
hostile_decide() { # <label> ENV=VAL... — decide(), run with that setting exported in the caller's environment
  local label="$1" got; shift
  # two branches: docs-only (the switch controls) and docs + a new green test (the same, and the tuning knobs that only a changed test reaches)
  got=$( export "$@"; decide "$(head_of s-docs)" ""; printf '%s' "$D_LANE"; decide "$(head_of s-testok)" ""; printf ' %s' "$D_LANE" )
  [ "$got" = "fast fast" ] && ok "hermetic [$label]: decide() still reads the docs-only and the docs+green-test branches as fast" || bad "hermetic [$label]: decide() inherited the caller's setting — lanes='$got' (want 'fast fast')"
}
hostile_probe() { # <label> ENV=VAL... — each helper, run with that operator control ON in the caller's environment; each must still read the docs-only branch as fast
  local label="$1" got; shift
  hostile_decide "$label" "$@"
  got=$( export "$@"; real_dec "$(head_of s-docs)" )
  [ "$got" = "RESULT lane=fast tier=FAST-LANE rev=0" ] && ok "hermetic [$label]: the dispatcher's Step 5 block + real lib still grants fast" || bad "hermetic [$label]: real_dec inherited the switch — '$got'"
  got=$( export "$@"; REPO="$T/repo2"; dconf "$FA" main "$FA"; printf '%s/%s' "$C_RC" "$C_L1" )
  [ "$got" = "0/fast" ] && ok "hermetic [$label]: the push-time confirm still says yes to the unmoved tip" || bad "hermetic [$label]: dconf inherited the switch — rc/lane='$got' (want 0/fast)"
  got=$( export "$@"; pc_case "$FA" "$M0_R2" "$FA"; printf '%s' "$PC_OUT" )
  case "$got" in *"STEP rc=0 result=none lane=fast"*) ok "hermetic [$label]: the dispatcher's push step still pushes the decided commit" ;; *) bad "hermetic [$label]: pc_case inherited the switch — $got" ;; esac
}
hostile_probe "flag file under the caller's GC_CITY" GC_CITY="$HC"
hostile_probe "caller exported GATE_FASTLANE_ENABLED=0" GATE_FASTLANE_ENABLED=0
hostile_probe "caller exported GATE_FASTLANE_OFF_FILE pointing at an existing file" GATE_FASTLANE_OFF_FILE="$T/hostile.off"
# a tuning knob is the same class, but only a branch that changes a test reaches it — so only decide()'s two-branch probe says anything about it
hostile_decide "caller exported GATE_FASTLANE_RUN_TESTS=0 (a tuning knob)" GATE_FASTLANE_RUN_TESTS=0

# ── 6. drift guards: facts the safety argument depends on ─────────────────────────────────────────────────────
echo "── 6. drift guards ──"
ln_of() { grep -n -F -- "$1" "$DISPATCHER" | head -1 | cut -d: -f1; }
L_BYP=$(grep -n 'SELFTEST-EXTRACT fastlane-bypass: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_SEQ=$(grep -n -F 'for i in $(seq 1 $REQUIRED_REVIEWERS); do' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_BYP" ] && [ -n "$L_SEQ" ] && [ "$L_BYP" -lt "$L_SEQ" ]; then ok "the bypass (line $L_BYP) comes BEFORE the reviewer-spawn loop (line $L_SEQ)"; else bad "bypass/spawn-loop order: bypass=$L_BYP spawn=$L_SEQ"; fi
L_ZERO=$(ln_of 'has ZERO verdict beads')
L_DEC=$(grep -n 'SELFTEST-EXTRACT phase-c-verdict-decision: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_ZERO" ] && [ -n "$L_DEC" ] && [ "$L_ZERO" -lt "$L_DEC" ]; then ok "Phase C refuses a ZERO-verdict run (line $L_ZERO) BEFORE it asks 'all verdicts in?' (line $L_DEC) — a 0-of-0 fast-lane orphan can never be PASS-finalized"
else bad "Phase C ordering broke: zero-verdict guard=$L_ZERO verdict-decision=$L_DEC — a crashed fast-lane run could now read as 'all passed'"; fi
# (captured, not piped into `grep -q`: under pipefail `grep -q` exits at its first match and the writer can die of SIGPIPE — a flaky red)
ZG=$(sed -n "${L_ZERO:-1},$((${L_ZERO:-1}+1))p" "$DISPATCHER")
case "$ZG" in *continue*) true ;; *) false ;; esac && ok "…and that guard really does \`continue\` past the run" || bad "the zero-verdict guard no longer continues"
L_POL=$(grep -n -E '^POLICY_FILES=' "$DISPATCHER" | head -1 | cut -d: -f1)
L_DECBLK=$(grep -n 'SELFTEST-EXTRACT fastlane-decide: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_POL" ] && [ -n "$L_DECBLK" ] && [ "$L_POL" -lt "$L_DECBLK" ]; then ok "POLICY_FILES (line $L_POL) is computed before the lane decision (line $L_DECBLK)"; else bad "POLICY_FILES is not defined before the lane decision ($L_POL / $L_DECBLK)"; fi
POLRE=$(grep -m1 -E '^POLICY_FILES=' "$DISPATCHER" | sed -n 's/.*grep -E "(\(.*\))".*/\1/p')
case "$POLRE" in "review-merge-policy|quality-gate") ok "the dispatcher's own policy regex is still $POLRE" ;; *) bad "the dispatcher's policy regex changed to '$POLRE' — update the lib's case list in gate_fastlane_classify_raw to match" ;; esac
grep -q '\*review-merge-policy\*|\*quality-gate\*|\*gate-fastlane\*|\*gate-lane\*) cls="POLICY"' "$LIB" && ok "the lib's policy case list carries both of the dispatcher's alternatives plus the lane's own two" || bad "lib policy case list drifted from the dispatcher's regex"
# a here-string, not `printf | grep -q`: the block outgrew one stdio buffer, and under pipefail the early-exiting `grep -q`
# then made the writer die of SIGPIPE — this assertion went red on a dispatcher that was correct
# NOTE what this does NOT prove: that \$BRANCH_SHA is the commit that lands. The merge pushes whatever origin/$BRANCH is at push time,
# so that property is enforced — and tested behaviourally — by the push-time confirm (§4f, §5e), not by this call's argument text.
grep -q 'gate_fastlane_decide git_rig "origin/$DEFAULT_BRANCH" "$BRANCH_SHA" "$POLICY_FILES"' <<< "$DECBLK" && ok "the decision is taken on the commit the run claimed (\$BRANCH_SHA) and honors the policy self-protection answer (that this is what lands is NOT assumed here — see §4f/§5e)" || bad "decide call no longer passes BRANCH_SHA / POLICY_FILES"
grep -q 'fast_lane_mechanical_checks_no_llm_review' "$DISPATCHER" && grep -q 'GATE_LANE:-normal}" = "fast"' "$DISPATCHER" && ok "a fast-lane PASS never records 'quorum_0_of_0_independent_sessions'" || bad "the PASS reason is not lane-aware"
grep -q 'reviewers: \$reviewers, dry_run: \$dry_run, lane: \$lane' "$DISPATCHER" && ok "dispatcher_complete carries a lane field (consumers can filter fast-lane runs)" || bad "dispatcher_complete lost its lane field"
grep -q '^lane: \$GATE_LANE$' "$DISPATCHER" && ok "the gate-run bead records its lane" || bad "run bead description has no lane: line"
# the push-time confirmation: the check and the act are ONE variable, with NOTHING between them (gate round 2, issue 2)
L_PCB=$(grep -n 'SELFTEST-EXTRACT fastlane-push-confirm: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_PCE=$(grep -n 'SELFTEST-EXTRACT fastlane-push-confirm: END' "$DISPATCHER" | head -1 | cut -d: -f1)
L_PUSH=$(grep -n -F 'if git_rig push origin "${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_LATE=$(grep -n 'LIVE re-check #2 — AUTHORITATIVE' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_PCB" ] && [ -n "$L_PCE" ] && [ -n "$L_PUSH" ] && [ -n "$L_LATE" ] && [ "$L_LATE" -lt "$L_PCB" ] && [ "$L_PCE" -lt "$L_PUSH" ]; then ok "the lane confirm (lines $L_PCB-$L_PCE) comes after the late bead re-check (line $L_LATE) and before the FF push (line $L_PUSH)"; else bad "push-confirm placement: late-recheck=$L_LATE confirm=$L_PCB-$L_PCE push=$L_PUSH"; fi
BETWEEN=$(sed -n "$((${L_PCE:-0}+1)),$((${L_PUSH:-0}-1))p" "$DISPATCHER" | grep -v -E '^[[:space:]]*(#.*)?$' || true)
[ -z "$BETWEEN" ] && ok "NOTHING executable sits between the confirm and the push — no window to move the tip in (only comments)" || bad "code between the confirm and the push: $BETWEEN"
grep -q 'gate_fastlane_confirm git_rig "$CUR_MAIN" "$CUR_BRANCH"' <<< "$PCBLK" && grep -q '"${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH"' <<< "$(sed -n "${L_PUSH:-1}p" "$DISPATCHER")" && ok "the confirm is asked about \$CUR_BRANCH — the very variable the push sends (decided variable == acted-on variable)" || bad "confirm and push no longer share \$CUR_BRANCH"
L_RETRY_B=$(grep -n 'while \[ "\$MERGE_ATTEMPT" -lt "\$MAX_MERGE_RETRIES" \]' "$DISPATCHER" | head -1 | cut -d: -f1)
L_RETRY_E=$(grep -n 'Stopping retry loop' "$DISPATCHER" | head -1 | cut -d: -f1)
RETRYBODY=$(sed -n "${L_RETRY_B:-1},${L_RETRY_E:-1}p" "$DISPATCHER")
case "$RETRYBODY" in *'"$MERGE_RESULT" = "failed_lane_revoked"'*) ok "failed_lane_revoked is a NON-retryable merge result (retrying the push would only be refused again)" ;; *) bad "failed_lane_revoked is not in the non-retryable list of the merge retry loop" ;; esac
L_LRB=$(grep -n 'SELFTEST-EXTRACT fastlane-lane-revoked: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_GENFAIL=$(grep -n -F 'if [[ "$MERGE_RESULT" = failed* ]]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_LRB" ] && [ -n "$L_GENFAIL" ] && [ "$L_LRB" -lt "$L_GENFAIL" ] && [ -n "$L_RETRY_E" ] && [ "$L_RETRY_E" -lt "$L_LRB" ]; then ok "the revoked-run block (line $L_LRB) sits after the merge loop and BEFORE the generic failed_* → FAIL handling (line $L_GENFAIL)"; else bad "revoked-run block placement: loop-end=$L_RETRY_E block=$L_LRB generic-fail=$L_GENFAIL"; fi
# the lane is decided only for a run that will actually start: after the live-sibling yield (5b) and the size park (5c), before Step 6
L_5C=$(grep -n '^# ── Step 5c' "$DISPATCHER" | head -1 | cut -d: -f1)
L_S6=$(grep -n '^# ── Step 6: Create gate-run tracking bead' "$DISPATCHER" | head -1 | cut -d: -f1)
L_RECE=$(grep -n 'SELFTEST-EXTRACT fastlane-record: END' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_5C" ] && [ -n "$L_S6" ] && [ -n "$L_DECBLK" ] && [ -n "$L_RECE" ] && [ "$L_5C" -lt "$L_DECBLK" ] && [ "$L_RECE" -lt "$L_S6" ]; then ok "the lane decision + record (lines $L_DECBLK-$L_RECE) come AFTER the yield/park guards (Step 5c, line $L_5C) and before Step 6 (line $L_S6) — no test runs under the gate lock for a marker that then yields or parks, and no gate_lane event is written for a decision that never ran"; else bad "lane decision placement: 5c=$L_5C decide=$L_DECBLK record-end=$L_RECE step6=$L_S6"; fi
for c in no-changed-files decision-errored lib-not-loaded revoked-at-push; do
  grep -q "GATE_LANE_REASON_CODE=\"$c\"" "$DISPATCHER" && ok "the dispatcher sets reason code '$c' on its own fallback path" || bad "the dispatcher lost reason code '$c' (its fallback would read as 'sem reason_code')"
done
grep -q 'gc-gate-fs-fastlane-\*' "$DISPATCHER" && ok "the stale-worktree reaper covers the fast lane's test worktree" || bad "reaper does not match gc-gate-fs-fastlane-*"
grep -q 'gc-gate-fl-diff-\*' "$DISPATCHER" && ok "the reaper also sweeps a leaked scan diff" || bad "reaper does not sweep gc-gate-fl-diff-*"
# the recovery the bypass comment relies on is real: the guard's Vector B reconcile, run on the REAL function
GUARD="$SELF_DIR/quality-gate-guard.sh"
RZ="$(awk '/^reconcile_zero_verdict_run_action\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$GUARD" 2>/dev/null)"
if [ -n "$RZ" ]; then
  rz() { "$B32" -c "$RZ"$'\n''reconcile_zero_verdict_run_action "$@"' _ "$@"; }
  [ "$(rz 30 10 dispatching)" = "supersede:requeue-marker" ] && ok "a crashed fast-lane run (running, 0 verdicts, marker dispatching, past grace) → guard Vector B: supersede:requeue-marker (closed + re-queued, lane redone)" || bad "guard no longer re-queues a zero-verdict run whose marker is dispatching: $(rz 30 10 dispatching)"
  [ "$(rz 5 10 dispatching)" = "skip" ] && ok "…and inside the grace window it leaves a brand-new run alone" || bad "grace window broke: $(rz 5 10 dispatching)"
  [ "$(rz 30 10 "")" = "skip" ] && ok "…and an unknown marker state is never guessed at (skip)" || bad "unknown marker state no longer skips: $(rz 30 10 "")"
else
  bad "reconcile_zero_verdict_run_action not found in quality-gate-guard.sh — the crash-recovery claim in the dispatcher bypass comment is no longer backed"
fi
# the fast lane's own temp names must be ones the reaper knows (no silent leak family)
grep -q 'gc-gate-fs-fastlane-\$\$' "$LIB" && grep -q 'gc-gate-fl-diff-XXXXXX' "$LIB" && ok "the lib names its temp files exactly as the reaper expects" || bad "lib/reaper temp-name drift"

# ── 7. record: marker metadata written AND read back; jsonl event; a failed write is said out loud ────────────
echo "── 7. gate_fastlane_record ──"
rec_case() { # lane-written lane-read-back
  : > "$T/bd.log"; rm -f "$T/qg.jsonl"
  REC_ERR=$(PATH="$T/bin:$PATH" FAKE_BD_LOG="$T/bd.log" FAKE_BD_LANE="$2" "$B32" -c '
    set -euo pipefail
    source "$1"
    GATE_LANE="$3"; GATE_LANE_REASON="all DOC"; GATE_LANE_COUNTS="doc=2 test=0 prompt=0 code=0"; GATE_LANE_FILES=$(printf "DOC\tdocs/a.md\nDOC\tdocs/b.md\n")
    gate_fastlane_record /city mk-1 ga-x feat/ga-x gascity 1 "$4"
  ' _ "$LIB" "$2" "$1" "$T/qg.jsonl" 2>&1 >/dev/null) || REC_ERR="ABORTED: $REC_ERR"
}
rec_case fast fast
grep -q 'gate.lane=fast' "$T/bd.log" && grep -q 'gate.lane_reason=' "$T/bd.log" && grep -q 'gate.lane_files=DOC:docs/a.md; DOC:docs/b.md -q' "$T/bd.log" && ok "marker metadata written: gate.lane / gate.lane_reason / gate.lane_files (the files that decided)" || bad "marker metadata: $(cat "$T/bd.log")"
[ -z "$REC_ERR" ] && ok "read-back matched → no warning" || bad "unexpected stderr: $REC_ERR"
J=$(tail -1 "$T/qg.jsonl" 2>/dev/null)
[ "$(printf '%s' "$J" | jq -r '[.event,.lane,.would_have_reviewers,.counts]|join("|")' 2>/dev/null)" = "gate_lane|fast|1|doc=2 test=0 prompt=0 code=0" ] && ok "jsonl gate_lane event carries lane, counts and the reviewers a normal run would have used (for the weekly tally)" || bad "jsonl event: $J"
[ "$(printf '%s' "$J" | jq -r '[.reason_code,.dry_run]|join("|")' 2>/dev/null)" = "|0" ] && ok "jsonl event carries reason_code (empty when the caller set none) and dry_run=0 by default" || bad "jsonl reason_code/dry_run: $J"
: > "$T/bd.log"; rm -f "$T/qg-code.jsonl"
PATH="$T/bin:$PATH" FAKE_BD_LOG="$T/bd.log" FAKE_BD_LANE=normal DRY_RUN=1 "$B32" -c 'set -euo pipefail; source "$1"; GATE_LANE=normal; GATE_LANE_REASON=r; GATE_LANE_REASON_CODE=code-or-prompt; GATE_LANE_COUNTS=c; GATE_LANE_FILES=f; gate_fastlane_record /city mk-1 ga-x b gascity 1 "$2"' _ "$LIB" "$T/qg-code.jsonl" >/dev/null 2>&1
[ "$(jq -r '[.reason_code,.dry_run]|join("|")' "$T/qg-code.jsonl" 2>/dev/null)" = "code-or-prompt|1" ] && ok "jsonl event carries the reason_code the decision set, and dry_run=1 under DRY_RUN=1" || bad "jsonl event: $(cat "$T/qg-code.jsonl" 2>/dev/null)"
rec_case fast normal
case "$REC_ERR" in *"NOT confirmed"*) ok "a write the read-back does not confirm is reported, not assumed" ;; *) bad "unconfirmed write was silent: '$REC_ERR'" ;; esac
[ -s "$T/qg.jsonl" ] && ok "…and the jsonl event is still written" || bad "jsonl event lost when the marker write was unconfirmed"

# a jq that fails: the event cannot be written, and that must be SAID, not swallowed
mkdir -p "$T/bin2"; printf '#!/bin/sh\nexit 1\n' > "$T/bin2/jq"; chmod +x "$T/bin2/jq"
JQ_ERR=$(PATH="$T/bin2:$T/bin:$PATH" FAKE_BD_LOG="$T/bd.log" FAKE_BD_LANE=fast "$B32" -c '
  set -euo pipefail; source "$1"
  GATE_LANE=fast; GATE_LANE_REASON=r; GATE_LANE_COUNTS=c; GATE_LANE_FILES=f
  gate_fastlane_record /city mk-1 ga-x b gascity 1 "$2"
' _ "$LIB" "$T/qg-jqfail.jsonl" 2>&1 >/dev/null) || JQ_ERR="ABORTED: $JQ_ERR"
case "$JQ_ERR" in *"could not append the gate_lane event"*) ok "a failing jq: the lost gate_lane event is reported (the tally would under-count) — not swallowed" ;; *) bad "failing jq was silent: '$JQ_ERR'" ;; esac

# ── 8. mutation checks of THIS harness ─────────────────────────────────────────────────────────────────────
echo "── 8. mutation checks: the assertions above must be load-bearing ──"
# 8a. a bypass that never fires must be caught by the finalize assertion
BYPBLK_USE="$(printf '%s\n' "$BYPBLK" | sed 's/^if \[ "\$GATE_LANE" = "fast" \]; then/if false; then/')"
byp_case fast fast
case "$BYP_OUT" in *"FINALIZE overall=PASS"*) bad "mutant bypass (never fires) still passed the finalize assertion — the harness is blind" ;; *) ok "a bypass that never fires turns the fast-lane assertion RED" ;; esac
BYPBLK_USE=""
# 8b. a lib that loses its symlink guard would grant fast to a symlinked doc
sed 's/120000|160000) GATE_FL_STATE="unclassifiable".*; return 0 ;;/120000|160000) ;;/' "$LIB" > "$T/mut-nosymlink.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-nosymlink.lib.sh"; then bad "mutation 8b did not change the lib (sed pattern drifted)"; else
  S=$(git -C "$REPO" rev-parse s-link); FL_LIB_OVERRIDE="$T/mut-nosymlink.lib.sh" decide "$S" ""
  [ "$D_LANE" = "fast" ] && ok "without the symlink guard a symlinked 'doc' WOULD be granted fast — the real guard is what holds it back" || bad "mutant without the symlink guard still read $D_LANE — the symlink assertion is not load-bearing"
fi
# 8c. a lib that reads 'could not scan' as clean would grant fast to a binary .md
perl -0pe 's/\*\) _gate_fastlane_normal "scan-failed" "content scan could not run.*?\n\s*return 0 ;;/*) ;;/s' "$LIB" > "$T/mut-scanclean.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-scanclean.lib.sh" || ! "$B32" -n "$T/mut-scanclean.lib.sh" 2>/dev/null; then
  # the sed mutant must still be valid bash; if my sed drifted, say so rather than pass vacuously
  bad "mutation 8c did not produce a valid, different lib (sed pattern drifted)"
else
  S=$(git -C "$REPO" rev-parse s-bin); FL_LIB_OVERRIDE="$T/mut-scanclean.lib.sh" decide "$S" ""
  [ "$D_LANE" = "fast" ] && ok "if 'could not scan' read as clean, a binary .md WOULD be granted fast — the real code refuses" || bad "mutant that reads unscannable as clean still read $D_LANE — assertion not load-bearing"
fi
# 8d. a lib that hands the tests the caller's full PATH would let an unreviewed test find the tools installed under $HOME (the stub 'secret')
sed 's/PATH="\$tpath"/PATH="$PATH"/' "$LIB" > "$T/mut-fullpath.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-fullpath.lib.sh"; then bad "mutation 8d did not change the lib (sed pattern drifted)"; else
  S=$(git -C "$REPO" rev-parse s-nosecret)
  FL_LIB_OVERRIDE="$T/mut-fullpath.lib.sh" decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  [ "$D_LANE" = "normal" ] && ok "without the PATH filter the stub 'secret' (a tool under $HOME) IS reachable and the scenario goes red — the filter is what drops $HOME tools" || bad "mutant with the full PATH still read $D_LANE — the PATH assertion is not load-bearing"
fi
# 8e. a producer whose code the tally does not bucket — the exact shape of the gate's blocking issue 2 — must turn §4e red
sed 's/_gate_fastlane_normal "code-or-prompt"/_gate_fastlane_normal "made-up-code"/' "$LIB" > "$T/mut-badcode.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-badcode.lib.sh"; then bad "mutation 8e did not change the lib (sed pattern drifted)"; else
  e2e_probe "$(head_of s-mdpy)" "" FL_LIB_OVERRIDE="$T/mut-badcode.lib.sh"
  if e2e_ok code-or-prompt; then bad "a lib emitting a code the tally does not know still passed §4e — the end-to-end check is blind"
  else ok "a lib emitting a code the tally does not bucket turns §4e RED (code='$D_CODE' → bucket '$E_BUCKET')"; fi
fi
# 8f. a producer that swaps two codes (code diffs reported as policy) must turn §4e red too — a bucket that EXISTS is not enough
sed 's/_gate_fastlane_normal "code-or-prompt"/_gate_fastlane_normal "policy"/' "$LIB" > "$T/mut-swapcode.lib.sh"
if cmp -s "$LIB" "$T/mut-swapcode.lib.sh"; then bad "mutation 8f did not change the lib (sed pattern drifted)"; else
  e2e_probe "$(head_of s-mdpy)" "" FL_LIB_OVERRIDE="$T/mut-swapcode.lib.sh"
  if e2e_ok code-or-prompt; then bad "a lib reporting code diffs as 'policy' still passed §4e"
  else ok "a lib that reports code diffs as the gate's own policy turns §4e RED (the cited misbucketing)"; fi
fi
# 8g. a confirm that always says yes — the exact shape of the gate's blocking issue 2 — must turn §4f red
sed 's/^gate_fastlane_confirm() {$/gate_fastlane_confirm() { return 0/' "$LIB" > "$T/mut-confirmyes.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-confirmyes.lib.sh"; then bad "mutation 8g did not change the lib (sed pattern drifted)"; else
  REPO="$T/repo2"; FL_LIB_OVERRIDE="$T/mut-confirmyes.lib.sh" dconf "$FA" main "$FB_PY"; REPO="$REPO_MAIN"
  [ "$C_RC" = "0" ] && ok "a confirm that always says yes WOULD wave the moved tip through (rc=0) — the real confirm is what refuses it" || bad "mutant confirm that always says yes still read rc=$C_RC — §4f is not load-bearing"
fi
# 8h. a push step that notices the revocation but does not return must reach the push in §5e
PCBLK_USE="$(printf '%s\n' "$PCBLK" | sed 's/return 1/:/')"
if [ "$PCBLK_USE" = "$PCBLK" ]; then bad "mutation 8h did not change the push-confirm block (sed pattern drifted)"; else
  pc_case "$FA" "$M0_R2" "$FB_PY"
  pc_reached && ok "a push step that logs the revocation but forgets to return WOULD reach the push — the 'return 1' is what holds it" || bad "mutant push step without its return still did not reach the push — §5e is not load-bearing"
fi
PCBLK_USE=""
# 8i. a lib whose DOC class is 'any .md' again (the round-2 blocking issue 1) must turn the class assertion red
perl -0pe 's/(\n  echo CODE\n  return 0\n\})/\n  if [ "\$ext" = "md" ]; then echo DOC; return 0; fi$1/' "$LIB" > "$T/mut-anymd.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-anymd.lib.sh" || ! "$B32" -n "$T/mut-anymd.lib.sh" 2>/dev/null; then bad "mutation 8i did not produce a valid, different lib (perl pattern drifted)"; else
  S=$(git -C "$REPO" rev-parse s-unkmd); FL_LIB_OVERRIDE="$T/mut-anymd.lib.sh" decide "$S" ""
  [ "$D_LANE" = "fast" ] && ok "if every .md were a doc again, an unlisted NOTES.md WOULD be granted fast — the positive DOC list is what keeps it in the gate" || bad "mutant with 'any .md is a doc' still read $D_LANE — the class assertion is not load-bearing"
fi
# 8j. a bypass that forgets the flag (gate round 3, blocking issue 1) must turn the lock assertions red: Step 9 would free the lock before the heavy part
BYPBLK_USE="$(printf '%s\n' "$BYPBLK" | sed '/^  GATE_SWEEP_HAS_MORE_WORK=1/d')"
if [ "$BYPBLK_USE" = "$BYPBLK" ]; then bad "mutation 8j did not change the bypass block (sed pattern drifted)"; else
  byp_lock_case 0
  case "$BL_OUT" in *"AT-FULL-SUITE lock=RELEASED"*) ok "a bypass without GATE_SWEEP_HAS_MORE_WORK WOULD reach the full-suite check with the lock already freed — the flag is what holds it" ;; *) bad "mutant bypass without the flag still held the lock at the full-suite check — §5c'' is not load-bearing" ;; esac
fi
# 8k/8l. a bypass that holds the lock but cannot release it (Step 9 consumed _gate_cleanup_done; or the flag is still set when the trap runs) leaks it until GATE_LOCK_MAX_AGE
BYPBLK_USE="$(printf '%s\n' "$BYPBLK" | sed 's/ _gate_cleanup_done=0; cleanup_reviewer_sessions; }/ cleanup_reviewer_sessions; }/')"
if [ "$BYPBLK_USE" = "$BYPBLK" ]; then bad "mutation 8k did not change the bypass block (sed pattern drifted)"; else
  byp_lock_case 0
  [ "$(bl_count LOCK-RELEASED)" = "0" ] && ok "an exit trap that does not re-arm the cleanup WOULD leak the lock (Step 9 consumed the dedup flag) — the re-arm is what frees it" || bad "mutant exit trap without the re-arm still released the lock — the release assertion is not load-bearing"
fi
BYPBLK_USE="$(printf '%s\n' "$BYPBLK" | sed 's/_fastlane_exit() { GATE_SWEEP_HAS_MORE_WORK=0; /_fastlane_exit() { /')"
if [ "$BYPBLK_USE" = "$BYPBLK" ]; then bad "mutation 8l did not change the bypass block (sed pattern drifted)"; else
  byp_lock_case 0
  [ "$(bl_count LOCK-RELEASED)" = "0" ] && ok "an exit trap that leaves the flag set WOULD leak the lock (the cleanup would skip its release) — clearing it is what frees it" || bad "mutant exit trap that keeps the flag still released the lock — the release assertion is not load-bearing"
fi
BYPBLK_USE=""
# 8m. an fl_env that no longer pins (back to a bare `env`) must turn §5f red: the caller's switch would reach the lib again
FL_ENV_DEF="$(declare -f fl_env)"
fl_env() { env "$@"; }
M8M=$( export GATE_FASTLANE_ENABLED=0; decide "$(head_of s-docs)" ""; printf '%s' "$D_LANE" )
eval "$FL_ENV_DEF"
[ "$M8M" = "normal" ] && ok "an fl_env that does not pin WOULD let the caller's GATE_FASTLANE_ENABLED=0 through (lane=normal) — the pin is what keeps the cases hermetic" || bad "mutant fl_env without the pin still read lane='$M8M' — §5f is not load-bearing"
# 8n. a lib without the "no diff text = nothing read" guard (gate round 3, low finding) must turn §4e' red: the unread diff would be granted fast
sed '/^  \[ -s "\$tmp" \] || { GATE_FL_SCAN_OUT=/d' "$LIB" > "$T/mut-nonull.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-nonull.lib.sh"; then bad "mutation 8n did not change the lib (sed pattern drifted)"; else
  M8N=$(null_scan "$(head_of s-docs)" "$T/mut-nonull.lib.sh")
  case "$M8N" in fast\|*) ok "without the guard, a diff whose text was never read WOULD be granted fast ('$M8N') — the guard is what keeps it in the gate" ;; *) bad "mutant lib without the guard still read '$M8N' — §4e' is not load-bearing" ;; esac
fi
# 8o-8q. the SCANNER's single rule is load-bearing (gate round 4): a scanner that backs off any one of its three decisions must read the reviewer's formats as clean
mut_scan() { # name sed-expr diff-printf-format want-mutant-rc — runs the real rule's diff through a scanner mutated by the sed expression
  local f="$T/mut-scan-$1.py" real mut
  sed "$2" "$SCAN" > "$f"
  if cmp -s "$SCAN" "$f" || ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null; then bad "mutation $1 did not produce a valid, different scanner (sed pattern drifted)"; return; fi
  real=0; printf "$3" | python3 "$SCAN" >/dev/null 2>&1 || real=$?
  mut=0;  printf "$3" | python3 "$f"    >/dev/null 2>&1 || mut=$?
  if [ "$real" = "1" ] && [ "$mut" = "0" ]; then ok "mutant '$1': the real scanner flags the case (rc=1) and the mutant reads it clean (rc=0) — the decision is what holds it"
  else bad "mutant '$1': real rc=$real, mutant rc=$mut — the assertion is not load-bearing"; fi
}
# 8o. a threshold one digit too high (9+): the 8-digit landline '3333-4444' goes through
mut_scan threshold 's/{7,}")/{8,}")/' "${H1}@@ -0,0 +1 @@\n+fixo 3333-4444\n"
# 8p. the separator class back to a LIST (space . - / ( ) +): markdown emphasis between groups that are each under 8 digits goes through
mut_scan separators 's/\[\\W_\]\*/[\\s.()\/+-]*/' "${H1}@@ -0,0 +1 @@\n+fone (**31**) **9999**-**8888**\n"
# 8q. no adjacent-line join (each added line replaces the run): a phone wrapped across two lines goes through
mut_scan crossline 's/run.append((lineno, line\[1:\]))/run = [(lineno, line[1:])]/' "${H1}@@ -0,0 +1,2 @@\n+ligar (31) 99999-\n+8888 amanha\n"
echo
echo "== gate-fastlane.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
