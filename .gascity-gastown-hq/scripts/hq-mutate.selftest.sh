#!/usr/bin/env bash
# hq-mutate.selftest.sh (ga-2hd02v.5.6.2) — o motor de mutantes do lastro: acha os testes fracos sem tocar no que não é dele, e sem jaula provada nada roda.
#
# ## Contents
#   Hermético · Casos · Teto de escrita (ga-e6ug8gq) · Ambiente (97)
#
# HERMÉTICO: pasta descartável e uma JAULA FALSA que só registra cada execução e deixa passar. Cada caso é uma IMPRESSÃO DIGITAL (rc, veredito, contagens, execuções na jaula): vale se for a esperada, e o MUTANTE do motor vale se ela mudar (âncora que não casa exatamente 1 vez = INVÁLIDO, ga-31xxl5).
# TETO DE ESCRITA (ga-e6ug8gq): um mutante cujo selftest entra em laço de escrita morre pelo teto por arquivo (`--fsize-mb`) e conta como MORTO. O caso grava com um awk em laço (fixture `loopy.sh`, parado em ~264 MB só para um motor SEM teto não encher o disco deste selftest) com o teto em 4 MB e confere: o arquivo não passou de 4 MB, o awk morreu (rc 153), em menos de 5 s, o mutante contou como morto e a pasta de trabalho ficou vazia. Cada elo do teto tem seu mutante do motor (teto ausente, em bytes, não fixado, SIGXFSZ ignorado, só no soft, falha que roda mesmo assim, sem mínimo contra um limite herdado, uso sem validação).
# AMBIENTE: com a JAULA REAL (Linux com Landlock, o nó) roda também o caso de contenção (o caminho de fora vai no TEXTO do selftest, o `env -i` do motor apagaria uma variável; controle e mutante pelo mesmo caminho); sem ela imprime AMBIENTE e sai 97.
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
if cmd[0] == "env":   # o env -i do motor limpa o ambiente: o que um caso quer que o selftest veja entra aqui (o texto dele não leva caminho do host)
    cmd[2:2] = ["%s=%s" % (k, os.environ[k]) for k in ("FAKE_N", "FAKE_ORIG", "FAKE_B", "FAKE_M") if k in os.environ]
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
echo $(( 1 << n )) && cat <<< foo && echo $'it\'s -eq 3'
(( n = x << y )) || echo no && z="$(echo "$q" | tr -d '"') -eq 3"
echo \" \' && echo done
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
EXP_SH='13|and-or|&&|||
13|and-or|&&|||
14|and-or|&&|||
14|and-or||||&&
15|and-or|&&|||
3|eq-ne|-eq|-ne
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
printf 'x = """sem fim\n' > "$W/ruim.py"; hm gen "$W/ruim.py" > /dev/null 2>&1;            eq "gen: python que não tokeniza = rc 3, não zero candidatos" 3 $?
printf 'echo $[ 1 << y ]\n' > "$W/lo.sh"; hm gen "$W/lo.sh" > /dev/null 2>&1;              eq "gen: shell que acaba com heredoc aberto (scanner perdido; o bash aceita) = rc 3, não a lista incompleta" 3 $?
hm gen "$W/nao-existe.sh" > /dev/null 2>&1;      eq "gen: arquivo que não abre = rc 3" 3 $?
fp_valid() {
  python3 -I - "${ENG:-$HM}" << 'PY'
import importlib.util, os, sys, tempfile
from pathlib import Path
sp = importlib.util.spec_from_file_location("hqm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
a, b, c, d = m.valid(Path("a.sh"), "if x; then"), m.valid(Path("a.sh"), "echo ok"), m.valid(Path("a.py"), "x = ="), m.valid(Path("a.py"), "x = 1")
def sem(path):   # PATH sem bash (OSError) ou com um bash que sai 5 (nem 0 nem 1/2)
    os.environ["PATH"] = path
    try:
        return m.valid(Path("a.sh"), "echo ok")
    except Exception as x:
        return "estourou:" + type(x).__name__
f = tempfile.mkdtemp(); open(f + "/bash", "w").write("#!/bin/sh\nexit 5\n"); os.chmod(f + "/bash", 0o755)
print(a, b, c, d, sem("/nao/existe"), sem(f))
PY
}
EXP_VALID="False True False True None None"
peq "valid: mutante que não compila é recusado (bash -n, compile); sem bash, ou bash que sai com outro rc, NÃO se sabe: None, nunca False" "$EXP_VALID" fp_valid
fp_fit() {  # a linha de resumo cabe no limite do puxador (6000): os sobreviventes que não cabem saem e a linha diz quantos
  python3 -I - "${ENG:-$HM}" << 'PY'
import contextlib, importlib.util, io, json, sys
sp = importlib.util.spec_from_file_location("hqm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
def run(w):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        m.summary("parcial", killed=3, survivors=[{"id": "x" * 40, "file": "f" * w, "n": i} for i in range(20)])
    l = buf.getvalue().rstrip("\n"); d = json.loads(l)
    return len(l) <= 6000, len(d["survivors"]), d.get("survivors_cortados", 0)
print(run(20), run(600))
PY
}
EXP_FIT="(True, 15, 5) (True, 8, 12)"
peq "summary: no máximo 15 sobreviventes e a linha cabe em 6000; o que não cabe sai e é contado" "$EXP_FIT" fp_fit
fp_sweep() {
  newfx; mkfoo; local o; o=$(cks "$TREE/scripts/foo.sh"); sw
  echo "$(cnt) surv=$(jf '",".join(sorted(s["op"] for s in d["survivors"]))') rec=$(jf 'd["recent"]') jail=$(runs) orig=$([ "$(cks "$TREE/scripts/foo.sh")" = "$o" ] && echo igual || echo MUDOU)" \
       "left=$(ls "$F/work" | wc -l | tr -d ' ') home=$(awk -F'\t' -v w="$F/work/slot-" '$1 == "run" && (index($3, w) != 1 || index($4, w) != 1) {n++} END {print n+0}' "$F/jail.log")" \
       "gen=$(hm gen --tree "$TREE" "$TREE/scripts/foo.sh" | cut -f1 | sort > "$F/g"; jf '"\n".join(sorted(x["id"] for x in d["survivors"]))' | sort | comm -12 - "$F/g" | wc -l | tr -d ' ')"
}
EXP_SWEEP="rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 surv=cmp-lim,exit-rc,exit-rc,num+1 rec=indisponivel jail=11 orig=igual left=0 home=0 gen=4"
fp_again() { newfx; mkfoo; sw; local j; j=$(runs); sw; echo "$(jf 'd["result"]') run=$(jf 'd["mutants_run"]') novas=$(( $(runs) - j ))"; }
fp_cap() {
  newfx; mkfoo; local o="" i
  for i in 1 2 3 4; do sw --cap 2; o="$o $(jf 'd["result"]'):$(jf 'd["mutants_run"]'):$(jf 'd["restam"]')"; done; echo "$o verdicts=$(python3 -I -c 'import json,sys; print(sum(len(t["verdicts"]) for t in json.load(open(sys.argv[1]))["targets"].values()))' "$F/state.json")"
}
fp_jail() { newfx; mkfoo; FAKE_JAIL=inerte sw; echo "rc=$RC $(jf 'd["result"]') jail=$(runs) state=$([ -e "$F/state.json" ] && echo existe || echo nao)"; }
fp_base() {  # fp_base RC: o selftest do foo sai com RC mesmo sem mutante
  newfx; mkfoo; mkst foo ": foo.sh; exit $1"; sw
  echo "rc=$RC res=$(jf 'd["result"]') run=$(jf 'd["mutants_run"]') jail=$(runs) skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))') plan=$(hm plan --tree "$TREE" --state "$F/state.json" | cut -f1)"
}
fp_state() {  # fp_state CONTEÚDO: estado que não lê = rc 3, o arquivo intacto, nada rodou
  newfx; mkfoo; printf '%s' "$1" > "$F/state.json"; local b; b=$(cks "$F/state.json"); sw
  echo "rc=$RC $(jf 'd["result"]') kept=$([ "$(cks "$F/state.json")" = "$b" ] && echo sim || echo NAO) jail=$(runs)"
}
fp_flaky() {  # passa na baseline e na 1ª rodada do mutante, reprova na re-execução: flaky, não sobrevivente (o contador vive no FAKE_N)
  newfx; printf '#!/bin/bash\nexit 7\n' > "$TREE/scripts/fl.sh"; export FAKE_N="$F/n"; : > "$FAKE_N"
  mkst fl 'echo x >> "$FAKE_N"; [ "$(wc -l < "$FAKE_N" | tr -d " ")" = 3 ] && exit 1
bash "$H/fl.sh"'; sw
  echo "$(cnt) jail=$(runs)"
}
fp_family() {  # o 1º selftest da família (beta-ext) é fraco; o 2º (beta) mata mais um: os dois têm de rodar
  newfx; printf '%s\n' "$FOO" > "$TREE/scripts/beta.sh"
  mkst beta-ext '[ "$(bash "$H/beta.sh" 9)" = big ] || exit 1'; mkst beta 'bash "$H/beta.sh" 9 > /dev/null || exit 1'; sw
  echo "$(cnt)"
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
fp_shims() { echo "$(fp_shim shim:shim) $(fp_shim real:shim) $(fp_shim shim:real)"; }
fp_env() {  # o ambiente do motor (HQM_SECRET: SSH_AUTH_SOCK, tokens, REMOTE_SHIM_CONF…) NÃO chega ao mutante; o PATH chega
  newfx; mkfoo; mkst foo '[ -z "${HQM_SECRET:-}" ] || exit 1
[ -n "${PATH:-}" ] || exit 1
[ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'
  HQM_SECRET=vazou sw; echo "$(cnt) skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))')"
}
fp_ilegivel() {  # python que não tokeniza = ilegivel; shell em que o scanner se perde (`$[ 1 << y ]`, aritmética velha que o bash aceita) = scan-perdido; nenhum dos dois conta como coberto
  newfx; printf 'x = """sem fim\n' > "$TREE/scripts/ruim.py"; mkst ruim 'python3 "$H/ruim.py" 2> /dev/null; true'
  printf 'echo $[ 1 << y ]\n' > "$TREE/scripts/lo.sh"; mkst lo 'bash "$H/lo.sh"'; sw
  echo "rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))') perdidos=$(jf 'len(d["perdidos"])') plan=$(hm plan --tree "$TREE" --state "$F/state.json" | cut -f1 | sort | paste -sd' ' -)"
}
fp_hash() { newfx; mkfoo; sw; printf '# mudou\n' >> "$TREE/scripts/foo.sh"; hm plan --tree "$TREE" --state "$F/state.json" | cut -f1,2 | tr '\t' '@'; }
fp_term() {  # fp_term b|m: TERM com a baseline (b) ou com 2 mutantes (m) em voo; o kill não vira veredito e a retomada acha os mesmos sobreviventes do controle
  newfx; mkfoo; cp "$TREE/scripts/foo.sh" "$F/foo.orig"; local n=1 B=30 M=0 pid i=0 a; [ "$1" = m ] && { n=3; B=0; M=30; }
  export FAKE_ORIG="$F/foo.orig" FAKE_B=$B FAKE_M=$M
  mkst foo 'cmp -s "$H/foo.sh" "$FAKE_ORIG" && sleep "$FAKE_B" || sleep "$FAKE_M"
[ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'
  python3 -I "${ENG:-$HM}" sweep --tree "$TREE" --state "$F/state.json" --work "$F/work" --jail "$W/fakejail.py" --slots 2 > "$F/out" 2> "$F/err" & pid=$!
  while [ "$(runs)" -lt "$n" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done
  kill -TERM "$pid" 2> /dev/null; ( sleep 20; kill -9 "$pid" 2> /dev/null ) & local wd=$!
  wait "$pid"; RC=$?; kill "$wd" 2> /dev/null; wait "$wd" 2> /dev/null
  a="rc=$RC $(jf 'd["result"]') v=$(python3 -I -c 'import json,os,sys; print(sum(len(t["verdicts"]) for t in json.load(open(sys.argv[1]))["targets"].values()) if os.path.exists(sys.argv[1]) else 0)' "$F/state.json")"
  export FAKE_B=0 FAKE_M=0; sw
  echo "$a | $(cnt) surv=$(jf '",".join(sorted(s["op"] for s in d["survivors"]))')"
}
fp_sem_alvos() {  # sem alvo = rc 3; só alvo pulado (denylist) = rc 0 mas sem-cobertura, nunca sem-novidade
  newfx; mkst so 'true'; sw; local a="rc=$RC $(jf 'd["result"]')"
  mkdir -p "$F/v/hq"; hm sweep --tree "$F/v/hq" --state "$F/s2.json" --work "$F/work" --jail "$W/fakejail.py" > "$F/out" 2> /dev/null; a="$a rc=$? $(jf 'd["result"]')"
  mkfoo; mkst foo 'bash "$H/foo.sh"; : sudo'; sw; echo "$a rc=$RC $(jf 'd["result"]') skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))')"
}
fp_symlink() {
  newfx; mkfoo; mkdir "$F/ext"; mv "$TREE/scripts/foo.sh" "$F/ext/foo.sh"; ln -s "$F/ext/foo.sh" "$TREE/scripts/foo.sh"; local a; a=$(cks "$F/ext/foo.sh"); sw
  echo "rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))') ext=$([ "$(cks "$F/ext/foo.sh")" = "$a" ] && echo intacto || echo MUDOU)"
}
fp_falha() {   # um ARQUIVO no lugar da pasta do slot: a execução falha por infra
  newfx; mkfoo; : > "$F/work/slot-0"; : > "$F/work/slot-1"; sw; local a="rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') falhas=$(jf 'd["falhas"]')"
  rm -f "$F/work/slot-0" "$F/work/slot-1"; sw; echo "$a | $(cnt)"
}
fp_jailrel() { newfx; mkfoo; cd "$W" && JAIL=fakejail.py sw; cnt; }   # --jail relativo (a forma do USO): resolvido uma vez, senão toda baseline vira vermelha
EXP_SW0="rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4"; EXP_SYM="rc=0 sem-cobertura run=0 skipped=symlink=1 ext=intacto"; EXP_FALHA="rc=0 parcial run=0 falhas=1 | $EXP_SW0"
peq "sujeito symlink: pulado (symlink=1), nada rodou e o arquivo de fora não mudou" "$EXP_SYM" fp_symlink
peq "execução que falha por infra: rc 0, parcial, falhas=1, nenhum veredito; consertado o slot a varredura seguinte roda os 6" "$EXP_FALHA" fp_falha
peq "--jail relativo funciona como o absoluto" "$EXP_SW0" fp_jailrel
fp_fsize_head() {   # (ga-2hd02v.5.6.3) o selftest escreve 3 MB num arquivo do slot com o teto em 1 MB: o laço de escrita para no teto (aqui são 3 MB, nunca GB)
  newfx; mkfoo; mkdir "$F/fora"
  mkst foo '( head -c 3000000 /dev/zero > "$TMPDIR/big" ) 2> /dev/null
wc -c < "$TMPDIR/big" >> "'"$F"'/fora/size"
[ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'
  sw --fsize-mb 1; m=$(tr -d ' ' < "$F/fora/size" | sort -n | tail -1)
  echo "$(cnt) teto=$([ "${m:-0}" -gt 0 ] && [ "${m:-0}" -le 1048576 ] && echo sim || echo "nao:${m:-vazio}")"
}
peq "--fsize-mb 1: o arquivo que o mutante escreve para no teto e o veredito é o mesmo" "$EXP_SW0 teto=sim" fp_fsize_head
# teto de ESCRITA por arquivo (ga-e6ug8gq). 27/10 05:09-05:24: um mutante virou um laço de awk que gravou 4,2 e 5,6 GB em $TMPDIR, duas vezes, o disco do mini zerou e o Dolt ficou com ENOSPC. O fixture é esse mutante: com
# o `-gt` virado, o caminho do 9 cai num laço de awk que não para (travado em 8 milhões de linhas, ~260 MB, só para que um motor SEM teto não encha o disco deste selftest); o teto de 4 MB tem de cortá-lo muito antes.
# O laço deixa FORA do slot (a jaula falsa deixa) o que viu: o rc do awk (153 = 128 + SIGXFSZ, morto pelo teto) e o tamanho do arquivo. Morto pelo teto = mutante MORTO, nunca falha de infra.
mkloopy() {
  cat > "$TREE/scripts/loopy.sh" << 'EOF'
#!/bin/bash
# loopy.sh: fixture
n=${1:-0}; ev=${2:-/dev/null}
if [ "$n" -gt 5 ]; then echo big; exit 0; fi
awk -v f="$TMPDIR/big" 'BEGIN { while (1) { print "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" > f; if (++i > 8000000) exit } }'
echo "awk_rc=$? size=$(wc -c < "$TMPDIR/big" | tr -d ' ')" > "$ev"
echo small
exit 0
EOF
  mkst loopy 'out=$(bash "$H/loopy.sh" 9 "'"$F"'/ev"); [ "$out" = big ] || exit 1'
}
fp_fsize() {  # fp_fsize [MB]: a varredura do fixture com teto de MB (4)
  newfx; mkloopy; local t0=$SECONDS ev ar sz cap=${1:-4}
  sw --fsize-mb "$cap"; ev=$(cat "$F/ev" 2> /dev/null); ar=${ev#awk_rc=}; ar=${ar%% *}; sz=${ev##*size=}
  echo "$(cnt) falhas=$(jf 'd["falhas"]') awk_rc=$ar teto=$([ -n "$sz" ] && [ "$sz" -le $((cap * 1048576)) ] 2> /dev/null && echo respeitado || echo "ESTOUROU($sz)") rapido=$([ $((SECONDS - t0)) -lt 5 ] && echo sim || echo NAO) left=$(ls "$F/work" | wc -l | tr -d ' ')"
}
EXP_FSIZE="rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 falhas=0 awk_rc=153 teto=respeitado rapido=sim left=0"
peq "mutante em laço de escrita infinito: o teto por arquivo (4 MB) corta o awk em menos de 5 s (rc 153), o arquivo não passa do teto, o mutante é MORTO e não vira falha de infra" "$EXP_FSIZE" fp_fsize
fp_fsize_uso() { newfx; mkfoo; local o="" v; for v in 0 -3 abc ""; do sw --fsize-mb "$v"; o="$o $RC"; done; sw --fsize-mb 1; echo "$o | $(cnt)"; }
peq "--fsize-mb que não é um inteiro >= 1 (0, negativo, texto, vazio) é uso (rc 2): sem teto não há varredura; 1 MB roda como qualquer outro" " 2 2 2 2 | $EXP_SW0" fp_fsize_uso
# teto que o lançador não consegue fixar (aqui: maior que o rlimit aceita) = nada roda, nunca roda SEM teto: a baseline fica vermelha e o alvo é pulado
fp_fsize_enorme() { newfx; mkfoo; sw --fsize-mb 99999999999999999999; echo "rc=$RC res=$(jf 'd["result"]') run=$(jf 'd["mutants_run"]') skipped=$(jf '",".join("%s=%d" % kv for kv in sorted(d["skipped"].items()))')"; }
EXP_FSIZE_ENORME="rc=0 res=sem-cobertura run=0 skipped=base-vermelha=1"
peq "teto que o lançador não consegue fixar: rc 70 do lançador, baseline vermelha, nenhum mutante roda (nunca roda sem teto)" "$EXP_FSIZE_ENORME" fp_fsize_enorme
# o motor roda sob um limite DURO menor que o pedido (um sistema que já limita): vale o menor, o teto não vira recusa e a varredura roda igual
fp_fsize_duro() { ( ulimit -f 2048 || exit 1; fp_fsize 4 ); }   # sem -H: soft e hard juntos (um hard abaixo do soft atual dá EINVAL)
peq "limite duro do sistema (2 MB) menor que o --fsize-mb pedido (4): vale o menor, a varredura roda igual e o laço morre" "$EXP_FSIZE" fp_fsize_duro
peq "sweep: mortos, sobreviventes confirmados, original intacto, HOME/TMPDIR no slot, slots limpos; os ids do gen --tree são os que ele grava" "$EXP_SWEEP" fp_sweep
fp_semvalid() {  # bash -n que sai com rc estranho: nenhum veredito (nem "i"), nao_sei, e a varredura seguinte tenta de novo
  newfx; mkfoo; mkdir "$F/bin"; printf '#!/bin/sh\n[ "$1" = -n ] && exit 5\nexec /bin/bash "$@"\n' > "$F/bin/bash"; chmod +x "$F/bin/bash"
  PATH="$F/bin:$PATH" sw; local a="rc=$RC $(jf 'd["result"]') run=$(jf 'd["mutants_run"]') nao_sei=$(jf 'd["nao_sei"]') inv=$(jf 'd["invalid"]') restam=$(jf 'd["restam"]')"
  sw; echo "$a | $(cnt)"
}
peq "sweep de novo, mesmo conteúdo: sem-novidade e nada roda (varrer o mesmo é queima disfarçada)" "sem-novidade run=0 novas=0" fp_again
EXP_CAP=" completo:2:4 completo:2:2 completo:2:0 sem-novidade:0:0 verdicts=6"
peq "--cap 2: pega os próximos ainda não vistos até cobrir os 6 (restam diz quantos faltam), depois sem-novidade" "$EXP_CAP" fp_cap
EXP_SV="rc=0 sem-cobertura run=0 nao_sei=1 inv=0 restam=6 | rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4"
peq "bash -n sem resposta (rc 5): nada roda, nenhum veredito, nao_sei; a varredura seguinte roda os 6" "$EXP_SV" fp_semvalid
peq "jaula não provada: rc 97, nenhuma execução, nenhum estado" "rc=97 sem-jaula jail=0 state=nao" fp_jail
EXP_B1="rc=0 res=sem-cobertura run=0 jail=1 skipped=base-vermelha=1 plan=base-vermelha"
peq "baseline vermelha pula o alvo (1 execução, nenhum mutante), o plan diz por quê e o result é sem-cobertura" "$EXP_B1" fp_base 1
EXP_B97="rc=0 res=sem-cobertura run=0 jail=1 skipped=base-ambiente=1 plan=base-ambiente"
peq "baseline 97 pula como base-ambiente" "$EXP_B97" fp_base 97
for s in 'lixo{' '' '{"v":99,"targets":{}}' '[]' '{"v":1}' '{"v":1,"targets":{"scripts/foo.sh":[]}}' '{"v":1,"targets":{"scripts/foo.sh":{"verdicts":[]}}}'; do
  peq "estado ilegível ($s): rc 3, intacto, nada roda" "rc=3 estado-ilegivel kept=sim jail=0" fp_state "$s"
done
peq "re-execução que reprova = flaky, nunca sobrevivente" "rc=0 completo run=1 k=0 c=0 f=1 inv=0 open=0 jail=3" fp_flaky
peq "a família inteira roda a cada mutante (o 2º selftest mata mais um)" "rc=0 completo run=6 k=3 c=3 f=0 inv=0 open=3" fp_family
fp_denys() { local t o=""; for t in 'sudo true' 'kill -s KILL -1' 'tmux send-keys x' 'curl --unix-socket /x http://a' 'kill -9 "$pid"'; do o="$o|$(fp_deny2 "$t")"; done; echo "$o"; }
peq "denylist: sudo, kill com sinal e -1, tmux e --unix-socket pulam o alvo; kill de um pid só NÃO (nada de largo demais)" "|denylist:sudo|denylist:kill -s KILL -1|denylist:tmux|denylist:--unix-socket|todo" fp_denys
peq "gc e bd symlinks para o remote-shim (o nó Hetzner) NÃO são denylist; gc ou bd de verdade são (decide por programa)" "todo denylist:gc denylist:bd" fp_shims
peq "o ambiente do motor não chega ao mutante (env -i), o PATH chega" "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 skipped=" fp_env
EXP_ILEG="rc=0 sem-cobertura run=0 skipped=ilegivel=1,scan-perdido=1 perdidos=1 plan=ilegivel scan-perdido"
peq "sujeito que não tokeniza é ilegivel e shell perdido é scan-perdido (a razão em perdidos): nem zero candidatos, nem queda, nem coberto" "$EXP_ILEG" fp_ilegivel
peq "conteúdo mudado: o alvo volta a ser todo" "todo@scripts/foo.sh" fp_hash
EXP_TERM="rc=143 interrompido v=0 | rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 surv=cmp-lim,exit-rc,exit-rc,num+1"
peq "TERM com a baseline em voo: rc 143, nada gravado, a retomada varre tudo" "$EXP_TERM" fp_term b
peq "TERM com mutantes em voo: rc 143, NENHUM veredito do kill (rc -9 não é teste), a retomada acha os mesmos sobreviventes" "$EXP_TERM" fp_term m
EXP_SA="rc=3 sem-alvos rc=3 sem-alvos rc=0 sem-cobertura skipped=denylist=1"
peq "sem alvos (selftest sem sujeito; árvore sem scripts/) = rc 3; só alvo na denylist = sem-cobertura, nunca sem-novidade" "$EXP_SA" fp_sem_alvos
newfx; mkfoo; mkdir "$F/root/w"; hm sweep --tree "$TREE" --state "$F/s.json" --work "$F/root/w" --jail "$W/fakejail.py" > /dev/null 2>&1; eq "--work dentro da árvore copiada = rc 2" 2 $?
newfx; mkfoo; printf 'lixo' > "$F/s.json"; hm plan --tree "$TREE" --state "$F/s.json" > /dev/null 2>&1; eq "plan com estado ilegível = rc 3" 3 $?

# ── plan: sujeito, família, exclusões, ordem, cobertura, retry_after ────────────────────────────────
fp_plan() {
  newfx; local n R="$F/root" ord cov part skip exp
  for n in alpha beta zeta delta gamma hetzner-ballast-q; do echo 'echo x' > "$TREE/scripts/$n.sh"; mkst "$n" "bash \"\$H/$n.sh\""; done
  mkst delta 'bash "$H/delta.sh"; : sudo'; mkst gamma 'true'
  mkdir -p "$TREE/packs/town-deltas/assets"; echo 'x = 1' > "$TREE/packs/town-deltas/assets/eps.py"; mkst eps 'python3 "$H/eps.py"; : mut x' packs/town-deltas/assets
  git -C "$R" init -q
  git -C "$R" add . ; git -C "$R" reset -q -- hq/scripts/alpha.sh hq/scripts/alpha.selftest.sh
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m velho
  git -C "$R" add . ; git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m novo
  local pl="hm plan --tree $TREE --state $F/st.json" h1 h2; echo '{"v":1,"targets":{}}' > "$F/st.json"
  h1=$($pl | awk -F'\t' '$2 == "scripts/zeta.sh" {print $6}'); h2=$($pl | awk -F'\t' '$2 == "scripts/beta.sh" {print $6}')
  st() { printf '{"v":1,"targets":{"scripts/zeta.sh":%s,"scripts/beta.sh":%s}}' "$1" "$2" > "$F/st.json"; $pl | awk -F'\t' -v r="$3" '$2 == r {print $1}'; }
  ord=$(st "{\"hash\":\"$h1\",\"swept\":100}" "{\"hash\":\"$h2\",\"swept\":500}" scripts/zeta.sh > /dev/null; $pl | awk -F'\t' '{printf "%s@%s ", $1, $2}')
  cov=$(st "{\"hash\":\"$h1\",\"total\":2,\"verdicts\":{\"a\":\"k\",\"b\":\"k\"}}" '{}' scripts/zeta.sh)
  part=$(st "{\"hash\":\"$h1\",\"total\":3,\"verdicts\":{\"a\":\"k\",\"b\":\"k\"}}" '{}' scripts/zeta.sh)
  skip=$(st '{}' "{\"hash\":\"$h2\",\"skip\":\"base-vermelha\",\"retry_after\":99999999999}" scripts/beta.sh)
  exp=$(st '{}' "{\"hash\":\"$h2\",\"skip\":\"base-vermelha\",\"retry_after\":1}" scripts/beta.sh)
  echo "$ord| cov=$cov part=$part skip=$skip exp=$exp"
}
EXP_PLAN="todo@scripts/alpha.sh denylist:sudo@scripts/delta.sh todo@scripts/zeta.sh todo@scripts/beta.sh todo@packs/town-deltas/assets/eps.py | cov=sem-novidade part=todo skip=base-vermelha exp=todo"
peq "plan: alpha (mudou há <7 dias) primeiro; depois sem mutante embutido e menos recente; eps (embutido) por último; gamma e hetzner-ballast fora; cobertura e retry_after" "$EXP_PLAN" fp_plan
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
kill_it() { mut "$1" "$4" "$5" && ne "mutante $1 ($2)" "$3" "$(ENG="$MP" "$2" ${6+"$6"} 2> /dev/null)"; }
par kill_it sem-reconfirma       fp_flaky   "rc=0 completo run=1 k=0 c=0 f=1 inv=0 open=0 jail=3" '    return None if r2 is None else "s" if r2[0] == 0 else "f"' '    return None if r2 is None else "s"'
par kill_it prova-ignorada       fp_jail    "rc=97 sem-jaula jail=0 state=nao" '    if proof is None:' '    if False:'
par kill_it baseline-ignorada    fp_base    "$EXP_B1" '            if rc != 0:' '            if False:' 1
par kill_it ambiente-e-vermelha  fp_base    "$EXP_B97" '"base-ambiente" if rc == 97 else' '"base-ambiente" if False else' 97
par kill_it sem-cobertura-falsa  fp_base    "$EXP_B1" '"sem-cobertura" if not n["run"] and' '"sem-cobertura" if False and' 1
par kill_it denylist-off         fp_denys   "|denylist:sudo|denylist:kill -s KILL -1|denylist:tmux|denylist:--unix-socket|todo" '        elif deny:' '        elif False:'
par kill_it kill-largo-demais    fp_denys   "|denylist:sudo|denylist:kill -s KILL -1|denylist:tmux|denylist:--unix-socket|todo" '|\bkill\b[^\n]*\s-1\b|' '|\bkill\b|'
par kill_it tmux-fora            fp_denys   "|denylist:sudo|denylist:kill -s KILL -1|denylist:tmux|denylist:--unix-socket|todo" '|tmux|' '|'
par kill_it shim-invertido       fp_shims   "todo denylist:gc denylist:bd" 'not in SHIMS]' 'in SHIMS]'
par kill_it shim-sem-realpath    fp_shims   "todo denylist:gc denylist:bd" 'os.path.realpath(shutil.which(b))' 'shutil.which(b)'
par kill_it resumo-sem-corte     fp_fit     "$EXP_FIT" '    while len(line) > MAX_LINE and' '    while False and'
par kill_it corte-sem-conta      fp_fit     "$EXP_FIT" '        kw["survivors_cortados"] += 1' '        pass'
par kill_it cortados-sem-15      fp_fit     "$EXP_FIT" 'max(0, len(kw["survivors"]) - 15)' '0'
par kill_it valid-sem-bash       fp_valid   "$EXP_VALID" $'    except (OSError, subprocess.TimeoutExpired):\n        return None\n    return True' $'    except ZeroDivisionError:\n        return None\n    return True'
par kill_it valid-rc-qualquer    fp_valid   "$EXP_VALID" 'return True if rc == 0 else False if rc in (1, 2) else None' 'return rc == 0'
par kill_it valid-py-sempre      fp_valid   "$EXP_VALID" $'            compile(text, str(path), "exec")\n            return True' '            return True'
par kill_it nao-sei-vira-i       fp_semvalid "$EXP_SV" '                elif ok is None:' '                elif False:'
par kill_it env-herdado          fp_env     "rc=0 completo run=6 k=2 c=4 f=0 inv=0 open=4 skipped=" '"env", "-i", *kv, "timeout", "-k"' '"env", *kv, "timeout", "-k"'
par kill_it sobrevivente-calado  fp_sweep   "$EXP_SWEEP" '                    new_surv.append(rec)' '                    pass'
par kill_it jaula-nao-usada      fp_sweep   "$EXP_SWEEP" '[sys.executable, "-I", ctx.a.jail, "--rw", str(slot), "--", "env", "-i", *kv, "timeout",' '["env", "-i", *kv, "timeout",'
par kill_it escreve-no-original  fp_sweep   "$EXP_SWEEP" '(cd / tgt["rel"]).write_text(text, encoding="utf-8")' '(ctx.tree / tgt["rel"]).write_text(text, encoding="utf-8")'
par kill_it home-na-jaula        fp_sweep   "$EXP_SWEEP" 'p = subprocess.Popen(cmd, cwd=cd, stdin=' 'p = subprocess.Popen(cmd, cwd=cd, env=dict(os.environ, HOME=str(slot / "home")), stdin='
par kill_it home-real            fp_sweep   "$EXP_SWEEP" '+ ["HOME=%s" % (slot / "home"), ' '+ ['
par kill_it sem-novidade-falso   fp_again   "sem-novidade run=0 novas=0" 'elif "total" in old and len(old.get("verdicts", {})) >= old["total"]:' 'elif False:'
par kill_it cota-ignorada        fp_cap     "$EXP_CAP" '                if len(pick) >= a.cap:' '                if False:'
par kill_it hash-ignorado        fp_hash    "todo@scripts/foo.sh" '        old = old if old.get("hash") == h else {}' '        old = old'
par kill_it familia-so-1         fp_family  "rc=0 completo run=6 k=3 c=3 f=0 inv=0 open=3" '    for st in tgt["family"]:' '    for st in tgt["family"][:1]:'
par kill_it term-ignorado        fp_term    "$EXP_TERM" '        ctx.stop.set()' '        pass' m
par kill_it kill-vira-veredito   fp_term    "$EXP_TERM" '        return None if ctx.stop.is_set() else r' '        return r' m
par kill_it ilegivel-derruba     fp_ilegivel "$EXP_ILEG" '            except (OSError, ValueError, SyntaxError, tokenize.TokenError) as e:' '            except OSError as e:'
par kill_it perdido-e-ilegivel   fp_ilegivel "$EXP_ILEG" '"scan-perdido" if isinstance(e, Lost) else "ilegivel"' '"ilegivel"'
par kill_it perdido-calado       fp_ilegivel "$EXP_ILEG" '        raise Lost(' '        _ = ('
par kill_it estado-zera         fp_state   "rc=3 estado-ilegivel kept=sim jail=0" '    except FileNotFoundError:' '    except (FileNotFoundError, ValueError):' 'lixo{'
par kill_it forma-ignorada       fp_state   "rc=3 estado-ilegivel kept=sim jail=0" ' or not all(shaped(e) for e in d["targets"].values())' '' '{"v":1,"targets":{"scripts/foo.sh":[]}}'
par kill_it ordem-invertida      fp_plan    "$EXP_PLAN" 'plan.sort(key=lambda t: (not t["recent"],' 'plan.sort(key=lambda t: (t["recent"],'
par kill_it ordem-sem-embutido   fp_plan    "$EXP_PLAN" 't["embedded"], t["swept"], t["rel"]' 't["rel"]'
par kill_it retry-ignorado       fp_plan    "$EXP_PLAN" '        elif old.get("skip") and now < old.get("retry_after", 0):' '        elif old.get("skip"):'
par kill_it ocorrencia-ignorada  fp_gen     "$EXP_GEN" '"%s:%d" % (key, seen[key])' '"%s:%d" % (key, 1)'
par kill_it aspas-sao-codigo     fp_gen     "$EXP_GEN" '                st.append(["ansi" if line[i - 1:i] == "$" else "sq", 0, n])' '                pass'
par kill_it ansi-e-sq            fp_gen     "$EXP_GEN" '"ansi" if line[i - 1:i] == "$" else "sq"' '"sq"'
par kill_it comentario-e-codigo  fp_gen     "$EXP_GEN" '            elif c == "#" and (' '            elif False and ('
par kill_it heredoc-e-codigo     fp_gen     "$EXP_GEN" '                    here = (m.group(3), m.group(1) == "-", n)' '                    here = None'
par kill_it here-string-e-heredoc fp_gen    "$EXP_GEN" ' and line[i - 1:i] != "<"' ''
par kill_it aritmetica-e-heredoc fp_gen     "$EXP_GEN" ' and line[:i].count("((") <= line[:i].count("))")' ''
par kill_it jail-relativo        fp_jailrel "$EXP_SW0" '    a.jail = str(Path(a.jail).resolve())' '    pass'
par kill_it head-teto-ausente    fp_fsize_head "$EXP_SW0 teto=sim" 'sys.executable, "-I", "-c", CAPPER, str(ctx.a.fsize_mb << 20), "bash", st]' '"bash", st]'
par kill_it head-teto-fixo       fp_fsize_head "$EXP_SW0 teto=sim" 'str(ctx.a.fsize_mb << 20)' '"536870912"'
par kill_it symlink-gravado      fp_symlink "$EXP_SYM" '        if subj.resolve() != subj:' '        if False:'
par kill_it falha-derruba        fp_falha   "$EXP_FALHA" '    except (OSError, RuntimeError):' '    except ZeroDivisionError:'
par kill_it falha-calada         fp_falha   "$EXP_FALHA" '            ctx.falhas += 1' '            pass'
par kill_it falha-e-completo     fp_falha   "$EXP_FALHA" ' and not ctx.falhas' ''
par kill_it base-nula-cai        fp_falha   "$EXP_FALHA" '            if r is None:' '            if False:'
par kill_it gen-sem-tree         fp_sweep   "$EXP_SWEEP" 'Path(a.file).resolve().relative_to(Path(a.tree).resolve()).as_posix() if a.tree else Path(a.file).name' 'Path(a.file).name'
par kill_it teto-ausente         fp_fsize   "$EXP_FSIZE" 'sys.executable, "-I", "-c", CAPPER, str(ctx.a.fsize_mb << 20), "bash", st]' '"bash", st]'
par kill_it teto-em-bytes        fp_fsize   "$EXP_FSIZE" 'str(ctx.a.fsize_mb << 20)' 'str(ctx.a.fsize_mb)'
par kill_it teto-nao-fixa        fp_fsize   "$EXP_FSIZE" '    resource.setrlimit(resource.RLIMIT_FSIZE, (n, n))\n' '    pass\n'
par kill_it sigxfsz-ignorado     fp_fsize   "$EXP_FSIZE" '    signal.signal(signal.SIGXFSZ, signal.SIG_DFL)\n' '    pass\n'
par kill_it teto-so-no-soft      fp_fsize   "$EXP_FSIZE" 'resource.setrlimit(resource.RLIMIT_FSIZE, (n, n))' 'resource.setrlimit(resource.RLIMIT_FSIZE, (n, resource.RLIM_INFINITY))'
par kill_it teto-falha-e-roda    fp_fsize_enorme "$EXP_FSIZE_ENORME" '    os._exit(70)\n' '    pass\n'
par kill_it teto-sem-minimo      fp_fsize_duro "$EXP_FSIZE" '    n = n if hard == resource.RLIM_INFINITY else min(n, hard)\n' '    n = n\n'
par kill_it teto-uso-aceita-zero fp_fsize_uso   " 2 2 2 2 | $EXP_SW0" 'if a.cmd == "sweep" and a.fsize_mb < 1:' 'if a.cmd == "sweep" and a.fsize_mb < 0:'
reap
# controle do controle: o `mut` recusa uma âncora ambígua e uma que não casa
FAIL0=$FAIL   # o mut recusa e conta uma falha própria: aqui a recusa é o esperado, então só a aceitação reprova
for a in import texto-que-nao-existe-no-motor; do if mut ancora-ruim "$a" y > /dev/null 2>&1; then bad "mut aceitou âncora que não casa exatamente 1 vez: $a"; else FAIL=$FAIL0; ok; fi; done

# ── jaula real (o nó): o mutante que escreve fora do --work não deixa rastro ───────────────────
SKIP=0
out=$(python3 -I "$HERE/hq-sandbox-run.py" --probe 2>&1) && case "$out" in "HQSB: abi="*) ;; *) SKIP=1 ;; esac || SKIP=1
if [ "$SKIP" = 1 ]; then
  echo "AMBIENTE: sem Landlock ABI >= 4 aqui ($out): o caso com a jaula REAL não rodou (o nó roda)"
else
  vz() {  # o selftest escreve fora do --work; o caminho vai no TEXTO dele (o env -i do motor apagaria uma variável); quem decide se a escrita passa é a jaula
    newfx; mkfoo; mkdir "$F/fora"
    mkst foo '( echo x > "'"$F"'/fora/vazou" ) 2> /dev/null
[ "$(bash "$H/foo.sh" 9)" = big ] || exit 1
[ "$(bash "$H/foo.sh" 1)" = small ] || exit 1'
    JAIL=$1 sw; echo "$(cnt) vazou=$([ -e "$F/fora/vazou" ] && echo SIM || echo nao)"
  }
  eq "jaula real: o veredito é o mesmo e a escrita fora do --work é barrada" "$EXP_SW0 vazou=nao" "$(vz "$HERE/hq-sandbox-run.py")"
  eq "controle pelo MESMO caminho do motor, com a jaula que não contém: a escrita passa" "$EXP_SW0 vazou=SIM" "$(vz "$W/fakejail.py")"
  eq "mutante jaula-nao-usada com a jaula real: a escrita passa (o caso reprova se a contenção cair)" "$EXP_SW0 vazou=SIM" "$(ENG="$W/eng-jaula-nao-usada.py" vz "$HERE/hq-sandbox-run.py")"
fi

echo "hq-mutate selftest: $PASS passed, $FAIL failed$([ "$SKIP" = 1 ] && echo ", caso da jaula real NÃO rodou (AMBIENTE)")"
[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP" -eq 0 ] || exit 97
exit 0
