#!/usr/bin/env bash
# pilot-dispatcher.wa-node-pass.selftest.sh — ga-2hd02v.9 (a bead de WA que o nó levaria chega ao gancho do nó, mesmo carimbada pelo mini)
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# POR QUE ESTA FATIA NÃO É A "ISENÇÃO DE YIELD" DO CORPO DA BEAD (revisão adversarial, conferida no artefato em 21/10): 173 de 182 beads de WA abertas que o Pilot cedeu nas varreduras recentes (95%) já levam
#   gc.routed_to=wa-worker, carimbo que o PRÓPRIO Pilot grava ao ceder/enfileirar; o `apply` do wa-node-dispatch.sh recusa (rc 12) toda bead com rota. Isentar essas beads do yield / do teto só as levaria à claim
#   e a um rc 12. O que move carga é uma PASSADA própria de WA no nó (PILOT_WA_NODE_EXEMPT=off|shadow|on, padrão off) que classifica barato (`check`), adota a rota carimbada (tira e, se o nó não ficar, recoloca)
#   e entrega a dispatch_one com a bandeira _PILOT_WA_NODE_PASS=1: sem yield, sem teto, e a bead que o nó não levou é solta SÓ por rótulo — nunca o carimbo nem o braço do mini.
#
# O QUE PROVA: (1) o modo: só `shadow|on` ligam, `on` só com rota label|auto, `shadow` com shadow|label|auto; DRY_RUN desliga, a passada só-nó do disk floor NÃO (ga-2hd02v.3.9: o disco do mini oscila em volta do piso e a só-nó é onde o nó mais precisa receber WA) · (2) a decisão pré-claim, sem escrita: bead com dono, rota
#   que não seja wa-worker, rótulo de veto, node:mini, falta de node:ok no modo label, recusa do probe do pool (ou recusa que não se sabe dizer) = NÃO · (3) a memória de vereditos (mini 6 h, unknown 1 h, solta 15 min,
#   chave id+updated_at) · (4) a sonda `check` (só o rc 0 com JSON node vale) · (5) adotar/devolver a rota com um bd falso COM estado: confirma lendo, restaura no desfazer, nunca toca bead que mudou de dono ·
#   (6) a passada inteira: shadow só observa e grava; on tenta na ordem, para na capacidade (rc 12) e nos orçamentos (sondas, segundos, falhas, vagas do nó), memoriza o que o nó recusou, tira da pista o que ficou ·
#   (7) as regiões VERBATIM de dispatch_one: o bloco do yield (alvo que não é wa-worker do store do WA solta) e o braço do pool (adota antes do gancho; rc 1 devolve a rota e solta; rc 2 não mexe; adotar que falha
#   não chega ao gancho) · (8) o gancho exporta o rc do apply · (9) a ordem dos pontos de chamada · (6b, ga-2hd02v.3.16) o waiter P0/P1 da cessão: a pista dele é percorrida primeiro, ele sem veredito legível (unknown/timeout/erro, sondado ou memorizado) segura a P2+ com veredito node, e o resumo conta as P2+ que foram ao nó com um P0/P1 esperando · (6c, ga-2hd02v.3.16, gate 1) os TRÊS estados do waiter: "não se sabe se ele vai ao nó" (pré-filtro ilegível / recusa que não se lê, apply rc 11 ou que nem chegou ao apply, memória `released`) segura
#   a P2+ — só o motivo DEFINITIVO (dono, veto, rota alheia, node:mini, recusa do pool, apply rc 10, memória mini) o solta.
# COMO RODA: as funções e as regiões são extraídas VERBATIM do dispatcher (awk) e rodam em shells filhos sob `set -euo pipefail`, PATH de sandbox (selftest-sandbox-path.lib.sh: sem gc/bd reais), bd e
#   wa-node-dispatch.sh falsos. Contra um dispatcher sem a fatia o arquivo se recusa a começar — o vermelho honesto.
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (WNP_NO_MUTANTS=1 pula) tem que reprovar este arquivo.
# Variáveis: PILOT_DISPATCHER_PATH · WNP_NO_MUTANTS=1 (ou o argumento --no-mutants: o `mbp-run.sh --repo hq` repassa argumentos ao `bash`, nunca variáveis de ambiente)
set -uo pipefail
[ "${1:-}" != "--no-mutants" ] || WNP_NO_MUTANTS=1
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${WNP_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${WNP_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
# ga-2hd02v.3.16: a classe de prioridade (P0/P1 vs P2+) é a DA CIDADE — a biblioteca de ordem real, não uma cópia (a mesma que o selftest do yield carrega)
WO_LIB="${PILOT_WORK_ORDER_LIB:-$SELF_DIR/scripts/work-order.sh}"
[ -f "$WO_LIB" ] || { echo "FATAL: work-order library not found at $WO_LIB" >&2; exit 2; }
# shellcheck disable=SC1090
. "$WO_LIB" || { echo "FATAL: cannot source $WO_LIB" >&2; exit 2; }
[ -n "${WORK_ORDER_JQ_DEFS:-}" ] || { echo "FATAL: $WO_LIB did not define WORK_ORDER_JQ_DEFS" >&2; exit 2; }

# vazio (a função/região não existe) → texto vazio e o need_fn recusa começar; falhou/ilegível (dispatcher que o awk não lê) → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
need_fn() { local s; s="$(fn_src "$1")"; [ -n "$s" ] || { echo "FATAL: $1() not found in $DISPATCHER (ga-2hd02v.9 not applied)" >&2; exit 2; }; printf '%s' "$s"; }
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
F_MODE="$(need_fn _pilot_wa_node_pass_mode)"; F_PRE="$(need_fn _pilot_wa_node_pass_pre)"
F_MHIT="$(need_fn _pilot_wa_node_pass_memo_hit)"; F_MPUT="$(need_fn _pilot_wa_node_pass_memo_put)"
F_CHECK="$(need_fn _pilot_wa_node_pass_check)"; F_ADOPT="$(need_fn _pilot_wa_node_adopt)"; F_UNADOPT="$(need_fn _pilot_wa_node_unadopt)"
F_PASS="$(need_fn _pilot_wa_node_pass)"; F_VETO="$(need_fn _pilot_node_first_veto)"; F_SPAWN="$(need_fn _pilot_wa_node_spawn_mode)"
F_DECIDE="$(need_fn _pilot_wa_node_decide)"; F_STATE="$(need_fn _pilot_wa_node_pass_state)"
F_CLASS="$(need_fn _pilot_priority_class_of)"
F_HOLD="$(need_fn _pilot_wa_node_pass_hold_for)"; F_WLANE="$(need_fn _pilot_wa_node_pass_waiter_lane)"
F_WHYV="$(need_fn _pilot_wa_node_pass_why_verdict)"
# ga-2hd02v.3.17: opcional DE PROPÓSITO (fn_src, não need_fn): num dispatcher sem o registro de motivos o arquivo tem de reprovar nos testes (6d), não abortar com FATAL
F_PNOTE="$(fn_src _pilot_wa_node_pass_probe_note)"
F_HPRIOR="$(need_fn _pilot_wa_node_pass_hold_prior)"; F_HPUT="$(need_fn _pilot_wa_node_pass_hold_put)"
VETO_LINE="$(grep -E '^PILOT_NODE_FIRST_VETO_LABELS="' "$DISPATCHER" | head -1)"
PWP_INIT="$(grep -E '^(_PWP_[A-Z_]+|_PILOT_WA_NODE_PASS|_PWN_APPLY_RC)=' "$DISPATCHER")"
EXEMPT_LINE="$(grep -E '^PILOT_WA_NODE_EXEMPT="' "$DISPATCHER" | head -1)"
{ [ -n "$VETO_LINE" ] && [ -n "$PWP_INIT" ] && [ -n "$EXEMPT_LINE" ]; } || { echo "FATAL: config lines (veto / _PWP_* / PILOT_WA_NODE_EXEMPT) not found in $DISPATCHER" >&2; exit 2; }
BLOCK_SRC="$(region '^  local _PYS_TARGET _PYS_NATIVE=0$' '^  # ── wa-root-worktree-isolation')"
ARM_SRC="$(region '^        local _RP_NODE_RC=0$' '^        : # pool: leave UNASSIGNED')"
{ [ -n "$BLOCK_SRC" ] && [ -n "$ARM_SRC" ]; } || { echo "FATAL: regiões de dispatch_one não achadas em $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-wa-node-pass-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc" "$WORK/scripts"
# wa-node-dispatch.sh falso: `check <id> --store S` conta a chamada, dorme se houver $WORK/chk.sleep e sai com o rc de $WORK/chk.<id> (padrão 11) imprimindo o JSON coerente; `apply` registra e sai com $WORK/apply.rc (padrão 12)
cat > "$WORK/scripts/wa-node-dispatch.sh" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo "$*" >> "$W/wnd.calls"
cmd="$1"; id="$2"
[ -f "$W/chk.sleep" ] && sleep "$(cat "$W/chk.sleep")"
if [ "$cmd" = apply ]; then rc=12; [ -f "$W/apply.rc" ] && rc=$(cat "$W/apply.rc"); exit "$rc"; fi
rc=11; [ -f "$W/chk.$id" ] && rc=$(cat "$W/chk.$id")
basis=text; [ -f "$W/chk.$id.basis" ] && basis=$(cat "$W/chk.$id.basis")
# ga-2hd02v.3.17: chk.<id>.reasons / chk.<id>.paths trazem a lista JSON que o classificador daria; chk.<id>.raw substitui a saída inteira (o que o jq não lê)
rs='["x"]'; [ -f "$W/chk.$id.reasons" ] && rs=$(cat "$W/chk.$id.reasons")
ps='[]'; [ -f "$W/chk.$id.paths" ] && ps=$(cat "$W/chk.$id.paths")
if [ -f "$W/chk.$id.raw" ]; then cat "$W/chk.$id.raw"; exit "$rc"; fi
case "$rc" in
  0)  rs='[]'; [ -f "$W/chk.$id.reasons" ] && rs=$(cat "$W/chk.$id.reasons"); echo "{\"verdict\":\"node\",\"basis\":\"$basis\",\"reasons\":$rs,\"paths\":$ps}" ;;
  10) echo "{\"verdict\":\"mini\",\"basis\":\"\",\"reasons\":$rs,\"paths\":$ps}" ;;
  11) echo "{\"verdict\":\"unknown\",\"basis\":\"\",\"reasons\":$rs,\"paths\":$ps}" ;;
  99) echo 'isto nao e json' ; rc=0 ;;
esac
exit "$rc"
EOF
chmod +x "$WORK/scripts/wa-node-dispatch.sh"
# bd falso COM estado: a bead é $WORK/bead.json. show imprime [bead]; update --unset-metadata K / --set-metadata K=V mexe no arquivo (a não ser que exista bd.noeffect: aceita e não persiste — o "rc 0 que não gravou");
# bd.show.rc / bd.update.rc != 0 fazem o verbo falhar. Toda chamada vai para bd.calls.
cat > "$WORK/bin/bd" <<'EOF'
#!/bin/sh
W="${SELFTEST_WORK:?}"
echo "$*" >> "$W/bd.calls"
shift 2
verb="$1"; shift
case "$verb" in
  show)
    n=$(cat "$W/bd.show.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$W/bd.show.n"
    [ -f "$W/bd.show.failafter" ] && [ "$n" -gt "$(cat "$W/bd.show.failafter")" ] && exit 1
    [ -f "$W/bd.show.rc" ] && [ "$(cat "$W/bd.show.rc")" != 0 ] && exit "$(cat "$W/bd.show.rc")"
    jq -c '[.]' "$W/bead.json" ;;
  update)
    shift
    [ -f "$W/bd.update.rc" ] && [ "$(cat "$W/bd.update.rc")" != 0 ] && exit "$(cat "$W/bd.update.rc")"
    while [ $# -gt 0 ]; do
      case "$1" in
        --unset-metadata) [ -f "$W/bd.noeffect" ] || { jq --arg k "$2" 'del(.metadata[$k])' "$W/bead.json" > "$W/bead.tmp" && mv "$W/bead.tmp" "$W/bead.json"; }; shift 2 ;;
        --set-metadata) k="${2%%=*}"; v="${2#*=}"; [ -f "$W/bd.noeffect" ] || { jq --arg k "$k" --arg v "$v" '.metadata[$k]=$v' "$W/bead.json" > "$W/bead.tmp" && mv "$W/bead.tmp" "$W/bead.json"; }; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -f "$W/bd.update.partial" ] && exit 1 ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/bd"
