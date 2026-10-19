#!/usr/bin/env bash
# job-ram-probe-loop.selftest.sh — hermético: launchctl e probe são stubs, o relógio é um arquivo, o HOME e a city são diretórios temporários (nada do launchd de verdade é tocado).
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS: data-limite passada = bootout + plist apagado + motivo e nº de noites no log, sem rodar o probe · 4 noites completas = fim · a última volta (3 noites + 1) mede com os argumentos certos (--skip-free-gb 3, arquivo do dia)
#   e termina na volta seguinte · volta que começa às 04:00 (e às 04:15) é `parcial` e NÃO conta · 03:59 conta · a noite que acabaria depois da data-limite não começa · 23/10 (a última permitida) é medida ·
#   rc != 0 repete e zera na 1ª que passa · 6 falhas seguidas = exit 1 SEM bootout e SEM apagar o plist · hora ilegível = falha, nunca decisão · a noite é julgada pelo ARQUIVO que o probe deixou, não pelo rc:
#   `cego=Ns` (ticks `pulado`, ps/launchctl falsos, buraco no tempo, pontas) até 600 s conta; acima, ou `tudo`, ou `?` (arquivo ausente/lixo) = `parcial`, não conta · plist que não saiu é dito no log.
#   O stub do probe grava no --out a noite descrita na 3ª coluna da fila: segmentos `gN` (N leituras boas), `pN` (N ticks pulados por disco), `sN` (ps_ok falso), `cN` (lc_ok falso), `hN` (buraco de N s),
#   passo de 5 s; `-` = não grava arquivo; `junk` = só lixo; sem 3ª coluna = `g5`.
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
# probe de mentira: anota os argumentos, tira a 1ª linha "RC HORA-DEPOIS [NOITE]" da fila, grava a noite no --out, adianta o relógio e sai com RC. Fila vazia = teste mal montado (exit 99, barulhento).
echo "$@" >> "$JRL_T/probe.calls"
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
line=$(head -1 "$JRL_T/queue" 2>/dev/null)
[ -n "$line" ] || exit 99
sed '1d' "$JRL_T/queue" > "$JRL_T/queue.n"; mv "$JRL_T/queue.n" "$JRL_T/queue"
set -- $line
echo "$2" > "$JRL_T/now"
case "${3:-g5}" in
  -) ;;
  junk) printf 'lixo\n{"ts":"x"}\n' > "$out";;
  *) awk -v spec="${3:-g5}" 'BEGIN { t = 1792218600; n = split(spec, a, ","); for (i = 1; i <= n; i++) { k = substr(a[i], 1, 1); c = substr(a[i], 2) + 0
       if (k == "h") { t += c; continue }
       for (j = 0; j < c; j++) {
         if (k == "g") printf "{\"ts\":%d,\"ps_ok\":true,\"lc_ok\":true,\"jobs\":{}}\n", t
         else if (k == "p") printf "{\"ts\":%d,\"pulado\":\"disco\",\"disk_free_mb\":1499,\"piso_mb\":3072}\n", t
         else if (k == "s") printf "{\"ts\":%d,\"ps_ok\":false,\"lc_ok\":true,\"jobs\":{}}\n", t
         else if (k == "c") printf "{\"ts\":%d,\"ps_ok\":true,\"lc_ok\":false,\"jobs\":{}}\n", t
         t += 5 } } }' > "$out";;
esac
exit "$1"
EOF

