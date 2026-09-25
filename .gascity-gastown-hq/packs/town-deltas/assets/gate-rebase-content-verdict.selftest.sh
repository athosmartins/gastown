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
#
# 3º INCIDENTE (ga-stisew / wa-92jot.1, medido pela digo-wa, 2026-09-15): o
# MESMO merge-tree, ja rodando contra o git-dir compartilhado (o fix da
# ga-slrz7 acima), ainda dava veredito ERRADO quando o arquivo envolvido tem
# merge driver custom no .gitattributes (ex.: `merge=union`) — um git-dir
# bare nao tem working tree, entao o driver nunca era aplicado, e uma branch
# perfeitamente sadia virava unknown:merge-tree-conflict, queimando as 3
# tentativas de rebase e escalando ao Mayor (medido: claim->escalado em 11min,
# so resolvido por rebase manual, ~40min de parede numa branch que nao
# precisava de nenhuma acao humana). Fix: aplicar `-c
# core.attributesFile=<materializado de <new_tip>:.gitattributes>` nas DUAS
# chamadas de merge-tree (rebase_content_verdict E rebase_content_lost_paths
# — sao call sites separados). O Teste 7 abaixo prova contra um fixture com
# merge=union, usando um `git merge` de verdade numa working tree de verdade
# como ground truth (nunca a mesma chamada merge-tree que esta sob teste) —
# vermelho antes do fix, verde depois.
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

# run_verdict_at <wt> <main_ref> <orig_tip> <new_tip> — generic form used by
# Teste 8 (ga-r5dsgp) below, which needs a DIFFERENT worktree per case
# (unlike run_verdict()'s single fixed "$R").
run_verdict_at() {
  ( . "$TMP/block.sh"; rebase_content_verdict "$1" "$2" "$3" "$4" )
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

# Teste 3e (ga-19rqcf) — merge-tree FALHA (rc=1, o MESMO codigo do Teste 3d
# acima) mas SEM produzir arvore nenhuma: orig_tip e um SHA que nao existe
# no repo ("bad revision"), nao um conflito de conteudo. Antes desta bead os
# dois casos eram INDISTINGUIVEIS — ambos caiam em unknown:merge-tree-
# conflict — que e exatamente o formato do falso-positivo medido ao vivo 3x
# (ga-pgxs78's ga-is6hxl/ga-3y7rxw; este bead's wa-kohtl/ga-licuhj). Prova
# que agora tem rotulo proprio, sem tocar no Teste 3d acima.
BADSHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
V3e=$( . "$TMP/block.sh"; rebase_content_verdict "$R" "$MAIN" "$BADSHA" "$FEAT" )
[ "$V3e" = "unknown:merge-tree-error" ] && ok "merge-tree falha sem produzir arvore (orig_tip invalido) => unknown:merge-tree-error, NAO merge-tree-conflict" \
                                          || bad "orig_tip invalido deveria dar unknown:merge-tree-error (nunca merge-tree-conflict, nunca yes), deu '$V3e'"

# Teste 3f (ga-19rqcf) — o mesmo cenario tem que carregar o stderr REAL do
# git na mensagem de rebase_content_lost_paths() — nao mais um placeholder
# mudo indistinguivel de um conflito genuino.
LOST_ERR=$( . "$TMP/block.sh"; rebase_content_lost_paths "$R" "$MAIN" "$BADSHA" "$FEAT" )
case "$LOST_ERR" in
  *"merge-tree-error"*"not something we can merge"*) ok "rebase_content_lost_paths carrega o stderr real do git (nao mais mudo)" ;;
  *) bad "rebase_content_lost_paths deveria citar o stderr real do git para o caso nao-conflito, deu: '$LOST_ERR'" ;;
esac

