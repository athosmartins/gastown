#!/usr/bin/env bash
# dolt-remote-peer-audit.selftest.sh (ga-k7o6ou) — teste hermético da sonda de pares do Dolt.
#
# Stuba `lsof`, `ps` e `pgrep` num PATH de scratch e aponta GC_CITY, o log e o lock para um
# diretório temporário: ZERO chamadas ao Dolt de verdade. Um `sleep` real faz o papel do
# "processo do dolt" (o dolt-pid-lib confere com `kill -0` de verdade); a identidade
# dele (comm=dolt, socket de LISTEN) é fingida pelos stubs.
#
# Cobre:
#   A. sample — classificação: loopback v4/v6, conexão de SAÍDA do dolt ignorada, par remoto,
#      par remoto IPv4-mapeado, self_lan (cliente desta máquina pelo IP da LAN), ninguém
#      conectado; e os estados que NÃO podem virar "clean": lsof falhou, sem LISTEN, sem pid.
#   B. sample — toda linha gravada é JSON válido (inclusive com par hostil), lock de
#      instância única (dono vivo pula, dono morto é retomado), teto de linhas do log.
#   C. report — LIMPO só com cobertura inteira; BLOQUEADO lista o par; INSUFICIENTE para
#      cobertura curta, buraco, sonda parada, unknown demais, linhas ilegíveis, log ausente;
#      100% unknown nunca vira LIMPO; argumento inválido.
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

run_sample() { # roda a sonda real com os stubs; devolve o rc; log fresco a cada cenário
  : >"$LOG"
  PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" DOLT_PEER_AUDIT_LOCK="$LOCKD" \
    bash "$SCRIPT" sample >"$WORK/out" 2>"$WORK/err"
  return $?
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
snap "$(est 127.0.0.1:52756 127.0.0.1:50001)" "$(est '[::1]:52756' '[::1]:50002')" \
     "$(est 192.168.1.5:50123 52.1.2.3:443)"   # conexão de SAÍDA (porta local ≠ LISTEN)
run_sample; rc=$?
check "A1 só loopback (+ saída do dolt ignorada) → rc 0"       test "$rc" = 0
check "A1 state=clean"                                         test "$(field state)" = clean
check "A1 conta só os 2 clientes (a saída para o S3 não é cliente)" test "$(field total)" = 2
check "A1 loopback=2 self_lan=0 remote=0"                      test "$(field loopback)/$(field self_lan)/$(field remote)" = "2/0/0"
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
check "B4 lock sem pid legível → não pego (estado inerte), nada gravado" test "$rc/$(nlines)" = "0/0"
rmdir "$LOCKD" 2>/dev/null

: >"$LOG"
for i in $(seq 1 12); do
  PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" DOLT_PEER_AUDIT_LOCK="$LOCKD" \
    DOLT_PEER_AUDIT_MAX_LINES=10 bash "$SCRIPT" sample >/dev/null 2>&1
done
n="$(nlines)"
check "B5 log respeita o teto de linhas (12 amostras, teto 10 → ≤ 10, ≥ 7)" test "$n" -le 10 -a "$n" -ge 7

echo "== C. report"
NOW="$(date +%s)"
gen() { # gen <de_horas_atrás> <até_horas_atrás> <passo_s> [estado]  → linhas de amostra
  local from=$(( $1 * 3600 )) to=$(( $2 * 3600 )) step="$3" st="${4:-clean}" e
  for (( e = NOW - from; e <= NOW - to; e += step )); do
    printf '{"ts":"x","epoch":%s,"state":"%s","pid":"1","ports":"52756","total":1,"loopback":1,"self_lan":0,"remote":0,"peers":{},"why":""}\n' "$e" "$st"
  done
}
rep() { PATH="$STUBS:$PATH" GC_CITY="$CITY" DOLT_PEER_AUDIT_LOG="$LOG" bash "$SCRIPT" report "$@" 2>&1; }
verdict() { rep "$@" | grep -Eo '^(LIMPO|BLOQUEADO|INSUFICIENTE)' | head -1; }

gen 49 0 600 >"$LOG"
check "C1 49h de cobertura limpa → LIMPO (rc 0)"               test "$(verdict 48)/$(rep 48 >/dev/null; echo $?)" = "LIMPO/0"

{ gen 49 0 600; printf '{"ts":"x","epoch":%s,"state":"nonloopback","pid":"1","ports":"52756","total":2,"loopback":1,"self_lan":0,"remote":1,"peers":{"192.168.1.20":1},"why":""}\n' "$((NOW - 3600))"; } >"$LOG"
out="$(rep 48)"; rc=$?
bloqueado() { [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^BLOQUEADO'; }
check "C2 um par fora do loopback na janela → BLOQUEADO (rc 1)" bloqueado
check "C2 lista o par e quando foi visto"                      printf '%s' "$out" | grep -q '192.168.1.20'

{ printf '{"ts":"x","epoch":%s,"state":"nonloopback","pid":"1","ports":"52756","total":2,"loopback":1,"self_lan":0,"remote":1,"peers":{"192.168.1.20":1},"why":""}\n' "$((NOW - 60 * 3600))"; gen 49 0 600; } >"$LOG"
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

for bad in abc 0 -5 1.5; do
  rep "$bad" >/dev/null; rc=$?
  check "C13 horas inválidas ('$bad') → rc 64"                  test "$rc" = 64
done

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
