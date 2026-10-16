#!/usr/bin/env bash
# mbp-run.sh — roda testes dirigidos (pytest) ou um comando pesado (rea/jadx/...) no nó Linux de testes (Hetzner) ou no MacBook Pro.
#
# Contents
#   Por quê · Uso · Códigos de saída · O nó Linux (ga-zri39b) · Presença do Athos · Toggle · Como funciona · Segurança
#
# POR QUÊ (Athos 11/10): o mini vive com load 40-60 e swap alto; os MESMOS 231 testes de lot_groups levam
#   161 s no mini e 5,3 s no MBP. O MBP (16 GB, 12 CPUs) vira nó de capacidade, com chave de ligar/desligar.
#   (Athos 13/10) 100% dos testes vão a um servidor externo: o nó Linux é o destino PADRÃO, o MBP vira reserva e o mini o último recurso.
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
#   mbp-run.sh --remote-pause on|off # grava/remove ~/gt-remote/PAUSE no MBP (a chave "pausar até eu liberar"; quem chama é o mbp-offload.sh)
#   mbp-run.sh --install-tools       # copia mbp-presence.sh e mbp-controle.sh (como `gascity-mbp`) para ~/gt-remote/bin/ no MBP
#   mbp-run.sh --host linux|mbp ...  # fixa UM host (sem a cadeia): vale para --check, e é como o shadow roda o lado do MBP
#        --host linux --check          saúde do nó Linux (preflight + bandeira + janela da sombra)
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
# O NÓ LINUX (ga-zri39b; servidor alugado por hora, teste de 1 semana aprovado pelo Athos em 13/10, ssh alias `hetzner-teste`)
#   LIGA/DESLIGA  arquivo $CITY/.gc/hetzner-node.on (apagar = desligar; o nó em si é do Mayor). Independe do mbp-offload.on e da pausa do Athos:
#                 a pausa existe porque o MBP é o notebook dele, o nó é máquina dedicada (presença sempre LIVRE).
#   CADEIA        nó Linux -> MBP -> mini, com os mesmos códigos 96..99: qualquer motivo para o nó não rodar (bandeira, inalcançável, sem saúde,
#                 slots cheios, base ausente, ssh que caiu no meio, filtro ilegível, repo que não é wa, teste mac-only) cai no MBP, e daí no
#                 que já existia. Servidor fora do ar NUNCA trava o gate. Só pytest vai ao nó (--exec segue no MBP; é a bead do REA).
#   SEGURANÇA     o rsync para o nó usa SÓ scripts/hetzner-rsync-filter.wa.txt, com --delete-excluded. O filtro olha NOME e pasta, nunca o conteúdo: nome de segredo
#                 ou de dado conhecido não sai, e fora de tests/ só sai código e os arquivos de dado/config listados POR CAMINHO (nome desconhecido fica inerte).
#                 Filtro fora da forma que o filter_sane confere = o nó NÃO é usado. O CONTEÚDO é conferido por node_guard (scripts/hetzner-pii-scan.py): arquivo
#                 com lista de telefones/CPFs fica no mini, e se a varredura não termina o nó NÃO é usado.
#   MAC-ONLY     scripts/hetzner-mac-only.txt (um glob por linha) + $CITY/.gc/hetzner-mac-only.learned (aprendido pela sombra): bateria com algum
#                 alvo da lista pula o nó (launchd/plist, osascript, /Users, ADB). Lista ilegível = o nó NÃO é usado (inerte).
#   SOMBRA        nas primeiras 24 h da bandeira (HETZNER_SHADOW_WINDOW_S) ~10% das baterias (HETZNER_SHADOW_PCT) rodam TAMBÉM no MBP, em paralelo;
#                 rc diferente (ou arquivos reprovados diferentes) vai para $CITY/.gc/logs/hetzner-shadow.jsonl e os arquivos divergentes entram na
#                 lista aprendida. Quem chamou recebe sempre o resultado do nó; a sombra só mede. rc de AMBIENTE (96..99, 124, 126/127, >=128) de um
#                 dos lados não é veredito de teste: vira `skipped` e NADA é aprendido (a lista aprendida não expira). O mesmo vale para saída de um
#                 dos lados que não abre: "não consegui ler" não é "nenhum arquivo reprovou".
#   PARALELISMO   pytest-xdist (-n) em baterias grandes (>= HETZNER_XDIST_MIN_TESTS testes, 40), com núcleos / baterias em curso; nunca por cima de
#                 -n, -p no:xdist, --pdb, --co, --lf... do chamador. O ganho do nó é o paralelismo: um teste só empata com o mini.
#   LOG           toda linha de $CITY/.gc/logs/mbp-run.jsonl traz "host":"hetzner"|"mbp" (e "shadow":1 no lado de sombra do MBP).
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
# TOGGLE: scripts/mbp-offload.sh on|off|pause|resume|status (arquivo-bandeira; o botão do painel é a bead de painel).
# COMO FUNCIONA: preflight (1 ssh) -> slot (mkdir atômico em ~/gt-remote/slots/N, dono=host:pid:epoch, reaping de
#   dono morto/idade) -> espelho por slot (~/gt-remote/mirror/<repo>-N, clone APFS da base na 1ª vez) -> rsync do
#   worktree do chamador -> pytest no venv do MBP com nice -> stream -> libera o slot -> log jsonl.
# SEGURANÇA: só testes dirigidos (nunca a suíte inteira). Não envia .git, venv, shared/data, *.db. Nenhum segredo
#   viaja no comando; o MBP usa o mesmo `secret`/Bitwarden do mini quando a tarefa precisar (decisão do Athos).
set -o pipefail

CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
MAC_HOST=${MBP_HOST:-athos@athoss-macbook-pro.local}
MBP_HOST=$MAC_HOST     # MBP_HOST é o host-ALVO da vez (use_host troca entre o MBP e o nó Linux); o MBP é o padrão de todos os modos que não são pytest
FLAG="$CITY/.gc/mbp-offload.on"
PAUSEFILE="$CITY/.gc/mbp-offload.pause"
LOG="$CITY/.gc/logs/mbp-run.jsonl"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESENCE_LIB="$HERE/mbp-presence.sh"
CONTROLE="$HERE/mbp-controle.sh"
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
SSH_OPTS_MAC="-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/%C -o ControlPersist=60"
SSH_OPTS=$SSH_OPTS_MAC
ME="$(hostname -s 2>/dev/null || echo mini)"
OWNER="$ME:$$:$(date +%s)"

