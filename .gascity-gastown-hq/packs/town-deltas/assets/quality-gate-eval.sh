#!/usr/bin/env bash
# quality-gate-eval.sh — Avaliação periódica do quality gate.
#
# Lê quality-gate.jsonl, computa métricas do período (padrão: 7 dias) e
# produz um resumo em português plain-text que o operador pode ler em
# menos de 20 segundos.
#
# ADVISORY ONLY: este script NÃO altera configurações, NÃO redespacha
# trabalho e NÃO toma ações autônomas. Apenas lê, computa e reporta.
#
# Scheduling: launchd semanal (com.gascity.quality-gate-eval.plist).
# Para rodar manualmente: bash ~/.gascity-gastown-hq/packs/town-deltas/assets/quality-gate-eval.sh
#
# City-local artifact — NOT a framework Deacon plugin.
# Mirror of quality-gate-guard.sh placement pattern.

set -euo pipefail

GC_CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
EVAL_LOG="${QG_EVAL_LOG:-$GC_CITY/.gc/quality-gate-eval.log}"
QG_LOG="${QG_LOG:-$GC_CITY/.gc/quality-gate.jsonl}"

mkdir -p "$LOG_DIR"
exec >> "$LOG_DIR/quality-gate-eval.log" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-eval] $*"; }
# warn always goes to stderr (fd2) so it never pollutes command-substitution captures
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-eval] WARN: $*" >&2; }

echo ""
log "=== Quality Gate Auto-Evaluation start ==="

PERIOD_DAYS="${QG_EVAL_PERIOD_DAYS:-7}"

# ── Funções auxiliares ────────────────────────────────────────────────────────

# Avalia um valor contra um limiar: retorna "manter" se ok, "precisa melhorar" caso contrário
# Uso: judge_lower_better <valor> <warn_threshold> <fail_threshold>  (menor = melhor)
judge_lower_better() {
  local val="$1"
  local warn="$2"
  local fail="${3:-$warn}"
  if awk "BEGIN{exit !($val > $fail)}"; then
    echo "PRECISA MELHORAR"
  elif awk "BEGIN{exit !($val > $warn)}"; then
    echo "ATENCAO"
  else
    echo "MANTER"
  fi
}

# Avalia taxa: retorna "manter" se acima do limiar, "precisa melhorar" caso contrário
# Uso: judge_higher_better <valor 0.0-1.0> <warn_threshold> <fail_threshold>
judge_higher_better() {
  local val="$1"
  local warn="$2"
  local fail="$3"
  if awk "BEGIN{exit !($val < $fail)}"; then
    echo "PRECISA MELHORAR"
  elif awk "BEGIN{exit !($val < $warn)}"; then
    echo "ATENCAO"
  else
    echo "MANTER"
  fi
}

# Formata segundos em "Xm" ou "Xh Ym"
fmt_elapsed() {
  local s="$1"
  if [ "$s" -lt 60 ]; then
    echo "${s}s"
  elif [ "$s" -lt 3600 ]; then
    echo "$((s / 60))m"
  else
    local h=$((s / 3600))
    local m=$(( (s % 3600) / 60 ))
    echo "${h}h ${m}m"
  fi
}

