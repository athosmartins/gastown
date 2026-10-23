#!/usr/bin/env bash
# pilot-dispatcher.ps-node-route.selftest.sh — testes do gancho de PS no nó Hetzner do Pilot (ga-2hd02v.4).
#
# O gancho _pilot_ps_node_decide leva uma bead de PS "código + teste, sem banco real, credencial nem rede viva" ao ps-worker-remote (nó) em vez do pool do mini. Nasce DESLIGADO
# (PILOT_PS_NODE_ROUTE=off|shadow|label|auto, padrão off). Quem classifica e escreve é scripts/ps-node-dispatch.sh (selftest próprio); a sessão do alias é aberta pelo PILOT, com as peças genéricas
# do modo pilot do WA (_pilot_node_remote_open/_rollback, provadas em pilot-dispatcher.wa-node-spawn.selftest.sh). Aqui se prova o que é do PS: a escada de modos, a leitura de três estados, o mapa de
# rc, a abertura só para a cara exata do que o apply escreve, o desfazer, a passada só-nó do disk floor e a fiação.
#
# As funções são as REAIS (extraídas palavra por palavra do pilot-dispatcher.sh); bd, gc e ps-node-dispatch.sh são falsos, o bd com estado.
#   A. modos e alvos: off e qualquer valor que não seja um dos 4 não chama nada · alvo que não é ps-worker, id que não é ps-*, script ausente → bead segue no mini.
#   B. shadow só chama `check` e nunca devolve 0 · dry-run só chama `apply --dry-run`, loga "WOULD" só para o rc 0 e nunca devolve 0.
#   C. label/auto: leitura em três estados (do nó=2, ilegível=2, lida e livre=segue) · mapa de rc do script · sessão aberta=0 · falha ao abrir=desfaz (1) ou segura (2).
#   D. rc incerto do apply (13, prazo, sinal): desfaz SÓ a cara do apply, nunca pisa em bead de outro, e devolve 2. Orçamento de spawn.
#   E. a passada só-nó do disk floor (_pilot_node_only_ps_route_on/_pre).
#   F. a fiação (grep no fonte).
#   G. mutantes: cada quebra tem de derrubar este selftest. Cada um roda o arquivo inteiro e para no 1º FAIL.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.ps-node-route.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK". Bash 3.2 (macOS) basta.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${PS_NODE_ROUTE_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
# Rodando como mutante (PS_NODE_ROUTE_SELFTEST_FILE) o primeiro FAIL já diz "morto": sai na hora.
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); [ -z "${PS_NODE_ROUTE_SELFTEST_FILE:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — obtido '$2', esperado '$3'"; fi; }   # eq <descrição> <obtido> <esperado>

[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FNS=""
for _f in _pilot_ps_node_decide _pilot_ps_node_open _pilot_ps_node_settle _pilot_node_only_ps_route_on _pilot_node_only_ps_pre _pilot_wa_node_read _pilot_node_remote_open _pilot_node_remote_rollback _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing gc_json_or_unknown; do
  _b="$(fn_of "$_f")"
  [ -n "$_b" ] || { echo "FATAL: $_f() não está em $DISPATCHER" >&2; exit 2; }
  FNS="$FNS"$'\n'"$_b"
done

T="$(mktemp -d "${TMPDIR:-/tmp}/ps-node-route.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/city" "$T/bin"
export FAKE_STATE="$T/state.json" FAKE_LOG="$T/calls" FAKE_BD_LOG="$T/bdcalls" FAKE_GC_LOG="$T/gccalls" FAKE_ORDER="$T/order" FAKE_NSHOW="$T/nshow"

# ps-node-dispatch.sh falso: anota os argumentos; no apply de verdade "escreve" (copia FAKE_BEAD2 para o estado) se FAKE_APPLY_WRITES=1, ou se vazio e o rc for 0.
cat > "$T/scripts/ps-node-dispatch.sh" <<'EOF'
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
chmod +x "$T/scripts/ps-node-dispatch.sh"

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
case "$verb" in
  list) [ "${FAKE_GC_LIST_RC:-0}" = 0 ] || exit "$FAKE_GC_LIST_RC"; printf '{"sessions":[]}'; exit 0 ;;
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

