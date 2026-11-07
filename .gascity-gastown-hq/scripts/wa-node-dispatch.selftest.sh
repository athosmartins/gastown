#!/usr/bin/env bash
# wa-node-dispatch.selftest.sh — hermético: bd e gc são stubs (um estado JSON em pasta temporária), o classificador é um stub com veredito escolhido + 1 caso com o real. (ga-2hd02v.1.10)
#
# Contents
#   Casos · Controle negativo · Como rodar
#
# CASOS: check devolve o veredito do classificador (0/10/11) · apply só escreve em bead aberta, sem dono e sem rota · a escrita é UMA e com comparação atômica (--if-assignee '' --if-status open)
#   · corrida perdida (bd rc 13) = 12 sem escrita · escrita sem conferência = desfeita (13) · slot do nó ocupado (bead ou sessão) = 12 · leitura de slot/sessão ilegível = 11 · base `label` exigida
#   · dry-run não escreve · bead ilegível ou de outro id = 11 · prefixo sem store = 11 · nunca roda `gc session new` · release só solta bead do alias E da rota, e confere · cada decisão deixa uma linha de log
#   · log que não grava não muda o resultado.
#   N SLOTS (ga-2hd02v.3): WA_NODE_SPAWN=pilot com WA_NODE_SLOTS aliases · escolhe o 1º alias sem bead e sem sessão viva · todos ocupados = 12 · leitura de qualquer alias ilegível = 11 · só `pilot` consulta o oráculo de capacidade
#   (local = 12; ausente, mudo, lento, incoerente ou sem `free` = 11; as beads atribuídas cuja sessão não subiu descontam da vaga) · a bead leva a marca pilot.wa_node_alias e NUNCA gc.routed_to · pool continua com 1 slot · N inválido = 1 ·
#   release solta as duas formas e só de alias do nó.
#   PULO DE ALIAS (ga-2hd02v.3.26): WA_NODE_SKIP_ALIASES (espaço ou vírgula) tira aliases de PICK e da sessão ociosa reaproveitada, mas eles seguem na conta de slots e de sessões vivas · tudo pulado = 12 slot-sem-alias-livre ·
#   token ilegível (glob, aspas, ;) é IGNORADO, nunca vira «pular todos» · vazio = o de sempre.
#   IDENTIDADE (ga-2hd02v.3): WA_NODE_SELF e WA_NODE_STORY trocam o nome que as mensagens e o comentário da bead usam e a bead que o comentário cita (o wrapper da bead de PS) · padrão = o texto da 1.10 byte a byte
#   nas partes fixas · vazio = padrão · valor com espaço, aspa, $, crase, ;, barra, quebra de linha ou acima de 64 caracteres = padrão (o valor vai para um comentário DA BEAD) · 64 exatos passam.
# CONTROLE NEGATIVO: cada mutante troca UMA linha numa cópia do script e o caso designado tem de reprovar; mutante que sobrevive reprova esta bateria.
# COMO RODAR: bash scripts/wa-node-dispatch.selftest.sh   (macOS /bin/bash 3.2 e Linux; precisa de jq e python3)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$HERE/wa-node-dispatch.sh"
CLS_REAL="$HERE/wa-node-classify.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-node-disp.XXXXXX")
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $1"; }
bad() { n=$((n+1)); echo "FAIL $1"; fails=$((fails+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq ausente"; exit 2; }

CITY="$T/city"; STORE="$T/wa-store"; mkdir -p "$CITY/.beads" "$CITY/.gc" "$STORE"
printf '{"prefix":"ga","path":"."}\n{"prefix":"wa","path":"../wa-store"}\n' > "$CITY/.beads/routes.jsonl"
STATE="$T/state.json"; CALLS="$T/bd.calls"; GCCALLS="$T/gc.calls"; SESS="$T/sessions.json"; CLSOUT="$T/cls.json"; CLSRC="$T/cls.rc"

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
    if os.environ.get("STUB_FAIL_LIST_ALIAS") and o.get("--assignee") == os.environ["STUB_FAIL_LIST_ALIAS"]: sys.exit(1)   # a leitura de UM alias falha, as outras respondem
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
        elif k == "--set-metadata":
            kk, vv = v.split("=", 1)
            if not os.environ.get("STUB_DROP_META"): b.setdefault("metadata", {})[kk] = vv   # DROP_META: a escrita pega o dono e o status e PERDE a marca/rota
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
    if not os.environ.get("STUB_KEEP_META"):   # KEEP_META: o dono sai e a marca/rota FICA
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
# o oráculo-stub é chamado como `python3 -I <script> --json verdict` (como o real): grava a chamada, dorme se pedido e devolve a saída e o código escolhidos
cat > "$T/cap.py" <<'PYEOF'
import os, sys, time
open(os.environ["STUB_CAP_CALLS"], "a").write(" ".join(sys.argv[1:]) + "\n")
time.sleep(float(os.environ.get("STUB_CAP_SLEEP", "0")))
sys.stdout.write(open(os.environ["STUB_CAP_OUT"]).read())
sys.exit(int(open(os.environ["STUB_CAP_RC"]).read().strip()))
PYEOF
# o classificador-stub é chamado como `python3 -I <script>` (como o real): ignora a bead e devolve o veredito escolhido
cat > "$T/cls.py" <<'PYEOF'
import os, sys
sys.stdin.read()
sys.stdout.write(open(os.environ["STUB_CLSOUT"]).read())
sys.exit(int(open(os.environ["STUB_CLSRC"]).read().strip()))
PYEOF

CAPOUT="$T/cap.json"; CAPRC="$T/cap.rc"; CAPCALLS="$T/cap.calls"
export STUB_CALLS="$CALLS" STUB_STATE="$STATE" STUB_GCCALLS="$GCCALLS" STUB_SESS="$SESS" STUB_CLSOUT="$CLSOUT" STUB_CLSRC="$CLSRC" STUB_CAP_OUT="$CAPOUT" STUB_CAP_RC="$CAPRC" STUB_CAP_CALLS="$CAPCALLS"
export GC_CITY="$CITY" WA_NODE_BD="$T/bd" WA_NODE_GC="$T/gc" WA_NODE_CLASSIFY="$T/cls.py" WA_NODE_LOG="$CITY/.gc/wa-node-route.jsonl" WA_NODE_TIMEOUT=20
export WA_NODE_CAPACITY="$T/cap.py"; unset WA_NODE_SPAWN WA_NODE_SLOTS WA_NODE_ALIAS WA_NODE_ALIAS_PREFIX WA_NODE_CAPACITY_TIMEOUT WA_NODE_SKIP_ALIASES   # o ambiente de quem roda não vaza para a bateria

NODE_TEXT='{"verdict":"node","basis":"text","reasons":["prova-no-texto:1-teste(s)+1-codigo"],"paths":[],"tests":[],"info":[]}'
NODE_LABEL='{"verdict":"node","basis":"label","reasons":["etiqueta-node:ok"],"paths":[],"tests":[],"info":[]}'
NODE_DERIV='{"verdict":"node","basis":"derivado","reasons":["prova-teste-derivado:1-teste(s)+1-codigo(s)"],"paths":[],"tests":[],"info":[]}'   # ga-2hd02v.3.15: prova mais fraca que a do texto
MINI='{"verdict":"mini","basis":"","reasons":["caminho-fora-do-filtro:queue.db"],"paths":[],"tests":[],"info":[]}'
UNK='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":[]}'
cls() { printf '%s' "$1" > "$CLSOUT"; printf '%s' "$2" > "$CLSRC"; }
CAP_OK='{"verdict":"node","reason":"free_slot","effective":3,"active":0,"free":3}'
CAP_LOCAL='{"verdict":"local","reason":"node_full","effective":3,"active":3,"free":0}'
cap() { printf '%s' "$1" > "$CAPOUT"; printf '%s' "$2" > "$CAPRC"; }
fresh() { # fresh [extra json mesclado na wa-t1]
  printf '{"wa-t1":{"id":"wa-t1","title":"t","status":"open","assignee":"","metadata":{}},"ga-x":{"id":"ga-x","title":"t","status":"open","assignee":"","metadata":{}}}' > "$STATE"
  if [ -n "${1:-}" ]; then jq -c --argjson m "$1" '."wa-t1" += $m' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; fi
  : > "$CALLS"; : > "$GCCALLS"; : > "$CITY/.gc/wa-node-route.jsonl"; echo '{"ok":true,"sessions":[]}' > "$SESS"; cls "$NODE_TEXT" 0
  cap "$CAP_OK" 0; : > "$CAPCALLS"
  unset STUB_FAIL_SHOW STUB_SHOW_OTHER STUB_FAIL_LIST STUB_LIST_GARBAGE STUB_UPDATE_RC STUB_NOOP_UPDATE STUB_PARTIAL_UPDATE STUB_UNDO_RC STUB_FAIL_GC STUB_GC_SLEEP STUB_LAND_RC STUB_FAIL_SHOW_AFTER_UPDATE STUB_FAIL_LIST_ALIAS STUB_CAP_SLEEP STUB_DROP_META STUB_KEEP_META
}
SCRIPT="$REAL"; OUT=""; RC=0; MUT_NAME=""; MUT_M=""
d() { OUT=$("$SCRIPT" "$@" 2>&1); RC=$?; }                       # roda e guarda saída + rc
wrote() { grep -q '^-C|[^|]*|update|' "$CALLS" 2>/dev/null; }      # houve alguma escrita (update)?
bead() { jq -r "$1" "$STATE"; }
expect_rc() { # expect_rc <rótulo> <rc esperado> [nada escrito: w0]
  if [ "$RC" != "$2" ]; then bad "$1 (rc=$RC, esperado $2; saída: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200))"; return 1; fi
  if [ "${3:-}" = w0 ] && wrote; then bad "$1 (rc ok, mas houve escrita: $(grep update "$CALLS" | head -n 1))"; return 1; fi
  ok "$1"
}

# ---- check
fresh; cls "$NODE_TEXT" 0; d check wa-t1;            expect_rc "check: node -> 0" 0 w0 && { printf '%s' "$OUT" | grep -q '"verdict":"node"' && ok "check: imprime o JSON do classificador" || bad "check: JSON ausente ($OUT)"; }
fresh; cls "$MINI" 10;     d check wa-t1;            expect_rc "check: mini -> 10" 10 w0
fresh; cls "$UNK" 11;      d check wa-t1;            expect_rc "check: unknown -> 11" 11 w0
fresh; cls "$NODE_TEXT" 0; d check ga-x --store "$T"; expect_rc "check: --store explícito vale" 0 w0
# ---- apply: caminho feliz
fresh; d apply wa-t1
expect_rc "apply: bead livre + node -> 0" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-1 ] && [ "$(bead '."wa-t1".status')" = in_progress ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"]')" = wa-worker-remote ] && ok "apply: atribuiu ao alias, em andamento, rota carimbada" || bad "apply: estado final errado: $(jq -c '."wa-t1"' "$STATE")"
[ "$(grep -c '|update|' "$CALLS")" = 1 ] && ok "apply: UMA escrita (update)" || bad "apply: $(grep -c '|update|' "$CALLS") escritas"
grep '|update|' "$CALLS" | head -n 1 | grep -q -- '--if-assignee||--if-status|open|' && ok "apply: a escrita compara antes de escrever (--if-assignee '' --if-status open)" || bad "apply: escrita sem comparação atômica: $(grep '|update|' "$CALLS" | head -n 1)"
[ "$(bead '."wa-t1".comments | length')" = 1 ] && ok "apply: deixa 1 comentário na bead" || bad "apply: comentários: $(bead '."wa-t1".comments')"
grep -q 'session new' "$GCCALLS" && bad "apply: rodou gc session new (a duplicata que o dedup derruba)" || ok "apply: não roda gc session new"
[ "$(jq -r '.event+":"+(.rc|tostring)' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1)" = "apply:0" ] && ok "apply: grava a decisão no log" || bad "apply: log: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# ---- apply: bead não elegível
fresh '{"assignee":"mila-wa"}';                   d apply wa-t1; expect_rc "apply: bead com dono -> 12 sem escrita" 12 w0
fresh '{"metadata":{"gc.routed_to":"wa-worker"}}'; d apply wa-t1; expect_rc "apply: bead já com rota -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress"}';                 d apply wa-t1; expect_rc "apply: bead em andamento -> 12 sem escrita" 12 w0
fresh '{"status":"closed"}';                      d apply wa-t1; expect_rc "apply: bead fechada -> 12 sem escrita" 12 w0
# ---- apply: veredito
fresh; cls "$MINI" 10; d apply wa-t1; expect_rc "apply: mini -> 10 sem escrita" 10 w0
fresh; cls "$UNK" 11;  d apply wa-t1; expect_rc "apply: unknown -> 11 sem escrita" 11 w0
fresh; cls "$NODE_TEXT" 0; d apply wa-t1 --basis label; expect_rc "apply --basis label com veredito por texto -> 10 sem escrita" 10 w0
fresh; cls "$NODE_LABEL" 0; d apply wa-t1 --basis label; expect_rc "apply --basis label com a etiqueta -> 0" 0
fresh; cls "$NODE_TEXT" 0; d apply wa-t1 --basis any; expect_rc "apply --basis any com texto -> 0" 0
fresh; cls "$NODE_DERIV" 0; d apply wa-t1 --basis label; expect_rc "apply --basis label com a prova derivada (teste do repo) -> 10 sem escrita: derivado nunca passa no modo label" 10 w0
fresh; cls "$NODE_DERIV" 0; d apply wa-t1 --basis any; expect_rc "apply --basis any com a prova derivada -> 0" 0
# ---- apply/check: o exit code e o JSON do classificador têm que CONCORDAR (terceiro estado, ga-9636op). Classificador que caiu, foi morto, não imprimiu, imprimiu o que não se lê ou cujo exit
#      code e veredito discordam NUNCA manda a bead ao nó: vira 11 ("não consegui decidir"), sem escrita. Um código cru do classificador (2, 12, 13, 124, 137) também não vaza: o chamador lê 2 como
#      "uso", 12 como "não elegível" e 13/124/137 como "a escrita pode ter acontecido".
fresh; cls "$MINI" 0;               d apply wa-t1; expect_rc "apply: classificador sai 0 mas o JSON diz mini -> 11 sem escrita" 11 w0
fresh; cls "" 0;                    d apply wa-t1; expect_rc "apply: classificador sai 0 sem imprimir nada -> 11 sem escrita" 11 w0
fresh; cls "not json" 0;            d apply wa-t1; expect_rc "apply: classificador sai 0 com saída que não é JSON -> 11 sem escrita" 11 w0
fresh; cls '{"basis":"text"}' 0;    d apply wa-t1; expect_rc "apply: classificador sai 0 e o JSON não tem veredito -> 11 sem escrita" 11 w0
fresh; cls "$NODE_TEXT" 10;         d apply wa-t1; expect_rc "apply: classificador sai 10 mas o JSON diz node -> 11 sem escrita" 11 w0
fresh; cls "$NODE_TEXT" 1;          d apply wa-t1; expect_rc "apply: classificador cai (rc 1) deixando um JSON de node -> 11 sem escrita" 11 w0
fresh; cls "" 137;                  d apply wa-t1; expect_rc "apply: classificador morto (rc 137) não vaza o 137 -> 11 sem escrita" 11 w0
fresh; cls "$UNK" 2;                d apply wa-t1; expect_rc "apply: classificador com o código de uso (2) não vaza -> 11 sem escrita" 11 w0
fresh; cls "$UNK" 12;               d apply wa-t1; expect_rc "apply: classificador com 12 não vaza como 'não elegível' -> 11 sem escrita" 11 w0
fresh; cls "$MINI" 0;               d check wa-t1; expect_rc "check: classificador sai 0 mas o JSON diz mini -> 11" 11 w0
fresh; cls "not json" 0;            d check wa-t1; expect_rc "check: classificador sai 0 com saída ilegível -> 11" 11 w0
printf '%s' "$OUT" | jq -e '.verdict == "unknown"' >/dev/null 2>&1 && ok "check: a resposta incoerente continua sendo um JSON (unknown)" || bad "check: a resposta incoerente não é um JSON unknown ($OUT)"
fresh; cls "$MINI" 0;               d apply wa-t1; [ "$(jq -r 'select(.event=="classify" or .event=="apply") | .event+":"+(.rc|tostring)' "$CITY/.gc/wa-node-route.jsonl" | tr '\n' ' ')" = "classify:11 apply:11 " ] && ok "apply: o classificador incoerente deixa o rastro no log (classify:11 e a decisão apply:11)" || bad "apply: log do incoerente: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# ---- apply: slot do nó
fresh; jq -c '. + {"wa-busy":{"id":"wa-busy","status":"in_progress","assignee":"wa-worker-remote-1","metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "apply: slot ocupado por bead em andamento -> 12 sem escrita" 12 w0
fresh; export STUB_FAIL_LIST=1;    d apply wa-t1; expect_rc "apply: leitura do slot falha -> 11 sem escrita" 11 w0
fresh; export STUB_LIST_GARBAGE=1; d apply wa-t1; expect_rc "apply: leitura do slot que não é lista -> 11 sem escrita" 11 w0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","closed":false,"alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; expect_rc "apply: sessão do template ativa -> 12 sem escrita" 12 w0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"closed","alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; expect_rc "apply: sessão antiga já fechada (estado) não ocupa o slot -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker","state":"active","alias":"wa-worker-adhoc-1"}]}' > "$SESS"; d apply wa-t1; expect_rc "apply: wa-worker do mini ativo não ocupa o slot do nó -> 0" 0
fresh; export STUB_FAIL_GC=1;      d apply wa-t1; expect_rc "apply: lista de sessões falha -> 11 sem escrita" 11 w0
fresh; echo 'not json' > "$SESS";   d apply wa-t1; expect_rc "apply: lista de sessões ilegível -> 11 sem escrita" 11 w0
fresh; echo '{"a":1}' > "$SESS";    d apply wa-t1; expect_rc "apply: resposta sem o campo sessions -> 11 sem escrita" 11 w0
fresh; echo '{"ok":true,"sessions":null}' > "$SESS"; d apply wa-t1; expect_rc "apply: sessions que não é lista -> 11 sem escrita" 11 w0
fresh; echo '[]' > "$SESS"; d apply wa-t1; expect_rc "apply: array solto (não é o formato do gc) -> 11 sem escrita" 11 w0
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","closed":true,"alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; expect_rc "apply: sessão com closed=true não ocupa o slot -> 0" 0
fresh; echo '{"ok":true,"sessions":[{"template":"gastown.dog","state":"start-pending","closed":false,"alias":"gastown.dog-5"},{"template":"wa-worker-remote","state":"start-pending","closed":false,"alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; expect_rc "apply: sessão do nó ainda iniciando (start-pending) ocupa o slot -> 12 sem escrita" 12 w0
# ---- prazo próprio da leitura de sessões (gc session list levou 14–22 s na mini carregada; o prazo geral é 20 s)
fresh; export STUB_GC_SLEEP=3; WA_NODE_TIMEOUT=2 WA_NODE_SESSION_TIMEOUT=15 d apply wa-t1; expect_rc "apply: sessões lentas (3 s) cabem no prazo próprio mesmo com o geral em 2 s -> 0" 0
fresh; export STUB_GC_SLEEP=3; WA_NODE_SESSION_TIMEOUT=1 d apply wa-t1; expect_rc "apply: sessões mais lentas que o prazo próprio -> 11 sem escrita" 11 w0
fresh; export STUB_GC_SLEEP=3; WA_NODE_TIMEOUT=2 WA_NODE_SESSION_TIMEOUT=abc d apply wa-t1; expect_rc "apply: prazo próprio ilegível volta ao padrão (60 s), não ao geral -> 0" 0
# ---- apply: dry-run, corrida, conferência
fresh; d apply wa-t1 --dry-run; expect_rc "apply --dry-run -> 0 sem escrita" 0 w0
[ "$(grep -c '|comment|' "$CALLS")" = 0 ] && ok "apply --dry-run: sem comentário" || bad "apply --dry-run comentou"
fresh; export STUB_UPDATE_RC=13; d apply wa-t1; expect_rc "apply: corrida perdida (bd rc 13) -> 12" 12
fresh; export STUB_UPDATE_RC=1;  d apply wa-t1; expect_rc "apply: bd update falha -> 13" 13
fresh; export STUB_NOOP_UPDATE=1; d apply wa-t1; expect_rc "apply: escrita que não pegou (conferência falha) -> 13" 13
grep '|update|' "$CALLS" | tail -n 1 | grep -q -- '--if-assignee|wa-worker-remote-1|--assignee||' && ok "apply: conferência falha -> tenta desfazer (só se ainda for do alias)" || bad "apply: sem desfazer: $(grep '|update|' "$CALLS" | tail -n 1)"
printf '%s' "$OUT" | grep -q 'desfeita' && ! printf '%s' "$OUT" | grep -q 'NÃO desfeita' && ok "apply: conferência falha e o desfazer pega -> a mensagem diz 'desfeita'" || bad "apply: mensagem do desfazer que pegou: $OUT"
# a escrita que NEM PEGOU não deixa nada nosso: o desfazer reprova (comparação atômica) mas a bead está limpa, então "desfeita" é verdade (o rc do desfazer não diz o estado; reler diz)
[ "$(jq -r 'select(.event=="apply") | .detail' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1)" = "conferencia-falhou-desfeito" ] && ok "apply: escrita que nem pegou, bead limpa -> o log diz desfeito" || bad "apply: log da escrita que nem pegou: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# a escrita que pegou SÓ O DONO deixa a bead atribuída ao nó: o desfazer tem de limpar, e se ele falhar a mensagem e o log não podem anunciar "desfeito" (a bead ficaria atribuída ao nó e quem lê acreditaria que não)
fresh; export STUB_PARTIAL_UPDATE=1; d apply wa-t1; expect_rc "apply: escrita que pegou só o dono, conferência falha, desfazer pega -> 13" 13
[ -z "$(bead '."wa-t1".assignee')" ] && printf '%s' "$OUT" | grep -q 'desfeita' && ! printf '%s' "$OUT" | grep -q 'NÃO desfeita' && ok "apply: desfazer que pegou -> a bead volta sem dono e a mensagem diz 'desfeita'" || bad "apply: estado/mensagem do desfazer que pegou: $(jq -c '."wa-t1"' "$STATE") / $OUT"
fresh; export STUB_PARTIAL_UPDATE=1 STUB_UNDO_RC=1; d apply wa-t1; expect_rc "apply: escrita que pegou só o dono E o desfazer também falha -> 13" 13
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-1 ] && ok "apply: (confirmação do cenário) a bead ficou atribuída ao nó" || bad "apply: cenário errado, bead: $(jq -c '."wa-t1"' "$STATE")"
printf '%s' "$OUT" | grep -q 'NÃO desfeita' && ok "apply: desfazer que falhou NÃO é anunciado como desfeito (mensagem)" || bad "apply: a mensagem mente sobre o desfazer: $OUT"
[ "$(jq -r 'select(.event=="apply") | .detail' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1)" = "conferencia-falhou-NAO-desfeito" ] && ok "apply: desfazer que falhou NÃO é anunciado como desfeito (log)" || bad "apply: o log mente sobre o desfazer: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# ---- escrita que o bd diz ter FALHADO (rc ≠ 0 e ≠ 13: prazo estourado, morto, bd fora) — ga-9636op, gate-fix 1. O rc de um update morto por prazo NÃO diz o estado (o servidor pode ter gravado): quem diz é a releitura.
#      Antes o ramo morria às cegas (13 "nada garantido") sem reler e sem desfazer: uma escrita que pegou deixava a bead atribuída ao nó sem que ninguém soubesse, e o Pilot, uma varredura depois, a lia como "livre".
#      Agora: a releitura confere (o rc mentiu) = segue como sucesso; algo nosso = desfaz como na conferência; nada nosso = 13 "nada garantido" (um update morto por prazo pode ainda entrar: o Pilot segura a bead e relê).
fresh; export STUB_UPDATE_RC=124; d apply wa-t1
expect_rc "apply: bd update morto por prazo (124) que não gravou nada -> 13" 13
tail -n 1 "$CALLS" | grep -q '^-C|[^|]*|show|' && ok "apply: depois da escrita que falhou, a ÚLTIMA chamada ao bd é uma releitura (show)" || bad "apply: sem releitura depois da escrita que falhou: $(tail -n 1 "$CALLS")"
[ -z "$(bead '."wa-t1".assignee')" ] && ok "apply: escrita que não gravou: a bead continua livre" || bad "apply: bead: $(jq -c '."wa-t1"' "$STATE")"
printf '%s' "$OUT" | grep -q 'pode ainda entrar' && ok "apply: escrita que falhou sem nada nosso na releitura: a mensagem diz que uma escrita morta por prazo pode ainda entrar" || bad "apply: mensagem: $OUT"
printf '%s' "$OUT" | grep -q 'desfeita' && bad "apply: escrita que nem pegou não é 'desfeita' (a mensagem mente: $OUT)" || ok "apply: escrita que falhou não é anunciada como 'desfeita'"
[ "$(jq -r 'select(.event=="apply") | .detail' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1)" = "escrita-falhou-sem-nada-nosso rc=124" ] && ok "apply: o log diz escrita-falhou-sem-nada-nosso e o rc do bd" || bad "apply: log: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# a escrita PEGOU por inteiro e só a resposta se perdeu (prazo, processo morto): a releitura confere, então é um sucesso — 0, e sem desfazer o que pegou
fresh; export STUB_LAND_RC=124; d apply wa-t1; expect_rc "apply: escrita que gravou tudo e o bd saiu 124 (resposta perdida) -> 0 (a releitura confere)" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-1 ] && [ "$(bead '."wa-t1".status')" = in_progress ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"]')" = wa-worker-remote ] && ok "apply: resposta perdida: a bead fica do nó (dono, status e rota)" || bad "apply: estado: $(jq -c '."wa-t1"' "$STATE")"
[ "$(grep -c '|update|' "$CALLS")" = 1 ] && ok "apply: resposta perdida: UMA escrita só, sem desfazer o que pegou" || bad "apply: escritas: $(grep -c '|update|' "$CALLS")"
[ "$(bead '."wa-t1".comments | length')" = 1 ] && ok "apply: resposta perdida: deixa o comentário como num sucesso" || bad "apply: comentários: $(bead '."wa-t1".comments')"
[ "$(jq -r 'select(.event=="apply") | (.rc|tostring) + " " + .detail' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1)" = "0 despachada para wa-worker-remote-1 (text) [bd update rc=124, a releitura confere]" ] && ok "apply: resposta perdida: o log diz que o rc do bd foi 124 e que a releitura conferiu" || bad "apply: log: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# pegou SÓ O DONO e o bd saiu 137: a conferência reprova e o desfazer limpa (antes: 13 às cegas e a bead ficava atribuída ao nó)
fresh; export STUB_LAND_RC=137 STUB_PARTIAL_UPDATE=1; d apply wa-t1; expect_rc "apply: escrita que pegou só o dono e o bd saiu 137 -> 13" 13
[ -z "$(bead '."wa-t1".assignee')" ] && grep '|update|' "$CALLS" | tail -n 1 | grep -q -- '--if-assignee|wa-worker-remote-1|--assignee||' && ok "apply: ...e o desfazer limpou o dono (a bead não fica atribuída ao nó)" || bad "apply: depois do 137 a bead: $(jq -c '."wa-t1"' "$STATE")"
# pegou só o dono, o bd saiu 124 e o desfazer também falha: a bead FICA do nó, e nada anuncia "desfeita"
fresh; export STUB_LAND_RC=124 STUB_PARTIAL_UPDATE=1 STUB_UNDO_RC=1; d apply wa-t1; expect_rc "apply: pegou só o dono, bd saiu 124 e o desfazer falha -> 13" 13
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-1 ] && printf '%s' "$OUT" | grep -q 'NÃO desfeita' && [ "$(jq -r 'select(.event=="apply") | .detail' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1)" = "escrita-falhou-NAO-desfeito rc=124" ] && ok "apply: ...a bead segue atribuída ao nó e a mensagem e o log dizem NÃO desfeita" || bad "apply: estado/mensagem/log: $(jq -c '."wa-t1"' "$STATE") / $OUT / $(tail -n 1 "$CITY/.gc/wa-node-route.jsonl")"
# a escrita gravou por inteiro, mas a releitura TAMBÉM falha: não dá para dizer que a bead está solta (nem que é do nó): 13 e "NÃO desfeita", nunca "desfeita"
fresh; export STUB_LAND_RC=124 STUB_FAIL_SHOW_AFTER_UPDATE=1; d apply wa-t1; expect_rc "apply: escrita gravou, bd saiu 124 e a releitura falha -> 13" 13
printf '%s' "$OUT" | grep -q 'NÃO desfeita' && ok "apply: releitura ilegível depois da escrita: a mensagem não diz 'desfeita'" || bad "apply: mensagem: $OUT"
# ---- leitura da bead e do store
fresh; export STUB_FAIL_SHOW=1;  d apply wa-t1; expect_rc "bead ilegível -> 11 sem escrita" 11 w0
fresh; export STUB_SHOW_OTHER=1; d apply wa-t1; expect_rc "show devolve outro id -> 11 sem escrita" 11 w0
fresh; d apply zz-1;                expect_rc "prefixo sem store em routes.jsonl -> 11" 11 w0
fresh; d apply wa-t1 --store "$T/nao-existe"; expect_rc "--store inexistente -> 11" 11 w0
fresh; mv "$CITY/.beads/routes.jsonl" "$CITY/.beads/routes.bak"; d apply wa-t1; expect_rc "routes.jsonl ausente -> 11" 11 w0; mv "$CITY/.beads/routes.bak" "$CITY/.beads/routes.jsonl"
# ---- uso
d apply 'wa t1';                       expect_rc "id fora do formato -> 2" 2
d apply;                               expect_rc "sem bead -> 2" 2
d frob wa-t1;                          expect_rc "comando desconhecido -> 2" 2
d apply wa-t1 --basis x;               expect_rc "--basis inválido -> 2" 2
d apply wa-t1 --zzz;                   expect_rc "argumento desconhecido -> 2" 2
fresh; WA_NODE_LOG=/dev/null/x/y d apply wa-t1; expect_rc "log que não grava não muda o resultado" 0
fresh; WA_NODE_TIMEOUT=abc d apply wa-t1; expect_rc "prazo ilegível volta ao padrão" 0
# ---- release
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'
d release wa-t1; expect_rc "release: bead do alias e da rota -> 0" 0
[ -z "$(bead '."wa-t1".assignee')" ] && [ "$(bead '."wa-t1".metadata["gc.routed_to"] // "vazio"')" = vazio ] && ok "release: dono e rota soltos" || bad "release: estado: $(jq -c '."wa-t1"' "$STATE")"
fresh '{"status":"in_progress","assignee":"mila-wa","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release wa-t1; expect_rc "release: dono é outro -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker"}}'; d release wa-t1; expect_rc "release: rota é outra -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; export STUB_UPDATE_RC=1; d release wa-t1; expect_rc "release: bd update falha -> 13" 13
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; export STUB_NOOP_UPDATE=1; d release wa-t1; expect_rc "release: escrita que não pegou -> 13" 13

