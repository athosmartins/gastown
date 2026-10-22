#!/usr/bin/env bash
# hetzner-capacity.selftest.sh — hermético (ga-2hd02v.1.11): o "nó" é um script que devolve o que o caso mandar, o list-running é outro, o relógio é HETZNER_CAPACITY_NOW,
# e a cidade é uma pasta de fixtures. Nada fala com host nenhum e nada toca em .gc/ de verdade.
#
# Contents
#   Casos · Controle negativo (mutantes) · Variáveis
#
# CASOS
#   medição (g_read): CPU livre é o MENOR entre o ocioso da amostra e 1-load5/núcleos · ssh que não conecta = unreachable, que estoura o prazo = unreachable ·
#     resposta sem o marcador de fim, sem MemAvailable ou com as duas amostras iguais = unreadable e a cor é `unknown` (NÃO vermelha: RAM que falta ler não é RAM 0%) ·
#     ruído antes do marcador é ignorado · list-running que falha deixa sessões null (não 0) · `read` e `status` não gravam nada nem chamam o ssh.
#   degraus (g_step): sobe 1→3→6→10 sem pular, só com janela + leituras + todas verdes + prova de carga · amarela, vermelha e ilegível na janela seguram ·
#     desce um degrau com 2 vermelhas SEGUIDAS e a mesma evidência não desce de novo (sem cascata) · ilegível entre duas vermelhas segura · último degrau não passa ·
#     refresh_s respeitado · set-ceiling só aceita degrau e registra · estado corrompido vai para o lado e recomeça no menor · estado ilegível NÃO recomeça ·
#     config com chave desconhecida é erro · lock ocupado = lê o cache e não grava.
#   veredito (g_verdict): nó com vaga · nó cheio no degrau · o MENOR entre degrau e cap do provider · pausa · liberação ausente · gate_done_bin nulo / não executável /
#     config do atalho ausente · nó fora (MINI) × leitura ilegível (NÃO SEI) · quente (MINI) · amarelo ainda autoriza · leitura velha ou no futuro com lock ocupado · sessões ilegíveis ·
#     pause.json que não dá para olhar não é "sem pausa" · exit 0/1/2.
#   terceiro estado (g_third, ga-5yp4n1): load5 `nan`/`inf` é leitura ilegível (não some do min() nem vira CPU 0) · leitura "ok" no state.json com CPU/RAM não numérica
#     ou ausente é NÃO SEI (rc 2, sem traceback), nunca NÓ · (gate 1) arquivo que não se lê como JSON UTF-8 (bytes `\xff`, aninhado fundo demais, sem changed_why) não derruba
#     a ferramenta: state.json é posto de lado com alarme e `step` cura (rc 0), `status` erra com rc 3, config.json/session-ssh.json/remote-shim.json viram NÃO SEI (rc 2) e
#     `pause` erra (rc 3) sem gravar · exceção inesperada: verdict → NÃO SEI `internal` (rc 2), outros → rc 3 (o traceback do Python sairia 1 = MINI) · ssh que não executa é
#     NÃO SEI (ferramenta quebrada), não MINI (nó fora) · gate_done_bin relativo é MINI (o atalho recusa).
#   sessão ocupada × ociosa (g_idle, ga-2hd02v.1.22): 3 dog-remote vivas SEM bead in_progress no alias = o nó TEM vaga (NÓ free_slot) · 3 COM bead = node_full · mistas contam
#     só as com bead · a bead no nome da sessão também vale · bead de outro dono e a sem dono não contam · TERCEIRO ESTADO: bd ou gc que falha / devolve lixo / não-lista / vazio
#     = todas as sessões contam OCUPADAS (node_full, com o motivo em idle_why), nunca "ociosas" · `[]` lido = ninguém trabalha = vaga · sessão sem alias, fora da lista do gc,
#     gate-reviewer / wa-worker / dog-remote-adhoc contam ocupadas · a prova de carga do degrau é de sessão OCUPADA (dog ocioso não faz o teto subir) ·
#     TERCEIRO ESTADO na prova de carga: leitura em que o gc ou o bd falhou / estourou o prazo (idle_why com motivo, sessions = total vivo contado ocupado) e a gravada antes da separação
#     (sem idle_why) NÃO provam carga — nem vetam: uma leitura que falhou no meio de leituras ocupadas lidas ainda deixa subir ·
#     PRAZO: gc e bd correm em PARALELO (o custo é o maior prazo, não a soma: o gc leva 10-21 s no mini carregado e o Pilot dá 40 s ao veredito inteiro) · estourar o prazo
#     de qualquer um é ilegível (ocupadas, motivo 'prazo') · HETZNER_CAPACITY_READ_TIMEOUT_S só encurta o prazo e o valor inválido cai no padrão.
#   encher o nó (g_fill, ga-2hd02v.2; sem config.json = os padrões de verdade — os outros grupos fixam a política ANTIGA no config.json da cidade de teste, em `LEGACY`, para provar o
#     mecanismo com números explícitos): padrões (10% livre para subir, 3% = quente, janela de 480 s com 3 leituras, só a RAM desce) · a escada sobe 1→3→6→10 em 27 min no ritmo do job
#     (180 s) e o relógio curto NÃO dispensa a prova de carga · 12,5% livre é verde, 6% âmbar, 2% vermelho · veredito autoriza com 4% livre e barra com 2% · CPU em 2% livre por 10 leituras
#     (carga externa) NÃO derruba o degrau, o veredito é node_hot enquanto dura e volta a NÓ com as vagas todas na leitura seguinte · a RAM < 20% desce com 2 leituras seguidas (falha no
#     meio quebra a sequência) · cpu_lowers_ceiling=true devolve a regra antiga e valor que não é bool é NÃO SEI · o plist agenda `step` a cada 180 s e o ciclo cabe em refresh_s / max_age_s.
#   CPU por hora (g_hourly, ga-2hd02v.2): média = 100 - ocioso por hora cheia UTC, só as horas COMPLETAS · hora sem leitura é sem_leitura (rc 1), nunca 0% nem ok · leitura que falhou fica
#     fora da média e entra em falhas · linha ruim é contada e pulada · lê o readings.jsonl.1 · arquivo que não abre é erro (rc 3), não "sem leitura" · --hours / --min-pct inválidos = rc 3.
# CONTROLE NEGATIVO: ilegível contado como verde · sem prova de carga · degrau que pula · evidência que vale duas vezes · `present()` que engole erro · veredito sem o
#   gate_done · cap ignorado · `>` no lugar de `>=` na vaga · sessões ilegíveis viram 0 · leitura velha autoriza · leitura sem `state` válida · leitura no futuro autoriza ·
#   vermelho só com CPU E RAM · âmbar vira verde · `max` no lugar de `min` na CPU · estado ilegível recomeça · falha de ssh vira leitura ok · load5 `nan` aceito ·
#   leitura "ok" de cor desconhecida autoriza · state.json não-UTF-8 / aninhado fundo / sem changed_why não tratados · config.json não-UTF-8 · config de fora aninhada ·
#   sem catch-all · catch-all que sai 1 · ssh que não executa vira nó fora · gate_done_bin relativo aceito · (ga-2hd02v.1.22) rc≠0 do gc/bd ignorado · leitura que falhou conta ociosa ·
#   bead de qualquer dono / só a primeira bead / saída não-lista vira "ninguém trabalha" · sessão sem alias, gate-reviewer / wa-worker e dog-remote-adhoc contam ociosas ·
#   bead no nome da sessão não vale · o veredito conta todas as vivas · sessão fantasma sem dog-remote · leituras em sequência · prazo estourado vira lista vazia ·
#   prazo de teste que alonga o padrão · prazo inválido/<=0 vira quase zero · prova de carga que aceita leitura com idle_why com motivo / sem idle_why — cada um é aplicado numa cópia e a bateria TEM que falhar.
#   (ga-2hd02v.2) a CPU cheia derruba o degrau · decide() volta à regra antiga · a RAM não derruba · leitura que falhou/âmbar desce · padrões de volta (35%, 1800 s, 10%, cpu_lowers_ceiling) ·
#   bool não validado · hourly: hora sem leitura como ok, falha na média, hora parcial, arquivo que não abre como vazio, linha ruim que derruba, linha sem t, --min-pct ignorado, rc 0 sempre, .1 não lido.
# VARIÁVEIS: HC_UNDER_TEST (script a testar) · HC_PY (interpretador; padrão /usr/bin/python3 = o 3.9 do mini) · HC_NO_MUTANTS=1 · HC_ONLY=<grupo> (só g_<grupo>: read, step, verdict, third, idle, bg, fill, hourly; sem mutantes)
#   HC_MGROUPS (uso interno do `mutant`: quais grupos a cópia mutada roda; vazio = todos)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${HC_UNDER_TEST:-$HERE/hetzner-capacity.py}"
PY="${HC_PY:-/usr/bin/python3}"
T=$(cd "$(mktemp -d /tmp/hc.XXXXXX)" && pwd -P)
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null; }
trap cleanup EXIT
fails=0; n=0
ok() {  # ok RC DESCRIÇÃO — no modo mutante, a primeira falha encerra (só interessa se a bateria reprova)
  n=$((n+1))
  if [ "$1" = 0 ]; then [ -n "${HC_MUTANT:-}" ] || echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -z "${HC_MUTANT:-}" ] || { echo "RESULT $fails/$n"; exit 1; }; fi
}
T0=1800000000
W="$T/w"; mkdir -p "$W"
SSHJ="$W/session-ssh.json"; SHIM="$W/remote-shim.json"; GDB="$W/gate-done-bin"
printf '#!/bin/sh\nexit 0\n' > "$GDB"; chmod +x "$GDB"

# o "nó": consome o script de entrada e devolve $W/ssh.out (ou falha com $W/ssh.rc); conta as chamadas
cat > "$W/ssh-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
cat >/dev/null
echo x >> "$W/ssh.calls"
[ -f "$W/ssh.sleep" ] && sleep "$(cat "$W/ssh.sleep")"
[ -f "$W/claude.started" ] && : > "$W/ssh.sawclaude"      # o gate do Claude já tinha começado enquanto a medição do nó ainda corria?
if [ -f "$W/ssh.rc" ] && [ "$(cat "$W/ssh.rc")" != 0 ]; then echo "ssh: connect to host stub port 22: Connection timed out" >&2; exit "$(cat "$W/ssh.rc")"; fi
cat "$W/ssh.out"
EOF
cat > "$W/list-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
if [ -f "$W/list.rc" ] && [ "$(cat "$W/list.rc")" != 0 ]; then echo "provider: ssh falhou" >&2; exit "$(cat "$W/list.rc")"; fi
i=0; while [ "$i" -lt "$(cat "$W/sessions" 2>/dev/null || echo 0)" ]; do echo "dog-remote-s$i"; i=$((i+1)); done
[ -f "$W/list.extra" ] && cat "$W/list.extra"
exit 0
EOF
# `gc session list --json` (ga-2hd02v.1.22): a sessão dog-remote-s<i> do nó tem o alias dog-remote-<i+1>; gcl.skip = sessões que o gc NÃO lista; gcl.noalias = sessões sem alias; gcl.raw = a saída crua; gcl.sleep = segundos de demora
cat > "$W/gcl-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
[ -f "$W/gcl.sleep" ] && sleep "$(cat "$W/gcl.sleep")"
if [ -f "$W/gcl.rc" ] && [ "$(cat "$W/gcl.rc")" != 0 ]; then echo '{"sessions":[]}'; echo "gc: dolt fora" >&2; exit "$(cat "$W/gcl.rc")"; fi
[ -f "$W/gcl.raw" ] && { cat "$W/gcl.raw"; exit 0; }
printf '{"sessions":['
i=0; sep=""
while [ "$i" -lt "$(cat "$W/sessions" 2>/dev/null || echo 0)" ]; do
  if ! grep -qx "dog-remote-s$i" "$W/gcl.skip" 2>/dev/null; then
    a="dog-remote-$((i+1))"; grep -qx "dog-remote-s$i" "$W/gcl.noalias" 2>/dev/null && a=""
    printf '%s{"session_name":"dog-remote-s%s","alias":"%s","template":"dog-remote","state":"active","closed":false}' "$sep" "$i" "$a"; sep=","
  fi
  i=$((i+1))
done
for x in $(cat "$W/list.extra" 2>/dev/null); do   # as sessões extras do nó (gate-reviewer, wa-worker, dog-remote-adhoc) o gc lista com alias = o próprio nome
  printf '%s{"session_name":"%s","alias":"%s","template":"x","state":"active","closed":false}' "$sep" "$x" "$x"; sep=","
