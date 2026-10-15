#!/usr/bin/env bash
# pytest-shim.selftest.sh — hermético: o python3/pytest "de verdade", o gate e o mbp-run são stubs; nada toca o MBP, o live nem o city real.
#
# Contents
#   Casos · Controles negativos
#
# CASOS (A, com o gate stub): `pytest` e `python3 -m pytest` (também -u, -W x, -mpytest, python) vão ao gate com os argumentos do PYTEST, e o gate recebe a chave, o log e
#   o prefixo do atalho · python3 que NÃO é `-m pytest` (script, -c, -m json.tool, `-m pytest` que é argumento de um script, stdin) roda o python de verdade com os mesmos
#   argumentos e o mesmo stdin, sem log · rc do gate e rc do python de verdade passam intactos · chave mbp-offload.on ausente, pausa, pytest-shim.off, GC_PYTEST_SHIM=off,
#   execução aninhada, nenhum alvo, gate ausente → roda o comando de hoje (e o motivo vai ao log, menos nos dois silenciosos) · PATH com o diretório do atalho duas vezes ou por
#   symlink não vira recursão · o python que roda AQUI no stub `pytest` é o do shebang.
#   (B, com o gate DE VERDADE e o mbp-run stub — os três controles do bead): chave off → local, e o MBP nem é chamado · MBP rc 98 → local, rc daqui · teste que FALHA no MBP →
#   rc != 0 no worker (confirmado aqui) · verde do MBP → ran=mbp, nada roda aqui, com a nota do MBP e o log do atalho (e o log do gate intocado).
#   Controles negativos M1-M4: sem a chave off, rc engolido, python3 que não é pytest também desviado, sem a guarda de execução aninhada — cada mutante tem de ser pego.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIMDIR="$HERE/pytest-shim"
GATE_REAL="$HERE/gate-pytest.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/pytest-shim-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/real" "$T/city/.gc/logs" "$T/wt/tests" "$T/whatsapp_automation/tests" "$T/mut"
: > "$T/wt/tests/test_a.py"; : > "$T/whatsapp_automation/tests/test_a.py"

# ---- stubs do que o PATH tem DEPOIS do atalho --------------------------------------------------------------------------------------------
cat > "$T/real/python3" <<'EOF'
#!/bin/sh
{ echo "PY_CALL $(basename "$0")"; for a in "$@"; do echo "  arg:$a"; done; [ "${STUB_PY_STDIN:-}" = 1 ] && echo "  stdin:$(cat)"; } >> "$STUB_LOG"
exit "${STUB_PY_RC:-0}"
EOF
cp "$T/real/python3" "$T/real/python"
cp "$T/real/python3" "$T/real/python3.11"   # interpretador do shebang do pytest de um dos casos (o shim só aceita python*): o log diz qual python rodou
cat > "$T/real/pytest" <<'EOF'
#!/bin/sh
{ echo "PYTEST_CALL"; for a in "$@"; do echo "  arg:$a"; done; } >> "$STUB_LOG"
exit "${STUB_PYTEST_RC:-0}"
EOF
chmod +x "$T/real/python3" "$T/real/python" "$T/real/python3.11" "$T/real/pytest"
# gate stub (casos A): registra o que o atalho entregou
cat > "$T/gate-stub.sh" <<'EOF'
#!/bin/sh
{ echo "GATE_CALL"; for a in "$@"; do echo "  arg:$a"; done
  echo "  env:PY=${GATE_PYTEST_PY:-}"; echo "  env:LOG=${GATE_PYTEST_LOG:-}"; echo "  env:OFF=${GATE_PYTEST_OFF_FILE:-}"; echo "  env:TAG=${GATE_PYTEST_TAG:-}"
  echo "  env:SHIMPY=${PYTEST_SHIM_PY:-}"; echo "  env:ACTIVE=${GC_PYTEST_SHIM_ACTIVE:-}"; echo "  env:HINT=${GATE_PYTEST_LOCAL_HINT:-}"; echo "  cwd=$(pwd -P)"; } >> "$STUB_LOG"
exit "${STUB_GATE_RC:-0}"
EOF
# mbp-run stub (casos B): o MBP de mentira
cat > "$T/mbp-stub" <<'EOF'
#!/usr/bin/env bash
{ echo "MBP_CALL"; for a in "$@"; do echo "  arg:$a"; done; } >> "$STUB_LOG"
[ -n "${STUB_MBP_OUT:-}" ] && cat "$STUB_MBP_OUT"
exit "${STUB_MBP_RC:-0}"
EOF
chmod +x "$T/gate-stub.sh" "$T/mbp-stub"
: > "$T/force-local.txt"

