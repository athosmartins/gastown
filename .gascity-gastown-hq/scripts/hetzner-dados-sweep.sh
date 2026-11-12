#!/bin/bash
# hetzner-dados-sweep.sh — varredura diária do dado que o trap do gt-dados-run não pegou (kill -9, queda de energia, reboot em build) (ga-qg1dw5z.1). Instalado por ROOT como /usr/local/sbin/gt-dados-sweep, disparado pelo gt-dados-sweep.timer.
#
# ## Contents
#   O que faz · Linha de log · Códigos de saída
#
# O QUE FAZ: sem build vivo (processo de `dados` com menos de 3 h), apaga o staging /srv/gtdados, o home do `dados` e o que `dados` deixou em /tmp, /var/tmp e /dev/shm. Processo de `dados` com 3 h ou mais não é build
#   (o prazo do wrapper é 2 h): é morto, e a varredura segue. Conferiu que sumiu, ou diz que não conseguiu: leitura que falhou NUNCA vira "limpo".
# LINHA DE LOG (/var/log/gt-dados-sweep.log, e no journal; a trava 3 lê a última e a idade dela):
#   <UTC> gt-dados-sweep: LIMPO removed=N killed=K · PULADO dados-vivo=N · NAO-CONSEGUI <motivo>
# CÓDIGOS: 0 LIMPO ou PULADO · 2 NAO-CONSEGUI
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
DU=dados; STAGE=/srv/gtdados; DHOME=/home/dados; LOG=/var/log/gt-dados-sweep.log; MAXSECS=10800
log() { local l; l="$(date -u +%Y-%m-%dT%H:%M:%SZ) gt-dados-sweep: $*"; echo "$l"; echo "$l" >> "$LOG" 2> /dev/null || echo "gt-dados-sweep: NAO-CONSEGUI escrever $LOG" >&2; }
cant() { log "NAO-CONSEGUI $*"; exit 2; }
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
N=0
for d in "$STAGE" "$DHOME"; do
  # vazio → 0 itens; falhou (find com erro) → não consegui
  c=$(find "$d" -xdev -mindepth 1 2> /dev/null | wc -l | tr -d ' '); N=$((N + c))
  find "$d" -xdev -mindepth 1 -delete 2> /dev/null
  left=$(find "$d" -xdev -mindepth 1 -print -quit 2> /dev/null) || cant "leitura-falhou:$d"
  [ -z "$left" ] || cant "sobrou:$left"
done
for d in /tmp /var/tmp /dev/shm; do
  find "$d" -xdev -mindepth 1 -user "$DU" -delete 2> /dev/null
  left=$(find "$d" -xdev -mindepth 1 -user "$DU" -print -quit 2> /dev/null) || cant "leitura-falhou:$d"
  [ -z "$left" ] || cant "sobrou:$left"
done
log "LIMPO removed=$N killed=$KILLED"
