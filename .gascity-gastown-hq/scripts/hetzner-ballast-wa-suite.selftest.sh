#!/usr/bin/env bash
# hetzner-ballast-wa-suite.selftest.sh — hermético (ga-2hd02v.8): o item `wa-suite` do lastro (scripts/hetzner-ballast-items/wa-suite.sh) contra um espelho git de brinquedo (repo bare com uma árvore de WA
# de mentira; o `hetzner-remote-git.sh` é um stub com `git worktree` de verdade), um `gt-iso-run` de brinquedo (canário e linhas de prova que o teste controla) e um "python -m pytest" de brinquedo que imprime
# EXATAMENTE o texto que o teste manda. Nada fala com o nó, nada usa rede nem root. A prova com o helper de root de verdade (sudo + gt-netns-run) foi feita no nó e está no runbook; aqui fica o que é hermético.
#
# Contents
#   Casos · Controle negativo · Variáveis
#
# CASOS
#   completo (g_run): rodada completa conta total/passou/reprovou/pulou, grava a lista de reprovadas (id com " - " dentro inteiro) e a ponta, apaga a árvore e a branch, deixa UMA linha BALLAST-SUMMARY · o
#     pytest recebe os argumentos da noturna, o -n do governo e GTN_WORKERS · 1ª rodada = "primeira" · mesma ponta = "sem-novidade" (sem canário, sem árvore; se o pull FALHOU e a ponta é a mesma, não é "sem novidade": `pull-falhou`, exit 3) · commit novo = só as reprovações NOVAS
#     (e as corrigidas) · zero falhas · falha de prazo de teste é contada à parte.
#   isolamento (g_iso): canário `nao-isolado` = vazamento, tranca o item (flag) e NADA roda · `inerte`/vazio = nada roda, sem flag · `nao-isolado` DENTRO da rodada idem · a flag do vazamento que não dá para gravar (`trava=falhou` no resumo, exit 3) nos dois caminhos · sem a linha `ok ns=` ou sem
#     `GTN-EGRESS` = resultado descartado (sem-prova-de-isolamento) e o estado não anda.
#   leitura (g_read): pytest rc fora de 0/1 · sem linha de resumo · total abaixo do piso · lista de ids ausente/parcial/com `reports` errado/duplicada/não JSON (ou um `GTN-FAIL` que é lista, não objeto) · linha de base ilegível ou de forma errada (inclusive uma linha que é JSON válido mas não é texto)
#     (nunca "0 novas": compare indisponível, a base NÃO anda, a ponta anda) · base vazia = toda falha é nova.
#   pausa (g_frozen): salto de relógio >= 60 s (sessão congelada) = comparação indisponível, base intacta · sem salto = comparação normal · arquivo de relógio ilegível ou vigia MORTO = desconhecido (`frozen_s` nulo, comparação indisponível) · o `sleep` do vigia não fica órfão
#     depois do pytest. O caso do salto ESPERA o vigia gravar o relógio (`py.waitfrozen`) em vez de dormir um tempo fixo: o flake do gate 1/3 era o laço de verdade sobrescrevendo o arquivo semeado.
#   preparo (g_prep): pull que falha segue · sem origin/main · wt-add que falha · árvore sem tests/ · plugin ou gt-iso-run ausente — exit 3, nada gravado · `wt-rm` que não leva a árvore velha embora = `arvore-velha`, exit 3.
#   estado (g_state): a lista de falhas que é pasta, e o passo final que morre, dão exit 3 (gravacao-falhou / resumo-falhou) sem consumir a ponta · TERM no meio repassa ao pytest, apaga a árvore e não grava · TERM com o pytest ainda não nascido (canário pendurado) sai 143 na hora, sem esperar os 10 s do laço.
#   registro (g_reg): a linha wa-suite do hetzner-ballast.items.txt (a REAL) lê limpa no governo, é `work` com núcleos FIXOS (um `auto` levaria o orçamento inteiro e o hq-selftests passaria horas sem rodar),
#     exige o helper, o gt-iso-run, o python do venv, o plugin e `noflag:wa-suite.leak`, e o comando existe na pasta de itens. CALIBRAÇÃO DA RAM (ga-weaih6): o rss_mb cobre núcleos × MB por worker + base + filho de coleta
#     MEDIDOS no nó, e passa a regra de partida e o piso de pausa do governo no p10 de MemAvailable (um wa-suite de 8 núcleos com teto de 12 GB morria por `rss` aos 5 min em toda rodada).
#     ga-r4lw72: o hq-selftests também tem núcleos FIXOS (o `auto` ficou com 1 núcleo por 3 h), que cabem junto do wa-suite no orçamento de 9 núcleos (16 - 6 de sessões - 1 de reserva); o prazo dele é pelo menos o dobro
#     de (soma ~12.555 s de selftest / núcleos); e o cooldown dos dois fica entre 120 s (cada pergunta é um pull ao espelho do mini) e 300 s (o main já mudou durante a rodada de 44 a 80 min).
#   agenda (g_sched): com o GOVERNO REAL e as colunas papel/núcleos/rss/prazo/cooldown da linha real: com o wa-suite rodando, o hq-selftests ainda começa (núcleos fixos da linha real); e com o hq-selftests JÁ rodando, o wa-suite
#     começa no tick seguinte (ga-r4lw72: com `auto` o hq levava o orçamento inteiro e o wa-suite, com o cooldown vencido, ficava de fora até ele acabar: 18:47Z a 20:06Z de 24/10).
# CONTROLE NEGATIVO: cada mutante (um trecho do item ou do registro trocado) TEM que reprovar a bateria.
# VARIÁVEIS: HBW_ANCHORS_ONLY=1 (só confere que cada âncora de mutante casa 1 vez) · HBW_PY (python do teste; padrão /usr/bin/python3) · HBW_ITEMS_DIR (pasta de itens; um mutante traz também a cópia do registro) · HBW_ONLY=<grupo> (run iso read frozen prep state reg sched; com HBW_MUTANT roda só esse grupo) ·
#   HBW_NO_MUTANTS=1 · HBW_JOBS (mutantes em paralelo; padrão 4)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ITEMS="${HBW_ITEMS_DIR:-$HERE/hetzner-ballast-items}"
REGF="$HERE/hetzner-ballast.items.txt"; [ ! -f "$ITEMS/hetzner-ballast.items.txt" ] || REGF="$ITEMS/hetzner-ballast.items.txt"
GOV="$HERE/hetzner-ballast.py"
PY="${HBW_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hbw.XXXXXX)" && pwd -P)
# killtree CAMINHO — mata, pelo GRUPO de processos, tudo que leva CAMINHO na linha de comando (o poupado é o grupo do próprio teste)
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
trap 'exit 143' TERM INT HUP
fails=0; n=0
ok() {  # no modo mutante, a primeira falha encerra (só interessa se a bateria reprova)
  n=$((n+1))
  if [ "$1" = 0 ]; then [ -n "${HBW_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HBW_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi
}
check() { if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$T/w"; mkdir -p "$W/bin" "$T/home"; : > "$W/plugin.py"
cat > "$W/bin/timeout" <<'EOF'
#!/bin/sh
# timeout de brinquedo COM prazo de verdade (o do macOS não existe): timeout [-k K] DUR cmd… ; estouro = rc 124 como o GNU, senão o rc do comando.
# Em Python, de propósito: um vigia em shell (subshell + `sleep`) deixa o `sleep` órfão (ppid 1) por DUR s quando o comando termina antes — 300/900 s por chamada, e uma bateria no nó chegou a ter 910
# deles vivos de uma vez (medido em 24/10, ga-2hd02v.8). Consertar isso em shell com grupo de processos (`set -m`) funciona no bash do macOS e TRAVA no dash do nó ("can't access tty"). Popen.wait(timeout) não deixa nada para trás.
[ "$1" = -k ] && shift 2
exec "$HBW_REAL_PY" -I -c '
import subprocess, sys
dur = float(sys.argv[1])
p = subprocess.Popen(sys.argv[2:])
try:
    rc = p.wait(timeout=dur)
except subprocess.TimeoutExpired:
    p.terminate()
    try:
        p.wait(timeout=1)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)
' "$@"
EOF
cat > "$W/bin/python3" <<'EOF'
#!/bin/sh
# python3 de brinquedo: o real, salvo que COM o arquivo $HBW_PY_CRASH o passo de LEITURA do pytest (o único cujo texto tem "out_p, prc, prev_p") quebra: rc 1 e nada na saída, como um OOM
case "$1:$2" in
  -I:-) src=$(cat)
        if [ -f "$HBW_PY_CRASH" ] && printf '%s' "$src" | grep -q 'out_p, prc, prev_p'; then echo "python3 (brinquedo): quebrou" >&2; exit 1; fi
        printf '%s\n' "$src" | "$HBW_REAL_PY" "$@"; exit $? ;;
esac
exec "$HBW_REAL_PY" "$@"
EOF
cat > "$W/bin/date" <<'EOF'
#!/bin/bash
# date de brinquedo: com o arquivo $HBW_JUMP (que guarda N) cada `date +%s` anda N s a mais que o anterior = a sessão "ficou parada"; sem ele, o real
if [ "${1:-}" = "+%s" ] && [ -f "${HBW_JUMP:-/nonexistent}" ]; then
  k=$(cat "$HBW_JUMP.n" 2>/dev/null || echo 0); k=$((k+1)); echo "$k" > "$HBW_JUMP.n"
  echo $(( $(/bin/date +%s) + k * $(cat "$HBW_JUMP") ))
