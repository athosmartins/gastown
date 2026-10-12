#!/usr/bin/env bash
# mbp-run.sh — roda testes dirigidos (pytest) ou um comando pesado (rea/jadx/...) no MacBook Pro.
#
# Contents
#   Por quê · Uso · Códigos de saída · Presença do Athos · Toggle · Como funciona · Segurança
#
# POR QUÊ (Athos 11/10): o mini vive com load 40-60 e swap alto; os MESMOS 231 testes de lot_groups levam
#   161 s no mini e 5,3 s no MBP. O MBP (16 GB, 12 CPUs) vira nó de capacidade, com chave de ligar/desligar.
#
# USO
#   mbp-run.sh [--repo wa|ps] [--dir <worktree>] -- <args do pytest>        # ex.: -- tests/test_x.py -q
#        (ps = checkout de código do property_scrapers em ~/.property-scrapers/runtime/main, não o rig-contêiner)
#   mbp-run.sh --exec [--push P]... [--pull REL:LOCAL]... [--env K=V]... [--keep] -- <comando> [args]
#        (REA/APK; o comando roda em ~/gt-remote/exec/<slot>; --push copia P para ./in/; --pull traz REL de volta;
#         o scratch é APAGADO ao fim (capturas de REA nunca ficam) salvo --keep. Para redirecionar saída use
#         `-- sh -c 'rea ... > out.json'`.)
#   mbp-run.sh --seed wa|ps          # (re)semeia a árvore-base e o site-packages do MBP (com checagem de hash)
#   mbp-run.sh --check               # imprime a saúde do MBP (preflight, com a presença do Athos e as tarefas em curso) e sai
#
# CÓDIGOS DE SAÍDA — qualquer 96..99 significa "rode local": quem chama NUNCA trata isso como falha de teste.
#   0..95  código do pytest/comando remoto (propagado)
#   99  offload desligado (falta $CITY/.gc/mbp-offload.on) OU pausado pelo Athos (arquivo $CITY/.gc/mbp-offload.pause no mini,
#       ou ~/gt-remote/PAUSE no MBP): ambos são "o dono mandou não usar", e quem chama roda local do mesmo jeito
#   98  MBP indisponível/sem saúde (ssh > 5 s, RAM disponível < 3 GB, pressão de memória acima de "normal", swap
#       CRESCENDO > 128 MB entre duas leituras com 2 s de intervalo (~3 s de relógio), swap usado >= 8 GB, algum desses sinais ilegível, bateria <= 40% sem
#       tomada, ou ssh caiu no meio da execução). Swap usado ALTO mas parado NÃO recusa (ga-9e2rjh): o macOS não
#       devolve swap depois de uma pressão. Cada recusa vai para o log com o motivo (campo "reason").
#   97  configuração (uso errado, árvore-base ausente no MBP -> rode --seed)
#   96  slots ocupados (o teto depende da presença do Athos: veja abaixo)
#
# PRESENÇA DO ATHOS (ga-77c1qg; decisão dele em 12/10: o MBP é o notebook de trabalho dele, o mini é o servidor)
#   O preflight lê, NO MBP e na mesma chamada ssh, se o Athos está lá (scripts/mbp-presence.sh: tela bloqueada, ou sem teclado/mouse
#   há >= 10 min e nenhum app segurando a tela acesa). Só evidência positiva de "fora" libera carga alta; leitura que falha = em uso.
#   LIVRE  teto de slots = o MENOR entre os núcleos do MBP (MBP_MAX_SLOTS troca esse número; núcleos ilegíveis = 3) e o que a RAM de
#          agora sustenta (1 + (RAM disponível - 3 GB) / MBP_SLOT_MEM_MB, 768 MB); `nice -n 10`.
#   EM USO só roda se o MBP estiver saudável pelos critérios abaixo, com 1 slot NO TOTAL (MBP_USE_SLOTS; um slot livre não basta se
#          outros números estão ocupados por uma rodada de quando ele estava fora), e tudo nosso em prioridade de fundo
#          (`taskpolicy -b` + `nice -n 19`: no Apple Silicon isso empurra o processo para os núcleos de eficiência).
#   Durante a execução um vigia no MBP reavalia a presença a cada MBP_WATCH_S (5 s): se o Athos voltou (ou pausou), a árvore de
#   processos da execução cai para prioridade de fundo na hora; nada novo começa. Nunca volta a subir (rebaixar é o lado seguro).
#   MBP_FORCE_PRESENCE=uso trata o MBP como "em uso" (só piora; não existe forçar "livre"). Cada linha do log traz `presence` e `demoted`.
#
# TOGGLE: scripts/mbp-offload.sh on|off|status (arquivo-bandeira; o botão do painel é a bead de painel).
# COMO FUNCIONA: preflight (1 ssh) -> slot (mkdir atômico em ~/gt-remote/slots/N, dono=host:pid:epoch, reaping de
#   dono morto/idade) -> espelho por slot (~/gt-remote/mirror/<repo>-N, clone APFS da base na 1ª vez) -> rsync do
#   worktree do chamador -> pytest no venv do MBP com nice -> stream -> libera o slot -> log jsonl.
# SEGURANÇA: só testes dirigidos (nunca a suíte inteira). Não envia .git, venv, shared/data, *.db. Nenhum segredo
#   viaja no comando; o MBP usa o mesmo `secret`/Bitwarden do mini quando a tarefa precisar (decisão do Athos).
set -o pipefail

CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
MBP_HOST=${MBP_HOST:-athos@athoss-macbook-pro.local}
FLAG="$CITY/.gc/mbp-offload.on"
PAUSEFILE="$CITY/.gc/mbp-offload.pause"
LOG="$CITY/.gc/logs/mbp-run.jsonl"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESENCE_LIB="$HERE/mbp-presence.sh"
MIN_AVAIL_MB=${MBP_MIN_AVAIL_MB:-3072}
MAX_SWAP_MB=${MBP_MAX_SWAP_MB:-8192}               # TETO absoluto do swap usado; sozinho não decide mais (era 5120, ga-9e2rjh)
MAX_SWAP_GROWTH_MB=${MBP_MAX_SWAP_GROWTH_MB:-128}  # swap que CRESCE mais que isto na janela abaixo = o MBP está trocando memória agora
SWAP_SAMPLE_S=${MBP_SWAP_SAMPLE_S:-2}
[ "$SWAP_SAMPLE_S" -ge 1 ] 2>/dev/null || SWAP_SAMPLE_S=2   # janela em segundos: precisa ser inteiro >= 1; outra coisa volta ao padrão
MAX_PRESSURE=${MBP_MAX_PRESSURE_LEVEL:-1}          # nível do kernel: 1 normal, 2 aviso, 4 crítico; acima disto recusa
MIN_BATT=${MBP_MIN_BATT:-40}
num_or() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }   # inteiro sem sinal, ou o padrão
MAX_SLOTS=$(num_or "${MBP_MAX_SLOTS:-}" "")        # teto em modo LIVRE; vazio = núcleos do MBP (3 se não der para ler)
[ -z "$MAX_SLOTS" ] || [ "$MAX_SLOTS" -ge 1 ] || MAX_SLOTS=""
FALLBACK_SLOTS=3
SLOT_MEM_MB=$(num_or "${MBP_SLOT_MEM_MB:-768}" 768)   # RAM que se reserva por execução ao calcular o teto do modo LIVRE
[ "$SLOT_MEM_MB" -ge 1 ] || SLOT_MEM_MB=768
USE_SLOTS=$(num_or "${MBP_USE_SLOTS:-1}" 1)        # teto TOTAL em modo EM USO
[ "$USE_SLOTS" -ge 1 ] || USE_SLOTS=1
AWAY_S=$(num_or "${MBP_AWAY_IDLE_S:-600}" 600)     # sem teclado/mouse por tanto tempo = "fora" (se a tela não estiver bloqueada)
[ "$AWAY_S" -ge 1 ] || AWAY_S=600
WATCH_S=$(num_or "${MBP_WATCH_S:-5}" 5)            # intervalo do vigia que rebaixa a prioridade quando o Athos volta
[ "$WATCH_S" -ge 1 ] || WATCH_S=5
SLOT_MAX_AGE=${MBP_SLOT_MAX_AGE_S:-14400}
RUN_TIMEOUT=${MBP_RUN_TIMEOUT_S:-3600}
SSH_BIN=${MBP_SSH:-ssh}
umask 077
mkdir -p "$HOME/.ssh/cm" 2>/dev/null && chmod 700 "$HOME/.ssh/cm" 2>/dev/null   # sockets do ssh ficam num dir privado, nunca em /tmp (mbp-sec 11/10)
RSYNC_BIN=${MBP_RSYNC:-rsync}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/%C -o ControlPersist=60"
ME="$(hostname -s 2>/dev/null || echo mini)"
OWNER="$ME:$$:$(date +%s)"

EXCLUDES=(--exclude .git --exclude venv --exclude .venv --exclude crew --exclude refinery --exclude .worktrees
  --exclude shared/data --exclude __pycache__ --exclude node_modules --exclude '*.db' --exclude '*.db-wal'
  --exclude '*.db-shm' --exclude .pytest_cache
  --exclude /.beads --exclude /.repo.git --exclude /.viewer-deploy-clone --exclude /.playwright-mcp --exclude /.gc
  --exclude /.claude --exclude /scratchpad --exclude /logs --exclude '/shared/logs*' --exclude '/shared/*backup*'
  --exclude '.env' --exclude '.env.*' --exclude '*.pem' --exclude '*.key' --exclude '*.p12' --exclude '*.pfx' --exclude '*.crt'
  --exclude 'id_rsa*' --exclude 'id_ed25519*' --exclude '*.kdbx' --exclude 'credentials*.json' --exclude 'client_secret*.json'
  --exclude 'cookies*.json' --exclude 'cookies*.txt' --exclude '*.session' --exclude 'auth/' --exclude 'auth-*/' --exclude 'auth_*/'
  --exclude 'auth.bak*/' --exclude '*.sqlite' --exclude '*.sqlite3')   # nomes de módulo (auth_gate.py, pdpj_token.py) continuam indo: só dir/arquivo de credencial fica

say() { printf 'mbp-run: %s\n' "$*" >&2; }
usage() { sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' >&2; }   # só o bloco de comentário do topo (o limite fixo 2,36 vazava código quando o cabeçalho mudava)

repo=""; dir="$PWD"; mode=pytest; seed_repo=""
pushes=(); pulls=(); envs=(); keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --dir) dir="${2:-}"; shift 2 ;;
    --exec) mode=exec; shift ;;
    --seed) mode=seed; seed_repo="${2:-}"; shift 2 ;;
    --check) mode=check; shift ;;
    --push) pushes+=("${2:-}"); shift 2 ;;
    --pull) pulls+=("${2:-}"); shift 2 ;;
    --env) envs+=("${2:-}"); shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

base_of() { case "$1" in wa) echo whatsapp_automation ;; ps) echo property_scrapers ;; esac; }
venv_of() { case "$1" in wa) echo venv ;; ps) echo venv-ps ;; esac; }
local_root_of() { case "$1" in wa) echo /Users/athos/gt/whatsapp_automation ;; ps) echo /Users/athos/.property-scrapers/runtime/main ;; esac; }
local_venv_of() { case "$1" in wa) echo /Users/athos/gt/whatsapp_automation/venv ;; ps) echo /Users/athos/.property-scrapers/runtime/main/venv ;; esac; }

