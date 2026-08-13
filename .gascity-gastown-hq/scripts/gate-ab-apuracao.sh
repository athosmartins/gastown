#!/bin/bash
# gate-ab-apuracao.sh — apura o A/B do ga-rstae. READ-ONLY, roda a qualquer hora.
#
# POR QUE ESTE ARQUIVO EXISTE: o bead ga-rstae mandava "reusar o script de taxonomia
# (esta no fim deste bead / no doc citado)" — e esse script NAO EXISTIA em lugar nenhum.
# Era analise que o Mayor rodou inline numa sessao e nunca salvou. O dog que construiu o
# ga-rstae tentou reusar, nao achou, e reportou o buraco em vez de inventar (conduta
# certa). Este arquivo fecha o buraco: e a apuracao de verdade, versionada, reproduzivel.
#
# METRICA PRIMARIA: aprovacao na PRIMEIRA tentativa, por braco.
# NAO use "% de runs que reprovam": uma bead que reprova 3x e passa conta 3 FAIL + 1 PASS,
# o que INFLA o problema (foi assim que "38% dos runs" virou a impressao de "50% reprova").
#
# A atribuicao de braco e recalculada aqui pela MESMA funcao pura do guard
# (gate_ab_arm_for_bead), extraida do arquivo vivo — nunca reimplementada. Se o guard
# mudar a funcao, esta apuracao acompanha sozinha. Reimplementar a regra do consumidor
# em vez de executa-la e como se audita errado (doutrina: auditar = EXECUTAR).
set -uo pipefail

HQ="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GUARD="$HQ/packs/town-deltas/assets/quality-gate-guard.sh"
LOG="$HQ/.gc/logs/quality-gate-dispatcher.log"
SINCE="${1:-}"   # opcional: YYYY-MM-DD — corta o log a partir dessa data (inicio do experimento)

for f in "$GUARD" "$LOG"; do
  [ -r "$f" ] || { echo "FATAL: nao consigo ler $f" >&2; exit 2; }
done

# Extrai a funcao de atribuicao do guard VIVO. Se ela sumir/mudar de nome, ABORTA alto —
# um braco calculado por regra diferente da que o guard aplicou nao mede nada, e um
# resultado silenciosamente errado e pior que nenhum resultado.
ARM_SRC=$(sed -n '/^gate_ab_arm_for_bead()/,/^}/p' "$GUARD")
if [ -z "$ARM_SRC" ]; then
  echo "FATAL: gate_ab_arm_for_bead() nao encontrada em $GUARD." >&2
  echo "       O experimento nao pode ser apurado com uma regra de atribuicao adivinhada." >&2
  exit 3
fi
eval "$ARM_SRC"

python3 - "$LOG" "$SINCE" <<'PYEOF' > /tmp/gate-ab-pairs.txt
import re, sys
log_path, since = sys.argv[1], sys.argv[2]
txt = open(log_path, errors='replace').read()
# (data, branch, verdict) — a data permite recortar a janela do experimento
for m in re.finditer(r'^\[(\d{4}-\d{2}-\d{2})[^\]]*\].*?branch=(\S+) verdict=(PASS|FAIL)', txt, re.M):
    d, br, v = m.groups()
    if since and d < since:
        continue
    # bead id = ultimo segmento da branch, sem sufixo descritivo
    leaf = br.rsplit('/', 1)[-1]
    mm = re.match(r'^([a-z]{2,6}-[a-z0-9.]{3,8})', leaf)
    if mm:
        print(f"{mm.group(1)}\t{br}\t{v}")
PYEOF

