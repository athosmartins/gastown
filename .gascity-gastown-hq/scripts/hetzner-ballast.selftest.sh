#!/usr/bin/env bash
# hetzner-ballast.selftest.sh — hermético (ga-2hd02v.5): o /proc é uma pasta de fixtures (BALLAST_PROC), o relógio é BALLAST_NOW, o "nó" é uma pasta temporária e os itens
# são scripts de brinquedo que dormem ou imprimem um resumo. Nada fala com o nó de verdade e nada toca em ~/gt-remote.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS
#   registro (g_reg): linhas válidas · coluna a mais/a menos, papel, núcleos, nome repetido e `requires` desconhecido viram erro VISÍVEL e o item fica inerte (os outros seguem) ·
#     comentário e linha em branco ignorados · registro ausente/ilegível = nada começa e nada é morto · comando relativo vale a partir da pasta de itens.
#   tick (g_tick): sem a chave `on` não começa nada · 1ª leitura só semeia · CPU livre >= 15% por 3 leituras seguidas antes de começar, e uma leitura abaixo zera a conta · o
#     tempo em nice > 0 (o próprio lastro) NÃO conta como carga · orçamento = núcleos livres - reserva (item de N núcleos só cabe se rodando + N <= orçamento; `auto` leva o resto) ·
#     teto de itens · contador que anda para trás ou lacuna de mais de 3 min recomeça a conta · /proc/stat ou meminfo ilegível = não começa e não mata · outra instância
#     rodando = não faz nada · pasta sem permissão = rc 3.
#   RAM (g_ram): abaixo do piso de partida não começa · abaixo do piso de pausa congela (SIGSTOP) e volta (SIGCONT) com folga · pausa que não passa em N leituras mata o maior ·
#     abaixo do piso crítico mata o maior na hora · RSS do item acima do teto dele mata.
#   fim e resultado (g_reap): rc 0 / rc≠0 / sem rc / resumo ilegível viram linha em results.jsonl, nunca "ok" por falta de leitura · cooldown · pid reaproveitado não é o item ·
#     prazo estourado (TERM, depois KILL) · quem sumiu sem a leitura de processos não é dado por morto.
#   enchimento (g_fill): item `filler` só entra com a flag, é morto quando um item `work` vai começar e nunca conta no orçamento do `work`.
#   desligar (g_off): chave `on` apagada mata o que roda (TERM) · `stop` idem · `status` diz o estado sem gravar.
#   estado (g_state): state.json corrompido vai para o lado e recomeça sem duplicar o que já roda (o processo é a fonte da verdade) · ilegível por permissão = inerte (rc 3).
#   lançamento (g_launch): prefixo nice 19 + SCHED_IDLE + ionice idle + timeout -k, com o que existir no PATH; sem `timeout` o item não começa.
# CONTROLE NEGATIVO: cada mutante (um trecho do script trocado) TEM que reprovar a bateria.
# VARIÁVEIS: HB_UNDER_TEST (script a testar) · HB_PY (interpretador; padrão /usr/bin/python3) · HB_NO_MUTANTS=1 · HB_ONLY=<grupo> (reg tick ram reap fill off state logs launch; sem mutantes)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${HB_UNDER_TEST:-$HERE/hetzner-ballast.py}"
PY="${HB_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hb.XXXXXX)" && pwd -P)
cleanup() { pkill -f "$T/h" 2>/dev/null; sleep 0.2; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() {  # ok RC DESCRIÇÃO — no modo mutante, a primeira falha encerra (só interessa se a bateria reprova)
  n=$((n+1))
  if [ "$1" = 0 ]; then [ -n "${HB_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HB_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi
}
check() {  # check "DESCRIÇÃO" ESPERADO REAL
  if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi
}
W="$T/w"; mkdir -p "$W/bin"
printf '#!/bin/sh\n# timeout de brinquedo (o do macOS não existe): descarta "-k K DUR" e roda\nshift 3; exec "$@"\n' > "$W/bin/timeout"; chmod +x "$W/bin/timeout"
NCPU=16
N=0; H=""; FP=""; NOW=0; U=0; NI=0; ID=0; EXTRA_ENV=""; LP='[]'; PID=""; RUN=""

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
writestat() {  # /proc/stat: a linha agregada + uma por núcleo (o governo conta os cpuN)
  { echo "cpu  $U $NI 0 $ID 0 0 0 0 0 0"; local k=0; while [ "$k" -lt "$NCPU" ]; do echo "cpu$k 0 0 0 0 0 0 0 0 0 0"; k=$((k+1)); done; echo "intr 0"; } > "$FP/stat"
}
adv() {  # adv FG_PCT NICE_PCT [SEGUNDOS=60]: avança o relógio e os contadores como se FG_PCT% da CPU fosse nice<=0 e NICE_PCT% fosse nice>0 (o resto parado)
  local s=${3:-60} tot; tot=$((NCPU * ${3:-60} * 100))
  U=$((U + tot * $1 / 100)); NI=$((NI + tot * $2 / 100)); ID=$((ID + tot * (100 - $1 - $2) / 100)); NOW=$((NOW + s)); writestat
}
setmem() { printf 'MemTotal:       32000000 kB\nMemFree:             100 kB\nMemAvailable:   %s kB\n' "$(( $1 * 1024 ))" > "$FP/meminfo"; }
reg() {  # reg 'nome|papel|núcleos|rss_mb|prazo_s|cooldown_s|requires|comando' — uma linha do registro (| vira TAB)
  printf '%s\n' "$1" | tr '|' '\t' >> "$H/items.tsv"
}
newhome() {
  N=$((N+1)); H="$T/h$N"; FP="$T/p$N"; mkdir -p "$H/items" "$FP"; : > "$H/on"
  printf '#!/bin/sh\nsleep 300\n' > "$H/items/sleeper.sh"; chmod +x "$H/items/sleeper.sh"
  printf '#!/bin/sh\necho "linha de log"\necho '"'"'BALLAST-SUMMARY: {"pass": 3, "fail": 0}'"'"'\nsleep 300\n' > "$H/items/summary.sh"; chmod +x "$H/items/summary.sh"
  : > "$H/items.tsv"; reg 'hq|work|4|1024|3600|300|-|sleeper.sh'
  NOW=1800000000; U=0; NI=0; ID=0; EXTRA_ENV=""; LP='[]'; setmem 28000; writestat
}
alive() {  # alive PID ITEM RUN [RSS_KB=1024] [ESTADO=S] — o processo do item aparece no /proc de mentira (líder de sessão, com a marca na linha de comando)
  mkdir -p "$FP/$1"
  printf '%s (sh) %s 1 %s %s 0 0\n' "$1" "${5:-S}" "$1" "$1" > "$FP/$1/stat"
  printf '0 %s 0 0 0 0 0\n' "$(( ${4:-1024} / 4 ))" > "$FP/$1/statm"
  printf 'sh\0-c\0x\0ballast-item:%s:%s\0' "$2" "$3" > "$FP/$1/cmdline"
}
member() {  # member PID SID [RSS_KB] — um filho do item (mesma sessão)
  mkdir -p "$FP/$1"; printf '%s (worker) S %s %s %s 0 0\n' "$1" "$2" "$2" "$2" > "$FP/$1/stat"; printf '0 %s 0 0 0 0 0\n' "$(( ${3:-1024} / 4 ))" > "$FP/$1/statm"; printf 'worker\0' > "$FP/$1/cmdline"
}
gone() { rm -rf "$FP/$1"; }   # o processo sumiu do /proc
bt() {  # bt [ARGS…] → $OUT (stdout), $RC. Padrão: tick
  [ $# -gt 0 ] || set -- tick
  OUT=$(env PATH="$W/bin:$PATH" BALLAST_HOME="$H" BALLAST_PROC="$FP" BALLAST_NOW="$NOW" BALLAST_LAUNCH_PREFIX="$LP" $EXTRA_ENV "$PY" -I "$P" "$@" 2>"$W/err"); RC=$?
}
jget() {  # jget CAMPO.PONTADO → valor do $OUT (JSON), texto simples; índice de lista como número; null/ausente → "null"
  printf '%s' "$OUT" | "$PY" -I -c 'import sys,json
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if isinstance(v,dict): v=v.get(k)
    elif isinstance(v,list) and k.isdigit() and int(k)<len(v): v=v[int(k)]
    else: v=None
print(v if isinstance(v,str) else json.dumps(v))' "$1" 2>/dev/null
}
nstart() { printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; print(len(json.load(sys.stdin)["started"]))'; }
started_pid() { jget started.0.pid; }
started_run() { jget started.0.run; }
isdead() {  # isdead PID — o grupo de processos sumiu (ou só sobrou zumbi): espera até 3 s
  local i=0; while [ "$i" -lt 15 ]; do kill -0 -- "-$1" 2>/dev/null || return 0; [ "$(pstate "$1")" = Z ] && return 0; sleep 0.2; i=$((i+1)); done; return 1
}
running_one() {  # running_one — newhome + o hq (4 núcleos) já rodando e visível no /proc de mentira: PID e RUN
  newhome; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" hq "$RUN"
}
nkilled() { printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; print(len(json.load(sys.stdin)["killed"]))'; }
rj() { [ -f "$H/results.jsonl" ] && tail -n 1 "$H/results.jsonl" | "$PY" -I -c 'import sys,json; v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else json.dumps(v))' "$1" || echo "sem-results"; }
seed() { bt; }                                          # a 1ª leitura só semeia o baseline
good() { adv "${1:-50}" "${2:-0}"; bt; }               # uma leitura com CPU livre (padrão: 50% de carga de sessões)
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
pstate() { ps -o stat= -p "$1" 2>/dev/null | cut -c1; }   # S, R, T (parado), vazio = não existe

# ── g_reg ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_reg() {
  newhome; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; bt status --json
  check "reg: duas linhas válidas aparecem no status" "hq queima" "$(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; print(" ".join(i["name"] for i in json.load(sys.stdin)["items"]))')"
  check "reg: papel e núcleos lidos (hq work 4; queima filler auto)" "work 4 filler auto" "$(jget items.0.role) $(jget items.0.cores) $(jget items.1.role) $(jget items.1.cores)"
  check "reg: requires flag:burn.on sem a flag → inerte com o motivo" "false" "$(jget items.1.eligible)"
  check "reg: o motivo cita o requires" "1" "$(jget items.1.why | grep -c 'flag:burn.on')"

  newhome; reg 'ruim|work|4|1024|3600|300|-'; reg '#comentário|work|1|1|1|1|-|x.sh'; echo >> "$H/items.tsv"; bt status --json
  check "reg: linha com coluna a menos vira erro visível (1 erro) e o item bom segue" "1 hq" "$(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; d=json.load(sys.stdin); print(len(d["registry_errors"]), d["items"][0]["name"])')"
  check "reg: o erro diz a linha" "1" "$(jget registry_errors.0 | grep -c 'linha 2')"
  check "reg: comentário e linha em branco não são itens nem erros" "1 1" "$(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; d=json.load(sys.stdin); print(len(d["items"]), len(d["registry_errors"]))')"

  newhome; reg 'hq|work|4|1024|3600|300|-|sleeper.sh'; bt status --json
  check "reg: nome repetido → a 2ª linha é erro e o item não duplica" "1 1" "$(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; d=json.load(sys.stdin); print(len(d["items"]), len(d["registry_errors"]))')"
  newhome; reg 'a|enorme|4|1024|3600|300|-|sleeper.sh'; reg 'b|work|0|1024|3600|300|-|sleeper.sh'; reg 'c|work|abc|1024|3600|300|-|sleeper.sh'; reg 'd|work|4|1024|0|300|-|sleeper.sh'; reg 'e|work|4|1024|3600|-1|-|sleeper.sh'; bt status --json
  check "reg: papel desconhecido, núcleos 0 / não numérico, prazo 0 e cooldown negativo → 5 erros, só o hq sobra" "1 5" "$(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; d=json.load(sys.stdin); print(len(d["items"]), len(d["registry_errors"]))')"
  newhome; reg 'x|work|2|1024|3600|300|bogus:y|sleeper.sh'; bt status --json
  check "reg: predicado de requires desconhecido → item inerte (nunca 'sem requisito')" "false" "$(jget items.1.eligible)"
  newhome; reg 'y|work|2|1024|3600|300|-|nao-existe.sh'; bt status --json
  check "reg: comando que não existe na pasta de itens → inerte, motivo 'comando'" "false 1" "$(jget items.1.eligible) $(jget items.1.why | grep -c comando)"
  newhome; printf '#!/bin/sh\nsleep 1\n' > "$H/items/nox.sh"; reg 'nx|work|2|1024|3600|300|-|nox.sh'; bt status --json
  check "reg: comando que existe mas SEM permissão de execução → inerte, motivo 'comando'" "false 1" "$(jget items.1.eligible) $(jget items.1.why | grep -c comando)"
  newhome; reg 'z|work|2|1024|3600|300|path:/nao/existe/mesmo,flag:on|sleeper.sh'; bt status --json
  check "reg: requires com dois predicados — um falso basta para ficar inerte" "false" "$(jget items.1.eligible)"
  newhome; reg 'w|work|2|1024|3600|300|path:'"$H"'/items,flag:on,cmd:sh|sleeper.sh'; bt status --json
  check "reg: requires com path + flag + cmd todos verdadeiros → elegível" "true" "$(jget items.1.eligible)"

  newhome; EXTRA_ENV="BALLAST_ITEMS=$HERE/hetzner-ballast.items.txt BALLAST_ITEMS_DIR=$HERE/hetzner-ballast-items"; bt status --json
  check "reg: o registro que VAI no repo (hetzner-ballast.items.txt) lê sem erro: hq-selftests (work) e queima (filler)" "0 hq-selftests work queima filler" "$(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; print(len(json.load(sys.stdin)["registry_errors"]))') $(jget items.0.name) $(jget items.0.role) $(jget items.1.name) $(jget items.1.role)"
  check "reg: todo comando do registro do repo existe em hetzner-ballast-items/ e é executável (o motivo de inerte, se houver, NÃO é 'comando')" "0 0" "$(jget items.0.why | grep -c comando) $(jget items.1.why | grep -c comando)"
  newhome; rm -f "$H/items.tsv"; seed; adv 50 0; bt; adv 50 0; bt; adv 50 0; bt
  check "reg: registro ausente → nada começa, nota registro-ilegivel, rc 0" "0 registro-ilegivel []" "$RC $(jget note) $(jget started)"
  newhome; printf '\xff\xfe\x00bin\n' > "$H/items.tsv"; seed; adv 50 0; bt
  check "reg: registro que não é texto → registro-ilegivel, nada começa" "registro-ilegivel" "$(jget note)"
}

# ── g_tick ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_tick() {
  newhome; rm -f "$H/on"; seed; good; good; good; good
  check "tick: sem a chave on → mode desligado e nada começa, mesmo com a CPU toda livre" "desligado []" "$(jget mode) $(jget started)"
  check "tick: rc 0 e state.json gravado" "0 1" "$RC $([ -s "$H/state.json" ] && echo 1 || echo 0)"

  newhome; seed
  check "tick: 1ª leitura só semeia (nota primeira-leitura, rc 0, nada começa)" "0 primeira-leitura []" "$RC $(jget note) $(jget started)"
  good; check "tick: 2ª leitura, CPU 50% livre → free_ticks 1, não começa" "1 []" "$(jget free_ticks) $(jget started)"
  good; check "tick: 3ª leitura → free_ticks 2, ainda não" "2 []" "$(jget free_ticks) $(jget started)"
  good; check "tick: 4ª leitura → 3 leituras seguidas livres: o hq começa" "3 hq" "$(jget free_ticks) $(jget started.0.item)"
  check "tick: o que começou traz pid e a pasta da rodada" "1" "$([ "$(started_pid)" -gt 1 ] 2>/dev/null && [ -d "$H/runs/$(started_run)" ] && echo 1 || echo 0)"
  check "tick: o fg_cores e o free_pct do registro (50% de 16 núcleos = 8,0; 50,0)" "8.0 50.0" "$(jget fg_cores) $(jget free_pct)"

  newhome; seed; good 50; good 50; good 90; check "tick: uma leitura com 10% livre (< 15%) zera a conta" "0" "$(jget free_ticks)"
  good 50; good 50; check "tick: a conta recomeça do zero depois (2 leituras ainda não bastam)" "2 []" "$(jget free_ticks) $(jget started)"
  good 50; check "tick: 3 leituras seguidas de novo → começa" "hq" "$(jget started.0.item)"

  newhome; seed; good 85; check "tick: 15% livres exatos conta como livre (>= 15)" "1" "$(jget free_ticks)"

  newhome; seed; good 0 100; good 0 100; good 0 100
  check "tick: tempo em nice > 0 (o próprio lastro) NÃO é carga: fg 0, livre 100%, começa" "0.0 100.0 hq" "$(jget fg_cores) $(jget free_pct) $(jget started.0.item)"

  newhome; reg 'b|work|8|1024|3600|300|-|sleeper.sh'; reg 'c|work|3|1024|3600|300|-|sleeper.sh'; seed; good 25; good 25; good 25
  check "tick: orçamento = 16 - 4 (carga) - 1 (reserva) = 11: hq(4) + b(8)=12 não cabe, c(3) cabe" "hq c" "$(jget started.0.item) $(jget started.1.item)"
  check "tick: b (8 núcleos) ficou de fora por falta de orçamento" "2" "$(nstart)"
  newhome; reg 'a|work|auto|1024|3600|300|-|sleeper.sh'; seed; good 25; good 25; good 25
  check "tick: auto leva o que sobra do orçamento (11 - 4 do hq = 7)" "hq a 7" "$(jget started.0.item) $(jget started.1.item) $(jget started.1.cores)"

  newhome; EXTRA_ENV="BALLAST_RESERVE_CORES=2"; seed; good 25; good 25; good 25
  check "tick: BALLAST_RESERVE_CORES muda a reserva (orçamento 10, hq cabe)" "hq" "$(jget started.0.item)"
  newhome; EXTRA_ENV="BALLAST_RESERVE_CORES=2"; reg 'b|work|7|1024|3600|300|-|sleeper.sh'; seed; good 25; good 25; good 25
  check "tick: com reserva 2 o orçamento é 10: hq(4) cabe e b(7) não (11 > 10)" "hq 1" "$(jget started.0.item) $(nstart)"

  newhome; EXTRA_ENV="BALLAST_MAX_ITEMS=1"; reg 'c|work|2|1024|3600|300|-|sleeper.sh'; seed; good 25; good 25; good 25
  check "tick: BALLAST_MAX_ITEMS=1 → só um item mesmo com orçamento" "1" "$(nstart)"

  newhome; seed; good 50; good 50; U=0; NI=0; ID=0; adv 50 0; bt
  check "tick: contador que anda para trás (reboot) → recomeça: primeira-leitura, free_ticks 0" "primeira-leitura 0" "$(jget note) $(jget free_ticks)"
  newhome; seed; good 50; good 50; adv 50 0 400; bt
  check "tick: lacuna de 400 s entre leituras (cron parado) zera a conta" "0" "$(jget free_ticks)"

  newhome; seed; printf 'lixo\n' > "$FP/stat"; NOW=$((NOW + 60)); bt
  check "tick: /proc/stat ilegível → leitura-ilegivel, não começa, rc 0" "0 leitura-ilegivel []" "$RC $(jget note) $(jget started)"
  newhome; seed; { k=0; while [ "$k" -lt "$NCPU" ]; do echo "cpu$k 5 5 5 5 5 5 5 5 0 0"; k=$((k+1)); done; } > "$FP/stat"; NOW=$((NOW + 60)); bt
  check "tick: /proc/stat SEM a linha agregada 'cpu' (só cpu0..cpu15) → leitura-ilegivel, não começa (a linha cpu0 não vale como total)" "leitura-ilegivel []" "$(jget note) $(jget started)"
  newhome; seed; good 50; good 50; setmem 28000; printf 'MemTotal: 1 kB\n' > "$FP/meminfo"; adv 50 0; bt
  check "tick: meminfo sem MemAvailable → leitura-ilegivel, não começa" "leitura-ilegivel []" "$(jget note) $(jget started)"

  newhome; seed; good 50; good 50; good 50
  pid=$(started_pid); run=$(started_run); alive "$pid" hq "$run"
  # outra instância: o lock está com o python de um 'sleep' do teste — o tick que não pega o lock não faz nada
  "$PY" -I -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(4)' "$H/lock" & lk=$!
  sleep 1; adv 50 0; bt
  check "tick: lock tomado por outra instância → nota outra-instancia, rc 0, nada muda" "0 outra-instancia" "$RC $(jget note)"
  wait "$lk" 2>/dev/null

  newhome; seed; chmod 500 "$H"; good 50
  check "tick: pasta de estado sem permissão de escrita → rc 3 (não consigo gravar) e nada começa" "3" "$RC"
  chmod 700 "$H"
}


# ── g_ram ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_ram() {
  newhome; seed; setmem 15000; good 50; good 50; good 50
  check "ram: 15000 MB livres < 14336 (piso de partida) + 1024 (rss do item) → não começa, ram baixa" "[] baixa" "$(jget started) $(jget ram)"
  setmem 15400; good 50; check "ram: 15400 MB → cabe: começa" "hq ok" "$(jget started.0.item) $(jget ram)"
  PID=$(started_pid); RUN=$(started_run); alive "$PID" hq "$RUN"

  setmem 9000; adv 50 0; bt
  check "ram: 9000 MB < piso de pausa (10240) → pausa o grupo (SIGSTOP), ram pausa, paused" "pausa true" "$(jget ram) $(jget paused)"
  sleep 0.3; check "ram: o processo do item ficou parado de verdade (estado T)" "T" "$(pstate "$PID")"
  setmem 11000; adv 50 0; bt; check "ram: 11000 MB (entre pausa e retomada 12288) → segue pausado" "true" "$(jget paused)"
  setmem 13000; adv 50 0; bt; sleep 0.3
  check "ram: 13000 MB >= retomada → SIGCONT, paused false" "false" "$(jget paused)"
  check "ram: o processo voltou a rodar (não está em T)" "1" "$([ "$(pstate "$PID")" != T ] && echo 1 || echo 0)"

  running_one; setmem 9000; adv 50 0; bt; adv 50 0; bt; adv 50 0; bt; adv 50 0; bt
  check "ram: pausado 4 leituras seguidas ainda vive" "0" "$(nkilled)"
  adv 50 0; bt
  check "ram: 5ª leitura pausada → mata o maior com SIGKILL (memória acabando não espera TERM) e o motivo ram-pausa" "1 ram-pausa KILL" "$(nkilled) $(jget killed.0.why) $(jget killed.0.sig)"
  isdead "$PID"; check "ram: o grupo morreu de verdade" "0" "$?"

  newhome; reg 'b|work|2|1024|3600|300|-|sleeper.sh'; seed; good 50; good 50; good 50
  p1=$(jget started.0.pid); r1=$(jget started.0.run); p2=$(jget started.1.pid); r2=$(jget started.1.run); alive "$p1" hq "$r1" 500000; alive "$p2" b "$r2" 100000
  setmem 6000; adv 50 0; bt
  check "ram: 6000 MB < piso crítico (7168) → mata na hora UM item, o de maior RSS (hq), com SIGKILL, motivo ram-critica" "1 hq ram-critica KILL" "$(nkilled) $(jget killed.0.item) $(jget killed.0.why) $(jget killed.0.sig)"
  isdead "$p1"; check "ram: o maior morreu" "0" "$?"
  check "ram: o menor segue vivo" "1" "$(kill -0 -- "-$p2" 2>/dev/null && echo 1 || echo 0)"
  kill -9 -- "-$p2" 2>/dev/null

  running_one; member 7000001 "$PID" 2000000; setmem 28000; adv 50 0; bt
  check "ram: soma de RSS do grupo (2 GB do filho + 1 MB) acima do teto do item (1024 MB) → mata, motivo rss" "1 rss" "$(nkilled) $(jget killed.0.why)"
  isdead "$PID"; check "ram: o grupo estourou o teto e morreu" "0" "$?"
}

# ── g_reap ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
smitem() {  # smitem — o item 'sm' rodando e visível; espera (até 10 s: o mini carregado leva centenas de ms por exec) o log ter a linha de resumo
  newhome; : > "$H/items.tsv"; reg 'sm|work|4|1024|3600|300|-|summary.sh'; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" sm "$RUN"
  local i=0; while [ "$i" -lt 50 ] && ! grep -q 'BALLAST-SUMMARY' "$H/runs/$RUN/log" 2>/dev/null; do sleep 0.2; i=$((i+1)); done
}
g_reap() {
  smitem; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; adv 50 0; bt
  check "reap: rc 0 + resumo no log → reaped, why ok" "sm 0 ok" "$(jget reaped.0.item) $(jget reaped.0.rc) $(jget reaped.0.why)"
  check "reap: results.jsonl ganha a linha com o resumo lido do log (pass 3)" "sm ok 3" "$(rj item) $(rj why) $(rj summary.pass)"
  check "reap: a rodada fica marcada como final (não é encerrada duas vezes)" "1" "$([ -e "$H/runs/$RUN/final" ] && echo 1 || echo 0)"
  adv 50 0; bt; check "reap: a mesma rodada não é reapada de novo" "1" "$(lines "$H/results.jsonl")"
  adv 50 0; bt; check "reap: dentro do cooldown (300 s) o item não recomeça" "[]" "$(jget started)"
  adv 50 0 300; bt; adv 50 0; bt; adv 50 0; bt; adv 50 0; bt
  check "reap: passado o cooldown, com 3 leituras livres seguidas, começa de novo" "sm" "$(jget started.0.item)"

  smitem; gone "$PID"; echo 3 > "$H/runs/$RUN/rc"; adv 50 0; bt
  check "reap: rc 3 → why rc-3 (nunca ok)" "3 rc-3" "$(jget reaped.0.rc) $(jget reaped.0.why)"
  adv 50 0 400; bt; adv 50 0; bt; adv 50 0; bt; adv 50 0; bt
  check "reap: item que falhou espera ao menos 600 s (400 s depois ainda não recomeça)" "[]" "$(jget started)"

  smitem; gone "$PID"; adv 50 0; bt
  check "reap: sumiu sem rc → why morreu-sem-rc e rc null (não é ok, não é falha de teste)" "null morreu-sem-rc" "$(jget reaped.0.rc) $(jget reaped.0.why)"

  smitem; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; printf 'x\nBALLAST-SUMMARY: {nope\n' > "$H/runs/$RUN/log"; adv 50 0; bt
  check "reap: resumo que não é JSON → summary null e summary_why ilegivel (a rodada segue ok)" "ok null ilegivel" "$(rj why) $(rj summary) $(rj summary_why)"
  smitem; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; printf 'sem resumo\n' > "$H/runs/$RUN/log"; adv 50 0; bt
  check "reap: log sem linha de resumo → summary_why ausente" "null ausente" "$(rj summary) $(rj summary_why)"
  smitem; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; printf 'BALLAST-SUMMARY: {"pass": 1}\nBALLAST-SUMMARY: {"pass": 9}\n' > "$H/runs/$RUN/log"; adv 50 0; bt
  check "reap: valem as últimas linhas (a última vence)" "9" "$(rj summary.pass)"
  smitem; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; printf 'BALLAST-SUMMARY: [1,2]\n' > "$H/runs/$RUN/log"; adv 50 0; bt
  check "reap: resumo que é JSON mas não é objeto → ilegivel (não vira dado)" "null ilegivel" "$(rj summary) $(rj summary_why)"

  smitem; member 7000002 "$PID" 2048; gone "$PID"; adv 50 0; bt
  check "reap: o líder sumiu mas um filho segue na sessão → o item AINDA roda (nada encerrado, nada recomeçado)" "[] [] sm" "$(jget reaped) $(jget started) $(jget running.0)"
  gone 7000002; adv 50 0; bt
  check "reap: quando o último filho some, a rodada é encerrada" "sm" "$(jget reaped.0.item)"

  smitem; printf 'sh\0-c\0x\0outro-programa\0' > "$FP/$PID/cmdline"; echo 0 > "$H/runs/$RUN/rc"; adv 50 0; bt
  check "reap: pid reaproveitado por outro programa (sem a marca) NÃO é o item: a rodada é encerrada" "sm" "$(jget reaped.0.item)"

  smitem; mv "$FP" "$FP.off"; NOW=$((NOW + 60)); bt; mv "$FP.off" "$FP"
  check "reap: sem conseguir ler os processos NINGUÉM é dado por morto (nenhum reaped, sem final)" "leitura-ilegivel 0" "$(jget note) $([ -e "$H/runs/$RUN/final" ] && echo 1 || echo 0)"
  smitem; chmod 311 "$FP"; adv 50 0; bt; chmod 755 "$FP"
  check "reap: /proc/stat e meminfo legíveis mas a LISTA de processos não (pasta sem leitura) → leitura-ilegivel, ninguém é dado por morto" "leitura-ilegivel [] 0" "$(jget note) $(jget reaped) $([ -e "$H/runs/$RUN/final" ] && echo 1 || echo 0)"

  newhome; : > "$H/items.tsv"; reg 'sl|work|4|1024|100|300|-|sleeper.sh'; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" sl "$RUN"
  adv 50 0 120; bt
  check "reap: dentro do prazo + 60 s de folga (120 s de 100) não mexe" "0" "$(nkilled)"
  adv 50 0 70; bt
  check "reap: passou prazo + folga (190 s > 160) e o grupo segue vivo → TERM, motivo prazo" "1 prazo" "$(nkilled) $(jget killed.0.why)"
  isdead "$PID"; check "reap: o item que respeita TERM morreu" "0" "$?"
  adv 50 0 10; bt
  check "reap: o item que levou TERM e ainda aparece vivo (dentro da graça de 20 s) NÃO é recomeçado: nenhuma segunda cópia" "[] [] sl" "$(jget started) $(jget killed) $(jget running.0 | sed 's/null/sl/')"

  newhome; : > "$H/items.tsv"; printf '#!/bin/sh\ntrap "" TERM\nsleep 300 &\nwait\n' > "$H/items/stubborn.sh"; chmod +x "$H/items/stubborn.sh"; reg 'st|work|4|1024|100|300|-|stubborn.sh'
  seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" st "$RUN"; sleep 0.5
  adv 50 0 170; bt; sleep 0.3
  check "reap: item que ignora TERM sobrevive ao primeiro golpe" "1" "$(kill -0 -- "-$PID" 2>/dev/null && echo 1 || echo 0)"
  adv 50 0 30; bt; sleep 0.3
  isdead "$PID"; check "reap: 20 s depois do TERM o governo manda KILL no que sobrou" "0" "$?"

  newhome; EXTRA_ENV="BALLAST_KEEP_RUNS=2"; : > "$H/items.tsv"; reg 'q|work|1|1024|3600|0|-|summary.sh'; seed; good 50; good 50; good 50; p=$(started_pid); r=$(started_run)
  for i in 1 2 3 4; do alive "$p" q "$r"; sleep 0.3; gone "$p"; kill -9 -- "-$p" 2>/dev/null; echo 0 > "$H/runs/$r/rc"; adv 50 0; bt; p=$(started_pid); r=$(started_run); done
  check "reap: BALLAST_KEEP_RUNS=2 guarda só as 2 últimas rodadas ENCERRADAS em runs/ (a que roda não conta)" "2" "$(ls "$H"/runs/*/final 2>/dev/null | wc -l | tr -d ' ')"
  check "reap: results.jsonl guarda a história inteira (4)" "4" "$(lines "$H/results.jsonl")"
  kill -9 -- "-$p" 2>/dev/null
}

# ── g_fill ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_fill() {
  newhome; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; seed; good 25; good 25; good 25
  check "fill: sem a flag burn.on o filler não é elegível (só o hq começa)" "hq 1" "$(jget started.0.item) $(nstart)"
  newhome; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; : > "$H/burn.on"; seed; good 25; good 25; good 25
  check "fill: com a flag, o work vem primeiro e o filler leva o resto do orçamento (11 - 4 = 7)" "hq queima 7" "$(jget started.0.item) $(jget started.1.item) $(jget started.1.cores)"
  p1=$(jget started.0.pid); r1=$(jget started.0.run); p2=$(jget started.1.pid); r2=$(jget started.1.run); alive "$p1" hq "$r1"; alive "$p2" queima "$r2"
  gone "$p1"; echo 0 > "$H/runs/$r1/rc"; adv 25 0; bt
  check "fill: o work acabou: filler segue rodando (cooldown do work corre)" "hq 0" "$(jget reaped.0.item) $(nkilled)"
  for i in 1 2 3 4 5; do adv 25 0; bt; done
  check "fill: cooldown do work acabou → o filler é morto (preempt) e o work começa NO MESMO tick" "queima preempt hq" "$(jget killed.0.item) $(jget killed.0.why) $(jget started.0.item)"
  isdead "$p2"; check "fill: o filler morto saiu mesmo" "0" "$?"
  p3=$(jget started.0.pid); r3=$(jget started.0.run); alive "$p3" hq "$r3"; gone "$p2"
  adv 25 0; bt
  check "fill: no tick seguinte o filler volta com o que sobrou do orçamento" "queima 7" "$(jget started.0.item) $(jget started.0.cores)"
  kill -9 -- "-$p3" 2>/dev/null

  newhome; : > "$H/items.tsv"; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; reg 'hq|work|4|1024|3600|300|-|sleeper.sh'; : > "$H/burn.on"; seed; good 25; good 25; good 25
  check "fill: mesmo com o filler ANTES no registro, o work começa primeiro e o filler leva só o resto (hq, queima 7)" "hq queima 7" "$(jget started.0.item) $(jget started.1.item) $(jget started.1.cores)"
  newhome; EXTRA_ENV="BALLAST_MAX_ITEMS=1"; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; : > "$H/burn.on"; seed; good 25; good 25; good 25
  check "fill: o teto de itens vale para o filler também (max 1: só o hq)" "hq 1" "$(jget started.0.item) $(nstart)"
}

# ── g_off ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_off() {
  newhome; rm -f "$H/on"; alive 7000100 estranho estranho-1700000000; seed; adv 50 0; bt
  check "off: processo com a marca ballast-item de OUTRA pasta de lastro (ex.: o selftest do próprio governo rodando como item) NÃO é nosso: não aparece em running e não é morto" "[] 0" "$(jget running) $(nkilled)"
  newhome; EXTRA_ENV="BALLAST_MAX_ITEMS=1"; alive 7000101 estranho estranho-1700000001; seed; good 50; good 50; good 50
  check "off: item estranho não gasta o teto de itens (max 1: o hq começa mesmo assim)" "hq" "$(jget started.0.item)"
  running_one; rm -f "$H/on"; adv 50 0; bt
  check "off: apagar a chave on mata o que roda (TERM), motivo desligado, mode desligado" "desligado 1 desligado" "$(jget mode) $(nkilled) $(jget killed.0.why)"
  isdead "$PID"; check "off: o item parou de verdade" "0" "$?"

  running_one; mv "$FP" "$FP.off"; rm -f "$H/on"; NOW=$((NOW + 60)); bt; mv "$FP.off" "$FP"
  check "off: desligado mas sem conseguir ler os processos → NÃO mata (leitura-ilegivel)" "leitura-ilegivel" "$(jget note)"
  kill -9 -- "-$PID" 2>/dev/null

  running_one; bt stop
  check "stop: mata o que roda mesmo com a chave ligada, devolve o que parou, rc 0" "0 hq" "$RC $(jget stopped.0.item)"
  isdead "$PID"; check "stop: o item morreu" "0" "$?"

  running_one; bt stop; gone "$PID"; adv 50 0; bt
  check "stop: a rodada parada à mão é encerrada com o motivo stop (não morreu-sem-rc) e SEM o cooldown de falha" "stop" "$(jget reaped.0.why)"
  check "stop: o cooldown da rodada parada é o do registro (300 s), não o de falha (600 s)" "300" "$("$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["cooldown"]["hq"] - d["last"]["t"])' "$H/state.json")"

  running_one; before=$(cd "$H" && find . -type f | sort | tr '\n' ' '); bt status --json; after=$(cd "$H" && find . -type f | sort | tr '\n' ' ')
  check "status: não grava nada" "$before" "$after"
  check "status: mostra o que roda e o modo" "hq ligado" "$(jget running.0) $(jget mode)"
  kill -9 -- "-$PID" 2>/dev/null
}

