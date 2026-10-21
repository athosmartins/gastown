#!/usr/bin/env bash
# hqswap.selftest.sh (ga-06wmmp) — teste hermético dos dois vigias de hqswap.sh que dizem QUANDO (em
# segundos) e QUEM abriu o banco com o Dolt parado: dotdolt_mtimes e watch_dolt_procs.
#
# ## Contents
# - O que cobre · Como roda
#
# O que cobre: dotdolt_mtimes (números de verdade, "?" quando não lê, nunca vazio nem parcial);
# watch_dolt_procs com `ps`/`lsof` falsos num PATH de scratch (a cadeia de pais de um `dolt backup`
# chega até o script que o chamou, o cwd aparece, cada processo é anotado UMA vez mesmo amostrado
# várias, o próprio pipeline do amostrador e as ferramentas do vigia de mtime (ls/stat/lsof sobre
# .beads/dolt) não viram ruído, um `ps` que falha não derruba o laço nem grava nada); o amostrador não
# fica órfão (um "script principal" de teste sobe o amostrador e leva SIGKILL; ele tem de sair sozinho);
# e os amarres no próprio hqswap.sh (sobe junto do vigia de mtime, para em stop-watch).
#
# Como roda: hqswap.sh executa a janela inteira no nível de topo e não dá para fazer source dele;
# as funções são extraídas pelo nome (sed) e rodam num shell de teste. Zero chamada a Dolt, ssh ou
# launchctl; o único processo extra é o "script principal" de teste do caso do órfão, morto por SIGKILL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HQSWAP_SCRIPT_PATH:-$SCRIPT_DIR/hqswap.sh}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
check() { # check <descrição> <comando de teste...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else nope "$d"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

fn_of() { sed -n "/^$1() {/,/^}/p" "$SCRIPT"; }
fn_of dotdolt_mtimes   > "$WORK/f-mtimes.sh"
fn_of watch_dolt_procs > "$WORK/f-procs.sh"

echo "── dotdolt_mtimes ──"
if [ -s "$WORK/f-mtimes.sh" ]; then ok "dotdolt_mtimes existe em hqswap.sh"; else nope "dotdolt_mtimes não existe em hqswap.sh"; fi

D1="$WORK/d1"; mkdir -p "$D1/hq/.dolt/noms"
touch -t 202401010101.01 "$D1/hq/.dolt" "$D1/hq/.dolt/noms"
OUT1=$(D="$D1" DB=hq bash -c ". '$WORK/f-mtimes.sh'; dotdolt_mtimes" 2>&1)
if printf '%s\n' "$OUT1" | grep -q -E '^mtime\(\.dolt noms\) [0-9]+ [0-9]+$'; then
  ok "com os dois diretórios presentes: dois números inteiros (segundos), não o minuto do ls -la"
else
  nope "saída inesperada de dotdolt_mtimes com os diretórios presentes: [$OUT1]"
fi

OUT2=$(D="$WORK/nao-existe" DB=hq bash -c ". '$WORK/f-mtimes.sh'; dotdolt_mtimes" 2>&1)
check "diretório ausente: imprime '?' (não lê ≠ zero, nem vazio)" test "$OUT2" = "mtime(.dolt noms) ?"

D3="$WORK/d3"; mkdir -p "$D3/hq/.dolt"
OUT3=$(D="$D3" DB=hq bash -c ". '$WORK/f-mtimes.sh'; dotdolt_mtimes" 2>&1)
check "só um dos dois existe: '?' inteiro, nunca um número só (leitura parcial não vira medida)" test "$OUT3" = "mtime(.dolt noms) ?"

echo "── watch_dolt_procs (ps e lsof falsos) ──"
if [ -s "$WORK/f-procs.sh" ]; then ok "watch_dolt_procs existe em hqswap.sh"; else nope "watch_dolt_procs não existe em hqswap.sh"; fi

cat > "$WORK/ps.table" <<'TABLE'
    1     0 /sbin/launchd
  300     1 /bin/bash /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/scripts/mol-dog-doctor.sh
  400   300 gtimeout --kill-after=2 10 dolt backup
  500   400 /opt/homebrew/bin/dolt backup
  600     1 /usr/sbin/cfprefsd agent
  200     1 /bin/bash scripts/hqswap.sh run
  700   200 ls -la /Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq/.dolt
  701   200 stat -f %m /Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq/.dolt /Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq/.dolt/noms
  702   200 lsof +D /Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq
TABLE
# ps falso: ignora os argumentos; PS_FAIL_FIRST=N faz as N primeiras chamadas falharem sem saída.
cat > "$BIN/ps" <<'STUB'
#!/bin/sh
n=0; [ -f "$PS_COUNT" ] && n=$(cat "$PS_COUNT"); n=$((n+1)); echo "$n" > "$PS_COUNT"
[ "$n" -le "${PS_FAIL_FIRST:-0}" ] && exit 1
cat "$PS_TABLE"
STUB
cat > "$BIN/lsof" <<'STUB'
#!/bin/sh
# lsof -a -d cwd -p PID -Fn : só o pid 500 tem cwd conhecido; o resto não responde (processo já saiu)
case "$*" in
  *" -p 500 "*) printf 'p500\nfcwd\nn/Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/ps" "$BIN/lsof"

