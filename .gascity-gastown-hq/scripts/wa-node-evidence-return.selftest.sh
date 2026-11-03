#!/usr/bin/env bash
# wa-node-evidence-return.selftest.sh — hermético: o log de rota, a cidade e o `bd` são de mentira numa pasta temporária; nada de cidade real, gc ou rede. (ga-t05a1z9, item 4)
#
# Contents
#   Fixtures · Ida confirmada · O que NÃO é ida · Erro lido na bead · Log e uso · Controle negativo · Como rodar
#
# FIXTURES: as linhas imitam o que os escritores de verdade gravam, não a leitura do autor do relatório. `pilot_s` = a linha de `_pilot_wa_node_decide` (pilot-dispatcher.sh: ts,event,bead,mode,rc,out,spawn,slots);
#   `apply_s` = o `jlog` de wa-node-dispatch.sh (ts,event,bead,rc,detail; "despachada para ..." só depois da releitura que confirma a escrita; "dry-run: iria para ..." no --dry-run); `rel` = o `release` (detail "solta").
#   O `bd` de mentira (um script) guarda uma bead por arquivo na pasta da loja e registra quem foi lido.
# CASOS: ida = linha do Pilot (label/auto, rc 0) + "despachada" do despachante · `release` depois da ida NÃO é erro (a sonda do gate) · shadow, dry-run e linha sem confirmação NÃO são ida
#   · rc 13/124/128-255 = ida INCERTA (contada, nomeada; 125-127 não) · modo desconhecido · `out` ilegível = "não sei" · despacho sem linha do Pilot · a ÚLTIMA ida manda · erro lido na bead:
#   recusa do worker, rótulo do gate, sem sinal, NÃO LIDA (bd ausente, rc != 0, JSON ruim, outra bead, loja sem rota) · log ausente/vazio/ilegível · --hours com dígito não-ASCII = rc 2.
# FRONTEIRAS (ga-eedg7fw, hq-mutants): relógio de mentira (inproc.py/units.py) para cair EXATAMENTE em cada limite: since, o pareamento 0..120 s do dry-run, o despacho sem linha em since, o orçamento de 120 s das leituras de bead.
#   Mutantes EQUIVALENTES do lastro, sem caso (nenhum teste de comportamento os distingue): (a) `nao_conf[bead] = nao_conf.get(bead, 0) + 1` com `0 → 1`: só as CHAVES de nao_conf são lidas (sorted(nao_conf), len(nao_conf)), nunca o valor;
#   (b) `1 <= int(a.hours) <= 99999` com `99999 → 100000`: o `re.fullmatch("[0-9]{1,5}")` da mesma linha já impede um 6º dígito, então o teto 99999 nunca é o que barra.
#   Rodízio de 03/11 (ga-59jrj3d): (a') `nao_conf.get(bead, 0) + 1` com `+ 1 → + 0` (c97a912d1c): o mesmo motivo de (a), o valor nunca é lido. (c) `text=True → False` no `bd show` (b0c724ee37): só difere se o `bd` imprimir bytes que não são UTF-8, e aí o ORIGINAL
#   morre com UnicodeDecodeError (medido: rc 1 com traceback, o `except (OSError, SubprocessError)` não o pega) enquanto o mutante diz "bd show: JSON ilegível" e segue: matar o mutante exigiria fixar um travamento como esperado, ou consertar o script; fica vivo e a falha vai no relato da entrega.
# CONTROLE NEGATIVO: cada mutante troca UMA linha do relatório numa cópia e o caso designado tem de reprovar.
# COMO RODAR: bash scripts/wa-node-evidence-return.selftest.sh   (macOS /bin/bash 3.2 e Linux; ~20 s no nó)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REP="$HERE/wa-node-evidence-return.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-evret.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
PY=${WA_NODE_SELFTEST_PY:-python3}

