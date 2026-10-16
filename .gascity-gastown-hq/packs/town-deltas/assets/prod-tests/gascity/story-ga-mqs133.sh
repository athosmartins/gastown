#!/usr/bin/env bash
# prod-tests/gascity/story-ga-mqs133.sh — prod test da ga-mqs133 (rodar as rodadas dos raspadores de imóveis no servidor Hetzner, depois de MEDIR se os sites respondem ao IP alemão).
#
# Contents
#   O que verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): hetzner-scrape-round.sh, a lista de elegíveis e o selftest existem e parseiam sob o /bin/bash 3.2 do macOS; a lista de elegíveis
#   (1) só nomeia raspadores que existem na árvore implantada de property_scrapers, (2) mantém BLOQUEADOS os que a medição de 16/10 mostrou que o Cloudflare barra do IP alemão (zap_vivareal, chavesnamao,
#   netimoveis, larimoveis, wimoveis, leilão Caixa/Núcleo, ciadoimovel, imobiliariamodelobh) e o que usa credencial (blow) — se alguém liberar um deles sem re-medir, é FALHA; o selftest hermético
#   (fronteira de dados do rsync, elegibilidade, staging fora da produção, códigos 96..99, classificação do probe) passa contra os arquivos vivos; e, com o nó vivo, `check` diz que o ambiente
#   está pronto e UMA rodada de verdade (primeimoveisdeluxo --limit 3) volta em staging com arquivos, sem escrever uma linha em ~/.property-scrapers/shared.
# POR QUE É SEGURO RODAR: o selftest usa ssh/rsync-de-mentira no nó e uma cidade temporária. A rodada viva é 3 anúncios públicos de um site, vai para um staging temporário (apagado ao fim) e a
#   produção é conferida (nada do raspador mais novo que um marco) depois. Nada é instalado nem apagado no servidor além da pasta da própria rodada; nenhuma bandeira é ligada ou desligada.
# O QUE É AVISO E NÃO FALHA: o servidor é de um teste e o Mayor o apaga ao fim. Bandeira desligada (rc 99), ssh que não responde ou ambiente não preparado (rc 98) viram AVISO — o código não
#   depende de o servidor existir (quem chama roda local). Se o nó RESPONDE e a rodada devolve erro do raspador ou nenhum arquivo, ou escreve na produção, é FALHA.
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-mqs133). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BASH32=/bin/bash
PS_CODE="${HETZNER_SCRAPE_CODE:-/Users/athos/.property-scrapers/runtime/main}"
PS_SHARED="${HETZNER_SCRAPE_SHARED:-/Users/athos/.property-scrapers/shared}"
TMPS=()
cleanup() { local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do [[ -n "$d" && -d "$d" ]] && { find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null; }; done; }
trap cleanup EXIT
log()  { echo "[prod-test:gascity ga-mqs133] $*"; }
warn() { echo "[prod-test:gascity ga-mqs133] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-mqs133] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"
# tmpdir: deixa a pasta em $TMPD e a registra para o cleanup. NÃO chamar dentro de $(...): o subshell perderia o TMPS+= e a pasta nunca seria apagada. mktemp que falha = FAIL (nunca um caminho vazio)
tmpdir() { TMPD="$(mktemp -d "${TMPDIR:-/tmp}/mqs133-prod.XXXXXX")" && [[ -n "$TMPD" ]] || fail "mktemp -d falhou: sem pasta temporária"; TMPS+=("$TMPD"); }
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
# a produção (shared/ tem GB: nada de somar o conteúdo) não pode ganhar NADA do raspador testado durante a rodada viva: confere, por data de modificação contra um marco criado antes, só o que é dele
# (data/<raspador>/ e seen/caches de config/). Rodada local do mesmo raspador no mesmo instante = o marco não prova nada, então a conferência é pulada com aviso.
touched_prod() { # touched_prod <marco> <raspador> : lista (até 3) arquivos da produção deste raspador mais novos que o marco
  find "$PS_SHARED/data/$2" "$PS_SHARED/config" -type f -newer "$1" \( -path "*/data/$2/*" -o -name "*$2*" \) 2>/dev/null | head -n 3
}

RUN="$CITY/scripts/hetzner-scrape-round.sh"; SELFTEST="$CITY/scripts/hetzner-scrape-round.selftest.sh"; ELIG="$CITY/scripts/hetzner-scrape-eligible.txt"
PII="$CITY/scripts/hetzner-pii-scan.py"; RUNBOOK="$CITY/docs/runbooks/hetzner-scrape-round.md"
need "$RUN" "$SELFTEST" "$ELIG" "$PII" "$RUNBOOK"
[[ -x "$RUN" ]] || fail "hetzner-scrape-round.sh sem permissão de execução"
syntax "$RUN" "$SELFTEST"
log "arquivos implantados presentes; sintaxe ok sob $("$BASH32" --version | head -n1 | sed 's/ (.*//')."

# a lista de elegíveis: nomes reais, bloqueios medidos mantidos, nada com credencial
if [[ -d "$PS_CODE/scrapers" ]]; then
  bad=""
  while read -r name; do
    [[ -n "$name" ]] || continue
    [[ -d "$PS_CODE/scrapers/$name" ]] || bad="$bad $name"
  done < <(awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 == "") next; sub(/^!/, ""); sub(/:.*/, ""); print }' "$ELIG" | sort -u)
  [[ -z "$bad" ]] || fail "a lista de elegíveis nomeia raspador que não existe em $PS_CODE/scrapers:$bad (erro de digitação? o nome é o da PASTA, não o id do runner.py)"
  log "lista de elegíveis: todos os nomes existem em $PS_CODE/scrapers ✓"
