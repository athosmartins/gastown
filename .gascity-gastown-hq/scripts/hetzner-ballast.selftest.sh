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
#   elástico (g_elastic, ga-2hd02v.5.11): o registro `N-M` e os slots que sobem e descem pela CPU ociosa, a RAM e o PSI de disco (e a chave elastic.off) · o fg líquido do tempo de kernel do próprio lastro (cpu.stat) · o cooldown curto da rodada `parcial`.
# CONTROLE NEGATIVO: cada mutante (um trecho do script trocado) TEM que reprovar a bateria. Mutante com descrição `[teto]` roda só os grupos do teto; com `[elastico]`, só o g_elastic.
# VARIÁVEIS: HB_UNDER_TEST (script a testar) · HB_PY (interpretador; padrão /usr/bin/python3) · HB_NO_MUTANTS=1 · HB_MUTANTS_ONLY=teto|elastico (só os mutantes do teto, ou dos slots elásticos) · HB_ONLY=<grupo> (reg tick run ram reap fill off state logs launch send ceil cgrp elastic; sem mutantes)
set -u
# argumentos (o mbp-run.sh --repo hq só leva argumentos ao selftest, não variáveis de ambiente): --only GRUPO = HB_ONLY, --no-mutants = HB_NO_MUTANTS=1, --mutants-only GRUPO = HB_MUTANTS_ONLY, --under-test = HB_UNDER_TEST
while [ $# -gt 0 ]; do
  case "$1" in
    --only) HB_ONLY="${2:?--only GRUPO}"; shift 2 ;;
    --no-mutants) HB_NO_MUTANTS=1; shift ;;
    --mutants-only) HB_MUTANTS_ONLY="${2:?--mutants-only GRUPO}"; shift 2 ;;
    --under-test) HB_UNDER_TEST="$(cd "$(dirname "${2:?--under-test CAMINHO}")" && pwd)/$(basename "$2")"; shift 2 ;;   # o governo a testar (a prova de que um teste novo reprova no anterior)
    *) echo "uso: $0 [--only GRUPO] [--no-mutants] [--mutants-only teto|elastico|piso] [--under-test CAMINHO]" >&2; exit 2 ;;
  esac
done
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
cleanup() { killtree "$T/"; pkill -f "$T/" 2>/dev/null; command -v systemctl > /dev/null 2>&1 && systemctl --user stop "ballast-s$$-*" > /dev/null 2>&1; sleep 0.2; chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
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
LU=$(id -run); mkdir -p "$T/linger"; : > "$T/linger/$LU"   # linger ligado por padrão (o arquivo que `loginctl enable-linger` cria); os casos de linger trocam BALLAST_LINGER_DIR pelo EXTRA_ENV
printf '#!/bin/sh\n# timeout de brinquedo (o do macOS não existe): descarta "-k K DUR" e roda\nshift 3; exec "$@"\n' > "$W/bin/timeout"; chmod +x "$W/bin/timeout"
# tmux de brinquedo (ga-03rqsr0): o governo conta as sessões do nó com `tmux -L gc-remote list-sessions`. Sem os arquivos fake-tmux.rc/.out na pasta do lastro ele NÃO LÊ (rc 2, texto que não é o de "sem servidor"): o piso de RAM fica
# no fixo de sempre e os testes de antes seguem valendo sem mudança; os casos do piso dinâmico escrevem os arquivos (tmux_n / tmux_none). Os argumentos que recebeu vão para fake-tmux.args.
printf '#!/bin/sh\necho "$*" >> "$BALLAST_HOME/fake-tmux.args"\n[ -f "$BALLAST_HOME/fake-tmux.rc" ] || { echo "tmux de brinquedo: sem leitura" >&2; exit 2; }\ncat "$BALLAST_HOME/fake-tmux.out"\nexit "$(cat "$BALLAST_HOME/fake-tmux.rc")"\n' > "$W/bin/tmux"; chmod +x "$W/bin/tmux"
NCPU=16
N=0; H=""; FP=""; NOW=0; U=0; NI=0; ID=0; EXTRA_ENV=""; LP='[]'; PID=""; RUN=""; CEIL=""; SD=""; CGD=""; CGN=""

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
  OUT=$(env PATH="$W/bin:$PATH" BALLAST_HOME="$H" BALLAST_PROC="$FP" BALLAST_NOW="$NOW" BALLAST_LAUNCH_PREFIX="$LP" BALLAST_TEST=1 BALLAST_CEILING="${CEIL:-off}" BALLAST_LINGER_DIR="$T/linger" $EXTRA_ENV "$PY" -I "$P" "$@" 2>"$W/err"); RC=$?
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
  newhome; CEIL=off; LP='["nice","-n","19"]'; EXTRA_ENV="BALLAST_TEST=0"; bt status --json; r1=$RC; CEIL=systemd; bt status --json
  check "teto: fora do selftest BALLAST_CEILING=off é recusado (rc 3) e o mesmo ambiente com o teto de verdade vale (rc 0): o lastro nunca roda sem teto por engano" "3 0" "$r1 $RC"

  # pronto ou não: sem gerenciador de usuário o item NÃO começa (o teto é condição, não enfeite)
  newhome; fakesd; rm -f "$T/rt/bus"; seed; good 50; good 50; good 50
  check "teto: com linger mas sem o barramento do usuário (o gerenciador não está de pé) o item NÃO começa" "[]" "$(jget started)"
  check "teto: ...a nota do tick diz sem-teto e o stderr diz o motivo" "1 1" "$(jget note | grep -c 'sem-teto') $(grep -c 'sem teto' "$W/err")"
  check "teto: ...e não fica pasta de rodada pela metade" "0" "$(ls "$H/runs" 2>/dev/null | wc -l | tr -d ' ')"
  bt status --json
  check "teto: o status diz que o teto NÃO está pronto, com o motivo (o barramento)" "false 1" "$(jget ceiling.ready) $(jget ceiling.why | grep -c 'bus')"
  # linger: o barramento sozinho NÃO é "pronto". Quem pergunta o status por ssh tem sessão e, com ela, o barramento; o cron não tem nenhum dos dois (gate 1 da ga-kgnjkt8)
  newhome; fakesd; mkdir -p "$T/nolinger"; EXTRA_ENV="$EXTRA_ENV BALLAST_LINGER_DIR=$T/nolinger"; seed; good 50; good 50; good 50
  check "teto: com o barramento presente MAS sem linger o item NÃO começa (o cron não tem a sessão que sobe o gerenciador)" "[]" "$(jget started)"
  check "teto: ...a nota do tick diz sem-teto e o stderr diz que falta o linger" "1 1" "$(jget note | grep -c 'sem-teto') $(grep -c 'sem linger' "$W/err")"
  bt status --json
  check "teto: ...e o status, perguntado COM o barramento à mão, diz NÃO pronto pelo motivo do linger (a resposta é a de quem começa o item)" "true false 1" "$([ -e "$T/rt/bus" ] && echo true || echo false) $(jget ceiling.ready) $(jget ceiling.why | grep -c 'sem linger')"
  EXTRA_ENV="$EXTRA_ENV BALLAST_LINGER_DIR=$T/inexistente"; bt status --json
  check "teto: a pasta do linger nem existir é 'sem linger' (não pronto), não 'ilegível'" "false 1 0" "$(jget ceiling.ready) $(jget ceiling.why | grep -c 'sem linger') $(jget ceiling.why | grep -c 'não consegui ler')"
  newhome; fakesd; : > "$T/notadir"; EXTRA_ENV="$EXTRA_ENV BALLAST_LINGER_DIR=$T/notadir"; seed; good 50; good 50; good 50
  check "teto: linger que NÃO consegui ler (a pasta é um arquivo: ENOTDIR) → o item NÃO começa, com a nota sem-teto" "[] 1" "$(jget started) $(jget note | grep -c 'sem-teto')"
  bt status --json
  check "teto: ...o status diz que NÃO li o linger (outro motivo que 'sem linger': ilegível nunca vira 'ligado' nem 'desligado')" "false 1 0" "$(jget ceiling.ready) $(jget ceiling.why | grep -c 'não consegui ler se o linger') $(jget ceiling.why | grep -c 'sem linger')"
  mkdir -p "$T/lingerdir/$LU"; EXTRA_ENV="$EXTRA_ENV BALLAST_LINGER_DIR=$T/lingerdir"; bt status --json
  check "teto: o 'arquivo' de linger que é uma pasta também é ilegível, nunca linger ligado" "false 1" "$(jget ceiling.ready) $(jget ceiling.why | grep -c 'não consegui ler se o linger')"
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
  # stop: o cgroup.kill que NÃO deu para confirmar aparece em cgroup_unverified (um setsid pode ter sobrado e a sessão não o vê); escopo já vazio e rodada sem teto não são aviso (rc segue 0)
  ceil_one; gone "$PID"; rm -f "$CGD/cgroup.kill"; mkdir "$CGD/cgroup.kill"; bt stop
  check "teto: stop com o escopo vivo mas o cgroup.kill RECUSADO (o kernel não aceita a escrita) → a rodada entra em cgroup_unverified, rc 0" "$RUN 0" "$(jget cgroup_unverified.0) $RC"
  ceil_one; gone "$PID"; : > "$H/runs/$RUN/cgroup"; bt stop
  check "teto: stop com o caminho do cgroup ilegível (o item não o escreveu) → cgroup_unverified (não sei: nunca 'nada a matar')" "$RUN" "$(jget cgroup_unverified.0)"
  ceil_one; gone "$PID"; rm -rf "$CGD"; bt stop
  check "teto: stop com o escopo já SUMIDO (nada a matar) → sem cgroup_unverified" "null" "$(jget cgroup_unverified)"
  ceil_one; gone "$PID"; bt stop
  check "teto: stop com o cgroup.kill gravado → sem cgroup_unverified, e o cgroup.kill recebeu 1" "null 1" "$(jget cgroup_unverified) $(cat "$CGD/cgroup.kill")"
  newhome; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" hq "$RUN"; gone "$PID"; bt stop
  check "teto: stop de uma rodada SEM teto (sem meta.ceiling, sem cgroup) → sem cgroup_unverified (não há o que conferir)" "null" "$(jget cgroup_unverified)"
  rm -f "$W/bin/systemd-run"
}

