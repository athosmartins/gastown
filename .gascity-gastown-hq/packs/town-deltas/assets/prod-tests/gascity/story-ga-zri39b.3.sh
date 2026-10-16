#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zri39b.3.sh — prod test da fatia 3 de 4 da ga-zri39b (nó Linux de testes, Hetzner, teste de 1 semana aprovado pelo Athos em 13/10):
# relatório diário do nó (baterias por host, tempo, fallbacks, sombra, custo via hcloud), o order que o manda ao Mayor e a chave `mbp-offload.sh node on|off|status`.
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o relatório, o order e o wrapper existem e parseiam; o selftest do relatório (e do wrapper) e a seção `chave` do selftest do mbp-offload passam contra os arquivos vivos; o relatório roda de verdade na cidade viva, sem custo e só lendo o log; com hcloud e token no cofre, o relatório com custo roda e traz a linha `Custo:`.
# O QUE NÃO VERIFICA — e não diz que verifica: o CONTEÚDO do servidor. Esta fatia só LÊ logs e pergunta o custo à API; não muda o que o rsync manda ao nó nem o que já está lá. A varredura de segurança
#   da base e dos espelhos do nó (nome de segredo/dado, token, arquivo grande, CONTEÚDO com lista de telefones/CPFs) é da story-ga-zri39b.1.sh, e esta fatia NÃO mantém cópia dela (a cópia que
#   existia aqui só olhava nome, só a wa-base, sem token e sem conteúdo, e nem chegava a ser chamada). Este teste PASSAR não diz nada sobre o que o servidor guarda.
# POR QUE É SEGURO RODAR: os selftests usam stubs de ssh/rsync/python e uma cidade temporária; as leituras vivas são SÓ leitura. Nada é semeado, instalado nem apagado no servidor, e nenhuma
#   bandeira é ligada ou desligada.
# O QUE É AVISO E NÃO FALHA: a linha `Custo: indisponível (motivo)` quando o motivo é do MUNDO — hcloud falhou (API fora, rede, token vencido) ou "nenhum servidor com o rótulo" (o Mayor já apagou o
#   servidor ao fim do teste de 1 semana): o relatório diz "não consegui saber", e isso é o comportamento certo. Também aviso: tráfego "indisponível" no servidor, e a ausência de hcloud ou do token no cofre.
#   É FALHA o relatório que QUEBRA na rota da API (rc ≠ 0, ou saída sem nenhuma linha `Custo:`) e o que NÃO ENTENDE a resposta viva — "resposta da API ilegível / não é uma lista" ou "sem preço": com hcloud e
#   token, isso é o código lendo o formato errado (os selftests só provam o formato que o autor escreveu nos stubs), não indisponibilidade. Essa rota só se exercita de verdade com um servidor no ar.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-zri39b.3). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
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
# o custo: com hcloud e token o relatório chama a API (rota que o --no-cost acima não exercita). O relatório sempre imprime UMA linha `Custo:` e sai 0: o preço, ou "indisponível (motivo)" (nunca €0).
# vazio (sem linha `Custo:`), falhou (rc ≠ 0) ou "não entendi a resposta da API" → FALHA, o relatório quebrou; indisponível por motivo do mundo (API fora, servidor apagado) → aviso, o relatório disse isso;
# sem hcloud/token → aviso, não há o que rodar
if command -v hcloud >/dev/null 2>&1 && secret Hetzner --field notes >/dev/null 2>&1; then
  cost_out="$("$BASH32" "$REPORT" 2>&1)"; cost_rc=$?
  [[ $cost_rc -eq 0 ]] || fail "hetzner-daily-report.sh (com custo) saiu rc=$cost_rc na cidade viva: $cost_out"
  cost="$(printf '%s\n' "$cost_out" | grep '^Custo' | head -n 1)"
  case "$cost" in
    "") fail "o relatório com custo saiu 0 mas sem nenhuma linha 'Custo:': $cost_out" ;;
    "Custo: indisponível (resposta da API"*|"Custo: indisponível (sem preço"*) fail "o relatório não entende a resposta VIVA da API de custo (o formato não é o que o código lê): $cost" ;;
    "Custo: indisponível"*) warn "custo indisponível, e o relatório disse isso: $(printf '%s' "$cost" | cut -c1-140)" ;;
    *)
      printf '%s\n' "$cost_out" | grep -q '^Custo estimado na janela: €' || fail "linha de custo de servidor sem a linha 'Custo estimado na janela: €': $cost_out"
      case "$cost" in *"tráfego de saída: indisponível"*) warn "a API não deu o tráfego do servidor (o relatório diz indisponível): $(printf '%s' "$cost" | cut -c1-140)" ;; esac
      log "custo: $(printf '%s' "$cost" | cut -c1-110)" ;;
  esac
else warn "sem hcloud ou sem o token no cofre: o custo sairia como indisponível"; fi

log "PASS"
exit 0
