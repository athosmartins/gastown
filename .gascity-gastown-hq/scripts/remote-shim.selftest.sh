#!/usr/bin/env bash
# remote-shim.selftest.sh — hermético: cidade, rigs e bd/gc/gate-done FALSOS em mktemp; nada fala com o mini de verdade, o servidor nem o Dolt.
# É o teste do LADO DO MINI do atalho (remote-shim-wrapper.py, ga-2hd02v.1.2.1). O lado do servidor e a cadeia inteira são do
# remote-shim-client.selftest.sh (ga-2hd02v.1.2.2). Só a seção "sshd de verdade" sobe um sshd sem privilégio em 127.0.0.1 numa porta livre
# (e some no fim); se ele não subir, a seção diz SKIP e o resumo conta quantos casos ficaram sem rodar — não conta como passou.
#
# Contents
#   Casos · Controle negativo · Mutantes (como rodar)
#
# CASOS: cada forma da LISTA roda com o argv canônico no bd/gc falso (cwd, BEADS_ACTOR, identidade) · RECUSA (77, com o motivo, sem chamar o falso)
#   de tudo fora da lista e das variações dos 3 novos · protocolo, identidade (alias, agent, sessão, template), config e metadata tortos · log que
#   não grava → não executa · HIGIENE de ambiente, timeout mata o grupo, auditoria · SSHD DE VERDADE: a chave só roda o wrapper (nem touch, shell,
#   -R, pty; from= que não casa nega; chave válida não listada é negada e, listada, a MESMA entra) · DOC: `list` == bloco da lista do runbook
# CONTROLE NEGATIVO: apagar uma regra, os prefixos de metadata, o formato do id ou a lista de env faz o MESMO caso se comportar diferente.
# MUTANTES: WRAPPER_UNDER_TEST=<cópia com UMA guarda apagada> FAILFAST=1 bash remote-shim.selftest.sh; a campanha inteira é
#   `python3 -I scripts/remote-shim.mutants.py` (fatia 1.2.2).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/remote-shim.selftest.lib.sh"
echo "== lista: o que roda (e o argv que o bd/gc de verdade recebe)"
allowed "bd show --json" bd show ga-2hd02v.1.2 --json
lastis "bd	cwd=$CITY	actor=gastown.dog-1	alias=gastown.dog-1" && lastis "argv=[show][ga-2hd02v.1.2][--json]"; ok $? "  cwd=cidade, BEADS_ACTOR=alias, argv canônico"
has "$T/out" "FAKE-bd-OUT"; ok $? "  a saída do comando volta ao cliente"
allowed "bd -C <nome do rig>" bd -C wa_rig show wa-1; lastis "cwd=$WA" && lastis "argv=[show][wa-1]"; ok $? "  cwd=rig e o -C não vai ao bd (o cwd faz o papel)"
allowed "bd -C <caminho real do rig>" bd -C "$WA" show wa-1; lastis "cwd=$WA"; ok $? "  cwd=rig"
allowed "bd -C ." bd -C . show ga-1; lastis "cwd=$CITY"; ok $? "  cwd=cidade"
allowed "bd list com todas as flags (curtas viram longas)" bd list --json -s open,in_progress -a gastown.dog-1 -l x:a -l b --parent ga-1 -n 5 --id ga-1,wa-2
lastis "argv=[list][--json][--status][open,in_progress][--assignee][gastown.dog-1][--label][x:a][--label][b][--parent][ga-1][--limit][5][--id][ga-1,wa-2]"; ok $? "  argv canônico"
allowed "bd list sem flag" bd list
allowed "bd update --set-metadata (repetida, com quebra de linha)" bd update ga-1 --set-metadata story.a=b --set-metadata $'athos.acao=linha1\nlinha2' --json
lastis "argv=[update][ga-1][--set-metadata][story.a=b][--set-metadata][athos.acao=linha1\\nlinha2][--json]"; ok $? "  argv canônico, valor multilinha inteiro"
allowed "bd update com chave story.x" bd update ga-1 --set-metadata story.resumo=ok
allowed "bd comment <id> palavras..." bd comment ga-1 hello there world; lastis "argv=[comment][ga-1][hello][there][world]"; ok $? "  argv canônico"
allowed "bd comment com texto que começa com '-'" bd comment ga-1 -- '- item' ; lastis "argv=[comment][ga-1][--][- item]"; ok $? "  o -- do cliente segue na mesma ordem"
printf 'texto vindo do stdin' > "$T/stdin.txt"; STDIN_FILE="$T/stdin.txt" allowed "bd comment <id> --stdin" bd comment ga-1 --stdin
has "$T/out" "STDIN<texto vindo do stdin>"; ok $? "  o stdin chega ao comando"
allowed "bd close --reason" bd close ga-1 --reason 'feito ok'; lastis "argv=[close][ga-1][--reason][feito ok]"; ok $? "  argv canônico"
allowed "bd close -r --json" bd close wa-1.2.3 -r x --json
allowed "gc mail check --inject" gc mail check --inject; lastis "argv=[mail][check][--inject]"; ok $? "  argv canônico"
allowed "gc mail check" gc mail check
allowed "gc mail inbox --json" gc mail inbox --json
allowed "gc mail read" gc mail read ga-abc
allowed "gc mail peek --json" gc mail peek ga-abc --json
allowed "gc mail archive 2 ids" gc mail archive ga-a ga-b
allowed "gc mail send" gc mail send mayor -s Assunto -m 'corpo -com traço'; lastis "argv=[mail][send][mayor][--subject][Assunto][--message][corpo -com traço]"; ok $? "  argv canônico"
allowed "gc mail reply" gc mail reply ga-abc -m ok
allowed "gc session nudge" gc session nudge gastown.mayor olá mundo --delivery queue; lastis "argv=[session][nudge][gastown.mayor][olá][mundo][--delivery][queue]"; ok $? "  argv canônico"
allowed "gc session nudge com a flag ANTES do alvo (o gc aceita flag em qualquer posição)" gc session nudge --delivery queue gastown.mayor oi; lastis "argv=[session][nudge][--delivery][queue][gastown.mayor][oi]"; ok $? "  argv canônico"
# ids no formato REAL de produção: 653/653 ids de mail/wisp medidos na cidade (14/10) são <prefixo>-wisp-<sufixo>, com DOIS hífens
allowed "gc mail read com id real de mail (ga-wisp-…)" gc mail read ga-wisp-0i6hr; lastis "argv=[mail][read][ga-wisp-0i6hr]"; ok $? "  argv canônico"
allowed "gc mail peek --json com id real" gc mail peek ga-wisp-7afbf --json
allowed "gc mail archive com 2 ids reais" gc mail archive ga-wisp-0i6hr ga-wisp-2mpem9c
allowed "gc mail reply com id real" gc mail reply ga-wisp-0i6hr -m ok
allowed "bd show em wisp" bd show ga-wisp-072rx --json
allowed "bd comment em wisp" bd comment ga-wisp-072rx feito
allowed "bd close em wisp" bd close ga-wisp-072rx --reason ok
allowed "bd update em wisp" bd update ga-wisp-072rx --set-metadata story.a=b
allowed "bd list --parent/--id com ids de wisp" bd list --parent ga-wisp-0i6hr --id ga-wisp-072rx,wa-wisp-0a0mav
HOOKENV='{"GC_ALIAS":"gastown.dog-1","GC_AGENT":"gastown.dog-1","GC_SESSION_NAME":"dog-gavycydh","GC_MANAGED_SESSION_HOOK":"1","GC_HOOK_EVENT_NAME":"SessionStart"}'
b=$(calls); wrap "$(rq gc "$HOOKENV" prime --hook)"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "hook=1/SessionStart" && lastis "argv=[prime][--hook]"; ok $? "gc prime --hook (decisão do Mayor) + GC_MANAGED_SESSION_HOOK/GC_HOOK_EVENT_NAME chegam ao gc"
b=$(calls); wrap "$(rq gc "$HOOKENV" prime --hook --hook-format codex)"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "argv=[prime][--hook][--hook-format][codex]"; ok $? "gc prime --hook --hook-format codex (a forma que o hook REAL do mini manda)"
allowed "gc handoff --auto (decisão do Mayor)" gc handoff --auto; lastis "argv=[handoff][--auto]"; ok $? "  argv canônico"
allowed 'gc handoff --auto "context cycle" (a forma que o hook REAL manda)' gc handoff --auto "context cycle"; lastis "argv=[handoff][--auto][context cycle]"; ok $? "  argv canônico"
allowed "gc nudge drain --inject (decisão do Mayor)" gc nudge drain --inject; lastis "argv=[nudge][drain][--inject]"; ok $? "  argv canônico"
allowed "gate-done (executável configurado)" gate-done; lastis "gatedone	cwd=$CITY"; ok $? "  roda o gatedone da config, na cidade"
call bd close ga-1 --reason FAIL7; [ "$RC" = 7 ] && has "$T/err" "fake-err"; ok $? "o código de saída (7) e o stderr do comando passam adiante"
b=$(calls); call gc mail check --inject; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && [ ! -e "$T/PWNED-bashenv" ] && [ ! -e "$T/PWNED-pythonpath" ]; ok $? "higiene: o comando RODOU e BASH_ENV e PYTHONPATH do ambiente de entrada não executaram nada (sem o 'rodou', um pedido recusado também deixaria os arquivos sem nascer)"
lastis "bashenv=UNSET	ld=UNSET	citypath=UNSET	pypath=UNSET"; ok $? "higiene: BASH_ENV, LD_PRELOAD, GC_CITY_PATH e PYTHONPATH não chegam ao filho"

