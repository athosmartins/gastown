#!/usr/bin/env bash
# venv-rewrite-hook.selftest.sh — hermético: o hook roda como o Claude Code o chama (JSON no stdin, JSON no stdout); city e log são temporários (ga-7q35xn).
#
# Contents
#   Casos · Controles negativos
#
# CASOS: A reescreve (relativo, absoluto, ./venv, .venv, venv3.11, depois de cd/&&/pipe/if/;, com timeout/nice/xargs/exec/env/VAR=x na frente, opções do python, -mpytest, duas
#   rodadas na mesma linha, heredoc ou $(…) ANTES de uma rodada de nível de topo) · B NÃO reescreve (texto entre aspas, mensagem de commit, grep, comentário, heredoc/$(…)/crase só
#   com texto, python3/pytest soltos, python do venv sem -m pytest, -c, PYTEST_SHIM_PY já presente, bypass GC_PYTEST_SHIM=off, redirecionamento antes do comando, aspas sem fechar,
#   ~ e $VAR no caminho) · C protocolo (só updatedInput, NUNCA permissionDecision; o tool_input inteiro volta; outra ferramenta, stdin vazio, lixo → sem saída, rc 0; atalho
#   ausente/sem bit de execução → sem saída; log: uma linha por comando, e falha de log não muda a resposta).
# CONTROLES M1-M5: cada mutante tem de ser pego (M1 emite permissionDecision, M2 ignora aspas, M3 usa VAR=x em vez de env, M4 não pula o corpo do heredoc, M5 lê heredoc dentro de $(…) por contagem de parênteses).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/pytest-shim/venv-rewrite-hook.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/venv-rewrite-hook-selftest.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
n=0; fails=0
mkdir -p "$T/city" "$T/mut/pytest-shim/bin" "$T/noshim"
export PYTEST_SHIM_CITY="$T/city" GC_SESSION_NAME=selftest
SHIM="$HERE/pytest-shim/bin/python3"
LOGF="$T/city/.gc/logs/pytest-venv-rewrite.jsonl"

ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "FAIL $1"; }
payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c,description:"d",timeout:5000}}'; }
# hook <py-do-hook> <comando>: stdout em $T/out, rc em $RC
hook() { RC=0; payload "$2" | python3 -I "$1" > "$T/out" 2>"$T/err" || RC=$?; }
newcmd() { jq -r '.hookSpecificOutput.updatedInput.command // empty' "$T/out" 2>/dev/null; }
rewrote() { # <rótulo> <comando> <esperado com @SHIM@ no lugar do caminho do atalho>
  local want="${3//@SHIM@/$SHIM}"; hook "$HOOK" "$2"; local got; got=$(newcmd)
  if [ "$RC" = 0 ] && [ "$got" = "$want" ]; then ok "A $1"; else bad "A $1
       esperado: $want
       veio:     $got (rc=$RC)"; fi; }
untouched() { # <rótulo> <comando>
  hook "$HOOK" "$2"
  if [ "$RC" = 0 ] && [ ! -s "$T/out" ]; then ok "B $1"; else bad "B $1 (rc=$RC, saída: $(head -c 200 "$T/out"))"; fi; }

# =============================== A. reescreve ===============================
rewrote "relativo"                    'venv/bin/python -m pytest tests/a.py -q'                    '/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest tests/a.py -q'
rewrote "absoluto"                    '/Users/x/gt/wa/venv/bin/python3 -m pytest tests/a.py'      '/usr/bin/env PYTEST_SHIM_PY=/Users/x/gt/wa/venv/bin/python3 @SHIM@ -m pytest tests/a.py'
rewrote "./venv e python3.11"         './venv/bin/python3.11 -m pytest t.py'                       '/usr/bin/env PYTEST_SHIM_PY=./venv/bin/python3.11 @SHIM@ -m pytest t.py'
rewrote ".venv"                       '.venv/bin/python -m pytest t.py'                            '/usr/bin/env PYTEST_SHIM_PY=.venv/bin/python @SHIM@ -m pytest t.py'
rewrote "venv312"                     'venv312/bin/python -m pytest t.py'                          '/usr/bin/env PYTEST_SHIM_PY=venv312/bin/python @SHIM@ -m pytest t.py'
rewrote "depois de cd &&, com pipe e 2>&1" 'cd rig && venv/bin/python -m pytest tests/ -x 2>&1 | tail -5' 'cd rig && /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest tests/ -x 2>&1 | tail -5'
rewrote "-mpytest"                    'venv/bin/python -mpytest t.py'                              '/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -mpytest t.py'
rewrote "opções do python antes"      'venv/bin/python -u -W ignore -X dev -m pytest t.py'         '/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -u -W ignore -X dev -m pytest t.py'
rewrote "VAR=x na frente"             'FOO=1 PYTHONPATH=. venv/bin/python -m pytest t.py'          'FOO=1 PYTHONPATH=. /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "timeout N na frente (por isso env e não VAR=x direto)" 'timeout 900 venv/bin/python -m pytest t.py' 'timeout 900 /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "timeout -k 5 900"            'timeout -k 5 900 venv/bin/python -m pytest t.py'            'timeout -k 5 900 /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "nice -n 5"                   'nice -n 5 venv/bin/python -m pytest t.py'                   'nice -n 5 /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "exec"                        'exec venv/bin/python -m pytest t.py'                        'exec /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "env FOO=1"                   'env FOO=1 venv/bin/python -m pytest t.py'                   'env FOO=1 /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "xargs timeout N"             'ls tests/*.py | xargs -n1 timeout 900 venv/bin/python -m pytest -q' 'ls tests/*.py | xargs -n1 timeout 900 /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest -q'
rewrote "if … then"                   'if venv/bin/python -m pytest t.py; then echo ok; fi'        'if /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py; then echo ok; fi'
rewrote "duas rodadas na linha"       'venv/bin/python -m pytest a.py; venv/bin/python -m pytest b.py' '/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest a.py; /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest b.py'
rewrote "uma rodada de topo e uma que só cita" "venv/bin/python -m pytest a.py && echo 'venv/bin/python -m pytest b.py'" "/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest a.py && echo 'venv/bin/python -m pytest b.py'"
rewrote "heredoc ANTES da rodada de topo (o corpo é pulado)" $'cat > /tmp/x.py <<\'EOF\'\nvenv/bin/python -m pytest corpo\nEOF\nvenv/bin/python -m pytest /tmp/x.py -q' $'cat > /tmp/x.py <<\'EOF\'\nvenv/bin/python -m pytest corpo\nEOF\n/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest /tmp/x.py -q'
rewrote "heredoc <<-"                 $'cat <<-EOT\n\tvenv/bin/python -m pytest corpo\n\tEOT\nvenv/bin/python -m pytest t.py' $'cat <<-EOT\n\tvenv/bin/python -m pytest corpo\n\tEOT\n/usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote '$(…) ANTES da rodada de topo (o interior é pulado)' 'cd $(git rev-parse --show-toplevel) && venv/bin/python -m pytest t.py' 'cd $(git rev-parse --show-toplevel) && /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py'
rewrote "(subshell)"                  '(cd rig && venv/bin/python -m pytest t.py)'                 '(cd rig && /usr/bin/env PYTEST_SHIM_PY=venv/bin/python @SHIM@ -m pytest t.py)'

# =============================== B. NÃO reescreve (o comando segue como veio) ===============================
untouched "texto entre aspas simples"            "echo 'venv/bin/python -m pytest t.py'"
untouched "texto entre aspas duplas"             'echo "venv/bin/python -m pytest t.py"'
untouched "; dentro de aspas não separa comando" "echo 'ok; venv/bin/python -m pytest t.py' done"
untouched "mensagem de commit"                   'git commit -m "run venv/bin/python -m pytest before pushing"'
untouched "grep do comando"                      "grep -n 'venv/bin/python -m pytest' docs/x.md"
untouched "comentário"                           '# venv/bin/python -m pytest t.py'
untouched "bash -c com o comando entre aspas"    "bash -c 'venv/bin/python -m pytest t.py'"
untouched "heredoc só com texto"                 $'cat <<EOF\nvenv/bin/python -m pytest t\nEOF'
untouched '$(…) só com a rodada dentro (a captura de saída não leva a linha do atalho)' 'x=$(venv/bin/python -m pytest t.py)'
untouched "crase só com a rodada dentro"         'echo `venv/bin/python -m pytest t.py`'
untouched "python3 solto (o PATH já cobre)"      'python3 -m pytest tests/x.py'
untouched "pytest solto (o PATH já cobre)"       'pytest tests/x.py'
untouched "python do venv sem -m pytest"         'venv/bin/python script.py --arg pytest'
untouched "python do venv -c"                    "venv/bin/python -c 'import pytest'"
untouched "-m de outro módulo"                   'venv/bin/python -m json.tool x.json'
untouched "pip do venv"                          'venv/bin/pip install pytest'
untouched "python que não é de venv"             '/usr/bin/python3.11 -m pytest t.py'
untouched "PYTEST_SHIM_PY já presente"           'PYTEST_SHIM_PY=venv/bin/python venv/bin/python -m pytest t.py'
untouched "worker pediu o bypass"                'GC_PYTEST_SHIM=off venv/bin/python -m pytest t.py'
untouched "bypass depois de env"                 'env GC_PYTEST_SHIM=off venv/bin/python -m pytest t.py'
untouched "redirecionamento antes do comando"    '>out venv/bin/python -m pytest t.py'
untouched "aspas sem fechar"                     "venv/bin/python -m pytest 'x"
untouched "heredoc sem fechar"                   $'cat <<EOF\nvenv/bin/python -m pytest t.py'
untouched '~ no caminho (o `env` não expande)'    '~/gt/wa/venv/bin/python3 -m pytest t.py'
untouched '$VAR no caminho'                      '$HOME/wa/venv/bin/python -m pytest t.py'
untouched "sem a palavra pytest"                 'venv/bin/python -m unittest'
untouched 'heredoc dentro de $(…) (um ")" desbalanceado no corpo fecharia a substituição cedo e o resto do corpo seria lido como comando de topo)' $'x=$(cat <<\'EOF\'\nfoo ) bar\nvenv/bin/python -m pytest corpo\nEOF\n)\nvenv/bin/python -m pytest t.py'

# =============================== C. protocolo ===============================
hook "$HOOK" 'cd rig && venv/bin/python -m pytest t.py'
jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' "$T/out" >/dev/null 2>&1 && ok "C hookEventName PreToolUse" || bad "C hookEventName PreToolUse"
jq -e '.hookSpecificOutput | has("permissionDecision") | not' "$T/out" >/dev/null 2>&1 && ok "C NUNCA permissionDecision (um allow aprovaria o comando composto inteiro, inclusive um rm -rf antes)" || bad "C permissionDecision presente"
jq -e '.hookSpecificOutput | keys == ["hookEventName","updatedInput"]' "$T/out" >/dev/null 2>&1 && ok "C só hookEventName + updatedInput" || bad "C chaves inesperadas na resposta"
jq -e '.hookSpecificOutput.updatedInput | (.description == "d" and .timeout == 5000)' "$T/out" >/dev/null 2>&1 && ok "C o tool_input INTEIRO volta (description e timeout preservados)" || bad "C tool_input incompleto"
RC=0; printf '' | python3 -I "$HOOK" > "$T/out" 2>"$T/err" || RC=$?; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C stdin vazio → sem saída, rc 0" || bad "C stdin vazio"
RC=0; echo 'não é json' | python3 -I "$HOOK" > "$T/out" 2>"$T/err" || RC=$?; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C lixo no stdin → sem saída, rc 0" || bad "C lixo no stdin"
RC=0; echo '[1,2]' | python3 -I "$HOOK" > "$T/out" 2>"$T/err" || RC=$?; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C JSON que não é objeto → sem saída, rc 0" || bad "C JSON que não é objeto"
RC=0; jq -n '{tool_name:"Read",tool_input:{command:"venv/bin/python -m pytest t.py"}}' | python3 -I "$HOOK" > "$T/out" 2>"$T/err" || RC=$?; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C outra ferramenta → sem saída" || bad "C outra ferramenta"
RC=0; jq -n '{tool_name:"Bash",tool_input:{command:5}}' | python3 -I "$HOOK" > "$T/out" 2>"$T/err" || RC=$?; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C command que não é texto → sem saída" || bad "C command que não é texto"
# atalho ausente / sem bit de execução: o hook copiado para uma pasta sem bin/python3, e uma com bin/python3 sem execução
mkdir -p "$T/noshim/pytest-shim/bin" "$T/noexec/pytest-shim/bin"; cp "$HOOK" "$T/noshim/pytest-shim/venv-rewrite-hook.py"; cp "$HOOK" "$T/noexec/pytest-shim/venv-rewrite-hook.py"; : > "$T/noexec/pytest-shim/bin/python3"; chmod 644 "$T/noexec/pytest-shim/bin/python3"
hook "$T/noshim/pytest-shim/venv-rewrite-hook.py" 'venv/bin/python -m pytest t.py'; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C atalho ausente → o comando passa como veio" || bad "C atalho ausente"
hook "$T/noexec/pytest-shim/venv-rewrite-hook.py" 'venv/bin/python -m pytest t.py'; [ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok "C atalho sem bit de execução → o comando passa como veio" || bad "C atalho sem execução"
# log
rm -f "$LOGF"; hook "$HOOK" 'venv/bin/python -m pytest a.py; venv/bin/python -m pytest b.py'
c=$(wc -l < "$LOGF" 2>/dev/null | tr -d ' '); [ "$c" = 1 ] && ok "C uma linha de log por COMANDO reescrito" || bad "C log: esperava 1 linha, vieram '$c'"
jq -e '.src == "venv-rewrite" and .n == 2 and .session == "selftest" and (.ts | test("Z$"))' "$LOGF" >/dev/null 2>&1 && ok "C a linha traz src, n (rodadas no comando), session e ts em UTC" || bad "C conteúdo da linha de log: $(cat "$LOGF" 2>/dev/null)"
rm -f "$LOGF"; hook "$HOOK" 'echo oi'; [ ! -e "$LOGF" ] && ok "C comando que não foi reescrito não grava log" || bad "C log gravado sem reescrita"
# falha de log não muda a resposta: a city aponta para um ARQUIVO (mkdir -p por baixo dele falha)
: > "$T/city-e-um-arquivo"; RC=0; payload 'venv/bin/python -m pytest t.py' | PYTEST_SHIM_CITY="$T/city-e-um-arquivo" python3 -I "$HOOK" > "$T/out" 2>"$T/err" || RC=$?
[ "$RC" = 0 ] && [ -n "$(newcmd)" ] && ok "C log que não grava: a reescrita sai igual, rc 0 (fail-open)" || bad "C falha de log mudou a resposta (rc=$RC)"

# =============================== M. controles negativos ===============================
mutant() { # <nome> <texto antigo> <texto novo> → $T/mut/pytest-shim/venv-rewrite-hook.py alterado (o atalho de verdade entra por symlink em bin/python3)
  cp "$HOOK" "$MH"; ln -sfn "$HERE/pytest-shim/bin/python3" "$T/mut/pytest-shim/bin/python3"
  if ! python3 -I -c 'import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1: sys.exit(3)
open(p, "w").write(s.replace(old, new))' "$MH" "$2" "$3"; then
    n=$((n+1)); fails=$((fails+1)); echo "FAIL mutante $1: o texto a trocar não existe exatamente uma vez (o controle não controla)"; return 1; fi
  return 0; }
caught() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: o mutante NÃO foi pego (esperava '$2', veio '$3')"; fails=$((fails+1)); fi; }
MH="$T/mut/pytest-shim/venv-rewrite-hook.py"
# M1: emite permissionDecision allow junto
mutant m1 '"hookEventName": "PreToolUse", "updatedInput": out' '"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": out' && {
  hook "$MH" 'venv/bin/python -m pytest t.py'; caught "M1 permissionDecision allow na resposta (o caso C reprova o mutante)" "true" "$(jq -r '.hookSpecificOutput | has("permissionDecision")' "$T/out" 2>/dev/null)"; }
# M2: o interior das aspas não é pulado (o ; de dentro delas passa a separar comandos)
mutant m2 'while i < n and cmd[i] != q:' 'while False:' && {
  hook "$MH" "echo 'ok; venv/bin/python -m pytest t.py' done"; caught "M2 aspas ignoradas: o texto citado é reescrito (o caso B 'ponto e vírgula dentro de aspas' reprova o mutante)" "1" "$([ -s "$T/out" ] && echo 1 || echo 0)"; }
# M3: VAR=x direto em vez de env (quebra depois de timeout)
mutant m3 'f"/usr/bin/env PYTEST_SHIM_PY={text} {shim_py3}"' 'f"PYTEST_SHIM_PY={text} {shim_py3}"' && {
  hook "$MH" 'timeout 900 venv/bin/python -m pytest t.py'; caught "M3 sem env, 'timeout 900 PYTEST_SHIM_PY=…' lê a atribuição como NOME do comando (o caso A 'timeout' reprova o mutante)" "1" "$(case "$(newcmd)" in "timeout 900 PYTEST_SHIM_PY="*) echo 1 ;; *) echo 0 ;; esac)"; }
# M4: o corpo do heredoc não é pulado
mutant m4 'for delim, strip in pending:' 'for delim, strip in []:' && {
  hook "$MH" $'cat <<EOF\nvenv/bin/python -m pytest corpo\nEOF'; caught "M4 corpo de heredoc lido como comando e reescrito (o caso B 'heredoc só com texto' reprova o mutante)" "1" "$([ -s "$T/out" ] && echo 1 || echo 0)"; }
# M5: heredoc dentro de substituição deixa de ser "não sei ler" (o corpo com ")" desbalanceado vaza como comando de topo)
mutant m5 'raise Bail("heredoc dentro de substituição")' 'pass' && {
  hook "$MH" $'x=$(cat <<\'EOF\'\nfoo ) bar\nvenv/bin/python -m pytest corpo\nEOF\n)\nvenv/bin/python -m pytest t.py'; caught "M5 heredoc dentro de \$(…) lido por contagem de parênteses: o corpo vira comando e é reescrito (o caso B reprova o mutante)" "1" "$([ -s "$T/out" ] && echo 1 || echo 0)"; }

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
