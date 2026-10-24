#!/usr/bin/env bash
# pilot-dispatcher.mbp-node.selftest.sh — testes do gancho do Pilot para o MBP (ga-w7qwl1.2.2, corte 2 de 5 do ga-w7qwl1.2).
#
# O gancho _pilot_mbp_node_decide oferece ao wa-worker-remote-mbp a bead de WA que o gancho do Hetzner deixou no mini E que o mini não comporta (pool wa-worker no teto). Nasce DESLIGADO
# (PILOT_WA_MBP_ROUTE=off|shadow|on, padrão off, valor desconhecido = off). Quem classifica, consulta o oráculo (gc-session-ssh gate mbp) e escreve é scripts/mbp-node-dispatch.sh (selftest próprio); a sessão do
# alias é aberta pelo PILOT, com as peças genéricas do modo pilot do WA (_pilot_node_remote_open/_rollback, provadas em pilot-dispatcher.wa-node-spawn.selftest.sh). Aqui se prova o que é do MBP.
#
# As funções são as REAIS (extraídas palavra por palavra do pilot-dispatcher.sh); bd, gc, mbp-node-dispatch.sh e wa-node-dispatch.sh são falsos, o bd com estado.
#   A. modos, alvos e ids: off e qualquer valor que não seja shadow|on não chama nada (nem a contagem de sessões).
#   B. o mini cheio: só contagem POSITIVA >= teto abre o caminho; contagem que não leu, teto ilegível e PILOT_SPAWN_WA_WORKER=0 deixam a bead no mini; sessão do MBP e do Hetzner não entram na conta do mini.
#   C. shadow e dry-run: só `apply --dry-run`, nunca devolvem 0, nunca escrevem; o log que não grava avisa.
#   D. on: leitura de três estados, mapa de rc do despachante, abertura da sessão só para a cara exata do apply, desfazer, rc incerto, orçamento de spawn. O alias do Hetzner nunca vale.
#   E. aceite: Athos volta (o despachante recusa) = nenhuma escrita e nenhuma sessão; o gancho do MBP nunca chama o despachante do Hetzner.
#   F. a fiação em dispatch_one: o bloco do gancho EXECUTADO com ganchos falsos (ordem Hetzner → MBP, passadas que não passam por ele).
#   G. mutantes: cada quebra tem de derrubar este selftest. Cada um roda o arquivo inteiro e para no 1º FAIL.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.mbp-node.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK". Bash 3.2 (macOS) basta.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${MBP_NODE_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
# Rodando como mutante (MBP_NODE_SELFTEST_FILE) o primeiro FAIL já diz "morto": sai na hora.
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); [ -z "${MBP_NODE_SELFTEST_FILE:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — obtido '$2', esperado '$3'"; fi; }   # eq <descrição> <obtido> <esperado>

[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FNS=""
for _f in _pilot_mbp_node_decide _pilot_mbp_mini_full _pilot_mbp_node_open _pilot_mbp_node_settle _pilot_pool_live_count _pilot_live_session_count _pilot_wa_node_read _pilot_node_remote_open _pilot_node_remote_rollback \
          _pilot_node_idle_secs _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing gc_json_or_unknown; do
  _b="$(fn_of "$_f")"
  [ -n "$_b" ] || { echo "FATAL: $_f() não está em $DISPATCHER" >&2; exit 2; }
  FNS="$FNS"$'\n'"$_b"
done

T="$(mktemp -d "${TMPDIR:-/tmp}/mbp-node.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/city" "$T/bin"
export FAKE_STATE="$T/state.json" FAKE_LOG="$T/calls" FAKE_BD_LOG="$T/bdcalls" FAKE_GC_LOG="$T/gccalls" FAKE_ORDER="$T/order" FAKE_NSHOW="$T/nshow" FAKE_HETZNER_LOG="$T/hcalls"

# mbp-node-dispatch.sh falso: anota os argumentos; no apply de verdade "escreve" (copia FAKE_BEAD2 para o estado) se FAKE_APPLY_WRITES=1, ou se vazio e o rc for 0.
cat > "$T/scripts/mbp-node-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
echo "script:${1:-}" >> "$FAKE_ORDER"
if [ "${1:-}" = apply ]; then
  dry=0; for a in "$@"; do [ "$a" = --dry-run ] && dry=1; done
  w="${FAKE_APPLY_WRITES:-}"; [ -n "$w" ] || { [ "${FAKE_RC:-0}" = 0 ] && w=1 || w=0; }
  if [ "$dry" = 0 ] && [ "$w" = 1 ]; then cp "$FAKE_BEAD2" "$FAKE_STATE"; fi
fi
echo "${FAKE_OUT:-fake}"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/scripts/mbp-node-dispatch.sh"
# o despachante do Hetzner, que o gancho do MBP NUNCA pode chamar
cat > "$T/scripts/wa-node-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_HETZNER_LOG"
exit 0
EOF
chmod +x "$T/scripts/wa-node-dispatch.sh"

# bd falso COM ESTADO: `bd -C <loja> show <id> --json` e `bd -C <loja> update <id> [--if-assignee X] [--assignee Y] [--status S] [--unset-metadata K] -q`. Knobs: FAKE_BD_SHOW_FAIL_FROM=N (o N-ésimo show
# e os seguintes falham), FAKE_BD_SHOW_ID (devolve a bead com esse id), FAKE_BD_SHOW_EMPTY (sai 0 sem saída), FAKE_BD_UPDATE_MODE=noop (sai 0 e não muda nada).
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
j=""; for x in "$@"; do j="$j|$x"; done
printf '%s\n' "$j" >> "$FAKE_BD_LOG"
[ "${1:-}" = -C ] || exit 64
verb="${3:-}"
echo "bd:$verb" >> "$FAKE_ORDER"
case "$verb" in
  show)
    n=$(cat "$FAKE_NSHOW" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_NSHOW"
    if [ -n "${FAKE_BD_SHOW_FAIL_FROM:-}" ] && [ "$n" -ge "$FAKE_BD_SHOW_FAIL_FROM" ]; then exit 1; fi
    [ -z "${FAKE_BD_SHOW_EMPTY:-}" ] || exit 0
    if [ -n "${FAKE_BD_SHOW_ID:-}" ]; then printf '['; jq --arg i "$FAKE_BD_SHOW_ID" '.id = $i' "$FAKE_STATE"; printf ']\n'; exit 0; fi
    printf '['; cat "$FAKE_STATE"; printf ']\n'; exit 0 ;;
  update)
    [ "${FAKE_BD_UPDATE_MODE:-}" = noop ] && exit 0
    shift 4
    ifa="__none__"; asg="__keep__"; st=""; um=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --if-assignee) ifa="$2"; shift 2 ;;
        --assignee) asg="$2"; shift 2 ;;
        --status) st="$2"; shift 2 ;;
        --unset-metadata) um="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cur=$(jq -r '.assignee // ""' "$FAKE_STATE" 2>/dev/null) || exit 1
    if [ "$ifa" != "__none__" ] && [ "$cur" != "$ifa" ]; then exit 1; fi
    f='.'
    [ "$asg" != "__keep__" ] && f="$f | (if \$a == \"\" then del(.assignee) else .assignee = \$a end)"
    [ -n "$st" ] && f="$f | .status = \$s"
    [ -n "$um" ] && f="$f | del(.metadata[\$m])"
    jq --arg a "$asg" --arg s "$st" --arg m "$um" "$f" "$FAKE_STATE" > "$FAKE_STATE.new" && mv "$FAKE_STATE.new" "$FAKE_STATE"
    exit 0 ;;
