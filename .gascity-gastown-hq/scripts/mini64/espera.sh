#!/usr/bin/env bash
# espera.sh — a chave de espera da migração para o mini 64 (ga-ke5w2ie.2). Runbook: docs/runbooks/mini64/02-espera-e-camadas.md
#
# Contents
#   Uso · O que cada comando faz · Saída
#
# USO: espera.sh status | ligar [--aplicar --confirmo mini-novo] | desligar [--aplicar]. Sem --aplicar, ligar e desligar só MOSTRAM o que fariam (rc 0).
#   status    só lê. 1ª linha: `espera: desligada|ligada|em-carga|carga-completa|plists-soltos|inconsistente|nao-sei`. Com o marcador e plists da cidade fora da
#             espera, pergunta ao launchctl quais estão carregados: `plists-soltos` = algum NÃO está (um ligar que falhou ou foi interrompido, ou um bootstrap
#             que falhou); em-carga e carga-completa só valem com todos carregados. Lista também o que a espera NÃO move (carrega no login), o que está
#             parado mas a tabela já não conhece e o que só a família classifica.
#   ligar     move os *.plist da cidade (as famílias de camadas.tsv) de ~/Library/LaunchAgents para ~/Library/LaunchAgents.mini64-espera e grava
#             o marcador ~/.mini64-espera ANTES de mover. Só mover: nada é apagado nem sobrescrito (uma cópia nova de um plist já parado vira o
#             vigente e a anterior fica como <nome>.plist.anterior-<epoch>). Rodar de novo termina o serviço. Mover o arquivo NÃO descarrega um job
#             que já está carregado: se houver algum, avisa e sai 3 (reinicie o mini antes de seguir). `--aplicar` exige `--confirmo mini-novo`: o script não
#             sabe em que máquina está, e no mini em produção os plists saem do login e a cidade não sobe no próximo reboot; a chave afirma que esta é a nova.
#   desligar  encerra a espera (o marcador vira ~/.mini64-espera.encerrada-<epoch>) SÓ quando a pasta da espera já não tem plist E nenhum plist da
#             cidade ficou solto e não carregado (um ligar que não moveu nada tem o mesmo aspecto de uma carga completa): devolver é trabalho do
#             carregar-camada.sh, camada por camada, nunca tudo de uma vez.
# SAÍDA: 0 feito (ou prévia) · 1 recusado, nada mudou · 2 não sei (uma leitura falhou), nada mudou · 3 feito, com aviso ou falha parcial.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mini64-lib.sh"

