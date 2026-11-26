#!/usr/bin/env bash
# carregar-camada.sh — devolve da espera e carrega SÓ a camada N do mini 64 (ga-ke5w2ie.2). Runbook: docs/runbooks/mini64/02-espera-e-camadas.md
#
# Contents
#   Uso · Recusas · Saída
#
# USO: carregar-camada.sh <N> [--aplicar] [--confirmo <chave>]. Sem --aplicar só mostra o plano (e diz se o --aplicar seria aceito).
# A camada N é o que camadas.tsv manda para N: o que está na espera volta para ~/Library/LaunchAgents e é carregado com `bootstrap gui/<uid>`, em
# ordem alfabética; o que já voltou é conferido (já carregado = nada a fazer), então rodar de novo é seguro. Nada é apagado nem sobrescrito.
# RECUSA (rc 1, nada muda): camada que a tabela não define · espera desligada (sem marcador) · plist de camada ANTERIOR ainda na espera (a ordem é
#   dolt, motor, backups, painéis, cloudflared, envios) · plist de camada POSTERIOR já solto em LaunchAgents (rode espera.sh ligar --aplicar) ·
#   camada com `exige` na tabela e sem --confirmo <chave> (backups e envios: servidor antigo aposentado; cloudflared: conector antigo parado).
# SAÍDA: 0 feito (ou prévia) · 1 recusado · 2 não sei (uma leitura falhou) · 3 feito com falha: plist que não voltou ou não carregou, ou sem resposta.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mini64-lib.sh"

uso() { echo "uso: carregar-camada.sh <N> [--aplicar] [--confirmo <chave>]" >&2; exit 1; }
N=""; aplicar=0; conf=""
while [ $# -gt 0 ]; do
  case "$1" in
    (--aplicar) aplicar=1;;
    (--confirmo) [ $# -ge 2 ] || uso; conf="$2"; shift;;
    (--*) uso;;
    (*) [ -z "$N" ] || uso; N="$1";;
  esac
  shift
done
[ -n "$N" ] || uso
case "$N" in (*[!0-9]*|????*) echo "carregar-camada: camada inválida: '$N' (um número inteiro de até 3 dígitos)" >&2; exit 1;; esac
N=$((10#$N))
m64_dirs || exit 2
m64_tabela_ok || exit 2
# vazio → a tabela não define N: recusa (rc 1); falhou/ilegível → a mesma recusa, nunca age numa camada que não conseguiu ler
info="$(m64_camada_info "$N")" || { echo "carregar-camada: a camada $N não existe na tabela (existem: $(m64_camadas))" >&2; exit 1; }
IFS=$'\t' read -r nome exige <<<"$info"
recusar() { echo "carregar-camada $N ($nome): RECUSADO: $1" >&2; exit 1; }

case "$(m64_marcador)" in
  (sim) ;;
  (nao) recusar "a espera não está ligada (sem $M64_MARCADOR): não há o que devolver; rode espera.sh ligar --aplicar";;
  (*) echo "carregar-camada: o marcador $M64_MARCADOR existe e não dá para ler; nada foi feito" >&2; exit 2;;
esac
# vazio → nada na espera / nada solto; falhou/ilegível → rc 2: não decido o plano sem ter lido os dois lados
esp="$(m64_espera_classificados)" || { echo "carregar-camada: não consegui ler $M64_ESPERA; nada foi feito" >&2; exit 2; }
agt="$(m64_classificados "$M64_AGENTS")" || { echo "carregar-camada: não consegui ler $M64_AGENTS; nada foi feito" >&2; exit 2; }

ant="$(printf '%s\n' "$esp" | awk -F'\t' -v n="$N" 'NF && $3 != "fora" && $2 + 0 < n + 0' | m64_por_camada)"
[ -z "$ant" ] || recusar "ainda há plists de camada anterior na espera:$ant; carregue as camadas na ordem"
adi="$(printf '%s\n' "$agt" | awk -F'\t' -v n="$N" 'NF && $3 != "fora" && $2 + 0 > n + 0 { print $1 }')"
[ -z "$adi" ] || recusar "$(m64_contar "$adi") plists de camada posterior estão soltos em LaunchAgents (carregariam no próximo login); rode espera.sh ligar --aplicar"
if [ "$exige" != "-" ] && [ "$conf" != "$exige" ]; then recusar "esta camada exige --confirmo $exige (o fato que a tabela cita para ela; ver o runbook)"; fi

volta="$(printf '%s\n' "$esp" | awk -F'\t' -v n="$N" 'NF && $3 != "fora" && $2 + 0 == n + 0 { print $1 }')"
solto="$(printf '%s\n' "$agt" | awk -F'\t' -v n="$N" 'NF && $3 != "fora" && $2 + 0 == n + 0 { print $1 }')"
todos="$(printf '%s\n%s\n' "$volta" "$solto" | sed '/^$/d' | LC_ALL=C sort -u)"
devolvidos=0; novos=0; jas=0; falhas=0

# carregar <label>: devolve (se estiver na espera) e carrega (se ainda não estiver carregado)
carregar() {
  local l="$1" src dst st out
  src="$M64_ESPERA/$l.plist"; dst="$M64_AGENTS/$l.plist"
  if [ -e "$src" ] || [ -L "$src" ]; then
    if [ -e "$dst" ] || [ -L "$dst" ]; then echo "  FALHA $l: existe na espera E em LaunchAgents; não sobrescrevo nenhum dos dois" >&2; falhas=$((falhas + 1)); return 0; fi
    if [ "$aplicar" -eq 0 ]; then echo "  devolveria e carregaria $l"; return 0; fi
    mv "$src" "$dst" || { echo "  FALHA $l: não consegui devolver o plist" >&2; falhas=$((falhas + 1)); return 0; }
    devolvidos=$((devolvidos + 1))
  fi
  m64_carregado "$l"; st=$?   # 2 = "não sei se já está carregado": não carrego e conto como falha
  case "$st" in
    (0) echo "  já carregado: $l"; jas=$((jas + 1));;
    (1) if [ "$aplicar" -eq 0 ]; then echo "  carregaria $l"
        elif out="$("$LAUNCHCTL" bootstrap "gui/$M64_UID" "$dst" 2>&1)"; then echo "  carregado: $l"; novos=$((novos + 1))
        else echo "  FALHA $l: bootstrap recusado: $out" >&2; falhas=$((falhas + 1)); fi;;
    (*) echo "  FALHA $l: não sei se já está carregado (rc $st); não carreguei" >&2; falhas=$((falhas + 1));;
  esac
  return 0
}

if [ "$aplicar" -eq 1 ]; then echo "carregar-camada $N ($nome): APLICANDO"; else echo "carregar-camada $N ($nome): PRÉVIA, nada muda"; fi
if [ -z "$todos" ]; then echo "  nenhum plist desta camada nesta máquina (o que sobe por outro meio, como brew services, suba à mão)"; exit 0; fi
while IFS= read -r l; do if [ -n "$l" ]; then carregar "$l"; fi; done <<<"$todos"
echo "camada $N: $devolvidos devolvidos, $novos carregados, $jas já carregados, $falhas falhas"
[ "$falhas" -eq 0 ] || exit 3
if [ "$aplicar" -eq 0 ]; then echo "para executar: carregar-camada.sh $N --aplicar$([ "$exige" = - ] || echo " --confirmo $exige")"; fi
exit 0