esac
exit 64
EOF
chmod +x "$T/bin/bd"
# gc falso: `gc --city C session list --json` devolve $FAKE_SESSIONS; new/wake/close/nudge saem com o rc do knob. Anota cada chamada.
cat > "$T/bin/gc" <<'EOF'
#!/usr/bin/env bash
j=""; for x in "$@"; do j="$j|$x"; done
printf '%s\n' "$j" >> "$FAKE_GC_LOG"
[ "${1:-}" = --city ] && [ "${3:-}" = session ] || exit 64
verb="${4:-}"
echo "gc:$verb" >> "$FAKE_ORDER"
empty='{"sessions":[]}'
case "$verb" in
  list) [ "${FAKE_GC_LIST_RC:-0}" = 0 ] || exit "$FAKE_GC_LIST_RC"; printf '%s' "${FAKE_SESSIONS:-$empty}"; exit 0 ;;
  new) exit "${FAKE_GC_NEW_RC:-0}" ;;
  wake) exit 0 ;;
  close) exit "${FAKE_GC_CLOSE_RC:-0}" ;;
  nudge) exit "${FAKE_GC_NUDGE_RC:-0}" ;;
esac
exit 64
EOF
chmod +x "$T/bin/gc"
export PATH="$T/bin:$PATH"

PRELUDE='warn(){ echo "WARN $*" >&2; }
log(){ echo "LOG $*" >&2; }
timeout(){ shift; "$@"; }'

ID=wa-abc12
ST=/x/whatsapp_automation
# mkb <arquivo> <status> <dono> <marca> [título] [id] [rota] — a bead falsa no formato de `bd show` (o bd omite dono, marca e rota vazios)
mkb() {
  jq -n --arg id "${6:-$ID}" --arg s "$2" --arg a "$3" --arg m "$4" --arg t "${5-Título X}" --arg r "${7:-}" \
    '{id:$id,status:$s,title:$t,metadata:((if $m=="" then {} else {"pilot.wa_node_alias":$m} end) + (if $r=="" then {} else {"gc.routed_to":$r} end))} + (if $a=="" then {} else {assignee:$a} end)' > "$1"
}
mkb "$T/b.free.json" open "" ""
mkb "$T/b.ap1.json" in_progress wa-worker-remote-mbp-1 wa-worker-remote-mbp-1
mkb "$T/b.hetz.json" in_progress wa-worker-remote-1 ""
mkb "$T/b.hz1.json" in_progress wa-worker-remote-1 wa-worker-remote-1   # a forma EXATA que o apply do Hetzner escreve (dono = marca): só o alias separa esta bead de uma do MBP
mkb "$T/b.mbp.json" in_progress wa-worker-remote-mbp-1 ""
mkb "$T/b.routed.json" open "" "" "Título X" "$ID" wa-worker-remote
mkb "$T/b.stamped.json" open "" "" "Título X" "$ID" wa-worker
mkb "$T/b.foreign.json" in_progress mila-wa ""

CITYGC="$T/city/.gc"
logfix() { [ -d "$CITYGC" ] || rm -f "$CITYGC"; chmod u+w "$CITYGC" 2>/dev/null || true; rmdir "$CITYGC/mbp-node-route.jsonl" 2>/dev/null || true; }
# baseline: o pool wa-worker do mini está CHEIO (4 de 4) — os casos que querem outra coisa dizem
reset() {
  logfix
  : > "$T/calls"; : > "$T/bdcalls"; : > "$T/gccalls"; : > "$T/err"; : > "$T/order"; : > "$T/hcalls"; echo 0 > "$T/nshow"
  rm -f "$T/city/.gc/mbp-node-route.jsonl"
  cp "$T/b.free.json" "$T/state.json"
  unset FAKE_BD_UPDATE_MODE FAKE_BD_SHOW_FAIL_FROM FAKE_BD_SHOW_ID FAKE_BD_SHOW_EMPTY FAKE_GC_LIST_RC FAKE_GC_NEW_RC FAKE_GC_CLOSE_RC FAKE_GC_NUDGE_RC FAKE_APPLY_WRITES FAKE_RC FAKE_OUT FAKE_SESSIONS \
        PRE_SLOW PILOT_WA_MBP_ROUTE DRY_RUN PILOT_SPAWN_WA_WORKER
  export FAKE_BEAD2="$T/b.ap1.json" PILOT_TEST_WA_WORKER_LIVE_COUNT=4 PILOT_WA_WORKER_MAX=4
}
# H <função> <args…> — roda a função REAL (extraída) num shell novo, com os falsos no PATH; imprime só "rc=N".
H() {
  GC_CITY="$T/city" PILOT_WA_MBP_SCRIPTS="$T/scripts" \
    bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_PILOT_SLOW_SPAWN_SEEN="${PRE_SLOW:-0}"; "$@"; echo "rc=$?"' _ "$@" 2>>"$T/err" | tail -1
}
D() { export PILOT_WA_MBP_ROUTE="$1" FAKE_RC="${2:-0}" DRY_RUN="${3:-0}"; H _pilot_mbp_node_decide "${ID_ARG-$ID}" "$ST" "${TGT-wa-worker}"; }   # D <modo> <rc do script> [dry]
ord()   { tr '\n' ' ' < "$T/order"; }
stt()   { jq -r '[.status, (.assignee // "-"), (.metadata["pilot.wa_node_alias"] // "-")] | join(",")' "$T/state.json"; }
ncalls() { wc -l < "$T/calls" | tr -d ' '; }
nbd()   { wc -l < "$T/bdcalls" | tr -d ' '; }
ngc()   { wc -l < "$T/gccalls" | tr -d ' '; }
nupd()  { grep -c '|update|' "$T/bdcalls" | tr -d ' '; }
jsonl() { cat "$T/city/.gc/mbp-node-route.jsonl" 2>/dev/null; }
UPD()   { printf '|-C|%s|update|%s|--if-assignee|%s|--assignee||--status|open|--unset-metadata|pilot.wa_node_alias|-q' "$ST" "$ID" "$1"; }
FREE="open,-,-"
AP1="in_progress,wa-worker-remote-mbp-1,wa-worker-remote-mbp-1"
# sess <vivas wa-worker> <vivas do MBP> <vivas do Hetzner> — a lista de sessões do engine
sess() {
  jq -nc --argjson w "$1" --argjson m "$2" --argjson h "$3" '{sessions: ([range($w) | {template:"wa-worker",state:"active",alias:"w\(.)"}]
    + [range($m) | {template:"wa-worker-remote-mbp",state:"active",alias:"wa-worker-remote-mbp-\(. + 1)"}]
    + [range($h) | {template:"wa-worker-remote",state:"active",alias:"wa-worker-remote-\(. + 1)"}])}'
}

