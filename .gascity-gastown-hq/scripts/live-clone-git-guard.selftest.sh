#!/usr/bin/env bash
# live-clone-git-guard.selftest.sh (ga-9jiq86) — hermético: o "clone vivo" é um repositório git de mktemp, nada toca o clone de verdade.
#
# Contents
#   O que prova · Grupos · Controle negativo (mutantes) · Variáveis
#
# O QUE PROVA. O incidente (ga-9jiq86): o clone vivo de produção do WA ficou em HEAD destacado por dias porque uma sessão do Claude rodou
#   `git checkout --detach <sha>` com o cwd lá dentro (reflog 21/10 e 24/10; o 10/10 foi um `--detach` sem volta). Aqui o guarda real
#   (python3 -I <guarda>) recebe o JSON de PreToolUse que o Claude Code manda e tem que:
#   block — recusar (exit 2) toda forma de checkout/switch que tira o HEAD do `main` do clone vivo: por cwd, `-C`, `cd … &&`, `--git-dir`,
#           subpasta do clone, `bash -c`, `eval`, subshell, depois de outro comando; --detach, SHA, origin/main, outra branch, -b/-c;
#   pass  — liberar o que NÃO tira o HEAD do main (voltar ao `main`, restaurar ARQUIVO com `--`, ler, mergear, `worktree add --detach`),
#           o MESMO checkout num clone aninhado (crew/x), num worktree ligado e fora do clone vivo, e comando que só CITA o checkout;
#   open  — falhar ABERTO: stdin que não é JSON, ferramenta que não é Bash, diretório que não sei resolver, o módulo do parser que não
#           carrega (e nesse caso gravar ERROR no log) e log que não grava NÃO podem virar "bloqueado": é trava contra engano, não sandbox;
#           e o que se libera SEM saber onde o git roda (sessão fora do vivo) fica CONTADO: uma linha result=UNRESOLVED, exit 0 (dentro do vivo, barra);
#   log   — cada bloqueio vira UMA linha em LCG_LOG com a sessão/alias de quem tentou, e a mensagem diz o que viu e o que fazer;
#   self  — `--selfcheck [settings.json]`: 0 só se o guarda decide como deveria E (com o settings) todo PreToolUse de Bash é exatamente
#           `python3 -I <guarda>`; 1 caso contrário.
#   No commit ANTERIOR a este o guarda não existe: toda asserção falha lá — é o "teste que falha hoje" que o bead pede. O grupo
#   MUTANTES prova que as asserções não são vácuas: cada mutação do guarda (substituição exata numa cópia) faz o grupo que a cobre falhar,
#   e a cópia SEM mutação passa (controle: sem ele, "falhou" podia ser só o ambiente do mutante).
# Variáveis: LCG_UNDER_TEST (guarda a testar) · LCG_ONLY (block|pass|open|log|self) · LCG_NO_MUTANTS=1 · LCG_RCG (parser; padrão: o vizinho)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${LCG_UNDER_TEST:-$HERE/live-clone-git-guard.py}"
export LCG_RCG="${LCG_RCG:-$HERE/remote-clone-guard.py}"   # explícito: a cópia de um mutante mora em outra pasta e não acha o vizinho
RCG="$LCG_RCG"
T=$(cd "$(mktemp -d /tmp/lcg.XXXXXX)" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
export HOME="$T/home"; unset LCG_ROOTS LCG_LOG GC_CITY_PATH GC_SESSION_NAME GC_ALIAS GC_AGENT GIT_DIR GIT_WORK_TREE
mkdir -p "$HOME/gt"
LIVE="$T/gt/whatsapp_automation"; WT="$T/scratch/review"; OUT="$T/outro/repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$LIVE/scripts" "$LIVE/crew/x" "$OUT" "$T/scratch"
git -C "$LIVE" init -q -b main && git -C "$LIVE" commit -q --allow-empty -m um && git -C "$LIVE" commit -q --allow-empty -m dois
SHA=$(git -C "$LIVE" rev-parse --short HEAD)
git -C "$LIVE/crew/x" init -q -b main && git -C "$LIVE/crew/x" commit -q --allow-empty -m c   # clone ANINHADO: tem .git próprio
git -C "$LIVE" worktree add -q --detach "$WT" HEAD                                              # worktree LIGADO, fora do clone vivo
git -C "$OUT" init -q -b main
ln -s "$LIVE" "$HOME/gt/whatsapp_automation"   # a raiz PADRÃO do guarda (~/gt/whatsapp_automation) aponta para o clone vivo de teste
export LCG_ROOTS="$LIVE" LCG_LOG="$T/guard.log"
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then [ "${LCG_QUIET:-0}" = 1 ] || echo "ok   $2"; else [ "${LCG_QUIET:-0}" = 1 ] || echo "FAIL $2"; fails=$((fails+1)); fi; }
grp() { [ -z "${LCG_ONLY:-}" ] || [ "$LCG_ONLY" = "$1" ]; }
mk() { jq -cn --arg t "$1" --arg c "$2" --arg k "$3" --arg v "$4" '{tool_name: $t, cwd: $c, tool_input: {($k): $v}}'; }   # mk TOOL CWD CAMPO VALOR (jq: 18 ms; python3 spawn: ~90)
run() { python3 -I "$P" >"$T/o" 2>"$T/err"; RC=$?; }                 # run < json  → RC, $T/o, $T/err
# bloqueio = exit 2 COM a mensagem do guarda: `python3 -I <arquivo que não existe>` também sai 2, e sem esta exigência o teste passava contra NADA
blocked() { [ "$RC" = 2 ] && grep -q 'HOOK BLOCK: live-clone-git-guard' "$T/err"; }
b() {  # b QUERO "descrição" "comando" [cwd]   (cwd padrão: o clone vivo — o caso do incidente)
  run < <(mk Bash "${4-$LIVE}" command "$3"); if [ "$1" = 2 ]; then blocked; else [ "$RC" = 0 ]; fi; ok $? "$2 (rc=$RC, queria $1)"
}

