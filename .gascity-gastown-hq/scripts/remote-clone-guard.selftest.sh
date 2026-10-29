#!/usr/bin/env bash
# remote-clone-guard.selftest.sh — hermético: o "território" é uma pasta de mktemp (HOME de teste), nada conecta em lugar nenhum.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS (grupos; o nome de cada caso diz o que ele prova): block — escrita de git no clone ALHEIO (por -C, --git-dir, GIT_DIR, ~/, symlink,
#   cwd, o espelho repo.git) · pass — leitura no clone alheio, escrita no PRÓPRIO clone e fora do território, comando que só CITA o outro
#   clone · evade — a mesma escrita embrulhada (command/env/sudo/xargs, bash -c, eval, $(…), crase, find -exec, ; && || |, heredoc) ·
#   closed — o que não sei NÃO vira liberado (variável, glob, ~usuário, subcomando desconhecido, stdin que não é JSON e cita git/file_path; sem citar, libera) · tools — Edit/Write/MultiEdit/
#   NotebookEdit · shell — o git atrás de palavra reservada (if/then/{/!/function), de `<(…)`, de cd/pushd com opção, de lançador que não modelo (flock/ssh/su…),
#   de heredoc e here-string que um shell lê, de `\`+newline (e os controles que NÃO podem bloquear) · wrap — o mesmo defeito em find (-execdir/-okdir, um segundo
#   -exec depois do `\;`), na tabela de opções de CADA embrulho (sudo -n, xargs -a, stdbuf -o L, timeout --signal, nice -5…; opção que não conheço = lançador opaco),
#   nas opções de topo do git que levam valor (--attr-source) e na palavra do shell no lugar do subcomando (`git $FLAGS -C x commit`), no `bash -c -e '…'` e no descritor de `2>/dev/null` (que não é argumento) · cfg — a LEITURA que traz configuração capaz de rodar programa
#   (`-c alias.x=…`, `--config-env`, `-p`, `--exec-path`, GIT_CONFIG_*/GIT_PAGER/GIT_EXTERNAL_DIFF…) deixa de valer como leitura no clone alheio; chave só de exibição e o próprio clone seguem livres · msg — o texto da recusa · check — --selfcheck com settings bom e com cada defeito · hook — o comando de hook de
#   verdade (`python3 -I <guarda> || exit 2`) sai 2 se o guarda trava, some ou tem erro de sintaxe (falha fechada), e 0 se libera · lex — o que o shell lê como TEXTO não vira operador nem
#   some (subgrupos: lexq aspas e `\` · lexs redirecionamento sem alvo · lexe palavra vazia · lexd `$'…'`/`$"…"` · lexu aspa ou `\` que não fecha, também num comentário `#` · lexr `$( )` do alvo
#   de redirecionamento · lexh heredoc/`<<<`/find · lexp os controles que NÃO bloqueiam) · dest — o lugar onde o git escreve vem como ARGUMENTO, sem -C (worktree remove ../outro,
#   clone/init <outro>/x, checkout-index --prefix=…; subgrupos destb e destp) · interp — o texto que um INTERPRETADOR (python -c, node -e, perl -e, ruby -e, awk) ou um pipe entrega a um
#   shell roda: as 12 formas que só o cc-safety-net pegava (ga-tphd15o; subgrupos interpc código de interpretador e os delimitadores de literal que o guarda lê — q<…>, %Q{…}, [[…]] —, interpp pipe que um shell lê, interpe base64/rev/eval/printf -v e a atribuição/cd dentro de bloco em VÁRIAS linhas).
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar (214 mutantes); e
#   contra um stub que só sai 0 (o servidor ANTES desta fatia: o hook do mini era `drop` e nada o substituía), quase tudo falha.
# VARIÁVEIS: RCG_UNDER_TEST (guarda a testar) · RCG_ONLY (grupos, vírgula) · RCG_NO_MUTANTS=1
# BUDGET (grupo à parte, ga-tih62nv): o pedido que fazia o guarda girar SEM FIM (e que o hook deixava seguir sem conferência ao estourar o prazo de 600 s do Claude Code) termina;
#   passou do teto de passos ou de tempo = BLOQUEADO, nunca liberado. Cada caso roda com prazo próprio (o guarda de antes não termina nesse pedido: o caso tem que reprovar, não pendurar).
#   Tentativa 2 no gate (parecer: a definição aninhada registrava o NOME sem condição e uma função chamada git pulava o git_hit): uma função chamada git NUNCA isenta a chamada (definição
#   condicional, em subshell, f que não rodou, command git / env git / \git), `g()` + newline + `{` e `function g()` no topo são definições, e a mesma aninhada reexecutada não se registra de novo.
#   A CLASSE disso: uma função com nome de comando que o guarda trata ANTES do ramo de função (bash, env, cd, find, eval, export, sudo, ssh…) é chamada como função pelo shell; o corpo
#   é reexecutado antes dos ramos especiais, e um cd ou export coberto por função vale "não sei".
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${RCG_UNDER_TEST:-$HERE/remote-clone-guard.py}"
T=$(cd "$(mktemp -d /tmp/rcg.XXXXXX)" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
export HOME="$T/home"; unset RCG_ROOT CLAUDE_PROJECT_DIR
TERR="$HOME/gt-remote/git"; OWN="$TERR/r/wt/own"; OTH="$TERR/r/wt/other"; OUT="$T/fora/repo"
mkdir -p "$OWN/sub" "$OTH/sub" "$TERR/r/repo.git" "$OUT/.git"
: > "$OWN/.git"; : > "$OTH/.git"; : > "$TERR/r/repo.git/HEAD"; ln -s "$OTH" "$OWN/link"
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
group() { [ -z "${RCG_ONLY:-}" ] || case ",$RCG_ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }
grp() { group "$1" || group "$2"; }  # subgrupo OU o grupo inteiro (RCG_ONLY=lex roda todos os lex*, RCG_ONLY=lexq só um: cada mutante roda só o subgrupo que o cobre)
mk() { python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "cwd": sys.argv[2], "tool_input": {sys.argv[3]: sys.argv[4]}}))' "$@"; }
run() {  # run PROJ < json   → RC, $T/err
  if [ -n "$1" ]; then (cd "$OWN" && CLAUDE_PROJECT_DIR="$1" python3 -I "$P" >"$T/o" 2>"$T/err"); else (cd "$OWN" && python3 -I "$P" >"$T/o" 2>"$T/err"); fi; RC=$?
}
g() {  # g QUERO DESCRIÇÃO TOOL CAMPO VALOR [CWD] [PROJ]
  run "${7-$OWN}" < <(mk "$3" "${6-$OWN}" "$4" "$5"); [ "$RC" = "$1" ]; ok $? "$2 (rc=$RC, queria $1)"
}
b() { g "$1" "$2" Bash command "$3" "${4-$OWN}" "${5-$OWN}"; }