echo "pilot-dispatcher.mbp-node.selftest — ga-w7qwl1.2.2"

echo; echo "=== A. modos, alvos e ids ==="
for m in "" off OFF On "on " yes 1 shadowx label auto; do
  reset; r=$(D "$m" 0)
  eq "modo '$m' não é shadow|on: bead segue no mini, nada chamado (script, bd, gc)" "$r $(ncalls) $(nbd) $(ngc)" "rc=1 0 0 0"
done
for t in ps-worker wa-worker-remote gastown.dog mila-wa ""; do reset; r=$(TGT=$t D on 0); eq "alvo '$t' não é wa-worker: 1, nada chamado" "$r $(ncalls) $(nbd) $(ngc)" "rc=1 0 0 0"; done
for i in ps-abc12 ga-abc12 lx-abc12 ""; do reset; r=$(ID_ARG=$i D on 0); eq "id '$i' não é wa-*: 1, nada chamado" "$r $(ncalls) $(nbd) $(ngc)" "rc=1 0 0 0"; done
reset; mv "$T/scripts/mbp-node-dispatch.sh" "$T/scripts/x.sh"; r=$(D on 0); mv "$T/scripts/x.sh" "$T/scripts/mbp-node-dispatch.sh"
eq "mbp-node-dispatch.sh ausente: 1 (a bead segue no mini)" "$r" "rc=1"; grep -q 'não está executável' "$T/err" && ok "e o aviso diz por quê" || fail "aviso: $(cat "$T/err")"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT=1 D off 0); eq "off não lê nem a contagem de sessões (mesmo com a lista quebrada)" "$r $(ngc)" "rc=1 0"

echo; echo "=== B. o mini cheio ==="
for m in shadow on; do
  reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT=3 D $m 0); eq "$m, 3 de 4 no pool: o mini tem vaga, 1 e nada chamado" "$r $(ncalls) $(nbd) $(ngc)" "rc=1 0 0 0"
done
reset; r=$(D on 0); eq "on, 4 de 4 (igual ao teto): o mini está cheio, o caminho abre (0)" "$r" "rc=0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT=9 D on 0); eq "on, 9 de 4: cheio, o caminho abre (0)" "$r" "rc=0"
reset; r=$(PILOT_WA_WORKER_MAX= D on 0); eq "teto vazio vale o padrão 4 (4 de 4: cheio)" "$r" "rc=0"
for mx in abc 4x -1 "4 "; do reset; r=$(PILOT_WA_WORKER_MAX="$mx" D on 0); eq "teto '$mx' não é número: não sei que está cheio, 1 e nada chamado" "$r $(ncalls) $(nbd) $(ngc)" "rc=1 0 0 0"; done
reset; r=$(PILOT_SPAWN_WA_WORKER=0 PILOT_TEST_WA_WORKER_LIVE_COUNT=9 D on 0); eq "PILOT_SPAWN_WA_WORKER=0 (o pool nem abre sessão): não há 'cheio', 1 e nada chamado" "$r $(ncalls) $(nbd)" "rc=1 0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_GC_LIST_RC=1 D on 0)
eq "contagem que não leu (session list falhou): NÃO sei que está cheio, 1 e o despachante não é chamado" "$r $(ncalls) $(nbd)" "rc=1 0 0"
grep -q 'cannot read the wa-worker live session count' "$T/err" && ok "...e o aviso do contador diz que não leu" || fail "aviso: $(cat "$T/err")"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_SESSIONS='isto não é json' D on 0); eq "lista de sessões ilegível: 1, nada chamado" "$r $(ncalls) $(nbd)" "rc=1 0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_SESSIONS='{"sessions":"x"}' D on 0); eq "lista sem o array .sessions: 1, nada chamado" "$r $(ncalls) $(nbd)" "rc=1 0 0"
# a conta é a do POOL DO MINI: sessão do MBP (wa-worker-remote-mbp) e do Hetzner (wa-worker-remote) não enchem o teto do mini
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_SESSIONS="$(sess 3 2 3)" D on 0)
eq "3 wa-worker + 2 do MBP + 3 do Hetzner: o mini tem 3 de 4 (as do MBP e do Hetzner não contam), 1 e nada chamado" "$r $(ncalls) $(nbd)" "rc=1 0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_SESSIONS="$(sess 0 2 3)" D on 0)
eq "só sessões do MBP e do Hetzner (0 no mini): o mini está vazio, 1 e nada chamado" "$r $(ncalls) $(nbd)" "rc=1 0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_SESSIONS="$(sess 4 0 0)" D on 0)
eq "4 wa-worker vivas na lista de verdade: cheio, o caminho abre (0)" "$r" "rc=0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_SESSIONS="$(sess 2 0 0)" PILOT_WA_WORKER_MAX=2 D on 0); eq "teto 2 e 2 vivas: cheio (o teto vem de PILOT_WA_WORKER_MAX, o dinâmico do mini)" "$r" "rc=0"

