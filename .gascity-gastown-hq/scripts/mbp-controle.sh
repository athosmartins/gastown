#!/usr/bin/env bash
# mbp-controle.sh — `gascity-mbp`: o controle do Gas City que o Athos usa DENTRO do MacBook Pro (ga-77c1qg, épico ga-sokx7u).
#
# Contents
#   Uso · Instalação · O que lê · Barra de menu
#
# USO (no MBP)
#   gascity-mbp status     como o Gas City enxerga o MBP agora: LIVRE / EM USO / PAUSADO, por quê, e o que está rodando aqui
#   gascity-mbp pausar     "pausar até eu liberar": nada novo do Gas City começa neste MBP e o que já roda cai para prioridade de
#                          fundo (em até ~5 s). Cria ~/gt-remote/PAUSE.
#   gascity-mbp liberar    tira a pausa (apaga ~/gt-remote/PAUSE)
#   gascity-mbp menubar    saída no formato xbar/SwiftBar (ver "Barra de menu")
#
# INSTALAÇÃO: não se instala à mão. No mini: `scripts/mbp-offload.sh install-mbp` copia este arquivo para
#   ~/gt-remote/bin/gascity-mbp e a biblioteca scripts/mbp-presence.sh para ~/gt-remote/bin/mbp-presence.sh. Nada é gravado fora de
#   ~/gt-remote; nenhum PATH, atalho ou perfil de shell é alterado (para chamar sem o caminho, o Athos cria um alias se quiser).
#
# O QUE LÊ: só o que o MBP sabe de si — a presença (mesma biblioteca do mini: tela bloqueada, teclado/mouse, tela segurada por app),
#   a pausa (~/gt-remote/PAUSE) e os slots em ~/gt-remote/slots (uma pasta por tarefa do Gas City, com dono e descrição). A chave
#   liga/desliga e a saúde (RAM/swap) moram no mini: `mbp-offload.sh status` lá mostra o quadro completo.
#
# BARRA DE MENU (opcional, NÃO instalada pelo Gas City): para ver "Gas City usando o MBP: N tarefas" no topo da tela, instale o
#   SwiftBar (gratuito) e crie nele UM arquivo executável, gascity-mbp.10s.sh, com:
#       #!/bin/bash
#       exec "$HOME/gt-remote/bin/gascity-mbp" menubar
#   A primeira linha da saída é o título (🟢 livre · 🟠 em uso · ⏸ pausado, com o número de tarefas); o menu tem "Pausar" e "Liberar".
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${GASCITY_MBP_LIB:-$HERE/mbp-presence.sh}"
GT="${GASCITY_MBP_HOME:-$HOME/gt-remote}"
SLOTS="$GT/slots"
PRESENCE_PAUSE_FILE="${PRESENCE_PAUSE_FILE:-$GT/PAUSE}"
SELF="$HERE/$(basename "$0")"
ORPHAN_AGE_S="${GASCITY_MBP_SLOT_MAX_AGE_S:-14400}"   # a mesma idade em que o mbp-run.sh do mini recolhe um slot (4 h)

if [ ! -r "$LIB" ]; then echo "gascity-mbp: biblioteca de presença ausente ($LIB) — rode no mini: scripts/mbp-offload.sh install-mbp" >&2; exit 97; fi
PRESENCE_LIB_ONLY=1
# shellcheck disable=SC1090
. "$LIB"

ago() { local s=$1; if [ "$s" -lt 60 ]; then echo "${s} s"; elif [ "$s" -lt 3600 ]; then echo "$((s / 60)) min"; else echo "$((s / 3600)) h $(((s % 3600) / 60)) min"; fi; }

# tarefas do Gas City neste MBP: "<slot>|<descrição>|<há quanto tempo>|<órfão 0/1>"; uma linha por pasta de slot. O MBP não sabe se o
# processo do mini ainda vive; slot mais velho que ORPHAN_AGE_S (a idade em que o mini o recolhe) é listado como "provável órfão" e
# NÃO entra na contagem — contar tarefa morta como "rodando" seria mentir na barra de menu.
tasks() {
  local d n info owner e now orphan age; now=$(date +%s)
  for d in "$SLOTS"/*/; do
    [ -d "$d" ] || continue
    n=${d%/}; n=${n##*/}
    owner=$(cat "$d/owner" 2>/dev/null | tr -d ' |\n'); e=${owner##*:}   # cat, não `< arquivo`: o erro de um redirecionamento que falha sai ANTES do 2>/dev/null
    info=$(cat "$d/info" 2>/dev/null | tr '\n|' '  ' | cut -c1-120)
    case "$e" in ''|*[!0-9]*) e="" ;; esac
    orphan=0; age=""
    if [ -n "$e" ]; then age=$(ago $((now - e))); [ $((now - e)) -gt "$ORPHAN_AGE_S" ] && orphan=1; fi
    echo "$n|${info:-sem descrição}|$age|$orphan"
  done
}
live_count() { printf '%s\n' "$1" | awk -F'|' 'NF >= 4 && $4 == 0 { n++ } END { print n + 0 }'; }
print_tasks() { # $1 = prefixo de cada linha
  printf '%s\n' "$2" | while IFS='|' read -r sl inf age orph; do
    [ -n "$sl" ] || continue
    echo "$1slot $sl: $inf${age:+ (há $age)}$([ "$orph" = 1 ] && echo ' [provável órfão: mais de 4 h, não conta]')"
  done
}

