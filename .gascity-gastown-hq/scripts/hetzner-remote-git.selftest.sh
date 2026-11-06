#!/bin/bash
# hetzner-remote-git.selftest.sh — hermético: tudo em mktemp, o "espelho" é um bare local servido por um `ssh` de mentira (sem rede, sem sshd, sem tocar nos clones reais). Cobre o `pull` de hetzner-remote-git.sh quando o espelho anuncia uma ref cuja ponta NÃO existe no clone (ga-yo1n1zg: a ponta é ancestral de uma presente; ga-eivvcus: a ref é OBSOLETA, o clone já a tem com o valor anunciado), e o gc seguro do clone.
#
# ## Contents
#   Fixture · Controles · Recuperação · Estado visível · Cura · Falha sem contorno · Recusas · Ref obsoleta (reparo) · gc seguro · Falha que não é essa · Lastro hq-mutants (filtro que muda, bootstrap, lag, status, wt-add/wt-rm, scan)
#
# O CASO: em 02/11 o commit c0cc488b9 sumiu do repo.git do nó; o espelho passou a anunciar uma branch nova nessa ponta e TODO pull/fetch morreu em "did not send all necessary objects" (main parado 70 min), com a causa escondida
# (last-pull-error guardava só a última linha do stderr). Aqui o commit some do clone da fixture do mesmo jeito (pack reescrito sem ele) e o `pull` de verdade roda contra ele.
# O `ssh` de mentira serve o bare (FAKE_SRV) e o spec de dados; o shim de git (SHIM_MODE) injeta UMA falha (ls-remote, listagem de objetos, fetch) e repassa o resto ao git de verdade.
# HRG_S=<script> (caminho ABSOLUTO) testa outra cópia do script (mutantes); HRG_KEEP=1 guarda o tmp. Leva ~20 s no nó (Linux, bash 5).
# ONDE VALE: git 2.43.0 do nó (229/229). No git 2.54 do mini o selftest já estava VERMELHO no HEAD anterior (27 de 165 casos, a partir do caso 8: "could not parse commit") e fica com 55 de 218 vermelhos; não analisei um a um. Prove no nó, não no mini.
# MUTANTES: 49 trocas de uma linha do conserto (34 do ga-yo1n1zg + 15 do ga-eivvcus), 42 mortas. As 7 que sobrevivem são EQUIVALENTES, e por quê: o `--filter=` explícito do fetch (o 1º e o do retry) é redundante, porque o `remote.origin.partialclonefilter` que o pull
#   grava logo antes já vale para todo fetch de remoto promisor (e o espelho só serve com o filtro vigente); a `--prune` do retry é redundante no git 2.43, onde o fetch poda ANTES de falhar (medido; fica por git mais velho), e a do fetch final do reparo pelo mesmo motivo; o `sort -u`
#   de `cat-file --batch-all-objects` é redundante onde a saída já vem ordenada (git >= 2.19); o `LC_ALL=C` só vale com git traduzido (a frase que dispara o retry é em inglês); o `+` (força) do refspec avulso da sonda só importaria se já houvesse uma refs/gt/repair/N de outra rodada
#   com valor sem relação, e nesse caso o objeto chega do mesmo jeito (medido no git 2.43: a atualização da ref é recusada, rc 1 do fetch avulso, que o reparo ignora, e o objeto fica no clone) e a ref é apagada logo depois.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); RG=${HRG_S:-$HERE/hetzner-remote-git.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/hrg.XXXXXX"); T=$(cd "$T" && pwd -P); chmod 700 "$T"; N=0; F=0; HRG_EXPECT=237
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_TERMINAL_PROMPT=0
export GT_REMOTE_GIT=$T/node GT_REMOTE_SSH=$T/bin/ssh GT_REMOTE_NOMUX=1 FAKE_SRV=$T/srv.git FAKE_SPEC=$T/spec REAL_GIT REAL_MKTEMP; REAL_GIT=$(command -v git); REAL_MKTEMP=$(command -v mktemp)
ok() { N=$((N+1)); echo "ok   $N - $1"; }
bad() { N=$((N+1)); F=$((F+1)); echo "FAIL $N - $1"; [ -z "${2:-}" ] || echo "     $2" | head -n 8; return 0; }   # sempre 0: `A && bad .. || ok ..` contaria o caso duas vezes
cleanup() { [ -n "${HRG_KEEP:-}" ] && echo "(mantido: $T)" || rm -rf "$T"; }; trap cleanup EXIT
has() { printf '%s' "$OUT" | grep -qF -- "$1" && ok "$2" || bad "$2 (faltou: $1)" "$OUT"; }
hasnt() { printf '%s' "$OUT" | grep -qF -- "$1" && bad "$2 (apareceu: $1)" "$OUT" || ok "$2"; }
present() { GIT_NO_LAZY_FETCH=1 git -C "$1" cat-file -e "$2" 2>/dev/null; }

# ── fixture: "espelho" (bare com ref em refs/remotes/origin/*), ssh e git de mentira, clone feito pelo `bootstrap` de verdade ───────────────────────────────────────
S=$T/srv.git; W=$T/work; K=$T/node/gascity/repo.git; LPE=$T/node/gascity/last-pull-error; LPS=$T/node/gascity/last-pull-skipped; mkdir -p "$T/bin" "$T/shim"
{ echo '/*'; for i in $(seq 1 24); do echo "!/data/x$i"; done; } > "$FAKE_SPEC"   # o spec do espelho: tudo, menos as 24 linhas negadas (>= 20 é o que o pull exige)
cat > "$T/bin/ssh" <<'EOF'
#!/bin/sh
for last; do :; done
case "$last" in
  "gt-mirror-spec "*) [ "${FAKE_SSH_FAIL:-}" != spec ] || { echo "ssh: spec indisponível (de propósito)" >&2; exit 75; }; cat "$FAKE_SPEC"; exit 0 ;;
  "git-upload-pack "*) [ "${FAKE_SSH_FAIL:-}" != upload-pack ] || { echo "ssh: Connection refused (de propósito)" >&2; exit 255; }; exec "$REAL_GIT" upload-pack "$FAKE_SRV" ;;
esac
echo "ssh de mentira: comando inesperado: $last" >&2; exit 97
EOF
cat > "$T/shim/git" <<'EOF'
#!/bin/sh
# o que o git 2.43 do nó imprime no FIM de todo fetch quando o clone tem um gc.log fresco (medido numa cópia do clone de produção, ga-eivvcus)
gcnoise() { printf '%s\n' "" "warning: The last gc run reported the following. Please correct the root cause" "and remove gc.log" "Automatic cleanup will not be performed until the file is removed." "" "warning: Failed to write bitmap index. Packfile doesn't have full closure (object ef01 is missing)" "fatal: failed to write bitmap index" "fatal: failed to run repack"; } >&2
case " $* " in *" fetch "*) [ -z "${SHIM_FETCHLOG:-}" ] || echo "$*" >> "$SHIM_FETCHLOG" ;; esac   # registra o argv de todo fetch (o selftest confere o filtro e a contagem)
case "${SHIM_MODE:-}:$*" in
  lsfail:*" ls-remote "*) echo "shim: ls-remote falhou (de propósito)" >&2; exit 128 ;;
  lsempty:*" ls-remote "*) exit 0 ;;
  objfail:*" cat-file --batch-all-objects "*) echo "shim: cat-file falhou (de propósito)" >&2; exit 128 ;;
  objempty:*" cat-file --batch-all-objects "*) exit 0 ;;
  retryfail:*"remote.origin.fetch=^"*" fetch "*) echo "error: boom no retry (de propósito)" >&2; exit 1 ;;
  fetchfake:*" fetch "*) echo "error: ssh://x/y.git did not send all necessary objects" >&2; exit 1 ;;
  flood:*" fetch "*) i=0; while [ $i -lt 300 ]; do echo "error: ruido $i" >&2; i=$((i+1)); done; echo "error: ssh://x/y.git did not send all necessary objects" >&2; exit 1 ;;
  cfgfail:*" config gc.cruftPacks "*) echo "shim: git config falhou (de propósito)" >&2; exit 1 ;;
  dedupe:*"refs/gt/repair/2"*) echo "shim: 2 refspecs avulsos para a mesma ponta (de propósito)" >&2; exit 1 ;;
  fetchnoise:*" fetch "*) printf '%s\n' "fatal: bad revision 'abc'" "error: ssh://x/y.git did not send all necessary objects" >&2; gcnoise; exit 1 ;;
  noiseonly:*" fetch "*) gcnoise; exit 1 ;;
