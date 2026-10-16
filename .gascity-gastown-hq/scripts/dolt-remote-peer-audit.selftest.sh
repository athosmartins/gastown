#!/usr/bin/env bash
# dolt-remote-peer-audit.selftest.sh (ga-k7o6ou) — teste hermético da sonda de pares do Dolt.
#
# Stuba `lsof`, `ps` e `pgrep` num PATH de scratch e aponta GC_CITY, o log e o lock para um
# diretório temporário: ZERO chamadas ao Dolt de verdade. Um `sleep` real faz o papel do
# "processo do dolt" (o dolt-pid-lib confere com `kill -0` de verdade); a identidade
# dele (comm=dolt, socket de LISTEN) é fingida pelos stubs.
#
# Cobre:
#   A. sample — classificação: loopback IPv4 (inclusive o IPv4-mapeado), [::1] à parte
#      (loopback6: o bind 127.0.0.1 deixa o listener só IPv4 e recusa esse cliente), conexão
#      de SAÍDA do dolt ignorada, par remoto, par remoto IPv4-mapeado, self_lan (cliente desta
#      máquina pelo IP da LAN), ninguém conectado; e os estados que NÃO podem virar "clean":
#      lsof falhou, sem LISTEN, sem pid.
#   B. sample — toda linha gravada é JSON válido (inclusive com par hostil), append anterior
#      cortado no meio não cola no registro novo, lock de instância única (dono vivo pula,
#      dono morto é retomado, lock sem pid só depois de velho), teto de linhas do log.
#   C. report — LIMPO só com cobertura inteira; BLOQUEADO lista o par (e explica o [::1]);
#      INSUFICIENTE para cobertura curta, buraco, sonda parada, unknown demais, trecho longo
#      só de unknown, linhas ilegíveis (inclusive registro cortado ou colado em outro, e
#      linha ilegível que cita nonloopback), log ausente; 100% unknown nunca vira LIMPO;
#      argumento inválido, inclusive horas com zero à esquerda (octal no bash).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DRPA_SCRIPT_PATH:-$SCRIPT_DIR/dolt-remote-peer-audit.sh}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
check() { # check <descrição> <comando de teste...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else nope "$d"; fi
}

WORK="$(mktemp -d)"
sleep 300 & FAKE_DOLT_PID=$!
trap 'kill "$FAKE_DOLT_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

CITY="$WORK/city"; STUBS="$WORK/stubs"; FIX="$WORK/fix"; LOG="$WORK/peers.jsonl"; LOCKD="$WORK/lock.d"
mkdir -p "$CITY/.gc/runtime/packs/dolt" "$STUBS" "$FIX"
echo "$FAKE_DOLT_PID" >"$CITY/.gc/runtime/packs/dolt/dolt.pid"

# ps: o pid do "dolt" tem comm=dolt; o resto vai para o ps de verdade.
cat >"$STUBS/ps" <<EOF
#!/bin/sh
case "\$*" in
  *"-o comm="*"-p $FAKE_DOLT_PID"*) echo "/opt/homebrew/bin/dolt"; exit 0 ;;
esac
exec /bin/ps "\$@"
EOF
# pgrep: nunca acha nada (o pidfile é quem escolhe o pid; o fallback não pode pegar o dolt real).
printf '#!/bin/sh\nexit 1\n' >"$STUBS/pgrep"
# lsof: LISTEN (checagem do dolt-pid-lib) responde por $FIX/listen_ok; o retrato da sonda
# (-iTCP sem filtro de estado) responde conforme $FIX/snap.mode.
cat >"$STUBS/lsof" <<EOF
#!/bin/sh
case "\$*" in
  *-sTCP:LISTEN*) [ -f "$FIX/listen_ok" ] && exit 0; exit 1 ;;
esac
mode=\$(cat "$FIX/snap.mode" 2>/dev/null)
case "\$mode" in
  ok)    cat "$FIX/snap.out"; exit 0 ;;
  empty) exit 1 ;;
  fail)  echo "lsof: WARNING: can't stat() something" >&2; exit 2 ;;
