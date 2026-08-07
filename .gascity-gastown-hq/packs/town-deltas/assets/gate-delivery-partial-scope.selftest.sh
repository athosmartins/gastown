#!/usr/bin/env bash
# gate-delivery-partial-scope.selftest.sh (ga-k2wjn, tightened by ga-zhfk8)
#
# Proves the ga-k2wjn fix: a gate PASS on a bug/task bead whose body enumerates
# multiple approved deliverables (>=3 numbered or lettered list items,
# anchored at line start) is held as delivery:partial + escalated to Mayor
# instead of auto-closed. "The gate approved the diff" and "the bead's full
# scope is done" are different claims — three real incidents (wa-uhbqb,
# wa-a7e98, wa-k0m1q) conflated them and silently dropped the remaining scope.
#
# ga-zhfk8 (measured 2026-08-04): v1 also held wa-zlgye — a LEGITIMATE merge —
# because it fired on the bare word "fatia"/"fatias"/"itens aprovados"
# ANYWHERE in prose, no list structure required at all. v2 drops that
# standalone-token trigger, requires a genuine run (not just >=3 matching
# lines anywhere in the text), and prints the detected lines so the hold
# message can CITE them instead of asserting without showing.
#
# ga-zhfk8 fix attempt 2 (gate-rejected attempt 1): a STRICT no-gap
# consecutive-line run false-negatived on realistic multi-line (wrapped) list
# items — see the WRAPPED_ITEMS fixture below. Fix attempt 2 tolerates
# INDENTED non-matching lines (wrapped continuations) inside a run without
# reopening the original bug: a BLANK line or FLUSH-LEFT non-matching line
# (unrelated prose, not a continuation) still ends the run, same as before.
#
# WHAT it guards:
#   - gate_delivery_looks_partial() (quality-gate-guard.sh): the pure heuristic,
#     re-run against synthetic fixtures AND 4 real historical bead bodies
#     (embedded verbatim) — 3 true positives (ga-k2wjn's falsifiable "should
#     have been held" AC) plus wa-zlgye, the measured false positive that must
#     NOT hold (ga-zhfk8's falsifiable AC). Checks BOTH numbered ("1. ") and
#     lettered ("a. ") list markers, BOTH description+notes (wa-k0m1q's own
#     list lives entirely in .notes — its .description is empty; a
#     description-only check would have missed it), that non-consecutive hits
#     do NOT count, and that a qualifying hit prints its evidence to stdout.
#   - quality-gate-dispatcher.sh: the bug/task PASS branch forks on IS_PARTIAL
#     before the close call; a scope_covered:all label bypasses the heuristic;
#     the post-merge re-pick verification does not false-flag a held bead as a
#     respawn vector; the hold comment/mail quote the detected evidence.
#   - story-delivery.sh: the Step 1b task reconciler's task_reconciler_verdict
#     gains a partial-delivery branch so a bead the primary dispatcher already
#     held for review is not silently closed a sweep later by this backstop
#     (and, for the crash-window case where the primary never ran, the
#     backstop applies the same hold+escalate treatment itself, also quoting
#     evidence).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
DELIVERY="$SELF_DIR/story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
rc0() { if "$@" >/dev/null 2>&1; then ok "rc0: $*"; else bad "expected rc0: $*"; fi; }
rc1() { if "$@" >/dev/null 2>&1; then bad "expected non-zero: $*"; else ok "rc!=0: $*"; fi; }
# out_has <needle> -- <cmd...> — asserts <cmd>'s STDOUT contains <needle> (ga-zhfk8 fix 3).
out_has() {
  local needle="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local got
  # ga-zhfk8: quality-gate-guard.sh sets `set -euo pipefail` at its own top,
  # which leaks into this shell via `source` even in lib-only mode — a bare
  # assignment from a command that legitimately returns 1 (no match) would
  # kill the whole selftest under the inherited errexit. `|| true` is the
  # same idiom already used throughout quality-gate-guard.sh itself for this
  # exact reason (e.g. digit_hits=$(... grep -Ec ... || true)).
  got=$("$@" 2>/dev/null) || true
  case "$got" in
    *"$needle"*) ok "stdout has '$needle': $*" ;;
    *) bad "stdout missing '$needle': $* (got: $got)" ;;
  esac
}
# err_has <needle> -- <cmd...> — asserts <cmd>'s STDERR contains <needle>
# (ga-cjrxh AC3). The release path must SAY WHY it released: "avaliei e nao
# achei escopo multiplo" and "nao consegui avaliar" are different facts and
# must not share one silent rc=1 (root-class error-vs-empty). Stderr, not
# stdout, because stdout on a HOLD is the quoted evidence the dispatcher
# pastes into the hold message — polluting it would corrupt that message.
err_has() {
  local needle="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local got
  got=$("$@" 2>&1 >/dev/null) || true
  case "$got" in
    *"$needle"*) ok "stderr has '$needle': $*" ;;
    *) bad "stderr missing '$needle': $* (got: $got)" ;;
  esac
}

echo "== gate-delivery-partial-scope.selftest (ga-k2wjn) =="

# ── 0. bash -n on all three touched files ───────────────────────────────────
echo "── 0. bash -n (syntax) ──"
for f in "$GUARD" "$DISPATCHER" "$DELIVERY"; do
  if bash -n "$f" 2>/tmp/gdps-syntax.$$; then
    ok "bash -n $(basename "$f")"
  else
    bad "bash -n $(basename "$f"): $(cat /tmp/gdps-syntax.$$)"
  fi
