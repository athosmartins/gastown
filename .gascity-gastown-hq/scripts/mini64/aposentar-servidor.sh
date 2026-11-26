#!/bin/bash
# aposentar-servidor.sh — aposenta o servidor ANTIGO (mini 16) na noite do corte, sem volta acidental (ga-ke5w2ie.4, Mini64 fatia 4).
# Risco no 1 do epico: dois servidores vivos = WhatsApp em dobro, Dolt divergente, backup S3 sobrescrito pela maquina errada; e o launchd recarrega no
# login tudo o que nao estiver DESABILITADO. Runbook: docs/runbooks/mini64/04-aposentar.md. Rotulos: aposentar-camadas.tsv (por NOME de camada, como o da .2).
#   plano     (padrao) so lista: nao chama o launchctl nem escreve nada. Pode rodar a qualquer hora, no mini de verdade
#   aplicar   grava o marcador ~/.servidor-aposentado, depois `launchctl disable` + `bootout` de cada rotulo, e CONFERE o efeito. So na noite do corte, pelo Mayor
#   conferir  so leitura: depois de um reboot, nada voltou?
#   desfazer  o inverso; SO com --sim-tenho-certeza (religar o antigo depois do go = WhatsApp em dobro)
# rc: 0 ok · 2 uso errado ou config invalida (nada foi alterado) · 4 pendencia ([FALHA], [NAO SEI] ou plist ilegivel; no aplicar o marcador ja foi gravado) · 6 so faltam
# os passos com sudo (impressos: o script NUNCA roda sudo).  ENV (so os testes): LAUNCHCTL_BIN APOSENTAR_UID APOSENTAR_PYTHON APOSENTAR_AGENTS_DIR
# APOSENTAR_CAMADAS_TSV SERVIDOR_APOSENTADO_FILE (o MESMO caminho que os scripts de backup para o S3 checam).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"; PY="${APOSENTAR_PYTHON:-python3}"; UID_ALVO="${APOSENTAR_UID:-$(id -u)}"
AGENTS_DIR="${APOSENTAR_AGENTS_DIR:-${HOME:-}/Library/LaunchAgents}"; MARCADOR="${SERVIDOR_APOSENTADO_FILE:-${HOME:-}/.servidor-aposentado}"
TSV="${APOSENTAR_CAMADAS_TSV:-$HERE/aposentar-camadas.tsv}"; TAB="$(printf '\t')"
say() { printf '%s\n' "$*"; }
die() { printf 'aposentar-servidor: %s\n' "$*" >&2; exit 2; }
usage() { echo "uso: aposentar-servidor.sh [plano | aplicar | conferir | desfazer --sim-tenho-certeza]" >&2; }

MODO=plano; CERTEZA=0
case "${1:-}" in plano|aplicar|conferir|desfazer) MODO="$1"; shift ;; -h|--help) usage; exit 0 ;; "") ;; *) usage; die "modo desconhecido: $1" ;; esac
for a in "$@"; do case "$a" in --sim-tenho-certeza) CERTEZA=1 ;; *) usage; die "opcao desconhecida: $a" ;; esac; done
[ "$CERTEZA" = 1 ] && [ "$MODO" != desfazer ] && die "--sim-tenho-certeza so vale para o modo desfazer"
# a recusa vem ANTES de ler qualquer coisa: sem a flag nada e lido nem tocado
[ "$MODO" = desfazer ] && [ "$CERTEZA" != 1 ] && die "desfazer RECUSADO: reativar o servidor antigo depois do go religa o envio de WhatsApp (em dobro com o novo), a escrita no Dolt de producao e o backup para o S3 (sobrescrito pela maquina errada). So ANTES do go, e so com --sim-tenho-certeza."
[ -n "${HOME:-}" ] || die "HOME vazio: nao sei onde ficam os LaunchAgents nem o marcador"

