#!/bin/bash
# disk-recovery-d3-ram-daemons.sh (ga-1p1i5jr.3, P0) — degrau D3 da escada de recuperação de disco do mini: restart DRENADO dos daemons que mais usam RAM.
#
# ## Contents
#   Por que existe · O que faz · Guardas · Três estados · Contrato com o maestro · Variáveis (teste) · Teste
#
# POR QUE EXISTE  De ~05:00 a ~10:40 de 01/11 o disco do mini ficou entre 2 e 4 GB livres porque a memória virou swap, e os guardas só LIMPAVAM arquivo. Decisão do Athos (AskUserQuestion na
#   sessão do Mayor, 01/11 ~11:00 BRT, citada na ga-1p1i5jr): a escada age sozinha, a qualquer hora, com guardas. O maestro (disk-recovery-ladder.sh) chama este degrau quando o livre fica
#   <= 4 GB por 30 min; aqui o que se faz é devolver ao sistema a RAM dos daemons Python do WhatsApp que incham com o tempo, SEM derrubar ligação nem envio no meio.
# O QUE FAZ       Lê livre e swap. Se o livre já passou de D3_MB + HYST_MB (4608), não faz nada. Senão olha os 4 daemons da ALLOWLIST (só estes, nenhum outro label é tocado nunca):
#     demand-dashboard :8095 · map-viewer :8099 · ficha360 :8207 · clientes-dashboard :8104     (com.whatsapp.<nome>)
#   ordena os elegíveis pelo phys_footprint medido AGORA (`footprint -p`, não RSS: sob compressão o RSS esconde o crescimento), do maior para o menor (empate/ilegível = ordem da lista acima),
#   e reinicia UM de cada vez, do maior para o menor. Depois de cada um espera D3_SETTLE_S, re-mede disco e swap e PARA assim que o livre passa de D3_MB + HYST_MB (a mesma histerese do maestro).
#   · demand-dashboard: SÓ pelo scripts/restart_demand_dashboard_guarded.sh do whatsapp_automation (pausa a fila com system_paused_by, lê de volta, espera o worker drenar, reinicia, espera 200,
#     despausa). Este degrau não reimplementa nada disso. Depois dele, sempre confere a fila por conta própria: pausa que é nossa (system_paused_by "disk-recovery-d3:...") e ficou para trás
#     é despausada e LIDA DE VOLTA; pausa de outro dono nunca é tocada. O notify do guardado é desligado aqui (GUARDED_RESTART_NOTIFY_BIN): aviso de rc 0/20 é do maestro, não se duplica.
#   · os outros três: `launchctl kickstart -k gui/<uid>/<label>`.
#   · PROVA de que reiniciou: PID novo (diferente do anterior, vivo) E a porta respondendo HTTP 200..399. Sem os dois = falhou (20), e o degrau PARA (não empilha falha em cima de falha).
# GUARDAS         (todas ANTES de cada daemon; qualquer uma que não esteja "livre" = não reinicia aquele nem os seguintes)
#   · ligação em curso — as DUAS guardas vazias: pix_call_log (demand_assignments.db) sem linha 'dialing'/'bridged' e voicebot_call_log (voicebot_cost.db) sem linha 'live', ambas atualizadas
#     nos últimos D3_CALL_WINDOW_S (1800 s; linha mais velha que isso é órfã de crash, o próprio pix_call_queue as resgata). Lidas direto no sqlite, SOMENTE LEITURA: os `live_calls()` dos
#     módulos engolem erro e devolvem [] (= "sem ligação"), o que viraria "pode reiniciar" quando o banco não abre. Aqui banco que não abre NÃO é "sem ligação".
#   · congelamento — scripts/deploy_freeze.py check <label>: rc 0 congelado = pula; rc 10 livre; qualquer outro rc = não sei = pula (e conta como "não consegui ler").
#   · idade — processo com menos de D3_MIN_AGE_S (3600 s) não é reiniciado: alguém acabou de reiniciar (inclusive este degrau) e o footprint dele não diz nada. É o que impede reinício em laço
#     quando o maestro volta a chamar o D3 meia hora depois.
#   · tamanho — footprint abaixo de D3_MIN_MB (100 MB) não é reiniciado: não devolveria o suficiente para aparecer na re-medição e custaria uma queda de painel à toa.
#   · tempo — D3_BUDGET_S (600 s) no total, contados da largada. O maestro dá 900 s e depois manda TERM (KILL 2 s depois): nenhum daemon começa se o pior caso dele não cabe no que sobrou.
#   · instância única (mkdir) e o interruptor do maestro ($CITY/.gc/disk-recovery.off): ligado = sai 10 sem ler nem agir, também quando alguém chama este degrau à mão.
# TRÊS ESTADOS    tem / não-tem / não-consegui-saber. df, swap, launchctl, ps, footprint, deploy_freeze ou sqlite ilegíveis NUNCA viram "tem bastante disco", "sem ligação", "livre" ou "descongelado":
#   o degrau não age naquilo (e, se nada foi feito, sai 30). Depois de já ter agido, uma leitura que falha só PARA o degrau (não reinicia o seguinte às cegas).
#   A fila do demand-dashboard segue a mesma regra e a linha final NUNCA diz "nada a fazer"/"conferida" por cima de dúvida: sobra de pausa nossa que não consegui desfazer = 20; fila ilegível no
#   início = 30 se nada foi reiniciado (se algo foi, rc 0 e a linha avisa); no TERM a linha só diz "conferida" se a conferência deu certo, "NAO confirmada" se não, e nada se não havia pausa nossa em aberto.
# CONTRATO        `--run` (real) ou `--dry-run` (lê tudo, diz o que faria; não toma trava, não grava log, não reinicia, não despausa, sai 10, ou 30 se nao conseguiu ler). stdout = UMA linha (ASCII: o maestro filtra para
#   caracteres imprimíveis), e NADA antes dela em stdout/stderr (o maestro lê só a 1ª linha dos dois juntos): tudo o mais vai para $LOG.
#   Saída 0 = agiu e terminou · 10 = nada a fazer ou uma guarda adiou · 20 = falhou (reinício sem prova, despausa não confirmada, TERM) · 30 = não consegui ler o estado (não agiu) · 2 = uso.
#   Com falha e sucesso na mesma rodada vale 20 (a linha diz os dois). O maestro dá 900 s e manda TERM→KILL: o TERM despausa a fila rápido (a nossa) antes de sair; KILL não dá para pegar,
#   por isso o orçamento de tempo é bem menor que 900 s.
# VARIÁVEIS (teste) DR_CITY · DR_D3_LOG · DR_D3_LOCK · DR_OFF_FILE · DR_FREE_MB_FILE · DR_SWAP_MB_FILE (mesmos nomes do maestro) · DR_D3_WA (checkout do whatsapp_automation) · DR_D3_PIX_DB ·
#   DR_D3_VOICE_DB · DR_D3_GUARDED (restart guardado) · DR_D3_FREEZE_CMD (no lugar de `python3 scripts/deploy_freeze.py`) · DR_D3_DD_URL (base do demand-dashboard) ·
#   DR_<NOME> numérico: D3_MB HYST_MB D3_MIN_AGE_S D3_MIN_MB D3_CALL_WINDOW_S D3_BUDGET_S D3_DRAIN_S D3_READY_S D3_DESPAUSE_S D3_SETTLE_S D3_CURL_S D3_CMD_S D3_GUARD_SLACK_S D3_LOG_MAX_KB (lixo cai no padrão e é dito no log).
#   Os comandos do sistema (launchctl, ps, footprint, curl, df, sysctl) são achados pelo PATH, que aqui só ganha os diretórios padrão no FIM (o launchd entrega um PATH mínimo; sem jq/curl nada age).
# TESTE           bash scripts/disk-recovery-d3-ram-daemons.selftest.sh   (hermético: launchctl, curl, ps, footprint, df, swap, bancos, guardado e freeze simulados; nada real é reiniciado)
set -uo pipefail

PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export PATH
LC_ALL=C; export LC_ALL

D=$(cd "$(dirname "$0")" && pwd)
CITY="${DR_CITY:-${GC_CITY_PATH:-$(cd "$D/.." && pwd)}}"
GCDIR="$CITY/.gc"
LOG="${DR_D3_LOG:-$GCDIR/logs/disk-recovery-d3.log}"
LOCK="${DR_D3_LOCK:-$GCDIR/disk-recovery-d3.lock}"
OFF="${DR_OFF_FILE:-$GCDIR/disk-recovery.off}"
VOLUME="/System/Volumes/Data"
WA="${DR_D3_WA:-/Users/athos/gt/whatsapp_automation}"
PIX_DB="${DR_D3_PIX_DB:-$WA/shared/data/demand_assignments.db}"
VOICE_DB="${DR_D3_VOICE_DB:-$WA/shared/data/voicebot_cost.db}"
GUARDED="${DR_D3_GUARDED:-$WA/scripts/restart_demand_dashboard_guarded.sh}"
FREEZE_CMD="${DR_D3_FREEZE_CMD:-}"
FREEZE_PY="$WA/scripts/deploy_freeze.py"
DD_URL="${DR_D3_DD_URL:-http://127.0.0.1:8095}"
BEAD="ga-1p1i5jr.3"
AGENT="disk-recovery-d3"            # vira o prefixo do system_paused_by que o guardado grava: é assim que reconheço uma pausa NOSSA
NAMES="demand-dashboard map-viewer ficha360 clientes-dashboard"      # a ALLOWLIST, na ordem de desempate

DRY=""
CFG_WARN=""
RB_OUT=""
RB_PID=""
CAP=""
LOCK_HELD=0
FINISHED=0
PAUSE_ARMED=0
DD_CURL_S=""
DD_PAUSED=""
DD_BY=""
LEFT_TXT=""      # o que a conferencia da fila (sobra de pausa NOSSA) achou, para a linha final; vazio = nada a dizer
LEFT_RC=0        # 0 = fila conferida · 20 = sobra de pausa nossa NAO despausada · 30 = nao consegui ler a fila

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
cfg D3_MB 4096;           cfg HYST_MB 512
cfg D3_MIN_AGE_S 3600;    cfg D3_MIN_MB 100;       cfg D3_CALL_WINDOW_S 1800
cfg D3_BUDGET_S 600;      cfg D3_DRAIN_S 90;       cfg D3_READY_S 60
cfg D3_DESPAUSE_S 60;     cfg D3_SETTLE_S 10
cfg D3_CURL_S 5;          cfg D3_CMD_S 25;         cfg D3_LOG_MAX_KB 2048
cfg D3_GUARD_SLACK_S 45
RECOVERED_MB=$((D3_MB + HYST_MB))

usage() { echo "uso: $0 --run | --dry-run" >&2; exit 2; }
[ $# -eq 1 ] || usage
case "$1" in --run) DRY=0 ;; --dry-run) DRY=1 ;; *) usage ;; esac

