#!/usr/bin/env bash
# aposentar-servidor.selftest.sh — aposentar-servidor.sh (ga-ke5w2ie.4, Mini64 fatia 4). NADA aqui toca o launchctl, o HOME ou o S3 reais: cada cenario roda num mundo falso
# (HOME temporario com plists de mentira; launchctl stub COM ESTADO que registra cada chamada, uid falso 4242; canario no PATH que acusa qualquer launchctl que nao seja o
# stub). Blocos: P plano e configuracao · A aplicar (inclui o launchctl que MENTE: rc 0 sem efeito) · C conferir · D desfazer · T o arquivo de dados REAL (rotulos reais, o Dolt
# nunca e aposentado, cada com.gascity.* citado e Label de plist do repo) · R runbook. Os guardas dos scripts de backup: aposentar-guards.selftest.sh.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; CITY_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${APOSENTAR_SERVIDOR_SH:-$HERE/aposentar-servidor.sh}"   # os overrides sao da bateria de mutantes; APOSENTAR_BASH = o bash que roda o script (no no, um 3.2.57)
TSV_REAL="${APOSENTAR_CAMADAS_REAL:-$HERE/aposentar-camadas.tsv}"; CLASSIFICA="${APOSENTAR_CLASSIFICA_PY:-$HERE/aposentar-classifica.py}"
PASS=0; FAIL=0; ok() { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }; bad() { FAIL=$((FAIL+1)); printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; }
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# launchctl stub com estado (loaded/disabled/enabled/disabled-system .txt), uma linha por chamada em calls.log. Falhas por ambiente (rotulo ou *): STUB_FAIL_{DISABLE,ENABLE,
# BOOTOUT,BOOTSTRAP} (erro), STUB_{DISABLE,ENABLE,BOOTOUT,BOOTSTRAP}_NOOP (rc 0 SEM efeito: o launchctl que mente), STUB_LIST_{GARBAGE,FAIL}, STUB_PD_{FAIL,GARBAGE,SYSTEM_FAIL}.
# mk.log: o marcador ja existia em cada chamada que MUDA estado?
cat > "$TMP/stub" <<'STUB'
#!/bin/bash
S="${STUB_STATE:?}"; printf '%s\n' "$*" >> "$S/calls.log"; v="${1:-}"; [ $# -gt 0 ] && shift; l="${1##*/}"
has() { grep -qxF -- "$2" "$S/$1" 2>/dev/null; }; drop() { grep -vxF -- "$2" "$S/$1" > "$S/$1.t"; mv "$S/$1.t" "$S/$1"; }
hit() { [ "$1" = "$2" ] || [ "$1" = "*" ]; }; pd() { while IFS= read -r x; do [ -n "$x" ] && printf '\t"%s" => %s\n' "$x" "$2"; done < "$S/$1"; }
case "$v" in disable|enable|bootout|bootstrap) if [ -e "${STUB_MARKER:-/n}" ]; then echo "presente $v" >> "$S/mk.log"; else echo "ausente $v" >> "$S/mk.log"; fi ;; esac
case "$v" in
  list) hit "${STUB_LIST_GARBAGE:-}" "$1" && { echo banana; exit 0; }; hit "${STUB_LIST_FAIL:-}" "$1" && { echo "erro de XPC" >&2; exit 1; }
        has loaded.txt "$1" && { printf '{\n\t"Label" = "%s";\n};\n' "$1"; exit 0; }; echo "Could not find service \"$1\" in domain" >&2; exit 113 ;;
  disable) hit "${STUB_FAIL_DISABLE:-}" "$l" && exit 1; hit "${STUB_DISABLE_NOOP:-}" "$l" && exit 0; drop enabled.txt "$l"; has disabled.txt "$l" || echo "$l" >> "$S/disabled.txt" ;;
  enable) hit "${STUB_FAIL_ENABLE:-}" "$l" && exit 1; hit "${STUB_ENABLE_NOOP:-}" "$l" && exit 0; drop disabled.txt "$l"; has enabled.txt "$l" || echo "$l" >> "$S/enabled.txt" ;;
  bootout) hit "${STUB_FAIL_BOOTOUT:-}" "$l" && exit 5; hit "${STUB_BOOTOUT_NOOP:-}" "$l" && exit 0; has loaded.txt "$l" && { drop loaded.txt "$l"; exit 0; }; exit 3 ;;
  bootstrap) l="$(sed -n 's#.*<string>\(\(com\|br\)\.[^<]*\)</string>.*#\1#p' "$2" | tail -1)"; hit "${STUB_FAIL_BOOTSTRAP:-}" "$l" && exit 5; has loaded.txt "$l" && exit 5
        hit "${STUB_BOOTSTRAP_NOOP:-}" "$l" && exit 0; echo "$l" >> "$S/loaded.txt" ;;
  print-disabled)
    if [ "${1:-}" = system ]; then [ -n "${STUB_PD_SYSTEM_FAIL:-}" ] && exit 1; echo "disabled services = {"; pd disabled-system.txt disabled; echo "}"; exit 0; fi
    [ -n "${STUB_PD_FAIL:-}" ] && exit 1; [ -n "${STUB_PD_GARBAGE:-}" ] && { echo banana; exit 0; }
    echo "disabled services = {"; pd disabled.txt disabled; pd enabled.txt enabled; echo "}" ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$TMP/stub"