if grp block; then
b 2 "block: git checkout --detach <sha> no cwd (a forma de 24/10)"          "git checkout --detach $SHA"
b 2 "block: git checkout <sha> (restaurar por SHA mantém o HEAD solto)"     "git checkout $SHA"
b 2 "block: git switch --detach (a forma sem volta de 10/10)"               "git switch --detach"
b 2 "block: git checkout --detach sem argumento"                            "git checkout --detach"
b 2 "block: git switch -d"                                                  "git switch -d $SHA"
b 2 "block: git checkout --detach main (destacado na ponta do main)"        "git checkout --detach main"
b 2 "block: git checkout main --detach (flag depois do nome)"               "git checkout main --detach"
b 2 "block: git checkout origin/main"                                       "git checkout origin/main"
b 2 "block: git checkout HEAD~1"                                            "git checkout HEAD~1"
b 2 "block: git checkout outra-branch"                                      "git checkout feature"
b 2 "block: git checkout -b nova"                                           "git checkout -b nova"
b 2 "block: git checkout -fb nova (flags juntas)"                           "git checkout -fb nova"
b 2 "block: git checkout -B nova"                                           "git checkout -B nova"
b 2 "block: git checkout --orphan x"                                        "git checkout --orphan x"
b 2 "block: git checkout -f main não é a volta liberada (só -q)"            "git checkout -f main"
b 2 "block: git checkout --detach <sha> -- (o -- no fim não vira modo arquivo)" "git checkout --detach $SHA --"
b 2 "block: git switch outra"                                               "git switch feature"
b 2 "block: git switch -c nova"                                             "git switch -c nova"
b 2 "block: git switch -- main (forma que não conheço)"                     "git switch -- main"
b 2 "block: git -C <vivo> checkout --detach, de outro cwd"                  "git -C $LIVE checkout --detach $SHA" "$OUT"
b 2 "block: git -C <vivo> switch --detach, de outro cwd"                    "git -C $LIVE switch --detach" "$OUT"
b 2 "block: cd <vivo> && git checkout --detach (a forma do revisor)"        "cd $LIVE && git checkout --detach $SHA" "$OUT"
b 2 "block: cd <vivo>; git checkout"                                        "cd $LIVE; git checkout --detach $SHA" "$OUT"
b 2 "block: ( cd <vivo> && git checkout ) em subshell"                      "( cd $LIVE && git checkout --detach $SHA )" "$OUT"
b 2 "block: subpasta do clone vivo (cwd)"                                   "git checkout --detach $SHA" "$LIVE/scripts"
b 2 "block: subpasta do clone vivo (-C)"                                    "git -C $LIVE/scripts checkout --detach $SHA" "$OUT"
b 2 "block: -C relativo resolvido contra o cwd"                             "git -C ../gt/whatsapp_automation checkout --detach $SHA" "$T/outro"
b 2 "block: depois de outro comando"                                        "echo oi; git status; git checkout --detach $SHA"
b 2 "block: no meio de um &&"                                               "git fetch -q && git checkout --detach origin/main && git status"
b 2 "block: bash -c"                                                        "bash -c 'git checkout --detach $SHA'"
b 2 "block: bash -c com cd"                                                 "bash -c 'cd $LIVE && git checkout --detach $SHA'" "$OUT"
b 2 "block: eval"                                                           "eval \"git -C $LIVE checkout --detach $SHA\"" "$OUT"
b 2 "block: git --no-pager checkout"                                        "git --no-pager checkout --detach $SHA"
b 2 "block: git -c k=v checkout"                                            "git -c advice.detachedHead=false checkout --detach $SHA"
b 2 "block: VAR=x git checkout"                                             "FOO=1 git checkout --detach $SHA"
b 2 "block: env git checkout"                                               "env FOO=1 git checkout --detach $SHA"
b 2 "block: --work-tree=<vivo>"                                             "git --git-dir=$LIVE/.git --work-tree=$LIVE checkout --detach $SHA" "$OUT"
b 2 "block: --work-tree=<vivo> sozinho (escreve os arquivos no vivo)"       "git --work-tree=$LIVE checkout --detach $SHA" "$OUT"
b 2 "block: GIT_WORK_TREE=<vivo>"                                           "GIT_WORK_TREE=$LIVE git checkout --detach $SHA" "$OUT"
b 2 "block: --work-tree $LIVE (valor no token seguinte)"                    "git --work-tree $LIVE checkout --detach $SHA" "$OUT"
b 2 "block: --git-dir=<vivo>/.git de uma pasta qualquer (o checkout cai no cwd e MOVE o HEAD do vivo)" "git --git-dir=$LIVE/.git checkout --detach $SHA" "$OUT"
b 2 "block: GIT_DIR=<vivo>/.git"                                            "GIT_DIR=$LIVE/.git git checkout --detach $SHA" "$OUT"
b 2 "block: checkout de arquivo e depois o --detach (o 2º trecho vale)"     "git checkout -- f; git checkout --detach $SHA"
b 2 "block: voltar ao main e depois destacar de novo"                       "git checkout main && git checkout --detach $SHA"
b 2 "block: cd para fora e de volta ao vivo"                                "cd $WT && cd $LIVE && git checkout --detach $SHA" "$OUT"
b 2 "block: função que faz o checkout, chamada no vivo"                     "f() { git checkout --detach $SHA; }; cd $LIVE && f" "$OUT"
( unset LCG_ROOTS; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); blocked ); ok $? "block: sem LCG_ROOTS a raiz padrão é ~/gt/whatsapp_automation"
( LCG_ROOTS=""; export LCG_ROOTS; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); blocked ); ok $? "block: LCG_ROOTS vazio vale como ausente (raiz padrão)"
( LCG_ROOTS="$OUT"; export LCG_ROOTS; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); [ "$RC" = 0 ] ); ok $? "block: LCG_ROOTS preenchido troca a lista (o vivo deixa de ser protegido)"
b 2 "block: git checkout em find -exec no vivo"                             "find $LIVE -maxdepth 0 -exec git checkout --detach $SHA \\;" "$LIVE"
b 2 "block: git checkout <sha> -- (sem arquivo depois do -- o HEAD MOVE)"   "git checkout $SHA --"
b 2 "block: git checkout outra-branch -- (idem, nome desambiguado)"         "git checkout feature --"
b 2 "block: git checkout -b nova <sha> -- arquivo (o git recusa; o guarda não confia nisso)" "git checkout -b nova $SHA -- f"
b 2 "block: git checkout --det <sha> -- (abreviação do --detach, nada depois do --)" "git checkout --det $SHA --"
Q="'"; b 2 "block: git \$'\\x63heckout' --detach (ANSI-C esconde a palavra do pré-filtro, o parser decodifica)" "git \$${Q}\\x63heckout${Q} --detach $SHA"
b 2 "block: cd \$VAR && git checkout, com a sessão NO vivo (não sei onde roda)" 'cd "$WHERE" && git checkout --detach abc'
b 2 "block: git -C \$VAR checkout, com a sessão NO vivo"                    'git -C "$WHERE" checkout --detach abc'
b 2 "block: lançador opaco (flock) na frente do git, sessão NO vivo"        "flock $T/l git checkout --detach $SHA"
b 2 "block: eval aninhado além do limite do parser, sessão NO vivo"         "eval eval eval eval eval git checkout --detach $SHA"
run < <(mk Bash "$LIVE" command 'cd "$WHERE" && git checkout --detach abc'); blocked && grep -q 'não consegui ver' "$T/err" && grep -qF "$LIVE" "$T/err"; ok $? "block: o 'não sei' diz que não conseguiu ver a pasta e cita o clone vivo"
run < <(mk Bash "$LIVE" command "eval eval eval eval eval git checkout --detach $SHA"); blocked && grep -q 'não consegui ver' "$T/err" && grep -qF "eval eval eval eval eval git checkout --detach $SHA" "$T/err"; ok $? "block: o 'não sei' do aninhamento fundo cita o COMANDO (não o motivo interno do parser)"
fi