sandbox_path_init "$WORK" jq date timeout mkdir dirname cat rm sh awk mv wc tr sleep grep sort || exit 2
reset() { rm -f "$WORK"/chk.* "$WORK"/apply.rc "$WORK"/wnd.calls "$WORK"/bd.calls "$WORK"/bd.show.rc "$WORK"/bd.show.n "$WORK"/bd.show.failafter "$WORK"/bd.update.rc "$WORK"/bd.update.partial "$WORK"/bd.noeffect "$WORK"/d1.* "$WORK"/notes "$WORK"/city/.gc/*.tsv "$WORK"/city/.gc/*.jsonl "$WORK"/block.rel "$WORK"/lines; }
chk() { echo "$2" > "$WORK/chk.$1"; }
wnd_calls() { [ -f "$WORK/wnd.calls" ] && wc -l < "$WORK/wnd.calls" | tr -d ' ' || echo 0; }
bd_writes() { [ -f "$WORK/bd.calls" ] || { echo 0; return; }; grep -c ' update ' "$WORK/bd.calls" || true; }
bead() { printf '%s' "$1" > "$WORK/bead.json"; }
MEMO="$WORK/city/.gc/wa-node-pass-memo.tsv"; PLOG="$WORK/city/.gc/wa-node-exempt.jsonl"

# prelúdio comum dos filhos: funções verbatim + stubs. NÃO usa `set -e` dentro do código de teste além do que o dispatcher usa (ele roda sob set -e; o filho também).
PRELUDE='
  set -euo pipefail
  PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
  log()  { echo "LOG $*" >> "$WORK/lines"; }
  warn() { echo "WARN $*" >> "$WORK/lines"; }
  GC_CITY="$WORK/city"; PILOT_WA_NODE_SCRIPTS="$WORK/scripts"; DRY_RUN="${T_DRY:-0}"; _PILOT_NODE_ONLY="${T_NODE_ONLY:-0}"
  PILOT_WA_NODE_ROUTE="${T_ROUTE-auto}"
  PILOT_WA_NODE_EXEMPT="${T_EXEMPT-on}"
  [ -z "${T_SPAWN+x}" ] || PILOT_WA_NODE_SPAWN="$T_SPAWN"
  [ -z "${T_SLOTS+x}" ] || PILOT_WA_NODE_SLOTS="$T_SLOTS"
  [ -z "${T_PROBES+x}" ] || PILOT_WA_NODE_PASS_PROBES="$T_PROBES"
  [ -z "${T_SECS+x}" ] || PILOT_WA_NODE_PASS_SECS="$T_SECS"
  [ -z "${T_FAILS+x}" ] || PILOT_WA_NODE_PASS_MAX_FAILS="$T_FAILS"
  [ -z "${T_MEMO_TTL+x}" ] || PILOT_WA_NODE_PASS_MINI_TTL="$T_MEMO_TTL"
  eval "$VETO_LINE"; eval "$PWP_INIT"
  PILOT_WA_NODE_PASS_MEMO="$WORK/city/.gc/wa-node-pass-memo.tsv"; PILOT_WA_NODE_PASS_LOG="$WORK/city/.gc/wa-node-exempt.jsonl"
  PILOT_WA_NODE_PASS_HOLD_STATE="${T_HOLD_STATE-$WORK/city/.gc/wa-node-pass-hold.tsv}"
  [ -z "${T_HOLD_MAX+x}" ] || PILOT_WA_NODE_PASS_HOLD_MAX_SWEEPS="$T_HOLD_MAX"
  eval "$F_VETO"; eval "$F_SPAWN"; eval "$F_MODE"; eval "$F_PRE"; eval "$F_MHIT"; eval "$F_MPUT"; eval "$F_CHECK"; eval "$F_STATE"; eval "$F_ADOPT"; eval "$F_UNADOPT"; eval "$F_CLASS"; eval "$F_HOLD"; eval "$F_WLANE"; eval "$F_WHYV"; eval "$F_HPRIOR"; eval "$F_HPUT"; eval "$F_PASS"; eval "$F_PNOTE"
  _PY_WAIT_ID="${T_WAIT-}"; _PY_WAIT_PRIO=1   # o waiter da cessão (ga-5fn5p3), como a varredura do waiter o deixa antes da passada; vazio = nenhum P0/P1 espera
  # T_REFUSAL vale para toda bead; com T_REFUSAL_ID, SÓ para a bead desse id (as demais: ninguém recusa) — é como o waiter tem a recusa ilegível e a P2 não
  _pilot_priority_refusal_of() { local _ri=""; if [ -n "${T_REFUSAL_ID-}" ]; then _ri=$(printf "%s" "$1" | jq -r ".id // empty" 2>/dev/null) || _ri=""; [ "$_ri" = "$T_REFUSAL_ID" ] || return 0; fi; case "${T_REFUSAL-}" in FAIL) return 1 ;; *) printf "%s" "${T_REFUSAL-}"; return 0 ;; esac; }
  _top_candidate() { printf "%s" "$1" | jq -c ".[0]"; }
  _bead_tier() { echo feature; }
  _pilot_sweep_note() { echo "$*" >> "$WORK/notes"; }
  _pilot_dispatch_should_stop() { [ -n "${T_STOP:-}" ]; }
  _dolt_saturated() { [ -n "${T_DOLT:-}" ]; }
  dispatch_one() {
    local _i; _i=$(printf "%s" "$1" | jq -r .id)
    echo "$_i $2 $3 pass=${_PILOT_WA_NODE_PASS:-?}" >> "$WORK/d1.calls"
    _PWN_APPLY_RC=""; [ ! -f "$WORK/d1.apply.$_i" ] || _PWN_APPLY_RC=$(cat "$WORK/d1.apply.$_i")
    DISPATCH_RESULT="r_$_i"
    return "$(cat "$WORK/d1.rc.$_i" 2>/dev/null || echo 1)"
  }
  DISPATCHED=0; SMALL_SLOTS="${T_SLOTS_SMALL:-5}"; BIG_SLOTS="${T_SLOTS_BIG:-5}"
'
# run_t '<código>' — roda o código depois do prelúdio e imprime a ÚLTIMA linha que ele echo-ar
run_t() { ( eval "$PRELUDE"; eval "$1" ) 2>&1 | tail -1; }
jb() { # jb <id> <upd> <rota|-> <labels csv> [owner] — JSON de candidata
  local rt='{}'; [ "$3" = "-" ] || rt="{\"gc.routed_to\":\"$3\"}"
  local lb; lb=$(printf '%s' "$4" | jq -R 'split(",") | map(select(length>0))')
  jq -cn --arg id "$1" --arg upd "$2" --argjson md "$rt" --argjson lb "$lb" --arg ow "${5:-}" '{id:$id,updated_at:$upd,priority:2,status:"open",labels:$lb,metadata:$md} + (if $ow=="" then {} else {assignee:$ow} end)'
}

echo "── (1) o modo: shadow|on só com a rota que o permite; DRY_RUN e disk floor desligam"
mode() { run_t '_pilot_wa_node_pass_mode; echo "$_PWP_MODE"'; }
for combo in "on auto on" "on label on" "on shadow off" "on off off" "on '' off" "on bogus off" "shadow shadow shadow" "shadow auto shadow" "shadow label shadow" "shadow off off" "off auto off" "'' auto off" "ON auto off" "maybe auto off"; do
  eval "set -- $combo"; ex="$1"; rt="$2"; want="$3"
  r=$(T_EXEMPT="$ex" T_ROUTE="$rt" mode)
  [ "$r" = "$want" ] && ok "EXEMPT='$ex' ROUTE='$rt' → $want" || bad "EXEMPT='$ex' ROUTE='$rt' deu '$r' (esperado $want)"
done
r=$(T_DRY=1 mode);       [ "$r" = off ] && ok "DRY_RUN=1: off (a passada sonda e grava memória)" || bad "DRY_RUN=1 ligou a passada ($r)"
r=$(T_NODE_ONLY=1 mode); [ "$r" = on ] && ok "passada só-nó do disk floor em curso + on/auto: on (ga-2hd02v.3.9: o mini no piso de disco é o caso normal, e a passada só escreve depois de veredito node)" || bad "a passada só-nó do disk floor desligou a passada de WA ($r)"
r=$(T_NODE_ONLY=1 T_EXEMPT=shadow mode); [ "$r" = shadow ] && ok "só-nó + shadow: shadow (só leitura e linha-sombra; os dados do shadow não ficam sem as varreduras de disco baixo)" || bad "só-nó + shadow deu '$r'"
r=$(T_NODE_ONLY=1 T_ROUTE=label mode);   [ "$r" = on ] && ok "só-nó + on/label: on" || bad "só-nó + on/label deu '$r'"
r=$(T_NODE_ONLY=1 T_ROUTE=shadow mode);  [ "$r" = off ] && ok "só-nó + on com rota shadow: off (a regra da rota continua valendo na só-nó)" || bad "só-nó + on/shadow deu '$r'"
r=$(T_NODE_ONLY=1 T_EXEMPT=off mode);    [ "$r" = off ] && ok "só-nó + EXEMPT=off: off (o padrão segue desligado)" || bad "só-nó + off deu '$r'"
r=$(T_NODE_ONLY=1 T_DRY=1 mode);         [ "$r" = off ] && ok "só-nó + DRY_RUN: off (DRY_RUN continua vencendo)" || bad "DRY_RUN não venceu na só-nó ($r)"
r=$(run_t 'unset PILOT_WA_NODE_EXEMPT; _pilot_wa_node_pass_mode; echo "$_PWP_MODE"'); [ "$r" = off ] && ok "variável nunca definida: off (o padrão)" || bad "sem a variável ligou ($r)"

echo "── (2) a decisão pré-claim (sem escrita)"
runpre() { local j="$1"; shift; ( eval "$PRELUDE"; _pilot_wa_node_pass_mode; x=0; _pilot_wa_node_pass_pre "$j" || x=$?; echo "$x ${_PWP_WHY:-} stamped=$_PWP_STAMPED" ) 2>&1 | tail -1; }
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved)");                                  [ "$r" = "0  stamped=0" ] && ok "bead livre sem rota: elegível (stamped=0)" || bad "bead livre: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z wa-worker story:approved)");                          [ "$r" = "0  stamped=1" ] && ok "bead carimbada gc.routed_to=wa-worker: elegível e marcada stamped=1" || bad "bead carimbada: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z wa-worker-remote story:approved)");                   [ "$r" = "1 routed:wa-worker-remote stamped=0" ] && ok "rota do nó (wa-worker-remote): NÃO" || bad "rota do nó passou: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z mila-wa story:approved)");                            [ "$r" = "1 routed:mila-wa stamped=0" ] && ok "rota de crew: NÃO" || bad "rota de crew passou: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved mila-wa)");                          [ "$r" = "1 has-owner stamped=0" ] && ok "bead com dono: NÃO" || bad "bead com dono passou: '$r'"
r=$(runpre "$(jb ps-a 2026-10-21T01:00:00Z - story:approved)");                                  [ "$r" = "1 not-wa stamped=0" ] && ok "ps-*: NÃO" || bad "ps-* passou: '$r'"
r=$(runpre "$(jb ga-a 2026-10-21T01:00:00Z - story:approved)");                                  [ "$r" = "1 not-wa stamped=0" ] && ok "ga-*: NÃO (bead de dog tem o caminho dela)" || bad "ga-* passou: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved,node:never)");                       [ "$r" = "1 veto:node:never stamped=0" ] && ok "rótulo de veto (node:never): NÃO" || bad "veto passou: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved,exec:manual)");                      [ "$r" = "1 veto:exec:manual stamped=0" ] && ok "exec:manual: NÃO" || bad "exec:manual passou: '$r'"
r=$(runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved,node:mini)");                        [ "$r" = "1 node:mini stamped=0" ] && ok "node:mini (decisão humana): NÃO, sem gastar sonda" || bad "node:mini passou: '$r'"
r=$(T_REFUSAL=label:story:refino-escalado runpre "$(jb wa-a 2026-10-21T01:00:00Z wa-worker story:approved)"); [ "$r" = "1 refused:label:story:refino-escalado stamped=0" ] && ok "a sonda do pool recusa a bead: NÃO (ninguém a pegaria; o nó também não)" || bad "recusa do pool ignorada: '$r'"
r=$(T_REFUSAL=FAIL runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved)");                   [ "$r" = "1 refusal-unknown stamped=0" ] && ok "recusa que não se sabe dizer: NÃO (nunca 'ninguém recusa')" || bad "recusa ilegível virou elegível: '$r'"
r=$(runpre "isto não é json");                                                                   [ "${r%% *}" = 1 ] && ok "JSON ilegível: NÃO" || bad "JSON ilegível passou: '$r'"
r=$(runpre "");                                                                                  [ "${r%% *}" = 1 ] && ok "entrada vazia: NÃO" || bad "entrada vazia passou: '$r'"
r=$(runpre '{"id":"wa-x y","labels":[],"metadata":{}}');                                         [ "${r%% *}" = 1 ] && ok "id fora de [A-Za-z0-9._-]: NÃO (vai a um arquivo TSV)" || bad "id estranho passou: '$r'"
r=$(T_ROUTE=label runpre "$(jb wa-a 2026-10-21T01:00:00Z - story:approved)");                    [ "$r" = "1 no-node-ok stamped=0" ] && ok "modo label sem node:ok: NÃO" || bad "label sem node:ok passou: '$r'"
r=$(T_ROUTE=label runpre "$(jb wa-a 2026-10-21T01:00:00Z wa-worker story:approved,node:ok)");    [ "$r" = "0  stamped=1" ] && ok "modo label com node:ok: elegível" || bad "label com node:ok: '$r'"

echo "── (3) memória de vereditos: chave id+updated_at, TTL por veredito"
now=$(date +%s)
reset; ( eval "$PRELUDE"; _pilot_wa_node_pass_memo_put wa-a U1 mini; _pilot_wa_node_pass_memo_put wa-b U1 unknown ) >/dev/null 2>&1
mhit() { ( eval "$PRELUDE"; x=0; _pilot_wa_node_pass_memo_hit "$1" "$2" || x=$?; echo "$x ${_PWP_MEMO_V:-}" ) 2>&1 | tail -1; }
[ "$(mhit wa-a U1)" = "0 mini" ] && ok "mini gravado agora: acerto (veredito mini)" || bad "acerto de mini: '$(mhit wa-a U1)'"
[ "$(mhit wa-b U1)" = "0 unknown" ] && ok "unknown gravado agora: acerto" || bad "acerto de unknown: '$(mhit wa-b U1)'"
[ "$(mhit wa-a U2)" = "1 " ] && ok "updated_at mudou (a bead foi editada): sem acerto — sonda de novo" || bad "updated_at diferente acertou: '$(mhit wa-a U2)'"
[ "$(mhit wa-c U1)" = "1 " ] && ok "outra bead: sem acerto" || bad "bead sem memória acertou: '$(mhit wa-c U1)'"
[ "$(mhit wa-a '')" = "1 " ] && ok "sem updated_at não há chave: sem acerto" || bad "sem updated_at acertou"
printf '%s\twa-old\tU1\tmini\n%s\twa-oldu\tU1\tunknown\n' "$((now-21500))" "$((now-3500))" >> "$MEMO"
[ "$(mhit wa-old U1)" = "0 mini" ] && ok "mini com 21500 s (< 6 h): ainda vale" || bad "mini quase vencido não acertou: '$(mhit wa-old U1)'"
[ "$(mhit wa-oldu U1)" = "0 unknown" ] && ok "unknown com 3500 s (< 1 h): ainda vale" || bad "unknown quase vencido não acertou: '$(mhit wa-oldu U1)'"
printf '%s\twa-exp\tU1\tmini\n%s\twa-expu\tU1\tunknown\n' "$((now-21700))" "$((now-3700))" >> "$MEMO"
[ "$(mhit wa-exp U1)" = "1 " ] && ok "mini com 21700 s (> 6 h): vencido, sem acerto" || bad "mini vencido acertou: '$(mhit wa-exp U1)'"
[ "$(mhit wa-expu U1)" = "1 " ] && ok "unknown com 3700 s: vencido (o TTL de unknown é 1 h, não 6 h)" || bad "unknown vencido acertou: '$(mhit wa-expu U1)'"
printf '%s\twa-rel\tU1\treleased\n' "$((now-100))" >> "$MEMO"
[ "$(mhit wa-rel U1)" = "0 released" ] && ok "released (solta há 100 s): acerto" || bad "released recente não acertou: '$(mhit wa-rel U1)'"
printf '%s\twa-rel2\tU1\treleased\n' "$((now-1000))" >> "$MEMO"
[ "$(mhit wa-rel2 U1)" = "1 " ] && ok "released com 1000 s: vencido (15 min)" || bad "released vencido acertou"
# sampled (a bead que o shadow do passo da carimbada já mediu, ga-w7qwl1.2.6): TTL próprio de 6 h, e NÃO o 0 dos veredictos que ninguém conhece
printf '%s\twa-smp\tU1\tsampled\n%s\twa-smp2\tU1\tsampled\n' "$((now-21500))" "$((now-21700))" >> "$MEMO"
[ "$(mhit wa-smp U1)" = "0 sampled" ] && ok "sampled com 21500 s (< 6 h): ainda vale" || bad "sampled recente não acertou: '$(mhit wa-smp U1)'"
[ "$(mhit wa-smp2 U1)" = "1 " ] && ok "sampled com 21700 s (> 6 h): vencido" || bad "sampled vencido acertou: '$(mhit wa-smp2 U1)'"
r=$(PILOT_WA_NODE_PASS_SAMPLED_TTL=100 mhit wa-smp U1); [ "$r" = "1 " ] && ok "PILOT_WA_NODE_PASS_SAMPLED_TTL=100: sampled com 21500 s vence" || bad "TTL do sampled não valeu: '$r'"
r=$(PILOT_WA_NODE_PASS_SAMPLED_TTL=abc mhit wa-smp U1); [ "$r" = "0 sampled" ] && ok "TTL do sampled ilegível: vale o padrão (6 h)" || bad "TTL ilegível do sampled: '$r'"
printf '%s\twa-lw\tU1\tmini\n%s\twa-lw\tU1\treleased\n' "$((now-5000))" "$((now-10))" >> "$MEMO"
[ "$(mhit wa-lw U1)" = "0 released" ] && ok "duas linhas da mesma bead: a ÚLTIMA vale" || bad "a última linha não valeu: '$(mhit wa-lw U1)'"
printf 'lixo sem tabs\n\t\t\t\n' >> "$MEMO"
[ "$(mhit wa-a U1)" = "0 mini" ] && ok "linha ilegível no arquivo não derruba a leitura nem apaga as outras" || bad "linha ilegível quebrou a leitura"
rm -f "$MEMO"; [ "$(mhit wa-a U1)" = "1 " ] && ok "sem arquivo: sem memória (sonda)" || bad "sem arquivo acertou"
mkdir -p "$MEMO"; [ "$(mhit wa-a U1)" = "1 " ] && ok "arquivo ilegível (é uma pasta): sem acerto — a sonda decide, nunca 'mini' por chute" || bad "arquivo ilegível acertou"
rmdir "$MEMO"
mkdir -p "$MEMO"; rm -f "$WORK/lines"
( eval "$PRELUDE"; x=0; _pilot_wa_node_pass_memo_put wa-a U1 mini || x=$?; echo "$x" ) >"$WORK/put.out" 2>&1
[ "$(tail -1 "$WORK/put.out")" = 0 ] && grep -q 'WARN' "$WORK/lines" && ok "memória que não grava (o caminho é uma pasta): avisa e devolve 0 — a sonda é só orçamento" || bad "falha ao gravar memória derrubou ou ficou muda ($(tail -1 "$WORK/put.out"))"
rmdir "$MEMO"
# aparar: > 5000 linhas ficam só as de menos de 24 h
awk -v now="$now" 'BEGIN{for(i=0;i<5100;i++) printf "%d\twa-old%d\tU1\tmini\n", now-200000, i; printf "%d\twa-fresh\tU1\tmini\n", now-100}' > "$MEMO"
( eval "$PRELUDE"; _pilot_wa_node_pass_memo_put wa-new U1 mini ) >/dev/null 2>&1
[ "$(wc -l < "$MEMO" | tr -d ' ')" = 2 ] && grep -q 'wa-fresh' "$MEMO" && grep -q 'wa-new' "$MEMO" && ! grep -q 'wa-old' "$MEMO" && ok "arquivo com > 5000 linhas é aparado: ficam só as de menos de 24 h (wa-fresh e a nova)" || bad "aparo da memória: $(wc -l < "$MEMO") linhas"
rm -f "$MEMO"

echo "── (4) a sonda: só o rc 0 com JSON node vale"
ck() { ( eval "$PRELUDE"; _pilot_wa_node_pass_check "$1" "$WORK/store"; echo "$_PWP_V ${_PWP_BASIS:-}" ) 2>&1 | tail -1; }
reset; chk wa-a 0;  [ "$(ck wa-a)" = "node text" ]  && ok "rc 0 + JSON node: node (basis text)" || bad "rc 0: '$(ck wa-a)'"
reset; chk wa-a 10; [ "$(ck wa-a)" = "mini " ]      && ok "rc 10: mini" || bad "rc 10: '$(ck wa-a)'"
reset; chk wa-a 11; [ "$(ck wa-a)" = "unknown " ]   && ok "rc 11: unknown" || bad "rc 11: '$(ck wa-a)'"
reset; chk wa-a 99; [ "$(ck wa-a)" = "error " ]     && ok "rc 0 com saída que não é JSON de node: error (nunca node)" || bad "saída ilegível com rc 0: '$(ck wa-a)'"
reset; chk wa-a 124; [ "$(ck wa-a)" = "timeout " ]  && ok "rc 124: timeout" || bad "rc 124: '$(ck wa-a)'"
reset; chk wa-a 2;  [ "$(ck wa-a)" = "error " ]     && ok "rc 2 (uso): error" || bad "rc 2: '$(ck wa-a)'"
reset; [ "$(ck wa-a)" = "unknown " ] && ok "sem arquivo de rc, o falso responde 11: unknown" || bad "padrão do falso: '$(ck wa-a)'"
reset; r=$( ( eval "$PRELUDE"; PILOT_WA_NODE_SCRIPTS="$WORK/nao-existe"; _pilot_wa_node_pass_check wa-a "$WORK/store"; echo "$_PWP_V" ) 2>&1 | tail -1 ); [ "$r" = missing ] && ok "wa-node-dispatch.sh ausente: missing (a passada para)" || bad "script ausente: '$r'"
reset; chk wa-a 0; ck wa-a >/dev/null; [ "$(cat "$WORK/wnd.calls")" = "check wa-a --store $WORK/store" ] && ok "a sonda é 'check <id> --store <loja>' (só leitura: nunca apply)" || bad "argv da sonda: '$(cat "$WORK/wnd.calls")'"

echo "── (5) adotar e devolver a rota (bd falso com estado)"
BEAD_FREE='{"id":"wa-a","status":"open","metadata":{}}'
BEAD_STAMPED='{"id":"wa-a","status":"open","metadata":{"gc.routed_to":"wa-worker"}}'
ad() { ( eval "$PRELUDE"; x=0; _pilot_wa_node_adopt wa-a "$WORK/store" || x=$?; echo "$x adopted=$_PWP_ADOPTED route=$(jq -r '.metadata["gc.routed_to"] // "-"' "$WORK/bead.json")" ) 2>&1 | tail -1; }
reset; bead "$BEAD_STAMPED"; r=$(ad); [ "$r" = "0 adopted=1 route=-" ] && [ "$(bd_writes)" = 1 ] && ok "carimbada: tira o carimbo (UMA escrita), confirma lendo e marca adotada — $r" || bad "adotar carimbada: '$r' escritas=$(bd_writes)"
reset; bead "$BEAD_FREE"; r=$(ad); [ "$r" = "0 adopted=0 route=-" ] && [ "$(bd_writes)" = 0 ] && ok "já sem rota: nada a tirar, nenhuma escrita" || bad "adotar livre: '$r' escritas=$(bd_writes)"
for st in '{"id":"wa-a","status":"in_progress","metadata":{"gc.routed_to":"wa-worker"}}' '{"id":"wa-a","status":"open","assignee":"mila-wa","metadata":{"gc.routed_to":"wa-worker"}}' '{"id":"wa-a","status":"open","metadata":{"gc.routed_to":"wa-worker-remote"}}' '{"id":"wa-a","status":"open","metadata":{"gc.routed_to":"mila-wa"}}' '{"id":"wa-OUTRA","status":"open","metadata":{}}'; do
  reset; bead "$st"; r=$(ad)
  [ "${r%% *}" = 1 ] && [ "$(bd_writes)" = 0 ] && ok "bead que não é mais livre/mudou de dono ou rota ($(printf '%s' "$st" | jq -r '[.status,(.assignee//"-"),(.metadata["gc.routed_to"]//"-"),.id]|join("/")')): 1, SEM escrever" || bad "adotou bead alheia: '$r' escritas=$(bd_writes)"
done
reset; bead "$BEAD_STAMPED"; echo 1 > "$WORK/bd.show.rc"; r=$(ad); [ "${r%% *}" = 1 ] && [ "$(bd_writes)" = 0 ] && ok "bd show falhou: 1, sem escrever (não sei o que há lá)" || bad "show falhou e adotou: '$r'"
reset; bead "$BEAD_STAMPED"; echo 1 > "$WORK/bd.update.rc"; r=$(ad); [ "${r%% *}" = 1 ] && jq -e '.metadata["gc.routed_to"]=="wa-worker"' "$WORK/bead.json" >/dev/null && ok "a escrita falhou: 1 e o carimbo continua onde estava" || bad "escrita falha: '$r'"
reset; bead "$BEAD_STAMPED"; : > "$WORK/bd.noeffect"; r=$(ad); [ "${r%% *}" = 1 ] && jq -e '.metadata["gc.routed_to"]=="wa-worker"' "$WORK/bead.json" >/dev/null && ok "rc 0 que NÃO gravou (a releitura ainda vê o carimbo): 1 — o efeito, não o retorno" || bad "confiou no rc: '$r'"
reset; bead "$BEAD_STAMPED"; : > "$WORK/bd.update.partial"; r=$(ad); [ "${r%% *}" = 1 ] && jq -e '.metadata["gc.routed_to"]=="wa-worker"' "$WORK/bead.json" >/dev/null && [ "$(bd_writes)" = 2 ] \
  && ok "a escrita PEGOU mas o bd reportou falha (prazo estourado): adotar devolve 1 e RECOLOCA o carimbo (2 escritas: tirar + devolver)" || bad "escrita que pegou e reportou falha: '$r' escritas=$(bd_writes) rota=$(jq -r '.metadata["gc.routed_to"] // "-"' "$WORK/bead.json")"
reset; bead "$BEAD_STAMPED"; echo 1 > "$WORK/bd.show.failafter"; r=$(ad); [ "${r%% *}" = 1 ] && jq -e '(.metadata["gc.routed_to"] // "-")=="-"' "$WORK/bead.json" >/dev/null && [ "$(bd_writes)" = 1 ] \
  && ok "a escrita pegou e a RELEITURA falhou: adotar devolve 1 e, sem ler, NÃO escreve de novo (a bead sem rota é inerte) — $r" || bad "releitura falha após a escrita: '$r' escritas=$(bd_writes)"
un() { ( eval "$PRELUDE"; _PWP_ADOPTED="${1:-1}"; x=0; _pilot_wa_node_unadopt wa-a "$WORK/store" || x=$?; echo "$x adopted=$_PWP_ADOPTED route=$(jq -r '.metadata["gc.routed_to"] // "-"' "$WORK/bead.json")" ) 2>&1 | tail -1; }
reset; bead "$BEAD_FREE"; r=$(un 1); [ "$r" = "0 adopted=0 route=wa-worker" ] && ok "devolver: bead ainda livre → recoloca gc.routed_to=wa-worker" || bad "devolver: '$r'"
reset; bead "$BEAD_FREE"; r=$(un 0); [ "$r" = "0 adopted=0 route=-" ] && [ "$(bd_writes)" = 0 ] && ok "devolver sem ter adotado: no-op, nenhuma escrita" || bad "devolver sem adotar escreveu: '$r'"
for st in '{"id":"wa-a","status":"open","assignee":"wa-worker-remote-1","metadata":{}}' '{"id":"wa-a","status":"in_progress","metadata":{}}' '{"id":"wa-a","status":"open","metadata":{"gc.routed_to":"wa-worker-remote"}}'; do
  reset; bead "$st"; r=$(un 1)
  [ "$(bd_writes)" = 0 ] && ok "devolver não pisa em bead que mudou ($(printf '%s' "$st" | jq -r '[.status,(.assignee//"-"),(.metadata["gc.routed_to"]//"-")]|join("/")')): 0 escritas (o nó pode ter ficado com ela)" || bad "devolver pisou numa bead alheia: '$r' escritas=$(bd_writes)"
done
reset; bead "$BEAD_FREE"; echo 1 > "$WORK/bd.show.rc"; r=$(un 1); [ "$(bd_writes)" = 0 ] && ok "devolver com bd show falho: não escreve (inerte: a bead sem rota é o estado de primeira vista)" || bad "devolver escreveu sem ler"

echo "── (6) a passada inteira"
S3="[$(jb wa-m1 U1 wa-worker story:approved),$(jb wa-n1 U1 wa-worker story:approved),$(jb wa-n2 U1 wa-worker story:approved)]"
pass() { # pass '<small json>' [big json] → imprime estado final
  local s="$1" b="${2:-[]}"
  SJ="$s" BJ="$b" run_t 'SMALL_CANDIDATES="$SJ"; BIG_CANDIDATES="$BJ"; SMALL_COUNT=$(echo "$SMALL_CANDIDATES"|jq length 2>/dev/null || echo 0); BIG_COUNT=$(echo "$BIG_CANDIDATES"|jq length 2>/dev/null || echo 0)
    _pilot_wa_node_pass; echo "S=$(echo "$SMALL_CANDIDATES"|jq -r "[.[].id]|join(\",\")" 2>/dev/null || echo "?") B=$(echo "$BIG_CANDIDATES"|jq -r "[.[].id]|join(\",\")" 2>/dev/null || echo "?") SS=$SMALL_SLOTS BS=$BIG_SLOTS D=$DISPATCHED C=$SMALL_COUNT/$BIG_COUNT PASSFLAG=${_PILOT_WA_NODE_PASS:-0}"'
}
d1() { [ -f "$WORK/d1.calls" ] && tr '\n' ';' < "$WORK/d1.calls" || printf -- '-'; }
memo_of() { [ -f "$MEMO" ] && awk -F'\t' '{print $2":"$4}' "$MEMO" | sort | tr '\n' ',' || printf -- '-'; }

# shadow: observa e grava, não escreve em bead nenhuma e não mexe na pista
reset; chk wa-m1 10; chk wa-n1 0; chk wa-n2 11
r=$(T_EXEMPT=shadow pass "$S3")
[ "$r" = "S=wa-m1,wa-n1,wa-n2 B= SS=5 BS=5 D=0 C=3/0 PASSFLAG=0" ] && ok "shadow: a pista e as vagas ficam como estavam — $r" || bad "shadow mexeu no estado: $r"
[ "$(d1)" = "-" ] && [ ! -f "$WORK/bd.calls" ] && ok "shadow: dispatch_one nunca chamado e NENHUMA chamada ao bd" || bad "shadow dispatchou ou escreveu (d1=$(d1) bd=$(cat "$WORK/bd.calls" 2>/dev/null | tr '\n' '|'))"
[ "$(wnd_calls)" = 3 ] && ! grep -q '^apply' "$WORK/wnd.calls" && ok "shadow: 3 sondas, todas 'check' (nenhum apply)" || bad "shadow: sondas=$(wnd_calls) $(tr '\n' '|' < "$WORK/wnd.calls")"
[ "$(memo_of)" = "wa-m1:mini,wa-n2:unknown," ] && ok "shadow: mini e unknown viram memória; o node NÃO (ele precisa ser sondado de novo quando houver vaga)" || bad "memória do shadow: '$(memo_of)'"
jq -e 'select(.event=="wa-node-pass-shadow" and .bead=="wa-n1" and .stamped==1)' "$PLOG" >/dev/null 2>&1 && jq -e 'select(.event=="wa-node-pass-summary" and .mode=="shadow" and .node==1 and .mini==1 and .unknown==1 and .probed==3 and .kept==0)' "$PLOG" >/dev/null 2>&1 \
  && ok "shadow: grava a linha 'iria ao nó' (stamped=1) e o resumo da varredura (probed=3 node=1 mini=1 unknown=1 kept=0)" || bad "jsonl do shadow: $(cat "$PLOG" 2>/dev/null | cut -c1-300)"

# on: tenta na ordem; o 1º node fica (pool: 1 vaga no nó) e a passada para por limite de vagas
reset; chk wa-m1 10; chk wa-n1 0; chk wa-n2 0; echo 0 > "$WORK/d1.rc.wa-n1"
r=$(pass "$S3")
[ "$r" = "S=wa-m1,wa-n2 B= SS=4 BS=5 D=1 C=2/0 PASSFLAG=0" ] && ok "on: n1 ficou com o nó → sai da pista, a vaga da pista cai (5→4), DISPATCHED +1, a bandeira volta a 0 — $r" || bad "on, estado final: $r"
[ "$(d1)" = "wa-n1 small feature pass=1;" ] && ok "on: dispatch_one só para n1, com a bandeira _PILOT_WA_NODE_PASS=1 (m1 é mini e n2 fica pelo limite de 1 vaga do nó)" || bad "on, chamadas: $(d1)"
[ "$(cat "$WORK/notes" 2>/dev/null)" = "wa-n1 0 r_wa-n1" ] && ok "on: o desfecho de n1 entra no resumo da varredura (rc 0)" || bad "nota do desfecho: '$(cat "$WORK/notes" 2>/dev/null)'"
# N vagas (modo pilot, 2): n1 e n2 ficam
reset; chk wa-n1 0; chk wa-n2 0; echo 0 > "$WORK/d1.rc.wa-n1"; echo 0 > "$WORK/d1.rc.wa-n2"
r=$(T_SPAWN=pilot T_SLOTS=2 pass "$S3")
[ "$(d1)" = "wa-n1 small feature pass=1;wa-n2 small feature pass=1;" ] && ok "modo pilot com 2 vagas: n1 e n2 ficam (o limite por varredura é _PWN_SLOTS)" || bad "2 vagas: $(d1) / $r"
reset; chk wa-n1 0; chk wa-n2 0; echo 0 > "$WORK/d1.rc.wa-n1"; echo 0 > "$WORK/d1.rc.wa-n2"
r=$(DISPATCH_TO_CAPACITY=0 T_SPAWN=pilot T_SLOTS=2 pass "$S3"); [ "$(d1)" = "wa-n1 small feature pass=1;" ] && ok "DISPATCH_TO_CAPACITY=0 (uma bead por pista): com 2 vagas do nó, só n1 fica" || bad "DISPATCH_TO_CAPACITY=0 não limitou a 1: $(d1)"
# rc 12 do apply = o nó está cheio → para sem memorizar a bead
reset; chk wa-n1 0; chk wa-n2 0; echo 1 > "$WORK/d1.rc.wa-n1"; echo 12 > "$WORK/d1.apply.wa-n1"
r=$(pass "$S3")
[ "$(d1)" = "wa-n1 small feature pass=1;" ] && ok "apply rc 12 (nó cheio): a passada PARA — n2 nem é tentada" || bad "rc 12 não parou: $(d1)"
! grep -q 'wa-n1' "$MEMO" 2>/dev/null && ok "rc 12: a bead NÃO entra na memória (capacidade é do nó, não da bead)" || bad "rc 12 memorizou a bead: $(memo_of)"
jq -e 'select(.event=="wa-node-pass-summary" and .stopped=="capacity" and .kept==0 and .released==1)' "$PLOG" >/dev/null 2>&1 && ok "resumo: stopped=capacity released=1" || bad "resumo do rc 12: $(tail -1 "$PLOG" 2>/dev/null | cut -c1-300)"
# rc 10 / 11 do apply → memoriza e segue; guarda sem apply (vazio) → memoriza 'released' e segue
reset; chk wa-m1 0; chk wa-n1 0; chk wa-n2 0; for i in wa-m1 wa-n1 wa-n2; do echo 1 > "$WORK/d1.rc.$i"; done; echo 10 > "$WORK/d1.apply.wa-m1"; echo 11 > "$WORK/d1.apply.wa-n1"
r=$(pass "$S3")
[ "$(memo_of)" = "wa-m1:mini,wa-n1:unknown,wa-n2:released," ] && ok "apply 10→mini, 11→unknown, e guarda antes do apply (vazio)→released; a passada continua até acabar as falhas permitidas" || bad "memória após falhas: '$(memo_of)' / d1=$(d1)"
reset; for i in a b c d e; do chk wa-$i 0; echo 1 > "$WORK/d1.rc.wa-$i"; done
L5="[$(jb wa-a U1 wa-worker x),$(jb wa-b U1 wa-worker x),$(jb wa-c U1 wa-worker x),$(jb wa-d U1 wa-worker x),$(jb wa-e U1 wa-worker x)]"
pass "$L5" >/dev/null
[ "$(grep -c . "$WORK/d1.calls")" = 3 ] && ok "no máximo 3 falhas por varredura (padrão): 5 candidatas, 3 tentativas" || bad "teto de falhas: $(d1)"
reset; for i in a b c d e; do chk wa-$i 0; echo 1 > "$WORK/d1.rc.wa-$i"; done
T_FAILS=1 pass "$L5" >/dev/null; [ "$(grep -c . "$WORK/d1.calls")" = 1 ] && ok "PILOT_WA_NODE_PASS_MAX_FAILS=1: 1 tentativa" || bad "MAX_FAILS=1: $(d1)"
reset; for i in a b c d e; do chk wa-$i 0; echo 1 > "$WORK/d1.rc.wa-$i"; done
T_FAILS=zzz pass "$L5" >/dev/null; [ "$(grep -c . "$WORK/d1.calls")" = 3 ] && ok "teto de falhas ilegível volta ao padrão (3)" || bad "MAX_FAILS ilegível: $(d1)"
# outro rc do apply (13, 124...) = a escrita pode ter acontecido → para sem memorizar
reset; chk wa-n1 0; chk wa-n2 0; echo 1 > "$WORK/d1.rc.wa-n1"; echo 13 > "$WORK/d1.apply.wa-n1"
pass "$S3" >/dev/null
[ "$(d1)" = "wa-n1 small feature pass=1;" ] && ! grep -q 'wa-n1' "$MEMO" 2>/dev/null && ok "apply rc 13 (incerto): para e não memoriza" || bad "rc 13: d1=$(d1) memo=$(memo_of)"

# orçamentos de sonda
reset; for i in a b c d e; do chk wa-$i 10; done
T_PROBES=2 pass "$L5" >/dev/null; [ "$(wnd_calls)" = 2 ] && ok "PILOT_WA_NODE_PASS_PROBES=2: só 2 sondas" || bad "teto de sondas: $(wnd_calls)"
jq -e 'select(.event=="wa-node-pass-summary" and .stopped=="budget-probes" and .probed==2)' "$PLOG" >/dev/null 2>&1 && ok "resumo: stopped=budget-probes" || bad "resumo do teto: $(tail -1 "$PLOG" | cut -c1-300)"
reset; for i in a b c d e; do chk wa-$i 10; done
T_PROBES=zzz pass "$L5" >/dev/null; [ "$(wnd_calls)" = 5 ] && ok "teto de sondas ilegível volta ao padrão (30): as 5 são sondadas" || bad "teto ilegível: $(wnd_calls)"
# o padrão é 30 (ga-2hd02v.3.17): com 35 elegíveis e o teto sem valor, a passada sonda 30 e para por orçamento de sondas (com 12 pararia em 12)
reset; L35="["; for i in $(seq 1 35); do chk wa-q$i 10; L35="$L35$([ "$i" -gt 1 ] && echo ,)$(jb wa-q$i U1 wa-worker x)"; done; L35="$L35]"
pass "$L35" >/dev/null; [ "$(wnd_calls)" = 30 ] && ok "sem PILOT_WA_NODE_PASS_PROBES: 30 sondas de 35 elegíveis" || bad "padrão de sondas: $(wnd_calls)"
jq -e 'select(.event=="wa-node-pass-summary" and .stopped=="budget-probes" and .probed==30)' "$PLOG" >/dev/null 2>&1 && ok "resumo: stopped=budget-probes com probed=30" || bad "resumo do padrão: $(tail -1 "$PLOG" | cut -c1-300)"
# memória evita re-sondar a cabeça da fila: 2ª varredura (outro processo) não sonda as mesmas
reset; for i in a b c d e; do chk wa-$i 10; done
T_PROBES=3 pass "$L5" >/dev/null; pass "$L5" >/dev/null
[ "$(wnd_calls)" = 5 ] && ok "memória: 1ª varredura sonda a,b,c (teto 3); a 2ª pula as 3 memorizadas e sonda d,e — a fila anda em vez de re-sondar a cabeça" || bad "a fila não andou: sondas=$(wnd_calls) $(tr '\n' ' ' < "$WORK/wnd.calls")"
# segundos
reset; for i in a b c; do chk wa-$i 10; done; echo 2 > "$WORK/chk.sleep"
pass "$(echo "$L5" | jq -c '.[0:3]')" >/dev/null 2>&1; n_slow=$(wnd_calls)
reset; for i in a b c; do chk wa-$i 10; done; echo 2 > "$WORK/chk.sleep"
T_SECS=2 pass "$(echo "$L5" | jq -c '.[0:3]')" >/dev/null 2>&1
[ "$n_slow" = 3 ] && [ "$(wnd_calls)" = 1 ] && ok "orçamento em SEGUNDOS: com 2 s por sonda e PILOT_WA_NODE_PASS_SECS=2, para depois da 1ª (sem ele, as 3; SECONDS tem granularidade de 1 s, por isso 2 e não 1)" || bad "orçamento de segundos: sem=$n_slow com=$(wnd_calls)"
reset; for i in a b c; do chk wa-$i 10; done
T_SECS=0 pass "$(echo "$L5" | jq -c '.[0:3]')" >/dev/null; [ "$(wnd_calls)" = 0 ] && ok "PILOT_WA_NODE_PASS_SECS=0: nenhuma sonda (0 segundos de orçamento)" || bad "SECS=0 sondou"
# dispatch halted
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
T_STOP=1 pass "$S3" >/dev/null; [ "$(wnd_calls)" = 0 ] && [ "$(d1)" = "-" ] && ok "fase de despacho já parada (_pilot_dispatch_should_stop): nem sonda nem despacha" || bad "passada correu com o despacho parado"
# Dolt saturado: a sonda (leitura) corre, mas nenhuma escrita (dispatch_one) começa
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
T_DOLT=1 pass "$S3" >/dev/null; [ "$(d1)" = "-" ] && [ "$(wnd_calls)" -ge 1 ] && ok "Dolt saturado agora (_dolt_saturated): sondou, mas NÃO despachou" || bad "despachou com o Dolt saturado: $(d1)"
jq -e 'select(.event=="wa-node-pass-summary" and .stopped=="dolt-saturated" and .kept==0)' "$PLOG" >/dev/null 2>&1 && ok "resumo: stopped=dolt-saturated" || bad "resumo do Dolt saturado: $(tail -1 "$PLOG" 2>/dev/null | cut -c1-300)"
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
r=$(PILOT_DOLT_SATURATED_AT_START=1 pass "$S3"); [ "$(d1)" = "-" ] && ok "Dolt saturado NO INÍCIO da varredura: não despacha" || bad "despachou com PILOT_DOLT_SATURATED_AT_START=1: $(d1)"
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
r=$(PILOT_DOLT_SATURATED_AT_START=0 pass "$S3"); [ "$(d1)" = "wa-n1 small feature pass=1;" ] && ok "Dolt são (START=0, _dolt_saturated=1): despacha" || bad "Dolt são não despachou: $(d1)"
# pista cheia
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
T_SLOTS_SMALL=0 pass "$S3" >/dev/null; [ "$(d1)" = "-" ] && ok "pista sem vaga (0): a passada on não despacha nela" || bad "despachou em pista cheia: $(d1)"
# filtros de entrada: nada disso é sondado
reset; chk wa-x 0
MIX="[$(jb wa-own U1 - x mila-wa),$(jb ps-p U1 - x),$(jb wa-rt U1 mila-wa x),$(jb wa-vt U1 - x,node:never),$(jb wa-mn U1 - x,node:mini)]"
pass "$MIX" >/dev/null; [ "$(wnd_calls)" = 0 ] && ok "com dono, ps-*, rota de crew, veto, node:mini: 0 sondas" || bad "sondou o que não podia: $(wnd_calls)"
reset; chk wa-l1 0; chk wa-l2 0
r=$(T_ROUTE=label pass "[$(jb wa-l1 U1 wa-worker x),$(jb wa-l2 U1 wa-worker x,node:ok)]" "[]"); [ "$(wnd_calls)" = 1 ] && grep -q 'wa-l2' "$WORK/wnd.calls" && ok "modo label: só a que tem node:ok é sondada" || bad "modo label sondou a errada: $(tr '\n' ' ' < "$WORK/wnd.calls")"
reset; chk wa-l2 0 ; echo text > "$WORK/chk.wa-l2.basis"; echo 0 > "$WORK/d1.rc.wa-l2"
T_ROUTE=label pass "[$(jb wa-l2 U1 wa-worker x,node:ok)]" >/dev/null; [ "$(d1)" = "-" ] && ok "modo label com veredito node por base 'text' (não pela etiqueta): não tenta — o apply recusaria por base" || bad "modo label tentou com base text: $(d1)"
# pista big e ordem small → big; o que ficou na big sai da big
reset; chk wa-b1 0; echo 0 > "$WORK/d1.rc.wa-b1"
r=$(pass "[]" "[$(jb wa-b1 U1 wa-worker x)]"); [ "$r" = "S= B= SS=5 BS=4 D=1 C=0/0 PASSFLAG=0" ] && [ "$(d1)" = "wa-b1 big feature pass=1;" ] && ok "pista big: a bead ficou no nó, sai da pista big e consome a vaga da big — $r" || bad "pista big: $r / $(d1)"
# pista ilegível
reset; r=$(pass "isto não é json"); case "$r" in *"D=0"*) ok "pista ilegível: a passada não faz nada (e não derruba)" ;; *) bad "pista ilegível: $r" ;; esac
# DRY_RUN
reset; chk wa-n1 0; T_DRY=1 pass "$S3" >/dev/null; [ "$(wnd_calls)" = 0 ] && ok "DRY_RUN: a passada não corre" || bad "DRY_RUN sondou"

# ga-2hd02v.3.9 — a passada na varredura SÓ-NÓ do disk floor (_PILOT_NODE_ONLY=1). Medido 22/10 07:29: o log dizia 'INERTE ... passada só-nó=1' e a bead node:ok carimbada wa-worker nunca ia ao Hetzner.
reset; chk wa-m1 10; chk wa-n1 0; chk wa-n2 0; echo 0 > "$WORK/d1.rc.wa-n1"
r=$(T_NODE_ONLY=1 pass "$S3")
[ "$r" = "S=wa-m1,wa-n2 B= SS=4 BS=5 D=1 C=2/0 PASSFLAG=0" ] && [ "$(d1)" = "wa-n1 small feature pass=1;" ] && ok "só-nó: a bead carimbada com veredito node é entregue a dispatch_one com a bandeira, sai da pista e consome a vaga — $r" || bad "só-nó, on: $r / d1=$(d1)"
grep -q 'passada de WA no nó (modo=on)' "$WORK/lines" 2>/dev/null && ! grep -q 'INERTE' "$WORK/lines" 2>/dev/null && ok "só-nó: o log diz 'passada de WA no nó (modo=on)' e NÃO diz INERTE (o critério de pronto do ga-2hd02v.3.9)" || bad "log da só-nó: $(cut -c1-200 "$WORK/lines" 2>/dev/null | tr '\n' '|')"
# nada é escrito em bead que o nó não levaria: veredito mini/unknown/timeout/erro → zero bd, zero dispatch_one (o disco do mini está baixo)
reset; chk wa-m1 10; chk wa-n2 11; chk wa-x 124; chk wa-y 99
r=$(T_NODE_ONLY=1 pass "[$(jb wa-m1 U1 wa-worker x),$(jb wa-n2 U1 wa-worker x),$(jb wa-x U1 wa-worker x),$(jb wa-y U1 wa-worker x)]")
[ "$(d1)" = "-" ] && [ ! -f "$WORK/bd.calls" ] && ok "só-nó: veredito mini/unknown/timeout/erro → NENHUMA chamada ao bd e dispatch_one nunca chamado (4 sondas, 0 escritas)" || bad "só-nó escreveu em bead que o nó não levaria (d1=$(d1) bd=$(tr '\n' '|' < "$WORK/bd.calls" 2>/dev/null))"
[ "$(wnd_calls)" = 4 ] && ok "só-nó: as 4 candidatas foram sondadas só com 'check' (leitura)" || bad "só-nó, sondas: $(wnd_calls)"
# modo label: node por texto não é o que o apply levaria → não chega a dispatch_one, mesmo na só-nó
reset; chk wa-l2 0; echo text > "$WORK/chk.wa-l2.basis"; echo 0 > "$WORK/d1.rc.wa-l2"
T_NODE_ONLY=1 T_ROUTE=label pass "[$(jb wa-l2 U1 wa-worker x,node:ok)]" >/dev/null; [ "$(d1)" = "-" ] && [ ! -f "$WORK/bd.calls" ] && ok "só-nó + label com veredito node por base 'text': não tenta e não escreve" || bad "só-nó + label tentou com base text: d1=$(d1)"
reset; chk wa-l2 0; echo label > "$WORK/chk.wa-l2.basis"; echo 0 > "$WORK/d1.rc.wa-l2"
T_NODE_ONLY=1 T_ROUTE=label pass "[$(jb wa-l2 U1 wa-worker x,node:ok)]" >/dev/null; [ "$(d1)" = "wa-l2 small feature pass=1;" ] && ok "só-nó + label com node:ok e base 'label': entrega (a bead node:ok carimbada wa-worker do critério de pronto)" || bad "só-nó + label não entregou: d1=$(d1)"
# Dolt saturado e despacho parado valem também na só-nó
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
T_NODE_ONLY=1 T_DOLT=1 pass "$S3" >/dev/null; [ "$(d1)" = "-" ] && ok "só-nó + Dolt saturado: sondou, não despachou" || bad "só-nó despachou com o Dolt saturado: $(d1)"
reset; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
T_NODE_ONLY=1 T_STOP=1 pass "$S3" >/dev/null; [ "$(wnd_calls)" = 0 ] && [ "$(d1)" = "-" ] && ok "só-nó + despacho parado: nem sonda nem despacha" || bad "só-nó correu com o despacho parado"
# nó cheio (apply rc 12) na só-nó: o custo é UMA tentativa por varredura — a passada para na 1ª e não memoriza a bead
reset; chk wa-n1 0; chk wa-n2 0; echo 1 > "$WORK/d1.rc.wa-n1"; echo 12 > "$WORK/d1.apply.wa-n1"
T_NODE_ONLY=1 pass "$S3" >/dev/null
[ "$(d1)" = "wa-n1 small feature pass=1;" ] && ! grep -q 'wa-n1' "$MEMO" 2>/dev/null && ok "só-nó + nó cheio (rc 12): UMA tentativa por varredura (n2 nem é tentada) e a bead não é memorizada" || bad "só-nó + rc 12: d1=$(d1) memo=$(memo_of)"

echo "── (6b) ga-2hd02v.3.16: o waiter P0/P1 da cessão e a vaga do nó"
# Medido 30/10 00:2x (Mayor): "priority yield: 176 P2+ ceded to P1 wa-j6r97f (wa-worker 2/2)" e o Hetzner ocioso. A cessão (ga-5fn5p3) protege a RAM do MINI; a vaga do NÓ não é a que o waiter espera (a passada já corre ANTES das pistas
# e dispensa o yield — ga-2hd02v.9). O que sobra, e é o que esta seção prova: (a) a P2+ com veredito node vai ao nó mesmo com um P1 esperando o mini, e o log conta quantas foram; (b) o PRÓPRIO waiter, se o nó o quer, passa à frente
# das P2+ mesmo quando está na outra pista (a passada anda small→big, e as 1–3 vagas por varredura iam para as P2+ da small antes de o waiter ser olhado); (c) o waiter SEM veredito legível (unknown/timeout/erro, sondado agora ou
# memorizado) segura a P2+ — "nunca solta P2 ao nó num palpite sobre a P1" — e nada mais: P0/P1 que não é o waiter, classe ilegível, waiter fora do nó, sem waiter e a chave PILOT_WA_NODE_PASS_HOLD=0 não seguram.
jbp() { local p="$1"; shift; jb "$@" | jq -c --argjson p "$p" '.priority=$p'; }
W1="$(jbp 1 wa-w1 U1 wa-worker story:approved)"; Q1="$(jbp 1 wa-q1 U1 wa-worker story:approved)"
P2A="$(jbp 2 wa-p2a U1 wa-worker story:approved)"; P2B="$(jbp 2 wa-p2b U1 wa-worker story:approved)"
setok() { local i; for i in "$@"; do echo 0 > "$WORK/d1.rc.$i"; done; }
summ() { jq -c 'select(.event=="wa-node-pass-summary")' "$PLOG" 2>/dev/null | tail -1; }
# (a) P1 espera o mini (veredito mini), P2 tem veredito node e há vaga: a P2 vai ao nó — e o resumo conta a P2+ que foi apesar da cessão
reset; chk wa-w1 10; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter P1 com veredito mini + P2 com veredito node + vaga: a P2 vai ao nó (a vaga do nó não é a que o waiter espera)" || bad "P2 não foi ao nó com o waiter em mini: $(d1)"
summ | jq -e '.p2_to_node==1 and .held==0' >/dev/null 2>&1 && ok "resumo: p2_to_node=1 held=0 (quantas P2+ foram ao nó com um P0/P1 esperando)" || bad "resumo sem p2_to_node: $(summ | cut -c1-300)"
grep -q 'P2+ ao nó com P0/P1 esperando=1' "$WORK/lines" 2>/dev/null && ok "o log da varredura diz 'P2+ ao nó com P0/P1 esperando=1'" || bad "log sem a contagem de P2+ ao nó: $(grep 'passada de WA' "$WORK/lines" 2>/dev/null | cut -c1-400)"
# (b) o waiter está na pista big e as P2 na small; UMA vaga: o waiter (veredito node) fica com ela
reset; chk wa-w1 0; chk wa-p2a 0; chk wa-p2b 0; setok wa-w1 wa-p2a wa-p2b
T_WAIT=wa-w1 pass "[$P2A,$P2B]" "[$W1]" >/dev/null
[ "$(d1)" = "wa-w1 big feature pass=1;" ] && ok "waiter na pista big, P2s na small, 1 vaga: o waiter (veredito node) vai ao nó PRIMEIRO" || bad "o waiter perdeu a vaga para as P2+ da outra pista: $(d1)"
reset; chk wa-w1 0; chk wa-p2a 0; chk wa-p2b 0; setok wa-w1 wa-p2a wa-p2b
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 pass "[$P2A,$P2B]" "[$W1]" >/dev/null
[ "$(d1)" = "wa-w1 big feature pass=1;wa-p2a small feature pass=1;wa-p2b small feature pass=1;" ] && ok "com 3 vagas: o waiter primeiro e as duas P2 depois (a ordem das pistas só muda para o waiter)" || bad "ordem com 3 vagas: $(d1)"
reset; chk wa-w1 0; chk wa-p2a 0; setok wa-w1 wa-p2a
pass "[$P2A]" "[$W1]" >/dev/null
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "SEM waiter (nenhum P0/P1 espera): a ordem de sempre, small antes de big" || bad "sem waiter a ordem mudou: $(d1)"
reset; chk wa-w1 0; chk wa-p2a 0; setok wa-w1 wa-p2a
T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-w1 small feature pass=1;" ] && ok "waiter e P2 na MESMA pista, 1 vaga: o waiter (P1, antes na ordem) fica com ela" || bad "waiter na mesma pista: $(d1)"
# (c) waiter SEM veredito legível segura a P2+ com veredito node: nada vai ao nó, ninguém escreve em bead, a P2+ não vira memória
for rc in 11 124 99; do
  reset; chk wa-w1 $rc; chk wa-p2a 0; setok wa-p2a
  T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
  [ "$(d1)" = "-" ] && [ ! -f "$WORK/bd.calls" ] && ok "waiter com sonda rc $rc (unknown/timeout/erro): a P2 com veredito node NÃO vai ao nó e nada é escrito em bead" || bad "P2 foi ao nó com o waiter rc $rc ilegível: d1=$(d1)"
  summ | jq -e '.held==1 and .p2_to_node==0 and .kept==0' >/dev/null 2>&1 && ok "waiter rc $rc: resumo held=1 p2_to_node=0 kept=0" || bad "resumo do waiter rc $rc: $(summ | cut -c1-300)"
done
! grep -q 'wa-p2a' "$MEMO" 2>/dev/null && ok "a P2 segurada não entra na memória (o node não se memoriza: é sondada de novo quando o waiter tiver veredito)" || bad "a P2 segurada foi memorizada: $(memo_of)"
reset; ( eval "$PRELUDE"; _pilot_wa_node_pass_memo_put wa-w1 U1 unknown ) >/dev/null 2>&1; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "-" ] && [ "$(wnd_calls)" = 1 ] && grep -q 'wa-p2a' "$WORK/wnd.calls" && ok "waiter JÁ memorizado como unknown (nenhuma sonda dele): segura do mesmo jeito — só a P2 foi sondada" || bad "waiter memorizado unknown: d1=$(d1) sondas=$(wnd_calls)"
# o memo_hit só devolve mini|unknown|released|sampled (outro valor tem TTL 0 e nem acerta): o `*` do caso é a rede de um valor NOVO — segura, nunca libera a P2+ num palpite sobre o waiter
reset; chk wa-p2a 0; setok wa-p2a
SJ="[$W1,$P2A]" T_WAIT=wa-w1 run_t 'SMALL_CANDIDATES="$SJ"; BIG_CANDIDATES="[]"; SMALL_COUNT=2; BIG_COUNT=0
  _pilot_wa_node_pass_memo_hit() { case "$1" in wa-w1) _PWP_MEMO_V=zzz-novo; return 0 ;; *) return 1 ;; esac; }
  _pilot_wa_node_pass; echo done' >/dev/null
[ "$(d1)" = "-" ] && [ "$(wnd_calls)" = 1 ] && ok "memo_hit devolvendo um valor que a passada não conhece (waiter): segura (a P2 com veredito node não vai)" || bad "valor novo do memo_hit não segurou: d1=$(d1) sondas=$(wnd_calls)"
# o que NÃO segura
reset; ( eval "$PRELUDE"; _pilot_wa_node_pass_memo_put wa-w1 U1 mini ) >/dev/null 2>&1; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter memorizado como mini: não segura" || bad "waiter mini memorizado segurou: $(d1)"
reset; W1V="$(jbp 1 wa-w1 U1 wa-worker story:approved,node:never)"; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "[$W1V,$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter com rótulo de veto (nunca irá ao nó): não segura" || bad "waiter vetado segurou: $(d1)"
reset; W1O="$(jbp 1 wa-w1 U1 wa-worker story:approved mila-wa)"; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "[$W1O,$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter com dono (a passada nem o sonda): não segura" || bad "waiter com dono segurou: $(d1)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=ps-zz pass "[$W1,$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter que NÃO está nas pistas de WA: não segura" || bad "waiter fora da passada segurou: $(d1)"
# a lista das pistas mistura beads de todos os rigs: o waiter ps-*/ga-* está NELA, mas a passada só itera wa-* e nunca o veria — ficaria "unseen" e seguraria toda P2+ para sempre
for NW in ps-zz ga-zz; do
  reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a; NWB="$(jbp 1 $NW U1 - story:approved)"
  T_WAIT=$NW pass "[$NWB,$W1,$P2A]" "[]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter $NW ESTÁ na pista (bead de outro rig): o nó não o ajuda, não segura — senão ficaria 'unseen' para sempre" || bad "waiter $NW (outro rig) na pista segurou a P2: $(d1)"
done
# a pista do waiter sem vaga de despacho: ele não pode ir ao nó nesta varredura, então não segura as P2+ da outra pista
reset; chk wa-w1 0; chk wa-p2a 0; setok wa-w1 wa-p2a
T_WAIT=wa-w1 T_SLOTS_BIG=0 pass "[$P2A]" "[$W1]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "waiter na pista big SEM vaga de despacho: não vai ao nó nesta varredura e por isso não segura a P2 da small" || bad "waiter sem vaga de pista segurou a P2: $(d1)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
pass "[$W1,$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "sem waiter (a cessão ociosa): P1 unknown não segura P2 — o comportamento de sempre" || bad "sem waiter segurou: $(d1)"
reset; chk wa-w1 11; chk wa-q1 0; setok wa-q1
T_WAIT=wa-w1 pass "[$W1,$Q1]" >/dev/null; [ "$(d1)" = "wa-q1 small feature pass=1;" ] && ok "outro P1 (não é o waiter) com veredito node: nunca é segurado — só P2+ cede" || bad "P1 não-waiter foi segurado: $(d1)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a; P9="$(jbp 9 wa-p2a U1 wa-worker story:approved)"
T_WAIT=wa-w1 pass "[$W1,$P9]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "prioridade ilegível (classe 5): não segura — 'não sei a classe' nunca segura trabalho (a regra do yield)" || bad "classe ilegível segurou: $(d1)"
summ | jq -e '.class_blind==1 and .held==0' >/dev/null 2>&1 && ok "…e a classe ilegível é CONTADA (class_blind=1, held=0): o fail-open não é silencioso" || bad "classe ilegível não foi contada: $(summ | cut -c1-300)"
grep -q 'classe de prioridade ILEGÍVEL' "$WORK/lines" 2>/dev/null && ok "…e AVISADA no log (WARN com a causa)" || bad "classe ilegível sem aviso: $(cut -c1-160 "$WORK/lines" 2>/dev/null | tr '\n' '|')"
reset; chk wa-w1 10; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "[$W1,$P9]" >/dev/null; summ | jq -e '.class_blind==0' >/dev/null 2>&1 && ok "classe ilegível com o waiter COM veredito (mini): nada a contar (class_blind=0) — só conta quando a retenção valeria" || bad "contou classe ilegível sem retenção: $(summ | cut -c1-300)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
PILOT_WA_NODE_PASS_HOLD=0 T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "PILOT_WA_NODE_PASS_HOLD=0 desliga a retenção (o comportamento anterior)" || bad "HOLD=0 não desligou: $(d1)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
PILOT_WA_NODE_PASS_HOLD=zzz T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null; [ "$(d1)" = "-" ] && ok "PILOT_WA_NODE_PASS_HOLD com valor ilegível: vale o padrão (ligada) — só '0' desliga" || bad "valor ilegível desligou a retenção: $(d1)"
# o waiter quer o nó, mas o nó está cheio (apply rc 12): a passada para como sempre — a P2 não passa na frente
reset; chk wa-w1 0; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-w1"; echo 12 > "$WORK/d1.apply.wa-w1"; setok wa-p2a
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 pass "[$W1,$P2A]" >/dev/null; [ "$(d1)" = "wa-w1 small feature pass=1;" ] && ok "waiter com veredito node e nó cheio (rc 12): a passada para, a P2 nem é tentada" || bad "P2 passou na frente do waiter com o nó cheio: $(d1)"
# pista ilegível COM waiter: não sei onde ele está (talvez na pista que não leio) — o estado inerte é segurar, nunca "sem waiter"; a pista legível ainda é percorrida (e sem waiter, a ilegível não segura nada)
reset; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 pass "isto não é json" "[$P2A]" >/dev/null; [ "$(d1)" = "-" ] && ok "pista small ilegível + waiter conhecido: a P2 da big NÃO vai ao nó (não sei onde o waiter está)" || bad "pista ilegível com waiter não segurou: $(d1)"
reset; chk wa-p2a 0; setok wa-p2a
pass "isto não é json" "[$P2A]" >/dev/null; [ "$(d1)" = "wa-p2a big feature pass=1;" ] && ok "pista small ilegível SEM waiter: a big é percorrida como sempre" || bad "pista ilegível sem waiter: $(d1)"

# os ajudantes sozinhos
wlane() { SJ="$1" BJ="$2" run_t 'SMALL_CANDIDATES="$SJ"; BIG_CANDIDATES="$BJ"; x=0; o=$(_pilot_wa_node_pass_waiter_lane) || x=$?; echo "rc=$x out=[$o]"'; }
r=$(T_WAIT=wa-w1 wlane "[$P2A]" "[$W1]");        [ "$r" = "rc=0 out=[big]" ]   && ok "pista do waiter: big" || bad "waiter_lane big: $r"
r=$(T_WAIT=wa-w1 wlane "[$W1]" "[$P2A]");        [ "$r" = "rc=0 out=[small]" ] && ok "pista do waiter: small" || bad "waiter_lane small: $r"
r=$(T_WAIT=wa-w1 wlane "[$P2A]" "[]");           [ "$r" = "rc=0 out=[none]" ]  && ok "waiter em nenhuma pista: none" || bad "waiter_lane none: $r"
r=$(T_WAIT= wlane "[$W1]" "[]");                 [ "$r" = "rc=0 out=[none]" ]  && ok "sem waiter: none" || bad "waiter_lane sem waiter: $r"
r=$(T_WAIT=ps-zz wlane "[$(jbp 1 ps-zz U1 - x)]" "[]"); [ "$r" = "rc=0 out=[none]" ] && ok "waiter que não é wa-*: none, mesmo estando na pista" || bad "waiter_lane ps: $r"
r=$(T_WAIT=wa-w1 wlane "isto não é json" "[]");  [ "$r" = "rc=1 out=[]" ]      && ok "pista ilegível: rc 1 e NADA impresso (nunca 'none')" || bad "waiter_lane ilegível: $r"
r=$(T_WAIT=wa-w1 wlane "[]" "isto não é json");  [ "$r" = "rc=1 out=[]" ]      && ok "pista big ilegível: rc 1 também" || bad "waiter_lane big ilegível: $r"
hold() { run_t "x=0; _pilot_wa_node_pass_hold_for '$1' '$2' || x=\$?; echo \"rc=\$x\""; }
r=$(T_WAIT=wa-w1 hold "$P2A" blind);  [ "$r" = "rc=0" ] && ok "hold_for: P2 + waiter blind → segura" || bad "hold_for P2/blind: $r"
r=$(T_WAIT=wa-w1 hold "$P2A" unseen); [ "$r" = "rc=0" ] && ok "hold_for: P2 + waiter unseen → segura" || bad "hold_for P2/unseen: $r"
for v in node out ""; do r=$(T_WAIT=wa-w1 hold "$P2A" "$v"); [ "$r" = "rc=1" ] && ok "hold_for: P2 + waiter '$v' → não segura" || bad "hold_for P2/'$v': $r"; done
r=$(T_WAIT=wa-w1 hold "$Q1" blind);   [ "$r" = "rc=1" ] && ok "hold_for: P1 nunca é segurado" || bad "hold_for P1: $r"
r=$(T_WAIT= hold "$P2A" blind);       [ "$r" = "rc=1" ] && ok "hold_for: sem waiter → não segura" || bad "hold_for sem waiter: $r"
P9B="$(jbp 9 wa-p9 U1 wa-worker x)"
r=$(T_WAIT=wa-w1 hold "$P9B" blind);  [ "$r" = "rc=2" ] && ok "hold_for: classe ilegível + waiter blind → rc 2 (não segura, e quem chama CONTA)" || bad "hold_for classe ilegível/blind: $r"
r=$(T_WAIT=wa-w1 hold "$P9B" unseen); [ "$r" = "rc=2" ] && ok "hold_for: classe ilegível + waiter unseen → rc 2" || bad "hold_for classe ilegível/unseen: $r"
r=$(T_WAIT=wa-w1 hold "$P9B" out);    [ "$r" = "rc=1" ] && ok "hold_for: classe ilegível mas o waiter tem veredito → rc 1 (a retenção nem valeria: nada a contar)" || bad "hold_for classe ilegível/out: $r"
r=$(T_WAIT=wa-w1 hold "" blind);      [ "$r" = "rc=2" ] && ok "hold_for: bead ilegível/vazia + waiter blind → rc 2, nunca 0" || bad "hold_for bead vazia: $r"

echo "── (6c) ga-2hd02v.3.16 (gate 1): o waiter em TRÊS estados — 'não se sabe' segura a P2+, só o motivo DEFINITIVO a solta"
# O gate reprovou a 1ª entrega (root-class error-vs-empty): "não consegui saber se o waiter vai ao nó" virava _pw_wv=out e SOLTAVA a P2+ — o palpite sobre o P1 que a mudança existe para tirar. Dois caminhos reproduzidos pelo revisor:
# (1a) o pré-filtro do waiter falha por motivo ILEGÍVEL (unreadable, refusal-unknown) e não por motivo definitivo (dono, veto, rota alheia, node:mini, recusa do pool); (1b) o waiter tem veredito node, o dispatch_one falha e o apply
# sai com rc 11 (unknown) ou nem chega ao apply — o resto DESTA passada seguia com wv=node. Mais um irmão da mesma classe: a memória `released` (tentativa anterior que nunca chegou a veredito) era lida como "não vai ao nó".
# (1a) pré-filtro do waiter ilegível: a recusa do probe do pool não se lê SÓ para o waiter (a P2 é lida normalmente) — nada vai ao nó, nada é escrito em bead, e o resumo diz blind (não "out")
reset; chk wa-p2a 0; setok wa-p2a
T_REFUSAL=FAIL T_REFUSAL_ID=wa-w1 T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "-" ] && [ ! -f "$WORK/bd.calls" ] && ok "(1a) waiter com a recusa do pool ilegível (refusal-unknown): a P2 com veredito node NÃO vai ao nó e nada é escrito em bead" || bad "(1a) P2 tomou a vaga do nó com a recusa do waiter ilegível: d1=$(d1)"
summ | jq -e '.held==1 and .p2_to_node==0 and .waiter_verdict=="blind" and .skipped["refusal-unknown"]==1' >/dev/null 2>&1 && ok "(1a) resumo: held=1 p2_to_node=0 waiter_verdict=blind (o sinal de que ninguém sabia NÃO some) e skipped.refusal-unknown=1" || bad "(1a) resumo do waiter refusal-unknown: $(summ | cut -c1-300)"
[ "$(wnd_calls)" = 1 ] && grep -q 'wa-p2a' "$WORK/wnd.calls" && ok "(1a) o waiter nem foi sondado (o pré-filtro o parou); só a P2 foi" || bad "(1a) sondas: $(wnd_calls)"
WSP="$(jbp 1 'wa-w x' U1 wa-worker story:approved)"
reset; chk wa-p2a 0; setok wa-p2a
T_WAIT='wa-w x' pass "[$WSP,$P2A]" >/dev/null
[ "$(d1)" = "-" ] && ok "(1a) waiter com id fora de [A-Za-z0-9._-] (unreadable): a P2 NÃO vai ao nó" || bad "(1a) waiter unreadable soltou a P2: d1=$(d1)"
summ | jq -e '.held==1 and .waiter_verdict=="blind" and .skipped.unreadable==1' >/dev/null 2>&1 && ok "(1a) resumo: waiter_verdict=blind e skipped.unreadable=1" || bad "(1a) resumo do waiter unreadable: $(summ | cut -c1-300)"
# o que continua DEFINITIVO e solta a P2+: a recusa do pool que se LEU (refused:*) — o nó também não o levaria
reset; chk wa-p2a 0; setok wa-p2a
T_REFUSAL=label:story:refino-escalado T_REFUSAL_ID=wa-w1 T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "(1a) waiter recusado pelo pool (refused, lido): não vai ao nó e não segura a P2" || bad "(1a) waiter refused segurou a P2: d1=$(d1)"
summ | jq -e '.held==0 and .p2_to_node==1 and .waiter_verdict=="out" and .skipped.refused==1' >/dev/null 2>&1 && ok "(1a) resumo: waiter_verdict=out held=0 p2_to_node=1 skipped.refused=1" || bad "(1a) resumo do waiter refused: $(summ | cut -c1-300)"
# a tabela do motivo do pré-filtro → veredito do waiter: SÓ o definitivo é out; ilegível, vazio e motivo que ninguém conhece são blind (um motivo NOVO nunca solta a P2+ por omissão)
whyv() { WHY="$1" run_t 'echo "[$(_pilot_wa_node_pass_why_verdict "$WHY")]"'; }
for w in not-wa has-owner no-node-ok node:mini routed:mila-wa routed:wa-worker-remote veto:node:never veto:exec:manual refused:label:story:refino-escalado; do
  [ "$(whyv "$w")" = "[out]" ] && ok "motivo '$w' (definitivo): o waiter é out" || bad "motivo '$w' deveria ser out: $(whyv "$w")"