# Teste 3g (ga-19rqcf) — o conflito genuino do Teste 3d NAO ganha o rotulo
# novo, e sua mensagem de lost_paths continua sem stderr (confirmado
# empiricamente: merge-tree nunca escreve em stderr num conflito real —
# tudo vai pro stdout). Se isto vazar "merge-tree-error" pra um conflito de
# verdade, o Teste 3d ja teria pegado (compara string exata) — este e o
# reforco do lado lost_paths().
LOST_CONFLICT=$( . "$TMP/block.sh"; rebase_content_lost_paths "$RC" "$CMAIN" "$CBRANCH" "$CBRANCH" )
[ "$LOST_CONFLICT" = "<could not compute: merge-tree-conflict>" ] && ok "conflito genuino mantem a mensagem original em lost_paths (sem stderr, pois nao ha)" \
                                          || bad "conflito genuino nao deveria mudar de mensagem em lost_paths, deu: '$LOST_CONFLICT'"

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

# Teste 7 (ga-stisew) — merge=union num .gitattributes tracado: duas branches
# EDITAM A MESMA LINHA de forma diferente — conflito de verdade sob merge
# padrao (Teste 7a abaixo prova a premissa) — mas o proprio .gitattributes
# do repo diz `merge=union`, ou seja, e uma branch SADIA. Ground-truth vem
# de um `git rebase` de VERDADE (a mesma operacao que o gate verifica),
# numa working tree onde o driver sempre valeu sem `-c core.attributesFile`
# nenhum — nunca a mesma chamada merge-tree que este teste verifica, senao
# o teste provaria a si mesmo. O "wt" passado pra rebase_content_verdict e
# um CLONE BARE de verdade (sem working tree nenhuma) — um repo nao-bare
# (como o `mkrepo()` dos Testes 1-6 usa) SEMPRE tem .gitattributes no disco
# do proprio checkout e mascara exatamente o bug que este teste existe pra
# pegar (medido: a 1a versao deste teste usava `-C` num repo nao-bare e
# passava mesmo ANTES do fix, porque git lia o .gitattributes do disco, nao
# da flag).
RU="$TMP/repo-union"; mkdir -p "$RU"; git -C "$RU" init -q
git -C "$RU" config user.email t@t; git -C "$RU" config user.name T
printf 'union.txt merge=union\n' > "$RU/.gitattributes"
printf 'l1\nSHARED\nl3\n' > "$RU/union.txt"
git -C "$RU" add -A; git -C "$RU" commit -qm base
git -C "$RU" branch -M umain
git -C "$RU" checkout -q -b ufeat
printf 'l1\nSHARED-feat\nl3\n' > "$RU/union.txt"
git -C "$RU" add -A; git -C "$RU" commit -qm "ufeat: edita SHARED"
git -C "$RU" checkout -q umain
printf 'l1\nSHARED-main\nl3\n' > "$RU/union.txt"
git -C "$RU" add -A; git -C "$RU" commit -qm "umain: edita SHARED"
UMAIN=$(git -C "$RU" rev-parse umain); UFEAT=$(git -C "$RU" rev-parse ufeat)

# Teste 7a — PREMISSA: a mesma edicao, num repo GEMEO sem merge=union
# nenhum, tem de conflitar de verdade (rc!=0). Sem isto, os testes abaixo
# poderiam passar por acidente porque o cenario nunca conflitava mesmo.
RP="$TMP/repo-union-plain"; mkdir -p "$RP"; git -C "$RP" init -q
git -C "$RP" config user.email t@t; git -C "$RP" config user.name T
printf 'l1\nSHARED\nl3\n' > "$RP/union.txt"
git -C "$RP" add -A; git -C "$RP" commit -qm base
git -C "$RP" branch -M pmain
git -C "$RP" checkout -q -b pfeat
printf 'l1\nSHARED-feat\nl3\n' > "$RP/union.txt"
git -C "$RP" add -A; git -C "$RP" commit -qm pfeat
git -C "$RP" checkout -q pmain
printf 'l1\nSHARED-main\nl3\n' > "$RP/union.txt"
git -C "$RP" add -A; git -C "$RP" commit -qm pmain
PMAIN=$(git -C "$RP" rev-parse pmain); PFEAT=$(git -C "$RP" rev-parse pfeat)
git -C "$RP" merge-tree --write-tree "$PMAIN" "$PFEAT" >/dev/null 2>&1
PRC=$?
[ "$PRC" -ne 0 ] && ok "premissa: a mesma edicao SEM merge=union conflita de verdade (rc=$PRC)" \
                 || bad "premissa quebrada: o fixture deveria conflitar sem merge=union, deu rc=0"