done
rm -f /tmp/gdps-syntax.$$

# ── Load the REAL heuristic (lib-only = no live sweep) ──────────────────────
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source quality-gate-guard.sh in lib-only mode"; exit 1; }
type gate_delivery_looks_partial >/dev/null 2>&1 \
  || { echo "FATAL: gate_delivery_looks_partial not defined by quality-gate-guard.sh"; exit 1; }

# ── 1. gate_delivery_looks_partial — pure heuristic, every branch ──────────
echo "── 1. gate_delivery_looks_partial (pure heuristic) ──"
rc1 gate_delivery_looks_partial ""
rc1 gate_delivery_looks_partial "Just a normal single-item bug description with no list at all."
rc1 gate_delivery_looks_partial "$(printf '1. only one item\n2. and a second\n')"   # 2 items — below threshold

# ga-cjrxh: these two assert LIST STRUCTURE (a run of >=3 items is found at
# all), which is still exactly what they test. They now carry an explicit
# "ESCOPO:" header because after ga-cjrxh structure ALONE no longer holds a
# bead — structure under a SCOPE or ENUMERATING header does, and structure
# under an unclassifiable header releases with a warning instead (asserted
# separately in 2c, so this section keeps testing structure and only
# structure).
rc0 gate_delivery_looks_partial "$(printf 'Fix the thing.\nESCOPO:\n1. first\n2. second\n3. third\n')"        # 3 numbered items
rc0 gate_delivery_looks_partial "$(printf 'ESCOPO:\na. socios\nb. datas\nc. permeabilidades\nd. anuncio\n')"  # lettered list

# ga-zhfk8: >=3 numbered lines separated by unrelated FLUSH-LEFT prose (a new
# sentence/paragraph, not a continuation of the item above) must NOT trigger.
# v1 counted matching lines anywhere in the text — exactly the gap that let
# it over-fire; v2 requires a genuine run; fix attempt 2 (below) narrows what
# breaks a run from "any non-matching line" to "blank or flush-left
# non-matching line" specifically, so this must still NOT trigger.
rc1 gate_delivery_looks_partial "$(printf '1. first item discussed here.\nSome unrelated paragraph explains context in between.\n2. second item, mentioned much later.\nAnother unrelated paragraph follows.\n3. third item, in passing.\n')"

# ga-zhfk8 fix attempt 2 (gate-rejected attempt 1, GATE-FEEDBACK 2026-08-05
# 06:35): attempt 1's STRICT no-gap consecutive-line requirement regressed on
# realistic multi-line (wrapped) list items — a common way to write a
# deliverables list, arguably more common than terse one-liners. Reviewer's
# own adversarial fixture (embedded verbatim, translated from the gate
# comment): a 3-item numbered list where each item's rationale wraps to an
# INDENTED second line. Attempt 1 flagged this as NOT partial (false
# negative — regressed the exact bug this backstop exists to stop); it MUST
# trigger. Distinguishing signal from the flush-left-prose fixture directly
# above: continuation lines here are indented (hang under the item text),
# those are not.
# (ga-cjrxh: "ESCOPO:" prepended for the same reason as the fixtures above —
# this fixture exists to assert WRAPPED-ITEM run detection, not header policy.
# Its three items are change verbs (Corrigir/Adicionar/Atualizar), so the
# per-item verification rule leaves all three counting, as intended.)
WRAPPED_ITEMS="$(printf 'ESCOPO:\n1. Corrigir o timeout no endpoint X - esta causando falhas ha 2 semanas,\n   afetando mais de 500 usuarios por dia.\n2. Adicionar validacao no campo Y - sem isso, dados corrompidos continuam\n   entrando no banco.\n3. Atualizar a documentacao do endpoint Z.\n')"
rc0 gate_delivery_looks_partial "$WRAPPED_ITEMS"
out_has "1. Corrigir o timeout" -- gate_delivery_looks_partial "$WRAPPED_ITEMS"
out_has "3. Atualizar a documentacao" -- gate_delivery_looks_partial "$WRAPPED_ITEMS"

# ga-zhfk8 (measured 2026-08-04, wa-zlgye false positive): v1 held a bead on
# the bare word "fatia"/"fatias"/"itens aprovados" ANYWHERE in prose, with
# ZERO list structure — common words in this city's technical Portuguese. v2
# drops that standalone-token trigger; these must NOT hold anymore.
rc1 gate_delivery_looks_partial "Precisa fatiar esse trabalho em partes menores."
rc1 gate_delivery_looks_partial "Fatias pequenas, por favor."
rc1 gate_delivery_looks_partial "Os itens aprovados pelo Athos foram: X, Y, Z."
rc1 gate_delivery_looks_partial "FATIA grande demais"     # case-insensitive — still no list structure
rc1 gate_delivery_looks_partial "ITENS APROVADOS: tudo"   # case-insensitive — still no list structure