# ── mundo falso ──
tsv() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
mkplist() { printf '<?xml version="1.0"?>\n<plist version="1.0"><dict>\n<!-- <key>Label</key><string>com.fake.decoy</string> -->\n<key>Label</key>\n<string>%s</string>\n</dict></plist>\n' "$2" > "$1/${3:-$2.plist}"; }
STD_LABELS="com.whatsapp.central-sender com.whatsapp.campaign-api com.whatsapp.map-viewer com.urblink.inbound-sweep com.urblink.warming-engine com.gascity.dolt-s3-backup
com.gascity.jsonl-hourly-offsite com.gascity.pilot com.athos.claude-history-backup br.urblink.cloudflared.urblink-ops com.gascity.nightly-reboot-postcheck com.apple.fake-terceiro com.whatsapp.renamed-sender"
RETIRE="br.urblink.cloudflared.urblink-ops
com.gascity.dolt-s3-backup
com.gascity.jsonl-hourly-offsite
com.gascity.nightly-reboot-postcheck
com.urblink.inbound-sweep
com.whatsapp.campaign-api
com.whatsapp.central-sender
com.whatsapp.renamed-sender"
new_world() {   # <nome>: HOME, LaunchAgents, stub e canario proprios; a lista de camadas do fixture: envios, ingestao, cloudflared, backups, reboot-noturno (+ paineis em manter)
  W="$TMP/$1"; mkdir -p "$W/home/Library/LaunchAgents" "$W/state" "$W/canary"; AGENTS="$W/home/Library/LaunchAgents"; MARKER="$W/home/.servidor-aposentado"; TSV="$W/camadas.tsv"
  (cd "$W/state" && : > calls.log && : > loaded.txt && : > disabled.txt && : > enabled.txt && : > disabled-system.txt); cp "$TMP/stub" "$W/launchctl"
  printf '#!/bin/sh\necho "launchctl REAL: $*" >> "%s/canary.log"\nexit 99\n' "$W" > "$W/canary/launchctl"; chmod +x "$W/canary/launchctl"
  { tsv aposentar envios gui exato com.whatsapp.central-sender n; tsv aposentar envios gui prefixo com.whatsapp. n; tsv manter paineis gui exato com.whatsapp.map-viewer n
    tsv aposentar ingestao gui prefixo com.urblink.inbound- n; tsv aposentar cloudflared gui prefixo br.urblink.cloudflared. n; tsv aposentar backups gui exato com.gascity.dolt-s3-backup n
    tsv aposentar backups gui exato com.gascity.jsonl-hourly-offsite n; tsv aposentar reboot-noturno gui exato com.gascity.nightly-reboot-postcheck n
    tsv aposentar reboot-noturno system exato com.gascity.nightly-reboot 'LaunchDaemon: sudo'; } > "$TSV"
}
std() { local l; new_world "$1"; for l in $STD_LABELS; do case "$l" in com.whatsapp.renamed-sender) mkplist "$AGENTS" "$l" weird-name.plist ;; *) mkplist "$AGENTS" "$l" ;; esac; done; }
load_all() { local l; for l in $STD_LABELS; do echo "$l" >> "$W/state/loaded.txt"; done; }   # simula "tudo rodando"
X1=""; run_ap() {   # <args>: RC, OUT, ERR da rodada contra o mundo W; X1 = uma atribuicao de ambiente extra
  OUT="$(env PATH="$W/canary:$PATH" HOME="$W/home" TMPDIR="$TMP" LAUNCHCTL_BIN="$W/launchctl" STUB_STATE="$W/state" STUB_MARKER="$MARKER" APOSENTAR_UID=4242 \
    APOSENTAR_CAMADAS_TSV="$TSV" SERVIDOR_APOSENTADO_FILE="$MARKER" ${X1:+"$X1"} "${APOSENTAR_BASH:-/bin/bash}" "$SCRIPT" "$@" 2>"$W/err")"; RC=$?; ERR="$(cat "$W/err")"; }
# chk <desc> <rc> [+texto presente | -texto ausente]... : o rc e a saida (stdout+stderr) da ultima rodada; UMA linha ok/bad
chk() { local d="$1" want="$2" a w=""; shift 2; [ "$RC" = "$want" ] || w="rc=$RC (queria $want)"
  for a in "$@"; do case "$a" in +*) case "$OUT$ERR" in *"${a#+}"*) ;; *) w="$w; falta «${a#+}»" ;; esac ;; -*) case "$OUT$ERR" in *"${a#-}"*) w="$w; sobrou «${a#-}»" ;; esac ;; esac; done
  if [ -z "$w" ]; then ok "$d"; else bad "$d: $w" "$(printf '%s' "$OUT$ERR" | head -c 400)"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "veio: $(printf '%s' "$2" | tr '\n' ' ' | head -c 250) | queria: $(printf '%s' "$3" | tr '\n' ' ' | head -c 250)"; fi; }
