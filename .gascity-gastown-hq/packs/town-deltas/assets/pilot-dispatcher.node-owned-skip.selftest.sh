#!/usr/bin/env bash
# pilot-dispatcher.node-owned-skip.selftest.sh — ga-59z7oek
#
# Achado (07/11, gastown.dog-4, ao ligar o node-ghost-release): a bead cujo dono e um alias do no com a sessao morta
# (wa-7tufg6, P1, dono wa-worker-remote-2, sessao fechada as 22:09Z) levava uma claim do Pilot a cada ~20-30 min e o job
# nunca a devolvia. O filtro de candidatas (ga-46wq5) readmite bead de dono inativo, o dispatch_one a claima (bd update
# pilot.dispatching_at: move o updated_at), o gate-f (ga-jzye0) deixa passar ("dono inativo") e SO O GANCHO DO NO,
# depois de tudo isso, rele a bead, ve que ja e do no e devolve 2; a claim e solta com OUTRO bd update. Quatro escritas por
# varredura (dois bd update + dois de rotulo): o updated_at nunca envelhece e o node-ghost-release (que exige ~30 min sem toque) fica cego.
#
# Correcao sob teste (pilot-dispatcher.sh): dispatch_lane pula ANTES da claim, sem escrever nada, a candidata que JA e do
# no (dono ou rota wa-/ps-worker-remote*) quando o gancho da familia dela esta ligado (label|auto): _pilot_node_owned_pre.
# E a mesma pergunta que _pilot_wa_node_decide / _pilot_ps_node_decide fazem depois da claim, feita sobre o JSON da
# candidata. O gancho continua la como segunda linha (releitura fresca, tres estados).
#
#   A. _pilot_node_owned_pre (funcao REAL extraida): o veredito por familia, modo, dono/rota e id; o que NAO pula (dono
#      que nao e do no, familia desligada ou em shadow, id de outro store); o terceiro estado (JSON ilegivel) nunca pula.
#   B. dispatch_lane (REAL, dispatch_one simulado como o de verdade se comporta com o no ligado: claim + soltura + 2):
#      a candidata do no nao chega ao dispatch_one (zero escrita, zero chamada ao bd/gc), a de tras segue no mesmo laco, a
#      pulada nao e falha nem consome vaga; os controles (no desligado, dono que nao e do no) seguem como antes.
#   C. a nota "node_owned_skip" cai em refused_by_guard no _pilot_sweep_emit REAL; wa_node_unknown segue failed_other.
#   D. a fiacao (grep no fonte): o pulo fica em dispatch_lane, depois do pulo so-no e antes da claim; a claim mora no
#      dispatch_one; o bloco do pulo nao escreve; os tres ganchos continuam como segunda linha.
#   E. mutantes: cada quebra, numa copia do dispatcher, tem de derrubar este arquivo (mais o controle de identidade).
#
# Cada assercao comportamental foi escrita para REPROVAR contra o dispatcher de antes (rode com PILOT_DISPATCHER_PATH
# apontando para uma copia sem a correcao: o dispatch_one e alcancado para a bead do no). Os controles so guardam contra
# o excesso: familia desligada ou dono que nao e do no tem de seguir exatamente como antes.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.node-owned-skip.selftest.sh
# Exit 0 iff tudo passa. Bash 3.2 (macOS) basta.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
# ga-ck3sz7: os cenarios rodam num PATH SEM gc/bd de verdade; os falsos de $WORK/bin sao os unicos que eles acham.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# fn_src <nome> — o fonte da funcao palavra por palavra, ou nada se o arquivo nao a define.
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
LANE_FN="$(fn_src dispatch_lane)"
NOTE_FN="$(fn_src _pilot_sweep_note)"
EMIT_FN="$(fn_src _pilot_sweep_emit)"
PRE_FN="$(fn_src _pilot_node_owned_pre)"
CAPQ_FN="$(fn_src _pilot_note_pool_cap_queued)"
# o predicado de saturacao do fim da varredura (o que separa "saturado" de "estagnado"): trecho marcado SELFTEST-EXTRACT, usado tambem pelo selftest do kimi-lane
SAT_BLOCK="$(sed -n '/# SELFTEST-EXTRACT pilot-saturation-predicate: BEGIN/,/# SELFTEST-EXTRACT pilot-saturation-predicate: END/p' "$DISPATCHER")"
[ -n "$LANE_FN" ] || { echo "FATAL: dispatch_lane() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$NOTE_FN" ] || { echo "FATAL: _pilot_sweep_note() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$EMIT_FN" ] || { echo "FATAL: _pilot_sweep_emit() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$CAPQ_FN" ] || { echo "FATAL: _pilot_note_pool_cap_queued() not found in $DISPATCHER" >&2; exit 2; }
[ -n "$SAT_BLOCK" ] || { echo "FATAL: o trecho SELFTEST-EXTRACT pilot-saturation-predicate nao esta em $DISPATCHER" >&2; exit 2; }
# a funcao nova pode faltar (dispatcher de antes da correcao): isso reprova a Parte A, nunca derruba a B (que mostra o motivo de verdade)
FUNCS="$LANE_FN
$NOTE_FN
$CAPQ_FN
$PRE_FN"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-node-owned-skip-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# bd e gc falsos: qualquer chamada fica anotada em town.calls (o pulo tem de deixar o arquivo VAZIO)
cat > "$WORK/bin/bd" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${SELFTEST_WORK:?}/town.calls"
exit 0
STUBEOF
chmod +x "$WORK/bin/bd"
cp "$WORK/bin/bd" "$WORK/bin/gc"
sandbox_path_init "$WORK" jq || exit 2

