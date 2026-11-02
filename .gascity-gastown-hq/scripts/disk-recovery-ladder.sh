#!/bin/bash
# disk-recovery-ladder.sh (ga-1p1i5jr.1, P0) — orquestrador da escada de recuperação de disco do mini.
#
# POR QUE EXISTE  De ~05:00 a ~10:40 de 01/11 o disco do mini ficou entre 2 e 4 GB livres (memória virando swap) e as P0/P1 do WA pararam; os guardas que existiam só limpam arquivo e avisam.
#   Decisão do Athos (AskUserQuestion na sessão do Mayor, 01/11 ~11:00 BRT, citada na ga-1p1i5jr): a escada age sozinha até o reinício guardado do mini, a qualquer hora, com guardas.
#   Este script é só o MAESTRO: não apaga, não para e não reinicia nada; lê o disco, guarda há quanto tempo está baixo e chama UM degrau por vez (quem age são os scripts dos degraus .2/.3/.4).
# O QUE FAZ       A cada rodada (launchd, 120 s): lê o livre do volume Data e o swap; atualiza os cronômetros; se o tempo do limiar de um degrau passou e ele ainda não bastou, chama esse degrau
#   (`--run`), re-mede, escreve 1 linha de log e, se o degrau agiu ou falhou, notify + mail ao Mayor. D1 (limpeza de arquivo) é o dolt-disk-floor-guard, que já roda a cada 5 min: o maestro não o chama.
# LIMIARES        (MB livres em `df -Pm /System/Volumes/Data` — NUNCA `df /`, que lê o volume de sistema selado e mostra 71% com o Data em 98%)
#   D2  livre <= 5120 por >= 900 s (15 min)     parar jobs pesados reiniciáveis da allowlist
#   D3  livre <= 4096 por >= 1800 s (30 min)    restart drenado dos daemons que mais usam RAM
#   D4  livre <  3072 por >= 3600 s (60 min)    OU livre < 1536 em 2 leituras SEGUIDAS e separadas por >= 100 s (2 rodadas do launchd)   reinício guardado do mini
#   O 2º caminho do D4 é parte do limiar dele (decisão do Athos: "< 1,5 GB a qualquer momento"), não um atalho: D2 e D3 só entram depois do tempo deles. As 2 leituras seguidas são do
#   maestro (uma leitura isolada abaixo de 1,5 GB, p.ex. um go build que sobe e solta, não reinicia o mini); duas rodadas coladas (--run à mão ao lado de uma agendada) contam como UMA.
#   HISTERESE: o cronômetro de um nível só ZERA quando o livre volta a limiar + 512 MB; entre os dois ele nem começa nem zera (um disco oscilando em volta de 3 GB por 5 h não reinicia o
#   relógio de 60 min a cada subida de 100 MB). Só conta tempo de rodadas que EU li: lacuna > 10 min entre duas leituras (máquina parada, launchd fora, df ilegível) zera cronômetros e marcas.
# TRÊS ESTADOS    tem / não-tem / não-consegui-saber. df ilegível ou swap ilegível NUNCA viram "tem bastante disco" nem "disco baixo": o maestro NÃO chama degrau nenhum, loga, avisa
#   (notify -p 4, no máximo 1 por hora ENTREGUE — ver ENTREGA) e sai com 30; os cronômetros salvos ficam como estavam (se a falta de leitura passar de 10 min, a lacuna os zera na próxima leitura boa).
#   Relógio ilegível: idem, mas só log/stdout e saída 30 (sem hora não há como limitar o aviso a 1 por hora). Estado salvo ilegível, vazio, cortado (falta qualquer chave) ou inválido é guardado como
#   `.corrupt-<hora>` (link duro, feito ANTES de o novo estado tomar o lugar dele por rename: o arquivo de estado nunca fica sem existir, senão a rodada seguinte seria "primeira rodada"), dito no log, e a rodada
#   SEGUE com os cronômetros zerados (nada dispara por um histórico que não consegui ler) MAS com o `acted4_ts` = AGORA:
#   não sei se o D4 acabou de disparar, e o reinício é a ação que não se repete na dúvida; o teto de 6 h vale e, se o disco seguir baixo, escala (notify -p 5 + mail) em vez de reiniciar.
#   Só o arquivo AUSENTE é "primeira rodada" (acted4_ts=0); apagar o estado à mão é, de propósito, o jeito de zerar tudo, inclusive o teto de 6 h.
#   Estado que não consigo gravar: aviso no log, notify -p 4 (no máximo 1 por hora) e saída 30; e se a marca de ANTES da chamada de um degrau não puder ser gravada, o degrau NÃO é chamado (a rodada acaba, saída 30).
#   Aviso de degrau que FALHOU: no máximo 1 notify + 1 mail por hora por degrau (a falha repete a cada 5 min; cada mail é um bead + commit no Dolt de uma máquina que está sem disco); "agiu" avisa sempre.
# ENTREGA         Tentado ≠ entregue. Toda marca de "já avisei" (esc4 da escalada do teto de 6 h, ST=absent do degrau ausente, os carimbos de 1 h warn_ts/nt/ut do estado, o arquivo .nosave) só é gravada DEPOIS de algum canal
#   CONFIRMAR: notify de -p >= 4 sai com NOTIFY_FORCE_PUSH=1 e NOTIFY_STRICT_EXIT=1 (sem o STRICT o notify sai 0 em todo caminho que não empurrou; com ele 0 = push com 2xx, 10 = segurado até as 7h pelo silêncio 22h–7h e
#   gravado no history.db para o flush das 7h, 11 = dedup; 0, 10 e 11 contam como entregue, 12/13/14/1 não) e `gc mail send` com rc 0; -p 3 segue o roteamento normal (rc 0 = o roteador aceitou). Sem confirmação a marca
#   NÃO é gravada, o log diz "NÃO confirmado/NÃO entregue" e o aviso repete na rodada (ou na chamada do degrau) seguinte: o "preciso de um humano" não se perde porque o disco, o Dolt ou a rede falharam naquela tentativa.
#   Mesmo contrato do send_notify/send_mail do disk-recovery-d4-guarded-reboot.sh, exceto que o D4 só aceita rc 0 (o aviso dele precisa chegar ANTES de um reinício). Os carimbos de 1 h são por degrau e por classe (FALHOU, NÃO LEU:
#   o "agiu" não cala um FALHOU), e um carimbo do estado no FUTURO (relógio que andou para trás) não cala o aviso.
# ESTADO, LOG, INTERRUPTORES
#   estado  $CITY/.gc/disk-recovery.state (chave=valor, escrito inteiro e trocado com mv)   log  $CITY/.gc/logs/disk-recovery.log (gira em 5 MB)
#   `touch $CITY/.gc/disk-recovery.off` desliga o maestro (sai 10 sem ler nem agir; apague o arquivo para voltar). Instância única por trava (mkdir) — o `--dry-run` não toma a trava.
#   O swap entra como leitura obrigatória e como contexto da mensagem; os limiares são de disco (a causa de 01/11 foi memória virando swap, e swap ocupa o mesmo disco).
#   Reinício em laço: o `acted4_ts` é gravado ANTES de chamar o D4 (um reinício que mata este processo no meio não perde a marca; se a gravação falha, o D4 não é chamado) e o maestro não chama
#   `d4 --run` de novo por 6 h depois de um rc 0; nesse caso, com o disco ainda < 3 GB, escala (notify -p 5 + mail, UMA vez por episódio, entregue: ver ENTREGA) em vez de reiniciar. A marca também vale quando o estado salvo some pela metade (ver TRÊS ESTADOS: acted4_ts = agora).
#   Só se perde com o arquivo de estado AUSENTE (apagado à mão). O contrato pede que o D4 tenha cooldown próprio também (defesa em profundidade, ga-1p1i5jr.4); este maestro não depende disso.
# CONTRATO DOS DEGRAUS  scripts/disk-recovery-d2-heavy-jobs.sh · -d3-ram-daemons.sh · -d4-guarded-reboot.sh, chamados `<script> --run` (real) ou `--dry-run` (só diz o que faria);
#   stdout = UMA linha; saída 0 = agiu e terminou · 10 = nada a fazer ou guarda adiou · 20 = falhou · 30 = não consegui ler o estado (não age). Passou de 900 s = TERM e conta como 20.
#   Degrau ausente (ou sem permissão de execução): loga, avisa uma vez por episódio (notify -p 4; a cada rodada até o notify confirmar) e PULA para o próximo. 10/20/30 repetem em 5 min; 0 não repete esse degrau por 30 min.
#   Cada degrau só entra quando o cronômetro DELE passou; um degrau por rodada; a marca de um degrau some quando o cronômetro dele zera. Ordem: a 1ª chamada de cada degrau no episódio
#   vai em D2→D3→D4; as repetições vão do mais alto para o mais baixo (senão o D2 repetindo a cada 5 min ocuparia toda rodada atrasada e o D3/D4 nunca teriam vez).
# MODOS           --run (launchd) · --dry-run (lê o estado salvo, aplica a leitura de agora numa cópia, chama os degraus com --dry-run, não grava estado/log, não avisa, não manda mail).
#   Sai: 0 rodada feita · 10 interruptor ligado ou outra instância rodando · 20 um degrau falhou · 30 não consegui ler (não agiu) · 2 uso.
# VARIÁVEIS (teste) DR_CITY · DR_STATE · DR_LOG · DR_OFF_FILE · DR_LOCK · DR_FREE_MB_FILE / DR_SWAP_MB_FILE (arquivo com o livre / o swap em MB, no lugar de df / sysctl) · DR_NOW_FILE (epoch)
#   · DR_D2_CMD/DR_D3_CMD/DR_D4_CMD · DR_NOTIFY_BIN · DR_GC_BIN · DR_<NOME> numérico = os nomes da lista `cfg` abaixo (valor que não é número, ou que fica abaixo do mínimo da regra, cai no padrão e é dito no log).
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
ASIDE=""     # estado ruim a guardar (.corrupt-<hora>, link duro) antes de o novo tomar o lugar dele por rename
SEEN=" "     # chaves que o load_state viu no arquivo

