#!/usr/bin/env bash
# gate-pre-review-rebase-content-check.selftest.sh (ga-itkbt)
#
# Drift-guard: proves quality-gate-dispatcher.sh's PRE-REVIEW auto-rebase step
# (worktree $TMP_REBASE_WT, ~lines 9440-9900) now gates EVERY push behind the
# same two content-preservation checks the MERGE-TIME rebase (worktree
# $TMP_MR_WT, ~lines 4600-4860) already had — branch_bead_commit_verdict
# (ga-y9a1d: did the branch's own commit survive?) and rebase_content_verdict
# (ga-m07gc: did the resulting TREE match the 3-way merge result, or did a
# whole file silently vanish inside a commit that otherwise survives?).
#
# Both helpers' own internal correctness is already proven by
# gate-rebase-content-verdict.selftest.sh (real git repos, a genuine
# content-loss repro, a mutation test on the comparison itself) and by
# gate-rebase-merge-content-check.selftest.sh for the MERGE-TIME call sites.
# This file does not re-prove that logic — it proves the six PRE-REVIEW call
# sites that had NEITHER check are now wired to it, exactly as the four
# merge-time call sites already are.
#
# INCIDENTS this closes (ga-itkbt, 2026-09-10):
#   wa-hcefm — the auto-rebase silently dropped a docs/data_dictionary.md
#     paragraph the author had just pushed; nothing in the marker, guard log,
#     or verdict mentioned it. The author re-ran the SAME rebase by hand
#     minutes later with zero conflict and zero loss — proving it was never a
#     real conflict, only the auto-rebase's own missing verification.
#   wa-i8kyc (2026-07-11) — the same class dropped 3 whole commits; the
#     reviewer approved the truncated branch and it merged. Content was later
#     recovered by hand (cherry-pick), but no root-cause bead was filed, so it
#     reincided ~2 months later as wa-hcefm above.
#
# Six sites, not four: pre-review additionally has an upfront "merge instead
# of rebase" path (when the branch's own tip is already a merge commit, or it
# is too far ahead for the rebase envelope) that merge-time does not — see
# BRANCH_TIP_IS_MERGE_COMMIT / FORCE_MERGE_REANCHOR in quality-gate-dispatcher.sh.
# Every one of the six pushes a rebase or merge result to the branch, so every
# one gets the guard.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   — $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

[ -f "$DISPATCHER" ] || { echo "dispatcher nao encontrado: $DISPATCHER"; exit 1; }

echo "── gate pre-review rebase content-check drift-guard (ga-itkbt) ──"

# Teste 1 — pre-condicao: os dois helpers de conteudo existem no dispatcher.
# A logica INTERNA deles ja e provada em gate-rebase-content-verdict.selftest.sh;
# aqui so confirmamos presenca, para que um "achei 0 sites" no Teste 2 nao
# possa ser confundido com "os helpers sumiram" — sao duas pre-condicoes
# distintas e este arquivo separa as duas.
if grep -q '^branch_bead_commit_verdict()' "$DISPATCHER" && grep -q '^rebase_content_verdict()' "$DISPATCHER"; then
  ok "dispatcher define os dois helpers de conteudo (branch_bead_commit_verdict, rebase_content_verdict)"
else
  bad "dispatcher esta faltando um dos helpers de conteudo — pre-condicao do guard ausente"
fi

# Teste 2 — o CORE deste bead: os 6 caminhos de push do bloco PRE-REVIEW
# (worktree $TMP_REBASE_WT — distinto de $TMP_MR_WT do merge-time, que
# gate-rebase-content-verdict.selftest.sh Teste 5 ja cobre com o mesmo padrao)
# agora exigem os dois veredicts "yes" antes do `git push`. Pre-fix, este
# grep dava 0 — nenhum site verificava nada antes de empurrar.
GUARD_PAT='PR_COMMIT_VERDICT" = "yes" \] && \[ "\$PR_CONTENT_VERDICT" = "yes" \] && git -C "\$TMP_REBASE_WT" push'
SITES=$(grep -c "$GUARD_PAT" "$DISPATCHER" 2>/dev/null || echo 0)
[ "$SITES" -ge 6 ] && ok "os 6 caminhos de push do pre-review conferem os dois content verdicts antes de empurrar (achei $SITES)" \
                   || bad "esperava >=6 pushes pre-review guardados pelos content verdicts, achei $SITES (ga-itkbt regression — algum site perdeu o guard)"

