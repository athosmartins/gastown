#!/usr/bin/env bash
# hetzner-nodejs-guard.sh — liga "os 5 arquivos de teste do PS que dependem do binário node estão FORA da lista mac-only" a "o nó tem o Node do pin" (ga-2hd02v.4.11). Roda no MINI; só lê.
#
# Contents
#   Por que existe · O que decide · Códigos de saída · Como é usado
#
# POR QUE EXISTE: a lista hetzner-mac-only.ps.txt é um arquivo estático; o Node é estado vivo do host. A revisão da ga-2hd02v.4.10 apontou que nada ligava os dois: se o nó for refeito sem o Node,
#   bead de PS que cite um desses 5 arquivos vai ao nó e reprova alto ("node não está no PATH") em vez de ficar no mini. Este guarda é o detector: ele não conserta, diz.
# O QUE DECIDE: para cada um dos 5 arquivos (NODE_FILES) pergunta se a lista o cobre, com a MESMA semântica do classificador (cada linha é um glob, `*` casa também `/`). Todos cobertos = não se aplica.
#   Algum FORA da lista = o nó precisa ter o Node: roda `hetzner-nodejs.sh check` (só leitura, ssh ao nó).
# CÓDIGOS: 0 ok (todos na lista, ou fora da lista e o Node confere) · 1 FALHA: algum fora da lista e o nó NÃO tem o Node do pin (check rc 1: ausente, quebrado ou outra versão)
#   · 2 NÃO SEI: lista ilegível ou sem nenhum glob, ou o check não respondeu (rc 2, 3, 124 de prazo, 127 de script ausente, qualquer outro). 2 nunca é verde: quem chama mostra o aviso.
# USO: hetzner-nodejs-guard.sh [LISTA] [SCRIPT-DO-CHECK]    padrões: hetzner-mac-only.ps.txt e hetzner-nodejs.sh, ambos ao lado deste script. O SCRIPT-DO-CHECK é chamado como `bash <script> check`.
#   Chamado pelo prod test da história (prod-tests/gascity/story-ga-2hd02v.4.sh). Selftest: scripts/hetzner-nodejs-guard.selftest.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=${1:-$HERE/hetzner-mac-only.ps.txt}; CHECK=${2:-$HERE/hetzner-nodejs.sh}
NODE_FILES=(tests/test_blow_rate_limit.py tests/test_blow_budget.py tests/test_blow_property_ids.py tests/test_blow_scraper_ids_wiring.py tests/test_scraper_status_blow_probe.py)
say() { echo "NODEJS-GUARD $*"; }

# vazio → lista sem nenhum glob = NÃO SEI (nunca "todos fora da lista"); falhou/ilegível → NÃO SEI
[ -r "$LIST" ] || { say "NAO-SEI: lista ilegível ou ausente ($LIST)"; exit 2; }
grep -qE '^[^#[:space:]]' "$LIST" 2>/dev/null || { say "NAO-SEI: a lista não tem nenhum glob ($LIST): não sei o que ela cobre"; exit 2; }

# a linha da lista é um glob que casa o caminho relativo ao repo; o `case` do bash casa como o fnmatch do classificador (o `*` atravessa `/`)
in_list() {
  local g; while IFS= read -r g || [ -n "$g" ]; do
    g="${g%"${g##*[![:space:]]}"}"; case "$g" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # o glob vem da lista de propósito
    case "$1" in $g) return 0 ;; esac
  done < "$LIST"; return 1
}
out_of_list=0
for f in "${NODE_FILES[@]}"; do in_list "$f" || out_of_list=$((out_of_list + 1)); done
[ "$out_of_list" -gt 0 ] || { say "ok: os ${#NODE_FILES[@]} arquivos estão cobertos pela lista mac-only; o Node do nó não é exigido"; exit 0; }

# vazio → sem saída do check ainda é decidido pelo rc; falhou/ilegível (rc ≠ 0 e ≠ 1) → NÃO SEI
out=$(timeout 90 bash "$CHECK" check 2>&1); rc=$?
case $rc in
  0) say "ok: $out_of_list arquivo(s) fora da lista mac-only e o nó tem o Node ($out)"; exit 0 ;;
  1) say "FALHA: $out_of_list arquivo(s) de teste do PS que dependem do node estão FORA da lista mac-only, mas o nó NÃO tem o Node do pin ($out). Rode 'bash scripts/hetzner-nodejs.sh install' ou recoloque os arquivos em hetzner-mac-only.ps.txt (docs/runbooks/hetzner-nodejs.md, 'Como desfazer')"; exit 1 ;;
  *) say "NAO-SEI: $out_of_list arquivo(s) fora da lista mas o check do Node não respondeu (rc $rc: $out)"; exit 2 ;;
esac