cfg() {  # $1=nome $2=padrão [$3=mínimo, padrão 0] → define a variável $1 com DR_$1 (só dígitos, até 9, >= mínimo); vazio → padrão; lixo ou abaixo do mínimo → padrão E registra em CFG_WARN (limiar que não leio não vira "sem limite")
  # São botões de TESTE (o plist não define nenhum). O mínimo existe só onde 0 mudaria a natureza da regra: D4_HARD_N=0 deixaria o D4 elegível com o disco saudável; os outros zeros só desligam uma proteção que o operador pediu.
  local v
  eval "v=\${DR_$1:-}"
  case "$v" in
    '') v=$2 ;;
    *[!0-9]*) CFG_WARN="$CFG_WARN DR_$1='$v'->$2"; v=$2 ;;
    *) { [ "${#v}" -le 9 ] && [ "$v" -ge "${3:-0}" ]; } || { CFG_WARN="$CFG_WARN DR_$1='$v'->$2"; v=$2; } ;;
  esac
  eval "$1=\$v"
}
cfg D2_MB 5120;  cfg D2_HOLD_S 900
cfg D3_MB 4096;  cfg D3_HOLD_S 1800
cfg D4_MB 3072;  cfg D4_HOLD_S 3600
cfg D4_HARD_MB 1536; cfg D4_HARD_N 2 1; cfg D4_HARD_SPACE_S 100
cfg HYST_MB 512; cfg GAP_S 600; cfg RETRY_S 300; cfg ACTED_REPEAT_S 1800; cfg D4_COOLDOWN_S 21600
cfg RUNG_TIMEOUT_S 900; cfg SETTLE_S 15; cfg WARN_EVERY_S 3600; cfg HEARTBEAT_S 3600; cfg LOG_MAX_KB 5120
cfg NOTIFY_TIMEOUT_S 30; cfg MAIL_TIMEOUT_S 60

