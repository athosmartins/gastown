#!/bin/bash
# dolt-hold.sh (ga-3risy2) — põe, tira e consulta o hold do Dolt gerenciado.
#
# ## Contents
# - Uso · O que o hold faz · Ordem certa · Validade · Códigos de saída
#
# USO
#   dolt-hold.sh on --reason "texto" [--owner NOME] [--ttl-secs N | --no-expiry]
#   dolt-hold.sh off
#   dolt-hold.sh status
#
# O QUE O HOLD FAZ: proíbe SUBIR o Dolt (e matá-lo para subir de novo): o dolt-hang-watchdog, o
#   guard de disco (_resurrect_dolt) e — depois que a janela do engine aplicar o patch
#   docs/pending-engine-window/ga-3risy2-dolt-hold.patch — o tick do controller, o retry do bd,
#   `gc dolt start|restart|recover` e o launchd com.gastown.dolt-server. Ele NÃO para o Dolt: quem
#   põe o hold para o Dolt depois (`gc-beads-bd.sh stop`, como o hqswap.sh faz).
#   ⚠️ ANTES do patch no ar, só os dois guards da cidade respeitam o arquivo; o supervisor, o retry
#   do bd e o launchd ainda religam o Dolt em segundos. Confira com: strings $(readlink -f $(which gc))
#   | grep dolt-hold
#
# ORDEM CERTA: 1) `on`  2) parar o Dolt  3) fazer a troca/GC/ensaio  4) `off`  5) o Dolt volta sozinho
#   em ~10 s (o launchd com.gastown.dolt-server relança `gc dolt start` enquanto o hold existe,
#   sendo recusado a cada vez) — ou suba na hora com `gc dolt start`. Pôr o hold DEPOIS de parar o
#   Dolt é a corrida que este arquivo existe para evitar.
#
# VALIDADE: `on` sem --ttl-secs vale 2 h (7200 s); o teto é 12 h (43200 s) a não ser com --no-expiry,
#   que é uma escolha explícita. Hold esquecido = banco de dados da cidade parado: por isso a
#   validade é o padrão, e vencida ela SOLTA (os guards e o engine tratam como sem hold). Para
#   estender, `off` e `on` de novo. Um hold que não dá para ler SEGURA (veja dolt-hold-lib.sh).
#
# SAÍDAS: 0 ok (status: 0 = há hold em vigor); 1 (status: sem hold ou vencido); 2 uso errado;
#   3 `on` recusado porque já há um hold em vigor (não sobrescreve o de outro); 4 não consegui
#   gravar/apagar o arquivo.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
_DH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=dolt-hold-lib.sh
source "$_DH_DIR/dolt-hold-lib.sh"

DEFAULT_TTL_SECS=7200
MAX_TTL_SECS=43200

usage() {
  cat >&2 <<'USAGE'
uso: dolt-hold.sh on --reason "texto" [--owner NOME] [--ttl-secs N | --no-expiry]
     dolt-hold.sh off
     dolt-hold.sh status
USAGE
  exit 2
}

cmd="${1:-}"
[ -n "$cmd" ] && shift
HOLD_FILE=$(dolt_hold_city_path "$CITY") || { echo "dolt-hold: não sei onde fica o arquivo de hold (sem cidade)" >&2; exit 4; }