# ---- N slots (ga-2hd02v.3): WA_NODE_SPAWN=pilot com WA_NODE_SLOTS aliases wa-worker-remote-1..N. O Pilot abre a sessão do alias (receita provada do dog-remote); a bead leva o dono e a marca
#      pilot.wa_node_alias, SEM gc.routed_to (a rota faria o pool abrir uma 2ª sessão). Em `pool` (padrão) nada muda: 1 slot, rota, o pool cria a sessão.
pm() { WA_NODE_SPAWN=pilot WA_NODE_SLOTS="${SL:-3}" d "$@"; }                  # roda no modo pilot com SL slots (3 se não dito)
busyat() { jq -c --arg a "wa-worker-remote-$1" '. + {("wa-busy-"+$a):{"id":("wa-busy-"+$a),"status":"in_progress","assignee":$a,"metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; }   # uma bead em andamento do alias N
sessions() { printf '{"ok":true,"sessions":%s}' "$1" > "$SESS"; }                                              # sessions '<array json>'
live() { printf '{"template":"wa-worker-remote","state":"active","closed":false,"alias":"wa-worker-remote-%s"}' "$1"; }   # uma sessão viva do alias N
who() { bead '."wa-t1".assignee'; }
mark() { bead '."wa-t1".metadata["pilot.wa_node_alias"] // "vazio"'; }
rota() { bead '."wa-t1".metadata["gc.routed_to"] // "vazio"'; }
ncap() { wc -l < "$CAPCALLS" | tr -d ' '; }                                   # quantas vezes o oráculo foi chamado

# -- caminho feliz e a escolha do alias
fresh; pm apply wa-t1
expect_rc "slots: bead livre, 3 slots, oráculo diz node -> 0" 0
[ "$(who)" = wa-worker-remote-1 ] && [ "$(bead '."wa-t1".status')" = in_progress ] && ok "slots: sem nada ocupado, o 1º alias é o -1" || bad "slots: estado: $(jq -c '."wa-t1"' "$STATE")"
[ "$(mark)" = wa-worker-remote-1 ] && [ "$(rota)" = vazio ] && ok "slots: a bead leva a marca do alias e NÃO leva gc.routed_to" || bad "slots: marca=$(mark) rota=$(rota)"
[ "$(grep -c '|update|' "$CALLS")" = 1 ] && ok "slots: UMA escrita" || bad "slots: $(grep -c '|update|' "$CALLS") escritas"
grep '|update|' "$CALLS" | head -n 1 | grep -q -- '--if-assignee||--if-status|open|' && ok "slots: a escrita continua com comparação atômica" || bad "slots: escrita sem comparação: $(grep '|update|' "$CALLS" | head -n 1)"
grep -q 'session new' "$GCCALLS" && bad "slots: o despachante rodou gc session new (quem abre a sessão é o Pilot)" || ok "slots: o despachante não roda gc session new"
[ "$(bead '."wa-t1".comments[0]' | grep -c 'O Pilot abre a sessão')" = 1 ] && ok "slots: o comentário diz que o Pilot abre a sessão" || bad "slots: comentário: $(bead '."wa-t1".comments')"
[ "$(ncap)" = 1 ] && grep -q -- '--json verdict' "$CAPCALLS" && ok "slots: consultou o oráculo uma vez (--json verdict)" || bad "slots: chamadas ao oráculo: $(cat "$CAPCALLS")"
fresh; busyat 1; pm apply wa-t1; expect_rc "slots: alias -1 ocupado -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && ok "slots: -1 ocupado, vai para o -2" || bad "slots: foi para $(who)"
fresh; busyat 1; busyat 2; pm apply wa-t1; expect_rc "slots: -1 e -2 ocupados -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "slots: -1 e -2 ocupados, vai para o -3" || bad "slots: foi para $(who)"
fresh; busyat 1; busyat 3; pm apply wa-t1; expect_rc "slots: -1 e -3 ocupados -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && ok "slots: buraco no meio: vai para o -2" || bad "slots: foi para $(who)"
fresh; busyat 1; busyat 2; busyat 3; pm apply wa-t1; expect_rc "slots: os 3 aliases ocupados -> 12 sem escrita" 12 w0
printf '%s' "$OUT" | grep -q 'estão ocupados' && ok "slots: a mensagem diz que os slots estão ocupados" || bad "slots: mensagem: $OUT"
[ "$(ncap)" = 0 ] && ok "slots: com tudo ocupado o oráculo nem é consultado (a leitura lenta vem por último)" || bad "slots: consultou o oráculo à toa"
fresh; busyat 1; busyat 2; SL=2 pm apply wa-t1; expect_rc "slots: 2 slots, os 2 ocupados -> 12 (o -3 não existe)" 12 w0
fresh; busyat 1; SL=1 pm apply wa-t1; expect_rc "slots: 1 slot em modo pilot, o -1 ocupado -> 12" 12 w0
# -- sessões vivas
fresh; sessions "[$(live 1)]"; pm apply wa-t1; expect_rc "slots: -1 sem bead mas com sessão viva -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && ok "slots: sessão viva sem bead (ociosa) não é reaproveitada: vai para o -2" || bad "slots: foi para $(who)"
fresh; sessions "[$(live 1),$(live 2),$(live 3)]"; pm apply wa-t1; expect_rc "slots: 3 sessões vivas = os 3 slots -> 12 sem escrita" 12 w0
fresh; sessions '[{"template":"wa-worker-remote","state":"active","closed":false,"alias":""},{"template":"wa-worker-remote","state":"active","closed":false,"alias":""},{"template":"wa-worker-remote","state":"active","closed":false}]'
pm apply wa-t1; expect_rc "slots: 3 sessões do template SEM alias também enchem os 3 slots -> 12 sem escrita" 12 w0
fresh; sessions "[$(live 1),$(live 2)]"; SL=2 pm apply wa-t1; expect_rc "slots: 2 slots com as 2 sessões vivas -> 12 sem escrita" 12 w0
fresh; sessions "[{\"template\":\"wa-worker-remote\",\"state\":\"closed\",\"alias\":\"wa-worker-remote-1\"},$(live 2)]"; pm apply wa-t1; expect_rc "slots: sessão fechada não conta -> 0" 0
[ "$(who)" = wa-worker-remote-1 ] && ok "slots: o alias da sessão fechada volta a ser o 1º livre" || bad "slots: foi para $(who)"
fresh; sessions '[{"template":"wa-worker","state":"active","alias":"wa-worker-adhoc-1"}]'; pm apply wa-t1; expect_rc "slots: wa-worker do mini ativo não ocupa slot do nó -> 0" 0
fresh; busyat 1; sessions "[$(live 2)]"; pm apply wa-t1; expect_rc "slots: -1 com bead (sessão ainda não subiu) e -2 com sessão viva -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "slots: pula o alias com bead E o alias com sessão" || bad "slots: foi para $(who)"
# -- sessão DORMINDO (idle_timeout de 15 min: ela dorme SEM soltar o alias). Modo pilot: não conta como viva e o alias volta a ser escolhido (o Pilot a acorda). Modo pool: segue segurando o slot.
asleep() { printf '{"template":"wa-worker-remote","state":"asleep","closed":false,"alias":"wa-worker-remote-%s"}' "$1"; }   # uma sessão dormindo do alias N
fresh; sessions "[$(asleep 1)]"; SL=1 pm apply wa-t1; expect_rc "dormindo: 1 slot em modo pilot, a sessão do -1 dormindo -> 0 (o slot não queima na 1ª ociosidade)" 0
[ "$(who)" = wa-worker-remote-1 ] && ok "dormindo: o alias da sessão dormindo é o escolhido (o Pilot a acorda)" || bad "dormindo: foi para $(who)"
fresh; sessions "[$(asleep 1),$(asleep 2),$(asleep 3)]"; pm apply wa-t1; expect_rc "dormindo: 3 sessões dormindo não enchem os 3 slots -> 0" 0
[ "$(who)" = wa-worker-remote-1 ] && ok "dormindo: com as 3 dormindo, vai ao 1º alias" || bad "dormindo: foi para $(who)"
fresh; sessions "[$(live 1),$(asleep 2),$(live 3)]"; pm apply wa-t1; expect_rc "dormindo: 2 vivas + 1 dormindo em 3 slots -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && ok "dormindo: o único alias reaproveitável é o da sessão dormindo (-2)" || bad "dormindo: foi para $(who)"
fresh; sessions "[$(live 1),$(live 2),$(asleep 3)]"; SL=2 pm apply wa-t1; expect_rc "dormindo: 2 slots já com 2 vivas, a dormindo é o -3 que não existe -> 12" 12 w0
fresh; sessions "[$(asleep 1)]"; d apply wa-t1; expect_rc "dormindo: modo POOL, a sessão dormindo segue segurando o slot -> 12 (o pool não muda)" 12 w0
fresh; sessions "[$(asleep 1)]"; WA_NODE_SPAWN=pool WA_NODE_SLOTS=3 d apply wa-t1; expect_rc "dormindo: modo pool com WA_NODE_SLOTS=3 (forçado a 1): ainda 12" 12 w0
fresh; sessions '[{"template":"wa-worker","state":"asleep","closed":false,"alias":"wa-worker-remote-1"}]'; SL=1 pm apply wa-t1; expect_rc "dormindo: sessão dormindo de OUTRO template com o alias do nó segue viva -> 12" 12 w0
fresh; sessions '[{"template":"wa-worker-remote","state":"suspended","closed":false,"alias":"wa-worker-remote-1"}]'; SL=1 pm apply wa-t1; expect_rc "dormindo: estado que não conheço (suspended) conta como vivo -> 12" 12 w0
fresh; sessions '[{"template":"wa-worker-remote","state":"Asleep","closed":false,"alias":"wa-worker-remote-1"}]'; SL=1 pm apply wa-t1; expect_rc "dormindo: 'Asleep' (outra grafia) não é o estado que conheço -> vivo -> 12" 12 w0
# -- sessão viva e OCIOSA (ga-2hd02v.3.12). Sem bead no alias E quieta há >= WA_NODE_IDLE_SECS (padrão 300 s) ela é VAGA, não lugar tomado. Antes, o `live >= SLOTS` contava toda sessão viva: 3 sessões
#    (uma já sem bead) davam "sessao-viva n=3" em toda varredura (27 recusas em ~19 h no wa-node-route.jsonl, a fila node:ok parada). Três estados: ociosa PROVADA = vaga; ocupada = bead em andamento no alias
#    OU quieta há pouco; não deu para saber (last_active ausente/ilegível/no futuro, estado que não é `active`, outro template, alias repetido) = OCUPADA, o inerte.
ago() { python3 -I -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"; }   # o carimbo de N segundos atrás (negativo = no futuro)
quiet() { printf '{"template":"wa-worker-remote","state":"active","closed":false,"alias":"wa-worker-remote-%s","last_active":"%s"}' "$1" "$(ago "${2:-600}")"; }   # sessão viva do alias N, quieta há $2 s (600 se não dito)
closedat() { jq -c --arg a "wa-worker-remote-$1" '. + {("wa-done-"+$a):{"id":("wa-done-"+$a),"status":"closed","assignee":$a,"metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; }   # uma bead FECHADA do alias N
# o caso medido: 3 sessões vivas, o -3 acabou de fechar a bead (fechada, sem bead em andamento), fila node:ok
fresh; busyat 1; busyat 2; closedat 3; sessions "[$(live 1),$(live 2),$(quiet 3)]"; pm apply wa-t1
expect_rc "ociosa: 3 sessões vivas, o -3 sem bead em andamento e quieto há 10 min -> 0 (antes: 12 sessao-viva)" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "ociosa: a bead vai para a sessão ociosa (-3), não para um alias novo" || bad "ociosa: foi para $(who)"
[ "$(mark)" = wa-worker-remote-3 ] && [ "$(rota)" = vazio ] && ok "ociosa: leva a marca do alias e nunca gc.routed_to" || bad "ociosa: marca=$(mark) rota=$(rota)"
[ "$(grep -c '|update|' "$CALLS")" = 1 ] && ok "ociosa: UMA escrita" || bad "ociosa: $(grep -c '|update|' "$CALLS") escritas"
grep '|update|' "$CALLS" | head -n 1 | grep -q -- '--if-assignee||--if-status|open|' && ok "ociosa: a escrita segue com comparação atômica" || bad "ociosa: escrita sem comparação"
grep -q 'session new' "$GCCALLS" && bad "ociosa: o despachante rodou gc session new" || ok "ociosa: o despachante não abre sessão (a do alias já está viva)"
grep -q 'sessao-viva' "$CITY/.gc/wa-node-route.jsonl" && bad "ociosa: o log ainda registra sessao-viva" || ok "ociosa: nenhuma recusa sessao-viva no log"
grep -q 'reaproveitada' "$CITY/.gc/wa-node-route.jsonl" && ok "ociosa: o log diz que a sessão ociosa foi reaproveitada (rastro)" || bad "ociosa: log sem rastro: $(cat "$CITY/.gc/wa-node-route.jsonl")"
bead '."wa-t1".comments[0]' | grep -q 'já está viva' && ok "ociosa: o comentário da bead diz que a sessão do alias já estava viva" || bad "ociosa: comentário: $(bead '."wa-t1".comments[0]')"
[ "$(bead '."wa-t1".comments[0]' | grep -c 'O Pilot abre a sessão')" = 1 ] && ok "ociosa: a parte fixa do comentário não muda" || bad "ociosa: parte fixa mudou"
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: -2 e -3 ociosas -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && ok "ociosa: com duas ociosas, a 1ª na ordem dos aliases (-2)" || bad "ociosa: foi para $(who)"
fresh; sessions "[$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: só o -3 vivo e ocioso (-1 e -2 sem sessão) -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "ociosa: prefere reaproveitar a sessão ociosa a abrir alias novo (nó não ganha uma tmux a mais)" || bad "ociosa: foi para $(who)"
fresh; sessions "[$(quiet 1)]"; SL=1 pm apply wa-t1; expect_rc "ociosa: 1 slot, a sessão do -1 ociosa -> 0 (antes: 12)" 0
[ "$(who)" = wa-worker-remote-1 ] && ok "ociosa: 1 slot reaproveita o -1" || bad "ociosa: foi para $(who)"
# quieta há pouco ou sem prova de quietude = ocupada (pode estar trabalhando sem bead: o autor esperando o gate, uma ferramenta longa)
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; pm apply wa-t1; expect_rc "ociosa: quietas há só 60 s (< 300 s) -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 240),$(quiet 3 240)]"; pm apply wa-t1; expect_rc "ociosa: quietas há 240 s (< 300 s, com folga: o relógio anda durante o teste) -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 300),$(quiet 3 300)]"; pm apply wa-t1; expect_rc "ociosa: quietas há 300 s (no corte; o teste só envelhece a sessão) -> 0" 0
fresh; busyat 1; sessions "[$(live 1),$(live 2),$(live 3)]"; pm apply wa-t1; expect_rc "ociosa: sessões sem last_active -> ocupadas -> 12 sem escrita" 12 w0
for la in '"ontem"' 'null' '""' '1792760000' '"2026-10-23T12:59:50-03:00"' '"2026-13-45T99:99:99Z"'; do
  fresh; busyat 1; sessions "[$(live 1),{\"template\":\"wa-worker-remote\",\"state\":\"active\",\"closed\":false,\"alias\":\"wa-worker-remote-2\",\"last_active\":$la},{\"template\":\"wa-worker-remote\",\"state\":\"active\",\"closed\":false,\"alias\":\"wa-worker-remote-3\",\"last_active\":$la}]"
  pm apply wa-t1; expect_rc "ociosa: last_active=$la (não dá para saber) -> ocupadas -> 12 sem escrita" 12 w0
done
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 -3600),$(quiet 3 -3600)]"; pm apply wa-t1; expect_rc "ociosa: last_active uma hora NO FUTURO (relógio) -> ocupadas -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 600 | sed 's/Z"/.123456Z"/'),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: last_active com fração de segundo é lido -> 0" 0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 | sed 's/"active"/"start-pending"/'),$(quiet 3 | sed 's/"active"/"start-pending"/')]"; pm apply wa-t1; expect_rc "ociosa: estado start-pending (subindo) nunca é ociosa -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 | sed 's/"active"/"suspended"/'),$(quiet 3 | sed 's/"active"/"suspended"/')]"; pm apply wa-t1; expect_rc "ociosa: estado que não conheço (suspended) nunca é ociosa -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 | sed 's/"wa-worker-remote"/"wa-worker"/'),$(quiet 3 | sed 's/"wa-worker-remote"/"wa-worker"/')]"; pm apply wa-t1; expect_rc "ociosa: sessão de OUTRO template com o alias do nó nunca é ociosa -> 12 sem escrita" 12 w0
# o alias tem bead em andamento: quieta ou não, NÃO é vaga (a bead é o sinal de trabalho)
fresh; busyat 1; busyat 2; busyat 3; sessions "[$(quiet 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: 3 quietas MAS com bead em andamento -> 12 sem escrita" 12 w0
fresh; busyat 1; busyat 2; sessions "[$(live 1),$(quiet 2),$(live 3)]"; pm apply wa-t1; expect_rc "ociosa: a única quieta tem bead; a outra sessão viva é ativa -> 12 sem escrita" 12 w0
fresh; busyat 1; busyat 2; sessions "[$(quiet 1),$(quiet 2),$(live 3)]"; pm apply wa-t1; expect_rc "ociosa: -1 e -2 quietas MAS com bead (o -3 livre, mas ativo) -> 12 sem escrita: bead no alias nunca é vaga" 12 w0
# duas sessões vivas com o MESMO alias: não há uma só sessão para reaproveitar
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 2),$(quiet 3)]"; pm apply wa-t1
expect_rc "ociosa: 4 vivas (o -2 duplicado) em 3 slots -> 12 sem escrita (a duplicata não vira vaga)" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 2),$(quiet 3)]"; SL=4 pm apply wa-t1
expect_rc "ociosa: 4 slots, o -2 duplicado e o -3 ocioso -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "ociosa: alias repetido não é reaproveitado (vai para o -3)" || bad "ociosa: foi para $(who)"
# modo pool não muda: o alias da sessão do pool não é nomeável, a sessão viva segue segurando o slot
fresh; sessions "[$(quiet 1)]"; d apply wa-t1; expect_rc "ociosa: modo POOL com sessão ociosa -> 12 (o pool não muda)" 12 w0
# o limiar
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; WA_NODE_IDLE_SECS=30 pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS=30 e quietas há 60 s -> 0" 0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 0),$(quiet 3 0)]"; WA_NODE_IDLE_SECS=0 pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS=0 vale (qualquer sessão sem bead) -> 0" 0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 400),$(quiet 3 400)]"; WA_NODE_IDLE_SECS=900 pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS=900 e quietas há 400 s -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 400),$(quiet 3 400)]"; WA_NODE_IDLE_SECS=0300 pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS=0300 (zero à esquerda) lê 300 e 400 s passa -> 0" 0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 250),$(quiet 3 250)]"; WA_NODE_IDLE_SECS=0300 pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS=0300 é decimal 300, não octal 192: 250 s não passa -> 12 sem escrita" 12 w0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; WA_NODE_IDLE_SECS=09 pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS=09 é decimal 9 (octal quebraria o script) -> 0" 0
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 -3600),$(quiet 3 -3600)]"; WA_NODE_IDLE_SECS=0 pm apply wa-t1; expect_rc "ociosa: corte 0 e last_active NO FUTURO -> 12 sem escrita (idade negativa nunca vale)" 12 w0
for iv in abc -5 3.5 '3 0' '' 99999999999999999999; do
  fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; WA_NODE_IDLE_SECS="$iv" pm apply wa-t1; expect_rc "ociosa: WA_NODE_IDLE_SECS='$iv' (ilegível/vazio) volta a 300 s: quietas há 60 s -> 12 sem escrita" 12 w0
