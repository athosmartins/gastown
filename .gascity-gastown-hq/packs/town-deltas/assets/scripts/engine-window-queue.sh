#!/usr/bin/env bash
# engine-window-queue.sh — diz, para cada patch pendente, QUAL binário precisa
# ser buildado pra ele sair da fila.
#
# ga-uayvv (2026-08-29). docs/pending-engine-window/ é tratada como "a fila da
# janela de motor", e o ritual é: dog recusa com
# pool:refused:engine-rebuild-required -> patch entra na fila -> Mayor abre a
# janela -> aplica. Só que "a janela" builda UM binário, o `gc`, e a fila tem
# patches de outros dois módulos. Medido no dia: 6 dos 7 patches restantes
# tinham 100% dos arquivos-alvo AUSENTES da árvore do gascity — não era
# conflito nem patch podre, era árvore errada. Eles ficam com
# needs:engine-window para sempre, toda janela de gc "não os resolve", o dog
# seguinte recusa de novo e o painel os conta como travados. Fome permanente
# por rótulo, e nada no processo denunciava isso: o rótulo não diz QUAL motor.
#
# Este script responde a pergunta que faltava, e responde SOZINHO — não depende
# de alguém lembrar de anotar o alvo. Para cada .patch ele lê os caminhos
# `+++ b/<path>` e pergunta a cada raiz de módulo conhecida se aquele caminho
# existe lá. O módulo que reconhece TODOS os alvos é o dono.
#
# Uso:
#   engine-window-queue.sh              # agrupa a fila por binário
#   engine-window-queue.sh gc           # só os aplicáveis numa janela de gc
#   engine-window-queue.sh --check      # exit 1 se algum patch não tem dono
#   engine-window-queue.sh --label      # carimba needs:build:<bin> nos beads
#
# `--check` existe pra rodar antes de abrir uma janela: um patch órfão (nenhum
# módulo reconhece seus arquivos) é o sintoma de que ele nunca vai ser aplicado
# por ninguém, e isso tem que aparecer ANTES de alguém gastar uma janela.
set -uo pipefail

QUEUE="${ENGINE_WINDOW_QUEUE:-/Users/athos/gt/.gascity-gastown-hq/docs/pending-engine-window}"

# binário -> raiz do módulo. Derivadas de go.mod, não chutadas:
#   gc = github.com/gastownhall/gascity   gt = github.com/steveyegge/gastown
#   bd = github.com/steveyegge/beads
MODULES="gc:${GC_SRC_ROOT:-/Users/athos/gt/.local-patches/_src-hookfix}
gt:${GT_SRC_ROOT:-/Users/athos/gt}
bd:${BD_SRC_ROOT:-/Users/athos/gt/beads}"

want="${1:-}"
check_only=0
label_mode=0
[ "$want" = "--check" ] && { check_only=1; want=""; }
# --label carimba needs:build:<bin> no bead de cada patch pendente. Sem isso o
# script resolve só metade do ga-uayvv: quem ABRE a janela passa a saber o que
# cabe nela, mas o BEAD continua mudo — ele carrega needs:engine-window, que não
# diz qual motor, então segue invisível até alguém abrir por acaso a janela
# certa. Com o carimbo, `bd list --label needs:build:gt` responde "o que a
# próxima janela de gt destrava" sem ninguém precisar saber deste script.
#
# ⚠️ Ao CONSULTAR o carimbo, passe sempre `-C <store>`. `gc bd list` sem -C
# resolve pra UM banco só e devolve silenciosamente uma resposta parcial:
# medido aqui, `gc bd list --label needs:build:gc` deu 0 enquanto
# `gc bd -C ~/gt/.gascity-gastown-hq list --label needs:build:gc` deu 2 — os
# beads ga-* vivem no hq e o wa-* no store do rig, e a query pelada só via um
# deles. Zero e "olhei no banco errado" ficam idênticos, que é justamente a
# forma de erro que este script existe pra eliminar, não pra reproduzir. O
# `label add` do modo --label NÃO tem esse problema: a escrita resolve o store
# a partir do prefixo do bead (confirmado nos 3, incl. o wa-*).
[ "$want" = "--label" ] && { label_mode=1; want=""; }

[ -d "$QUEUE" ] || { echo "fila não existe: $QUEUE" >&2; exit 2; }

