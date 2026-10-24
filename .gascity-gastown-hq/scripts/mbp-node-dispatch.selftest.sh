#!/usr/bin/env bash
# mbp-node-dispatch.selftest.sh — hermético: bd e gc são stubs (estado JSON em pasta temporária); o despachante é o REAL (wa-node-dispatch.sh), o oráculo é o REAL (mbp-node-capacity.py) nos
# casos de ponta a ponta e um stub nos demais, e o classificador é o stub com veredito escolhido + casos com o real do WA. (ga-w7qwl1.2.1)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: a casca fixa a identidade do MBP (alias -mbp-1..2, template, log, modo pilot SEM gc.routed_to) mesmo com WA_NODE_* no ambiente, inclusive o ORÁCULO · o oráculo manda (Athos no MBP/sem vaga/ilegível/ausente = fica no mini, nada escrito) ·
#   2 slots, MBP_NODE_SLOTS=1, valor ilegível = 1, slot só do MBP · só bead wa-* · despachante ausente = 11 · release só solta bead de alias do MBP · ponta a ponta com o oráculo e o classificador REAIS.
# CONTROLE NEGATIVO: cada mutante troca UMA linha da casca numa cópia e o caso designado tem de reprovar; mutante que sobrevive reprova esta bateria.
# COMO RODAR: bash scripts/mbp-node-dispatch.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/mbp-node-dispatch.sh"
WA_DISPATCH="$HERE/wa-node-dispatch.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-node-disp.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq ausente"; exit 2; }

CITY="$T/city"; WASTORE="$T/wa-store"; PSSTORE="$T/ps-store"; mkdir -p "$CITY/.beads" "$CITY/.gc" "$WASTORE" "$PSSTORE" "$CITY/scripts"
printf '{"prefix":"ga","path":"."}\n{"prefix":"wa","path":"../wa-store"}\n{"prefix":"ps","path":"../ps-store"}\n' > "$CITY/.beads/routes.jsonl"
# a casca acha o despachante, o classificador e o oráculo ao lado dela: as cópias em $CITY/scripts são o que os mutantes alteram sem tocar os originais
cp "$WA_DISPATCH" "$CITY/scripts/wa-node-dispatch.sh"; cp "$HERE/wa-node-classify.py" "$HERE/mbp-node-capacity.py" "$CITY/scripts/"
cp "$HERE/hetzner-rsync-filter.wa.txt" "$HERE/hetzner-mac-only.txt" "$HERE/hetzner-mirror.sh" "$CITY/scripts/"
STATE="$T/state.json"; CALLS="$T/bd.calls"; GCCALLS="$T/gc.calls"; SESS="$T/sessions.json"; CLSOUT="$T/cls.json"; CLSRC="$T/cls.rc"; CAPOUT="$T/cap.json"; CAPRC="$T/cap.rc"
GATEOUT="$T/gate.json"; GATERC="$T/gate.rc"

# ---- stubs (os mesmos do ps-node-dispatch.selftest.sh)
cat > "$T/bd" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
open(os.environ["STUB_CALLS"], "a").write("|".join(a) + "\n")
if a[:1] == ["-C"]: a = a[2:]
st = json.load(open(os.environ["STUB_STATE"]))
cmd, rest = a[0], a[1:]
def save(): json.dump(st, open(os.environ["STUB_STATE"], "w"))
if cmd == "show":
    if os.environ.get("STUB_FAIL_SHOW"): sys.exit(1)
    b = st.get(rest[0])
    if b is None: sys.exit(1)
    print(json.dumps([b])); sys.exit(0)
if cmd == "list":
    if os.environ.get("STUB_FAIL_LIST"): sys.exit(1)
    o = {rest[i]: rest[i + 1] for i in range(len(rest) - 1) if rest[i].startswith("--")}
    print(json.dumps([b for b in st.values() if isinstance(b, dict) and b.get("assignee") == o.get("--assignee") and b.get("status") == o.get("--status")])); sys.exit(0)
if cmd == "comment":
    st[rest[0]].setdefault("comments", []).append(rest[1]); save(); sys.exit(0)