export PYTEST_SHIM_CITY="$T/city" STUB_LOG="$T/stub.log" GC_SESSION_NAME=selftest
export GATE_PYTEST_MBP_RUN="$T/mbp-stub" GATE_PYTEST_FORCE_LOCAL_LIST="$T/force-local.txt" GATE_PYTEST_CITY="$T/city"
unset GC_PYTEST_SHIM GC_PYTEST_SHIM_ACTIVE GATE_PYTEST_PY GATE_PYTEST_LOG GATE_PYTEST_OFF_FILE GATE_PYTEST_TAG GATE_PYTEST_LOCAL_HINT PYTEST_SHIM_GATE
LOGF="$T/city/.gc/logs/pytest-shim.jsonl"; GLOG="$T/city/.gc/logs/gate-pytest.jsonl"
KEY="$T/city/.gc/mbp-offload.on"
fails=0; n=0
NODEKEY="$T/city/.gc/hetzner-node.on"
reset() { : > "$STUB_LOG"; rm -f "$LOGF" "$GLOG" "$T/city/.gc/mbp-offload.pause" "$T/city/.gc/pytest-shim.off" "$NODEKEY"; touch "$KEY"
  unset STUB_GATE_RC STUB_PY_RC STUB_PYTEST_RC STUB_PY_STDIN STUB_MBP_RC STUB_MBP_OUT GC_PYTEST_SHIM GC_PYTEST_SHIM_ACTIVE; unset PYTEST_SHIM_GATE; }
expect() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; else echo "FAIL $1: esperado rc=$2, veio $3"; fails=$((fails+1)); fi; }
has()   { n=$((n+1)); if grep -q -E -e "$3" "$2" 2>/dev/null; then echo "ok   $1"; else echo "FAIL $1: '$3' ausente em $2"; fails=$((fails+1)); fi; }
hasnt() { n=$((n+1)); if grep -q -E -e "$3" "$2" 2>/dev/null; then echo "FAIL $1: '$3' presente em $2"; fails=$((fails+1)); else echo "ok   $1"; fi; }
count() { n=$((n+1)); c=$(grep -c -E -e "$3" "$2" 2>/dev/null); if [ "$c" = "$4" ]; then echo "ok   $1 ($c)"; else echo "FAIL $1: esperado $4 de '$3', vieram $c"; fails=$((fails+1)); fi; }
# run_in <dir-do-atalho> <cwd> <comando> [args]: o PATH é atalho, depois os stubs "de verdade", depois o sistema (git, bash, grep...).
run_in() { local sd=$1 cwd=$2; shift 2; ( cd "$cwd" && PATH="$sd/bin:$T/real:/usr/bin:/bin" "$@" >"$T/out" 2>"$T/err" ; echo $? ); }
run() { run_in "$SHIMDIR" "$T/wt" "$@"; }
use_gate_stub() { export PYTEST_SHIM_GATE="$T/gate-stub.sh"; }