# ── saída: UMA linha em stdout (fd 3) e mais nada ─────────────────────────────────────────────────────────────────────────────────
exec 3>&1
exec 1>/dev/null
if [ "$DRY" = 1 ]; then
  exec 2>/dev/null
else
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  if [ -f "$LOG" ] && [ "$(( $(wc -c < "$LOG" 2>/dev/null || echo 0) / 1024 ))" -ge "$D3_LOG_MAX_KB" ]; then mv -f "$LOG" "$LOG.1" 2>/dev/null; fi
  if ( : >> "$LOG" ) 2>/dev/null; then exec 2>>"$LOG"; else exec 2>/dev/null; fi
fi

log() { [ "$DRY" = 1 ] || printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
getv() { eval "printf '%s' \"\${$1:-}\""; }
setv() { eval "$1=\$2"; }
now_s() { date +%s; }
nth() { local k=0 x; for x in $NAMES; do k=$((k + 1)); [ "$k" = "$1" ] && { printf '%s' "$x"; return 0; }; done; return 1; }

release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; LOCK_HELD=0; fi
  return 0
}
finish() {  # $1=rc $2=linha. A ÚNICA saída do script: grava no log, imprime a linha (ASCII, até 290) no fd 3, solta a trava
  FINISHED=1
  local line
  line=$(printf '%s' "$2" | LC_ALL=C tr -cd '[:print:]' | cut -c1-290)
  log "FIM rc=$1: $2"
  printf '%s\n' "${line:-D3 sem mensagem}" >&3
  release_lock
  exit "$1"
}
on_exit() {  # rede de segurança: se o script morrer sem passar por finish (variável não definida, bug), ainda sai com UMA linha e rc 20
  local rc=$?
  if [ "$FINISHED" != 1 ]; then
    FINISHED=1
    log "ERRO: saída inesperada (rc=$rc) sem passar por finish"
    printf '%s\n' "D3 falhou: saida inesperada do degrau (rc=$rc), veja o log" >&3
    release_lock
    exit 20
  fi
}
trap on_exit EXIT

# ── processos externos com limite de tempo ───────────────────────────────────────────────────────────────────────────────────────
run_bounded() {  # $1=segundos, resto=comando. stdout+stderr em $RB_OUT. rc do comando; 124 = estourou o tempo (TERM, depois KILL); 125 = não consegui nem lançar
  local secs=$1 ticks=0 limit
  shift
  RB_OUT=$(mktemp "${TMPDIR:-/tmp}/disk-recovery-d3.XXXXXX" 2>/dev/null) || { RB_OUT=""; return 125; }
  limit=$((secs * 20))
  "$@" > "$RB_OUT" 2>&1 &
  RB_PID=$!
  while kill -0 "$RB_PID" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      pkill -TERM -P "$RB_PID" 2>/dev/null; kill -TERM "$RB_PID" 2>/dev/null
      sleep 2
      pkill -KILL -P "$RB_PID" 2>/dev/null; kill -KILL "$RB_PID" 2>/dev/null
      wait "$RB_PID" 2>/dev/null
      RB_PID=""
      return 124
    fi
    sleep 0.05; ticks=$((ticks + 1))
  done
  wait "$RB_PID"
  local rc=$?
  RB_PID=""
  return $rc
}
bcap() {  # $1=segundos, resto=comando → saída em $CAP (já apagado o arquivo), rc do comando
  local rc
  run_bounded "$@"; rc=$?
  CAP=""
  if [ -n "$RB_OUT" ]; then CAP=$(cat "$RB_OUT" 2>/dev/null); rm -f "$RB_OUT" 2>/dev/null; RB_OUT=""; fi
  return $rc
}

# ── leituras ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
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
    v=$(awk '{for (i = 1; i <= NF; i++) if ($i == "used") { x = $(i + 2); u = substr(x, length(x)); n = substr(x, 1, length(x) - 1)
          if (n ~ /^[0-9]+(\.[0-9]+)?$/ && (u == "M" || u == "G")) { if (u == "G") n = n * 1024; printf "%d", n; exit } } }' <<<"$out")
  fi
  isnum "$v" && [ "${#v}" -le 9 ] || return 1
  printf '%s' "$v"
}
measure() {  # lê livre e swap → M_FREE, M_SWAP; rc 0 só se OS DOIS foram lidos. M_WHY diz o que faltou
  M_FREE=""; M_SWAP=""; M_WHY=""
  M_FREE=$(read_free_mb) || { M_FREE=""; M_WHY="df do volume Data ilegivel"; }
  M_SWAP=$(read_swap_mb) || { M_SWAP=""; M_WHY="${M_WHY:+$M_WHY; }swap (vm.swapusage) ilegivel"; }
  [ -z "$M_WHY" ]
}

