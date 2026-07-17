#!/usr/bin/env bash
# silent-ignorance-watch.sh — o MONITOR da IGNORÂNCIA SILENCIOSA (ga-vkjs / wa-xvxs0).
#
# A CLASSE (nome travado pelo Athos, 16/07/2026 — "Ignorância Silenciosa"):
#   o sistema não consegue apurar um fato e emite EXATAMENTE o mesmo sinal de quando
#   apurou. Ele não sabe, e não diz que não sabe. 14 instâncias etiquetadas num dia,
#   achadas por 4 agentes — nenhum procurando o padrão. Custos reais: 47 respostas de
#   lead nunca chegaram ao gerador de draft; 58 msgs mortas caladas; 5h de gate travado;
#   um filtro de segurança 5 dias fora do processo; 20h de trabalho perdido (ga-p5q3).
#
# POR QUE ESTE MONITOR EXISTE, e não só o scanner:
#   o error-empty-conflation-scan.sh (ga-p5q3, thies, 14/07) JÁ ACHAVA a classe — e
#   ficou 2 dias em main SEM SER AGENDADO. Detector que ninguém roda é igual a detector
#   que não existe: foi assim que a gente "redescobriu" a classe do zero em 16/07, com
#   ela já nomeada e com scanner pronto. Este arquivo é a parte que faltava: o gatilho.
#
# O QUE ELE FAZ (e o que deliberadamente NÃO faz):
#   Roda o scanner, compara com o BASELINE e alerta SÓ o que é NOVO. Os ~291 achados
#   existentes são DÍVIDA (report-only, o humano tria); um achado NOVO é ALGUÉM QUE
#   ACABOU DE ESCREVER O BUG — esse é o sinal. Isto também conserta a régua que estava
#   quebrada: ela confundia "achado" com "criado". Baseline = achado. Delta = criado.
#
# AS 3 LIÇÕES DE 16/07 QUE ESTÃO CODIFICADAS AQUI (cada uma é um bug real de hoje):
#   1. wa-k288h — dedup sem timestamp avisa 1x e CALA PRA SEMPRE. Aqui: o seen guarda
#      epoch por achado e RE-ESCALA depois de ESCALATE_DAYS.
#   2. wa-4fmxd — persistir ANTES de o aviso sair faz um ntfy falho CONSUMIR o alerta.
#      Aqui: só grava o baseline DEPOIS de o notify confirmar (rc=0).
#   3. ga-p5q3 (regra b, do thies) — todo check cuja VACUIDADE é load-bearing tem que
#      ser FALSIFICADO. Aqui: se o scanner não roda, ou o baseline não é legível, o
#      monitor GRITA e sai != 0 — nunca reporta "0 novos" por não ter conseguido olhar.
#      É a diferença entre "não achei" e "não consegui procurar".
#
# Uso:  silent-ignorance-watch.sh [--notify] [--seed] [--baseline PATH]
#         (sem --notify = dry-run: NÃO toca no baseline — senão o smoke-test manual
#          silencia o alerta da rodada agendada, que foi o bug wa-8fzuk/wa-4fmxd)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${SILENT_IGN_SCAN:-$HERE/error-empty-conflation-scan.sh}"
BASELINE="${SILENT_IGN_BASELINE:-/Users/athos/gt/.gascity-gastown-hq/.gc/silent-ignorance-baseline.tsv}"
ESCALATE_DAYS="${SILENT_IGN_ESCALATE_DAYS:-7}"
NOTIFY_BIN="${SILENT_IGN_NOTIFY:-$HOME/.local/bin/notify}"
ROOTS="${SILENT_IGN_ROOTS:-}"
notify_mode=0; seed_mode=0

while [ $# -gt 0 ]; do
  case "$1" in
    --notify)   notify_mode=1; shift ;;
    --seed)     seed_mode=1; shift ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    *) echo "silent-ignorance-watch: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── as raízes: derivadas do rig list, NUNCA hardcoded ────────────────────────
# (ga-shqn: a lista hardcoded do root-class-count.sh já nascia sem gastown[50 beads]
#  e marketing[5]. Rig novo = nunca varrido, e ninguém percebe.)
if [ -z "$ROOTS" ]; then
  HQ="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
  ROOTS="$HQ"
  rigs_json=$(gc --city "$HQ" rig list --json 2>/dev/null)
  if [ -z "$rigs_json" ]; then
    echo "silent-ignorance-watch: ERRO — 'gc rig list' não respondeu. NÃO é 'zero rigs':" >&2
    echo "  não consigo saber o que varrer, então não afirmo nada. (Ignorância Silenciosa)" >&2
    exit 3
  fi
  for p in $(printf '%s' "$rigs_json" | jq -r '.rigs[].path // empty' 2>/dev/null); do
    case " $ROOTS " in *" $p "*) continue ;; esac
    [ -d "$p" ] || { echo "  aviso: rig '$p' está no rig list mas NÃO existe em disco — varredura INCOMPLETA" >&2; continue; }
    ROOTS="$ROOTS $p"
  done