log()  { if [ "$DRY" = 1 ]; then printf '[dry-run] %s\n' "$*"; else printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; fi; }
note() { log "$*"; [ "$DRY" = 1 ] || printf '%s\n' "$*"; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
getv() { eval "printf '%s' \"\${$1$2}\""; }
setv() { eval "$1$2=\$3"; }
due() {  # $1=carimbo $2=agora $3=janela (s) → rc 0 se o aviso pode sair: nunca avisou (carimbo 0), a janela passou, ou o carimbo está no FUTURO (relógio que andou para trás não cala aviso). Só números já validados (state_ok)
  [ "$2" -lt "$1" ] || [ $(( $2 - $1 )) -ge "$3" ]
}

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
    # "seguidas" = rodadas separadas por >= D4_HARD_SPACE_S: duas rodadas coladas (--run à mão, launchd atrasado que alcança) são UMA leitura, não duas
    if [ "$1" -ge "$D4_HARD_MB" ]; then HARD_N=0; HARD_TS=0
    elif [ "$HARD_N" -eq 0 ]; then HARD_N=1; HARD_TS=$2
    elif [ $(( $2 - HARD_TS )) -ge "$D4_HARD_SPACE_S" ]; then HARD_N=$((HARD_N + 1)); HARD_TS=$2
    fi
  elif [ "$1" -ge "$D4_HARD_MB" ]; then
    HARD_N=0; HARD_TS=0
  fi
}

eligible() {  # $1=n $2=agora → rc 0 se o tempo do limiar do degrau passou (D4: ou as leituras seguidas abaixo do piso duro)
  local s; s=$(getv SINCE "$1")
  if [ "$s" -gt 0 ] && [ $(( $2 - s )) -ge "$(lv_hold "$1")" ]; then return 0; fi
  [ "$1" = 4 ] && [ "$HARD_N" -ge "$D4_HARD_N" ]
}

# ── estado salvo ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
state_reset() {
  STV=0; LAST_TS=0; LAST_FREE=0; LAST_SWAP=0; HARD_N=0; HARD_TS=0; ACTED4_TS=0; ESC4=0; WARN_TS=0; HB_TS=0
  SINCE2=0; SINCE3=0; SINCE4=0; ST2=none; ST3=none; ST4=none; AT2=0; AT3=0; AT4=0; NT2=0; NT3=0; NT4=0; UT2=0; UT3=0; UT4=0
}

