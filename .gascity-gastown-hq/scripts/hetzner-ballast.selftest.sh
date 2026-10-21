#!/usr/bin/env bash
# hetzner-ballast.selftest.sh — hermético (ga-2hd02v.5): o /proc é uma pasta de fixtures (BALLAST_PROC), o relógio é BALLAST_NOW, o "nó" é uma pasta temporária e os itens são scripts de
# brinquedo. Nada fala com o nó de verdade e nada toca em ~/gt-remote.
# Contents: Casos · Controle negativo (mutantes) · Variáveis
# CASOS (fatia 2/5: MEDE e COMEÇA; encerrar, RAM, prazo, filler e stop são a 3/5): registro (g_reg) · tick (g_tick: chave on, histerese de 3 leituras, nice não é carga, orçamento, teto, lacuna, leituras
#   ilegíveis, lock) · processos (g_run: marca + pasta runs/ desta pasta, duplicata, o que já roda ocupa núcleos e teto) · estado (g_state: forma, corrompido, permissão) · lançamento (g_launch).
# CONTROLE NEGATIVO: cada mutante (um trecho do script trocado) TEM que reprovar a bateria.
# VARIÁVEIS: HB_UNDER_TEST (script a testar) · HB_PY (interpretador; padrão /usr/bin/python3) · HB_NO_MUTANTS=1 · HB_ONLY=<grupo> (reg tick run state launch; sem mutantes)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${HB_UNDER_TEST:-$HERE/hetzner-ballast.py}"
PY="${HB_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hb.XXXXXX)" && pwd -P)
# killtree CAMINHO — mata, pelo GRUPO de processos, tudo que leva CAMINHO na linha de comando (o item roda em sessão própria e seus filhos `sleep 300` não levam o caminho: `pkill -f` os deixava órfãos; incidente 20/10). Poupa o grupo do teste.
killtree() {
  local g self; self=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  for g in $(ps -axo pgid=,command= 2>/dev/null | awk -v p="$1" 'index($0, p) { print $1 }' | sort -u); do
    case "$g" in ''|*[!0-9]*) continue ;; esac
    [ "$g" -gt 1 ] && [ "$g" != "$self" ] && kill -KILL -- "-$g" 2>/dev/null
  done
  return 0
}
cleanup() { killtree "$T/"; pkill -f "$T/" 2>/dev/null; sleep 0.2; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 143' TERM INT HUP   # sem isto um TERM/INT (TaskStop, ctrl-c) pula o EXIT e deixa os itens órfãos
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
  [ -z "$H" ] || killtree "$H/"   # os itens do fixture anterior morrem AGORA: acumulá-los até o fim da bateria era o que carregava o mini
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
  OUT=$(env PATH="$W/bin:$PATH" BALLAST_HOME="$H" BALLAST_PROC="$FP" BALLAST_NOW="$NOW" BALLAST_LAUNCH_PREFIX="$LP" BALLAST_TEST=1 $EXTRA_ENV "$PY" -I "$P" "$@" 2>"$W/err"); RC=$?
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
running_one() {  # running_one — newhome + o hq (4 núcleos) já rodando e visível no /proc de mentira: PID e RUN
  newhome; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" hq "$RUN"
}
seed() { bt; }                                          # a 1ª leitura só semeia o baseline
good() { adv "${1:-50}" "${2:-0}"; bt; }               # uma leitura com CPU livre (padrão: 50% de carga de sessões)
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

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

  newhome; rm -f "$H/items.tsv"; seed; adv 50 0; bt; adv 50 0; bt; adv 50 0; bt
  check "reg: registro ausente → nada começa, nota registro-ilegivel, rc 0, registry_errors null (não leu; [] seria 'leu e está limpo')" "0 registro-ilegivel [] null" "$RC $(jget note) $(jget started) $(jget registry_errors)"
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

  newhome; seed; setmem 15000; good 50; good 50; good 50
  check "tick: 15000 MB livres < 14336 (piso de partida) + 1024 (teto de RSS do item) → não começa, ram baixa" "[] baixa" "$(jget started) $(jget ram)"
  setmem 15400; good 50; check "tick: 15400 MB → cabe: começa" "hq" "$(jget started.0.item)"
  newhome; reg 'c|work|2|1024|3600|300|-|sleeper.sh'; setmem 15500; seed; good 25; good 25; good 25
  check "tick: 15500 MB cabem UM item (a RAM é lida uma vez, mas cada item começado a desconta): hq começa, c fica de fora, ram baixa" "hq 1 baixa" "$(jget started.0.item) $(nstart) $(jget ram)"
  newhome; seed; good 50; "$PY" -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["cooldown"]["hq"]=int(sys.argv[2])+600; json.dump(d, open(p,"w"))' "$H/state.json" "$NOW"; good 50; good 50
  check "tick: item em cooldown (lido do state.json) não começa mesmo com a CPU livre" "[]" "$(jget started)"
  bt status --json; check "tick: o status diz o porquê (cooldown)" "1" "$(jget items.0.why | grep -c cooldown)"
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
  check "tick: lock tomado por outra instância → nota outra-instancia, rc 0, mode null (não leu a chave on)" "0 outra-instancia null" "$RC $(jget note) $(jget mode)"
  wait "$lk" 2>/dev/null

  newhome; seed; chmod 500 "$H"; good 50
  check "tick: pasta de estado sem permissão de escrita → rc 3 (não consigo gravar) e nada começa" "3" "$RC"
  chmod 700 "$H"
}

