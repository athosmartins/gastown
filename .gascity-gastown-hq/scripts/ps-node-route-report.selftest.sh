#!/usr/bin/env bash
# ps-node-route-report.selftest.sh — hermético: cidades falsas em mktemp; o relatório e a peça de gravação do Pilot (_pilot_ps_node_log, extraída do pilot-dispatcher.sh) são os REAIS. (ga-2hd02v.4.13)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: a amostra limpa (contagens por modo, veredito, base) · linha de outro evento e linha ilegível contadas à parte · nada a medir (3) · perda contada pelo contador, só pelo aviso do log do Pilot, e o MAIOR dos dois ·
#   o arquivo que existe e não lê (jsonl, contador, log do Pilot virados pasta, ou o jq que sai 0 sem escrever o resumo) é DESCONHECIDO (4), nunca "0" · uso (2) · só leitura · e a ponta a ponta: o gancho real perde linhas num log quebrado e o relatório as vê.
# CONTROLE NEGATIVO: cada mutante troca UMA linha do relatório numa cópia e a bateria inteira tem de reprovar; mutante que sobrevive reprova esta bateria.
# COMO RODAR: bash scripts/ps-node-route-report.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3)
#   REPORT_UNDER_TEST=<cópia do relatório> roda a bateria contra a cópia, sem mutantes, e para no 1º FAIL (é como o controle negativo chama a si mesmo).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORT="${REPORT_UNDER_TEST:-$HERE/ps-node-route-report.sh}"
DISPATCHER="$HERE/../packs/town-deltas/assets/pilot-dispatcher.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/ps-node-report.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); [ -z "${REPORT_UNDER_TEST:-}" ] || { echo "(mutante: primeiro FAIL, saindo)"; exit 1; }; }
command -v jq >/dev/null 2>&1 || { echo "jq ausente"; exit 2; }
[ -f "$REPORT" ] || { echo "relatório ausente: $REPORT"; exit 2; }

