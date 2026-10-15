#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zri39b.1.sh — prod test da fatia 1 de 4 da ga-zri39b (nó Linux de testes, Hetzner, teste de 1 semana aprovado pelo Athos em 13/10):
# o nó Linux entra na cadeia de mbp-run.sh (nó → MBP → mini, mesmos códigos 96..99) com o filtro de segurança do rsync; o gate e o atalho dos workers abrem com a bandeira do nó.
#
# Contents
#   O que verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): os scripts e o filtro existem e parseiam sob o /bin/bash 3.2 do macOS; o filtro tem a ORDEM de segurança (segredo/dado antes de `+ /tests/***`, conferida pelo próprio mbp-run.sh: `--host linux --check` diz node_filter_ok=1) e dado/config sai por CAMINHO, nunca por extensão solta; a árvore REAL do WA, passada pelo filtro vivo e olhada por CONTEÚDO (hetzner-pii-scan.py), não manda nenhuma classe de dado conhecida nem deixa uma pasta de config com lista de telefones/CPFs; os selftests que provam isso passam contra os arquivos vivos (o do nó, o do atalho do pytest, o do parágrafo do prompt do revisor e o do invariante de apóstrofos); o parágrafo TEST WRAPPER acompanha as bandeiras da cidade viva; e, no servidor, o preflight lê RAM, pressão, núcleos e disco e a base e os espelhos do nó não têm NOME de segredo/dado nem LISTA de telefones/CPFs (a varredura de conteúdo roda lá, só devolve contagens).
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
# a varredura de segurança no servidor de verdade (SÓ leitura, nada é copiado nem apagado lá): na base (wa-base) e nos espelhos (mirror/wa-N, onde o rsync cai), (1) NOME de segredo/dado, (2) arquivo > 4 MB (dado
# de verdade não cabe no filtro de nome) e (3) CONTEÚDO — o hetzner-pii-scan.py do repositório roda no servidor (vai por base64 no argumento, não é gravado lá) e devolve só contagens. Achado é FALHA; nó que não responde é AVISO.
# Um achado no WA-BASE é à mão do Mayor (a base não é alvo do rsync); num espelho, o --delete-excluded da próxima rodada do nó limpa.
scan_node_base() {
  local leaks bad remote b64
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$NODE_HOST" true >/dev/null 2>&1; then warn "o nó $NODE_HOST não respondeu ao ssh — checks vivos do servidor pulados (a cadeia cai no MBP)"; return 0; fi
  b64="$(base64 < "$CITY/scripts/hetzner-pii-scan.py" | tr -d '\n')"; [[ -n "$b64" ]] || fail "não consegui ler o hetzner-pii-scan.py para varrer o conteúdo no servidor"
  remote="$(cat <<'REMOTE'
found=0
for d in "$HOME/gt-remote/wa-base" "$HOME"/gt-remote/mirror/wa-*; do
  [ -d "$d" ] || continue; found=1; cd "$d" || continue; echo "DIR $d"
  find . \( -name ".env" -o -name ".env.*" -o -name "client_secret*.json" -o -name "credentials*.json" -o -name "*.pem" -o -name "*.key" -o -name "*.duckdb*" -o -name "*.db" -o -name "*.sqlite*" -o -name "*.parquet" -o -name "*.csv" -o -name "*.gz" -o -name "*.pkl" -o -name "*.xlsx" -o -path "./shared" -o -path "./data" -o -path "./logs" \
    -o -name ".*token*" -o -name "*token" -o -name "*token*.json" -o -name "*token*.txt" -o -name ".netrc" -o -name ".npmrc" -o -name ".pgpass" -o -name "secrets*.json" -o -name "service_account*.json" -o -name "*.keystore" -o -name "*.pickle" \) -print 2>/dev/null | grep -v -E "^\./\.env\.example$" | head -200 | sed 's/^/NOME /'
  find . -type f -size +4096k -print 2>/dev/null | head -50 | sed 's/^/GRANDE /'
  find . -type f -size -4097k -print 2>/dev/null | sed 's#^\./##' | python3 -I -c 'import base64,sys; c=base64.b64decode(sys.argv[1]).decode(); sys.argv=["x"]+sys.argv[2:]; exec(c)' @PII@ . 2>&1 | head -200 | sed 's/^/CONTEUDO /'
done
[ "$found" = 1 ] || echo NOBASE
echo SCAN_DONE
REMOTE
)"
  leaks="$(printf '%s\n' "${remote//@PII@/$b64}" | ssh -o BatchMode=yes -o ConnectTimeout=8 "$NODE_HOST" bash -s 2>/dev/null)"
  if [[ "$leaks" == *NOBASE* ]]; then warn "o nó ainda não tem ~/gt-remote/wa-base nem espelho — a cadeia cai no MBP até lá"
  elif [[ "$leaks" != *SCAN_DONE* ]]; then warn "não consegui varrer a base do nó (ssh caiu no meio): a checagem de vazamento NÃO foi feita"
  else
    # awk, não grep -E '^(X|)$': o grep do macOS rejeita a alternativa vazia, o erro sumia no `|| true` e a lista voltava VAZIA mesmo com vazamento
    bad="$(printf '%s\n' "$leaks" | awk '$0 != "" && $0 != "SCAN_DONE" && $0 !~ /^DIR /')"
    [[ -z "$bad" ]] || fail "SEGURANÇA: segredo ou dado de cliente no nó $NODE_HOST (NOME = nome de segredo/dado · GRANDE = arquivo > 4 MB · CONTEUDO = telefones<TAB>CPFs<TAB>caminho, só contagens):
$bad
(wa-base: à mão do Mayor, a base não é alvo do rsync · mirror/wa-N: o --delete-excluded da próxima rodada do nó limpa · e investigue como chegou; apagar o arquivo não desfaz a exposição de uma credencial)"
    log "base e espelhos do nó sem nome de segredo/dado, sem arquivo grande e sem lista de telefones/CPFs (varredura de conteúdo no servidor) ✓"
  fi
}
# varredura de CLASSE na árvore REAL do WA (SÓ leitura): o que o filtro VIVO deixaria sair, olhado por conteúdo. É a medição que a 2ª revisão do gate fez à mão (nome neutro com dado dentro) e que um
# arquivo novo numa pasta de config reabre: pasta liberada por caminho que ganhe uma lista de telefones/CPFs, ou uma classe de dado conhecida que volte a sair, é FALHA.
sweep_wa_tree() {
  local wa=/Users/athos/gt/whatsapp_automation d lst held hit
  [[ -d "$wa/tests" ]] || { warn "árvore do WA ($wa) ausente — varredura de classe pulada"; return 0; }
  d="$(tmpcity)"; mkdir -p "$d/dst"; lst="$d/sent.lst"; held="$d/held.out"
  rsync -a -n --out-format='%n' --filter=". $FILTER" "$wa"/ "$d/dst"/ 2>/dev/null | grep -v '/$' > "$lst"
  [[ ${PIPESTATUS[0]} -eq 0 && -s "$lst" ]] || fail "não consegui listar o que o filtro vivo deixaria sair da árvore do WA (rsync -n)"
  hit="$(grep -E '^(docs/auto_response/ab_results/|docs/pix_verdicts/|analysis/.*\.json$|scripts/peter/mrv_bh/.*\.json$|scripts/campanhas_[^/]*estado\.json$|state\.json$|config\.json$)|pdpj_token\.txt|mrv_decisores|client_secret|(^|/)\.env' "$lst" | head -5)"
  [[ -z "$hit" ]] || fail "SEGURANÇA: o filtro vivo deixaria sair da árvore do WA uma classe de dado conhecida:
$hit"
  python3 -I "$CITY/scripts/hetzner-pii-scan.py" "$wa" --rules "$d/held.rules" < "$lst" > "$held"; rc=$?
  [[ $rc -eq 0 ]] || fail "hetzner-pii-scan.py não varreu a árvore do WA inteira (rc=$rc; 3 = algum arquivo da lista não pôde ser lido): varredura incompleta não é 'nada retido'"
  hit="$(awk -F'\t' '$3 !~ /^tests\// && $3 !~ /\.(py|sh|js|mjs|cjs|ts|css)$/' "$held" | head -5)"
  [[ -z "$hit" ]] || fail "SEGURANÇA: pasta de dado/config liberada por caminho tem LISTA de telefones/CPFs (telefones<TAB>CPFs<TAB>caminho):
$hit"
  log "árvore real do WA ($(wc -l < "$lst" | tr -d ' ') arquivos que sairiam): nenhuma classe de dado conhecida, nenhuma pasta de config com lista de telefones/CPFs; o node_guard retém $(wc -l < "$held" | tr -d ' ') ✓"
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
awk '/^\+ \*\.(json|md|html|ya?ml|sql|plist|ini|txt|xml)$/ { bad = 1 } END { exit bad }' "$FILTER" || fail "o filtro tem '+ *.<extensão de dado>' solta: dado/config sai por CAMINHO (3b), nunca por extensão — foi o que mandou ab_results/*.json ao nó"
log "filtro do rsync: ordem de segurança, '- *' final e dado/config só por caminho ✓ (aceito pelo mbp-run.sh vivo)"
sweep_wa_tree

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
