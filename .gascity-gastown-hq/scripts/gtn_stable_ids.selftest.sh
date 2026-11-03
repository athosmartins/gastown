#!/usr/bin/env bash
# gtn_stable_ids.selftest.sh — o plugin gtn_stable_ids.py e o hetzner-nightly-tests.sh contra o pytest + xdist DE VERDADE (ga-9p6pte, gate 1).
#
# ## Contents
#   Por quê · Casos · Controles negativos · Requisito
#
# POR QUÊ: o hetzner-nightly-tests.selftest.sh é hermético (a saída do pytest é de mentira). Foi assim que o corte da linha `FAILED <id> - <msg>` no primeiro " - " passou: o selftest
#   alimentava o script com ids sem " - " escritos à mão. Este arquivo roda o pytest de verdade, num projeto minúsculo que tem os formatos que importam, e passa a saída REAL ao script real.
# CASOS: (1) plugin: a lista GTN-FAIL tem os 7 ids distintos (irmãos de parametrize com " - ", id com acento escapado pelo pytest, erro de coleta, erro de setup, falha + erro de teardown no
#   mesmo teste), n=7 e reports=8 = o "5 failed ... 3 errors" do resumo, com xdist (-n 2) e sem (-n 0); sem falhas → n=0 reports=0 · (2) o script, 3 noites com a saída real: a 1ª grava os 7
#   ids inteiros; a 2ª (um irmão corrigido) diz 0 novas e 1 corrigida; a 3ª (o irmão volta a falhar, o outro continua falhando) lista SÓ o irmão como NOVO · (1b) o relógio no id
#   (ga-2hd02v.5.7): cada worker do xdist ganha um segundo (e uma fração) DIFERENTE, então um id com relógio que o plugin não normaliza derruba a coleta com "Different tests were collected"
#   (o que parou a suíte inteira do WA em 02/11); os 5 formatos (`T` e espaço, com e sem fração, e fração com vírgula) têm de passar com o id `test_clock[<TS>]`.
# CONTROLES NEGATIVOS: o mesmo cenário de 3 noites contra o script com o corte antigo (id lido da linha humana, cortado no 1º " - ", sem conferir `n`) TEM de ser reprovado; e o plugin sem
#   os erros (só "failed") TEM de ser reprovado pela conferência contra o resumo; (1b) o plugin sem o espaço TEM de ser reprovado no formato com espaço, e o plugin sem a fração no formato com
#   fração; o mutante neutro (só um comentário) TEM de passar, senão "reprovado" não prova nada.
# REQUISITO: um python com pytest e pytest-xdist (GTN_PYTHON; padrão o venv do WA). Sem ele: sai 3 ("NÃO RODOU"), nunca 0: um teste que não rodou não é um teste que passou.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PY=${GTN_PYTHON:-/Users/athos/gt/whatsapp_automation/venv/bin/python}
"$PY" -c 'import pytest, xdist' 2>/dev/null || { echo "SELFTEST NÃO RODOU: $PY não tem pytest + pytest-xdist (defina GTN_PYTHON)"; exit 3; }
T=$(mktemp -d "${TMPDIR:-/tmp}/gtn-ids-selftest.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
n=0; fails=0
ck() { local l=$1; shift; n=$((n+1)); if "$@"; then echo "ok   $l"; else echo "FAIL $l"; fails=$((fails+1)); fi; }
has() { grep -q -E -- "$2" "$1"; }
hasnt() { ! grep -q -E -- "$2" "$1"; }

# ---- o projeto de teste (os formatos de id e de falha que importam)
P="$T/proj"; mkdir -p "$P/tests"
dash() { # <expr python do que passa> — reescreve o parametrize
  cat > "$P/tests/test_dash.py" <<EOF
import pytest


@pytest.mark.parametrize("v", ["a - b", "a - c", "ok - d", "não - sim"])
def test_dash(v):
    assert $1
EOF
}
dash 'v.startswith("ok")'
cat > "$P/tests/test_misc.py" <<'EOF'
import pytest


@pytest.fixture
def boom_setup():
    raise RuntimeError("setup boom")


@pytest.fixture
def boom_teardown():
    yield
    raise RuntimeError("teardown boom")


def test_plain_fail():
    assert 1 == 2


def test_pass():
    pass


def test_setup_error(boom_setup):
    pass


def test_call_fail_and_teardown_error(boom_teardown):
    assert False


@pytest.mark.xfail
def test_xfail():
    assert False


@pytest.mark.xfail
def test_xpass():
    pass


@pytest.mark.skip
def test_skip():
    pass
EOF
printf 'import modulo_que_nao_existe_xyz\n\n\ndef test_never():\n    pass\n' > "$P/tests/test_collect_err.py"
git init -q -b main "$P" && git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t commit -qm m && git -C "$P" update-ref refs/remotes/origin/main HEAD
mkdir -p "$T/plug" && cp "$HERE/gtn_stable_ids.py" "$T/plug/"
EXPECT="$T/expect"
printf '%s\n' 'tests/test_collect_err.py' 'tests/test_dash.py::test_dash[a - b]' 'tests/test_dash.py::test_dash[a - c]' 'tests/test_dash.py::test_dash[n\xe3o - sim]' \
  'tests/test_misc.py::test_call_fail_and_teardown_error' 'tests/test_misc.py::test_plain_fail' 'tests/test_misc.py::test_setup_error' | LC_ALL=C sort -u > "$EXPECT"
runpy() { # plugin-dir saída args... — pytest de verdade com o plugin
  local plug=$1 out=$2; shift 2; ( cd "$P" && PYTHONPATH="$plug" PYTHONHASHSEED=0 "$PY" -m pytest -p no:cacheprovider -p gtn_stable_ids tests/ -q -rfE --tb=line --continue-on-collection-errors "$@" ) > "$out" 2>&1; }
ids_of() { sed -n 's/^GTN-FAIL: //p' "$1" | jq -r . | LC_ALL=C sort -u; }
sumnum() { # saída categoria → o número do resumo ("5 failed", "3 errors"), 0 se a categoria não aparece
  local l; l=$(grep -E '^[0-9]+ [a-z]+.* in [0-9.]+s' "$1" | tail -n 1); printf '%s' "$l" | sed -n -E "s/(^|.*[^0-9])([0-9]+) $2.*/\\2/p" | head -n 1 | sed 's/^$/0/'; }

# ---- (1) o plugin
for mode in "-n 2" "-n 0"; do
  o="$T/out-${mode// /}"; runpy "$T/plug" "$o" $mode
  ck "plugin ($mode): os 7 ids distintos, inteiros e decodificados" cmp -s <(ids_of "$o") "$EXPECT"
  ck "plugin ($mode): uma só linha GTN-FAILED" test "$(grep -c '^GTN-FAILED: ' "$o")" = 1
  ck "plugin ($mode): n=7" has "$o" '^GTN-FAILED: n=7 reports='
  F=$(sumnum "$o" failed); E=$(sumnum "$o" 'errors?')
  ck "plugin ($mode): reports = failed + error do resumo do pytest ($F + $E)" has "$o" "^GTN-FAILED: n=7 reports=$((F + E))\$"
  ck "plugin ($mode): o resumo é o esperado (5 falhas, 3 erros)" test "$F+$E" = "5+3"
done
cp -R "$P" "$T/proj-ok"; cat > "$T/proj-ok/tests/test_dash.py" <<'EOF'
def test_ok():
    pass
EOF
find "$T/proj-ok/tests" -name 'test_misc.py' -delete; find "$T/proj-ok/tests" -name 'test_collect_err.py' -delete
( cd "$T/proj-ok" && PYTHONPATH="$T/plug" "$PY" -m pytest -p no:cacheprovider -p gtn_stable_ids tests/ -q -n 2 ) > "$T/out-ok" 2>&1
ck "plugin: sem falhas emite n=0 reports=0 (vazio é dito, não omitido)" has "$T/out-ok" '^GTN-FAILED: n=0 reports=0$'; ck "plugin: sem falhas não emite GTN-FAIL" hasnt "$T/out-ok" '^GTN-FAIL: '

# ---- controle negativo do plugin: sem os erros (só `failed`) o `reports` NÃO bate com o resumo, e a conferência do script pega
mkdir -p "$T/plug-mut"; sed 's/for key in ("failed", "error")/for key in ("failed",)/' "$HERE/gtn_stable_ids.py" > "$T/plug-mut/gtn_stable_ids.py"
ck "controle: o mutante do plugin (sem os erros) difere do original" test -n "$(diff "$HERE/gtn_stable_ids.py" "$T/plug-mut/gtn_stable_ids.py")"
runpy "$T/plug-mut" "$T/out-pm" -n 2
F=$(sumnum "$T/out-pm" failed); E=$(sumnum "$T/out-pm" 'errors?')
ck "controle: o plugin sem os erros NÃO fecha com o resumo (é o que o script reprova)" hasnt "$T/out-pm" "^GTN-FAILED: n=7 reports=$((F + E))\$"

# ---- (1b) o relógio no id (ga-2hd02v.5.7): o worker gw0 vê :10, o gw1 vê :11 (e a fração acompanha), então o id só fecha entre os workers se o plugin o normalizar
clockproj() { # <nome> <relógio com %(s)02d (segundos) e %(f)06d (fração)> — projeto de 1 teste cujo id é o relógio DESTE worker
  local d="$T/clock-$1"; mkdir -p "$d/tests"
  cat > "$d/tests/test_clock.py" <<EOF
import os

import pytest

_W = int(os.environ.get("PYTEST_XDIST_WORKER", "gw0")[2:])  # gw0, gw1: o "relógio" de cada worker difere de propósito
_R = {"s": 10 + _W, "f": 123456 + _W}


@pytest.mark.parametrize("v", ["$2" % _R])
def test_clock(v):
    pass
EOF
}
runclock() { # <nome> <dir do plugin> <saída> — pytest de verdade, 2 workers, com o plugin
  ( cd "$T/clock-$1" && PYTHONPATH="$2" PYTHONHASHSEED=0 "$PY" -m pytest -p no:cacheprovider -p gtn_stable_ids tests/ -v -n 2 ) > "$3" 2>&1; }
clockok() { # <saída> — fechou: 1 passou, id normalizado, nada de "Different tests", e nenhum relógio cru sobrou no id
  has "$1" '1 passed' && has "$1" 'test_clock\[<TS>\]' && hasnt "$1" 'Different tests were collected' && hasnt "$1" 'test_clock\[[0-9]{4}-'; }
clockdies() { # <saída> — a coleta divergiu entre os workers (o sintoma de 02/11)
  has "$1" 'Different tests were collected'; }
clockproj tmais   '2026-12-03T03:39:%(s)02d'
clockproj espaco  '2026-12-03 03:39:%(s)02d'
clockproj tfrac   '2026-12-03T03:39:%(s)02d.%(f)06d'
clockproj espfrac '2026-12-03 03:39:%(s)02d.%(f)06d'
clockproj virgula '2026-12-03 03:39:%(s)02d,%(f)03d'
for f in tmais espaco tfrac espfrac virgula; do
  runclock "$f" "$T/plug" "$T/out-clock-$f"
  ck "relógio ($f): os 2 workers fecham a coleta e o id vira test_clock[<TS>]" clockok "$T/out-clock-$f"
done
cpl=$(cat "$HERE/gtn_stable_ids.py"; echo x); cpl=${cpl%x}
sp_old='[T ]'; sp_new='T'; fr_old='(?:[.,]\d+)?'; fr_new=''
mkdir -p "$T/plug-nosp" "$T/plug-nofr" "$T/plug-neutral"
printf '%s' "${cpl/"$sp_old"/"$sp_new"}" > "$T/plug-nosp/gtn_stable_ids.py"
printf '%s' "${cpl/"$fr_old"/"$fr_new"}" > "$T/plug-nofr/gtn_stable_ids.py"
printf '%s' "$cpl" | sed '2i\
# comentario neutro' > "$T/plug-neutral/gtn_stable_ids.py"
ck "controle: o plugin sem o espaço difere do original" test -n "$(diff "$HERE/gtn_stable_ids.py" "$T/plug-nosp/gtn_stable_ids.py")"
ck "controle: o plugin sem a fração difere do original" test -n "$(diff "$HERE/gtn_stable_ids.py" "$T/plug-nofr/gtn_stable_ids.py")"
runclock espfrac "$T/plug-neutral" "$T/out-clock-neutral"
ck "controle: o mutante neutro (só um comentário) PASSA o formato espaço + fração (o mutante é executável aqui)" clockok "$T/out-clock-neutral"
runclock espaco "$T/plug-nosp" "$T/out-clock-nosp"
ck "controle: sem o espaço, o formato com espaço é REPROVADO (a coleta diverge entre os workers)" clockdies "$T/out-clock-nosp"
runclock tfrac "$T/plug-nofr" "$T/out-clock-nofr"
ck "controle: sem a fração, o formato com fração é REPROVADO (a coleta diverge entre os workers)" clockdies "$T/out-clock-nofr"
runclock tmais "$T/plug-nosp" "$T/out-clock-nosp-t"
ck "controle: sem o espaço, o formato com T continua passando (o mutante só quebra o que deve)" clockok "$T/out-clock-nosp-t"

# ---- (2) o script real, 3 noites, com a saída real
CITY="$T/city"; mkdir -p "$CITY/.gc/logs" "$CITY/.gc/run"
cat > "$T/run-real.sh" <<'EOF'
#!/usr/bin/env bash
# faz o papel do mbp-run.sh: roda o pytest DE VERDADE no --dir com os argumentos da noite (-n 14 vira -n 2) e imprime as linhas de prova do canário
d=""; while [ $# -gt 0 ]; do case "$1" in --dir) d=$2;; --) shift; break;; esac; shift; done
echo "GTN-ISO: isolado (sonda barrou 5 tentativas)"
cd "$d" || exit 97
a=("$@"); for i in "${!a[@]}"; do [ "${a[$i]}" = 14 ] && a[$i]=2; done
PYTHONPATH="$PLUGIN_DIR" PYTHONHASHSEED=0 "$GTN_PY" -m pytest -p no:cacheprovider "${a[@]}"
rc=$?
echo "GTN-EGRESS: attempts=3"
exit $rc
EOF
printf '#!/usr/bin/env bash\necho MAIL-CALL >> "$T/mail.log"; printf "%%s\\n" "$*" >> "$T/mail.log"\n' > "$T/mail-stub.sh"
printf '#!/usr/bin/env bash\ncat > /dev/null; exit 0\n' > "$T/ssh-stub.sh"
chmod +x "$T/run-real.sh" "$T/mail-stub.sh" "$T/ssh-stub.sh"
export T GTN_PY="$PY" PLUGIN_DIR="$HERE"
commit() { git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1" >/dev/null && git -C "$P" update-ref refs/remotes/origin/main HEAD; }
night() { # script → roda uma noite inteira contra o projeto de teste (origin/main dele)
  MBP_CITY="$CITY" HZN_RUN="$T/run-real.sh" HZN_WA_REPO="$P" HZN_MAIL_CMD="$T/mail-stub.sh" HZN_SSH="$T/ssh-stub.sh" HZN_NODE_HOST=stub HZN_NO_FETCH=1 HZN_MIN_TOTAL=1 bash "$1" > "$T/night.out" 2>&1; }
LOGDIR="$CITY/.gc/logs/hetzner-nightly"; DAY=$(date +%Y-%m-%d); REPORT="$LOGDIR/$DAY.md"
reset_city() { find "$LOGDIR" -mindepth 1 -delete 2>/dev/null; : > "$CITY/.gc/logs/hetzner-nightly.jsonl"; find "$CITY/.gc/hetzner-nightly.lock" -mindepth 1 -delete 2>/dev/null; rmdir "$CITY/.gc/hetzner-nightly.lock" 2>/dev/null; }
scenario() { # script → 3 noites; devolve 0 se o relatório disse a verdade nas 3
  local s=$1 ok=0
  reset_city; dash 'v.startswith("ok")'; commit "noite 1"; night "$s"
  [ "$(jq -r . "$LOGDIR/last-complete.failed" | LC_ALL=C sort -u | cmp -s - "$EXPECT"; echo $?)" = 0 ] || { echo "   noite 1: a baseline não tem os 7 ids inteiros" >&2; ok=1; }
  has "$REPORT" 'primeira rodada completa' || { echo "   noite 1: sem o texto de primeira rodada" >&2; ok=1; }
  dash 'v.startswith("ok") or v == "a - c"'; commit "noite 2"; night "$s"
  has "$REPORT" '0 falhas NOVAS, 1 corrigidas' || { echo "   noite 2: esperava 0 novas e 1 corrigida (o a - c passou)" >&2; ok=1; }
  dash 'v.startswith("ok")'; commit "noite 3"; night "$s"
  has "$REPORT" '1 falhas NOVAS, 0 corrigidas' || { echo "   noite 3: esperava 1 NOVA (o irmão a - c voltou a falhar)" >&2; ok=1; }
  has "$REPORT" '^  - tests/test_dash.py::test_dash\[a - c\]$' || { echo "   noite 3: o irmão a - c não está na lista de novas, inteiro" >&2; ok=1; }
  hasnt "$REPORT" '^  - tests/test_dash.py::test_dash\[a - b\]$' || { echo "   noite 3: o a - b já falhava e NÃO é novo" >&2; ok=1; }
  return $ok; }
ck "script: 3 noites com o pytest de verdade (ids com ' - ' inteiros, irmão novo listado, o que já falhava não)" scenario "$HERE/hetzner-nightly-tests.sh"

# ---- controles do script: o mutante com o corte antigo (id da linha humana, cortado no 1º " - ", sem conferir n) TEM de ser reprovado pelo cenário; o neutro (só um comentário) TEM de passar
# (sem o neutro, "reprovado" não prova nada: um mutante que não roda por faltar um arquivo irmão também é reprovado)
neg() { ! "$@"; }
cp "$HERE/hetzner-iso-run.sh" "$HERE/gtn_stable_ids.py" "$T/"
rd() { local c; c=$(cat "$1"; echo x); printf '%s' "${c%x}"; }
c=$(rd "$HERE/hetzner-nightly-tests.sh")
old1="LC_ALL=C sed -n 's/^GTN-FAIL: //p' \"\$OUT\" 2>/dev/null |"
new1="LC_ALL=C sed -n -E 's/^(FAILED|ERROR) (.*)\$/\\2/p' \"\$OUT\" 2>/dev/null | sed -E 's/ - .*\$//' | jq -R . |"
old2='elif [ "$NIDS" -ne "$SN" ]; then'
case $c in *"$old1"*) ok1=1;; *) ok1=0;; esac; case $c in *"$old2"*) ok2=1;; *) ok2=0;; esac
ck "controle: os dois trechos a trocar existem no script (senão o mutante é o original)" test "$ok1$ok2" = 11
m=${c/"$old1"/"$new1"}; m=${m/"$old2"/'elif false; then'}
printf '%s' "$m" > "$T/m-corte-antigo.sh"
printf '%s' "$c" | sed '2i\
# comentario neutro' > "$T/m-neutro.sh"
ck "controle: o mutante com o corte antigo difere do original" test -n "$(diff "$HERE/hetzner-nightly-tests.sh" "$T/m-corte-antigo.sh")"
ck "controle: o mutante neutro (só um comentário) PASSA o cenário de 3 noites (o mutante é executável neste diretório)" scenario "$T/m-neutro.sh"
ck "controle: o corte antigo é REPROVADO pelo cenário de 3 noites" neg scenario "$T/m-corte-antigo.sh"
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
