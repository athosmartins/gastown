#!/bin/sh
# job-ram-probe-loop.sh — coletor de pegada de RAM por job que SOBREVIVE AO REBOOT e se encerra sozinho (ga-sh8t23.6, decisão do Mayor em 19/10).
#
# Contents
#   Por que existe · O que faz · Fim da missão · O que conta como noite · Variáveis
#
# POR QUE EXISTE  O mini reinicia toda noite (23:41); um processo lançado uma vez não chega à janela 03:30-05:10 do dia seguinte. As noites 18 e 19/10 se perderam assim (o loop da ga-sh8t23.3
#   morreu às 05:26 de 17/10 e o plist dele não ficava em ~/Library/LaunchAgents). Este script roda como LaunchAgent (com.gascity.job-ram-probe-loop.plist: RunAtLoad, SEM
#   KeepAlive; o plist saiu do repo em 23/10, ga-l0glof, e a receita de reinstalar está em docs/runbooks/grade-noturna.md): a cada boot ele recomeça sozinho, espera a janela e mede.
# O QUE FAZ       Uma noite por volta: `job-ram-probe.py --start 03:30 --until 05:10` grava `.gc/job-ram-probe-AAAAMMDD.jsonl` (um arquivo por noite) e a volta é anotada em
#   `.gc/job-ram-probe-run/loop.log` (`<hora> noite AAAAMMDD rc=N [parcial] cego=Ns`). Com menos de 3 GB livres o probe NÃO amostra e só grava a linha `pulado: disco` (--skip-free-gb 3, ~100 B por passo; se nem
#   ela couber, o probe conta e segue). O piso duro --min-free-gb 0.1 só é conferido depois de uma amostra TIRADA, então com o disco já abaixo de 3 GB ele não chega a rodar.
#   Volta que falha (rc != 0) repete em 5 min; 6 falhas seguidas e o script desiste (exit 1) SEM mexer no agente: o próximo boot tenta de novo, e a data-limite abaixo decide o resto.
# FIM DA MISSÃO   Duas saídas, as duas fazem o mesmo: apagam o plist de ~/Library/LaunchAgents, escrevem `fim: <motivo>` no loop.log e dão `launchctl bootout` (o plist sai ANTES porque o bootout mata
#   este processo). (1) 4 noites completas no loop.log (a de 17/10 + 3 novas); (2) DATA-LIMITE 23/10 05:30 (JRL_DEADLINE), com ou sem as 4 noites: passou dela, ou a próxima noite acabaria (05:10)
#   depois dela. A data-limite é conferida a CADA início: se o loop morrer antes, o 1º boot depois dela (o de 23/10 às 23:41, no pior caso) tira o agente. Prova de remoção: `launchctl print
#   gui/$(id -u)/com.gascity.job-ram-probe-loop` com rc 113 e o plist ausente.
# O QUE CONTA COMO NOITE  Só `rc=0`, volta que COMEÇOU antes das 04:00 E com no máximo JRL_BLIND_MAX s (600) CEGOS. O lote das 04:00 é o que a medição quer ver: um plist instalado às 04:30 gravaria
#   40 min que não o cobrem, e uma noite em que o disco ficou baixo (ou ps/launchctl falharam, ou a máquina parou) tem `rc=0` igual à de leitura inteira, porque o probe só falha sem NENHUMA amostra.
#   Por isso a noite é julgada pelo ARQUIVO contra a JANELA, não pelo rc: `cego=Ns` = tempo sem leitura utilizável (tick `pulado`, `ps_ok`/`lc_ok` falso, buraco > 3 passos, do 1º tick gravado até a 1ª leitura boa e da última
#   leitura boa até o último tick gravado) MAIS as pontas, que o arquivo sozinho não mostra: do lote (04:00) até o 1º tick, se ele saiu depois das 04:00 (o loop pode ter começado cedo e o probe demorado), e do último tick
#   até o fim da janela (05:10), se o arquivo para antes. O probe sai com rc=0 pelo RELÓGIO (passou das 05:10), não por ter amostrado até lá: uma máquina que dormiu ou um probe travado deixam rc=0 e um arquivo curto.
#   Buraco ou ponta de até 3 passos (15 s) não entra: `Ns` é limite INFERIOR do tempo cego. 600 s folgam o reseed de 17/10 (235 s + 46 s). Passou do limite → `parcial`, NÃO conta, o loop segue para a noite seguinte.
#   `cego=tudo` = o arquivo não tem leitura utilizável; `cego=?` = não consegui ler o arquivo ou calcular a janela: os dois são `parcial` (não sei ≠ 0 s cego). Dia repetido conta uma vez. Linha SEM `cego=` é do loop anterior (a noite de 17/10, sem piso de disco)
#   e vale como estava. loop.log ausente/ilegível = 0 noites contadas (o mesmo que "não sei": segue medindo, e a data-limite segura o fim, nunca o contrário). O `fim:` diz quantas noites
#   completas havia: a data-limite pode encerrar com menos de 4, e quem lê precisa ver isso sem reabrir o log.
# VARIÁVEIS (só para teste): JRL_PROBE_CMD (comando do probe; sem espaços nos caminhos) · JRL_LAUNCHCTL · JRL_LABEL · JRL_AGENT_PLIST · JRL_DEADLINE (AAAAMMDDhhmm) · JRL_NIGHTS · JRL_RETRY_SLEEP (s) · JRL_BLIND_MAX (s cegos que ainda deixam a noite valer) ·
#   JRL_NOW_FILE (arquivo com a hora AAAAMMDDhhmm, no lugar do relógio) · JRL_WINDOW_PY (o python que calcula a janela da noite; o teste põe `false`/`echo` para fazê-lo falhar). Teste: `bash scripts/job-ram-probe-loop.selftest.sh`.
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
INTERVAL=5                                  # s entre amostras; o julgamento da noite (blind_secs) usa o mesmo passo
BLIND_MAX="${JRL_BLIND_MAX:-600}"
WPY="${JRL_WINDOW_PY:-python3}"

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

