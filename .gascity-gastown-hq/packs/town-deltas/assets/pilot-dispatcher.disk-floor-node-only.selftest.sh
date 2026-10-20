#!/usr/bin/env bash
# pilot-dispatcher.disk-floor-node-only.selftest.sh — ga-2hd02v.1.20 (a varredura pausada por DISK FLOOR ainda faz a passada só-nó)
#
# O Pilot pausava a varredura inteira quando o disco livre do mini cai abaixo do piso (33 de 53 varreduras em 19/10: o swap do mini faz o disco oscilar 3–6 GB) e o nó Hetzner ficava ocioso. Essa pausa
# protege o disco do MINI; despachar ao nó não gasta disco do mini (o worktree e o build são no Hetzner). Com PILOT_NODE_FIRST=on, uma varredura pausada SÓ por disk floor faz a PASSADA SÓ-NÓ
# (_PILOT_NODE_ONLY=1): só bead de dog do HQ com veredito node e vaga vai adiante, e nada vai ao mini. Cota 5h, pressão de RAM, drain e quiet hours continuam pausando tudo; oráculo que falha = nada.
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: (1) a cadeia de gates, EXECUTADA (a região verbatim do dispatcher, de cota até quiet hours, com os leitores falsos): disco baixo + on + fora do DRY_RUN segue em passada só-nó e grava a pausa
#   "disk-floor" · off, shadow, valor que não existe, vazio e DRY_RUN pausam e saem como sempre · disco ok ou ilegível nunca liga a passada só-nó · cota e RAM pausam ANTES do disco, drain e quiet hours DEPOIS
#   dele, e todos continuam saindo com disco baixo + on. (2) o limpa-pausa (ga-nq0jo) não roda na passada só-nó (o painel não pode ler "sem pausa" com o disco ainda baixo) · o top-up de pool não abre sessão
#   no mini · a varredura só-nó que despachou 0 não conta no streak de estagnação do Step 5 (e não o zera) · a checagem de cessões consecutivas do priority yield (ga-2lca0l) sai na 1a guarda dela nessa passada (PRIORITY_YIELDED é 0 e apagaria o contador). (3) a decisão pré-claim `_pilot_node_only_candidate_pre`: node com vaga → candidata; local, oráculo
#   mudo, JSON ilegível, node sem effective, veto, wa-worker/ps-worker, bead de outro store ou de outro rig → NÃO (nada é escrito). (4) os pontos de chamada, na ordem: o que não é candidata é pulado antes da
#   claim · a que o nó não fica solta a claim e nunca chega ao despacho ao mini.
# COMO RODA: as funções e as regiões são extraídas VERBATIM do dispatcher (awk) e rodam em shells filhos sob `set -euo pipefail` com leitores falsos; `python3` é o oráculo falso do PATH do filho
#   (selftest-sandbox-path.lib.sh). Contra o dispatcher sem a passada só-nó as asserções reprovam uma a uma (o vermelho mostra o que falta).
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (DF_NO_MUTANTS=1 pula) tem que reprovar este arquivo.
# Variáveis: PILOT_DISPATCHER_PATH · DF_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${DF_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${DF_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# vazio (a função não existe) → texto vazio, e quem usa reprova a asserção; falhou/ilegível (dispatcher que o awk não lê) → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
# region <início> <fim> — as linhas de [início, fim) VERBATIM (regex em ENVIRON: o awk -v comeria as barras); âncora que não casa → vazio → o FATAL logo abaixo
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
FUNC_EXEMPT="$(fn_src _pilot_priority_node_exempt)"; FUNC_PRE="$(fn_src _pilot_priority_node_exempt_pre)"
FUNC_SHADOW="$(fn_src _pilot_node_first_shadow)"; FUNC_VETO="$(fn_src _pilot_node_first_veto)"
FUNC_BOUND="$(fn_src _pilot_priority_pool_bound_pre)"; FUNC_NC="$(fn_src _pilot_node_only_candidate_pre)"
# ga-8okir7: _pilot_node_only_candidate_pre delega a bead wa-* a _pilot_node_only_wa_pre; o harness tem que carregar o que a função sob teste chama (a prova do caminho de WA mora em pilot-dispatcher.disk-floor-node-only-wa.selftest.sh)
FUNC_ON="$(fn_src _pilot_node_only_wa_route_on)"; FUNC_WA="$(fn_src _pilot_node_only_wa_pre)"; PNW_INIT="$(grep -E '^_PNW_PROBES=' "$DISPATCHER")"
VETO_LINE="$(grep -E '^PILOT_NODE_FIRST_VETO_LABELS="' "$DISPATCHER" | head -1)"
PNY_INIT="$(grep -E '^_PNY_(ASKED|VERDICT|EFFECTIVE|GRANTED|GRANTED_N|EXEMPT_THIS)=' "$DISPATCHER")"
GATE_SRC="$(region '^if \[ "\$_PILOT_QUOTA_STATE" = "limited" \]; then$' '^# ── ga-d0hz3: CROSS-STAGE admission gate')"
CLEAR_SRC="$(region '^# ga-nq0jo: reaching here' '^# ── Step 0: TTL recovery')"
FUNC_TOPUP="$(fn_src _pilot_pool_topup)"
STALL_SRC="$(region '^PILOT_STALL_STATE=' '^# ga-2lca0l \(3\)')"
FUNC_YSTALL="$(fn_src _pilot_yield_stall_check)"
{ [ -n "$FUNC_EXEMPT" ] && [ -n "$FUNC_PRE" ] && [ -n "$FUNC_SHADOW" ] && [ -n "$FUNC_VETO" ] && [ -n "$FUNC_BOUND" ] && [ -n "$VETO_LINE" ] && [ -n "$PNY_INIT" ]; } \
  || { echo "FATAL: ga-2hd02v.1.19 não aplicada (funções ou linhas de configuração do nó não achadas em $DISPATCHER)" >&2; exit 2; }
{ [ -n "$FUNC_ON" ] && [ -n "$FUNC_WA" ] && [ -n "$PNW_INIT" ]; } || { echo "FATAL: ga-8okir7 não aplicada (o caminho de WA do filtro pré-claim não está em $DISPATCHER: _pilot_node_only_wa_route_on / _pilot_node_only_wa_pre / _PNW_PROBES)" >&2; exit 2; }
{ [ -n "$GATE_SRC" ] && [ -n "$CLEAR_SRC" ] && [ -n "$FUNC_TOPUP" ] && [ -n "$STALL_SRC" ] && [ -n "$FUNC_YSTALL" ]; } || { echo "FATAL: região ou função do dispatcher não achada (gates / limpa-pausa / _pilot_pool_topup / Step 5 / cessões consecutivas) em $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-diskfloor-nodeonly-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc"
# o oráculo falso: conta a chamada, devolve $WORK/oracle.out e sai com $WORK/oracle.rc (sem arquivo: sai 127 como "comando que não rodou")
cat > "$WORK/bin/python3" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo x >> "$W/oracle.calls"
[ -f "$W/oracle.rc" ] || exit 127
[ -f "$W/oracle.out" ] && cat "$W/oracle.out"
exit "$(cat "$W/oracle.rc")"
EOF
chmod +x "$WORK/bin/python3"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat rm || exit 2
LINES="$WORK/lines.txt"; STALL="$WORK/city/.gc/pilot-dispatcher-stall.count"
reset() { rm -f "$WORK"/oracle.out "$WORK"/oracle.rc "$WORK"/oracle.calls "$WORK"/pause.calls "$WORK"/topup.calls "$WORK"/ystall.state "$LINES" "$STALL"; }
oracle() { printf '%s' "$2" > "$WORK/oracle.out"; echo "$1" > "$WORK/oracle.rc"; }
calls() { [ -f "$WORK/oracle.calls" ] && wc -l < "$WORK/oracle.calls" | tr -d ' ' || echo 0; }

# ── (1) a cadeia de gates: quota → RAM → DISCO → drain → quiet hours, a região verbatim ──────────────────────────────────────────────────────────
cat > "$WORK/gate-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
log()  { echo "LOG $*"; }
warn() { echo "WARN $*"; }
notify() { :; }
_pilot_write_sweep_pause_state() { echo "PAUSE_STATE $*" >> "$WORK/pause.calls"; }
_PILOT_QUOTA_STATE="${GT_QUOTA:-ok}"; _pilot_quota_eta() { echo ""; }
_pilot_ram_pressure_blocks() { echo "${GT_RAM:-0}"; }; _pilot_ram_pressure_level() { echo WARN; }; _pilot_ram_pressure_unreadable() { echo 0; }
_pilot_disk_floor() {
  PILOT_DISK_FLOOR_NOTE=""; PILOT_DISK_FLOOR_DETAIL="disk_free=3000MB floor=5120MB"
  case "${GT_DISK:-ok}" in low) PILOT_DISK_FLOOR_STATE=low; return 0 ;; unknown) PILOT_DISK_FLOOR_STATE=unknown; return 1 ;; *) PILOT_DISK_FLOOR_STATE=ok; return 1 ;; esac
}
_drain_window_blocks() { echo "${GT_DRAIN:-0}"; }; _drain_window_detail() { echo drain; }; _drain_window_unreadable() { echo 0; }
_quiet_hours_blocks() { echo "${GT_QUIET:-0}"; }; _quiet_hours_unreadable() { echo 0; }
PILOT_NODE_FIRST="${GT_MODE-on}"; DRY_RUN="${GT_DRY:-0}"
eval "$GATE_SRC"
echo "REACHED node_only=${_PILOT_NODE_ONLY:-unset}"
EOF
# gate <VAR=valor...> — roda a cadeia e deixa em G_REACHED / G_NODE_ONLY / G_REASON (a última razão de pausa gravada) / G_END (o "(paused: …)" do fim de varredura)
gate() {
  rm -f "$WORK/pause.calls"
  G_OUT="$(env GATE_SRC="$GATE_SRC" SANDBOX_PATH="$SANDBOX_PATH" WORK="$WORK" "$@" bash "$WORK/gate-runner.sh" 2>&1)"
  G_REACHED=0; case "$G_OUT" in "REACHED "*|*$'\n'"REACHED "*) G_REACHED=1 ;; esac
  G_NODE_ONLY="$(printf '%s\n' "$G_OUT" | sed -n 's/^REACHED node_only=//p')"
  # vazio (nenhuma pausa gravada) → "nenhuma"; falhou/ilegível (arquivo que não lê) → também "nenhuma": a asserção que espera uma razão reprova
  G_REASON="$(sed -n 's/^PAUSE_STATE 1 \([^ ]*\) .*/\1/p' "$WORK/pause.calls" 2>/dev/null | tail -1)"; G_REASON="${G_REASON:-nenhuma}"
  G_END="$(printf '%s\n' "$G_OUT" | sed -n 's/.*Pilot sweep complete: dispatched=0 (paused: \(.*\)) ===.*/\1/p' | head -1)"
}
expect() { # <desc> <reached> <node_only> <razão> <fim>
  if [ "$G_REACHED" = "$2" ] && [ "$G_NODE_ONLY" = "$3" ] && [ "$G_REASON" = "$4" ] && [ "$G_END" = "$5" ]; then ok "$1 — reached=$G_REACHED node_only=${G_NODE_ONLY:--} pausa=$G_REASON fim='${G_END:--}'"
  else bad "$1 — esperado reached=$2 node_only=${3:--} pausa=$4 fim='${5:--}'; veio reached=$G_REACHED node_only='${G_NODE_ONLY:--}' pausa=$G_REASON fim='${G_END:--}'"; fi
}
echo "── (1) disco baixo + on: a varredura segue em passada só-nó e a pausa do disco continua gravada"
gate GT_DISK=low
expect "disco baixo, on, fora do DRY_RUN: segue só-nó" 1 1 disk-floor ""
printf '%s\n' "$G_OUT" | grep -q 'só-nó' && ok "a passada só-nó está dita no log (quem lê o log sabe que o disco segue baixo e o que a varredura faz)" || bad "nenhuma linha de log diz 'só-nó'"
[ "$(grep -c '^PAUSE_STATE 1 disk-floor ' "$WORK/pause.calls" 2>/dev/null)" = 1 ] && ok "a pausa do disk floor é gravada UMA vez (o painel e o reconciler seguem vendo a razão)" || bad "a pausa disk-floor não foi gravada uma vez"
echo "── (1) o que NÃO liga a passada: off, shadow, valor desconhecido, vazio, DRY_RUN — pausam e saem como sempre"
gate GT_DISK=low GT_MODE=off;    expect "PILOT_NODE_FIRST=off" 0 "" disk-floor "disk floor"
gate GT_DISK=low GT_MODE=shadow; expect "PILOT_NODE_FIRST=shadow" 0 "" disk-floor "disk floor"
gate GT_DISK=low GT_MODE=maybe;  expect "PILOT_NODE_FIRST=maybe (valor que não existe)" 0 "" disk-floor "disk floor"
gate GT_DISK=low GT_MODE=;       expect "PILOT_NODE_FIRST vazio" 0 "" disk-floor "disk floor"
gate GT_DISK=low GT_DRY=1;       expect "DRY_RUN (a passada consulta o nó e grava estado)" 0 "" disk-floor "disk floor"
echo "── (1) disco que não está confirmado baixo nunca liga a passada"
gate GT_DISK=ok;      expect "disco ok" 1 0 nenhuma ""
gate GT_DISK=unknown; expect "disco ilegível (fail-open de sempre; NÃO é 'baixo')" 1 0 nenhuma ""
echo "── (1) cota e RAM pausam ANTES do disco; drain e quiet hours DEPOIS — e todos continuam saindo com disco baixo + on"
gate GT_DISK=low GT_QUOTA=limited; expect "cota 5h limitada" 0 "" quota-limited "cota 5h limitada"
gate GT_DISK=low GT_RAM=1;         expect "pressão de RAM (antes do disco: a razão gravada é a da RAM, não a do disco)" 0 "" ram-pressure "pressão de RAM WARN"
gate GT_DISK=low GT_DRAIN=1;       expect "drain window (depois do disco: a passada só-nó não a atravessa)" 0 "" drain-window "drain window"
gate GT_DISK=low GT_QUIET=1;       expect "quiet hours (depois do disco: a passada só-nó não a atravessa)" 0 "" quiet-hours "quiet hours"
gate GT_DISK=ok GT_RAM=1;          expect "RAM sem disco baixo (controle)" 0 "" ram-pressure "pressão de RAM WARN"

