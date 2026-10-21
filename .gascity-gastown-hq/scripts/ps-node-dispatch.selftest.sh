#!/usr/bin/env bash
# ps-node-dispatch.selftest.sh — hermético: bd e gc são stubs (estado JSON em pasta temporária); o despachante é o REAL (wa-node-dispatch.sh) e o classificador é o stub com veredito escolhido + casos com o real do PS. (ga-2hd02v.4)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: a casca aponta o despachante do WA para o PS (alias ps-worker-remote-1, classificador do PS, log ps-node-route.jsonl) no modo PILOT (a bead leva dono + marca pilot.wa_node_alias, SEM gc.routed_to: o pool do PS
#   não a enxerga e quem abre a sessão é o Pilot) · um ambiente com as variáveis do WA (alias, rota, modo pool, slots) NÃO desvia nada · o oráculo de capacidade do nó manda: sem vaga/ilegível a bead fica no mini · só bead ps-* (wa-*, ga-*, vazio: 11 sem nenhuma chamada) · despachante ausente = 11 · o slot do PS é independente do slot do WA (sessão e bead do WA não ocupam o do PS, e
#   o contrário vale) · release só solta bead do alias E da rota do PS (a do WA não é tocada) · bead com rota do WA não é carimbada de novo · o classificador real do PS manda ao nó uma bead com código + teste e deixa
#   no mini a que cita banco.
# CONTROLE NEGATIVO: cada mutante troca UMA linha da casca numa cópia e o caso designado tem de reprovar; mutante que sobrevive reprova esta bateria.
# COMO RODAR: bash scripts/ps-node-dispatch.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/ps-node-dispatch.sh"
WA_DISPATCH="$HERE/wa-node-dispatch.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/ps-node-disp.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq ausente"; exit 2; }

CITY="$T/city"; PSSTORE="$T/ps-store"; WASTORE="$T/wa-store"; mkdir -p "$CITY/.beads" "$CITY/.gc" "$PSSTORE" "$WASTORE" "$CITY/scripts"
printf '{"prefix":"ga","path":"."}\n{"prefix":"ps","path":"../ps-store"}\n{"prefix":"wa","path":"../wa-store"}\n' > "$CITY/.beads/routes.jsonl"
# a casca descobre o despachante real e o classificador ao lado dela: a cópia em $CITY/scripts é o que os mutantes alteram sem tocar o original
cp "$WA_DISPATCH" "$CITY/scripts/wa-node-dispatch.sh"; cp "$HERE/ps-node-classify.py" "$CITY/scripts/ps-node-classify.py"
cp "$HERE/hetzner-rsync-filter.ps.txt" "$HERE/hetzner-mac-only.ps.txt" "$HERE/hetzner-scrape-eligible.txt" "$CITY/scripts/"
STATE="$T/state.json"; CALLS="$T/bd.calls"; GCCALLS="$T/gc.calls"; SESS="$T/sessions.json"; CLSOUT="$T/cls.json"; CLSRC="$T/cls.rc"; CAPOUT="$T/cap.json"; CAPRC="$T/cap.rc"

# ---- stubs (os mesmos do wa-node-dispatch.selftest.sh)
# ---- stubs
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
    if os.environ.get("STUB_FAIL_SHOW_AFTER_UPDATE") and any("|update|" in l for l in open(os.environ["STUB_CALLS"])): sys.exit(1)   # a releitura depois da escrita falha (a primeira leitura passou)
    b = st.get(rest[0])
    if os.environ.get("STUB_SHOW_OTHER"): b = dict(b, id="wa-other")
    if b is None: sys.exit(1)
    print(json.dumps([b])); sys.exit(0)
if cmd == "list":
    if os.environ.get("STUB_FAIL_LIST"): sys.exit(1)
    if os.environ.get("STUB_LIST_GARBAGE"): print("not a list"); sys.exit(0)
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
    rc = int(os.environ.get("STUB_UPDATE_RC", "0"))
    if rc: sys.exit(rc)
    land = 0 if unsets else int(os.environ.get("STUB_LAND_RC", "0"))   # a escrita PEGA e só então o processo sai com este código (prazo estourado, morto): a resposta se perdeu; nunca vale para o desfazer
    if unsets and os.environ.get("STUB_UNDO_RC"): sys.exit(int(os.environ["STUB_UNDO_RC"]))   # só o desfazer leva --unset-metadata
    if ifa is not None and (b.get("assignee") or "") != ifa: sys.exit(13)
    if ifs is not None and b.get("status") != ifs: sys.exit(13)
    if os.environ.get("STUB_PARTIAL_UPDATE"):   # pegou só o dono (e a rota): o status não muda, a conferência reprova e a bead fica suja; o desfazer limpa dono e rota
        b["assignee"] = sets.get("assignee", b.get("assignee"))
        for u in unsets: b.get("metadata", {}).pop(u, None)
        save(); sys.exit(land)
    if os.environ.get("STUB_NOOP_UPDATE"): sys.exit(0)
    b.update(sets)
    for u in unsets: b.get("metadata", {}).pop(u, None)
    save(); sys.exit(land)
