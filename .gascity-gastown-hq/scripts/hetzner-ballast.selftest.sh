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
#     teto de itens · contador que anda para trás ou lacuna de mais de 3 min recomeça a conta · /proc/stat ou meminfo ilegível = não começa (desligar e prazo seguem valendo; a tabela de processos ilegível é que não mata) · outra instância
#     rodando = não faz nada · pasta sem permissão = rc 3.
#   processos (g_run): o que roda é achado na tabela de processos (marca + pasta runs/<rodada> DESTA pasta; marca de outra pasta não é nossa; pid 0/1 na meta.json não é líder) · duplicata · o que já roda ocupa núcleos (meta.json sumida = o que o registro diz) e teto · lista de processos ilegível ≠ ninguém roda.
#   RAM (g_ram): abaixo do piso de partida não começa · abaixo do piso de pausa congela (SIGSTOP) e volta (SIGCONT) com folga · pausa que não passa em N leituras mata o maior ·
#     abaixo do piso crítico mata o maior na hora · RSS do item acima do teto dele mata.
#   fim e resultado (g_reap): rc 0 / rc≠0 / sem rc / resumo ilegível viram linha em results.jsonl, nunca "ok" por falta de leitura · cooldown · pid reaproveitado não é o item ·
#     prazo estourado (TERM, depois KILL) · quem sumiu sem a leitura de processos não é dado por morto.
#   enchimento (g_fill): item `filler` só entra com a flag, é morto quando um item `work` vai começar e nunca conta no orçamento do `work`.
#   desligar (g_off): chave `on` apagada mata o que roda (TERM+CONT; vale com meminfo ilegível) · `stop` idem, e só diz que parou o que a SESSÃO do item mostra vazia (item noutro grupo da sessão, como com o
#     timeout do GNU, leva KILL; sobrevivente → rc 5 `survivors`; tabela ilegível depois do TERM → rc 5 `unverified`, sem KILL às cegas) · `status` diz o estado sem gravar.
#   estado (g_state): state.json corrompido vai para o lado e recomeça sem duplicar o que já roda (o processo é a fonte da verdade) · ilegível por permissão = inerte (rc 3).
#   lançamento (g_launch): prefixo nice 19 + SCHED_IDLE + ionice idle + timeout -k, com o que existir no PATH; sem `timeout` o item não começa.
#   sinais (g_send): send() com um membro da sessão que o runner não pode sinalizar (o bash root do helper do gt-iso-run, item wa-suite): o sinal chega aos outros, inclusive aos que vêm depois do que recusou, sem levantar ·
#     grupo do líder já sumido (o timeout do GNU muda de grupo) ainda sinaliza os membros · ninguém aceitou o sinal = False, nunca True por ter tentado.
#   teto (g_ceil, hermético; g_cgrp, o kernel de verdade): cada item começa num escopo systemd do usuário com TasksMax/MemoryMax (sem gerenciador de usuário NÃO começa) · o tick lê pids.events/memory.events do
#     cgroup do item e o mata (teto-processos / teto-memoria; contador ilegível ≠ zero estouros) · o caminho do cgroup só vale se for o escopo DESTA rodada na ballast.slice · fim de rodada e stop mandam
#     cgroup.kill (pega quem fez setsid) · os picos do item entram em results.jsonl. g_cgrp só roda onde há systemd --user (senão `skip`, que NÃO conta como passou): fork em laço e alocador, ambos LIMITADOS por construção.
# CONTROLE NEGATIVO: cada mutante (um trecho do script trocado) TEM que reprovar a bateria. Mutante com descrição `[teto]` roda só os grupos do teto.
# VARIÁVEIS: HB_UNDER_TEST (script a testar) · HB_PY (interpretador; padrão /usr/bin/python3) · HB_NO_MUTANTS=1 · HB_MUTANTS_ONLY=teto (só os mutantes do teto) · HB_ONLY=<grupo> (reg tick run ram reap fill off state logs launch send ceil cgrp; sem mutantes)
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
N=0; H=""; FP=""; NOW=0; U=0; NI=0; ID=0; EXTRA_ENV=""; LP='[]'; PID=""; RUN=""; CEIL=""; SD=""; CGD=""

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
  NOW=1800000000; U=0; NI=0; ID=0; EXTRA_ENV=""; LP='[]'; CEIL=""; setmem 28000; writestat
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
  OUT=$(env PATH="$W/bin:$PATH" BALLAST_HOME="$H" BALLAST_PROC="$FP" BALLAST_NOW="$NOW" BALLAST_LAUNCH_PREFIX="$LP" BALLAST_TEST=1 BALLAST_CEILING="${CEIL:-off}" $EXTRA_ENV "$PY" -I "$P" "$@" 2>"$W/err"); RC=$?
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
plive() { kill -0 "$1" 2>/dev/null && [ "$(pstate "$1")" != Z ]; }   # o PROCESSO existe (zumbi não conta)
pdead() {  # pdead PID… — cada PROCESSO sumiu: espera até 3 s por cada um. Olha o processo e não o grupo (o item pode estar noutro grupo da sessão)
  local p i; for p in "$@"; do i=0; while [ "$i" -lt 15 ] && plive "$p"; do sleep 0.2; i=$((i+1)); done; ! plive "$p" || return 1; done
}
running_one() {  # running_one — newhome + o hq (4 núcleos) já rodando e visível no /proc de mentira: PID e RUN
  newhome; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" hq "$RUN"
}
trapper_up() {  # trapper_up — newhome + o item `tp` (anota `termed` ao tratar o TERM) rodando, PARADO (SIGSTOP no grupo) e visível no /proc de mentira: PID e RUN
  newhome; : > "$H/items.tsv"; printf '#!/bin/sh\ntrap '"'"'echo 1 > "$BALLAST_RUN_DIR/termed"; exit 0'"'"' TERM\nsleep 300 &\necho 1 > "$BALLAST_RUN_DIR/ready"\nwait\n' > "$H/items/trapper.sh"; chmod +x "$H/items/trapper.sh"; reg 'tp|work|4|1024|3600|300|-|trapper.sh'
  seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" tp "$RUN"; waitlines "$H/runs/$RUN/ready" 1; kill -STOP -- "-$PID"
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
rcnow() {  # rcnow CONTEÚDO [ÉPOCA=$NOW] — grava o rc da rodada $RUN com o carimbo no relógio de mentira (o governo mede a idade do rc contra BALLAST_NOW; o relógio do arquivo é o de verdade)
  printf '%s\n' "$1" > "$H/runs/$RUN/rc"; "$PY" -I -c 'import os, sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$H/runs/$RUN/rc" "${2:-$NOW}"
}
orfao() {  # orfao CONTEÚDO_DO_RC [ÉPOCA] — o item 'sm' acabou: rc gravado, o líder sumiu do /proc de mentira e um órfão (7000002) segue na sessão; o grupo REAL do item ainda vive, para o TERM ser visível
  smitem; rcnow "$1" "${2:-$NOW}"; gone "$PID"; member 7000002 "$PID" 2048
}

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
  # O governo confere `requires` ANTES de resolver o comando (eligibility): com os requires do registro do repo sem valer, o motivo é sempre "requires: … não vale" e a pasta de itens nunca é olhada — o gate
  # (21/10) reproduziu o MESMO "0 0" com os scripts presentes, ausentes e sem permissão, então o check antigo ("o motivo NÃO é 'comando'") passava sem testar nada. Aqui o ambiente SATISFAZ os dois requires
  # (HOME de mentira com o hetzner-remote-git.sh executável + a chave burn.on) e o que se afirma é a ELEGIBILIDADE: o governo real chegou ao comando de cada item e o achou, existente e executável.
  # O controle negativo está na mesma bateria: uma cópia da pasta com o hq-selftests.sh renomeado e o queima.sh sem permissão TEM que dar inerte, com motivo "comando", nos dois.
  mkdir -p "$H/home/gt-remote/bin"; printf '#!/bin/sh\n' > "$H/home/gt-remote/bin/hetzner-remote-git.sh"; chmod +x "$H/home/gt-remote/bin/hetzner-remote-git.sh"; : > "$H/burn.on"
  EXTRA_ENV="HOME=$H/home BALLAST_ITEMS=$HERE/hetzner-ballast.items.txt BALLAST_ITEMS_DIR=$HERE/hetzner-ballast-items"; bt status --json
  check "reg: com os requires do registro do repo satisfeitos, hq-selftests e queima ficam ELEGÍVEIS (o governo achou o comando de cada um: existe e é executável)" "true true" "$(jget items.0.eligible) $(jget items.1.eligible)"
  cp -R "$HERE/hetzner-ballast-items" "$H/items-sem"; mv "$H/items-sem/hq-selftests.sh" "$H/items-sem/hq-selftests.renomeado"; chmod -x "$H/items-sem/queima.sh"
  EXTRA_ENV="HOME=$H/home BALLAST_ITEMS=$HERE/hetzner-ballast.items.txt BALLAST_ITEMS_DIR=$H/items-sem"; bt status --json
  check "reg: controle negativo — pasta com o hq-selftests.sh renomeado e o queima.sh sem permissão → os DOIS inertes, motivo 'comando' em cada um (o check acima não é vácuo)" "false false 1 1" "$(jget items.0.eligible) $(jget items.1.eligible) $(jget items.0.why | grep -c comando) $(jget items.1.why | grep -c comando)"
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
  check "run: item rodando com a meta.json sumida/ilegível → a nota meta-ilegivel:<rodada> avisa que ele ficou sem prazo e sem teto de RSS" "1" "$(jget note | grep -c "meta-ilegivel:$RUN")"
  for bad in 0 1; do
    newhome; seed; mkdir -p "$H/runs/hq-1799999000"; printf '{"item":"hq","pid":%s,"start":1799999000,"timeout_s":3600,"cooldown_s":300,"cores":4,"rss_mb":1024,"role":"work"}' "$bad" > "$H/runs/hq-1799999000/meta.json"; member 7000200 "$bad"; adv 50 0; bt
    check "run: meta.json com pid $bad NÃO acha a rodada (sid $bad casaria com thread de kernel / o init, e killpg($bad) acertaria o grupo do próprio tick)" "[]" "$(jget running)"
  done
  newhome; seed; good 50; good 50; mkdir -p "$FP/4242"; printf 'lixo' > "$FP/4242/stat"; adv 50 0; bt; check "run: a tabela lista um processo e NENHUM é legível → leitura-ilegivel, nada começa e running null (não é 'ninguém roda')" "leitura-ilegivel [] null" "$(jget note) $(jget started) $(jget running)"
  newhome; seed; mv "$FP" "$FP.off"; NOW=$((NOW + 60)); bt; mv "$FP.off" "$FP"
  check "run: sem conseguir ler nada do /proc → leitura-ilegivel, rc 0, nada começa" "0 leitura-ilegivel []" "$RC $(jget note) $(jget started)"
  newhome; seed; good 50; good 50; chmod 311 "$FP"; adv 50 0; bt; chmod 755 "$FP"
  check "run: /proc/stat e meminfo legíveis mas a LISTA de processos não → leitura-ilegivel e nada começa (não é 'ninguém roda'); running null, não []" "leitura-ilegivel [] null" "$(jget note) $(jget started) $(jget running)"
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

  smitem; rm -f "$H/runs/$RUN/meta.json"; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; adv 50 0; bt
  check "reap: meta.json sumida (não sei o cooldown do item) → o item sai pelo nome da pasta e espera o cooldown de FALHA (600 s), não 0" "sm 600" "$(rj item) $("$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["cooldown"]["sm"] - d["last"]["t"])' "$H/state.json")"

  newhome; seed; mkdir -p "$H/runs/a-12-1799999000"; echo 0 > "$H/runs/a-12-1799999000/rc"; adv 50 0; bt
  check "reap: sem meta.json o nome do item sai da pasta tirando SÓ -<época>[-<n>] (item com número no nome: a-12, não a)" "a-12" "$(rj item)"

  smitem; gone "$PID"; adv 50 0; bt
  check "reap: sumiu sem rc → why morreu-sem-rc e rc null (não é ok, não é falha de teste)" "null morreu-sem-rc" "$(jget reaped.0.rc) $(jget reaped.0.why)"

  smitem; gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; printf 'x\nBALLAST-SUMMARY: {truncated\n' > "$H/runs/$RUN/log"; adv 50 0; bt
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

  # ÓRFÃOS (ga-r4lw72): o item JÁ gravou o rc e a sessão ainda tem gente. Medido no nó em 24/10: toda rodada completa do hq-selftests ficava 16 a 45 min "rodando" depois do item acabar (visto ao vivo:
  # processos do mbp-proof.selftest.sh na sessão; NÃO provado que sejam eles a segurar a cauda), com os núcleos do `auto` contando no orçamento (leitura do running_cores) e o wa-suite sem poder começar. A cauda é sobra: depois da graça o governo manda TERM e fecha a rodada pelo rc do ITEM.
  orfao 0
  adv 50 0 100; bt
  check "reap: item que JÁ gravou o rc e deixou órfão: dentro da graça (100 s de 180) nada é morto e a rodada segue rodando" "0 sm" "$(nkilled) $(jget running.0)"
  adv 50 0 100; bt
  check "reap: passada a graça (200 s depois do rc) o órfão leva TERM (motivo orfaos) e a rodada sai do orçamento no mesmo tick" "1 orfaos []" "$(nkilled) $(jget killed.0.why) $(jget running)"
  isdead "$PID"; check "reap: o grupo do item morreu com o TERM" "0" "$?"
  gone 7000002; adv 50 0; bt
  check "reap: quando o órfão sai a rodada fecha pelo rc do ITEM (ok), não por orfaos, e a linha diz que houve órfãos" "ok true" "$(rj why) $(rj orfaos)"
  check "reap: rodada boa que teve órfão ganha o cooldown do item (300 s), não o de falha (600 s)" "300" "$("$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["cooldown"]["sm"] - d["last"]["t"])' "$H/state.json")"
  orfao 3; adv 50 0 200; bt; gone 7000002; adv 50 0; bt
  check "reap: item que FALHOU (rc 3) e deixou órfão fecha como rc-3: limpar o órfão não apaga a falha, e a falha espera 600 s" "rc-3 true 600" "$(rj why) $(rj orfaos) $("$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["cooldown"]["sm"] - d["last"]["t"])' "$H/state.json")"
  smitem; gone "$PID"; member 7000002 "$PID" 2048; adv 50 0 1000; bt
  check "reap: SEM rc o item pode estar vivo: o órfão NÃO é tocado, por mais velha que seja a rodada" "0 sm" "$(nkilled) $(jget running.0)"
  orfao x; adv 50 0 500; bt
  check "reap: rc que não é um inteiro (ilegível) NÃO conta como item terminado: nada é morto" "0 sm" "$(nkilled) $(jget running.0)"
  orfao 0 1700000000; adv 50 0 500; bt
  check "reap: rc com carimbo ANTERIOR ao início da rodada (outro relógio) não dá idade: nada é morto" "0 sm" "$(nkilled) $(jget running.0)"
  orfao 0; EXTRA_ENV="BALLAST_ORPHAN_GRACE_S=30"; adv 50 0 40; bt
  check "reap: BALLAST_ORPHAN_GRACE_S muda a graça (30 s: o TERM vem 40 s depois do rc)" "1 orfaos" "$(nkilled) $(jget killed.0.why)"

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
  newhome; : > "$H/items.tsv"; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; : > "$H/burn.on"; setmem 14400; seed; good 25; good 25; good 25
  check "fill: RAM de partida vale para o filler também: 14400 MB - 256 (rss dele) < 14336 → não começa, ram baixa" "[] baixa" "$(jget started) $(jget ram)"
  newhome; reg 'queima|filler|auto|256|600|0|flag:burn.on|sleeper.sh'; : > "$H/burn.on"; setmem 15615; seed; good 25; good 25; good 25
  check "fill: o work que vai começar já desconta a RAM do filler (15615 - 1024 - 256 = 14335 < 14336): só o hq, filler fica de fora, ram baixa" "hq 1 baixa" "$(jget started.0.item) $(nstart) $(jget ram)"
  newhome; : > "$H/items.tsv"; reg 'q1|filler|2|256|600|0|-|sleeper.sh'; reg 'q2|filler|2|256|600|0|-|sleeper.sh'; setmem 14592; seed; good 25; good 25; good 25
  check "fill: a RAM é lida uma vez: o filler que começou desconta a sobra do seguinte (14592 cabem UM de 256): q1 começa, q2 não, ram baixa" "q1 1 baixa" "$(jget started.0.item) $(nstart) $(jget ram)"
}