# ── (2) o resto da varredura respeita a passada só-nó ─────────────────────────────────────────────────────────────────────────────────────────────
cat > "$WORK/clear-runner.sh" <<'EOF'
set -euo pipefail
_pilot_write_sweep_pause_state() { echo "PAUSE_STATE $*" >> "$WORK/pause.calls"; }
[ -z "${NODE_ONLY+x}" ] || _PILOT_NODE_ONLY="$NODE_ONLY"
eval "$CLEAR_SRC"
EOF
# a FUNÇÃO real _pilot_pool_topup (a guarda mora nela, não no chamador: as duas chamadas ficam no topo do arquivo, como o selftest grande exige). Os espiões registram a primeira leitura que a função faria depois da guarda
# (a contagem de sessões vivas, bd, gc) e a recusam (rc 1): fora da passada só-nó ela chega nelas e para aí, sem abrir nada.
cat > "$WORK/topup-runner.sh" <<'EOF'
set -euo pipefail
log()  { echo "LOG $*"; }
warn() { echo "WARN $*"; }
_pilot_live_session_count() { echo "LIVE $*" >> "$WORK/topup.calls"; return 1; }
bd() { echo "bd $*" >> "$WORK/topup.calls"; return 1; }
gc() { echo "gc $*" >> "$WORK/topup.calls"; return 1; }
[ -z "${NODE_ONLY+x}" ] || _PILOT_NODE_ONLY="$NODE_ONLY"
eval "$FUNC_TOPUP"
_pilot_pool_topup wa-worker 4
_pilot_pool_topup ps-worker 2
EOF
cat > "$WORK/stall-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
warn() { echo "WARN $*"; }; notify() { echo "NOTIFY $*"; }
GC_CITY="$WORK/city"; DRY_RUN=0; DISPATCHED="${ST_DISPATCHED:-0}"; SMALL_SLOTS=2; BIG_SLOTS=0; _pool_saturated_sweep=0
[ -z "${NODE_ONLY+x}" ] || _PILOT_NODE_ONLY="$NODE_ONLY"
eval "$STALL_SRC"
EOF
# a FUNÇÃO real _pilot_yield_stall_check (a guarda mora nela, não no chamador: a chamada fica no topo do arquivo, como I11 do selftest do priority yield exige), com um arquivo de estado semeado e os contadores de uma varredura
# que NÃO cedeu (DISPATCHED=0, PRIORITY_YIELDED=0): fora da passada só-nó o ramo "não cedeu" APAGA o arquivo (é o que encerra uma sequência); na passada só-nó a função sai antes e o arquivo fica como estava.
# vazio (variável nunca definida) → varredura normal, apaga; falhou/ilegível (função que o awk não leu) → o FATAL lá em cima
cat > "$WORK/ystall-runner.sh" <<'EOF'
set -euo pipefail
warn() { echo "WARN $*"; }; notify() { echo "NOTIFY $*"; }
DRY_RUN=0; DISPATCHED=0; PRIORITY_YIELDED=0; SMALL_SLOTS=2; BIG_SLOTS=0; _PY_WAIT_ID=""
PILOT_YIELD_STALL_FILE="$WORK/ystall.state"
[ -z "${NODE_ONLY+x}" ] || _PILOT_NODE_ONLY="$NODE_ONLY"
eval "$FUNC_YSTALL"
_pilot_yield_stall_check
EOF
echo "── (2) limpa-pausa (ga-nq0jo): a passada só-nó não escreve 'sem pausa' com o disco ainda baixo"
reset; env CLEAR_SRC="$CLEAR_SRC" WORK="$WORK" NODE_ONLY=1 bash "$WORK/clear-runner.sh" >/dev/null 2>&1
[ ! -s "$WORK/pause.calls" ] && ok "node_only=1: a pausa NÃO é limpa" || bad "node_only=1 limpou a pausa ($(cat "$WORK/pause.calls"))"
reset; env CLEAR_SRC="$CLEAR_SRC" WORK="$WORK" NODE_ONLY=0 bash "$WORK/clear-runner.sh" >/dev/null 2>&1
grep -q '^PAUSE_STATE 0 ' "$WORK/pause.calls" 2>/dev/null && ok "node_only=0 (controle): a pausa é limpa como sempre" || bad "node_only=0 não limpou a pausa — o harness não prova nada"
reset; env CLEAR_SRC="$CLEAR_SRC" WORK="$WORK" bash "$WORK/clear-runner.sh" >/dev/null 2>&1
grep -q '^PAUSE_STATE 0 ' "$WORK/pause.calls" 2>/dev/null && ok "variável nunca definida: vale varredura normal (limpa)" || bad "sem _PILOT_NODE_ONLY a pausa não foi limpa"
echo "── (2) top-up de pool: não abre sessão no mini na passada só-nó"
# a linha de log vem junto da ausência de chamadas: um runner que morre antes de chamar a função também deixaria topup.calls vazio e passaria por "nenhum top-up"
reset; TU_RC=0; TU_OUT=$(env FUNC_TOPUP="$FUNC_TOPUP" WORK="$WORK" NODE_ONLY=1 bash "$WORK/topup-runner.sh" 2>&1) || TU_RC=$?
{ [ "$TU_RC" = 0 ] && [ ! -s "$WORK/topup.calls" ] && printf '%s' "$TU_OUT" | grep -q 'sem top-up de wa-worker' && printf '%s' "$TU_OUT" | grep -q 'sem top-up de ps-worker'; } \
  && ok "node_only=1: a função sai na 1a guarda dos dois pools, sem ler nem abrir nada (wa-worker/ps-worker abrem sessão no mini)" || bad "node_only=1 não pulou o top-up (rc=$TU_RC; chamadas: $(tr '\n' ';' < "$WORK/topup.calls" 2>/dev/null); saída: $(printf '%s' "$TU_OUT" | head -c 300))"