done
for w in unreadable refusal-unknown "" zzz-novo; do
  [ "$(whyv "$w")" = "[blind]" ] && ok "motivo '$w' (não se sabe / desconhecido): o waiter é blind" || bad "motivo '$w' deveria ser blind: $(whyv "$w")"
done
# (1b) o waiter tem veredito node, o dispatch_one falha: o que o apply disse manda no resto DA MESMA passada. rc 11 e 'nada chegou ao apply' = não se sabe (segura); rc 10 = o apply disse mini (solta)
reset; chk wa-w1 0; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-w1"; echo 11 > "$WORK/d1.apply.wa-w1"; setok wa-p2a
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-w1 small feature pass=1;" ] && [ "$(memo_of)" = "wa-w1:unknown," ] && ok "(1b) waiter node + apply rc 11: a P2 NÃO toma a vaga na MESMA passada (e o waiter fica memorizado unknown)" || bad "(1b) apply rc 11: d1=$(d1) memo=$(memo_of)"
summ | jq -e '.held==1 and .p2_to_node==0 and .released==1 and .waiter_verdict=="blind"' >/dev/null 2>&1 && ok "(1b) apply rc 11: resumo held=1 p2_to_node=0 released=1 waiter_verdict=blind (não 'node')" || bad "(1b) resumo do apply rc 11: $(summ | cut -c1-300)"
reset; chk wa-w1 0; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-w1"; setok wa-p2a
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-w1 small feature pass=1;" ] && [ "$(memo_of)" = "wa-w1:released," ] && ok "(1b) waiter node + nada chegou ao apply: a P2 NÃO toma a vaga na mesma passada (memória released)" || bad "(1b) sem apply: d1=$(d1) memo=$(memo_of)"
summ | jq -e '.held==1 and .p2_to_node==0 and .released==1 and .waiter_verdict=="blind"' >/dev/null 2>&1 && ok "(1b) sem apply: resumo held=1 p2_to_node=0 waiter_verdict=blind" || bad "(1b) resumo sem apply: $(summ | cut -c1-300)"
reset; chk wa-w1 0; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-w1"; echo 7 > "$WORK/d1.apply.wa-w1"; setok wa-p2a
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-w1 small feature pass=1;" ] && summ | jq -e '.waiter_verdict=="blind" and .stopped=="hook-held" and .p2_to_node==0' >/dev/null 2>&1 && ok "(1b) apply com outro rc (a escrita pode ter acontecido): a passada para e o resumo diz blind, não 'node'" || bad "(1b) apply rc 7: d1=$(d1) $(summ | cut -c1-300)"
reset; chk wa-w1 0; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-w1"; echo 10 > "$WORK/d1.apply.wa-w1"; setok wa-p2a
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 pass "[$W1,$P2A]" >/dev/null
[ "$(d1)" = "wa-w1 small feature pass=1;wa-p2a small feature pass=1;" ] && [ "$(memo_of)" = "wa-w1:mini," ] && ok "(1b) waiter node + apply rc 10 (o apply DISSE mini: definitivo): a P2 vai ao nó na mesma passada" || bad "(1b) apply rc 10: d1=$(d1) memo=$(memo_of)"
summ | jq -e '.held==0 and .p2_to_node==1 and .waiter_verdict=="out"' >/dev/null 2>&1 && ok "(1b) apply rc 10: resumo held=0 p2_to_node=1 waiter_verdict=out" || bad "(1b) resumo do apply rc 10: $(summ | cut -c1-300)"
# memória do waiter: `released` (tentativa anterior sem veredito) e `sampled` (o shadow mediu node, mas a chave dele é outra) NÃO são "não vai ao nó": seguram. Só `mini` solta (testado acima: "waiter memorizado como mini: não segura").
for mv in released sampled; do
  reset; ( eval "$PRELUDE"; _pilot_wa_node_pass_memo_put wa-w1 U1 "$mv" ) >/dev/null 2>&1; chk wa-p2a 0; setok wa-p2a
  T_WAIT=wa-w1 pass "[$W1,$P2A]" >/dev/null
  [ "$(d1)" = "-" ] && [ "$(wnd_calls)" = 1 ] && ok "(memória) waiter memorizado como $mv (sem veredito de verdade): a P2 NÃO vai ao nó — só ela foi sondada" || bad "(memória) waiter $mv soltou a P2: d1=$(d1) sondas=$(wnd_calls)"
  summ | jq -e '.held==1 and .waiter_verdict=="blind"' >/dev/null 2>&1 && ok "(memória) waiter $mv: resumo held=1 waiter_verdict=blind" || bad "(memória) resumo do waiter $mv: $(summ | cut -c1-300)"