ID=ps-abc12
ST=/x/property_scrapers
# mkb <arquivo> <status> <dono> <marca> [título] [id] [rota] — a bead falsa no formato de `bd show` (o bd omite dono, marca e rota vazios)
mkb() {
  jq -n --arg id "${6:-$ID}" --arg s "$2" --arg a "$3" --arg m "$4" --arg t "${5-Título X}" --arg r "${7:-}" \
    '{id:$id,status:$s,title:$t,metadata:((if $m=="" then {} else {"pilot.wa_node_alias":$m} end) + (if $r=="" then {} else {"gc.routed_to":$r} end))} + (if $a=="" then {} else {assignee:$a} end)' > "$1"
}
mkb "$T/b.free.json" open "" ""
mkb "$T/b.ap1.json" in_progress ps-worker-remote-1 ps-worker-remote-1
mkb "$T/b.node.json" in_progress ps-worker-remote-1 ""
mkb "$T/b.routed.json" open "" "" "Título X" "$ID" ps-worker-remote
mkb "$T/b.foreign.json" in_progress mila-ps ""

reset() {
  : > "$T/calls"; : > "$T/bdcalls"; : > "$T/gccalls"; : > "$T/err"; : > "$T/order"; echo 0 > "$T/nshow"
  rm -f "$T/city/.gc/ps-node-route.jsonl"
  cp "$T/b.free.json" "$T/state.json"
  unset FAKE_BD_UPDATE_MODE FAKE_BD_SHOW_FAIL_FROM FAKE_BD_SHOW_ID FAKE_BD_SHOW_EMPTY FAKE_GC_LIST_RC FAKE_GC_NEW_RC FAKE_GC_CLOSE_RC FAKE_GC_NUDGE_RC FAKE_APPLY_WRITES FAKE_RC FAKE_OUT \
        PRE_SLOW PILOT_PS_NODE_ROUTE DRY_RUN PILOT_PS_NODE_ONLY_PROBES
  export FAKE_BEAD2="$T/b.ap1.json"
}
# H <função> <args…> — roda a função REAL (extraída) num shell novo, com os falsos no PATH; imprime só "rc=N".
H() {
  GC_CITY="$T/city" PILOT_PS_NODE_SCRIPTS="$T/scripts" \
    bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_PILOT_SLOW_SPAWN_SEEN="${PRE_SLOW:-0}"; _PNP_PROBES=0; "$@"; echo "rc=$?"' _ "$@" 2>>"$T/err" | tail -1
}
D() { export PILOT_PS_NODE_ROUTE="$1" FAKE_RC="${2:-0}" DRY_RUN="${3:-0}"; H _pilot_ps_node_decide "${ID_ARG-$ID}" "$ST" "${TGT-ps-worker}"; }   # D <modo> <rc do script> [dry]
ord()   { tr '\n' ' ' < "$T/order"; }
stt()   { jq -r '[.status, (.assignee // "-"), (.metadata["pilot.wa_node_alias"] // "-")] | join(",")' "$T/state.json"; }
ncalls() { wc -l < "$T/calls" | tr -d ' '; }
jsonl() { cat "$T/city/.gc/ps-node-route.jsonl" 2>/dev/null; }
UPD()   { printf '|-C|%s|update|%s|--if-assignee|%s|--assignee||--status|open|--unset-metadata|pilot.wa_node_alias|-q' "$ST" "$ID" "$1"; }
FREE="open,-,-"
AP1="in_progress,ps-worker-remote-1,ps-worker-remote-1"

echo "pilot-dispatcher.ps-node-route.selftest — ga-2hd02v.4"

echo; echo "=== A. modos e alvos ==="
for m in "" off OFF Auto auto\  on yes 1 shadowx; do
  reset; r=$(D "$m" 0)
  eq "modo '$m' não é um dos 4: bead segue no mini, nada chamado (script, bd, gc)" "$r $(ncalls) $(cat "$T/bdcalls" "$T/gccalls" | wc -l | tr -d ' ')" "rc=1 0 0"
done
for t in ps-worker-remote wa-worker gastown.dog mila-ps ""; do reset; r=$(TGT=$t D label 0); eq "alvo '$t' não é ps-worker: 1, nada chamado" "$r $(ncalls)" "rc=1 0"; done
for i in wa-abc12 ga-abc12 lx-abc12 ""; do reset; r=$(ID_ARG=$i D label 0); eq "id '$i' não é ps-*: 1, nada chamado" "$r $(ncalls)" "rc=1 0"; done
reset; mv "$T/scripts/ps-node-dispatch.sh" "$T/scripts/x.sh"; r=$(D label 0); mv "$T/scripts/x.sh" "$T/scripts/ps-node-dispatch.sh"
eq "ps-node-dispatch.sh ausente: 1 (a bead segue no mini)" "$r" "rc=1"; grep -q 'não está executável' "$T/err" && ok "e o aviso diz por quê" || fail "aviso: $(cat "$T/err")"