# ── Detecção de escapes (best-effort v1) ─────────────────────────────────────
#
# Metodologia v1: procura commits cujas mensagens contêm "revert" ou
# "hotfix" no branch main do rig gastown dentro do período.
# Isso é uma aproximação — não detecta reverts silenciosos, fixes em branches
# separadas ou rollbacks de infra. Marcado explicitamente como "estimativa v1".
#
# Retorna o número de commits suspeitos.
detect_escapes_bestv1() {
  local since_date
  since_date=$(date -u -v -"${PERIOD_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u --date="${PERIOD_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "")

  if [ -z "$since_date" ]; then
    warn "Não foi possível calcular data de início do período"
    echo "N/A"
    return
  fi

  # Rig path: gastown rig lives alongside the city dir
  local city_parent rig_path
  city_parent=$(dirname "$GC_CITY")
  rig_path="$city_parent/gastown"

  if [ ! -d "$rig_path/.git" ]; then
    warn "Rig gastown não encontrado em $rig_path — escapes não verificados"
    echo "N/A"
    return
  fi

  local count
  count=$(git -C "$rig_path" log \
    --oneline \
    --since="$since_date" \
    main \
    2>/dev/null \
    | grep -Eic "(^[a-f0-9]+ revert |^[a-f0-9]+ hotfix)" || echo "0")

  echo "$count"
}

# ── Verifica existência do log do quality gate ────────────────────────────────

if [ ! -f "$QG_LOG" ]; then
  cat <<NODATA

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AVALIAÇÃO PERIÓDICA: Quality Gate
Período: últimos ${PERIOD_DAYS} dias
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Sem dados: log não encontrado em $QG_LOG
  O quality gate ainda não produziu nenhum registro neste ambiente.
  Aguarde ao menos um ciclo completo antes da próxima avaliação.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NODATA
  log "Log não encontrado — avaliação encerrada sem dados."
  exit 0
fi

# ── Thresholds (editáveis) ────────────────────────────────────────────────────
MAX_ESCAPES="${QG_EVAL_MAX_ESCAPES:-0}"
AVG_ELAPSED_WARN_S="${QG_EVAL_AVG_ELAPSED_WARN_S:-3600}"   # 1h
AVG_ELAPSED_FAIL_S="${QG_EVAL_AVG_ELAPSED_FAIL_S:-14400}"  # 4h
PASS_RATE_WARN="${QG_EVAL_PASS_RATE_WARN:-0.80}"
PASS_RATE_FAIL="${QG_EVAL_PASS_RATE_FAIL:-0.60}"

# ── Computa métricas via python3 ──────────────────────────────────────────────
# python3 é usado para aritmética de ponto flutuante e parsing ISO8601.
# Disponível no macOS sem dependências externas.

since_iso=$(date -u -v -"${PERIOD_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u --date="${PERIOD_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u +%Y-%m-%dT%H:%M:%SZ)

metrics_json=$(python3 - "$QG_LOG" "$since_iso" <<'PYEOF'
import sys, json, datetime, collections

log_path   = sys.argv[1]
since_iso  = sys.argv[2]

try:
    since_dt = datetime.datetime.fromisoformat(since_iso.replace("Z", "+00:00"))
except Exception:
    since_dt = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)

entries = []
with open(log_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        ts_raw = e.get("ts", "")
        try:
            ts = datetime.datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
        except Exception:
            continue
        if ts >= since_dt:
            entries.append(e)

total      = len(entries)
passed     = sum(1 for e in entries if e.get("result") == "PASS")
failed     = total - passed

# Elapsed (only passed entries with elapsed_s)
elapsed_vals = [
    e["elapsed_s"] for e in entries
    if "elapsed_s" in e and e.get("result") == "PASS" and isinstance(e.get("elapsed_s"), (int, float))
]
avg_elapsed = int(sum(elapsed_vals) / len(elapsed_vals)) if elapsed_vals else -1
min_elapsed = int(min(elapsed_vals)) if elapsed_vals else -1
max_elapsed = int(max(elapsed_vals)) if elapsed_vals else -1

# Pass rate
pass_rate = (passed / total) if total > 0 else -1.0

# Issues caught: entries where result == FAIL
fail_reasons = [e.get("reason", "desconhecido") for e in entries if e.get("result") == "FAIL"]

# Cost: check if token_cost field is present and non-null on any entry
cost_values = [e["token_cost"] for e in entries if e.get("token_cost") not in (None, "", 0)]
has_cost = len(cost_values) > 0
avg_cost = sum(cost_values) / len(cost_values) if cost_values else None

# Tier breakdown
tier_code    = sum(1 for e in entries if e.get("tier") == "CODE")
tier_noncode = sum(1 for e in entries if e.get("tier") == "NON-CODE")

# Unique branches
branches = list({e.get("branch", "") for e in entries if e.get("branch")})

result = {
    "total": total,
    "passed": passed,
    "failed": failed,
    "pass_rate": pass_rate,
    "avg_elapsed": avg_elapsed,
    "min_elapsed": min_elapsed,
    "max_elapsed": max_elapsed,
    "fail_reasons": fail_reasons,
    "has_cost": has_cost,
    "avg_cost": avg_cost,
    "tier_code": tier_code,
    "tier_noncode": tier_noncode,
    "branches_count": len(branches),
}
print(json.dumps(result))
PYEOF
)

if [ -z "$metrics_json" ]; then
  warn "Falha ao computar métricas — abortando"
  exit 1
fi

# ── Extrai valores ────────────────────────────────────────────────────────────
total=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total'])")
passed=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['passed'])")
failed=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['failed'])")
pass_rate=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['pass_rate']:.2f}\" if d['pass_rate'] >= 0 else 'N/A')")
avg_elapsed=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['avg_elapsed'])")
fail_reasons_json=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['fail_reasons']))")
has_cost=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d['has_cost'] else 'false')")
avg_cost=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['avg_cost'] or 'null')")
tier_code=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tier_code'])")
tier_noncode=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tier_noncode'])")
branches_count=$(echo "$metrics_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['branches_count'])")