# bead <id> [dono] [rota] — uma candidata como o `bd list --json` a entrega (o bd omite a chave vazia)
bead() {
  local _j='{"id":"'"$1"'","priority":1,"issue_type":"bug","status":"in_progress","labels":["story:approved"]'
  [ -z "${2:-}" ] || _j="$_j"',"assignee":"'"$2"'"'
  if [ -n "${3:-}" ]; then _j="$_j"',"metadata":{"gc.routed_to":"'"$3"'"}'; else _j="$_j"',"metadata":{}'; fi
  printf '%s}' "$_j"
}
pool_of() { local _o="" _c; for _c in "$@"; do _o="$_o${_o:+,}$_c"; done; printf '[%s]' "$_o"; }

echo "pilot-dispatcher.node-owned-skip.selftest — a bead que ja e do no nao e claimada (ga-59z7oek)"

# ── A: o veredito ────────────────────────────────────────────────────────────────────────────────────────────────────
echo "=== A: _pilot_node_owned_pre — o veredito sobre o JSON da candidata ==="
# pre_rc <rota-WA> <rota-PS> <DRY_RUN> <json> — imprime o rc ("-" = variavel ausente)
pre_rc() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    if [ "$1" = "-" ]; then unset PILOT_WA_NODE_ROUTE; else PILOT_WA_NODE_ROUTE="$1"; fi
    if [ "$2" = "-" ]; then unset PILOT_PS_NODE_ROUTE; else PILOT_PS_NODE_ROUTE="$2"; fi
    DRY_RUN="$3"
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warn.txt"; }
    eval "$PRE_FN"
    _rc=0; _pilot_node_owned_pre "$4" || _rc=$?
    printf '%s' "$_rc"
  )
}
# want <descricao> <rc esperado> <rota-WA> <rota-PS> <DRY_RUN> <json>
want() {
  local _got; _got="$(pre_rc "$3" "$4" "$5" "$6")"
  if [ "$_got" = "$2" ]; then ok "$1 (rc=$_got)"; else bad "$1 — rc=$_got, esperado $2"; fi
}
if [ -z "$PRE_FN" ]; then
  bad "A0: _pilot_node_owned_pre() nao existe em $DISPATCHER (dispatcher de antes da correcao?)"
