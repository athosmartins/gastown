#!/usr/bin/env bash
# mbp-node-dispatch.selftest.sh — hermético: bd e gc são stubs (estado JSON em pasta temporária); o despachante é o REAL (wa-node-dispatch.sh), o oráculo é o REAL (mbp-node-capacity.py) nos
# casos de ponta a ponta e um stub nos demais, e o classificador é o stub com veredito escolhido + casos com o real do WA. (ga-w7qwl1.2.1)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: a casca fixa a identidade do MBP (alias -mbp-1..4, template, log, modo pilot SEM gc.routed_to) mesmo com WA_NODE_* no ambiente, inclusive o ORÁCULO · o oráculo manda (Athos no MBP/sem vaga/ilegível/ausente = fica no mini, nada escrito) ·
#   até 4 slots (padrão 4; MBP_NODE_SLOTS=1..4 baixa; qualquer outro valor definido = 1), slot só do MBP · só bead wa-* · despachante ausente = 11 · release só solta bead de alias do MBP · ponta a ponta com o oráculo e o classificador REAIS
#   (3 e 4 construtores com o Athos fora e memória livre; a queda com a memória baixa e com o Athos de volta) · o teto 4 é o mesmo no agente, na casca, no oráculo e no Pilot (ga-ixr6fh4).
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
if cmd == "blocked":   # ga-0qcsdce: o apply real lê `bd -C <loja> blocked --json` antes de classificar; aqui nada está bloqueado (a lista vazia que o bd imprime) até STUB_BLOCKED trocar a saída crua
    sys.stdout.write(os.environ.get("STUB_BLOCKED", "[]")); sys.exit(0)
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
  unset STUB_FAIL_SHOW STUB_FAIL_LIST STUB_BLOCKED MBP_NODE_SLOTS MBP_NODE_DISPATCH MBP_NODE_GATE_CMD MBP_NODE_SESSIONS_CMD
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
# ---- ga-0qcsdce: a recusa do despachante real por dependência aberta (bd blocked) ou rótulo de parada explícita sai 14, e o 14 chega ao chamador com o código dele, sem escrita
fresh; STUB_BLOCKED='[{"id":"wa-t1"}]' d apply wa-t1; expect_rc "apply: bead no bd blocked -> 14 (o código do despachante real chega ao chamador) sem escrita" 14 w0
fresh '{"labels":["pilot:no-auto-dispatch"]}'; d apply wa-t1; expect_rc "apply: bead com pilot:no-auto-dispatch -> 14 sem escrita" 14 w0
# ---- despachante real ausente
fresh; MBP_NODE_DISPATCH="$T/nao-existe.sh" d apply wa-t1; expect_rc "despachante real ausente -> 11 sem escrita" 11 w0
# ---- o prazo de teste (MBP_NODE_TIMEOUT) chega ao despachante como WA_NODE_TIMEOUT; sem ele o WA_NODE_TIMEOUT do ambiente fica como está (ga-u6ueg0q)
# o despachante aqui é um stub que só imprime o WA_NODE_TIMEOUT que recebeu: sem o repasse sai "unset"; um repasse com MBP_NODE_TIMEOUT vazio apagaria o 9 herdado
printf '#!/bin/sh\necho "WA_NODE_TIMEOUT=${WA_NODE_TIMEOUT-unset}"\n' > "$T/echo-timeout.sh"; chmod +x "$T/echo-timeout.sh"
got=$( unset WA_NODE_TIMEOUT; export MBP_NODE_TIMEOUT=7 MBP_NODE_DISPATCH="$T/echo-timeout.sh"; "$REAL" check wa-t1 2>&1 )
[ "$got" = "WA_NODE_TIMEOUT=7" ] && ok "MBP_NODE_TIMEOUT=7 chega ao despachante como WA_NODE_TIMEOUT=7" || bad "MBP_NODE_TIMEOUT=7: o despachante recebeu '$got'"
got=$( unset MBP_NODE_TIMEOUT; export WA_NODE_TIMEOUT=9 MBP_NODE_DISPATCH="$T/echo-timeout.sh"; "$REAL" check wa-t1 2>&1 )
[ "$got" = "WA_NODE_TIMEOUT=9" ] && ok "sem MBP_NODE_TIMEOUT o WA_NODE_TIMEOUT=9 do ambiente passa intacto" || bad "sem MBP_NODE_TIMEOUT: o despachante recebeu '$got' (esperado 9 herdado)"