# =============================== A. decisões, com o gate stub ===============================
# A1 `pytest` e `python3 -m pytest` vão ao gate com os argumentos do pytest e nada além
reset; use_gate_stub; rc=$(run pytest tests/test_a.py -q); expect "A1 pytest solto → gate" 0 "$rc"
has "A1 gate recebeu '-- tests/test_a.py -q'" "$STUB_LOG" 'arg:--$'; has "A1 alvo entregue" "$STUB_LOG" 'arg:tests/test_a.py'; has "A1 flag entregue" "$STUB_LOG" 'arg:-q'
hasnt "A1 o pytest de verdade não rodou" "$STUB_LOG" 'PYTEST_CALL'
has "A1 execução aninhada protegida (GC_PYTEST_SHIM_ACTIVE=1 no gate)" "$STUB_LOG" 'env:ACTIVE=1'
has "A1 log do atalho, não o do gate" "$STUB_LOG" "env:LOG=$LOGF"; has "A1 chave do atalho, não a do gate" "$STUB_LOG" "env:OFF=$T/city/.gc/pytest-shim.off"
has "A1 prefixo das mensagens" "$STUB_LOG" 'env:TAG=pytest-shim'; has "A1 dica de rodar aqui ensina o bypass" "$STUB_LOG" 'env:HINT=GC_PYTEST_SHIM=off python3 -m pytest'
has "A1 o gate roda no cwd do worker" "$STUB_LOG" "cwd=.*/wt$"
reset; use_gate_stub; rc=$(run python3 -m pytest tests/test_a.py -x -q); expect "A2 python3 -m pytest → gate" 0 "$rc"
has "A2 alvo entregue" "$STUB_LOG" 'arg:tests/test_a.py'; has "A2 flag entregue" "$STUB_LOG" 'arg:-x'; hasnt "A2 '-m' não vaza para o gate" "$STUB_LOG" 'arg:-m$'; hasnt "A2 'pytest' (o módulo) não vaza para o gate" "$STUB_LOG" 'arg:pytest$'
hasnt "A2 o python de verdade não rodou" "$STUB_LOG" 'PY_CALL'
has "A2 o python que roda AQUI é o python3 de verdade" "$STUB_LOG" "env:PY=$T/real/python3"
# A3 outras grafias do mesmo comando
for form in "python3 -u -m pytest" "python3 -mpytest" "python3 -W ignore -m pytest" "python3 -X dev -u -m pytest"; do
  reset; use_gate_stub; rc=$(run $form tests/test_a.py -q); expect "A3 '$form' → gate" 0 "$rc"
  has "A3 '$form': gate chamado" "$STUB_LOG" 'GATE_CALL'; has "A3 '$form': alvo entregue" "$STUB_LOG" 'arg:tests/test_a.py'; hasnt "A3 '$form': nada de opção do python no gate" "$STUB_LOG" 'arg:(-u|-W|ignore|-X|dev|-mpytest)$'
done
reset; use_gate_stub; rc=$(run python -m pytest tests/test_a.py -q); expect "A3 'python -m pytest' → gate" 0 "$rc"; has "A3 python: o python daqui é o python de verdade" "$STUB_LOG" "env:PY=$T/real/python$"
# A4 python que NÃO é `-m pytest`: roda o python de verdade, mesmos argumentos, sem log, sem gate
for form in "python3 script.py" "python3 script.py one.py two.py three.py" "python3 -c print(1)" "python3 -m json.tool" "python3 script.py -m pytest tests/test_a.py" "python3 -m pytest_xdist tests/test_a.py" "python3 -u script.py" "python3 -m" "python3 -W"; do
  reset; use_gate_stub; rc=$(run $form); expect "A4 '$form' → python de verdade" 0 "$rc"
  has "A4 '$form': python de verdade chamado" "$STUB_LOG" 'PY_CALL'; hasnt "A4 '$form': gate não chamado" "$STUB_LOG" 'GATE_CALL'; hasnt "A4 '$form': nada no log do atalho" "$LOGF" 'shim-pass'
