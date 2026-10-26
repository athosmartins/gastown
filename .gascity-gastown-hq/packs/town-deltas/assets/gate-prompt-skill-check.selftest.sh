#!/usr/bin/env bash
# gate-prompt-skill-check.selftest.sh — ga-gqtg1fs: hermetic proof of gate-prompt-skill-check.sh, the checker the
# quality-gate guard (Step 5b-pre4) calls when a submission touches what pool-prompt-skill-mention.selftest.sh reads.
#
# WHY. Nothing used to run that selftest when a prompt changed (the gate's reviewers run "the test files the diff
# changed", and a prompt is not a test file), so 3eea2c223 (ga-eei1o4) put a skill token in the gate-reviewer prompt
# and main sat red for two days. The checker closes that: it runs the selftest of the TIP tree when the diff touches an
# input of the detector, and blocks only what the diff itself made fail (red on tip AND green on base).
#
# HOW. Every case builds a tiny git repo laid out like the HQ repo and copies in the REAL detector (flavor "real"), so
# "a skill token in a prompt is refused" is proven with the real rule, not with a stand-in. Flavor "stub" swaps the
# detector for a script that appends to a counter file: that is how "a diff that touches no prompt never runs the
# detector" is MEASURED instead of assumed.
#
# THIRD STATES. Each read the checker makes has a case that makes it fail (empty args, not a repo, unknown sha,
# detector missing, detector crashing, detector with no summary line, a summary that disagrees with the exit code,
# a timeout, a tree entry git cannot extract). None of them may read as "ok" and none may read as "fail": a check that
# cannot measure must never block (fail-open) and never vouch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${GATE_PSC_SUT:-$HERE/gate-prompt-skill-check.sh}"
DET="${GATE_PSC_DETECTOR:-$HERE/pool-prompt-skill-mention.selftest.sh}"
HQ=".gascity-gastown-hq"
DET_REL="$HQ/packs/town-deltas/assets/pool-prompt-skill-mention.selftest.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DET" ] || { echo "FATAL: detector not found at $DET"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found"; exit 1; }
# The agents the fixture needs are the ones the detector itself lists as pool templates (it reports "pool template
# listed but missing" for any absent one, which would turn every real-detector case red at base). Read from the detector,
# never copied here: a new pool agent added there (kimi-worker-remote was, on 26/10) must not break this selftest.
# vazio → o detector mudou de forma e a lista não foi achada: FATAL com a causa (nunca seguir com lista vazia, que
# esconderia a ausência dos templates); falhou/ilegível → idem
POOL="$(sed -n 's/^POOL_TEMPLATES="${POOL_PROMPT_POOL_TEMPLATES:-\(.*\)}"$/\1/p' "$DET" 2>/dev/null | head -n 1)"
[ -n "$POOL" ] || { echo "FATAL: cannot read the POOL_TEMPLATES default from $DET (the detector changed shape)"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/psc-selftest.XXXXXX")" || { echo "FATAL: no scratch dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# The checker makes its own scratch dirs under TMPDIR: pointing it at a private one lets the leak case below count them.
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

git_in() { local d="$1"; shift; git -C "$d" "$@"; }

# mkfix <dir> <real|stub> [counter-file]  -> a repo with branch main holding one "base" commit.
mkfix() {
  local d="$1" flavor="$2" counter="${3:-}" a=""
  mkdir -p "$d" && git -C "$d" init -q && git -C "$d" symbolic-ref HEAD refs/heads/main || return 1
  git -C "$d" config user.email t@example.invalid; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  for a in $POOL gate-reviewer; do
    mkdir -p "$d/$HQ/agents/$a"
    printf '# %s\nstart from the bead; submit with the gate-done skill.\n' "$a" > "$d/$HQ/agents/$a/prompt.template.md"
  done
  mkdir -p "$d/$HQ/skills/recall" "$d/$HQ/commands" "$d/$HQ/packs/town-deltas/template-fragments" "$d/$HQ/packs/town-deltas/assets" "$d/other"
  printf '# recall\n' > "$d/$HQ/skills/recall/SKILL.md"
  printf '# gate-done\n' > "$d/$HQ/commands/gate-done.md"
  printf '[workspace]\nglobal_fragments = ["town-deltas"]\n' > "$d/$HQ/city.toml"
  printf 'plain fragment text.\n' > "$d/$HQ/packs/town-deltas/template-fragments/town-deltas.template.md"
  printf 'x = 1\n' > "$d/other/app.py"
  if [ "$flavor" = real ]; then
    cp "$DET" "$d/$DET_REL"
  else
    printf '#!/usr/bin/env bash\necho run >> "%s"\necho "pool-prompt-skill-mention selftest: 1 passed, 0 failed"\nexit 0\n' "$counter" > "$d/$DET_REL"
  fi
  git -C "$d" add -A && git -C "$d" commit -q -m base
}
branch_from_main() { git -C "$1" checkout -q -b "$2" main; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2" && git -C "$1" rev-parse HEAD; }

# run_sut <rig> <base> <tip> [VAR=value ...] -> sets OUT (whole output), RC, VERDICT (token), REASON.
run_sut() {
  local rig="$1" base="$2" tip="$3"; shift 3
  OUT="$(env "$@" bash "$SUT" "$rig" "$base" "$tip" 2>&1)"; RC=$?
  # vazio → a saída não tem linha VERDICT= e o caso reprova (VERDICT fica vazio); falhou → idem
  VERDICT="$(printf '%s\n' "$OUT" | sed -n 's/^VERDICT=\([^ ]*\).*/\1/p' | head -n 1)"
  REASON="$(printf '%s\n' "$OUT" | sed -n 's/^VERDICT=[^ ]* reason=\([^ ]*\).*/\1/p' | head -n 1)"
}
expect() { # expect <label> <verdict> [reason]
  if [ "$VERDICT" = "$2" ] && { [ -z "${3:-}" ] || [ "$REASON" = "$3" ]; } && [ "$RC" -eq 0 ]; then ok "$1 -> $VERDICT${3:+ ($REASON)}"
  else bad "$1: wanted $2${3:+ ($3)}, got verdict='$VERDICT' reason='$REASON' rc=$RC :: $(printf '%s' "$OUT" | head -n 3 | tr '\n' '|')"; fi
}

echo "A. the checker exists and answers"
[ -f "$SUT" ] && ok "checker present: $(basename "$SUT")" || bad "checker missing at $SUT: nothing below can pass"

R="$WORK/real"; mkfix "$R" real || { echo "FATAL: cannot build the real-detector fixture"; exit 1; }
BASE="$(git_in "$R" rev-parse main)"

echo "B. the incident: a skill token in a prompt is refused (real detector)"
branch_from_main "$R" tok_unquoted
printf 'then run /gate-done to submit.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"
TIP="$(commit_all "$R" "unquoted token")"
run_sut "$R" "$BASE" "$TIP"
expect "unquoted token in a non-pool prompt" fail
printf '%s\n' "$OUT" | grep -q 'gate-reviewer' && ok "the red lines name the prompt" || bad "the red lines do not name gate-reviewer :: $OUT"
printf '%s\n' "$OUT" | grep -q '/gate-done' && ok "the red lines show the offending text" || bad "the offending text is not shown :: $OUT"

git_in "$R" checkout -q main; branch_from_main "$R" tok_pool
printf 'use `/gate-done` to submit.\n' >> "$R/$HQ/agents/dog-remote/prompt.template.md"
TIP="$(commit_all "$R" "backticked token in a pool prompt")"
run_sut "$R" "$BASE" "$TIP"
expect "backticked token in a POOL prompt (strict rule)" fail

git_in "$R" checkout -q main; branch_from_main "$R" tok_frag
printf 'run /gate-done now.\n' >> "$R/$HQ/packs/town-deltas/template-fragments/town-deltas.template.md"
TIP="$(commit_all "$R" "token in the global fragment")"
run_sut "$R" "$BASE" "$TIP"
expect "token in a template fragment" fail

echo "C. clean prompt edits and diffs that touch nothing the detector reads"
git_in "$R" checkout -q main; branch_from_main "$R" clean_prompt
printf 'one more plain sentence.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"
TIP="$(commit_all "$R" "clean prompt edit")"
run_sut "$R" "$BASE" "$TIP"
expect "clean prompt edit" ok

git_in "$R" checkout -q main; branch_from_main "$R" py_only
printf 'x = 2\n' > "$R/other/app.py"
TIP="$(commit_all "$R" "python only")"
run_sut "$R" "$BASE" "$TIP"
expect "diff outside the detector's inputs" sem-prompt-alterado

git_in "$R" checkout -q main; branch_from_main "$R" claude_other
mkdir -p "$R/.claude"; printf '{}\n' > "$R/.claude/settings.json"
printf 'not a prompt\n' > "$R/$HQ/notes.txt"
TIP="$(commit_all "$R" ".claude settings and an HQ note")"
run_sut "$R" "$BASE" "$TIP"
expect "files under .claude and the HQ dir that are not inputs" sem-prompt-alterado

echo "D. the cost proof: a diff that touches no prompt never runs the detector (stub detector + counter)"
S="$WORK/stub"; CNT="$WORK/stub.count"; : > "$CNT"
mkfix "$S" stub "$CNT" || { echo "FATAL: cannot build the stub fixture"; exit 1; }
SBASE="$(git_in "$S" rev-parse main)"
branch_from_main "$S" py_only
printf 'x = 2\n' > "$S/other/app.py"
STIP="$(commit_all "$S" "python only")"
run_sut "$S" "$SBASE" "$STIP"
expect "stub: diff outside the inputs" sem-prompt-alterado
N="$(wc -l < "$CNT" | tr -d ' ')"; [ "$N" = "0" ] && ok "the detector ran 0 times for a diff that touches no prompt" || bad "the detector ran $N time(s) for a diff outside its inputs"
git_in "$S" checkout -q main; branch_from_main "$S" prompt_edit
printf 'another sentence.\n' >> "$S/$HQ/agents/ps-worker/prompt.template.md"
STIP="$(commit_all "$S" "prompt edit")"
run_sut "$S" "$SBASE" "$STIP"
expect "stub: prompt edit" ok
N="$(wc -l < "$CNT" | tr -d ' ')"; [ "$N" = "1" ] && ok "the detector ran exactly once for a green prompt edit" || bad "the detector ran $N time(s) (wanted 1)"

echo "E. inputs other than prompts also trigger it (the verdict can flip without a prompt in the diff)"
git_in "$R" checkout -q main; branch_from_main "$R" latent
printf 'see /newskill for details.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"
LBASE="$(commit_all "$R" "latent token: no skill called newskill exists yet")"
git_in "$R" checkout -q main; git_in "$R" merge -q --ff-only latent; BASE2="$(git_in "$R" rev-parse main)"
run_sut "$R" "$BASE" "$BASE2"
expect "latent token while the name is not a skill yet" ok
branch_from_main "$R" newskill
mkdir -p "$R/$HQ/skills/newskill"; printf '# newskill\n' > "$R/$HQ/skills/newskill/SKILL.md"
TIP="$(commit_all "$R" "add the skill that makes the latent token real")"
run_sut "$R" "$BASE2" "$TIP"
expect "a NEW skill name turns an old prompt line into a skill mention" fail
git_in "$R" checkout -q main; git_in "$R" reset -q --hard "$BASE"

echo "F. only what the diff made fail blocks (base-aware)"
branch_from_main "$R" red_base
printf 'old debt: run /gate-done.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"
RBASE="$(commit_all "$R" "main already red")"
git_in "$R" checkout -q -b other_edit "$RBASE"   # from the RED base, not from main: the tip must still carry the debt
printf 'harmless line.\n' >> "$R/$HQ/agents/ps-worker/prompt.template.md"
TIP="$(commit_all "$R" "harmless edit while main is red")"
run_sut "$R" "$RBASE" "$TIP"
expect "red on tip AND on base: pre-existing debt" debito-previo
git_in "$R" checkout -q -b repair "$RBASE"
printf 'plain sentence only.\n' > "$R/$HQ/agents/gate-reviewer/prompt.template.md"
TIP="$(commit_all "$R" "repair the red prompt")"
run_sut "$R" "$RBASE" "$TIP"
expect "base red, tip green: the repair passes" ok
git_in "$R" checkout -q main

echo "G. the detector is trusted code: the branch's copy is never run, and a diff that edits it is not judged"
git_in "$R" checkout -q main; branch_from_main "$R" det_edit
CANARY="$WORK/canary-detector"
printf '#!/usr/bin/env bash\ntouch "%s"\necho "pool-prompt-skill-mention selftest: 9 passed, 0 failed"\nexit 0\n' "$CANARY" > "$R/$DET_REL"
printf 'use /gate-done here.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"
TIP="$(commit_all "$R" "weakened detector + a token in one push")"
run_sut "$R" "$BASE" "$TIP"
expect "weakened detector + a token in the same diff is NOT vouched for" nao-consegui-medir detector-alterado-no-diff
[ "$VERDICT" != "ok" ] && ok "never 'ok' for a diff that attests for itself" || bad "a self-attesting diff read ok"
[ ! -e "$CANARY" ] && ok "the branch's detector was never executed (canary absent)" || bad "the branch's detector RAN (canary exists)"

git_in "$R" checkout -q main; branch_from_main "$R" det_gone
git_in "$R" rm -q "$DET_REL"
TIP="$(commit_all "$R" "detector deleted")"
run_sut "$R" "$BASE" "$TIP"
expect "detector deleted in the diff" nao-consegui-medir detector-alterado-no-diff

git_in "$R" checkout -q main; branch_from_main "$R" data_only
CANARY2="$WORK/c2"
printf 'harmless $(touch %s) and `touch %s` and ; touch %s text.\n' "$CANARY2" "$CANARY2" "$CANARY2" >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"
TIP="$(commit_all "$R" "shell syntax inside prompt text")"
run_sut "$R" "$BASE" "$TIP"
expect "shell syntax inside a prompt is data" ok
[ ! -e "$CANARY2" ] && ok "nothing in the prompt text was executed" || bad "prompt text was EXECUTED (canary exists)"

echo "H. third states: a check that cannot measure never blocks and never vouches"
run_sut "" "" ""
expect "empty arguments" nao-consegui-medir entrada-vazia
run_sut "$WORK" "$BASE" "$BASE"
expect "rig path is not a git repository" nao-consegui-medir sem-toplevel
run_sut "$R" "$BASE" "0000000000000000000000000000000000000000"
expect "tip sha unknown to git (the diff fails)" nao-consegui-medir diff-falhou

# A detector that is part of the base lineage (unchanged by the diff, so it is the one that runs) but misbehaves.
broken_detector_case() { # broken_detector_case <label> <detector text> [VAR=value ...]
  local lab="$1" text="$2" cb="" tip=""; shift 2
  git_in "$R" checkout -q main; git_in "$R" checkout -q -b "bd_$RANDOM"
  printf '%s' "$text" > "$R/$DET_REL"; cb="$(commit_all "$R" "base lineage with a broken detector")"
  git_in "$R" checkout -q -b "bt_$RANDOM"
  printf 'plain.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"; tip="$(commit_all "$R" "prompt edit")"
  run_sut "$R" "$cb" "$tip" "$@"
  expect "$lab" nao-consegui-medir selftest-inconclusivo-tip
}
broken_detector_case "detector crashes without a summary line" $'#!/usr/bin/env bash\necho boom >&2\nexit 3\n'
broken_detector_case "exit 0 with no summary line is not a pass" $'#!/usr/bin/env bash\nexit 0\n'
broken_detector_case "a summary that disagrees with the exit code" $'#!/usr/bin/env bash\necho "pool-prompt-skill-mention selftest: 5 passed, 0 failed"\nexit 1\n'
broken_detector_case "detector hits the timeout" $'#!/usr/bin/env bash\nsleep 5\necho "pool-prompt-skill-mention selftest: 1 passed, 0 failed"\n' GATE_PSC_TIMEOUT=1

git_in "$R" checkout -q main; git_in "$R" checkout -q -b nodet_base
git_in "$R" rm -q "$DET_REL"; NB="$(commit_all "$R" "base lineage without any detector")"
git_in "$R" checkout -q -b nodet_tip
printf 'plain.\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"; TIP="$(commit_all "$R" "prompt edit")"
run_sut "$R" "$NB" "$TIP"
expect "no detector in the tree at all" nao-consegui-medir selftest-ausente-no-tip

# A detector that reads the tree it runs in: red on the tip (REDWORD), crashing on the base (CRASHWORD).
STUB_TREE=$'#!/usr/bin/env bash\nf=".gascity-gastown-hq/agents/gate-reviewer/prompt.template.md"\nif grep -q CRASHWORD "$f"; then echo boom >&2; exit 3; fi\nif grep -q REDWORD "$f"; then echo "pool-prompt-skill-mention selftest: 1 passed, 1 failed"; exit 1; fi\necho "pool-prompt-skill-mention selftest: 2 passed, 0 failed"\n'
git_in "$R" checkout -q main; git_in "$R" checkout -q -b stub_lineage
printf '%s' "$STUB_TREE" > "$R/$DET_REL"; SB="$(commit_all "$R" "lineage with a tree-reading detector")"
git_in "$R" checkout -q -b stub_base; printf 'CRASHWORD\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"; BB="$(commit_all "$R" "base: detector crashes here")"
git_in "$R" checkout -q -b stub_tip "$SB"; printf 'REDWORD\n' >> "$R/$HQ/agents/gate-reviewer/prompt.template.md"; TIP="$(commit_all "$R" "tip: detector is red here")"
run_sut "$R" "$BB" "$TIP"
expect "tip red but the detector cannot answer on the base" nao-consegui-medir selftest-inconclusivo-base

git_in "$R" checkout -q main; branch_from_main "$R" gitlink
git_in "$R" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,"$HQ/skills/ghost/SKILL.md"
# plain commit: commit_all's `git add -A` would drop a gitlink whose path is not on disk
git_in "$R" commit -q -m "a tree entry git cannot extract" && TIP="$(git_in "$R" rev-parse HEAD)"
run_sut "$R" "$BASE" "$TIP"
expect "an input entry that cannot be extracted" nao-consegui-medir extracao-tip
git_in "$R" checkout -q main

echo "I. a tree path that climbs out of the scratch directory is refused (git mktree builds such entries)"
# tree = main's tree + .gascity-gastown-hq/skills/<5 x '..'>/planted/SKILL.md; unpatched, the write lands in $WORK/planted
mk_climb_commit() { # mk_climb_commit <repo> <parent> -> prints the commit
  local r="$1" par="$2" b="" leaf="" t="" i="" newsk="" newhq="" newroot=""
  b="$(printf 'planted\n' | git -C "$r" hash-object -w --stdin)"
  leaf="$(printf '100644 blob %s\tSKILL.md\n' "$b" | git -C "$r" mktree)"
  t="$(printf '040000 tree %s\tplanted\n' "$leaf" | git -C "$r" mktree)"
  for i in 1 2 3 4; do t="$(printf '040000 tree %s\t..\n' "$t" | git -C "$r" mktree)"; done
  newsk="$( { git -C "$r" ls-tree "$par:$HQ/skills"; printf '040000 tree %s\t..\n' "$t"; } | git -C "$r" mktree)"
  newhq="$( { git -C "$r" ls-tree "$par:$HQ" | awk -F'\t' '$2 != "skills"'; printf '040000 tree %s\tskills\n' "$newsk"; } | git -C "$r" mktree)"
  newroot="$( { git -C "$r" ls-tree "$par" | awk -F'\t' -v n="$HQ" '$2 != n'; printf '040000 tree %s\t%s\n' "$newhq" "$HQ"; } | git -C "$r" mktree)"
  git -C "$r" commit-tree "$newroot" -p "$par" -m "climbing path"
}
TIP="$(mk_climb_commit "$R" main)"
if [ -n "$TIP" ]; then
  run_sut "$R" "$BASE" "$TIP"
  expect "a tree path with '..' components" nao-consegui-medir extracao-tip
  [ ! -e "$WORK/planted" ] && ok "nothing was written outside the scratch directory" || bad "the climbing path WROTE $WORK/planted"
else
  bad "could not build the climbing-path commit (plumbing failed): the traversal case did not run"
fi

echo "J. contract: one VERDICT line first, red lines only for fail/debito-previo, nothing left behind"
run_sut "$R" "$BASE" "$BASE"
FIRST="$(printf '%s\n' "$OUT" | head -n 1)"
case "$FIRST" in (VERDICT=*) ok "first line is the verdict line" ;; (*) bad "first line is not the verdict line: $FIRST" ;; esac
LEFT="$(ls "$TMPDIR" 2>/dev/null | grep -c . || true)"
[ "$LEFT" = "0" ] && ok "no scratch directory left in TMPDIR after all the runs" || bad "$LEFT scratch entr(ies) left in TMPDIR: $(ls "$TMPDIR" | tr '\n' ' ')"

echo
echo "gate-prompt-skill-check selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