rssh() { "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s; }
rssh_s() { "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s -- "$@"; }   # idem, com argumentos posicionais para o script

log_run() { # repo mode slot rc secs   (+ globais PRES e DEMOTED: o estado em que a execução largou e se foi rebaixada no meio)
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","repo":"%s","mode":"%s","slot":"%s","rc":%s,"secs":%s,"nargs":%s,"presence":"%s","demoted":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$(( $# - 5 ))" "${PRES:--}" "${DEMOTED:-0}" >> "$LOG" 2>/dev/null || true
}

# ---- leitura do preflight ---------------------------------------------------------------------------------------
PF=""; REFUSAL=""; REFUSAL_RC=98; PRES=""; PRES_WHY=""; NCPU=""; DEMOTED=0
isnum() { [ "$1" -ge 0 ] 2>/dev/null; }                 # inteiro sem sinal; vazio e texto NÃO são número
isint() { [ "$1" -eq "$1" ] 2>/dev/null; }              # inteiro com sinal (o delta do swap pode ser negativo)
pf_get() { printf '%s\n' "$PF" | sed -n "s/^$1=//p" | head -1; }
refuse() { REFUSAL="$1"; say "$2 — rode local"; }       # $1 = motivo para o log, $2 = mensagem; quem chama faz `return 98` (ou 99 se pausado)

# Uma recusa do preflight vira UMA linha no log, com o motivo e os números que a causaram: sem isso "recusa indevida" não se
# mede (antes só execuções que rodaram eram logadas). Só o caminho normal chama isto; --check e --seed não contam como recusa.
log_refusal() { # usa REFUSAL e PF
  local a s d p
  # campo vazio/ilegível → grava null (não 0): "não consegui ler" nunca se confunde com "li zero" no log
  a=$(pf_get avail_mb); s=$(pf_get swap_mb); d=$(pf_get swap_delta_mb); p=$(pf_get pressure)
  isnum "$a" || a=null; isnum "$s" || s=null; isint "$d" || d=null; isnum "$p" || p=null
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":%s,"secs":0,"nargs":0,"reason":"%s","avail_mb":%s,"swap_mb":%s,"swap_delta_mb":%s,"pressure":%s,"presence":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${REFUSAL_RC:-98}" "${REFUSAL:-desconhecido}" "$a" "$s" "$d" "$p" "${PRES:--}" >> "$LOG" 2>/dev/null \
    || say "AVISO: recusa '${REFUSAL:-desconhecido}' NÃO gravada em $LOG — a contagem de 72 h (mbp-offload.sh counts) não vai incluí-la"
}

# ---- script remoto: cabeçalho comum (marcador + parâmetros + biblioteca de presença) -------------------------------------
# $1 = nome do marcador (primeira linha: é por ele que o stub do selftest reconhece o script). A biblioteca mbp-presence.sh roda NO
# MBP; se não der para lê-la aqui, o MBP é tratado como "em uso" (presence= vazio) — nunca como livre — e o aviso sai no stderr.
remote_header() {
  local lib
  printf '# MBP:%s\n' "$1"
  printf 'PRESENCE_AWAY_S=%s\nPRESENCE_WATCH_S=%s\nPRESENCE_LIB_ONLY=1\n' "$AWAY_S" "$WATCH_S"
  [ "${MBP_FORCE_PRESENCE:-}" = uso ] && printf 'PRESENCE_FORCE_USO=1\n'
  lib=$(cat "$PRESENCE_LIB" 2>/dev/null)
  if [ -n "$lib" ]; then printf '%s\n' "$lib"
  else
    say "AVISO: biblioteca de presença $PRESENCE_LIB ilegível — o MBP conta como EM USO"
    printf '%s\n' 'presence_eval() { PR_MODE=uso; PR_WHY=ilegivel:biblioteca; PR_LOCKED=; PR_IDLE=; PR_HOLD=; if [ -e "$HOME/gt-remote/PAUSE" ]; then PR_PAUSED=1; else PR_PAUSED=0; fi; }' \
      'presence_probe() { presence_eval; echo "presence="; echo "presence_why=$PR_WHY"; echo "paused=$PR_PAUSED"; }'
  fi
}

# ---- preflight: UMA chamada ssh; imprime pares k=v -------------------------------------------------------------
#
# CRITÉRIO (ga-9e2rjh): RAM disponível (free+inactive+speculative) + pressão de memória do kernel + CRESCIMENTO do swap numa
# janela curta; o swap usado virou só um TETO absoluto. O macOS não devolve o swap depois de uma pressão: o MBP ocioso fica em
# ~5 GB "usados" (medido 11/10: 4,9-5,2 GB parado) e o limiar antigo de 5 GB recusou uma execução com 3,8 GB de RAM sobrando.
# Medido ocioso em 11/10: pressão nível 1, memory_pressure 54% livre, swap parado em 5105 MB. O compressor (5,3 GB, 32% da RAM
# mesmo ocioso) só é REPORTADO: com esse ruído de base ele não serve de porta.
#
# PRESENÇA (ga-77c1qg): a mesma chamada traz presence=livre|uso (+ presence_why), paused, ncpu e as tarefas em curso (task=...). A
# presença NÃO recusa por si: ela decide o TETO de slots e a prioridade (ver o cabeçalho). Só a pausa recusa (rc 99).
preflight_script() {
  remote_header PREFLIGHT
  cat <<'EOF'
SAMPLE_S=${1:-2}
[ "$SAMPLE_S" -ge 1 ] 2>/dev/null || SAMPLE_S=2
isnum() { [ "$1" -ge 0 ] 2>/dev/null; }
# swap usado em MB inteiros. vazio/formato inesperado ("used = <n>M|G" ausente) → imprime NADA; falhou → imprime NADA
swap_used() { sysctl -n vm.swapusage 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "used" && $(i+1) == "=") { v = $(i+2); u = substr(v, length(v)); sub(/[MG]$/, "", v); if ((u == "M" || u == "G") && v ~ /^[0-9]+(\.[0-9]+)?$/) { print int(u == "G" ? v * 1024 : v); exit } } }'; }
s1=$(swap_used)
# vm_stat vazio/falhou → page size e contadores vazios → avail_mb e compressed_mb saem vazios
vm=$(vm_stat 2>/dev/null)
ps=$(printf '%s\n' "$vm" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p' | head -1)
g() { printf '%s\n' "$vm" | awk -v k="$1" 'index($0, k) == 1 { gsub(/[^0-9]/, "", $NF); print $NF; exit }'; }
free=$(g "Pages free"); inact=$(g "Pages inactive"); spec=$(g "Pages speculative"); comp=$(g "Pages occupied by compressor")
if isnum "$ps" && isnum "$free" && isnum "$inact" && isnum "$spec"; then echo "avail_mb=$(( (free + inact + spec) * ps / 1048576 ))"; else echo "avail_mb="; fi
if isnum "$ps" && isnum "$comp"; then echo "compressed_mb=$(( comp * ps / 1048576 ))"; else echo "compressed_mb="; fi
# nível de pressão do kernel (1 normal, 2 aviso, 4 crítico). vazio/falhou/ilegível → pressure= vazio, NUNCA "1"
lvl=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
if isnum "$lvl"; then echo "pressure=$lvl"; else echo "pressure="; fi
# memory_pressure: só informativo (não decide). vazio/falhou/ilegível → campo vazio
mp=$(memory_pressure 2>/dev/null | sed -n 's/^System-wide memory free percentage: \([0-9][0-9]*\)%.*/\1/p' | head -1)
echo "mem_free_pct=$mp"
# fonte de energia: "AC Power" → ac, "Battery Power" → battery; pmset vazio/falhou/formato inesperado → power= VAZIO (nunca "battery")
b=$(pmset -g batt 2>/dev/null)
if printf '%s\n' "$b" | grep -q 'AC Power'; then echo "power=ac"; elif printf '%s\n' "$b" | grep -q 'Battery Power'; then echo "power=battery"; else echo "power="; fi
echo "batt=$(echo "$b" | grep -o '[0-9]*%' | head -1 | tr -d '%')"
echo "load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
# núcleos: vazio/ilegível/zero → ncpu= vazio (o lado local cai no teto de reserva, nunca num teto inventado)
nc=$(sysctl -n hw.ncpu 2>/dev/null)
if isnum "$nc" && [ "$nc" -ge 1 ]; then echo "ncpu=$nc"; else echo "ncpu="; fi
# presença do Athos + pausa (biblioteca mbp-presence.sh, colada acima)
presence_probe
# tarefas do Gas City em curso (uma linha por slot): task=<n>|<dono host:pid:epoch>|<info>|<mtime>. Só informativo.
for d in "$HOME"/gt-remote/slots/*/; do
  [ -d "$d" ] || continue
  tn=${d%/}; tn=${tn##*/}
  echo "task=$tn|$(cat "$d/owner" 2>/dev/null | tr -d ' |\n')|$(cat "$d/info" 2>/dev/null | tr '\n|' '  ' | cut -c1-160)|$(stat -f %m "$d" 2>/dev/null)"
done
# segunda leitura do swap, SAMPLE_S segundos depois da primeira. qualquer das duas ilegível → delta vazio (não 0)
sleep "$SAMPLE_S"
s2=$(swap_used)
echo "swap_mb=$s2"
if isnum "$s1" && isnum "$s2"; then echo "swap_delta_mb=$(( s2 - s1 ))"; else echo "swap_delta_mb="; fi
EOF
}

preflight() {
  local out rc avail swap delta pressure power batt
  REFUSAL=""; REFUSAL_RC=98
  # Script remoto: toda leitura que vazia, falha ou vem em formato inesperado deixa o campo VAZIO (nunca 0, nunca "normal");
  # o lado local lê campo vazio como "não consegui saber" e recusa (estado inerte). $1 = janela da amostra de swap, em segundos.
  out=$(preflight_script | rssh_s "$SWAP_SAMPLE_S" 2>/dev/null); rc=$?
  [ $rc -eq 0 ] && [ -n "$out" ] || { REFUSAL=inalcancavel; say "MBP inalcançável (ssh rc=$rc) — rode local"; return 98; }
  PF="$out"
  # Presença: valor ausente ou fora de {livre,uso} é "uso" (nunca "livre"); MBP_FORCE_PRESENCE=uso só piora.
  PRES=$(pf_get presence); PRES_WHY=$(pf_get presence_why); NCPU=$(pf_get ncpu)
  case "$PRES" in livre|uso) ;; *) PRES=uso; PRES_WHY=${PRES_WHY:-ilegivel:presenca} ;; esac
  [ "${MBP_FORCE_PRESENCE:-}" = uso ] && { PRES=uso; PRES_WHY=forcado; }
  # Pausa do Athos (arquivo no MBP): vem antes da saúde — é uma ordem dele, não uma medida. Só o literal 1 pausa (o teste do arquivo
  # é um [ -e ], que não tem terceiro estado).
  if [ "$(pf_get paused)" = 1 ]; then
    REFUSAL_RC=99; refuse pausado_mbp "MBP pausado pelo Athos ($(pf_get pause_info))"; return 99
  fi
  # Lado local: campo AUSENTE ou ilegível ≠ valor baixo. Os três estados (tem / não tem / não consegui saber) NUNCA caem no
  # mesmo resultado: ilegível recusa com motivo "ilegivel:<campo>" (distinto de ram/pressao/swap) para o log não mentir.
  avail=$(pf_get avail_mb); swap=$(pf_get swap_mb); delta=$(pf_get swap_delta_mb); pressure=$(pf_get pressure)
  power=$(pf_get power); batt=$(pf_get batt)
  isnum "$avail" || { refuse ilegivel:avail "RAM disponível do MBP ilegível"; return 98; }    # gate:ilegivel-avail
  [ "$avail" -ge "$MIN_AVAIL_MB" ] || { refuse ram "MBP sem RAM livre ($avail MB < $MIN_AVAIL_MB)"; return 98; }    # gate:ram
  case "$pressure" in 1|2|4) ;; *) refuse ilegivel:pressure "pressão de memória do MBP ilegível (nível '${pressure:-}')"; return 98 ;; esac    # gate:ilegivel-pressao
  [ "$pressure" -le "$MAX_PRESSURE" ] || { refuse pressao "MBP sob pressão de memória (nível $pressure > $MAX_PRESSURE; 1=normal 2=aviso 4=crítico)"; return 98; }    # gate:pressao
  isint "$delta" || { refuse ilegivel:swap_delta "crescimento do swap do MBP ilegível"; return 98; }    # gate:ilegivel-delta
  [ "$delta" -le "$MAX_SWAP_GROWTH_MB" ] || { refuse swap_cresce "MBP trocando memória agora (swap cresceu $delta MB em ${SWAP_SAMPLE_S}s > $MAX_SWAP_GROWTH_MB)"; return 98; }    # gate:cresce
  isnum "$swap" || { refuse ilegivel:swap "swap usado do MBP ilegível"; return 98; }    # gate:ilegivel-swap
  [ "$swap" -lt "$MAX_SWAP_MB" ] || { refuse swap_teto "MBP com swap acima do teto ($swap MB >= $MAX_SWAP_MB)"; return 98; }    # gate:teto
  # fonte de energia ilegível recusa com motivo próprio (antes caía em "battery" e virava recusa por bateria baixa no log)
  case "$power" in ac|battery) ;; *) refuse ilegivel:power "fonte de energia do MBP ilegível ('${power:-}')"; return 98 ;; esac    # gate:ilegivel-power
  if [ "$power" = battery ]; then
    isnum "$batt" || { refuse ilegivel:batt "carga da bateria do MBP ilegível"; return 98; }    # gate:ilegivel-batt
    [ "$batt" -gt "$MIN_BATT" ] || { refuse bateria "MBP na bateria ($batt% <= $MIN_BATT%)"; return 98; }
  fi
  return 0
}

