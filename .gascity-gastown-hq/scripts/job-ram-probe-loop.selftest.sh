#!/usr/bin/env bash
# job-ram-probe-loop.selftest.sh — hermético: launchctl e probe são stubs, o relógio é um arquivo, o HOME e a city são diretórios temporários (nada do launchd de verdade é tocado).
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: data-limite passada = bootout + plist apagado + motivo no log, sem rodar o probe · 4 noites completas = fim · a última volta (3 noites + 1) mede com os argumentos certos (--skip-free-gb 3, arquivo do dia)
#   e termina na volta seguinte · volta que começa às 04:00 (e às 04:15) é `parcial` e NÃO conta · 03:59 conta · a noite que acabaria depois da data-limite não começa · 23/10 (a última permitida) é medida ·
#   rc != 0 repete e zera na 1ª que passa · 6 falhas seguidas = exit 1 SEM bootout e SEM apagar o plist · hora ilegível = falha, nunca decisão.
# CONTROLE NEGATIVO: cada guarda é removida do script (sed numa cópia) e a suíte TEM que passar a falhar.
# VARIÁVEIS: JRL_UNDER_TEST (script a testar) · JRL_NO_MUTANTS=1
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
L="${JRL_UNDER_TEST:-$HERE/job-ram-probe-loop.sh}"
T=$(cd "$(mktemp -d /tmp/jrl.XXXXXX)" && pwd -P)
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
command -v timeout >/dev/null || { echo "precisa de 'timeout' no PATH"; exit 2; }
fails=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -n "${JRL_MUTANT:-}" ] && { echo "RESULT $fails/$n"; exit 1; }; fi; }  # mutante: o 1º caso vermelho já o mata
LABEL=com.gascity.job-ram-probe-loop
UID_=$(id -u)

mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$@" >> "$JRL_T/lc.calls"\n' > "$T/bin/launchctl"; chmod +x "$T/bin/launchctl"
cat > "$T/stub.sh" <<'EOF'
#!/bin/sh
# probe de mentira: anota os argumentos, tira a 1ª linha "RC HORA-DEPOIS" da fila, adianta o relógio e sai com RC. Fila vazia = teste mal montado (exit 99, barulhento).
echo "$@" >> "$JRL_T/probe.calls"
line=$(head -1 "$JRL_T/queue" 2>/dev/null)
[ -n "$line" ] || exit 99
sed '1d' "$JRL_T/queue" > "$JRL_T/queue.n"; mv "$JRL_T/queue.n" "$JRL_T/queue"
set -- $line
echo "$2" > "$JRL_T/now"
exit "$1"
EOF

# run NOME "LOG" HORA "FILA"  → $T/NOME/{rc,loop.log,lc.calls,probe.calls}; o plist falso nasce presente
run() {
  local d="$T/$1"
  mkdir -p "$d/city/.gc/job-ram-probe-run" "$d/home/Library/LaunchAgents"
  [ "$2" = "-" ] || printf '%s' "$2" > "$d/city/.gc/job-ram-probe-run/loop.log"      # "-" = arquivo ausente
  : > "$d/home/Library/LaunchAgents/$LABEL.plist"
  [ "$3" = "-" ] || printf '%s\n' "$3" > "$d/now"      # "-" = nenhuma hora escrita (K aponta o relógio para um caminho ausente)
  printf '%s' "$4" > "$d/queue"
  JRL_T="$d" GC_CITY_PATH="$d/city" HOME="$d/home" JRL_PROBE_CMD="sh $T/stub.sh" JRL_LAUNCHCTL="$T/bin/launchctl" JRL_NOW_FILE="${NOWF:-$d/now}" JRL_RETRY_SLEEP=0 \
    timeout 10 sh "$L" > "$d/out" 2>&1; echo $? > "$d/rc"
}
rc_of() { cat "$T/$1/rc"; }
plist_gone() { [ ! -e "$T/$1/home/Library/LaunchAgents/$LABEL.plist" ]; }
logl() { cat "$T/$1/city/.gc/job-ram-probe-run/loop.log"; }
calls() { cat "$T/$1/$2" 2>/dev/null; }
nl() { printf '%s' "$1" | grep -c . | tr -d ' '; }
N17='2026-10-17T05:10:03 noite 20261017 rc=0
2026-10-17T05:26:13 noite 20261018 rc=143
'
N3="${N17}2026-10-20T05:10:01 noite 20261020 rc=0
2026-10-21T05:10:02 noite 20261021 rc=0
"  # 17 + 20 + 21 = 3 noites completas (a 20261018 rc=143 não entra); a 4ª é a de 22/10
BOOT="bootout gui/$UID_/$LABEL"