# ── g_cgrp ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# O kernel de verdade (ga-kgnjkt8): só onde há um gerenciador de usuário do systemd de pé (Linux, com sessão aberta aqui; o linger vem de fixture); nos outros ambientes a bateria diz `skip` e isso NÃO conta como passou. Todo
# "descontrolado" daqui é LIMITADO POR CONSTRUÇÃO (300 filhos, 400 MB): sem o teto o teste reprova, não derruba a máquina. A leitura de /proc/stat e meminfo continua de mentira; processo e cgroup são reais.
cgrp_ok() {
  [ "$(uname -s)" = Linux ] && command -v systemd-run > /dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] && systemd-run --user --scope --quiet --collect -p TasksMax=16 true > /dev/null 2>&1
}
cgrp_item() {  # cgrp_item NOME 'corpo python' RSS_MB — newhome com UM item real (script python em $H/items/s<pid>-NOME.py) sob o systemd-run REAL. O nome leva o pid do selftest: a unidade do systemd é ballast-<item>-<época do relógio de mentira>, e sem isso uma rodada que morreu no meio (ou o mutante em paralelo) deixa um escopo de mesmo nome vivo e o próximo systemd-run recusa
  newhome; CEIL=systemd; CGN="s$$-$1"; : > "$H/items.tsv"
  printf '#!%s\nimport os, time\nRD = os.environ["BALLAST_RUN_DIR"]\n%s\n' "$PY" "$2" > "$H/items/$CGN.py"; chmod +x "$H/items/$CGN.py"; reg "$CGN|work|4|$3|3600|300|-|$CGN.py"
}
cgrp_start() { seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" "$CGN" "$RUN"; }
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
  check "cgrp: o item que termina sozinho grava o relatório: pids_peak entre 10 e 40, pids_hits > 0 (fork recusado) e mem_peak > 0, lidos do kernel" "1 1 1" "$(awk '$1=="pids_peak"{p=$2} $1=="pids_hits"{h=$2} $1=="mem_peak"{m=$2} END{print (p>=10 && p<=40 ? 1 : 0), (h>0 ? 1 : 0), (m>0 ? 1 : 0)}' "$H/runs/$RUN/ceiling" 2>/dev/null)"
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
  cgrp_start es; waitfile "$H/runs/$RUN/esc.pid"; sleep 0.3; EP=$(cat "$H/runs/$RUN/esc.pid" 2>/dev/null); case "$EP" in ''|*[!0-9]*|0|1) EP="" ;; esac   # pid inválido nunca vira kill: `kill -9 0` mata o GRUPO inteiro (o selftest junto)
  check "cgrp: o escapee (setsid) está vivo e fora da sessão do item" "1" "$([ -n "$EP" ] && plive "$EP" && [ "$(ps -o sid= -p "$EP" | tr -d ' ')" != "$PID" ] && echo 1 || echo 0)"
  bt stop
  if [ -n "$EP" ]; then pdead "$EP"; check "cgrp: o stop mata também quem fez setsid (o cgroup.kill pega; a sessão não o enxerga)" "0" "$?"; kill -9 "$EP" 2>/dev/null
  else ok 1 "cgrp: o escapee nem nasceu (esc.pid ausente ou inválido): o item es não começou?"; fi
}

