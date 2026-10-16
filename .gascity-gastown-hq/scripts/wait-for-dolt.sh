#!/usr/bin/env bash
# wait-for-dolt.sh (ga-sh8t23.2; revisão de arquitetura 15/10) — espera o Dolt ficar pronto e SÓ ENTÃO roda o comando (exec).
#
# Contents
#   Para que serve · Uso · Os três estados · Códigos de saída · Limites
#
# PARA QUE SERVE
#   No boot ~227 plists com RunAtLoad sobem juntos (medido 16/10, ga-sh8t23). Os que leem o Dolt (bd/gc/dolt) concorrem com o servidor que ainda está subindo, e uma
#   leitura que volta vazia ou falha porque o servidor não subiu é lida pelo job como "não tem" (a família "erro e vazio dão o mesmo valor"). Este wrapper vai na frente do
#   comando no ProgramArguments do plist: o job só começa quando a sonda do dolt-pid-lib.sh (dolt_server_pid) acha um Dolt DE VERDADE — executável `dolt` E socket LISTEN,
#   nunca porta escrita em doc. Quem escolhe os jobs é o wait-for-dolt-plan.py (lista medida + política revisada); este arquivo só espera.
#
# USO   wait-for-dolt.sh [--timeout SEG] [--boot-window SEG] -- COMANDO [ARGS...]
#   --timeout SEG       prazo da espera, 0-3600 (padrão 300; env WAIT_FOR_DOLT_TIMEOUT; a flag vence a env). Valor ilegível → padrão 300 e uma linha AVISO (ausente usa o padrão em silêncio).
#   --boot-window SEG   só espera se o boot foi há MENOS de SEG segundos (0-86400; padrão 0 = sempre espera; env WAIT_FOR_DOLT_BOOT_WINDOW). Passada a janela, roda o comando
#                       direto, sem sondar: o wrapper fica no ProgramArguments de TODA execução do job, e um alarme com StartInterval não pode virar mudo (nem pagar lsof a cada
#                       minuto) só porque o Dolt caiu no meio do dia. Uptime que não consigo ler → trata como boot (espera) e avisa. Valor ilegível → padrão 0.
#   WAIT_FOR_DOLT_POLL  intervalo entre sondagens em segundos (padrão 5; aceita decimal; é o gancho dos testes). WAIT_FOR_DOLT_LIB troca o dolt-pid-lib.sh (testes).
#
# OS TRÊS ESTADOS (o que não sei NÃO vira "pronto")
#   Dolt pronto            → exec do comando (o rc dele é o rc do job; não há subshell). Silencioso se já estava pronto; se esperou, uma linha com o tempo.
#   Dolt não veio no prazo → NÃO roda o comando; uma linha no stderr (o launchd a leva ao StandardErrorPath do job) com o prazo e o tempo esperado; rc 75.
#   Sonda sem condição de saber (lib ilegível, sem a função, falta ps/lsof/pgrep) → NÃO roda, mesma saída inerte; rc 76. A sonda que volta vazia, com erro ou com lixo
#   que não é PID conta como "ainda não" e segue esperando até o prazo: nunca como pronto.
#
# CÓDIGOS  64 uso errado · 75 Dolt não ficou pronto no prazo · 76 sonda indisponível · qualquer outro = o rc do comando embrulhado (exec; se o próprio comando devolver 64/75/76
#   a linha de log é que distingue). Comando que não existe/não executa → 126/127 do bash.
#
# LIMITES  "pronto" = o que a sonda diz (processo `dolt` com socket LISTEN), não "respondeu uma consulta". A espera pode passar do prazo por um intervalo de sondagem mais uma
#   sondagem (sem `timeout` do coreutils no PATH do launchd não dá para limitar o lsof). Compatível com o bash 3.2 do /bin/bash do macOS (é o que o launchd acha no PATH).
set -uo pipefail

log() { printf '%s wait-for-dolt[%s] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "${XPC_SERVICE_NAME:-?}" "$*" >&2; }
usage() { log "uso: wait-for-dolt.sh [--timeout SEG] [--boot-window SEG] -- COMANDO [ARGS...] ($*)"; exit 64; }

# inteiro em [0,MAX]; ilegível (vazio, sinal, letra, grande demais) → o padrão e um AVISO — o padrão nunca é "sem espera" por engano.
pick_int() { # $1 nome  $2 valor  $3 padrão  $4 máximo
  case "$2" in ''|*[!0-9]*) log "AVISO: $1='$2' não é um inteiro de 0 a $4; usando o padrão $3"; printf '%s' "$3"; return 0 ;; esac   # GUARD:pick-int
  if [ "${#2}" -gt 6 ] || [ "$((10#$2))" -gt "$4" ]; then log "AVISO: $1='$2' passa de $4; usando o padrão $3"; printf '%s' "$3"; return 0; fi
  printf '%s' "$((10#$2))"
}