NC=0; C=""; OUT=""; RC=0
newcity() { NC=$((NC+1)); C="$T/city$NC"; mkdir -p "$C/.gc/logs"; }
# J <bead> <modo> <rc> <out> <ts> — uma linha de decisão como o gancho do Pilot grava
J() { jq -cn --arg b "$1" --arg m "$2" --argjson rc "$3" --arg o "$4" --arg ts "$5" '{ts:$ts,event:"pilot-node-route",bead:$b,mode:$m,rc:$rc,out:$o}'; }
NODE_TXT='{"verdict":"node","basis":"text"}'; NODE_LBL='{"verdict":"node","basis":"label"}'
LOG() { echo "$C/.gc/ps-node-route.jsonl"; }
run() { OUT=$("$REPORT" --city "$C" 2>&1); RC=$?; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
expect() { # expect <rótulo> <rc esperado> [trecho que a saída tem de ter]...
  local label="$1" want="$2"; shift 2
  if [ "$RC" != "$want" ]; then bad "$label (rc=$RC, esperado $want; saída: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-300))"; return; fi
  local frag
  for frag in "$@"; do has "$frag" || { bad "$label (a saída não tem '$frag'; saída: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-400))"; return; }; done
  ok "$label"
}
# Se a saída tiver este trecho, o caso reprova
expect_not() { if has "$1"; then bad "$2 (a saída tem '$1')"; else ok "$2"; fi; }

# ---- amostra limpa
newcity
{ J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z; J ps-2 shadow 10 '{"verdict":"mini"}' 2026-10-23T10:05:00Z; J ps-1 shadow 0 "$NODE_LBL" 2026-10-23T10:10:00Z
  J ps-3 shadow 11 'x' 2026-10-23T10:15:00Z; echo '{"ts":"t","event":"apply","bead":"ps-9","rc":12,"detail":"x"}'; } > "$(LOG)"
run; expect "amostra limpa: 0, com as contagens por modo, veredito e base" 0 \
  "linhas gravadas (decisões): 4" "beads distintas: 3" "de 2026-10-23T10:00:00Z a 2026-10-23T10:15:00Z" "por modo: shadow=4" \
  "node (rc 0)=2 · mini (rc 10)=1 · não sei (rc 11)=1 · outro rc=0" "node por base: label=1 text=1" "linhas ilegíveis: 0" "linhas de outro evento (não são decisões): 1" \
  "contador (ps-node-route.lost): 0 — arquivo ausente" "avisos no log do Pilot: não li" "nenhuma perda registrada"
expect_not "AMOSTRA SUBCONTADA" "amostra limpa: não acusa subcontagem"
newcity; { J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z; J ps-2 label 12 'erro' 2026-10-23T10:01:00Z; J ps-3 auto 13 'erro' 2026-10-23T10:02:00Z; J ps-4 shadow 0 'fake' 2026-10-23T10:03:00Z; } > "$(LOG)"
run; expect "modos misturados, rc de erro do despachante e 'out' que não é JSON" 0 "por modo: auto=1 label=1 shadow=2" "outro rc=2" "node por base: ?=1 text=1"

# ---- nada a medir
newcity; run; expect "cidade sem nada: 3, 'nada a medir'" 3 "nada a medir" "linhas gravadas (decisões): 0 —"
newcity; : > "$(LOG)"; run; expect "jsonl vazio e nenhuma perda: 3, não 'completa'" 3 "nada a medir"
expect_not "nenhuma perda registrada (contador e avisos)" "jsonl vazio: não diz que a amostra está boa"

# ---- perdas
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; printf 't1\tps-5\tshadow\tIs a directory\nt2\tps-6\tshadow\tIs a directory\nt3\tps-7\tshadow\tIs a directory\n' > "$C/.gc/ps-node-route.lost"
run; expect "3 linhas no contador: 4, 'AMOSTRA SUBCONTADA' e o número" 4 "AMOSTRA SUBCONTADA" "contador (ps-node-route.lost): 3" "3 linha(s) NÃO gravada(s)" "linhas gravadas (decisões): 1"
newcity; printf 't1\tps-5\tshadow\tIs a directory\nt2\tps-6\tshadow\tIs a directory\n' > "$C/.gc/ps-node-route.lost"
run; expect "só o contador, sem nenhum jsonl: 4 (a amostra é de zero linhas e perdeu 2), não 3" 4 "linhas gravadas (decisões): 0 —" "contador (ps-node-route.lost): 2" "AMOSTRA SUBCONTADA"
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"
printf '[x] [pilot-dispatcher] WARN: ps-node: linha de ps-5 (shadow, rc=0) NÃO gravada em ps-node-route.jsonl: Is a directory — a amostra do shadow fica subcontada; NEM O CONTADOR gravou — esta perda só existe neste aviso\nlinha qualquer\n[x] [pilot-dispatcher] WARN: ps-node: linha de ps-6 (shadow, rc=10) NÃO gravada em ps-node-route.jsonl: Is a directory — a amostra do shadow fica subcontada; NEM O CONTADOR gravou — esta perda só existe neste aviso\n' > "$C/.gc/logs/pilot-dispatcher.log"
run; expect "disco cheio: nenhum contador, só os avisos do log do Pilot: 4 e conta os 2 avisos" 4 "avisos no log do Pilot: 2" "2 linha(s) NÃO gravada(s)" "AMOSTRA SUBCONTADA"
printf 't1\tps-5\tshadow\tx\nt2\tps-6\tshadow\tx\nt3\tps-7\tshadow\tx\nt4\tps-8\tshadow\tx\nt5\tps-9\tshadow\tx\n' > "$C/.gc/ps-node-route.lost"
run; expect "contador 5 e avisos 2: vale o MAIOR (5)" 4 "contador (ps-node-route.lost): 5" "avisos no log do Pilot: 2" "5 linha(s) NÃO gravada(s)"
printf 't1\tps-5\tshadow\tx\n' > "$C/.gc/ps-node-route.lost"
run; expect "contador 1 e avisos 2: vale o MAIOR (2)" 4 "2 linha(s) NÃO gravada(s)"
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; printf '[x] WARN: ps-node: outra coisa qualquer\n[x] LOG ps-node-route.jsonl foi lido\n' > "$C/.gc/logs/pilot-dispatcher.log"
run; expect "log do Pilot sem o aviso de linha perdida (nem o nome do arquivo solto conta): 0, avisos 0" 0 "avisos no log do Pilot: 0"
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; : > "$C/.gc/ps-node-route.lost"
run; expect "contador que existe e está vazio: 0 perdas lidas, sem dúvida" 0 "contador (ps-node-route.lost): 0"

newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; printf 't1\tps-5\tshadow\tx\n\n   \nt2\tps-6\tshadow\tx\n' > "$C/.gc/ps-node-route.lost"
run; expect "contador com linhas em branco no meio: só as linhas com conteúdo contam (2)" 4 "contador (ps-node-route.lost): 2"

# ---- linha ilegível
newcity; { J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z; printf '{"ts":"2026-10-23T10:01:00Z","event":"pilot-node-route","bead":"ps-2","mo'; } > "$(LOG)"
run; expect "última linha cortada no meio (disco cheio no write): 4, 1 ilegível, e a decisão boa segue contada" 4 "linhas ilegíveis: 1" "linhas gravadas (decisões): 1" "não leem como JSON"
newcity; { J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z; echo '123'; echo '"texto"'; } > "$(LOG)"
run; expect "JSON que não é objeto também é ilegível: 4, 2 linhas" 4 "linhas ilegíveis: 2"

# ---- o arquivo que existe e não lê é DESCONHECIDO, nunca zero
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; mkdir "$C/.gc/ps-node-route.lost"
run; expect "contador que virou pasta: 4, 'DESCONHECIDO' (não 0 perdas)" 4 "contador (ps-node-route.lost): DESCONHECIDO" "AMOSTRA SUBCONTADA OU DUVIDOSA"
expect_not "ps-node-route.lost): 0" "contador ilegível: não é dito como 0"
newcity; mkdir "$(LOG)"; run; expect "jsonl que virou pasta: 4, 'DESCONHECIDO' (não 0 linhas)" 4 "linhas gravadas (decisões): DESCONHECIDO"
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; mkdir "$C/.gc/logs/pilot-dispatcher.log"
run; expect "log do Pilot que virou pasta: 4, 'DESCONHECIDO'" 4 "avisos no log do Pilot: DESCONHECIDO"
if [ "$(id -u)" != 0 ]; then
  newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; chmod 000 "$(LOG)"; run; chmod 644 "$(LOG)"
  expect "jsonl sem permissão de leitura: 4, 'DESCONHECIDO'" 4 "linhas gravadas (decisões): DESCONHECIDO"
else
  echo "(arquivo sem permissão de leitura: pulado — root lê tudo; os cenários de pasta acima são à prova de root)"
fi
# o arquivo lê, mas o jq sai 0 sem escrever o resumo (jq quebrado ou trocado): resumo vazio é "não li" (4), nunca "0 linhas" (ga-u6ueg0q)
mkdir "$T/jq-mudo"; printf '#!/bin/sh\nexit 0\n' > "$T/jq-mudo/jq"; chmod +x "$T/jq-mudo/jq"
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; OUT=$(PATH="$T/jq-mudo:$PATH" "$REPORT" --city "$C" 2>&1); RC=$?
expect "jq que sai 0 sem resumo: 4, 'DESCONHECIDO' (não 0 linhas)" 4 "linhas gravadas (decisões): DESCONHECIDO" "AMOSTRA SUBCONTADA OU DUVIDOSA"

# ---- uso
newcity; OUT=$("$REPORT" --foo 2>&1); RC=$?; expect "argumento desconhecido: 2" 2 "argumento desconhecido"
OUT=$("$REPORT" --city 2>&1); RC=$?; expect "--city sem pasta: 2" 2 "--city pede uma pasta"
OUT=$("$REPORT" --help 2>&1); RC=$?; expect "--help: 0 e diz o uso" 0 "uso: ps-node-route-report.sh"
newcity; J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z > "$(LOG)"; OUT=$(GC_CITY="$C" "$REPORT" 2>&1); RC=$?; expect "sem --city vale GC_CITY" 0 "linhas gravadas (decisões): 1"

# ---- só leitura
newcity; { J ps-1 shadow 0 "$NODE_TXT" 2026-10-23T10:00:00Z; } > "$(LOG)"; printf 't1\tps-5\tshadow\tx\n' > "$C/.gc/ps-node-route.lost"
before=$(cd "$C" && find . -type f -exec cksum {} + | sort | tr '\n' ' '); beforel=$(cd "$C" && find . | sort | tr '\n' ' '); run
after=$(cd "$C" && find . -type f -exec cksum {} + | sort | tr '\n' ' '); afterl=$(cd "$C" && find . | sort | tr '\n' ' ')
[ "$before" = "$after" ] && [ "$beforel" = "$afterl" ] && ok "só leitura: nenhum arquivo criado, apagado ou alterado" || bad "o relatório mexeu na cidade: antes=$before depois=$after"

# ---- ponta a ponta: o gancho REAL perde linhas num log quebrado e o relatório as enxerga
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FN="$(fn_of _pilot_ps_node_log)"
if [ -z "$FN" ]; then bad "ponta a ponta: _pilot_ps_node_log não está em $DISPATCHER"; else
  newcity
  hook() { GC_CITY="$C" bash -c 'warn(){ echo "WARN $*" >&2; }'$'\n'"$FN"$'\n''_pilot_ps_node_log "$@"; echo "rc=$?"' _ "$@" 2>>"$T/hook.err" | tail -1; }
  : > "$T/hook.err"
  r1=$(hook ps-a shadow 0 "$NODE_TXT"); r2=$(hook ps-b shadow 10 '{"verdict":"mini"}')
  mv "$(LOG)" "$T/jsonl.guardado"; mkdir "$(LOG)"
  r3=$(hook ps-c shadow 0 "$NODE_TXT"); r4=$(hook ps-d shadow 0 "$NODE_TXT")
  rmdir "$(LOG)"; mv "$T/jsonl.guardado" "$(LOG)"
  [ "$r1 $r2 $r3 $r4" = "rc=0 rc=0 rc=1 rc=1" ] && ok "ponta a ponta: o gancho grava 2, perde 2 num log quebrado e devolve 1 nas perdas" || bad "ponta a ponta: rcs do gancho '$r1 $r2 $r3 $r4' ($(cat "$T/hook.err"))"
  run; expect "ponta a ponta: o relatório vê as 2 decisões gravadas e as 2 perdas (4)" 4 "linhas gravadas (decisões): 2" "contador (ps-node-route.lost): 2" "2 linha(s) NÃO gravada(s)" "AMOSTRA SUBCONTADA"
  # a mesma cidade, com o aviso do gancho copiado para o log do Pilot (como o launchd faz): o relatório o conta também
  cp "$T/hook.err" "$C/.gc/logs/pilot-dispatcher.log"; run; expect "ponta a ponta: o aviso do gancho, no log do Pilot, é contado como o aviso que é (2)" 4 "avisos no log do Pilot: 2"
fi

# ---- controle negativo: cada mutante troca UMA linha do relatório numa cópia; a bateria inteira contra a cópia tem de reprovar
if [ -n "${REPORT_UNDER_TEST:-}" ]; then
  echo "---"; echo "$((n-fails))/$n ok"; [ $fails -eq 0 ] && { echo "SELFTEST OK"; exit 0; } || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
fi
mutant() { # mutant <nome> <trecho original> <trecho novo>
  local name="$1" copy="$T/report.mut.sh"
  python3 -I - "$REPORT" "$copy" "$2" "$3" <<'EOF' || { bad "mutante $name: o trecho original não existe (o relatório mudou? atualize o mutante)"; return; }
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(sys.argv[3]) < 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  chmod +x "$copy"
  if REPORT_UNDER_TEST="$copy" bash "$0" >/dev/null 2>&1; then bad "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi
}
mutant perda-nao-avisa          'if [ "$lost_max" -gt 0 ]; then add_doubt' 'if false; then add_doubt'
mutant so-o-contador            'lost_max=$lost_n; [ "$warn_n" -le "$lost_max" ] || lost_max=$warn_n' 'lost_max=$lost_n'
mutant so-o-aviso               'lost_max=$lost_n; [ "$warn_n" -le "$lost_max" ] || lost_max=$warn_n' 'lost_max=$warn_n'
mutant menor-em-vez-do-maior    '[ "$warn_n" -le "$lost_max" ] || lost_max=$warn_n' '[ "$warn_n" -ge "$lost_max" ] || lost_max=$warn_n'
mutant contador-ilegivel-vira-0 'if [ "$lost_state" = ilegivel ]; then add_doubt' 'if false; then add_doubt'
mutant jsonl-ilegivel-vira-0    '    add_doubt "$LOG existe e não foi possível lê-lo' '    : "$LOG existe e não foi possível lê-lo'
mutant log-pilot-ilegivel-vira-0 'if [ "$plog_state" = ilegivel ]; then add_doubt' 'if false; then add_doubt'
mutant linha-ilegivel-nao-conta 'if [ "$ileg" -gt 0 ]; then add_doubt' 'if false; then add_doubt'
mutant resumo-vazio-vale-lido   '"$LOG" 2>/dev/null) && [ -n "$SUM" ]; then' '"$LOG" 2>/dev/null) || [ -n "$SUM" ]; then'
mutant subcontada-sai-0         '  printf '"'"'%s\n'"'"' "$doubt" | sed '"'"'s/^/  - /'"'"'
  exit 4' '  printf '"'"'%s\n'"'"' "$doubt" | sed '"'"'s/^/  - /'"'"'
  exit 0'
mutant nada-a-medir-sai-0       '  exit 3
fi
echo "nenhuma perda registrada' '  exit 0
fi
echo "nenhuma perda registrada'
mutant outro-evento-e-decisao   'select(type == "object" and .event == "pilot-node-route")' 'select(type == "object")'
mutant aviso-do-pilot-frouxo    "WARN_TXT='NÃO gravada em ps-node-route.jsonl'" "WARN_TXT='ps-node-route.jsonl'"
mutant contador-conta-vazias    "lost_n=\$(grep -c '[^[:space:]]' \"\$LOST\" 2>/dev/null || true)" 'lost_n=$(grep -c '"'"'^'"'"' "$LOST" 2>/dev/null || true)'
mutant uso-sai-0                '    *) say "argumento desconhecido: $1 (uso: ps-node-route-report.sh [--city DIR])"; exit 2 ;;' '    *) say "argumento desconhecido: $1 (uso: ps-node-route-report.sh [--city DIR])"; exit 0 ;;'
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