# ── Detecta escapes (best-effort v1) ─────────────────────────────────────────
escapes_count=$(detect_escapes_bestv1)

# ── Avalia cada métrica ───────────────────────────────────────────────────────
verdict_escapes="NAO VERIFICADO"
verdict_elapsed="SEM DADOS"
verdict_passrate="SEM DADOS"
elapsed_fmt="N/A"

# Escapes
if [ "$escapes_count" != "N/A" ]; then
  if [ "$escapes_count" -gt "$MAX_ESCAPES" ]; then
    verdict_escapes="PRECISA MELHORAR"
  else
    verdict_escapes="MANTER"
  fi
fi

# Tempo médio ready→live
if [ "$avg_elapsed" != "-1" ]; then
  elapsed_fmt=$(fmt_elapsed "$avg_elapsed")
  verdict_elapsed=$(judge_lower_better "$avg_elapsed" "$AVG_ELAPSED_WARN_S" "$AVG_ELAPSED_FAIL_S")
fi

# Taxa de aprovação
if [ "$pass_rate" != "N/A" ]; then
  verdict_passrate=$(judge_higher_better "$pass_rate" "$PASS_RATE_WARN" "$PASS_RATE_FAIL")
fi

# Custo por entrega
if [ "$has_cost" = "true" ]; then
  cost_str=$(echo "$avg_cost" | python3 -c "import sys; v=float(sys.stdin.read().strip()); print(f'~{v:.2f} tokens/entrega')" 2>/dev/null || echo "$avg_cost")
else
  cost_str="não medido ainda — campo reservado no log"
fi

