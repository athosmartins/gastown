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
#      "clean" must turn the matching assertion red.
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

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

# ── 1. the scanner ────────────────────────────────────────────────────────────────────────────────────────────
echo "── 1. scanner: findings, clean, and 'could not scan' ──"
mkdiff() { printf 'diff --git a/docs/x.md b/docs/x.md\n--- a/docs/x.md\n+++ b/docs/x.md\n@@ -0,0 +1,3 @@\n%s\n' "$1"; }
scan_case() { # name body want_rc
  local out rc=0
  out=$(mkdiff "$2" | python3 "$SCAN" 2>&1) || rc=$?
  if [ "$rc" = "$3" ]; then ok "scan: $1 → rc=$3"; else bad "scan: $1 → rc=$rc, want $3 ($out)"; fi
}
scan_case "clean prose"                 '+Este documento descreve o gate.'                       0
scan_case "formatted CPF"               '+cliente 529.982.247-25 ligou'                         1
scan_case "bare 11 digits, valid DV"    '+cpf 52998224725 fim'                                   1
scan_case "11 digits, invalid DV"       '+id 12345678901 fim'                                    0
scan_case "epoch-ms timestamp"          '+ts 1790815326123'                                      0
scan_case "phone +55"                   '+fone +55 31 99999-8888'                                1
scan_case "phone (DDD) landline"        '+fone (31) 3333-4444'                                   1
scan_case "WhatsApp-style id"           '+jid 5531999998888@s.whatsapp.net'                      1
scan_case "AWS key"                     '+AKIAIOSFODNN7EXAMPLE'                                  1
scan_case "private key header"          '+-----BEGIN RSA PRIVATE KEY-----'                       1
scan_case "secret assignment"           '+API_TOKEN = "a1b2c3d4e5f6g7h8i9j0k1l2"'                1
scan_case "placeholder assignment"      '+API_TOKEN = "<your-token-here-0123456789>"'            0
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
path_case DOC    docs/runbooks/a.md README.md reports/2026-09/relatorio.md docs/x.txt reports/leads.csv runbooks/a.rst \
                 docs/deep/er/x.md .github/PULL_REQUEST_TEMPLATE.md whatsapp_automation/docs/data_dictionary.md README.MD
path_case TEST   tests/test_a.py tests/fixtures/x.json test_foo.py foo_test.go web/app.test.ts web/app.spec.js \
                 packs/town-deltas/assets/gate-x.selftest.sh tests/conftest.py __tests__/a.js packs/x/assets/tests/daemon-refresh.test.sh
path_case PROMPT skills/foo/SKILL.md .claude/skills/x/SKILL.md CLAUDE.md docs/CLAUDE.md AGENTS.md agents/mayor/prompt.template.md \
                 commands/gate-done.md .claude/commands/x.md packs/town-deltas/template-fragments/a.md prompts/x.txt \
                 formulas/mol-x.toml prompt_v2.md docs/fragments/x.md skill.md Skills/Foo/Skill.MD
path_case CODE   scripts/foo.py packs/x/assets/quality-gate-dispatcher.sh deploy_deps.json config.toml city.toml \
                 .github/workflows/ci.yml requirements.txt data/leads.csv docs/x.patch docs/run.sh docs/x.json docs/x.html \
                 packs/x/assets/prod-tests/wa/story-1.sh Makefile app/prompt_loader.py docs/img/x.png

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