# ── 1b. Evidence on stdout (ga-zhfk8 fix 3: cite, don't just assert) ───────
echo "── 1b. gate_delivery_looks_partial prints detected evidence ──"
# (ga-cjrxh: "ESCOPO:" added for the same reason as in section 1 — these
# assert that a HOLD quotes its evidence, so the fixtures must be ones that
# still hold.)
out_has "1. first" -- gate_delivery_looks_partial "$(printf 'Fix the thing.\nESCOPO:\n1. first\n2. second\n3. third\n')"
out_has "a. socios" -- gate_delivery_looks_partial "$(printf 'ESCOPO:\na. socios\nb. datas\nc. permeabilidades\nd. anuncio\n')"
NO_EVIDENCE=$(gate_delivery_looks_partial "Just prose, no list, mentions fatia once." 2>/dev/null) || true
eq "no stdout when it does not look partial" "$NO_EVIDENCE" ""

# ── 2. Re-run against the 4 REAL historical bodies (ga-k2wjn + ga-zhfk8 AC) ─
# Embedded verbatim from `bd show` (description+notes) as of 2026-08-04, the
# day this fix was written. ga-k2wjn: "as tres deveriam ter sido retidas."
# ga-zhfk8: wa-zlgye should NOT have been (measured false positive).
echo "── 2. Re-run against the 4 real historical bodies (ga-k2wjn + ga-zhfk8 AC) ──"
WA_UHBQB='ESCOPO
a. ESTABELECIMENTOS — adicionar os SÓCIOS.
b. DATAS combinadas que não apareceram.
c. PERMEABILIDADES foram perdidas no caminho — reintroduzir.
d. Proprietário PESSOA JURÍDICA: CNAE + abertura + capital.
e. ANÚNCIO: hiperlink para o anúncio.
f. CONSTRUÇÃO EXISTENTE: área construída menor.
g. PROJETO APROVADO: mostrar mais dados.
h. PÍLULAS descritivas em Construção existente e Terreno.
i. Emojis repetidos entre seções.'
rc0 gate_delivery_looks_partial "$WA_UHBQB"

WA_A7E98='ESCOPO
1. Decidir o alvo certo: o .gc/settings.json da cidade.
2. Registrar gt tap guard dangerous-command com os matchers corretos.
3. .gc/ e gitignored: precisa de script de reativacao versionado.
4. Corrigir o CLAUDE.md do rig para descrever o que REALMENTE esta ligado.'
rc0 gate_delivery_looks_partial "$WA_A7E98"

# wa-k0m1q's list lives ONLY in .notes — .description is empty (0 chars). The
# heuristic MUST be fed description+notes concatenated, or this one is missed
# exactly like the original incident.
WA_K0M1Q_NOTES='Os 11 itens, na ordem em que ele pediu:
 1. REMOVER a caixa "4 contas".
 2. Timestamp de quando a checagem de uso foi feita.
 3. REMOVER o fundo degradê roxo do card.
⚠️ IMPLEMENTAR EM FATIAS PEQUENAS.'
WA_K0M1Q_DESCRIPTION=''
rc0 gate_delivery_looks_partial "$WA_K0M1Q_DESCRIPTION
$WA_K0M1Q_NOTES"
# and the description-only view (what a naive .description-only read would see)
# must NOT be mistaken for sufficient — document the gap explicitly:
rc1 gate_delivery_looks_partial "$WA_K0M1Q_DESCRIPTION"

# ga-zhfk8's measured false positive (embedded verbatim from `bd show wa-zlgye`
# .description, 2026-08-04 — .notes was empty for this bead). Zero numbered or
# lettered list items; the only thing v1 matched was the bare word "fatia" in
# "fatiar"/"fatiei" plus "a)" as a substring of "detectada)" (x3) appearing in
# ordinary prose. Mayor verified and released it manually the same day: "o
# heurístico casou na PROSA... não como lista de entregas." Must NOT hold.
WA_ZLGYE='O coletor de gravações do Drive manda o arquivo INTEIRO pro Groq Whisper. O Groq recusa
acima de ~25 MB; o `except` em `_transcribe_audio_bytes` (scripts/peter/peter_gdrive_collect.py:111)
loga um warning e devolve None, e o chamador (linha 229) grava o literal
"(sem fala detectada)".

Ou seja: FALHA vira SILÊNCIO. E o viés é o pior possível — quanto MAIOR a ligação, maior o
arquivo, maior a chance de estourar. As ligações longas são exatamente as substantivas.

MEDIDO (03/08/2026): a ligação Athos↔André das 16h54 tem 46min20 e 42,9 MB. O JSON do
/peter-review trazia content="(sem fala detectada)". Baixei, converti pra wav mono 16k,
fatiei em blocos de 10 min e transcrevi via o mesmo Groq: **27.491 caracteres de fala** —
o debrief mais denso do dia (desistência do Cláudio/MCF no Leopoldina, custo de obra da MCF
vs ProTempo, posição financeira do Cláudio, Victor Pardini, Zé Maria Alphansu, projeto
aprovado do Luxemburgo). Tudo isso teria se perdido em silêncio.

CONSERTO: fatiar antes de enviar (ffmpeg -f segment, blocos de ~10 min, wav mono 16k) e
concatenar as transcrições. Receita já validada em
/private/tmp/.../scratchpad/transcribe_long_call.py.

E o mais importante: **nunca gravar "(sem fala detectada)" quando houve ERRO.** Silêncio
genuíno e falha de transcrição precisam ser estados DIFERENTES no JSON — hoje o consumidor
(eu, no /peter-review) não tem como distinguir.'
rc1 gate_delivery_looks_partial "$WA_ZLGYE"