section() { printf '%s\n' "$OUT" | awk -v t="== $1" 'index($0,t)==1 {f=1; next} /^== /{f=0} f'; }
labels_of() { sed -n "s#^$1 gui/4242/\(.*\)\$#\1#p" "$W/state/calls.log" | sort -u; }       # <verbo>: rotulos que receberam esse verbo
verdict() { section CONFERENCIA | sed -n "s/^  \[\(.*\)\] $1 .*/\1/p" | head -1; }              # <rotulo|marcador>: ok | FALHA | NAO SEI | PENDENTE
line_of() { grep -n -m1 -F -- "$1" "$W/state/calls.log" | cut -d: -f1; }                      # <trecho>: no da 1a chamada que o contem
snap() { (cd "$W/home" && { find . | sort; find . -type f -exec cat {} +; }) | cksum; }
nmut() { grep -cE '^(disable|enable|bootout|bootstrap) ' "$W/state/calls.log"; }               # chamadas que MUDAM estado
nok() { section CONFERENCIA | grep -c '^  \[ok\] \(com\|br\)\.'; }
mk() { printf '%s\n' "$MARKER"; }
lst() { tr '\n' ' ' | sed 's/ *$//'; }; RS="$(echo $RETIRE)"   # lista em uma linha sem espaco no fim; RS = os 8 rotulos esperados

echo "── P: plano e configuracao ──"
std p1; S0="$(snap)"; run_ap plano
chk "P1 plano: rc 0, diz que nada foi alterado, usa o uid de APOSENTAR_UID, traz os sudo do LaunchDaemon, ignora o Label so de comentario" 0 "+PLANO" "+nada foi alterado" "+launchctl disable gui/4242/<rotulo>" \
  "+sudo launchctl bootout system/com.gascity.nightly-reboot" "+sudo launchctl disable system/com.gascity.nightly-reboot" "-com.fake.decoy"
eq "P1 plano: o launchctl NAO foi chamado, nada foi escrito no HOME, nenhum canario" "$(wc -l < "$W/state/calls.log" | tr -d ' '):$([ "$(snap)" = "$S0" ] && echo igual):$([ -e "$W/canary.log" ] && echo canario || echo limpo):$([ -e "$(mk)" ] && echo marcador || echo sem)" "0:igual:limpo:sem"
eq "P1 APOSENTAR = exatamente os 8 rotulos (o weird-name.plist pelo Label de dentro; o painel mantido e o de terceiro fora)" "$(section APOSENTAR | awk '/^  \[/ {print $2}' | sort -u | grep -vxF com.gascity.nightly-reboot)" "$RETIRE"
case "$(section APOSENTAR)" in *"[envios]"*"[ingestao]"*"[cloudflared]"*"[backups]"*"[reboot-noturno]"*) ok "P1 camadas pelo NOME, na ordem da lista" ;; *) bad "P1 ordem das camadas" ;; esac
eq "P1 MANTER traz o painel; FICAM RODANDO traz so o que nao tem regra" "$(section MANTER | grep -c map-viewer):$(section 'FICAM RODANDO' | awk 'NF {print $1}' | tr '\n' ' ')" "1:com.athos.claude-history-backup com.gascity.pilot com.urblink.warming-engine "
eq "P1 RESUMO por camada" "$(section RESUMO | tr -d ' \n')" "envios:3ingestao:1cloudflared:1backups:2reboot-noturno:2manter:1ficamrodando:3"
run_ap; chk "P2 sem argumento = plano" 0 "+PLANO"
run_ap plano; chk "P1m marcador ausente" 0 "+marcador ......... $MARKER (ausente)"; echo x > "$MARKER"; run_ap plano; chk "P1m marcador PRESENTE" 0 "+marcador ......... $MARKER (PRESENTE)"; rm -f "$MARKER"
ln -s "$W/nao-existe" "$MARKER"; run_ap plano; chk "P1m marcador que e link QUEBRADO conta como PRESENTE" 0 "+(PRESENTE)"; rm -f "$MARKER"
if [ "$(id -u)" != 0 ]; then mkdir -p "$W/sa"; chmod 000 "$W/sa"; MARKER="$W/sa/m"; run_ap plano; chmod 700 "$W/sa"; chk "P1m pasta do marcador sem acesso: NAO SEI, nunca 'ausente'" 0 "+NAO SEI" "-(ausente)"; fi
std p3; mkdir "$AGENTS/diretorio.plist"; printf '<plist version="1.0"><dict><key>Foo</key><string>x</string></dict></plist>\n' > "$AGENTS/sem-label.plist"; printf 'lixo\n' > "$AGENTS/quebrado.plist"
mkplist "$AGENTS" 'com.whatsapp.rotulo/../escapa' com.whatsapp.escapa.plist; ln -s "$W/nao-existe.plist" "$AGENTS/link-quebrado.plist"; cp "$AGENTS/com.whatsapp.campaign-api.plist" "$AGENTS/copia-velha.plist"
run_ap plano; chk "P3 plists estranhos: o plano sai e nomeia como NAO SEI o diretorio, o sem-Label, o corrompido e o Label com barra (que nunca vira alvo)" 0 "+NAO SEI o que e: $AGENTS/diretorio.plist" \
  "+NAO SEI o que e: $AGENTS/sem-label.plist" "+NAO SEI o que e: $AGENTS/quebrado.plist" "+NAO SEI o que e: $AGENTS/com.whatsapp.escapa.plist" "-[envios] com.whatsapp.rotulo"