# Teste 3 — cada site que falha o veredito tem de ABORTAR o git state
# (rebase --abort ou merge --abort, conforme a operacao) em vez de deixar o
# worktree num estado pendurado — mesma higiene que o merge-time ja tinha.
# Conta TOTAL inclui os aborts pre-existentes do "comando falhou" (ja
# presentes antes deste bead) mais os novos do "veredito falhou" (este bead):
# 2 rebase --abort pre-existentes + 2 novos = 4; 4 merge --abort
# pre-existentes + 4 novos = 8.
REBASE_ABORTS=$(grep -c 'git -C "\$TMP_REBASE_WT" rebase --abort 2>/dev/null || true' "$DISPATCHER" 2>/dev/null || echo 0)
MERGE_ABORTS=$(grep -c 'git -C "\$TMP_REBASE_WT" merge --abort 2>/dev/null || true' "$DISPATCHER" 2>/dev/null || echo 0)
if [ "$REBASE_ABORTS" -ge 4 ] && [ "$MERGE_ABORTS" -ge 8 ]; then
  ok "pre-review aborta o git state em falha de veredito nos 6 sites (rebase_aborts=$REBASE_ABORTS merge_aborts=$MERGE_ABORTS)"
else
  bad "esperava >=4 rebase-aborts e >=8 merge-aborts tied to \$TMP_REBASE_WT, achei rebase=$REBASE_ABORTS merge=$MERGE_ABORTS"
fi

# Teste 4 — a mensagem de erro tem de citar os PATHS perdidos
# (rebase_content_lost_paths), nao so um "no" mudo — mesmo padrao acionavel
# que o merge-time ja usa (ver ga-m07gc no bloco merge-time).
LOST_PATH_CALLS=$(grep -c 'rebase_content_lost_paths "\$TMP_REBASE_WT"' "$DISPATCHER" 2>/dev/null || echo 0)
[ "$LOST_PATH_CALLS" -ge 6 ] && ok "os 6 sites citam os paths divergentes via rebase_content_lost_paths (achei $LOST_PATH_CALLS)" \
                             || bad "esperava >=6 chamadas a rebase_content_lost_paths no bloco pre-review, achei $LOST_PATH_CALLS"

# Teste 5 — MUTACAO do padrao usado no Teste 2: prova que o grep discrimina
# corretamente uma linha REALMENTE guardada de uma linha de push comum (o
# shape exato de ANTES deste bead — wa-hcefm/wa-i8kyc). Sem isto, o Teste 2
# poderia estar "passando" com um padrao frouxo demais (que casaria qualquer
# push) ou especifico demais (que nunca bateria com nada, sempre vermelho).
SYN_GUARDED='              if [ "$PR_COMMIT_VERDICT" = "yes" ] && [ "$PR_CONTENT_VERDICT" = "yes" ] && git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>"$_PUSH_ERR_FILE"; then'
SYN_UNGUARDED_PREFIX='        elif git -C "$TMP_REBASE_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" rebase "origin/$DEFAULT_BRANCH" 2>"$_REBASE_ERR_FILE"; then'
SYN_UNGUARDED_PUSH='              if git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>"$_PUSH_ERR_FILE"; then'
if printf '%s\n' "$SYN_GUARDED" | grep -q "$GUARD_PAT"; then
  ok "MUTACAO: o padrao do Teste 2 CASA uma linha realmente guardada (positivo correto)"
else
  bad "MUTACAO: o padrao do Teste 2 NAO casa uma linha guardada de verdade — Teste 2 e falso-negativo (nao prova nada)"
fi
if printf '%s\n%s\n' "$SYN_UNGUARDED_PREFIX" "$SYN_UNGUARDED_PUSH" | grep -q "$GUARD_PAT"; then
  bad "MUTACAO: o padrao do Teste 2 casou o shape PRE-FIX (push sem veredicts, wa-hcefm/wa-i8kyc) — Teste 2 e falso-positivo (nao prova nada)"
else
  ok "MUTACAO: o padrao do Teste 2 corretamente NAO casa o shape pre-fix (push sem veredicts) — confirma que Teste 2 pegaria a regressao original"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
