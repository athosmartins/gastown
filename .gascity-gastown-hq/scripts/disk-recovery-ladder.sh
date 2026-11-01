#!/bin/bash
# disk-recovery-ladder.sh (ga-1p1i5jr.1, P0) — orquestrador da escada de recuperação de disco do mini.
#
# ## Contents
#   Por que existe · O que faz · Limiares · Três estados · Estado, log e interruptores · Contrato dos degraus · Variáveis (teste) · Teste
#
# POR QUE EXISTE  De ~05:00 a ~10:40 de 01/11 o disco do mini ficou entre 2 e 4 GB livres (memória virando swap) e as P0/P1 do WA pararam. Os guardas que existiam só LIMPAM ARQUIVO e
#   avisam (o dolt-disk-floor-guard diz "this guard never kills anything itself"). Decisão do Athos (AskUserQuestion na sessão do Mayor, 01/11 ~11:00 BRT, citada na ga-1p1i5jr): a escada
#   tem de agir sozinha até o reinício guardado do mini, a qualquer hora, com guardas. Este script é só o MAESTRO: lê o disco, guarda há quanto tempo está baixo e chama UM degrau por vez.
#   Ele não apaga nada, não para nada e não reinicia nada por conta própria: quem age são os scripts dos degraus (.2/.3/.4).
# O QUE FAZ       A cada rodada (launchd, 120 s): lê o livre do volume Data e o swap em uso; atualiza os cronômetros; se o tempo do limiar de um degrau passou e o degrau ainda não bastou,
#   chama esse degrau (`--run`); re-mede depois; escreve 1 linha de log e, se o degrau agiu ou falhou, notify + mail ao Mayor. Um degrau por rodada. D1 (limpeza de arquivo) é o
#   dolt-disk-floor-guard, que já roda sozinho a cada 5 min: o maestro NÃO o reimplementa nem o chama (ele já teve 3 passadas quando o D2 entra, aos 15 min).
# LIMIARES        (MB livres em `df -Pm /System/Volumes/Data` — NUNCA `df /`, que lê o volume de sistema selado e mostra 71% com o Data em 98%)
#   D2  livre <= 5120 por >= 900 s (15 min)     parar jobs pesados reiniciáveis da allowlist
#   D3  livre <= 4096 por >= 1800 s (30 min)    restart drenado dos daemons que mais usam RAM
#   D4  livre <  3072 por >= 3600 s (60 min)    OU livre < 1536 em 2 leituras SEGUIDAS (2 min)   reinício guardado do mini
#   O 2º caminho do D4 é parte do limiar dele (decisão do Athos: "< 1,5 GB a qualquer momento"), não um atalho: D2 e D3 só entram depois do tempo deles, e o D4 nunca entra antes do
#   dele a não ser por esse caminho. As 2 leituras seguidas são do maestro (uma leitura isolada abaixo de 1,5 GB, p.ex. um go build que sobe e solta, não reinicia o mini).
#   HISTERESE: o cronômetro de um nível só ZERA quando o livre volta a limiar + 512 MB. Entre o limiar e limiar + 512 MB ele nem começa nem zera: um disco que oscila em volta de 3 GB
#   por 5 h não pode reiniciar o relógio de 60 min a cada subida de 100 MB. Tudo isso é "tempo contínuo abaixo", só de rodadas que EU li: lacuna maior que 10 min entre duas leituras
#   (máquina parada, launchd fora, df ilegível) zera cronômetros e marcas, porque tempo que ninguém observou não vale como "60 min abaixo" para reiniciar uma máquina.
# TRÊS ESTADOS    tem / não-tem / não-consegui-saber. df ilegível ou swap ilegível NUNCA viram "tem bastante disco" nem "disco baixo": o maestro NÃO chama degrau nenhum, loga, avisa
#   (notify -p 4, no máximo 1 por hora) e sai com 30; os cronômetros salvos ficam como estavam (se a falta de leitura passar de 10 min, a lacuna os zera na próxima leitura boa).
#   Relógio ilegível: idem, mas só log/stdout e saída 30 (sem hora não há como limitar o aviso a 1 por hora). Estado salvo ilegível ou inválido é posto de lado (`.corrupt-<hora>`),
#   dito no log, e a rodada SEGUE com os cronômetros zerados (o lado inerte: nada dispara por um histórico que não consegui ler). Estado que não consigo gravar: aviso no log e saída 30.
# ESTADO, LOG, INTERRUPTORES
#   estado  $CITY/.gc/disk-recovery.state (chave=valor, escrito inteiro e trocado com mv)   log  $CITY/.gc/logs/disk-recovery.log (gira em 5 MB)
#   `touch $CITY/.gc/disk-recovery.off` desliga o maestro (sai 10 sem ler nem agir; apague o arquivo para voltar). Instância única por trava (mkdir) — o `--dry-run` não toma a trava.
#   O swap entra como leitura obrigatória e como contexto da mensagem; os limiares são de disco (a causa de 01/11 foi memória virando swap, e swap ocupa o mesmo disco).
#   Reinício em laço é impossível por construção: o `acted4_ts` é gravado ANTES de chamar o D4 (um reinício que mata este processo no meio não perde a marca) e o maestro não chama
#   `d4 --run` de novo por 6 h depois de um rc 0; nesse caso, com o disco ainda < 3 GB, escala (notify -p 5 + mail) em vez de reiniciar. O contrato pede que o D4 tenha cooldown próprio também (defesa em profundidade, ga-1p1i5jr.4); este maestro não depende disso.
# CONTRATO DOS DEGRAUS  scripts/disk-recovery-d2-heavy-jobs.sh · -d3-ram-daemons.sh · -d4-guarded-reboot.sh, chamados `<script> --run` (real) ou `--dry-run` (só diz o que faria);
#   stdout = UMA linha; saída 0 = agiu e terminou · 10 = nada a fazer ou guarda adiou · 20 = falhou · 30 = não consegui ler o estado (não age). Passou de 900 s = TERM e conta como 20.
#   Degrau ausente (ou sem permissão de execução): loga, avisa uma vez (notify -p 4) e PULA para o próximo. 10/20/30 repetem em 5 min; 0 não repete esse degrau por 30 min.
#   Cada degrau só entra quando o cronômetro DELE passou; um degrau por rodada; a marca de um degrau some quando o cronômetro dele zera. Ordem: a 1ª chamada de cada degrau no episódio
#   vai em D2→D3→D4; as repetições vão do mais alto para o mais baixo (senão o D2 repetindo a cada 5 min ocuparia toda rodada atrasada e o D3/D4 nunca teriam vez).
# MODOS           --run (launchd) · --dry-run (lê o estado salvo, aplica a leitura de agora numa cópia, chama os degraus com --dry-run, não grava estado/log, não avisa, não manda mail).
#   Sai: 0 rodada feita · 10 interruptor ligado ou outra instância rodando · 20 um degrau falhou · 30 não consegui ler (não agiu) · 2 uso.
# VARIÁVEIS (teste) DR_CITY · DR_STATE · DR_LOG · DR_OFF_FILE · DR_LOCK · DR_FREE_MB_FILE (arquivo com o livre em MB, no lugar do df) · DR_SWAP_MB_FILE (idem swap) · DR_NOW_FILE (epoch)
#   · DR_D2_CMD/DR_D3_CMD/DR_D4_CMD · DR_NOTIFY_BIN · DR_GC_BIN · DR_<NOME> numérico (D2_MB D2_HOLD_S D3_MB D3_HOLD_S D4_MB D4_HOLD_S D4_HARD_MB D4_HARD_N HYST_MB GAP_S RETRY_S
#   ACTED_REPEAT_S D4_COOLDOWN_S RUNG_TIMEOUT_S SETTLE_S WARN_EVERY_S HEARTBEAT_S LOG_MAX_KB NOTIFY_TIMEOUT_S MAIL_TIMEOUT_S; valor que não é número cai no padrão e é dito no log).
# TESTE           bash scripts/disk-recovery-ladder.selftest.sh   (hermético: df, swap, relógio, degraus, notify e mail simulados; nada real é parado nem reiniciado)
set -uo pipefail

