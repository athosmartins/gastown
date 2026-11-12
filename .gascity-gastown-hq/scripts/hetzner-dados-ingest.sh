#!/bin/bash
# hetzner-dados-ingest.sh — o ÚNICO comando da chave do mini no usuário `dados` (forced command, `restrict`): entrega o dado, devolve o resultado, apaga (ga-qg1dw5z.1). Instalado por ROOT como /usr/local/sbin/gt-dados-ingest.
#
# ## Contents
#   Verbos · Códigos de saída
#
# VERBOS (vêm de SSH_ORIGINAL_COMMAND; nada é interpretado como shell, o nome casa ^[a-z0-9][a-z0-9_.-]{0,63}$):
#   put <nome>    lê um tar do stdin para /srv/gtdados/in/<nome>/ (substitui o que havia); link simbólico no tar → tudo apagado e 65; tar que falha → apagado e o rc do tar
#   get <nome>    escreve em stdout um tar de /srv/gtdados/out/<nome>/ (o resultado do build); ausente OU sem nenhum arquivo regular → 66, NUNCA um tar vazio que pareça "resultado vazio"; não consegui ler (find falhou) → 74
#   clean [nome]  apaga in/ e out/ (de um nome, ou tudo sem nome); confere que sumiu
#   status        uma linha: tmpfs sim/não e quantos itens há em in/ e out/ (`?` no lugar do número se não consegui ler, e rc 74)
# in/ e out/ são nomes do BUILD (o `dados` pode trocá-los por link simbólico ou arquivo): put, get e clean <nome> recusam `stage-dirs` (98) se um deles existe e não é diretório de verdade (um caminho que passasse pelo link gravaria o dado fora do tmpfs, em disco);
#   status conta `?` (rc 74); `clean` sem nome apaga o próprio link (é o jeito de sair desse estado).
# CÓDIGOS: 0 ok · 64 verbo ou nome recusado · 65 link simbólico no tar · 66 resultado ausente ou sem arquivo · 67 put sem arquivo nenhum (arquivo tar vazio: apagado) · 73 não consegui criar o destino · 74 status que não conseguiu contar / get que não conseguiu ler · 98 o staging não é um tmpfs próprio, ou in/ ou out/ não é diretório de verdade (o dado NÃO é gravado fora do tmpfs) · 99 apaguei mas ainda sobrou
set -u
PATH=/usr/bin:/bin
STAGE=/srv/gtdados
no() { echo "GTD-INGEST: recusado:$1" >&2; exit "${2:-64}"; }
read -r VERB NAME EXTRA <<< "${SSH_ORIGINAL_COMMAND:-}"
[ -z "${EXTRA:-}" ] || no argumentos
case $VERB in put | get) [[ $NAME =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || no nome ;; clean) [ -z "$NAME" ] || [[ $NAME =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || no nome ;; status) [ -z "$NAME" ] || no argumentos ;; *) no verbo ;; esac
# tmpfs de verdade e montagem PRÓPRIA: vazio/falhou (findmnt ausente, diretório solto no disco) → recusa; o dado nunca vai a bloco de disco por engano
[ "$(findmnt -no FSTYPE --target "$STAGE" 2> /dev/null)" = tmpfs ] && mountpoint -q "$STAGE" || no stage-nao-e-tmpfs 98
# some = não sobrou nada: caminho que não existe já está "apagado"; o -delete leva a pasta junto, então se ela AINDA existe depois (inclusive link solto) é "não consegui", nunca "sumiu"
# tenta TODOS os caminhos (um que sobrou não pula os seguintes: `clean` sem nome tem de tentar out/ mesmo se in/ resistiu) e devolve 1 se ALGUM sobrou
gone() { local p rc=0; for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] || continue; find "$p" -delete 2> /dev/null; if [ -e "$p" ] || [ -L "$p" ]; then rc=1; fi; done; return $rc; }
# itens de um diretório: não existe → 0; find que falha → "?" (nunca 0, que pareceria "nada aqui")
# UM ponto por ENTRADA: o formato '.%.0s' consome um argumento por vez (com `printf .` o `{} +` imprimia 1 ponto por LOTE do find, ou seja, 1 para qualquer N ≥ 1: gate 12/11, tentativa 2)
# existe e não é diretório de verdade (link simbólico, inclusive solto, ou arquivo) → "?": o caminho pelo link não é o staging
isdir() { [ -d "$1" ] && [ ! -L "$1" ]; }
sane() { local d; for d in in out; do if [ -e "$STAGE/$d" ] || [ -L "$STAGE/$d" ]; then isdir "$STAGE/$d" || return 1; fi; done; }
cnt() { local o; [ -e "$1" ] || [ -L "$1" ] || { echo 0; return 0; }; isdir "$1" || { echo '?'; return 0; }; o=$(find "$1" -mindepth 1 -maxdepth 1 -exec printf '.%.0s' {} + 2> /dev/null) || { echo '?'; return 0; }; echo "${#o}"; }
case $VERB in
  put)
    sane || no stage-dirs 98
    [ -d "$STAGE/in" ] || { mkdir "$STAGE/in" && chmod 0700 "$STAGE/in"; } || no destino 73
    gone "$STAGE/in/$NAME" || no sobra-do-put-anterior 99
    mkdir -m 0700 "$STAGE/in/$NAME" || no destino 73
    tar -x --no-same-owner --no-same-permissions -C "$STAGE/in/$NAME"; rc=$?
    [ $rc -eq 0 ] || { gone "$STAGE/in/$NAME"; echo "GTD-INGEST: put falhou (tar rc=$rc), nada ficou" >&2; exit $rc; }
    # vazio → nenhum link; falhou (find com erro) → conta como link: apaga e recusa, nunca deixa o dado
    l=$(find "$STAGE/in/$NAME" -type l -print -quit 2> /dev/null) || l="?"
    [ -z "$l" ] || { gone "$STAGE/in/$NAME"; no link-simbolico-ou-ilegivel 65; }
    # arquivo tar VÁLIDO porém vazio (só blocos de zeros: o tar do remetente morreu antes de listar nada) o `tar -x` aceita com rc 0 sem extrair nada (um stream de 0 byte já sai 2 sozinho, medido no GNU tar 1.35): lote sem arquivo nenhum não é "ok" → apaga e recusa (67). find que falha conta 0 = recusa
    nf=$(find "$STAGE/in/$NAME" -type f 2> /dev/null | wc -l | tr -d ' ')
    [ "${nf:-0}" -gt 0 ] || { gone "$STAGE/in/$NAME"; no put-sem-arquivos 67; }
    echo "GTD-INGEST: put $NAME ok files=$nf" ;;
  get)
    sane || no stage-dirs 98
    [ -d "$STAGE/out/$NAME" ] || no resultado-ausente 66
    # vazio (nenhum arquivo regular: pasta vazia, só links, ou out/<nome> que é link — o find não entra nele) → ausente (66); falhou (find com erro) → 74: nunca "sem resultado" por erro de leitura nem um tar sem nada que pareça "resultado vazio"
    f=$(find "$STAGE/out/$NAME" -type f -print -quit 2> /dev/null) || no resultado-ilegivel 74
    [ -n "$f" ] || no resultado-ausente 66
    exec tar -c -C "$STAGE/out" -- "$NAME" ;;
  clean)
    if [ -n "$NAME" ]; then sane || no stage-dirs 98; gone "$STAGE/in/$NAME" "$STAGE/out/$NAME"; else gone "$STAGE/in" "$STAGE/out"; fi || no sobrou 99
    echo "GTD-INGEST: clean ok" ;;
  status)
    i=$(cnt "$STAGE/in"); o=$(cnt "$STAGE/out"); echo "GTD-INGEST: tmpfs=sim in=$i out=$o"
    case "$i$o" in *'?'*) exit 74 ;; esac ;;
esac