done

echo "── (6d) ga-2hd02v.3.17: o porquê de cada sonda fica no log (uma linha por sonda + a soma no resumo)"
# a passada de 05:39Z sondou 12 e mandou 0 ao nó; o log só dizia "mini 5 · não sei 7". Aqui cada sonda grava veredito, motivos, classes e caminhos; "não li" nunca é "sem motivo".
probe_of() { jq -c --arg b "$1" 'select(.event=="wa-node-pass-probe" and .bead==$b)' "$PLOG" 2>/dev/null | tail -1; }
sumr() { jq -c 'select(.event=="wa-node-pass-summary") | .reasons' "$PLOG" 2>/dev/null | tail -1; }
reset; chk wa-m1 10; echo '["moles:banco-de-dados","caminho-fora-do-filtro:shared/data/x.json"]' > "$WORK/chk.wa-m1.reasons"; echo '["shared/data/x.json"]' > "$WORK/chk.wa-m1.paths"
T_EXEMPT=shadow pass "$S3" >/dev/null
pl=$(probe_of wa-m1)
[ "$(printf '%s' "$pl" | jq -c '[.verdict,.lane,.reasons,.classes,.paths]' 2>/dev/null)" = '["mini","small",["moles:banco-de-dados","caminho-fora-do-filtro:shared/data/x.json"],["caminho-fora-do-filtro","moles"],["shared/data/x.json"]]' ] \
  && ok "mini: a linha da sonda traz veredito, pista, motivos, classes (motivo até o 1º ':') e caminhos" || bad "linha da sonda do mini: '$pl'"