echo; echo "=== B. shadow e dry-run ==="
reset; r=$(D shadow 0)
eq "shadow nunca devolve 0 (nem com o script dizendo 0): 1" "$r" "rc=1"
eq "shadow chama só 'check <id> --store <loja>', sem ler a bead, sem escrever, sem sessão" "$(cat "$T/calls")|$(ord)" "check $ID --store $ST|script:check "
jsonl | jq -e --arg b "$ID" 'select(.event=="pilot-node-route" and .mode=="shadow" and .bead==$b and .rc==0)' >/dev/null && ok "shadow grava a linha em ps-node-route.jsonl" || fail "jsonl: $(jsonl)"
reset; r=$(D shadow 10); eq "shadow com rc 10 do script: 1 e a linha leva o rc" "$r $(jsonl | jq -r .rc)" "rc=1 10"
reset; r=$(D label 0 1)
eq "dry-run (label): chama 'apply --store … --basis label --dry-run', loga WOULD e devolve 1" "$r|$(cat "$T/calls")|$(ord)" "rc=1|apply $ID --store $ST --basis label --dry-run|bd:show script:apply "
grep -q 'WOULD route' "$T/err" && ok "dry-run rc 0: 'WOULD route'" || fail "dry-run: $(cat "$T/err")"
eq "dry-run: nada escrito, nenhuma sessão" "$(stt) $(wc -l < "$T/gccalls" | tr -d ' ')" "$FREE 0"
for c in 10 11 12 13; do reset; r=$(D auto $c 1); eq "dry-run com rc $c: 1" "$r" "rc=1"; grep -q 'would NOT go' "$T/err" && ok "dry-run rc $c: o log diz 'would NOT go', não 'WOULD route'" || fail "dry-run $c: $(cat "$T/err")"; done
reset; r=$(D shadow 0 1); eq "shadow tem precedência sobre o dry-run: só 'check'" "$r $(cat "$T/calls")" "rc=1 check $ID --store $ST"

echo; echo "=== C. label/auto: leitura de três estados, mapa de rc, sessão ==="
reset; r=$(D label 0)
eq "label, tudo certo: 0" "$r" "rc=0"
eq "ordem: lê a bead, apply, relê a bead, lista as sessões, abre, avisa" "$(ord)" "bd:show script:apply bd:show gc:list gc:new gc:nudge "
eq "apply com a base da etiqueta" "$(cat "$T/calls")" "apply $ID --store $ST --basis label"
grep -qF -- "|--city|$T/city|session|new|ps-worker-remote|--alias|ps-worker-remote-1|--no-attach|--title-hint|build $ID: Título X" "$T/gccalls" && ok "abre 'session new ps-worker-remote --alias ps-worker-remote-1 --no-attach' (template e alias do PS)" || fail "new: $(cat "$T/gccalls")"
grep -qF -- 'session|nudge|ps-worker-remote-1|Bead nova para você: ps-abc12 — Título X.' "$T/gccalls" && ok "e avisa o alias do PS" || fail "nudge: $(cat "$T/gccalls")"
eq "a bead fica como o apply a deixou" "$(stt)" "$AP1"
reset; r=$(D auto 0); eq "auto: 0, com a base 'any'" "$r $(cat "$T/calls")" "rc=0 apply $ID --store $ST --basis any"
jsonl | jq -e 'select(.mode=="auto" and .rc==0)' >/dev/null && ok "auto grava a linha com o modo e o rc" || fail "jsonl: $(jsonl)"
# três estados da leitura que vem ANTES do script
for spec in 'dono do nó|b.node.json' 'rota do nó|b.routed.json'; do
  reset; cp "$T/${spec#*|}" "$T/state.json"; r=$(D label 0)
  eq "bead que já é do nó ($(printf '%s' "${spec%%|*}")): 2, o script nem é chamado, nada escrito, nenhuma sessão" "$r $(ncalls) $(grep -c '|update|' "$T/bdcalls") $(wc -l < "$T/gccalls" | tr -d ' ')" "rc=2 0 0 0"
