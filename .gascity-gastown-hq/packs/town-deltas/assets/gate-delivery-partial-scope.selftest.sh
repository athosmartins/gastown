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

rc0 gate_delivery_looks_partial "$(printf 'Fix the thing.\n1. first\n2. second\n3. third\n')"        # 3 numbered items
rc0 gate_delivery_looks_partial "$(printf 'a. socios\nb. datas\nc. permeabilidades\nd. anuncio\n')"  # lettered list

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
WRAPPED_ITEMS="$(printf '1. Corrigir o timeout no endpoint X - esta causando falhas ha 2 semanas,\n   afetando mais de 500 usuarios por dia.\n2. Adicionar validacao no campo Y - sem isso, dados corrompidos continuam\n   entrando no banco.\n3. Atualizar a documentacao do endpoint Z.\n')"
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
out_has "1. first" -- gate_delivery_looks_partial "$(printf 'Fix the thing.\n1. first\n2. second\n3. third\n')"
out_has "a. socios" -- gate_delivery_looks_partial "$(printf 'a. socios\nb. datas\nc. permeabilidades\nd. anuncio\n')"
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