# vazio ([]): o classificador respondeu SEM motivo → reasons [] e a palavra "sem-motivo"; não é null
reset; chk wa-m1 11; echo '[]' > "$WORK/chk.wa-m1.reasons"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[.verdict,.reasons,.classes]' 2>/dev/null)" = '["unknown",[],[]]' ] && [ "$(sumr | jq -r '.["unknown:sem-motivo"] // "-"' 2>/dev/null)" = 1 ] \
  && ok "reasons [] (o classificador respondeu sem motivo): a linha guarda [] e o resumo conta 'unknown:sem-motivo'" || bad "reasons []: linha='$(probe_of wa-m1)' resumo='$(sumr)'"
# falhou/ilegível: saída que o jq não lê, ou JSON sem a lista, é null e "ilegivel" — NUNCA "sem-motivo"
reset; chk wa-m1 10; echo 'isto nao e json' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[.verdict,.reasons,.classes,.paths]' 2>/dev/null)" = '["mini",null,null,null]' ] && [ "$(sumr | jq -r '.["mini:ilegivel"] // "-"' 2>/dev/null)" = 1 ] && [ "$(sumr | jq -r '.["mini:sem-motivo"] // "-"' 2>/dev/null)" = "-" ] \
  && ok "rc 10 com saída ilegível: reasons=null e 'mini:ilegivel' no resumo (o veredito mini fica; 'não li' nunca vira 'sem motivo')" || bad "saída ilegível: linha='$(probe_of wa-m1)' resumo='$(sumr)'"
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":"texto"}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[.reasons,.classes]' 2>/dev/null)" = '[null,null]' ] && [ "$(sumr | jq -r '.["unknown:ilegivel"] // "-"' 2>/dev/null)" = 1 ] \
  && ok "reasons que não é lista: null e 'unknown:ilegivel'" || bad "reasons que não é lista: linha='$(probe_of wa-m1)' resumo='$(sumr)'"