else
  warn "árvore implantada de property_scrapers ($PS_CODE) ausente — conferência dos nomes pulada"
fi
for blocked in zap_vivareal chavesnamao netimoveis larimoveis wimoveis leilao_caixa leilao_nucleo ciadoimovel imobiliariamodelobh blow; do
  v="$("$BASH32" "$RUN" eligible "$blocked" 2>/dev/null)" && fail "'$blocked' voltou a ser PERMITIDO no nó ($v): a medição de 16/10 mostrou 403 do Cloudflare (ou credencial) — re-meça com \`hetzner-scrape-round.sh probe\` e rode uma rodada real antes de liberar"
  [[ "$v" == BLOCK* ]] || fail "'$blocked' deveria estar BLOQUEADO de propósito na lista (veio '$v'): bloqueio medido tem de ser explícito (!nome), não só 'ausente'"
done
log "bloqueios medidos mantidos explícitos (zap_vivareal, chavesnamao, netimoveis, larimoveis, wimoveis, leilões, ciadoimovel, imobiliariamodelobh, blow) ✓"
n_allowed="$(awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && substr($0, 1, 1) != "!") n++ } END { print n + 0 }' "$ELIG")"
[[ "$n_allowed" -ge 1 ]] || fail "a lista de elegíveis não permite nenhum raspador: o servidor ficaria sem o que fazer (ga-mqs133 existe para tirar rodada do mini)"
log "lista de elegíveis: $n_allowed permitidos ✓"

run_suite "selftest da rodada de raspadores no nó" 40 timeout 600 "$BASH32" "$SELFTEST"

# com o nó vivo: ambiente pronto e UMA rodada de verdade, em staging, sem escrever na produção
rc=0; chk="$("$BASH32" "$RUN" check 2>&1)" || rc=$?
case "$rc" in
  0)
    tmpdir; stage="$TMPD"; mark="$stage/.marco"; : > "$mark"
    out="$(HETZNER_SCRAPE_POLL_S=5 timeout 900 "$BASH32" "$RUN" run primeimoveisdeluxo --limit 3 --timeout 600 --stage "$stage" 2>&1)"; rrc=$?
    case "$rrc" in
      0)
        files="$(printf '%s\n' "$out" | sed -n 's/^files=//p' | tail -n 1)"
        [[ "${files:-0}" -ge 1 ]] || fail "a rodada viva terminou rc 0 mas devolveu ${files:-0} arquivos (esperado >= 1 de primeimoveisdeluxo --limit 3):
$out"
        d="$(printf '%s\n' "$out" | sed -n 's/^stage=//p' | tail -n 1)"
        [[ -n "$d" && -f "$d/scraper.log" ]] || fail "a rodada viva não devolveu o scraper.log em staging:
$out"
        if [[ ! -d "$PS_SHARED/config" ]]; then
          warn "$PS_SHARED/config ilegível — a conferência de que a produção não foi tocada foi pulada (sem como verificar)"
        elif pgrep -f 'scrapers/primeimoveisdeluxo/scraper.py' >/dev/null 2>&1; then
          warn "há uma rodada LOCAL de primeimoveisdeluxo em andamento — a conferência de que a produção não foi tocada foi pulada (o marco não distingue os dois)"
        else
          hit="$(touched_prod "$mark" primeimoveisdeluxo)"
          [[ -z "$hit" ]] || fail "SEGURANÇA: a rodada viva escreveu na produção ($PS_SHARED): a fatia 1 só grava em staging:
$hit"
        fi
        log "rodada viva (primeimoveisdeluxo --limit 3): $files arquivos em staging; produção conferida (veja os avisos acima se a conferência foi pulada) ✓";;
      96|97|98|99) warn "o nó recusou a rodada viva (rc $rrc) — a cadeia cai no mini: $(printf '%s\n' "$out" | tail -n 1)";;
      *) fail "a rodada viva no nó terminou com rc $rrc (esperado 0):
$(printf '%s\n' "$out" | tail -n 15)";;
    esac;;
  97|98|99) warn "o nó não está disponível/pronto (rc $rc: $(printf '%s\n' "$chk" | tail -n 1)) — checks vivos do servidor pulados (o mini roda a rodada)";;
  *) fail "hetzner-scrape-round.sh check saiu com rc inesperado $rc:
$chk";;
esac

log "PASS"
exit 0
