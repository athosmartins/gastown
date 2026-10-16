#!/usr/bin/env bash
# remote-clone-guard.selftest.sh — hermético: o "território" é uma pasta de mktemp (HOME de teste), nada conecta em lugar nenhum.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS (grupos): block — escrita de git no clone ALHEIO (commit/push/merge/rebase/reset/cherry-pick/checkout/add/stash/clean/branch -D/
#   tag -d/revert/am/apply/switch/restore/rm/mv/update-ref/fetch/pull), por -C, -C relativo, -C encadeado, ~/, --git-dir, --work-tree,
#   GIT_DIR=, symlink do meu clone para o alheio, cwd dentro do alheio, o espelho repo.git · pass — leitura no clone alheio (log/status/
#   diff/show/rev-parse/ls-files/blame/branch/tag -l/stash list/config --get/remote -v/worktree list), escrita no PRÓPRIO clone (cwd, -C,
#   subpasta, cd), escrita fora do território, comando que só CITA o outro clone (echo, mensagem de commit, corpo de heredoc), subshell
#   que volta de cd · evade — a mesma escrita embrulhada: command/env/sudo/xargs/caminho do git, bash -c, sh -c, eval, $(…), crase,
#   find -exec, ; && || | ( ), heredoc, -c user.name · closed — o que não sei NÃO vira liberado: variável, glob, ~usuário, cd para variável,
#   subcomando desconhecido, JSON ruim, sem CLAUDE_PROJECT_DIR, aninhamento fundo · tools — Edit/Write/MultiEdit/NotebookEdit no clone
#   alheio bloqueiam, no próprio e fora do território liberam, Read passa · msg — a mensagem diz o alvo, o clone próprio, que não é o
#   usuário cancelando e que leitura segue liberada · check — --selfcheck com settings bom e com cada defeito (sem Bash, sem Edit, sem
#   `|| exit 2`, outro caminho, disableAllHooks) · hook — o comando de hook de verdade (`python3 -I <guarda> || exit 2`) sai 2 se o guarda
#   trava, some ou tem erro de sintaxe (falha fechada), e 0 se libera.
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e o grupo que a cobre TEM que passar a falhar (28 mutantes); e
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
  done
  g 2 "tools: Write sem clone próprio (sem projeto)" Write file_path "$OWN/f" "$OWN" ""
  g 2 "tools: Edit com caminho relativo e sem cwd resolvível" Edit file_path "x.txt" "" "$OWN"
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
  settings "$s" "Bash" "Edit|Write|MultiEdit|NotebookEdit"; python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d["disableAllHooks"]=True;json.dump(d,open(sys.argv[1],"w"))' "$s"
  python3 -I "$P" --selfcheck "$s" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "check: disableAllHooks ligado → falha"
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

all() { group block && g_block; group pass && g_pass; group evade && g_evade; group closed && g_closed; group tools && g_tools; group msg && g_msg
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
  mutant evade "cd não muda o diretório" 's/st\["cwd"\] = res(seg\[1\] if len(seg) > 1 else "~", st\["cwd"\])/pass/'
  mutant evade "bash -c não é aberto" 's/return scan(seg\[j + 1\], st\["cwd"\], terr, own, depth + 1)/pass/'
  mutant evade "eval não é aberto" 's/return scan(" ".join(seg\[1:\]), st\["cwd"\], terr, own, depth + 1)/pass/'
  mutant evade "\$( ) não é aberto" 's/r = scan(bytes.fromhex(m.group(1)).decode(), st\["cwd"\], terr, own, depth + 1)/r = None/'
  mutant evade "crase não vira \$( )" 's/cmd, out, i = BACKTICK.sub(r"$(\\1)", cmd), \[\], 0/cmd, out, i = cmd, [], 0/'
  mutant evade "parêntese dentro do \$( ) não é contado" 's/d + (cmd\[k\] == "(") - /d - /'
  mutant evade "\$( ) de heredoc sem aspas é ignorado" 's/("" if m.group(2) else/("" if True else/'
  mutant evade "find -exec não é aberto" 's/if t in ("-exec", "-execdir", "-ok", "-okdir"):/if False:/'
  mutant evade "command/env/sudo/xargs não são descascados" 's/elif os.path.basename(seg\[0\]) in WRAP:/elif False:/'
  mutant pass "corpo de heredoc é tratado como comando" 's/hide(HEREDOC.sub(heredoc, cmd))/hide(cmd)/'
  mutant evade "pontuação colada ); engole a próxima palavra" 's/for pc in PIECE.findall(tok):/for pc in [tok]:/'
  mutant tools "Edit/Write não são vigiados" 's/    if tool in TOOLS_FILE:/    if False:/'
  mutant closed "falha do guarda vira liberado" '/o guarda falhou/{n;s/return 2/return 0/;}'
  mutant block "bloqueio sai 0 em vez de 2" '/print(message(hit/{n;s/return 2/return 0/;}'
  mutant closed "sem projeto, o cwd vira clone próprio" 's/p = os.path.realpath(proj) if proj else ""/p = os.path.realpath(proj or os.getcwd())/'
  mutant evade "stash push com 'stash list' na mensagem vira leitura" 's/(sub == "stash" and first in ("list", "show"))/(sub == "stash")/'
  mutant closed "branch com argumento vira leitura" 's/return all(t in LIST_FLAGS\[sub\] for t in rest)/return True/'
  mutant closed "JSON ruim que cita git passa" 's/if not re.search(r"git|file_path|notebook_path", raw):/if True:/'
  mutant check "selfcheck só confere o Bash" 's/for tool in ("Bash",) + tuple(TOOLS_FILE):/for tool in ("Bash",):/'
  mutant check "selfcheck aceita hook que chama outro arquivo" 's/me in h.get("command", "") and/True and/'
  mutant check "selfcheck não exige '|| exit 2'" 's/ and h\["command"\].endswith("|| exit 2")//'
  mutant check "selfcheck ignora disableAllHooks" 's/if s.get("disableAllHooks"):/if False:/'
  echo "-- contra um stub que só sai 0 (o servidor ANTES desta fatia)"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub"; chmod +x "$T/stub"; printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$T/stub.py"
  r=$(RCG_MUTANT=1 RCG_ONLY="block,evade,closed,tools,msg,check" RCG_UNDER_TEST="$T/stub.py" bash "$0" 2>&1 | tail -1); echo "stub: $r"
  case "$r" in "RESULT 0/"*|"") ok 1 "stub deveria falhar quase tudo ($r)";; *) ok 0 "stub falha os casos ($r)";; esac
  echo "== final: $((n-fails))/$n ok =="
}
[ "$fails" = 0 ]