done
reset; use_gate_stub; run python3 script.py a "b c" -m pytest >/dev/null; has "A4 argumentos intactos (com espaço)" "$STUB_LOG" 'arg:b c'; has "A4 argumentos intactos (-m do script)" "$STUB_LOG" 'arg:-m'
reset; use_gate_stub; rc=$(echo 'print(1)' | STUB_PY_STDIN=1 run python3 -); expect "A4 stdin passa" 0 "$rc"; has "A4 stdin chegou ao python de verdade" "$STUB_LOG" 'stdin:print\(1\)'
# A5 rc passa intacto, nos dois sentidos
reset; use_gate_stub; rc=$(STUB_GATE_RC=7 run python3 -m pytest tests/test_a.py); expect "A5 rc do gate (7) passa" 7 "$rc"
reset; use_gate_stub; rc=$(STUB_PY_RC=3 run python3 script.py); expect "A5 rc do python de verdade (3) passa" 3 "$rc"
reset; rc=$(STUB_PYTEST_RC=5 run pytest --version); expect "A5 rc do pytest de verdade (5) passa quando não desvia" 5 "$rc"
# A6 quando NÃO intercepta
reset; use_gate_stub; rm -f "$KEY"; rc=$(STUB_PY_RC=2 run python3 -m pytest tests/test_a.py -q); expect "A6 mbp-offload.on ausente → comando de hoje (rc do python)" 2 "$rc"
hasnt "A6 chave off: gate não chamado" "$STUB_LOG" 'GATE_CALL'; has "A6 chave off: python de verdade com os MESMOS argumentos" "$STUB_LOG" 'arg:tests/test_a.py'; has "A6 chave off: o '-m pytest' continua" "$STUB_LOG" 'arg:pytest'
has "A6 chave off: motivo no log" "$LOGF" '"src":"shim-pass".*"ran":"local".*"detail":"offload-desligado"'; has "A6 chave off: a sessão vai no log" "$LOGF" '"session":"selftest"'; hasnt "A6 chave off: nenhuma saída a mais" "$T/out" 'pytest-shim'
reset; use_gate_stub; : > "$T/city/.gc/mbp-offload.pause"; rc=$(run pytest tests/test_a.py); expect "A6 pausa do Athos → comando de hoje" 0 "$rc"; hasnt "A6 pausa: gate não chamado" "$STUB_LOG" 'GATE_CALL'; has "A6 pausa: motivo" "$LOGF" 'offload-pausado'
# A6n o nó Linux (ga-zri39b) tem a bandeira dele: ligada, o atalho desvia ao gate MESMO com o MBP desligado ou pausado (o mbp-run.sh decide a cadeia)
reset; use_gate_stub; rm -f "$KEY"; touch "$NODEKEY"; rc=$(run pytest tests/test_a.py); expect "A6n nó ligado + mbp-offload.on ausente → vai ao gate" 0 "$rc"
has "A6n nó ligado, MBP desligado: gate chamado" "$STUB_LOG" 'GATE_CALL'; hasnt "A6n nó ligado: sem linha de passe no log" "$LOGF" 'offload-desligado'
reset; use_gate_stub; : > "$T/city/.gc/mbp-offload.pause"; touch "$NODEKEY"; rc=$(run pytest tests/test_a.py); expect "A6n nó ligado + MBP pausado → vai ao gate" 0 "$rc"
has "A6n nó ligado, MBP pausado: gate chamado" "$STUB_LOG" 'GATE_CALL'; hasnt "A6n a pausa do MBP não vale para o nó" "$LOGF" 'offload-pausado'
reset; use_gate_stub; rm -f "$KEY"; rc=$(run pytest tests/test_a.py); expect "A6n os dois desligados → comando de hoje" 0 "$rc"; hasnt "A6n os dois desligados: gate não chamado" "$STUB_LOG" 'GATE_CALL'; has "A6n os dois desligados: motivo" "$LOGF" 'offload-desligado'
reset; use_gate_stub; touch "$T/city/.gc/pytest-shim.off"; rc=$(run pytest tests/test_a.py); expect "A6 chave pytest-shim.off → comando de hoje" 0 "$rc"; hasnt "A6 shim.off: gate não chamado" "$STUB_LOG" 'GATE_CALL'; has "A6 shim.off: motivo" "$LOGF" 'chave-pytest-shim-off'
reset; use_gate_stub; rc=$(GC_PYTEST_SHIM=off run pytest tests/test_a.py); expect "A6 GC_PYTEST_SHIM=off → comando de hoje" 0 "$rc"; hasnt "A6 bypass: gate não chamado" "$STUB_LOG" 'GATE_CALL'; hasnt "A6 bypass: sem linha no log" "$LOGF" 'shim-pass'
reset; use_gate_stub; rc=$(GC_PYTEST_SHIM_ACTIVE=1 run python3 -m pytest tests/test_a.py); expect "A6 execução aninhada → comando de hoje" 0 "$rc"; hasnt "A6 aninhada: gate não chamado" "$STUB_LOG" 'GATE_CALL'; hasnt "A6 aninhada: sem linha no log" "$LOGF" 'shim-pass'
for form in "pytest" "pytest --version" "pytest -h" "python3 -m pytest" "python3 -m pytest -q --co"; do
  reset; use_gate_stub; rc=$(run $form); expect "A6 '$form' (nenhum alvo) → comando de hoje" 0 "$rc"; hasnt "A6 '$form': gate não chamado" "$STUB_LOG" 'GATE_CALL'; has "A6 '$form': motivo" "$LOGF" '"detail":"sem-alvo"'