if grp pass; then
b 0 "pass: git checkout main (a volta)"                                     "git checkout main"
b 0 "pass: git checkout -q main"                                            "git checkout -q main"
b 0 "pass: git switch main"                                                 "git switch main"
b 0 "pass: git switch -q main"                                              "git switch -q main"
b 0 "pass: git -C <vivo> checkout main, de outro cwd"                       "git -C $LIVE checkout main" "$OUT"
b 0 "pass: cd <vivo> && git switch main"                                    "cd $LIVE && git switch main" "$OUT"
b 0 "pass: git checkout sem argumento (só mostra o estado)"                 "git checkout"
b 0 "pass: git checkout -- arquivo (não move o HEAD)"                       "git checkout -- scripts/x.sh"
b 0 "pass: git -C <worktree> atrás de lançador opaco, sessão no vivo (o -C absoluto resolve)" "flock $T/l git -C $WT checkout --detach $SHA" "$LIVE"
b 0 "pass: git checkout <sha> -- arquivo (não move o HEAD)"                 "git checkout $SHA -- scripts/x.sh"
b 0 "pass: git -C <vivo> checkout HEAD -- arquivo"                          "git -C $LIVE checkout HEAD -- f" "$OUT"
b 0 "pass: git status"                                                      "git status"
b 0 "pass: git log / show"                                                  "git log --oneline -3; git show $SHA:scripts"
b 0 "pass: git merge origin/main"                                           "git merge --ff-only origin/main"
b 0 "pass: git pull --ff-only"                                              "git pull --ff-only"
b 0 "pass: git branch -f main HEAD (conserto do Mayor, não destaca)"        "git branch -f main HEAD"
b 0 "pass: git worktree add --detach <fora> <sha> (o idioma seguro)"        "git -C $LIVE worktree add --detach $T/scratch/novo $SHA"
b 0 "pass: git -C <vivo> show <sha>:arquivo"                                "git -C $LIVE show $SHA:scripts" "$OUT"
b 0 "pass: git commit -m com 'checkout --detach' na mensagem"               "git commit -m 'git checkout --detach $SHA'"
b 0 "pass: echo 'git checkout --detach' (só cita)"                          "echo 'git checkout --detach $SHA'"
b 0 "pass: grep pelo texto do checkout"                                     "grep -rn 'checkout --detach' ."
b 0 "pass: heredoc que só contém o checkout (cat)"                          "cat <<'EOF'
git checkout --detach $SHA
EOF"
b 0 "pass: checkout --detach em clone ANINHADO (crew/x, .git próprio) por cwd" "git checkout --detach HEAD" "$LIVE/crew/x"
b 0 "pass: checkout --detach em clone ANINHADO por -C"                      "git -C $LIVE/crew/x checkout --detach HEAD" "$OUT"
b 0 "pass: checkout --detach em worktree LIGADO fora do vivo, por cwd"      "git checkout --detach $SHA" "$WT"
b 0 "pass: checkout --detach em worktree LIGADO por -C"                     "git -C $WT checkout --detach $SHA" "$LIVE"
b 0 "pass: cd <worktree> && checkout, estando no vivo"                      "cd $WT && git checkout --detach $SHA" "$LIVE"
b 0 "pass: checkout --detach em repositório qualquer"                       "git checkout --detach HEAD" "$OUT"
b 0 "pass: comando sem a palavra checkout/switch"                           "ls -la"
b 0 "pass: git switch em outro repositório"                                 "git switch -c x" "$OUT"
run < <(mk Edit "$LIVE" file_path "$LIVE/scripts/x.sh"); [ "$RC" = 0 ]; ok $? "pass: ferramenta Edit (o guarda só olha Bash)"
fi

