#!/usr/bin/env bash
# hetzner-nodejs-guard.sh — liga "os testes do PS que dependem do binário node estão FORA da lista mac-only" a "o nó tem o Node do pin" (ga-2hd02v.4.11, deriva em ga-2hd02v.4.14). Roda no MINI; só lê.
#
# Contents
#   Por que existe · De onde vem o conjunto de testes · O que decide · Códigos de saída · Como é usado · Limites
#
# POR QUE EXISTE: a lista hetzner-mac-only.ps.txt é um arquivo estático; o Node é estado vivo do host. A revisão da ga-2hd02v.4.10 apontou que nada ligava os dois: se o nó for refeito sem o Node,
#   bead de PS que cite um teste que precisa do node vai ao nó e reprova alto ("node não está no PATH") em vez de ficar no mini. Este guarda é o detector: ele não conserta, diz.
# DE ONDE VEM O CONJUNTO DE TESTES: DERIVADO do próprio repositório do PS (`git grep` por shutil.which("node") em tests/ e lib/tests/ da ref PS_REF, padrão main). Um retrato à mão (NODE_FILES) envelhece:
#   a revisão da .4.11 achou tests/test_blow_cycle.py, que nasceu depois da medição dos "5" e também exige o node. O retrato fica SÓ como reserva quando o repositório do PS não pode ser lido, e então o
#   guarda diz que o conjunto é o retrato.
# O QUE DECIDE (os 5 → N arquivos): para cada teste do conjunto pergunta se a lista o cobre, com a MESMA semântica do classificador (cada linha, sem espaço nos DOIS lados, é um glob; `*` casa também `/`).
#   Algum FORA da lista = o nó precisa ter o Node: roda `hetzner-nodejs.sh check` (só leitura, ssh ao nó). Com o Node presente tudo passa, então a completude do conjunto só importa quando o Node falta ou quando
#   TODOS estão cobertos pela lista (aí a pergunta é "algum teste que precisa do node ficou de fora do conjunto?", e só um conjunto derivado responde).
# CÓDIGOS: 0 ok (ALGUM fora da lista e o Node confere; ou todos cobertos e o conjunto foi derivado) · 1 FALHA: ALGUM fora da lista e o nó NÃO tem o Node do pin (check rc 1: ausente, quebrado ou outra versão)
#   · 2 NÃO SEI: lista ilegível ou sem nenhum glob; o check não respondeu (rc 2, 3, 124, 127, qualquer outro); derivação que não achou NENHUM teste (contradiz o retrato: provável mudança de pasta, não verdade);
#   ou todos cobertos mas o conjunto é só o retrato (não dá para afirmar que nenhum teste novo precisa do node). 2 nunca é verde: quem chama mostra o aviso.
# USO: hetzner-nodejs-guard.sh [LISTA] [SCRIPT-DO-CHECK]    padrões: hetzner-mac-only.ps.txt e hetzner-nodejs.sh, ao lado deste script. O SCRIPT-DO-CHECK é chamado como `bash <script> check`.
#   PS_GIT_DIR (padrão: ../../property_scrapers/.repo.git a partir deste script, o rig do PS ao lado da cidade) e PS_REF (padrão main). Chamado pelo prod test da história (story-ga-2hd02v.4.sh).
#   Selftest: scripts/hetzner-nodejs-guard.selftest.sh.
# LIMITES: a derivação só enxerga teste que acha o node por shutil.which("node") (o padrão dos 6 de hoje). Um teste que chame o node por caminho fixo, por subprocess sem which ou por fixture em outro
#   arquivo não entra no conjunto: o guarda não o vê. É o mesmo limite de qualquer varredura por texto, dito aqui para não parecer cobertura total.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=${1:-$HERE/hetzner-mac-only.ps.txt}; CHECK=${2:-$HERE/hetzner-nodejs.sh}
PS_GIT=${PS_GIT_DIR:-$HERE/../../property_scrapers/.repo.git}; PS_REF=${PS_REF:-main}
# retrato (RESERVA): os testes que chamam which("node") em c624646 do PS; a derivação abaixo é quem manda quando o repositório do PS é legível
NODE_FILES=(tests/test_blow_cycle.py tests/test_blow_rate_limit.py tests/test_blow_budget.py tests/test_blow_property_ids.py tests/test_blow_scraper_ids_wiring.py tests/test_scraper_status_blow_probe.py)
say() { echo "NODEJS-GUARD $*"; }