# ── g_elastic ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Slots ELÁSTICOS (ga-2hd02v.5.11). O governo conta núcleo NOMINAL: o wa-mutants reservava 4 e a CPU ociosa do nó ficava sem uso (tarde de 04/11: 30-37% de ocupação, 8 núcleos livres). O registro `N-M` (núcleos 4-12) mantém o N como reserva do
# orçamento e deixa o item subir até o M: a cada tick o governo mede a CPU ociosa REAL (idle+iowait do /proc/stat), a RAM (MemAvailable) e a pressão de disco (PSI io) e escreve em runs/<rodada>/slots quantos slots o motor pode usar AGORA.
#   sobe +BALLAST_ELASTIC_STEP (2) com >= BALLAST_ELASTIC_ROOM (2) núcleos ociosos ALÉM da reserva, RAM que deixa MemAvailable >= o piso de partida depois dos slots novos (512 MB cada) e disco sem pressão (io full avg10 <= metade do teto)
#   desce 2 com MemAvailable abaixo do piso de retomada + 1 GB, 1 com io full avg10 > teto (25) ou com menos de 1 núcleo ocioso (a reserva); fica quando a leitura é boa mas não pede nada; leitura que não veio (CPU, RAM) NUNCA muda o limite
#   e PSI que não veio só impede de SUBIR. elastic.off derruba ao mínimo. A conta de núcleos do orçamento (o que o item reserva para começar outros) continua sendo o N.
# FG LÍQUIDO: o tempo de KERNEL do próprio lastro (copiar árvores, journal) cai na coluna `system` do /proc/stat, que o governo lê como carga de sessão; o cpu.stat do escopo de cada item diz quanto foi (system_usec) e o governo tira isso do fg.
setpsi() {  # setpsi SOME10 FULL10 — o /proc/pressure/io de mentira
  mkdir -p "$FP/pressure"; printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$1" "$2" > "$FP/pressure/io"
}
el_one() {  # el_one LO HI [RSS_MB] — newhome + o item `wam` (work, LO-HI núcleos) rodando e visível no /proc de mentira (1 KB de RSS): PID e RUN. O item anota o BALLAST_CORES_MAX que recebeu em cmax
  newhome; : > "$H/items.tsv"; printf '#!/bin/sh\necho "$BALLAST_CORES_MAX" > "$BALLAST_RUN_DIR/cmax"\nsleep 300\n' > "$H/items/wam.sh"; chmod +x "$H/items/wam.sh"; reg "wam|work|$1-$2|${3:-1024}|3600|300|-|wam.sh"
  setpsi 1 1; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" wam "$RUN"
}
slots_now() { cat "$H/runs/$RUN/slots" 2> /dev/null | tr -d ' \n'; echo; }
eltick() {  # eltick FG NICE MEM [SOME FULL] — um tick com a carga de sessões (FG%), a RAM e o PSI de disco dados; o resto da CPU é ociosa
  setmem "$3"; setpsi "${4:-1}" "${5:-1}"; adv "$1" "$2"; bt
}
mkpar() {  # mkpar — os itens parcial.sh e completo.sh: imprimem o resumo e dormem
  printf '#!/bin/sh\necho '"'"'BALLAST-SUMMARY: {"result": "parcial"}'"'"'\nsleep 300\n' > "$H/items/parcial.sh"; printf '#!/bin/sh\necho '"'"'BALLAST-SUMMARY: {"result": "completo"}'"'"'\nsleep 300\n' > "$H/items/completo.sh"; chmod +x "$H/items/parcial.sh" "$H/items/completo.sh"
}
par_one() {  # par_one SCRIPT RC SEGUNDOS [PASSO=60 [TICKS=3]] — newhome + o item `pa` (work, 2 núcleos, cooldown 300) acaba com rc RC depois de SEGUNDOS de relógio (resumo no log) e o tick que o encerra roda; depois TICKS leituras livres, uma a cada PASSO s
  # (o pulo do relógio acima de 180 s abre uma lacuna que zera a conta de leituras livres). PAR_T = segundos depois do tick que encerrou a rodada em que o item RECOMEÇOU, em QUALQUER dos ticks ("-" = não recomeçou): o último tick sozinho não vê um recomeço mais cedo
  newhome; : > "$H/items.tsv"; mkpar; reg "pa|work|2|1024|3600|300|-|$1"; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" pa "$RUN"
  local i=0 k=1; while [ "$i" -lt 50 ] && ! grep -q 'BALLAST-SUMMARY' "$H/runs/$RUN/log" 2> /dev/null; do sleep 0.2; i=$((i+1)); done
  gone "$PID"; echo "$2" > "$H/runs/$RUN/rc"; adv 50 0 "$3"; bt
  PAR_T="-"; while [ "$k" -le "${5:-3}" ]; do adv 50 0 "${4:-60}"; bt; [ "$PAR_T" != "-" ] || [ "$(nstart)" = 0 ] || PAR_T=$((k * ${4:-60})); k=$((k+1)); done
}
g_elastic() {
  local a b c d
  # registro: N-M é o mínimo e o máximo; qualquer outra forma é erro visível e o item fica inerte
  newhome; : > "$H/items.tsv"; reg 'a|work|2-6|1024|3600|300|-|sleeper.sh'; reg 'b|work|3|1024|3600|300|-|sleeper.sh'; reg 'c|work|2-2|1024|3600|300|-|sleeper.sh'; reg 'd|work|4-2|1024|3600|300|-|sleeper.sh'; reg 'e|work|0-4|1024|3600|300|-|sleeper.sh'; reg 'f|work|x-3|1024|3600|300|-|sleeper.sh'; reg 'g|work|3-|1024|3600|300|-|sleeper.sh'; reg 'h|filler|2-6|1024|3600|300|-|sleeper.sh'; bt status --json
  check "elástico/registro: 2-6 lê (núcleos 2, máximo 6) e 3 continua fixo (máximo null); 2-2, 4-2, 0-4, x-3, 3- e um filler elástico são 6 erros visíveis (o filler não tem orçamento para elasticidade)" "2 6 3 null 6" "$(jget items.0.cores) $(jget items.0.cores_max) $(jget items.1.cores) $(jget items.1.cores_max) $(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; print(len(json.load(sys.stdin)["registry_errors"]))')"

  # começo: o item recebe o máximo e começa no mínimo (o arquivo de slots já existe quando ele roda); a reserva do orçamento é o mínimo
  el_one 2 6; waitfile "$H/runs/$RUN/cmax"
  check "elástico/início: o item recebe BALLAST_CORES_MAX=6, o slots-file da rodada começa em 2 (o motor já o lê ao subir), a rodada conta 2 núcleos e a meta guarda o máximo 6" "6 2 2 6" "$(cat "$H/runs/$RUN/cmax") $(slots_now) $(jget started.0.cores) $("$PY" -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("cores_max"))' "$H/runs/$RUN/meta.json")"
  newhome; : > "$H/items.tsv"; reg 'fx|work|2|1024|3600|300|-|sleeper.sh'; seed; good 50; good 50; good 50; RUN=$(started_run)
  check "elástico/início: item de núcleos FIXOS não ganha arquivo de slots (nada muda para quem não é elástico)" "0" "$([ -e "$H/runs/$RUN/slots" ] && echo 1 || echo 0)"
  newhome; fakesd; : > "$H/items.tsv"; reg 'wam|work|2-6|1024|3600|300|-|sleeper.sh'; seed; good 50; good 50; good 50; waitfile "$SD/call.1"
  check "elástico/início: o teto de memória do escopo é o do máximo (1024 MB x 1,25 x 6/2 = 3840 MB): o kernel é a rede de baixo do máximo, não do mínimo" "1 0" "$(callhas MemoryMax=3840M) $(callhas MemoryMax=1280M)"

  # sobe: CPU ociosa de sobra, RAM e disco folgados → +2 por tick até o máximo
  el_one 2 6; eltick 30 0 28000; a=$(slots_now); eltick 30 0 28000; b=$(slots_now); eltick 30 0 28000; c=$(slots_now)
  check "elástico/sobe: 70% da CPU ociosa (11,2 núcleos), RAM de 28 GB e disco calmo: +2 por tick (2 → 4 → 6) e nunca passa do máximo" "4 6 6" "$a $b $c"
  check "elástico/sobe: o tick no máximo registra a decisão (de 6 para 6, motivo max) e o que mediu (11,2 núcleos ociosos, io full 1,0)" "wam 6 6 max 11.2 1.0" "$(jget elastic.0.item) $(jget elastic.0.from) $(jget elastic.0.to) $(jget elastic.0.why) $(jget idle_cores) $(jget io_full)"
  el_one 2 6; eltick 30 0 28000; check "elástico/sobe: o primeiro tick registra de 2 para 4, motivo up" "up 2 4" "$(jget elastic.0.why) $(jget elastic.0.from) $(jget elastic.0.to)"
  el_one 2 6; eltick 81 0 28000; a=$(slots_now); el_one 2 6; eltick 82 0 28000; b=$(slots_now)
  check "elástico/sobe: a fronteira da CPU (>= 2 núcleos ociosos além da reserva de 1): 19% ociosos (3,04) sobem, 18% (2,88) ficam" "4 2" "$a $b"
  NCPU=12; el_one 2 6; eltick 75 0 28000; a=$(slots_now); NCPU=16
  check "elástico/sobe: a fronteira é INCLUSIVA: com exatamente 3,0 núcleos ociosos (25% de 12) sobram 2,0 além da reserva de 1 e o item sobe" "4" "$a"
  el_one 2 6; eltick 85 0 28000; a=$(slots_now); eltick 94 0 28000; b=$(slots_now)
  check "elástico/CPU: entre 1 e 3 núcleos ociosos (15% = 2,4) fica onde está; abaixo da reserva (6% = 0,96) um item que já está no mínimo continua no mínimo" "2 2" "$a $b"
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; eltick 93 0 28000; a=$(slots_now); eltick 94 0 28000; b=$(slots_now); eltick 94 0 28000; c=$(slots_now); eltick 94 0 28000; d=$(slots_now)
  check "elástico/CPU saturada: de 6, 7% ociosos (1,12 núcleo, a reserva é 1) fica em 6; 6% (0,96) desce 1 por tick (5, 4, 3)" "6 5 4 3" "$a $b $c $d"

  # RAM: sobe só enquanto MemAvailable - slots novos x 512 MB >= 14336 (o piso de partida); desce 2 abaixo de 13312 (retomada + 1 GB); entre os dois, fica
  el_one 2 6; eltick 30 0 14948; a=$(slots_now); el_one 2 6; eltick 30 0 14847; b=$(slots_now)
  check "elástico/RAM: a 14948 MB cabe 1 slot novo (14948 - 512 >= 14336) e não 2: sobe só 1; a 14847 MB nenhum cabe: fica" "3 2" "$a $b"
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; eltick 30 0 13500; a=$(slots_now); eltick 30 0 13312; b=$(slots_now); eltick 30 0 13311; c=$(slots_now); eltick 30 0 13000; d=$(slots_now)
  check "elástico/RAM: de 6, a 13500 MB (entre o piso de descida e o de subida) fica; a 13312 (o piso, inclusive) fica; a 13311 desce 2 (4); e segue descendo 2 por tick até o mínimo (2)" "6 6 4 2" "$a $b $c $d"
  el_one 2 6; eltick 30 0 14948; a=$(slots_now); eltick 30 0 13000; b=$(slots_now)
  check "elástico/RAM: a descida para no mínimo registrado: de 3 slots (a 14948 MB sobe 1) com RAM baixa o passo de 2 daria 1, e o item fica em 2" "3 2" "$a $b"
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; eltick 30 0 9000; a=$(slots_now)
  check "elástico/RAM: abaixo do piso de pausa o governo pausa o item (ram_step) e o elástico desce na hora, sem esperar (6 → 4)" "4" "$a"
  el_one 2 6; EXTRA_ENV="BALLAST_RAM_PAUSE_MB=30000"; eltick 30 0 28000; a=$(slots_now); b=$(jget paused)
  check "elástico/RAM: item parado por RAM nunca sobe, mesmo com CPU e RAM de sobra para os slots (aqui o piso de pausa foi posto acima da RAM só para parar o item): fica em 2 e o tick diz paused true" "2 true" "$a $b"
  # disco: PSI io full avg10 acima de 25 desce 1 por tick; acima de 12,5 só impede de subir; ilegível só impede de subir (a RAM ainda manda descer)
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; eltick 30 0 28000 30 30; a=$(slots_now); eltick 30 0 28000 30 25; b=$(slots_now); eltick 30 0 28000 30 26; c=$(slots_now)
  check "elástico/disco: io full 30 desce 1 (5); 25 (o teto, inclusive) fica; 26 desce de novo (4)" "5 5 4" "$a $b $c"
  el_one 2 6; eltick 30 0 28000 13 13; a=$(slots_now); eltick 30 0 28000 13 12.5; b=$(slots_now)
  check "elástico/disco: io full acima de metade do teto (13 > 12,5) impede de SUBIR e não desce; com 12,5 (inclusive) sobe" "2 4" "$a $b"
  el_one 2 6; setmem 28000; rm -f "$FP/pressure/io"; adv 30 0; bt; a=$(slots_now)
  check "elástico/disco: PSI ausente (o arquivo não existe) NÃO sobe: o disco não foi lido (e o tick segue, rc 0: a leitura que falta não derruba o governo)" "2 0" "$a $RC"
  el_one 2 6; setmem 28000; printf 'some avg10=1.00 avg60=0.00 avg300=0.00 total=0\n' > "$FP/pressure/io"; adv 30 0; bt; a=$(slots_now); b=$RC
  printf 'some avg10=nan avg60=0.00 avg300=0.00 total=0\nfull avg10=nan avg60=0.00 avg300=0.00 total=0\n' > "$FP/pressure/io"; adv 30 0; bt; c=$(slots_now)
  check "elástico/disco: PSI só com a linha some (sem full) ou com NaN não foi lido: NÃO sobe e o tick segue (rc 0); nunca 'full 0' nem 'calmo'" "2 0 2 0" "$a $b $c $RC"
  el_one 2 8; eltick 30 0 28000; eltick 30 0 28000; printf 'lixo\n' > "$FP/pressure/io"; setmem 28000; adv 30 0; bt; a=$(slots_now); setmem 13000; adv 30 0; bt; b=$(slots_now)
  check "elástico/disco: PSI que não é número (lixo) não sobe nem desce (6) e a RAM baixa ainda desce (4): ler só um dos dois não congela o outro" "6 4" "$a $b"
  # leitura que não veio nunca muda o limite
  el_one 2 8; eltick 30 0 28000; eltick 30 0 28000; adv 30 0 300; setmem 28000; setpsi 1 1; bt; a=$(slots_now)
  check "elástico/leitura: lacuna entre leituras da CPU (5 min sem tick) → a medida não vale e o limite fica em 6 (sem subir nem descer)" "6" "$a"
  el_one 2 8; eltick 30 0 28000; eltick 30 0 28000; rm -f "$FP/meminfo"; setpsi 1 1; adv 30 0; bt; a=$(slots_now)
  check "elástico/leitura: meminfo ilegível → o limite fica (nunca 'RAM livre' nem 'RAM baixa')" "6" "$a"
  # chave de emergência
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; : > "$H/elastic.off"; eltick 30 0 28000; a=$(slots_now); eltick 30 0 28000; b=$(slots_now); rm -f "$H/elastic.off"; eltick 30 0 28000; c=$(slots_now)
  check "elástico/chave: com elastic.off o item volta ao mínimo de uma vez (6 → 2) e fica; sem o arquivo ele volta a subir" "2 2 4" "$a $b $c"
  # estado do arquivo de slots: ilegível vale o MÍNIMO (não sei o que o motor roda), e é reescrito
  el_one 2 6; printf 'abc\n' > "$H/runs/$RUN/slots"; eltick 30 0 28000; a=$(slots_now); rm -f "$H/runs/$RUN/slots"; eltick 30 0 28000; b=$(slots_now)
  check "elástico/arquivo: slots-file com lixo, ou apagado, vale o mínimo e o governo o reescreve (2 → 4)" "4 4" "$a $b"
  el_one 2 6; printf '99\n' > "$H/runs/$RUN/slots"; eltick 30 0 28000; a=$(slots_now); printf '1\n' > "$H/runs/$RUN/slots"; eltick 30 0 28000; b=$(slots_now)
  check "elástico/arquivo: número fora de 2..6 (99 acima do máximo, 1 abaixo do mínimo) também não vale: conta como o mínimo e sobe a 4, nunca para 99 nem 3" "4 4" "$a $b"
  el_one 2 6; printf 'abc\n' > "$H/runs/$RUN/slots"; eltick 85 0 28000; a=$(slots_now)
  check "elástico/arquivo: slots-file com lixo é reescrito mesmo quando a decisão é ficar no mínimo (15% ociosos): o motor não pode ficar lendo 'abc'" "2" "$a"
  # teto de RSS proporcional: com 6 slots o item tem 3x o teto de RSS do mínimo
  el_one 2 6 100; eltick 30 0 28000; eltick 30 0 28000; alive "$PID" wam "$RUN" 250000; eltick 30 0 28000; a=$(nkilled)
  check "elástico/RSS: com 6 slots o teto de RSS é 3x (300 MB): um item de 244 MB NÃO é terminado" "0" "$a"
  : > "$H/elastic.off"; eltick 30 0 28000; eltick 30 0 28000; b=$(nkilled)
  check "elástico/RSS: ...e quando volta ao mínimo o teto também (100 MB): o mesmo item passa dele e é terminado por rss" "1 rss" "$b $(jget killed.0.why)"
  # as opções do ambiente
  el_one 2 6; EXTRA_ENV="BALLAST_ELASTIC_STEP=1"; eltick 30 0 28000; a=$(slots_now)
  check "elástico/ambiente: BALLAST_ELASTIC_STEP=1 sobe 1 por tick" "3" "$a"
  EXTRA_ENV="BALLAST_ELASTIC_STEP=0"; bt status --json; a=$RC; EXTRA_ENV="BALLAST_SLOT_MB=0"; bt status --json; b=$RC; EXTRA_ENV="BALLAST_IO_FULL_MAX=-1"; bt status --json; c=$RC
  check "elástico/ambiente: passo 0, MB por slot 0 e teto de disco negativo são configuração inválida (rc 3), nunca um elástico que não anda ou que ignora o disco" "3 3 3" "$a $b $c"

  # o orçamento: o tempo de KERNEL do próprio lastro não é carga de sessão. O governo lê o cpu.stat do escopo de cada item e tira o delta de system_usec do fg
  ceil_one; reg 'big|work|4|1024|3600|300|-|sleeper.sh'
  printf 'usage_usec 9000000\nuser_usec 4000000\nsystem_usec 1000000\n' > "$CGD/cpu.stat"; adv 50 0; bt
  check "fg líquido: na 1ª leitura não há o que comparar (sem correção): fg 8,0 cru, orçamento 7 (16 - 8 - 1) e o item de 4 núcleos NÃO cabe ao lado do hq de 4" "[] 8.0 null" "$(jget started) $(jget fg_cores) $(jget bg_sys)"
  printf 'usage_usec 69000000\nuser_usec 4000000\nsystem_usec 61000000\n' > "$CGD/cpu.stat"; adv 50 0; bt
  check "fg líquido: 60 s depois o item gastou 60 s de kernel (1,0 núcleo): fg cru 8,0, líquido 7,0, orçamento 8, e o item de 4 núcleos começa" "big 1.0 7.0 8.0" "$(jget started.0.item) $(jget bg_sys) $(jget fg_net) $(jget fg_cores)"
  ceil_one; reg 'big|work|4|1024|3600|300|-|sleeper.sh'; rm -f "$CGD/cpu.stat"; adv 50 0; bt; adv 50 0; bt
  check "fg líquido: sem cpu.stat (não consegui ler) a correção não existe, nunca zero: orçamento cru e o item NÃO começa" "[] null" "$(jget started) $(jget bg_sys)"
  ceil_one; reg 'big|work|4|1024|3600|300|-|sleeper.sh'; printf 'usage_usec 69000000\nsystem_usec 61000000\n' > "$CGD/cpu.stat"; adv 50 0; bt; printf 'usage_usec 9000000\nsystem_usec 1000000\n' > "$CGD/cpu.stat"; adv 50 0; bt
  check "fg líquido: contador que anda para trás (o cgroup foi recriado) não vira correção" "[] null" "$(jget started) $(jget bg_sys)"
  ceil_one; reg 'big|work|4|1024|3600|300|-|sleeper.sh'; printf 'usage_usec 9000000\nsystem_usec 1000000\n' > "$CGD/cpu.stat"; adv 50 0; bt; printf 'usage_usec 69000000\nsystem_usec 61000000\n' > "$CGD/cpu.stat"; adv 50 0 400; bt
  check "fg líquido: baseline velha (400 s entre as leituras: lacuna) não corrige" "null" "$(jget bg_sys)"
  ceil_one; reg 'big|work|4|1024|3600|300|-|sleeper.sh'; printf 'usage_usec 69000000\nsystem_usec 61000000\n' > "$CGD/cpu.stat"
  printf '{"t": %s, "runs": {"%s": "x"}}\n' "$NOW" "$RUN" > "$H/cpu.prev"; adv 50 0; bt
  a=$(jget bg_sys); b=$RC; printf '{"t": "%s", "runs": {"%s": 1000000}}\n' "$NOW" "$RUN" > "$H/cpu.prev"; adv 50 0; bt
  c=$(jget bg_sys); d=$RC; printf 'lixo, nao e json {\n' > "$H/cpu.prev"; adv 50 0; bt
  check "fg líquido: cpu.prev de forma errada (o contador é texto, o carimbo é texto) ou que nem é JSON não é baseline: sem correção (null) e o tick segue (rc 0)" "null 0 null 0 null 0" "$a $b $c $d $(jget bg_sys) $RC"
  ceil_one; reg 'big|work|4|1024|3600|300|-|sleeper.sh'; printf 'usage_usec 9000000\nsystem_usec 1000000\n' > "$CGD/cpu.stat"; adv 50 0; bt; printf 'usage_usec 9000000\nsystem_usec 900000000\n' > "$CGD/cpu.stat"; adv 50 0; bt
  check "fg líquido: kernel de mais que a CPU toda (899 s em 60 s: leitura absurda) leva o fg a 0, nunca a negativo (o orçamento 15 deixa o item começar)" "0.0 big" "$(jget fg_net) $(jget started.0.item)"

  # cooldown: a rodada que o item diz `parcial` (o rodízio acabou no prazo e ainda há o que varrer) volta logo; a que não rodou tempo de verdade, não
  par_one parcial.sh 0 700
  check "cooldown: rodada de 700 s que diz parcial (rc 0) volta em 180 s (a lacuna do relógio zera as 3 leituras livres que o governo pede; o cooldown de 30 s já passou, o de 300 não)" "180" "$PAR_T"
  par_one parcial.sh 0 600 8 4
  check "cooldown: o cooldown da rodada parcial é de 30 s (nem 0, nem os 300 s): com leituras livres a cada 8 s a rodada de 600 s (o mínimo, inclusive) recomeça no 4º tick (32 s) e não no 3º (24 s)" "32" "$PAR_T"
  par_one parcial.sh 0 599 8 4
  check "cooldown: 599 s é abaixo do mínimo de 600 s: espera os 300 s de sempre (nada recomeça em 32 s)" "-" "$PAR_T"
  par_one parcial.sh 0 120
  check "cooldown: rodada de só 120 s que diz parcial NÃO é prazo de verdade (pode ser infra): em 180 s ela não recomeça (os 300 s de sempre)" "-" "$PAR_T"
  par_one completo.sh 0 700
  check "cooldown: rodada de 700 s que diz completo: em 180 s não recomeça (os 300 s de sempre)" "-" "$PAR_T"
  par_one parcial.sh 3 700
  check "cooldown: parcial com rc 3 é FALHA (espera ao menos 600 s): em 180 s não recomeça" "-" "$PAR_T"
}