# ── g_off ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
g_off() {
  newhome; rm -f "$H/on"; alive 7000100 estranho estranho-1700000000; seed; adv 50 0; bt
  check "off: processo com a marca ballast-item de OUTRA pasta de lastro (ex.: o selftest do próprio governo rodando como item) NÃO é nosso: não aparece em running e não é morto" "[] 0" "$(jget running) $(nkilled)"
  running_one; rm -f "$H/on"; adv 50 0; bt
  check "off: apagar a chave on mata o que roda (TERM), motivo desligado, mode desligado" "desligado 1 desligado" "$(jget mode) $(nkilled) $(jget killed.0.why)"
  isdead "$PID"; check "off: o item parou de verdade" "0" "$?"

  running_one; mv "$FP" "$FP.off"; rm -f "$H/on"; NOW=$((NOW + 60)); bt; mv "$FP.off" "$FP"
  check "off: desligado mas sem conseguir ler os processos → NÃO mata (leitura-ilegivel)" "leitura-ilegivel" "$(jget note)"
  kill -9 -- "-$PID" 2>/dev/null

  running_one; bt stop
  check "stop: mata o que roda mesmo com a chave ligada, devolve o que parou, rc 0" "0 hq" "$RC $(jget stopped.0.item)"
  isdead "$PID"; check "stop: o item morreu" "0" "$?"

  # o `timeout` do GNU faz setpgid(0,0): o item vive em OUTRO grupo da MESMA sessão. O stop olha a SESSÃO, não o grupo do líder: antes o líder morria no TERM, a sonda de grupo dizia "sumiu",
  # o KILL nunca vinha e o stop dizia rc 0 com o item vivo (só o `timeout -k 30` o matava, 30 s depois). Aqui o item ignora o TERM e o shim de `timeout` troca de grupo, como o do GNU.
  newhome; : > "$H/items.tsv"; printf '#!/bin/sh\ntrap "" TERM\nsleep 300 &\necho "$$ $!" > "$BALLAST_RUN_DIR/pids"\nwait\n' > "$H/items/stubborn.sh"; chmod +x "$H/items/stubborn.sh"; reg 'tc|work|4|1024|3600|300|-|stubborn.sh'
  mkdir -p "$W/bin2"; printf '#!%s\nimport os, sys\nos.setpgid(0, 0)\na = sys.argv[4:]\nos.execvp(a[0], a)\n' "$PY" > "$W/bin2/timeout"; chmod +x "$W/bin2/timeout"
  EXTRA_ENV="PATH=$W/bin2:$W/bin:/usr/bin:/bin"; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); waitlines "$H/runs/$RUN/pids" 1
  read -r SP SL < "$H/runs/$RUN/pids"; alive "$PID" tc "$RUN"; member "$SP" "$PID"; member "$SL" "$PID"; bt stop
  check "stop: item noutro grupo da sessão (timeout do GNU) que ignora o TERM → rc 0, o item aparece em stopped, sem survivors" "0 tc null" "$RC $(jget stopped.0.item) $(jget survivors)"
  pdead "$PID" "$SP" "$SL"; check "stop: ...e os processos do item morreram DE VERDADE (o KILL veio pela sessão, não 30 s depois pelo timeout -k)" "0" "$?"
  kill -9 "$SP" "$SL" 2>/dev/null

  # sobrevivente que o KILL não tira (um zumbi, que o /proc de mentira lista como vivo): o stop NÃO diz que parou
  running_one; "$PY" -I -c 'import os, time
