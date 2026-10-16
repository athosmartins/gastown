#!/usr/bin/env bash
# hetzner-nightly-tests.sh — a suíte INTEIRA do WA no nó Linux (Hetzner), toda madrugada, sem rede de saída e sem segredo, com relatório ao Mayor (ga-9p6pte).
#
# ## Contents
#   Por quê · Veredito · Como roda · O que NÃO faz · Ambiente
#
# POR QUÊ: em 04/10 um teste de branch antiga mandou um e-mail de verdade. Rodar a suíte inteira toda noite só é aceitável com a saída de rede PROVADA
#   cortada (canário do hetzner-iso-run.sh + helper de root hetzner-netns-run.sh) e ambiente limpo. Sem essa prova nada roda.
# VEREDITO (última linha do stdout `VEREDITO: <x>`; uma linha jsonl por noite em $CITY/.gc/logs/hetzner-nightly.jsonl; um e-mail ao Mayor, salvo PULADO)
#   COMPLETO  a suíte rodou DENTRO do isolamento provado e o resumo do pytest foi lido: total, falhas, novas falhas contra a última noite COMPLETA, duração.
#             Teste que falha é dado do relatório, não falha do job (exit 0).
#   INERTE    o isolamento não foi provado (helper de root não instalado, canário `inerte`/`nao-isolado`, wrapper ausente): NADA rodou. Exit 0, e-mail diz o que falta.
#   FALHOU    o que impede de dizer o que aconteceu: nó fora, sync/guard recusado, estouro de prazo (2 h), pytest abortado (rc>=2), resumo ilegível ou total
#             implausível, rodou sem a linha de prova do isolamento (o número NÃO é divulgado como resultado). Exit 1.
#   PULADO    por escolha, com evidência: bandeira do nó desligada (rc 99 do mbp-run) ou outra rodada em andamento. Sem e-mail, exit 0.
# COMO RODA: gc order (packs/town-deltas/orders/hetzner-nightly-tests.toml, 02:00 local = 05:00 UTC). `git archive origin/main` do WA (nada de WIP de agente, nada de untracked) para um scratch,
#   `HETZNER_ISOLATE=1 mbp-run.sh --host linux --repo wa -- tests/ -n 14 ...` (o filtro, o node_guard, o slot e a supervisão são os do gate, sem cópia), e o scratch é apagado.
# O QUE NÃO FAZ: não cai no MBP nem no mini (--host linux, sem cadeia); não decide se uma falha é regressão (só diz quais são novas); não instala o helper de root.
# AMBIENTE (selftest e rodada manual): MBP_CITY, HZN_RUN (mbp-run.sh), HZN_WA_REPO, HZN_MAIL_CMD (padrão `gc mail send mayor`), HZN_TIMEOUT_S (7200), HZN_MIN_TOTAL (1000),
#   HZN_NODE_HOST (hetzner-teste), HZN_SSH (ssh), HZN_NO_FETCH=1 (não buscar o origin), HZN_KEEP_DAYS (14).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY=${MBP_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}
RUN=${HZN_RUN:-$HERE/mbp-run.sh}
WA=${HZN_WA_REPO:-/Users/athos/gt/whatsapp_automation}
MAIL=${HZN_MAIL_CMD:-gc mail send mayor}
TIMEOUT_S=${HZN_TIMEOUT_S:-7200}
MIN_TOTAL=${HZN_MIN_TOTAL:-1000}
NODE=${HZN_NODE_HOST:-hetzner-teste}
SSH=${HZN_SSH:-ssh}
LOGDIR="$CITY/.gc/logs/hetzner-nightly"
JSONL="$CITY/.gc/logs/hetzner-nightly.jsonl"
LOCK="$CITY/.gc/hetzner-nightly.lock"
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
DAY=$(date +%Y-%m-%d)
T0=$(date +%s)
say() { printf '%s hetzner-nightly: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
SCR=""; OUT="$LOGDIR/$DAY.out"; REPORT="$LOGDIR/$DAY.md"
cleanup() { [ -z "$SCR" ] || find "$SCR" -mindepth 1 -delete 2>/dev/null; [ -z "$SCR" ] || rmdir "$SCR" 2>/dev/null; [ ! -f "$LOCK/pid" ] || [ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ] || { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; }; return 0; }
trap cleanup EXIT
mkdir -p "$LOGDIR" 2>/dev/null || { say "FALHOU — não consegui criar $LOGDIR"; exit 1; }

SHA="?"; ISO_LINE=""; EGRESS="?"; MAILRC=0
finish() { # veredito motivo [exit] — grava o relatório, o jsonl, manda o e-mail (salvo PULADO) e sai
  local v=$1 why=$2 rcx=${3:-0} subj
  [ -s "$REPORT" ] || printf '# Hetzner nightly %s — %s\n\n%s\n' "$DAY" "$v" "$why" > "$REPORT"
  subj="[hetzner-nightly] $DAY $v: $why"
  if [ "$v" != PULADO ]; then
    # vazio/falhou (o comando de e-mail não existe ou recusou) → o relatório fica no disco, o jsonl diz mail=falhou e o exit vira 1: ninguém acha que o Mayor foi avisado
    # shellcheck disable=SC2086
    $MAIL -s "$subj" -m "$(cat "$REPORT")" >/dev/null 2>&1 || { MAILRC=1; say "WARN: e-mail ao Mayor falhou (relatório em $REPORT)"; [ "$rcx" -ne 0 ] || rcx=1; }
  fi
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$v" --arg why "$why" --arg sha "$SHA" --arg iso "$ISO_LINE" --arg egress "$EGRESS" \
     --argjson wall "$(( $(date +%s) - T0 ))" --argjson mailrc "$MAILRC" '{ts:$ts,verdict:$v,reason:$why,sha:$sha,isolation:$iso,egress_attempts:$egress,wall_s:$wall,mail_failed:$mailrc}' >> "$JSONL" 2>/dev/null \
     || say "WARN: não gravei $JSONL"
  find "$LOGDIR" -type f -mtime +"${HZN_KEEP_DAYS:-14}" -delete 2>/dev/null
  say "$subj"; say "VEREDITO: $v"; exit "$rcx"
}

# lock: vazio (sem pasta) → toma; pid vivo → PULADO; pid morto ou ilegível → dono morreu no meio, toma de novo (uma noite perdida muda é pior que um lock velho)
if ! mkdir "$LOCK" 2>/dev/null; then
  op=$(cat "$LOCK/pid" 2>/dev/null)
  case "$op" in ''|*[!0-9]*) op="" ;; esac
  if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then say "PULADO — outra rodada em andamento (pid $op)"; say "VEREDITO: PULADO"; exit 0; fi
  say "WARN: lock sem dono vivo (pid '${op:-ilegível}'): tomando"