# ---- o nó Linux (ga-zri39b) ---------------------------------------------------------------------------------------------------
NODE_HOST=${HETZNER_NODE_HOST:-hetzner-teste}
NODE_FLAG="$CITY/.gc/hetzner-node.on"
NODE_FILTER=${HETZNER_RSYNC_FILTER:-$HERE/hetzner-rsync-filter.wa.txt}
NODE_MAC_ONLY=${HETZNER_MAC_ONLY_LIST:-$HERE/hetzner-mac-only.txt}
NODE_LEARNED="$CITY/.gc/hetzner-mac-only.learned"
NODE_SHADOW_LOG="$CITY/.gc/logs/hetzner-shadow.jsonl"
# valor fora de 0..100 (ou não numérico) volta ao padrão 10, e NÃO satura em 100: um erro de digitação (1000) não pode dobrar a carga do MBP — o lado seguro de um valor inválido é o padrão
NODE_SHADOW_PCT=$(num_or "${HETZNER_SHADOW_PCT:-10}" 10); [ "$NODE_SHADOW_PCT" -le 100 ] || NODE_SHADOW_PCT=10
NODE_SHADOW_WINDOW_S=$(num_or "${HETZNER_SHADOW_WINDOW_S:-86400}" 86400)   # a janela conta da hora da bandeira (touch na bandeira reabre a sombra)
NODE_SHADOW_WAIT_S=$(num_or "${HETZNER_SHADOW_WAIT_S:-120}" 120)           # quanto esperar o lado do MBP depois que o nó terminou
NODE_MAX_SLOTS=$(num_or "${HETZNER_MAX_SLOTS:-6}" 6); [ "$NODE_MAX_SLOTS" -ge 1 ] || NODE_MAX_SLOTS=6
NODE_MIN_DISK_MB=$(num_or "${HETZNER_MIN_DISK_MB:-2048}" 2048)
NODE_XDIST_MIN=$(num_or "${HETZNER_XDIST_MIN_TESTS:-40}" 40)
NODE_XDIST_OFF=${HETZNER_XDIST_OFF:-0}                                     # 1 = nunca injeta -n
NODE_PERSIST_S=$(num_or "${HETZNER_SSH_PERSIST_S:-600}" 600)               # ssh mini->nó custa ~3 s por conexão (RTT 200 ms): a conexão é reaproveitada entre baterias
SSH_OPTS_NODE="-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/%C -o ControlPersist=$NODE_PERSIST_S"
HOSTKIND=mac; HOSTLOG=mbp; HNAME=MBP
SHADOW_RUN=${MBP_RUN_SHADOW:-0}                                            # 1 = este processo é o lado de MBP de uma sombra (o log o marca)
use_host() { # linux | mbp
  case "$1" in
    linux) HOSTKIND=linux; HOSTLOG=hetzner; HNAME="nó Linux"; MBP_HOST=$NODE_HOST; SSH_OPTS=$SSH_OPTS_NODE ;;
    *)     HOSTKIND=mac;   HOSTLOG=mbp;     HNAME=MBP;        MBP_HOST=$MAC_HOST;  SSH_OPTS=$SSH_OPTS_MAC ;;
  esac
}

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
pause_arg=""; host_sel=auto
pushes=(); pulls=(); envs=(); keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host_sel="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --repo) repo="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --dir) dir="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --exec) mode=exec; shift ;;
    --seed) mode=seed; seed_repo="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --check) mode=check; shift ;;
    --remote-pause) mode=remote_pause; pause_arg="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --install-tools) mode=install_tools; shift ;;
    --push) pushes+=("${2:-}"); shift $(( $# > 1 ? 2 : 1 )) ;;
    --pull) pulls+=("${2:-}"); shift $(( $# > 1 ? 2 : 1 )) ;;
    --env) envs+=("${2:-}"); shift $(( $# > 1 ? 2 : 1 )) ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

case "$host_sel" in auto|linux|mbp) ;; *) say "uso: --host linux|mbp"; exit 97 ;; esac
# nomes na máquina remota: no MBP a base é gt-remote/whatsapp_automation e o venv gt-remote/venv; no nó Linux (montado pelo Mayor) são wa-base e venv-wa.
# O nó só tem o wa: ps no nó Linux não existe (vazio → o chamador cai no MBP).
base_of() { if [ "$HOSTKIND" = linux ]; then case "$1" in wa) echo wa-base ;; esac; else case "$1" in wa) echo whatsapp_automation ;; ps) echo property_scrapers ;; esac; fi; }
venv_of() { if [ "$HOSTKIND" = linux ]; then case "$1" in wa) echo venv-wa ;; esac; else case "$1" in wa) echo venv ;; ps) echo venv-ps ;; esac; fi; }
local_root_of() { case "$1" in wa) echo /Users/athos/gt/whatsapp_automation ;; ps) echo /Users/athos/.property-scrapers/runtime/main ;; esac; }
local_venv_of() { case "$1" in wa) echo /Users/athos/gt/whatsapp_automation/venv ;; ps) echo /Users/athos/.property-scrapers/runtime/main/venv ;; esac; }