esac
exec "$REAL_GIT" "$@"
EOF
cat > "$T/shim/mktemp" <<'EOF'
#!/bin/sh
[ "${SHIM_MODE:-}" = mktempfail ] && [ "${1:-}" = -d ] && { echo "shim: mktemp -d falhou (de propósito)" >&2; exit 1; }
exec "$REAL_MKTEMP" "$@"
EOF
chmod 755 "$T/bin/ssh" "$T/shim/git" "$T/shim/mktemp"
git init -q --bare "$S"; git -C "$S" config uploadpack.allowFilter true; git -C "$S" hash-object -w --stdin < "$FAKE_SPEC" > /dev/null   # o oid do spec tem de existir no espelho: `--filter=sparse:oid=` resolve lá
git init -q "$W"; cm() { git -C "$W" add -A && git -C "$W" commit -qm "$1" && git -C "$W" rev-parse HEAD; }
mkdir -p "$W/lib" "$W/data"; echo a > "$W/README"; echo ok > "$W/lib/ok.txt"; A=$(cm A); echo c > "$W/lib/c.txt"; C=$(cm C); echo m > "$W/lib/m.txt"; M=$(cm M)
git -C "$W" push -q "$S" "$M:refs/remotes/origin/main" "$M:refs/gt/synced" "$A:refs/remotes/origin/fix/velha"; cp -a "$S" "$T/srv.boot.git"
echo k > "$T/key"; echo kh > "$T/kh"; OUT=$("$RG" bootstrap gascity ssh://u@127.0.0.1:2293/gascity.git "$T/key" "$T/kh" feat/ 2>&1)
has 'resultado=ok' "fixture: o bootstrap de verdade clonou pelo ssh de mentira"
# o commit C some do clone como em produção: o pack é reescrito sem ele (o objeto some, o filho M continua apontando para ele)
git -C "$K" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null | grep -v "^$C" > "$T/keep.list"; OLD=$(ls "$K"/objects/pack/*.pack)
NEW=$(git -C "$K" pack-objects "$K/objects/pack/pack" < "$T/keep.list" | tail -n 1); : > "$K/objects/pack/pack-$NEW.promisor"
for p in $OLD; do [ "${p%.pack}" = "$K/objects/pack/pack-$NEW" ] || rm -f "${p%.pack}".*; done
# o espelho anda: main/synced avançam (e trazem um arquivo NEGADO pelo spec), nasce uma ref sadia, nasce uma ref NA PONTA ausente, e a ref velha sai
echo m2 > "$W/lib/m2.txt"; echo 'SEGREDO-x1' > "$W/data/x1"; M2=$(cm M2); VIS=$(git -C "$W" rev-parse "$M2:lib/m2.txt"); SEG=$(git -C "$W" rev-parse "$M2:data/x1"); echo e > "$W/lib/e.txt"; E=$(cm E)
git -C "$W" push -q "$S" "$M2:refs/remotes/origin/main" "$M2:refs/gt/synced" "$E:refs/remotes/origin/fix/sadia" "$C:refs/remotes/origin/fix/quebrado" "$C:refs/heads/fora"; git -C "$S" update-ref -d refs/remotes/origin/fix/velha   # refs/heads/fora: ponta ausente, mas FORA do que o fetch busca
cp -a "$S" "$T/srv.adv.git"; cp -a "$T/node" "$T/node.base"
mkdir -p "$T/cwd/refs/remotes/origin" "$T/cwd/refs/gt"; : > "$T/cwd/refs/remotes/origin/x"; : > "$T/cwd/refs/gt/y"; cd "$T/cwd" || exit 9   # cwd com arquivos que CASAM com os padrões de ref: sem `set -f` no pull o shell os expandiria
fresh() { rm -rf "$T/node" "$T/srv.git"; cp -a "$T/node.base" "$T/node"; cp -a "$T/srv.$1.git" "$T/srv.git"; }   # $1 = boot (espelho como no bootstrap) | adv (espelho andou)
pull() { if [ -n "${1:--}" ] && [ "${1:--}" != - ]; then OUT=$(env PATH="$T/shim:$PATH" SHIM_MODE="$1" "$RG" pull gascity 2>&1); else OUT=$("$RG" pull gascity 2>&1); fi; RC=$?; }
ref_of() { git -C "$K" rev-parse -q --verify "$1" 2>/dev/null; }
OIDF() { git -C "$K" config gtremote.sparseoid; }

# ── controles: a fixture reproduz a falha de produção (senão nenhum caso abaixo prova coisa alguma) ──────────────────────────────────────────────────────────────────
fresh adv
present "$K" "$M" && ok "controle: o detector de objeto presente enxerga M no clone" || bad "controle: M não está no clone"
present "$K" "$C" && bad "controle: C ainda está no clone (a perda não foi simulada)" || ok "controle: C sumiu do clone (como o c0cc488b9 em produção)"
[ "$(ref_of refs/remotes/origin/fix/velha)" = "$A" ] && ok "controle: fix/velha existe no clone antes do pull (o fetch --prune poda ANTES de falhar, então a checagem tem de vir antes)" || bad "controle: fix/velha não existe no clone"
OUT=$(git -C "$K" fetch -q --prune "--filter=sparse:oid=$(OIDF)" origin 2>&1); R=$?
[ "$R" != 0 ] && printf '%s' "$OUT" | grep -qF 'did not send all necessary objects' && ok "controle: o fetch simples do pull antigo morre em 'did not send all necessary objects'" || bad "controle: este git NÃO reproduz a falha (rc=$R)" "$OUT"
printf '%s' "$OUT" | grep -qF "$C" && ok "controle: o stderr completo do git nomeia o commit ausente (a causa que o last-pull-error escondia)" || bad "controle: o stderr não nomeia C" "$OUT"
git init -q --bare "$T/full.git"; git -C "$T/full.git" fetch -q "$S" '+refs/remotes/origin/*:refs/remotes/origin/*' 2>/dev/null
present "$T/full.git" "$SEG" && ok "controle: SEM filtro o blob negado chega (a ausência dele no clone é obra do filtro)" || bad "controle: o blob negado nem existe no espelho da fixture"

# ── recuperação: o pull passa SEM a ref de ponta ausente, e só sem ela ────────────────────────────────────────────────────────────────────────────────────────────
fresh adv; pull
[ "$RC" = 0 ] && ok "pull com ref de ponta ausente: rc 0 (recupera sozinho)" || bad "pull com ref de ponta ausente: rc=$RC" "$OUT"
export SHIM_FETCHLOG=$T/fetchlog; : > "$SHIM_FETCHLOG"; fresh adv; pull fetchlog; unset SHIM_FETCHLOG
[ "$(grep -c . "$T/fetchlog")" = 2 ] && ! grep -q 'refs/gt/repair' "$T/fetchlog" && ok "ref sem par local (buraco sob um have): 2 fetches (o simples e o retry), nenhum reparo por refspec avulso (o reparo é só da ref OBSOLETA)" || bad "ref sem par local: fetches inesperados" "$(cat "$T/fetchlog")"
has 'resultado=ok' "pull: resultado=ok"
[ "$(ref_of refs/remotes/origin/main)" = "$M2" ] && ok "retry: main andou para o commit novo (não ficou velho)" || bad "retry: main não andou" "$(ref_of refs/remotes/origin/main)"
[ "$(ref_of refs/gt/synced)" = "$M2" ] && ok "retry: refs/gt/* também andou (os refspecs da config seguem valendo)" || bad "retry: refs/gt/synced não andou"
[ "$(ref_of refs/remotes/origin/fix/sadia)" = "$E" ] && ok "retry: a ref sadia nova foi buscada (só a de ponta ausente ficou de fora)" || bad "retry: fix/sadia não veio"
[ -z "$(ref_of refs/remotes/origin/fix/quebrado)" ] && ok "retry: a ref de ponta ausente ficou FORA" || bad "retry: fix/quebrado entrou"
[ -z "$(ref_of refs/remotes/origin/fix/velha)" ] && ok "retry: --prune segue valendo (a ref que saiu do espelho foi podada)" || bad "retry: fix/velha não foi podada"
present "$K" "$VIS" && ok "retry: o código novo chegou (blob liberado pelo spec)" || bad "retry: o blob liberado não chegou"
present "$K" "$SEG" && bad "retry: o blob NEGADO pelo spec chegou ao clone (o retry perdeu o filtro de dados)" || ok "retry: o blob negado pelo spec NÃO chegou (o retry leva o MESMO filtro)"

# ── estado visível: degradado não pode parecer limpo ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
has 'AVISO' "retry: o pull diz AVISO"; has 'refs/remotes/origin/fix/quebrado' "retry: o AVISO nomeia a ref que ficou fora"; has 'git fetch --refetch' "retry: o AVISO aponta o reparo"
[ ! -e "$LPE" ] && ok "retry: last-pull-error some (o pull deu certo)" || bad "retry: last-pull-error ficou" "$(cat "$LPE")"
grep -qF "refs/remotes/origin/fix/quebrado $C" "$LPS" 2>/dev/null && [ "$(wc -l < "$LPS" | tr -d ' ')" = 1 ] && ok "retry: last-pull-skipped guarda <ref> <oid> só da ref do escopo do fetch (refs/heads/fora, de ponta ausente também, não conta)" || bad "retry: last-pull-skipped" "$(cat "$LPS" 2>&1)"
OUT=$("$RG" status gascity 2>&1); has 'refs_fora_do_pull=[refs/remotes/origin/fix/quebrado' "status: mostra a ref fora do pull"; has 'último_pull_com_erro=[]' "status: sem erro (o pull passou)"
if [ "$(id -u)" = 0 ]; then ok "status: last-pull-skipped ilegível → '?' (pulado: root lê arquivo de modo 000)"; else chmod 000 "$LPS"; OUT=$("$RG" status gascity 2>&1); chmod 644 "$LPS"; has 'refs_fora_do_pull=[?]' "status: last-pull-skipped existe e é ilegível → '?' (não sei), nunca vazio (= nenhuma)"; fi
tail -n 1 "$T/node/pulls.jsonl" | grep -qF '"pull":"ok"' && ok "pulls.jsonl: o pull degradado conta como ok (main foi atualizado)" || bad "pulls.jsonl" "$(tail -n 1 "$T/node/pulls.jsonl")"
pull; [ "$RC" = 0 ] && ok "segundo pull com o mesmo estado: rc 0 de novo" || bad "segundo pull: rc=$RC" "$OUT"; has 'AVISO' "segundo pull: o AVISO continua enquanto o dano continua"
# ── cura: a ref some do espelho (o que o Mayor fez em ga-6auslu) → pull limpo, sem AVISO, e o estado 'fora' desaparece ────────────────────────────────────────────────────
git -C "$S" update-ref -d refs/remotes/origin/fix/quebrado; pull
[ "$RC" = 0 ] && ok "cura: sem a ref quebrada o pull passa de primeira" || bad "cura: rc=$RC" "$OUT"; hasnt 'AVISO' "cura: sem AVISO"
[ ! -e "$LPS" ] && ok "cura: last-pull-skipped some" || bad "cura: last-pull-skipped ficou" "$(cat "$LPS")"
present "$K" "$SEG" && bad "cura: o blob negado pelo spec chegou no fetch de primeira (o filtro caiu)" || ok "cura: o fetch de primeira também leva o filtro (o blob negado segue fora)"
OUT=$("$RG" status gascity 2>&1); has 'refs_fora_do_pull=[]' "cura: status volta a refs_fora_do_pull=[]"
# a ref tem par local, com valor DIFERENTE do anunciado (e presente): não é obsoleta (o git pediu o objeto e o servidor o omitiu) → também sem reparo, 2 fetches
export SHIM_FETCHLOG=$T/fetchlog; : > "$SHIM_FETCHLOG"; fresh adv; mkdir -p "$K/refs/remotes/origin/fix"; echo "$M" > "$K/refs/remotes/origin/fix/quebrado"; pull fetchlog; unset SHIM_FETCHLOG
[ "$RC" = 0 ] && [ "$(grep -c . "$T/fetchlog")" = 2 ] && ! grep -q 'refs/gt/repair' "$T/fetchlog" && ok "ref com par local de valor DIFERENTE: 2 fetches e nenhum reparo (só a igualdade com o anunciado faz a ref obsoleta)" || bad "ref com par local diferente: rc=$RC, fetches inesperados" "$(cat "$T/fetchlog")"

# ── falha sem contorno: o stderr INTEIRO fica guardado, a 1ª linha segue sendo o resumo de sempre ──────────────────────────────────────────────────────────────────────
fresh adv; pull lsfail
[ "$RC" = 1 ] && ok "sem contorno: rc 1" || bad "sem contorno: rc=$RC" "$OUT"; has 'resultado=erro' "sem contorno: resultado=erro"
[ "$(wc -l < "$LPE" | tr -d ' ')" -ge 3 ] && ok "last-pull-error: tem o stderr inteiro (3+ linhas), não só a última" || bad "last-pull-error: poucas linhas" "$(cat "$LPE")"
grep -qF "$C" "$LPE" && ok "last-pull-error: nomeia o commit ausente (a causa)" || bad "last-pull-error: sem o oid de C" "$(cat "$LPE")"
[ "$(head -n 1 "$LPE" | cut -d' ' -f2- | grep -c 'did not send all necessary objects')" = 1 ] && ok "last-pull-error: a 1ª linha segue sendo <epoch> <última linha do git> (formato antigo)" || bad "last-pull-error: 1ª linha" "$(head -n 1 "$LPE")"
OUT=$("$RG" status gascity 2>&1); [ "$(printf '%s\n' "$OUT" | grep -c 'último_pull_com_erro=')" = 1 ] && hasnt 'Could not read' "status: só a 1ª linha do last-pull-error (o corpo não vaza para a linha de status)" || bad "status: linha de erro" "$OUT"
fresh adv; pull lsfail; [ "$(printf '%s\n' "$OUT" | grep -c 'resultado=erro')" = 1 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && ok "pull: a linha de resultado segue UMA linha só (o corpo do erro não entra nela)" || bad "pull: linha de resultado" "$OUT"
fresh adv; pull retryfail
[ "$RC" = 1 ] && ok "retry que também falha: rc 1" || bad "retry que falha: rc=$RC" "$OUT"
grep -qF -- '--- tentativa 2' "$LPE" && grep -qF 'boom no retry' "$LPE" && grep -qF "$C" "$LPE" && ok "retry que falha: last-pull-error guarda as DUAS tentativas" || bad "retry que falha: last-pull-error" "$(cat "$LPE")"
[ "$(head -n 1 "$LPE" | cut -d' ' -f2-)" = "error: boom no retry (de propósito)" ] && ok "retry que falha: o resumo é a última linha do git da última tentativa" || bad "retry que falha: resumo" "$(head -n 1 "$LPE")"
[ "$(ref_of refs/remotes/origin/main)" = "$M" ] && [ ! -e "$LPS" ] && ok "retry que falha: nada andou e nada foi gravado como 'fora'" || bad "retry que falha: estado"
fresh boot; pull flood
[ "$(wc -l < "$LPE" | tr -d ' ')" -le 202 ] && grep -qF 'linhas omitidas' "$LPE" && ok "last-pull-error: o corpo tem teto (200 linhas) e diz quantas omitiu" || bad "last-pull-error: teto" "$(wc -l < "$LPE") linhas"
sed -n '2p' "$LPE" | grep -qF 'ruido 0' && ok "last-pull-error: o teto guarda o COMEÇO do stderr (onde está a causa)" || bad "last-pull-error: começo" "$(sed -n '1,3p' "$LPE")"

# ── recusas: sem certeza, NÃO contorna (a ref segue falhando, alto) ───────────────────────────────────────────────────────────────────────────────────────────────────
refuse() {   # <desc> <espelho> <modo do shim | -> <trecho do motivo> [preparo]: o pull falha, nada anda, o motivo está na 1ª linha do last-pull-error e nada é gravado como 'fora'
  fresh "$2"; eval "${5:-:}"; pull "$3"
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF 'resultado=erro' && ok "$1: o pull falha (rc 1, resultado=erro)" || bad "$1: rc=$RC" "$OUT"
  head -n 1 "$LPE" | grep -qF -- "$4" && ok "$1: o motivo está na 1ª linha do last-pull-error" || bad "$1: motivo ausente (queria: $4)" "$(cat "$LPE" 2>&1)"
  [ "$(ref_of refs/remotes/origin/main)" = "$M" ] && [ ! -e "$LPS" ] && ok "$1: nenhuma ref andou e nada foi gravado como 'fora'" || bad "$1: estado mudou"
}
refuse "ls-remote falha" adv lsfail "retry não feito: não consegui listar as refs do espelho"
refuse "ls-remote vazio (não é 'nada falta')" adv lsempty "retry não feito: não consegui listar as refs do espelho"
refuse "listagem de objetos falha" adv objfail "retry não feito: não consegui listar os objetos do clone"
refuse "listagem de objetos vazia (não é 'tudo falta')" adv objempty "retry não feito: não consegui listar os objetos do clone"
refuse "clone sem refspec de fetch (o fetch busca só o HEAD do espelho, que aponta para a ponta ausente)" adv - "retry não feito: o clone não tem refspec de fetch" 'git -C "$K" config --unset-all remote.origin.fetch; git -C "$S" symbolic-ref HEAD refs/remotes/origin/fix/quebrado'
refuse "sem diretório de trabalho (mktemp -d falha depois do fetch)" adv mktempfail "retry não feito: sem tmp"
refuse "nenhuma ponta anunciada falta (o fetch falhou por outra coisa)" boot fetchfake "retry não feito: nenhuma ponta anunciada falta neste clone"
fresh adv; git -C "$S" update-ref refs/remotes/origin/main "$C"; cp -a "$S" "$T/srv.mainc.git"
refuse "a ponta de main é a que falta" mainc - "retry não feito: a ponta de refs/remotes/origin/main"
fresh adv; git -C "$S" update-ref refs/gt/synced "$C"; cp -a "$S" "$T/srv.syncc.git"
refuse "a ponta de refs/gt/synced é a que falta" syncc - "retry não feito: a ponta de refs/remotes/origin/main ou de refs/gt/synced"
mk() { fresh adv; git -C "$S" update-ref -d refs/remotes/origin/fix/quebrado; i=1; while [ $i -le "$1" ]; do echo "create refs/remotes/origin/fix/q$i $C"; i=$((i+1)); done | git -C "$S" update-ref --stdin; cp -a "$S" "$T/srv.q$1.git"; }
mk 21; refuse "21 refs de ponta ausente (acima do teto de 20)" q21 - "retry não feito: 21 refs com ponta ausente (teto 20)"
mk 20; fresh q20; pull
[ "$RC" = 0 ] && ok "20 refs de ponta ausente (no teto): ainda contorna" || bad "20 refs: rc=$RC" "$OUT"; has '20 ref(s)' "20 refs: o AVISO conta as 20"
[ "$(wc -l < "$LPS" 2>/dev/null | tr -d ' ')" = 20 ] && ok "20 refs: last-pull-skipped lista as 20" || bad "20 refs: last-pull-skipped" "$(cat "$LPS" 2>&1 | head -n 3)"
fresh adv; mkdir "$LPS"; pull   # o arquivo de estado não pode ser gravado (é uma pasta): o pull passou do mesmo jeito, e o AVISO diz que o estado não foi guardado
[ "$RC" = 0 ] && has 'não consegui gravar' "estado não gravável: o pull passa (main andou) e o AVISO diz que não guardou o last-pull-skipped" || bad "estado não gravável: rc=$RC" "$OUT"

# ── ref obsoleta (ga-eivvcus): a ponta falta no clone E o clone tem a MESMA ref com o MESMO valor ─────────────────────────────────────────────────────────────────────────
# O git dá essa ref por "up to date" e nunca pede o objeto: o pack vem sem a ponta e a checagem de conectividade morre em "did not send all necessary objects" (medido numa cópia do clone do nó: o pull ficou 14 h parado, com
# refs/gt/synced entre as 4 pontas ausentes). Não é o buraco do ga-yo1n1zg (ancestral de uma ponta presente, que o servidor omite mesmo pedido). O reparo busca a ponta (uma FOLHA: nenhum commit presente a tem por filho) por refspec avulso, com o MESMO filtro.
echo l > "$W/lib/l.txt"; echo 'SEGREDO-l' > "$W/data/x2"; L=$(cm L); LVIS=$(git -C "$W" rev-parse "$L:lib/l.txt"); LSEG=$(git -C "$W" rev-parse "$L:data/x2"); L2=$(git -C "$W" commit-tree "$L^{tree}" -p "$E" -m L2)
mksrv() {   # <nome> <ref>...: o espelho "adv" (sem as refs de ponta C) com estas refs na folha L, mais uma folha irmã L2 em fix/folha2 se a ref for essa
  local n=$1 r; shift; rm -rf "$T/srv.$n.git"; cp -a "$T/srv.adv.git" "$T/srv.$n.git"; git -C "$T/srv.$n.git" update-ref -d refs/remotes/origin/fix/quebrado; git -C "$T/srv.$n.git" update-ref -d refs/heads/fora
  for r in "$@"; do case $r in */folha2) git -C "$W" push -q -f "$T/srv.$n.git" "$L2:$r" ;; *) git -C "$W" push -q -f "$T/srv.$n.git" "$L:$r" ;; esac; done
}
stale_in() { local r; for r in "$@"; do mkdir -p "$(dirname "$K/$r")"; case $r in */folha2) echo "$L2" > "$K/$r" ;; *) echo "$L" > "$K/$r" ;; esac; done; }   # o clone já tem as MESMAS refs com o MESMO valor, escritas à mão (o objeto nunca chegou nele)
mkstale() { local n=$1; shift; mksrv "$n" "$@"; fresh "$n"; stale_in "$@"; }
mkstale folha refs/remotes/origin/fix/folha
[ "$(ref_of refs/remotes/origin/fix/folha)" = "$L" ] && ! present "$K" "$L" && ok "controle (obsoleta): o clone tem fix/folha em L e L não está nele" || bad "controle (obsoleta): estado do clone" "$(ref_of refs/remotes/origin/fix/folha)"
OUT=$(git -C "$K" fetch -q --prune "--filter=sparse:oid=$(OIDF)" origin 2>&1); R=$?
[ "$R" != 0 ] && printf '%s' "$OUT" | grep -qF 'did not send all necessary objects' && ok "controle (obsoleta): o fetch simples do pull antigo morre em 'did not send all necessary objects' (a ref 'up to date' não pede o objeto)" || bad "controle (obsoleta): este git NÃO reproduz a falha (rc=$R)" "$OUT"
printf '%s' "$OUT" | grep -qF "$L" && ok "controle (obsoleta): o stderr do git nomeia a ponta ausente" || bad "controle (obsoleta): o stderr não nomeia L" "$OUT"
mkstale folha refs/remotes/origin/fix/folha; pull
[ "$RC" = 0 ] && has 'resultado=ok' "obsoleta (ref lateral): o pull passa (rc 0, resultado=ok)" || bad "obsoleta: rc=$RC" "$OUT"
has 'REPARO' "obsoleta: o pull diz REPARO"; has 'refs/remotes/origin/fix/folha' "obsoleta: o REPARO nomeia a ref"; has '1 ref(s) estavam obsoletas' "obsoleta: ...e conta uma"; hasnt 'AVISO' "obsoleta: nada ficou de fora (sem AVISO)"
[ "$(ref_of refs/remotes/origin/fix/folha)" = "$L" ] && present "$K" "$L" && ok "obsoleta: a ponta chegou ao clone (a ref ficou onde estava, agora com objeto)" || bad "obsoleta: a ponta não chegou" "$(ref_of refs/remotes/origin/fix/folha)"
[ "$(ref_of refs/remotes/origin/main)" = "$M2" ] && [ "$(ref_of refs/gt/synced)" = "$M2" ] && ok "obsoleta: main e refs/gt/synced andaram no mesmo pull" || bad "obsoleta: main/synced não andaram"
present "$K" "$LVIS" && ok "obsoleta: o blob liberado pelo spec chegou junto" || bad "obsoleta: o blob liberado não chegou"
present "$K" "$LSEG" && bad "obsoleta: o blob NEGADO pelo spec chegou ao clone (o reparo perdeu o filtro de dados)" || ok "obsoleta: o blob negado pelo spec NÃO chegou (o reparo leva o MESMO filtro)"
[ -z "$(ref_of refs/gt/repair/1)" ] && ! grep -q 'refs/gt/repair' "$K/packed-refs" 2> /dev/null && [ -z "$(find "$K/refs/gt/repair" -type f 2> /dev/null)" ] && ok "obsoleta: a ref avulsa do reparo não fica no clone" || bad "obsoleta: refs/gt/repair ficou" "$(find "$K/refs/gt/repair" -type f 2>&1)"
[ ! -e "$LPE" ] && [ ! -e "$LPS" ] && ok "obsoleta: sem last-pull-error e sem last-pull-skipped" || bad "obsoleta: estado de erro/fora ficou"
tail -n 1 "$T/node/pulls.jsonl" | grep -qF '"pull":"ok"' && ok "obsoleta: pulls.jsonl conta o pull como ok" || bad "obsoleta: pulls.jsonl" "$(tail -n 1 "$T/node/pulls.jsonl")"
pull; [ "$RC" = 0 ] && hasnt 'REPARO' "obsoleta: o pull seguinte já sai limpo (sem REPARO)" || bad "obsoleta: segundo pull rc=$RC" "$OUT"; hasnt 'AVISO' "obsoleta: ...e sem AVISO"
# refs/gt/synced obsoleta: no HEAD antigo era recusa certa (a recusa de main/synced), e era o caso do nó
mkstale sync refs/gt/synced; export SHIM_FETCHLOG=$T/fetchlog; : > "$SHIM_FETCHLOG"; pull fetchlog; unset SHIM_FETCHLOG
[ "$RC" = 0 ] && has 'resultado=ok' "synced obsoleta: o pull passa (no HEAD antigo a recusa de refs/gt/synced o derrubava)" || bad "synced obsoleta: rc=$RC" "$OUT"
has 'REPARO' "synced obsoleta: o pull diz REPARO"; has 'refs/gt/synced' "synced obsoleta: o REPARO nomeia a ref"
[ "$(ref_of refs/gt/synced)" = "$L" ] && present "$K" "$L" && [ "$(ref_of refs/remotes/origin/main)" = "$M2" ] && ok "synced obsoleta: synced tem o objeto e main andou" || bad "synced obsoleta: estado" "$(ref_of refs/gt/synced) $(ref_of refs/remotes/origin/main)"
present "$K" "$LSEG" && bad "synced obsoleta: o blob negado chegou" || ok "synced obsoleta: o blob negado pelo spec segue fora"
[ "$(grep -c . "$T/fetchlog")" = 3 ] && [ "$(grep -c 'refs/gt/repair/1' "$T/fetchlog")" = 1 ] && ok "synced obsoleta: 3 fetches (o simples, a sonda da ponta, o final)" || bad "synced obsoleta: contagem de fetches" "$(cat "$T/fetchlog")"
[ "$(grep -c -- "--filter=sparse:oid=$(OIDF)" "$T/fetchlog")" = 3 ] && ok "synced obsoleta: TODO fetch leva o filtro vigente na linha de comando, a sonda inclusive (nada de dado a mais no clone)" || bad "synced obsoleta: fetch sem o filtro vigente" "$(cat "$T/fetchlog")"
# main obsoleta com ponta ENTREGÁVEL (folha): o reparo traz, e o main não fica de fora
mkstale main refs/remotes/origin/main; pull
[ "$RC" = 0 ] && has 'resultado=ok' "main obsoleta (folha): o pull passa" || bad "main obsoleta: rc=$RC" "$OUT"
has 'REPARO' "main obsoleta: o pull diz REPARO"; [ "$(ref_of refs/remotes/origin/main)" = "$L" ] && present "$K" "$L" && ok "main obsoleta: main tem o objeto" || bad "main obsoleta: estado" "$(ref_of refs/remotes/origin/main)"
# main obsoleta com ponta que o servidor NÃO entrega (C: ancestral de M, que o clone tem; o servidor a omite mesmo pedida): continua erro ALTO, nada anda, e o reparo ficou registrado
fresh mainc; mkdir -p "$K/refs/remotes/origin"; echo "$C" > "$K/refs/remotes/origin/main"; pull
[ "$RC" = 1 ] && has 'resultado=erro' "main obsoleta SEM entrega: o pull FALHA (rc 1, resultado=erro): a recusa de main segue de pé" || bad "main obsoleta sem entrega: rc=$RC" "$OUT"
head -n 1 "$LPE" | grep -qF 'retry não feito: a ponta de refs/remotes/origin/main ou de refs/gt/synced falta' && ok "main obsoleta sem entrega: o motivo está na 1ª linha do last-pull-error" || bad "main obsoleta sem entrega: motivo" "$(head -n 2 "$LPE" 2>&1)"
grep -qF -- '--- reparo' "$LPE" && ok "main obsoleta sem entrega: o last-pull-error registra que o reparo foi tentado" || bad "main obsoleta sem entrega: sem a marca do reparo" "$(head -n 4 "$LPE")"
[ "$(ref_of refs/remotes/origin/main)" = "$C" ] && [ "$(ref_of refs/gt/synced)" = "$M" ] && [ ! -e "$LPS" ] && ok "main obsoleta sem entrega: nada andou e nada foi gravado como 'fora'" || bad "main obsoleta sem entrega: estado mudou"
[ -z "$(find "$K/refs/gt/repair" -type f 2> /dev/null)" ] && ok "main obsoleta sem entrega: a ref avulsa do reparo também não fica" || bad "main obsoleta sem entrega: refs/gt/repair ficou"
# reparo PARCIAL: a folha chega, a ponta C não (hole sob uma ponta presente); sobra o contorno de sempre só para C, e o que chegou fica
mksrv parc refs/remotes/origin/fix/folha; git -C "$T/srv.parc.git" update-ref refs/remotes/origin/fix/quebrado "$C"; fresh parc; stale_in refs/remotes/origin/fix/folha; mkdir -p "$K/refs/remotes/origin/fix"; echo "$C" > "$K/refs/remotes/origin/fix/quebrado"; pull
[ "$RC" = 0 ] && has 'resultado=ok' "reparo parcial: o pull passa" || bad "reparo parcial: rc=$RC" "$OUT"
has 'AVISO' "reparo parcial: a ref que o servidor não entrega vira AVISO (o contorno de sempre)"; has 'refs/remotes/origin/fix/quebrado' "reparo parcial: ...e o AVISO a nomeia"; hasnt 'REPARO' "reparo parcial: sem REPARO (o reparo sozinho não resolveu)"
[ "$(ref_of refs/remotes/origin/fix/folha)" = "$L" ] && present "$K" "$L" && ok "reparo parcial: a folha que chegou ficou no clone" || bad "reparo parcial: a folha não chegou" "$(ref_of refs/remotes/origin/fix/folha)"
grep -qF "refs/remotes/origin/fix/quebrado $C" "$LPS" 2> /dev/null && [ "$(wc -l < "$LPS" | tr -d ' ')" = 1 ] && ok "reparo parcial: last-pull-skipped lista só a que não chegou" || bad "reparo parcial: last-pull-skipped" "$(cat "$LPS" 2>&1)"
# 25 refs obsoletas na MESMA ponta: o objeto é pedido uma vez (1 refspec avulso; o shim derruba o fetch que traga um 2º), e o teto de 20 do contorno não vale para o reparo
refs25=""; i=1; while [ $i -le 25 ]; do refs25="$refs25 refs/remotes/origin/fix/s$i"; i=$((i+1)); done
mkstale mil $refs25; pull dedupe
[ "$RC" = 0 ] && has 'resultado=ok' "25 obsoletas na mesma ponta: o pull passa (um refspec só)" || bad "25 obsoletas: rc=$RC" "$OUT"
has '25 ref(s) estavam obsoletas' "25 obsoletas: o REPARO conta as 25"; present "$K" "$L" && ok "25 obsoletas: a ponta chegou" || bad "25 obsoletas: a ponta não chegou"
# duas pontas DISTINTAS: as duas são pedidas
mkstale duas refs/remotes/origin/fix/folha refs/remotes/origin/fix/folha2; pull
[ "$RC" = 0 ] && has '2 ref(s) estavam obsoletas' "duas pontas obsoletas distintas: o pull passa e o REPARO conta as 2" || bad "duas obsoletas: rc=$RC" "$OUT"
present "$K" "$L" && present "$K" "$L2" && ok "duas pontas obsoletas distintas: as duas chegaram" || bad "duas obsoletas: faltou ponta"
# clone SEM o refspec de refs/gt/*: o --prune do fetch final não varre refs/gt/repair, então a ref avulsa só some se o próprio reparo a apaga
mkstale folha refs/remotes/origin/fix/folha; git -C "$K" config --unset-all remote.origin.fetch; git -C "$K" config --add remote.origin.fetch '+refs/remotes/origin/*:refs/remotes/origin/*'; pull
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF 'REPARO' && present "$K" "$L" && [ -z "$(find "$K/refs/gt/repair" -type f 2> /dev/null)" ] && ! grep -q 'refs/gt/repair' "$K/packed-refs" 2> /dev/null && ok "obsoleta sem refspec de refs/gt/*: o reparo passa e a ref avulsa não fica (só o próprio reparo a apaga)" || bad "obsoleta sem refspec de refs/gt/*: rc=$RC" "$OUT $(find "$K/refs/gt/repair" -type f 2>&1)"
# gc seguro: o gc padrão do git 2.43 num clone parcial(cruft + bitmap) perdeu um commit local e morreu numa cópia do clone do nó. O bootstrap (que faz o 1º pull) e todo pull gravam gc.cruftPacks=false e repack.writeBitmaps=false
fresh boot; [ "$(git -C "$K" config gc.cruftPacks)" = false ] && [ "$(git -C "$K" config repack.writeBitmaps)" = false ] && ok "gc seguro: o clone do bootstrap nasce com gc.cruftPacks=false e repack.writeBitmaps=false" || bad "gc seguro: o bootstrap não gravou a config do gc" "$(git -C "$K" config --get-regexp 'gc|repack')"
fresh adv; git -C "$K" config --unset gc.cruftPacks; git -C "$K" config --unset repack.writeBitmaps; git -C "$K" config gc.cruftPacks true; pull
[ "$RC" = 0 ] && [ "$(git -C "$K" config gc.cruftPacks)" = false ] && [ "$(git -C "$K" config repack.writeBitmaps)" = false ] && ok "gc seguro: um pull conserta o clone que já existia (cruft ligado, bitmap sem config)" || bad "gc seguro: o pull não consertou a config do gc" "rc=$RC $(git -C "$K" config --get-regexp 'gc|repack')"
fresh adv; pull cfgfail
[ "$RC" = 0 ] && has 'resultado=ok' "gc seguro: não gravar a config não derruba o pull" || bad "gc seguro: pull com a gravação falhando rc=$RC" "$OUT"
has 'AVISO: não gravei gc.cruftPacks=false' "gc seguro: ...mas o pull DIZ que o clone ficou sem a config do gc"
# o resumo do last-pull-error não é o eco do gc.log: com um gc.log velho no clone o git termina TODO fetch repetindo o conteúdo dele, e a causa sumia da 1ª linha (texto medido no git 2.43 do nó)
fresh boot; pull fetchnoise
head -n 1 "$LPE" | cut -d' ' -f2- | grep -qF 'did not send all necessary objects' && ok "resumo: o eco do gc.log não vira a 1ª linha do last-pull-error (a causa do git continua nela)" || bad "resumo: 1ª linha" "$(head -n 1 "$LPE")"
grep -qF 'The last gc run reported the following' "$LPE" && grep -qF 'failed to run repack' "$LPE" && ok "resumo: o eco do gc.log segue guardado no corpo do last-pull-error" || bad "resumo: o corpo perdeu o eco" "$(cat "$LPE")"
OUT=$("$RG" status gascity 2>&1); has 'último_pull_com_erro=[error: ssh://x/y.git did not send all necessary objects' "resumo: o status mostra a causa, não o eco do gc"
fresh boot; pull noiseonly
head -n 1 "$LPE" | cut -d' ' -f2- | grep -qxF 'fatal: failed to run repack' && ok "resumo: stderr só com o eco do gc: cai na última linha (nunca um resumo vazio)" || bad "resumo: só eco" "$(head -n 1 "$LPE")"