# ── Lista de problemas detectados ─────────────────────────────────────────────
issues_list=""
if [ "$failed" -gt 0 ]; then
  issues_list=$(echo "$fail_reasons_json" | python3 -c "
import sys, json, collections
reasons = json.load(sys.stdin)
counts = collections.Counter(reasons)
lines = []
for reason, count in counts.most_common(5):
    label = reason.replace('_', ' ')
    lines.append(f'  • {label} ({count}x)')
print('\n'.join(lines))
" 2>/dev/null || echo "  • (não foi possível listar)")
fi

# ── Monta o resumo ────────────────────────────────────────────────────────────
ts_now=$(date -u "+%Y-%m-%d %H:%M UTC")

summary=$(cat <<SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AVALIAÇÃO PERIÓDICA: Quality Gate
Período: últimos ${PERIOD_DAYS} dias  |  Gerado em: $ts_now
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ATIVIDADE DO PERÍODO
  Entregas avaliadas : $total  (CODE: $tier_code, NON-CODE: $tier_noncode)
  Aprovadas          : $passed
  Reprovadas         : $failed
  Branches distintas : $branches_count

─────────────────────────────────────────────────────────
MÉTRICAS — VEREDICTO

1. ESCAPES PARA PRODUÇÃO  →  $verdict_escapes
   Estimativa: $escapes_count revert/hotfix no período (best-effort v1)
   Meta: ~0 escapes. Método: grep de commits "revert|hotfix" no main.
   ATENCAO: v1 não detecta rollbacks silenciosos, fixes em PRs
      ou rollbacks de infra. Sinal incompleto, use com cautela.

2. VELOCIDADE (tempo médio ready→live)  →  $verdict_elapsed
   Tempo médio: $elapsed_fmt
   Meta: < 1h (aviso) / < 4h (aceitável). Acima de 4h = precisa melhorar.

3. TAXA DE APROVAÇÃO (1ª tentativa)  →  $verdict_passrate
   Taxa: $pass_rate
   Meta: >= 80% (aviso < 80%) / >= 60% (aceitável). Abaixo de 60% = precisa melhorar.

4. CUSTO POR ENTREGA
   $cost_str

─────────────────────────────────────────────────────────
PROBLEMAS DETECTADOS NO PERÍODO
$([ "$failed" -eq 0 ] && echo "  Nenhum — todas as entregas aprovadas." || echo "$issues_list")

─────────────────────────────────────────────────────────
RESUMO EXECUTIVO
$(
  issues=0
  summary_lines=()
  [ "$verdict_escapes" = "PRECISA MELHORAR" ] && { issues=$((issues+1)); summary_lines+=("  x Escapes: detectados reverts/hotfixes — investigar causa raiz"); }
  [ "$verdict_elapsed" = "PRECISA MELHORAR" ] && { issues=$((issues+1)); summary_lines+=("  x Velocidade: tempo médio acima de 4h — revisar gargalos no gate"); }
  [ "$verdict_elapsed" = "ATENCAO" ]           && summary_lines+=("  ! Velocidade: tempo médio acima de 1h — monitorar")
  [ "$verdict_passrate" = "PRECISA MELHORAR" ] && { issues=$((issues+1)); summary_lines+=("  x Taxa de aprovação: abaixo de 60% — gate pode estar muito restritivo ou código com baixa qualidade"); }
  [ "$verdict_passrate" = "ATENCAO" ]          && summary_lines+=("  ! Taxa de aprovação: abaixo de 80% — monitorar tendência")
  [ "$total" -eq 0 ]                           && { issues=$((issues+1)); summary_lines+=("  x Sem atividade: nenhuma entrega avaliada no período"); }

  if [ ${#summary_lines[@]} -eq 0 ]; then
    echo "  Tudo dentro do esperado. Gate saudável."
  else
    printf '%s\n' "${summary_lines[@]}"
  fi
  echo ""
  echo "  Ação recomendada: $([ $issues -eq 0 ] && echo 'nenhuma — manter configuração atual' || echo 'revisar itens marcados com x acima')"
)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
)

echo "$summary"

# ── Persiste no arquivo de log de avaliação ───────────────────────────────────
mkdir -p "$(dirname "$EVAL_LOG")"
echo "$summary" >> "$EVAL_LOG"
log "Resumo gravado em $EVAL_LOG"

# ── Notifica operador ─────────────────────────────────────────────────────────
notify_msg="Quality Gate avaliação: ${total} entregas, ${passed} aprovadas, ${failed} reprovadas | Escapes: ${escapes_count} | Tempo médio: ${elapsed_fmt}"
if command -v notify >/dev/null 2>&1; then
  notify -t "Auto-Eval: Quality Gate" "$notify_msg" 2>/dev/null || true
fi

log "=== Quality Gate Auto-Evaluation complete ==="