else
  echo "-- WA: o que PULA (dono ou rota wa-worker-remote*, rota label|auto)"
  want "A1: dono wa-worker-remote-2, rota auto" 0 auto - 0 "$(bead wa-a wa-worker-remote-2)"
  want "A1: dono wa-worker-remote-2, rota label" 0 label - 0 "$(bead wa-a wa-worker-remote-2)"
  want "A1: dono do MBP (wa-worker-remote-mbp-1): o mesmo prefixo que o gancho usa" 0 auto - 0 "$(bead wa-a wa-worker-remote-mbp-1)"
  want "A1: so a ROTA wa-worker-remote (sem dono)" 0 auto - 0 "$(bead wa-a '' wa-worker-remote)"
  want "A1: dono do no + carimbo wa-worker de uma tentativa antiga: o dono manda" 0 auto - 0 "$(bead wa-a wa-worker-remote-2 wa-worker)"
  want "A1: a mesma verdade em DRY_RUN=1 (o gancho tambem segura em DRY_RUN)" 0 auto - 1 "$(bead wa-a wa-worker-remote-2)"
  echo "-- WA: o que NAO pula (segue como sempre)"
  want "A2: dono que e crew nomeada (mila-wa): readmissao do gate-f intacta" 1 auto auto 0 "$(bead wa-a mila-wa)"
  want "A2: dono que e slot do pool do mini (wa-worker-3, morto): readmissao intacta" 1 auto auto 0 "$(bead wa-a wa-worker-3)"
  want "A2: dono dog-remote-1 (alias do nó-primeiro de dog, nao e familia WA)" 1 auto auto 0 "$(bead wa-a dog-remote-1)"
  want "A2: so a rota wa-worker (carimbo do pool do mini)" 1 auto auto 0 "$(bead wa-a '' wa-worker)"
  want "A2: bead livre (sem dono e sem rota: o estado de primeira vista)" 1 auto auto 0 "$(bead wa-a)"
  want "A2: prefixo no MEIO do dono nao e dono do no (startswith, nao contains)" 1 auto auto 0 "$(bead wa-a xwa-worker-remote-1)"
  want "A2: maiuscula nao casa (o gancho tambem e sensivel a caixa)" 1 auto auto 0 "$(bead wa-a WA-WORKER-REMOTE-1)"
  echo "-- WA: o botao (so label|auto liga; o resto e como o gancho: desligado)"
  for _m in shadow off on AUTO lixo ""; do
    want "A3: PILOT_WA_NODE_ROUTE='$_m' NAO pula" 1 "$_m" auto 0 "$(bead wa-a wa-worker-remote-2)"
  done
  want "A3: PILOT_WA_NODE_ROUTE ausente NAO pula" 1 - auto 0 "$(bead wa-a wa-worker-remote-2)"
  echo "-- PS: a familia irma, com o botao e o prefixo proprios"
  want "A4: ps-*, dono ps-worker-remote-3, PS auto" 0 - auto 0 "$(bead ps-a ps-worker-remote-3)"
  want "A4: ps-*, dono ps-worker-remote-3, PS label" 0 - label 0 "$(bead ps-a ps-worker-remote-3)"
  want "A4: ps-*, so a rota ps-worker-remote" 0 - auto 0 "$(bead ps-a '' ps-worker-remote)"
  want "A4: ps-*, PS shadow NAO pula" 1 auto shadow 0 "$(bead ps-a ps-worker-remote-3)"
  want "A4: ps-*, PS ausente NAO pula" 1 auto - 0 "$(bead ps-a ps-worker-remote-3)"
  want "A4: ps-* com dono que nao e do no (batista-ps): segue" 1 auto auto 0 "$(bead ps-a batista-ps)"
  echo "-- os dois botoes sao independentes e cada familia so conhece o prefixo dela"
  want "A5: WA ligado, PS desligado: a bead de PS do no NAO pula" 1 auto off 0 "$(bead ps-a ps-worker-remote-3)"
  want "A5: PS ligado, WA desligado: a bead de WA do no NAO pula" 1 off auto 0 "$(bead wa-a wa-worker-remote-2)"
  want "A5: bead de WA com dono de PS-no (familia trocada) NAO pula" 1 auto auto 0 "$(bead wa-a ps-worker-remote-1)"
  want "A5: bead de PS com dono de WA-no (familia trocada) NAO pula" 1 auto auto 0 "$(bead ps-a wa-worker-remote-1)"
  echo "-- id de outro store: nao ha gancho do no para ele"
  want "A6: ga-* com dono wa-worker-remote-2 NAO pula" 1 auto auto 0 "$(bead ga-a wa-worker-remote-2)"
  want "A6: lx-* NAO pula" 1 auto auto 0 "$(bead lx-a wa-worker-remote-2)"
  echo "-- terceiro estado: JSON que nao se le NUNCA pula (rc 2 + aviso; o gancho do no rele a bead depois da claim)"
  for _j in 'isto não é json' '[1,2]' '"texto"' '5' '{"id":"wa-u","assignee":7}' '{"id":"wa-u","metadata":"texto"}' '{"id":"wa-u","metadata":{"gc.routed_to":5}}'; do
    rm -f "$WORK/warn.txt"
    want "A7: ilegivel $_j" 2 auto auto 0 "$_j"
    [ -s "$WORK/warn.txt" ] && ok "A7: ... e o aviso ga-59z7oek ficou escrito" || bad "A7: ilegivel $_j nao deixou aviso (erro mudo = o mesmo que vazio)"
  done
  echo "-- vazio e o estado normal, nao erro: sem aviso"
  for _j in '{}' 'null'; do
    rm -f "$WORK/warn.txt"
    want "A8: vazio $_j" 1 auto auto 0 "$_j"
    [ ! -s "$WORK/warn.txt" ] && ok "A8: ... sem aviso" || bad "A8: vazio $_j gerou aviso (vazio nao e erro)"
  done
  echo "-- os dois botoes desligados: volta antes de ler qualquer coisa (custo zero no padrao)"
  rm -f "$WORK/warn.txt"
  want "A9: ambos off + JSON ilegivel: rc 1 (nem chega a ler)" 1 off off 0 'isto não é json'
  [ ! -s "$WORK/warn.txt" ] && ok "A9: ... e nenhum aviso" || bad "A9: leu o JSON com os dois botoes desligados"
fi

