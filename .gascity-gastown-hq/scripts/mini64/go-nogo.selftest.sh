#!/usr/bin/env bash
# go-nogo.selftest.sh — testa scripts/mini64/go-nogo.sh (ga-ke5w2ie.3) SEM tocar na máquina: todo comando externo é um stub num PATH isolado.
#
# ## Contents
#   Simulado · Seções · Como rodar
#
# SIMULADO  o script roda com `env -i` num PATH só com utilitários básicos (links) e stubs de bd, gc, python3 (o imparavel-check), launchctl, pgrep/ps/lsof (porta do Dolt), curl, adb, cloudflared, df, sysctl e date; cada stub lê o
#   modo dele em $W/world e anota a chamada em $W/calls.log. Comando AUSENTE = stub sem link no PATH. Nada real é lido, parado ou gravado fora de $W.
# SEÇÕES    tudo ok · uma falha · comando ausente · estouro · leitura vazia · precedência · porta do Dolt · espera esperada · horário-limite · teto do timeout · somente leitura · fronteiras e formatos · arquivos de dados · bash 3.2
# COMO RODAR  bash scripts/mini64/go-nogo.selftest.sh   ·   GONOGO_ST_SUT=<arquivo> · GONOGO_ST_BASH=<bash que roda o script> · GONOGO_ST_B32=<bash 3.2: confere o -n> · GONOGO_ST_FAILFAST=1 · GONOGO_ST_ONLY=<trecho do título da seção>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${GONOGO_ST_SUT:-$HERE/go-nogo.sh}"
[ -f "$SUT" ] || { echo "FATAL: go-nogo.sh não encontrado em $SUT"; exit 1; }
BASH_UT="$(command -v "${GONOGO_ST_BASH:-bash}")" || { echo "FATAL: bash não encontrado"; exit 1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/gonogo-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
case "$W" in */gonogo-selftest.??????) ;; *) echo "FATAL: diretório de trabalho estranho: $W"; exit 1 ;; esac
DOLT_PID=""; : > "$W/calls.log"
trap '[ -n "$DOLT_PID" ] && kill "$DOLT_PID" 2>/dev/null; chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0; OUT=""; ERR=""; RC=0; SUT_ARGS=""; EXTRA=""; SKIP=0
ok()   { [ "$SKIP" = 1 ] && return 0; PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { [ "$SKIP" = 1 ] && return 0; FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "$OUT" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 26; [ -n "$ERR" ] && printf '%s\n' "$ERR" | sed 's/^/        ! /' | tail -n 5; [ "${GONOGO_ST_FAILFAST:-0}" = 1 ] && { echo "(FAILFAST) $PASS ok, $FAIL FAIL"; exit 1; }; return 0; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
has()   { case "$1" in *"$2"*) ok "$3" ;; *) nope "$3 (faltou: $2)" ;; esac; }
hasnt() { case "$1" in *"$2"*) nope "$3 (não devia ter: $2)" ;; *) ok "$3" ;; esac; }
section() { if [ -n "${GONOGO_ST_ONLY:-}" ] && [ "${1#*"$GONOGO_ST_ONLY"}" = "$1" ]; then SKIP=1; return 0; fi; SKIP=0; printf '\n== %s\n' "$1"; }
C="$W/city"; WA="$W/wa"
mkdir -p "$W/bin" "$W/stubs" "$W/world" "$W/home" "$W/tmp" "$C/scripts" "$C/.gc/runtime/packs/dolt" "$C/.beads" "$WA"
for t in awk sed grep cut tr head tail cat mktemp rm rmdir sleep pkill basename dirname wc sort uniq mkdir touch chmod ls id uname hostname tee; do
  p="$(command -v "$t")" || { echo "FATAL: utilitário $t não encontrado no host"; exit 1; }
  case "$p" in /*) ln -s "$p" "$W/bin/$t" ;; *) echo "FATAL: $t sem caminho absoluto: $p"; exit 1 ;; esac
done
REAL_DATE="$(command -v date)" || { echo "FATAL: date"; exit 1; }
: > "$C/scripts/imparavel-check.py"
sleep 600 >/dev/null 2>&1 </dev/null &
DOLT_PID=$!; disown "$DOLT_PID" 2>/dev/null   # o 3.2 imprimiria "Terminated" ao matar este sleep na saída
# stubs: um arquivo por comando; a 1ª linha anota a chamada e o modo vem de $W_WORLD
mkstub() { { printf '#!/bin/bash\necho "%s $*" >> "$W_CALLS"\n' "$1"; cat; } > "$W/stubs/$1"; chmod +x "$W/stubs/$1"; }
mkstub bd <<'S'
key=outro; [ "$2" = "$W_CITY" ] && key=hq; [ "$2" = "$W_WA" ] && key=wa
case "$(cat "$W_WORLD/bd.$key" 2>/dev/null || echo ok)" in
  (ok) echo '[]' ;; (vazio) ;; (lixo) echo '<html>502 Bad Gateway</html>' ;; (lento) sleep 2; echo '[]' ;; (trava) exec sleep 30 ;;
  (falha) echo 'Error: dial tcp 127.0.0.1:52756: connect: connection refused' >&2; exit 1 ;;
esac
S
mkstub gc <<'S'
case "$(cat "$W_WORLD/gc" 2>/dev/null || echo ok)" in (ok) echo "ID  TEMPLATE  STATE" ;; (falha) echo 'gc: supervisor not running' >&2; exit 1 ;; (trava) exec sleep 30 ;; esac
S
mkstub python3 <<'S'
case "$(cat "$W_WORLD/imparavel" 2>/dev/null || echo ok)" in
  (ok) echo "VEREDITO: ✅ IMPARÁVEL agora" ;; (nogo) echo "VEREDITO: ❌ NÃO IMPARÁVEL"; exit 1 ;; (semlinha) echo "relatório sem veredito" ;; (trava) exec sleep 30 ;;
  (incerto) echo "VEREDITO: ⚠️  INCERTO (não posso afirmar ✅ com honestidade)"; exit 2 ;; (diverge) echo "VEREDITO: ✅ IMPARÁVEL agora"; exit 1 ;;
  (crash) echo "Traceback (most recent call last):" >&2; exit 1 ;;
esac
S
mkstub launchctl <<'S'
[ "$1" = list ] || { echo "launchctl: verbo inesperado: $1" >&2; exit 64; }
m=$(cat "$W_WORLD/launchd/$2" 2>/dev/null || echo ausente)
case "$m" in
  (pid:*) printf '{\n\t"Label" = "%s";\n\t"LastExitStatus" = 0;\n\t"PID" = %s;\n};\n' "$2" "${m#pid:}" ;;
  (carregado) printf '{\n\t"Label" = "%s";\n\t"LastExitStatus" = 0;\n};\n' "$2" ;;
  (ausente) echo "Could not find service \"$2\" in domain for port" >&2; exit 113 ;;
  (lixo) echo ok ;; (falha) echo "launchctl: operation not permitted" >&2; exit 1 ;; (trava) exec sleep 30 ;;
esac
S
mkstub pgrep <<'S'
case "$(cat "$W_WORLD/dolt.mode" 2>/dev/null || echo ok)" in (nenhum) exit 1 ;; (trava) exec sleep 30 ;; esac; cat "$W_WORLD/dolt.pid"; echo
S
mkstub ps <<'S'
case "$(cat "$W_WORLD/dolt.mode" 2>/dev/null || echo ok)" in (naodolt) echo python3 ;; (*) echo /usr/local/bin/dolt ;; esac
S
mkstub lsof <<'S'
case "$(cat "$W_WORLD/dolt.mode" 2>/dev/null || echo ok)" in (semescuta) exit 1 ;; (trava) exec sleep 30 ;; esac
case "$*" in (*-Fn*) printf 'p%s\nn127.0.0.1:%s\n' "$(cat "$W_WORLD/dolt.pid")" "$(cat "$W_WORLD/dolt.port")" ;; esac
S
mkstub curl <<'S'
url=""; for a in "$@"; do url="$a"; done; rest="${url#http://127.0.0.1:}"
m=$(cat "$W_WORLD/curl.${rest%%/*}" 2>/dev/null || echo 200)
case "$m" in (200|401|403|404|500|502|302|301) printf '%s' "$m" ;; (recusada) printf 000; exit 7 ;; (estouro) printf 000; exit 28 ;; (lixo) printf xyz ;; (trava) exec sleep 30 ;; esac
S
mkstub adb <<'S'
[ "$1" = devices ] || { echo "adb: verbo inesperado: $1" >&2; exit 64; }
case "$(cat "$W_WORLD/adb.mode" 2>/dev/null || echo ok)" in (ok) cat "$W_WORLD/adb.out" ;; (falha) echo "adb: failed to check server version" >&2; exit 1 ;; (trava) exec sleep 30 ;; esac
S
mkstub cloudflared <<'S'
[ "$1 $2" = "tunnel info" ] || { echo "cloudflared: verbo inesperado: $*" >&2; exit 64; }
case "$(cat "$W_WORLD/cf.mode" 2>/dev/null || echo ok)" in (ok) cat "$W_WORLD/cf.info" ;; (falha) echo "Cannot determine default origin certificate path" >&2; exit 1 ;; (trava) exec sleep 30 ;; esac
S
mkstub df <<'S'
H='Filesystem    1048576-blocks   Used Available Capacity Mounted on'
case "$(cat "$W_WORLD/df.mode" 2>/dev/null || echo ok)" in
  (ok) printf '%s\n/dev/disk3s5 953344 441344 %s 47%% %s\n' "$H" "$(cat "$W_WORLD/df.free")" "${*: -1}" ;;
  (outromontagem) printf '%s\n/dev/disk3s1s1 953344 11000 %s 2%% /\n' "$H" "$(cat "$W_WORLD/df.free")" ;;
  (lixo) echo "df: sem resposta" ;; (falha) echo "df: No such file or directory" >&2; exit 1 ;; (trava) exec sleep 30 ;;
esac
S
mkstub sysctl <<'S'
case "$(cat "$W_WORLD/sysctl.mode" 2>/dev/null || echo ok)" in (ok) cat "$W_WORLD/swap" ;; (lixo) echo "vm.swapusage: ?" ;; (falha) echo "sysctl: unknown oid" >&2; exit 1 ;; (trava) exec sleep 30 ;; esac
S
printf '#!/bin/bash\nif [ "$1" = "+%%H%%M" ] && [ -e "$W_WORLD/now_hhmm" ]; then [ "$(cat "$W_WORLD/now_hhmm")" = FALHA ] && exit 1; cat "$W_WORLD/now_hhmm"; exit 0; fi\nexec "$W_REAL_DATE" "$@"\n' > "$W/stubs/date"; chmod +x "$W/stubs/date"
STUBS_ALL="bd gc python3 launchctl pgrep ps lsof curl adb cloudflared df sysctl date"
unlink_tool() { rm -f "$W/bin/$1"; }
swap_is() { printf 'total = 9G  used = %s  free = 1M\n' "$1" > "$W/world/swap"; }
TUNNEL_ID="6ff42ae2-765d-4adf-8112-31c55c1551ef"
world_ok() {  # o mundo saudável; cada caso muda UMA coisa
  local t; rm -rf "$W/world" "$W/home" "$W/tmp"; mkdir -p "$W/world/launchd" "$W/home/.cloudflared" "$W/tmp"
  for t in $STUBS_ALL; do [ -e "$W/bin/$t" ] || ln -s "$W/stubs/$t" "$W/bin/$t"; done
  printf '%s' "$DOLT_PID" > "$W/world/dolt.pid"; printf '52756' > "$W/world/dolt.port"
  printf 'pid:4242' > "$W/world/launchd/com.gascity.supervisor"; printf 'pid:6161' > "$W/world/launchd/br.urblink.cloudflared.urblink-ops"
  printf 'carregado' > "$W/world/launchd/com.gascity.pilot"; printf 'carregado' > "$W/world/launchd/com.gascity.quality-gate-dispatcher"
  printf 'List of devices attached\nSERIAL1\tdevice\nSERIAL2\tdevice\n\n' > "$W/world/adb.out"
  printf 'NAME:     urblink-ops\nID:       %s\nCREATED:  2024-01-01 00:00:00 +0000 UTC\n\nCONNECTOR ID                         CREATED              ARCHITECTURE VERSION  ORIGIN IP    EDGE\n8f7a9b2c-1111-4222-8333-444455556666 2025-11-26T07:00:00Z darwin_arm64 2025.11.0 203.0.113.9 2xgru01, 2xgru02\n' "$TUNNEL_ID" > "$W/world/cf.info"
  printf '512000' > "$W/world/df.free"; swap_is 0.00M; printf '0412' > "$W/world/now_hhmm"
  : > "$W/home/.mini64-espera"; printf '# config\ntunnel: %s\ncredentials-file: /x/%s.json\n' "$TUNNEL_ID" "$TUNNEL_ID" > "$W/home/.cloudflared/urblink-ops.yml"
  printf '# nome\tporta\tcaminho\nalpha\t8101\t/\nbeta\t8102\t/health\ngamma\t8103\t/api/x\n' > "$W/paineis.tsv"; printf '# serial\tapelido\nSERIAL1\tcel-1\nSERIAL2\tcel-2\n' > "$W/celulares.tsv"
  printf '1111\n' > "$C/.beads/dolt-server.port"; SUT_ARGS=""; EXTRA=""
}
run_sut() {  # run_sut [VAR=valor ...]   (argumentos do script em SUT_ARGS)
  [ "$SKIP" = 1 ] && return 0
  : > "$W/calls.log"
  OUT=$(env -i PATH="$W/bin" HOME="$W/home" TMPDIR="$W/tmp" LC_ALL=C GC_CITY_PATH="$C" W_WORLD="$W/world" W_CALLS="$W/calls.log" W_CITY="$C" W_WA="$WA" W_REAL_DATE="$REAL_DATE" \
    GONOGO_EXTRA_PATH="" GONOGO_BD_STORES="hq=$C wa=$WA" GONOGO_PAINEIS="$W/paineis.tsv" GONOGO_CELULARES="$W/celulares.tsv" GONOGO_IMPARAVEL="$C/scripts/imparavel-check.py" GONOGO_TIMEOUT=3 \
    "$@" "$BASH_UT" "$SUT" $SUT_ARGS 2>"$W/err"); RC=$?
  ERR=$(<"$W/err")
}
# leitores da saída em bash puro (cada fork a menos pesa: o selftest roda o script ~150 vezes)
line_of()  { local l t n r; while IFS= read -r l; do case "$l" in "["*) ;; *) continue ;; esac; read -r t n r <<< "$l"; if [ "$n" = "$1" ]; then printf '%s' "$l"; return 0; fi; done <<< "$OUT"; return 0; }
state_of() { local l t n r; while IFS= read -r l; do case "$l" in "["*) ;; *) continue ;; esac; read -r t n r <<< "$l"; if [ "$n" = "$1" ]; then t="${t#\[}"; printf '%s' "${t%\]}"; return 0; fi; done <<< "$OUT"; return 0; }
count_tag() { local l c=0; while IFS= read -r l; do case "$l" in "[$1]"*) c=$((c + 1)) ;; esac; done <<< "$OUT"; printf '%s' "$c"; }
last_line() { printf '%s' "${OUT##*$'\n'}"; }
ALL_CHECKS="dolt-porta bd-hq bd-wa supervisor pilot gate gc imparavel painel-alpha painel-beta painel-gamma adb cloudflared-job cloudflared-conectores disco swap espera envio"
t() {  # t <descrição> <preparo (eval)> <checagem> <estado> [trecho na linha]   (o preparo pode pôr UMA VAR=valor em EXTRA e argumentos do script em SUT_ARGS)
  world_ok; eval "$2"; run_sut ${EXTRA:+"$EXTRA"}
  eq "$(state_of "$3")" "$4" "$1: $3 = $4"
  [ -z "${5:-}" ] || has "$(line_of "$3")" "$5" "$1: a linha diz '$5'"
}
nogo_case() {  # $1=descrição $2=checagem $3=preparo $4=trecho
  world_ok; eval "$3"; run_sut
  eq "$(state_of "$2")" "NO-GO" "$1: $2 = NO-GO"; has "$(line_of "$2")" "$4" "$1: a linha diz '$4'"; eq "$RC" "1" "$1: rc 1"
  eq "$(count_tag NO-GO)/$(count_tag INCERTO)" "1/0" "$1: só essa checagem mudou"; has "$(last_line)" "VEREDITO: NO-GO" "$1: veredito NO-GO"
}
inc_case() {  # $1=descrição $2=checagem $3=preparo $4=trecho $5=quantas linhas INCERTO
  world_ok; eval "$3"; run_sut
  eq "$(state_of "$2")" "INCERTO" "$1: $2 = INCERTO"; has "$(line_of "$2")" "$4" "$1: a linha diz '$4'"; eq "$RC" "2" "$1: rc 2"
  eq "$(count_tag NO-GO)/$(count_tag INCERTO)" "0/$5" "$1: ninguém mais mudou"; has "$(last_line)" "VEREDITO: INCERTO" "$1: veredito INCERTO"; hasnt "$(last_line)" "VEREDITO: GO" "$1: nunca GO"
}

section "tudo ok → GO"
world_ok; run_sut
eq "$RC" "0" "rc 0"; has "$(last_line)" "VEREDITO: GO" "a última linha é o veredito GO"
for c in $ALL_CHECKS; do eq "$(state_of "$c")" "OK" "$c = OK"; done
eq "$(count_tag OK)/$(count_tag NO-GO)/$(count_tag INCERTO)" "18/0/0" "18 checagens, uma linha cada, todas OK"
eq "$ERR" "" "nada no stderr"; has "$OUT" "timeout por checagem: 3 s" "o cabeçalho diz o timeout em uso"
eq "$(ls "$W/tmp" | wc -l | tr -d ' ')" "0" "o script não deixa arquivo temporário"

section "uma falha → NO-GO (uma por checagem)"
nogo_case "imparavel diz NÃO IMPARÁVEL" imparavel 'echo nogo > "$W/world/imparavel"' "NÃO IMPARÁVEL"
nogo_case "painel com HTTP 500" painel-beta 'echo 500 > "$W/world/curl.8102"' "HTTP 500"
nogo_case "painel com HTTP 302 (só 200/401/403 valem)" painel-beta 'echo 302 > "$W/world/curl.8102"' "HTTP 302"
nogo_case "painel com conexão recusada (nada escuta)" painel-gamma 'echo recusada > "$W/world/curl.8103"' "recusada"
nogo_case "celular que não aparece no adb" adb 'printf "List of devices attached\nSERIAL1\tdevice\n\n" > "$W/world/adb.out"' "cel-2"
nogo_case "celular unauthorized" adb 'printf "List of devices attached\nSERIAL1\tdevice\nSERIAL2\tunauthorized\n\n" > "$W/world/adb.out"' "unauthorized"
nogo_case "celular offline" adb 'printf "List of devices attached\nSERIAL1\toffline\nSERIAL2\tdevice\n\n" > "$W/world/adb.out"' "offline"
nogo_case "2 conectores no túnel (o antigo ainda vivo)" cloudflared-conectores 'printf "8f7a9b2c-aaaa-4222-8333-444455556666 2025-11-20T07:00:00Z darwin_arm64 2025.11.0 198.51.100.7 1xgru01\n" >> "$W/world/cf.info"' "2 conectores"
nogo_case "disco abaixo do piso" disco 'printf 1000 > "$W/world/df.free"' "abaixo do piso"
nogo_case "swap acima do teto" swap 'swap_is 3072.50M' "acima do teto"
nogo_case "marcador de espera ausente (esperado: ligada)" espera 'rm -f "$W/home/.mini64-espera"' "marcador ausente"
nogo_case "supervisor carregado sem PID" supervisor 'printf carregado > "$W/world/launchd/com.gascity.supervisor"' "sem PID"
nogo_case "supervisor fora do launchd" supervisor 'rm -f "$W/world/launchd/com.gascity.supervisor"' "não está carregado"
nogo_case "pilot fora do launchd" pilot 'rm -f "$W/world/launchd/com.gascity.pilot"' "não está carregado"
nogo_case "dispatcher do gate fora do launchd" gate 'rm -f "$W/world/launchd/com.gascity.quality-gate-dispatcher"' "não está carregado"
nogo_case "túnel cloudflared fora do launchd" cloudflared-job 'rm -f "$W/world/launchd/br.urblink.cloudflared.urblink-ops"' "não está carregado"
nogo_case "central-sender carregado com a espera ligada (pode estar enviando)" envio 'printf pid:7777 > "$W/world/launchd/com.whatsapp.central-sender"' "carregado"
t "dispatcher do gate com PID (job de intervalo: PID é opcional)" 'printf pid:4242 > "$W/world/launchd/com.gascity.quality-gate-dispatcher"' gate OK
t "painel atrás de login: 401" 'echo 401 > "$W/world/curl.8101"' painel-alpha OK
t "painel atrás de login: 403" 'echo 403 > "$W/world/curl.8101"' painel-alpha OK

section "comando ausente → INCERTO (nunca GO)"
inc_case "bd ausente" bd-hq 'unlink_tool bd' "bd ausente" 2
inc_case "gc ausente" gc 'unlink_tool gc' "gc ausente" 1
inc_case "python3 ausente (imparavel)" imparavel 'unlink_tool python3' "python3 ausente" 1
inc_case "curl ausente" painel-alpha 'unlink_tool curl' "curl ausente" 3
inc_case "adb ausente" adb 'unlink_tool adb' "adb ausente" 1
inc_case "cloudflared ausente" cloudflared-conectores 'unlink_tool cloudflared' "cloudflared ausente" 1
inc_case "launchctl ausente" supervisor 'unlink_tool launchctl' "launchctl ausente" 5
inc_case "df ausente" disco 'unlink_tool df' "df ausente" 1
inc_case "sysctl ausente" swap 'unlink_tool sysctl' "sysctl ausente" 1
inc_case "lsof ausente (porta do Dolt)" dolt-porta 'unlink_tool lsof' "sem porta viva" 1
inc_case "pgrep ausente (porta do Dolt)" dolt-porta 'unlink_tool pgrep' "sem porta viva" 1
inc_case "ps ausente (porta do Dolt)" dolt-porta 'unlink_tool ps' "sem porta viva" 1

section "estouro de prazo → INCERTO (timeout por checagem, sem pendurar o script)"
world_ok
for f in bd.hq bd.wa gc imparavel curl.8101 curl.8102 curl.8103 adb.mode cf.mode df.mode sysctl.mode dolt.mode launchd/com.gascity.supervisor launchd/com.gascity.pilot launchd/com.gascity.quality-gate-dispatcher launchd/br.urblink.cloudflared.urblink-ops launchd/com.whatsapp.central-sender; do echo trava > "$W/world/$f"; done
T0=$SECONDS; run_sut GONOGO_TIMEOUT=1; T1=$SECONDS
eq "$RC" "2" "tudo pendurado: rc 2"; has "$(last_line)" "VEREDITO: INCERTO" "tudo pendurado: INCERTO"
for c in $ALL_CHECKS; do
  [ "$c" = espera ] && continue
  eq "$(state_of "$c")" "INCERTO" "$c pendurado = INCERTO"; has "$(line_of "$c")" "estourou 1 s" "$c: a linha diz que estourou 1 s"
done
eq "$(state_of espera)" "OK" "a checagem que não chama comando (espera) segue OK"
[ $((T1 - T0)) -le 40 ] && ok "o script terminou (${T0}→${T1}: 17 estouros de 1 s cabem em 40 s)" || nope "o script demorou $((T1 - T0)) s com tudo pendurado"
eq "$(ls "$W/tmp" | wc -l | tr -d ' ')" "0" "depois do estouro também não sobra arquivo temporário"
inc_case "só o bd pendura" bd-hq 'echo trava > "$W/world/bd.hq"' "estourou" 1
t "bd list lento (2 s com limite de 1 s)" 'echo lento > "$W/world/bd.hq"; EXTRA=GONOGO_BD_SLOW_S=1' bd-hq INCERTO "lento"

section "leitura vazia/ilegível/falha → INCERTO (nunca GO, nunca NO-GO por palpite)"
inc_case "bd rc 1" bd-wa 'echo falha > "$W/world/bd.wa"' "falhou (rc 1)" 1
inc_case "bd rc 0 com HTML" bd-hq 'echo lixo > "$W/world/bd.hq"' "ilegível" 1
inc_case "bd rc 0 sem saída" bd-hq 'echo vazio > "$W/world/bd.hq"' "ilegível" 1
inc_case "gc rc 1" gc 'echo falha > "$W/world/gc"' "falhou (rc 1)" 1
inc_case "imparavel quebrou (rc 1 sem veredito): crash não é NÃO IMPARÁVEL" imparavel 'echo crash > "$W/world/imparavel"' "sem linha VEREDITO" 1
inc_case "imparavel rc 1 mas a linha diz IMPARÁVEL" imparavel 'echo diverge > "$W/world/imparavel"' "não bate" 1
inc_case "imparavel rc 0 sem linha de veredito" imparavel 'echo semlinha > "$W/world/imparavel"' "sem linha VEREDITO" 1
inc_case "imparavel INCERTO (rc 2)" imparavel 'echo incerto > "$W/world/imparavel"' "INCERTO" 1
inc_case "script do imparavel ausente" imparavel 'rm -f "$C/scripts/imparavel-check.py"' "ausente" 1
: > "$C/scripts/imparavel-check.py"
inc_case "lista de painéis ausente" paineis 'rm -f "$W/paineis.tsv"' "ausente" 1
inc_case "lista de painéis sem nenhuma linha" paineis 'printf "# nome\tporta\tcaminho\n" > "$W/paineis.tsv"' "nenhum painel" 1
world_ok; printf 'alpha\t8101\t/\nruim\tabc\t/x\nbeta\t8102\t/health\n' > "$W/paineis.tsv"; run_sut
eq "$(state_of paineis)/$RC" "INCERTO/2" "linha de painel com porta que não é número: INCERTO"
has "$(line_of paineis)" "linha 2" "a linha diz qual linha do arquivo"
eq "$(state_of painel-alpha)/$(state_of painel-beta)" "OK/OK" "as linhas boas continuam sendo checadas"
inc_case "curl rc 28 (sem resposta)" painel-alpha 'echo estouro > "$W/world/curl.8101"' "rc 28" 1
inc_case "curl rc 0 com código que não é número" painel-alpha 'echo lixo > "$W/world/curl.8101"' "ilegível" 1
inc_case "lista de celulares ausente" adb 'rm -f "$W/celulares.tsv"' "ausente" 1
inc_case "lista de celulares sem nenhum serial" adb 'printf "# serial\tapelido\n" > "$W/celulares.tsv"' "lista vazia" 1
inc_case "adb rc 1" adb 'echo falha > "$W/world/adb.mode"' "falhou (rc 1)" 1
inc_case "adb sem o cabeçalho conhecido" adb 'printf "algo estranho\n" > "$W/world/adb.out"' "ilegível" 1
inc_case "cloudflared rc 1 (sem cert)" cloudflared-conectores 'echo falha > "$W/world/cf.mode"' "falhou (rc 1)" 1
inc_case "cloudflared com texto que não reconheço" cloudflared-conectores 'printf "algo estranho\n" > "$W/world/cf.info"' "sem a linha ID:" 1
inc_case "cloudflared com uma linha de conector mas sem o cabeçalho ID: (nunca conta)" cloudflared-conectores 'printf "8f7a9b2c-1111-4222-8333-444455556666 2025-11-26T07:00:00Z\n" > "$W/world/cf.info"' "sem a linha ID:" 1
inc_case "cloudflared sem nenhuma linha de conector (túnel fora ou formato mudou: não sei qual)" cloudflared-conectores 'printf "NAME:     urblink-ops\nID:       %s\n" "$TUNNEL_ID" > "$W/world/cf.info"' "0 conectores lidos" 1
inc_case "config do túnel ausente" cloudflared-conectores 'rm -f "$W/home/.cloudflared/urblink-ops.yml"' "config" 1
inc_case "config do túnel sem a chave tunnel:" cloudflared-conectores 'printf "ingress:\n  - service: http_status:404\n" > "$W/home/.cloudflared/urblink-ops.yml"' "tunnel" 1
inc_case "df com resposta que não é tabela" disco 'echo lixo > "$W/world/df.mode"' "ilegível" 1
inc_case "df de OUTRO volume (a raiz selada, não o Data)" disco 'echo outromontagem > "$W/world/df.mode"' "ilegível" 1
inc_case "df rc 1" disco 'echo falha > "$W/world/df.mode"' "falhou" 1
inc_case "sysctl sem o swap legível" swap 'echo lixo > "$W/world/sysctl.mode"' "ilegível" 1
inc_case "sysctl com unidade que não conheço" swap 'swap_is 12,00K' "ilegível" 1
inc_case "launchctl devolve texto sem o dicionário do job" supervisor 'echo lixo > "$W/world/launchd/com.gascity.supervisor"' "sem dicionário" 1
inc_case "launchctl rc 1 que não é 'Could not find service'" pilot 'echo falha > "$W/world/launchd/com.gascity.pilot"' "launchctl" 1
t "marcador que é uma pasta (existe e não é arquivo legível)" 'rm -f "$W/home/.mini64-espera"; mkdir "$W/home/.mini64-espera"' espera INCERTO "não é um arquivo legível"
t "marcador numa pasta que não existe (ausente ≠ não consigo olhar)" 'EXTRA="GONOGO_ESPERA_MARCADOR=$W/nao-existe/marcador"' espera INCERTO "não consigo olhar"

section "precedência: uma falha confirmada vence o incerto"
world_ok; echo 500 > "$W/world/curl.8101"; printf 1000 > "$W/world/df.free"; echo falha > "$W/world/gc"; run_sut
eq "$RC" "1" "2 falhas + 1 incerto: rc 1"; has "$(last_line)" "VEREDITO: NO-GO — 2 falha(s), 1 incerto(s)" "o resumo conta as falhas e os incertos"

section "porta do Dolt: do processo vivo, nunca de arquivo"
t "porta lida do lsof do pid que o pgrep achou (o arquivo diz 1111)" 'true' dolt-porta OK "porta viva 52756"
t "GC_DOLT_PORT_OVERRIDE no ambiente é ignorado" 'EXTRA=GC_DOLT_PORT_OVERRIDE=9999' dolt-porta OK "porta viva 52756"
hasnt "$(line_of dolt-porta)" "9999" "o override não aparece"
inc_case "nenhum processo dolt + arquivo de porta com 1111 (nunca lê o arquivo)" dolt-porta 'echo nenhum > "$W/world/dolt.mode"' "sem porta viva" 1
hasnt "$(line_of dolt-porta)" "1111" "a porta do arquivo não vira resposta"
t "sem processo e com override no ambiente" 'echo nenhum > "$W/world/dolt.mode"; EXTRA=GC_DOLT_PORT_OVERRIDE=9999' dolt-porta INCERTO "sem porta viva"
inc_case "processo que não se chama dolt" dolt-porta 'echo naodolt > "$W/world/dolt.mode"' "sem porta viva" 1
inc_case "processo dolt sem porta em LISTEN" dolt-porta 'echo semescuta > "$W/world/dolt.mode"' "sem porta viva" 1
world_ok; run_sut; has "$(cat "$W/calls.log")" "-iTCP -sTCP:LISTEN" "a porta foi pedida ao lsof do processo"

section "espera esperada (--espera)"
D='rm -f "$W/home/.mini64-espera"; printf pid:7777 > "$W/world/launchd/com.whatsapp.central-sender"; SUT_ARGS="--espera desligada"'
t "desligada: marcador ausente e sender rodando" "$D" espera OK; eq "$(state_of envio)/$RC" "OK/0" "desligada: envio OK e GO"
t "desligada mas o marcador existe" 'printf pid:7777 > "$W/world/launchd/com.whatsapp.central-sender"; SUT_ARGS="--espera desligada"' espera NO-GO "marcador presente"
t "desligada mas o sender não está carregado" 'rm -f "$W/home/.mini64-espera"; SUT_ARGS="--espera desligada"' envio NO-GO
t "--espera ligada explícito é o padrão" 'SUT_ARGS="--espera ligada"' espera OK; eq "$RC" "0" "ligada explícito: GO"
for a in "--espera" "--espera talvez" "--bogus"; do t "uso errado: $a" "SUT_ARGS=\"$a\"" espera ""; eq "$RC" "64" "'$a': rc 64"; eq "$(count_tag OK)" "0" "'$a': nenhuma checagem rodou"; done
world_ok; SUT_ARGS="--help"; run_sut
eq "$RC" "0" "--help: rc 0"; has "$OUT" "NO-GO" "--help explica o NO-GO"; has "$OUT" "INCERTO" "--help explica o INCERTO"; eq "$(<"$W/calls.log")" "" "--help não chama comando nenhum"

section "horário-limite 04:30"
for c in "0412|faltam 18 min" "0445|PASSOU há 15 min" "0430|faltam 0 min" "2300|faltam 330 min" "1330|faltam 900 min"; do
  world_ok; echo "${c%%|*}" > "$W/world/now_hhmm"; run_sut; has "$OUT" "PRAZO 04:30: ${c#*|}" "${c%%|*} → ${c#*|}"
done
hasnt "$OUT" "vale NO-GO" "antes do prazo a linha não ameaça"
world_ok; echo 0445 > "$W/world/now_hhmm"; run_sut; has "$OUT" "vale NO-GO" "depois do prazo a linha lembra que sem GO vale NO-GO"
world_ok; run_sut GONOGO_PRAZO=05:00; has "$OUT" "PRAZO 05:00: faltam 48 min" "GONOGO_PRAZO muda o horário"
world_ok; run_sut GONOGO_PRAZO=abc; has "$OUT" "PRAZO 04:30" "prazo inválido volta ao 04:30"; has "$OUT" "GONOGO_PRAZO inválido" "e diz que o valor era inválido"
world_ok; echo FALHA > "$W/world/now_hhmm"; run_sut; has "$OUT" "hora ilegível" "date que falha: a linha diz hora ilegível (não inventa minutos)"; eq "$RC" "0" "a hora ilegível não muda o veredito"

section "teto do timeout por checagem (≤ 20 s)"
for v in 999 0 abc -5 "" 21; do world_ok; run_sut GONOGO_TIMEOUT="$v"; has "$OUT" "timeout por checagem: 20 s" "GONOGO_TIMEOUT='$v' → 20 s"; done
for v in 7 20; do world_ok; run_sut GONOGO_TIMEOUT="$v"; has "$OUT" "timeout por checagem: $v s" "GONOGO_TIMEOUT=$v vale"; done
world_ok; OUT=$(env -i PATH="$W/bin" HOME="$W/home" TMPDIR="$W/tmp" LC_ALL=C GC_CITY_PATH="$C" W_WORLD="$W/world" W_CALLS="$W/calls.log" W_CITY="$C" W_WA="$WA" W_REAL_DATE="$REAL_DATE" GONOGO_EXTRA_PATH="" GONOGO_BD_STORES="hq=$C wa=$WA" GONOGO_PAINEIS="$W/paineis.tsv" GONOGO_CELULARES="$W/celulares.tsv" GONOGO_IMPARAVEL="$C/scripts/imparavel-check.py" "$BASH_UT" "$SUT" 2>/dev/null)
has "$OUT" "timeout por checagem: 20 s" "sem GONOGO_TIMEOUT o padrão é 20 s"

section "somente leitura: o que o script chama e o que o texto dele contém"
world_ok; run_sut
ALLOWED='^(bd -C [^ ]+ list -n 1 --json|gc session list|python3 [^ ]+imparavel-check\.py|launchctl list [A-Za-z0-9._-]+|curl .*http://127\.0\.0\.1:[0-9]+/[^ ]*|adb devices|cloudflared tunnel info [0-9a-f-]+|df -Pm /System/Volumes/Data|sysctl -n vm\.swapusage|pgrep -f dolt sql-server|ps -o comm= -p [0-9]+|lsof -nP -a -p [0-9]+ -iTCP -sTCP:LISTEN( -Fn)?)$'
eq "$(grep -Evc "$ALLOWED" "$W/calls.log")" "0" "toda chamada externa é uma leitura conhecida (nenhuma escrita)"
[ -s "$W/calls.log" ] && ok "o log de chamadas tem conteúdo (o teste prova algo)" || nope "o log de chamadas está vazio"
eq "$(grep -c '^launchctl ' "$W/calls.log")" "5" "launchctl: 5 leituras (supervisor, pilot, gate, túnel e central-sender), todas 'list'"
for pat in 'launchctl +(bootstrap|bootout|kickstart|load|unload|enable|disable|remove|submit|start|stop)' 'kill -9' 'pkill -f' 'rm -rf' '(^|[ ;])eval ' '(^|[ ;])sudo ' '(^|[ ;])git ' 'bd +(update|close|comment|create|label|dolt|sql|import)' 'adb +(kill-server|start-server|reboot|install|uninstall|shell|push|pull|connect|disconnect)' 'cloudflared +(tunnel +(run|delete|create|route|cleanup)|service|update)' '(>|>>) */(etc|usr|System|Library|var)/' 'dolt-server\.port|BEADS_DOLT_PORT' '(^|[^_a-z])dolt_server_port([^_a-z]|$)'; do
  if grep -Eq "$pat" "$SUT"; then nope "o texto do script contém um padrão proibido: $pat"; else ok "o texto do script não contém: $pat"; fi