# ground-truth: rebase de verdade, numa working tree de verdade.
git -C "$RU" checkout -q ufeat
if git -C "$RU" rebase umain -q >/dev/null 2>&1; then
  UNEWTIP=$(git -C "$RU" rev-parse HEAD)
  RU_BARE="$TMP/repo-union.bare.git"
  git clone --bare -q "$RU" "$RU_BARE"

  V7=$( . "$TMP/block.sh"; rebase_content_verdict "$RU_BARE" "$UMAIN" "$UFEAT" "$UNEWTIP" )
  [ "$V7" = "yes" ] && ok "merge=union: bare merge-tree agora concorda com o rebase real => yes (antes: unknown:merge-tree-conflict)" \
                    || bad "branch sadia sob merge=union deveria dar yes, deu '$V7'"

  LOST7=$( . "$TMP/block.sh"; rebase_content_lost_paths "$RU_BARE" "$UMAIN" "$UFEAT" "$UNEWTIP" )
  [ -z "$LOST7" ] && ok "rebase_content_lost_paths tambem reconhece (2o call site, sem paths divergentes)" \
                   || bad "rebase_content_lost_paths deveria vir vazio (sem divergencia), deu: '$LOST7'"

  # Teste 7c — prova que a leitura vem do COMMIT (git show), nao do disco de
  # um worktree LIGADO ao mesmo bare (requisito 2 da bead): o worktree tem o
  # proprio .gitattributes ADULTERADO (sem merge=union nenhum) no disco: se
  # o veredito mudasse, a implementacao estaria lendo o arquivo do worktree,
  # nao o blob do SHA sendo verificado — a mesma classe de dependencia que a
  # ga-slrz7 (acima) ja teve de remover uma vez.
  RU_WT="$TMP/repo-union-linkedwt"
  git --git-dir="$RU_BARE" worktree add --detach -q "$RU_WT" "$UMAIN"
  printf 'nada aqui — sem merge=union\n' > "$RU_WT/.gitattributes"
  V7c=$( . "$TMP/block.sh"; rebase_content_verdict "$RU_WT" "$UMAIN" "$UFEAT" "$UNEWTIP" )
  git --git-dir="$RU_BARE" worktree remove --force "$RU_WT" >/dev/null 2>&1 || true
  [ "$V7c" = "yes" ] && ok "veredito le do commit (git show), nao do .gitattributes adulterado no disco do worktree" \
                     || bad "adulterar o .gitattributes do worktree NAO deveria mudar o veredito, deu '$V7c' (leitura por disco, nao por commit)"
else
  echo "  skip — rebase de verdade (ground truth com merge=union) falhou neste ambiente, nao conta como FAIL"
fi

# Teste 7d (ga-stisew) — o FILTRO de driver: uma linha com driver CUSTOM
# (nao-embutido) tem de ser DESCARTADA do arquivo materializado, mesmo
# convivendo com uma linha valida (merge=union) no MESMO .gitattributes —
# e o que salva o Teste 6 acima (incidente real: docs/data_dictionary.md
# merge=union convive com daemons/deploy_deps.json merge=deploydeps) de
# tentar executar um driver customizado nao configurado neste git-dir.
RF="$TMP/repo-filter"; mkdir -p "$RF"; git -C "$RF" init -q
git -C "$RF" config user.email t@t; git -C "$RF" config user.name T
printf 'union.txt merge=union\ncustom.txt merge=bogus-unregistered-driver\n' > "$RF/.gitattributes"
printf 'c1\n' > "$RF/custom.txt"
git -C "$RF" add -A; git -C "$RF" commit -qm base
FSHA=$(git -C "$RF" rev-parse HEAD)
FBARE="$TMP/repo-filter.bare.git"; git clone --bare -q "$RF" "$FBARE"
ATTRS_OUT=$( . "$TMP/block.sh"; rebase_git_attributes_file "$FBARE" "$FSHA" )
if [ -n "$ATTRS_OUT" ] && [ -f "$ATTRS_OUT" ]; then
  ATTRS_CONTENT=$(cat "$ATTRS_OUT"); rm -f "$ATTRS_OUT"
  case "$ATTRS_CONTENT" in
    *"bogus-unregistered-driver"*)
      bad "filtro deveria descartar o driver customizado, mas ele sobreviveu: '$ATTRS_CONTENT'" ;;
    *"union.txt merge=union"*)
      ok "filtro mantem merge=union e descarta o driver customizado nao-embutido" ;;
    *)
      bad "filtro deveria manter a linha merge=union, arquivo materializado: '$ATTRS_CONTENT'" ;;
  esac