# Teto de slots para o modo de agora.
#   LIVRE   = o MENOR entre (núcleos do MBP, ou MBP_MAX_SLOTS; 3 se os núcleos não foram legíveis) e o que a RAM de AGORA sustenta:
#             1 + (RAM disponível - mínimo) / SLOT_MEM_MB. Medido ocioso em 12/10: ~4,3 GB disponíveis num MBP de 16 GB, então "um slot
#             por núcleo" sozinho deixaria 12 execuções passarem juntas pela checagem de RAM (cada uma lê o mesmo número antes de
#             alguma ocupar memória) e levaria o notebook ao swap justo quando o Athos voltasse. A RAM disponível já desconta as
#             execuções em curso, então o teto encolhe sozinho conforme a carga cresce.
#   EM USO  = USE_SLOTS (1).
slot_cap() {
  local cpu mem avail
  if [ "$PRES" = livre ]; then
    if [ -n "$MAX_SLOTS" ]; then cpu=$MAX_SLOTS
    elif isnum "$NCPU" && [ "$NCPU" -ge 1 ]; then cpu=$NCPU
    else cpu=$FALLBACK_SLOTS; fi
    avail=$(pf_get avail_mb)
    if isnum "$avail"; then
      mem=$(( 1 + (avail - MIN_AVAIL_MB) / SLOT_MEM_MB )); [ "$mem" -ge 1 ] || mem=1
      [ "$mem" -ge "$cpu" ] || cpu=$mem
    fi
    echo "$cpu"
  else echo "$USE_SLOTS"; fi
}

