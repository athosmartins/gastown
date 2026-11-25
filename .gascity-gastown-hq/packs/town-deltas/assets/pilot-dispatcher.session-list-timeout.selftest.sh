#!/usr/bin/env bash
# ga-pj5bvdt: toda leitura de `gc session list` com timeout no caminho de despacho do Pilot usa o MESMO orçamento PILOT_SESSION_LIST_TIMEOUT_SECS.
# Medido 24/11: a lista levava 30-48 s; a rota ao nó (Hetzner/MBP) tinha `timeout 20` fixo e desistia sempre.
# Fora da conta: gc_variable_session_count, gêmeo byte-a-byte do quality-gate-dispatcher.sh (variable-session-cap.selftest.sh
# exige os dois corpos iguais) e sem chamador no Pilot — muda junto com o gêmeo do gate, nunca sozinho.
# O guarda pega só a forma `timeout <dígitos> gc --city <x> session list --json`; leitura sem timeout não é contada aqui.
set -u
D="$(cd "$(dirname "$0")" && pwd)"; F="$D/pilot-dispatcher.sh"
fail=0
[ -r "$F" ] || { echo "FAIL: não li $F"; exit 1; }
SRC=$(awk '/^gc_variable_session_count\(\)/{skip=1} skip&&/^}/{skip=0;next} !skip' "$F")
grep -q "^gc_variable_session_count()" "$F" || { echo "FAIL: gêmeo gc_variable_session_count sumiu (padrão mudou?)"; exit 1; }
n_all=$(printf "%s\n" "$SRC" | grep -c "session list --json")
n_fixed=$(printf "%s\n" "$SRC" | grep -E "timeout [0-9]+ gc --city [^ ]+ session list --json" | wc -l | tr -d " ")
n_env=$(printf "%s\n" "$SRC" | grep -c "timeout \"\${PILOT_SESSION_LIST_TIMEOUT_SECS:-30}\" gc --city \"\$GC_CITY\" session list --json")
[ "$n_all" -gt 0 ] || { echo "FAIL: nenhuma leitura de session list achada (padrão mudou?)"; exit 1; }
if [ "$n_fixed" -ne 0 ]; then echo "FAIL: $n_fixed leitura(s) de session list com timeout fixo:"; printf "%s\n" "$SRC" | grep -E "timeout [0-9]+ gc --city [^ ]+ session list --json"; fail=1; else echo "ok: nenhuma leitura com timeout fixo"; fi
if [ "$n_env" -lt 5 ]; then echo "FAIL: só $n_env leitura(s) usam PILOT_SESSION_LIST_TIMEOUT_SECS (esperado >= 5: dispatch_one, contagens, pick e rota ao nó)"; fail=1; else echo "ok: $n_env leituras usam PILOT_SESSION_LIST_TIMEOUT_SECS"; fi
exit $fail