else
  bad "rebase_git_attributes_file nao materializou arquivo nenhum (esperava um so com a linha union)"
fi

# Teste 8 (ga-r5dsgp) — daemons/deploy_deps.json sole-conflict special case.
#
# INCIDENTE: daemons/deploy_deps.json is registered with a CUSTOM merge
# driver (merge=deploydeps), and rebase_git_attributes_file() (ga-stisew,
# Teste 7d above) deliberately excludes custom drivers from this function's
# own ground-truth merge-tree — so that computation conflicts on this file
# every time main and the branch both regenerated it, forever, turning a
# healthy push into a permanent "unknown:merge-tree-conflict" (ga-r5dsgp: 59
# sweeps on one marker, 2.5h head-of-line block).
#
# GATE FEEDBACK (attempt 1, root-class:error-vs-empty): the first version
# returned "yes" after verifying ONLY deploy_deps.json, so a rebase that
# ALSO dropped some other file — a file neither side conflicted on — still
# had "one conflicting path" and got force-pushed. "yes" now additionally
# requires the tip's tree to differ from the conflicted merge's own tree at
# exactly that one path (8f), the generator that vouches for the file to be
# main's own (8h), $wt to really be the tip (8g), and --check to be bounded
# (8i). 8f and 8h are proven against an in-suite mutation of the shipped code
# (8f-mut / 8h-mut), so they cannot pass by accident.
#
# $wt must be a REAL, non-bare checkout for this (unlike Teste 6's bare
# .repo.git): --check reads $wt's on-disk files, exactly as the live
# dispatcher's $TMP_REBASE_WT already is post-commit, pre-push.
mkrepo_ddj() {  # <dir> [with_other:0|1] [with_feature:0|1] [gen_mode:canon|slow|degraded|selfattest|none]
  local R="$1" with_other="${2:-0}" with_feature="${3:-0}" gen_mode="${4:-canon}" pre=''
  mkdir -p "$R/daemons" "$R/scripts"
  git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name T
  case "$gen_mode" in
    slow)     pre='import time; time.sleep(30)' ;;
    degraded) pre='sys.stderr.write("AVISO varredura degradada: 1 plist(s) nao parseiam agora\n")' ;;
  esac
  # Fixture generator: --check passes iff the committed file's content is
  # exactly the one "canonical" string — a minimal stand-in for the real
  # rig's scripts/gen_daemon_deps.py (wa-9lxa7's "compara o build fresco
  # contra o commitado"); this test only needs pass/fail, not real closures.
  if [ "$gen_mode" != "none" ]; then   # none: a rig that never had a generator
    cat > "$R/scripts/gen_daemon_deps.py" <<PYEOF
#!/usr/bin/env python3
import sys
CANON = '{"n": 2}\n'
if "--check" in sys.argv[1:]:
    $pre
    with open("daemons/deploy_deps.json") as f:
        sys.exit(0 if f.read() == CANON else 1)