done
grep -q 'dolt_server_live_port' "$SUT" && ok "usa dolt_server_live_port (a metade estrita: sem arquivo, sem pin)" || nope "não usa dolt_server_live_port"

section "fronteiras e formatos (disco, swap, adb, arquivos de dados)"
t "disco exatamente no piso (102400 MB)" 'printf 102400 > "$W/world/df.free"' disco OK
t "disco 1 MB abaixo do piso" 'printf 102399 > "$W/world/df.free"' disco NO-GO
t "GONOGO_DISCO_MIN_MB baixa o piso (ensaio no mini atual)" 'printf 5000 > "$W/world/df.free"; EXTRA=GONOGO_DISCO_MIN_MB=4096' disco OK
t "swap exatamente no teto (2048 MB)" 'swap_is 2048.00M' swap OK
t "swap 1 MB acima do teto" 'swap_is 2049.00M' swap NO-GO
t "swap em G: 2.50G = 2560 MB" 'swap_is 2.50G' swap NO-GO "2560 MB"
t "swap com vírgula decimal (pt_BR): 1,50G = 1536 MB" 'swap_is 1,50G' swap OK "1536 MB"
t "swap em M com vírgula decimal: 512,25M = 512 MB" 'swap_is 512,25M' swap OK "512 MB"
t "adb que sobe o daemon (linhas com *) e um aparelho a mais" 'printf "* daemon not running; starting now\n* daemon started successfully\nList of devices attached\nSERIAL1\tdevice\nSERIAL2\tdevice\nSERIAL9\tdevice\n\n" > "$W/world/adb.out"' adb OK "+1 fora da lista"
t "adb devices -l (colunas a mais)" 'printf "List of devices attached\nSERIAL1\tdevice product:x model:Y\nSERIAL2\tdevice usb:1-1\n" > "$W/world/adb.out"' adb OK
t "SERIAL10 não vale como SERIAL1 (prefixo)" 'printf "List of devices attached\nSERIAL10\tdevice\nSERIAL2\tdevice\n" > "$W/world/adb.out"' adb NO-GO
t "lista de painéis com CRLF" 'printf "alpha\t8101\t/\r\nbeta\t8102\t/health\r\n" > "$W/paineis.tsv"' painel-alpha OK; has "$(cat "$W/calls.log")" "http://127.0.0.1:8101/" "o caminho não leva o CR para a URL"
t "lista de celulares com CRLF (uma linha só com serial)" 'printf "SERIAL1\r\nSERIAL2\tcel-2\r\n" > "$W/celulares.tsv"' adb OK
t "GONOGO_BD_STORES com par sem '='" 'EXTRA="GONOGO_BD_STORES=hq=$C semcaminho"' bd-lista INCERTO
t "GONOGO_BD_STORES só com espaço" 'EXTRA="GONOGO_BD_STORES= "' bd-lista INCERTO "nenhum banco"
t "GONOGO_BD_STORES vazio vale como não definido" 'EXTRA="GONOGO_BD_STORES="' bd-wa OK
t "GONOGO_HTTP_OK com 302 aceita o redirecionamento" 'echo 302 > "$W/world/curl.8101"; EXTRA="GONOGO_HTTP_OK=200 302"' painel-alpha OK
t "GONOGO_HTTP_OK inválido volta ao padrão" 'echo 302 > "$W/world/curl.8101"; EXTRA=GONOGO_HTTP_OK=abc' painel-alpha NO-GO