# ── falha que não é essa: sem a frase do git não há segunda tentativa ─────────────────────────────────────────────────────────────────────────────────────────────────
fresh adv; OUT=$(env FAKE_SSH_FAIL=upload-pack "$RG" pull gascity 2>&1); RC=$?
[ "$RC" = 1 ] && has 'resultado=erro' "outra falha do fetch (rede): o pull falha como sempre"
grep -qF 'Connection refused' "$LPE" && ok "outra falha: o stderr dela fica no last-pull-error" || bad "outra falha: stderr" "$(cat "$LPE" 2>&1)"
grep -qF 'retry' "$LPE" && bad "outra falha: tentou contornar o que não era a falha esperada" "$(cat "$LPE")" || ok "outra falha: sem segunda tentativa nem nota de retry"
fresh adv; OUT=$(env FAKE_SSH_FAIL=spec "$RG" pull gascity 2>&1); RC=$?   # falha ANTES do fetch (o espelho não devolve o filtro): as variáveis do retry nunca foram setadas e o pull tem de falhar limpo, não morrer em 'unbound variable'
[ "$RC" = 1 ] && has 'resultado=erro' "espelho sem filtro (antes do fetch): o pull falha limpo (rc 1, resultado=erro)"; hasnt 'unbound' "espelho sem filtro: nenhuma variável do retry fica sem valor (set -u)"
grep -qF 'spec indisponível' "$LPE" && ok "espelho sem filtro: o stderr do ssh fica no last-pull-error" || bad "espelho sem filtro: stderr" "$(cat "$LPE" 2>&1)"