sys.exit(0)
PYEOF
  fi
  printf '{"n": 0}\n' > "$R/daemons/deploy_deps.json"
  [ "$with_other" = "1" ] && printf 'base\n' > "$R/other.txt"
  git -C "$R" add -A; git -C "$R" commit -qm base
  git -C "$R" branch -M ddjmain
  git -C "$R" checkout -q -b ddjbranch
  printf '{"n": 1}\n' > "$R/daemons/deploy_deps.json"
  [ "$with_other" = "1" ] && printf 'branch-version\n' > "$R/other.txt"
  # A file the branch ADDS and main never touches: it merges cleanly, so it is
  # NOT among the conflicting paths — exactly the kind a sole-conflict check
  # alone cannot see being dropped (8f).
  [ "$with_feature" = "1" ] && printf 'the branch feature\n' > "$R/feature.txt"
  # selfattest: the branch's OWN authored commit rewrites the generator to approve
  # anything. It merges cleanly (main never touches the generator), so it sits in
  # BOTH the ground-truth merge tree and the rebase tip — invisible to the tree
  # comparison, which is exactly why 8h needs its own requirement.
  [ "$gen_mode" = "selfattest" ] && printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$R/scripts/gen_daemon_deps.py"
  git -C "$R" add -A; git -C "$R" commit -qm "branch regenerates deploy_deps.json"
  git -C "$R" checkout -q ddjmain
  printf '{"n": 5}\n' > "$R/daemons/deploy_deps.json"
  [ "$with_other" = "1" ] && printf 'main-version\n' > "$R/other.txt"
  git -C "$R" add -A; git -C "$R" commit -qm "main regenerates deploy_deps.json differently"
}
# ddj_setup <dir> [with_other] [with_feature] [gen_mode] — builds the fixture
# and sets DDJ_MAIN / DDJ_BRANCH, leaving $dir checked out detached at the
# branch, ready for a "rebase result" commit on top.
ddj_setup() {
  mkrepo_ddj "$@"
  DDJ_MAIN=$(git -C "$1" rev-parse ddjmain); DDJ_BRANCH=$(git -C "$1" rev-parse ddjbranch)
  git -C "$1" checkout -q --detach "$DDJ_BRANCH"
}
RD="$TMP/repo-deploydeps"; ddj_setup "$RD" 0 1

# Teste 8-premise — the two sides genuinely conflict under a plain merge-tree
# (same single-line file, both sides changed it away from base) — without
# this, Testes 8a/8b below could pass by accident because there was never a
# real conflict to special-case around.
git -C "$RD" merge-tree --write-tree "$DDJ_MAIN" "$DDJ_BRANCH" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "premissa: main e branch regeneram deploy_deps.json de forma conflitante sob merge-tree puro" \
               || bad "premissa quebrada: o fixture deveria conflitar sem o driver, ground-truth deu rc=0"

# Teste 8a — THE FIX: the rebase tip keeps EVERY other file (feature.txt too),
# carries a canonical deploy_deps.json, and $wt passes --check => "yes", even
# though the ground-truth 3-way merge genuinely conflicts on this path.
printf '{"n": 2}\n' > "$RD/daemons/deploy_deps.json"
git -C "$RD" commit -qam "gate auto-resolve: regenerated deploy_deps.json"
DDJ_GOOD_TIP=$(git -C "$RD" rev-parse HEAD)
V8A=$(run_verdict_at "$RD" "$DDJ_MAIN" "$DDJ_BRANCH" "$DDJ_GOOD_TIP")
[ "$V8A" = "yes" ] && ok "sole conflict is deploy_deps.json AND every other path matches AND --check green => yes (the ga-r5dsgp fix)" \
                   || bad "expected yes (driver-resolved, rest of tree intact, --check green), got '$V8A'"

# Teste 8b — SAFETY: --check FAILS (drift — the committed content does NOT
# match what regeneration would produce) => stays unknown, never upgraded.
printf '{"n": 999}\n' > "$RD/daemons/deploy_deps.json"
git -C "$RD" commit -qam "corrupted: does not match the generator"
DDJ_BAD_TIP=$(git -C "$RD" rev-parse HEAD)
V8B=$(run_verdict_at "$RD" "$DDJ_MAIN" "$DDJ_BRANCH" "$DDJ_BAD_TIP")
[ "$V8B" = "unknown:deploy-deps-check-failed" ] && ok "--check FAILS on drifted content => unknown:deploy-deps-check-failed (never silently upgraded to yes)" \
                   || bad "expected unknown:deploy-deps-check-failed for drifted content, got '$V8B' (would silently push bad content)"