# ── g_floor ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# PISO DE RAM DINÂMICO (ga-03rqsr0). O piso fixo de 14336 MB para COMEÇAR item (e subir slots) foi posto para proteger sessões reais do nó, mas o nó roda 0-2 sessões e o piso deixava ~3 núcleos ociosos (wa-mutants parado em 11 de 12 slots com
# why=sem-ram; hq-selftests e hq-mutants pulados por ram). O governo agora conta as sessões vivas no tmux do provider (`tmux -L gc-remote list-sessions`), guarda o PICO das últimas BALLAST_SESS_WINDOW_S (6 h) e põe o piso em
# pausa + margem + pico x MB por sessão (10240 + 1024 + pico x 1024), nunca acima do fixo (14336). Três estados: leu N (0 = sem servidor) / não consegui ler (tmux ausente, travado ou erro estranho) → piso FIXO e o histórico não anda / histórico curto
# (aquecendo: menos de uma janela de leituras contínuas, ou lacuna > BALLAST_SESS_GAP_S) → piso FIXO. A chave ram-floor.fixed na pasta do lastro volta ao fixo. Item que já roda não é afetado: só decide COMEÇAR e SUBIR slots.
tmux_set() {  # tmux_set RC TEXTO — o que o tmux de brinquedo responde (rc e saída)
  printf '%s' "$1" > "$H/fake-tmux.rc"; printf '%s' "$2" > "$H/fake-tmux.out"
}
tmux_n() {  # tmux_n N — N sessões vivas (uma linha por nome)
  local i=1 s=""; while [ "$i" -le "$1" ]; do s="${s}dog-remote-$i
"; i=$((i+1)); done; tmux_set 0 "$s"
}
tmux_none() { tmux_set 1 "no server running on /tmp/tmux-1000/gc-remote"; }   # sem servidor = 0 sessões (o texto que o próprio provider trata como vazio)
tmux_bad() { rm -f "$H/fake-tmux.rc" "$H/fake-tmux.out"; }                      # o tmux de brinquedo não lê
fl_up() {  # fl_up [JANELA=300] [MEM=13000] [LACUNA=1800] — newhome com o hq (4 núcleos, 1024 MB), janela de sessões curta, 0 sessões e a RAM entre o piso dinâmico (11264 + 1024) e o fixo (14336 + 1024); só a 1ª leitura (semeia) já rodou
  newhome; EXTRA_ENV="BALLAST_SESS_WINDOW_S=${1:-300} BALLAST_SESS_GAP_S=${3:-1800}"; tmux_none; setmem "${2:-13000}"; seed
}
fl_rec() { echo "$(jget ram_floor_mb) $(jget ram_floor_why) $(jget sess) $(jget sess_peak) $(nstart)"; }   # piso, motivo, sessões lidas, pico, itens começados no tick
g_floor() {
  local a b c d
  # aquecendo: a janela (300 s) ainda não encheu de leituras contínuas → piso FIXO, mesmo com 0 sessões; no tick que a janela enche vira dinâmico e o item (RAM 13000) começa
  fl_up; good 50; good 50; good 50; a=$(fl_rec); good 50; b=$(fl_rec); good 50; c=$(fl_rec)
  check "piso/aquecendo: com 0 sessões e a janela ainda curta o piso é o FIXO (14336) e a RAM de 13000 MB não deixa o item começar" "14336 fixo-aquecendo 0 0 0" "$a"
  check "piso/aquecendo: no 4º tick (240 s de 300) segue fixo" "14336 fixo-aquecendo 0 0 0" "$b"
  check "piso/dinâmico: com a janela cheia (300 s) e 0 sessões o piso cai para pausa + margem (10240 + 1024 = 11264) e o item começa com 13000 MB" "11264 dinamico 0 0 1" "$c"
  check "piso/dinâmico: o tmux foi chamado com o socket do provider e a listagem de nomes" "-L gc-remote list-sessions -F #{session_name}" "$(head -n 1 "$H/fake-tmux.args")"

  # fronteira: começa quando RAM - rss do item >= piso (inclusive): 12288 - 1024 = 11264 começa, 12287 não
  fl_up 300 12287; good 50; good 50; good 50; good 50; good 50; a="$(fl_rec) $(jget skipped.0.why)"; setmem 12288; good 50; b=$(fl_rec)
  check "piso/fronteira: a 12287 MB (12287 - 1024 < 11264) o item não começa e o tick diz que foi a RAM" "11264 dinamico 0 0 0 ram" "$a"
  check "piso/fronteira: a 12288 MB (exato, inclusive) o item começa" "11264 dinamico 0 0 1" "$b"

  # pico: 2 sessões vistas dentro da janela seguram o piso em 13312 (10240 + 1024 + 2 x 1024) mesmo com 0 agora; passada a janela volta a 11264
  fl_up; tmux_n 2; good 50; tmux_none; good 50; good 50; good 50; good 50; a=$(fl_rec); good 50; b=$(fl_rec); good 50; c=$(fl_rec)
  check "piso/pico: 2 sessões vistas há 4 min seguram o piso em 13312 (e com 13000 MB o item não começa), com 0 sessões agora" "13312 dinamico 0 2 0" "$a"
  check "piso/pico: ainda dentro da janela (+ a granularidade do balde) o pico vale" "13312 dinamico 0 2 0" "$b"
  check "piso/pico: passada a janela o pico some e o piso volta a 11264 (o item começa)" "11264 dinamico 0 0 1" "$c"
  fl_up; tmux_n 3; good 50; tmux_none; good 50; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/teto: com 3 sessões o piso chega ao FIXO (14336) e segue 'dinamico' (a conta é que deu o mesmo número)" "14336 dinamico 0 3 0" "$a"
  fl_up; tmux_n 9; good 50; tmux_none; good 50; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/teto: com 9 sessões o piso NUNCA passa do fixo (14336): o dinâmico só pode liberar RAM, nunca pedir mais que antes" "14336 dinamico 0 9 0" "$a"

  # não consegui ler: tmux ausente/estranho → piso FIXO e o histórico não anda; quando volta a ler, recomeça o aquecimento (a leitura que falhou não é 'zero sessões')
  fl_up 300 13000 100; tmux_bad; good 50; good 50; good 50; good 50; good 50; a=$(fl_rec); tmux_none; good 50; b=$(fl_rec)
  check "piso/sem leitura: tmux que não lê durante a janela inteira → piso FIXO, 'sem leitura', sessões null (nunca 0) e nada começa" "14336 fixo-sem-leitura null null 0" "$a"
  check "piso/sem leitura: depois de uma falha maior que a lacuna tolerada (100 s aqui) a história não é contínua: ao voltar a ler (0 sessões) o aquecimento COMEÇA agora e 1 leitura boa não é uma janela" "14336 fixo-aquecendo 0 0 0" "$b"
  fl_up; good 50; tmux_bad; good 50; tmux_none; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/sem leitura curta: UMA leitura que falhou (60 s, menos que a lacuna de 1800 s) não derruba a história: a janela enche no tempo e o item começa" "11264 dinamico 0 0 1" "$a"
  fl_up; tmux_set 1 "protocol version mismatch (client 8, server 7)"; good 50; good 50; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/sem leitura: erro do tmux que NÃO é 'sem servidor' (versão, socket sem permissão) é não-consegui-ler, não 0 sessões" "14336 fixo-sem-leitura null null 0" "$a"
  fl_up; tmux_set 0 ""; good 50; good 50; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/vazio: tmux que lista nada com rc 0 é 0 sessões (lido e vazio), e vale como leitura" "11264 dinamico 0 0 1" "$a"
  # tmux que NÃO EXECUTA (caminho que não existe = OSError, outro ramo que o rc ≠ 0 do tmux de brinquedo): é não-consegui-ler, nunca 0 sessões (0 liberaria RAM)
  fl_up; EXTRA_ENV="$EXTRA_ENV BALLAST_TMUX=$W/nao-existe/tmux"; good 50; good 50; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/sem leitura: tmux que não executa (OSError) é 'sem leitura', sessões null (nunca 0) e, com a janela cheia, nada começa" "14336 fixo-sem-leitura null null 0" "$a"
  # tmux TRAVADO (não responde dentro de BALLAST_TMUX_TIMEOUT_S): é não-consegui-ler, nunca 0 sessões; `exec sleep` para o timeout matar o próprio processo (um filho do sh seguraria o pipe)
  printf '#!/bin/sh\nexec sleep 20\n' > "$W/slow-tmux"; chmod +x "$W/slow-tmux"
  fl_up; EXTRA_ENV="$EXTRA_ENV BALLAST_TMUX=$W/slow-tmux BALLAST_TMUX_TIMEOUT_S=1"; good 50; good 50; good 50; good 50; good 50; a=$(fl_rec)
  check "piso/sem leitura: tmux que trava (passa do tempo limite) é 'sem leitura', sessões null (nunca 0) e, com a janela cheia, nada começa" "14336 fixo-sem-leitura null null 0" "$a"
  # o pico some do registro no tick em que o tmux não leu (a história guardada tem 2, mas este tick não sabe quantas sessões há): sess_peak null, nunca o pico velho
  fl_up; tmux_n 2; good 50; tmux_bad; good 50; a=$(fl_rec)
  check "piso/sem leitura: com 2 sessões na história, o tick em que o tmux não leu registra sess null e sess_peak null (não 2) e o piso FIXO" "14336 fixo-sem-leitura null null 0" "$a"
  # o mesmo com a chave ram-floor.fixed ligada: o ramo 'fixo-chave' é o único que devolve o pico ao registro, e com o tmux sem leitura ele também é null (não o 2 da história)
  fl_up; tmux_n 2; good 50; tmux_bad; : > "$H/ram-floor.fixed"; good 50; a=$(fl_rec)
  check "piso/sem leitura + chave: com 2 sessões na história, tmux sem leitura e ram-floor.fixed ligada, o registro tem 'fixo-chave', sess null e sess_peak null (não 2)" "14336 fixo-chave null null 0" "$a"
  # o balde guarda a MAIOR contagem: janela de 600 s = baldes de 50 s; 2 sessões e, 10-40 s depois no MESMO balde, 0 → o pico segue 2 até o fim da janela (a última contagem do balde não vale)
  fl_tk() { adv 50 0 "$1"; bt; }   # um tick $1 s depois, 50% de carga de sessões
  fl_up 600; tmux_n 2; fl_tk 10; tmux_none; fl_tk 10; fl_tk 10; fl_tk 10; fl_tk 560; a=$(fl_rec)
  check "piso/pico no mesmo balde: 2 sessões e 0 logo depois, no mesmo balde de 50 s, o balde guarda a MAIOR (2): com a janela de 600 s cheia o piso é 13312, não 11264" "13312 dinamico 0 2 0" "$a"

  # lacuna: sem leitura por mais que BALLAST_SESS_GAP_S (1800 s) a história não é contínua → recomeça o aquecimento (o pico que passou na lacuna ninguém viu)
  fl_up 300 11000; good 50; good 50; good 50; good 50; good 50; a=$(fl_rec); adv 50 0 2000; bt; b=$(fl_rec)
  check "piso/lacuna: com a janela cheia o piso é dinâmico (RAM 11000: nada começa)" "11264 dinamico 0 0 0" "$a"
  check "piso/lacuna: 2000 s sem tick (> 1800 s) → a história não é contínua e o piso volta ao FIXO (aquecendo)" "14336 fixo-aquecendo 0 0 0" "$b"

  # chave: ram-floor.fixed volta ao fixo de uma vez; sem o arquivo volta ao dinâmico
  fl_up 300 11000; good 50; good 50; good 50; good 50; good 50; : > "$H/ram-floor.fixed"; good 50; a=$(fl_rec); rm -f "$H/ram-floor.fixed"; good 50; b=$(fl_rec)
  check "piso/chave: com ram-floor.fixed o piso é o FIXO ('fixo-chave') mesmo com a janela cheia; apagado, volta ao dinâmico" "14336 fixo-chave 0 0 0|11264 dinamico 0 0 0" "$a|$b"

  fl_up 300 11000; good 50; good 50; good 50; good 50; good 50; ln -s ram-floor.fixed "$H/ram-floor.fixed"; good 50; a=$(fl_rec); rm -f "$H/ram-floor.fixed"
  check "piso/chave: ram-floor.fixed que não dá para ler (symlink em laço, ELOOP) vale como chave LIGADA (o lado conservador): piso fixo, nunca o dinâmico" "14336 fixo-chave 0 0 0" "$a"

  # elástico acompanha o piso: a descida por RAM é min(retomada + 1 GB, piso) e a subida usa o piso dinâmico
  el_fl() {  # el_fl — newhome + o item wam (2-6) rodando com janela de 300 s, 0 sessões; a CPU de sessões a 93% mantém os slots em 2 até o fim do aquecimento
    newhome; : > "$H/items.tsv"; printf '#!/bin/sh\nsleep 300\n' > "$H/items/wam.sh"; chmod +x "$H/items/wam.sh"; reg 'wam|work|2-6|1024|3600|300|-|wam.sh'
    EXTRA_ENV="BALLAST_SESS_WINDOW_S=300"; tmux_none; setpsi 1 1; seed; good 50; good 50; good 50; PID=$(started_pid); RUN=$(started_run); alive "$PID" wam "$RUN"
    eltick 93 0 28000; eltick 93 0 28000
  }
  el_fl; eltick 30 0 12000; a=$(slots_now); b=$(jget elastic.0.why)
  check "piso/elástico: com o piso dinâmico (11264) 12000 MB cabem 1 slot (12000 - 512 >= 11264) e a RAM NÃO manda descer (o piso de descida acompanha o de partida: min(13312, 11264))" "3 up" "$a $b"
  el_fl; eltick 30 0 12000; eltick 30 0 11200; a=$(slots_now); b=$(jget elastic.0.why)
  check "piso/elástico: abaixo do piso dinâmico (11200 < 11264) desce 2 por RAM (3 → 2, o mínimo)" "2 ram" "$a $b"
  el_fl; eltick 30 0 12000; eltick 30 0 11264; a=$(slots_now); b=$(jget elastic.0.why)
  check "piso/elástico: no piso exato (11264) fica (a descida é estritamente abaixo) e sem 512 MB sobrando não sobe" "3 sem-ram" "$a $b"
  # com o piso FIXO (tmux sem leitura) o elástico é o de antes: 12000 MB (< 13312) desce
  el_fl; tmux_bad; eltick 30 0 28000; eltick 30 0 28000; eltick 30 0 12000; a=$(slots_now); b=$(jget elastic.0.why)
  check "piso/elástico: com o piso FIXO (tmux sem leitura) a 12000 MB o elástico desce por RAM como antes (13312 de descida): de 6 slots vai a 4 (um passo de 2)" "4 ram" "$a $b"
}