done
printf '%s{"session_name":"mayor","alias":"mayor","template":"mayor","state":"active","closed":false}]}\n' "$sep"
EOF
# `bd list --status in_progress --json`: busy = "all" (toda sessão do nó tem bead), "none" ou os números dos aliases que têm; sempre traz uma bead de OUTRO dono (ruído que não pode contar); bd.raw = a saída crua; bd.sleep = segundos de demora
cat > "$W/bd-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
[ -f "$W/bd.sleep" ] && sleep "$(cat "$W/bd.sleep")"
if [ -f "$W/bd.rc" ] && [ "$(cat "$W/bd.rc")" != 0 ]; then echo '[]'; echo "bd: dolt fora" >&2; exit "$(cat "$W/bd.rc")"; fi
[ -f "$W/bd.raw" ] && { cat "$W/bd.raw"; exit 0; }
n=$(cat "$W/sessions" 2>/dev/null || echo 0); b=$(cat "$W/busy" 2>/dev/null || echo all)
if [ "$b" = all ]; then b=""; i=1; while [ "$i" -le "$n" ]; do b="$b $i"; i=$((i+1)); done; fi
printf '['
for k in $b; do [ "$b" = none ] && break; printf '{"id":"ga-b%s","status":"in_progress","assignee":"dog-remote-%s"},' "$k" "$k"; done
printf '{"id":"ga-x","status":"in_progress","assignee":"gastown.dog-2"},{"id":"ga-y","status":"in_progress"}]\n'
EOF
# o `hetzner-claude.py gate` (ga-2hd02v.7): devolve $W/claude.out com a saída $W/claude.rc; claude.sleep = segundos de demora; conta as chamadas e marca que começou
cat > "$W/claude-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
echo x >> "$W/claude.calls"; : > "$W/claude.started"
[ -f "$W/claude.sleep" ] && sleep "$(cat "$W/claude.sleep")"
cat "$W/claude.out"
exit "$(cat "$W/claude.rc")"
EOF
# o provider (`gc-session-ssh <op> <nome>`, ga-0k82lw): get-last-activity imprime $W/act.<nome> (act.rc≠0 = falha; sem o arquivo = não imprime nada); stop anota em stop.calls, falha com stop.rc
# e tira o nome de list.extra (a não ser que stop.keep exista: o stop diz ok e a tmux continua)
cat > "$W/prov-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
case "$1" in
  get-last-activity) if [ -f "$W/act.rc" ] && [ "$(cat "$W/act.rc")" != 0 ]; then echo "provider: ssh falhou" >&2; exit "$(cat "$W/act.rc")"; fi
                     [ -f "$W/act.$2" ] && cat "$W/act.$2"; exit 0;;
  stop) echo "$2" >> "$W/stop.calls"
        if [ -f "$W/stop.rc" ] && [ "$(cat "$W/stop.rc")" != 0 ]; then echo "provider: stop falhou" >&2; exit "$(cat "$W/stop.rc")"; fi
        [ -f "$W/stop.keep" ] || { grep -vx "$2" "$W/list.extra" > "$W/list.extra.new"; mv "$W/list.extra.new" "$W/list.extra"; }
        exit 0;;
esac
exit 2
EOF
# `bd show <id> --json` de uma bead de SESSÃO: o status vem de $W/show.<id> (sem o arquivo a bead não existe: rc 1); show.raw = a saída crua
cat > "$W/show-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
[ -f "$W/show.raw" ] && { cat "$W/show.raw"; exit 0; }
[ -f "$W/show.$1" ] || { echo "bd: no issue found matching $1" >&2; exit 1; }
printf '[{"id":"%s","status":"%s","issue_type":"session"}]\n' "$1" "$(cat "$W/show.$1")"
EOF
chmod +x "$W/ssh-stub" "$W/list-stub" "$W/gcl-stub" "$W/bd-stub" "$W/claude-stub" "$W/prov-stub" "$W/show-stub"

node() {  # node IDLE_PCT LOAD5 MEM_AVAIL_PCT  → resposta do nó com 16 núcleos, 32 GB, entre os marcadores (e com ruído de .bashrc antes)
  local idle="$1" load="$2" mem="$3" d=$(( $1 * 10 ))
  { echo "Welcome to the stub (ruído de .bashrc)"; echo "@@CAP-BEGIN@@"; echo "ncpu=16"
    echo "stat1=cpu  1000 0 0 1000 0 0 0 0 0 0"; echo "stat2=cpu  $((1000 + 1000 - d)) 0 0 $((1000 + d)) 0 0 0 0 0 0"
    echo "load=0.5 $load 1.0 1/100 12345"
    echo "MemTotal:       32000000 kB"; echo "MemAvailable:   $(( mem * 320000 )) kB"
    echo "@@CAP-END@@"; } > "$W/ssh.out"; rm -f "$W/ssh.rc"
}
sess() { echo "$1" > "$W/sessions"; rm -f "$W/list.rc"; }
node_bg() {  # node_bg USER NICE IDLE LOAD5 MEM_PCT — deltas em jiffies das duas amostras (USER+NICE+IDLE = 2000 = 16 núcleos x 125); a 2ª coluna do /proc/stat é o tempo em nice > 0
  local u="$1" ni="$2" id="$3" load="$4" mem="$5"
  { echo "@@CAP-BEGIN@@"; echo "ncpu=16"
    echo "stat1=cpu  1000 1000 0 1000 0 0 0 0 0 0"; echo "stat2=cpu  $((1000 + u)) $((1000 + ni)) 0 $((1000 + id)) 0 0 0 0 0 0"
    echo "load=0.5 $load 1.0 1/100 12345"
    echo "MemTotal:       32000000 kB"; echo "MemAvailable:   $(( mem * 320000 )) kB"
    echo "@@CAP-END@@"; } > "$W/ssh.out"; rm -f "$W/ssh.rc"
}
busy() { echo "$*" > "$W/busy"; }      # busy all | none | N N… (números dos aliases dog-remote-N com bead in_progress)
mkcfg() {  # mkcfg CAP [released]
  printf '{"default_host":"hetzner","hosts":{"hetzner":{"ssh":"stub","cap":%s,"remote_root":"/r","remote_home":"/h"%s}}}\n' "$1" "${2-,\"real_sessions_released_by\":\"mayor teste\"}" > "$SSHJ"
}
mkshim() { printf '{"city":"/c","gate_done_bin":%s}\n' "${1-\"$GDB\"}" > "$SHIM"; }
RT=""      # RT=N → HETZNER_CAPACITY_READ_TIMEOUT_S=N (encurta o prazo das leituras de gc/bd e do gate do Claude); newcity zera
CC=""      # CC = HETZNER_CAPACITY_CLAUDE_CMD (o comando do gate do Claude); newcity põe o claude-stub, que um caso pode trocar
gate_says() { printf '%s\n' "$2" > "$W/claude.out"; echo "$1" > "$W/claude.rc"; }      # gate_says SAÍDA LINHA — o que o gate do Claude falso devolve (LINHA vazia = saída sem texto)
# A política ANTIGA (ga-2hd02v.1.11: verde com 35% livre, 6 leituras em 1800 s, CPU também desce o degrau) fica FIXADA no config.json da cidade de teste: os grupos de mecanismo
# (g_read, g_step, g_verdict, g_third, g_idle) provam o ciclo, o veredito e o terceiro estado com números explícitos, não com os padrões. Os padrões da meta de encher o nó
# (ga-2hd02v.2) são do g_fill / g_hourly, que usam `fillcity` (sem config.json).
LEGACY='"cpu_up_headroom_pct":35,"cpu_down_headroom_pct":10,"up_window_s":1800,"up_min_reads":6,"cpu_lowers_ceiling":true'
newcity() { RT=""; CC="[\"$W/claude-stub\"]"; D="$T/d.$((++nd))"; mkdir -p "$D"; printf '{%s}\n' "$LEGACY" > "$D/config.json"; mkcfg 10; mkshim; node 70 3 90; sess 3; busy all; rm -f "$W/ssh.calls" "$W/ssh.sleep" "$W/list.rc" "$W/list.extra" "$W"/gcl.* "$W"/bd.* "$W/claude.calls" "$W/claude.sleep" "$W/claude.started" "$W/ssh.sawclaude"; gate_says 0 ok; NOW=$T0; }
fillcity() { newcity; rm -f "$D/config.json"; }
nd=0
hc() {  # hc ARGS → $OUT (stdout), $RC
  OUT=$(HETZNER_CAPACITY_DIR="$D" GC_SSH_CONFIG="$SSHJ" HETZNER_CAPACITY_SHIM_CONFIG="$SHIM" HETZNER_CAPACITY_NOW="$NOW" \
        HETZNER_CAPACITY_SSH_CMD="[\"$W/ssh-stub\"]" HETZNER_CAPACITY_LIST_CMD="[\"$W/list-stub\"]" \
        HETZNER_CAPACITY_SESSIONS_CMD="[\"$W/gcl-stub\"]" HETZNER_CAPACITY_BEADS_CMD="[\"$W/bd-stub\"]" HETZNER_CAPACITY_CLAUDE_CMD="$CC" HETZNER_CAPACITY_READ_TIMEOUT_S="$RT" \
        HETZNER_CAPACITY_PROVIDER_CMD="${PCMD:-[\"$W/prov-stub\"]}" HETZNER_CAPACITY_SHOW_CMD="[\"$W/show-stub\"]" "$PY" -I "$P" "$@" 2>"$W/err"); RC=$?
}
at() { NOW=$((T0 + $1)); }
jget() {  # jget CAMPO.PONTADO → valor do $OUT (JSON), texto simples; null/ausente → "null"
  printf '%s' "$OUT" | "$PY" -I -c 'import sys,json
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else json.dumps(v))' "$1" 2>/dev/null
}
check() {  # check "DESCRIÇÃO" ESPERADO REAL
  if [ "$2" = "$3" ]; then ok 0 "$1"; else ok 1 "$1 (esperado '$2', veio '$3')"; fi
}
calls() { [ -f "$W/ssh.calls" ] && wc -l < "$W/ssh.calls" | tr -d ' ' || echo 0; }
ceil() { hc --json status; jget ceiling; }
series() {  # series DE ATÉ PASSO (segundos) — um `step` a cada passo
  local t="$1"; while [ "$t" -le "$2" ]; do at "$t"; hc --json step; t=$((t + $3)); done
}

g_read() {
  newcity
  node 60 4 90; hc --json read
  check "read: nó verde → rc 0, ok, CPU livre = ocioso (60 < 75 pela carga)" "0 ok 60.0" "$RC $(jget state) $(jget cpu_headroom_pct)"
  check "read: RAM disponível em % e sessões lidas do provider" "90.0 3" "$(jget mem_avail_pct) $(jget sessions)"
  node 80 12 90; hc --json read
  check "read: carga sustentada pesa mais que a amostra (idle 80, load5 12/16 → 25)" "25.0" "$(jget cpu_headroom_pct)"
  check "read: cor amarela entre os limites (CPU 25 < 35, > 10; RAM 90)" "amber" "$(jget color)"
  node 5 3 90; hc --json read; check "read: CPU 5% livre → vermelho" "red" "$(jget color)"
  node 70 3 15; hc --json read; check "read: RAM 15% → vermelho (o nó não tem swap)" "red" "$(jget color)"
  echo 255 > "$W/ssh.rc"; hc --json read
  check "read: ssh que não conecta → rc 1, unreachable, sessões não contadas" "1 unreachable null" "$RC $(jget state) $(jget sessions)"
  check "read: unreachable é cor unknown, não vermelha" "unknown" "$(jget color)"
  node 70 3 90; echo 2 > "$W/ssh.sleep"; printf '{"ssh_timeout_s":1}' > "$D/config.json"; hc --json read
  check "read: prazo estourado → unreachable (não trava a varredura)" "1 unreachable" "$RC $(jget state)"
  rm -f "$W/ssh.sleep" "$D/config.json"
  node 70 3 90; sed -i.bak '/@@CAP-END@@/d' "$W/ssh.out"; hc --json read
  check "read: resposta sem o marcador de fim → unreadable, nunca 'lista vazia'" "1 unreadable unknown" "$RC $(jget state) $(jget color)"
  node 70 3 90; sed -i.bak '/MemAvailable/d' "$W/ssh.out"; hc --json read
  check "read: sem MemAvailable → unreadable e cor unknown (NÃO vermelha)" "unreadable unknown" "$(jget state) $(jget color)"
  node 70 3 90; sed -i.bak 's/^stat2=.*/stat2=cpu  1000 0 0 1000 0 0 0 0 0 0/' "$W/ssh.out"; hc --json read
  check "read: duas amostras iguais (dt=0) → unreadable" "unreadable" "$(jget state)"
  node 70 3 90; sess 3; echo 1 > "$W/list.rc"; hc --json read
  check "read: list-running falhou → sessions null (NÃO 0), nó segue ok" "ok null" "$(jget state) $(jget sessions)"
  rm -f "$W/list.rc"; sess 0; hc --json read; check "read: list-running vazio com rc 0 → 0 sessões" "0" "$(jget sessions)"
  newcity; node 70 3 90; sess 1; before=$(cd "$D" && ls -A | tr '\n' ' '); hc --json read; hc --json status
  check "read/status: não criam arquivo nenhum na pasta de estado" "$before" "$(cd "$D" && ls -A | tr '\n' ' ')"
  check "status: sem ssh (a chamada do read acima foi a única)" "1" "$(calls)"
}

