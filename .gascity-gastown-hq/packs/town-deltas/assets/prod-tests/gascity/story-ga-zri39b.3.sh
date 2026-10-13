#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zri39b.3.sh — prod test da fatia 3 de 4 da ga-zri39b (nó Linux de testes, Hetzner, teste de 1 semana aprovado pelo Athos em 13/10):
# relatório diário do nó (baterias por host, tempo, fallbacks, sombra, custo via hcloud), o order que o manda ao Mayor e a chave `mbp-offload.sh node on|off|status`.
#
# Contents
#   O que verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o relatório, o order e o wrapper existem e parseiam; o selftest do relatório (e do wrapper) e a seção `chave` do selftest do mbp-offload passam contra os arquivos vivos; o relatório roda de verdade na cidade viva, sem custo e só lendo o log; com hcloud e token no cofre, a linha de custo sai.
# POR QUE É SEGURO RODAR: os selftests usam stubs de ssh/rsync/python e uma cidade temporária; as leituras vivas são SÓ leitura. Nada é semeado, instalado nem apagado no servidor, e nenhuma
#   bandeira é ligada ou desligada.
# O QUE É AVISO E NÃO FALHA: o servidor é de um teste de 1 semana e o Mayor o apaga ao fim. Se o ssh ao nó não responde, os checks vivos dele viram AVISO (o código não depende de o
#   servidor existir: a cadeia cai no MBP). Se o nó RESPONDE e a base dele tem segredo ou dado, é FALHA: é o requisito de segurança da bead.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-zri39b.3). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
NODE_HOST="${HETZNER_NODE_HOST:-hetzner-teste}"
TMPS=()
cleanup() { local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do [[ -n "$d" && -d "$d" ]] && { find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null; }; done; }
trap cleanup EXIT
log()  { echo "[prod-test:gascity ga-zri39b.3] $*"; }
warn() { echo "[prod-test:gascity ga-zri39b.3] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-zri39b.3] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
tmpcity() { local d; d="$(mktemp -d "${TMPDIR:-/tmp}/zri39b-prod.XXXXXX")"; TMPS+=("$d"); mkdir -p "$d/.gc/logs"; printf '%s' "$d"; }
need() { local f; for f in "$@"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done; }
syntax() { local f; for f in "$@"; do "$BASH32" -n "$f" || fail "$f não parseia sob $BASH32"; done; }
# run_suite <rótulo> <mínimo de casos> <comando...>: o selftest tem de terminar com a linha "N/N ok" (todos ok) e o mínimo de casos
run_suite() {
  local label="$1" min="$2"; shift 2
  local out; out="$("$@" 2>&1)" || { echo "$out" | tail -25 >&2; fail "$label falhou (ou estourou o tempo) contra a árvore viva"; }
  local line; line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok$' | tail -1)
  [[ -n "$line" ]] || fail "$label sem a linha de resultado 'N/N ok':
$out"
  local pass=${line%%/*} rest=${line#*/}; local total=${rest%% *}
  [[ "$pass" == "$total" && "$total" -ge "$min" ]] || fail "$label reportou '$line' (esperado todos ok e pelo menos $min casos)"
  printf '%s\n' "$out" | grep -qE 'SELFTEST OK|RESULT: .* 0 failed' || fail "$label sem a linha final de sucesso"
  log "$label: $line ✓"
}
# a varredura de segurança no servidor de verdade (SÓ leitura): segredo ou dado de cliente na base do nó é FALHA; nó que não responde é AVISO
scan_node_base() {
  local leaks bad
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$NODE_HOST" true >/dev/null 2>&1; then warn "o nó $NODE_HOST não respondeu ao ssh — checks vivos do servidor pulados (a cadeia cai no MBP)"; return 0; fi
  leaks="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$NODE_HOST" 'cd ~/gt-remote/wa-base 2>/dev/null || { echo NOBASE; exit 0; }
    find . \( -name ".env" -o -name ".env.*" -o -name "client_secret*.json" -o -name "credentials*.json" -o -name "*.pem" -o -name "*.key" -o -name "*.duckdb*" -o -name "*.db" -o -name "*.sqlite*" -o -name "*.parquet" -o -name "*.csv" -o -name "*.gz" -o -name "*.pkl" -o -name "*.xlsx" -o -path "./shared" -o -path "./data" -o -path "./logs" \) -print 2>/dev/null | grep -v -E "^\./\.env\.example$" | head -20; echo SCAN_DONE' 2>/dev/null)"
  if [[ "$leaks" == *NOBASE* ]]; then warn "o nó ainda não tem ~/gt-remote/wa-base — a cadeia cai no MBP até lá"
  elif [[ "$leaks" != *SCAN_DONE* ]]; then warn "não consegui varrer a base do nó (ssh caiu no meio): a checagem de vazamento NÃO foi feita"
  else
    # awk, não grep -E '^(X|)$': o grep do macOS rejeita a alternativa vazia, o erro sumia no `|| true` e a lista voltava VAZIA mesmo com vazamento
    bad="$(printf '%s\n' "$leaks" | awk '$0 != "" && $0 != "SCAN_DONE"')"
    [[ -z "$bad" ]] || fail "SEGURANÇA: segredo ou dado de cliente na base do nó ($NODE_HOST:~/gt-remote/wa-base):
$bad
(o --delete-excluded da semeadura limpa; e investigue como chegou)"
    log "base do nó sem segredo nem dado (varredura no servidor) ✓"
  fi
}

RUN="$CITY/scripts/mbp-run.sh"; SELFTEST="$CITY/scripts/mbp-run.selftest.sh"; OFFLOAD="$CITY/scripts/mbp-offload.sh"
REPORT="$CITY/scripts/hetzner-daily-report.sh"; REPORT_ST="$CITY/scripts/hetzner-daily-report.selftest.sh"
ORDER="$ASSETS/../orders/hetzner-daily-report.toml"; ORDER_SH="$ASSETS/scripts/hetzner-daily-report-order.sh"
need "$RUN" "$SELFTEST" "$OFFLOAD" "$REPORT" "$REPORT_ST" "$ORDER" "$ORDER_SH"
[[ -x "$REPORT" && -x "$ORDER_SH" ]] || fail "hetzner-daily-report.sh / o wrapper do order sem permissão de execução"
syntax "$OFFLOAD" "$REPORT" "$REPORT_ST" "$ORDER_SH" "$SELFTEST"
grep -q '^trigger *= *"cron"' "$ORDER" && grep -q 'hetzner-daily-report-order.sh' "$ORDER" || fail "o order hetzner-daily-report não está no formato esperado ($ORDER)"
log "arquivos implantados presentes; sintaxe ok; order no pack ✓"

run_suite "selftest do relatório diário e do wrapper do order" 50 timeout 300 "$BASH32" "$REPORT_ST"
run_suite "selftest do mbp-offload (chave do nó, status, hoje e contagens)" 100 env MBP_SELFTEST_ONLY=chave timeout 900 "$BASH32" "$SELFTEST"

# o relatório de verdade, sem custo (nenhuma chamada à API) e SÓ lendo o log vivo: roda e diz a verdade sobre o que leu
out="$("$BASH32" "$REPORT" --no-cost 2>&1)" || fail "hetzner-daily-report.sh --no-cost falhou na cidade viva: $out"
printf '%s\n' "$out" | grep -q '^Baterias' || fail "o relatório vivo não tem a linha 'Baterias': $out"
log "relatório vivo (sem custo) ✓: $(printf '%s\n' "$out" | grep '^Baterias' | head -n 1 | cut -c1-110)"
# o custo: com hcloud e token a API responde; sem eles o relatório diz "indisponível (motivo)", nunca €0 (aviso, não falha)
if command -v hcloud >/dev/null 2>&1 && secret Hetzner --field notes >/dev/null 2>&1; then
  cost="$("$BASH32" "$REPORT" 2>&1 | grep '^Custo' | head -n 1)"
  case "$cost" in "Custo: urblink"*|"Custo: "*) log "custo: $(printf '%s' "$cost" | cut -c1-110)" ;; *) warn "o relatório não trouxe a linha de custo" ;; esac
else warn "sem hcloud ou sem o token no cofre: o custo sairia como indisponível"; fi

log "PASS"
exit 0