# ── g_carry ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# SLOTS QUE ATRAVESSAM A RODADA (ga-03rqsr0). O wa-mutants acaba no prazo (3000 s), espera o cooldown (30 s se `parcial`) e recomeça nos 2 slots do MÍNIMO: a rampa de volta (+2 por minuto) deixava 1-2 núcleos de 12 parados por ~4-5 min a cada ~50 min
# (02:52-02:56Z de 10/11, idle_cores 12-14). O governo guarda em state.json o último limite de cada item elástico (n, época) e a rodada que recomeça dentro de BALLAST_SLOTS_CARRY_S (900 s) nasce com esse limite, menos o que a RAM não paga
# (cada slot novo, BALLAST_SLOT_MB; a conta do piso é a da partida). Fora da janela, com elastic.off ou sem o estado: o mínimo de sempre.
carry_one() {  # carry_one ESPERA_S MEM — el_one 2 6, sobe até 6, a rodada acaba (rc 0) e o item recomeça depois do pulo de ESPERA_S s (3 leituras livres); CR_RUN = a rodada nova (ou vazio), CR_SLOTS = o slots-file dela
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; eltick 30 0 28000
  gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; adv 50 0 60; bt
  adv 50 0 "$1"; setmem "$2"; bt; good 50; good 50; good 50
  CR_RUN=""; CR_SLOTS=""; [ "$(nstart)" = 0 ] || { CR_RUN=$(started_run); CR_SLOTS=$(cat "$H/runs/$CR_RUN/slots" 2> /dev/null | tr -d ' \n'); }
}
g_carry() {
  local a b
  carry_one 301 28000
  check "slots/carry: a rodada que recomeça 301 s depois da última escrita de slots (6) já nasce com 6, e o tick diz quantos slots deu" "6 6" "$CR_SLOTS $(jget started.0.slots)"
  carry_one 1000 28000
  check "slots/carry: passada a janela de 900 s (1000 s de pulo) volta ao mínimo (2): o limite velho não vale" "2 2" "$CR_SLOTS $(jget started.0.slots)"
  carry_one 301 15900
  check "slots/carry: a RAM paga só o que cabe: a 15900 MB (15900 - 1024 - 14336 = 540 MB) cabe 1 slot novo (512 MB) → 3, não 6" "3 3" "$CR_SLOTS $(jget started.0.slots)"
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000; eltick 30 0 28000; : > "$H/elastic.off"
  gone "$PID"; echo 0 > "$H/runs/$RUN/rc"; adv 50 0 60; bt; adv 50 0 301; bt; good 50; good 50; good 50; a=$(cat "$H/runs/$(started_run)/slots" 2> /dev/null | tr -d ' \n')
  check "slots/carry: com elastic.off o item recomeça no mínimo (2)" "2" "$a"
  # o limite guardado é o do ÚLTIMO tick elástico, com o carimbo desse tick (state.json: slots_last)
  el_one 2 6; eltick 30 0 28000; eltick 30 0 28000
  check "slots/carry: state.json guarda o último limite do item (6) e o carimbo do tick" "6 $NOW" "$("$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1]))["slots_last"]["wam"]; print(d["n"], d["t"])' "$H/state.json")"
  # estado de forma errada é estado corrompido (vai para o lado e recomeça), nunca limite inventado
  el_one 2 6; adv 50 0 60; printf '{"v": 1, "last": null, "free_ticks": 0, "cooldown": {}, "slots_last": {"wam": {"n": "seis", "t": 1}}}' > "$H/state.json"; bt
  check "slots/carry: slots_last de forma errada (n texto) corrompe o estado: o arquivo vai para o lado" "1" "$(ls "$H" | grep -c '^state.json.corrupt-')"
  adv 50 0 60; printf '{"v": 1, "last": null, "free_ticks": 0, "cooldown": {}, "sess": {"since": 1, "last": 2, "b": {"x": 1}}}' > "$H/state.json"; bt
  check "piso/estado: sess de forma errada (balde que não é número) corrompe o estado: o arquivo vai para o lado" "2" "$(ls "$H" | grep -c '^state.json.corrupt-')"
}

