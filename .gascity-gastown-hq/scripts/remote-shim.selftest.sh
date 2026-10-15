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
HOOKENV='{"GC_ALIAS":"gastown.dog-1","GC_AGENT":"gastown.dog-1","GC_SESSION_NAME":"dog-gavycydh","GC_MANAGED_SESSION_HOOK":"1","GC_HOOK_EVENT_NAME":"SessionStart"}'
b=$(calls); wrap "$(rq gc "$HOOKENV" prime --hook)"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "hook=1/SessionStart" && lastis "argv=[prime][--hook]"; ok $? "gc prime --hook (decisão do Mayor) + GC_MANAGED_SESSION_HOOK/GC_HOOK_EVENT_NAME chegam ao gc"
b=$(calls); wrap "$(rq gc "$HOOKENV" prime --hook --hook-format codex)"; [ "$RC" = 0 ] && [ "$(calls)" = $((b+1)) ] && lastis "argv=[prime][--hook][--hook-format][codex]"; ok $? "gc prime --hook --hook-format codex (a forma que o hook REAL do mini manda)"
allowed "gc handoff --auto (decisão do Mayor)" gc handoff --auto; lastis "argv=[handoff][--auto]"; ok $? "  argv canônico"
allowed 'gc handoff --auto "context cycle" (a forma que o hook REAL manda)' gc handoff --auto "context cycle"; lastis "argv=[handoff][--auto][context cycle]"; ok $? "  argv canônico"
allowed "gc nudge drain --inject (decisão do Mayor)" gc nudge drain --inject; lastis "argv=[nudge][drain][--inject]"; ok $? "  argv canônico"
allowed "gate-done (executável configurado)" gate-done; lastis "gatedone	cwd=$CITY"; ok $? "  roda o gatedone da config, na cidade"
call bd close ga-1 --reason FAIL7; [ "$RC" = 7 ] && has "$T/err" "fake-err"; ok $? "o código de saída (7) e o stderr do comando passam adiante"
call gc mail check --inject; [ ! -e "$T/PWNED-bashenv" ] && [ ! -e "$T/PWNED-pythonpath" ]; ok $? "higiene: BASH_ENV e PYTHONPATH do ambiente de entrada não executaram nada"
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
denied "id com ';'" "fora do formato" bd show 'ga-1;id'
denied "id com \$()" "fora do formato" bd show 'ga-$(id)'
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
denied "gc session nudge --delivery inventado" "fora do formato" gc session nudge mayor x --delivery now
denied "gc session nudge --delivery immediate" "fora do formato" gc session nudge gastown.mayor oi --delivery immediate
denied "gc session nudge para alvo fora do nudge_pattern" "nudge_pattern" gc session nudge outra-sessao oi
printf '{"city":"%s","identity_pattern":"(gastown\\\\.dog-1|dog-gavycydh)","bin_dirs":["%s"]}' "$CITY" "$FB" > "$T/conf-nonudge.json"
CONF_OVERRIDE="$T/conf-nonudge.json" denied "gc session nudge com a config SEM nudge_pattern" "sem a chave" gc session nudge gastown.mayor oi
denied "ferramenta dolt" "comando fora da lista" dolt sql
denied "ferramenta bw" "comando fora da lista" bw get password x
denied "ferramenta security" "comando fora da lista" security find-generic-password
denied "ferramenta sh" "comando fora da lista" sh -c id
denied "ferramenta ssh" "comando fora da lista" ssh outro
denied "gate-done com flag" "flag fora da lista" gate-done --bead ga-1
denied "gate-done com argumento" "argumento a mais" gate-done ga-1

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
sleep 0.3; [ -s "$FB/sleep.pid" ] && ! kill -0 "$(cat "$FB/sleep.pid")" 2>/dev/null; ok $? "o timeout mata o GRUPO (o neto 'sleep 37' não sobrevive)"
call bd comment ga-1 'SEGREDO-4711 texto do comentário'
! grep -q 'SEGREDO-4711' "$LOGF"; ok $? "o log de auditoria não guarda o texto do argumento"
has "$LOGF" "203.0.113.9"; ok $? "o log guarda o ip do cliente (SSH_CLIENT)"
has "$LOGF" "gastown.dog-1	ok	bd [-C <rig>] close <id> [--json] [--reason|-r <text>]"; ok $? "o log guarda alias, veredito e a regra"
grep -P '\tok\t' "$LOGF" >/dev/null 2>&1 || grep -E "$(printf '\t')ok$(printf '\t')" "$LOGF" >/dev/null; ok $? "o log tem linhas 'ok' (gravadas ANTES de executar)"
has "$LOGF" "done rc=124"; ok $? "o log tem 'done rc=124' do caso do timeout"
has "$LOGF" "refused"; ok $? "o log registra recusas"
[ "$(stat -f '%Lp' "$LOGF" 2>/dev/null || stat -c '%a' "$LOGF")" = 600 ]; ok $? "o log é 0600"
call bd close ga-1 --reason BREAKLOG; [ "$RC" = 0 ] && has "$T/err" "não consegui gravar o desfecho"; ok $? "desfecho que não grava no log: o comando rodou (rc 0) e o aviso diz que o log ficou sem o desfecho"
rmdir "$LOGF" 2>/dev/null  # (o falso trocou o log por uma pasta; a próxima chamada o recria)
python3 -I - "$W" <<'EOF2'
import importlib.util, subprocess, sys
s = importlib.util.spec_from_file_location("w", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
p = subprocess.Popen(["true"], start_new_session=True); p.wait()
m.kill_group(p)  # o grupo já não existe: não pode levantar
EOF2
ok $? "kill_group: grupo cujo filho já saiu não vira erro (a corrida entre o fim do filho e o kill)"

echo "== authorized-line"
line=$(python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" --from "127.0.0.1,10.0.0.0/8"); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ]; ok $? "imprime UMA linha"
case "$line" in restrict,from=\"127.0.0.1,10.0.0.0/8\",command=\"*\ -I\ *serve\ --config\ *\"\ ssh-ed25519\ AAAA*\ remote-shim-hetzner) true;; *) false;; esac; ok $? "forma: restrict, from=, command=\"<python> -I <wrapper> serve --config <conf>\", chave, comentário fixo"
has <(printf '%s' "$line") "alguem@servidor" ; [ $? != 0 ]; ok $? "o comentário da chave original não vai (nem nada além do tipo e do blob)"
python3 -I "$W" authorized-line --config "$CONF" --pubkey "$KD/user_key.pub" | grep -q '^restrict,command='; ok $? "sem --from: restrict,command= (sem from)"
QD="$T/dir com espaço"; QQ="$T/q\"uote"; mkdir -p "$QD" "$QQ"; cp "$CONF" "$QD/conf.json"; cp "$CONF" "$QQ/conf.json"
for c in "$QD/conf.json" "$QQ/conf.json"; do
  l=$(python3 -I "$W" authorized-line --config "$c" --pubkey "$KD/user_key.pub")
  python3 -I - "$l" "$c" <<'EOF2'
import re, shlex, sys
line, conf = sys.argv[1], sys.argv[2]
m = re.match(r'restrict,command="((?:[^"\\]|\\.)*)" ssh-ed25519 ', line)
argv = shlex.split(re.sub(r'\\(["\\])', r'\1', m.group(1)))  # o que o sshd tira das aspas do authorized_keys e entrega ao shell
sys.exit(0 if argv[1] == "-I" and argv[-3:] == ["serve", "--config", conf] else 1)
EOF2
  ok $? "  caminho com espaço/aspas ($(basename "$(dirname "$c")")) volta inteiro depois do authorized_keys e do shell"
done
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
else
  skip "sshd de verdade: não subiu (sshd=${SSHD:-ausente}) — 8 casos da chave/forced-command ficaram SEM rodar; os outros casos NÃO provam que a chave só roda o wrapper"
  skipped=$((skipped+7))
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

echo "== controle negativo: apagar a guarda faz o MESMO caso se comportar diferente"
mutate() {  # mutate 'texto a trocar' 'texto novo' → $T/mutant.py (falha se o texto não está no wrapper: o controle não pode virar vazio)
  python3 -I - "$W" "$T/mutant.py" "$1" "$2" <<'EOF2'
import sys
s = open(sys.argv[1]).read()
if sys.argv[3] not in s:
    sys.exit(3)
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4], 1))
EOF2
}
withmutant() { local W0=$W; W="$T/mutant.py"; "$@"; W=$W0; }
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

echo
if [ "$skipped" -gt 0 ]; then echo "AVISO: $skipped caso(s) NÃO rodaram (SKIP acima) — não contam como passou"; fi
echo "$((n-fails))/$n ok, $fails falharam, $skipped pulados"
exit $((fails > 0))
