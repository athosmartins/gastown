#!/usr/bin/env bash
# hetzner-ballast-items.selftest.sh — hermético (ga-2hd02v.5): os itens do lastro (scripts/hetzner-ballast-items/*.sh) contra um espelho git de brinquedo (um repo bare com a árvore do hq
# de mentira, o `hetzner-remote-git.sh` é um stub que usa `git worktree` de verdade) e selftests de brinquedo (passa, reprova, ambiente, estoura o prazo, só-macOS); o motor de mutantes e a jaula do
# hq-mutants e do wa-mutants são de mentira (um hq-mutate.py / hq-mutate-wa.py de brinquedo que imprime o que o caso manda). Nada fala com o nó.
#
# Contents
#   Casos · Controle negativo · Variáveis
#
# CASOS
#   hq-selftests (g_hq): uma rodada completa conta passou/reprovou/ambiente/prazo e deixa de fora a lista só-macOS · 1ª rodada = "primeira" (sem comparação) · mesma ponta do main = "sem-novidade"
#     e não cria árvore · commit novo = só as reprovações NOVAS contra a última rodada COMPLETA entram em new_fail · reprovação que passa na 2ª tentativa é "flaky", não reprovada ·
#     pull que falha segue com o clone que há e diz pull=falhou · lista só-macOS ausente/vazia, árvore sem scripts/, wt-add que falha = exit 3, nada rodou e a ponta NÃO é gravada ·
#     TERM no meio apaga a árvore e NÃO grava a ponta (a próxima rodada refaz) · log só de quem reprovou · resumo é JSON de uma linha `BALLAST-SUMMARY:` · padrão só-macOS com espaço nas pontas é aparado ·
#     o passo FINAL (resumo + gravação do estado) que falha — arquivo de durações que é pasta, ou o python do passo que morre — dá exit 3 com resumo `gravacao-falhou`/`resumo-falhou`, não consome a ponta nem a
#     lista de reprovadas, e a rodada seguinte AINDA diz a falha nova.
#   queima (g_burn): sobe BALLAST_CORES laços, avisa o resumo na partida e sai no TERM sem deixar filho · passado BALLAST_BURN_SECS termina SOZINHA com rc 0 (o `timeout` do prazo a mataria com 124 e o
#     governo cobraria >= 600 s de cooldown de falha) · BALLAST_BURN_SECS inválido = exit 2 · o relógio (sleep) que falha dá rc 1, não 0 · o tempo padrão fica >= 60 s abaixo do prazo da linha `queima` do registro. Toda corrida de entrada inválida
#     leva prazo (o queima agora dorme BALLAST_BURN_SECS: um que aceitasse a entrada ruim penduraria o teste).
#   hq-mutants (g_mut): a rodada passa ao motor a árvore NOVA, o estado em $BALLAST_HOME (sobrevive entre rodadas), --slots (2 × núcleos; HQ_MUTANTS_SLOTS inválido volta ao padrão, acima de 16 corta em 16) e --budget-s ·
#     o resumo é a ÚLTIMA linha JSON do motor COM `result` (não uma velha, nem lixo depois) mais main/pull/slots/budget_s/engine_rc, uma linha só · motor sem-novidade com rc 0 grava o marcador de ocioso e a mesma
#     ponta (de menos de 6 h) não cria árvore nem chama o motor · marcador velho, ponta nova, motor que diz sem-novidade com rc 3, completo, sem-jaula (rc 97 passa adiante), rc estranho (vira 3), motor que morre sem
#     resumo (motor-sem-resumo, rc 3, sem marcador) · sem motor/jaula na árvore, sem scripts/, sem origin/main, wt-add que falha = exit 3 · pull que falha segue · o passo do resumo que morre = resumo-falhou, exit 3 · TERM no
#     meio espera o motor acabar ANTES de a árvore sair, e a árvore e a branch saem · o registro REAL: a linha hq-mutants (work, núcleos fixos que cabem ao lado do wa-suite, depois dele, prazo >= budget + 1000 s, RAM).
#   wa-mutants (g_wam, ga-tmfmvxi): o mesmo contrato do hq-mutants com DOIS rigs: o motor (hq-mutate.py, hq-mutate-wa.py e a jaula) sai do origin/main do HQ para a pasta da rodada (cmp), a árvore é a do origin/main do WA e o python é o do venv do WA ·
#     o marcador de ocioso vale pelo PAR de pontas (WA:HQ): ponta nova de qualquer um dos dois, ou marcador de 6 h ou mais, roda de novo · sem wrapper/jaula no main do HQ (ou jaula vazia) = sem-motor dizendo qual falta, e o WA nem ganha árvore ·
#     sem o python do venv = preparo-ausente · árvore do WA sem tests/ ou sem lib/ E daemons/ = arvore-sem-testes (só daemons/ vale) · pull que falha em um rig, no outro ou nos dois segue com os clones que há (pull=falhou / hqpull=falhou) ·
#     sem origin/main em qualquer dos dois = sem-main · sobra de rodada morta (árvore + branch) é refeita na ponta nova · TERM espera o motor acabar antes de a árvore sair · o registro REAL: a linha wa-mutants (work, núcleos fixos, requires com o
#     hetzner-remote-git.sh, o venv e noflag:wa-suite.leak, prazo >= budget + 1000 s, cooldown de 120 a 600 s, cabe com o wa-suite e com o hq-mutants no orçamento de 9 núcleos, RAM >= 1 GB por slot, depois do wa-suite e do hq-mutants).
# CONTROLE NEGATIVO: (wa-mutants.sh: cada comportamento acima trocado numa cópia do item — o motor tirado do clone do WA em vez do main do HQ, o marcador que ignora uma das pontas ou o relógio, o rig errado, o python errado, a árvore que fica, o TERM que não espera ·
#   a lista inteira está nas linhas do bloco MUT) · sem a rodada de reprovadas · ambiente/prazo contados como reprovados · lista só-macOS ignorada ou aceita vazia · comparação sem a rodada anterior · ponta não gravada · árvore
#   não removida (nem no TERM) · pull/wt-add que falham ignorados · queima que não leva os laços no TERM · queima que espera o prazo (rc 124), sai com rc 1 no fim normal ou toma o relógio que falhou por fim normal · tempo padrão acima do prazo do registro ·
#   BALLAST_BURN_SECS inválido aceito · falha do passo final vista como rc 0 · alvo de estado que é pasta sem a checagem prévia · passo do resumo que morre sem resumo · padrão só-macOS não aparado —
#   cada um é aplicado numa cópia e a bateria TEM que falhar.
# VARIÁVEIS: HBI_PY (python do teste; padrão /usr/bin/python3) · HBI_ONLY=<grupo> (hq mut burn wam) · HBI_NO_MUTANTS=1 · HBI_JOBS (mutantes em paralelo; padrão 4)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ITEMS="${HBI_ITEMS_DIR:-$HERE/hetzner-ballast-items}"
PY="${HBI_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hbi.XXXXXX)" && pwd -P)
# killtree CAMINHO — mata, pelo GRUPO de processos, tudo que leva CAMINHO na linha de comando. O item de brinquedo roda em sessão própria e tem filhos (`sleep 300`) que NÃO levam o caminho:
# `pkill -f` só os pega se o caminho aparecer, e o resto fica órfão (ppid 1) no mini/nó depois do teste (incidente de 20/10: 22 órfãos por rodada). O grupo do próprio teste é poupado.
killtree() {
  local g self; self=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  for g in $(ps -axo pgid=,command= 2>/dev/null | awk -v p="$1" 'index($0, p) { print $1 }' | sort -u); do
    case "$g" in ''|*[!0-9]*) continue ;; esac
    [ "$g" -gt 1 ] && [ "$g" != "$self" ] && kill -KILL -- "-$g" 2>/dev/null
  done
  return 0
}
cleanup() { killtree "$T/"; pkill -f "$T/" 2>/dev/null; sleep 0.2; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP   # sem isto um TERM/INT (TaskStop, ctrl-c) pula o EXIT e deixa processos órfãos
fails=0; n=0
ok() {  # no modo mutante, a primeira falha encerra (só interessa se a bateria reprova)
  n=$((n+1))
  if [ "$1" = 0 ]; then [ -n "${HBI_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HBI_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi
}
check() { if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$T/w"; mkdir -p "$W/bin"
cat > "$W/bin/timeout" <<'EOF'
#!/bin/sh
# timeout de brinquedo COM prazo de verdade (o do macOS não existe): timeout [-k K] DUR cmd… ; estouro = rc 124 como o GNU
[ "$1" = -k ] && shift 2
dur=$1; shift
f=$(mktemp -u "${TMPDIR:-/tmp}/tmo.XXXXXX")
"$@" & pid=$!
( sleep "$dur"; : > "$f"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) & kp=$!
wait "$pid"; rc=$?
kill "$kp" 2>/dev/null
[ -e "$f" ] && { rm -f "$f"; exit 124; }
exit "$rc"
EOF
chmod +x "$W/bin/timeout"
cat > "$W/bin/python3" <<'EOF'
#!/bin/sh
# python3 de brinquedo: o real, salvo que COM o arquivo $HBI_PY_CRASH o passo do RESUMO final (o único cujo texto tem "res1, res2, prev_p", "erc, short, pull" no hq-mutants ou "erc, short, hqshort" no wa-mutants) quebra — rc 1 e nada na saída, como um OOM ou um erro do interpretador
case "$1:$2" in
  -I:-) src=$(cat)
        if [ -f "$HBI_PY_CRASH" ] && printf '%s' "$src" | grep -q -e 'res1, res2, prev_p' -e 'erc, short, pull' -e 'erc, short, hqshort'; then echo "python3 (brinquedo): quebrou" >&2; exit 1; fi
        printf '%s\n' "$src" | "$HBI_REAL_PY" "$@"; exit $? ;;
esac
exec "$HBI_REAL_PY" "$@"
EOF
chmod +x "$W/bin/python3"
export HBI_REAL_PY="$PY" HBI_PY_CRASH="$W/py.crash"   # o python3 de brinquedo acima lê os dois (todo filho herda)

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
mkst() {  # mkst CAMINHO RC [CORPO] — um selftest de brinquedo
  mkdir -p "$(dirname "$1")"; printf '#!/bin/bash\necho "selftest %s"\n%s\nexit %s\n' "$(basename "$1")" "${3:-:}" "$2" > "$1"
}
newrig() {  # repo-fonte com a árvore do hq de mentira + o repo bare que o stub usa como "clone do nó"
  N=$((${N:-0}+1)); BH="$T/bh$N"; GR="$T/gr$N"; SRC="$T/src$N"; RD="$T/rd$N"; mkdir -p "$BH" "$GR/gascity" "$RD"
  git init -q "$SRC"; local c="$SRC/.gascity-gastown-hq"
  mkst "$c/scripts/a.selftest.sh" 0; mkst "$c/scripts/b.selftest.sh" 1; mkst "$c/scripts/mac.selftest.sh" 1
  mkst "$c/scripts/env.selftest.sh" 97; mkst "$c/scripts/slow.selftest.sh" 0 'sleep 8'; mkst "$c/packs/town-deltas/assets/c.selftest.sh" 0
  printf '# só-macOS\nscripts/mac.selftest.sh\n' > "$c/scripts/hetzner-mac-only.hq.txt"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m um && git clone -q --bare "$SRC" "$GR/gascity/repo.git" 2>/dev/null
  git -C "$GR/gascity/repo.git" update-ref refs/remotes/origin/main "$(git -C "$SRC" rev-parse HEAD)"
  rm -f "$W/rg.pull.fail" "$W"/rg.pull.fail.* "$W/rg.wtadd.fail"; : > "$W/rg.calls"
}
newcommit() {  # newcommit ARQUIVO RC — um selftest novo no main (e o espelho avança)
  mkst "$SRC/.gascity-gastown-hq/scripts/$1" "$2"; git -C "$SRC" add -A && git -C "$SRC" commit -q -m novo
  git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"
}
cat > "$W/rg" <<'EOF'
#!/bin/bash
# stub do hetzner-remote-git.sh: pull / wt-add / wt-rm com git worktree de verdade
W="$(cd "$(dirname "$0")" && pwd)"; echo "$*" >> "$W/rg.calls"
case "$1" in
  pull) { [ -f "$W/rg.pull.fail" ] || [ -f "$W/rg.pull.fail.$2" ]; } && { echo "pull rig=$2 resultado=erro" >&2; exit 1; }; echo "pull rig=$2 resultado=ok"; exit 0 ;;
  wt-add) [ -f "$W/rg.wtadd.fail" ] && exit 3
          g="git -C $GT_REMOTE_GIT/$2/repo.git"
          if $g rev-parse -q --verify "refs/heads/worker/$3" > /dev/null; then $g worktree add -q "$GT_REMOTE_GIT/$2/wt/$3" "worker/$3" || exit 3
          else $g worktree add -q -b "worker/$3" "$GT_REMOTE_GIT/$2/wt/$3" refs/remotes/origin/main || exit 3; fi; echo "{}"; exit 0 ;;
  wt-rm) git -C "$GT_REMOTE_GIT/$2/repo.git" worktree remove --force "$GT_REMOTE_GIT/$2/wt/$3" 2>/dev/null; exit 0 ;;