case "$cmd" in
  status)
    if dolt_hold_city_blocks "$CITY"; then
      echo "HOLD em vigor: $DOLT_HOLD_MESSAGE"
      exit 0
    fi
    if [ -e "$HOLD_FILE" ]; then
      echo "sem hold: o arquivo $HOLD_FILE existe mas está VENCIDO (apague-o: dolt-hold.sh off)"
    else
      echo "sem hold ($HOLD_FILE não existe)"
    fi
    exit 1
    ;;

  off)
    if [ ! -e "$HOLD_FILE" ] && [ ! -h "$HOLD_FILE" ]; then
      echo "sem hold ($HOLD_FILE não existe); nada a tirar"
      exit 0
    fi
    rm -f -- "$HOLD_FILE" || { echo "dolt-hold: não consegui apagar $HOLD_FILE" >&2; exit 4; }
    if [ -e "$HOLD_FILE" ] || [ -h "$HOLD_FILE" ]; then
      echo "dolt-hold: $HOLD_FILE continua lá depois do rm" >&2
      exit 4
    fi
    echo "hold removido ($HOLD_FILE). O Dolt NÃO foi iniciado por este comando: o launchd com.gastown.dolt-server o sobe em ~10 s, ou rode 'gc dolt start'."
    exit 0
    ;;

  on)
    reason="" owner="${GC_ALIAS:-${GC_SESSION_NAME:-${USER:-desconhecido}}}" ttl="$DEFAULT_TTL_SECS" no_expiry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason)    [ $# -ge 2 ] || usage; reason="$2"; shift 2 ;;
        --owner)     [ $# -ge 2 ] || usage; owner="$2"; shift 2 ;;
        --ttl-secs)  [ $# -ge 2 ] || usage; ttl="$2"; shift 2 ;;
        --no-expiry) no_expiry=1; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$reason" ] || { echo "dolt-hold: --reason é obrigatório (quem ver o hold precisa saber o porquê)" >&2; exit 2; }
    case "$ttl" in ''|*[!0-9]*) echo "dolt-hold: --ttl-secs tem de ser um inteiro positivo" >&2; exit 2 ;; esac
    [ "$ttl" -gt 0 ] 2>/dev/null || { echo "dolt-hold: --ttl-secs tem de ser um inteiro positivo" >&2; exit 2; }
    if [ "$no_expiry" -eq 0 ] && [ "$ttl" -gt "$MAX_TTL_SECS" ]; then
      echo "dolt-hold: --ttl-secs acima de ${MAX_TTL_SECS}s (12 h); para segurar mais use --no-expiry de propósito" >&2
      exit 2
    fi
    # uma quebra de linha no texto viraria outra chave do arquivo (reason="x\nexpires_at=1")
    reason=$(printf '%s' "$reason" | tr '\r\n' '  ')
    owner=$(printf '%s' "$owner" | tr '\r\n' '  ')

    # Sem hold / hold vencido → pode pôr. Hold em vigor (ou ilegível, que segura) → recusa: o de
    # outra pessoa não se sobrescreve; quem quer trocar faz `off` antes, sabendo que é dele.
    if dolt_hold_city_blocks "$CITY"; then
      echo "dolt-hold: já há um hold em vigor — $DOLT_HOLD_MESSAGE" >&2
      echo "dolt-hold: recusado. Se for seu, 'dolt-hold.sh off' e ponha de novo." >&2
      exit 3
    fi

    now=$(date +%s)
    hold_dir=$(dirname "$HOLD_FILE")
    mkdir -p "$hold_dir" 2>/dev/null || { echo "dolt-hold: não consegui criar $hold_dir" >&2; exit 4; }
    tmp=$(mktemp "$hold_dir/.dolt-hold.XXXXXX") || { echo "dolt-hold: não consegui criar um arquivo temporário em $hold_dir" >&2; exit 4; }
    {
      echo "# colocado por dolt-hold.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ) (ga-3risy2); tirar: dolt-hold.sh off"
      echo "created_at=$now"
      echo "owner=$owner"
      echo "reason=$reason"
      if [ "$no_expiry" -eq 0 ]; then echo "expires_at=$((now + ttl))"; fi
    } > "$tmp" || { rm -f -- "$tmp"; echo "dolt-hold: não consegui escrever $tmp" >&2; exit 4; }
    chmod 644 "$tmp" 2>/dev/null || true
    # mv no mesmo diretório é atômico: quem lê vê o hold inteiro ou nenhum
    mv -f -- "$tmp" "$HOLD_FILE" || { rm -f -- "$tmp"; echo "dolt-hold: não consegui gravar $HOLD_FILE" >&2; exit 4; }

    # confere o efeito, não o retorno: o arquivo gravado tem de ser lido como hold em vigor
    if ! dolt_hold_city_blocks "$CITY"; then
      echo "dolt-hold: gravei $HOLD_FILE mas ele NÃO é lido como hold em vigor ($DOLT_HOLD_MESSAGE) — não confie nele" >&2
      exit 4
    fi
    echo "HOLD posto: $DOLT_HOLD_MESSAGE"
    echo "Agora pare o Dolt se for o caso ('gc-beads-bd.sh stop'). Tirar: dolt-hold.sh off"
    exit 0
    ;;

  *) usage ;;
esac