done
reset; export PYTEST_SHIM_GATE="$T/nao-existe.sh"; rc=$(STUB_PY_RC=4 run python3 -m pytest tests/test_a.py); expect "A6 gate ausente → comando de hoje (rc do python)" 4 "$rc"
has "A6 gate ausente: AVISO dito no stderr" "$T/err" 'AVISO'; has "A6 gate ausente: motivo" "$LOGF" 'gate-pytest-ilegivel'; has "A6 gate ausente: python de verdade com os argumentos de hoje" "$STUB_LOG" 'arg:tests/test_a.py'
# A7 o diretório do atalho aparecendo duas vezes ou por symlink no PATH não vira recursão
reset; use_gate_stub; ln -s "$SHIMDIR/bin" "$T/linkbin"
rc=$( cd "$T/wt" && PATH="$SHIMDIR/bin:$T/linkbin:$SHIMDIR/bin:$T/real:/usr/bin:/bin" python3 script.py >"$T/out" 2>"$T/err"; echo $? ); expect "A7 PATH com o atalho 3x (uma por symlink) → acha o python de verdade" 0 "$rc"; count "A7 uma chamada ao python de verdade" "$STUB_LOG" 'PY_CALL' 1
# A8 o stub `pytest` roda AQUI com o python do shebang do pytest de verdade — e só se o shebang for mesmo um python
shebang_case() { # <rotulo> <shebang> <python esperado em GATE_PYTEST_PY>
  reset; use_gate_stub; { echo "$2"; echo "# stub"; } > "$T/real/pytest.sheb"; mv "$T/real/pytest" "$T/real/pytest.orig"; mv "$T/real/pytest.sheb" "$T/real/pytest"; chmod +x "$T/real/pytest"
  rc=$(run pytest tests/test_a.py); expect "A8 $1 → gate" 0 "$rc"; has "A8 $1: o python daqui" "$STUB_LOG" "env:PY=$3"
  mv "$T/real/pytest.orig" "$T/real/pytest"; }
shebang_case "shebang com caminho de python" "#!$T/real/python3.11" "$T/real/python3.11"
shebang_case "shebang '/usr/bin/env python3'" "#!/usr/bin/env python3" "$T/real/python3"
shebang_case "shebang '/usr/bin/env -S python3 -u'" "#!/usr/bin/env -S python3 -u" "$T/real/python3"
shebang_case "shebang '#!/bin/sh' (não é python) cai no python3 do PATH" "#!/bin/sh" "$T/real/python3"
shebang_case "shebang de python que não abre cai no python3 do PATH" "#!$T/real/python9.99" "$T/real/python3"
shebang_case "arquivo sem shebang cai no python3 do PATH" "# sem shebang" "$T/real/python3"