# ── leitura: a lista + os plists, classificados pelo helper ──────────────────────────────────────────────────────────────────────
kind() { printf '%s\n' "$CLASS" | awk -F'\t' -v k="$1" '$1 == k {print substr($0, length(k) + 2)}'; }
conta() { printf '%s\n' "$1" | awk 'NF {n++} END {print n + 0}'; }
carregar() {
  command -v "$PY" >/dev/null 2>&1 || [ -x "$PY" ] || die "nao achei o interpretador python ($PY; APOSENTAR_PYTHON): sem ele nao leio os plists, entao nao aposento nada"
  # vazio → o helper recusa lista sem regra (rc 2); falhou/ilegivel (lista ou diretorio invalidos) → rc 2 aqui e nada e feito
  CLASS="$("$PY" -I "$HERE/aposentar-classifica.py" --tsv "$TSV" --agents-dir "$AGENTS_DIR" 2>&1)" || { printf '%s\n' "$CLASS" >&2; exit 2; }
  ALVOS="$(kind ALVO)"; MANTIDOS="$(kind MANTER)"; LIVRES="$(kind LIVRE)"; ILEGIVEIS="$(kind ILEGIVEL)"; CAMADAS="$(kind CAMADA | tr '\n' ' ')"
  IFS="$TAB" read -r N_LIDOS N_ILEG N_QUEB N_FORA <<EOF
$(kind PLISTS)
EOF
  # vazio (diretorio sem nenhum .plist) → recusa: num servidor de verdade isso e HOME ou caminho errado, nunca "nada a aposentar"
  [ $((N_LIDOS + N_ILEG + N_QUEB)) -gt 0 ] || die "nenhum plist em $AGENTS_DIR: HOME ou APOSENTAR_AGENTS_DIR errado?"
  # vazio (nenhuma regra 'aposentar' casa com plist nenhum) → recusa: aplicar sem alvo gravaria o marcador e diria "tudo conferido"
  [ -n "$ALVOS" ] || die "nenhum rotulo a aposentar: nenhuma regra 'aposentar' de $TSV casa com os plists de $AGENTS_DIR"
}
# vazio (sem marcador, pasta legivel) → "ausente"; falhou/ilegivel (pasta sem acesso) → "NAO SEI", nunca "ausente"
estado_marcador() {
  if [ -e "$MARCADOR" ] || [ -L "$MARCADOR" ]; then echo PRESENTE; elif [ -x "$(dirname "$MARCADOR")" ]; then echo ausente; else echo "NAO SEI (a pasta do marcador nao abre)"; fi
}

cmd_plano() {
  carregar
  say "aposentar-servidor: PLANO - nada foi alterado e o launchctl NAO foi chamado."
  say "  LaunchAgents ..... $AGENTS_DIR ($N_LIDOS plists lidos; $N_FORA fora das familias da cidade, ignorados)"
  say "  lista de camadas . $TSV"
  say "  marcador ......... $MARCADOR ($(estado_marcador))"
  say "  uid .............. $UID_ALVO"
  say "== RESUMO (rotulos por camada; a lista completa vem a seguir) =="
  local c; for c in $CAMADAS; do say "  $c: $(printf '%s\n' "$ALVOS" | awk -F'\t' -v c="$c" '$1 == c {n++} END {print n + 0}')"; done
  say "  manter: $(conta "$MANTIDOS")"; say "  ficam rodando: $(conta "$LIVRES")"
  say "== APOSENTAR (ordem em que o aplicar age; linha: [camada] rotulo) =="
  printf '%s\n' "$ALVOS" | awk -F'\t' '$1 != "" {printf "  [%s] %s  (%s%s)\n", $1, $3, ($2 == "system" ? "LaunchDaemon: precisa de sudo, o script NAO roda sudo; " : ($4 == "-" ? "sem plist no disco; o disable vale mesmo assim; " : "")), $5}'
  say "== MANTER (regra 'manter': continuam rodando de proposito) =="
  printf '%s\n' "$MANTIDOS" | awk -F'\t' '$1 != "" {printf "  [%s] %s  (%s)\n", $1, $2, $4}'
  say "== FICAM RODANDO (da familia da cidade e SEM regra nenhuma: confira se algum envia, ingere ou sobe backup) =="
  printf '%s\n' "$LIVRES" | awk -F'\t' '$1 != "" {print "  " $1}'
  if [ "$N_ILEG" -gt 0 ] || [ "$N_QUEB" -gt 0 ]; then
    say "== ILEGIVEIS (plists que nao deu para classificar) =="
    printf '%s\n' "$ILEGIVEIS" | awk -F'\t' '$1 != "" {print "  NAO SEI o que e: " $1 " (" $2 "): confira a mao; o aplicar termina com rc 4 por causa disso"}'
    kind QUEBRADO | awk -F'\t' '$1 != "" {print "  link quebrado (o launchd nao o carrega): " $1 " -> " $2}'
  fi
  say "== O QUE O APLICAR FARIA =="
  say "  1. gravar o marcador $MARCADOR (os scripts de backup para o S3 recusam subir enquanto ele existir)"
  say "  2. para cada rotulo gui de APOSENTAR: launchctl disable gui/$UID_ALVO/<rotulo> ; launchctl bootout gui/$UID_ALVO/<rotulo>"
  say "  3. conferir o efeito (launchctl list; print-disabled): carregado, habilitado ou 'nao sei' = FALHA, rc 4"
  say "  4. passos com sudo, que VOCE roda:"
  printf '%s\n' "$ALVOS" | awk -F'\t' '$2 == "system" {print "       sudo launchctl bootout system/" $3; print "       sudo launchctl disable system/" $3}'
}