# ---- execução supervisionada no MBP -----------------------------------------------------------------------------------
# O trabalho roda em segundo plano dentro de uma função `job`; ao lado roda um vigia que reavalia a presença a cada WATCH_S. Se o
# Athos voltou (ou pausou), a ÁRVORE de processos do trabalho cai para prioridade de fundo (renice 19 + taskpolicy -b) — e nunca
# volta a subir. O aviso vai por arquivo (o vigia roda sem stdout): um filho do vigia segurando o canal do ssh atrasaria o fim da
# execução. stdin do trabalho e do vigia é /dev/null: o script chega pelo stdin do `bash -s`, e um filho que o lesse comeria linhas dele.
remote_supervisor() {
  cat <<'EOF'
MBP_BG=""; MBP_NICE=10
mbp_tree() { ps -A -o pid=,ppid= 2>/dev/null | awk -v r="$1" '{ pp[$1] = $2 } END { out[r] = 1; ch = 1; while (ch) { ch = 0; for (p in pp) if (!(p in out) && (pp[p] in out)) { out[p] = 1; ch = 1 } } for (p in out) print p }'; }
mbp_kill_tree() { local t; t=$(mbp_tree "$1"); [ -z "$t" ] || kill $t 2>/dev/null; return 0; }
mbp_demote() {
  local p
  for p in $(mbp_tree "$1"); do
    renice -n 19 -p "$p" >/dev/null 2>&1
    command -v taskpolicy >/dev/null 2>&1 && taskpolicy -b -p "$p" >/dev/null 2>&1
  done
  return 0
}
mbp_calm() { [ "$PR_MODE" = livre ] && [ "$PR_PAUSED" = 0 ]; }
mbp_watch() {
  local job=$1 why
  while kill -0 "$job" 2>/dev/null; do
    sleep "${PRESENCE_WATCH_S:-5}"
    kill -0 "$job" 2>/dev/null || break
    presence_eval
    if ! mbp_calm; then
      # só é "rebaixada no meio" a execução que LARGOU calma; quem largou em uso já nasceu em fundo (o rebaixamento só garante os filhos novos).
      # O aviso é gravado ANTES de rebaixar: se o trabalho terminar logo depois de rebaixado, o aviso já existe quando o pai o procura.
      if [ "$MBP_STARTED_CALM" = 1 ]; then
        why="o Athos voltou ao MBP ($PR_WHY)"; [ "$PR_PAUSED" = 1 ] && why="o Athos pausou o Gas City"
        echo "$why" > "$MBP_DEMOTED" 2>/dev/null
      fi
      mbp_demote "$job"
    fi
  done
}
mbp_supervise() {
  MBP_DEMOTED="${TMPDIR:-/tmp}/gascity-demoted.$$"; rm -f "$MBP_DEMOTED"
  presence_eval
  MBP_STARTED_CALM=1
  if ! mbp_calm; then MBP_STARTED_CALM=0; MBP_NICE=19; command -v taskpolicy >/dev/null 2>&1 && MBP_BG="taskpolicy -b"; fi
  "$@" </dev/null &
  MBP_JOB=$!
  mbp_watch "$MBP_JOB" >/dev/null 2>&1 </dev/null &
  MBP_WATCHER=$!
  trap 'mbp_kill_tree "$MBP_JOB"; mbp_kill_tree "$MBP_WATCHER"; rm -f "$MBP_DEMOTED"; exit 143' HUP TERM INT
  wait "$MBP_JOB"; MBP_RC=$?
  mbp_kill_tree "$MBP_WATCHER"
  if [ -s "$MBP_DEMOTED" ]; then echo "[mbp-run:demoted] $(cat "$MBP_DEMOTED"): os processos desta execução foram para prioridade de fundo"; fi
  rm -f "$MBP_DEMOTED"
  exit "$MBP_RC"
}
EOF
}

