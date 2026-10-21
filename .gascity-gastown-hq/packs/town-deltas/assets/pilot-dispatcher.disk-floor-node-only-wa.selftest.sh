#!/usr/bin/env bash
# pilot-dispatcher.disk-floor-node-only-wa.selftest.sh — ga-8okir7 (a passada só-nó do disk floor também leva ao nó a bead de WA que o gancho do nó leva)
#
# A passada só-nó (ga-2hd02v.1.20) deixava passar SÓ bead de dog do HQ: a de WA era pulada antes da claim e, se chegasse à claim, solta depois. Resultado medido 20/10: com o mini no piso de disco o nó ficou
# ocioso (CPU 1–18% de 00:45 a 06:35) enquanto havia trabalho de WA. O gancho que leva a bead de WA ao wa-worker-remote já existe (_pilot_wa_node_decide, ga-2hd02v.1.10, PILOT_WA_NODE_ROUTE, padrão off);
# faltava a passada só-nó chegar até ele — e, quando ele não leva a bead, NÃO cair no pool do mini (carimbo wa-worker + gc session new), que é o que o disk floor pausa.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: (1) a decisão pré-claim (_pilot_node_only_candidate_pre + _pilot_node_only_wa_pre), EXECUTADA com um wa-node-dispatch.sh falso: só PILOT_WA_NODE_ROUTE=label|auto move bead (off, shadow, vazio,
#   valor que não existe e DRY_RUN = NÃO); `label` exige node:ok no JSON antes de gastar a sonda; bead com dono ou rota, de outro prefixo, JSON ilegível, script ausente = NÃO, sem sonda; a sonda é SEMPRE
#   `apply --dry-run` (nunca escreve) e só o rc 0 vale (10, 11, 12, 13, 124, 137 = NÃO); a sonda tem teto por varredura; a bead de dog continua como era. (2) o braço do pool em dispatch_one (região
#   verbatim): rc 0 do gancho troca o alvo para wa-worker-remote · rc 2 solta a claim e não despacha · rc 1 fora da passada só-nó segue ao pool (como sempre) · rc 1 NA passada só-nó solta a claim e sai com
#   disk_floor_node_only, sem chegar ao carimbo wa-worker. (3) o bloco da passada só-nó em dispatch_one (região verbatim): alvo wa-worker + rig-native + rota ligada segue; ps-worker, crew, rota desligada ou
#   bead do HQ com alvo wa-worker soltam a claim; dog continua isento como na 1.20. (4) a ordem dos pontos de chamada no arquivo.
# COMO RODA: as funções e as regiões são extraídas VERBATIM do dispatcher (awk) e rodam em shells filhos sob `set -euo pipefail` com leitores falsos; nada toca o bd, o gc nem o nó de verdade (PATH de
#   sandbox, selftest-sandbox-path.lib.sh). Contra o dispatcher sem a fatia as asserções reprovam uma a uma (o vermelho mostra o que falta).
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (WAN_NO_MUTANTS=1 pula) tem que reprovar este arquivo.
# Variáveis: PILOT_DISPATCHER_PATH · WAN_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${WAN_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${WAN_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# vazio (a função/região não existe) → texto vazio, e quem usa reprova a asserção; falhou/ilegível (dispatcher que o awk não lê) → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
# region <início> <fim> — as linhas de [início, fim) VERBATIM (regex em ENVIRON: o awk -v comeria as barras); âncora que não casa → vazio
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
FUNC_ON="$(fn_src _pilot_node_only_wa_route_on)"; FUNC_WA="$(fn_src _pilot_node_only_wa_pre)"; FUNC_NC="$(fn_src _pilot_node_only_candidate_pre)"
FUNC_TMPL="$(fn_src wa_worker_template)"; FUNC_ISPOOL="$(fn_src _pilot_priority_target_is_pool)"
PNW_INIT="$(grep -E '^_PNW_PROBES=' "$DISPATCHER")"
# ga-2hd02v.4: _pilot_node_only_candidate_pre também delega a bead ps-* a _pilot_node_only_ps_pre; o harness carrega o que a função sob teste chama (a prova do caminho de PS mora em pilot-dispatcher.ps-node-route.selftest.sh).
# Aqui PILOT_PS_NODE_ROUTE nunca é definida: a bead ps-* segue NÃO candidata.
FUNC_PSON="$(fn_src _pilot_node_only_ps_route_on)"; FUNC_PS="$(fn_src _pilot_node_only_ps_pre)"; PNP_INIT="$(grep -E '^_PNP_PROBES=' "$DISPATCHER")"
ARM_SRC="$(region '^        local _RP_NODE_RC=0$' '^        : # pool: leave UNASSIGNED')"
BLOCK_SRC="$(region '^  local _PYS_TARGET _PYS_NATIVE=0$' '^  # ── wa-root-worktree-isolation')"
{ [ -n "$FUNC_NC" ] && [ -n "$FUNC_TMPL" ] && [ -n "$FUNC_ISPOOL" ] && [ -n "$ARM_SRC" ] && [ -n "$BLOCK_SRC" ]; } \
  || { echo "FATAL: ga-2hd02v.1.20 não aplicada (função ou região do dispatcher não achada em $DISPATCHER)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-diskfloor-nodeonly-wa-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc" "$WORK/scripts"
# o wa-node-dispatch.sh falso: conta a chamada com os argumentos, sai com o rc de $WORK/wnd.rc (sem arquivo: 12, "não elegível"). Nunca escreve em lugar nenhum além do próprio log.
cat > "$WORK/scripts/wa-node-dispatch.sh" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo "$*" >> "$W/wnd.calls"
[ -f "$W/wnd.rc" ] || exit 12
exit "$(cat "$W/wnd.rc")"
EOF
chmod +x "$WORK/scripts/wa-node-dispatch.sh"
# o bd falso: só registra os argumentos (a claim solta é uma escrita; o selftest conta quais)
cat > "$WORK/bin/bd" <<'EOF'
#!/bin/sh
echo "$*" >> "${SELFTEST_WORK:?}/bd.calls"
exit 0
EOF
chmod +x "$WORK/bin/bd"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat rm sh || exit 2
reset() { rm -f "$WORK"/wnd.rc "$WORK"/wnd.calls "$WORK"/bd.calls; }
wnd() { echo "$1" > "$WORK/wnd.rc"; }
calls() { [ -f "$WORK/wnd.calls" ] && wc -l < "$WORK/wnd.calls" | tr -d ' ' || echo 0; }
bdcalls() { [ -f "$WORK/bd.calls" ] && wc -l < "$WORK/bd.calls" | tr -d ' ' || echo 0; }

# ── (1) a decisão pré-claim ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# As regras de dog (_pilot_priority_*) são trocadas por falsos: o que faz uma bead de WA ser candidata aqui só pode vir do caminho novo.
run_pre() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { :; }
    warn() { :; }
    GC_CITY="$WORK/city"; PILOT_WA_NODE_SCRIPTS="$WORK/scripts"; DRY_RUN="${PR_DRY:-0}"
    [ -z "${PR_ROUTE+x}" ] || PILOT_WA_NODE_ROUTE="$PR_ROUTE"
    [ -z "${PR_CAP+x}" ] || PILOT_WA_NODE_ONLY_PROBES="$PR_CAP"
    [ -z "${PR_SCRIPTS+x}" ] || PILOT_WA_NODE_SCRIPTS="$PR_SCRIPTS"
    eval "$PNW_INIT"
    _pilot_priority_pool_bound_pre() { return 0; }
    _pilot_priority_node_exempt_pre() { return "${PR_DOG_EXEMPT:-1}"; }
    eval "$FUNC_ON"; eval "$FUNC_WA"; eval "$FUNC_NC"; eval "$FUNC_PSON"; eval "$FUNC_PS"; eval "$PNP_INIT"
    c() { local x=0; _pilot_node_only_candidate_pre "$1" || x=$?; printf '%s ' "$x"; }
    eval "$1"
  ) 2>&1 | tail -1
}
J_LABEL='{"id":"wa-p1","labels":["story:approved","node:ok"],"metadata":{}}'
J_PLAIN='{"id":"wa-p2","labels":["story:approved"],"metadata":{}}'
J_ROUTED='{"id":"wa-p3","labels":["story:approved","node:ok"],"metadata":{"gc.routed_to":"wa-worker"}}'
J_OWNED='{"id":"wa-p4","labels":["story:approved","node:ok"],"assignee":"mila-wa","metadata":{}}'
J_PS='{"id":"ps-p5","labels":["story:approved","node:ok"],"metadata":{}}'
J_GA='{"id":"ga-p6","labels":["story:approved","node:ok"],"metadata":{}}'
q() { printf '%s' "${1//\"/\\\"}"; }
echo "── (1) PILOT_WA_NODE_ROUTE: só label|auto move bead; o resto NÃO (e não gasta a sonda)"
for m in off shadow "" on AUTO Label; do
  reset; wnd 0
  r=$(PR_ROUTE="$m" run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
  [ "$r" = 1 ] && [ "$(calls)" = 0 ] && ok "PILOT_WA_NODE_ROUTE='$m': NÃO é candidata, 0 sondas (o script falso diria 0)" || bad "PILOT_WA_NODE_ROUTE='$m' deixou a bead de WA passar (rc=$r, sondas=$(calls))"
done
reset; wnd 0
r=$(unset PR_ROUTE; run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = 1 ] && [ "$(calls)" = 0 ] && ok "variável nunca definida: NÃO é candidata (o padrão do gancho é off)" || bad "sem PILOT_WA_NODE_ROUTE a bead de WA passou (rc=$r, sondas=$(calls))"
reset; wnd 0
r=$(PR_ROUTE=label PR_DRY=1 run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = 1 ] && [ "$(calls)" = 0 ] && ok "DRY_RUN=1: NÃO é candidata, 0 sondas" || bad "DRY_RUN=1 deixou a bead de WA passar (rc=$r, sondas=$(calls))"

echo "── (1) a bead de WA candidata: label exige node:ok no JSON; a sonda é SEMPRE o dry-run"
reset; wnd 0
r=$(PR_ROUTE=label run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = 0 ] && [ "$(calls)" = 1 ] && ok "label + node:ok + sonda rc 0: candidata, UMA sonda" || bad "label + node:ok + rc 0 não é candidata (rc=$r, sondas=$(calls))"
[ "$(cat "$WORK/wnd.calls" 2>/dev/null)" = "apply wa-p1 --dry-run --basis label" ] && ok "a sonda é 'apply <bead> --dry-run --basis label' (dry-run: nada é escrito)" || bad "a sonda não é o dry-run esperado: '$(cat "$WORK/wnd.calls" 2>/dev/null)'"
reset; wnd 0
r=$(PR_ROUTE=label run_pre 'c "'"$(q "$J_PLAIN")"'"; echo'); r="${r% }"
[ "$r" = 1 ] && [ "$(calls)" = 0 ] && ok "label sem node:ok: NÃO é candidata e não gasta a sonda (o apply recusaria por base)" || bad "label sem node:ok passou ou gastou sonda (rc=$r, sondas=$(calls))"
reset; wnd 0
r=$(PR_ROUTE=auto run_pre 'c "'"$(q "$J_PLAIN")"'"; echo'); r="${r% }"
[ "$r" = 0 ] && [ "$(calls)" = 1 ] && [ "$(cat "$WORK/wnd.calls")" = "apply wa-p2 --dry-run --basis any" ] && ok "auto sem node:ok: candidata pela sonda (apply --dry-run --basis any)" || bad "auto sem node:ok (rc=$r, sondas=$(calls), argv='$(cat "$WORK/wnd.calls" 2>/dev/null)')"

echo "── (1) o terceiro estado nunca vira node: só o rc 0 da sonda vale"
for rc in 10 11 12 13 2 124 137 127; do
  reset; wnd "$rc"
  r=$(PR_ROUTE=auto run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
  [ "$r" = 1 ] && [ "$(calls)" = 1 ] && ok "sonda rc $rc: NÃO é candidata" || bad "sonda rc $rc virou candidata (rc=$r, sondas=$(calls))"
done
echo "── (1) o que não pode ir ao nó não gasta sonda"
reset; wnd 0
r=$(PR_ROUTE=auto run_pre 'c "'"$(q "$J_ROUTED")"'"; c "'"$(q "$J_OWNED")"'"; c "'"$(q "$J_PS")"'"; c "'"$(q "$J_GA")"'"; c "isto não é json"; c ""; echo'); r="${r% }"
[ "$r" = "1 1 1 1 1 1" ] && [ "$(calls)" = 0 ] && ok "com rota, com dono, ps-*, ga-* (regras de dog falsas dizem NÃO), JSON ilegível e vazio: NÃO candidatas, 0 sondas — $r" || bad "um filtro de entrada falhou ($r, sondas=$(calls))"
reset; wnd 0
r=$(PR_ROUTE=auto PR_SCRIPTS="$WORK/nao-existe" run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = 1 ] && ok "wa-node-dispatch.sh ausente: NÃO é candidata" || bad "script ausente virou candidata ($r)"
echo "── (1) o helper de WA recusa por conta própria o id que não é wa-* (defesa em profundidade: o candidate_pre só delega wa-*)"
reset; wnd 0
r=$(PR_ROUTE=auto run_pre 'cw() { local x=0; _pilot_node_only_wa_pre "$1" || x=$?; printf "%s " "$x"; }; cw "'"$(q "$J_PS")"'"; cw "'"$(q "$J_GA")"'"; cw "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = "1 1 0" ] && [ "$(calls)" = 1 ] && ok "chamado direto: ps-* e ga-* NÃO (sem sonda); wa-* com a sonda em 0 SIM — $r" || bad "o helper de WA deixou passar id que não é wa-* ($r, sondas=$(calls))"
echo "── (1) teto de sondas por varredura"
reset; wnd 12
r=$(PR_ROUTE=auto PR_CAP=2 run_pre 'c "'"$(q "$J_LABEL")"'"; c "'"$(q "$J_LABEL")"'"; c "'"$(q "$J_LABEL")"'"; c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = "1 1 1 1" ] && [ "$(calls)" = 2 ] && ok "PILOT_WA_NODE_ONLY_PROBES=2: só 2 sondas na varredura; as seguintes são NÃO sem sonda" || bad "o teto não vale ($r, sondas=$(calls))"
reset; wnd 0
r=$(PR_ROUTE=auto PR_CAP=x run_pre 'c "'"$(q "$J_LABEL")"'"; echo'); r="${r% }"
[ "$r" = 0 ] && ok "teto ilegível volta ao padrão (não desliga a passada nem a abre sem limite)" || bad "teto ilegível: rc=$r"
echo "── (1) a bead de dog continua como era"
reset; wnd 0
r=$(PR_ROUTE=off PR_DOG_EXEMPT=0 run_pre 'c "'"$(q "$J_GA")"'"; echo'); r="${r% }"
[ "$r" = 0 ] && [ "$(calls)" = 0 ] && ok "ga-* que o nó quer: candidata pelo caminho de dog, sem sonda de WA" || bad "a bead de dog deixou de ser candidata (rc=$r, sondas=$(calls))"

# ── (2) o braço do pool em dispatch_one ──────────────────────────────────────────────────────────────────────────────────────────────────────────
run_arm() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { :; }
    warn() { :; }
    STORY_ID=wa-arm1; STORY_BEAD_CITY="$WORK/wa-store"; _SLING_TARGET=wa-worker; DISPATCH_RESULT=""
    _PILOT_NODE_ONLY="${AR_NODE_ONLY:-0}"
    _pilot_wa_node_decide() { return "${AR_RC:-1}"; }
    armfn() {
      eval "$ARM_SRC"
      echo "CONTINUED target=$_SLING_TARGET"
    }
    # sem $(...): o armfn roda neste shell, e o DISPATCH_RESULT que ele grava chega até o eco abaixo (num subshell ele se perderia)
    r=0; armfn > "$WORK/arm.out" || r=$?
    out="$(cat "$WORK/arm.out" 2>/dev/null)"
    echo "rc=$r result=${DISPATCH_RESULT:-} ${out:-NOT-CONTINUED}"
  ) 2>&1 | tail -1
}
echo "── (2) o braço do pool: o que o gancho devolve e o que a passada só-nó faz com isso"
reset; r=$(AR_RC=0 AR_NODE_ONLY=1 run_arm)
[ "$r" = "rc=0 result= CONTINUED target=wa-worker-remote" ] && [ "$(bdcalls)" = 0 ] && ok "gancho rc 0 (a bead já é do nó): alvo wa-worker-remote, nada solto — $r" || bad "rc 0 do gancho: $r (escritas=$(bdcalls))"
reset; r=$(AR_RC=2 AR_NODE_ONLY=1 run_arm)
[ "$r" = "rc=1 result=wa_node_unknown NOT-CONTINUED" ] && [ "$(bdcalls)" = 2 ] && ok "gancho rc 2 (a escrita pode ter acontecido): solta a claim e não despacha — $r" || bad "rc 2 do gancho: $r (escritas=$(bdcalls))"
reset; r=$(AR_RC=1 AR_NODE_ONLY=0 run_arm)
[ "$r" = "rc=0 result= CONTINUED target=wa-worker" ] && [ "$(bdcalls)" = 0 ] && ok "gancho rc 1 FORA da passada só-nó: segue ao pool do mini, como sempre — $r" || bad "rc 1 fora da passada só-nó mudou: $r (escritas=$(bdcalls))"
reset; r=$(AR_RC=1 AR_NODE_ONLY=1 run_arm)
[ "$r" = "rc=1 result=disk_floor_node_only NOT-CONTINUED" ] && ok "gancho rc 1 NA passada só-nó: sai com disk_floor_node_only e NÃO chega ao carimbo wa-worker/gc session new — $r" || bad "rc 1 na passada só-nó: $r"
[ "$(bdcalls)" = 2 ] && grep -q 'label remove wa-arm1 pilot:dispatching' "$WORK/bd.calls" && grep -q 'unset-metadata pilot.dispatching_at' "$WORK/bd.calls" && ! grep -q 'routed_to' "$WORK/bd.calls" \
  && ok "e solta a claim (label + stamp), sem carimbar gc.routed_to" || bad "a claim não foi solta como esperado: $(tr '\n' '|' < "$WORK/bd.calls" 2>/dev/null)"

# ── (3) o bloco da passada só-nó em dispatch_one (depois da claim) ───────────────────────────────────────────────────────────────────────────────
run_block() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log() { echo "LOG $*" >> "$WORK/block.log"; }
    STORY_ID=wa-blk1; STORY_BEAD_CITY="${BL_CITY:-$WORK/wa-store}"; GC_CITY="$WORK/city"; STORY_LABELS=""; STORY='{}'
    BUILDER_TARGET="${BL_TARGET:-wa-worker-1}"; DISPATCH_RESULT=""; _PNY_EXEMPT_THIS=0
    _PILOT_NODE_ONLY=1; DRY_RUN=0
    [ -z "${BL_ROUTE+x}" ] || PILOT_WA_NODE_ROUTE="$BL_ROUTE"
    _pilot_priority_node_exempt() { return "${BL_DOG_EXEMPT:-1}"; }
    _pilot_priority_yield_for() { return 1; }
    _pilot_priority_yield_say() { :; }
    _pilot_priority_yield_release() { echo "RELEASE $4" >> "$WORK/block.rel"; }
    eval "$FUNC_TMPL"; eval "$FUNC_ISPOOL"; eval "$FUNC_ON"
    blkfn() {
      eval "$BLOCK_SRC"
      echo "CONTINUED exempt=$_PNY_EXEMPT_THIS"
    }
    r=0; blkfn > "$WORK/blk.out" || r=$?
    out="$(cat "$WORK/blk.out" 2>/dev/null)"
    echo "rc=$r result=${DISPATCH_RESULT:-} ${out:-NOT-CONTINUED} rel=$(tr '\n' ',' < "$WORK/block.rel" 2>/dev/null)"
  ) 2>&1 | tail -1
}
blk() { rm -f "$WORK/block.log" "$WORK/block.rel"; run_block; }
echo "── (3) dispatch_one, passada só-nó, depois da claim: quem segue e quem solta"
r=$(BL_ROUTE=label BL_CITY="$WORK/wa-store" blk)
[ "$r" = "rc=0 result= CONTINUED exempt=0 rel=" ] && ok "wa-worker + rig-native + rota label: SEGUE (a claim fica; o gancho do nó decide) — $r" || bad "bead de WA com rota ligada não segue: $r"
r=$(BL_ROUTE=auto blk)
[ "$r" = "rc=0 result= CONTINUED exempt=0 rel=" ] && ok "wa-worker + rig-native + rota auto: SEGUE — $r" || bad "bead de WA com rota auto não segue: $r"
r=$(BL_ROUTE=off blk)
[ "$r" = "rc=1 result=disk_floor_node_only NOT-CONTINUED rel=RELEASE disk-floor-node-only," ] && ok "rota off: solta a claim (nada vai ao mini) — $r" || bad "rota off não soltou: $r"
r=$(BL_ROUTE=shadow blk)
[ "$r" = "rc=1 result=disk_floor_node_only NOT-CONTINUED rel=RELEASE disk-floor-node-only," ] && ok "rota shadow (só registra): solta a claim — $r" || bad "rota shadow não soltou: $r"
r=$(BL_ROUTE=auto BL_CITY="$WORK/city" blk)
[ "$r" = "rc=1 result=disk_floor_node_only NOT-CONTINUED rel=RELEASE disk-floor-node-only," ] && ok "bead da cidade (HQ) com alvo wa-worker: solta (o gancho de WA só leva bead do store do WA) — $r" || bad "bead do HQ com alvo wa-worker não soltou: $r"
r=$(BL_ROUTE=auto BL_TARGET=ps-worker-1 blk)
[ "$r" = "rc=1 result=disk_floor_node_only NOT-CONTINUED rel=RELEASE disk-floor-node-only," ] && ok "ps-worker: solta (não há ps-worker remoto) — $r" || bad "ps-worker não soltou: $r"
r=$(BL_ROUTE=auto BL_TARGET=oracle-wa blk)
[ "$r" = "rc=1 result=disk_floor_node_only NOT-CONTINUED rel=RELEASE disk-floor-node-only," ] && ok "crew nomeada: solta — $r" || bad "crew nomeada não soltou: $r"
r=$(BL_ROUTE=off BL_TARGET=gastown.dog BL_CITY="$WORK/city" BL_DOG_EXEMPT=0 blk)
[ "$r" = "rc=0 result= CONTINUED exempt=1 rel=" ] && ok "dog do HQ que o nó quer: segue isento, como na 1.20 — $r" || bad "a bead de dog deixou de seguir: $r"

