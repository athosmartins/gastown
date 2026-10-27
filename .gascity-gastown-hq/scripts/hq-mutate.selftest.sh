#!/usr/bin/env bash
# hq-mutate.selftest.sh (ga-2hd02v.5.6.2) — o motor de mutantes do lastro: acha os testes fracos sem tocar no que não é dele, e sem jaula provada nada roda.
#
# ## Contents
#   Hermético · Casos · Mutantes do motor · Ambiente (97)
#
# HERMÉTICO: tudo numa pasta descartável (árvore falsa, --work, estado) e uma JAULA FALSA que só registra cada execução e deixa passar (assim o que o motor decide é testado em qualquer sistema); git
#   preso à pasta (GIT_CEILING_DIRECTORIES). Cada caso é uma IMPRESSÃO DIGITAL (rc, veredito, contagens, execuções na jaula): o caso vale se a impressão é a esperada e o mutante do motor vale se muda.
# CASOS: operadores (gen) de shell e python: nada dentro de aspas, comentário ou heredoc; ids únicos e estáveis; arquivo ilegível = rc 3 (nunca zero candidatos) · alvos (plan): sujeito achado pelo nome aparado
#   E citado pelo selftest, família, pastas, exclusões, denylist, ordem (recente, sem mutante embutido, menos recente), cobertura, retry_after, hash · varredura: mortos e sobreviventes confirmados, o
#   original intacto, HOME/TMPDIR no slot, slots limpos, cota (--cap), sem-novidade, flaky, baseline vermelha/ambiente, estado ilegível (rc 3, intacto), jaula não provada (rc 97, nada roda), TERM.
# MUTANTES DO MOTOR (cada âncora casa EXATAMENTE 1 vez, senão o caso é INVÁLIDO e reprova, ga-31xxl5): tirar a re-execução do sobrevivente, ignorar a prova da jaula, a baseline, o estado corrompido, a
#   denylist, a ordem, a cota, o hash, a cobertura, o aviso do sobrevivente, escrever no original, rodar fora da jaula, HOME real, família pela metade, TERM, os três mascaramentos do scanner.
# AMBIENTE: com a JAULA REAL (Linux com Landlock, o nó) roda também o caso de contenção (um mutante que escreve fora do --work não deixa rastro); sem ela imprime AMBIENTE e sai 97.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HM="$HERE/hq-mutate.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/hq-mutate-st.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT
export GIT_CEILING_DIRECTORIES="$W" GIT_CONFIG_NOSYSTEM=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: esperava [$2], veio [$3]"; fi; }
ne()  { if [ "$2" != "$3" ]; then ok; else bad "$1: SOBREVIVEU (a impressão não mudou: [$3])"; fi; }
ENG=""   # o motor sob teste: vazio = o de verdade; os mutantes apontam para uma cópia
hm() { python3 -I "${ENG:-$HM}" "$@"; }
# casos independentes rodam EM PARALELO (cada um numa subcasca, com a própria pasta): o resultado vai para um arquivo e é somado no fim (HQM_ST_JOBS = quantos ao mesmo tempo)
JOBS=${HQM_ST_JOBS:-6}; RES="$W/res"; mkdir -p "$RES"; NJ=0
par() {  # par CMD [args…]: roda CMD numa subcasca em que ok/bad escrevem no arquivo do caso
  NJ=$((NJ+1)); local id; id=$(printf '%03d' "$NJ")
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.2; done
  ( ok() { echo ok >> "$RES/$id"; }; bad() { echo "FAIL: $*" >> "$RES/$id"; }; "$@"; [ -e "$RES/$id" ] || echo "FAIL: o caso $1 não deu veredito" >> "$RES/$id" ) &
}
_peq() { local l=$1 e=$2; shift 2; eq "$l" "$e" "$("$@")"; }   # o fp_* roda DENTRO da subcasca (um $(…) no argumento rodaria antes, em série)
peq() { par _peq "$@"; }
reap() {  # soma os resultados dos casos em paralelo
  wait
  local f l
  for f in "$RES"/*; do
    [ -e "$f" ] || continue
    while IFS= read -r l; do if [ "$l" = ok ]; then ok; else bad "${l#FAIL: }"; fi; done < "$f"
  done
  rm -f "$RES"/*
}

# jaula falsa: registra cada prova e cada execução (slot, HOME, TMPDIR) e deixa o comando passar; FAKE_JAIL=inerte recusa a prova
cat > "$W/fakejail.py" << 'PY'
import os, shutil, sys
a = sys.argv[1:]
def log(*x):
    open(os.environ["FAKE_LOG"], "a").write("\t".join(x) + "\n")
if a[:1] == ["--prove"]:
    log("prove")
    if os.environ.get("FAKE_JAIL") == "inerte":
        print("HQSB: inerte fake")
        sys.exit(97)
    print("HQSB: provado fake")
    sys.exit(0)
i = a.index("--")
cmd = a[i + 1:]
# como a jaula de verdade: um --rw que é o HOME ou pai dele é recusado (rc 64) e o comando NÃO roda
rw, home = os.path.realpath(a[i - 1]), os.path.realpath(os.path.expanduser("~"))
if home == rw or home.startswith(rw + "/"):
    sys.exit(64)
kv = dict(x.split("=", 1) for x in cmd[1:] if "=" in x.split("/")[0]) if cmd[0] == "env" else {}
log("run", a[i - 1], kv.get("HOME", ""), kv.get("TMPDIR", ""))
if "timeout" in cmd and not shutil.which("timeout"):
    j = cmd.index("timeout")
    cmd = cmd[:j] + cmd[j + 4:]
os.execvp(cmd[0], cmd)
PY

newfx() { F="$(mktemp -d "$W/fx.XXXXXX")"; F="$(cd -P "$F" && pwd)"; TREE="$F/root/hq"; mkdir -p "$TREE/scripts" "$F/work"; : > "$F/jail.log"; export FAKE_LOG="$F/jail.log"; }
mkst() {  # mkst NOME 'comandos' [pasta]: NOME.selftest.sh dentro do TREE
  printf '#!/bin/bash\nH="$(cd "$(dirname "$0")" && pwd)"\n%s\nexit 0\n' "$2" > "$TREE/${3:-scripts}/$1.selftest.sh"
}
FOO='#!/bin/bash
# foo.sh: fixture
limit=${1:-}
if [ "$limit" -gt 5 ]; then echo big; exit 0; fi
echo small
exit 0'
# foo.sh tem 6 candidatos: dois morrem (cmp-neg, neg-if), quatro sobrevivem (o limite 5 e o rc de saída não são testados)
mkfoo() { printf '%s\n' "$FOO" > "$TREE/scripts/foo.sh"; mkst foo '[ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'; }
sw() { hm sweep --tree "$TREE" --state "$F/state.json" --work "$F/work" --jail "${JAIL:-$W/fakejail.py}" --slots 2 "$@" > "$F/out" 2> "$F/err"; RC=$?; }
# eval só de expressões LITERAIS deste arquivo sobre o JSON que o próprio motor imprimiu (nenhuma entrada externa)
jf() { python3 -I -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1]); print(eval(sys.argv[2]))' "$F/out" "$1" 2> /dev/null; }
runs() { grep -c '^run' "$F/jail.log"; }
cks() { cksum < "$1"; }
cnt() { echo "rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') k=$(jf 'd["killed"]') c=$(jf 'd["confirmed"]') f=$(jf 'd["flaky"]') inv=$(jf 'd["invalid"]') open=$(jf 'd["open_n"]')"; }

# ── operadores (gen) ───────────────────────────────────────────────────────────────────────────
cat > "$W/op.sh" << 'EOF'
#!/bin/bash
# comentário: [ a -eq b ] && exit 1
if [ "$a" -eq 3 ]; then x=1; fi
[ "$a" -lt 2 ] && echo lt || exit 4
[[ "$s" == y ]] || return 0
[ -z "$s" ] && [ ! -n "$s" ]
while read -r l; do :; done
echo "-eq && || exit 1" 'if [ -z x ]' "a \" && b"; echo $# ${#a} # fim && ||
cat <<'EOT'
[ "$a" -eq 3 ] && exit 1
EOT
echo end
EOF
cat > "$W/op.py" << 'EOF'
def f(a, b):
    # comment a == b and True
    s = "a == b and not True"
    if a == b and not b < 3:
        return True
    return a >= 0 or 1  # trailing a != b
EOF
printf 'true && true && true\n' > "$W/dup.sh"
genl() { hm gen "$1" | cut -f2-5 | LC_ALL=C sort | tr ' \t' '_|'; }
EXP_SH='3|eq-ne|-eq|-ne
3|neg-if||!_
3|num+1|3|4
4|and-or|&&|||
4|and-or||||&&
4|cmp-lim|-lt|-le
4|cmp-neg|-lt|-ge
4|exit-rc|4|0
4|neg-test||!_
4|num+1|2|3
4|sem-exit|_||_exit_4|
5|and-or||||&&
5|exit-rc|0|1
5|neg-test||!_
5|sem-exit|_||_return_0|
5|str-eq|==|!=
6|and-or|&&|||
6|neg-test||!_
6|neg-test|!_|
6|z-n|-n|-z
6|z-n|-z|-n
7|neg-if||!_'
EXP_PY='4|lim|<|<=
4|num|3|4
4|sem-not|not|
4|swap|<|>=
4|swap|==|!=
4|swap|and|or
5|swap|True|False
6|lim|>=|>
6|num|0|1
6|num|1|0
6|swap|>=|<
6|swap|or|and'
fp_gen() { echo "sh=$(genl "$W/op.sh" | cksum) py=$(genl "$W/op.py" | cksum) dup=$(hm gen "$W/dup.sh" | cut -f1 | sort -u | wc -l | tr -d ' ')"; }
EXP_GEN="sh=$(printf '%s\n' "$EXP_SH" | cksum) py=$(printf '%s\n' "$EXP_PY" | cksum) dup=2"
peq "gen: operadores de shell e de python, nada em aspas/comentário/heredoc, ids únicos" "$EXP_GEN" fp_gen
eq "gen: os mesmos ids nas duas rodadas" "$(hm gen "$W/op.sh" | cut -f1 | cksum)" "$(hm gen "$W/op.sh" | cut -f1 | cksum)"
printf 'x = """sem fim\n' > "$W/ruim.py"
hm gen "$W/ruim.py" > /dev/null 2>&1;            eq "gen: python que não tokeniza = rc 3, não zero candidatos" 3 $?
hm gen "$W/nao-existe.sh" > /dev/null 2>&1;      eq "gen: arquivo que não abre = rc 3" 3 $?
hm bobagem > /dev/null 2>&1;                     eq "subcomando desconhecido = rc 2" 2 $?
hm sweep > /dev/null 2>&1;                       eq "sweep sem argumentos = rc 2" 2 $?
fp_valid() {
  python3 -I - "${ENG:-$HM}" << 'PY'
import importlib.util, sys
from pathlib import Path
sp = importlib.util.spec_from_file_location("hqm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
a, b, c, d = m.valid(Path("a.sh"), "if x; then"), m.valid(Path("a.sh"), "echo ok"), m.valid(Path("a.py"), "x = ="), m.valid(Path("a.py"), "x = 1")
import os; os.environ["PATH"] = "/nao/existe"
try:
    e = m.valid(Path("a.sh"), "echo ok")
except Exception as x:
    e = "estourou:" + type(x).__name__
print(a, b, c, d, e)
PY
}
peq "valid: mutante que não compila é recusado (bash -n, compile); sem bash não se sabe, então não roda" "False True False True False" fp_valid
fp_fit() {  # a linha de resumo cabe no limite do puxador (6000): os sobreviventes que não cabem saem e a linha diz quantos
  python3 -I - "${ENG:-$HM}" << 'PY'
import contextlib, importlib.util, io, json, sys
sp = importlib.util.spec_from_file_location("hqm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
def run(w):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        m.summary("parcial", killed=3, survivors=[{"id": "x" * 40, "file": "f" * w, "n": i} for i in range(15)])
    l = buf.getvalue().rstrip("\n"); d = json.loads(l)
    return len(l) <= 6000, len(d["survivors"]), d.get("survivors_cortados", 0)
print(run(20), run(600))
PY
}
peq "summary: a linha de resumo cabe em 6000; o que não cabe sai e é contado" "(True, 15, 0) (True, 8, 7)" fp_fit
# ── varredura: impressões digitais ────────────────────────────────────────────────────────────
fp_sweep() {
  newfx; mkfoo; local o; o=$(cks "$TREE/scripts/foo.sh"); sw
  echo "$(cnt) surv=$(jf '",".join(sorted(s["op"] for s in d["survivors"]))') rec=$(jf 'd["recent"]') jail=$(runs) orig=$([ "$(cks "$TREE/scripts/foo.sh")" = "$o" ] && echo igual || echo MUDOU)" \
       "left=$(ls "$F/work" | wc -l | tr -d ' ') home=$(awk -F'\t' -v w="$F/work/slot-" '$1 == "run" && (index($3, w) != 1 || index($4, w) != 1) {n++} END {print n+0}' "$F/jail.log")"
}
EXP_SWEEP="rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 surv=cmp-lim,exit-rc,exit-rc,num+1 rec=indisponivel jail=11 orig=igual left=0 home=0"
fp_again() { newfx; mkfoo; sw; local j; j=$(runs); sw; echo "$(jf 'd["result"]') run=$(jf 'd["mutants_run"]') novas=$(( $(runs) - j ))"; }
fp_cap() {
  newfx; mkfoo; local o="" i
  for i in 1 2 3 4; do sw --cap 2; o="$o $(jf 'd["result"]'):$(jf 'd["mutants_run"]')"; done
  echo "$o verdicts=$(python3 -I -c 'import json,sys; print(sum(len(t["verdicts"]) for t in json.load(open(sys.argv[1]))["targets"].values()))' "$F/state.json")"
}
fp_jail() { newfx; mkfoo; FAKE_JAIL=inerte sw; echo "rc=$RC $(jf 'd["result"]') jail=$(runs) state=$([ -e "$F/state.json" ] && echo existe || echo nao)"; }
fp_base() {  # fp_base RC: o selftest do foo sai com RC mesmo sem mutante
  newfx; mkfoo; mkst foo ": foo.sh; exit $1"; sw
  echo "rc=$RC run=$(jf 'd["mutants_run"]') jail=$(runs) skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))') plan=$(hm plan --tree "$TREE" --state "$F/state.json" | cut -f1)"
}
fp_state() {  # fp_state CONTEÚDO: estado que não lê = rc 3, o arquivo intacto, nada rodou
  newfx; mkfoo; printf '%s' "$1" > "$F/state.json"; local b; b=$(cks "$F/state.json"); sw
  echo "rc=$RC $(jf 'd["result"]') kept=$([ "$(cks "$F/state.json")" = "$b" ] && echo sim || echo NAO) jail=$(runs)"
}
fp_flaky() {  # passa na baseline e na 1ª rodada do mutante, reprova na re-execução: flaky, não sobrevivente
  newfx; printf '#!/bin/bash\nexit 7\n' > "$TREE/scripts/fl.sh"; : > "$F/n"
  mkst fl "echo x >> '$F/n'; [ \"\$(wc -l < '$F/n' | tr -d ' ')\" = 3 ] && exit 1
bash \"\$H/fl.sh\""; sw
  echo "$(cnt) jail=$(runs)"
}
fp_family() {  # o 1º selftest da família (beta-ext) é fraco; o 2º (beta) mata mais um: os dois têm de rodar
  newfx; printf '%s\n' "$FOO" > "$TREE/scripts/beta.sh"
  mkst beta-ext '[ "$(bash "$H/beta.sh" 9)" = big ] || exit 1'; mkst beta 'bash "$H/beta.sh" 9 > /dev/null || exit 1'; sw
  echo "$(cnt)"
}
fp_deny() {
  newfx; mkfoo; printf 'echo d\n' > "$TREE/scripts/delta.sh"; mkst delta 'bash "$H/delta.sh"; : sudo'; sw
  echo "$(cnt) skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))') plan=$(hm plan --tree "$TREE" --state "$F/state.json" | cut -f1,2 | tr '\t\n' '@ ')"
}
fp_shim() {  # fp_shim GC:BD (shim|real): o que o plan diz do alvo cujo texto cita gc e bd; shim = symlink para o remote-shim (o nó Hetzner), real = programa de verdade
  newfx; mkfoo; printf 'echo g\n' > "$TREE/scripts/gx.sh"; mkst gx 'bash "$H/gx.sh"; : gc bd'
  local B="$F/bin" w k; mkdir -p "$B"; : > "$B/remote-shim"; chmod +x "$B/remote-shim"
  for w in gc bd; do
    if [ "$w" = gc ]; then k=${1%%:*}; else k=${1##*:}; fi
    if [ "$k" = shim ]; then ln -s remote-shim "$B/$w"; else printf '#!/bin/sh\nexit 0\n' > "$B/$w"; chmod +x "$B/$w"; fi
  done
  PATH="$B:$PATH" hm plan --tree "$TREE" --state "$F/state.json" | awk -F'\t' '$2 == "scripts/gx.sh" {print $1}'
}
fp_deny2() {  # fp_deny2 TEXTO: o que o plan diz do alvo cujo selftest cita TEXTO
  newfx; mkfoo; printf 'echo g\n' > "$TREE/scripts/gx.sh"; mkst gx "bash \"\$H/gx.sh\"; : $1"
  hm plan --tree "$TREE" --state "$F/state.json" | awk -F'\t' '$2 == "scripts/gx.sh" {print $1}'
}
fp_env() {  # o ambiente do motor (HQM_SECRET: SSH_AUTH_SOCK, tokens, REMOTE_SHIM_CONF…) NÃO chega ao mutante; o PATH chega
  newfx; mkfoo; mkst foo '[ -z "${HQM_SECRET:-}" ] || exit 1
[ -n "${PATH:-}" ] || exit 1
[ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'
  HQM_SECRET=vazou sw; echo "$(cnt) skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))')"
}
fp_ilegivel() { newfx; printf 'x = """sem fim\n' > "$TREE/scripts/ruim.py"; mkst ruim 'python3 "$H/ruim.py" 2> /dev/null; true'; sw; echo "rc=$RC run=$(jf 'd["mutants_run"]') skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))')"; }
fp_hash() { newfx; mkfoo; sw; printf '# mudou\n' >> "$TREE/scripts/foo.sh"; hm plan --tree "$TREE" --state "$F/state.json" | cut -f1,2 | tr '\t' '@'; }
fp_term() {
  newfx; printf '#!/bin/bash\nexit 7\n' > "$TREE/scripts/slow.sh"; mkst slow 'sleep 30; bash "$H/slow.sh"'
  python3 -I "${ENG:-$HM}" sweep --tree "$TREE" --state "$F/state.json" --work "$F/work" --jail "$W/fakejail.py" --slots 2 > "$F/out" 2> "$F/err" & local pid=$! i=0
  while [ "$(runs)" -lt 1 ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done
  kill -TERM "$pid" 2> /dev/null; ( sleep 20; kill -9 "$pid" 2> /dev/null ) & local wd=$!
  wait "$pid"; RC=$?; kill "$wd" 2> /dev/null; wait "$wd" 2> /dev/null
  echo "rc=$RC $(jf 'd["result"]')"
}
fp_sem_alvos() {
  newfx; mkst so 'true'; sw; local a="rc=$RC $(jf 'd["result"]')"
  mkdir -p "$F/v/hq"; hm sweep --tree "$F/v/hq" --state "$F/s2.json" --work "$F/work" --jail "$W/fakejail.py" > "$F/out" 2> /dev/null; echo "$a rc=$? $(jf 'd["result"]')"
}
peq "sweep: mortos, sobreviventes confirmados, original intacto, HOME/TMPDIR no slot, slots limpos" "$EXP_SWEEP" fp_sweep
peq "sweep de novo, mesmo conteúdo: sem-novidade e nada roda (varrer o mesmo é queima disfarçada)" "sem-novidade run=0 novas=0" fp_again
peq "--cap 2: pega os próximos ainda não vistos até cobrir os 6, depois sem-novidade" " completo:2 completo:2 completo:2 sem-novidade:0 verdicts=6" fp_cap
peq "jaula não provada: rc 97, nenhuma execução, nenhum estado" "rc=97 sem-jaula jail=0 state=nao" fp_jail
peq "baseline vermelha pula o alvo (1 execução, nenhum mutante), e o plan diz por quê" "rc=0 run=0 jail=1 skipped=base-vermelha=1 plan=base-vermelha" fp_base 1
peq "baseline 97 pula como base-ambiente" "rc=0 run=0 jail=1 skipped=base-ambiente=1 plan=base-ambiente" fp_base 97
for s in 'lixo{' '' '{"v":99,"targets":{}}' '[]' '{"v":1}'; do
  peq "estado ilegível ($s): rc 3, intacto, nada roda" "rc=3 estado-ilegivel kept=sim jail=0" fp_state "$s"
done
peq "re-execução que reprova = flaky, nunca sobrevivente" "rc=0 completo run=1 k=0 c=0 f=1 inv=0 open=0 jail=3" fp_flaky
peq "a família inteira roda a cada mutante (o 2º selftest mata mais um)" "rc=0 completo run=6 k=3 c=3 f=0 inv=0 open=3" fp_family
EXP_DENYPLAN="denylist:sudo@scripts/delta.sh sem-novidade@scripts/foo.sh "
peq "denylist (sudo no texto) pula o alvo; o outro roda" "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 skipped=denylist=1 plan=$EXP_DENYPLAN" fp_deny
peq "gc e bd que são symlinks para o remote-shim (o nó Hetzner) NÃO são denylist: o alvo roda" "todo" fp_shim shim:shim
peq "gc de verdade é denylist" "denylist:gc" fp_shim real:shim
peq "bd de verdade é denylist mesmo com o gc sendo o shim (decide por programa, não por tudo ou nada)" "denylist:bd" fp_shim shim:real
peq "denylist: kill com sinal e -1 (qualquer ordem) mata o mundo todo" "denylist:kill -s KILL -1" fp_deny2 'kill -s KILL -1'
peq "denylist: tmux (fala com o servidor do tmux por socket unix)" "denylist:tmux" fp_deny2 'tmux send-keys x'
peq "denylist: --unix-socket" "denylist:--unix-socket" fp_deny2 'curl --unix-socket /x http://a'
peq "denylist: kill de um pid só NÃO é denylist (nada de largo demais)" "todo" fp_deny2 'kill -9 "$pid"'
peq "o ambiente do motor não chega ao mutante (env -i), o PATH chega" "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 skipped=" fp_env
peq "sujeito que não tokeniza é ilegivel, não zero candidatos nem queda" "rc=0 run=0 skipped=ilegivel=1" fp_ilegivel
peq "conteúdo mudado: o alvo volta a ser todo" "todo@scripts/foo.sh" fp_hash
peq "TERM: interrompido, rc 143" "rc=143 interrompido" fp_term
peq "sem alvos (selftest sem sujeito; árvore sem scripts/) = rc 3, nunca sem-novidade" "rc=3 sem-alvos rc=3 sem-alvos" fp_sem_alvos
newfx; mkfoo; mkdir "$F/root/w"; hm sweep --tree "$TREE" --state "$F/s.json" --work "$F/root/w" --jail "$W/fakejail.py" > /dev/null 2>&1; eq "--work dentro da árvore copiada = rc 2" 2 $?
newfx; mkfoo; printf 'lixo' > "$F/s.json"; hm plan --tree "$TREE" --state "$F/s.json" > /dev/null 2>&1; eq "plan com estado ilegível = rc 3" 3 $?

# ── plan: sujeito, família, exclusões, ordem, cobertura, retry_after ────────────────────────────────
fp_plan() {
  newfx; local n R="$F/root"
  for n in alpha beta zeta delta gamma hetzner-ballast-q; do echo 'echo x' > "$TREE/scripts/$n.sh"; mkst "$n" "bash \"\$H/$n.sh\""; done
  mkst delta 'bash "$H/delta.sh"; : sudo'; mkst gamma 'true'
  mkdir -p "$TREE/packs/town-deltas/assets"; echo 'x = 1' > "$TREE/packs/town-deltas/assets/eps.py"; mkst eps 'python3 "$H/eps.py"; : mut x' packs/town-deltas/assets
  git -C "$R" init -q
  git -C "$R" add . ; git -C "$R" reset -q -- hq/scripts/alpha.sh hq/scripts/alpha.selftest.sh
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m velho
  git -C "$R" add . ; git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m novo
  local pl="hm plan --tree $TREE --state $F/st.json" h1 h2
  echo '{"v":1,"targets":{}}' > "$F/st.json"
  h1=$($pl | awk -F'\t' '$2 == "scripts/zeta.sh" {print $6}'); h2=$($pl | awk -F'\t' '$2 == "scripts/beta.sh" {print $6}')
  st() { printf '{"v":1,"targets":{"scripts/zeta.sh":%s,"scripts/beta.sh":%s}}' "$1" "$2" > "$F/st.json"; $pl | awk -F'\t' -v r="$3" '$2 == r {print $1}'; }
  local ord cov part skip exp
  ord=$(st "{\"hash\":\"$h1\",\"swept\":100}" "{\"hash\":\"$h2\",\"swept\":500}" scripts/zeta.sh > /dev/null; $pl | awk -F'\t' '{printf "%s@%s ", $1, $2}')
  cov=$(st "{\"hash\":\"$h1\",\"total\":2,\"verdicts\":{\"a\":\"k\",\"b\":\"k\"}}" '{}' scripts/zeta.sh)
  part=$(st "{\"hash\":\"$h1\",\"total\":3,\"verdicts\":{\"a\":\"k\",\"b\":\"k\"}}" '{}' scripts/zeta.sh)
  skip=$(st '{}' "{\"hash\":\"$h2\",\"skip\":\"base-vermelha\",\"retry_after\":99999999999}" scripts/beta.sh)
  exp=$(st '{}' "{\"hash\":\"$h2\",\"skip\":\"base-vermelha\",\"retry_after\":1}" scripts/beta.sh)
  echo "$ord| cov=$cov part=$part skip=$skip exp=$exp"
}
EXP_PLAN="todo@scripts/alpha.sh denylist:sudo@scripts/delta.sh todo@scripts/zeta.sh todo@scripts/beta.sh todo@packs/town-deltas/assets/eps.py | cov=sem-novidade part=todo skip=base-vermelha exp=todo"
peq "plan: alpha (mudou há <7 dias) primeiro; depois sem mutante embutido e menos recente; eps (embutido) por último; gamma e hetzner-ballast fora; cobertura e retry_after" "$EXP_PLAN" fp_plan
# ── mutantes do motor ─────────────────────────────────────────────────────────────────────────────
# mut NOME ANTIGO NOVO: copia o motor e troca ANTIGO por NOVO (tem de casar exatamente 1 vez); o caminho fica em $MP
mut() {
  MP="$W/eng-$1.py"
  python3 -I - "$HM" "$MP" "$2" "$3" << 'PY' || { bad "mutante $1: INVÁLIDO (âncora não casa exatamente 1 vez)"; return 1; }
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
n = t.count(old)
if n != 1:
    print("âncora casa %d vezes: %r" % (n, old[:70]), file=sys.stderr); sys.exit(1)
open(dst, "w", encoding="utf-8").write(t.replace(old, new))
PY
}
# kill NOME FUNÇÃO ESPERADO ANTIGO NOVO [ARG]: o motor mutante tem de dar uma impressão diferente da esperada
kill_it() { mut "$1" "$4" "$5" && ne "mutante $1 ($2)" "$3" "$(ENG="$MP" "$2" ${6+"$6"})"; }
par kill_it sem-reconfirma       fp_flaky   "rc=0 completo run=1 k=0 c=0 f=1 inv=0 open=0 jail=3" '    return "s" if run_slot(ctx, tgt, mutated, tgt["tmo"])[0] == 0 else "f"' '    return "s"'
par kill_it prova-ignorada       fp_jail    "rc=97 sem-jaula jail=0 state=nao" '    if proof is None:' '    if False:'
par kill_it baseline-ignorada    fp_base    "rc=0 run=0 jail=1 skipped=base-vermelha=1 plan=base-vermelha" '            if rc != 0:
                reason = ' '            if False:
                reason = ' 1
par kill_it ambiente-e-vermelha  fp_base    "rc=0 run=0 jail=1 skipped=base-ambiente=1 plan=base-ambiente" '"base-ambiente" if rc == 97 else' '"base-ambiente" if False else' 97
par kill_it denylist-off         fp_deny    "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 skipped=denylist=1 plan=$EXP_DENYPLAN" '        if deny:' '        if False:'
par kill_it shim-ignorado         fp_shim    "todo" 'not in SHIMS]' 'not in ()]' shim:shim
par kill_it shim-invertido       fp_shim    "denylist:gc" 'not in SHIMS]' 'in SHIMS]' real:shim
par kill_it shim-sem-realpath    fp_shim    "todo" 'os.path.realpath(shutil.which(b))' 'shutil.which(b)' shim:shim
par kill_it resumo-sem-corte     fp_fit     "(True, 15, 0) (True, 8, 7)" '    while len(line) > MAX_LINE and' '    while False and'
par kill_it corte-sem-conta      fp_fit     "(True, 15, 0) (True, 8, 7)" 'kw.get("survivors_cortados", 0) + 1' 'kw.get("survivors_cortados", 0)'
par kill_it valid-sem-bash       fp_valid   "False True False True False" '    except (OSError, subprocess.TimeoutExpired):
        return False' '    except ZeroDivisionError:
        return False'
par kill_it env-herdado          fp_env     "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 skipped=" '"env", "-i", *kv, "timeout", "-k"' '"env", *kv, "timeout", "-k"'
par kill_it kill-so-o-9          fp_deny2   "denylist:kill -s KILL -1" '|\bkill\b[^\n]*\s-1\b|' '|kill -(?:9|KILL) -1|' 'kill -s KILL -1'
par kill_it kill-largo-demais    fp_deny2   "todo" '|\bkill\b[^\n]*\s-1\b|' '|\bkill\b|' 'kill -9 "$pid"'
par kill_it tmux-fora            fp_deny2   "denylist:tmux" '|tmux|' '|' 'tmux send-keys x'
par kill_it sobrevivente-calado fp_sweep   "$EXP_SWEEP" '                    new_surv.append(rec)' '                    pass'
par kill_it jaula-nao-usada      fp_sweep   "$EXP_SWEEP" '[sys.executable, "-I", ctx.a.jail, "--rw", str(slot), "--", "env", "-i", *kv, "timeout",' '["env", "-i", *kv, "timeout",'
par kill_it escreve-no-original  fp_sweep   "$EXP_SWEEP" '(cd / tgt["rel"]).write_text(text, encoding="utf-8")' '(ctx.tree / tgt["rel"]).write_text(text, encoding="utf-8")'
par kill_it home-na-jaula    fp_sweep   "$EXP_SWEEP" 'p = subprocess.Popen(cmd, cwd=cd, stdin=' 'p = subprocess.Popen(cmd, cwd=cd, env=dict(os.environ, HOME=str(slot / "home")), stdin='
par kill_it home-real            fp_sweep   "$EXP_SWEEP" '+ ["HOME=%s" % (slot / "home"), ' '+ ['
par kill_it sem-cobertura        fp_again   "sem-novidade run=0 novas=0" '        elif "total" in old and len(old.get("verdicts", {})) >= old["total"]:' '        elif False:'
par kill_it cota-ignorada        fp_cap     " completo:2 completo:2 completo:2 sem-novidade:0 verdicts=6" '                if len(pick) >= a.cap:' '                if False:'
par kill_it hash-ignorado        fp_hash    "todo@scripts/foo.sh" '        old = old if old.get("hash") == h else {}' '        old = old'
par kill_it familia-so-1         fp_family  "rc=0 completo run=6 k=3 c=3 f=0 inv=0 open=3" '    for st in tgt["family"]:
        cmd =' '    for st in tgt["family"][:1]:
        cmd ='
par kill_it term-ignorado        fp_term    "rc=143 interrompido" '        ctx.stop.set()
        for pid in list(ctx.pids):' '        for pid in list(ctx.pids):'
par kill_it ilegivel-derruba     fp_ilegivel "rc=0 run=0 skipped=ilegivel=1" '            except (OSError, ValueError, SyntaxError, tokenize.TokenError):
                skipped["ilegivel"]' '            except OSError:
                skipped["ilegivel"]'
par kill_it estado-zera          fp_state   "rc=3 estado-ilegivel kept=sim jail=0" '    except FileNotFoundError:
        return {"v": VERSION, "targets": {}}' '    except (FileNotFoundError, ValueError):
        return {"v": VERSION, "targets": {}}' 'lixo{'
par kill_it ordem-invertida      fp_plan    "$EXP_PLAN" 'plan.sort(key=lambda t: (not t["recent"],' 'plan.sort(key=lambda t: (t["recent"],'
par kill_it embutido-ignorado    fp_plan    "$EXP_PLAN" 't["embedded"], t["swept"], t["rel"]' 't["swept"], t["rel"]'
par kill_it swept-ignorado       fp_plan    "$EXP_PLAN" 't["embedded"], t["swept"], t["rel"]' 't["embedded"], t["rel"]'
par kill_it retry-ignorado       fp_plan    "$EXP_PLAN" '        elif old.get("skip") and now < old.get("retry_after", 0):' '        elif old.get("skip"):'
par kill_it ocorrencia-ignorada  fp_gen     "$EXP_GEN" '"%s:%d" % (key, seen[key])' '"%s:%d" % (key, 1)'
par kill_it aspas-sao-codigo     fp_gen     "$EXP_GEN" "            elif c == \"'\":
                sq = True" "            elif c == \"'\":
                pass"
par kill_it comentario-e-codigo  fp_gen     "$EXP_GEN" '            elif c == "#" and (' '            elif False and ('
par kill_it heredoc-e-codigo     fp_gen     "$EXP_GEN" '                    here = (m.group(3), m.group(1) == "-")' '                    here = None'
par kill_it valid-sh-sempre      fp_valid   "False True False True" 'timeout=30).returncode == 0' 'timeout=30).returncode >= 0'
par kill_it valid-py-sempre      fp_valid   "False True False True" '            compile(text, str(path), "exec")
            return True' '            return True'
reap
# controle do controle: o `mut` recusa uma âncora ambígua e uma que não casa
FAIL0=$FAIL   # o mut recusa e conta uma falha própria: aqui a recusa é o esperado, então só a aceitação reprova
if mut ancora-ambigua 'import' 'import' > /dev/null 2>&1; then bad "mut aceitou âncora que casa várias vezes"; else FAIL=$FAIL0; ok; fi
if mut ancora-ausente 'texto-que-nao-existe-no-motor' 'y' > /dev/null 2>&1; then bad "mut aceitou âncora que não casa"; else FAIL=$FAIL0; ok; fi

# ── jaula real (o nó): o mutante que escreve fora do --work não deixa rastro ───────────────────
SKIP=0
out=$(python3 -I "$HERE/hq-sandbox-run.py" --probe 2>&1) && case "$out" in "HQSB: abi="*) ;; *) SKIP=1 ;; esac || SKIP=1
if [ "$SKIP" = 1 ]; then
  echo "AMBIENTE: sem Landlock ABI >= 4 aqui ($out): o caso com a jaula REAL não rodou (o nó roda)"
else
  newfx; mkfoo; mkdir "$F/fora"; export FORA="$F/fora"
  mkst foo '( echo x > "$FORA/vazou" ) 2> /dev/null; [ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'
  JAIL="$HERE/hq-sandbox-run.py" sw
  eq "jaula real: o veredito é o mesmo e nenhuma execução escreveu fora do --work" "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 vazou=nao" "$(cnt) vazou=$([ -e "$F/fora/vazou" ] && echo SIM || echo nao)"
  ( cd "$TREE" && bash scripts/foo.selftest.sh ) > /dev/null 2>&1; [ -e "$F/fora/vazou" ] && ok || bad "controle: sem a jaula o mesmo selftest ESCREVE fora (senão 'não vazou' não provaria nada)"
fi

echo "hq-mutate selftest: $PASS passed, $FAIL failed$([ "$SKIP" = 1 ] && echo ", caso da jaula real NÃO rodou (AMBIENTE)")"
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP" -eq 0 ] || exit 97
exit 0