# =============================== A9. PYTEST_SHIM_PY (ga-7q35xn): o python que o worker DIGITOU, em TODO caminho local ===============================
# O hook PreToolUse reescreve `venv/bin/python -m pytest ...` para `env PYTEST_SHIM_PY=<esse python> <atalho>/bin/python3 -m pytest ...`. Se o atalho deixar passar (chave off,
# bypass, aninhado, sem alvo) ou mandar o gate rodar aqui, quem roda TEM de ser o python do worker (as dependências do rig estão nele): cair no python3 do PATH muda o teste.
mkdir -p "$T/wt/venv/bin"
cat > "$T/wt/venv/bin/python" <<'EOF'
#!/bin/sh
{ echo "VENV_CALL argv0=$0"; for a in "$@"; do echo "  arg:$a"; done; echo "  env:SHIMPY=${PYTEST_SHIM_PY:-}"; } >> "$STUB_LOG"
exit "${STUB_PY_RC:-0}"
EOF
chmod +x "$T/wt/venv/bin/python"; VPY="$T/wt/venv/bin/python"
reset; rm -f "$KEY"; rc=$(STUB_PY_RC=2 PYTEST_SHIM_PY="$VPY" run python3 -m pytest tests/test_a.py -q); expect "A9 chave off: roda o python DO WORKER (rc é o dele)" 2 "$rc"
has "A9 chave off: o python do worker foi chamado" "$STUB_LOG" 'VENV_CALL'; hasnt "A9 chave off: o python3 do PATH NÃO foi chamado" "$STUB_LOG" 'PY_CALL'
has "A9 chave off: argumentos de hoje (-m pytest + alvo)" "$STUB_LOG" 'arg:tests/test_a.py'; has "A9 chave off: o '-m pytest' continua" "$STUB_LOG" 'arg:pytest'
hasnt "A9 PYTEST_SHIM_PY não vaza para o python do worker (nem para um python3 aninhado dele)" "$STUB_LOG" 'env:SHIMPY=.+'
reset; rc=$(PYTEST_SHIM_PY=venv/bin/python run python3 -m pytest tests/test_a.py -q); expect "A9 caminho relativo" 0 "$rc"; has "A9 relativo vira ABSOLUTO contra o cwd (o gate pode mudar de diretório)" "$STUB_LOG" 'argv0=/.*/wt/venv/bin/python$'; hasnt "A9 relativo: não executa o caminho relativo cru" "$STUB_LOG" 'argv0=venv'
reset; use_gate_stub; rc=$(PYTEST_SHIM_PY="$VPY" run python3 -m pytest tests/test_a.py -q); expect "A9 gate: desvia normalmente" 0 "$rc"
has "A9 gate: o python que roda AQUI é o do worker" "$STUB_LOG" "env:PY=$VPY"; hasnt "A9 gate: não é o python3 do PATH" "$STUB_LOG" "env:PY=$T/real/python3"; hasnt "A9 gate: PYTEST_SHIM_PY não vaza" "$STUB_LOG" 'env:SHIMPY=.+'
reset; use_gate_stub; rc=$(PYTEST_SHIM_PY="$VPY" GC_PYTEST_SHIM=off run python3 -m pytest tests/test_a.py); expect "A9 bypass GC_PYTEST_SHIM=off → python do worker" 0 "$rc"; has "A9 bypass: python do worker" "$STUB_LOG" 'VENV_CALL'; hasnt "A9 bypass: gate não chamado" "$STUB_LOG" 'GATE_CALL'; hasnt "A9 bypass: python3 do PATH não chamado" "$STUB_LOG" 'PY_CALL'
reset; use_gate_stub; rc=$(PYTEST_SHIM_PY="$VPY" GC_PYTEST_SHIM_ACTIVE=1 run python3 -m pytest tests/test_a.py); expect "A9 aninhado → python do worker" 0 "$rc"; has "A9 aninhado: python do worker" "$STUB_LOG" 'VENV_CALL'; hasnt "A9 aninhado: python3 do PATH não chamado" "$STUB_LOG" 'PY_CALL'
reset; use_gate_stub; rc=$(PYTEST_SHIM_PY="$VPY" run python3 -m pytest -q); expect "A9 sem alvo → python do worker" 0 "$rc"; has "A9 sem alvo: python do worker" "$STUB_LOG" 'VENV_CALL'; hasnt "A9 sem alvo: python3 do PATH não chamado" "$STUB_LOG" 'PY_CALL'
reset; use_gate_stub; rc=$(PYTEST_SHIM_PY="$T/wt/venv/bin/nao-existe" run python3 -m pytest tests/test_a.py); n=$((n+1)); if [ "$rc" != 0 ]; then echo "ok   A9 python do worker que não existe → erro (rc=$rc), não um pytest com outro python"; else echo "FAIL A9 python do worker inexistente saiu 0"; fails=$((fails+1)); fi
hasnt "A9 inexistente: NUNCA cai para o python3 do PATH" "$STUB_LOG" 'PY_CALL'; hasnt "A9 inexistente: o gate não roda com outro python" "$STUB_LOG" 'GATE_CALL.*'

# =============================== B. o gate DE VERDADE (mbp-run stub): os controles do bead ===============================
runb() { run_in "$SHIMDIR" "$T/whatsapp_automation" "$@"; }
( cd "$T/whatsapp_automation" && git init -q . 2>/dev/null )
# B1 verde no MBP: nada roda aqui, e o log é o do atalho
reset; printf '%s\n' "." "1 passed in 0.10s" > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out"
rc=$(runb python3 -m pytest tests/test_a.py -q); expect "B1 verde no MBP" 0 "$rc"
has "B1 MBP chamado com --repo wa" "$STUB_LOG" 'arg:wa'; hasnt "B1 nada rodou aqui" "$STUB_LOG" 'PY_CALL'
has "B1 linha final com o prefixo do atalho" "$T/out" 'pytest-shim: ran=mbp rc=0'; hasnt "B1 não usa o prefixo do gate" "$T/out" '^gate-pytest:'
has "B1 a nota do verde do MBP sai, com o bypass certo" "$T/out" 'nota: verde do MBP aceito.*GC_PYTEST_SHIM=off python3 -m pytest'
has "B1 log do atalho: ran=mbp" "$LOGF" '"ran":"mbp","rc":0'; hasnt "B1 o log do gate não foi tocado" "$GLOG" 'ran'
reset; printf '%s\n' "." "1 passed in 0.10s" > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out"; rc=$(runb pytest tests/test_a.py -q); expect "B1b pytest solto, verde no MBP" 0 "$rc"; has "B1b ran=mbp" "$T/out" 'pytest-shim: ran=mbp rc=0'
# B2 chave off: o comando de hoje, o MBP nem é chamado, e o rc daqui passa
reset; rm -f "$KEY"; rc=$(STUB_PY_RC=2 runb python3 -m pytest tests/test_a.py -q); expect "B2 chave off → local (rc do python daqui)" 2 "$rc"
hasnt "B2 o MBP nem foi chamado" "$STUB_LOG" 'MBP_CALL'; has "B2 python daqui com o comando de hoje" "$STUB_LOG" 'arg:tests/test_a.py'; hasnt "B2 nenhuma saída a mais" "$T/out" 'pytest-shim'
# B3 MBP indisponível (rc 98, e os outros 96..99): roda aqui, o rc é o daqui, nunca o 98
for code in 96 97 98 99; do
  reset; rc=$(STUB_MBP_RC=$code STUB_PY_RC=3 runb python3 -m pytest tests/test_a.py -q)
  expect "B3 MBP rc=$code → local e o rc é o daqui (3), nunca $code" 3 "$rc"