# ── B: o laco ────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "=== B: dispatch_lane REAL — a candidata do no nao chega ao dispatch_one ==="
# run_lane <rota-WA> <rota-PS> <DRY_RUN> <pool-json> [vagas] — uma pista de uma varredura num shell so, sob o `set -euo pipefail` do dispatcher.
# dispatch_one e simulado COMO O DE VERDADE se comporta com o gancho do no ligado para a bead que ja e do no: claim (bd update + label),
# gancho rele, "ja e do no" (rc 2), solta a claim (label + bd update) e devolve 1 com wa_node_unknown. Com o gancho desligado a bead de dono
# morto segue o caminho do pool do mini (gate-f) e despacha (rc 0). O pulo, se existir, acontece ANTES de qualquer um dos dois.
run_lane() {
  rm -f "$WORK"/town.calls "$WORK"/attempts "$WORK"/log.txt "$WORK"/state.txt "$WORK"/bd.writes
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    if [ "$1" = "-" ]; then unset PILOT_WA_NODE_ROUTE; else PILOT_WA_NODE_ROUTE="$1"; fi
    if [ "$2" = "-" ]; then unset PILOT_PS_NODE_ROUTE; else PILOT_PS_NODE_ROUTE="$2"; fi
    GC_CITY="test-city"; DRY_RUN="$3"
    DISPATCH_TO_CAPACITY=1; PILOT_DOLT_SATURATED_AT_START=0
    POOL_CAP_QUEUED=0; POOL_CAP_QUEUED_IDS=""; NONQUEUE_FAILS=0; DISPATCHED=0; PRIORITY_YIELDED=0
    SWEEP_OUTCOMES=""; DISPATCH_RESULT=""; _PCAP_COUNT_UNREADABLE=""; _PCAP_CALL_QUEUED=0; _PILOT_WA_MBP_PASS=0; _PMN_APPLY_RC=""
    _PCAP_POOL=wa-worker; _PCAP_LIVE=4; _PCAP_MAX=4; KIMI_LANE_WAITING=0
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    # o que dispatch_lane() chama e este teste nao e sobre (CAP_FULL_ID: a bead cujo pool "esta no teto", para o B8)
    _top_candidate() { printf '%s' "$1" | jq -c '.[0]'; }
    _bead_tier() { echo tier1; }
    _pilot_dispatch_should_stop() { return 1; }
    _pilot_priority_pool_bound_pre() { return 1; }
    _pilot_priority_waiter_note() { return 0; }
    _pilot_pool_cap_full_for() { [ -n "${CAP_FULL_ID:-}" ] && [ "$(printf '%s' "$1" | jq -r '.id')" = "$CAP_FULL_ID" ]; }
    _pilot_slow_spawn_deferred_for() { return 1; }
    _dolt_saturated() { return 1; }
    dispatch_one() {
      DISPATCH_RESULT=""
      local _i _n _on=0
      _i=$(printf '%s' "$1" | jq -r '.id')
      printf '%s\n' "$_i" >> "$WORK/attempts"
      _n=$(printf '%s' "$1" | jq -r '(((.assignee // "") | startswith("wa-worker-remote")) or ((.metadata["gc.routed_to"] // "") | startswith("wa-worker-remote"))) as $w | (((.assignee // "") | startswith("ps-worker-remote")) or ((.metadata["gc.routed_to"] // "") | startswith("ps-worker-remote"))) as $p | if (($w and (.id | startswith("wa-"))) or ($p and (.id | startswith("ps-")))) then "node" else "other" end')
      case "$_i" in
        (wa-*) case "${PILOT_WA_NODE_ROUTE:-}" in (label|auto) _on=1 ;; esac ;;
        (ps-*) case "${PILOT_PS_NODE_ROUTE:-}" in (label|auto) _on=1 ;; esac ;;
      esac
      if [ "$_n" = node ] && [ "$_on" = 1 ]; then
        printf 'claim+release %s\n' "$_i" >> "$WORK/bd.writes"
        DISPATCH_RESULT="wa_node_unknown"
        return 1
      fi
      DISPATCH_RESULT="rig_native_ok"
      return 0
    }
    eval "$FUNCS"
    dispatch_lane small "$4" "${5:-5}"
    _pool_saturated_sweep=0
    eval "$SAT_BLOCK"
    {
      echo "DISP=$DISPATCHED"
      echo "NQ=$NONQUEUE_FAILS"
      echo "CAPQ=$POOL_CAP_QUEUED"
      echo "SAT=$_pool_saturated_sweep"
      echo "YIELD=$PRIORITY_YIELDED"
      printf 'OUTCOMES=%s\n' "$(printf '%s' "$SWEEP_OUTCOMES" | tr '\n\t' ';,')"
    } > "$WORK/state.txt"
  ) || echo "  (run_lane: o subshell saiu com erro — o laco abortou sob set -e?)" >&2
}
state_get() { sed -n "s/^$1=//p" "$WORK/state.txt" 2>/dev/null | head -1; }
attempted() { [ -f "$WORK/attempts" ] && tr '\n' ',' < "$WORK/attempts" | sed 's/,$//' || true; }
writes() { [ -f "$WORK/bd.writes" ] && wc -l < "$WORK/bd.writes" | tr -d ' ' || echo 0; }
town_calls() { [ -f "$WORK/town.calls" ] && wc -l < "$WORK/town.calls" | tr -d ' ' || echo 0; }
log_count() { local _c; _c=$(grep -cF -- "$1" "$WORK/log.txt" 2>/dev/null) || _c=0; printf '%s' "${_c:-0}"; }
GHOST="$(bead wa-ghost wa-worker-remote-2)"
FREE="$(bead wa-free)"