# ga-2hd02v.3.17 (gate 1): "a leitura FALHOU" é um estado próprio da linha da sonda. O classificador respondeu (veredito e motivos), mas o `info` dele diz o que não conseguiu ler (`caminho-solto-ilegivel:…`,
# `espelho-ilegivel:…`, `teste-derivado-ilegivel:…`) e o veredito pode estar pior do que o certo. `leitura`: lista com as entradas *-ilegivel (até 6 de 80 caracteres) = a leitura falhou; [] = leu tudo;
# null = o `info` não foi lido (sem saída, saída ilegível, sem `info`, `info` que não é lista). Os três nunca se confundem, e o contrato de palavras do resumo (veredito:classe) não muda.
reset; chk wa-m1 10; echo '{"verdict":"mini","basis":"","reasons":["caminho-fora-do-filtro:loose.html"],"paths":["loose.html"],"info":["tela-ao-vivo","caminho-solto-ilegivel:repo-git-rc-128","espelho-ilegivel:espelho-ausente"]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[.verdict,.classes,.leitura]' 2>/dev/null)" = '["mini",["caminho-fora-do-filtro"],["caminho-solto-ilegivel:repo-git-rc-128","espelho-ilegivel:espelho-ausente"]]' ] && [ "$(sumr | jq -r '.["mini:caminho-fora-do-filtro"] // "-"' 2>/dev/null)" = 1 ] && [ "$(sumr | jq -r '[keys[] | select(test("ilegivel"))] | length' 2>/dev/null)" = 0 ] \
  && ok "leitura: a linha da sonda guarda só as entradas *-ilegivel do info ('tela-ao-vivo' fica de fora) e o resumo continua com as palavras veredito:classe" || bad "leitura que falhou: linha='$(probe_of wa-m1)' resumo='$(sumr)'"
reset; chk wa-m1 10; echo '{"verdict":"mini","basis":"","reasons":["moles:x"],"paths":[],"info":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.leitura' 2>/dev/null)" = '[]' ] && ok "leitura: info [] (o classificador leu tudo) fica [] — não é null nem falha" || bad "info []: '$(probe_of wa-m1)'"
reset; chk wa-m1 10; echo '{"verdict":"mini","basis":"","reasons":["moles:x"],"paths":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[.leitura, .classes]' 2>/dev/null)" = '[null,["moles"]]' ] && ok "leitura: sem info na saída é null (não li o info), sem tocar nas classes" || bad "sem info: '$(probe_of wa-m1)'"
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":["moles:x"],"paths":[],"info":"caminho-solto-ilegivel:x"}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.leitura' 2>/dev/null)" = 'null' ] && ok "leitura: info que não é lista é null (texto não vira falha nem leitura limpa)" || bad "info texto: '$(probe_of wa-m1)'"
reset; chk wa-m1 124; chk wa-n1 2
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.leitura' 2>/dev/null)" = 'null' ] && [ "$(probe_of wa-n1 | jq -c '.leitura' 2>/dev/null)" = 'null' ] && ok "leitura: sem saída do classificador (timeout, error) é null" || bad "sem saída: m1='$(probe_of wa-m1)' n1='$(probe_of wa-n1)'"
long=$(printf 'y%.0s' $(seq 1 100))
reset; chk wa-m1 10; jq -cn --arg long "$long" '{verdict:"mini",basis:"",reasons:["moles:x"],paths:[],info:([range(0;8) | "teste-derivado-ilegivel:\(.)" + $long])}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[(.leitura|length), (.leitura|map(length)|max), (.leitura[0]|startswith("teste-derivado-ilegivel:0"))]' 2>/dev/null)" = '[6,80,true]' ] \
  && ok "leitura: no máximo 6 entradas de 80 caracteres (a linha da sonda não cresce com o info)" || bad "teto da leitura: $(probe_of wa-m1 | cut -c1-300)"
# ga-2hd02v.3.20: `custo` = o que o classificador mediu de si (ms total, ms da derivação de caminho, cache das irmãs). Vai para a linha da sonda para o custo por sonda ser LIDO, não suposto.
# Objeto -> carregado; ausente ou que não é objeto -> null (o campo todo); campo que não é número/texto -> null NESSE campo. "Não medi" nunca vira 0 ms.
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"custo":{"ms":412,"derivacao_ms":380,"cache":"miss"},"info":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.custo' 2>/dev/null)" = '{"ms":412,"derivacao_ms":380,"cache":"miss"}' ] && ok "custo: o objeto que o classificador mediu vai inteiro para a linha da sonda" || bad "custo carregado: '$(probe_of wa-m1)'"
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"info":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.custo' 2>/dev/null)" = 'null' ] && ok "custo: saída sem o campo (classificador antigo) é null, não {ms:0}" || bad "custo ausente: '$(probe_of wa-m1)'"
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"custo":"rapido","info":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.custo' 2>/dev/null)" = 'null' ] && ok "custo: valor que não é objeto é null (texto não vira custo)" || bad "custo texto: '$(probe_of wa-m1)'"
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"custo":{"ms":"muito","derivacao_ms":5,"cache":7},"info":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.custo' 2>/dev/null)" = '{"ms":null,"derivacao_ms":5,"cache":null}' ] && ok "custo: campo que não é número/texto fica null só nele (o vizinho válido sobrevive, nada vira 0)" || bad "custo com campos ruins: '$(probe_of wa-m1)'"
reset; chk wa-m1 11; echo '{"verdict":"unknown","basis":"","reasons":["sem-prova-de-codigo-e-teste"],"paths":[],"custo":{"ms":5,"derivacao_ms":"x","cache":"hit"},"info":[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.custo' 2>/dev/null)" = '{"ms":5,"derivacao_ms":null,"cache":"hit"}' ] && ok "custo: derivacao_ms que não é número também fica null só nele (ms e cache válidos sobrevivem, nada vira 0)" || bad "custo com derivacao_ms ruim: '$(probe_of wa-m1)'"
reset; chk wa-m1 11; jq -cn --arg long "$long" '{verdict:"unknown",basis:"",reasons:["sem-prova-de-codigo-e-teste"],paths:[],custo:{ms:1,derivacao_ms:1,cache:("hit"+$long)},info:[]}' > "$WORK/chk.wa-m1.raw"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[(.custo.cache|length), (.custo.cache|startswith("hit"))]' 2>/dev/null)" = '[16,true]' ] && ok "custo: o texto do cache é cortado em 16 caracteres (a linha da sonda não cresce)" || bad "teto do cache: $(probe_of wa-m1 | cut -c1-300)"
reset; chk wa-m1 124; chk wa-n1 2
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '.custo' 2>/dev/null)" = 'null' ] && [ "$(probe_of wa-n1 | jq -c '.custo' 2>/dev/null)" = 'null' ] && ok "custo: sem saída do classificador (timeout, error) é null" || bad "custo sem saída: m1='$(probe_of wa-m1)' n1='$(probe_of wa-n1)'"
# sem saída por definição (prazo, rc fora do contrato): 'sem-saida', a sonda ainda é contada
reset; chk wa-m1 124; chk wa-n1 2
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[.verdict,.reasons]' 2>/dev/null)" = '["timeout",null]' ] && [ "$(probe_of wa-n1 | jq -c '[.verdict,.reasons]' 2>/dev/null)" = '["error",null]' ] \
  && [ "$(sumr | jq -c '[.["timeout:sem-saida"], .["error:sem-saida"]]' 2>/dev/null)" = '[1,1]' ] && ok "timeout e error: a linha da sonda existe (reasons null) e o resumo conta 'sem-saida'" || bad "timeout/error: m1='$(probe_of wa-m1)' n1='$(probe_of wa-n1)' resumo='$(sumr)'"
# a soma do resumo: uma palavra veredito:classe por sonda (classe repetida na mesma sonda conta UMA vez)
reset; chk wa-m1 10; echo '["caminho-fora-do-filtro:a.db","caminho-fora-do-filtro:b.db","moles:credencial"]' > "$WORK/chk.wa-m1.reasons"; chk wa-n1 0; echo '["prova-teste-derivado:1-teste(s)+1-codigo(s)"]' > "$WORK/chk.wa-n1.reasons"; chk wa-n2 11; echo '["sem-prova-de-codigo-e-teste"]' > "$WORK/chk.wa-n2.reasons"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(sumr | jq -cS . 2>/dev/null)" = '{"mini:caminho-fora-do-filtro":1,"mini:moles":1,"node:prova-teste-derivado":1,"unknown:sem-prova-de-codigo-e-teste":1}' ] \
  && ok "o resumo soma motivo × contagem por veredito (3 sondas → 4 palavras; classe repetida na mesma sonda conta 1)" || bad "soma do resumo: '$(sumr)'"
grep -q 'motivos: .*mini:moles=1' "$WORK/lines" 2>/dev/null && ok "a linha do log do Pilot traz 'motivos: …' (o que o Athos lê sem abrir o jsonl)" || bad "log sem motivos: $(grep 'passada de WA' "$WORK/lines" 2>/dev/null | cut -c1-300)"
# nenhuma sonda → {} (verdade: nada sondado), não null
reset
T_EXEMPT=shadow pass "[]" >/dev/null
[ "$(sumr)" = '{}' ] && ok "passada sem sonda nenhuma: reasons {} no resumo (nada foi sondado), não null" || bad "resumo sem sondas: '$(sumr)'"
# memória acertou → não houve sonda → nenhuma linha de sonda nova (a linha é por SONDA, não por candidata)
reset; chk wa-m1 10; chk wa-n1 0; chk wa-n2 11; T_EXEMPT=shadow pass "$S3" >/dev/null; n1=$(grep -c '"wa-node-pass-probe"' "$PLOG" 2>/dev/null || true)
T_EXEMPT=shadow pass "$S3" >/dev/null; n2=$(grep -c '"wa-node-pass-probe"' "$PLOG" 2>/dev/null || true)
[ "$n1" = 3 ] && [ "$n2" = 4 ] && ok "a 2ª varredura só sonda o que a memória não tem (3 sondas na 1ª; na 2ª m1 mini e n2 unknown vêm da memória e só o node n1, que não é memorizado, é sondado: +1)" || bad "linhas de sonda: 1ª=$n1 2ª=$n2 (esperado 3 e 4)"
# o teto: motivos e caminhos são aparados (12 × 80 e 10 × 120), mas as CLASSES saem da lista inteira — o motivo que vem depois do corte não some
long=$(printf 'x%.0s' $(seq 1 100))
reasons=$(jq -cn --arg long "$long" '[range(0;20) | "caminho-fora-do-filtro:p\(.)"] + ["so-no-mac:z", ("longo:" + $long)]')
paths=$(jq -cn '[range(0;15) | "d/p\(.).db"]')
reset; chk wa-m1 10; printf '%s' "$reasons" > "$WORK/chk.wa-m1.reasons"; printf '%s' "$paths" > "$WORK/chk.wa-m1.paths"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(probe_of wa-m1 | jq -c '[(.reasons|length), (.paths|length), (.classes|index("so-no-mac") != null), (.classes|index("longo") != null)]' 2>/dev/null)" = '[12,10,true,true]' ] \
  && ok "teto: 12 motivos e 10 caminhos na linha, mas as classes vêm da lista inteira (so-no-mac e longo, depois do corte, aparecem)" || bad "teto: $(probe_of wa-m1 | cut -c1-300)"
reset; chk wa-m1 10; printf '%s' "$reasons" > "$WORK/chk.wa-m1.reasons"
T_EXEMPT=shadow pass "$S3" >/dev/null
[ "$(printf '%s' "$reasons" | jq -c '.[21]|length')" -gt 80 ] && [ "$(sumr | jq -r 'to_entries | map(.key|length) | max' 2>/dev/null)" -lt 60 ] && ok "motivo de 100+ caracteres: a classe do resumo é só o prefixo até ':' (chave curta)" || bad "chave do resumo longa: '$(sumr)'"
# modo on: a linha de sonda também sai (a bead que ficou com o nó tem veredito node e base)
reset; chk wa-n1 0; echo '["prova-teste-derivado:1-teste(s)+1-codigo(s)"]' > "$WORK/chk.wa-n1.reasons"; echo derivado > "$WORK/chk.wa-n1.basis"; echo 0 > "$WORK/d1.rc.wa-n1"
pass "$S3" >/dev/null
[ "$(probe_of wa-n1 | jq -c '[.verdict,.basis,.reasons]' 2>/dev/null)" = '["node","derivado",["prova-teste-derivado:1-teste(s)+1-codigo(s)"]]' ] && ok "modo on: a bead que ficou com o nó também tem linha de sonda (node, base derivado, motivo da prova)" || bad "modo on sem linha de sonda: '$(probe_of wa-n1)'"
# observar não decide: log que não grava (o caminho é uma pasta) avisa e a passada segue — veredito, memória e despacho iguais
reset; chk wa-m1 10; chk wa-n1 0; echo 0 > "$WORK/d1.rc.wa-n1"
r=$(SJ="$S3" run_t 'PILOT_WA_NODE_PASS_LOG="$WORK/city/.gc"; SMALL_CANDIDATES="$SJ"; BIG_CANDIDATES="[]"; _pilot_wa_node_pass; echo "D=$DISPATCHED"')
[ "$r" = "D=1" ] && [ "$(memo_of)" = "wa-m1:mini," ] && grep -q 'WARN ga-2hd02v.3.17: não consegui gravar a linha de sonda' "$WORK/lines" 2>/dev/null \
  && ok "log que não grava: avisa e a passada segue igual (n1 despachada, m1 memorizada como mini) — o registro só observa" || bad "log inescrevível mudou a decisão: r=$r memo=$(memo_of) avisos=$(grep -c WARN "$WORK/lines" 2>/dev/null)"
# nada do registro vaza para a decisão: o veredito da sonda não muda com reasons ilegível
reset; chk wa-n1 0; echo 'lixo' > "$WORK/chk.wa-n1.raw"; echo 0 > "$WORK/d1.rc.wa-n1"
pass "$S3" >/dev/null
[ "$(d1)" = "-" ] && ok "rc 0 com saída ilegível continua error (nunca node) — o detalhe dos motivos não abre porta nenhuma" || bad "saída ilegível despachou: $(d1)"