state_ok() {  # valida o que foi lido: a marca v=1 existe, TODAS as chaves do save_state estão no arquivo (cortado numa fronteira de linha não passa: chave que falta virava 0 em silêncio, e acted4_ts=0 liga o reinício),
  # todo campo numérico é número e todo estado é de um conjunto fechado → rc 0. vazio (chave ausente) → rc 1; falhou/ilegível → rc 1
  local v
  [ "$STV" = 1 ] || return 1
  for v in v last_ts last_free_mb last_swap_mb hard_n hard_ts acted4_ts esc4 warn_ts hb_ts since2 since3 since4 st2 st3 st4 at2 at3 at4 nt2 nt3 nt4 ut2 ut3 ut4; do
    case "$SEEN" in *" $v "*) ;; *) return 1 ;; esac
  done
  for v in "$LAST_TS" "$LAST_FREE" "$LAST_SWAP" "$HARD_N" "$HARD_TS" "$ACTED4_TS" "$ESC4" "$WARN_TS" "$HB_TS" "$SINCE2" "$SINCE3" "$SINCE4" "$AT2" "$AT3" "$AT4" "$NT2" "$NT3" "$NT4" "$UT2" "$UT3" "$UT4"; do
    isnum "$v" || return 1
  done
  for v in "$ST2" "$ST3" "$ST4"; do
    case "$v" in none|acted|idle|failed|unknown|absent) ;; *) return 1 ;; esac
  done
  return 0
}

load_state() {  # vazio (arquivo ausente) → 1ª rodada, estado zerado, sem aviso, acted4_ts=0; falhou/ilegível/0 bytes/chave que falta/campo inválido → AVISA, estado zerado (cronômetros recomeçam: nada dispara por histórico que não li)
  # MAS acted4_ts=AGORA (não sei se o D4 acabou de disparar: o teto de 6 h vale) e o arquivo ruim é guardado como .corrupt-<hora> (ASIDE: link duro no save_state, antes de o novo estado tomar o lugar dele por rename). Precisa de $NOW.
  local k="" v=""   # inicializadas: um `read` que falha na 1ª linha (o estado é um diretório, erro de E/S) não atribui o k, e sob `set -u` o `[ -n "$k" ]` do laço mataria a rodada, toda rodada, sem aviso
  state_reset
  SEEN=" "
  [ -e "$STATE" ] || { log "estado: primeira rodada (sem $STATE)"; return 0; }
  if [ -r "$STATE" ] && [ -s "$STATE" ]; then
    # `|| [ -n "$k" ]`: a última linha SEM \n final faz o read devolver 1 e o corpo do laço não rodar → o campo final seria ignorado em
    # silêncio e o arquivo passaria como válido (o save_state sempre termina com \n; isto cobre arquivo cortado ou editado à mão)
    while IFS='=' read -r k v || [ -n "$k" ]; do
      SEEN="$SEEN$k "
      case "$k" in
        v) STV=$v ;; last_ts) LAST_TS=$v ;; last_free_mb) LAST_FREE=$v ;; last_swap_mb) LAST_SWAP=$v ;; hard_n) HARD_N=$v ;; hard_ts) HARD_TS=$v ;; acted4_ts) ACTED4_TS=$v ;; esc4) ESC4=$v ;;
        warn_ts) WARN_TS=$v ;; hb_ts) HB_TS=$v ;;
        since2) SINCE2=$v ;; since3) SINCE3=$v ;; since4) SINCE4=$v ;;
        st2) ST2=$v ;; st3) ST3=$v ;; st4) ST4=$v ;; at2) AT2=$v ;; at3) AT3=$v ;; at4) AT4=$v ;; nt2) NT2=$v ;; nt3) NT3=$v ;; nt4) NT4=$v ;;
        ut2) UT2=$v ;; ut3) UT3=$v ;; ut4) UT4=$v ;;
      esac
    done < "$STATE"
    state_ok && return 0
  fi
  state_reset
  ACTED4_TS=$NOW
  note "WARN: estado salvo ilegível, incompleto ou inválido ($STATE): ponho de lado e recomeço os cronômetros do zero (nada dispara por histórico que não li); acted4_ts passa a ser AGORA ($NOW): não sei se o D4 acabou de disparar, então o teto de 6 h vale"
  [ "$DRY" = 1 ] || ASIDE="$STATE.corrupt-$(date +%Y%m%d%H%M%S).$$"   # com o pid: o nome é único por rodada (keep_aside trata "já existe" como "foi esta rodada")
  return 0
}