D=$(cd "$(dirname "$0")" && pwd)
CITY="${DR_CITY:-${GC_CITY_PATH:-$(cd "$D/.." && pwd)}}"
GCDIR="$CITY/.gc"
STATE="${DR_STATE:-$GCDIR/disk-recovery.state}"
LOG="${DR_LOG:-$GCDIR/logs/disk-recovery.log}"
OFF="${DR_OFF_FILE:-$GCDIR/disk-recovery.off}"
LOCK="${DR_LOCK:-$GCDIR/disk-recovery.lock}"
NOTIFY="${DR_NOTIFY_BIN:-$HOME/.local/bin/notify}"
GCBIN="${DR_GC_BIN:-${GC_BIN:-gc}}"
D2_CMD="${DR_D2_CMD:-$D/disk-recovery-d2-heavy-jobs.sh}"
D3_CMD="${DR_D3_CMD:-$D/disk-recovery-d3-ram-daemons.sh}"
D4_CMD="${DR_D4_CMD:-$D/disk-recovery-d4-guarded-reboot.sh}"
VOLUME="/System/Volumes/Data"

DRY=""
CFG_WARN=""
RB_OUT=""
LOCK_HELD=0
RC_FINAL=0
SAVE_FAIL=0

cfg() {  # $1=nome $2=padrão → define a variável $1 com DR_$1 (só dígitos, até 9); vazio → padrão; lixo → padrão E registra em CFG_WARN (limiar que não leio não vira "sem limite")
  local v
  eval "v=\${DR_$1:-}"
  case "$v" in
    '') v=$2 ;;
    *[!0-9]*) CFG_WARN="$CFG_WARN DR_$1='$v'->$2"; v=$2 ;;
    *) [ "${#v}" -le 9 ] || { CFG_WARN="$CFG_WARN DR_$1='$v'->$2"; v=$2; } ;;
  esac
  eval "$1=\$v"
}
cfg D2_MB 5120;  cfg D2_HOLD_S 900
cfg D3_MB 4096;  cfg D3_HOLD_S 1800
cfg D4_MB 3072;  cfg D4_HOLD_S 3600
cfg D4_HARD_MB 1536; cfg D4_HARD_N 2
cfg HYST_MB 512; cfg GAP_S 600; cfg RETRY_S 300; cfg ACTED_REPEAT_S 1800; cfg D4_COOLDOWN_S 21600
cfg RUNG_TIMEOUT_S 900; cfg SETTLE_S 15; cfg WARN_EVERY_S 3600; cfg HEARTBEAT_S 3600; cfg LOG_MAX_KB 5120
cfg NOTIFY_TIMEOUT_S 30; cfg MAIL_TIMEOUT_S 60

