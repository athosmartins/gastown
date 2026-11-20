#!/bin/bash
# hetzner-dados-code-export.sh — MINI: exporta do COMMIT (nunca da árvore de trabalho) só o fechamento dos entrypoints pedidos, em tar + manifesto, para o NÓ verificar sem repo (ga-kwk6fcl).
#
# ## Contents
#   Uso · Por quê · O que confere antes de qualquer byte sair · Códigos de saída
#
# USO (no mini, com o repo do rig):
#   hetzner-dados-code-export.sh --repo <repo git> --sha <id de 40 hex> --entrypoint <nome> [--entrypoint <nome>]... --out <pasta NOVA> [--main-ref origin/main]
#   → <pasta>/code.tar e <pasta>/code.manifest. Os dois vão ao nó (scp para /root/gt-dados-src, docs/runbooks/hetzner-dados.md) e entram no instalador:
#   hetzner-dados-install.sh apply ... --code-tar <tar> --code-manifest <manifesto> --code-sha <o MESMO sha> (os wrappers do rig passam essas três opções no lugar de --code-dir).
# POR QUÊ: o `apply --code-dir` roda `git archive` NO NÓ e o `git archive` pede ao repo TODO blob do commit (medido: um pathspec de 2 arquivos num clone parcial buscou os 8 blobs do commit, dado de lead incluso);
#   um clone com todos os blobs no nó é o que a wa-4p38ls proíbe. Aqui o `git archive` e o `git ls-tree` do COMMIT rodam no mini, só com os caminhos da lista branca (hetzner-dados-code-allow.txt, AO LADO deste script),
#   e o nó só confere cada arquivo contra o blob-id do manifesto (`git hash-object`), sem repo.
# O QUE CONFERE, tudo aqui e antes de qualquer byte sair do mini: o sha é o id COMPLETO de um commit (nome de ref, abreviação e tag não valem) · é ancestral de --main-ref (a conferência de que "o sha está em main";
#   ref ilegível = recusa, nunca "está"; um origin/main velho recusa por segurança: `git fetch origin main` antes) · o entrypoint tem linha na lista (um `git archive` sem caminho levaria o commit INTEIRO) ·
#   o `verify-code` do instalador aprova o que foi exportado (formato da lista, dado de lead, blob-id de cada arquivo, modos, tipos): é a MESMA conferência que o apply do nó refaz. O archive é da ÁRVORE do commit (`<sha>^{tree}`:
#   sem cabeçalho global PAX e sem expandir `export-subst`); um `.gitattributes` que ainda converte o arquivo (eol, filter) ou o omite (export-ignore) reprova aqui como `code-hash`/`code-fora-da-lista`: conserte o atributo, não a lista.
# CÓDIGOS: 0 · 64 uso · 98 recusa (`GTD-EXPORT: falhou:<passo>`; a pasta --out que este script criou é apagada, nada fica)
set -u
SRC=$(cd "$(dirname "$0")" && pwd); ALLOW=$SRC/hetzner-dados-code-allow.txt; INST=$SRC/hetzner-dados-install.sh
die() { echo "GTD-EXPORT: falhou:$1" >&2; exit 98; }
usage() { echo "uso: $0 --repo <repo git> --sha <40 hex> --entrypoint <nome> [--entrypoint <nome>]... --out <pasta nova> [--main-ref origin/main]" >&2; exit 64; }
REPO=""; SHA=""; OUT=""; MAIN=origin/main; ENTS=""
while [ $# -gt 0 ]; do
  # opção sem valor (última palavra): `shift 2` falha sem deslocar nada e o laço giraria para sempre → recusa (mesma guarda do instalador)
  case $1 in --repo | --sha | --entrypoint | --out | --main-ref) [ $# -ge 2 ] || { echo "opção sem valor: $1" >&2; usage; } ;; esac
  case $1 in
    --repo) REPO=${2:-}; shift 2 ;; --sha) SHA=${2:-}; shift 2 ;; --entrypoint) ENTS="$ENTS ${2:-}"; shift 2 ;; --out) OUT=${2:-}; shift 2 ;; --main-ref) MAIN=${2:-}; shift 2 ;;
    *) echo "argumento desconhecido: $1" >&2; usage ;; esac