# ---- até 4 slots do MBP (e só do MBP) — ga-ixr6fh4. Padrão 4 (o teto do agente); MBP_NODE_SLOTS=1..4 baixa; o resto vale 1 (o inerte: erro de digitação nunca vira mais sessões)
fresh; busy wa-b1 wa-worker-remote-mbp-1; d apply wa-t1
expect_rc "1º slot ocupado (bead em andamento do -mbp-1) -> a bead vai ao 2º slot -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-2 ] && ok "slots: a bead foi ao wa-worker-remote-mbp-2" || bad "slots: dono $(bead '."wa-t1".assignee')"
# O oráculo-stub vê 9 vagas: só o número de slots decide (com free 2 ele recusaria antes: as beads já atribuídas e ainda sem sessão descontam da vaga dele, e o caso testaria o oráculo, não a casca)
CAP_NODE9='{"verdict":"node","free":9,"reason":"ok"}'
fill() { local i=1; while [ "$i" -le "$1" ]; do busy "wa-b$i" "wa-worker-remote-mbp-$i"; i=$((i+1)); done; }   # fill <n>: uma bead em andamento por alias, -mbp-1..n
slots_case() { # slots_case <rótulo> <MBP_NODE_SLOTS | -: não definida> <quantos aliases ocupados> <rc esperado> <alias que recebe a bead | -: nada escrito>
  fresh; cap "$CAP_NODE9" 0; fill "$3"
  if [ "$2" = - ]; then d apply wa-t1; else MBP_NODE_SLOTS="$2" d apply wa-t1; fi
  if [ "$5" = - ]; then expect_rc "$1" "$4" w0
  else expect_rc "$1" "$4" && { [ "$(bead '."wa-t1".assignee')" = "$5" ] && ok "  e foi ao $5" || bad "  dono '$(bead '."wa-t1".assignee')' (esperado $5)"; }
  fi
}
slots_case "padrão (MBP_NODE_SLOTS não definida): 0 ocupados -> -mbp-1" - 0 0 wa-worker-remote-mbp-1
slots_case "padrão 4: 2 ocupados -> o 3º slot (-mbp-3)" - 2 0 wa-worker-remote-mbp-3
slots_case "padrão 4: 3 ocupados -> o 4º slot (-mbp-4)" - 3 0 wa-worker-remote-mbp-4
slots_case "padrão 4: os 4 ocupados -> 12 sem escrita (não há 5º)" - 4 12 -
slots_case "MBP_NODE_SLOTS=4: 3 ocupados -> -mbp-4" 4 3 0 wa-worker-remote-mbp-4
slots_case "MBP_NODE_SLOTS=4: 4 ocupados -> 12 sem escrita" 4 4 12 -
slots_case "MBP_NODE_SLOTS=3: 2 ocupados -> -mbp-3" 3 2 0 wa-worker-remote-mbp-3
slots_case "MBP_NODE_SLOTS=3: 3 ocupados -> 12 sem escrita (o 4º não abre)" 3 3 12 -
slots_case "MBP_NODE_SLOTS=2 (o teto de antes): 1 ocupado -> -mbp-2" 2 1 0 wa-worker-remote-mbp-2
slots_case "MBP_NODE_SLOTS=2: 2 ocupados -> 12 sem escrita (o 3º não abre)" 2 2 12 -
slots_case "MBP_NODE_SLOTS=1 (canário): 0 ocupados -> -mbp-1" 1 0 0 wa-worker-remote-mbp-1
slots_case "MBP_NODE_SLOTS=1: com o -mbp-1 ocupado -> 12 sem escrita" 1 1 12 -
# valor definido e ilegível (fora de 1..4, vazio, texto, decimal, com zero à esquerda ou espaço) vale 1 slot — nunca o número digitado e nunca o padrão 4
for badv in 5 9 10 0 "" abc 2.5 -1 04 " 2" "3 "; do
  slots_case "MBP_NODE_SLOTS='$badv' (fora de 1..4): vale 1 slot — 1 ocupado -> 12 sem escrita" "$badv" 1 12 -
  slots_case "MBP_NODE_SLOTS='$badv': sem ocupados a bead vai ao -mbp-1 (1 slot, não o padrão 4)" "$badv" 0 0 wa-worker-remote-mbp-1