# ── g_run ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_run() {
  newhome; alive 7000100 estranho estranho-1700000000; seed; adv 50 0; bt
  check "run: processo com a marca ballast-item de OUTRA pasta de lastro (ex.: o selftest do próprio governo rodando como item) NÃO é nosso: não aparece em running" "[]" "$(jget running)"
  newhome; EXTRA_ENV="BALLAST_MAX_ITEMS=1"; alive 7000101 estranho estranho-1700000001; seed; good 50; good 50; good 50
  check "run: item estranho não gasta o teto de itens (max 1: o hq começa mesmo assim)" "hq" "$(jget started.0.item)"
  running_one; reg 'big|work|12|1024|3600|300|-|sleeper.sh'; adv 0 0; bt
  check "run: nó ocioso (orçamento 15): o hq que roda aparece em running e NÃO é duplicado, e o big(12) não cabe ao lado dos 4 que já rodam (16 > 15)" "hq []" "$(jget running.0) $(jget started)"
  member 7000002 "$PID" 2048; gone "$PID"; adv 0 0; bt
  check "run: o líder sumiu mas um filho segue na sessão → o item AINDA roda (nada recomeçado em cima)" "hq []" "$(jget running.0) $(jget started)"
  gone 7000002; mkdir -p "$FP/$PID"; printf '%s (sh) S 1 %s %s 0 0\n' "$PID" "$PID" "$PID" > "$FP/$PID/stat"; printf '0 256 0 0 0 0 0\n' > "$FP/$PID/statm"; printf 'sh\0-c\0x\0outro-programa\0' > "$FP/$PID/cmdline"; adv 50 0; bt
  check "run: pid reaproveitado por outro programa (líder vivo SEM a marca da rodada) NÃO é o item" "[]" "$(jget running)"
  newhome; EXTRA_ENV="BALLAST_MAX_ITEMS=2"; reg 'b|work|2|1024|3600|300|-|sleeper.sh'; seed; good 25; good 25; good 25
  alive "$(jget started.0.pid)" hq "$(jget started.0.run)"; alive "$(jget started.1.pid)" b "$(jget started.1.run)"; reg 'c|work|2|1024|3600|300|-|sleeper.sh'; adv 0 0; bt
  check "run: 2 itens já rodando e BALLAST_MAX_ITEMS=2: o c cabe no orçamento e na RAM, mas o teto conta o que JÁ roda" "[] b hq" "$(jget started) $(jget running.0) $(jget running.1)"
  running_one; rm -f "$H/runs/$RUN/meta.json"; reg 'b|work|4|1024|3600|300|-|sleeper.sh'; adv 50 0; bt
  check "run: item rodando com a meta.json sumida ocupa o que o REGISTRO diz (4), não 1: b(4) não cabe no orçamento 7, e a nota avisa" "[] 1" "$(jget started) $(jget note | grep -c cores-desconhecidos)"
  printf '{"item":"hq","cores":0}' > "$H/runs/$RUN/meta.json"; adv 50 0; bt; check "run: meta.json com núcleos 0 também não vale (o item não encolhe o que ocupa)" "[]" "$(jget started)"
  rm -f "$H/runs/$RUN/meta.json"; : > "$H/items.tsv"; reg 'b|work|1|1024|3600|300|-|sleeper.sh'; adv 50 0; bt; check "run: rodando, sem meta.json e FORA do registro → ocupa o orçamento inteiro: nem o b(1) começa" "[]" "$(jget started)"
  newhome; seed; good 50; good 50; mkdir -p "$FP/4242"; printf 'lixo' > "$FP/4242/stat"; adv 50 0; bt; check "run: a tabela lista um processo e NENHUM é legível → leitura-ilegivel, nada começa e running null (não é 'ninguém roda')" "leitura-ilegivel [] null" "$(jget note) $(jget started) $(jget running)"
  newhome; seed; mv "$FP" "$FP.off"; NOW=$((NOW + 60)); bt; mv "$FP.off" "$FP"
  check "run: sem conseguir ler nada do /proc → leitura-ilegivel, rc 0, nada começa" "0 leitura-ilegivel []" "$RC $(jget note) $(jget started)"
  newhome; seed; good 50; good 50; chmod 311 "$FP"; adv 50 0; bt; chmod 755 "$FP"
  check "run: /proc/stat e meminfo legíveis mas a LISTA de processos não → leitura-ilegivel e nada começa (não é 'ninguém roda'); running null, não []" "leitura-ilegivel [] null" "$(jget note) $(jget started) $(jget running)"
}