# ── g_state ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_state() {
  running_one; printf 'isto não é json' > "$H/state.json"; good 50; good 50; good 50; good 50
  check "state: state.json corrompido vai para o lado (state.json.corrupt-*) e recomeça" "1" "$(ls "$H" | grep -c '^state.json.corrupt-')"
  check "state: o item que JÁ roda (visto no /proc) não é duplicado depois de perder o estado" "[]" "$(jget started)"
  kill -9 -- "-$PID" 2>/dev/null

  newhome; printf '[1,2,3]' > "$H/state.json"; seed
  check "state: JSON válido de outra forma (lista) também é corrompido" "1" "$(ls "$H" | grep -c '^state.json.corrupt-')"
  newhome; printf '\xff\xfe{' > "$H/state.json"; seed
  check "state: bytes que não são UTF-8 também" "0 1" "$RC $(ls "$H" | grep -c '^state.json.corrupt-')"
  newhome; seed; chmod 000 "$H/state.json"; good 50; good 50; good 50
  check "state: ilegível por permissão NÃO recomeça: rc 3 e nada começa" "3" "$RC"
  chmod 600 "$H/state.json"
  newhome; seed; good 50; good 50; mkdir -p "$H/runs"; chmod 500 "$H"; good 50
  check "state: pasta sem escrita (mas com runs/ gravável) e 3 leituras livres → rc 3 e NADA começou (a escrita é conferida ANTES de começar)" "3 0" "$RC $(ls "$H/runs" 2>/dev/null | wc -l | tr -d ' ')"
  chmod 700 "$H"
}