# Teste 8c — SAFETY: a rig whose main has NO generator at all => nothing to
# vouch for the file, so it cannot be verified; falls through with its own
# reason, no crash, never mistaken for a resolvable case. (A tip that DELETES a
# generator main has is a different shape — the tree comparison catches it as
# deploy-deps-tree-mismatch before this check is ever reached.)
RD2="$TMP/repo-deploydeps-nogen"; ddj_setup "$RD2" 0 0 none; D2_MAIN="$DDJ_MAIN"; D2_BRANCH="$DDJ_BRANCH"
printf '{"n": 2}\n' > "$RD2/daemons/deploy_deps.json"
git -C "$RD2" commit -qam "no generator in this rig"
DDJ2_TIP=$(git -C "$RD2" rev-parse HEAD)
V8C=$(run_verdict_at "$RD2" "$D2_MAIN" "$D2_BRANCH" "$DDJ2_TIP")
[ "$V8C" = "unknown:deploy-deps-generator-unverified" ] && ok "rig with no scripts/gen_daemon_deps.py on main => unknown:deploy-deps-generator-unverified, no crash" \
                   || bad "expected unknown:deploy-deps-generator-unverified when no generator exists, got '$V8C'"

# Teste 8d — SAFETY: a SECOND, unrelated conflicting path alongside
# deploy_deps.json => not a SOLE conflict anymore, falls through unchanged
# (this fix must never mask a real conflict in a DIFFERENT file).
RD3="$TMP/repo-deploydeps-multi"; ddj_setup "$RD3" 1
D3_MAIN="$DDJ_MAIN"; D3_BRANCH="$DDJ_BRANCH"
printf '{"n": 2}\n' > "$RD3/daemons/deploy_deps.json"
git -C "$RD3" commit -qam "gate auto-resolve attempt: only regenerated deploy_deps.json, other.txt still conflicts"
DDJ3_TIP=$(git -C "$RD3" rev-parse HEAD)
V8D=$(run_verdict_at "$RD3" "$D3_MAIN" "$D3_BRANCH" "$DDJ3_TIP")
[ "$V8D" = "unknown:merge-tree-conflict" ] && ok "a SECOND conflicting file (other.txt) alongside deploy_deps.json => NOT treated as sole/resolvable, stays unknown (never masks a real conflict elsewhere)" \
                   || bad "expected unknown:merge-tree-conflict when more than one path conflicts, got '$V8D'"

# Teste 8f — THE GATE-FEEDBACK CASE (attempt 1, blocking): deploy_deps.json is
# the ONLY conflicting path, the tip's deploy_deps.json is canonical (--check
# would pass), but the tip silently DROPPED feature.txt — a file that merges
# cleanly, so no conflict ever named it. The old code said "yes" here and the
# content-losing tip would have been force-pushed.
RD4="$TMP/repo-deploydeps-lostfile"; ddj_setup "$RD4" 0 1
D4_MAIN="$DDJ_MAIN"; D4_BRANCH="$DDJ_BRANCH"
git -C "$RD4" rm -q feature.txt
printf '{"n": 2}\n' > "$RD4/daemons/deploy_deps.json"
git -C "$RD4" commit -qam "rebase tip: canonical deploy_deps.json but feature.txt silently dropped"
DDJ4_TIP=$(git -C "$RD4" rev-parse HEAD)
V8F=$(run_verdict_at "$RD4" "$D4_MAIN" "$D4_BRANCH" "$DDJ4_TIP")
[ "$V8F" = "unknown:deploy-deps-tree-mismatch" ] && ok "sole conflict = deploy_deps.json + a NON-conflicting file dropped by the tip => unknown:deploy-deps-tree-mismatch, NOT yes (the attempt-1 blocking issue)" \
                   || bad "expected unknown:deploy-deps-tree-mismatch for a tip that dropped feature.txt, got '$V8F' (a content-losing tip would be force-pushed)"