done
# o oráculo continua mandando: reaproveitar a sessão não o dispensa
fresh; busyat 1; cap "$CAP_LOCAL" 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: oráculo diz local -> 12 sem escrita (reaproveitar não dispensa o oráculo)" 12 w0
fresh; busyat 1; cap '{"verdict":"unknown","reason":"stale"}' 2; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: oráculo não sabe -> 11 sem escrita" 11 w0
fresh; busyat 1; cap '{"verdict":"node","free":1}' 0; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: oráculo com 1 vaga e nenhuma bead à espera de sessão -> 0" 0
fresh; busyat 1; busyat 2; cap '{"verdict":"node","free":1}' 0; sessions "[$(live 1),$(quiet 3)]"; pm apply wa-t1; expect_rc "ociosa: o -2 tem bead e a sessão não subiu (desconta 1 vaga do oráculo) -> 12 sem escrita" 12 w0
# a leitura de sessões que falha segue 11 (não vira "ociosa por falta de leitura")
fresh; busyat 1; export STUB_FAIL_GC=1; pm apply wa-t1; expect_rc "ociosa: lista de sessões falha -> 11 sem escrita" 11 w0
# o jq que avalia a ociosidade falha (rc ≠ 0): NÃO sei avaliar -> 11 sem escrita, nunca "ociosa" nem "ocupada por padrão". Injeção: um jq na frente do PATH que só falha na consulta de ociosidade (a que lê last_active).
mkdir -p "$T/failjq"; REAL_JQ=$(command -v jq)
printf '#!/bin/sh\ncase "$*" in *fromdateiso8601*) exit 5 ;; esac\nexec "%s" "$@"\n' "$REAL_JQ" > "$T/failjq/jq"; chmod +x "$T/failjq/jq"
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; PATH="$T/failjq:$PATH" pm apply wa-t1; expect_rc "ociosa: o jq da ociosidade falha (rc 5) -> 11 sem escrita" 11 w0
grep -q 'ociosidade-ilegivel' "$CITY/.gc/wa-node-route.jsonl" && ok "ociosa: o log diz ociosidade-ilegivel" || bad "ociosa: log: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# -- pular alias (ga-2hd02v.3.26). O gancho do Pilot achou a sessão do alias que o apply escolheu viva e ocupada (31/10 09:47:57Z: o apply reaproveitou o -1 «ociosa», 19 s depois a lista do gancho a viu busy) e repete o apply SEM ele.
#    vazio/ausente = o de sempre; o alias pulado nunca é PICK nem sessão ociosa reaproveitada, mas SEGUE na conta de slots e de sessões vivas; token ilegível é ignorado (nunca vira «pular todos»).
fresh; pm apply wa-t1; expect_rc "pulo: sem WA_NODE_SKIP_ALIASES o 1º alias livre (-1), como sempre -> 0" 0
[ "$(who)" = wa-worker-remote-1 ] && ok "pulo: sem o pulo vai para o -1" || bad "pulo: foi para $(who)"
fresh; WA_NODE_SKIP_ALIASES=wa-worker-remote-1 pm apply wa-t1; expect_rc "pulo: -1 pulado, nenhuma outra sessão -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && [ "$(mark)" = wa-worker-remote-2 ] && ok "pulo: vai para o -2 (dono e marca do alias novo)" || bad "pulo: foi para $(who) marca=$(mark)"
fresh; WA_NODE_SKIP_ALIASES="wa-worker-remote-1,wa-worker-remote-2" pm apply wa-t1; expect_rc "pulo: -1 e -2 pulados (vírgula) -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "pulo: lista com vírgula vai para o -3" || bad "pulo: vírgula foi para $(who)"
fresh; WA_NODE_SKIP_ALIASES="wa-worker-remote-1 wa-worker-remote-2" pm apply wa-t1; expect_rc "pulo: -1 e -2 pulados (espaço) -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "pulo: lista com espaço vai para o -3" || bad "pulo: espaço foi para $(who)"
fresh; WA_NODE_SKIP_ALIASES="wa-worker-remote-1 wa-worker-remote-2 wa-worker-remote-3" pm apply wa-t1; expect_rc "pulo: todos pulados -> 12 sem escrita" 12 w0
grep -q 'slot-sem-alias-livre' "$CITY/.gc/wa-node-route.jsonl" && ok "pulo: o log diz slot-sem-alias-livre (o token de sempre)" || bad "pulo: log: $(cat "$CITY/.gc/wa-node-route.jsonl")"
printf '%s' "$OUT" | grep -q 'foi pulado (' && ok "pulo: a mensagem diz que houve pulo" || bad "pulo: mensagem: $OUT"
fresh; WA_NODE_SKIP_ALIASES="wa-worker-remote-1 wa-worker-remote-2 wa-worker-remote-3 ;rm * \$(x)" pm apply wa-t1; expect_rc "pulo: todos pulados + lixo -> 12 sem escrita" 12 w0
case "$OUT" in *';rm'*|*'$(x)'*) bad "pulo: o token ilegível apareceu na mensagem: $OUT" ;; *) ok "pulo: token ilegível não entra na mensagem" ;; esac
# lixo sozinho NUNCA pula nada (nenhum alias real tem esse nome)
for junk in '*' ';' '$(touch x)' "'" '"wa-worker-remote-1"' '..' ' ' ',,' 'wa-worker-remote-1;'; do
  fresh; WA_NODE_SKIP_ALIASES="$junk" pm apply wa-t1; [ "$RC" = 0 ] && [ "$(who)" = wa-worker-remote-1 ] && ok "pulo: valor ilegível '$junk' não pula nada -> -1" || bad "pulo: '$junk' rc=$RC foi para $(who)"