esac
exit 3
EOF
chmod +x "$STUBS/ps" "$STUBS/pgrep" "$STUBS/lsof"
touch "$FIX/listen_ok"

HDR='COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME'
LISTEN_LINE='dolt    1111 athos  306u  IPv6 0xaaaaaaaaaaaaaaaa      0t0  TCP *:52756 (LISTEN)'
est() { # est <local> <peer>  → uma linha ESTABLISHED do dolt
  printf 'dolt    1111 athos  %su  IPv4 0xbbbbbbbbbbbbbbbb      0t0  TCP %s->%s (ESTABLISHED)\n' "$RANDOM" "$1" "$2"
}
snap() { # snap <linhas ESTABLISHED...>  (com LISTEN)
  { echo "$HDR"; echo "$LISTEN_LINE"; for l in "$@"; do echo "$l"; done; } >"$FIX/snap.out"
  echo ok >"$FIX/snap.mode"
}

run_sample_keep() { # roda a sonda real com os stubs SEM zerar o log (o log do cenário já existe)
  PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" DOLT_PEER_AUDIT_LOCK="$LOCKD" \
    bash "$SCRIPT" sample >"$WORK/out" 2>"$WORK/err"
  return $?
}
run_sample() { # roda a sonda real com os stubs; devolve o rc; log fresco a cada cenário
  : >"$LOG"
  run_sample_keep
}
field() { # field <nome> → valor do campo na ÚLTIMA linha do log (string ou número)
  python3 -I - "$LOG" "$1" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1]) if l.strip()]
v = json.loads(lines[-1])[sys.argv[2]]
print(json.dumps(v) if isinstance(v, (dict, list)) else v)
PY
}
nlines() { wc -l <"$LOG" | tr -d ' '; }

echo "== A. sample: classificação"
snap "$(est 127.0.0.1:52756 127.0.0.1:50001)" "$(est '[::ffff:127.0.0.1]:52756' '[::ffff:127.0.0.1]:50002')" \
     "$(est 192.168.1.5:50123 52.1.2.3:443)"   # conexão de SAÍDA (porta local ≠ LISTEN)
run_sample; rc=$?
check "A1 só loopback IPv4 (+ saída do dolt ignorada) → rc 0"  test "$rc" = 0
check "A1 state=clean"                                         test "$(field state)" = clean
check "A1 conta só os 2 clientes (a saída para o S3 não é cliente)" test "$(field total)" = 2
check "A1 loopback=2 loopback6=0 self_lan=0 remote=0"          test "$(field loopback)/$(field loopback6)/$(field self_lan)/$(field remote)" = "2/0/0/0"
check "A1 ports vem do LISTEN do processo vivo"                test "$(field ports)" = 52756

snap "$(est 127.0.0.1:52756 127.0.0.1:50001)" "$(est 192.168.1.5:52756 192.168.1.20:51234)" "$(est 127.0.0.1:52756 127.0.0.1:50003)"
run_sample; rc=$?
check "A2 par remoto → rc 1"                                   test "$rc" = 1
check "A2 state=nonloopback"                                   test "$(field state)" = nonloopback
check "A2 remote=1 loopback=2"                                 test "$(field remote)/$(field loopback)" = "1/2"
check "A2 peers lista o IP remoto"                             test "$(field peers)" = '{"192.168.1.20": 1}'
check "A2 avisa no stderr (e não no stdout)"                   grep -q NONLOOPBACK "$WORK/err"

snap "$(est '[::ffff:192.168.1.5]:52756' '[::ffff:192.168.1.20]:51234')"
run_sample; rc=$?
check "A3 par remoto IPv4-mapeado ([::ffff:a.b.c.d]) → remote, rc 1" test "$rc/$(field remote)" = "1/1"

