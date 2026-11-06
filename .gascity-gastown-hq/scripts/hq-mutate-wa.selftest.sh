#!/usr/bin/env bash
# hq-mutate-wa.selftest.sh (ga-tmfmvxi) — a varredura de mutantes do código do WA: acha o teste fraco do lib/ e do daemons/, com a família de testes INTEIRA, sem tocar na árvore de origem e sem rodar nada que a jaula não segure.
#
# ## Contents
#   Hermético · Casos · Regra de conjunto de falhas · Mutantes do wrapper
#
# HERMÉTICO: pasta descartável, uma JAULA FALSA (a do hq-mutate.selftest.sh: registra cada execução e deixa passar) e um PYTHON FALSO (`fakepy`: aceita `-m pytest … ARQUIVOS`, roda cada arquivo de teste como script, na ordem, e para no primeiro que reprova, como o `-x`).
#   O python falso registra onde foi chamado, com que HOME/TMPDIR/PYTHONHASHSEED e com que argumentos: é o que prova que o pytest roda no slot, dentro do ambiente limpo e com a família certa. Não precisa de pytest nem do venv do WA: o que se mede aqui é o wrapper (hq-mutate-wa.py), não o pytest.
# O MOTOR (hq-mutate.py: operadores, veredito, estado, teto de escrita, TERM) tem a bateria própria (hq-mutate.selftest.sh); aqui entra só o que o wrapper troca: quem é o alvo e a família, o que se pula, o que vira candidato e como o pytest é chamado.
# CASOS: cada caso é uma IMPRESSÃO DIGITAL (rc, veredito, contagens, argumentos do pytest, onde e com que ambiente ele rodou): vale se for a esperada, e o MUTANTE do wrapper vale se ela mudar (âncora que não casa exatamente 1 vez = INVÁLIDO).
#   A árvore do caso tem 3 alvos com 12 mutantes (calc 7, pkg/mod 3, runner 2) e tests/ pensado para que CADA regra de família seja a única a matar algum mutante: sem os testes pelo NOME (test_calc_edge) dois mutantes sobrevivem, sem os IMPORTADORES (test_users) outros dois,
#   e o test_calcify (começa com `calc` mas sem fronteira, e só importa por importlib) fica FORA e deixa dois sobreviventes que só ele mataria.
# REGRA DE CONJUNTO DE FALHAS (ga-z137atn, --max-bad): a baseline que NÃO dá 0 por poucos testes quebrados (ambiente da jaula) deixa de pular o alvo; ver o bloco «regra de morte» abaixo. Quatro níveis de prova: (1) a varredura inteira com o python falso, que faz o papel do plugin quando o caso manda (ctl.json) e registra
#   PYTHONPATH, WAM_SKIP e WAM_FAILS; (2) as funções puras (near_green, wa_save_state) importadas do wrapper; (3) o PLUGIN do pytest com objetos de mentira; (4) ponta a ponta com o pytest de verdade, se houver um python com pytest e pytest-timeout (senão AMBIENTE, exit 97: o venv do WA do nó tem).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HM="$HERE/hq-mutate-wa.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/hq-mutate-wa-st.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT
export GIT_CEILING_DIRECTORIES="$W" GIT_CONFIG_NOSYSTEM=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: esperava [$2], veio [$3]"; fi; }
ne()  { if [ "$2" != "$3" ]; then ok; else bad "$1: SOBREVIVEU (a impressão não mudou: [$3])"; fi; }
ENG=""   # o wrapper sob teste: vazio = o de verdade; os mutantes apontam para uma pasta com a cópia mutada ao lado do hq-mutate.py
hm() { python3 -I -B "${ENG:-$HM}" "$@"; }
PY3="$(python3 -I -B -c 'import sys; print(sys.executable)')"
[ -x "$PY3" ] || { echo "hq-mutate-wa selftest: sem python3"; exit 3; }
# casos independentes rodam EM PARALELO (cada um numa subcasca, com a própria pasta): o resultado vai para um arquivo e é somado no fim (HQMW_ST_JOBS = quantos ao mesmo tempo)
JOBS=${HQMW_ST_JOBS:-6}; RES="$W/res"; mkdir -p "$RES"; NJ=0
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

# jaula falsa (a do hq-mutate.selftest.sh): registra cada prova e cada execução (slot, HOME, TMPDIR) e deixa o comando passar; FAKE_JAIL=inerte recusa a prova
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
# python falso: `-m pytest [opções] ARQ.py…` roda cada ARQ.py (relativo ao cwd = a cópia da árvore) como script, com lib/, daemons/ e a raiz no sys.path, e sai com o rc do primeiro que reprova.
# Registra (TAB): py · cwd · HOME · PYTHONHASHSEED · argumentos · HQM_SECRET (tem de vir vazio: o `env -i` do motor) · TMPDIR · PYTHONPATH · WAM_SKIP · WAM_FAILS (os três últimos são da regra de conjunto de falhas, ga-z137atn)
# ctl.json (opcional, escrito pelo caso): na baseline com o plugin (`-p wam_plug`, sem `-x`) da família que cita `match`, o python falso faz o PAPEL DO PLUGIN: grava `out` (objeto ou texto cru) em $WAM_FAILS e sai com `rc`. O plugin de verdade tem os casos dele (fp_plug) e o de ponta a ponta com pytest real (fp_e2e)
{ printf '#!%s\n' "$PY3"; cat << 'PY'
import json, os, subprocess, sys
a = sys.argv[1:]
here = os.path.dirname(os.path.abspath(sys.argv[0]))
open(os.path.join(here, "py.log"), "a").write("\t".join(["py", os.getcwd(), os.environ.get("HOME", ""), os.environ.get("PYTHONHASHSEED", ""), " ".join(a), os.environ.get("HQM_SECRET", ""), os.environ.get("TMPDIR", ""), os.environ.get("PYTHONPATH", ""), os.environ.get("WAM_SKIP", ""), os.environ.get("WAM_FAILS", "")]) + "\n")
if a[:2] != ["-m", "pytest"]:
    sys.exit(5)
ctl = os.path.join(here, "ctl.json")
if os.path.exists(ctl) and "wam_plug" in a and "-x" not in a:
    c = json.load(open(ctl))
    if c["match"] in a:
        if "out" in c:
            open(os.environ["WAM_FAILS"], "w").write(c["out"] if isinstance(c["out"], str) else json.dumps(c["out"]))
        sys.exit(c["rc"])
boot = "import runpy, sys\nsys.path[:0] = [sys.argv[1] + '/lib', sys.argv[1] + '/daemons', sys.argv[1]]\nrunpy.run_path(sys.argv[2], run_name='__main__')\n"
for f in [x for x in a[2:] if x.endswith(".py")]:
    rc = subprocess.call([sys.executable, "-I", "-B", "-c", boot, os.getcwd(), f])
    if rc:
        sys.exit(rc)
PY
} > "$W/fakepy"

newfx() {
  F="$(mktemp -d "$W/fx.XXXXXX")"; F="$(cd -P "$F" && pwd)"; TREE="$F/root/wa"; mkdir -p "$TREE" "$F/work"
  : > "$F/jail.log"; : > "$F/py.log"; export FAKE_LOG="$F/jail.log"; cp "$W/fakepy" "$F/fakepy"; chmod +x "$F/fakepy"
}
# a árvore do WA em miniatura: ver o cabeçalho para o que cada arquivo mata. crew/, node_modules/, .git, __pycache__ e *.bak-* existem para NÃO serem copiados (o test_calc confere)
mkwa() {
  mkdir -p "$TREE/lib/pkg" "$TREE/lib/__pycache__" "$TREE/daemons" "$TREE/tests" "$TREE/crew" "$TREE/node_modules" "$TREE/.git"
  printf 'def inc(a):\n    return a + 1\n\n\ndef lt(a, b):\n    return a < b and a >= 0\n' > "$TREE/lib/calc.py"
  cp "$TREE/lib/calc.py" "$TREE/lib/calc.py.bak-1"; echo x > "$TREE/lib/__pycache__/calc.pyc"; echo x > "$TREE/crew/x.py"; echo x > "$TREE/node_modules/m.js"; echo x > "$TREE/.git/x"
  : > "$TREE/lib/pkg/__init__.py"
  printf 'def pos(x):\n    return x > 0\n' > "$TREE/lib/pkg/mod.py"
  printf 'import logging\nlog = logging.getLogger("r")\n\n\ndef go(n):\n    log.info("go %%s", n == 3)\n    print("n is", n != 3)\n    return n == 3\n' > "$TREE/daemons/runner.py"
  printf 'import os\nfrom calc import inc\nfor p in ("crew", "node_modules", ".git", "lib/__pycache__", "lib/calc.py.bak-1"):\n    assert not os.path.exists(p), p\nassert inc(1) == 2\n' > "$TREE/tests/test_calc.py"
  printf 'import importlib\nassert importlib.import_module("calc").lt(2, 2) is False\n' > "$TREE/tests/test_calc_edge.py"
  printf 'import calc\nassert calc.lt(1, 2) is True\n' > "$TREE/tests/test_users.py"
  printf 'import importlib\ncalc = importlib.import_module("calc")\nassert calc.lt(0, 1) is True\n' > "$TREE/tests/test_calcify.py"
  printf 'from pkg import mod\nassert mod.pos(1) is True\n' > "$TREE/tests/test_pkgs.py"
  printf 'import runner\nassert runner.go(3) is True\n' > "$TREE/tests/test_runner.py"
}
tree_ck() { ( cd "$TREE" && find . -type f -not -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do cat "$f"; done | cksum ); }
sw() { hm sweep --tree "$TREE" --state "$F/state.json" --work "$F/work" --jail "$W/fakejail.py" --python "${PYBIN:-$F/fakepy}" --slots 2 "$@" > "$F/out" 2> "$F/err"; RC=$?; }
# eval só de expressões LITERAIS deste arquivo sobre o JSON que o próprio motor imprimiu (nenhuma entrada externa)
jf() { python3 -I -B -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1]); print(eval(sys.argv[2]))' "$F/out" "$1" 2> /dev/null; }
runs() { grep -c '^run' "$F/jail.log"; }
cnt() { echo "rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') k=$(jf 'd["killed"]') c=$(jf 'd["confirmed"]') f=$(jf 'd["flaky"]') inv=$(jf 'd["invalid"]') open=$(jf 'd["open_n"]')"; }
skp() { jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))'; }
pyargs() { awk -F'\t' '{print $5}' "$F/py.log"; }
# a FORMA de cada chamada ao pytest, contadas (uma por linha do py.log): fase (base = sem -x, a baseline da regra · mut = com -x), o que ela levou [plug = -p wam_plug · cont = --continue-on-collection-errors · skip = WAM_SKIP · fails = WAM_FAILS · pp = PYTHONPATH] e a família
shapes() {
  awk -F'\t' '{
    a = $5; ph = (a ~ / -x /) ? "mut" : "base"; w = ""
    if (a ~ / -p wam_plug /) w = w ",plug"
    if (a ~ / --continue-on-collection-errors /) w = w ",cont"
    if ($9 != "") w = w ",skip"
    if ($10 != "") w = w ",fails"
    if ($8 != "") w = w ",pp"
    sub(/.* --timeout=[0-9]* (--continue-on-collection-errors )?/, "", a)
    print ph "[" substr(w, 2) "] " a
  }' "$F/py.log" | LC_ALL=C sort | uniq -c | sed 's/^ *//' | paste -sd'|' -
}
stx() {  # stx [CHAVE=excl] — a CHAVE de cada alvo no estado do motor (- = não existe)
  python3 -I -B -c 'import json, sys; t = json.load(open(sys.argv[1]))["targets"]; print(",".join("%s=%s" % (k.rsplit("/", 1)[-1], t[k].get(sys.argv[2], "-")) for k in sorted(t, key=lambda k: k.rsplit("/", 1)[-1])))' "$F/state.json" "${1:-excl}"
}