rssh() { "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s; }
rssh_s() { "$SSH_BIN" $SSH_OPTS "$MBP_HOST" bash -s -- "$@"; }   # idem, com argumentos posicionais para o script

log_run() { # repo mode slot rc secs   (+ globais PRES e DEMOTED: o estado em que a execução largou e se foi rebaixada no meio)
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  # host: onde a execução rodou (hetzner|mbp); shadow=1 só no lado de MBP de uma sombra (esse rc não é o que o chamador recebeu)
  printf '{"ts":"%s","repo":"%s","mode":"%s","slot":"%s","rc":%s,"secs":%s,"nargs":%s,"presence":"%s","demoted":%s,"host":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$(( $# - 5 ))" "${PRES:--}" "${DEMOTED:-0}" "$HOSTLOG" "$([ "$SHADOW_RUN" = 1 ] && printf ',"shadow":1')" >> "$LOG" 2>/dev/null || true
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
  printf '{"ts":"%s","repo":"-","mode":"preflight","slot":"-","rc":%s,"secs":0,"nargs":0,"reason":"%s","avail_mb":%s,"swap_mb":%s,"swap_delta_mb":%s,"pressure":%s,"presence":"%s","host":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${REFUSAL_RC:-98}" "${REFUSAL:-desconhecido}" "$a" "$s" "$d" "$p" "${PRES:--}" "$HOSTLOG" "$([ "$SHADOW_RUN" = 1 ] && printf ',"shadow":1')" >> "$LOG" 2>/dev/null \
    || say "AVISO: recusa '${REFUSAL:-desconhecido}' NÃO gravada em $LOG — a contagem de 72 h (mbp-offload.sh counts) não vai incluí-la"
}

# ---- script remoto: cabeçalho comum (marcador + parâmetros + biblioteca de presença) -------------------------------------
# $1 = nome do marcador (primeira linha: é por ele que o stub do selftest reconhece o script). A biblioteca mbp-presence.sh roda NO
# MBP; se não der para lê-la aqui, o MBP é tratado como "em uso" (presence= vazio) — nunca como livre — e o aviso sai no stderr.
remote_header() {
  local lib
  printf '# MBP:%s\n' "$1"
  printf 'PRESENCE_AWAY_S=%s\nPRESENCE_WATCH_S=%s\nPRESENCE_LIB_ONLY=1\n' "$AWAY_S" "$WATCH_S"
  if [ "$HOSTKIND" = linux ]; then
    # máquina dedicada: não há Athos para proteger. Presença é SEMPRE livre e nunca há pausa remota; a biblioteca do macOS (ioreg/pmset) nem é enviada.
    printf '%s\n' 'presence_eval() { PR_MODE=livre; PR_WHY=dedicada; PR_LOCKED=; PR_IDLE=; PR_HOLD=; PR_PAUSED=0; }' \
      'presence_probe() { presence_eval; echo "presence=livre"; echo "presence_why=dedicada"; echo "paused=0"; }'
    return 0
  fi
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
# Preflight do nó Linux: os MESMOS pares k=v do macOS, lidos de /proc (o 2º argumento posicional é a raiz do /proc, só o selftest muda).
#   RAM = MemAvailable · swap = SwapTotal - SwapFree (e o crescimento entre duas leituras) · pressão = PSI de memória, mapeada para os níveis do
#   macOS (1 normal, 2 aviso, 4 crítico) para o lado local julgar igual · bateria não existe (power=ac) · presença = sempre livre (máquina dedicada).
#   Mesma regra de sempre: leitura que vazia, falha ou vem em formato inesperado deixa o campo VAZIO, nunca 0 e nunca "normal" — o lado local
#   lê campo vazio como "não consegui saber" e recusa. Sem swap nenhum (SwapTotal 0) é uma leitura VÁLIDA de 0.
preflight_script_linux() {
  remote_header PREFLIGHT
  printf 'PSI_S2=%s\nPSI_F2=%s\nPSI_S4=%s\nPSI_F4=%s\nWAVENV=%s\n' "$(num_or "${HETZNER_PSI_SOME_WARN:-10}" 10)" "$(num_or "${HETZNER_PSI_FULL_WARN:-1}" 1)" \
    "$(num_or "${HETZNER_PSI_SOME_CRIT:-40}" 40)" "$(num_or "${HETZNER_PSI_FULL_CRIT:-10}" 10)" "$(HOSTKIND=linux venv_of wa)"
  cat <<'EOF'
SAMPLE_S=${1:-2}; PROC=${2:-/proc}
[ "$SAMPLE_S" -ge 1 ] 2>/dev/null || SAMPLE_S=2
isnum() { [ "$1" -ge 0 ] 2>/dev/null; }
mi() { awk -v k="$1:" '$1 == k && $2 ~ /^[0-9]+$/ && $3 == "kB" { print $2; exit }' "$PROC/meminfo" 2>/dev/null; }
swap_used() { local st sf; st=$(mi SwapTotal); sf=$(mi SwapFree); if isnum "$st" && isnum "$sf" && [ "$sf" -le "$st" ]; then echo $(( (st - sf) / 1024 )); fi; }
s1=$(swap_used)
ma=$(mi MemAvailable)
if isnum "$ma"; then echo "avail_mb=$(( ma / 1024 ))"; else echo "avail_mb="; fi
echo "compressed_mb="
# PSI: `some` e `full` avg10 = % do tempo, nos últimos 10 s, com tarefas paradas esperando memória. Faltou uma das duas linhas, ou o formato mudou → NADA
psi_level() { awk -v s2="$PSI_S2" -v f2="$PSI_F2" -v s4="$PSI_S4" -v f4="$PSI_F4" '
  ($1 == "some" || $1 == "full") { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=[0-9]+(\.[0-9]+)?$/) { sub(/^avg10=/, "", $i); v[$1] = $i + 0; got[$1] = 1 } }
  END { if (!(got["some"] && got["full"])) exit 1
        if (v["some"] >= s4 || v["full"] >= f4) print 4; else if (v["some"] >= s2 || v["full"] >= f2) print 2; else print 1 }'; }
lvl=$(psi_level 2>/dev/null < "$PROC/pressure/memory")
if isnum "$lvl"; then echo "pressure=$lvl"; else echo "pressure="; fi
echo "mem_free_pct="
echo "power=ac"
echo "batt="
echo "load=$(awk '{print $1}' "$PROC/loadavg" 2>/dev/null)"
nc=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
if isnum "$nc" && [ "$nc" -ge 1 ]; then echo "ncpu=$nc"; else echo "ncpu="; fi
# disco livre do home, em MB (rsync de worktree + espelhos por slot). ilegível → vazio
echo "disk_mb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print int($4 / 1024) }')"
# pytest-xdist no venv do nó: 1 tem · 0 não tem · vazio = não consegui olhar (o lado local trata vazio como 0: não injeta -n)
sp=$(ls -d "$HOME/gt-remote/$WAVENV"/lib/python3*/site-packages 2>/dev/null | head -1)
if [ -n "$sp" ] && ls "$sp" >/dev/null 2>&1; then if ls "$sp" | grep -q '^pytest_xdist-'; then echo "xdist=1"; else echo "xdist=0"; fi; else echo "xdist="; fi
presence_probe
for d in "$HOME"/gt-remote/slots/*/; do
  [ -d "$d" ] || continue
  tn=${d%/}; tn=${tn##*/}
  echo "task=$tn|$(cat "$d/owner" 2>/dev/null | tr -d ' |\n')|$(cat "$d/info" 2>/dev/null | tr '\n|' '  ' | cut -c1-160)|$(stat -c %Y "$d" 2>/dev/null)"
done
sleep "$SAMPLE_S"
s2=$(swap_used)
echo "swap_mb=$s2"
if isnum "$s1" && isnum "$s2"; then echo "swap_delta_mb=$(( s2 - s1 ))"; else echo "swap_delta_mb="; fi
EOF
}

preflight_script() {
  if [ "$HOSTKIND" = linux ]; then preflight_script_linux; return; fi
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
  local out rc avail swap delta pressure power batt disk
  REFUSAL=""; REFUSAL_RC=98
  # Script remoto: toda leitura que vazia, falha ou vem em formato inesperado deixa o campo VAZIO (nunca 0, nunca "normal");
  # o lado local lê campo vazio como "não consegui saber" e recusa (estado inerte). $1 = janela da amostra de swap, em segundos.
  out=$(preflight_script | rssh_s "$SWAP_SAMPLE_S" 2>/dev/null); rc=$?
  [ $rc -eq 0 ] && [ -n "$out" ] || { REFUSAL=inalcancavel; say "$HNAME inalcançável (ssh rc=$rc) — rode local"; return 98; }
  PF="$out"
  # Presença: valor ausente ou fora de {livre,uso} é "uso" (nunca "livre"); MBP_FORCE_PRESENCE=uso só piora.
  PRES=$(pf_get presence); PRES_WHY=$(pf_get presence_why); NCPU=$(pf_get ncpu)
  case "$PRES" in livre|uso) ;; *) PRES=uso; PRES_WHY=${PRES_WHY:-ilegivel:presenca} ;; esac
  [ "${MBP_FORCE_PRESENCE:-}" = uso ] && { PRES=uso; PRES_WHY=forcado; }
  # Pausa do Athos (arquivo no MBP): vem antes da saúde — é uma ordem dele, não uma medida. Só o literal 1 pausa (o teste do arquivo
  # é um [ -e ], que não tem terceiro estado).
  if [ "$(pf_get paused)" = 1 ]; then
    REFUSAL_RC=99; refuse pausado_mbp "$HNAME pausado pelo Athos ($(pf_get pause_info))"; return 99
  fi
  # Lado local: campo AUSENTE ou ilegível ≠ valor baixo. Os três estados (tem / não tem / não consegui saber) NUNCA caem no
  # mesmo resultado: ilegível recusa com motivo "ilegivel:<campo>" (distinto de ram/pressao/swap) para o log não mentir.
  avail=$(pf_get avail_mb); swap=$(pf_get swap_mb); delta=$(pf_get swap_delta_mb); pressure=$(pf_get pressure)
  power=$(pf_get power); batt=$(pf_get batt)
  isnum "$avail" || { refuse ilegivel:avail "RAM disponível do $HNAME ilegível"; return 98; }    # gate:ilegivel-avail
  [ "$avail" -ge "$MIN_AVAIL_MB" ] || { refuse ram "$HNAME sem RAM livre ($avail MB < $MIN_AVAIL_MB)"; return 98; }    # gate:ram
  case "$pressure" in 1|2|4) ;; *) refuse ilegivel:pressure "pressão de memória do $HNAME ilegível (nível '${pressure:-}')"; return 98 ;; esac    # gate:ilegivel-pressao
  [ "$pressure" -le "$MAX_PRESSURE" ] || { refuse pressao "$HNAME sob pressão de memória (nível $pressure > $MAX_PRESSURE; 1=normal 2=aviso 4=crítico)"; return 98; }    # gate:pressao
  isint "$delta" || { refuse ilegivel:swap_delta "crescimento do swap do $HNAME ilegível"; return 98; }    # gate:ilegivel-delta
  [ "$delta" -le "$MAX_SWAP_GROWTH_MB" ] || { refuse swap_cresce "$HNAME trocando memória agora (swap cresceu $delta MB em ${SWAP_SAMPLE_S}s > $MAX_SWAP_GROWTH_MB)"; return 98; }    # gate:cresce
  isnum "$swap" || { refuse ilegivel:swap "swap usado do $HNAME ilegível"; return 98; }    # gate:ilegivel-swap
  [ "$swap" -lt "$MAX_SWAP_MB" ] || { refuse swap_teto "$HNAME com swap acima do teto ($swap MB >= $MAX_SWAP_MB)"; return 98; }    # gate:teto
  # fonte de energia ilegível recusa com motivo próprio (antes caía em "battery" e virava recusa por bateria baixa no log)
  case "$power" in ac|battery) ;; *) refuse ilegivel:power "fonte de energia do $HNAME ilegível ('${power:-}')"; return 98 ;; esac    # gate:ilegivel-power
  if [ "$power" = battery ]; then
    isnum "$batt" || { refuse ilegivel:batt "carga da bateria do $HNAME ilegível"; return 98; }    # gate:ilegivel-batt
    [ "$batt" -gt "$MIN_BATT" ] || { refuse bateria "$HNAME na bateria ($batt% <= $MIN_BATT%)"; return 98; }
  fi
  # só o nó Linux: disco cheio faz o rsync do worktree falhar no meio. ilegível ≠ pouco: recusa com motivo próprio
  if [ "$HOSTKIND" = linux ]; then
    disk=$(pf_get disk_mb)
    isnum "$disk" || { refuse ilegivel:disk "disco livre do $HNAME ilegível"; return 98; }    # gate:ilegivel-disco
    [ "$disk" -ge "$NODE_MIN_DISK_MB" ] || { refuse disco "$HNAME sem disco livre ($disk MB < $NODE_MIN_DISK_MB)"; return 98; }    # gate:disco
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
  if [ "$HOSTKIND" = linux ]; then
    # máquina dedicada: o teto é HETZNER_MAX_SLOTS (6), ainda limitado pela RAM de agora, como no modo LIVRE do MBP. Cada bateria grande usa vários núcleos
    # (xdist divide os núcleos pelas baterias em curso), então "um slot por núcleo" colocaria 16 pytest -n 2 disputando o mesmo disco.
    cpu=$NODE_MAX_SLOTS; avail=$(pf_get avail_mb)
    if isnum "$avail"; then
      mem=$(( 1 + (avail - MIN_AVAIL_MB) / SLOT_MEM_MB )); [ "$mem" -ge 1 ] || mem=1
      [ "$mem" -ge "$cpu" ] || cpu=$mem
    fi
    echo "$cpu"; return
  fi
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
    if [ "\$occ" -le $cap ]; then echo "SLOT=\$n"; echo "OCC=\$occ"; exit 0; fi
    rm -f "\$S/\$n/owner" "\$S/\$n/info"; rmdir "\$S/\$n" 2>/dev/null
    break
  fi
  n=\$((n+1))