pid_of() {  # $1=label → PID em stdout. rc 0 = rodando; rc 2 = o launchd lista o label mas sem PID (parado) ou nem lista; rc 1 = não consegui ler o `launchctl list` (falhou, vazio ou sem o cabeçalho). Parado ≠ não sei
  local rc
  bcap "$D3_CMD_S" launchctl list; rc=$?
  [ "$rc" -eq 0 ] || return 1
  # here-string, nunca `printf | head`/`| awk ...exit`: com pipefail o consumidor que sai cedo faz o printf tomar SIGPIPE ("Broken pipe") e a leitura boa vira "ilegivel" (visto no selftest com a maquina carregada)
  local p first
  first=$(head -n 1 <<<"$CAP")
  case "$first" in PID*) ;; *) return 1 ;; esac
  p=$(awk -F'\t' -v l="$1" '$3 == l {print $1; exit}' <<<"$CAP")
  if isnum "$p"; then printf '%s' "$p"; return 0; fi
  return 2
}
age_of() {  # $1=pid → segundos de vida em stdout (`ps -o etime=`: [[dd-]hh:]mm:ss; o macOS não tem etimes). vazio/processo morto → rc 1; formato que não bate → rc 1. Morto ≠ idade 0
  isnum "$1" || return 1
  local rc v
  bcap "$D3_CMD_S" ps -o etime= -p "$1"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  v=$(printf '%s' "$CAP" | tr -d ' \n')
  awk '{ t = $0; d = 0
      if (t !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) exit 1
      if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, p, ":"); if (n == 3) s = p[1] * 3600 + p[2] * 60 + p[3]; else s = p[1] * 60 + p[2]
      printf "%d", d * 86400 + s }' <<<"$v"
}
fp_of() {  # $1=pid → phys_footprint em MB inteiros, em stdout. falhou/vazio/sem a linha phys_footprint/unidade desconhecida → rc 1 (não sei ≠ 0 MB: um processo "leve" por ilegível nunca é pulado como pequeno)
  isnum "$1" || return 1
  local rc v
  bcap "$D3_CMD_S" footprint -p "$1"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  v=$(awk '$1 == "phys_footprint:" { n = $2; gsub(",", ".", n); u = $3
      if (n !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
      if (u == "B") n = n / 1048576; else if (u == "KB") n = n / 1024; else if (u == "MB") n = n + 0; else if (u == "GB") n = n * 1024; else exit 1
      printf "%d", n; exit }' <<<"$CAP")
  isnum "$v" || return 1
  printf '%s' "$v"
}
freeze_check() {  # $1=label → rc 0 congelado · rc 10 livre · outro = não consegui olhar (inclui helper ausente, 124/125). Só 0 e 10 são respostas; o resto é "não sei"
  local rc
  if [ -n "$FREEZE_CMD" ]; then
    bcap "$D3_CMD_S" "$FREEZE_CMD" check "$1"; rc=$?
  else
    [ -f "$FREEZE_PY" ] || return 99
    bcap "$D3_CMD_S" python3 "$FREEZE_PY" check "$1"; rc=$?
  fi
  case "$rc" in 0) return 0 ;; 10) return 10 ;; *) return 99 ;; esac
}
http_code() {  # $1=url → código HTTP (3 dígitos) em stdout. falhou/sem resposta/ilegível → "000" (nunca 200 por engano)
  local c
  bcap $((D3_CURL_S + 3)) curl -s -o /dev/null -m "$D3_CURL_S" -w '%{http_code}' "$1" || { printf '000'; return 0; }
  c=$(printf '%s' "$CAP" | tail -n 1)
  case "$c" in [0-9][0-9][0-9]) printf '%s' "$c" ;; *) printf '000' ;; esac
}
http_ok() { case "$(http_code "$1")" in 2??|3??) return 0 ;; *) return 1 ;; esac; }

# ── guardas de ligação (sqlite SOMENTE LEITURA) ──────────────────────────────────────────────────────────────────────────────────
db_count() {  # $1=banco $2=SQL de contagem → inteiro em stdout. banco ausente/sem a tabela/travado/saída que não é um número só → rc 1 (não sei ≠ 0 ligações). Nunca cria nada
  [ -f "$1" ] || return 1
  local rc v
  bcap "$D3_CMD_S" sqlite3 -readonly -batch -cmd ".timeout 3000" "$1" "$2"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  v=$(printf '%s' "$CAP" | tr -d ' \n')
  isnum "$v" && [ "${#v}" -le 9 ] || return 1
  printf '%s' "$v"
}
guards_check() {  # preenche G_PIX e G_VOICE (contagem de ligações em curso ou "?"). rc 0 = as DUAS vazias (0 e 0) · rc 1 = alguma tem ligação em curso (mesmo que a outra seja ilegível) · rc 2 = nenhuma viva mas alguma ilegível
  G_PIX=$(db_count "$PIX_DB" "SELECT COUNT(*) FROM pix_call_log WHERE state IN ('dialing','bridged') AND COALESCE(updated_at, started_at) >= datetime('now','localtime','-$D3_CALL_WINDOW_S seconds');") || G_PIX="?"
  G_VOICE=$(db_count "$VOICE_DB" "SELECT COUNT(*) FROM voicebot_call_log WHERE status='live' AND COALESCE(updated_at, started_at) >= datetime('now','localtime','-$D3_CALL_WINDOW_S seconds');") || G_VOICE="?"
  { [ "$G_PIX" != "?" ] && [ "$G_PIX" -gt 0 ]; } && return 1
  { [ "$G_VOICE" != "?" ] && [ "$G_VOICE" -gt 0 ]; } && return 1
  { [ "$G_PIX" = "?" ] || [ "$G_VOICE" = "?" ]; } && return 2
  return 0
}