eq "P3 link quebrado e dito como link quebrado (nao NAO SEI); o Label duplicado em 2 arquivos aparece 1 vez" "$(printf '%s\n' "$OUT" | grep link-quebrado | grep -c 'NAO SEI'):$(section APOSENTAR | grep -c ' com.whatsapp.campaign-api ')" "0:1"
# cfg_t <n> <desc> <setup> <trecho esperado> [args]: uma configuracao ruim; esperado rc 2
cfg_t() { local n="$1" d="$2" s="$3" want="$4"; shift 4; std "cfg$n"; eval "$s"; run_ap "${@:-plano}"; chk "P4 $d" 2 "+$want"; }
cfg_t 1 "lista ausente (a mensagem nomeia o arquivo)" 'rm -f "$TSV"' "camadas.tsv"
cfg_t 2 "lista so de comentarios: vazia nao e 'nada a fazer'" 'printf "# nada\n" > "$TSV"' "lista vazia"
cfg_t 3 "lista so com 'manter'" 'tsv manter paineis gui exato com.x.y a > "$TSV"' "nenhuma regra 'aposentar'"
cfg_t 4 "diretorio de LaunchAgents ausente" 'rm -rf "$W/home/Library"' "LaunchAgents"
cfg_t 5 "LaunchAgents sem plist nenhum (HOME errado?)" 'rm -f "$AGENTS"/*.plist' "nenhum plist"
X1="APOSENTAR_PYTHON=$TMP/sem/python3"; cfg_t 6 "python3 ausente" ':' "python"; X1=""
cfg_t 7 "modo desconhecido" ':' "uso:" vamos-ver
cfg_t 8 "--sim-tenho-certeza so vale para desfazer" ':' "so vale para o modo desfazer" plano --sim-tenho-certeza
cfg_t 9 "opcao desconhecida" ':' "opcao desconhecida" plano --nao-existe
cfg_t 10 "linha com colunas faltando" 'printf "# x\naposentar\tenvios\tgui\texato\n" > "$TSV"' "linha 2"
cfg_t 11 "acao invalida" 'tsv destruir envios gui exato com.x.y a > "$TSV"' "acao 'destruir'"
cfg_t 12 "padrao repetido (copia e cola)" '{ tsv aposentar envios gui exato com.x.y a; tsv aposentar backups gui exato com.x.y b; } > "$TSV"' "repetido"
cfg_t 13 "system so aceita rotulo exato" 'tsv aposentar reboot-noturno system prefixo com.gascity.nightly- a > "$TSV"' "so aceita tipo exato"
cfg_t 14 "rotulo com espaco (viraria argumento do launchctl)" 'tsv aposentar envios gui exato "com.x y" a > "$TSV"' "caractere fora"
cfg_t 15 "rotulo com barra (escaparia do alvo gui/<uid>/<rotulo>)" 'tsv aposentar envios gui exato "com.x/../y" a > "$TSV"' "caractere fora"
cfg_t 16 "nenhuma regra 'aposentar' casa com plist nenhum (so prefixo sem plist): aplicar nao pode dar sucesso silencioso" 'tsv aposentar envios gui prefixo com.nada.casa. a > "$TSV"' "nenhum rotulo a aposentar" aplicar
std p1f; for l in com.gastown.drive-cleanup com.phoneproxy.relay com.realestate.motherduck-sync com.whatsapp-automation.content-variation-monitor br.urblink.assertiva; do mkplist "$AGENTS" "$l"; done; run_ap plano
for l in com.gastown.drive-cleanup com.phoneproxy.relay com.realestate.motherduck-sync com.whatsapp-automation.content-variation-monitor br.urblink.assertiva; do case "$(section 'FICAM RODANDO')" in *"$l"*) ;; *) bad "P1f $l fora das familias (as 9 reais, nao so as 4 da bead)" ;; esac; done

echo "── D1: desfazer sem a flag ──"
std d1; echo marcador > "$MARKER"; S0="$(snap)"; run_ap desfazer; chk "D1 desfazer sem --sim-tenho-certeza recusa e diz o risco (WhatsApp em dobro)" 2 "+--sim-tenho-certeza" "+dobro"
for f in --sim --sim-tenho-certeza=0 --sim-tenho-certeza-nao; do run_ap desfazer "$f"; chk "D1 flag '$f' nao vale" 2; done
eq "D1 nada lido nem tocado: HOME e marcador intactos, nenhuma chamada" "$([ "$(snap)" = "$S0" ] && echo igual):$(wc -l < "$W/state/calls.log" | tr -d ' ')" "igual:0"