echo "B1: WA auto — [bead do no, bead livre], 1 vaga: so a livre chega ao dispatch_one, a do no nao consome a vaga"
run_lane auto - 0 "$(pool_of "$GHOST" "$FREE")" 1
[ "$(attempted)" = "wa-free" ] && ok "B1: dispatch_one alcancado SO para wa-free" || bad "B1: dispatch_one alcancado para '$(attempted)' — a bead do no foi claimada (claim + soltura = quatro escritas por varredura, dois bd update)"
[ "$(writes)" = "0" ] && ok "B1: zero escritas (nenhuma claim, nenhuma soltura)" || bad "B1: $(writes) escrita(s) de claim/soltura na bead do no"
[ "$(town_calls)" = "0" ] && ok "B1: o laco nao chamou bd nem gc" || bad "B1: o laco chamou bd/gc $(town_calls) vez(es)"
[ "$(state_get OUTCOMES)" = "wa-ghost,1,node_owned_skip;wa-free,0,rig_native_ok;" ] && ok "B1: a pulada e a despachada estao na conta da varredura (node_owned_skip / rig_native_ok)" || bad "B1: outcomes='$(state_get OUTCOMES)'"
[ "$(state_get DISP)" = "1" ] && [ "$(state_get NQ)" = "0" ] && ok "B1: despachou 1 e a pulada NAO soma em NONQUEUE_FAILS (nao e falha, nao mascara saturacao)" || bad "B1: DISP=$(state_get DISP) NQ=$(state_get NQ)"
[ "$(log_count 'ga-59z7oek')" = "1" ] && [ "$(log_count 'wa-ghost')" -ge 1 ] && ok "B1: UMA linha de log nomeia a bead pulada" || bad "B1: linhas ga-59z7oek no log: $(log_count 'ga-59z7oek')"
[ "$(log_count 'iteration guard')" = "0" ] && ok "B1: a guarda de iteracao nao disparou" || bad "B1: a guarda de iteracao disparou (o laco girou a toa)"

echo "B2: WA auto — so beads do no: nenhuma vai ao dispatch_one, o laco termina limpo"
run_lane auto - 0 "$(pool_of "$(bead wa-g1 wa-worker-remote-1)" "$(bead wa-g2 wa-worker-remote-2)" "$(bead wa-g3 wa-worker-remote-mbp-1)")" 5
[ -z "$(attempted)" ] && [ "$(writes)" = "0" ] && [ "$(town_calls)" = "0" ] && ok "B2: nenhuma chegou ao dispatch_one, zero escritas, zero bd/gc" || bad "B2: dispatch_one alcancado para '$(attempted)', escritas=$(writes), bd/gc=$(town_calls)"
[ "$(state_get OUTCOMES)" = "wa-g1,1,node_owned_skip;wa-g2,1,node_owned_skip;wa-g3,1,node_owned_skip;" ] && ok "B2: as tres estao na conta como node_owned_skip, na ordem" || bad "B2: outcomes='$(state_get OUTCOMES)'"
[ "$(state_get DISP)" = "0" ] && [ "$(state_get NQ)" = "0" ] && [ "$(log_count 'iteration guard')" = "0" ] && ok "B2: DISP=0, NQ=0 e sem guarda de iteracao (a pista se esgotou)" || bad "B2: DISP=$(state_get DISP) NQ=$(state_get NQ) guarda=$(log_count 'iteration guard')"

echo "B3: CONTROLE — gancho do WA desligado/shadow: a bead de dono morto segue o caminho de sempre (readmissao do gate-f)"
for _m in - off shadow; do
  run_lane "$_m" - 0 "$(pool_of "$GHOST" "$FREE")" 5
  [ "$(attempted)" = "wa-ghost,wa-free" ] && [ "$(state_get OUTCOMES)" = "wa-ghost,0,rig_native_ok;wa-free,0,rig_native_ok;" ] && [ "$(state_get DISP)" = "2" ] \
    && ok "B3: PILOT_WA_NODE_ROUTE='$_m': as duas vao ao dispatch_one e despacham (nada pulado)" \
    || bad "B3: PILOT_WA_NODE_ROUTE='$_m': attempted='$(attempted)' outcomes='$(state_get OUTCOMES)'"
  [ "$(log_count 'ga-59z7oek')" = "0" ] && ok "B3: ... e nenhuma linha do pulo" || bad "B3: PILOT_WA_NODE_ROUTE='$_m' registrou um pulo"
done

echo "B4: CONTROLE — dono que NAO e do no segue ao dispatch_one mesmo com o gancho ligado"
run_lane auto auto 0 "$(pool_of "$(bead wa-crew mila-wa)" "$(bead wa-slot wa-worker-3)" "$(bead wa-dog dog-remote-1)" "$FREE")" 5
[ "$(attempted)" = "wa-crew,wa-slot,wa-dog,wa-free" ] && [ "$(state_get DISP)" = "4" ] && [ "$(state_get NQ)" = "0" ] \
  && ok "B4: crew nomeada, slot do pool, dog-remote e livre: todas ao dispatch_one (a readmissao do gate-f nao mudou)" \
  || bad "B4: attempted='$(attempted)' DISP=$(state_get DISP) outcomes='$(state_get OUTCOMES)'"

echo "B5: PS auto, WA desligado — os botoes sao independentes"
run_lane - auto 0 "$(pool_of "$(bead ps-ghost ps-worker-remote-1)" "$GHOST" "$(bead ps-free)")" 5
[ "$(attempted)" = "wa-ghost,ps-free" ] && [ "$(state_get OUTCOMES)" = "ps-ghost,1,node_owned_skip;wa-ghost,0,rig_native_ok;ps-free,0,rig_native_ok;" ] \
  && ok "B5: a bead de PS do no e pulada; a de WA (gancho desligado) e a livre seguem" \
  || bad "B5: attempted='$(attempted)' outcomes='$(state_get OUTCOMES)'"
