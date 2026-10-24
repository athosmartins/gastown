#!/usr/bin/env bash
# mbp-node-capacity.selftest.sh — hermético: o `gc-session-ssh gate mbp` e o `gc session list` são stubs (arquivos com a saída e o rc); o oráculo é o REAL. (ga-w7qwl1.2.1)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: gate libera (vaga = min(cap, slot_cap) − sessões do MBP vivas) · gate RECUSA (o motivo passa adiante; a lista nem é esperada) · gate ilegível/incoerente/sem teto/de outro host/prazo NUNCA vira node ·
#   só as sessões do MBP contam (fechada ou dormindo não ocupa; estado ausente ou desconhecido ocupa) · lista ilegível = unknown · config de teste ilegível = unknown · prazo mata o GRUPO · saída é UM objeto JSON.
# CONTROLE NEGATIVO: cada mutante troca UMA linha do oráculo numa cópia e o caso designado tem de reprovar; mutante que sobrevive reprova esta bateria.
# COMO RODAR: bash scripts/mbp-node-capacity.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/mbp-node-capacity.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/mbp-node-cap.XXXXXX")
trap 'pkill -f "sleep 37.31" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq ausente"; exit 2; }

GATEOUT="$T/gate.out"; GATERC="$T/gate.rc"; SESSOUT="$T/sess.out"; SESSRC="$T/sess.rc"
cat > "$T/gate.sh" <<'SHEOF'
#!/bin/sh
cat "$STUB_GATEOUT"; exit "$(cat "$STUB_GATERC")"
SHEOF
cat > "$T/sess.sh" <<'SHEOF'
#!/bin/sh
cat "$STUB_SESSOUT"; exit "$(cat "$STUB_SESSRC")"
SHEOF
cat > "$T/hang.sh" <<'SHEOF'
#!/bin/sh
sleep 37.31 &
wait
SHEOF
chmod +x "$T/gate.sh" "$T/sess.sh" "$T/hang.sh"
export STUB_GATEOUT="$GATEOUT" STUB_GATERC="$GATERC" STUB_SESSOUT="$SESSOUT" STUB_SESSRC="$SESSRC"

GATE_OK='{"cap":2,"host":"mbp","ok":true,"reason":"Athos fora e MBP saudável","slot_cap":3}'
SESS_NONE='{"sessions":[]}'
gate() { printf '%s' "$1" > "$GATEOUT"; printf '%s' "${2:-0}" > "$GATERC"; }
sess() { printf '%s' "$1" > "$SESSOUT"; printf '%s' "${2:-0}" > "$SESSRC"; }
reset() { gate "$GATE_OK" 0; sess "$SESS_NONE" 0; unset MBP_NODE_GATE_CMD MBP_NODE_SESSIONS_CMD MBP_NODE_GATE_TIMEOUT_S MBP_NODE_SESSIONS_TIMEOUT_S; export MBP_NODE_GATE_CMD="[\"$T/gate.sh\"]" MBP_NODE_SESSIONS_CMD="[\"$T/sess.sh\"]"; }
OUT=""; RC=0; STDERR_F="$T/stderr"
run_oracle() { OUT=$(python3 -I "$1" "${@:2}" 2>"$STDERR_F"); RC=$?; }
jget() { printf '%s' "$OUT" | jq -r ".$1 // \"\"" 2>/dev/null; }
# expect <rótulo> <rc> <verdict> [reason] [free]
expect() {
  local why=""
  [ "$RC" = "$2" ] || why="rc=$RC (esperado $2)"
  [ "$(jget verdict)" = "$3" ] || why="$why verdict=$(jget verdict) (esperado $3)"
  [ -z "${4:-}" ] || [ "$(jget reason)" = "$4" ] || why="$why reason=$(jget reason) (esperado $4)"
  [ -z "${5:-}" ] || [ "$(jget free)" = "$5" ] || why="$why free=$(jget free) (esperado $5)"
  if [ -n "$why" ]; then bad "$1 ::$why :: $(printf '%s' "$OUT" | cut -c1-240)"; else ok "$1"; fi
}
verd() { run_oracle "$REAL" --json verdict; }