echo "== lista: o que NÃO roda (77 + motivo + o bd/gc falso não é chamado)"
denied "bd sql" "comando fora da lista" bd sql "select 1"
denied "bd sql sem argumento" "comando fora da lista" bd sql
denied "bd dolt" "comando fora da lista" bd dolt push
denied "bd create" "comando fora da lista" bd create "x"
denied "bd (sem subcomando)" "comando fora da lista" bd
denied "bd show --current" "flag fora da lista" bd show ga-1 --current
denied "bd show sem id" "faltam argumentos" bd show
denied "bd show com dois ids" "argumento a mais" bd show ga-1 ga-2
denied "bd list --all" "flag fora da lista" bd list --all
denied "bd list --limit 0 (tudo)" "fora do formato" bd list --limit 0
denied "bd list --limit 201" "fora do formato" bd list --limit 201
denied "bd list --label-regex" "flag fora da lista" bd list --label-regex x
denied "bd list --status repetida" "flag repetida" bd list --status open --status closed
denied "bd list --flag=valor" "flag fora da lista" bd list --limit=5
denied "bd update sem --set-metadata" "falta --set-metadata" bd update ga-1 --json
denied "bd update --status closed" "flag fora da lista" bd update ga-1 --status closed
denied "bd update --set-metadata gc.routed_to" "fora do formato" bd update ga-1 --set-metadata gc.routed_to=x
denied "bd update --set-metadata pilot.x" "fora do formato" bd update ga-1 --set-metadata pilot.dispatched_at=1
denied "bd update --set-metadata GC.x (maiúscula)" "fora do formato" bd update ga-1 --set-metadata GC.routed_to=x
denied "bd update --set-metadata sem '='" "fora do formato" bd update ga-1 --set-metadata abc
for k in gate.submitted_by delivery.x Story.x foo.bar; do denied "bd update --set-metadata $k (prefixo fora da lista athos./story.)" "fora do formato" bd update ga-1 --set-metadata "$k=x"; done
denied "bd update --unset-metadata" "flag fora da lista" bd update ga-1 --set-metadata story.a=b --unset-metadata c
denied "bd comment --file" "flag fora da lista" bd comment ga-1 --file /etc/passwd
denied "bd comment sem texto" "faltam argumentos" bd comment ga-1
denied "bd comment --stdin com texto" "flag fora da lista" bd comment ga-1 oi --stdin
denied "bd close --reason-file" "flag fora da lista" bd close ga-1 --reason-file /etc/passwd
denied "bd close --force" "flag fora da lista" bd close ga-1 --force
denied "bd close sem id" "faltam argumentos" bd close
# ga-6auslu: o texto da tarefa do revisor (gate-review-task.lib.sh) manda 4 escritas na bead de veredito: label remove verdict:pending, label add verdict:PASS|FAIL,
# comment, close. comment e close têm regra; `bd label` NÃO tem, DE PROPÓSITO: o bd não confere dono no `label add`, o dispatcher lê verdict:PASS ANTES de verdict:FAIL
# (gate_collect_verdicts) e o resgate ga-7lz1 fecha bead ABERTA que já tem rótulo + revisor drenado — um `label add <bead alheia> verdict:PASS` vindo do nó aprovaria
# código sem revisão. O veredito do nó vai por comment "VERDICT: …" + close (o dispatcher lê o comentário ancorado: ga-86l90a8 PASS, ga-w7pm55 FAIL). Alargar isto
# exige checagem de dono no wrapper (decisão do Mayor), nunca um acerto de lista: por isso cada chave tem o seu caso, e a vizinhança também.
for _lk in "remove verdict:pending" "add verdict:PASS" "add verdict:FAIL" "remove verdict:PASS" "add verdict:REQUEUED" "add verdict:TIMEOUT" "add verdict:ABORTED" \
           "add gate:needs-fix" "add gate-status:passed" "add pilot:no-auto-dispatch" "add story:approved" "add type:quality-gate-verdict"; do
  _lop="${_lk%% *}"; _lkey="${_lk#* }"
  denied "rótulo do veredito: bd label $_lop <bead> $_lkey" "comando fora da lista" bd label "$_lop" ga-vb-1 "$_lkey"
  denied "rótulo do veredito: bd -C . label $_lop <bead> $_lkey (a forma do texto da tarefa)" "comando fora da lista" bd -C . label "$_lop" ga-vb-1 "$_lkey"
done
denied "rótulo do veredito: bd label add com dois rótulos" "comando fora da lista" bd label add ga-vb-1 verdict:PASS verdict:FAIL
denied "rótulo do veredito: bd label list" "comando fora da lista" bd label list ga-vb-1
denied "id com ';'" "fora do formato" bd show 'ga-1;id'
denied "id com \$()" "fora do formato" bd show 'ga-$(id)'
denied "id de wisp com ';'" "fora do formato" bd show 'ga-wisp-1;id'
denied "id de wisp com \$()" "fora do formato" gc mail read 'ga-wisp-$(id)'
denied "id com segmento vazio" "fora do formato" bd show 'ga--x'
denied "id terminado em hífen" "fora do formato" bd show 'ga-wisp-'
denied "id com 3 hífens (o teto são 2: <prefixo>-wisp-<sufixo>)" "fora do formato" bd show 'ga-a-b-c'
denied "id de wisp em --id com ';'" "fora do formato" bd list --id 'ga-wisp-1,ga-wisp-2;id'
denied "id começando com '-'" "flag fora da lista" bd show -ga-1
denied "id com espaço" "fora do formato" bd show 'ga-1 ga-2'
denied "bd -C fora das rotas" "não é a cidade nem um rig" bd -C /etc show ga-1
denied "bd -C relativo" "não é a cidade nem um rig" bd -C ../x show ga-1
denied "bd -C rig que não existe" "não é a cidade nem um rig" bd -C outro_rig show ga-1
denied "bd -C sem valor" "-C sem valor" bd -C
denied "bd --actor" "comando fora da lista" bd --actor mayor show ga-1
denied "bd --db" "comando fora da lista" bd --db /x show ga-1
denied "gc (sem subcomando)" "comando fora da lista" gc
denied "gc dolt" "comando fora da lista" gc dolt sql
denied "gc rig list" "comando fora da lista" gc rig list
denied "gc config show" "comando fora da lista" gc config show
denied "gc bd ..." "comando fora da lista" gc bd show ga-1
denied "gc session kill" "comando fora da lista" gc session kill gastown.mayor
denied "gc session list" "comando fora da lista" gc session list
denied "gc prime SEM --hook" "comando fora da lista" gc prime
denied "gc prime --hook com argumento a mais" "argumento a mais" gc prime --hook extra
denied "gc prime --hook outro formato" "flag fora da lista" gc prime --hook --hook-format claude
denied "gc prime --hook --evil" "flag fora da lista" gc prime --hook --evil
denied "gc prime <agente>" "comando fora da lista" gc prime mayor
denied "gc handoff sem --auto" "comando fora da lista" gc handoff
denied "gc handoff --auto com outra mensagem" "argumento a mais" gc handoff --auto "outra"
denied "gc handoff --target" "comando fora da lista" gc handoff --target mayor "x"
denied "gc nudge drain sem --inject" "comando fora da lista" gc nudge drain
denied "gc nudge drain --inject <sessão>" "argumento a mais" gc nudge drain --inject mayor
denied "gc nudge drain <sessão> --inject" "comando fora da lista" gc nudge drain mayor --inject
denied "gc mail check <sessão alheia>" "argumento a mais" gc mail check mayor
denied "gc mail send --all" "flag fora da lista" gc mail send mayor --all
denied "gc mail send --from" "flag fora da lista" gc mail send mayor --from mayor
denied "gc mail archive --all-recipients" "flag fora da lista" gc mail archive ga-a --all-recipients
denied "gc mail delete" "comando fora da lista" gc mail delete ga-a
denied "gc mail inbox <sessão alheia>" "argumento a mais" gc mail inbox mayor
denied "gc --city fora" "comando fora da lista" gc --city /x prime --hook
denied "gc session nudge com ESC" "fora do formato" gc session nudge mayor $'\x1b[2Jlimpa'
denied "gc session nudge com CR" "fora do formato" gc session nudge mayor $'a\rrm -rf x'
denied "gc session nudge com LF" "fora do formato" gc session nudge mayor $'a\nb'
denied "gc session nudge com C1 (CSI 8 bits)" "fora do formato" gc session nudge mayor $'a\xc2\x9bb'
# alvo VÁLIDO nos três abaixo: o que recusa é o texto, não o alvo
denied "gc session nudge com TAB (autocompletar no terminal do destino)" "fora do formato" gc session nudge gastown.mayor $'a\tb'
denied "gc session nudge com U+2028 (separador de linha Unicode)" "fora do formato" gc session nudge gastown.mayor $'a\xe2\x80\xa8b'
denied "gc session nudge com U+202E (inversão bidi: o texto exibido não é o digitado)" "fora do formato" gc session nudge gastown.mayor $'a\xe2\x80\xaeb'
denied "gc session nudge com U+200E (LRM: marca de direção, reordena o que se vê)" "fora do formato" gc session nudge gastown.mayor $'a\xe2\x80\x8eb'
denied "gc session nudge com U+200F (RLM)" "fora do formato" gc session nudge gastown.mayor $'a\xe2\x80\x8fb'
denied "gc session nudge com U+061C (ALM)" "fora do formato" gc session nudge gastown.mayor $'a\xd8\x9cb'
allowed "controle: pontuação e acento comuns (travessão U+2014 incluído) passam" gc session nudge gastown.mayor 'olá — ação: ok (v2)'
denied "gc session nudge --delivery inventado" "fora do formato" gc session nudge mayor x --delivery now
denied "gc session nudge --delivery immediate" "fora do formato" gc session nudge gastown.mayor oi --delivery immediate
denied "gc session nudge para alvo fora do nudge_pattern" "nudge_pattern" gc session nudge outra-sessao oi
printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","bin_dirs":["%s"]}' "$CITY" "$FB" > "$T/conf-nonudge.json"
CONF_OVERRIDE="$T/conf-nonudge.json" denied "gc session nudge com a config SEM nudge_pattern" "sem a chave" gc session nudge gastown.mayor oi
denied "gc session nudge com flag primeiro e alvo fora do nudge_pattern" "nudge_pattern" gc session nudge --delivery queue outra-sessao oi
# o guarda tem que olhar o alvo que o gc usa (o 1º posicional), não o args[0]: com um padrão de NEGAÇÃO ("qualquer um menos o Mayor") a flag na frente o furava
printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","nudge_pattern":"(?!gastown\\\\.mayor$)[a-z0-9._-]+","bin_dirs":["%s"]}' "$CITY" "$FB" > "$T/conf-denynudge.json"
CONF_OVERRIDE="$T/conf-denynudge.json" denied "nudge (padrão de negação) direto ao alvo vetado" "nudge_pattern" gc session nudge gastown.mayor oi
CONF_OVERRIDE="$T/conf-denynudge.json" denied "nudge (padrão de negação) com --delivery ANTES do alvo vetado" "nudge_pattern" gc session nudge --delivery queue gastown.mayor oi
CONF_OVERRIDE="$T/conf-denynudge.json" denied "nudge (padrão de negação) com -- ANTES do alvo vetado" "nudge_pattern" gc session nudge -- gastown.mayor oi
CONF_OVERRIDE="$T/conf-denynudge.json" allowed "nudge (padrão de negação) com flag antes de alvo permitido" gc session nudge --delivery queue outra-sessao oi
denied "ferramenta dolt" "comando fora da lista" dolt sql
denied "ferramenta bw" "comando fora da lista" bw get password x
denied "ferramenta security" "comando fora da lista" security find-generic-password
denied "ferramenta sh" "comando fora da lista" sh -c id
denied "ferramenta ssh" "comando fora da lista" ssh outro
denied "gate-done com flag" "flag fora da lista" gate-done --bead ga-1
denied "gate-done com argumento" "argumento a mais" gate-done ga-1
# um `--` sem nada depois não é "forma EXATA": o executável receberia argc=1 argv=[--] (o gate-done é um script, não um cobra)
denied "gate-done --" "sem nada depois" gate-done --
denied "gc handoff --auto --" "sem nada depois" gc handoff --auto --
denied "gc prime --hook --" "sem nada depois" gc prime --hook --
denied "gc nudge drain --inject --" "sem nada depois" gc nudge drain --inject --
denied "bd show <id> --" "sem nada depois" bd show ga-1 --
allowed "controle: o -- COM algo depois continua valendo (bd show -- <id>)" bd show -- ga-1; lastis "argv=[show][--][ga-1]"; ok $? "  argv na ordem do cliente"