NOW=$(date +%s)
iso() { "$PY" -I -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
isos() { iso $((NOW - $1)); }   # carimbo de <segundos> atrás
# out_of <info JSON array | -> : o `out` como o Pilot o grava (o stdout do classificador, JSON puro, dentro de uma string JSON); "-" = vazio
out_of() { if [ "$1" = "-" ]; then printf '""'; else "$PY" -I -c 'import json,sys; print(json.dumps(json.dumps({"verdict":"node","basis":"text","reasons":["prova-no-texto:1-teste(s)+1-codigo"],"paths":[],"tests":[],"info":json.loads(sys.argv[1])})))' "$1"; fi; }
pilot_s() { printf '{"ts":"%s","event":"pilot-node-route","bead":"%s","mode":"%s","rc":%s,"out":%s,"spawn":"pilot","slots":1}\n' "$(isos "$1")" "$2" "$3" "$4" "$(out_of "$5")"; }   # pilot_s <seg atrás> <bead> <modo> <rc> <info|->
apply_s() { printf '{"ts":"%s","event":"apply","bead":"%s","rc":%s,"detail":"%s"}\n' "$(isos "$1")" "$2" "$3" "$4"; }                                                          # apply_s <seg atrás> <bead> <rc> <detalhe>
ida() { apply_s $(($1*60+2)) "$2" 0 "despachada para wa-worker-remote-1 (text)"; pilot_s $(($1*60)) "$2" auto 0 "$3"; }                                                         # ida <min atrás> <bead> <info|->: o despacho de verdade
rel() { printf '{"ts":"%s","event":"release","bead":"%s","rc":%s,"detail":"solta"}\n' "$(isos $(($1*60)))" "$2" "${3:-0}"; }

# a cidade de mentira: rotas, uma loja para o prefixo wa, e o bd de mentira
CITY="$T/city"; STORE="$CITY/store-wa"; mkdir -p "$STORE" "$CITY/.beads"
printf '{"prefix":"ga","path":"."}\n{"prefix":"wa","path":"store-wa"}\n' > "$CITY/.beads/routes.jsonl"
FBD="$T/bd"; CALLS="$T/bd-calls"
cat > "$FBD" <<'EOF'
#!/bin/bash
# bd -C <loja> show <id> --json  — a bead é o arquivo <loja>/<id>.json; <id>.rc (opcional) = rc de saída, DEPOIS de imprimir
[ "${1:-}" = "-C" ] && [ "${3:-}" = "show" ] && [ "${5:-}" = "--json" ] || exit 64
echo "$4" >> "${FAKE_BD_CALLS:?}"
[ -f "$2/$4.json" ] || exit 1
cat "$2/$4.json"
[ -f "$2/$4.rc" ] && exit "$(cat "$2/$4.rc")"
exit 0
EOF
chmod +x "$FBD"; export FAKE_BD_CALLS="$CALLS"
# bead <id> [labels JSON] [metadata JSON]
bead() { local lb="${2:-}" md="${3:-}"; [ -n "$lb" ] || lb='["ctx:ready"]'; [ -n "$md" ] || md='{}'
  printf '[{"id":"%s","labels":%s,"metadata":%s,"status":"in_progress","assignee":""}]\n' "$1" "$lb" "$md" > "$STORE/$1.json"; }

L="$T/rota.jsonl"
newcase() { NOW=$(date +%s); find "$STORE" -mindepth 1 -delete; : > "$CALLS"; }
run() { OUT=$("$PY" -I "${CLS:-$REP}" --route-log "$L" --city "$CITY" --bd "${BDCMD:-$FBD}" "$@" 2>"$T/err"); RC=$?; }
expect() { # expect <rótulo> <rc> <regex da saída> [args...]
  local label="$1" rc="$2" rx="$3"; shift 3; run "$@"
  if [ "$RC" = "$rc" ] && { [ "$rx" = "-" ] || printf '%s' "$OUT" | grep -q -E -e "$rx"; }; then ok "$label"; else bad "$label (rc=$RC, esperado $rc; saída: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-300))"; fi
}
expect_not() { # expect_not <rótulo> <rc> <regex que NÃO pode aparecer> [args...]
  local label="$1" rc="$2" rx="$3"; shift 3; run "$@"
  if [ "$RC" = "$rc" ] && ! printf '%s' "$OUT" | grep -q -E -e "$rx"; then ok "$label"; else bad "$label (rc=$RC, esperado $rc sem /$rx/; saída: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-300))"; fi
}
EV='["producao","evidencia-de-dado:queue.db"]'; DOC='["evidencia-de-doc:docs/data_dictionary.md"]'; SEM='["producao","tela-ao-vivo"]'
J='--json'

# ---- ida confirmada + erro lido na bead
newcase; bead wa-a; { ida 120 wa-a "$EV"; } > "$L"
expect "ida confirmada com evidência e bead sem sinal = 'sem sinal de erro'" 0 '"foram_ao_no": 1, "com_evidencia": 1, "sem_evidencia": 0.*"recusadas_pelo_no": \[\], "reprovadas_no_gate": \[\], "sem_sinal_de_erro": \["wa-a"\]' $J
expect "texto: as três linhas da bead + o limite do que 'sem sinal' quer dizer" 0 'sem sinal de erro \(construindo, entregue, solta após a entrega, ou ida desfeita por falha de sessão.*: 1  wa-a'
newcase; bead wa-r; { ida 140 wa-r "$EV"; rel 70 wa-r; } > "$L"
expect "release DEPOIS da ida (a entrega) NÃO é custo do erro (a sonda do gate)" 0 '"recusadas_pelo_no": \[\], "reprovadas_no_gate": \[\], "sem_sinal_de_erro": \["wa-r"\]' $J
expect_not "e o texto não chama a soltura de custo do erro" 0 'soltas depois'
newcase; bead wa-b '["ctx:ready"]' '{"athos.node_recusa":"precisa do banco"}'; { ida 100 wa-b "$EV"; } > "$L"
expect "athos.node_recusa preenchido = o worker do nó devolveu" 0 '"recusadas_pelo_no": \["wa-b"\], "reprovadas_no_gate": \[\], "sem_sinal_de_erro": \[\]' $J
expect "texto: a devolução vem com o nome da marca" 0 'o worker do nó devolveu \(athos.node_recusa; custo do erro\): 1  wa-b'
newcase; bead wa-bl '["ctx:ready"]' '{"athos.node_recusa":"  "}'; { ida 100 wa-bl "$EV"; } > "$L"
expect "athos.node_recusa em branco NÃO conta como devolvida" 0 '"recusadas_pelo_no": \[\].*"sem_sinal_de_erro": \["wa-bl"\]' $J
newcase; bead wa-g1 '["gate:needs-fix","lane:small"]'; bead wa-g2 '["gate:fix-attempt:2"]'; bead wa-g3 '["gate:failed"]'; bead wa-g4 '["gate:approved","story:in-flight"]'
{ ida 100 wa-g1 "$EV"; ida 99 wa-g2 "$EV"; ida 98 wa-g3 "$EV"; ida 97 wa-g4 "$EV"; } > "$L"
expect "rótulos do gate (needs-fix, fix-attempt:N, failed) = reprovada; outro gate:* NÃO" 0 '"reprovadas_no_gate": \["wa-g1", "wa-g2", "wa-g3"\], "sem_sinal_de_erro": \["wa-g4"\]' $J
newcase; bead wa-both '["gate:needs-fix"]' '{"athos.node_recusa":"x"}'; { ida 100 wa-both "$EV"; } > "$L"
expect "recusa + gate na mesma bead: conta UMA vez, como recusa" 0 '"recusadas_pelo_no": \["wa-both"\], "reprovadas_no_gate": \[\]' $J
newcase; printf '[{"id":"wa-nolab","status":"open"}]\n' > "$STORE/wa-nolab.json"; { ida 100 wa-nolab "$EV"; } > "$L"
expect "bead lida sem labels/metadata = nenhum (não é 'não lida')" 0 '"sem_sinal_de_erro": \["wa-nolab"\], "beads_nao_lidas": \[\]' $J
newcase; bead wa-d; { ida 100 wa-d "$DOC"; } > "$L"
expect "evidencia-de-doc também conta" 0 '"com_evidencia": 1' $J
newcase; bead wa-pre; { pilot_s 3600 wa-pre auto 0 "$EV" | sed 's/"out":"\(.*\)","spawn"/"out":"[wa-node-dispatch] despachada\\n\1","spawn"/'; apply_s 3602 wa-pre 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"
expect "out com texto ANTES do JSON: lê a última linha que é objeto" 0 '"com_evidencia": 1' $J
newcase; bead wa-sem; { ida 100 wa-sem "$SEM"; } > "$L"
expect "ida SEM evidência não entra na conta de erro, só em sem_evidencia" 0 '"foram_ao_no": 1, "com_evidencia": 0, "sem_evidencia": 1' $J
if ! grep -q 'wa-sem' "$CALLS"; then ok "e a bead sem evidência nem é lida no bd"; else bad "bead sem evidência foi lida no bd"; fi
expect "texto: nenhuma bead com evidência" 0 'nenhuma bead com evidência'
# a ÚLTIMA ida confirmada manda
newcase; bead wa-l; { ida 200 wa-l "$EV"; ida 100 wa-l "$SEM"; } > "$L"
expect "a última ida SEM evidência (texto editado) vale; a anterior não" 0 '"com_evidencia": 0, "sem_evidencia": 1' $J
newcase; bead wa-l; { ida 200 wa-l "$SEM"; ida 100 wa-l "$EV"; } > "$L"
expect "a última ida COM evidência vale" 0 '"com_evidencia": 1, "sem_evidencia": 0' $J
# janela
newcase; bead wa-w; { ida $((60*24*3)) wa-w "$EV"; } > "$L"
expect "ida fora da janela (3 dias, janela de 24 h) fica de fora" 0 '"foram_ao_no": 0' $J --hours 24
expect "a mesma ida entra com a janela padrão (7 dias)" 0 '"foram_ao_no": 1' $J
newcase; bead wa-e; { pilot_s 3560 wa-e auto 0 "$EV"; apply_s 3650 wa-e 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"
expect "a linha do despachante logo ANTES da janela ainda pareia com a do Pilot dentro dela" 0 '"foram_ao_no": 1' $J --hours 1

# ---- o que NÃO é ida
newcase; bead wa-s; { pilot_s 100 wa-s shadow 0 "$EV"; } > "$L"
expect "modo shadow rc 0 (só o check; nada atribuído) NÃO é ida (a sonda do gate)" 0 '"foram_ao_no": 0, "com_evidencia": 0.*"sombra_linhas": 1, "sombra_beads": 1' $J
expect "texto: a sombra é informada, fora das contas" 0 'info: 1 linha\(s\) em modo shadow \(1 bead\(s\)\)'
newcase; bead wa-y; { apply_s 122 wa-y 0 "dry-run: iria para wa-worker-remote-1 (text)"; pilot_s 120 wa-y auto 0 "$EV"; } > "$L"
expect "dry-run (o apply não escreveu) NÃO é ida" 0 '"foram_ao_no": 0.*"dry_run_linhas": 1, "sem_confirmacao_do_despachante": \[\]' $J
newcase; bead wa-x; { pilot_s 120 wa-x auto 0 "$EV"; } > "$L"
expect "linha do Pilot rc 0 SEM nada do despachante: não é ida, vem nomeada" 0 '"foram_ao_no": 0.*"sem_confirmacao_do_despachante": \["wa-x"\]' $J
expect "texto: AVISA da linha sem confirmação" 0 'AVISO: 1 bead\(s\) com linha do Pilot rc 0 sem `despachada` do despachante.*: wa-x'
newcase; bead wa-far; { apply_s 900 wa-far 0 "despachada para wa-worker-remote-1 (text)"; pilot_s 120 wa-far auto 0 "$EV"; } > "$L"
expect "despachada 13 min ANTES da linha do Pilot (fora do prazo de 120 s) não pareia" 0 '"foram_ao_no": 0.*"sem_confirmacao_do_despachante": \["wa-far"\]' $J
newcase; bead wa-post; { pilot_s 120 wa-post auto 0 "$EV"; apply_s 110 wa-post 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"
expect "despachada POSTERIOR à linha do Pilot não pareia (o Pilot grava depois do apply)" 0 '"foram_ao_no": 0.*"sem_confirmacao_do_despachante": \["wa-post"\]' $J
newcase; bead wa-one; { apply_s 122 wa-one 0 "despachada para wa-worker-remote-1 (text)"; pilot_s 120 wa-one auto 0 "$EV"; pilot_s 60 wa-one auto 0 "$EV"; } > "$L"
expect "uma 'despachada' serve a UMA linha do Pilot: a segunda fica sem confirmação" 0 '"foram_ao_no": 1.*"sem_confirmacao_do_despachante": \["wa-one"\]' $J
newcase; bead wa-h; { apply_s 100 wa-h 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"
expect "despacho SEM linha do Pilot (apply à mão): não é ida contada, vem nomeado" 0 '"foram_ao_no": 0.*"despachos_sem_linha_do_pilot": \["wa-h"\]' $J
expect "texto: AVISA que a evidência é desconhecida" 0 'AVISO: 1 bead\(s\) com despacho sem linha do Pilot.*: wa-h'
newcase; bead wa-m; { pilot_s 120 wa-m auto 13 "-"; rel 60 wa-m; } > "$L"
expect "rc 13 (escrita desconhecida) + release depois: a bead é ida INCERTA, nomeada (a sonda do gate)" 0 '"foram_ao_no": 0.*"idas_incertas": \["wa-m"\]' $J
expect "texto: AVISA da ida incerta" 0 'AVISO: 1 bead\(s\) com ida INCERTA \(rc 13, 124 ou 128-255'
newcase; { pilot_s 100 wa-i124 auto 124 "-"; pilot_s 99 wa-i128 auto 128 "-"; pilot_s 98 wa-i137 auto 137 "-"; pilot_s 97 wa-i255 auto 255 "-"
           pilot_s 96 wa-n125 auto 125 "-"; pilot_s 95 wa-n127 auto 127 "-"; pilot_s 94 wa-n12 auto 12 "-"; pilot_s 93 wa-n10 auto 10 "-"; pilot_s 92 wa-n1 label 1 "-"; } > "$L"
expect "incertas: 124, 128, 137 e 255 sim; 125, 127, 12, 10 e 1 (nada rodou / recusa) não" 0 '"idas_incertas": \["wa-i124", "wa-i128", "wa-i137", "wa-i255"\]' $J
newcase; { pilot_s 100 wa-q banana 0 "$EV"; } > "$L"
expect "modo desconhecido: não é ida, contado" 0 '"foram_ao_no": 0.*"modo_desconhecido_linhas": 1' $J
newcase; bead wa-u; { ida 100 wa-u -; } > "$L"
expect "ida confirmada com out vazio: 'não sei', nomeada, fora das duas contas" 0 '"foram_ao_no": 1, "com_evidencia": 0, "sem_evidencia": 0, "evidencia_desconhecida": \["wa-u"\]' $J
expect "texto: AVISA que não dá para saber" 0 'AVISO: 1 ida\(s\) ao nó sem `out` legível.*: wa-u'
newcase; { apply_s 62 wa-c2 0 "despachada para wa-worker-remote-1 (text)"; printf '{"ts":"%s","event":"pilot-node-route","bead":"wa-c2","mode":"auto","rc":0,"out":"{\\"verdict\\": corrupt"}\n' "$(isos 60)"; } > "$L"
expect "out com JSON corrompido: 'não sei', nunca 'sem evidência'" 0 '"sem_evidencia": 0, "evidencia_desconhecida": \["wa-c2"\]' $J
newcase; { apply_s 100 wa-ap 0 "outra coisa"; apply_s 100 wa-ap2 12 "slot-sem-alias-livre"; } > "$L"
expect "apply rc 0 que não diz 'despachada' nem 'dry-run': contado; apply rc != 0 é só recusa, ignorado" 0 '"apply_nao_reconhecido": 1, "linhas_ilegiveis": 0' $J

# ---- erro lido na bead: o terceiro estado
newcase; bead wa-a; { ida 100 wa-a "$EV"; } > "$L"; BDCMD="$T/nao-existe-bd"
expect "bd AUSENTE: a bead é NÃO LIDA, nunca 'sem sinal'" 0 '"sem_sinal_de_erro": \[\], "beads_nao_lidas": \["wa-a"\]' $J
if grep -q 'wa-a não lida' "$T/err"; then ok "bd ausente: o motivo vai ao stderr"; else bad "bd ausente: stderr sem motivo ($(cat "$T/err"))"; fi
expect "texto: AVISA das não lidas" 0 'AVISO: 1 bead\(s\) NÃO LIDA\(S\)'
BDCMD=""
newcase; { ida 100 wa-gone "$EV"; } > "$L"
expect "bead que o bd não acha (rc 1): NÃO LIDA" 0 '"sem_sinal_de_erro": \[\], "beads_nao_lidas": \["wa-gone"\]' $J
newcase; bead wa-rc '["ctx:ready"]' '{"athos.node_recusa":"x"}'; echo 3 > "$STORE/wa-rc.rc"; { ida 100 wa-rc "$EV"; } > "$L"
expect "bd com rc != 0, mesmo imprimindo a bead: NÃO LIDA" 0 '"recusadas_pelo_no": \[\].*"beads_nao_lidas": \["wa-rc"\]' $J
newcase; echo 'isto não é json' > "$STORE/wa-bj.json"; printf '[]\n' > "$STORE/wa-emp.json"; printf '[{"id":"wa-outra"}]\n' > "$STORE/wa-oid.json"
printf '[{"id":"wa-tl","labels":"gate:needs-fix"}]\n' > "$STORE/wa-tl.json"; printf '[{"id":"wa-tm","metadata":"x"}]\n' > "$STORE/wa-tm.json"
{ ida 100 wa-bj "$EV"; ida 99 wa-emp "$EV"; ida 98 wa-oid "$EV"; ida 97 wa-tl "$EV"; ida 96 wa-tm "$EV"; } > "$L"
expect "JSON ruim, lista vazia, outra bead, labels que não é lista, metadata que não é objeto: todas NÃO LIDAS" 0 '"sem_sinal_de_erro": \[\], "beads_nao_lidas": \["wa-bj", "wa-emp", "wa-oid", "wa-tl", "wa-tm"\]' $J
newcase; { ida 100 zz-1 "$EV"; } > "$L"
expect "prefixo sem rota em routes.jsonl: NÃO LIDA" 0 '"beads_nao_lidas": \["zz-1"\]' $J
newcase; bead wa-a; { ida 100 wa-a "$EV"; } > "$L"
expect "cidade sem routes.jsonl: NÃO LIDA" 0 '"beads_nao_lidas": \["wa-a"\]' $J --city "$T/outra-cidade"

# ---- log e uso
newcase; bead wa-i; { ida 60 wa-i "$EV"; echo 'linha corrupt: nao e json'; echo '{"event":"release"}'; echo '[1,2]'; pilot_s 50 wa-t auto '"0"' "$EV"; apply_s 40 wa-t2 'null' "x"; printf '{"ts":"%s","event":"classify","bead":"wa-z","rc":0,"detail":"node"}\n' "$(isos 30)"; } > "$L"
expect "linhas ilegíveis (lixo, sem bead/hora, não-objeto, rc que não é número) são CONTADAS; classify/read/release válidos não" 0 '"linhas_ilegiveis": 5' $J
expect "e o texto AVISA delas" 0 'AVISO: 5 linha\(s\) do log de rota ilegível'
expect "a ida legível ao lado do lixo continua valendo" 0 '"com_evidencia": 1' $J
: > "$L"
expect "log VAZIO (existe, sem linha) = nenhuma bead, rc 0" 0 'nenhuma bead com evidência'
rm -f "$L"
expect "log AUSENTE = rc 3, e diz que NÃO é zero beads" 3 '-'
if grep -q 'ausente' "$T/err" && grep -q 'NÃO é zero beads' "$T/err"; then ok "log ausente: a razão vai ao stderr"; else bad "log ausente: stderr sem a razão ($(cat "$T/err"))"; fi
mkdir "$L"
expect "log ILEGÍVEL (é uma pasta) = rc 3" 3 '-'
if grep -q 'ilegível' "$T/err"; then ok "log ilegível: a razão vai ao stderr"; else bad "log ilegível: stderr sem a razão ($(cat "$T/err"))"; fi
rmdir "$L"
: > "$L"
expect "--hours 0 = uso errado, rc 2" 2 '-' --hours 0
expect "--hours abc = uso errado, rc 2" 2 '-' --hours abc
expect "--hours 100000 = uso errado, rc 2" 2 '-' --hours 100000
expect "--hours 99999 (o teto) vale: rc 0 e a janela sai como 99999 h" 0 'nas últimas 99999 h' --hours 99999
expect "--hours com dígito não-ASCII (²) = rc 2, não traceback" 2 '-' --hours "²"
expect "--hours com dígitos árabe-índicos = rc 2" 2 '-' --hours "١٢"
if ! grep -q Traceback "$T/err"; then ok "e sem traceback no stderr"; else bad "traceback no stderr"; fi
expect "argumento desconhecido = rc 2" 2 '-' --nada

# ---- fronteiras com RELÓGIO DE MENTIRA (ga-eedg7fw, hq-mutants): cair EXATAMENTE em cima de cada limite exige que "agora" seja um número que o teste escolhe.
# inproc.py roda o main() do relatório com time.time() fixo em $WNR_NOW (o resto é o programa de verdade: mesmos argumentos, mesmo stdout, mesmo rc); units.py chama
# funções direto, com o subprocess.run trocado por um de mentira (instantâneo: nenhum prazo de 0,5 s depende da carga da máquina) que registra o `timeout=` recebido.
cat > "$T/inproc.py" <<'PYEOF'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("wnr", os.environ["WNR_REP"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fixed = float(os.environ["WNR_NOW"])
time.time = lambda: fixed
sys.exit(m.main([os.environ["WNR_REP"]] + sys.argv[1:]))
PYEOF
cat > "$T/units.py" <<'PYEOF'
import contextlib, importlib.util, io, os, subprocess, sys, time
spec = importlib.util.spec_from_file_location("wnr", os.environ["WNR_REP"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
NOW = float(os.environ["WNR_NOW"]); time.time = lambda: NOW
city, bd, log = os.environ["WNR_CITY"], os.environ["WNR_BD"], os.environ["WNR_LOG"]
def chk(label, fn, want):
    try:
        got = fn()
    except Exception as e:   # uma função que EXPLODE onde devia devolver "não sei" é a falha que este teste existe para pegar
        print("FAIL %s (exceção %s: %s)" % (label, type(e).__name__, e)); return
    print(("ok   " if got == want else "FAIL ") + label + ("" if got == want else " (veio %r, esperado %r)" % (got, want)))
cj = m.classifier_json
chk("classifier_json(None) → None (não é texto: sem exceção)", lambda: cj(None), None)
chk("classifier_json(5) → None (não é texto: sem exceção)", lambda: cj(5), None)
chk("classifier_json('   ') → None (só espaço)", lambda: cj("   "), None)
chk("classifier_json: objeto sem 'info' → None", lambda: cj('{"verdict": 1}'), None)
chk("classifier_json: 'info' que não é lista → None", lambda: cj('{"info": "x"}'), None)
chk("classifier_json: JSON que não é objeto → None (sem exceção)", lambda: cj('[1]'), None)
chk("classifier_json: objeto com 'info' lista → o próprio dict", lambda: cj('{"info": ["a"]}'), {"info": ["a"]})
chk("classifier_json: texto antes do JSON → a última linha que é objeto", lambda: cj('despachada\n{"info": []}'), {"info": []})
chk("evidencia_da_ida(None) → None (out nulo = não sei)", lambda: m.evidencia_da_ida(None), None)
chk("evidencia_da_ida(5) → None (out que não é texto = não sei)", lambda: m.evidencia_da_ida(5), None)
calls = []
def fake_run(cmd, **kw):
    calls.append(kw.get("timeout"))
    return subprocess.CompletedProcess(cmd, 0, stdout='[{"id": "wa-bud", "labels": [], "metadata": {}}]', stderr="")
m.subprocess.run = fake_run
chk("estado_da_bead: restante == 0 → não lida ('orçamento de leitura esgotado'), o bd nem roda", lambda: (m.estado_da_bead(city, bd, "wa-bud", NOW), list(calls)), ((None, "orçamento de leitura esgotado"), []))
del calls[:]
chk("estado_da_bead: restante 0,5 s → lê a bead, com timeout=0,5", lambda: (m.estado_da_bead(city, bd, "wa-bud", NOW + 0.5), list(calls)), (("sem_sinal", ""), [0.5]))
del calls[:]
chk("estado_da_bead: restante 100 s → o prazo de UMA leitura (20 s) é o teto do timeout", lambda: (m.estado_da_bead(city, bd, "wa-bud", NOW + 100), list(calls)), (("sem_sinal", ""), [20]))
seen = []
real = m.estado_da_bead
def spy(c, b, bead, deadline):
    seen.append(deadline - NOW); return real(c, b, bead, deadline)
m.estado_da_bead = spy
with contextlib.redirect_stdout(io.StringIO()):
    rc = m.main(["x", "--route-log", log, "--city", city, "--bd", bd, "--json", "--hours", "1"])
chk("main: o orçamento de TODAS as leituras de bead juntas é de 120 s", lambda: (rc, seen), (0, [120.0]))
PYEOF
fixed_case() { newcase; NOW=1800000000; }   # newcase pega o relógio de verdade; aqui o "agora" é o do inproc.py/units.py
fexpect() { CLS="$T/inproc.py" WNR_REP="$REP" WNR_NOW="$NOW" expect "$@"; }
SD="despachada para wa-worker-remote-1 (text)"

# janela: a linha do Pilot EXATAMENTE em since (agora − horas) entra; um segundo antes não
fixed_case; bead wa-w1; { apply_s 3602 wa-w1 0 "$SD"; pilot_s 3600 wa-w1 auto 0 "$EV"; } > "$L"
fexpect "janela: a linha do Pilot EXATAMENTE em 'since' entra (a ida conta)" 0 '"foram_ao_no": 1' $J --hours 1
fixed_case; bead wa-w2; { apply_s 3603 wa-w2 0 "$SD"; pilot_s 3601 wa-w2 auto 0 "$EV"; } > "$L"
fexpect "janela: a linha do Pilot 1 s ANTES de 'since' não entra" 0 '"foram_ao_no": 0' $J --hours 1
# despacho sem linha do Pilot: só conta se foi na janela (o que veio até 120 s antes só serve para parear)
fixed_case; { apply_s 3600 wa-w3 0 "$SD"; } > "$L"
fexpect "despacho EXATAMENTE em 'since' e sem linha do Pilot → aparece em despachos_sem_linha_do_pilot" 0 '"despachos_sem_linha_do_pilot": \["wa-w3"\]' $J --hours 1
fixed_case; { apply_s 3601 wa-w3 0 "$SD"; } > "$L"
fexpect "despacho 1 s antes de 'since' (lido só para parear) e sem linha do Pilot → NÃO aparece" 0 '"despachos_sem_linha_do_pilot": \[\]' $J --hours 1
# dry-run: a linha do Pilot de 0 a 120 s DEPOIS do apply pareia (os dois extremos valem); 121 s depois ou antes do apply não
DR="dry-run: iria para wa-worker-remote-1 (text)"
for d in 0 120; do
  fixed_case; bead wa-d; { apply_s $((500 + d)) wa-d 0 "$DR"; pilot_s 500 wa-d auto 0 "$EV"; } > "$L"
  fexpect "dry-run: Pilot $d s depois do apply pareia (dry_run_linhas 1, não é ida nem 'sem confirmação')" 0 '"foram_ao_no": 0.*"dry_run_linhas": 1, "sem_confirmacao_do_despachante": \[\]' $J
done
fixed_case; bead wa-d; { apply_s 621 wa-d 0 "$DR"; pilot_s 500 wa-d auto 0 "$EV"; } > "$L"
fexpect "dry-run: Pilot 121 s depois do apply NÃO pareia (sem confirmação do despachante)" 0 '"dry_run_linhas": 0, "sem_confirmacao_do_despachante": \["wa-d"\]' $J
fixed_case; bead wa-d; { apply_s 499 wa-d 0 "$DR"; pilot_s 500 wa-d auto 0 "$EV"; } > "$L"
fexpect "dry-run: Pilot 1 s ANTES do apply (a linha do Pilot não pode preceder o despachante) NÃO pareia" 0 '"dry_run_linhas": 0, "sem_confirmacao_do_despachante": \["wa-d"\]' $J
fixed_case; bead wa-d2; { apply_s 600 wa-d2 0 "$DR"; pilot_s 590 wa-d2 auto 0 "$EV"; pilot_s 580 wa-d2 auto 0 "$EV"; } > "$L"
fexpect "dry-run: UM apply serve a UMA linha do Pilot (a 2ª fica sem confirmação)" 0 '"dry_run_linhas": 1, "sem_confirmacao_do_despachante": \["wa-d2"\]' $J
# dois applies ao alcance da 1ª linha do Pilot (70 s e 50 s antes dela), e a 2ª linha só alcança o mais recente (115 s contra 135 s): a 1ª fica com o MAIS RECENTE e a 2ª sobra sem confirmação (ga-59jrj3d)
fixed_case; bead wa-d3; { apply_s 400 wa-d3 0 "$DR"; apply_s 380 wa-d3 0 "$DR"; pilot_s 330 wa-d3 auto 0 "$EV"; pilot_s 265 wa-d3 auto 0 "$EV"; } > "$L"
fexpect "dry-run: dois applies ao alcance, a linha do Pilot fica com o MAIS RECENTE; a seguinte só alcançava esse e fica sem confirmação" 0 '"dry_run_linhas": 1, "sem_confirmacao_do_despachante": \["wa-d3"\]' $J
# um despacho e duas linhas do Pilot na janela: a 1ª (mais antiga) fica com ele, e é a evidência DELA que vale
fixed_case; bead wa-o; { apply_s 1000 wa-o 0 "$SD"; pilot_s 995 wa-o auto 0 "$EV"; pilot_s 990 wa-o auto 0 "$SEM"; } > "$L"
fexpect "duas linhas do Pilot, um despacho: a linha MAIS ANTIGA pareia (evidência True), a outra fica sem confirmação" 0 '"com_evidencia": 1, "sem_evidencia": 0.*"sem_confirmacao_do_despachante": \["wa-o"\]' $J
# linha com hora ilegível, bead vazio, bead que não é texto, sem bead: cada uma conta como ilegível (cada perna do `or` sozinha)
fixed_case
{ printf '{"ts":"nao-e-data","event":"apply","bead":"wa-b1","rc":0,"detail":"x"}\n'
  printf '{"ts":"%s","event":"apply","bead":"","rc":0,"detail":"x"}\n' "$(isos 100)"
  printf '{"ts":"%s","event":"apply","bead":123,"rc":0,"detail":"x"}\n' "$(isos 100)"
  printf '{"ts":"%s","event":"apply","rc":0,"detail":"x"}\n' "$(isos 100)"; } > "$L"
fexpect "linhas com hora ilegível / bead vazio / bead que não é texto / sem bead: as 4 contam como ilegíveis" 0 '"linhas_ilegiveis": 4' $J
# funções direto (units.py): classificador, `out` que não é texto, e o orçamento de leitura das beads
fixed_case; bead wa-bud; { ida 10 wa-bud "$EV"; } > "$L"     # ida <MINUTOS atrás>: 10 min cabe na janela de --hours 1 que o units.py usa
UOUT=$(WNR_REP="$REP" WNR_NOW="$NOW" WNR_CITY="$CITY" WNR_BD="$FBD" WNR_LOG="$L" "$PY" -I "$T/units.py" 2>"$T/uerr"); URC=$?
if [ "$URC" != 0 ]; then bad "units.py não terminou (rc=$URC; $(cut -c1-200 "$T/uerr"))"; fi
while IFS= read -r ul; do
  case "$ul" in "ok   "*) ok "${ul#ok   }" ;; "FAIL "*) bad "${ul#FAIL }" ;; *) bad "units.py: linha inesperada: $ul" ;; esac
done <<EOF_UNITS
$UOUT
EOF_UNITS
# o `out` de uma ida que não é texto: a ida conta e a evidência é DESCONHECIDA (nunca derruba o relatório)
fixed_case; bead wa-on; { apply_s 102 wa-on 0 "$SD"; printf '{"ts":"%s","event":"pilot-node-route","bead":"wa-on","mode":"auto","rc":0,"out":null,"spawn":"pilot","slots":1}\n' "$(isos 100)"; } > "$L"
fexpect "out nulo na linha do Pilot: a ida vale e a evidência é 'desconhecida' (rc 0, sem traceback)" 0 '"foram_ao_no": 1, "com_evidencia": 0, "sem_evidencia": 0, "evidencia_desconhecida": \["wa-on"\]' $J
# --help não é erro de uso; a cidade e o bd resolvidos pelo ambiente (sem --city/--bd); o --json não escapa não-ASCII
expect "--help sai 0 e mostra o uso (pedir ajuda não é erro de uso)" 0 'usage: wa-node-evidence-return.py' --help
newcase; bead wa-env; { ida 100 wa-env "$EV"; } > "$L"
r_env() { OUT=$(env -i PATH="$PATH" "FAKE_BD_CALLS=$CALLS" "$@" "$PY" -I "$REP" --route-log "$L" --json 2>"$T/err"); RC=$?; }   # env -i: o bd de mentira precisa do FAKE_BD_CALLS de volta
r_env "GC_CITY_PATH=$CITY" "WA_NODE_BD=$FBD"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q -E -e '"sem_sinal_de_erro": \["wa-env"\]'; then ok "sem --city/--bd: GC_CITY_PATH acha a cidade e WA_NODE_BD é o bd"; else bad "GC_CITY_PATH + WA_NODE_BD (rc=$RC; $(printf '%s' "$OUT" | cut -c1-240))"; fi
r_env "GC_CITY=$CITY" "WA_NODE_BD=$FBD"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q -E -e '"sem_sinal_de_erro": \["wa-env"\]'; then ok "sem --city/--bd: GC_CITY (sozinho) também acha a cidade"; else bad "GC_CITY + WA_NODE_BD (rc=$RC; $(printf '%s' "$OUT" | cut -c1-240))"; fi
r_env "GC_CITY_PATH=$CITY" "GC_CITY=$T/outra-cidade-que-nao-existe" "WA_NODE_BD=$FBD"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q -E -e '"sem_sinal_de_erro": \["wa-env"\]'; then ok "GC_CITY_PATH vence GC_CITY (o errado é ignorado)"; else bad "GC_CITY_PATH vs GC_CITY (rc=$RC; $(printf '%s' "$OUT" | cut -c1-240))"; fi
newcase; printf '[{"id":"wa-\\u00e7","labels":["ctx:ready"],"metadata":{}}]\n' > "$STORE/wa-ç.json"; { ida 100 "wa-ç" "$EV"; } > "$L"
expect "--json não escapa não-ASCII: o id 'wa-ç' sai como está (ensure_ascii=False)" 0 '"sem_sinal_de_erro": \["wa-ç"\]' $J

# ---- controle negativo: um mutante por linha; o caso designado tem de reprovar
mutant() { # mutant <nome> <trecho original> <trecho novo> <preparo do caso (função)> <rc> <regex> [args do relatório]
  local name="$1" orig="$2" new="$3" prep="$4" rc="$5" rx="$6"; shift 6; local M="$T/mut-$name.py"
  if ! "$PY" -I - "$REP" "$M" "$orig" "$new" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  then bad "mutante $name: o trecho original não existe (o relatório mudou? atualize o mutante)"; return; fi
  $prep; CLS="$REP"; run "$@"
  if ! { [ "$RC" = "$rc" ] && { [ "$rx" = "-" ] || printf '%s' "$OUT" | grep -q -E -e "$rx"; }; }; then bad "mutante $name VAZIO: o relatório ORIGINAL já reprova o caso (rc=$RC; saída: $(printf '%s' "$OUT" | cut -c1-200))"; CLS=""; return; fi
  CLS="$M"; run "$@"
  if [ "$RC" = "$rc" ] && { [ "$rx" = "-" ] || printf '%s' "$OUT" | grep -q -E -e "$rx"; }; then bad "mutante $name SOBREVIVEU (o caso ainda passa)"; else ok "mutante $name morreu"; fi
  CLS=""
}
p_shadow()  { newcase; { pilot_s 100 wa-s shadow 0 "$EV"; } > "$L"; }
p_dry()     { newcase; bead wa-y; { apply_s 122 wa-y 0 "dry-run: iria para wa-worker-remote-1 (text)"; pilot_s 120 wa-y auto 0 "$EV"; } > "$L"; }
p_far()     { newcase; bead wa-far; { apply_s 900 wa-far 0 "despachada para wa-worker-remote-1 (text)"; pilot_s 120 wa-far auto 0 "$EV"; } > "$L"; }
p_post()    { newcase; bead wa-post; { pilot_s 120 wa-post auto 0 "$EV"; apply_s 110 wa-post 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"; }
p_one()     { newcase; bead wa-one; { apply_s 122 wa-one 0 "despachada para wa-worker-remote-1 (text)"; pilot_s 120 wa-one auto 0 "$EV"; pilot_s 60 wa-one auto 0 "$EV"; } > "$L"; }
p_semlinha(){ newcase; { apply_s 100 wa-h 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"; }
p_incerta() { newcase; { pilot_s 120 wa-m auto 13 "-"; pilot_s 100 wa-i124 auto 124 "-"; } > "$L"; }
p_fronteira(){ newcase; { pilot_s 100 wa-i128 auto 128 "-"; pilot_s 96 wa-n125 auto 125 "-"; } > "$L"; }
p_modo()    { newcase; { pilot_s 100 wa-q banana 0 "$EV"; } > "$L"; }
p_outvazio(){ newcase; bead wa-u; { ida 100 wa-u -; } > "$L"; }
p_semev()   { newcase; bead wa-sem; { ida 100 wa-sem "$SEM"; } > "$L"; }
p_ultima()  { newcase; bead wa-l; { ida 200 wa-l "$EV"; ida 100 wa-l "$SEM"; } > "$L"; }
p_bdausente(){ newcase; bead wa-a; { ida 100 wa-a "$EV"; } > "$L"; }
p_bdrc()    { newcase; bead wa-rc '["ctx:ready"]' '{"athos.node_recusa":"x"}'; echo 3 > "$STORE/wa-rc.rc"; { ida 100 wa-rc "$EV"; } > "$L"; }
p_outraid() { newcase; printf '[{"id":"wa-outra"}]\n' > "$STORE/wa-oid.json"; { ida 100 wa-oid "$EV"; } > "$L"; }
p_recusa()  { newcase; bead wa-b '["ctx:ready"]' '{"athos.node_recusa":"precisa do banco"}'; { ida 100 wa-b "$EV"; } > "$L"; }
p_recbranco(){ newcase; bead wa-bl '["ctx:ready"]' '{"athos.node_recusa":"  "}'; { ida 100 wa-bl "$EV"; } > "$L"; }
p_gate()    { newcase; bead wa-g1 '["gate:needs-fix"]'; bead wa-g2 '["gate:fix-attempt:2"]'; bead wa-g3 '["gate:failed"]'; bead wa-g4 '["gate:approved"]'; { ida 100 wa-g1 "$EV"; ida 99 wa-g2 "$EV"; ida 98 wa-g3 "$EV"; ida 97 wa-g4 "$EV"; } > "$L"; }
p_ambos()   { newcase; bead wa-both '["gate:needs-fix"]' '{"athos.node_recusa":"x"}'; { ida 100 wa-both "$EV"; } > "$L"; }
p_lixo()    { newcase; bead wa-i; { ida 60 wa-i "$EV"; echo 'linha corrupt: nao e json'; } > "$L"; }
p_rctexto() { newcase; { pilot_s 50 wa-t auto '"0"' "$EV"; } > "$L"; }
p_janela()  { newcase; bead wa-e; { pilot_s 3560 wa-e auto 0 "$EV"; apply_s 3650 wa-e 0 "despachada para wa-worker-remote-1 (text)"; } > "$L"; }
p_ausente() { newcase; rm -f "$L"; }
mutant shadow-vira-modo-estranho 'elif mode == "shadow":' 'elif False:' p_shadow 0 '"sombra_linhas": 1' $J
mutant dry-run-vira-despacho '_add(L.dry, bead, ts)' '_add(L.despachos, bead, ts)' p_dry 0 '"foram_ao_no": 0' $J
mutant pareamento-sem-prazo '0 <= ts - d <= PAREAR_S]' '0 <= ts - d]' p_far 0 '"sem_confirmacao_do_despachante": \["wa-far"\]' $J
mutant despachada-posterior-vale '0 <= ts - d <= PAREAR_S]' '-PAREAR_S <= ts - d <= PAREAR_S]' p_post 0 '"sem_confirmacao_do_despachante": \["wa-post"\]' $J
mutant despachada-serve-a-todas 'used_d.add(c[-1])' 'pass' p_one 0 '"sem_confirmacao_do_despachante": \["wa-one"\]' $J
mutant despacho-sem-linha-some 'sem_linha[bead] = n' 'pass' p_semlinha 0 '"despachos_sem_linha_do_pilot": \["wa-h"\]' $J
mutant incerta-so-13 'rc in (13, 124) or' 'rc in (13,) or' p_incerta 0 '"idas_incertas": \["wa-i124", "wa-m"\]' $J
mutant incerta-descartada 'L.incertas[bead] = L.incertas.get(bead, 0) + 1' 'pass' p_incerta 0 '"idas_incertas": \["wa-i124", "wa-m"\]' $J
mutant incerta-128-fora '128 <= rc <= 255' '128 < rc <= 255' p_fronteira 0 '"idas_incertas": \["wa-i128"\]' $J
mutant incerta-125-dentro '128 <= rc <= 255' '125 <= rc <= 255' p_fronteira 0 '"idas_incertas": \["wa-i128"\]' $J
mutant modo-estranho-vira-label 'elif mode not in MODOS_QUE_ESCREVEM:' 'elif False:' p_modo 0 '"modo_desconhecido_linhas": 1' $J
mutant out-ilegivel-vira-sem 'return None if d is None else any(' 'return False if d is None else any(' p_outvazio 0 '"evidencia_desconhecida": \["wa-u"\]' $J
mutant sem-marca-vale-tudo 'any(isinstance(x, str) and x.startswith(MARCAS) for x in d["info"])' 'True' p_semev 0 '"com_evidencia": 0, "sem_evidencia": 1' $J
mutant ultima-ida-ignorada 'if ultima is None or ts >= ultima[0]:' 'if (ultima is None or ts >= ultima[0]) and evid is True:' p_ultima 0 '"com_evidencia": 0, "sem_evidencia": 1' $J
mutant nao-lida-vira-sem-sinal 'st = "nao_lida"' 'st = "sem_sinal"' p_bdausente 0 '"sem_sinal_de_erro": \[\], "beads_nao_lidas": \["wa-a"\]' $J --bd "$T/nao-existe-bd"
mutant bd-rc-ignorado 'if p.returncode != 0:' 'if False:' p_bdrc 0 '"beads_nao_lidas": \["wa-rc"\]' $J
mutant bead-de-outro-id 'or j.get("id") != bead' 'or False' p_outraid 0 '"beads_nao_lidas": \["wa-oid"\]' $J
mutant recusa-ignorada 'return "recusada", ""' 'pass' p_recusa 0 '"recusadas_pelo_no": \["wa-b"\]' $J
mutant recusa-em-branco-conta 'if isinstance(rec, str) and rec.strip():' 'if rec is not None:' p_recbranco 0 '"recusadas_pelo_no": \[\]' $J
mutant gate-sem-prefixo-de-tentativa 'or x.startswith(PREFIXO_TENTATIVA_GATE)' 'or False' p_gate 0 '"reprovadas_no_gate": \["wa-g1", "wa-g2", "wa-g3"\]' $J
mutant gate-qualquer-rotulo '(x in ROTULOS_GATE or x.startswith(PREFIXO_TENTATIVA_GATE))' 'x.startswith("gate:")' p_gate 0 '"reprovadas_no_gate": \["wa-g1", "wa-g2", "wa-g3"\]' $J
mutant recusa-nao-ganha-do-gate 'return "recusada", ""' 'estado_extra = 1' p_ambos 0 '"recusadas_pelo_no": \["wa-both"\], "reprovadas_no_gate": \[\]' $J
mutant lixo-some 'L.bad += 1' 'pass' p_lixo 0 '"linhas_ilegiveis": 1' $J
mutant rc-texto-passa 'return v if isinstance(v, int) and not isinstance(v, bool) else None' 'return v' p_rctexto 0 '"linhas_ilegiveis": 1' $J
mutant janela-sem-folga 'if ts < since - PAREAR_S:' 'if ts < since:' p_janela 0 '"foram_ao_no": 1' $J --hours 1
mutant hours-isdigit 'not re.fullmatch(r"[0-9]{1,5}", a.hours)' 'not a.hours.isdigit()' newcase 2 '-' --hours "²"
mutant ausente-vira-zero 'return EX_NOLOG' 'return EX_OK' p_ausente 3 '-'

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