snap "$(est 192.168.1.5:52756 192.168.1.5:50000)"
run_sample; rc=$?
check "A4 cliente desta máquina pelo IP da LAN → self_lan=1 (quebraria com bind 127.0.0.1), rc 1" \
  test "$rc/$(field self_lan)/$(field remote)" = "1/1/0"

snap
run_sample; rc=$?
check "A5 ninguém conectado → clean com total=0, rc 0"         test "$rc/$(field state)/$(field total)" = "0/clean/0"

echo "fail" >"$FIX/snap.mode"
run_sample; rc=$?
check "A6 lsof falhou (rc 2) → rc 2"                           test "$rc" = 2
check "A6 state=unknown — falha NUNCA vira clean"              test "$(field state)" = unknown
check "A6 stderr diz UNKNOWN"                                  grep -q UNKNOWN "$WORK/err"

{ echo "$HDR"; est 127.0.0.1:52756 127.0.0.1:50001; } >"$FIX/snap.out"; echo ok >"$FIX/snap.mode"
run_sample; rc=$?
check "A7 retrato sem linha de LISTEN → unknown (não afirmo que li os sockets)" test "$rc/$(field state)" = "2/unknown"

echo empty >"$FIX/snap.mode"
run_sample; rc=$?
check "A8 lsof sem saída nenhuma (nem LISTEN) → unknown"       test "$rc/$(field state)" = "2/unknown"

echo 999999 >"$CITY/.gc/runtime/packs/dolt/dolt.pid"      # pid que não existe; pgrep stub não acha outro
snap "$(est 127.0.0.1:52756 127.0.0.1:50001)"
run_sample; rc=$?
check "A9 sem pid do Dolt → unknown, rc 2 (e não clean)"       test "$rc/$(field state)" = "2/unknown"
echo "$FAKE_DOLT_PID" >"$CITY/.gc/runtime/packs/dolt/dolt.pid"

# O listener de hoje é dual-stack ("IPv6 *:52756"); com bind 127.0.0.1 vira só IPv4 e um
# cliente que chega por ::1 leva ECONNREFUSED. Contá-lo como "loopback" (que passa) foi o
# defeito do gate ga-nt9vmg: a mesma classe que a sonda existe para pegar.
snap "$(est 127.0.0.1:52756 127.0.0.1:50001)" "$(est '[::1]:52756' '[::1]:50002')"
run_sample; rc=$?
check "A10 cliente em [::1] → rc 1 (o bind 127.0.0.1 o recusaria)" test "$rc" = 1
check "A10 state=nonloopback"                                  test "$(field state)" = nonloopback
check "A10 [::1] vai para o campo próprio: loopback=1 loopback6=1 self_lan=0 remote=0" \
  test "$(field loopback)/$(field loopback6)/$(field self_lan)/$(field remote)" = "1/1/0/0"
check "A10 total soma os 4 baldes (2 clientes)"                test "$(field total)" = 2
check "A10 peers lista o [::1] (o report precisa poder mostrá-lo)" test "$(field peers)" = '{"[::1]": 1}'
check "A10 avisa NONLOOPBACK no stderr"                        grep -q NONLOOPBACK "$WORK/err"

echo "== B. sample: robustez"
snap "$(est 10.0.0.1:52756 'ev"il\x:5000')"
run_sample; rc=$?
check "B1 par com caractere hostil → linha continua JSON válido" python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$LOG"
check "B1 par hostil vira \"?\" e conta como remote"           test "$rc/$(field peers)" = '1/{"?": 1}'

snap "$(est 127.0.0.1:52756 127.0.0.1:50001)"
mkdir -p "$LOCKD"; echo $$ >"$LOCKD/pid"                   # dono vivo (este shell)
run_sample; rc=$?
check "B2 lock com dono vivo → pula a amostra, rc 0, nada gravado" test "$rc/$(nlines)" = "0/0"
check "B2 o lock do outro dono NÃO foi apagado"                test -d "$LOCKD"
rm -f "$LOCKD/pid"; rmdir "$LOCKD"