echo; echo "=== C. shadow e dry-run ==="
reset; r=$(D shadow 0)
eq "shadow nunca devolve 0 (nem com o script dizendo 0): 1" "$r" "rc=1"
eq "shadow chama só 'apply … --basis any --dry-run', sem ler a bead, sem escrever, sem sessão" "$(cat "$T/calls")|$(ord)" "apply $ID --store $ST --basis any --dry-run|script:apply "
jsonl | jq -e --arg b "$ID" 'select(.event=="pilot-node-route" and .mode=="shadow" and .bead==$b and .rc==0)' >/dev/null && ok "shadow grava a linha em mbp-node-route.jsonl (o log do MBP, não o do Hetzner)" || fail "jsonl: $(jsonl)"
eq "...e só ela: nenhum wa-node-route.jsonl" "$([ -e "$T/city/.gc/wa-node-route.jsonl" ] && echo existe || echo não)" "não"
reset; r=$(D shadow 12); eq "shadow com o gate recusando (rc 12): 1 e a linha leva o rc" "$r $(jsonl | jq -r .rc)" "rc=1 12"
reset; r=$(D shadow 0 1); eq "shadow tem precedência sobre o dry-run: o mesmo dry-run, 1" "$r $(cat "$T/calls")" "rc=1 apply $ID --store $ST --basis any --dry-run"
reset; r=$(D on 0 1)
eq "on com DRY_RUN=1: chama o mesmo 'apply --dry-run', sem ler a bead, devolve 1" "$r|$(cat "$T/calls")|$(ord)|$(nbd)" "rc=1|apply $ID --store $ST --basis any --dry-run|script:apply |0"
grep -q 'WOULD route' "$T/err" && ok "dry-run rc 0: 'WOULD route'" || fail "dry-run: $(cat "$T/err")"
eq "dry-run: nada escrito, nenhuma sessão" "$(stt) $(ngc)" "$FREE 0"
for c in 10 11 12 13; do reset; r=$(D on $c 1); eq "dry-run com rc $c: 1" "$r" "rc=1"; grep -q 'would NOT go' "$T/err" && ok "dry-run rc $c: o log diz 'would NOT go', não 'WOULD route'" || fail "dry-run $c: $(cat "$T/err")"; done
# o log que NÃO grava: o despacho não muda, mas a linha perdida avisa (em shadow ela é a única saída do gancho)
reset; mkdir -p "$CITYGC/mbp-node-route.jsonl"; r=$(D shadow 0)
eq "log impossível de gravar (o jsonl é uma pasta): shadow segue devolvendo 1" "$r" "rc=1"
grep -q 'WARN mbp-node: linha de wa-abc12 (shadow, rc=0) NÃO gravada em mbp-node-route.jsonl' "$T/err" && ok "...e AVISA qual linha se perdeu (bead, modo, rc)" || fail "sem aviso da linha perdida: $(cat "$T/err")"
reset; mkdir -p "$CITYGC/mbp-node-route.jsonl"; r=$(D on 0)
eq "on com o log impossível de gravar: o despacho segue (0), a sessão abre — o log é medição, não decisão" "$r $(ord)" "rc=0 bd:show script:apply bd:show gc:list gc:new gc:nudge "
logfix

echo; echo "=== D. on: leitura de três estados, mapa de rc, sessão ==="
reset; r=$(D on 0)
eq "on, tudo certo: 0" "$r" "rc=0"
eq "ordem: lê a bead, apply, relê a bead, lista as sessões, abre, avisa" "$(ord)" "bd:show script:apply bd:show gc:list gc:new gc:nudge "
eq "apply com a base 'any' e a loja" "$(cat "$T/calls")" "apply $ID --store $ST --basis any"
grep -qF -- "|--city|$T/city|session|new|wa-worker-remote-mbp|--alias|wa-worker-remote-mbp-1|--no-attach|--title-hint|build $ID: Título X" "$T/gccalls" && ok "abre 'session new wa-worker-remote-mbp --alias wa-worker-remote-mbp-1 --no-attach' (template e alias do MBP)" || fail "new: $(cat "$T/gccalls")"
grep -qF -- 'session|nudge|wa-worker-remote-mbp-1|Bead nova para você: wa-abc12 — Título X.' "$T/gccalls" && ok "e avisa o alias do MBP" || fail "nudge: $(cat "$T/gccalls")"
grep -qF -- "ache com 'bd -C whatsapp_automation list --status in_progress --assignee \"\$GC_ALIAS\" --json --limit 5' e siga o seu protocolo." "$T/gccalls" && ok "o aviso manda 'bd -C whatsapp_automation list …' (o prompt do worker do MBP lê a loja do rig)" || fail "nudge sem -C whatsapp_automation: $(cat "$T/gccalls")"
eq "a bead fica como o apply a deixou" "$(stt)" "$AP1"
eq "nada do Hetzner foi chamado" "$(wc -l < "$T/hcalls" | tr -d ' ')" "0"
# três estados da leitura que vem ANTES do script
for spec in 'dono do Hetzner|b.hetz.json' 'dono do MBP|b.mbp.json' 'rota do nó|b.routed.json'; do
  reset; cp "$T/${spec#*|}" "$T/state.json"; r=$(D on 0)
  eq "bead que já é do nó ($(printf '%s' "${spec%%|*}")): 2, o script nem é chamado, nada escrito, nenhuma sessão" "$r $(ncalls) $(nupd) $(ngc)" "rc=2 0 0 0"