# ── g_logs ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_logs() {
  newhome; seed; head -c 1300000 /dev/zero | tr '\0' 'x' | fold -w 99 > "$H/ticks.jsonl"; good 50
  check "logs: ticks.jsonl acima de 1 MB perde a metade mais velha e a linha nova fica no fim" "1 1" "$([ "$(wc -c < "$H/ticks.jsonl")" -lt 800000 ] && echo 1 || echo 0) $(tail -n 1 "$H/ticks.jsonl" | grep -c '"free_ticks"')"
  newhome; seed; head -c 400000 /dev/zero | tr '\0' 'e' | fold -w 99 > "$H/cron.err"; good 50
  check "logs: cron.err acima de 256 KB é cortado para os últimos 64 KB (o cron escreve nele a cada erro)" "1" "$([ "$(wc -c < "$H/cron.err")" -le 70000 ] && echo 1 || echo 0)"
  newhome; seed; printf 'erro antigo\n' > "$H/cron.err"; good 50
  check "logs: cron.err pequeno não é mexido" "erro antigo" "$(cat "$H/cron.err")"
}

# ── g_launch ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
mkstubs() {  # mkstubs DIR nome… — cada stub anota os argumentos e descarta os do próprio (nice -n 19 / chrt -i 0 / ionice -c 3 / timeout -k 30 N) antes de rodar o resto
  mkdir -p "$1"; local d="$1"; shift
  for x in "$@"; do
    case "$x" in timeout) k=3;; *) k=2;; esac
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nshift %s\nexec "$@"\n' "$x" "$d" "$k" > "$d/$x"; chmod +x "$d/$x"
  done
  ln -sf /bin/sh "$d/sh"; ln -sf "$(command -v sleep)" "$d/sleep"; ln -sf "$(command -v echo)" "$d/echo" 2>/dev/null; ln -sf "$(command -v env)" "$d/env"; ln -sf "$(command -v cat)" "$d/cat"
}
waitlines() {  # waitlines ARQUIVO N — espera (até 10 s: o mini carregado leva centenas de ms por exec) o arquivo ter N linhas
  local i=0; while [ "$i" -lt 50 ]; do [ "$(lines "$1")" -ge "$2" ] && return 0; sleep 0.2; i=$((i+1)); done; return 1
}
g_launch() {
  newhome; LP='5'; bt status --json
  check "launch: BALLAST_LAUNCH_PREFIX que não é uma lista JSON de textos → configuração inválida, rc 3 (nunca um prefixo vazio por engano)" "3" "$RC"
  newhome; LP='["nice", 3]'; bt status --json
  check "launch: lista com item que não é texto também é recusada (rc 3)" "3" "$RC"
  newhome; LP=""; D1="$W/lb1"; rm -rf "$D1"; mkstubs "$D1" nice chrt ionice timeout; EXTRA_ENV="PATH=$D1"; seed; good 50; good 50; good 50; waitlines "$D1/calls" 4
  check "launch: o prefixo padrão é nice -n 19, chrt -i 0, ionice -c 3 e depois timeout -k 30, nessa ordem" "nice -n 19|chrt -i 0|ionice -c 3|timeout -k 30" "$(sed -n '1,4p' "$D1/calls" 2>/dev/null | awk '{printf "%s %s %s%s", $1, $2, $3, (NR < 4 ? "|" : "")}')"
  check "launch: o prazo do timeout é o da coluna prazo_s do registro (3600)" "3600" "$(sed -n 4p "$D1/calls" 2>/dev/null | awk '{print $4}')"
  kill -9 -- "-$(started_pid)" 2>/dev/null

  newhome; LP=""; D2="$W/lb2"; rm -rf "$D2"; mkstubs "$D2" nice timeout; EXTRA_ENV="PATH=$D2"; bt status --json
  check "launch: sem chrt/ionice no PATH → só nice -n 19 (o que o /proc/stat conta como fundo)" "nice -n 19" "$(jget launch_prefix.0) $(jget launch_prefix.1) $(jget launch_prefix.2)"

  newhome; D3="$W/lb3"; rm -rf "$D3"; mkdir -p "$D3"; ln -sf /bin/sh "$D3/sh"; ln -sf "$(command -v sleep)" "$D3/sleep"; EXTRA_ENV="PATH=$D3"; seed; good 50; good 50; good 50
  check "launch: sem timeout no PATH o item NÃO começa (sem prazo não roda) e o status diz por quê" "[]" "$(jget started)"
  bt status --json; check "launch: motivo timeout" "1" "$(jget items.0.why | grep -c timeout)"

  newhome; : > "$H/items.tsv"; printf '#!/bin/sh\nenv > "$BALLAST_RUN_DIR/env.txt"\n[ -r /proc/self/oom_score_adj ] && cat /proc/self/oom_score_adj > "$BALLAST_RUN_DIR/oom.txt"\nsleep 300\n' > "$H/items/envdump.sh"; chmod +x "$H/items/envdump.sh"
  reg 'ev|work|4|1024|3600|300|-|envdump.sh'; EXTRA_ENV="SECRET_TOKEN=nao-pode-vazar"; seed; good 50; good 50; good 50; r=$(started_run); waitlines "$H/runs/$r/env.txt" 3
  check "launch: o item recebe BALLAST_CORES/ITEM/RUN_DIR e NENHUM segredo do ambiente do tick" "1 1 0" "$(grep -c '^BALLAST_CORES=4$' "$H/runs/$r/env.txt") $(grep -c '^BALLAST_ITEM=ev$' "$H/runs/$r/env.txt") $(grep -c 'nao-pode-vazar' "$H/runs/$r/env.txt")"
  if [ -r /proc/self/oom_score_adj ]; then check "launch: o item entra com oom_score_adj 1000 (se faltar memória, o kernel mata o lastro primeiro)" "1000" "$(cat "$H/runs/$r/oom.txt" 2>/dev/null)"; fi
  kill -9 -- "-$(started_pid)" 2>/dev/null
}