reset; TU_RC=0; TU_OUT=$(env FUNC_TOPUP="$FUNC_TOPUP" WORK="$WORK" NODE_ONLY=0 bash "$WORK/topup-runner.sh" 2>&1) || TU_RC=$?
{ [ "$TU_RC" = 0 ] && [ "$(wc -l < "$WORK/topup.calls" 2>/dev/null | tr -d ' ')" = 2 ] && ! printf '%s' "$TU_OUT" | grep -q 'sem top-up de'; } \
  && ok "node_only=0 (controle): a função passa da guarda nos dois pools e chega à leitura das sessões vivas — os espiões enxergam a chamada" || bad "node_only=0 não chegou à leitura das sessões vivas dos dois pools — o harness não prova nada (rc=$TU_RC)"
reset; TU_RC=0; TU_OUT=$(env FUNC_TOPUP="$FUNC_TOPUP" WORK="$WORK" bash "$WORK/topup-runner.sh" 2>&1) || TU_RC=$?
{ [ "$TU_RC" = 0 ] && [ "$(wc -l < "$WORK/topup.calls" 2>/dev/null | tr -d ' ')" = 2 ]; } \
  && ok "variável nunca definida: vale varredura normal (o top-up segue)" || bad "sem _PILOT_NODE_ONLY o top-up foi pulado (rc=$TU_RC)"