# ── marcador: gravado PRIMEIRO pelo aplicar (se algo falhar depois o estado que fica e o inerte); escrita atomica ────────────────────
# vazio → (ja existe) nao regrava, o 1o carimbo vale; falhou (pasta inexistente ou sem escrita) → rc 1 e o aplicar para ANTES de tocar no launchd
gravar_marcador() {
  [ -e "$MARCADOR" ] || [ -L "$MARCADOR" ] && return 0
  local tmp="$MARCADOR.tmp.$$"
  { echo "servidor-aposentado=1"; echo "aposentado_em=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "host=$(hostname -s 2>/dev/null || echo ?)"; echo "usuario=$(id -un 2>/dev/null || echo ?)"
    echo "camadas=${CAMADAS% }"; echo "desfazer=bash scripts/mini64/aposentar-servidor.sh desfazer --sim-tenho-certeza   (so antes do go)"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$MARCADOR" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# ── o que o launchctl diz: TRES estados (como no nightly-reboot-postcheck), nunca dois ───────────────────────────────────────────────
# so "Could not find service" prova "descarregado" e so um dicionario com "Label" prova "carregado"; o resto (erro de XPC, rc 0 sem dicionario) e nao-sei
estado_carga() {
  local out rc; out="$("$LAUNCHCTL_BIN" list "$1" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then case "$out" in *"Could not find service"*) echo descarregado ;; *) echo "nao-sei: list saiu rc=$rc" ;; esac; return 0; fi
  case "$out" in *'"Label"'*) echo carregado ;; *) echo "nao-sei: list saiu rc 0 sem o dicionario do job" ;; esac
}
# uma chamada de print-disabled por dominio. vazio (a lista nao tem o rotulo) → "sem-override" (o disable nao pegou); falhou/ilegivel → nao-sei para TODOS
ler_desabilitados() {
  PD_OUT="$("$LAUNCHCTL_BIN" print-disabled "$1" 2>&1)" && case "$PD_OUT" in *"disabled services"*) PD_OK=1 ;; *) PD_OK=0 ;; esac || PD_OK=0
}
estado_desabilitado() {   # <rotulo>: desabilitado | habilitado | sem-override | nao-sei
  [ "$PD_OK" = 1 ] || { echo nao-sei; return 0; }
  case "$(printf '%s\n' "$PD_OUT" | grep -F "\"$1\" =>" | head -1)" in
    *"=> disabled"*|*"=> true"*) echo desabilitado ;; *"=> enabled"*|*"=> false"*) echo habilitado ;; "") echo sem-override ;; *) echo nao-sei ;;
  esac
}
# <retirado|religado> <rotulo> <arquivo|->  →  "ok|FALHA|NAO SEI<TAB>detalhe". Prova de FALHA vale mesmo com o resto nao-sei.
veredito() {
  local c d; c="$(estado_carga "$2")"; d="$(estado_desabilitado "$2")"
  if [ "$1" = retirado ]; then
    [ "$c" = carregado ] && { printf 'FALHA\tainda CARREGADO (o bootout nao o descarregou)\n'; return 0; }
    case "$d" in habilitado|sem-override) printf 'FALHA\tdescarregado, mas NAO desabilitado (%s): volta no proximo login ou reboot\n' "$d"; return 0 ;; esac
    [ "$c" = descarregado ] && [ "$d" = desabilitado ] && { printf 'ok\tdescarregado e desabilitado\n'; return 0; }
  else
    [ "$d" = desabilitado ] && { printf 'FALHA\tainda DESABILITADO (o enable nao pegou)\n'; return 0; }
    [ "$c" = descarregado ] && [ "$3" != "-" ] && { printf 'FALHA\thabilitado mas NAO carregou (o bootstrap falhou?): rode o desfazer de novo\n'; return 0; }
    case "$c:$d" in carregado:habilitado|carregado:sem-override|descarregado:habilitado|descarregado:sem-override) printf 'ok\tcarregado e habilitado (ou sem plist: nada a carregar)\n'; return 0 ;; esac
  fi
  printf 'NAO SEI\tlist: %s; print-disabled: %s\n' "${c#nao-sei: }" "$d"
}