# ---- o gate libera: vagas = menor entre cap e slot_cap, menos as sessões do MBP vivas
reset; verd; expect "gate libera, sem sessões: node, free 2 (cap 2, slot_cap 3)" 0 node ok 2
[ "$(jget effective)" = 2 ] && [ "$(jget host_cap)" = 2 ] && [ "$(jget slot_cap)" = 3 ] && [ "$(jget live)" = 0 ] && ok "o JSON diz cap, slot_cap, efetivo e vivas" || bad "campos do JSON: $OUT"
reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":1}'; verd; expect "slot_cap 1 (RAM) < cap 2: free 1" 0 node ok 1
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; verd; expect "cap 1 < slot_cap 3: free 1" 0 node ok 1
reset; sess '{"sessions":[{"template":"wa-worker-remote-mbp","alias":"wa-worker-remote-mbp-1","session_name":"wa-worker-remote-mbp-gax1","state":"active","closed":false}]}'; verd
expect "1 sessão do MBP viva: free 1" 0 node ok 1
reset; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"active"},{"template":"wa-worker-remote-mbp","state":"active"}]}'; verd
expect "2 sessões do MBP vivas (teto 2): local sem_vaga, free 0" 1 local sem_vaga 0
reset; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"active"},{"template":"wa-worker-remote-mbp","state":"active"},{"template":"wa-worker-remote-mbp","state":"active"}]}'; verd
expect "3 sessões vivas (acima do teto): local sem_vaga, free 0 (nunca negativo)" 1 local sem_vaga 0

# ---- o gate RECUSA: o motivo do provider passa adiante, e a lista de sessões nem é esperada
for why in "Athos está no MBP (presença=uso, motivo=input_recente)" "pausa do Athos ativa" "MBP sem saúde ou fora do ar (rc 98)" "bandeira mbp-offload desligada" "MBP desligado ou pausado (bandeira ou pausa do Athos)"; do
  reset; gate "{\"cap\":2,\"host\":\"mbp\",\"ok\":false,\"reason\":\"$why\",\"slot_cap\":null}" 1; verd
  expect "gate recusa ($why) -> local" 1 local gate
  [ "$(jget detail)" = "$why" ] && ok "  o motivo do provider chega no detail" || bad "  detail=$(jget detail)"
done
reset; gate '{"cap":2,"host":"mbp","ok":false,"reason":"","slot_cap":null}' 1; verd; expect "gate recusa sem motivo -> local (diz que não disse)" 1 local gate
reset; gate '{"cap":2,"host":"mbp","ok":false,"reason":"Athos no MBP","slot_cap":null}' 1; sess 'lixo' 1; verd; expect "gate recusa + lista de sessões ilegível -> local (a lista nem importa)" 1 local gate
reset; gate '{"cap":2,"host":"mbp","ok":false,"reason":"Athos no MBP","slot_cap":null}' 1; export MBP_NODE_SESSIONS_CMD="[\"$T/hang.sh\"]" MBP_NODE_SESSIONS_TIMEOUT_S=20
t0=$SECONDS; verd; dt=$((SECONDS-t0)); expect "gate recusa + lista de sessões PENDURADA -> local" 1 local gate
[ "$dt" -lt 10 ] && ok "  e não esperou a lista pendurada (${dt}s)" || bad "  esperou a lista pendurada (${dt}s)"
pkill -f "sleep 37.31" 2>/dev/null