# ── fila do demand-dashboard ─────────────────────────────────────────────────────────────────────────────────────────────────────
dd_cs() { printf '%s' "${DD_CURL_S:-$D3_CURL_S}"; }
dd_get_config() {  # GET /api/outreach/config → DD_PAUSED ("0"/"1") e DD_BY. vazio/HTTP != 200/JSON ilegível/system_paused que não é 0 nem 1/sem jq → rc 1 (não sei ≠ "não pausada")
  local code body cs
  cs=$(dd_cs)
  DD_PAUSED=""; DD_BY=""
  command -v jq >/dev/null 2>&1 || return 1
  bcap $((cs + 3)) curl -s -m "$cs" -w '\n%{http_code}' "$DD_URL/api/outreach/config" || return 1
  code=$(printf '%s\n' "$CAP" | tail -n 1)
  [ "$code" = 200 ] || return 1
  body=$(printf '%s\n' "$CAP" | sed '$d')
  DD_PAUSED=$(printf '%s' "$body" | jq -r '.system_paused // ""' 2>/dev/null) || { DD_PAUSED=""; return 1; }
  case "$DD_PAUSED" in 0|1) ;; *) DD_PAUSED=""; return 1 ;; esac
  DD_BY=$(printf '%s' "$body" | jq -r '.system_paused_by // ""' 2>/dev/null) || DD_BY=""
  return 0
}
dd_unpause() {  # PATCH system_paused=0 com system_paused_by do degrau. rc 0 só com HTTP 200; o chamador LÊ DE VOLTA (o 200 sozinho não prova)
  local payload code cs
  cs=$(dd_cs)
  payload=$(jq -n --arg sp "0" --arg by "$AGENT: despausa de seguranca apos restart guardado $BEAD" '{system_paused: $sp, system_paused_by: $by}' 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1
  bcap $((cs + 3)) curl -s -m "$cs" -X PATCH -H 'Content-Type: application/json' -d "$payload" -w '\n%{http_code}' "$DD_URL/api/outreach/config" || return 1
  code=$(printf '%s\n' "$CAP" | tail -n 1)
  [ "$code" = 200 ]
}
ensure_despaused() {  # $1=segundos máx. Garante que a pausa NOSSA (system_paused_by "disk-recovery-d3:...") não ficou para trás. rc 0 = fila não está pausada por nós (já livre, pausa de outro dono, ou despausei e li de volta 0)
  # rc 1 = NÃO consegui confirmar (daemon fora do ar, PATCH recusado, leitura de volta ainda 1): pode haver pausa nossa. Pausa de outro dono nunca é tocada. Reler a cada volta: daemon que ainda está subindo é esperado
  local t0 t
  t0=$(now_s)
  while :; do
    if dd_get_config; then
      if [ "$DD_PAUSED" = 0 ]; then return 0; fi
      case "$DD_BY" in
        "$AGENT":*) dd_unpause && log "despausa enviada (pausa nossa: '$DD_BY'); relendo para confirmar" ;;
        *) log "fila pausada por outro dono ('$DD_BY'): nao mexo"; return 0 ;;
      esac
    fi
    t=$(( $(now_s) - t0 ))
    [ "$t" -lt "$1" ] || return 1
    sleep 1
  done
}

# ── sinais: o maestro manda TERM (e KILL 2 s depois) ao passar de 900 s ───────────────────────────────────────────────────────────
on_signal() {
  local qtxt=""
  log "WARN: recebi $1"
  if [ -n "$RB_PID" ]; then pkill -TERM -P "$RB_PID" 2>/dev/null; kill -TERM "$RB_PID" 2>/dev/null; fi
  # a linha final diz da fila SO o que foi de fato conferido: PAUSE_ARMED=0 → nao ha pausa nossa em aberto, qtxt fica vazio (a linha nao fala da fila, fora o que a conferencia do inicio ja achou em LEFT_TXT)
  # conferi (rc 0) → "conferida" · falhou/NAO consegui confirmar (rc 1) → "NAO confirmada", nunca "conferida" · a leitura de AGORA vale mais que a do inicio, entao LEFT_TXT sai da linha
  if [ "$PAUSE_ARMED" = 1 ]; then
    DD_CURL_S=1
    if ensure_despaused 2; then log "fila conferida/despausada na saida"; qtxt="; fila do demand-dashboard conferida (nao esta pausada por nos)"
    else log "ERRO: sai por $1 com a fila do demand-dashboard POSSIVELMENTE PAUSADA por nos"; qtxt="; fila do demand-dashboard NAO confirmada (se estiver pausada por nos, despausar a mao)"; fi
    LEFT_TXT=""
  fi
  # o estado da fila vem ANTES da lista do que ja reiniciei: e a parte que importa para quem le, e a lista (ate 3 daemons) e o que o corte de 290 pode comer
  finish 20 "D3 interrompido ($1)${LEFT_TXT:+; $LEFT_TXT}$qtxt${ACTED_TXT:+; depois de: $ACTED_TXT}"
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP

# ── um daemon: o que o scan decide ───────────────────────────────────────────────────────────────────────────────────────────────
SKIPS=""
UNK=0
skip() {  # $1=nome $2=motivo $3=1 se foi "não consegui ler"
  SKIPS="${SKIPS:+$SKIPS, }$1 ($2)"
  [ "${3:-0}" = 1 ] && UNK=1
  log "pulo $1: $2"
  return 0
}
scan_one() {  # $1=índice $2=nome. Define ELIG_i, PID_i, AGE_i, FP_i
  local i=$1 n=$2 l="com.whatsapp.$2" pid age fp rc
  setv "ELIG_$i" 0
  pid=$(pid_of "$l"); rc=$?
  case "$rc" in
    0) ;;
    2) skip "$n" "parado, sem PID" 0; return 0 ;;
    *) skip "$n" "launchctl ilegivel" 1; return 0 ;;
  esac
  setv "PID_$i" "$pid"
  freeze_check "$l"; rc=$?
  case "$rc" in
    10) ;;
    0) skip "$n" "congelado (deploy_freeze)" 0; return 0 ;;
    *) skip "$n" "deploy_freeze ilegivel" 1; return 0 ;;
  esac
  age=$(age_of "$pid") || { skip "$n" "idade do processo ilegivel" 1; return 0; }
  setv "AGE_$i" "$age"
  if [ "$age" -lt "$D3_MIN_AGE_S" ]; then skip "$n" "reiniciado ha $((age / 60)) min (<$((D3_MIN_AGE_S / 60)))" 0; return 0; fi
  fp=$(fp_of "$pid") || { skip "$n" "footprint ilegivel" 1; return 0; }
  setv "FP_$i" "$fp"
  if [ "$fp" -lt "$D3_MIN_MB" ]; then skip "$n" "${fp} MB < ${D3_MIN_MB} MB" 0; return 0; fi
  if [ "$n" = demand-dashboard ]; then
    { command -v jq >/dev/null 2>&1 && [ -x "$GUARDED" ]; } || { skip "$n" "sem jq ou sem o restart guardado" 1; return 0; }
  fi
  setv "ELIG_$i" 1
  return 0
}
port_of()   { case "$1" in demand-dashboard) printf 8095 ;; map-viewer) printf 8099 ;; ficha360) printf 8207 ;; clientes-dashboard) printf 8104 ;; *) return 1 ;; esac; }
health_of() { case "$1" in demand-dashboard) printf '%s' "$DD_URL/api/outreach/config" ;; *) printf 'http://127.0.0.1:%s/' "$(port_of "$1")" ;; esac; }