# ── 2b. ga-1yxyt: header-aware run classification ──────────────────────────
# v2 (ga-zhfk8) found list STRUCTURE but had no notion of what a list was
# FOR. ga-o5de8 passed the gate, merged, and was STILL held as
# delivery:partial: its ">=3 numbered lines" were the "O CICLO:" section
# describing the 3-step DEADLOCK being reported, not 3 approved deliverables.
# v3 skips a run whose nearest preceding header classifies as
# DIAGNOSTIC/OBSERVATION; a SCOPE/WORK header or no recognizable header at
# all must still count (fail-safe unchanged).
echo "── 2b. ga-1yxyt: header-aware run classification ──"

# AC #1 (falsifiable, ga-1yxyt): ga-o5de8 verbatim (`bd show ga-o5de8`
# .description, 2026-08-05 — .notes was empty). "O CICLO:" numbers the
# deadlock's 3 steps (must NOT count); "FIX PEDIDO:"/"CRITÉRIO DE ACEITE:"
# use inline "(a)/(b)" and "· " bullets, neither of which is list STRUCTURE
# by this heuristic's own line-start rule, so this fixture also proves the
# fix doesn't depend on those sections lacking real content — they simply
# never formed a qualifying run in the first place. Must NOT hold.
GA_O5DE8='REPORTADO por digo-wa 05/08, com o ciclo mapeado e a saída que ele usou.

O CICLO:
1. O reconciler do ga-k2wjn aplica park:needs-human em bead com gate:passed cujo corpo
   enumera vários entregáveis e que não tem scope_covered:all.
2. O autor NÃO PODE marcar scope_covered:all se um item realmente não foi entregue —
   marcar seria mentir, e é o que a retenção existe para impedir.
3. O gate RECUSA mergear branch cujo source-bead está parked.
=> Se o item que falta está numa branch pendente do MESMO bead, ele NUNCA mergeia: o park
   impede o merge que removeria o park.

⚠️ É um deadlock introduzido por um mecanismo que EU pedi (ga-k2wjn). Ele resolve um
problema real (4 casos de escopo parcial pegos), mas criou este. Não desligar — consertar.

FIX PEDIDO: a retenção por escopo não pode bloquear o merge de uma branch que ENTREGA um
dos itens faltantes. Opções: (a) o park vetar só o FECHAMENTO da bead, não o merge das
branches; (b) permitir merge quando a branch declara qual item do escopo ela cobre.

CRITÉRIO DE ACEITE:
· Bead parked por escopo parcial + branch nova que entrega o item faltante -> MERGEIA.
· CONTROLE: bead parked + branch que NÃO entrega nada do escopo -> continua barrada.
· A bead só FECHA quando o escopo estiver coberto (o valor original do ga-k2wjn preservado).'
rc1 gate_delivery_looks_partial "$GA_O5DE8"

# AC #2 (control — the ga-k2wjn value must not be lost): WA_UHBQB above
# (real ga-k2wjn true-positive) already proves a genuine SCOPE-headed list
# ("ESCOPO" directly preceding the a.-i. run) keeps holding. Direct fixture
# for the "FIX PEDIDO"/"CRITERIO DE ACEITE" vocabulary specifically, since
# ga-o5de8 (above) shows those headers WITHOUT list structure — this shows
# them WITH it, so the header vocabulary itself isn't what's being rejected:
FIX_PEDIDO_WITH_LIST="$(printf 'FIX PEDIDO:\n1. Corrigir o parser de datas.\n2. Adicionar teste de regressao.\n3. Atualizar o changelog.\n')"
rc0 gate_delivery_looks_partial "$FIX_PEDIDO_WITH_LIST"

# AC #3 (fail-safe) — DELIBERATELY REVERSED BY ga-cjrxh (P1, 2026-08-06).
# ga-1yxyt asserted that a list under an UNRECOGNIZED header must still HOLD,
# reasoning that retaining too much costs one human review while retaining too
# little silently drops scope. Measurement overturned the first half: the
# Mayor sampled 4 holds in one session and 3 were false (75%), and both false
# ones re-measured for this bead (ga-tqe4j, ga-05604.2) fire on exactly this
# branch — an unrecognized header ("=== POR QUE E O PIOR CASO DESSA CLASSE
# ===", a criteria section). The real cost is not "one human review": the bead
# stops, the Pilot is barred from re-dispatching it, and it does not shout —
# so the error this fail-safe caused is both EXPENSIVE and SILENT, worse than
# the one it prevents. ga-cjrxh directs the reversal in as many words:
# "preferir errar liberando + reportando a errar segurando".
#
# What ga-1yxyt actually needed — that "could not classify" never collapse
# into "classified as description" — is PRESERVED and strengthened: it now has
# its own named channel on stderr instead of being inferred from a shared rc.
# So the fixture keeps its falsifiable value; only the direction changed, and
# releasing must still WARN, never go silent.
UNKNOWN_HEADER_LIST="$(printf 'ALGUMA SECAO SEM NOME RECONHECIVEL:\n1. item um\n2. item dois\n3. item tres\n')"
rc1 gate_delivery_looks_partial "$UNKNOWN_HEADER_LIST"
err_has "escopo-multiplo:possivel" -- gate_delivery_looks_partial "$UNKNOWN_HEADER_LIST"
err_has "ALGUMA SECAO SEM NOME RECONHECIVEL" -- gate_delivery_looks_partial "$UNKNOWN_HEADER_LIST"
# ...and the three outcomes stay mutually distinguishable (ga-1yxyt's real
# invariant, restated as ga-cjrxh AC3): held / released-with-warning /
# nothing-to-read.
err_has "escopo-multiplo:nao-detectado" -- gate_delivery_looks_partial "Prosa comum, sem lista nenhuma."
err_has "escopo-multiplo:nao-avaliavel" -- gate_delivery_looks_partial ""