# classify <patch> -> imprime "<binario> <alvos_presentes>/<alvos_totais>"
# Um módulo só é dono se reconhece TODOS os alvos. Reconhecer alguns é
# ambiguidade, não vitória — e ambiguidade tem que aparecer, não ser arredondada.
classify() {
  local patch="$1" best="" best_hit=0 total=0
  # Só contam os arquivos que o patch MODIFICA. Um patch que CRIA arquivo tem
  # `--- /dev/null` antes do `+++ b/<novo>`, e esse caminho por definição ainda
  # não existe em lugar nenhum — contá-lo faria todo patch com arquivo novo
  # parecer "parcial" e disparar o aviso de patch stale. (Pego no controle:
  # ga-eu2x aparecia 1/2 só porque adiciona um _test.go.)
  local paths
  paths=$(awk '/^--- /{prev=$2} /^\+\+\+ b\//{ if (prev != "/dev/null") { sub(/^\+\+\+ b\//,""); print $0 } }' "$patch" 2>/dev/null)
  [ -z "$paths" ] && {
    # patch que SÓ cria arquivos: sem alvo existente pra casar, então classifica
    # pelo diretório-raiz dos arquivos novos em vez de declarar órfão.
    paths=$(grep '^+++ b/' "$patch" 2>/dev/null | sed 's|^+++ b/||' | sed 's|/[^/]*$||')
    [ -z "$paths" ] && { echo "?  0/0"; return; }
  }
  total=$(printf '%s\n' "$paths" | grep -c .)

  local line bin root hit p
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    bin="${line%%:*}"; root="${line#*:}"
    [ -d "$root" ] || continue
    hit=0
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -e "$root/$p" ] && hit=$((hit + 1))
    done <<EOF
$paths
EOF
    if [ "$hit" -gt "$best_hit" ]; then best_hit=$hit; best=$bin; fi
  done <<EOF
$MODULES
EOF

  [ "$best_hit" -eq 0 ] && { echo "ORFAO  0/$total"; return; }
  echo "$best  $best_hit/$total"
}

orphans=0
partials=0
declare -a rows=()

for f in "$QUEUE"/*.patch; do
  [ -e "$f" ] || continue
  res=$(classify "$f")
  bin="${res%% *}"; frac="${res##* }"
  bead=$(basename "$f" | grep -oE '^[a-z]{2}-[a-z0-9]+' | head -1)
  [ "$bin" = "ORFAO" ] && orphans=$((orphans + 1))
  case "$frac" in
    */*) [ "${frac%%/*}" != "${frac##*/}" ] && [ "$bin" != "ORFAO" ] && partials=$((partials + 1)) ;;
  esac
  rows+=("$bin|$bead|$frac|$(basename "$f")")
done

[ "${#rows[@]}" -eq 0 ] && { echo "fila vazia — nenhum .patch pendente"; exit 0; }

if [ "$label_mode" -eq 1 ]; then
  command -v gc >/dev/null 2>&1 || { echo "gc não encontrado no PATH" >&2; exit 2; }
  for r in "${rows[@]}"; do
    IFS='|' read -r bin bead frac name <<EOF
$r
EOF
    [ -z "$bead" ] && continue
    if [ "$bin" = "ORFAO" ] || [ "$bin" = "?" ]; then
      printf '  %-10s PULADO (sem dono — carimbar seria mentir sobre qual janela resolve)\n' "$bead"
      continue
    fi
    # Idempotente: `label add` de um label já presente é no-op.
    if timeout 30 gc bd label add "$bead" "needs:build:$bin" -q >/dev/null 2>&1; then
      printf '  %-10s needs:build:%s\n' "$bead" "$bin"
    else
      printf '  %-10s FALHOU ao carimbar needs:build:%s\n' "$bead" "$bin"
    fi
  done
  exit 0
fi

if [ -n "$want" ]; then
  for r in "${rows[@]}"; do
    IFS='|' read -r bin bead frac name <<EOF
$r
EOF
    [ "$bin" = "$want" ] && printf '%-10s %-8s %s\n' "$bead" "$frac" "$name"
  done
  exit 0
fi

echo "FILA: $QUEUE"
echo
for target in gc gt bd ORFAO; do
  n=0
  for r in "${rows[@]}"; do [ "${r%%|*}" = "$target" ] && n=$((n + 1)); done
  [ "$n" -eq 0 ] && continue
  case "$target" in
    ORFAO) echo "SEM DONO ($n) — nenhum modulo conhecido reconhece os arquivos-alvo:" ;;
    *)     echo "precisa de uma janela de \`$target\` ($n):" ;;
  esac
  for r in "${rows[@]}"; do
    IFS='|' read -r bin bead frac name <<EOF
$r
EOF
    [ "$bin" = "$target" ] || continue
    flag=""
    [ "${frac%%/*}" != "${frac##*/}" ] && flag="  <- alvos PARCIAIS: patch stale ou depende de vendor mais novo"
    printf '  %-10s %-8s %s%s\n' "$bead" "$frac" "$name" "$flag"
  done
  echo
done

if [ "$orphans" -gt 0 ]; then
  echo "AVISO: $orphans patch(es) sem dono. Eles NAO vao sair da fila por conta"
  echo "       de nenhuma janela — ou o alvo mudou de caminho, ou o modulo nao"
  echo "       esta clonado nesta maquina. Trate antes de abrir a proxima."
fi
if [ "$partials" -gt 0 ]; then
  echo "AVISO: $partials patch(es) com alvos parciais — o modulo reconhece so"
  echo "       parte dos arquivos. Normalmente e patch escrito contra base"
  echo "       antiga, ou dependencia de vendor ainda nao atualizado."
fi

[ "$check_only" -eq 1 ] && [ "$orphans" -gt 0 ] && exit 1
exit 0