done
[ -n "$REPO" ] && [ -n "$OUT" ] && [ -n "$ENTS" ] || usage
# um valor que começa com `-` viraria opção do git
case $MAIN in -*) echo "--main-ref não pode começar com -: $MAIN" >&2; usage ;; esac
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || die sha-invalido
for e in $ENTS; do [[ $e =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || die "entrypoint-invalido:$e"; done
# vazio/falhou: repo que não abre → recusa; commit que não existe deixa GOT vazio e id completo que é OUTRO (tag, ref) deixa GOT diferente: nenhum é igual ao pedido → recusa; só o id de commit IGUAL ao pedido libera
git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1 || die repo-ilegivel
GOT=$(git -C "$REPO" rev-parse --verify --quiet "$SHA^{commit}")
[ "$GOT" = "$SHA" ] || die sha-nao-e-commit
# três respostas e só a 1ª libera: ancestral (rc 0) · NÃO ancestral (rc 1: o sha não está em main, ou o ref local está velho: `git fetch origin main`) · não consegui saber (ref inexistente, repo ilegível: rc ≥ 2) → recusa, nunca "está em main"
git -C "$REPO" merge-base --is-ancestor "$SHA" "$MAIN" 2> /dev/null; rc=$?
case $rc in 0) ;; 1) die sha-fora-de-main ;; *) die main-ilegivel ;; esac
# vazio/falhou: lista ausente → recusa (com o motivo certo); um awk que não lê a lista, como um entrypoint sem linha, deixa ps VAZIO e vazio → recusa (`git archive` SEM caminho levaria o commit inteiro, dado de lead
# incluso). O `verify-code` abaixo revalida a lista a sério (formato, bin/<ep>, dado): este awk só PROPÕE os caminhos
[ -f "$ALLOW" ] || die code-allow-ilegivel
PSPEC=()
for e in $ENTS; do
  ps=$(awk -v e="$e" '$1 == e && NF == 2 { print $2 }' "$ALLOW")
  [ -n "$ps" ] || die "entrypoint-sem-linha:$e"
  while IFS= read -r p; do PSPEC+=("$p"); done <<< "$ps"
done
# vazio: nenhum caminho (um --entrypoint de valor vazio ou só espaços passa por `[ -n "$ENTS" ]` e o laço acima nem itera): sem este teste o `git archive` sem caminho levaria o commit INTEIRO
[ "${#PSPEC[@]}" -gt 0 ] || die entrypoint-vazio
# o destino é NOVO: pasta que já existe (cheia ou vazia) → recusa, nunca sobrescreve um export anterior; a trava só apaga o que ESTE script criou
[ ! -e "$OUT" ] || die out-ja-existe
mkdir -m 0700 "$OUT" || die out-nao-criou
FIN=0; trap '[ "$FIN" = 1 ] || rm -rf -- "$OUT"' EXIT
# falhou (repo ilegível, caminho que não está no commit) → recusa. O tar e o manifesto ficam em .part até o verify-code os aprovar.
# O archive é da ÁRVORE do commit (`<sha>^{tree}`), não do commit: o tar de commit leva um cabeçalho global PAX (`comment=<sha>`) que cada `tar` (GNU, bsdtar do mini) trata a seu modo, e expande `$Format:..$` dos arquivos com
# `export-subst`; o de árvore não tem nenhum dos dois (medido no git 2.43), e quem liga os bytes ao commit é o manifesto
git -C "$REPO" archive --format=tar "$SHA^{tree}" -- "${PSPEC[@]}" > "$OUT/code.tar.part" || die archive
# vazio/falhou: um ls-tree que falha ou não lista nada deixa o manifesto SEM arquivo e o verify-code o recusa (code-manifesto-vazio); modo que não é 100644/100755 (elo, submódulo) também é recusado por ele.
# A linha do ls-tree (`<modo> <tipo> <id>\t<caminho>`) vira `<modo> <id> <caminho>`: é o `git ls-tree` do COMMIT, a identidade de cada arquivo que o nó confere com `git hash-object`
{ echo "gt-dados-code-manifest 1"; echo "commit $SHA"; git -C "$REPO" ls-tree -r "$SHA" -- "${PSPEC[@]}" | awk -F'\t' '{ split($1, m, " "); print m[1], m[3], $2 }'; } > "$OUT/code.manifest.part"
# a MESMA conferência que o apply do nó refaz (lista branca, dado, blob-id de cada arquivo, modos, tipos) roda AQUI, antes de qualquer byte sair do mini; o motivo exato vem do instalador, no stderr
ARGS=(); for e in $ENTS; do ARGS+=(--entrypoint "$e"); done
bash "$INST" verify-code --code-tar "$OUT/code.tar.part" --code-manifest "$OUT/code.manifest.part" --code-sha "$SHA" "${ARGS[@]}" > "$OUT/verify.log" 2>&1 || { cat "$OUT/verify.log" >&2; die verify-code; }
mv "$OUT/code.tar.part" "$OUT/code.tar" && mv "$OUT/code.manifest.part" "$OUT/code.manifest" || die mv
rm -f "$OUT/verify.log"
# vazio/falhou: só informativo (o id que o main-ref tinha); se não der para ler, `?` (a conferência de main já passou acima)
MAINSHA=$(git -C "$REPO" rev-parse --verify --quiet "$MAIN^{commit}") || MAINSHA="?"
FIN=1
echo "GTD-EXPORT: ok commit=$SHA main=$MAINSHA ($MAIN) arquivos=$(grep -c '^[0-9]' "$OUT/code.manifest") tar=$OUT/code.tar manifesto=$OUT/code.manifest"