done
fresh; WA_NODE_SKIP_ALIASES="" pm apply wa-t1; [ "$RC" = 0 ] && [ "$(who)" = wa-worker-remote-1 ] && ok "pulo: valor vazio = o de sempre" || bad "pulo: vazio rc=$RC foi para $(who)"
# o pulado SEGUE contando: uma bead em andamento no alias pulado continua ocupando o slot (e uma sessão viva continua contando)
fresh; busyat 1; busyat 2; WA_NODE_SKIP_ALIASES=wa-worker-remote-3 pm apply wa-t1; expect_rc "pulo: -1 e -2 com bead e o -3 pulado -> 12 sem escrita (pular não inventa vaga)" 12 w0
fresh; sessions "[$(live 1),$(live 2),$(live 3)]"; WA_NODE_SKIP_ALIASES=wa-worker-remote-3 pm apply wa-t1; expect_rc "pulo: 3 sessões vivas em 3 slots, o -3 pulado -> 12 sem escrita (a sessão do pulado segue contando)" 12 w0
grep -q 'sessao-viva n=3' "$CITY/.gc/wa-node-route.jsonl" && ok "pulo: o log segue com sessao-viva n=3 (o pulado não sai da conta)" || bad "pulo: log: $(cat "$CITY/.gc/wa-node-route.jsonl")"
# a sessão ociosa do alias pulado NÃO é reaproveitada: o apply refeito pega outra
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; WA_NODE_SKIP_ALIASES=wa-worker-remote-2 pm apply wa-t1; expect_rc "pulo: -2 e -3 ociosas, o -2 pulado -> 0" 0
[ "$(who)" = wa-worker-remote-3 ] && ok "pulo: reaproveita a ociosa do -3, não a do -2 pulado" || bad "pulo: foi para $(who)"
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; WA_NODE_SKIP_ALIASES="wa-worker-remote-2 wa-worker-remote-3" pm apply wa-t1; expect_rc "pulo: as duas ociosas puladas -> 12 sem escrita (o -1 tem bead; sessão viva segue contando)" 12 w0
fresh; sessions "[$(quiet 3)]"; WA_NODE_SKIP_ALIASES=wa-worker-remote-3 pm apply wa-t1; expect_rc "pulo: só a ociosa do -3 e ela pulada -> 0 em alias novo" 0
[ "$(who)" = wa-worker-remote-1 ] && ok "pulo: sem a ociosa do -3, abre o alias livre (-1)" || bad "pulo: foi para $(who)"
# o pulo não dispensa o resto: oráculo local ainda manda
fresh; cap "$CAP_LOCAL" 1; WA_NODE_SKIP_ALIASES=wa-worker-remote-1 pm apply wa-t1; expect_rc "pulo: oráculo diz local -> 12 sem escrita (pular não dispensa o oráculo)" 12 w0
# -- leituras ilegíveis: qualquer uma = 11, nunca livre
fresh; STUB_FAIL_LIST_ALIAS=wa-worker-remote-2 pm apply wa-t1; expect_rc "slots: a leitura do -2 falha (o -1 estava livre) -> 11 sem escrita" 11 w0
fresh; STUB_FAIL_LIST_ALIAS=wa-worker-remote-3 pm apply wa-t1; expect_rc "slots: a leitura do -3 falha -> 11 sem escrita" 11 w0
fresh; export STUB_FAIL_LIST=1; pm apply wa-t1; expect_rc "slots: toda leitura de bead falha -> 11 sem escrita" 11 w0
fresh; export STUB_FAIL_GC=1; pm apply wa-t1; expect_rc "slots: lista de sessões falha -> 11 sem escrita" 11 w0
fresh; echo '{"a":1}' > "$SESS"; pm apply wa-t1; expect_rc "slots: lista de sessões sem o campo sessions -> 11 sem escrita" 11 w0
# -- o oráculo de capacidade (só em modo pilot)
fresh; cap "$CAP_LOCAL" 1; pm apply wa-t1; expect_rc "oráculo: local (rc 1) -> 12 sem escrita" 12 w0
printf '%s' "$OUT" | grep -q 'node_full' && ok "oráculo: a mensagem leva o motivo do oráculo" || bad "oráculo: mensagem: $OUT"
fresh; cap '{"verdict":"unknown","reason":"stale"}' 2; pm apply wa-t1; expect_rc "oráculo: não sei (rc 2) -> 11 sem escrita" 11 w0
fresh; cap "$CAP_OK" 1; pm apply wa-t1; expect_rc "oráculo: JSON node mas rc 1 (incoerente) -> 11 sem escrita" 11 w0
fresh; cap "$CAP_LOCAL" 0; pm apply wa-t1; expect_rc "oráculo: JSON local mas rc 0 (incoerente) -> 11 sem escrita" 11 w0
fresh; cap "$CAP_OK" 3; pm apply wa-t1; expect_rc "oráculo: rc 3 (erro do oráculo) -> 11 sem escrita" 11 w0
fresh; cap 'not json' 0; pm apply wa-t1; expect_rc "oráculo: saída que não é JSON -> 11 sem escrita" 11 w0
fresh; cap '' 0; pm apply wa-t1; expect_rc "oráculo: sem saída -> 11 sem escrita" 11 w0
fresh; cap '{"reason":"x"}' 0; pm apply wa-t1; expect_rc "oráculo: JSON sem veredito -> 11 sem escrita" 11 w0
fresh; cap '{"verdict":"node","reason":"free_slot"}' 0; pm apply wa-t1; expect_rc "oráculo: node sem o campo free -> 11 sem escrita" 11 w0
fresh; cap '{"verdict":"node","free":0}' 0; pm apply wa-t1; expect_rc "oráculo: node com free 0 (contradição) -> 11 sem escrita" 11 w0
fresh; cap '{"verdict":"node","free":"2"}' 0; pm apply wa-t1; expect_rc "oráculo: free como texto -> 11 sem escrita" 11 w0
fresh; cap '{"verdict":"node","free":1.5}' 0; pm apply wa-t1; expect_rc "oráculo: free fracionário -> 11 sem escrita" 11 w0
fresh; cap '{"verdict":"node","free":-1}' 0; pm apply wa-t1; expect_rc "oráculo: free negativo -> 11 sem escrita" 11 w0
fresh; WA_NODE_CAPACITY="$T/nao-existe.py" pm apply wa-t1; expect_rc "oráculo: arquivo ausente -> 11 sem escrita" 11 w0
fresh; export STUB_CAP_SLEEP=3; WA_NODE_CAPACITY_TIMEOUT=1 pm apply wa-t1; expect_rc "oráculo: mais lento que o prazo -> 11 sem escrita" 11 w0
fresh; export STUB_CAP_SLEEP=2; WA_NODE_CAPACITY_TIMEOUT=abc pm apply wa-t1; expect_rc "oráculo: prazo ilegível volta ao padrão (45 s) -> 0" 0
# vagas: o oráculo só vê sessões vivas; a bead atribuída cuja sessão ainda não subiu desconta
fresh; cap '{"verdict":"node","free":1}' 0; busyat 1; pm apply wa-t1; expect_rc "oráculo: 1 vaga, mas o -1 já foi atribuído e a sessão não subiu -> 12 sem escrita" 12 w0
printf '%s' "$OUT" | grep -q 'esperam a sessão subir' && ok "oráculo: a mensagem explica o desconto" || bad "oráculo: mensagem: $OUT"
fresh; cap '{"verdict":"node","free":1}' 0; busyat 1; sessions "[$(live 1)]"; pm apply wa-t1; expect_rc "oráculo: 1 vaga, o -1 já tem sessão viva (o oráculo a viu) -> 0" 0
[ "$(who)" = wa-worker-remote-2 ] && ok "oráculo: sessão viva já contada pelo oráculo não desconta de novo" || bad "oráculo: foi para $(who)"
fresh; cap '{"verdict":"node","free":2}' 0; busyat 1; pm apply wa-t1; expect_rc "oráculo: 2 vagas e 1 pendente -> 0" 0
fresh; cap '{"verdict":"node","free":2}' 0; busyat 1; busyat 2; pm apply wa-t1; expect_rc "oráculo: 2 vagas e 2 pendentes -> 12 sem escrita" 12 w0
# dry-run em modo pilot: mede, escolhe, não escreve
fresh; pm apply wa-t1 --dry-run; expect_rc "slots: --dry-run -> 0 sem escrita" 0 w0
printf '%s' "$OUT" | grep -q 'iria para wa-worker-remote-1' && ok "slots: o dry-run diz para qual alias iria" || bad "slots: dry-run: $OUT"
fresh; cap "$CAP_LOCAL" 1; pm apply wa-t1 --dry-run; expect_rc "slots: --dry-run com o oráculo dizendo local -> 12" 12 w0
# -- modo pool (padrão) não muda: 1 slot, rota, sem oráculo
fresh; WA_NODE_SLOTS=3 d apply wa-t1; expect_rc "pool com WA_NODE_SLOTS=3 -> 0" 0
[ "$(who)" = wa-worker-remote-1 ] && [ "$(rota)" = wa-worker-remote ] && [ "$(mark)" = vazio ] && ok "pool: continua alias -1 com a rota e SEM a marca do Pilot" || bad "pool: estado: $(jq -c '."wa-t1"' "$STATE")"
fresh; busyat 1; WA_NODE_SLOTS=3 d apply wa-t1; expect_rc "pool com 3 slots pedidos e o -1 ocupado -> 12 (em pool o N vale 1)" 12 w0
fresh; sessions "[$(live 1)]"; WA_NODE_SLOTS=3 d apply wa-t1; expect_rc "pool com 3 slots pedidos e sessão viva -> 12" 12 w0
fresh; cap "$CAP_LOCAL" 1; d apply wa-t1; expect_rc "pool não consulta o oráculo (ele diria local) -> 0" 0
[ "$(ncap)" = 0 ] && ok "pool: nenhuma chamada ao oráculo" || bad "pool: chamou o oráculo $(ncap) vez(es)"
fresh; busyat 1; WA_NODE_SPAWN=xx WA_NODE_SLOTS=3 d apply wa-t1; expect_rc "modo desconhecido (xx) = pool, 1 slot -> 12" 12 w0
fresh; busyat 1; WA_NODE_SPAWN= WA_NODE_SLOTS=3 d apply wa-t1; expect_rc "modo vazio = pool, 1 slot -> 12" 12 w0
# -- N inválido volta a 1 (nunca mais slots por engano)
for sl in 0 abc 10 99 -1 '' 1.5 ' 2'; do
  fresh; busyat 1; WA_NODE_SPAWN=pilot WA_NODE_SLOTS="$sl" d apply wa-t1; expect_rc "slots: WA_NODE_SLOTS='$sl' vale 1 -> com o -1 ocupado, 12 sem escrita" 12 w0