# $1 = marcador (RUN|EXEC), $2 = texto que define `job` e chama `mbp_supervise job`. Deixa o rc do ssh em RC e a saída em $TMPOUT.
run_remote() {
  local script
  script=$(remote_header "$1"; remote_supervisor; printf '%s\n' "$2")
  timeout "$RUN_TIMEOUT" "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s 2>&1 <<<"$script" | tee "$TMPOUT"
  RC=${PIPESTATUS[0]}
  DEMOTED=0; grep -q '^\[mbp-run:demoted\]' "$TMPOUT" 2>/dev/null && DEMOTED=1
  return 0
}

# ---- slots ------------------------------------------------------------------------------------------------------
# Teto por modo (slot_cap). O teto vale para o TOTAL de slots ocupados, não só para os números 1..teto: depois de uma rodada de quando
# o Athos estava fora (slots 1..9 ocupados), a chegada de uma execução com ele de volta (teto 1) não pode pegar um número baixo livre
# e somar-se a elas. Por isso, depois do mkdir (atômico) conta-se o total; se passou do teto, devolve-se o slot e responde-se FULL.
SLOT=""
SLOT_INFO=""
# o que aparece no status ("repo mode what presence"): só nomes de arquivo de teste / o nome do comando, saneado e curto; nunca
# argumentos de --exec nem variáveis de ambiente (--env), que podem carregar valor sensível
slot_info_for() { # repo mode args...
  local r="$1" m="$2" a w=""; shift 2
  if [ "$m" = pytest ]; then
    for a in "$@"; do case "$a" in -*) ;; *) w="$w,${a##*/}" ;; esac; done; w=${w#,}
  else w=${1##*/}; fi
  w=$(printf '%s' "$w" | tr -c 'A-Za-z0-9_.,:+=-' '_' | cut -c1-80)
  printf 'repo=%s mode=%s what=%s presence=%s' "$r" "$m" "${w:--}" "${PRES:--}"
}
acquire_once() {
  local cap; cap=$(slot_cap)
  rssh <<EOF 2>/dev/null
# MBP:SLOT_ACQUIRE
S="\$HOME/gt-remote/slots"; mkdir -p "\$S"
n=1
while [ \$n -le $cap ]; do
  if mkdir "\$S/\$n" 2>/dev/null; then
    printf '%s\n' '$OWNER' > "\$S/\$n/owner"; printf '%s\n' '$SLOT_INFO' > "\$S/\$n/info"
    occ=\$(ls -1 "\$S" | grep -c '^[0-9][0-9]*\$')
    if [ "\$occ" -le $cap ]; then echo "SLOT=\$n"; exit 0; fi
    rm -f "\$S/\$n/owner" "\$S/\$n/info"; rmdir "\$S/\$n" 2>/dev/null
    break
  fi
  n=\$((n+1))
done
for d in "\$S"/*/; do
  [ -d "\$d" ] || continue
  m=\${d%/}; m=\${m##*/}
  echo "BUSY \$m \$(cat "\$d/owner" 2>/dev/null | tr -d ' ') \$(stat -f %m "\$d" 2>/dev/null)"
done
echo FULL; exit 3
EOF
}
force_release() { # n
  rssh <<EOF >/dev/null 2>&1
# MBP:SLOT_REAP
S="\$HOME/gt-remote/slots/$1"
rm -f "\$S/owner" "\$S/info"; rmdir "\$S" 2>/dev/null; true
EOF
}
acquire() {
  local out rc now line n owner mt h p e
  for attempt in 1 2; do
    out=$(acquire_once); rc=$?
    SLOT=$(echo "$out" | sed -n 's/^SLOT=//p' | head -1)
    [ -n "$SLOT" ] && return 0
    [ $rc -eq 255 ] && { say "ssh caiu ao pegar slot"; return 98; }
    [ $attempt -eq 2 ] && break
    now=$(date +%s); reaped=0
    while IFS= read -r line; do
      case "$line" in BUSY*) ;; *) continue ;; esac
      set -- $line; n=$2; owner=${3:-}; mt=${4:-0}
      h=${owner%%:*}; p=${owner#*:}; p=${p%%:*}; e=${owner##*:}
      stale=0
      if [ -z "$owner" ]; then [ $((now - ${mt:-0})) -gt 60 ] && stale=1
      else
        [ "$h" = "$ME" ] && [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && stale=1
        case "$e" in ''|*[!0-9]*) ;; *) [ $((now - e)) -gt "$SLOT_MAX_AGE" ] && stale=1 ;; esac
      fi
      if [ $stale -eq 1 ]; then say "slot $n morto (dono=$owner) — liberando"; force_release "$n"; reaped=1; fi
    done <<<"$out"
    [ $reaped -eq 1 ] || break
  done
  say "slots do MBP ocupados (teto $(slot_cap), modo ${PRES:-?}) — rode local"; return 96
}
release() {
  [ -n "$SLOT" ] || return 0
  rssh <<EOF >/dev/null 2>&1
# MBP:SLOT_RELEASE
S="\$HOME/gt-remote/slots/$SLOT"
if grep -q '$OWNER' "\$S/owner" 2>/dev/null; then rm -f "\$S/owner" "\$S/info"; rmdir "\$S" 2>/dev/null; fi
true
EOF
  SLOT=""
}
cleanup() { release; [ -n "${TMPOUT:-}" ] && rm -f "$TMPOUT"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---- seed / check -----------------------------------------------------------------------------------------------
if [ "$mode" = check ]; then
  preflight; rc=$?
  printf '%s\n' "${PF:-}"; echo "offload_flag=$([ -f "$FLAG" ] && echo on || echo off)"
  echo "paused_local=$([ -e "$PAUSEFILE" ] && echo 1 || echo 0)"
  echo "pause_local_info=$(head -n 1 "$PAUSEFILE" 2>/dev/null | tr -d '|\r' | cut -c1-100)"
  [ -n "$PRES" ] && echo "slot_cap=$(slot_cap)"
  exit $rc
fi

if [ "$mode" = seed ]; then
  case "$seed_repo" in wa|ps) ;; *) say "uso: --seed wa|ps"; exit 97 ;; esac
  [ -e "$PAUSEFILE" ] && { say "pausado pelo Athos ($PAUSEFILE) — não semeio"; exit 99; }
  preflight || exit $?
  # com o Athos no MBP (ou sem saber), o receptor do rsync roda em prioridade de fundo: a semeadura é I/O no notebook dele
  RSYNC_PATH_OPT=(); [ "$PRES" = livre ] || RSYNC_PATH_OPT=(--rsync-path="taskpolicy -b rsync")
  root=$(local_root_of "$seed_repo"); base=$(base_of "$seed_repo"); lv=$(local_venv_of "$seed_repo"); rv=$(venv_of "$seed_repo")
  say "semeando ~/gt-remote/$base a partir de $root"
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "mkdir -p gt-remote/$base gt-remote/mirror gt-remote/slots" || exit 98
  "$RSYNC_BIN" -a --delete "${RSYNC_PATH_OPT[@]+"${RSYNC_PATH_OPT[@]}"}" -e "$SSH_BIN $SSH_OPTS" "${EXCLUDES[@]}" "$root"/ "$MBP_HOST:gt-remote/$base/" || exit 98
  sp=$(ls -d "$lv"/lib/python3.*/site-packages 2>/dev/null | head -1)
  [ -n "$sp" ] || { say "site-packages local não achado em $lv"; exit 97; }
  pyver=$(echo "$sp" | sed -n 's#.*/lib/\(python3\.[0-9]*\)/site-packages#\1#p')
  hash=$(ls "$sp" | grep -E '\.dist-info$' | LC_ALL=C sort | shasum | awk '{print $1}')
  rhash=$("$SSH_BIN" $SSH_OPTS "$MBP_HOST" "cat gt-remote/$rv/.sp-hash 2>/dev/null")
  if [ "$hash" = "$rhash" ]; then say "site-packages do MBP já bate (hash ${hash:0:12})"; exit 0; fi
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "zsh -lc 'test -d gt-remote/$rv || $pyver -m venv gt-remote/$rv'" || { say "venv no MBP falhou ($pyver)"; exit 98; }
  "$RSYNC_BIN" -a --delete --exclude __pycache__ "${RSYNC_PATH_OPT[@]+"${RSYNC_PATH_OPT[@]}"}" -e "$SSH_BIN $SSH_OPTS" "$sp"/ "$MBP_HOST:gt-remote/$rv/lib/$pyver/site-packages/" || exit 98
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "echo $hash > gt-remote/$rv/.sp-hash"
  say "seed $seed_repo ok (hash $hash)"; exit 0
