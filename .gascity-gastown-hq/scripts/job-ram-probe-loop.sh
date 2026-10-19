#!/bin/sh
# job-ram-probe-loop.sh — coletor de pegada de RAM por job que SOBREVIVE AO REBOOT e se encerra sozinho (ga-sh8t23.6, decisão do Mayor em 19/10).
#
# Contents
#   Por que existe · O que faz · Fim da missão · O que conta como noite · Variáveis
#
# POR QUE EXISTE  O mini reinicia toda noite (23:41); um processo lançado uma vez não chega à janela 03:30-05:10 do dia seguinte. As noites 18 e 19/10 se perderam assim (o loop da ga-sh8t23.3
#   morreu às 05:26 de 17/10 e o plist dele não ficava em ~/Library/LaunchAgents). Este script roda como LaunchAgent (packs/town-deltas/assets/com.gascity.job-ram-probe-loop.plist: RunAtLoad, SEM
#   KeepAlive): a cada boot ele recomeça sozinho, espera a janela e mede.
# O QUE FAZ       Uma noite por volta: `job-ram-probe.py --start 03:30 --until 05:10` grava `.gc/job-ram-probe-AAAAMMDD.jsonl` (um arquivo por noite) e a volta é anotada em
#   `.gc/job-ram-probe-run/loop.log` (`<hora> noite AAAAMMDD rc=N [parcial]`). Com menos de 3 GB livres o probe NÃO amostra e grava `pulado: disco` (--skip-free-gb 3); abaixo de 0,1 GB para (rc 6).
#   Volta que falha (rc != 0) repete em 5 min; 6 falhas seguidas e o script desiste (exit 1) SEM mexer no agente: o próximo boot tenta de novo, e a data-limite abaixo decide o resto.
# FIM DA MISSÃO   Duas saídas, as duas fazem o mesmo: apagam o plist de ~/Library/LaunchAgents, escrevem `fim: <motivo>` no loop.log e dão `launchctl bootout` (o plist sai ANTES porque o bootout mata
#   este processo). (1) 4 noites completas no loop.log (a de 17/10 + 3 novas); (2) DATA-LIMITE 23/10 05:30 (JRL_DEADLINE), com ou sem as 4 noites: passou dela, ou a próxima noite acabaria (05:10)
#   depois dela. A data-limite é conferida a CADA início: se o loop morrer antes, o 1º boot depois dela (o de 23/10 às 23:41, no pior caso) tira o agente. Prova de remoção: `launchctl print
#   gui/$(id -u)/com.gascity.job-ram-probe-loop` com rc 113 e o plist ausente.
# O QUE CONTA COMO NOITE  Só `rc=0` E volta que COMEÇOU antes das 04:00: o lote das 04:00 é o que a medição quer ver; um plist instalado às 04:30 gravaria 40 min que não o cobrem, e isso ficaria
#   igual a uma noite inteira. Essa volta é anotada `rc=0 parcial` e NÃO conta (o loop segue para a noite seguinte). Dia repetido conta uma vez. loop.log ausente/ilegível = 0 noites contadas (o
#   mesmo que "não sei": segue medindo, e a data-limite segura o fim, nunca o contrário).
# VARIÁVEIS (só para teste): JRL_PROBE_CMD (comando do probe; sem espaços nos caminhos) · JRL_LAUNCHCTL · JRL_LABEL · JRL_AGENT_PLIST · JRL_DEADLINE (AAAAMMDDhhmm) · JRL_NIGHTS · JRL_RETRY_SLEEP (s) ·
#   JRL_NOW_FILE (arquivo com a hora AAAAMMDDhhmm, no lugar do relógio). Teste: `bash scripts/job-ram-probe-loop.selftest.sh`.
D=$(cd "$(dirname "$0")" && pwd)
CITY="${GC_CITY_PATH:-$(cd "$D/.." && pwd)}"
RUN="$CITY/.gc/job-ram-probe-run"
LOG="$RUN/loop.log"
LABEL="${JRL_LABEL:-com.gascity.job-ram-probe-loop}"
PROBE_CMD="${JRL_PROBE_CMD:-python3 -I $D/job-ram-probe.py}"
LAUNCHCTL="${JRL_LAUNCHCTL:-launchctl}"
AGENT_PLIST="${JRL_AGENT_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
DEADLINE="${JRL_DEADLINE:-202610230530}"
NIGHTS="${JRL_NIGHTS:-4}"
RETRY="${JRL_RETRY_SLEEP:-300}"

