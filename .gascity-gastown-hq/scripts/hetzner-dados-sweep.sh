#!/bin/bash
# hetzner-dados-sweep.sh — varredura diária do dado que o trap do gt-dados-run não pegou (kill -9, queda de energia, reboot em build) (ga-qg1dw5z.1). Instalado por ROOT como /usr/local/sbin/gt-dados-sweep, disparado pelo gt-dados-sweep.timer.
#
# ## Contents
#   O que faz · Linha de log · Códigos de saída
#
# O QUE FAZ: sem build vivo (processo de `dados` com menos de 3 h, ou o lock do wrapper tomado), apaga o staging /srv/gtdados, o home do `dados` e o que `dados` deixou em /tmp, /var/tmp e /dev/shm. Processo de `dados`
#   com 3 h ou mais não é build (o prazo do wrapper é 2 h): é morto, e a varredura segue. Conferiu que sumiu, ou diz que não conseguiu: leitura que falhou NUNCA vira "limpo".
# LOCK: a varredura toma o MESMO lock do wrapper (/run/gt-dados-run.lock) e o segura até o fim: um build que comece no meio recusa `ocupado` em vez de ter o staging apagado (o filho do build herda o fd do lock, então
#   até um wrapper morto por kill -9 o mantém enquanto o build existir). Lock tomado por build vivo → PULADO. Um `put` do canal do mini que comece DEPOIS da checagem de processos não é protegido (o ingest não toma o lock).
# ALCANCE EM /tmp: só o 1º nível (o que `dados` cria direto lá, com o que houver dentro). O /tmp do nó tem ~1,7 milhão de entradas e a árvore inteira levou 40+ min sem terminar e sem escrever o log (medido 12/11);
#   arquivo de `dados` dentro de pasta de OUTRO dono em /tmp não é visto. /var/tmp e /dev/shm são varridos inteiros (pequenos). Cada apagamento e cada leitura de verificação tem prazo (SCANSECS): a verificação que estourou = NAO-CONSEGUI.
# LINHA DE LOG (/var/log/gt-dados-sweep.log, e no journal; a trava 3 lê a última e a idade dela):
#   <UTC> gt-dados-sweep: LIMPO removed=N killed=K · PULADO dados-vivo=N · PULADO build-vivo lock=ocupado · NAO-CONSEGUI <motivo>
# CÓDIGOS: 0 LIMPO ou PULADO · 2 NAO-CONSEGUI
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
DU=dados; STAGE=/srv/gtdados; DHOME=/home/dados; LOG=/var/log/gt-dados-sweep.log; MAXSECS=10800; LOCK=/run/gt-dados-run.lock; LOCKWAIT=10; SCANSECS=900; TOPONLY=/tmp
log() { local l; l="$(date -u +%Y-%m-%dT%H:%M:%SZ) gt-dados-sweep: $*"; echo "$l"; echo "$l" >> "$LOG" 2> /dev/null || echo "gt-dados-sweep: NAO-CONSEGUI escrever $LOG" >&2; }
cant() { log "NAO-CONSEGUI $*"; exit 2; }
# find com prazo. Entrada que SUMIU durante a leitura ("No such file or directory": o runner apaga e cria em /tmp o tempo todo) não é sobra e não reprova a leitura; QUALQUER outro erro, o prazo estourado (rc ≥ 124)
# ou rc ≠ 0 sem erro legível → return 2 (não consegui). Imprime o que o find imprimiu.
GONE="No such file or directory"
ff() { local ef out rc; ef=$(mktemp) || return 2
  out=$(timeout -k 5 "$SCANSECS" find "$@" 2> "$ef"); rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ge 124 ] || ! [ -s "$ef" ] || grep -v -F -e "$GONE" "$ef" | grep -q .; then rm -f "$ef"; return 2; fi
  fi
  rm -f "$ef"; [ -z "$out" ] || printf '%s\n' "$out"; return 0; }
id -u "$DU" > /dev/null 2>&1 || cant usuario-dados-ausente
# tmpfs de verdade e montagem PRÓPRIA; se não for, o dado pode estar em disco e esta varredura não prova nada (conta o que há, para quem ler o log)
if [ "$(findmnt -no FSTYPE --target "$STAGE" 2> /dev/null)" != tmpfs ] || ! mountpoint -q "$STAGE"; then cant "stage-nao-e-tmpfs itens=$(find "$STAGE" -mindepth 1 2> /dev/null | wc -l | tr -d ' ')"; fi
# vazio (rc 0, ninguém) → segue; falhou (ps com rc ≠ 0) → não consegui
P=$(ps -eo user:20=,etimes=,pid= 2> /dev/null) || cant ps-falhou
LIVE=$(printf '%s\n' "$P" | awk -v u="$DU" -v m="$MAXSECS" '$1 == u && $2 < m { n++ } END { print n + 0 }')
OLD=$(printf '%s\n' "$P" | awk -v u="$DU" -v m="$MAXSECS" '$1 == u && $2 >= m { print $3 }')
if [ "$LIVE" -gt 0 ]; then log "PULADO dados-vivo=$LIVE"; exit 0; fi
KILLED=0
for pid in $OLD; do kill -9 "$pid" 2> /dev/null && KILLED=$((KILLED + 1)); done
# lock livre → segue segurando-o até o fim; ocupado por build vivo (rc 75, depois de LOCKWAIT s: dá tempo de o kill -9 acima soltar o de um órfão) → PULADO; não consegui abrir/usar o lock → NAO-CONSEGUI (nunca varre às cegas)
{ exec 8> "$LOCK"; } 2> /dev/null || cant lock-ilegivel
flock -w "$LOCKWAIT" -E 75 8; r=$?
[ "$r" -ne 75 ] || { log "PULADO build-vivo lock=ocupado"; exit 0; }
[ "$r" -eq 0 ] || cant "lock-falhou:$r"
N=0
for d in "$STAGE" "$DHOME"; do
  # vazio → 0 itens; falhou (find com erro ou prazo estourado) → não consegui
  c=$(find "$d" -xdev -mindepth 1 2> /dev/null | wc -l | tr -d ' '); N=$((N + c))
  timeout -k 5 "$SCANSECS" find "$d" -xdev -mindepth 1 -delete 2> /dev/null
  left=$(ff "$d" -xdev -mindepth 1 -print -quit) || cant "leitura-falhou:$d"
  [ -z "$left" ] || cant "sobrou:$left"
done
for d in /tmp /var/tmp /dev/shm; do
  A=(-xdev -mindepth 1); [ "$d" != "$TOPONLY" ] || A+=(-maxdepth 1)
  # nível 1 de /tmp: apaga a entrada inteira (rm -rf, pasta com conteúdo); o resto: find -delete. O que não apagou aparece na leitura abaixo
  if [ "$d" = "$TOPONLY" ]; then timeout -k 5 "$SCANSECS" find "$d" "${A[@]}" -user "$DU" -exec rm -rf --one-file-system -- {} + 2> /dev/null
  else timeout -k 5 "$SCANSECS" find "$d" "${A[@]}" -user "$DU" -delete 2> /dev/null; fi
  # vazio → nada sobrou; falhou/prazo estourado → não consegui (nunca "limpo")
  left=$(ff "$d" "${A[@]}" -user "$DU" -print -quit) || cant "leitura-falhou:$d"
  [ -z "$left" ] || cant "sobrou:$left"
done
log "LIMPO removed=$N killed=$KILLED"
