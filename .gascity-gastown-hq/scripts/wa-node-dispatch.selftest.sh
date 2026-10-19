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
cat > "$T/cls.py" <<'PYEOF'
import os, sys
sys.stdin.read()
sys.stdout.write(open(os.environ["STUB_CLSOUT"]).read())
sys.exit(int(open(os.environ["STUB_CLSRC"]).read().strip()))
PYEOF

export STUB_CALLS="$CALLS" STUB_STATE="$STATE" STUB_GCCALLS="$GCCALLS" STUB_SESS="$SESS" STUB_CLSOUT="$CLSOUT" STUB_CLSRC="$CLSRC"
export GC_CITY="$CITY" WA_NODE_BD="$T/bd" WA_NODE_GC="$T/gc" WA_NODE_CLASSIFY="$T/cls.py" WA_NODE_LOG="$CITY/.gc/wa-node-route.jsonl" WA_NODE_TIMEOUT=20

NODE_TEXT='{"verdict":"node","basis":"text","reasons":["prova-no-texto:1-teste(s)+1-codigo"],"paths":[],"tests":[],"info":[]}'
NODE_LABEL='{"verdict":"node","basis":"label","reasons":["etiqueta-node:ok"],"paths":[],"tests":[],"info":[]}'
MINI='{"verdict":"mini","basis":"","reasons":["caminho-fora-do-filtro:queue.db"],"paths":[],"tests":[],"info":[]}'
UNK='{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"tests":[],"info":[]}'
cls() { printf '%s' "$1" > "$CLSOUT"; printf '%s' "$2" > "$CLSRC"; }
fresh() { # fresh [extra json mesclado na wa-t1]
  printf '{"wa-t1":{"id":"wa-t1","title":"t","status":"open","assignee":"","metadata":{}},"ga-x":{"id":"ga-x","title":"t","status":"open","assignee":"","metadata":{}}}' > "$STATE"
  if [ -n "${1:-}" ]; then jq -c --argjson m "$1" '."wa-t1" += $m' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; fi
  : > "$CALLS"; : > "$GCCALLS"; : > "$CITY/.gc/wa-node-route.jsonl"; echo '{"ok":true,"sessions":[]}' > "$SESS"; cls "$NODE_TEXT" 0
  unset STUB_FAIL_SHOW STUB_SHOW_OTHER STUB_FAIL_LIST STUB_LIST_GARBAGE STUB_UPDATE_RC STUB_NOOP_UPDATE STUB_PARTIAL_UPDATE STUB_UNDO_RC STUB_FAIL_GC STUB_GC_SLEEP STUB_LAND_RC STUB_FAIL_SHOW_AFTER_UPDATE
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
grep -q 'session|new' "$GCCALLS" && bad "apply: rodou gc session new (a duplicata que o dedup derruba)" || ok "apply: não roda gc session new"
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

# ---- 1 caso de ponta a ponta com o classificador REAL (mesma bead que o selftest dele manda ao nó)
fresh; unset WA_NODE_CLASSIFY
jq -c '."wa-t1" += {"description":"Em lib/foo_parser.py a funcao quebra com string vazia. Teste em tests/test_foo_parser.py."}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "ponta a ponta com o classificador real: bead de código+teste -> 0" 0
fresh; jq -c '."wa-t1" += {"description":"lib/foo.py lê queue.db; tests/test_foo.py"}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"
d apply wa-t1; expect_rc "ponta a ponta com o classificador real: bead que cita .db -> 10 sem escrita" 10 w0
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
mutant slot-ignorado 'case "$n" in 0) ;;' 'case "0" in 0) ;;'
fresh; jq -c '. + {"wa-busy":{"id":"wa-busy","status":"in_progress","assignee":"wa-worker-remote-1","metadata":{}}}' "$STATE" > "$STATE.n" && mv "$STATE.n" "$STATE"; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
mutant sessao-ignorada 'case "$live" in 0) ;;' 'case "0" in 0) ;;'
fresh; echo '{"ok":true,"sessions":[{"template":"wa-worker-remote","state":"active","alias":"wa-worker-remote-1"}]}' > "$SESS"; d apply wa-t1; if [ "$RC" = 12 ]; then survived; else killed; fi
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
mutant release-qualquer '[ "$as" = "$ALIAS" ] && [ "$rt" = "$ROUTE" ] ||' 'true ||'
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

echo "---"; echo "$((n-fails))/$n ok"
[ $fails -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($fails)"; exit 1; }