log()  { if [ "$DRY" = 1 ]; then printf '[dry-run] %s\n' "$*"; else printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; fi; }
note() { log "$*"; [ "$DRY" = 1 ] || printf '%s\n' "$*"; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
getv() { eval "printf '%s' \"\${$1$2}\""; }
setv() { eval "$1$2=\$3"; }

usage() { echo "uso: $0 --run | --dry-run" >&2; exit 2; }

# ── relógio, leituras ────────────────────────────────────────────────────────────────────────────────────────────────────────────
now() {  # epoch em segundos. vazio → rc 1 (sem número); falhou/ilegível → rc 1: sem hora legível o maestro não decide nada (nem tempo de limiar, nem lacuna)
  local t
  if [ -n "${DR_NOW_FILE:-}" ]; then t=$(cat "$DR_NOW_FILE" 2>/dev/null) || return 1; else t=$(date +%s 2>/dev/null) || return 1; fi
  isnum "$t" || return 1
  printf '%s' "$t"
}

read_free_mb() {  # MB livres do volume Data, inteiro, em stdout. vazio → rc 1; falhou/ilegível → rc 1; df de outro volume (ponto de montagem diferente) → rc 1. NUNCA 0 e nunca "tem bastante"
  local out v mp
  if [ -n "${DR_FREE_MB_FILE:-}" ]; then
    v=$(cat "$DR_FREE_MB_FILE" 2>/dev/null) || return 1
  else
    out=$(df -Pm "$VOLUME" 2>/dev/null) || return 1
    v=$(printf '%s\n' "$out" | awk 'NR==2 {print $4}')
    mp=$(printf '%s\n' "$out" | awk 'NR==2 {print $6}')
    [ "$mp" = "$VOLUME" ] || return 1
  fi
  isnum "$v" && [ "${#v}" -le 9 ] || return 1
  printf '%s' "$v"
}

read_swap_mb() {  # MB de swap EM USO, inteiro, em stdout. vazio → rc 1; falhou/ilegível/unidade que não é M nem G → rc 1 (não sei ≠ 0 MB de swap)
  local out v
  if [ -n "${DR_SWAP_MB_FILE:-}" ]; then
    v=$(cat "$DR_SWAP_MB_FILE" 2>/dev/null) || return 1
  else
    out=$(sysctl -n vm.swapusage 2>/dev/null) || return 1
    v=$(printf '%s\n' "$out" | awk '{for (i = 1; i <= NF; i++) if ($i == "used") { x = $(i + 2); u = substr(x, length(x)); n = substr(x, 1, length(x) - 1)
          if (n ~ /^[0-9]+(\.[0-9]+)?$/ && (u == "M" || u == "G")) { if (u == "G") n = n * 1024; printf "%d", n; exit } } }')
  fi
  isnum "$v" && [ "${#v}" -le 9 ] || return 1
  printf '%s' "$v"
}

measure() {  # lê livre e swap → M_FREE, M_SWAP; rc 0 só se OS DOIS foram lidos. Diz em M_WHY o que faltou
  M_FREE=""; M_SWAP=""; M_WHY=""
  M_FREE=$(read_free_mb) || { M_FREE=""; M_WHY="df de $VOLUME ilegível"; }
  M_SWAP=$(read_swap_mb) || { M_SWAP=""; M_WHY="${M_WHY:+$M_WHY; }swap (vm.swapusage) ilegível"; }
  [ -z "$M_WHY" ]
}