# Exclusion isn't a blanket "stop at the first diagnostic run": a LONGER
# diagnostic-headed run must yield the `best` slot to a SHORTER qualifying
# (scope-headed) run found later in the same text — a real partial-scope
# list past a diagnostic section must still be caught.
DIAGNOSTIC_THEN_SCOPE="$(printf 'SINTOMA:\n1. primeiro sintoma observado\n2. segundo sintoma observado\n3. terceiro sintoma observado\n4. quarto sintoma observado\n\nENTREGAVEIS:\n1. corrigir o parser\n2. adicionar teste\n3. atualizar doc\n')"
rc0 gate_delivery_looks_partial "$DIAGNOSTIC_THEN_SCOPE"
out_has "corrigir o parser" -- gate_delivery_looks_partial "$DIAGNOSTIC_THEN_SCOPE"

# ── 2c. ga-cjrxh: a VERIFICATION list is not a DELIVERABLE list ─────────────
# Measured by the Mayor 2026-08-05: in ONE session the guard produced 4 holds
# and 3 were FALSE POSITIVES (75%). The pattern is structural, not bad luck —
# a well-written BUG bead in this city enumerates ACCEPTANCE CRITERIA and TEST
# FIXTURES, so the better the report, the likelier the wrongful hold. And the
# failure mode is BIASED TOWARD SILENCE: a held bead does not shout, it stops.
# v4 therefore inverts the bias — prefer releasing and reporting over holding.
echo "── 2c. ga-cjrxh: verification lists vs deliverable lists ──"

# AC1 (falsifiable): ga-tqe4j verbatim (`bd show ga-tqe4j`, 2026-08-06). The
# run that fired sits under "=== CRITERIO DE ACEITE (falsificavel) ===" — a
# header v3 classified as *scope*, which is why it held. Its 5 items are ONE
# deliverable's acceptance criteria: a FIXTURE, two named CONTROLE, one
# invariant, and "Rodar a suite". Must NOT hold.
GA_TQE4J='=== FIX PEDIDO ===
So declarar RESOLVED apos re-checar o bead individualmente (o label sumiu de
fato). Se o bead nao pode ser re-checado (store nao resolve, consulta falha,
timeout), NAO podar: manter no estado e reportar como "nao verificado nesta
execucao" -- fail-safe. Manter o first_seen intacto nesse caso.

=== CRITERIO DE ACEITE (falsificavel) ===
1. FIXTURE: bead no estado que NAO aparece no flagged_ids porque a consulta do
   seu store falhou -> permanece no estado, com first_seen preservado.
2. CONTROLE (nao pode regredir): bead cujo label REALMENTE sumiu -> continua
   sendo declarado RESOLVED e podado.
3. CONTROLE 3 (o coracao do bug): os dois casos acima devem produzir saidas
   DIFERENTES. Assertar a diferenca, nao so cada um isolado.
4. first_seen sobrevive a uma execucao degradada (nao zera o relogio de idade).
5. Rodar a suite completa e reportar o PLACAR TOTAL.'
rc1 gate_delivery_looks_partial "$GA_TQE4J"

# AC2 (non-regression control — MANDATORY, ga-cjrxh names it explicitly):
# wa-se0zu verbatim excerpt (`bd show wa-se0zu`, 2026-08-06). REAL multi-scope
# — 8 independent layout deltas, of which the merge covered 2. v3 held it, but
# by ACCIDENT: it fired on a numbered VERIFICATION list elsewhere in the body,
# while the actual A.-H. scope list escaped entirely because the lettered
# pattern was lowercase-only. Fixing AC1 without this would RELEASE it. It
# must keep holding — and now for the right reason.
WA_SE0ZU='DELTA MEDIDO com as DUAS TELAS RENDERIZADAS no navegador em 1200px:

A. CREDITOS — hoje grade de 2 COLUNAS compacta; no mockup e 1 COLUNA de linhas em largura
   cheia. E a maior area da pagina e a diferenca mais visivel.
