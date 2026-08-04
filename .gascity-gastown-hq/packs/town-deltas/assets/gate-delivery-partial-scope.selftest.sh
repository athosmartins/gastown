#!/usr/bin/env bash
# gate-delivery-partial-scope.selftest.sh (ga-k2wjn)
#
# Proves the ga-k2wjn fix: a gate PASS on a bug/task bead whose body enumerates
# multiple approved deliverables (a numbered/lettered list, or the words
# fatia/fatias/"itens aprovados") is held as delivery:partial + escalated to
# Mayor instead of auto-closed. "The gate approved the diff" and "the bead's
# full scope is done" are different claims — three real incidents (wa-uhbqb,
# wa-a7e98, wa-k0m1q) conflated them and silently dropped the remaining scope.
#
# WHAT it guards:
#   - gate_delivery_looks_partial() (quality-gate-guard.sh): the pure heuristic,
#     re-run against synthetic fixtures AND the 3 real historical bead bodies
#     (embedded verbatim) — ga-k2wjn's falsifiable "should have been held" AC.
#     Checks BOTH numbered ("1. ") and lettered ("a. ") list markers, and BOTH
#     description+notes (wa-k0m1q's own list lives entirely in .notes — its
#     .description is empty; a description-only check would have missed it).
#   - quality-gate-dispatcher.sh: the bug/task PASS branch forks on IS_PARTIAL
#     before the close call; a scope_covered:all label bypasses the heuristic;
#     the post-merge re-pick verification does not false-flag a held bead as a
#     respawn vector.
#   - story-delivery.sh: the Step 1b task reconciler's task_reconciler_verdict
#     gains a partial-delivery branch so a bead the primary dispatcher already
#     held for review is not silently closed a sweep later by this backstop
#     (and, for the crash-window case where the primary never ran, the
#     backstop applies the same hold+escalate treatment itself).
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
rc0 gate_delivery_looks_partial "Precisa fatiar esse trabalho em partes menores."
rc0 gate_delivery_looks_partial "Fatias pequenas, por favor."
rc0 gate_delivery_looks_partial "Os itens aprovados pelo Athos foram: X, Y, Z."
rc0 gate_delivery_looks_partial "FATIA grande demais"     # case-insensitive
rc0 gate_delivery_looks_partial "ITENS APROVADOS: tudo"   # case-insensitive

# ── 2. Re-run against the 3 REAL historical false-closes (ga-k2wjn's AC) ───
# Embedded verbatim from `bd show` (description+notes) as of 2026-08-04, the
# day this fix was written. ga-k2wjn: "as tres deveriam ter sido retidas."
echo "── 2. Re-run against the 3 real historical bodies (ga-k2wjn AC) ──"
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

# ── 5. Structural wiring: story-delivery.sh task reconciler backstop ───────
echo "── 5. Wiring: story-delivery.sh task reconciler ──"
if grep -q 'gate_delivery_looks_partial' "$DELIVERY"; then ok "story-delivery.sh mirrors gate_delivery_looks_partial"; else bad "story-delivery.sh does not check gate_delivery_looks_partial"; fi
if grep -q 'keep:partial-delivery' "$DELIVERY"; then ok "story-delivery.sh's task_reconciler_verdict has a partial-delivery verdict"; else bad "story-delivery.sh missing keep:partial-delivery verdict"; fi

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