# conferencia <retirado|religado>: imprime a secao e deixa CONF_RUIM (FALHA/NAO SEI/plist ilegivel), CONF_PEND (passos com sudo) e CONF_SUDO.
# "retirado" = o que o aplicar deixa (marcador la, rotulos descarregados E desabilitados); "religado" = o que o desfazer deixa.
conferencia() {
  local m="$1" cam dom rot arq regra v e; CONF_RUIM=0; CONF_PEND=0; CONF_SUDO=""
  say "== CONFERENCIA =="
  case "$(estado_marcador):$m" in PRESENTE:retirado|ausente:religado) e=ok ;; NAO*) e="NAO SEI" ;; *) e=FALHA ;; esac
  printf '  [%s] marcador %s  %s\n' "$e" "$MARCADOR" "$(estado_marcador)"; [ "$e" = ok ] || CONF_RUIM=$((CONF_RUIM + 1))
  ler_desabilitados "gui/$UID_ALVO"
  while IFS="$TAB" read -r cam dom rot arq regra; do
    [ "$dom" = gui ] || continue
    v="$(veredito "$m" "$rot" "$arq")"; printf '  [%s] %s  %s\n' "${v%%"$TAB"*}" "$rot" "${v#*"$TAB"}"; [ "${v%%"$TAB"*}" = ok ] || CONF_RUIM=$((CONF_RUIM + 1))
  done <<EOF
$ALVOS
EOF
  [ "$m" = retirado ] && ler_desabilitados system
  while IFS="$TAB" read -r cam dom rot arq regra; do
    [ "$dom" = system ] || continue
    # o dominio system e de root: sem root a leitura pode falhar e ai NAO SEI, nunca ok. Carregado ou nao: sem root nao da para ver
    if [ "$m" = religado ]; then e=PENDENTE; v="o script nao liga LaunchDaemon: rode os comandos com sudo abaixo"
    else case "$(estado_desabilitado "$rot")" in
      desabilitado) e=ok; v="desabilitado no dominio system" ;;
      habilitado|sem-override) e=PENDENTE; v="ainda nao desabilitado: rode os comandos com sudo abaixo" ;;
      *) e="NAO SEI"; v="print-disabled system nao respondeu sem root: sudo launchctl print-disabled system | grep $rot" ;; esac; fi
    printf '  [%s] %s  %s\n' "$e" "$rot" "$v"; [ "$e" = ok ] || { CONF_PEND=$((CONF_PEND + 1)); CONF_SUDO="$CONF_SUDO$rot "; }
  done <<EOF
$ALVOS
EOF
  # plist que nao deu para ler pode ser justamente o que envia: pendencia (rc 4). Link quebrado nao: o launchd nao o carrega
  while IFS="$TAB" read -r arq v; do [ -n "$arq" ] || continue; printf '  [NAO SEI] %s  nao sei o que e (%s): confira a mao\n' "$arq" "$v"; CONF_RUIM=$((CONF_RUIM + 1)); done <<EOF
$ILEGIVEIS
EOF
}
fim() {   # <retirado|religado>: os passos com sudo que ficaram e o RESULTADO (rc 4 pendencia · 6 so faltam os passos com sudo · 0 tudo)
  local r o="aposentado"; [ "$1" = religado ] && o="religado"
  if [ -n "$CONF_SUDO" ]; then
    say "== PASSOS COM SUDO (voce roda; o script NAO roda sudo) =="
    for r in $CONF_SUDO; do
      if [ "$1" = retirado ]; then say "  sudo launchctl bootout system/$r"; say "  sudo launchctl disable system/$r"
      else say "  sudo launchctl enable system/$r"; say "  sudo launchctl bootstrap system /Library/LaunchDaemons/$r.plist"; fi
    done
  fi
  if [ "$CONF_RUIM" -gt 0 ]; then say "RESULTADO: rc 4 - $CONF_RUIM pendencia(s) acima ([FALHA] ou [NAO SEI]); nao esta provado que o servidor ficou $o."; return 4; fi
  if [ "$CONF_PEND" -gt 0 ]; then say "RESULTADO: rc 6 - tudo o que o script faz sem root esta feito e conferido; faltam os passos com sudo acima."; return 6; fi
  say "RESULTADO: rc 0 - tudo conferido: servidor $o e marcador $([ "$1" = retirado ] && echo no lugar || echo removido)."
}