echo "── A: aplicar ──"
std a1; load_all; run_ap aplicar
chk "A1 aplicar: o que da sem root esta feito e conferido, faltam so os passos com sudo (rc 6)" 6 "+[PENDENTE] com.gascity.nightly-reboot" "+sudo launchctl bootout system/com.gascity.nightly-reboot"
eq "A1 disable e bootout EXATAMENTE nos 8 rotulos das camadas" "$(labels_of disable | lst)|$(labels_of bootout | lst)" "$RS|$RS"
eq "A1 sem enable/bootstrap/system; os 5 que ficam nem foram consultados e seguem carregados; o canario ficou limpo" "$(grep -cE '^(enable|bootstrap) |^(disable|bootout) system' "$W/state/calls.log"):$(grep -cE 'map-viewer|warming|pilot|claude-history|fake-terceiro' "$W/state/calls.log"):$(grep -cE 'map-viewer|warming|pilot|claude-history|fake-terceiro' "$W/state/loaded.txt"):$([ -e "$W/canary.log" ] && echo c || echo ok)" "0:0:5:ok"
eq "A1 estado final: os 8 desabilitados e descarregados; os [ok] da conferencia" "$(sort "$W/state/disabled.txt" | lst)|$(grep -cxF -f <(echo "$RETIRE") "$W/state/loaded.txt")|$(nok)|$(verdict marcador)" "$RS|0|8|ok"
for k in 'servidor-aposentado=1' 'aposentado_em=' 'host=' 'usuario=' 'camadas=envios ingestao cloudflared backups reboot-noturno' 'desfazer='; do grep -qF -- "$k" "$MARKER" || bad "A1 o marcador nao traz «$k»" "$(cat "$MARKER")"; done
eq "A1 o marcador existia em TODA chamada que muda estado (gravado ANTES do launchctl); disable antes do bootout" "$(grep -c '^ausente' "$W/state/mk.log"):$([ -s "$W/state/mk.log" ] && echo cheio):$([ "$(line_of 'disable gui/4242/com.whatsapp.central-sender')" -lt "$(line_of 'bootout gui/4242/com.whatsapp.central-sender')" ] && echo ok)" "0:cheio:ok"
P=""; for l in com.whatsapp.central-sender com.urblink.inbound-sweep br.urblink.cloudflared.urblink-ops com.gascity.dolt-s3-backup com.gascity.nightly-reboot-postcheck; do P="$P $(line_of "bootout gui/4242/$l")"; done
eq "A1 ordem das camadas (a inversa da carga da .2): envios, ingestao, cloudflared, backups, reboot-noturno" "$(echo $P | tr ' ' '\n' | sort -n -c 2>&1 && echo crescente)" "crescente"
run_ap aplicar; chk "A3 aplicar de novo e idempotente: bootout de servico ja descarregado (rc 3) nao vira FALHA, a conferencia decide" 6 "-[FALHA]" "-[NAO SEI]"
std a2; load_all; grep -v "$(printf '\tsystem\t')" "$TSV" > "$TSV.x"; mv "$TSV.x" "$TSV"; run_ap aplicar; chk "A2 sem LaunchDaemon na lista: rc 0" 0
fm() { std "$1"; load_all; X1="$2"; run_ap aplicar; X1=""; eq "$1 [$2] -> rc $3, $4 = $5, e os 8 foram processados (nao para no 1o erro)" "$RC:$(verdict "$4"):$(labels_of bootout | lst)" "$3:$5:$RS"; }
fm a4 STUB_FAIL_BOOTOUT=com.whatsapp.central-sender 4 com.whatsapp.central-sender FALHA
fm a5 STUB_LIST_GARBAGE=com.gascity.dolt-s3-backup 4 com.gascity.dolt-s3-backup "NAO SEI"
fm a6 'STUB_LIST_FAIL=*' 4 com.whatsapp.central-sender "NAO SEI"
fm a7 STUB_PD_FAIL=1 4 com.whatsapp.central-sender "NAO SEI"
fm a8 STUB_PD_GARBAGE=1 4 com.whatsapp.central-sender "NAO SEI"
fm a9 STUB_FAIL_DISABLE=com.urblink.inbound-sweep 4 com.urblink.inbound-sweep FALHA
fm a17 STUB_DISABLE_NOOP=com.gascity.jsonl-hourly-offsite 4 com.gascity.jsonl-hourly-offsite FALHA
fm a18 STUB_BOOTOUT_NOOP=com.whatsapp.central-sender 4 com.whatsapp.central-sender FALHA
std a10; load_all; MARKER="$W/nao-existe/m"; run_ap aplicar; chk "A10 marcador impossivel de gravar: recusa ANTES de tocar no launchd" 2 "+marcador"; eq "A10 nenhuma chamada" "$(wc -l < "$W/state/calls.log" | tr -d ' ')" 0
std a11; load_all; X1="LAUNCHCTL_BIN=$W/nao-existe"; run_ap aplicar; X1=""; chk "A11 launchctl ausente: recusa" 2; eq "A11 sem launchctl nao grava o marcador" "$([ -e "$(mk)" ] && echo grava || echo nada)" nada
std a12; load_all; printf 'lixo\n' > "$AGENTS/quebrado.plist"; run_ap aplicar; chk "A12 plist ilegivel: aposenta o resto e termina com rc 4" 4 "+quebrado.plist"; eq "A12 os demais foram aposentados" "$(labels_of bootout | lst)" "$RS"
std a13; load_all; ln -s "$W/nao-existe.plist" "$AGENTS/link-quebrado.plist"; run_ap aplicar; chk "A13 link quebrado nao e pendencia (o launchd nao o carrega)" 6
std a15; load_all; run_ap aplicar >/dev/null; echo com.gascity.nightly-reboot >> "$W/state/disabled-system.txt"; run_ap aplicar; chk "A15 depois do sudo (daemon desabilitado no dominio system) o aplicar fecha com rc 0" 0 "+[ok] com.gascity.nightly-reboot"
std a16; load_all; X1="STUB_PD_SYSTEM_FAIL=1"; run_ap aplicar; X1=""; chk "A16 sem root a leitura do dominio system falha: NAO SEI e rc 6 (nunca ok)" 6 "+[NAO SEI] com.gascity.nightly-reboot"