wait_new_pid() {  # $1=label $2=pid antigo $3=url → NEW_PID e rc 0 só com PID diferente, VIVO (ps responde) e a porta dando HTTP 2xx/3xx, dentro de D3_READY_S
  local t0 p
  t0=$(now_s); NEW_PID=""
  while :; do
    p=$(pid_of "$1") && [ "$p" != "$2" ] && age_of "$p" >/dev/null && http_ok "$3" && { NEW_PID=$p; return 0; }
    [ $(( $(now_s) - t0 )) -lt "$D3_READY_S" ] || return 1
    sleep 1
  done
}

RESTART_WHY=""
restart_plain() {  # $1=nome $2=pid antigo. rc 0 = PID novo + porta respondendo. Senão rc 1 e RESTART_WHY diz o que faltou
  local n=$1 old=$2 l="com.whatsapp.$1" rc
  bcap "$D3_CMD_S" launchctl kickstart -k "gui/$(id -u)/$l"; rc=$?
  if [ "$rc" -ne 0 ]; then RESTART_WHY="kickstart rc=$rc"; return 1; fi
  if ! wait_new_pid "$l" "$old" "$(health_of "$n")"; then RESTART_WHY="sem PID novo + porta $(port_of "$n") em ${D3_READY_S}s"; return 1; fi
  return 0
}
restart_guarded() {  # demand-dashboard. $1=pid antigo. Roda o guardado, CONFERE a fila sempre, e só então prova PID novo + porta
  local old=$1 rc verdict dp
  PAUSE_ARMED=1
  DD_CURL_S=""
  GUARDED_RESTART_DRAIN_TIMEOUT=$D3_DRAIN_S GUARDED_RESTART_READY_TIMEOUT=$D3_READY_S GUARDED_RESTART_NOTIFY_BIN=/nonexistent DEMAND_DASHBOARD_URL=$DD_URL \
    run_bounded $((D3_DRAIN_S + D3_READY_S + D3_GUARD_SLACK_S)) "$GUARDED" "$AGENT" "$BEAD"; rc=$?
  verdict=""
  if [ -n "$RB_OUT" ]; then verdict=$(grep 'VEREDITO' "$RB_OUT" 2>/dev/null | tail -n 1 | LC_ALL=C tr -cd '[:print:]' | cut -c1-160); rm -f "$RB_OUT" 2>/dev/null; RB_OUT=""; fi
  log "guardado rc=$rc ${verdict:+($verdict)}"
  if ensure_despaused "$D3_DESPAUSE_S"; then
    PAUSE_ARMED=0; dp="fila conferida (livre ou de outro dono)"
    # lida AGORA e nao e pausa nossa: a duvida da conferencia do inicio (sobra nao despausada / fila ilegivel) acabou; a linha final nao a repete
    if [ "$LEFT_RC" != 0 ]; then log "fila conferida agora: a duvida da conferencia inicial (rc $LEFT_RC) acabou"; LEFT_TXT=""; LEFT_RC=0; fi
  else dp="fila NAO confirmada (se estiver pausada por nos, despausar a mao)"; fi
  if [ "$rc" -ne 0 ]; then RESTART_WHY="guardado rc=$rc${verdict:+ [$verdict]}; $dp"; return 1; fi
  if [ "$PAUSE_ARMED" = 1 ]; then RESTART_WHY="$dp"; return 1; fi
  if ! wait_new_pid "com.whatsapp.demand-dashboard" "$old" "$(health_of demand-dashboard)"; then RESTART_WHY="sem PID novo + porta 8095 em ${D3_READY_S}s; $dp"; return 1; fi
  return 0
}
need_s() {  # pior caso, em segundos, para reiniciar $1 (cabe no que sobra do orçamento?)
  if [ "$1" = demand-dashboard ]; then printf '%s' $((D3_DRAIN_S + D3_READY_S + D3_GUARD_SLACK_S + D3_DESPAUSE_S + D3_READY_S + D3_SETTLE_S + 4 * D3_CMD_S))
  else printf '%s' $((D3_READY_S + D3_SETTLE_S + 4 * D3_CMD_S)); fi
}