# run_sampler <nome> <falhas-iniciais-do-ps> — roda o amostrador ~2,2 s e devolve o log em $WORK/<nome>/dotdolt-procs.log
run_sampler() {
  local x="$WORK/$1"; mkdir -p "$x"
  rm -f "$x/stop-watch" "$WORK/ps.count.$1"
  ( X="$x" D="$WORK/dx" DB=hq PATH="$BIN:$PATH" PS_TABLE="$WORK/ps.table" PS_COUNT="$WORK/ps.count.$1" PS_FAIL_FIRST="$2" \
      bash -c ". '$WORK/f-procs.sh'; watch_dolt_procs" ) &
  local pid=$!
  sleep 2.2
  touch "$x/stop-watch"
  wait "$pid" 2>/dev/null
}

run_sampler a 0
LOGA="$WORK/a/dotdolt-procs.log"
check "o dolt backup (pid 500) foi anotado"                         grep -q 'pid=500 ' "$LOGA"
check "a cadeia de pais chega ao script que chamou (mol-dog-doctor.sh)" grep -q 'pid=500 .*mol-dog-doctor\.sh' "$LOGA"
check "a cadeia chega até o launchd"                                grep -q 'pid=500 .*launchd' "$LOGA"
check "o cwd aparece na linha seguinte ao processo"                 grep -q '^  cwd: /Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq$' "$LOGA"
check "o intermediário (gtimeout ... dolt backup, pid 400) também é anotado" grep -q 'pid=400 ' "$LOGA"
check "pid sem cwd legível mostra '?' (não inventa caminho)"        grep -q '^  cwd: ?$' "$LOGA"
N500=$(grep -c 'pid=500 ' "$LOGA" 2>/dev/null); N500=${N500:-0}
SAMPLES=$(cat "$WORK/ps.count.a" 2>/dev/null); SAMPLES=${SAMPLES:-0}
check "pid 500 aparece UMA vez mesmo com várias amostras (amostras: $SAMPLES)" test "$N500" = 1 -a "$SAMPLES" -ge 3
check "processos sem 'dolt' na linha (launchd, bash do doctor, cfprefsd) não são anotados" sh -c "! grep -q -E 'pid=(1|300|600) ' '$LOGA'"
check "o pipeline do próprio amostrador (awk -v seen=, ps -axww) não vira ruído" sh -c "! grep -q -E 'awk -v seen=|ps -axww' '$LOGA'"
check "as ferramentas do vigia de mtime (ls -la, stat, lsof +D sobre .beads/dolt/hq) não viram 'processo dolt novo'" sh -c "! grep -q -E 'pid=(700|701|702) ' '$LOGA'"
check "o filtro é pelo programa, não pelo caminho: o dolt backup (500) e o gtimeout ... dolt backup (400) continuam anotados" sh -c "grep -q 'pid=500 ' '$LOGA' && grep -q 'pid=400 ' '$LOGA'"

run_sampler b 2
LOGB="$WORK/b/dotdolt-procs.log"
check "ps que falha nas 2 primeiras amostras: o laço sobrevive e anota o processo na seguinte" grep -q 'pid=500 ' "$LOGB"
check "nenhuma linha de lixo foi gravada pelas amostras sem saída (a 1ª linha já é um processo)" sh -c "head -1 '$LOGB' | grep -q ' pid='"

echo "── amarres no hqswap.sh ──"
check "o amostrador sobe junto do vigia de mtime, depois de parar o Dolt" grep -q 'watch_dotdolt & WATCH_PID=\$!; watch_dolt_procs & WATCH_PROCS_PID=\$!' "$SCRIPT"
check "o amostrador para em stop-watch"                              sh -c "fn() { sed -n '/^watch_dolt_procs() {/,/^}/p' '$SCRIPT'; }; fn | grep -q 'stop-watch'"
# comportamento, não grep no fonte: um "script principal" de teste sobe o amostrador em segundo plano (como o hqswap.sh faz) e leva SIGKILL;
# o amostrador tem de sair sozinho. $$ dentro dele é o PID do principal, e é isso que o laço confere
XO="$WORK/orfao"; mkdir -p "$XO"; rm -f "$XO/stop-watch" "$XO/sampler.pid"
X="$XO" D="$WORK/dx" DB=hq PATH="$BIN:$PATH" PS_TABLE="$WORK/ps.table" PS_COUNT="$WORK/ps.count.orfao" PS_FAIL_FIRST=0 \
  bash -c ". '$WORK/f-procs.sh'; watch_dolt_procs & echo \$! > '$XO/sampler.pid'; wait" &
MAIN_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$XO/sampler.pid" ] && break; sleep 0.2; done
SAMPLER_PID=$(cat "$XO/sampler.pid" 2>/dev/null)
sleep 1
if [ -n "$SAMPLER_PID" ] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
  ok "o amostrador está de pé enquanto o script principal vive (pid $SAMPLER_PID)"
else
  nope "o amostrador não subiu ou morreu cedo (pid [${SAMPLER_PID:-}])"
fi
kill -9 "$MAIN_PID" 2>/dev/null; wait "$MAIN_PID" 2>/dev/null
GONE=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ -n "$SAMPLER_PID" ] && ! kill -0 "$SAMPLER_PID" 2>/dev/null; then GONE=1; break; fi
  sleep 0.25
done
check "o amostrador não fica órfão: com o script principal morto por SIGKILL, ele sai em até 3 s" test "$GONE" = 1
touch "$XO/stop-watch"; [ "$GONE" = 1 ] || kill "$SAMPLER_PID" 2>/dev/null
check "o log do operador diz onde olhar (dotdolt-procs.log)"         grep -q '5b vigias ligados' "$SCRIPT"
check "bash -n limpo"                                                bash -n "$SCRIPT"

echo
echo "hqswap.selftest: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