echo "── C: conferir ──"
std c1; load_all; run_ap aplicar >/dev/null; : > "$W/state/calls.log"; S0="$(snap)"; L0="$(cksum < "$W/state/loaded.txt")"; run_ap conferir
chk "C1 conferir logo depois do aplicar: tudo [ok], so falta o passo com sudo" 6; eq "C1 so leu (nenhum disable/enable/bootout/bootstrap) mas de fato consultou; nada mudou" "$(nmut):$([ -s "$W/state/calls.log" ] && echo leu):$([ "$(snap)" = "$S0" ] && [ "$(cksum < "$W/state/loaded.txt")" = "$L0" ] && echo igual)" "0:leu:igual"
echo com.gascity.nightly-reboot >> "$W/state/disabled-system.txt"; run_ap conferir; chk "C1b com o daemon desabilitado: rc 0" 0
cx() { std "$1"; load_all; run_ap aplicar >/dev/null; eval "$2"; X1="$3"; run_ap conferir; X1=""; eq "$1 -> rc $4 e $5 = $6" "$RC:$(verdict "$5")" "$4:$6"; }
cx c2 'echo com.whatsapp.central-sender >> "$W/state/loaded.txt"' "" 4 com.whatsapp.central-sender FALHA    # o reboot trouxe o remetente de volta
cx c3 'grep -vxF com.urblink.inbound-sweep "$W/state/disabled.txt" > "$W/d.x"; mv "$W/d.x" "$W/state/disabled.txt"' "" 4 com.urblink.inbound-sweep FALHA   # alguem reabilitou
cx c4 'rm -f "$MARKER"' "" 4 marcador FALHA
cx c5 ':' "STUB_PD_FAIL=1" 4 com.whatsapp.central-sender "NAO SEI"
if [ "$(id -u)" != 0 ]; then std c6; load_all; run_ap aplicar >/dev/null; mkdir -p "$W/sa"; chmod 000 "$W/sa"; MARKER="$W/sa/m"; run_ap conferir; chmod 700 "$W/sa"; eq "C6 pasta do marcador sem acesso: NAO SEI, nunca 'ausente'" "$RC:$(verdict marcador)" "4:NAO SEI"; fi
std c7; X1="LAUNCHCTL_BIN=$W/nao-existe"; run_ap conferir; X1=""; chk "C7 conferir sem launchctl: rc 2 (nao conferir nao e 'ok')" 2
std c8; run_ap conferir; chk "C8 conferir num servidor que NAO foi aposentado (tudo carregado/habilitado, sem marcador): rc 4" 4 "+[FALHA] marcador"

echo "── D: desfazer --sim-tenho-certeza ──"
std d3; load_all; run_ap aplicar >/dev/null; : > "$W/state/calls.log"; rm -f "$W/state/mk.log"; run_ap desfazer --sim-tenho-certeza
chk "D3 desfazer: religou o que da sem root, faltam so os passos com sudo (enable e bootstrap do daemon)" 6 "+sudo launchctl enable system/com.gascity.nightly-reboot" "+sudo launchctl bootstrap system /Library/LaunchDaemons/com.gascity.nightly-reboot.plist"
eq "D3 enable nos 8; bootstrap do ARQUIVO real de cada plist (o weird-name.plist, nao o rotulo); nenhum disable/bootout" "$(labels_of enable | lst)|$(sed -n 's#^bootstrap gui/4242 .*/\(.*\)$#\1#p' "$W/state/calls.log" | sort | lst)|$(grep -cE '^(disable|bootout) ' "$W/state/calls.log")" \
  "$RS|br.urblink.cloudflared.urblink-ops.plist com.gascity.dolt-s3-backup.plist com.gascity.jsonl-hourly-offsite.plist com.gascity.nightly-reboot-postcheck.plist com.urblink.inbound-sweep.plist com.whatsapp.campaign-api.plist com.whatsapp.central-sender.plist weird-name.plist|0"