[ "$(writes)" = "0" ] && ok "B5: zero escritas" || bad "B5: $(writes) escrita(s)"

echo "B6: DRY_RUN=1 — o pulo vale igual (o gancho tambem segura em DRY_RUN)"
run_lane auto - 1 "$(pool_of "$GHOST" "$FREE")" 5
[ "$(attempted)" = "wa-free" ] && [ "$(state_get OUTCOMES)" = "wa-ghost,1,node_owned_skip;wa-free,0,rig_native_ok;" ] && ok "B6: wa-ghost pulada em DRY_RUN" || bad "B6: attempted='$(attempted)' outcomes='$(state_get OUTCOMES)'"

echo "B7: so a ROTA do no (sem dono) tambem e do no"
run_lane auto - 0 "$(pool_of "$(bead wa-rt '' wa-worker-remote)" "$FREE")" 5
[ "$(attempted)" = "wa-free" ] && [ "$(state_get OUTCOMES)" = "wa-rt,1,node_owned_skip;wa-free,0,rig_native_ok;" ] && ok "B7: wa-rt (so rota wa-worker-remote) pulada" || bad "B7: attempted='$(attempted)' outcomes='$(state_get OUTCOMES)'"

echo "B8: a razao de a pulada nao somar em NONQUEUE_FAILS — sweep com [bead do no, bead enfileirada no teto do pool] e SATURADO (backpressure), nao 'estagnado'"
CAP_FULL_ID=wa-queued run_lane auto - 0 "$(pool_of "$GHOST" "$(bead wa-queued)")" 5
[ "$(state_get OUTCOMES)" = "wa-ghost,1,node_owned_skip;wa-queued,1,rig_native_pool_session_cap_queued;" ] && [ "$(state_get CAPQ)" = "1" ] && [ "$(state_get DISP)" = "0" ] \
  && ok "B8: a do no foi pulada e a outra ficou na fila do teto (CAPQ=1, nada despachado)" \
  || bad "B8: outcomes='$(state_get OUTCOMES)' CAPQ=$(state_get CAPQ) DISP=$(state_get DISP)"
[ "$(state_get NQ)" = "0" ] && [ "$(state_get SAT)" = "1" ] \
  && ok "B8: o predicado de saturacao REAL diz saturado (NQ=0, SAT=1): a bead deixada em paz por desenho nao fabrica 'Pilot estagnado'" \
  || bad "B8: NQ=$(state_get NQ) SAT=$(state_get SAT) — a bead do no virou falha e mascarou a saturacao (o streak do Step 5 contaria o sweep como parado)"

# ── C: a classificacao ────────────────────────────────────────────────────────────────────────────────────────────────
echo "=== C: _pilot_sweep_emit REAL — node_owned_skip e beneigna; wa_node_unknown segue visivel ==="
# emit_for <notas> — uma varredura sob semantica de producao (/bin/bash, set -euo pipefail); imprime a linha jsonl emitida. Uma nota por linha: "<id> <rc> [<resultado>]".
emit_for() {
  : > "$WORK/pilot.jsonl"
  PATH="$SANDBOX_PATH" /bin/bash -c '
set -euo pipefail
PILOT_LOG="$1"; DRY_RUN=0; _pool_saturated_sweep=0; SMALL_SLOTS=5; BIG_SLOTS=2
SWEEP_OUTCOMES=""
warn() { echo "WARN: $*" >&2; }
'"$NOTE_FN"'
'"$EMIT_FN"'
while IFS=" " read -r _id _rc _res; do
  [ -z "$_id" ] && continue
  _pilot_sweep_note "$_id" "$_rc" "${_res:-}"
done <<< "$2"
_pilot_sweep_emit
' _ "$WORK/pilot.jsonl" "$1" >/dev/null 2>&1
  cat "$WORK/pilot.jsonl"
}
emit_has() { local _g; _g="$(printf '%s' "$EMITTED" | jq -rc "$1" 2>/dev/null)"; if [ "$_g" = "$2" ]; then ok "$3"; else bad "$3 — esperado '$2', obtido '$_g'"; fi; }
EMITTED="$(emit_for "wa-ghost 1 node_owned_skip
wa-unk 1 wa_node_unknown
wa-ok 0 rig_native_ok")"
emit_has '.candidates' 3 "C1: as tres entram em candidates"
emit_has '.refused_by_guard.node_owned_skip' 1 "C1: node_owned_skip cai em refused_by_guard (guarda que segurou de proposito, nao falha do Pilot)"
emit_has '.failed_other' 1 "C1: so wa_node_unknown (o gancho do no segurando DEPOIS da claim) segue failed_other"
emit_has '.refused_by_guard | has("wa_node_unknown")' false "C1: wa_node_unknown NAO foi escondido na lista benigna"
emit_has '.dispatched' 1 "C1: a despachada continua dispatched"
emit_has '.results.node_owned_skip' 1 "C1: o nome aparece em results (a deriva de vocabulario se explica sozinha)"