keep_aside() {  # guarda o estado ruim como $ASIDE (.corrupt-<hora>) ANTES de o novo estado tomar o lugar dele: o STATE nunca fica sem existir (sem ele a próxima rodada seria "primeira rodada" = acted4_ts 0 = teto de 6 h perdido).
  # Link duro (não gasta bloco; o rename do novo estado deixa o inode velho vivo sob o nome do ASIDE); falhou → cópia; não é arquivo comum → mover; nada funcionou → só AVISA: a evidência se perde, o estado novo é gravado mesmo assim. Sempre rc 0
  [ -n "$ASIDE" ] || return 0
  [ -e "$ASIDE" ] && return 0   # já guardado por uma tentativa anterior desta rodada (o rename do novo estado falhou e o save_state foi repetido)
  ln "$STATE" "$ASIDE" 2>/dev/null && return 0
  cp -p "$STATE" "$ASIDE" 2>/dev/null && return 0
  # o que não é arquivo comum (um diretório, p.ex.) não tem link duro, cópia nem rename por cima (o mv do novo estado entraria DENTRO dele): só mover tira do caminho, e ele não guardava estado nenhum. Arquivo comum fica onde está: o rename o substitui
  if [ ! -f "$STATE" ] && mv -f "$STATE" "$ASIDE" 2>/dev/null; then return 0; fi
  log "WARN: não consegui guardar o estado ruim em $ASIDE: a evidência dele se perde (o estado novo é gravado mesmo assim)"
  return 0
}

save_state() {  # grava inteiro num temporário, guarda o ruim (keep_aside) e troca com mv. Falhou (disco cheio é o caso esperado) → AVISA e segue: o arquivo antigo continua íntegro, a rodada seguinte relê dele
  [ "$DRY" = 1 ] && return 0
  local tmp="$STATE.tmp.$$"
  {
    echo "v=1"
    echo "last_ts=$LAST_TS"; echo "last_free_mb=$LAST_FREE"; echo "last_swap_mb=$LAST_SWAP"; echo "hard_n=$HARD_N"
    echo "hard_ts=$HARD_TS"; echo "acted4_ts=$ACTED4_TS"; echo "esc4=$ESC4"; echo "warn_ts=$WARN_TS"; echo "hb_ts=$HB_TS"
    echo "since2=$SINCE2"; echo "since3=$SINCE3"; echo "since4=$SINCE4"
    echo "st2=$ST2"; echo "st3=$ST3"; echo "st4=$ST4"; echo "at2=$AT2"; echo "at3=$AT3"; echo "at4=$AT4"; echo "nt2=$NT2"; echo "nt3=$NT3"; echo "nt4=$NT4"
    echo "ut2=$UT2"; echo "ut3=$UT3"; echo "ut4=$UT4"
  } 2>/dev/null > "$tmp" && keep_aside && mv -f "$tmp" "$STATE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    SAVE_FAIL=1
    note "WARN: não consegui gravar o estado ($STATE): disco cheio ou sem permissão; a escada fica cega para o TEMPO (cada rodada relê o arquivo antigo); saio com 30"
    return 1
  }
  ASIDE=""
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

send_notify() {  # $1=prioridade $2=título $3=mensagem. rc 0 = ENTREGUE (ou garantido: ver abaixo); rc 1 = NÃO confirmado (rc≠0, prazo estourado, sem arquivo temporário): quem grava uma marca "já avisei" só o faz com rc 0. Em dry-run só mostra e devolve 0
  # vazio → n/a (o rc de um comando é sempre um número); falhou/ilegível → rc 1 + uma linha no log, nunca derruba a rodada
  if [ "$DRY" = 1 ]; then log "(notify -p $1 '$2' — não enviado em dry-run) $3"; return 0; fi
  # O notify decide push-vs-resumo-horário pela REDAÇÃO da mensagem, não pelo -p (ga-ff6t9: um aviso de disco crítico real caiu no resumo mudo mesmo com -p 5). Prioridade >= 4 é "tem de
  # chegar no celular" (D3, D4, escalada, escada cega): NOTIFY_FORCE_PUSH=1 é a saída documentada do próprio notify, e NOTIFY_STRICT_EXIT=1 faz o rc dizer a verdade (sem ele o notify sai 0 em todo caminho que
  # não empurrou). Com ele (scripts/notify, policy_exit): 0 = push com 2xx · 10 = segurado até as 7h (silêncio 22h–7h do Athos: a linha fica no history.db e o flush das 7h a empurra, então NÃO se perde) · 11 = dedup (um
  # push de mesmo título saiu há < 30 min) · 12 = resumo/teto, 13, 14 e 1 (transporte) = nada saiu. Aqui 0, 10 e 11 contam como entregue (o que importa à marca é "o aviso não vai sumir", como na daemon-unverified-sweep);
  # o D4 é mais estrito (só 0) porque o aviso dele precisa CHEGAR antes de um reinício. FORCE_PUSH não fura a madrugada: sem contar o 10, toda escalada noturna com o mail fora repetiria a cada rodada e encheria a fila de segurados.
  # Prioridade 3 (D2 agiu) segue o roteamento normal, sem STRICT: lá rc 0 = o roteador aceitou, resumo incluído.
  local rc ok=0
  if [ "$1" -ge 4 ]; then
    NOTIFY_STRICT_EXIT=1 NOTIFY_FORCE_PUSH=1 run_bounded "$NOTIFY_TIMEOUT_S" "$NOTIFY" -p "$1" -t "$2" "$3"; rc=$?
    case "$rc" in 10|11) ok=1; log "notify -p $1: rc=$rc ($(out_line)): segurado até as 7h ou dedup, conto como entregue" ;; esac
  else
    run_bounded "$NOTIFY_TIMEOUT_S" "$NOTIFY" -p "$1" -t "$2" "$3"; rc=$?
  fi
  [ "$rc" -eq 0 ] && ok=1
  [ "$ok" = 1 ] || log "WARN: notify NÃO confirmado rc=$rc ($(out_line))"
  rb_clean
  [ "$ok" = 1 ]
}
send_mail() {  # $1=assunto $2=corpo. Mesmo contrato do send_notify: rc 0 = entregue, rc 1 = NÃO confirmado; em dry-run só mostra e devolve 0
  if [ "$DRY" = 1 ]; then log "(mail ao Mayor '$1' — não enviado em dry-run)"; return 0; fi
  run_bounded "$MAIL_TIMEOUT_S" "$GCBIN" mail send mayor -s "$1" -m "$2"
  local rc=$?
  [ "$rc" -eq 0 ] || log "WARN: gc mail send mayor NÃO confirmado rc=$rc ($(out_line))"
  rb_clean
  [ "$rc" -eq 0 ]
}