done
reset; r=$(FAKE_BD_SHOW_FAIL_FROM=1 D on 0); eq "bd falha ao reler: 2 (não é 'livre')" "$r $(ncalls)" "rc=2 0"
reset; r=$(FAKE_BD_SHOW_EMPTY=1 D on 0); eq "bd sai 0 sem saída: 2" "$r $(ncalls)" "rc=2 0"
reset; r=$(FAKE_BD_SHOW_ID=wa-outra D on 0); eq "bd devolve a bead de OUTRO id: 2" "$r $(ncalls)" "rc=2 0"
reset; cp "$T/b.foreign.json" "$T/state.json"; r=$(D on 12); eq "bead de outro dono que não é do nó: lida e segue; script diz 12: 1" "$r" "rc=1"
reset; cp "$T/b.stamped.json" "$T/state.json"; r=$(D on 12); eq "bead carimbada gc.routed_to=wa-worker (a do mini): lida como 'não é do nó', segue ao apply, que recusa (12): 1" "$r $(ncalls)" "rc=1 1"
reset; r=$(D shadow 0); eq "em shadow a leitura não acontece: nenhum bd" "$(nbd)" "0"
# mapa de rc do script
for c in 10 11 12 2 125 126 127 1 3; do reset; r=$(D on $c); eq "script rc $c: nada ficou escrito → 1 (segue no mini), sem sessão" "$r $(ngc)" "rc=1 0"; done
for c in 13 124 137 143 129 130 139 141 255; do reset; r=$(D on $c); eq "script rc $c: pode ter escrito → 2 (segura)" "$r" "rc=2"; done
# a sessão
reset; r=$(FAKE_APPLY_WRITES=0 D on 0); eq "apply disse 0 mas a bead segue livre na releitura: 2, sem sessão, sem desfazer" "$r $(ngc) $(nupd)" "rc=2 0 0"
for spec in 'dono do Hetzner|in_progress|wa-worker-remote-1|wa-worker-remote-1' 'dono do Hetzner com marca|in_progress|wa-worker-remote-2|wa-worker-remote-2' 'dono de outra pessoa|in_progress|mila-wa|mila-wa' 'alias do MBP 3|in_progress|wa-worker-remote-mbp-3|wa-worker-remote-mbp-3' \
            'alias do MBP 0|in_progress|wa-worker-remote-mbp-0|wa-worker-remote-mbp-0' 'alias do MBP 12|in_progress|wa-worker-remote-mbp-12|wa-worker-remote-mbp-12' \
            'marca de outro alias|in_progress|wa-worker-remote-mbp-1|wa-worker-remote-mbp-2' 'sem marca|in_progress|wa-worker-remote-mbp-1|' 'status open|open|wa-worker-remote-mbp-1|wa-worker-remote-mbp-1'; do
  IFS='|' read -r nm st as mk <<EOF_S
$spec
EOF_S
  reset; mkb "$T/b.x.json" "$st" "$as" "$mk"; export FAKE_BEAD2="$T/b.x.json"; r=$(D on 0)
  eq "depois do apply a bead está com a cara errada ($nm): 2, sem sessão e sem desfazer" "$r $(ngc) $(nupd)" "rc=2 0 0"
done
reset; mkb "$T/b.2.json" in_progress wa-worker-remote-mbp-2 wa-worker-remote-mbp-2; export FAKE_BEAD2="$T/b.2.json"; r=$(D on 0)
grep -qF -- '|new|wa-worker-remote-mbp|--alias|wa-worker-remote-mbp-2|' "$T/gccalls" && eq "o alias 2 do MBP também abre" "$r" "rc=0" || fail "alias 2: $r $(cat "$T/gccalls")"
reset; r=$(FAKE_BD_SHOW_FAIL_FROM=2 D on 0); eq "a releitura depois do apply falha: 2, sem sessão" "$r $(ngc)" "rc=2 0"
reset; r=$(FAKE_GC_NEW_RC=1 D on 0)
eq "session new falhou: fecha a sessão, solta a bead e confirma — 1 (segue no mini)" "$r $(ord)$(stt)" "rc=1 bd:show script:apply bd:show gc:list gc:new gc:close bd:update bd:show $FREE"
grep -qxF -- "$(UPD wa-worker-remote-mbp-1)" "$T/bdcalls" && ok "o desfazer é UMA escrita guardada com a chave pilot.wa_node_alias" || fail "update: $(cat "$T/bdcalls")"
reset; r=$(FAKE_GC_LIST_RC=1 PILOT_TEST_WA_WORKER_LIVE_COUNT=4 D on 0); eq "a lista de sessões não leu: não abre, desfaz sem fechar sessão — 1" "$r $(ord)$(stt)" "rc=1 bd:show script:apply bd:show gc:list bd:update bd:show $FREE"
reset; r=$(FAKE_GC_NUDGE_RC=1 D on 0); eq "o aviso falhou: desfaz — 1" "$r $(stt)" "rc=1 $FREE"
reset; r=$(FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=noop D on 0); eq "o desfazer não se confirma: 2 (segura; a bead segue do alias)" "$r $(stt)" "rc=2 $AP1"
# rc incerto: desfaz só a cara do apply
for c in 13 124 143 130; do
  reset; r=$(FAKE_APPLY_WRITES=1 D on $c)
  eq "rc $c e a escrita pegou (cara do apply, sem sessão): desfaz e devolve 2" "$r $(stt)" "rc=2 $FREE"
done
reset; r=$(FAKE_APPLY_WRITES=0 D on 13); eq "rc 13 e a bead segue livre: não escreve nada — 2" "$r $(nupd)" "rc=2 0"
reset; export FAKE_BEAD2="$T/b.foreign.json"; r=$(FAKE_APPLY_WRITES=1 D on 13); eq "rc 13 e a bead é de OUTRO dono: não toca — 2" "$r $(stt) $(nupd)" "rc=2 in_progress,mila-wa,- 0"
reset; export FAKE_BEAD2="$T/b.hz1.json"; r=$(FAKE_APPLY_WRITES=1 D on 13); eq "rc 13 e a bead tem a forma do apply do HETZNER (dono = marca = wa-worker-remote-1): não toca — 2" "$r $(nupd) $(stt)" "rc=2 0 in_progress,wa-worker-remote-1,wa-worker-remote-1"
reset; mkb "$T/b.y.json" in_progress wa-worker-remote-mbp-1 wa-worker-remote-mbp-2; export FAKE_BEAD2="$T/b.y.json"; r=$(FAKE_APPLY_WRITES=1 D on 13); eq "rc 13 e a marca é de outro alias: não toca — 2" "$r $(nupd)" "rc=2 0"
reset; r=$(FAKE_APPLY_WRITES=1 FAKE_BD_SHOW_FAIL_FROM=2 D on 13); eq "rc 13 e a releitura falha: não toca — 2" "$r $(nupd)" "rc=2 0"
reset; r=$(PRE_SLOW=1 D on 0); eq "sessão lenta já gastou o orçamento do sweep: nem escreve — 1" "$r $(ncalls)" "rc=1 0"
reset; r=$(PRE_SLOW=1 D shadow 0); eq "o orçamento gasto não afeta o shadow" "$r $(ncalls)" "rc=1 1"
reset; r=$(PRE_SLOW=1 D on 0 1); eq "nem o dry-run" "$r $(ncalls)" "rc=1 1"