# ── g_startmb ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# START_MB (ga-03rqsr0): a conta de PARTIDA descontava de MemAvailable o teto do item (rss_mb), que é o que MATA, não o que o item usa. Medido no nó (results.jsonl desde 03/11, memory.peak do escopo, que ainda inclui cache de arquivo): hq-selftests
# pico máximo 1584 MB (p90 1482) com teto de 4096; hq-mutants 1048 (p90 1008) com teto de 3072; por isso os dois ficaram `skipped why=ram` em 38% e 26% dos ticks ao lado do wa-suite. A 9ª coluna OPCIONAL do registro, start_mb (1..rss_mb), é o que a partida
# desconta (ausente = rss_mb, como antes); o teto (rss_mb) continua sendo o que o governo aplica por minuto e o MemoryMax do escopo.
sm_home() {  # sm_home MEM — newhome com dois itens work de 2 núcleos, teto 4096 e start_mb 1024 (sm1 e sm2); a RAM dada
  newhome; : > "$H/items.tsv"; reg 'sm1|work|2|4096|3600|300|-|sleeper.sh|1024'; reg 'sm2|work|2|4096|3600|300|-|sleeper.sh|1024'; setmem "$1"; seed; good 50; good 50; good 50
}
g_startmb() {
  local a b
  sm_home 15400; a=$(nstart); b=$(jget skipped)
  check "start_mb: a 15400 MB (15400 - 1024 >= 14336) o sm1 começa mesmo com teto de 4096; o sm2 não cabe depois do desconto do sm1 (14376 - 1024 < 14336) e o tick diz que foi a RAM" "1 sm2" "$a $(jget skipped.0.item)"
  sm_home 15300; a=$(nstart)
  check "start_mb: a 15300 MB (15300 - 1024 < 14336) nenhum começa" "0" "$a"
  sm_home 16500; a=$(nstart)
  check "start_mb: a 16500 MB os dois cabem (o 2º desconta o 1º: 16500 - 1024 - 1024 >= 14336)" "2" "$a"
  sm_home 16300; a=$(nstart)
  check "start_mb: a 16300 MB só um (16300 - 1024 - 1024 = 14252 < 14336): o item planejado desconta o start_mb dele" "1" "$a"
  sm_home 15400; RUN=$(started_run)
  check "start_mb: a meta da rodada guarda o TETO (4096), que é o que mata e o que vai para o escopo; o start_mb não o rebaixa" "4096" "$("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["rss_mb"])' "$H/runs/$RUN/meta.json")"
  newhome; : > "$H/items.tsv"; reg 'a|work|2|4096|3600|300|-|sleeper.sh|700'; reg 'b|work|2|4096|3600|300|-|sleeper.sh'; reg 'c|work|2|4096|3600|300|-|sleeper.sh|0'; reg 'd|work|2|4096|3600|300|-|sleeper.sh|4097'; reg 'e|work|2|4096|3600|300|-|sleeper.sh|abc'
  reg 'f|work|2|4096|3600|300|-|sleeper.sh|1000|9'; reg 'g|work|2|4096|3600|300|-|sleeper.sh|4096'; bt status --json
  check "start_mb: o registro lê a 9ª coluna (700), ausente vale o teto (4096) e 4096 = teto vale; 0, 4097 (> teto), texto e uma 10ª coluna são 4 erros visíveis" "700 4096 4096 4" "$(jget items.0.start_mb) $(jget items.1.start_mb) $(jget items.2.start_mb) $(printf '%s' "$OUT" | "$PY" -I -c 'import sys,json; print(len(json.load(sys.stdin)["registry_errors"]))')"
}

if [ -n "${HB_MUTANT:-}" ]; then
  if [ "${HB_MUTANT_GROUPS:-}" = teto ]; then g_ceil; g_cgrp; elif [ "${HB_MUTANT_GROUPS:-}" = elastico ]; then g_elastic; elif [ "${HB_MUTANT_GROUPS:-}" = piso ]; then g_floor; g_carry; g_startmb; else g_reg; g_tick; g_run; g_ram; g_reap; g_fill; g_off; g_state; g_logs; g_launch; g_send; fi
  echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?
fi
if [ -n "${HB_ONLY:-}" ]; then "g_$HB_ONLY"; echo "── $((n - fails))/$n ok (só g_$HB_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_reg; g_tick; g_run; g_ram; g_reap; g_fill; g_off; g_state; g_logs; g_launch; g_send; g_ceil; g_cgrp; g_elastic; g_floor; g_carry; g_startmb

[ -n "${HB_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  # lista: DESCRIÇÃO@@ANTES@@DEPOIS (as âncoras podem ter várias linhas; trocam EXATAMENTE uma ocorrência numa cópia). [linux] = só vale onde há /proc/self/oom_score_adj.
  cat > "$T/mutants.txt" <<'MUT'
carga conta o tempo em nice (o lastro viraria carga)@@fg = (d[0] + d[2] + d[5] + d[6] + d[7]) / float(dt)@@fg = (d[0] + d[1] + d[2] + d[5] + d[6] + d[7]) / float(dt)
15% exatos deixa de contar como livre (> no lugar de >=)@@rec["free_pct"] >= cfg.idle_min_pct else 0@@rec["free_pct"] > cfg.idle_min_pct else 0
leitura abaixo de 15% não zera a conta@@st["free_ticks"] = st["free_ticks"] + 1 if rec["free_pct"] >= cfg.idle_min_pct else 0@@st["free_ticks"] = st["free_ticks"] + 1
começa na 1ª leitura livre (sem histerese)@@st["free_ticks"] >= cfg.idle_ticks:@@st["free_ticks"] >= 1:
orçamento sem a reserva de núcleos@@budget = int(ncpu - fg_net - cfg.reserve + 1e-9)@@budget = int(ncpu - fg_net + 1e-9)
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
sem rc vira ok@@why = (None if orph else killed) or hit or ("ok" if rc == 0 else@@why = (None if orph else killed) or hit or ("ok" if rc in (0, None) else
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
registro com coluna a menos aceito@@        if len(c) not in (8, 9):@@        if len(c) < 7:
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
            if mem_left - it["start_mb"] < floor:@@used + cores > budget:
                continue
            if mem_left < floor:
RAM de partida do filler ignora o teto de RSS do item@@fill_used + cores > budget):
                continue
            if mem_left - it["start_mb"] < floor:@@fill_used + cores > budget):
                continue
            if mem_left < floor:
stop não anota o motivo da rodada@@            st["killed"].setdefault(r["run"], "stop")@@            pass
rodada parada à mão ganha o cooldown de falha@@"preempt", "stop"):@@"preempt"):
cron.err cresce sem teto@@    trim_log(os.path.join(cfg.home, "cron.err"), 262144, 65536)@@    pass
ticks.jsonl cresce sem teto@@        if os.path.exists(path) and os.path.getsize(path) > cap:@@        if False:
quem levou TERM e ainda morre é recomeçado em cima@@        running_names = seen_names | {k["item"] for k in rec["killed"]}@@        running_names = {r["item"] for r in run.values()} | {k["item"] for k in rec["killed"]}
prefixo de lançamento inválido é aceito@@    if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):@@    if False:
prefixo sem nice aceito fora do selftest@@    if not test and "nice" not in v:@@    if False:
a RAM lida uma vez: o work planejado não desconta a sobra do seguinte@@            used += cores
            mem_left -= it["start_mb"]@@            used += cores