# ── principal ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
T_START=$(now_s)
[ -z "$CFG_WARN" ] || log "WARN: variavel(is) invalida(s), usei o padrao:$CFG_WARN"
log "inicio ($([ "$DRY" = 1 ] && echo dry-run || echo run)) pid=$$ orcamento=${D3_BUDGET_S}s recuperado>${RECOVERED_MB}MB"

PFX=""; [ "$DRY" = 1 ] && PFX="DRY-RUN "
finish_q() {  # $1=rc natural $2=cabeça $3=resto. A ÚNICA saída depois da conferência da fila: o que a conferência achou (LEFT_TXT) entra LOGO NO COMEÇO da linha (o corte de 290 não o derruba) e sobe o rc
  # fila com sobra nossa NÃO despausada (LEFT_RC=20) → 20, nunca "nada a fazer" · fila ilegível (30) com NADA reiniciado (rc natural 10) → 30, não 10 · já agiu (rc 0) → continua 0 e a linha só avisa
  local rc=$1 head=$2 rest=$3
  if [ "$LEFT_RC" = 20 ] && [ "$rc" != 20 ]; then rest="$head: $rest"; head="falhou"; rc=20
  elif [ "$LEFT_RC" = 30 ] && [ "$rc" = 10 ]; then rest="$head: $rest"; head="nao consegui ler e nao agi"; rc=30; fi
  finish "$rc" "${PFX}D3 $head: ${LEFT_TXT:+$LEFT_TXT; }$rest"
}

if [ -e "$OFF" ]; then finish 10 "${PFX}D3 desligado: interruptor $(basename "$OFF") ligado, nada lido nem feito"; fi

if [ "$DRY" != 1 ]; then
  # instância única: mkdir é atômico. Trava de dono morto (pid que não existe mais) é tomada; dono vivo = sai 10
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    lp=$(cat "$LOCK/pid" 2>/dev/null)   # vazio → rc 0 sem número (trava sem dono gravado = tratada como morta); ilegível → igual
    if isnum "$lp" && kill -0 "$lp" 2>/dev/null; then finish 10 "D3 outra instancia rodando (pid $lp), nada feito"; fi
    log "trava de dono morto (pid '${lp:-?}'): tomando"
    rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || finish 30 "D3 nao consegui tomar a trava $LOCK, nada feito"
  fi
  LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
fi

measure || finish 30 "${PFX}D3 nao consegui ler: $M_WHY; nada feito"
FREE0=$M_FREE; SWAP0=$M_SWAP; FREE=$M_FREE; SWAP=$M_SWAP
log "leitura: livre=${FREE}MB swap=${SWAP}MB (recuperado = livre > ${RECOVERED_MB}MB)"

# pausa NOSSA que sobrou de uma rodada que o maestro matou (KILL não se pega): desfaz antes de qualquer coisa. Só em --run; pausa de outro dono nem é tocada
# vazio/lida e nao pausada → nada a dizer · pausa nossa despausada e lida de volta → LEFT_TXT conta, rc inalterado · pausa nossa que NAO consegui desfazer → LEFT_RC=20 (a fila segue parada)
# falhou/ilegível (daemon fora do ar, HTTP != 200, JSON ruim, sem jq) → LEFT_RC=30: não sei se há pausa nossa; a linha final NUNCA diz "nada a fazer" por cima disso (finish_q)
if [ "$DRY" != 1 ]; then
  if dd_get_config; then
    if [ "$DD_PAUSED" = 1 ]; then
      case "$DD_BY" in
        "$AGENT":*)
          log "WARN: achei a fila pausada por nos ('$DD_BY'), sobra de rodada anterior: despausando"
          DD_CURL_S=""; PAUSE_ARMED=1    # armado enquanto despauso: um TERM no meio ainda tenta de novo antes de sair
          if ensure_despaused "$D3_DESPAUSE_S"; then PAUSE_ARMED=0; LEFT_TXT="sobra de pausa nossa da rodada anterior: despausada e conferida"
          else log "ERRO: nao consegui despausar a sobra"; LEFT_TXT="fila do demand-dashboard NAO despausada (sobra de pausa nossa da rodada anterior; despausar a mao)"; LEFT_RC=20; fi ;;
      esac
    fi
  else
    log "WARN: nao consegui ler a fila do demand-dashboard no inicio: nao sei se ha pausa nossa"
    LEFT_TXT="fila do demand-dashboard ilegivel no inicio (nao sei se ha pausa nossa)"; LEFT_RC=30
  fi
fi

if [ "$FREE" -gt "$RECOVERED_MB" ]; then
  finish_q 10 "nada a fazer" "disco ja recuperado (livre ${FREE} MB > ${RECOVERED_MB} MB, swap ${SWAP} MB)"
fi

# scan: pid, freeze, idade, footprint de cada daemon da allowlist
i=0
for n in $NAMES; do i=$((i + 1)); scan_one "$i" "$n"; done
ORDER=$(i=0; for n in $NAMES; do i=$((i + 1)); [ "$(getv "ELIG_$i")" = 1 ] && echo "$(getv "FP_$i") $i"; done | sort -k1,1nr -k2,2n | awk '{print $2}')
if [ -z "$ORDER" ]; then
  if [ "$UNK" = 1 ]; then finish_q 30 "nao consegui ler" "algum daemon e nenhum outro e elegivel (livre ${FREE} MB): $SKIPS"; fi
  finish_q 10 "nada a fazer" "nenhum daemon elegivel (livre ${FREE} MB): $SKIPS"