echo; echo "=== E. aceite: o Athos volta, o Hetzner e o mini não se mexem ==="
reset; r=$(D on 0); eq "gate liberando e mini cheio: a bead vai ao alias do MBP e a sessão abre" "$r $(stt)" "rc=0 $AP1"
grep -q 'gc:new' "$T/order" && ok "...(abriu mesmo: gc session new no log)" || fail "sem session new: $(ord)"
reset; r=$(FAKE_OUT='o oráculo diz que o nó não recebe agora (athos-no-mbp) — fica no mini' D on 12)
eq "o Athos voltou (o despachante recusa, rc 12): nenhuma bead nova vai ao MBP, nenhuma sessão abre, nenhuma escrita" "$r $(stt) $(ngc) $(nupd) $(grep -c 'gc:new' "$T/order")" "rc=1 $FREE 0 0 0"
reset; r=$(FAKE_OUT='gate sem resposta' D on 11); eq "gate sem resposta (rc 11, 'não consegui saber'): 1, sem sessão" "$r $(ngc) $(nupd)" "rc=1 0 0"
reset; r=$(D on 0 >/dev/null; D on 0); eq "o gancho nunca chama o despachante do Hetzner (nem no caminho que abre sessão)" "$(wc -l < "$T/hcalls" | tr -d ' ')" "0"
reset; r=$(D shadow 0 >/dev/null; D on 12 >/dev/null; D on 0 1 >/dev/null); eq "...nem em shadow, nem com a recusa, nem no dry-run" "$(wc -l < "$T/hcalls" | tr -d ' ')" "0"
reset; r=$(PILOT_WA_NODE_ROUTE=auto PILOT_WA_NODE_SPAWN=pilot PILOT_WA_NODE_SLOTS=3 WA_NODE_ALIAS=wa-worker-remote-1 D on 0); eq "as variáveis do Hetzner no ambiente não mexem no gancho do MBP" "$r $(stt) $(cat "$T/calls")" "rc=0 $AP1 apply $ID --store $ST --basis any"

# O teto do Hetzner, medido no despachante REAL (scripts/wa-node-dispatch.sh --dry-run, com bd, gc, classificador e oráculo falsos): sessão do MBP viva não ocupa o slot dele; uma do Hetzner ocupa (o controle).
# Os mutantes mexem no dispatcher do Pilot, não neste script: a seção não roda nas cópias.
if [ -z "${MBP_NODE_SELFTEST_FILE:-}" ]; then
  echo; echo "=== E2. o teto do Hetzner, no despachante real ==="
  HZS="$SELF_DIR/../../../scripts/wa-node-dispatch.sh"
  if [ -x "$HZS" ]; then
    mkdir -p "$T/h/store" "$T/h/city/.gc"
    cat > "$T/h/bd" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -C ] && shift 2
case "${1:-}" in
  show) printf '[{"id":"wa-hz1","title":"t","status":"open","metadata":{}}]\n' ;;
  list) printf '[]\n' ;;
  *) exit 1 ;;
esac
EOF
    cat > "$T/h/gc" <<'EOF'
#!/bin/sh
[ "$1 $2" = "session list" ] && { printf '%s' "$FAKE_HSESS"; exit 0; }
exit 1
EOF
    printf 'import sys\nsys.stdin.read()\nsys.stdout.write(\x27{"verdict":"node","basis":"text","reasons":[],"paths":[],"tests":[],"info":[]}\x27)\n' > "$T/h/cls.py"
    printf 'import sys\nsys.stdout.write(\x27{"verdict":"node","reason":"free_slot","effective":3,"active":0,"free":3}\x27)\n' > "$T/h/cap.py"
    chmod +x "$T/h/bd" "$T/h/gc"
    hz() { GC_CITY="$T/h/city" WA_NODE_BD="$T/h/bd" WA_NODE_GC="$T/h/gc" WA_NODE_CLASSIFY="$T/h/cls.py" WA_NODE_CAPACITY="$T/h/cap.py" WA_NODE_LOG="$T/h/city/.gc/log.jsonl" WA_NODE_SPAWN=pilot WA_NODE_SLOTS=1 FAKE_HSESS="$1" bash "$HZS" apply wa-hz1 --store "$T/h/store" --basis any --dry-run 2>&1; echo "rc=$?"; }
    r=$(hz '{"sessions":[]}'); eq "controle: sem sessão nenhuma o Hetzner (1 slot) aceita a bead" "$(printf '%s' "$r" | tail -1) $(printf '%s' "$r" | grep -c 'iria para wa-worker-remote-1')" "rc=0 1"
    r=$(hz "$(sess 0 2 0)"); eq "2 sessões do MBP vivas: o slot do Hetzner segue livre (o teto dele não muda com o MBP ligado)" "$(printf '%s' "$r" | tail -1) $(printf '%s' "$r" | grep -c 'iria para wa-worker-remote-1')" "rc=0 1"
    r=$(hz '{"sessions":[{"template":"wa-worker-remote","alias":"wa-worker-remote-1","state":"active"}]}'); eq "controle: uma sessão do Hetzner viva ocupa o slot (12) — o caso é sensível" "$(printf '%s' "$r" | tail -1)" "rc=12"
  else
    fail "scripts/wa-node-dispatch.sh não está em $HZS"
  fi
fi

