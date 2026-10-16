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
#   de heredoc e here-string que um shell lê, de `\`+newline (e os controles que NÃO podem bloquear) · cfg — a LEITURA que traz configuração capaz de rodar programa
#   (`-c alias.x=…`, `--config-env`, `-p`, `--exec-path`, GIT_CONFIG_*/GIT_PAGER/GIT_EXTERNAL_DIFF…) deixa de valer como leitura no clone alheio; chave só de exibição e o próprio clone seguem livres · msg — o texto da recusa · check — --selfcheck com settings bom e com cada defeito · hook — o comando de hook de
#   verdade (`python3 -I <guarda> || exit 2`) sai 2 se o guarda trava, some ou tem erro de sintaxe (falha fechada), e 0 se libera.
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar (67 mutantes); e
#   contra um stub que só sai 0 (o servidor ANTES desta fatia: o hook do mini era `drop` e nada o substituía), quase tudo falha.
# VARIÁVEIS: RCG_UNDER_TEST (guarda a testar) · RCG_ONLY (grupos, vírgula) · RCG_NO_MUTANTS=1
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

all() { group block && g_block; group pass && g_pass; group evade && g_evade; group closed && g_closed; group shell && g_shell; group cfg && g_cfg; group tools && g_tools; group msg && g_msg
        group check && g_check; group hook && g_hook; return 0; }

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
  mutant evade "cd não muda o diretório" 's/st\["cwd"\] = chdir(seg\[1:\], st\["cwd"\], c == "pushd")/pass/'
  mutant evade "bash -c não é aberto" 's/return scan(seg\[j + 1\], cwd, terr, own, depth + 1)/pass/'
  mutant evade "eval não é aberto" 's/return scan(" ".join(seg\[1:\]), cwd, terr, own, depth + 1)/pass/'
  mutant evade "\$( ) não é aberto" 's/r = scan(bytes.fromhex(m.group(1)).decode(), st\["cwd"\], terr, own, depth + 1)/r = None/'
  mutant evade "crase não vira \$( )" 's/cmd, out, i = BACKTICK.sub(r"$(\\1)", cmd), \[\], 0/cmd, out, i = cmd, [], 0/'
  mutant evade "parêntese dentro do \$( ) não é contado" 's/d + (cmd\[k\] == "(") - /d - /'
  mutant evade "\$( ) de heredoc sem aspas é ignorado" 's/("" if m.group(2) else/("" if True else/'
  mutant evade "find -exec não é aberto" 's/if t in ("-exec", "-execdir", "-ok", "-okdir"):/if False:/'
  mutant evade "command/env/sudo/xargs não são descascados" 's/elif os.path.basename(seg\[0\]) in WRAP:/elif False:/'
  mutant pass "corpo de heredoc é tratado como comando" 's/hide(CONT.sub(r"\\1", HEREDOC.sub(heredoc, cmd)))/hide(cmd)/'
  mutant evade "pontuação colada ); engole a próxima palavra" 's/for pc in PIECE.findall(tok):/for pc in [tok]:/'
  mutant tools "Edit/Write não são vigiados" 's/    if tool in TOOLS_FILE:/    if False:/'
  mutant closed "falha do guarda vira liberado" '/o guarda falhou/{n;s/return 2/return 0/;}'
  mutant block "bloqueio sai 0 em vez de 2" '/print(message(hit/{n;s/return 2/return 0/;}'
  mutant closed "sem projeto, o cwd vira clone próprio" 's/p = os.path.realpath(proj) if proj else ""/p = os.path.realpath(proj or os.getcwd())/'
  mutant evade "stash push com 'stash list' na mensagem vira leitura" 's/(sub == "stash" and first in ("list", "show"))/(sub == "stash")/'
  mutant closed "branch com argumento vira leitura" 's/return lists_only(sub, rest)/return True/'
  mutant closed "JSON ruim que cita git passa" 's/if not re.search(r"git|file_path|notebook_path", raw):/if True:/'
  mutant check "selfcheck só confere o Bash" 's/for tool in ("Bash",) + tuple(TOOLS_FILE):/for tool in ("Bash",):/'
  mutant check "selfcheck aceita hook que chama outro arquivo" 's/re.escape(me)/r"\\S+"/'
  mutant check "selfcheck não exige '|| exit 2'" 's/\\s+\\|\\|\\s+exit\\s+2")/.*")/'
  mutant check "selfcheck ignora disableAllHooks" 's/if s.get("disableAllHooks"):/if False:/'
  mutant check "selfcheck ignora a camada do projeto" 's/for d in args\[1:\]:/for d in []:/'
  mutant evade "opção de env/sudo que muda o diretório não deixa o guarda cego" 's/^\( *\)blind = blind or seg\[0\]\[:2\].*/\1pass/'
  mutant evade "export/declare não são lidos" 's/if c in ("export", "declare", "typeset"):/if False:/'
  mutant evade "VAR=x solta não vale para o git seguinte" 's/st\["env"\].update(env)  # /pass  # /'
  mutant evade "VAR=x depois de env/sudo é descartada" 's/env\[m.group(1)\] = m.group(2)$/pass/'
  mutant evade "env -S (comando inteiro numa palavra) não é reaberto" 's/if " " in seg\[0\]:/if False:/'
  mutant evade "remote -v add vira leitura" 's/rest in (\[\], \["-v"\]) or/rest[:1] in ([], ["-v"]) or/'
  mutant evade "--output/--lost-found em comando de leitura" 's/    if any(WRITES.match(t) for t in rest):/    if False:/'
  mutant tools "Edit/Write em ~\/.claude\/hooks e settings passam" 's/p is None or claude_conf(p) or (inside/p is None or (inside/'
  mutant check "selfcheck aceita o arquivo citado no meio do comando" 's/hook_re.fullmatch(/hook_re.search(/'
  mutant shell "palavra reservada (if/then/{/!…) esconde o git" 's/        elif seg\[0\] in KEYWORDS:/        elif False:/'
  mutant shell "function NOME { git …; }" 's/        elif seg\[0\] == "function":/        elif False:/'
  mutant shell "coproc NOME { git …; }" 's/seg\[3:\] if seg\[0\] == "coproc" and seg\[2:3\] == \["{"\] else seg\[1:\]/seg[1:]/'
  mutant shell "cd -P / -L não são lidos como opção" 's/    while args and re.fullmatch(r"-\[LPe@\]+", args\[0\]):/    while False:/'
  mutant shell "cd -- DIR não é lido" 's/    if args\[:1\] == \["--"\]:/    if False:/'
  mutant shell "cd com dois argumentos vira o primeiro" 's/    if len(args) > 1 or /    if False or /'
  mutant shell "pushd sem argumento vira HOME" 's/ or (push and not args) or / or (False) or /'
  mutant shell "pushd +N / opção que não conheço vira diretório" 's/ or (args and args\[0\]\[:1\] in ("-", "+")):/ or False:/'
  mutant shell "<(cmd) engole o comando como se fosse alvo de redirecionamento" 's/^\( *\)skip = False  # `<(cmd)`.*/\1pass/'
  mutant shell "lançador que não modelo (flock/ssh/su/trap…) vira comando comum" 's/        elif c in OPAQUE:/        elif False:/'
  mutant shell "git atrás de lançador herda o diretório conhecido" 's/{\*\*st\["env"\], \*\*env}, None, terr, own)/{**st["env"], **env}, cwd, terr, own)/'
  mutant shell "texto entre aspas passado ao lançador não é aberto" 's/                if re.search(r"\\s", t):/                if False:/'
  mutant shell "heredoc para bash/ssh/sh é descartado" 's/^    if any(runs_text(s.split()) for s in .*:$/    if False:/'
  mutant shell "todo heredoc vira script" 's/^    return bool(s) and os.path.basename(s\[0\]) in .*/    return True/'
  mutant shell "here-string para bash é ignorado" 's/            if herestr and runs_text(seg):/            if False:/'
  mutant shell "continuação de linha não é juntada" 's/hide(CONT.sub(r"\\1", HEREDOC.sub(heredoc, cmd)))/hide(HEREDOC.sub(heredoc, cmd))/'
  mutant shell "barra escapada + newline vira continuação" 's/^CONT = re.compile(.*)  #/CONT = re.compile(r"()\\\\\\n")  #/'
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
  echo "-- contra um stub que só sai 0 (o servidor ANTES desta fatia)"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub"; chmod +x "$T/stub"; printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$T/stub.py"
  r=$(RCG_MUTANT=1 RCG_ONLY="block,evade,closed,shell,cfg,tools,msg,check" RCG_UNDER_TEST="$T/stub.py" bash "$0" 2>&1 | tail -1); echo "stub: $r"
  case "$r" in "RESULT 0/"*|"") ok 1 "stub deveria falhar quase tudo ($r)";; *) ok 0 "stub falha os casos ($r)";; esac
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