echo "── (2) Step 5: varredura só-nó com 0 despachos não conta no streak de estagnação nem o zera"
st() { env STALL_SRC="$STALL_SRC" SANDBOX_PATH="$SANDBOX_PATH" WORK="$WORK" "$@" bash "$WORK/stall-runner.sh" >/dev/null 2>&1; [ -f "$STALL" ] && cat "$STALL" || echo nada; }
reset; [ "$(st NODE_ONLY=0)" = 1 ] && ok "node_only=0, 0 despachos, vaga livre (controle): streak = 1" || bad "o controle do streak não contou"
reset; [ "$(st NODE_ONLY=1)" = nada ] && ok "node_only=1: o streak NÃO é criado" || bad "varredura só-nó entrou no streak de estagnação"
reset; echo 2 > "$STALL"; [ "$(st NODE_ONLY=1)" = 2 ] && ok "node_only=1 com streak 2: continua 2 (nem conta, nem zera)" || bad "varredura só-nó mexeu num streak existente"
reset; echo 2 > "$STALL"; [ "$(st NODE_ONLY=0 ST_DISPATCHED=1)" = nada ] && ok "node_only=0 com despacho (controle): o streak é zerado" || bad "o controle de zerar o streak não zerou"
echo "── (2) cessões consecutivas do priority yield (ga-2lca0l): a passada só-nó não apaga o contador"
yst() { env FUNC_YSTALL="$FUNC_YSTALL" WORK="$WORK" "$@" bash "$WORK/ystall-runner.sh" >/dev/null 2>&1; }
yseed() { printf '3\tga-x\t\n' > "$WORK/ystall.state"; }
reset; yseed; YS_RC=0; yst NODE_ONLY=1 || YS_RC=$?
{ [ "$YS_RC" = 0 ] && [ "$(cat "$WORK/ystall.state" 2>/dev/null)" = "$(printf '3\tga-x\t')" ]; } \
  && ok "node_only=1: o contador de cessões consecutivas fica como estava (PRIORITY_YIELDED é 0 na passada só-nó e o ramo \"não cedeu\" o apagaria)" || bad "node_only=1 mexeu no contador de cessões consecutivas (rc=$YS_RC; arquivo: $(cat "$WORK/ystall.state" 2>/dev/null || echo APAGADO))"