esac
exit 2
EOF
chmod +x "$W/rg"
runhq() {  # runhq [VAR=valor…] → $OUT (stdout inteiro), $RC; BALLAST_RUN_DIR novo a cada rodada
  RDN=$((${RDN:-0}+1)); RD="$T/rd$N.$RDN"; mkdir -p "$RD"
  OUT=$(env PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" HQ_SELFTEST_TIMEOUT=3 "$@" bash "$ITEMS/hq-selftests.sh" 2>"$W/err"); RC=$?
}
sj() {  # sj CAMPO — campo do último BALLAST-SUMMARY (JSON) do $OUT
  printf '%s\n' "$OUT" | grep '^BALLAST-SUMMARY: ' | tail -n 1 | sed 's/^BALLAST-SUMMARY: //' | "$PY" -I -c 'import sys,json
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if isinstance(v,dict): v=v.get(k)
    elif isinstance(v,list) and k.isdigit() and int(k)<len(v): v=v[int(k)]
    else: v=None
print(v if isinstance(v,str) else json.dumps(v))' "$1" 2>/dev/null
}

# ── g_hq ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_hq() {
  newrig; runhq
  check "hq: rodada completa → rc 0" "0" "$RC"
  check "hq: resultado completo" "completo" "$(sj result)"
  check "hq: 5 contam (a, b, env, slow, c); mac.selftest fica de fora (só-macOS)" "5 1" "$(sj total) $(sj skipped_mac)"
  check "hq: passou 2 (a, c) · reprovou 1 (b) · ambiente 1 (rc 97) · prazo 1 (slow, 3 s)" "2 1 1 1" "$(sj pass) $(sj fail) $(sj ambiente) $(sj timeout)"
  check "hq: 1ª rodada não tem com o que comparar → compare primeira, new_fail_n 0" "primeira 0" "$(sj compare) $(sj new_fail_n)"
  check "hq: a ponta testada é gravada só no fim" "$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)" "$(cat "$BH/hq-selftests.last" 2>/dev/null)"
  check "hq: o resumo traz o pull (ok) e a ponta (7 letras)" "ok 1" "$(sj pull) $([ "$(sj main | tr -d '"' | wc -c | tr -d ' ')" -ge 8 ] && echo 1 || echo 0)"
  check "hq: log só de quem reprovou (b sim, a não)" "1 0" "$(ls "$RD/out" | grep -c 'scripts_b.selftest.sh.log') $(ls "$RD/out" | grep -c 'scripts_a.selftest.sh.log')"
  check "hq: a árvore de trabalho foi removida ao fim (wt-rm chamado)" "1" "$(grep -c '^wt-rm gascity ballast-hq' "$W/rg.calls")"
  check "hq: nenhuma branch worker/* sobra no clone do nó (o wt-rm real só tira a árvore; uma branch por rodada entupiria o espelho)" "0" "$(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"
  check "hq: exatamente UMA linha BALLAST-SUMMARY no stdout" "1" "$(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"

  runhq
  check "hq: mesma ponta → sem-novidade, rc 0" "0 sem-novidade" "$RC $(sj result)"
  check "hq: sem-novidade não cria árvore (nenhum wt-add novo)" "1" "$(grep -c '^wt-add' "$W/rg.calls")"

  newcommit d.selftest.sh 1; runhq
  check "hq: commit novo → roda de novo; b já reprovava na última COMPLETA, d é nova: new_fail = d" "ok 1 scripts/d.selftest.sh" "$(sj compare) $(sj new_fail_n) $(sj new_fail.0)"
  check "hq: fail = b e d (2)" "2" "$(sj fail)"
  check "hq: o resumo da rodada do commit novo traz a ponta NOVA do main (9 primeiras letras do sha)" "$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main | cut -c1-9)" "$(sj main)"
  newcommit e.selftest.sh 0; runhq
  check "hq: terceira rodada: d e b reprovavam antes → nenhuma NOVA (new_fail_n 0)" "0" "$(sj new_fail_n)"

  # Rodada morta com SIGKILL (o trap não roda) deixa no clone a árvore E a branch worker/ballast-hq na ponta de então. Sem apagar a branch ANTES do wt-add, o wt-add a reusaria e a rodada seguinte
  # testaria o código de outro dia. O fim normal de rodada e o TERM já apagam a branch, então só este caso a deixa de pé: sem ele o mutante "a branch velha não sai antes do wt-add" passava batido.
  newrig; old=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)
  git -C "$GR/gascity/repo.git" worktree add -q -b worker/ballast-hq "$GR/gascity/wt/ballast-hq" "$old"
  newcommit g.selftest.sh 1; runhq
  new=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)
  check "hq: a ponta mudou entre a rodada morta e a seguinte (o caso não é vazio)" "1" "$([ "$old" != "$new" ] && echo 1 || echo 0)"
  check "hq: sobra de rodada morta (árvore + branch na ponta velha) → a rodada seguinte testa a ponta NOVA, não a branch velha" "0 ${new:0:9} 1" "$RC $(sj main) $([ "$(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')" = 0 ] && echo 1 || echo 0)"

  # O passo FINAL (resumo + gravação do estado) que falha não pode virar rc 0 nem consumir o sinal (veredito do gate, 21/10): antes, a lista de reprovadas era gravada ANTES das durações, da ponta e do
  # resumo, e uma exceção no meio deixava rc 0 sem BALLAST-SUMMARY, com as reprovadas da rodada já na linha de base — a falha nova sumia sem ter sido dita. Dois jeitos de quebrar o passo: o arquivo
  # de durações vira PASTA (a troca falha até para root) e o python do passo morre (rc 1, sem saída). Nos dois: exit 3, o resumo diz o que houve, nada é consumido e a rodada seguinte AINDA diz a falha nova.
  newrig; runhq
  newcommit h.selftest.sh 1
  prev0=$(cat "$BH/hq-selftests.failed" 2>/dev/null); last0=$(cat "$BH/hq-selftests.last" 2>/dev/null)
  rm -f "$BH/hq-selftests.durations"; mkdir "$BH/hq-selftests.durations"; runhq
  check "hq: gravação do estado que falha (durações é uma pasta) → exit 3, resumo gravacao-falhou (uma linha só), nunca rc 0" "3 gravacao-falhou 1" "$RC $(sj result) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"
  check "hq: ...e nada foi consumido: reprovadas e ponta seguem as da rodada anterior (a falha nova h não entrou na linha de base)" "1 1" "$([ "$(cat "$BH/hq-selftests.failed" 2>/dev/null)" = "$prev0" ] && echo 1 || echo 0) $([ "$(cat "$BH/hq-selftests.last" 2>/dev/null)" = "$last0" ] && echo 1 || echo 0)"
  rmdir "$BH/hq-selftests.durations"; runhq
  check "hq: ...e na rodada seguinte, com a gravação de volta, a falha nova AINDA é dita (new_fail = h)" "completo 1 scripts/h.selftest.sh" "$(sj result) $(sj new_fail_n) $(sj new_fail.0)"
  prev1=$(cat "$BH/hq-selftests.failed" 2>/dev/null); last1=$(cat "$BH/hq-selftests.last" 2>/dev/null)
  newcommit i.selftest.sh 1; : > "$W/py.crash"; runhq; rm -f "$W/py.crash"
  check "hq: o passo do resumo que quebra (python rc 1, sem saída) → exit 3 com resumo-falhou, nunca rc 0" "3 resumo-falhou 1" "$RC $(sj result) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"
  check "hq: ...e também não consumiu nada (reprovadas e ponta seguem as da rodada anterior)" "1 1" "$([ "$(cat "$BH/hq-selftests.failed" 2>/dev/null)" = "$prev1" ] && echo 1 || echo 0) $([ "$(cat "$BH/hq-selftests.last" 2>/dev/null)" = "$last1" ] && echo 1 || echo 0)"
  runhq
  check "hq: ...e na rodada seguinte a falha nova AINDA é dita (new_fail = i)" "completo 1 scripts/i.selftest.sh" "$(sj result) $(sj new_fail_n) $(sj new_fail.0)"

  newrig; mkst "$SRC/.gascity-gastown-hq/scripts/flaky.selftest.sh" 0 'f="$TMPDIR_HBI/flaky.count"; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n+1)) > "$f"; [ "$n" -ge 1 ] || exit 1'
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m flaky && git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"; mkdir -p "$T/tmpd$N"
  runhq TMPDIR_HBI="$T/tmpd$N"
  check "hq: reprovou na 1ª e passou na 2ª tentativa → flaky 1 (não conta como reprovada)" "1 1" "$(sj flaky) $(sj fail)"

  newrig; : > "$W/rg.pull.fail"; runhq
  check "hq: pull que falha segue com o clone que há e diz pull=falhou (rc 0)" "0 falhou completo" "$RC $(sj pull) $(sj result)"

  newrig; sed -i.bak '/mac.selftest/d;/só-macOS/d' "$SRC/.gascity-gastown-hq/scripts/hetzner-mac-only.hq.txt"; git -C "$SRC" add -A; git -C "$SRC" commit -q -m vazio; git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"
  runhq
  check "hq: lista só-macOS sem nenhum padrão → exit 3, nada rodou, ponta não gravada" "3 mac-only-ilegivel 0" "$RC $(sj result) $([ -e "$BH/hq-selftests.last" ] && echo 1 || echo 0)"
  newrig; git -C "$SRC" rm -q ".gascity-gastown-hq/scripts/hetzner-mac-only.hq.txt"; git -C "$SRC" commit -q -m sem; git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"; runhq
  check "hq: lista só-macOS ausente → exit 3 (o nó não é usado)" "3 mac-only-ilegivel" "$RC $(sj result)"
  newrig; printf '# só-macOS\n  scripts/mac.selftest.sh \t\r\n' > "$SRC/.gascity-gastown-hq/scripts/hetzner-mac-only.hq.txt"; git -C "$SRC" add -A; git -C "$SRC" commit -q -m espaco; git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"; runhq
  check "hq: padrão só-macOS com espaço, tab e CR nas pontas é aparado (como no mbp-run.sh) → mac.selftest segue de fora (5 contam, 1 pulado)" "5 1" "$(sj total) $(sj skipped_mac)"
  newrig; : > "$W/rg.wtadd.fail"; runhq
  check "hq: wt-add que falha → exit 3, ponta não gravada" "3 wt-add-falhou 0" "$RC $(sj result) $([ -e "$BH/hq-selftests.last" ] && echo 1 || echo 0)"
  newrig; git -C "$GR/gascity/repo.git" update-ref -d refs/remotes/origin/main; runhq
  check "hq: clone sem origin/main → exit 3 (sem-main)" "3 sem-main" "$RC $(sj result)"

  newrig; RDN=$((RDN+1)); RD="$T/rd$N.k"; mkdir -p "$RD"
  ( env PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" HQ_SELFTEST_TIMEOUT=20 bash "$ITEMS/hq-selftests.sh" > "$W/kill.out" 2>&1 ) & kp=$!
  sleep 3; pkill -TERM -P "$kp" 2>/dev/null; kill -TERM "$kp" 2>/dev/null; wait "$kp" 2>/dev/null
  i=0; while [ "$i" -lt 100 ] && ! grep -q '^wt-rm gascity ballast-hq' "$W/rg.calls"; do sleep 0.2; i=$((i+1)); done   # até 20 s: o item só trata o TERM quando o xargs em primeiro plano volta (a rodada de brinquedo dura ~8 s); o governo manda o TERM ao GRUPO e isto não exercita isso
  check "hq: TERM no meio → a ponta NÃO é gravada (a próxima rodada refaz)" "0" "$([ -e "$BH/hq-selftests.last" ] && echo 1 || echo 0)"
  check "hq: TERM no meio → a árvore de trabalho é removida" "1" "$(grep -c '^wt-rm gascity ballast-hq' "$W/rg.calls")"
  check "hq: TERM no meio → a branch worker/* também não sobra" "0" "$(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"
}

# ── g_burn ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_burn() {
  local out="$W/burn.out"; BR="$T/burnrun"; mkdir -p "$BR" "$T/qm"; cp "$ITEMS/queima.sh" "$T/qm/queima.sh" 2>/dev/null
  ( env PATH="$PATH" BALLAST_HOME="$T/bh0" BALLAST_RUN_DIR="$BR" BALLAST_CORES=3 bash "$T/qm/queima.sh" > "$out" 2>&1 ) & bp=$!
  sleep 1.5
  check "burn: avisa o resumo na partida (cores 3, secs 3300 = o padrão)" "1" "$(grep -c '^BALLAST-SUMMARY: {"kind": "queima", "cores": 3, "secs": 3300}$' "$out")"
  check "burn: 3 laços de CPU + o script = 4 processos com o caminho do item" "4" "$(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  kill -TERM "$(pgrep -o -f "$T/qm/queima.sh" 2>/dev/null)" 2>/dev/null; sleep 1.5
  check "burn: TERM só no processo mais velho (o script) → ele leva os laços junto, nada fica para trás" "0" "$(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  wait "$bp" 2>/dev/null
  ( env BALLAST_RUN_DIR="$BR" BALLAST_CORES=abc BALLAST_BURN_SECS=1 "$W/bin/timeout" 6 bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  check "burn: BALLAST_CORES que não é inteiro >= 1 → exit 2 e nada sobe" "2" "$rc"
  ( env BALLAST_RUN_DIR="$BR" BALLAST_CORES=0 BALLAST_BURN_SECS=1 "$W/bin/timeout" 6 bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  check "burn: BALLAST_CORES=0 também é recusado (exit 2)" "2" "$rc"
  ( env BALLAST_RUN_DIR="$BR" BALLAST_CORES=1 BALLAST_BURN_SECS=abc "$W/bin/timeout" 6 bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  check "burn: BALLAST_BURN_SECS que não é inteiro >= 1 → exit 2 e nada sobe" "2 0" "$rc $(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  # O fim NORMAL de uma hora de queima tem que ser rc 0: o `timeout` do prazo devolve 124 e o governo (finalize) cobra cooldown >= 600 s de qualquer why que não seja ok. O `timeout` de brinquedo
  # devolve 124 no estouro, como o GNU, então um queima que espera o prazo em vez de terminar sozinho aparece aqui como rc 124.
  s0=$SECONDS
  ( env BALLAST_RUN_DIR="$BR" BALLAST_CORES=2 BALLAST_BURN_SECS=2 "$W/bin/timeout" 8 bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  check "burn: passado BALLAST_BURN_SECS termina sozinho com rc 0 (não 124 do timeout), sem esperar o prazo" "0 1" "$rc $([ $((SECONDS - s0)) -lt 7 ] && echo 1 || echo 0)"
  sleep 0.5
  check "burn: ao terminar sozinho não deixa laço nem relógio para trás" "0" "$(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  check "burn: o resumo da partida diz por quanto tempo (secs 2)" "1" "$(grep -c '^BALLAST-SUMMARY: {"kind": "queima", "cores": 2, "secs": 2}$' "$out")"
  # O relógio que falha não é fim normal: um `sleep` de brinquedo que sai com 1 só quando é o do queima (arg 2; o do `timeout` de brinquedo, 8, passa para o real) → rc 1 e nenhum laço sobrando
  mkdir -p "$T/nosleep"; printf '#!/bin/sh\n[ "$1" = 2 ] && exit 1\nexec /bin/sleep "$@"\n' > "$T/nosleep/sleep"; chmod +x "$T/nosleep/sleep"
  ( env PATH="$T/nosleep:$PATH" BALLAST_RUN_DIR="$BR" BALLAST_CORES=2 BALLAST_BURN_SECS=2 "$W/bin/timeout" 8 bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  sleep 0.5
  check "burn: o relógio (sleep) que falha NÃO é fim normal: rc 1 e leva os laços (rc 0 faria o governo recomeçá-lo a cada tick como 'ok', sem queimar nada)" "1 0" "$rc $(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  # O tempo padrão vem do texto do próprio queima.sh e o prazo da linha `queima` do REGISTRO que vai no repo: se alguém subir um e esquecer o outro, o timeout volta a matar com 124.
  # vazio/ilegível (não achei o padrão ou o prazo) → 0 e a bateria reprova; nunca "folga ok" por falta de leitura
  dflt=$(grep -o 'BALLAST_BURN_SECS:-[0-9]*' "$T/qm/queima.sh" 2>/dev/null | head -n 1 | grep -o '[0-9]*$')
  prazo=$(awk -F'\t' '$1 == "queima" { print $5 }' "$HERE/hetzner-ballast.items.txt" 2>/dev/null)
  case "$dflt$prazo" in ''|*[!0-9]*) folga=0 ;; *) [ -n "$dflt" ] && [ -n "$prazo" ] && [ $((dflt + 60)) -le "$prazo" ] && folga=1 || folga=0 ;; esac
  check "burn: o tempo padrão ($dflt s) fica pelo menos 60 s abaixo do prazo da linha queima do registro ($prazo s)" "1" "$folga"
}

# ── g_mut ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
addengine() {  # motor e jaula de MENTIRA no main de brinquedo (o que o motor imprime e com que rc vem de FAKE_MODE; cada chamada fica em $W/engine.log)
  local s="$SRC/.gascity-gastown-hq/scripts"; mkdir -p "$s"; : > "$s/hq-sandbox-run.py"
  cat > "$s/hq-mutate.py" <<'PYE'
import json, os, signal, sys, time
open(os.environ["FAKE_LOG"], "a").write(" ".join(sys.argv[1:]) + "\n")
mode = os.environ.get("FAKE_MODE", "completo")
def out(d, rc):
    print(json.dumps(d), flush=True); sys.exit(rc)
a = sys.argv[1:]
if "--work" not in a or not os.path.isdir(a[a.index("--work") + 1]): out({"result": "work-ausente"}, 2)
if mode == "completo":   # uma linha velha antes, o resumo, lixo JSON depois: vale o ÚLTIMO com `result`
    print(json.dumps({"result": "stale"})); print(json.dumps({"result": "completo", "mutants_run": 3, "survivors": [{"id": "m1", "file": "scripts/a.sh", "line": 7}]})); out({"x": 1}, 0)
if mode == "novidade": out({"result": "sem-novidade"}, 0)
if mode == "sn3": out({"result": "sem-novidade"}, 3)
if mode == "cob": out({"result": "sem-cobertura", "nao_sei": 1, "restam": 5, "perdidos": ["x"]}, 0)
if mode == "jaula": out({"result": "sem-jaula"}, 97)
if mode == "rc5": out({"result": "completo"}, 5)
if mode == "lixo":
    print("lixo"); print("boom", file=sys.stderr); sys.exit(1)
if mode == "term":   # o TERM só chega aqui pelo trap do item; a árvore NÃO pode sair antes de este ENGINE-DONE
    def h(*_):
        time.sleep(1); open(os.environ["RG_CALLS"], "a").write("ENGINE-DONE\n"); out({"result": "interrompido"}, 143)
    signal.signal(signal.SIGTERM, h); open(os.environ["FAKE_LOG"] + ".up", "w").close(); time.sleep(12); out({"result": "completo"}, 0)
PYE
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m motor && git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"
}
newmut() { newrig; : > "$W/engine.log"; rm -f "$W/engine.log.up" "$W/py.crash"; addengine; }
runmut() {  # runmut [VAR=valor…] → $OUT, $RC (BALLAST_CORES=2: o padrão é 4 slots)
  RDN=$((${RDN:-0}+1)); RD="$T/rd$N.$RDN"; mkdir -p "$RD"
  OUT=$(env PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" FAKE_LOG="$W/engine.log" RG_CALLS="$W/rg.calls" "$@" bash "$ITEMS/hq-mutants.sh" 2>"$W/err"); RC=$?
}
eng() { grep -c -F -- "$1" "$W/engine.log"; }   # quantas chamadas do motor levaram o trecho
g_mut() {
  local tip tr idle
  newmut; runmut FAKE_MODE=completo; tip=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main); tr="$GR/gascity/wt/ballast-hqm/.gascity-gastown-hq"; idle="$BH/hq-mutants.idle"
  check "mut: rodada → rc 0, result completo (a ÚLTIMA linha JSON com result: nem a velha antes, nem o lixo depois)" "0 completo" "$RC $(sj result)"
  check "mut: o resumo traz o sobrevivente do motor, o pull, slots (2 × núcleos), budget_s e engine_rc" "m1 ok 4 1800 0" "$(sj survivors.0.id) $(sj pull) $(sj slots) $(sj budget_s) $(sj engine_rc)"
  check "mut: o resumo traz a ponta (9 letras) e é UMA linha BALLAST-SUMMARY só" "${tip:0:9} 1" "$(sj main) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"
  check "mut: o motor recebe a árvore NOVA (a do ballast-hqm) e a jaula DELA" "1 1" "$(eng "sweep --tree $tr ") $(eng "--jail $tr/scripts/hq-sandbox-run.py ")"
  check "mut: o estado fica em \$BALLAST_HOME (o rodízio sobrevive entre rodadas; no run-dir recomeçaria do zero) e o --work no run-dir" "1 1" "$(eng "--state $BH/hq-mutants.state.json ") $(eng "--work $RD/work ")"
  check "mut: --slots 4 (2 × os 2 núcleos) e --budget-s 1800 (o padrão)" "1 1" "$(eng "--slots 4 ") $(eng "--budget-s 1800")"
  check "mut: ao fim a árvore sai (wt-rm), nenhuma branch worker/* sobra, e completo NÃO grava marcador de ocioso" "1 0 0" "$(grep -c '^wt-rm gascity ballast-hqm' "$W/rg.calls") $(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ') $([ -e "$idle" ] && echo 1 || echo 0)"
  : > "$W/engine.log"; runmut FAKE_MODE=completo HQ_MUTANTS_SLOTS=abc HQ_MUTANTS_BUDGET_S=xyz
  check "mut: HQ_MUTANTS_SLOTS e HQ_MUTANTS_BUDGET_S que não são inteiros voltam ao padrão (4 slots, 1800 s)" "1 1" "$(eng "--slots 4 ") $(eng "--budget-s 1800")"
  : > "$W/engine.log"; runmut FAKE_MODE=completo HQ_MUTANTS_SLOTS=99 HQ_MUTANTS_BUDGET_S=5
  check "mut: slots acima de 16 cortam em 16; prazo abaixo de 60 s sobe a 60" "1 1" "$(eng "--slots 16 ") $(eng "--budget-s 60")"
  : > "$W/engine.log"; runmut FAKE_MODE=completo HQ_MUTANTS_SLOTS=3 HQ_MUTANTS_BUDGET_S=90
  check "mut: HQ_MUTANTS_SLOTS=3 e HQ_MUTANTS_BUDGET_S=90 valem" "1 1" "$(eng "--slots 3 ") $(eng "--budget-s 90")"

  newmut; runmut FAKE_MODE=novidade; tip=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)
  check "mut: motor sem-novidade (rc 0) → rc 0 e o marcador de ocioso guarda a ponta" "0 sem-novidade $tip" "$RC $(sj result) $(cat "$BH/hq-mutants.idle" 2>/dev/null)"
  : > "$W/engine.log"; runmut FAKE_MODE=completo
  check "mut: mesma ponta com o marcador de menos de 6 h → sem-novidade sem criar árvore e sem chamar o motor" "0 sem-novidade 1 0" "$RC $(sj result) $(grep -c '^wt-add' "$W/rg.calls") $(wc -l < "$W/engine.log" | tr -d ' ')"
  touch -t 202001010000 "$BH/hq-mutants.idle"; runmut FAKE_MODE=completo
  check "mut: marcador de ocioso de mais de 6 h (um alvo pulado por base-vermelha volta em 2 dias) → roda de novo" "completo 1" "$(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  runmut FAKE_MODE=novidade; newcommit z.selftest.sh 0; : > "$W/engine.log"; runmut FAKE_MODE=completo
  check "mut: ponta nova (commit no main) → roda de novo apesar do marcador" "completo 1" "$(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newmut; runmut FAKE_MODE=sn3
  check "mut: motor que diz sem-novidade mas sai com rc 3 → exit 3 e SEM marcador (não houve rodada)" "3 sem-novidade 0" "$RC $(sj result) $([ -e "$BH/hq-mutants.idle" ] && echo 1 || echo 0)"
  newmut; runmut FAKE_MODE=cob
  check "mut: motor sem-cobertura (rc 0: nada examinado) → rc 0, nao_sei/restam/perdidos do motor passam e SEM marcador de ocioso (a seguinte tenta de novo)" "0 sem-cobertura 1 5 x 0" "$RC $(sj result) $(sj nao_sei) $(sj restam) $(sj perdidos.0) $([ -e "$BH/hq-mutants.idle" ] && echo 1 || echo 0)"
  newmut; runmut FAKE_MODE=jaula
  check "mut: motor sem-jaula (rc 97) → o 97 passa adiante, resumo sem-jaula, sem marcador" "97 sem-jaula 0" "$RC $(sj result) $([ -e "$BH/hq-mutants.idle" ] && echo 1 || echo 0)"
  newmut; runmut FAKE_MODE=rc5
  check "mut: rc que o motor não tem (5) → exit 3 e engine_rc 5 no resumo" "3 5" "$RC $(sj engine_rc)"
  newmut; runmut FAKE_MODE=lixo
  check "mut: motor que morre sem JSON → exit 3, motor-sem-resumo com a última linha do stderr, engine_rc 1, UMA linha de resumo" "3 motor-sem-resumo boom 1 1" "$RC $(sj result) $(sj stderr) $(sj engine_rc) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"
  newmut; : > "$W/py.crash"; runmut FAKE_MODE=completo; rm -f "$W/py.crash"
  check "mut: o passo do resumo que quebra (python rc 1, sem saída) → exit 3 com resumo-falhou (uma linha), nunca rc 1 mudo" "3 resumo-falhou 0 1" "$RC $(sj result) $(sj engine_rc) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"

  newrig; : > "$W/engine.log"; runmut FAKE_MODE=completo
  check "mut: o main sem o motor (ainda é o 5.6.2) → exit 3 sem-motor, motor não chamado, árvore removida" "3 sem-motor 0 1" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ') $(grep -c '^wt-rm gascity ballast-hqm' "$W/rg.calls")"
  newmut; git -C "$SRC" rm -q .gascity-gastown-hq/scripts/hq-sandbox-run.py; git -C "$SRC" commit -q -m sem-jaula; git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"; runmut FAKE_MODE=completo
  check "mut: o motor sem a jaula na árvore → exit 3 sem-motor (nunca roda mutante sem jaula)" "3 sem-motor 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newmut; git -C "$SRC" rm -rq .gascity-gastown-hq/scripts; git -C "$SRC" commit -q -m sem-scripts; git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"; runmut FAKE_MODE=completo
  check "mut: árvore sem scripts/ → exit 3 arvore-sem-scripts" "3 arvore-sem-scripts" "$RC $(sj result)"
  newmut; : > "$W/rg.pull.fail"; runmut FAKE_MODE=completo
  check "mut: pull que falha segue com o clone que há e diz pull=falhou (rc 0)" "0 falhou completo" "$RC $(sj pull) $(sj result)"
  newmut; git -C "$GR/gascity/repo.git" update-ref -d refs/remotes/origin/main; runmut FAKE_MODE=completo
  check "mut: clone sem origin/main → exit 3 (sem-main), motor não chamado" "3 sem-main 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newmut; : > "$W/rg.wtadd.fail"; runmut FAKE_MODE=completo
  check "mut: wt-add que falha → exit 3 wt-add-falhou, motor não chamado" "3 wt-add-falhou 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  # sobra de rodada morta com SIGKILL (árvore + branch na ponta velha): a seguinte testa a ponta NOVA
  newmut; old=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main); git -C "$GR/gascity/repo.git" worktree add -q -b worker/ballast-hqm "$GR/gascity/wt/ballast-hqm" "$old"
  newcommit y.selftest.sh 0; runmut FAKE_MODE=completo; tip=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)
  check "mut: sobra de rodada morta (árvore + branch na ponta velha) → a rodada seguinte testa a ponta NOVA e nenhuma branch sobra" "0 ${tip:0:9} 0" "$RC $(sj main) $(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"

  newmut; RDN=$((RDN+1)); RD="$T/rd$N.k"; mkdir -p "$RD"
  PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" FAKE_LOG="$W/engine.log" RG_CALLS="$W/rg.calls" FAKE_MODE=term bash "$ITEMS/hq-mutants.sh" > "$W/killm.out" 2>&1 & kp=$!   # sem subshell: $kp é o próprio item
  i=0; while [ "$i" -lt 100 ] && [ ! -e "$W/engine.log.up" ]; do sleep 0.2; i=$((i+1)); done
  kill -TERM "$kp" 2>/dev/null; wait "$kp" 2>/dev/null; krc=$?
  i=0; while [ "$i" -lt 100 ] && ! grep -q '^wt-rm gascity ballast-hqm' "$W/rg.calls"; do sleep 0.2; i=$((i+1)); done
  check "mut: TERM no meio → exit 143 e o marcador de ocioso não é gravado" "143 0" "$krc $([ -e "$BH/hq-mutants.idle" ] && echo 1 || echo 0)"
  check "mut: TERM no meio → a árvore e a branch saem DEPOIS de o motor acabar de parar (ENGINE-DONE antes do wt-rm: com a árvore fora, mutante em voo perderia a cópia)" "1 1 0" "$([ "$(grep -n '^ENGINE-DONE' "$W/rg.calls" | cut -d: -f1 | head -n 1)" -lt "$(grep -n '^wt-rm gascity ballast-hqm' "$W/rg.calls" | cut -d: -f1 | head -n 1)" ] 2>/dev/null && echo 1 || echo 0) $(grep -c '^wt-rm gascity ballast-hqm' "$W/rg.calls") $(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"

  # o registro REAL (hetzner-ballast.items.txt do repo): a linha hq-mutants
  local R="$HERE/hetzner-ballast.items.txt" cmd rss cores prazo cdn dflt folga ln_w ln_m
  rf() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n && NF == 8 { print $c }' "$R" 2>/dev/null; }   # campo c da linha n (8 colunas); vazio se a linha falta
  cores=$(rf hq-mutants 3); rss=$(rf hq-mutants 4); prazo=$(rf hq-mutants 5); cdn=$(rf hq-mutants 6); cmd=$(rf hq-mutants 8)
  case "$cores$rss$prazo$cdn" in ''|*[!0-9]*) cores=0 ;; esac
  check "mut: a linha hq-mutants do registro é papel work, de 8 colunas, com núcleos FIXOS (inteiro >= 2: o auto levaria o orçamento inteiro) e o comando $cmd executável na pasta de itens" "work 1 1" "$(rf hq-mutants 2) $([ "$cores" -ge 2 ] && echo 1 || echo 0) $([ -n "$cmd" ] && [ -x "$ITEMS/$cmd" ] && echo 1 || echo 0)"
  check "mut: exige o hetzner-remote-git.sh (sem ele o item nem pull faz)" "1" "$(rf hq-mutants 7 | tr ',' '\n' | grep -c -x -F 'exec:~/gt-remote/bin/hetzner-remote-git.sh')"
  dflt=$(grep -o 'HQ_MUTANTS_BUDGET_S:-[0-9]*' "$ITEMS/hq-mutants.sh" 2>/dev/null | head -n 1 | grep -o '[0-9]*$')
  case "$dflt$prazo" in ''|*[!0-9]*) folga=0 ;; *) [ -n "$dflt" ] && [ "$((dflt + 1000))" -le "$prazo" ] && folga=1 || folga=0 ;; esac
  check "mut: o prazo do registro ($prazo s) passa o tempo do motor ($dflt s) em >= 1000 s (um mutante em voo leva até 930 s, e o prazo mata com rc 124)" "1" "$folga"
  check "mut: espera de 120 a 600 s depois de uma rodada (cada pergunta é um pull ao espelho, que só atualiza a cada ~5 min)" "1" "$([ "$cdn" -ge 120 ] 2>/dev/null && [ "$cdn" -le 600 ] && echo 1 || echo 0)"
  check "mut: $(rf wa-suite 3) núcleos do wa-suite + $cores do hq-mutants cabem no orçamento de 9 (16 - 6 de sessões - 1 de reserva): ao lado do wa-suite, que é o que roda quase sempre" "1" "$([ "$cores" -ge 1 ] && [ $(( $(rf wa-suite 3) + cores )) -le 9 ] 2>/dev/null && echo 1 || echo 0)"
  check "mut: rss_mb ($rss) cobre 2 slots por núcleo × 150 MB (o dobro dos ~76 MB medidos por slot) + 512 de base" "1" "$([ "$rss" -ge $((cores * 2 * 150 + 512)) ] 2>/dev/null && echo 1 || echo 0)"
  ln_w=$(grep -n '^wa-suite	' "$R" | cut -d: -f1); ln_m=$(grep -n '^hq-mutants	' "$R" | cut -d: -f1)
  check "mut: a linha hq-mutants vem DEPOIS do wa-suite (o governo começa os work na ordem do arquivo: com os dois prontos o wa-suite não pode ficar de fora)" "1" "$([ -n "$ln_w" ] && [ -n "$ln_m" ] && [ "$ln_m" -gt "$ln_w" ] && echo 1 || echo 0)"
}

