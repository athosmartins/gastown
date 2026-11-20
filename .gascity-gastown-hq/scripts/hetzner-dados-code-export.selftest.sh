#!/usr/bin/env bash
# hetzner-dados-code-export.selftest.sh — hermético: o exportador do MINI (`git archive` + `git ls-tree` do COMMIT, só a lista branca) com repos git de VERDADE num diretório temporário (ga-kwk6fcl).
#
# ## Contents
#   Casos · Mutantes · O que este teste NÃO prova
#
# O exportador roda do jeito que roda no mini: numa pasta de scripts que tem ao lado o instalador de verdade (o `verify-code` dele é a conferência final) e a lista branca; aqui a lista é a de TESTE ($SD) e o repo é um clone
# de um origin local (bare), com o commit bom (M1), três commits hostis de `.gitattributes` (M2 eol=crlf e M3 export-ignore: o `git archive` converte ou omite o arquivo e o verify-code recusa; M4 export-subst: o archive de
# ÁRVORE não expande e o export passa), um ramo lateral FORA de main e uma tag anotada.
# CASOS: export feliz (tar e manifesto exatos, só os arquivos da lista, conteúdo do COMMIT e não da árvore de trabalho, nada de dado de lead, pasta só com os dois arquivos) · uso errado (64) · recusas 98 com o código certo e a pasta
#   de saída SEM EXISTIR depois (sha que não é commit completo, sha fora de main, ref de main ilegível, lista ausente, entrypoint sem linha, destino que já existe com a trava só apagando o que ELA criou) · o que o `verify-code` pega e o mini
#   RECUSA exportar (dado na lista, pasta na lista, eol/export-ignore) e o que ele NÃO precisa recusar (export-subst, cabeçalho global PAX: o archive é da árvore) · mv que falha · a lista de PRODUÇÃO exportada inteira.
# O QUE NÃO PROVA: o `git` do mini (Apple/Homebrew) nem o `tar` BSD; isso é o 1º export de verdade, rodado no mini.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzdados-export-selftest.XXXXXX"); OUTF="$T/stdout"; ERRF="$T/stderr"
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/home" "$T/stubs" "$T/o" "$T/tmp"
# o git do OPERADOR não entra no teste (autocrlf, safecrlf...): HOME e config de sistema vazios
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
# a pasta de scripts do teste = a do mini: o exportador, o instalador DE VERDADE e a lista branca de teste ao lado
SD="$T/scripts"; mkdir -p "$SD"; cp "$HERE/hetzner-dados-code-export.sh" "$HERE/hetzner-dados-install.sh" "$SD/"; chmod +x "$SD"/*.sh
ALLOW_BASE=("build-x bin/build-x" "build-x lib/x.py"); setallow() { printf '%s\n' "$@" > "$SD/hetzner-dados-code-allow.txt"; }; setallow "${ALLOW_BASE[@]}"
# MV_FAIL: o `mv` que falha (só quando o caso põe $T/stubs na frente do PATH)
printf '%s\n' '[ -z "${MV_FAIL:-}" ] || exit 1; exec /bin/mv "$@"' > "$T/stubs/mv"; chmod +x "$T/stubs/mv"
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
has() { grep -q -E -- "$2" "$1"; }; hasnt() { ! grep -q -E -- "$2" "$1"; }
# o exportador da cópia $EX (a do $SD, ou a do mutante) com os argumentos dados; RC e os dois arquivos de saída
EX="$SD/hetzner-dados-code-export.sh"
ex() { "$EX" "$@" > "$OUTF" 2> "$ERRF"; RC=$?; }
# como ex, mas com prazo de 3 s: um exportador que GIRA (laço sem saída) vira RC=124, nunca trava a bateria
ex_t() { local p i=0; "$EX" "$@" > "$OUTF" 2> "$ERRF" & p=$!; while kill -0 "$p" 2> /dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$p" 2> /dev/null; then kill -9 "$p" 2> /dev/null; wait "$p" 2> /dev/null; RC=124; else wait "$p"; RC=$?; fi; }
oi=0; newo() { oi=$((oi+1)); O="$T/o/$oi"; }
# o ambiente git: origin bare + clone. M1 (bom, em main) · M2 `lib/x.py eol=crlf` · M3 `lib/x.py export-ignore` · M4 lib/x.py com $Format:%H$ + export-subst (todos em main) · ramo `side` com um commit FORA de main · tag anotada v1 em M1
mkenv() { rm -rf "$T/origin.git" "$T/wa"; local g=/usr/bin/git
  ( $g init -q --bare -b main "$T/origin.git" && $g clone -q "$T/origin.git" "$T/wa" ) > /dev/null 2>&1
  ( cd "$T/wa" && $g symbolic-ref HEAD refs/heads/main && $g config user.email t@t && $g config user.name t && $g config commit.gpgsign false && $g config core.autocrlf false \
    && mkdir -p bin lib contacts_auth docs/investigations && printf '#!/bin/sh\n' > bin/build-x && chmod 755 bin/build-x && printf 'good\n' > lib/x.py && echo other > lib/other.py \
    && for f in hawkey_outbound_messages_48h.csv lib/tabela.csv contacts_auth/helper.py docs/investigations/nota.py; do echo LEAD-DATA > "$f"; done \
    && $g add -A && $g commit -q -m M1 && $g tag -a v1 -m tag1 \
    && printf 'lib/x.py text eol=crlf\n' > .gitattributes && $g add -A && $g commit -q -m M2 \
    && printf 'lib/x.py export-ignore\n' > .gitattributes && $g add -A && $g commit -q -m M3 \
    && printf 'ver $Format:%%H$\n' > lib/x.py && printf 'lib/x.py export-subst\n' > .gitattributes && $g add -A && $g commit -q -m M4 \
    && $g push -q origin main \
    && $g checkout -q -b side main~3 && printf 'side\n' > lib/side.py && $g add -A && $g commit -q -m S && $g checkout -q main ) > /dev/null 2>&1
  s1=$($g -C "$T/wa" rev-parse main~3 2> /dev/null); s2=$($g -C "$T/wa" rev-parse main~2 2> /dev/null); s3=$($g -C "$T/wa" rev-parse main~1 2> /dev/null); s4=$($g -C "$T/wa" rev-parse main 2> /dev/null)
  sS=$($g -C "$T/wa" rev-parse side 2> /dev/null); sTag=$($g -C "$T/wa" rev-parse v1 2> /dev/null); }
# recusa de verdade: rc 98, o código CERTO no stderr (o rc sozinho não prova qual guarda reprovou) e a pasta de saída SEM EXISTIR (nada fica no mini); enxerga $O do caso (escopo dinâmico)
refused() { local rot=$1 msg=$2
  ck "$rot → 98 $msg e a pasta de saída não existe" bash -c "[ $RC = 98 ] && grep -q 'falhou:$msg' '$ERRF' && [ ! -e '$O' ]"; }
usage_is() { ck "$1 → 64 e a mensagem diz o motivo" bash -c "[ $RC = 64 ] && grep -q -E -- '$2' '$ERRF'"; }

case_happy() { mkenv; local idb idx exp i
  ck "preparo: o repo de teste tem M1..M4 em main, o ramo lateral e a tag anotada (todos com id de 40 hex, e o da tag ≠ o do commit)" bash -c "[ ${#s1} = 40 ] && [ ${#s4} = 40 ] && [ ${#sS} = 40 ] && [ ${#sTag} = 40 ] && [ '$sTag' != '$s1' ] && [ '$sS' != '$s1' ]"
  echo evil > "$T/wa/lib/x.py"   # árvore de trabalho SUJA: o export é do COMMIT, nunca dela
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"
  ck "export feliz: rc 0 e a linha de resumo diz commit, main e o nº de arquivos" bash -c "[ $RC = 0 ] && grep -q '^GTD-EXPORT: ok commit=$s1 main=$s4 (origin/main) arquivos=2 ' '$OUTF'"
  ck "a pasta só tem code.tar e code.manifest (nada de .part nem verify.log) e é 0700" bash -c "[ \"\$(ls -A '$O' | tr '\n' ' ')\" = 'code.manifest code.tar ' ] && [ -n \"\$(find '$O' -maxdepth 0 -perm 700)\" ]"
  idb=$(/usr/bin/git -C "$T/wa" rev-parse "$s1:bin/build-x"); idx=$(/usr/bin/git -C "$T/wa" rev-parse "$s1:lib/x.py")
  exp=$(printf 'gt-dados-code-manifest 1\ncommit %s\n100755 %s bin/build-x\n100644 %s lib/x.py\n' "$s1" "$idb" "$idx")
  ck "o manifesto é EXATAMENTE o ls-tree do commit (cabeçalho, commit, modo+blob-id+caminho)" test "$(cat "$O/code.manifest")" = "$exp"
  ck "o tar de ÁRVORE não leva o cabeçalho global PAX (comment=<sha>): o mesmo tar em qualquer implementação de tar" bash -c "[ \"\$(head -c 4096 '$O/code.tar' | grep -a -c 'comment=')\" = 0 ]"
  ck "o tar tem só a lista (bin/, bin/build-x, lib/, lib/x.py): nenhum dado de lead, nem lib/other.py" test "$(tar -tf "$O/code.tar" | LC_ALL=C sort | tr '\n' ' ')" = "bin/ bin/build-x lib/ lib/x.py "
  rm -rf "$T/xt"; mkdir -p "$T/xt"; tar -x -C "$T/xt" -f "$O/code.tar"
  ck "o conteúdo é o do COMMIT (good), não o da árvore de trabalho suja (evil), e nenhum byte de dado" bash -c "[ \"\$(cat '$T/xt/lib/x.py')\" = good ] && [ -z \"\$(grep -rl LEAD-DATA '$T/xt' 2> /dev/null)\" ]"
  TMPDIR="$T/tmp" bash "$SD/hetzner-dados-install.sh" verify-code --code-tar "$O/code.tar" --code-manifest "$O/code.manifest" --code-sha "$s1" --entrypoint build-x > "$T/v.out" 2>&1; i=$?
  ck "o par exportado passa de novo no verify-code do instalador (a conferência que o nó refaz)" bash -c "[ $i = 0 ] && grep -q '^GTD-CODE: ok commit=$s1 arquivos=2' '$T/v.out'"
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O" --main-ref refs/remotes/origin/main
  ck "--main-ref explícito (refs/remotes/origin/main) e commit mais antigo que a ponta de main (ancestral)" bash -c "[ $RC = 0 ] && [ -s '$O/code.tar' ]"; }
case_usage() { mkenv; newo
  ex; usage_is "sem argumentos" '^uso:'; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x; usage_is "sem --out" '^uso:'; ex --repo "$T/wa" --sha "$s1" --out "$O"; usage_is "sem --entrypoint" '^uso:'
  ex --repo "$T/wa" --entrypoint build-x --out "$O" --nao-existe; usage_is "argumento desconhecido" 'argumento desconhecido: --nao-existe'
  for o in --repo --sha --entrypoint --out --main-ref; do ex_t "$o"; ck "opção sem valor ($o, última palavra) → 64, não gira para sempre" bash -c "[ $RC = 64 ] && grep -q 'opção sem valor: $o' '$ERRF'"; done
  ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O" --main-ref -x; usage_is "--main-ref que começa com - (viraria opção do git)" 'não pode começar com -'
  ck "uso errado: nenhuma pasta de saída foi criada" test ! -e "$O"; }
case_refuse() { mkenv; local ab up
  ab=${s1%????????????????????????????????}; up=$(printf '%s' "$s1" | tr 'a-f' 'A-F')
  newo; ex --repo "$T/wa" --sha "$ab" --entrypoint build-x --out "$O"; refused "sha abreviado (8 hex)" sha-invalido
  newo; ex --repo "$T/wa" --sha "$up" --entrypoint build-x --out "$O"; refused "sha em maiúsculas" sha-invalido
  newo; ex --repo "$T/wa" --sha main --entrypoint build-x --out "$O"; refused "nome de ref no lugar do sha" sha-invalido
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint 'A/../b' --out "$O"; refused "nome de entrypoint inválido" 'entrypoint-invalido:A/../b'
  newo; ex --repo "$T/naoexiste" --sha "$s1" --entrypoint build-x --out "$O"; refused "repo que não existe" repo-ilegivel
  mkdir -p "$T/vazio"; newo; ex --repo "$T/vazio" --sha "$s1" --entrypoint build-x --out "$O"; refused "pasta que não é repo git" repo-ilegivel
  newo; ex --repo "$T/wa" --sha 0000000000000000000000000000000000000000 --entrypoint build-x --out "$O"; refused "id de 40 hex que não é objeto nenhum" sha-nao-e-commit
  newo; ex --repo "$T/wa" --sha "$sTag" --entrypoint build-x --out "$O"; refused "id da TAG anotada (aponta para um commit, mas não é o id dele)" sha-nao-e-commit
  newo; ex --repo "$T/wa" --sha "$sS" --entrypoint build-x --out "$O"; refused "commit do ramo lateral, FORA de main" sha-fora-de-main
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O" --main-ref origin/nao-existe; refused "ref de main que não existe (não consegui saber ≠ está em main)" main-ilegivel
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O" --main-ref ""; refused "--main-ref vazio" main-ilegivel
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint ghost --out "$O"; refused "entrypoint sem linha na lista (o archive sem caminho levaria o commit INTEIRO)" 'entrypoint-sem-linha:ghost'
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --entrypoint ghost --out "$O"; refused "2º entrypoint sem linha (o 1º tem)" 'entrypoint-sem-linha:ghost'
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint "" --out "$O"; refused "--entrypoint com valor VAZIO (nenhum caminho: o archive sem caminho levaria o commit INTEIRO)" entrypoint-vazio
  newo; ex --repo "$T/wa" --sha "$s1" --entrypoint "   " --out "$O"; refused "--entrypoint só com espaços" entrypoint-vazio
  mv "$SD/hetzner-dados-code-allow.txt" "$SD/allow.off"; newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"; refused "lista branca ausente (nunca 'sem lista = exporta tudo')" code-allow-ilegivel; mv "$SD/allow.off" "$SD/hetzner-dados-code-allow.txt"
  # a lista aponta um arquivo que o commit não tem → o `git archive` falha
  setallow "${ALLOW_BASE[@]}" "build-x lib/nao-existe.py"; newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"; refused "arquivo da lista que não está no commit" archive; setallow "${ALLOW_BASE[@]}"
  # o destino é NOVO: o que já existe NÃO é tocado nem apagado pela trava (que só apaga o que o script criou)
  newo; mkdir -p "$O"; echo canario > "$O/canario"; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"
  ck "destino que já existe (com um arquivo dentro) → 98 out-ja-existe e o arquivo do destino segue lá (a trava não apaga o que não criou)" bash -c "[ $RC = 98 ] && grep -q 'falhou:out-ja-existe' '$ERRF' && [ \"\$(cat '$O/canario')\" = canario ]"
  newo; : > "$O"; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"; ck "destino que é um arquivo → 98 out-ja-existe" bash -c "[ $RC = 98 ] && grep -q 'falhou:out-ja-existe' '$ERRF' && [ -f '$O' ]"
  newo; O="$T/sem-pai/dentro"; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"; refused "destino cuja pasta-pai não existe" out-nao-criou; }
# o que o `verify-code` do instalador pega: o mini RECUSA exportar, o motivo exato do instalador vem no stderr e NADA fica no disco
case_verify() { mkenv
  setallow "${ALLOW_BASE[@]}" "build-x hawkey_outbound_messages_48h.csv"; newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"
  ck "arquivo de dado na lista (o csv do vazamento real) → recusa, o instalador diz code-dado-no-export, e a pasta (com o csv dentro do tar) NÃO fica" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-dado-no-export:hawkey_outbound_messages_48h.csv' '$ERRF' && grep -q 'falhou:verify-code' '$ERRF' && [ ! -e '$O' ]"
  setallow "build-x bin/build-x" "build-x lib"; newo; ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"
  ck "pasta na lista (lib): o archive leva lib/other.py também → recusa (code-manifesto-fora-da-lista), nada fica" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-manifesto-fora-da-lista' '$ERRF' && [ ! -e '$O' ]"
  setallow "${ALLOW_BASE[@]}"; newo; ex --repo "$T/wa" --sha "$s2" --entrypoint build-x --out "$O"
  ck "lib/x.py com eol=crlf no .gitattributes: o archive CONVERTE (bytes ≠ blob) → recusa (code-hash:lib/x.py), nada fica" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-hash:lib/x.py' '$ERRF' && [ ! -e '$O' ]"
  newo; ex --repo "$T/wa" --sha "$s3" --entrypoint build-x --out "$O"
  ck "lib/x.py com export-ignore: o archive o OMITE → recusa (code-fora-da-lista), nada fica" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-fora-da-lista' '$ERRF' && [ ! -e '$O' ]"
  # export-subst NÃO é aplicado: o archive é da ÁRVORE (sem commit para expandir), então os bytes do tar são os do blob e o export passa
  newo; ex --repo "$T/wa" --sha "$s4" --entrypoint build-x --out "$O"
  ck "lib/x.py com export-subst: o archive de ÁRVORE não expande o \$Format (bytes = blob) → o export passa (rc 0)" bash -c "[ $RC = 0 ] && [ -s '$O/code.tar' ]"
  rm -rf "$T/xs"; mkdir -p "$T/xs"; tar -x -C "$T/xs" -f "$O/code.tar"
  ck "o Format:%H segue LITERAL em lib/x.py do tar (não virou o hash do commit)" bash -c "grep -q -F 'Format:%H' '$T/xs/lib/x.py'"
  newo; PATH="$T/stubs:$PATH" MV_FAIL=1 ex --repo "$T/wa" --sha "$s1" --entrypoint build-x --out "$O"; refused "mv que falha na hora de dar o nome final (nunca 'ok' sem os arquivos)" mv
  ck "mv que falha: nenhum 'GTD-EXPORT: ok' foi impresso" hasnt "$OUTF" '^GTD-EXPORT: ok'; }
# a lista de PRODUÇÃO (hetzner-dados-code-allow.txt) exportada inteira: um repo com exatamente os arquivos dela e os 3 entrypoints juntos
# vazio/falhou: lista de produção ilegível → `ents` fica vazio e o caso reprova (nunca "exportou sem entrypoint = ok")
case_prod() { local ents="" want="" ep pa x e eargs=() sha g=/usr/bin/git i
  cp "$HERE/hetzner-dados-code-allow.txt" "$SD/hetzner-dados-code-allow.txt"; rm -rf "$T/prod.git" "$T/prodwa"
  ( $g init -q --bare -b main "$T/prod.git" && $g clone -q "$T/prod.git" "$T/prodwa" ) > /dev/null 2>&1
  while read -r ep pa x || [ -n "${ep:-}" ]; do case ${ep:-} in '' | '#'* | @fixture) continue ;; esac
    mkdir -p "$T/prodwa/$(dirname "$pa")"; printf '#!/bin/sh\n' > "$T/prodwa/$pa"; case $pa in bin/*) chmod 755 "$T/prodwa/$pa" ;; esac
    case " $ents " in *" $ep "*) ;; *) ents="$ents $ep" ;; esac; want="$want$pa"$'\n'
  done < "$HERE/hetzner-dados-code-allow.txt"
  ( cd "$T/prodwa" && $g symbolic-ref HEAD refs/heads/main && $g config user.email t@t && $g config user.name t && $g config commit.gpgsign false && $g add -A && $g commit -q -m c && $g push -q origin main ) > /dev/null 2>&1
  sha=$($g -C "$T/prodwa" rev-parse HEAD 2> /dev/null); want=$(printf '%s' "$want" | LC_ALL=C sort -u)
  ck "prod: a lista de produção tem entrypoints e o commit de teste está em main" bash -c "[ -n '$ents' ] && [ ${#sha} = 40 ]"
  for e in $ents; do eargs+=(--entrypoint "$e"); done
  newo; ex --repo "$T/prodwa" --sha "$sha" ${eargs[@]+"${eargs[@]}"} --out "$O"
  [ "$RC" = 0 ] || [ "$QUIET" = 1 ] || { echo "--- prod: rc=$RC"; cat "$ERRF"; echo "--- fim"; }
  ck "prod: a lista de PRODUÇÃO é exportada inteira (rc 0) e o manifesto tem exatamente os arquivos dela" bash -c "[ $RC = 0 ] && [ \"\$(grep '^[0-9]' '$O/code.manifest' | awk '{print \$3}' | LC_ALL=C sort)\" = \"\$(printf '%s' '$want')\" ]"
  setallow "${ALLOW_BASE[@]}"; }
case_happy; case_usage; case_refuse; case_verify; case_prod
# ── mutantes: cada guarda do exportador tirada SOZINHA tem de reprovar o caso que a prova. A cópia mutante vai para $SD/m.sh e roda no lugar do exportador (ao lado do instalador e da lista de teste)
mut() { local name=$1 expr=$2 fn=$3; sed -e "$expr" "$SD/hetzner-dados-code-export.sh" > "$SD/m.sh"; chmod +x "$SD/m.sh"
  cmp -s "$SD/m.sh" "$SD/hetzner-dados-code-export.sh" && { echo "FAIL mutante $name não alterou nada"; fails=$((fails+1)); return; }
  EX="$SD/m.sh"; QUIET=1; BAD=0; "$fn" > /dev/null 2>&1; QUIET=0; EX="$SD/hetzner-dados-code-export.sh"; rm -f "$SD/m.sh"; n=$((n+1)); if [ "$BAD" = 1 ]; then echo "ok   mutante $name reprovado"; else echo "FAIL mutante $name SOBREVIVEU"; fails=$((fails+1)); fi; }
mut E01-sha-sem-forma 's#\[\[ \$SHA =~ ^\[0-9a-f\]{40}\$ \]\] || die sha-invalido#true#' case_refuse
mut E02-entrypoint-sem-forma 's#\[\[ \$e =~ ^\[a-z0-9\]\[a-z0-9_.-\]{0,63}\$ \]\] || die "entrypoint-invalido:\$e"#true#' case_refuse
mut E03-repo-ilegivel-passa 's#git -C "\$REPO" rev-parse --git-dir > /dev/null 2>&1 || die repo-ilegivel#true#' case_refuse
mut E04-id-da-tag-vale-como-commit 's#\[ "\$GOT" = "\$SHA" \] || die sha-nao-e-commit#true#' case_refuse
mut E05-fora-de-main-passa 's#1) die sha-fora-de-main ;;#1) ;;#' case_refuse
mut E06-main-ilegivel-vira-esta-em-main 's#\*) die main-ilegivel ;; esac#*) ;; esac#' case_refuse
mut E07-lista-ausente-sem-motivo 's#\[ -f "\$ALLOW" \] || die code-allow-ilegivel#true#' case_refuse
mut E08-entrypoint-sem-linha-passa 's#\[ -n "\$ps" \] || die "entrypoint-sem-linha:\$e"#true#' case_refuse
mut E09-destino-existente-passa 's#\[ ! -e "\$OUT" \] || die out-ja-existe#true#' case_refuse
mut E10-destino-sem-pai-passa 's#mkdir -m 0700 "\$OUT" || die out-nao-criou#mkdir -m 0700 "$OUT"#' case_refuse
mut E11-archive-que-falha-passa 's#> "\$OUT/code.tar.part" || die archive#> "$OUT/code.tar.part"#' case_refuse
mut E12-sem-a-trava-de-limpeza 's#^FIN=0; trap .*#FIN=0#' case_verify
mut E13-sem-o-verify-code 's#^bash "\$INST" verify-code#true verify-code#' case_verify
mut E14-verify-sem-dizer-o-motivo 's#{ cat "\$OUT/verify.log" >&2; die verify-code; }#{ die verify-code; }#' case_verify
mut E15-mv-que-falha-vira-ok 's#"\$OUT/code.manifest" || die mv#"$OUT/code.manifest"#' case_verify
mut E16-sem-dar-o-nome-final 's#^mv "\$OUT/code.tar.part" "\$OUT/code.tar" && mv "\$OUT/code.manifest.part" "\$OUT/code.manifest" || die mv#true#' case_happy
mut E17-verify-log-fica-na-pasta 's#^rm -f "\$OUT/verify.log"#true#' case_happy
mut E18-trava-apaga-o-export-que-deu-certo 's#^FIN=1$#FIN=0#' case_happy
mut E19-main-ref-com-hifen 's#case \$MAIN in -\*) echo "--main-ref não pode começar com -: \$MAIN" >&2; usage ;; esac#true#' case_usage
mut E20-opcao-sem-valor-gira 's,\[ \$# -ge 2 \] || { echo "opção sem valor: \$1" >&2; usage; },true,' case_usage
mut E22-archive-do-commit-e-nao-da-arvore 's#archive --format=tar "\$SHA^{tree}"#archive --format=tar "$SHA"#' case_happy
mut E23-sem-caminho-nenhum-exporta-o-commit-inteiro 's,\[ "\${#PSPEC\[@\]}" -gt 0 \] || die entrypoint-vazio,true,' case_refuse
mut E21-argumentos-obrigatorios 's#^\[ -n "\$REPO" \] && \[ -n "\$OUT" \] && \[ -n "\$ENTS" \] || usage#true#' case_usage
echo "---"; echo "casos: $n, reprovados: $fails"; [ "$fails" -eq 0 ]