done
reset; rc=$(STUB_MBP_RC=98 STUB_PY_RC=0 runb python3 -m pytest tests/test_a.py -q); expect "B3 98 + local verde = 0" 0 "$rc"
has "B3 rodou aqui, o comando de hoje" "$STUB_LOG" 'PY_CALL'; has "B3 ran=local" "$T/out" 'pytest-shim: ran=local rc=0'; has "B3 o log tem o motivo mbp-rc=98" "$LOGF" 'mbp-rc=98'
# B4 teste que FALHA no MBP: o rc != 0 chega ao worker (a falha nunca some)
reset; printf '%s\n' "FAILED tests/test_a.py::test_x - AssertionError: boom" "1 failed in 0.20s" > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
rc=$(STUB_PY_RC=1 runb python3 -m pytest tests/test_a.py -q); expect "B4 falha no MBP e aqui → rc 1 no worker" 1 "$rc"; has "B4 o id que falhou foi reconferido aqui" "$STUB_LOG" 'arg:tests/test_a.py::test_x'; has "B4 log: local-confirmou" "$LOGF" 'local-confirmou'
reset; printf '%s\n' "FAILED tests/test_a.py::test_x - AssertionError: boom" "1 failed in 0.20s" > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out" STUB_MBP_RC=1
rc=$(STUB_PY_RC=1 runb pytest tests/test_a.py -q); expect "B4b pytest solto: falha no MBP e aqui → rc 1" 1 "$rc"
unset STUB_MBP_OUT STUB_MBP_RC
# B5 shell: o comando do worker continua funcionando dentro de um pipe/subshell (o idioma `| tail`)
reset; printf '%s\n' "." "1 passed in 0.10s" > "$T/mbp.out"; export STUB_MBP_OUT="$T/mbp.out"
out=$( cd "$T/whatsapp_automation" && PATH="$SHIMDIR/bin:$T/real:/usr/bin:/bin" python3 -m pytest tests/test_a.py -q 2>&1 | tail -n 2 ); n=$((n+1))
case "$out" in *"pytest-shim: ran=mbp"*) echo "ok   B5 '| tail' vê a linha final do atalho" ;; *) echo "FAIL B5: '| tail' não viu a linha final ($out)"; fails=$((fails+1)) ;; esac
unset STUB_MBP_OUT

# =============================== M. controles negativos: cada mutante do atalho tem de ser pego ===============================
mutant() { # <nome> <sed-expr>  → $T/mut/<nome>/ com o atalho alterado
  mkdir -p "$T/mut/$1"; cp -R "$SHIMDIR/bin" "$T/mut/$1/bin"; sed -e "$2" "$SHIMDIR/pytest-shim.sh" > "$T/mut/$1/pytest-shim.sh"; chmod +x "$T/mut/$1/pytest-shim.sh"
  cmp -s "$SHIMDIR/pytest-shim.sh" "$T/mut/$1/pytest-shim.sh" && { echo "FAIL mutante $1: o sed não mudou nada (o controle não controla)"; fails=$((fails+1)); n=$((n+1)); return 1; }
  return 0; }
caught() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: o mutante NÃO foi pego (esperava rc/valor '$2', veio '$3')"; fails=$((fails+1)); fi; }
# M1 sem a checagem da chave: com a chave off o gate seria chamado
mutant m1 '/offload-desligado/d' && {
  reset; use_gate_stub; rm -f "$KEY"; rc=$(run_in "$T/mut/m1" "$T/wt" pytest tests/test_a.py); c=$(grep -c GATE_CALL "$STUB_LOG")
  caught "M1 sem a chave off o gate é chamado (o caso A6 reprova o mutante)" 1 "$c"; }