done
fresh; cap "$CAP_NODE9" 0; MBP_NODE_SLOTS=5 d apply wa-t1; printf '%s' "$OUT" | grep -qF "MBP_NODE_SLOTS='5' não é 1..4" && ok "valor ilegível AVISA no stderr (não é 1..4) e diz que usa 1 slot" || bad "aviso do valor ilegível: $OUT"
fresh; cap "$CAP_NODE9" 0; MBP_NODE_SLOTS=3 d apply wa-t1; printf '%s' "$OUT" | grep -q 'MBP_NODE_SLOTS' && bad "valor válido (3) não devia avisar: $OUT" || ok "valor válido (3) não avisa"
# ---- o slot do MBP é só do MBP
fresh; busy wa-hz wa-worker-remote-1; d apply wa-t1
expect_rc "bead em andamento do wa-worker-remote-1 (Hetzner) NÃO ocupa o slot do MBP -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","closed":false,"alias":"wa-worker-remote-1"}]}' > "$SESS"
d apply wa-t1; expect_rc "sessão ativa do wa-worker-remote (Hetzner) NÃO ocupa o slot do MBP -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker","state":"active","alias":"wa-worker-adhoc-1"}]}' > "$SESS"
d apply wa-t1; expect_rc "wa-worker do mini ativo não ocupa o slot do MBP -> 0" 0
live_mbp() { # live_mbp <n>: n sessões ativas do template do MBP, uma por alias -mbp-1..n (a lista que o `gc session list --json` devolve)
  local i=1 rows=""; while [ "$i" -le "$1" ]; do rows="$rows${rows:+,}{\"template\":\"wa-worker-remote-mbp\",\"state\":\"active\",\"closed\":false,\"alias\":\"wa-worker-remote-mbp-$i\"}"; i=$((i+1)); done
  printf '{"ok":true,"sessions":[%s]}\n' "$rows" > "$SESS"
}
fresh; cap "$CAP_NODE9" 0; live_mbp 4
d apply wa-t1; expect_rc "4 sessões ativas do wa-worker-remote-mbp (padrão 4) -> 12 sem escrita" 12 w0
fresh; cap "$CAP_NODE9" 0; live_mbp 3
d apply wa-t1; expect_rc "3 sessões ativas (padrão 4) -> a bead vai ao 4º alias -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-4 ] && ok "3 sessões ativas: a bead foi ao -mbp-4 (o alias que NENHUMA sessão viva tem)" || bad "3 sessões ativas: dono '$(bead '."wa-t1".assignee')'"
fresh; cap "$CAP_NODE9" 0; live_mbp 2
MBP_NODE_SLOTS=2 d apply wa-t1; expect_rc "2 sessões ativas com MBP_NODE_SLOTS=2 -> 12 sem escrita" 12 w0
fresh; cap "$CAP_NODE9" 0; live_mbp 2
MBP_NODE_SLOTS=3 d apply wa-t1; expect_rc "2 sessões ativas com MBP_NODE_SLOTS=3 -> 0 (o 3º slot)" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote-mbp","state":"asleep","closed":false,"alias":"wa-worker-remote-mbp-1"}]}' > "$SESS"
d apply wa-t1; expect_rc "sessão do wa-worker-remote-mbp DORMINDO não segura o slot (o Pilot a acorda) -> 0" 0
# ---- o teto 4 mora em QUATRO arquivos (seis pontos) e tem de ser o MESMO número (ga-ixr6fh4): o agente (max_active_sessions), o padrão e o último valor aceito da casca, o SESSIONS_MAX do oráculo e os dois padrões de
# alias do Pilot (abrir a sessão do alias e desfazer o apply incerto). Um deles diferente deixa bead dona de um alias que ninguém serve: o Pilot recusa abrir a sessão e a bead fica segura como "já é do nó".
# vazio (arquivo ou padrão que não achei) → o número fica vazio e o caso REPROVA; nunca "igual" por falta de leitura.
AGENT_TOML="$HERE/../agents/wa-worker-remote-mbp/agent.toml"; PILOT_SH="$HERE/../packs/town-deltas/assets/pilot-dispatcher.sh"
t_agent=$(sed -n 's/^max_active_sessions *= *\([0-9][0-9]*\).*/\1/p' "$AGENT_TOML" 2>/dev/null | head -n 1)
t_default=$(sed -n 's/^SLOTS=\([0-9][0-9]*\)$/\1/p' "$REAL" 2>/dev/null | head -n 1)
t_upto=$(sed -n 's/.*case "\$MBP_NODE_SLOTS" in \([0-9|]*\)) SLOTS=.*/\1/p' "$REAL" 2>/dev/null | tr '|' '\n' | sort -n | tail -n 1)
t_oracle=$(sed -n 's/^SESSIONS_MAX = \([0-9][0-9]*\).*/\1/p' "$HERE/mbp-node-capacity.py" 2>/dev/null | head -n 1)
t_pilot=$(grep -o 'wa-worker-remote-mbp-\[1-[0-9]\]' "$PILOT_SH" 2>/dev/null | sed 's/.*\[1-\([0-9]\)\]/\1/' | sort -u | tr '\n' ' ')
t_pilot_n=$(grep -o 'wa-worker-remote-mbp-\[1-[0-9]\]' "$PILOT_SH" 2>/dev/null | wc -l | tr -d ' ')
case "$t_agent" in ''|*[!0-9]*) bad "teto do agente ilegível em $AGENT_TOML ('$t_agent')" ;; *)
  [ "$t_default" = "$t_agent" ] && ok "o padrão de SLOTS da casca ($t_default) é o max_active_sessions do agente ($t_agent)" || bad "padrão de SLOTS da casca '$t_default' ≠ max_active_sessions do agente '$t_agent'"
  [ "$t_upto" = "$t_agent" ] && ok "o último valor que MBP_NODE_SLOTS aceita ($t_upto) é o teto do agente ($t_agent)" || bad "MBP_NODE_SLOTS aceita até '$t_upto' ≠ teto do agente '$t_agent'"
  [ "$t_oracle" = "$t_agent" ] && ok "o SESSIONS_MAX do oráculo ($t_oracle) é o teto do agente ($t_agent)" || bad "SESSIONS_MAX do oráculo '$t_oracle' ≠ teto do agente '$t_agent'"
  [ "$t_pilot" = "$t_agent " ] && [ "${t_pilot_n:-0}" -ge 2 ] && ok "os padrões de alias do Pilot (abrir e desfazer: $t_pilot_n) vão até -mbp-$t_agent, o teto do agente" || bad "padrões de alias do Pilot: '$t_pilot' ($t_pilot_n) ≠ -mbp-$t_agent"