done
reset; r=$(FAKE_BD_SHOW_FAIL_FROM=1 D label 0); eq "bd falha ao reler: 2 (não é 'livre')" "$r $(ncalls)" "rc=2 0"
reset; r=$(FAKE_BD_SHOW_EMPTY=1 D label 0); eq "bd sai 0 sem saída: 2" "$r $(ncalls)" "rc=2 0"
reset; r=$(FAKE_BD_SHOW_ID=ps-outra D label 0); eq "bd devolve a bead de OUTRO id: 2" "$r $(ncalls)" "rc=2 0"
reset; cp "$T/b.foreign.json" "$T/state.json"; r=$(D label 12); eq "bead de outro dono que não é do nó: lida e segue; script diz 12: 1" "$r" "rc=1"
reset; r=$(D shadow 0); eq "em shadow a leitura não acontece (nada muda no despacho): nenhum bd" "$(cat "$T/bdcalls" | wc -l | tr -d ' ')" "0"
# mapa de rc do script
for c in 10 11 12 2 125 126 127 1 3; do reset; r=$(D label $c); eq "script rc $c: nada ficou escrito → 1 (segue no mini), sem sessão" "$r $(wc -l < "$T/gccalls" | tr -d ' ')" "rc=1 0"; done
for c in 13 124 137 143 129 130 139 141 255; do reset; r=$(D label $c); eq "script rc $c: pode ter escrito → 2 (segura)" "$r" "rc=2"; done
# a sessão
reset; r=$(FAKE_APPLY_WRITES=0 D label 0); eq "apply disse 0 mas a bead segue livre na releitura: 2, sem sessão, sem desfazer" "$r $(wc -l < "$T/gccalls" | tr -d ' ') $(grep -c '|update|' "$T/bdcalls")" "rc=2 0 0"
for spec in 'dono do WA|in_progress|wa-worker-remote-1|wa-worker-remote-1' 'dono de outra pessoa|in_progress|mila-ps|mila-ps' 'alias 10|in_progress|ps-worker-remote-10|ps-worker-remote-10' 'alias 0|in_progress|ps-worker-remote-0|ps-worker-remote-0' \
            'marca de outro alias|in_progress|ps-worker-remote-1|ps-worker-remote-2' 'sem marca|in_progress|ps-worker-remote-1|' 'status open|open|ps-worker-remote-1|ps-worker-remote-1'; do
  IFS='|' read -r nm st as mk <<EOF_S
$spec
EOF_S
  reset; mkb "$T/b.x.json" "$st" "$as" "$mk"; export FAKE_BEAD2="$T/b.x.json"; r=$(D label 0)
  eq "depois do apply a bead está com a cara errada ($nm): 2, sem sessão e sem desfazer" "$r $(wc -l < "$T/gccalls" | tr -d ' ') $(grep -c '|update|' "$T/bdcalls")" "rc=2 0 0"
done
reset; r=$(FAKE_BD_SHOW_FAIL_FROM=2 D label 0); eq "a releitura depois do apply falha: 2, sem sessão" "$r $(wc -l < "$T/gccalls" | tr -d ' ')" "rc=2 0"
reset; r=$(FAKE_GC_NEW_RC=1 D label 0)
eq "session new falhou: fecha a sessão, solta a bead e confirma — 1 (segue no mini)" "$r $(ord)$(stt)" "rc=1 bd:show script:apply bd:show gc:list gc:new gc:close bd:update bd:show $FREE"
grep -qxF -- "$(UPD ps-worker-remote-1)" "$T/bdcalls" && ok "o desfazer é UMA escrita guardada com a chave pilot.wa_node_alias" || fail "update: $(cat "$T/bdcalls")"
reset; r=$(FAKE_GC_LIST_RC=1 D label 0); eq "a lista de sessões não leu: não abre, desfaz sem fechar sessão — 1" "$r $(ord)$(stt)" "rc=1 bd:show script:apply bd:show gc:list bd:update bd:show $FREE"
reset; r=$(FAKE_GC_NUDGE_RC=1 D label 0); eq "o aviso falhou: desfaz — 1" "$r $(stt)" "rc=1 $FREE"
reset; r=$(FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=noop D label 0); eq "o desfazer não se confirma: 2 (segura; a bead segue do alias)" "$r $(stt)" "rc=2 $AP1"

echo; echo "=== D. rc incerto: desfaz só a cara do apply; orçamento de spawn ==="
for c in 13 124 143 130; do
  reset; r=$(FAKE_APPLY_WRITES=1 D label $c)
  eq "rc $c e a escrita pegou (cara do apply, sem sessão): desfaz e devolve 2" "$r $(stt)" "rc=2 $FREE"