# ---- gate que não dá para ler NUNCA vira node
reset; gate 'gc-session-ssh gate: host mbp não está em .gc/session-ssh.json' 1; verd; expect "gate sem JSON (host fora da config) -> unknown" 2 unknown gate_ilegivel
reset; gate '' 0; verd; expect "gate com saída vazia e rc 0 -> unknown" 2 unknown gate_ilegivel
reset; gate '[]' 0; verd; expect "gate devolve um array, não objeto -> unknown" 2 unknown gate_ilegivel
reset; gate "$GATE_OK" 1; verd; expect "rc 1 com ok true (discordam) -> unknown" 2 unknown gate_incoerente
reset; gate '{"cap":2,"host":"mbp","ok":false,"reason":"x","slot_cap":null}' 0; verd; expect "rc 0 com ok false (discordam) -> unknown" 2 unknown gate_incoerente
reset; gate '{"cap":2,"host":"mbp","ok":null,"reason":"dry-run: não consultei a presença","slot_cap":null}' 2; verd; expect "rc 2 (dry-run, não consultou) -> unknown" 2 unknown gate_incoerente
reset; gate "$GATE_OK" 3; verd; expect "rc fora de 0/1/2 -> unknown" 2 unknown gate_incoerente
reset; gate '{"cap":2,"host":"mbp","ok":"true","reason":"x","slot_cap":3}' 0; verd; expect "ok como texto \"true\" -> unknown" 2 unknown gate_incoerente
reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":null}' 0; verd; expect "ok com slot_cap nulo (host sem presence_gate) -> unknown, não livre" 2 unknown gate_sem_teto
reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x"}' 0; verd; expect "ok sem a chave slot_cap -> unknown" 2 unknown gate_sem_teto
reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":0}' 0; verd; expect "slot_cap 0 -> unknown" 2 unknown gate_sem_teto
reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":"3"}' 0; verd; expect "slot_cap como texto -> unknown" 2 unknown gate_sem_teto
reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":true}' 0; verd; expect "slot_cap booleano true -> unknown (true não é 1 vaga)" 2 unknown gate_sem_teto
reset; gate '{"host":"mbp","ok":true,"reason":"x","slot_cap":3}' 0; verd; expect "sem a chave cap -> unknown" 2 unknown gate_sem_teto
reset; gate '{"cap":2,"host":"hetzner","ok":true,"reason":"x","slot_cap":3}' 0; verd; expect "veredito de OUTRO host (hetzner) -> unknown" 2 unknown gate_outro_host
reset; export MBP_NODE_GATE_CMD="[\"$T/nao-existe.sh\"]"; verd; expect "gate que não roda (arquivo ausente) -> unknown" 2 unknown gate_nao_roda
# prazo: o gate pendura, o oráculo diz unknown no prazo e MATA o grupo (o sleep filho não fica órfão)
reset; export MBP_NODE_GATE_CMD="[\"$T/hang.sh\"]" MBP_NODE_GATE_TIMEOUT_S=1
t0=$SECONDS; verd; dt=$((SECONDS-t0)); expect "gate pendurado -> unknown gate_prazo" 2 unknown gate_prazo
[ "$dt" -lt 12 ] && ok "  no prazo (${dt}s)" || bad "  demorou ${dt}s com prazo de 1s"
sleep 1; if pgrep -f "sleep 37.31" >/dev/null 2>&1; then bad "  o processo filho do gate pendurado ficou órfão"; pkill -f "sleep 37.31"; else ok "  o grupo de processos foi morto (sem filho órfão)"; fi

# ---- as sessões: só as do MBP contam
reset; sess '{"sessions":[{"template":"wa-worker-remote","state":"active","session_name":"wa-worker-remote-gawisp1","alias":"wa-worker-remote-1"},{"template":"wa-worker","state":"active","session_name":"wa-worker-gax"},{"template":"dog-remote","state":"active","session_name":"dog-remote-gab"}]}'; verd
expect "sessões do Hetzner e do mini NÃO contam: free 2" 0 node ok 2
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"","session_name":"wa-worker-remote-mbp-gaxyz","state":"active"}]}'; verd
expect "sessão só pelo NOME (-remote-mbp-) conta" 1 local sem_vaga
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"alias":"wa-worker-remote-mbp-1","state":"active"}]}'; verd
expect "sessão só pelo ALIAS (-remote-mbp-1) conta" 1 local sem_vaga
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"dog-remote","session_name":"dog-remote-mbp-1","state":"active"}]}'; verd
expect "outro papel no MBP (dog-remote-mbp-1) também ocupa o teto do host" 1 local sem_vaga
reset; sess '{"sessions":[{"template":"wa-worker-remote","session_name":"wa-worker-remote-gambp","state":"active"},{"template":"wa-worker-remote","session_name":"wa-worker-remote-mbpx-1","state":"active"}]}'; verd
expect "nome que só contém 'mbp' sem o pedido de host (-remote-mbp-) NÃO conta" 0 node ok 2
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"active","closed":true}]}'; verd
expect "sessão fechada (closed true) não ocupa" 0 node ok 1
for st in closed stopped archived drained asleep; do
  reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess "{\"sessions\":[{\"template\":\"wa-worker-remote-mbp\",\"state\":\"$st\"}]}"; verd
  expect "sessão em estado '$st' não ocupa" 0 node ok 1