B. BARRA DE SALDO — hoje traco fino/tracejado; no mockup e uma barra VERDE solida e curta.
C. IDADE POR SERVICO — no mockup vem LOGO ABAIXO DO NOME do servico ("ha 25m").
D. CONSUMO DO MES — hoje 5 cards lado a lado numa faixa; no mockup sao LINHAS iguais.
E. CARD DO CLAUDE — hoje grade 2x2 de contas; no mockup as contas sao EMPILHADAS.
F. SELO "RESETA PRIMEIRO" verde na primeira conta + rodape explicativo.
G. RODAPE EXPLICATIVO — o mockup fecha com duas notas curtas. Hoje nao existe.
H. TIMESTAMP DO CARD DO CLAUDE — hoje e uma pilula com borda; no mockup e texto discreto.'
WA_SE0ZU_TITLE='Saldos & Creditos: o LAYOUT aprovado nao chegou na tela — prod diverge do mockup em 8 pontos'
# Held — and the honest reason, measured against the real bead, is the TITLE,
# not the A.-H. list. That run sits under an unclassifiable header ("DELTA
# MEDIDO ..."), so on its own it only warns. Passing the title is what the
# dispatcher does for the real bead, so the assertion mirrors production.
rc0 gate_delivery_looks_partial "$WA_SE0ZU" "$WA_SE0ZU_TITLE"
# Body alone: releases, but never silently — the signal survives as a warning.
rc1 gate_delivery_looks_partial "$WA_SE0ZU"
err_has "escopo-multiplo:possivel" -- gate_delivery_looks_partial "$WA_SE0ZU"
# The [A-Za-z] widening earns its place where it actually decides a hold: an
# UPPERCASE lettered list under a scope header. v3's [a-z]-only pattern could
# not see this shape at all, which is why wa-se0zu's real scope list escaped.
UPPER_UNDER_SCOPE="$(printf 'ESCOPO:\nA. Reescrever a grade de creditos em 1 coluna.\nB. Trocar a barra de saldo por barra solida.\nC. Empilhar as contas do card do Claude.\n')"
rc0 gate_delivery_looks_partial "$UPPER_UNDER_SCOPE"
out_has "A. Reescrever" -- gate_delivery_looks_partial "$UPPER_UNDER_SCOPE"

# ga-cjrxh (d), reinforced by the Mayor: across the 4 measured holds, the one
# signal that separated the true positive from the 3 false ones was the TITLE
# ("prod diverge do mockup em 8 pontos"). It is cheap, independent of how the
# author formatted the body, and it still fires when the body list is written
# in some shape the structural patterns miss. Optional 2nd arg = bead title.
rc0 gate_delivery_looks_partial "Corpo em prosa corrida, sem lista nenhuma." "$WA_SE0ZU_TITLE"
out_has "8 pontos" -- gate_delivery_looks_partial "Corpo em prosa corrida, sem lista nenhuma." "$WA_SE0ZU_TITLE"
# ...but a title with no enumeration must not start holding everything:
rc1 gate_delivery_looks_partial "Corpo em prosa corrida." "Corrigir o parser de datas"
# ...and "2 pontos" is below the >=3 threshold the rest of the guard uses:
rc1 gate_delivery_looks_partial "Corpo em prosa corrida." "prod diverge do mockup em 2 pontos"

# ga-cjrxh (e), Mayor's addition: an item beginning with a NEGATION ("NAO
# mudar X") is never a deliverable — it is a scope RESTRICTION, satisfied by
# doing nothing. Modeled on ga-05604.2's measured shape: 2 real fix items + 1
# fixture + 1 negative constraint, which v3 counted as 4 and held.
GA_05604_SHAPE="$(printf 'ESCOPO:\n1. Reordenar a escrita do label lane antes do in-flight.\n2. Adicionar retry com verificacao na escrita do lane.\n3. FIXTURE: bead cujo lane some entre as duas escritas.\n4. NAO mudar o CAP de concorrencia neste bead.\n')"
rc1 gate_delivery_looks_partial "$GA_05604_SHAPE"

# (b) item-level test verbs. Anchored at the ITEM START on purpose: "Adicionar
# teste de regressao" is a DELIVERABLE that merely mentions a test and must
# keep counting — FIX_PEDIDO_WITH_LIST above is the control that proves it.
VERIF_VERBS="$(printf 'COMO TESTAR:\n1. Rodar a suite completa.\n2. Conferir o placar no log.\n3. Medir a latencia antes e depois.\n4. Verificar que o artefato mudou de data.\n')"
rc1 gate_delivery_looks_partial "$VERIF_VERBS"

# GATE-FEEDBACK (gate run ga-wisp-05gt4qu, reviewer 1, 2026-08-06) — CONFIRMED
# by re-running the real function, then fixed. The verification-LABEL
# alternation carried NO trailing word boundary while its sibling verb
# alternation did, so ordinary Portuguese deliverable openers that merely SHARE
# A PREFIX with a short label were silently counted as verification:
#   "Provavelmente resolve..."  matched PROVA
#   "Controlemos os efeitos..." matched CONTROLE
#   "Evidenciar o problema..."  matched EVIDENCIA
# The damage is a silent -1 on the deliverable count, so an exactly-3-item REAL
# multi-scope run flips from HOLD to RELEASE — and can sink below the ADVISORY
# bar too, meaning not even the warning fires. That is strictly worse than v3
# for that case and undermines the exact distinction this bead introduces.
# None of the fixtures above caught it: they only ever exercised whole-word
# matches (FIXTURE/CONTROLE/RODAR), never a same-prefix DIFFERENT word.
PREFIX_TRAP="$(printf 'ESCOPO:\n1. Provavelmente resolve o problema do timeout, mas confirmar depois.\n2. Controlemos os efeitos colaterais antes de liberar.\n3. Evidenciar o problema no dashboard de metricas.\n')"
rc0 gate_delivery_looks_partial "$PREFIX_TRAP"
out_has "1. Provavelmente" -- gate_delivery_looks_partial "$PREFIX_TRAP"
# ...and the real labels those three collide with must STILL be verification,
# or the fix would have traded one miscount for the opposite one:
REAL_LABELS="$(printf 'ESCOPO:\n1. PROVA: o log mostra o erro na linha 12.\n2. CONTROLE: o caso oposto nao pode regredir.\n3. EVIDENCIA: screenshot anexado ao bead.\n')"
rc1 gate_delivery_looks_partial "$REAL_LABELS"
# AC[0-9] stays UNBOUNDED on purpose, split out of the \b-anchored alternation:
# \b between two digits is not a boundary, so "AC[0-9]\b" silently stops
# matching AC10 and up. The reviewer flagged this as the trap hiding inside the
# obvious one-line fix; both ends are asserted so neither can regress alone.
AC_MULTIDIGIT="$(printf 'ESCOPO:\n1. AC1 o placar total bate.\n2. AC10 o first_seen sobrevive.\n3. AC11 as saidas sao diferentes.\n')"
rc1 gate_delivery_looks_partial "$AC_MULTIDIGIT"