mkdir -p "$LOCKD"; sleep 0 & dead=$!; wait "$dead" 2>/dev/null; echo "$dead" >"$LOCKD/pid"   # dono morto
run_sample; rc=$?
check "B3 lock com dono morto → retomado, amostra gravada"     test "$rc/$(nlines)" = "0/1"
check "B3 lock liberado ao terminar"                           test ! -d "$LOCKD"

mkdir -p "$LOCKD"                                          # lock sem pid legível
run_sample; rc=$?
check "B4 lock NOVO sem pid legível → não pego (dono pode estar escrevendo o pid), nada gravado" test "$rc/$(nlines)" = "0/0"
rmdir "$LOCKD" 2>/dev/null

# Lock sem pid e VELHO: o dono caiu entre o mkdir e o echo. Sem retomada a sonda calava para
# sempre (rc 0 + stderr; só o report acusava, como INSUFICIENTE).
mkdir -p "$LOCKD"; touch -t 200001010000 "$LOCKD"
run_sample; rc=$?
check "B4b lock sem pid legível e VELHO → retomado, amostra gravada" test "$rc/$(nlines)" = "0/1"
check "B4b lock liberado ao terminar"                          test ! -d "$LOCKD"

# Lock com dono VIVO nunca é retomado por idade (matar/furar um sampler lento seria pior).
mkdir -p "$LOCKD"; echo $$ >"$LOCKD/pid"; touch -t 200001010000 "$LOCKD"
run_sample; rc=$?
check "B4c lock velho mas com dono VIVO → não pego, nada gravado" test "$rc/$(nlines)" = "0/0"
rm -f "$LOCKD/pid"; rmdir "$LOCKD" 2>/dev/null

: >"$LOG"
for i in $(seq 1 12); do
  PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" DOLT_PEER_AUDIT_LOCK="$LOCKD" \
    DOLT_PEER_AUDIT_MAX_LINES=10 bash "$SCRIPT" sample >/dev/null 2>&1
done
n="$(nlines)"
check "B5 log respeita o teto de linhas (12 amostras, teto 10 → ≤ 10, ≥ 7)" test "$n" -le 10 -a "$n" -ge 7

# Append anterior cortado no meio (ENOSPC, kill): sem \n final, o registro novo colava na
# ponta cortada e o report lia as duas como UMA linha (gate ga-nt9vmg, defeito 2).
snap "$(est 127.0.0.1:52756 127.0.0.1:50001)"
printf '{"ts":"x","epoch":17' >"$LOG"
run_sample_keep; rc=$?
check "B6 log termina sem \\n → o registro novo começa em linha própria (2 linhas)" test "$rc/$(nlines)" = "0/2"
check "B6 a ponta cortada fica sozinha na linha 1"             test "$(sed -n 1p "$LOG")" = '{"ts":"x","epoch":17'
check "B6 a linha 2 é um registro JSON inteiro"                python3 -I -c 'import json,sys; json.loads(open(sys.argv[1]).read().splitlines()[1])' "$LOG"

: >"$LOG"; run_sample_keep; run_sample_keep
check "B7 log novo/terminado em \\n → nenhuma linha em branco inserida (2 amostras = 2 linhas)" \
  test "$(nlines)/$(grep -c '^$' "$LOG")" = "2/0"

# Cauda cheia de NUL (queda/reboot pode deixar zeros onde o append não chegou ao disco; aqui é simulada). O bash
# descarta o byte NUL em $(...), então "o último byte é \n?" por substituição de comando respondia
# SIM para uma cauda de zeros: nenhum \n era inserido e o registro novo colava nos zeros — o awk
# corta a linha no primeiro NUL e um nonloopback colado ali sumia sem o contador citá-lo.
snap "$(est 127.0.0.1:52756 127.0.0.1:50001)"
printf '{"ts":"x","epoch":17,"state":"clean"}\n\0\0\0\0\0\0\0\0' >"$LOG"
run_sample_keep; rc=$?
check "B8 log termina em NUL (sem \\n) → o registro novo começa em linha própria (3 linhas)" test "$rc/$(nlines)" = "0/3"
check "B8 a última linha é um registro JSON inteiro, sem NUL na frente" \
  python3 -I -c 'import json,sys; json.loads(open(sys.argv[1],"rb").read().split(b"\n")[-2])' "$LOG"