echo; echo "=== F. a fiação em dispatch_one ==="
lnof() { grep -nF -- "$1" "$DISPATCHER" | head -n "${2:-1}" | tail -n 1 | cut -d: -f1; }
eq "o gancho do MBP é chamado em UM lugar de dispatch_one" "$(grep -cF -- '_pilot_mbp_node_decide "$STORY_ID"' "$DISPATCHER")" "1"
w1=$(lnof '_pilot_wa_node_decide "$STORY_ID" "$STORY_BEAD_CITY" "$_SLING_TARGET"'); m1=$(lnof '_pilot_mbp_node_decide "$STORY_ID" "$STORY_BEAD_CITY" "$_SLING_TARGET"')
i1=$(awk -v a="${w1:-0}" 'NR>a && index($0,"        if [ \"$_RP_NODE_RC\" = 0 ]; then")==1 {print NR; exit}' "$DISPATCHER")
{ [ -n "$w1" ] && [ -n "$m1" ] && [ -n "$i1" ] && [ "$w1" -lt "$m1" ] && [ "$m1" -lt "$i1" ]; } && ok "o gancho do MBP vem DEPOIS do do Hetzner e ANTES do tratamento do rc (se o Hetzner levou, ele nem é chamado)" || fail "ordem das chamadas ($w1, $m1, $i1)"
ARM="$(awk 'f==0 && $0 ~ /^        local _RP_NODE_RC=0$/ {f=1} f==1 {print} f==1 && $0 ~ /^        : # pool: leave UNASSIGNED/ {exit}' "$DISPATCHER")"
[ -n "$ARM" ] || fail "a região do gancho do WA não foi achada em $DISPATCHER"
# armrun <rc do gancho do Hetzner> <rc do gancho do MBP> <_PILOT_WA_NODE_PASS> <_PILOT_NODE_ONLY> → "rc=<rc da região> fell=<0|1> target=<alvo no fim> result=<DISPATCH_RESULT> calls=<ganchos e escritas>"
armrun() {
  : > "$T/armbd"
  ARMBD="$T/armbd" WARC="$1" MBPRC="$2" _PILOT_WA_NODE_PASS="$3" _PILOT_NODE_ONLY="$4" _SLING_TARGET=wa-worker bash -c '
bd() { echo bd >> "$ARMBD"; }
log() { :; }
_pilot_wa_node_adopt() { echo adopt >> "$ARMBD"; return 0; }
_pilot_wa_node_unadopt() { echo unadopt >> "$ARMBD"; }
_pilot_priority_yield_release() { echo yield >> "$ARMBD"; }
unmark_pool_builder() { echo unmark >> "$ARMBD"; }
_pilot_wa_node_decide() { echo wa >> "$ARMBD"; return "$WARC"; }
_pilot_mbp_node_decide() { echo mbp >> "$ARMBD"; return "$MBPRC"; }
f() {
  local STORY_ID=wa-abc12 STORY_BEAD_CITY=/x BUILDER_TARGET=wa-worker-1
'"$ARM"'
  FELL=1
}
f; rc=$?; echo "rc=$rc fell=${FELL:-0} target=$_SLING_TARGET result=${DISPATCH_RESULT:-} calls=$(tr "\n" "," < "$ARMBD")"' 2>/dev/null | tail -1
}
eq "Hetzner levou (rc 0): o MBP nem é chamado, o alvo vira wa-worker-remote" "$(armrun 0 0 0 0)" "rc=0 fell=1 target=wa-worker-remote result= calls=wa,"
eq "Hetzner não levou (rc 1) e o MBP levou (rc 0): o mesmo caminho do nó (alvo wa-worker-remote), nada solto" "$(armrun 1 0 0 0)" "rc=0 fell=1 target=wa-worker-remote result= calls=wa,mbp,"
eq "nenhum dos dois levou (rc 1 e 1): o caminho do pool do mini segue, o alvo não muda" "$(armrun 1 1 0 0)" "rc=0 fell=1 target=wa-worker result= calls=wa,mbp,"
eq "Hetzner não levou e o MBP inseguro (rc 2): solta a claim e não despacha (wa_node_unknown)" "$(armrun 1 2 0 0)" "rc=1 fell=0 target=wa-worker result=wa_node_unknown calls=wa,mbp,bd,bd,"
eq "Hetzner inseguro (rc 2): o MBP nem é chamado, solta a claim" "$(armrun 2 0 0 0)" "rc=1 fell=0 target=wa-worker result=wa_node_unknown calls=wa,bd,bd,"
eq "passada de WA (flag 1), Hetzner rc 1: o MBP NÃO é chamado, a soltura por rótulo de sempre" "$(armrun 1 0 1 0)" "rc=1 fell=0 target=wa-worker result=wa_node_pass_released calls=adopt,wa,unadopt,yield,"
eq "passada só-nó do disk floor, Hetzner rc 1: o MBP NÃO é chamado, a soltura de sempre (disk_floor_node_only)" "$(armrun 1 0 0 1)" "rc=1 fell=0 target=wa-worker result=disk_floor_node_only calls=wa,bd,bd,"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
if [ -n "${MBP_NODE_SELFTEST_FILE:-}" ]; then
  echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
  [ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
  exit 0
fi

# MBP_NODE_ST_NOMUT=1 pula os mutantes (a bateria do gate é a completa)
if [ "${MBP_NODE_ST_NOMUT:-}" = 1 ]; then
  echo "(mutantes pulados: MBP_NODE_ST_NOMUT=1)"; echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
  [ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
  exit 0
fi

echo; echo "=== G. mutantes ==="
# mut <nome> <função|-> <trecho original> <trecho novo> — troca a 1ª ocorrência DENTRO da função (ou do arquivo, com "-") numa cópia do pilot-dispatcher.sh e roda este arquivo contra ela; tem de reprovar
mut() {
  local name="$1" fn="$2" old="$3" new="$4" copy="$T/mut.sh"
  python3 -I - "$DISPATCHER" "$copy" "$fn" "$old" "$new" <<'EOF' || { fail "mutante $name: o trecho original não existe em $2 (o fonte mudou? atualize o mutante)"; return; }
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
fn, old, new = sys.argv[3], sys.argv[4], sys.argv[5]
lo, hi = 0, len(src)
if fn != "-":
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(fn), src, re.S | re.M)
    if not m: sys.exit(1)
    lo, hi = m.span()
i = src.find(old, lo, hi)
if i < 0: sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src[:i] + new + src[i + len(old):])
EOF
  if MBP_NODE_SELFTEST_FILE="$copy" bash "$SELF" >/dev/null 2>&1; then fail "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi
}
D1=_pilot_mbp_node_decide; M1=_pilot_mbp_mini_full; O1=_pilot_mbp_node_open; S1=_pilot_mbp_node_settle
mut off-roda            $D1 'case "$_mode" in shadow|on) ;; *) return 1 ;; esac' 'case "$_mode" in off|shadow|on) ;; *) return 1 ;; esac'
mut label-roda          $D1 'case "$_mode" in shadow|on) ;; *) return 1 ;; esac' 'case "$_mode" in shadow|on|label|auto) ;; *) return 1 ;; esac'
mut sem-guarda-alvo     $D1 '[ "$_tgt" = "wa-worker" ] || return 1' ':'
mut sem-guarda-id       $D1 'case "$_id" in wa-*) ;; *) return 1 ;; esac' ':'
mut sem-cheio           $D1 '_pilot_mbp_mini_full || return 1' ':'
mut cheio-ao-contrario  $D1 '_pilot_mbp_mini_full || return 1' '_pilot_mbp_mini_full && return 1'
mut do-no-vira-1        $D1 'node) warn "mbp-node: $_id já é do nó' 'node) return 1; warn "mbp-node: $_id já é do nó'
mut ilegivel-vira-1     $D1 '*) warn "mbp-node: não consegui reler $_id' '*) return 1; warn "mbp-node: não consegui reler $_id'
mut sem-leitura         $D1 'if [ "$_mode" = shadow ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if true; then'
mut shadow-escreve      $D1 'if [ "$_mode" = shadow ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if [ "${DRY_RUN:-0}" = "1" ]; then'
mut dry-run-escreve     $D1 'if [ "$_mode" = shadow ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if [ "$_mode" = shadow ]; then'
mut base-do-dry-run     $D1 '--basis any --dry-run 2>/dev/null' '--basis label --dry-run 2>/dev/null'
mut base-do-apply       $D1 '--basis any 2>/dev/null) || _rc=$?' '--basis label 2>/dev/null) || _rc=$?'
mut dry-run-devolve-0   $D1 'nothing written)"; fi
    fi
    return 1' 'nothing written)"; fi
    fi
    return 0'
