#!/usr/bin/env bash
# gate-queue-composition.sh — "a fila está funda" NÃO é um número, é uma COMPOSIÇÃO.
#
# POR QUE ESTE SCRIPT EXISTE (Mayor, 2026-08-06, madrugada que virou recorde):
#   A fila do gate tinha 23 markers e todo mundo — inclusive eu — leu isso como
#   "precisamos de mais revisores". Subi concorrência e cadência. Ajudou pouco.
#   O ganho real veio quando MEDI o que a fila continha: 5 de 10 markers eram de
#   branches JÁ MERGEADAS, presas em needs-rebase (estado que nunca poderiam
#   satisfazer — rebasear branch mergeada dá branch vazia); 1 era duplicata
#   esterilizando varredura; 1 estava invisível havia 2 dias por não ter label
#   gate-status. Metade da "carga" não existia. Estávamos otimizando o transporte
#   de carga fantasma.
#
#   O diagnóstico existente (gate_queue_backlog.py::_gate_queue_depth) conta
#   markers gate-status:queued e NÃO pergunta se há trabalho ali. Um número de
#   profundidade que inclui fantasma é precisamente o sinal que leva à decisão
#   errada — e com confiança, porque é um número.
#
# REGRA QUE ESTE SCRIPT SERVE (town-deltas, doutrina de autonomia, regra nº1):
#   MEÇA ANTES DE TEORIZAR. Antes de mexer em concorrência, cadência ou teto,
#   rode isto. Se `real` for baixo, mais capacidade não resolve nada.
#
# DETECTION-ONLY: não escreve nada, não muta bead, não toca em branch. Read-only
# por construção — pode rodar a qualquer momento, por qualquer agente.
#
# TERCEIRO ESTADO (obrigatório aqui): quando um fato não pode ser lido — branch
# ausente do origin, rig irresolvível, bd que não responde — o marker vai para
# UNKNOWN, nunca para PHANTOM. Classificar o ilegível como fantasma convidaria a
# fechar trabalho real, que é o erro caro; o barato é olhar de novo.
#
# Uso:  bash gate-queue-composition.sh [--json]

set -uo pipefail

JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

HQ="${GC_CITY_PATH:-}"
if [ -z "$HQ" ]; then
  HQ=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
fi
[ -d "$HQ/.beads" ] || { echo "ERRO: não achei o store HQ (tentei: $HQ). Setei GC_CITY_PATH?" >&2; exit 2; }

# Mapa rig->path derivado do registry VIVO, nunca de caminho escrito em doc.
RIGS_JSON=$(gc --city "$HQ" rig list --json 2>/dev/null || echo '{}')

rig_path() {
  local name="$1"
  [ "$name" = "gascity" ] || [ -z "$name" ] && { printf '%s' "$(dirname "$HQ")"; return; }
  printf '%s' "$RIGS_JSON" | jq -r --arg n "$name" '.rigs[]? | select(.name==$n) | .path' 2>/dev/null | head -1
}

# --limit 0 é OBRIGATÓRIO: `bd list` trunca em 50 por padrão. Em modo humano ele
# avisa ("more results matched but were hidden by --limit"), mas o aviso vai pro
# STDERR — e o `2>/dev/null` idiomático desta cidade o engole. O --json devolve um
# array puro, sem nenhum campo dizendo que truncou. Resultado: uma fila com 60
# markers seria reportada como 50, e a composição REAL/FANTASMA sairia errada sem
# nenhum sinal. Um diagnóstico que subconta em silêncio é pior que não ter.
#
# --include-infra é IGUALMENTE obrigatório, e por pouco esta ferramenta não
# ensinou a cidade inteira a errar. O bd 1.1.0 classifica bead `--ephemeral` como
# INFRA e o OMITE de `bd list` por padrão; markers de gate nasciam ephemeral.
# Sem a flag, este script imprimia "total de markers: 0" com 7 markers na fila e
# o gate parado — e ele é o script que a doutrina manda rodar ANTES de teorizar.
# Um medidor cego não é neutro: ele é uma teoria errada com cara de medição.
# PATH ROBUSTO — este script não roda só no terminal do Athos. O
# nightly-reboot.sh o invoca como LaunchDaemon (root), cujo PATH herdado NÃO
# tem /Users/athos/.local/bin (onde mora o bd) nem /opt/homebrew/bin (jq, gc).
# Sem isto, `bd` dá "command not found", o 2>/dev/null abaixo engolia a
# mensagem, e o script devolvia rc=2 "UNKNOWN" — que o nightly-reboot lê,
# corretamente, como "estado do gate desconhecido, NÃO é seguro rebootar".
# Efeito medido: o reboot noturno foi bloqueado 3 noites seguidas (04, 05 e
# 06/09), sempre pelo mesmo motivo, e o log não dizia qual era. Isolado com um
# 2x2: PATH mínimo reprova com HOME=/var/root E com HOME=/Users/athos; PATH
# completo passa nos dois. É PATH, não HOME.
for _d in /Users/athos/.local/bin /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$_d:"*) ;; *) [ -d "$_d" ] && PATH="$_d:$PATH" ;; esac
done
export PATH
unset _d