# M1n sem a bandeira do nó no teste: com o MBP desligado e o nó ligado o gate NÃO seria chamado
mutant m1n 's# || \[ \$NODE_ON -eq 1 \] # #' && {
  reset; use_gate_stub; rm -f "$KEY"; touch "$NODEKEY"; rc=$(run_in "$T/mut/m1n" "$T/wt" pytest tests/test_a.py); c=$(grep -c GATE_CALL "$STUB_LOG")
  caught "M1n sem a bandeira do nó o gate não é chamado (o caso A6n reprova o mutante)" 0 "$c"; }
# M1p a pausa do MBP passa a valer para o nó também: com o nó ligado e o MBP pausado o gate NÃO seria chamado
mutant m1p 's# \&\& \[ \$NODE_ON -eq 0 \] \&\& \[ -e "\$CITY/.gc/mbp-offload.pause" \]# \&\& [ -e "$CITY/.gc/mbp-offload.pause" ]#' && {
  reset; use_gate_stub; : > "$T/city/.gc/mbp-offload.pause"; touch "$NODEKEY"; rc=$(run_in "$T/mut/m1p" "$T/wt" pytest tests/test_a.py); c=$(grep -c GATE_CALL "$STUB_LOG")
  caught "M1p a pausa do MBP bloqueando o nó (o caso A6n reprova o mutante)" 0 "$c"; }
# M2 rc engolido: `exec` trocado por chamada seguida de exit 0
mutant m2 's#^exec /usr/bin/env bash "\$GATE" -- "\$@"#/usr/bin/env bash "$GATE" -- "$@"; exit 0#' && {
  reset; use_gate_stub; rc=$(STUB_GATE_RC=7 run_in "$T/mut/m2" "$T/wt" python3 -m pytest tests/test_a.py)
  caught "M2 rc engolido: o rc 7 do gate vira 0 (o caso A5 reprova o mutante)" 0 "$rc"; }
# M3 python3 que não é pytest também desviado
mutant m3 's#^py_pytest_skip() {#py_pytest_skip() { SKIP=2; return 0;#' && {
  reset; use_gate_stub; rc=$(run_in "$T/mut/m3" "$T/wt" python3 script.py one.py two.py three.py); c=$(grep -c GATE_CALL "$STUB_LOG")
  caught "M3 'python3 script.py a b c' desviado ao gate (o caso A4 reprova o mutante)" 1 "$c"; }
# M4 sem a guarda da execução aninhada: o gate não recebe GC_PYTEST_SHIM_ACTIVE
mutant m4 '/^export GC_PYTEST_SHIM_ACTIVE=1/d' && {
  reset; use_gate_stub; rc=$(run_in "$T/mut/m4" "$T/wt" python3 -m pytest tests/test_a.py); c=$(grep -c 'env:ACTIVE=1' "$STUB_LOG")
  caught "M4 sem a guarda aninhada o gate não vê GC_PYTEST_SHIM_ACTIVE (o caso A1 reprova o mutante)" 0 "$c"; }

# M5 o PYTEST_SHIM_PY é ignorado quando o atalho deixa passar: cai no python3 do PATH
mutant m5 's#^  \[ -n "\$VENV_PY" \] \&\& \[ "\$_rr_name" != pytest \] \&\& exec "\$VENV_PY" "\$@"#  :#' && {
  reset; use_gate_stub; rm -f "$KEY"; rc=$(PYTEST_SHIM_PY="$VPY" run_in "$T/mut/m5" "$T/wt" python3 -m pytest tests/test_a.py); c=$(grep -c VENV_CALL "$STUB_LOG")
  caught "M5 sem o python do worker no passe direto roda o python3 do PATH (o caso A9 'chave off' reprova o mutante)" 0 "$c"; }
# M6 a variável não é removida do ambiente: vaza para o python do worker e para python3 aninhados
mutant m6 's#^VENV_PY=\${PYTEST_SHIM_PY:-}; unset PYTEST_SHIM_PY#VENV_PY=${PYTEST_SHIM_PY:-}#' && {
  reset; rm -f "$KEY"; rc=$(PYTEST_SHIM_PY="$VPY" run_in "$T/mut/m6" "$T/wt" python3 -m pytest tests/test_a.py); c=$(grep -c 'env:SHIMPY=.' "$STUB_LOG")
  caught "M6 sem o unset a variável vaza para o filho (o caso A9 'não vaza' reprova o mutante)" 1 "$c"; }

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
