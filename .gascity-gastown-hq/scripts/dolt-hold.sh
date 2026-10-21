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
#   ⚠️ Hold sobre um Dolt SAUDÁVEL (depois do patch no ar) também não é silencioso: o `start` recusa
#   mesmo com o Dolt de pé, sai 1, e o launchd (KeepAlive SuccessfulExit=false) relança o launcher a cada
#   ~10 s, uma linha em .gc/logs/dolt-server-launchd.err por vez, até o hold sair ou vencer. O Dolt não
#   é tocado. Para um hold longo sobre Dolt de pé, dê bootout no job (como o hqswap.sh) em vez de deixá-lo em laço.
#
# VALIDADE: `on` sem --ttl-secs vale 2 h (7200 s); o teto é 12 h (43200 s) a não ser com --no-expiry,
#   que é uma escolha explícita. Hold esquecido = banco de dados da cidade parado: por isso a
#   validade é o padrão, e vencida ela SOLTA (os guards e o engine tratam como sem hold). Para
#   estender, `off` e `on` de novo. Um hold que não dá para ler SEGURA (veja dolt-hold-lib.sh).
#   Zero à esquerda em --ttl-secs é decimal ("07200" = 7200 s). --ttl-secs e --no-expiry se excluem.
#   Os DOIS leitores (o do shell e o do Go) leem só os 4096 primeiros bytes do arquivo; o que estiver
#   além disso não existe para eles. Por isso --reason (até 1000 bytes) e --owner (até 200) têm teto,
#   a validade é gravada ANTES deles, e a conferência depois de gravar relê exatamente esses 4096 bytes.
#
# O `on` NUNCA APAGA NADA: ele publica com `ln`, que falha se o destino existe. Um hold vencido que ficou lá
#   para os guards já está solto, mas o `on` recusa (exit 3) e manda rodar `off`; quem tira arquivo é o `off`.
#   Por isso, com duas chamadas de `on` ao mesmo tempo: destino ausente → uma ganha (exit 0) e a outra recusa
#   (exit 3) sem tocar no hold da primeira; vencido no lugar → as duas recusam (exit 3) e o arquivo não muda.
#   (Medido: 60 rodadas de cada.)
#
# SAÍDAS: 0 ok (status: 0 = há hold em vigor); 1 (status: sem hold ou vencido); 2 uso errado (inclui
#   texto acima do teto e opções que se contradizem); 3 `on` recusado porque já há um hold em vigor, ou
#   porque outro apareceu enquanto este era preparado/gravado (não sobrescreve nem apaga o de outro), ou
#   porque há um hold VENCIDO no lugar (rode `off`);
#   4 não consegui gravar/apagar o arquivo, ler o relógio, medir o texto ou conferir o efeito (`on`: o
#   arquivo não é lido como hold em vigor, não consegui relê-lo, ou a validade que o leitor vê não é a
#   pedida; `off`: o hold continua em vigor depois do comando — inclusive quando ele existe mas a pasta
#   não deixa vê-lo).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
_DH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=dolt-hold-lib.sh
source "$_DH_DIR/dolt-hold-lib.sh"

DEFAULT_TTL_SECS=7200
MAX_TTL_SECS=43200
# Tetos de texto livre, em BYTES. Com o cabeçalho, created_at e expires_at o arquivo fica perto de 1,4 KiB no
# pior caso, bem abaixo dos 4096 bytes que os leitores leem.
MAX_REASON_BYTES=1000
MAX_OWNER_BYTES=200
HOLD_READ_BYTES=4096   # igual a dolt_hold_blocks (head -c) e a managedDoltHoldReadLimit do Go

usage() {
  cat >&2 <<'USAGE'
uso: dolt-hold.sh on --reason "texto" [--owner NOME] [--ttl-secs N | --no-expiry]
     dolt-hold.sh off
     dolt-hold.sh status
USAGE
  exit 2
}

# O valor de uma opção não pode ser OUTRA opção: `--reason --no-expiry` engolia a opção como texto e gravava
# um hold com validade (o contrário do pedido). Valor vazio segue para a checagem de cada opção.
opt_value() {
  case "$2" in
    --*) echo "dolt-hold: $1 precisa de um valor, não de outra opção (veio '$2')" >&2; exit 2 ;;
  esac
}