fi

# ---- caminho normal (pytest | exec) ----------------------------------------------------------------------------
[ -f "$FLAG" ] || { say "offload desligado (falta $FLAG) — rode local"; exit 99; }
[ -e "$PAUSEFILE" ] && { say "pausado pelo Athos ($(head -n 1 "$PAUSEFILE" 2>/dev/null | cut -c1-100)) — rode local"; exit 99; }

if [ "$mode" = pytest ]; then
  if [ -z "$repo" ]; then
    case "$dir" in *whatsapp_automation*) repo=wa ;; *property_scrapers*|*property-scrapers*) repo=ps ;; esac
  fi
  case "$repo" in wa|ps) ;; *) say "não deduzi o repo de '$dir' — use --repo wa|ps"; usage; exit 97 ;; esac
  [ $# -gt 0 ] || { say "faltam os argumentos do pytest (use -- tests/test_x.py)"; exit 97; }
  [ -d "$dir/tests" ] || { say "$dir não tem tests/ — use --dir <worktree>"; exit 97; }
else
  [ $# -gt 0 ] || { say "faltou o comando (use -- <comando>)"; exit 97; }
fi

preflight || { rc=$?; log_refusal; exit $rc; }
SLOT_INFO=$(slot_info_for "${repo:-exec}" "$mode" "$@")
acquire || exit $?
T0=$(date +%s)
mkdir -p "$CITY/.gc/run" 2>/dev/null; TMPOUT=$(mktemp "$CITY/.gc/run/mbp-run.XXXXXX")
RC=0
qargs=$(printf '%q ' "$@")

if [ "$mode" = pytest ]; then
  base=$(base_of "$repo"); rv=$(venv_of "$repo"); M="gt-remote/mirror/$repo-$SLOT"
  m=$(rssh <<EOF 2>/dev/null
# MBP:MIRROR
B="\$HOME/gt-remote/$base"; M="\$HOME/$M"
[ -d "\$M" ] && { echo MIRROR_OK; exit 0; }
[ -d "\$B" ] || { echo NOBASE; exit 97; }
mkdir -p "\$HOME/gt-remote/mirror" && cp -cR "\$B" "\$M" && echo MIRROR_SEEDED
EOF
  ); mrc=$?
  case "$m" in
    *NOBASE*) say "base ~/gt-remote/$base ausente no MBP — rode: mbp-run.sh --seed $repo"; exit 97 ;;
    *MIRROR_*) ;;
    *) [ $mrc -eq 255 ] && { say "ssh caiu ao preparar o espelho"; exit 98; }; say "espelho falhou: $m"; exit 98 ;;
  esac
  "$RSYNC_BIN" -a --delete -e "$SSH_BIN $SSH_OPTS" "${EXCLUDES[@]}" "$dir"/ "$MBP_HOST:$M/" >/dev/null 2>&1
  rrc=$?; [ $rrc -eq 0 ] || { say "rsync do worktree falhou (rc=$rrc) — rode local"; exit 98; }
  IFS= read -r -d '' JOBDEF <<EOF || true