# Teste 8f-mut — MUTATION: neutralize the tree-difference requirement and the
# SAME fixture must flip to yes. Without this, 8f could pass for an unrelated
# reason (say, --check failing) and prove nothing about the requirement.
sed 's/if \[ "\$diffout" != "daemons\/deploy_deps.json" \]; then/if false; then/' \
  "$TMP/block.sh" > "$TMP/block_mut8f.sh"
if ! grep -q '^  if false; then$' "$TMP/block_mut8f.sh"; then
  bad "8f-mut: mutacao nao aplicou — 8f nao esta provando nada"
else
  V8FM=$( . "$TMP/block_mut8f.sh"; rebase_content_verdict "$RD4" "$D4_MAIN" "$D4_BRANCH" "$DDJ4_TIP" )
  [ "$V8FM" = "yes" ] && ok "8f-mut: with the tree-difference requirement neutralized the dropped-file tip becomes yes => that requirement is what catches it" \
                      || bad "8f-mut: mutated code should say yes for the dropped-file tip (proving the requirement is what catches it), got '$V8FM'"
fi

# Teste 8g — $wt is NOT the tip (checked out elsewhere), or has a tracked
# modification: --check would read files that are not what is about to be
# pushed => unknown, never a verdict on unrelated on-disk content.
RD5="$TMP/repo-deploydeps-wt"; ddj_setup "$RD5" 0 1
D5_MAIN="$DDJ_MAIN"; D5_BRANCH="$DDJ_BRANCH"
printf '{"n": 2}\n' > "$RD5/daemons/deploy_deps.json"
git -C "$RD5" commit -qam "good tip"
DDJ5_TIP=$(git -C "$RD5" rev-parse HEAD)
git -C "$RD5" checkout -q --detach "$D5_BRANCH"     # wt now at the pre-resolution branch commit
V8G1=$(run_verdict_at "$RD5" "$D5_MAIN" "$D5_BRANCH" "$DDJ5_TIP")
git -C "$RD5" checkout -q --detach "$DDJ5_TIP"
printf '{"n": 12345}\n' > "$RD5/daemons/deploy_deps.json"   # uncommitted edit on disk
V8G2=$(run_verdict_at "$RD5" "$D5_MAIN" "$D5_BRANCH" "$DDJ5_TIP")
git -C "$RD5" checkout -q -- daemons/deploy_deps.json
[ "$V8G1" = "unknown:deploy-deps-wt-not-at-tip" ] && [ "$V8G2" = "unknown:deploy-deps-wt-not-at-tip" ] \
  && ok "\$wt not at new_tip, or dirty => unknown:deploy-deps-wt-not-at-tip (--check never judges files that are not the pushed content)" \
  || bad "expected unknown:deploy-deps-wt-not-at-tip for both a wrong-HEAD wt ('$V8G1') and a dirty wt ('$V8G2')"

# Teste 8h — SELF-ATTESTING GENERATOR: the branch's own authored commit also
# rewrote scripts/gen_daemon_deps.py to exit 0 unconditionally, and its
# deploy_deps.json is WRONG. Running the branch's own generator would bless it; the generator
# must be main's.
RD6="$TMP/repo-deploydeps-selfattest"; ddj_setup "$RD6" 0 1 selfattest
D6_MAIN="$DDJ_MAIN"; D6_BRANCH="$DDJ_BRANCH"
printf '{"n": 999}\n' > "$RD6/daemons/deploy_deps.json"
git -C "$RD6" commit -qam "rebase tip: the branch's own always-approving generator vouches for a WRONG deploy_deps.json"
DDJ6_TIP=$(git -C "$RD6" rev-parse HEAD)
V8H=$(run_verdict_at "$RD6" "$D6_MAIN" "$D6_BRANCH" "$DDJ6_TIP")
[ "$V8H" = "unknown:deploy-deps-generator-unverified" ] && ok "generator at the tip differs from main's => unknown:deploy-deps-generator-unverified (a branch cannot attest its own output)" \
                   || bad "expected unknown:deploy-deps-generator-unverified when the branch rewrote the generator, got '$V8H'"