# AC3 (root-class error-vs-empty): "avaliei e nao achei escopo multiplo" and
# "nao consegui avaliar" are DIFFERENT facts and must not share one silent
# rc=1 — otherwise a guard that failed to read the bead looks exactly like a
# guard that read it and cleared it.
err_has "escopo-multiplo:nao-detectado" -- gate_delivery_looks_partial "$GA_TQE4J"
err_has "escopo-multiplo:nao-avaliavel" -- gate_delivery_looks_partial ""
err_has "escopo-multiplo:nao-avaliavel" -- gate_delivery_looks_partial "   "

# ── 3. Control: a normal, single-scope bug (the common case) is unaffected ─
echo "── 3. Control: normal single-item bug body ──"
NORMAL_BUG='O botão X não responde ao clique no mobile.
Reproduzido em iOS 17, Safari. O handler está registrado no elemento errado
após o re-render — mover o addEventListener para o container pai.'
rc1 gate_delivery_looks_partial "$NORMAL_BUG"

# ── 4. Structural wiring: quality-gate-dispatcher.sh ────────────────────────
echo "── 4. Wiring: quality-gate-dispatcher.sh bug/task PASS branch ──"
if grep -q 'IS_PARTIAL=' "$DISPATCHER"; then ok "IS_PARTIAL is computed in dispatcher.sh"; else bad "IS_PARTIAL not found in dispatcher.sh"; fi
if grep -q 'gate_delivery_looks_partial' "$DISPATCHER"; then ok "dispatcher.sh calls gate_delivery_looks_partial"; else bad "dispatcher.sh does not call gate_delivery_looks_partial"; fi
if grep -q '"delivery:partial"' "$DISPATCHER"; then ok "dispatcher.sh labels delivery:partial"; else bad "dispatcher.sh does not label delivery:partial"; fi
if grep -q 'scope_covered:all' "$DISPATCHER"; then ok "dispatcher.sh honors scope_covered:all override"; else bad "dispatcher.sh missing scope_covered:all override"; fi

# ga-6dpoa: the IS_PARTIAL branch must use ITS OWN label (scope:needs-review), not
# gate:needs-human — the latter is read by lifecycle-coherence-janitor's R7 rule as
# "not implementable" and strips gc.routed_to, silently losing routing on beads that
# were only awaiting a scope glance, not blocked on anything. Scoped to the IS_PARTIAL
# branch specifically (via sed range) because dispatcher.sh legitimately sets
# gate:needs-human elsewhere for real circuit-breaks, e.g. ga-lxz5w's sibling-race
# hold — a file-wide grep would give a false read on those unrelated sites.
PARTIAL_BRANCH=$(sed -n '/elif \[ "\$IS_PARTIAL" = "1" \]; then/,/# BUG\/TASK/p' "$DISPATCHER")
# Explicit extraction-succeeded check: without this, a broken sed anchor (e.g. the
# IS_PARTIAL branch gets refactored) would silently empty $PARTIAL_BRANCH, and the
# NEGATIVE check below ("does not add gate:needs-human") would then vacuously pass
# on empty input — a real absence misread as a verified-clean absence.
if [ -z "$PARTIAL_BRANCH" ]; then
  bad "dispatcher.sh's IS_PARTIAL branch extraction found nothing — sed anchors stale? (ga-6dpoa test itself would silently pass its negative check on this empty input)"
fi
if printf '%s' "$PARTIAL_BRANCH" | grep -q '"scope:needs-review"'; then
  ok "dispatcher.sh's IS_PARTIAL branch labels scope:needs-review (ga-6dpoa)"
else
  bad "dispatcher.sh's IS_PARTIAL branch does not label scope:needs-review (ga-6dpoa)"
fi
if printf '%s' "$PARTIAL_BRANCH" | grep -qF 'label add "$BEAD_ID" "gate:needs-human"'; then
  bad "dispatcher.sh's IS_PARTIAL branch still adds bare gate:needs-human (ga-6dpoa regression — collides with janitor R7)"
else
  ok "dispatcher.sh's IS_PARTIAL branch does not add gate:needs-human (ga-6dpoa)"
fi

if grep -qF 'Quality gate PASSED — branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA, gate_run=$GATE_RUN_ID). Closed by autonomous dispatcher (ga-esbg).' "$DISPATCHER"; then
  ok "existing close-reason text preserved (no regression on the full-scope path)"
else
  bad "existing close-reason text missing/changed unexpectedly"
fi