else exec /bin/date "$@"; fi
EOF
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
  wt-rm) [ -f "$W/rg.wtrm.fail" ] && exit 1; git -C "$GT_REMOTE_GIT/$2/repo.git" worktree remove --force "$GT_REMOTE_GIT/$2/wt/$3" 2>/dev/null; exit 0 ;;
esac
exit 2
EOF
cat > "$W/iso" <<'EOF'
#!/bin/bash
# gt-iso-run de brinquedo. --canary: imprime $W/iso.canary (padrão: isolado). -- CMD: imprime a linha do canário, a do helper (`ok ns=`) e, no fim, o contador; cada uma some com o seu arquivo
# (iso.noproof, iso.noegress); $W/iso.runfirst troca a linha do canário DENTRO da rodada por outra (e sai 97, como o real); $W/iso.hang pendura o --canary (grava o pid em iso.pid). Repassa TERM ao filho (o sudo faz isso no nó).
W="$(cd "$(dirname "$0")" && pwd)"; echo "$*" >> "$W/iso.calls"
if [ "${1:-}" = --canary ]; then
  [ ! -f "$W/iso.hang" ] || { echo $$ > "$W/iso.pid"; exec sleep 60; }
  if [ -f "$W/iso.canary" ]; then cat "$W/iso.canary"; else echo "GTN-ISO: isolado (sonda barrou 6 tentativas)"; fi
  exit 0
fi
[ "${1:-}" = -- ] && shift
echo "workers=${GTN_WORKERS:-}" >> "$W/iso.env"
if [ -f "$W/iso.runfirst" ]; then cat "$W/iso.runfirst"; exit 97; fi
echo "GTN-ISO: isolado (sonda barrou 6 tentativas)"
[ -f "$W/iso.noproof" ] || echo "GTN-ISO: ok ns=gtn1 uid=1" >&2
"$@" & CH=$!
trap 'kill -TERM $CH 2>/dev/null' TERM
wait $CH; rc=$?
while kill -0 $CH 2>/dev/null; do wait $CH; rc=$?; done
[ -f "$W/iso.noegress" ] || echo "GTN-EGRESS: attempts=0" >&2
exit $rc
EOF
cat > "$W/py" <<'EOF'
#!/bin/bash
# "python -m pytest" de brinquedo: anota os argumentos, o diretório e GTN_WORKERS; dorme $W/py.sleep s se existir; com $W/py.waitfrozen espera (até 20 s) o laço de relógio do item gravar o arquivo frozen;
# com $W/py.killwatch mata o laço de relógio do item (o filho do item que não é o gt-iso-run); imprime $W/py.out; sai com $W/py.rc (padrão: 1 se há FAILED, senão 0)
W="$(cd "$(dirname "$0")" && pwd)"
{ echo "args: $*"; echo "pwd: $(pwd)"; echo "workers: ${GTN_WORKERS:-}"; } > "$W/py.args"
echo $$ > "$W/py.pid"
[ ! -f "$W/py.sleep" ] || { : > "$W/py.started"; sleep "$(cat "$W/py.sleep")"; }
i=0; while [ -f "$W/py.waitfrozen" ] && [ ! -e "$BALLAST_RUN_DIR/frozen" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
if [ -f "$W/py.killwatch" ]; then
  ip=$(ps -o ppid= -p "$PPID" | tr -d ' '); i=0   # $PPID = o gt-iso-run de brinquedo; o pai dele é o item
  while [ -z "${wp:-}" ] && [ "$i" -lt 50 ]; do wp=$(ps -axo pid=,ppid= | awk -v p="$ip" -v s="$PPID" '$2 == p && $1 != s { print $1 }'); [ -n "$wp" ] || sleep 0.1; i=$((i+1)); done
  kill -KILL $wp 2>/dev/null; sleep 0.5
fi
cat "$W/py.out"
if [ -f "$W/py.rc" ]; then exit "$(cat "$W/py.rc")"; fi
grep -q '^FAILED' "$W/py.out" && exit 1
exit 0
EOF
chmod +x "$W/bin/timeout" "$W/bin/python3" "$W/bin/date" "$W/rg" "$W/iso" "$W/py"
export HBW_REAL_PY="$PY" HBW_PY_CRASH="$W/py.crash" HBW_JUMP="$W/jump"

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────
N=0
newrig() {  # newrig [notests] — repo-fonte com uma árvore de WA de mentira + o repo bare que o stub usa como "clone do nó"
  N=$((N+1)); BH="$T/bh$N"; GR="$T/gr$N"; SRC="$T/src$N"; mkdir -p "$BH" "$GR/whatsapp_automation"
  git init -q "$SRC"; echo x > "$SRC/conftest.py"
  [ "${1:-}" = notests ] || { mkdir -p "$SRC/tests"; echo 'def test_a(): pass' > "$SRC/tests/test_a.py"; }
  git -C "$SRC" add -A && git -C "$SRC" commit -q -m um && git clone -q --bare "$SRC" "$GR/whatsapp_automation/repo.git" 2>/dev/null
  git -C "$GR/whatsapp_automation/repo.git" update-ref refs/remotes/origin/main "$(git -C "$SRC" rev-parse HEAD)"
  rm -f "$W"/rg.*.fail "$W"/iso.canary "$W"/iso.runfirst "$W"/iso.noproof "$W"/iso.noegress "$W"/iso.env "$W"/py.args "$W"/py.rc "$W"/py.sleep "$W"/py.started "$W"/py.pid "$W"/py.crash "$W"/py.waitfrozen "$W"/py.killwatch "$W"/iso.hang "$W"/iso.pid "$W"/jump "$W"/jump.n
  : > "$W/rg.calls"; : > "$W/iso.calls"; mkout 990 8 "tests/a.py::t1" "tests/b.py::t2[ADE V - Setor 4]"
}
newcommit() {  # newcommit — um commit novo no main (o espelho avança)
  echo "# $N$RANDOM" >> "$SRC/tests/test_a.py"; git -C "$SRC" add -A && git -C "$SRC" commit -q -m novo
  git -C "$GR/whatsapp_automation/repo.git" fetch -q "$SRC" "+HEAD:refs/remotes/origin/main"
}
mkout() {  # mkout PASSOU PULOU [ID_REPROVADO…] — a saída de um pytest -q com o plugin gtn_stable_ids (linhas FAILED, resumo, GTN-FAIL por id e GTN-FAILED)
  local passed=$1 skipped=$2; shift 2; local nf=$# id
  { echo "..........  [ 50%]"; echo "..........  [100%]"
    for id in "$@"; do echo "FAILED $id - assert 0"; done
    if [ "$nf" -gt 0 ]; then echo "$nf failed, $passed passed, $skipped skipped in 12.34s (0:00:12)"; else echo "$passed passed, $skipped skipped in 12.34s (0:00:12)"; fi
    for id in "$@"; do printf 'GTN-FAIL: "%s"\n' "$id"; done
    echo "GTN-FAILED: n=$nf reports=$nf"
  } > "$W/py.out"
}
newrd() { RDN=$((${RDN:-0}+1)); RD="$T/rd$N.$RDN"; mkdir -p "$RD"; [ -z "${PRE_FROZEN:-}" ] || printf '%s\n' "$PRE_FROZEN" > "$RD/frozen"; }   # BALLAST_RUN_DIR novo a cada rodada (PRE_FROZEN semeia o arquivo do relógio)
envwa() {  # envwa [VAR=valor…] — o item no ambiente de brinquedo, em $RD (as variáveis do chamador vêm DEPOIS e ganham). SÓ em subshell ($(…) ou &): o exec faz o pid do subshell ser o do item (é nele que o TERM tem que cair)
  exec env PATH="$W/bin:$PATH" HOME="$T/home" BALLAST_HOME="$BH" BALLAST_RUN_DIR="$RD" BALLAST_CORES=2 BALLAST_REMOTE_GIT="$W/rg" GT_REMOTE_GIT="$GR" BALLAST_ISO_RUN="$W/iso" BALLAST_WA_PYTHON="$W/py" \
      BALLAST_WA_PLUGIN="$W/plugin.py" WA_SUITE_MIN_TOTAL=10 WA_SUITE_WATCH_S=1 "$@" bash "$ITEMS/wa-suite.sh"
}
runwa() { newrd; OUT=$(envwa "$@" 2>"$W/err"); RC=$?; }   # runwa [VAR=valor…] → $OUT (stdout inteiro), $RC
sj() {  # sj CAMPO — campo do último BALLAST-SUMMARY (JSON) do $OUT; lista por índice (new_fail.0); null/ausente → "null"
  printf '%s\n' "$OUT" | grep '^BALLAST-SUMMARY: ' | tail -n 1 | sed 's/^BALLAST-SUMMARY: //' | "$PY" -I -c 'import sys,json
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if isinstance(v,dict): v=v.get(k)
    elif isinstance(v,list) and k.isdigit() and int(k)<len(v): v=v[int(k)]
    else: v=None
print(v if isinstance(v,str) else json.dumps(v))' "$1" 2>/dev/null
}
nsum() { printf '%s\n' "$OUT" | grep -c '^BALLAST-SUMMARY: '; }
tip() { git -C "$GR/whatsapp_automation/repo.git" rev-parse refs/remotes/origin/main; }
nlines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo ausente; }
calls() { grep -c "$1" "$2" 2>/dev/null || true; }
orphans() { ps -axo ppid=,command= | awk -v d="$1" '$1 == 1 && $2 == "sleep" && $3 == d' | wc -l | tr -d ' '; }   # orphans DURAÇÃO — `sleep DURAÇÃO` com ppid 1 (o vigia do stub timeout que ficou sem dono)