# ── níveis, cronômetros ──────────────────────────────────────────────────────────────────────────────────────────────────────────
lv_mb()   { case "$1" in 2) printf '%s' "$D2_MB" ;; 3) printf '%s' "$D3_MB" ;; *) printf '%s' "$D4_MB" ;; esac; }
lv_hold() { case "$1" in 2) printf '%s' "$D2_HOLD_S" ;; 3) printf '%s' "$D3_HOLD_S" ;; *) printf '%s' "$D4_HOLD_S" ;; esac; }
rung_cmd() { case "$1" in 2) printf '%s' "$D2_CMD" ;; 3) printf '%s' "$D3_CMD" ;; *) printf '%s' "$D4_CMD" ;; esac; }
in_lv() {   # $1=n $2=livre → rc 0 se o livre está NO nível: D2 e D3 "<=", D4 "<" (os textos da missão: "≤ 5 GB", "≤ 4 GB", "< 3 GB")
  local t; t=$(lv_mb "$1")
  if [ "$1" = 4 ]; then [ "$2" -lt "$t" ]; else [ "$2" -le "$t" ]; fi
}
out_lv() {  # $1=n $2=livre → rc 0 se o livre voltou a limiar + histerese (só aí o cronômetro zera)
  local t; t=$(lv_mb "$1"); [ "$2" -ge $((t + HYST_MB)) ]
}

update_timers() {  # $1=livre $2=agora $3=1 conta a leitura para o caminho "< 1,5 GB seguidas"
  local n s
  for n in 2 3 4; do
    s=$(getv SINCE "$n")
    if in_lv "$n" "$1"; then
      if [ "$s" -eq 0 ]; then setv SINCE "$n" "$2"; log "D$n: livre=${1}MB abaixo do limiar ($(lv_mb "$n")MB): cronômetro começa (agora $2)"; fi
    elif out_lv "$n" "$1"; then
      if [ "$s" -gt 0 ] || [ "$(getv ST "$n")" != none ]; then log "D$n: livre=${1}MB >= limiar+histerese ($(( $(lv_mb "$n") + HYST_MB ))MB): recuperou; cronômetro e marca do degrau zerados"; fi
      setv SINCE "$n" 0; setv ST "$n" none; setv AT "$n" 0
      [ "$n" = 4 ] && ESC4=0
    fi
  done
  if [ "${3:-0}" = 1 ]; then
    if [ "$1" -lt "$D4_HARD_MB" ]; then HARD_N=$((HARD_N + 1)); else HARD_N=0; fi
  elif [ "$1" -ge "$D4_HARD_MB" ]; then
    HARD_N=0
  fi
}

eligible() {  # $1=n $2=agora → rc 0 se o tempo do limiar do degrau passou (D4: ou as leituras seguidas abaixo do piso duro)
  local s; s=$(getv SINCE "$1")
  if [ "$s" -gt 0 ] && [ $(( $2 - s )) -ge "$(lv_hold "$1")" ]; then return 0; fi
  [ "$1" = 4 ] && [ "$HARD_N" -ge "$D4_HARD_N" ]
}

# ── estado salvo ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
state_reset() {
  STV=0; LAST_TS=0; LAST_FREE=0; LAST_SWAP=0; HARD_N=0; ACTED4_TS=0; ESC4=0; WARN_TS=0; WARN2_TS=0; HB_TS=0
  SINCE2=0; SINCE3=0; SINCE4=0; ST2=none; ST3=none; ST4=none; AT2=0; AT3=0; AT4=0
}

state_ok() {  # valida o que foi lido: a marca v=1 existe (arquivo que não é nosso/truncado não passa), todo campo numérico é número e todo estado é de um conjunto fechado → rc 0
  local v
  [ "$STV" = 1 ] || return 1
  for v in "$LAST_TS" "$LAST_FREE" "$LAST_SWAP" "$HARD_N" "$ACTED4_TS" "$ESC4" "$WARN_TS" "$WARN2_TS" "$HB_TS" "$SINCE2" "$SINCE3" "$SINCE4" "$AT2" "$AT3" "$AT4"; do
    isnum "$v" || return 1
  done
  for v in "$ST2" "$ST3" "$ST4"; do
    case "$v" in none|acted|idle|failed|unknown|absent) ;; *) return 1 ;; esac
  done
  return 0
}

load_state() {  # vazio (arquivo ausente) → 1ª rodada, estado zerado, sem aviso; falhou/ilegível/vazio-de-0-bytes/campo inválido → põe de lado (.corrupt-<hora>), AVISA, estado zerado: cronômetros recomeçam, nada dispara por histórico que não li
  local k v
  state_reset
  [ -e "$STATE" ] || { log "estado: primeira rodada (sem $STATE)"; return 0; }
  if [ -r "$STATE" ] && [ -s "$STATE" ]; then
    # `|| [ -n "$k" ]`: a última linha SEM \n final faz o read devolver 1 e o corpo do laço não rodar → o campo final seria ignorado em
    # silêncio e o arquivo passaria como válido (o save_state sempre termina com \n; isto cobre arquivo cortado ou editado à mão)
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in
        v) STV=$v ;; last_ts) LAST_TS=$v ;; last_free_mb) LAST_FREE=$v ;; last_swap_mb) LAST_SWAP=$v ;; hard_n) HARD_N=$v ;; acted4_ts) ACTED4_TS=$v ;; esc4) ESC4=$v ;;
        warn_ts) WARN_TS=$v ;; warn2_ts) WARN2_TS=$v ;; hb_ts) HB_TS=$v ;;
        since2) SINCE2=$v ;; since3) SINCE3=$v ;; since4) SINCE4=$v ;;
        st2) ST2=$v ;; st3) ST3=$v ;; st4) ST4=$v ;; at2) AT2=$v ;; at3) AT3=$v ;; at4) AT4=$v ;;
      esac
    done < "$STATE"
    state_ok && return 0
  fi
  state_reset
  note "WARN: estado salvo ilegível ou inválido ($STATE): ponho de lado e recomeço os cronômetros do zero (nada dispara por histórico que não li)"
  [ "$DRY" = 1 ] || mv -f "$STATE" "$STATE.corrupt-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  return 0
}