done
fresh; WA_NODE_SPAWN=pilot WA_NODE_SLOTS=9 d apply wa-t1; expect_rc "slots: 9 é o teto permitido -> 0" 0
fresh; cap '{"verdict":"node","free":9}' 0; for i in 1 2 3 4 5 6 7 8; do busyat "$i"; done; WA_NODE_SPAWN=pilot WA_NODE_SLOTS=9 d apply wa-t1; expect_rc "slots: 8 ocupados de 9 -> 0" 0
[ "$(who)" = wa-worker-remote-9 ] && ok "slots: o 9º alias é o -9" || bad "slots: foi para $(who)"
# -- alias único de teste e prefixo
fresh; WA_NODE_SPAWN=pilot WA_NODE_SLOTS=3 WA_NODE_ALIAS=zz-1 d apply wa-t1; expect_rc "WA_NODE_ALIAS único ganha de SLOTS -> 0" 0
[ "$(who)" = zz-1 ] && ok "WA_NODE_ALIAS único: a bead vai para ele" || bad "WA_NODE_ALIAS: foi para $(who)"
fresh; WA_NODE_SPAWN=pilot WA_NODE_ALIAS_PREFIX=zz- d apply wa-t1; expect_rc "WA_NODE_ALIAS_PREFIX troca o prefixo -> 0" 0
[ "$(who)" = zz-1 ] && ok "prefixo trocado: o alias é zz-1" || bad "prefixo: foi para $(who)"
# -- a conferência e o desfazer em modo pilot usam a MARCA (não a rota)
fresh; export STUB_NOOP_UPDATE=1; pm apply wa-t1; expect_rc "pilot: escrita que não pegou -> 13" 13
fresh; export STUB_PARTIAL_UPDATE=1; pm apply wa-t1; expect_rc "pilot: escrita que pegou só o dono (e a marca), conferência falha, desfazer pega -> 13" 13
grep '|update|' "$CALLS" | tail -n 1 | grep -q -- '--if-assignee|wa-worker-remote-1|--assignee||--status|open|--unset-metadata|pilot.wa_node_alias|' && ok "pilot: o desfazer é guardado pelo alias e tira a MARCA" || bad "pilot: desfazer: $(grep '|update|' "$CALLS" | tail -n 1)"
[ -z "$(who)" ] && [ "$(mark)" = vazio ] && printf '%s' "$OUT" | grep -q 'desfeita' && ! printf '%s' "$OUT" | grep -q 'NÃO desfeita' && ok "pilot: desfazer que pegou -> bead sem dono e sem marca, a mensagem diz 'desfeita'" || bad "pilot: estado/mensagem: $(jq -c '."wa-t1"' "$STATE") $OUT"
fresh; export STUB_PARTIAL_UPDATE=1 STUB_UNDO_RC=1; pm apply wa-t1; expect_rc "pilot: o desfazer também falha -> 13" 13
printf '%s' "$OUT" | grep -q 'NÃO desfeita' && [ "$(who)" = wa-worker-remote-1 ] && ok "pilot: desfazer que falhou NÃO é anunciado como desfeito (a bead ficou do nó)" || bad "pilot: $OUT / $(jq -c '."wa-t1"' "$STATE")"
fresh; export STUB_LAND_RC=124; pm apply wa-t1; expect_rc "pilot: escrita gravou e o bd saiu 124 (resposta perdida) -> 0 (a releitura confere)" 0
fresh; export STUB_UPDATE_RC=13; pm apply wa-t1; expect_rc "pilot: corrida perdida (bd rc 13) -> 12" 12
# -- release: as duas formas, de qualquer alias do nó
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-2"}}'
d release wa-t1; expect_rc "release: forma pilot (dono -2 + marca do -2, sem rota) -> 0" 0
[ -z "$(who)" ] && [ "$(mark)" = vazio ] && [ "$(rota)" = vazio ] && ok "release: forma pilot: dono e marca soltos" || bad "release: estado: $(jq -c '."wa-t1"' "$STATE")"
grep '|update|' "$CALLS" | head -n 1 | grep -q -- '--if-assignee|wa-worker-remote-2|' && ok "release: forma pilot: a soltura é guardada pelo dono real (-2)" || bad "release: escrita: $(grep '|update|' "$CALLS" | head -n 1)"
fresh '{"status":"in_progress","assignee":"wa-worker-remote-3","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release wa-t1; expect_rc "release: forma pool de um alias -3 -> 0" 0
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-3"}}'; d release wa-t1; expect_rc "release: marca de OUTRO alias -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{}}'; d release wa-t1; expect_rc "release: alias do nó mas sem marca nem rota (atribuída à mão) -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"mila-wa","metadata":{"pilot.wa_node_alias":"mila-wa"}}'; d release wa-t1; expect_rc "release: marca igual ao dono mas o dono não é do nó -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-2","gc.routed_to":"wa-worker-remote"}}'; d release wa-t1; expect_rc "release: marca E rota juntas (estado estranho) -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"other-3","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release wa-t1; expect_rc "release: dono que não é alias do nó, com a rota do nó -> 12 sem escrita" 12 w0
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-2"}}'; export STUB_NOOP_UPDATE=1; d release wa-t1; expect_rc "release: forma pilot, escrita que não pegou -> 13" 13

# -- a escrita que pegou o dono e o status mas PERDEU a marca (pilot) ou a rota (pool) não é sucesso: a conferência reprova e o desfazer limpa tudo
fresh; export STUB_DROP_META=1; pm apply wa-t1; expect_rc "pilot: escrita que pegou o dono mas perdeu a marca -> 13" 13
[ -z "$(who)" ] && [ "$(bead '."wa-t1".status')" = open ] && printf '%s' "$OUT" | grep -q 'desfeita' && ok "pilot: ...o desfazer solta a bead (sem dono, aberta) e a mensagem diz 'desfeita'" || bad "pilot: depois da marca perdida: $(jq -c '."wa-t1"' "$STATE") / $OUT"
fresh; export STUB_DROP_META=1; d apply wa-t1; expect_rc "pool: escrita que pegou o dono mas perdeu a rota -> 13" 13
# -- release que deixa a marca (ou a rota) para trás não é "solta"
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-2"}}'; export STUB_KEEP_META=1; d release wa-t1; expect_rc "release: forma pilot, o dono saiu mas a marca ficou -> 13" 13
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; export STUB_KEEP_META=1; d release wa-t1; expect_rc "release: forma pool, o dono saiu mas a rota ficou -> 13" 13