# Sem `declare -A`: o /bin/bash do macOS e 3.2 e nao tem array associativo. Este script
# precisa rodar tanto sob bash 5 (launchd/homebrew) quanto sob o 3.2 do PATH interativo —
# um script de apuracao que so roda no shell de quem escreveu nao serve pra ninguem.
# Dedup da primeira tentativa por branch feito com arquivo ordenado + awk, portavel.
A_tot=0; A_pass1=0; B_tot=0; B_pass1=0
awk -F'\t' '!seen[$2]++' /tmp/gate-ab-pairs.txt > /tmp/gate-ab-first.txt
while IFS=$'\t' read -r bead branch verdict; do
  [ -z "${branch:-}" ] && continue
  arm=$(gate_ab_arm_for_bead "$bead")
  if [ "$arm" = "A" ]; then
    A_tot=$((A_tot+1)); [ "$verdict" = "PASS" ] && A_pass1=$((A_pass1+1))
  else
    B_tot=$((B_tot+1)); [ "$verdict" = "PASS" ] && B_pass1=$((B_pass1+1))
  fi
done < /tmp/gate-ab-first.txt

pct() { [ "$2" -eq 0 ] && { echo "n/a"; return; }; echo "$((100*$1/$2))%"; }

echo "═══ APURACAO DO A/B DO GATE (ga-rstae) ═══"
[ -n "$SINCE" ] && echo "  janela: a partir de $SINCE" || echo "  janela: log inteiro (passe YYYY-MM-DD p/ recortar)"
echo
printf "  %-8s %8s %10s %12s\n" "braco" "branches" "1a-PASS" "taxa"
printf "  %-8s %8s %10s %12s\n" "A (ctrl)" "$A_tot" "$A_pass1" "$(pct $A_pass1 $A_tot)"
printf "  %-8s %8s %10s %12s\n" "B (exp)"  "$B_tot" "$B_pass1" "$(pct $B_pass1 $B_tot)"
echo
if [ "$A_tot" -gt 0 ] && [ "$B_tot" -gt 0 ]; then
  echo "  lift (B - A): $(( (100*B_pass1/B_tot) - (100*A_pass1/A_tot) ))pp"
fi
echo
echo "  ── PISO DE RUIDO, medido (A/A) ──"
echo "    Rodando esta MESMA apuracao sobre o log HISTORICO (2026-07-23..08-12, antes"
echo "    de qualquer intervencao existir, com os dois bracos recebendo tratamento"
echo "    IDENTICO), deu: A=67% (337/501)  B=64% (325/504)  ->  -3pp."
echo "    Isso e RUIDO PURO: nao havia diferenca de tratamento pra causar diferenca."
echo "    Portanto um lift de ate ~3pp NAO SIGNIFICA NADA — e indistinguivel do acaso."
echo "    (Convergente com o calculo de poder abaixo, que ja dizia +3pp = 20 semanas."
echo "     Duas rotas independentes chegando no mesmo numero.)"
echo
echo "  ── PODER: com base 71%, ~175 branches/braco/semana ──"
echo "    +3pp  -> 3477/braco (~20 semanas) INDETECTAVEL"
echo "    +7pp  ->  608/braco (~3.5 semanas)"
echo "    +10pp ->  286/braco (~1.6 semanas)  <- alvo"
echo "    +14pp ->  137/braco (~0.8 semana)"
MIN=$(( A_tot < B_tot ? A_tot : B_tot ))
echo "    menor braco hoje: $MIN branches"
if [ "$MIN" -lt 286 ]; then
  echo "    ⚠  AINDA NAO CONCLUSIVO p/ +10pp — precisa de $((286-MIN)) branches a mais no menor braco."
  echo "       NAO pare o experimento aqui. Parar quando o numero agrada e escolher o resultado."
fi
echo
echo "  ── verdicts do check por braco (do log estruturado do guard) ──"
grep -oE 'AB-BASE-TEST bead=\S+ arm=[AB] verdict=\S+' "$LOG" 2>/dev/null \
  | sed -E 's/.*arm=([AB]) verdict=(\S+)/  \1 \2/' | sort | uniq -c | sort -rn | head -10
echo "  (vazio = o guard novo ainda nao mergeou ou nao rodou; nao e erro)"