# ── g_run ────────────────────────────────────────────────────────────────────────────────────────────
g_run() {
  newrig; runwa
  check "run: rodada completa → rc 0, resultado completo" "0 completo" "$RC $(sj result)"
  check "run: total 1000 = 990 passou + 2 falhou + 8 pulou" "1000 990 2 0 8" "$(sj total) $(sj passed) $(sj failed) $(sj errors) $(sj skipped)"
  check "run: 1ª rodada não tem com o que comparar → compare primeira, new_fail_n null, fail_n 2" "primeira null 2" "$(sj compare) $(sj new_fail_n) $(sj fail_n)"
  check "run: o resumo traz a prova de isolamento (isolado, contador 0) e a duração do pytest (12 s)" "isolado 0 12" "$(sj iso) $(sj egress) $(sj secs)"
  check "run: a ponta testada é gravada" "$(tip)" "$(cat "$BH/wa-suite.last" 2>/dev/null)"
  check "run: a lista de reprovadas tem 2 ids em JSON, e o id com ' - ' dentro fica INTEIRO (a razão do plugin)" "2 1" "$(nlines "$BH/wa-suite.failed") $(grep -c '^"tests/b.py::t2\[ADE V - Setor 4\]"$' "$BH/wa-suite.failed")"
  check "run: o pytest recebe os argumentos da bateria noturna e o -n do governo (2)" "1 1 1 1 1 1" \
    "$(grep -c -- '-m pytest' "$W/py.args") $(grep -c -- 'tests/ -n 2 ' "$W/py.args") $(grep -c -- '-p gtn_stable_ids' "$W/py.args") $(grep -c -- '--timeout=900' "$W/py.args") $(grep -c -- '--continue-on-collection-errors' "$W/py.args") $(grep -c -- '-rfE --tb=line' "$W/py.args")"
  check "run: GTN_WORKERS = BALLAST_CORES (sem ele o conftest do WA limita o xdist a 2 workers)" "workers: 2" "$(grep '^workers:' "$W/py.args")"
  check "run: o pytest roda DENTRO da árvore do espelho (ballast-wa)" "1" "$(grep -c "/wt/ballast-wa$" "$W/py.args")"
  check "run: a árvore foi removida ao fim (wt-rm chamado) e nenhuma branch worker/* sobra" "1 0" "$(calls '^wt-rm whatsapp_automation ballast-wa' "$W/rg.calls") $(git -C "$GR/whatsapp_automation/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ')"
  check "run: exatamente UMA linha BALLAST-SUMMARY no stdout" "1" "$(nsum)"
  check "run: o canário rodou ANTES da suíte (a 1ª chamada do gt-iso-run é --canary)" "--canary" "$(head -n 1 "$W/iso.calls")"

  newrig; runwa BALLAST_CORES=3
  check "run: BALLAST_CORES=3 → -n 3 e GTN_WORKERS 3 (o -n e o teto do conftest seguem o governo, não um número fixo)" "1 workers: 3" "$(grep -c -- 'tests/ -n 3 ' "$W/py.args") $(grep '^workers:' "$W/py.args")"
  newrig; runwa; newcommit; git -C "$GR/whatsapp_automation/repo.git" branch worker/ballast-wa "$(cat "$BH/wa-suite.last")"; runwa
  check "run: branch worker/ballast-wa que sobrou de uma rodada morta (na ponta VELHA) não faz a rodada testar o código de outro dia" "$(tip | cut -c1-9)" "$(sj main)"
  newrig; runwa
  c0=$(wc -l < "$W/iso.calls"); runwa
  check "run: mesma ponta → sem-novidade, rc 0" "0 sem-novidade" "$RC $(sj result)"
  check "run: sem-novidade não roda canário nem cria árvore" "0 1" "$(( $(wc -l < "$W/iso.calls") - c0 )) $(calls '^wt-add' "$W/rg.calls")"

  newcommit; mkout 990 8 "tests/a.py::t1" "tests/c.py::t3"; runwa
  check "run: commit novo → compare ok; nova falha só t3, corrigida só t2, 2 falhas hoje (t1 e t3)" "ok 1 1 2" "$(sj compare) $(sj new_fail_n) $(sj fixed_n) $(sj fail_n)"
  check "run: a lista de novas traz o id novo" "tests/c.py::t3" "$(sj new_fail.0)"
  check "run: a base andou para a lista de hoje (t1, t3)" '"tests/a.py::t1" "tests/c.py::t3"' "$(tr '\n' ' ' < "$BH/wa-suite.failed" | sed 's/ $//')"

  newcommit; mkout 1000 0; runwa
  check "run: zero falhas (GTN-FAILED n=0 reports=0) → compare ok, 0 novas, 2 corrigidas, base vazia" "0 ok 0 2 0" "$(sj failed) $(sj compare) $(sj new_fail_n) $(sj fixed_n) $(nlines "$BH/wa-suite.failed")"
  newcommit; mkout 997 0 "tests/z.py::t[a]" "tests/y.py::t[b]" "tests/x.py::t[c]"; sed -i.bak 's#^FAILED tests/z.py::t\[a\] - assert 0#FAILED tests/z.py::t[a] - Failed: Timeout >900.0s#; s#^FAILED tests/y.py::t\[b\] - assert 0#FAILED tests/y.py::t[b] - Failed: Timeout (>900.0s) from pytest-timeout.#' "$W/py.out"; runwa
  check "run: falha por prazo de teste (pytest-timeout) é contada à parte (2 de 3)" "3 2" "$(sj failed) $(sj timeout_n)"
}

# ── g_iso ────────────────────────────────────────────────────────────────────────────────────────────
g_iso() {
  newrig; echo "GTN-ISO: nao-isolado tcp:1.1.1.1:53" > "$W/iso.canary"; runwa
  check "iso: canário nao-isolado → vazamento, exit 3, trava gravada (trava=ok)" "3 vazamento ok" "$RC $(sj result) $(sj trava)"
  check "iso: vazamento TRANCA o item (wa-suite.leak) e nada roda: sem árvore, sem pytest, sem ponta" "1 0 ausente ausente" "$([ -e "$BH/wa-suite.leak" ] && echo 1 || echo 0) $(calls '^wt-add' "$W/rg.calls") $([ -e "$W/py.args" ] && echo roda || echo ausente) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  check "iso: o resumo diz o que a sonda achou" "nao-isolado tcp:1.1.1.1:53" "$(sj iso)"

  newrig; echo "GTN-ISO: inerte helper-ausente (/usr/local/sbin/gt-netns-run)" > "$W/iso.canary"; runwa
  check "iso: canário inerte → isolamento-inerte, exit 3, SEM trancar, nada roda" "3 isolamento-inerte 0 ausente" "$RC $(sj result) $([ -e "$BH/wa-suite.leak" ] && echo 1 || echo 0) $([ -e "$W/py.args" ] && echo roda || echo ausente)"
  newrig; : > "$W/iso.canary"; runwa
  check "iso: canário que não imprime NADA nunca vira isolado: isolamento-inerte" "3 isolamento-inerte ausente" "$RC $(sj result) $([ -e "$W/py.args" ] && echo roda || echo ausente)"

  newrig; echo "GTN-ISO: nao-isolado dns" > "$W/iso.runfirst"; runwa
  check "iso: nao-isolado DENTRO da rodada (o canário do pré-teste passou) → vazamento, tranca (trava=ok), ponta não anda" "3 vazamento ok 1 ausente" "$RC $(sj result) $(sj trava) $([ -e "$BH/wa-suite.leak" ] && echo 1 || echo 0) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  # a trava que não grava (wa-suite.leak é pasta): o item NÃO ficou trancado e o resumo tem que dizer, nos dois caminhos (canário do bash e passo de leitura do python)
  newrig; echo "GTN-ISO: nao-isolado dns" > "$W/iso.canary"; mkdir "$BH/wa-suite.leak"; runwa
  check "iso: canário nao-isolado e a trava NÃO grava → vazamento com trava=falhou, exit 3" "3 vazamento falhou" "$RC $(sj result) $(sj trava)"
  newrig; echo "GTN-ISO: nao-isolado dns" > "$W/iso.runfirst"; mkdir "$BH/wa-suite.leak"; runwa
  check "iso: nao-isolado DENTRO da rodada e a trava NÃO grava → vazamento com trava=falhou, exit 3" "3 vazamento falhou" "$RC $(sj result) $(sj trava)"

  newrig; : > "$W/iso.noproof"; runwa
  check "iso: sem a linha 'GTN-ISO: ok ns=' o resultado é descartado (sem-prova-de-isolamento), nada é gravado" "3 sem-prova-de-isolamento ausente ausente" "$RC $(sj result) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente) $([ -e "$BH/wa-suite.failed" ] && echo gravou || echo ausente)"
  newrig; : > "$W/iso.noegress"; runwa
  check "iso: sem a linha GTN-EGRESS também é descartado" "3 sem-prova-de-isolamento" "$RC $(sj result)"
}