eq "D3 o marcador sai DEPOIS de todos os enable e ANTES dos bootstrap; tudo carregado e habilitado; conferencia [ok]" "$(grep -c '^presente enable' "$W/state/mk.log")$(grep -c '^ausente enable' "$W/state/mk.log"):$(grep -c '^ausente bootstrap' "$W/state/mk.log")$(grep -c '^presente bootstrap' "$W/state/mk.log"):$([ -e "$(mk)" ] && echo marcador):$(nok):$(verdict marcador)" "80:80::8:ok"
P=""; for l in com.gascity.nightly-reboot-postcheck com.gascity.dolt-s3-backup br.urblink.cloudflared.urblink-ops com.urblink.inbound-sweep com.whatsapp.central-sender; do P="$P $(line_of "bootstrap gui/4242 $AGENTS/$l.plist")"; done
eq "D3 ordem INVERSA do aplicar (= a de carga da .2): o envio de WhatsApp volta por ultimo" "$(echo $P | tr ' ' '\n' | sort -n -c 2>&1 && echo crescente)" "crescente"
fd() { std "$1"; load_all; run_ap aplicar >/dev/null; X1="$2"; run_ap desfazer --sim-tenho-certeza; X1=""; eq "$1 [$2] -> rc $3, $4 = $5" "$RC:$(verdict "$4")" "$3:$5"; }
fd d9 STUB_ENABLE_NOOP=com.urblink.inbound-sweep 4 com.urblink.inbound-sweep FALHA
fd d10 STUB_BOOTSTRAP_NOOP=com.whatsapp.campaign-api 4 com.whatsapp.campaign-api FALHA
fd d5 STUB_FAIL_BOOTSTRAP=com.gascity.dolt-s3-backup 4 com.gascity.dolt-s3-backup FALHA
std d4; load_all; run_ap aplicar >/dev/null; : > "$W/state/calls.log"; X1="STUB_FAIL_ENABLE=com.urblink.inbound-sweep"; run_ap desfazer --sim-tenho-certeza; X1=""
chk "D4 um enable falha: rc 4, o marcador FICOU e nada foi religado" 4 "+FICOU"; eq "D4 marcador la e nenhum bootstrap" "$([ -e "$(mk)" ] && echo la):$(grep -c '^bootstrap ' "$W/state/calls.log")" "la:0"
std d6; load_all; run_ap aplicar >/dev/null; rm -f "$MARKER"; run_ap desfazer --sim-tenho-certeza; chk "D6 marcador ja ausente: idempotente" 6 "+ja estava ausente"
std d7; load_all; run_ap desfazer --sim-tenho-certeza; chk "D7 num servidor nunca aposentado (tudo ja carregado): o bootstrap que falha com rc 5 nao decide, a conferencia diz [ok]" 6 "-[FALHA]"
std d8; load_all; run_ap aplicar >/dev/null; X1="LAUNCHCTL_BIN=$W/nao-existe"; run_ap desfazer --sim-tenho-certeza; X1=""; chk "D8 desfazer sem launchctl recusa" 2; eq "D8 o marcador continua la" "$([ -e "$(mk)" ] && echo la)" la