fi
log "elegiveis por footprint (maior primeiro): $(for k in $ORDER; do printf '%s=%sMB ' "$(nth "$k")" "$(getv "FP_$k")"; done)"

ACTED_N=0; ACTED_TXT=""; FAIL_TXT=""; STOP_TXT=""; WOULD=""
for k in $ORDER; do
  n=$(nth "$k"); l="com.whatsapp.$n"; old=$(getv "PID_$k"); fp0=$(getv "FP_$k")

  if [ "$DRY" != 1 ]; then
    el=$(( $(now_s) - T_START )); need=$(need_s "$n")
    if [ $((el + need)) -gt "$D3_BUDGET_S" ]; then STOP_TXT="sem tempo para $n (${el}s gastos + ${need}s de pior caso > ${D3_BUDGET_S}s)"; break; fi
  fi

  # as DUAS guardas de ligação, imediatamente antes de CADA daemon
  guards_check; grc=$?
  if [ "$grc" -eq 1 ]; then STOP_TXT="ligacao em curso (pix=$G_PIX voicebot=$G_VOICE) antes de $n"; break; fi
  if [ "$grc" -eq 2 ]; then STOP_TXT="nao consegui ler a guarda de ligacao (pix=$G_PIX voicebot=$G_VOICE) antes de $n"; UNK=1; break; fi

  # o mundo mudou desde o scan? PID diferente = alguém acabou de reiniciar; freeze novo = respeita
  cur=$(pid_of "$l"); crc=$?
  if [ "$crc" -ne 0 ] || [ "$cur" != "$old" ]; then skip "$n" "PID mudou ou sumiu desde a leitura" $([ "$crc" -eq 1 ] && echo 1 || echo 0); continue; fi
  freeze_check "$l"; frc=$?
  if [ "$frc" -eq 0 ]; then skip "$n" "congelado agora (deploy_freeze)" 0; continue; fi
  if [ "$frc" -ne 10 ]; then skip "$n" "deploy_freeze ilegivel agora" 1; continue; fi

  if [ "$DRY" = 1 ]; then WOULD="${WOULD:+$WOULD, }$n ($fp0 MB)"; continue; fi

  log "reiniciando $n (pid $old, ${fp0}MB) livre=${FREE}MB"
  RESTART_WHY=""
  if [ "$n" = demand-dashboard ]; then restart_guarded "$old"; else restart_plain "$n" "$old"; fi
  rrc=$?
  if [ "$rrc" -ne 0 ]; then
    FAIL_TXT="$n: $RESTART_WHY"
    log "ERRO: $FAIL_TXT"
    break
  fi
  newpid=$NEW_PID
  ACTED_N=$((ACTED_N + 1))

  [ "$D3_SETTLE_S" -le 0 ] || sleep "$D3_SETTLE_S"
  fp1="?"; v=$(fp_of "$newpid") && fp1=$v
  ACTED_TXT="${ACTED_TXT:+$ACTED_TXT; }$n pid $old->$newpid ${fp0}->${fp1} MB porta $(port_of "$n") ok"
  log "reiniciado: $n pid $old->$newpid (${fp0}->${fp1}MB), porta $(port_of "$n") respondendo"

  if measure; then
    FREE=$M_FREE; SWAP=$M_SWAP
    log "re-medida: livre=${FREE}MB swap=${SWAP}MB"
    if [ "$FREE" -gt "$RECOVERED_MB" ]; then STOP_TXT="disco recuperado (livre ${FREE} MB > ${RECOVERED_MB} MB)"; break; fi
  else
    STOP_TXT="nao consegui re-medir ($M_WHY): paro por aqui"
    UNK=1; break
  fi
done

if [ "$DRY" = 1 ]; then
  if [ -n "$WOULD" ]; then finish 10 "DRY-RUN D3: faria reiniciar (maior primeiro): $WOULD; livre ${FREE} MB swap ${SWAP} MB${STOP_TXT:+; adiado: $STOP_TXT}${SKIPS:+; pulos: $SKIPS}; nada foi feito"; fi
  if [ "$UNK" = 1 ]; then finish 30 "DRY-RUN D3: nao consegui ler ${STOP_TXT:-algum daemon}${SKIPS:+; pulos: $SKIPS}; nada foi feito"; fi
  finish 10 "DRY-RUN D3: nada a fazer${STOP_TXT:+: $STOP_TXT}${SKIPS:+; pulos: $SKIPS}; nada foi feito"
fi

TAIL="livre ${FREE0}->${FREE} MB swap ${SWAP0}->${SWAP} MB"
if [ -n "$FAIL_TXT" ]; then
  finish_q 20 "falhou" "$FAIL_TXT${ACTED_TXT:+; antes disso reiniciei: $ACTED_TXT}; $TAIL"
fi
if [ "$ACTED_N" -gt 0 ]; then
  finish_q 0 "agiu" "reiniciei $ACTED_TXT; $TAIL${STOP_TXT:+; parei: $STOP_TXT}${SKIPS:+; pulos: $SKIPS}"
fi
if [ "$UNK" = 1 ]; then
  finish_q 30 "nao consegui ler e nao agi" "${STOP_TXT:-algum daemon}${SKIPS:+; pulos: $SKIPS}; $TAIL"
fi
finish_q 10 "adiado, nada reiniciado" "${STOP_TXT:-sem motivo registrado}${SKIPS:+; pulos: $SKIPS}; $TAIL"