if grep -qF '[ "$IS_STORY" != "1" ] && [ "$IS_PARTIAL" != "1" ]' "$DISPATCHER"; then
  ok "post-merge re-pick verification exempts IS_PARTIAL (no false respawn-hit warning)"
else
  bad "post-merge re-pick verification does not exempt IS_PARTIAL"
fi

# ga-zhfk8 fix 3: the hold message must CITE detected evidence, not just assert.
if grep -qF 'PARTIAL_EVIDENCE=$(gate_delivery_looks_partial' "$DISPATCHER"; then
  ok "dispatcher.sh captures gate_delivery_looks_partial's stdout evidence"
else
  bad "dispatcher.sh does not capture evidence (still asserting without showing)"
fi
if grep -q '\$PARTIAL_EVIDENCE' "$DISPATCHER"; then
  ok "dispatcher.sh quotes \$PARTIAL_EVIDENCE in the hold comment/mail"
else
  bad "dispatcher.sh never uses \$PARTIAL_EVIDENCE — evidence captured but not shown"
fi

# ── 5. Structural wiring: story-delivery.sh task reconciler backstop ───────
echo "── 5. Wiring: story-delivery.sh task reconciler ──"
if grep -q 'gate_delivery_looks_partial' "$DELIVERY"; then ok "story-delivery.sh mirrors gate_delivery_looks_partial"; else bad "story-delivery.sh does not check gate_delivery_looks_partial"; fi
if grep -q 'keep:partial-delivery' "$DELIVERY"; then ok "story-delivery.sh's task_reconciler_verdict has a partial-delivery verdict"; else bad "story-delivery.sh missing keep:partial-delivery verdict"; fi

# ga-6dpoa: same fix, mirrored in the task-reconciler backstop's keep:partial-delivery
# case arm. Scoped via sed range for the same reason as the dispatcher.sh check above.
TASK_PARTIAL_ARM=$(sed -n '/keep:partial-delivery)/,/keep:contradicted-by-gate-failed-or-needs-fix)/p' "$DELIVERY")
# Same extraction-succeeded guard as the dispatcher.sh check above — see its comment.
if [ -z "$TASK_PARTIAL_ARM" ]; then
  bad "story-delivery.sh's keep:partial-delivery arm extraction found nothing — sed anchors stale? (ga-6dpoa test itself would silently pass its negative check on this empty input)"
fi
if printf '%s' "$TASK_PARTIAL_ARM" | grep -q '"scope:needs-review"'; then
  ok "story-delivery.sh's keep:partial-delivery arm labels scope:needs-review (ga-6dpoa)"
else
  bad "story-delivery.sh's keep:partial-delivery arm does not label scope:needs-review (ga-6dpoa)"
fi
if printf '%s' "$TASK_PARTIAL_ARM" | grep -qF 'label add "$TASK_BEAD_ID" "gate:needs-human"'; then
  bad "story-delivery.sh's keep:partial-delivery arm still adds bare gate:needs-human (ga-6dpoa regression — collides with janitor R7)"
else
  ok "story-delivery.sh's keep:partial-delivery arm does not add gate:needs-human (ga-6dpoa)"
fi

# ga-zhfk8 fix 3, mirrored: same evidence-capture-and-quote discipline.
if grep -qF 'TASK_PARTIAL_EVIDENCE=$(gate_delivery_looks_partial' "$DELIVERY"; then
  ok "story-delivery.sh captures gate_delivery_looks_partial's stdout evidence"
else
  bad "story-delivery.sh does not capture evidence (still asserting without showing)"
fi
if grep -q '\$TASK_PARTIAL_EVIDENCE' "$DELIVERY"; then
  ok "story-delivery.sh quotes \$TASK_PARTIAL_EVIDENCE in the hold comment/mail"
else
  bad "story-delivery.sh never uses \$TASK_PARTIAL_EVIDENCE — evidence captured but not shown"
fi

# ── 6. task_reconciler_verdict (story-delivery.sh) — 3rd-arg extension ─────
# Sourced separately (own LIB_ONLY var) so this file also drift-guards the
# real function, not a hand-copy.
echo "── 6. task_reconciler_verdict partial-delivery branch (real function) ──"
STORY_DELIVERY_LIB_ONLY=1 source "$DELIVERY" \
  || { echo "FATAL: could not source story-delivery.sh in lib-only mode"; exit 1; }
type task_reconciler_verdict >/dev/null 2>&1 \
  || { echo "FATAL: task_reconciler_verdict not defined by story-delivery.sh"; exit 1; }

# Existing 2-arg call sites (story-delivery.selftest.sh) must keep working —
# the new 3rd arg must default to "not partial" so this is additive, not breaking.
eq "2-arg call unaffected: unverified → keep" "$(task_reconciler_verdict 0 0)" "keep:merge-not-verified"
eq "2-arg call unaffected: verified → close"  "$(task_reconciler_verdict 0 1)" "close:commit-in-origin-main"

eq "partial beats merge-verified (scope, not artifact, is the question)" \
   "$(task_reconciler_verdict 0 1 1)" "keep:partial-delivery"
eq "contradiction still wins over partial (stale label is not a scope signal either)" \
   "$(task_reconciler_verdict 1 1 1)" "keep:contradicted-by-gate-failed-or-needs-fix"
eq "not partial + verified → close (no regression)" \
   "$(task_reconciler_verdict 0 1 0)" "close:commit-in-origin-main"

echo ""
echo "== gate-delivery-partial-scope: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