# ── g_state ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_state() {
  running_one; printf 'isto não é json' > "$H/state.json"; good 50; good 50; good 50; good 50
  check "state: state.json corrompido vai para o lado (state.json.corrupt-*) e recomeça" "1" "$(ls "$H" | grep -c '^state.json.corrupt-')"
  check "state: o item que JÁ roda (visto no /proc) não é duplicado depois de perder o estado" "[]" "$(jget started)"
  kill -9 -- "-$PID" 2>/dev/null

  newhome; seed; head -c 1300000 /dev/zero | tr '\0' 'x' | fold -w 99 > "$H/ticks.jsonl"; good 50
  check "state: ticks.jsonl acima de 1 MB perde a metade mais velha e a linha nova fica no fim" "1 1" "$([ "$(wc -c < "$H/ticks.jsonl")" -lt 800000 ] && echo 1 || echo 0) $(tail -n 1 "$H/ticks.jsonl" | grep -c '"free_ticks"')"
  newhome; printf '[1,2,3]' > "$H/state.json"; seed
  check "state: JSON válido de outra forma (lista) também é corrompido" "1" "$(ls "$H" | grep -c '^state.json.corrupt-')"
  newhome; printf '{"v":1,"last":5,"free_ticks":0,"cooldown":{}}' > "$H/state.json"; seed; r1=$RC; c1=$(ls "$H" | grep -c '^state.json.corrupt-'); good 50
  check "state: JSON válido com last de forma errada → vai para o lado (rc 0) e o tick seguinte funciona (não repete o erro)" "0 1 0" "$r1 $c1 $RC"
  newhome; bt status --json; s1=$(jget state); printf '[1,2,3]' > "$H/state.json"; bt status --json
  check "state: status com estado ausente → state ausente; com JSON de forma errada (lista) → ilegivel, rc 0, sem quebrar" "ausente ilegivel 0" "$s1 $(jget state) $RC"
  newhome; printf '\xff\xfe{' > "$H/state.json"; seed
  check "state: bytes que não são UTF-8 também" "0 1" "$RC $(ls "$H" | grep -c '^state.json.corrupt-')"
  newhome; seed; chmod 000 "$H/state.json"; good 50; good 50; good 50
  check "state: ilegível por permissão NÃO recomeça: rc 3 e nada começa" "3" "$RC"
  chmod 600 "$H/state.json"
  newhome; seed; good 50; good 50; mkdir -p "$H/runs"; chmod 500 "$H"; good 50
  check "state: pasta sem escrita (mas com runs/ gravável) e 3 leituras livres → rc 3 e NADA começou (a escrita é conferida ANTES de começar)" "3 0" "$RC $(ls "$H/runs" 2>/dev/null | wc -l | tr -d ' ')"
  chmod 700 "$H"
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
  newhome; EXTRA_ENV="BALLAST_TEST=0"; LP='[]'; bt status --json; r1=$RC; LP='["chrt","-i","0"]'; bt status --json; r2=$RC; LP='["nice","-n","19"]'; bt status --json
  check "launch: fora do selftest o prefixo precisa ter nice: [] e um prefixo sem nice → rc 3; com nice → rc 0" "3 3 0" "$r1 $r2 $RC"
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