if cmd == "update":
    b = st[rest[0]]; i = 1; sets = {}; unsets = []; ifa = ifs = None
    while i < len(rest):
        k = rest[i]
        if k == "-q": i += 1; continue
        v = rest[i + 1]; i += 2
        if k == "--if-assignee": ifa = v
        elif k == "--if-status": ifs = v
        elif k == "--assignee": sets["assignee"] = v
        elif k == "--status": sets["status"] = v
        elif k == "--set-metadata": kk, vv = v.split("=", 1); b.setdefault("metadata", {})[kk] = vv
        elif k == "--unset-metadata": unsets.append(v)
    if ifa is not None and (b.get("assignee") or "") != ifa: sys.exit(13)
    if ifs is not None and b.get("status") != ifs: sys.exit(13)
    b.update(sets)
    for u in unsets: b.get("metadata", {}).pop(u, None)
    save(); sys.exit(0)
sys.exit(1)
PYEOF
cat > "$T/gc" <<'SHEOF'
#!/bin/sh
echo "$*" >> "$STUB_GCCALLS"
[ "$1 $2" = "session list" ] && { cat "$STUB_SESS"; exit 0; }
[ "$3 $4" = "session list" ] && { cat "$STUB_SESS"; exit 0; }
exit 1
SHEOF
chmod +x "$T/bd" "$T/gc"
# classificador-stub: chamado como `python3 -I <script>`; ignora a bead e devolve o veredito escolhido
cat > "$T/cls.py" <<'PYEOF'
import os, sys
sys.stdin.read()
sys.stdout.write(open(os.environ["STUB_CLSOUT"]).read())
sys.exit(int(open(os.environ["STUB_CLSRC"]).read().strip()))
PYEOF
# oráculo-stub: chamado como `python3 -I <script> --json verdict`; devolve o JSON de CAPOUT com o rc de CAPRC
cat > "$T/cap.py" <<'PYEOF'
import os, sys
sys.stdout.write(open(os.environ["STUB_CAPOUT"]).read())
sys.exit(int(open(os.environ["STUB_CAPRC"]).read().strip()))
PYEOF
# gate-stub (para o oráculo REAL): imprime GATEOUT e sai com GATERC
cat > "$T/gate.sh" <<'SHEOF'
#!/bin/sh
cat "$STUB_GATEOUT"; exit "$(cat "$STUB_GATERC")"
SHEOF
chmod +x "$T/gate.sh"

export STUB_CALLS="$CALLS" STUB_STATE="$STATE" STUB_GCCALLS="$GCCALLS" STUB_SESS="$SESS" STUB_CLSOUT="$CLSOUT" STUB_CLSRC="$CLSRC" STUB_CAPOUT="$CAPOUT" STUB_CAPRC="$CAPRC" STUB_GATEOUT="$GATEOUT" STUB_GATERC="$GATERC"
export GC_CITY="$CITY" MBP_NODE_BD="$T/bd" MBP_NODE_GC="$T/gc" MBP_NODE_CLASSIFY="$T/cls.py" MBP_NODE_CAPACITY="$T/cap.py" MBP_NODE_TIMEOUT=20