# TERCEIRO ESTADO: "bd não existe no PATH" e "bd rodou e devolveu erro" são
# causas DIFERENTES com remédios diferentes, e antes produziam a mesma linha.
# Foi exatamente isso que tornou as 3 noites bloqueadas indiagnosticáveis pelo
# log. Cada uma agora se identifica.
if ! command -v bd >/dev/null 2>&1; then
  echo "ERRO: 'bd' não está no PATH — não é possível ler os markers." >&2
  echo "      PATH=$PATH" >&2
  echo "      Isto é UNKNOWN, não 'fila vazia' — não conclua nada a partir daqui." >&2
  exit 2
fi

BD_ERR=$(mktemp -t gqc-bd-err)
MARKERS=$(bd -C "$HQ" list --limit 0 --include-infra -l type:quality-gate-marker --json 2>"$BD_ERR")
if [ -z "$MARKERS" ] || ! printf '%s' "$MARKERS" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "ERRO: não consegui ler os markers (bd falhou ou devolveu envelope de erro)." >&2
  # Repassa o que o bd disse: sem isto o diagnóstico depende de reproduzir o
  # ambiente do daemon à mão, que foi o que custou 3 noites.
  [ -s "$BD_ERR" ] && sed 's/^/      bd: /' "$BD_ERR" >&2
  echo "      Isto é UNKNOWN, não 'fila vazia' — não conclua nada a partir daqui." >&2
  rm -f "$BD_ERR"
  exit 2
fi
rm -f "$BD_ERR"

TOTAL=$(printf '%s' "$MARKERS" | jq 'length')
REAL=0; PHANTOM=0; UNKNOWN=0
REAL_L=""; PH_L=""; UNK_L=""

# Contagem de markers por branch: >1 = duplicata (esteriliza varredura, ga-o64z1)
BRANCH_COUNTS=$(printf '%s' "$MARKERS" \
  | jq -r '.[] | (.labels[]? | select(startswith("branch:")))' 2>/dev/null \
  | sort | uniq -c)

