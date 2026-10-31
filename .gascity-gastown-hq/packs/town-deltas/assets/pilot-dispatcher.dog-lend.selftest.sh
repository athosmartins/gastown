#!/usr/bin/env bash
# pilot-dispatcher.dog-lend.selftest.sh — ga-hfx1kou (parte 2)
#
# Ordem do Athos (31/10): "todos os P0 e P1 em aprovadas podem ser rodeados para os dogs". Medido: os pools são POR RIG — P0/P1 de WA só vão ao wa-worker, os de PS só ao
# ps-worker — e os dogs ficavam ociosos com o pool do rig cheio. A passada _pilot_dog_lend_pass (depois das pistas) EMPRESTA a P0/P1 aprovada de um rig cujo pool está
# POSITIVAMENTE cheio a um dog do mini, por uma bead-gancho no HQ (a sonda do dog só lê o HQ) que manda o dog trabalhar num worktree DO RIG, ler o CLAUDE.md DO RIG antes de
# editar, e dar push + /gate-done de lá.
#
# Cenários (a)-(e) do aceite + os vetos e as três saídas de cada leitura nova:
#   (a) HQ P0 sem rota ganha rota no varrimento .......... é do vigia (scripts/pilot-missing-route-watchdog.sh --selftest, cenários 65-78); aqui só a checagem de fiação
#   (b) P0 de WA, pool cheio, dog livre ................... emprestada a gastown.dog, com o texto do worktree do rig
#   (c) veredito node ..................................... NUNCA a um dog do mini (nem a nenhum alvo); fica na fila
#   (d) P2 de WA com o pool cheio ......................... não vai a dog
#   (e) controle negativo ................................. este arquivo sai com FATAL (rc 2) no HEAD anterior, que não tem _pilot_dog_lend_pass
#
# As funções saem VERBATIM do despachante (awk); o resto (bd, gc, as sondas de pool/disco/memória/classificador) são stubs. gc e bd são EXECUTÁVEIS REAIS no PATH do
# sandbox (um `timeout` faz exec do argumento, uma função shell chamada gc seria invisível a ele).
#
# Exit 0 sse todo cenário se comporta como esperado.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }

# O conjunto inteiro da passada; qualquer um faltando = FATAL (é o controle negativo (e): o HEAD anterior não tem nenhum).
LEND_FUNCS="_pilot_dog_lend_mode _pilot_dog_lend_veto _pilot_dog_lend_pool_of _pilot_dog_lend_pool_full _pilot_dog_lend_dog_free _pilot_dog_lend_mini_ok \
_pilot_dog_lend_node_gate _pilot_dog_lend_reread _pilot_dog_lend_still_free _pilot_dog_lend_release _pilot_dog_lend_prompt _pilot_dog_lend_one _pilot_dog_lend_pass"
FUNCS=""
for _f in $LEND_FUNCS; do
  [ -n "$(fn_src "$_f")" ] || { echo "FATAL: $_f() not found in $DISPATCHER — a passada de empréstimo ao dog (ga-hfx1kou) não existe neste código" >&2; exit 2; }
  FUNCS="$FUNCS
$(fn_src "$_f")"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-doglend-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/db" "$WORK/city" "$WORK/wa" "$WORK/ps" "$WORK/traco-bim"