if [ -n "${HB_MUTANT:-}" ]; then g_reg; g_tick; g_run; g_state; g_launch; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HB_ONLY:-}" ]; then "g_$HB_ONLY"; echo "── $((n - fails))/$n ok (só g_$HB_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_reg; g_tick; g_run; g_state; g_launch

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
auto leva o orçamento inteiro, sem descontar o que já roda@@cores = it["cores"] if it["cores"] != "auto" else budget - used@@cores = it["cores"] if it["cores"] != "auto" else budget
teto de itens ignorado@@if len(run) + len(rec["started"]) >= cfg.max_items:@@if False:
teto de itens não conta o que JÁ roda@@if len(run) + len(rec["started"]) >= cfg.max_items:@@if len(rec["started"]) >= cfg.max_items:
contador que anda para trás é aceito@@if not last or any(v < l for v, l in zip(vec, last["vec"])):@@if not last:
lacuna entre leituras ignorada@@if cfg.now - last["t"] > cfg.gap_s:@@if False:
lock de instância única ignorado (o flock espera em vez de falhar)@@fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)@@fcntl.flock(lock, fcntl.LOCK_EX)
escrita não conferida antes de começar@@        raise Fail("%s: não consigo gravar (%s)" % (cfg.home, e))@@        pass
/proc/stat ilegível vira leitura boa@@    if len(f) < 9 or f[0] != "cpu":@@    if False:
meminfo sem MemAvailable vira 0 MB@@    raise Unreadable("/proc/meminfo: sem MemAvailable")@@    return 0
tabela de processos ilegível vira lista vazia@@        raise Unreadable("%s: %s" % (root, e))@@        return []
pid reaproveitado vale como item (a marca não é conferida)@@        if run not in cand and (ldr is None or ldr["state"] == "Z"):@@        if run not in cand:
filho vivo na sessão não segura a rodada (só o líder vale)@@        mem = [q for q in procs if q["sid"] == pid and q["state"] != "Z"]@@        mem = [q for q in procs if q["pid"] == pid and q["state"] != "Z"]
estado corrompido não vai para o lado@@            os.replace(path, aside)@@            pass
estado de outra forma (lista) passa por válido@@    if not (isinstance(st, dict) and st.get("v") == 1 and@@    if not (True and
estado ilegível por permissão recomeça@@        raise Fail("%s: não abre (%s)" % (path, e))@@        return fresh_state()
registro com nome repetido aceito@@if name in seen:@@if False:
registro com coluna a menos aceito@@        if len(c) != 8:@@        if len(c) < 7:
predicado de requires desconhecido vira verdadeiro@@            return False, "requires: predicado desconhecido %r" % term.strip()@@            continue
comando sem permissão de execução aceito@@    if not (os.path.isfile(argv[0]) and os.access(argv[0], os.X_OK)):@@    if not os.path.isfile(argv[0]):
nice 19 trocado por nice 0 no prefixo@@    pre = ["nice", "-n", "19"]@@    pre = ["nice", "-n", "0"]
o item herda o ambiente inteiro do tick (segredos vazam)@@    env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": os.path.expanduser("~"),@@    env = {**os.environ, "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "HOME": os.path.expanduser("~"),
[linux] o item não entra com oom_score_adj@@{ echo 1000 > /proc/self/oom_score_adj; } 2>/dev/null; @@
sem timeout no PATH o item começa assim mesmo@@if shutil.which("timeout") is None:@@if False:
cooldown ignorado@@    if until > cfg.now:@@    if False:
a marca ballast-item de OUTRA pasta de lastro vale como item nosso@@ and (valid is None or parts[1] in valid):@@ and True:
RAM de partida ignora o teto de RSS do item@@if mem_left - it["rss_mb"] < cfg.ram_start_mb:@@if mem_left < cfg.ram_start_mb:
ticks.jsonl cresce sem teto@@        if os.path.exists(path) and os.path.getsize(path) > cap:@@        if False:
prefixo de lançamento inválido é aceito@@    if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):@@    if False:
prefixo sem nice aceito fora do selftest@@    if not test and "nice" not in v:@@    if False:
a RAM lida uma vez: o item começado não desconta a sobra do seguinte@@                mem_left -= it["rss_mb"]@@                pass
item que roda não ocupa núcleos (running_cores zerado)@@        tot += c@@        tot += 0
meta.json ausente conta 1 núcleo (errar para menos)@@            c = budget if c == "auto" else c@@            c = 1
meta.json com núcleos 0 vale@@if not (_int(c) and c >= 1):@@if not _int(c):
item que já roda pode ser começado de novo (rodando ignorado)@@    if item["name"] in running_names:@@    if False:
tabela de processos ilegível aparece como running [] no registro@@ if procs is not None else None@@
mode padrão ligado quando o tick não leu a chave on@@"mode": None, "note": ""@@"mode": "ligado", "note": ""
registry_errors padrão [] quando o registro não foi lido@@"registry_errors": None, "ram": None}@@"registry_errors": [], "ram": None}
estado com last de forma errada passa por válido@@last is None or (isinstance(last, dict)@@True or (isinstance(last, dict)
status não valida a forma do estado@@            st = fresh_state()@@            pass
status não distingue estado ausente@@        out["state"] = "ausente"@@        pass
pids listados e nenhum legível viram "ninguém roda"@@    if seen and not out:@@    if False:
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