# ── g_read ───────────────────────────────────────────────────────────────────────────────────────────
g_read() {
  newrig; echo 2 > "$W/py.rc"; runwa
  check "read: pytest com rc 2 (abortou) → pytest-abortou, exit 3, nada gravado" "3 pytest-abortou ausente" "$RC $(sj result) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  newrig; echo 124 > "$W/py.rc"; runwa
  check "read: rc 124 (prazo) também não é resultado" "3 pytest-abortou" "$RC $(sj result)"
  newrig; printf '..........  [100%%]\n' > "$W/py.out"; runwa
  check "read: sem linha de resumo do pytest → sem-resumo, nada gravado" "3 sem-resumo ausente" "$RC $(sj result) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  newrig; mkout 3 0; runwa
  check "read: total abaixo do piso (3 < 10) → total-implausivel, nada gravado" "3 total-implausivel ausente" "$RC $(sj result) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"

  # lista de ids: cada defeito dá compare indisponivel, a base NÃO anda e a ponta anda (rc 0: o resumo do pytest foi lido)
  newrig; runwa; cp "$BH/wa-suite.failed" "$T/base.$N"; newcommit
  mkout 990 8 "tests/a.py::t1" "tests/n.py::tn"; grep -v '^GTN-FAILED' "$W/py.out" > "$W/py.out.x"; mv "$W/py.out.x" "$W/py.out"; runwa
  check "read: sem a linha GTN-FAILED → compare indisponivel (nunca 0 novas), rc 0, a ponta anda" "0 completo indisponivel null $(tip)" "$RC $(sj result) $(sj compare) $(sj new_fail_n) $(cat "$BH/wa-suite.last")"
  check "read: o resumo diz POR QUÊ (o plugin não imprimiu GTN-FAILED)" "1" "$(sj why | grep -c 'GTN-FAILED')"
  check "read: e a base de ids NÃO foi tocada" "$(cat "$T/base.$N")" "$(cat "$BH/wa-suite.failed")"
  newcommit; mkout 990 8 "tests/a.py::t1" "tests/n.py::tn"; grep -v 'tests/n.py::tn"$' "$W/py.out" > "$W/py.out.x"; mv "$W/py.out.x" "$W/py.out"; runwa
  check "read: lista PARCIAL (n=2, 1 id lido) → indisponivel, base intacta" "indisponivel null" "$(sj compare) $(sj new_fail_n)"
  check "read: lista parcial: base intacta" "$(cat "$T/base.$N")" "$(cat "$BH/wa-suite.failed")"
  newcommit; mkout 990 8 "tests/a.py::t1" "tests/n.py::tn"; sed -i.bak 's/^GTN-FAILED: n=2 reports=2/GTN-FAILED: n=2 reports=5/' "$W/py.out"; runwa
  check "read: 'reports' diferente de falhas+erros do resumo → indisponivel, base intacta" "indisponivel $(cat "$T/base.$N" | tr '\n' ' ')" "$(sj compare) $(cat "$BH/wa-suite.failed" | tr '\n' ' ')"
  newcommit; mkout 990 8 "tests/a.py::t1" "tests/n.py::tn"; echo "GTN-FAILED: n=2 reports=2" >> "$W/py.out"; runwa
  check "read: a linha GTN-FAILED duas vezes → indisponivel" "indisponivel" "$(sj compare)"
  newcommit; mkout 990 8 "tests/a.py::t1" "tests/n.py::tn"; sed -i.bak 's/^GTN-FAIL: "tests\/n.py::tn"/GTN-FAIL: tests\/n.py::tn/' "$W/py.out"; runwa
  check "read: GTN-FAIL que não é JSON → indisponivel" "indisponivel" "$(sj compare)"
  newcommit; mkout 990 8 "tests/a.py::t1" "tests/n.py::tn"; sed -i.bak 's/^GTN-FAIL: "tests\/n.py::tn"/GTN-FAIL: ["tn"]/' "$W/py.out"; runwa
  check "read: GTN-FAIL que é uma lista JSON (não hashable) → indisponivel, rc 0" "0 indisponivel" "$RC $(sj compare)"

  # linha de base
  newrig; runwa; newcommit; printf 'isto nao e json\n' > "$BH/wa-suite.failed"; cp "$BH/wa-suite.failed" "$T/bad.$N"; runwa
  check "read: base ilegível (texto solto) → indisponivel, NUNCA '0 novas'; a base fica como estava" "indisponivel null $(cat "$T/bad.$N")" "$(sj compare) $(sj new_fail_n) $(cat "$BH/wa-suite.failed")"
  newcommit; printf '123\n456\n' > "$BH/wa-suite.failed"; runwa
  check "read: base que é JSON mas não é lista de ids em texto (números) → indisponivel" "indisponivel null" "$(sj compare) $(sj new_fail_n)"
  newcommit; printf '["a"]\n{"k": 1}\n' > "$BH/wa-suite.failed"; cp "$BH/wa-suite.failed" "$T/bad2.$N"; runwa
  check "read: base com linha JSON que é lista/objeto (não hashable: TypeError) → indisponivel, rc 0 (nunca o passo derrubado e 3 h de suíte repetidas a cada 10 min), base intacta" "0 completo indisponivel null $(cat "$T/bad2.$N")" "$RC $(sj result) $(sj compare) $(sj new_fail_n) $(cat "$BH/wa-suite.failed")"
  newcommit; rm -f "$BH/wa-suite.failed"; mkdir "$BH/wa-suite.failed"; runwa
  check "read: base que é uma PASTA (não abre) → indisponivel, rc 0, nunca '0 novas'" "0 indisponivel null" "$RC $(sj compare) $(sj new_fail_n)"
  rmdir "$BH/wa-suite.failed"; newcommit; : > "$BH/wa-suite.failed"; runwa
  check "read: base VAZIA (a última rodada completa não teve falha) → toda falha de hoje é nova (2 de 2)" "ok 2" "$(sj compare) $(sj new_fail_n)"
}

# ── g_frozen ─────────────────────────────────────────────────────────────────────────────────────────
g_frozen() {
  newrig; runwa; cp "$BH/wa-suite.failed" "$T/fz.$N"; newcommit; : > "$W/py.waitfrozen"; echo 100 > "$W/jump"; runwa   # o pytest de brinquedo espera o laço gravar o salto (nada de sleep fixo: carga alta atrasava o laço)
  check "frozen: relógio que salta 100 s entre dois sleeps (sessão congelada) → frozen_s >= 60, compare indisponivel, rc 0" "0 completo 1 indisponivel null" "$RC $(sj result) $([ "$(sj frozen_s)" -ge 60 ] 2>/dev/null && echo 1 || echo 0) $(sj compare) $(sj new_fail_n)"
  check "frozen: o resumo diz que foi a pausa/fome de CPU" "1" "$(sj why | grep -c 'parada')"
  check "frozen: a base NÃO anda numa rodada suspeita, a ponta anda" "$(cat "$T/fz.$N") $(tip)" "$(cat "$BH/wa-suite.failed") $(cat "$BH/wa-suite.last")"
  # o relógio de brinquedo volta ao real e o laço de relógio NÃO anda (WA_SUITE_WATCH_S enorme): nos dois casos abaixo só vale o arquivo `frozen` semeado à mão, nenhum salto de 1 s o sobrescreve
  rm -f "$W/jump" "$W/jump.n" "$W/py.waitfrozen" "$W/py.sleep"
  newcommit; PRE_FROZEN=abc runwa WA_SUITE_WATCH_S=3600
  check "frozen: arquivo de relógio ilegível (não é inteiro) = rodada suspeita: comparação indisponível, frozen_s null (nunca 0)" "indisponivel null" "$(sj compare) $(sj frozen_s)"
  newcommit; PRE_FROZEN=0 runwa WA_SUITE_WATCH_S=3600
  check "frozen: salto 0 (o laço rodou e o relógio andou direito) é normal" "ok" "$(sj compare)"
  newcommit; echo 3 > "$W/py.sleep"; rm -f "$W/jump" "$W/jump.n"; runwa
  check "frozen: sem salto de relógio → frozen_s pequeno e comparação normal (ok)" "ok 1" "$(sj compare) $([ "$(sj frozen_s)" -lt 60 ] 2>/dev/null && echo 1 || echo 0)"
  newcommit; : > "$W/py.killwatch"; runwa; rm -f "$W/py.killwatch"
  check "frozen: o laço de relógio que MORRE no meio da rodada = relógio desconhecido: comparação indisponível, frozen_s null (o arquivo ausente leria como 'sem salto')" "indisponivel null" "$(sj compare) $(sj frozen_s)"
  # duração curta e única (a vida de um órfão é essa): se o fim do item deixasse o `sleep` do laço solto (ppid 1), ele some sozinho em < 1 min em vez de ficar horas no nó
  d=$((31 + RANDOM % 28)); b=$(orphans "$d"); newcommit; echo 1 > "$W/py.sleep"; runwa WA_SUITE_WATCH_S=$d
  check "frozen: ao fim o item não deixa o sleep do laço de relógio órfão" "0" "$(( $(orphans "$d") - b ))"
}