echo "── (6e) ga-2hd02v.3.18: o hold do waiter blind tem FIM — a 3ª passada seguida solta a P2+ com veredito node"
# Medido 30/10 06:20 (pilot-dispatcher.log): "seguradas pelo waiter sem veredito=4 · ficaram com o nó=0" varredura após varredura, com o Hetzner a 14,4% de CPU há 773 min e 1 wa-worker-remote vivo de 6. O hold do 3.16 é certo por UMA
# passada ("não consegui ler" não vira "o waiter não vai ao nó"), mas não tinha fim: um waiter cujo classificador responde unknown de forma PERSISTENTE congelava o nó inteiro para WA. Esta seção prova: (a) o contador por waiter
# (arquivo de estado que sobrevive entre varreduras) e o fim do hold na 3ª passada blind seguida (PILOT_WA_NODE_PASS_HOLD_MAX_SWEEPS, padrão 2; 0 = o comportamento anterior); (b) o veredito legível (node/out) ZERA o contador, e
# waiter outro recomeça do 0; (c) o contador só anda quando o waiter foi de fato olhado nesta passada (pista sem vaga, falta de leitura e ausência de waiter não andam nem zeram); (d) estado ilegível/que não grava NÃO solta a P2+
# (segue segurando, e AVISA); (e) o waiter é sondado ANTES de qualquer P2+ (orçamento de sondas) para que o hold acabe por veredito quando possível.
HOLD_STATE="$WORK/city/.gc/wa-node-pass-hold.tsv"
hold_of() { [ -f "$HOLD_STATE" ] && awk -F'\t' '{print $2":"$3}' "$HOLD_STATE" | tr '\n' ',' || printf -- '-'; }
# uma varredura: a memória de vereditos e o estado do hold SOBREVIVEM entre varreduras; só o que a anterior deixou em d1/lines/resumo é apagado
sweep() { rm -f "$WORK/d1.calls" "$WORK/lines" "$PLOG" "$WORK/bd.calls"; pass "$@" >/dev/null; }
# (a) o contador sobe a cada passada em que o waiter termina blind; com o padrão 2, as passadas 1 e 2 seguram e a 3ª solta
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "-" ] && [ "$(hold_of)" = "wa-w1:1," ] && ok "(a) passada 1, waiter blind: segura a P2 (nada vai ao nó) e o contador grava wa-w1:1" || bad "(a) passada 1: d1=$(d1) estado=$(hold_of)"
T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "-" ] && [ "$(hold_of)" = "wa-w1:2," ] && ok "(a) passada 2, o mesmo waiter blind (memória unknown): segura de novo e o contador sobe para 2" || bad "(a) passada 2: d1=$(d1) estado=$(hold_of)"
T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && [ "$(hold_of)" = "wa-w1:3," ] && ok "(a) passada 3, o mesmo waiter AINDA blind: o hold expira e a P2 com veredito node VAI ao nó (só ela: o waiter blind não é despachado)" || bad "(a) passada 3: d1=$(d1) estado=$(hold_of)"
summ | jq -e '.hold_expired==1 and .held==0 and .p2_to_node==1 and .waiter_blind_passes==3 and .waiter_verdict=="blind"' >/dev/null 2>&1 && ok "(a) resumo da passada 3: hold_expired=1 held=0 p2_to_node=1 waiter_blind_passes=3 waiter_verdict=blind (o sinal de que o waiter segue cego NÃO some)" || bad "(a) resumo da passada 3: $(summ | cut -c1-400)"
grep -q 'hold expirado (waiter blind há 3 passadas)' "$WORK/lines" 2>/dev/null && ok "(a) o log diz 'hold expirado (waiter blind há 3 passadas)'" || bad "(a) log sem 'hold expirado': $(grep 'ga-2hd02v' "$WORK/lines" 2>/dev/null | cut -c1-300)"
grep -q 'holds expirados=1' "$WORK/lines" 2>/dev/null && ok "(a) a linha de resumo da passada traz 'holds expirados=1'" || bad "(a) linha de resumo sem holds expirados: $(grep 'passada de WA' "$WORK/lines" 2>/dev/null | cut -c1-500)"
T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && [ "$(hold_of)" = "wa-w1:4," ] && ok "(a) passada 4: continua solto (o contador segue contando: wa-w1:4) — o hold não volta enquanto o waiter estiver blind" || bad "(a) passada 4: d1=$(d1) estado=$(hold_of)"
# (b) o waiter que GANHA veredito zera o contador; depois disso o hold volta a valer por 2 passadas
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(hold_of)" = "wa-w1:2," ] || bad "(b) preparo: estado=$(hold_of)"
W1U2="$(jbp 1 wa-w1 U2 wa-worker story:approved)"; chk wa-w1 10
T_WAIT=wa-w1 sweep "[$W1U2,$P2A]"
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && [ "$(hold_of)" = "wa-w1:0," ] && ok "(b) o waiter muda (updated_at novo), a sonda diz mini (veredito legível): a P2 vai ao nó e o contador ZERA (wa-w1:0)" || bad "(b) veredito legível: d1=$(d1) estado=$(hold_of)"
W1U3="$(jbp 1 wa-w1 U3 wa-worker story:approved)"; chk wa-w1 11
T_WAIT=wa-w1 sweep "[$W1U3,$P2A]"
[ "$(d1)" = "-" ] && [ "$(hold_of)" = "wa-w1:1," ] && ok "(b) o waiter volta a ficar blind: o hold recomeça do 1 (segura) — o contador antigo não vazou" || bad "(b) recomeço: d1=$(d1) estado=$(hold_of)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
chk wa-w1 0; echo 0 > "$WORK/d1.rc.wa-w1"; W1U4="$(jbp 1 wa-w1 U4 wa-worker story:approved)"
T_WAIT=wa-w1 sweep "[$W1U4,$P2A]"
[ "$(hold_of)" = "wa-w1:0," ] && ok "(b) o waiter ganha veredito node: o contador zera também (node e out zeram)" || bad "(b) node não zerou: estado=$(hold_of)"
# (b2) outro waiter recomeça do 0 (o contador é DO waiter, não da cidade)
reset; chk wa-w1 11; chk wa-w2 11; chk wa-p2a 0; setok wa-p2a; W2="$(jbp 1 wa-w2 U1 wa-worker story:approved)"
T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
T_WAIT=wa-w2 sweep "[$W2,$P2A]"
[ "$(d1)" = "-" ] && [ "$(hold_of)" = "wa-w2:1," ] && ok "(b2) outro waiter (wa-w2) blind: recomeça do 1 e segura — a contagem de wa-w1 não vale para ele" || bad "(b2) outro waiter: d1=$(d1) estado=$(hold_of)"
# o botão: valor de HOLD_MAX_SWEEPS
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
for i in 1 2 3; do T_HOLD_MAX=3 T_WAIT=wa-w1 sweep "[$W1,$P2A]"; [ "$(d1)" = "-" ] || bad "(botão) MAX=3 soltou na passada $i: $(d1)"; done
T_HOLD_MAX=3 T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "(botão) HOLD_MAX_SWEEPS=3: três passadas seguram e a 4ª solta" || bad "(botão) MAX=3 na passada 4: d1=$(d1) estado=$(hold_of)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_HOLD_MAX=1 T_WAIT=wa-w1 sweep "[$W1,$P2A]"; r1="$(d1)"; T_HOLD_MAX=1 T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$r1" = "-" ] && [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "(botão) HOLD_MAX_SWEEPS=1: a 1ª passada segura e a 2ª solta" || bad "(botão) MAX=1: 1ª=$r1 2ª=$(d1)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
for i in 1 2 3 4 5; do T_HOLD_MAX=0 T_WAIT=wa-w1 sweep "[$W1,$P2A]"; done
[ "$(d1)" = "-" ] && [ "$(hold_of)" = "-" ] && ok "(botão) HOLD_MAX_SWEEPS=0: o comportamento anterior — 5 passadas seguram, e o estado nem é gravado" || bad "(botão) MAX=0: d1=$(d1) estado=$(hold_of)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
for i in 1 2; do T_HOLD_MAX=zzz T_WAIT=wa-w1 sweep "[$W1,$P2A]"; done; T_HOLD_MAX=zzz T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "(botão) valor ilegível (zzz): vale o padrão 2 — a 3ª passada solta" || bad "(botão) MAX=zzz: d1=$(d1)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
for i in 1 2 3 4; do PILOT_WA_NODE_PASS_HOLD=0 T_WAIT=wa-w1 sweep "[$W1,$P2A]"; done
[ "$(hold_of)" = "-" ] && ok "(botão) PILOT_WA_NODE_PASS_HOLD=0 (sem retenção): o contador nem anda" || bad "(botão) HOLD=0 gravou estado: $(hold_of)"
# (c) o contador só anda quando o waiter foi de fato olhado
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
sweep "[$P2A]"
[ "$(hold_of)" = "wa-w1:2," ] && [ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "(c) varredura SEM waiter: nada é segurado, e o estado fica como estava (wa-w1:2) — um waiter que pisca não reinicia o contador" || bad "(c) sem waiter: d1=$(d1) estado=$(hold_of)"
T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && [ "$(hold_of)" = "wa-w1:3," ] && ok "(c) o waiter volta blind: o contador continua de onde parou (wa-w1:3) e a P2 vai ao nó" || bad "(c) waiter volta: d1=$(d1) estado=$(hold_of)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
T_WAIT=wa-w1 T_SLOTS_BIG=0 sweep "[$P2A]" "[$W1]"
[ "$(hold_of)" = "wa-w1:2," ] && ok "(c) waiter na pista big SEM vaga de despacho (não foi olhado): o contador não anda nem zera" || bad "(c) pista sem vaga mexeu no contador: estado=$(hold_of)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
T_WAIT=wa-w1 sweep "isto não é json" "[$P2A]"
[ "$(hold_of)" = "wa-w1:2," ] && [ "$(d1)" = "wa-p2a big feature pass=1;" ] && ok "(c) pista small ilegível (não sei onde o waiter está): o contador não anda; o hold já expirado (2 passadas) vale" || bad "(c) pista ilegível: d1=$(d1) estado=$(hold_of)"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_EXEMPT=shadow T_WAIT=wa-w1 sweep "[$W1,$P2A]"; T_EXEMPT=shadow T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(hold_of)" = "-" ] && ok "(c) modo shadow (nunca segura nem despacha): o contador não anda" || bad "(c) shadow gravou estado: $(hold_of)"
# o waiter com veredito node cujo apply devolve rc 11 termina blind: conta
reset; chk wa-w1 0; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-w1"; echo 11 > "$WORK/d1.apply.wa-w1"; setok wa-p2a
T_WAIT=wa-w1 T_SPAWN=pilot T_SLOTS=3 sweep "[$W1,$P2A]"
[ "$(hold_of)" = "wa-w1:1," ] && ok "(c) waiter node + apply rc 11 (termina blind): o contador anda (wa-w1:1)" || bad "(c) apply rc 11: estado=$(hold_of)"
# (c2) a P2+ solta pelo fim do hold e cujo dispatch FALHA não conta como 'foi ao nó por hold expirado'
reset; chk wa-w1 11; chk wa-p2a 0; echo 1 > "$WORK/d1.rc.wa-p2a"
for i in 1 2; do T_WAIT=wa-w1 sweep "[$W1,$P2A]"; done; T_WAIT=wa-w1 sweep "[$W1,$P2A]"
summ | jq -e '.hold_expired==0 and .released==1' >/dev/null 2>&1 && ok "(c2) hold expirado mas o dispatch da P2 falhou (rc 1): hold_expired=0 released=1 — só conta a que ficou com o nó" || bad "(c2) resumo: $(summ | cut -c1-400)"
# (d) estado ilegível ou que não grava NUNCA solta a P2+ — segue segurando, e AVISA
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a; printf '1\twa-w1\tabc\n' > "$HOLD_STATE"
T_WAIT=wa-w1 sweep "[$W1,$P2A]"
[ "$(d1)" = "-" ] && [ "$(hold_of)" = "wa-w1:1," ] && ok "(d) estado com contagem ilegível ('abc'): conta como 0 — segura a P2, e a escrita da passada conserta o arquivo (wa-w1:1)" || bad "(d) contagem ilegível: d1=$(d1) estado=$(hold_of)"
grep -q 'WARN.*leitura do estado do hold falhou' "$WORK/lines" 2>/dev/null && ok "(d) …e AVISA no log (o estado ilegível não passa calado)" || bad "(d) estado ilegível sem aviso: $(cut -c1-200 "$WORK/lines" 2>/dev/null | tr '\n' '|')"
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a; echo x > "$WORK/city/.gc/notadir"
for i in 1 2 3; do T_HOLD_STATE="$WORK/city/.gc/notadir/h.tsv" T_WAIT=wa-w1 sweep "[$W1,$P2A]"; done
[ "$(d1)" = "-" ] && ok "(d) estado que não grava (pasta impossível): a P2 NUNCA é solta por isso — o contador não anda e o hold segura (o comportamento anterior)" || bad "(d) estado sem escrita soltou a P2: d1=$(d1)"
grep -q 'WARN.*escrita do estado do hold falhou' "$WORK/lines" 2>/dev/null && ok "(d) …e AVISA que não gravou (sem isso o congelamento voltaria em silêncio)" || bad "(d) escrita falha sem aviso: $(cut -c1-200 "$WORK/lines" 2>/dev/null | tr '\n' '|')"
rm -f "$WORK/city/.gc/notadir"
# (e) o waiter é sondado ANTES de qualquer P2+ (a lista é [P2, waiter]; a ordem de trabalho da cidade põe P0/P1 antes na pista real, e o stub do teste não)
reset; chk wa-w1 11; chk wa-p2a 0; setok wa-p2a
T_PROBES=1 T_WAIT=wa-w1 pass "[$P2A,$W1]" >/dev/null
[ "$(wnd_calls)" = 1 ] && grep -q 'wa-w1' "$WORK/wnd.calls" && ok "(e) 1 sonda no orçamento e a P2 vem antes na lista: a sonda vai para o WAITER (não para a P2)" || bad "(e) a sonda não foi ao waiter: $(cat "$WORK/wnd.calls" 2>/dev/null | tr '\n' '|')"
summ | jq -e '.waiter_verdict=="blind" and .probed==1' >/dev/null 2>&1 && ok "(e) resumo: waiter_verdict=blind (ele foi olhado, não ficou unseen por falta de orçamento)" || bad "(e) resumo: $(summ | cut -c1-300)"
reset; chk wa-w1 0; chk wa-p2a 0; setok wa-w1 wa-p2a
T_PROBES=1 T_WAIT=wa-w1 pass "[$P2A,$W1]" >/dev/null
[ "$(d1)" = "wa-w1 small feature pass=1;" ] && ok "(e) waiter com veredito node e a P2 antes na lista, 1 sonda: o waiter fica com a vaga do nó" || bad "(e) waiter perdeu a vaga para a P2: $(d1)"
reset; chk wa-w1 0; chk wa-p2a 0; setok wa-w1 wa-p2a
T_WAIT=ps-zz pass "[$P2A,$W1]" >/dev/null
[ "$(d1)" = "wa-p2a small feature pass=1;" ] && ok "(e) waiter de outro rig: a ordem da lista não muda (só o waiter de WA passa à frente)" || bad "(e) ordem mudou sem waiter de WA: $(d1)"
# os ajudantes sozinhos: hold_for com o hold expirado, e o estado
holdx() { run_t "_PWP_HOLD_MAX=$1; _PWP_HOLD_PRIOR=$2; x=0; _pilot_wa_node_pass_hold_for '$3' '$4' || x=\$?; echo \"rc=\$x\""; }
r=$(T_WAIT=wa-w1 holdx 2 1 "$P2A" blind);  [ "$r" = "rc=0" ] && ok "hold_for: prior 1 < max 2 → segura (rc 0)" || bad "hold_for prior<max: $r"
r=$(T_WAIT=wa-w1 holdx 2 2 "$P2A" blind);  [ "$r" = "rc=3" ] && ok "hold_for: prior 2 >= max 2 → rc 3 (a retenção valeria e EXPIROU: segue, e quem chama conta)" || bad "hold_for prior=max: $r"
r=$(T_WAIT=wa-w1 holdx 2 7 "$P2A" unseen); [ "$r" = "rc=3" ] && ok "hold_for: prior 7, waiter unseen → rc 3" || bad "hold_for prior>max unseen: $r"
r=$(T_WAIT=wa-w1 holdx 0 9 "$P2A" blind);  [ "$r" = "rc=0" ] && ok "hold_for: max 0 → nunca expira (rc 0)" || bad "hold_for max=0: $r"
r=$(T_WAIT=wa-w1 holdx 2 5 "$Q1" blind);   [ "$r" = "rc=1" ] && ok "hold_for: P1 com hold expirado → rc 1 (nunca foi segurado: nada a contar)" || bad "hold_for P1 expirado: $r"
r=$(T_WAIT=wa-w1 holdx 2 5 "$P9B" blind);  [ "$r" = "rc=2" ] && ok "hold_for: classe ilegível com hold expirado → rc 2 (a classe ilegível segue contada, não vira 'expirado')" || bad "hold_for classe ilegível expirado: $r"
r=$(T_WAIT=wa-w1 holdx 2 5 "$P2A" node);   [ "$r" = "rc=1" ] && ok "hold_for: waiter com veredito + hold expirado → rc 1" || bad "hold_for node expirado: $r"
prior() { PID="$1" run_t 'x=0; o=$(_pilot_wa_node_pass_hold_prior "$PID") || x=$?; echo "rc=$x out=[$o]"'; }
reset; r=$(prior wa-w1);                                                       [ "$r" = "rc=0 out=[0]" ] && ok "prior: sem arquivo → 0 (rc 0: ainda não houve passada blind)" || bad "prior sem arquivo: $r"
( eval "$PRELUDE"; _pilot_wa_node_pass_hold_put wa-w1 4 ) >/dev/null 2>&1
r=$(prior wa-w1);                                                              [ "$r" = "rc=0 out=[4]" ] && ok "prior: put 4 → prior 4" || bad "prior depois do put: $r"
r=$(prior wa-w2);                                                              [ "$r" = "rc=0 out=[0]" ] && ok "prior: outro waiter → 0" || bad "prior de outro waiter: $r"
r=$(prior "");                                                                 [ "$r" = "rc=0 out=[0]" ] && ok "prior: sem id → 0" || bad "prior sem id: $r"
printf '1\twa-w1\n' > "$HOLD_STATE"; r=$(prior wa-w1);                         [ "$r" = "rc=1 out=[0]" ] && ok "prior: linha do waiter SEM contagem → 0 e rc 1 (ilegível, quem chama avisa)" || bad "prior sem contagem: $r"
printf '1\twa-w1\t-3\n' > "$HOLD_STATE"; r=$(prior wa-w1);                     [ "$r" = "rc=1 out=[0]" ] && ok "prior: contagem negativa → 0 e rc 1" || bad "prior negativo: $r"
( eval "$PRELUDE"; _pilot_wa_node_pass_hold_put 'wa-w x' 2 ) >/dev/null 2>&1
r=$(prior 'wa-w x');                                                           [ "$r" = "rc=0 out=[2]" ] && [ "$(wc -l < "$HOLD_STATE" | tr -d ' ')" = 1 ] && ok "put/prior: id com espaço é normalizado igual nos dois lados e continua UMA linha de TSV" || bad "id estranho: $r linhas=$(wc -l < "$HOLD_STATE")"
reset

echo "── (7) dispatch_one: o bloco do yield e o braço do pool (regiões VERBATIM)"
run_block() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log() { :; }
    STORY_ID=wa-blk1; STORY_BEAD_CITY="${BL_CITY:-$WORK/wa-store}"; GC_CITY="$WORK/city"; STORY_LABELS=""; STORY='{}'
    BUILDER_TARGET="${BL_TARGET:-wa-worker-1}"; DISPATCH_RESULT=""; _PNY_EXEMPT_THIS=0
    _PILOT_NODE_ONLY="${BL_NODE_ONLY:-0}"; _PILOT_WA_NODE_PASS="${BL_PASS:-1}"; DRY_RUN=0
    # as duas rotas ligadas: se a bandeira da passada NÃO vencesse a só-nó, o elif da só-nó seguiria a bead de ps-worker (rota do PS ligada) em vez de soltá-la; é o caso que distingue os dois ramos (o wa-worker do store do WA segue nos dois)
    PILOT_WA_NODE_ROUTE=auto; PILOT_PS_NODE_ROUTE=auto
    _pilot_priority_node_exempt() { return 1; }
    _pilot_priority_yield_for() { echo YIELD_ASKED >> "$WORK/block.rel"; return 0; }
    _pilot_priority_yield_say() { :; }
    _pilot_priority_yield_release() { echo "RELEASE $4" >> "$WORK/block.rel"; }
    eval "$(fn_src wa_worker_template)"; eval "$(fn_src _pilot_priority_target_is_pool)"; eval "$(fn_src _pilot_node_only_wa_route_on)"; eval "$(fn_src _pilot_node_only_ps_route_on)"
    blkfn() { eval "$BLOCK_SRC"; echo "CONTINUED"; }
    r=0; blkfn > "$WORK/blk.out" || r=$?
    out="$(cat "$WORK/blk.out" 2>/dev/null || true)"
    echo "rc=$r result=${DISPATCH_RESULT:-} ${out:-NOT-CONTINUED} rel=$(tr '\n' ',' < "$WORK/block.rel" 2>/dev/null || true)"
  ) 2>&1 | tail -1
}
blk() { rm -f "$WORK/block.rel"; run_block; }
r=$(blk);                                                       [ "$r" = "rc=0 result= CONTINUED rel=" ] && ok "passada de WA, alvo wa-worker no store do WA: SEGUE, sem consultar o yield (a vaga do nó não é a da P0/P1) — $r" || bad "bloco, caso feliz: $r"
r=$(BL_CITY="$WORK/city" blk);                                  [ "$r" = "rc=1 result=wa_node_pass_released NOT-CONTINUED rel=RELEASE wa-node-pass," ] && ok "bead do HQ com alvo wa-worker: solta SEM carimbo (4º arg 'wa-node-pass', não wa-worker) — $r" || bad "bloco, HQ: $r"
r=$(BL_TARGET=ps-worker-1 blk);                                 case "$r" in "rc=1 result=wa_node_pass_released"*"RELEASE wa-node-pass,") ok "ps-worker: solta sem carimbo — $r" ;; *) bad "bloco, ps-worker: $r" ;; esac
r=$(BL_TARGET=oracle-wa blk);                                   case "$r" in "rc=1 result=wa_node_pass_released"*"RELEASE wa-node-pass,") ok "crew nomeada: solta sem carimbo (a passada só leva ao nó, nunca a uma crew) — $r" ;; *) bad "bloco, crew: $r" ;; esac
r=$(BL_PASS=0 blk);                                             case "$r" in *YIELD_ASKED*) ok "fora da passada: o yield é consultado, como sempre" ;; *) bad "fora da passada o yield não foi consultado: $r" ;; esac
# ga-2hd02v.3.9: com a passada rodando na só-nó, a bandeira da passada vence o elif da só-nó (que seguiria o ps-worker e o wa-worker com rota ligada)
r=$(BL_NODE_ONLY=1 blk);                                        [ "$r" = "rc=0 result= CONTINUED rel=" ] && ok "só-nó, passada de WA, wa-worker no store do WA: SEGUE, sem consultar o yield — $r" || bad "bloco, só-nó, caso feliz: $r"
r=$(BL_NODE_ONLY=1 BL_TARGET=ps-worker-1 blk);                  case "$r" in "rc=1 result=wa_node_pass_released"*"RELEASE wa-node-pass,") ok "só-nó + passada, ps-worker (com a rota do PS ligada): solta sem carimbo — a bandeira da passada vence o elif da só-nó — $r" ;; *) bad "bloco, só-nó, ps-worker: $r" ;; esac
r=$(BL_NODE_ONLY=1 BL_CITY="$WORK/city" blk);                   [ "$r" = "rc=1 result=wa_node_pass_released NOT-CONTINUED rel=RELEASE wa-node-pass," ] && ok "só-nó + passada, bead do HQ com alvo wa-worker: solta sem carimbo — $r" || bad "bloco, só-nó, HQ: $r"
r=$(BL_NODE_ONLY=1 BL_TARGET=oracle-wa blk);                    case "$r" in "rc=1 result=wa_node_pass_released"*"RELEASE wa-node-pass,") ok "só-nó + passada, crew nomeada: solta sem carimbo — $r" ;; *) bad "bloco, só-nó, crew: $r" ;; esac