# ── lastro hq-mutants (ga-0qhveri): o que as seções acima não pisam — o filtro que MUDA, o bootstrap, a idade (lag), status, wt-add/wt-rm e scan ──────────────────────────────────────
# Cada caso abaixo mata uma troca de `&&`/`||`/`-n`/`!`/limite que deixava o selftest verde. EQUIVALENTES (provados por leitura, sem caso): o `|| true` -> `&& true` das duas leituras `rev-parse -q --verify` do status e o do `old=$(g config gtremote.sparseoid || true)` do pull
# (sem `set -e` o rc de uma atribuição por $( ) nunca é lido; a saída do $( ) é a mesma) e o `return 0` -> `return 1` do lag_fields (os três chamadores o chamam com `;`, e sem `set -e` o status nunca é lido).
# O id leva a linha: quando se insere linha acima (ga-kzwlkhh, ga-eivvcus) a declaração envelhece e o mutante volta à lista com id novo. ga-9twwdmk trocou os ids abaixo (211be6fe01 era c5c184d44d, 70e8d9bd68 era fe123d753c, 9c05845b12 e a81c597348 eram
# 6a099af2c5 e 5572d3e5d6) depois de provar com o candidates() do motor, no commit anterior ao ga-kzwlkhh, que são o mesmo token na mesma linha de código.
# O `|| return 2` do `mktemp -d` de denied e o `&&` entre o `tr` e a conferência de contagem do `find` do scan estavam declarados equivalentes aqui; NÃO são (a razão só olhava o ramo «o find falha»): os casos do fim do arquivo (ga-9twwdmk) os matam.
# EQUIVALENT 9c05845b12 a81c597348: o `|| true` -> `&& true` das duas leituras `rev-parse -q --verify` do status: sem `set -e` o rc de uma atribuicao por $( ) nunca e lido
# EQUIVALENT 211be6fe01: o `return 0` -> `return 1` do lag_fields: os tres chamadores (pull, wt-add, status) o chamam com `;` e nenhum le o $? depois (o script so tem `set -u`: sem `set -e` e sem trap ERR, o status solto nao derruba nada)
# EQUIVALENT 70e8d9bd68: o `|| true` -> `&& true` do `old=$(g config gtremote.sparseoid || true)` do pull: a saida do $( ) e a mesma (o `true` nao imprime) e o status da atribuicao nunca e lido (so ha `set -u`: sem `set -e` e sem trap ERR, e o comando seguinte nao olha o $?)
mkdir -p "$T/shim2" "$T/home"; export REAL_DATE; REAL_DATE=$(command -v date)
printf '%s\n' '#!/bin/sh' '[ -n "${FAKE_NOW:-}" ] && [ "${1:-}" = +%s ] && { echo "$FAKE_NOW"; exit 0; }' 'exec "$REAL_DATE" "$@"' > "$T/shim2/date"   # FAKE_NOW fixa o `date +%s` do script: a idade sai exata
printf '%s\n' '#!/bin/sh' 'case "${SHIM2_MODE:-}:${1:-}" in' '  mktempfail:-d) echo "shim: mktemp -d falhou (de proposito)" >&2; exit 1 ;;' \
  '  mktemp2fail:-d) n=$(cat "$SHIM2_CNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$SHIM2_CNT"; [ "$n" -lt 2 ] || { echo "shim: mktemp -d falhou da 2a vez em diante (de proposito)" >&2; exit 1; } ;;' \
  'esac' 'exec "$REAL_MKTEMP" "$@"' > "$T/shim2/mktemp"
