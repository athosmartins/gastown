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

# Teste 3 — TERCEIRO ESTADO: sem base de comparacao NAO pode virar "yes".
V3=$( . "$TMP/block.sh"; rebase_content_verdict "$R" "$MAIN" "$FEAT" "" )
[ "$V3" = "unknown" ] && ok "new_tip vazio => unknown (nunca yes)" \
                      || bad "faltando new_tip deveria dar unknown, deu '$V3'"
V3b=$( . "$TMP/block.sh"; rebase_content_verdict "$R" "$MAIN" "$FEAT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" )
[ "$V3b" = "unknown" ] && ok "new_tip inexistente => unknown (nunca yes)" \
                       || bad "new_tip invalido deveria dar unknown, deu '$V3b'"

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

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