why_text() {
  case "$1" in
    bloqueada) echo "tela bloqueada" ;;
    ocioso) echo "sem teclado/mouse há ${2:-?} s" ;;
    input_recente) echo "teclado/mouse há ${2:-?} s" ;;
    tela_em_uso) echo "um app segura a tela acesa (chamada/vídeo/apresentação), mesmo sem teclado/mouse há ${2:-?} s" ;;
    forcado) echo "forçado" ;;
    ilegivel:*) echo "não consegui ler a presença: por segurança conta como em uso" ;;
    *) echo "$1" ;;
  esac
}

cmd=${1:-status}
case "$cmd" in
  pausar|pause)
    mkdir -p "$GT" && printf 'origem=mbp desde=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$PRESENCE_PAUSE_FILE" || { echo "gascity-mbp: não consegui gravar $PRESENCE_PAUSE_FILE" >&2; exit 1; }
    echo "Gas City PAUSADO neste MBP: nada novo começa; o que já roda cai para prioridade de fundo em até ~5 s. Para liberar: gascity-mbp liberar" ;;
  liberar|resume)
    rm -f "$PRESENCE_PAUSE_FILE"
    if [ -e "$PRESENCE_PAUSE_FILE" ]; then echo "gascity-mbp: NÃO consegui apagar $PRESENCE_PAUSE_FILE" >&2; exit 1; fi
    echo "Gas City LIBERADO neste MBP: volta a usar conforme você está (tela bloqueada = carga alta; você aqui = no máximo 1 tarefa, em fundo)" ;;
  status)
    presence_eval
    if [ "$PR_PAUSED" = 1 ]; then echo "Gas City: PAUSADO ($(presence_pause_info)) — nada novo começa neste MBP"
    elif [ "$PR_MODE" = livre ]; then echo "Gas City: LIVRE — você está fora ($(why_text "$PR_WHY" "$PR_IDLE")); o Gas City pode usar o MBP com carga alta"
    else echo "Gas City: EM USO — tratado como \"você está no MBP\" ($(why_text "$PR_WHY" "$PR_IDLE")); no máximo 1 tarefa por vez, em prioridade de fundo"; fi
    t=$(tasks); n=$(live_count "$t")
    echo "Tarefas do Gas City rodando aqui: $n"
    print_tasks "  " "$t"
    echo "Controle: gascity-mbp pausar | liberar" ;;
  menubar)
    presence_eval
    t=$(tasks); n=$(live_count "$t")
    if [ "$PR_PAUSED" = 1 ]; then echo "⏸ Gas City: pausado"
    elif [ "$PR_MODE" = livre ]; then echo "🟢 Gas City: $n"
    else echo "🟠 Gas City: $n"; fi
    echo "---"
    if [ "$PR_PAUSED" = 1 ]; then echo "PAUSADO por você — nada novo começa"
    elif [ "$PR_MODE" = livre ]; then echo "Livre: você está fora ($(why_text "$PR_WHY" "$PR_IDLE"))"
    else echo "Em uso: tratado como \"você está aqui\" ($(why_text "$PR_WHY" "$PR_IDLE")) — no máximo 1 tarefa, em fundo"; fi
    echo "Tarefas do Gas City neste MBP: $n"
    print_tasks "-- " "$t"
    echo "---"
    echo "Pausar até eu liberar | bash=$SELF param1=pausar terminal=false refresh=true"
    echo "Liberar | bash=$SELF param1=liberar terminal=false refresh=true" ;;
  -h|--help|help) sed -n '2,/^[^#]/{/^#/p;}' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "uso: gascity-mbp status|pausar|liberar|menubar" >&2; exit 2 ;;
esac
