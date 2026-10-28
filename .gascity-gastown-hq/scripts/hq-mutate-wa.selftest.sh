#!/usr/bin/env bash
# hq-mutate-wa.selftest.sh (ga-tmfmvxi) — a varredura de mutantes do código do WA: acha o teste fraco do lib/ e do daemons/, com a família de testes INTEIRA, sem tocar na árvore de origem e sem rodar nada que a jaula não segure.
#
# ## Contents
#   Hermético · Casos · Mutantes do wrapper
#
# HERMÉTICO: pasta descartável, uma JAULA FALSA (a do hq-mutate.selftest.sh: registra cada execução e deixa passar) e um PYTHON FALSO (`fakepy`: aceita `-m pytest … ARQUIVOS`, roda cada arquivo de teste como script, na ordem, e para no primeiro que reprova, como o `-x`).
#   O python falso registra onde foi chamado, com que HOME/TMPDIR/PYTHONHASHSEED e com que argumentos: é o que prova que o pytest roda no slot, dentro do ambiente limpo e com a família certa. Não precisa de pytest nem do venv do WA: o que se mede aqui é o wrapper (hq-mutate-wa.py), não o pytest.
# O MOTOR (hq-mutate.py: operadores, veredito, estado, teto de escrita, TERM) tem a bateria própria (hq-mutate.selftest.sh); aqui entra só o que o wrapper troca: quem é o alvo e a família, o que se pula, o que vira candidato e como o pytest é chamado.
# CASOS: cada caso é uma IMPRESSÃO DIGITAL (rc, veredito, contagens, argumentos do pytest, onde e com que ambiente ele rodou): vale se for a esperada, e o MUTANTE do wrapper vale se ela mudar (âncora que não casa exatamente 1 vez = INVÁLIDO).
#   A árvore do caso tem 3 alvos com 12 mutantes (calc 7, pkg/mod 3, runner 2) e tests/ pensado para que CADA regra de família seja a única a matar algum mutante: sem os testes pelo NOME (test_calc_edge) dois mutantes sobrevivem, sem os IMPORTADORES (test_users) outros dois,
#   e o test_calcify (começa com `calc` mas sem fronteira, e só importa por importlib) fica FORA e deixa dois sobreviventes que só ele mataria.
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
# Registra (TAB): py · cwd · HOME · PYTHONHASHSEED · argumentos · HQM_SECRET (tem de vir vazio: o `env -i` do motor) · TMPDIR
{ printf '#!%s\n' "$PY3"; cat << 'PY'
import os, subprocess, sys
a = sys.argv[1:]
open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "py.log"), "a").write("\t".join(["py", os.getcwd(), os.environ.get("HOME", ""), os.environ.get("PYTHONHASHSEED", ""), " ".join(a), os.environ.get("HQM_SECRET", ""), os.environ.get("TMPDIR", "")]) + "\n")
if a[:2] != ["-m", "pytest"]:
    sys.exit(5)
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
  echo "rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') skipped=$(skp) jail=$(runs)"
}
peq "baseline vermelha: sem-cobertura, base-vermelha=1, 0 mutantes (só a baseline foi à jaula)" "rc=0 sem-cobertura run=0 skipped=base-vermelha=1 jail=1" fp_red

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
par kill_it fam-so-1            fp_sweep "$EXP_SWEEP" '"--timeout=%d" % PYTEST_TMO, *tgt["family"]]' '"--timeout=%d" % PYTEST_TMO, *tgt["family"][:1]]'
# como o pytest é chamado
par kill_it sem-randomly        fp_sweep "$EXP_SWEEP" '"-p", "no:randomly", ' ''
par kill_it sem-x               fp_sweep "$EXP_SWEEP" '"-q", "-x", ' '"-q", '
par kill_it sem-timeout         fp_sweep "$EXP_SWEEP" ', "--timeout=%d" % PYTEST_TMO,' ','
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
par kill_it copia-sem-pycache   fp_sweep "$EXP_SWEEP" 'ignore_patterns(".git", "__pycache__", "*.pyc"' 'ignore_patterns(".git", "*.pyc"'
par kill_it copia-sem-git       fp_sweep "$EXP_SWEEP" 'ignore_patterns(".git", "__pycache__"' 'ignore_patterns("__pycache__"'
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
par kill_it cap-do-flag-ignorado fp_plan "$EXP_PLAN" 'FAM_CAP, PYTEST_TMO, PYTHON = mine.fam_cap, mine.pytest_timeout' 'FAM_CAP, PYTEST_TMO, PYTHON = FAM_CAP, mine.pytest_timeout'
par kill_it sem-teste-off       fp_plan  "$EXP_PLAN" '        elif not fam:' '        elif False:'
par kill_it symlink-off         fp_plan  "$EXP_PLAN" '        if subj.resolve() != subj:' '        if False:'
par kill_it recente-sem-familia fp_plan  "$EXP_PLAN" 'bool(({rel} | set(fam)) & recent)' 'bool({rel} & recent)'
par kill_it recente-sem-sujeito fp_plan  "$EXP_PLAN" 'bool(({rel} | set(fam)) & recent)' 'bool(set(fam) & recent)'
par kill_it ordem-invertida     fp_plan  "$EXP_PLAN" 'plan.sort(key=lambda t: (not t["recent"],' 'plan.sort(key=lambda t: (t["recent"],'
par kill_it retry-ignorado      fp_retry "base-vermelha todo" '        elif old.get("skip") and now < old.get("retry_after", 0):' '        elif old.get("skip"):'
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
par kill_it baseline-ignorada   fp_red   "rc=0 sem-cobertura run=0 skipped=base-vermelha=1 jail=1" '    return rc, int(time.time() - t0)' '    return 0, int(time.time() - t0)'
reap
# controle do controle: o `mut` recusa uma âncora ambígua e uma que não casa
FAIL0=$FAIL   # o mut recusa e conta uma falha própria: aqui a recusa é o esperado, então só a aceitação reprova
for a in import texto-que-nao-existe-no-wrapper; do if mut ancora-ruim "$a" y > /dev/null 2>&1; then bad "mut aceitou âncora que não casa exatamente 1 vez: $a"; else FAIL=$FAIL0; ok; fi; done

echo "hq-mutate-wa selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