done
reset; r=$(FAKE_APPLY_WRITES=0 D label 13); eq "rc 13 e a bead segue livre: não escreve nada — 2" "$r $(grep -c '|update|' "$T/bdcalls")" "rc=2 0"
reset; export FAKE_BEAD2="$T/b.foreign.json"; r=$(FAKE_APPLY_WRITES=1 D label 13); eq "rc 13 e a bead é de OUTRO dono: não toca — 2" "$r $(stt) $(grep -c '|update|' "$T/bdcalls")" "rc=2 in_progress,mila-ps,- 0"
reset; mkb "$T/b.y.json" in_progress ps-worker-remote-1 ps-worker-remote-2; export FAKE_BEAD2="$T/b.y.json"; r=$(FAKE_APPLY_WRITES=1 D label 13); eq "rc 13 e a marca é de outro alias: não toca — 2" "$r $(grep -c '|update|' "$T/bdcalls")" "rc=2 0"
reset; r=$(FAKE_APPLY_WRITES=1 FAKE_BD_SHOW_FAIL_FROM=2 D label 13); eq "rc 13 e a releitura falha: não toca — 2" "$r $(grep -c '|update|' "$T/bdcalls")" "rc=2 0"
reset; r=$(PRE_SLOW=1 D label 0); eq "sessão lenta já gastou o orçamento do sweep: nem escreve — 1" "$r $(ncalls)" "rc=1 0"
reset; r=$(PRE_SLOW=1 D shadow 0); eq "o orçamento gasto não afeta o shadow" "$r $(ncalls)" "rc=1 1"
reset; r=$(PRE_SLOW=1 D label 0 1); eq "nem o dry-run" "$r $(ncalls)" "rc=1 1"