# run NOME "LOG" HORA "FILA"  → $T/NOME/{rc,loop.log,lc.calls,probe.calls}; o plist falso nasce presente
run() {
  local d="$T/$1"
  mkdir -p "$d/city/.gc/job-ram-probe-run" "$d/home/Library/LaunchAgents"
  [ "$2" = "-" ] || printf '%s' "$2" > "$d/city/.gc/job-ram-probe-run/loop.log"      # "-" = arquivo ausente
  : > "$d/home/Library/LaunchAgents/$LABEL.plist"
  [ -z "${PLIST_AS_DIR:-}" ] || { rm -f "$d/home/Library/LaunchAgents/$LABEL.plist"; mkdir "$d/home/Library/LaunchAgents/$LABEL.plist"; }      # `rm -f` num diretório falha: o plist "não sai"
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

# night_case NOME SPEC SUFIXO conta|parcial DESCRIÇÃO: a volta de 22/10 grava SPEC; `conta` = vale como a 4ª noite (1 chamada do probe), `parcial` = não vale e a volta de 23/10 (g5) é a 4ª (2 chamadas)
night_case() {
  run "$1" "$N3" 202610220200 "0 202610220511 $2
0 202610230511 g5
"
  local l; l=$(logl "$1")
  if [ "$4" = conta ]; then
    [ "$(nl "$(calls "$1" probe.calls)")" = 1 ] && printf '%s\n' "$l" | grep -q "noite 20261022 rc=0 $3\$" && printf '%s\n' "$l" | tail -1 | grep -q 'fim: 4 noites completas'
  else
    [ "$(nl "$(calls "$1" probe.calls)")" = 2 ] && printf '%s\n' "$l" | grep -q "noite 20261022 rc=0 parcial $3\$" && printf '%s\n' "$l" | grep -q 'noite 20261023 rc=0 cego=0s$' && printf '%s\n' "$l" | tail -1 | grep -q 'fim: 4 noites completas'
  fi
  ok $? "$5"
}

run_all() {
  # A: data-limite passada
  run A "$N17" 202610230531 ""
  [ "$(rc_of A)" = 0 ] && [ "$(calls A lc.calls)" = "$BOOT" ] && plist_gone A && [ ! -e "$T/A/probe.calls" ] && logl A | grep -q 'fim: data-limite 202610230530 passou (agora 202610230531); 1 de 4 noites completas'; ok $? "data-limite passada: bootout, plist apagado, motivo e nº de noites no log e o probe NÃO roda"
  # B: 4 noites completas
  run B "${N3}2026-10-22T05:10:03 noite 20261022 rc=0
" 202610220600 ""
  [ "$(rc_of B)" = 0 ] && [ "$(calls B lc.calls)" = "$BOOT" ] && plist_gone B && [ ! -e "$T/B/probe.calls" ] && logl B | grep -q 'fim: 4 noites completas (>= 4)'; ok $? "4 noites completas no log (a de 17/10 + 3): fim, sem rodar o probe"
  # C: 3 noites + a última: argumentos certos, depois fim
  run C "$N3" 202610220200 "0 202610220511
"
  [ "$(rc_of C)" = 0 ] && [ "$(nl "$(calls C probe.calls)")" = 1 ] && [ "$(calls C probe.calls)" = "--start 03:30 --until 05:10 --interval 5 --max-mb 60 --min-free-gb 0.1 --skip-free-gb 3 --out $T/C/city/.gc/job-ram-probe-20261022.jsonl" ]; ok $? "3 noites + a de 22/10: o probe roda UMA vez com a janela, os pisos (--skip-free-gb 3) e o arquivo do dia"
  logl C | tail -2 | head -1 | grep -q 'noite 20261022 rc=0 cego=0s$' && logl C | tail -1 | grep -q 'fim: 4 noites completas' && plist_gone C && [ "$(calls C lc.calls)" = "$BOOT" ]; ok $? "a volta é anotada 'noite 20261022 rc=0 cego=0s' (sem 'parcial') e a seguinte termina a missão"
  # D: começou às 04:00 -> parcial, não conta; depois 6 falhas -> desiste sem tocar no agente
  run D "$N17" 202610210400 "0 202610210511
6 202610210512
6 202610210512
6 202610210512
6 202610210512
6 202610210512
6 202610210512
"
  logl D | grep -q 'noite 20261021 rc=0 parcial cego=0s$'; ok $? "volta que começa às 04:00 em ponto é anotada 'rc=0 parcial' (cego=0s: a noite foi lida, só chegou tarde)"
  ! logl D | grep -q 'fim:' && [ "$(rc_of D)" = 1 ] && logl D | grep -q 'desisto: 6 falhas seguidas (última rc=6)'; ok $? "a volta parcial NÃO conta como noite (a missão segue) e 6 falhas seguidas = desiste com exit 1"
  [ ! -e "$T/D/lc.calls" ] && ! plist_gone D; ok $? "desistir NÃO dá bootout nem apaga o plist (o próximo boot tenta de novo)"
  [ "$(nl "$(calls D probe.calls)")" = 7 ] && calls D probe.calls | tail -1 | grep -q 'job-ram-probe-20261022.jsonl$'; ok $? "depois da volta parcial de 21/10 as tentativas são da noite SEGUINTE (22/10), 7 chamadas no total"
  # E: a noite que acabaria depois da data-limite
  run E "$N17" 202610230520 ""
  [ "$(rc_of E)" = 0 ] && [ "$(calls E lc.calls)" = "$BOOT" ] && plist_gone E && [ ! -e "$T/E/probe.calls" ] && logl E | grep -q 'fim: a noite 20261024 acaba (05:10) depois da data-limite 202610230530; 1 de 4 noites completas'; ok $? "05:20 de 23/10: a próxima noite (24/10) acabaria depois da data-limite: fim, sem medir"
  # F: 23/10 03:00 ainda cabe (acaba 05:10 < 05:30)
  run F "$N17" 202610230300 "0 202610230511
"
  calls F probe.calls | grep -q 'job-ram-probe-20261023.jsonl$' && logl F | grep -q 'noite 20261023 rc=0 cego=0s$' && logl F | tail -1 | grep -q 'fim: a noite 20261024 acaba'; ok $? "23/10 de madrugada: a noite de 23/10 É medida (acaba antes da data-limite) e a volta seguinte termina"
  # G: hora ilegível
  run G "$N17" lixo ""
  [ "$(rc_of G)" = 1 ] && [ ! -e "$T/G/lc.calls" ] && [ ! -e "$T/G/probe.calls" ] && ! plist_gone G && logl G | grep -q "falha: hora ilegível ('lixo')"; ok $? "hora ilegível: 6 falhas e exit 1; não mede, não decide o fim, não apaga o agente"
  # K: arquivo da hora AUSENTE (cat falha): igual a hora ilegível, nada é decidido
  NOWF="$T/K/hora-ausente" run K "$N17" - ""
  [ "$(rc_of K)" = 1 ] && [ ! -e "$T/K/lc.calls" ] && [ ! -e "$T/K/probe.calls" ] && ! plist_gone K && logl K | grep -q "falha: hora ilegível ('')"; ok $? "relógio ilegível (arquivo ausente): 6 falhas e exit 1; não mede, não decide o fim, não apaga o agente"
  # L: loop.log AUSENTE: 0 noites contadas (não 4), segue medindo e cria o log
  run L - 202610220200 "0 202610220511
"
  calls L probe.calls | head -1 | grep -q 'job-ram-probe-20261022.jsonl$' && logl L | grep -q 'noite 20261022 rc=0 cego=0s$' && ! logl L | grep -q 'fim:' && ! plist_gone L; ok $? "loop.log ausente: conta 0 noites (não 'completas'), mede a noite e NÃO encerra a missão"
  # H: falha, repete, passa
  run H "$N3" 202610220200 "6 202610220200
0 202610220511
"
  [ "$(nl "$(calls H probe.calls)")" = 2 ] && logl H | grep -q 'noite 20261022 rc=6$' && logl H | grep -q 'noite 20261022 rc=0 cego=0s$' && plist_gone H; ok $? "rc=6 repete a mesma noite, a 1ª que passa conta e termina (a falha não é fim nem noite)"
  # J: 3 noites completas + uma volta que começa às 04:15: se a parcial contasse, a missão acabaria uma noite cedo
  run J "$N3" 202610220415 "0 202610220511
0 202610230511
"
  [ "$(nl "$(calls J probe.calls)")" = 2 ] && logl J | grep -q 'noite 20261022 rc=0 parcial cego=0s$' && logl J | grep -q 'noite 20261023 rc=0 cego=0s$' && logl J | tail -1 | grep -q 'fim: 4 noites completas' && plist_gone J; ok $? "3 noites + volta parcial de 22/10: a missão NÃO acaba (parcial não é a 4ª); a de 23/10 é a 4ª e termina"
  # I: 03:59 ainda cobre o lote das 04:00
  run I "$N3" 202610220359 "0 202610220511
"
  logl I | grep -q 'noite 20261022 rc=0 cego=0s$' && plist_gone I; ok $? "volta que começa às 03:59 conta como noite completa"
  # a noite é julgada pelo ARQUIVO: rc=0 só diz que houve ao menos uma amostra (ga-sh8t23.6, gate 1). 3 noites contadas + a de 22/10; a de 23/10 (g5) é a reserva que fecha a missão quando a de 22/10 não vale.
  night_case M "g20,p47,g20" "cego=235s" conta "o dip de 235 s do reseed de 17/10 (disco < 3 GB, 47 ticks pulados) CONTA: cego=235s, a missão termina nesta volta"
  night_case N "g20,p139,g20" "cego=695s" parcial "700 s de disco baixo: rc=0 mas 'parcial cego=695s', NÃO conta; a volta de 23/10 é a 4ª"
  night_case O "g20,s130,g20" "cego=650s" parcial "ps que falhou por 650 s (ps_ok falso) é tempo cego: parcial, não conta"
  night_case P "g20,c130,g20" "cego=650s" parcial "launchctl que falhou por 650 s (lc_ok falso) é tempo cego: parcial, não conta"
  night_case Q "g20,h700,g20" "cego=700s" parcial "máquina parada 700 s (buraco no tempo, nenhum tick) é tempo cego: parcial, não conta"
  night_case R "p50" "cego=tudo" parcial "arquivo só com ticks pulados (nenhuma leitura): 'cego=tudo parcial', nunca 0 s"
  night_case S "-" "cego=?" parcial "arquivo da noite ausente apesar do rc=0: 'cego=? parcial' (não sei ≠ 0 s cego)"
  night_case T "junk" "cego=?" parcial "arquivo só com lixo: 'cego=? parcial' (não sei ≠ 0 s cego)"
  night_case U "g20,p130" "cego=650s" parcial "disco baixo até o fim da noite (cauda de 650 s): parcial"
  night_case V "p130,g20" "cego=650s" parcial "disco baixo desde o começo (cabeça de 650 s): parcial"
  night_case W "g20,p2,g20,p3,g20" "cego=15s" conta "2 ticks perdidos (≤ 3 passos) não contam; 3 contam 15 s: cego=15s, noite vale"
  JRL_BLIND_MAX=595 night_case X1 "g20,p119,g20" "cego=595s" conta "fronteira: cego=595s com limite 595 AINDA conta"
  JRL_BLIND_MAX=594 night_case X2 "g20,p119,g20" "cego=595s" parcial "fronteira: cego=595s com limite 594 NÃO conta"
  # log novo: as noites no formato com cego= contam, as parcial não
  run Z "${N17}2026-10-20T05:10:01 noite 20261020 rc=0 cego=0s
2026-10-21T05:10:02 noite 20261021 rc=0 parcial cego=700s
2026-10-22T05:10:03 noite 20261022 rc=0 cego=235s
" 202610220600 "0 202610230511
"
  [ "$(nl "$(calls Z probe.calls)")" = 1 ] && logl Z | grep -q 'noite 20261023 rc=0 cego=0s$' && logl Z | tail -1 | grep -q 'fim: 4 noites completas'; ok $? "log no formato novo: 17 + 20 + 22 contam (21 parcial não): 3 noites, a de 23/10 é a 4ª"
  # limite de cegueira que não é número: recusa na partida (com `[ x -gt abc ]` falhando, toda noite viraria completa)
  JRL_BLIND_MAX=abc run B1 "$N3" 202610220200 "0 202610220511
"
  [ "$(rc_of B1)" = 2 ] && [ ! -e "$T/B1/probe.calls" ] && [ ! -e "$T/B1/lc.calls" ] && ! plist_gone B1 && grep -q 'JRL_BLIND_MAX precisam ser números' "$T/B1/out"; ok $? "JRL_BLIND_MAX não numérico: exit 2, não mede, não mexe no agente"
  # o plist que não saiu é dito
  PLIST_AS_DIR=1 run Y "$N17" 202610230531 ""
  [ "$(rc_of Y)" = 0 ] && [ "$(calls Y lc.calls)" = "$BOOT" ] && ! plist_gone Y && logl Y | grep -q 'AVISO: não consegui apagar .*; o agente continua instalado'; ok $? "rm que falha: o log diz 'AVISO: não consegui apagar', o bootout ainda roda e o exit é 0"
  run Y2 "$N17" 202610230531 ""
  ! logl Y2 | grep -q 'AVISO'; ok $? "rm que funciona: nenhum AVISO no log"
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
  mutant "volta tardia não é marcada parcial" '/\[ "\$hm" -ge 400 \]/s/ && late=" parcial"/ \&\& :/'
  mutant "volta parcial conta como noite" 's/ && \$5 != "parcial"//'
  mutant "limite das 04:00 vira 04:01" 's/\[ "\$hm" -ge 400 \]/[ "$hm" -ge 401 ]/'
  mutant "fim não apaga o plist" 's/^  rm -f "\$AGENT_PLIST"$/  :/'
  mutant "fim não dá bootout" 's/^  "\$LAUNCHCTL" bootout .*$/  :/'
  mutant "6 falhas não desistem" 's/^    \[ "\$fails" -ge 6 \] && { log "desisto: \$fails falhas seguidas (última.*$/    :/'
  mutant "hora ilegível vira hora" 's/^  if ! isnum "\$now" || \[ "\${#now}" -ne 12 \]; then.*$/  if false; then/'
  mutant "probe sem o piso de amostragem" 's/ --skip-free-gb 3//'
  mutant "falha não conta como falha seguida (nunca desiste)" 's/^    fails=\$((fails + 1))$/    fails=0/'
  mutant "noite cega conta como completa" 's/\[ "\$b" -gt "\$BLIND_MAX" \] && late=" parcial"/:/'
  mutant "cego no limite (>=) já não vale" 's/"\$b" -gt "\$BLIND_MAX"/"$b" -ge "$BLIND_MAX"/'
  mutant "cego=? / tudo não é parcial" 's/else cego=" cego=\$b"; late=" parcial"; fi/else cego=" cego=$b"; fi/'
  mutant "tick pulado não é tempo cego" 's/\/"pulado"|"ps_ok":false/\/"ps_ok":false/'
  mutant "ps_ok falso não é tempo cego" 's/|"ps_ok":false|/|/'
  mutant "lc_ok falso não é tempo cego" 's/|"lc_ok":false\//\//'
  mutant "buraco no tempo não é tempo cego" 's/ else if (t - prev > 3 \* iv) blind += t - prev - iv;//'
  mutant "buraco de 1 passo já é cego" 's/t - prev > 3 \* iv/t - prev > 1 * iv/'
  mutant "cauda cega não conta" 's/print int(blind + (last - prev))/print int(blind)/'
  mutant "cabeça cega não conta" 's/blind += t - first; good = 1/good = 1/'
  mutant "sem leitura boa vira 0 s cego" 's/if (!good) { print "tudo"; exit 0 }/if (!good) { print 0; exit 0 }/'
  mutant "arquivo sem tick vira 'tudo' em vez de '?'" 's/if (!seen) exit 3; //'
  mutant "data-limite não diz as noites" '/data-limite \$DEADLINE passou/s/; \$n de \$NIGHTS noites completas//'
  mutant "noite depois da data-limite não diz as noites" '/acaba (05:10) depois da data-limite/s/; \$n de \$NIGHTS noites completas//'
  mutant "limite de cegueira não numérico passa" 's/ && isnum "\$BLIND_MAX" ||/ ||/'
  mutant "plist que não saiu não é dito" 's/^  \[ ! -e "\$AGENT_PLIST" \] || log .*$/  :/'
  echo "== mutantes: $((n-fails))/$n ok no total =="
}
[ "$fails" = 0 ]
