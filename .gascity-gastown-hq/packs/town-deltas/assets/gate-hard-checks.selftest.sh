#!/usr/bin/env bash
# gate-hard-checks.selftest.sh — ga-vywjzsp: proof of gate-hard-checks.sh, the checker behind quality-gate-guard.sh
# Step 5b-pre5 (the gate's hard checks 2b template parse, 2c doc-rules lint, 2d E12 coverage, 2e third-state reads).
#
# WHY. Those four checks lived only in an orphan formula; nothing ran them (see the checker's header). This proves each one runs
# the REAL tool (copied from the tree under test) over a fixture repo and that its verdict is the right one, in both directions:
# a violation is refused, a clean diff is not, and anything the checker cannot measure is said, never read as clean or as a finding.
#
# HOW. Everything is written under a scratch dir. A fixture "city" holds copies of the real tools (GATE_HC_HQ); a fixture rig is a
# throw-away git repo whose E12 inputs are the real prompts, fragment and city.toml, so the "green base" cases are not hermetic: they
# need the E12 coverage of the tree under test to be green.
# 2b uses a stub `gc` (the real `gc lint` is not here) behind a PATH of symlinks, so "gc absent" and "jq absent" are testable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${GHC_SUT:-$HERE/gate-hard-checks.sh}"
RHQ="${GHC_HQ:-$(cd "$HERE/../../.." && pwd)}"
HQ=".gascity-gastown-hq"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