printf '%s\n' '#!/bin/sh' 'case "${SHIM2_MODE:-}:$*" in' \
  '  flood201:*" fetch "*|flood200:*" fetch "*) i=0; max=200; [ "$SHIM2_MODE" = flood200 ] && max=199; while [ $i -lt $max ]; do echo "error: ruido $i" >&2; i=$((i+1)); done; echo "error: ssh://x/y.git did not send all necessary objects" >&2; exit 1 ;;' \
  '  rmlies:*" worktree remove "*|rmlies:*" worktree prune") exit 0 ;;' \
  'esac' 'exec "$REAL_GIT" "$@"' > "$T/shim2/git"
chmod 755 "$T/shim2/date" "$T/shim2/mktemp" "$T/shim2/git"

# o filtro do espelho MUDA entre dois pulls: sparse, deny, o oid guardado e o partialclonefilter acompanham, e o AVISO diz de qual para qual
{ cat "$FAKE_SPEC"; echo '!/data/extra'; } > "$T/spec2"; NEWOID=$(git hash-object "$T/spec2")
fresh adv; git -C "$S" hash-object -w --stdin < "$T/spec2" > /dev/null; OLDOID=$(OIDF)
OUT=$(env FAKE_SPEC="$T/spec2" "$RG" pull gascity 2>&1); RC=$?
[ "$RC" = 0 ] && ok "filtro que muda: o pull passa" || bad "filtro que muda: rc=$RC" "$OUT"
has "o filtro do espelho mudou ($OLDOID" "filtro que muda: o AVISO diz de qual oid saiu"; has "$NEWOID); rode scan" "filtro que muda: ...e para qual foi"
[ "$(OIDF)" = "$NEWOID" ] && [ "$(git -C "$K" config remote.origin.partialclonefilter)" = "sparse:oid=$NEWOID" ] && ok "filtro que muda: o oid guardado e o partialclonefilter acompanham" || bad "filtro que muda: oid/partialclonefilter" "$(OIDF) $(git -C "$K" config remote.origin.partialclonefilter)"
cmp -s "$T/spec2" "$T/node/gascity/sparse" && ok "filtro que muda: o sparse é o spec novo" || bad "filtro que muda: sparse"
[ "$(grep -c . "$T/node/gascity/deny")" = 25 ] && grep -qx '/data/extra' "$T/node/gascity/deny" && ok "filtro que muda: o deny é o spec novo sem a 1ª linha e sem o '!' (25 linhas)" || bad "filtro que muda: deny" "$(wc -l < "$T/node/gascity/deny") linhas"
# uma resposta que não é um filtro: 24 negações mas a 1ª linha não é '/*'
{ echo '/lib'; for i in $(seq 1 24); do echo "!/data/y$i"; done; } > "$T/spec.bad"
fresh adv; OUT=$(env FAKE_SPEC="$T/spec.bad" "$RG" pull gascity 2>&1); RC=$?
[ "$RC" = 1 ] && has 'resultado=erro' "spec que não abre com '/*' (mesmo com 24 negações): o pull falha" || bad "spec sem '/*': rc=$RC" "$OUT"
cmp -s "$FAKE_SPEC" "$T/node/gascity/sparse" && ok "spec sem '/*': o filtro gravado não mudou" || bad "spec sem '/*': o sparse mudou"
# o corpo do last-pull-error tem teto de 200 linhas: com 201 a última é contada, com 200 nada é omitido
fresh boot; OUT=$(env PATH="$T/shim2:$PATH" SHIM2_MODE=flood201 "$RG" pull gascity 2>&1); RC=$?
grep -qF '1 linhas omitidas)' "$LPE" && ok "last-pull-error: 201 linhas de stderr: a 201ª é contada como omitida" || bad "last-pull-error: 201 linhas" "$(tail -n 2 "$LPE")"
fresh boot; OUT=$(env PATH="$T/shim2:$PATH" SHIM2_MODE=flood200 "$RG" pull gascity 2>&1); RC=$?
grep -qF 'omitidas)' "$LPE" && bad "last-pull-error: 200 linhas cabem no teto, nada é omitido" "$(tail -n 2 "$LPE")" || ok "last-pull-error: 200 linhas cabem no teto, nada é omitido"
# a listagem de objetos do clone falha: o pull diz que NÃO refez o fetch, e de fato não refez (a marca da 2a tentativa não está no last-pull-error)
fresh adv; pull objfail; grep -qF -- '--- tentativa 2' "$LPE" && bad "listagem de objetos falha: houve uma 2a tentativa" "$(grep -c . "$LPE") linhas" || ok "listagem de objetos falha: nenhuma 2a tentativa foi feita"
fresh adv; pull objempty; grep -qF -- '--- tentativa 2' "$LPE" && bad "listagem de objetos vazia: houve uma 2a tentativa" "$(grep -c . "$LPE") linhas" || ok "listagem de objetos vazia: nenhuma 2a tentativa foi feita"

