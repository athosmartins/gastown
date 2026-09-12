#!/usr/bin/env bash
# gate-rebase-content-verdict.selftest.sh (ga-m07gc)
#
# Prova o guard que faltava: o merge do gate pode perder um ARQUIVO INTEIRO
# dentro de um commit que sobrevive ao rebase com a mensagem certa.
#
# INCIDENTE (wa-09wg5, 2026-09-05): o commit do builder tinha 5 arquivos
# (f9ca09c77, 453 insercoes); o que entrou em main tinha 4 (189deae3f, 438) —
# a entrada do docs/data_dictionary.md sumiu. Sem conflito, sem log, sem mail.
# O guard existente (branch_bead_commit_verdict, ga-y9a1d) respondeu "yes" com
# toda razao: ele pergunta "o COMMIT sobreviveu?", contando commits e casando o
# id da bead na mensagem — nao ve o conteudo DENTRO do commit. Ponto cego de
# GRANULARIDADE.
#
# Por que isso e pior que um doc perdido: o pre-push do rig tem um Atlas drift
# guard que BLOQUEIA o builder que nao atualiza o data_dictionary. Se o merge
# pode descartar exatamente esse arquivo depois, o guard vira teatro — cobra do
# builder, o builder paga, o merge joga fora, e todo mundo a jusante acredita
# que o atlas esta em dia.
#
# INVARIANTE testado: um rebase sem conflito e um merge 3-way sem conflito do
# mesmo par produzem a MESMA ARVORE (historia diferente, conteudo identico). O
# gate ja calcula essa arvore no pre-check com `merge-tree --write-tree`, entao
# conferir custa uma chamada e zero heuristica.
#
# Estrategia: extrai o bloco VIVO pelos sentinelas SELFTEST-EXTRACT (nunca uma
# copia a mao) e exercita contra repos git de verdade. O Teste 4 e MUTACAO:
# neutralizar a comparacao tem de deixar o Teste 2 vermelho — senao este
# arquivo nao esta provando nada.
#
# 2º INCIDENTE (wa-zpgjl / marker ga-hivi2 / bug ga-slrz7, 2026-09-11): o
# MESMO guard, ja com o fix acima aplicado (ga-m07gc), ainda deixou passar —
# porque o guard computava sua propria arvore "esperada" (`merge-tree
# --write-tree`) rodando `-C` DENTRO do mesmo worktree temporario onde o
# rebase/merge sob teste tinha acabado de rodar. Confirmado ao vivo, reprodu-
# zivel: `merge-tree --write-tree <main> <orig_tip>` roda contra o repo bare
# devolve a arvore CORRETA (com a mudanca do autor); a MESMA chamada rodada
# via `-C <worktree-temporario>` devolve outra arvore, SEM a mudanca —
# byte-identica a arvore que o rebase de verdade produziu. Os dois lados da
# comparacao herdavam a MESMA corrupcao, entao batiam. O Teste 6 abaixo prova
# contra os SHAs reais do incidente, via um worktree de reproducao de
# verdade (nao um repo sintetico) — precisa continuar reprovando se alguem
# reverter rebase_wt_git_dir() para usar `-C "$wt"` direto.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   — $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