# ── g_wam ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# wa-mutants.sh tem DOIS rigs: o WA (whatsapp_automation) dá a árvore que se muta, o hq (gascity) dá o motor — os TRÊS arquivos saem do origin/main dele por git show, sem árvore do hq.
newwam() {  # newmut + hq-mutate-wa.py (cópia do motor de mentira) e jaula NÃO vazia no main do hq + o rig do WA (repo bare com lib/ e tests/) + um python de venv de mentira
  newmut
  local s="$SRC/.gascity-gastown-hq/scripts"; cp "$s/hq-mutate.py" "$s/hq-mutate-wa.py"; echo '# jaula de brinquedo' > "$s/hq-sandbox-run.py"
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m wa-motor && git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"
  WSRC="$T/wsrc$N"; git init -q "$WSRC"; mkdir -p "$WSRC/lib" "$WSRC/tests"; echo 'x = 1' > "$WSRC/lib/a.py"; echo 'import a' > "$WSRC/tests/test_a.py"
  git -C "$WSRC" add -A && git -C "$WSRC" commit -q -m wa && git clone -q --bare "$WSRC" "$GR/whatsapp_automation/repo.git" 2> /dev/null
  git -C "$GR/whatsapp_automation/repo.git" update-ref refs/remotes/origin/main "$(git -C "$WSRC" rev-parse HEAD)"
  mkdir -p "$T/venv/bin"; printf '#!/bin/sh\n' > "$T/venv/bin/python"; chmod +x "$T/venv/bin/python"
}
wanew() {  # wanew ARQUIVO — commit novo no main do WA (o espelho do nó avança)
  echo 'x = 2' > "$WSRC/lib/$1"; git -C "$WSRC" add -A && git -C "$WSRC" commit -q -m novo-wa && git -C "$GR/whatsapp_automation/repo.git" fetch -q "$WSRC" "+HEAD:refs/remotes/origin/main"
}
wamain() { git -C "$WSRC" commit -q -m "$1" && git -C "$GR/whatsapp_automation/repo.git" fetch -q "$WSRC" "+HEAD:refs/remotes/origin/main"; }   # wamain MSG — grava o que está no índice do WA e avança o espelho
hqmain() { git -C "$SRC" commit -q -m "$1" && git -C "$GR/gascity/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"; }   # hqmain MSG — o mesmo para o main do hq
runwam() {  # runwam [VAR=valor…] → $OUT, $RC (BALLAST_CORES=2: o padrão é 2 slots, 1 por núcleo)
  RDN=$((${RDN:-0}+1)); RD="$T/rd$N.$RDN"; mkdir -p "$RD"
  OUT=$(env PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" BALLAST_WA_PYTHON="$T/venv/bin/python" FAKE_LOG="$W/engine.log" RG_CALLS="$W/rg.calls" "$@" bash "$ITEMS/wa-mutants.sh" 2>"$W/err"); RC=$?
}
g_wam() {
  local tip hqtip tr idle old R cmd rss cores prazo cdn dflt folga ln_w ln_h ln_m
  newwam; runwam FAKE_MODE=completo; tip=$(git -C "$GR/whatsapp_automation/repo.git" rev-parse refs/remotes/origin/main); hqtip=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)
  tr="$GR/whatsapp_automation/wt/ballast-wam"; idle="$BH/wa-mutants.idle"
  check "wam: rodada → rc 0, result completo (a ÚLTIMA linha JSON com result), o sobrevivente do motor, pull e hqpull ok, slots (1 por núcleo: 2), budget_s e engine_rc" "0 completo m1 ok ok 2 1800 0" "$RC $(sj result) $(sj survivors.0.id) $(sj pull) $(sj hqpull) $(sj slots) $(sj budget_s) $(sj engine_rc)"
  check "wam: o resumo traz a ponta do WA e a do hq (9 letras cada) e é UMA linha BALLAST-SUMMARY só" "${tip:0:9} ${hqtip:0:9} 1" "$(sj main) $(sj hq) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"
  check "wam: o motor recebe a árvore do WA (ballast-wam), a jaula do run-dir, o python do venv, o estado em \$BALLAST_HOME (o rodízio sobrevive entre rodadas) e o --work no run-dir" "1 1 1 1 1" "$(eng "sweep --tree $tr ") $(eng "--jail $RD/engine/hq-sandbox-run.py ") $(eng "--python $T/venv/bin/python ") $(eng "--state $BH/wa-mutants.state.json ") $(eng "--work $RD/work ")"
  check "wam: os TRÊS arquivos do motor saem do main do hq para \$RD/engine (iguais aos do main) e o hq NÃO ganha árvore" "hq-mutate-wa.py hq-mutate.py hq-sandbox-run.py 1 1 1 0" "$(LC_ALL=C ls "$RD/engine" | tr '\n' ' ')$(for f in hq-mutate.py hq-mutate-wa.py hq-sandbox-run.py; do cmp -s "$RD/engine/$f" "$SRC/.gascity-gastown-hq/scripts/$f" && echo -n "1 " || echo -n "0 "; done)$(grep -c '^wt-add gascity' "$W/rg.calls")"
  check "wam: o WA ganha a árvore ballast-wam e ela sai no fim (wt-rm), nenhuma branch worker/* sobra no WA, e completo NÃO grava marcador de ocioso" "1 1 0 0" "$(grep -c '^wt-add whatsapp_automation ballast-wam main' "$W/rg.calls") $(grep -c '^wt-rm whatsapp_automation ballast-wam' "$W/rg.calls") $(git -C "$GR/whatsapp_automation/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ') $([ -e "$idle" ] && echo 1 || echo 0)"
  : > "$W/engine.log"; runwam FAKE_MODE=completo WA_MUTANTS_SLOTS=abc WA_MUTANTS_BUDGET_S=xyz
  check "wam: WA_MUTANTS_SLOTS e WA_MUTANTS_BUDGET_S que não são inteiros voltam ao padrão (2 slots, 1800 s)" "1 1" "$(eng "--slots 2 ") $(eng "--budget-s 1800")"
  : > "$W/engine.log"; runwam FAKE_MODE=completo WA_MUTANTS_SLOTS=99 WA_MUTANTS_BUDGET_S=5
  check "wam: slots acima de 16 cortam em 16; prazo abaixo de 60 s sobe a 60" "1 1" "$(eng "--slots 16 ") $(eng "--budget-s 60")"
  : > "$W/engine.log"; runwam FAKE_MODE=completo WA_MUTANTS_SLOTS=3 WA_MUTANTS_BUDGET_S=90
  check "wam: WA_MUTANTS_SLOTS=3 e WA_MUTANTS_BUDGET_S=90 valem" "1 1" "$(eng "--slots 3 ") $(eng "--budget-s 90")"
  : > "$W/engine.log"; runwam FAKE_MODE=completo BALLAST_CORES=abc
  check "wam: BALLAST_CORES que não é inteiro vale 2 (e os slots acompanham)" "1" "$(eng "--slots 2 ")"

  newwam; runwam FAKE_MODE=novidade; tip=$(git -C "$GR/whatsapp_automation/repo.git" rev-parse refs/remotes/origin/main); hqtip=$(git -C "$GR/gascity/repo.git" rev-parse refs/remotes/origin/main)
  check "wam: motor sem-novidade (rc 0) → rc 0 e o marcador de ocioso guarda o PAR de pontas (WA:hq)" "0 sem-novidade $tip:$hqtip" "$RC $(sj result) $(cat "$BH/wa-mutants.idle" 2>/dev/null)"
  : > "$W/engine.log"; runwam FAKE_MODE=completo
  check "wam: o mesmo par com o marcador de menos de 6 h → sem-novidade sem criar árvore e sem chamar o motor" "0 sem-novidade 1 0" "$RC $(sj result) $(grep -c '^wt-add' "$W/rg.calls") $(wc -l < "$W/engine.log" | tr -d ' ')"
  touch -t 202001010000 "$BH/wa-mutants.idle"; runwam FAKE_MODE=completo
  check "wam: marcador de ocioso de mais de 6 h (um alvo pulado por base-vermelha volta em 2 dias) → roda de novo" "completo 1" "$(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  runwam FAKE_MODE=novidade; wanew b.py; : > "$W/engine.log"; runwam FAKE_MODE=completo
  check "wam: ponta nova no main do WA → roda de novo apesar do marcador" "completo 1" "$(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  runwam FAKE_MODE=novidade; newcommit z.selftest.sh 0; : > "$W/engine.log"; runwam FAKE_MODE=completo
  check "wam: ponta nova no main do hq (o motor mudou) → roda de novo apesar do marcador" "completo 1" "$(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; runwam FAKE_MODE=sn3
  check "wam: motor que diz sem-novidade mas sai com rc 3 → exit 3 e SEM marcador (não houve rodada)" "3 sem-novidade 0" "$RC $(sj result) $([ -e "$BH/wa-mutants.idle" ] && echo 1 || echo 0)"
  newwam; runwam FAKE_MODE=cob
  check "wam: motor sem-cobertura (rc 0: nada examinado) → rc 0, nao_sei/restam/perdidos do motor passam e SEM marcador de ocioso (a seguinte tenta de novo)" "0 sem-cobertura 1 5 x 0" "$RC $(sj result) $(sj nao_sei) $(sj restam) $(sj perdidos.0) $([ -e "$BH/wa-mutants.idle" ] && echo 1 || echo 0)"
  newwam; runwam FAKE_MODE=jaula
  check "wam: motor sem-jaula (rc 97) → o 97 passa adiante, resumo sem-jaula, sem marcador" "97 sem-jaula 0" "$RC $(sj result) $([ -e "$BH/wa-mutants.idle" ] && echo 1 || echo 0)"
  newwam; runwam FAKE_MODE=rc5
  check "wam: rc que o motor não tem (5) → exit 3 e engine_rc 5 no resumo" "3 5" "$RC $(sj engine_rc)"
  newwam; runwam FAKE_MODE=lixo
  check "wam: motor que morre sem JSON → exit 3, motor-sem-resumo com a última linha do stderr, engine_rc 1, UMA linha de resumo" "3 motor-sem-resumo boom 1 1" "$RC $(sj result) $(sj stderr) $(sj engine_rc) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"
  newwam; : > "$W/py.crash"; runwam FAKE_MODE=completo; rm -f "$W/py.crash"
  check "wam: o passo do resumo que quebra (python rc 1, sem saída) → exit 3 com resumo-falhou (uma linha), nunca rc 1 mudo" "3 resumo-falhou 0 1" "$RC $(sj result) $(sj engine_rc) $(printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: ')"

  newrig; : > "$W/engine.log"; runwam FAKE_MODE=completo
  check "wam: sem rig do WA e sem motor no main do hq → exit 3, motor não chamado (o ambiente do nó ainda não está pronto)" "3 0" "$RC $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; git -C "$SRC" rm -q .gascity-gastown-hq/scripts/hq-mutate-wa.py; hqmain sem-wrapper; runwam FAKE_MODE=completo
  check "wam: o main do hq sem o wrapper (ainda é o 5.6.3) → exit 3 sem-motor dizendo qual falta, motor não chamado, o WA nem ganha árvore" "3 sem-motor hq-mutate-wa.py 0 0" "$RC $(sj result) $(sj falta) $(wc -l < "$W/engine.log" | tr -d ' ') $(grep -c '^wt-add' "$W/rg.calls")"
  newwam; : > "$SRC/.gascity-gastown-hq/scripts/hq-sandbox-run.py"; git -C "$SRC" add -A; hqmain jaula-vazia; runwam FAKE_MODE=completo
  check "wam: jaula VAZIA no main do hq → exit 3 sem-motor hq-sandbox-run.py (nunca roda mutante sem jaula)" "3 sem-motor hq-sandbox-run.py 0" "$RC $(sj result) $(sj falta) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; runwam FAKE_MODE=completo BALLAST_WA_PYTHON="$T/venv/bin/naoexiste"
  check "wam: sem o python do venv do WA → exit 3 preparo-ausente, motor não chamado, o WA nem ganha árvore" "3 preparo-ausente naoexiste 0 0" "$RC $(sj result) $(sj falta) $(wc -l < "$W/engine.log" | tr -d ' ') $(grep -c '^wt-add' "$W/rg.calls")"
  newwam; git -C "$WSRC" rm -rq tests; wamain sem-tests; runwam FAKE_MODE=completo
  check "wam: árvore do WA sem tests/ → exit 3 arvore-sem-testes, motor não chamado, a árvore sai" "3 arvore-sem-testes 0 1" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ') $(grep -c '^wt-rm whatsapp_automation ballast-wam' "$W/rg.calls")"
  newwam; git -C "$WSRC" rm -rq lib; wamain sem-lib; runwam FAKE_MODE=completo
  check "wam: árvore do WA com tests/ mas sem lib/ nem daemons/ → exit 3 arvore-sem-testes (não há o que mutar)" "3 arvore-sem-testes 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; git -C "$WSRC" mv lib daemons; wamain so-daemons; runwam FAKE_MODE=completo
  check "wam: árvore do WA só com daemons/ (sem lib/) vale: rodada completa" "0 completo 1" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; : > "$W/rg.pull.fail"; runwam FAKE_MODE=completo
  check "wam: pull que falha nos dois rigs segue com os clones que há e diz pull=falhou hqpull=falhou (rc 0)" "0 falhou falhou completo" "$RC $(sj pull) $(sj hqpull) $(sj result)"
  newwam; : > "$W/rg.pull.fail.whatsapp_automation"; runwam FAKE_MODE=completo
  check "wam: só o pull do WA falha → pull=falhou, hqpull=ok" "0 falhou ok" "$RC $(sj pull) $(sj hqpull)"
  newwam; : > "$W/rg.pull.fail.gascity"; runwam FAKE_MODE=completo
  check "wam: só o pull do hq falha → pull=ok, hqpull=falhou" "0 ok falhou" "$RC $(sj pull) $(sj hqpull)"
  newwam; git -C "$GR/whatsapp_automation/repo.git" update-ref -d refs/remotes/origin/main; runwam FAKE_MODE=completo
  check "wam: clone do WA sem origin/main → exit 3 (sem-main), motor não chamado" "3 sem-main 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; git -C "$GR/gascity/repo.git" update-ref -d refs/remotes/origin/main; runwam FAKE_MODE=completo
  check "wam: clone do hq sem origin/main (não há de onde tirar o motor) → exit 3 (sem-main), motor não chamado" "3 sem-main 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  newwam; : > "$W/rg.wtadd.fail"; runwam FAKE_MODE=completo
  check "wam: wt-add que falha → exit 3 wt-add-falhou, motor não chamado" "3 wt-add-falhou 0" "$RC $(sj result) $(wc -l < "$W/engine.log" | tr -d ' ')"
  # sobra de rodada morta com SIGKILL (árvore + branch na ponta velha do WA): a seguinte testa a ponta NOVA
  newwam; old=$(git -C "$GR/whatsapp_automation/repo.git" rev-parse refs/remotes/origin/main); git -C "$GR/whatsapp_automation/repo.git" worktree add -q -b worker/ballast-wam "$GR/whatsapp_automation/wt/ballast-wam" "$old"
  wanew c.py; runwam FAKE_MODE=completo; tip=$(git -C "$GR/whatsapp_automation/repo.git" rev-parse refs/remotes/origin/main)
  check "wam: sobra de rodada morta (árvore + branch na ponta velha do WA) → a rodada seguinte testa a ponta NOVA e nenhuma branch sobra" "0 ${tip:0:9} 0" "$RC $(sj main) $(git -C "$GR/whatsapp_automation/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"

  newwam; RDN=$((RDN+1)); RD="$T/rd$N.k"; mkdir -p "$RD"
  PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" BALLAST_WA_PYTHON="$T/venv/bin/python" FAKE_LOG="$W/engine.log" RG_CALLS="$W/rg.calls" FAKE_MODE=term bash "$ITEMS/wa-mutants.sh" > "$W/killm.out" 2>&1 & kp=$!   # sem subshell: $kp é o próprio item
  i=0; while [ "$i" -lt 100 ] && [ ! -e "$W/engine.log.up" ]; do sleep 0.2; i=$((i+1)); done
  kill -TERM "$kp" 2>/dev/null; wait "$kp" 2>/dev/null; krc=$?
  i=0; while [ "$i" -lt 100 ] && ! grep -q '^wt-rm whatsapp_automation ballast-wam' "$W/rg.calls"; do sleep 0.2; i=$((i+1)); done
  check "wam: TERM no meio → exit 143 e o marcador de ocioso não é gravado" "143 0" "$krc $([ -e "$BH/wa-mutants.idle" ] && echo 1 || echo 0)"
  check "wam: TERM no meio → a árvore e a branch do WA saem DEPOIS de o motor acabar de parar (ENGINE-DONE antes do wt-rm: com a árvore fora, mutante em voo perderia a cópia)" "1 1 0" "$([ "$(grep -n '^ENGINE-DONE' "$W/rg.calls" | cut -d: -f1 | head -n 1)" -lt "$(grep -n '^wt-rm whatsapp_automation ballast-wam' "$W/rg.calls" | cut -d: -f1 | head -n 1)" ] 2>/dev/null && echo 1 || echo 0) $(grep -c '^wt-rm whatsapp_automation ballast-wam' "$W/rg.calls") $(git -C "$GR/whatsapp_automation/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"

  # o registro REAL (hetzner-ballast.items.txt do repo): a linha wa-mutants
  R="$HERE/hetzner-ballast.items.txt"
  rf() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n && NF == 8 { print $c }' "$R" 2>/dev/null; }   # campo c da linha n (8 colunas); vazio se a linha falta
  cores=$(rf wa-mutants 3); rss=$(rf wa-mutants 4); prazo=$(rf wa-mutants 5); cdn=$(rf wa-mutants 6); cmd=$(rf wa-mutants 8)
  case "$cores$rss$prazo$cdn" in ''|*[!0-9]*) cores=0 ;; esac
  check "wam: a linha wa-mutants do registro é papel work, de 8 colunas, com núcleos FIXOS (inteiro >= 2: o auto levaria o orçamento inteiro) e o comando $cmd executável na pasta de itens" "work 1 1" "$(rf wa-mutants 2) $([ "$cores" -ge 2 ] && echo 1 || echo 0) $([ -n "$cmd" ] && [ -x "$ITEMS/$cmd" ] && echo 1 || echo 0)"
  check "wam: exige o hetzner-remote-git.sh (sem ele o item nem pull faz), o python do venv do WA e a ausência do vazamento medido pelo wa-suite (noflag:wa-suite.leak)" "1 1 1" "$(rf wa-mutants 7 | tr ',' '\n' | grep -c -x -F 'exec:~/gt-remote/bin/hetzner-remote-git.sh') $(rf wa-mutants 7 | tr ',' '\n' | grep -c -x -F 'exec:~/gt-remote/venv-wa/bin/python') $(rf wa-mutants 7 | tr ',' '\n' | grep -c -x -F 'noflag:wa-suite.leak')"
  dflt=$(grep -o 'WA_MUTANTS_BUDGET_S:-[0-9]*' "$ITEMS/wa-mutants.sh" 2>/dev/null | head -n 1 | grep -o '[0-9]*$')
  case "$dflt$prazo" in ''|*[!0-9]*) folga=0 ;; *) [ -n "$dflt" ] && [ "$((dflt + 1000))" -le "$prazo" ] && folga=1 || folga=0 ;; esac
  check "wam: o prazo do registro ($prazo s) passa o tempo do motor ($dflt s) em >= 1000 s (um mutante em voo leva até 930 s, e o prazo mata com rc 124)" "1" "$folga"
  check "wam: espera de 120 a 600 s depois de uma rodada (cada pergunta é um pull ao espelho, que só atualiza a cada ~5 min)" "1" "$([ "$cdn" -ge 120 ] 2>/dev/null && [ "$cdn" -le 600 ] && echo 1 || echo 0)"
  check "wam: $(rf wa-suite 3) núcleos do wa-suite + $cores do wa-mutants cabem no orçamento de 9 (16 - 6 de sessões - 1 de reserva), e $cores + $(rf hq-mutants 3) do hq-mutants também (os dois de mutantes rodam juntos)" "1 1" "$([ "$cores" -ge 1 ] && [ $(( $(rf wa-suite 3) + cores )) -le 9 ] 2>/dev/null && echo 1 || echo 0) $([ "$cores" -ge 1 ] && [ $(( $(rf hq-mutants 3) + cores )) -le 9 ] 2>/dev/null && echo 1 || echo 0)"
  check "wam: rss_mb ($rss) cobre 1 GB por slot (1 slot por núcleo; ESTIMADO, o pytest do WA importa o app inteiro: o 1º pico no results.jsonl corrige)" "1" "$([ "$rss" -ge $((cores * 1024)) ] 2>/dev/null && echo 1 || echo 0)"
  ln_w=$(grep -n '^wa-suite	' "$R" | cut -d: -f1); ln_h=$(grep -n '^hq-mutants	' "$R" | cut -d: -f1); ln_m=$(grep -n '^wa-mutants	' "$R" | cut -d: -f1)
  check "wam: a linha wa-mutants vem DEPOIS do wa-suite e do hq-mutants (o governo começa os work na ordem do arquivo: o novo não pode furar a fila dos que já rodam)" "1" "$([ -n "$ln_w" ] && [ -n "$ln_h" ] && [ -n "$ln_m" ] && [ "$ln_m" -gt "$ln_w" ] && [ "$ln_m" -gt "$ln_h" ] && echo 1 || echo 0)"
}