# ---- identidade: WA_NODE_SELF / WA_NODE_STORY (ga-2hd02v.3) — o wrapper da bead de PS troca o nome e a bead citada sem copiar o script
cmt() { bead '."wa-t1".comments[0]'; }
cmt_ok() { # cmt_ok <rótulo> <bead que o comentário cita> <nome do script no comentário> — o comentário começa por "nó (<bead>): " e acaba por " Ao fim da entrega: <nome> release wa-t1."
  local c; c=$(cmt)
  case "$c" in "nó ($2): "*" Ao fim da entrega: $3 release wa-t1.") ok "$1" ;; *) bad "$1 (comentário: $c)" ;; esac
}
say_ok() { # say_ok <rótulo> <nome sem .sh> — a mensagem de sucesso do apply começa pelo nome
  printf '%s' "$OUT" | grep -q "^$2: wa-t1 → " && ok "$1" || bad "$1 (saída: $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-160))"
}
L64=$(printf '%064d' 0 | tr 0 a); L65=$(printf '%065d' 0 | tr 0 a)
fresh; d apply wa-t1
expect_rc "identidade padrão: apply -> 0" 0
cmt_ok "identidade padrão: o comentário do apply é o da 1.10 (ga-2hd02v.1.10, wa-node-dispatch.sh)" ga-2hd02v.1.10 wa-node-dispatch.sh
say_ok "identidade padrão: a mensagem começa por wa-node-dispatch:" wa-node-dispatch
fresh; d
expect_rc "identidade padrão: sem argumentos -> 2" 2
printf '%s' "$OUT" | grep -q '^wa-node-dispatch: uso: wa-node-dispatch.sh check|apply|release <bead>' && ok "identidade padrão: o uso diz wa-node-dispatch.sh" || bad "identidade padrão: uso: $OUT"
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release wa-t1
expect_rc "identidade padrão: release -> 0" 0
case "$(cmt)" in "nó (ga-2hd02v.1.10): dono wa-worker-remote-1 e rota wa-worker-remote soltos após a entrega"*) ok "identidade padrão: o comentário do release é o da 1.10" ;; *) bad "identidade padrão: comentário do release: $(cmt)" ;; esac

fresh; WA_NODE_SELF=ps-node-dispatch.sh WA_NODE_STORY=ga-2hd02v.4 d apply wa-t1
expect_rc "identidade trocada: apply -> 0" 0
cmt_ok "identidade trocada: o comentário cita ga-2hd02v.4 e ps-node-dispatch.sh" ga-2hd02v.4 ps-node-dispatch.sh
say_ok "identidade trocada: a mensagem começa por ps-node-dispatch:" ps-node-dispatch
printf '%s' "$OUT" | grep -q 'wa-node-dispatch' && bad "identidade trocada: sobrou wa-node-dispatch na saída: $OUT" || ok "identidade trocada: nenhum wa-node-dispatch na saída"
case "$(cmt)" in *wa-node-dispatch*|*ga-2hd02v.1.10*) bad "identidade trocada: sobrou o nome/a bead antigos no comentário: $(cmt)" ;; *) ok "identidade trocada: nenhum nome/bead antigos no comentário" ;; esac
fresh; WA_NODE_SELF=ps-node-dispatch.sh d
expect_rc "identidade trocada: sem argumentos -> 2" 2
printf '%s' "$OUT" | grep -q '^ps-node-dispatch: uso: ps-node-dispatch.sh check|apply|release <bead>' && ok "identidade trocada: o uso diz ps-node-dispatch.sh" || bad "identidade trocada: uso: $OUT"
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; WA_NODE_STORY=ga-2hd02v.4 d release wa-t1
expect_rc "identidade trocada: release -> 0" 0
case "$(cmt)" in "nó (ga-2hd02v.4): dono wa-worker-remote-1 e rota wa-worker-remote soltos após a entrega"*) ok "identidade trocada: o comentário do release cita ga-2hd02v.4" ;; *) bad "identidade trocada: comentário do release: $(cmt)" ;; esac

# vazio → o padrão
fresh; WA_NODE_SELF= WA_NODE_STORY= d apply wa-t1
expect_rc "identidade vazia: apply -> 0" 0
cmt_ok "identidade vazia: volta ao padrão" ga-2hd02v.1.10 wa-node-dispatch.sh
# ilegível → o padrão (o valor vai para um comentário da bead)
for v in 'ps node.sh' 'a;b' 'a$b' 'a`b' "a'b" 'a"b' 'a/b' 'a(b)' $'a\nb' "$L65"; do
  fresh; WA_NODE_SELF="$v" d apply wa-t1
  [ "$RC" = 0 ] && { cmt_ok "WA_NODE_SELF ilegível ($(printf '%s' "$v" | tr '\n' '~' | cut -c1-12)…) volta ao padrão" ga-2hd02v.1.10 wa-node-dispatch.sh; } || bad "WA_NODE_SELF ilegível: apply rc=$RC"
  fresh; WA_NODE_STORY="$v" d apply wa-t1
  [ "$RC" = 0 ] && { cmt_ok "WA_NODE_STORY ilegível ($(printf '%s' "$v" | tr '\n' '~' | cut -c1-12)…) volta ao padrão" ga-2hd02v.1.10 wa-node-dispatch.sh; } || bad "WA_NODE_STORY ilegível: apply rc=$RC"
done
# 64 caracteres passam (o teto é inclusivo)
fresh; WA_NODE_SELF="$L64" WA_NODE_STORY="$L64" d apply wa-t1
cmt_ok "identidade de 64 caracteres passa (o teto é inclusivo)" "$L64" "$L64"
fresh; WA_NODE_SELF=ps_node-dispatch.v2.sh WA_NODE_STORY=ga-2hd02v.4.1 d apply wa-t1
cmt_ok "identidade com _ - . e dígitos passa" ga-2hd02v.4.1 ps_node-dispatch.v2.sh

# ---- ga-31u0zl7: WA_NODE_ACCEPT_UNKNOWN=sem-prova — o `unknown` cujo ÚNICO motivo é a falta de prova (e cuja leitura não falhou) sai como node, base sem-prova. Três estados: promove / lê-mas-falhou (fica unknown) /
#      qualquer outro motivo (fica como veio). Sem a variável, ou com qualquer valor que não seja exatamente `sem-prova`, o de sempre (os casos «unknown -> 11» lá de cima).
UNK_INFO_OK='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["palavra-mole:banco","evidencia-de-doc:docs/x.md"]}'
UNK_READFAIL='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["caminho-derivado-ilegivel:git-log-falhou"]}'
UNK_READFAIL2='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["palavra-mole:banco","teste-derivado-ilegivel:rsync"]}'
UNK_MOLES='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste","moles:credencial"],"paths":[],"tests":[],"info":[]}'
UNK_OTHER='{"verdict":"unknown","basis":"","reasons":["json-ilegivel"],"paths":[],"tests":[],"info":[]}'
UNK_DUP='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste","sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":[]}'
UNK_NOINFO='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[]}'
UNK_INFOSTR='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":"caminho-derivado-ilegivel:x"}'
UNK_INFONULL='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":null}'
UNK_INFOOBJ='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":{}}'
UNK_NOREASON='{"verdict":"unknown","basis":"","paths":[],"tests":[],"info":[]}'
# gate-fix 1: a busca de teste por IMPORTAÇÃO do classificador deixa notas que NÃO têm `ilegiv` mas dizem «li só parte» (wa-node-classify.py, importer_tests: MAX_IMPORTER_SCAN e o candidato que não parseia)
UNK_IMP_TRUNC='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["palavra-mole:banco","teste-importador-truncado:12"]}'
UNK_IMP_PARSE='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["teste-importador-nao-parseou:2"]}'
# leitura INTEIRA que só desistiu de escolher entre muitos arquivos (sinal fraco, o worker confere), e uma nota de importador que é evidência e não leitura incompleta
UNK_DEMAIS='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["codigo-do-teste-demais:12","caminho-derivado-demais:14","caminho-derivado-ambiguo:util=5"]}'
UNK_IMP_NEAR='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["teste-importador:lib/x.py=tests/test_x.py"]}'
export WA_NODE_ACCEPT_UNKNOWN=sem-prova
fresh; cls "$UNK" 11; d check wa-t1;               expect_rc "accept-unknown: check de unknown só por falta de prova -> 0 (node)" 0 w0
printf '%s' "$OUT" | jq -e '.verdict == "node" and .basis == "sem-prova" and .promoted_from == "unknown" and .reasons == ["sem-prova-de-codigo-e-teste"]' >/dev/null 2>&1 && ok "accept-unknown: check imprime node/base sem-prova/promoted_from e CONSERVA o motivo original" || bad "accept-unknown: JSON promovido errado ($OUT)"
fresh; cls "$UNK_INFO_OK" 11; d check wa-t1;       expect_rc "accept-unknown: info com palavra-mole e evidência (nenhuma leitura falhou) ainda promove -> 0" 0 w0
fresh; cls "$MINI" 10; d check wa-t1;              expect_rc "accept-unknown: mini continua mini (10)" 10 w0
fresh; cls "$NODE_TEXT" 0; d check wa-t1;          expect_rc "accept-unknown: node de verdade continua node, base intacta (0)" 0 w0
printf '%s' "$OUT" | jq -e '.basis == "text" and (has("promoted_from") | not)' >/dev/null 2>&1 && ok "accept-unknown: o node de verdade NÃO ganha promoted_from nem muda de base" || bad "accept-unknown: node de verdade foi alterado ($OUT)"
fresh; cls "$UNK_READFAIL" 11; d check wa-t1;      expect_rc "accept-unknown: leitura que FALHOU (caminho-derivado-ilegivel) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_READFAIL2" 11; d check wa-t1;     expect_rc "accept-unknown: leitura que falhou misturada com palavra-mole NÃO promove -> 11" 11 w0
fresh; cls "$UNK_IMP_TRUNC" 11; d check wa-t1;     expect_rc "accept-unknown: busca de importador TRUNCADA (importadores além do 60º nem foram lidos) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_IMP_PARSE" 11; d check wa-t1;     expect_rc "accept-unknown: teste candidato que não parseou (leitura pela metade) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_DEMAIS" 11; d check wa-t1;        expect_rc "accept-unknown: codigo-do-teste-demais / caminho-derivado-demais|ambiguo (leitura INTEIRA, só desistiu de escolher) promove -> 0" 0 w0
fresh; cls "$UNK_IMP_NEAR" 11; d check wa-t1;      expect_rc "accept-unknown: nota teste-importador:<codigo>=<teste> (evidência) não é leitura incompleta -> 0" 0 w0
fresh; cls "$UNK_MOLES" 11; d check wa-t1;         expect_rc "accept-unknown: motivo EXTRA (moles:credencial) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_OTHER" 11; d check wa-t1;         expect_rc "accept-unknown: outro motivo de unknown (json-ilegivel) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_DUP" 11; d check wa-t1;           expect_rc "accept-unknown: motivo repetido não é «exatamente o motivo» -> 11" 11 w0
fresh; cls "$UNK_NOINFO" 11; d check wa-t1;        expect_rc "accept-unknown: info AUSENTE (não sei se leu) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_INFOSTR" 11; d check wa-t1;       expect_rc "accept-unknown: info que não é lista NÃO promove -> 11" 11 w0
fresh; cls "$UNK_INFONULL" 11; d check wa-t1;      expect_rc "accept-unknown: info null NÃO promove -> 11" 11 w0
fresh; cls "$UNK_INFOOBJ" 11; d check wa-t1;       expect_rc "accept-unknown: info que é OBJETO (o map do jq o aceitaria) NÃO promove -> 11" 11 w0
fresh; cls "$UNK_NOREASON" 11; d check wa-t1;      expect_rc "accept-unknown: unknown sem motivo NÃO promove -> 11" 11 w0
fresh; cls "$UNK" 0; d check wa-t1;                expect_rc "accept-unknown: classificador incoerente (unknown com rc 0) NÃO promove -> 11" 11 w0
fresh; cls "not json" 11; d check wa-t1;           expect_rc "accept-unknown: saída ilegível NÃO promove -> 11" 11 w0
fresh; cls "" 11; d check wa-t1;                   expect_rc "accept-unknown: saída vazia NÃO promove -> 11" 11 w0
# apply
fresh; cls "$UNK" 11; d apply wa-t1;               expect_rc "accept-unknown: apply de unknown só por falta de prova -> 0 e ESCREVE" 0
[ "$(bead '."wa-t1".assignee')" = wa-worker-remote-1 ] && [ "$(bead '."wa-t1".status')" = in_progress ] && ok "accept-unknown: apply atribuiu ao alias, em andamento" || bad "accept-unknown: apply não atribuiu"
bead '."wa-t1".comments[0]' | grep -q 'SEM PROVA' && ok "accept-unknown: o comentário da bead diz SEM PROVA e manda conferir/devolver" || bad "accept-unknown: comentário sem o aviso: $(bead '."wa-t1".comments')"
bead '."wa-t1".comments[0]' | grep -q 'base sem-prova' && ok "accept-unknown: o comentário cita a base sem-prova" || bad "accept-unknown: comentário sem a base"
jq -r 'select(.event=="apply") | .detail' "$CITY/.gc/wa-node-route.jsonl" | tail -n 1 | grep -q '(sem-prova)' && ok "accept-unknown: o log do apply guarda a base (sem-prova): é o que o relatório conta" || bad "accept-unknown: log sem a base: $(cat "$CITY/.gc/wa-node-route.jsonl")"
fresh; cls "$NODE_TEXT" 0; d apply wa-t1;          expect_rc "accept-unknown: apply de node de verdade -> 0" 0
bead '."wa-t1".comments[0]' | grep -q 'SEM PROVA' && bad "accept-unknown: node de verdade ganhou o aviso SEM PROVA" || ok "accept-unknown: node de verdade NÃO ganha o aviso SEM PROVA"
fresh; cls "$UNK" 11; d apply wa-t1 --basis label; expect_rc "accept-unknown: modo label NUNCA aceita sem-prova -> 10 sem escrita" 10 w0
fresh; cls "$UNK_READFAIL" 11; d apply wa-t1;      expect_rc "accept-unknown: apply com leitura que falhou -> 11 sem escrita" 11 w0
fresh; cls "$UNK_IMP_TRUNC" 11; d apply wa-t1;     expect_rc "accept-unknown: apply com a busca de importador truncada -> 11 sem escrita" 11 w0
fresh; cls "$UNK_MOLES" 11; d apply wa-t1;         expect_rc "accept-unknown: apply com motivo extra -> 11 sem escrita" 11 w0
fresh; cls "$MINI" 10; d apply wa-t1;              expect_rc "accept-unknown: apply de mini -> 10 sem escrita" 10 w0
fresh; cls "$UNK" 11; d apply wa-t1 --dry-run;     expect_rc "accept-unknown: apply --dry-run de unknown promovido -> 0 SEM escrita" 0 w0
fresh; jq -c '. + {"wa-busy":{"id":"wa-busy","status":"in_progress","assignee":"wa-worker-remote-1","metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; cls "$UNK" 11
d apply wa-t1; expect_rc "accept-unknown: a promoção NÃO fura o slot do nó (ocupado -> 12 sem escrita)" 12 w0
# valor ilegível = desligado, NUNCA ligado por erro de digitação
for v in semprova Sem-Prova "sem-prova " " sem-prova" 1 true on sem-prova,x ""; do
  fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN="$v" d check wa-t1; expect_rc "accept-unknown: valor '$v' = desligado -> 11 (check)" 11 w0