# ── g_prep ───────────────────────────────────────────────────────────────────────────────────────────
g_prep() {
  newrig; : > "$W/rg.pull.fail"; runwa
  check "prep: pull que falha segue com o clone que há e diz pull=falhou" "0 completo falhou" "$RC $(sj result) $(sj pull)"
  newrig; runwa; : > "$W/rg.pull.fail"; runwa
  check "prep: pull que falha COM a ponta da última rodada → pull-falhou, exit 3 (um pull que falha para sempre não pode parecer fila parada), nada roda de novo" "3 pull-falhou falhou 1" "$RC $(sj result) $(sj pull) $(calls '^wt-add' "$W/rg.calls")"
  newrig; git -C "$GR/whatsapp_automation/repo.git" update-ref -d refs/remotes/origin/main; runwa
  check "prep: clone sem origin/main → sem-main, exit 3" "3 sem-main" "$RC $(sj result)"
  newrig; : > "$W/rg.wtadd.fail"; runwa
  check "prep: wt-add que falha → wt-add-falhou, exit 3, pytest não roda, ponta não anda" "3 wt-add-falhou ausente ausente" "$RC $(sj result) $([ -e "$W/py.args" ] && echo roda || echo ausente) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  newrig; mkdir -p "$GR/whatsapp_automation/wt/ballast-wa"; : > "$W/rg.wtrm.fail"; runwa
  check "prep: árvore velha que o wt-rm não tira → arvore-velha, exit 3, o pytest não roda (o wt-add diria 'já existe' e a rodada testaria código de outro dia)" "3 arvore-velha ausente" "$RC $(sj result) $([ -e "$W/py.args" ] && echo roda || echo ausente)"
  newrig notests; runwa
  check "prep: árvore sem tests/ → arvore-sem-testes, exit 3, e a árvore é removida" "3 arvore-sem-testes 1" "$RC $(sj result) $(calls '^wt-rm whatsapp_automation ballast-wa' "$W/rg.calls")"
  newrig; runwa BALLAST_WA_PLUGIN="$T/nao-existe.py"
  check "prep: plugin gtn_stable_ids ausente → preparo-ausente, exit 3, nada roda" "3 preparo-ausente ausente" "$RC $(sj result) $([ -e "$W/py.args" ] && echo roda || echo ausente)"
  newrig; runwa BALLAST_ISO_RUN="$T/nao-existe"
  check "prep: gt-iso-run ausente → preparo-ausente (nunca roda sem o isolamento)" "3 preparo-ausente" "$RC $(sj result)"
  newrig; runwa BALLAST_WA_PYTHON="$T/nao-existe"
  check "prep: python do venv ausente → preparo-ausente" "3 preparo-ausente" "$RC $(sj result)"
  # o stub `timeout` não pode deixar o `sleep` do vigia órfão (ppid 1): até 24/10 deixava UM por chamada e uma bateria só enchia o nó de `sleep` (~900 de uma vez). Duração única por execução: outro processo não confunde a conta.
  d=$((4000 + RANDOM % 900)); b=$(orphans "$d"); i=0; while [ "$i" -lt 20 ]; do "$W/bin/timeout" "$d" true 2> /dev/null; i=$((i+1)); done
  check "prep: 20 chamadas instantâneas do stub timeout não deixam nenhum sleep órfão" "0" "$(( $(orphans "$d") - b ))"
  check "prep: o stub timeout continua dando 124 no estouro de prazo e repassando o rc do comando" "124 7" "$("$W/bin/timeout" 1 sleep 30 2> /dev/null; echo $?) $("$W/bin/timeout" 50 sh -c 'exit 7' 2> /dev/null; echo $?)"
}