save_state() {  # grava inteiro num temporário e troca com mv. Falhou (disco cheio é o caso esperado) → AVISA e segue: o arquivo antigo continua íntegro, a rodada seguinte relê dele
  [ "$DRY" = 1 ] && return 0
  local tmp="$STATE.tmp.$$"
  {
    echo "v=1"
    echo "last_ts=$LAST_TS"; echo "last_free_mb=$LAST_FREE"; echo "last_swap_mb=$LAST_SWAP"; echo "hard_n=$HARD_N"
    echo "acted4_ts=$ACTED4_TS"; echo "esc4=$ESC4"; echo "warn_ts=$WARN_TS"; echo "warn2_ts=$WARN2_TS"; echo "hb_ts=$HB_TS"
    echo "since2=$SINCE2"; echo "since3=$SINCE3"; echo "since4=$SINCE4"
    echo "st2=$ST2"; echo "st3=$ST3"; echo "st4=$ST4"; echo "at2=$AT2"; echo "at3=$AT3"; echo "at4=$AT4"
  } 2>/dev/null > "$tmp" && mv -f "$tmp" "$STATE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    SAVE_FAIL=1
    note "WARN: não consegui gravar o estado ($STATE): disco cheio ou sem permissão; a escada fica cega para o TEMPO (cada rodada relê o arquivo antigo); saio com 30"
    return 1
  }
  SAVE_FAIL=0
}

# ── processos externos com limite de tempo ───────────────────────────────────────────────────────────────────────────────────────
run_bounded() {  # $1=segundos, resto=comando. Saída (stdout+stderr) em $RB_OUT. rc do comando; 124 = estourou o tempo (TERM, depois KILL); 125 = não consegui nem lançar
  local secs=$1 pid ticks=0 limit
  shift
  RB_OUT=$(mktemp "${TMPDIR:-/tmp}/disk-recovery.XXXXXX" 2>/dev/null) || { RB_OUT=""; return 125; }
  limit=$((secs * 5))
  "$@" > "$RB_OUT" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      # filhos diretos primeiro: depois que o pai morre eles passam a ser filhos do init e o `pkill -P` não os acha mais
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$pid"
}

out_line() {  # primeira linha de $RB_OUT, só caracteres imprimíveis, até 300. vazio/ilegível → "(sem saída)": a falta de linha não vira sucesso nem falha por si
  local l=""
  [ -n "$RB_OUT" ] && [ -r "$RB_OUT" ] && l=$(sed -n 1p "$RB_OUT" 2>/dev/null | LC_ALL=C tr -cd '[:print:]' | cut -c1-300)
  printf '%s' "${l:-(sem saída)}"
}
rb_clean() { [ -n "$RB_OUT" ] && rm -f "$RB_OUT" 2>/dev/null; RB_OUT=""; return 0; }

send_notify() {  # $1=prioridade $2=título $3=mensagem. Em dry-run só mostra. Falha do notify é dita no log e nunca derruba a rodada
  if [ "$DRY" = 1 ]; then log "(notify -p $1 '$2' — não enviado em dry-run) $3"; return 0; fi
  # O notify decide push-vs-resumo-horário pela REDAÇÃO da mensagem, não pelo -p (ga-ff6t9: um aviso de disco crítico real caiu no resumo mudo mesmo com -p 5). Prioridade >= 4 é "tem de
  # chegar no celular" (D3, D4, escalada, escada cega): NOTIFY_FORCE_PUSH=1 é a saída documentada do próprio notify. Prioridade 3 (D2 agiu) segue o roteamento normal.
  local rc
  if [ "$1" -ge 4 ]; then
    NOTIFY_FORCE_PUSH=1 run_bounded "$NOTIFY_TIMEOUT_S" "$NOTIFY" -p "$1" -t "$2" "$3"; rc=$?
  else
    run_bounded "$NOTIFY_TIMEOUT_S" "$NOTIFY" -p "$1" -t "$2" "$3"; rc=$?
  fi
  [ "$rc" -eq 0 ] || log "WARN: notify rc=$rc ($(out_line))"
  rb_clean
}
send_mail() {  # $1=assunto $2=corpo. Mesma regra: em dry-run só mostra; falha dita no log
  if [ "$DRY" = 1 ]; then log "(mail ao Mayor '$1' — não enviado em dry-run)"; return 0; fi
  run_bounded "$MAIL_TIMEOUT_S" "$GCBIN" mail send mayor -s "$1" -m "$2"
  local rc=$?
  [ "$rc" -eq 0 ] || log "WARN: gc mail send mayor rc=$rc ($(out_line))"
  rb_clean
}

