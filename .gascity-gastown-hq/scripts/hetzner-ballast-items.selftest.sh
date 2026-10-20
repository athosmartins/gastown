#!/usr/bin/env bash
# hetzner-ballast-items.selftest.sh — hermético (ga-2hd02v.5): os itens do lastro (scripts/hetzner-ballast-items/*.sh) contra um espelho git de brinquedo (um repo bare com a árvore do hq
# de mentira, o `hetzner-remote-git.sh` é um stub que usa `git worktree` de verdade) e selftests de brinquedo (passa, reprova, ambiente, estoura o prazo, só-macOS). Nada fala com o nó.
#
# Contents
#   Casos · Variáveis
#
# CASOS
#   hq-selftests (g_hq): uma rodada completa conta passou/reprovou/ambiente/prazo e deixa de fora a lista só-macOS · 1ª rodada = "primeira" (sem comparação) · mesma ponta do main = "sem-novidade"
#     e não cria árvore · commit novo = só as reprovações NOVAS contra a última rodada COMPLETA entram em new_fail · reprovação que passa na 2ª tentativa é "flaky", não reprovada ·
#     pull que falha segue com o clone que há e diz pull=falhou · lista só-macOS ausente/vazia, árvore sem scripts/, wt-add que falha = exit 3, nada rodou e a ponta NÃO é gravada ·
#     TERM no meio apaga a árvore e NÃO grava a ponta (a próxima rodada refaz) · log só de quem reprovou · resumo é JSON de uma linha `BALLAST-SUMMARY:`.
#   queima (g_burn): sobe BALLAST_CORES laços, avisa o resumo na partida e sai no TERM sem deixar filho.
# CONTROLE NEGATIVO: sem a rodada de reprovadas · ambiente/prazo contados como reprovados · lista só-macOS ignorada ou aceita vazia · comparação sem a rodada anterior · ponta não gravada · árvore
#   não removida (nem no TERM) · pull/wt-add que falham ignorados · queima que não leva os laços no TERM — cada um é aplicado numa cópia e a bateria TEM que falhar.
# VARIÁVEIS: HBI_PY (python do teste; padrão /usr/bin/python3) · HBI_ONLY=<grupo> (hq burn) · HBI_NO_MUTANTS=1 · HBI_JOBS (mutantes em paralelo; padrão 4)
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
  rm -f "$W/rg.pull.fail" "$W/rg.wtadd.fail"; : > "$W/rg.calls"
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
  pull) [ -f "$W/rg.pull.fail" ] && { echo "pull rig=$2 resultado=erro" >&2; exit 1; }; echo "pull rig=$2 resultado=ok"; exit 0 ;;
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
  check "hq: a rodada do commit novo testou a ponta NOVA (d existe na árvore testada: reprovou), não a branch velha de uma rodada anterior" "ok" "$(sj compare)"
  newcommit e.selftest.sh 0; runhq
  check "hq: terceira rodada: d e b reprovavam antes → nenhuma NOVA (new_fail_n 0)" "0" "$(sj new_fail_n)"

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
  newrig; : > "$W/rg.wtadd.fail"; runhq
  check "hq: wt-add que falha → exit 3, ponta não gravada" "3 wt-add-falhou 0" "$RC $(sj result) $([ -e "$BH/hq-selftests.last" ] && echo 1 || echo 0)"
  newrig; git -C "$GR/gascity/repo.git" update-ref -d refs/remotes/origin/main; runhq
  check "hq: clone sem origin/main → exit 3 (sem-main)" "3 sem-main" "$RC $(sj result)"

  newrig; RDN=$((RDN+1)); RD="$T/rd$N.k"; mkdir -p "$RD"
  ( env PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" HQ_SELFTEST_TIMEOUT=20 bash "$ITEMS/hq-selftests.sh" > "$W/kill.out" 2>&1 ) & kp=$!
  sleep 3; pkill -TERM -P "$kp" 2>/dev/null; kill -TERM "$kp" 2>/dev/null; wait "$kp" 2>/dev/null
  i=0; while [ "$i" -lt 50 ] && ! grep -q '^wt-rm gascity ballast-hq' "$W/rg.calls"; do sleep 0.2; i=$((i+1)); done
  check "hq: TERM no meio → a ponta NÃO é gravada (a próxima rodada refaz)" "0" "$([ -e "$BH/hq-selftests.last" ] && echo 1 || echo 0)"
  check "hq: TERM no meio → a árvore de trabalho é removida" "1" "$(grep -c '^wt-rm gascity ballast-hq' "$W/rg.calls")"
  check "hq: TERM no meio → a branch worker/* também não sobra" "0" "$(git -C "$GR/gascity/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"
}