run_all() {
  # A: data-limite passada
  run A "$N17" 202610230531 ""
  [ "$(rc_of A)" = 0 ] && [ "$(calls A lc.calls)" = "$BOOT" ] && plist_gone A && [ ! -e "$T/A/probe.calls" ] && logl A | grep -q 'fim: data-limite 202610230530 passou'; ok $? "data-limite passada: bootout, plist apagado, motivo no log e o probe NÃO roda"
  # B: 4 noites completas
  run B "${N3}2026-10-22T05:10:03 noite 20261022 rc=0
" 202610220600 ""
  [ "$(rc_of B)" = 0 ] && [ "$(calls B lc.calls)" = "$BOOT" ] && plist_gone B && [ ! -e "$T/B/probe.calls" ] && logl B | grep -q 'fim: 4 noites completas (>= 4)'; ok $? "4 noites completas no log (a de 17/10 + 3): fim, sem rodar o probe"
  # C: 3 noites + a última: argumentos certos, depois fim
  run C "$N3" 202610220200 "0 202610220511
"
  [ "$(rc_of C)" = 0 ] && [ "$(nl "$(calls C probe.calls)")" = 1 ] && [ "$(calls C probe.calls)" = "--start 03:30 --until 05:10 --interval 5 --max-mb 60 --min-free-gb 0.1 --skip-free-gb 3 --out $T/C/city/.gc/job-ram-probe-20261022.jsonl" ]; ok $? "3 noites + a de 22/10: o probe roda UMA vez com a janela, os pisos (--skip-free-gb 3) e o arquivo do dia"
  logl C | tail -2 | head -1 | grep -q 'noite 20261022 rc=0$' && logl C | tail -1 | grep -q 'fim: 4 noites completas' && plist_gone C && [ "$(calls C lc.calls)" = "$BOOT" ]; ok $? "a volta é anotada 'noite 20261022 rc=0' (sem 'parcial') e a seguinte termina a missão"
  # D: começou às 04:00 -> parcial, não conta; depois 6 falhas -> desiste sem tocar no agente
  run D "$N17" 202610210400 "0 202610210511
6 202610210512
6 202610210512
6 202610210512
6 202610210512
6 202610210512
6 202610210512
"
  logl D | grep -q 'noite 20261021 rc=0 parcial$'; ok $? "volta que começa às 04:00 em ponto é anotada 'rc=0 parcial'"
  ! logl D | grep -q 'fim:' && [ "$(rc_of D)" = 1 ] && logl D | grep -q 'desisto: 6 falhas seguidas (última rc=6)'; ok $? "a volta parcial NÃO conta como noite (a missão segue) e 6 falhas seguidas = desiste com exit 1"
  [ ! -e "$T/D/lc.calls" ] && ! plist_gone D; ok $? "desistir NÃO dá bootout nem apaga o plist (o próximo boot tenta de novo)"
  [ "$(nl "$(calls D probe.calls)")" = 7 ] && calls D probe.calls | tail -1 | grep -q 'job-ram-probe-20261022.jsonl$'; ok $? "depois da volta parcial de 21/10 as tentativas são da noite SEGUINTE (22/10), 7 chamadas no total"
  # E: a noite que acabaria depois da data-limite
  run E "$N17" 202610230520 ""
  [ "$(rc_of E)" = 0 ] && [ "$(calls E lc.calls)" = "$BOOT" ] && plist_gone E && [ ! -e "$T/E/probe.calls" ] && logl E | grep -q 'fim: a noite 20261024 acaba (05:10) depois da data-limite'; ok $? "05:20 de 23/10: a próxima noite (24/10) acabaria depois da data-limite: fim, sem medir"
  # F: 23/10 03:00 ainda cabe (acaba 05:10 < 05:30)
  run F "$N17" 202610230300 "0 202610230511
"
  calls F probe.calls | grep -q 'job-ram-probe-20261023.jsonl$' && logl F | grep -q 'noite 20261023 rc=0$' && logl F | tail -1 | grep -q 'fim: a noite 20261024 acaba'; ok $? "23/10 de madrugada: a noite de 23/10 É medida (acaba antes da data-limite) e a volta seguinte termina"
  # G: hora ilegível
  run G "$N17" lixo ""
  [ "$(rc_of G)" = 1 ] && [ ! -e "$T/G/lc.calls" ] && [ ! -e "$T/G/probe.calls" ] && ! plist_gone G && logl G | grep -q "falha: hora ilegível ('lixo')"; ok $? "hora ilegível: 6 falhas e exit 1; não mede, não decide o fim, não apaga o agente"
  # K: arquivo da hora AUSENTE (cat falha): igual a hora ilegível, nada é decidido
  NOWF="$T/K/hora-ausente" run K "$N17" - ""
  [ "$(rc_of K)" = 1 ] && [ ! -e "$T/K/lc.calls" ] && [ ! -e "$T/K/probe.calls" ] && ! plist_gone K && logl K | grep -q "falha: hora ilegível ('')"; ok $? "relógio ilegível (arquivo ausente): 6 falhas e exit 1; não mede, não decide o fim, não apaga o agente"
  # L: loop.log AUSENTE: 0 noites contadas (não 4), segue medindo e cria o log
  run L - 202610220200 "0 202610220511
"
  calls L probe.calls | head -1 | grep -q 'job-ram-probe-20261022.jsonl$' && logl L | grep -q 'noite 20261022 rc=0$' && ! logl L | grep -q 'fim:' && ! plist_gone L; ok $? "loop.log ausente: conta 0 noites (não 'completas'), mede a noite e NÃO encerra a missão"
  # H: falha, repete, passa
  run H "$N3" 202610220200 "6 202610220200
0 202610220511
"
  [ "$(nl "$(calls H probe.calls)")" = 2 ] && logl H | grep -q 'noite 20261022 rc=6$' && logl H | grep -q 'noite 20261022 rc=0$' && plist_gone H; ok $? "rc=6 repete a mesma noite, a 1ª que passa conta e termina (a falha não é fim nem noite)"
  # J: 3 noites completas + uma volta que começa às 04:15: se a parcial contasse, a missão acabaria uma noite cedo
  run J "$N3" 202610220415 "0 202610220511
0 202610230511
"
  [ "$(nl "$(calls J probe.calls)")" = 2 ] && logl J | grep -q 'noite 20261022 rc=0 parcial$' && logl J | grep -q 'noite 20261023 rc=0$' && logl J | tail -1 | grep -q 'fim: 4 noites completas' && plist_gone J; ok $? "3 noites + volta parcial de 22/10: a missão NÃO acaba (parcial não é a 4ª); a de 23/10 é a 4ª e termina"
  # I: 03:59 ainda cobre o lote das 04:00
  run I "$N3" 202610220359 "0 202610220511
"
  logl I | grep -q 'noite 20261022 rc=0$' && plist_gone I; ok $? "volta que começa às 03:59 conta como noite completa"
}