NODE_TEXT='{"verdict":"node","basis":"text","reasons":["prova-no-texto:1-teste(s)+1-codigo"],"paths":[],"tests":[],"info":[]}'
cls() { printf '%s' "$1" > "$CLSOUT"; printf '%s' "$2" > "$CLSRC"; }
cap() { printf '%s' "$1" > "$CAPOUT"; printf '%s' "$2" > "$CAPRC"; }
gate() { printf '%s' "$1" > "$GATEOUT"; printf '%s' "$2" > "$GATERC"; }
CAP_NODE='{"verdict":"node","free":2,"reason":"ok"}'; CAP_LOCAL='{"verdict":"local","reason":"gate","detail":"Athos está no MBP"}'
GATE_OK='{"cap":2,"host":"mbp","ok":true,"reason":"Athos fora e MBP saudável","slot_cap":3}'; GATE_NO='{"cap":2,"host":"mbp","ok":false,"reason":"Athos está no MBP (presença=uso)","slot_cap":null}'
fresh() { # fresh [json mesclado na wa-t1]
  printf '{"wa-t1":{"id":"wa-t1","title":"t","status":"open","assignee":"","metadata":{}},"wa-t2":{"id":"wa-t2","title":"t2","status":"open","assignee":"","metadata":{}},"ps-t1":{"id":"ps-t1","title":"t","status":"open","assignee":"","metadata":{}},"ga-x":{"id":"ga-x","title":"t","status":"open","assignee":"","metadata":{}}}' > "$STATE"
  if [ -n "${1:-}" ]; then jq -c --argjson m "$1" '."wa-t1" += $m' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; fi
  : > "$CALLS"; : > "$GCCALLS"; rm -f "$CITY/.gc/mbp-node-route.jsonl" "$CITY/.gc/wa-node-route.jsonl"; echo '{"ok":true,"sessions":[]}' > "$SESS"; cls "$NODE_TEXT" 0; cap "$CAP_NODE" 0; gate "$GATE_OK" 0
  unset STUB_FAIL_SHOW STUB_FAIL_LIST MBP_NODE_SLOTS MBP_NODE_DISPATCH MBP_NODE_GATE_CMD MBP_NODE_SESSIONS_CMD
  unset WA_NODE_ALIAS WA_NODE_ROUTE_TEMPLATE WA_NODE_CLASSIFY WA_NODE_LOG WA_NODE_SELF WA_NODE_STORY WA_NODE_SPAWN WA_NODE_SLOTS WA_NODE_ALIAS_PREFIX WA_NODE_CAPACITY
  export MBP_NODE_CAPACITY="$T/cap.py"
}
SCRIPT="$REAL"; OUT=""; RC=0
d() { OUT=$("$SCRIPT" "$@" 2>&1); RC=$?; }
wrote() { grep -q '^-C|[^|]*|update|' "$CALLS" 2>/dev/null; }
bead() { jq -r "$1" "$STATE"; }
expect_rc() { # expect_rc <rótulo> <rc esperado> [w0 = nada escrito]
  if [ "$RC" != "$2" ]; then bad "$1 (rc=$RC, esperado $2; saída: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200))"; return 1; fi
  if [ "${3:-}" = w0 ] && wrote; then bad "$1 (rc ok, mas houve escrita: $(grep update "$CALLS" | head -n 1))"; return 1; fi
  ok "$1"
}
busy() { # busy <id> <alias>: uma bead em andamento do alias
  jq -c --arg id "$1" --arg a "$2" '. + {($id):{"id":$id,"status":"in_progress","assignee":$a,"metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
}
MBPLOG="$CITY/.gc/mbp-node-route.jsonl"; WALOG="$CITY/.gc/wa-node-route.jsonl"

# ---- apply: o caminho feliz carimba a identidade DO MBP
fresh; d apply wa-t1
expect_rc "apply: bead wa livre + node -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".status')" = in_progress ] && [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"]')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"] // ""')" = "" ] && ok "apply: dono wa-worker-remote-mbp-1, em andamento, marca pilot.wa_node_alias = o dono, SEM gc.routed_to (o pool do MBP não a vê: demanda zero)" || bad "apply: estado: $(jq -c '."wa-t1"' "$STATE")"
bead '."wa-t1".comments[0]' | grep -q 'ga-w7qwl1.2.1' && bead '."wa-t1".comments[0]' | grep -q 'mbp-node-dispatch.sh release wa-t1' && ok "apply: o comentário da bead cita a história do MBP e o release do MBP (WA_NODE_SELF/WA_NODE_STORY)" || bad "apply: comentário: $(bead '."wa-t1".comments[0]')"
[ -s "$MBPLOG" ] && [ ! -e "$WALOG" ] && ok "apply: a decisão vai para mbp-node-route.jsonl e NÃO para o log do WA/Hetzner" || bad "apply: logs: mbp=$([ -s "$MBPLOG" ] && echo sim || echo não) wa=$([ -e "$WALOG" ] && echo existe || echo não)"
# ---- um ambiente com as variáveis do WA/Hetzner não desvia nada — inclusive o oráculo
fresh; WA_NODE_ALIAS=wa-worker-remote-1 WA_NODE_ALIAS_PREFIX=wa-worker-remote- WA_NODE_ROUTE_TEMPLATE=wa-worker-remote WA_NODE_CLASSIFY=/bin/false WA_NODE_LOG="$WALOG" WA_NODE_SPAWN=pool WA_NODE_SLOTS=3 d apply wa-t1
expect_rc "ambiente com WA_NODE_* (alias, prefixo, rota, classificador, log do WA, modo pool, 3 slots): a bead vai ao MBP -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"]')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"] // ""')" = "" ] && [ -s "$MBPLOG" ] && [ ! -e "$WALOG" ] && ok "ambiente do WA: alias, modo pilot e log continuam os do MBP" || bad "ambiente do WA desviou: $(jq -c '."wa-t1"' "$STATE") mbp=$([ -s "$MBPLOG" ] && echo sim || echo não) wa=$([ -e "$WALOG" ] && echo existe || echo não)"
# O CASO CENTRAL: um oráculo do Hetzner herdado no ambiente diz "node"; o do MBP diz "local" (Athos no MBP). Quem manda é o do MBP: nada é escrito.
cat > "$T/cap-hz.py" <<'PYEOF'
import sys
sys.stdout.write('{"verdict":"node","free":6,"reason":"ok"}')
sys.exit(0)
PYEOF
fresh; cap "$CAP_LOCAL" 1; WA_NODE_CAPACITY="$T/cap-hz.py" d apply wa-t1
expect_rc "oráculo do Hetzner herdado (WA_NODE_CAPACITY) diz node, o do MBP diz local -> 12 sem escrita" 12 w0