if [ -n "${HB_MUTANT:-}" ]; then g_reg; g_tick; g_ram; g_reap; g_fill; g_off; g_state; g_logs; g_launch; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HB_ONLY:-}" ]; then "g_$HB_ONLY"; echo "── $((n - fails))/$n ok (só g_$HB_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_reg; g_tick; g_ram; g_reap; g_fill; g_off; g_state; g_logs; g_launch

[ -n "${HB_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # lista: DESCRIÇÃO@@ANTES@@DEPOIS (as âncoras podem ter várias linhas; trocam EXATAMENTE uma ocorrência numa cópia). [linux] = só vale onde há /proc/self/oom_score_adj.
  cat > "$T/mutants.txt" <<'MUT'
carga conta o tempo em nice (o lastro viraria carga)@@fg = (d[0] + d[2] + d[5] + d[6] + d[7]) / float(dt)@@fg = (d[0] + d[1] + d[2] + d[5] + d[6] + d[7]) / float(dt)
15% exatos deixa de contar como livre (> no lugar de >=)@@rec["free_pct"] >= cfg.idle_min_pct else 0@@rec["free_pct"] > cfg.idle_min_pct else 0
leitura abaixo de 15% não zera a conta@@st["free_ticks"] = st["free_ticks"] + 1 if rec["free_pct"] >= cfg.idle_min_pct else 0@@st["free_ticks"] = st["free_ticks"] + 1
começa na 1ª leitura livre (sem histerese)@@st["free_ticks"] >= cfg.idle_ticks:@@st["free_ticks"] >= 1:
orçamento sem a reserva de núcleos@@budget = int(ncpu - rec["fg_cores"] - cfg.reserve + 1e-9)@@budget = int(ncpu - rec["fg_cores"] + 1e-9)
item de N núcleos cabe mesmo estourando o orçamento (> vira >=... trocado por nunca)@@if not ok or cores < 1 or used + cores > budget:@@if not ok or cores < 1:
auto leva o orçamento inteiro, sem descontar o que já roda@@cores = it["cores"] if it["cores"] != "auto" else budget - used
            if not ok@@cores = it["cores"] if it["cores"] != "auto" else budget
            if not ok
teto de itens ignorado@@if len(run) + len(rec["started"]) >= cfg.max_items:
                break@@if False:
                break
contador que anda para trás é aceito@@if not last or any(v < l for v, l in zip(vec, last["vec"])):@@if not last:
lacuna entre leituras ignorada@@if cfg.now - last["t"] > cfg.gap_s:@@if False:
lock de instância única ignorado@@    except OSError:
        rec["note"] = "outra-instancia"@@    except ZeroDivisionError:
        rec["note"] = "outra-instancia"
escrita não conferida antes de começar@@        with open(probe, "w") as f:
            f.write("x")
        os.remove(probe)@@        pass
/proc/stat ilegível vira leitura boa@@    if len(f) < 9 or f[0] != "cpu":@@    if False:
meminfo sem MemAvailable vira 0 MB@@    raise Unreadable("/proc/meminfo: sem MemAvailable")@@    return 0
tabela de processos ilegível vira lista vazia@@    except OSError as e:
        raise Unreadable("%s: %s" % (root, e))
    out = []@@    except OSError as e:
        return []
    out = []
RAM de partida ignora o teto de RSS do item@@if mem - it["rss_mb"] < cfg.ram_start_mb:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append@@if mem < cfg.ram_start_mb:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append
pausa manda CONT em vez de STOP@@send(r, signal.SIGSTOP)@@send(r, signal.SIGCONT)
retomada nunca acontece (sem a histerese)@@    elif mem < cfg.ram_pause_mb or (st["paused"] and mem < cfg.ram_resume_mb):@@    elif mem < cfg.ram_pause_mb:
pausa que não passa não mata (limite de leituras ignorado)@@if st["paused_ticks"] >= cfg.pause_kill_ticks:@@if st["paused_ticks"] >= 10**9:
mata o MENOR em vez do maior RSS@@biggest = max(run.values(), key=lambda r: r["rss_kb"]) if run else None@@biggest = min(run.values(), key=lambda r: r["rss_kb"]) if run else None
RAM crítica não mata na hora@@        if biggest:
            kill_now(cfg, st, biggest, "ram-critica", rec)@@        if False:
            kill_now(cfg, st, biggest, "ram-critica", rec)
RAM crítica manda TERM (um grupo parado não trata)@@kill_now(cfg, st, biggest, "ram-pausa", rec)@@terminate(cfg, st, biggest, "ram-pausa", rec)
teto de RSS do item ignorado@@elif m and r["rss_kb"] > m["rss_mb"] * 1024:@@elif False:
sem rc vira ok@@why = killed or ("ok" if rc == 0 else@@why = killed or ("ok" if rc in (0, None) else
resumo que não é objeto vira dado@@    return (v, "") if isinstance(v, dict) else (None, "ilegivel")@@    return (v, "")
vale a primeira linha de resumo, não a última@@        v = json.loads(lines[-1][len("BALLAST-SUMMARY: "):])@@        v = json.loads(lines[0][len("BALLAST-SUMMARY: "):])
falha não ganha o cooldown mínimo@@    if why not in ("ok", "desligado", "preempt", "stop"):
        cool = max(cool, cfg.fail_cooldown_s)@@    if False:
        cool = max(cool, cfg.fail_cooldown_s)
rodada encerrada duas vezes (sem a marca final)@@        with open(os.path.join(rundir, "final"), "w") as f:
            f.write("%d\n" % cfg.now)@@        with open(os.path.join(rundir, "final2"), "w") as f:
            f.write("%d\n" % cfg.now)
pid reaproveitado vale como item (a marca não é conferida)@@        if run not in cand and (ldr is None or ldr["state"] == "Z"):@@        if run not in cand:
filho vivo na sessão não segura a rodada (só o líder vale)@@        mem = [q for q in procs if q["sid"] == pid and q["state"] != "Z"]@@        mem = [q for q in procs if q["pid"] == pid and q["state"] != "Z"]
prazo ignorado@@elif m and isinstance(m.get("start"), int) and cfg.now - m["start"] > m["timeout_s"] + cfg.deadline_slack_s:@@elif False:
TERM ignorado nunca vira KILL@@if cfg.now - t >= cfg.term_grace_s:@@if False:
desligar não mata@@            elif not on:
                terminate(cfg, st, r, "desligado", rec)@@            elif False:
                terminate(cfg, st, r, "desligado", rec)
filler não é morto quando um work vai começar@@                if m.get("role") == "filler" and r["run"] not in st["term"]:@@                if False:
filler entra antes do work (conta no orçamento do work)@@            if it["role"] != "work":
                continue@@            if it["role"] not in ("work", "filler"):
                continue
estado corrompido não vai para o lado@@            os.replace(path, aside)@@            pass
estado de outra forma (lista) passa por válido@@        if not (isinstance(st, dict) and st.get("v") == 1 and@@        if not (True and
estado ilegível por permissão recomeça@@        raise Fail("%s: não abre (%s)" % (path, e))@@        return fresh_state()
registro com nome repetido aceito@@            if name in seen:
                raise ValueError("nome repetido %r" % name)@@            if False:
                raise ValueError("nome repetido %r" % name)
registro com coluna a menos aceito@@        if len(c) != 8:@@        if len(c) < 7:
predicado de requires desconhecido vira verdadeiro@@            return False, "requires: predicado desconhecido %r" % term.strip()@@            continue
comando sem permissão de execução aceito@@    if not (os.path.isfile(argv[0]) and os.access(argv[0], os.X_OK)):@@    if not os.path.isfile(argv[0]):
nice 19 trocado por nice 0 no prefixo@@    pre = ["nice", "-n", "19"]@@    pre = ["nice", "-n", "0"]
o item herda o ambiente inteiro do tick (segredos vazam)@@    env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": os.path.expanduser("~"),@@    env = {**os.environ, "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": os.path.expanduser("~"),
[linux] o item não entra com oom_score_adj@@{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; @@
sem timeout no PATH o item começa assim mesmo@@    if shutil.which("timeout") is None:
        return False, "timeout ausente no PATH (sem prazo não começa)"@@    if False:
        return False, "timeout ausente no PATH (sem prazo não começa)"
cooldown ignorado@@    if until > cfg.now:@@    if False:
stop não devolve o que parou@@        out["stopped"].append({"item": r["item"], "run": r["run"], "pid": r["pid"]})@@        pass
a marca ballast-item de OUTRA pasta de lastro vale como item nosso@@ and (valid is None or parts[1] in valid):@@ and True:
stop não anota o motivo da rodada@@            st["killed"].setdefault(r["run"], "stop")@@            pass
rodada parada à mão ganha o cooldown de falha@@"preempt", "stop"):@@"preempt"):
cron.err cresce sem teto@@    trim_log(os.path.join(cfg.home, "cron.err"), 262144, 65536)@@    pass
ticks.jsonl cresce sem teto@@        if os.path.exists(path) and os.path.getsize(path) > cap:@@        if False:
quem levou TERM e ainda morre é recomeçado em cima@@        running_names = seen_names | {k["item"] for k in rec["killed"]}@@        running_names = {r["item"] for r in run.values()} | {k["item"] for k in rec["killed"]}
prefixo de lançamento inválido é aceito@@    if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):@@    if False:
MUT
  "$PY" -I - "$P" "$T/mutants.txt" "$T" > "$T/mutants.idx" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
entries, cur = [], None
for line in open(sys.argv[2], encoding="utf-8").read().split("\n"):
    if cur is None or (cur.count("@@") >= 2 and re.match(r"^[^@\s][^@]*@@", line)):
        if cur is not None:
            entries.append(cur)
        cur = line
    else:
        cur += "\n" + line
if cur:
    entries.append(cur)
for i, e in enumerate(entries, 1):
    parts = e.split("@@")
    if len(parts) != 3 or src.count(parts[1]) != 1:
        print("%d\tBAD\t%s" % (i, parts[0]))
        continue
    open("%s/mut%d.py" % (sys.argv[3], i), "w", encoding="utf-8").write(src.replace(parts[1], parts[2]))
    print("%d\tOK\t%s" % (i, parts[0]))
PYEOF
  JOBS=${HB_JOBS:-4}
  while IFS="$(printf '\t')" read -r idx st desc; do
    if [ "$st" != OK ]; then ok 1 "mutante '$desc': a âncora não casa exatamente 1 vez (o script mudou?)"; continue; fi
    case "$desc" in "[linux]"*) [ -r /proc/self/oom_score_adj ] || { echo "skip mutante '$desc' (sem /proc/self/oom_score_adj neste host)"; continue; };; esac
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    ( HB_MUTANT=1 HB_UNDER_TEST="$T/mut$idx.py" bash "$0" 2>&1 | tail -1 > "$T/mres.$idx" ) &
  done < "$T/mutants.idx"
  wait
  while IFS="$(printf '\t')" read -r idx st desc; do
    [ "$st" = OK ] || continue
    [ -f "$T/mres.$idx" ] || continue   # pulado
    r=$(cat "$T/mres.$idx")
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$desc' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$desc' pego ($r)";; *) ok 1 "mutante '$desc': sem resultado ($r)";; esac
  done < "$T/mutants.idx"
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