# ── um degrau ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
run_rung() {  # $1=n $2=agora. rc 1 = degrau ausente (não gastou a rodada; o chamador tenta o próximo); rc 0 = chamou; rc 2 = NÃO chamei porque não consegui gravar a marca antes (a rodada acaba)
  local n=$1 t0=$2 cmd mode rc cls line held t1 pre4 verb prio preST preAT nt told
  cmd=$(rung_cmd "$n")
  # existe e é executável? não existe/falhou/sem permissão → "ausente": loga, avisa uma vez por marca, PULA
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then
    if [ "$(getv ST "$n")" != absent ]; then
      note "WARN: degrau D$n ausente ou sem permissão de execução ($cmd): o tempo do limiar dele passou (livre=${FREE}MB) e a escada não tem como agir nele; pulo para o próximo"
      # a marca `absent` é o "já avisei": só vale com o notify CONFIRMADO; sem entrega o estado fica como estava e a rodada seguinte avisa de novo
      if send_notify 4 "Disco: degrau D$n ausente" "O tempo do degrau D$n passou (livre ${FREE} MB, swap ${SWAP} MB) mas $cmd não existe ou não executa. A escada não consegue agir nesse degrau."; then
        setv ST "$n" absent; setv AT "$n" 0
      fi
    fi
    return 1
  fi
  mode=--run; [ "$DRY" = 1 ] && mode=--dry-run
  held=0; [ "$(getv SINCE "$n")" -gt 0 ] && held=$((t0 - $(getv SINCE "$n")))
  note "degrau D$n: chamando $cmd $mode (livre=${FREE}MB swap=${SWAP}MB; abaixo do limiar há ${held}s; leituras < ${D4_HARD_MB}MB seguidas=$HARD_N)"
  pre4=$ACTED4_TS
  if [ "$DRY" != 1 ]; then
    # grava a marca ANTES de chamar: o D4 pode reiniciar a máquina e matar este processo no meio; a marca tem de já estar no disco (se ele não agir, volta ao valor anterior)
    preST=$(getv ST "$n"); preAT=$(getv AT "$n")
    setv AT "$n" "$t0"; setv ST "$n" unknown
    [ "$n" = 4 ] && ACTED4_TS=$t0
    if ! save_state; then
      # não consegui gravar = não sei se a marca existe no disco. Sem ela um reinício (D4) ou uma falha repetiriam a chamada a cada rodada: o lado inerte é NÃO chamar. Desfaz a marca em memória
      setv ST "$n" "$preST"; setv AT "$n" "$preAT"; ACTED4_TS=$pre4
      [ "$RC_FINAL" = 0 ] && RC_FINAL=30
      note "WARN: degrau D$n NÃO chamado: não consegui gravar a marca antes da chamada ($STATE); a rodada acaba aqui"
      return 2
    fi
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
      # FALHOU repete a cada RETRY_S (5 min) enquanto o disco está baixo: 1 notify (push forçado) + 1 mail (= um bead e um commit no Dolt) por hora por degrau, o resto só no log. O carimbo (NT) é só do FALHOU
      # (o "agiu" não cala um FALHOU logo depois) e só é gravado depois que ALGUM canal confirmou a entrega: sem entrega a chamada seguinte do degrau avisa de novo. "agiu" avisa sempre (repete no máx. a cada 30 min)
      nt=$(getv NT "$n")
      if [ "$cls" = failed ] && ! due "$nt" "$t1" "$WARN_EVERY_S"; then
        log "D$n $verb de novo: o aviso e o mail dele saíram há $(( t1 - nt ))s (no máximo 1 por ${WARN_EVERY_S}s por degrau); só log"
      else
        told=0
        send_notify "$prio" "Disco: degrau D$n $verb" "D$n $verb: livre ${before} -> ${after} MB, swap ${swap2} MB. $line" && told=1
        send_mail "Disco: degrau D$n $verb (livre ${before} -> ${after} MB)" "Escada de recuperação de disco (ga-1p1i5jr.1).
Degrau: D$n ($cmd $mode) rc=$rc ($cls)
Saída do degrau: $line
Livre antes/depois: ${before} / ${after} MB   Swap depois: ${swap2} MB
Cronômetros (s abaixo do limiar): D2=$(held_of 2 "$t2") D3=$(held_of 3 "$t2") D4=$(held_of 4 "$t2")   leituras < ${D4_HARD_MB}MB seguidas: $HARD_N
Log: $LOG   Estado: $STATE   Desligar o maestro: touch $OFF" && told=1
        if [ "$told" = 1 ]; then
          [ "$cls" = failed ] && setv NT "$n" "$t1"
        elif [ "$cls" = failed ]; then
          log "WARN: aviso de D$n $verb NÃO entregue (notify e mail sem confirmação): carimbo de 1 h não gravado, a próxima chamada do degrau avisa de novo"
        else
          log "WARN: aviso de D$n $verb NÃO entregue (notify e mail sem confirmação)"
        fi
      fi ;;
    unknown)
      # um carimbo POR degrau (UT) e só depois da entrega: o aviso do D2 (-p 3, que pode cair no resumo mudo) não cala o do D4 (-p 4 forçado), e um aviso que ninguém recebeu repete na chamada seguinte
      if due "$(getv UT "$n")" "$t1" "$WARN_EVERY_S"; then
        # o D4 cego com o disco crítico é "escada cega" como o df ilegível: -p 4 forçado (a -p 3 pode cair no resumo mudo da hora)
        prio=3; [ "$n" = 4 ] && prio=4
        if send_notify "$prio" "Disco: degrau D$n não leu o estado" "D$n devolveu rc=$rc (não consegui ler o estado; não agiu): $line"; then setv UT "$n" "$t1"; fi
      fi ;;
  esac
  return 0
}