mut dry-run-sem-aviso   $D1 'would NOT go to the MBP' 'would go to the MBP'
mut log-do-hetzner      $D1 '>> "$GC_CITY/.gc/mbp-node-route.jsonl"' '>> "$GC_CITY/.gc/wa-node-route.jsonl"'
mut log-sem-aviso       $D1 '|| warn "mbp-node: linha de' '|| : "mbp-node: linha de'
mut log-muda-despacho   $D1 '|| warn "mbp-node: linha de $_id ($_mode, rc=$_rc) NÃO gravada em mbp-node-route.jsonl — a amostra do shadow fica subcontada"' '|| return 2'
mut script-do-hetzner   $D1 '"$_dir/mbp-node-dispatch.sh" apply "$_id" --store "$_store" --basis any --dry-run' '"$_dir/wa-node-dispatch.sh" apply "$_id" --store "$_store" --basis any --dry-run'
mut script-real-hetzner $D1 '"$_dir/mbp-node-dispatch.sh" apply "$_id" --store "$_store" --basis any 2>/dev/null' '"$_dir/wa-node-dispatch.sh" apply "$_id" --store "$_store" --basis any 2>/dev/null'
mut sem-orcamento       $D1 'if _pilot_slow_spawn_budget_spent; then' 'if false; then'
mut sem-13              $D1 '13|124|137|143)' '124|137|143)'
mut sem-sinal           $D1 '12[89]|1[3-9][0-9]|' '1[3-9][0-9]|'
mut sem-settle-13       $D1 '_pilot_mbp_node_settle "$_id" "$_store"; return 2 ;;' 'return 2 ;;'
mut rc-incerto-vira-1   $D1 'return 2 ;;
    # morto por qualquer' 'return 1 ;;
    # morto por qualquer'
mut open-vira-0         $D1 '_pilot_mbp_node_open "$_id" "$_store"' '_pilot_mbp_node_open "$_id" "$_store"; return 0'
mut cheio-sem-contagem  $M1 '_pilot_pool_live_count wa-worker || return 1' '_pilot_pool_live_count wa-worker || return 0'
mut cheio-teto-ilegivel $M1 "''|*[!0-9]*) return 1 ;; esac" "''|*[!0-9]*) return 0 ;; esac"
mut cheio-sem-flag      $M1 '[ "${PILOT_SPAWN_WA_WORKER:-1}" = "1" ] || return 1' ':'
mut cheio-igual-nao     $M1 '[ "$_PCAP_N" -ge "$_mf_max" ]' '[ "$_PCAP_N" -gt "$_mf_max" ]'
mut cheio-sempre        $M1 '[ "$_PCAP_N" -ge "$_mf_max" ]' ':'
mut open-sem-alias      $O1 'wa-worker-remote-mbp-[1-2]) ;;' '*) ;;'
mut open-alias-hetzner  $O1 'wa-worker-remote-mbp-[1-2]) ;;' 'wa-worker-remote-[1-9]|wa-worker-remote-mbp-[1-2]) ;;'
mut open-sem-marca      $O1 'if [ "$_PWR_STATUS" != in_progress ] || [ "$_PWR_MARK" != "$_PWR_ALIAS" ]; then' 'if false; then'
mut open-template       $O1 '_pilot_node_remote_open wa-worker-remote-mbp ' '_pilot_node_remote_open wa-worker-remote '
mut open-chave          $O1 'pilot.wa_node_alias "$(_pilot_node_idle_secs)" whatsapp_automation' 'pilot.mbp_node_alias "$(_pilot_node_idle_secs)" whatsapp_automation'
mut open-sem-rig        $O1 'pilot.wa_node_alias "$(_pilot_node_idle_secs)" whatsapp_automation || _mo_rc=$?' 'pilot.wa_node_alias "$(_pilot_node_idle_secs)" || _mo_rc=$?'
mut open-rig-do-ps      $O1 'whatsapp_automation || _mo_rc=$?' 'property_scrapers || _mo_rc=$?'
mut open-rc-engolido    $O1 'return "$_mo_rc"' 'return 0'
mut settle-sem-forma    $S1 'if [ "$_PWR_STATUS" != in_progress ] || [ "$_PWR_MARK" != "$_PWR_ALIAS" ]; then return 0; fi' ':'
mut settle-chave        $S1 '0 pilot.wa_node_alias || true' '0 pilot.mbp_node_alias || true'
mut settle-sem-alias    $S1 'case "$_PWR_ALIAS" in wa-worker-remote-mbp-[1-2]) ;; *) return 0 ;; esac' ':'
mut fia-sem-chamada     - '_pilot_mbp_node_decide "$STORY_ID" "$STORY_BEAD_CITY" "$_SLING_TARGET" || _RP_MBP_RC=$?' ':'
mut fia-sem-guarda-pass - '[ "${_PILOT_WA_NODE_PASS:-0}" != "1" ] && [ "${_PILOT_NODE_ONLY:-0}" != "1" ]; then
          local _RP_MBP_RC=0' 'true; then
          local _RP_MBP_RC=0'
mut fia-sempre-chama    - 'if [ "$_RP_NODE_RC" = 1 ] && [ "${_PILOT_WA_NODE_PASS:-0}" != "1" ]' 'if [ "${_PILOT_WA_NODE_PASS:-0}" != "1" ]'
mut fia-rc2-vira-1      - 'case "$_RP_MBP_RC" in 0) _RP_NODE_RC=0 ;; 2) _RP_NODE_RC=2 ;; esac' 'case "$_RP_MBP_RC" in 0) _RP_NODE_RC=0 ;; esac'
mut fia-rc0-vira-1      - 'case "$_RP_MBP_RC" in 0) _RP_NODE_RC=0 ;; 2) _RP_NODE_RC=2 ;; esac' 'case "$_RP_MBP_RC" in 2) _RP_NODE_RC=2 ;; esac'

echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
[ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
