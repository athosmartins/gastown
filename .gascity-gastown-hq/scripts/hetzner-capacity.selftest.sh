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
# CONTROLE NEGATIVO: ilegível contado como verde · sem prova de carga · degrau que pula · evidência que vale duas vezes · `present()` que engole erro · veredito sem o
#   gate_done · cap ignorado · `>` no lugar de `>=` na vaga · sessões ilegíveis viram 0 · leitura velha autoriza · leitura sem `state` válida · leitura no futuro autoriza ·
#   vermelho só com CPU E RAM · âmbar vira verde · `max` no lugar de `min` na CPU · estado ilegível recomeça · falha de ssh vira leitura ok · load5 `nan` aceito ·
#   leitura "ok" de cor desconhecida autoriza · state.json não-UTF-8 / aninhado fundo / sem changed_why não tratados · config.json não-UTF-8 · config de fora aninhada ·
#   sem catch-all · catch-all que sai 1 · ssh que não executa vira nó fora · gate_done_bin relativo aceito — cada um é aplicado numa cópia e a bateria TEM que falhar.
# VARIÁVEIS: HC_UNDER_TEST (script a testar) · HC_PY (interpretador; padrão /usr/bin/python3 = o 3.9 do mini) · HC_NO_MUTANTS=1
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
if [ -f "$W/ssh.rc" ] && [ "$(cat "$W/ssh.rc")" != 0 ]; then echo "ssh: connect to host stub port 22: Connection timed out" >&2; exit "$(cat "$W/ssh.rc")"; fi
cat "$W/ssh.out"
EOF
cat > "$W/list-stub" <<'EOF'
#!/bin/sh
W="$(dirname "$0")"
if [ -f "$W/list.rc" ] && [ "$(cat "$W/list.rc")" != 0 ]; then echo "provider: ssh falhou" >&2; exit "$(cat "$W/list.rc")"; fi
i=0; while [ "$i" -lt "$(cat "$W/sessions" 2>/dev/null || echo 0)" ]; do echo "dog-remote-s$i"; i=$((i+1)); done
EOF
chmod +x "$W/ssh-stub" "$W/list-stub"

node() {  # node IDLE_PCT LOAD5 MEM_AVAIL_PCT  → resposta do nó com 16 núcleos, 32 GB, entre os marcadores (e com ruído de .bashrc antes)
  local idle="$1" load="$2" mem="$3" d=$(( $1 * 10 ))
  { echo "Welcome to the stub (ruído de .bashrc)"; echo "@@CAP-BEGIN@@"; echo "ncpu=16"
    echo "stat1=cpu  1000 0 0 1000 0 0 0 0 0 0"; echo "stat2=cpu  $((1000 + 1000 - d)) 0 0 $((1000 + d)) 0 0 0 0 0 0"
    echo "load=0.5 $load 1.0 1/100 12345"
    echo "MemTotal:       32000000 kB"; echo "MemAvailable:   $(( mem * 320000 )) kB"
    echo "@@CAP-END@@"; } > "$W/ssh.out"; rm -f "$W/ssh.rc"
}
sess() { echo "$1" > "$W/sessions"; rm -f "$W/list.rc"; }
mkcfg() {  # mkcfg CAP [released]
  printf '{"default_host":"hetzner","hosts":{"hetzner":{"ssh":"stub","cap":%s,"remote_root":"/r","remote_home":"/h"%s}}}\n' "$1" "${2-,\"real_sessions_released_by\":\"mayor teste\"}" > "$SSHJ"
}
mkshim() { printf '{"city":"/c","gate_done_bin":%s}\n' "${1-\"$GDB\"}" > "$SHIM"; }
newcity() { D="$T/d.$((++nd))"; mkdir -p "$D"; mkcfg 10; mkshim; node 70 3 90; sess 3; rm -f "$W/ssh.calls" "$W/ssh.sleep" "$W/list.rc"; NOW=$T0; }
nd=0
hc() {  # hc ARGS → $OUT (stdout), $RC
  OUT=$(HETZNER_CAPACITY_DIR="$D" GC_SSH_CONFIG="$SSHJ" HETZNER_CAPACITY_SHIM_CONFIG="$SHIM" HETZNER_CAPACITY_NOW="$NOW" \
        HETZNER_CAPACITY_SSH_CMD="[\"$W/ssh-stub\"]" HETZNER_CAPACITY_LIST_CMD="[\"$W/list-stub\"]" "$PY" -I "$P" "$@" 2>"$W/err"); RC=$?
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
  printf '{"require_load_proof":false}' > "$D/config.json"; at 2700; hc --json step
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

if [ -n "${HC_MUTANT:-}" ]; then g_third; g_read; g_step; g_verdict; echo "RESULT $fails/$n"; [ "$fails" = 0 ]; exit $?; fi
g_read; g_step; g_verdict; g_third

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
    local r; r=$(HC_MUTANT=1 HC_UNDER_TEST="$m" bash "$0" 2>&1 | tail -1)
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
}
echo "── $((n - fails))/$n ok"
[ "$fails" = 0 ]