# ── a varredura inteira ────────────────────────────────────────────────────────────────────────────
fp_sweep() {
  newfx; mkwa; local o; o=$(tree_ck); HQM_SECRET=vazou sw
  echo "$(cnt) surv=$(jf '",".join(sorted("%s:%s" % (s["file"].rsplit("/", 1)[-1], s["op"]) for s in d["survivors"]))') jail=$(runs) orig=$([ "$(tree_ck)" = "$o" ] && echo igual || echo MUDOU) left=$(ls "$F/work" | wc -l | tr -d ' ')" \
       "flags=$(pyargs | sed 's/ tests\/.*//' | sort -u | paste -sd'|' -)" \
       "fam=$(pyargs | sed 's/.* --timeout=[0-9]* //' | sort -u | paste -sd'|' -)" \
       "slot=$(awk -F'\t' -v w="$F/work/slot-" '{ if (index($2, w) != 1 || $2 !~ /\/clone$/ || index($3, w) != 1 || index($7, w) != 1) n++ } END {print n+0}' "$F/py.log") seed=$(awk -F'\t' '{print $4}' "$F/py.log" | sort -u | paste -sd'|' -) leak=$(awk -F'\t' '$6 != ""' "$F/py.log" | wc -l | tr -d ' ')"
}
EXP_SWEEP="rc=0 completo run=12 k=9 c=3 f=0 inv=0 open=3 surv=calc.py:lim,calc.py:num,mod.py:lim jail=18 orig=igual left=0 flags=-m pytest -p no:cacheprovider -p no:randomly -q -x --tb=no --no-header --timeout=120 fam=tests/test_calc.py tests/test_calc_edge.py tests/test_users.py|tests/test_pkgs.py|tests/test_runner.py slot=0 seed=0 leak=0"
peq "sweep: 12 mutantes (9 mortos, 3 sobreviventes confirmados), família = nome + importadores (test_calcify fora), pytest no slot/ambiente limpo, árvore de origem intacta" "$EXP_SWEEP" fp_sweep

fp_again() { newfx; mkwa; sw; local j; j=$(runs); sw; echo "$(jf 'd["result"]') run=$(jf 'd["mutants_run"]') novas=$(( $(runs) - j ))"; }
peq "segunda varredura sem mudança: sem-novidade, nenhuma execução nova (o estado do motor vale pelo hash do wrapper)" "sem-novidade run=0 novas=0" fp_again

fp_hash() {  # mexer num teste DA família reabre o alvo; mexer no que não é da família (test_calcify) não
  newfx; mkwa; sw
  printf '# mudou\n' >> "$TREE/tests/test_calcify.py"; local a b
  a=$(hm plan --tree "$TREE" --state "$F/state.json" | cut -f1,2 | sort | tr '\t' '@' | paste -sd' ' -)
  printf '# mudou\n' >> "$TREE/tests/test_calc_edge.py"
  b=$(hm plan --tree "$TREE" --state "$F/state.json" | cut -f1,2 | sort | tr '\t' '@' | paste -sd' ' -)
  echo "$a | $b"
}
EXP_HASH="sem-novidade@daemons/runner.py sem-novidade@lib/calc.py sem-novidade@lib/pkg/mod.py | sem-novidade@daemons/runner.py sem-novidade@lib/pkg/mod.py todo@lib/calc.py"
peq "hash: o teste que não é da família não reabre o alvo; o da família reabre só o dele" "$EXP_HASH" fp_hash

fp_red() {  # a família reprova SEM mutante: base-vermelha, nada de mutante rodado, nunca cobertura declarada
  newfx; mkdir -p "$TREE/lib" "$TREE/tests"; printf 'x = 1\n' > "$TREE/lib/red.py"; printf 'import red\nassert False\n' > "$TREE/tests/test_red.py"; sw
  echo "rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') skipped=$(skp) jail=$(runs) rule=$(stx rule)"
}
peq "baseline vermelha SEM a regra: sem-cobertura, base-vermelha=1, 0 mutantes (só a baseline foi à jaula) e o estado NÃO grava rule" "rc=0 sem-cobertura run=0 skipped=base-vermelha=1 jail=1 rule=red.py=-" fp_red

# ── plano: família, pulos, ordem ───────────────────────────────────────────────────────────────────
fp_plan() {
  newfx; mkwa; local R="$TREE" s
  printf 'x = 1\n' > "$R/lib/lonely.py"
  printf 'x = 1\n' > "$R/lib/crowd.py"; for s in a b c d; do printf 'import crowd\n' > "$R/tests/test_crowd_$s.py"; done
  printf 'import os\n\n\ndef f(p):\n    os.kill(p, 9)\n' > "$R/lib/killer.py"; printf 'import killer\n' > "$R/tests/test_killer.py"
  printf 'import os\n\n\ndef g(p):\n    os.killpg(p, 9)\n' > "$R/lib/grouper.py"; printf 'import grouper\n' > "$R/tests/test_grouper.py"
  printf 'x = 1\n' > "$R/lib/watch.py"; printf 'import watch\nimport psutil\n' > "$R/tests/test_watch.py"
  printf 'x = 1\n' > "$R/lib/priv.py"; printf 'import priv\n# sudo\n' > "$R/tests/test_priv.py"
  mkdir -p "$F/ext"; printf 'x = 1\n' > "$F/ext/linked.py"; ln -s "$F/ext/linked.py" "$R/lib/linked.py"; printf 'import linked\n' > "$R/tests/test_linked.py"
  printf 'def helper():\n    pass\n' > "$R/lib/test_helpers.py"; : > "$R/lib/conftest.py"; printf 'x = 1\n' > "$R/lib/pkg/setup.py"; printf 'x = 1\n' > "$R/lib/old.bak-2.py"
  mkdir -p "$R/lib/crew" "$R/lib/archive"; printf 'x = 1\n' > "$R/lib/crew/c.py"; printf 'x = 1\n' > "$R/lib/archive/a.py"
  git -C "$R" init -q; git -C "$R" add . ; git -C "$R" reset -q -- lib/calc.py tests/test_pkgs.py
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m velho
  git -C "$R" add . ; git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m novo
  hm plan --tree "$TREE" --state "$F/st.json" --fam-cap 3 | cut -f1,2 | tr '\t' '@' | paste -sd' ' -
}
EXP_PLAN="todo@lib/calc.py todo@lib/pkg/mod.py todo@daemons/runner.py familia-grande@lib/crowd.py denylist:os.killpg@lib/grouper.py denylist:os.kill@lib/killer.py symlink@lib/linked.py sem-teste@lib/lonely.py denylist:sudo@lib/priv.py denylist:psutil@lib/watch.py"
peq "plan: recentes primeiro (o sujeito OU um teste da família mudou há <7 dias); depois por nome; sem-teste, familia-grande (4>3, 3 entra), symlink, denylist (os.kill, sudo no teste, psutil no teste); test_/conftest/setup/.bak/crew/archive fora" "$EXP_PLAN" fp_plan

fp_retry() {  # o skip gravado vale até o retry_after; vencido, o alvo volta
  newfx; mkwa; local h a b
  h=$(hm plan --tree "$TREE" --state "$F/st.json" | awk -F'\t' '$2 == "lib/calc.py" {print $6}')
  printf '{"v":1,"targets":{"lib/calc.py":{"hash":"%s","skip":"base-vermelha","retry_after":99999999999}}}' "$h" > "$F/st.json"
  a=$(hm plan --tree "$TREE" --state "$F/st.json" | awk -F'\t' '$2 == "lib/calc.py" {print $1}')
  printf '{"v":1,"targets":{"lib/calc.py":{"hash":"%s","skip":"base-vermelha","retry_after":1}}}' "$h" > "$F/st.json"
  b=$(hm plan --tree "$TREE" --state "$F/st.json" | awk -F'\t' '$2 == "lib/calc.py" {print $1}')
  echo "$a $b"
}
peq "retry_after: base-vermelha gravada vale até vencer; vencida, o alvo é todo" "base-vermelha todo" fp_retry