[ -f "$DISPATCHER" ] || { echo "dispatcher nao encontrado: $DISPATCHER"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

extract_block() {  # <dest>
  sed -n '/SELFTEST-EXTRACT gate-rebase-content-verdict: BEGIN/,/SELFTEST-EXTRACT gate-rebase-content-verdict: END/p' \
    "$DISPATCHER" > "$1"
}
extract_block "$TMP/block.sh"
if ! grep -q "rebase_content_verdict()" "$TMP/block.sh"; then
  echo "FAIL: sentinelas SELFTEST-EXTRACT nao delimitam rebase_content_verdict"; exit 1
fi

# ── cenario git real ──────────────────────────────────────────────────────────
# base -> main avanca (toca outro arquivo); branch adiciona 2 arquivos.
mkrepo() {
  local R="$1"; mkdir -p "$R"; git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name T
  echo base > "$R/a.txt"; echo doc > "$R/doc.md"
  git -C "$R" add -A; git -C "$R" commit -qm base
  git -C "$R" branch -M main
  git -C "$R" checkout -q -b feat
  echo novo > "$R/novo.txt"; echo "linha do branch" >> "$R/doc.md"
  git -C "$R" add -A; git -C "$R" commit -qm "feat: 2 arquivos"
  git -C "$R" checkout -q main
  echo mais >> "$R/a.txt"
  git -C "$R" add -A; git -C "$R" commit -qm "main avanca"
}
R="$TMP/repo"; mkrepo "$R"
MAIN=$(git -C "$R" rev-parse main); FEAT=$(git -C "$R" rev-parse feat)

run_verdict() { # <new_tip>
  ( . "$TMP/block.sh"; rebase_content_verdict "$R" "$MAIN" "$FEAT" "$1" )
}

# Teste 1 — rebase honesto: arvore bate com o merge 3-way => "yes"
git -C "$R" checkout -q --detach feat
git -C "$R" rebase main -q >/dev/null 2>&1
GOOD=$(git -C "$R" rev-parse HEAD)
V1=$(run_verdict "$GOOD")
[ "$V1" = "yes" ] && ok "rebase que preserva tudo => yes" \
                  || bad "rebase honesto deveria dar yes, deu '$V1'"

# Teste 2 — O BUG: o commit sobrevive, mas um arquivo sumiu dentro dele.
# Reproduz o shape do incidente sem depender do mecanismo git que o causou.
git -C "$R" checkout -q --detach "$GOOD"
git -C "$R" rm -q --cached novo.txt >/dev/null 2>&1
rm -f "$R/novo.txt"
git -C "$R" commit -q --amend --no-edit >/dev/null 2>&1
LOSSY=$(git -C "$R" rev-parse HEAD)
V2=$(run_verdict "$LOSSY")
[ "$V2" = "no" ] && ok "commit sobrevive mas PERDE arquivo => no (o incidente)" \
                 || bad "perda de arquivo deveria dar no, deu '$V2'"

# Teste 2b — a mensagem tem de nomear o arquivo perdido (erro acionavel)
LOST=$( . "$TMP/block.sh"; rebase_content_lost_paths "$R" "$MAIN" "$FEAT" "$LOSSY" )
case "$LOST" in
  *novo.txt*) ok "a mensagem de erro nomeia o arquivo perdido (novo.txt)" ;;
  *) bad "rebase_content_lost_paths nao nomeou novo.txt (deu: '$LOST')" ;;
esac

# Teste 3 — TERCEIRO ESTADO: sem base de comparacao NAO pode virar "yes". A
# partir de ga-pgxs78 cada "unknown" carrega QUAL das 5 condicoes disparou —
# ver o header do proprio rebase_content_verdict() para a lista completa.
V3=$( . "$TMP/block.sh"; rebase_content_verdict "$R" "$MAIN" "$FEAT" "" )
[ "$V3" = "unknown:empty-arg" ] && ok "new_tip vazio => unknown:empty-arg (nunca yes)" \
                      || bad "faltando new_tip deveria dar unknown:empty-arg, deu '$V3'"
V3b=$( . "$TMP/block.sh"; rebase_content_verdict "$R" "$MAIN" "$FEAT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" )
[ "$V3b" = "unknown:bad-actual-sha" ] && ok "new_tip inexistente => unknown:bad-actual-sha (nunca yes)" \
                       || bad "new_tip invalido deveria dar unknown:bad-actual-sha, deu '$V3b'"

# Teste 3c (ga-pgxs78) — <worktree> inexistente: rebase_wt_git_dir() nao
# resolve o git-dir compartilhado => unknown:no-gitdir. Este e o suspeito
# PRINCIPAL apontado pelo incidente real (ga-is6hxl/ga-3y7rxw) — uma
# bisecao textual das 5 condicoes so vale alguma coisa se cada uma tiver
# um teste que realmente a alcanca, nao so as 2 que ja tinham cobertura.
V3c=$( . "$TMP/block.sh"; rebase_content_verdict "$TMP/nao-existe-mesmo" "$MAIN" "$FEAT" "$FEAT" )
[ "$V3c" = "unknown:no-gitdir" ] && ok "worktree inexistente => unknown:no-gitdir (suspeito principal do incidente real)" \
                                 || bad "worktree inexistente deveria dar unknown:no-gitdir, deu '$V3c'"

# Teste 3d (ga-pgxs78) — merge-tree(main_ref, orig_tip) CONFLITA de verdade
# (rc!=0) => unknown:merge-tree-conflict. Repo separado: main e orig_tip
# editam a MESMA linha do MESMO arquivo a partir da mesma base — um
# conflito genuino, nao o shape sintetico do incidente (que o autor do bug
# ja mediu NAO ser a causa aqui, mas o guard ainda precisa acertar quando
# for).
RC="$TMP/repo-conflict"; mkdir -p "$RC"; git -C "$RC" init -q
git -C "$RC" config user.email t@t; git -C "$RC" config user.name T
echo base > "$RC/x.txt"
git -C "$RC" add -A; git -C "$RC" commit -qm base
git -C "$RC" branch -M cmain
git -C "$RC" checkout -q -b cbranch
echo branch-version > "$RC/x.txt"
git -C "$RC" add -A; git -C "$RC" commit -qm "branch: conflicting edit"
git -C "$RC" checkout -q cmain
echo main-version > "$RC/x.txt"
git -C "$RC" add -A; git -C "$RC" commit -qm "main: conflicting edit"
CMAIN=$(git -C "$RC" rev-parse cmain); CBRANCH=$(git -C "$RC" rev-parse cbranch)
V3d=$( . "$TMP/block.sh"; rebase_content_verdict "$RC" "$CMAIN" "$CBRANCH" "$CBRANCH" )
[ "$V3d" = "unknown:merge-tree-conflict" ] && ok "merge-tree(main,orig_tip) conflita de verdade => unknown:merge-tree-conflict" \
                                            || bad "conflito real deveria dar unknown:merge-tree-conflict, deu '$V3d'"