fi
echo $$ > "$LOCK/pid" 2>/dev/null || finish FALHOU "não consegui gravar o dono do lock em $LOCK" 1
: > "$REPORT"   # o relatório de hoje começa vazio: um relatório de rodada anterior do mesmo dia nunca vira o e-mail desta

# o que vai ao nó: origin/main do WA, só o versionado. falhou o fetch → segue com o origin/main que o clone já tem (o sha vai no relatório); sem origin/main legível → FALHOU
[ "${HZN_NO_FETCH:-0}" = 1 ] || timeout 120 git -C "$WA" fetch -q origin main 2>/dev/null || say "WARN: git fetch origin main falhou; uso o origin/main que o clone já tem"
# vazio/falhou (rev-parse não devolve sha) → FALHOU, nada é enviado
SHA=$(git -C "$WA" rev-parse --verify -q origin/main 2>/dev/null | cut -c1-9); [ -n "$SHA" ] || finish FALHOU "origin/main do WA ilegível em $WA" 1
mkdir -p "$CITY/.gc/run" 2>/dev/null; SCR=$(mktemp -d "$CITY/.gc/run/hetzner-nightly.XXXXXX") || finish FALHOU "não criei o scratch em $CITY/.gc/run" 1
mkdir "$SCR/whatsapp_automation" && git -C "$WA" archive origin/main | tar -x -C "$SCR/whatsapp_automation" || finish FALHOU "git archive origin/main falhou" 1

# o wrapper do canário e o plugin de ids vão ao nó a cada noite (o helper de root é do root; estes dois são nossos e ficam iguais aos do repo). Falhou o ssh/cat → o nó não foi alcançado
for f in hetzner-iso-run.sh:gt-iso-run gtn_stable_ids.py:gtn_stable_ids.py; do
  if ! $SSH -o BatchMode=yes -o ConnectTimeout=20 "$NODE" "mkdir -p ~/gt-remote/bin && cat > ~/gt-remote/bin/.${f#*:}.new && chmod 755 ~/gt-remote/bin/.${f#*:}.new && mv -f ~/gt-remote/bin/.${f#*:}.new ~/gt-remote/bin/${f#*:}" < "$HERE/${f%%:*}" 2>/dev/null; then
    finish FALHOU "não consegui instalar ${f#*:} em $NODE (nó inalcançável?)" 1
  fi
done