done
for d in "\$S"/*/; do
  [ -d "\$d" ] || continue
  m=\${d%/}; m=\${m##*/}
  echo "BUSY \$m \$(cat "\$d/owner" 2>/dev/null | tr -d ' ') \$(stat -c %Y "\$d" 2>/dev/null || stat -f %m "\$d" 2>/dev/null)"
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
    OCC=$(echo "$out" | sed -n 's/^OCC=//p' | head -1)   # quantos slots ocupados com o meu (divide os núcleos do nó entre as baterias); ausente = 1
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
  say "slots do $HNAME ocupados (teto $(slot_cap), modo ${PRES:-?}) — rode local"; return 96
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
cleanup() { type shadow_abort >/dev/null 2>&1 && shadow_abort; release; [ -n "${TMPOUT:-}" ] && rm -f "$TMPOUT"; [ -n "${SENT:-}" ] && { rm -f "$SENT" "$SENT.held" "$SENT.out" "$SENT.hp" "$SENT.v"; rmdir "$SENT.dst" 2>/dev/null; }; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---- nó Linux: guardas de segurança, lista mac-only, sombra, xdist ----------------------------------------------------------
# filter_sane: o filtro do rsync é a fronteira de dados do servidor alugado, então ele é CONFERIDO, não só lido. Confere a FORMA, não a suficiência (essa é o teste com rsync
# de verdade, no selftest e no prod test): (1) abre e não é vazio, (2) `+ /tests/***` existe, (3) as 12 regras-âncora de cada classe (.env, .netrc, client_secret, dotfile de
# token, token/secret com extensão de dado, .pickle, *.duckdb/.db/.csv/.parquet/.gz) vêm ANTES dela — o rsync usa a primeira regra que casa, e quem inclui tests/ primeiro deixa passar
# um *.duckdb plantado lá dentro —, (4) nenhum `+` antes dela e nenhum `+` que inclua tudo (`+ *`, `+ **`, `+ /*`, `+ /**`, `+ **/**`...) em lugar nenhum, só regras `- x`/`+ x` (um `!`, que
# zera a lista, ou um `.`/`:`, que traz outro arquivo, não passam), (5) a ÚLTIMA regra é `- *` (sem ela, nome desconhecido sai). rc 0 = vale · 1 = não.
filter_sane() {
  [ -f "$NODE_FILTER" ] && [ -r "$NODE_FILTER" ] && [ -s "$NODE_FILTER" ] || return 1
  awk '
    BEGIN { split(".env|.netrc|client_secret*.json|.*[Tt][Oo][Kk][Ee][Nn]*|*[Tt][Oo][Kk][Ee][Nn]*.[jyti]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*.[jyti]*|*.pickle|*.duckdb*|*.db|*.csv|*.parquet|*.gz", c, "|")
            for (i in c) { want["- " c[i]] = 1; nwant++ } }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { line = $0; sub(/[[:space:]]+$/, "", line); last = line }
    line !~ /^[-+] / { bad = 1 }
    line ~ /^\+ [*\/]+$/ && line != "+ */" { bad = 1 }
    line == "+ /tests/***" { if (!tests) tests = NR; next }
    !tests && line ~ /^\+/ { bad = 1 }
    !tests && (line in want) { seen[line] = 1 }
    END { n = 0; for (k in seen) n++; exit !(tests && !bad && n == nwant && last == "- *") }' "$NODE_FILTER"
}
# mac_only_match <args do pytest>: imprime o 1º alvo da lista mac-only. rc 0 = há alvo mac-only · 1 = nenhum · 2 = a lista não deu para ler (o chamador NÃO usa o nó: sem a
# lista não se sabe o que tem de ficar no Mac). A lista estática precisa existir; a aprendida pela sombra pode ainda não existir, mas se existe tem de abrir.
mac_only_match() {
  local lf a f g
  [ -f "$NODE_MAC_ONLY" ] && [ -r "$NODE_MAC_ONLY" ] || return 2
  if [ -e "$NODE_LEARNED" ]; then [ -f "$NODE_LEARNED" ] && [ -r "$NODE_LEARNED" ] || return 2; fi
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    f="${a%%::*}"; f="${f#"$dir"/}"
    for lf in "$NODE_MAC_ONLY" "$NODE_LEARNED"; do
      [ -f "$lf" ] || continue
      while IFS= read -r g || [ -n "$g" ]; do
        g=${g#"${g%%[![:space:]]*}"}; g=${g%"${g##*[![:space:]]}"}
        case "$g" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2254
        case "$f" in $g) printf '%s\n' "$f"; return 0 ;; esac
      done < "$lf"
    done
  done
  return 1
}
fmtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }   # mtime em segundos; ilegível → vazio
# janela da sombra: HETZNER_SHADOW_WINDOW_S depois da hora da bandeira. Hora ilegível = janela ABERTA (o lado que protege o veredito; custa só carga a mais)
shadow_window_open() {
  local t now; t=$(fmtime "$NODE_FLAG"); now=$(date +%s)
  isnum "$t" || return 0
  [ $(( now - t )) -lt "$NODE_SHADOW_WINDOW_S" ]
}
# node_wanted <args>: o nó entra na cadeia? Devolve 1 quando não e deixa o motivo em NODE_WHY (vira uma linha do log). A bandeira desligada NÃO é recusa: é o interruptor.
NODE_WHY=""
node_wanted() {
  NODE_WHY=""
  [ "$host_sel" != mbp ] || return 1
  [ -f "$NODE_FLAG" ] || return 1
  [ "$repo" = wa ] || { [ "$host_sel" = linux ] && say "o nó Linux só roda o repo wa (este é '$repo') — rode local"; return 1; }
  filter_sane || { NODE_WHY="filtro-invalido"; say "o filtro do rsync do nó ($NODE_FILTER) não abre ou não está na forma conferida pelo filter_sane (regras de segredo/dado ANTES de + /tests/***, nada que inclua tudo, \`- *\` no fim) — o nó NÃO é usado"; return 1; }
  local mo mrc
  mo=$(mac_only_match "$@"); mrc=$?
  case $mrc in
    0) NODE_WHY="mac-only"; say "$mo está na lista mac-only — esta bateria não vai ao nó Linux"; return 1 ;;
    1) ;;
    *) NODE_WHY="mac-only-ilegivel"; say "a lista mac-only ($NODE_MAC_ONLY / $NODE_LEARNED) não abre — sem ela não se sabe o que tem de ficar no Mac; o nó NÃO é usado"; return 1 ;;
  esac
  return 0
}
# node_guard: o filtro olha NOME e pasta; isto olha o CONTEÚDO do que ele deixaria sair (hetzner-pii-scan.py, o mesmo que o prod test roda no servidor). Arquivo com LISTA de telefones/CPFs (>=20 / >=3)
# fica no mini: vira regra `- /caminho` em $HELD, que o rsync lê ANTES do filtro. FALHA FECHADA (rc 1 = o nó NÃO é usado; erro e "nada retido" não são a mesma coisa): a lista do rsync que não sai, a varredura que
# não termina, arquivo listado que a varredura não conseguiu LER (rc 3 do scanner: nome com quebra de linha, que a lista parte em dois, ou arquivo que sumiu/ficou ilegível entre a lista e a varredura; sem permissão desde o início já derruba a própria lista, rc 23), e regra que NÃO segura o arquivo — um caminho com barra invertida
# vira `- /a\\b` e o rsync não o casa —, o que é conferido de verdade: um 2º rsync -n com $HELD não pode listar nenhum caminho retido. LIMITE: a lista e a varredura são um retrato de poucos segundos antes
# da cópia (o rsync da cópia anda a árvore de novo); arquivo editado nessa janela não é revarrido. A fronteira que vale no instante da cópia é o filtro (nome/pasta); isto é a segunda camada.
SENT=""; HELD=""
node_guard() {
  local nheld
  mkdir -p "$CITY/.gc/run" 2>/dev/null; SENT=$(mktemp "$CITY/.gc/run/mbp-sent.XXXXXX") || return 1; HELD="$SENT.held"
  mkdir "$SENT.dst" || return 1
  "$RSYNC_BIN" -a -n --out-format='%n' --filter=". $NODE_FILTER" "$dir"/ "$SENT.dst"/ 2>/dev/null | grep -v '/$' > "$SENT"
  [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$SENT" ] || return 1
  python3 -I "$HERE/hetzner-pii-scan.py" "$dir" --rules "$HELD" < "$SENT" > "$SENT.out" 2>/dev/null && [ -f "$HELD" ] || return 1
  nheld=$(wc -l < "$SENT.out" | tr -d ' ')
  if [ "$nheld" -gt 0 ]; then
    # vazio (nenhum caminho retido) → nada a conferir, pula; falhou (rsync -n sem resposta, lista ilegível) ou algum caminho retido AINDA listado → rc 1, o nó NÃO é usado (grep: 1 = nenhum casou = ok; 0 = vazou; 2 = erro)
    cut -f3- "$SENT.out" > "$SENT.hp" || return 1
    "$RSYNC_BIN" -a -n --out-format='%n' --filter=". $HELD" --filter=". $NODE_FILTER" "$dir"/ "$SENT.dst"/ 2>/dev/null | grep -v '/$' > "$SENT.v"
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    grep -qxF -f "$SENT.hp" "$SENT.v"; [ $? -eq 1 ] || return 1
  fi
  [ "$nheld" -eq 0 ] || say "NOTE: $nheld arquivo(s) com lista de telefones/CPFs ficam no mini e NÃO vão ao $HNAME ($(cut -f3 "$SENT.out" | head -n 4 | tr '\n' ' ')…): teste que os lê ou importa falha aqui — rode esse teste local."
  return 0
}
# node_xdist_n <args>: quantos workers do pytest-xdist usar (imprime N) ou nada. O ganho do nó é o paralelismo (um teste só empata com o mini). Só em bateria grande
# (contagem de `def test_` nos alvos; ilegível = 0 = não injeta), com xdist instalado no nó, e nunca por cima de uma escolha do chamador.
node_xdist_n() {
  [ "$HOSTKIND" = linux ] && [ "$NODE_XDIST_OFF" != 1 ] && [ "$(pf_get xdist)" = 1 ] || return 0
  local a f c n=0 nc occ w
  for a in "$@"; do
    case "$a" in
      -n|-n?*|--numprocesses|--numprocesses=*|--dist|--dist=*|-d|--pdb|--trace|--co|--collect-only|--setup-show|--sw|--stepwise|--lf|--last-failed|--ff|--nf|--looponfail|--forked|-pno:xdist|no:xdist) return 0 ;;
    esac
  done
  for a in "$@"; do
    case "$a" in -*) continue ;; *::*) n=$((n + 1)); continue ;; esac
    f="${a#"$dir"/}"
    if [ -f "$dir/$f" ]; then c=$(grep -c -E '^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_' "$dir/$f" 2>/dev/null); isnum "$c" && n=$((n + c))
    elif [ -d "$dir/$f" ]; then c=$(grep -r -c -E --include='test_*.py' '^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_' "$dir/$f" 2>/dev/null | awk -F: '{ s += $NF } END { print s + 0 }'); isnum "$c" && n=$((n + c)); fi
  done
  [ "$n" -ge "$NODE_XDIST_MIN" ] || return 0
  nc=$(pf_get ncpu); isnum "$nc" && [ "$nc" -ge 2 ] || return 0
  occ=$(num_or "${OCC:-1}" 1); [ "$occ" -ge 1 ] || occ=1
  w=$(( nc / occ )); [ "$w" -ge 2 ] || w=2; [ "$w" -le "$nc" ] || w=$nc
  echo "$w"
}
# arquivos reprovados (FAILED/ERROR do resumo -rfEs) de uma saída de pytest, ordenados, sem repetição
failed_files() { sed -n -E 's/^(FAILED|ERROR) ([^: ]+).*/\2/p' "$1" 2>/dev/null | sort -u; }

