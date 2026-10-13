#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zri39b.1.sh — prod test da fatia 1 de 4 da ga-zri39b (nó Linux de testes, Hetzner, teste de 1 semana aprovado pelo Athos em 13/10):
# o nó Linux entra na cadeia de mbp-run.sh (nó → MBP → mini, mesmos códigos 96..99) com o filtro de segurança do rsync; o gate e o atalho dos workers abrem com a bandeira do nó.
#
# Contents
#   O que verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): os scripts e o filtro existem e parseiam sob o /bin/bash 3.2 do macOS; o filtro tem a ORDEM de segurança (segredo/dado antes de `+ /tests/***`, conferida pelo próprio mbp-run.sh: `--host linux --check` diz node_filter_ok=1); os selftests que provam isso passam contra os arquivos vivos (o do nó, o do atalho do pytest, o do parágrafo do prompt do revisor e o do invariante de apóstrofos); o parágrafo TEST WRAPPER acompanha as bandeiras da cidade viva; e, no servidor, o preflight lê RAM, pressão, núcleos e disco e a base do nó não tem segredo nem dado.
# POR QUE É SEGURO RODAR: os selftests usam stubs de ssh/rsync/python e uma cidade temporária; as leituras vivas são SÓ leitura. Nada é semeado, instalado nem apagado no servidor, e nenhuma
#   bandeira é ligada ou desligada.
# O QUE É AVISO E NÃO FALHA: o servidor é de um teste de 1 semana e o Mayor o apaga ao fim. Se o ssh ao nó não responde, os checks vivos dele viram AVISO (o código não depende de o
#   servidor existir: a cadeia cai no MBP). Se o nó RESPONDE e a base dele tem segredo ou dado, é FALHA: é o requisito de segurança da bead.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-zri39b.1). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
NODE_HOST="${HETZNER_NODE_HOST:-hetzner-teste}"
TMPS=()
cleanup() { local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do [[ -n "$d" && -d "$d" ]] && { find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null; }; done; }
trap cleanup EXIT
log()  { echo "[prod-test:gascity ga-zri39b.1] $*"; }
warn() { echo "[prod-test:gascity ga-zri39b.1] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-zri39b.1] FAIL: $*" >&2; exit 1; }
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
    find . \( -name ".env" -o -name ".env.*" -o -name "client_secret*.json" -o -name "credentials*.json" -o -name "*.pem" -o -name "*.key" -o -name "*.duckdb*" -o -name "*.db" -o -name "*.sqlite*" -o -name "*.parquet" -o -name "*.csv" -o -name "*.gz" -o -name "*.pkl" -o -name "*.xlsx" -o -path "./shared" -o -path "./data" -o -path "./logs" \
      -o -name ".*token*" -o -name "*token" -o -name "*token*.json" -o -name "*token*.txt" -o -name ".netrc" -o -name ".npmrc" -o -name ".pgpass" -o -name "secrets*.json" -o -name "service_account*.json" -o -name "*.keystore" -o -name "*.pickle" \) -print 2>/dev/null | grep -v -E "^\./\.env\.example$" | head -20; echo SCAN_DONE' 2>/dev/null)"
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

RUN="$CITY/scripts/mbp-run.sh"; SELFTEST="$CITY/scripts/mbp-run.selftest.sh"; FILTER="$CITY/scripts/hetzner-rsync-filter.wa.txt"
SHIM="$CITY/scripts/pytest-shim/pytest-shim.sh"; SHIM_ST="$CITY/scripts/pytest-shim.selftest.sh"
TASKLIB="$ASSETS/gate-review-task.lib.sh"; LIB_ST="$ASSETS/gate-test-wrapper-rules.selftest.sh"; APOS_ST="$ASSETS/gate-6aj348-recall-bar.selftest.sh"; RUNBOOK="$CITY/docs/runbooks/mbp-offload.md"
need "$RUN" "$SELFTEST" "$FILTER" "$SHIM" "$SHIM_ST" "$TASKLIB" "$LIB_ST" "$APOS_ST" "$RUNBOOK"
[[ -x "$RUN" ]] || fail "mbp-run.sh sem permissão de execução"
syntax "$RUN" "$SELFTEST" "$TASKLIB"; sh -n "$SHIM" || fail "pytest-shim.sh não parseia sob sh"
log "arquivos implantados presentes; sintaxe ok sob $("$BASH32" --version | head -n1 | sed 's/ (.*//')."