say "rodando a suíte do WA @$SHA em $NODE (prazo ${TIMEOUT_S}s)"
HETZNER_ISOLATE=1 MBP_RUN_TIMEOUT_S="$TIMEOUT_S" "$RUN" --host linux --repo wa --dir "$SCR/whatsapp_automation" -- tests/ -n 14 -p gtn_stable_ids --timeout=300 -q -rfE --tb=line --continue-on-collection-errors > "$OUT" 2>&1
RC=$?
WALL=$(( $(date +%s) - T0 ))
# vazio (nenhuma linha GTN-ISO) → a prova NÃO existe; falhou/ilegível → mesma coisa. Só uma linha que COMEÇA com "isolado" vale como prova.
ISO_LINE=$(sed -n 's/^GTN-ISO: //p' "$OUT" 2>/dev/null | head -n 1)
# vazio/ilegível (sem a linha GTN-EGRESS, ou `?`) → "?" no relatório: não afirmo zero tentativas sem ter lido o contador
EGRESS=$(sed -n 's/^GTN-EGRESS: attempts=//p' "$OUT" 2>/dev/null | tail -n 1); [ -n "$EGRESS" ] || EGRESS="?"
# vazio/ilegível (saída vazia ou sem leitura) → o motivo do FALHOU sai sem a última linha da saída; o veredito não muda
TAIL3=$(grep . "$OUT" 2>/dev/null | tail -n 3 | cut -c1-200)

case "$RC" in
  99) finish PULADO "nó Linux desligado (falta $CITY/.gc/hetzner-node.on)" 0 ;;
  96|97|98)
    case "$ISO_LINE" in
      inerte*|nao-isolado*) { echo "# Hetzner nightly $DAY — INERTE (nada rodou)"; echo; echo "Isolamento de rede NÃO provado: \`GTN-ISO: $ISO_LINE\`"; echo "Sem essa prova a suíte não roda (04/10: um teste mandou e-mail de verdade)."; echo "Instalar o helper de root: docs/runbooks/hetzner-nightly-tests.md, seção Instalação."; echo; echo "origin/main @$SHA"; } > "$REPORT"
        finish INERTE "isolamento não provado ($ISO_LINE)" 0 ;;
      *) finish FALHOU "o mbp-run não rodou a suíte (rc=$RC): $(printf '%s' "$TAIL3" | tail -n 1)" 1 ;;
    esac ;;
  124) finish FALHOU "estourou o prazo de ${TIMEOUT_S}s (meta: menos de 2 h)" 1 ;;
  0|1) ;;
  *) finish FALHOU "o pytest abortou (rc=$RC): $(printf '%s' "$TAIL3" | tail -n 1)" 1 ;;
esac

# sem prova de isolamento o resultado NÃO é divulgado como rodada (pode ter rodado sem o wrapper: o aviso é alto)
case "$ISO_LINE" in isolado*) ;; *) finish FALHOU "ATENÇÃO: a suíte terminou SEM a linha de prova do isolamento (GTN-ISO: '${ISO_LINE:-vazio}'); resultado descartado, confira o hook HETZNER_ISOLATE do mbp-run.sh" 1 ;; esac

# vazio (a categoria não aparece na linha) → 0, o pytest omite o que é zero; falhou/ilegível (nenhuma linha de resumo "... in N s") → FALHOU, nenhum número é inventado
SUM=$(grep -E '^(=+ )?([0-9]+ [a-z]+.*|no tests ran) in [0-9.]+s' "$OUT" 2>/dev/null | tail -n 1)
[ -n "$SUM" ] || finish FALHOU "sem linha de resumo do pytest na saída (rc=$RC): $(printf '%s' "$TAIL3" | tail -n 1)" 1
cnt() { printf '%s' "$SUM" | sed -n -E "s/.*[^0-9]([0-9]+) $1.*/\1/p;s/^([0-9]+) $1.*/\1/p" | head -n 1; }
PASSED=$(cnt passed); FAILED=$(cnt failed); ERRORS=$(cnt 'errors?'); SKIPPED=$(cnt skipped); XF=$(cnt xfailed); XP=$(cnt xpassed)
PASSED=${PASSED:-0}; FAILED=${FAILED:-0}; ERRORS=${ERRORS:-0}; SKIPPED=${SKIPPED:-0}; XF=${XF:-0}; XP=${XP:-0}
TOTAL=$(( PASSED + FAILED + ERRORS + SKIPPED + XF + XP ))
# vazio/ilegível (a linha de resumo não traz "in N.NNs") → PYSECS vazio: o relatório mostra "?" (não 0h0min) e a meta de 2 h é medida pelo relógio total
PYSECS=$(printf '%s' "$SUM" | sed -n -E 's/.* in ([0-9]+)\.[0-9]+s.*/\1/p')
[ "$TOTAL" -ge "$MIN_TOTAL" ] || finish FALHOU "total implausível ($TOTAL testes < $MIN_TOTAL; resumo: $SUM)" 1