fp_arvore() {  # árvore que não é a do WA, sem alvo, com teste que não abre: rc 3 e NADA roda (nem a baseline)
  newfx; local o="" d
  mkdir -p "$F/a/lib"; printf 'x = 1\n' > "$F/a/lib/m.py"                                  # sem tests/
  mkdir -p "$F/b/tests"; printf 'x = 1\n' > "$F/b/tests/test_m.py"                         # sem lib/ nem daemons/
  mkdir -p "$F/c/lib" "$F/c/tests"; : > "$F/c/lib/__init__.py"; printf 'x = 1\n' > "$F/c/tests/test_m.py"   # lib/ sem nenhum alvo
  mkwa; ln -s /nao/existe "$TREE/tests/test_fantasma.py"                                    # teste que não abre
  for d in "$F/a" "$F/b" "$F/c" "$TREE"; do hm plan --tree "$d" --state "$F/st.json" > /dev/null 2>&1; o="$o $?"; done
  sw; echo "$o | rc=$RC $(jf 'd["result"]') run=$(runs)"
}
peq "plan de árvore sem tests/, sem lib/ nem daemons/, sem alvo, ou com teste que não abre = rc 3; a varredura dessa última dá sem-alvos e nada roda" " 3 3 3 3 | rc=3 sem-alvos run=0" fp_arvore

# ── candidatos: nada em linha de log/print ─────────────────────────────────────────────────────────
fp_gen() { newfx; mkwa; hm gen "$TREE/daemons/runner.py" --tree "$TREE" | cut -f2-5 | tr ' \t' '_|' | paste -sd' ' -; }
peq "gen: só a linha do return (8); o texto de log.info(...) e de print(...) não vira candidato" "8|swap|==|!= 8|num|3|4" fp_gen