fi

# ── varre. Erro do scanner NUNCA pode virar "0 achados". ─────────────────────
# ⚠️ NÃO ponha este for num PIPE (`for ... done | sort > f`). A v1 fazia isso e o
# `exit 3` de dentro saía só do SUBSHELL — o script seguia e reportava "0 achados"
# com o scanner QUEBRADO. Peguei falsificando (scanner inexistente + baseline válido
# -> exit=0, "0 achado(s)"). O monitor da Ignorância Silenciosa era, ele mesmo, uma
# instância dela. Escrevendo direto no arquivo, o `exit` roda no shell principal.
tmp_all=$(mktemp); tmp_raw=$(mktemp); tmp_new=$(mktemp)
trap 'rm -f "$tmp_all" "$tmp_raw" "$tmp_new" "${tmp_all}.keys" 2>/dev/null' EXIT
: > "$tmp_raw"
for r in $ROOTS; do
  out=$(bash "$SCAN" --path "$r" --quiet 2>/dev/null); rc=$?
  # rc 0/1 = varreu (com ou sem achados). Qualquer outra coisa = NÃO OLHEI.
  if [ "$rc" -gt 1 ]; then
    echo "silent-ignorance-watch: ERRO — scanner falhou em '$r' (rc=$rc). NÃO é 'zero achados'." >&2
    echo "  não consegui varrer -> não afirmo nada sobre este root. (Ignorância Silenciosa)" >&2
    exit 3
  fi
  printf '%s\n' "$out" | grep -E ':(C1|C2|C3):' >> "$tmp_raw" || true
done
sed 's/[[:space:]]*$//' "$tmp_raw" | sort -u > "$tmp_all"

total=$(wc -l < "$tmp_all" | tr -d '[:space:]')
now=$(date +%s)

# chave estável: arquivo:categoria:código (SEM o número da linha — senão qualquer
# edição acima desloca tudo e o monitor grita 291 falsos "novos" no dia seguinte).
key_of() { awk -F: '{cat=""; for(i=1;i<=NF;i++) if($i=="C1"||$i=="C2"||$i=="C3"){cat=$i; ci=i; break} code=""; for(j=ci+1;j<=NF;j++) code=code (j>ci+1?":":"") $j; gsub(/^[[:space:]]+|[[:space:]]+$/,"",code); print $1 "\t" cat "\t" code}' "$1"; }

# ── persist_baseline <keys> <delta|/dev/null> ────────────────────────────────
# ⚠️ NUNCA reescreva o baseline carimbando $now em TUDO. O relógio é POR ACHADO.
# A v1 fazia `key_of ... | awk -v t="$now" '{print $0 "\t" t}' > "$BASELINE"`: como a
# regravação dispara quando aparece 1 NOVO em QUALQUER rig, o first-seen dos outros
# ~290 era zerado junto. Nenhum achado jamais completaria ESCALATE_DAYS intactos ⇒ a
# re-escalação NUNCA dispararia, e o monitor voltaria a "avisa 1x e cala pra sempre"
# (wa-k288h) — o bug que este arquivo existe pra prevenir, reintroduzido pela própria
# linha que declara preveni-lo, via reset de timestamp em vez de set sem timestamp.
# Achado pelo revisor do gate (run ga-wisp-3ip2my) e REPRODUZIDO antes de aceitar:
# achado com epoch de 10 dias virou "visto agora" porque um achado ALHEIO apareceu.
# Regra: quem já está no baseline PRESERVA o first-seen; NOVO nasce agora; e quem
# acabou de ser re-escalado reinicia o relógio (re-escala a cada ESCALATE_DAYS, não a
# cada rodada).
persist_baseline() {
  local keys="$1" delta="$2" prev="$BASELINE"
  [ -r "$prev" ]  || prev=/dev/null      # 1ª semeadura: não há epoch anterior
  [ -r "$delta" ] || delta=/dev/null     # --seed: não há re-escalados
  awk -F'\t' -v OFS='\t' -v t="$now" -v bf="$prev" -v df="$delta" '
    FILENAME == bf { old[$1 FS $2 FS $3] = $4; next }
    FILENAME == df { if ($1 == "ANTIGO") re[$2 FS $3 FS $4] = 1; next }
    {
      k = $1 FS $2 FS $3
      if (k in re)        e = t          # re-escalado agora  -> reinicia o relógio
      else if (k in old)  e = old[k]     # segue aberto       -> PRESERVA o first-seen
      else                e = t          # NOVO               -> nasce agora
      print $0, e
    }
  ' "$prev" "$delta" "$keys" > "${BASELINE}.tmp" && mv "${BASELINE}.tmp" "$BASELINE"
}