# ---- só bead wa-*
fresh; d apply ps-t1;  expect_rc "apply: bead ps-* -> 11 sem escrita e sem chamar o bd" 11 w0; [ ! -s "$CALLS" ] && ok "apply: ps-* não chegou a chamar o bd" || bad "apply: ps-* chamou o bd: $(head -n 2 "$CALLS")"
fresh; d check ps-t1;  expect_rc "check: bead ps-* -> 11" 11 w0
fresh; d release ps-t1; expect_rc "release: bead ps-* -> 11" 11 w0
fresh; d apply "";      expect_rc "apply: id vazio -> 11" 11 w0
fresh; d apply;         expect_rc "sem argumentos -> uso (2)" 2
fresh; d apply wa-t1 --dry-run; expect_rc "apply --dry-run -> 0 sem escrita" 0 w0
# ---- despachante real ausente
fresh; MBP_NODE_DISPATCH="$T/nao-existe.sh" d apply wa-t1; expect_rc "despachante real ausente -> 11 sem escrita" 11 w0

# ---- 2 slots do MBP (e só do MBP)
fresh; busy wa-b1 wa-worker-remote-mbp-1; d apply wa-t1
expect_rc "1º slot ocupado (bead em andamento do -mbp-1) -> a bead vai ao 2º slot -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-2 ] && ok "2 slots: a bead foi ao wa-worker-remote-mbp-2" || bad "2 slots: dono $(bead '."wa-t1".assignee')"
fresh; busy wa-b1 wa-worker-remote-mbp-1; busy wa-b2 wa-worker-remote-mbp-2; d apply wa-t1
expect_rc "os 2 slots ocupados -> 12 sem escrita (não há 3º)" 12 w0
fresh; busy wa-b1 wa-worker-remote-mbp-1; MBP_NODE_SLOTS=1 d apply wa-t1
expect_rc "MBP_NODE_SLOTS=1 com o -mbp-1 ocupado -> 12 sem escrita" 12 w0
fresh; busy wa-b1 wa-worker-remote-mbp-1; MBP_NODE_SLOTS=2 d apply wa-t1
expect_rc "MBP_NODE_SLOTS=2 com o -mbp-1 ocupado -> 0" 0
fresh; busy wa-b1 wa-worker-remote-mbp-1; MBP_NODE_SLOTS=3 d apply wa-t1
expect_rc "MBP_NODE_SLOTS=3 (acima do teto do agente) vale 1 slot: -mbp-1 ocupado -> 12 sem escrita" 12 w0
fresh; busy wa-b1 wa-worker-remote-mbp-1; MBP_NODE_SLOTS= d apply wa-t1
expect_rc "MBP_NODE_SLOTS definido e vazio vale 1 slot (não 'sem valor'): -mbp-1 ocupado -> 12 sem escrita" 12 w0
# ---- o slot do MBP é só do MBP
fresh; busy wa-hz wa-worker-remote-1; d apply wa-t1
expect_rc "bead em andamento do wa-worker-remote-1 (Hetzner) NÃO ocupa o slot do MBP -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","closed":false,"alias":"wa-worker-remote-1"}]}' > "$SESS"
d apply wa-t1; expect_rc "sessão ativa do wa-worker-remote (Hetzner) NÃO ocupa o slot do MBP -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker","state":"active","alias":"wa-worker-adhoc-1"}]}' > "$SESS"
d apply wa-t1; expect_rc "wa-worker do mini ativo não ocupa o slot do MBP -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote-mbp","state":"active","closed":false,"alias":"wa-worker-remote-mbp-1"},{"template":"wa-worker-remote-mbp","state":"active","closed":false,"alias":"wa-worker-remote-mbp-2"}]}' > "$SESS"
d apply wa-t1; expect_rc "2 sessões ativas do wa-worker-remote-mbp -> 12 sem escrita" 12 w0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote-mbp","state":"asleep","closed":false,"alias":"wa-worker-remote-mbp-1"}]}' > "$SESS"
d apply wa-t1; expect_rc "sessão do wa-worker-remote-mbp DORMINDO não segura o slot (o Pilot a acorda) -> 0" 0
# ---- o oráculo de capacidade do MBP manda (modo pilot): sem vaga, ilegível ou ausente a bead fica no mini e nada é escrito
fresh; cap "$CAP_LOCAL" 1; d apply wa-t1; expect_rc "oráculo diz local (rc 1: Athos no MBP, pausa, sem saúde, bandeira off) -> 12 sem escrita" 12 w0
fresh; cap '{"verdict":"unknown","reason":"gate_ilegivel"}' 2; d apply wa-t1; expect_rc "oráculo diz unknown (rc 2) -> 11 sem escrita" 11 w0
fresh; cap '{"verdict":"node","free":0}' 0; d apply wa-t1; expect_rc "oráculo diz node mas sem vaga livre (free 0) -> 11 sem escrita" 11 w0
fresh; cap 'isto nao e json' 0; d apply wa-t1; expect_rc "oráculo com saída ilegível -> 11 sem escrita" 11 w0
fresh; cap "$CAP_NODE" 3; d apply wa-t1; expect_rc "oráculo que sai com rc fora de 0/1 -> 11 sem escrita" 11 w0
fresh; MBP_NODE_CAPACITY="$T/nao-existe.py" d apply wa-t1; expect_rc "oráculo ausente -> 11 sem escrita" 11 w0
# ---- bead que já tem rota/dono não é carimbada de novo
fresh '{"metadata":{"gc.routed_to":"wa-worker-remote"}}'; d apply wa-t1; expect_rc "bead com a rota do Hetzner -> 12 sem escrita" 12 w0
fresh '{"metadata":{"gc.routed_to":"wa-worker-remote-mbp"},"assignee":"wa-worker-remote-mbp-1","status":"in_progress"}'; d apply wa-t1; expect_rc "bead que já é do MBP -> 12 sem escrita" 12 w0
fresh '{"assignee":"wa-worker-remote-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"wa-worker-remote-1"}}'; d apply wa-t1; expect_rc "bead que já é do nó do Hetzner -> 12 sem escrita" 12 w0
fresh '{"metadata":{"gc.routed_to":"wa-worker"}}'; d apply wa-t1; expect_rc "bead com a rota do pool do mini (wa-worker) -> 12 sem escrita" 12 w0
# ---- release
fresh '{"assignee":"wa-worker-remote-mbp-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"wa-worker-remote-mbp-1"}}'; d release wa-t1
expect_rc "release: bead do alias do MBP com a marca do Pilot (a forma que o apply escreve) -> 0" 0
[ -z "$(bead '."wa-t1".assignee')" ] && [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"] // ""')" = "" ] && ok "release: dono e marca soltos" || bad "release: estado: $(jq -c '."wa-t1"' "$STATE")"
fresh '{"assignee":"wa-worker-remote-mbp-2","status":"in_progress","metadata":{"pilot.wa_node_alias":"wa-worker-remote-mbp-2"}}'; d release wa-t1
expect_rc "release: bead do 2º alias do MBP -> 0" 0
fresh '{"assignee":"wa-worker-remote-mbp-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"wa-worker-remote-mbp-2"}}'; d release wa-t1
expect_rc "release: marca de OUTRO alias -> 12 sem escrita" 12 w0
fresh '{"assignee":"wa-worker-remote-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"wa-worker-remote-1"}}'; d release wa-t1
expect_rc "release: bead do alias do Hetzner (wa-worker-remote-1) -> 12 sem escrita (não é do MBP)" 12 w0
fresh '{"assignee":"wa-worker-remote-mbp-3","status":"in_progress","metadata":{"pilot.wa_node_alias":"wa-worker-remote-mbp-3"}}'; d release wa-t1
expect_rc "release: alias -mbp-3 tem a forma <prefixo><dígito> e solta (a bead não fica presa se o N baixar) -> 0" 0
fresh '{"assignee":"wa-worker-remote-mbp-1","status":"in_progress","metadata":{"gc.routed_to":"wa-worker"}}'; d release wa-t1
expect_rc "release: dono do MBP mas rota de outro pool -> 12 sem escrita" 12 w0