if [ -n "${HBI_MUTANT:-}" ]; then for g in ${HBI_MUTANT_G:-hq burn mut wam}; do "g_$g"; done; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HBI_ONLY:-}" ]; then "g_$HBI_ONLY"; echo "── $((n - fails))/$n ok (só g_$HBI_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_hq; g_burn; g_mut; g_wam

[ -n "${HBI_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # ARQUIVO@@DESCRIÇÃO@@ANTES@@DEPOIS — troca EXATAMENTE uma ocorrência numa cópia da pasta de itens
  cat > "$T/mutants.txt" <<'MUT'
hq-selftests.sh@@sem a 2ª tentativa dos reprovados (flaky vira reprovado)@@awk -F'\t' '$2 != 0 && $2 != 97 && $2 != 124 && $2 != 137 {print $1}' "$RD/results.tsv" > "$RD/retry.txt"@@: > "$RD/retry.txt"
hq-selftests.sh@@ambiente (rc 97) conta como reprovado@@    elif rc == 97:@@    elif rc == 9999:
hq-selftests.sh@@prazo (rc 124/137) conta como reprovado@@    elif rc in (124, 137):@@    elif rc in (9999,):
hq-selftests.sh@@a ponta testada nunca é gravada@@staged.append(stage(last_p, full + "\n"))@@pass
hq-selftests.sh@@a lista só-macOS é ignorada (skip nunca vale)@@    case "$rel" in $pat) skip=1; break ;; esac@@    case "$rel" in $pat) skip=0; break ;; esac
hq-selftests.sh@@lista só-macOS vazia é aceita (roda tudo)@@[ -n "$pats" ] || { say "lista só-macOS ausente@@[ -n "x" ] || { say "lista só-macOS ausente
hq-selftests.sh@@a comparação ignora a rodada anterior (tudo que reprova é novo)@@new = sorted(set(kind["fail"]) - prev) if compare == "ok" else []@@new = sorted(set(kind["fail"])) if compare == "ok" else []
hq-selftests.sh@@a árvore de trabalho nunca é removida@@cleanup() { [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@cleanup() { :; }
hq-selftests.sh@@a branch worker/* não sai no fim da rodada@@"$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@"$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; }; }
hq-selftests.sh@@a branch velha não sai antes do wt-add (a rodada testaria a ponta de outro dia)@@branch_rm
if ! timeout 900 "$RG" wt-add@@if ! timeout 900 "$RG" wt-add
hq-selftests.sh@@sem-novidade nunca é reconhecido@@if [ "$main" = "$(cat "$LAST" 2> /dev/null)" ]; then@@if false; then
hq-selftests.sh@@wt-add que falha segue em frente@@if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then@@if false; then
hq-selftests.sh@@clone sem origin/main segue em frente@@[ -n "$main" ] || { say "o clone não tem origin/main"; summary sem-main pull=$pull; exit 3; }@@main=${main:-0000000000}
hq-selftests.sh@@pull que falha é dado como ok@@2>&1 || pull=falhou@@2>&1 || pull=ok
queima.sh@@os laços ficam para trás no TERM@@trap 'kill $pids 2>/dev/null; exit 143' TERM INT@@trap 'exit 143' TERM INT
queima.sh@@BALLAST_CORES inválido é aceito@@case "$n" in ''|*[!0-9]*|0) echo@@case "$n" in ''|*[!0-9]*) echo
queima.sh@@não termina sozinho (espera os laços, que não têm fim; o prazo do registro o mataria com rc 124)@@wait "$sp"; rc=$?   # só o relógio@@wait; rc=$?   # só o relógio
queima.sh@@termina sozinho mas com rc 1 (o governo cobraria o cooldown de falha)@@exit 1; }
exit 0@@exit 1; }
exit 1
queima.sh@@o relógio que falha (sleep rc != 0) conta como fim normal@@[ "$rc" -eq 0 ] || { echo "queima: o relógio@@[ "$rc" -eq 99 ] && { echo "queima: o relógio
queima.sh@@o tempo padrão passa do prazo do registro (volta o rc 124)@@${BALLAST_BURN_SECS:-3300}@@${BALLAST_BURN_SECS:-3600}
queima.sh@@BALLAST_BURN_SECS inválido é aceito@@case "$secs" in ''|*[!0-9]*|0) echo@@case "$secs" in 'zzz') echo
hq-selftests.sh@@falha do passo final (resumo e gravação do estado) vira rc 0@@[ "$prc" -ne 0 ] || exit 0@@exit 0
hq-selftests.sh@@alvo de estado que é pasta só falha na troca, DEPOIS do resumo (sem a checagem antes)@@    if os.path.isdir(path):@@    if False:
hq-selftests.sh@@o passo do resumo que morre sem imprimir não deixa resumo nenhum@@summary resumo-falhou main="${tested:0:9}" pull="$pull" python_rc="$prc"@@:
hq-selftests.sh@@a lista só-macOS não é aparada nas pontas@@pat=${pat#"${pat%%[![:space:]]*}"}; pat=${pat%"${pat##*[![:space:]]}"}@@:
hq-mutants.sh@@o marcador de ocioso nunca é reconhecido@@if [ "$main" = "$(cat "$IDLE" 2> /dev/null)" ] &&@@if false &&
hq-mutants.sh@@o marcador de ocioso vale para sempre (sem o prazo de 6 h)@@ && [ -n "$(find "$IDLE" -mmin -360 2> /dev/null)" ]; then@@; then
hq-mutants.sh@@o marcador é gravado em qualquer resultado@@if rec["result"] == "sem-novidade" and erc == 0:@@if True:
hq-mutants.sh@@o marcador é gravado com o motor em rc != 0@@if rec["result"] == "sem-novidade" and erc == 0:@@if rec["result"] == "sem-novidade":
hq-mutants.sh@@o marcador guarda outra coisa que a ponta@@f.write(full + "\n")@@f.write("x\n")
hq-mutants.sh@@o rc do motor vira 0@@rc = erc if erc in (0, 97, 143) else 3@@rc = 0
hq-mutants.sh@@rc que o motor não tem passa adiante@@rc = erc if erc in (0, 97, 143) else 3@@rc = erc
hq-mutants.sh@@o 97 do motor vira 3@@(0, 97, 143)@@(0, 143)
hq-mutants.sh@@motor sem resumo sai com rc 0@@"stderr": tail}
    rc = 3@@"stderr": tail}
    rc = 0
hq-mutants.sh@@vale a PRIMEIRA linha JSON do motor, não a última@@for line in reversed(@@for line in (
hq-mutants.sh@@linha JSON sem result é aceita como resumo@@if isinstance(v, dict) and "result" in v:@@if True:
hq-mutants.sh@@a árvore de trabalho nunca é removida@@cleanup() { [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@cleanup() { :; }
hq-mutants.sh@@a branch worker/* não sai no fim da rodada@@"$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@"$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; }; }
hq-mutants.sh@@a branch velha não sai antes do wt-add (a rodada testaria a ponta de outro dia)@@branch_rm
if ! timeout 900 "$RG" wt-add@@if ! timeout 900 "$RG" wt-add
hq-mutants.sh@@wt-add que falha segue em frente@@if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then@@if false; then
hq-mutants.sh@@clone sem origin/main segue em frente@@[ -n "$main" ] || { say "o clone não tem origin/main"; summary sem-main pull=$pull; exit 3; }@@main=${main:-0000000000}
hq-mutants.sh@@pull que falha é dado como ok@@2>&1 || pull=falhou@@2>&1 || pull=ok
hq-mutants.sh@@árvore sem o motor ou a jaula segue em frente@@[ -f "$ENG" ] && [ -f "$JAIL" ] || {@@true || {
hq-mutants.sh@@árvore sem scripts/ segue em frente@@[ -d "$TREE/scripts" ] || {@@true || {
hq-mutants.sh@@o TERM não espera o motor acabar (a árvore sai de baixo dos mutantes em voo)@@kill -TERM "$ep" 2>/dev/null; wait "$ep" 2>/dev/null; }; exit 143'@@kill -TERM "$ep" 2>/dev/null; }; exit 143'
hq-mutants.sh@@o TERM não chega ao motor@@{ kill -TERM "$ep" 2>/dev/null; wait "$ep"@@{ wait "$ep"
hq-mutants.sh@@o item não espera o motor@@wait "$ep"; erc=$?; ep=""@@erc=0; ep=""
hq-mutants.sh@@--slots fixo em 1@@--slots "$SLOTS"@@--slots 1
hq-mutants.sh@@--budget-s fixo@@--budget-s "$BUDGET"@@--budget-s 99
hq-mutants.sh@@1 slot por núcleo em vez de 2@@SLOTS=${HQ_MUTANTS_SLOTS:-$((CORES * 2))}@@SLOTS=${HQ_MUTANTS_SLOTS:-$((CORES))}
hq-mutants.sh@@HQ_MUTANTS_SLOTS inválido é aceito@@case "$SLOTS" in ''|*[!0-9]*|0) SLOTS=$((CORES * 2)) ;; esac@@case "$SLOTS" in 'zz') SLOTS=$((CORES * 2)) ;; esac
hq-mutants.sh@@o teto de 16 slots some@@[ "$SLOTS" -le 16 ] || SLOTS=16@@:
hq-mutants.sh@@HQ_MUTANTS_BUDGET_S inválido é aceito@@case "$BUDGET" in ''|*[!0-9]*) BUDGET=1800 ;; esac@@case "$BUDGET" in 'zz') BUDGET=1800 ;; esac
hq-mutants.sh@@o piso de 60 s do prazo some@@[ "$BUDGET" -ge 60 ] || BUDGET=60@@:
hq-mutants.sh@@o estado vai para o run-dir (o rodízio recomeçaria do zero a cada rodada)@@STATE="$BH/hq-mutants.state.json"@@STATE="$RD/hq-mutants.state.json"
hq-mutants.sh@@o tempo do motor passa do prazo do registro (volta o rc 124)@@HQ_MUTANTS_BUDGET_S:-1800@@HQ_MUTANTS_BUDGET_S:-3000
hq-mutants.sh@@o passo do resumo que morre não deixa resumo nenhum@@if [ "$prc" -eq 1 ]; then summary resumo-falhou@@if false; then summary resumo-falhou
hq-mutants.sh@@o rc do passo do resumo é perdido (sai sempre 0)@@exit "$prc"@@exit 0
hq-mutants.sh@@a pasta de trabalho do motor não é criada@@mkdir -p "$RD/work" || {@@: || {
hq-mutants.sh@@o resumo traz a ponta inteira em vez das 9 letras@@rec.update(main=short,@@rec.update(main=full,
wa-mutants.sh@@o marcador de ocioso nunca é reconhecido@@if [ "$KEY" = "$(cat "$IDLE" 2> /dev/null)" ] &&@@if false &&
wa-mutants.sh@@o marcador de ocioso vale para sempre (sem o prazo de 6 h)@@ && [ -n "$(find "$IDLE" -mmin -360 2> /dev/null)" ]; then@@; then
wa-mutants.sh@@o marcador ignora o main do hq (o motor novo não reabre a varredura)@@KEY="$main:$hqmain"@@KEY="$main"
wa-mutants.sh@@o marcador é gravado em qualquer resultado@@if rec["result"] == "sem-novidade" and erc == 0:@@if True:
wa-mutants.sh@@o marcador é gravado com o motor em rc != 0@@if rec["result"] == "sem-novidade" and erc == 0:@@if rec["result"] == "sem-novidade":
wa-mutants.sh@@o marcador guarda outra coisa que o par de pontas@@f.write(key + "\n")@@f.write("x\n")
wa-mutants.sh@@o rc do motor vira 0@@rc = erc if erc in (0, 97, 143) else 3@@rc = 0
wa-mutants.sh@@rc que o motor não tem passa adiante@@rc = erc if erc in (0, 97, 143) else 3@@rc = erc
wa-mutants.sh@@o 97 do motor vira 3@@(0, 97, 143)@@(0, 143)
wa-mutants.sh@@motor sem resumo sai com rc 0@@"stderr": tail}
    rc = 3@@"stderr": tail}
    rc = 0
wa-mutants.sh@@vale a PRIMEIRA linha JSON do motor, não a última@@for line in reversed(@@for line in (
wa-mutants.sh@@linha JSON sem result é aceita como resumo@@if isinstance(v, dict) and "result" in v:@@if True:
wa-mutants.sh@@o resumo traz a ponta do hq no lugar da do WA@@"$erc" "${tested:0:9}" "${hqmain:0:9}"@@"$erc" "${hqmain:0:9}" "${hqmain:0:9}"
wa-mutants.sh@@o resumo repete a ponta do WA no campo do hq@@rec.update(main=short, hq=hqshort,@@rec.update(main=short, hq=short,
wa-mutants.sh@@a árvore de trabalho nunca é removida@@cleanup() { [ -z "$bead" ] || { "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@cleanup() { :; }
wa-mutants.sh@@a limpeza não roda no fim (sem o trap EXIT)@@trap cleanup EXIT@@:
wa-mutants.sh@@a branch worker/* não sai no fim da rodada@@"$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@"$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; }; }
wa-mutants.sh@@a branch velha não sai antes do wt-add (a rodada testaria a ponta de outro dia)@@branch_rm
if ! timeout 900 "$RG" wt-add@@if ! timeout 900 "$RG" wt-add
wa-mutants.sh@@a árvore velha não sai antes do wt-add@@[ ! -e "$GR/$RIG/wt/$bead" ] ||@@true ||
wa-mutants.sh@@a árvore tem o mesmo nome da do wa-suite@@bead="ballast-wam"@@bead="ballast-wa"
wa-mutants.sh@@wt-add que falha segue em frente@@if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then@@if false; then
wa-mutants.sh@@clone do WA sem origin/main segue em frente@@[ -n "$main" ] || { say "o clone do $RIG não tem origin/main"; summary sem-main pull=$pull hqpull=$hqpull; exit 3; }@@main=${main:-0000000000}
wa-mutants.sh@@clone do hq sem origin/main segue em frente@@[ -n "$hqmain" ] || { say "o clone do $HQRIG não tem origin/main"; summary sem-main main="${main:0:9}" pull=$pull hqpull=$hqpull; exit 3; }@@hqmain=${hqmain:-0000000000}
wa-mutants.sh@@pull do WA que falha é dado como ok@@"$RG" pull "$RIG" > /dev/null 2>&1 || pull=falhou@@"$RG" pull "$RIG" > /dev/null 2>&1 || pull=ok
wa-mutants.sh@@pull do hq que falha é dado como ok@@|| hqpull=falhou@@|| hqpull=ok
wa-mutants.sh@@sem o python do venv segue em frente@@[ -x "$PYV" ] ||@@true ||
wa-mutants.sh@@o motor vem sem a conferência de arquivo vazio@@ || [ ! -s "$ENGDIR/$f" ]; then@@; then
wa-mutants.sh@@a jaula não é tirada do main do hq@@for f in hq-mutate.py hq-mutate-wa.py hq-sandbox-run.py; do@@for f in hq-mutate.py hq-mutate-wa.py; do
wa-mutants.sh@@o wrapper não é tirado do main do hq@@for f in hq-mutate.py hq-mutate-wa.py hq-sandbox-run.py; do@@for f in hq-mutate.py hq-sandbox-run.py; do
wa-mutants.sh@@árvore sem tests/ ou sem lib/ e daemons/ segue em frente@@{ [ -d "$TREE/tests" ] && { [ -d "$TREE/lib" ] || [ -d "$TREE/daemons" ]; }; } ||@@true ||
wa-mutants.sh@@árvore sem lib/ nem daemons/ segue em frente@@ && { [ -d "$TREE/lib" ] || [ -d "$TREE/daemons" ]; }@@
wa-mutants.sh@@árvore só com daemons/ é recusada@@|| [ -d "$TREE/daemons" ]; }; } ||@@|| false; }; } ||
wa-mutants.sh@@o TERM não espera o motor acabar (a árvore sai de baixo dos mutantes em voo)@@kill -TERM "$ep" 2>/dev/null; wait "$ep" 2>/dev/null; }; exit 143'@@kill -TERM "$ep" 2>/dev/null; }; exit 143'
wa-mutants.sh@@o TERM não chega ao motor@@{ kill -TERM "$ep" 2>/dev/null; wait "$ep"@@{ wait "$ep"
wa-mutants.sh@@o item não espera o motor@@wait "$ep"; erc=$?; ep=""@@erc=0; ep=""
wa-mutants.sh@@--slots fixo em 1@@--slots "$SLOTS"@@--slots 1
wa-mutants.sh@@--budget-s fixo@@--budget-s "$BUDGET"@@--budget-s 99
wa-mutants.sh@@o python do venv não vai ao motor@@--python "$PYV"@@--python python3
wa-mutants.sh@@a jaula vai de outro lugar@@--jail "$ENGDIR/hq-sandbox-run.py"@@--jail /nonexistent
wa-mutants.sh@@2 slots por núcleo em vez de 1 (o pytest é CPU, não espera)@@SLOTS=${WA_MUTANTS_SLOTS:-$CORES}@@SLOTS=${WA_MUTANTS_SLOTS:-$((CORES * 2))}
wa-mutants.sh@@WA_MUTANTS_SLOTS inválido é aceito@@case "$SLOTS" in ''|*[!0-9]*|0) SLOTS=$CORES ;; esac@@case "$SLOTS" in 'zz') SLOTS=$CORES ;; esac
wa-mutants.sh@@o teto de 16 slots some@@[ "$SLOTS" -le 16 ] || SLOTS=16@@:
wa-mutants.sh@@BALLAST_CORES inválido é aceito@@case "$CORES" in ''|*[!0-9]*|0) CORES=2 ;; esac@@case "$CORES" in 'zz') CORES=2 ;; esac
wa-mutants.sh@@WA_MUTANTS_BUDGET_S inválido é aceito@@case "$BUDGET" in ''|*[!0-9]*) BUDGET=1800 ;; esac@@case "$BUDGET" in 'zz') BUDGET=1800 ;; esac
wa-mutants.sh@@o piso de 60 s do prazo some@@[ "$BUDGET" -ge 60 ] || BUDGET=60@@:
wa-mutants.sh@@o estado vai para o run-dir (o rodízio recomeçaria do zero a cada rodada)@@STATE="$BH/wa-mutants.state.json"@@STATE="$RD/wa-mutants.state.json"
wa-mutants.sh@@o tempo do motor passa do prazo do registro (volta o rc 124)@@WA_MUTANTS_BUDGET_S:-1800@@WA_MUTANTS_BUDGET_S:-3000
wa-mutants.sh@@o passo do resumo que morre não deixa resumo nenhum@@if [ "$prc" -eq 1 ]; then summary resumo-falhou@@if false; then summary resumo-falhou
wa-mutants.sh@@o rc do passo do resumo é perdido (sai sempre 0)@@exit "$prc"@@exit 0
wa-mutants.sh@@a pasta de trabalho do motor não é criada@@mkdir -p "$RD/work" || {@@: || {
wa-mutants.sh@@a pasta do motor não é criada@@mkdir -p "$ENGDIR" ||@@: ||
wa-mutants.sh@@o motor é tirado do clone do WA em vez do hq@@show "$hqmain:.gascity-gastown-hq/scripts/$f"@@show "$main:.gascity-gastown-hq/scripts/$f"
MUT
  "$PY" -I - "$ITEMS" "$T/mutants.txt" "$T" > "$T/mutants.idx" <<'PYEOF'
import os, re, shutil, sys
items, lst, tmp = sys.argv[1:4]
entries, cur = [], None
for line in open(lst, encoding="utf-8").read().split("\n"):
    if cur is None or (cur.count("@@") >= 3 and re.match(r"^[a-z][a-z0-9.-]*\.sh@@", line)):
        if cur is not None:
            entries.append(cur)
        cur = line
    else:
        cur += "\n" + line
if cur:
    entries.append(cur)
for i, e in enumerate(entries, 1):
    parts = e.split("@@")
    if len(parts) != 4:
        print("%d\tBAD\t%s" % (i, e[:60])); continue
    fn, desc, a, b = parts
    src = open(os.path.join(items, fn), encoding="utf-8").read()
    if src.count(a) != 1:
        print("%d\tBAD\t%s" % (i, desc)); continue
    d = "%s/mi%d" % (tmp, i)
    shutil.copytree(items, d)
    open(os.path.join(d, fn), "w", encoding="utf-8").write(src.replace(a, b))
    print("%d\tOK\t%s\t%s" % (i, desc, fn))
PYEOF
  JOBS=${HBI_JOBS:-4}
  while IFS="$(printf '\t')" read -r idx st desc fn; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o script mudou?)"; continue; fi
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    case "$fn" in hq-mutants.sh) g=mut ;; wa-mutants.sh) g=wam ;; queima.sh) g=burn ;; *) g=hq ;; esac   # só o grupo do arquivo mudado
    ( HBI_MUTANT=1 HBI_MUTANT_G=$g HBI_ITEMS_DIR="$T/mi$idx" bash "$0" 2>&1 | tail -1 > "$T/mres.$idx" ) &
  done < "$T/mutants.idx"
  wait
  while IFS="$(printf '\t')" read -r idx st desc fn; do
    [ "$st" = OK ] || continue
    r=$(cat "$T/mres.$idx" 2>/dev/null)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$desc' pego ($r)";; *) ok 1 "mutante '$desc': sem resultado ($r)";; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