D_LANE=""; D_REASON=""; D_FILES=""
decide() { # decide <head> <policy> [ENV=VAL ...]  -> D_LANE / D_REASON / D_FILES
  local head="$1" policy="$2" out; shift 2
  out=$(env GATE_FS_TMPDIR="$T/tmp" FL_LIB="${FL_LIB_OVERRIDE:-$LIB}" FL_REPO="$REPO" FL_BASE="${FL_BASE:-main}" FL_HEAD="$head" FL_POLICY="$policy" "$@" \
        "$B32" -c '
    set -euo pipefail
    source "$FL_LIB"
    gfn() { git -C "$FL_REPO" "$@"; }
    gate_fastlane_decide gfn "$FL_BASE" "$FL_HEAD" "$FL_POLICY"
    printf "%s\n%s\n%s\n" "$GATE_LANE" "$GATE_LANE_REASON" "$(gate_fastlane_files_oneline)"
  ' 2>"$T/decide.err") || { D_LANE="ABORTED"; D_REASON="decide() aborted under set -euo pipefail: $(cat "$T/decide.err")"; D_FILES=""; return; }
  D_LANE=$(printf '%s\n' "$out" | sed -n 1p); D_REASON=$(printf '%s\n' "$out" | sed -n 2p); D_FILES=$(printf '%s\n' "$out" | sed -n 3p)
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
# 4b. mechanical scan
S=$(mkbr s-cpf 'docs/c.md=cliente 529.982.247-25 ligou\n');                  decide "$S" "";  check "a CPF on an added line" normal "cpf"
case "$D_REASON $D_FILES" in *529.982*|*52998224725*) bad "the lane output echoes the CPF value" ;; *) ok "the lane output never echoes the matched value" ;; esac
S=$(mkbr s-phone 'docs/p.md=ligar +55 31 99999-8888\n');                     decide "$S" "";  check "a phone number on an added line" normal "telefone"
S=$(mkbr s-key 'docs/k.md=chave AKIAIOSFODNN7EXAMPLE\n');                    decide "$S" "";  check "a credential on an added line" normal "aws-key"
# 4c. tests: run, env scrubbed, stdin closed, bounded
S=$(mkbr s-testok 'docs/n.md=x\n' 'tests/ok.selftest.sh=exit 0\n');          decide "$S" "";  check "docs + a new green test" fast "ran green"; no_leftovers "green test"
S=$(mkbr s-testbad 'tests/bad.selftest.sh=exit 3\n');                        decide "$S" "";  check "a new test that FAILS stays in the gate (never a FAIL verdict)" normal "rc=3"; no_leftovers "failing test"
S=$(mkbr s-scrub 'tests/scrub.selftest.sh=[ -z "${FL_SECRET:-}" ] || exit 1\ncase "$HOME" in */gc-gate-fs-fastlane-*) ;; *) exit 1 ;; esac\n')
decide "$S" "" FL_SECRET=hunter2;  check "tests run with a scrubbed env (inherited secret absent, HOME inside the worktree)" fast "ran green"
# the tests' PATH must not reach user bin dirs (the vault CLI `secret`, `notify`, `bd`, `gc` live under $HOME)
mkdir -p "$T/fakehome/.local/bin"; printf '#!/bin/sh\necho VAULT-REACHED\n' > "$T/fakehome/.local/bin/secret"; chmod +x "$T/fakehome/.local/bin/secret"
[ "$(PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" command -v secret)" = "$T/fakehome/.local/bin/secret" ] && ok "premise: a stub 'secret' IS on the caller's PATH under \$HOME" || bad "premise broken: the stub 'secret' is not findable"
S=$(mkbr s-nosecret 'tests/nosecret.selftest.sh=if command -v secret >/dev/null 2>&1; then exit 12; fi\ncommand -v git >/dev/null || exit 13\ncommand -v jq >/dev/null || exit 14\nexit 0\n')
# a controlled PATH: the stub dir under the (fake) HOME first, then only system/Homebrew dirs — so the REAL ~/.local/bin cannot leak in
decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin";  check "tests run WITHOUT user bin dirs on PATH (no vault CLI) but with git/jq" fast "ran green"
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
  FL_REPO="$REPO" FL_LIB="$LIB" GATE_FS_TMPDIR="$T/tmp" "$B32" "$T/realdec.sh" 2>&1 | tail -1
}
real_case() { # name branch want
  local got; got=$(real_dec "$(git -C "$REPO" rev-parse "$2")")
  if [ "$got" = "$3" ]; then ok "real Step 5 block + real lib + real git: $1 → ${3#RESULT }"; else bad "real Step 5 block: $1 → '$got', want '$3'"; fi
}
real_case "branch with only docs/*.md takes the fast lane (0 reviewers)"  s-docs   "RESULT lane=fast tier=FAST-LANE rev=0"
real_case "control: a skill .md stays in the normal gate"                  s-skill  "RESULT lane=normal tier=NON-CODE rev=1"
real_case "control: .md + one .py stays in the normal gate"                s-mdpy   "RESULT lane=normal tier=NON-CODE rev=1"
real_case "docs with a CPF stays in the normal gate"                       s-cpf    "RESULT lane=normal tier=NON-CODE rev=1"

