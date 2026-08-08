#!/usr/bin/env bash
# root-class-count.sh — conta as instâncias da classe-raiz ga-p5q3
# ("não sei" lido como "confirmado" / error e empty produzindo o mesmo valor).
#
# POR QUE ISTO É UM SCRIPT E NÃO "é só rodar um bd list":
# A query "óbvia" MENTE de duas formas, e as duas morderam de verdade em 16/07:
#
#   1. `bd list` EXCLUI closed por padrão. Sem `--status all` o HQ devolvia 3 em vez
#      de 10 — e a mila quase reportou ao Mayor que "o label não pegou" baseada nisso
#      (conferiu com `bd show` antes de mandar, e por isso não errou).
#   2. `bd list -C <store>` NÃO enxerga os outros stores. O Mayor reportou baseline
#      9 rodando só no HQ; o real era 13 (10 HQ + 3 whatsapp_automation).
#
# O risco concreto: alguém mede 9 na semana que vem, compara com o 13 de hoje e
# conclui que MELHOROU sem nada ter melhorado. Uma medição que subconta em silêncio
# é a própria classe que ela deveria estar medindo — foi assim que ela nasceu aqui
# (o Mayor cometeu a classe ao medir a classe; a mila pegou).
#
# Uso:  bash scripts/root-class-count.sh
# Ver:  memória error-and-empty-must-not-produce-the-same-value
set -uo pipefail

LABEL="${ROOT_CLASS_LABEL:-root-class:error-vs-empty}"
GC_ROOT="${GC_ROOT:-/Users/athos/gt}"

# ── A lista de stores é DERIVADA, não hardcoded (ga-shqn, achado pela mila-wa) ──
# A v1 hardcodava 4 stores (HQ + whatsapp_automation + property_scrapers + lexbh) e JÁ
# nascia incompleta: `gc rig list` tem 7 — faltavam deacon, marketing (5 beads) e
# **gastown (50 beads)**. Uma contagem que varre 4 de 7 stores e não diz nada produz o
# veredito "o remédio pegou" a partir de amostra parcial, EM SILÊNCIO — a própria classe
# que este script existe pra medir. Rig novo entra sozinho; rig removido some do `gc rig
# list` junto. Se a derivação falhar, o script PARA (não cai pro hardcoded — um fallback
# mudo seria o mesmo bug de novo).
if [ -n "${ROOT_CLASS_STORES:-}" ]; then
  STORES="$ROOT_CLASS_STORES"          # override explícito (testes/falsificação)
else
  # Use o PATH que o gc informa — não construa "$GC_ROOT/$nome" na mão. O `gc rig list`
  # já resolve cada store, inclusive o do próprio city (`gascity` → .gascity-gastown-hq,
  # que NÃO é $GC_ROOT/gascity). Montar o caminho por convenção inventava um dir que não
  # existe e disparava meu próprio alarme de AUSENTE — falso-positivo meu, no ato de
  # consertar o falso-negativo dela. Pergunte à ferramenta em vez de adivinhar.
  STORES=$(gc rig list --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
rigs = d if isinstance(d, list) else (d.get('rigs') or [])
out = []
for r in rigs:
    if not isinstance(r, dict):
        continue
    p = (r.get('path') or r.get('work_dir') or '').strip()
    if p and p not in out:
        out.append(p)
print(' '.join(out))
" 2>/dev/null)
  if [ -z "$STORES" ]; then
    echo "FATAL: 'gc rig list' não devolveu paths — NÃO vou contar com uma lista parcial." >&2
    echo "       (contagem parcial silenciosa é a própria classe ga-p5q3 que este script mede)" >&2
    echo "       Use ROOT_CLASS_STORES=... para forçar uma lista explícita." >&2
    exit 2
  fi
fi

total=0
missing=0
echo "═══ instâncias de $LABEL ($(date '+%Y-%m-%d %H:%M')) ═══"
for S in $STORES; do
  # ga-shqn: store ausente NÃO pode ser pulado em silêncio (era `[ -d ] || continue`,
  # ACIMA do guard de query, então o guard nunca o via). Rig movido/renomeado derrubava
  # a contagem sem UMA linha de aviso — "não olhei" indistinguível de "olhei e deu 0".
  if [ ! -d "$S" ]; then
    printf '  %-24s %s\n' "$(basename "$S")" "AUSENTE (dir não existe) — contagem INCOMPLETA"
    missing=$((missing + 1))
    continue
  fi
  # --status all é OBRIGATÓRIO: sem ele os beads FECHADOS (a maioria, quando o fix
  # funciona) somem e a contagem despenca sem que nada tenha melhorado.
  n=$(bd -C "$S" list --label "$LABEL" --status all --json 2>/dev/null \
      | python3 -c "import sys,json;d=json.load(sys.stdin,strict=False);print(len(d if isinstance(d,list) else d.get('issues',[])))" 2>/dev/null)
  # Erro de query e "zero instâncias" NÃO podem virar o mesmo valor — a lição do próprio bead.
  if [ -z "$n" ]; then
    echo "  $(basename "$S"): ERRO na query (NÃO é zero — a contagem abaixo está INCOMPLETA)"
    continue
  fi
  printf '  %-24s %s\n' "$(basename "$S")" "$n"
  total=$((total + n))
done
echo "  ────────────────────────"
if [ "$missing" -gt 0 ]; then
  echo "  TOTAL: $total  ⚠️ INCOMPLETO ($missing store(s) AUSENTE(s) — veja acima)"
else
  echo "  TOTAL: $total"
fi
echo
cat <<'INTERP'
  ⚠️ NÃO LEIA ESTE TOTAL COMO "PIOROU" OU "MELHOROU". ELE NÃO MEDE ISSO.

  baseline 2026-07-16 = 13  ·  2026-07-17 = 33  (+20 em UM DIA)

  Esse salto NÃO significa que a classe explodiu. Significa que na madrugada de 17/07
  quatro agentes fizeram uma CAÇADA e etiquetaram 20 instâncias que já existiam há
  semanas. Este contador mede **quantas foram ETIQUETADAS**, não quantas EXISTEM.
  "A classe piorou" e "nós olhamos com mais cuidado" produzem O MESMO NÚMERO — que é,
  literalmente, a classe que este script existe para medir, cometida pelo script.
  (O texto anterior aqui mandava ler alta = remédio falhou. Estava errado e foi removido:
  uma métrica confundida que dá veredito é pior que métrica nenhuma, porque autoriza ação.)

  ⇒ A PERGUNTA CERTA, que ESTE script não responde: o remédio (a dimensão 'terceiro estado'
  no prompt do gate-reviewer, ga-31ac) existe pra fazer o GATE PEGAR a instância ANTES do
  merge. Então a métrica honesta é a TAXA DE CAPTURA, não a contagem:

      pegas pelo gate (verdict FAIL citando a classe)  ÷  (pegas pelo gate + achadas depois em prod)

  Essa fração tem denominador e não é inflada por caçada: se dobrarmos o esforço de busca,
  os dois lados sobem juntos. Subir = o remédio pegando. Cair = escapando.

  ENQUANTO ISSO, use este total só para: (a) inventário — saber o que existe pra consertar;
  (b) confirmar que instâncias novas estão sendo etiquetadas em TODOS os stores.
  Nunca para: julgar se melhorou. Etiquete TODA nova instância ao filar, em QUALQUER store.
INTERP