# ── g_burn ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_burn() {
  local out="$W/burn.out"; BR="$T/burnrun"; mkdir -p "$BR" "$T/qm"; cp "$ITEMS/queima.sh" "$T/qm/queima.sh" 2>/dev/null
  ( env PATH="$PATH" BALLAST_HOME="$T/bh0" BALLAST_RUN_DIR="$BR" BALLAST_CORES=3 bash "$T/qm/queima.sh" > "$out" 2>&1 ) & bp=$!
  sleep 1.5
  check "burn: avisa o resumo na partida (cores 3)" "1" "$(grep -c '^BALLAST-SUMMARY: {"kind": "queima", "cores": 3}$' "$out")"
  check "burn: 3 laços de CPU + o script = 4 processos com o caminho do item" "4" "$(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  kill -TERM "$(pgrep -o -f "$T/qm/queima.sh" 2>/dev/null)" 2>/dev/null; sleep 1.5
  check "burn: TERM só no processo mais velho (o script) → ele leva os laços junto, nada fica para trás" "0" "$(pgrep -f "$T/qm/queima.sh" 2>/dev/null | wc -l | tr -d ' ')"
  wait "$bp" 2>/dev/null
  ( env BALLAST_RUN_DIR="$BR" BALLAST_CORES=abc bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  check "burn: BALLAST_CORES que não é inteiro >= 1 → exit 2 e nada sobe" "2" "$rc"
  ( env BALLAST_RUN_DIR="$BR" BALLAST_CORES=0 bash "$T/qm/queima.sh" > "$out" 2>&1 ); rc=$?
  check "burn: BALLAST_CORES=0 também é recusado (exit 2)" "2" "$rc"
}

if [ -n "${HBI_MUTANT:-}" ]; then g_hq; g_burn; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HBI_ONLY:-}" ]; then "g_$HBI_ONLY"; echo "── $((n - fails))/$n ok (só g_$HBI_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_hq; g_burn

[ -n "${HBI_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # ARQUIVO@@DESCRIÇÃO@@ANTES@@DEPOIS — troca EXATAMENTE uma ocorrência numa cópia da pasta de itens
  cat > "$T/mutants.txt" <<'MUT'
hq-selftests.sh@@sem a 2ª tentativa dos reprovados (flaky vira reprovado)@@awk -F'\t' '$2 != 0 && $2 != 97 && $2 != 124 && $2 != 137 {print $1}' "$RD/results.tsv" > "$RD/retry.txt"@@: > "$RD/retry.txt"
hq-selftests.sh@@ambiente (rc 97) conta como reprovado@@    elif rc == 97:@@    elif rc == 9999:
hq-selftests.sh@@prazo (rc 124/137) conta como reprovado@@    elif rc in (124, 137):@@    elif rc in (9999,):
hq-selftests.sh@@a ponta testada nunca é gravada@@put(last_p, full + "\n")@@pass
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
    print("%d\tOK\t%s" % (i, desc))
PYEOF
  JOBS=${HBI_JOBS:-4}
  while IFS="$(printf '\t')" read -r idx st desc; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o script mudou?)"; continue; fi
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    ( HBI_MUTANT=1 HBI_ITEMS_DIR="$T/mi$idx" bash "$0" 2>&1 | tail -1 > "$T/mres.$idx" ) &
  done < "$T/mutants.idx"
  wait
  while IFS="$(printf '\t')" read -r idx st desc; do
    [ "$st" = OK ] || continue
    r=$(cat "$T/mres.$idx" 2>/dev/null)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$desc' pego ($r)";; *) ok 1 "mutante '$desc': sem resultado ($r)";; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