SHADOW_PID=""; SHADOW_OUT=""
shadow_start() { # "$@" = args ORIGINAIS do pytest. Decide e dispara o lado de MBP em paralelo; SHADOW_PID fica vazio quando não há sombra.
  SHADOW_PID=""; SHADOW_OUT=""
  [ "$HOSTKIND" = linux ] && [ "$host_sel" = auto ] && [ "$SHADOW_RUN" != 1 ] || return 0
  [ "$NODE_SHADOW_PCT" -gt 0 ] || return 0
  shadow_window_open || return 0
  [ $(( RANDOM % 100 )) -lt "$NODE_SHADOW_PCT" ] || return 0
  mkdir -p "$CITY/.gc/run" 2>/dev/null
  SHADOW_OUT=$(mktemp "$CITY/.gc/run/mbp-shadow.XXXXXX" 2>/dev/null) || { SHADOW_OUT=""; say "AVISO: sombra não iniciada (sem arquivo temporário)"; return 0; }
  ( exec env MBP_RUN_SHADOW=1 "$HERE/$(basename "$0")" --host mbp --repo "$repo" --dir "$dir" -- "$@" >"$SHADOW_OUT" 2>&1 </dev/null ) &
  SHADOW_PID=$!
}
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
# Derruba a sombra DE VERDADE. O trap `exit 130` dela só roda quando o comando em primeiro plano (o ssh ao MBP) termina: um `kill` só no PID deixa o `wait` segurando quem chamou até o MBP acabar,
# e o teto de espera (e o aborto com o nó caído) não limitariam nada. Ordem: TERM no processo da sombra (o trap fica pendente), depois nos filhos (o comando em primeiro plano acaba, o trap roda e
# ela libera o slot do MBP), espera limitada, e KILL se ainda estiver viva (sem pgrep a lista de filhos vem vazia: o KILL ainda solta quem chamou em até 10 s).
shadow_kill() { # PID
  local pid="$1" kids k w=0
  kids=$(descendants "$pid")
  kill "$pid" 2>/dev/null
  for k in $kids; do kill "$k" 2>/dev/null; done
  while kill -0 "$pid" 2>/dev/null && [ "$w" -lt 10 ]; do sleep 1; w=$((w + 1)); done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}