;; esac

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
# ---- ga-ixr6fh4: o teto DINÂMICO ponta a ponta (despachante, oráculo e classificador REAIS; só o gate e a lista de sessões são stubs). `up <n>`: os aliases -mbp-1..n têm bead em andamento E sessão ativa.
GATE_M52='{"cap":4,"host":"mbp","ok":true,"reason":"Athos fora e MBP saudável","slot_cap":8,"mem_free_pct":52}'
GATE_M30='{"cap":4,"host":"mbp","ok":true,"reason":"Athos fora e MBP saudável","slot_cap":8,"mem_free_pct":30}'
GATE_NOMEM='{"cap":4,"host":"mbp","ok":true,"reason":"Athos fora e MBP saudável","slot_cap":8}'
GATE_CAP2='{"cap":2,"host":"mbp","ok":true,"reason":"Athos fora e MBP saudável","slot_cap":8,"mem_free_pct":52}'
GATE_USO90='{"cap":4,"host":"mbp","ok":false,"reason":"Athos está no MBP (presença=uso, motivo=input_recente)","slot_cap":null,"mem_free_pct":90}'
e2e_up() { # e2e_up <json do gate> <rc do gate> <n>
  e2e; gate "$1" "$2"; fill "$3"; live_mbp "$3"
}
dyn_case() { # dyn_case <rótulo> <json do gate> <rc do gate> <n no ar> <rc esperado> <alias que recebe | -: nada escrito>
  e2e_up "$2" "$3" "$4"; d apply wa-t1
  if [ "$6" = - ]; then expect_rc "$1" "$5" w0
  else expect_rc "$1" "$5" && { [ "$(bead '."wa-t1".assignee')" = "$6" ] && ok "  e foi ao $6" || bad "  dono '$(bead '."wa-t1".assignee')' (esperado $6)"; }
  fi
}
dyn_case "Athos fora, 52% livres, nenhuma no ar: -> -mbp-1" "$GATE_M52" 0 0 0 wa-worker-remote-mbp-1
dyn_case "Athos fora, 52% livres, 2 no ar: a 3ª construtora -> -mbp-3" "$GATE_M52" 0 2 0 wa-worker-remote-mbp-3
dyn_case "Athos fora, 52% livres, 3 no ar: a 4ª construtora -> -mbp-4" "$GATE_M52" 0 3 0 wa-worker-remote-mbp-4
dyn_case "Athos fora, 52% livres, 4 no ar: não há 5ª -> 12 sem escrita" "$GATE_M52" 0 4 12 -
dyn_case "memória em 30% (abaixo de 35), 1 no ar: a 2ª ainda abre (o teto de antes) -> -mbp-2" "$GATE_M30" 0 1 0 wa-worker-remote-mbp-2
dyn_case "memória caiu a 30% com 2 no ar: a 3ª NÃO abre -> 12 sem escrita (as 2 seguem)" "$GATE_M30" 0 2 12 -
dyn_case "provider antigo (sem mem_free_pct), 2 no ar: a 3ª NÃO abre -> 12 sem escrita" "$GATE_NOMEM" 0 2 12 -
dyn_case "cap 2 na config do host, 52% livres, 2 no ar: o cap segura -> 12 sem escrita" "$GATE_CAP2" 0 2 12 -
dyn_case "Athos de volta (gate recusa), nenhuma no ar: -> 12 sem escrita, mesmo com 90% livres" "$GATE_USO90" 1 0 12 -
dyn_case "Athos de volta com 1 no ar: -> 12 sem escrita (nenhuma sessão nova; a viva segue em prioridade de fundo)" "$GATE_USO90" 1 1 12 -
# a queda: o mesmo MBP com 2 no ar aceita a 3ª e, com o Athos de volta, a 4ª não vem
dyn_case "queda, antes: Athos fora, 52% livres, 2 no ar -> -mbp-3" "$GATE_M52" 0 2 0 wa-worker-remote-mbp-3
dyn_case "queda, depois: o Athos volta, 3 no ar -> 12 sem escrita" "$GATE_USO90" 1 3 12 -
e2e_up "$GATE_M52" 0 2; MBP_NODE_SLOTS=2 d apply wa-t1; expect_rc "Athos fora, 52% livres e MBP_NODE_SLOTS=2 (canário): 2 no ar -> 12 sem escrita (a casca baixa o teto)" 12 w0
e2e_up "$GATE_M52" 0 3; MBP_NODE_SLOTS=3 d apply wa-t1; expect_rc "MBP_NODE_SLOTS=3: 3 no ar -> 12 sem escrita (o 4º não abre)" 12 w0
unset MBP_NODE_GATE_CMD MBP_NODE_SESSIONS_CMD
# ---- o classificador REAL do WA, ponta a ponta (sem MBP_NODE_CLASSIFY): o padrão da casca aponta para scripts/wa-node-classify.py
fresh '{"description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em tests/test_foo_parser.py."}'
REAL_CLS_SAVED="$MBP_NODE_CLASSIFY"; unset MBP_NODE_CLASSIFY; d check wa-t1; expect_rc "classificador real: código + teste citados -> node (0)" 0 w0
printf '%s' "$OUT" | grep -q '"verdict": "node"' && ok "classificador real: a saída é a do classificador do WA" || bad "classificador real: saída $OUT"
fresh '{"description":"lib/foo.py lê data/helper.py; tests/test_foo.py"}'
d check wa-t1; expect_rc "classificador real: cita código que o filtro não deixa sair (data/helper.py) -> mini (10)" 10 w0
fresh '{"description":"lib/foo.py mede queue.db; tests/test_foo.py"}'
d check wa-t1; expect_rc "classificador real: queue.db citado como PROVA, com código e teste -> node (0) (ga-t05a1z9)" 0 w0
fresh '{"description":"o teste tests/test_foo.py mede queue.db"}'
d check wa-t1; expect_rc "classificador real: queue.db citado SEM código -> segue mini (10)" 10 w0
fresh '{"description":"Em lib/foo_parser.py a funcao quebra. Teste em tests/test_foo_parser.py."}'
d apply wa-t1; expect_rc "classificador real + apply: bead com código e teste -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && ok "classificador real + apply: dono wa-worker-remote-mbp-1" || bad "classificador real + apply: $(jq -c '."wa-t1"' "$STATE")"
export MBP_NODE_CLASSIFY="$REAL_CLS_SAVED"