# 5c. the Step 7 bypass
byp_case() { # name lane
  { cat <<'HDR'
set -euo pipefail
BRANCH="b"; GATE_LANE_REASON="r"
log() { echo "LOG: $*"; }
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

# 5d. the BSD seq hazard this design routes around (informational on GNU userland)
if [ "$(seq 1 0 | wc -l | tr -d ' ')" = "2" ]; then ok "this host's seq counts DOWN (seq 1 0 prints 2 lines) — hence an explicit branch, not REQUIRED_REVIEWERS=0"
else ok "seq 1 0 prints nothing here (GNU) — the explicit bypass is still the contract"; fi

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
sed -n "${L_ZERO:-1},$((${L_ZERO:-1}+1))p" "$DISPATCHER" | grep -q 'continue' && ok "…and that guard really does \`continue\` past the run" || bad "the zero-verdict guard no longer continues"
L_POL=$(grep -n -E '^POLICY_FILES=' "$DISPATCHER" | head -1 | cut -d: -f1)
L_DECBLK=$(grep -n 'SELFTEST-EXTRACT fastlane-decide: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_POL" ] && [ -n "$L_DECBLK" ] && [ "$L_POL" -lt "$L_DECBLK" ]; then ok "POLICY_FILES (line $L_POL) is computed before the lane decision (line $L_DECBLK)"; else bad "POLICY_FILES is not defined before the lane decision ($L_POL / $L_DECBLK)"; fi
POLRE=$(grep -m1 -E '^POLICY_FILES=' "$DISPATCHER" | sed -n 's/.*grep -E "(\(.*\))".*/\1/p')
case "$POLRE" in "review-merge-policy|quality-gate") ok "the dispatcher's own policy regex is still $POLRE" ;; *) bad "the dispatcher's policy regex changed to '$POLRE' — update the lib's case list in gate_fastlane_classify_raw to match" ;; esac
grep -q '\*review-merge-policy\*|\*quality-gate\*|\*gate-fastlane\*|\*gate-lane\*) cls="POLICY"' "$LIB" && ok "the lib's policy case list carries both of the dispatcher's alternatives plus the lane's own two" || bad "lib policy case list drifted from the dispatcher's regex"
printf '%s\n' "$DECBLK" | grep -q 'gate_fastlane_decide git_rig "origin/$DEFAULT_BRANCH" "$BRANCH_SHA" "$POLICY_FILES"' && ok "the decision classifies the exact commit the gate merges (\$BRANCH_SHA) and honors the policy self-protection answer" || bad "decide call no longer passes BRANCH_SHA / POLICY_FILES"
grep -q 'fast_lane_mechanical_checks_no_llm_review' "$DISPATCHER" && grep -q 'GATE_LANE:-normal}" = "fast"' "$DISPATCHER" && ok "a fast-lane PASS never records 'quorum_0_of_0_independent_sessions'" || bad "the PASS reason is not lane-aware"
grep -q 'reviewers: \$reviewers, dry_run: \$dry_run, lane: \$lane' "$DISPATCHER" && ok "dispatcher_complete carries a lane field (consumers can filter fast-lane runs)" || bad "dispatcher_complete lost its lane field"
grep -q '^lane: \$GATE_LANE$' "$DISPATCHER" && ok "the gate-run bead records its lane" || bad "run bead description has no lane: line"
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
cat > "$T/bin/bd" <<'EOF'
#!/bin/bash
echo "$@" >> "$FAKE_BD_LOG"
case "$*" in *" show "*) printf '[{"metadata":{"gate.lane":"%s"}}]\n' "${FAKE_BD_LANE:-}" ;; esac
exit 0
EOF
chmod +x "$T/bin/bd"
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
perl -0pe 's/\*\) _gate_fastlane_normal "content scan could not run.*?\n\s*return 0 ;;/*) ;;/s' "$LIB" > "$T/mut-scanclean.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-scanclean.lib.sh" || ! "$B32" -n "$T/mut-scanclean.lib.sh" 2>/dev/null; then
  # the sed mutant must still be valid bash; if my sed drifted, say so rather than pass vacuously
  bad "mutation 8c did not produce a valid, different lib (sed pattern drifted)"
else
  S=$(git -C "$REPO" rev-parse s-bin); FL_LIB_OVERRIDE="$T/mut-scanclean.lib.sh" decide "$S" ""
  [ "$D_LANE" = "fast" ] && ok "if 'could not scan' read as clean, a binary .md WOULD be granted fast — the real code refuses" || bad "mutant that reads unscannable as clean still read $D_LANE — assertion not load-bearing"
fi
# 8d. a lib that hands the tests the caller's full PATH would let an unreviewed test reach the vault CLI
sed 's/PATH="\$tpath"/PATH="$PATH"/' "$LIB" > "$T/mut-fullpath.lib.sh"
cp "$SCAN" "$T/"
if cmp -s "$LIB" "$T/mut-fullpath.lib.sh"; then bad "mutation 8d did not change the lib (sed pattern drifted)"; else
  S=$(git -C "$REPO" rev-parse s-nosecret)
  FL_LIB_OVERRIDE="$T/mut-fullpath.lib.sh" decide "$S" "" HOME="$T/fakehome" PATH="$T/fakehome/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  [ "$D_LANE" = "normal" ] && ok "without the PATH filter the stub vault CLI IS reachable and the scenario goes red — the filter is what holds it" || bad "mutant with the full PATH still read $D_LANE — the PATH assertion is not load-bearing"
fi

echo
echo "== gate-fastlane.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