sys.exit(1)
PYEOF
cat > "$T/gc" <<'SHEOF'
#!/bin/sh
echo "$*" >> "$STUB_GCCALLS"
[ -z "${STUB_FAIL_GC:-}" ] || exit 1
[ "$1 $2" = "session list" ] && { sleep "${STUB_GC_SLEEP:-0}"; cat "$STUB_SESS"; exit 0; }
exit 1
SHEOF
chmod +x "$T/bd" "$T/gc"
# o classificador-stub é chamado como `python3 -I <script>` (como o real): ignora a bead e devolve o veredito escolhido
# oráculo de capacidade (hetzner-capacity.py verdict): chamado como `python3 -I <script> --json verdict`; devolve o JSON de CAPOUT com o rc de CAPRC
cat > "$T/cap.py" <<'PYEOF'
import os, sys
sys.stdout.write(open(os.environ["STUB_CAPOUT"]).read())
sys.exit(int(open(os.environ["STUB_CAPRC"]).read().strip()))
PYEOF
cat > "$T/cls.py" <<'PYEOF'
import os, sys
sys.stdin.read()
sys.stdout.write(open(os.environ["STUB_CLSOUT"]).read())
sys.exit(int(open(os.environ["STUB_CLSRC"]).read().strip()))
PYEOF


export STUB_CALLS="$CALLS" STUB_STATE="$STATE" STUB_GCCALLS="$GCCALLS" STUB_SESS="$SESS" STUB_CLSOUT="$CLSOUT" STUB_CLSRC="$CLSRC" STUB_CAPOUT="$CAPOUT" STUB_CAPRC="$CAPRC"
export GC_CITY="$CITY" PS_NODE_BD="$T/bd" PS_NODE_GC="$T/gc" PS_NODE_CLASSIFY="$T/cls.py" PS_NODE_CAPACITY="$T/cap.py" PS_NODE_TIMEOUT=20

