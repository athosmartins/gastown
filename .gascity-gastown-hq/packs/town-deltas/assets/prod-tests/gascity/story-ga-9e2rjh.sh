#!/usr/bin/env bash
# prod-tests/gascity/story-ga-9e2rjh.sh — prod test for ga-9e2rjh: critério de saúde do MBP por RAM
# disponível + pressão de memória + CRESCIMENTO do swap (o swap usado virou só um teto absoluto), e
# toda recusa do preflight gravada no log com o motivo.
#
# Defeito (medido 11/10): o MBP ocioso fica em 4,9-5,2 GB de swap "usado" (o macOS não devolve swap
# depois de uma pressão) e o limiar fixo de 5 GB recusou uma execução com 3,8 GB de RAM disponível.
#
# Called by run.sh after deploy (STORY_ID=ga-9e2rjh). Exits 0 on pass. Os scripts do gascity rodam no
# lugar (ver delivery-runbooks.toml), então o que se confere aqui É a versão em produção. Não toca o
# MBP nem o log vivo: o selftest do próprio mbp-run.sh é hermético (ssh/rsync falsos no PATH).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUN="$CITY/scripts/mbp-run.sh"
OFFLOAD="$CITY/scripts/mbp-offload.sh"
SELFTEST="$CITY/scripts/mbp-run.selftest.sh"
RUNBOOK="$CITY/docs/runbooks/mbp-offload.md"

log()  { echo "[prod-test:gascity ga-9e2rjh] $*"; }
fail() { echo "[prod-test:gascity ga-9e2rjh] FAIL: $*" >&2; exit 1; }

# ── Os arquivos implantados existem e passam no parser do bash ────────────────
for f in "$RUN" "$OFFLOAD" "$SELFTEST" "$RUNBOOK"; do
  [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"
done
for f in "$RUN" "$OFFLOAD" "$SELFTEST"; do
  bash -n "$f" 2>/dev/null || fail "erro de sintaxe em $f"
done
log "mbp-run.sh, mbp-offload.sh, selftest e runbook presentes; sintaxe ok"

# ── Estrutural: cada porta do preflight está no script implantado, uma vez só ──
# vazio (marcador ausente) → count 0 → FAIL (a porta não foi implantada); grep falhou/ilegível → também
# count 0 → FAIL. Nunca vira "ok": só passa com exatamente 1 linha marcada por porta.
for gate in ram ilegivel-avail pressao ilegivel-pressao ilegivel-delta cresce ilegivel-swap teto ilegivel-power ilegivel-batt; do
  n=$(grep -c "# gate:$gate\$" "$RUN" 2>/dev/null || true)
  [[ "${n:-0}" == "1" ]] || fail "porta '# gate:$gate' aparece ${n:-0}x em $RUN (esperado 1) — critério novo não implantado"
done
log "as 10 portas do preflight estão no script implantado ✓"

# vazio (sem a linha do teto) → FAIL; falhou/ilegível → FAIL. O teto antigo (5120) como padrão é o defeito.
swap_default=$(sed -n 's/^MAX_SWAP_MB=\${MBP_MAX_SWAP_MB:-\([0-9]*\)}.*/\1/p' "$RUN" 2>/dev/null | head -1)
[[ "$swap_default" == "8192" ]] \
  || fail "teto absoluto do swap em $RUN é '${swap_default:-<ausente>}' (esperado 8192; 5120 é o limiar antigo que recusava swap parado)"
log "teto absoluto do swap = 8192 MB ✓"

# ── O log de recusa e o status por motivo estão implantados ──────────────────
grep -q '^log_refusal()' "$RUN" || fail "log_refusal() ausente em $RUN — recusa do preflight não vai pro log"
grep -q '^preflight || { rc=\$?; log_refusal; exit \$rc; }' "$RUN" \
  || fail "o caminho normal não chama log_refusal depois de um preflight que recusa"
# vazio (sem a linha) → FAIL; falhou/ilegível (help sem texto) → FAIL
bash "$OFFLOAD" help 2>/dev/null | grep -q '72 h' \
  || fail "mbp-offload.sh help não menciona a contagem de recusas das últimas 72 h"
grep -q 'recent_counts()' "$OFFLOAD" || fail "recent_counts() ausente em $OFFLOAD"
grep -q '^  counts) recent_counts' "$OFFLOAD" || fail "subcomando 'counts' ausente em $OFFLOAD"
# a contagem avisa linha ilegível em vez de omitir (senão uma recusa truncada deixa "nenhuma" mentir)
grep -q 'linha(s) ilegível(is) no log' "$OFFLOAD" || fail "recent_counts não avisa linha ilegível do log"
log "recusa vai pro log com motivo; counts/status contam por motivo (72 h) e avisam linha ilegível ✓"

# ── Runbook: descreve o critério novo e não o limiar antigo de 5 GB ──────────
for key in swap_cresce swap_teto pressao 'ilegivel:'; do
  grep -q -- "$key" "$RUNBOOK" || fail "runbook não descreve o motivo '$key'"
done
if grep -q 'swap usado >= 5 GB' "$RUNBOOK"; then
  fail "runbook ainda diz 'swap usado >= 5 GB' (critério antigo)"
fi
log "runbook descreve o critério novo ✓"

# ── Comportamental: o selftest hermético passa inteiro contra a árvore viva ───
# Inclui o caso do defeito (swap 5.248 MB parado com 3,9 GB livres PASSA), RAM baixa (recusa) e o controle
# negativo (cada porta removida deixa o mutante de reproduzir o motivo). vazio (sem saída) → FAIL;
# timeout/falhou → FAIL; resultado sem a linha "N/N ok" com N==N → FAIL.
OUT="$(timeout 900 bash "$SELFTEST" 2>&1)" || {
  echo "$OUT" | tail -30 >&2
  fail "mbp-run.selftest.sh falhou (ou estourou 900 s) contra a árvore viva"
}
line=$(printf '%s\n' "$OUT" | grep -E '^[0-9]+/[0-9]+ ok$' | tail -1)
[[ -n "$line" ]] || fail "selftest sem a linha de resultado 'N/N ok':
$OUT"
pass=${line%%/*}; rest=${line#*/}; total=${rest%% *}
[[ "$pass" == "$total" && "$total" -ge 100 ]] \
  || fail "selftest reportou '$line' (esperado todos ok e pelo menos 100 casos)"
printf '%s\n' "$OUT" | grep -q 'SELFTEST OK' || fail "selftest sem a linha 'SELFTEST OK'"
log "selftest hermético: $line ✓"

log "PASS"
exit 0