# o filtro: a ordem de segurança, conferida pelo código vivo que decide se o nó entra na cadeia
tmpc="$(tmpcity)"
chk="$(MBP_CITY="$tmpc" "$BASH32" "$RUN" --host linux --check 2>/dev/null | sed -n 's/^node_filter_ok=//p')"
[[ "$chk" == 1 ]] || fail "o mbp-run.sh vivo NÃO aceita o filtro $FILTER (node_filter_ok='${chk:-vazio}'): o nó não seria usado"
awk '/^\+ \/tests\/\*\*\*$/ { t = NR } /^- \*\.duckdb\*$/ { d = NR } END { exit !(t && d && d < t) }' "$FILTER" || fail "no filtro, *.duckdb não vem ANTES de + /tests/***"
awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next } { last = $0 } END { exit !(last == "- *") }' "$FILTER" || fail "no filtro, a última regra não é '- *': nome desconhecido sairia do mini"
log "filtro do rsync: ordem de segurança e '- *' final ✓ (aceito pelo mbp-run.sh vivo)"

run_suite "selftest do nó Linux (mbp-run.sh)" 120 env MBP_SELFTEST_ONLY=node timeout 900 "$BASH32" "$SELFTEST"
run_suite "selftest do atalho do pytest (bandeira do nó)" 150 timeout 600 "$BASH32" "$SHIM_ST"
run_suite "selftest do parágrafo do prompt do revisor" 20 timeout 300 "$BASH32" "$LIB_ST"
out="$(timeout 300 "$BASH32" "$APOS_ST" 2>&1)" || { echo "$out" | tail -10 >&2; fail "gate-6aj348-recall-bar.selftest.sh falhou (o texto do prompt ganhou um apóstrofo ou perdeu uma régua?)"; }
log "invariantes do prompt do revisor (apóstrofos / régua de recall) ✓"

log "bandeiras da cidade viva comandam o parágrafo real do prompt do revisor..."
# shellcheck disable=SC1090
( . "$TASKLIB" || exit 3
  live=$(gate_test_wrapper_rules "$CITY")
  if [[ ( -f "$CITY/.gc/mbp-offload.on" || -f "$CITY/.gc/hetzner-node.on" ) && ! -f "$CITY/.gc/gate-pytest.off" ]]; then
    [[ -n "$live" ]] || { echo "uma bandeira de offload está ligada e o parágrafo saiu vazio" >&2; exit 1; }
    echo "  bandeira ligada -> parágrafo presente ✓"
  else
    [[ -z "$live" ]] || { echo "nenhuma bandeira ligada e o parágrafo saiu mesmo assim" >&2; exit 1; }
    echo "  nenhuma bandeira ligada -> parágrafo ausente ✓ (prompt idêntico ao de antes)"
  fi ) || fail "o parágrafo do prompt não acompanha as bandeiras da cidade viva"

# o nó de verdade (SÓ leitura)
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$NODE_HOST" true >/dev/null 2>&1; then
  chk_out="$(MBP_CITY="$tmpc" "$BASH32" "$RUN" --host linux --check 2>&1)"; chk_rc=$?
  if [[ $chk_rc -eq 0 ]]; then
    for k in avail_mb pressure ncpu disk_mb; do
      v="$(printf '%s\n' "$chk_out" | sed -n "s/^$k=//p")"
      [[ "$v" =~ ^[0-9]+$ ]] || fail "preflight vivo do nó: '$k' veio '${v:-vazio}' (campo ilegível — a cadeia recusaria o nó)"
    done
    log "nó $NODE_HOST responde e o preflight lê RAM, pressão, núcleos e disco ✓"
  else
    warn "o nó responde ao ssh mas o preflight recusou (rc=$chk_rc): $(printf '%s\n' "$chk_out" | tail -n 2 | tr '\n' ' ') — a cadeia cairia no MBP"
  fi
fi
scan_node_base

log "PASS"
exit 0