if [ -n "${JRL_MUTANT:-}" ]; then run_all; echo "RESULT $fails/$n"; exit $((fails > 0)); fi
run_all
echo "== $((n-fails))/$n ok =="

[ -n "${JRL_NO_MUTANTS:-}" ] || {
  echo "-- controle negativo: cada guarda removida TEM que fazer a suíte falhar"
  mutant() {  # mutant DESCRIÇÃO SED-EXPR
    local m="$T/mut.$RANDOM"; mkdir -p "$m"; sed -e "$2" "$L" > "$m/job-ram-probe-loop.sh"
    if cmp -s "$L" "$m/job-ram-probe-loop.sh"; then ok 1 "mutante '$1': o sed não mudou nada (o teste do mutante está errado)"; return; fi
    local r; r=$(JRL_MUTANT=1 JRL_UNDER_TEST="$m/job-ram-probe-loop.sh" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$1' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$1' pego ($r)";; *) ok 1 "mutante '$1': execução sem resultado ($r)";; esac
  }
  mutant "data-limite não encerra" 's/^  \[ "\$now" -ge "\$DEADLINE" \] && finish .*$/  :/'
  mutant "4 noites não encerram" 's/^  \[ "\$n" -ge "\$NIGHTS" \] && finish .*$/  :/'
  mutant "noite que acaba depois da data-limite começa" 's/^  \[ "\${day}0510" -gt "\$DEADLINE" \] && finish .*$/  :/'
  mutant "volta tardia não é marcada parcial" 's/ && late=" parcial"/ \&\& :/'
  mutant "volta parcial conta como noite" 's/ && \$5 != "parcial"//'
  mutant "limite das 04:00 vira 04:01" 's/\[ "\$hm" -ge 400 \]/[ "$hm" -ge 401 ]/'
  mutant "fim não apaga o plist" 's/^  rm -f "\$AGENT_PLIST"$/  :/'
  mutant "fim não dá bootout" 's/^  "\$LAUNCHCTL" bootout .*$/  :/'
  mutant "6 falhas não desistem" 's/^    \[ "\$fails" -ge 6 \] && { log "desisto: \$fails falhas seguidas (última.*$/    :/'
  mutant "hora ilegível vira hora" 's/^  if ! isnum "\$now" || \[ "\${#now}" -ne 12 \]; then.*$/  if false; then/'
  mutant "probe sem o piso de amostragem" 's/ --skip-free-gb 3//'
  mutant "falha não conta como falha seguida (nunca desiste)" 's/^    fails=\$((fails + 1))$/    fails=0/'
  echo "== mutantes: $((n-fails))/$n ok no total =="
}
[ "$fails" = 0 ]