# ---- ponta a ponta com o ORÁCULO REAL (sem MBP_NODE_CAPACITY): gate-stub + sessões-stub
e2e() { fresh; unset MBP_NODE_CAPACITY; export MBP_NODE_GATE_CMD="[\"$T/gate.sh\"]" MBP_NODE_SESSIONS_CMD="[\"$T/gc\",\"--city\",\"x\",\"session\",\"list\",\"--json\"]"; }
e2e; d apply wa-t1; expect_rc "oráculo real: gate libera (Athos fora, slot_cap 3, cap 2) -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && ok "oráculo real: dono wa-worker-remote-mbp-1" || bad "oráculo real: $(jq -c '."wa-t1"' "$STATE")"
e2e; gate "$GATE_NO" 1; d apply wa-t1; expect_rc "oráculo real: gate RECUSA (Athos está no MBP) -> 12 sem escrita" 12 w0
e2e; gate 'texto sem json' 1; d apply wa-t1; expect_rc "oráculo real: gate sem JSON (host fora da config) -> 11 sem escrita" 11 w0
e2e; gate '' 0; d apply wa-t1; expect_rc "oráculo real: gate com saída vazia e rc 0 -> 11 sem escrita" 11 w0
e2e; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":null}' 0; d apply wa-t1; expect_rc "oráculo real: ok com slot_cap nulo (host sem presence_gate) -> 11 sem escrita" 11 w0
e2e; gate "$GATE_OK" 0; echo 'não é json' > "$SESS"; d apply wa-t1; expect_rc "oráculo real: gate libera mas a lista de sessões é ilegível -> 11 sem escrita" 11 w0
e2e; gate "$GATE_OK" 0; MBP_NODE_SLOTS=1 d apply wa-t1; expect_rc "oráculo real + 1 slot -> 0" 0
unset MBP_NODE_GATE_CMD MBP_NODE_SESSIONS_CMD
# ---- o classificador REAL do WA, ponta a ponta (sem MBP_NODE_CLASSIFY): o padrão da casca aponta para scripts/wa-node-classify.py
fresh '{"description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em tests/test_foo_parser.py."}'
REAL_CLS_SAVED="$MBP_NODE_CLASSIFY"; unset MBP_NODE_CLASSIFY; d check wa-t1; expect_rc "classificador real: código + teste citados -> node (0)" 0 w0
printf '%s' "$OUT" | grep -q '"verdict": "node"' && ok "classificador real: a saída é a do classificador do WA" || bad "classificador real: saída $OUT"
fresh '{"description":"lib/foo.py lê queue.db; tests/test_foo.py"}'
d check wa-t1; expect_rc "classificador real: cita banco (queue.db) -> mini (10)" 10 w0
fresh '{"description":"Em lib/foo_parser.py a funcao quebra. Teste em tests/test_foo_parser.py."}'
d apply wa-t1; expect_rc "classificador real + apply: bead com código e teste -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && ok "classificador real + apply: dono wa-worker-remote-mbp-1" || bad "classificador real + apply: $(jq -c '."wa-t1"' "$STATE")"
export MBP_NODE_CLASSIFY="$REAL_CLS_SAVED"