done
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN="sem-prova;rm" d apply wa-t1; expect_rc "accept-unknown: valor com ; = desligado -> 11 sem escrita (apply)" 11 w0
unset WA_NODE_ACCEPT_UNKNOWN
fresh; cls "$UNK" 11; d check wa-t1;               expect_rc "accept-unknown: variável AUSENTE = o de sempre -> 11 (check)" 11 w0
fresh; cls "$UNK" 11; d apply wa-t1;               expect_rc "accept-unknown: variável AUSENTE = o de sempre -> 11 sem escrita (apply)" 11 w0

# ---- 1 caso de ponta a ponta com o classificador REAL (mesma bead que o selftest dele manda ao nó)
fresh; unset WA_NODE_CLASSIFY
jq -c '."wa-t1" += {"description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em tests/test_foo_parser.py."}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "ponta a ponta com o classificador real: bead de código+teste -> 0" 0
fresh; jq -c '."wa-t1" += {"description":"lib/foo.py lê data/helper.py; tests/test_foo.py"}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "ponta a ponta com o classificador real: bead que cita código que o filtro não deixa sair -> 10 sem escrita" 10 w0
# ga-t05a1z9: banco citado como PROVA (com código e teste) já não é duro; sem código citado segue duro e a bead fica no mini sem escrita
fresh; jq -c '."wa-t1" += {"description":"lib/foo.py mede queue.db; tests/test_foo.py"}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "ponta a ponta com o classificador real: .db citado como prova + código + teste -> 0" 0
fresh; jq -c '."wa-t1" += {"description":"o teste tests/test_foo.py mede queue.db"}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "ponta a ponta com o classificador real: .db citado SEM código -> 10 sem escrita" 10 w0
export WA_NODE_CLASSIFY="$T/cls.py"

# ---- controle negativo
mutant() { # mutant <nome> <trecho original> <trecho novo> <rótulo do caso designado> <comando de preparo> -- args do script
  local name="$1" old="$2" new="$3" M="$T/mut-$1.sh"
  MUT_NAME="$name"; MUT_M="$M"; SCRIPT="$M"
  python3 -I - "$REAL" "$M" "$old" "$new" <<'EOF' || { bad "mutante $name: trecho original ausente (o script mudou? atualize o mutante)"; SCRIPT="$REAL"; return; }
import sys
src = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] not in src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
EOF
  chmod +x "$M"
}
mdone() { rm -f "${MUT_M:-}"; SCRIPT="$REAL"; }
survived() { bad "mutante $MUT_NAME SOBREVIVEU (o caso designado ainda passa)"; mdone; }
killed()   { ok "mutante $MUT_NAME morreu"; mdone; }

mutant sem-elegibilidade '[ "$st" = open ] && [ -z "$as" ] && [ -z "$rt" ] ||' 'true ||'
# o rc 12 sozinho não basta: sem a elegibilidade a comparação atômica ainda devolve 12 (defesa em profundidade) — o que prova a elegibilidade é NÃO ter tentado escrever
fresh '{"assignee":"mila-wa"}'; d apply wa-t1; if [ "$RC" = 12 ] && ! wrote; then survived; else killed; fi
mutant sem-comparacao '--if-assignee "" --if-status open ' ''
fresh; d apply wa-t1; if grep '|update|' "$CALLS" | head -n 1 | grep -q -- '--if-assignee||--if-status|open|'; then survived; else killed; fi
mutant slot-ignorado '*) busy_a="$busy_a $A"; busy_n=$((busy_n+n)) ;; esac' '*) free_a="$free_a $A" ;; esac'
fresh; jq -c '. + {"wa-busy":{"id":"wa-busy","status":"in_progress","assignee":"wa-worker-remote-1","metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant sessao-ignorada 'if [ $((live - n_reuse)) -ge "$SLOTS" ]; then jlog apply' 'if false; then jlog apply'
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active"}]}' > "$SESS"; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant veredito-ignorado 'if [ "$rc" != 0 ]; then jlog apply' 'if false; then jlog apply'
fresh; cls "$MINI" 10; d apply wa-t1; if [ "$RC" = 10 ] && ! wrote; then survived; else killed; fi
mutant base-ignorada 'if [ "$basis" = label ] && [ "$b" != label ]; then' 'if false; then'
fresh; cls "$NODE_TEXT" 0; d apply wa-t1 --basis label; if [ "$RC" = 10 ]; then survived; else killed; fi
mutant sem-conferencia 'jlog apply "$id" 13 "conferencia-falhou-$u"; [ "$u" = desfeito ] && die 13 "não consegui confirmar a atribuição de $id — desfeita"; die 13 "não consegui confirmar a atribuição de $id — NÃO desfeita: confira à mão"' 'jlog apply "$id" 13 "conferencia-falhou-$u"'
fresh; export STUB_NOOP_UPDATE=1; d apply wa-t1; if [ "$RC" = 13 ]; then survived; else killed; fi
mutant corrida-vira-erro 'if [ "$w" = 13 ]; then jlog apply "$id" 12 "perdeu-a-corrida"; die 12' 'if [ "$w" = 99 ]; then jlog apply "$id" 12 "perdeu-a-corrida"; die 12'
fresh; export STUB_UPDATE_RC=13; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant outro-id 'select(type=="object" and .id == $id)' 'select(type=="object")'
fresh; export STUB_SHOW_OTHER=1; d apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant release-qualquer 'case "$as" in "$ALIAS"|"$PREFIX"[1-9]) mine_alias=1 ;; *) mine_alias=0 ;; esac' 'mine_alias=1'
fresh '{"status":"in_progress","assignee":"mila-wa","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant release-sem-conferencia 'jlog release "$id" 13 "conferencia-falhou"; die 13 "não consegui confirmar que $id foi solta — confira à mão"' 'true'
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; export STUB_NOOP_UPDATE=1; d release wa-t1; if [ "$RC" = 13 ]; then survived; else killed; fi
mutant dry-run-escreve 'if [ "$dry" = 1 ]; then jlog apply' 'if [ "$dry" = 99 ]; then jlog apply'
fresh; d apply wa-t1 --dry-run; if ! wrote; then survived; else killed; fi
mutant sessao-viva-fechada 'select((.state // .State // "") | test("closed|stopped|archived|drained") | not)' 'select(true)'
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"closed","alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant sessao-closed-flag 'select(.closed != true) | ' ''
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","closed":true,"alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant sessoes-so-array 'if type=="object" and (.sessions|type)=="array" then [.sessions[] |' 'if type=="array" then [.[] |'
fresh; d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant sessao-prazo-geral 'sess=$(TS "$GC" session list' 'sess=$(T "$GC" session list'
fresh; export STUB_GC_SLEEP=3; WA_NODE_TIMEOUT=2 WA_NODE_SESSION_TIMEOUT=15 d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant prazo-proprio-ilegivel 'case "$STMO" in '"''"'|*[!0-9]*) STMO=60 ;; esac' ':'
fresh; export STUB_GC_SLEEP=3; WA_NODE_TIMEOUT=2 WA_NODE_SESSION_TIMEOUT=abc d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant coerencia-ignorada 'case "$rc:$v" in 0:node|10:mini|11:unknown) return 0 ;; esac' 'return 0'
fresh; cls "$MINI" 0; d apply wa-t1; if [ "$RC" = 11 ] && ! wrote; then survived; else killed; fi
mutant rc-cru-vaza '"info":[]}'"'"'; rc=11' '"info":[]}'"'"
fresh; cls "" 137; d apply wa-t1; if [ "$RC" = 11 ] && ! wrote; then survived; else killed; fi
mutant desfazer-mente 'u=NAO-desfeito' 'u=desfeito'
fresh; export STUB_PARTIAL_UPDATE=1 STUB_UNDO_RC=1; d apply wa-t1; if printf '%s' "$OUT" | grep -q 'NÃO desfeita'; then survived; else killed; fi

# ---- N slots (ga-2hd02v.3): mutantes. Cada um desliga UMA defesa do script e o caso designado tem de falhar.
mutant oraculo-ignorado '      0:node) ;;' '      *) ;;'
fresh; cap '{"verdict":"local","reason":"node_full","free":2}' 1; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant oraculo-incoerente '      *) jlog apply "$id" 11 "oraculo-ilegivel rc=$crc verdict=${cv:-?}"; die 11 "o oráculo de capacidade não respondeu de forma coerente (rc=$crc, veredito=${cv:-?}) — fica no mini" ;;' '      *) ;;'
fresh; cap '{"verdict":"node","free":3}' 3; pm apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant oraculo-sem-free 'case "$cfree" in '"''"'|*[!0-9]*|0) jlog apply "$id" 11 "oraculo-sem-free"' 'case "7" in '"''"'|*[!0-9]*|0) jlog apply "$id" 11 "oraculo-sem-free"'
fresh; cap '{"verdict":"node","reason":"free_slot"}' 0; pm apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant oraculo-free-texto '(.free | select(type=="number")) // empty' '.free // empty'
fresh; cap '{"verdict":"node","free":"2"}' 0; pm apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant pendentes-ignorados 'if [ $((cfree - pend)) -lt 1 ]; then' 'if [ "$cfree" -lt 1 ]; then'
fresh; cap '{"verdict":"node","free":1}' 0; busyat 1; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant pendentes-vivos-descontam $'for A in $busy_a; do printf \'%s\\n\' "$live_al" | grep -qxF -- "$A" ||' 'for A in $busy_a; do false ||'
fresh; cap '{"verdict":"node","free":1}' 0; busyat 1; sessions "[$(live 1)]"; pm apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant alias-vivo-ignorado $'for A in $free_a; do skipped "$A" && continue; printf \'%s\\n\' "$live_al" | grep -qxF -- "$A" ||' 'for A in $free_a; do skipped "$A" && continue; false ||'
fresh; sessions "[$(live 1)]"; pm apply wa-t1; if [ "$(who)" = wa-worker-remote-2 ]; then survived; else killed; fi
mutant todos-ocupados 'if [ -z "$free_a" ]; then' 'if false; then'
fresh; busyat 1; busyat 2; busyat 3; pm apply wa-t1; if [ "$RC" = 12 ] && printf '%s' "$OUT" | grep -q 'estão ocupados'; then survived; else killed; fi
mutant lista-do-slot-ilegivel 'case "$n" in 0) free_a="$free_a $A" ;; '"''"'|x|*[!0-9]*) jlog apply "$id" 11 "slot-ilegivel"; die 11 "leitura do slot do nó não é uma lista — fica no mini" ;;' 'case "$n" in 0) free_a="$free_a $A" ;; '"''"'|x|*[!0-9]*) ;;'
fresh; export STUB_LIST_GARBAGE=1; pm apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant slots-ignorados '[ "$SPAWN" = pilot ] || SLOTS=1' ':'
fresh; busyat 1; WA_NODE_SLOTS=3 d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant slot-tampa 'case "$SLOTS" in [1-9]) ;; *) SLOTS=1 ;; esac' 'case "$SLOTS" in *) ;; esac'
fresh; busyat 1; WA_NODE_SPAWN=pilot WA_NODE_SLOTS=10 d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant marca-sem-rota 'wmeta="pilot.wa_node_alias=$PICK"; umeta="pilot.wa_node_alias"' 'wmeta="gc.routed_to=$ROUTE"; umeta="gc.routed_to"'
fresh; pm apply wa-t1; if [ "$RC" = 0 ] && [ "$(rota)" = vazio ] && [ "$(mark)" = wa-worker-remote-1 ]; then survived; else killed; fi
mutant desfazer-pilot-marca 'wmeta="pilot.wa_node_alias=$PICK"; umeta="pilot.wa_node_alias"' 'wmeta="pilot.wa_node_alias=$PICK"; umeta="gc.routed_to"'
fresh; export STUB_PARTIAL_UPDATE=1; pm apply wa-t1; if [ "$(mark)" = vazio ] && ! printf '%s' "$OUT" | grep -q 'NÃO desfeita'; then survived; else killed; fi
mutant marca-nao-conferida $'if [ "$SPAWN" = pilot ]; then m=$(printf \'%s\' "$j" | jq -r \'.metadata["pilot.wa_node_alias"] // ""\' 2>/dev/null); [ "$m" = "$PICK" ]; else' 'if [ "$SPAWN" = pilot ]; then true; else'
fresh; export STUB_DROP_META=1; pm apply wa-t1; if [ "$RC" = 13 ]; then survived; else killed; fi
mutant oraculo-consultado-no-pool $'  if [ "$SPAWN" = pilot ]; then\n    # teto do nó' $'  if true; then\n    # teto do nó'
fresh; cap "$CAP_LOCAL" 1; d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant oraculo-sem-prazo 'TC() { if command -v timeout >/dev/null 2>&1; then timeout "$CTMO" "$@"; else "$@"; fi; }' 'TC() { "$@"; }'
fresh; export STUB_CAP_SLEEP=3; WA_NODE_CAPACITY_TIMEOUT=1 pm apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant prazo-oraculo-ilegivel 'case "$CTMO" in '"''"'|*[!0-9]*) CTMO=45 ;; esac' ':'
fresh; export STUB_CAP_SLEEP=2; WA_NODE_CAPACITY_TIMEOUT=abc pm apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant release-qualquer-dono 'case "$as" in "$ALIAS"|"$PREFIX"[1-9]) mine_alias=1 ;; *) mine_alias=0 ;; esac' 'mine_alias=1'
fresh '{"status":"in_progress","assignee":"other-3","metadata":{"gc.routed_to":"wa-worker-remote"}}'; d release wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant release-rota-qualquer '[ "$rt" = "$ROUTE" ] && [ -z "$mk" ]; then shape=pool' '[ -n "$rt" ] && [ -z "$mk" ]; then shape=pool'
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker"}}'; d release wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant release-pilot-sem-marca '[ -z "$rt" ] && [ "$mk" = "$as" ]; then shape=pilot' '[ -z "$rt" ]; then shape=pilot'
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-3"}}'; d release wa-t1; if [ "$RC" = 12 ] && ! wrote; then survived; else killed; fi
mutant release-marca-sobra $'&& [ -z "$(printf \'%s\' "$A" | jq -r \'.metadata["pilot.wa_node_alias"] // ""\')" ]; } ||' '; } ||'
fresh '{"status":"in_progress","assignee":"wa-worker-remote-2","metadata":{"pilot.wa_node_alias":"wa-worker-remote-2"}}'; export STUB_KEEP_META=1; d release wa-t1; if [ "$RC" = 13 ]; then survived; else killed; fi