# Teste 4 — MUTACAO: se a comparacao nao comparar, o Teste 2 tem de ficar
# vermelho. Sem isto, os testes acima poderiam passar por acidente.
sed 's/if \[ "\$expected" = "\$actual" \]; then echo "yes"; else echo "no"; fi/echo "yes"/' \
  "$TMP/block.sh" > "$TMP/block_mut.sh"
if ! grep -q 'echo "yes"$' "$TMP/block_mut.sh"; then
  bad "mutacao nao aplicou — o teste 4 nao esta provando nada"
else
  V4=$( . "$TMP/block_mut.sh"; rebase_content_verdict "$R" "$MAIN" "$FEAT" "$LOSSY" )
  [ "$V4" = "yes" ] && ok "mutacao (comparacao neutralizada) deixa a perda passar => o guard e quem pega" \
                    || bad "mutacao deveria devolver yes (provando que a comparacao e o que pega), deu '$V4'"
fi

# Teste 5 — o dispatcher REALMENTE consulta o verdict antes de empurrar.
# Sem isto, a funcao poderia estar perfeita e nunca ser chamada (guard inerte).
SITES=$(grep -c '_CONTENT" = "yes" \] && git -C "\$TMP_MR_WT" push' "$DISPATCHER" 2>/dev/null || echo 0)
[ "$SITES" -ge 4 ] && ok "os 4 caminhos de push conferem o content verdict (achei $SITES)" \
                   || bad "esperava >=4 pushes guardados pelo content verdict, achei $SITES"

# Teste 6 — INCIDENTE REAL (wa-zpgjl / ga-hivi2 / ga-slrz7, 2026-09-11), contra
# o repositorio de verdade, nao um repo sintetico: prova que o guard agora
# pega o caso que passou pelo mecanismo reproduzido ao vivo — merge-tree via
# `-C <worktree>` divergindo da MESMA chamada contra o git-dir compartilhado,
# pro MESMO par de SHAs imutaveis. So roda quando o repo e os commits reais
# estao disponiveis neste ambiente; pula (nao conta como FAIL) caso
# contrario, para nao quebrar em outro ambiente/cidade.
WA_REPO_GITDIR="/Users/athos/gt/whatsapp_automation/.repo.git"
WA_MAIN=a3b44a9bc922b2f97757a9e1a0c8a7073323b638
WA_ORIG_TIP=39a21213353d2fc29ccc2a3d79d8f836c1619d16
WA_NEW_TIP=40eebf04d08d2778cdb25f4058f189e623842dd1
if [ -d "$WA_REPO_GITDIR" ] \
   && git --git-dir="$WA_REPO_GITDIR" cat-file -e "$WA_MAIN" 2>/dev/null \
   && git --git-dir="$WA_REPO_GITDIR" cat-file -e "$WA_ORIG_TIP" 2>/dev/null \
   && git --git-dir="$WA_REPO_GITDIR" cat-file -e "$WA_NEW_TIP" 2>/dev/null; then
  WAWT="$TMP/wa-repro-wt"
  if git --git-dir="$WA_REPO_GITDIR" worktree add --detach "$WAWT" "$WA_ORIG_TIP" >/dev/null 2>&1; then
    V6=$( . "$TMP/block.sh"; rebase_content_verdict "$WAWT" "$WA_MAIN" "$WA_ORIG_TIP" "$WA_NEW_TIP" )
    [ "$V6" = "no" ] && ok "incidente real wa-zpgjl: verdict a partir de um worktree de verdade => no" \
                     || bad "incidente real wa-zpgjl deveria dar 'no' a partir do worktree real, deu '$V6'"
    # sempre desregistra o worktree de reproducao, passe ou falhe o assert
    # acima — nunca deixa um worktree fantasma no repo de PRODUCAO do rig.
    git --git-dir="$WA_REPO_GITDIR" worktree remove --force "$WAWT" >/dev/null 2>&1 || true
  else
    echo "  skip — nao consegui criar worktree de reproducao contra o repo real (nao conta como FAIL)"
  fi
else
  echo "  skip — repo/commits do incidente real (wa-zpgjl) nao disponiveis neste ambiente (nao conta como FAIL)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