# ── um degrau ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
run_rung() {  # $1=n $2=agora. rc 1 = degrau ausente (não gastou a rodada; o chamador tenta o próximo); rc 0 = chamou
  local n=$1 t0=$2 cmd mode rc cls line held t1 pre4 verb prio
  cmd=$(rung_cmd "$n")
  # existe e é executável? não existe/falhou/sem permissão → "ausente": loga, avisa uma vez por marca, PULA
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then
    if [ "$(getv ST "$n")" != absent ]; then
      setv ST "$n" absent; setv AT "$n" 0
      note "WARN: degrau D$n ausente ou sem permissão de execução ($cmd): o tempo do limiar dele passou (livre=${FREE}MB) e a escada não tem como agir nele; pulo para o próximo"
      send_notify 4 "Disco: degrau D$n ausente" "O tempo do degrau D$n passou (livre ${FREE} MB, swap ${SWAP} MB) mas $cmd não existe ou não executa. A escada não consegue agir nesse degrau."
    fi
    return 1
  fi
  mode=--run; [ "$DRY" = 1 ] && mode=--dry-run
  held=0; [ "$(getv SINCE "$n")" -gt 0 ] && held=$((t0 - $(getv SINCE "$n")))
  note "degrau D$n: chamando $cmd $mode (livre=${FREE}MB swap=${SWAP}MB; abaixo do limiar há ${held}s; leituras < ${D4_HARD_MB}MB seguidas=$HARD_N)"
  pre4=$ACTED4_TS
  if [ "$DRY" != 1 ]; then
    # grava a marca ANTES de chamar: o D4 pode reiniciar a máquina e matar este processo no meio; a marca tem de já estar no disco (se ele não agir, volta ao valor anterior)
    setv AT "$n" "$t0"; setv ST "$n" unknown
    [ "$n" = 4 ] && ACTED4_TS=$t0
    save_state
  fi
  run_bounded "$RUNG_TIMEOUT_S" "$cmd" "$mode"; rc=$?
  line=$(out_line); rb_clean
  case "$rc" in
    0)   cls=acted ;;
    10)  cls=idle ;;
    20)  cls=failed ;;
    30)  cls=unknown ;;
    124) cls=failed;  line="estourou ${RUNG_TIMEOUT_S}s e foi encerrado (TERM): $line" ;;
    125) cls=unknown; line="não consegui lançar o degrau (mktemp falhou?)" ;;
    *)   cls=failed;  line="rc inesperado $rc: $line" ;;
  esac
  if [ "$DRY" = 1 ]; then log "D$n --dry-run: rc=$rc ($cls): $line"; return 0; fi
  t1=$(now) || t1=$t0
  setv ST "$n" "$cls"; setv AT "$n" "$t1"
  if [ "$n" = 4 ]; then [ "$cls" = acted ] && ACTED4_TS=$t1 || ACTED4_TS=$pre4; fi
  # re-mede depois de cada degrau (um agiu → dá um respiro antes); ilegível → não mexe nos cronômetros e diz
  [ "$cls" = acted ] && [ "$SETTLE_S" -gt 0 ] && sleep "$SETTLE_S"
  local before=$FREE after="?" swap2="?" t2
  t2=$(now) || t2=$t1
  if measure; then
    after=$M_FREE; swap2=$M_SWAP; FREE=$M_FREE; SWAP=$M_SWAP
    update_timers "$M_FREE" "$t2" 0
    LAST_TS=$t2; LAST_FREE=$M_FREE; LAST_SWAP=$M_SWAP
  else
    log "WARN: re-medição depois do D$n falhou ($M_WHY): sigo sem mexer nos cronômetros"
  fi
  note "degrau D$n: rc=$rc ($cls) livre antes=${before}MB depois=${after}MB swap depois=${swap2}MB: $line"
  case "$cls" in
    acted|failed)
      case "$n" in 2) prio=3 ;; 3) prio=4 ;; *) prio=5 ;; esac
      if [ "$cls" = acted ]; then verb="agiu"; else verb="FALHOU"; [ "$prio" -lt 4 ] && prio=4; RC_FINAL=20; fi
      send_notify "$prio" "Disco: degrau D$n $verb" "D$n $verb: livre ${before} -> ${after} MB, swap ${swap2} MB. $line"
      send_mail "Disco: degrau D$n $verb (livre ${before} -> ${after} MB)" "Escada de recuperação de disco (ga-1p1i5jr.1).