# byte_len <texto> — imprime o tamanho em BYTES (LC_ALL=C: 'ã' são 2). Retorna 1 se não deu para medir; quem
# chama RECUSA nesse caso. "Não consegui medir" nunca vale "cabe".
byte_len() {
  local n
  # vazio → 0 (printf '%s' "" | wc -c); falhou/ilegível → retorna 1 e o chamador recusa (nada é gravado)
  n=$(printf '%s' "$1" | LC_ALL=C wc -c 2>/dev/null) || return 1
  n=${n//[[:space:]]/}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

# first_expires <texto> — imprime o valor do PRIMEIRO "expires_at=" das linhas de <texto> (nada, se não houver).
# Só builtins do bash: um sed|head que falhasse devolveria "" e, com --no-expiry, "" é justamente o esperado.
first_expires() {
  local line
  while IFS= read -r line; do
    case "$line" in expires_at=*) printf '%s\n' "${line#expires_at=}"; return 0 ;; esac
  done <<EOF_EXP
$1
EOF_EXP
  return 0
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
    # `-e`/`-h` dão FALSO para um arquivo que existe quando a pasta-mãe não tem permissão de busca (o lib
    # trata isso como "não consegui saber -> SEGURA", e o status acerta). Por isso "não vejo o arquivo"
    # NÃO basta para dizer "sem hold": o efeito é conferido com o mesmo leitor, nos dois caminhos.
    removed=0
    if [ -e "$HOLD_FILE" ] || [ -h "$HOLD_FILE" ]; then
      rm -f -- "$HOLD_FILE" || { echo "dolt-hold: não consegui apagar $HOLD_FILE" >&2; exit 4; }
      if [ -e "$HOLD_FILE" ] || [ -h "$HOLD_FILE" ]; then
        echo "dolt-hold: $HOLD_FILE continua lá depois do rm" >&2
        exit 4
      fi
      removed=1
    fi
    if dolt_hold_city_blocks "$CITY"; then
      echo "dolt-hold: o hold continua em vigor e este comando não conseguiu tirá-lo — $DOLT_HOLD_MESSAGE" >&2
      exit 4
    fi
    if [ "$removed" -eq 0 ]; then
      echo "sem hold ($HOLD_FILE não existe); nada a tirar"
      exit 0
    fi
    echo "hold removido ($HOLD_FILE). O Dolt NÃO foi iniciado por este comando: o launchd com.gastown.dolt-server o sobe em ~10 s, ou rode 'gc dolt start'."
    exit 0
    ;;

  on)
    reason="" owner="${GC_ALIAS:-${GC_SESSION_NAME:-${USER:-desconhecido}}}" ttl="$DEFAULT_TTL_SECS" no_expiry=0 ttl_given=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason)    [ $# -ge 2 ] || usage; opt_value --reason "$2"; reason="$2"; shift 2 ;;
        --owner)     [ $# -ge 2 ] || usage; opt_value --owner "$2"; owner="$2"; shift 2 ;;
        --ttl-secs)  [ $# -ge 2 ] || usage; opt_value --ttl-secs "$2"; ttl="$2"; ttl_given=1; shift 2 ;;
        --no-expiry) no_expiry=1; shift ;;
        *) usage ;;
      esac
    done
    if [ "$no_expiry" -eq 1 ] && [ "$ttl_given" -eq 1 ]; then
      echo "dolt-hold: --ttl-secs e --no-expiry se excluem (quem digitou uma validade não quer um hold sem fim)" >&2
      exit 2
    fi
    [ -n "$reason" ] || { echo "dolt-hold: --reason é obrigatório (quem ver o hold precisa saber o porquê)" >&2; exit 2; }
    case "$ttl" in ''|*[!0-9]*) echo "dolt-hold: --ttl-secs tem de ser um inteiro positivo" >&2; exit 2 ;; esac
    # Zero à esquerda é decimal para o `[ -gt ]` que valida abaixo mas OCTAL na aritmética que grava
    # ($((now + 07200)) = +3712 s; "08" estoura). Tirar os zeros AQUI, uma vez, por texto (sem
    # aritmética: nada de octal nem de estouro) faz o valor validado ser o mesmo que é gravado.
    ttl="${ttl#"${ttl%%[!0]*}"}"
    [ -n "$ttl" ] || ttl=0
    [ "$ttl" -gt 0 ] 2>/dev/null || { echo "dolt-hold: --ttl-secs tem de ser um inteiro positivo" >&2; exit 2; }
    if [ "$no_expiry" -eq 0 ] && [ "$ttl" -gt "$MAX_TTL_SECS" ]; then
      echo "dolt-hold: --ttl-secs acima de ${MAX_TTL_SECS}s (12 h); para segurar mais use --no-expiry de propósito" >&2
      exit 2
    fi
    # uma quebra de linha no texto viraria outra chave do arquivo (reason="x\nexpires_at=1"). Substituição do
    # próprio bash, não `tr`: um `tr` que falhasse devolveria texto VAZIO, depois de --reason já ter sido exigido.
    reason=${reason//$'\r'/ }; reason=${reason//$'\n'/ }
    owner=${owner//$'\r'/ }; owner=${owner//$'\n'/ }
    # Teto de texto livre: os leitores só veem os 4096 primeiros bytes do arquivo. Não medir = recusar.
    reason_len=$(byte_len "$reason") || { echo "dolt-hold: não consegui medir o texto de --reason (wc); recusado, nada foi gravado" >&2; exit 4; }
    owner_len=$(byte_len "$owner") || { echo "dolt-hold: não consegui medir o texto de --owner (wc); recusado, nada foi gravado" >&2; exit 4; }
    if [ "$reason_len" -gt "$MAX_REASON_BYTES" ]; then
      echo "dolt-hold: --reason tem $reason_len bytes; o máximo é $MAX_REASON_BYTES (os leitores só leem os $HOLD_READ_BYTES primeiros bytes do arquivo)" >&2
      exit 2
    fi
    if [ "$owner_len" -gt "$MAX_OWNER_BYTES" ]; then
      echo "dolt-hold: --owner tem $owner_len bytes; o máximo é $MAX_OWNER_BYTES" >&2
      exit 2
    fi

    # Sem hold → pode pôr. Hold em vigor (ou ilegível, que segura) → recusa: o de outra pessoa não se
    # sobrescreve; quem quer trocar faz `off` antes, sabendo que é dele. (Vencido no lugar: veja abaixo.)
    if dolt_hold_city_blocks "$CITY"; then
      echo "dolt-hold: já há um hold em vigor — $DOLT_HOLD_MESSAGE" >&2
      echo "dolt-hold: recusado. Se for seu, 'dolt-hold.sh off' e ponha de novo." >&2
      exit 3
    fi
    # O leitor diz "solto" e ainda assim há um arquivo no destino: é um hold VENCIDO. Para os guards ele já está
    # solto, mas o `on` NÃO o apaga: apagar o arquivo de outro é o ato que não se desfaz (se um hold válido
    # chegasse entre a leitura e o rm, ele iria junto), e `ln` só publica em destino ausente. Quem tira é o `off`.
    expired_in_place() {
      echo "dolt-hold: há um hold VENCIDO em $HOLD_FILE; o on não apaga arquivo de ninguém." >&2
      echo "dolt-hold: recusado. Tire-o com 'dolt-hold.sh off' e ponha o novo." >&2
      exit 3
    }
    if [ -e "$HOLD_FILE" ] || [ -h "$HOLD_FILE" ]; then expired_in_place; fi

    # O temporário some em qualquer saída entre o mktemp e a publicação: erro, recusa e também TERM/INT/HUP (o bash
    # roda o trap de EXIT quando um sinal o mata; conferido no 5.3 e no /bin/bash 3.2 do launchd). kill -9 não dá
    # para tratar: sobra um .dolt-hold.XXXXXX ao lado do hold, que nenhum leitor lê (só "dolt-hold" conta).
    tmp=""
    trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT

    # relógio ilegível → recusa (nada gravado); lido → só dígitos. Sem `now` não há created_at nem validade.
    now=$(date +%s 2>/dev/null)
    case "$now" in ''|*[!0-9]*) echo "dolt-hold: não consegui ler o relógio (date +%s); recusado, nada foi gravado" >&2; exit 4 ;; esac
    # a validade é calculada ANTES de criar o temporário: nenhuma falha de conta pode deixá-lo para trás
    expires=""
    if [ "$no_expiry" -eq 0 ]; then expires=$((now + ttl)); fi
    hold_dir=$(dirname "$HOLD_FILE")
    mkdir -p "$hold_dir" 2>/dev/null || { echo "dolt-hold: não consegui criar $hold_dir" >&2; exit 4; }
    tmp=$(mktemp "$hold_dir/.dolt-hold.XXXXXX") || { tmp=""; echo "dolt-hold: não consegui criar um arquivo temporário em $hold_dir" >&2; exit 4; }
    {
      echo "# colocado por dolt-hold.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ) (ga-3risy2); tirar: dolt-hold.sh off"
      echo "created_at=$now"
      # A validade vem ANTES do texto livre: o que passar dos $HOLD_READ_BYTES bytes não existe para os leitores.
      if [ -n "$expires" ]; then echo "expires_at=$expires"; fi
      echo "owner=$owner"
      echo "reason=$reason"
    } > "$tmp" || { echo "dolt-hold: não consegui escrever $tmp" >&2; exit 4; }
    chmod 644 "$tmp" 2>/dev/null || true
    # Publicar SEM sobrescrever e SEM apagar nada: `ln` falha se o destino existe, e é a única coisa que o `on`
    # faz com ele (o `mv -f` trocava em silêncio o hold que outro `on` pôs entre a checagem acima e esta
    # gravação; um `rm` antes do `ln` apagava o hold válido que chegasse depois da leitura). Com o destino
    # ausente, de dois `on` ao mesmo tempo um publica e o outro cai aqui: o que chegou lá é o hold de outro
    # (exit 3, ele fica como está) ou um vencido (exit 3, manda rodar `off`); nada disso (exit 4).
    if ! ln -- "$tmp" "$HOLD_FILE" 2>/dev/null; then
      if dolt_hold_city_blocks "$CITY"; then
        echo "dolt-hold: outro hold apareceu enquanto este era gravado — $DOLT_HOLD_MESSAGE" >&2
        echo "dolt-hold: recusado; o hold dele ficou como estava." >&2
        exit 3
      fi
      if [ -e "$HOLD_FILE" ] || [ -h "$HOLD_FILE" ]; then expired_in_place; fi
      echo "dolt-hold: não consegui gravar $HOLD_FILE" >&2
      exit 4
    fi
    rm -f -- "$tmp"; tmp=""

    # confere o efeito, não o retorno: o arquivo gravado tem de ser lido como hold em vigor...
    if ! dolt_hold_city_blocks "$CITY"; then
      echo "dolt-hold: gravei $HOLD_FILE mas ele NÃO é lido como hold em vigor ($DOLT_HOLD_MESSAGE) — não confie nele" >&2
      exit 4
    fi
    # ...e com a MESMA validade que foi pedida, lida pelos MESMOS bytes que o leitor vê (os $HOLD_READ_BYTES
    # primeiros): uma validade curta demais ainda "segura", então só o valor denuncia (foi assim que o octal
    # passou), e uma validade além do que o leitor lê deixa o hold sem fim com a leitura do arquivo inteiro
    # dizendo que está tudo certo. Sem validade pedida (--no-expiry) o esperado é "nenhuma".
    # vazio → sem expires_at nesses bytes (só confere com --no-expiry); falhou/ilegível → exit 4, nunca "sem validade"
    seen=$(LC_ALL=C head -c "$HOLD_READ_BYTES" "$HOLD_FILE" 2>/dev/null) || {
      echo "dolt-hold: gravei $HOLD_FILE mas não consegui relê-lo para conferir a validade — não confie nele (tire com 'dolt-hold.sh off')" >&2
      exit 4
    }
    got=$(first_expires "$seen")
    if [ "$got" != "$expires" ]; then
      echo "dolt-hold: pedi validade ${expires:-nenhuma} mas o leitor vê '${got:-nenhuma}' em $HOLD_FILE — não confie nele (tire com 'dolt-hold.sh off')" >&2
      exit 4
    fi
    echo "HOLD posto: $DOLT_HOLD_MESSAGE"
    echo "Agora pare o Dolt se for o caso ('gc-beads-bd.sh stop'). Tirar: dolt-hold.sh off"
    exit 0
    ;;

  *) usage ;;
esac
