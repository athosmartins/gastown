#!/usr/bin/env bash
# ga-pj5bvdt: toda leitura de `gc session list` no Pilot usa o MESMO orçamento PILOT_SESSION_LIST_TIMEOUT_SECS.
# Medido 24/11: a lista levava 30-48 s; a rota ao nó (Hetzner/MBP) tinha `timeout 20` fixo e desistia sempre.
set -u
D="$(cd "$(dirname "$0")" && pwd)"; F="$D/pilot-dispatcher.sh"
fail=0
[ -r "$F" ] || { echo "FAIL: não li $F"; exit 1; }
n_all=$(grep -c "session list --json" "$F")
n_fixed=$(grep -E "timeout [0-9]+ gc --city [^ ]+ session list --json" "$F" | wc -l | tr -d " ")
n_env=$(grep -c "timeout \"\${PILOT_SESSION_LIST_TIMEOUT_SECS:-30}\" gc --city \"\$GC_CITY\" session list --json" "$F")
[ "$n_all" -gt 0 ] || { echo "FAIL: nenhuma leitura de session list achada (padrão mudou?)"; exit 1; }
if [ "$n_fixed" -ne 0 ]; then echo "FAIL: $n_fixed leitura(s) de session list com timeout fixo:"; grep -nE "timeout [0-9]+ gc --city [^ ]+ session list --json" "$F"; fail=1; else echo "ok: nenhuma leitura com timeout fixo"; fi
if [ "$n_env" -lt 6 ]; then echo "FAIL: só $n_env leitura(s) usam PILOT_SESSION_LIST_TIMEOUT_SECS (esperado >= 6: dispatch_one, contagens, pick e rota ao nó)"; fail=1; else echo "ok: $n_env leituras usam PILOT_SESSION_LIST_TIMEOUT_SECS"; fi
exit $fail