shadow_abort() { # o nó caiu no meio: o lado de MBP da sombra não tem mais com quem comparar
  if [ -n "$SHADOW_PID" ]; then shadow_kill "$SHADOW_PID"; SHADOW_PID=""; fi
  [ -z "$SHADOW_OUT" ] || rm -f "$SHADOW_OUT"; SHADOW_OUT=""
  return 0
}
shadow_log() { # veredito rc_nó rc_mbp arquivos aprendidos
  mkdir -p "$(dirname "$NODE_SHADOW_LOG")" 2>/dev/null
  printf '{"ts":"%s","repo":"%s","verdict":"%s","a_host":"hetzner","a_rc":%s,"b_host":"mbp","b_rc":%s,"files":"%s","learned":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo" "$1" "$2" "${3:-null}" "$(printf '%s' "$4" | tr -d '"\\' | tr '\n' ',' | cut -c1-300)" "${5:-0}" >> "$NODE_SHADOW_LOG" 2>/dev/null \
    || say "AVISO: veredito da sombra NÃO gravado em $NODE_SHADOW_LOG"
}
# shadow_no_verdict <rc>: 0 quando o rc NÃO é veredito de teste e sim do ambiente: 96..99 (o wrapper não rodou), 124 (estourou o tempo), 126/127 (o shell não executou/achou o comando) e >=128 (morto por sinal).
# Comparar um desses com o rc do outro lado ensinaria "mac-only" a partir de problema de infraestrutura, e a lista aprendida NUNCA expira: um timeout passageiro prenderia a bateria inteira no Mac.
# vazio/ilegível (não numérico) → também "sem veredito"; o estado inerte é não aprender nada
shadow_no_verdict() {
  case "$1" in ''|*[!0-9]*|96|97|98|99|124|126|127) return 0 ;; esac
  [ "$1" -ge 128 ]
}
shadow_finish() { # rc_do_nó arquivo_da_saída_do_nó "$@" (args originais). Espera o MBP (até NODE_SHADOW_WAIT_S), compara e aprende.
  [ -n "$SHADOW_PID" ] || return 0
  local arc="$1" aout="$2" brc waited=0 bf af diffs="" t f learned=0 msg; shift 2
  # o nó acabou por ambiente (tempo, sinal, wrapper): não há veredito de teste para comparar. Derruba a sombra sem esperar o MBP e não aprende nada.
  if shadow_no_verdict "$arc"; then
    shadow_kill "$SHADOW_PID"
    shadow_log skipped "${arc:-null}" null "" 0; say "sombra: o nó terminou com rc=${arc:-vazio} (tempo, sinal ou wrapper; não é veredito de teste) — sem veredito, nada aprendido"
    rm -f "$SHADOW_OUT"; SHADOW_OUT=""; SHADOW_PID=""; return 0
  fi
  while kill -0 "$SHADOW_PID" 2>/dev/null && [ "$waited" -lt "$NODE_SHADOW_WAIT_S" ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$SHADOW_PID" 2>/dev/null; then
    shadow_kill "$SHADOW_PID"
    shadow_log timeout "$arc" null "" 0; say "sombra: o MBP não terminou em ${NODE_SHADOW_WAIT_S}s depois do nó — sem veredito"
  else
    wait "$SHADOW_PID" 2>/dev/null; brc=$?
    if shadow_no_verdict "$brc"; then
      shadow_log skipped "$arc" "$brc" "" 0; say "sombra: o MBP não deu veredito de teste (rc=$brc: não rodou, tempo ou sinal) — sem veredito, nada aprendido"
    elif [ ! -r "$aout" ] || [ ! -r "$SHADOW_OUT" ]; then
      # failed_files devolve VAZIO tanto para "nenhum arquivo reprovou" quanto para "não consegui ler a saída" (arquivo apagado, disco que falhou): comparar um vazio desses com a lista do outro lado
      # ensinaria mac-only (para sempre) a partir de um problema local. Saída que não abre = sem veredito, nada aprendido.
      shadow_log skipped "$arc" "$brc" "" 0; say "sombra: a saída de um dos lados não pôde ser lida — sem veredito, nada aprendido"
    else
      af=$(failed_files "$aout"); bf=$(failed_files "$SHADOW_OUT")
      if [ "$arc" = "$brc" ] && [ "$af" = "$bf" ]; then shadow_log same "$arc" "$brc" "" 0
      else
        # arquivos que reprovam só de um lado; rc diferente sem nenhum arquivo legível → TODOS os alvos (mais arquivos no Mac, nunca menos)
        diffs=$(printf '%s\n%s\n' "$af" "$bf" | grep -v '^$' | sort | uniq -u)
        if [ -z "$diffs" ]; then
          for t in "$@"; do
            case "$t" in -*) continue ;; esac
            f="${t%%::*}"; f="${f#"$dir"/}"
            case "$f" in *.py) diffs="$diffs${diffs:+,}$f" ;; esac
          done
          diffs=$(printf '%s' "$diffs" | tr ',' '\n')
        fi
        if [ -n "$diffs" ]; then
          if { printf '# %s sombra: rc nó=%s mbp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arc" "$brc"; printf '%s\n' "$diffs"; } >> "$NODE_LEARNED" 2>/dev/null; then
            learned=$(printf '%s\n' "$diffs" | grep -c .)
          else say "AVISO: não consegui gravar $NODE_LEARNED — o arquivo divergente NÃO foi marcado como mac-only"; fi
        fi
        shadow_log diverge "$arc" "$brc" "$diffs" "$learned"
        # a mensagem diz "marcado" SÓ do que foi gravado ($learned vem da gravação, não de $diffs): alvo que não é .py (um diretório) ou gravação que falhou não pode sair como "marcado"
        if [ "$learned" -gt 0 ]; then msg="marcado como mac-only: $(printf '%s' "$diffs" | tr '\n' ' ')"
        elif [ -n "$diffs" ]; then msg="NADA foi marcado como mac-only (a lista aprendida não aceitou a gravação)"
        else msg="nada marcado como mac-only (nenhum alvo .py para aprender)"; fi
        say "sombra: DIVERGÊNCIA (nó rc=$arc, MBP rc=$brc) — $msg"
      fi
    fi
  fi
  rm -f "$SHADOW_OUT"; SHADOW_OUT=""; SHADOW_PID=""
}

# ---- seed / check -----------------------------------------------------------------------------------------------
# --host linux fixa o nó nos modos que olham UM host (--check, --seed); sem --host, esses modos continuam sendo do MBP como sempre foram.
case "$host_sel:$mode" in linux:remote_pause|linux:install_tools) say "--host linux não vale para --$(echo "$mode" | tr _ -): a pausa e as ferramentas são do MBP"; exit 97 ;; esac
[ "$host_sel" = linux ] && use_host linux
if [ "$mode" = check ]; then
  preflight; rc=$?
  printf '%s\n' "${PF:-}"; echo "offload_flag=$([ -f "$FLAG" ] && echo on || echo off)"
  echo "paused_local=$([ -e "$PAUSEFILE" ] && echo 1 || echo 0)"
  echo "pause_local_info=$(head -n 1 "$PAUSEFILE" 2>/dev/null | tr -d '|\r' | cut -c1-100)"
  [ -n "$PRES" ] && echo "slot_cap=$(slot_cap)"
  if [ "$HOSTKIND" = linux ]; then
    echo "node_flag=$([ -f "$NODE_FLAG" ] && echo on || echo off)"
    echo "node_filter_ok=$(filter_sane && echo 1 || echo 0)"
    mac_only_match >/dev/null; echo "node_mac_only_rc=$?"
    echo "node_shadow_window_open=$([ -f "$NODE_FLAG" ] && { shadow_window_open && echo 1 || echo 0; } || echo -)"   # sem bandeira não há janela
  fi
  exit $rc