sed 's/ || \[ "\$main_gen" != "\$tip_gen" \]//' "$TMP/block.sh" > "$TMP/block_mut8h.sh"
if cmp -s "$TMP/block.sh" "$TMP/block_mut8h.sh"; then
  bad "8h-mut: mutacao nao aplicou — 8h nao esta provando nada"
else
  V8HM=$( . "$TMP/block_mut8h.sh"; rebase_content_verdict "$RD6" "$D6_MAIN" "$D6_BRANCH" "$DDJ6_TIP" )
  [ "$V8HM" = "yes" ] && ok "8h-mut: with the generator-identity requirement neutralized the self-attesting branch becomes yes => that requirement is what catches it" \
                      || bad "8h-mut: mutated code should say yes for the self-attesting branch, got '$V8HM'"
fi

# Teste 8i — a --check that outlives GATE_DEPLOY_DEPS_CHECK_TIMEOUT is cut off
# and reported as its own reason; it must not block the sweep or read as green.
RD7="$TMP/repo-deploydeps-slow"; ddj_setup "$RD7" 0 1 slow
D7_MAIN="$DDJ_MAIN"; D7_BRANCH="$DDJ_BRANCH"
printf '{"n": 2}\n' > "$RD7/daemons/deploy_deps.json"
git -C "$RD7" commit -qam "good content, slow generator"
DDJ7_TIP=$(git -C "$RD7" rev-parse HEAD)
T0=$(date +%s)
V8I=$( export GATE_DEPLOY_DEPS_CHECK_TIMEOUT=1; run_verdict_at "$RD7" "$D7_MAIN" "$D7_BRANCH" "$DDJ7_TIP" )
T1=$(date +%s)
{ [ "$V8I" = "unknown:deploy-deps-check-timeout" ] && [ $((T1 - T0)) -lt 20 ]; } \
  && ok "--check past GATE_DEPLOY_DEPS_CHECK_TIMEOUT is cut off => unknown:deploy-deps-check-timeout in $((T1 - T0))s (bounded, not green)" \
  || bad "expected unknown:deploy-deps-check-timeout within <20s for a 30s generator at timeout=1, got '$V8I' after $((T1 - T0))s"

# Teste 8j — a --check that exits 0 but says its plist scan was DEGRADED is
# accepted (same as the rig's own lint) — but never silently: the degraded
# state must be visible on the caller's stderr, next to the run announcement.
RD8="$TMP/repo-deploydeps-degraded"; ddj_setup "$RD8" 0 1 degraded
D8_MAIN="$DDJ_MAIN"; D8_BRANCH="$DDJ_BRANCH"
printf '{"n": 2}\n' > "$RD8/daemons/deploy_deps.json"
git -C "$RD8" commit -qam "good content, degraded scan"
DDJ8_TIP=$(git -C "$RD8" rev-parse HEAD)
V8J=$( . "$TMP/block.sh"; log() { echo "[t] $*"; }; rebase_content_verdict "$RD8" "$D8_MAIN" "$D8_BRANCH" "$DDJ8_TIP" 2>"$TMP/8j.err" )
{ [ "$V8J" = "yes" ] && grep -q 'DEGRADED plist scan' "$TMP/8j.err" && grep -q 'running gen_daemon_deps.py --check' "$TMP/8j.err"; } \
  && ok "--check green with a degraded scan => yes, and the degraded state + the run announcement are on stderr (visible, not silent)" \
  || bad "expected yes + a DEGRADED log line on stderr, got verdict '$V8J' / stderr: $(cat "$TMP/8j.err" 2>/dev/null | tr '\n' '|')"

echo "── Teste 8e — drift-guard: shipped code still has the special-case wired ──"
grep -q 'rebase_deploy_deps_verdict "\$wt" "\$gd" "\$main_ref" "\$new_tip" "\$out"' "$DISPATCHER" \
  && ok "rebase_content_verdict still delegates its conflicted-merge-tree branch to rebase_deploy_deps_verdict" || bad "the ga-r5dsgp delegation is gone from rebase_content_verdict"
grep -q 'gen_daemon_deps.py --check' "$DISPATCHER" \
  && ok "dispatcher still invokes the generator's --check as the verification step" || bad "the --check invocation is gone from the dispatcher"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