# ---- controle negativo: cada mutante troca UMA linha da casca (numa cópia) e o caso designado tem de reprovar
# O mutante mora em $CITY/scripts/mbp-node-dispatch.mut.sh (ao lado do despachante, do classificador e do oráculo copiados, que é como a casca os acha).
mk_mutant() { # mk_mutant <nome> <trecho original> <trecho novo> -> $CITY/scripts/mbp-node-dispatch.mut.sh; rc 1 se o trecho não existe
  # o arquivo do mutante anterior sai ANTES: com a âncora ausente o rc do python (1) é o da função, e o `chmod` final não o esconde nem deixa um mutante velho rodar no lugar deste (ga-ixr6fh4)
  rm -f "$CITY/scripts/mbp-node-dispatch.mut.sh"
  python3 -I - "$REAL" "$CITY/scripts/mbp-node-dispatch.mut.sh" "$2" "$3" <<'EOF' || return 1
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
# oráculo-stub com 9 vagas (CAP_NODE9): as beads já atribuídas (sem sessão) descontam da vaga dele, e só o nº de slots decide (com free 2 o oráculo recusaria antes e o mutante nunca seria exercido)
sc_slots_env() { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 4; export WA_NODE_SLOTS=5; }   # 4 ocupados e o ambiente diz 5: o da casca (4) manda -> 12; o mutante abre o 5º
sc_two()       { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 1; }                           # padrão: o -mbp-2 recebe; com 1 slot só -> 12
sc_def4()      { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 3; }                           # padrão 4: o -mbp-4 recebe; com padrão 2 (ou 3) -> 12
sc_bad5()      { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 1; export MBP_NODE_SLOTS=5; }  # 5 é ilegível: 1 slot -> 12; quem aceita o 5 deixa o -mbp-2 receber
sc_three()     { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 2; export MBP_NODE_SLOTS=3; }  # 3 vale: o -mbp-3 recebe; quem só aceita 1|2 deixa em 1 slot -> 12
sc_four()      { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 3; export MBP_NODE_SLOTS=4; }  # 4 vale: o -mbp-4 recebe; quem só aceita até 3 deixa em 1 slot -> 12
sc_empty()     { fresh; SC_ARGS="apply wa-t1"; cap "$CAP_NODE9" 0; fill 1; export MBP_NODE_SLOTS=; }   # definida e vazia: 1 slot -> 12
st_mbp()       { [ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"]')" = wa-worker-remote-mbp-1 ]; }
st_pilot()     { [ "$(bead '."wa-t1".metadata["pilot.wa_node_alias"]')" = wa-worker-remote-mbp-1 ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"] // ""')" = "" ]; }
st_log()       { [ -s "$MBPLOG" ] && [ ! -e "$WALOG" ]; }
st_clean()     { ! wrote; }
st_second()    { [ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-2 ]; }
st_third()     { [ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-3 ]; }
st_fourth()    { [ "$(bead '."wa-t1".assignee')" = wa-worker-remote-mbp-4 ]; }
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
mutant um-slot-so           'SLOTS=4
if'                                                                                  'SLOTS=1
if'                                                                                  sc_two 0 st_second
mutant padrao-volta-a-2     'SLOTS=4
if'                                                                                  'SLOTS=2
if'                                                                                  sc_def4 0 st_fourth
mutant slot-ilegivel-vale-o-valor 'SLOTS=1; say "MBP_NODE_SLOTS='"'"'$MBP_NODE_SLOTS'"'"' não é 1..4'  'SLOTS="$MBP_NODE_SLOTS"; say "MBP_NODE_SLOTS='"'"'$MBP_NODE_SLOTS'"'"' não é 1..4' sc_bad5 12 st_clean
mutant aceita-ate-5         '1|2|3|4)'                                               '1|2|3|4|5)'                                         sc_bad5 12 st_clean
mutant so-1-ou-2            '1|2|3|4)'                                               '1|2)'                                               sc_three 0 st_third
mutant so-ate-3             '1|2|3|4)'                                               '1|2|3)'                                             sc_four 0 st_fourth
mutant slots-vazio-vale-padrao '"${MBP_NODE_SLOTS+set}" = set'                       '"${MBP_NODE_SLOTS:+set}" = set'                     sc_empty 12 st_clean
mutant sem-guarda-de-prefixo 'case "$2" in wa-*) ;; *) say "$2 não é uma bead do WA (prefixo wa-): não decido — fica onde está"; exit 11 ;; esac' ':' sc_ps 11 st_clean
mutant sem-guarda-do-despachante '[ -x "$REAL" ] || { say "despachante $REAL ausente ou não executável — fica no mini"; exit 11; }' ':' sc_missing 11 st_clean
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