section "arquivos de dados versionados"
DATA_P="$HERE/paineis.tsv"; DATA_C="$HERE/celulares.tsv"
[ -f "$DATA_P" ] && ok "paineis.tsv existe" || nope "paineis.tsv não existe ($DATA_P)"
[ -f "$DATA_C" ] && ok "celulares.tsv existe" || nope "celulares.tsv não existe ($DATA_C)"
if [ -f "$DATA_P" ]; then
  N_ROWS=0; BAD_ROWS=0; NAMES=""
  while IFS="$(printf '\t')" read -r n p c rest; do
    case "$n" in ''|'#'*) continue ;; esac
    N_ROWS=$((N_ROWS+1)); NAMES="$NAMES $n"
    case "$p" in ''|*[!0-9]*) BAD_ROWS=$((BAD_ROWS+1)) ;; esac
    case "$c" in /*) ;; *) BAD_ROWS=$((BAD_ROWS+1)) ;; esac
    case "$n" in *[!A-Za-z0-9._-]*) BAD_ROWS=$((BAD_ROWS+1)) ;; esac
  done < "$DATA_P"
  [ "$N_ROWS" -ge 1 ] && ok "paineis.tsv lista ao menos 1 painel ($N_ROWS)" || nope "paineis.tsv sem nenhum painel"
  eq "$BAD_ROWS" "0" "paineis.tsv: nome, porta numérica e caminho com / em toda linha"
  eq "$(printf '%s\n' $NAMES | sort | uniq -d | wc -l | tr -d ' ')" "0" "paineis.tsv: nomes sem repetição"
  world_ok; run_sut GONOGO_PAINEIS="$DATA_P"
  eq "$(count_tag OK)" "$((15 + N_ROWS))" "o script checa cada painel do arquivo versionado (1 linha OK por linha de dados, mais as 15 outras checagens)"
fi
if [ -f "$DATA_C" ]; then
  if grep -Eq '(\+?55 ?\(?[0-9]{2}\)? ?9?[0-9]{4}-?[0-9]{4}|\([0-9]{2}\) ?9[0-9]{4}|9[0-9]{4}-[0-9]{4})' "$DATA_C"; then nope "celulares.tsv parece ter número de telefone"; else ok "celulares.tsv não tem número de telefone"; fi
  BAD_S=0
  while IFS="$(printf '\t')" read -r s a rest; do
    case "$s" in ''|'#'*) continue ;; esac
    case "$s" in *[!A-Za-z0-9._:-]*) BAD_S=$((BAD_S+1)) ;; esac
    [ -n "$a" ] || BAD_S=$((BAD_S+1))
  done < "$DATA_C"
  eq "$BAD_S" "0" "celulares.tsv: serial (letras, números, . _ : -) e apelido em toda linha de dados"
fi

section "bash 3.2 (a versão do /bin/bash do mini)"
if [ -n "${GONOGO_ST_B32:-}" ] && [ -x "${GONOGO_ST_B32}" ]; then
  for f in "$SUT" "$0"; do
    B32OUT=$("$GONOGO_ST_B32" -n "$f" 2>&1); B32RC=$?
    if [ "$B32RC" -eq 0 ] && [ -z "$B32OUT" ]; then ok "bash -n no 3.2 sai limpo: ${f##*/}"; else nope "bash 3.2 -n recusa ${f##*/}: $B32OUT"; fi
  done
else echo "pulado: GONOGO_ST_B32=<bash 3.2> não informado (o gate roda o bash -n do mini nos .sh)"; fi
printf '\n=== RESULT: %s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