# ── D: a fiacao ───────────────────────────────────────────────────────────────────────────────────────────────────────
echo "=== D: a fiacao no fonte ==="
L_LANE=$(grep -n '^dispatch_lane() {' "$DISPATCHER" | head -1 | cut -d: -f1)
L_NODEONLY=$(grep -n '_PILOT_NODE_ONLY:-0}" = "1" \] && ! _pilot_node_only_candidate_pre "\$pick"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_OWNED=$(grep -n '    if _pilot_node_owned_pre "\$pick"; then' "$DISPATCHER" | head -1 | cut -d: -f1)
L_MBP=$(grep -n '    local _mbp_pass=0' "$DISPATCHER" | head -1 | cut -d: -f1)
L_ONE=$(grep -n '    if dispatch_one "\$pick" "\$lane" "\$pick_tier"; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_LANE" ] && [ -n "$L_NODEONLY" ] && [ -n "$L_OWNED" ] && [ -n "$L_MBP" ] && [ -n "$L_ONE" ] \
   && [ "$L_LANE" -lt "$L_NODEONLY" ] && [ "$L_NODEONLY" -lt "$L_OWNED" ] && [ "$L_OWNED" -lt "$L_MBP" ] && [ "$L_MBP" -lt "$L_ONE" ]; then
  ok "D1: dispatch_lane (L$L_LANE): pulo so-no (L$L_NODEONLY) → pulo do no (L$L_OWNED) → passo do MBP (L$L_MBP) → dispatch_one (L$L_ONE): sem claim, sem escrita"
else
  bad "D1: o pulo do no nao esta em dispatch_lane entre o pulo so-no e o passo do MBP, antes do dispatch_one (lane=$L_LANE so-no=$L_NODEONLY no=$L_OWNED mbp=$L_MBP one=$L_ONE)"
fi
ONE_FN="$(fn_src dispatch_one)"
if grep -q 'pilot.dispatching_at=\$CLAIM_EPOCH' <<< "$ONE_FN" && ! grep -q 'pilot.dispatching_at' <<< "$LANE_FN"; then
  ok "D2: a claim (bd update pilot.dispatching_at) mora no dispatch_one e nao no laco: nao entrar no dispatch_one = nao claimar"
else
  bad "D2: a claim nao esta so no dispatch_one (o argumento 'pulou = zero escrita' deixou de valer)"
fi
BLK="$(awk '/_pilot_node_owned_pre "\$pick"/{f=1} f{print} f&&/^    fi$/{exit}' <<< "$LANE_FN")"
if [ -n "$BLK" ] && grep -q 'node_owned_skip' <<< "$BLK" && grep -q 'continue' <<< "$BLK" && ! grep -qE '(^|[[:space:];|&(])(bd|gc)[[:space:]]' <<< "$BLK"; then
  ok "D3: o bloco do pulo anota e continua, e nao chama bd nem gc"
else
  bad "D3: o bloco do pulo nao e 'anota + continue' sem bd/gc: $BLK"
fi
n_hooks=0
grep -qF 'já é do nó (dono ou rota wa-worker-remote*)' "$DISPATCHER" && n_hooks=$((n_hooks+1))
grep -qF 'já é do nó (dono ou rota ps-worker-remote*)' "$DISPATCHER" && n_hooks=$((n_hooks+1))
[ "$n_hooks" = 2 ] && ok "D4: os ganchos do WA e do PS continuam com a segunda linha (releitura fresca depois da claim)" || bad "D4: um gancho perdeu o 'ja e do no' (achei $n_hooks de 2)"

# ── E: mutantes ───────────────────────────────────────────────────────────────────────────────────────────────────────
if [ -z "${NOS_MUTANT:-}" ]; then
  echo "=== E: controle negativo — cada quebra, numa copia do dispatcher, tem de reprovar este arquivo ==="
  nm=0
  # mutant <nome> <ancora> <troca> — a ancora tem de casar EXATAMENTE 1 vez; o 1o ✗ impresso e o motivo da morte (conferido a olho na entrega, nao so "morto")
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh" out r
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a ancora nao casa exatamente 1 vez"; return; }
    out=$(NOS_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$SELF" 2>&1); r=$(printf '%s\n' "$out" | tail -1)
    case "$r" in
      "RESULT 0/"*) bad "mutante '$1' SOBREVIVEU ($r)" ;;
      "RESULT "*) ok "mutante '$1' morto ($r; 1o ✗: $(printf '%s\n' "$out" | grep -m1 '✗' | cut -c1-100))" ;;
      *) bad "mutante '$1': sem resultado ($r)" ;;
    esac
  }
  # as ancoras sao ASCII de proposito (o python3 le o argv no locale do shell e o arquivo em UTF-8)
  mutant "o laco nao pergunta ao helper" '    if _pilot_node_owned_pre "$pick"; then' '    if false; then'
  mutant "o pulo nao continua (cai no dispatch_one)" $'      _pilot_sweep_note "$pick_id" 1 "node_owned_skip"\n      continue' $'      _pilot_sweep_note "$pick_id" 1 "node_owned_skip"\n      :'
  mutant "o pulo nao anota a bead" $'      _pilot_sweep_note "$pick_id" 1 "node_owned_skip"\n' ''
  mutant "o pulo anota com outro nome" '_pilot_sweep_note "$pick_id" 1 "node_owned_skip"' '_pilot_sweep_note "$pick_id" 1 "node_owned_skiq"'
  mutant "o pulo anota como despachada (rc 0)" '_pilot_sweep_note "$pick_id" 1 "node_owned_skip"' '_pilot_sweep_note "$pick_id" 0 "node_owned_skip"'
  mutant "o pulo soma em NONQUEUE_FAILS" $'      _pilot_sweep_note "$pick_id" 1 "node_owned_skip"\n      continue' $'      _pilot_sweep_note "$pick_id" 1 "node_owned_skip"\n      NONQUEUE_FAILS=$((NONQUEUE_FAILS + 1))\n      continue'
  mutant "o pulo so vale fora do DRY_RUN (laco)" '    if _pilot_node_owned_pre "$pick"; then' '    if [ "${DRY_RUN:-0}" != "1" ] && _pilot_node_owned_pre "$pick"; then'
  mutant "o emit nao classifica o nome como beneigno" '"disk_floor_node_only", "node_owned_skip", ' '"disk_floor_node_only", '
  mutant "WA desligado tambem pula" '    wa-*) [ "$_wa" = 1 ] || return 1; _pfx=wa-worker-remote ;;' '    wa-*) _pfx=wa-worker-remote ;;'
  mutant "PS desligado tambem pula" '    ps-*) [ "$_ps" = 1 ] || return 1; _pfx=ps-worker-remote ;;' '    ps-*) _pfx=ps-worker-remote ;;'
  mutant "shadow liga o WA" 'label|auto) _wa=1 ;; esac' 'label|auto|shadow) _wa=1 ;; esac'
  mutant "shadow liga o PS" 'label|auto) _ps=1 ;; esac' 'label|auto|shadow) _ps=1 ;; esac'
  mutant "o PS usa o prefixo do WA" '_pfx=ps-worker-remote ;;' '_pfx=wa-worker-remote ;;'
  mutant "o WA usa o prefixo do PS" '_pfx=wa-worker-remote ;;' '_pfx=ps-worker-remote ;;'
  mutant "so o dono conta (a rota e ignorada)" ' or ((.metadata["gc.routed_to"] // "") | startswith($p))' ''
  mutant "so a rota conta (o dono e ignorado)" '(((.assignee // "") | startswith($p)) or ((.metadata["gc.routed_to"] // "") | startswith($p)))' '((.metadata["gc.routed_to"] // "") | startswith($p))'
  mutant "contem em vez de comeca com" '(((.assignee // "") | startswith($p)) or ((.metadata["gc.routed_to"] // "") | startswith($p)))' '(((.assignee // "") | contains($p)) or ((.metadata["gc.routed_to"] // "") | contains($p)))'
  mutant "id ilegivel vira 'e do no'" $'    return 2\n  }\n  case "$_id" in' $'    return 0\n  }\n  case "$_id" in'
  mutant "id ilegivel colapsa com vazio (rc 1)" $'    return 2\n  }\n  case "$_id" in' $'    return 1\n  }\n  case "$_id" in'
  mutant "dono/rota ilegivel vira 'e do no'" $'    return 2\n  }\n  [ "$_is" = true ]' $'    return 0\n  }\n  [ "$_is" = true ]'
  mutant "dono/rota ilegivel colapsa com vazio (rc 1)" $'    return 2\n  }\n  [ "$_is" = true ]' $'    return 1\n  }\n  [ "$_is" = true ]'
  mutant "o helper so vale fora do DRY_RUN" $'  [ "$_is" = true ]\n}' $'  [ "$_is" = true ] && [ "${DRY_RUN:-0}" != "1" ]\n}'
  mutant "sem o corte barato (le o JSON com os dois botoes desligados)" '  [ "$_wa$_ps" != 00 ] || return 1' '  :'
  # controle de identidade: trocar o texto por ele mesmo NAO pode matar nada (se matar, a morte dos outros e vazia)
  nm=$((nm+1)); idm="$WORK/disp.id.sh"; cp "$DISPATCHER" "$idm"
  idr=$(NOS_MUTANT=1 PILOT_DISPATCHER_PATH="$idm" bash "$SELF" 2>&1 | tail -1)
  case "$idr" in "RESULT 0/"*) ok "controle de identidade: a copia sem mutacao passa inteira ($idr)" ;; *) bad "controle de identidade: a copia SEM mutacao reprova ($idr) — as mortes acima nao provam nada" ;; esac
fi

if [ -n "${NOS_MUTANT:-}" ]; then
  echo "RESULT $FAIL/$((PASS+FAIL))"
  [ "$FAIL" -eq 0 ]
  exit
fi
echo ""
echo "pilot-dispatcher.node-owned-skip.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