for t in git python3 jq timeout; do command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t not found"; exit 1; }; done
for f in scripts/doc-rules-lint.py packs/town-deltas/assets/third-state-reads-check.py packs/town-deltas/assets/e12-crew-doctrine.sh \
         packs/town-deltas/assets/e12-arms.sh packs/town-deltas/assets/template-fragment-lint-guard.sh city.toml; do
  [ -f "$RHQ/$f" ] || { echo "FATAL: $RHQ/$f not found (the tools the checker runs)"; exit 1; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ghc-selftest.XXXXXX")" || { echo "FATAL: no scratch dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

put() { mkdir -p "$(dirname "$1/$2")" && cat > "$1/$2"; }
commit_all() { git -C "$1" add -A >/dev/null 2>&1 && git -C "$1" commit -q -m "$2" && git -C "$1" rev-parse HEAD; }
branch_from() { git -C "$1" checkout -q -b "$3" "$2"; }   # <rig> <start> <new branch>
filler() { local i=0 s=""; while [ "$i" -lt 12 ]; do s="$s a-sentence-long-enough-to-pass-the-300-char-threshold."; i=$((i+1)); done; printf '%s\n' "$s"; }
good_doc() { printf '# Title\n\n## Contents\n\n- Alpha\n\n## Alpha\n\n'; filler; }
bad_doc() { printf '# Title\n\n## Alpha\n\n'; filler; }

# mkcity <dir> [skip-tool]: copies of the REAL tools, an empty .gc. Stubs are written over them by the cases that need one.
mkcity() {
  local c="$1" a="$1/packs/town-deltas/assets" f=""
  mkdir -p "$c/scripts" "$a" "$c/.gc" && cp "$RHQ/scripts/doc-rules-lint.py" "$c/scripts/" || return 1
  for f in third-state-reads-check.py e12-crew-doctrine.sh e12-arms.sh template-fragment-lint-guard.sh; do
    [ "$f" = "${2:-}" ] || cp "$RHQ/packs/town-deltas/assets/$f" "$a/" || return 1
  done
}
# mkrig <dir>: branch main with one base commit laid out like the HQ repo (real E12 inputs, three docs, a pack.toml).
mkrig() {
  local d="$1" hq="$1/$HQ" a="" n=""
  mkdir -p "$d" && git -C "$d" init -q && git -C "$d" symbolic-ref HEAD refs/heads/main || return 1
  git -C "$d" config user.email t@example.invalid; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  mkdir -p "$hq/agents" "$hq/packs/town-deltas/template-fragments" "$d/docs" "$d/lib" "$d/tests"
  for a in "$RHQ"/agents/*/; do
    n="$(basename "$a")"
    if [ -f "$a/prompt.template.md" ]; then mkdir -p "$hq/agents/$n" && cp "$a/prompt.template.md" "$hq/agents/$n/" || return 1; fi
  done
  cp "$RHQ/packs/town-deltas/template-fragments/town-deltas.template.md" "$hq/packs/town-deltas/template-fragments/" && cp "$RHQ/city.toml" "$hq/" || return 1
  good_doc > "$d/docs/ok.md"; bad_doc > "$d/docs/legacy.md"; bad_doc > "$d/docs/upstream.md"
  { i=0; while [ "$i" -lt 100 ]; do echo "imp $i"; i=$((i+1)); done; } > "$d/docs/imp.md"   # imported by the CLAUDE.md case; never in a diff
  ln -s ok.md "$d/docs/alias.md"   # an unchanged link named .md (AGENTS.md -> CLAUDE.md is common): never in a diff either
  printf '[pack]\nname = "t"\nschema = 2\n' > "$d/pack.toml"; printf 'x = 1\n' > "$d/lib/app.py"
  git -C "$d" add -A >/dev/null 2>&1 && git -C "$d" commit -q -m base
}

# run_sut <step> <rig> <base> <tip> <bead> [VAR=value ...] -> OUT, RC, VERDICT, REASON, LINE (the VERDICT= line)
run_sut() {
  local step="$1" rig="$2" base="$3" tip="$4" bead="$5"; shift 5
  OUT="$(env "GATE_HC_HQ=${CITY_UNDER:-$CITY}" GATE_HC_PYTHONS=python3 "$@" "${BASH:-bash}" "$SUT" "$step" "$rig" "$base" "$tip" "$bead" 2>&1)"; RC=$?
  LINE="$(printf '%s\n' "$OUT" | sed -n '/^VERDICT=/{p;q;}')"
  VERDICT="$(printf '%s\n' "$LINE" | sed -n 's/^VERDICT=\([^ ]*\) .*/\1/p')"
  REASON="$(printf '%s\n' "$LINE" | sed -n 's/^VERDICT=[^ ]* step=[^ ]* reason=\([^ ]*\).*/\1/p')"
}
expect() { # expect <label> <verdict> [reason]
  if [ "$VERDICT" = "$2" ] && { [ -z "${3:-}" ] || [ "$REASON" = "$3" ]; } && [ "$RC" -eq 0 ]; then ok "$1 -> $VERDICT${3:+ ($REASON)}"
  else bad "$1: wanted $2${3:+ ($3)}, got verdict='$VERDICT' reason='$REASON' rc=$RC :: $(printf '%s' "$OUT" | head -n 4 | tr '\n' '|' | cut -c1-300)"; fi
}
has() { printf '%s\n' "$OUT" | grep -q -- "$2" && ok "$1" || bad "$1 (no '$2' in: $(printf '%s' "$OUT" | head -n 3 | tr '\n' '|' | cut -c1-200))"; }

CITY="$WORK/city"; mkcity "$CITY" || { echo "FATAL: cannot build the fixture city"; exit 1; }
R="$WORK/rig"; mkrig "$R" || { echo "FATAL: cannot build the fixture rig"; exit 1; }
MAIN="$(git -C "$R" rev-parse main)"

echo "A. the checker exists, refuses bad input and never exits non-zero"
[ -f "$SUT" ] && ok "checker present: $(basename "$SUT")" || bad "checker missing at $SUT: nothing below can pass"
run_sut 9z "$R" "$MAIN" "$MAIN" ga-x;                      expect "unknown step" nao-consegui-medir passo-invalido
run_sut 2c "" "$MAIN" "$MAIN" ga-x;                        expect "empty rig" nao-consegui-medir entrada-vazia
run_sut 2c "$R" "--output=$WORK/pwned" "$MAIN" ga-x;       expect "a non-hex sha is refused before git sees it" nao-consegui-medir entrada-invalida
[ ! -e "$WORK/pwned" ] && ok "and --output=FILE wrote nothing" || bad "--output=FILE was read as a git option"
run_sut 2c "$WORK" "$MAIN" "$MAIN" ga-x;                   expect "a directory that is not a repository" nao-consegui-medir sem-toplevel
run_sut 2c "$R" 0000000000000000000000000000000000000001 "$MAIN" ga-x; expect "an unknown base sha" nao-consegui-medir diff-falhou
run_sut 2c "$R" "$MAIN" "$MAIN" ga-x;                      expect "an empty diff is a measured zero" nao-se-aplica

echo "B. 2c doc-rules lint (real doc-rules-lint.py, content from the tip, refs from the real git dir)"
branch_from "$R" main b_code;  printf 'x = 2\n' > "$R/lib/app.py";                      TIP="$(commit_all "$R" code)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "no .md in the diff" nao-se-aplica
branch_from "$R" main b_good;  good_doc > "$R/docs/new_ok.md";                           TIP="$(commit_all "$R" good)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a new doc with its Contents" ok
branch_from "$R" main b_bad;   bad_doc > "$R/docs/new_bad.md";                           TIP="$(commit_all "$R" bad)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a new doc over 300 chars without Contents is refused" fail violacoes-doc-rules
has "the lint's own lines reach the refusal" "contents"
# The lint echoes branch text in its violation lines: a title that spells its kill-switch phrase must not turn the refusal into desligado
branch_from "$R" main b_forge; { printf '# T\n\n## Contents\n\n- A\n\n## A\n\n'; filler; printf '\n## DISABLED via x\n\nmore\n'; } > "$R/docs/forge.md"; TIP="$(commit_all "$R" forge)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a title that spells the kill-switch phrase is still refused" fail violacoes-doc-rules
has "the violation line really echoes the title (the forgery is real)" 'DISABLED via x'
branch_from "$R" main b_legacy; printf 'one more line\n' >> "$R/docs/legacy.md";         TIP="$(commit_all "$R" legacy)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "touching a legacy doc lints the WHOLE file (the formula's rule)" fail
branch_from "$R" main b_imp
{ printf '# T\n\n## Contents\n\n- A\n\n## A\n\n'; i=0; while [ "$i" -lt 150 ]; do echo "line $i"; i=$((i+1)); done; echo "@docs/imp.md"; } > "$R/CLAUDE.md"; TIP="$(commit_all "$R" imports)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "CLAUDE.md (158 lines, its Contents fine) + the UNCHANGED docs/imp.md it imports = over 200: every .md must be extracted" fail
has "and the violation is the 200-line rule" "200"
branch_from "$R" main b_named; { printf '# T\n\n## Contents\n\n- A\n\n## A\n\n'; filler; } > "$R/CLAUDE.md"; TIP="$(commit_all "$R" claude-ok)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a clean CLAUDE.md with an UNCHANGED link named .md in the tree: a pass needs a whole tree (an @import may go through it)" nao-consegui-medir entrada-especial-fora-do-diff-1
branch_from "$R" main b_tchg;  { printf '# T\n\n## Contents\n\n- A\n\n## A\n\n'; filler; } > "$R/CLAUDE.md"; rm -f "$R/docs/imp.md"; ln -s ok.md "$R/docs/imp.md"; TIP="$(commit_all "$R" type-change)"
git -C "$R" diff --name-status "$MAIN" "$TIP" | grep -q '^T[[:space:]]docs/imp.md' && ok "(fixture: docs/imp.md really is a type change, status T)" || bad "fixture: no T status in $(git -C "$R" diff --name-status "$MAIN" "$TIP" | tr '\n' '|')"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a file that changes TYPE into a link counts as changed, even though the lint's own filter skips T: refused" nao-consegui-medir extracao-tip
# upstream/main holds docs/upstream.md only: the lint skips a file that exists upstream, which needs the REAL refs (GIT_DIR)
blob="$(git -C "$R" rev-parse main:docs/upstream.md)"; inner="$(printf '100644 blob %s\tupstream.md\n' "$blob" | git -C "$R" mktree)"
up="$(printf '040000 tree %s\tdocs\n' "$inner" | git -C "$R" mktree)"; git -C "$R" update-ref refs/remotes/upstream/main "$(git -C "$R" commit-tree "$up" -m up)"
branch_from "$R" main b_up; printf 'edit\n' >> "$R/docs/upstream.md";                    TIP="$(commit_all "$R" upstream)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a file that exists in upstream/main is skipped: the lint checked nothing, so not 'ok'" nao-se-aplica nenhum-arquivo-conferido
git -C "$R" update-ref -d refs/remotes/upstream/main
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "control: the same diff without the upstream ref is refused" fail
branch_from "$R" main b_tool;  printf '# changed\n' >> "$R/$HQ/scripts/doc-rules-lint.py" 2>/dev/null || { mkdir -p "$R/$HQ/scripts"; printf '# changed\n' > "$R/$HQ/scripts/doc-rules-lint.py"; }; good_doc > "$R/docs/t.md"; TIP="$(commit_all "$R" tool)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a diff that edits the lint is not judged by it" nao-consegui-medir ferramenta-alterada-no-diff
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x DOC_RULES_LINT=off; expect "the lint's own kill switch" desligado interruptor
# The lint matches ".md" case-insensitively (path.lower().endswith); the checker must pick the same files or it measures a different set (gate_run ga-g5chf2c)
branch_from "$R" main b_upper; bad_doc > "$R/docs/UPPER.MD";                               TIP="$(commit_all "$R" upper)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "an uppercase .MD over 300 chars without Contents is refused, the lint reads it" fail violacoes-doc-rules
branch_from "$R" main b_mixcase; bad_doc > "$R/docs/Mixed.Md";                             TIP="$(commit_all "$R" mixcase)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a .Md is a doc too" fail violacoes-doc-rules
branch_from "$R" main b_two; good_doc > "$R/docs/a.md"; bad_doc > "$R/docs/B.MD";         TIP="$(commit_all "$R" two)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a good .md beside a bad .MD: the .MD is not left out of the selection" fail violacoes-doc-rules
branch_from "$R" main b_upgood; good_doc > "$R/docs/GOOD.MD";                              TIP="$(commit_all "$R" upgood)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "control: a clean uppercase .MD is ok" ok lint-limpo
branch_from "$R" main b_impu
{ i=0; while [ "$i" -lt 100 ]; do echo "imp $i"; i=$((i+1)); done; } > "$R/docs/IMPU.MD";  IBASE="$(commit_all "$R" impu-base)"
{ printf '# T\n\n## Contents\n\n- A\n\n## A\n\n'; i=0; while [ "$i" -lt 150 ]; do echo "line $i"; i=$((i+1)); done; echo "@docs/IMPU.MD"; } > "$R/CLAUDE.md"; TIP="$(commit_all "$R" impu-claude)"
run_sut 2c "$R" "$IBASE" "$TIP" ga-x;                      expect "CLAUDE.md imports an UNCHANGED uppercase .MD: the whole-tree extract takes it too" fail violacoes-doc-rules
# The lint follows an @import to ANY regular file (resolve_import only tests S_ISREG), so the tree handed to it must hold every file a
# named doc reaches, whatever its suffix: else the 200-line count is short and the verdict is a clean one on a tree it could not see
# (gate_run ga-h3scrqt). The base has no unchanged link (alias.md): these cases ask for a CLEAN verdict, which a link makes unmeasured.
branch_from "$R" main b_nb; git -C "$R" rm -q docs/alias.md
big() { local i=0; while [ "$i" -lt "$1" ]; do echo "big $i"; i=$((i+1)); done; }
big 250 > "$R/docs/big.txt"; big 3 > "$R/docs/small.txt"; printf '@big.txt\n' > "$R/docs/chain.md"; ln -s big.txt "$R/docs/biglink.txt"
printf '@cyc_b.txt\n' > "$R/docs/cyc_a.txt"; printf '@cyc_a.txt\nmore\n' > "$R/docs/cyc_b.txt"
mkdir -p "$R/sub" && big 250 > "$R/sub/notes.txt"; big 3 > "$WORK/outside.txt"; mkdir -p "$WORK/home" && big 3 > "$WORK/home/ref.txt"
NB="$(commit_all "$R" nolink-base)"
# nd <branch> <import line> [doc path]: a small named doc (9 lines, Contents fine) on a branch of NB; TIP = its commit
nd() { branch_from "$R" "$NB" "$1"; mkdir -p "$(dirname "$R/${3:-CLAUDE.md}")"; { printf '# T\n\n## Contents\n\n- A\n\n## A\n\n'; filler; printf '%s\n' "$2"; } > "$R/${3:-CLAUDE.md}"; TIP="$(commit_all "$R" "$1")"; }
nd n_plain "no import here";            run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "control: a clean CLAUDE.md with no link in the tree is ok" ok lint-limpo
nd n_big "@docs/big.txt";               run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "CLAUDE.md (9 lines) imports an UNCHANGED 250-line .txt: the lint sees 259 lines, not 9" fail violacoes-doc-rules
has "and the violation is the 200-line rule, counted through the .txt" "imported 250 from big.txt"
nd n_small "@docs/small.txt";           run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "control: a 3-line .txt import stays under the cap" ok lint-limpo
nd n_chain "@docs/chain.md";            run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "a .md the doc imports itself imports a 250-line .txt: the closure is followed" fail violacoes-doc-rules
nd n_cyc "@docs/cyc_a.txt";             run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "two .txt files that import each other end the closure, they do not loop" ok lint-limpo
nd n_sub "@notes.txt" sub/CLAUDE.md;    run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an import is resolved from the importing doc's folder (sub/notes.txt), not from the root" fail violacoes-doc-rules
nd n_link "@docs/biglink.txt";          run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an import that goes through a symlink cannot be read as data: a clean lint is unmeasured" nao-consegui-medir entrada-especial-fora-do-diff-1
nd n_prose "mail @someone about @types/node";  run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an @word that names no file is not an import" ok lint-limpo
nd n_span 'see `@docs/biglink.txt` here';      run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an @import inside a code span is not an import (the lint's own tokenizer decides)" ok lint-limpo
nd n_fence $'```\n@docs/biglink.txt\n```'; run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an @import inside a fenced code block is not an import either" ok lint-limpo
nd n_abs "@$WORK/outside.txt";          run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an absolute import reads the HOST's file, not the branch's: a clean lint is unmeasured" nao-consegui-medir entrada-especial-fora-do-diff-1
nd n_home "@~/ref.txt";                 run_sut 2c "$R" "$NB" "$TIP" ga-x "HOME=$WORK/home"; expect "a ~ import is the host's file too" nao-consegui-medir entrada-especial-fora-do-diff-1
nd n_nofile "@/nonexistent-dir/x.txt";  run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an absolute @word that is no file is not an import" ok lint-limpo
nd n_up "@../outside.txt";              run_sut 2c "$R" "$NB" "$TIP" ga-x; expect "an import that climbs above the tree is resolved against the scratch dir, not the repo: unmeasured" nao-consegui-medir entrada-especial-fora-do-diff-1
# A closure helper that crashes or prints something else is a measurement that did not happen, never an empty closure
HB="$WORK/hbroken"; mkdir -p "$HB"; cp "$SUT" "$HB/gate-hard-checks.sh"; SUT_REAL="$SUT"; SUT="$HB/gate-hard-checks.sh"
nd n_hlp "@docs/big.txt"
printf 'import sys\nsys.exit(3)\n' > "$HB/gate-hard-checks-imports.py"
run_sut 2c "$R" "$NB" "$TIP" ga-x;                         expect "a closure helper that exits non-zero" nao-consegui-medir imports-nao-medidos
printf 'print("IMPORTS-OK special=0 files=0")\nimport sys\nsys.exit(3)\n' > "$HB/gate-hard-checks-imports.py"
run_sut 2c "$R" "$NB" "$TIP" ga-x;                         expect "a closure helper that prints a good first line and then dies is still a walk that did not finish" nao-consegui-medir imports-nao-medidos
printf 'print("IMPORTS-OK special=0 files=0 extra")\n' > "$HB/gate-hard-checks-imports.py"
run_sut 2c "$R" "$NB" "$TIP" ga-x;                         expect "a closure helper whose first line is not the exact protocol line" nao-consegui-medir imports-nao-medidos
rm -f "$HB/gate-hard-checks-imports.py"
run_sut 2c "$R" "$NB" "$TIP" ga-x;                         expect "a missing closure helper" nao-consegui-medir imports-nao-medidos
SUT="$SUT_REAL"
# Excluded directories (vendor/) are skipped by the lint: "0 file(s) checked" is a measured zero, not a clean bill
branch_from "$R" main b_vendor; mkdir -p "$R/vendor"; bad_doc > "$R/vendor/x.md";           TIP="$(commit_all "$R" vendor)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a diff whose only .md sits in an excluded dir: the lint checked no file, so not 'ok'" nao-se-aplica nenhum-arquivo-conferido

echo "C. 2c third states: a tool that cannot answer is never a finding"
git -C "$R" checkout -q b_bad
C2="$WORK/city2"; mkcity "$C2"
printf 'import sys\nprint("boom")\nsys.exit(1)\n' > "$C2/scripts/doc-rules-lint.py"
CITY_UNDER="$C2"; run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x;       expect "exit 1 with no summary line (a crash) is not a violation" nao-consegui-medir saida-sem-resumo
printf 'import sys\nsys.exit(2)\n' > "$C2/scripts/doc-rules-lint.py"
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x;                          expect "exit 2 (could not evaluate)" nao-consegui-medir lint-rc2
printf 'import time\ntime.sleep(30)\n' > "$C2/scripts/doc-rules-lint.py"
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x GATE_HC_TIMEOUT=1;      expect "a hung lint is cut by the timeout" nao-consegui-medir lint-rc124
printf 'import sys\nsys.exit(0)\n' > "$C2/scripts/doc-rules-lint.py"
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x;                          expect "exit 0 with no output at all is not a clean lint" nao-consegui-medir saida-sem-resumo
printf 'print("doc-rules-lint: 2 file(s) checked, 1 violation(s), 0 skipped (excluded)")\n' > "$C2/scripts/doc-rules-lint.py"
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x;                          expect "exit 0 whose summary counts a violation contradicts itself: unmeasured" nao-consegui-medir saida-sem-resumo
printf 'print("doc-rules-lint: 3 file(s) checked, 0 violation(s), 0 skipped (excluded)")\n' > "$C2/scripts/doc-rules-lint.py"
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x;                          expect "control: exit 0 and a summary of 3 files checked, 0 violations" ok lint-limpo
rm -f "$C2/scripts/doc-rules-lint.py"
run_sut 2c "$R" "$MAIN" "$(git -C "$R" rev-parse b_bad)" ga-x;                          expect "a missing lint" nao-consegui-medir ferramenta-ilegivel
CITY_UNDER=""

echo "D. tree safety: a path the branch controls can neither climb out of the scratch dir nor be a link"
blob="$(printf 'x\n' | git -C "$R" hash-object -w --stdin)"
t1="$(printf '100644 blob %s\tevil.md\n' "$blob" | git -C "$R" mktree)"; t2="$(printf '040000 tree %s\t..\n' "$t1" | git -C "$R" mktree)"; t3="$(printf '040000 tree %s\t..\n' "$t2" | git -C "$R" mktree)"
root="$( { git -C "$R" ls-tree main; printf '040000 tree %s\t..\n' "$t3"; } | git -C "$R" mktree)"
TIP="$(git -C "$R" commit-tree "$root" -p "$MAIN" -m climb)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "an entry named .. is refused" nao-consegui-medir extracao-tip
[ ! -e "$TMPDIR/evil.md" ] && ok "and nothing was written outside the scratch dir" || bad "evil.md escaped to $TMPDIR"
branch_from "$R" main b_link; ln -s ok.md "$R/docs/link.md";                              TIP="$(commit_all "$R" link)"
run_sut 2c "$R" "$MAIN" "$TIP" ga-x;                       expect "a symlink where a doc should be is refused" nao-consegui-medir extracao-tip
n="$(find "$TMPDIR" -maxdepth 1 -name 'ghc.*' | wc -l | tr -d ' ')"; [ "$n" = 0 ] && ok "no scratch dir was left behind" || bad "$n scratch dir(s) left in $TMPDIR"

echo "E. 2e third-state reads (real third-state-reads-check.py; the arm is recorded in the city's .gc)"
READ='def load(p):\n    return open(p).read()'; TEST='import m\ndef test_denied(mocker):\n    mocker.patch("builtins.open", side_effect=PermissionError)\n    assert m.load("a") is None'
branch_from "$R" main e_read;  printf '%b\n' "$READ" | put "$R" lib/m.py;                  RTIP="$(commit_all "$R" read)"
branch_from "$R" main e_ok;    printf '%b\n' "$READ" | put "$R" lib/m.py; printf '%b\n' "$TEST" | put "$R" tests/test_m.py; OTIP="$(commit_all "$R" read-with-test)"
branch_from "$R" main e_waiv;  printf 'def load(p):\n    return open(p).read()  # third-state-waiver: a packaged constant cannot fail\n' | put "$R" lib/m.py; WTIP="$(commit_all "$R" waived)"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-arm;                    expect "no .gc/third-state-reads.conf: not switched on, said so" nao-ligado conf-ausente
printf 'mode=enforce\n' > "$CITY/.gc/third-state-reads.conf"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-arm;                    expect "a new read with no failure test is refused" fail leitura-sem-teste
printf '%s\n' "$LINE" | grep -q 'arm=enforce' && ok "the checker's own VERDICT line carries the arm" || bad "the VERDICT line has no arm=enforce: $LINE"
has "the finding names file and line" "lib/m.py:2"
grep -q '"bead": "ga-arm"' "$CITY/.gc/third-state-reads-arms.jsonl" 2>/dev/null && ok "the arm of the bead is recorded in .gc/third-state-reads-arms.jsonl" || bad "no arms row for ga-arm"
branch_from "$R" main e_forge; printf 'def load():\n    return open("a not switched on mode=off is switched OFF b").read()\n' | put "$R" lib/m.py; FTIP="$(commit_all "$R" forge-read)"
run_sut 2e "$R" "$MAIN" "$FTIP" ga-arm1;                   expect "finding text that spells the tool's off-switch phrases is still refused" fail leitura-sem-teste
run_sut 2e "$R" "$MAIN" "$OTIP" ga-arm2;                   expect "the same read beside a test that injects the failure" ok leituras-com-teste
run_sut 2e "$R" "$MAIN" "$WTIP" ga-arm3;                   expect "a waived read" ok leituras-com-teste
branch_from "$R" main e_none;  printf 'x = 7\n' > "$R/lib/app.py";                          NTIP="$(commit_all "$R" no-read)"
run_sut 2e "$R" "$MAIN" "$NTIP" ga-arm10;                  expect "a diff with no read in it: ok, but it must not claim the reads have tests" ok sem-leituras-vistas
printf 'mode=warn\n' > "$CITY/.gc/third-state-reads.conf"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-arm4;                   expect "mode=warn lists the finding but does not refuse" aviso
printf 'mode=off\n' > "$CITY/.gc/third-state-reads.conf"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-arm5;                   expect "mode=off" nao-ligado mode-off
printf 'mode=bogus\n' > "$CITY/.gc/third-state-reads.conf"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-arm6;                   expect "an invalid conf is 'could not tell', not a finding" nao-consegui-medir ferramenta-rc2
printf 'mode=enforce\n' > "$CITY/.gc/third-state-reads.conf"; : > "$CITY/.gc/third-state-reads-check.off"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-arm7;                   expect "the kill switch file" desligado interruptor
rm -f "$CITY/.gc/third-state-reads-check.off"
run_sut 2e "$R" "$MAIN" "$RTIP" "ga x";                    expect "a bead id with a space is refused" nao-consegui-medir bead-invalido
branch_from "$R" main e_tool;  printf '# changed\n' | put "$R" "$HQ/packs/town-deltas/assets/third-state-reads-check.py"; printf 'x = 5\n' > "$R/lib/app.py"; ETIP="$(commit_all "$R" tsr-edit)"
run_sut 2e "$R" "$MAIN" "$ETIP" ga-arm9;                   expect "a diff that edits third-state-reads-check.py is not judged by it" nao-consegui-medir ferramenta-alterada-no-diff
rm -f "$CITY/.gc/third-state-reads.conf" "$CITY/.gc/third-state-reads-arms.jsonl"
# Stand-in tool: the checker reads the VERDICT line's fields; a field that is not there is not a value (arm=-, never the whole line).
C5="$WORK/city5"; mkcity "$C5" || { echo "FATAL: cannot build city5"; exit 1; }; CITY_UNDER="$C5"
T5="$C5/packs/town-deltas/assets/third-state-reads-check.py"
printf 'print("third-state-reads-check: verdict=ok mode=enforce reads=0 uncovered=0 waived=0 skipped=0")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st1;                    expect "a verdict line with no arm= field" ok sem-leituras-vistas
printf '%s\n' "$LINE" | grep -q ' arm=-$' && ok "and the arm column is '-', not a slice of the line" || bad "arm column of a line with no arm=: $LINE"
printf 'print("third-state-reads-check: verdict=ok mode=enforce arm=enforce reads=4 uncovered=0 waived=1 skipped=0")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st2;                    expect "control: reads=4 all covered" ok leituras-com-teste
printf '%s\n' "$LINE" | grep -q ' arm=enforce$' && ok "and the arm column is the tool's" || bad "arm column: $LINE"
printf 'print("third-state-reads-check: verdict=ok mode=enforce arm=enforce")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st3;                    expect "an ok line with no reads= count cannot say what was read: unmeasured" nao-consegui-medir saida-ilegivel
# The tool's "NOT analysed" files are a scope it declared; a pass that says nothing about them reads like "every file was looked at"
printf 'print("third-state-reads-check: verdict=ok mode=enforce arm=enforce reads=0 uncovered=0 waived=0 skipped=3")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st4;                    expect "reads=0 and 3 files not analysed: still ok, but the reason says how many were not looked at" ok sem-leituras-vistas-e-3-nao-analisados
printf 'print("third-state-reads-check: verdict=ok mode=enforce arm=enforce reads=4 uncovered=0 waived=1 skipped=2")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st5;                    expect "reads=4 covered and 2 files not analysed: the reason carries the 2" ok leituras-com-teste-e-2-nao-analisados
printf 'print("third-state-reads-check: verdict=ok mode=enforce arm=enforce reads=4 uncovered=0 waived=1")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st6;                    expect "an ok line with reads= but no skipped= cannot say what was left out: unmeasured" nao-consegui-medir saida-ilegivel
printf 'print("third-state-reads-check: verdict=ok mode=enforce arm=enforce reads=4 uncovered=0 waived=1 skipped=x")\n' > "$T5"
run_sut 2e "$R" "$MAIN" "$RTIP" ga-st7;                    expect "a skipped= that is not a number is not zero" nao-consegui-medir saida-ilegivel
CITY_UNDER=""

echo "F. 2d E12 coverage (real e12-crew-doctrine.sh over the fixture's prompts; the city's generator, never the branch's)"
branch_from "$R" main f_doc;   printf 'x\n' >> "$R/docs/ok.md";                          TIP="$(commit_all "$R" doc)"
run_sut 2d "$R" "$MAIN" "$TIP" ga-x;                       expect "a diff that touches no prompt" nao-se-aplica
branch_from "$R" main f_ok;    printf '\nplain line outside the region\n' >> "$R/$HQ/agents/dog-remote/prompt.template.md"; OKTIP="$(commit_all "$R" prompt-ok)"
run_sut 2d "$R" "$MAIN" "$OKTIP" ga-x;                     expect "a prompt edit outside the generated region (green base)" ok
branch_from "$R" main f_stale; awk '{print} /e12-doctrine:begin/ {print "A STALE LINE INSIDE THE REGION"}' "$R/$HQ/agents/dog-remote/prompt.template.md" > "$WORK/p.md" && cp "$WORK/p.md" "$R/$HQ/agents/dog-remote/prompt.template.md"; STIP="$(commit_all "$R" stale)"
run_sut 2d "$R" "$MAIN" "$STIP" ga-x;                      expect "a hand edit inside the generated region is refused (red tip, green base)" fail e12-vermelho-no-tip-e-verde-na-base
has "the generator's own line reaches the refusal" "STALE"
branch_from "$R" "$STIP" f_debt; printf '\nanother plain line\n' >> "$R/$HQ/agents/mila-wa/prompt.template.md"; DTIP="$(commit_all "$R" debt)"
run_sut 2d "$R" "$STIP" "$DTIP" ga-x;                      expect "red on the base too: main's debt, recorded, never refused" debito-previo e12-vermelho-na-base-tambem
# The red lines carry the tree's path and the tip and the base sit in different dirs: the cut must survive how macOS names a TMPDIR
# (a trailing slash, and /var is a link to /private/var), or every debt-carrying branch would read as "new" in production
ln -s "$WORK/tmp" "$WORK/tmplink"
run_sut 2d "$R" "$STIP" "$DTIP" ga-x "TMPDIR=$WORK/tmplink/"; expect "same debt, scratch under a TMPDIR that ends in a slash and goes through a link: still main's debt" debito-previo e12-vermelho-na-base-tambem
# "Red on the base too" is a SET question: main's one gap must not let a second one ride (gate_run ga-h3scrqt, medium finding)
branch_from "$R" "$STIP" f_second; awk '{print} /e12-doctrine:begin/ {print "A SECOND STALE LINE INSIDE THE REGION"}' "$R/$HQ/agents/mila-wa/prompt.template.md" > "$WORK/p2.md" && cp "$WORK/p2.md" "$R/$HQ/agents/mila-wa/prompt.template.md"; S2TIP="$(commit_all "$R" second-stale)"
run_sut 2d "$R" "$STIP" "$S2TIP" ga-x;                     expect "main's gap is red on the base, and this diff adds a SECOND one in another prompt: refused" fail e12-vermelho-novo-no-tip
has "and the refusal names the new prompt" "mila-wa"
branch_from "$R" "$STIP" f_same; printf '\nplain\n' >> "$R/$HQ/agents/dog-remote/prompt.template.md"; SATIP="$(commit_all "$R" same-prompt-edit)"
run_sut 2d "$R" "$STIP" "$SATIP" ga-x;                     expect "control: editing the already-stale prompt outside its region adds no red line: still main's debt" debito-previo e12-vermelho-na-base-tambem
branch_from "$R" main f_linkbase; mkdir -p "$R/$HQ/agents/zz-link"; ln -s ../dog-remote/prompt.template.md "$R/$HQ/agents/zz-link/prompt.template.md"; LB="$(commit_all "$R" link-base)"
branch_from "$R" "$LB" f_link; printf '\nplain line\n' >> "$R/$HQ/agents/mila-wa/prompt.template.md"; LTIP="$(commit_all "$R" prompt-over-link-base)"
run_sut 2d "$R" "$LB" "$LTIP" ga-x;                        expect "an untouched link among the prompts: a green E12 is not vouched for" nao-consegui-medir entrada-especial-fora-do-diff-1
branch_from "$R" main f_tool;  printf '# changed\n' | put "$R" "$HQ/packs/town-deltas/assets/e12-arms.sh"; printf 'y\n' >> "$R/$HQ/agents/dog-remote/prompt.template.md"; TTIP="$(commit_all "$R" arms)"
run_sut 2d "$R" "$MAIN" "$TTIP" ga-x;                      expect "a diff that edits e12-arms.sh (sourced by the generator) is not judged" nao-consegui-medir ferramenta-alterada-no-diff
: > "$CITY/.gc/e12-coverage-gate.off"
run_sut 2d "$R" "$MAIN" "$STIP" ga-x;                      expect "the flag file switches it off" desligado interruptor
rm -f "$CITY/.gc/e12-coverage-gate.off"
run_sut 2d "$R" "$MAIN" "$STIP" ga-x E12_COVERAGE_GATE=off; expect "the env switch" desligado interruptor
mkdir -p "$WORK/fakepy"; printf '#!/bin/sh\ncase "$*" in *tomllib*) exit 1;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$WORK/fakepy/python3"; chmod +x "$WORK/fakepy/python3"
run_sut 2d "$R" "$MAIN" "$STIP" ga-x GATE_HC_PYTHONS="$WORK/fakepy/python3"; expect "a python without tomllib says so (it would make every base red too)" nao-consegui-medir python-sem-tomllib
FB2="$WORK/fb2"; mkdir -p "$FB2"; for t in bash sh env git grep awk sed tr cat mkdir rm dirname basename mktemp cp cut head tail sort uniq python3 timeout jq ls wc; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$FB2/$t"; done
run_sut 2d "$R" "$STIP" "$DTIP" ga-x PATH="$FB2";            expect "no comm to compare the red lines: unmeasured, never 'no new red line'" nao-consegui-medir e12-linhas-ilegiveis
C3="$WORK/city3"; mkcity "$C3" e12-crew-doctrine.sh; CITY_UNDER="$C3"
run_sut 2d "$R" "$MAIN" "$STIP" ga-x;                      expect "a missing generator" nao-consegui-medir ferramenta-ilegivel
CITY_UNDER=""

echo "G. 2b template parse (stub gc behind a PATH of symlinks: the real gc lint is not on this node)"
FB="$WORK/fb"; mkdir -p "$FB"
for t in bash sh env git grep awk sed tr cat mkdir rm dirname basename mktemp cp cut head tail sort uniq python3 timeout jq ls wc; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$FB/$t"; done
cat > "$FB/gc" <<'STUB'
#!/bin/sh
# gc lint <pack> --json: red when any file under <pack> holds BADTEMPLATE (or when STUB_GC_FAIL is set)
[ "$1" = lint ] || exit 2
if [ -n "${STUB_GC_FAIL:-}" ] || grep -r -q BADTEMPLATE "$2" 2>/dev/null; then
  printf '{"error_count":1,"packs":[{"name":"p","path":"%s","ok":false,"diagnostics":[{"severity":"error","path":"%s/agents/x/prompt.template.md","message":"template: prompt:1:2: bad"}]}]}\n' "$2" "$2"; exit 1
fi
printf '{"error_count":0,"packs":[{"name":"p","path":"%s","ok":true,"diagnostics":[]}]}\n' "$2"
STUB
chmod +x "$FB/gc"
branch_from "$R" main g_code;  printf 'x = 3\n' > "$R/lib/app.py";                       TIP="$(commit_all "$R" code2)"
run_sut 2b "$R" "$MAIN" "$TIP" ga-x PATH="$FB";            expect "no template-shaped file in the diff" nao-se-aplica
branch_from "$R" main g_ok;    printf 'fine\n' >> "$R/$HQ/agents/mila-wa/prompt.template.md"; GOK="$(commit_all "$R" tmpl-ok)"
run_sut 2b "$R" "$MAIN" "$GOK" ga-x PATH="$FB";            expect "a template edit that parses" ok parse-verde-no-tip
branch_from "$R" main g_bad;   printf 'BADTEMPLATE\n' >> "$R/$HQ/agents/mila-wa/prompt.template.md"; GBAD="$(commit_all "$R" tmpl-bad)"
run_sut 2b "$R" "$MAIN" "$GBAD" ga-x PATH="$FB";           expect "a template that does not parse (red tip, green base, green control)" fail parse-vermelho-no-tip-e-verde-na-base
has "the guard's FAIL line reaches the refusal" "template-fragment-lint-guard: FAIL"
branch_from "$R" "$GBAD" g_debt; printf 'more\n' >> "$R/$HQ/agents/thies-wa/prompt.template.md"; GDEBT="$(commit_all "$R" tmpl-debt)"
run_sut 2b "$R" "$GBAD" "$GDEBT" ga-x PATH="$FB";          expect "red on the base too: main's debt" debito-previo
run_sut 2b "$R" "$MAIN" "$GBAD" ga-x PATH="$FB" STUB_GC_FAIL=1; expect "a gc that cannot lint anything fails the CONTROL: said, not 'debt for good'" nao-consegui-medir gc-lint-controle-vermelho

echo "G2. 2b: an exit 0 is not proof that a lint ran (the parse guard exits 0 when it SKIPS; gate_run ga-rrje9vk)"
# rig2 has no pack.toml anywhere, like whatsapp_automation, which tracks a .md.tmpl outside every pack: the guard skips with a warning.
R2="$WORK/rig2"; mkdir -p "$R2" && git -C "$R2" init -q && git -C "$R2" symbolic-ref HEAD refs/heads/main && git -C "$R2" config user.email t@example.invalid \
  && git -C "$R2" config user.name t && git -C "$R2" config commit.gpgsign false || { echo "FATAL: cannot build rig2"; exit 1; }
printf 'x = 1\n' | put "$R2" lib/app.py; MAIN2="$(commit_all "$R2" base2)"
branch_from "$R2" main h_nopack; printf 'hello {{ .Unclosed\n' | put "$R2" templates/CLAUDE.local.md.tmpl;      NPTIP="$(commit_all "$R2" nopack)"
run_sut 2b "$R2" "$MAIN2" "$NPTIP" ga-x PATH="$FB";        expect "a template with no pack.toml above it was never linted: not ok" nao-consegui-medir lint-nao-rodou-no-tip
has "and the guard's own warning reaches the output" "no pack.toml found above changed file"
branch_from "$R2" main h_owned; printf '[pack]\nname = "s"\nschema = 2\n' | put "$R2" sub/pack.toml; printf 'fine\n' | put "$R2" sub/agents/a/prompt.template.md; OWTIP="$(commit_all "$R2" owned)"
run_sut 2b "$R2" "$MAIN2" "$OWTIP" ga-x PATH="$FB";        expect "control: the same rig, a template that HAS an owning pack, is ok" ok parse-verde-no-tip
branch_from "$R2" "$OWTIP" h_mixed; printf 'x\n' | put "$R2" loose/x.md.tmpl;                                         MXTIP="$(commit_all "$R2" mixed)"
run_sut 2b "$R2" "$MAIN2" "$MXTIP" ga-x PATH="$FB";        expect "one file that lints and one with no pack: a pass needs every file measured" nao-consegui-medir lint-nao-rodou-no-tip
branch_from "$R2" main h_newpack; printf '[pack]\nname = "n"\nschema = 2\n' | put "$R2" np/pack.toml; printf 'BADTEMPLATE\n' | put "$R2" np/agents/a/prompt.template.md; NNTIP="$(commit_all "$R2" newpack-bad)"
run_sut 2b "$R2" "$MAIN2" "$NNTIP" ga-x PATH="$FB";        expect "red tip, but the base had no pack to lint: 'green on the base' was never measured, no refusal" nao-consegui-medir lint-nao-rodou-na-base
# The base is judged per red pack: a loose template the base cannot lint (a WARNING) must not hide that the pack the tip broke
# WAS linted green there, and a green pack elsewhere on the base must not vouch for a pack the base never had.
branch_from "$R2" main i_base; printf 'x\n' | put "$R2" loose/x.md.tmpl; printf '[pack]\nname = "s"\nschema = 2\n' | put "$R2" sub/pack.toml; printf 'fine\n' | put "$R2" sub/agents/a/prompt.template.md; IB2="$(commit_all "$R2" base-sub)"
branch_from "$R2" "$IB2" i_tip; printf 'y\n' | put "$R2" loose/x.md.tmpl; printf 'BADTEMPLATE\n' | put "$R2" sub/agents/a/prompt.template.md; IT2="$(commit_all "$R2" tip-broken)"
run_sut 2b "$R2" "$IB2" "$IT2" ga-x PATH="$FB";            expect "the broken pack linted green on the base, beside a loose template the base could not lint: refused" fail parse-vermelho-no-tip-e-verde-na-base
branch_from "$R2" "$IB2" i_tip2; printf 'z\n' | put "$R2" sub/agents/a/prompt.template.md; printf '[pack]\nname = "n"\nschema = 2\n' | put "$R2" np/pack.toml; printf 'BADTEMPLATE\n' | put "$R2" np/agents/a/prompt.template.md; IT3="$(commit_all "$R2" tip-newpack)"
run_sut 2b "$R2" "$IB2" "$IT3" ga-x PATH="$FB";            expect "a pack linted green on the base is no proof for a NEW pack the base never had" nao-consegui-medir lint-nao-rodou-na-base
# Stand-in parse guard: STUB_GUARD_MODE picks the lie, anything else delegates to the real guard (REAL_GUARD).
C4="$WORK/city4"; mkcity "$C4" template-fragment-lint-guard.sh || { echo "FATAL: cannot build city4"; exit 1; }
cat > "$C4/packs/town-deltas/assets/template-fragment-lint-guard.sh" <<'STUBG'
#!/usr/bin/env bash
case "${STUB_GUARD_MODE:-}:$1" in
  (forged-ok:*) echo "template-fragment-lint-guard: OK -- /not/the/tree/under/test"; exit 0 ;;
  (no-match:*)  echo "template-fragment-lint-guard: no changed file matches a template/fragment/pack.toml pattern -- skipping gc lint."; exit 0 ;;
  (ctl-skip:*/ctl) echo "template-fragment-lint-guard: WARNING: no pack.toml found above changed file x -- skipping (nothing to gc lint against)." >&2; exit 0 ;;
esac
exec bash "$REAL_GUARD" "$@"
STUBG
CITY_UNDER="$C4"; REALG="$RHQ/packs/town-deltas/assets/template-fragment-lint-guard.sh"
run_sut 2b "$R" "$MAIN" "$GBAD" ga-x PATH="$FB" REAL_GUARD="$REALG" STUB_GUARD_MODE=ctl-skip; expect "the CONTROL gets the same check: a control the guard skipped proves no lint ran" nao-consegui-medir gc-lint-controle-nao-rodou
run_sut 2b "$R" "$MAIN" "$GOK" ga-x PATH="$FB" REAL_GUARD="$REALG" STUB_GUARD_MODE=forged-ok;  expect "an OK line that does not name the tree under test is not proof (it echoes branch data)" nao-consegui-medir lint-nao-rodou-no-tip
run_sut 2b "$R" "$MAIN" "$GOK" ga-x PATH="$FB" REAL_GUARD="$REALG" STUB_GUARD_MODE=no-match;   expect "exit 0 and no OK line at all (the guard matched nothing)" nao-consegui-medir lint-nao-rodou-no-tip
run_sut 2b "$R" "$MAIN" "$GOK" ga-x PATH="$FB" REAL_GUARD="$REALG";                            expect "control: the stand-in delegating to the real guard still reads ok" ok parse-verde-no-tip
CITY_UNDER=""
rm -f "$FB/gc"
run_sut 2b "$R" "$MAIN" "$GBAD" ga-x PATH="$FB";           expect "no gc on PATH (the guard would exit 0 with only a warning)" nao-consegui-medir sem-gc
printf '#!/bin/sh\nexit 0\n' > "$FB/gc"; chmod +x "$FB/gc"; rm -f "$FB/jq"
run_sut 2b "$R" "$MAIN" "$GBAD" ga-x PATH="$FB";           expect "no jq on PATH" nao-consegui-medir sem-jq
branch_from "$R" main g_tool;  printf '# x\n' | put "$R" "$HQ/packs/town-deltas/assets/template-fragment-lint-guard.sh"; printf 'q\n' >> "$R/$HQ/agents/mila-wa/prompt.template.md"; GT="$(commit_all "$R" guard-edit)"
run_sut 2b "$R" "$MAIN" "$GT" ga-x PATH="$FB";             expect "a diff that edits the parse guard is not judged by it" nao-consegui-medir ferramenta-alterada-no-diff

echo "gate-hard-checks selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