# ---- controle negativo: cada mutante troca UMA linha da casca (numa cópia) e o caso designado tem de reprovar
# O mutante mora em $CITY/scripts/mbp-node-dispatch.mut.sh (ao lado do despachante, do classificador e do oráculo copiados, que é como a casca os acha).
mk_mutant() { # mk_mutant <nome> <trecho original> <trecho novo> -> $CITY/scripts/mbp-node-dispatch.mut.sh; rc 1 se o trecho não existe
  python3 -I - "$REAL" "$CITY/scripts/mbp-node-dispatch.mut.sh" "$2" "$3" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  chmod +x "$CITY/scripts/mbp-node-dispatch.mut.sh"
}
mutant() { # mutant <nome> <trecho original> <trecho novo> <preparo: função de cenário> <rc esperado> <verificação: função que devolve 0 se o estado é o certo>
  local name="$1"
  mk_mutant "$name" "$2" "$3" || { bad "mutante $name: o trecho original não existe (a casca mudou? atualize o mutante)"; return; }
  $4; SCRIPT="$REAL"; d $SC_ARGS
  if [ "$RC" != "$5" ] || ! $6; then bad "mutante $name VAZIO: a casca ORIGINAL já reprova o caso designado (rc=$RC, esperado $5)"; return; fi
  $4; SCRIPT="$CITY/scripts/mbp-node-dispatch.mut.sh"; d $SC_ARGS
  if [ "$RC" = "$5" ] && $6; then bad "mutante $name SOBREVIVEU (o caso designado ainda passa)"; else ok "mutante $name morreu"; fi
  SCRIPT="$REAL"
}
sc_apply()     { fresh; SC_ARGS="apply wa-t1"; }
sc_ps()        { fresh; SC_ARGS="apply ps-t1"; }
sc_missing()   { fresh; SC_ARGS="apply wa-t1"; export MBP_NODE_DISPATCH="$CITY/scripts/nao-existe.sh"; }
sc_env()       { fresh; SC_ARGS="apply wa-t1"; export WA_NODE_ALIAS=wa-worker-remote-1 WA_NODE_ALIAS_PREFIX=wa-worker-remote- WA_NODE_ROUTE_TEMPLATE=wa-worker-remote WA_NODE_CLASSIFY=/bin/false WA_NODE_LOG="$WALOG"; }
sc_alias_env() { fresh; SC_ARGS="apply wa-t1"; export WA_NODE_ALIAS=wa-worker-remote-1; }
sc_pool_env()  { fresh; SC_ARGS="apply wa-t1"; export WA_NODE_SPAWN=pool; }
sc_cap_env()   { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_LOCAL" 1; export WA_NODE_CAPACITY="$T/cap-hz.py"; }
sc_cap_default() { e2e; gate "$GATE_NO" 1; SC_ARGS="apply wa-t1"; }
# 1 slot e uma sessão viva do TEMPLATE do MBP com um alias que não é do slot: só o template (a rota) a prende; com o template do Hetzner o slot pareceria livre
sc_tpl()       { fresh; SC_ARGS="apply wa-t1"; export MBP_NODE_SLOTS=1; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote-mbp","state":"active","closed":false,"alias":"outro-alias"}]}' > "$SESS"; }
sc_tpl_env()   { sc_tpl; export WA_NODE_ROUTE_TEMPLATE=wa-worker-remote; }
# oráculo com 5 vagas: as 2 beads já atribuídas (sem sessão) descontam 2, sobram 3 — só o nº de slots decide (com free 2 o oráculo recusaria antes e o mutante nunca seria exercido)
sc_slots_env() { fresh; SC_ARGS="apply wa-t1"; busy wa-b1 wa-worker-remote-mbp-1; busy wa-b2 wa-worker-remote-mbp-2; cap '{"verdict":"node","free":5,"reason":"ok"}' 0; export WA_NODE_SLOTS=3; }
sc_two()       { fresh; SC_ARGS="apply wa-t1"; busy wa-b1 wa-worker-remote-mbp-1; }
sc_bad3()      { fresh; SC_ARGS="apply wa-t1"; busy wa-b1 wa-worker-remote-mbp-1; busy wa-b2 wa-worker-remote-mbp-2; cap '{"verdict":"node","free":5,"reason":"ok"}' 0; export MBP_NODE_SLOTS=3; }
sc_empty()     { fresh; SC_ARGS="apply wa-t1"; busy wa-b1 wa-worker-remote-mbp-1; export MBP_NODE_SLOTS=; }
st_mbp()       { [ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"]')" = wa-worker-remote-mbp-1 ]; }
st_pilot()     { [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"]')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"] // ""')" = "" ]; }
st_log()       { [ -s "$MBPLOG" ] && [ ! -e "$WALOG" ]; }
st_clean()     { ! wrote; }
st_second()    { [ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-2 ]; }
mutant prefixo-do-hetzner   'export WA_NODE_ALIAS_PREFIX="wa-worker-remote-mbp-"'   'export WA_NODE_ALIAS_PREFIX="wa-worker-remote-"'   sc_apply 0 st_mbp
mutant rota-do-hetzner      'export WA_NODE_ROUTE_TEMPLATE="wa-worker-remote-mbp"'  'export WA_NODE_ROUTE_TEMPLATE="wa-worker-remote"'  sc_tpl 12 st_clean
mutant log-do-hetzner       '${MBP_NODE_LOG:-$CITY/.gc/mbp-node-route.jsonl}'       '${MBP_NODE_LOG:-$CITY/.gc/wa-node-route.jsonl}'    sc_apply 0 st_log
mutant prefixo-do-ambiente-vence 'export WA_NODE_ALIAS_PREFIX="wa-worker-remote-mbp-"' 'export WA_NODE_ALIAS_PREFIX="${WA_NODE_ALIAS_PREFIX:-wa-worker-remote-mbp-}"' sc_env 0 st_mbp
mutant rota-do-ambiente-vence 'export WA_NODE_ROUTE_TEMPLATE="wa-worker-remote-mbp"' 'export WA_NODE_ROUTE_TEMPLATE="${WA_NODE_ROUTE_TEMPLATE:-wa-worker-remote-mbp}"' sc_tpl_env 12 st_clean
mutant alias-unico-herdado  'unset WA_NODE_ALIAS'                                    ':'                                                  sc_alias_env 0 st_mbp
mutant oraculo-do-ambiente-vence 'export WA_NODE_CAPACITY="${MBP_NODE_CAPACITY:-$HERE/mbp-node-capacity.py}"' 'export WA_NODE_CAPACITY="${WA_NODE_CAPACITY:-${MBP_NODE_CAPACITY:-$HERE/mbp-node-capacity.py}}"' sc_cap_env 12 st_clean
mutant oraculo-do-hetzner   '$HERE/mbp-node-capacity.py}"'                           '$HERE/hetzner-capacity.py}"'                        sc_cap_default 12 st_clean
mutant modo-pool            'export WA_NODE_SPAWN="pilot"'                           'export WA_NODE_SPAWN="pool"'                        sc_apply 0 st_pilot
mutant modo-do-ambiente-vence 'export WA_NODE_SPAWN="pilot"'                         'export WA_NODE_SPAWN="${WA_NODE_SPAWN:-pilot}"'     sc_pool_env 0 st_pilot
mutant slots-do-ambiente-vence 'export WA_NODE_SLOTS="$SLOTS"'                       'export WA_NODE_SLOTS="${WA_NODE_SLOTS:-$SLOTS}"'    sc_slots_env 12 st_clean
mutant um-slot-so           'SLOTS=2
if'                                                                                  'SLOTS=1
if'                                                                                  sc_two 0 st_second
mutant slot-ilegivel-vale-o-valor 'SLOTS=1; say "MBP_NODE_SLOTS='"'"'$MBP_NODE_SLOTS'"'"' não é 1 nem 2'  'SLOTS="$MBP_NODE_SLOTS"; say "MBP_NODE_SLOTS='"'"'$MBP_NODE_SLOTS'"'"' não é 1 nem 2' sc_bad3 12 st_clean
mutant slots-vazio-vale-padrao '"${MBP_NODE_SLOTS+set}" = set'                       '"${MBP_NODE_SLOTS:+set}" = set'                     sc_empty 12 st_clean
mutant sem-guarda-de-prefixo 'case "$2" in wa-*) ;; *) say "$2 não é uma bead do WA (prefixo wa-): não decido — fica onde está"; exit 11 ;; esac' ':' sc_ps 11 st_clean
mutant sem-guarda-do-despachante '[ -x "$REAL" ] || { say "despachante $REAL ausente ou não executável — fica no mini"; exit 11; }' ':' sc_missing 11 st_clean
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