p = os.fork()
if p == 0:
    os._exit(0)
print(p, flush=True)
time.sleep(60)' > "$W/zpid" & ZP=$!
  waitlines "$W/zpid" 1; ZC=$(head -n 1 "$W/zpid"); member "$ZC" "$PID"; bt stop
  check "stop: sobrou processo vivo na sessão depois do KILL → rc 5, nada em stopped, survivors nomeia o processo" "5 [] $ZC" "$RC $(jget stopped) $(jget survivors.$RUN.0)"
  kill -9 "$ZP" 2>/dev/null; wait "$ZP" 2>/dev/null

  # tabela de processos ilegível DEPOIS do TERM (o item, ao tratar o TERM, tira a permissão da pasta): não sei se parou → rc 5, unverified, nada em stopped
  newhome; : > "$H/items.tsv"; cat > "$H/items/hider.sh" <<EOF
#!/bin/sh
trap 'chmod 000 "$FP"' TERM
sleep 300 &
echo "\$\$ \$!" > "\$BALLAST_RUN_DIR/pids"
wait
EOF
  chmod +x "$H/items/hider.sh"; reg 'hd|work|4|1024|3600|300|-|hider.sh'; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); waitlines "$H/runs/$RUN/pids" 1
  read -r SP SL < "$H/runs/$RUN/pids"; alive "$PID" hd "$RUN"; member "$SP" "$PID"; bt stop; chmod 755 "$FP"
  check "stop: tabela de processos ilegível depois do TERM → rc 5, unverified true, nada em stopped (não sei se parou)" "5 true []" "$RC $(jget unverified) $(jget stopped)"
  kill -9 -- "-$PID" 2>/dev/null; kill -9 "$SP" "$SL" 2>/dev/null

  # item PARADO (a pausa de RAM manda SIGSTOP): ele só trata o TERM depois do CONT; sem o CONT o TERM fica pendente até o KILL
  trapper_up; bt stop; waitlines "$H/runs/$RUN/termed" 1
  check "stop: item parado trata o TERM (o stop manda CONT junto)" "0 1" "$RC $(lines "$H/runs/$RUN/termed")"
  kill -9 -- "-$PID" 2>/dev/null
  trapper_up; rm -f "$H/on"; adv 50 0; bt; waitlines "$H/runs/$RUN/termed" 1
  check "off: item parado trata o TERM da chave apagada (o tick manda CONT junto)" "1 1" "$(nkilled) $(lines "$H/runs/$RUN/termed")"
  kill -9 -- "-$PID" 2>/dev/null

  # a tabela de processos é lida mesmo com o meminfo ilegível: a chave apagada continua matando (só RAM e começo dependem do meminfo)
  running_one; rm -f "$H/on"; printf 'MemTotal: 1 kB\n' > "$FP/meminfo"; adv 50 0; bt
  check "off: meminfo ilegível NÃO impede a chave apagada de matar (nota leitura-ilegivel, nada começa)" "leitura-ilegivel 1 desligado []" "$(jget note) $(nkilled) $(jget killed.0.why) $(jget started)"
  kill -9 -- "-$PID" 2>/dev/null

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
  newhome; CEIL=systemd; EXTRA_ENV="BALLAST_TEST=0"; LP='[]'; bt status --json; r1=$RC; LP='["chrt","-i","0"]'; bt status --json; r2=$RC; LP='["nice","-n","19"]'; bt status --json
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

# ── g_send ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# send() com um membro da sessão que o runner NÃO pode sinalizar (ga-2hd02v.8). O item wa-suite roda sob `sudo -n gt-netns-run` e o bash do helper é root; medido no nó em 24/10, ele é o ÚNICO membro
# root da sessão (a carga roda com o uid do runner: setpriv --reuid). O sinal tem que chegar a todos os outros, sem levantar e sem parar no que recusou. kill/killpg são de mentira: root de verdade não cabe aqui.
g_send() {
  local o
  o=$("$PY" -I - "$P" <<'PYEOF'
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("hb", sys.argv[1]); hb = importlib.util.module_from_spec(spec); spec.loader.exec_module(hb)
LEADER, ROOT, A, GONE, B = 100, 101, 102, 103, 104   # B vem DEPOIS do que recusa: parar no primeiro EPERM o deixaria sem o sinal
def run(pg_exc, members, refuse=(), gone=()):
    att = []
    def killpg(pg, sig):
        if pg_exc is not None:
            raise pg_exc
    def kill(pid, sig):
        att.append(pid)
        if pid in refuse:
            raise PermissionError(1, "Operation not permitted")
        if pid in gone:
            raise ProcessLookupError(3, "No such process")
    os.killpg, os.kill = killpg, kill
    try:
        res = hb.send({"pid": LEADER, "members": members}, signal.SIGSTOP)
    except BaseException as e:
        return "levantou:%s" % type(e).__name__
    return "%s tentou=%s" % (res, ",".join(map(str, att)))
print("1", run(None, [A, ROOT, GONE, B], refuse={ROOT}, gone={GONE}))
print("2", run(ProcessLookupError(3, "x"), [A, B]))
print("3", run(ProcessLookupError(3, "x"), [ROOT], refuse={ROOT}))
print("4", run(PermissionError(1, "x"), [ROOT], refuse={ROOT}))
print("5", run(ProcessLookupError(3, "x"), [GONE], gone={GONE}))
PYEOF
)
  check "send: grupo aceita, um membro root recusa (EPERM) e um sumiu → o sinal é tentado em TODOS, também no que vem DEPOIS do que recusou, sem levantar; hit True" "True tentou=102,101,103,104" "$(printf '%s\n' "$o" | sed -n 's/^1 //p')"
  check "send: o grupo do líder já não existe (o timeout do GNU muda de grupo) → os membros ainda recebem o sinal" "True tentou=102,104" "$(printf '%s\n' "$o" | sed -n 's/^2 //p')"
  check "send: ninguém aceitou o sinal (grupo vazio e o único membro recusa) → False, nunca True por ter tentado" "False tentou=101" "$(printf '%s\n' "$o" | sed -n 's/^3 //p')"
  check "send: o grupo inteiro recusa (EPERM no killpg) → False e não levanta" "False" "$(printf '%s\n' "$o" | sed -n 's/^4 //p' | awk '{print $1}')"
  check "send: nada existe mais (grupo e membros sumidos) → False e não levanta" "False tentou=103" "$(printf '%s\n' "$o" | sed -n 's/^5 //p')"
}