mkdir -p "$RUN" || { echo "job-ram-probe-loop: não consegui criar $RUN" >&2; exit 1; }
log() { echo "$(date +%FT%T) $*" >> "$LOG"; }
isnum() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

now_stamp() {  # AAAAMMDDhhmm local; JRL_NOW_FILE só no teste. vazio/ilegível → "" (o chamador trata como falha, não como hora)
  if [ -n "${JRL_NOW_FILE:-}" ]; then cat "$JRL_NOW_FILE" 2>/dev/null; else date +%Y%m%d%H%M; fi
}

night_day() {  # $1 = AAAAMMDDhhmm → AAAAMMDD da noite 03:30-05:10 que ainda não acabou (a partir das 05:10 é a de amanhã). falhou → "" (python3 ausente ou hora ilegível: não sei o dia)
  python3 -I -c 'import datetime as d, sys; t = d.datetime.strptime(sys.argv[1], "%Y%m%d%H%M"); print((t + d.timedelta(days=1 if t.hour * 60 + t.minute >= 310 else 0)).strftime("%Y%m%d"))' "$1" 2>/dev/null
}

nights_done() {  # nº de dias distintos com `noite AAAAMMDD rc=0` e SEM `parcial`. log ausente/ilegível → 0 (não sei ≠ completo)
  awk '$2 == "noite" && $4 == "rc=0" && $5 != "parcial" && $3 ~ /^[0-9]+$/ {print $3}' "$LOG" 2>/dev/null | sort -u | wc -l | tr -d ' '
}

finish() {  # fim da missão. O plist sai ANTES do bootout, que mata este processo; o motivo vai para o log antes dos dois.
  log "fim: $1"
  rm -f "$AGENT_PLIST"
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >> "$LOG" 2>&1
  exit 0
}

isnum "$DEADLINE" && isnum "$NIGHTS" && isnum "$RETRY" || { echo "job-ram-probe-loop: JRL_DEADLINE/JRL_NIGHTS/JRL_RETRY_SLEEP precisam ser números" >&2; exit 2; }
fails=0
while :; do
  now=$(now_stamp)
  if ! isnum "$now" || [ "${#now}" -ne 12 ]; then  # sem hora legível não decido nada (nem fim, nem noite): conta como falha
    fails=$((fails + 1)); log "falha: hora ilegível ('$now'), $fails seguida(s)"
    [ "$fails" -ge 6 ] && { log "desisto: 6 falhas seguidas"; exit 1; }
    sleep "$RETRY"; continue
  fi
  [ "$now" -ge "$DEADLINE" ] && finish "data-limite $DEADLINE passou (agora $now)"
  n=$(nights_done)
  isnum "$n" || n=0
  [ "$n" -ge "$NIGHTS" ] && finish "$n noites completas (>= $NIGHTS)"
  day=$(night_day "$now")
  if ! isnum "$day" || [ "${#day}" -ne 8 ]; then
    fails=$((fails + 1)); log "falha: não consegui calcular o dia da noite (agora $now), $fails seguida(s)"
    [ "$fails" -ge 6 ] && { log "desisto: 6 falhas seguidas"; exit 1; }
    sleep "$RETRY"; continue
  fi
  [ "${day}0510" -gt "$DEADLINE" ] && finish "a noite $day acaba (05:10) depois da data-limite $DEADLINE"
  hm=${now#????????}
  late=""; [ "$hm" -ge 400 ] && [ "$hm" -lt 510 ] && late=" parcial"  # começou depois das 04:00 e ainda dentro da janela: não cobre o lote das 04:00
  $PROBE_CMD --start 03:30 --until 05:10 --interval 5 --max-mb 60 --min-free-gb 0.1 --skip-free-gb 3 --out "$CITY/.gc/job-ram-probe-$day.jsonl"
  rc=$?
  [ "$rc" -eq 0 ] || late=""
  log "noite $day rc=$rc$late"
  if [ "$rc" -eq 0 ]; then
    fails=0
  else
    fails=$((fails + 1))
    [ "$fails" -ge 6 ] && { log "desisto: $fails falhas seguidas (última rc=$rc)"; exit 1; }
    sleep "$RETRY"
  fi
done