echo "== C. report"
NOW="$(date +%s)"
rec() { # rec <epoch> <estado> [loopback loopback6 self_lan remote peers-json]  → UM registro, no formato do emit
  local lp="${3:-1}" l6="${4:-0}" sl="${5:-0}" rm="${6:-0}" pj="${7:-}"
  [ -n "$pj" ] || pj='{}'
  printf '{"ts":"2026-01-01T00:00:00Z","epoch":%s,"state":"%s","pid":"1","ports":"52756","total":%s,"loopback":%s,"loopback6":%s,"self_lan":%s,"remote":%s,"peers":%s,"why":""}\n' \
    "$1" "$2" "$((lp + l6 + sl + rm))" "$lp" "$l6" "$sl" "$rm" "$pj"
}
gen() { # gen <de_horas_atrás> <até_horas_atrás> <passo_s> [estado]  → linhas de amostra
  local from=$(( $1 * 3600 )) to=$(( $2 * 3600 )) step="$3" st="${4:-clean}" e
  for (( e = NOW - from; e <= NOW - to; e += step )); do rec "$e" "$st"; done
}
rep() { PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" bash "$SCRIPT" report "$@" 2>&1; }
verdict() { rep "$@" | grep -Eo '^(LIMPO|BLOQUEADO|INSUFICIENTE)' | head -1; }

gen 49 0 600 >"$LOG"
check "C1 49h de cobertura limpa → LIMPO (rc 0)"               test "$(verdict 48)/$(rep 48 >/dev/null; echo $?)" = "LIMPO/0"

{ gen 49 0 600; rec "$((NOW - 3600))" nonloopback 1 0 0 1 '{"192.168.1.20":1}'; } >"$LOG"
out="$(rep 48)"; rc=$?
bloqueado() { [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^BLOQUEADO'; }
check "C2 um par fora do loopback na janela → BLOQUEADO (rc 1)" bloqueado
check "C2 lista o par e quando foi visto"                      printf '%s' "$out" | grep -q '192.168.1.20'

{ rec "$((NOW - 60 * 3600))" nonloopback 1 0 0 1 '{"192.168.1.20":1}'; gen 49 0 600; } >"$LOG"
check "C3 par visto ANTES da janela de 48h não bloqueia (semântica da janela)" test "$(verdict 48)" = LIMPO

gen 30 0 600 >"$LOG"
out="$(rep 48)"; rc=$?
insuficiente() { [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '^INSUFICIENTE'; }
check "C4 só 30h de cobertura para 48h → INSUFICIENTE (rc 2)"   insuficiente

{ gen 49 0 600 | awk 'NR % 8 == 0 { sub(/"state":"clean"/, "\"state\":\"unknown\"") } 1'; } >"$LOG"
check "C5 12% de amostras unknown → INSUFICIENTE (unknown não é evidência)" test "$(verdict 48)" = INSUFICIENTE

{ gen 49 26 600; gen 23 0 600; } >"$LOG"
check "C6 buraco de ~3h no meio → INSUFICIENTE"                test "$(verdict 48)" = INSUFICIENTE

gen 49 3 600 >"$LOG"
check "C7 última amostra com 3h (a sonda parou) → INSUFICIENTE" test "$(verdict 48)" = INSUFICIENTE

{ gen 49 0 600; for i in 1 2 3 4 5 6 7 8; do echo 'lixo sem json $i'; done; } >"$LOG"
check "C8 linhas ilegíveis acima de 1% → INSUFICIENTE"          test "$(verdict 48)" = INSUFICIENTE

gen 49 0 600 unknown >"$LOG"
check "C9 100% unknown nunca vira LIMPO"                       test "$(verdict 48)" = INSUFICIENTE

: >"$LOG"
check "C10 log vazio → INSUFICIENTE"                           test "$(verdict 48)" = INSUFICIENTE

rm -f "$LOG"
out="$(rep 48)"; rc=$?
nunca_rodou() { [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'nunca rodou'; }
check "C11 log ausente → INSUFICIENTE (a sonda nunca rodou), rc 2" nunca_rodou

gen 25 0 600 >"$LOG"
check "C12 janela configurável: 24h com 25h de cobertura → LIMPO" test "$(verdict 24)" = LIMPO

for bad in abc 0 00 -5 1.5 99999999999999999999; do
  rep "$bad" >/dev/null; rc=$?
  check "C13 horas inválidas ('$bad') → rc 64"                  test "$rc" = 64
done

# "08"/"09" são octal inválido para o bash ($((...)) → erro com exit 1 = o código do BLOQUEADO,
# sem veredito) e "010" virava 8h calado mas imprimia "10h". Horas são decimais, sempre.
gen 49 0 600 >"$LOG"
check "C13 '08' → LIMPO sobre 8h (não erro de octal)"          test "$(verdict 08)/$(rep 08 | grep -Eo 'últimas [0-9]+h' | head -1)" = "LIMPO/últimas 8h"
check "C13 '09' → LIMPO sobre 9h (não erro de octal)"          test "$(verdict 09)/$(rep 09 | grep -Eo 'últimas [0-9]+h' | head -1)" = "LIMPO/últimas 9h"
# "010" lido como octal vira janela de 8h: com só 9h de log o veredito certo (janela de 10h) é
# INSUFICIENTE; o bug dava LIMPO, e o cabeçalho ainda dizia "10h".
gen 9 0 600 >"$LOG"
check "C13 '010' = 10h decimais: log de 9h → INSUFICIENTE (e não LIMPO sobre 8h)" test "$(verdict 010)" = INSUFICIENTE

# Cliente em [::1] dentro da janela: o bind 127.0.0.1 o recusaria → BLOQUEADO, e o report diz por quê.
{ gen 49 0 600; rec "$((NOW - 3600))" nonloopback 1 1 0 0 '{"[::1]":1}'; } >"$LOG"
out="$(rep 48)"; rc=$?
bloqueado6() { [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^BLOQUEADO' && printf '%s' "$out" | grep -q '\[::1\]' \
  && printf '%s' "$out" | grep -q 'só IPv4'; }
check "C14 cliente em [::1] na janela → BLOQUEADO, lista o [::1] e explica o bind só IPv4" bloqueado6

# O caso reproduzido pelo revisor: um append cortado ('{"ts":"x","epoch":17') seguido do registro
# SEGUINTE inteiro, que viu um cliente remoto, colados numa linha só. O report lia a primeira
# ocorrência de epoch/state, aceitava a linha e dizia "LIMPO ... ilegíveis: 0".
{ gen 49 0 600; printf '{"ts":"x","epoch":17'; rec "$((NOW - 3600))" nonloopback 1 0 0 1 '{"192.168.1.20":1}'; } >"$LOG"
out="$(rep 48)"; rc=$?
colado() { [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '^INSUFICIENTE' && printf '%s' "$out" | grep -q 'linhas ilegíveis: 1' \
  && printf '%s' "$out" | grep -q 'nonloopback'; }
check "C15 registro cortado COLADO num nonloopback → INSUFICIENTE (rc 2), ilegíveis: 1, cita nonloopback" colado

# Registro cortado depois de epoch+state: parecia válido ao padrão antigo (que só procurava as duas chaves).
{ gen 49 0 600; printf '{"ts":"x","epoch":%s,"state":"clean","pid":"1"\n' "$((NOW - 1800))"; } >"$LOG"
out="$(rep 48)"
check "C16 registro cortado após epoch+state conta como ilegível (ilegíveis: 1)" \
  test "$(printf '%s' "$out" | grep -c 'linhas ilegíveis: 1')" = 1

# Uma linha de lixo que NÃO cita nonloopback segue tolerada (< 1%), mas aparece no contador.
{ gen 49 0 600; echo 'lixo qualquer'; } >"$LOG"
out="$(rep 48)"
check "C17 uma linha de lixo (sem nonloopback) → LIMPO, e o contador diz ilegíveis: 1" \
  test "$(printf '%s' "$out" | grep -Eo '^LIMPO' | head -1)/$(printf '%s' "$out" | grep -c 'linhas ilegíveis: 1')" = "LIMPO/1"

# unknown: a porcentagem sozinha deixava 10% de 48h (~4,8h) ser UM trecho cego só de unknown.
# Passo de 600 s aqui: 3 unknown seguidos = trecho de 1200 s (> 900 s do maxgap) com só 1% do total.
gen 49 0 600 | awk 'NR >= 100 && NR <= 102 { sub(/"state":"clean"/, "\"state\":\"unknown\"") } 1' >"$LOG"
out="$(rep 48)"; rc=$?
trecho_cego() { [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '^INSUFICIENTE' && printf '%s' "$out" | grep -q 'só com unknown'; }
check "C18 3 unknown seguidos (1% do total, trecho > maxgap) → INSUFICIENTE 'só com unknown'" trecho_cego

# Controle de fronteira: dois pares ISOLADOS de unknown (trecho de 600 s cada, 1,4% do total) ficam LIMPOS,
# e o LIMPO diz quantas leituras NÃO eram válidas (não conta unknown como evidência).
gen 49 0 600 | awk '(NR >= 100 && NR <= 101) || (NR >= 200 && NR <= 201) { sub(/"state":"clean"/, "\"state\":\"unknown\"") } 1' >"$LOG"
out="$(rep 48)"; rc=$?
check "C19 dois pares isolados de unknown → LIMPO (rc 0)"       test "$rc/$(printf '%s' "$out" | grep -Eo '^LIMPO' | head -1)" = "0/LIMPO"
check "C19 o LIMPO conta só as leituras válidas e diz '(+4 unknown)'" test "$(printf '%s' "$out" | grep -c '(+4 unknown)')" = 1

# Registro cortado NO MEIO de um caractere multibyte (o `why` tem "í"/"ã"; ENOSPC pode parar entre
# os dois bytes). Num shell interativo em UTF-8 o awk do macOS morria com "towc: multibyte
# conversion failure" e o report inteiro ficava sem veredito — o log envenenado por ~14 dias (teto
# de linhas) para quem roda `report 48` à mão. O script fixa LC_ALL=C: o veredito sai igual em
# qualquer locale. Só vale onde o locale UTF-8 existe; sem ele o teste seria vacuamente verde.
locales="$(locale -a 2>/dev/null)"   # sem pipe para `grep -q`: com pipefail o SIGPIPE do `locale` dava "locale ausente"
case $'\n'"$locales"$'\n' in *$'\n'en_US.UTF-8$'\n'*) have_utf8=1 ;; *) have_utf8=0 ;; esac
if [ "$have_utf8" = 1 ]; then
  { gen 49 0 600
    printf '{"ts":"x","epoch":17,"state":"unknown","why":"lsof falhou ou sem LISTEN vis\303\n'
    rec "$((NOW - 3600))" nonloopback 1 0 0 1 '{"192.168.1.20":1}'; } >"$LOG"
  out="$(LC_ALL=en_US.UTF-8 PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" bash "$SCRIPT" report 48 2>&1)"; rc=$?
  utf8() { [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^BLOQUEADO' && printf '%s' "$out" | grep -q 'linhas ilegíveis: 1' \
    && ! printf '%s' "$out" | grep -q 'multibyte'; }
  check "C20 registro cortado no meio de um multibyte, report em locale UTF-8 → BLOQUEADO (rc 1), ilegíveis: 1, sem erro do awk" utf8
else
  echo "skip - C20 (locale en_US.UTF-8 ausente nesta máquina: o teste seria vacuamente verde)"
fi

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