# ── (4) os pontos de chamada, na ordem ───────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── (4) a ordem no dispatcher"
L_WA=$(grep -n '^_pilot_node_only_wa_pre() {' "$DISPATCHER" | head -1 | cut -d: -f1)
L_NC=$(grep -n '^_pilot_node_only_candidate_pre() {' "$DISPATCHER" | head -1 | cut -d: -f1)
L_DECIDE=$(grep -n '^_pilot_wa_node_decide() {' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_WA" ] && [ -n "$L_NC" ] && [ -n "$L_DECIDE" ] && [ "$L_NC" -lt "$L_WA" ] && ok "o helper de WA está definido depois de _pilot_node_only_candidate_pre (linhas $L_NC → $L_WA; funções, a ordem só importa na chamada)" || bad "helper de WA ausente ou fora do lugar (nc=$L_NC wa=$L_WA decide=$L_DECIDE)"
grep -qxF '_PNW_PROBES=0' <<<"$PNW_INIT" && ok "o contador de sondas nasce em 0 uma vez por varredura (cada varredura é um processo novo)" || bad "contador _PNW_PROBES sem inicialização"
L_CALL=$(grep -n '_pilot_wa_node_decide "\$STORY_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_ONLY=$(awk -v a="${L_CALL:-0}" 'NR>a && /_PILOT_NODE_ONLY:-0}" = "1" \]; then/ {print NR; exit}' "$DISPATCHER")
L_LEAVE=$(grep -n ': # pool: leave UNASSIGNED + open so RoutedPoolQuery' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_CALL" ] && [ -n "$L_ONLY" ] && [ -n "$L_LEAVE" ] && [ "$L_CALL" -lt "$L_ONLY" ] && [ "$L_ONLY" -lt "$L_LEAVE" ] && ok "dispatch_one: o gancho do nó ($L_CALL) → a saída da passada só-nó ($L_ONLY) → o caminho do pool do mini ($L_LEAVE)" || bad "a saída da passada só-nó não fica entre o gancho e o pool (gancho=$L_CALL saída=$L_ONLY pool=$L_LEAVE)"
{ grep -qxF '_pilot_pool_topup "wa-worker" "${PILOT_WA_WORKER_MAX:-4}"' "$DISPATCHER" && grep -qxF '_pilot_pool_topup "ps-worker" "${PILOT_PS_WORKER_MAX:-2}"' "$DISPATCHER"; } \
  && ok "o top-up do pool do mini continua pulado dentro da função na passada só-nó (esta fatia não o toca: abrir sessão de wa-worker no mini gasta o disco que o piso protege)" || bad "as chamadas do top-up mudaram de lugar"

if [ -z "${WAN_MUTANT:-}" ] && [ -z "${WAN_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo"
  nm=0
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(WAN_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  # as âncoras são ASCII de propósito (o python3 lê o argv no locale do shell e o arquivo em UTF-8: uma âncora com acento não casaria sob LC_ALL=C)
  mutant "a sonda não é dry-run" '--dry-run --basis "$_basis" >/dev/null' '--basis "$_basis" >/dev/null'
  mutant "a rota desligada deixa passar" $'  case "${PILOT_WA_NODE_ROUTE:-}" in label|auto) ;; *) return 1 ;; esac\n  [ "${DRY_RUN:-0}" != "1" ]' $'  [ "${DRY_RUN:-0}" != "1" ]'
  mutant "o DRY_RUN deixa passar" $'label|auto) ;; *) return 1 ;; esac\n  [ "${DRY_RUN:-0}" != "1" ]' $'label|auto) ;; *) return 1 ;; esac\n  :'
  mutant "a sonda vale com qualquer rc" '  [ "$_rc" = 0 ]' '  return 0'
  mutant "o teto de sondas não vale" '  [ "$_PNW_PROBES" -lt "$_cap" ] || return 1' '  :'
  mutant "label sem node:ok gasta a sonda" '    printf '"'"'%s'"'"' "$_b" | jq -e '"'"'(.labels // []) | index("node:ok")'"'"' >/dev/null 2>&1 || return 1' '    :'
  mutant "bead com dono ou rota gasta a sonda" '  [ -z "$_own" ] || return 1' '  :'
  mutant "id que nao e wa-* entra no caminho de WA" '  [ "${_id#wa-}" != "$_id" ] || return 1' '  :'
  mutant "o candidate_pre nao chama o caminho de WA" $'  case "$_id" in wa-*) _pilot_node_only_wa_pre "$_b" && return 0; return 1 ;; esac' '  :'
  mutant "o bloco pos-claim solta a bead de WA com rota ligada" $'    elif [ "$_PYS_NATIVE" = "1" ] && [ "$_PYS_TARGET" = "wa-worker" ] && _pilot_node_only_wa_route_on; then' $'    elif false; then'
  mutant "o bloco pos-claim deixa passar bead do HQ com alvo wa-worker" $'    elif [ "$_PYS_NATIVE" = "1" ] && [ "$_PYS_TARGET" = "wa-worker" ]' $'    elif [ "$_PYS_TARGET" = "wa-worker" ]'
  mutant "o rc 1 do gancho cai no pool do mini na passada so-no" $'        elif [ "${_PILOT_NODE_ONLY:-0}" = "1" ]; then' $'        elif false; then'
  mutant "o rc 1 na passada so-no nao solta a claim" $'          DISPATCH_RESULT="disk_floor_node_only"\n          return 1\n        fi\n        : # pool' $'          DISPATCH_RESULT="disk_floor_node_only"\n        fi\n        : # pool'
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