fi

# ---- a chave "pausar até eu liberar" do lado do MBP (~/gt-remote/PAUSE); quem chama é o mbp-offload.sh ----------------
if [ "$mode" = remote_pause ]; then
  case "$pause_arg" in
    on)  line="origem=${MBP_PAUSE_ORIGIN:-painel} desde=$(date +%Y-%m-%dT%H:%M:%S%z)"
         "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "mkdir -p gt-remote && printf '%s\n' '$line' > gt-remote/PAUSE" || { say "não consegui gravar a pausa no MBP"; exit 98; }
         say "pausa gravada no MBP ($line)"; exit 0 ;;
    off) out=$("$SSH_BIN" $SSH_OPTS "$MBP_HOST" 'if [ -e gt-remote/PAUSE ]; then rm -f gt-remote/PAUSE; if [ -e gt-remote/PAUSE ]; then echo STILL; else echo REMOVED; fi; else echo ABSENT; fi' 2>/dev/null) || { say "MBP inalcançável: não sei se a pausa de lá foi removida"; exit 98; }
         case "$out" in
           REMOVED) say "pausa removida do MBP"; exit 0 ;;
           ABSENT) say "o MBP não tinha pausa"; exit 0 ;;
           *) say "a pausa do MBP NÃO saiu (${out:-sem resposta})"; exit 98 ;;
         esac ;;
    *) say "uso: --remote-pause on|off"; exit 97 ;;
  esac
fi

# ---- instala no MBP o que o Athos usa de lá: o comando `gascity-mbp` (pausar/liberar/status/barra de menu) e a biblioteca de presença
# Também roda ao fim de cada --seed (o reseed noturno): "mergeado ≠ vivo" — a cópia que mora no MBP acompanha o repositório em até um dia.
install_tools() {
  [ -r "$PRESENCE_LIB" ] && [ -r "$CONTROLE" ] || { say "faltam $PRESENCE_LIB ou $CONTROLE"; return 97; }
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "mkdir -p gt-remote/bin" || { say "MBP inalcançável"; return 98; }
  "$RSYNC_BIN" -a -e "$SSH_BIN $SSH_OPTS" "$PRESENCE_LIB" "$MBP_HOST:gt-remote/bin/mbp-presence.sh" || { say "rsync de mbp-presence.sh falhou"; return 98; }
  "$RSYNC_BIN" -a -e "$SSH_BIN $SSH_OPTS" "$CONTROLE" "$MBP_HOST:gt-remote/bin/gascity-mbp" || { say "rsync de gascity-mbp falhou"; return 98; }
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "chmod 755 gt-remote/bin/mbp-presence.sh gt-remote/bin/gascity-mbp" || { say "chmod falhou"; return 98; }
}
if [ "$mode" = install_tools ]; then
  install_tools || exit $?
  say "instalado: ~/gt-remote/bin/gascity-mbp (pausar | liberar | status | menubar) e mbp-presence.sh"; exit 0
fi
# fim de cada seed: atualiza as ferramentas do MBP sem nunca falhar a semeadura por causa delas (a base é o que importa à noite)
refresh_tools() { install_tools >/dev/null 2>&1 || say "AVISO: não atualizei ~/gt-remote/bin no MBP (gascity-mbp); rode: mbp-offload.sh install-mbp"; }
if [ "$mode" = seed ]; then
  case "$seed_repo" in wa|ps) ;; *) say "uso: --seed wa|ps"; exit 97 ;; esac
  if [ "$HOSTKIND" = linux ]; then say "a semeadura do nó Linux ainda não existe (fatia 4 da ga-zri39b)"; exit 97; fi
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
  if [ "$hash" = "$rhash" ]; then say "site-packages do MBP já bate (hash ${hash:0:12})"
    refresh_tools
    exit 0
  fi
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "zsh -lc 'test -d gt-remote/$rv || $pyver -m venv gt-remote/$rv'" || { say "venv no MBP falhou ($pyver)"; exit 98; }
  "$RSYNC_BIN" -a --delete --exclude __pycache__ "${RSYNC_PATH_OPT[@]+"${RSYNC_PATH_OPT[@]}"}" -e "$SSH_BIN $SSH_OPTS" "$sp"/ "$MBP_HOST:gt-remote/$rv/lib/$pyver/site-packages/" || exit 98
  "$SSH_BIN" $SSH_OPTS "$MBP_HOST" "echo $hash > gt-remote/$rv/.sp-hash"
  say "seed $seed_repo ok (hash $hash)"
  refresh_tools
  exit 0
fi

# ---- caminho normal (pytest | exec) ----------------------------------------------------------------------------
# pytest: CADEIA nó Linux -> MBP (-> o chamador roda no mini quando sobra 96..99). Cada host é uma TENTATIVA (attempt_pytest) que devolve o rc do pytest, ou 96..99 = "este host
# não rodou, tente o próximo". exec (REA/APK) continua só no MBP.
mac_gates() { # as chaves do MBP: bandeira e pausa do Athos
  [ -f "$FLAG" ] || { say "offload desligado (falta $FLAG) — rode local"; return 99; }
  [ -e "$PAUSEFILE" ] && { say "pausado pelo Athos ($(head -n 1 "$PAUSEFILE" 2>/dev/null | cut -c1-100)) — rode local"; return 99; }
  return 0
}
fall() { # motivo rc: o host não rodou. Só o nó grava a linha (o log do MBP segue como era); é por ela que "recusas/fallbacks" se medem.
  REFUSAL="$1"; REFUSAL_RC="$2"
  [ "$HOSTKIND" = linux ] && log_refusal
  return 0
}

