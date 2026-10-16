#!/usr/bin/env bash
# prod-tests/gascity/story-ga-zri39b.2.sh — prod test da fatia 2 de 4 da ga-zri39b (nó Linux de testes, Hetzner, teste de 1 semana aprovado pelo Athos em 13/10):
# lista mac-only, sombra de 24 h e paralelismo (xdist) do nó Linux.
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): a lista mac-only existe, é lida pelo mbp-run.sh vivo e tem entradas que apontam para arquivos reais do WA; um alvo da lista não vai ao nó (rc 98, motivo `mac-only` no log, sem rede); o selftest do nó (cadeia, segurança, mac-only, xdist e sombra) passa contra os arquivos vivos.
# O QUE NÃO VERIFICA — e não diz que verifica: o CONTEÚDO do servidor. Esta fatia só decide para onde uma bateria vai (lista mac-only), compara com o MBP (sombra) e liga o xdist; não muda o que o rsync manda
#   ao nó nem o que já está lá. A varredura de segurança da base e dos espelhos do nó (nome de segredo/dado, token, arquivo grande, CONTEÚDO com lista de telefones/CPFs) é da story-ga-zri39b.1.sh, e esta fatia
#   NÃO mantém cópia dela: a cópia que existia aqui ficou para trás (só olhava nome, só a wa-base, sem token e sem conteúdo; o revisor do gate a rodou contra um `.pdpj_token.txt` plantado e ela devolveu "limpo").
#   Este teste PASSAR não diz nada sobre o que o servidor guarda.
# POR QUE É SEGURO RODAR: os selftests usam stubs de ssh/rsync/python e uma cidade temporária; as leituras vivas são SÓ leitura. Nada é semeado, instalado nem apagado no servidor, e nenhuma
#   bandeira é ligada ou desligada.
# O QUE É AVISO E NÃO FALHA: entrada da lista mac-only que aponta para um arquivo que não existe mais na árvore do WA (é lixo na lista, não segurança).
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-zri39b.2). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
TMPS=()
cleanup() { local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do [[ -n "$d" && -d "$d" ]] && { find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null; }; done; }
trap cleanup EXIT
log()  { echo "[prod-test:gascity ga-zri39b.2] $*"; }
warn() { echo "[prod-test:gascity ga-zri39b.2] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-zri39b.2] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
# Sem subshell: `d="$(tmpcity)"` perdia o TMPS+= (o append morria no subshell) e o cleanup() nunca apagava a cidade temporária. O caminho vai em $TMPCITY.
# vazio/falhou → fail (o mkdir -p NÃO roda com caminho vazio: viraria /.gc/logs na raiz)
tmpcity() { TMPCITY="$(mktemp -d "${TMPDIR:-/tmp}/zri39b-prod.XXXXXX")" && [[ -n "$TMPCITY" && -d "$TMPCITY" ]] || fail "não consegui criar a cidade temporária"; TMPS+=("$TMPCITY"); mkdir -p "$TMPCITY/.gc/logs"; }
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
RUN="$CITY/scripts/mbp-run.sh"; SELFTEST="$CITY/scripts/mbp-run.selftest.sh"; MACONLY="$CITY/scripts/hetzner-mac-only.txt"; WA_TREE="${WA_TREE:-/Users/athos/gt/whatsapp_automation}"
need "$RUN" "$SELFTEST" "$MACONLY"
syntax "$RUN" "$SELFTEST"
log "arquivos implantados presentes; sintaxe ok."

# a lista mac-only: lida pelo mbp-run.sh vivo e sem entrada que aponte para um arquivo que não existe mais na árvore do WA (entrada velha é lixo, não segurança: AVISO)
tmpcity; tmpc="$TMPCITY"; touch "$tmpc/.gc/hetzner-node.on"
chk="$(MBP_CITY="$tmpc" "$BASH32" "$RUN" --host linux --check 2>/dev/null | sed -n 's/^node_mac_only_rc=//p')"
[[ "$chk" == 1 ]] || fail "o mbp-run.sh vivo não leu a lista mac-only (node_mac_only_rc='${chk:-vazio}'; 1 = lida, nenhum alvo)"
n=0; gone=0
while IFS= read -r f; do
  [[ -z "$f" || "$f" == \#* ]] && continue
  n=$((n + 1)); [[ -f "$WA_TREE/$f" ]] || { gone=$((gone + 1)); warn "mac-only lista $f, que não existe em $WA_TREE"; }
done < "$MACONLY"
[[ $n -ge 1 ]] || fail "a lista mac-only está vazia ($MACONLY)"
log "lista mac-only lida pelo código vivo: $n entradas ($gone sem arquivo correspondente)"

# roteamento de verdade, sem rede: um arquivo da lista NÃO vai ao nó (sai antes de qualquer ssh) e o motivo vai ao log
first="$(grep -v -E '^(#|[[:space:]]*$)' "$MACONLY" | head -n 1)"
mkdir -p "$tmpc/wt/tests"
MBP_CITY="$tmpc" "$BASH32" "$RUN" --host linux --repo wa --dir "$tmpc/wt" -- "$first" >/dev/null 2>&1; rc=$?
[[ $rc -eq 98 ]] || fail "com --host linux, '$first' (da lista mac-only) devolveu rc=$rc (esperado 98: o nó não é usado para ele)"
grep -q '"reason":"mac-only"' "$tmpc/.gc/logs/mbp-run.jsonl" 2>/dev/null || fail "o motivo mac-only não foi para o log"
log "alvo da lista mac-only fica fora do nó (rc 98, motivo no log) ✓"

# 2700 s: o selftest passa de 300 casos e cada um sobe o mbp-run.sh inteiro; medido em 15/10 com o mini a load 50–65 foram 24 min, e o story-delivery roda o prod test a ni 15 (mais lento ainda). 900 s matava um selftest verde.
run_suite "selftest do nó Linux (mbp-run.sh): cadeia, segurança, mac-only, xdist e sombra" 200 env MBP_SELFTEST_ONLY=node timeout 2700 "$BASH32" "$SELFTEST"

log "PASS"
exit 0