echo "== protocolo, identidade e config"
badreq "pedido vazio" "sem comando" ""
badreq "pedido sem rs1" "fora do formato" "bd show ga-1"
badreq "rs1 com base64 de lixo" "fora do formato" 'rs1 !!!;id'
badreq "rs1 com base64 curto demais" "ilegível" 'rs1 A'
badreq "rs1 com JSON ruim" "ilegível" "$(raw '{nope')"
badreq "rs1 com JSON que é lista" "forma inesperada" "$(raw '[1]')"
badreq "chave duplicada" "chave duplicada" "$(raw '{"tool":"bd","tool":"gc","argv":["show","ga-1"],"env":{"GC_ALIAS":"gastown.dog-1"}}')"
badreq "chave a mais" "forma inesperada" "$(raw '{"tool":"bd","argv":["show","ga-1"],"env":{"GC_ALIAS":"gastown.dog-1"},"cwd":"/"}')"
badreq "argv com inteiro" "argv" "$(raw '{"tool":"bd","argv":["show",1],"env":{"GC_ALIAS":"gastown.dog-1"}}')"
badreq "argv com NUL" "argv" "$(raw '{"tool":"bd","argv":["show","ga-1\u0000x"],"env":{"GC_ALIAS":"gastown.dog-1"}}')"
badreq "tool que não é texto" "forma inesperada" "$(raw '{"tool":3,"argv":[],"env":{}}')"
badreq "env com valor que não é texto" "env: valor" "$(raw '{"tool":"bd","argv":["show","ga-1"],"env":{"GC_ALIAS":5}}')"
badreq "pedido grande demais" "grande demais" "rs1 $(python3 -I -c 'print("A"*300000)')"
badreq "argv com surrogate solto (viraria o byte C1 0x9b cru no nudge)" "surrogate" "$(raw '{"tool":"gc","argv":["session","nudge","gastown.mayor","a\udc9bb"],"env":{"GC_ALIAS":"gastown.dog-1"}}')"
badreq "mais de 64 argumentos" "argv" "$(python3 -I -c 'import json,base64;print("rs1 "+base64.urlsafe_b64encode(json.dumps({"tool":"bd","argv":["show"]+["ga-1"]*70,"env":{"GC_ALIAS":"gastown.dog-1"}}).encode()).decode().rstrip("="))')"
badreq "JSON aninhado fundo demais (RecursionError no json.loads, 120 KB: abaixo do teto de tamanho)" "ilegível" "$(python3 -I -c 'import base64;print("rs1 "+base64.urlsafe_b64encode(("["*60000+"]"*60000).encode()).decode().rstrip("="),end="")')"
tail -1 "$LOGF" | grep -qF "refused"; ok $? "  e essa recusa ficou no log de auditoria (antes caía no catch-all e o log nem era criado)"
b=$(calls); wrap "$(rq bd '{}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "sem GC_ALIAS/GC_AGENT"; ok $? "sem identidade: recusa"
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.mayor"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "identity_pattern"; ok $? "alias do Mayor não casa com identity_pattern"
for al in gastown.dog-1x evil-gastown.dog-1 "gastown.dog-1/../mayor"; do
  b=$(calls); wrap "$(rq bd "{\"GC_ALIAS\":\"$al\"}" show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "identity_pattern"; ok $? "alias '$al' casa só em parte com identity_pattern: recusa (fullmatch, não match/search)"
done
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_AGENT":"gastown.mayor"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "GC_AGENT"; ok $? "GC_AGENT do Mayor com alias bom: recusa"
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_CITY_PATH":"/x"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "env fora da lista"; ok $? "env fora da lista (GC_CITY_PATH): recusa"
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_BIN":"/tmp/x"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ]; ok $? "env fora da lista (GC_BIN): recusa"
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_SESSION_ID":"ga-mayor1"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "env fora da lista"; ok $? "GC_SESSION_ID não atravessa (nenhum padrão o liga ao alias; o handoff aceita o alias): recusa"
for k in GC_SESSION_NAME GC_TEMPLATE; do b=$(calls); wrap "$(rq bd "{\"GC_ALIAS\":\"gastown.dog-1\",\"$k\":\"gastown.mayor\"}" show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "$k"; ok $? "$k do Mayor com alias bom: recusa (tudo que diz quem é a sessão casa com identity_pattern)"; done
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_SESSION_NAME":"a b"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "fora do formato"; ok $? "valor de env fora do formato: recusa"
b=$(calls); wrap "$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_MANAGED_SESSION_HOOK":"2"}' show ga-1)"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ]; ok $? "GC_MANAGED_SESSION_HOOK só aceita 1"
badreq "pedido bom seguido de ';' e outro comando" "fora do formato" "$REQ_OK; touch $T/PWNED-tail"
badreq "pedido bom seguido de espaço e lixo" "fora do formato" "$REQ_OK extra"
badreq "pedido bom com quebra de linha no fim" "fora do formato" "$REQ_OK"$'\n'"touch $T/PWNED-tail"
[ ! -e "$T/PWNED-tail" ]; ok $? "  nada depois do pedido foi executado"
cfgcase() {  # cfgcase "descrição" "trecho" <conteúdo do arquivo de config | @ausente>
  local b; b=$(calls); if [ "$3" = "@ausente" ]; then CONF_OVERRIDE="$T/nao-existe.json"; else printf '%s' "$3" > "$T/conf-bad.json"; CONF_OVERRIDE="$T/conf-bad.json"; fi
  wrap "$REQ_OK"; CONF_OVERRIDE=""; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "$2"; ok $? "config: $1  [$2]"
}
cfgcase "ausente" "config ilegível" "@ausente"
cfgcase "não é JSON" "config ilegível" "{x"
cfgcase "é lista" "config ilegível" "[]"
cfgcase "chave desconhecida" "chave desconhecida" "{\"city\":\"$CITY\",\"identity_pattern\":\"x\",\"shell\":\"/bin/sh\"}"
cfgcase "sem identity_pattern" "sem city/identity_pattern" "{\"city\":\"$CITY\"}"
! has "$T/err" "nudge_pattern"; ok $? "  a mensagem diz o que FALTA e não chama de 'desconhecida' uma chave opcional (nudge_pattern, log, bin_dirs…)"
cfgcase "timeout true (JSON booleano não é número)" "timeout_s" "{\"city\":\"$CITY\",\"identity_pattern\":\"x\",\"timeout_s\":true}"
cfgcase "regex ruim" "identity_pattern inválido" "{\"city\":\"$CITY\",\"identity_pattern\":\"(\"}"
cfgcase "city relativa" "caminho absoluto" "{\"city\":\"city\",\"identity_pattern\":\"x\"}"
cfgcase "city que não é pasta" "caminho absoluto" "{\"city\":\"$T/nada\",\"identity_pattern\":\"x\"}"
cfgcase "timeout 0" "timeout_s" "{\"city\":\"$CITY\",\"identity_pattern\":\"x\",\"timeout_s\":0}"
cfgcase "gate_done_bin relativo" "caminho absoluto" "{\"city\":\"$CITY\",\"identity_pattern\":\"x\",\"gate_done_bin\":\"gatedone\"}"
cfgcase "bin_dirs relativo" "caminho absoluto" "{\"city\":\"$CITY\",\"identity_pattern\":\"x\",\"bin_dirs\":[\"bin\"]}"
b=$(calls); printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","bin_dirs":["%s/vazio"]}' "$CITY" "$T" > "$T/conf-nobin.json"; mkdir -p "$T/vazio"
CONF_OVERRIDE="$T/conf-nobin.json" wrap "$REQ_OK"; [ "$RC" = 127 ] && [ "$(calls)" = "$b" ] && has "$T/err" "não encontrado"; ok $? "ferramenta que não achei: 127, diz onde procurou e não executa"
b=$(calls); printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","bin_dirs":["%s"]}' "$CITY" "$FB" > "$T/conf-nogd.json"
CONF_OVERRIDE="$T/conf-nogd.json" wrap "$(rq gate-done "$ID")"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "gate-done: nenhum executável configurado"; ok $? "gate-done sem gate_done_bin: recusa dizendo por quê"
printf '#!/bin/sh\n' > "$T/gd-noexec"; chmod 600 "$T/gd-noexec"
b=$(calls); printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","gate_done_bin":"%s","bin_dirs":["%s"]}' "$CITY" "$T/gd-noexec" "$FB" > "$T/conf-gdnx.json"
CONF_OVERRIDE="$T/conf-gdnx.json" wrap "$(rq gate-done "$ID")"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "está configurado" && ! has "$T/err" "nenhum executável configurado"; ok $? "gate-done com gate_done_bin que existe mas não é executável: recusa dizendo 'configurado mas inutilizável', não 'não configurado'"
mv "$CITY/.beads/routes.jsonl" "$CITY/.beads/routes.off"; denied "-C com routes.jsonl ilegível (não sei ≠ qualquer rig)" "routes.jsonl" bd -C wa_rig show wa-1; allowed "sem -C, routes.jsonl ausente não atrapalha" bd show ga-1
mv "$CITY/.beads/routes.off" "$CITY/.beads/routes.jsonl"
mkdir -p "$T/ro"; chmod 500 "$T/ro"
if [ ! -w "$T/ro" ]; then
  printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","log":"%s/ro/sub/x.log","bin_dirs":["%s"]}' "$CITY" "$T" "$FB" > "$T/conf-ro.json"
  b=$(calls); CONF_OVERRIDE="$T/conf-ro.json" wrap "$REQ_OK"; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "não executo sem rastro"; ok $? "log de auditoria que não grava: NÃO executa"
else skip "log não gravável (rodando como root: chmod não impede)"; fi
chmod 700 "$T/ro"

echo "== timeout e auditoria"
sed 's/"timeout_s": 120/"timeout_s": 3/' "$CONF" > "$T/conf-tmo.json"  # timeout curto SÓ neste caso: com a máquina carregada, 3s no resto do selftest matava o bd falso
t0=$(date +%s); CONF_OVERRIDE="$T/conf-tmo.json" call bd close ga-1 --reason SLEEP; t1=$(date +%s)
[ "$RC" = 124 ] && [ $((t1-t0)) -lt 30 ] && has "$T/err" "passou de 3s"; ok $? "timeout_s: 124 em ~3s (bem antes dos 37s do comando), com aviso"
gone() {  # gone ARQUIVO-DE-PID → 0 se o processo sumiu (ou virou zumbi) em até 10 s; o kill -0 ainda "vê" o zumbi até o init reapar, e 0,3 s fixos reprovavam sob carga
  [ -s "$1" ] || return 1
  local pid st i; pid=$(cat "$1")
  for i in $(seq 1 100); do
    st=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$st" in ""|Z*) return 0;; esac
    sleep 0.1
  done
  return 1
}
gone "$FB/sleep.pid"; ok $? "o timeout mata o GRUPO (o neto 'sleep 37' não sobrevive)"
b=$(calls); call bd comment ga-1 'SEGREDO-4711 texto do comentário'
[ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && ! grep -q 'SEGREDO-4711' "$LOGF"; ok $? "o comando RODOU e o log de auditoria não guarda o texto do argumento (sem o 'rodou', uma recusa também não o guardaria: apagada a regra do bd comment, só o grep passava)"
has "$LOGF" "203.0.113.9"; ok $? "o log guarda o ip do cliente (SSH_CLIENT)"
has "$LOGF" "gastown.dog-1	ok	bd [-C <rig>] close <id> [--json] [--reason|-r <text>]"; ok $? "o log guarda alias, veredito e a regra"
grep -P '\tok\t' "$LOGF" >/dev/null 2>&1 || grep -E "$(printf '\t')ok$(printf '\t')" "$LOGF" >/dev/null; ok $? "o log tem linhas 'ok' (gravadas ANTES de executar)"
has "$LOGF" "done rc=124"; ok $? "o log tem 'done rc=124' do caso do timeout"
has "$LOGF" "refused"; ok $? "o log registra recusas"
[ "$(stat -f '%Lp' "$LOGF" 2>/dev/null || stat -c '%a' "$LOGF")" = 600 ]; ok $? "o log é 0600"
call bd close ga-1 --reason BREAKLOG; [ "$RC" = 0 ] && has "$T/err" "não consegui gravar o desfecho"; ok $? "desfecho que não grava no log: o comando rodou (rc 0) e o aviso diz que o log ficou sem o desfecho"
rmdir "$LOGF" 2>/dev/null  # (o falso trocou o log por uma pasta; a próxima chamada o recria)
kg() {  # kg reaped|unreaped|alive-eperm → 0 se kill_group se comportou como deve (a corrida entre o fim do filho e o kill)
  python3 -I - "$W" "$1" <<'EOF2'
import importlib.util, os, signal, subprocess, sys, time
s = importlib.util.spec_from_file_location("w", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
how = sys.argv[2]
def zombie(pid):  # espera o filho virar zumbi (saiu, ainda não reapado) SEM reapá-lo; via ps porque o python do sistema no macOS não tem os.waitid
    for _ in range(500):
        if subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip().startswith("Z"):
            return
        time.sleep(0.02)
    raise SystemExit("o filho não virou zumbi")
if how == "alive-eperm":  # EPERM com o filho VIVO não é a corrida: é "não consegui matar", e tem que levantar (senão o p.wait() seguinte pendura)
    real = os.killpg
    def eperm(pg, sig): raise PermissionError(1, "Operation not permitted")
    os.killpg = eperm
    p = subprocess.Popen(["sleep", "30"], start_new_session=True)
    try:
        m.kill_group(p)
        ok = False
    except PermissionError:
        ok = True
    finally:
        os.killpg = real
        real(p.pid, signal.SIGKILL); p.wait()
    sys.exit(0 if ok else 1)
p = subprocess.Popen(["true"], start_new_session=True)
if how == "reaped":
    p.wait()
else:  # saiu e continua zumbi: o estado em que serve() chama kill_group ANTES de o p.wait() reapar (no macOS o killpg dá EPERM, não ESRCH)
    zombie(p.pid)
m.kill_group(p)
p.wait()
EOF2
}
kg reaped; ok $? "kill_group: grupo cujo filho já foi reapado não vira erro (ESRCH)"
kg unreaped; ok $? "kill_group: grupo cujo filho SAIU e ainda não foi reapado não vira erro (macOS: EPERM — o estado real da corrida, que o teste antigo não exercia)"
kg alive-eperm; ok $? "kill_group: EPERM com o filho ainda VIVO levanta (não engole 'não consegui matar')"
echo "== trava de dono (ga-2hd02v.1.16): bd comment/close em bead de veredito só pelo dono (assignee == alias); estado que não consegui ler = recusa, nada executa"
VL='"labels":["area:infra","type:quality-gate-verdict"]'
bead() { printf '%s\n' "$2" > "$FB/beads/$1.json"; }  # bead ID 'JSON': o que o `bd show <id> --json` do falso responde (a leitura de estado do wrapper)
reads() { [ -e "$FB/reads.log" ] || { echo 0; return; }; wc -l < "$FB/reads.log" | tr -d ' '; }
lastread() { tail -1 "$FB/reads.log" | grep -qF -- "$1"; }
bead ga-v1 "[{\"id\":\"ga-v1\",\"status\":\"in_progress\",\"assignee\":\"gastown.dog-1\",$VL}]"
r=$(reads); allowed "bd comment em bead de veredito DO PRÓPRIO alias" bd comment ga-v1 'VERDICT: PASS'
[ "$(reads)" = $((r+1)) ] && lastread "cwd=$CITY" && lastread "actor=gastown.dog-1" && lastread "ro=true/off" && lastread "argv=[show][ga-v1][--json]"; ok $? "  a leitura de estado é UM bd show --json no MESMO cwd e BEADS_ACTOR do comando, com BD_READONLY=true e BD_DOLT_AUTO_COMMIT=off"
lastis "ro=UNSET/UNSET" && lastis "argv=[comment][ga-v1][VERDICT: PASS]"; ok $? "  e o COMANDO não leva BD_READONLY (a escrita é de verdade; o log de chamadas conta só comandos)"
allowed "bd close em bead de veredito do próprio alias" bd close ga-v1 --reason 'veredito entregue'
printf 'VERDICT: PASS' > "$T/stdin.txt"; STDIN_FILE="$T/stdin.txt" allowed "bd comment --stdin em bead de veredito do próprio alias" bd comment ga-v1 --stdin
has "$T/out" "STDIN<VERDICT: PASS>"; ok $? "  o stdin chega inteiro ao COMANDO (a leitura de estado roda com stdin fechado e não o consome)"
bead ga-v2 "[{\"id\":\"ga-v2\",\"status\":\"closed\",\"assignee\":\"gastown.dog-9\",$VL}]"
denied "bd comment em bead de veredito de OUTRA sessão (o 'VERDICT: PASS' forjado)" "ga-v2 é bead de veredito" bd comment ga-v2 'VERDICT: PASS'
has "$T/err" "não repita"; ok $? "  a mensagem diz que NÃO adianta repetir (a bead é de outro; ≠ leitura que falhou, que diz 'pode repetir')"
STDIN_FILE="$T/stdin.txt" denied "bd comment --stdin em bead de veredito de outra sessão" "ga-v2 é bead de veredito" bd comment ga-v2 --stdin
denied "bd close em bead de veredito de outra sessão" "ga-v2 é bead de veredito" bd close ga-v2 --reason x
denied "bd close com a flag ANTES do id (o dono é conferido na bead certa)" "ga-v2 é bead de veredito" bd close --reason x ga-v2
bead wa-v1 "[{\"id\":\"wa-v1\",\"assignee\":\"gastown.dog-9\",$VL}]"
denied "bd -C <rig> comment em bead de veredito de outra sessão" "wa-v1 é bead de veredito" bd -C wa_rig comment wa-v1 oi
lastread "cwd=$WA"; ok $? "  e a leitura de estado rodou no cwd do RIG, o mesmo do comando"
bead ga-v3 "[{\"id\":\"ga-v3\",\"status\":\"closed\",$VL}]"
denied "bead de veredito SEM dono (a chave assignee ausente: 55 de 60 beads fechadas medidas)" "ga-v3 é bead de veredito" bd comment ga-v3 'VERDICT: PASS'
bead ga-v4 "[{\"id\":\"ga-v4\",\"assignee\":\"\",$VL}]"
denied "bead de veredito com assignee vazio" "ga-v4 é bead de veredito" bd comment ga-v4 'VERDICT: PASS'
bead ga-p1 '[{"id":"ga-p1","status":"in_progress","assignee":"gastown.dog-9","labels":["area:infra"]}]'
allowed "bd comment em bead COMUM de outro dono passa como antes (o dog comenta e fecha a própria bead por aqui)" bd comment ga-p1 oi
allowed "bd close em bead COMUM" bd close ga-p1 --reason ok
bead ga-p2 '[{"id":"ga-p2","status":"open"}]'
allowed "bead sem assignee e sem labels (chaves ausentes = 'não tem', não 'não consegui ler')" bd comment ga-p2 oi
bead ga-p3 '[{"id":"ga-p3","assignee":"gastown.dog-9","labels":["type:quality-gate-verdict-x","Type:quality-gate-verdict","type:quality-gate-verdicts"]}]'
allowed "rótulo parecido não é o rótulo (comparação exata)" bd comment ga-p3 oi
unreadable() {  # unreadable "descrição" 'stdout bruto do bd show' → 77 "pode repetir" e nada executou (nem a escrita)
  rm -f "$FB/beads/ga-u1.json"; printf '%s' "$2" > "$FB/beads/ga-u1.raw"
  denied "$1" "nada foi executado, pode repetir" bd comment ga-u1 oi
}
unreadable "estado ilegível: stdout vazio" ''
unreadable "estado ilegível: stdout que não é JSON" 'oi tudo bem'
unreadable "estado ilegível: lista vazia (a bead não existe)" '[]'
unreadable "estado ilegível: lista de 2 beads" '[{"id":"ga-u1"},{"id":"ga-u2"}]'
unreadable "estado ilegível: objeto solto, não lista" '{"id":"ga-u1"}'
unreadable "estado ilegível: item da lista que não é objeto" '["ga-u1"]'
unreadable "estado ilegível: assignee null (o bd omite a chave, não escreve null)" '[{"id":"ga-u1","assignee":null,"labels":["type:quality-gate-verdict"]}]'
unreadable "estado ilegível: assignee que não é texto" '[{"id":"ga-u1","assignee":["gastown.dog-1"],"labels":["type:quality-gate-verdict"]}]'
unreadable "estado ilegível: labels null" '[{"id":"ga-u1","assignee":"gastown.dog-1","labels":null}]'
unreadable "estado ilegível: labels com item que não é texto" '[{"id":"ga-u1","assignee":"gastown.dog-1","labels":[1,"type:quality-gate-verdict"]}]'
unreadable "estado ilegível: labels texto em vez de lista" '[{"id":"ga-u1","assignee":"gastown.dog-1","labels":"type:quality-gate-verdict"}]'
rm -f "$FB/beads/ga-u1.raw"
bead ga-u2 '[{"id":"ga-u2","status":"open"}]'; printf 7 > "$FB/beads/ga-u2.rc"
denied "bd show com rc≠0 mesmo com um JSON de bead comum no stdout (o rc manda)" "rc=7" bd comment ga-u2 oi
rm -f "$FB/beads/ga-u2.rc"
bead ga-n1 "[{\"id\":\"ga-n1\",\"assignee\":\"gastown.dog-1\",$VL}]"; : > "$FB/beads/ga-n1.noise"
allowed "aviso do Dolt no stderr do bd show (stdout JSON limpo): só o stdout é lido" bd comment ga-n1 'VERDICT: PASS'
bead ga-n2 "[{\"id\":\"ga-n2\",\"assignee\":\"gastown.dog-9\",$VL}]"; : > "$FB/beads/ga-n2.noise"
denied "o mesmo aviso não faz a bead de outro passar" "ga-n2 é bead de veredito" bd comment ga-n2 'VERDICT: PASS'
sed 's/"timeout_s": 120/"timeout_s": 2/' "$CONF" > "$T/conf-read-tmo.json"; : > "$FB/beads/ga-t1.sleep"; rm -f "$FB/read-sleep.pid"
b=$(calls); t0=$(date +%s); CONF_OVERRIDE="$T/conf-read-tmo.json" call bd comment ga-t1 oi; t1=$(date +%s)
[ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "passou do prazo" && has "$T/err" "pode repetir" && [ $((t1-t0)) -lt 20 ]; ok $? "bd show que não responde: estoura o prazo (timeout_s), 77 'pode repetir' e o comando NÃO rodou"
gone "$FB/read-sleep.pid"; ok $? "  e a leitura pendurada é encerrada com o grupo (o neto 'sleep 37' não sobrevive)"
rm -f "$FB/beads/ga-t1.sleep"
has "$LOGF" "gastown.dog-1	ok	bd [-C <rig>] comment <id> <text>... +dono"; ok $? "o log de auditoria guarda a regra com '+dono'"
grep -F "refused" "$LOGF" | grep -qF "ga-v2 é bead de veredito"; ok $? "  e a recusa por dono fica no log como 'refused', com o motivo"

# harness: roda o serve() REAL do wrapper com UMA falha forçada em ponto escolhido (no ambiente de um sshd, como o wrap)
cat > "$T/race.py" <<'EOF2'
import importlib.util, os, signal, subprocess, sys, time
s = importlib.util.spec_from_file_location("w", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
mode = sys.argv[2]
def zombie(pid):  # espera o filho virar zumbi (saiu, ainda não reapado) SEM reapá-lo; via ps porque o python do sistema no macOS não tem os.waitid
    for _ in range(500):
        if subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip().startswith("Z"):
            return
        time.sleep(0.02)
    raise RuntimeError("o filho não virou zumbi")
real_wait, state, target = subprocess.Popen.wait, [], []  # target: o filho que o wrapper espera (não o `ps` do zombie(), cujo subprocess.run também termina com um poll())
def wait(self, timeout=None):
    if timeout is not None and not state:
        state.append(1)
        if mode in ("race", "race2"):  # o filho SAIU (ainda zumbi) e o wait diz que o prazo estourou: o fim do filho corre com o timeout
            target.append(self.pid)
            zombie(self.pid)
            raise subprocess.TimeoutExpired(self.args, timeout)
        if mode in ("boom", "boomnokill"):  # o próprio wrapper falha DEPOIS de o comando ter rodado
            real_wait(self)
            raise RuntimeError("boom")
        if mode == "termnokill":  # o sinal chega com o filho já criado
            os.kill(os.getpid(), signal.SIGTERM)
    return real_wait(self, timeout)
if mode in ("race", "race2", "boom", "boomnokill", "termnokill"):
    subprocess.Popen.wait = wait
if mode == "race2":  # a janela de microssegundos entre o poll depois do prazo e o kill: o poll ainda vê o filho vivo, e quando o kill chega ele já saiu com o código DELE
    real_poll, polls = subprocess.Popen.poll, []
    def poll(self):
        if target and self.pid == target[0] and not polls:  # só a 1ª olhada DO WRAPPER no filho que ele espera (o poll() que o subprocess.run do `ps` faz não pode gastá-la: foi o que fez este caso passar vazio no wrapper antigo)
            polls.append(1)
            return None
        return real_poll(self)
    subprocess.Popen.poll = poll
if mode == "termpopen":  # o sinal chega DENTRO do Popen: o filho já foi criado (e já trabalha), mas o Popen ainda não devolveu o handle a quem o chamou
    real_init = subprocess.Popen.__init__
    def init(self, *a, **k):
        real_init(self, *a, **k)
        for _ in range(300):  # espera o filho de verdade começar (o falso grava o pid do neto): um sinal antes disso não prova nada
            if os.path.exists(sys.argv[4]) and os.path.getsize(sys.argv[4]) > 0:
                break
            time.sleep(0.1)
        os.kill(os.getpid(), signal.SIGTERM)
    subprocess.Popen.__init__ = init
if mode in ("boomnokill", "termnokill"):  # o kill do grupo LEVANTA (EPERM com o filho vivo): "não consegui encerrar" não pode virar "encerrado"
    def kill(p): raise PermissionError(1, "Operation not permitted")
    m.kill_group = kill
elif mode == "nopopen":
    def popen(*a, **k): raise OSError(13, "Permission denied")
    subprocess.Popen = popen
elif mode == "internal":  # erro que o wrapper não previu, ANTES de o comando começar
    def decide(*a, **k): raise RuntimeError("inesperado")
    m.decide = decide
sys.exit(m.main(["serve", "--config", sys.argv[3]]))
EOF2
harness() {  # harness MODO "<SSH_ORIGINAL_COMMAND>" → RC, $T/out, $T/err
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin SSH_CLIENT="203.0.113.9 5555 22" SSH_ORIGINAL_COMMAND="$2" python3 -I "$T/race.py" "$W" "$1" "$CONF" "$FB/sleep.pid" > "$T/out" 2> "$T/err" < /dev/null
  RC=$?
}
lastlog() { tail -1 "$LOGF" | grep -qF -- "$1"; }
b=$(calls); harness race "$REQ_OK"
[ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && ! has "$T/err" "RECUSADO" && ! has "$T/err" "passou de"; ok $? "corrida fim-do-filho × prazo: o filho TERMINOU, vale o código dele (0) — nunca 'RECUSADO' (o falso rodou) nem 'estourou o prazo'"
lastlog "done rc=0"; ok $? "  e o log fecha com o desfecho real"
b=$(calls); harness race2 "$REQ_OK"
[ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && ! has "$T/err" "passou de" && ! has "$T/err" "RECUSADO"; ok $? "corrida fim-do-filho × kill (o poll ainda o vê vivo, e ele sai com o código DELE antes do kill chegar): vale o código dele (0), não 124 'passou do prazo'"
lastlog "done rc=0"; ok $? "  e o log fecha com o código real, não com 124"
b=$(calls); harness boom "$REQ_OK"
[ "$RC" = 125 ] && [ "$(calls)" = $((b+1)) ] && has "$T/err" "INICIADO" && ! has "$T/err" "RECUSADO"; ok $? "falha do wrapper DEPOIS de o comando ter rodado: 125 e 'INICIADO' (o falso rodou) — nunca 77/'RECUSADO', que o cliente leria como 'nada executou' e repetiria"
lastlog "done unknown"; ok $? "  e o log fecha com 'done unknown' (a linha 'ok' sozinha, lida como 'rodou', não fica sem desfecho)"
has "$T/err" "o grupo foi encerrado"; ok $? "  e, com o kill funcionando, a mensagem diz que o grupo foi encerrado"
harness boomnokill "$REQ_OK"
[ "$RC" = 125 ] && has "$T/err" "NÃO consegui encerrar o grupo" && ! has "$T/err" "o grupo foi encerrado"; ok $? "falha pós-início com o kill do grupo LEVANTANDO: a mensagem diz 'NÃO consegui encerrar', não 'encerrado' (terceiro estado)"
lastlog "done unknown RuntimeError filho-nao-encerrado"; ok $? "  e o log também"
b=$(calls); harness termnokill "$REQ_OK"
# neste caso o kill do grupo foi feito para LEVANTAR: o filho segue vivo e grava a sua linha em calls.log DEPOIS de o wrapper sair — esperar, senão a linha cai no caso seguinte e quebra a contagem dele
for _ in $(seq 1 200); do [ "$(calls)" -gt "$b" ] && break; sleep 0.1; done
[ "$RC" = 143 ] && [ "$(calls)" = $((b+1)) ]; ok $? "SIGTERM com o filho criado: sai 143 mesmo se o kill do grupo levantar (e o filho que ficou vivo terminou a sua chamada)"
lastlog "done killed sig=15 filho-nao-encerrado"; ok $? "  e o log diz 'filho-nao-encerrado', não 'filho-encerrado' (o handler não afirma o que não conseguiu)"
rm -f "$FB/sleep.pid"; b=$(calls); harness termpopen "$(rq gc "$ID" session nudge gastown.mayor SLEEP)"  # (gc, não bd close: o close agora faz uma LEITURA de estado antes, que também é Popen e o init remendado a pegaria)
[ "$RC" = 143 ] && [ "$(calls)" = $((b+1)) ]; ok $? "SIGTERM DENTRO do Popen (o filho já roda, o Popen ainda não devolveu o handle): sai 143 e o comando tinha mesmo começado"
lastlog "done killed sig=15 filho-encerrado" && ! lastlog "sem-filho-registrado"; ok $? "  e o log diz 'filho-encerrado' (o sinal esperou o filho ser registrado e aí o encerrou), nunca 'sem-filho-registrado' com o comando rodando"
gone "$FB/sleep.pid"; ok $? "  e o filho (o neto 'sleep 37') não sobrevive: antes o handler saía sem matar nada e o comando rodava até o fim com o cliente já longe"
b=$(calls); harness nopopen "$REQ_OK"
[ "$RC" = 126 ] && [ "$(calls)" = "$b" ] && has "$T/err" "não consegui executar"; ok $? "Popen que falha: 126 e o falso NÃO rodou"
lastlog "done rc=126"; ok $? "  e o log tem o desfecho (126, nao-iniciado): sem ele o 'ok' lido sozinho diria 'rodou'"
b=$(calls); harness internal "$REQ_OK"
[ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "RECUSADO: erro interno RuntimeError"; ok $? "erro que o wrapper não previu ANTES do comando: 77 'erro interno' e o falso NÃO rodou"
lastlog "refused"; ok $? "  e essa recusa também fica no log (antes só a recusa de Refused era auditada)"
rm -f "$FB/sleep.pid"
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin SSH_CLIENT="203.0.113.9 5555 22" SSH_ORIGINAL_COMMAND="$(rq gc "$ID" session nudge gastown.mayor SLEEP)" python3 -I "$W" serve --config "$CONF" > "$T/out" 2> "$T/err" < /dev/null &
WPID=$!
for _ in $(seq 1 300); do [ -s "$FB/sleep.pid" ] && break; sleep 0.2; done
kill -TERM "$WPID"; wait "$WPID"; RC=$?
[ "$RC" = 143 ]; ok $? "SIGTERM no wrapper (o cliente ssh foi embora): sai 143"
lastlog "done killed sig=15 filho-encerrado"; ok $? "  e o log fecha com 'done killed sig=15 filho-encerrado' (o 'ok' não fica sem desfecho)"
gone "$FB/sleep.pid"; ok $? "  e o filho (o neto 'sleep 37') não sobrevive ao wrapper"
b=$(calls); call bd show ga-1; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "pedido para parear as duas linhas de auditoria rodou"
tail -2 "$LOGF" | awk -F'\t' 'NR==1 {o = $4; oh = $6; ots = $1} NR==2 {d = $4; dh = $7; dts = $1} END {exit !(o == "ok" && d ~ /^done / && oh != "" && oh == dh && ots == dts)}'; ok $? "as linhas 'ok' e 'done' do mesmo pedido levam o MESMO ts e a MESMA hash do argv (é como duas chamadas simultâneas do mesmo alias e regra se pareiam)"
call bd sql "select 1"; lastlog "declarado=gastown.dog-1	refused"; ok $? "linha de recusa de um pedido que decodificou leva o alias que ele DECLAROU (declarado=…), não '?'"
wrap "$(rq bd '{}' show ga-1)"; lastlog "sem-alias	refused"; ok $? "  pedido que decodificou e não trouxe alias: 'sem-alias' (≠ '?', que é 'nem decodificou')"
wrap 'rs1 A'; lastlog "?	refused"; ok $? "  pedido que nem decodificou: '?'"
logclean() {  # a última linha do log não tem controle C0/C1 (fora o TAB entre campos), separador de linha Unicode nem bidi: o que o cliente declara não reescreve um log lido no terminal
  tail -1 "$LOGF" | python3 -I -c 'import re, sys; l = sys.stdin.read(); sys.exit(1 if re.search(r"[\x00-\x08\x0b-\x1f\x7f-\x9f\u2028\u2029\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]", l.rstrip("\n")) else 0)'
}
wrap "$(rq bd "$(python3 -I -c 'import json; print(json.dumps({"GC_ALIAS": "gastown.dog-1\u001b[31m\u202e\u200e\u200f\u061c\nFAKE"}))')" show ga-1)"
lastlog "declarado=gastown.dog-1" && lastlog "FAKE" && logclean; ok $? "alias DECLARADO com ESC, bidi e quebra de linha: a linha de recusa o leva sem nenhum deles (nem parte o registro em dois)"
call bd $'\x1b]0;evil\x07x'; lastlog "comando fora da lista" && logclean; ok $? "argumento com ESC/BEL no motivo da recusa: o log não o leva cru"

echo "== authorized-line"
line=$(python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from "127.0.0.1,10.0.0.0/8"); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ]; ok $? "imprime UMA linha"
case "$line" in restrict,from=\"127.0.0.1,10.0.0.0/8\",command=\"*\ -I\ *serve\ --config\ *\"\ ssh-ed25519\ AAAA*\ remote-shim-hetzner) true;; *) false;; esac; ok $? "forma: restrict, from=, command=\"<python> -I <wrapper> serve --config <conf>\", chave, comentário fixo"
printf '%s' "$line" > "$T/line.txt"  # arquivo, não <(…): a substituição de processo ilegível daria "não achei" e o controle negativo passaria vazio
has "$T/line.txt" "ssh-ed25519 AAAA" && ! has "$T/line.txt" "alguem@servidor"; ok $? "o comentário da chave original não vai (nem nada além do tipo e do blob); o controle positivo: o arquivo lido tem a chave"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 0 ] && grep -q '^restrict,command=' "$T/out"; ok $? "sem --from: restrict,command= (sem from)"
has "$T/err" "sem --from"; ok $? "  e AVISA no stderr que a chave vale de qualquer endereço (a ausência de --from era um fail-open calado)"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from 127.0.0.1 > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 0 ] && [ -s "$T/out" ] && ! has "$T/err" "sem --from"; ok $? "  com --from não avisa nada (o aviso não é ruído fixo)"
QD="$T/dir com espaço"; QQ="$T/q\"uote"; QB="$T/back\\slash"; QBQ="$T/b\\\"q"; mkdir -p "$QD" "$QQ" "$QB" "$QBQ"
for d in "$QD" "$QQ" "$QB" "$QBQ"; do cp "$CONF" "$d/conf.json"; done
for c in "$QD/conf.json" "$QQ/conf.json" "$QB/conf.json" "$QBQ/conf.json"; do
  l=$(python3 -I "$W" authorized-line --config "$c" --pubkey "$KD/user_key.pub")
  python3 -I - "$l" "$c" <<'EOF2'
import shlex, sys
line, conf = sys.argv[1], sys.argv[2]
def dequote(s):  # opt_dequote do OpenSSH (auth-options.c): dentro de command="…" SÓ \" é escape; qualquer outra barra invertida é literal
    assert s[0] == '"'
    i, out = 1, []
    while i < len(s) and s[i] != '"':
        if s[i] == '\\' and s[i + 1:i + 2] == '"':
            i += 1
        out.append(s[i])
        i += 1
    return "".join(out), s[i + 1:]
assert line.startswith("restrict,command=")
cmd, rest = dequote(line[len("restrict,command="):])
argv = shlex.split(cmd)  # o que o sshd entrega ao shell de login
sys.exit(0 if rest.startswith(" ssh-ed25519 ") and argv[1] == "-I" and argv[-3:] == ["serve", "--config", conf] else 1)
EOF2
  ok $? "  caminho com espaço/aspas/barra invertida ($(basename "$(dirname "$c")")) volta inteiro depois do authorized_keys e do shell"
done
QN="$T/nl"$'\n'"x"; mkdir -p "$QN"; cp "$CONF" "$QN/conf.json"
python3 -I "$W" authorized-line --config "$QN/conf.json" --pubkey "$KD/user_key.pub" > "$T/out" 2> "$T/err"; [ $? = 77 ] && [ ! -s "$T/out" ] && has "$T/err" "caractere de controle"; ok $? "caminho com quebra de linha: recusa (imprimiria DUAS linhas no authorized_keys)"
printf 'command="/bin/sh" %s\n' "$(cat "$KD/user_key.pub")" > "$KD/with_opts.pub"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/with_opts.pub" >/dev/null 2>"$T/err"; [ $? = 77 ] && has "$T/err" "sem opções na frente"; ok $? "pubkey com opções na frente: recusa"
{ cat "$KD/user_key.pub"; cat "$KD/user_key.pub"; } > "$KD/two.pub"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/two.pub" >/dev/null 2>"$T/err"; [ $? = 77 ]; ok $? "pubkey com duas chaves: recusa"
printf 'ssh-ed25519 AAAA\nQUFB\n' > "$KD/nl.pub"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/nl.pub" >/dev/null 2>"$T/err"; [ $? = 77 ]; ok $? "pubkey com quebra de linha no meio: recusa"
printf 'ssh-ed25519 AAAA"; rm -rf x' > "$KD/inj.pub"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/inj.pub" >/dev/null 2>"$T/err"; [ $? = 77 ]; ok $? "pubkey com aspas/ponto-e-vírgula no blob: recusa"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from '1.2.3.4",command="/bin/sh' >/dev/null 2>"$T/err"; [ $? = 77 ] && has "$T/err" "--from"; ok $? "--from com aspas (injeção de opção): recusa"
python3 -I "$W" authorized-line --config "$T/nao-existe.json" --pubkey "$KD/user_key.pub" >/dev/null 2>"$T/err"; [ $? = 77 ]; ok $? "config ruim: não gera linha"

echo "== sshd de verdade (sem privilégio, 127.0.0.1, porta livre): a chave só roda o wrapper"
if start_sshd; then
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$SD/host_key.pub")" > "$SD/kh"
  SSHO=(-F /dev/null -i "$KD/user_key" -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$SD/kh" -o ConnectTimeout=5 -o LogLevel=ERROR)
  OTHER=("${SSHO[@]}"); OTHER[3]="$KD/other"   # as mesmas opções, com a chave VÁLIDA que não está no authorized_keys
  rm -f "$T/PWNED-key"
  b=$(calls); tmo 20 ssh "${SSHO[@]}" "$USER@127.0.0.1" "touch $T/PWNED-key" > "$T/out" 2> "$T/err"; RC=$?
  [ "$RC" = 77 ] && [ ! -e "$T/PWNED-key" ] && [ "$(calls)" = "$b" ] && has "$T/err" "fora do formato"; ok $? "a chave NÃO roda um comando qualquer (touch): 77 e o arquivo não nasce"
  tmo 20 ssh "${SSHO[@]}" "$USER@127.0.0.1" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
  [ "$RC" = 77 ] && has "$T/err" "sem comando"; ok $? "a chave NÃO abre shell (sem comando): 77 'sem comando'"
  tmo 20 ssh "${SSHO[@]}" -N -R 0:127.0.0.1:9 -o ExitOnForwardFailure=yes "$USER@127.0.0.1" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
  [ "$RC" != 0 ] && [ "$RC" != 142 ] && has "$T/err" "forwarding failed"; ok $? "a chave NÃO encaminha porta (-R): o sshd recusa (restrict)"
  tmo 20 ssh "${SSHO[@]}" -tt "$USER@127.0.0.1" "$(rq gc "$ID" mail check)" > "$T/out" 2> "$T/err" < /dev/null
  has "$T/err" "PTY allocation request failed"; ok $? "a chave NÃO ganha pty (restrict)"
  tmo 20 ssh "${OTHER[@]}" "$USER@127.0.0.1" "$REQ_OK" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
  [ "$RC" = 255 ] && has "$T/err" "Permission denied" && ! has "$T/out" "FAKE-bd-OUT"; ok $? "chave VÁLIDA que não está no authorized_keys: negada"
  { cat "$SD/authorized_keys"; python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/other.pub" --from 127.0.0.1; } > "$SD/authorized_keys.2"
  cp "$SD/authorized_keys.2" "$SD/authorized_keys"
  tmo 20 ssh "${OTHER[@]}" "$USER@127.0.0.1" "$REQ_OK" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
  [ "$RC" = 0 ] && has "$T/out" "FAKE-bd-OUT"; ok $? "  controle: listada, a MESMA chave entra (a negação acima vem do authorized_keys, não de a chave nem existir)"
  python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from 192.0.2.1 > "$SD/authorized_keys"
  tmo 20 ssh "${SSHO[@]}" "$USER@127.0.0.1" "$REQ_OK" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
  [ "$RC" = 255 ] && has "$T/err" "Permission denied"; ok $? "from= que não casa com 127.0.0.1: a chave é negada (o quoting do command=/from= sobreviveu ao sshd)"
  python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from 127.0.0.1 > "$SD/authorized_keys"
  tmo 20 ssh "${SSHO[@]}" "$USER@127.0.0.1" "$REQ_OK" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
  [ "$RC" = 0 ] && has "$T/out" "FAKE-bd-OUT"; ok $? "from= que casa: volta a rodar o pedido bom"
  for c in "$QQ" "$QB" "$QBQ"; do  # o que o sshd de VERDADE faz com o command="…" quando o caminho da config tem aspas / barra invertida
    python3 -I "$W" authorized-line --config "$c/conf.json" --pubkey "$KD/user_key.pub" --from 127.0.0.1 > "$SD/authorized_keys"
    tmo 20 ssh "${SSHO[@]}" "$USER@127.0.0.1" "$REQ_OK" > "$T/out" 2> "$T/err" < /dev/null; RC=$?
    [ "$RC" = 0 ] && has "$T/out" "FAKE-bd-OUT"; ok $? "config em caminho com aspas/barra invertida ($(basename "$c")): o command= sobrevive ao sshd de verdade e o wrapper acha a config"
  done
else
  skip "sshd de verdade: não subiu (sshd=${SSHD:-ausente}) — 11 casos da chave/forced-command ficaram SEM rodar; os outros casos NÃO provam que a chave só roda o wrapper"
  skipped=$((skipped+10))
fi

echo "== documentação: a lista do runbook é a do código"
BEGIN='<!-- allowlist:begin -->'; END='<!-- allowlist:end -->'
if [ -f "$RUNBOOK" ] && has "$RUNBOOK" "$BEGIN" && has "$RUNBOOK" "$END"; then
  sed -n "/$BEGIN/,/$END/p" "$RUNBOOK" | sed '1d;$d' | sed '/^```/d' > "$T/doc-list.txt"
  python3 -I "$W" list > "$T/code-list.txt"
  diff -u "$T/doc-list.txt" "$T/code-list.txt" > "$T/doc-diff.txt"; ok $? "o bloco 'allowlist' do runbook == saída de \`list\` (regras e variáveis de ambiente)"
  [ -s "$T/doc-diff.txt" ] && head -20 "$T/doc-diff.txt"
  [ "$(sort "$T/code-list.txt" | uniq -d | wc -l | tr -d ' ')" = 0 ]; ok $? "nenhuma regra repetida na lista"
else ok 1 "o runbook $RUNBOOK tem o bloco <!-- allowlist:begin/end -->"; fi
# a config que o runbook manda instalar "enquanto o Mayor não define os papéis" é dita INERTE: o selftest roda ESSA config (só city, log e bin_dirs trocados pelos do hermético)
python3 -I - "$RUNBOOK" "$CITY" "$FB" "$LOGF" > "$T/conf-runbook.json" <<'EOF2'
import json, re, sys
rb, city, fb, log = sys.argv[1:5]
m = re.search(r'^\s+`(\{"city".*\})`', open(rb).read(), re.M)
if not m:
    sys.exit(1)
cfg = json.loads(m.group(1))
cfg.update(city=city, log=log, bin_dirs=[fb])
print(json.dumps(cfg))
EOF2
[ -s "$T/conf-runbook.json" ] && grep -q '"identity_pattern"' "$T/conf-runbook.json"; ok $? "controle: a config do passo 1 do runbook foi extraída (e tem identity_pattern)"
for al in servidor-x servidor-abc-1 gastown.dog-1 gastown.mayor dog-gavycydh; do
  b=$(calls); CONF_OVERRIDE="$T/conf-runbook.json" wrap "$(rq bd "{\"GC_ALIAS\":\"$al\"}" show ga-1)"
  [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && has "$T/err" "não casa com identity_pattern"; ok $? "a config de exemplo do runbook é INERTE: alias '$al' recusado por identity_pattern (a doc dizia 'recusa tudo' e o marcador antigo deixava passar servidor-*)"
done

echo "== controle negativo: apagar a guarda faz o MESMO caso se comportar diferente"
mutate() {  # mutate 'texto a trocar' 'texto novo' ['outro texto' 'outro novo'...] → $T/mutant.py (falha se QUALQUER texto não está no wrapper: o controle não pode virar vazio)
  python3 -I - "$W" "$T/mutant.py" "$@" <<'EOF2'
import sys
s = open(sys.argv[1]).read()
pairs = sys.argv[3:]
for old, new in zip(pairs[::2], pairs[1::2]):
    if old not in s:
        sys.exit(3)
    s = s.replace(old, new, 1)
open(sys.argv[2], "w").write(s)
EOF2
}
withmutant() { local W0=$W r; W="$T/mutant.py"; "$@"; r=$?; W=$W0; return $r; }  # devolve o status do comando (os que olham $RC não dependem disso)
mutate '    Rule("gc", ["prime", "--hook"]),
' ''; ok $? "controle: a linha 'gc prime --hook' existe na RULES"
b=$(calls); withmutant call gc prime --hook; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ]; ok $? "  sem essa linha o MESMO comando passa a ser recusado (a tabela RULES é o que decide)"
mutate 'and k.startswith(ALLOW_META) ' ''; ok $? "controle: a lista de prefixos de metadata existe"
b=$(calls); withmutant call bd update ga-1 --set-metadata gc.routed_to=x; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "  sem ela 'gc.routed_to=x' passa a rodar (o caso de recusa acima de fato a exercita)"
mutate '"id": _fm(ID), ' '"id": lambda s: True, '; ok $? "controle: o formato do id existe"
b=$(calls); withmutant call bd show 'ga-1;id'; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ]; ok $? "  sem ele 'ga-1;id' passa a rodar"
mutate '    if len(doc["argv"]) > MAX_ARGS or' '    if False and len(doc["argv"]) > MAX_ARGS or'; ok $? "controle: o teto de argumentos existe"
mutate 'if k not in ENV_VAL or not re.fullmatch(ENV_VAL[k], env[k])]' 'if False]'; ok $? "controle: a lista de variáveis de ambiente existe"
BINREQ="$(rq bd '{"GC_ALIAS":"gastown.dog-1","GC_BIN":"/tmp/x"}' show ga-1)"
wrap "$BINREQ"; R0=$RC; withmutant wrap "$BINREQ"; R1=$RC
[ "$R0" = 77 ] && [ "$R1" = 0 ]; ok $? "  sem ela GC_BIN=/tmp/x chega ao filho (com ela é recusado)"
mutate 'if p.poll() is None:  # (o poll reapa)' 'if True:  # (o poll reapa)'; ok $? "controle: o kill_group separa 'filho zumbi' (EPERM benigno) de 'filho vivo' pelo poll"
withmutant kg unreaped; [ $? != 0 ]; ok $? "  sem a separação (EPERM sempre levanta) o MESMO caso do filho zumbi volta a levantar"
mutate 'if p.poll() is None:  # (o poll reapa)' 'if False:  # (o poll reapa)'; ok $? "controle: a mesma guarda, do outro lado"
withmutant kg alive-eperm; [ $? != 0 ]; ok $? "  sem a separação (EPERM nunca levanta) o EPERM de filho VIVO é engolido"
mutate 'rc = p.poll()  # o filho pode ter saído' 'rc = None  # o filho pode ter saído'; ok $? "controle: o poll depois do TimeoutExpired existe"
withmutant harness race "$REQ_OK"; [ "$RC" = 0 ] && ! has "$T/err" "passou de"; ok $? "  sem SÓ ele a corrida 'o filho já tinha terminado' segue 0: a decisão pelo código do wait() depois do kill a cobre (duas guardas em profundidade; cada uma é provada por si)"
mutate 'rc = p.poll()  # o filho pode ter saído' 'rc = None  # o filho pode ter saído' 'if rc == -signal.SIGKILL:' 'if True:'; ok $? "controle: as duas guardas da corrida existem"
withmutant harness race "$REQ_OK"; [ "$RC" = 124 ] && has "$T/err" "passou de"; ok $? "  sem as DUAS a corrida 'o filho já tinha terminado' vira 124 'passou do prazo'"
mutate 'return "filho-nao-encerrado"' 'return "filho-encerrado"'; ok $? "controle: end_children separa 'encerrei' de 'o kill levantou'"
withmutant harness termnokill "$REQ_OK"; lastlog "done killed sig=15 filho-encerrado" && ! lastlog "filho-nao-encerrado"; ok $? "  sem a separação o log afirma 'filho-encerrado' mesmo com o kill levantando (e a linha de desfecho existe: sem ela o 'não tem filho-nao-encerrado' passaria vazio)"
mutate 'LOG_BAD.sub("?", f)[:200]' 're.sub(r"[\t\r\n]", " ", f)[:200]'; ok $? "controle: o log higieniza TODOS os campos (não só TAB/CR/LF, como antes)"
withmutant call bd $'\x1b]0;evil\x07x'; ! logclean; ok $? "  sem isso o MESMO argumento com ESC/BEL chega cru ao log"
mutate '    Rule("bd", ["comment"], [("id", 1, 1), ("text", 1, 50)], {}, owner_lock=True),
' ''; ok $? "controle: a regra 'bd comment <id> <texto>...' existe na RULES"
b=$(calls); withmutant call bd comment ga-1 'SEGREDO-4711 texto do comentário'; [ "$RC" = 77 ] && [ "$(calls)" = "$b" ] && ! grep -q 'SEGREDO-4711' "$LOGF"; ok $? "  sem a regra o MESMO pedido é recusado e o grep do log também passa: é o 'RODOU' (rc 0 + uma chamada) do caso do SEGREDO que prova o caminho, não o grep"
mutate 'if _LAUNCH["on"]:' 'if False:'; ok $? "controle: o handler de sinal adia o sinal enquanto o Popen está em curso"
rm -f "$FB/sleep.pid"; withmutant harness termpopen "$(rq gc "$ID" session nudge gastown.mayor SLEEP)"
lastlog "done killed sig=15 sem-filho-registrado"; ok $? "  sem o adiamento o MESMO caso volta a sair com 'sem-filho-registrado' (o comando RODANDO, o handler sem filho para matar)"
[ -s "$FB/sleep.pid" ] && kill "$(cat "$FB/sleep.pid")" 2>/dev/null; rm -f "$FB/sleep.pid"  # (o neto que o mutante deixou vivo)
mutate 'if rc == -signal.SIGKILL:' 'if True:'; ok $? "controle: o código do wait() depois do kill decide entre 'estourou' (morreu do NOSSO SIGKILL) e 'saiu sozinho antes do kill'"
withmutant harness race2 "$REQ_OK"; [ "$RC" = 124 ] && has "$T/err" "passou de"; ok $? "  sem essa decisão a corrida volta a perder o código real do filho (124 'passou do prazo' com o comando já terminado)"

echo
if [ "$skipped" -gt 0 ]; then echo "AVISO: $skipped caso(s) NÃO rodaram (SKIP acima) — não contam como passou"; fi
echo "$((n-fails))/$n ok, $fails falharam, $skipped pulados"
exit $((fails > 0))