export PATH=/opt/homebrew/bin:\$PATH PYTHONDONTWRITEBYTECODE=1
job() { cd "\$HOME/$M" || return 97; \$MBP_BG nice -n "\$MBP_NICE" "\$HOME/gt-remote/$rv/bin/python" -m pytest -p no:cacheprovider $qargs; }
mbp_supervise job
EOF
  run_remote RUN "$JOBDEF"
  if [ $RC -ne 0 ] && grep -q -E 'shared/data|\.db\b|unable to open database' "$TMPOUT"; then
    say "NOTE: shared/data/ e *.db NÃO são enviados ao MBP; teste que lê esses arquivos falha aqui — rode esse teste local."
  fi
else
  X="gt-remote/exec/$SLOT"
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "mkdir -p $X/in" || { say "ssh caiu ao preparar o scratch"; exit 98; }
  for p in "${pushes[@]+"${pushes[@]}"}"; do
    [ -n "$p" ] || continue
    "$RSYNC_BIN" -a -e "$SSH_BIN $SSH_OPTS" "$p" "$MBP_HOST:$X/in/" >/dev/null 2>&1 || { say "push de $p falhou"; exit 98; }
  done
  envline=""
  for kv in "${envs[@]+"${envs[@]}"}"; do [ -n "$kv" ] && envline="$envline $(printf '%q' "$kv")"; done
  IFS= read -r -d '' JOBDEF <<EOF || true
export PATH="\$HOME/gt-remote/rea/bin:/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:\$PATH"
export GHIDRA_INSTALL_DIR="\${GHIDRA_INSTALL_DIR:-/opt/homebrew/opt/ghidra/libexec}"
export JAVA_HOME="\${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
job() { cd "\$HOME/$X" || return 97; env$envline \$MBP_BG nice -n "\$MBP_NICE" $qargs; }
mbp_supervise job
EOF
  run_remote EXEC "$JOBDEF"
  for pl in "${pulls[@]+"${pulls[@]}"}"; do
    rel=${pl%%:*}; dest=${pl#*:}
    [ -n "$rel" ] && [ -n "$dest" ] || continue
    "$RSYNC_BIN" -a -e "$SSH_BIN $SSH_OPTS" "$MBP_HOST:$X/$rel" "$dest" >/dev/null 2>&1 || say "pull de $rel falhou"
  done
  if [ $keep -eq 0 ]; then
    "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "find $X -mindepth 1 -delete" >/dev/null 2>&1 || say "AVISO: scratch $X não foi limpo"
  fi
fi

SECS=$(( $(date +%s) - T0 ))
if [ $RC -eq 255 ]; then say "ssh caiu durante a execução — rode local"; log_run "${repo:-exec}" "$mode" "$SLOT" 255 "$SECS" "$@"; exit 98; fi
if [ $RC -eq 124 ]; then say "timeout de ${RUN_TIMEOUT}s"; fi
log_run "${repo:-exec}" "$mode" "$SLOT" "$RC" "$SECS" "$@"
exit $RC