# ── g_state ──────────────────────────────────────────────────────────────────────────────────────────
g_state() {
  newrig; mkdir -p "$BH/wa-suite.last"; runwa
  check "state: ponta (wa-suite.last) que é PASTA → gravacao-falhou, exit 3 (antes da troca, não depois do resumo), a lista de falhas NÃO é trocada, nenhum .tmp sobra" "3 gravacao-falhou ausente 0" "$RC $(sj result) $([ -e "$BH/wa-suite.failed" ] && echo gravou || echo ausente) $(ls "$BH" | grep -c '\.tmp$')"
  check "state: e há exatamente UM resumo (o de gravacao-falhou, nunca um 'completo' antes dele)" "1" "$(nsum)"
  rmdir "$BH/wa-suite.last"; runwa
  check "state: a rodada seguinte refaz e grava (a falha anterior não consumiu a ponta)" "0 completo" "$RC $(sj result)"
  newrig; : > "$W/py.crash"; runwa
  check "state: o passo de leitura que morre sem imprimir → exit 3 com resumo resumo-falhou, a ponta não anda" "3 resumo-falhou ausente" "$RC $(sj result) $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  check "state: e há exatamente UM resumo" "1" "$(nsum)"

  # TERM no meio: o item repassa ao pytest, apaga a árvore e não grava
  newrig; echo 30 > "$W/py.sleep"; newrd; envwa > "$W/term.out" 2>&1 &
  ipid=$!; i=0; while [ ! -e "$W/py.started" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  ppid_py=$(cat "$W/py.pid" 2>/dev/null)
  kill -TERM "$ipid" 2>/dev/null; wait "$ipid" 2>/dev/null; rc=$?
  check "state: TERM no meio → o item sai 143" "143" "$rc"
  i=0; while [ -n "$ppid_py" ] && kill -0 "$ppid_py" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.2; i=$((i+1)); done
  check "state: TERM repassado ao pytest (o processo do pytest de brinquedo morreu)" "morto" "$(kill -0 "$ppid_py" 2>/dev/null && echo vivo || echo morto)"
  check "state: TERM apaga a árvore e a branch e NÃO grava a ponta" "1 0 ausente" "$(calls '^wt-rm whatsapp_automation ballast-wa' "$W/rg.calls") $(git -C "$GR/whatsapp_automation/repo.git" branch --list 'worker/*' | wc -l | tr -d ' ') $([ -e "$BH/wa-suite.last" ] && echo gravou || echo ausente)"
  # TERM ANTES do pytest (no canário): o governo manda TERM a todos os membros da sessão, o filho morre e o item tem que sair na hora, não esperar 10 s por um pytest que não existe
  newrig; : > "$W/iso.hang"; newrd; envwa > "$W/term.out" 2>&1 &
  ipid=$!; i=0; while [ ! -s "$W/iso.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  s0=$(date +%s); kill -TERM "$ipid" "$(cat "$W/iso.pid" 2>/dev/null)" 2>/dev/null; wait "$ipid" 2>/dev/null; rc=$?
  check "state: TERM antes do pytest nascer (canário pendurado) → o item sai 143 na hora (< 7 s; sem PYPID não há o que esperar)" "143 1" "$rc $([ $(( $(date +%s) - s0 )) -lt 7 ] && echo 1 || echo 0)"
}

# ── g_reg ────────────────────────────────────────────────────────────────────────────────────────────
reg_field() {  # reg_field COLUNA [ITEM] — a coluna (1-8) da linha do ITEM (padrão wa-suite) no registro
  awk -F'\t' -v c="$1" -v nm="${2:-wa-suite}" '$1 == nm { print $c }' "$REGF" | head -n 1
}
num_or_0() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }   # vazio/ilegível/"auto" → 0: o check que usa o número reprova, nunca "cabe" por falta de leitura
g_reg() {
  err=$("$PY" -I - "$GOV" "$REGF" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hb", sys.argv[1]); hb = importlib.util.module_from_spec(spec); spec.loader.exec_module(hb)
items, errs = hb.parse_registry(open(sys.argv[2], encoding="utf-8").read())
names = [i["name"] for i in items]
print("%d %s" % (len(errs), "wa-suite" in names))
PYEOF
)
  check "reg: o registro REAL lê sem erro no governo e traz o wa-suite" "0 True" "$err"
  check "reg: wa-suite é papel work" "work" "$(reg_field 2)"
  case "$(reg_field 3)" in ''|auto|*[!0-9]*) c=0 ;; *) c=$(reg_field 3) ;; esac
  check "reg: núcleos FIXOS (inteiro >= 1): 'auto' levaria o orçamento inteiro e o hq-selftests ficaria horas sem rodar" "1" "$([ "$c" -ge 1 ] && echo 1 || echo 0)"
  check "reg: o prazo cabe a suíte inteira (>= 3 h = 10800 s; a noturna tem meta de 2 h a 14 workers)" "1" "$([ "$(reg_field 5)" -ge 10800 ] 2>/dev/null && echo 1 || echo 0)"
  rq=$(reg_field 7)
  for need in 'exec:~/gt-remote/bin/hetzner-remote-git.sh' 'exec:~/gt-remote/bin/gt-iso-run' 'exec:/usr/local/sbin/gt-netns-run' 'exec:~/gt-remote/venv-wa/bin/python' 'path:~/gt-remote/bin/gtn_stable_ids.py' 'noflag:wa-suite.leak'; do
    check "reg: requires exige $need" "1" "$(printf '%s' "$rq" | tr ',' '\n' | grep -c -x -F "$need")"
  done
  cmd=$(reg_field 8)
  check "reg: o comando ($cmd) existe e é executável na pasta de itens" "1" "$([ -x "$ITEMS/$cmd" ] && echo 1 || echo 0)"
  # CALIBRAÇÃO DA RAM (ga-weaih6): o teto rss_mb é o que o governo cobra (passou, `why=rss`) e entra na regra de partida; ele tem que caber na memória que a suíte REALMENTE usa, medida no nó em 24/10 (WA a1079e0e6,
  # mesmo wa-suite.sh; scripts/hetzner-ballast-wa-suite-mem-probe.py; números e conta em docs/runbooks/hetzner-ballast.md, "Medido"). Suíte maior ou nó diferente = medir de novo e mexer AQUI e no registro.
  local worker_mb=2064 base_mb=1110 collect_mb=1624 p10_mb=27780 cores rss hq start_mb pause_mb need gv
  # worker_mb: o maior worker do xdist com a suíte em 98% (2062 MB; cresce com o progresso, então é o pior caso e não a média) · base_mb: mestre do pytest + gt-iso-run/sudo/timeout (soma de RSS 11050 − 5 workers 9942, também em 98%)
  # collect_mb: o filho `pytest --collect-only` que um teste lança entre 37% e 44% da suíte (pico 1622 MB; some depois) · p10_mb: MemAvailable p10 dos 2432 ticks do governo no nó (40 h; mediana 28953)
  cores=$(num_or_0 "$(reg_field 3)"); rss=$(num_or_0 "$(reg_field 4)"); hq=$(num_or_0 "$(reg_field 4 hq-selftests)")
  # vazio (o governo não imprime os dois números) → gv vazio; falhou/ilegível (o governo não carrega) → gv vazio: os dois viram 0 e reprovam os checks de RAM, nunca passam por falta de leitura
  gv=$("$PY" -I - "$GOV" <<'PYEOF' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hb", sys.argv[1]); hb = importlib.util.module_from_spec(spec); spec.loader.exec_module(hb)
c = hb.load_config({"BALLAST_HOME": "/nonexistent"})
print(c.ram_start_mb, c.ram_pause_mb)
PYEOF
)
  read -r start_mb pause_mb <<< "$gv"; start_mb=$(num_or_0 "${start_mb:-}"); pause_mb=$(num_or_0 "${pause_mb:-}")
  need=$((cores * worker_mb + base_mb + collect_mb))
  check "reg: o rss_mb ($rss) cobre o pior caso MEDIDO de $cores núcleos ($cores × $worker_mb + $base_mb + $collect_mb = $need MB); abaixo disso o governo mata a rodada com why=rss" "1" "$([ "$cores" -ge 1 ] && [ "$rss" -ge 1 ] && [ "$rss" -ge "$need" ] && echo 1 || echo 0)"
  check "reg: o rss_mb ($rss) passa a regra de partida do governo no p10 do nó ($rss + $start_mb <= $p10_mb MB); acima disso o wa-suite quase nunca começa" "1" "$([ "$rss" -ge 1 ] && [ "$start_mb" -ge 1 ] && [ $((rss + start_mb)) -le "$p10_mb" ] && echo 1 || echo 0)"
  check "reg: wa-suite ($rss) + hq-selftests ($hq) rodando juntos não cruzam o piso de pausa de RAM ($pause_mb) no p10 do nó ($p10_mb MB)" "1" "$([ "$rss" -ge 1 ] && [ "$hq" -ge 1 ] && [ "$pause_mb" -ge 1 ] && [ $((rss + hq + pause_mb)) -le "$p10_mb" ] && echo 1 || echo 0)"
  # NÚCLEOS E COOLDOWN (ga-r4lw72, medido no nó em 24/10): o `auto` do hq-selftests é decidido UMA vez, na partida. Às 15:34Z ele começou ao lado do wa-suite de 8 núcleos (orçamento 9 - 8 = 1) e ficou com 1 núcleo por
  # 3 h (rc 124, prazo); sozinho levava o orçamento inteiro e o wa-suite não começava (18:47Z-20:06Z). O trabalho do hq soma ~12.555 s de selftest (maior: 1.200 s), então 1 núcleo não cabe nos 10800 s do prazo.
  local hqc wac cdn it
  hqc=$(num_or_0 "$(reg_field 3 hq-selftests)"); wac=$(num_or_0 "$(reg_field 3)")
  check "reg: o hq-selftests tem núcleos FIXOS (inteiro >= 2), não auto: o auto decidido na partida já deu 1 núcleo por 3 h" "1" "$([ "$hqc" -ge 2 ] && echo 1 || echo 0)"
  check "reg: hq-selftests ($hqc) + wa-suite ($wac) cabem juntos no orçamento de 9 núcleos (16 - 6 de sessões - 1 de reserva): senão o segundo só começa quando o primeiro acaba" "1" "$([ "$hqc" -ge 1 ] && [ "$wac" -ge 1 ] && [ $((hqc + wac)) -le 9 ] && echo 1 || echo 0)"
  check "reg: o prazo do hq-selftests ($(reg_field 5 hq-selftests) s) é pelo menos o dobro de (12555 s de selftest / $hqc núcleos): rodada que estoura o prazo não deixa resultado" "1" "$([ "$hqc" -ge 1 ] && [ "$(num_or_0 "$(reg_field 5 hq-selftests)")" -ge $((2 * 12555 / hqc)) ] && echo 1 || echo 0)"
  for it in wa-suite hq-selftests; do
    cdn=$(num_or_0 "$(reg_field 6 "$it")")
    check "reg: $it espera de 120 a 300 s depois de uma rodada completa (o main já mudou durante a rodada; e cada pergunta é um pull ao espelho do mini, que só atualiza a cada ~5 min)" "1" "$([ "$cdn" -ge 120 ] && [ "$cdn" -le 300 ] && echo 1 || echo 0)"
  done
}