# vazio → lista sem nenhum glob = NÃO SEI (nunca "todos fora da lista"); falhou/ilegível → NÃO SEI
[ -r "$LIST" ] || { say "NAO-SEI: lista ilegível ou ausente ($LIST)"; exit 2; }
grep -qE '^[[:space:]]*[^#[:space:]]' "$LIST" 2>/dev/null || { say "NAO-SEI: a lista não tem nenhum glob ($LIST): não sei o que ela cobre"; exit 2; }

# vazio → git grep rc 1 = nenhum teste chama o node: contradiz o retrato, então NÃO SEI (nunca "não se aplica"); falhou/ilegível (rc ≥ 2: repositório ausente, ref inexistente) → reserva = retrato, dito na saída
SRC=derivado; FILES=()
derived=$(git --git-dir="$PS_GIT" grep -l -E 'which\(.node.\)' "$PS_REF" -- tests lib/tests 2>/dev/null); grc=$?
case $grc in
  0) while IFS= read -r f; do [ -n "$f" ] && FILES+=("${f#"$PS_REF":}"); done <<EOF_D
$derived
EOF_D
     ;;
  1) say "NAO-SEI: a derivação não achou NENHUM teste do PS que chame which(\"node\") em $PS_REF — isso contradiz o retrato (${#NODE_FILES[@]} arquivos); provável mudança de pasta, não afirmo que nada precisa do node"; exit 2 ;;
  *) SRC=retrato; FILES=("${NODE_FILES[@]}") ;;
esac

# a linha da lista é um glob que casa o caminho relativo ao repo; o `case` do bash casa como o fnmatch do classificador (o `*` atravessa `/`); espaço dos DOIS lados é descartado como no classificador (l.strip())
in_list() {
  local g; while IFS= read -r g || [ -n "$g" ]; do
    g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"; case "$g" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # o glob vem da lista de propósito
    case "$1" in $g) return 0 ;; esac
  done < "$LIST"; return 1
}
OUT=(); for f in "${FILES[@]}"; do in_list "$f" || OUT+=("$f"); done
if [ "${#OUT[@]}" -eq 0 ]; then
  if [ "$SRC" = derivado ]; then say "ok: os ${#FILES[@]} testes do PS que chamam o node (derivados do repositório) estão cobertos pela lista mac-only; o Node do nó não é exigido"; exit 0; fi
  say "NAO-SEI: os ${#FILES[@]} arquivos do retrato estão cobertos pela lista, mas não consegui ler o repositório do PS ($PS_GIT, ref $PS_REF) para derivar o conjunto: não afirmo que nenhum teste novo precise do node"; exit 2
fi

NAMES=$(IFS=,; echo "${OUT[*]}")
[ "$SRC" = retrato ] && NOTE=" [conjunto = retrato; repositório do PS ilegível, deriva não conferida]" || NOTE=""
# vazio → sem saída do check ainda é decidido pelo rc; falhou/ilegível (rc ≠ 0 e ≠ 1) → NÃO SEI
out=$(timeout 90 bash "$CHECK" check 2>&1); rc=$?
case $rc in
  0) say "ok: ${#OUT[@]} teste(s) fora da lista mac-only e o nó tem o Node ($out)$NOTE"; exit 0 ;;
  1) say "FALHA: ${#OUT[@]} teste(s) do PS que dependem do node estão FORA da lista mac-only (${NAMES}), mas o nó NÃO tem o Node do pin ($out). Rode 'bash scripts/hetzner-nodejs.sh install' ou recoloque ESTES arquivos em hetzner-mac-only.ps.txt (docs/runbooks/hetzner-nodejs.md, 'Como desfazer')$NOTE"; exit 1 ;;
  *) say "NAO-SEI: ${#OUT[@]} teste(s) fora da lista mas o check do Node não respondeu (rc $rc: $out)$NOTE"; exit 2 ;;
esac