# segundos desde o boot; vazio + rc 1 quando não consigo saber (sysctl ausente/falhando, formato novo, relógio antes do boot).
boot_uptime() {
  local raw sec now
  raw=$(sysctl -n kern.boottime 2>/dev/null) || return 1
  sec=${raw#*sec = }; sec=${sec%%,*}
  case "$sec" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$sec" ] || return 1
  printf '%s' "$((now - sec))"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) [ $# -ge 2 ] || usage "--timeout sem valor"; t_flag="$2"; shift 2 ;;
    --boot-window) [ $# -ge 2 ] || usage "--boot-window sem valor"; b_flag="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage "argumento desconhecido: $1" ;;
  esac
done
[ $# -gt 0 ] || usage "falta o comando depois de --"

if [ "${t_flag+set}" = set ]; then TIMEOUT=$(pick_int --timeout "$t_flag" 300 3600)
elif [ "${WAIT_FOR_DOLT_TIMEOUT+set}" = set ]; then TIMEOUT=$(pick_int WAIT_FOR_DOLT_TIMEOUT "$WAIT_FOR_DOLT_TIMEOUT" 300 3600)
else TIMEOUT=300; fi
if [ "${b_flag+set}" = set ]; then BOOT_WINDOW=$(pick_int --boot-window "$b_flag" 0 86400)
elif [ "${WAIT_FOR_DOLT_BOOT_WINDOW+set}" = set ]; then BOOT_WINDOW=$(pick_int WAIT_FOR_DOLT_BOOT_WINDOW "$WAIT_FOR_DOLT_BOOT_WINDOW" 0 86400)
else BOOT_WINDOW=0; fi
POLL=${WAIT_FOR_DOLT_POLL:-5}
case "$POLL" in ''|*[!0-9.]*|.*|*.|*.*.*) POLL=5 ;; esac   # ilegível → 5 (gancho de teste: sem AVISO)
case "$POLL" in *[1-9]*) ;; *) POLL=5 ;; esac   # zero ("0", "0.0") viraria laço quente

if [ "$BOOT_WINDOW" -gt 0 ]; then
  # vazio/falhou → uptime desconhecido: trata como boot (espera o Dolt), nunca como "já passou a janela"
  if up=$(boot_uptime); then
    if [ "$up" -ge "$BOOT_WINDOW" ]; then exec "$@"; fi   # GUARD:passthrough — fora do boot o wrapper é transparente (nada de sonda, nada de espera)
  else
    log "AVISO: uptime ilegível (sysctl kern.boottime); tratando como boot e esperando o Dolt"   # GUARD:uptime-unknown-gates
  fi
fi

LIB=${WAIT_FOR_DOLT_LIB:-$(cd "$(dirname "$0")" && pwd)/dolt-pid-lib.sh}
# vazio → n/a; falhou/ilegível → rc 76 (sonda indisponível): o comando NÃO roda, nunca "pronto por falta de resposta"
[ -r "$LIB" ] || { log "sonda indisponível: $LIB ilegível; NÃO rodo $1"; exit 76; }   # GUARD:probe-unavailable
. "$LIB" 2>/dev/null || { log "sonda indisponível: não consegui carregar $LIB; NÃO rodo $1"; exit 76; }
type dolt_server_pid >/dev/null 2>&1 || { log "sonda indisponível: $LIB não define dolt_server_pid; NÃO rodo $1"; exit 76; }
for tool in ps lsof pgrep; do
  command -v "$tool" >/dev/null 2>&1 || { log "sonda indisponível: falta '$tool' no PATH; NÃO rodo $1"; exit 76; }
done

start=$SECONDS; announced=0
while :; do
  # vazio → ainda não há servidor, segue esperando; falhou (rc≠0) → idem; lixo que não é PID → idem. Nenhum dos três é "pronto".
  pid=$(dolt_server_pid 2>/dev/null) || pid=""   # GUARD:probe-fail-not-ready
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac   # GUARD:garbage-pid
  [ -n "$pid" ] && break
  waited=$((SECONDS - start))
  if [ "$waited" -ge "$TIMEOUT" ]; then
    log "Dolt NÃO ficou pronto em ${waited}s (prazo ${TIMEOUT}s); NÃO rodo $1"
    exit 75   # GUARD:timeout-inert
  fi
  [ "$announced" = 1 ] || { log "aguardando o Dolt (prazo ${TIMEOUT}s) para $1"; announced=1; }
  sleep "$POLL"
done
[ "$announced" = 1 ] && log "Dolt pronto (pid $pid) após $((SECONDS - start))s; rodando $1"
exec "$@"   # GUARD:final-exec — exec, não subshell: o rc do comando é o rc do job