reset; yseed; YS_RC=0; yst NODE_ONLY=0 || YS_RC=$?
{ [ "$YS_RC" = 0 ] && [ ! -e "$WORK/ystall.state" ]; } \
  && ok "node_only=0 (controle): a varredura que não cedeu APAGA o contador, como sempre" || bad "node_only=0 não apagou o contador — o harness não prova nada (rc=$YS_RC)"
reset; yseed; YS_RC=0; yst || YS_RC=$?
{ [ "$YS_RC" = 0 ] && [ ! -e "$WORK/ystall.state" ]; } \
  && ok "variável nunca definida: vale varredura normal (apaga, como o base)" || bad "sem _PILOT_NODE_ONLY o contador não foi apagado (rc=$YS_RC)"

# ── (3) a decisão pré-claim: o que o nó quer, ANTES da claim ──────────────────────────────────────────────────────────────────────────────────────
run_nc() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log()  { echo "LOG $*" >> "$LINES"; }
    warn() { echo "WARN $*" >> "$LINES"; }
    GC_CITY="$WORK/city"; PILOT_NODE_FIRST="${NC_MODE-on}"; eval "$VETO_LINE"
    PILOT_NODE_CAPACITY_BIN="$WORK/fake-capacity.py"; PILOT_NODE_FIRST_LOG="$WORK/shadow.jsonl"; DRY_RUN="${NC_DRY:-0}"
    eval "$PNY_INIT"
    rig_to_builders() { case "$1" in gascity) echo gastown.dog ;; *) echo wa-worker ;; esac; }
    rig_has_persistent_crew_capability() { return 1; }
    eval "$FUNC_VETO"; eval "$FUNC_SHADOW"; eval "$FUNC_EXEMPT"; eval "$FUNC_PRE"; eval "$FUNC_BOUND"; eval "$FUNC_NC"; eval "$FUNC_ON"; eval "$FUNC_WA"; eval "$PNW_INIT"
    c() { local x=0; _pilot_node_only_candidate_pre "$1" || x=$?; printf '%s ' "$x"; }
    eval "$1"
  ) 2>&1 | tail -1
}
J_DOG='{"id":"ga-p1","labels":["story:approved"],"metadata":{"gc.routed_to":"gastown.dog"}}'
J_FIRST='{"id":"ga-p2","labels":["story:approved"],"metadata":{}}'
J_RIG='{"id":"ga-p3","labels":["story:approved"],"metadata":{"story.rig":"gascity"}}'
J_WA='{"id":"wa-p4","labels":["story:approved"],"metadata":{"gc.routed_to":"wa-worker"}}'
J_PS='{"id":"ps-p5","labels":["story:approved"],"metadata":{"gc.routed_to":"ps-worker"}}'
J_WAPFX='{"id":"wa-p6","labels":["story:approved"],"metadata":{}}'
# ga-8okir7: o wa-* sem rota agora é do caminho de WA (nunca chega à regra ga-*); o prefixo de OUTRO store que ainda chega nela é este (ps-* de primeira vista, sem rota e sem story.rig)
J_PSPFX='{"id":"ps-p9","labels":["story:approved"],"metadata":{}}'
J_OTHER='{"id":"ga-p7","labels":["story:approved"],"metadata":{"story.rig":"whatsapp_automation"}}'
J_VETO='{"id":"ga-p8","labels":["story:approved","exec:manual"],"metadata":{"gc.routed_to":"gastown.dog"}}'
J_NOID='{"labels":["story:approved"],"metadata":{"gc.routed_to":"gastown.dog"}}'
echo "── (3) node com vaga: a bead de dog do HQ é candidata; o resto NÃO (e não gasta a consulta ao oráculo)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":4}'
r=$(run_nc 'c "'"${J_WA//\"/\\\"}"'"; c "'"${J_PS//\"/\\\"}"'"; c "'"${J_WAPFX//\"/\\\"}"'"; c "'"${J_PSPFX//\"/\\\"}"'"; c "'"${J_OTHER//\"/\\\"}"'"; c "'"${J_VETO//\"/\\\"}"'"; c "isto não é json"; c "'"${J_NOID//\"/\\\"}"'"; echo'); r="${r% }"
[ "$r" = "1 1 1 1 1 1 1 1" ] && [ "$(calls)" = 0 ] && ok "wa-worker, ps-worker, bead de outro store, de outro rig, com veto, JSON ilegível e sem id: NÃO candidatas, 0 consultas — $r" || bad "um filtro de entrada falhou ($r, consultas=$(calls))"
r=$(run_nc 'c "'"${J_DOG//\"/\\\"}"'"; c "'"${J_FIRST//\"/\\\"}"'"; c "'"${J_RIG//\"/\\\"}"'"; echo'); r="${r% }"
[ "$r" = "0 0 0" ] && [ "$(calls)" = 1 ] && ok "dog roteado, ga-* sem rota e rig→dog: candidatas, UMA consulta à varredura — $r" || bad "bead de dog que o nó quer não é candidata ($r, consultas=$(calls))"
echo "── (3) o terceiro estado nunca vira node"
reset; oracle 1 '{"verdict":"local","reason":"node_full"}'
r=$(run_nc 'c "'"${J_DOG//\"/\\\"}"'"; echo'); [ "${r% }" = 1 ] && ok "veredito local: NÃO é candidata (nada ao mini, nada escrito)" || bad "local virou candidata ($r)"
reset
r=$(run_nc 'c "'"${J_DOG//\"/\\\"}"'"; echo'); [ "${r% }" = 1 ] && ok "oráculo que não rodou (127): NÃO é candidata" || bad "oráculo mudo virou candidata ($r)"
reset; oracle 0 'isto não é json'
r=$(run_nc 'c "'"${J_DOG//\"/\\\"}"'"; echo'); [ "${r% }" = 1 ] && ok "JSON ilegível com exit 0: NÃO é candidata" || bad "JSON ilegível virou candidata ($r)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot"}'
r=$(run_nc 'c "'"${J_DOG//\"/\\\"}"'"; echo'); [ "${r% }" = 1 ] && ok "node sem effective: NÃO é candidata" || bad "node sem effective virou candidata ($r)"
reset; oracle 0 '{"verdict":"node","reason":"free_slot","effective":4}'
r=$(NC_MODE=off run_nc 'c "'"${J_DOG//\"/\\\"}"'"; echo'); [ "${r% }" = 1 ] && [ "$(calls)" = 0 ] && ok "PILOT_NODE_FIRST=off: NÃO é candidata e não consulta" || bad "off virou candidata ($r, consultas=$(calls))"