g_block() {
  local op
  for op in "commit -m x" "push origin HEAD" "merge main" "rebase main" "reset --hard" "cherry-pick abc" "checkout -- f" "add ." "stash" "clean -fd" \
            "branch -D x" "tag -d v1" "revert HEAD" "am p.mbox" "apply p.diff" "switch x" "restore f" "rm f" "mv a b" "update-ref HEAD x" "fetch" "pull"; do
    b 2 "block: git -C <alheio> $op" "git -C $OTH $op"
  done
  b 2 "block: -C relativo" "git -C ../other commit -m x" "$OWN"
  b 2 "block: -C encadeado (-C own -C ../other)" "git -C $OWN -C ../other commit"
  b 2 "block: ~/ expandido" "git -C ~/gt-remote/git/r/wt/other commit"
  b 2 "block: --git-dir" "git --git-dir=$OTH/.git commit"
  b 2 "block: --git-dir separado" "git --git-dir $OTH/.git commit"
  b 2 "block: --work-tree" "git --work-tree=$OTH add ."
  b 2 "block: GIT_DIR=" "GIT_DIR=$OTH/.git git commit"
  b 2 "block: GIT_WORK_TREE=" "GIT_WORK_TREE=$OTH git add ."
  b 2 "block: symlink do meu clone para o alheio" "git -C $OWN/link commit"
  b 2 "block: subpasta do alheio" "git -C $OTH/sub commit"
  b 2 "block: cwd dentro do alheio" "git commit -m x" "$OTH"
  b 2 "block: cwd dentro do alheio (push)" "git push" "$OTH"
  b 2 "block: o espelho repo.git" "git -C $TERR/r/repo.git update-ref HEAD x"
  b 2 "block: com o meu clone de projeto mas outro cwd" "git commit" "$OTH" "$OWN"
}
g_pass() {
  local op
  for op in "log" "log --oneline -5" "status" "diff HEAD~1" "show HEAD" "rev-parse HEAD" "ls-files" "blame f" "branch" "branch -a" "branch --show-current" \
            "tag -l" "stash list" "stash show" "config --get user.name" "remote -v" "worktree list" "grep x" "cat-file -p HEAD" "describe" "reflog"; do
    b 0 "pass: leitura git -C <alheio> $op" "git -C $OTH $op"
  done
  b 0 "pass: commit no cwd (próprio)" "git commit -m x"
  b 0 "pass: -C no próprio" "git -C $OWN push origin HEAD"
  b 0 "pass: -C subpasta do próprio" "git -C $OWN/sub commit"
  b 0 "pass: cd no próprio e escreve" "cd $OWN/sub && git commit"
  b 0 "pass: cwd em subpasta do próprio" "git add ." "$OWN/sub"
  b 0 "pass: escrita fora do território" "git -C $OUT commit -m x"
  b 0 "pass: cd fora do território e escreve" "cd $OUT && git commit"
  b 0 "pass: só cita o outro clone (echo)" "echo git -C $OTH commit"
  b 0 "pass: mensagem de commit cita o outro clone" "git commit -m 'fix: git -C $OTH commit deixou de rodar'"
  b 0 "pass: corpo de heredoc cita o outro clone" "git commit -F - <<'EOF'
git -C $OTH commit -m x
It's fine
EOF"
  b 0 "pass: heredoc com apóstrofo no próprio" "git commit -F - <<'EOF'
It's a message
EOF"
  b 0 "pass: subshell que volta de cd" "(cd $OTH && git log); git commit -m x"
  b 0 "pass: comando que não é git" "ls -la $OTH && cat $OTH/f"
  b 0 "pass: stash list no alheio" "git -C $OTH stash list"
  b 0 "pass: pipeline de leitura" "git -C $OTH log | head -3"
  b 0 "pass: redirecionamento 2>&1" "git -C $OTH log 2>&1 | head"
  for op in "branch --contains HEAD" "branch --no-contains HEAD" "branch --merged" "branch --list 'feat/*'" "branch -l 'feat/*'" "branch --points-at HEAD" "branch --sort=-committerdate" \
            "branch --format=%(refname)" "branch -a --contains HEAD" "tag --list 'v*'" "tag -l 'v*'" "tag --contains HEAD" "tag --points-at HEAD" "tag -n5" "tag -l -n 'v*'" \
            "config user.name" "config --local user.name" "config --global --get-all user.name"; do
    b 0 "pass: leitura que parecia escrita (gate ga-iczduy): git -C <alheio> $op" "git -C $OTH $op"
  done
}
g_evade() {
  b 2 "evade: command git" "command git -C $OTH commit"
  b 2 "evade: env VAR=1 git" "env FOO=1 git -C $OTH commit"
  b 2 "evade: caminho do git" "/usr/bin/git -C $OTH commit"
  b 2 "evade: sudo -u" "sudo -u runner git -C $OTH commit"
  b 2 "evade: xargs git" "echo x | xargs git -C $OTH commit"
  b 2 "evade: xargs -I {}" "echo x | xargs -I {} git -C $OTH push"
  b 2 "evade: timeout 5" "timeout 5 git -C $OTH commit"
  b 2 "evade: bash -c" "bash -c 'git -C $OTH reset --hard'"
  b 2 "evade: sh -lc" "sh -lc \"git -C $OTH push\""
  b 2 "evade: eval" "eval \"git -C $OTH commit\""
  b 2 "evade: \$( )" "echo \$(git -C $OTH commit)"
  b 2 "evade: \$( ) entre aspas" "echo \"\$(git -C $OTH commit)\""
  b 2 "evade: crase" "echo \`git -C $OTH commit\`"
  b 2 "evade: find -exec" "find . -name x -exec git -C $OTH commit {} \\;"
  b 2 "evade: depois de ;" "git status; git -C $OTH reset --hard"
  b 2 "evade: depois de &&" "git status && git -C $OTH commit"
  b 2 "evade: depois de ||" "false || git -C $OTH commit"
  b 2 "evade: depois de |" "echo x | git -C $OTH commit -F -"
  b 2 "evade: dentro de ( )" "(git -C $OTH commit)"
  b 2 "evade: ( ); colado" "(cd $OTH; git commit);"
  b 2 "evade: ); colado e o git que vem depois (a pontuação colada separa, não engole a próxima palavra)" "(true); git -C $OTH commit -m y"
  b 2 "evade: );git colado dos dois lados" "(true);git -C $OTH commit -m y"
  b 2 "evade: cd && git" "cd $OTH && git commit"
  b 2 "evade: cd; git" "cd $OTH; git commit"
  b 2 "evade: pushd" "pushd $OTH; git commit"
  b 2 "evade: cd relativo" "cd ../other && git commit" "$OWN"
  b 2 "evade: heredoc no alheio" "git -C $OTH commit -F - <<'EOF'
It's
EOF"
  b 2 "evade: -c user.name antes do -C" "git -c user.name=a -C $OTH commit"
  b 2 "evade: --no-pager antes do -C" "git --no-pager -C $OTH commit"
  b 2 "evade: stash push com 'stash list' na mensagem" "git -C $OTH stash push -m 'stash list'"
  b 2 "evade: branch com delete e nome" "git -C $OTH branch --delete x"
  b 2 "evade: tag criando" "git -C $OTH tag v9"
  b 2 "evade: aspas no caminho" "git -C \"$OTH\" commit"
  b 2 "evade: nova linha separa comandos" "git status
git -C $OTH commit"
  b 2 "evade: crase depois de cd no alheio" "cd $OTH && echo \`git commit\`"
  b 2 "evade: crase no valor de -C" 'git -C `pwd` commit'
  b 2 "evade: \$( ) no valor de -C" 'git -C $(pwd) commit'
  b 2 "evade: \$( ) com parênteses dentro e depois o subcomando" 'git -C $(cd x && (pwd)) commit'
  b 2 "evade: VAR=\$(git alheio) antes de outro comando" "X=\$(git -C $OTH commit) true"
  b 2 "evade: \$( ) aninhado" "echo \$(echo \$(git -C $OTH commit))"
  b 2 "evade: \$( ) em heredoc SEM aspas roda" "cat <<EOF
\$(git -C $OTH commit)
EOF"
  b 0 "pass: \$( ) em heredoc COM aspas é texto" "cat <<'EOF'
\$(git -C $OTH commit)
EOF"
  for c in "export GIT_DIR=$OTH/.git; git commit" "export GIT_WORK_TREE=$OTH && git add ." "declare -x GIT_DIR=$OTH/.git; git commit" "GIT_DIR=$OTH/.git; git commit" \
           "env GIT_DIR=$OTH/.git git commit" "sudo GIT_DIR=$OTH/.git git commit" "env -C $OTH git commit" "env --chdir=$OTH git commit" "env -C$OTH git commit" \
           "sudo -D $OTH git commit" "env -S 'git -C $OTH commit'" "env -C $OTH find . -exec git commit {} \\;" "git -C $OTH remote -v add x y" "git -C $OTH remote add x y" \
           "git -C $OTH log --output=x" "git -C $OTH diff --output x" "git -C $OTH fsck --lost-found" "git -C $OTH grep --open-files-in-pager=x y"; do
    b 2 "evade: $c" "$c"
  done
  for c in "export GIT_DIR=$OWN/.git; git commit" "export FOO=1; git commit" "export GIT_DIR=$OTH/.git; git log" "env -C $OTH git log" "env -C $OWN git log" "git -C $OTH remote -v" \
           "git -C $OTH remote show origin" "git -C $OTH remote get-url origin" "git -C $OTH diff --stat" "GIT_DIR=$OTH/.git git log; git commit -m x"; do
    b 0 "pass: $c" "$c"
  done
  b 0 "pass: \$( ) de leitura no alheio" "echo \$(git -C $OTH log -1)"
  b 0 "pass: \$( ) que não é git" "echo \$(date) \`hostname\`"
}
g_closed() {
  b 2 "closed: -C com variável" 'git -C "$X" commit'
  b 2 "closed: -C com glob" "git -C $TERR/r/wt/* commit"
  b 2 "closed: -C com ~usuário" "git -C ~runner/x commit"
  b 2 "closed: -C com crase" 'git -C `pwd` commit'
  b 2 "closed: cd para variável" 'cd $D && git commit'
  b 2 "closed: --git-dir com variável" 'git --git-dir=$G commit'
  b 2 "closed: subcomando que não conheço" "git -C $OTH frobnicate"
  b 2 "closed: alias (subcomando curto)" "git -C $OTH ci -m x"
  b 2 "closed: branch com argumento" "git -C $OTH branch novo"
  b 2 "closed: config sem --get" "git -C $OTH config user.name x"
  local w
  for w in "branch --list -d velho" "branch --list --delete velho" "branch --contains HEAD -d velho" "branch -m velho novo" "branch --sort novo" "branch --contains -D x" "tag v1" "tag -d v1" "tag -a v1 -m x" \
           "tag --list -d v1" "tag -l -f v1" "config --unset user.name" "config --edit" "config user.name x y" "config --local user.name x" "config --global --add k v" "config -e"; do
    b 2 "closed: continua escrita (a leitura nova não vira brecha): git -C <alheio> $w" "git -C $OTH $w"
  done
  nest() { python3 -c 'import shlex,sys
c = sys.argv[2]
for _ in range(int(sys.argv[1])): c = "bash -c " + shlex.quote(c)
print(c)' "$@"; }
  b 2 "closed: 3 níveis de bash -c ainda são abertos" "$(nest 3 "git -C $OTH commit")"
  b 2 "closed: 5 níveis de bash -c (fundo demais para conferir) bloqueiam" "$(nest 5 "git -C $OTH commit")"
  b 2 "closed: 5 níveis de bash -c bloqueiam mesmo com comando inofensivo (não sei = bloqueia)" "$(nest 5 "git log")"
  b 0 "closed: leitura com variável não é escrita" 'git -C "$X" log'
  run "$OWN" < <(echo 'isto não é json com git'); [ "$RC" = 2 ]; ok $? "closed: JSON ruim que cita git bloqueia (rc=$RC)"
  run "$OWN" < <(echo 'lixo'); [ "$RC" = 0 ]; ok $? "closed: JSON ruim sem git/arquivo não trava a sessão toda (rc=$RC)"
  b 2 "closed: sem CLAUDE_PROJECT_DIR toda escrita no território bloqueia" "git commit -m x" "$OWN" ""
  b 0 "closed: sem CLAUDE_PROJECT_DIR leitura passa" "git log" "$OWN" ""
  b 0 "closed: sem CLAUDE_PROJECT_DIR escrita fora do território passa" "git commit" "$OUT" ""
  b 2 "closed: projeto fora do território (sem clone próprio)" "git commit" "$OWN" "$OUT"
  run "$OWN" < <(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git -C '"$OTH"' commit"}}))'); [ "$RC" = 2 ]; ok $? "closed: sem cwd no JSON ainda bloqueia o alvo explícito (rc=$RC)"
  run "$OWN" < <(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git commit"}}))'); [ "$RC" = 2 ]; ok $? "closed: sem cwd no JSON, git sem -C é 'não sei' e bloqueia (rc=$RC)"
}
g_shell() {  # gate ga-iczduy (rodada 1): palavra que o guarda não entende na posição de COMANDO ou de DIRETÓRIO não pode valer "não é git" nem "diretório que conheço"
  local c
  for c in "if true; then git -C $OTH commit -m x; fi" "for d in $OTH; do git -C $OTH commit -m x; done" "for d in $OTH; do git -C \$d commit -m x; done" \
           "{ git -C $OTH commit -m x; }" "! git -C $OTH commit -m x" "until git -C $OTH push; do :; done" "while git -C $OTH commit -m x; do :; done" \
           "if false; then :; elif git -C $OTH commit -m x; then :; fi" "if true; then :; else git -C $OTH commit -m x; fi" "f() { git -C $OTH commit -m x; }; f" \
           "function f { git -C $OTH commit -m x; }; f" "bash -c 'if true; then git -C $OTH commit -m x; fi'" "case x in x) git -C $OTH commit -m x ;; esac" \
           "coproc git -C $OTH commit -m x" "coproc W { git -C $OTH commit -m x; }" "{ cd $OTH; git commit -m x; }" "for d in $OTH; do cd \$d; git commit -m x; done" "if true; then cd $OTH; git commit -m x; fi" \
           "cat <(git -C $OTH commit -m x)" "tee >(git -C $OTH commit -F -)" "diff <(git -C $OTH log) <(git -C $OTH commit -m x)"; do
    b 2 "shell: $c" "$c"
  done
  for c in "cd -- $OTH && git commit -m x" "cd -P $OTH && git commit -m x" "cd -L $OTH && git commit -m x" "cd -P -- $OTH && git commit -m x" "pushd -- $OTH && git commit -m x" \
           "cd -Z $OTH && git commit -m x" "cd $OWN $OTH && git commit -m x" "pushd && git commit -m x" "pushd +1 && git commit -m x" "builtin cd -- $OTH && git commit -m x"; do
    b 2 "shell: cd/pushd com opção ou argumento que não leio vira 'não sei': $c" "$c"
  done
  for c in "flock $T/l git -C $OTH commit -m x" "ionice -c3 git -C $OTH commit -m x" "chrt -i 0 git -C $OTH commit -m x" "taskset 1 git -C $OTH commit -m x" \
           "parallel git -C $OTH commit -m x ::: a" "su runner -c 'git -C $OTH commit -m x'" "ssh localhost 'git -C $OTH commit -m x'" \
           "script -qc 'git -C $OTH commit -m x' /dev/null" "sudo flock $T/l git -C $OTH commit -m x" "trap 'git -C $OTH commit -m x' EXIT" \
           "flock $T/l git commit -m x" "flock $T/l git -C \$X commit -m x"; do
    b 2 "shell: embrulho que não modelo: $c" "$c"
  done
  b 2 "shell: bash <<'EOF' roda o corpo" "bash <<'EOF'
git -C $OTH commit -m x
EOF"
  b 2 "shell: bash -s <<EOF roda o corpo" "bash -s <<EOF
cd $OTH
git commit -m x
EOF"
  b 2 "shell: sh <<EOF roda o corpo" "sh <<EOF
git -C $OTH push
EOF"
  b 2 "shell: ssh localhost <<EOF roda o corpo" "ssh localhost <<'EOF'
git -C $OTH commit -m x
EOF"
  b 2 "shell: bash <<< 'texto' roda o texto (here-string)" "bash <<< 'git -C $OTH commit -m x'"
  b 2 "shell: sh -s <<<\"cd …; git …\" roda o texto" "sh -s <<<\"cd $OTH; git commit -m x\""
  b 2 "shell: ssh localhost <<< 'texto' roda o texto" "ssh localhost <<< 'git -C $OTH push'"
  b 2 "shell: continuação de linha não esconde a escrita" "git -C $OTH \\
commit -m x"
  b 2 "shell: barra dupla + nova linha NÃO é continuação (a linha seguinte é outro comando)" "echo \\\\
git -C $OTH commit -m x"
  for c in "if git status; then git commit -m x; fi" "for f in a b; do git add \$f; done" "{ git commit -m x; }" "! git log" "while read l; do echo \$l; done < /dev/null" \
           "f() { git commit -m x; }; f" "cat <(git -C $OTH log)" "diff <(git -C $OTH log) <(git log)" "if true; then cd $OWN/sub; git commit -m x; fi" \
           "cd -- $OWN/sub && git commit -m x" "cd -P $OWN && git commit -m x" "cd -L -- $OWN; git commit -m x" "pushd -- $OWN/sub && git commit -m x" "cd && ls" \
           "flock $T/l git -C $OWN commit -m x" "flock $T/l git -C $OTH log" "ionice -c3 git -C $OTH status" "ssh localhost 'git -C $OTH log'" "ssh localhost uptime" \
           "su runner -c 'git -C $OTH log'" "trap 'echo oi' EXIT" "for d in a b; do echo \$d; done"; do
    b 0 "pass: $c" "$c"
  done
  b 0 "pass: bash <<EOF só com leitura no alheio" "bash <<'EOF'
git -C $OTH log
EOF"
  b 0 "pass: bash <<< 'texto' só com leitura no alheio" "bash <<< 'git -C $OTH log'"
  b 0 "pass: here-string para quem não é shell continua sendo texto" "git commit -F - <<< 'git -C $OTH commit -m x'"
  b 0 "pass: cat <<< 'texto' é só texto" "cat <<< 'git -C $OTH commit -m x'"
  b 0 "pass: bash <<EOF que não é git" "bash <<'EOF'
echo oi
EOF"
  b 0 "pass: heredoc de commit que não é shell continua sendo texto" "git commit -F - <<'EOF'
git -C $OTH commit -m x
EOF"
  b 0 "pass: continuação de linha entre -C e o subcomando de leitura" "git -C $OTH \\
log"
}
g_wrap() {  # gate ga-iczduy (rodada 2): o MESMO defeito das rodadas anteriores (o que o guarda não entende vale "não é git") em find, nas opções de CADA embrulho, no git de topo e no bash -c
  local c
  for c in "find $T -name .git -execdir git pull \\;" "find . -name .git -okdir git add -A \\;" "find . -execdir git commit -m x ';'" "find . -execdir sh -c 'git commit -m x' \\;" \
           "find . -execdir bash -c 'git add -A' \\;" "find . -name x -exec echo {} \\; -exec git -C $OTH commit -m x \\;" "find . \\( -name a \\) -o -exec git -C $OTH commit -m x \\;" \
           "find . -name x -exec echo {} \\; -execdir git commit -m x \\;" "find . -name x -exec echo {} \\; -ok git -C $OTH commit -m x \\;" "find . -name x -exec sh -c 'git -C \"\$0\" commit' {} \\;" \
           "find . -name x -exec echo {} + -exec git -C $OTH commit -m x +" "cd $OTH && find . -name x -exec git commit -m x {} \\;"; do
    b 2 "wrap: find: $c" "$c"
  done
  for c in "find . -name x -execdir git log \\;" "find . -name x -execdir git -C $OWN commit {} \\;" "find . -name x -exec git commit {} \\;" "find . -name x -exec echo {} \\; -exec git status \\;" \
           "find . -name x -exec echo {} \\; -exec git commit -m x \\;" "find . -name x -exec git -C $OTH log {} \\;" "find . -name x -execdir git -C $OTH log \\;"; do
    b 0 "pass: wrap: find: $c" "$c"
  done
  for c in "sudo -n git -C $OTH commit -m x" "sudo -E git -C $OTH commit" "sudo -P git -C $OTH commit" "sudo -nE git -C $OTH commit" "sudo -u root -n git -C $OTH commit" "sudo -h host git -C $OTH commit" \
           "sudo -p x git -C $OTH commit" "sudo -- git -C $OTH commit" "sudo -u root -- git -C $OTH commit" "sudo --user root git -C $OTH commit" "sudo --preserve-env=PATH git -C $OTH commit" \
           "xargs -a F git -C $OTH commit" "xargs --arg-file F git -C $OTH commit" "xargs -0 -r git -C $OTH commit" "xargs -n1 git -C $OTH commit" "xargs -i{} git -C $OTH commit" \
           "stdbuf -o L git -C $OTH commit" "stdbuf --output L git -C $OTH commit" "stdbuf -oL -eL git -C $OTH commit" "timeout --signal KILL 5 git -C $OTH commit" "timeout -k 1 5 git -C $OTH commit" \
           "timeout 1.5 git -C $OTH commit" "nice -5 git -C $OTH commit" "nice -n 5 git -C $OTH commit" "nice --adjustment 5 git -C $OTH commit" "exec -a x git -C $OTH commit" "env - git -C $OTH commit" \
           "env -u X git -C $OTH commit" "env -i -u X git -C $OTH commit" "env --split-string='git -C $OTH commit'" "env -S'git -C $OTH commit'" "time -p git -C $OTH commit" "time -f %e git -C $OTH commit" \
           "setsid -f git -C $OTH commit" "doas -u x git -C $OTH commit" "command -p git -C $OTH commit" "sudo -n timeout 5 nice -n 1 git -C $OTH commit" \
           "sudo --frobnicate x git -C $OTH commit" "xargs -Z x git -C $OTH commit" "sudo --frobnicate git commit -m x"; do
    b 2 "wrap: embrulho: $c" "$c"
  done
  for c in "sudo -n git commit -m x" "sudo -nE git commit -m x" "sudo -u root -- git commit -m x" "sudo -E git -C $OWN commit" "nice -n 5 git commit -m x" "nice -5 git commit" "timeout 5 git commit -m x" \
           "timeout -k 1 5 git commit" "timeout --signal KILL 5 git commit" "timeout 1.5 git commit" "env -i git commit -m x" "env - git commit" "env -u X git commit" "xargs -n1 git commit" \
           "xargs -I{} git commit" "xargs -i{} git commit" "xargs -a F git commit" "stdbuf -o L git commit" "stdbuf -oL git commit" "exec -a x git commit" "time -p git commit" "setsid -f git commit" \
           "command -p git commit" "nohup git commit" "sudo -n git -C $OTH log" "xargs -a F git -C $OTH log" "env FOO=1 git commit" "sudo --frobnicate git -C $OWN commit -m x" \
           "sudo -i git commit -m x"; do
    b 0 "pass: wrap: embrulho: $c" "$c"
  done
  for c in "git --attr-source HEAD -C $OTH commit" "git --attr-source=HEAD -C $OTH commit" "git --future-opt x -C $OTH commit" "git --future-flag commit -m x" "git -c user.name=a --future-opt x -C $OTH commit" \
           "git --future-opt x -C $OWN commit -m x"; do  # o último é falso positivo ASSUMIDO: não sei se `x` é o valor da opção ou o subcomando, então o `-C` depois dele não vale
    b 2 "wrap: git de topo: $c" "$c"
  done
  for c in "git --attr-source HEAD -C $OWN commit" "git --attr-source=HEAD commit -m x" "git --no-optional-locks -C $OTH status" "git --no-pager commit -m x" "git -P log"; do
    b 0 "pass: wrap: git de topo: $c" "$c"
  done
  for c in "git \$FLAGS -C $OTH commit -m x" "git \"\$X\" -C $OTH commit -m x" "git \"\$@\"" "git \$(echo -C) $OTH commit -m x" "git * -C $OTH commit" "git -C $OTH \$SUB -m x" "git \$FLAGS commit -m x"; do
    b 2 "wrap: palavra do shell na posição do subcomando (esconde um -C): $c" "$c"  # o último é falso positivo ASSUMIDO (não sei o que \$FLAGS vira)
  done
  for c in "git commit -m \"\$msg\"" "git -C $OWN commit -m \"\$msg\"" "git -C $OTH log \"\$X\"" "git -C $OTH log \$(echo -1)"; do
    b 0 "pass: wrap: variável depois do subcomando não esconde opção de topo: $c" "$c"
  done
  for c in "bash -c -e 'git -C $OTH commit -m x'" "bash -c -- 'git -C $OTH commit -m x'" "sh -c +e 'git -C $OTH commit -m x'" "bash -c -x -e \"git -C $OTH push\""; do
    b 2 "wrap: shell -c com opção depois do -c: $c" "$c"
  done
  b 0 "pass: wrap: bash -c -e no próprio clone" "bash -c -e 'git -C $OWN commit -m x'"
  b 0 "pass: wrap: bash -c -- no próprio clone" "bash -c -- 'git commit -m x'"
  for c in "cd $OWN/sub 2>/dev/null && git commit -m x" "cd $OWN/sub 2>&1 && git add -A" "git commit -m x 2>/dev/null" "git commit -m x 1>/dev/null 2>&1" "git add . 2>>$T/log" "cd $OWN 2>/dev/null; git commit -m x"; do
    b 0 "pass: wrap: descritor do redirecionamento não é argumento: $c" "$c"
  done
  for c in "cd $OTH 2>/dev/null && git commit -m x" "git -C $OTH commit -m x 2>/dev/null" "git -C $OTH tag 1 >/dev/null" "git -C $OTH branch -D 2 2>&1" "cd $OTH 2>&1; git commit -m x"; do
    b 2 "wrap: o descritor some, o argumento que é número fica: $c" "$c"
  done
}
g_lex() {  # gate ga-cgu53f (rodada 3): o shlex tira as aspas e a barra, então `'>'`, `\>` e `''` chegavam ao guarda como um `>` de verdade ou como NADA; o que o shell lê como texto tem que continuar sendo palavra
  local c NL=$'\n'
  if grp lexq lex; then
  for c in "echo '>' && git -C $OTH commit -m y" "echo '>>' && git -C $OTH commit -m y" "echo '<' && git -C $OTH commit -m y" "echo '<>' && git -C $OTH commit -m y" "echo '&>' && git -C $OTH commit -m y" \
           "echo \\> ; git -C $OTH commit -m y" "echo \\< ; git -C $OTH commit -m y" "echo \\>x ; git -C $OTH commit -m y" "echo \">\" && git -C $OTH commit -m y" "tr -d '<>' ; git -C $OTH commit -m y" \
           "echo '>' || git -C $OTH commit -m y" "echo '>' | git -C $OTH commit -m y" "echo '>' & git -C $OTH commit -m y" "echo '<'${NL}git -C $OTH commit -m y" "echo 'a > b' ; git -C $OTH commit -m y" \
           "echo '>' ; echo '<' ; git -C $OTH commit -m y" "echo '(' ; git -C $OTH commit -m y" "echo ')' ; git -C $OTH commit -m y" "echo '&&' ; git -C $OTH push" "echo \"a;b\" ; git -C $OTH commit -m y" \
           "bash -c \"echo '>' && git -C $OTH commit -m y\"" "sh -c \"git -C $OTH commit -m '>'\"" "eval \"echo '>' ; git -C $OTH commit -m y\"" "ssh host \"echo '>' ; git -C $OTH commit\""; do
    b 2 "lex: operador entre aspas ou com barra é palavra, o git depois dele é conferido: $c" "$c"
  done
  for c in "xargs -I '>' git -C $OTH commit -m y" "xargs -I '>>' git -C $OTH commit -m y" "xargs -I '<' git -C $OTH commit -m y" "xargs -I '<>' git -C $OTH commit -m y" "xargs -I '&>' git -C $OTH commit -m y" \
           "xargs -I \\> git -C $OTH commit -m y" "xargs -I \">\" git -C $OTH commit -m y" "xargs -d '>' git -C $OTH commit -m y" "xargs -E '<' git -C $OTH commit -m y" \
           "(cd $OTH && echo ')' && git commit -m y)" "echo '(' ; cd $OTH ; echo ')' ; git commit -m y" "(cd $OTH && echo \\) && git commit -m y)" "echo \"(\" ; cd $OTH ; echo \")\" ; git commit -m y"; do
    b 2 "lex: o operador entre aspas ou com barra como VALOR de opção não engole o git, e o ')' de texto não desfaz o cd: $c" "$c"
  done
  fi
  if grp lexs lex; then
  for c in "git -C $OTH commit -m '>'" "git -C $OTH commit -m '<'" "git -C $OTH commit -m '>>'" "git -C $OTH commit -m '<>'" "git -C $OTH commit -m '&>'" "git -C $OTH tag -a v1 -m '<'" "git -C $OTH commit -m \">\"" "git -C $OTH commit -m \\>" \
           "git -C $OTH commit -m ';'" "git -C $OTH commit -m '&&'" "git -C $OTH commit -m '|'" "git -C $OTH commit >" "git -C $OTH commit <" "git -C $OTH commit -m y 2>" "echo hi > && git -C $OTH commit -m y" \
           "echo hi > ; git -C $OTH commit -m y" "echo hi >> | git -C $OTH commit -m y" "echo hi > f ; git -C $OTH commit -m y" "echo hi >f && git -C $OTH commit -m y"; do
    b 2 "lex: operador no fim ou sem alvo não engole o terminador, e o alvo de verdade é só uma palavra: $c" "$c"
  done
  fi
  if grp lexe lex; then
  for c in "git -C '' -C $OTH commit -m y" "git -C \"\" -C $OTH commit -m y" "git -C $OTH -C '' commit -m y" "git -C '' -C '' -C $OTH commit" "git -C $OTH commit -m ''" "echo '' && git -C $OTH commit -m y" "echo \"\" ; git -C $OTH commit -m y" \
           "sudo -u '' git -C $OTH commit -m y" "env -u '' git -C $OTH commit -m y" "nice -n '' git -C $OTH commit -m y" "git -c '' -C $OTH commit -m y" "git --git-dir '' -C $OTH commit" "cd '' ; git -C $OTH commit -m y" \
           "xargs -I '' git -C $OTH commit"; do
    b 2 "lex: palavra vazia ('' ou \"\") fica no lugar e não desloca o que vem depois: $c" "$c"
  done
  fi
  if grp lexd lex; then
  for c in "\$'git' -C $OTH commit -m y" "\$\"git\" -C $OTH commit -m y" "\$'\\x67it' -C $OTH commit -m y" "\$'\\147it' -C $OTH commit -m y" "g\$'i't -C $OTH commit -m y" "git -C \$'$OTH' commit -m y" \
           "echo \$'\\'' ; git -C $OTH commit -m y ; echo \$'\\''" "echo \$'\\'' ; git -C $OTH commit -m y ; echo \\'" "echo \$(git -C $OTH commit -m y)'x'"; do
    b 2 "lex: \$'…' e \$\"…\" são palavras do shell (o \$ some, os escapes valem), e o \$( ) colado numa aspa fica inteiro: $c" "$c"
  done
  fi
  if grp lexu lex; then
  for c in "git -C '' -C $OTH commit -m y ; echo 'x" "\$'git' -C $OTH commit -m y${NL}echo 'oops" "git -C $OTH commit -m y ; echo 'x" "git -C $OTH -C '' commit -m y ; echo \"x" \
           "bash -c 'git -C $OTH commit -m y' # it's" "xargs -I '>' git -C $OTH commit -m y # it's" "bash -c 'git -C $OTH commit -m y' \\" "git -C $OTH commit -m y \\" "eval 'git -C $OTH commit -m y' # it's" \
           "git status # it's${NL}git -C $OTH commit -m y" "git status # say \"hi${NL}git -C $OTH commit -m y" "git status # don't \"x${NL}git -C $OTH commit -m y" "echo \"it's${NL}git -C $OTH commit -m y" "echo \$'x${NL}git -C $OTH commit -m y"; do
    b 2 "lex: aspa que não fecha (ou \\ no fim): sai do texto e o resto é conferido, o shell pode ter lido a aspa num comentário #: $c" "$c"
  done
  for c in "git status # it's fine" "git commit -m y # don't" "git status \\" "git log # it's ; git -C $OTH log" "git -C $OTH log # it's" "git commit -m \"it's\" # don't" "git status # \"x" "git status # it's \"x" "ls # it's" "echo \"it's\" ; git status" "git status ${NL}# it's"; do
    b 0 "pass: lex: aspa ou \\ solto no fim de um comando que não escreve em clone alheio segue livre: $c" "$c"
  done
  fi
  if grp lexr lex; then
  for c in "echo hi > \$(git -C $OTH commit -m y)" "echo hi >> \$(git -C $OTH commit -m y)" "cat < \$(git -C $OTH commit -m y)" "echo hi 2> \$(git -C $OTH commit -m y)" "echo hi >| \$(git -C $OTH commit -m y)" \
           "echo hi >& \$(git -C $OTH commit -m y)" "cat <<< \$(git -C $OTH commit -m y)" "echo hi > \`git -C $OTH commit -m y\`"; do
    b 2 "lex: o \$( ) do alvo de um redirecionamento roda: $c" "$c"
  done
  fi
  if grp lexh lex; then
  b 2 "lex: <<< não abre heredoc (o que vem depois é comando)" "cat <<< EOF${NL}git -C $OTH commit -m y${NL}EOF"
  b 2 "lex: <<<PALAVRA colado não abre heredoc" "cat <<<EOF${NL}git -C $OTH commit -m y${NL}EOF"
  for c in "find . '(' -name a ')' -exec git -C $OTH commit -m x ';'" "find . -name x -exec echo {} ';' -exec git -C $OTH commit -m x ';'" "find . -exec git -C $OTH commit -m '>' \\;" "eval echo hi ';' git -C $OTH commit"; do
    b 2 "lex: find/eval com \`;\` entre aspas ou com barra: $c" "$c"
  done
  fi
  if grp lexp lex; then
  for c in "git -C '' commit -m y" "git -C \"\" commit -m y" "git -C $OWN -C '' commit -m y" "echo '>' && git commit -m y" "echo \\> ; git commit -m y" "git commit -m '>'" "git commit -m '<>'" "git commit -m 'a; b && c | d (e) > f'" \
           "git commit -m 'git -C $OTH commit'" "git commit -m \"git -C $OTH push; ok\"" "echo '>' ; git -C $OTH log" "tr -d '<>' ; git add -A" "git commit -m ''" "echo '' && git commit -m y" "git commit -m \$'a\\nb'" "git commit -m \$'it\\'s'" \
           "cat <<< hello && git status" "cat <<< x; cat <<EOF${NL}git -C $OTH commit -m y${NL}EOF" "echo a >| $OWN/f && git commit -m y" "git commit -m x > $OWN/log; git status" "git status > $OWN/o 2>&1" "sudo -u '' git commit -m y" \
           "echo hi > '' ; git commit -m y" "echo hi > \$(mktemp)" "git -C $OTH log > \$(mktemp)" "cat <<< \$(echo hi)" "bash -c \"echo '>' && git commit -m y\"" "git commit -m \$\"mensagem\"" "echo \$'git' -C $OTH commit"; do
    b 0 "pass: lex: o que o shell lê como texto não vira operador nem some: $c" "$c"
  done
  fi
}
g_dest() {  # gate ga-cgu53f (rodada 3, medium): o lugar onde o git escreve vem como ARGUMENTO (sem -C): worktree remove ../outro, clone <repo> <outro>/x, init <outro>/x, checkout-index --prefix=<outro>/
  local c
  if grp destb dest; then
  for c in "git worktree remove --force ../other" "git worktree remove $OTH" "git worktree move $OTH ../x" "git worktree move ../x $OTH/sub" "git worktree add $OTH/sub" "git worktree add -b nb $OTH/sub" "git worktree lock ../other" \
           "git worktree unlock $OTH" "git worktree repair $OTH" "git clone $OWN $OTH/sub" "git clone --depth 1 https://example.com/x.git $OTH/sub" "git clone $OWN ../other/sub" "git clone https://example.com/x.git ../other" \
           "git clone https://example.com/x.git $OTH --depth 1" "git init $OTH/sub" "git init --bare $OTH/sub.git" "git init --separate-git-dir=$OTH/g x" "git init --separate-git-dir $OTH/g x" "git checkout-index --prefix=$OTH/ -a" \
           "git checkout-index -a --prefix $OTH/" "git archive -o $OTH/a.tar HEAD" "git archive --output=$OTH/a.tar HEAD" "git archive -o$OTH/a.tar HEAD" "git bundle create $OTH/b.bundle HEAD" "git format-patch -o $OTH HEAD~1" \
           "git format-patch -o$OTH HEAD~1" "git format-patch --output-directory=$OTH HEAD~1" "git submodule add ./x $OTH/s" "git diff --output=$OTH/f" "git log --output=$OTH/f" "git show --output $OTH/f" "git diff --output $OTH/f" \
           "git worktree add \$X" "git worktree remove \"\$WT\"" "git init \$D" "git archive -o \$F HEAD" "git diff --output=\$F" "git worktree add $TERR/r/repo.git/x" "git clone $OWN $TERR/r/wt/nova" "cd $OWN && git worktree add ../nova"; do
    b 2 "dest: o destino que vem como argumento é conferido: $c" "$c"
  done
  b 2 "dest: clone com origem no clone alheio bloqueia (falso positivo ASSUMIDO: não separo a origem do destino)" "git clone $OTH $OWN/sub"
  fi
  if grp destp dest; then
  for c in "git worktree list" "git worktree list --porcelain" "git worktree add $OUT/wt" "git worktree remove $OUT/wt" "git worktree add -b nb $OUT/wt" "git clone https://example.com/x.git" "git clone https://example.com/x.git sub" \
           "git clone 'https://example.com/r.git?x=1' sub" "git clone git@example.com:x/y.git $OWN/sub" "git clone ssh://git@example.com/x/y.git $OUT/y" "git init" "git init $OWN/sub" "git init $OUT/new" "git init --separate-git-dir=$OUT/g x" \
           "git checkout-index --prefix=$OWN/x/ -a" "git checkout-index -a --prefix $OWN/x/" "git archive -o $OWN/a.tar HEAD" "git archive -o $OUT/a.tar HEAD" "git archive --output=$OWN/a.tar HEAD" "git diff --output=$OWN/f" "git log --output=$OUT/f" \
           "git bundle create $OUT/b HEAD" "git format-patch -o $OWN/patches HEAD~1" "git format-patch -o$OWN/patches HEAD~1" "git submodule add ./x $OWN/s" "git commit -m \"veja $OTH/arquivo\"" "git commit -m x $OWN/f" \
           "git -C $OTH worktree list" "git -C $OTH log --oneline -- $OTH/x" "git config user.name 'A B'" "git config alias.x '!git log *'" "git -C $OWN worktree add $OUT/wt" "git -C $OUT/repo worktree add $OUT/wt2"; do
    b 0 "pass: dest: o que não aponta para outro clone segue livre: $c" "$c"
  done
  fi
}
g_cfg() {  # parecer de segurança do push da rodada 1: leitura que TRAZ configuração capaz de rodar programa (alias, pager, fsmonitor…) não é leitura
  local c
  for c in "git -C $OTH -c alias.log='!git commit -m x' log" "git -C $OTH -c core.pager='sh -c x' log" "git -C $OTH -c core.fsmonitor=/tmp/x status" \
           "git -C $OTH -c Alias.log=x log" "git -C $OTH -c alias.log log" "git -c core.pager=x -C $OTH log" "git -C $OTH -c user.name=a -c core.pager=x log" \
           "git -C $OTH --config-env=alias.log=EVIL log" "git -C $OTH --config-env alias.log=EVIL log" "git -C $OTH -p log" "git -C $OTH --paginate log" \
           "git -C $OTH --exec-path=/tmp/x log" "git -C $OTH --exec-path log" \
           "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.log GIT_CONFIG_VALUE_0='!x' git -C $OTH log" "GIT_EXTERNAL_DIFF=/tmp/x git -C $OTH diff" "GIT_PAGER='sh -c x' git -C $OTH log" \
           "env GIT_SSH_COMMAND=x git -C $OTH ls-remote origin" "export GIT_PAGER=x; git -C $OTH log" "GIT_EDITOR=x git -C $OTH log" \
           "cd $OTH && git -c alias.log=x log" "bash -c 'git -C $OTH -c alias.log=x log'" "flock $T/l git -C $OTH -c alias.log=x log" "git -C \$X -c alias.log=x log"; do
    b 2 "cfg: $c" "$c"
  done
  for c in "git -C $OTH -c color.ui=never log" "git -C $OTH -c safe.directory='*' status" "git -C $OTH -c core.quotepath=false -c advice.detachedHead=false diff" \
           "git -C $OTH -c user.name=a -c user.email=b@c log" "git -C $OTH --config-env=user.name=NAMEVAR log" "git -C $OTH --no-pager log" "GIT_TERMINAL_PROMPT=0 git -C $OTH log" \
           "git -C $OWN -c core.pager=cat log" "git -c alias.x=y status" "GIT_PAGER=cat git log" "git -C $OWN -p log" "git -C $OUT -c alias.log=x log" "GIT_PAGER=cat git -C $OUT log"; do
    b 0 "pass: $c" "$c"
  done
  b 2 "cfg: a mensagem diz que a LEITURA foi barrada pela configuração" "git -C $OTH -c alias.log=x log"; grep -qF "leitura com configuração que roda programa" "$T/err"; ok $? "cfg: a recusa nomeia o motivo (leitura com configuração que roda programa)"
}
g_tools() {
  local t
  for t in "Edit file_path" "Write file_path" "MultiEdit file_path" "NotebookEdit notebook_path"; do
    set -- $t
    g 2 "tools: $1 no clone alheio" "$1" "$2" "$OTH/f.txt"
    g 2 "tools: $1 no clone alheio, caminho relativo" "$1" "$2" "../other/f.txt" "$OWN"
    g 2 "tools: $1 via symlink do meu clone" "$1" "$2" "$OWN/link/f.txt"
    g 2 "tools: $1 no espelho" "$1" "$2" "$TERR/r/repo.git/HEAD"
    g 0 "tools: $1 no próprio clone" "$1" "$2" "$OWN/sub/f.txt"
    g 0 "tools: $1 fora do território" "$1" "$2" "$OUT/f.txt"
    g 2 "tools: $1 em ~/.claude/hooks (desligaria o guarda)" "$1" "$2" "$HOME/.claude/hooks/remote-clone-guard.py"
    g 2 "tools: $1 em ~/.claude/settings.json" "$1" "$2" "$HOME/.claude/settings.json"
  done
  g 2 "tools: Write sem clone próprio (sem projeto)" Write file_path "$OWN/f" "$OWN" ""
  g 2 "tools: Edit com caminho relativo e sem cwd resolvível" Edit file_path "x.txt" "" "$OWN"
  g 0 "tools: Write em .claude/settings.json do PRÓPRIO clone passa" Write file_path "$OWN/.claude/settings.json"
  g 0 "tools: Write em ~/.claude/projects passa" Write file_path "$HOME/.claude/projects/x.jsonl"
  g 0 "tools: Read de arquivo do outro clone passa" Read file_path "$OTH/f.txt"
  g 0 "tools: ferramenta desconhecida passa" WebFetch url "http://x"
}
g_cond() {  # gate da fatia 6a (tentativa 3): a variável em que o guarda DECIDE (cwd modelado) tem de ser a mesma em que o shell AGE. cd que pode não ter rodado
  # (depois de ||, atrás de then/else/do, em pipeline/background, ou depois de && sem a cadeia seguir) deixa o diretório "não sei" → escrita bloqueia; e `<<EOF`
  # entre aspas é texto: não engole as linhas seguintes. Cada forma tem o caso que bloqueia E o controle que segue liberado.
  b 2 "cond: cd <alheio> 2>/dev/null || cd <próprio>; git commit (o repro do revisor: o shell fica no alheio)" "cd $OTH 2>/dev/null || cd $OWN; git commit --allow-empty -m probe"
  b 2 "cond: cd <alheio> && true || cd <próprio>; git commit" "cd $OTH && true || cd $OWN; git commit -m x"
  b 2 "cond: if true; then cd <alheio>; else cd <próprio>; fi; git commit" "if true; then cd $OTH; else cd $OWN; fi; git commit -m x"
  b 2 "cond: if false; then cd <próprio>; else cd <alheio>; fi; git commit" "if false; then cd $OWN; else cd $OTH; fi; git commit -m x"
  b 2 "cond: true && cd <alheio>; git commit (a cadeia && não segue até o git)" "true && cd $OTH; git commit -m x"
  b 2 "cond: cd <alheio> & git commit (background)" "cd $OTH & git commit -m x"
  b 2 "cond: cd <alheio> | cat; git commit (pipeline)" "cd $OTH | cat; git commit -m x"
  b 2 "cond: cd <próprio> || cd <alheio>; git commit (não sei onde estou → bloqueia)" "cd $OWN || cd $OTH; git commit -m x"
  b 2 "cond: cd <alheio> || true; git commit" "cd $OTH || true; git commit -m x"
  b 2 "cond: cd <próprio> || true; git commit, com cwd no alheio (se o cd falhar, o git roda no alheio)" "cd $OWN || true; git commit -m x" "$OTH"
  b 0 "cond: if true; then cd <próprio>; git commit; fi (o cd vale dentro do próprio ramo)" "if true; then cd $OWN/sub; git commit -m x; fi"
  b 2 "cond: if true; then cd <alheio>; git commit; fi (idem, no alheio: bloqueia)" "if true; then cd $OTH; git commit -m x; fi"
  b 2 "cond: if true; then cd <próprio>; fi; git commit, com cwd no alheio (depois do fi não sei o ramo)" "if true; then cd $OWN; fi; git commit -m x" "$OTH"
  # gate-fix 5: o cd que não é o 1º da cadeia vale SÓ enquanto a cadeia && continua até o git; case, função (nunca chamada) e grupo em background também não contam
  b 2 "cond: cd <alheio>; false && cd <próprio> && true; git commit (repro do revisor: a cadeia acabou no ;)" "cd $OTH; false && cd $OWN && true; git commit --allow-empty -m INTRUDER"
  b 2 "cond: [ -d x ] && cd <próprio> && git status; git commit, com cwd no alheio" "[ -d /tmp ] && cd $OWN && git status >/dev/null; git commit -m x" "$OTH"
  b 2 "cond: case x in x) cd <próprio>;; esac; git commit, com cwd no alheio" "case x in x) cd $OWN;; esac; git commit -m x" "$OTH"
  # O cd de UM ramo do case não vale no ramo seguinte (a contagem de blocos só zera o diretório no esac, então o ramo b ainda veria o cd do ramo a): sem o `case)`/`;;` do cd, estes passam.
  b 2 "cond: case x in a) cd <próprio> ;; b) git commit ;; esac, com cwd no alheio (o cd do ramo a não vale no b)" "case x in a) cd $OWN ;; b) git commit -m x ;; esac" "$OTH"
  b 2 "cond: o mesmo case em várias linhas, com cwd no alheio" "case x in"$'\n'"a) cd $OWN ;;"$'\n'"b) git commit -m x ;;"$'\n'"esac" "$OTH"
  b 2 "cond: false && { cd <próprio> && true; }; git commit, com cwd no alheio" "false && { cd $OWN && true; }; git commit -m x" "$OTH"
  b 2 "cond: { cd <próprio>; } & git commit, com cwd no alheio (grupo em background)" "{ cd $OWN; } & git commit -m x" "$OTH"
  b 2 "cond: f() { cd <próprio>; }; git commit, com cwd no alheio (função nunca chamada)" "f() { cd $OWN; }; git commit -m x" "$OTH"
  b 0 "cond: cd <próprio> && true; git commit (o cd é o 1º da cadeia: rodou com certeza)" "cd $OWN/sub && true; git commit -m x"
  b 0 "cond: { cd <próprio>; }; git commit (grupo em linha, não em background)" "{ cd $OWN/sub; }; git commit -m x"
  b 0 "cond: case x in x) git -C <alheio> log;; esac; git commit (leitura no case, commit no próprio)" "case x in x) git -C $OTH log;; esac; git commit -m x"
  b 0 "cond: f() { git log; }; git commit (função sem cd)" "f() { git log; }; git commit -m x"
  b 0 "cond: diff <(git -C <alheio> log) /dev/null; git commit (<( ) não é definição de função)" "diff <(git -C $OTH log) /dev/null; git commit -m x"
  # gate-fix 6: o que o shell executa não some — opener de heredoc em comentário ou em $(( )), delimitador com '-'/'.', heredoc sem terminador; git em corpo de função roda no cwd da CHAMADA; cd para diretório que não existe FALHA
  b 2 "cond: '# <<EOF' é comentário, a linha seguinte roda" "echo hi # <<EOF
git -C $OTH commit -m x
EOF"
  b 2 "cond: 'cat /dev/null # <<EOF' — leitor de dados, mas o <<EOF é comentário: a linha seguinte roda" "cat /dev/null # <<EOF
git -C $OTH commit -m x
EOF"
  b 2 "cond: <<EOF dentro de \$(( )) não abre heredoc" "echo \$((1<<2))
git -C $OTH commit -m x
EOF"
  b 2 "cond: delimitador END-OF-FILE: o heredoc acaba em END-OF-FILE, não em END" "cat <<END-OF-FILE
x
END-OF-FILE
git -C $OTH commit -m x
END"
  b 2 "cond: delimitador EOF.txt idem" "cat <<EOF.txt
x
EOF.txt
git -C $OTH commit -m x
EOF"
  b 2 "cond: heredoc sem terminador: nada some" "cat <<EOF
git -C $OTH commit -m x"
  b 0 "cond: heredoc de verdade com delimitador END-OF-FILE: o corpo some" "cat <<END-OF-FILE
git -C $OTH commit -m x
END-OF-FILE"
  b 0 "cond: <<- com terminador indentado por tab" "cat <<-EOF
git -C $OTH commit -m x
	EOF"
  b 2 "cond: f() { git commit; }; cd <alheio>; f (o corpo roda no cwd da chamada)" "f() { git commit -m x; }; cd $OTH; f"
  b 2 "cond: f() { git commit; }; cd <alheio>; time f (a função atrás de um embrulho: o ramo depois do descasque)" "f() { git commit -m x; }; cd $OTH; time f"
  b 2 "cond: function f { git commit; }; (cd <alheio>; f)" "function f { git commit -m x; }; (cd $OTH; f)"
  b 2 "cond: cd <próprio>/nao-existe; git commit, com cwd no alheio (o cd falha, o shell fica no alheio)" "cd $OWN/nao-existe; git commit -m x" "$OTH"
  b 2 "cond: cd <próprio>/arquivo (não é diretório); git commit, com cwd no alheio" "cd $OWN/.git; git commit -m x" "$OTH"
  b 2 "cond: while cd <alheio>; do git commit; done" "while cd $OTH; do git commit -m x; done"
  b 2 "cond: cd <alheio> || exit 1; git commit (|| exit mantém o diretório: bloqueia)" "cd $OTH || exit 1; git commit -m x"
  b 2 "cond: true && cd <alheio> && git commit (cadeia && mantém: bloqueia)" "true && cd $OTH && git commit -m x"
  b 2 "cond: cd <alheio>; git commit (sequencial: controle, continua bloqueando)" "cd $OTH; git commit -m x"
  b 0 "cond: cd <próprio> || exit 1; git commit (|| exit mantém: libera)" "cd $OWN/sub || exit 1; git commit -m x"
  b 0 "cond: cd <próprio> || return; git commit (|| return mantém: libera)" "cd $OWN/sub || return; git commit -m x"
  b 0 "cond: mkdir -p && cd <próprio> && git init (cadeia && mantém: libera)" "mkdir -p $OWN/sub && cd $OWN/sub && git init"
  b 0 "cond: cd <próprio>; git commit (sequencial: controle, continua liberado)" "cd $OWN/sub; git commit -m x"
  b 0 "cond: cd <alheio> || cd <próprio>; git log (leitura segue liberada)" "cd $OTH || cd $OWN; git log"
  b 0 "cond: (cd <alheio> && git log); git commit (subshell volta: controle)" "(cd $OTH && git log); git commit -m x"
  b 2 "cond: <<EOF entre aspas não engole as linhas seguintes (o repro do revisor)" "git commit -m \"doc: cat <<EOF\"
git -C $OTH commit --allow-empty -m x
EOF"
  b 2 "cond: <<EOF escapado (\\<<EOF) idem" "echo \\<<EOF
git -C $OTH commit -m x
EOF"
  b 0 "cond: controle — sem o <<EOF entre aspas, o mesmo texto no próprio passa" "git commit -m \"doc: cat\"
git commit -m x
EOF"
  b 0 "cond: <<EOF entre aspas E um heredoc de verdade depois: só o de verdade some (corpo cita o alheio)" "echo \"<<EOF\"
cat <<EOF
git -C $OTH commit -m x
EOF
git commit -m x"
  mkdir -p "$TERR/r/wt/nogit"
  b 2 "cond/msg: (preparo) projeto no território sem .git" "git commit -m x" "$OWN" "$TERR/r/wt/nogit"
  grep -qF "não tem .git" "$T/err"; ok $? "cond/msg: projeto no território sem .git até a raiz: a mensagem diz isso (não 'fora do território')"
  b 2 "cond/msg: (preparo) projeto fora do território" "git commit -m x" "$OWN" "$OUT"
  grep -qF "fora do território" "$T/err"; ok $? "cond/msg: projeto fora do território: a mensagem diz 'fora do território'"
}
g_ctx() {  # gate da fatia 6a (tentativa 7, ga-37bwre): o trecho aninhado ($( ), crase, bash -c, eval, env -S) começa com o contexto de fora — variáveis e
  # funções desta chamada —, nunca do zero; função cujo fim não acho roda; heredoc só some para leitor de DADOS conhecido; falha do guarda num Bash bloqueia
  b 2 "ctx: GIT_DIR=<alheio> bash -c 'git commit'" "GIT_DIR=$OTH/.git bash -c 'git commit -m x'"
  b 2 "ctx: GIT_WORK_TREE=<alheio> sh -c 'git add .'" "GIT_WORK_TREE=$OTH sh -c 'git add .'"
  b 2 "ctx: env GIT_DIR=<alheio> bash -c 'git commit'" "env GIT_DIR=$OTH/.git bash -c 'git commit -m x'"
  b 2 "ctx: GIT_DIR=<alheio> eval git commit" "GIT_DIR=$OTH/.git eval git commit -m x"
  b 2 "ctx: export GIT_DIR=<alheio>; eval 'git commit'" "export GIT_DIR=$OTH/.git; eval 'git commit -m x'"
  b 2 "ctx: export GIT_DIR=<alheio>; echo \$(git commit)" "export GIT_DIR=$OTH/.git; echo \$(git commit -m x)"
  b 2 "ctx: GIT_DIR=<alheio>; echo crase git commit" "GIT_DIR=$OTH/.git; echo \`git commit -m x\`"
  b 2 "ctx: GIT_DIR=<alheio> env -S 'git commit'" "GIT_DIR=$OTH/.git env -S 'git commit -m x'"
  b 2 "ctx: f() { git -C <alheio> commit; }; echo \$(f)" "f() { git -C $OTH commit; }; echo \$(f)"
  b 2 "ctx: f() { git -C <alheio> commit; }; eval f" "f() { git -C $OTH commit; }; eval f"
  b 2 "ctx: f() { git -C <alheio> commit; }; export -f f; bash -c f" "f() { git -C $OTH commit; }; export -f f; bash -c f"
  b 2 "ctx: f() { … '{' …; git -C <alheio> commit; }; f (o fim da função não fecha)" "f() { :; echo '{'; git -C $OTH commit; }; f"
  b 2 "ctx: idem com newlines" "f() {
:
echo '{'
git -C $OTH commit
}
f"
  b 2 "ctx: sh<<EOF (sem espaço)" "sh<<EOF
git -C $OTH commit -m x
EOF"
  b 2 "ctx: bash<<'EOF'" "bash<<'EOF'
git -C $OTH commit -m x
EOF"
  b 2 "ctx: <<EOF bash (redirecionamento primeiro)" "<<EOF bash
git -C $OTH commit -m x
EOF"
  b 2 "ctx: 0<<EOF sh" "0<<EOF sh
git -C $OTH commit -m x
EOF"
  b 2 "ctx: 2>/dev/null sh <<EOF" "2>/dev/null sh <<EOF
git -C $OTH commit -m x
EOF"
  b 2 "ctx: python3 <<EOF (leitor que não está em DATA: o corpo é conferido)" "python3 <<EOF
git -C $OTH commit -m x
EOF"
  b 2 "ctx: \$'\\UFFFFFFFF' + glob + g''it, cwd fora do território (o guarda não pode cair)" "echo \$'\\UFFFFFFFF'; cd g?*/r/wt/other && g''it commit -m x" "$HOME/gt-remote"
  run "$OWN" < <(printf '{"tool_name":"Bash","cwd":"%s","tool_input":["g%sit commit"]}' "$HOME" "''")
  [ "$RC" = 2 ]; ok $? "ctx: Bash cujo tool_input não é objeto e não cita 'git': o guarda cai e BLOQUEIA (rc=$RC)"
  b 0 "ctx: controle — \$'\\UFFFFFFFF'; git commit no próprio (o escape não derruba o guarda)" "echo \$'\\UFFFFFFFF'; git commit -m x"
  b 0 "ctx: controle — \"cat\" <<'EOF' cita o alheio (leitor entre aspas segue sendo dado)" "\"cat\" <<'EOF'
git -C $OTH commit -m x
EOF"
  b 0 "ctx: controle — cat<<'EOF' (colado) cita o alheio: segue sendo dado" "cat<<'EOF'
git -C $OTH commit -m x
EOF"
  b 0 "ctx: controle — 2>/dev/null cat <<'EOF' cita o alheio: segue sendo dado" "2>/dev/null cat <<'EOF'
git -C $OTH commit -m x
EOF"
  b 0 "ctx: controle — export FOO=1; bash -c 'git commit' no próprio" "export FOO=1; bash -c 'git commit -m x'"
  b 0 "ctx: controle — GIT_DIR=<próprio> bash -c 'git commit'" "GIT_DIR=$OWN/.git bash -c 'git commit -m x'"
  b 0 "ctx: controle — f() { git log; }; eval f; git commit" "f() { git -C $OTH log; }; eval f; git commit -m x"
  b 0 "ctx: controle — f() { … '{' …; git commit; }; f no próprio, cwd absoluto" "f() { :; echo '{'; git -C $OWN commit; }; f"
  # gate-fix 8 (gate ga-36d3ic, fuzzer diferencial do revisor): aspa de COMENTÁRIO não pareia; $( )/crase só no nível que o shell expande; atribuição
  # que pode não ter rodado = "não sei"; cd atrás de lançador externo não muda o shell
  b 2 "ctx: '# Don't forget' + git -C <alheio> commit -m 'msg' (a aspa do comentário engolia o git)" "# Don't forget
git -C $OTH commit -m 'msg'"
  b 2 "ctx: '# say \"hi' + git -C <alheio> commit -m \"x\" (gêmea com aspa dupla)" "# say \"hi
git -C $OTH commit -m \"x\""
  b 2 "ctx: comentário terminando em \\ não junta a linha seguinte" "git status # trailing \\
git -C $OTH commit -m x"
  b 2 "ctx: bash -c \"x=\\\$(git -C \\\"../other\\\" commit)\" (o \$( ) escapado roda no bash de dentro)" "bash -c \"x=\\\$(git -C \\\"../other\\\" commit -m y)\""
  b 2 "ctx: eval \"echo \\\$(git -C \\\"../other\\\" commit)\"" "eval \"echo \\\$(git -C \\\"../other\\\" commit -m m)\""
  b 2 "ctx: bash -c 'x=\$(git -C '\"'\"'../other'\"'\"' commit)' (o \$( ) entre aspas simples roda no bash de dentro)" "bash -c 'x=\$(git -C '\"'\"'../other'\"'\"' commit -m y)'"
  b 2 "ctx: eval \"echo \\\`git -C <alheio> commit\\\`\" (crase escapada em aspas duplas)" "eval \"echo \\\`git -C $OTH commit -m x\\\`\""
  b 2 "ctx: \$(case a in a) git --git-dir=<alheio> commit;; esac) (o ) do case não fecha o \$( ))" "echo \$(case a in a) git --git-dir=$OTH/.git commit -m x;; esac)"
  b 2 "ctx: export GIT_DIR=<alheio>; true || export GIT_DIR=<próprio>; git commit" "export GIT_DIR=$OTH/.git; true || export GIT_DIR=$OWN/.git; git commit -m x"
  b 2 "ctx: GIT_DIR=<alheio>; false && GIT_DIR=<próprio>; export GIT_DIR; git commit" "GIT_DIR=$OTH/.git; false && GIT_DIR=$OWN/.git; export GIT_DIR; git commit -m x"
  b 2 "ctx: cd <alheio>; env cd <próprio>; git commit (env roda o cd como programa)" "cd $OTH; env cd $OWN; git commit -m x"
  b 2 "ctx: cd <alheio>; find <próprio> -exec cd <próprio> \; ; git commit (o cd do find é programa: o shell fica no alheio)" "cd $OTH; find $OWN -maxdepth 0 -exec cd $OWN \; ; git commit -m x"
  b 2 "ctx: cd <alheio>; find <próprio> -exec cd <próprio> ; git commit (o ; do shell corta o find: ele falha e o cd não roda)" "cd $OTH; find $OWN -maxdepth 0 -exec cd $OWN ; git commit -m x"
  b 0 "ctx: controle — '# it's fine' + git commit -m 'msg' no próprio" "# it's fine
git commit -m 'msg'"
  b 0 "ctx: controle — git commit -m \"custa \\\$5\" no próprio" "git commit -m \"custa \\\$5\""
  b 0 "ctx: controle — git commit -m 'a # b' (# entre aspas não é comentário)" "git commit -m 'a # b'"
  b 0 "ctx: controle — export GIT_DIR=<próprio>; git commit (atribuição certa)" "export GIT_DIR=$OWN/.git; git commit -m x"
}

g_interp() {  # ga-tphd15o (achado do ga-nkfwixz, cc-safety-net como oráculo): o texto que um INTERPRETADOR (python/node/perl/awk) ou um pipe entrega a um shell roda — as 12 formas que só o safety-net pegava
  # As strings com os.system / shell=True abaixo são PAYLOADS DE TESTE de propósito: viram só o texto de um pedido que o guarda confere, nada aqui as executa.
  local c g="git -C $OTH reset --hard" h="git -C $OWN commit -m x" B R v6 v7
  B=$(python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "$g"); R=$(python3 -c 'import sys; print(sys.argv[1][::-1])' "$g")
  if grp interpc interp; then
  for c in "python3 -c \"import os; os.system('$g')\"" "python3 -c \"import subprocess; subprocess.run('$g', shell=True)\"" "node -e \"require('child_process').execSync('$g')\"" \
           "perl -e 'system(\"$g\")'" "perl -e '\`$g\`'" "awk 'BEGIN{system(\"$g\")}'" "python3 -c \"import os; os.popen('$g')\"" "python3 -c \"import subprocess; subprocess.check_output('$g', shell=True)\"" \
           "python3 -I -c \"import os; os.system('git -C ../other reset --hard')\"" "python3.12 -c \"import os; os.system('$g')\"" "node -e \"require('child_process').exec('$g')\"" "perl -e 'system \"$g\"'" \
           "perl -e 'exec(\"$g\")'" "ruby -e 'system(\"$g\")'" "gawk 'BEGIN{\"$g\" | getline}'" "sudo -n python3 -c \"import os; os.system('$g')\"" "bash -c \"python3 -c \\\"import os; os.system('$g')\\\"\"" \
           "python3 -c \"import os; os.chdir('$OTH'); os.system('git commit -m x')\"" "node -e \"require('child_process').execSync('git commit -m x', {cwd: '$OTH'})\"" "perl -e 'qx{$g}'" "perl -e 'system(qq{$g})'" "ruby -e '%x($g)'" "ruby -e '%x{$g}'" \
           "node -e \"require('child_process').execSync('git commit -m x', {'cwd': '$OTH'})\"" "python3 -c \"import subprocess; subprocess.run('git commit -m x', shell=True, **{'cwd': '$OTH'})\"" \
           "python3 -c \"import os; os.environ['GIT_DIR'] = '$OTH/.git'; os.system('git commit -m x')\"" "node -e \"require('child_process').execSync('git commit -m x', {env: {GIT_DIR: '$OTH/.git'}})\"" \
           "python3 -c \"import subprocess; subprocess.run('git add .', shell=True, env={'GIT_WORK_TREE': '$OTH'})\"" \
           "python3 -c \"import json; print(json.dumps({'cwd': '$OWN', 'command': 'git checkout --detach abc'}))\"" \
           "python3 -c \"import os; os.system('\\x67it -C $OTH reset --hard')\"" "node -e \"require('child_process').execSync('\\x67it -C $OTH reset --hard')\"" \
           "awk -v cmd='$g' 'BEGIN{system(cmd)}'" "python3 -c \"import os,sys; os.system(sys.argv[1])\" '$g'"; do
    b 2 "interp: o texto entre aspas do código roda num shell: $c" "$c"
  done
  for c in "python3 -c \"import os; os.system('git -C $OWN commit -m x')\"" "python3 -c \"import os; os.system('git commit -m x')\"" "python3 -c \"import os; os.system('git -C $OTH log')\"" \
           "python3 -c \"print('use git -C $OTH commit to write')\"" "python3 -c \"import json,sys; print(json.load(sys.stdin))\"" "awk '{print \$1}'" "perl -pe 's/a b/c d/'" "node -e \"console.log(1+1)\"" \
           "perl -e 'system(\"git -C $OWN commit -m x\")'" "awk 'BEGIN{system(\"git status\")}'" "python3 -c \"import os; os.chdir('$OWN'); os.system('git -C $OWN commit -m x')\"" "python3 $T/tool.py --msg ok" "perl -e 'qx{git -C $OWN commit -m x}'" "python3 -c \"DIGIT_N = 1; import os; os.system('git commit -m x')\""; do
    b 0 "pass: interp: código de interpretador que não escreve no alheio: $c" "$c"
  done
  # interpretadores que o parecer do gate (ga-tphd15o, tentativa 1) apontou fora da lista, e os delimitadores do perl além de q{} q() q[] q//
  for c in "php -r 'system(\"$g\");'" "php8.2 -r 'shell_exec(\"$g\");'" "lua -e 'os.execute(\"$g\")'" "lua5.4 -e 'io.popen(\"$g\")'" "deno eval \"new Deno.Command('sh', {args: ['-c', '$g']}).outputSync()\"" "bun -e \"require('child_process').execSync('$g')\"" \
           "perl -e 'system(q!$g!)'" "perl -e 'system(q#$g#)'" "perl -e 'system(qq|$g|)'" "perl -e 'qx,$g,'"; do
    b 2 "interp: php/lua/deno/bun e q!…! do perl rodam o texto num shell: $c" "$c"
  done
  for c in "php -r 'echo 1;'" "lua -e 'print(1)'" "bun -e \"console.log(1)\"" "deno eval \"console.log(1)\"" "php -r 'system(\"git -C $OWN commit -m x\");'" "perl -e 'system(q!git -C $OWN commit -m x!)'"; do
    b 0 "pass: interp: php/lua/deno/bun/perl que não escrevem no alheio: $c" "$c"
  done
  # Gate ga-tphd15o, tentativa 2: q<…>/qq<…>/qx<…> do perl, %x<…>/%Q{…}/%q<…> do ruby e [[…]]/[=[…]=] do lua passavam como "nada a conferir" (o guarda dizia ler "qualquer delimitador").
  # Cada forma que o guarda lê tem um caso que bloqueia; as que ele NÃO lê estão no runbook ("Continua sem ver"), nunca num comentário que prometa mais.
  for c in "perl -e 'system(q<$g>)'" "perl -e 'system(qq<$g>)'" "perl -e 'qx<$g>'" "ruby -e '%x<$g>'" "ruby -e 'system(%Q{$g})'" "ruby -e 'system(%Q<$g>)'" "ruby -e 'system(%q<$g>)'" \
           "ruby -e 'system(%Q[$g])'" "ruby -e 'system(%q($g))'" "perl -e 'system(q <$g>)'" "lua -e 'os.execute([[$g]])'" "lua -e 'os.execute([=[$g]=])'" "lua -e 'os.execute([==[$g]==])'" \
           "lua -e 'io.popen([[echo hi]]); os.execute([[$g]])'" "perl -e 'print q<hi>; system(q<$g>)'"; do
    b 2 "interp: <…> do perl/ruby, %Q/%q do ruby e [[…]] do lua são literais lidos: $c" "$c"
  done
  for c in "perl -e 'system(q<git -C $OWN commit -m x>)'" "perl -e 'qx<git status>'" "ruby -e 'system(%Q{git -C $OWN commit -m x})'" "ruby -e 'system(%q<git -C $OTH log>)'" "lua -e 'os.execute([[git -C $OWN commit -m x]])'" \
           "lua -e 'print([[git -C $OTH log]])'" "lua -e 'os.execute([=[git -C $OWN commit -m x]=])'" "perl -e 'print q<hi>'" "ruby -e 'puts %Q{hi}'" "lua -e 'print([[hi]])'"; do
    b 0 "pass: interp: <…>, %Q/%q e [[…]] que não escrevem no alheio: $c" "$c"
  done
  fi
  if grp interpp interp; then
  for c in "echo '$g' | sh" "printf '%s\\n' '$g' | bash -s" "echo $g | sh" "echo \"$g\" | bash" "printf 'cd %s && git reset --hard\\n' $OTH | sh" "printf '%s\\n' 'cd $OTH' 'git reset --hard' | bash" \
           "echo -e 'cd $OTH\\ngit reset --hard' | sh" "printf -- '%s\\n' '$g' | sh" "LC_ALL=C command echo '$g' | sh" "echo '$g' | sudo -n bash -s" "echo '$g' |& sh" "true && echo '$g' | sh -x" "echo '$g' | zsh" "echo 'git -C ../other reset --hard' | sh" "echo '$g' | cat | sh" "echo '$g' | tee $T/o | sh" "echo '$g' | cat -u | bash -s" "cat <<< '$g' | sh" "cat <<< \"$g\" | bash -s" "rev <<< '$R' | sh" "c='$g'; cat <<< \"\$c\" | sh" \
           "f() { echo '$g' | sh; }; f" "case x in x) echo '$g' | sh;; esac" "( echo '$g' | sh )" "x=\$(echo '$g' | sh)" "if true; then echo '$g' | sh; fi"; do
    b 2 "interp: o texto que um pipe entrega a um shell roda: $c" "$c"
  done
  for c in "echo '$g' | cat" "echo '$g' | wc -l" "echo '$g' > $T/out" "printf '%s\\n' '$g' | tee $T/out" "echo 'git -C $OWN commit -m x' | sh" "echo '$g' | sh -c 'cat'" "echo 'git -C $OTH log' | sh" \
           "echo hello | sh" "echo '$g' | bash -c 'git -C $OWN log'" "echo 'git commit -m x' | sh" "echo '$g' | cat $T/f | sh" "f() { echo 'git -C $OWN commit -m x' | sh; }; f" "cat <<< '$g' | cat" "cat <<< 'git -C $OWN commit -m x' | sh"; do
    b 0 "pass: interp: pipe que não entrega o texto a um shell, ou texto que não escreve no alheio: $c" "$c"
  done
  fi
  if grp interpe interp; then
  for c in "eval \"\$(echo $B | base64 -d)\"" "echo $B | base64 -d | sh" "eval \"\$(echo '$R' | rev)\"" "printf -v c '%s' '$g'; eval \"\$c\"" "eval \$(echo $B | base64 --decode)" "echo $B | base64 -D | bash" \
           "echo '$R' | rev | sh" "base64 -d <<< $B | sh" "eval \$(echo '$R' | rev)" "printf -v c '%s' '$g'; eval \$c" "printf -v c '%s' '$g'; eval \"\${c}\"" "false || printf -v c '%s' '$g'; eval \"\$c\"" \
           "printf -v c 'git -C %s reset --hard' $OTH; eval \"\$c\"" "c='$g'; eval \"\$c\"" "export c='$g'; eval \$c" \
           "c='$g'; echo \"\$c\" | sh" "c='$g'; printf '%s\\n' \"\$c\" | bash -s" "b=$B; echo \$b | base64 -d | sh" "echo \"\$(echo $B | base64 -d)\" | sh" "c='$g'; eval \"\$(echo \"\$c\")\""; do
    b 2 "interp: texto codificado ou guardado em variável que o eval ou o shell roda: $c" "$c"
  done
  for c in "echo $B | base64 -d" "echo $B | base64 -d > $T/out" "eval \"\$(echo $B | base64 -d | wc -c)\"" "eval \"\$(echo $B | base64 -d > $T/out)\"" "echo '$R' | rev" "printf -v c '%s' '$g'; echo \"\$c\"" "printf -v c '%s' 'git -C $OWN commit -m x'; eval \"\$c\"" \
           "eval \"\$(echo hello)\"" "eval \"\$(ssh-agent -s)\"" "eval \"\$(echo '$g' | wc -c)\"" "printf -v c '%s' hello; eval \"\$c\"" "eval \"\$d\"" "c='git -C $OWN log'; eval \"\$c\"" "printf -v c '%s' '$g'; c=ok; eval \"\$c\"" "c='git -C $OWN commit -m x'; echo \"\$c\" | sh" "echo \"\$d\" | sh" "c='$g'; echo \"\$c\" | cat"; do
    b 0 "pass: interp: codificado ou em variável, mas que não vira escrita no alheio: $c" "$c"
  done
  # Trecho que PODE não ter rodado (gate ga-tphd15o, tentativa 1): o texto de antes continua possível E o novo também — o eval e o pipe conferem todos. Erro e vazio não dão o mesmo valor:
  # um valor inofensivo que talvez não tenha sido gravado não apaga o nocivo que talvez continue lá, e um nocivo que talvez tenha sido gravado conta.
  for c in "printf -v c '%s' '$g'; [ -f /nonexistent ] && printf -v c '%s' ok; eval \"\$c\"" "c='$g'; [ -f /nonexistent ] && printf -v c '%s' ok; eval \"\$c\"" "c='$g'; [ -f /nonexistent ] && c=ok; eval \"\$c\"" \
           "c=ok; [ -d / ] && c='$g'; eval \"\$c\"" "if [ -d / ]; then c='$g'; fi; eval \"\$c\"" "[ -d / ] && c='$g'; eval \"\$c\"" "false || c='$g'; eval \"\$c\"" "false || export c='$g'; eval \"\$c\"" \
           "for i in 1; do c='$g'; done; eval \"\$c\"" "while false; do c='$g'; done; eval \"\$c\"" "case x in y) c='$g';; esac; eval \"\$c\"" "[ -d / ] && c='$g'; echo \"\$c\" | sh" \
           "c='$g'; f() { c=ok; }; [ -f /nonexistent ] && f; eval \"\$c\"" "c='$g'; f() { c=ok; }; [ -f /nonexistent ] && command f; eval \"\$c\"" "a='git -C'; [ -d / ] && a=ok; eval \"\$a\" '$OTH' reset --hard" \
           "printf -v GIT_DIR '%s' $OTH/.git; [ -f /nonexistent ] && printf -v GIT_DIR '%s' $OWN/.git; git commit -m x"; do
    b 2 "interp: o texto de antes ou o novo — o trecho pode não ter rodado: $c" "$c"
  done
  # Os MESMOS blocos em VÁRIAS linhas (gate ga-tphd15o, tentativa 2): a atribuição sozinha numa linha dentro de if/for/while/until/case/else também pode não ter rodado; só a forma de
  # uma linha estava coberta (o `then`/`do` do trecho a marcava), e a de várias linhas apagava o texto nocivo de antes. O mesmo vale para o cd e o GIT_DIR dentro do bloco.
  local nl=$'\n'
  for c in "c='$g'${nl}if [ -f /nonexistent ]; then${nl}c=ok${nl}fi${nl}eval \"\$c\"" "c='$g'${nl}for i in 1; do${nl}c=ok${nl}done${nl}eval \"\$c\"" \
           "c='$g'${nl}while false; do${nl}c=ok${nl}done${nl}eval \"\$c\"" "c='$g'${nl}until true; do${nl}c=ok${nl}done${nl}eval \"\$c\"" \
           "c='$g'${nl}if [ -f /nonexistent ]; then${nl}c=a${nl}else${nl}c=b${nl}fi${nl}eval \"\$c\"" "c='$g'${nl}if [ -d / ]; then${nl}if [ -f /nonexistent ]; then${nl}c=ok${nl}fi${nl}fi${nl}eval \"\$c\"" \
           "c='$g'${nl}case x in${nl}y) c=ok ;;${nl}esac${nl}eval \"\$c\"" "c='$g'${nl}if [ -f /nonexistent ]; then${nl}printf -v c '%s' ok${nl}fi${nl}eval \"\$c\"" \
           "c='$g'${nl}if [ -f /nonexistent ]; then${nl}export c=ok${nl}fi${nl}echo \"\$c\" | sh" "c='$g'${nl}if [ -d / ]; then if [ -f /nonexistent ]; then${nl}true${nl}fi${nl}c=ok${nl}fi${nl}eval \"\$c\"" \
           "c='$g'${nl}if [ -f /nonexistent ]; then${nl}  c=ok${nl}fi${nl}echo \"\$c\" | sh" "export GIT_DIR=$OTH/.git${nl}if [ -f /nonexistent ]; then${nl}export GIT_DIR=$OWN/.git${nl}fi${nl}git commit -m x" \
           "GIT_DIR=$OTH/.git${nl}for i in 1; do${nl}GIT_DIR=$OWN/.git${nl}done${nl}git commit -m x" "cd $OTH${nl}if [ -f /nonexistent ]; then${nl}cd $OWN${nl}fi${nl}git commit -m x" \
           "cd $OTH${nl}for i in 1; do${nl}cd $OWN${nl}done${nl}git commit -m x" "cd $OTH${nl}while false; do${nl}cd $OWN${nl}done${nl}git commit -m x" \
           "c='$g'${nl}if [ -d / ]; then${nl}case x in${nl}y) true ;;${nl}esac${nl}c=ok${nl}fi${nl}eval \"\$c\""; do
    b 2 "interp: bloco em várias linhas — a atribuição ou o cd dentro dele pode não ter rodado: $c" "$c"
  done
  # Controles: depois do fi/done/esac a atribuição que SEI que rodou volta a apagar o texto de antes (a profundidade do bloco desce); dentro do bloco o cd vale até o fi.
  for c in "c='$h'${nl}if [ -f /nonexistent ]; then${nl}c=ok${nl}fi${nl}eval \"\$c\"" "if [ -d / ]; then${nl}c=ok${nl}fi${nl}eval \"\$c\"" \
           "c='$g'${nl}if [ -d / ]; then${nl}true${nl}fi${nl}c=ok${nl}eval \"\$c\"" "c='$g'${nl}for i in 1; do${nl}true${nl}done${nl}c=ok${nl}eval \"\$c\"" \
           "c='$g'${nl}case x in${nl}y) true ;;${nl}esac${nl}c=ok${nl}eval \"\$c\"" "c='$g'${nl}if [ -d / ]; then if [ -f /nonexistent ]; then${nl}true${nl}fi${nl}fi${nl}c=ok${nl}eval \"\$c\"" \
           "cd $OWN${nl}if [ -f /nonexistent ]; then${nl}git commit -m x${nl}fi" "cd $OTH${nl}if [ -d / ]; then${nl}cd $OWN${nl}git commit -m x${nl}fi" \
           "export GIT_DIR=$OTH/.git${nl}if [ -d / ]; then${nl}true${nl}fi${nl}export GIT_DIR=$OWN/.git${nl}git commit -m x"; do
    b 0 "pass: interp: bloco em várias linhas que não escreve no alheio, e o texto atribuído DEPOIS do bloco vence: $c" "$c"
  done
  # Uma abertura atrás de then/do/else (`then if x; then`) também abre bloco: sem contá-la, o 1º fi zera a profundidade com o bloco de fora ainda aberto.
  b 2 "interp: if aninhado atrás do then, na mesma linha — o fi de dentro não fecha o de fora" "c='$g'${nl}if [ -d / ]; then if [ -f /nonexistent ]; then${nl}true${nl}fi${nl}c=ok${nl}fi${nl}eval \"\$c\""
  # O texto passa de variável para variável, vem de $( ) guardado, de %b, do prefixo do comando, ou de dentro de um shell aninhado.
  for c in "c=\$(echo '$g'); eval \"\$c\"" "c=\$(echo '$g'); echo \"\$c\" | sh" "c='$g'; d=\$c; eval \"\$d\"" "c='$g'; d=\"\$c\"; eval \"\$d\"" \
           "printf '%b' 'cd $OTH\\ngit reset --hard' | sh" "printf '%b\\n' 'cd $OTH\\ngit reset --hard' | sh" "c='$g'; c=ok eval \"\$c\"" "c=ok; c='$g' eval '\$c'" \
           "export c='$g'; bash -c 'eval \"\$c\"'" "c='$g' bash -c 'eval \"\$c\"'" "export d='$g'; export c=\$d; eval \"\$c\"" "export c=\$(echo '$g'); eval \"\$c\""; do
    b 2 "interp: o texto vem de outra variável, de \$( ) guardado, de %b, do prefixo do comando ou de um shell aninhado: $c" "$c"
  done
  # O ( ) roda num subshell: o que ele atribui não vale fora (o texto de antes continua; GIT_DIR de antes continua).
  for c in "c='$g'; ( c=ok ); eval \"\$c\"" "GIT_DIR=$OTH/.git; ( GIT_DIR=$OWN/.git ); git commit -m x"; do
    b 2 "interp: o subshell não desfaz o que veio antes: $c" "$c"
  done
  # O `)` que fecha um PADRÃO de case, dentro de um ( ), não fecha o subshell: o diretório, o GIT_DIR e o texto de antes do case continuam valendo até o `)` de verdade.
  for c in "( cd $OTH; case x in y) git commit -m x ;; x) git commit -m y ;; esac )" "( cd $OTH; case x in y) true ;; esac; git commit -m x )" \
           "( GIT_DIR=$OTH/.git; case x in y) true ;; esac; git commit -m x )" "( c='$g'; case x in y) true ;; esac; eval \"\$c\" )" \
           "( c='$g'; case x in y) c=ok ;; esac; eval \"\$c\" )" "( cd $OTH; case x in y) case z in w) true ;; esac ;; esac; git commit -m x )" \
           "( cd $OTH; case x in (y) true ;; esac; git commit -m x )" "( cd $OTH; case x in y) ( true ) ;; esac; git commit -m x )" \
           "( cd $OTH; if case x in y) true ;; esac; then git commit -m x; fi )" "( cd $OTH; while case x in y) false ;; esac; do git commit -m x; done )" \
           "( cd $OTH; case x in y) true ;; esac ); cd $OTH; git commit -m x" "( cd $OTH; case x in"$'\n'" y) true ;; esac; git commit -m x )"; do
    b 2 "interp: o ) de um padrão de case não fecha o subshell: $c" "$c"
  done
  for c in "( cd $OTH; case x in y) true ;; esac ); git commit -m x" "( c='$g'; case x in y) true ;; esac ); eval \"\$c\"" "( cd $OWN; case x in y) true ;; esac; git commit -m x )"; do
    b 0 "pass: interp: o ) que fecha o subshell depois do case volta o diretório e as variáveis: $c" "$c"
  done
  # Variantes demais para conferir uma a uma (7 variáveis de 2 textos = 128): bloqueia, nunca libera por não ter conferido.
  v6="a=1; [ -d / ] && a=2; b=1; [ -d / ] && b=2; c=1; [ -d / ] && c=2; d=1; [ -d / ] && d=2; e=1; [ -d / ] && e=2; f=1; [ -d / ] && f=2;"
  v7="$v6 g=1; [ -d / ] && g=2;"
  b 2 "interp: 128 variantes de um eval passam do teto: bloqueia" "$v7 eval \"\$a\" \"\$b\" \"\$c\" \"\$d\" \"\$e\" \"\$f\" \"\$g\""
  grep -qF "variáveis demais" "$T/err"; ok $? "interp: o bloqueio por variantes demais diz o motivo (não 'o guarda falhou')"
  b 0 "pass: interp: 64 variantes de um eval (6 variáveis de 2 textos) ainda são conferidas e nenhuma escreve no alheio" "$v6 eval \"\$a\" \"\$b\" \"\$c\" \"\$d\" \"\$e\" \"\$f\""
  for c in "c='$h'; [ -f /nonexistent ] && c=ok; eval \"\$c\"" "c='$h'; if [ -d / ]; then c=ok; fi; eval \"\$c\"" "if [ -d / ]; then c=ok; fi; eval \"\$c\"" \
           "c=ok; [ -f /nonexistent ] && c='$g'; c=ok; eval \"\$c\"" "( c='$g' ); eval \"\$c\"" "( c='$h'; eval \"\$c\" )" "( export GIT_DIR=$OWN/.git; git commit -m x )" \
           "printf '%b' 'cd $OWN\\ngit commit -m x' | sh" "c='$g'; c=ok; [ -f /nonexistent ] && c=ok2; eval \"\$c\"" "printf -v GIT_DIR '%s' $OTH/.git; printf -v GIT_DIR '%s' $OWN/.git; git commit -m x" \
           "c=\$(echo '$h'); eval \"\$c\"" "c='$h'; d=\$c; eval \"\$d\"" "c='$g'; f() { c=ok; }; f; eval \"\$c\"" "c=ok eval \"\$c\"" "c='$g'; c=ok; c2=\$c; eval \"\$c2\"" \
           "export c='$h'; bash -c 'eval \"\$c\"'" "printf -v c '%s' '$g'; [ -f /nonexistent ] && printf -v c '%s' ok; echo \"\$c\" | cat"; do
    b 0 "pass: interp: trecho que pode não ter rodado, subshell, variável de variável, mas nada escreve no alheio: $c" "$c"
  done
  fi
}
g_fuzz() {  # fuzzer diferencial (gate ga-36d3ic, sugestão do revisor): o bash REAL com um git falso que registra onde escreveria é a verdade; o guarda
  # tem de bloquear toda escrita no alheio. Semente fixa (reproduzível). RCG_FUZZ_N muda o tamanho (padrão 200).
  cat > "$T/fuzz.py" <<'FUZZEOF'
#!/usr/bin/env python3
"""Fuzzer diferencial do remote-clone-guard: o bash REAL (com um git falso que registra onde escreveria) é a verdade;
o guarda tem de bloquear (rc 2) todo comando em que o bash escreveria no clone ALHEIO. Uso: rcg_fuzz.py GUARDA [N] [SEED]."""
import json, os, random, shlex, shutil, subprocess, sys, tempfile

GUARD = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 400
rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 7)
READ = {"log", "status", "diff", "show", "rev-parse"}

t = os.path.realpath(tempfile.mkdtemp(prefix="rcgfz."))
terr = t + "/terr"; own = terr + "/r/wt/own"; oth = terr + "/r/wt/other"; shim = t + "/bin"; log = t + "/git.log"
for d in (own, oth, shim, t + "/home"):
    os.makedirs(d)
for d in (own, oth):
    open(d + "/.git", "w").close()
with open(shim + "/git", "w") as f:  # o git falso: resolve o alvo como o git faria (-C em sequência, --git-dir/--work-tree, GIT_DIR/GIT_WORK_TREE) e registra
    f.write(f"""#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]; cwd = os.getcwd(); gd = os.environ.get("GIT_DIR"); wt = os.environ.get("GIT_WORK_TREE")
while a and a[0].startswith("-"):
    x = a.pop(0)
    if x == "-C" and a: cwd = os.path.join(cwd, a.pop(0))
    elif x.startswith("--git-dir"): gd = x.split("=", 1)[1] if "=" in x else a.pop(0)
    elif x.startswith("--work-tree"): wt = x.split("=", 1)[1] if "=" in x else a.pop(0)
    elif x == "-c" and a: a.pop(0)
sub = a[0] if a else ""
tgt = os.path.dirname(os.path.join(cwd, gd)) if gd else (os.path.join(cwd, wt) if wt else cwd)
open({log!r}, "a").write(sub + "\\t" + os.path.realpath(tgt) + "\\n")
""")
os.chmod(shim + "/git", 0o755)


def q(s):  # um estilo de aspas ao acaso para entregar o texto a um shell
    k = rnd.randrange(3)
    if k == 0:
        return shlex.quote(s)
    if k == 1:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'
    return "$'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"


def core(tgt):
    p = rnd.choice([tgt, "../" + os.path.basename(tgt)])
    pq = rnd.choice([p, "'" + p + "'", '"' + p + '"'])
    m = rnd.choice(["-m x", "-m 'msg'", '-m "m s g"', "-m \"it's\""])
    op = rnd.choice([f"commit {m}", "push origin HEAD", "reset --hard", "add ."])
    return rnd.choice([f"git -C {pq} {op}", f"git --git-dir={p}/.git {op}", f"GIT_DIR={p}/.git git {op}", f"cd {pq} && git {op}", f"cd {pq}; git {op}"])


def wrap(c, depth):
    for _ in range(depth):
        k = rnd.randrange(10)
        c = [lambda: f"bash -c {q(c)}", lambda: f"sh -c {q(c)}", lambda: f"eval {q(c)}", lambda: f"x=$({c})", lambda: f"echo `{c}`",
             lambda: f'echo "$({c})"', lambda: f"env {c}", lambda: f"command {c}", lambda: f"case a in a) {c};; esac",
             lambda: f"timeout 5 {c}"][k]()
    return c


def prefix():
    return rnd.choice(["", "# Don't forget\n", '# say "hi\n', "# trailing \\\n", "git status # it's\n", "true && ", "echo ok; ",
                       "# a 'b' c\n", "cat <<EOF\nit's data\nEOF\n"])


def case(tgt):
    k = rnd.randrange(10)
    if k == 6:
        w = rnd.choice(["env cd", "timeout 5 cd", "command cd", "nohup cd"])
        return f"cd {oth}; {w} {own}; git commit -m x", oth
    if k == 7:
        return f"cd {oth}; find {own} -maxdepth 0 -exec cd {{}} \\; ; git commit -m x", oth
    if k == 8:
        return f"echo $(case a in a) {core(tgt)};; esac)", tgt
    if k == 9:
        return rnd.choice([f"if true; then export GIT_DIR={tgt}/.git; fi; git commit -m x", f"export GIT_DIR={oth}/.git; false && export GIT_DIR={own}/.git; git commit -m x"]), tgt
    if k == 0:
        return f"export GIT_DIR={oth}/.git; true || export GIT_DIR={own}/.git; git commit -m x", oth
    if k == 1:
        return f"bash <<EOF\n{core(tgt)}\nEOF", tgt
    return prefix() + wrap(core(tgt), rnd.randrange(3)), tgt


def bash_truth(cmd):
    open(log, "w").close()
    env = {"PATH": shim + ":/usr/bin:/bin", "HOME": t + "/home"}
    try:
        subprocess.run(["bash", "-c", cmd], cwd=own, env=env, capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        pass
    hits = [l.split("\t") for l in open(log).read().splitlines() if "\t" in l]
    return any(s not in READ and (p == oth or p.startswith(oth + "/")) for s, p in hits)


def guard_rc(cmd):
    inp = json.dumps({"tool_name": "Bash", "cwd": own, "tool_input": {"command": cmd}})
    r = subprocess.run(["python3", "-I", GUARD], input=inp, text=True, capture_output=True,
                       env={**os.environ, "RCG_ROOT": terr, "CLAUDE_PROJECT_DIR": own})
    return r.returncode


if guard_rc(f"git -C {own} commit -m x") != 0 or guard_rc(f"git -C {oth} commit -m x") != 2:  # o guarda tem de RODAR: arquivo ausente/erro sai 2 e contaria como "bloqueou"
    print("fuzz: o guarda não passou no controle (próprio=0, alheio=2) — nada medido"); sys.exit(2)
bypass, fp, wrote, fps = [], 0, 0, []
for i in range(N):
    tgt = rnd.choice([oth, oth, own])
    cmd, _ = case(tgt)
    truth = bash_truth(cmd)
    rc = guard_rc(cmd)
    if truth:
        wrote += 1
        if rc != 2:
            bypass.append(cmd)
    elif rc == 2 and tgt == own:
        fp += 1
        fps.append(cmd)
print(f"fuzz: {N} comandos, {wrote} escreveriam no alheio (bash real), BYPASS={len(bypass)}, bloqueio no próprio={fp}")
for c in bypass[:12]:
    print("BYPASS:", repr(c.replace(t, "T"))[:220])
for c in fps[:int(os.environ.get("FZ_FP", "0"))]:
    print("FP:", repr(c.replace(t, "T"))[:200])
shutil.rmtree(t, ignore_errors=True)
sys.exit(1 if bypass else 0)
FUZZEOF
  local out; out=$(TMPDIR="$T" python3 -I "$T/fuzz.py" "$P" "${RCG_FUZZ_N:-200}" 7 2>&1); local rc=$?
  echo "$out" | head -6
  [ "$rc" = 0 ]; ok $? "fuzz: nenhum bypass do guarda contra o bash real (${RCG_FUZZ_N:-200} comandos, semente 7)"
}

g_msg() {
  b 2 "msg: (preparo)" "git -C $OTH commit -m x"
  has() { grep -qF -- "$1" "$T/err"; }
  has "$OTH" && has "$OWN" && has "NÃO É CANCELAMENTO DO USUÁRIO" && has "git commit" && has "Leitura continua liberada" && has "worker/<bead>"; ok $? "msg: diz alvo, clone próprio, 'não é cancelamento', a operação, que leitura segue liberada e como publicar"
  b 2 "msg: (preparo 2)" 'git -C "$X" commit'; has "não consegui resolver"; ok $? "msg: alvo não resolvido diz que não conseguiu resolver"
  b 0 "msg: (preparo 3)" "git -C $OTH log"; [ ! -s "$T/err" ]; ok $? "msg: leitura liberada não escreve nada em stderr"
  g 2 "msg: (preparo 4)" Write file_path "$OTH/f"; has "escrita de arquivo (Write)"; ok $? "msg: Write diz que é escrita de arquivo"
}
settings() {  # settings ARQUIVO MATCHERS...  (um grupo por matcher, todos chamando o guarda $P com `|| exit 2`)
  local f="$1" m cmd="python3 -I $P || exit 2"; shift
  python3 - "$f" "$cmd" "$@" <<'EOF'
import json, sys
f, cmd, ms = sys.argv[1], sys.argv[2], sys.argv[3:]
json.dump({"hooks": {"PreToolUse": [{"matcher": m, "hooks": [{"type": "command", "command": cmd}]} for m in ms]}}, open(f, "w"))
EOF
}
g_check() {
  local s="$T/s.json"
  python3 -I "$P" --selfcheck >"$T/o" 2>"$T/err"; ok $? "check: sem settings, só os casos internos (rc=$?)"
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; ok $? "check: settings bom (matchers Bash + Edit|Write|MultiEdit|NotebookEdit)"
  settings "$s" "*"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; ok $? "check: matcher '*' cobre tudo"
  settings "$s" "Bash|Edit|Write|MultiEdit|NotebookEdit"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; ok $? "check: um matcher só com todas as ferramentas"
  local bad
  for bad in "Bash" "Edit|Write|MultiEdit|NotebookEdit" "Bash|Edit|Write|MultiEdit"; do
    settings "$s" "$bad"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: matchers '$bad' deixam ferramenta sem guarda → falha"
  done
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; sed -i.bak 's/ || exit 2//' "$s"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: sem '|| exit 2' (falha aberta) → falha"
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; sed -i.bak "s#$P#/outro/guarda.py#" "$s"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: o hook chama outro arquivo → falha"
  local fake  # o hook só vale se o comando INTEIRO é `python3 -I <este arquivo> || exit 2`: citar o arquivo em outro lugar do comando não conta
  for fake in "echo $P || exit 2" "python3 -I /outro/guarda.py # $P || exit 2" "python3 -I /outro/guarda.py; python3 -I $P || exit 2" "python3 -I $P; true || exit 2" "python3 $P || exit 2" "python3 -I $P || exit 2; true || exit 2"; do
    settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; python3 - "$s" "$fake" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["hooks"]["PreToolUse"]:
    g["hooks"][0]["command"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
EOF
    python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: hook que só cita o arquivo (\`$fake\`) → falha"
  done
  local mod  # o comando CERTO mas com um campo que muda QUANDO o hook dispara (o cross-clone-block do mini tinha "if": "Bash(git -C *)"): conferir só o `command` deixaria passar (gate ga-iczduy, rodada 2)
  for mod in 'h["if"] = "Bash(git -C *)"' 'h["async"] = True' 'del h["type"]' 'h["type"] = "prompt"' 'g["if"] = "Bash(git -C *)"'; do
    settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; python3 - "$s" "$mod" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["hooks"]["PreToolUse"]:
    h = g["hooks"][0]
    exec(sys.argv[2])
json.dump(d, open(sys.argv[1], "w"))
EOF
    python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: hook com o comando certo e \`$mod\` → falha"
  done
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; python3 - "$s" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["hooks"]["PreToolUse"]:
    g["hooks"][0]["timeout"] = 5
json.dump(d, open(sys.argv[1], "w"))
EOF
  python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; ok $? "check: \`timeout\` no hook é só prazo, não muda quando dispara → ok"
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d["disableAllHooks"]=True;json.dump(d,open(sys.argv[1],"w"))' "$s"
  python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: disableAllHooks ligado → falha"
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; local pd="$T/proj" cl; mkdir -p "$pd/.claude"
  chk() { python3 -I "$P" --selfcheck "$s" "$pd" >"$T/o" 2>"$T/err"; }
  chk; ok $? "check: pasta do projeto sem settings (camada ausente) → ok"
  for cl in settings.json settings.local.json; do
    echo '{"disableAllHooks": true}' > "$pd/.claude/$cl"; chk; [ $? = 1 ]; ok $? "check: projeto/$cl liga disableAllHooks → falha"
    echo '{"permissions": {}}' > "$pd/.claude/$cl"; chk; ok $? "check: projeto/$cl sem disableAllHooks → ok"
    echo 'lixo' > "$pd/.claude/$cl"; chk; [ $? = 1 ]; ok $? "check: projeto/$cl ilegível → falha (não sei ≠ ok)"; rm -f "$pd/.claude/$cl"
  done
  echo '{}' > "$s"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: settings sem hooks → falha"
  echo 'não é json' > "$s"; python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: settings ilegível → falha"
  python3 -I "$P" --selfcheck "$T/nao-existe.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: settings ausente → falha"
}
g_hook() {  # o comando que vai no settings do servidor
  local js; js=$(mk Bash "$OWN" command "git -C $OTH commit -m x"); local c
  c="python3 -I $P || exit 2"
  CLAUDE_PROJECT_DIR="$OWN" sh -c "$c" <<<"$js" >/dev/null 2>&1; [ $? = 2 ]; ok $? "hook: bloqueia com 2"
  CLAUDE_PROJECT_DIR="$OWN" sh -c "$c" <<<"$(mk Bash "$OWN" command 'git log')" >/dev/null 2>&1; [ $? = 0 ]; ok $? "hook: libera com 0"
  printf 'import sys\nsys.exit(1)\n' > "$T/trava.py"; c="python3 -I $T/trava.py || exit 2"
  sh -c "$c" <<<"$js" >/dev/null 2>&1; [ $? = 2 ]; ok $? "hook: guarda que sai 1 vira 2 (sem o '|| exit 2' o hook falharia ABERTO)"
  sh -c "python3 -I $T/trava.py" <<<"$js" >/dev/null 2>&1; [ $? = 1 ]; ok $? "hook: (controle) sem o '|| exit 2' o mesmo guarda sai 1, que o Claude trata como erro NÃO bloqueante"
  printf 'def (:\n' > "$T/sintaxe.py"; c="python3 -I $T/sintaxe.py || exit 2"
  sh -c "$c" <<<"$js" >/dev/null 2>&1; [ $? = 2 ]; ok $? "hook: erro de sintaxe no guarda vira 2"
  c="python3 -I $T/nao-existe.py || exit 2"; sh -c "$c" <<<"$js" >/dev/null 2>&1; [ $? = 2 ]; ok $? "hook: guarda ausente vira 2"
  c="python3-que-nao-existe -I $P || exit 2"; sh -c "$c" <<<"$js" >/dev/null 2>&1; [ $? = 2 ]; ok $? "hook: python ausente (127) vira 2"
}

g_budget() {  # ga-tih62nv: o pedido que fazia o guarda girar SEM FIM (e que o hook deixava seguir sem conferência quando o prazo de 600 s do Claude Code estourava) termina; o que passa do teto de passos ou de tempo é BLOQUEADO, nunca liberado
  local rp="$T/repro.txt" hn="$T/budget.py" capy="$T/cap.py" r
  has() { grep -qF -- "$1" "$T/err"; }
  calls() {  # calls K: K funções f1..fK, cada uma chama todas as outras, e a chamada de f1 (os passos crescem como K!: K=5 são ~300, K=8 são ~96 mil)
    local k=$1 i j body out=""
    for ((i = 1; i <= k; i++)); do
      body=""
      for ((j = 1; j <= k; j++)); do [ "$j" = "$i" ] || body="$body f$j;"; done
      out="$out f$i() {$body }; "
    done
    echo "${out}f1"
  }
  nested() {  # nested K: f() com K definições aninhadas `function gN { :; }` e a chamada de f (registrar cada uma copia o resto da lista: ~K²/2 entradas)
    local k=$1 i out="f() { :;"
    for ((i = 1; i <= k; i++)); do out="$out function g$i { :; };"; done
    echo "$out }; f"
  }
  # o pedido de 4 linhas / 438 caracteres do runbook (seção "Custo de tempo" da ga-tphd15o): definição de função + $((…)) + ${V#*/} + case numa linha, dentro do texto de um python
  cat > "$rp" <<'EOF'
     """    mn=$((mn+1)); [ $((mn % ${GCSSH_SHARD#*/})) = "${GCSSH_SHARD%/*}" ] || return  # GCSSH_SHARD=K/N: só o mutante de ordem ≡ K (mod N); a ordem conta TODOS, de qualquer grupo
    [ -z "${GCSSH_MUTANTS_ONLY:-}" ] || case ",$1," in *",$GCSSH_MUTANTS_ONLY,"*) ;; *) return;; esac""")
sub1("""  mutant() {  # mutant GRUPOS DESCRIÇÃO SED-EXPR""", """  mn=0; : "${GCSSH_SHARD:=0/1}"
  mutant() {  # mutant GRUPOS DESCRIÇÃO SED-EXPR""")
EOF
  cat > "$capy" <<'PYEOF'
import subprocess, sys
# cap.py SEGUNDOS SCRIPT [ARGS…]: roda `python3 -I SCRIPT ARGS…` com prazo; estourou → mata e sai 124 (o `timeout` do coreutils não está no PATH do mini)
try:
    sys.exit(subprocess.run([sys.executable, "-I"] + sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PYEOF
  cat > "$hn" <<'PYEOF'
import importlib.util, io, signal, sys, time
# budget.py GUARDA MODO: roda o main() do GUARDA com o relógio em 0.3 s e imprime `rc= dt= timer= analisar=` (timer = o relógio que sobrou armado; analisar = a recusa de tempo saiu no stderr)
spec = importlib.util.spec_from_file_location("rcg", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
g.TIME_LIMIT = 0.3
sys.stdin = io.StringIO('{"tool_name": "Bash", "cwd": "/", "tool_input": {"command": "echo oi"}}')
if sys.argv[2] == "busy":  # o julgamento que nunca volta
    def busy(*a):
        while True:
            pass
    g.decide = busy
elif sys.argv[2] == "stdin":  # o pedido nunca termina de chegar
    class Hang(io.StringIO):
        def read(self, *a):
            time.sleep(30)
            return ""
    sys.stdin = Hang()
elif sys.argv[2] == "twice":  # decide() zera o contador a cada pedido: dois pedidos de ~300 passos com teto de 500 não estouram
    g.STEP_LIMIT = 500
    cmd = "; ".join("echo a%d" % i for i in range(300))
    for _ in range(2):
        g.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": "/"}, "/x", None)
    print("rc=0 reset=ok")
    sys.exit(0)
err = io.StringIO()
sys.stderr = err
t = time.perf_counter()
rc = g.main(["x"])
sys.stderr = sys.__stderr__
print("rc=%d dt=%.1f timer=%g analisar=%d" % (rc, time.perf_counter() - t, signal.getitimer(signal.ITIMER_REAL)[0], "não consegui analisar este pedido a tempo" in err.getvalue()))
PYEOF
  tb() {  # tb QUERO DESCRIÇÃO COMANDO — como b, mas com prazo de 20 s: o guarda de antes NÃO termina neste pedido, e o caso tem que REPROVAR (rc 124), não pendurar o selftest
    (cd "$OWN" && CLAUDE_PROJECT_DIR="$OWN" python3 -I "$capy" 20 "$P" >"$T/o" 2>"$T/err" < <(mk Bash "$OWN" command "$3")); RC=$?
    [ "$RC" = "$1" ]; ok $? "$2 (rc=$RC, queria $1)"
  }
  tb 0 "budget: o pedido de 438 caracteres do runbook (função + conta + case numa linha) termina e libera" "$(cat "$rp")"
  tb 2 "budget: o mesmo pedido com um git -C <alheio> commit no fim é BLOQUEADO (terminar não custa o veredito)" "$(cat "$rp")"$'\n'"git -C $OTH commit -m x"
  has "$OTH" && ! has "a tempo"; ok $? "budget: ...e a recusa é a de sempre (diz o alvo alheio), não a de tempo"
  tb 0 "budget: o mesmo pedido seguido de cd <próprio> && git commit libera (o diretório volta a ser conhecido depois da chamada)" "$(cat "$rp")"$'\n'"cd $OWN && git commit -m x"
  tb 2 "budget: 8 funções que chamam todas as outras (~96 mil passos) passam do teto e são BLOQUEADAS, não liberadas" "$(calls 8)"
  has "NÃO É CANCELAMENTO DO USUÁRIO" && has "não consegui analisar este pedido a tempo" && has "passos de conferência" && has "um comando por chamada"; ok $? "budget: ...a recusa diz que é política automática, que faltou tempo/passos e como reescrever"
  tb 0 "budget: controle — 5 funções que chamam todas as outras (~300 passos) passam" "$(calls 5)"
  tb 2 "budget: 400 definições aninhadas num corpo só (~80 mil entradas copiadas ao registrar) estouram o teto: a cópia entra na conta" "$(nested 400)"
  tb 0 "budget: controle — 20 definições aninhadas no mesmo corpo passam" "$(nested 20)"
  # parecer de segurança dos commits anteriores: a definição ANINHADA num corpo reexecutado (function g {, g() {) NÃO roda; o que o corpo dela faz (cd, variável) não pode valer para o que vem depois
  b 2 "budget: f() { function g { cd <próprio>; }; }; cd <alheio>; f; git commit — o cd de g NÃO rodou, o commit escreve no alheio" "f() { function g { cd $OWN; }; }; cd $OTH; f; git commit -m x"
  b 2 "budget: ...a mesma aninhada na forma g() { cd <próprio>; }" "f() { g() { cd $OWN; }; }; cd $OTH; f; git commit -m x"
  b 2 "budget: ...e o git DENTRO de f, depois da definição aninhada, também" "f() { :; function g { cd $OWN; }; git commit -m x; }; cd $OTH; f"
  b 2 "budget: ...e um \$( ) depois da aninhada (o diretório que ele vê é o \"não sei\", não o do cd de g)" "f() { :; function g { cd $OWN; }; echo \$(git commit -m x); }; cd $OTH; f"
  b 2 "budget: ...e a variável: export GIT_DIR=<próprio> dentro da aninhada não vale (GIT_DIR=<alheio> de fora)" "f() { function g { export GIT_DIR=$OWN/.git; }; }; export GIT_DIR=$OTH/.git; f; git commit -m x"
  b 0 "budget: controle — um grupo { cd <próprio>; } no começo do corpo de f RODA: o git seguinte escreve no próprio" "f() { { cd $OWN; }; git commit -m x; }; cd $OTH; f"
  b 2 "budget: texto de python (foo(a, b)) num heredoc deixava a bandeira de definição velha: o grupo { } seguinte, com um git no alheio, era engolido sem conferir" "python3 - <<'EOF'
foo(a, b)
EOF
{ git -C $OTH commit -m x; }"
  b 2 "budget: ...e a cabeça g() aninhada, g() { k() { cd <alheio>; }; k; g() { :; }; }; g; { git commit; } (o guarda de antes nem termina nele)" "g() { k() { cd $OTH; }; k; g() { :; }; }; g; { git commit -m x; }"
  b 2 "budget: ...a definição que pode não ter rodado (true || function f { cd <próprio>; }): o cd de f não vale" "cd $OTH; true || function f { cd $OWN; }; f; git commit -m x"
  b 2 "budget: ...a região perdida sobrevive a uma chamada feita dentro dela (depois do h, o cd ainda é o do corpo que não roda)" "f() { :; function g { :; h; cd $OWN; }; git commit -m x; }; h() { :; }; cd $OTH; f"
  b 2 "budget: f() { g() { git commit; }; }; f; cd <alheio>; g — a aninhada passa a existir quando f roda, e a chamada dela de fora é conferida" "f() { g() { git commit -m x; }; }; f; cd $OTH; g"
  b 2 "budget: ...o mesmo com function g {" "f() { function g { git commit -m x; }; }; f; cd $OTH; g"
  b 0 "budget: uma função que se redefine (function f { dentro de f) não gira nem estoura o teto" "f() { :; function f { :; }; :; }; f"
  b 0 "budget: controle — f() { { cd <próprio>; }; :; }; cd <alheio>; f; git commit — o grupo do começo do corpo RODA, o cd vale" "f() { { cd $OWN; }; :; }; cd $OTH; f; git commit -m x"
  b 0 "budget: controle — com uma bandeira de definição velha (foo(); no meio), o grupo { } do corpo de f NÃO reabre a definição: o cd e o git do próprio seguem certos" "f() { :; { :; }; }; foo(); f; cd $OWN && git commit -m x"
  b 2 "budget: f cuja chave não fecha (aspa tardia) com function g { } e um git no alheio: o corpo reexecutado no fim é CONFERIDO, não engolido por g" "f() { :; echo '{'; function g { :; }; git -C $OTH commit -m x; }; f"
  b 2 "budget: controle — a função aninhada CHAMADA que escreve no alheio é bloqueada" "f() { function g { git -C $OTH commit -m x; }; g; }; f"
  # parecer do gate na tentativa 1: registrar a aninhada SEM CONDIÇÃO, com o ramo "chamada de função" antes do ramo git, deixava uma função chamada git pular o git_hit.
  # Uma função chamada git NUNCA isenta a chamada: pode não existir (a definição não rodou) e command git / env git / \git a ignoram.
  b 2 "budget: f() { false && function git { :; }; }; f; git -C <alheio> commit — a definição NUNCA rodou, o git de verdade escreve no alheio" "f() { false && function git { :; }; }; f; git -C $OTH commit -m x"
  b 2 "budget: ...a definição dentro de um subshell ( function git { :; } ) não vale fora dele" "f() { ( function git { :; } ); }; f; git -C $OTH commit -m x"
  b 2 "budget: ...a chamada de f que pode não rodar (false && f)" "f() { function git { :; }; }; false && f; git -C $OTH commit -m x"
  b 2 "budget: ...a git DEFINIDA de verdade também não isenta a chamada (lado fechado, falso positivo assumido: command git e env git a ignoram)" "f() { :; function git { :; }; }; f; git -C $OTH commit -m x"
  b 2 "budget: ...sem a camada f (false && function git { :; })" "false && function git { :; }; git -C $OTH commit -m x"
  b 2 "budget: ...f chamada dentro de \$( )" "f() { function git { :; }; }; echo \$(f); git -C $OTH commit -m x"
  b 2 "budget: ...a forma g() { de uma aninhada chamada git" "f() { git() { :; }; }; f; git -C $OTH commit -m x"
  b 2 "budget: git() { :; }; git -C <alheio> commit — a função git do topo não isenta a chamada" "git() { :; }; git -C $OTH commit -m x"
  b 2 "budget: ...git() { :; }; command git -C <alheio> commit (command ignora a função)" "git() { :; }; command git -C $OTH commit -m x"
  b 2 "budget: ...env git" "git() { :; }; env git -C $OTH commit -m x"
  b 2 "budget: ...\\git" "git() { :; }; \\git -C $OTH commit -m x"
  b 2 "budget: ...e o cwd alheio" "git() { :; }; cd $OTH; git commit -m x"
  b 0 "budget: controle — git() que só faz echo e uma LEITURA no alheio: libera (o git de verdade só lê)" "git() { echo hi; }; git -C $OTH log"
  b 0 "budget: controle — ...e a escrita no PRÓPRIO clone" "git() { echo hi; }; git -C $OWN commit -m x"
  # `g()` + quebra de linha + `{`: o separador é o `;` do newline, não o `)`; num corpo reexecutado o `{` é o corpo da aninhada (não roda agora)
  b 2 "budget: f() { :; g()⏎{ cd <próprio>; }; }; cd <alheio>; f; git commit — g só foi DEFINIDA, o commit escreve no alheio" "f() { :; g()"$'\n'"{ cd $OWN; }; }; cd $OTH; f; git commit -m x"
  b 2 "budget: ...com espaço (g ()⏎{)" "f() { :; g ()"$'\n'"{ cd $OWN; }; }; cd $OTH; f; git commit -m x"
  b 2 "budget: ...e na forma function g ()⏎{" "f() { :; function g ()"$'\n'"{ cd $OWN; }; }; cd $OTH; f; git commit -m x"
  b 0 "budget: controle — texto de python (foo(a, b)) num heredoc no corpo de f e um grupo { cd <próprio>; } depois: o grupo RODA (a cabeça não deixa bandeira velha)" "f() { python3 - <<'EOF'"$'\n'"foo(a, b)"$'\n'"EOF"$'\n'"{ cd $OWN; }; git commit -m x; }; cd $OTH; f"
  b 0 "budget: controle — uma cabeça foo (a) solta e depois um grupo { cd <próprio>; } que RODA" "f() { echo \$(foo (a)); { cd $OWN; }; }; cd $OTH; f; git commit -m x"
  # function g() no topo: g só foi definida, o cd de dentro não rodou
  b 2 "budget: cd <alheio>; function g() { cd <próprio>; }; git commit — a definição não roda o corpo" "cd $OTH; function g() { cd $OWN; }; git commit -m x"
  b 2 "budget: ...com espaço (function g ())" "cd $OTH; function g () { cd $OWN; }; git commit -m x"
  b 2 "budget: ...function g()⏎{" "cd $OTH; function g()"$'\n'"{ cd $OWN; }; git commit -m x"
  b 0 "budget: controle — function g() chamada: o cd RODA e o commit é no próprio" "cd $OTH; function g() { cd $OWN; }; g; git commit -m x"
  # custo: a MESMA aninhada reexecutada não se registra de novo (o corpo registrado traz o próprio cabeçalho: a lista dobrava a cada chamada)
  tb 0 "budget: f() { function g { :; }; g; }; f; g; g; g; g; g; g; g — 7 chamadas de uma aninhada não estouram o teto (falso positivo da tentativa 1)" "f() { function g { :; }; g; }; f; g; g; g; g; g; g; g"
  tb 0 "budget: ...f chamada duas vezes" "f() { function g { :; }; g; }; f; f; g; g"
  tb 2 "budget: controle — 7 chamadas da aninhada que escreve no alheio ainda bloqueiam" "f() { function g { git -C $OTH commit -m x; }; }; f; g; g; g; g; g; g; g"
  b 2 "budget: controle — duas aninhadas de nomes diferentes: cada uma registrada, a segunda escreve no alheio" "f() { function g { :; }; function k { git -C $OTH commit -m x; }; }; f; k"
  b 2 "budget: controle — a MESMA aninhada g definida por duas funções, a segunda escreve: o registro da segunda não pode ser pulado só porque o nome já foi registrado" "f() { function g { :; }; }; h() { function g { git commit -m x; }; }; f; h; cd $OTH; g"
  # a CLASSE do parecer: uma função com nome de comando que o guarda trata ANTES do ramo de função (bash, env, cd, find, eval, export, sudo, ssh…) é chamada como FUNÇÃO pelo shell, e o
  # corpo nunca era reexecutado (o guarda de antes também liberava). `git` era só o caso que o gate citou.
  local nm
  for nm in bash sh eval find env sudo xargs command time ssh flock exec nohup; do
    b 2 "budget: $nm() { <escreve no alheio>; }; $nm — a função tem o nome de um comando que o guarda trata antes: o corpo RODA" "$nm() { git -C $OTH commit -m x; }; $nm"
  done
  b 2 "budget: cd() { <escreve no alheio>; }; cd /tmp" "cd() { git -C $OTH commit -m x; }; cd /tmp"
  b 2 "budget: export() { <escreve no alheio>; }; export X=1" "export() { git -C $OTH commit -m x; }; export X=1"
  b 0 "budget: controle — bash() que só faz echo: libera" "bash() { echo hi; }; bash"
  b 0 "budget: controle — env() que só faz echo: libera" "env() { echo hi; }; env"
  b 2 "budget: cd <alheio>; cd() { :; }; cd <próprio>; git commit — o cd é a FUNÇÃO e o diretório não mudou: o commit escreve no alheio" "cd $OTH; cd() { :; }; cd $OWN; git commit -m x"
  b 2 "budget: export GIT_DIR=<alheio>; export() { :; }; export GIT_DIR=<próprio>; git commit — o export é a FUNÇÃO e a variável não mudou" "export GIT_DIR=$OTH/.git; export() { :; }; export GIT_DIR=$OWN/.git; git commit -m x"
  b 2 "budget: f() { git -C <alheio> commit; }; time f — a função atrás de um embrulho (time) ainda é conferida" "f() { git -C $OTH commit -m x; }; time f"
  r=$(python3 -I "$capy" 10 "$hn" "$P" busy 2>&1); echo "$r" | grep -qF "rc=2 " && echo "$r" | grep -qF "timer=0 " && echo "$r" | grep -qF "analisar=1"; ok $? "budget: o julgamento que gira sem fim é cortado pelo relógio (0.3 s no teste): sai 2, diz que não deu tempo e o relógio fica desarmado [$r]"
  r=$(python3 -I "$capy" 10 "$hn" "$P" stdin 2>&1); echo "$r" | grep -qF "rc=2 " && echo "$r" | grep -qF "analisar=1"; ok $? "budget: o relógio já está armado quando o guarda lê o stdin: pedido que nunca termina de chegar é BLOQUEADO [$r]"
  r=$(python3 -I "$capy" 10 "$hn" "$P" ok 2>&1); echo "$r" | grep -qF "rc=0 " && echo "$r" | grep -qF "timer=0 "; ok $? "budget: pedido comum libera e deixa o relógio desarmado [$r]"
  r=$(python3 -I "$capy" 10 "$hn" "$P" twice 2>&1); echo "$r" | grep -qF "reset=ok"; ok $? "budget: decide() zera o contador de passos a cada pedido [$r]"
}

all() { group block && g_block; group pass && g_pass; group evade && g_evade; group closed && g_closed; group shell && g_shell; group wrap && g_wrap; g_lex; g_dest; group cfg && g_cfg; group tools && g_tools; group msg && g_msg; group cond && g_cond; group ctx && g_ctx; g_interp; group fuzz && g_fuzz
        group check && g_check; group hook && g_hook; group budget && g_budget; return 0; }

if [ -n "${RCG_MUTANT:-}" ]; then all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
all
echo "== $((n-fails))/$n ok =="

[ -n "${RCG_NO_MUTANTS:-}" ] || [ -n "${RCG_ONLY:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer o grupo que a cobre falhar"
  mutant() {  # mutant GRUPOS DESCRIÇÃO SED-EXPR
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; sed -e "$3" "$P" > "$m/remote-clone-guard.py"
    if cmp -s "$P" "$m/remote-clone-guard.py"; then ok 1 "mutante '$2': o sed não mudou nada (o teste do mutante está errado)"; return; fi
    local r; r=$(RCG_MUTANT=1 RCG_ONLY="$1" RCG_UNDER_TEST="$m/remote-clone-guard.py" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$2' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$2' pego ($r)";; *) ok 1 "mutante '$2': execução sem resultado ($r)";; esac
  }
  mutant block "bloqueio do alvo alheio" 's/if t is None or (inside(t, terr) and not (own and inside(t, own))):/if False:/'
  mutant closed "alvo que não resolve passa a liberar" 's/if t is None or (inside(t, terr)/if (t is not None and inside(t, terr)/'
  mutant closed "subcomando desconhecido vira leitura" 's/    if sub in READ:/    if True:/'
  mutant pass "o próprio clone deixa de ser liberado" 's/ and not (own and inside(t, own))//'
  mutant block "realpath (symlink)" 's/os.path.realpath(os.path.join(cwd or "\/", p))/os.path.abspath(os.path.join(cwd or "\/", p))/'
  mutant block "-C não é seguido" 's/cwd, i = res(seg\[i + 1\], cwd), i + 2/i += 2/'
  mutant evade "cd não muda o diretório" 's/new = None if c == "popd" else chdir(seg\[1:\], st\["cwd"\], c == "pushd")/new = st["cwd"]/'
  mutant cond "cd condicional (|| , then/else, pipeline, && sem cadeia) segue mudando o diretório" 's/            if st.get("lost") or kw or wrapped or ext or prev in ("||", "|", "|&", "case)") or term in ("|", "|&", "&", ";;") or (prev == "&&" and term != "&&"):/            if False:/'
  mutant cond "`cd a || cd b`: o trecho depois do || não vira não-sei" 's/        if st.pop("or", False) and prev == "||" and c not in ("exit", "return"):/        if False:/'
  mutant cond "<<EOF entre aspas/comentário volta a abrir heredoc (engole as linhas seguintes)" 's/        if not opener_ok(cmd, m.start()) or eol < 0:/        if eol < 0:/'
  mutant cond "'# <<EOF' deixa de ser comentário" 's/        elif c == "#" and (k == 0 or s\[k - 1\] in " \\t;&|("):/        elif False:/'
  mutant cond "corpo de função nunca é conferido na chamada" 's/        elif c in st.get("funcs", {}) and c not in st.setdefault("calling", set()):/        elif False:/'
  mutant cond "cd para diretório inexistente vale como se tivesse rodado" 's/    return p if p is None or os.path.isdir(p) else None/    return p/'
  mutant cond "a cadeia && que sustentava o cd acaba e o diretório continua valendo" 's/        if st.get("chain") and prev != "&&":/        if False:/'
  mutant cond "cd em padrão de case ou com ;; segue mudando o diretório" 's/            if st.get("lost") or kw or wrapped or ext or prev in ("||", "|", "|&", "case)") or term in ("|", "|&", "&", ";;")/            if st.get("lost") or kw or wrapped or ext or prev in ("||", "|", "|\&") or term in ("|", "|\&", "\&")/'
  mutant cond "{ cd a; } & mantém o diretório do grupo em background" 's/^\( *\)if term == "&":$/\1if False:/'
  mutant evade "bash -c não é aberto" 's/return sub(script\[0\], cwd, env)/pass/'
  mutant evade "eval não é aberto" 's/            return sub("\\n".join(" ".join(v) for v in reveal(seg\[1:\], seen(env, True))), cwd, env)/            pass/'
  mutant evade "\$( ) não é aberto" 's/r = sub(bytes.fromhex(m.group(1)).decode(), st\["cwd"\], {})/r = None/'
  mutant evade "crase não vira \$( )" 's/(cmd.startswith("\$(", k) or cmd\[k\] == "`")/cmd.startswith("$(", k)/'
  mutant evade "parêntese dentro do \$( ) não é contado" 's/            d += 1 if c == "(" else -1/            d -= 1/'
  mutant evade "\$( ) de heredoc sem aspas é ignorado" 's/("" if m.group(2) else/("" if True else/'
  mutant evade "find -exec não é aberto" 's/if t in ("-exec", "-execdir", "-ok", "-okdir"):/if False:/'
  mutant evade "command/env/sudo/xargs não são descascados" 's/elif os.path.basename(seg\[0\]) in WRAP:/elif False:/'
  mutant pass "corpo de heredoc é tratado como comando" 's/hide(CONT.sub(r"\\1", decomment(heredocs(cmd))))/hide(cmd)/'
  mutant evade "pontuação colada ); engole a próxima palavra" 's/for pc in PIECE.findall(tok):/for pc in [tok]:/'
  mutant tools "Edit/Write não são vigiados" 's/    if tool in TOOLS_FILE:/    if False:/'
  mutant closed "falha do guarda vira liberado" '/o guarda falhou/{n;s/return 2/return 0/;}'
  mutant block "bloqueio sai 0 em vez de 2" '/print(message(hit/{n;s/return 2/return 0/;}'
  mutant closed "sem projeto, o cwd vira clone próprio" 's/p = os.path.realpath(proj) if proj else ""/p = os.path.realpath(proj or os.getcwd())/'
  mutant evade "stash push com 'stash list' na mensagem vira leitura" 's/(sub == "stash" and first in ("list", "show"))/(sub == "stash")/'
  mutant closed "branch com argumento vira leitura" 's/return lists_only(sub, rest)/return True/'
  mutant closed "JSON ruim que cita git passa" 's/ and not re.search(r"git|file_path|notebook_path", raw):/:/'
  mutant check "selfcheck só confere o Bash" 's/for tool in ("Bash",) + tuple(TOOLS_FILE):/for tool in ("Bash",):/'
  mutant check "selfcheck aceita hook que chama outro arquivo" 's/re.escape(me)/r"\\S+"/'
  mutant check "selfcheck não exige '|| exit 2'" 's/\\s+\\|\\|\\s+exit\\s+2")/.*")/'
  mutant check "selfcheck ignora disableAllHooks" 's/if s.get("disableAllHooks"):/if False:/'
  mutant check "selfcheck ignora a camada do projeto" 's/for d in args\[1:\]:/for d in []:/'
  mutant evade "opção de env/sudo que muda o diretório não deixa o guarda cego" 's/^\( *\)blind = blind or name in chd$/\1pass/'
  mutant evade "export/declare não são lidos" 's/if c in ("export", "declare", "typeset"):/if False:/'
  mutant evade "VAR=x solta não vale para o git seguinte" 's/                setvar(k, texts(v, st\["may"\]), unsure, v)/                pass/'
  mutant evade "VAR=x (solta ou depois de env/sudo) é descartada" 's/env\[m.group(1)\], seg = m.group(2), seg\[1:\]/seg = seg[1:]/'
  mutant evade "env -S (comando inteiro numa palavra) não é reaberto" 's/if " " in seg\[0\]:/if False:/'
  mutant evade "remote -v add vira leitura" 's/rest in (\[\], \["-v"\]) or/rest[:1] in ([], ["-v"]) or/'
  mutant evade "--output/--lost-found em comando de leitura" 's/    if any(WRITES.match(t) for t in rest):/    if False:/'
  mutant tools "Edit/Write em ~\/.claude\/hooks e settings passam" 's/p is None or claude_conf(p) or (inside/p is None or (inside/'
  mutant check "selfcheck aceita o arquivo citado no meio do comando" 's/hook_re.fullmatch(/hook_re.search(/'
  mutant shell "palavra reservada (if/then/{/!…) esconde o git" 's/        elif seg\[0\] in KEYWORDS:/        elif False:/'
  mutant shell,cond "function NOME { git …; }" 's/        if not st.get("calling") and (seg\[:1\] == \["{"\] and st.pop("func", False) or seg\[:1\] == \["function"\] and seg\[2:3\] == \["{"\]):/        if seg[:1] == ["{"] and st.pop("func", False):/'
  mutant shell "coproc NOME { git …; }" 's/seg\[3:\] if seg\[0\] == "coproc" and seg\[2:3\] == \["{"\] else seg\[1:\]/seg[1:]/'
  mutant shell "cd -P / -L não são lidos como opção" 's/    while args and re.fullmatch(r"-\[LPe@\]+", args\[0\]):/    while False:/'
  mutant shell "cd -- DIR não é lido" 's/    if args\[:1\] == \["--"\]:/    if False:/'
  mutant shell "cd com dois argumentos vira o primeiro" 's/    if len(args) > 1 or /    if False or /'
  mutant shell "pushd sem argumento vira HOME" 's/ or (push and not args) or / or (False) or /'
  mutant shell "pushd +N / opção que não conheço vira diretório" 's/ or (args and args\[0\]\[:1\] in ("-", "+")):/ or False:/;s/    return p if p is None or os.path.isdir(p) else None/    return p/'
  mutant shell "<(cmd) engole o comando como se fosse alvo de redirecionamento" 's/^\( *\)skip = False  # `<(cmd)`.*/\1pass/'
  mutant shell "lançador que não modelo (flock/ssh/su/trap…) vira comando comum" 's/        elif c in OPAQUE or opq:/        elif False:/'
  mutant shell "git atrás de lançador herda o diretório conhecido" 's/{\*\*st\["env"\], \*\*env}, None, terr, own)/{**st["env"], **env}, cwd, terr, own)/'
  mutant shell "texto entre aspas passado ao lançador não é aberto" 's/                if re.search(r"\\s", t):/                if False:/'
  mutant shell "heredoc para bash/ssh/sh é descartado" 's/^        if not all(data_reader(s) for s in .*:$/        if False:/'
  mutant shell "todo heredoc vira script" 's/^    return bool(s) and (opq or .*/    return True/'
  mutant shell "here-string para bash é ignorado" 's/            if herestr and runs_text(seg):/            if False:/'
  mutant shell "continuação de linha não é juntada" 's/hide(CONT.sub(r"\\1", decomment(heredocs(cmd))))/hide(decomment(heredocs(cmd)))/'
  mutant shell "barra escapada + newline vira continuação" 's/^CONT = re.compile(.*)  #/CONT = re.compile(r"()\\\\\\n")  #/'
  mutant ctx "trecho aninhado começa sem as variáveis de fora" 's/return scan(text, cwd, terr, own, depth + 1, {\*\*st\["env"\], \*\*env}, st\["funcs"\], seen(env))/return scan(text, cwd, terr, own, depth + 1, {}, st["funcs"], seen(env))/'
  mutant ctx "trecho aninhado começa sem as funções de fora" 's/"funcs": {} if funcs is None else funcs, /"funcs": {}, /'
  mutant ctx "função cujo fim não fecha nunca roda" 's/    if st.get("fdepth"):  # o fim da função/    if False:  # o fim da função/'
  mutant ctx "heredoc volta a sumir para qualquer leitor que não é shell" 's/    return not opq and (not seg or os.path.basename(seg\[0\]) in DATA)/    return not opq and (not seg or os.path.basename(seg[0]) not in SHELLS)/'
  mutant ctx "redirecionamento colado esconde o shell do heredoc" 's/REDIR.sub(" ", cmd\[/(cmd[/'
  mutant ctx "leitor entre aspas deixa de ser lido como palavra" 's/peel(shlex.split(s))/peel(s.split())/'
  mutant ctx "escape \\U grande derruba o guarda" 's/chr(min(int(e\[1:\], 16), 0x10FFFF))/chr(int(e[1:], 16))/'
  mutant ctx "falha do guarda num Bash sem a palavra git libera" 's/if not (isinstance(inp, dict) and inp.get("tool_name") in {"Bash", \*TOOLS_FILE}) and not re.search/if not re.search/'
  mutant ctx "aspa de comentário volta a parear com a da linha seguinte" 's/        if not q and cmd\[k\] == "#" and (k == 0 or cmd\[k - 1\] in " \\t\\n;&|()"):/        if False:/'
  mutant ctx "\$( ) entre aspas simples/escapado volta a ser extraído no nível de fora" 's/        if q not in (.*) and (cmd.startswith("\$(", k) or cmd\[k\] == "`"):/        if (cmd.startswith("$(", k) or cmd[k] == "`"):/'
  mutant ctx "o ) do case fecha o \$( )" 's/            cs = max(0, cs + (1 if w.group(1) == "case" else -1))/            pass/'
  mutant ctx "em aspas duplas \\\$ e \\\` mantêm a barra" 's/out += \[cmd\[i + 1\]\] if q == .* else \[c, PROT.get/out += [c, PROT.get/'
  mutant ctx "VAR= depois de || vale como certa" 's/setvar(k, texts(v, st\["may"\]), unsure, v)/setvar(k, texts(v, st["may"]), False, v)/'
  mutant ctx "export depois de || vale como certo" 's/setvar(m.group(1), texts(m.group(2), st\["may"\]), unsure, m.group(2))/setvar(m.group(1), texts(m.group(2), st["may"]), False, m.group(2))/'
  mutant ctx "env cd muda o diretório do shell" 's/if st.get("lost") or kw or wrapped or ext or/if st.get("lost") or kw or ext or/'
  mutant ctx "find -exec cd (sem terminador) muda o diretório do shell" 's/if st.get("lost") or kw or wrapped or ext or/if st.get("lost") or kw or wrapped or/'
  mutant closed "branch/tag com palavra solta e sem opção de lista vira leitura" 's/        elif t.startswith("-") or not listing:/        elif t.startswith("-"):/'
  mutant closed "branch --list -d x vira leitura" 's/        elif t.startswith("-") or not listing:/        elif not listing:/'
  mutant closed "branch --contains -D x vira leitura" 's/^            if t.startswith("-"):/            if False:/'
  mutant closed "git config chave valor vira leitura" 's/len(rest) - len(flags) == 1 and/len(rest) - len(flags) >= 1 and/'
  mutant closed "git config --unset chave vira leitura" 's/ and all(t in CONFIG_SCOPE for t in flags))/)/'
  mutant cfg "leitura com configuração que roda programa volta a ser leitura (o guarda de antes)" 's/    if read and not runs:/    if read:/'
  mutant cfg "-c / --config-env com chave que roda programa não conta" 's/runs, i = runs or not CFG_SAFE.fullmatch(seg\[i + 1\].partition("=")\[0\]), i + 2/runs, i = runs, i + 2/'
  mutant cfg "--config-env=CHAVE=VAR (junto) não conta" 's/runs, i = runs or not CFG_SAFE.fullmatch(a.partition("=")\[2\].partition("=")\[0\]), i + 1/runs, i = runs, i + 1/'
  mutant cfg "-p / --paginate / --exec-path não contam" 's/            runs, i = True, i + 1/            runs, i = runs, i + 1/'
  mutant cfg "GIT_CONFIG_* / GIT_PAGER / GIT_EXTERNAL_DIFF… não contam" 's/    runs = any(CFG_ENV.fullmatch(k) for k in env)/    runs = False/'
  mutant cfg "toda chave de -c vale como segura" 's/CFG_SAFE = re.compile(r"(?:color|advice)/CFG_SAFE = re.compile(r".*|(?:color|advice)/'
  mutant cfg "nenhuma chave de -c vale como segura (os controles que passam importam)" 's/CFG_SAFE = re.compile(r"(?:color|advice)/CFG_SAFE = re.compile(r"(?!)(?:color|advice)/'
  mutant wrap "find -execdir/-okdir rodam no diretório do find (não ficam cegos)" 's/one(seg\[j + 1:\], blind or t.endswith("dir"), ext=True)/one(seg[j + 1:], blind, ext=True)/'
  mutant wrap "opção que não conheço de embrulho vira opção sem argumento" 's/            if name not in flag | arg | joined:/            if False:/'
  mutant wrap "sudo -n volta a levar argumento (a tabela única de antes)" 's/"-C -c -D -g -h -p -R -r -T -t -U -u --close-from/"-n -C -c -D -g -h -p -R -r -T -t -U -u --close-from/'
  mutant wrap "-- não encerra as opções do embrulho" 's/        if t == "--":/        if False:/'
  mutant wrap "env -S / --split-string não reabre o comando" 's/            if name in SPLIT:/            if False:/'
  mutant wrap "nice -5 não é lido" 's/        elif w == "nice" and t\[1:\].isdigit():/        elif False:/'
  mutant wrap "a duração do timeout não é descascada" 's/    if w == "timeout" and seg and NUM.fullmatch(seg\[0\]):/    if False:/'
  mutant wrap "duração decimal do timeout (1.5) não é lida" 's/re.compile(r"\[\\d.\]+\[smhd\]?")/re.compile(r"\\d+[smhd]?")/'
  mutant wrap "git --attr-source VALOR: o valor vira subcomando" 's/elif a in ("--namespace", "--attr-source") and i + 1 < len(seg):/elif a in ("--namespace",) and i + 1 < len(seg):/'
  mutant wrap "opção de topo do git que não conheço não deixa o diretório 'não sei'" 's/                lost, cwd = True, None/                pass/'
  mutant wrap "toda opção de topo do git vale como conhecida" 's/^GIT_FLAG = re.compile(r"-\[Phv\]|/GIT_FLAG = re.compile(r".*|-[Phv]|/'
  mutant wrap "bash -c com opção depois do -c" 's/while len(script) > 1 and script\[0\]\[:1\] in ("-", "+"):/while False:/'
  mutant wrap "o descritor de 2>/dev/null conta como argumento" 's/^FD = re.compile(.*)  #/FD = re.compile(r"(?!)")  #/'
  mutant wrap "número com espaço antes do > (argumento!) é tratado como descritor" 's/\\d+(?=\[<>\])/\\d+\\s*(?=[<>])/'
  mutant wrap "palavra do shell na posição do subcomando do git não esconde um -C" 's/    if SHELLY.search(sub):/    if False:/'
  mutant lexq "aspas simples: o ;<>… dentro delas volta a ser operador" "s/out.append(c if c == \"'\" else PROT.get(c, c))/out.append(c)/"
  mutant lexq "aspas duplas: o ;<>… dentro delas volta a ser operador" "s/out.append(c if c == '\"' else PROT.get(c, c))/out.append(c)/"
  mutant lexq "barra + caractere (\\>): o caractere escapado volta a ser operador" 's/else \[c, PROT.get(cmd\[i + 1\], cmd\[i + 1\])\]/else [c, cmd[i + 1]]/'
  mutant lexq "quem é operador é decidido DEPOIS de devolver os caracteres protegidos" 's/bool(t) and set(t) <= PUNCT) for t in lx\]/bool(t) and set(t.translate(UNPROT)) <= PUNCT) for t in lx]/'
  mutant lexs "redirecionamento sem alvo (> no fim) engole o terminador" 's/if skip and not op:/if skip:/'
  mutant lexs "operador que chega com redirecionamento esperando alvo não zera o alvo" 's/^\( *\)skip = herestr = False  # um operador.*/\1pass/'
  mutant lexe "a palavra vazia ('' ou \"\") some da lista de palavras" 's/ for t in lx\]/ for t in lx if t]/'
  mutant lexe "a palavra vazia vale como operador" 's/(t.translate(UNPROT), bool(t) and set(t)/(t.translate(UNPROT), set(t)/'
  mutant lexd "\$'…' não é aberto (o \$ fica e o git vira \$git)" "s/elif c == \"\\\$\" and cmd\[i + 1:i + 2\] == \"'\":/elif False:/"
  mutant lexd "\$\"…\" não perde o \$" "s/elif c == \"\\\$\" and cmd\[i + 1:i + 2\] == '\"':/elif False:/"
  mutant lexd "escape hexadecimal de \$'…' não é decodificado" 's/return chr(min(int(e\[1:\], 16), 0x10FFFF))/return m.group(0)/'
  mutant lexd "escape octal de \$'…' não é decodificado" 's/return chr(int(e, 8) & 255)/return m.group(0)/'
  mutant lexd "aspa escapada dentro de \$'…' (\\') fecha o \$'…'" 's/j += 2 if cmd\[j\] == "\\\\" else 1/j += 1/'
  mutant lexd "\$S<hex>\$ de um \$( ) colado numa aspa perde o \$ final" 's/elif c == "\$" and (m := SUBST.match(cmd, i)):/elif False:/'
  mutant lexu "aspa que não fecha: em vez de sair do texto ela fecha no fim (o que vem depois, até a linha seguinte, vira texto)" 's/cmd = cmd\[:e.pos\] + cmd\[e.pos + 1:\]/cmd += cmd[e.pos]/'
  mutant lexu "aspa que não fecha: nada a conserta (o ValueError sobe e o pedido todo é bloqueado)" 's/cmd = cmd\[:e.pos\] + cmd\[e.pos + 1:\]/raise/'
  mutant lexu "aspa que não fecha: a que sobra no fim do texto não é percebida" 's/^    if q:$/    if False:/'
  mutant lexu "\\ solto no fim (fora de aspas) não é percebida" 's/^\( *\)raise Unclosed(i)  # barra solta no fim.*/\1out.append(c)/'
  mutant lexu "\$'… que não fecha não é percebido (o resto vira texto dentro dele)" 's/raise Unclosed(i + 1)/pass/'
  mutant lexr "o \$( ) do alvo de um redirecionamento não roda" 's/^\( *\)r = inner(\[tok\])  # .*/\1r = None/'
  mutant lexh "<<< volta a abrir heredoc (esconde os comandos depois dele)" 's/^HEREDOC = re.compile(r"(?<!<)/HEREDOC = re.compile(r"/'
  mutant wrap,lexh "o segundo -exec (depois do \;) não é aberto" 's/r = one(seg\[j + 1:\], blind or t.endswith("dir"), ext=True)/return one(seg[j + 1:], blind or t.endswith("dir"), ext=True)/'
  mutant destb "o destino que vem como argumento não é conferido" 's/ + \[res(x, cwd) for x in dests(sub, rest)\]//'
  mutant destb "--output/--prefix/--separate-git-dir (PATHOPT) não são lidos" 's/        elif name in PATHOPT:/        elif False:/'
  mutant destb "toda palavra de worktree/clone/init/checkout-index… não conta como destino" 's/        elif sub in DEST:/        elif False:/'
  mutant destb "worktree sai da lista DEST (git worktree remove ../outro)" 's/^DEST = {"worktree", /DEST = {/'
  mutant destb "-oVALOR (colado) não é lido" 's/ else t\[2:\] if t\[:1\] == "-" else t)/ else "" if t[:1] == "-" else t)/'
  mutant destb "--opção VALOR (valor no token seguinte) não é lido" 's/if eq else (out, True)/if eq else (out, False)/'
  mutant destb "--opção=VALOR não é lido" 's/out, val = (out + \[v\], False) if eq else/out, val = (out, False) if eq else/'
  mutant destp "URL (https://…) vira caminho" 's/ and not URL.match(x)\]/]/'
  mutant check "selfcheck ignora campo extra do hook (if, async…)" 's/ and set(h) <= {"type", "command", "timeout"}//'
  mutant check "selfcheck ignora campo extra do grupo" 's/ and set(g) <= {"matcher", "hooks"}//'
  mutant check "selfcheck não exige type=command" 's/ and h.get("type") == "command"//'
  mutant budget "um { guardado, ao reexecutar um corpo, reabre a definição (o laço sem fim do pedido do runbook)" 's/if not st.get("calling") and (seg\[:1\] == \["{"\]/if (seg[:1] == ["{"]/'
  mutant budget "o corpo que não fecha, reexecutado no fim, volta a poder reabrir a definição" 's/^        st.setdefault("calling", set()).add(st\["fname"\]).*/        pass/'
  mutant budget "sem contar os trechos de one() o teto de passos nunca vale" 's/^        tick()$/        pass/'
  mutant budget "teto de passos gigante" 's/^STEP_LIMIT, TIME_LIMIT, WORK = 50000,/STEP_LIMIT, TIME_LIMIT, WORK = 10**9,/'
  mutant budget "o contador de passos não zera a cada pedido" 's/^    WORK\[0\] = 0$/    pass/'
  mutant budget "o relógio não é armado" 's/^    signal.setitimer(signal.ITIMER_REAL, TIME_LIMIT).*/    pass/'
  mutant budget "o relógio só é armado depois de ler o stdin" 's/^    signal.setitimer(signal.ITIMER_REAL, TIME_LIMIT).*/    pass/;s/^    raw = sys.stdin.read()$/    raw = sys.stdin.read(); signal.setitimer(signal.ITIMER_REAL, TIME_LIMIT)/'
  mutant budget "sem tratador de SIGALRM o alarme MATA o guarda, sem a recusa" 's/^    signal.signal(signal.SIGALRM, expired)$/    pass/'
  mutant budget "o relógio continua armado depois do veredito" 's/^        signal.setitimer(signal.ITIMER_REAL, 0)$/        pass/'
  mutant budget "o estouro dentro do julgamento cai no 'o guarda falhou' (sem a recusa de tempo)" 's/^    except Budget:$/    except KeyError:/'
  mutant budget "main() não pega o estouro" 's/^    except Budget as e:/    except KeyError as e:/'
  mutant budget "function NOME { aninhada num corpo reexecutado não marca a região como perdida" 's/if seg\[:1\] == \["function"\] or seg\[:1\] == \["{"\] and (prev == ")" or st.get("nhead")):/if seg[:1] == ["{"] and (prev == ")" or st.get("nhead")):/'
  mutant budget "NOME() { aninhada num corpo reexecutado não marca a região como perdida" 's/if seg\[:1\] == \["function"\] or seg\[:1\] == \["{"\] and (prev == ")" or st.get("nhead")):/if seg[:1] == ["function"]:/'
  mutant budget "na região perdida o cd volta a valer" 's/if st.get("lost") or kw or wrapped or ext or/if kw or wrapped or ext or/'
  mutant budget "na região perdida a atribuição de variável volta a valer" 's/norun = bool(st.get("lost")) or kw/norun = kw/'
  mutant budget "uma chamada feita dentro da região perdida a encerra para o resto do corpo de fora" 's/^            st\["lost"\] = saved$/            st.pop("lost", None)/'
  mutant budget "function f { depois de || ou && vale como definição que sempre rodou" 's/";" if prev == ")" else prev/";"/'
  mutant budget "a aninhada não passa a existir quando f roda (a chamada dela de fora não é conferida)" 's/^                        st\["funcs"\]\.setdefault(nm, \[\])\.extend(rest)$/                        pass/'
  mutant budget "a cabeça g() aninhada não dá o nome à função (só a forma function g { dá)" 's/^                st\["nhead"\] = seg\[0\] .*/                pass/'
  mutant budget "function g { aninhada não dá o nome à função (só a forma g() { dá)" 's/nm = seg\[1\] if seg\[0\] == "function" and seg\[1:2\] else st.pop("nhead", None)/nm = st.pop("nhead", None)/'
  mutant budget "a reexecução percorre a lista viva E o registro repetido não é pulado (juntos: uma função que se redefine acrescenta a si mesma sem fim; sozinha, a cópia virou defesa em profundidade, o registro único já impede)" 's/body = list(st\["funcs"\]\[c\])  # cópia/body = st["funcs"][c]  # cópia/;s/if key not in st.setdefault("regd", set()):/if st.setdefault("regd", set()) is not None:/'
  mutant budget "registrar uma aninhada copia a lista sem entrar na conta do teto" 's/^                        tick(len(rest))  #.*/                        pass/'
  mutant budget "a cabeça NOME( que não foi seguida de { deixa a bandeira de definição velha (o próximo grupo { } vira corpo, sem conferir)" 's/^        if seg and seg\[0\] != "{":$/        if False:/'
  mutant budget "o corpo que começa por um grupo { } parece uma definição aninhada" 's/";" if prev == ")" else prev/prev/'
  mutant budget "uma função chamada git isenta a chamada do git_hit (a definição pode nem ter rodado; command git a ignora)" 's/^            if c == "git":  #.*/            if False:/'
  mutant budget "g() NEWLINE { num corpo reexecutado não é lido como definição aninhada" 's/(prev == ")" or st.get("nhead"))/prev == ")"/'
  mutant budget "a cabeça g ( que não foi seguida de { deixa a bandeira velha (o próximo grupo { } vira corpo de função e o cd dele deixa de valer)" 's/^            elif seg and seg\[0\] != "{":$/            elif False:/'
  mutant budget "a MESMA aninhada é registrada de novo a cada chamada (a lista dobra e o pedido de 7 chamadas estoura o teto)" 's/if key not in st.setdefault("regd", set()):/if st.setdefault("regd", set()) is not None:/'
  mutant budget "o registro da aninhada é pulado pelo NOME (a segunda definição de g, que escreve, nunca é conferida na chamada)" 's/key = (nm, id(rest\[0\]) if rest else 0)/key = nm/'
  mutant budget "function NOME() no topo não é lido como definição (o cd de dentro vale como se tivesse rodado)" 's/ or len(seg) == 2 and seg\[0\] == "function" and seg\[1\] not in KEYWORDS)/)/'
  mutant budget "a palavra de comando que é uma função não é reexecutada antes dos ramos especiais (bash(), env(), cd(), find(), eval()…)" 's/^        if fw in st.get("funcs", {}) and fw not in st.setdefault("calling", set()):/        if False:/'
  mutant budget "um cd coberto por uma função segue modelado como cd" 's/^            if done:$/            if False:/'
  mutant budget "uma atribuição coberta por uma função (export() { :; }) segue valendo" 's/unsure = norun or bool(done)/unsure = norun/'
  mutant interpc "python -c deixa de ser interpretador" 's/^INTERP = re.compile(r"(?:python|pypy|perl|ruby|php|lua)/INTERP = re.compile(r"(?:pypy|perl|ruby|php|lua)/'
  mutant interpc "node -e deixa de ser interpretador" 's/|node(?:js)?|/|/'
  mutant interpc "perl -e deixa de ser interpretador" 's/|perl|ruby|php|lua)/|ruby|php|lua)/'
  mutant interpc "ruby -e deixa de ser interpretador" 's/|perl|ruby|php|lua)/|perl|php|lua)/'
  mutant interpc "php -r deixa de ser interpretador" 's/|ruby|php|lua)/|ruby|lua)/'
  mutant interpc "lua -e deixa de ser interpretador" 's/|ruby|php|lua)/|ruby|php)/'
  mutant interpc "deno eval e bun -e deixam de ser interpretadores" 's/|node(?:js)?|deno|bun|/|node(?:js)?|/'
  mutant interpc "o perl só aceita q{} q() q[] como delimitador (q!…! e q#…# passam)" 's/\\6|<(/\\6(?!)|<(/'
  mutant interpc "<…> do perl e do ruby (q<>, qq<>, qx<>, %x<>, %Q<>) deixa de ser literal" 's/|<(\[^>\]\*)>)/|<(?!)(\[^>\]\*)>)/'
  mutant interpc "[[…]] e [=[…]=] do lua deixam de ser literais" 's/\\9\\]", re.S)/\\9\\](?!)", re.S)/'
  mutant interpc "%Q e %q do ruby deixam de ser literais (só %x)" 's/%\[xQq\]/%x/'
  mutant interpc "awk deixa de ser interpretador" 's/|\[gmn\]?awk"/"/'
  mutant interpc "o código de nenhum interpretador é aberto" 's/        elif INTERP.fullmatch(c):/        elif False:/'
  mutant interpc "o literal entre aspas do código não é conferido sozinho (perl system \"…\" sem parêntese, getline do awk)" 's/ + \[ANSI.sub(ansi, (\[x for x in g if x\] or \[""\])\[-1\]) for g in LIT.findall(t)\]:/:/'
  mutant interpc "o código inteiro não é conferido como shell (a crase do perl)" 's/for text in \[t\] + (\[m.group(2)\] if m else \[\]) + /for text in ([m.group(2)] if m else []) + /'
  mutant interpc "chdir/cwd no código não deixa o diretório \"não sei\"" 's/^CODECD = re.compile(r"chdir|\\bcwd\\b|\\bGIT_\[A-Z_\]+")/CODECD = re.compile(r"(?!)")/'
  mutant interpc "a chave 'cwd' ENTRE ASPAS deixa de valer como a opção (bypass)" 's/^CODECD = re.compile(r"chdir|\\bcwd\\b|\\bGIT_\[A-Z_\]+")/CODECD = re.compile(r"chdir|\\bcwd\\s\*\[=:\]|\\bGIT_\[A-Z_\]+")/'
  mutant interpc "GIT_DIR / GIT_WORK_TREE no código não deixam o diretório \"não sei\"" 's/^CODECD = re.compile(r"chdir|\\bcwd\\b|\\bGIT_\[A-Z_\]+")/CODECD = re.compile(r"chdir|\\bcwd\\b")/'
  mutant interpc "GIT_ sem fronteira de palavra casa DIGIT_N (falso positivo no próprio clone)" 's/^CODECD = re.compile(r"chdir|\\bcwd\\b|\\bGIT_\[A-Z_\]+")/CODECD = re.compile(r"chdir|\\bcwd\\b|GIT_\[A-Z_\]+")/'
  mutant interpc "os escapes do literal (\\x67it) não são decodificados" 's/ANSI.sub(ansi, (\[x for x in g if x\] or \[""\])\[-1\])/(\[x for x in g if x\] or [""])[-1]/'
  mutant interpc "o valor de NOME=valor (awk -v cmd=…) não é conferido" 's/\[m.group(2)\] if m else \[\]/[]/'
  mutant interpc "o shell aberto pelo código nunca sabe o diretório (falso positivo no próprio clone)" 's/cw = None if CODECD.search(" ".join(seg)) else cwd/cw = None/'
  mutant interpp "shell sem -c não lê o texto do pipe (nem o que está em corpo de função)" 's/ else seg + \["-c", "\\n".join(flow)\]/ else seg/'
  mutant interpp "o texto de um trecho não segue para o próximo do pipe" 's/flow, hs = printed(seg, flow if hs is None else hs, st\["may"\]) if pc in PIPES else None, None/flow, hs = None, None/'
  mutant interpp "o trecho não recebe o que o anterior imprime" 's/r = one(pipefed(seg, flow), False, prev, pc)/r = one(seg, False, prev, pc)/'
  mutant interpp "|& não liga trechos" 's/^PIPES, VAR, MANY = ("|", "|&"),/PIPES, VAR, MANY = ("|",),/'
  mutant interpp,interpe "o texto de um here-string não é guardado" 's/            hs = \[v\[0\] for v in reveal(\[tok\], st\["may"\])\] if herestr else hs/            pass/'
  mutant interpp,interpe "o here-string não vira o stdin do produtor do pipe" 's/printed(seg, flow if hs is None else hs, st\["may"\])/printed(seg, flow, st["may"])/'
  mutant interpp "echo não é lido" 's/^    if c == "echo":/    if False:/'
  mutant interpp "echo -e não decodifica os escapes" 's/if "e" in fl else/if False else/'
  mutant interpp,interpe "printf não é lido" 's/^    if c == "printf" and a:/    if False:/'
  mutant interpp "printf reaproveita o formato só uma vez" 's/range(0, max(len(a) - 1, 1) if n else 1, n or 1)/range(0, 1)/'
  mutant interpp "printf -- não é pulado" 's/^    a = a\[1:\] if c == "printf" and a\[:1\] == \["--"\] else a/    a = a/'
  mutant interpp "VAR=x e command antes do echo escondem o produtor do pipe" 's/^    _, s, _, opq = peel(seg)$/    s, opq = seg, False/'
  mutant interpc "qx{…} e q{…}/qq{…} do perl deixam de ser literais" 's/(?:\\bq\[qx\]?|%\[xQq\])/(?:%[xQq])/'
  mutant interpc "%x(…) do ruby deixa de ser literal" 's/(?:\\bq\[qx\]?|%\[xQq\])/(?:\\bq[qx]?)/'
  mutant interpp "tee não repassa o stdin" 's/(c == "tee" or c == "cat"/(c == "tee1" or c == "cat"/'
  mutant interpp "cat sem arquivo não repassa o stdin" 's/ or c == "cat" and all(/ or c == "cat1" and all(/'
  mutant interpp "cat com arquivo repassa o stdin (lê o arquivo, não o pipe)" 's/all(x\[:1\] == "-" for x in a)/True/'
  mutant interpe "echo e printf não revelam variável nem \$( ) nos argumentos" 's/for v in reveal(a, may)\] if c in ("echo", "printf")/for v in [a]] if c in ("echo", "printf")/'
  mutant interpe "base64 -d só vale com -d (não --decode nem -D)" 's/{"-d", "--decode", "-D"}/{"-d"}/'
  mutant interpe "base64 -d não decodifica" 's/c == "base64"/c == "base65"/'
  mutant interpe "rev não inverte" 's/ and c == "rev" else None/ and False else None/'
  mutant interpe "pipeline dentro do \$( ) não é lido" 's/        elif tok in PIPES:/        elif False:/'
  mutant interpe "outro operador dentro do \$( ) (>, ;…) vale como pipeline simples" '/elif tok in PIPES:/,/return flow/ s/            return None/            pass/'
  mutant interpe "o eval não revela o \$( ) que só imprime texto" 's/t = pipe_out(bytes.fromhex(m.group(1)).decode(), may) if m else/t = None if m else/'
  mutant interpe "o eval não revela a variável que guardo" 's/ else may.get(v.group(1) or v.group(2)) if v else \[w\]/ else None if v else [w]/'
  mutant interpe "o eval volta a ver só o texto da palavra" 's/for v in reveal(seg\[1:\], seen(env, True))/for v in [seg[1:]]/'
  mutant interpe "o eval revela só as variáveis do próprio comando, não as do shell" 's/reveal(seg\[1:\], seen(env, True))/reveal(seg[1:], {k: texts(v, {}) or [] for k, v in env.items()})/'
  mutant interpe "o eval só vê as variáveis do shell, não o prefixo NOME=x do comando" 's/ + (texts(v, st\["may"\]) or \[\]))) for k, v in env.items()}}/)) for k, v in env.items()}}/'
  mutant interpe "o eval só vê o prefixo NOME=x, não o texto que a variável tinha antes" 's/(st\["may"\].get(k, \[\]) if keep else \[\])/[]/'
  mutant interpe "o shell aninhado (bash -c, NOME=x bash -c) começa sem os textos das variáveis" 's/st\["funcs"\], seen(env))/st["funcs"], {})/'
  mutant interpe "printf -v NOME não guarda o texto" 's/        elif c == "printf" and seg\[1:2\] == \["-v"\] and len(seg) > 3:/        elif False:/'
  mutant interpe "printf -v guarda sempre \"não sei\" para o git" 's/setvar(seg\[2\], t, unsure, t\[0\] if t and len(t) == 1 else "\$?")/setvar(seg[2], t, unsure, "$?")/'
  mutant interpe "trecho que pode não ter rodado APAGA o texto de antes (o inofensivo vence o nocivo)" 's/            st\["may"\]\[name\] = list(dict.fromkeys(st\["may"\].get(name, \[\]) + ts))  # /            st["may"][name] = ts  # /'
  mutant interpe "trecho que pode não ter rodado não conta o texto novo (o nocivo que talvez foi gravado)" 's/        elif ts:$/        elif False:/'
  mutant interpe "trecho que SEI que rodou não apaga o texto de antes" 's/            st\["may"\]\[name\] = ts or \[\]  # /            st["may"][name] = st["may"].get(name, []) + (ts or [])  # /'
  mutant interpe "NOME=\$OUTRA e NOME=\$( ) não leem o texto da atribuição" 's/setvar(k, texts(v, st\["may"\]), unsure, v)/setvar(k, [v], unsure, v)/'
  mutant interpe "export NOME=\$OUTRA e NOME=\$( ) não leem o texto da atribuição" 's/setvar(m.group(1), texts(m.group(2), st\["may"\]), unsure, m.group(2))/setvar(m.group(1), [m.group(2)], unsure, m.group(2))/'
  mutant interpe "o argumento do %b do printf não decodifica os escapes" 's/ANSI.sub(ansi, next(it, "")) if m.group()\[-1\] == "b" else next(it, "")/next(it, "")/'
  mutant interpe "o ( ) não desfaz o que o subshell atribuiu" 's/st\["cwd"\], st\["env"\], st\["may"\] = stack.pop()/st["cwd"] = stack.pop()[0]/'
  mutant interpe "o case não marca a pilha: o ) do padrão fecha o subshell" 's/if seg\[c0:c0 + 1\] == \["case"\] and "in" in seg\[c0 + 2:\]:/if False:/'
  mutant interpe "o esac não tira a marca do case: o ) que fecha o subshell vira fim de padrão" 's/elif seg\[c0:c0 + 1\] == \["esac"\] and None in stack:/elif False:/'
  mutant interpe "o ) sempre fecha o subshell, mesmo com o case aberto" 's/if stack and stack\[-1\] is not None:/if stack:/'
  mutant interpe "o case depois de if/while não é reconhecido (a palavra reservada conta como comando)" 's/c0 = next((i for i, w in enumerate(seg) if w not in KEYWORDS), len(seg))/c0 = 0/'
  mutant interpe "função chamada por um trecho que pode não ter rodado atribui como se tivesse" 's/^        st\["maybe"\] = was or maybe$/        st["maybe"] = was/'
  mutant interpe "a palavra de comando que é função, chamada por um trecho que pode não ter rodado, atribui como se tivesse" 's/            r = call(fw, blind, norun)/            r = call(fw, blind)/'
  mutant interpe "função escondida atrás de um embrulho (command f), chamada por um trecho que pode não ter rodado, atribui como se tivesse" 's/                r = call(c, blind, unsure)  #.*/                r = call(c, blind)/'
  mutant interpe "if/for/while/until em várias linhas não abrem bloco (a atribuição de dentro vale como certa)" 's/st\["bdepth"\] = st.get("bdepth", 0) + 1/pass/'
  mutant interpe "fi/done/esac não fecham o bloco (a atribuição de DEPOIS dele vira \"talvez\")" 's/st\["bdepth"\] = max(st.get("bdepth", 0) - 1, 0)/pass/'
  mutant interpe "dentro do bloco de várias linhas o trecho não é \"pode não ter rodado\"" 's/ or st.get("bdepth", 0) > 0  # o trecho/  # o trecho/'
  mutant interpe "o cd dentro do bloco de várias linhas vale depois do fi" 's/if (blk or st.get("bdepth", 0) > 0) and new is not None:/if blk and new is not None:/'
  mutant interpe "o case não conta como bloco (o esac fecha o if de fora)" 's/("if", "for", "while", "until", "case", "select")/("if", "for", "while", "until", "select")/'
  mutant interpe "then/do na frente de um if (then if x; then) escondem a abertura" 's/^LEAD = {"then", "do", /LEAD = {/'
  mutant interpe "variantes demais passam sem conferir (o teto some)" 's/        if len(out) > MANY:/        if False:/'
  mutant interpe "variantes demais bloqueiam como falha do guarda, sem dizer o motivo" 's/        except Many:/        except ZeroDivisionError:/'
  echo "-- contra um stub que só sai 0 (o servidor ANTES desta fatia)"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub"; chmod +x "$T/stub"; printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$T/stub.py"
  r=$(RCG_MUTANT=1 RCG_ONLY="block,evade,closed,shell,wrap,lex,dest,cfg,tools,msg,check,cond,interp" RCG_UNDER_TEST="$T/stub.py" bash "$0" 2>&1 | tail -1); echo "stub: $r"
  case "$r" in "RESULT 0/"*|"") ok 1 "stub deveria falhar quase tudo ($r)";; *) ok 0 "stub falha os casos ($r)";; esac
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