window_epochs() {  # $1 = AAAAMMDD → "R0 R1": epoch LOCAL de 04:00 (o lote das 04:00) e de 05:10 (o fim da janela) dessa noite. Python que falha ou saída que não são 2 epochs → rc 1 (o chamador faz cego=?; janela não se adivinha)
  # vazio → rc 1 (0 campos); falhou/ilegível → rc 1 (o `||`, e o que não são 2 epochs): nos dois o chamador marca a noite `cego=?`, nunca a dá por coberta
  w=$("$WPY" -I -c 'import sys, time
d = sys.argv[1]
e = lambda h, m: int(time.mktime((int(d[:4]), int(d[4:6]), int(d[6:]), h, m, 0, 0, 0, -1)))
print(e(4, 0), e(5, 10))' "$1" 2>/dev/null) || return 1
  set -- $w
  [ $# -eq 2 ] && isnum "$1" && isnum "$2" || return 1
  echo "$1 $2"
}

blind_secs() {  # $1 = arquivo da noite, $2 = AAAAMMDD da noite → segundos SEM leitura utilizável (ver "O QUE CONTA COMO NOITE"). vazio (nenhum tick cego) → 0; sem leitura boa nenhuma → "tudo"; falhou/ilegível/sem tick/sem janela → "?"
  [ -s "$1" ] || { echo "?"; return 1; }
  # vazio → "?" (sem janela não há com o que comparar as pontas); falhou/ilegível → "?" (a noite fica parcial: não sei ≠ 0 s cego)
  w=$(window_epochs "$2") || { echo "?"; return 1; }
  b=$(awk -v iv="$INTERVAL" -v r0="${w% *}" -v r1="${w#* }" '
    !/^\{"ts":[0-9]+/ { next }
    { match($0, /[0-9]+/); t = substr($0, RSTART, RLENGTH) + 0; if (!seen) { first = t; seen = 1 }; last = t }
    /"pulado"|"ps_ok":false|"lc_ok":false/ { next }
    { if (!good) { blind += t - first; good = 1 } else if (t - prev > 3 * iv) blind += t - prev - iv; prev = t }
    END { if (!seen) exit 3; if (!good) { print "tudo"; exit 0 }
          if (first - r0 > 3 * iv) blind += first - r0             # o 1º tick saiu mais de 3 passos depois do lote das 04:00: o que veio antes dele não foi lido
          if (r1 - last > 3 * iv) blind += r1 - last - iv          # o arquivo para antes do fim da janela: o resto da noite não foi lido
          print int(blind + (last - prev)) }' "$1" 2>/dev/null) || { echo "?"; return 1; }
  [ "$b" = tudo ] || isnum "$b" || { echo "?"; return 1; }
  echo "$b"
}

finish() {  # fim da missão. O plist sai ANTES do bootout, que mata este processo; o motivo vai para o log antes dos dois. Plist que continua lá depois do rm é dito (o próximo boot refaz o fim)
  log "fim: $1"
  rm -f "$AGENT_PLIST"
  [ ! -e "$AGENT_PLIST" ] || log "AVISO: não consegui apagar $AGENT_PLIST; o agente continua instalado (o próximo boot refaz o fim)"
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >> "$LOG" 2>&1
  exit 0
}

isnum "$DEADLINE" && isnum "$NIGHTS" && isnum "$RETRY" && isnum "$BLIND_MAX" || { echo "job-ram-probe-loop: JRL_DEADLINE/JRL_NIGHTS/JRL_RETRY_SLEEP/JRL_BLIND_MAX precisam ser números (limite que não leio não pode virar 'noite sempre vale')" >&2; exit 2; }
fails=0
while :; do
  now=$(now_stamp)
  if ! isnum "$now" || [ "${#now}" -ne 12 ]; then  # sem hora legível não decido nada (nem fim, nem noite): conta como falha
    fails=$((fails + 1)); log "falha: hora ilegível ('$now'), $fails seguida(s)"
    [ "$fails" -ge 6 ] && { log "desisto: 6 falhas seguidas"; exit 1; }
    sleep "$RETRY"; continue
  fi
  n=$(nights_done)
  isnum "$n" || n=0
  [ "$now" -ge "$DEADLINE" ] && finish "data-limite $DEADLINE passou (agora $now); $n de $NIGHTS noites completas"
  [ "$n" -ge "$NIGHTS" ] && finish "$n noites completas (>= $NIGHTS)"
  day=$(night_day "$now")
  if ! isnum "$day" || [ "${#day}" -ne 8 ]; then
    fails=$((fails + 1)); log "falha: não consegui calcular o dia da noite (agora $now), $fails seguida(s)"
    [ "$fails" -ge 6 ] && { log "desisto: 6 falhas seguidas"; exit 1; }
    sleep "$RETRY"; continue
  fi
  [ "${day}0510" -gt "$DEADLINE" ] && finish "a noite $day acaba (05:10) depois da data-limite $DEADLINE; $n de $NIGHTS noites completas"
  hm=${now#????????}
  late=""; [ "$hm" -ge 400 ] && [ "$hm" -lt 510 ] && late=" parcial"  # começou depois das 04:00 e ainda dentro da janela: não cobre o lote das 04:00
  night="$CITY/.gc/job-ram-probe-$day.jsonl"
  $PROBE_CMD --start 03:30 --until 05:10 --interval "$INTERVAL" --max-mb 60 --min-free-gb 0.1 --skip-free-gb 3 --out "$night"
  rc=$?
  cego=""
  if [ "$rc" -ne 0 ]; then
    late=""
  else  # a noite é julgada pelo arquivo: rc=0 só diz que houve ao menos UMA amostra
    b=$(blind_secs "$night" "$day")
    if isnum "$b"; then cego=" cego=${b}s"; [ "$b" -gt "$BLIND_MAX" ] && late=" parcial"; else cego=" cego=$b"; late=" parcial"; fi
  fi
  log "noite $day rc=$rc$late$cego"
  if [ "$rc" -eq 0 ]; then
    fails=0
  else
    fails=$((fails + 1))
    [ "$fails" -ge 6 ] && { log "desisto: $fails falhas seguidas (última rc=$rc)"; exit 1; }
    sleep "$RETRY"
  fi
done