# ── g_ceil ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Teto de sistema por item (ga-kgnjkt8). O nice 19/SCHED_IDLE protege a CPU, não a tabela de processos nem a RAM (29/10 16:30Z uma fork bomb de uma sessão sem teto parou o nó). Cada item entra num escopo
# systemd do usuário (ballast.slice/ballast-<rodada>.scope) com TasksMax e MemoryMax, e o governo lê os contadores do kernel a cada tick. Aqui o systemd-run é de brinquedo (anota o que recebeu e roda
# o resto) e o cgroup é uma pasta de fixtures (BALLAST_CGROUP_ROOT); o que o kernel faz de verdade está no g_cgrp.
waitfile() {  # waitfile ARQUIVO — espera (até 10 s) o arquivo existir
  local i=0; while [ "$i" -lt 50 ] && [ ! -e "$1" ]; do sleep 0.2; i=$((i+1)); done; [ -e "$1" ]
}
fakesd() {  # fakesd — CEIL=systemd com um barramento de mentira ($T/rt/bus) e um systemd-run de brinquedo que anota o que recebeu (argumentos e ambiente) em $SD/call.N e roda o que vem depois do `--`
  CEIL=systemd; rm -rf "$T/rt" "$T/cg"; mkdir -p "$T/rt" "$T/cg"; : > "$T/rt/bus"
  EXTRA_ENV="BALLAST_RUNTIME_DIR=$T/rt BALLAST_CGROUP_ROOT=$T/cg"
  SD="$W/sd$N"; rm -rf "$SD"; mkdir -p "$SD"
  cat > "$W/bin/systemd-run" <<EOS
#!/bin/sh
D=$SD
n=\$(ls "\$D" | grep -c '^call\.'); n=\$((n + 1))
{ printf 'ARGV:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; echo "XDG=\${XDG_RUNTIME_DIR:-unset}"; echo "DBUS=\${DBUS_SESSION_BUS_ADDRESS:-unset}"; } > "\$D/call.\$n"
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
EOS
  chmod +x "$W/bin/systemd-run"
}
callhas() { local c; c=$(grep -c -F -- "[$1]" "$SD/call.1" 2>/dev/null); echo "${c:-0}"; }   # quantas vezes o argumento $1 aparece na 1ª chamada do systemd-run de brinquedo
ceil_one() {  # ceil_one — newhome + o item hq (4 núcleos) rodando sob o systemd-run de brinquedo, visível no /proc de mentira, com o cgroup de mentira montado (CGD): PID, RUN e CGD
  newhome; fakesd; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" hq "$RUN"
  waitfile "$H/runs/$RUN/cgroup"; sleep 0.5   # o item escreve o cgroup dele no começo; o meu (de mentira) vai por cima depois
  CGD="$T/cg/user.slice/user-1000.slice/user@1000.service/ballast.slice/ballast-$RUN.scope"
  printf '/user.slice/user-1000.slice/user@1000.service/ballast.slice/ballast-%s.scope\n' "$RUN" > "$H/runs/$RUN/cgroup"
  mkdir -p "$CGD"; printf 'max 0\n' > "$CGD/pids.events"; printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n' > "$CGD/memory.events"; : > "$CGD/cgroup.kill"; : > "$CGD/cgroup.procs"
}
g_ceil() {
  local D3 i
  # lançamento: o item começa dentro de um escopo com teto, e o item não herda o barramento do usuário
  newhome; fakesd; : > "$H/items.tsv"; printf '#!/bin/sh\nenv > "$BALLAST_RUN_DIR/env.txt"\nsleep 300\n' > "$H/items/envdump.sh"; chmod +x "$H/items/envdump.sh"; reg 'ev|work|4|1024|3600|300|-|envdump.sh'
  seed; good 50; good 50; good 50; RUN=$(started_run); waitfile "$SD/call.1"; waitfile "$H/runs/$RUN/env.txt"
  check "teto: o item começa por systemd-run --user --scope --collect, na unidade ballast-<rodada> da ballast.slice" "1 1 1 1 1" "$(callhas --user) $(callhas --scope) $(callhas --collect) $(callhas "--unit=ballast-$RUN") $(callhas --slice=ballast.slice)"
  check "teto: TasksMax=4096, MemoryMax=1280M (rss_mb 1024 x 1,25), sem swap, e o kernel mata só o que estourou (OOMPolicy=continue: o item ainda grava o rc e os picos)" "1 1 1 1" "$(callhas TasksMax=4096) $(callhas MemoryMax=1280M) $(callhas MemorySwapMax=0) $(callhas OOMPolicy=continue)"
  check "teto: o systemd-run recebe o barramento do usuário (XDG_RUNTIME_DIR e DBUS_SESSION_BUS_ADDRESS)" "XDG=$T/rt DBUS=unix:path=$T/rt/bus" "$(grep '^XDG=' "$SD/call.1" 2>/dev/null) $(grep '^DBUS=' "$SD/call.1" 2>/dev/null)"
  check "teto: ...mas o item NÃO herda o barramento (não pede ao gerenciador um escopo fora do teto)" "0" "$(grep -c -E '^(XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)=' "$H/runs/$RUN/env.txt" 2>/dev/null)"
  check "teto: a meta.json da rodada guarda o teto que valeu (tasks 4096, mem_mb 1280)" "4096 1280" "$("$PY" -I -c 'import json,sys; c=json.load(open(sys.argv[1])).get("ceiling") or {}; print(c.get("tasks"), c.get("mem_mb"))' "$H/runs/$RUN/meta.json" 2>/dev/null)"
  newhome; fakesd; EXTRA_ENV="$EXTRA_ENV BALLAST_TASKS_MAX=77 BALLAST_MEM_FACTOR=2"; seed; good 50; good 50; good 50; waitfile "$SD/call.1"
  check "teto: BALLAST_TASKS_MAX e BALLAST_MEM_FACTOR mudam o teto (TasksMax=77, MemoryMax=2048M)" "1 1" "$(callhas TasksMax=77) $(callhas MemoryMax=2048M)"
  newhome; fakesd; EXTRA_ENV="$EXTRA_ENV BALLAST_TASKS_MAX=3"; bt status --json; r1=$RC; EXTRA_ENV="$EXTRA_ENV BALLAST_TASKS_MAX=4096 BALLAST_MEM_FACTOR=0.5"; bt status --json
  check "teto: BALLAST_TASKS_MAX abaixo de 16 ou BALLAST_MEM_FACTOR abaixo de 1 → configuração inválida (rc 3), nunca um teto que mata o item de cara" "3 3" "$r1 $RC"
  newhome; CEIL=off; EXTRA_ENV="BALLAST_TEST=0"; bt status --json
  check "teto: fora do selftest BALLAST_CEILING=off é recusado (rc 3): o lastro nunca roda sem teto por engano" "3" "$RC"

  # pronto ou não: sem gerenciador de usuário o item NÃO começa (o teto é condição, não enfeite)
  newhome; fakesd; rm -f "$T/rt/bus"; seed; good 50; good 50; good 50
  check "teto: sem o barramento do usuário (sem sessão aberta nem linger) o item NÃO começa" "[]" "$(jget started)"
  check "teto: ...a nota do tick diz sem-teto e o stderr diz o motivo" "1 1" "$(jget note | grep -c 'sem-teto') $(grep -c 'sem teto' "$W/err")"
  check "teto: ...e não fica pasta de rodada pela metade" "0" "$(ls "$H/runs" 2>/dev/null | wc -l | tr -d ' ')"
  bt status --json
  check "teto: o status diz que o teto NÃO está pronto, com o motivo (o barramento)" "false 1" "$(jget ceiling.ready) $(jget ceiling.why | grep -c 'bus')"
  newhome; fakesd; rm -f "$W/bin/systemd-run"; D3="$W/sdnp"; rm -rf "$D3"; mkdir -p "$D3"; ln -sf /bin/sh "$D3/sh"; ln -sf "$(command -v sleep)" "$D3/sleep"; EXTRA_ENV="$EXTRA_ENV PATH=$W/bin:$D3"; seed; good 50; good 50; good 50
  check "teto: sem systemd-run no PATH o item NÃO começa" "[]" "$(jget started)"
  bt status --json; check "teto: ...e o status diz que o teto NÃO está pronto" "false" "$(jget ceiling.ready)"
  newhome; fakesd; bt status --json
  check "teto: pronto, o status mostra o modo e os limites (systemd, 4096 tarefas, fator 1.25)" "systemd true 4096 1.25" "$(jget ceiling.mode) $(jget ceiling.ready) $(jget ceiling.tasks_max) $(jget ceiling.mem_factor)"

  # o tick lê os contadores do kernel do cgroup do item
  ceil_one; adv 50 0; bt
  check "teto: sem estouro (max 0, oom_kill 0) nada é morto e a nota não fala de teto" "0 0" "$(nkilled) $(jget note | grep -c teto)"
  printf 'max 7\n' > "$CGD/pids.events"; adv 50 0; bt
  check "teto: fork recusado no cgroup do item (pids.events max>0) → morto de imediato (KILL) com o motivo teto-processos" "1 teto-processos KILL" "$(nkilled) $(jget killed.0.why) $(jget killed.0.sig)"
  check "teto: ...e o governo escreve 1 no cgroup.kill do item (pega também quem fez setsid e some da sessão)" "1" "$(cat "$CGD/cgroup.kill")"
  isdead "$PID"; check "teto: ...e o item parou de verdade" "0" "$?"
  ceil_one; printf 'low 0\nhigh 0\nmax 0\noom 1\noom_kill 1\noom_group_kill 0\n' > "$CGD/memory.events"; adv 50 0; bt
  check "teto: o kernel matou algo no cgroup do item (memory.events oom_kill>0) → morto com o motivo teto-memoria" "1 teto-memoria" "$(nkilled) $(jget killed.0.why)"
  ceil_one; printf 'low 0\nhigh 0\nmax 42\noom 0\noom_kill 0\noom_group_kill 0\n' > "$CGD/memory.events"; adv 50 0; bt
  check "teto: memory.events max>0 sem oom_kill (o kernel só recuperou cache no limite) NÃO é estouro" "0" "$(nkilled)"
  ceil_one; rm -f "$CGD/pids.events"; adv 50 0; bt
  check "teto: pids.events ilegível → NÃO mata (o kernel segue impondo o teto) e a nota diz teto-ilegivel:<rodada>" "0 1" "$(nkilled) $(jget note | grep -c "teto-ilegivel:$RUN")"
  ceil_one; printf 'lixo\n' > "$CGD/pids.events"; adv 50 0; bt
  check "teto: pids.events que não é contador (lixo) também é ilegível, nunca 0 estouros" "0 1" "$(nkilled) $(jget note | grep -c "teto-ilegivel:$RUN")"
  ceil_one; rm -f "$CGD/pids.events"; printf 'low 0\nhigh 0\nmax 0\noom 1\noom_kill 1\noom_group_kill 0\n' > "$CGD/memory.events"; adv 50 0; bt
  check "teto: um contador ilegível não esconde o outro (pids.events some, oom_kill=1 → teto-memoria)" "1 teto-memoria" "$(nkilled) $(jget killed.0.why)"
  ceil_one; : > "$H/runs/$RUN/cgroup"; adv 50 0; bt
  check "teto: o item ainda não disse o cgroup dele (arquivo vazio) → não mata, nota teto-ilegivel:<rodada>" "0 1" "$(nkilled) $(jget note | grep -c "teto-ilegivel:$RUN")"

  # o caminho do cgroup vem de um arquivo: só vale se for exatamente o escopo DESTA rodada na ballast.slice (nunca a sessão de login de alguém)
  ceil_one; mkdir -p "$T/cg/user.slice/user-1000.slice/session-3.scope"; : > "$T/cg/user.slice/user-1000.slice/session-3.scope/cgroup.kill"; printf 'max 9\n' > "$T/cg/user.slice/user-1000.slice/session-3.scope/pids.events"
  printf '/user.slice/user-1000.slice/session-3.scope\n' > "$H/runs/$RUN/cgroup"; adv 50 0; bt
  check "teto: caminho fora da ballast.slice (a sessão de login) NUNCA é lido nem recebe kill" "0 0 1" "$(nkilled) $(wc -c < "$T/cg/user.slice/user-1000.slice/session-3.scope/cgroup.kill" | tr -d ' ') $(jget note | grep -c "teto-caminho:$RUN")"
  ceil_one; printf '/user.slice/user-1000.slice/user@1000.service/ballast.slice/ballast-outra-1700000000.scope\n' > "$H/runs/$RUN/cgroup"; adv 50 0; bt
  check "teto: escopo de OUTRA rodada da ballast.slice também é recusado (o nome tem que ser o desta rodada)" "0 1" "$(nkilled) $(jget note | grep -c "teto-caminho:$RUN")"
  ceil_one; printf '/user.slice/user-1000.slice/user@1000.service/../../../x/ballast.slice/ballast-%s.scope\n' "$RUN" > "$H/runs/$RUN/cgroup"; adv 50 0; bt
  check "teto: caminho com .. é recusado" "0 1" "$(nkilled) $(jget note | grep -c "teto-caminho:$RUN")"

  # fim de rodada: o que sobrou no cgroup (quem fez setsid) leva kill, e os picos do item entram no resultado
  ceil_one; echo 0 > "$H/runs/$RUN/rc"; gone "$PID"; adv 50 0; bt
  check "teto: a rodada acabou (rc gravado, ninguém na sessão) → o governo manda kill ao que SOBROU no cgroup" "1" "$(cat "$CGD/cgroup.kill")"
  ceil_one; echo 0 > "$H/runs/$RUN/rc"; printf 'pids_peak 37\nmem_peak 123731968\npids_hits 0\noom_kill 0\n' > "$H/runs/$RUN/ceiling"; gone "$PID"; adv 50 0; bt
  check "teto: o relatório do item (picos lidos de dentro do escopo) entra na linha do results.jsonl" "ok 37 118 0 0" "$(rj why) $(rj ceiling.tasks_peak) $(rj ceiling.mem_peak_mb) $(rj ceiling.tasks_hit) $(rj ceiling.oom_kill)"
  ceil_one; echo 0 > "$H/runs/$RUN/rc"; gone "$PID"; adv 50 0; bt
  check "teto: sem relatório o resultado diz ceiling null (não sei os picos), nunca 0" "ok null" "$(rj why) $(rj ceiling)"
  ceil_one; echo 0 > "$H/runs/$RUN/rc"; printf 'pids_peak lixo\nmem_peak 5\n' > "$H/runs/$RUN/ceiling"; gone "$PID"; adv 50 0; bt
  check "teto: relatório com campo ilegível → o campo é null e o que dá para ler fica (mem_peak 5 bytes = 0 MB)" "null 0" "$(rj ceiling.tasks_peak) $(rj ceiling.mem_peak_mb)"
  ceil_one; echo 0 > "$H/runs/$RUN/rc"; printf 'pids_peak 4096\nmem_peak 1\npids_hits 12\noom_kill 0\n' > "$H/runs/$RUN/ceiling"; gone "$PID"; adv 50 0; bt
  check "teto: o item saiu rc 0 mas o relatório diz fork recusado → a rodada fecha como teto-processos (cooldown de falha), não ok" "teto-processos" "$(rj why)"
  ceil_one; echo 137 > "$H/runs/$RUN/rc"; printf 'pids_peak 30\nmem_peak 83886080\npids_hits 0\noom_kill 1\n' > "$H/runs/$RUN/ceiling"; gone "$PID"; adv 50 0; bt
  check "teto: o kernel matou o maior do item (oom_kill 1; o rc é 137) → a rodada fecha como teto-memoria, com o pico de memória" "teto-memoria 80" "$(rj why) $(rj ceiling.mem_peak_mb)"
  rm -f "$W/bin/systemd-run"
}

# ── g_cgrp ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# O kernel de verdade (ga-kgnjkt8): só onde há um gerenciador de usuário do systemd (Linux, sessão aberta ou linger); nos outros ambientes a bateria diz `skip` e isso NÃO conta como passou. Todo
# "descontrolado" daqui é LIMITADO POR CONSTRUÇÃO (300 filhos, 400 MB): sem o teto o teste reprova, não derruba a máquina. A leitura de /proc/stat e meminfo continua de mentira; processo e cgroup são reais.
cgrp_ok() {
  [ "$(uname -s)" = Linux ] && command -v systemd-run > /dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] && systemd-run --user --scope --quiet --collect -p TasksMax=16 true > /dev/null 2>&1
}
cgrp_item() {  # cgrp_item NOME 'corpo python' RSS_MB — newhome com UM item real (script python em $H/items/NOME.py) sob o systemd-run REAL; o item começa no 3º tick livre. PID e RUN
  newhome; CEIL=systemd; : > "$H/items.tsv"
  printf '#!%s\nimport os, time\nRD = os.environ["BALLAST_RUN_DIR"]\n%s\n' "$PY" "$2" > "$H/items/$1.py"; chmod +x "$H/items/$1.py"; reg "$1|work|4|$3|3600|300|-|$1.py"
}
cgrp_start() { seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" "$1" "$RUN"; }
g_cgrp() {
  local sp mb canary cg i EP
  if ! cgrp_ok; then echo "skip cgrp: sem systemd-run --user utilizável aqui (precisa de Linux com gerenciador de usuário): os casos do kernel de verdade NÃO rodaram"; return 0; fi
  # (1) fork em laço, limitado a 300 filhos: com TasksMax=40 o item consegue no máximo 40; sem teto consegue os 300
  cgrp_item fk 'n = 0
for _ in range(300):
    try:
        pid = os.fork()
    except OSError:
        continue
    if pid == 0:
        time.sleep(60)
        os._exit(0)
    n += 1
open(RD + "/spawned", "w").write(str(n))
time.sleep(60)' 1024
  EXTRA_ENV="BALLAST_TASKS_MAX=40"; cgrp_start fk; waitfile "$H/runs/$RUN/spawned"; sp=$(cat "$H/runs/$RUN/spawned" 2>/dev/null || echo 0)
  check "cgrp: o item que tenta criar 300 filhos com TasksMax=40 consegue entre 10 e 40 (sem teto seriam 300; criou $sp)" "1" "$([ "$sp" -ge 10 ] && [ "$sp" -le 40 ] && echo 1 || echo 0)"
  canary=0; sh -c 'exit 0' && canary=1
  check "cgrp: ...e quem está fora do escopo (o sshd do nó) continua criando processos com o item no teto" "1" "$canary"
  adv 50 0; bt
  check "cgrp: o tick seguinte vê o fork recusado no cgroup de verdade e mata o item com o motivo teto-processos" "teto-processos" "$(jget killed.0.why)"
  cg="/sys/fs/cgroup$(cat "$H/runs/$RUN/cgroup" 2>/dev/null)"; i=0; while [ "$i" -lt 25 ] && [ -d "$cg" ]; do sleep 0.2; i=$((i+1)); done
  check "cgrp: ...e o cgroup do item sumiu (nenhum filho sobrou)" "gone" "$([ -d "$cg" ] && echo vivo || echo gone)"
  gone "$PID"; adv 50 0; bt
  check "cgrp: a rodada fecha como teto-processos" "teto-processos" "$(rj why)"
  # (1b) o item que TERMINA sozinho grava o relatório de dentro do escopo (picos e fork recusado lidos do kernel): é o que o governo guarda no results.jsonl
  cgrp_item fk2 'n = 0
for _ in range(300):
    try:
        pid = os.fork()
    except OSError:
        continue
    if pid == 0:
        time.sleep(30)
        os._exit(0)
    n += 1
open(RD + "/spawned", "w").write(str(n))' 1024
  EXTRA_ENV="BALLAST_TASKS_MAX=40"; cgrp_start fk2; i=0; while [ "$i" -lt 50 ] && [ ! -s "$H/runs/$RUN/ceiling" ]; do sleep 0.2; i=$((i+1)); done
  check "cgrp: o item que termina sozinho grava o relatório: pids_peak entre 10 e 40 e pids_hits > 0 (fork recusado), lidos do kernel" "1 1" "$(awk '$1=="pids_peak"{p=$2} $1=="pids_hits"{h=$2} END{print (p>=10 && p<=40 ? 1 : 0), (h>0 ? 1 : 0)}' "$H/runs/$RUN/ceiling" 2>/dev/null)"
  check "cgrp: ...e o caminho do cgroup do item está no padrão ballast.slice/ballast-<rodada>.scope" "1" "$(grep -c "^/user.slice/.*/ballast.slice/ballast-$RUN.scope\$" "$H/runs/$RUN/cgroup" 2>/dev/null)"
  # (2) memória: alocador limitado a 400 MB (10 x 40); rss_mb 64 → MemoryMax=80M: o kernel o mata no 2º bloco
  cgrp_item hog 'chunks = []
for i in range(10):
    chunks.append(bytearray(b"x") * (40 << 20))
    open(RD + "/mb", "w").write(str((i + 1) * 40))
    time.sleep(0.1)
time.sleep(60)' 64
  cgrp_start hog; i=0; while [ "$i" -lt 60 ] && [ ! -e "$H/runs/$RUN/rc" ] && [ "$(cat "$H/runs/$RUN/mb" 2>/dev/null || echo 0)" -lt 400 ]; do sleep 0.25; i=$((i+1)); done
  mb=$(cat "$H/runs/$RUN/mb" 2>/dev/null || echo 0)
  check "cgrp: o alocador de 400 MB com MemoryMax=80M é morto pelo kernel antes de passar de 80 MB (marca: $mb MB)" "1" "$([ "$mb" -le 80 ] && echo 1 || echo 0)"
  i=0; while [ "$i" -lt 25 ] && [ ! -s "$H/runs/$RUN/ceiling" ]; do sleep 0.2; i=$((i+1)); done; gone "$PID"; adv 50 0; bt
  check "cgrp: a rodada fecha como teto-memoria, com oom_kill 1 e o pico lidos de dentro do escopo" "teto-memoria 1" "$(rj why) $(rj ceiling.oom_kill)"
  # (3) quem faz setsid sai da sessão do item e o governo, por sessão, não o vê: o stop tem que pegá-lo pelo cgroup
  cgrp_item es 'import subprocess
subprocess.Popen(["setsid", "sh", "-c", "echo $$ > \"$1\"; exec sleep 301", "_", RD + "/esc.pid"])
time.sleep(60)' 1024
  cgrp_start es; waitfile "$H/runs/$RUN/esc.pid"; sleep 0.3; EP=$(cat "$H/runs/$RUN/esc.pid" 2>/dev/null || echo 0)
  check "cgrp: o escapee (setsid) está vivo e fora da sessão do item" "1" "$(plive "$EP" && [ "$(ps -o sid= -p "$EP" | tr -d ' ')" != "$PID" ] && echo 1 || echo 0)"
  bt stop
  pdead "$EP"; check "cgrp: o stop mata também quem fez setsid (o cgroup.kill pega; a sessão não o enxerga)" "0" "$?"
  kill -9 "$EP" 2>/dev/null
}

if [ -n "${HB_MUTANT:-}" ]; then
  if [ "${HB_MUTANT_GROUPS:-}" = teto ]; then g_ceil; g_cgrp; else g_reg; g_tick; g_run; g_ram; g_reap; g_fill; g_off; g_state; g_logs; g_launch; g_send; fi
  echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?
fi
if [ -n "${HB_ONLY:-}" ]; then "g_$HB_ONLY"; echo "── $((n - fails))/$n ok (só g_$HB_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_reg; g_tick; g_run; g_ram; g_reap; g_fill; g_off; g_state; g_logs; g_launch; g_send; g_ceil; g_cgrp

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
lock de instância única ignorado (o flock espera em vez de falhar)@@        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        rec["note"] = "outra-instancia"@@        fcntl.flock(lock, fcntl.LOCK_EX)
    except OSError:
        rec["note"] = "outra-instancia"
escrita não conferida antes de começar@@        raise Fail("%s: não consigo gravar (%s)" % (cfg.home, e))@@        pass
/proc/stat ilegível vira leitura boa@@    if len(f) < 9 or f[0] != "cpu":@@    if False:
meminfo sem MemAvailable vira 0 MB@@    raise Unreadable("/proc/meminfo: sem MemAvailable")@@    return 0
tabela de processos ilegível vira lista vazia@@        raise Unreadable("%s: %s" % (root, e))@@        return []
pausa manda CONT em vez de STOP@@send(r, signal.SIGSTOP)@@send(r, signal.SIGCONT)
retomada nunca acontece (sem a histerese)@@    elif mem < cfg.ram_pause_mb or (st["paused"] and mem < cfg.ram_resume_mb):@@    elif mem < cfg.ram_pause_mb:
pausa que não passa não mata (limite de leituras ignorado)@@if st["paused_ticks"] >= cfg.pause_kill_ticks:@@if st["paused_ticks"] >= 10**9:
mata o MENOR em vez do maior RSS@@biggest = max(run.values(), key=lambda r: r["rss_kb"]) if run else None@@biggest = min(run.values(), key=lambda r: r["rss_kb"]) if run else None
RAM crítica não mata na hora@@        if biggest:
            kill_now(cfg, st, biggest, "ram-critica", rec)@@        if False:
            kill_now(cfg, st, biggest, "ram-critica", rec)
RAM crítica manda TERM (um grupo parado não trata)@@kill_now(cfg, st, biggest, "ram-pausa", rec)@@terminate(cfg, st, biggest, "ram-pausa", rec)
teto de RSS do item ignorado@@elif _int(cap) and r["rss_kb"] > cap * 1024:@@elif False:
sem rc vira ok@@why = (None if orph else killed) or ("ok" if rc == 0 else@@why = (None if orph else killed) or ("ok" if rc in (0, None) else
resumo que não é objeto vira dado@@    return (v, "") if isinstance(v, dict) else (None, "ilegivel")@@    return (v, "")
vale a primeira linha de resumo, não a última@@        v = json.loads(lines[-1][len("BALLAST-SUMMARY: "):])@@        v = json.loads(lines[0][len("BALLAST-SUMMARY: "):])
meta.json sumida vira cooldown 0 (errar para menos recomeça em cima)@@    cool = meta.get("cooldown_s") if meta else None
    if not (_int(cool) and cool >= 0):
        cool = cfg.fail_cooldown_s@@    cool = meta.get("cooldown_s", 0) if meta else 0
falha não ganha o cooldown mínimo@@    if why not in ("ok", "desligado", "preempt", "stop"):
        cool = max(cool, cfg.fail_cooldown_s)@@    if False:
        cool = max(cool, cfg.fail_cooldown_s)
rodada encerrada duas vezes (sem a marca final)@@        with open(os.path.join(rundir, "final"), "w") as f:
            f.write("%d\n" % cfg.now)@@        with open(os.path.join(rundir, "final2"), "w") as f:
            f.write("%d\n" % cfg.now)
pid reaproveitado vale como item (a marca não é conferida)@@        if run not in cand and (ldr is None or ldr["state"] == "Z"):@@        if run not in cand:
filho vivo na sessão não segura a rodada (só o líder vale)@@        mem = [q for q in procs if q["sid"] == pid and q["state"] != "Z"]@@        mem = [q for q in procs if q["pid"] == pid and q["state"] != "Z"]
prazo ignorado@@elif _int(start) and _int(tmo) and cfg.now - start > tmo + cfg.deadline_slack_s:@@elif False:
meta.json sem start/timeout_s lido sem conferir (derruba o tick)@@            elif _int(start) and _int(tmo) and cfg.now - start@@            elif cfg.now - start
meta.json sem rss_mb lido sem conferir (derruba o tick)@@            elif _int(cap) and r["rss_kb"] > cap * 1024:@@            elif r["rss_kb"] > cap * 1024:
TERM ignorado nunca vira KILL@@if cfg.now - t >= cfg.term_grace_s:@@if False:
desligar não mata@@            elif not on:
                terminate(cfg, st, r, "desligado", rec)@@            elif False:
                terminate(cfg, st, r, "desligado", rec)
filler não é morto quando um work vai começar@@                if m.get("role") == "filler" and r["run"] not in st["term"]:@@                if False:
filler entra antes do work (conta no orçamento do work)@@            if it["role"] != "work":
                continue@@            if it["role"] not in ("work", "filler"):
                continue
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
stop não devolve o que parou@@        out["stopped"].append({"item": r["item"], "run": r["run"], "pid": r["pid"]})@@        pass
a marca ballast-item de OUTRA pasta de lastro vale como item nosso@@ and (valid is None or parts[1] in valid):@@ and True:
RAM de partida do work ignora o teto de RSS do item@@used + cores > budget:
                continue
            if mem_left - it["rss_mb"] < cfg.ram_start_mb:@@used + cores > budget:
                continue
            if mem_left < cfg.ram_start_mb:
RAM de partida do filler ignora o teto de RSS do item@@fill_used + cores > budget):
                continue
            if mem_left - it["rss_mb"] < cfg.ram_start_mb:@@fill_used + cores > budget):
                continue
            if mem_left < cfg.ram_start_mb:
stop não anota o motivo da rodada@@            st["killed"].setdefault(r["run"], "stop")@@            pass
rodada parada à mão ganha o cooldown de falha@@"preempt", "stop"):@@"preempt"):
cron.err cresce sem teto@@    trim_log(os.path.join(cfg.home, "cron.err"), 262144, 65536)@@    pass
ticks.jsonl cresce sem teto@@        if os.path.exists(path) and os.path.getsize(path) > cap:@@        if False:
quem levou TERM e ainda morre é recomeçado em cima@@        running_names = seen_names | {k["item"] for k in rec["killed"]}@@        running_names = {r["item"] for r in run.values()} | {k["item"] for k in rec["killed"]}
prefixo de lançamento inválido é aceito@@    if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):@@    if False:
prefixo sem nice aceito fora do selftest@@    if not test and "nice" not in v:@@    if False:
a RAM lida uma vez: o work planejado não desconta a sobra do seguinte@@            used += cores
            mem_left -= it["rss_mb"]@@            used += cores
