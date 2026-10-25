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
#   não chega ao gancho) · (8) o gancho exporta o rc do apply · (9) a ordem dos pontos de chamada.
# COMO RODA: as funções e as regiões são extraídas VERBATIM do dispatcher (awk) e rodam em shells filhos sob `set -euo pipefail`, PATH de sandbox (selftest-sandbox-path.lib.sh: sem gc/bd reais), bd e
#   wa-node-dispatch.sh falsos. Contra um dispatcher sem a fatia o arquivo se recusa a começar — o vermelho honesto.
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (WNP_NO_MUTANTS=1 pula) tem que reprovar este arquivo.
# Variáveis: PILOT_DISPATCHER_PATH · WNP_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${WNP_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${WNP_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# vazio (a função/região não existe) → texto vazio e o need_fn recusa começar; falhou/ilegível (dispatcher que o awk não lê) → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
need_fn() { local s; s="$(fn_src "$1")"; [ -n "$s" ] || { echo "FATAL: $1() not found in $DISPATCHER (ga-2hd02v.9 not applied)" >&2; exit 2; }; printf '%s' "$s"; }
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
F_MODE="$(need_fn _pilot_wa_node_pass_mode)"; F_PRE="$(need_fn _pilot_wa_node_pass_pre)"
F_MHIT="$(need_fn _pilot_wa_node_pass_memo_hit)"; F_MPUT="$(need_fn _pilot_wa_node_pass_memo_put)"
F_CHECK="$(need_fn _pilot_wa_node_pass_check)"; F_ADOPT="$(need_fn _pilot_wa_node_adopt)"; F_UNADOPT="$(need_fn _pilot_wa_node_unadopt)"
F_PASS="$(need_fn _pilot_wa_node_pass)"; F_VETO="$(need_fn _pilot_node_first_veto)"; F_SPAWN="$(need_fn _pilot_wa_node_spawn_mode)"
F_DECIDE="$(need_fn _pilot_wa_node_decide)"; F_STATE="$(need_fn _pilot_wa_node_pass_state)"
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
case "$rc" in
  0)  echo "{\"verdict\":\"node\",\"basis\":\"$basis\",\"reasons\":[]}" ;;
  10) echo '{"verdict":"mini","basis":"","reasons":["x"]}' ;;
  11) echo '{"verdict":"unknown","basis":"","reasons":["x"]}' ;;
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
  eval "$F_VETO"; eval "$F_SPAWN"; eval "$F_MODE"; eval "$F_PRE"; eval "$F_MHIT"; eval "$F_MPUT"; eval "$F_CHECK"; eval "$F_STATE"; eval "$F_ADOPT"; eval "$F_UNADOPT"; eval "$F_PASS"
  _pilot_priority_refusal_of() { case "${T_REFUSAL-}" in FAIL) return 1 ;; *) printf "%s" "${T_REFUSAL-}"; return 0 ;; esac; }
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
T_PROBES=zzz pass "$L5" >/dev/null; [ "$(wnd_calls)" = 5 ] && ok "teto de sondas ilegível volta ao padrão (12): as 5 são sondadas" || bad "teto ilegível: $(wnd_calls)"
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