cmd_aplicar() {
  carregar
  [ -x "$LAUNCHCTL_BIN" ] || die "launchctl nao encontrado ou nao executavel ($LAUNCHCTL_BIN): este script e do macOS; nada foi alterado"
  gravar_marcador || die "nao consegui gravar o marcador $MARCADOR (pasta inexistente ou sem escrita): nada foi alterado"
  say "aposentar-servidor: APLICAR (uid $UID_ALVO). Marcador $MARCADOR gravado ANTES de mexer no launchd."
  local cam dom rot arq regra r1 r2
  while IFS="$TAB" read -r cam dom rot arq regra; do
    [ "$dom" = gui ] || continue
    # disable PRIMEIRO: e ele que persiste no reboot. Um erro nao para o laco (parar o processo vale por si): quem decide e a conferencia
    "$LAUNCHCTL_BIN" disable "gui/$UID_ALVO/$rot" >/dev/null 2>&1; r1=$?
    "$LAUNCHCTL_BIN" bootout "gui/$UID_ALVO/$rot" >/dev/null 2>&1; r2=$?
    say "  [$cam] $rot  disable rc=$r1 bootout rc=$r2"
  done <<EOF
$ALVOS
EOF
  conferencia retirado; fim retirado
}
cmd_conferir() {
  carregar
  # falhou (sem launchctl) → rc 2: "nao conferi" nunca e "esta tudo certo"
  [ -x "$LAUNCHCTL_BIN" ] || die "launchctl nao encontrado ou nao executavel ($LAUNCHCTL_BIN): este script e do macOS"
  say "aposentar-servidor: CONFERIR (so leitura; uid $UID_ALVO)"; conferencia retirado; fim retirado
}
# desfazer: reabilita TUDO primeiro (reabilitar nao carrega nada); so se todos os enable deram certo o marcador sai; ai religa na ordem inversa
# (o envio de WhatsApp por ultimo). So antes do go: depois dele, religar o antigo e mandar WhatsApp em dobro.
cmd_desfazer() {
  carregar
  [ -x "$LAUNCHCTL_BIN" ] || die "launchctl nao encontrado ou nao executavel ($LAUNCHCTL_BIN): este script e do macOS; nada foi alterado"
  say "aposentar-servidor: DESFAZER (uid $UID_ALVO): reabilitando o servidor antigo."
  local cam dom rot arq regra falhas=0 inversa
  while IFS="$TAB" read -r cam dom rot arq regra; do
    [ "$dom" = gui ] || continue
    "$LAUNCHCTL_BIN" enable "gui/$UID_ALVO/$rot" >/dev/null 2>&1 || { falhas=$((falhas + 1)); say "  [$cam] $rot  enable FALHOU"; }
  done <<EOF
$ALVOS
EOF
  [ "$falhas" -eq 0 ] || { say "RESULTADO: rc 4 - $falhas enable falharam: o marcador FICOU em $MARCADOR e NADA foi religado (estado inerte). Corrija e rode o desfazer de novo."; return 4; }
  # o marcador sai ANTES de religar: um backup com RunAtLoad que subisse com ele ainda la seria recusado
  if [ -e "$MARCADOR" ] || [ -L "$MARCADOR" ]; then
    rm -f "$MARCADOR" 2>/dev/null; [ ! -e "$MARCADOR" ] && [ ! -L "$MARCADOR" ] || { say "RESULTADO: rc 4 - nao consegui remover o marcador $MARCADOR; nada foi religado."; return 4; }
    say "  marcador $MARCADOR removido"
  else say "  marcador $MARCADOR ja estava ausente"; fi
  inversa="$(printf '%s\n' "$ALVOS" | awk '{a[NR] = $0} END {for (i = NR; i > 0; i--) print a[i]}')"
  while IFS="$TAB" read -r cam dom rot arq regra; do
    [ "$dom" = gui ] && [ "$arq" != "-" ] || continue
    # o rc do bootstrap nao decide (servico ja carregado devolve erro): a conferencia abaixo diz se carregou
    "$LAUNCHCTL_BIN" bootstrap "gui/$UID_ALVO" "$arq" >/dev/null 2>&1; say "  [$cam] $rot  bootstrap rc=$?"
  done <<EOF
$inversa
EOF
  conferencia religado; fim religado
}

case "$MODO" in plano) cmd_plano ;; aplicar) cmd_aplicar ;; conferir) cmd_conferir ;; desfazer) cmd_desfazer ;; esac
exit $?