FETCHED=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  ID=$(printf '%s' "$row" | jq -r '.id')
  BRANCH=$(printf '%s' "$row" | jq -r '[.labels[]?|select(startswith("branch:"))|sub("^branch:";"")]|first // ""')
  SRCBEAD=$(printf '%s' "$row" | jq -r '[.labels[]?|select(startswith("source-bead:"))|sub("^source-bead:";"")]|first // ""')
  RIG=$(printf '%s' "$row" | jq -r '[.labels[]?|select(startswith("bead-rig:"))|sub("^bead-rig:";"")]|first // ""')
  GSTATUS=$(printf '%s' "$row" | jq -r '[.labels[]?|select(startswith("gate-status:"))]|join(",")')

  # (a) sem gate-status = invisível ao dispatcher por construção (ga-5jyo8)
  if [ -z "$GSTATUS" ]; then
    PHANTOM=$((PHANTOM+1)); PH_L="$PH_L\n    $ID  sem gate-status — invisível ao dispatcher (ga-5jyo8)"
    continue
  fi
  # (b) mais de um gate-status = invariante corrompido; não dá pra dizer onde está
  if printf '%s' "$GSTATUS" | grep -q ','; then
    UNKNOWN=$((UNKNOWN+1)); UNK_L="$UNK_L\n    $ID  DOIS gate-status ($GSTATUS) — estado ambíguo"
    continue
  fi
  # (c) duplicata por branch
  if [ -n "$BRANCH" ]; then
    N=$(printf '%s' "$BRANCH_COUNTS" | awk -v b="branch:$BRANCH" '$2==b {print $1}')
    if [ "${N:-1}" -gt 1 ] 2>/dev/null; then
      PHANTOM=$((PHANTOM+1)); PH_L="$PH_L\n    $ID  duplicata p/ $BRANCH ($N markers) — esteriliza varredura (ga-o64z1)"
      continue
    fi
  fi
  if [ -z "$BRANCH" ]; then
    UNKNOWN=$((UNKNOWN+1)); UNK_L="$UNK_L\n    $ID  sem label branch: — não dá pra avaliar"
    continue
  fi

  RP=$(rig_path "$RIG")
  # NÃO teste `-d "$RP/.git"`: num worktree ou submodule o .git é um ARQUIVO, não
  # diretório, e o teste dá falso negativo — property_scrapers caiu nisso e virou
  # ILEGÍVEL sem ser. `rev-parse --git-dir` responde a pergunta real ("isto é um
  # repo utilizável?") em vez de inferi-la do formato do .git.
  if [ -z "$RP" ] || ! git -C "$RP" rev-parse --git-dir >/dev/null 2>&1; then
    UNKNOWN=$((UNKNOWN+1)); UNK_L="$UNK_L\n    $ID  rig '$RIG' não resolveu — ILEGÍVEL, não é fantasma"
    continue
  fi
  case "$FETCHED" in *"|$RP|"*) : ;; *) git -C "$RP" fetch origin -q 2>/dev/null; FETCHED="$FETCHED|$RP|" ;; esac

  if ! git -C "$RP" rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
    UNKNOWN=$((UNKNOWN+1)); UNK_L="$UNK_L\n    $ID  branch $BRANCH ausente do origin — ILEGÍVEL, não é fantasma"
    continue
  fi
  DEF=$(git -C "$RP" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'); DEF="${DEF:-main}"

  # (d) branch JÁ MERGEADA = não há o que revisar; rebasear daria branch vazia
  if git -C "$RP" merge-base --is-ancestor "origin/$BRANCH" "origin/$DEF" 2>/dev/null; then
    PHANTOM=$((PHANTOM+1)); PH_L="$PH_L\n    $ID  $BRANCH JÁ MERGEADA em $DEF — nada a revisar (ga-88sl7)"
    continue
  fi
  # (e) bead de origem fechado = trabalho entregue por outra via
  if [ -n "$SRCBEAD" ]; then
    SB_STORE="$HQ"; [ -n "$RIG" ] && [ "$RIG" != "gascity" ] && SB_STORE="$RP"
    SBJ=$(bd -C "$SB_STORE" show "$SRCBEAD" --json 2>/dev/null)
    if [ -n "$SBJ" ] && printf '%s' "$SBJ" | jq -e 'type=="array"' >/dev/null 2>&1; then
      ST=$(printf '%s' "$SBJ" | jq -r '.[0].status // ""')
      if [ "$ST" = "closed" ]; then
        PHANTOM=$((PHANTOM+1)); PH_L="$PH_L\n    $ID  bead $SRCBEAD fechado — trabalho já entregue"
        continue
      fi
    fi
    # status ilegível NÃO reclassifica: segue para real, que é o lado seguro.
  fi

  AHEAD=$(git -C "$RP" rev-list --count "origin/$DEF..origin/$BRANCH" 2>/dev/null)
  REAL=$((REAL+1)); REAL_L="$REAL_L\n    $ID  $BRANCH (+${AHEAD:-?} commits) [$GSTATUS]"
done < <(printf '%s' "$MARKERS" | jq -c '.[]')

if [ "$JSON_OUT" = "1" ]; then
  printf '{"total":%d,"real":%d,"phantom":%d,"unknown":%d}\n' "$TOTAL" "$REAL" "$PHANTOM" "$UNKNOWN"
  exit 0
fi

echo "═══ COMPOSIÇÃO DA FILA DO GATE ═══"
echo "  total de markers: $TOTAL"
echo "  TRABALHO REAL:    $REAL   <- só isto responde a mais capacidade"
echo "  FANTASMA:         $PHANTOM   <- some com limpeza, não com revisor"
echo "  ILEGÍVEL:         $UNKNOWN   <- olhe de novo; NÃO é fantasma"
[ -n "$REAL_L" ] && { echo; echo "  REAL:"; printf "$REAL_L\n"; }
[ -n "$PH_L" ]   && { echo; echo "  FANTASMA:"; printf "$PH_L\n"; }
[ -n "$UNK_L" ]  && { echo; echo "  ILEGÍVEL:"; printf "$UNK_L\n"; }
echo
if [ "$TOTAL" -gt 0 ] && [ "$REAL" -lt "$PHANTOM" ]; then
  echo "  ⚠ A MAIOR PARTE DA FILA NÃO É TRABALHO. Aumentar concorrência não vai"
  echo "    mover este número — limpe o fantasma primeiro."
fi