done
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp"}]}'; verd
expect "sessão SEM estado ocupa (não sei = ocupada)" 1 local sem_vaga
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"creating"}]}'; verd
expect "sessão em estado desconhecido (creating) ocupa" 1 local sem_vaga
reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":7}]}'; verd
expect "estado que não é texto ocupa" 1 local sem_vaga

# ---- lista de sessões que não se lê = unknown (nunca '0 vivas')
reset; sess '{"sessions":[]}' 1; verd; expect "gc session list sai com rc 1 e JSON bom -> unknown" 2 unknown sessoes_falhou
reset; sess 'não é json' 0; verd; expect "lista que não é JSON -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '[]' 0; verd; expect "lista que é array solto -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '{"ok":true}' 0; verd; expect "sem a chave sessions -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '{"sessions":null}' 0; verd; expect "sessions nulo -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '{"sessions":{}}' 0; verd; expect "sessions que não é lista -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '{"sessions":["wa-worker-remote-mbp-1"]}' 0; verd; expect "item que não é objeto -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '{"sessions":[{"template":5,"state":"active"}]}' 0; verd; expect "template que não é texto -> unknown" 2 unknown sessoes_ilegiveis
reset; sess '' 0; verd; expect "saída vazia -> unknown (não é '0 sessões')" 2 unknown sessoes_ilegiveis
reset; export MBP_NODE_SESSIONS_CMD="[\"$T/nao-existe.sh\"]"; verd; expect "gc que não roda -> unknown" 2 unknown sessoes_nao_roda
reset; export MBP_NODE_SESSIONS_CMD="[\"$T/hang.sh\"]" MBP_NODE_SESSIONS_TIMEOUT_S=1; verd; expect "lista pendurada -> unknown sessoes_prazo" 2 unknown sessoes_prazo
sleep 1; pkill -f "sleep 37.31" 2>/dev/null

# ---- config de teste ilegível = unknown (o padrão NÃO volta calado)
reset; export MBP_NODE_GATE_CMD='isto não é json'; verd; expect "MBP_NODE_GATE_CMD que não é JSON -> unknown config (não o gate real)" 2 unknown config
reset; export MBP_NODE_GATE_CMD='[]'; verd; expect "MBP_NODE_GATE_CMD lista vazia -> unknown config" 2 unknown config
reset; export MBP_NODE_SESSIONS_CMD='[1,2]'; verd; expect "MBP_NODE_SESSIONS_CMD com item que não é texto -> unknown config" 2 unknown config
reset; export MBP_NODE_SESSIONS_CMD='{"a":1}'; verd; expect "MBP_NODE_SESSIONS_CMD objeto, não lista -> unknown config" 2 unknown config
# prazos: valor ilegível volta ao padrão, e nunca passa de 40 s (o despachante dá 45)
for pair in "abc:25" "0:25" "99:25" "-1:25" "1.5:25" ":25" "7:7" "40:40" "41:25"; do
  v="${pair%%:*}"; want="${pair##*:}"
  got=$(MBP_NODE_GATE_TIMEOUT_S="$v" python3 -I - "$REAL" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cap", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.timeout_s("MBP_NODE_GATE_TIMEOUT_S", 25))
EOF
)
  [ "$got" = "$want" ] && ok "prazo '$v' -> $want s" || bad "prazo '$v' -> $got s (esperado $want)"
done