run_arm() {
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    log() { :; }
    warn() { :; }
    STORY_ID=wa-arm1; STORY_BEAD_CITY="$WORK/wa-store"; _SLING_TARGET=wa-worker; BUILDER_TARGET=wa-worker-1; DISPATCH_RESULT=""
    _PILOT_NODE_ONLY="${AR_NODE_ONLY:-0}"; _PILOT_WA_NODE_PASS="${AR_PASS:-1}"
    : > "$WORK/arm.ev"
    _pilot_wa_node_adopt()   { echo ADOPT >> "$WORK/arm.ev"; return "${AR_ADOPT:-0}"; }
    _pilot_wa_node_unadopt() { echo UNADOPT >> "$WORK/arm.ev"; return 0; }
    _pilot_wa_node_decide()  { echo DECIDE >> "$WORK/arm.ev"; return "${AR_RC:-1}"; }
    _pilot_priority_yield_release() { echo "RELEASE $4" >> "$WORK/arm.ev"; }
    unmark_pool_builder() { echo "UNMARK $1" >> "$WORK/arm.ev"; }
    armfn() { eval "$ARM_SRC"; echo "CONTINUED target=$_SLING_TARGET"; }
    r=0; armfn > "$WORK/arm.out" || r=$?
    out="$(cat "$WORK/arm.out" 2>/dev/null || true)"
    echo "rc=$r result=${DISPATCH_RESULT:-} ${out:-NOT-CONTINUED} ev=$(tr '\n' ',' < "$WORK/arm.ev")"
  ) 2>&1 | tail -1
}
reset; r=$(AR_RC=0 run_arm);  [ "$r" = "rc=0 result= CONTINUED target=wa-worker-remote ev=ADOPT,DECIDE,UNMARK wa-worker-1," ] && ok "gancho rc 0: adota ANTES de decidir, a bead é do nó, e a vaga virtual do mini volta (UNMARK) — $r" || bad "arm rc 0: $r"
reset; r=$(AR_RC=1 run_arm);  [ "$r" = "rc=1 result=wa_node_pass_released NOT-CONTINUED ev=ADOPT,DECIDE,UNADOPT,RELEASE wa-node-pass," ] && ok "gancho rc 1: devolve a rota (UNADOPT) e solta a claim SEM carimbo — nunca chega ao pool do mini — $r" || bad "arm rc 1: $r"
reset; r=$(AR_RC=2 run_arm);  case "$r" in "rc=1 result=wa_node_unknown"*"ev=ADOPT,DECIDE,") ok "gancho rc 2 (a escrita pode ter acontecido): NÃO devolve a rota (o nó pode ter ficado com a bead) e não despacha — $r" ;; *) bad "arm rc 2: $r" ;; esac
reset; r=$(AR_ADOPT=1 AR_RC=0 run_arm); [ "$r" = "rc=1 result=wa_node_pass_released NOT-CONTINUED ev=ADOPT,RELEASE wa-node-pass," ] && ok "adotar falhou: o gancho NEM é chamado, solta sem carimbo — $r" || bad "arm, adotar falhou: $r"
reset; r=$(AR_PASS=0 AR_RC=1 run_arm); [ "$r" = "rc=0 result= CONTINUED target=wa-worker ev=DECIDE," ] && ok "fora da passada: nada de adotar; rc 1 segue ao pool do mini, como sempre — $r" || bad "arm fora da passada: $r"
reset; r=$(AR_PASS=0 AR_RC=0 run_arm); [ "$r" = "rc=0 result= CONTINUED target=wa-worker-remote ev=DECIDE," ] && ok "fora da passada, rc 0: alvo do nó e a vaga virtual NÃO é devolvida (comportamento de antes)" || bad "arm fora da passada rc 0: $r"
# ga-2hd02v.3.9: na só-nó o braço da passada vem ANTES do elif da só-nó — rc 1 devolve a rota que a passada tirou (senão a bead perde o carimbo wa-worker) em vez de só soltar como disk_floor_node_only
reset; r=$(AR_NODE_ONLY=1 AR_RC=0 run_arm);  [ "$r" = "rc=0 result= CONTINUED target=wa-worker-remote ev=ADOPT,DECIDE,UNMARK wa-worker-1," ] && ok "só-nó + passada, gancho rc 0: a bead é do nó e a vaga virtual do mini volta — $r" || bad "arm só-nó rc 0: $r"
reset; r=$(AR_NODE_ONLY=1 AR_RC=1 run_arm);  [ "$r" = "rc=1 result=wa_node_pass_released NOT-CONTINUED ev=ADOPT,DECIDE,UNADOPT,RELEASE wa-node-pass," ] && ok "só-nó + passada, gancho rc 1: devolve a rota (UNADOPT) e solta com wa_node_pass_released, NÃO com disk_floor_node_only (que deixaria a bead sem o carimbo) — $r" || bad "arm só-nó rc 1: $r"
reset; r=$(AR_NODE_ONLY=1 AR_RC=2 run_arm);  case "$r" in "rc=1 result=wa_node_unknown"*"ev=ADOPT,DECIDE,") ok "só-nó + passada, gancho rc 2: não devolve a rota e não despacha — $r" ;; *) bad "arm só-nó rc 2: $r" ;; esac
reset; r=$(AR_NODE_ONLY=1 AR_ADOPT=1 AR_RC=0 run_arm); [ "$r" = "rc=1 result=wa_node_pass_released NOT-CONTINUED ev=ADOPT,RELEASE wa-node-pass," ] && ok "só-nó + passada, adotar falhou: o gancho NEM é chamado — $r" || bad "arm só-nó, adotar falhou: $r"
reset; r=$(AR_NODE_ONLY=1 AR_PASS=0 AR_RC=1 run_arm); case "$r" in "rc=1 result=disk_floor_node_only"*"ev=DECIDE,"*) ok "só-nó FORA da passada (bead de lane), gancho rc 1: continua soltando com disk_floor_node_only, sem tocar na rota — $r" ;; *) bad "arm só-nó fora da passada: $r" ;; esac

echo "── (8) o gancho exporta o rc do apply (a passada decide por ele: 12 = nó cheio)"
dec() { ( eval "$PRELUDE"; eval "$F_DECIDE"; _pilot_wa_node_open() { return 0; }; _pilot_slow_spawn_budget_spent() { return 1; }; _pilot_wa_node_settle() { :; }
          x=0; _pilot_wa_node_decide wa-a "$WORK/store" wa-worker || x=$?; echo "ret=$x apply_rc=${_PWN_APPLY_RC:-<vazio>}" ) 2>&1 | tail -1; }
reset; bead "$BEAD_FREE"; echo 12 > "$WORK/apply.rc"; r=$(dec);  [ "$r" = "ret=1 apply_rc=12" ] && ok "apply rc 12: o gancho devolve 1 e deixa _PWN_APPLY_RC=12" || bad "exporta rc 12: $r"
reset; bead "$BEAD_FREE"; echo 10 > "$WORK/apply.rc"; r=$(dec);  [ "$r" = "ret=1 apply_rc=10" ] && ok "apply rc 10: _PWN_APPLY_RC=10" || bad "exporta rc 10: $r"
reset; bead "$BEAD_FREE"; echo 0 > "$WORK/apply.rc";  r=$(dec);  [ "$r" = "ret=0 apply_rc=0" ] && ok "apply rc 0 (modo pool): _PWN_APPLY_RC=0 e o gancho devolve 0" || bad "exporta rc 0: $r"
reset; r=$( ( eval "$PRELUDE"; eval "$F_DECIDE"; _PWN_APPLY_RC=12; PILOT_WA_NODE_ROUTE=off; x=0; _pilot_wa_node_decide wa-a "$WORK/store" wa-worker || x=$?; echo "ret=$x apply_rc=${_PWN_APPLY_RC:-<vazio>}" ) 2>&1 | tail -1 )
[ "$r" = "ret=1 apply_rc=<vazio>" ] && ok "gancho que sai antes do apply (rota off): zera o rc — um rc velho nunca é lido como o desta bead" || bad "rc velho vazou: $r"

echo "── (9) a ordem no dispatcher"
L_PASSDEF=$(grep -n '^_pilot_wa_node_pass() {' "$DISPATCHER" | head -1 | cut -d: -f1)
L_CALL=$(grep -n '^_pilot_wa_node_pass$\|^_pilot_wa_node_pass || true$' "$DISPATCHER" | head -1 | cut -d: -f1)
L_SMALL=$(grep -n '^  dispatch_lane "small"' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_PASSDEF" ] && [ -n "$L_CALL" ] && [ -n "$L_SMALL" ] && [ "$L_PASSDEF" -lt "$L_CALL" ] && [ "$L_CALL" -lt "$L_SMALL" ] && ok "a passada é definida ($L_PASSDEF), chamada ($L_CALL) e só então vêm as pistas normais ($L_SMALL)" || bad "ordem da passada: def=$L_PASSDEF call=$L_CALL small=$L_SMALL"
grep -qE '^_PILOT_WA_NODE_PASS=0( |$)' <<<"$PWP_INIT" && ok "a bandeira nasce em 0" || bad "a bandeira não nasce em 0"
L_ADOPT=$(grep -n '_pilot_wa_node_adopt "\$STORY_ID"' "$DISPATCHER" | head -1 | cut -d: -f1); L_DEC=$(grep -n '_pilot_wa_node_decide "\$STORY_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
[ -n "$L_ADOPT" ] && [ -n "$L_DEC" ] && [ "$L_ADOPT" -lt "$L_DEC" ] && ok "dispatch_one adota ($L_ADOPT) antes de chamar o gancho ($L_DEC)" || bad "adotar não vem antes do gancho ($L_ADOPT / $L_DEC)"
grep -q '"wa_node_pass_released"' "$DISPATCHER" && grep -q 'wa_node_pass_released' <(awk '/def cls\(\$o\)/,/else "failed_other" end;/' "$DISPATCHER") && ok "wa_node_pass_released está classificado no pilot_sweep (refused_by_guard)" || bad "wa_node_pass_released fora do jq do pilot_sweep (cai em failed_other)"

if [ -z "${WNP_MUTANT:-}" ] && [ -z "${WNP_NO_MUTANTS:-}" ]; then
  echo "── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo"
  nm=0
  mutant() {
    nm=$((nm+1)); local m="$WORK/disp.mut$nm.sh"
    python3 -I -c 'import sys
s=open(sys.argv[1],encoding="utf-8").read()
if s.count(sys.argv[2])!=1: sys.exit(3)
open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3]))' "$DISPATCHER" "$2" "$3" "$m" 2>/dev/null \
      || { bad "mutante '$1': a âncora não casa exatamente 1 vez"; return; }
    local r; r=$(WNP_MUTANT=1 PILOT_DISPATCHER_PATH="$m" bash "$0" 2>&1 | tail -1)
    case "$r" in "RESULT 0/"*) bad "mutante '$1' NÃO foi pego ($r)" ;; "RESULT "*) ok "mutante '$1' pego ($r)" ;; *) bad "mutante '$1': sem resultado ($r)" ;; esac
  }
  # as âncoras são ASCII de propósito (o python3 lê o argv no locale do shell e o arquivo em UTF-8)
  MUTANTS_FILE="$SELF_DIR/pilot-dispatcher.wa-node-pass.mutants.txt"
  if [ -f "$MUTANTS_FILE" ]; then
    # formato: nome<TAB>âncora<TAB>troca, uma linha por mutante (\n escrito como \\n)
    while IFS=$'\t' read -r mname manchor mrepl; do
      [ -n "$mname" ] || continue
      manchor="${manchor//\\n/$'\n'}"; mrepl="${mrepl//\\n/$'\n'}"
      mutant "$mname" "$manchor" "$mrepl"
    done < "$MUTANTS_FILE"
  else
    bad "lista de mutantes ausente ($MUTANTS_FILE)"
  fi
fi
echo "── $PASS ok, $FAIL falhas"
[ "$FAIL" = 0 ]