# ── (4) os pontos de chamada, na ordem ────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── (4) a ordem no dispatcher: pula antes da claim · solta a claim · nunca chega ao despacho ao mini"
L_LANE=$(grep -n '^dispatch_lane() {' "$DISPATCHER" | head -1 | cut -d: -f1)
L_SKIP=$(grep -n '_PILOT_NODE_ONLY:-0}" = "1" \] && ! _pilot_node_only_candidate_pre "\$pick"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_ONE=$(grep -n '    if dispatch_one "\$pick" "\$lane" "\$pick_tier"; then' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_LANE" ] && [ -n "$L_SKIP" ] && [ -n "$L_ONE" ] && [ "$L_LANE" -lt "$L_SKIP" ] && [ "$L_SKIP" -lt "$L_ONE" ] && ok "dispatch_lane: o pulo da não-candidata (linha $L_SKIP) vem ANTES do dispatch_one (linha $L_ONE) — sem claim, sem escrita" || bad "o pulo pré-claim não está em dispatch_lane antes do dispatch_one (lane=$L_LANE skip=$L_SKIP one=$L_ONE)"
L_REL1=$(grep -n 'DISPATCH_RESULT="disk_floor_node_only"' "$DISPATCHER" | sed -n 1p | cut -d: -f1)
L_REL2=$(grep -n 'DISPATCH_RESULT="disk_floor_node_only"' "$DISPATCHER" | sed -n 2p | cut -d: -f1)
L_HOOK=$(grep -n '_pilot_node_first_dispatch "\$STORY_ID" "\$STORY_BEAD_CITY" "\$STORY_TITLE"' "$DISPATCHER" | head -1 | cut -d: -f1)
L_SLING=$(grep -n 'Dispatch via gc sling (HQ beads)' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_REL1" ] && [ -n "$L_REL2" ] && [ -n "$L_HOOK" ] && [ -n "$L_SLING" ] && [ "$L_REL1" -lt "$L_HOOK" ] && [ "$L_HOOK" -lt "$L_REL2" ] && [ "$L_REL2" -lt "$L_SLING" ] \
  && ok "dispatch_one: solta a claim da que o nó não quer ($L_REL1) → gancho do nó ($L_HOOK) → solta a que o nó não ficou ($L_REL2) → despacho ao mini ($L_SLING)" \
  || bad "as duas saídas da passada só-nó não estão na ordem esperada (rel1=$L_REL1 gancho=$L_HOOK rel2=$L_REL2 sling=$L_SLING)"
# as duas chamadas do top-up ficam no topo do arquivo, sem `if` em volta: TOPUP-6 e ga-swnsg3-e do selftest grande reprovam se forem indentadas (a 1a versão desta fatia fez isso: 17 falhas contra as 14 do baseline)
# vazio (linha não achada) → a asserção reprova; falhou/ilegível (dispatcher que o grep não lê) → o FATAL lá em cima, nunca um ok
{ grep -qxF '_pilot_pool_topup "wa-worker" "${PILOT_WA_WORKER_MAX:-4}"' "$DISPATCHER" && grep -qxF '_pilot_pool_topup "ps-worker" "${PILOT_PS_WORKER_MAX:-2}"' "$DISPATCHER" && grep -qxF '_pilot_yield_stall_check || true' "$DISPATCHER"; } \
  && ok "as chamadas do top-up e da checagem de cessões consecutivas estão no topo do arquivo, sem if em volta (o que TOPUP-6 e ga-swnsg3-e do selftest grande e I11 do priority yield exigem); a passada só-nó pula DENTRO das funções" \
  || bad "uma das chamadas (top-up ou checagem de cessões consecutivas) saiu do topo do arquivo (indentada ou alterada): TOPUP-6, ga-swnsg3-e e I11 reprovam — a guarda da passada só-nó mora dentro das funções"

if [ -z "${DF_MUTANT:-}" ] && [ -z "${DF_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo"
  nm=0
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(DF_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  # as âncoras são ASCII de propósito (o python3 lê o argv no locale do shell e o arquivo em UTF-8: uma âncora com acento não casaria sob LC_ALL=C)
  mutant "o gate não liga a passada só-nó" $'  _PILOT_NODE_ONLY=1\n  warn "Disk floor' $'  :\n  warn "Disk floor'
  mutant "o gate liga a passada fora do on" '[ "${PILOT_NODE_FIRST:-off}" = "on" ] && ' ''
  mutant "o gate liga a passada no DRY_RUN" '"on" ] && [ "${DRY_RUN:-0}" != "1" ]; then' '"on" ]; then'
  mutant "o gate liga a passada sem disco confirmado baixo" 'if [ "$_disk_floor_rc" -eq 0 ] && [ "${PILOT_NODE_FIRST:-off}" = "on" ]' 'if [ "${PILOT_NODE_FIRST:-off}" = "on" ]'
  mutant "o limpa-pausa roda na passada só-nó" $'if [ "${_PILOT_NODE_ONLY:-0}" != "1" ]; then\n  _pilot_write_sweep_pause_state 0 "" ""\nfi' '_pilot_write_sweep_pause_state 0 "" ""'
  mutant "o top-up abre sessão na passada só-nó" $'  if [ "${_PILOT_NODE_ONLY:-0}" = "1" ]; then\n    log "  ga-2hd02v.1.20: passada' $'  if false; then\n    log "  ga-2hd02v.1.20: passada'
  mutant "a guarda do top-up volta para um if em volta das chamadas (quebra TOPUP-6 e ga-swnsg3-e)" $'_pilot_pool_topup "wa-worker" "${PILOT_WA_WORKER_MAX:-4}"\n_pilot_pool_topup "ps-worker" "${PILOT_PS_WORKER_MAX:-2}"' $'if [ "${_PILOT_NODE_ONLY:-0}" != "1" ]; then\n  _pilot_pool_topup "wa-worker" "${PILOT_WA_WORKER_MAX:-4}"\n  _pilot_pool_topup "ps-worker" "${PILOT_PS_WORKER_MAX:-2}"\nfi'
  mutant "o streak de estagnação conta a passada só-nó" '[ "$DRY_RUN" != "1" ] && [ "${_PILOT_NODE_ONLY:-0}" != "1" ] && [ "$DISPATCHED" -eq "0" ]' '[ "$DRY_RUN" != "1" ] && [ "$DISPATCHED" -eq "0" ]'
  mutant "o streak de estagnação é zerado pela passada só-nó" 'elif [ "$DRY_RUN" != "1" ] && [ "${_PILOT_NODE_ONLY:-0}" != "1" ] && [ -f "$PILOT_STALL_STATE" ]; then' 'elif [ "$DRY_RUN" != "1" ] && [ -f "$PILOT_STALL_STATE" ]; then'
  mutant "o contador de cessões consecutivas é apagado pela passada só-nó" '    return 0   # ga-2hd02v.1.20: node-only pass leaves' '    :   # ga-2hd02v.1.20: node-only pass leaves'
  mutant "a guarda da checagem de cessões consecutivas volta para um if em volta da chamada (quebra I11 do priority yield)" $'\n_pilot_yield_stall_check || true\n' $'\nif [ "${_PILOT_NODE_ONLY:-0}" != "1" ]; then\n  _pilot_yield_stall_check || true\nfi\n'
  mutant "o helper não pergunta ao nó" $'  _pilot_priority_node_exempt_pre "$_b"\n}' $'  return 0\n}'
  mutant "o helper aceita id de outro store" '    case "$_id" in ga-*) ;; *) return 1 ;; esac' '    :'
  mutant "o helper aceita bead de outro rig" '    { [ -z "$_rig" ] || [ "$_rig" = "null" ]; } || return 1' '    :'
  mutant "o dispatch_lane não pula antes da claim" '    if [ "${_PILOT_NODE_ONLY:-0}" = "1" ] && ! _pilot_node_only_candidate_pre "$pick"; then' '    if false; then'
  mutant "a bead que o nó não quer segue ao mini" $'      DISPATCH_RESULT="disk_floor_node_only"\n      return 1' '      :'
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
