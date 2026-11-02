#!/bin/bash
# hetzner-remote-git.selftest.sh — hermético: tudo em mktemp, o "espelho" é um bare local servido por um `ssh` de mentira (sem rede, sem sshd, sem tocar nos clones reais). Cobre o `pull` de hetzner-remote-git.sh quando o espelho anuncia uma ref cuja ponta NÃO existe no clone (ga-yo1n1zg).
#
# ## Contents
#   Fixture · Controles · Recuperação · Estado visível · Cura · Falha sem contorno · Recusas · Falha que não é essa
#
# O CASO: em 02/11 o commit c0cc488b9 sumiu do repo.git do nó; o espelho passou a anunciar uma branch nova nessa ponta e TODO pull/fetch morreu em "did not send all necessary objects" (main parado 70 min), com a causa escondida
# (last-pull-error guardava só a última linha do stderr). Aqui o commit some do clone da fixture do mesmo jeito (pack reescrito sem ele) e o `pull` de verdade roda contra ele.
# O `ssh` de mentira serve o bare (FAKE_SRV) e o spec de dados; o shim de git (SHIM_MODE) injeta UMA falha (ls-remote, listagem de objetos, fetch) e repassa o resto ao git de verdade.
# HRG_S=<script> (caminho ABSOLUTO) testa outra cópia do script (mutantes); HRG_KEEP=1 guarda o tmp. Leva ~5 s.
# MUTANTES: 34 trocas de uma linha do conserto, 29 mortas. As 5 que sobrevivem são EQUIVALENTES, e por quê: o `--filter=` explícito do fetch (o 1º e o do retry) é redundante, porque o `remote.origin.partialclonefilter` que o pull
#   grava logo antes já vale para todo fetch de remoto promisor (e o espelho só serve com o filtro vigente); a `--prune` do retry é redundante no git 2.43, onde o fetch poda ANTES de falhar (medido; fica por git mais velho); o `sort -u`
#   de `cat-file --batch-all-objects` é redundante onde a saída já vem ordenada (git >= 2.19); o `LC_ALL=C` só vale com git traduzido (a frase que dispara o retry é em inglês).
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); RG=${HRG_S:-$HERE/hetzner-remote-git.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/hrg.XXXXXX"); T=$(cd "$T" && pwd -P); chmod 700 "$T"; N=0; F=0; HRG_EXPECT=85
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
case "${SHIM_MODE:-}:$*" in
  lsfail:*" ls-remote "*) echo "shim: ls-remote falhou (de propósito)" >&2; exit 128 ;;
  lsempty:*" ls-remote "*) exit 0 ;;
  objfail:*" cat-file --batch-all-objects "*) echo "shim: cat-file falhou (de propósito)" >&2; exit 128 ;;
  objempty:*" cat-file --batch-all-objects "*) exit 0 ;;
  retryfail:*"remote.origin.fetch=^"*" fetch "*) echo "error: boom no retry (de propósito)" >&2; exit 1 ;;
  fetchfake:*" fetch "*) echo "error: ssh://x/y.git did not send all necessary objects" >&2; exit 1 ;;
  flood:*" fetch "*) i=0; while [ $i -lt 300 ]; do echo "error: ruido $i" >&2; i=$((i+1)); done; echo "error: ssh://x/y.git did not send all necessary objects" >&2; exit 1 ;;
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

# ── falha que não é essa: sem a frase do git não há segunda tentativa ─────────────────────────────────────────────────────────────────────────────────────────────────
fresh adv; OUT=$(env FAKE_SSH_FAIL=upload-pack "$RG" pull gascity 2>&1); RC=$?
[ "$RC" = 1 ] && has 'resultado=erro' "outra falha do fetch (rede): o pull falha como sempre"
grep -qF 'Connection refused' "$LPE" && ok "outra falha: o stderr dela fica no last-pull-error" || bad "outra falha: stderr" "$(cat "$LPE" 2>&1)"
grep -qF 'retry' "$LPE" && bad "outra falha: tentou contornar o que não era a falha esperada" "$(cat "$LPE")" || ok "outra falha: sem segunda tentativa nem nota de retry"
fresh adv; OUT=$(env FAKE_SSH_FAIL=spec "$RG" pull gascity 2>&1); RC=$?   # falha ANTES do fetch (o espelho não devolve o filtro): as variáveis do retry nunca foram setadas e o pull tem de falhar limpo, não morrer em 'unbound variable'
[ "$RC" = 1 ] && has 'resultado=erro' "espelho sem filtro (antes do fetch): o pull falha limpo (rc 1, resultado=erro)"; hasnt 'unbound' "espelho sem filtro: nenhuma variável do retry fica sem valor (set -u)"
grep -qF 'spec indisponível' "$LPE" && ok "espelho sem filtro: o stderr do ssh fica no last-pull-error" || bad "espelho sem filtro: stderr" "$(cat "$LPE" 2>&1)"

[ "$N" = "$HRG_EXPECT" ] || bad "casos rodados: $N, esperava $HRG_EXPECT (algum caso sumiu, ou foi acrescentado sem atualizar HRG_EXPECT)"
echo; echo "hetzner-remote-git selftest: $((N-F))/$N ok"; [ "$F" = 0 ] && exit 0 || { echo "FAIL=$F"; exit 1; }