# bootstrap: quatro argumentos bastam, o que o regex recusa, o que não dá para ler, e o ssh que fica gravado
GRB=$T/nodeb; URLB=ssh://u@127.0.0.1:2293/gascity.git; fresh adv
bs() { rm -rf "$GRB"; OUT=$(env GT_REMOTE_GIT="$GRB" "$@" 2>&1); RC=$?; }
bs "$RG" bootstrap rigb "$URLB" "$T/key" "$T/kh"
[ "$RC" = 0 ] && has 'bootstrap rig=rigb' "bootstrap com 4 argumentos (nenhum prefixo): passa" || bad "bootstrap com 4 argumentos: rc=$RC" "$OUT"
[ "$(git -C "$GRB/rigb/repo.git" config --get-all remote.origin.push | wc -l | tr -d ' ')" = 2 ] && ok "bootstrap sem prefixo: empurra só crew/ e worker/" || bad "bootstrap sem prefixo: remote.origin.push" "$(git -C "$GRB/rigb/repo.git" config --get-all remote.origin.push)"
SSHC=$(git -C "$GRB/rigb/repo.git" config gtremote.ssh); printf '%s' "$SSHC" | grep -qF 'ControlMaster=no' && ! printf '%s' "$SSHC" | grep -qF 'ControlMaster=auto' && ok "GT_REMOTE_NOMUX=1: o ssh gravado não usa ControlMaster" || bad "NOMUX: ssh gravado" "$SSHC"
bs env -u GT_REMOTE_NOMUX "$RG" bootstrap rigb "$URLB" "$T/key" "$T/kh"
SSHC=$(git -C "$GRB/rigb/repo.git" config gtremote.ssh); printf '%s' "$SSHC" | grep -qF 'ControlMaster=auto' && printf '%s' "$SSHC" | grep -qF "ControlPath=$GRB/.cm-" && ! printf '%s' "$SSHC" | grep -qF 'ControlMaster=no' && ok "sem GT_REMOTE_NOMUX: o ssh gravado multiplexa (ControlMaster=auto, ControlPath no clone)" || bad "sem NOMUX: ssh gravado" "$SSHC"
bs "$RG" bootstrap Rig "$URLB" "$T/key" "$T/kh"
[ "$RC" = 2 ] && has 'caractere que recuso' "bootstrap: rig com maiúscula é recusado (rc 2)" || bad "bootstrap rig ruim: rc=$RC" "$OUT"
[ ! -e "$GRB/Rig" ] && ok "bootstrap: ...e nada foi criado" || bad "bootstrap rig ruim: criou $GRB/Rig"
bs "$RG" bootstrap rigb "$URLB" "$T/k y" "$T/kh"
[ "$RC" = 2 ] && has 'caractere que recuso' "bootstrap: chave com espaço é recusada (rc 2, não 3)" || bad "bootstrap chave ruim: rc=$RC" "$OUT"
bs "$RG" bootstrap rigb "$URLB" "$T/key" "$T/k h"
[ "$RC" = 2 ] && has 'caractere que recuso' "bootstrap: known_hosts com espaço é recusado (rc 2, não 3)" || bad "bootstrap known_hosts ruim: rc=$RC" "$OUT"
bs "$RG" bootstrap rigb "$URLB" "$T/sem-chave" "$T/kh"
[ "$RC" = 3 ] && has 'chave ou known_hosts il' "bootstrap: chave que não existe → rc 3" || bad "bootstrap sem chave: rc=$RC" "$OUT"
bs "$RG" bootstrap rigb "$URLB" "$T/key" "$T/sem-kh"
[ "$RC" = 3 ] && has 'chave ou known_hosts il' "bootstrap: known_hosts que não existe → rc 3" || bad "bootstrap sem known_hosts: rc=$RC" "$OUT"