# ── g_sched ──────────────────────────────────────────────────────────────────────────────────────────
g_sched() {  # o governo REAL, o /proc de mentira, as colunas da linha real; requires e comando são de brinquedo
  local H="$T/hs" FP="$T/ps" NOW=1800000000 U=0 NI=0 ID=0 k out pid run
  mkdir -p "$H/items" "$FP"; : > "$H/on"; printf '#!/bin/sh\nsleep 300\n' > "$H/items/sleeper.sh"; chmod +x "$H/items/sleeper.sh"
  awk -F'\t' -v OFS='\t' '$1 == "wa-suite" || $1 == "hq-selftests" { $7 = "-"; $8 = "sleeper.sh"; print }' "$REGF" > "$T/reg.both"
  grep '^wa-suite' "$T/reg.both" > "$H/items.tsv"
  printf 'MemTotal: 32000000 kB\nMemFree: 100 kB\nMemAvailable: %s kB\n' $((28000 * 1024)) > "$FP/meminfo"
  stat() { { echo "cpu  $U $NI 0 $ID 0 0 0 0 0 0"; k=0; while [ "$k" -lt 16 ]; do echo "cpu$k 0 0 0 0 0 0 0 0 0 0"; k=$((k+1)); done; echo "intr 0"; } > "$FP/stat"; }
  gv() { out=$(env PATH="$W/bin:$PATH" BALLAST_HOME="$H" BALLAST_PROC="$FP" BALLAST_NOW="$NOW" BALLAST_LAUNCH_PREFIX='[]' BALLAST_TEST=1 "$PY" -I "$GOV" tick 2>/dev/null); }
  adv() { local tot=$((16 * 60 * 100)); U=$((U + tot * 25 / 100)); ID=$((ID + tot * 75 / 100)); NOW=$((NOW + 60)); stat; }
  field() { printf '%s' "$out" | "$PY" -I -c 'import sys,json
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v=(v.get(k) if isinstance(v,dict) else (v[int(k)] if isinstance(v,list) and k.isdigit() and int(k)<len(v) else None))
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
  stat; gv; adv; gv; adv; gv; adv; gv
  check "sched: com CPU livre o wa-suite começa sozinho com os núcleos da linha real" "wa-suite $(reg_field 3)" "$(field started.0.item) $(field started.0.cores)"
  pid=$(field started.0.pid); run=$(field started.0.run)
  mkdir -p "$FP/$pid"; printf '%s (sh) S 1 %s %s 0 0\n' "$pid" "$pid" "$pid" > "$FP/$pid/stat"; printf '0 256 0 0 0 0 0\n' > "$FP/$pid/statm"; printf 'sh\0-c\0x\0ballast-item:wa-suite:%s\0' "$run" > "$FP/$pid/cmdline"
  grep '^hq-selftests' "$T/reg.both" >> "$H/items.tsv"
  adv; gv
  # orçamento = 16 - 4 (sessões) - 1 (reserva) = 11; o wa-suite leva os núcleos da linha real e o hq-selftests começa ao lado dele com os DELE (fixos)
  check "sched: com o wa-suite rodando, o hq-selftests AINDA começa, com os núcleos fixos da linha real" "hq-selftests $(reg_field 3 hq-selftests)" "$(field started.0.item) $(field started.0.cores)"
  killtree "$H/"
  # O hq-selftests entra PRIMEIRO (era o único elegível: o wa-suite estava em cooldown). Com `auto` ele levava o orçamento inteiro e o wa-suite, com o cooldown já vencido, ficava de fora até o hq acabar (24/10, 18:47Z a
  # 20:06Z, medido). A RAM não impede: com o hq rodando MemAvailable fica em 29 GB (mediana dos ticks do nó), então o wa-suite só espera o orçamento de CPU.
  H="$T/hs2"; FP="$T/ps2"; NOW=1800000000; U=0; NI=0; ID=0; mkdir -p "$H/items" "$FP"; : > "$H/on"; printf '#!/bin/sh\nsleep 300\n' > "$H/items/sleeper.sh"; chmod +x "$H/items/sleeper.sh"
  grep '^hq-selftests' "$T/reg.both" > "$H/items.tsv"
  printf 'MemTotal: 32000000 kB\nMemFree: 100 kB\nMemAvailable: %s kB\n' $((28000 * 1024)) > "$FP/meminfo"
  stat; gv; adv; gv; adv; gv; adv; gv
  check "sched: sozinho, o hq-selftests começa com os núcleos fixos da linha real" "hq-selftests $(reg_field 3 hq-selftests)" "$(field started.0.item) $(field started.0.cores)"
  pid=$(field started.0.pid); run=$(field started.0.run)
  mkdir -p "$FP/$pid"; printf '%s (sh) S 1 %s %s 0 0\n' "$pid" "$pid" "$pid" > "$FP/$pid/stat"; printf '0 256 0 0 0 0 0\n' > "$FP/$pid/statm"; printf 'sh\0-c\0x\0ballast-item:hq-selftests:%s\0' "$run" > "$FP/$pid/cmdline"
  grep '^wa-suite' "$T/reg.both" >> "$H/items.tsv"
  adv; gv
  check "sched: com o hq-selftests JÁ rodando, o wa-suite (cooldown vencido) começa no tick seguinte, com os núcleos da linha real (com auto o hq levava o orçamento inteiro e ele ficava de fora)" "wa-suite $(reg_field 3)" "$(field started.0.item) $(field started.0.cores)"
  killtree "$H/"
}

GRUPOS="run iso read frozen prep state reg sched"
if [ -n "${HBW_MUTANT:-}" ]; then for g in ${HBW_ONLY:-$GRUPOS}; do "g_$g"; done; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HBW_ONLY:-}" ]; then "g_$HBW_ONLY"; echo "── $((n - fails))/$n ok (só g_$HBW_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
[ -n "${HBW_ANCHORS_ONLY:-}" ] || { for g in $GRUPOS; do "g_$g"; done; }

[ -n "${HBW_NO_MUTANTS:-}" ] || {
  # a bateria SEM mutante tem que estar verde: com ela vermelha (carga, relógio, ambiente) qualquer mutante "reprovaria" por motivo nenhum e o controle negativo não prova nada
  [ "$fails" = 0 ] || { echo "── bateria sem mutante VERMELHA ($fails falhas): o controle negativo não vale, nenhum mutante contado"; exit 1; }
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # ARQUIVO@@GRUPO@@DESCRIÇÃO@@ANTES@@DEPOIS — troca EXATAMENTE uma ocorrência numa cópia da pasta de itens (e do registro). GRUPO é o único que roda contra o mutante: quem o pega é o grupo que o mutante mira (uma falha de OUTRO grupo, de carga ou de relógio, não conta como "pego")
  cat > "$T/mutants.txt" <<'MUT'
wa-suite.sh@@iso@@o vazamento do canário não tranca o item@@{ : > "$LEAK"; } 2> /dev/null || lock=falhou@@:
wa-suite.sh@@iso@@canário inerte/vazio segue para a suíte@@summary isolamento-inerte main="${main:0:9}" pull=$pull iso="${canary#GTN-ISO: }"; exit 3 ;;@@: ;;
wa-suite.sh@@run@@sem-novidade nunca é reconhecido@@if [ "$main" = "$(cat "$LAST" 2> /dev/null)" ]; then@@if false; then
wa-suite.sh@@run@@a árvore de trabalho nunca é removida@@{ "$RG" wt-rm "$RIG" "$bead" > /dev/null 2>&1; branch_rm; }; }@@{ :; }; }
wa-suite.sh@@run@@a branch worker/* não sai no fim da rodada@@> /dev/null 2>&1; branch_rm; }; }@@> /dev/null 2>&1; }; }
wa-suite.sh@@run@@a branch velha não sai antes do wt-add (a rodada testaria a ponta de outro dia)@@branch_rm
if ! timeout 900 "$RG" wt-add@@if ! timeout 900 "$RG" wt-add
wa-suite.sh@@iso@@resultado sem a prova de isolamento é aceito@@if not (iso.startswith("isolado") and ok_line and eg != ""):@@if False:
wa-suite.sh@@iso@@a linha `ok ns=` do helper não é exigida@@iso.startswith("isolado") and ok_line and eg != ""@@iso.startswith("isolado") and eg != ""
wa-suite.sh@@iso@@a linha GTN-EGRESS não é exigida@@iso.startswith("isolado") and ok_line and eg != ""@@iso.startswith("isolado") and ok_line
wa-suite.sh@@iso@@o nao-isolado de DENTRO da rodada não tranca@@        open(leak_p, "w").close()@@        pass
wa-suite.sh@@read@@pytest que aborta (rc fora de 0/1) vira resultado@@if prc not in (0, 1):@@if False:
wa-suite.sh@@read@@total abaixo do piso é aceito@@if total < min_total:@@if False:
wa-suite.sh@@read@@lista GTN ausente vira zero falhas (confiável)@@    why = "o pytest não imprimiu a linha GTN-FAILED (o plugin não rodou ou falhou ao montar a lista)"@@    listok = True
wa-suite.sh@@read@@lista parcial (n != ids lidos) é aceita@@if len(ids) != int(mm.group(1)):@@if False:
wa-suite.sh@@read@@reports != falhas+erros do resumo é aceito@@elif int(mm.group(2)) != failed + errors:@@elif False:
wa-suite.sh@@read@@GTN-FAILED duplicada é aceita@@elif len(sent) > 1:@@elif False:
wa-suite.sh@@read@@GTN-FAIL que não é JSON derruba o passo em vez de virar indisponível@@        except (ValueError, TypeError):@@        except (KeyError,):
wa-suite.sh@@read@@base com JSON que não é texto é aceita@@if not all(isinstance(x, str) for x in rows):@@if False:
wa-suite.sh@@run@@a comparação ignora a base (tudo que reprova é novo)@@new = sorted(set(ids) - prev)@@new = sorted(set(ids))
wa-suite.sh@@read@@base ilegível vira 'comparação ok, 0 novas'@@        why = "a linha de base %s não pôde ser lida como lista de ids em JSON" % os.path.basename(prev_p)@@        compare = "ok"
wa-suite.sh@@frozen@@rodada congelada ainda compara@@elif frozen < 0 or frozen >= 60:@@elif False:
wa-suite.sh@@frozen@@o limiar do congelamento é alto demais (6000 s)@@elif frozen < 0 or frozen >= 60:@@elif frozen < 0 or frozen >= 6000:
wa-suite.sh@@frozen@@relógio ilegível conta como zero (não suspeito)@@        frozen = -1@@        frozen = 0
wa-suite.sh@@read@@a base anda mesmo com comparação indisponível@@if compare in ("ok", "primeira"):@@if True:
wa-suite.sh@@run@@a ponta testada nunca é gravada@@staged.append(stage(last_p, full + "\n"))   # a ponta@@pass   # a ponta
wa-suite.sh@@state@@alvo de estado que é pasta só falha na troca, DEPOIS do resumo@@    if os.path.isdir(path):@@    if False:
wa-suite.sh@@state@@falha do passo final vira rc 0@@[ "$prc" -ne 0 ] || exit 0@@exit 0
wa-suite.sh@@state@@o passo que morre sem imprimir não deixa resumo nenhum@@[ "$prc" -eq 3 ] || summary resumo-falhou main="${tested:0:9}" pull="$pull" python_rc="$prc"@@:
wa-suite.sh@@state@@o TERM não é repassado ao pytest@@[ -z "$PYPID" ] || kill -TERM "$PYPID" 2> /dev/null@@:
wa-suite.sh@@run@@GTN_WORKERS não chega ao gt-iso-run@@GTN_WORKERS="$CORES" "$ISO" --@@"$ISO" --
wa-suite.sh@@run@@o -n é fixo em vez de seguir o governo@@-n "$CORES" -p gtn_stable_ids@@-n 2 -p gtn_stable_ids
wa-suite.sh@@prep@@pull que falha é dado como ok@@2>&1 || pull=falhou@@2>&1 || pull=ok
wa-suite.sh@@run@@falha de prazo de teste não é contada@@Timeout \(?>[0-9.]+s@@NUNCA-CASA
wa-suite.sh@@prep@@árvore sem tests/ segue em frente@@[ -d "$WT/tests" ] || {@@true || {
wa-suite.sh@@prep@@wt-add que falha segue em frente@@if ! timeout 900 "$RG" wt-add "$RIG" "$bead" main > "$RD/wt-add.out" 2>&1; then@@if false; then
wa-suite.sh@@prep@@clone sem origin/main segue em frente@@[ -n "$main" ] || { say "o clone não tem origin/main"@@[ -n "x" ] || { say "o clone não tem origin/main"
wa-suite.sh@@prep@@plugin ausente não impede a rodada@@[ -f "$PLUG" ] || {@@true || {
wa-suite.sh@@prep@@gt-iso-run ou python do venv ausente não impedem a rodada@@  [ -x "$need" ] || {@@  true || {
hetzner-ballast.items.txt@@reg@@núcleos viram auto (o hq-selftests passaria horas sem rodar)@@wa-suite\twork\t5\t@@wa-suite\twork\tauto\t
hetzner-ballast.items.txt@@reg@@o prazo do registro não cabe a suíte@@\t5\t13312\t21600\t@@\t5\t13312\t600\t
hetzner-ballast.items.txt@@reg@@o teto de RAM volta a 12288 (a rodada de 5 núcleos mediu 11795 MB de pico, sem folga para o filho de coleta)@@\t5\t13312\t21600\t@@\t5\t12288\t21600\t
hetzner-ballast.items.txt@@reg@@os núcleos voltam a 8 com o teto de 13312 (8 × ~2 GB não cabem)@@\t5\t13312\t21600\t@@\t8\t13312\t21600\t
hetzner-ballast.items.txt@@reg@@o teto sobe para 16384 (nem a regra de partida do governo nem o piso de pausa aceitam)@@\t5\t13312\t21600\t@@\t5\t16384\t21600\t
hetzner-ballast.items.txt@@reg@@o registro deixa de exigir a flag de vazamento@@,noflag:wa-suite.leak@@
hetzner-ballast.items.txt@@reg@@o registro deixa de exigir o plugin@@path:~/gt-remote/bin/gtn_stable_ids.py,@@
hetzner-ballast.items.txt@@reg@@o registro deixa de exigir o gt-iso-run@@exec:~/gt-remote/bin/gt-iso-run,@@
hetzner-ballast.items.txt@@reg@@o registro deixa de exigir o helper de root@@exec:/usr/local/sbin/gt-netns-run,@@
wa-suite.sh@@iso@@a trava que não gravou é dada como gravada (caminho do canário)@@{ : > "$LEAK"; } 2> /dev/null || lock=falhou@@{ : > "$LEAK"; } 2> /dev/null || lock=ok
wa-suite.sh@@iso@@a trava que não gravou é dada como gravada (caminho do passo de leitura)@@        lock = "falhou"   # não gravou a trava@@        lock = "ok"   # não gravou a trava
wa-suite.sh@@read@@base com linha JSON não hashable derruba o passo (TypeError) em vez de virar indisponível@@rows = [json.loads(l) for l in f if l.strip()]@@rows = {json.loads(l) for l in f if l.strip()}
wa-suite.sh@@read@@GTN-FAIL que é lista JSON derruba o passo (só ValueError é pego)@@        except (ValueError, TypeError):@@        except ValueError:
wa-suite.sh@@frozen@@laço de relógio morto não vira desconhecido@@kill -0 "$WATCH" 2> /dev/null || echo -1 > "$RD/frozen"@@:
wa-suite.sh@@frozen@@o sleep do laço de relógio fica órfão no fim@@{ pkill -P "$WATCH" 2> /dev/null; kill "$WATCH" 2> /dev/null; }@@{ kill "$WATCH" 2> /dev/null; }
wa-suite.sh@@prep@@pull que falha com a ponta da última rodada vira sem-novidade@@[ "$pull" = ok ] || { say "o pull falhou@@true || { say "o pull falhou
wa-suite.sh@@prep@@árvore velha que o wt-rm não tirou segue para o wt-add@@[ ! -e "$GR/$RIG/wt/$bead" ] || { say "a árvore velha@@true || { say "a árvore velha
wa-suite.sh@@state@@o TERM antes do pytest espera os 10 s@@[ -n "$PYPID" ] && kill -0 "$PYPID" 2> /dev/null || break@@[ -z "$PYPID" ] || kill -0 "$PYPID" 2> /dev/null || break
hetzner-ballast.items.txt@@reg@@o hq-selftests volta a auto (decidido na partida: já deu 1 núcleo por 3 h)@@hq-selftests\twork\t4\t@@hq-selftests\twork\tauto\t
hetzner-ballast.items.txt@@sched@@o hq-selftests volta a auto (levava o orçamento inteiro e o wa-suite não começava ao lado dele)@@hq-selftests\twork\t4\t@@hq-selftests\twork\tauto\t
hetzner-ballast.items.txt@@reg@@o hq-selftests sobe para 8 núcleos (com o wa-suite não cabem no orçamento de 9)@@hq-selftests\twork\t4\t@@hq-selftests\twork\t8\t
hetzner-ballast.items.txt@@sched@@o hq-selftests sobe para 8 núcleos (o wa-suite não começa ao lado dele)@@hq-selftests\twork\t4\t@@hq-selftests\twork\t8\t
hetzner-ballast.items.txt@@reg@@o hq-selftests cai para 1 núcleo (12555 s de selftest não cabem no prazo)@@hq-selftests\twork\t4\t@@hq-selftests\twork\t1\t
hetzner-ballast.items.txt@@reg@@o cooldown do hq-selftests volta a 600 s (espera pura depois da rodada)@@\t4096\t10800\t180\t@@\t4096\t10800\t600\t
hetzner-ballast.items.txt@@reg@@o cooldown do wa-suite volta a 600 s@@\t5\t13312\t21600\t180\t@@\t5\t13312\t21600\t600\t
hetzner-ballast.items.txt@@reg@@o cooldown do hq-selftests cai a 0 (um pull ao espelho a cada tick)@@\t4096\t10800\t180\t@@\t4096\t10800\t0\t
MUT
  "$PY" -I - "$ITEMS" "$REGF" "$T/mutants.txt" "$T" > "$T/mutants.idx" <<'PYEOF'
import os, re, shutil, sys
items, regf, lst, tmp = sys.argv[1:5]
entries, cur = [], None
for line in open(lst, encoding="utf-8").read().rstrip("\n").split("\n"):   # sem o rstrip a última entrada ganhava um "\n" no fim (o mutante do TERM virava erro de sintaxe e "reprovava" por outro motivo)
    if cur is None or (cur.count("@@") >= 4 and re.match(r"^[a-z][a-z0-9.-]*\.(sh|txt)@@", line)):
        if cur is not None:
            entries.append(cur)
        cur = line
    else:
        cur += "\n" + line
if cur:
    entries.append(cur)
for i, e in enumerate(entries, 1):
    parts = e.split("@@")
    if len(parts) != 5:
        print("%d\tBAD\t-\t%s" % (i, e[:60])); continue
    fn, grp, desc, a, b = parts
    a, b = a.replace("\\t", "\t"), b.replace("\\t", "\t")   # \t nas âncoras do registro (TSV)
    d = "%s/mi%d" % (tmp, i)
    shutil.copytree(items, d)
    shutil.copy(regf, os.path.join(d, "hetzner-ballast.items.txt"))
    path = os.path.join(d, fn)
    src = open(path, encoding="utf-8").read()
    if src.count(a) != 1:
        print("%d\tBAD\t-\t%s" % (i, desc)); continue
    open(path, "w", encoding="utf-8").write(src.replace(a, b))
    print("%d\tOK\t%s\t%s" % (i, grp, desc))
PYEOF
  [ -z "${HBW_ANCHORS_ONLY:-}" ] || { cat "$T/mutants.idx" | awk -F'\t' '{ c[$2]++; if ($2 != "OK") print "ÂNCORA RUIM: " $4 } END { print "âncoras: OK=" c["OK"]+0 " ruins=" c["BAD"]+0 }'; exit 0; }
  JOBS=${HBW_JOBS:-4}
  while IFS="$(printf '\t')" read -r idx st grp desc; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o arquivo mudou?)"; continue; fi
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    ( HBW_MUTANT=1 HBW_ONLY="$grp" HBW_ITEMS_DIR="$T/mi$idx" bash "$0" > "$T/mres.$idx" 2>&1 ) &
  done < "$T/mutants.idx"
  wait
  while IFS="$(printf '\t')" read -r idx st grp desc; do
    [ "$st" = OK ] || continue
    r=$(tail -n 1 "$T/mres.$idx" 2>/dev/null); f=$(grep -m 1 '^FAIL ' "$T/mres.$idx" 2>/dev/null | cut -c6-300)   # f = o check que reprovou (o mutante é pego POR ele; o texto pode ter várias linhas, a 1ª basta)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego pelo grupo $grp ($r)";; "RESULT "*) ok 0 "mutante '$desc' pego em $grp: $f";; *) ok 1 "mutante '$desc': sem resultado ($r)";; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