Degrau: D$n ($cmd $mode) rc=$rc ($cls)
Saída do degrau: $line
Livre antes/depois: ${before} / ${after} MB   Swap depois: ${swap2} MB
Cronômetros (s abaixo do limiar): D2=$(held_of 2 "$t2") D3=$(held_of 3 "$t2") D4=$(held_of 4 "$t2")   leituras < ${D4_HARD_MB}MB seguidas: $HARD_N
Log: $LOG   Estado: $STATE   Desligar o maestro: touch $OFF" ;;
    unknown)
      if [ $(( t1 - WARN2_TS )) -ge "$WARN_EVERY_S" ]; then
        WARN2_TS=$t1
        send_notify 3 "Disco: degrau D$n não leu o estado" "D$n devolveu rc=$rc (não consegui ler o estado; não agiu): $line"
      fi ;;
  esac
  return 0
}

held_of() {  # $1=n $2=agora → segundos que o cronômetro do nível está rodando (0 = parado)
  local s; s=$(getv SINCE "$1")
  if [ "$s" -gt 0 ] && [ "$2" -ge "$s" ]; then printf '%s' $(( $2 - s )); else printf '0'; fi
}

escalate_d4_cap() {  # $1=agora. D4 já foi disparado há menos de 6 h e o disco segue < limiar: NÃO reinicia de novo; escala UMA vez por episódio
  [ "$ESC4" = 1 ] && return 0
  local age=$(( $1 - ACTED4_TS ))
  note "ESCALA: D4 elegível (livre=${FREE}MB) mas o último disparo dele foi há ${age}s (< ${D4_COOLDOWN_S}s): NÃO chamo de novo (sem reinício em laço)"
  [ "$DRY" = 1 ] || ESC4=1
  send_notify 5 "Disco: segue baixo depois do reinício, preciso de um humano" "Livre ${FREE} MB, swap ${SWAP} MB. O último disparo do D4 foi há $((age / 60)) min e o disco segue abaixo do limiar. Não reinicio de novo antes de $((D4_COOLDOWN_S / 3600)) h."
  send_mail "Disco: D4 já disparou há $((age / 60)) min e o disco segue baixo (livre ${FREE} MB)" "O maestro da escada de disco (ga-1p1i5jr.1) NÃO chama o D4 de novo dentro de ${D4_COOLDOWN_S}s do último disparo (laço de reinício). Livre agora: ${FREE} MB, swap ${SWAP} MB. Último disparo do D4: há ${age}s. Precisa de um humano: o que está comendo o disco depois do boot? Log: $LOG"
}

try_rung() {  # $1=n $2=agora. rc 0 = chamou o degrau (a rodada acabou); rc 1 = não chamou (ausente, ou D4 dentro do tempo de espera do reinício)
  if [ "$1" = 4 ] && [ "$ACTED4_TS" -gt 0 ] && [ $(( $2 - ACTED4_TS )) -lt "$D4_COOLDOWN_S" ]; then escalate_d4_cap "$2"; return 1; fi
  run_rung "$1" "$2"
}

pick_and_run() {  # $1=agora. UM degrau por rodada, só os que têm o cronômetro vencido.
  # Passada 1 — 1ª chamada do degrau neste episódio (estado none/absent), em ordem D2→D3→D4: nenhum degrau é pulado nem passa à frente do anterior. Degrau ausente devolve 1 e a passada segue para o próximo.
  # Passada 2 — repetição (acted: ACTED_REPEAT_S; idle/failed/unknown: RETRY_S), do MAIS ALTO para o mais baixo: se o D2 repetisse primeiro a cada 5 min, com o launchd atrasado (rodadas a 5 min uma da outra)
  #   ele ocuparia toda rodada e o D3/D4 nunca teriam vez. O degrau de cima só chega aqui depois de o tempo dele ter passado, e o de baixo já teve a chance dele antes.
  local n st at age
  for n in 2 3 4; do
    eligible "$n" "$1" || continue
    case "$(getv ST "$n")" in none|absent) ;; *) continue ;; esac
    try_rung "$n" "$1" && return 0
  done
  for n in 4 3 2; do
    eligible "$n" "$1" || continue
    st=$(getv ST "$n"); at=$(getv AT "$n"); age=$(( $1 - at ))
    case "$st" in
      acted) [ "$age" -ge "$ACTED_REPEAT_S" ] || continue ;;
      idle|failed|unknown) [ "$age" -ge "$RETRY_S" ] || continue ;;
      *) continue ;;
    esac
    try_rung "$n" "$1" && return 0
  done
  return 0
}