g_step() {
  newcity; sess 1; node 70 3 90
  series 0 1500 300
  check "step: 1500 s ainda no degrau 1 (a janela é de 1800 s)" "1" "$(ceil)"
  at 1800; hc --json step; check "step: 1800 s, 6 leituras verdes e o nó aguentou 1 sessão → sobe para 3" "3" "$(jget ceiling)"
  check "step: a mudança fica em events.jsonl (1 → 3, com o motivo)" "1" "$(grep '"event": "ceiling"' "$D/events.jsonl" | grep '"from": 1,' | grep '"to": 3' | grep -c 'leituras verdes')"
  sess 3; series 2100 3300 300; check "step: não pula: 1200 s depois do 3 ainda é 3" "3" "$(ceil)"
  at 3600; hc --json step; check "step: 3 → 6 (nunca 3 → 10)" "6" "$(jget ceiling)"
  sess 6; series 3900 5400 300; check "step: 6 → 10 só depois da janela cheia" "10" "$(ceil)"
  series 5700 9000 300; check "step: no último degrau não passa" "10" "$(ceil)"

  newcity; sess 0; node 70 3 90; series 0 2400 300
  check "step: nó verde mas NUNCA com sessões >= degrau → não sobe (prova de carga)" "1" "$(ceil)"
  hc --json status; check "status: diz que falta a prova de carga" "1" "$(printf '%s' "$OUT" | grep -c 'prova de carga')"
  printf '{"require_load_proof":false,%s}' "$LEGACY" > "$D/config.json"; at 2700; hc --json step
  check "step: require_load_proof=false dispensa a prova" "3" "$(jget ceiling)"

  newcity; sess 1; node 70 3 90; series 0 600 300; node 70 3 30; at 900; hc --json step
  node 70 3 90; series 1200 2400 300
  check "step: UMA leitura âmbar (RAM 30%) na janela segura a subida" "1" "$(ceil)"
  at 2700; hc --json step; check "step: a âmbar de 900 s ainda está na borda da janela em 2700 s (inclusive) → segura" "1" "$(jget ceiling)"
  at 3000; hc --json step; check "step: depois que a âmbar sai da janela (1800 s), sobe" "3" "$(jget ceiling)"

  newcity; sess 1; node 70 3 90; series 0 600 300; echo 255 > "$W/ssh.rc"; at 900; hc --json step; node 70 3 90
  series 1200 2400 300
  check "step: UMA leitura que falhou (ssh) na janela também segura: falha não é verde" "1" "$(ceil)"

  newcity; sess 6; node 70 3 90; hc --json set-ceiling 6 --reason "teste"; check "set-ceiling: degrau da lista aceito" "0 6" "$RC $(ceil)"
  hc --json set-ceiling 4 --reason "não é degrau"; check "set-ceiling: 4 não é degrau → rc 3 e nada muda" "3 6" "$RC $(ceil)"
  check "set-ceiling: fica em events.jsonl com o motivo" "1" "$(grep -c 'manual: teste' "$D/events.jsonl")"
  node 3 3 90; at 120; hc --json step; check "step: 1 vermelha não desce" "6" "$(jget ceiling)"
  at 180; hc --json step; check "step: 2 vermelhas seguidas descem UM degrau (6 → 3)" "3" "$(jget ceiling)"
  at 240; hc --json step; check "step: a 3ª vermelha NÃO desce de novo (a evidência do degrau 6 não vale no 3)" "3" "$(jget ceiling)"
  at 300; hc --json step; check "step: 2 vermelhas novas, agora no degrau 3 → 1" "1" "$(jget ceiling)"
  at 420; hc --json step; at 480; hc --json step; check "step: no degrau 1 não desce mais" "1" "$(jget ceiling)"

  newcity; sess 3; hc --json set-ceiling 3 --reason t; node 3 3 90; at 120; hc --json step
  echo 255 > "$W/ssh.rc"; at 180; hc --json step; node 3 3 90; at 240; hc --json step
  check "step: vermelha, FALHOU, vermelha → não desce (falha não é vermelha; não são seguidas)" "3" "$(jget ceiling)"

  newcity; sess 3; hc --json set-ceiling 3 --reason t; node 70 3 90; at 120; hc --json step; at 150; hc --json step
  check "step: refresh_s=60: 2º step dentro de 60 s não mede de novo" "1 false" "$(calls) $(jget refreshed)"

  newcity; hc --json step; echo '{"ceiling": "x"' > "$D/state.json"; at 600; hc --json step
  check "estado corrompido: posto de lado e recomeça no menor, com alarme" "1 1 1" "$(jget ceiling) $(ls "$D" | grep -c 'state.json.corrupt-') $(grep -c '"event": "alarm"' "$D/events.jsonl")"
  newcity; printf '{"v":1,"ceiling":3,"changed_at":%s,"changed_why":"x","readings":[{"t":%s}]}' "$T0" "$((T0 + 590))" > "$D/state.json"; sess 0; at 600; hc --json verdict
  check "estado com leitura SEM 'state' (adulterado): tratado como corrompido, o veredito não quebra" "1 1 1" "$(ls "$D" | grep -c 'state.json.corrupt-') $(printf '%s' "$OUT" | grep -c '"verdict"') $(jget ceiling)"
  newcity; hc --json step; chmod 000 "$D/state.json"; at 600; hc --json step
  check "estado que existe mas NÃO abre: erro (rc 3), nada é reiniciado" "3" "$RC"
  chmod 600 "$D/state.json"; hc --json verdict; chmod 000 "$D/state.json"; hc --json verdict
  check "estado que não abre: veredito é NÃO SEI (rc 2), não 'nó'" "2 unknown" "$RC $(jget verdict)"
  chmod 600 "$D/state.json"

  newcity; printf '{"steps":[1,3],"degrau_novo":5}' > "$D/config.json"; hc --json step
  check "config: chave desconhecida → step rc 3" "3" "$RC"; hc --json verdict
  check "config: chave desconhecida → veredito NÃO SEI (rc 2, motivo config)" "2 config" "$RC $(jget reason)"
  printf '{"steps":[3,1]}' > "$D/config.json"; hc --json verdict; check "config: degraus fora de ordem → NÃO SEI" "2" "$RC"
  printf '{"cpu_up_headroom_pct":10,"cpu_down_headroom_pct":10}' > "$D/config.json"; hc --json verdict; check "config: sem faixa âmbar (subir = descer) → NÃO SEI" "2" "$RC"
  printf '{"refresh_s":600,"max_age_s":300}' > "$D/config.json"; hc --json verdict; check "config: max_age_s <= refresh_s → NÃO SEI" "2" "$RC"
  rm -f "$D/config.json"

  newcity; sess 1; hc --json step; at 70
  ( "$PY" -I -c 'import fcntl,sys,time
f=open(sys.argv[1],"a+"); fcntl.flock(f,2); print("held",flush=True); time.sleep(5)' "$D/lock" > "$W/held" ) &
  hp=$!; for _ in $(seq 1 50); do [ -s "$W/held" ] && break; sleep 0.1; done
  c0=$(calls); sum0=$(cksum < "$D/state.json"); hc --json step
  check "lock ocupado por outro ciclo: não mede, não grava, lê o cache" "false false $c0 $sum0" "$(jget locked) $(jget refreshed) $(calls) $(cksum < "$D/state.json")"
  wait "$hp" 2>/dev/null
}

g_verdict() {
  newcity; sess 0; node 70 3 90; at 10
  hc --json verdict; check "veredito: nó verde, 0 sessões, degrau 1 → NÓ (rc 0)" "0 node free_slot" "$RC $(jget verdict) $(jget reason)"
  check "veredito: traz teto efetivo, ativas e livres" "1 0 1" "$(jget effective) $(jget active) $(jget free)"
  sess 1; at 100; hc --json verdict; check "veredito: 1 sessão no degrau 1 → MINI, nó cheio (rc 1)" "1 local node_full" "$RC $(jget verdict) $(jget reason)"
  newcity; sess 2; hc --json set-ceiling 6 --reason t; mkcfg 2; at 70; hc --json verdict
  check "veredito: degrau 6 mas cap do provider 2 → vale o MENOR: 2 sessões = cheio" "local node_full 2" "$(jget verdict) $(jget reason) $(jget effective)"
  mkcfg 3; at 140; hc --json verdict; check "veredito: cap 3, 2 sessões → NÓ (a vaga é a diferença para o menor)" "node 3 1" "$(jget verdict) $(jget effective) $(jget free)"

  newcity; sess 0; at 10; hc --json pause --reason "janela do engine"; hc --json verdict
  check "veredito: pausa → MINI paused, mesmo com tudo verde" "1 paused" "$RC $(jget reason)"
  hc --json resume; at 100; hc --json verdict; check "veredito: resume → NÓ" "0 node" "$RC $(jget verdict)"

  newcity; sess 0; mkcfg 10 ""; at 10; hc --json verdict; check "veredito: host sem real_sessions_released_by → MINI not_released" "1 not_released" "$RC $(jget reason)"
  mkcfg 10 ',"real_sessions_released_by":"   "'; at 100; hc --json verdict; check "veredito: liberação só com espaços → MINI" "not_released" "$(jget reason)"
  rm -f "$SSHJ"; at 200; hc --json verdict; check "veredito: config do provider ausente → NÃO SEI (rc 2)" "2 unknown provider_config" "$RC $(jget verdict) $(jget reason)"
  printf '{"hosts":{"hetzner":{"ssh":"stub"}}}' > "$SSHJ"; at 300; hc --json verdict; check "veredito: host sem cap → NÃO SEI" "provider_config" "$(jget reason)"
  newcity; sess 0; mkshim null; at 10; hc --json verdict; check "veredito: gate_done_bin nulo → MINI gate_done_off (bead no nó não chega ao gate)" "1 gate_done_off" "$RC $(jget reason)"
  mkshim "\"$W/nao-existe\""; at 100; hc --json verdict; check "veredito: gate_done_bin aponta para o que não existe → MINI gate_done_not_exec" "gate_done_not_exec" "$(jget reason)"
  printf 'x' > "$W/not-exec"; mkshim "\"$W/not-exec\""; at 200; hc --json verdict; check "veredito: arquivo sem permissão de execução → MINI" "gate_done_not_exec" "$(jget reason)"
  rm -f "$SHIM"; at 300; hc --json verdict; check "veredito: config do atalho ausente → NÃO SEI (rc 2), não 'liberado'" "2 shim_config" "$RC $(jget reason)"

  newcity; sess 0; hc --json step; echo 255 > "$W/ssh.rc"; at 100; hc --json verdict
  check "veredito: leitura boa antes, ssh fora agora → MINI node_down (vale a ÚLTIMA leitura)" "1 local node_down" "$RC $(jget verdict) $(jget reason)"
  node 70 3 90; sed -i.bak '/@@CAP-END@@/d' "$W/ssh.out"; at 200; hc --json verdict; check "veredito: leitura ilegível → NÃO SEI (rc 2)" "2 reading_unreadable" "$RC $(jget reason)"
  node 3 3 90; at 300; hc --json verdict; check "veredito: nó quente (CPU 3%) → MINI node_hot" "1 node_hot" "$RC $(jget reason)"
  node 80 12 90; at 400; hc --json verdict; check "veredito: faixa âmbar ainda autoriza (CPU 25%, RAM 90%)" "0 node" "$RC $(jget verdict)"
  node 70 3 90; echo 1 > "$W/list.rc"; at 500; hc --json verdict; check "veredito: sessões ilegíveis → NÃO SEI" "2 sessions_unreadable" "$RC $(jget reason)"

  newcity; sess 0; hc --json step; at 1000
  ( "$PY" -I -c 'import fcntl,sys,time
f=open(sys.argv[1],"a+"); fcntl.flock(f,2); print("held",flush=True); time.sleep(5)' "$D/lock" > "$W/held" ) &
  hp=$!; for _ in $(seq 1 50); do [ -s "$W/held" ] && break; sleep 0.1; done
  hc --json verdict; check "veredito: leitura de 1000 s (> 900) e ninguém para refazer (lock ocupado) → NÃO SEI reading_stale" "2 reading_stale" "$RC $(jget reason)"
  wait "$hp" 2>/dev/null

  newcity; sess 0; at 5000; hc --json step; at 0
  ( "$PY" -I -c 'import fcntl,sys,time
f=open(sys.argv[1],"a+"); fcntl.flock(f,2); print("held",flush=True); time.sleep(5)' "$D/lock" > "$W/held" ) &
  hp=$!; for _ in $(seq 1 50); do [ -s "$W/held" ] && break; sleep 0.1; done
  hc --json verdict; check "veredito: leitura carimbada 5000 s no FUTURO (relógio voltou) e sem como refazer → NÃO SEI reading_future" "2 reading_future" "$RC $(jget reason)"
  wait "$hp" 2>/dev/null

  # present() de verdade: um diretório sem permissão de busca faz o lstat falhar com PermissionError, que NÃO pode virar "não existe"
  mkdir -p "$W/sem-x"; : > "$W/sem-x/pause.json"; chmod 000 "$W/sem-x"
  r=$("$PY" -I -c 'import importlib.util,sys
spec=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try: print("devolveu", m.present(sys.argv[2]))
except OSError as e: print("levantou", type(e).__name__)' "$P" "$W/sem-x/pause.json")
  chmod 755 "$W/sem-x"
  check "present(): erro de permissão LEVANTA (não vira 'não existe')" "levantou PermissionError" "$r"
  r=$("$PY" -I -c 'import importlib.util,sys
spec=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.present(sys.argv[2]), m.present(sys.argv[3]))' "$P" "$W/sem-x/pause.json" "$W/nao-tem")
  check "present(): arquivo que existe → True, que não existe → False" "True False" "$r"
}

g_third() {  # leitura que PARECE ok e não é (ga-5yp4n1): medição ilegível = MINI/NÃO SEI, nunca NÓ
  newcity
  node 70 nan 90; hc --json read
  check "read: load5 'nan' → unreadable e cor unknown (a carga não some calada do min())" "1 unreadable unknown" "$RC $(jget state) $(jget color)"
  node 70 inf 90; hc --json read
  check "read: load5 'inf' → unreadable (não vira 'ok' com CPU 0)" "1 unreadable unknown" "$RC $(jget state) $(jget color)"
  # o state.json só é escrito por esta ferramenta, mas se vier adulterado o veredito não pode ler "ok" onde falta número
  newcity; sess 0; at 10
  printf '{"v":1,"ceiling":1,"changed_at":%s,"changed_why":"x","readings":[{"t":%s,"state":"ok","sessions":0,"cpu_headroom_pct":"abc","mem_avail_pct":"xyz"}]}' "$T0" "$((T0 + 5))" > "$D/state.json"
  hc --json verdict
  check "veredito: leitura 'ok' com CPU/RAM não numéricas → NÃO SEI (rc 2), nunca NÓ" "2 reading_unreadable" "$RC $(jget reason)"
  printf '{"v":1,"ceiling":1,"changed_at":%s,"changed_why":"x","readings":[{"t":%s,"state":"ok","sessions":0}]}' "$T0" "$((T0 + 5))" > "$D/state.json"
  hc --json verdict
  check "veredito: leitura 'ok' sem CPU/RAM → NÃO SEI (rc 2), sem traceback" "2 reading_unreadable 0" "$RC $(jget reason) $(grep -c Traceback "$W/err")"
  # gate 1 (ga-5yp4n1): arquivo que não se lê como JSON UTF-8 não pode derrubar a ferramenta — o crash sai com rc 1, o código do MINI conhecido
  newcity; sess 0; hc --json step; printf '\xff\xfe{garbage' > "$D/state.json"; at 100; hc --json verdict
  check "state.json com bytes não-UTF-8: posto de lado com alarme e o veredito sai (antes: traceback, rc 1 = MINI sem motivo)" "1 1 0 1" \
    "$(ls "$D" | grep -c 'state.json.corrupt-') $(grep -c '"event": "alarm"' "$D/events.jsonl") $(grep -c Traceback "$W/err") $(printf '%s' "$OUT" | grep -c '"verdict"')"
  printf '\xff' > "$D/state.json"; at 200; hc --json step; check "step com state.json não-UTF-8: rc 0 (cura sozinho; o contrato é 0 ou 3)" "0" "$RC"
  printf '\xff' > "$D/state.json"; hc --json status; check "status com state.json não-UTF-8: erro rc 3 sem gravar, sem traceback" "3 0" "$RC $(grep -c Traceback "$W/err")"
  "$PY" -c "print('['*200000)" > "$D/state.json"; at 300; hc --json step
  check "state.json aninhado fundo demais (RecursionError, não é ValueError): posto de lado como o JSON ruim" "0 0" "$RC $(grep -c Traceback "$W/err")"
  newcity; printf '{"v":1,"ceiling":1,"changed_at":%s,"readings":[]}' "$T0" > "$D/state.json"; at 400; hc --json step
  check "state.json sem changed_why (o status indexa): é corrompido, não válido" "1" "$(ls "$D" | grep -c 'state.json.corrupt-')"
  newcity; printf '{"steps":[1,3]}\xff' > "$D/config.json"; hc --json verdict
  check "config.json com byte não-UTF-8: NÃO SEI (rc 2, motivo config), sem traceback" "2 config 0" "$RC $(jget reason) $(grep -c Traceback "$W/err")"
  hc --json pause --reason x; check "config.json não-UTF-8: pause é erro (rc 3) e NÃO grava pause.json" "3 0" "$RC $(ls "$D" | grep -c '^pause.json')"
  "$PY" -c "print('['*200000)" > "$D/config.json"; hc --json verdict; check "config.json aninhado fundo demais: NÃO SEI config" "2 config" "$RC $(jget reason)"
  # rede de segurança: bug que ninguém previu no caminho do veredito. Sem ela o Python sai com 1 = MINI; com ela, NÃO SEI (2) / erro (3)
  newcity
  r=$(HETZNER_CAPACITY_DIR="$D" GC_SSH_CONFIG="$SSHJ" "$PY" -I -c 'import importlib.util,sys,json,io,contextlib
spec=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def boom(*a, **k): raise RuntimeError("bug futuro")
m.tick=boom
b=io.StringIO()
with contextlib.redirect_stdout(b): rc1=m.main(["--json","verdict"])
with contextlib.redirect_stderr(io.StringIO()): rc2=m.main(["--json","step"])
v=json.loads(b.getvalue()); print(rc1, v["verdict"], v["reason"], rc2)' "$P" 2>&1 | tail -1)
  check "exceção inesperada: verdict → NÃO SEI interno (rc 2), step → rc 3; nunca o rc 1 do MINI" "2 unknown internal 3" "$r"
  # ssh que não executa é ferramenta quebrada (NÃO SEI), não "nó fora" (MINI node_down)
  newcity; chmod -x "$W/ssh-stub"; hc --json verdict; r="$RC $(jget reason)"; chmod +x "$W/ssh-stub"
  check "ssh sem permissão de execução (PermissionError): NÃO SEI reading_unreadable, não MINI node_down" "2 reading_unreadable" "$r"
  # o atalho recusa a config inteira se gate_done_bin não for absoluto; o oráculo não pode autorizar o nó com um caminho que só existe a partir do cwd
  newcity; sess 0; mkshim '"gate-done-bin"'; cd "$W" || return; hc --json verdict; cd "$OLDPWD" || return
  check "gate_done_bin relativo (existe a partir do cwd): MINI gate_done_not_exec, não NÓ" "1 gate_done_not_exec" "$RC $(jget reason)"
  # as configs de fora (provider, atalho) também vêm de arquivo: bytes não-UTF-8 ou aninhado fundo demais é NÃO SEI com o motivo certo, não traceback (rc 1 = MINI)
  newcity; printf '\xff' > "$SSHJ"; hc --json verdict
  check "session-ssh.json não-UTF-8: NÃO SEI provider_config, sem traceback" "2 provider_config 0" "$RC $(jget reason) $(grep -c Traceback "$W/err")"
  newcity; "$PY" -c "print('['*200000)" > "$SHIM"; hc --json verdict
  check "remote-shim.json aninhado fundo demais: NÃO SEI shim_config, sem traceback" "2 shim_config 0" "$RC $(jget reason) $(grep -c Traceback "$W/err")"
}

# ga-2hd02v.1.22: sessão VIVA não é sessão OCUPADA. dog-remote sem bead in_progress no alias é vaga; o que não dá para provar ocioso (bead ilegível, gc ilegível, sem alias, não é dog-remote) conta como ocupado.
g_idle() {
  idle_city() { newcity; sess 3; hc --json set-ceiling 3 --reason t; busy "$1"; at 70; }
  idle_city none; hc --json verdict
  check "ocioso: 3 sessões dog-remote vivas SEM bead → NÓ com vaga (rc 0), não nó cheio" "0 node free_slot" "$RC $(jget verdict) $(jget reason)"
  check "ocioso: ocupadas 0 de teto 3 → 3 livres" "0 3" "$(jget active) $(jget free)"
  check "ocioso: a leitura separa total, ocupadas e ociosas" "3 0 3" "$(jget reading.sessions_total) $(jget reading.sessions) $(jget reading.sessions_idle)"
  busy all; at 140; hc --json verdict
  check "ocupado: 3 sessões COM bead in_progress no alias → MINI node_full (rc 1)" "1 local node_full 3" "$RC $(jget verdict) $(jget reason) $(jget active)"
  busy 2; at 210; hc --json verdict
  check "misto: só dog-remote-2 tem bead → NÓ, 1 ocupada e 2 livres" "node 1 2" "$(jget verdict) $(jget active) $(jget free)"
  busy 1 2; at 280; hc --json verdict
  check "misto: duas com bead, uma ociosa → NÓ com 1 vaga (o teto é 3)" "node 2 1" "$(jget verdict) $(jget active) $(jget free)"
  busy s0; at 350; hc --json verdict
  check "bead atribuída ao NOME da sessão (não ao alias) também a torna ocupada" "node 1 2" "$(jget verdict) $(jget active) $(jget free)"
  # a bead de OUTRO dono (e a sem dono) está em todas as respostas do stub: só o alias exato da sessão prova que ela trabalha
  busy none; at 420; hc --json verdict
  check "bead in_progress de outro dono não torna a sessão ocupada" "node 0" "$(jget verdict) $(jget active)"

  # TERCEIRO ESTADO: bead ilegível NÃO é "sem bead". Falhou → a sessão conta como ocupada (nunca enche o nó além do teto)
  idle_city none; echo 1 > "$W/bd.rc"; hc --json verdict
  check "bd falhou: 3 sessões contam OCUPADAS → MINI node_full (nunca 'ociosas')" "1 local node_full 3" "$RC $(jget verdict) $(jget reason) $(jget active)"
  check "bd falhou: o motivo fica na leitura (idle_why) e a total segue 3" "yes 3" "$([ -n "$(jget reading.idle_why)" ] && [ "$(jget reading.idle_why)" != null ] && echo yes || echo no) $(jget reading.sessions_total)"
  rm -f "$W/bd.rc"
  for raw in 'isto nao e json' '{"a":1}' '[1,2]' '[{"assignee":7}]' ''; do
    idle_city none; printf '%s' "$raw" > "$W/bd.raw"; hc --json verdict
    check "bd devolveu '$raw' (ilegível): MINI node_full, não NÓ" "local node_full" "$(jget verdict) $(jget reason)"
  done
  idle_city none; echo '[]' > "$W/bd.raw"; hc --json verdict
  check "bd devolveu [] (lista lida e vazia): ninguém tem bead → NÓ" "node 0" "$(jget verdict) $(jget active)"
  idle_city none; echo 1 > "$W/gcl.rc"; hc --json verdict
  check "gc session list falhou: sem alias para casar com a bead → 3 ocupadas, MINI node_full" "local node_full 3" "$(jget verdict) $(jget reason) $(jget active)"
  for raw in 'lixo' '{"sessions":"x"}' '[]' ''; do
    idle_city none; printf '%s' "$raw" > "$W/gcl.raw"; hc --json verdict
    check "gc session list devolveu '$raw' (ilegível): MINI node_full" "local node_full" "$(jget verdict) $(jget reason)"
  done

  # PRAZO e PARALELISMO: o gc leva 10-21 s no mini carregado e o Pilot dá 40 s ao veredito inteiro — as duas leituras correm juntas, e estourar o prazo é ilegível (ocupada)
  idle_city none; echo 3 > "$W/gcl.sleep"; echo 3 > "$W/bd.sleep"; t0=$SECONDS; hc --json verdict; el=$((SECONDS - t0))
  check "paralelo: gc e bd de 3 s cada, ociosas → NÓ" "node 0" "$(jget verdict) $(jget active)"
  check "paralelo: as duas leituras custam o MAIOR prazo (~3 s), não a soma (6 s): levou ${el}s" "yes" "$([ "$el" -le 5 ] && echo yes || echo no)"
  idle_city none; echo 4 > "$W/gcl.sleep"; RT=1; hc --json verdict
  check "gc estourou o prazo: 3 ocupadas, MINI node_full (nunca 'ociosas')" "local node_full 3" "$(jget verdict) $(jget reason) $(jget active)"
  check "gc estourou o prazo: o motivo diz 'prazo'" "yes" "$(case "$(jget reading.idle_why)" in *prazo*) echo yes;; *) echo no;; esac)"
  idle_city none; echo 4 > "$W/bd.sleep"; RT=1; hc --json verdict
  check "bd estourou o prazo: 3 ocupadas, MINI node_full (prazo não é 'ninguém trabalha')" "local node_full 3" "$(jget verdict) $(jget reason) $(jget active)"
  rt() { HETZNER_CAPACITY_READ_TIMEOUT_S="$1" "$PY" -I -c 'import importlib.util,sys
sp=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m); print(m.read_timeout(15.0))' "$P"; }
  check "HETZNER_CAPACITY_READ_TIMEOUT_S só ENCURTA (1→1, 30→15) e o inválido cai no padrão (abc, 0, -5, nan, inf, vazio → 15)" "1.0 15.0 15.0 15.0 15.0 15.0 15.0 15.0" \
    "$(rt 1) $(rt 30) $(rt abc) $(rt 0) $(rt -5) $(rt nan) $(rt inf) $(rt '')"

  # o que não dá para provar ocioso fica ocupado: sem alias, fora da lista do gc, outro papel (gate-reviewer, wa-worker), dog-remote-adhoc
  idle_city none; echo dog-remote-s1 > "$W/gcl.skip"; hc --json verdict
  check "sessão que o gc não lista (sem alias conhecido): conta OCUPADA" "node 1 2" "$(jget verdict) $(jget active) $(jget reading.sessions_idle)"
  idle_city none; echo dog-remote-s2 > "$W/gcl.noalias"; hc --json verdict
  check "sessão sem alias: conta OCUPADA" "node 1 2" "$(jget verdict) $(jget active) $(jget reading.sessions_idle)"
  idle_city none; printf 'gate-reviewer-remote-adhoc-aaa\nwa-worker-remote-bbb\ndog-remote-adhoc-ccc\n' > "$W/list.extra"; hc --json verdict
  check "gate-reviewer / wa-worker / dog-remote-adhoc no nó, MESMO listados no gc com alias: contam OCUPADOS (só alias de pool dog-remote-<n> prova ocioso)" "6 3 3 local node_full" "$(jget reading.sessions_total) $(jget reading.sessions) $(jget reading.sessions_idle) $(jget verdict) $(jget reason)"

  # a prova de carga do degrau é de sessão OCUPADA: dog ocioso não prova que o nó aguentou o degrau
  newcity; sess 3; busy none; node 70 3 90; series 0 2400 300
  check "step: 3 sessões OCIOSAS não são prova de carga → não sobe do degrau 1" "1" "$(ceil)"
  newcity; sess 3; busy all; node 70 3 90; series 0 2400 300
  check "step: 3 sessões OCUPADAS são prova de carga → sobe para 3" "3" "$(ceil)"

  # TERCEIRO ESTADO na prova de carga (gate-fix 1): quando o gc ou o bd não é LIDO, `sessions` guarda o TOTAL vivo contado como ocupado. Para o veredito isso é o inerte
  # (node_full); para a prova de carga seria o contrário (dog ocioso subiria o teto). Leitura sem a separação ocupada×ociosa feita não prova nada.
  newcity; sess 3; busy none; node 70 3 90; echo 1 > "$W/bd.rc"; series 0 2400 300
  check "step: bd falhando o tempo todo, 3 sessões sem bead → NÃO sobe (leitura que não separou ocupada de ociosa não é prova de carga)" "1" "$(ceil)"
  newcity; sess 3; busy none; node 70 3 90; echo 1 > "$W/gcl.rc"; series 0 2400 300
  check "step: gc falhando o tempo todo, 3 sessões sem bead → NÃO sobe" "1" "$(ceil)"
  newcity; sess 3; busy none; node 70 3 90; echo 4 > "$W/gcl.sleep"; RT=1; series 0 2400 300
  check "step: gc estourando o prazo o tempo todo, 3 sessões sem bead → NÃO sobe" "1" "$(ceil)"
  newcity; sess 3; busy none; node 70 3 90; series 0 1200 300; echo 1 > "$W/bd.rc"; series 1500 1500 300; rm -f "$W/bd.rc"; series 1800 2400 300
  check "step: UMA leitura com bd falhando no meio de uma janela de dogs ociosos já seria prova com any(): não sobe" "1" "$(ceil)"
  # os controles: a guarda não pode ser larga demais (leitura que falhou não VETA a subida; as outras da janela seguem valendo)
  newcity; sess 3; busy all; node 70 3 90; series 0 1200 300; echo 1 > "$W/bd.rc"; series 1500 1500 300; rm -f "$W/bd.rc"; series 1800 2400 300
  check "step: uma leitura com bd falhando no meio de leituras com 3 OCUPADAS lidas → ainda sobe para 3 (não veta)" "3" "$(ceil)"
  # leitura gravada antes da separação ocupada×ociosa (sem idle_why): não sabe quantas eram ociosas → não prova; com idle_why "" (lida) a mesma leitura prova
  for why in '' ',"idle_why":""'; do
    newcity; sess 3; busy none; node 70 3 90; rd=""
    for t in 600 900 1200 1500 1800 2100; do rd="$rd{\"t\":$((T0 + t)),\"state\":\"ok\",\"sessions\":3,\"cpu_headroom_pct\":70.0,\"mem_avail_pct\":90.0$why},"; done
    printf '{"v":1,"ceiling":1,"changed_at":%s,"changed_why":"x","readings":[%s]}' "$T0" "${rd%,}" > "$D/state.json"; at 2400; hc --json step
    if [ -z "$why" ]; then check "step: leituras gravadas SEM idle_why (antes da separação) não provam carga → não sobe" "1" "$(ceil)"
    else check "step: as mesmas leituras COM idle_why vazio (gc e bd lidos, 3 ocupadas) provam → sobe para 3" "3" "$(ceil)"; fi
  done
}

g_bg() {  # trabalho em nice > 0 (o lastro do nó, ga-2hd02v.5) é FUNDO: cede a qualquer sessão (nice 0), então não consome a folga da cidade
  newcity
  node_bg 200 1700 100 18 90; hc --json read
  check "bg: lastro 85% em nice 19 + sessões 10% + 5% parado, load5 18/16 → folga 90% (fundo cede), não 0%" "90.0 85.0 5.0" "$(jget cpu_headroom_pct) $(jget cpu_bg_pct) $(jget cpu_idle_pct)"
  check "bg: a leitura com lastro rodando é verde (a cidade segue recebendo bead)" "ok green" "$(jget state) $(jget color)"
  node_bg 1840 60 100 17 90; hc --json read
  check "bg: sessões saturando o nó (92% em nice 0) com lastro de 3% → folga 8%, vermelho (fundo não esconde carga de verdade)" "8.0 red" "$(jget cpu_headroom_pct) $(jget color)"
  node_bg 200 1700 100 18 15; hc --json read
  check "bg: RAM 15% continua vermelha com o lastro rodando (o lastro não afrouxa a RAM)" "red" "$(jget color)"
  node_bg 800 10 1190 12 90; hc --json read
  check "bg: fundo abaixo de 1% (0,5%) → vale a regra de antes: min(ocioso 59,5; 1-load5/núcleos = 25) = 25" "25.0 0.5" "$(jget cpu_headroom_pct) $(jget cpu_bg_pct)"
  node_bg 800 20 1180 12 90; hc --json read
  check "bg: fundo em exatos 1,0% → a carga (load5 12) deixa de valer, que inclui o próprio fundo: folga = ocioso + fundo = 60" "60.0" "$(jget cpu_headroom_pct)"
  node_bg 700 0 1300 12 90; hc --json read
  check "bg: sem fundo nenhum → a leitura de antes, sem mudança (min(65; 25) = 25, cpu_bg_pct 0)" "25.0 0.0" "$(jget cpu_headroom_pct) $(jget cpu_bg_pct)"
  node_bg 200 -5 1805 3 90; hc --json read
  check "bg: contador nice que anda para trás (o total das amostras segue positivo) → unreadable e cor unknown, nunca folga" "unreadable unknown" "$(jget state) $(jget color)"
}

# ga-2hd02v.2: a meta de ENCHER O NÓ, com os padrões de verdade (fillcity = sem config.json). O Athos: "o que não pode é ficar menos do que 100% ocupado".
g_fill() {
  r=$("$PY" -I -c 'import importlib.util,sys
sp=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
d=m.DEFAULTS; print(d["cpu_up_headroom_pct"], d["cpu_down_headroom_pct"], d["up_window_s"], d["up_min_reads"], d["down_reads"], d["cpu_lowers_ceiling"])' "$P" 2>&1 | tail -1)
  check "padrões: verde com 10% de CPU livre, quente abaixo de 3%, janela de 480 s com 3 leituras, 2 leituras para descer, só a RAM desce o degrau" "10.0 3.0 480 3 2 False" "$r"

  # (1)+(2) a escada sobe em MINUTOS com o ritmo do job (180 s), não em horas: 1 → 3 → 6 → 10 em 27 min
  fillcity; sess 1; node 70 3 90; busy all; series 0 360 180
  check "encher: 360 s (2 leituras contadas) ainda no degrau 1" "1" "$(ceil)"
  at 540; hc --json step; check "encher: 540 s, 3 leituras verdes em 480 s e 1 sessão ocupada → sobe para 3 (antes: 30 min e 6 leituras, que o ritmo do Pilot nunca dava)" "3" "$(jget ceiling)"
  sess 3; series 720 900 180; check "encher: 360 s depois do 3 ainda é 3 (não pula)" "3" "$(ceil)"
  at 1080; hc --json step; check "encher: 1080 s, 3 → 6" "6" "$(jget ceiling)"
  sess 6; series 1260 1440 180; check "encher: 360 s depois do 6 ainda é 6" "6" "$(ceil)"
  at 1620; hc --json step; check "encher: 1620 s (27 min) → 10" "10" "$(jget ceiling)"
  newcity; rm -f "$D/config.json"; sess 3; busy none; node 70 3 90; series 0 1800 180
  check "encher: o relógio mais curto NÃO dispensa a prova de carga (3 sessões ociosas, 30 min verdes → fica no 1)" "1" "$(ceil)"

  # (2) verde = sobra para mais uma sessão: 12,5% de CPU livre (nó a ~87% de uso) sobe; 35% livre era exigir o nó a 65%
  fillcity; node 85 14 90; hc --json read
  check "cor: CPU livre 12,5% é VERDE (cabe mais uma sessão); com o limite antigo de 35% era âmbar" "12.5 green" "$(jget cpu_headroom_pct) $(jget color)"
  node 85 15 90; hc --json read; check "cor: CPU livre 6,2% é âmbar (entre 3 e 10: segura o degrau, o nó ainda recebe)" "amber" "$(jget color)"
  node 2 3 90; hc --json read; check "cor: CPU livre 2% é vermelho (nó saturado)" "red" "$(jget color)"
  fillcity; sess 0; node 4 3 90; at 10; hc --json verdict
  check "veredito: CPU livre 4% (nó a 96%) ainda é NÓ — quente é abaixo de 3%" "0 node" "$RC $(jget verdict)"
  node 2 3 90; at 100; hc --json verdict; check "veredito: CPU livre 2% → MINI node_hot" "1 node_hot" "$RC $(jget reason)"

  # (3) CPU ocupada por quem NÃO é sessão da cidade (o Traço BIM) não derruba o degrau; quando a carga sai, o veredito volta ao NÓ na leitura seguinte, com as vagas todas
  fillcity; sess 0; hc --json set-ceiling 6 --reason t; node 2 40 90; series 180 1800 180
  check "externa: 10 leituras com CPU em 2% livre (load5 40/16) NÃO derrubam o degrau 6" "6" "$(ceil)"
  at 1800; hc --json verdict; check "externa: enquanto dura, o veredito do momento é MINI node_hot (bead nova não vai a nó saturado)" "1 local node_hot" "$RC $(jget verdict) $(jget reason)"
  node 70 3 90; at 1980; hc --json verdict
  check "externa: a carga saiu → NÓ na leitura seguinte (<= 3 min), com as 6 vagas: o degrau não caiu, não há subida de horas a refazer" "0 node 6" "$RC $(jget verdict) $(jget free)"
  # controle: a RAM continua sendo o limite duro. 2 leituras com RAM < 20% descem o degrau, uma só não, e leitura que falhou no meio não conta
  fillcity; sess 0; hc --json set-ceiling 6 --reason t; node 70 3 15; at 180; hc --json step
  check "RAM 15%: UMA leitura vermelha não desce" "6" "$(jget ceiling)"
  at 360; hc --json step; check "RAM 15%: 2 leituras seguidas descem 6 → 3 (o nó não tem swap)" "3" "$(jget ceiling)"
  fillcity; sess 0; hc --json set-ceiling 6 --reason t; node 70 3 15; at 180; hc --json step; echo 255 > "$W/ssh.rc"; at 240; hc --json step; node 70 3 15; at 300; hc --json step
  check "RAM 15%, FALHOU, RAM 15%: falha não é vermelha e quebra a sequência → não desce" "6" "$(jget ceiling)"
  fillcity; sess 0; hc --json set-ceiling 6 --reason t; node 2 3 15; at 180; hc --json step; at 360; hc --json step
  check "CPU E RAM vermelhas: a RAM desce" "3" "$(jget ceiling)"
  # a regra antiga continua à mão do Mayor: cpu_lowers_ceiling=true
  fillcity; sess 0; printf '{"cpu_lowers_ceiling":true}' > "$D/config.json"; hc --json set-ceiling 6 --reason t; node 2 3 90; at 180; hc --json step; at 360; hc --json step
  check "cpu_lowers_ceiling=true devolve a regra antiga: 2 leituras com CPU 2% livre descem o degrau" "3" "$(jget ceiling)"
  printf '{"cpu_lowers_ceiling":"sim"}' > "$D/config.json"; hc --json verdict
  check "config: cpu_lowers_ceiling que não é true/false → NÃO SEI config (rc 2), não 'verdadeiro'" "2 config" "$RC $(jget reason)"

  # (1) o relógio é do job: o plist agenda `step` a cada 180 s e a leitura de um ciclo perdido ainda vale
  PL="$HERE/com.gascity.hetzner-capacity-step.plist"
  r=$("$PY" -I -c 'import plistlib,sys
try: d=plistlib.load(open(sys.argv[1],"rb"))
except Exception as e: print("ilegivel", type(e).__name__); sys.exit(0)
a=d.get("ProgramArguments") or []
print(d.get("Label"), d.get("StartInterval"), a[-1] if a else None, bool(len(a) > 1 and a[-2].endswith("/scripts/hetzner-capacity.py")), (d.get("EnvironmentVariables") or {}).get("GC_CITY_PATH"))' "$PL" 2>&1 | tail -1)
  check "job: o plist agenda hetzner-capacity.py step a cada 180 s (o relógio da leitura é do job, não do Pilot)" "com.gascity.hetzner-capacity-step 180 step True /Users/athos/gt/.gascity-gastown-hq" "$r"
  r=$("$PY" -I -c 'import importlib.util,plistlib,sys
sp=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
try: iv=plistlib.load(open(sys.argv[2],"rb")).get("StartInterval")
except Exception as e: print("ilegivel", type(e).__name__); sys.exit(0)
d=m.DEFAULTS; print(isinstance(iv, int) and d["refresh_s"] <= iv and d["max_age_s"] >= 3 * iv and d["up_window_s"] >= 2 * iv and d["up_window_s"] >= d["up_min_reads"] * iv // 2)' "$P" "$PL" 2>&1 | tail -1)
  check "job: todo ciclo mede (refresh_s <= 180), um ciclo perdido não envelhece a leitura (max_age_s >= 3 x 180) e a janela cabe 3 leituras" "True" "$r"
}

# ga-2hd02v.2: a consulta da prova ao vivo. Hora SEM leitura não é 0% nem OK; leitura que falhou fica fora da média; linha ruim é contada e pulada.
g_hourly() {
  rd() {  # rd HORA SEG IDLE [STATE] → uma linha em readings.jsonl (HORA = horas depois de T0; SEG = segundos dentro da hora)
    printf '{"t":%s,"state":"%s","cpu_idle_pct":%s,"mem_avail_pct":90.0,"sessions":0}\n' "$((T0 + $1 * 3600 + $2))" "${4:-ok}" "$3" >> "${RDF:-$D/readings.jsonl}"
  }
  hj() { printf '%s' "$OUT" | "$PY" -I -c 'import sys,json
d=json.load(sys.stdin); print(" ".join(h["status"] for h in d["hours"]), d["all_ok"], d["bad_lines"])'; }
  hf() { printf '%s' "$OUT" | "$PY" -I -c 'import sys,json
h=json.load(sys.stdin)["hours"][int(sys.argv[1])]; print(h["media"], h["ok"], h["falhas"], h["status"])' "$1"; }
  RDF=""; newcity; for h in 0 1 2; do rd $h 100 10; rd $h 1000 12; rd $h 2000 8; done
  at $((3 * 3600 + 100)); hc --json hourly --hours 3
  check "hourly: 3 horas completas com ~90% de CPU ocupada → rc 0, todas ok" "0 ok ok ok True 0" "$RC $(hj)"
  check "hourly: a média é 100 - ocioso (10, 12, 8 → 90.0, 3 leituras)" "90.0 3 0 ok" "$(hf 0)"
  hc hourly --hours 3; check "hourly: sem --json imprime uma linha por hora e o veredito" "4 1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ') $(printf '%s' "$OUT" | grep -c 'tudo >= 85%')"
  check "hourly: não grava nada nem chama o ssh" "0" "$(calls)"
  rd 1 3000 60; rd 1 3100 60; rd 1 3200 60; hc --json hourly --hours 3
  check "hourly: a hora 1 puxada para baixo (média ~65%) → rc 1, abaixo" "1 ok abaixo ok False 0" "$RC $(hj)"
  hc hourly --hours 3; check "hourly: o texto aponta a hora ABAIXO de 85%" "1" "$(printf '%s' "$OUT" | grep -c 'ABAIXO de 85%')"
  hc --json hourly --hours 3 --min-pct 60; check "hourly: --min-pct 60 → a mesma hora passa" "0 True" "$RC $(hj | cut -d' ' -f4)"

  RDF=""; newcity; for h in 0 1; do rd $h 100 10; rd $h 1000 10; done
  at $((3 * 3600 + 100)); hc --json hourly --hours 3
  check "hourly: hora SEM leitura (a 2) é sem_leitura, não 0% e não ok → rc 1" "1 ok ok sem_leitura False" "$RC $(hj | cut -d' ' -f1-4)"
  RDF=""; newcity; hc --json hourly --hours 2; at 7300; hc --json hourly --hours 2
  check "hourly: sem readings.jsonl nenhum → todas sem_leitura, rc 1 (nem erro nem 'tudo certo')" "1 sem_leitura sem_leitura False" "$RC $(hj | cut -d' ' -f1-3)"

  RDF=""; newcity; for h in 0 1; do rd $h 100 10; rd $h 1000 10; done
  rd 0 2000 0 unreachable; rd 0 2100 0 unreadable; rd 0 2200 100 ok
  at $((2 * 3600 + 100)); hc --json hourly --hours 2
  check "hourly: leitura que falhou (cpu_idle 0 no registro) fica FORA da média e entra em falhas; a ok com 100% ocioso entra (90, 90, 0 → 60.0)" "60.0 3 2 abaixo" "$(hf 0)"
  RDF=""; newcity; for h in 0 1; do rd $h 100 10; rd $h 1000 10; done
  printf 'isto não é json\n{"t":"x"}\n{"state":"ok"}\n\n' >> "$D/readings.jsonl"; at $((2 * 3600 + 100)); hc --json hourly --hours 2
  check "hourly: linha que não é JSON / sem t inteiro é CONTADA (3) e pulada; as boas seguem valendo" "0 ok ok True 3" "$RC $(hj)"

  # o arquivo rotacionado (.1) também conta; a hora corrente (parcial) não entra
  RDF="$T/rot.jsonl"; rm -f "$RDF"; newcity; RDF="$D/readings.jsonl.1"; rd 0 100 10; rd 0 1000 10; RDF="$D/readings.jsonl"; rd 1 100 10; rd 1 1000 10; rd 2 100 100; rd 2 200 100
  at $((2 * 3600 + 3000)); hc --json hourly --hours 2
  check "hourly: lê o readings.jsonl.1 e deixa de fora a hora corrente (a 2, 0% ocupada): 2 horas, ambas ok" "0 ok ok True 0" "$RC $(hj)"

  RDF=""; newcity; rd 0 100 10; at 4000; chmod 000 "$D/readings.jsonl"; hc --json hourly --hours 1; r="$RC $(grep -c Traceback "$W/err")"; chmod 600 "$D/readings.jsonl"
  check "hourly: readings.jsonl que existe e não abre → erro rc 3, sem traceback (NÃO 'sem leitura')" "3 0" "$r"
  newcity; at 4000; hc --json hourly --hours 0; r="$RC"; hc --json hourly --hours 721; r="$r $RC"; hc --json hourly --min-pct 101; r="$r $RC"; hc --json hourly --min-pct nan; r="$r $RC"
  check "hourly: --hours fora de 1..720 e --min-pct fora de 0..100 (ou nan) → rc 3" "3 3 3 3" "$r"
  RDF=""
}

cnew() { newcity; sess 0; }      # cidade sem sessões vivas: a vaga existe, e é a pergunta ao Claude que decide
g_claude() {  # o login do Claude do nó (ga-2hd02v.7): só `ok` do gate (saída 0 e a linha exata) deixa o veredito dizer NÓ; login medido ruim = MINI; o resto = NÃO SEI; tudo AO VIVO, sem pausa gravada
  cnew; hc --json verdict
  check "claude: gate ok → NÓ free_slot (rc 0), com UMA pergunta ao gate" "0 node free_slot 1" "$RC $(jget verdict) $(jget reason) $(wc -l < "$W/claude.calls" | tr -d ' ')"
  for st in logged-out expired quota; do
    cnew; gate_says 1 "blocked: $st: texto do gate"; hc --json verdict
    check "claude: blocked: $st (saída 1) → MINI claude_blocked (rc 1)" "1 local claude_blocked" "$RC $(jget verdict) $(jget reason)"
  done
  cnew; gate_says 1 "blocked: quota: You've hit your weekly limit · renova em 2026-10-22T16:00:00Z"; hc --json verdict
  case "$(jget detail)" in *"renova em 2026-10-22T16:00:00Z"*) ok 0 "claude: o detalhe do veredito leva o horário em que a cota renova";; *) ok 1 "claude: o detalhe do veredito não leva o horário (veio '$(jget detail)')";; esac
  # o que não é nem ok nem login medido ruim → NÃO SEI (rc 2): nunca NÓ, e nunca um MINI "conhecido"
  while IFS='|' read -r rc line why; do
    cnew; gate_says "$rc" "$line"; hc --json verdict
    check "claude: $why → NÃO SEI claude_unknown (rc 2)" "2 unknown claude_unknown" "$RC $(jget verdict) $(jget reason)"
  done <<'EOF'
1|blocked: unreachable: ssh fora|o gate não soube dizer (unreachable)
1|blocked: unknown: resposta ilegível|o gate não soube dizer (unknown)
0|okay|saída 0 com linha que só começa com ok
0||saída 0 e vazia
1||saída 1 e vazia
1|ok|saída 1 com a linha ok (contradição)
0|blocked: quota: x|saída 0 com linha blocked (contradição)
2|blocked: quota: x|saída 2 com linha blocked
3|ok|saída 3 com a linha ok
124|blocked: quota: x|saída 124 (o timeout cortou o gate)
EOF
  cnew; echo 5 > "$W/claude.sleep"; RT=1; hc --json verdict
  check "claude: gate que estoura o prazo → NÃO SEI claude_unknown (rc 2), sem esperar os 5 s" "2 unknown claude_unknown" "$RC $(jget verdict) $(jget reason)"
  case "$(jget detail)" in *prazo*) ok 0 "claude: o detalhe do estouro diz 'prazo'";; *) ok 1 "claude: o detalhe do estouro não diz prazo (veio '$(jget detail)')";; esac
  cnew; CC='["/nao/existe/gate-claude"]'; hc --json verdict
  check "claude: comando do gate que não executa → NÃO SEI claude_unknown (rc 2)" "2 unknown claude_unknown" "$RC $(jget verdict) $(jget reason)"
  cnew; CC='isto não é uma lista JSON'; hc --json verdict
  check "claude: HETZNER_CAPACITY_CLAUDE_CMD que não é lista JSON → NÃO SEI claude_unknown (rc 2), sem traceback" "2 unknown claude_unknown" "$RC $(jget verdict) $(jget reason)"
  # a pergunta que LEVANTOU exceção (NUL no argumento: o subprocess levanta ValueError, que o gate não trata) → NÃO SEI, nunca NÓ
  cnew; CC='["a\u0000b"]'; hc --json verdict
  check "claude: pergunta que levantou exceção (NUL no comando do gate) → NÃO SEI claude_unknown (rc 2)" "2 unknown claude_unknown" "$RC $(jget verdict) $(jget reason)"
  case "$(jget detail)" in *"falhou (ValueError"*) ok 0 "claude: o detalhe da exceção diz que a pergunta falhou e com qual erro";; *) ok 1 "claude: o detalhe da exceção não diz o erro (veio '$(jget detail)')";; esac
  # o veredito SEM a pergunta (verdict() chamado sem o gate) o CLI nunca alcança — o main dispara a pergunta em todo `verdict` —, então só a chamada direta prova que ele não vira ok; o 3º é o controle: resposta ok vale ok
  cr() { "$PY" -I -c 'import importlib.util,sys
sp=importlib.util.spec_from_file_location("hc",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
class F:
    def result(self): raise RuntimeError("x")
print(m.claude_result(None)[:8], m.claude_result(F())[:8], m.claude_result(type("O", (), {"result": lambda s: "ok"})()))' "$P"; }
  check "claude: sem a pergunta → unknown; pergunta que levantou exceção → unknown; só a resposta ok do gate vale ok" "unknown: unknown: ok" "$(cr)"
  # a ordem das condições: pausa e nó cheio vêm antes da pergunta ao Claude
  cnew; gate_says 1 "blocked: quota: x"; hc --json pause --reason "janela"; hc --json verdict
  check "claude: pausa do Mayor + gate blocked → a pausa decide (MINI paused)" "1 paused" "$RC $(jget reason)"
  newcity; sess 10; gate_says 1 "blocked: quota: x"; hc --json verdict
  check "claude: nó cheio + gate blocked → node_full decide (a pergunta vem depois da vaga)" "local node_full" "$(jget verdict) $(jget reason)"
  # retomada sozinha (item 4): nada é gravado; com o gate de volta a ok o veredito seguinte volta a ser NÓ, e a pausa do Mayor continua só dele
  cnew; gate_says 1 "blocked: quota: x"; hc --json verdict; r1="$RC $(jget reason)"
  gate_says 0 ok; at 120; hc --json verdict; r2="$RC $(jget reason)"
  check "claude: blocked e depois ok → MINI claude_blocked e, no veredito seguinte, NÓ (retomada sozinha)" "1 claude_blocked|0 free_slot" "$r1|$r2"
  check "claude: o bloqueio não grava pause.json" "no" "$([ -e "$D/pause.json" ] && echo yes || echo no)"
  cnew; hc --json pause --reason "mayor"; gate_says 1 "blocked: quota: x"; hc --json verdict; gate_says 0 ok; at 120; hc --json verdict
  check "claude: gate de volta a ok NÃO apaga a pausa do Mayor (segue MINI paused)" "1 paused yes" "$RC $(jget reason) $([ -e "$D/pause.json" ] && echo yes || echo no)"
  # quem pergunta: só o `verdict`, e junto com a medição do nó (o ssh dorme 2 s; o gate já tinha começado quando ele acabou)
  cnew; echo 2 > "$W/ssh.sleep"; hc --json verdict
  check "claude: a pergunta ao gate corre JUNTO com a medição do nó (a soma estouraria os 40 s do Pilot)" "yes" "$([ -e "$W/ssh.sawclaude" ] && echo yes || echo no)"
  cnew; hc --json status; hc --json read; hc --json step; hc --json pause --reason t; hc --json resume
  check "claude: status, read, step, pause e resume não perguntam ao gate" "no" "$([ -e "$W/claude.calls" ] && echo yes || echo no)"
}

g_orphan() {  # a tmux do nó que o gc já deu por fechada (ga-0k82lw, camada 3): só morre com TODAS as provas, em ciclos seguidos; leitura que falha não age nem mexe nos relógios
  X=dog-remote-gawispzz001; Y=dog-remote-gawispzz002; Z=dog-remote-gawispzz003
  oc() {  # oc MODO → cidade nova com a varredura nesse modo; nó sem tmux; o gc lista só o Mayor
    newcity; PCMD=""; rm -f "$W"/act.* "$W"/stop.* "$W"/show.* "$W/gcl.raw"
    printf '{%s,"reap_orphans":"%s"}\n' "$LEGACY" "$1" > "$D/config.json"; sess 0; : > "$W/list.extra"; gcl
  }
  gcl() {  # gcl NOME… → o gc lista essas sessões como ABERTAS (mais o Mayor)
    local s='{"session_name":"mayor","alias":"mayor","state":"active","closed":false}' x
    for x in "$@"; do s="$s,{\"session_name\":\"$x\",\"alias\":\"$x\",\"state\":\"active\",\"closed\":false}"; done
    printf '{"sessions":[%s]}\n' "$s" > "$W/gcl.raw"
  }
  node_has() { printf '%s\n' "$@" > "$W/list.extra"; }                  # as tmux vivas do nó
  beadst() { echo "$2" > "$W/show.$1"; }                                # beadst ID STATUS
  act_at() { "$PY" -I -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(int(sys.argv[1]))))' $((T0 + $2)) > "$W/act.$1"; }      # act_at NOME SEGUNDOS (relativos ao T0)
  full() { oc "$1"; node_has $X; beadst ga-wisp-zz001 closed; act_at $X -3600; }      # a órfã de verdade: fora do gc, bead fechada, parada há 1 h
  runs() { local t; for t in "$@"; do at "$t"; hc --json step; done; }
  stops() { local s; s=$(cat "$W/stop.calls" 2>/dev/null | tr '\n' ' '); printf '%s' "${s:- }"; }      # os nomes encerrados, cada um com um espaço atrás; um espaço só = nenhum stop
  evn() { grep -c "\"state\": \"$1\"" "$D/events.jsonl" 2>/dev/null; true; }
  onnode() { grep -qx "$1" "$W/list.extra" && echo yes || echo no; }

  full kill; runs 0; check "órfã: no 1º ciclo é só vista (nada encerrado)" "dog-remote-gawispzz001| |1" "$(jget orphans.seen | tr -d '[]\"')|$(stops)|$(evn vista)"
  runs 180; check "órfã: no 2º ciclo, com 180 s de idade (< 600), ainda não age" " |1" "$(stops)|$(evn vista)"
  runs 700; check "órfã: 3 ciclos, 700 s, bead fechada, parada há 1 h → o provider encerra a tmux" "dog-remote-gawispzz001 |no" "$(stops)|$(onnode $X)"
  check "órfã: encerrada e conferida (lista do nó sem ela): killed, estado morta, sai do orphans.json" "[\"dog-remote-gawispzz001\"] 1 []" "$(jget orphans.killed) $(evn morta) $("$PY" -I -c 'import json,sys;print(json.dumps(list(json.load(open(sys.argv[1]))["orphans"])))' "$D/orphans.json")"
  check "órfã: o step segue com rc 0 e o degrau" "0" "$RC"

  full log; runs 0 180 700; check "modo log: registra a elegível ('parada') e NÃO encerra" " |1|yes" "$(stops)|$(evn parada)|$(onnode $X)"
  full kill; printf '{%s}\n' "$LEGACY" > "$D/config.json"; runs 0 180 700; check "sem a chave no config.json o padrão é log: não encerra" " |yes" "$(stops)|$(onnode $X)"
  full off; runs 0 180 700; check "modo off: não olha (sem orphans.json), não encerra" " |no|off" "$(stops)|$([ -e "$D/orphans.json" ] && echo yes || echo no)|$(jget orphans.mode)"

  full kill; printf '{%s,"reap_orphans":"kill","orphan_grace_s":1}\n' "$LEGACY" > "$D/config.json"; runs 700
  check "um ciclo só não basta (ORPHAN_MIN_SEEN=2), mesmo com a carência cumprida" " " "$(stops)"; runs 710; check "o 2º ciclo seguido, com a carência cumprida, encerra" "dog-remote-gawispzz001 " "$(stops)"
  full kill; runs 0 1000; check "ciclos longe demais um do outro (> max_age_s) não são 'seguidos': o relógio recomeça" " " "$(stops)"
  full kill; runs 0 180; printf 'lixo' > "$D/orphans.json"; runs 360 700; check "orphans.json ilegível: os relógios recomeçam (nunca age cedo)" " " "$(stops)"; runs 1400; check "…e depois da carência de novo, age" "dog-remote-gawispzz001 " "$(stops)"

  full kill; beadst ga-wisp-zz001 open; runs 0 180 700; check "bead da sessão ABERTA (o gc só não a listava): não é órfã, não encerra" " |1" "$(stops)|$(evn bead-open)"
  for why in sem-bead outra-forma; do
    full kill; [ $why = sem-bead ] && rm -f "$W/show.ga-wisp-zz001" || printf '[{"id":"ga-wisp-zz001","status":"closed","issue_type":"task"}]\n' > "$W/show.raw"
    runs 0 180 700; check "bead ilegível ($why): terceiro estado, não encerra" " |1" "$(stops)|$(evn ilegivel)"
  done
  full kill; act_at $X 640; runs 0 180 700; check "tmux com atividade há 60 s: ainda trabalha, não encerra" " |1" "$(stops)|$(evn ativa)"
  act_at $X -3600; runs 880; check "…e quando para há mais de orphan_idle_s, encerra" "dog-remote-gawispzz001 " "$(stops)"
  full kill; echo 1 > "$W/act.rc"; runs 0 180 700; check "atividade ilegível (provider falhou): não encerra" " |1" "$(stops)|$(evn ilegivel)"
  full kill; rm -f "$W/act.$X"; runs 0 180 700; check "atividade sem data (provider não imprimiu nada): não encerra" " " "$(stops)"

  full kill; echo 1 > "$W/gcl.rc"; runs 0 180 700; check "gc session list falhou: não encerra e os relógios nem andam" " |no" "$(stops)|$([ -e "$D/orphans.json" ] && echo yes || echo no)"
  check "gc session list falhou: o motivo vai na saída" "yes" "$([ -n "$(jget orphans.error)" ] && [ "$(jget orphans.error)" != null ] && echo yes || echo no)"
  full kill; printf '{"sessions":[]}\n' > "$W/gcl.raw"; runs 0 180 700; check "gc com lista VAZIA é leitura suspeita (nunca 'nenhuma aberta'): não encerra" " " "$(stops)"
  full kill; echo 1 > "$W/list.rc"; runs 0 180 700; check "list-running do nó falhou: não encerra" " " "$(stops)"
  full kill; gcl $X; runs 0 180 700; check "o gc lista a sessão como aberta: não é órfã (nem com bead fechada e parada)" " |[]" "$(stops)|$(jget orphans.seen)"
  full kill; node_has scratch-manual; runs 0 180 700; check "tmux com nome que o gc não gera: a varredura não toca" " |[]" "$(stops)|$(jget orphans.seen)"

  oc kill; node_has $X $Y $Z; for b in 1 2 3; do beadst ga-wisp-zz00$b closed; done; act_at $X -3600; act_at $Y -3600; act_at $Z -3600; runs 0 180 700
  check "no máximo 2 encerradas por ciclo (ORPHAN_MAX_KILLS)" "dog-remote-gawispzz001 dog-remote-gawispzz002 " "$(stops)"; runs 880; check "…a 3ª fica para o ciclo seguinte" "dog-remote-gawispzz001 dog-remote-gawispzz002 dog-remote-gawispzz003 " "$(stops)"
  full kill; echo 1 > "$W/stop.rc"; runs 0 180 700; check "stop que falha: a tmux segue, estado falhou, killed vazio" "yes|1|[]" "$(onnode $X)|$(evn falhou)|$(jget orphans.killed)"
  rm -f "$W/stop.rc"; runs 880; check "…e o ciclo seguinte tenta de novo e consegue" "no" "$(onnode $X)"
  full kill; : > "$W/stop.keep"; runs 0 180 700; check "stop que diz ok mas a tmux continua no nó: 'continua', NÃO conta como encerrada" "1|[]" "$(evn continua)|$(jget orphans.killed)"
  full kill; runs 0 180; PCMD='isto nao e json'; runs 700; PCMD=""; check "erro de configuração no meio da varredura: o step segue rc 0 e vai para o alarme" "0|yes" "$RC|$(grep -q '"event": "alarm"' "$D/events.jsonl" && echo yes || echo no)"
  oc kill; printf '{%s,"reap_orphans":"sim"}\n' "$LEGACY" > "$D/config.json"; hc step; check "reap_orphans inválido é erro de configuração (rc 3)" "3" "$RC"
  oc kill; printf '{%s,"orphan_grace_s":0}\n' "$LEGACY" > "$D/config.json"; hc step; check "orphan_grace_s < 1 é erro de configuração (rc 3)" "3" "$RC"
}

if [ -n "${HC_MUTANT:-}" ]; then for g in ${HC_MGROUPS:-bg third read step verdict idle fill hourly claude orphan}; do "g_$g"; done; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
if [ -n "${HC_ONLY:-}" ]; then "g_$HC_ONLY"; echo "── $((n - fails))/$n ok (só g_$HC_ONLY)"; [ "$fails" = 0 ]; exit $?; fi
g_fill; g_hourly; g_read; g_step; g_verdict; g_third; g_idle; g_bg; g_claude; g_orphan

[ -n "${HC_NO_MUTANTS:-}" ] || {
  echo "── controle negativo: cada mutante tem que reprovar a bateria ──"
  nm=0
  mutant() {  # mutant DESCRIÇÃO ANTES DEPOIS — troca EXATAMENTE uma ocorrência numa cópia
    nm=$((nm+1)); local m="$T/mut$nm.py"
    "$PY" -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$P" "$2" "$3" "$m"
    if [ $? -ne 0 ]; then ok 1 "mutante '$1': a âncora não casa exatamente 1 vez (o script mudou?)"; return; fi
    local r; r=$(HC_MUTANT=1 HC_MGROUPS="${MG:-}" HC_UNDER_TEST="$m" bash "$0" 2>&1 | tail -1)      # MG=grupos: o mutante da lógica nova só roda os grupos que o pegam
    case "$r" in "RESULT 0/"*) ok 1 "mutante '$1' NÃO foi pego ($r)";; "RESULT "*) ok 0 "mutante '$1' pego ($r)";; *) ok 1 "mutante '$1': sem resultado ($r)";; esac
  }
  mutant "leitura que falhou conta como verde" 'if r.get("state") != "ok" or not is_num(r.get("cpu_headroom_pct")) or not is_num(r.get("mem_avail_pct")):
        return "unknown"' 'if r.get("state") != "ok" or not is_num(r.get("cpu_headroom_pct")) or not is_num(r.get("mem_avail_pct")):
        return "green"'
  mutant "sobe sem a prova de carga" 'if cfg["require_load_proof"] and not any(' 'if False and not any('
  mutant "degrau que pula para o último" 'return {"action": "up", "to": steps[i + 1]' 'return {"action": "up", "to": steps[-1]'
  mutant "evidência que vale duas vezes (>=)" 'since = [r for r in reads if r["t"] > st["changed_at"]]' 'since = [r for r in reads if r["t"] >= st["changed_at"]]'
  mutant "present() engole o erro" '        os.lstat(path)
        return True
    except FileNotFoundError:' '        os.lstat(path)
        return True
    except OSError:'
  mutant "veredito sem o gate_done" '    if gd != "ok":' '    if False:'
  mutant "cap do provider ignorado" 'base["effective"] = min(st["ceiling"], caps["cap"])' 'base["effective"] = st["ceiling"]'
  mutant "vaga com > no lugar de >=" 'if r["sessions"] >= base["effective"]:' 'if r["sessions"] > base["effective"]:'
  mutant "sessões ilegíveis viram 0" '    except Unreadable as e:
        r["sessions_why"] = str(e)
    return r' '    except Unreadable as e:
        r["sessions"] = 0
    return r'
  mutant "leitura velha autoriza" 'if now - r["t"] > cfg["max_age_s"]:' 'if False:'
  mutant "leitura sem 'state' passa por válida" 'and isinstance(r.get("t"), int) and isinstance(r.get("state"), str) for r in st["readings"]))' 'and isinstance(r.get("t"), int) for r in st["readings"]))'
  mutant "leitura no futuro autoriza" 'if now - r["t"] < -60:' 'if False:'
  mutant "vermelho só com CPU E RAM" 'if cpu < cfg["cpu_down_headroom_pct"] or mem < cfg["mem_down_avail_pct"]:' 'if cpu < cfg["cpu_down_headroom_pct"] and mem < cfg["mem_down_avail_pct"]:'
  mutant "âmbar vira verde" 'if cpu >= cfg["cpu_up_headroom_pct"] and mem >= cfg["mem_up_avail_pct"]:' 'if cpu >= cfg["cpu_up_headroom_pct"] or mem >= cfg["mem_up_avail_pct"]:'
  mutant "CPU livre pelo MAIOR em vez do menor" 'max(0.0, min(100.0, idle_pct, 100.0 * (1.0 - load5 / ncpu)))' 'max(0.0, min(100.0, max(idle_pct, 100.0 * (1.0 - load5 / ncpu))))'
  mutant "estado ilegível recomeça em vez de falhar" '        raise StateUnreadable(f"{env.state}: não abre ({e})")' '        return fresh_state(cfg, now, "recomeço"), []'
  mutant "falha de ssh vira leitura ok com zeros" 'r.update(state="unreachable", why=str(e) or type(e).__name__)' 'r.update(state="ok", cpu_headroom_pct=0.0, mem_avail_pct=100.0)'
  mutant "load5 nan/inf passa por válido" 'or not 0 <= load5 < float("inf"):' 'or load5 < 0:'
  mutant "leitura ok de cor desconhecida autoriza" 'if color(r, cfg) == "unknown":' 'if False:'
  mutant "state.json não-UTF-8 derruba (só JSONDecodeError é pego)" '    except (ValueError, RecursionError):        # JSON ruim' '    except json.JSONDecodeError:        # JSON ruim'
  mutant "state.json aninhado fundo demais derruba (RecursionError fora)" '    except (ValueError, RecursionError):        # JSON ruim' '    except ValueError:        # JSON ruim'
  mutant "state.json sem changed_why passa por válido" ' and isinstance(st.get("changed_why"), str)' ''
  mutant "config.json não-UTF-8 derruba (só JSONDecodeError é pego)" '    except (ValueError, RecursionError) as e:
        raise ConfigError(f"{path}: JSON inválido ou não é UTF-8 ({e})")' '    except json.JSONDecodeError as e:
        raise ConfigError(f"{path}: JSON inválido ou não é UTF-8 ({e})")'
  mutant "config de fora aninhada fundo demais derruba (read_json sem RecursionError)" 'except (OSError, ValueError, RecursionError) as e:' 'except (OSError, ValueError) as e:'
  mutant "sem o catch-all em main()" '    except Exception as e:      # bug nosso' '    except KeyboardInterrupt as e:      # bug nosso'
  mutant "catch-all do verdict sai 1 (MINI) em vez de 2" '"detail": f"{type(e).__name__}: {e}"}, f"unknown internal: {type(e).__name__}: {e}")
            return 2' '"detail": f"{type(e).__name__}: {e}"}, f"unknown internal: {type(e).__name__}: {e}")
            return 1'
  mutant "catch-all do step sai 1 (MINI) em vez de 3" 'erro interno: {type(e).__name__}: {e}", file=sys.stderr)
        return 3' 'erro interno: {type(e).__name__}: {e}", file=sys.stderr)
        return 1'
  mutant "ssh que não executa vira nó fora" 'except (ConnectionError, subprocess.TimeoutExpired) as e:' 'except (ConnectionError, subprocess.TimeoutExpired, OSError) as e:'
  mutant "gate_done_bin relativo passa por executável" 'os.path.isabs(v) and os.path.isfile(v)' 'os.path.isfile(v)'
  mutant "bd/gc com rc≠0 mas JSON válido: o rc é ignorado" 'if p.returncode != 0:
        raise Unreadable(f"{what} saiu com' 'if False:
        raise Unreadable(f"{what} saiu com'
  mutant "leitura de bead/sessão que falhou conta como ociosa" 'return len(names), 0, f"não provei nenhuma sessão ociosa: {e}"' 'return others, len(dogs), ""'
  mutant "bead de qualquer dono torna ocupada, em vez de a do alias" 'idle = [n for n in dogs if n in owners and not (owners[n] & working)]' 'idle = [n for n in dogs if n in owners and not working]'
  mutant "bead de outro dono não conta (só a primeira bead vale)" 'return {b["assignee"] for b in rows if isinstance(b.get("assignee"), str) and b["assignee"]}' 'return {b["assignee"] for b in rows[:1] if isinstance(b.get("assignee"), str) and b["assignee"]}'
  mutant "sessão sem alias conhecido conta ociosa" 'idle = [n for n in dogs if n in owners and not (owners[n] & working)]' 'idle = [n for n in dogs if not (owners.get(n, set()) & working)]'
  mutant "gate-reviewer / wa-worker / dog-remote-adhoc com alias no gc contam ociosas (alias de pool não é exigido)" ' and POOL_DOG_ALIAS.fullmatch(x["alias"])}' ' and x["alias"]}'
  mutant "dog-remote-adhoc-* vale como alias de pool (padrão frouxo)" 'POOL_DOG_ALIAS = re.compile(r"dog-remote-[0-9]+")' 'POOL_DOG_ALIAS = re.compile(r"dog-remote-.*")'
  mutant "bead no NOME da sessão não a torna ocupada" 'return {x["session_name"]: {x["alias"], x["session_name"]} for x in rows' 'return {x["session_name"]: {x["alias"]} for x in rows'
  mutant "saída do bd que não é lista de beads vira 'ninguém trabalha'" 'raise Unreadable("bd list in_progress: a saída não é uma lista de beads")' 'return set()'
  mutant "o veredito conta TODAS as vivas (a leitura antiga)" 'return len(names) - len(idle), len(idle), ""' 'return len(names), len(idle), ""'
  mutant "as duas leituras em sequência (a soma, não o maior)" '        f_owners, f_work = pool.submit(session_owners), pool.submit(busy_aliases)' '        f_owners = pool.submit(session_owners); f_owners.exception(); f_work = pool.submit(busy_aliases)'
  mutant "leitura que estourou o prazo vira lista vazia (ninguém trabalha)" '        raise Unreadable(f"{what} estourou o prazo ({limit:g}s)")' '        return []'
  mutant "o prazo do teste alonga o padrão" '    return min(v, default) if v > 0 else default' '    return v if v > 0 else default'
  mutant "prazo inválido ou <= 0 vira prazo quase zero" '    return min(v, default) if v > 0 else default' '    return min(v, default) if v > 0 else 0.001'
  mutant "sem dog-remote no nó, conta uma sessão fantasma" 'return others, 0, ""' 'return others + 1, 0, ""'
  mutant "a prova de carga aceita leitura com gc/bd não lidos (idle_why com motivo)" ' and r.get("idle_why") == "" and r["sessions"] >= cur' ' and r["sessions"] >= cur'
  mutant "a prova de carga aceita leitura sem idle_why (anterior à separação ocupada×ociosa)" 'r.get("idle_why") == ""' 'not r.get("idle_why")'
  mutant "(ga-2hd02v.5) o fundo (nice > 0) não vira folga" 'cpu_headroom = max(0.0, min(100.0, idle_pct + bg_pct))' 'cpu_headroom = max(0.0, min(100.0, idle_pct))'
  mutant "(ga-2hd02v.5) o load5 continua valendo com fundo (o lastro faria o nó parecer cheio)" '    if bg_pct >= BG_MIN_PCT:' '    if False:'
  mutant "(ga-2hd02v.5) qualquer fundo, até 0%, desliga o load5" 'BG_MIN_PCT = 1.0 ' 'BG_MIN_PCT = 0.0 '
  mutant "(ga-2hd02v.5) contador nice que anda para trás é aceito" ' or not 0 <= dn <= dt - di' ''
  # ga-2hd02v.2 (encher o nó): cada mutante da lógica nova só roda os grupos que o pegam (MG)
  MG=fill mutant "a CPU cheia derruba o degrau (a regra antiga)" 'return cfg["cpu_lowers_ceiling"] or r["mem_avail_pct"] < cfg["mem_down_avail_pct"]' 'return True'
  MG=fill mutant "decide() volta a descer por qualquer leitura vermelha" 'all(lowers_ceiling(r, cfg) for r in last)' 'all(color(r, cfg) == "red" for r in last)'
  MG=fill mutant "a RAM não derruba mais o degrau" 'return cfg["cpu_lowers_ceiling"] or r["mem_avail_pct"] < cfg["mem_down_avail_pct"]' 'return cfg["cpu_lowers_ceiling"]'
  MG=fill mutant "leitura que falhou ou âmbar também desce o degrau" '    if color(r, cfg) != "red":
        return False' '    if color(r, cfg) == "green":
        return False'
  MG=fill mutant "o padrão de CPU livre para subir volta a 35%" '"cpu_up_headroom_pct": 10.0,' '"cpu_up_headroom_pct": 35.0,'
  MG=fill mutant "a janela de subida volta a 1800 s" '"up_window_s": 480,' '"up_window_s": 1800,'
  MG=fill mutant "o limite de nó quente volta a 10%" '"cpu_down_headroom_pct": 3.0,' '"cpu_down_headroom_pct": 9.0,'
  MG=fill mutant "a CPU passa a derrubar o degrau por padrão" '"cpu_lowers_ceiling": False,' '"cpu_lowers_ceiling": True,'
  MG=fill mutant "cpu_lowers_ceiling que não é bool é aceito" 'for k in ("require_load_proof", "cpu_lowers_ceiling"):' 'for k in ("require_load_proof",):'
  MG=hourly mutant "hora sem leitura conta como ok" '"status": "sem_leitura" if mean is None else ("abaixo" if mean < min_pct else "ok")}' '"status": "ok" if mean is None else ("abaixo" if mean < min_pct else "ok")}'
  MG=hourly mutant "leitura que falhou entra na média" '        if r.get("state") == "ok" and is_num(idle) and 0 <= idle <= 100:' '        if is_num(idle) and 0 <= idle <= 100:'
  MG=hourly mutant "a hora corrente (parcial) entra" 'busy = {h: [] for h in range(cur - hours, cur)}' 'busy = {h: [] for h in range(cur - hours + 1, cur + 1)}'
  MG=hourly mutant "arquivo que existe e não abre vira sem leitura" '    except FileNotFoundError:
        return [], 0' '    except OSError:
        return [], 0'
  MG=hourly mutant "linha que não é JSON derruba a consulta" '            except (ValueError, RecursionError):
                bad += 1
                continue' '            except KeyboardInterrupt:
                bad += 1
                continue'
  MG=hourly mutant "linha sem t inteiro vira leitura" 'if isinstance(o, dict) and isinstance(o.get("t"), int) and not isinstance(o["t"], bool):' 'if isinstance(o, dict):'
  MG=hourly mutant "--min-pct é ignorado" '"abaixo" if mean < min_pct else "ok"' '"abaixo" if mean < 85.0 else "ok"'
  MG=hourly mutant "exit 0 com hora abaixo ou sem leitura" 'return 0 if res["all_ok"] else 1' 'return 0'
  MG=hourly mutant "o arquivo rotacionado (.1) não é lido" 'for p in (env.readings + ".1", env.readings):' 'for p in (env.readings,):'
  # (ga-2hd02v.7) o login do Claude do nó
  mutant "o gate do Claude que não diz ok não segura o veredito (unknown vira NÓ)" '    if cg != "ok":
        return out("unknown", "claude_unknown",' '    if False:
        return out("unknown", "claude_unknown",'
  mutant "login medido ruim vira NÃO SEI em vez de MINI" 'return out("local", "claude_blocked",' 'return out("unknown", "claude_blocked",'
  mutant "saída do gate diferente de 0 vale como ok (só a linha importa)" 'if p.returncode == 0 and first == "ok":' 'if first == "ok":'
  mutant "linha do gate que só começa com ok vale" 'if p.returncode == 0 and first == "ok":' 'if p.returncode == 0 and first.startswith("ok"):'
  mutant "blocked de qualquer estado vale como login ruim (unreachable e unknown viram MINI)" 'first.startswith(("blocked: logged-out: ", "blocked: expired: ", "blocked: quota: "))' 'first.startswith("blocked: ")'
  mutant "blocked com saída que não é 1 vale como login ruim" 'if p.returncode == 1 and first.startswith(' 'if first.startswith('
  mutant "gate do Claude que estoura o prazo vale como ok" 'return f"unknown:o gate do Claude estourou o prazo ({limit:g}s)"' 'return "ok"'
  mutant "comando do gate do Claude que não executa vale como ok" 'return f"unknown:o gate do Claude não rodou ({ex})"' 'return "ok"'
  mutant "comando do gate do Claude mal configurado vale como ok" 'return f"unknown:{e}"' 'return "ok"'
  mutant "veredito sem a pergunta ao gate do Claude vale como ok" 'return "unknown:o login do Claude do nó não foi perguntado"' 'return "ok"'
  mutant "pergunta ao gate do Claude que levantou exceção vale como ok" 'return f"unknown:a pergunta ao gate do Claude falhou ({type(e).__name__}: {e})"' 'return "ok"'
  mutant "a pergunta ao gate corre DEPOIS da medição (a soma, não o maior)" '        claude = ThreadPoolExecutor(max_workers=1).submit(claude_gate) if args.cmd == "verdict" else None
        res = tick(env, cfg, now, ssh_dest, refresh=ssh_dest is not None)' '        res = tick(env, cfg, now, ssh_dest, refresh=ssh_dest is not None)
        claude = ThreadPoolExecutor(max_workers=1).submit(claude_gate) if args.cmd == "verdict" else None'
  mutant "o bloqueio do Claude grava pause.json (a retomada dependeria de alguém)" '    if cg.startswith("blocked:"):
        return out("local", "claude_blocked",' '    if cg.startswith("blocked:"):
        os.makedirs(env.dir, exist_ok=True); atomic_write(env.pause, "{}")
        return out("local", "claude_blocked",'
  mutant "o step também pergunta ao gate do Claude" 'submit(claude_gate) if args.cmd == "verdict" else None' 'submit(claude_gate) if args.cmd in ("verdict", "step") else None'
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