if [ "$seed_mode" = "1" ]; then
  key_of "$tmp_all" > "${tmp_all}.keys"
  persist_baseline "${tmp_all}.keys" /dev/null
  echo "silent-ignorance-watch: baseline semeado com $total achado(s) — nada alertado (é a dívida existente)."
  exit 0
fi

if [ ! -r "$BASELINE" ]; then
  echo "silent-ignorance-watch: ERRO — baseline ausente/ilegível ($BASELINE)." >&2
  echo "  SEM baseline eu não sei o que é NOVO. Rode --seed primeiro. NÃO vou reportar 'nada novo'." >&2
  exit 3
fi

# ── delta: o que é NOVO + o que segue aberto há >= ESCALATE_DAYS ─────────────
key_of "$tmp_all" > "${tmp_all}.keys"
cutoff=$((now - ESCALATE_DAYS * 86400))
awk -F'\t' -v OFS='\t' -v cutoff="$cutoff" '
  NR==FNR { seen[$1 FS $2 FS $3] = $4; next }
  {
    k = $1 FS $2 FS $3
    if (!(k in seen))          { print "NOVO", $0; next }
    if (seen[k] + 0 < cutoff)  { print "ANTIGO", $0 }   # re-escala (lição wa-k288h)
  }' "$BASELINE" "${tmp_all}.keys" > "$tmp_new"

# ⚠️ NÃO use `$(grep -c ... || echo 0)` aqui. `grep -c` JÁ IMPRIME "0" quando não acha,
# E sai com rc=1 — então o `|| echo 0` acrescenta um SEGUNDO zero e a variável vira "0\n0",
# que estoura o `[ -gt ]` com "integer expression expected". Foi o que aconteceu na v1 deste
# arquivo: eu escrevi, no monitor da Ignorância Silenciosa, o EXATO idioma `|| echo "0"` que
# o scanner flagra como C2. (Peguei porque rodei e li o stderr, não porque revisei.)
# `grep -c` sem `||` já dá o que a gente quer: conta certa, e o rc a gente ignora de propósito
# porque "zero linhas" aqui é um fato legítimo, não um erro — o erro do scanner já foi
# tratado lá em cima, com exit 3.
novos=$(grep -c '^NOVO' "$tmp_new" 2>/dev/null); novos=${novos:-0}
reesc=$(grep -c '^ANTIGO' "$tmp_new" 2>/dev/null); reesc=${reesc:-0}

echo "silent-ignorance-watch: $total achado(s) no total | $novos NOVO(s) | $reesc re-escalado(s) (>=${ESCALATE_DAYS}d)"
[ "$novos" = "0" ] && [ "$reesc" = "0" ] && exit 0
grep '^NOVO' "$tmp_new" | head -20 | cut -f2,3,4

if [ "$notify_mode" = "0" ]; then
  echo "(dry-run: baseline INTACTO — use --notify pra alertar de verdade)"
  exit 0
fi

msg="Ignorância Silenciosa: $novos achado(s) NOVO(s)$([ "$reesc" -gt 0 ] && echo ", $reesc antigo(s) sem tratar >=${ESCALATE_DAYS}d")
$(grep '^NOVO' "$tmp_new" | head -8 | awk -F'\t' '{print "  • " $2 " [" $3 "]"}')
(total: $total | baseline: $(wc -l < "$BASELINE" | tr -d '[:space:]'))"

# lição wa-4fmxd: SÓ persiste o baseline DEPOIS de a entrega ser confirmada.
# Aviso não entregue = baseline intacto = a próxima rodada re-tenta. Um ntfy falho
# NÃO PODE consumir o alerta (foi assim que 58 msgs morreram caladas no wa-mzfm0).
if [ ! -x "$NOTIFY_BIN" ]; then
  echo "silent-ignorance-watch: ERRO — notify não encontrado em '$NOTIFY_BIN'; baseline INTACTO." >&2
  exit 3
fi
if ! "$NOTIFY_BIN" -t "🔇 Ignorância Silenciosa" -p 4 "$msg" >/dev/null 2>&1; then
  echo "silent-ignorance-watch: ERRO — notify falhou; baseline INTACTO, próxima rodada re-tenta." >&2
  exit 3
fi
persist_baseline "${tmp_all}.keys" "$tmp_new"
echo "alertado e baseline atualizado (first-seen dos achados que continuam abertos PRESERVADO)."
exit 0