if grp open; then
b 0 "open: cd \$VAR && git checkout (diretório que não resolvo)"            'cd "$WHERE" && git checkout --detach abc' "$OUT"
b 0 "open: git checkout num cwd que não existe e fora do vivo"              "git checkout --detach $SHA" "$T/nao/existe"
b 0 "open: lançador opaco (flock) com a sessão FORA do vivo → libera"       "flock $T/l git checkout --detach $SHA" "$OUT"
b 0 "open: eval aninhado além do limite com a sessão FORA do vivo → libera" "eval eval eval eval eval git checkout --detach $SHA" "$OUT"
b 0 "open: git -C \$VAR checkout com a sessão FORA do vivo → libera"        'git -C "$WHERE" checkout --detach abc' "$OUT"
nlog() { wc -l < "$T/guard.log" | tr -d ' '; }
: > "$T/guard.log"; run < <(mk Bash "$OUT" command 'cd "$WHERE" && git checkout --detach abc'); [ "$RC" = 0 ] && [ "$(nlog)" = 1 ] && grep -q 'result=UNRESOLVED' "$T/guard.log" && grep -q 'op=git checkout --detach abc' "$T/guard.log" && grep -qF "cwd=$OUT" "$T/guard.log"; ok $? "open: liberar sem saber onde roda deixa UMA linha result=UNRESOLVED com o op e o cwd, exit 0 (rc=$RC)"
: > "$T/guard.log"; run < <(mk Bash "$OUT" command "flock $T/l git checkout --detach $SHA"); [ "$RC" = 0 ] && grep -q 'result=UNRESOLVED' "$T/guard.log"; ok $? "open: lançador opaco liberado também é contado (UNRESOLVED)"
: > "$T/guard.log"; run < <(mk Bash "$OUT" command "eval eval eval eval eval git checkout --detach $SHA"); [ "$RC" = 0 ] && grep -q 'result=UNRESOLVED.*op=eval eval eval eval eval git checkout' "$T/guard.log"; ok $? "open: aninhado fundo demais liberado também é contado (UNRESOLVED, op = o comando)"
: > "$T/guard.log"; run < <(mk Bash "$OUT" command "git -C $WT checkout --detach $SHA; git checkout main; cd \"\$WHERE\" && git checkout main"); [ "$RC" = 0 ] && [ "$(nlog)" = 0 ]; ok $? "open: o que resolve (ou não move o HEAD) NÃO vira UNRESOLVED — a contagem não enche de ruído"
: > "$T/guard.log"; run < <(mk Bash "$LIVE" command 'cd "$WHERE" && git checkout --detach abc'); blocked && [ "$(nlog)" = 1 ] && grep -q 'result=BLOCK' "$T/guard.log"; ok $? "open: o 'não sei' barrado no vivo é UMA linha BLOCK, sem UNRESOLVED junto"
run < <(printf 'garbage not json: git checkout --detach'); [ "$RC" = 0 ]; ok $? "open: stdin que não é JSON (rc=$RC)"
run < /dev/null; [ "$RC" = 0 ]; ok $? "open: stdin vazio (rc=$RC)"
run < <(printf '{"tool_name":"Bash"}'); [ "$RC" = 0 ]; ok $? "open: Bash sem tool_input (rc=$RC)"
run < <(printf '{"tool_name":"Bash","tool_input":"git checkout --detach x"}'); [ "$RC" = 0 ] && [ ! -s "$T/err" ]; ok $? "open: tool_input texto em vez de objeto → libera sem traceback (rc=$RC)"
run < <(printf '{"tool_name":"Bash","tool_input":["git checkout --detach x"]}'); [ "$RC" = 0 ] && [ ! -s "$T/err" ]; ok $? "open: tool_input lista em vez de objeto → libera sem traceback (rc=$RC)"
run < <(printf '{"tool_name":"Bash","tool_input":{"command":"git checkout --detach x"}}'); [ "$RC" = 0 ]; ok $? "open: sem cwd e comando sem caminho (rc=$RC)"
: > "$T/guard.log"
( LCG_RCG="$T/nao-existe.py"; export LCG_RCG; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); [ "$RC" = 0 ] ); ok $? "open: parser que não carrega → libera, não bloqueia"
grep -q 'result=ERROR' "$T/guard.log"; ok $? "open: parser que não carrega → ERROR no log (não some em silêncio)"
printf 'def res(*a, **k):\n    return None\ndef scan(*a, **k):\n    raise RuntimeError("boom")\n' > "$T/boom.py"   # parser que CARREGA mas cujo scan levanta
: > "$T/guard.log"
( LCG_RCG="$T/boom.py"; export LCG_RCG; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); [ "$RC" = 0 ] ); ok $? "open: parser que carrega mas levanta exceção na decisão → libera, não bloqueia"
grep -q 'result=ERROR.*decide: boom' "$T/guard.log"; ok $? "open: exceção na decisão → ERROR decide: no log"
( LCG_LOG="$T/sem/pasta/log"; export LCG_LOG; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); blocked ); ok $? "open: log que não grava NÃO muda o veredito (continua bloqueando)"
if [ "$P" = "$HERE/live-clone-git-guard.py" ]; then   # só com o guarda de verdade: a cópia de um mutante não mora ao lado do parser
  ( unset LCG_RCG; run < <(mk Bash "$LIVE" command "git checkout --detach $SHA"); blocked ); ok $? "open: sem LCG_RCG o parser é achado ao lado do guarda"