echo; echo "=== E. a passada só-nó do disk floor ==="
RO() { PILOT_PS_NODE_ROUTE="$1" DRY_RUN="${2:-0}" H _pilot_node_only_ps_route_on; }
eq "route_on: label" "$(RO label)" "rc=0"; eq "route_on: auto" "$(RO auto)" "rc=0"
for m in "" off shadow Auto yes; do eq "route_on: '$m' não move bead" "$(RO "$m")" "rc=1"; done
eq "route_on: DRY_RUN=1 não move bead" "$(RO label 1)" "rc=1"
BP='{"id":"ps-abc12","labels":["node:ok"],"metadata":{}}'
PRE() { PILOT_PS_NODE_ROUTE="${MODE-label}" DRY_RUN="${DRY:-0}" FAKE_RC="${PRC:-0}" H _pilot_node_only_ps_pre "$1"; }
reset; eq "pre: label com node:ok e sonda rc 0: candidata" "$(PRE "$BP")" "rc=0"
eq "pre: UMA sonda 'apply --dry-run --basis label'" "$(cat "$T/calls")" "apply $ID --dry-run --basis label"
reset; eq "pre: auto não exige a etiqueta e sonda com a base any" "$(MODE=auto PRE '{"id":"ps-abc12","labels":[]}') $(cat "$T/calls")" "rc=0 apply $ID --dry-run --basis any"
reset; eq "pre: label sem node:ok: não, sem sonda" "$(PRE '{"id":"ps-abc12","labels":["x"]}') $(ncalls)" "rc=1 0"
reset; eq "pre: com dono: não, sem sonda" "$(PRE '{"id":"ps-abc12","assignee":"mila-ps","labels":["node:ok"]}') $(ncalls)" "rc=1 0"
reset; eq "pre: com rota: não, sem sonda" "$(PRE '{"id":"ps-abc12","metadata":{"gc.routed_to":"ps-worker"},"labels":["node:ok"]}') $(ncalls)" "rc=1 0"
reset; eq "pre: id de WA: não, sem sonda" "$(PRE '{"id":"wa-abc12","labels":["node:ok"]}') $(ncalls)" "rc=1 0"
reset; eq "pre: JSON ilegível: não, sem sonda" "$(PRE 'isto não é json') $(ncalls)" "rc=1 0"
reset; eq "pre: modo shadow: não, sem sonda" "$(MODE=shadow PRE "$BP") $(ncalls)" "rc=1 0"
reset; eq "pre: DRY_RUN=1: não, sem sonda" "$(DRY=1 PRE "$BP") $(ncalls)" "rc=1 0"
for c in 10 11 12 13 124; do reset; eq "pre: sonda com rc $c: não" "$(PRC=$c PRE "$BP")" "rc=1"; done
reset; mv "$T/scripts/ps-node-dispatch.sh" "$T/scripts/x.sh"; eq "pre: script ausente: não" "$(PRE "$BP")" "rc=1"; mv "$T/scripts/x.sh" "$T/scripts/ps-node-dispatch.sh"
reset; r=$(PILOT_PS_NODE_ROUTE=label PILOT_PS_NODE_ONLY_PROBES=2 FAKE_RC=0 GC_CITY="$T/city" PILOT_PS_NODE_SCRIPTS="$T/scripts" bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_PNP_PROBES=0; for k in 1 2 3 4; do _pilot_node_only_ps_pre "$1" && printf "S" || printf "N"; done; echo' _ "$BP" 2>/dev/null | tail -1)
eq "pre: o teto de sondas por varredura (2): SSNN" "$r $(ncalls)" "SSNN 2"
reset; r=$(PILOT_PS_NODE_ROUTE=label PILOT_PS_NODE_ONLY_PROBES=abc FAKE_RC=0 GC_CITY="$T/city" PILOT_PS_NODE_SCRIPTS="$T/scripts" bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_PNP_PROBES=0; for k in 1 2 3 4 5 6 7 8; do _pilot_node_only_ps_pre "$1" && printf "S" || printf "N"; done; echo' _ "$BP" 2>/dev/null | tail -1)
eq "pre: teto ilegível volta ao padrão (6)" "$r" "SSSSSSNN"

echo; echo "=== F. a fiação (grep no fonte) ==="
lnof() { grep -nF -- "$1" "$DISPATCHER" | head -n "${2:-1}" | tail -n 1 | cut -d: -f1; }
CALL='_pilot_ps_node_decide "$STORY_ID" "$STORY_BEAD_CITY" "$_SLING_TARGET" || _RP_PS_NODE_RC=$?'
eq "o gancho é chamado em UM lugar de dispatch_one" "$(grep -cF -- '_pilot_ps_node_decide "$STORY_ID"' "$DISPATCHER")" "1"
c1=$(lnof "$CALL"); w1=$(lnof '_pilot_wa_node_decide "$STORY_ID" "$STORY_BEAD_CITY" "$_SLING_TARGET"')
{ [ -n "$c1" ] && [ -n "$w1" ] && [ "$c1" -lt "$w1" ]; } && ok "a chamada do PS vem ANTES da do WA (a do WA devolve 1 para o alvo que não é wa-worker)" || fail "ordem das chamadas ($c1, $w1)"
BLK="$(awk -v a="$c1" -v b="$w1" 'NR>=a && NR<b' "$DISPATCHER")"
printf '%s' "$BLK" | grep -qF -- '_SLING_TARGET="ps-worker-remote"' && ok "rc 0: o alvo vira ps-worker-remote" || fail "rc 0 sem trocar o alvo"
printf '%s' "$BLK" | grep -F -- '= 2 ]' | grep -qF '_RP_PS_NODE_RC' && printf '%s' "$BLK" | grep -qF 'label remove "$STORY_ID" "pilot:dispatching"' && printf '%s' "$BLK" | grep -qF 'DISPATCH_RESULT="ps_node_unknown"' && ok "rc 2: solta a claim e não despacha (ps_node_unknown)" || fail "o rc 2 não solta a claim"
a1=$(lnof '      ps-worker-remote)'); a2=$(awk -v a="${a1:-0}" 'NR>a && index($0,"      ps-worker*)")==1 {print NR; exit}' "$DISPATCHER")
{ [ -n "$a1" ] && [ -n "$a2" ] && [ "$a1" -lt "$a2" ]; } && ok "o braço ps-worker-remote) do spawn vem ANTES de ps-worker*) (que o casaria)" || fail "ordem dos braços ($a1, $a2)"
ARM="$(awk -v a="$a1" -v b="$a2" 'NR>a && NR<b' "$DISPATCHER" | grep -v '^ *#')"
printf '%s' "$ARM" | grep -qE 'session new|routed_to' && fail "o braço ps-worker-remote) abre sessão ou carimba rota: $ARM" || ok "o braço ps-worker-remote) só loga (nem session new nem gc.routed_to)"
grep -qF -- 'if [ "$_RP_PS_NODE_RC" != 0 ]; then' "$DISPATCHER" && ok "o gancho do WA (e o elif só-nó dele) fica dentro de um if que a bead levada pelo PS não atravessa" || fail "falta o if em volta do gancho do WA"
grep -qF -- 'ps-*) _pilot_node_only_ps_pre "$_b" && return 0; return 1 ;; esac' "$DISPATCHER" && ok "a candidata da passada só-nó de uma bead ps-* vai para a sonda do PS" || fail "falta a linha ps-* em _pilot_node_only_candidate_pre"
grep -qF -- '"$_PYS_TARGET" = "ps-worker" ] && _pilot_node_only_ps_route_on; then' "$DISPATCHER" && ok "a passada só-nó deixa seguir a bead de ps-worker quando a rota do PS move" || fail "falta o elif ps-worker da passada só-nó"

echo; echo "=== F2. o braço do pool, EXECUTADO (a região de dispatch_one entre o gancho do PS e o fim do braço, verbatim) ==="
ARM="$(awk 'f==0 && $0 ~ /^        local _RP_PS_NODE_RC=0$/ {f=1} f==1 && $0 ~ /^        ;;$/ {exit} f==1 {print}' "$DISPATCHER")"
[ -n "$ARM" ] || fail "a região do braço do pool não foi achada em $DISPATCHER"
# armrun <rc do gancho do PS> <rc do gancho do WA> <_PILOT_NODE_ONLY> <alvo> → "rc=<rc da região> fell=<0|1> target=<alvo no fim> result=<DISPATCH_RESULT> calls=<ganchos e bd chamados>"
armrun() {
  : > "$T/armbd"
  ARMBD="$T/armbd" PSRC="$1" WARC="$2" _PILOT_NODE_ONLY="$3" _SLING_TARGET="$4" bash -c '
bd() { echo "bd $*" >> "$ARMBD"; }
_pilot_ps_node_decide() { echo ps >> "$ARMBD"; return "$PSRC"; }
_pilot_wa_node_decide() { echo wa >> "$ARMBD"; return "$WARC"; }
f() {
  local STORY_ID=ps-abc12 STORY_BEAD_CITY=/x
'"$ARM"'
  FELL=1
}
f; rc=$?; echo "rc=$rc fell=${FELL:-0} target=$_SLING_TARGET result=${DISPATCH_RESULT:-} calls=$(cut -c1-17 "$ARMBD" | tr "\n" ",")"' 2>/dev/null | tail -1
}
eq "PS levou (rc 0) na passada só-nó: o alvo vira ps-worker-remote, o gancho do WA NÃO roda, nada é solto" "$(armrun 0 1 1 ps-worker)" "rc=0 fell=1 target=ps-worker-remote result= calls=ps,"
eq "PS levou (rc 0) fora da passada só-nó: idem" "$(armrun 0 1 0 ps-worker)" "rc=0 fell=1 target=ps-worker-remote result= calls=ps,"
eq "PS não levou (rc 1) na passada só-nó: o gancho do WA devolve 1 e a claim é solta (disk_floor_node_only), sem cair no pool do mini" "$(armrun 1 1 1 ps-worker)" "rc=1 fell=0 target=ps-worker result=disk_floor_node_only calls=ps,wa,bd -C /x label re,bd -C /x update p,"
eq "PS não levou (rc 1) fora da passada só-nó: segue ao pool, o alvo não muda" "$(armrun 1 1 0 ps-worker)" "rc=0 fell=1 target=ps-worker result= calls=ps,wa,"
eq "PS inseguro (rc 2): solta a claim, ps_node_unknown, o gancho do WA nem roda" "$(armrun 2 1 0 ps-worker)" "rc=1 fell=0 target=ps-worker result=ps_node_unknown calls=ps,bd -C /x label re,bd -C /x update p,"
eq "o WA segue igual: o gancho do PS diz 1 (outro alvo), o do WA leva (rc 0): alvo wa-worker-remote" "$(armrun 1 0 0 wa-worker)" "rc=0 fell=1 target=wa-worker-remote result= calls=ps,wa,"
eq "o WA segue igual: o do WA inseguro (rc 2) solta e devolve wa_node_unknown" "$(armrun 1 2 0 wa-worker)" "rc=1 fell=0 target=wa-worker result=wa_node_unknown calls=ps,wa,bd -C /x label re,bd -C /x update p,"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
if [ -n "${PS_NODE_ROUTE_SELFTEST_FILE:-}" ]; then
  echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
  [ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
  exit 0
fi

# PS_NODE_ROUTE_ST_NOMUT=1 pula os mutantes (o prod test roda o resto contra a árvore viva; os mutantes são a bateria do gate)
if [ "${PS_NODE_ROUTE_ST_NOMUT:-}" = 1 ]; then
  echo "(mutantes pulados: PS_NODE_ROUTE_ST_NOMUT=1)"; echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
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
  if PS_NODE_ROUTE_SELFTEST_FILE="$copy" bash "$SELF" >/dev/null 2>&1; then fail "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi
}
D1=_pilot_ps_node_decide; O1=_pilot_ps_node_open; S1=_pilot_ps_node_settle
mut off-roda          $D1 'case "$_mode" in shadow|label|auto) ;; *) return 1 ;; esac' 'case "$_mode" in off|shadow|label|auto) ;; *) return 1 ;; esac'
mut sem-guarda-alvo   $D1 '[ "$_tgt" = "ps-worker" ] || return 1' ':'
mut sem-guarda-id     $D1 'case "$_id" in ps-*) ;; *) return 1 ;; esac' ':'
mut do-no-vira-1      $D1 'node) warn "ps-node: $_id já é do nó (dono ou rota ps-worker-remote*) — seguro: sem carimbo do mini e sem sessão do mini; a próxima varredura relê"; return 2 ;;' 'node) return 1 ;;'
mut ilegivel-vira-1   $D1 '*) warn "ps-node: não consegui reler $_id' '*) return 1; warn "ps-node: não consegui reler $_id'
mut sem-leitura       $D1 'if [ "$_mode" != shadow ]; then' 'if false; then'
mut shadow-devolve-0  $D1 '[ "$_mode" = shadow ] && return 1' '[ "$_mode" = shadow ] && return 0'
mut label-sem-base    $D1 '[ "$_mode" = label ] && _basis=label' ':'
mut dry-run-devolve-0 $D1 'nothing written)"; fi
    return 1' 'nothing written)"; fi
    return 0'
mut sem-orcamento     $D1 'if _pilot_slow_spawn_budget_spent; then' 'if false; then'
mut sem-13            $D1 '13|124|137|143)' '124|137|143)'
mut sem-sinal         $D1 '12[89]|1[3-9][0-9]|' '1[3-9][0-9]|'
mut sem-settle-13     $D1 '_pilot_ps_node_settle "$_id" "$_store"; return 2 ;;' 'return 2 ;;'
mut log-do-wa         $D1 'ps-node-route.jsonl' 'wa-node-route.jsonl'
mut open-vira-0       $D1 '_pilot_ps_node_open "$_id" "$_store"' '_pilot_ps_node_open "$_id" "$_store"; return 0'
mut open-sem-alias    $O1 'ps-worker-remote-[1-9]) ;;' '*) ;;'
mut open-sem-marca    $O1 'if [ "$_PWR_STATUS" != in_progress ] || [ "$_PWR_MARK" != "$_PWR_ALIAS" ]; then' 'if false; then'
mut open-template     $O1 '_pilot_node_remote_open ps-worker-remote ' '_pilot_node_remote_open wa-worker-remote '
mut open-chave        $O1 'pilot.wa_node_alias "$(_pilot_node_idle_secs)" || _po_rc=$?' 'pilot.ps_node_alias "$(_pilot_node_idle_secs)" || _po_rc=$?'
mut open-rc-engolido  $O1 'return "$_po_rc"' 'return 0'
mut settle-sem-forma  $S1 'if [ "$_PWR_STATUS" != in_progress ] || [ "$_PWR_MARK" != "$_PWR_ALIAS" ]; then return 0; fi' ':'
mut settle-chave      $S1 '0 pilot.wa_node_alias || true' '0 pilot.ps_node_alias || true'
mut route-on-shadow   _pilot_node_only_ps_route_on 'label|auto) return 0 ;;' 'shadow|label|auto) return 0 ;;'
mut route-on-dry      _pilot_node_only_ps_route_on '[ "${DRY_RUN:-0}" != "1" ] || return 1' ':'
mut pre-sem-etiqueta  _pilot_node_only_ps_pre 'any(. == "node:ok")' 'any(. == "node:ok") or true'
mut pre-sem-dono      _pilot_node_only_ps_pre 'if [ -n "$_own" ]; then return 1; fi' ':'
mut pre-sem-teto      _pilot_node_only_ps_pre '[ "$_PNP_PROBES" -lt "$_cap" ] || return 1' ':'
mut pre-sem-prefixo   _pilot_node_only_ps_pre '[ "${_id#ps-}" != "$_id" ] || return 1' ':'
mut pre-sonda-sem-dry _pilot_node_only_ps_pre ' --dry-run --basis "$_basis"' ' --basis "$_basis"'
mut fia-sem-chamada   - "$CALL" ':'
mut fia-ordem         - 'ps_node_unknown' 'ps_node_desconhecido'
mut fia-braco         - '      ps-worker-remote)' '      ps-worker-remotex)'
mut fia-embrulho      - 'if [ "$_RP_PS_NODE_RC" != 0 ]; then' 'if true; then'
mut fia-candidata     - 'ps-*) _pilot_node_only_ps_pre "$_b" && return 0; return 1 ;; esac' 'ps-*) return 1 ;; esac'

echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
[ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