# ids reprovados desta noite (FAILED e ERROR do resumo -rfE), sem a mensagem, ordenados.
# vazio (nenhuma linha FAILED/ERROR) → só vale como "zero falhas" se o resumo também diz zero; o resumo dizendo N>0 com a lista vazia → LISTOK=0 (comparação indisponível, linha de base intacta)
CUR="$LOGDIR/$DAY.failed"
sed -n -E 's/^(FAILED|ERROR) (.*)$/\2/p' "$OUT" | sed -E 's/ - .*$//' | sort -u > "$CUR"
LISTOK=1; [ -s "$CUR" ] || [ $(( FAILED + ERRORS )) -eq 0 ] || LISTOK=0
PREV="$LOGDIR/last-complete.failed"; PMETA="$LOGDIR/last-complete.meta"
# vazio (o arquivo existe e está vazio) → a última noite COMPLETA não teve falha, toda falha de hoje é nova; ausente → 1ª rodada, nada a comparar;
# falhou/ilegível (existe e não abre/ordena) → "comparação indisponível", NUNCA "0 novas"
CMP="primeira rodada completa: não há noite anterior para comparar; as $(wc -l < "$CUR" | tr -d ' ') falhas de hoje viram a linha de base"
NEW="$LOGDIR/$DAY.new"; : > "$NEW"; NEWTXT="sem comparação"
if [ "$LISTOK" = 0 ]; then CMP="comparação INDISPONÍVEL: o resumo diz $((FAILED + ERRORS)) falhas/erros e nenhum id FAILED/ERROR foi lido de $OUT (a linha de base não foi tocada)"
elif [ -e "$PREV" ]; then
  if [ -r "$PREV" ] && sort -u "$PREV" > "$SCR/prev.sorted" 2>/dev/null; then
    comm -13 "$SCR/prev.sorted" "$CUR" > "$NEW"; FIXED=$(comm -23 "$SCR/prev.sorted" "$CUR" | wc -l | tr -d ' ')
    NEWTXT="$(wc -l < "$NEW" | tr -d ' ') novas"
    CMP="contra a última noite completa ($(cat "$PMETA" 2>/dev/null || echo 'data ilegível')): $(wc -l < "$NEW" | tr -d ' ') falhas NOVAS, $FIXED corrigidas"
  else CMP="comparação INDISPONÍVEL: $PREV existe e não pôde ser lido (as falhas de hoje estão em $CUR)"; fi
else NEWTXT="primeira rodada"
fi
DUR="?"; [ -z "$PYSECS" ] || DUR="$(( PYSECS / 3600 ))h$(( (PYSECS % 3600) / 60 ))min"
GOAL="ATINGIDA"; [ "${PYSECS:-$WALL}" -lt 7200 ] || GOAL="ESTOURADA"
EGLINE="$EGRESS tentativa(s) de saída barradas pelo nft"
case "$EGRESS" in 0) EGLINE="0 tentativas de saída (contador do nft lido)" ;; '?') EGLINE="contador do nft ILEGÍVEL — não afirmo zero tentativas" ;; esac
{
  echo "# Hetzner nightly $DAY — COMPLETO"; echo
  echo "- origin/main @$SHA, nó $NODE, \`pytest tests/ -n 14\`"
  echo "- total: $TOTAL ($PASSED passaram, $FAILED falharam, $ERRORS erros, $SKIPPED pulados, $XF xfail, $XP xpass)"
  echo "- duração: pytest ${DUR} (${PYSECS:-?} s), relógio total ${WALL} s; meta de 2 h: $GOAL"
  echo "- $CMP"
  echo "- isolamento: \`GTN-ISO: $ISO_LINE\`; $EGLINE"
  if [ -s "$NEW" ]; then echo; echo "Falhas novas (até 30 de $(wc -l < "$NEW" | tr -d ' ')):"; head -n 30 "$NEW" | sed 's/^/  - /'; fi
  echo; echo "Saída completa: $OUT; ids reprovados: $CUR"
} > "$REPORT"
# a linha de base só avança numa noite COMPLETA (gravação atômica; nunca com a de uma noite inerte ou que falhou)
if [ "$LISTOK" = 1 ]; then cp "$CUR" "$PREV.new" && mv -f "$PREV.new" "$PREV" && echo "$DAY @$SHA" > "$PMETA" || say "WARN: não avancei a linha de base ($PREV)"
else say "WARN: lista de falhas ilegível; a linha de base ($PREV) ficou como estava"; fi
finish COMPLETO "$TOTAL testes, $FAILED falhas, $ERRORS erros ($NEWTXT), pytest ${DUR}" 0