# ── trava de instância única ─────────────────────────────────────────────────────────────────────────────────────────────────────
acquire_lock() {  # rc 0 = peguei; rc 1 = outra instância viva. Trava velha (pid morto, ou vivo mas não é este script) é refeita. Sem pid ainda (mkdir feito, echo pendente) e dir novo (< 1 min) = ocupado
  local p tries=0
  while [ "$tries" -lt 2 ]; do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid" 2>/dev/null; LOCK_HELD=1; return 0; fi
    # vazio (sem pid) → ocupado se o dir é novo; falhou/ilegível → idem: na dúvida a outra instância é a dona
    p=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -z "$p" ]; then
      [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
    elif kill -0 "$p" 2>/dev/null && ps -p "$p" -o command= 2>/dev/null | grep -q 'disk-recovery-ladder'; then
      return 1
    fi
    rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
    tries=$((tries + 1))
  done
  return 1
}
release_lock() { if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; LOCK_HELD=0; fi; return 0; }

rotate_log() {  # log acima de LOG_MAX_KB vira .1 (um só backup). tamanho ilegível → não gira (log maior que o previsto é melhor que log perdido)
  local kb
  kb=$(du -k "$LOG" 2>/dev/null | awk '{print $1}')
  isnum "$kb" && [ "$kb" -gt "$LOG_MAX_KB" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
  return 0
}

# ── uma rodada ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in --run) DRY=0 ;; --dry-run) DRY=1 ;; *) usage ;; esac
  [ "$#" -eq 1 ] || usage
  if [ "$DRY" != 1 ]; then mkdir -p "$GCDIR" "$(dirname "$LOG")" 2>/dev/null; rotate_log; fi
  [ -z "$CFG_WARN" ] || note "WARN: variável de configuração inválida, usei o padrão:$CFG_WARN"

  # interruptor: existe → desligado. (test -e só tem dois resultados; arquivo que não consigo ver = como ausente, e o maestro segue ligado)
  if [ -e "$OFF" ]; then note "interruptor ligado ($OFF): não leio, não ajo"; exit 10; fi

  if [ "$DRY" != 1 ]; then
    acquire_lock || { log "outra instância em execução ($LOCK): saio"; exit 10; }
    trap release_lock EXIT
  fi

  NOW=$(now) || { note "WARN: relógio ilegível: não decido nada nesta rodada"; exit 30; }
  load_state

  if ! measure; then
    note "WARN: leitura impossível ($M_WHY): NÃO chamo degrau nenhum nesta rodada (não sei ≠ disco bom)"
    if [ $(( NOW - WARN_TS )) -ge "$WARN_EVERY_S" ]; then
      WARN_TS=$NOW
      send_notify 4 "Disco: a escada não consegue ler o disco" "Não consegui ler: $M_WHY. A escada de recuperação NÃO está agindo enquanto isso. (aviso no máximo 1 por hora)"
    fi
    save_state
    exit 30
  fi
  FREE=$M_FREE; SWAP=$M_SWAP

  # lacuna: tempo que ninguém observou não conta como "abaixo do limiar". Relógio que andou para trás idem.
  if [ "$LAST_TS" -gt 0 ] && { [ "$NOW" -lt "$LAST_TS" ] || [ $(( NOW - LAST_TS )) -gt "$GAP_S" ]; }; then
    log "lacuna: última leitura em $LAST_TS, agora $NOW (> ${GAP_S}s ou relógio para trás): cronômetros e marcas zerados (acted4_ts fica)"
    SINCE2=0; SINCE3=0; SINCE4=0; ST2=none; ST3=none; ST4=none; AT2=0; AT3=0; AT4=0; HARD_N=0; ESC4=0
  fi

  update_timers "$FREE" "$NOW" 1
  LAST_TS=$NOW; LAST_FREE=$FREE; LAST_SWAP=$SWAP

  if [ "$SINCE2" -gt 0 ] || [ "$SINCE3" -gt 0 ] || [ "$SINCE4" -gt 0 ] || [ "$FREE" -le $((D2_MB + HYST_MB)) ] || [ "$DRY" = 1 ]; then
    log "leitura: livre=${FREE}MB swap=${SWAP}MB | abaixo há: D2=$(held_of 2 "$NOW")s/${D2_HOLD_S}s D3=$(held_of 3 "$NOW")s/${D3_HOLD_S}s D4=$(held_of 4 "$NOW")s/${D4_HOLD_S}s | < ${D4_HARD_MB}MB seguidas=$HARD_N/${D4_HARD_N} | marcas D2=$ST2 D3=$ST3 D4=$ST4"
  elif [ $(( NOW - HB_TS )) -ge "$HEARTBEAT_S" ]; then
    HB_TS=$NOW
    log "ok: livre=${FREE}MB swap=${SWAP}MB (sem episódio; batimento 1/h)"
  fi

  save_state
  pick_and_run "$NOW"
  save_state
  [ "$SAVE_FAIL" = 1 ] && [ "$RC_FINAL" = 0 ] && RC_FINAL=30
  exit "$RC_FINAL"
}

main "$@"