# ── bd falso: uma bead = um arquivo em $WORK/db/<id>.json; show/update/label/comment/list ───────────────────────────────────────────────────────────────────────────
cat > "$WORK/bin/bd" <<'BDEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
echo "$*" >> "$W/bd.log"
if [ "${1:-}" = "-C" ]; then shift 2; fi
cmd="${1:-}"; shift || true
rw() { local f="$1" prog="$2"; shift 2; jq -c "$@" "$prog" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
case "$cmd" in
  show)
    id="$1"
    [ -f "$W/bd.fail.show.$id" ] && { echo "boom" >&2; exit 1; }
    [ -f "$W/db/$id.json" ] || exit 1
    jq -c '[.]' "$W/db/$id.json" ;;
  update)
    id="$1"; shift
    [ -f "$W/bd.fail.update.$id" ] && exit 1
    f="$W/db/$id.json"; [ -f "$f" ] || exit 1
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata) kv="$2"; rw "$f" '.metadata[$k]=$v' --arg k "${kv%%=*}" --arg v "${kv#*=}"; shift 2 ;;
        --unset-metadata) rw "$f" 'del(.metadata[$k])' --arg k "$2"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  label)
    sub="$1"; id="$2"; l="$3"
    f="$W/db/$id.json"; [ -f "$f" ] || exit 1
    case "$sub" in
      add)
        [ -f "$W/bd.fail.labeladd.$l" ] && exit 1
        [ -f "$W/bd.lost.labeladd.$l" ] && exit 0      # a escrita "passa" (rc 0) mas some — o caso da leitura que desmente
        rw "$f" '.labels = ((.labels // []) + [$l] | unique)' --arg l "$l" ;;
      remove) rw "$f" '.labels = ((.labels // []) - [$l])' --arg l "$l" ;;
    esac ;;
  comment) echo "$1: $2" >> "$W/comments.log" ;;
  list)
    # só o orphan-guard do sling: lista as beads do HQ cujo título bate com --title
    t=""; while [ $# -gt 0 ]; do [ "$1" = "--title" ] && t="$2"; shift; done
    [ -f "$W/bd.fail.list" ] && exit 1
    jq -cs --arg t "$t" '[.[] | select(.title == $t)]' "$W"/db/ga-wrap*.json 2>/dev/null || echo '[]' ;;
esac
exit 0
BDEOF
chmod +x "$WORK/bin/bd"

# ── gc falso: sling gastown.dog --stdin cria a bead-gancho; session nudge só registra ──────────────────────────────────────────────────────────────────────────────────
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
echo "$*" >> "$W/gc.log"
case "$*" in
  *" sling "*)
    cat > "$W/sling.in.tmp"
    n=$(( $(cat "$W/sling.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$W/sling.count"
    cp "$W/sling.in.tmp" "$W/sling.$n.in"
    [ -f "$W/sling.fail" ] && { echo "sling boom" >&2; exit 1; }
    title="$(head -1 "$W/sling.in.tmp")"
    id="ga-wrap$n"
    jq -cn --arg id "$id" --arg t "$title" '{id:$id,title:$t,status:"open",labels:[],metadata:{"gc.routed_to":"gastown.dog"}}' > "$W/db/$id.json"
    if [ -f "$W/sling.noid" ]; then echo '{}'; else jq -cn --arg id "$id" '{bead_id:$id}'; fi ;;
  *"session nudge"*)
    [ -f "$W/nudge.fail" ] && exit 1
    echo ok ;;
esac
exit 0
GCEOF
chmod +x "$WORK/bin/gc"
cat > "$WORK/bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
shift
exec "$@"
TOEOF
chmod +x "$WORK/bin/timeout"
sandbox_path_init "$WORK" jq || exit 2

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# mk <id> <prio> [labels-csv] [jq-extra-filter]  → grava a bead em db/ e a soma aos candidatos (small.json); o prefixo diz a loja (wa → $WORK/wa, ps → $WORK/ps, ga → city, tb → traco-bim)
mk() {
  local id="$1" prio="$2" labels="${3:-story:approved,exec:auto}" extra="${4:-.}" lj
  lj=$(printf '%s' "$labels" | jq -Rc 'split(",") | map(select(length > 0))')
  jq -cn --arg id "$id" --argjson p "$prio" --argjson l "$lj" --arg ts "2026-10-3${5:-1}T10:00:00Z" \
    '{id:$id,title:("bead "+$id),priority:$p,status:"open",issue_type:"bug",labels:$l,metadata:{"gc.routed_to":"wa-worker"},assignee:"",created_at:$ts}' \
    | jq -c "$extra" > "$WORK/db/$id.json"
  jq -c '.' "$WORK/db/$id.json" >> "$WORK/cands.ndjson"
}
reset() {
  rm -rf "$WORK/db" "$WORK"/*.log "$WORK"/sling.* "$WORK"/nudge.fail "$WORK"/cands.ndjson "$WORK"/bd.fail.* "$WORK"/bd.lost.* "$WORK"/verdict.calls "$WORK"/disk.calls
  mkdir -p "$WORK/db"; : > "$WORK/cands.ndjson"
  T_WA_LIVE=4; T_PS_LIVE=2; T_DOG_LIVE=1; T_DISK=ok; T_MEM=ok; T_VERDICT=mini; T_REFUSAL=""; T_REFUSAL_FAIL=0; T_STOP=0
  unset T_NODE_ONLY T_MODE T_MAX T_DRY T_DOG_MAX
}
logged() { grep -qF -- "$1" "$WORK/log.txt" 2>/dev/null; }
slings() { [ -f "$WORK/sling.count" ] && cat "$WORK/sling.count" || echo 0; }
lbl() { jq -r '(.labels // []) | join(",")' "$WORK/db/$1.json"; }
meta() { jq -r --arg k "$2" '.metadata[$k] // ""' "$WORK/db/$1.json"; }
has_label() { case ",$(lbl "$1")," in *",$2,"*) return 0 ;; esac; return 1; }
bd_writes() { grep -cE '^(-C [^ ]+ )?(update|label|comment) ' "$WORK/bd.log" 2>/dev/null || true; }

# run_pass — UMA varredura: o harness tem os stubs dos vizinhos (já testados nos seus próprios selftests) e as funções VERBATIM do despachante.
run_pass() {
  (
    PATH="$SANDBOX_PATH"; SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    GC_CITY="$WORK/city"; DRY_RUN="${T_DRY:-0}"; GC_ALIAS="gastown.dog-5"; export GC_ALIAS
    PILOT_RIG_PATHS_JSON="warm"; PILOT_INFLIGHT_SLEEP=0; PILOT_INFLIGHT_RETRIES=2
    PILOT_WA_WORKER_MAX=4; PILOT_PS_WORKER_MAX=2
    [ -z "${T_MODE:-}" ] || PILOT_DOG_LEND="$T_MODE"
    [ -z "${T_MAX:-}" ] || PILOT_DOG_LEND_MAX_PER_SWEEP="$T_MAX"
    [ -z "${T_DOG_MAX:-}" ] || PILOT_DOG_LEND_DOG_MAX="$T_DOG_MAX"
    _PILOT_NODE_ONLY="${T_NODE_ONLY:-0}"
    _PCAP_LIVE_WA="" ; _PCAP_LIVE_PS=""
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    err()  { printf 'err\t%s\n'  "$*" >> "$WORK/log.txt"; }
    # vizinhos stubados ---------------------------------------------------------------------------------------------------------------------------------------------
    _pilot_bead_home_store() { case "${1%%-*}" in wa) printf '%s' "$WORK/wa" ;; ps) printf '%s' "$WORK/ps" ;; tb) printf '%s' "$WORK/traco-bim" ;; ga) printf '%s' "$GC_CITY" ;; *) printf '' ;; esac; }
    _pilot_pool_store_verdict() {
      _PSV_VERDICT="unknown"; _PSV_POOL_RIG=""
      [ -n "${2:-}" ] || return 0
      case "$1" in
        wa-worker) _PSV_POOL_RIG=whatsapp_automation; [ "$2" = "$WORK/wa" ] && _PSV_VERDICT=serves || _PSV_VERDICT=blind ;;
        # o traco-bim (repo sem gate) FINGE servir o ps-worker de propósito: só a recusa explícita de «repo sem gate» o segura (sem ela, o stub o deixaria passar)
        ps-worker) _PSV_POOL_RIG=property_scrapers;   { [ "$2" = "$WORK/ps" ] || [ "$2" = "$WORK/traco-bim" ]; } && _PSV_VERDICT=serves || _PSV_VERDICT=blind ;;
        *) _PSV_VERDICT=serves ;;
      esac
      return 0
    }
    _pilot_pool_live_count() {
      local _n
      case "$1" in wa-worker) _n="$T_WA_LIVE" ;; ps-worker) _n="$T_PS_LIVE" ;; *) return 1 ;; esac
      case "$_n" in ''|*[!0-9]*) return 1 ;; esac
      _PCAP_N="$_n"; return 0
    }
    _pilot_live_session_count() {
      _PLSC_N=""
      case "$T_DOG_LIVE" in ''|*[!0-9]*) _PLSC_UNREADABLE=1; return 1 ;; esac
      _PLSC_N="$T_DOG_LIVE"; return 0
    }
    _pilot_disk_floor() {
      echo x >> "$WORK/disk.calls"
      PILOT_DISK_FLOOR_STATE="$T_DISK"; PILOT_DISK_FLOOR_DETAIL="disk=$T_DISK"
      [ "$T_DISK" = low ] && return 0
      return 1
    }
    _pilot_memory_tight() {
      PILOT_MEM_TIGHT_REASON=""; PILOT_MEM_TIGHT_BLIND=""; PILOT_MEM_TIGHT_DETAIL=""
      case "$T_MEM" in tight) PILOT_MEM_TIGHT_REASON="swap-used"; return 0 ;; blind) PILOT_MEM_TIGHT_BLIND="swap_used,swap_free" ;; esac
      return 1
    }
    _pilot_wa_node_pass_check() { echo "$1" >> "$WORK/verdict.calls"; _PWP_V="$T_VERDICT"; _PWP_BASIS=""; return 0; }
    _pilot_priority_refusal_of() { [ "$T_REFUSAL_FAIL" = 1 ] && return 1; printf '%s' "$T_REFUSAL"; return 0; }
    _pilot_order_pool() { printf '%s' "$1" | jq -c 'sort_by([.priority, .created_at])'; }
    classify_lane() { printf 'small'; }
    _pilot_dispatch_should_stop() { [ "$T_STOP" = 1 ]; }
    _pilot_pool_target_has_live_session() { return 1; }
    _pilot_suppress_reused_sling() { echo "suppress $2" >> "$WORK/suppress.log"; }
    _pilot_unsuppress_sling() { echo "unsuppress $2" >> "$WORK/suppress.log"; }
    SMALL_CANDIDATES=$(jq -cs '.' "$WORK/cands.ndjson"); BIG_CANDIDATES="[]"
    eval "$FUNCS"
    _pilot_dog_lend_pass
    echo "$_PCAP_LIVE_WA|$_PCAP_LIVE_PS" > "$WORK/pcap.after"
    echo "END" >> "$WORK/log.txt"
  )
}
sweep() { : > "$WORK/log.txt"; : > "$WORK/bd.log"; run_pass; }

echo "pilot-dispatcher.dog-lend.selftest — a dog takes a rig's P0/P1 when that rig's pool is full (ga-hfx1kou)"

# ── (b) P0 de WA, pool cheio, dog livre → emprestada, com o contexto do rig ─────────────────────────────────────────────────────────────────────────────────────────
echo "(b) WA P0, wa-worker 4/4, dog 1/3, veredito mini — emprestada a gastown.dog com o worktree do rig"
reset; mk wa-p0 0
sweep
[ "$(slings)" = 1 ] && ok "b: exatamente 1 sling" || bad "b: slings=$(slings) (esperado 1)"
grep -q 'sling gastown.dog --stdin' "$WORK/gc.log" 2>/dev/null && ok "b: alvo do sling é gastown.dog" || bad "b: o sling não foi a gastown.dog: $(cat "$WORK/gc.log" 2>/dev/null)"
P="$WORK/sling.1.in"
for pat in "wa-p0" "$WORK/wa" "CLAUDE.md" "worktree add" "/gate-done" "bd -C \"$WORK/wa\"" "ensure_merge_driver" "ensure_symlinks" "P0"; do
  grep -qF -- "$pat" "$P" 2>/dev/null && ok "b: o texto da bead-gancho traz «$pat»" || bad "b: o texto da bead-gancho NÃO traz «$pat»"
done
grep -qE 'read .*CLAUDE.md.*BEFORE|BEFORE.*CLAUDE.md|CLAUDE.md.*BEFORE' "$P" 2>/dev/null && ok "b: manda ler o CLAUDE.md do rig ANTES de editar" || bad "b: não diz para ler o CLAUDE.md ANTES de editar"
has_label wa-p0 story:in-flight && ok "b: a bead do rig ganhou story:in-flight" || bad "b: sem story:in-flight (labels=$(lbl wa-p0))"
has_label wa-p0 pilot:dispatched && ok "b: ...e pilot:dispatched" || bad "b: sem pilot:dispatched"
has_label wa-p0 pilot:dispatching && bad "b: o claim pilot:dispatching ficou" || ok "b: o claim foi solto"
has_label wa-p0 lane:small && ok "b: lane:small gravada" || bad "b: sem lane:*"
[ "$(meta wa-p0 pilot.sling_bead)" = "ga-wrap1" ] && ok "b: pilot.sling_bead aponta a bead-gancho" || bad "b: pilot.sling_bead='$(meta wa-p0 pilot.sling_bead)'"
[ -z "$(meta wa-p0 gc.routed_to)" ] && ok "b: gc.routed_to=wa-worker saiu (o pool do rig não a pega junto com o dog)" || bad "b: gc.routed_to='$(meta wa-p0 gc.routed_to)' ficou"
[ "$(meta ga-wrap1 pilot.sling_for)" = "wa-p0" ] && ok "b: a bead-gancho tem o ponteiro reverso pilot.sling_for" || bad "b: sem pilot.sling_for na bead-gancho"
logged "dog-lend: LENT wa-p0" && ok "b: linha «dog-lend: LENT» (o grep das 24 h)" || bad "b: sem a linha dog-lend: LENT"
[ "$(cat "$WORK/pcap.after")" = "|" ] && ok "b: não mexeu na contagem do pool do rig (não gasta vaga do wa-worker)" || bad "b: tocou na contagem do pool: $(cat "$WORK/pcap.after")"

echo "(b2) veredito unknown também vai ao dog do mini; P1 é elegível"
reset; mk wa-p1 1; T_VERDICT=unknown
sweep
[ "$(slings)" = 1 ] && ok "b2: P1 + unknown → emprestada" || bad "b2: slings=$(slings)"

echo "(b3) PS P0, ps-worker 2/2 → emprestada; o classificador do nó NÃO é consultado (é coisa do WA)"
reset; mk ps-p0 0 "story:approved,exec:auto" '.metadata["gc.routed_to"]="ps-worker"'
sweep
[ "$(slings)" = 1 ] && ok "b3: PS P0 emprestada" || bad "b3: slings=$(slings)"
grep -qF "$WORK/ps" "$WORK/sling.1.in" 2>/dev/null && ok "b3: o texto traz a raiz do rig PS" || bad "b3: texto sem a raiz do PS"
[ ! -s "$WORK/verdict.calls" ] && ok "b3: sem consulta ao classificador de nó" || bad "b3: consultou o classificador para uma bead de PS"

echo "(b4) primeira vista: P0 de WA SEM gc.routed_to (o pool ainda nem a viu) — emprestada, nada a desfazer na rota"
reset; mk wa-new 0 "story:approved,exec:auto" 'del(.metadata["gc.routed_to"])'
sweep
[ "$(slings)" = 1 ] && ok "b4: emprestada sem rota prévia" || bad "b4: slings=$(slings)"

# ── (c) veredito node: NUNCA a um dog do mini, nem a outro alvo ─────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(c) veredito node — nenhum sling para nenhum alvo; a bead segue como estava (a passada do nó e a fila a levam)"
reset; mk wa-node 0; T_VERDICT=node
sweep
[ "$(slings)" = 0 ] && ok "c: 0 slings com veredito node" || bad "c: $(slings) sling(s) com veredito node"
grep -q 'dog-remote' "$WORK/gc.log" 2>/dev/null && bad "c: algo falou com dog-remote" || ok "c: nenhum alvo dog-remote tocado (sem visibilidade verificada das lojas de rig)"
[ "$(meta wa-node gc.routed_to)" = "wa-worker" ] && ok "c: a rota original ficou intacta" || bad "c: rota alterada para '$(meta wa-node gc.routed_to)'"
has_label wa-node story:in-flight && bad "c: a bead ficou in-flight" || ok "c: a bead não foi marcada"
logged "node-verdict" && ok "c: o motivo vai ao log (node-verdict-…)" || bad "c: sem motivo no log"
[ "$(bd_writes)" = 0 ] && ok "c: ZERO escritas de bd (leitura que recusa não escreve)" || bad "c: $(bd_writes) escritas de bd numa recusa"

echo "(c2) timeout / error / missing do classificador = recusa (nunca vira mini)"
for v in timeout error missing; do
  reset; mk wa-v 0; T_VERDICT=$v
  sweep
  [ "$(slings)" = 0 ] && ok "c2: veredito $v → não empresta" || bad "c2: veredito $v emprestou"
done

# ── (d) P2 com o pool cheio: não vai a dog ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(d) WA P2 com wa-worker 4/4 — NÃO é emprestada (só P0/P1)"
reset; mk wa-p2 2
sweep
[ "$(slings)" = 0 ] && ok "d: P2 não vai a dog" || bad "d: P2 foi emprestada"
reset; mk wa-p3 3
sweep
[ "$(slings)" = 0 ] && ok "d: P3 idem" || bad "d: P3 foi emprestada"
reset; mk wa-pstr 1 "story:approved,exec:auto" '.priority="P1"'
sweep
[ "$(slings)" = 1 ] && ok "d: prioridade escrita «P1» (texto) conta como P1" || bad "d: «P1» em texto não foi lida"
reset; mk wa-px 1 "story:approved,exec:auto" '.priority="lixo"'
sweep
[ "$(slings)" = 0 ] && ok "d: prioridade ilegível não é P0/P1 (não empresta no escuro)" || bad "d: prioridade ilegível emprestou"

# ── o pool do rig tem vaga → o caminho normal é dono ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(f) pool com vaga (3/4) — o caminho normal despacha; o dog não rouba"
reset; mk wa-room 0; T_WA_LIVE=3
sweep
[ "$(slings)" = 0 ] && ok "f: pool com vaga → 0 empréstimos" || bad "f: emprestou com o pool com vaga"
echo "(f2) contagem do pool ilegível — não empresta (só um «cheio» POSITIVO empresta)"
reset; mk wa-blind 0; T_WA_LIVE=unreadable
sweep
[ "$(slings)" = 0 ] && ok "f2: contagem ilegível → 0 empréstimos" || bad "f2: emprestou numa contagem ilegível"
logged "unreadable" && ok "f2: o cego aparece no log" || bad "f2: o cego não aparece no log"

# ── vaga de dog ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(g) sem dog livre (3/3) → não empresta"
reset; mk wa-nodog 0; T_DOG_LIVE=3
sweep
[ "$(slings)" = 0 ] && ok "g: dog 3/3 → 0 empréstimos" || bad "g: emprestou sem vaga de dog"
logged "no free dog" && ok "g: o motivo (no free dog) vai ao log" || bad "g: sem o motivo no log"
echo "(g2) contagem de dog ilegível → não empresta"
reset; mk wa-dogblind 0; T_DOG_LIVE=unreadable
sweep
[ "$(slings)" = 0 ] && ok "g2: contagem de dog ilegível → 0" || bad "g2: emprestou com a contagem de dog ilegível"
echo "(g3) teto por varredura: 2 elegíveis, MAX_PER_SWEEP=1 → só a primeira da ordem (P0 antes de P1)"
reset; mk wa-a 1 "story:approved,exec:auto" . 1; mk wa-b 0 "story:approved,exec:auto" . 2; T_MAX=1; T_DOG_LIVE=0
sweep
[ "$(slings)" = 1 ] && ok "g3: 1 sling" || bad "g3: slings=$(slings)"
has_label wa-b story:in-flight && ! has_label wa-a story:in-flight && ok "g3: a P0 (wa-b) foi antes da P1 mais velha (wa-a)" || bad "g3: ordem errada (wa-a=$(lbl wa-a) wa-b=$(lbl wa-b))"
echo "(g4) as vagas do dog contam o que a própria varredura já emprestou (dog 1/3 + 2 emprestadas = 3 → a terceira espera)"
reset; mk wa-1 0 "story:approved,exec:auto" . 1; mk wa-2 0 "story:approved,exec:auto" . 2; mk wa-3 0 "story:approved,exec:auto" . 3; T_MAX=5; T_DOG_LIVE=1
sweep
[ "$(slings)" = 2 ] && ok "g4: 2 empréstimos (1 vivo + 2 = 3 = teto)" || bad "g4: slings=$(slings) (esperado 2)"

# ── disco e memória do mini ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(h) disco baixo no mini — dog com bead de WA não é despachado"
reset; mk wa-disk 0; T_DISK=low
sweep
[ "$(slings)" = 0 ] && ok "h: disco low → 0 empréstimos" || bad "h: emprestou com o disco baixo"
logged "disk" && ok "h: motivo disk no log" || bad "h: sem motivo disk"
echo "(h2) disco ilegível (unknown) — numa passada OPCIONAL a dúvida não empresta"
reset; mk wa-disku 0; T_DISK=unknown
sweep
[ "$(slings)" = 0 ] && ok "h2: disco unknown → 0" || bad "h2: emprestou com o disco ilegível"
echo "(h3) disco ok / interruptor do disco desligado (off) → empresta"
reset; mk wa-diskok 0; T_DISK=ok
sweep
[ "$(slings)" = 1 ] && ok "h3: disco ok → empresta" || bad "h3: não emprestou com o disco ok"
reset; mk wa-diskoff 0; T_DISK=off
sweep
[ "$(slings)" = 1 ] && ok "h3: disco off (decisão do operador) → empresta" || bad "h3: não emprestou com o guard desligado pelo operador"
echo "(h4) memória apertada / sonda cega → não empresta"
reset; mk wa-mem 0; T_MEM=tight
sweep
[ "$(slings)" = 0 ] && ok "h4: memória tight → 0" || bad "h4: emprestou com a memória apertada"
reset; mk wa-memb 0; T_MEM=blind
sweep
[ "$(slings)" = 0 ] && ok "h4: sonda de memória cega → 0" || bad "h4: emprestou com a sonda de memória cega"

# ── vetos (rótulos, dono, rota) — um por linha ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(i) vetos: cada um recusa, sem sling e sem escrita"
for lab in "pilot:no-auto-dispatch" "no-auto-dispatch" "next-action:athos" "exec:manual" "gate:needs-fix" "gate:needs-human" "pilot:held" "story:in-flight" "pilot:dispatched" "pilot:dispatching" "lane:kimi"; do
  reset; mk wa-veto 0 "story:approved,exec:auto,$lab"
  sweep
  if [ "$(slings)" = 0 ] && [ "$(bd_writes)" = 0 ]; then ok "i: $lab → sem sling e sem escrita"; else bad "i: $lab não vetou (slings=$(slings) writes=$(bd_writes))"; fi
done
reset; mk wa-veto 0 "story:approved"
sweep; [ "$(slings)" = 0 ] && ok "i: sem exec:auto → não" || bad "i: sem exec:auto emprestou"
reset; mk wa-veto 0 "exec:auto"
sweep; [ "$(slings)" = 0 ] && ok "i: sem story:approved → não" || bad "i: sem story:approved emprestou"
reset; mk wa-veto 0 "story:approved,exec:auto" '.assignee="mila-wa"'
sweep; [ "$(slings)" = 0 ] && ok "i: atribuída a crew (mila-wa) → não" || bad "i: bead de crew emprestada"
reset; mk wa-veto 0 "story:approved,exec:auto" '.metadata["gc.routed_to"]="kimi-worker-remote"'
sweep; [ "$(slings)" = 0 ] && ok "i: rota para outro alvo (kimi) → não" || bad "i: rota alheia emprestada"
reset; mk wa-veto 0 "story:approved,exec:auto" '.status="in_progress"'
sweep; [ "$(slings)" = 0 ] && ok "i: status in_progress → não" || bad "i: in_progress emprestada"
reset; mk wa-veto 0; T_REFUSAL="label:delivery:pending-restart"
sweep; [ "$(slings)" = 0 ] && ok "i: o veto do pool (delivery:pending-restart) vale para o dog" || bad "i: ignorou o veto do pool"
reset; mk wa-veto 0; T_REFUSAL_FAIL=1
sweep; [ "$(slings)" = 0 ] && ok "i: lista de recusas ilegível → não (o terceiro estado não vira «sem recusa»)" || bad "i: emprestou com a lista de recusas ilegível"

echo "(j) lojas: bead do HQ e de traco-bim (repo sem gate) NÃO são do empréstimo; loja desconhecida também não"
reset; mk ga-hq 0
sweep; [ "$(slings)" = 0 ] && ok "j: P0 do HQ → não (é do vigia/da rota e do caminho normal do dog)" || bad "j: HQ emprestada"
reset; mk tb-x 0
sweep; [ "$(slings)" = 0 ] && ok "j: P0 do traco-bim → não" || bad "j: traco-bim emprestada"
reset; mk zz-x 0
sweep; [ "$(slings)" = 0 ] && ok "j: prefixo sem loja (store-unknown) → não" || bad "j: loja desconhecida emprestada"

# ── interruptores ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(k) interruptores: off, valor desconhecido, shadow, DRY_RUN, passada só-nó, varredura parada"
reset; mk wa-k 0; T_MODE=off
sweep; [ "$(slings)" = 0 ] && [ "$(bd_writes)" = 0 ] && ok "k: PILOT_DOG_LEND=off → nada" || bad "k: off não desligou"
reset; mk wa-k 0; T_MODE=talvez
sweep; [ "$(slings)" = 0 ] && ok "k: valor que não existe → desligado (a passada é opcional: dúvida não empresta)" || bad "k: valor ilegível ligou a passada"
reset; mk wa-k 0; T_MODE=shadow
sweep; [ "$(slings)" = 0 ] && [ "$(bd_writes)" = 0 ] && logged "SHADOW would lend wa-k" && ok "k: shadow → só diz o que faria (0 sling, 0 escrita)" || bad "k: shadow escreveu ou não disse (slings=$(slings) writes=$(bd_writes))"
reset; mk wa-k 0; T_DRY=1
sweep; [ "$(slings)" = 0 ] && [ "$(bd_writes)" = 0 ] && ok "k: DRY_RUN=1 → zero escrita" || bad "k: DRY_RUN escreveu"
reset; mk wa-k 0; T_NODE_ONLY=1
sweep; [ "$(slings)" = 0 ] && ok "k: passada só-nó (disco/memória do mini) → nada" || bad "k: emprestou na passada só-nó"
reset; mk wa-k 0; T_STOP=1
sweep; [ "$(slings)" = 0 ] && ok "k: varredura parada (contagem ilegível/orçamento) → nada" || bad "k: emprestou com a varredura parada"
reset; mk wa-k 0; T_DOG_MAX=1; T_DOG_LIVE=1
sweep; [ "$(slings)" = 0 ] && ok "k: PILOT_DOG_LEND_DOG_MAX=1 respeitado" || bad "k: ignorou PILOT_DOG_LEND_DOG_MAX"

# ── a leitura fresca antes da claim, e a falha que desfaz ─────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(l) o candidato velho: a leitura fresca mostra que já tem dono → não empresta"
reset; mk wa-stale 0
jq -c '.assignee="wa-worker-1" | .status="in_progress"' "$WORK/db/wa-stale.json" > "$WORK/db/t" && mv "$WORK/db/t" "$WORK/db/wa-stale.json"
sweep; [ "$(slings)" = 0 ] && ok "l: dono apareceu depois do varrimento → 0 sling" || bad "l: emprestou uma bead que já tinha dono"
echo "(l2) a releitura falha (bd show sai ≠ 0) → não empresta, nada escrito"
reset; mk wa-rf 0; : > "$WORK/bd.fail.show.wa-rf"
sweep; [ "$(slings)" = 0 ] && [ "$(bd_writes)" = 0 ] && ok "l2: bd show falhou → 0 sling, 0 escrita" || bad "l2: slings=$(slings) writes=$(bd_writes)"
echo "(l3) o varrimento dizia P1, a leitura fresca diz P2 (rebaixada no meio) → não empresta: o veto vale também na cópia fresca"
reset; mk wa-dg 1
jq -c '.priority=2' "$WORK/db/wa-dg.json" > "$WORK/db/t" && mv "$WORK/db/t" "$WORK/db/wa-dg.json"
sweep; [ "$(slings)" = 0 ] && [ "$(bd_writes)" = 0 ] && ok "l3: prioridade rebaixada → 0 sling, 0 escrita" || bad "l3: emprestou uma bead rebaixada (slings=$(slings) writes=$(bd_writes))"

echo "(l4) _pilot_dog_lend_veto direto: entrada vazia / que não é bead / não-P0P1 NUNCA dá «ok»"
veto_of() { ( PATH="$SANDBOX_PATH"; _pilot_priority_refusal_of() { printf ''; return 0; }; eval "$FUNCS"; _pilot_dog_lend_veto "$1" ); }
GOOD='{"id":"wa-u","priority":1,"status":"open","assignee":"","labels":["story:approved","exec:auto"],"metadata":{"gc.routed_to":"wa-worker"}}'
[ "$(veto_of "$GOOD")" = ok ] && ok "l4: a bead boa dá ok" || bad "l4: a bead boa não deu ok (deu: $(veto_of "$GOOD"))"
[ "$(veto_of '')" = unreadable ] && ok "l4: entrada vazia → unreadable (nunca ok)" || bad "l4: entrada vazia deu «$(veto_of '')»"
[ "$(veto_of 'isso não é json')" = unreadable ] && ok "l4: texto que não é JSON → unreadable" || bad "l4: lixo deu «$(veto_of 'isso não é json')»"
[ "$(veto_of '[]')" = unreadable ] && ok "l4: JSON que não é objeto → unreadable" || bad "l4: [] deu «$(veto_of '[]')»"
case "$(veto_of "$(printf '%s' "$GOOD" | jq -c '.priority=2')")" in priority:P2) ok "l4: P2 → priority:P2" ;; *) bad "l4: P2 deu «$(veto_of "$(printf '%s' "$GOOD" | jq -c '.priority=2')")»" ;; esac
case "$(veto_of "$(printf '%s' "$GOOD" | jq -c 'del(.priority)')")" in priority:*) ok "l4: sem prioridade → não é P0/P1" ;; *) bad "l4: sem prioridade deu «$(veto_of "$(printf '%s' "$GOOD" | jq -c 'del(.priority)')")»" ;; esac

echo "(m) o sling falha → desfaz: sem claim, rota original de volta, sem in-flight"
reset; mk wa-sf 0; : > "$WORK/sling.fail"
sweep
has_label wa-sf pilot:dispatching && bad "m: o claim ficou" || ok "m: claim solto"
has_label wa-sf story:in-flight && bad "m: ficou in-flight sem gancho" || ok "m: sem in-flight"
[ "$(meta wa-sf gc.routed_to)" = "wa-worker" ] && ok "m: a rota wa-worker voltou (o pool do rig volta a vê-la)" || bad "m: rota='$(meta wa-sf gc.routed_to)' (não foi restaurada)"
[ -z "$(meta wa-sf pilot.dispatching_at)" ] && ok "m: o carimbo de claim saiu" || bad "m: pilot.dispatching_at ficou"
logged "dog-lend: FAILED wa-sf" && ok "m: o fracasso vai ao log" || bad "m: sem linha FAILED"
echo "(m2) o sling devolve sem id mas a bead-gancho existe (orphan) → adota em vez de duplicar"
reset; mk wa-orph 0; : > "$WORK/sling.noid"
sweep
[ "$(slings)" = 1 ] && has_label wa-orph story:in-flight && ok "m2: adotou a bead-gancho já criada (1 sling, in-flight)" || bad "m2: slings=$(slings) labels=$(lbl wa-orph)"
echo "(m3) a escrita de story:in-flight some (rc 0 e a releitura desmente) → o claim FICA (o TTL é o dono) e o fracasso aparece"
reset; mk wa-lost 0; : > "$WORK/bd.lost.labeladd.story:in-flight"
sweep
has_label wa-lost pilot:dispatching && ok "m3: claim mantido para a recuperação por TTL" || bad "m3: o claim foi solto sem in-flight confirmado"
logged "inflight" && ok "m3: o aviso de in-flight não confirmado está no log" || bad "m3: silêncio sobre o in-flight"
echo "(m4) o nudge falha → a bead-gancho volta a ser visível (unsuppress), a bead do rig segue in-flight"
reset; mk wa-ng 0; : > "$WORK/nudge.fail"
sweep
has_label wa-ng story:in-flight && ok "m4: bead do rig in-flight mesmo com o nudge falho" || bad "m4: perdeu o in-flight por causa do nudge"

# ── fiação (o que só o texto do despachante prova) ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "(n) fiação no despachante"
has() { grep -qE -- "$1" "$DISPATCHER"; }
has '^_pilot_dog_lend_pass \|\| true' && ok "n: a passada é chamada (com ||true: nunca derruba a varredura)" || bad "n: chamada ausente"
L_HOOK=$(grep -n '^_pilot_dog_lend_pass || true' "$DISPATCHER" | head -1 | cut -d: -f1)
L_BIG=$(grep -n 'dispatch_lane "big" "\$BIG_CANDIDATES"' "$DISPATCHER" | tail -1 | cut -d: -f1)
{ [ -n "$L_HOOK" ] && [ -n "$L_BIG" ] && [ "$L_HOOK" -gt "$L_BIG" ]; } && ok "n: roda DEPOIS das pistas ($L_HOOK > $L_BIG): só empresta o que o caminho normal não despachou" || bad "n: ordem errada (hook=$L_HOOK big=$L_BIG)"
SRC_ONE="$(fn_src _pilot_dog_lend_one)"; SRC_PASS="$(fn_src _pilot_dog_lend_pass)"; SRC_MINI="$(fn_src _pilot_dog_lend_mini_ok)"; SRC_NODE="$(fn_src _pilot_dog_lend_node_gate)"
printf '%s' "$SRC_ONE" | grep -q 'sling gastown.dog' && ok "n: o único alvo de sling é gastown.dog" || bad "n: sling não vai a gastown.dog"
printf '%s' "$SRC_ONE$SRC_PASS$SRC_NODE" | grep -q 'sling dog-remote\|sling "dog-remote' && bad "n: há sling a dog-remote" || ok "n: nenhum sling a dog-remote"
printf '%s' "$SRC_MINI" | grep -q '_pilot_disk_floor' && printf '%s' "$SRC_MINI" | grep -q '_pilot_memory_tight' && ok "n: usa os MESMOS guards de disco e memória do resto do Pilot" || bad "n: guards próprios/ausentes"
printf '%s' "$SRC_NODE" | grep -q '_pilot_wa_node_pass_check' && ok "n: o veredito de nó vem do classificador que o Pilot já usa" || bad "n: veredito próprio"
printf '%s' "$SRC_PASS" | grep -q '_pilot_priority_refusal_of\|_pilot_dog_lend_veto' && ok "n: vetos aplicados" || bad "n: sem vetos"
printf '%s' "$SRC_ONE$SRC_PASS" | grep -qE 'PILOT_WA_WORKER_MAX' && bad "n: mexe em PILOT_WA_WORKER_MAX (não deve gastar vaga do pool)" || ok "n: não toca PILOT_WA_WORKER_MAX na decisão de empréstimo"
printf '%s' "$(fn_src _pilot_dog_lend_pool_full)" | grep -q 'PILOT_WA_WORKER_MAX' && ok "n: só LÊ o teto do pool, para saber se está cheio" || bad "n: não lê o teto do pool"
# a fiação do vigia (cenários 65-78: gc.routed_to=gastown.dog em P0/P1 aprovada do HQ) é provada pelo --selftest do próprio vigia — fatia 1/2 de ga-hfx1kou, outro commit; aqui só o despachante

echo
echo "dog-lend selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