# idade (lag) e status: um nó pequeno só de refs, com datas de commit conhecidas e o `date +%s` do script fixo em 1700010800
N2=$T/node2; G2=$N2/rg2/repo.git; mkdir -p "$N2/lixo"; git init -q --bare "$G2"; ET=4b825dc642cb6eb9a060e54bf8d69288fbee4904
mkc() { GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" git -C "$G2" commit-tree "$ET" ${3:+-p "$3"} -m "$1"; }
st() { OUT=$(env PATH="$T/shim2:$PATH" GT_REMOTE_GIT="$N2" FAKE_NOW=1700010800 "$RG" status "$@" 2>&1); RC=$?; }
P0=$(mkc p0 1699980000); S0=$(mkc base 1699990000 "$P0"); Q=$(mkc synced 1700000000 "$S0")
git -C "$G2" update-ref refs/remotes/origin/main "$S0"; git -C "$G2" update-ref refs/gt/synced "$Q"
st rg2; has "main=${S0:0:7} idade_do_origin_min=180 idade_do_commit_main_min=346" "lag: a idade do origin vem do carimbo refs/gt/synced (180 min) e a do commit do main, do commit dele (346 min)"
git -C "$G2" update-ref -d refs/gt/synced; st rg2; has "idade_do_origin_min=null idade_do_commit_main_min=346" "lag: sem carimbo a idade do origin é null (nunca um número)"
git -C "$G2" update-ref refs/gt/synced "$Q"; git -C "$G2" update-ref -d refs/remotes/origin/main; st rg2; has "main= idade_do_origin_min=180 idade_do_commit_main_min=null" "lag: sem origin/main o main sai vazio e a idade do commit é null"
git -C "$G2" update-ref refs/remotes/origin/main "$S0"
# as situações de uma branch local, só por refs (nenhum remoto)
PUB=$(mkc pub 1700000300 "$S0"); git -C "$G2" update-ref refs/heads/worker/pub "$PUB"; git -C "$G2" update-ref refs/remotes/origin/worker/pub "$PUB"
GTP=$(mkc gtp 1700000310 "$S0"); git -C "$G2" update-ref refs/heads/worker/gtp "$GTP"; git -C "$G2" update-ref refs/gt/published/worker/gtp "$GTP"
git -C "$G2" update-ref refs/heads/worker/old "$P0"
PEN=$(mkc pen 1700000320 "$S0"); git -C "$G2" update-ref refs/heads/worker/pen "$PEN"
D1=$(mkc d1 1700000330 "$S0"); D2=$(mkc d2 1700000331 "$S0"); git -C "$G2" update-ref refs/heads/worker/div "$D2"; git -C "$G2" update-ref refs/remotes/origin/worker/div "$D1"
X=$(mkc x 1700000340 "$S0"); XX=$(mkc xx 1700000341 "$X"); git -C "$G2" update-ref refs/heads/worker/ahead "$XX"; git -C "$G2" update-ref refs/remotes/origin/worker/ahead "$X"
git -C "$G2" update-ref refs/heads/crew/c1 "$(mkc cr 1700000350 "$S0")"; git -C "$G2" update-ref refs/heads/feat/f1 "$(mkc fe 1700000360 "$S0")"
st rg2
has "  worker/pub: publicada no origin" "status: branch igual ao origin/<b>: publicada"
has "  worker/gtp: publicada no origin" "status: branch igual ao refs/gt/published/<b> (o origin ainda não trouxe): publicada"
has "  worker/old: sem trabalho novo" "status: branch contida no origin/main: sem trabalho novo"
has "  worker/pen: PENDENTE (empurre" "status: branch sem origin/<b> e fora do main: pendente"
has "  worker/div: PENDENTE e DIVERGE de origin/worker/div (${D1:0:7})" "status: origin/<b> e a ponta local, cada uma com commit que a outra não tem: diverge"
has "  worker/ahead: PENDENTE (empurre" "status: a ponta local é filha do origin/<b>: pendente comum"; hasnt "  worker/ahead: PENDENTE e DIVERGE" "status: ...e não diz que diverge"
has "  crew/c1: PENDENTE (empurre" "status: sem push configurado os prefixos são crew/ e worker/"; hasnt "feat/f1" "status: ...e feat/ fica de fora"; hasnt "origin/main:" "status: ...e nenhuma outra ref aparece como branch"
git -C "$G2" config --add remote.origin.push 'refs/heads/feat/*:refs/heads/feat/*'; st rg2
has "  feat/f1: PENDENTE (empurre" "status: o prefixo vem do push configurado pelo bootstrap (feat/)"; hasnt "worker/pub" "status: ...e só dele"
git -C "$G2" config --unset-all remote.origin.push
st; [ "$RC" = 0 ] && has "rg2: main=" "status sem argumento: lista os clones que têm repo.git (e só eles)" || bad "status sem argumento: rc=$RC" "$OUT"

# wt-add / wt-rm de ponta a ponta (o pull de dentro do wt-add é o do espelho de mentira)
wt() { OUT=$("$RG" "$@" 2>&1); RC=$?; }
fresh adv; WTA=$T/node/gascity/wt; wt wt-add gascity bead-a
[ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qE '"bead":"bead-a","branch":"worker/bead-a","base":"main","main":"[0-9a-f]{7}","main_age_min":-?[0-9]+,"lag_min":-?[0-9]+,"pull":"ok"\}$' && ok "wt-add: rc 0 e a linha JSON (bead, branch, base, main, idades, pull=ok)" || bad "wt-add: rc=$RC" "$OUT"
[ -e "$WTA/bead-a/lib/m2.txt" ] && [ ! -e "$WTA/bead-a/data/x1" ] && ok "wt-add: o checkout esparso traz o código liberado e NÃO o arquivo que o spec nega" || bad "wt-add: checkout esparso" "$(ls -R "$WTA/bead-a" 2>&1 | head -n 8)"
grep -qF '"bead":"bead-a"' "$T/node/worktrees.jsonl" && ok "wt-add: a linha também vai para worktrees.jsonl" || bad "wt-add: worktrees.jsonl"
wt wt-add gascity bead-a; [ "$RC" = 0 ] && has "wt/bead-a já existe" "wt-add de novo: a pasta pronta é reaproveitada (rc 0)" || bad "wt-add de novo: rc=$RC" "$OUT"
mkdir "$WTA/bead-inc"; wt wt-add gascity bead-inc; [ "$RC" = 3 ] && has 'worktree incompleto' "wt-add: pasta que existe sem checkout é recusada (rc 3), não tomada por pronta" || bad "wt-add pasta incompleta: rc=$RC" "$OUT"
wt wt-add gascity 'Bead Ruim'; [ "$RC" = 2 ] && has 'bead inv' "wt-add: bead que o regex recusa → rc 2" || bad "wt-add bead ruim: rc=$RC" "$OUT"
wt wt-add gascity bead-b 'Base Ruim'; [ "$RC" = 2 ] && has 'base inv' "wt-add: base que o regex recusa → rc 2" || bad "wt-add base ruim: rc=$RC" "$OUT"
wt wt-add gascity bead-b; [ "$RC" = 0 ] && ok "wt-add: uma segunda bead" || bad "wt-add bead-b: rc=$RC" "$OUT"
# (ga-tsi6ovl) um git que MENTE: `worktree remove` e `worktree prune` dizem 0 e a pasta continua la. O `[ ! -e ]` do wt-rm le o estado de DEPOIS, e e' ele que recusa (rc 3): sem ele
# (314cfe418f, o `&&` antes do `[ ! -e ]` virando `||`) o wt-rm contaria "removido, liberou N KB" sobre uma pasta que existe. Antes dos wt-rm de verdade: a bead-a segue inteira para eles.
OUT=$(env PATH="$T/shim2:$PATH" SHIM2_MODE=rmlies "$RG" wt-rm gascity bead-a 2>&1); RC=$?
{ [ "$RC" = 3 ] && [ -e "$WTA/bead-a" ]; } && has 'não removi' "wt-rm: git que diz 0 sem remover → rc 3 'não removi' (a pasta é conferida depois, não o rc do git)" || bad "wt-rm com git que mente: rc=$RC pasta=$([ -e "$WTA/bead-a" ] && echo existe || echo sumiu)" "$OUT"
find "$WTA/bead-b" -depth -delete   # a pasta some à mão: o clone fica com a entrada velha do worktree
wt wt-rm gascity bead-a
[ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qE '^wt-rm: bead-a removido, liberou [0-9]+ KB$' && [ ! -e "$WTA/bead-a" ] && ok "wt-rm: remove a pasta e diz quanto liberou" || bad "wt-rm: rc=$RC" "$OUT"
[ "$(git -C "$K" worktree list | wc -l | tr -d ' ')" = 1 ] && ok "wt-rm: também poda a entrada velha do worktree que alguém apagou à mão" || bad "wt-rm: a entrada velha ficou" "$(git -C "$K" worktree list)"
wt wt-rm gascity bead-a; [ "$RC" = 2 ] && has 'sem worktree bead-a' "wt-rm: bead sem worktree → rc 2" || bad "wt-rm sem worktree: rc=$RC" "$OUT"
wt wt-rm gascity 'Bead Ruim'; [ "$RC" = 2 ] && has 'bead inv' "wt-rm: bead que o regex recusa → rc 2" || bad "wt-rm bead ruim: rc=$RC" "$OUT"
wt wt-add gascity bead-a; [ "$RC" = 0 ] && [ -e "$WTA/bead-a/lib/m2.txt" ] && ok "wt-add depois do wt-rm: a branch worker/bead-a que ficou é reaproveitada" || bad "wt-add depois do wt-rm: rc=$RC" "$OUT"
rm -f "$T/node/gascity/sparse"; wt wt-add gascity bead-c; [ "$RC" = 3 ] && has 'clone sem filtro de dados' "wt-add: clone sem o arquivo sparse (nenhum pull deu certo) → rc 3" || bad "wt-add sem sparse: rc=$RC" "$OUT"
# schema-dbs-v1 (ga-kzwlkhh): a loja de bancos só-schema ($GR/schema-dbs/<rig>, instalada pelo wa-schema-dbs.py) entra no worktree NOVO no mesmo caminho relativo, como CÓPIA (o teste escreve sem sujar a loja); sem loja o wt-add é o
# de sempre; cp que falha não aborta o wt-add (o worktree segue sem o banco: o teste fica vermelho e a bead volta ao mini)
fresh adv; SD=$T/node/schema-dbs/gascity; mkdir -p "$SD/shared/data/sub" "$T/shim3"; printf 'SQLite format 3\0' > "$SD/shared/data/queue.db"; : > "$SD/shared/data/sub/x.db"; cp "$SD/shared/data/queue.db" "$T/queue.db.orig"
wt wt-add gascity sd-a
{ [ "$RC" = 0 ] && cmp -s "$T/queue.db.orig" "$WTA/sd-a/shared/data/queue.db" && [ -f "$WTA/sd-a/shared/data/sub/x.db" ]; } && ok "schema-dbs: o wt-add NOVO copia a loja para o mesmo caminho relativo (shared/data/queue.db e a subpasta)" || bad "schema-dbs: wt-add com loja: rc=$RC" "$(ls -R "$WTA/sd-a/shared" 2>&1 | head -n 6)"
echo mexido >> "$WTA/sd-a/shared/data/queue.db"; { cmp -s "$T/queue.db.orig" "$SD/shared/data/queue.db" && [ ! -L "$WTA/sd-a/shared/data/queue.db" ]; } && ok "schema-dbs: a cópia é arquivo próprio: escrever nela não suja a loja" || bad "schema-dbs: a loja mudou ou o arquivo é link"
mv "$SD" "$SD.off"; wt wt-add gascity sd-b; { [ "$RC" = 0 ] && [ -e "$WTA/sd-b/lib/m2.txt" ] && [ ! -e "$WTA/sd-b/shared" ]; } && ok "schema-dbs: sem loja instalada o wt-add é o de sempre (nenhum shared/ aparece)" || bad "schema-dbs: wt-add sem loja: rc=$RC" "$OUT"; mv "$SD.off" "$SD"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$T/shim3/cp"; chmod 755 "$T/shim3/cp"; OUT=$(env PATH="$T/shim3:$PATH" "$RG" wt-add gascity sd-c 2>&1); RC=$?
{ [ "$RC" = 0 ] && [ -e "$WTA/sd-c/lib/m2.txt" ] && [ ! -e "$WTA/sd-c/shared" ] && printf '%s' "$OUT" | grep -qF 'AVISO: não copiei a loja de schema-dbs'; } && ok "schema-dbs: cp que falha não aborta o wt-add (rc 0, o worktree vem sem o banco) e o AVISO aparece" || bad "schema-dbs: wt-add com cp falhando: rc=$RC" "$OUT"

# scan: clones de história conhecida, uma lista de dados e um HOME de mentira (nada de /home real nem de GH_TOKEN)
N3=$T/node3; W3=$T/w3; mkdir -p "$N3/lixo"; git init -q "$W3"; mkdir -p "$W3/lib" "$W3/data"; echo a > "$W3/lib/a.txt"; echo b > "$W3/README"; git -C "$W3" add -A; git -C "$W3" commit -qm c1
mkrig() { mkdir -p "$N3/$1"; git clone -q --bare "$W3" "$N3/$1/repo.git" 2>/dev/null; git -C "$N3/$1/repo.git" config gtremote.mirrorurl "$(git -C "$N3/$1/repo.git" config remote.origin.url)"; printf '%s\n' '/data/x1' '/data/x2' > "$N3/$1/deny"; }
SCANRIGS=; sc() { OUT=$(env -u GH_TOKEN -u GITHUB_TOKEN HOME="$T/home" GT_REMOTE_GIT="$N3" "$@" "$RG" scan $SCANRIGS 2>&1); RC=$?; }
mkrig sc; sc
[ "$RC" = 0 ] && has 'scan sc: limpo (' "scan sem argumento: lista só o clone que tem repo.git; sem dado negado, sem remoto de fora: limpo, rc 0" || bad "scan limpo: rc=$RC" "$OUT"
has 'scan credenciais: limpo' "scan: HOME sem credencial do GitHub: limpo"
mkrig st; mkdir -p "$N3/st/data"; echo x > "$N3/st/data/x2"; mkrig sr; git -C "$N3/sr/repo.git" remote add outro https://example.org/r.git; mkrig nd; rm -f "$N3/nd/deny"
echo SEGREDO > "$W3/data/x1"; git -C "$W3" add -A; git -C "$W3" commit -qm c2; mkrig sh   # só o sh nasce depois do commit com o dado negado
SCANRIGS=sh; sc
[ "$RC" = 1 ] && has 'historico=[data/x1 ] arvore=[] remotos_fora_do_espelho=[]' "scan: blob de caminho negado na história → VIOLAÇÃO só por isso, rc 1" || bad "scan história: rc=$RC" "$OUT"
SCANRIGS=st; sc
[ "$RC" = 1 ] && has 'historico=[] arvore=[data/x2 ] remotos_fora_do_espelho=[]' "scan: arquivo de caminho negado na árvore do clone → VIOLAÇÃO só por isso, rc 1" || bad "scan árvore: rc=$RC" "$OUT"
SCANRIGS=sr; sc
[ "$RC" = 1 ] && has 'historico=[] arvore=[] remotos_fora_do_espelho=[https://example.org/r.git]' "scan: remoto que não é o espelho → VIOLAÇÃO só por isso, rc 1" || bad "scan remoto: rc=$RC" "$OUT"
mkdir -p "$T/hc/.ssh"; : > "$T/hc/.netrc"; : > "$T/hc/.ssh/id_ed25519"; printf 'Host github.com\n' > "$T/hc/.ssh/config"; echo 'export GH_TOKEN=y' > "$T/hc/.profile"
printf '[credential]\n\thelper = store\n' > "$T/gitglobal"; printf '[credential]\n\thelper = store\n' > "$T/gitsystem"; SCANRIGS=sc
sc HOME="$T/hc" GH_TOKEN=x GIT_CONFIG_GLOBAL="$T/gitglobal" GIT_CONFIG_SYSTEM="$T/gitsystem"
[ "$RC" = 1 ] && has 'scan sc: limpo (' "scan: só a credencial viola (o clone está limpo) → rc 1" || bad "scan credenciais: rc=$RC" "$OUT"
for tag in '~/.netrc' '~/.ssh/id_*' '~/.ssh(github)' 'git-config-system(credential)' 'git-config-global(credential)' 'arquivo-de-shell(token)' 'env(token)'; do has "$tag" "scan: a credencial $tag é nomeada"; done
SCANRIGS=nd; sc
[ "$RC" = 2 ] && has 'sem a lista de dados' "scan: clone sem o arquivo deny → NÃO consegui (rc 2), nunca limpo" || bad "scan sem deny: rc=$RC" "$OUT"
SCANRIGS=sc; sc PATH="$T/shim2:$PATH" SHIM2_MODE=mktempfail
[ "$RC" = 2 ] && ok "scan: mktemp -d falha → rc 2, nunca 0" || bad "scan com mktemp -d falhando: rc=$RC" "$OUT"
rm -f "$T/cnt"; sc PATH="$T/shim2:$PATH" SHIM2_MODE=mktemp2fail SHIM2_CNT="$T/cnt"
[ "$RC" = 2 ] && has 'avaliar os nomes do hist' "scan: o mktemp -d de dentro do filtro de nomes falha → o clone é NÃO consegui, não limpo" || bad "scan com o 2º mktemp -d falhando: rc=$RC" "$OUT"
SCANRIGS=sc; sc PATH="$T/shim2:$PATH" SHIM2_MODE=mktempfail   # o 1º mktemp -d (o do próprio scan) falha: volta antes do laço, sem varrer clone nem credencial (sem o `|| return 2` o laço rodava com $t vazio)
hasnt 'scan sc:' "scan: mktemp -d do scan falha → nenhum clone é varrido (nem 'limpo' nem 'NÃO consegui' por clone)"; hasnt 'scan credenciais' "scan: mktemp -d do scan falha → as credenciais também não são varridas"
# schema-dbs-v1 (ga-kzwlkhh): o scan libera SÓ o caminho EXATO <wt>/<rel> de um banco do MANIFEST instalado (e -wal/-shm/-journal dele); outro .db, o mesmo nome fora de wt/<x>/ e o MANIFEST ausente seguem VIOLAÇÃO
W4=$T/w4; git init -q "$W4"; mkdir -p "$W4/lib"; echo a > "$W4/lib/a.txt"; git -C "$W4" add -A; git -C "$W4" commit -qm c1; mkdir -p "$N3/sd/wt/w1/shared/data" "$N3/schema-dbs/sd"
git clone -q --bare "$W4" "$N3/sd/repo.git" 2>/dev/null; git -C "$N3/sd/repo.git" config gtremote.mirrorurl "$(git -C "$N3/sd/repo.git" config remote.origin.url)"; printf '%s\n' '*.db' '*.db-*' 'data/' > "$N3/sd/deny"
: > "$N3/sd/wt/w1/shared/data/queue.db"; printf 'shared/data/queue.db\n' > "$N3/schema-dbs/sd/MANIFEST"; SCANRIGS=sd; sc
[ "$RC" = 0 ] && has 'scan sd: limpo (' "schema-dbs: o banco do MANIFEST dentro de um worktree (wt/w1/shared/data/queue.db) não é achado: limpo, rc 0" || bad "schema-dbs: scan com o banco liberado: rc=$RC" "$OUT"
: > "$N3/sd/wt/w1/shared/data/queue.db-wal"; : > "$N3/sd/wt/w1/shared/data/queue.db-shm"; sc; [ "$RC" = 0 ] && ok "schema-dbs: o -wal e o -shm do banco liberado também passam" || bad "schema-dbs: scan com -wal/-shm: rc=$RC" "$OUT"
: > "$N3/sd/wt/w1/shared/data/outro.db"; sc; [ "$RC" = 1 ] && has 'arvore=[wt/w1/shared/data/outro.db ]' "schema-dbs: outro .db no worktree (fora do MANIFEST) segue VIOLAÇÃO, rc 1" || bad "schema-dbs: scan com outro.db: rc=$RC" "$OUT"
find "$N3/sd/wt/w1/shared/data/outro.db" -delete; mkdir -p "$N3/sd/shared/data"; : > "$N3/sd/shared/data/queue.db"; sc
[ "$RC" = 1 ] && has 'arvore=[shared/data/queue.db ]' "schema-dbs: o MESMO nome fora de wt/<x>/ segue VIOLAÇÃO (a exceção é o caminho exato dentro de um worktree)" || bad "schema-dbs: scan com queue.db fora de wt/: rc=$RC" "$OUT"
find "$N3/sd/shared" -depth -delete; mv "$N3/schema-dbs/sd/MANIFEST" "$N3/schema-dbs/sd/MANIFEST.off"; sc
[ "$RC" = 1 ] && has 'arvore=[wt/w1/shared/data/queue.db' "schema-dbs: sem MANIFEST nada é liberado (VIOLAÇÃO, rc 1)" || bad "schema-dbs: scan sem MANIFEST: rc=$RC" "$OUT"
printf '[^%%]*\n../x\n' > "$N3/schema-dbs/sd/MANIFEST"; sc; [ "$RC" = 1 ] && has 'arvore=[wt/w1/shared/data/queue.db' "schema-dbs: MANIFEST com linha que não é caminho de banco ([^%]*) não vira regex que libera tudo: VIOLAÇÃO, rc 1" || bad "schema-dbs: scan com MANIFEST hostil: rc=$RC" "$OUT"

# ── lastro hq-mutants (ga-59jrj3d): o que o rodízio de 03/11 ainda achou vivo ─────────────────────────────────────────────────────────────────────────────────────────────
# rig_of: o nome tem de passar no regex E ter repo.git. Nome válido sem clone → rc 2 (com `||` no lugar do `&&` o regex bastava e o erro virava o rc 3 do pull); nome que o regex recusa, mesmo com pasta → rc 2 também.
wt pull semrig; [ "$RC" = 2 ] && has 'clone desconhecido: semrig' "rig_of: nome válido sem repo.git → rc 2 (não o 3 do pull)" || bad "rig_of sem clone: rc=$RC" "$OUT"
git init -q --bare "$T/node/UP/repo.git"; wt status UP; [ "$RC" = 2 ] && has 'clone desconhecido: UP' "rig_of: nome que o regex recusa, mesmo com repo.git na pasta → rc 2" || bad "rig_of nome recusado: rc=$RC" "$OUT"
# refspec de fetch: UM só basta para o retry (com `-gt 1` no lugar do `-gt 0` um clone com um refspec era tomado por "sem refspec") e NENHUM não refaz o fetch (nem deixa a marca da 2a tentativa)
fresh adv; git -C "$K" config --unset-all remote.origin.fetch; git -C "$K" config --add remote.origin.fetch '+refs/remotes/origin/*:refs/remotes/origin/*'; pull
[ "$RC" = 0 ] && has 'ref(s) ficaram FORA' "um refspec só: o retry contorna a ref de ponta ausente (o pull passa e o AVISO diz o que ficou fora)" || bad "um refspec só: rc=$RC" "$OUT"
fresh adv; git -C "$K" config --unset-all remote.origin.fetch; pull fetchfake
grep -qF -- '--- tentativa 2' "$LPE" && bad "sem refspec: houve uma 2a tentativa" "$(head -n 3 "$LPE")" || ok "sem refspec: nenhuma 2a tentativa foi feita"
grep -qF 'retry não feito: o clone não tem refspec de fetch' "$LPE" && ok "sem refspec: o last-pull-error diz que o clone não tem refspec de fetch" || bad "sem refspec: nota" "$(head -n 2 "$LPE")"
# o piso do filtro do espelho: EXATAMENTE 20 negações basta (`-ge 20`); com 19 o pull recusa
{ echo '/*'; for i in $(seq 1 20); do echo "!/data/z$i"; done; } > "$T/spec20"; { echo '/*'; for i in $(seq 1 19); do echo "!/data/z$i"; done; } > "$T/spec19"
fresh adv; git -C "$S" hash-object -w --stdin < "$T/spec20" > /dev/null; OUT=$(env FAKE_SPEC="$T/spec20" "$RG" pull gascity 2>&1); RC=$?
[ "$RC" = 0 ] && has 'resultado=ok' "filtro com 20 negações (o piso): o pull passa" || bad "filtro com 20 negações: rc=$RC" "$OUT"
fresh adv; git -C "$S" hash-object -w --stdin < "$T/spec19" > /dev/null; OUT=$(env FAKE_SPEC="$T/spec19" "$RG" pull gascity 2>&1); RC=$?
[ "$RC" = 1 ] && has 'resultado=erro' "filtro com 19 negações (abaixo do piso): o pull falha" || bad "filtro com 19 negações: rc=$RC" "$OUT"
# scan sem nenhum clone (só pasta que não é clone): NÃO consegui (rc 2), nunca limpo, e nem chega às credenciais
mkdir -p "$T/node4/lixo"; OUT=$(env HOME="$T/home" GT_REMOTE_GIT="$T/node4" "$RG" scan 2>&1); RC=$?
[ "$RC" = 2 ] && has 'scan: nenhum clone para varrer' "scan sem nenhum clone: NÃO consegui (rc 2), nunca limpo" || bad "scan sem clone: rc=$RC" "$OUT"
hasnt 'scan credenciais' "scan sem nenhum clone: nem chega às credenciais"

# ── lastro hq-mutants (ga-9twwdmk): três trocas do scan que o rodízio de 06/11 achou vivas (duas estavam declaradas equivalentes, com razão que só olhava um ramo) ────────────────────────────────────────
# (a) nome de arquivo com quebra de linha na ÁRVORE: o `find -print0` e o `tr` passam, e só a conferência de contagem (NULs x linhas) percebe que o parse por linha forjaria dois nomes; com o `&&` antes dela virando `||` o scan diz «limpo» (3 arquivos conferidos para 2 reais)
# (b) o `mktemp -d` de denied falha: sem o `|| return 2` o `git init` roda com $t vazio, isto é, em /r (como root criaria /r); o rc continua 2, então só o registro dos `git init` separa os dois
# (c) o `grep -v` do MANIFEST falha (rc 2) DEPOIS de imprimir o recorte bom: a lista fica como estava (o banco liberado segue achado); `[ $? -le 2 ]` aceitaria o recorte de uma filtragem que falhou
mkdir -p "$N3/nl" "$T/shim4" "$T/shim5"; git clone -q --bare "$W4" "$N3/nl/repo.git" 2>/dev/null; git -C "$N3/nl/repo.git" config gtremote.mirrorurl "$(git -C "$N3/nl/repo.git" config remote.origin.url)"; printf '%s\n' '/data/x1' > "$N3/nl/deny"
SCANRIGS=nl; sc
[ "$RC" = 0 ] && has 'scan nl: limpo (' "controle (nome com quebra de linha): o clone sem arquivo estranho na árvore é limpo, rc 0" || bad "controle (nome com quebra de linha): rc=$RC" "$OUT"
NLF="$N3/nl/$(printf 'a\nb')"; : > "$NLF"; sc
[ "$RC" = 2 ] && has 'find falhou ou há nome de arquivo com quebra de linha' "scan: arquivo com quebra de linha no NOME na árvore → NÃO consegui varrer (rc 2), o parse por linha não é seguro" || bad "scan com nome com quebra de linha na árvore: rc=$RC" "$OUT"
hasnt 'scan nl: limpo' "scan: ...e o clone não é dado por limpo"; rm -f "$NLF"
# o log dos `git init`: um scan normal CHAMA git init (o filtro de nomes cria um repo vazio em $t/r); o shim recusa o de /r (o selftest nunca cria nada na raiz do disco, nem rodando como root)
printf '%s\n' '#!/bin/sh' 'case "${1:-}" in init) echo "$*" >> "$SHIM4_LOG"; for last; do :; done; [ "$last" != /r ] || { echo "shim: git init /r recusado (de proposito)" >&2; exit 128; } ;; esac' 'exec "$REAL_GIT" "$@"' > "$T/shim4/git"; chmod 755 "$T/shim4/git"
: > "$T/gitinit.log"; sc PATH="$T/shim4:$PATH" SHIM4_LOG="$T/gitinit.log"
# vazio → o shim não registrou nada e o controle FALHA (nunca vira «sem git init»); ilegível → o grep -c não imprime número e o controle falha do mesmo jeito
[ "$RC" = 0 ] && [ "$(grep -c '^init -q /..*/r$' "$T/gitinit.log" 2> /dev/null)" -ge 1 ] && ok "controle (git init): um scan normal chama git init (em <tmp>/r, nunca em /r) e o shim o registra" || bad "controle (git init): rc=$RC" "$(cat "$T/gitinit.log" 2>&1)"
: > "$T/gitinit.log"; rm -f "$T/cnt"; sc PATH="$T/shim4:$T/shim2:$PATH" SHIM4_LOG="$T/gitinit.log" SHIM2_MODE=mktemp2fail SHIM2_CNT="$T/cnt"
[ "$RC" = 2 ] && has 'avaliar os nomes do hist' "denied: o mktemp -d falha → o scan diz NÃO consegui (rc 2)" || bad "denied com mktemp -d falhando: rc=$RC" "$OUT"
# vazio → nenhum git init (o esperado, e o controle acima prova que o mesmo log é escrito quando há); ilegível → o arquivo acabou de ser criado vazio, então só um shim que não escreve o deixaria assim
[ ! -s "$T/gitinit.log" ] && ok "denied: o mktemp -d que falha volta na hora e NÃO roda git init com \$t vazio (seria em /r)" || bad "denied: git init depois do mktemp -d falhar" "$(cat "$T/gitinit.log" 2>&1)"
# o grep -v do MANIFEST sai com rc 2 DEPOIS de imprimir o recorte certo (o banco do MANIFEST some dele): a lista de achados fica como estava, o banco liberado continua VIOLAÇÃO
export REAL_GREP; REAL_GREP=$(command -v grep)
printf '%s\n' '#!/bin/sh' 'case "${1:-} ${2:-} ${3:-}" in "-v -E ^wt/"*) "$REAL_GREP" "$@"; exit 2 ;; esac' 'exec "$REAL_GREP" "$@"' > "$T/shim5/grep"; chmod 755 "$T/shim5/grep"
SCANRIGS=sd; printf 'shared/data/queue.db\n' > "$N3/schema-dbs/sd/MANIFEST"; sc
[ "$RC" = 0 ] && has 'scan sd: limpo (' "controle (grep do MANIFEST): com o MANIFEST bom o banco liberado (e o -wal/-shm) passa, rc 0" || bad "controle (grep do MANIFEST): rc=$RC" "$OUT"
sc PATH="$T/shim5:$PATH"
[ "$RC" = 1 ] && has 'wt/w1/shared/data/queue.db' "schema-dbs: o grep do MANIFEST que falha (rc 2) depois de imprimir o recorte bom → a lista fica como estava: o banco liberado segue VIOLAÇÃO, rc 1" || bad "schema-dbs: grep do MANIFEST falhando: rc=$RC" "$OUT"

[ "$N" = "$HRG_EXPECT" ] || bad "casos rodados: $N, esperava $HRG_EXPECT (algum caso sumiu, ou foi acrescentado sem atualizar HRG_EXPECT)"
echo; echo "hetzner-remote-git selftest: $((N-F))/$N ok"; [ "$F" = 0 ] && exit 0 || { echo "FAIL=$F"; exit 1; }