uso() { echo "uso: espera.sh status | ligar [--aplicar --confirmo mini-novo] | desligar [--aplicar]" >&2; exit 1; }
cmd="${1:-}"; [ $# -gt 0 ] && shift
aplicar=0; conf=""
case "$cmd" in
  (status) [ $# -eq 0 ] || uso;;
  (ligar|desligar)
    while [ $# -gt 0 ]; do
      case "$1" in
        (--aplicar) aplicar=1;;
        (--confirmo) [ "$cmd" = ligar ] && [ $# -ge 2 ] || uso; conf="$2"; shift;;
        (*) uso;;
      esac
      shift
    done;;
  (*) uso;;
esac
# status sempre abre com `espera: <estado>`: HOME ou tabela que falham são "nao-sei" dito na saída padrão (o motivo vai para stderr), nunca silêncio
if ! m64_dirs || ! m64_tabela_ok; then [ "$cmd" != status ] || echo "espera: nao-sei (HOME ou tabela ilegível; o motivo está acima)"; exit 2; fi

cmd_status() {
  local mk ag esp nC nO nE est soltos=""
  # vazio → zero plists; falhou/ilegível → "nao-sei" (rc 2), nunca "desligada"
  mk="$(m64_marcador)"
  ag="$(m64_classificados "$M64_AGENTS")" || { echo "espera: nao-sei (não consegui ler $M64_AGENTS)"; return 2; }
  esp="$(m64_espera_classificados)" || { echo "espera: nao-sei (não consegui ler $M64_ESPERA)"; return 2; }
  [ "$mk" != nao-sei ] || { echo "espera: nao-sei (o marcador $M64_MARCADOR existe e não dá para ler)"; return 2; }
  IFS=' ' read -r nC nO <<<"$(printf '%s\n' "$ag" | awk -F'\t' 'NF { if ($3 == "fora") o++; else c++ } END { print c + 0, o + 0 }')"
  nE="$(m64_contar "$esp")"
  # com o marcador e plists soltos só o launchctl diz se é carga ou um ligar que não moveu: vazio → todos carregados; falhou/sem resposta → "nao-sei" (rc 2), nunca carga-completa
  if [ "$mk" = sim ] && [ "$nC" -gt 0 ]; then soltos="$(printf '%s\n' "$ag" | m64_nao_carregados)" || { echo "espera: nao-sei (não consegui conferir no launchd o que está carregado)"; return 2; }; fi
  if [ "$mk" = sim ]; then
    if [ -n "$soltos" ]; then est=plists-soltos
    elif [ "$nE" -gt 0 ] && [ "$nC" -gt 0 ]; then est=em-carga
    elif [ "$nE" -gt 0 ]; then est=ligada
    elif [ "$nC" -gt 0 ]; then est=carga-completa
    else est=ligada; fi
  elif [ "$nE" -eq 0 ]; then est=desligada
  else est=inconsistente; fi
  echo "espera: $est"
  echo "marcador: $mk"; if [ "$mk" = sim ]; then sed 's/^/  /' "$M64_MARCADOR"; fi
  echo "LaunchAgents: $nC plists da cidade, $nO de fora da cidade"
  echo "espera/: $nE plists$(printf '%s\n' "$esp" | m64_por_camada)"
  m64_lista "SOLTOS em LaunchAgents e NÃO carregados (carregariam no próximo login; rode espera.sh ligar --aplicar --confirmo mini-novo de novo ou carregar-camada.sh <N> --aplicar):" "$soltos"
  m64_lista "NÃO movidos pela espera (carregam sozinhos no login):" "$(printf '%s\n' "$ag" | awk -F'\t' 'NF && $3 == "fora" { print $1 }')"
  m64_lista "Na espera, fora da tabela (nunca voltam sozinhos; ponha uma linha em camadas.tsv):" "$(printf '%s\n' "$esp" | awk -F'\t' 'NF && $3 == "fora" { print $1 }')"
  m64_lista "Sem linha própria na tabela (só a família manda; camada entre parênteses):" "$(printf '%s\n%s\n' "$ag" "$esp" | awk -F'\t' 'NF && $3 == "padrao" { print $1 " (" $2 ")" }')"
  return 0
}

cmd_ligar() {
  local ag esp mover fora mk nm ant i movidos=0 falhas=0 avisos=0 carregados ja
  # --aplicar tira os plists da cidade do login: no mini em produção a cidade não sobe no próximo reboot. A chave afirma que ESTA máquina é o mini 64 NOVO
  if [ "$aplicar" -eq 1 ] && [ "$conf" != mini-novo ]; then echo "ligar RECUSADO: --aplicar exige --confirmo mini-novo (afirma que esta máquina, $(hostname -s), é o mini 64 NOVO; no mini em produção os plists saem do login e a cidade não sobe no próximo reboot)" >&2; return 1; fi
  # vazio → nada a mover (o marcador ainda é gravado); falhou/ilegível → rc 2 e nada é movido
  ag="$(m64_classificados "$M64_AGENTS")" || { echo "espera: não consegui ler $M64_AGENTS; nada foi movido" >&2; return 2; }
  mk="$(m64_marcador)"
  [ "$mk" != nao-sei ] || { echo "espera: o marcador $M64_MARCADOR existe e não dá para ler; nada foi movido" >&2; return 2; }
  if [ -e "$M64_ESPERA" ] || [ -L "$M64_ESPERA" ]; then
    [ -d "$M64_ESPERA" ] && [ -w "$M64_ESPERA" ] || { echo "espera: $M64_ESPERA existe e não é uma pasta gravável; nada foi movido" >&2; return 2; }
  fi
  mover="$(printf '%s\n' "$ag" | awk -F'\t' 'NF && $3 != "fora" { print $1 }')"
  fora="$(printf '%s\n' "$ag" | awk -F'\t' 'NF && $3 == "fora" { print $1 }')"
  if [ "$aplicar" -eq 0 ]; then
    echo "ligar (PRÉVIA, nada mudou): moveria $(m64_contar "$mover") plists da cidade para $M64_ESPERA e gravaria $M64_MARCADOR"
    m64_lista "Moveria:" "$mover"
    m64_lista "NÃO moveria (carregam sozinhos no login):" "$fora"
    echo "para executar, SÓ no mini 64 NOVO (esta máquina é $(hostname -s)): espera.sh ligar --aplicar --confirmo mini-novo"; return 0
  fi
  mkdir -p "$M64_ESPERA" || { echo "espera: não consegui criar $M64_ESPERA; nada foi movido" >&2; return 2; }
  # o marcador vai ANTES dos plists: se algo interromper no meio, o status diz plists-soltos (soltos e não carregados) e rodar de novo termina o serviço
  if [ -e "$M64_MARCADOR" ]; then printf 'reaplicada-em=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$M64_MARCADOR"
  else printf 'mini64-espera\nligada-em=%s\nhost=%s\nusuario=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname -s)" "$(id -un)" > "$M64_MARCADOR"; fi \
    || { echo "espera: não consegui gravar o marcador; nada foi movido" >&2; return 2; }
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    if [ -e "$M64_ESPERA/$nm.plist" ] || [ -L "$M64_ESPERA/$nm.plist" ]; then   # já há um parado com esse nome: ele vira .anterior, o que chegou é o vigente
      i=0; ant="$M64_ESPERA/$nm.plist.anterior-$(date +%s)"
      while [ -e "$ant" ] || [ -L "$ant" ]; do i=$((i + 1)); ant="$M64_ESPERA/$nm.plist.anterior-$(date +%s)-$i"; done
      mv "$M64_ESPERA/$nm.plist" "$ant" || { falhas=$((falhas + 1)); echo "espera: não consegui pôr $nm.plist de lado; ele continua em LaunchAgents" >&2; continue; }
    fi
    if mv "$M64_AGENTS/$nm.plist" "$M64_ESPERA/$nm.plist"; then movidos=$((movidos + 1)); else falhas=$((falhas + 1)); echo "espera: não consegui mover $nm.plist" >&2; fi
  done <<<"$mover"
  echo "ligar: $movidos plists movidos para $M64_ESPERA, $falhas falhas; marcador em $M64_MARCADOR"
  m64_lista "NÃO movidos (carregam sozinhos no login; um cloudflared aqui seria um 2º conector no túnel):" "$fora"
  # vazio → nenhum job parado está carregado (sem aviso); falhou → avisa que não deu para conferir (rc 3), nunca diz "nenhum carregado"
  if esp="$(m64_espera_classificados)" && carregados="$("$LAUNCHCTL" list 2>/dev/null)"; then
    ja="$(printf '%s\n' "$carregados" | awk -F'\t' 'NR == FNR { p[$1] = 1; next } $3 in p { print $3 }' <(printf '%s\n' "$esp") -)"
    if [ -n "$ja" ]; then avisos=1; echo "AVISO: $(m64_contar "$ja") jobs da espera JÁ ESTÃO CARREGADOS: mover o plist não os descarrega. Reinicie o mini antes de seguir." >&2; m64_lista "Carregados:" "$ja" >&2; fi
  else avisos=1; echo "AVISO: não consegui conferir o que já está carregado; reinicie o mini antes de seguir." >&2; fi
  if [ "$falhas" -ne 0 ] || [ "$avisos" -ne 0 ]; then return 3; fi
}

cmd_desligar() {
  local mk esp nE ag soltos
  mk="$(m64_marcador)"
  [ "$mk" != nao-sei ] || { echo "espera: o marcador $M64_MARCADOR existe e não dá para ler; nada foi feito" >&2; return 2; }
  # vazio → a pasta não existe ou não tem plist; falhou/ilegível → rc 2: não declaro "sem plist" sem ter lido
  esp="$(m64_espera_classificados)" || { echo "espera: não consegui ler $M64_ESPERA; nada foi feito" >&2; return 2; }
  nE="$(m64_contar "$esp")"
  if [ "$nE" -gt 0 ]; then
    echo "desligar recusado: ainda há $nE plists na espera:$(printf '%s\n' "$esp" | m64_por_camada). Devolva com carregar-camada.sh <N> --aplicar, camada por camada." >&2
    return 1
  fi
  if [ "$mk" = nao ]; then echo "desligar: a espera já está desligada (sem marcador e sem plists na espera)"; return 0; fi
  # a espera vazia também é o aspecto de um ligar que não moveu nada: só o launchctl libera o desligar. vazio → nada solto (ou tudo carregado): segue; falhou/sem resposta → rc 2 e o marcador fica
  ag="$(m64_classificados "$M64_AGENTS")" || { echo "espera: não consegui ler $M64_AGENTS; nada foi feito" >&2; return 2; }
  soltos="$(printf '%s\n' "$ag" | m64_nao_carregados)" || { echo "espera: não consegui conferir no launchd o que está carregado; nada foi feito" >&2; return 2; }
  if [ -n "$soltos" ]; then
    echo "desligar recusado: $(m64_contar "$soltos") plists da cidade soltos em LaunchAgents e NÃO carregados (carregariam no próximo login). Rode espera.sh ligar --aplicar --confirmo mini-novo de novo ou carregar-camada.sh <N> --aplicar." >&2
    m64_lista "SOLTOS:" "$soltos" >&2; return 1
  fi
  if [ "$aplicar" -eq 0 ]; then echo "desligar (PRÉVIA, nada mudou): encerraria a espera ($M64_MARCADOR vira .encerrada-<epoch>); para executar: espera.sh desligar --aplicar"; return 0; fi
  mv "$M64_MARCADOR" "$M64_MARCADOR.encerrada-$(date +%s)" || { echo "espera: não consegui encerrar o marcador" >&2; return 2; }
  echo "desligar: espera encerrada"
}

"cmd_$cmd"
exit $?