a RAM lida uma vez: o filler começado não desconta a sobra do seguinte@@                mem_left -= it["start_mb"]@@                pass
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
a rodada limpa de órfãos fecha como orfaos e não pelo rc do item (ganharia o cooldown de falha)@@why = (None if orph else killed) or hit or (@@why = killed or hit or (
a linha da rodada não diz que houve órfãos@@        row["orfaos"] = True@@        pass
[teto] sem o barramento do usuário o item começa assim mesmo (o teto some quando não há gerenciador)@@    if not os.path.exists(bus):@@    if False:
[teto] sem systemd-run no PATH o item começa assim mesmo@@    if shutil.which("systemd-run") is None:@@    if False:
[teto] sem teto pronto o tick não bloqueia o começo de itens (a nota sem-teto não trava)@@"primeira-leitura", "lacuna", "sem-teto")@@"primeira-leitura", "lacuna")
[teto] o systemd-run não leva TasksMax@@"-p", "TasksMax=%d" % cfg.tasks_max,@@
[teto] o systemd-run não leva MemoryMax@@"-p", "MemoryMax=%dM" % mem_cap_mb(cfg, item),@@
[teto] o systemd-run não leva MemorySwapMax=0@@"-p", "MemorySwapMax=0",@@
[teto] OOMPolicy=kill mata o item inteiro e leva o rc e os picos junto@@"-p", "OOMPolicy=continue"@@"-p", "OOMPolicy=kill"
[teto] o MemoryMax ignora o fator (rss_mb cru)@@    return int(math.ceil(item["rss_mb"] * cfg.mem_factor * scale))@@    return int(item["rss_mb"])
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
[teto] sem linger o item começa assim mesmo (só o barramento decide)@@    if lg == "no":@@    if False:
[teto] linger que não consegui ler vira pronto@@    if lg != "yes":@@    if False:
[teto] a pasta do linger sem o arquivo do usuário vira 'não consegui ler' (outro motivo)@@        return "no", path@@        return "ilegivel", path
[teto] uma pasta no lugar do arquivo de linger conta como linger ligado@@    if not stat.S_ISREG(st.st_mode):@@    if False:
[teto] erro de stat do linger (ENOTDIR, permissão) conta como linger ligado@@        return "ilegivel", "%s: %s" % (path, e)@@        return "yes", path
[teto] o status não traz o bloco ceiling@@"ceiling": {"mode": cfg.ceiling, "ready": ceil_ok@@"ceilingX": {"mode": cfg.ceiling, "ready": ceil_ok
[teto-linux] o item não escreve o cgroup dele (o governo não sabe onde ler)@@'[ -z "$BALLAST_CEILING_ON" ] || { { cut -d: -f3@@'[ -n "$BALLAST_CEILING_ON" ] || { { cut -d: -f3
[teto-linux] o relatório do item perde o fork recusado@@sed -n "s/^max /pids_hits /p" $c/pids.events;@@
[teto-linux] o relatório do item perde o oom_kill@@sed -n "s/^oom_kill /oom_kill /p" $c/memory.events;@@
[teto-linux] o relatório do item perde o pico de memória@@echo "mem_peak $(cat $c/memory.peak)";@@
[teto-linux] o stop não manda kill ao cgroup de cada rodada aberta (o escapee de setsid sobrevive)@@        if cgroup_kill(cfg, rn) == "unknown" and (read_meta(cfg, rn) or {}).get("ceiling"):@@        if False:
[teto] o stop não avisa quando o cgroup.kill de uma rodada com teto não saiu (cgroup_unverified)@@        if cgroup_kill(cfg, rn) == "unknown" and (read_meta(cfg, rn) or {}).get("ceiling"):@@        if cgroup_kill(cfg, rn) == "x" and (read_meta(cfg, rn) or {}).get("ceiling"):
[teto] escopo que já sumiu (nada a matar) conta como kill não confirmado@@            return "gone"@@            return "unknown"
[teto] cgroup.kill que o kernel recusou conta como escopo vazio@@        except OSError:
            pass
        return "unknown"@@        except OSError:
            pass
        return "gone"
[teto] caminho do cgroup ilegível conta como escopo vazio (nada a matar)@@    if d is None:
        return "unknown"@@    if d is None:
        return "gone"
[elastico] o registro N-M aceita N >= M@@                if not 1 <= ncores < cmax or role != "work":@@                if not 1 <= ncores <= cmax or role != "work":
[elastico] o registro N-M aceita N 0@@                if not 1 <= ncores < cmax or role != "work":@@                if not 0 <= ncores < cmax or role != "work":
[elastico] filler elástico é aceito@@                if not 1 <= ncores < cmax or role != "work":@@                if not 1 <= ncores < cmax:
[elastico] o escopo do item elástico tem o teto do mínimo (não escala pelo máximo)@@    scale = item["cores_max"] / float(item["cores"]) if item.get("cores_max") else 1.0@@    scale = 1.0
[elastico] o item elástico não recebe o máximo@@        env["BALLAST_CORES_MAX"] = str(item["cores_max"])@@        env["BALLAST_CORES_MAX"] = str(cores)
[elastico] o arquivo de slots começa em outro valor que o mínimo@@        write_slots(cfg, run, cores if slots is None else slots)@@        write_slots(cfg, run, item["cores_max"])
[elastico] a meta não guarda o máximo@@    if item.get("cores_max"):
        meta["cores_max"] = item["cores_max"]@@    if item.get("cores_max"):
        pass
[elastico] a gravação do slots-file não é atômica e perde o novo valor (grava no tmp e não troca)@@        os.replace(tmp, path)
        return True@@        return True
[elastico] a leitura ruim (CPU/RAM/ilegível) vale como 'tudo livre' e o limite sobe@@    if mem is None or not ok or room is None:
        return cur, "leitura"@@    if mem is None or not ok or room is None:
        room, mem = 99.0, 99999
[elastico] RAM baixa não devolve slots@@    if mem < min(cfg.ram_resume_mb + 1024, floor):@@    if False:
[elastico] o piso de descida por RAM é o de retomada (sem o 1 GB de margem)@@    if mem < min(cfg.ram_resume_mb + 1024, floor):@@    if mem < min(cfg.ram_resume_mb, floor):
[elastico] RAM baixa desce 1 em vez do passo@@        return max(lo, cur - cfg.elastic_step), "ram"@@        return max(lo, cur - 1), "ram"
[elastico] RAM baixa desce abaixo do mínimo@@        return max(lo, cur - cfg.elastic_step), "ram"@@        return cur - cfg.elastic_step, "ram"
[elastico] a pressão de disco acima do teto não desce@@    if io is not None and io > cfg.io_full_max:@@    if False:
[elastico] o teto de disco é inclusivo (25 desce)@@    if io is not None and io > cfg.io_full_max:@@    if io is not None and io >= cfg.io_full_max:
[elastico] CPU saturada (menos de 1 núcleo ocioso) não desce@@    if room < 0:@@    if False:
[elastico] CPU saturada desce o passo todo e não 1@@        return max(lo, cur - 1), "cpu"@@        return max(lo, cur - cfg.elastic_step), "cpu"
[elastico] sobe mesmo sem folga de CPU (a fronteira de 2 núcleos além da reserva some)@@ or room < cfg.elastic_room:@@ or room < 0:
[elastico] a fronteira da CPU é exclusiva (>= vira >)@@ or room < cfg.elastic_room:@@ or room <= cfg.elastic_room:
[elastico] sobe com PSI que não veio (disco 'calmo' por falta de leitura)@@    if st["paused"] or io is None or io > cfg.io_full_max / 2.0 or room < cfg.elastic_room:@@    if st["paused"] or (io or 0.0) > cfg.io_full_max / 2.0 or room < cfg.elastic_room:
[elastico] sobe com o disco sob pressão moderada (acima de metade do teto)@@ or io > cfg.io_full_max / 2.0 or@@ or io > cfg.io_full_max or
[elastico] a metade do teto de disco é exclusiva (12,5 não sobe)@@ or io > cfg.io_full_max / 2.0 or@@ or io >= cfg.io_full_max / 2.0 or
[elastico] sobe com o item pausado por RAM@@    if st["paused"] or io is None@@    if io is None
[elastico] sobe sem limite no máximo@@    if cur >= hi:
        return cur, "max"@@    if False:
        return cur, "max"
[elastico] sobe sem olhar a RAM que sobra (sem os 512 MB por slot)@@    k = min(cfg.elastic_step, hi - cur, int((mem - floor) // cfg.slot_mb))@@    k = min(cfg.elastic_step, hi - cur)
[elastico] sobe 1 só em vez do passo@@    k = min(cfg.elastic_step, hi - cur, int((mem - floor) // cfg.slot_mb))@@    k = min(1, hi - cur, int((mem - floor) // cfg.slot_mb))
[elastico] a chave elastic.off não faz nada@@    off = os.path.exists(os.path.join(cfg.home, "elastic.off"))@@    off = False
[elastico] a chave elastic.off derruba só 1 e não ao mínimo@@        want, why = (lo, "chave") if off else@@        want, why = (max(lo, cur - 1), "chave") if off else
[elastico] arquivo de slots ilegível vale o máximo (e não o mínimo)@@        return lo, False
    return (n, True) if lo <= n <= hi else (lo, False)@@        return hi, False
    return (n, True) if lo <= n <= hi else (lo, False)
[elastico] arquivo de slots fora de lo..hi vale como está@@    return (n, True) if lo <= n <= hi else (lo, False)@@    return (n, True)
[elastico] o arquivo de slots ilegível não é reescrito@@        if want != cur or not known:@@        if want != cur:
[elastico] o teto de RSS não acompanha os slots@@                cap = cap * read_slots_file(cfg, r["run"], m["cores"], m["cores_max"])[0] // m["cores"]@@                cap = cap
[elastico] o teto de RSS escala pelo máximo e não pelos slots dados@@                cap = cap * read_slots_file(cfg, r["run"], m["cores"], m["cores_max"])[0] // m["cores"]@@                cap = cap * m["cores_max"] // m["cores"]
[elastico] a leitura do PSI aceita só a linha some (full ausente vira 0)@@    if set(out) != {"some", "full"} or not all(math.isfinite(x) for x in out.values()):
        raise Unreadable("pressure/io: sem as linhas some e full legíveis")
    return out["some"], out["full"]@@    if "some" not in out:
        raise Unreadable("pressure/io: sem as linhas some e full legíveis")
    return out["some"], out.get("full", 0.0)
[elastico] a leitura do PSI aceita NaN (a comparação com NaN dá falso: disco 'calmo')@@    if set(out) != {"some", "full"} or not all(math.isfinite(x) for x in out.values()):@@    if set(out) != {"some", "full"}:
[elastico] o passo do ambiente não vale (fixo em 2)@@        elastic_step=_num(env, "BALLAST_ELASTIC_STEP", 2, int, 1)@@        elastic_step=2
[elastico] o mínimo do passo aceita 0@@"BALLAST_ELASTIC_STEP", 2, int, 1)@@"BALLAST_ELASTIC_STEP", 2, int, 0)
[elastico] o mínimo de MB por slot aceita 0@@"BALLAST_SLOT_MB", 512, int, 1)@@"BALLAST_SLOT_MB", 512, int, 0)
[elastico] o teto de disco negativo é aceito@@"BALLAST_IO_FULL_MAX", 25.0, float, 0.0)@@"BALLAST_IO_FULL_MAX", 25.0, float, -5.0)
[elastico] o fg líquido não é usado no orçamento@@        budget = int(ncpu - fg_net - cfg.reserve + 1e-9)@@        budget = int(ncpu - rec["fg_cores"] - cfg.reserve + 1e-9)
[elastico] a correção de fg vira soma (o kernel do lastro AUMENTA o fg)@@            fg_net = max(0.0, fg_net - bg_sys)@@            fg_net = fg_net + bg_sys
[elastico] o fg líquido pode ficar negativo@@            fg_net = max(0.0, fg_net - bg_sys)@@            fg_net = fg_net - bg_sys
[elastico] a 1ª leitura (sem baseline) já corrige@@    if prev is None or not 0 < cfg.now - prev["t"] <= cfg.gap_s:
        return None@@    if prev is None:
        prev = {"t": cfg.now - 60, "runs": {}}
[elastico] a baseline velha (lacuna) ainda corrige@@    if prev is None or not 0 < cfg.now - prev["t"] <= cfg.gap_s:@@    if prev is None or not 0 < cfg.now - prev["t"]:
[elastico] o contador que anda para trás vira correção@@        if pu is None or u < pu:@@        if pu is None:
[elastico] o delta do kernel é dividido por outro tempo (1 s fixo)@@        tot += (u - pu) / 1e6 / (cfg.now - prev["t"])@@        tot += (u - pu) / 1e6
[elastico] cpu.stat sem a chave ou ilegível vale 0 (o delta cheio vira correção)@@    return None


def read_cpu_prev(cfg):@@    return 0


def read_cpu_prev(cfg):
[elastico] o cpu.prev de forma errada vale como baseline@@    if not (isinstance(d, dict) and _int(d.get("t")) and isinstance(d.get("runs"), dict) and all(isinstance(k, str) and _int(v) for k, v in d["runs"].items())):
        return None@@    if not isinstance(d, dict):
        return None
[elastico] o cpu.prev que nem é JSON derruba o tick@@            d = json.load(f)
    except (OSError, ValueError, RecursionError):
        return None
    if not (isinstance(d, dict) and _int(d.get("t"))@@            d = json.load(f)
    except (OSError, RecursionError):
        return None
    if not (isinstance(d, dict) and _int(d.get("t"))
[elastico] a rodada parcial não encurta o cooldown@@        cool = min(cool, cfg.partial_cooldown_s)@@        pass
[elastico] a rodada parcial curta (infra) também encurta@@ and row["secs"] >= cfg.partial_min_s and@@ and True and
[elastico] o mínimo de 600 s da rodada parcial é exclusivo (600 s não encurta)@@ and row["secs"] >= cfg.partial_min_s and@@ and row["secs"] > cfg.partial_min_s and
[elastico] só o `parcial` de rc 0 conta mas a falha também encurta@@    if why == "ok" and _int(row["secs"])@@    if _int(row["secs"])
[elastico] o cooldown do parcial encurta para 0 em vez do ambiente@@        cool = min(cool, cfg.partial_cooldown_s)@@        cool = 0
[elastico] o resumo completo também encurta o cooldown@@ and summ.get("result") == "parcial":@@ and summ.get("result"):
[piso] o piso dinâmico ignora o pico de sessões (conta 0)@@cfg.ram_pause_mb + cfg.sess_margin_mb + peak * cfg.sess_mb@@cfg.ram_pause_mb + cfg.sess_margin_mb + 0 * cfg.sess_mb
[piso] o piso dinâmico passa do fixo (sem o teto)@@return min(cfg.ram_start_mb, cfg.ram_pause_mb + cfg.sess_margin_mb + peak * cfg.sess_mb), "dinamico", peak@@return cfg.ram_pause_mb + cfg.sess_margin_mb + peak * cfg.sess_mb, "dinamico", peak
[piso] o piso dinâmico perde a margem (pausa + sessões)@@cfg.ram_pause_mb + cfg.sess_margin_mb + peak * cfg.sess_mb@@cfg.ram_pause_mb + peak * cfg.sess_mb
[piso] o piso dinâmico conta 512 MB por sessão em vez de usar BALLAST_SESS_MB@@cfg.ram_pause_mb + cfg.sess_margin_mb + peak * cfg.sess_mb@@cfg.ram_pause_mb + cfg.sess_margin_mb + peak * 512
[piso] o aquecimento é ignorado (dinâmico com 1 leitura só)@@    if peak is None or cfg.now - s["since"] < cfg.sess_window_s:@@    if peak is None:
[piso] o aquecimento conta uma leitura a menos (a janela cheia é exclusiva)@@cfg.now - s["since"] < cfg.sess_window_s:@@cfg.now - s["since"] <= cfg.sess_window_s:
[piso] tmux que não leu vira 0 sessões@@    except Unreadable:
        n_sess = None@@    except Unreadable:
        n_sess = 0
[piso] o tmux que não lê não deixa o histórico quieto (anota 0)@@    if n is None:
        return
    s = st.get("sess")@@    if n is None:
        n = 0
    s = st.get("sess")
[piso] erro do tmux que não é 'sem servidor' vira 0 sessões@@    raise Unreadable("tmux list-sessions: rc %d (%s)" % (p.returncode, out.strip()[:120]))@@    return 0
[piso] 'sem servidor' deixa de ser 0 sessões (vira não consegui ler)@@    if "no server running" in out or ("error connecting to" in out and "(No such file or directory)" in out):@@    if False:
[piso] saída do tmux sem linha conta como 1 sessão@@        return len([ln for ln in out.splitlines() if ln.strip()])@@        return len(out.splitlines()) or 1
[piso] o tmux que não executa é 0 sessões@@        raise Unreadable("tmux list-sessions: não executou (%s)" % e)@@        return 0
[piso] a lacuna de leituras não recomeça a história@@    if not s or cfg.now < s["last"] or cfg.now - s["last"] > cfg.sess_gap_s:@@    if not s:
[piso] o tmux travado é 0 sessões@@        raise Unreadable("tmux list-sessions: passou de %d s" % cfg.tmux_timeout_s)@@        return 0
[piso] o balde guarda a última contagem e não a maior@@    s["b"][k] = max(s["b"].get(k, 0), n)@@    s["b"][k] = n
[piso] o histórico nunca esquece (sem a poda dos baldes velhos)@@    s["b"] = {b: v for b, v in s["b"].items() if int(b) >= lo}@@    s["b"] = s["b"]
[piso] o pico aparece mesmo quando o tmux não leu neste tick@@    peak = max(s["b"].values()) if (n is not None and s and s["b"]) else None@@    peak = max(s["b"].values()) if (s and s["b"]) else None
[piso] a chave ram-floor.fixed é ignorada@@    if flag_on(os.path.join(cfg.home, "ram-floor.fixed")):@@    if False:
[piso] chave que não consigo ler vale como desligada (o lado que libera RAM)@@    except OSError:
        return True@@    except OSError:
        return False
[piso] sem leitura o piso usa o dinâmico de antes@@    if n is None:
        return cfg.ram_start_mb, "fixo-sem-leitura", None@@    if False:
        return cfg.ram_start_mb, "fixo-sem-leitura", None
[piso] os slots guardados não são atualizados a cada tick@@        st["slots_last"][r["item"]] = {"n": want, "t": cfg.now}@@        pass
[piso] o limite guardado vale para sempre (sem a janela de 900 s)@@or not 0 <= cfg.now - last["t"] <= cfg.slots_carry_s:@@or False:
[piso] o carry ignora elastic.off@@ or not last or flag_on(os.path.join(cfg.home, "elastic.off")) or not 0 <=@@ or not last or not 0 <=
[piso] o carry ignora o que a RAM paga@@    extra = max(0, int((mem_left - item["start_mb"] - floor) // cfg.slot_mb))@@    extra = 99
[piso] o carry começa sempre no máximo do item@@    return max(cores, min(last["n"], item["cores_max"], cores + extra))@@    return item["cores_max"]
[piso] o item elástico começa no mínimo mesmo com o limite guardado@@        write_slots(cfg, run, cores if slots is None else slots)@@        write_slots(cfg, run, cores)
[piso] o tick não diz quantos slots deu ao item que começou@@        out["slots"] = cores if slots is None else slots@@        pass
[piso] a descida por RAM do elástico ignora o piso dinâmico (retomada + 1 GB fixo)@@    if mem < min(cfg.ram_resume_mb + 1024, floor):@@    if mem < cfg.ram_resume_mb + 1024:
[piso] o elástico sobe pelo piso FIXO e não pelo do tick@@int((mem - floor) // cfg.slot_mb))@@int((mem - cfg.ram_start_mb) // cfg.slot_mb))
[piso] a partida do work usa o piso fixo e não o do tick@@            if mem_left - it["start_mb"] < floor:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append(@@            if mem_left - it["rss_mb"] < cfg.ram_start_mb:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append(
[piso] o estado aceita balde que não é número@@and all(isinstance(k, str) and k.isdigit() and _int(v) and v >= 0 for k, v in sess["b"].items())@@and all(isinstance(k, str) and _int(v) and v >= 0 for k, v in sess["b"].items())
[piso] o estado aceita slots_last de n texto@@isinstance(v, dict) and _int(v.get("n")) and v["n"] >= 1 and _int(v.get("t"))@@isinstance(v, dict)
[piso] a conta de partida do work volta a descontar o teto e não o start_mb@@            if mem_left - it["start_mb"] < floor:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append(@@            if mem_left - it["rss_mb"] < floor:
                rec["skipped"].append({"item": it["name"], "why": "ram"})
                rec["ram"] = "baixa"
                continue
            plan.append(
[piso] o item planejado não desconta o start_mb de mem_left@@            used += cores
            mem_left -= it["start_mb"]@@            used += cores
            pass
[piso] a 9ª coluna do registro é ignorada (start_mb sempre o teto)@@            start_mb = int(c[8]) if len(c) == 9 else rss_mb@@            start_mb = rss_mb
[piso] start_mb acima do teto é aceito@@            if not 1 <= start_mb <= rss_mb:@@            if not 1 <= start_mb:
[piso] start_mb 0 é aceito@@            if not 1 <= start_mb <= rss_mb:@@            if not 0 <= start_mb <= rss_mb:
[piso] uma 10ª coluna é aceita@@        if len(c) not in (8, 9):@@        if len(c) not in (8, 9, 10):
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
    grp=""; case "$desc" in "[teto]"*|"[teto-linux]"*) grp=teto ;; "[elastico]"*) grp=elastico ;; "[piso]"*) grp=piso ;; esac
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