fi
fi

if grp log; then
: > "$T/guard.log"
GC_SESSION_NAME=gate-reviewer-x GC_ALIAS=gate.reviewer-7 GC_AGENT=gastown.gate-reviewer run < <(mk Bash "$LIVE" command "git checkout --detach $SHA")
grep -q 'HOOK BLOCK: live-clone-git-guard' "$T/err";             ok $? "msg: abre com o prefixo [HOOK BLOCK: live-clone-git-guard]"
grep -q 'NÃO É CANCELAMENTO DO USUÁRIO' "$T/err";                 ok $? "msg: diz que não é cancelamento do usuário"
grep -q "git checkout --detach $SHA" "$T/err";                    ok $? "msg: cita o comando que viu"
grep -qF "$LIVE" "$T/err";                                        ok $? "msg: cita o clone vivo"
grep -q 'worktree add --detach' "$T/err";                         ok $? "msg: ensina o idioma seguro (worktree add --detach)"
grep -q 'git checkout main' "$T/err";                             ok $? "msg: ensina a volta (git checkout main)"
[ "$(wc -l < "$T/guard.log" | tr -d ' ')" = 1 ];                  ok $? "log: UMA linha por bloqueio"
grep -q 'result=BLOCK' "$T/guard.log" && grep -q "alias=gate.reviewer-7" "$T/guard.log" && grep -q 'agent=gastown.gate-reviewer' "$T/guard.log"; ok $? "log: result=BLOCK + alias/agente de quem tentou"
grep -q 'session=gate-reviewer-x' "$T/guard.log";                 ok $? "log: session= de quem tentou"
grep -qF "root=$LIVE" "$T/guard.log";                             ok $? "log: root= é o clone vivo"
b 0 "log: o que libera passa" "git checkout main"
[ "$(wc -l < "$T/guard.log" | tr -d ' ')" = 1 ];                  ok $? "log: liberar NÃO acrescenta linha"
: > "$T/guard.log"; (mkdir -p "$T/cidade/.gc/logs"; unset LCG_LOG; GC_CITY_PATH="$T/cidade"; export GC_CITY_PATH; run < <(mk Bash "$LIVE" command "git switch --detach"); blocked && grep -q 'result=BLOCK' "$T/cidade/.gc/logs/live-clone-git-guard.log" ); ok $? "log: sem LCG_LOG grava em \$GC_CITY_PATH/.gc/logs/live-clone-git-guard.log"
fi