# ---- a linha de comando e a saída
reset; verd; [ "$(printf '%s' "$OUT" | jq -s 'length' 2>/dev/null)" = 1 ] && printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1 && ok "a saída é UM objeto JSON" || bad "saída: $OUT"
reset; run_oracle "$REAL" verdict --json; expect "verdict --json (a opção depois do comando) -> o mesmo" 0 node ok 2
reset; run_oracle "$REAL" verdict; case "$OUT" in "node ok: "*) ok "sem --json: uma linha de texto" ;; *) bad "sem --json: $OUT" ;; esac
run_oracle "$REAL" --json; [ "$RC" = 2 ] && ok "sem comando -> uso (2)" || bad "sem comando: rc=$RC"
run_oracle "$REAL" --json bogus; [ "$RC" = 2 ] && ok "comando desconhecido -> uso (2)" || bad "comando desconhecido: rc=$RC"
reset; run_oracle "$REAL" --json verdict </dev/null; expect "entrada fechada (</dev/null) como o despachante a chama" 0 node ok 2

# ---- controle negativo: cada mutante troca UMA linha do oráculo (numa cópia) e o caso designado tem de reprovar
MUT="$T/mbp-node-capacity.mut.py"
mk_mutant() { python3 -I - "$REAL" "$MUT" "$1" "$2" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
}
v_default() { return 0; }
v_noorphan() { sleep 1; if pgrep -f "sleep 37.31" >/dev/null 2>&1; then pkill -f "sleep 37.31"; return 1; fi; return 0; }
v_fast() { [ "${DT:-99}" -lt 10 ]; }
mutant() { # mutant <nome> <trecho original> <trecho novo> <cenário> <rc esperado> <reason esperado> [verificação extra]
  local name="$1" vx="${7:-v_default}"
  mk_mutant "$2" "$3" || { bad "mutante $name: o trecho original não existe (o oráculo mudou? atualize o mutante)"; return; }
  $4; t0=$SECONDS; run_oracle "$REAL" --json verdict; DT=$((SECONDS-t0))
  if [ "$RC" != "$5" ] || [ "$(jget reason)" != "$6" ] || ! $vx; then bad "mutante $name VAZIO: o oráculo ORIGINAL já reprova o caso designado (rc=$RC reason=$(jget reason), esperado $5/$6)"; return; fi
  $4; t0=$SECONDS; run_oracle "$MUT" --json verdict; DT=$((SECONDS-t0))
  if [ "$RC" = "$5" ] && [ "$(jget reason)" = "$6" ] && $vx; then bad "mutante $name SOBREVIVEU (o caso designado ainda passa)"; else ok "mutante $name morreu"; fi
}
sc_bool()    { reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":true}' 0; }
sc_null()    { reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":null}' 0; }
sc_zero()    { reset; gate '{"cap":2,"host":"mbp","ok":true,"reason":"x","slot_cap":0}' 0; }
sc_rc1ok()   { reset; gate "$GATE_OK" 1; }
sc_rc0no()   { reset; gate '{"cap":2,"host":"mbp","ok":false,"reason":"x","slot_cap":null}' 0; }
sc_hetz()    { reset; gate '{"cap":2,"host":"hetzner","ok":true,"reason":"x","slot_cap":3}' 0; }
sc_max()     { reset; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"active"},{"template":"wa-worker-remote-mbp","state":"active"}]}'; }
sc_full()    { reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"active"}]}'; }
sc_asleep()  { reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"asleep"}]}'; }
sc_nostate() { reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp"}]}'; }
sc_byname()  { reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"","session_name":"wa-worker-remote-mbp-gaxyz","state":"active"}]}'; }
sc_hz()      { reset; sess '{"sessions":[{"template":"wa-worker-remote","state":"active","session_name":"wa-worker-remote-gawisp1"},{"template":"wa-worker","state":"active"}]}'; }
sc_closed()  { reset; gate '{"cap":1,"host":"mbp","ok":true,"reason":"x","slot_cap":3}'; sess '{"sessions":[{"template":"wa-worker-remote-mbp","state":"active","closed":true}]}'; }
sc_srcrc()   { reset; sess '{"sessions":[]}' 1; }
sc_badcfg()  { reset; export MBP_NODE_GATE_CMD='isto não é json'; }
sc_hang()    { reset; export MBP_NODE_GATE_CMD="[\"$T/hang.sh\"]" MBP_NODE_GATE_TIMEOUT_S=1; }
sc_refuse()  { reset; gate '{"cap":2,"host":"mbp","ok":false,"reason":"Athos no MBP","slot_cap":null}' 1; }
sc_refuse_hang() { sc_refuse; export MBP_NODE_SESSIONS_CMD="[\"$T/hang.sh\"]" MBP_NODE_SESSIONS_TIMEOUT_S=20; }
sc_nokeys()  { reset; gate '{"host":"mbp","ok":true,"reason":"x","slot_cap":3}' 0; }
sc_item()    { reset; sess '{"sessions":["x"]}' 0; }
mutant slot-booleano-vale     'if not isinstance(v, int) or isinstance(v, bool) or v < 1:'                  'if not isinstance(v, int) or v < 1:'                       sc_bool 2 gate_sem_teto
mutant slot-nulo-passa        'for nm, v in (("cap", cap), ("slot_cap", slot)):'                            'for nm, v in (("cap", cap),):'                             sc_null 2 gate_sem_teto
mutant slot-zero-passa        'or v < 1:'                                                                   'or v < 0:'                                                 sc_zero 2 gate_sem_teto
mutant cap-ausente-passa      'for nm, v in (("cap", cap), ("slot_cap", slot)):'                            'for nm, v in (("slot_cap", slot),):'                       sc_nokeys 2 gate_sem_teto
mutant rc1-com-ok-true-libera 'if rc == 0 and ok is True:'                                                  'if ok is True:'                                            sc_rc1ok 2 gate_incoerente
mutant rc0-com-ok-false-recusa 'if rc == 1 and ok is False:'                                                'if ok is False:'                                           sc_rc0no 2 gate_incoerente
mutant host-errado-passa      'if doc.get("host") != HOST:'                                                 'if False:'                                                 sc_hetz 2 gate_outro_host
mutant vaga-pelo-maior        'effective = min(cap, slot)'                                                  'effective = max(cap, slot)'                                sc_max 1 sem_vaga
mutant vaga-zero-passa        'if free < 1:'                                                                'if free < 0:'                                              sc_full 1 sem_vaga
mutant dormindo-ocupa         'closed|stopped|archived|drained|asleep'                                      'closed|stopped|archived|drained'                           sc_asleep 0 ok
mutant sem-estado-nao-ocupa   'if s.get("closed") is True or DEAD_STATE_RE.search(state):'                 'if s.get("closed") is True or not state or DEAD_STATE_RE.search(state):' sc_nostate 1 sem_vaga
mutant nome-nao-conta         'if tpl != TEMPLATE and not any(n and MBP_NAME_RE.search(n) for n in rest):'  'if tpl != TEMPLATE:'                                       sc_byname 1 sem_vaga
mutant conta-todas            'if tpl != TEMPLATE and not any(n and MBP_NAME_RE.search(n) for n in rest):'  'if False:'                                                 sc_hz 0 ok
mutant fechada-ocupa          'if s.get("closed") is True or DEAD_STATE_RE.search(state):'                  'if DEAD_STATE_RE.search(state):'                           sc_closed 0 ok
mutant rc-da-lista-ignorado   'if rc != 0:
        return ("unknown", "sessoes_falhou"'                                                                'if False:
        return ("unknown", "sessoes_falhou"'                                                                                                                    sc_srcrc 2 sessoes_falhou
mutant item-nao-objeto-ok     'if not isinstance(s, dict):
            return ("unknown", "sessoes_ilegiveis", "um item de sessions não é objeto")'                    'if False:
            return ("unknown", "sessoes_ilegiveis", "um item de sessions não é objeto")'                                                                          sc_item 2 sessoes_ilegiveis
mutant config-ruim-vira-padrao 'raise ValueError(f"{name} não é JSON ({e})")'                               'return default'                                            sc_badcfg 2 config
mutant prazo-sem-matar-o-grupo 'os.killpg(p.pid, signal.SIGKILL)'                                           'p.kill()'                                                  sc_hang 2 gate_prazo v_noorphan
mutant gate-recusa-espera-a-lista 'if g[0] == "local":'                                                     'if g[0] == "local" and sess.wait()[0] != "x":'              sc_refuse_hang 1 gate v_fast
echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