# ── uso: --python, --fam-cap, --pytest-timeout ─────────────────────────────────────────────────────
fp_uso() {
  newfx; mkwa; local o="" a="--tree $TREE --state $F/st.json"
  hm sweep $a --work "$F/work" --jail "$W/fakejail.py" > /dev/null 2>&1;                                    o="$o $?"   # sem --python
  hm sweep $a --work "$F/work" --jail "$W/fakejail.py" --python /nao/existe > /dev/null 2>&1;               o="$o $?"   # --python que não é executável
  hm plan $a > /dev/null 2>&1;                                                                              o="$o $?"   # o plan não precisa do python
  hm plan $a --fam-cap 0 > /dev/null 2>&1;                                                                  o="$o $?"
  hm plan $a --pytest-timeout 0 > /dev/null 2>&1;                                                           o="$o $?"
  echo "$o jail=$(runs)"
}
peq "uso: sweep sem --python ou com --python que não executa = 2; plan sem --python = 0; --fam-cap 0 e --pytest-timeout 0 = 2; nada foi à jaula" " 2 2 0 2 2 jail=0" fp_uso
fp_tmo() { newfx; mkwa; sw --pytest-timeout 7; echo "$(cnt) flags=$(pyargs | sed 's/ tests\/.*//' | sort -u | paste -sd'|' -)"; }
peq "--pytest-timeout 7 chega ao pytest como --timeout=7" "rc=0 completo run=12 k=9 c=3 f=0 inv=0 open=3 flags=-m pytest -p no:cacheprovider -p no:randomly -q -x --tb=no --no-header --timeout=7" fp_tmo
# TETO DE DADOS (ga-2hd02v.5.11): o wrapper põe o MESMO teto do motor (--data-mb, RLIMIT_DATA) no processo do pytest, e o filho herda. O teste de família tenta alocar 300 MB e grava o resultado FORA do slot (a jaula falsa deixa): com --data-mb 128 a alocação falha
# (MemoryError), sem o teto passa. O RLIMIT_DATA só é imposto pelo kernel Linux: só roda se a sonda PROVAR que ele impõe o limite, senão pula com AMBIENTE (o caso do motor, no hq-mutate.selftest.sh, tem a mesma regra).
SKIP_DATA=1; [ "$(python3 -I -c 'import resource
d = 128 << 20
resource.setrlimit(resource.RLIMIT_DATA, (d, d))
try:
    bytearray(300 << 20)
except MemoryError:
    print("imposto")' 2> /dev/null)" = imposto ] && SKIP_DATA=0
mkhog() { mkdir -p "$TREE/lib" "$TREE/tests"; printf 'def inc(a):\n    return a + 1\n' > "$TREE/lib/hog.py"
  printf 'import hog\ntry:\n    bytearray(300 << 20)\n    r = "alloc=ok"\nexcept MemoryError:\n    r = "alloc=falhou"\nopen("%s/ev", "w").write(r)\nassert hog.inc(1) == 2\n' "$F" > "$TREE/tests/test_hog.py"; }
fp_data() { newfx; mkhog; sw --data-mb "$1"; echo "rc=$RC $(jf 'd["result"]') $(cat "$F/ev" 2> /dev/null)"; }
fp_data128() { fp_data 128; }
[ "$SKIP_DATA" = 1 ] || peq "--data-mb 128 chega ao pytest do wrapper: a alocação de 300 MB do teste falha (MemoryError) e a varredura é completa" "rc=0 completo alloc=falhou" fp_data 128
peq "controle do mesmo caminho sem o teto (--data-mb 0): a alocação passa" "rc=0 completo alloc=ok" fp_data 0

# ── regra de morte por CONJUNTO DE FALHAS (ga-z137atn) ─────────────────────────────────────────────
# Sem a regra a baseline tem de dar 0: a família com UM teste quebrado por ambiente na jaula (PermissionError, duckdb, caminho de /Users…) vira base-vermelha e todos os mutantes dela ficam sem julgar (19,3 mil no WA em 06/11). Com --max-bad N a baseline roda a
# família INTEIRA, sem -x e com --continue-on-collection-errors, e um plugin do pytest (PLUGIN, escrito no slot) anota quem quebra; de 1 a N quebrados e até 5% dos testes que rodaram o alvo ENTRA e cada mutante roda SEM eles (exclusão pelo id exato): morre só quem
# faz falhar um teste que PASSAVA. O python falso faz o papel do plugin quando o caso manda (ctl.json); o plugin de verdade tem os casos dele com objetos de mentira (fp_plug) e, havendo pytest, de ponta a ponta (fp_e2e).
fp_ng() {  # 2 testes quebrados na baseline de calc: o alvo ENTRA; o mutante roda com -x, o plugin e os ids EXATOS em WAM_SKIP; os outros alvos seguem a linha de sempre
  newfx; mkwa
  printf '%s' '{"match":"tests/test_calc.py","rc":1,"out":{"tests":["tests/test_users.py::test_env_a","tests/test_users.py::test_env_b"],"mods":[],"passed":100}}' > "$F/ctl.json"
  sw --max-bad 25
  echo "$(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') excl=$(stx) | $(shapes) | skip=$(awk -F'\t' '$9 != "" {print $9}' "$F/py.log" | LC_ALL=C sort -u)"
}
EXP_NG='rc=0 completo run=12 k=9 c=3 f=0 inv=0 open=3 near=1 ctlf=0 excl=calc.py=2,mod.py=-,runner.py=- | 1 base[plug,cont,fails,pp] tests/test_calc.py tests/test_calc_edge.py tests/test_users.py|1 base[plug,cont,fails,pp] tests/test_pkgs.py|1 base[plug,cont,fails,pp] tests/test_runner.py|4 mut[] tests/test_pkgs.py|2 mut[] tests/test_runner.py|10 mut[plug,skip,pp] tests/test_calc.py tests/test_calc_edge.py tests/test_users.py | skip=["tests/test_users.py::test_env_a", "tests/test_users.py::test_env_b"]'
peq "regra ligada, calc com 2 testes quebrados: o alvo entra (near_green=1, excl=2 no estado); baseline sem -x e com o plugin; as 10 chamadas de calc depois da baseline (o CONTROLE + 7 mutantes + 2 reprovas de sobrevivente) levam -x, o plugin e os 2 ids em WAM_SKIP; mod e runner seguem a linha clássica; mesmos 12 veredictos" "$EXP_NG" fp_ng

fp_ngmod() {  # módulo que NÃO COLETA na baseline: sai da família dos mutantes (nada a pular: sem plugin) e os mutantes que só ele mataria sobrevivem
  newfx; mkwa
  printf '%s' '{"match":"tests/test_calc.py","rc":1,"out":{"tests":[],"mods":["tests/test_users.py"],"passed":100}}' > "$F/ctl.json"
  sw --max-bad 25
  echo "$(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') excl=$(stx) | $(shapes)"
}
EXP_NGMOD='rc=0 completo run=12 k=8 c=4 f=0 inv=0 open=4 near=1 ctlf=0 excl=calc.py=1,mod.py=-,runner.py=- | 1 base[plug,cont,fails,pp] tests/test_calc.py tests/test_calc_edge.py tests/test_users.py|1 base[plug,cont,fails,pp] tests/test_pkgs.py|1 base[plug,cont,fails,pp] tests/test_runner.py|11 mut[] tests/test_calc.py tests/test_calc_edge.py|4 mut[] tests/test_pkgs.py|2 mut[] tests/test_runner.py'
peq "regra ligada, calc com test_users.py que não coleta: a família de calc perde o arquivo (11 chamadas, o controle incluído, sem plugin nem WAM_SKIP) e o mutante que só ele matava (>= por <) sobrevive: k=8 c=4, um sobrevivente a mais que os 3 de sempre" "$EXP_NGMOD" fp_ngmod

fp_ongreen() {  # regra ligada e tudo verde: só a baseline muda (plugin, sem -x); os mutantes seguem a linha clássica, os mesmos 12 veredictos
  newfx; mkwa; sw --max-bad 25
  echo "$(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') excl=$(stx) | $(shapes)"
}
EXP_ONGREEN='rc=0 completo run=12 k=9 c=3 f=0 inv=0 open=3 near=0 ctlf=0 excl=calc.py=-,mod.py=-,runner.py=- | 1 base[plug,cont,fails,pp] tests/test_calc.py tests/test_calc_edge.py tests/test_users.py|1 base[plug,cont,fails,pp] tests/test_pkgs.py|1 base[plug,cont,fails,pp] tests/test_runner.py|9 mut[] tests/test_calc.py tests/test_calc_edge.py tests/test_users.py|4 mut[] tests/test_pkgs.py|2 mut[] tests/test_runner.py'
peq "regra ligada, família verde: a baseline leva o plugin e roda sem -x, mas nenhum mutante leva plugin, PYTHONPATH ou WAM_SKIP (o estoque que já era alcançável roda como sempre) e o resumo diz near_green=0" "$EXP_ONGREEN" fp_ongreen

fp_off() {  # --max-bad 0 = regra desligada: nenhuma chamada leva plugin, PYTHONPATH nem WAM_*, o -x fica, e o resumo não tem near_green
  newfx; mkwa; sw --max-bad 0
  echo "$(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') | $(shapes)"
}
EXP_OFF='rc=0 completo run=12 k=9 c=3 f=0 inv=0 open=3 near=None ctlf=None | 10 mut[] tests/test_calc.py tests/test_calc_edge.py tests/test_users.py|5 mut[] tests/test_pkgs.py|3 mut[] tests/test_runner.py'
peq "--max-bad 0: a linha clássica em TODAS as 18 chamadas (baseline com -x, sem plugin, PYTHONPATH ou WAM_*) e o resumo sem near_green" "$EXP_OFF" fp_off

fp_ngred() {  # o que NÃO entra continua base-vermelha (o estado inerte): o plugin não gravou nada (pytest morto pelo prazo), gravou lixo, ou a baseline saiu com rc 2 (interrompida)
  local o="" v
  for v in '{"match":"tests/test_calc.py","rc":1}' \
           '{"match":"tests/test_calc.py","rc":1,"out":"{nao e json"}' \
           '{"match":"tests/test_calc.py","rc":2,"out":{"tests":["tests/test_users.py::test_a"],"mods":[],"passed":100}}'; do
    newfx; mkwa; printf '%s' "$v" > "$F/ctl.json"; sw --max-bad 25
    o="$o | $(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') skipped=$(skp) excl=$(stx) rule=$(stx rule)"
  done
  echo "${o# | }"
}
EXP_NGRED1='rc=0 completo run=5 k=4 c=1 f=0 inv=0 open=1 near=0 ctlf=0 skipped=base-vermelha=1 excl=calc.py=-,mod.py=-,runner.py=- rule=calc.py=1,mod.py=-,runner.py=-'
EXP_NGRED="$EXP_NGRED1 | $EXP_NGRED1 | $EXP_NGRED1"
peq "sem arquivo do plugin, com lixo no lugar dele, ou com rc 2: o alvo fica base-vermelha (nunca verde por falta de leitura), só mod e runner rodam mutantes, sem excl, e o estado marca rule=1 na vermelha (foi julgada pela regra)" "$EXP_NGRED" fp_ngred

fp_ngsticky() {  # o `excl` do alvo NÃO some quando a baseline seguinte (mesmo hash, o ambiente melhorou) dá verde: os sobreviventes já julgados foram julgados sem aqueles testes
  newfx; mkwa; local a
  printf '%s' '{"match":"tests/test_calc.py","rc":1,"out":{"tests":["tests/test_users.py::test_env_a","tests/test_users.py::test_env_b"],"mods":[],"passed":100}}' > "$F/ctl.json"
  sw --max-bad 25 --cap 3; a="$(jf 'd["result"]') run=$(jf 'd["mutants_run"]') excl=$(stx)"
  rm -f "$F/ctl.json"; sw --max-bad 25
  echo "$a | $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') excl=$(stx)"
}
EXP_STICKY="completo run=8 excl=calc.py=2,mod.py=-,runner.py=- | completo run=4 near=0 ctlf=0 excl=calc.py=2,mod.py=-,runner.py=-"
peq "excl gravado numa varredura (--cap 3: 8 mutantes) sobrevive à seguinte, em que a baseline de calc deu verde e os outros 4 mutantes rodaram" "$EXP_STICKY" fp_ngsticky

fp_stale() {  # base-vermelha SEM rule (gravada pelo motor antigo ou com a regra desligada) foi julgada por «qualquer teste quebrado»: com a regra ligada ela vence na hora e o alvo volta; a com rule=1 (julgada pela regra), a de outro motivo e a regra desligada seguem o retry_after
  newfx; mkwa; local h o="" v sv
  h=$(hm plan --tree "$TREE" --state "$F/st.json" | awk -F'\t' '$2 == "lib/calc.py" {print $6}')
  for v in "base-vermelha - 25" "base-vermelha 1 25" "base-vermelha - 0" "base-ambiente - 25" "base-vermelha 0 25"; do   # skip · rule (- = a chave não existe) · --max-bad
    set -- $v
    sv=",\"rule\":$2"; [ "$2" != - ] || sv=""
    printf '{"v":1,"targets":{"lib/calc.py":{"hash":"%s","skip":"%s","retry_after":99999999999%s}}}' "$h" "$1" "$sv" > "$F/st.json"
    o="$o $(hm plan --tree "$TREE" --state "$F/st.json" --max-bad "$3" | awk -F'\t' '$2 == "lib/calc.py" {print $1}')"
  done
  echo "$o"
}
EXP_STALE=" todo base-vermelha base-vermelha base-ambiente todo"
peq "plan: base-vermelha sem rule (ou rule 0), com --max-bad 25 = todo; a com rule=1, a de --max-bad 0 e a base-ambiente sem rule seguem o retry_after" "$EXP_STALE" fp_stale

fp_hashpin() {  # o hash do alvo é o de sempre: a regra NÃO mexe no SCAN_REV nem no que entra nele (mudar reavaliaria os ~660 alvos já cobertos, 55 mil mutantes)
  newfx; mkwa; hm plan --tree "$TREE" --state "$F/st.json" | awk -F'\t' '$2 == "lib/calc.py" {print $6}'
}
EXP_HASHPIN="79ceeb2f14490d71a4d449f73a69de65e379e9bf"
peq "hash do alvo lib/calc.py da árvore de brinquedo é o de antes da regra (SCAN_REV intacto; medido no wrapper sem a regra)" "$EXP_HASHPIN" fp_hashpin

fp_usomb() {  # --max-bad: inteiro >= 0; negativo e texto = rc 2 (no plan e no sweep) e nada vai à jaula
  newfx; mkwa; local o="" a="--tree $TREE --state $F/st.json"
  hm plan $a --max-bad 5 > /dev/null 2>&1;                                                                         o="$o $?"
  hm plan $a --max-bad 0 > /dev/null 2>&1;                                                                         o="$o $?"
  hm plan $a --max-bad -1 > /dev/null 2>&1;                                                                        o="$o $?"
  hm plan $a --max-bad abc > /dev/null 2>&1;                                                                       o="$o $?"
  hm sweep $a --work "$F/work" --jail "$W/fakejail.py" --python "$F/fakepy" --max-bad -3 > /dev/null 2>&1;         o="$o $?"
  echo "$o jail=$(runs)"
}
EXP_USOMB=" 0 0 2 2 2 jail=0"
peq "uso: --max-bad 5 e 0 = 0; -1, abc e (no sweep) -3 = 2, sem nada na jaula" "$EXP_USOMB" fp_usomb

fp_near() {  # a regra de aceitação no nível da função: 1..MAX_BAD quebrados e até 5% dos que rodaram (20*ruins <= bons+ruins); módulo fora da família; e as leituras que falham valem None (vermelha)
  newfx
  python3 -I -B - "${ENG:-$HM}" "$F" << 'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("w", sys.argv[1])
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
d = sys.argv[2]
FAM = ["tests/a.py", "tests/b.py"]


def ids(n):
    return ["tests/a.py::t%d" % i for i in range(n)]


def run(label, payload, mx=25):
    p = os.path.join(d, "n-" + label)
    if payload is not None:
        open(p, "w").write(payload if isinstance(payload, str) else json.dumps(payload))
    w.MAX_BAD = mx
    r = w.near_green({"family": FAM}, p)
    return "%s=%s" % (label, "-" if r is None else "%d+%d" % (len(r["tests"]), len(r["mods"])))


print(" ".join([
    run("um-19", {"tests": ids(1), "mods": [], "passed": 19}),
    run("um-18", {"tests": ids(1), "mods": [], "passed": 18}),
    run("v25", {"tests": ids(25), "mods": [], "passed": 475}),
    run("v25-474", {"tests": ids(25), "mods": [], "passed": 474}),
    run("v26", {"tests": ids(26), "mods": [], "passed": 5000}),
    run("mods", {"tests": ids(1), "mods": ["tests/b.py"], "passed": 100}),
    run("mod-fora", {"tests": [], "mods": ["conftest.py"], "passed": 100}),
    run("zero", {"tests": [], "mods": [], "passed": 100}),
    run("max2-ok", {"tests": ids(2), "mods": [], "passed": 100}, mx=2),
    run("max2-3", {"tests": ids(3), "mods": [], "passed": 100}, mx=2),
    run("max0", {"tests": ids(1), "mods": [], "passed": 100}, mx=0),
    run("ausente", None),
    run("lixo", "{nao"),
    run("vazio", ""),
    run("lista", "[]"),
    run("sem-passed", {"tests": ids(1), "mods": []}),
    run("passed-texto", {"tests": ids(1), "mods": [], "passed": "100"}),
    run("teste-nao-str", {"tests": [1], "mods": [], "passed": 100}),
    run("mods-texto", {"tests": [], "mods": "tests/b.py", "passed": 100}),
]))
PY
}
EXP_NEAR="um-19=1+0 um-18=- v25=25+0 v25-474=- v26=- mods=1+1 mod-fora=- zero=- max2-ok=2+0 max2-3=- max0=- ausente=- lixo=- vazio=- lista=- sem-passed=- passed-texto=- teste-nao-str=- mods-texto=-"
peq "near_green: fronteiras (19 passando + 1 quebrado = 5% entra, 18 não; 25 quebrados entra com 475, não com 474; 26 não), módulo fora da família, --max-bad (2 entra, 3 não, 0 desliga) e arquivo ausente/lixo/vazio/de outra forma = None" \
  "$EXP_NEAR" fp_near

fp_plug() {  # o plugin do pytest (PLUGIN do wrapper) SEM pytest: ganchos com objetos de mentira, chamados como o pluggy chama (só os argumentos que o gancho declara)
  newfx
  python3 -I -B -c 'import importlib.util, sys; s = importlib.util.spec_from_file_location("w", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.stdout.write(m.PLUGIN)' "${ENG:-$HM}" > "$F/wam_plug.py" 2> /dev/null || { echo "sem PLUGIN"; return 0; }
  python3 -I -B - "$F/wam_plug.py" "$F" << 'PY'
import importlib.util, inspect, json, os, sys
src, d = sys.argv[1:3]
os.chdir(d)   # escrita perdida do plugin cairia aqui e apareceria na listagem


class Rep:
    def __init__(self, nodeid, when, outcome):
        self.nodeid, self.when = nodeid, when
        self.passed, self.failed, self.skipped = outcome == "passed", outcome == "failed", outcome == "skipped"


class Item:
    def __init__(self, nodeid):
        self.nodeid = nodeid


class Hook:
    gone = None

    def pytest_deselected(self, items):
        self.gone = [i.nodeid for i in items]


class Cfg:
    def __init__(self):
        self.hook = Hook()


def load(env):
    for k in ("WAM_FAILS", "WAM_SKIP"):
        os.environ.pop(k, None)
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("wam_plug", src)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def call(m, name, **kw):   # como o pluggy: só os argumentos que o gancho declara
    fn = getattr(m, name)
    return fn(**{k: v for k, v in kw.items() if k in inspect.signature(fn).parameters})


def modify(env, ids):
    m, cfg = load(env), Cfg()
    items = [Item(i) for i in ids]
    call(m, "pytest_collection_modifyitems", config=cfg, items=items, session=None)
    return "kept:%s|gone:%s" % (",".join(i.nodeid for i in items), ",".join(cfg.hook.gone) if cfg.hook.gone is not None else "None")


out = []
p = os.path.join(d, "fails.json")
m = load({"WAM_FAILS": p})
for r in (Rep("t::a", "setup", "passed"), Rep("t::a", "call", "passed"), Rep("t::b", "call", "passed"), Rep("t::f", "call", "failed"), Rep("t::f", "teardown", "failed"),
          Rep("t::s", "setup", "failed"), Rep("t::k", "call", "skipped"), Rep("t::z", "teardown", "passed")):
    call(m, "pytest_runtest_logreport", report=r)
for r in (Rep("tests/m1.py", "collect", "failed"), Rep("tests/m1.py", "collect", "failed"), Rep("tests/m2.py", "collect", "passed")):
    call(m, "pytest_collectreport", report=r)
call(m, "pytest_sessionfinish", session=None, exitstatus=1)
out.append("log=" + json.dumps(json.load(open(p)), sort_keys=True))
antes = sorted(os.listdir(d))
call(load({}), "pytest_sessionfinish", session=None, exitstatus=0)
out.append("semvar=%s" % ("nada" if sorted(os.listdir(d)) == antes else "escreveu"))
call(load({"WAM_FAILS": os.path.join(d, "nao", "existe.json")}), "pytest_sessionfinish", session=None, exitstatus=1)
out.append("semdir=ok")
ids = ["t::f", "t::f_more", "t::g[x y]", "t::g[x]"]
out.append("skip=" + modify({"WAM_SKIP": json.dumps(["t::f", "t::g[x y]"])}, ids))
out.append("nada=" + modify({}, ids))
out.append("vazio=" + modify({"WAM_SKIP": "[]"}, ids))
print(" ; ".join(out))
PY
}
EXP_PLUG='log={"mods": ["tests/m1.py"], "passed": 2, "tests": ["t::f", "t::s"]} ; semvar=nada ; semdir=ok ; skip=kept:t::f_more,t::g[x]|gone:t::f,t::g[x y] ; nada=kept:t::f,t::f_more,t::g[x y],t::g[x]|gone:None ; vazio=kept:t::f,t::f_more,t::g[x y],t::g[x]|gone:None'
peq "plugin: só o call que passou conta como passado; falha de qualquer fase entra uma vez (teardown repetido, setup); módulo que não coleta; sem WAM_FAILS ou com pasta que não existe não escreve nem estoura; WAM_SKIP tira o id EXATO (t::f_more fica) e avisa o pytest_deselected; sem WAM_SKIP ou com [] nada muda" \
  "$EXP_PLUG" fp_plug

fp_hook() {  # wa_save_state: grava o excl no alvo CUJO hash foi o julgado; entrada de outro hash, ou ausente (a baseline não chegou a ser processada), fica sem; o excl de antes não se apaga; e o estado é salvo
  newfx
  python3 -I -B - "${ENG:-$HM}" << 'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("w", sys.argv[1])
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
saved = []
w._save_state = lambda p, s: saved.append(p)
w.EXCL.update({"lib/a.py": ("H1", 3), "lib/b.py": ("H2", 4), "lib/c.py": ("H3", 5)})
w.RED.update({"lib/e.py": "H5", "lib/f.py": "H6", "lib/g.py": "H7"})
state = {"targets": {"lib/a.py": {"hash": "H1"}, "lib/b.py": {"hash": "OUTRO"}, "lib/d.py": {"hash": "H4", "excl": 9}, "lib/e.py": {"hash": "H5"}, "lib/f.py": {"hash": "OUTRO"}}}
w.wa_save_state("ARQ", state)
t = state["targets"]
print("saved=%s a=%s b=%s c=%s d=%s e=%s f=%s g=%s" % (saved, t["lib/a.py"].get("excl", "-"), t["lib/b.py"].get("excl", "-"), "lib/c.py" in t, t["lib/d.py"].get("excl", "-"), t["lib/e.py"].get("rule", "-"), t["lib/f.py"].get("rule", "-"), "lib/g.py" in t))
PY
}
EXP_HOOK="saved=['ARQ'] a=3 b=- c=False d=9 e=1 f=- g=False"
peq "wa_save_state: o excl vai para o alvo do mesmo hash (a=3), não para o de hash diferente (b) nem cria entrada que não existe (c), o excl de antes fica (d=9), a baseline vermelha ganha rule=1 só no alvo do mesmo hash (e=1, f=-, g sem entrada) e o estado é salvo uma vez" "$EXP_HOOK" fp_hook

# PONTA A PONTA com o pytest de verdade (venv do WA do nó; HQMW_PYTEST_PY muda): sem um python com pytest e pytest-timeout o caso não roda (AMBIENTE, exit 97, como o do teto de dados).
# calc2 tem 40 casos que passam, 1 quebrado "por ambiente" (test_env_broken), um IRMÃO que passa e leva o nome dele como prefixo (test_env_broken_more: o único que mata o mutante 1->0 de inc) e um módulo que não coleta (test_calc2_extra):
# com a exclusão pelo id EXATO o mutante 1->0 morre; com --deselect (prefixo) o irmão sumiria e ele sobreviveria; o 3º mutante (< por <=) sobrevive de qualquer jeito, e se o quebrado ou o módulo não saíssem todos os mutantes "morreriam"
PYTEST_PY="${HQMW_PYTEST_PY:-$HOME/gt-remote/venv-wa/bin/python}"
SKIP_PYTEST=1; "$PYTEST_PY" -c 'import pytest, pytest_timeout' > /dev/null 2>&1 && SKIP_PYTEST=0
mkpt() {
  mkdir -p "$TREE/lib" "$TREE/tests"
  printf '[pytest]\npythonpath = lib\n' > "$TREE/pytest.ini"
  printf 'def inc(a):\n    return a + 1\n\n\ndef lt(a, b):\n    return a < b\n' > "$TREE/lib/calc2.py"
  printf 'import pytest\nimport calc2\n\n\n@pytest.mark.parametrize("n", range(40))\ndef test_many(n):\n    assert calc2.lt(n, n + 5) is True\n\n\ndef test_env_broken():\n    assert False\n\n\ndef test_env_broken_more():\n    assert calc2.inc(1) == 2\n' > "$TREE/tests/test_calc2.py"
  printf 'import modulo_que_nao_existe\n' > "$TREE/tests/test_calc2_extra.py"
}
fp_e2e() { newfx; mkpt; PYBIN="$PYTEST_PY" sw --max-bad 25; echo "$(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') excl=$(stx)"; }
EXP_E2E="rc=0 completo run=3 k=2 c=1 f=0 inv=0 open=1 near=1 ctlf=0 excl=calc2.py=2"
mkdep() {   # test_a_env_broken roda primeiro, deixa um rastro no TMPDIR do slot e quebra; os 40 test_b só passam com o rastro. Baseline: 40 passaram, 1 quebrou (entraria). Sem o teste quebrado (controle): os 40 quebram
  mkdir -p "$TREE/lib" "$TREE/tests"
  printf '[pytest]\npythonpath = lib\n' > "$TREE/pytest.ini"
  printf 'def inc(a):\n    return a + 1\n' > "$TREE/lib/dep.py"
  printf 'import os\nimport pytest\nimport dep\n\nMARK = os.path.join(os.environ["TMPDIR"], "rastro")\n\n\ndef test_a_env_broken():\n    open(MARK, "w").write("x")\n    assert False\n\n\n@pytest.mark.parametrize("n", range(40))\ndef test_b_needs_trace(n):\n    assert os.path.exists(MARK)\n    assert dep.inc(n) == n + 1\n' > "$TREE/tests/test_dep.py"
}
fp_e2edep() { newfx; mkdep; PYBIN="$PYTEST_PY" sw --max-bad 25; echo "$(cnt) near=$(jf 'd.get("near_green")') ctlf=$(jf 'd.get("controle_falhou")') skipped=$(skp) excl=$(stx)"; }
EXP_E2EDEP="rc=0 sem-cobertura run=0 k=0 c=0 f=0 inv=0 open=0 near=0 ctlf=1 skipped=base-vermelha=1 excl=dep.py=-"
[ "$SKIP_PYTEST" = 1 ] || peq "pytest real, controle: o teste quebrado deixa um rastro de que os 40 que passavam dependem; sem ele eles quebram, então o alvo NÃO entra (base-vermelha, 0 mutantes, sem excl) em vez de matar todos os mutantes por falso positivo" "$EXP_E2EDEP" fp_e2edep
[ "$SKIP_PYTEST" = 1 ] || peq "ponta a ponta com pytest real: o quebrado e o módulo que não coleta saem, o irmão test_env_broken_more PASSA a rodar e mata 1->0, só < por <= sobrevive (k=2 c=1), excl=2" "$EXP_E2E" fp_e2e

# ── mutantes do wrapper ────────────────────────────────────────────────────────────────────────────
# mut NOME ANTIGO NOVO: copia o wrapper para uma pasta PRÓPRIA com o hq-mutate.py ao lado (ele o carrega de lá) e troca ANTIGO por NOVO (tem de casar exatamente 1 vez); o caminho fica em $MP
mut() {
  mkdir -p "$W/eng-$1" && cp "$HERE/hq-mutate.py" "$W/eng-$1/hq-mutate.py"; MP="$W/eng-$1/hq-mutate-wa.py"
  python3 -I -B - "$HM" "$MP" "$2" "$3" << 'PY' || { bad "mutante $1: INVÁLIDO (âncora não casa exatamente 1 vez)"; return 1; }
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
n = t.count(old)
if n != 1:
    print("âncora casa %d vezes: %r" % (n, old[:70]), file=sys.stderr); sys.exit(1)
open(dst, "w", encoding="utf-8").write(t.replace(old, new))
PY
}
# kill_it NOME FUNÇÃO ESPERADO ANTIGO NOVO: o wrapper mutante tem de dar uma impressão diferente da esperada
kill_it() { mut "$1" "$4" "$5" && ne "mutante $1 ($2)" "$3" "$(ENG="$MP" "$2" 2> /dev/null)"; }
# família
par kill_it fam-so-nomes        fp_sweep "$EXP_SWEEP" '    return sorted(named.get(stem, set()) | imp.get(stem, set()))' '    return sorted(named.get(stem, set()))'
par kill_it fam-so-importadores fp_sweep "$EXP_SWEEP" '    return sorted(named.get(stem, set()) | imp.get(stem, set()))' '    return sorted(imp.get(stem, set()))'
par kill_it fam-prefixo-solto   fp_sweep "$EXP_SWEEP" 'for i in [i for i, c in enumerate(body) if not c.isalnum()] + [len(body)]:' 'for i in range(1, len(body) + 1):'
par kill_it fam-from-calado     fp_sweep "$EXP_SWEEP" 'names = set(m.group(1).split(".")) | set(re.findall(r"\w+", m.group(2)))' 'names = set(m.group(1).split("."))'
par kill_it fam-import-calado   fp_sweep "$EXP_SWEEP" 'names = {w for part in m.group(3).split(",") for w in re.findall(r"\w+", part.split(" as ")[0])}' 'names = set()'
par kill_it fam-so-1            fp_sweep "$EXP_SWEEP" '    fam = [f for f in tgt["family"] if f not in' '    fam = [f for f in tgt["family"][:1] if f not in'
# como o pytest é chamado
par kill_it sem-randomly        fp_sweep "$EXP_SWEEP" '"-p", "no:cacheprovider", "-p", "no:randomly"]' '"-p", "no:cacheprovider"]'
par kill_it sem-x               fp_sweep "$EXP_SWEEP" '([] if base else ["-x"])' '([] if base else [])'
par kill_it sem-timeout         fp_sweep "$EXP_SWEEP" '"--no-header", "--timeout=%d" % PYTEST_TMO]' '"--no-header"]'
par kill_it timeout-fixo        fp_tmo   "rc=0 completo run=12 k=9 c=3 f=0 inv=0 open=3 flags=-m pytest -p no:cacheprovider -p no:randomly -q -x --tb=no --no-header --timeout=7" '"--timeout=%d" % PYTEST_TMO' '"--timeout=120"'
par kill_it jaula-nao-usada     fp_sweep "$EXP_SWEEP" 'cmd = [sys.executable, "-I", ctx.a.jail, "--rw", str(slot), "--", "env", "-i", *kv,' 'cmd = ["env", "-i", *kv,'
par kill_it env-herdado         fp_sweep "$EXP_SWEEP" '"--", "env", "-i", *kv, "timeout"' '"--", "env", *kv, "timeout"'
par kill_it home-real           fp_sweep "$EXP_SWEEP" '["HOME=%s" % (slot / "home"), ' '['
par kill_it tmpdir-real         fp_sweep "$EXP_SWEEP" '"TMPDIR=%s" % (slot / "tmp"), ' ''
par kill_it sem-hashseed        fp_sweep "$EXP_SWEEP" '"PYTHONDONTWRITEBYTECODE=1", "PYTHONHASHSEED=0",' '"PYTHONDONTWRITEBYTECODE=1",'
par kill_it grava-na-origem     fp_sweep "$EXP_SWEEP" '(clone / tgt["rel"]).write_text(text, encoding="utf-8")' '(ctx.tree / tgt["rel"]).write_text(text, encoding="utf-8")'
par kill_it baseline-com-texto  fp_sweep "$EXP_SWEEP" '    if text is not None:' '    if True:'
par kill_it copia-sem-crew      fp_sweep "$EXP_SWEEP" '"*.pyc", "crew", "node_modules"' '"*.pyc", "node_modules"'
par kill_it copia-sem-node      fp_sweep "$EXP_SWEEP" '"crew", "node_modules", "*.bak-*")' '"crew", "*.bak-*")'
par kill_it copia-sem-bak       fp_sweep "$EXP_SWEEP" '"node_modules", "*.bak-*")' '"node_modules")'
par kill_it copia-sem-pycache   fp_sweep "$EXP_SWEEP" 'COPY_IGNORE = (".git", "__pycache__", "*.pyc"' 'COPY_IGNORE = (".git", "*.pyc"'
par kill_it copia-sem-git       fp_sweep "$EXP_SWEEP" 'COPY_IGNORE = (".git", "__pycache__"' 'COPY_IGNORE = ("__pycache__"'
# o que é candidato
par kill_it ruido-off           fp_gen   "8|swap|==|!= 8|num|3|4" 'if not (0 < c["line"] <= len(lines) and NOISE.match(lines[c["line"] - 1]))' 'if True'
par kill_it ruido-sem-log       fp_gen   "8|swap|==|!= 8|num|3|4" '|log\.\w+|' '|'
par kill_it ruido-sem-print     fp_gen   "8|swap|==|!= 8|num|3|4" '(?:print|logger' '(?:logger'
par kill_it sem-patch-cand      fp_gen   "8|swap|==|!= 8|num|3|4" 'hqm.make_plan, hqm.exec_family, hqm.candidates = wa_make_plan, wa_exec_family, wa_candidates' 'hqm.make_plan, hqm.exec_family = wa_make_plan, wa_exec_family'
# plano
par kill_it sem-patch-plano     fp_plan  "$EXP_PLAN" 'hqm.make_plan, hqm.exec_family, hqm.candidates = wa_make_plan, wa_exec_family, wa_candidates' 'hqm.exec_family, hqm.candidates = wa_exec_family, wa_candidates'
par kill_it denylist-off        fp_plan  "$EXP_PLAN" '        elif deny:' '        elif False:'
par kill_it denylist-wa-off     fp_plan  "$EXP_PLAN" 'deny = hqm.DENY_RX.search(text) or WA_DENY.search(text)' 'deny = hqm.DENY_RX.search(text)'
par kill_it denylist-hq-off     fp_plan  "$EXP_PLAN" 'deny = hqm.DENY_RX.search(text) or WA_DENY.search(text)' 'deny = WA_DENY.search(text)'
par kill_it denylist-so-sujeito fp_plan  "$EXP_PLAN" 'text = "" if big or not fam else b"\n".join(blobs).decode("utf-8", "replace")' 'text = blobs[0].decode("utf-8", "replace")'
par kill_it psutil-fora         fp_plan  "$EXP_PLAN" '|\bpsutil\b")' '")'
par kill_it killpg-fora         fp_plan  "$EXP_PLAN" 'os\.kill(?:pg)?\b' 'os\.kill\b'
par kill_it grande-off          fp_plan  "$EXP_PLAN" '        elif big:' '        elif False:'
par kill_it grande-no-limite    fp_plan  "$EXP_PLAN" 'big = len(fam) > FAM_CAP' 'big = len(fam) >= FAM_CAP'
par kill_it cap-do-flag-ignorado fp_plan "$EXP_PLAN" 'FAM_CAP, PYTEST_TMO, PYTHON, MAX_BAD = mine.fam_cap, mine.pytest_timeout' 'FAM_CAP, PYTEST_TMO, PYTHON, MAX_BAD = FAM_CAP, mine.pytest_timeout'
par kill_it sem-teste-off       fp_plan  "$EXP_PLAN" '        elif not fam:' '        elif False:'
par kill_it symlink-off         fp_plan  "$EXP_PLAN" '        if subj.resolve() != subj:' '        if False:'
par kill_it recente-sem-familia fp_plan  "$EXP_PLAN" 'bool(({rel} | set(fam)) & recent)' 'bool({rel} & recent)'
par kill_it recente-sem-sujeito fp_plan  "$EXP_PLAN" 'bool(({rel} | set(fam)) & recent)' 'bool(set(fam) & recent)'
par kill_it ordem-invertida     fp_plan  "$EXP_PLAN" 'plan.sort(key=lambda t: (not t["recent"],' 'plan.sort(key=lambda t: (t["recent"],'
par kill_it retry-ignorado      fp_retry "base-vermelha todo" '        elif old.get("skip") and now < old.get("retry_after", 0) and not stale_red(old):' '        elif old.get("skip") and not stale_red(old):'
par kill_it hash-sem-familia    fp_hash  "$EXP_HASH" '([] if big else [files[f] for f in fam])' '[]'
par kill_it hash-ignorado       fp_again "sem-novidade run=0 novas=0" '        old = old if old.get("hash") == h else {}' '        old = {}'
par kill_it novidade-ignorada   fp_again "sem-novidade run=0 novas=0" '        elif "total" in old and len(old.get("verdicts", {})) >= old["total"]:' '        elif False:'
# árvore e uso
par kill_it arvore-sem-teste    fp_arvore " 3 3 3 3 | rc=3 sem-alvos run=0" '    if not (tree / TEST_DIR).is_dir() or not any((tree / d).is_dir() for d in SUBJECT_DIRS):' '    if False:'
par kill_it sem-alvos-aceito    fp_arvore " 3 3 3 3 | rc=3 sem-alvos run=0" '    if not subjects:' '    if False:'
par kill_it teste-ilegivel-calado fp_arvore " 3 3 3 3 | rc=3 sem-alvos run=0" '            files[rel] = p.read_bytes()' '            files[rel] = p.read_bytes() if p.exists() else b""'
par kill_it python-opcional     fp_uso   " 2 2 0 2 2 jail=0" '    if rest[:1] == ["sweep"] and not (mine.python and os.access(mine.python, os.X_OK)):' '    if False:'
par kill_it python-nao-exec     fp_uso   " 2 2 0 2 2 jail=0" ' and os.access(mine.python, os.X_OK))' ')'
par kill_it cap-zero-aceito     fp_uso   " 2 2 0 2 2 jail=0" 'if mine.fam_cap < 1 or' 'if mine.fam_cap < 0 or'
par kill_it timeout-zero-aceito fp_uso   " 2 2 0 2 2 jail=0" ' or mine.pytest_timeout < 1:' ' or mine.pytest_timeout < 0:'
par kill_it baseline-ignorada   fp_red   "rc=0 sem-cobertura run=0 skipped=base-vermelha=1 jail=1" '    return rc, secs' '    return 0, secs'
[ "$SKIP_DATA" = 1 ] || par kill_it dados-nao-chega  fp_data128 "rc=0 completo alloc=falhou" 'sys.executable, "-I", "-c", hqm.CAPPER, hqm.cap_arg(ctx.a), *pytest]' 'sys.executable, "-I", "-c", hqm.CAPPER, str(ctx.a.fsize_mb << 20), *pytest]'
# regra de morte por conjunto de falhas (ga-z137atn): a opção e a fiação
par kill_it max-bad-padrao-ligado fp_sweep "$EXP_SWEEP" 'MAX_BAD = 0   # --max-bad (ga-z137atn)' 'MAX_BAD = 25   # --max-bad (ga-z137atn)'
par kill_it max-bad-flag-ignorado fp_ng   "$EXP_NG" 'mine.python or "", mine.max_bad' 'mine.python or "", MAX_BAD'
par kill_it max-bad-neg-aceito    fp_usomb "$EXP_USOMB" '    if mine.max_bad < 0:' '    if False:'
par kill_it max-bad-zero-recusado fp_usomb "$EXP_USOMB" '    if mine.max_bad < 0:' '    if mine.max_bad < 1:'
par kill_it sem-patch-estado      fp_ng   "$EXP_NG" '    hqm.save_state, hqm.summary = wa_save_state, wa_summary' '    hqm.summary = wa_summary'
par kill_it sem-patch-resumo      fp_ng   "$EXP_NG" '    hqm.save_state, hqm.summary = wa_save_state, wa_summary' '    hqm.save_state = wa_save_state'
par kill_it scan-rev-subiu        fp_hashpin "$EXP_HASHPIN" 'SCAN_REV = 1   # entra no hash' 'SCAN_REV = 2   # entra no hash'
# o plano: a base-vermelha de antes da regra vence
par kill_it stale-sempre          fp_stale "$EXP_STALE" '    return MAX_BAD > 0 and old.get("skip") == "base-vermelha" and not old.get("rule")' '    return old.get("skip") == "base-vermelha" and not old.get("rule")'
par kill_it stale-qualquer-skip   fp_stale "$EXP_STALE" 'old.get("skip") == "base-vermelha" and not old.get("rule")' 'bool(old.get("skip")) and not old.get("rule")'
par kill_it stale-rule-ignorado   fp_stale "$EXP_STALE" 'old.get("skip") == "base-vermelha" and not old.get("rule")' 'old.get("skip") == "base-vermelha"'
par kill_it stale-rule-invertido  fp_stale "$EXP_STALE" 'old.get("skip") == "base-vermelha" and not old.get("rule")' 'old.get("skip") == "base-vermelha" and old.get("rule")'
par kill_it stale-nunca           fp_stale "$EXP_STALE" 'now < old.get("retry_after", 0) and not stale_red(old):' 'now < old.get("retry_after", 0):'
# near_green: a aceitação e a leitura
par kill_it ng-sem-lista          fp_near "$EXP_NEAR" 'isinstance(tests, list) and isinstance(mods, list) and ' ''
par kill_it ng-passed-sem-tipo    fp_near "$EXP_NEAR" 'type(passed) is int and ' ''
par kill_it ng-elemento-nao-str   fp_near "$EXP_NEAR" 'all(isinstance(x, str) for x in tests + mods)' 'True'
par kill_it ng-zero-aceito        fp_near "$EXP_NEAR" '0 < bad <= MAX_BAD' '0 <= bad <= MAX_BAD'
par kill_it ng-teto-exclusivo     fp_near "$EXP_NEAR" '0 < bad <= MAX_BAD' '0 < bad < MAX_BAD'
par kill_it ng-teto-mais-um       fp_near "$EXP_NEAR" '0 < bad <= MAX_BAD' '0 < bad <= MAX_BAD + 1'
par kill_it ng-5pct-estrito       fp_near "$EXP_NEAR" 'bad * 20 <= passed + bad' 'bad * 20 < passed + bad'
par kill_it ng-10pct              fp_near "$EXP_NEAR" 'bad * 20 <= passed + bad' 'bad * 10 <= passed + bad'
par kill_it ng-5pct-sem-os-ruins  fp_near "$EXP_NEAR" 'bad * 20 <= passed + bad' 'bad * 20 <= passed'
par kill_it ng-sem-familia        fp_near "$EXP_NEAR" ' and all(m in tgt["family"] for m in mods))' ')'
par kill_it ng-familia-invertida  fp_near "$EXP_NEAR" 'all(m in tgt["family"] for m in mods)' 'all(m not in tgt["family"] for m in mods)'
par kill_it ng-devolve-sem-mods   fp_near "$EXP_NEAR" 'return {"tests": tests, "mods": mods}' 'return {"tests": tests, "mods": []}'
par kill_it ng-sem-oserror        fp_near "$EXP_NEAR" 'except (OSError, ValueError, KeyError, TypeError):' 'except (ValueError, KeyError, TypeError):'
par kill_it ng-sem-valueerror     fp_near "$EXP_NEAR" 'except (OSError, ValueError, KeyError, TypeError):' 'except (OSError, KeyError, TypeError):'
par kill_it ng-sem-keyerror       fp_near "$EXP_NEAR" 'except (OSError, ValueError, KeyError, TypeError):' 'except (OSError, ValueError, TypeError):'
par kill_it ng-sem-typeerror      fp_near "$EXP_NEAR" 'except (OSError, ValueError, KeyError, TypeError):' 'except (OSError, ValueError, KeyError):'
par kill_it ng-passed-inventado   fp_near "$EXP_NEAR" 'tests, mods, passed = d["tests"], d["mods"], d["passed"]' 'tests, mods, passed = d["tests"], d["mods"], 10 ** 9'
# o plugin do pytest
par kill_it plug-conta-setup      fp_plug "$EXP_PLUG" '    elif report.when == "call" and report.passed:' '    elif report.passed:'
par kill_it plug-falha-so-call    fp_plug "$EXP_PLUG" $'    if report.failed:\n        _bad.add(report.nodeid)' $'    if report.failed and report.when == "call":\n        _bad.add(report.nodeid)'
par kill_it plug-sem-modulos      fp_plug "$EXP_PLUG" '        _mods.add(report.nodeid)' '        pass'
par kill_it plug-modulo-passado   fp_plug "$EXP_PLUG" $'    if report.failed:\n        _mods.add(report.nodeid)' $'    if True:\n        _mods.add(report.nodeid)'
par kill_it plug-skip-prefixo     fp_plug "$EXP_PLUG" 'gone = [i for i in items if i.nodeid in _skip]' 'gone = [i for i in items if i.nodeid.startswith(tuple(_skip))]'
par kill_it plug-sem-deselected   fp_plug "$EXP_PLUG" '        config.hook.pytest_deselected(items=gone)' '        pass'
par kill_it plug-nao-remove       fp_plug "$EXP_PLUG" '        items[:] = [i for i in items if i.nodeid not in _skip]' '        pass'
par kill_it plug-sempre-remove    fp_plug "$EXP_PLUG" '    if gone:' '    if True:'
par kill_it plug-sempre-grava     fp_plug "$EXP_PLUG" '    if _f:' '    if True:'
par kill_it plug-sem-oserror      fp_plug "$EXP_PLUG" $'        except OSError:\n            pass   # uma gravação' $'        except ValueError:\n            pass   # uma gravação'
par kill_it plug-passa-dois       fp_plug "$EXP_PLUG" '        _ok[0] += 1' '        _ok[0] += 2'
par kill_it plug-lista-trocada    fp_plug "$EXP_PLUG" '"tests": sorted(_bad), "mods": sorted(_mods)' '"tests": sorted(_mods), "mods": sorted(_bad)'
par kill_it plug-ignora-skip      fp_plug "$EXP_PLUG" '_skip = set(json.loads(_s)) if _s else set()' '_skip = set()'
par kill_it plug-ignora-fails     fp_plug "$EXP_PLUG" '_f, _s = os.environ.get("WAM_FAILS"), os.environ.get("WAM_SKIP")' '_f, _s = None, os.environ.get("WAM_SKIP")'
# o gancho do estado
par kill_it hook-sem-hash         fp_hook "$EXP_HOOK" $'        if ent is not None and ent.get("hash") == h:\n            ent["excl"] = n' $'        if ent is not None:\n            ent["excl"] = n'
par kill_it hook-sem-existe       fp_hook "$EXP_HOOK" $'        if ent is not None and ent.get("hash") == h:\n            ent["excl"] = n' $'        if ent.get("hash") == h:\n            ent["excl"] = n'
par kill_it red-sem-hash          fp_hook "$EXP_HOOK" $'        if ent is not None and ent.get("hash") == h:\n            ent["rule"] = 1' $'        if ent is not None:\n            ent["rule"] = 1'
par kill_it red-sem-existe        fp_hook "$EXP_HOOK" $'        if ent is not None and ent.get("hash") == h:\n            ent["rule"] = 1' $'        if ent.get("hash") == h:\n            ent["rule"] = 1'
par kill_it red-nao-grava         fp_hook "$EXP_HOOK" '            ent["rule"] = 1' '            pass'
par kill_it red-valor-zero        fp_hook "$EXP_HOOK" '            ent["rule"] = 1' '            ent["rule"] = 0'
par kill_it red-todos             fp_ngred "$EXP_NGRED" '    if base and rc != 0:' '    if base:'
par kill_it red-so-rc1            fp_ngred "$EXP_NGRED" '    if base and rc != 0:' '    if base and rc == 1:'
par kill_it red-sem-regra         fp_red  "rc=0 sem-cobertura run=0 skipped=base-vermelha=1 jail=1 rule=red.py=-" '    if base and rc != 0:' '    if rc != 0:'
par kill_it red-hash-errado       fp_ngred "$EXP_NGRED" '        RED[tgt["rel"]] = tgt["hash"]' '        RED[tgt["rel"]] = "x"'
par kill_it hook-n-fixo           fp_hook "$EXP_HOOK" '            ent["excl"] = n' '            ent["excl"] = 1'
par kill_it hook-apaga-excl       fp_hook "$EXP_HOOK" '    for rel, (h, n) in list(EXCL.items()):' $'    for ent0 in state["targets"].values():\n        ent0.pop("excl", None)\n    for rel, (h, n) in list(EXCL.items()):'
par kill_it hook-nao-salva        fp_hook "$EXP_HOOK" '    _save_state(path, state)' '    pass'
par kill_it hook-nao-grava        fp_ng   "$EXP_NG" '            ent["excl"] = n' '            pass'
par kill_it resumo-near-zero      fp_ng   "$EXP_NG" 'kw["near_green"], kw["controle_falhou"] = len(EXCL), len(CTL_FAIL)' 'kw["near_green"], kw["controle_falhou"] = 0, len(CTL_FAIL)'
par kill_it resumo-ctlf-zero      fp_e2edep "$EXP_E2EDEP" 'kw["near_green"], kw["controle_falhou"] = len(EXCL), len(CTL_FAIL)' 'kw["near_green"], kw["controle_falhou"] = len(EXCL), 0'
par kill_it resumo-sempre         fp_off  "$EXP_OFF" $'    if MAX_BAD > 0:\n        kw["near_green"], kw["controle_falhou"] = len(EXCL), len(CTL_FAIL)' $'    if True:\n        kw["near_green"], kw["controle_falhou"] = len(EXCL), len(CTL_FAIL)'
# a execução: baseline, mutante e a linha do pytest
par kill_it base-sempre           fp_off  "$EXP_OFF" '    base = MAX_BAD > 0 and text is None' '    base = text is None'
par kill_it base-tambem-mutante   fp_ongreen "$EXP_ONGREEN" '    base = MAX_BAD > 0 and text is None' '    base = MAX_BAD > 0'
par kill_it plug-sempre           fp_off  "$EXP_OFF" '    plug = base or bool(excl and excl["tests"])' '    plug = True'
par kill_it plug-so-baseline      fp_ng   "$EXP_NG" '    plug = base or bool(excl and excl["tests"])' '    plug = base'
par kill_it plug-so-mutante       fp_ng   "$EXP_NG" '    plug = base or bool(excl and excl["tests"])' '    plug = bool(excl and excl["tests"])'
par kill_it plug-com-modulos      fp_ngmod "$EXP_NGMOD" '    plug = base or bool(excl and excl["tests"])' '    plug = base or bool(excl)'
par kill_it fails-e-skip-trocados fp_ng   "$EXP_NG" 'if base else "WAM_SKIP=' 'if not base else "WAM_SKIP='
par kill_it skip-so-modulos       fp_ng   "$EXP_NG" 'json.dumps(excl["tests"])' 'json.dumps(excl["mods"])'
par kill_it fam-sem-mods          fp_ngmod "$EXP_NGMOD" '    fam = [f for f in tgt["family"] if f not in (excl["mods"] if excl else [])]' '    fam = list(tgt["family"])'
par kill_it fam-so-mods           fp_ongreen "$EXP_ONGREEN" 'if f not in (excl["mods"] if excl else [])]' 'if f in (excl["mods"] if excl else [])]'
par kill_it x-invertido           fp_ng   "$EXP_NG" '([] if base else ["-x"])' '(["-x"] if base else [])'
par kill_it cont-nunca            fp_ng   "$EXP_NG" '(["--continue-on-collection-errors"] if base else [])' '[]'
par kill_it cont-sempre           fp_ongreen "$EXP_ONGREEN" '(["--continue-on-collection-errors"] if base else [])' '(["--continue-on-collection-errors"])'
par kill_it plug-p-nunca          fp_ng   "$EXP_NG" '(["-p", "wam_plug"] if plug else [])' '[]'
par kill_it rc-qualquer           fp_ngred "$EXP_NGRED" '    if base and rc == 1:' '    if base and rc != 0:'
par kill_it excl-nao-guardado     fp_ng   "$EXP_NG" '            tgt["excl"], rc = got, 0' '            rc = 0'
par kill_it aceita-mas-vermelho   fp_ng   "$EXP_NG" '            tgt["excl"], rc = got, 0' '            tgt["excl"], rc = got, 1'
par kill_it excl-conta-so-testes  fp_ngmod "$EXP_NGMOD" 'len(got["tests"]) + len(got["mods"])' 'len(got["tests"])'
par kill_it excl-conta-so-mods    fp_ng   "$EXP_NG" 'len(got["tests"]) + len(got["mods"])' 'len(got["mods"])'
par kill_it out-gravado-noutro    fp_ng   "$EXP_NG" '"WAM_FAILS=%s" % (slot / "plug" / "out.json")' '"WAM_FAILS=%s" % (slot / "plug" / "outro.json")'
par kill_it out-lido-noutro       fp_ng   "$EXP_NG" 'near_green(tgt, slot / "plug" / "out.json")' 'near_green(tgt, slot / "plug" / "outro.json")'
par kill_it sticky-perde          fp_ngsticky "$EXP_STICKY" '    for rel, (h, n) in list(EXCL.items()):' $'    for ent0 in state["targets"].values():\n        ent0.pop("excl", None)\n    for rel, (h, n) in list(EXCL.items()):'
par kill_it controle-ignorado     fp_ng   "$EXP_NG" '            if wa_exec_family(ctx, slot_n, tgt, None, tmo, ctl=got)[0] == 0:' '            if True:'
par kill_it controle-invertido    fp_ng   "$EXP_NG" 'tmo, ctl=got)[0] == 0:' 'tmo, ctl=got)[0] != 0:'
par kill_it controle-sem-exclusao fp_ng   "$EXP_NG" 'tmo, ctl=got)[0] == 0:' 'tmo, ctl={"tests": [], "mods": []})[0] == 0:'
par kill_it controle-so-testes    fp_ngmod "$EXP_NGMOD" 'tmo, ctl=got)[0] == 0:' 'tmo, ctl={"tests": got["tests"], "mods": []})[0] == 0:'
par kill_it ctlf-nao-conta        fp_e2edep "$EXP_E2EDEP" '                CTL_FAIL.add(tgt["rel"])' '                pass'
par kill_it ctlf-conta-tudo       fp_ng   "$EXP_NG" $'                tgt["excl"], rc = got, 0\n' $'                tgt["excl"], rc = got, 0\n                CTL_FAIL.add(tgt["rel"])\n'
par kill_it controle-vira-baseline fp_ng  "$EXP_NG" '    base = MAX_BAD > 0 and text is None and not ctl' '    base = MAX_BAD > 0 and text is None'
par kill_it controle-sem-ctl-excl fp_ng   "$EXP_NG" '    excl = ctl or tgt.get("excl")' '    excl = tgt.get("excl")'
# com pytest de verdade (o python falso não importa o plugin nem lê o ini): o arquivo do plugin, o PYTHONPATH que o acha
[ "$SKIP_PYTEST" = 1 ] || par kill_it plug-arquivo-vazio  fp_e2e "$EXP_E2E" 'write_text(PLUGIN, encoding="utf-8")' 'write_text("", encoding="utf-8")'
[ "$SKIP_PYTEST" = 1 ] || par kill_it plug-pythonpath-errado fp_e2e "$EXP_E2E" '"PYTHONPATH=%s" % (slot / "plug")' '"PYTHONPATH=%s" % slot'
[ "$SKIP_PYTEST" = 1 ] || par kill_it controle-ignorado-e2e fp_e2edep "$EXP_E2EDEP" '            if wa_exec_family(ctx, slot_n, tgt, None, tmo, ctl=got)[0] == 0:' '            if True:'
[ "$SKIP_PYTEST" = 1 ] || par kill_it plug-skip-so-prefixo fp_e2e "$EXP_E2E" '        items[:] = [i for i in items if i.nodeid not in _skip]' '        items[:] = [i for i in items if not i.nodeid.startswith(tuple(_skip))]'
reap
# controle do controle: o `mut` recusa uma âncora ambígua e uma que não casa
FAIL0=$FAIL   # o mut recusa e conta uma falha própria: aqui a recusa é o esperado, então só a aceitação reprova
for a in import texto-que-nao-existe-no-wrapper; do if mut ancora-ruim "$a" y > /dev/null 2>&1; then bad "mut aceitou âncora que não casa exatamente 1 vez: $a"; else FAIL=$FAIL0; ok; fi; done

[ "$SKIP_DATA" = 0 ] || echo "AMBIENTE: este kernel não impõe o RLIMIT_DATA (ou a sonda não rodou): o caso do teto de dados e o seu mutante não rodaram (o nó, Linux, roda)"
[ "$SKIP_PYTEST" = 0 ] || echo "AMBIENTE: sem um python com pytest e pytest-timeout ($PYTEST_PY; HQMW_PYTEST_PY muda): o caso de ponta a ponta e os mutantes dele não rodaram (o venv do WA do nó tem)"
echo "hq-mutate-wa selftest: $PASS passed, $FAIL failed$([ "$SKIP_DATA" = 1 ] && echo ", caso do teto de dados NÃO rodou (AMBIENTE)")$([ "$SKIP_PYTEST" = 1 ] && echo ", caso com pytest real NÃO rodou (AMBIENTE)")"
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP_DATA" -eq 0 ] && [ "$SKIP_PYTEST" -eq 0 ] || exit 97
exit 0