held_of() {  # $1=n $2=agora → segundos que o cronômetro do nível está rodando (0 = parado)
  local s; s=$(getv SINCE "$1")
  if [ "$s" -gt 0 ] && [ "$2" -ge "$s" ]; then printf '%s' $(( $2 - s )); else printf '0'; fi
}

escalate_d4_cap() {  # $1=agora. D4 já foi disparado há menos de 6 h e o disco segue < limiar: NÃO reinicia de novo; escala UMA vez por episódio, e "uma vez" só vale com a entrega CONFIRMADA por algum canal (notify -p 5 ou mail):
  # este é o único "preciso de um humano" da escada (o D4 está no teto). Nenhum canal confirmou → esc4 fica 0 e a rodada seguinte (2 min) tenta de novo, como o escalate_low_after_reboot do D4; disco cheio, Dolt caído e rede falhando são o cenário ESPERADO aqui.
  [ "$ESC4" = 1 ] && return 0
  local age=$(( $1 - ACTED4_TS )) told=0
  note "ESCALA: D4 elegível (livre=${FREE}MB) mas o último disparo dele (ou a perda do estado salvo, que conto como disparo) foi há ${age}s (< ${D4_COOLDOWN_S}s): NÃO chamo de novo (sem reinício em laço)"
  send_notify 5 "Disco: segue baixo depois do reinício, preciso de um humano" "Livre ${FREE} MB, swap ${SWAP} MB. O último disparo do D4 (ou a perda do estado salvo da escada) foi há $((age / 60)) min e o disco segue abaixo do limiar. Não reinicio de novo antes de $((D4_COOLDOWN_S / 3600)) h." && told=1
  send_mail "Disco: D4 já disparou há $((age / 60)) min e o disco segue baixo (livre ${FREE} MB)" "O maestro da escada de disco (ga-1p1i5jr.1) NÃO chama o D4 de novo dentro de ${D4_COOLDOWN_S}s do último disparo (laço de reinício). Livre agora: ${FREE} MB, swap ${SWAP} MB. Último disparo do D4 (ou perda do estado salvo): há ${age}s. Precisa de um humano: o que está comendo o disco depois do boot? Se o estado salvo se perdeu e o D4 NÃO chegou a disparar, apagar $STATE libera o D4 (zera o teto). Log: $LOG" && told=1
  [ "$DRY" = 1 ] && return 0
  if [ "$told" = 1 ]; then ESC4=1; else note "ERROR: escalada NÃO entregue (notify e mail sem confirmação): não marco esc4, repito na próxima rodada"; fi
}