echo "── T: o arquivo de dados REAL ──"
EMPTY="$TMP/vazio"; mkdir -p "$EMPTY"; T2="$TMP/t2"; mkdir -p "$T2"
T1="$(python3 -I "$CLASSIFICA" --tsv "$TSV_REAL" --agents-dir "$EMPTY" 2>&1)"; T1RC=$?
eq "T1 o helper aceita o arquivo real; camadas na ordem do aplicar (a inversa da carga da .2)" "$T1RC:$(printf '%s\n' "$T1" | awk -F'\t' '$1=="CAMADA"{printf "%s ", $2}')" "0:envios cloudflared backups reboot-noturno "
# rotulo esperado, camada esperada (rotulos REAIS do repo da cidade e do repo do WA): o negativo que mais importa e o Dolt, o motor e os backups por-host NUNCA serem aposentados
T2LIST="com.whatsapp.central-sender aposentar:envios|com.whatsapp.campaign-scheduler aposentar:envios|com.urblink.warming-engine aposentar:envios|com.urblink.inbound-sweep aposentar:envios|br.urblink.assertiva aposentar:envios
com.phoneproxy.relay aposentar:envios|com.realestate.motherduck-sync aposentar:envios|com.whatsapp.backup-all-dbs aposentar:backups|com.whatsapp.dolthub-backup aposentar:backups|com.urblink.backup-health-db-6h aposentar:backups
com.urblink.sync-critical-dbs-hourly aposentar:backups|com.gascity.dolt-s3-backup aposentar:backups|com.gascity.jsonl-hourly-offsite aposentar:backups|br.urblink.cloudflared.urblink-ops aposentar:cloudflared
com.gascity.cloudflared-dns-reconcile aposentar:cloudflared|com.gascity.nightly-reboot-postcheck aposentar:reboot-noturno|com.whatsapp.map-viewer manter:paineis|com.whatsapp.demand-dashboard-amostra-fina manter:paineis
com.whatsapp.ficha360-search-index-refresh manter:paineis|com.whatsapp.classification-dashboard-auth-watchdog manter:paineis|br.urblink.motherduck-dashboard manter:paineis|com.gascity.jsonl-hourly-offsite-age manter:backups
com.gascity.jsonl-export manter:backups|com.gascity.dolt-restore-verify manter:backups|com.gascity.dolt-restore-lab-mbp manter:backups|com.gascity.mbp-nightly-reseed aposentar:backups
com.gastown.dolt-server livre|com.gastown.bw-serve livre|com.gascity.pilot livre|com.gascity.quality-gate-dispatcher livre|com.gascity.dolt-gc-maintenance livre|com.gascity.dolt-compact-routine livre|com.athos.claude-history-backup livre"
for l in $(printf '%s\n' "$T2LIST" | tr '|' '\n' | awk '{print $1}'); do mkplist "$T2" "$l"; done
T2OUT="$(python3 -I "$CLASSIFICA" --tsv "$TSV_REAL" --agents-dir "$T2" 2>&1)"; BADROWS=""
while read -r l want; do got="$(printf '%s\n' "$T2OUT" | awk -F'\t' -v l="$l" '($1=="ALVO" && $4==l){print "aposentar:" $2} ($1=="MANTER" && $3==l){print "manter:" $2} ($1=="LIVRE" && $2==l){print "livre"}')"; [ "$got" = "$want" ] || BADROWS="$BADROWS $l=${got:-nada}(queria $want)"; done <<EOF
$(printf '%s\n' "$T2LIST" | tr '|' '\n')
EOF
eq "T2 classificacao de $(printf '%s\n' "$T2LIST" | tr '|' '\n' | grep -c .) rotulos reais pelo arquivo real (Dolt, motor e backups por-host: livres; paineis e restore de prova: mantidos)" "${BADROWS:-todos certos}" "todos certos"
# T3: cada com.gascity.* citado existe como Label de plist DESTE repo (um rename quebra aqui, nao na noite do corte); T4: o LaunchDaemon (sem plist no repo) esta no runbook; T5: o tunel e o do postcheck
find "$CITY_ROOT" -name '*.plist' -not -path '*/docs/launchd-archive/*' -not -path '*/.git/*' 2>/dev/null | while IFS= read -r f; do awk '/<key>Label<\/key>/ {w=1} w && /<string>/ {s=$0; sub(/.*<string>/,"",s); sub(/<\/string>.*/,"",s); print s; exit}' "$f"; done | sort -u > "$TMP/labels"
MISS=""; N=0; while IFS="$(printf '\t')" read -r a c d t p n; do case "$a:$p:$d" in *:system) continue ;; "#"*|"") continue ;; *:com.gascity.*:*) N=$((N+1)); if [ "$t" = exato ]; then grep -qxF "$p" "$TMP/labels" || MISS="$MISS $p"; else grep -q "^$p" "$TMP/labels" || MISS="$MISS $p*"; fi ;; esac; done < "$TSV_REAL"
eq "T3 as $N regras com.gascity.* batem com Labels de plist do repo (nenhuma regra morta ou renomeada)" "${MISS:-batem}:$([ "$N" -ge 7 ] && echo ok)" "batem:ok"
SYS="$(awk -F'\t' '$1=="aposentar" && $3=="system"{print $5}' "$TSV_REAL")"
grep -qF "<string>$SYS</string>" "$CITY_ROOT/docs/runbooks/nightly-reboot-PENDING-INSTALL.md" && T4=ok || T4=falta; grep -qF 'br.urblink.cloudflared.urblink-ops' "$CITY_ROOT/scripts/nightly-reboot-postcheck.sh" && T5=ok || T5=falta
eq "T4 o LaunchDaemon da lista e o do runbook do reboot noturno; T5 o tunel e o TUNNEL_LABEL do postcheck" "$SYS:$T4:$T5" "com.gascity.nightly-reboot:ok:ok"
eq "T6 so nomes de camada conhecidos (os da .2 + reboot-noturno)" "$(awk -F'\t' '$1=="aposentar"||$1=="manter"{print $2}' "$TSV_REAL" | sort -u | grep -vxE 'envios|backups|cloudflared|paineis|reboot-noturno' | tr '\n' ' ')" ""
DOC="$CITY_ROOT/docs/runbooks/mini64/04-aposentar.md"
eq "R o runbook existe, o 1o titulo ## e Contents, e cita os 4 scripts de upload que recusam (todos existem)" "$(awk '/^## /{print $2; exit}' "$DOC"):$(for s in scripts/dolt-s3-backup.sh scripts/dolt-backup-s3-proof.sh scripts/dolt-backup-reseed.sh packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh; do [ -f "$CITY_ROOT/$s" ] && grep -qF "$s" "$DOC" && printf x; done)" "Contents:xxxx"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