# Uma tentativa de pytest no host da vez (use_host). Libera o slot e apaga a saída temporária antes de devolver, para a próxima tentativa partir do zero.
attempt_pytest() {
  local rc
  _attempt_pytest "$@"; rc=$?
  release
  [ -z "${TMPOUT:-}" ] || rm -f "$TMPOUT"; TMPOUT=""
  return $rc
}
_attempt_pytest() {
  local base rv M m mrc rrc xn cpcmd pathline JOBDEF rc SECS
  local orig=("$@")
  preflight || { rc=$?; log_refusal; return $rc; }
  if [ "$HOSTKIND" = linux ]; then node_guard || { say "não consegui varrer o conteúdo do que iria ao $HNAME (lista do rsync ou hetzner-pii-scan.py falhou) — o nó NÃO é usado, rode local"; fall varredura-falhou 98; return 98; }; fi
  SLOT_INFO=$(slot_info_for "$repo" pytest "$@")
  OCC=1
  acquire || { rc=$?; if [ $rc -eq 96 ]; then fall slots "$rc"; else fall ssh-caiu "$rc"; fi; return $rc; }
  T0=$(date +%s)
  mkdir -p "$CITY/.gc/run" 2>/dev/null; TMPOUT=$(mktemp "$CITY/.gc/run/mbp-run.XXXXXX")
  RC=0
  base=$(base_of "$repo"); rv=$(venv_of "$repo"); M="gt-remote/mirror/$repo-$SLOT"
  [ -n "$base" ] && [ -n "$rv" ] || { say "o $HNAME não tem o repo '$repo'"; fall repo-sem-no 97; return 97; }
  cpcmd="cp -cR"; [ "$HOSTKIND" = linux ] && cpcmd="cp -a --reflink=auto"   # APFS clone no macOS; no Linux, cópia (reflink quando o disco deixa)
  m=$(rssh <<EOF 2>/dev/null
# MBP:MIRROR
B="\$HOME/gt-remote/$base"; M="\$HOME/$M"
[ -x "\$HOME/gt-remote/$rv/bin/python" ] || { echo NOVENV; exit 97; }
[ -d "\$M" ] && { echo MIRROR_OK; exit 0; }
[ -d "\$B" ] || { echo NOBASE; exit 97; }
mkdir -p "\$HOME/gt-remote/mirror" && $cpcmd "\$B" "\$M" && echo MIRROR_SEEDED
EOF
  ); mrc=$?
  case "$m" in
    *NOBASE*) say "base ~/gt-remote/$base ausente no $HNAME — $([ "$HOSTKIND" = linux ] && echo 'o Mayor monta a base do nó à mão (a semeadura é a fatia 4 da ga-zri39b)' || echo "rode: mbp-run.sh --seed $repo")"; fall sem-base 97; return 97 ;;
    *NOVENV*) say "venv ~/gt-remote/$rv ausente no $HNAME — $([ "$HOSTKIND" = linux ] && echo 'o Mayor monta o venv do nó à mão (a semeadura é a fatia 4 da ga-zri39b)' || echo "rode: mbp-run.sh --seed $repo")"; fall sem-venv 97; return 97 ;;
    *MIRROR_*) ;;
    *) [ $mrc -eq 255 ] && { say "ssh caiu ao preparar o espelho"; fall ssh-caiu 98; return 98; }; say "espelho falhou: $m"; fall espelho-falhou 98; return 98 ;;
  esac
  if [ "$HOSTKIND" = linux ]; then
    # SEGURANÇA: só o filtro decide o que sai do mini. --delete-excluded tira do espelho o que o filtro exclui (inclusive o que uma semeadura antiga tenha levado).
    "$RSYNC_BIN" -a --delete --delete-excluded --filter=". $HELD" --filter=". $NODE_FILTER" -e "$SSH_BIN $SSH_OPTS" "$dir"/ "$MBP_HOST:$M/" >/dev/null 2>&1
  else
    "$RSYNC_BIN" -a --delete -e "$SSH_BIN $SSH_OPTS" "${EXCLUDES[@]}" "$dir"/ "$MBP_HOST:$M/" >/dev/null 2>&1
  fi
  rrc=$?; [ $rrc -eq 0 ] || { say "rsync do worktree falhou (rc=$rrc) — rode local"; fall rsync-falhou 98; return 98; }
  # paralelismo do nó (o ganho dele): só aqui, depois que o slot disse quantas baterias há em curso
  xn=$(node_xdist_n "$@")
  if [ -n "$xn" ]; then set -- -n "$xn" "$@"; say "xdist: $xn workers (núcleos do nó / baterias em curso)"; fi
  qargs=$(printf '%q ' "$@")
  if [ "$HOSTKIND" = linux ]; then pathline='export PATH="$HOME/.local/bin:$PATH" PYTHONDONTWRITEBYTECODE=1'
  else pathline='export PATH=/opt/homebrew/bin:$PATH PYTHONDONTWRITEBYTECODE=1'; fi
  IFS= read -r -d '' JOBDEF <<EOF || true
$pathline
job() { cd "\$HOME/$M" || return 97; \$MBP_BG nice -n "\$MBP_NICE" "\$HOME/gt-remote/$rv/bin/python" -m pytest -p no:cacheprovider $qargs; }
mbp_supervise job
EOF
  shadow_start "${orig[@]}"
  run_remote RUN "$JOBDEF"
  if [ $RC -ne 0 ] && grep -q -E 'shared/data|\.db\b|unable to open database' "$TMPOUT"; then
    say "NOTE: shared/data/ e *.db NÃO são enviados ao $HNAME; teste que lê esses arquivos falha aqui — rode esse teste local."
  fi
  SECS=$(( $(date +%s) - T0 ))
  if [ $RC -eq 255 ]; then
    say "ssh caiu durante a execução — rode local"; log_run "$repo" pytest "$SLOT" 255 "$SECS" "${orig[@]}"; shadow_abort; return 98
  fi
  if [ $RC -eq 124 ]; then say "timeout de ${RUN_TIMEOUT}s"; fi
  log_run "$repo" pytest "$SLOT" "$RC" "$SECS" "${orig[@]}"
  say "rodou em $HOSTLOG ($HNAME) slot=$SLOT secs=$SECS rc=$RC"
  shadow_finish "$RC" "$TMPOUT" "${orig[@]}"
  return $RC
}

# ---- --exec (REA/APK): só no MBP -----------------------------------------------------------------------------------------------
run_exec() {
  local X kv p envline pl rel dest JOBDEF SECS
  preflight || { rc=$?; log_refusal; exit $rc; }
  SLOT_INFO=$(slot_info_for "exec" "$mode" "$@")
  acquire || exit $?
  T0=$(date +%s)
  mkdir -p "$CITY/.gc/run" 2>/dev/null; TMPOUT=$(mktemp "$CITY/.gc/run/mbp-run.XXXXXX")
  RC=0
  qargs=$(printf '%q ' "$@")
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
  SECS=$(( $(date +%s) - T0 ))
  if [ $RC -eq 255 ]; then say "ssh caiu durante a execução — rode local"; log_run "exec" "$mode" "$SLOT" 255 "$SECS" "$@"; exit 98; fi
  if [ $RC -eq 124 ]; then say "timeout de ${RUN_TIMEOUT}s"; fi
  log_run "exec" "$mode" "$SLOT" "$RC" "$SECS" "$@"
  exit $RC
}

# ---- orquestração ------------------------------------------------------------------------------------------------------------------
if [ "$mode" = exec ]; then
  [ "$host_sel" != linux ] || { say "--exec roda só no MBP (o nó Linux é de pytest)"; exit 97; }
  mac_gates || exit $?
  [ $# -gt 0 ] || { say "faltou o comando (use -- <comando>)"; exit 97; }
  use_host mbp
  run_exec "$@"
fi

# pytest. Com o nó possível, a validação de uso vem antes (precisa do repo); sem o nó, a ordem de sempre: as chaves do MBP primeiro (rc 99 sem olhar os argumentos).
node_possible=0
[ "$host_sel" != mbp ] && [ -f "$NODE_FLAG" ] && node_possible=1
if [ "$host_sel" = linux ] && [ $node_possible -eq 0 ]; then say "nó Linux desligado (falta $NODE_FLAG) — rode local"; exit 99; fi
if [ $node_possible -eq 0 ]; then mac_gates || exit $?; fi

if [ -z "$repo" ]; then
  case "$dir" in *whatsapp_automation*) repo=wa ;; *property_scrapers*|*property-scrapers*) repo=ps ;; esac
fi
case "$repo" in wa|ps) ;; *) say "não deduzi o repo de '$dir' — use --repo wa|ps"; usage; exit 97 ;; esac
[ $# -gt 0 ] || { say "faltam os argumentos do pytest (use -- tests/test_x.py)"; exit 97; }
[ -d "$dir/tests" ] || { say "$dir não tem tests/ — use --dir <worktree>"; exit 97; }

if [ $node_possible -eq 1 ]; then
  if node_wanted "$@"; then
    use_host linux
    attempt_pytest "$@"; nrc=$?
    case $nrc in 96|97|98|99) ;; *) exit $nrc ;; esac
    [ "$host_sel" != linux ] || exit $nrc
    say "o nó Linux não rodou (rc=$nrc) — tentando o MBP"
  else
    # o nó estava ligado e NÃO foi usado por um motivo (filtro, lista mac-only, repo): uma linha no log, para o relatório contar os fallbacks
    if [ -n "$NODE_WHY" ]; then use_host linux; fall "$NODE_WHY" 98; fi
    [ "$host_sel" != linux ] || exit 98
  fi
  use_host mbp
  mac_gates || exit $?
fi
use_host mbp
attempt_pytest "$@"
exit $?