a RAM lida uma vez: o filler começado não desconta a sobra do seguinte@@                mem_left -= it["rss_mb"]@@                pass
item que roda não ocupa núcleos (running_cores zerado)@@        tot += c@@        tot += 0
meta.json ausente conta 1 núcleo (errar para menos)@@            c = budget if c == "auto" else c@@            c = 1
meta.json com núcleos 0 vale@@if not (_int(c) and c >= 1):@@if not _int(c):
item que já roda pode ser começado de novo (rodando ignorado)@@    if item["name"] in running_names:@@    if False:
tabela de processos ilegível aparece como running [] no registro@@ if procs is not None else None@@
mode padrão ligado quando o tick não leu a chave on@@"mode": None, "note": ""@@"mode": "ligado", "note": ""
registry_errors padrão [] quando o registro não foi lido@@"registry_errors": None, "ram": None,@@"registry_errors": [], "ram": None,
estado com last de forma errada passa por válido@@last is None or (isinstance(last, dict)@@True or (isinstance(last, dict)
status não valida a forma do estado@@            st = fresh_state()@@            pass
status não distingue estado ausente@@        out["state"] = "ausente"@@        pass
pids listados e nenhum legível viram "ninguém roda"@@    if seen and not out:@@    if False:
stop não manda KILL no que sobrou na sessão@@    if left:   # o que sobrou@@    if False:   # o que sobrou
stop olha só o líder e não a sessão (a sonda de grupo que passava com o item vivo)@@p["sid"] == r["pid"] and p["state"] != "Z" and pid_exists(p["pid"])@@p["pid"] == r["pid"] and p["state"] != "Z" and pid_exists(p["pid"])
stop dá por sumido o que ainda responde ao sinal 0@@        os.kill(pid, 0)
        return True@@        os.kill(pid, 0)
        return False
stop com sobrevivente ou tabela ilegível sai rc 0@@return 5 if out.get("survivors") or out.get("unverified") else 0@@return 0
stop devolve em stopped a rodada que tem sobrevivente@@        out["stopped"] = [x for x in out["stopped"] if x["run"] not in left]@@        pass
stop com tabela ilegível depois do TERM diz que esvaziou@@        except Unreadable:
            return None@@        except Unreadable:
            return {}
stop sem SIGCONT (item parado não trata o TERM)@@        send(r, signal.SIGCONT)
        if st is not None:@@        if st is not None:
terminate sem SIGCONT (item parado não trata o TERM)@@    send(r, signal.SIGCONT)
    st["term"][r["run"]] = cfg.now@@    st["term"][r["run"]] = cfg.now
meta.json com pid 0/1 vale como líder da rodada@@type(m.get("pid")) is int and m["pid"] > 1:@@isinstance(m.get("pid"), int):
meta.json ilegível não deixa nota@@                notes.append("meta-ilegivel:%s" % r["run"])@@                pass
nome do item pela pasta tira todo número final@@r"-[0-9]{9,}(-[0-9]+)?$"@@r"-[0-9]+(-[0-9]+)?$"
meminfo ilegível derruba também a leitura dos processos (leituras juntas)@@        procs, unf, run = current_runs(cfg)@@        if bad:
            raise Unreadable("juntas")
        procs, unf, run = current_runs(cfg)
send não tolera o membro que recusa o sinal (o EPERM do bash root do helper derruba o resto)@@        except (ProcessLookupError, PermissionError):
            pass
    return hit@@        except ProcessLookupError:
            pass
    return hit
send para no primeiro membro que recusa (os de depois ficam sem o sinal)@@        except (ProcessLookupError, PermissionError):
            pass
    return hit@@        except (ProcessLookupError, PermissionError):
            break
    return hit
send conta como sinalizado o membro que recusou@@        except (ProcessLookupError, PermissionError):
            pass
    return hit@@        except (ProcessLookupError, PermissionError):
            hit = True
    return hit
send só sinaliza o grupo do líder (o timeout do GNU muda de grupo e fica de fora)@@    for m in r["members"]:
        try:
            os.kill(m, sig)@@    for m in []:
        try:
            os.kill(m, sig)
send desiste dos membros quando o grupo do líder já não existe@@    except ProcessLookupError:
        pass
    except PermissionError:
        return False@@    except ProcessLookupError:
        return False
    except PermissionError:
        return False
órfão nunca é limpo (a rodada fica rodando até o último sair)@@    return _int(start) and t >= start and cfg.now - t >= cfg.orphan_grace_s@@    return False
a graça é ignorada (o órfão leva TERM no tick do rc)@@t >= start and cfg.now - t >= cfg.orphan_grace_s@@t >= start
BALLAST_ORPHAN_GRACE_S não é lida (graça fixa em 180 s)@@orphan_grace_s=_num(env, "BALLAST_ORPHAN_GRACE_S", 180, int, 0)@@orphan_grace_s=180
rc que não é inteiro conta como item terminado@@            int(f.read().strip())@@            f.read()
carimbo de outro relógio vale como idade do rc (sem conferir o início da rodada)@@_int(start) and t >= start and cfg.now - t@@_int(start) and cfg.now - t
sem rc o item é dado por terminado (qualquer rodada velha perde os órfãos… e o item vivo)@@    except (OSError, ValueError):
        return False
    return _int(start)@@    except (OSError, ValueError):
        return True
    return _int(start)
a rodada com órfão sai do orçamento só no tick seguinte (o run não é tirado da lista)@@                terminate(cfg, st, r, "orfaos", rec)
                del run[r["run"]]@@                terminate(cfg, st, r, "orfaos", rec)
a rodada limpa de órfãos fecha como orfaos e não pelo rc do item (ganharia o cooldown de falha)@@why = (None if orph else killed) or (@@why = killed or (
a linha da rodada não diz que houve órfãos@@        row["orfaos"] = True@@        pass
[teto] sem o barramento do usuário o item começa assim mesmo (o teto some quando não há gerenciador)@@    if not os.path.exists(bus):@@    if False:
[teto] sem systemd-run no PATH o item começa assim mesmo@@    if shutil.which("systemd-run") is None:@@    if False:
[teto] sem teto pronto o tick não bloqueia o começo de itens (a nota sem-teto não trava)@@"primeira-leitura", "lacuna", "sem-teto")@@"primeira-leitura", "lacuna")
[teto] o systemd-run não leva TasksMax@@"-p", "TasksMax=%d" % cfg.tasks_max,@@
[teto] o systemd-run não leva MemoryMax@@"-p", "MemoryMax=%dM" % mem_cap_mb(cfg, item),@@
[teto] o systemd-run não leva MemorySwapMax=0@@"-p", "MemorySwapMax=0",@@
[teto] OOMPolicy=kill mata o item inteiro e leva o rc e os picos junto@@"-p", "OOMPolicy=continue"@@"-p", "OOMPolicy=kill"
[teto] o MemoryMax ignora o fator (rss_mb cru)@@    return int(math.ceil(item["rss_mb"] * cfg.mem_factor))@@    return int(item["rss_mb"])
[teto] o escopo não é --collect (escopo morto por OOM fica como unidade failed)@@"--quiet", "--collect",@@"--quiet",
[teto] a unidade não leva o nome da rodada@@"--unit=ballast-" + run@@"--unit=ballast"
[teto] o item herda o barramento do usuário (pode pedir um escopo fora do teto)@@"-u", "DBUS_SESSION_BUS_ADDRESS"] + wrapper@@] + wrapper
[teto] a meta.json não guarda o teto que valeu@@        meta["ceiling"] = {"tasks": cfg.tasks_max, "mem_mb": mem_cap_mb(cfg, item)}@@        pass
[teto] fork recusado no cgroup do item não é lido (pids.events)@@    if pe is not None and pe.get("max", 0) > 0:@@    if False:
[teto] zero forks recusados já conta como estouro@@    if pe is not None and pe.get("max", 0) > 0:@@    if pe is not None and pe.get("max", 0) >= 0:
[teto] oom_kill no cgroup do item não é lido (memory.events)@@    if me is not None and me.get("oom_kill", 0) > 0:@@    if False:
[teto] o max do memory.events (cache recuperado no limite) conta como estouro@@    if me is not None and me.get("oom_kill", 0) > 0:@@    if me is not None and me.get("max", 0) > 0:
[teto] contador ilegível vira lista vazia e some a nota (ilegível ≠ zero estouros calado)@@    return out or None@@    return out
[teto] o caminho do cgroup não é conferido (qualquer cgroup, até a sessão de login, recebe a leitura e o kill)@@    if not m or m.group(1) != run or any(s in (".", "..") for s in raw.split("/")):@@    if not raw:
[teto] o nome da rodada no caminho não é conferido (escopo de outra rodada vale)@@    if not m or m.group(1) != run or any(@@    if not m or any(
[teto] caminho com .. passa na conferência@@ or any(s in (".", "..") for s in raw.split("/")):@@:
[teto] estouro de teto espera a graça do TERM em vez de KILL@@            elif breach:
                kill_now(cfg, st, r, breach, rec)@@            elif breach:
                terminate(cfg, st, r, breach, rec)
[teto] o tick nunca lê o cgroup do item (meta.ceiling ignorada)@@(t is None and on and m.get("ceiling"))@@(t is None and on and False)
[teto] kill_now não manda cgroup.kill@@    cgroup_kill(cfg, r["run"])   # quem fez setsid sai da sessão e o send() não o alcança; o cgroup alcança@@    pass
[teto] o fim de rodada não manda kill ao que sobrou no cgroup@@    cgroup_kill(cfg, run)@@    pass
[teto] relatório ilegível vira 0 (nunca null)@@        kv[k] = int(v) if v.isdigit() else None@@        kv[k] = int(v) if v.isdigit() else 0
[teto] pico de memória do relatório fica em bytes@@mem // 1048576 if mem is not None else None@@mem if mem is not None else None
[teto] o relatório com fork recusado não muda o motivo da rodada@@hit = ("teto-processos" if (rep or {}).get("tasks_hit") else@@hit = (None if (rep or {}).get("tasks_hit") else
[teto] o relatório com oom_kill não muda o motivo da rodada@@else "teto-memoria" if (rep or {}).get("oom_kill") else None)@@else None if (rep or {}).get("oom_kill") else None)
[teto] BALLAST_CEILING=off vale fora do selftest@@    if raw == "off" and test:@@    if raw == "off":
[teto] BALLAST_TASKS_MAX aceita qualquer valor (sem o mínimo de 16)@@_num(env, "BALLAST_TASKS_MAX", 4096, int, 16)@@_num(env, "BALLAST_TASKS_MAX", 4096, int, 0)
[teto] BALLAST_MEM_FACTOR aceita fator abaixo de 1 (teto menor que o rss_mb)@@_num(env, "BALLAST_MEM_FACTOR", 1.25, float, 1.0)@@_num(env, "BALLAST_MEM_FACTOR", 1.25, float, 0.0)
[teto] o status não traz o bloco ceiling@@"ceiling": {"mode": cfg.ceiling, "ready": ceil_ok@@"ceilingX": {"mode": cfg.ceiling, "ready": ceil_ok
[teto-linux] o item não escreve o cgroup dele (o governo não sabe onde ler)@@'[ -z "$BALLAST_CEILING_ON" ] || { { cut -d: -f3@@'[ -n "$BALLAST_CEILING_ON" ] || { { cut -d: -f3
[teto-linux] o relatório do item perde o fork recusado@@sed -n "s/^max /pids_hits /p" $c/pids.events;@@
[teto-linux] o relatório do item perde o oom_kill@@sed -n "s/^oom_kill /oom_kill /p" $c/memory.events;@@
[teto-linux] o relatório do item perde o pico de memória@@echo "mem_peak $(cat $c/memory.peak)";@@
[teto-linux] o stop não manda kill ao cgroup de cada rodada aberta (o escapee de setsid sobrevive)@@        cgroup_kill(cfg, rn)@@        pass
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
    grp=""; case "$desc" in "[teto]"*|"[teto-linux]"*) grp=teto ;; esac
    [ -z "${HB_MUTANTS_ONLY:-}" ] || [ "$grp" = "$HB_MUTANTS_ONLY" ] || continue
    case "$desc" in "[teto-linux]"*) cgrp_ok || { echo "skip mutante '$desc' (sem systemd-run --user utilizável neste host)"; continue; };; esac
    while [ "$(jobs -r | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
    ( HB_MUTANT=1 HB_MUTANT_GROUPS="$grp" HB_UNDER_TEST="$T/mut$idx.py" bash "$0" 2>&1 | tail -1 > "$T/mres.$idx" ) &
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