# ---- sessão dormindo (ga-2hd02v.3)
mutant dormindo-viva 'select(($sp == "pilot" and ((.state // .State // "") == "asleep") and ((.template // .Template // "") == $t)) | not) | ' ''
fresh; sessions "[$(asleep 1)]"; SL=1 pm apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant dormindo-no-pool '($sp == "pilot" and ((.state' '(((.state'
fresh; sessions "[$(asleep 1)]"; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant dormindo-qualquer-template ' and ((.template // .Template // "") == $t)) | not)' ') | not)'
fresh; sessions '[{"template":"wa-worker","state":"asleep","closed":false,"alias":"wa-worker-remote-1"}]'; SL=1 pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant dormindo-qualquer-estado '((.state // .State // "") == "asleep") and' '((.state // .State // "") != "") and'
fresh; sessions '[{"template":"wa-worker-remote","state":"suspended","closed":false,"alias":"wa-worker-remote-1"}]'; SL=1 pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi

# ---- identidade (ga-2hd02v.3)
mutant say-fixo 'say() { echo "${SELF%.sh}: $*" >&2; }' 'say() { echo "wa-node-dispatch: $*" >&2; }'
fresh; WA_NODE_SELF=ps-node-dispatch.sh d apply wa-t1; if printf '%s' "$OUT" | grep -q '^ps-node-dispatch: wa-t1'; then survived; else killed; fi
mutant uso-fixo 'die 2 "uso: $SELF check' 'die 2 "uso: wa-node-dispatch.sh check'
fresh; WA_NODE_SELF=ps-node-dispatch.sh d; if printf '%s' "$OUT" | grep -q 'uso: ps-node-dispatch.sh check'; then survived; else killed; fi
mutant comentario-nome-fixo 'Ao fim da entrega: $SELF release $id.' 'Ao fim da entrega: wa-node-dispatch.sh release $id.'
fresh; WA_NODE_SELF=ps-node-dispatch.sh d apply wa-t1; case "$(cmt)" in *"ps-node-dispatch.sh release wa-t1."*) survived ;; *) killed ;; esac
mutant comentario-apply-bead-fixa '"nó ($STORY): $who' '"nó (ga-2hd02v.1.10): $who'
fresh; WA_NODE_STORY=ga-2hd02v.4 d apply wa-t1; case "$(cmt)" in "nó (ga-2hd02v.4): "*) survived ;; *) killed ;; esac
mutant comentario-release-bead-fixa '"nó ($STORY): dono $as e' '"nó (ga-2hd02v.1.10): dono $as e'
fresh '{"status":"in_progress","assignee":"wa-worker-remote-1","metadata":{"gc.routed_to":"wa-worker-remote"}}'; WA_NODE_STORY=ga-2hd02v.4 d release wa-t1; case "$(cmt)" in "nó (ga-2hd02v.4): dono "*) survived ;; *) killed ;; esac
mutant self-sem-filtro 'case "$SELF" in *[!A-Za-z0-9._-]*) SELF=wa-node-dispatch.sh ;; esac; ' ''
fresh; WA_NODE_SELF='ps node.sh' d apply wa-t1; case "$(cmt)" in *"ps node.sh release"*) killed ;; *) survived ;; esac
mutant story-sem-filtro 'case "$STORY" in *[!A-Za-z0-9._-]*) STORY=ga-2hd02v.1.10 ;; esac; ' ''
fresh; WA_NODE_STORY='a;b' d apply wa-t1; case "$(cmt)" in "nó (a;b): "*) killed ;; *) survived ;; esac
mutant self-sem-teto '[ "${#SELF}" -le 64 ] || SELF=wa-node-dispatch.sh' ':'
fresh; WA_NODE_SELF="$L65" d apply wa-t1; case "$(cmt)" in *"$L65 release"*) killed ;; *) survived ;; esac
mutant story-sem-teto '[ "${#STORY}" -le 64 ] || STORY=ga-2hd02v.1.10' ':'
fresh; WA_NODE_STORY="$L65" d apply wa-t1; case "$(cmt)" in "nó ($L65): "*) killed ;; *) survived ;; esac
mutant self-teto-65 '[ "${#SELF}" -le 64 ]' '[ "${#SELF}" -le 65 ]'
fresh; WA_NODE_SELF="$L65" d apply wa-t1; case "$(cmt)" in *"$L65 release"*) killed ;; *) survived ;; esac
mutant story-teto-65 '[ "${#STORY}" -le 64 ]' '[ "${#STORY}" -le 65 ]'
fresh; WA_NODE_STORY="$L65" d apply wa-t1; case "$(cmt)" in "nó ($L65): "*) killed ;; *) survived ;; esac
mutant self-teto-63 '[ "${#SELF}" -le 64 ]' '[ "${#SELF}" -lt 64 ]'
fresh; WA_NODE_SELF="$L64" d apply wa-t1; case "$(cmt)" in *"$L64 release"*) survived ;; *) killed ;; esac
mutant story-teto-63 '[ "${#STORY}" -le 64 ]' '[ "${#STORY}" -lt 64 ]'
fresh; WA_NODE_STORY="$L64" d apply wa-t1; case "$(cmt)" in "nó ($L64): "*) survived ;; *) killed ;; esac
mutant self-vazio-quebra 'SELF="${WA_NODE_SELF:-wa-node-dispatch.sh}"' 'SELF="${WA_NODE_SELF-wa-node-dispatch.sh}"'
fresh; WA_NODE_SELF= d apply wa-t1; case "$(cmt)" in *" Ao fim da entrega: wa-node-dispatch.sh release wa-t1.") survived ;; *) killed ;; esac
mutant story-vazio-quebra 'STORY="${WA_NODE_STORY:-ga-2hd02v.1.10}"' 'STORY="${WA_NODE_STORY-ga-2hd02v.1.10}"'
fresh; WA_NODE_STORY= d apply wa-t1; case "$(cmt)" in "nó (ga-2hd02v.1.10): "*) survived ;; *) killed ;; esac

# -- sessão ociosa (ga-2hd02v.3.12): cada mutante quebra UMA linha da regra e o caso designado tem de notar
mutant ociosa-nao-desconta 'if [ $((live - n_reuse)) -ge "$SLOTS" ]; then' 'if [ "$live" -ge "$SLOTS" ]; then'
fresh; busyat 1; busyat 2; closedat 3; sessions "[$(live 1),$(live 2),$(quiet 3)]"; pm apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant ociosa-sem-quietude ' and (($now - $ts) >= $idle)))' '))'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-estado-qualquer ' and ((.state // .State // "") == "active")' ''
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 | sed 's/"active"/"start-pending"/'),$(quiet 3 | sed 's/"active"/"start-pending"/')]"; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-template-qualquer 'select(((.template // .Template // "") == $t) and .closed != true and ((.state' 'select((true) and .closed != true and ((.state'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 | sed 's/"wa-worker-remote"/"wa-worker"/'),$(quiet 3 | sed 's/"wa-worker-remote"/"wa-worker"/')]"; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-tipo-last-active 'select((.last_active | type) == "string") | ' ''
fresh; busyat 1; sessions "[$(live 1),{\"template\":\"wa-worker-remote\",\"state\":\"active\",\"closed\":false,\"alias\":\"wa-worker-remote-2\",\"last_active\":1792760000},{\"template\":\"wa-worker-remote\",\"state\":\"active\",\"closed\":false,\"alias\":\"wa-worker-remote-3\",\"last_active\":1792760000}]"; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-pool-reaproveita $'  if [ "$SPAWN" = pilot ]; then\n    idle_json=' $'  if true; then\n    idle_json='
fresh; sessions "[$(quiet 1)]"; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-alias-repetido '[ "$(printf '"'"'%s\n'"'"' "$live_al" | grep -cxF -- "$A")" = 1 ] || continue' 'true'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 2),$(quiet 3)]"; SL=4 pm apply wa-t1; if [ "$RC" = 0 ] && [ "$(who)" = wa-worker-remote-3 ]; then survived; else killed; fi
mutant ociosa-ignora-bead $'    for A in $free_a; do\n      skipped "$A" && continue' $'    for A in $ALIASES; do\n      skipped "$A" && continue'
fresh; busyat 1; busyat 2; sessions "[$(quiet 1),$(quiet 2),$(live 3)]"; pm apply wa-t1; if [ "$RC" = 12 ] && ! wrote; then survived; else killed; fi
mutant ociosa-prefere-novo 'for A in $reuse_a; do PICK="$A"; REUSED=1; break; done' ':'
fresh; sessions "[$(quiet 3)]"; pm apply wa-t1; if [ "$(who)" = wa-worker-remote-3 ]; then survived; else killed; fi
mutant ociosa-idle-padrao 'IDLE="${WA_NODE_IDLE_SECS:-300}"' 'IDLE="${WA_NODE_IDLE_SECS:-0}"'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-idle-ilegivel-zero "''|*[!0-9]*) IDLE=300 ;; *) if" "''|*[!0-9]*) IDLE=0 ;; *) if"
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; WA_NODE_IDLE_SECS=abc pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-idle-octal 'IDLE=$((10#$IDLE))' 'IDLE=$((IDLE))'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 250),$(quiet 3 250)]"; WA_NODE_IDLE_SECS=0300 pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-idle-longo 'else IDLE=300; fi' 'else IDLE=0; fi'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2 60),$(quiet 3 60)]"; WA_NODE_IDLE_SECS=99999999999999999999 pm apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant ociosa-comentario '[ "$REUSED" = 1 ] && who="$who A sessão do alias já está viva e ociosa (reaproveitada): o Pilot só a avisa."' ':'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; if bead '."wa-t1".comments[0]' | grep -q 'já está viva'; then survived; else killed; fi
mutant ociosa-rastro 'rn=" [sessão ociosa reaproveitada]"' 'rn=""'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; pm apply wa-t1; if grep -q 'reaproveitada' "$CITY/.gc/wa-node-route.jsonl"; then survived; else killed; fi
mutant ociosa-ilegivel-segue 'ok) ;; *) jlog apply "$id" 11 "ociosidade-ilegivel"; die 11 "não consegui avaliar quais sessões estão ociosas — fica no mini" ;; esac' 'ok) ;; *) ;; esac'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; PATH="$T/failjq:$PATH" pm apply wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant pulo-ignorado-no-pick 'for A in $free_a; do skipped "$A" && continue; printf' 'for A in $free_a; do printf'
fresh; WA_NODE_SKIP_ALIASES=wa-worker-remote-1 pm apply wa-t1; if [ "$(who)" = wa-worker-remote-2 ]; then survived; else killed; fi
mutant pulo-ignorado-na-ociosa 'skipped "$A" && continue                                                 # ga-2hd02v.3.26: o gancho' ': # ga-2hd02v.3.26: o gancho'
fresh; busyat 1; sessions "[$(live 1),$(quiet 2),$(quiet 3)]"; WA_NODE_SKIP_ALIASES=wa-worker-remote-2 pm apply wa-t1; if [ "$(who)" = wa-worker-remote-3 ]; then survived; else killed; fi
mutant pulo-lixo-entra "case \"\$_sk\" in ''|*[!A-Za-z0-9._-]*) continue ;; esac" "case \"\$_sk\" in '') continue ;; esac"
fresh; WA_NODE_SKIP_ALIASES="wa-worker-remote-1 wa-worker-remote-2 wa-worker-remote-3 ;rm" pm apply wa-t1; case "$OUT" in *';rm'*) killed ;; *) survived ;; esac
mutant pulo-sai-da-conta 'if [ $((live - n_reuse)) -ge "$SLOTS" ]; then jlog apply' 'if [ $((live - n_reuse - $(printf '"'"'%s\n'"'"' "$live_al" | grep -cxF -- "${SKIP# }" || true))) -ge "$SLOTS" ]; then jlog apply'
fresh; sessions "[$(live 1),$(live 2),$(live 3)]"; WA_NODE_SKIP_ALIASES=wa-worker-remote-3 pm apply wa-t1; if [ "$RC" != 12 ]; then survived; else killed; fi

# ---- ga-31u0zl7: mutantes de WA_NODE_ACCEPT_UNKNOWN. Cada um desliga UMA defesa; o caso designado tem de falhar.
mutant au-sem-variavel '  [ -n "$ACCEPT_UNKNOWN" ] || return 0   # (já saneado' '  : # (já saneado'
fresh; cls "$UNK" 11; d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-valor-ilegivel '[ "$ACCEPT_UNKNOWN" = sem-prova ] || ACCEPT_UNKNOWN=""' ':'
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN=true d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-motivo-extra '(.reasons == ["sem-prova-de-codigo-e-teste"])' '(.reasons | index("sem-prova-de-codigo-e-teste") != null)'
fresh; cls "$UNK_MOLES" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-leitura-falhou ' and ((.info | map(tostring | select(test("ilegiv") or test("^teste-importador-(truncado|nao-parseou):"))) | length) == 0)' ''
fresh; cls "$UNK_READFAIL" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-importador-truncado 'truncado|nao-parseou' 'nao-parseou'
fresh; cls "$UNK_IMP_TRUNC" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-importador-nao-parseou 'truncado|nao-parseou' 'truncado'
fresh; cls "$UNK_IMP_PARSE" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-importador-largo '^teste-importador-(truncado|nao-parseou):' '^teste-importador'
fresh; cls "$UNK_IMP_NEAR" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant au-leitura-so-um-sufixo 'test("ilegiv")' 'test("-ilegivel:")'
fresh; cls '{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":["labels-ilegiveis"]}' 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-info-nao-lista ' and ((.info | type) == "array")' ''
fresh; cls "$UNK_INFOOBJ" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 11 ]; then survived; else killed; fi
mutant au-base-text '.basis = "sem-prova"' '.basis = "text"'
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if printf '%s' "$OUT" | jq -e '.basis == "sem-prova"' >/dev/null 2>&1; then survived; else killed; fi
mutant au-rc-continua-11 'out="$p"; rc=0' 'out="$p"; rc=11'
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant au-check-sem-promocao $'  classify_checked\n  promote_sem_prova\n  printf' $'  classify_checked\n  printf'
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d check wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant au-apply-sem-promocao $'  classify_checked\n  promote_sem_prova\n  if [ "$rc" != 0 ]' $'  classify_checked\n  if [ "$rc" != 0 ]'
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d apply wa-t1; if [ "$RC" = 0 ]; then survived; else killed; fi
mutant au-sem-aviso '[ "$b" = sem-prova ] && who="$who SEM PROVA' ': # SEM PROVA'
fresh; cls "$UNK" 11; WA_NODE_ACCEPT_UNKNOWN=sem-prova d apply wa-t1; if bead '."wa-t1".comments[0]' | grep -q 'SEM PROVA'; then survived; else killed; fi

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