try_rung() {  # $1=n $2=agora. rc 0 = chamou o degrau (a rodada acabou); rc 1 = não chamou e a rodada segue (ausente, ou D4 dentro do tempo de espera do reinício); rc 2 = não chamou porque a marca não pôde ser gravada (a rodada acaba)
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
    try_rung "$n" "$1"; [ $? -eq 1 ] || return 0   # 1 = não chamou e segue para o próximo; 0 (chamou) e 2 (marca não gravável) acabam a rodada
  done
  for n in 4 3 2; do
    eligible "$n" "$1" || continue
    st=$(getv ST "$n"); at=$(getv AT "$n"); age=$(( $1 - at ))
    case "$st" in
      acted) [ "$age" -ge "$ACTED_REPEAT_S" ] || continue ;;
      idle|failed|unknown) [ "$age" -ge "$RETRY_S" ] || continue ;;
      *) continue ;;
    esac
    try_rung "$n" "$1"; [ $? -eq 1 ] || return 0   # 1 = não chamou e segue para o próximo; 0 (chamou) e 2 (marca não gravável) acabam a rodada
  done
  return 0
}

# ── trava de instância única ─────────────────────────────────────────────────────────────────────────────────────────────────────
acquire_lock() {  # rc 0 = peguei; rc 1 = outra instância viva. Trava velha (pid morto, ou vivo mas não é este script) é refeita. Sem pid ainda (mkdir feito, echo pendente) e dir novo (< 1 min) = ocupado
  local p c tries=0
  while [ "$tries" -lt 2 ]; do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid" 2>/dev/null; LOCK_HELD=1; return 0; fi
    # vazio (sem pid) → ocupado se o dir é novo; falhou/ilegível → idem: na dúvida a outra instância é a dona
    p=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -z "$p" ]; then
      [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
    elif kill -0 "$p" 2>/dev/null; then
      # pid vivo: só é trava velha se o ps LEU outro comando (pid reaproveitado). vazio (ps sem saída) → dúvida → a outra instância é a dona; falhou/ilegível → idem
      c=$(ps -p "$p" -o command= 2>/dev/null)
      case "$c" in ''|*disk-recovery-ladder*) return 1 ;; esac
    fi
    rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
    tries=$((tries + 1))
  done
  return 1
}
release_lock() { if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; LOCK_HELD=0; fi; return 0; }

nosave_warn() {  # estado que não grava: a escada não guarda tempo e não chama degrau. Avisa -p 4 forçado, no máx. 1 por hora; a marca do aviso é um arquivo VAZIO em $GCDIR (tocar um que já existe não gasta bloco) e só é tocada com o notify CONFIRMADO
  local m="$GCDIR/disk-recovery.nosave"
  [ "$DRY" = 1 ] && return 0
  # vazio (sem marca) → avisa; falhou/ilegível (find sem resposta) → avisa: aqui o silêncio é o lado perigoso
  [ -z "$(find "$m" -maxdepth 0 -mmin -60 2>/dev/null)" ] || return 0
  if send_notify 4 "Disco: a escada não consegue gravar o estado" "Não consegui gravar $STATE. A escada de recuperação NÃO chama degrau nenhum enquanto isso (sem a marca no disco um reinício se repetiria). (aviso no máximo 1 por hora)"; then
    { : > "$m"; } 2>/dev/null
  fi
  return 0
}

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
    if due "$WARN_TS" "$NOW" "$WARN_EVERY_S"; then
      # o carimbo de 1 h só vale com o notify CONFIRMADO: sem entrega a rodada seguinte (2 min) avisa de novo
      send_notify 4 "Disco: a escada não consegue ler o disco" "Não consegui ler: $M_WHY. A escada de recuperação NÃO está agindo enquanto isso. (aviso no máximo 1 por hora)" && WARN_TS=$NOW
    fi
    save_state
    exit 30
  fi
  FREE=$M_FREE; SWAP=$M_SWAP

  # lacuna: tempo que ninguém observou não conta como "abaixo do limiar". Relógio que andou para trás idem.
  if [ "$LAST_TS" -gt 0 ] && { [ "$NOW" -lt "$LAST_TS" ] || [ $(( NOW - LAST_TS )) -gt "$GAP_S" ]; }; then
    log "lacuna: última leitura em $LAST_TS, agora $NOW (> ${GAP_S}s ou relógio para trás): cronômetros e marcas zerados (acted4_ts fica)"
    SINCE2=0; SINCE3=0; SINCE4=0; ST2=none; ST3=none; ST4=none; AT2=0; AT3=0; AT4=0; HARD_N=0; HARD_TS=0; ESC4=0
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
  if [ "$SAVE_FAIL" = 1 ]; then [ "$RC_FINAL" = 0 ] && RC_FINAL=30; nosave_warn; fi
  exit "$RC_FINAL"
}

main "$@"