if grp self; then
python3 -I "$P" --selfcheck >"$T/o" 2>"$T/err"; [ $? = 0 ] && grep -q 'selfcheck: ok' "$T/o"; ok $? "self: --selfcheck sem settings → ok"
good="$T/good.json"; printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 -I %s"}]}]}}' "$P" > "$good"
python3 -I "$P" --selfcheck "$good" >"$T/o" 2>"$T/err"; ok $? "self: settings com o hook exato → ok"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 -I %s","if":"Bash(git -C *)"}]}]}}' "$P" > "$T/if.json"
python3 -I "$P" --selfcheck "$T/if.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "self: hook com \`if\` (só dispararia em git -C) → 1"
printf '{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"python3 -I %s"}]}]}}' "$P" > "$T/read.json"
python3 -I "$P" --selfcheck "$T/read.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "self: hook só no Read, nenhum no Bash → 1"
printf '{"disableAllHooks":true,"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 -I %s"}]}]}}' "$P" > "$T/dis.json"
python3 -I "$P" --selfcheck "$T/dis.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "self: disableAllHooks ligado → 1"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 -I %s || true"}]}]}}' "$P" > "$T/or.json"
python3 -I "$P" --selfcheck "$T/or.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "self: \`|| true\` no fim apagaria o exit 2 → 1"
printf 'garbage not json' > "$T/bad.json"
python3 -I "$P" --selfcheck "$T/bad.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "self: settings ilegível → 1"
python3 -I "$P" --selfcheck "$T/nao-existe.json" >"$T/o" 2>"$T/err"; [ $? = 1 ]; ok $? "self: settings que não existe → 1"
( LCG_RCG="$T/nao-existe.py"; export LCG_RCG; python3 -I "$P" --selfcheck >"$T/o" 2>"$T/err"; [ $? = 1 ] ); ok $? "self: parser que não carrega → 1 (o ativador vê; a sessão não cai)"
fi

# ── MUTANTES ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# cada mutante é o guarda com UMA proteção arrancada (substituição exata numa cópia; trecho que não existe = mutante vácuo = falha). O grupo que
# cobre a proteção roda contra a cópia, em modo quieto, e TEM que falhar. O controle (cópia sem mutação) TEM que passar.
if [ "${LCG_NO_MUTANTS:-0}" != 1 ] && [ -z "${LCG_ONLY:-}" ]; then
  mn=0
  child() {  # child <arquivo> <grupo>  → rc do selftest daquele grupo contra o arquivo
    LCG_ONLY="$2" LCG_NO_MUTANTS=1 LCG_QUIET=1 LCG_UNDER_TEST="$1" LCG_RCG="$RCG" bash "$0" >/dev/null 2>&1
  }
  cp "$P" "$T/ctl.py"
  for g in block pass open log self; do ( child "$T/ctl.py" "$g"; echo $? > "$T/ctl.$g" ) & done; wait
  for g in block pass open log self; do [ "$(cat "$T/ctl.$g" 2>/dev/null)" = 0 ]; ok $? "controle: a cópia SEM mutação passa o grupo $g"; done
  # os filhos rodam em paralelo (no máximo $JOBS ao mesmo tempo): sequenciais passavam de 3 min. Cada um tem o SEU mktemp; o veredito de cada um vai para $T/rc.N e é lido depois, em ordem.
  JOBS="${LCG_JOBS:-6}"; names=(); groups=()
  mut() {  # mut "nome" grupo "trecho exato" "troca"
    local k=$((++mn)) cp="$T/m.$((mn)).py"
    names[$k]="$1"; groups[$k]="$2"
    python3 - "$P" "$cp" "$3" "$4" <<'PY' || { echo vacuo > "$T/rc.$k"; return; }
import sys
src = open(sys.argv[1]).read()
assert src.count(sys.argv[3]) == 1, f"{src.count(sys.argv[3])} ocorrências"
open(sys.argv[2], "w").write(src.replace(sys.argv[3], sys.argv[4]))
PY
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.2; done
    ( child "$cp" "$2"; echo $? > "$T/rc.$k" ) &
  }
  mut "sem switch"                          block 'HEAD_MOVERS = ("checkout", "switch")' 'HEAD_MOVERS = ("checkout",)'
  mut "sem checkout"                        block 'HEAD_MOVERS = ("checkout", "switch")' 'HEAD_MOVERS = ("switch",)'
  mut "nunca protege"                       block 'return p if p in roots else None' 'return None'
  mut "-C ignorado"                         block 'cwd, i = rcg.res(seg[i + 1], cwd), i + 2' 'i += 2'
  mut "--git-dir ignorado"                  block 'cands.append(os.path.dirname(gdp))' 'pass'
  mut "--work-tree ignorado"                block 'wt = v' 'pass'
  mut "main liberado com qualquer flag"     block 'and all(f in QUIET for f in flags)' ''
  mut "flags liberadas inclui --detach"     block 'QUIET = {"-q", "--quiet"}' 'QUIET = {"-q", "--quiet", "--detach", "-f"}'
  mut "-- libera até -b/--detach"           block 'return any(BRANCHY.fullmatch(a) for a in before if a.startswith("-"))' 'return False'
  mut "modo arquivo sem -- não existe"      pass  'if sub == "checkout" and "--" in rest and rest[rest.index("--") + 1:]:' 'if False:'
  mut "checkout sem argumento bloqueia"     pass  'if not rest:' 'if False:'
  mut "clone aninhado conta como vivo"      pass  'if os.path.exists(os.path.join(p, ".git")):' 'if p in roots:'
  mut "falha do guarda fecha"               open  'return 0  # falhou' 'return 2  # falhou'
  mut "parser que não carrega bloqueia"     open  'return 0  # sem parser' 'return 2  # sem parser'
  mut "parser que não carrega some do log"  open  'log("ERROR", "", "parser: " + str(e)[:100], "")' 'pass'
  mut "raiz padrão errada"                  block '"~/gt/whatsapp_automation"' '"/nao/existe"'
  mut "sem log de BLOCK"                    log   'log("BLOCK", root, op, inp.get("cwd") or "")' 'pass'
  mut "sem sessão no log"                   log   '"session=" + os.environ.get("GC_SESSION_NAME", "")' '"session="'
  mut "mensagem sem o idioma seguro"        log   'worktree add --detach <pasta-fora-do-clone>' 'worktree add <pasta-fora-do-clone>'
  mut "mensagem sem a volta"                log   'a volta é liberada: git checkout main.' 'a volta é liberada: git status.'
  mut "selfcheck ignora o if"               self  'set(h) <= {"type", "command", "timeout"}' 'True'
  mut "selfcheck aceita sufixo"             self  'h.get("command", "").strip() == "python3 -I " + me' 'h.get("command", "").strip().startswith("python3 -I " + me)'
  mut "selfcheck ignora disableAllHooks"    self  'if s.get("disableAllHooks"):' 'if False:'
  mut "cwd da sessão não vale no não-sei"  block 'if cands[0] is None:' 'if False:'
  mut "aninhado fundo demais libera"        block '    if res:  # (None, motivo)' '    if False:  # (None, motivo)'
  mut "arquivo sem pathspec conta"          block 'if sub == "checkout" and "--" in rest and rest[rest.index("--") + 1:]:' 'if sub == "checkout" and "--" in rest:'
  mut "mensagem do não-sei some"            block 'não consegui ver em que pasta' 'bloqueado em que pasta'
  mut "UNRESOLVED não grava"                open  'log("UNRESOLVED", "", blind[0], inp.get("cwd") or "")' 'pass'
  mut "não-sei fora do vivo não conta"      open  'blind.append(op)  # sessão fora do vivo: libera, mas conta' 'pass'
  mut "aninhado fundo fora do vivo não conta" open 'blind.append(op)  # aninhado fundo demais fora do vivo: libera, mas conta' 'pass'
  mut "prefiltro ignora ANSI-C"             block 'if ANSI_C not in cmd and not PREFILTER.search' 'if not PREFILTER.search'
  wait
  for k in $(seq 1 "$mn"); do
    rc=$(cat "$T/rc.$k" 2>/dev/null || echo ausente)
    case "$rc" in
      vacuo) ok 1 "mutante '${names[$k]}': o trecho a trocar não existe uma vez só no guarda (mutante vácuo)";;
      0|ausente) ok 1 "mutante '${names[$k]}' NÃO fez o grupo ${groups[$k]} falhar (rc=$rc)";;
      *) ok 0 "mutante '${names[$k]}' faz o grupo ${groups[$k]} falhar (rc=$rc)";;
    esac
  done
fi

echo "---"; echo "live-clone-git-guard.selftest: $((n - fails))/$n ok, $fails FAIL"
[ "$fails" = 0 ]