NODE_TEXT='{"verdict":"node","basis":"text","reasons":["prova-no-texto:1-teste(s)+1-codigo"],"paths":[],"tests":[],"info":[]}'
MINI='{"verdict":"mini","basis":"","reasons":["caminho-fora-do-filtro:market.db"],"paths":[],"tests":[],"info":[]}'
cls() { printf '%s' "$1" > "$CLSOUT"; printf '%s' "$2" > "$CLSRC"; }
cap() { printf '%s' "$1" > "$CAPOUT"; printf '%s' "$2" > "$CAPRC"; }
CAP_NODE='{"verdict":"node","free":2,"reason":"ok"}'; CAP_LOCAL='{"verdict":"local","reason":"cpu do nó acima do teto"}'
fresh() { # fresh [json mesclado na ps-t1]
  printf '{"ps-t1":{"id":"ps-t1","title":"t","status":"open","assignee":"","metadata":{}},"wa-t1":{"id":"wa-t1","title":"t","status":"open","assignee":"","metadata":{}},"ga-x":{"id":"ga-x","title":"t","status":"open","assignee":"","metadata":{}}}' > "$STATE"
  if [ -n "${1:-}" ]; then jq -c --argjson m "$1" '."ps-t1" += $m' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; fi
  : > "$CALLS"; : > "$GCCALLS"; rm -f "$CITY/.gc/ps-node-route.jsonl" "$CITY/.gc/wa-node-route.jsonl"; echo '{"ok":true,"sessions":[]}' > "$SESS"; cls "$NODE_TEXT" 0; cap "$CAP_NODE" 0
  unset STUB_FAIL_SHOW STUB_UPDATE_RC STUB_NOOP_UPDATE STUB_FAIL_GC STUB_LAND_RC STUB_FAIL_LIST
  unset WA_NODE_ALIAS WA_NODE_ROUTE_TEMPLATE WA_NODE_CLASSIFY WA_NODE_LOG WA_NODE_SELF WA_NODE_STORY PS_NODE_DISPATCH WA_NODE_SPAWN WA_NODE_SLOTS WA_NODE_ALIAS_PREFIX
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
PSLOG="$CITY/.gc/ps-node-route.jsonl"; WALOG="$CITY/.gc/wa-node-route.jsonl"

# ---- apply: o caminho feliz carimba a identidade DO PS
fresh; d apply ps-t1
expect_rc "apply: bead ps livre + node -> 0" 0
[ "$(bead '."ps-t1".assignee')" = ps-worker-remote-1 ] && [ "$(bead '."ps-t1".status')" = in_progress ] && [ "$(bead '."ps-t1".metadata["pilot.wa_node_alias"]')" = ps-worker-remote-1 ] && [ "$(bead '."ps-t1".metadata["gc.routed_to"] // ""')" = "" ] && ok "apply: dono ps-worker-remote-1, em andamento, marca pilot.wa_node_alias = o dono, SEM gc.routed_to (o pool não a vê; o Pilot abre a sessão)" || bad "apply: estado: $(jq -c '."ps-t1"' "$STATE")"
bead '."ps-t1".comments[0]' | grep -q 'ga-2hd02v.4' && bead '."ps-t1".comments[0]' | grep -q 'ps-node-dispatch.sh release ps-t1' && ok "apply: o comentário da bead cita a história do PS e o release do PS (WA_NODE_SELF/WA_NODE_STORY)" || bad "apply: comentário: $(bead '."ps-t1".comments[0]')"
[ -s "$PSLOG" ] && [ ! -e "$WALOG" ] && ok "apply: a decisão vai para ps-node-route.jsonl e NÃO para o log do WA" || bad "apply: logs: ps=$([ -s "$PSLOG" ] && echo sim || echo não) wa=$([ -e "$WALOG" ] && echo existe || echo não)"
# ---- um ambiente com as variáveis do WA não desvia nada
fresh; WA_NODE_ALIAS=wa-worker-remote-1 WA_NODE_ROUTE_TEMPLATE=wa-worker-remote WA_NODE_CLASSIFY=/bin/false WA_NODE_LOG="$WALOG" WA_NODE_SPAWN=pool WA_NODE_SLOTS=3 WA_NODE_ALIAS_PREFIX=wa-worker-remote- d apply ps-t1
expect_rc "ambiente com WA_NODE_* (alias, rota, classificador, log do WA, modo pool, 3 slots): a bead de PS vai ao nó DO PS -> 0" 0
[ "$(bead '."ps-t1".assignee')" = ps-worker-remote-1 ] && [ "$(bead '."ps-t1".metadata["pilot.wa_node_alias"]')" = ps-worker-remote-1 ] && [ "$(bead '."ps-t1".metadata["gc.routed_to"] // ""')" = "" ] && [ -s "$PSLOG" ] && [ ! -e "$WALOG" ] && ok "ambiente do WA: alias, modo pilot e log continuam os do PS" || bad "ambiente do WA desviou: $(jq -c '."ps-t1"' "$STATE") ps=$([ -s "$PSLOG" ] && echo sim || echo não) wa=$([ -e "$WALOG" ] && echo existe || echo não)"
# ---- só bead ps-*
fresh; d apply wa-t1;  expect_rc "apply: bead wa-* -> 11 sem escrita e sem chamar o bd" 11 w0; [ ! -s "$CALLS" ] && ok "apply: wa-* não chegou a chamar o bd" || bad "apply: wa-* chamou o bd: $(head -n 2 "$CALLS")"
fresh; d apply ga-x;   expect_rc "apply: bead ga-* -> 11 sem escrita" 11 w0
fresh; d check wa-t1;  expect_rc "check: bead wa-* -> 11" 11 w0
fresh; d release wa-t1; expect_rc "release: bead wa-* -> 11" 11 w0
fresh; d apply "";      expect_rc "apply: id vazio -> 11" 11 w0
fresh; d apply;         expect_rc "sem argumentos -> uso (2)" 2
fresh; d apply ps-t1 --dry-run; expect_rc "apply --dry-run -> 0 sem escrita" 0 w0
# ---- despachante real ausente
fresh; PS_NODE_DISPATCH="$T/nao-existe.sh" d apply ps-t1; expect_rc "despachante real ausente -> 11 sem escrita" 11 w0
# ---- o slot do PS é só do PS
fresh; jq -c '. + {"wa-busy":{"id":"wa-busy","status":"in_progress","assignee":"wa-worker-remote-1","metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply ps-t1; expect_rc "slot do WA ocupado (bead em andamento do wa-worker-remote-1) NÃO ocupa o do PS -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","closed":false,"alias":"wa-worker-remote-1"}]}' > "$SESS"
d apply ps-t1; expect_rc "sessão ativa do wa-worker-remote NÃO ocupa o slot do PS -> 0" 0
fresh; jq -c '. + {"ps-busy":{"id":"ps-busy","status":"in_progress","assignee":"ps-worker-remote-1","metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply ps-t1; expect_rc "slot do PS ocupado (bead em andamento do ps-worker-remote-1) -> 12 sem escrita" 12 w0
fresh; echo '{"ok":true,"sessions":[{"template":"ps-worker-remote","state":"active","closed":false,"alias":"ps-worker-remote-1"}]}' > "$SESS"
d apply ps-t1; expect_rc "sessão ativa do ps-worker-remote -> 12 sem escrita" 12 w0
fresh; echo '{"ok":true,"sessions":[{"template":"ps-worker","state":"active","alias":"ps-worker-adhoc-1"}]}' > "$SESS"
d apply ps-t1; expect_rc "ps-worker do mini ativo não ocupa o slot do nó -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"ps-worker-remote","state":"asleep","closed":false,"alias":"ps-worker-remote-1"}]}' > "$SESS"
d apply ps-t1; expect_rc "sessão do ps-worker-remote DORMINDO não segura o slot (o Pilot a acorda) -> 0" 0
# ---- o oráculo de capacidade do nó manda (modo pilot): sem vaga, ilegível ou ausente a bead fica no mini e nada é escrito
fresh; cap "$CAP_LOCAL" 1; d apply ps-t1; expect_rc "oráculo diz local (rc 1) -> 12 sem escrita" 12 w0
fresh; cap '{"verdict":"node","free":0}' 0; d apply ps-t1; expect_rc "oráculo diz node mas sem vaga livre (free 0) -> 11 sem escrita" 11 w0
fresh; cap 'isto nao e json' 0; d apply ps-t1; expect_rc "oráculo com saída ilegível -> 11 sem escrita" 11 w0
fresh; cap "$CAP_NODE" 3; d apply ps-t1; expect_rc "oráculo que sai com rc fora de 0/1 -> 11 sem escrita" 11 w0
fresh; PS_NODE_CAPACITY="$T/nao-existe.py" d apply ps-t1; expect_rc "oráculo ausente -> 11 sem escrita" 11 w0
# ---- bead que já tem rota/dono não é carimbada de novo
fresh '{"metadata":{"gc.routed_to":"wa-worker-remote"}}'; d apply ps-t1; expect_rc "bead com a rota do WA -> 12 sem escrita" 12 w0
fresh '{"metadata":{"gc.routed_to":"ps-worker-remote"},"assignee":"ps-worker-remote-1","status":"in_progress"}'; d apply ps-t1; expect_rc "bead que já é do nó do PS -> 12 sem escrita" 12 w0
fresh '{"metadata":{"gc.routed_to":"ps-worker"}}'; d apply ps-t1; expect_rc "bead com a rota do pool do mini (ps-worker) -> 12 sem escrita" 12 w0
# ---- release
fresh '{"assignee":"ps-worker-remote-1","status":"in_progress","metadata":{"gc.routed_to":"ps-worker-remote"}}'; d release ps-t1
expect_rc "release: bead do alias e da rota do PS -> 0" 0
[ -z "$(bead '."ps-t1".assignee')" ] && [ "$(bead '."ps-t1".metadata["gc.routed_to"] // ""')" = "" ] && ok "release: dono e rota soltos" || bad "release: estado: $(jq -c '."ps-t1"' "$STATE")"
fresh '{"assignee":"ps-worker-remote-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"ps-worker-remote-1"}}'; d release ps-t1
expect_rc "release: bead do alias do PS com a marca do Pilot (a forma que o apply escreve) -> 0" 0
[ -z "$(bead '."ps-t1".assignee')" ] && [ "$(bead '."ps-t1".metadata["pilot.wa_node_alias"] // ""')" = "" ] && ok "release: dono e marca soltos" || bad "release (marca): estado: $(jq -c '."ps-t1"' "$STATE")"
fresh '{"assignee":"ps-worker-remote-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"ps-worker-remote-2"}}'; d release ps-t1
expect_rc "release: marca de OUTRO alias -> 12 sem escrita" 12 w0
fresh '{"assignee":"ps-worker-remote-1","status":"in_progress","metadata":{"pilot.wa_node_alias":"ps-worker-remote-1","gc.routed_to":"ps-worker"}}'; d release ps-t1
expect_rc "release: marca do Pilot MAIS rota do pool do mini (as duas formas juntas) -> 12 sem escrita" 12 w0
fresh '{"assignee":"wa-worker-remote-1","status":"in_progress","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release ps-t1
expect_rc "release: bead com alias e rota do WA -> 12 sem escrita (não é do nó do PS)" 12 w0
fresh '{"assignee":"ps-worker-remote-1","status":"in_progress","metadata":{"gc.routed_to":"ps-worker"}}'; d release ps-t1
expect_rc "release: dono do PS mas rota de outro pool -> 12 sem escrita" 12 w0
# ---- o classificador REAL do PS, ponta a ponta (sem PS_NODE_CLASSIFY): o padrão da casca aponta para scripts/ps-node-classify.py
fresh '{"description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em lib/tests/test_foo_parser.py."}'
REAL_CLS_SAVED="$PS_NODE_CLASSIFY"; unset PS_NODE_CLASSIFY; d check ps-t1; export PS_NODE_CLASSIFY="$REAL_CLS_SAVED"; expect_rc "classificador real: código + teste citados -> node (0)" 0 w0
printf '%s' "$OUT" | grep -q '"verdict": "node"' && ok "classificador real: a saída é a do classificador do PS" || bad "classificador real: saída $OUT"
fresh '{"description":"lib/foo_parser.py le market.db; teste em lib/tests/test_foo_parser.py"}'
unset PS_NODE_CLASSIFY; d check ps-t1; export PS_NODE_CLASSIFY="$REAL_CLS_SAVED"; expect_rc "classificador real: cita banco (market.db) -> mini (10)" 10 w0
fresh '{"description":"Em lib/foo_parser.py a funcao quebra. Teste em lib/tests/test_foo_parser.py."}'
unset PS_NODE_CLASSIFY; d apply ps-t1; export PS_NODE_CLASSIFY="$REAL_CLS_SAVED"; expect_rc "classificador real + apply: bead com código e teste -> 0" 0
[ "$(bead '."ps-t1".assignee')" = ps-worker-remote-1 ] && ok "classificador real + apply: dono ps-worker-remote-1" || bad "classificador real + apply: $(jq -c '."ps-t1"' "$STATE")"

# ---- controle negativo: cada mutante troca UMA linha da casca (numa cópia) e o caso designado tem de reprovar
# O mutante mora em $CITY/scripts/ps-node-dispatch.mut.sh (ao lado do despachante e do classificador copiados, que é como a casca os acha).
mk_mutant() { # mk_mutant <nome> <trecho original> <trecho novo> -> $CITY/scripts/ps-node-dispatch.mut.sh; rc 1 se o trecho não existe
  python3 -I - "$REAL" "$CITY/scripts/ps-node-dispatch.mut.sh" "$2" "$3" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  chmod +x "$CITY/scripts/ps-node-dispatch.mut.sh"
}
mutant() { # mutant <nome> <trecho original> <trecho novo> <preparo: função de cenário> <rc esperado> <verificação: função que devolve 0 se o estado é o certo>
  local name="$1"
  mk_mutant "$name" "$2" "$3" || { bad "mutante $name: o trecho original não existe (a casca mudou? atualize o mutante)"; return; }
  $4; SCRIPT="$REAL"; d $SC_ARGS
  if [ "$RC" != "$5" ] || ! $6; then bad "mutante $name VAZIO: a casca ORIGINAL já reprova o caso designado (rc=$RC, esperado $5)"; return; fi
  $4; SCRIPT="$CITY/scripts/ps-node-dispatch.mut.sh"; d $SC_ARGS
  if [ "$RC" = "$5" ] && $6; then bad "mutante $name SOBREVIVEU (o caso designado ainda passa)"; else ok "mutante $name morreu"; fi
  SCRIPT="$REAL"
}
sc_apply()    { fresh; SC_ARGS="apply ps-t1"; }
sc_apply_env(){ fresh; SC_ARGS="apply ps-t1"; export WA_NODE_ALIAS=wa-worker-remote-1 WA_NODE_ROUTE_TEMPLATE=wa-worker-remote WA_NODE_CLASSIFY=/bin/false WA_NODE_LOG="$WALOG"; }
sc_wa()       { fresh; SC_ARGS="apply wa-t1"; }
# sessão viva do TEMPLATE do PS com um alias que não é o do slot: só o template (a rota) a prende; com o template do WA o slot pareceria livre
sc_tpl()      { fresh; SC_ARGS="apply ps-t1"; echo '{"ok":true,"sessions":[{"template":"ps-worker-remote","state":"active","closed":false,"alias":"outro-alias"}]}' > "$SESS"; }
sc_tpl_env()  { sc_tpl; export WA_NODE_ROUTE_TEMPLATE=wa-worker-remote; }
sc_pilot_env(){ fresh; SC_ARGS="apply ps-t1"; export WA_NODE_SPAWN=pool; }
st_pilot()    { [ "$(bead '."ps-t1".metadata["pilot.wa_node_alias"]')" = ps-worker-remote-1 ] && [ "$(bead '."ps-t1".metadata["gc.routed_to"] // ""')" = "" ]; }
sc_missing()  { fresh; SC_ARGS="apply ps-t1"; export PS_NODE_DISPATCH="$CITY/scripts/nao-existe.sh"; }
st_ps()       { [ "$(bead '."ps-t1".assignee')" = ps-worker-remote-1 ] && [ "$(bead '."ps-t1".metadata["pilot.wa_node_alias"]')" = ps-worker-remote-1 ]; }
st_log()      { [ -s "$PSLOG" ] && [ ! -e "$WALOG" ]; }
st_clean()    { ! wrote; }
mutant alias-do-wa        'WA_NODE_ALIAS="${PS_NODE_ALIAS:-ps-worker-remote-1}"'           'WA_NODE_ALIAS="${PS_NODE_ALIAS:-wa-worker-remote-1}"'           sc_apply 0 st_ps
mutant rota-do-wa         'WA_NODE_ROUTE_TEMPLATE="${PS_NODE_ROUTE_TEMPLATE:-ps-worker-remote}"' 'WA_NODE_ROUTE_TEMPLATE="${PS_NODE_ROUTE_TEMPLATE:-wa-worker-remote}"' sc_tpl 12 st_clean
mutant log-do-wa          '${PS_NODE_LOG:-$CITY/.gc/ps-node-route.jsonl}'                  '${PS_NODE_LOG:-$CITY/.gc/wa-node-route.jsonl}'                  sc_apply 0 st_log
mutant ambiente-do-wa-vence 'export WA_NODE_ALIAS="${PS_NODE_ALIAS:-ps-worker-remote-1}"'   'export WA_NODE_ALIAS="${WA_NODE_ALIAS:-${PS_NODE_ALIAS:-ps-worker-remote-1}}"' sc_apply_env 0 st_ps
mutant rota-do-ambiente-vence 'export WA_NODE_ROUTE_TEMPLATE="${PS_NODE_ROUTE_TEMPLATE:-ps-worker-remote}"' 'export WA_NODE_ROUTE_TEMPLATE="${WA_NODE_ROUTE_TEMPLATE:-${PS_NODE_ROUTE_TEMPLATE:-ps-worker-remote}}"' sc_tpl_env 12 st_clean
mutant log-do-ambiente-vence 'export WA_NODE_LOG="${PS_NODE_LOG:-$CITY/.gc/ps-node-route.jsonl}"' 'export WA_NODE_LOG="${WA_NODE_LOG:-${PS_NODE_LOG:-$CITY/.gc/ps-node-route.jsonl}}"' sc_apply_env 0 st_log
mutant modo-pool          'export WA_NODE_SPAWN="pilot"'                                                    'export WA_NODE_SPAWN="pool"'                                                     sc_apply 0 st_pilot
mutant modo-do-ambiente-vence 'export WA_NODE_SPAWN="pilot"'                                              'export WA_NODE_SPAWN="${WA_NODE_SPAWN:-pilot}"'                                  sc_pilot_env 0 st_pilot
mutant sem-guarda-de-prefixo 'case "$2" in ps-*) ;; *) say "$2 não é uma bead do PS (prefixo ps-): não decido — fica onde está"; exit 11 ;; esac' ':' sc_wa 11 st_clean
mutant sem-guarda-do-despachante '[ -x "$REAL" ] || { say "despachante $REAL ausente ou não executável — fica no mini"; exit 11; }' ':' sc_missing 11 st_clean
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
