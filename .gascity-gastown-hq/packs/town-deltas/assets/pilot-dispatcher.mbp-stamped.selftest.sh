#!/usr/bin/env bash
# pilot-dispatcher.mbp-stamped.selftest.sh — testes do passo da bead CARIMBADA do Pilot para o MBP (ga-w7qwl1.2.6, corte 6 do ga-w7qwl1.2).
#
# O gancho do corte 2 (_pilot_mbp_node_decide) roda dentro de dispatch_one e o `apply` recusa (rc 12) a bead que já traz gc.routed_to=wa-worker, o carimbo que o próprio Pilot grava. Essa bead era pulada em dispatch_lane,
# ANTES da claim e sem escrever, justamente quando o pool do mini está cheio (a condição do MBP): o gancho nunca era chamado para ela. O passo novo (_pilot_mbp_stamped_pre → bandeira _PILOT_WA_MBP_PASS → adoção do
# carimbo em dispatch_one → gancho → _pilot_mbp_stamped_after) a deixa passar. Nasce DESLIGADO como o gancho (PILOT_WA_MBP_ROUTE=off|shadow|on).
#
# As funções e os trechos de dispatch_lane/dispatch_one são os REAIS (extraídos palavra por palavra do pilot-dispatcher.sh); bd, gc, mbp-node-dispatch.sh e o oráculo de capacidade são falsos, o bd com estado.
# Tudo roda em `set -euo pipefail`, o modo do despachante.
#   A. o oráculo do MBP (_pilot_mbp_stamped_gate): só rc 0 + verdict node + free >= 1; uma pergunta por varredura.
#   B. o `check` (_pilot_mbp_stamped_check): o terceiro estado nunca vira node.
#   C. a decisão (_pilot_mbp_stamped_pre): modos, carimbo EXATO, dono, vetos, Hetzner primeiro, orçamentos, mini cheio, memória, oráculo, `check`, shadow, Dolt — e NENHUMA escrita em bead.
#   D. a contabilidade (_pilot_mbp_stamped_after) e o rc do apply guardado pelo gancho.
#   E. a fiação: trechos reais de dispatch_lane (pulos pré-claim, bandeira) e de dispatch_one (yield, adoção, gancho, desfazer).
#   F. o caminho inteiro (lane → claim → adoção → apply → sessão) com o bd falso com estado, e a prova de que o carimbo é o que o `apply` real recusa.
#   H. o resumo por varredura (_pilot_mbp_stamped_summary): uma linha de log + um evento em mbp-node-route.jsonl com o que o passo fez e POR QUE parou — o terceiro estado (oráculo/check que falha) nunca é silêncio.
#   G. mutantes: cada quebra tem de derrubar este selftest. Cada um roda o arquivo inteiro e para no 1º FAIL.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.mbp-stamped.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK". Bash 3.2 (macOS) basta.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${MBP_STAMPED_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
# Rodando como mutante (MBP_STAMPED_SELFTEST_FILE) o primeiro FAIL já diz "morto": sai na hora.
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); [ -z "${MBP_STAMPED_SELFTEST_FILE:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — obtido '$2', esperado '$3'"; fi; }   # eq <descrição> <obtido> <esperado>
[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FNS=""
for _f in _pilot_mbp_stamped_pre _pilot_mbp_stamped_gate _pilot_mbp_stamped_check _pilot_mbp_stamped_after _pilot_mbp_stamped_skip _pilot_mbp_stamped_tally _pilot_mbp_stamped_summary _pilot_mbp_stamped_upd_now \
          _pilot_wa_node_pass_memo_hit _pilot_wa_node_pass_memo_put _pilot_wa_node_pass_state _pilot_wa_node_adopt _pilot_wa_node_unadopt _pilot_bead_home_store \
          _pilot_mbp_node_decide _pilot_mbp_mini_full _pilot_mbp_node_open _pilot_mbp_node_settle _pilot_pool_live_count _pilot_live_session_count _pilot_wa_node_read _pilot_node_remote_open _pilot_node_remote_rollback \
          _pilot_node_idle_secs _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing gc_json_or_unknown; do
  _b="$(fn_of "$_f")"
  [ -n "$_b" ] || { echo "FATAL: $_f() não está em $DISPATCHER" >&2; exit 2; }
  FNS="$FNS"$'\n'"$_b"
done
# as declarações REAIS dos globais do passo (um global sem declaração quebra em `set -u`, como no despachante)
INIT_G="$(grep -E '^(_PMS_[A-Z_]+|_PILOT_WA_MBP_PASS|_PMN_APPLY_RC|_PWP_LAST_STOP|_PWP_MODE|_PWP_MEMO_V|_PWP_ADOPTED)=' "$DISPATCHER")"
[ -n "$INIT_G" ] || { echo "FATAL: os globais do passo (_PMS_*) não estão declarados em $DISPATCHER" >&2; exit 2; }
# os trechos REAIS de dispatch_lane e dispatch_one
YREG="$(awk 'f==0 && $0=="  _PNY_EXEMPT_THIS=0" {f=1; next} f==1 {print} f==1 && /^  fi$/ {exit}' "$DISPATCHER")"
HREG="$(awk 'f==0 && $0 ~ /^        local _RP_NODE_RC=0$/ {f=1} f==1 {print} f==1 && $0 ~ /^        : # pool: leave UNASSIGNED/ {p=1} f==1 && p==1 && $0 ~ /^        fi$/ {exit}' "$DISPATCHER")"
LREG="$(awk 'f==0 && $0=="    local _mbp_pass=0" {f=1} f==1 && $0 ~ /^    # ── ga-6hr8p7/ {exit} f==1 {print}' "$DISPATCHER")"
DREG="$(awk 'f==0 && $0=="    _PCAP_CALL_QUEUED=0" {f=1} f==1 {print} f==1 && $0 == "      _pilot_sweep_note \"$pick_id\" 1 \"${DISPATCH_RESULT:-}\"" {exit}' "$DISPATCHER")"
for _r in YREG HREG LREG DREG; do eval "[ -n \"\$$_r\" ]" || { echo "FATAL: a região $_r não foi achada em $DISPATCHER" >&2; exit 2; }; done
DREG="$DREG"$'\n''    fi'
T="$(mktemp -d "${TMPDIR:-/tmp}/mbp-stamped.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/city/.gc" "$T/city/.beads" "$T/city/rigs/whatsapp_automation" "$T/bin"
export FAKE_STATE="$T/state.json" FAKE_LOG="$T/calls" FAKE_BD_LOG="$T/bdcalls" FAKE_GC_LOG="$T/gccalls" FAKE_ORDER="$T/order" FAKE_CAPLOG="$T/capcalls" FAKE_REG="$T/reg"
STORE="$(cd -P "$T/city/rigs/whatsapp_automation" && pwd -P)"
printf '{"prefix":"wa","path":"rigs/whatsapp_automation"}\n' > "$T/city/.beads/routes.jsonl"
MEMO="$T/city/.gc/wa-node-pass-memo.tsv"; export PILOT_WA_NODE_PASS_MEMO="$MEMO"
JSONL="$T/city/.gc/mbp-node-route.jsonl"
# mbp-node-dispatch.sh falso: anota os argumentos. `check` devolve FAKE_CHECK_OUT (padrão: node/label) com o rc FAKE_CHECK_RC. `apply` de verdade "escreve" (copia FAKE_BEAD2 para o estado) se FAKE_APPLY_WRITES=1, ou se vazio e o rc for 0.
cat > "$T/scripts/mbp-node-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
echo "script:${1:-}" >> "$FAKE_ORDER"
if [ "${1:-}" = check ]; then
  def='{"verdict":"node","basis":"label"}'
  printf '%s\n' "${FAKE_CHECK_OUT-$def}"
  exit "${FAKE_CHECK_RC:-0}"
fi
if [ "${1:-}" = apply ]; then
  dry=0; for a in "$@"; do [ "$a" = --dry-run ] && dry=1; done
  w="${FAKE_APPLY_WRITES:-}"; [ -n "$w" ] || { [ "${FAKE_RC:-0}" = 0 ] && w=1 || w=0; }
  if [ "$dry" = 0 ] && [ "$w" = 1 ]; then cp "$FAKE_BEAD2" "$FAKE_STATE"; fi
fi
echo "${FAKE_OUT:-fake}"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/scripts/mbp-node-dispatch.sh"
# o oráculo de capacidade falso (python, como o real): anota a chamada; FAKE_CAP_OUT / FAKE_CAP_RC mandam
cat > "$T/scripts/mbp-node-capacity.py" <<'EOF'
import os, sys
open(os.environ["FAKE_CAPLOG"], "a").write(" ".join(sys.argv[1:]) + "\n")
out = os.environ.get("FAKE_CAP_OUT")
if out is None:
    out = '{"verdict":"node","reason":"free_slot","effective":2,"active":0,"free":2}'
sys.stdout.write(out)
sys.exit(int(os.environ.get("FAKE_CAP_RC", "0")))
EOF
# bd falso COM ESTADO: `bd -C <loja> show <id> --json` e `bd -C <loja> update <id> [--if-assignee X] [--assignee Y] [--status S] [--unset-metadata K] [--set-metadata K=V] -q`. Knobs: FAKE_BD_UPDATE_MODE=noop (sai 0 e não muda nada); FAKE_BD_SHOW_RC=N (o show sai com N).
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
j=""; for x in "$@"; do j="$j|$x"; done
printf '%s\n' "$j" >> "$FAKE_BD_LOG"
[ "${1:-}" = -C ] || exit 64
verb="${3:-}"
echo "bd:$verb" >> "$FAKE_ORDER"
case "$verb" in
  show) [ -z "${FAKE_BD_SHOW_RC:-}" ] || exit "$FAKE_BD_SHOW_RC"; printf '['; cat "$FAKE_STATE"; printf ']\n'; exit 0 ;;
  update)
    [ "${FAKE_BD_UPDATE_MODE:-}" = noop ] && exit 0
    shift 4
    ifa="__none__"; asg="__keep__"; st=""; um=""; sm=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --if-assignee) ifa="$2"; shift 2 ;;
        --assignee) asg="$2"; shift 2 ;;
        --status) st="$2"; shift 2 ;;
        --unset-metadata) um="$2"; shift 2 ;;
        --set-metadata) sm="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cur=$(jq -r '.assignee // ""' "$FAKE_STATE" 2>/dev/null) || exit 1
    if [ "$ifa" != "__none__" ] && [ "$cur" != "$ifa" ]; then exit 1; fi
    f='.'
    [ "$asg" != "__keep__" ] && f="$f | (if \$a == \"\" then del(.assignee) else .assignee = \$a end)"
    [ -n "$st" ] && f="$f | .status = \$s"
    [ -n "$um" ] && f="$f | del(.metadata[\$m])"
    [ -n "$sm" ] && f="$f | .metadata[\$k] = \$v"
    jq --arg a "$asg" --arg s "$st" --arg m "$um" --arg k "${sm%%=*}" --arg v "${sm#*=}" "$f" "$FAKE_STATE" > "$FAKE_STATE.new" && mv "$FAKE_STATE.new" "$FAKE_STATE"
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
  close) exit 0 ;;
  nudge) exit 0 ;;
esac
exit 64
EOF
chmod +x "$T/bin/gc"
export PATH="$T/bin:$PATH"
PRELUDE='set -euo pipefail
warn(){ echo "WARN $*" >&2; }
log(){ echo "LOG $*" >&2; }
timeout(){ shift; "$@"; }'
# o que o passo pede emprestado ao resto do despachante, falso e dirigido por variáveis
STUBS='_pilot_node_first_veto() { printf "%s" "${FAKE_VETO:-}"; return 0; }
_pilot_priority_refusal_of() { [ "${FAKE_REFUSAL_RC:-0}" = 0 ] || return 1; printf "%s" "${FAKE_REFUSAL:-}"; }
_dolt_saturated() { [ "${FAKE_DOLT_SAT:-0}" = 1 ]; }'
INIT='_PILOT_SLOW_SPAWN_SEEN="${PRE_SLOW:-0}"'
# R <trecho> — roda o trecho num bash novo (set -euo pipefail) com as funções REAIS, os globais REAIS e os falsos no PATH; imprime a saída do trecho
R() {
  GC_CITY="$T/city" PILOT_WA_MBP_SCRIPTS="$T/scripts" \
    bash -c "$PRELUDE"$'\n'"$INIT_G"$'\n'"$INIT"$'\n'"$FNS"$'\n'"$STUBS"$'\n'"$1" _ 2>>"$T/err"
}
# sb <id> <dono> <rota> <rótulos separados por vírgula> [updated_at] [prioridade] — a candidata como `bd list --json` a entrega
sb() {
  jq -nc --arg id "$1" --arg a "$2" --arg r "$3" --arg l "$4" --arg u "${5-2026-10-25T10:00:00Z}" --argjson p "${6:-2}" \
    '{id:$id,status:"open",priority:$p,labels:($l|split(",")|map(select(length>0))),metadata:(if $r=="" then {} else {"gc.routed_to":$r} end)} + (if $a=="" then {} else {assignee:$a} end) + (if $u=="" then {} else {updated_at:$u} end)'
}
ID=wa-abc12
UPD=2026-10-25T10:00:00Z
CUR=2026-10-25T10:07:00Z   # o updated_at da bead DEPOIS da claim/adoção/soltura (medido: a claim move o updated_at; a chave lida antes nunca mais bate)
BASE="$(sb $ID "" wa-worker "story:approved")"
# mkb <arquivo> <status> <dono> <marca> <rota> — a bead no formato de `bd show` (o bd omite dono, marca e rota vazios)
mkb() {
  jq -n --arg id "$ID" --arg s "$2" --arg a "$3" --arg m "$4" --arg r "$5" --arg u "$CUR" \
    '{id:$id,status:$s,title:"Título X",updated_at:$u,metadata:((if $m=="" then {} else {"pilot.wa_node_alias":$m} end) + (if $r=="" then {} else {"gc.routed_to":$r} end))} + (if $a=="" then {} else {assignee:$a} end)' > "$1"
}
mkb "$T/b.stamped.json" open "" "" wa-worker
mkb "$T/b.free.json" open "" "" ""
mkb "$T/b.ap1.json" in_progress wa-worker-remote-mbp-1 wa-worker-remote-mbp-1 ""
mkb "$T/b.owned.json" in_progress mila-wa "" wa-worker
CITYGC="$T/city/.gc"
reset() {
  [ -d "$CITYGC/mbp-node-route.jsonl" ] && rmdir "$CITYGC/mbp-node-route.jsonl" 2>/dev/null
  : > "$T/calls"; : > "$T/bdcalls"; : > "$T/gccalls"; : > "$T/err"; : > "$T/order"; : > "$T/capcalls"; : > "$FAKE_REG"
  rm -f "$JSONL" "$MEMO"
  [ -f "$T/city/.beads/routes.jsonl" ] || printf '{"prefix":"wa","path":"rigs/whatsapp_automation"}\n' > "$T/city/.beads/routes.jsonl"
  [ -x "$T/scripts/mbp-node-dispatch.sh" ] || mv "$T/scripts/x.sh" "$T/scripts/mbp-node-dispatch.sh" 2>/dev/null
  cp "$T/b.stamped.json" "$T/state.json"
  unset FAKE_VETO FAKE_REFUSAL FAKE_REFUSAL_RC FAKE_DOLT_SAT FAKE_CAP_OUT FAKE_CAP_RC FAKE_CHECK_OUT FAKE_CHECK_RC FAKE_APPLY_WRITES FAKE_RC FAKE_OUT FAKE_SESSIONS FAKE_GC_LIST_RC FAKE_GC_NEW_RC FAKE_BD_UPDATE_MODE FAKE_BD_SHOW_RC \
        PRE_SLOW PRE DRY_RUN PILOT_DOLT_SATURATED_AT_START PILOT_WA_NODE_ROUTE PILOT_SPAWN_WA_WORKER PILOT_WA_MBP_STAMPED_PROBES PILOT_WA_MBP_STAMPED_MAX PILOT_WA_MBP_STAMPED_MAX_FAILS \
        PILOT_WA_NODE_PASS_MINI_TTL PILOT_WA_NODE_PASS_UNKNOWN_TTL PILOT_WA_NODE_PASS_RELEASED_TTL MBP_NODE_PY MBP_NODE_CAPACITY
  export PILOT_WA_MBP_ROUTE=on PILOT_TEST_WA_WORKER_LIVE_COUNT=4 PILOT_WA_WORKER_MAX=4 FAKE_BEAD2="$T/b.ap1.json"
}
ncalls() { wc -l < "$T/calls" | tr -d ' '; }
nbd()    { wc -l < "$T/bdcalls" | tr -d ' '; }
ngc()    { wc -l < "$T/gccalls" | tr -d ' '; }
ncap()   { wc -l < "$T/capcalls" | tr -d ' '; }
nupd()   { grep -c '|update|' "$T/bdcalls" | tr -d ' '; }
ord()    { tr '\n' ' ' < "$T/order"; }
st4()    { jq -r '[.status, (.assignee // "-"), (.metadata["pilot.wa_node_alias"] // "-"), (.metadata["gc.routed_to"] // "-")] | join(",")' "$T/state.json"; }
memo_put() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$MEMO"; }   # memo_put <chave> <updated_at> <veredito>
memo_last() { awk -F'\t' 'END { if (NR) print $2 "|" $3 "|" $4 }' "$MEMO" 2>/dev/null; }
# P <candidata> — roda _pilot_mbp_stamped_pre (com $PRE antes) e imprime "rc=N why=… stop=… probes=…"
P() { BEAD="$1" R "${PRE:-:}"$'\n''rc=0; _pilot_mbp_stamped_pre "$BEAD" || rc=$?; echo "rc=$rc why=$_PMS_WHY stop=$_PMS_STOP probes=$_PMS_PROBES"' | tail -1; }
echo "pilot-dispatcher.mbp-stamped.selftest — ga-w7qwl1.2.6"
echo; echo "=== A. o oráculo do MBP: uma pergunta por varredura, só 'node' com vaga abre ==="
gate() { R 'rc=0; _pilot_mbp_stamped_gate || rc=$?; echo "rc=$rc gate=$_PMS_GATE"' | tail -1; }
reset; r=$(gate); eq "node com 2 vagas: abre (0) e a resposta fica guardada" "$r $(ncap)" "rc=0 gate=ok 1"
eq "pergunta ao oráculo do MBP com 'python3 -I … --json verdict'" "$(cat "$T/capcalls")" "--json verdict"
for spec in '{"verdict":"node","free":1}|0' '{"verdict":"node","free":0}|1' '{"verdict":"node","free":-1}|1' '{"verdict":"node"}|1' '{"verdict":"node","free":"2"}|1' '{"verdict":"mini","free":2}|1' '{"verdict":"no","free":2}|1' '{"free":2}|1' 'não é json|1' '|1' '[]|1'; do
  reset; r=$(FAKE_CAP_OUT="${spec%|*}" gate | cut -d' ' -f1)
  eq "oráculo diz '${spec%|*}': rc=${spec##*|}" "$r" "rc=${spec##*|}"
done
for c in 1 2 124 137; do reset; r=$(FAKE_CAP_RC=$c gate | cut -d' ' -f1); eq "oráculo com a saída boa mas rc $c: não abre (o rc vale)" "$r" "rc=1"; done
reset; mv "$T/scripts/mbp-node-capacity.py" "$T/scripts/x.py"; r=$(gate); mv "$T/scripts/x.py" "$T/scripts/mbp-node-capacity.py"
eq "oráculo ausente: não abre" "$r" "rc=1 gate=no"; grep -q 'o oráculo .* não existe' "$T/err" && ok "...e o aviso diz que o oráculo não existe" || fail "aviso: $(cat "$T/err")"
reset; r=$(R '_pilot_mbp_stamped_gate; _pilot_mbp_stamped_gate; echo done' | tail -1); eq "duas perguntas na mesma varredura, uma ida ao oráculo (resposta ok guardada)" "$(ncap)" "1"
reset; r=$(FAKE_CAP_OUT='{"verdict":"mini","free":0}' R '_pilot_mbp_stamped_gate || true; _pilot_mbp_stamped_gate || true; echo done' | tail -1); eq "...e a resposta 'não' também fica guardada (uma ida só)" "$(ncap)" "1"
reset; r=$(MBP_NODE_CAPACITY="$T/scripts/mbp-node-capacity.py" MBP_NODE_PY=python3 gate); eq "MBP_NODE_CAPACITY e MBP_NODE_PY (os nomes de teste do despachante do MBP) valem" "$r" "rc=0 gate=ok"
# ── o terceiro estado do oráculo AVISA (fail-closed mas nunca silencioso); a recusa limpa não
gate2() { R 'rc=0; _pilot_mbp_stamped_gate || rc=$?; echo "rc=$rc gate=$_PMS_GATE why=${_PMS_GATE_WHY:-}"' | tail -1; }
nwarn() { grep -c '^WARN' "$T/err" | tr -d ' '; }
reset; r=$(gate2); eq "oráculo ok: abre, sem motivo de recusa e sem aviso" "$r $(nwarn)" "rc=0 gate=ok why= 0"
reset; r=$(FAKE_CAP_RC=1 FAKE_CAP_OUT='{"verdict":"local","reason":"sem_vaga"}' gate2); eq "recusa LIMPA (rc 1, verdict local: Athos em casa ou sem vaga) é o 'não' normal: fecha SEM aviso" "$r $(nwarn)" "rc=1 gate=no why=local 0"
reset; r=$(FAKE_CAP_RC=2 FAKE_CAP_OUT='{"verdict":"unknown","reason":"config"}' gate2); eq "oráculo que NÃO SOUBE dizer (rc 2, verdict unknown): fecha e AVISA" "$r $(nwarn)" "rc=1 gate=no why=unknown 1"
grep -q 'não soube' "$T/err" && ok "...e o aviso diz que o oráculo não soube" || fail "aviso do rc 2: $(cat "$T/err")"
for c in 124 137 143; do reset; r=$(FAKE_CAP_RC=$c FAKE_CAP_OUT='' gate2); eq "oráculo morto por prazo/sinal (rc $c): fecha e AVISA" "$r $(nwarn)" "rc=1 gate=no why=timeout 1"; done
grep -q 'prazo' "$T/err" && ok "...e o aviso do prazo diz 'prazo'" || fail "aviso do prazo: $(cat "$T/err")"
for spec in '0|não é json' '0|' '0|[]' '0|{"verdict":"mini","free":2}' '0|{"verdict":"node","free":0}' '0|{"verdict":"node"}' '0|{"verdict":"local"}' '1|' '1|lixo' '2|lixo' '2|{"verdict":"local"}' '1|{"verdict":"unknown"}' '1|{"verdict":"node","free":2}'; do
  reset; r=$(FAKE_CAP_RC="${spec%%|*}" FAKE_CAP_OUT="${spec#*|}" gate2); eq "rc ${spec%%|*} com a saída '${spec#*|}' (não é um veredito coerente com o rc): fecha e AVISA como ilegível" "$r $(nwarn)" "rc=1 gate=no why=unreadable 1"
done
grep -q 'ilegível' "$T/err" && ok "...e o aviso diz 'ilegível'" || fail "aviso do ilegível: $(cat "$T/err")"
for spec in '3|' '5|{"verdict":"node","free":2}' '126|' '127|'; do
  reset; r=$(FAKE_CAP_RC="${spec%%|*}" FAKE_CAP_OUT="${spec#*|}" gate2); eq "rc ${spec%%|*} do oráculo (o python nem rodou direito): fecha e AVISA como erro" "$r $(nwarn)" "rc=1 gate=no why=error 1"
done
reset; mv "$T/scripts/mbp-node-capacity.py" "$T/scripts/x.py"; r=$(gate2); mv "$T/scripts/x.py" "$T/scripts/mbp-node-capacity.py"; eq "oráculo ausente: fecha, motivo missing, e o aviso de sempre" "$r $(nwarn)" "rc=1 gate=no why=missing 1"
reset; r=$(FAKE_CAP_RC=2 FAKE_CAP_OUT='{"verdict":"unknown","reason":"config"}' R '_pilot_mbp_stamped_gate || true; _pilot_mbp_stamped_gate || true; _pilot_mbp_stamped_gate || true; echo done' | tail -1); eq "o 'não' guardado não repete o aviso: uma ida ao oráculo, UM aviso por varredura" "$(ncap) $(nwarn)" "1 1"
echo; echo "=== B. o check: o terceiro estado nunca vira node ==="
chk() { R '_pilot_mbp_stamped_check wa-abc12 '"$STORE"'; echo "v=$_PMS_V basis=$_PMS_BASIS"' | tail -1; }
reset; r=$(chk); eq "node/label" "$r" "v=node basis=label"
eq "o check recebe o id e a loja" "$(cat "$T/calls")" "check $ID --store $STORE"
reset; r=$(FAKE_CHECK_OUT='{"verdict":"node","basis":"text"}' chk); eq "node/text: a base vem do veredito" "$r" "v=node basis=text"
reset; r=$(FAKE_CHECK_OUT='{"verdict":"node"}' chk); eq "node sem base: node, base vazia" "$r" "v=node basis="
for spec in '{"verdict":"mini"}' '{"verdict":"unknown"}' 'lixo' ''; do reset; r=$(FAKE_CHECK_OUT="$spec" chk); eq "rc 0 mas a saída é '$spec': error (só 'node' com rc 0 vale)" "$r" "v=error basis="; done
for spec in '10|mini' '11|unknown' '124|timeout' '137|timeout' '143|timeout' '1|error' '2|error' '3|error' '125|error' '127|error' '12|error' '13|error'; do
  reset; r=$(FAKE_CHECK_RC="${spec%|*}" chk); eq "rc ${spec%|*} do check: ${spec#*|} (o rc decide, mesmo com a saída de node)" "$r" "v=${spec#*|} basis="
done
reset; mv "$T/scripts/mbp-node-dispatch.sh" "$T/scripts/x.sh"; r=$(chk); mv "$T/scripts/x.sh" "$T/scripts/mbp-node-dispatch.sh"; eq "mbp-node-dispatch.sh ausente: missing" "$r" "v=missing basis="
# ── o check que falha AVISA (timeout/erro/ausente); o veredito limpo (node/mini/unknown) não
reset; r=$(FAKE_CHECK_RC=10 chk); eq "check mini (rc 10): veredito limpo, sem aviso" "$r $(nwarn)" "v=mini basis= 0"
reset; r=$(FAKE_CHECK_RC=11 chk); eq "check unknown (rc 11): veredito limpo, sem aviso" "$r $(nwarn)" "v=unknown basis= 0"
reset; r=$(chk); eq "check node: sem aviso" "$r $(nwarn)" "v=node basis=label 0"
reset; r=$(FAKE_CHECK_RC=124 chk); eq "check que estourou o prazo: timeout e UM aviso" "$r $(nwarn)" "v=timeout basis= 1"
grep -q 'prazo' "$T/err" && ok "...que diz 'prazo' e o id da bead" || fail "aviso do timeout: $(cat "$T/err")"
reset; r=$(FAKE_CHECK_RC=3 chk); eq "check com rc 3: error e UM aviso" "$r $(nwarn)" "v=error basis= 1"
grep -q 'rc=3' "$T/err" && ok "...que traz o rc" || fail "aviso do error: $(cat "$T/err")"
reset; r=$(FAKE_CHECK_OUT='lixo' chk); eq "check rc 0 com saída que não é veredito: error e UM aviso" "$r $(nwarn)" "v=error basis= 1"
reset; mv "$T/scripts/mbp-node-dispatch.sh" "$T/scripts/x.sh"; r=$(chk); mv "$T/scripts/x.sh" "$T/scripts/mbp-node-dispatch.sh"; eq "mbp-node-dispatch.sh ausente: missing e UM aviso (o passo para por isso)" "$r $(nwarn)" "v=missing basis= 1"
grep -q 'mbp-node-dispatch.sh' "$T/err" && ok "...que nomeia o script" || fail "aviso do missing: $(cat "$T/err")"
echo; echo "=== C. a decisão: _pilot_mbp_stamped_pre ==="
reset; r=$(P "$BASE")
eq "carimbada livre, mini cheio, oráculo node, check node: oferece (0), uma sonda" "$r" "rc=0 why= stop= probes=1"
eq "...com UM check (id e loja) e UMA ida ao oráculo; nenhum apply" "$(cat "$T/calls")|$(ncap)" "check $ID --store $STORE|1"
eq "...e NENHUMA escrita: o bd não foi chamado, nenhuma linha de memória nem do jsonl" "$(nbd) $(ngc) $([ -e "$MEMO" ] && echo memo || echo -) $([ -e "$JSONL" ] && echo jsonl || echo -)" "0 0 - -"
# modos
for m in "" off OFF "on " yes 1 shadowx label auto; do
  reset; r=$(PILOT_WA_MBP_ROUTE="$m" P "$BASE"); eq "modo '$m' não é shadow|on: não oferece (off), nada chamado" "$r $(ncalls) $(ncap) $(nbd)" "rc=1 why=off stop= probes=0 0 0 0"
done
# shadow e dry-run: só registram
reset; r=$(PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "shadow: devolve 1 (nunca oferece), a sonda foi feita" "$r" "rc=1 why=shadow stop= probes=1"
eq "shadow: nenhuma escrita em bead, uma linha em mbp-node-route.jsonl" "$(nbd) $(wc -l < "$JSONL" | tr -d ' ')" "0 1"
jq -e --arg b "$ID" 'select(.event=="pilot-node-route" and .mode=="shadow" and .bead==$b and .stamped==true and .verdict=="node" and .basis=="label" and .prio=="2")' "$JSONL" >/dev/null && ok "...a linha traz bead, modo shadow, stamped:true, veredito node, base label e a prioridade" || fail "jsonl: $(cat "$JSONL")"
reset; r=$(PILOT_WA_MBP_ROUTE=shadow DRY_RUN=1 P "$BASE"); eq "shadow com DRY_RUN=1: a linha grava, mas o dry-run NÃO lembra a bead (nenhuma memória)" "$r $(wc -l < "$JSONL" | tr -d ' ') $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=shadow stop= probes=1 1 -"
reset; r=$(DRY_RUN=1 P "$BASE"); eq "on com DRY_RUN=1: devolve 1, sem escrita em bead" "$r $(nbd)" "rc=1 why=shadow stop= probes=1 0"
jq -e 'select(.mode=="on-dry-run" and .stamped==true)' "$JSONL" >/dev/null && ok "...e a linha diz on-dry-run" || fail "jsonl: $(cat "$JSONL")"
reset; mkdir -p "$CITYGC/mbp-node-route.jsonl"; r=$(PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "jsonl impossível de gravar (é uma pasta): o shadow segue devolvendo 1" "$r" "rc=1 why=shadow stop= probes=1"
grep -q 'linha-sombra de wa-abc12 (shadow, carimbada) NÃO gravada' "$T/err" && ok "...e AVISA a linha que se perdeu" || fail "sem aviso: $(cat "$T/err")"
eq "...e NÃO lembra a bead (linha que não gravou = amostra perdida: volta na próxima varredura)" "$([ -e "$MEMO" ] && echo memo || echo -)" "-"
rmdir "$CITYGC/mbp-node-route.jsonl"
reset; r=$(PRE='_PMS_STOP=gate' P "$BASE"); eq "parada da varredura (_PMS_STOP) é pegajosa: não oferece, nada chamado" "$r $(ncalls) $(ncap)" "rc=1 why=stop:gate stop=gate probes=0 0 0"
# a candidata
for spec in 'sem rota||' 'rota do Hetzner|wa-worker-remote|' 'rota do MBP|wa-worker-remote-mbp|' 'rota de PS|ps-worker|' 'rota wa-worker-2|wa-worker-2|' 'rota com espaço|wa-worker |'; do
  IFS='|' read -r nm rt _x <<EOF_S
$spec
EOF_S
  reset; r=$(P "$(sb $ID "" "$rt" "story:approved")"); eq "$nm: não é a carimbada (EXATAMENTE wa-worker), não oferece, sem check" "$r $(ncalls)" "rc=1 why=not-stamped stop= probes=0 0"
done
for ow in mila-wa wa-worker-remote-1 wa-worker-remote-mbp-1 wa-worker-3; do reset; r=$(P "$(sb $ID "$ow" wa-worker "story:approved")"); eq "bead com dono ($ow): não oferece, sem check" "$r $(ncalls)" "rc=1 why=has-owner stop= probes=0 0"; done
for i in ps-abc12 ga-abc12 ""; do reset; r=$(P "$(sb "$i" "" wa-worker "story:approved")"); eq "id '$i' não é wa-*: não oferece" "$r $(ncalls)" "rc=1 why=not-wa stop= probes=0 0"; done
for i in 'wa-a b' 'wa-a/b' 'wa-a;b'; do reset; r=$(P "$(sb "$i" "" wa-worker "story:approved")"); eq "id '$i' fora de [A-Za-z0-9._-]: ilegível, não oferece" "$r $(ncalls)" "rc=1 why=unreadable stop= probes=0 0"; done
for b in 'lixo' '[]' '"x"'; do reset; r=$(P "$b"); eq "candidata ilegível ('$b'): não oferece, nunca 'livre'" "$r $(ncalls)" "rc=1 why=unreadable stop= probes=0 0"; done
reset; r=$(P 'null'); eq "candidata null: não é bead de WA" "$r" "rc=1 why=not-wa stop= probes=0"
reset; r=$(FAKE_VETO=node:never P "$BASE"); eq "rótulo de veto do nó-primeiro: não oferece, sem check" "$r $(ncalls)" "rc=1 why=veto:node:never stop= probes=0 0"
reset; r=$(P "$(sb $ID "" wa-worker "story:approved,node:mini")"); eq "rótulo node:mini: não oferece, sem check" "$r $(ncalls)" "rc=1 why=node:mini stop= probes=0 0"
reset; r=$(P "$(sb $ID "" wa-worker "story:approved,node:ok")"); eq "rótulo node:ok sem a passada do Hetzner ligada: oferece (a regra não se aplica)" "$r" "rc=0 why= stop= probes=1"
# Hetzner primeiro
OKB="$(sb $ID "" wa-worker "story:approved,node:ok")"
for spec in '|hetzner-first' 'end|hetzner-first' 'max-fails|hetzner-first' 'budget-probes|hetzner-first' 'capacity|ok' 'keep-limit|ok'; do
  reset; r=$(PILOT_WA_NODE_ROUTE=label PRE="_PWP_MODE=on; _PWP_LAST_STOP='${spec%|*}'" P "$OKB" | cut -d' ' -f1,2)
  case "${spec#*|}" in ok) eq "Hetzner ligado (rota label), bead node:ok, a passada parou em '${spec%|*}': o nó está cheio, o MBP pode" "$r" "rc=0 why=" ;; *) eq "Hetzner ligado (rota label), bead node:ok, a passada parou em '${spec%|*}': fica para o Hetzner" "$r" "rc=1 why=hetzner-first" ;; esac
done
reset; r=$(PILOT_WA_NODE_ROUTE=label PRE='_PWP_MODE=on; _PWP_LAST_STOP=""' P "$BASE" | cut -d' ' -f1,2); eq "Hetzner ligado (rota label), bead SEM node:ok: não é dele, o MBP pode" "$r" "rc=0 why="
reset; r=$(PILOT_WA_NODE_ROUTE=auto PRE='_PWP_MODE=on; _PWP_LAST_STOP=""' P "$BASE" | cut -d' ' -f1,2); eq "Hetzner ligado (rota auto): qualquer WA é dele primeiro" "$r" "rc=1 why=hetzner-first"
reset; r=$(PILOT_WA_NODE_ROUTE=auto PRE='_PWP_MODE=on; _PWP_LAST_STOP=capacity' P "$BASE" | cut -d' ' -f1,2); eq "...rota auto e o nó cheio (capacity): o MBP pode" "$r" "rc=0 why="
for rt in "" off shadow xx; do reset; r=$(PILOT_WA_NODE_ROUTE="$rt" PRE='_PWP_MODE=on; _PWP_LAST_STOP=""' P "$OKB" | cut -d' ' -f1,2); eq "passada ligada mas rota '$rt' (a passada não leva bead): a regra não se aplica" "$r" "rc=0 why="; done
for pm in off shadow; do reset; r=$(PILOT_WA_NODE_ROUTE=auto PRE="_PWP_MODE=$pm; _PWP_LAST_STOP=''" P "$OKB" | cut -d' ' -f1,2); eq "passada do Hetzner em '$pm': não leva bead, o MBP pode" "$r" "rc=0 why="; done
# orçamentos
reset; r=$(PRE='_PMS_TAKEN=2' P "$BASE"); eq "levou os 2 do teto (padrão 2): para a varredura" "$r $(ncalls)" "rc=1 why=taken-limit stop=taken-limit probes=0 0"
reset; r=$(PRE='_PMS_TAKEN=1' P "$BASE" | cut -d' ' -f1); eq "levou 1 de 2: ainda oferece" "$r" "rc=0"
reset; r=$(PILOT_WA_MBP_STAMPED_MAX=3 PRE='_PMS_TAKEN=2' P "$BASE" | cut -d' ' -f1); eq "PILOT_WA_MBP_STAMPED_MAX=3, levou 2: oferece" "$r" "rc=0"
reset; r=$(PILOT_WA_MBP_STAMPED_MAX=0 P "$BASE"); eq "PILOT_WA_MBP_STAMPED_MAX=0 desliga só este passo (nada chamado)" "$r $(ncalls) $(ncap)" "rc=1 why=taken-limit stop=taken-limit probes=0 0 0"
reset; r=$(PILOT_WA_MBP_STAMPED_MAX=1 PRE='_PMS_TAKEN=1' P "$BASE" | cut -d' ' -f1,2); eq "PILOT_WA_MBP_STAMPED_MAX=1, levou 1: para" "$r" "rc=1 why=taken-limit"
for mx in abc "" -1; do reset; r=$(PILOT_WA_MBP_STAMPED_MAX="$mx" PRE='_PMS_TAKEN=2' P "$BASE" | cut -d' ' -f1,2); eq "teto '$mx' não é número: vale o padrão 2 (levou 2: para)" "$r" "rc=1 why=taken-limit"; done
reset; r=$(PRE_SLOW=1 P "$BASE"); eq "a sessão lenta do sweep já gastou o orçamento de spawn: nem claim nem sonda" "$r $(ncalls) $(ncap)" "rc=1 why=slow-spawn stop=slow-spawn probes=0 0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT=3 P "$BASE"); eq "mini com vaga (3 de 4): não oferece, nada chamado (nem o oráculo)" "$r $(ncalls) $(ncap)" "rc=1 why=mini-not-full stop= probes=0 0 0"
reset; r=$(PILOT_SPAWN_WA_WORKER=0 P "$BASE"); eq "PILOT_SPAWN_WA_WORKER=0 (o pool nem abre sessão): não há 'cheio', não oferece" "$r $(ncalls)" "rc=1 why=mini-not-full stop= probes=0 0"
reset; r=$(PILOT_WA_WORKER_MAX=abc P "$BASE"); eq "teto do mini ilegível: não sei que está cheio, não oferece" "$r $(ncalls)" "rc=1 why=mini-not-full stop= probes=0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT= FAKE_GC_LIST_RC=1 P "$BASE"); eq "contagem de sessões que não leu: não oferece" "$r $(ncalls)" "rc=1 why=mini-not-full stop= probes=0 0"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT=9 P "$BASE" | cut -d' ' -f1); eq "9 de 4: cheio, oferece" "$r" "rc=0"
reset; mv "$T/city/.beads/routes.jsonl" "$T/city/.beads/x.jsonl"; r=$(P "$BASE"); mv "$T/city/.beads/x.jsonl" "$T/city/.beads/routes.jsonl"; eq "sem routes.jsonl a loja é desconhecida: não oferece, sem check" "$r $(ncalls)" "rc=1 why=store-unknown stop= probes=0 0"
reset; r=$(P "$(sb wa-abc12 "" wa-worker "story:approved")" | cut -d' ' -f1); eq "(controle) a loja é a da pasta do prefixo wa" "$r" "rc=0"
eq "...e o check recebeu a loja resolvida do routes.jsonl" "$(cat "$T/calls")" "check $ID --store $STORE"
# memória
for v in mini unknown released; do reset; memo_put "mbp:$ID" "$UPD" $v; r=$(P "$BASE"); eq "memória '$v' (chave mbp:, mesmo updated_at): não oferece, sem check" "$r $(ncalls)" "rc=1 why=memo:$v stop= probes=0 0"; done
reset; memo_put "mbp:$ID" "2026-10-24T00:00:00Z" mini; r=$(P "$BASE" | cut -d' ' -f1); eq "memória de OUTRO updated_at (a bead mudou): sonda de novo" "$r" "rc=0"
reset; memo_put "$ID" "$UPD" mini; r=$(P "$BASE" | cut -d' ' -f1); eq "a memória do HETZNER (chave sem mbp:) não vale para o MBP: sonda" "$r" "rc=0"
reset; memo_put "mbp:$ID" "$UPD" mini; r=$(PILOT_WA_NODE_PASS_MINI_TTL=0 P "$BASE" | cut -d' ' -f1); eq "memória vencida (TTL 0): sonda de novo" "$r" "rc=0"
reset; r=$(P "$(sb $ID "" wa-worker "story:approved" "")" | cut -d' ' -f1,2); eq "sem updated_at não há chave de memória: sonda (e o check manda)" "$r" "rc=0 why="
reset; r=$(FAKE_CHECK_RC=10 P "$(sb $ID "" wa-worker "story:approved" "")"); eq "...sem updated_at e o check 'mini': não oferece e NÃO grava memória" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=check-mini stop= probes=1 -"
# recusa do pool
reset; r=$(FAKE_REFUSAL='pilot:no-auto-dispatch' P "$BASE"); eq "a lista de recusas do pool recusa a bead: não oferece, sem oráculo" "$r $(ncap)" "rc=1 why=refused:pilot:no-auto-dispatch stop= probes=0 0"
reset; r=$(FAKE_REFUSAL_RC=1 P "$BASE"); eq "não sei dizer se o pool a recusa: não oferece (o pulo de sempre decide)" "$r $(ncap)" "rc=1 why=refusal-unknown stop= probes=0 0"
# oráculo
reset; r=$(FAKE_CAP_OUT='{"verdict":"mini","free":0}' P "$BASE"); eq "oráculo diz que o MBP não recebe: não oferece, para a varredura, sem check" "$r $(ncalls) $(ncap)" "rc=1 why=gate stop=gate probes=0 0 1"
reset; r=$(FAKE_CAP_OUT='{"verdict":"mini","free":0}' B1="$BASE" B2="$(sb wa-def34 "" wa-worker "story:approved")" R '_pilot_mbp_stamped_pre "$B1" || true; _pilot_mbp_stamped_pre "$B2" || true; echo "why=$_PMS_WHY stop=$_PMS_STOP"' | tail -1)
eq "2ª bead depois do oráculo fechado: 'stop:gate', e o oráculo foi perguntado UMA vez" "$r $(ncap)" "why=stop:gate stop=gate 1"
reset; r=$(B1="$BASE" B2="$(sb wa-def34 "" wa-worker "story:approved")" R 'a=0; b=0; _pilot_mbp_stamped_pre "$B1" || a=$?; _pilot_mbp_stamped_pre "$B2" || b=$?; echo "a=$a b=$b probes=$_PMS_PROBES"' | tail -1)
eq "duas candidatas com o oráculo aberto: as duas oferecidas, 2 sondas, UMA ida ao oráculo" "$r $(ncap) $(ncalls)" "a=0 b=0 probes=2 1 2"
# sondas
BEADS3="$BASE"
reset; r=$(FAKE_CHECK_RC=10 PILOT_WA_MBP_STAMPED_PROBES=2 B1="$BASE" B2="$(sb wa-def34 "" wa-worker "story:approved")" B3="$(sb wa-ghi56 "" wa-worker "story:approved")" R 'for b in "$B1" "$B2" "$B3"; do _pilot_mbp_stamped_pre "$b" || true; done; echo "why=$_PMS_WHY stop=$_PMS_STOP probes=$_PMS_PROBES"' | tail -1)
eq "orçamento de 2 sondas: a 3ª candidata para a varredura sem sondar" "$r $(ncalls)" "why=budget-probes stop=budget-probes probes=2 2"
reset; r=$(PILOT_WA_MBP_STAMPED_PROBES=0 P "$BASE"); eq "orçamento 0: nenhuma sonda, para" "$r $(ncalls)" "rc=1 why=budget-probes stop=budget-probes probes=0 0"
reset; r=$(PILOT_WA_MBP_STAMPED_PROBES=abc P "$BASE" | cut -d' ' -f1); eq "orçamento ilegível vale o padrão 12" "$r" "rc=0"
# resultado do check
reset; r=$(FAKE_CHECK_RC=10 P "$BASE"); eq "check 'mini': não oferece, uma sonda gasta" "$r" "rc=1 why=check-mini stop= probes=1"
eq "...e memoriza com a chave mbp:, o updated_at e o veredito" "$(memo_last)" "mbp:$ID|$UPD|mini"
reset; r=$(FAKE_CHECK_RC=11 P "$BASE"); eq "check 'unknown': não oferece" "$r" "rc=1 why=check-unknown stop= probes=1"; eq "...e memoriza unknown" "$(memo_last)" "mbp:$ID|$UPD|unknown"
reset; r=$(FAKE_CHECK_RC=124 P "$BASE"); eq "check que passou do prazo: não oferece, NÃO memoriza, não para" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=check-timeout stop= probes=1 -"
reset; r=$(FAKE_CHECK_RC=1 P "$BASE"); eq "check com erro: não oferece, NÃO memoriza" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=check-error stop= probes=1 -"
reset; mv "$T/scripts/mbp-node-dispatch.sh" "$T/scripts/x.sh"; r=$(P "$BASE"); mv "$T/scripts/x.sh" "$T/scripts/mbp-node-dispatch.sh"; eq "despachante do MBP ausente: para a varredura" "$r" "rc=1 why=check-missing stop=check-missing probes=1"
reset; P "$BASE" >/dev/null; P "$BASE" >/dev/null; eq "nenhuma chamada de pré gravou memória para a bead que o check liberou (node)" "$([ -e "$MEMO" ] && echo memo || echo -)" "-"
# Dolt
reset; r=$(FAKE_DOLT_SAT=1 P "$BASE"); eq "Dolt saturado agora: não oferece (claim+adoção+apply+soltura são escritas), para" "$r" "rc=1 why=dolt-saturated stop=dolt-saturated probes=1"
reset; r=$(PILOT_DOLT_SATURATED_AT_START=1 P "$BASE"); eq "Dolt saturado no início da varredura: o mesmo" "$r" "rc=1 why=dolt-saturated stop=dolt-saturated probes=1"
reset; r=$(FAKE_DOLT_SAT=1 PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "o shadow não escreve em bead e por isso segue medindo com o Dolt saturado" "$r" "rc=1 why=shadow stop= probes=1"
eq "NENHUMA das decisões acima escreveu em bead (o bd falso nunca foi chamado)" "$(nbd)" "0"
# ── o que o resumo precisa saber (contadores) e as duas correções de escrita (DRY_RUN sem memória; shadow amostra cada bead UMA vez)
PC() { BEAD="$1" R "${PRE:-:}"$'\n''rc=0; _pilot_mbp_stamped_pre "$BEAD" || rc=$?; echo "rc=$rc seen=${_PMS_SEEN:-} offered=${_PMS_OFFERED:-} checked=[${_PMS_CHECKED:-}] gate_why=${_PMS_GATE_WHY:-}"' | tail -1; }
reset; r=$(PC "$BASE"); eq "oferecida: vista 1, oferecida 1, um check node" "$r" "rc=0 seen=1 offered=1 checked=[ node] gate_why="
reset; r=$(PILOT_WA_MBP_ROUTE=off PC "$BASE"); eq "modo off: nem vista (o contador só anda com o passo ligado)" "$r" "rc=1 seen=0 offered=0 checked=[] gate_why="
reset; r=$(PC "$(sb $ID mila-wa wa-worker "story:approved")"); eq "bead com dono: vista, não oferecida, nenhum check" "$r" "rc=1 seen=1 offered=0 checked=[] gate_why="
reset; r=$(FAKE_CHECK_RC=10 PC "$BASE"); eq "check mini: vista, não oferecida, o veredito entra na lista" "$r" "rc=1 seen=1 offered=0 checked=[ mini] gate_why="
reset; r=$(FAKE_CHECK_RC=124 PC "$BASE"); eq "check timeout: o veredito entra na lista" "$r" "rc=1 seen=1 offered=0 checked=[ timeout] gate_why="
reset; r=$(FAKE_CHECK_RC=3 PC "$BASE"); eq "check error: o veredito entra na lista" "$r" "rc=1 seen=1 offered=0 checked=[ error] gate_why="
reset; mv "$T/scripts/mbp-node-dispatch.sh" "$T/scripts/x.sh"; r=$(PC "$BASE"); mv "$T/scripts/x.sh" "$T/scripts/mbp-node-dispatch.sh"; eq "check ausente: o veredito entra na lista" "$r" "rc=1 seen=1 offered=0 checked=[ missing] gate_why="
reset; r=$(FAKE_CAP_RC=1 FAKE_CAP_OUT='{"verdict":"local","reason":"sem_vaga"}' PC "$BASE"); eq "oráculo fechado (recusa limpa): nenhum check, o motivo do oráculo fica" "$r" "rc=1 seen=1 offered=0 checked=[] gate_why=local"
reset; r=$(FAKE_CAP_RC=2 FAKE_CAP_OUT='{"verdict":"unknown"}' PC "$BASE"); eq "oráculo que não soube: o motivo do oráculo fica" "$r" "rc=1 seen=1 offered=0 checked=[] gate_why=unknown"
reset; r=$(FAKE_CHECK_RC=10 B1="$BASE" B2="$(sb wa-def34 "" wa-worker "story:approved")" R 'for b in "$B1" "$B2"; do _pilot_mbp_stamped_pre "$b" || true; done; echo "seen=$_PMS_SEEN checked=[$_PMS_CHECKED]"' | tail -1); eq "duas candidatas: os contadores acumulam" "$r" "seen=2 checked=[ mini mini]"
# DRY_RUN não escreve nem a memória (a "NENHUMA escrita" do comentário vale para bead E para o estado local, menos a linha-medição do jsonl)
reset; r=$(DRY_RUN=1 FAKE_CHECK_RC=10 P "$BASE"); eq "DRY_RUN + check mini: não oferece e NÃO grava memória" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=check-mini stop= probes=1 -"
reset; r=$(DRY_RUN=1 FAKE_CHECK_RC=11 P "$BASE"); eq "DRY_RUN + check unknown: NÃO grava memória" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=check-unknown stop= probes=1 -"
reset; r=$(DRY_RUN=1 P "$BASE"); eq "DRY_RUN + check node: a linha-medição do jsonl sim, memória não" "$r $(wc -l < "$JSONL" | tr -d ' ') $([ -e "$MEMO" ] && echo memo || echo -)" "rc=1 why=shadow stop= probes=1 1 -"
# shadow: a amostra anda — a bead que o check disse node é lembrada (sampled, 6 h) e a próxima varredura sonda OUTRAS
reset; r=$(PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "shadow: 1ª varredura mede a bead" "$r" "rc=1 why=shadow stop= probes=1"
eq "...e a lembra como sampled (chave mbp:, updated_at, veredito)" "$(memo_last)" "mbp:$ID|$UPD|sampled"
r=$(PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "shadow: 2ª varredura NÃO sonda a mesma bead de novo (memo:sampled), sem 2ª linha no jsonl" "$r $(ncalls) $(wc -l < "$JSONL" | tr -d ' ')" "rc=1 why=memo:sampled stop= probes=0 1 1"
r=$(PILOT_WA_MBP_ROUTE=shadow P "$(sb wa-def34 "" wa-worker "story:approved")"); eq "...e a candidata seguinte é medida (a amostra anda)" "$r $(wc -l < "$JSONL" | tr -d ' ')" "rc=1 why=shadow stop= probes=1 2"
reset; PILOT_WA_MBP_ROUTE=shadow P "$BASE" >/dev/null; r=$(PILOT_WA_NODE_PASS_SAMPLED_TTL=0 PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "shadow: PILOT_WA_NODE_PASS_SAMPLED_TTL=0 vence a amostra (sonda de novo)" "$r" "rc=1 why=shadow stop= probes=1"
reset; PILOT_WA_MBP_ROUTE=shadow P "$BASE" >/dev/null; r=$(PILOT_WA_NODE_PASS_SAMPLED_TTL=abc PILOT_WA_MBP_ROUTE=shadow P "$BASE"); eq "TTL do sampled ilegível: vale o padrão (a amostra segue lembrada)" "$r" "rc=1 why=memo:sampled stop= probes=0"
reset; r=$(PILOT_WA_MBP_ROUTE=on P "$BASE" >/dev/null; PILOT_WA_MBP_ROUTE=on P "$BASE"); eq "modo on NUNCA lembra node (a bead que o MBP leva é decidida a cada varredura)" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "rc=0 why= stop= probes=1 -"
reset; PILOT_WA_MBP_ROUTE=shadow P "$BASE" >/dev/null; r=$(PILOT_WA_MBP_ROUTE=on P "$BASE" | cut -d' ' -f1); eq "a amostra do shadow NÃO segura o modo on (quem liga o on com a amostra de 6 h na memória não perde a bead): oferece" "$r" "rc=0"
echo; echo "=== D. a contabilidade: _pilot_mbp_stamped_after ==="
# aft <rc de dispatch_one> [pré-trecho] — imprime "taken=N fails=N stop=… memo=…"
aft() { RC="$1" R "_PMS_UPD='$UPD'; ${PRE:-:}"$'\n''_pilot_mbp_stamped_after wa-abc12 "$RC"; echo "taken=$_PMS_TAKEN fails=$_PMS_FAILS stop=$_PMS_STOP"' | tail -1; }
reset; r=$(aft 0); eq "o MBP levou (rc 0): conta na varredura, nada mais" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "taken=1 fails=0 stop= -"
reset; r=$(PRE='_PMN_APPLY_RC=10' aft 0); eq "rc 0 não olha o rc do apply guardado (é o de outra tentativa)" "$r" "taken=1 fails=0 stop="
reset; r=$(PRE='_PMS_TAKEN=1' aft 0); eq "contagem acumula" "$r" "taken=2 fails=0 stop="
reset; r=$(PRE='_PMN_APPLY_RC=10' aft 1); eq "apply 10 (a bead não é do nó): falha, sem parar" "$r" "taken=0 fails=1 stop="; eq "...e memoriza mini (sob o updated_at ATUAL da bead, que a claim moveu: não o de antes da claim)" "$(memo_last)" "mbp:$ID|$CUR|mini"
reset; r=$(PRE='_PMN_APPLY_RC=11' aft 1); eq "apply 11: falha" "$r" "taken=0 fails=1 stop="; eq "...e memoriza unknown (updated_at atual)" "$(memo_last)" "mbp:$ID|$CUR|unknown"
reset; r=$(PRE='_PMN_APPLY_RC=' aft 1); eq "não chegou ao apply (adoção que falhou, mini sem lotar): falha" "$r" "taken=0 fails=1 stop="; eq "...e memoriza released (updated_at atual)" "$(memo_last)" "mbp:$ID|$CUR|released"
reset; r=$(PRE='_PMN_APPLY_RC=12' aft 1); eq "apply 12 (o MBP encheu ou a bead mudou): para a varredura, sem falha" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "taken=0 fails=0 stop=capacity -"
for c in 13 1 2 124 137 255; do reset; r=$(PRE="_PMN_APPLY_RC=$c" aft 1); eq "apply $c (a escrita pode ter pegado ou o gancho não leu): para sem memorizar" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "taken=0 fails=0 stop=hook-held -"; done
reset; r=$(PRE='_PMN_APPLY_RC=10; DISPATCH_RESULT=wa_node_unknown' aft 1); eq "o gancho segurou a bead (wa_node_unknown): para, mesmo com o rc 10 guardado, sem falha e sem memória" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "taken=0 fails=0 stop=hook-held -"
reset; r=$(PRE='_PMN_APPLY_RC=10; _PMS_FAILS=2' aft 1); eq "3ª falha (padrão 3): para a varredura (max-fails)" "$r" "taken=0 fails=3 stop=max-fails"
reset; r=$(PILOT_WA_MBP_STAMPED_MAX_FAILS=1 PRE='_PMN_APPLY_RC=10' aft 1); eq "PILOT_WA_MBP_STAMPED_MAX_FAILS=1: a 1ª falha para" "$r" "taken=0 fails=1 stop=max-fails"
reset; r=$(PILOT_WA_MBP_STAMPED_MAX_FAILS=abc PRE='_PMN_APPLY_RC=10; _PMS_FAILS=1' aft 1); eq "teto de falhas ilegível vale 3 (2 falhas: segue)" "$r" "taken=0 fails=2 stop="
reset; r=$(PRE='_PMN_APPLY_RC=10; _PMS_FAILS=2; _PMS_STOP=gate' aft 1); eq "uma parada que já existe não é sobrescrita" "$r" "taken=0 fails=3 stop=gate"
reset; r=$(PRE='_PMN_APPLY_RC=10; _PMS_UPD=' aft 1); eq "sem updated_at: a falha conta e não há linha de memória" "$r $([ -e "$MEMO" ] && echo memo || echo -)" "taken=0 fails=1 stop= -"
# a chave é a que a PRÓXIMA varredura vai ler no `bd list`: o updated_at de DEPOIS da claim/adoção/soltura (medido 25/10: a claim moveu 05:12:20Z → 05:13:25Z)
reset; r=$(PRE='_PMN_APPLY_RC=10' aft 1); r2=$(P "$(sb $ID "" wa-worker "story:approved" "$CUR")"); eq "a chave de agora acerta na varredura seguinte (a bead com o updated_at atual cai na memória)" "$r2" "rc=1 why=memo:mini stop= probes=0"
reset; PRE='_PMN_APPLY_RC=10' aft 1 >/dev/null; r2=$(P "$BASE" | cut -d' ' -f1); eq "...e a chave de ANTES da claim (a que o passo guardava) não acertaria nunca: sonda" "$r2" "rc=0"
reset; r=$(PRE='_PMN_APPLY_RC=10' aft 0 >/dev/null; nbd); eq "só lê a bead quando vai gravar memória: o rc 0 (levou) não chama o bd" "$r" "0"
reset; r=$(PRE='_PMN_APPLY_RC=12' aft 1 >/dev/null; nbd); eq "...nem o apply 12 (capacidade, não memoriza)" "$r" "0"
reset; r=$(PRE='_PMN_APPLY_RC=13' aft 1 >/dev/null; nbd); eq "...nem o apply 13 (incerto, não memoriza)" "$r" "0"
reset; r=$(PRE='_PMN_APPLY_RC=10; _PMS_UPD=' aft 1 >/dev/null; nbd); eq "...nem sem updated_at capturado (a varredura seguinte também não teria chave)" "$r" "0"
reset; PRE='_PMN_APPLY_RC=10' aft 1 >/dev/null; eq "...e, quando memoriza, lê UMA vez (show, só leitura)" "$(nbd) $(nupd)" "1 0"
# o leitor do updated_at atual, direto: sem id ou sem loja nem chama o bd (vazio ≠ lido)
reset; r=$(R "x=\$(_pilot_mbp_stamped_upd_now '' '$STORE') && echo \"rc=0 x=\$x\" || echo rc=1" | tail -1); eq "upd_now sem id: rc 1, nenhuma ida ao bd" "$r $(nbd)" "rc=1 0"
reset; r=$(R "x=\$(_pilot_mbp_stamped_upd_now wa-abc12 '') && echo \"rc=0 x=\$x\" || echo rc=1" | tail -1); eq "upd_now sem loja: rc 1, nenhuma ida ao bd" "$r $(nbd)" "rc=1 0"
reset; r=$(R "x=\$(_pilot_mbp_stamped_upd_now wa-abc12 '$STORE') && echo \"rc=0 x=\$x\" || echo rc=1" | tail -1); eq "upd_now com id e loja: devolve o updated_at atual, UMA ida ao bd" "$r $(nbd)" "rc=0 x=$CUR 1"
# ilegível NÃO é vazio, e nenhum dos dois vira chave: sem releitura boa a memória fica de fora (inerte) e o aviso diz por quê
reset; r=$(FAKE_BD_SHOW_RC=1 PRE='_PMN_APPLY_RC=10' aft 1); eq "show que falha: a falha conta, NÃO memoriza (sem chave confiável), UM aviso" "$r $([ -e "$MEMO" ] && echo memo || echo -) $(nwarn)" "taken=0 fails=1 stop= - 1"
grep -q 'updated_at' "$T/err" && ok "...que fala do updated_at" || fail "aviso: $(cat "$T/err")"
reset; jq 'del(.updated_at)' "$T/state.json" > "$T/state.new" && mv "$T/state.new" "$T/state.json"; r=$(PRE='_PMN_APPLY_RC=10' aft 1); eq "bead sem updated_at na releitura: NÃO memoriza, UM aviso" "$r $([ -e "$MEMO" ] && echo memo || echo -) $(nwarn)" "taken=0 fails=1 stop= - 1"
reset; jq '.id="wa-outra"' "$T/state.json" > "$T/state.new" && mv "$T/state.new" "$T/state.json"; r=$(PRE='_PMN_APPLY_RC=10' aft 1); eq "releitura de OUTRA bead: NÃO memoriza (nunca a chave de outra), UM aviso" "$r $([ -e "$MEMO" ] && echo memo || echo -) $(nwarn)" "taken=0 fails=1 stop= - 1"
reset; jq '.updated_at="não é data"' "$T/state.json" > "$T/state.new" && mv "$T/state.new" "$T/state.json"; r=$(PRE='_PMN_APPLY_RC=10' aft 1); eq "updated_at com cara de lixo: NÃO memoriza (a mesma regra de chave do passo), UM aviso" "$r $([ -e "$MEMO" ] && echo memo || echo -) $(nwarn)" "taken=0 fails=1 stop= - 1"
reset; mv "$T/city/.beads/routes.jsonl" "$T/city/.beads/x.jsonl"; r=$(PRE='_PMN_APPLY_RC=10' aft 1); mv "$T/city/.beads/x.jsonl" "$T/city/.beads/routes.jsonl"; eq "loja desconhecida: NÃO memoriza, UM aviso, e a falha conta" "$r $([ -e "$MEMO" ] && echo memo || echo -) $(nwarn)" "taken=0 fails=1 stop= - 1"
# o rc do apply guardado pelo gancho
dec() { R "${PRE:-:}"$'\n''rc=0; _pilot_mbp_node_decide wa-abc12 '"$STORE"' wa-worker || rc=$?; echo "rc=$rc apply=[$_PMN_APPLY_RC]"' | tail -1; }
reset; cp "$T/b.free.json" "$T/state.json"; r=$(FAKE_RC=12 dec); eq "o gancho em on guarda o rc do apply (12)" "$r" "rc=1 apply=[12]"
reset; cp "$T/b.free.json" "$T/state.json"; r=$(FAKE_RC=10 dec); eq "...o 10" "$r" "rc=1 apply=[10]"
reset; cp "$T/b.free.json" "$T/state.json"; r=$(FAKE_RC=0 dec); eq "...e o 0 (a bead foi escrita)" "$r" "rc=0 apply=[0]"
reset; cp "$T/b.free.json" "$T/state.json"; r=$(FAKE_RC=13 dec); eq "...e o 13 (incerto)" "$r" "rc=2 apply=[13]"
reset; r=$(PRE='_PMN_APPLY_RC=12; PILOT_WA_MBP_ROUTE=off' dec); eq "modo off sai antes do apply e ZERA o valor antigo (nunca o rc de outra bead)" "$r" "rc=1 apply=[]"
reset; r=$(PRE='_PMN_APPLY_RC=12; PILOT_TEST_WA_WORKER_LIVE_COUNT=1' dec); eq "mini com vaga (sai antes do apply): zerado" "$r" "rc=1 apply=[]"
reset; r=$(PRE='_PMN_APPLY_RC=12; DRY_RUN=1' dec); eq "dry-run (não é a escrita que o passo julga): zerado" "$r" "rc=1 apply=[]"
reset; cp "$T/b.free.json" "$T/state.json"; r=$(PRE='_PMN_APPLY_RC=12; PILOT_WA_MBP_ROUTE=shadow' dec); eq "shadow (só dry-run): zerado" "$r" "rc=1 apply=[]"
reset; cp "$T/b.stamped.json" "$T/state.json"; r=$(FAKE_RC=12 dec); eq "(2.2) o gancho sozinho com a bead carimbada: o apply recusa (12), o gancho devolve 1 — é o que o passo novo contorna" "$r" "rc=1 apply=[12]"
echo; echo "=== E. a fiação em dispatch_lane e dispatch_one (trechos REAIS) ==="
lnof() { grep -nF -- "$1" "$DISPATCHER" | head -n "${2:-1}" | tail -n 1 | cut -d: -f1; }
# --- dispatch_one: o yield ---
yrun() {   # yrun <pass> <native> <alvo> → "rc=N fell=0|1 result=… calls=…"
  : > "$T/reg"
  PASS="$1" YN="$2" YT="$3" bash -c '
set -euo pipefail
log() { :; }
_pilot_priority_target_is_pool() { echo tip >> "$FAKE_REG"; return "${F_POOL:-1}"; }
_pilot_priority_yield_for() { echo yf >> "$FAKE_REG"; return "${F_YIELD:-1}"; }
_pilot_priority_node_exempt() { echo ne >> "$FAKE_REG"; return 1; }
_pilot_priority_yield_say() { :; }
_pilot_priority_yield_release() { echo yr >> "$FAKE_REG"; }
_pilot_release_pool_cap_queued() { echo rcq >> "$FAKE_REG"; }
_pilot_node_only_wa_route_on() { return 1; }
_pilot_node_only_ps_route_on() { return 1; }
_PILOT_WA_NODE_PASS=0; _PILOT_NODE_ONLY=0; _PILOT_WA_MBP_PASS="$PASS"
f() {
  local STORY_ID=wa-abc12 STORY_BEAD_CITY=/x BUILDER_TARGET=wa-worker-1 STORY="{}" STORY_LABELS="" _PYS_TARGET="$YT" _PYS_NATIVE="$YN"
'"$YREG"'
  FELL=1
}
rc=0; f || rc=$?; echo "rc=$rc fell=${FELL:-0} result=${DISPATCH_RESULT:-} calls=$(tr "\n" "," < "$FAKE_REG")"' 2>/dev/null | tail -1
}
eq "bandeira, bead de WA do store do WA com alvo wa-worker: segue, o yield NEM é perguntado" "$(F_POOL=0 F_YIELD=0 yrun 1 1 wa-worker)" "rc=0 fell=1 result= calls="
eq "bandeira, bead do HQ (store da cidade): solta a claim como fila de capacidade, sem yield" "$(F_POOL=0 F_YIELD=0 yrun 1 0 wa-worker)" "rc=1 fell=0 result=rig_native_pool_session_cap_queued calls=rcq,"
eq "bandeira, alvo ps-worker: o mesmo (só o pool wa-worker chama o gancho do MBP)" "$(F_POOL=0 F_YIELD=0 yrun 1 1 ps-worker)" "rc=1 fell=0 result=rig_native_pool_session_cap_queued calls=rcq,"
eq "(controle) sem bandeira, o yield é perguntado e cede" "$(F_POOL=0 F_YIELD=0 yrun 0 1 wa-worker)" "rc=1 fell=0 result=priority_yield calls=tip,yf,ne,yr,"
eq "(controle) sem bandeira e sem yield: segue" "$(yrun 0 1 wa-worker)" "rc=0 fell=1 result= calls=tip,"
# --- dispatch_one: o gancho ---
mrun() {   # mrun <rc do Hetzner> <rc da adoção> <rc do gancho MBP> <bandeira> → "rc=N fell=0|1 target=… result=… calls=…"
  : > "$T/reg"
  WARC="$1" ADRC="$2" MBPRC="$3" PASS="$4" _PILOT_WA_NODE_PASS=0 _PILOT_NODE_ONLY=0 _SLING_TARGET=wa-worker bash -c '
set -euo pipefail
bd() { echo bd >> "$FAKE_REG"; }
log() { :; }
_pilot_wa_node_decide() { echo wa >> "$FAKE_REG"; return "$WARC"; }
_pilot_wa_node_adopt() { echo adopt >> "$FAKE_REG"; return "$ADRC"; }
_pilot_wa_node_unadopt() { echo unadopt >> "$FAKE_REG"; }
_pilot_mbp_node_decide() { echo mbp >> "$FAKE_REG"; return "$MBPRC"; }
_pilot_release_pool_cap_queued() { echo rcq >> "$FAKE_REG"; }
_pilot_priority_yield_release() { echo yield >> "$FAKE_REG"; }
unmark_pool_builder() { echo unmark >> "$FAKE_REG"; }
_PILOT_WA_MBP_PASS="$PASS"; _PMN_APPLY_RC=""
f() {
  local STORY_ID=wa-abc12 STORY_BEAD_CITY=/x BUILDER_TARGET=wa-worker-1
'"$HREG"'
  FELL=1
}
rc=0; f || rc=$?; echo "rc=$rc fell=${FELL:-0} target=$_SLING_TARGET result=${DISPATCH_RESULT:-} calls=$(tr "\n" "," < "$FAKE_REG")"' 2>/dev/null | tail -1
}
eq "bandeira, Hetzner não levou, adoção ok, MBP levou: alvo do nó, a vaga virtual do mini devolvida (unmark)" "$(mrun 1 0 0 1)" "rc=0 fell=1 target=wa-worker-remote result= calls=wa,adopt,mbp,unmark,"
eq "bandeira, MBP não levou (rc 1): devolve o carimbo, solta a claim como fila e NÃO cai no mini" "$(mrun 1 0 1 1)" "rc=1 fell=0 target=wa-worker result=rig_native_pool_session_cap_queued calls=wa,adopt,mbp,unadopt,rcq,"
eq "bandeira, adoção que falhou: o gancho NEM é chamado, solta a claim como fila" "$(mrun 1 1 0 1)" "rc=1 fell=0 target=wa-worker result=rig_native_pool_session_cap_queued calls=wa,adopt,rcq,"
eq "bandeira, MBP inseguro (rc 2): segura (wa_node_unknown), NÃO devolve o carimbo, NÃO solta como fila" "$(mrun 1 0 2 1)" "rc=1 fell=0 target=wa-worker result=wa_node_unknown calls=wa,adopt,mbp,bd,bd,"
eq "bandeira, Hetzner inseguro (rc 2): segura antes de adotar" "$(mrun 2 0 0 1)" "rc=1 fell=0 target=wa-worker result=wa_node_unknown calls=wa,bd,bd,"
eq "bandeira, Hetzner levou (rc 0): nem adota nem chama o MBP" "$(mrun 0 0 0 1)" "rc=0 fell=1 target=wa-worker-remote result= calls=wa,"
eq "(controle 2.2) sem bandeira, MBP levou: o alvo muda e NADA do passo novo roda (sem adoção, sem unmark)" "$(mrun 1 1 0 0)" "rc=0 fell=1 target=wa-worker-remote result= calls=wa,mbp,"
eq "(controle 2.2) sem bandeira, MBP não levou: segue no mini como antes (sem adoção, sem devolução, sem solta)" "$(mrun 1 1 1 0)" "rc=0 fell=1 target=wa-worker result= calls=wa,mbp,"
eq "(controle 2.2) sem bandeira, MBP inseguro: segura como antes" "$(mrun 1 1 2 0)" "rc=1 fell=0 target=wa-worker result=wa_node_unknown calls=wa,mbp,bd,bd,"
# a ordem no fonte: a adoção vem antes do gancho do MBP, que continua depois do ': # pool' do Hetzner
a1=$(lnof 'if [ "${_PILOT_WA_MBP_PASS:-0}" = "1" ] && ! _pilot_wa_node_adopt'); m1=$(lnof '_pilot_mbp_node_decide "$STORY_ID" "$STORY_BEAD_CITY" "$_SLING_TARGET"'); l1=$(lnof ': # pool: leave UNASSIGNED + open so RoutedPoolQuery')
{ [ -n "$a1" ] && [ -n "$m1" ] && [ -n "$l1" ] && [ "$l1" -lt "$a1" ] && [ "$a1" -lt "$m1" ]; } && ok "a adoção vem DEPOIS do ': # pool' do Hetzner e ANTES do gancho do MBP (as linhas do Hetzner ficam como estavam)" || fail "ordem (pool $l1, adoção $a1, gancho $m1)"
# --- dispatch_lane: os pulos pré-claim ---
lrun() {   # lrun <pre rc> → "out=continue|break|fell pass=N calls=…"; o ambiente diz o resto (F_BOUND/F_YIELD/F_CAP/F_UNREAD)
  : > "$T/reg"
  FPRE="$1" bash -c '
set -euo pipefail
log() { :; }
_pilot_mbp_stamped_pre() { echo pre >> "$FAKE_REG"; return "$FPRE"; }
_pilot_mbp_stamped_skip() { :; }
_pilot_priority_pool_bound_pre() { echo bound >> "$FAKE_REG"; return "${F_BOUND:-0}"; }
_pilot_priority_yield_for() { echo yf >> "$FAKE_REG"; return "${F_YIELD:-0}"; }
_pilot_priority_node_exempt_pre() { echo ne >> "$FAKE_REG"; return 1; }
_pilot_priority_yield_say() { :; }
_pilot_sweep_note() { echo "note:$3" >> "$FAKE_REG"; }
_pilot_pool_cap_full_for() { echo cap >> "$FAKE_REG"; return "${F_CAP:-0}"; }
_pilot_priority_waiter_note() { :; }
_pilot_note_pool_cap_queued() { return 1; }
_pilot_dispatch_halt() { echo halt >> "$FAKE_REG"; }
PRIORITY_YIELDED=0; NONQUEUE_FAILS=0; _PCAP_COUNT_UNREADABLE="${F_UNREAD:-}"; _PCAP_POOL=wa-worker; _PCAP_LIVE=4; _PCAP_MAX=4
lane() {
  local pick="{}" pick_id=wa-abc12 OUT=break ITER=0
  while :; do
    ITER=$((ITER+1)); if [ "$ITER" -ge 2 ]; then OUT=continue; break; fi
'"$LREG"'
    OUT=fell; break
  done
  echo "out=$OUT pass=${_mbp_pass:-?} calls=$(tr "\n" "," < "$FAKE_REG")"
}
lane' 2>/dev/null | tail -1
}
unset PILOT_WA_MBP_ROUTE; r=$(F_UNREAD=x lrun 0); eq "PILOT_WA_MBP_ROUTE sem valor (off): o passo NEM é chamado; yield, teto e contagem decidem como sempre" "$r" "out=continue pass=0 calls=bound,yf,ne,note:priority_yield,"
r=$(PILOT_WA_MBP_ROUTE=off lrun 0); eq "off explícito: pre nem é chamado (mesmo se devolvesse 0)" "$r" "out=continue pass=0 calls=bound,yf,ne,note:priority_yield,"
r=$(PILOT_WA_MBP_ROUTE=on lrun 1); eq "on, pre recusa: o passo é chamado ANTES dos pulos e eles decidem (yield)" "$r" "out=continue pass=0 calls=pre,bound,yf,ne,note:priority_yield,"
r=$(PILOT_WA_MBP_ROUTE=on F_BOUND=1 lrun 1); eq "on, pre recusa: o pulo do teto do pool" "$r" "out=continue pass=0 calls=pre,bound,cap,note:rig_native_pool_session_cap_queued,"
r=$(PILOT_WA_MBP_ROUTE=on F_BOUND=1 F_CAP=1 F_UNREAD=x lrun 1); eq "on, pre recusa: a parada por contagem ilegível" "$r" "out=break pass=0 calls=pre,bound,cap,note:rig_native_pool_count_unreadable,halt,"
r=$(PILOT_WA_MBP_ROUTE=on F_UNREAD=x lrun 0); eq "on, pre oferece (0): NÃO pula pelo yield, NÃO pula pelo teto do pool, NÃO para pela contagem — vai a dispatch_one" "$r" "out=fell pass=1 calls=pre,"
r=$(PILOT_WA_MBP_ROUTE=shadow lrun 1); eq "shadow chama o passo (que só registra) e o resto decide como sempre" "$r" "out=continue pass=0 calls=pre,bound,yf,ne,note:priority_yield,"
# --- dispatch_lane: o motivo de cada "não" do passo entra no resumo (a função de verdade, o trecho de verdade)
SKIPFN="$(fn_of _pilot_mbp_stamped_skip)"
krun() {   # krun <pre rc> <_PMS_WHY que o pre deixou> → "out=… pass=N skipped=[…]"
  : > "$T/reg"
  FPRE="$1" FWHY="$2" SKIPFN="$SKIPFN" bash -c '
set -euo pipefail
log() { :; }
_pilot_mbp_stamped_pre() { echo pre >> "$FAKE_REG"; _PMS_WHY="$FWHY"; return "$FPRE"; }
_pilot_priority_pool_bound_pre() { return 1; }
_pilot_pool_cap_full_for() { return 1; }
_pilot_priority_waiter_note() { :; }
_pilot_sweep_note() { :; }
_PMS_WHY="stale"; _PMS_SKIPPED=""
eval "$SKIPFN"
lane() {
  local pick="{}" pick_id=wa-abc12 OUT=break ITER=0
  while :; do
    ITER=$((ITER+1)); if [ "$ITER" -ge 2 ]; then OUT=continue; break; fi
'"$LREG"'
    OUT=fell; break
  done
  echo "out=$OUT pass=${_mbp_pass:-?} skipped=[${_PMS_SKIPPED:-}] calls=$(tr "\n" "," < "$FAKE_REG")"
}
lane' 2>/dev/null | tail -1
}
r=$(PILOT_WA_MBP_ROUTE=on krun 1 has-owner); eq "on, o passo recusa (has-owner): o motivo entra na lista do resumo" "$r" "out=fell pass=0 skipped=[ has-owner] calls=pre,"
r=$(PILOT_WA_MBP_ROUTE=on krun 1 'refused:a b'); eq "...o motivo com espaço vira um token só (a lista é separada por espaço)" "$r" "out=fell pass=0 skipped=[ refused:a_b] calls=pre,"
r=$(PILOT_WA_MBP_ROUTE=on krun 1 ''); eq "...motivo vazio vira '?' (nunca um buraco na lista)" "$r" "out=fell pass=0 skipped=[ ?] calls=pre,"
r=$(PILOT_WA_MBP_ROUTE=on krun 0 ''); eq "on, o passo oferece (0): nada entra na lista" "$r" "out=fell pass=1 skipped=[] calls=pre,"
r=$(PILOT_WA_MBP_ROUTE=off krun 1 has-owner); eq "off: o passo nem é chamado e a lista não anda (o _PMS_WHY velho não vaza)" "$r" "out=fell pass=0 skipped=[] calls="
r=$(PILOT_WA_MBP_ROUTE=shadow krun 1 shadow); eq "shadow: o 'não' do passo (shadow) entra na lista" "$r" "out=fell pass=0 skipped=[ shadow] calls=pre,"
# --- dispatch_lane: a bandeira em volta de dispatch_one ---
drun() {   # drun <_mbp_pass> <rc de dispatch_one> → "flag_in=… apply_in=[…] res_in=[…] flag_out=… calls=…"
  : > "$T/reg"
  MP="$1" D1RC="$2" bash -c '
set -euo pipefail
log() { :; }
dispatch_one() { echo "d1:flag=$_PILOT_WA_MBP_PASS apply=[${_PMN_APPLY_RC:-}] res=[${DISPATCH_RESULT:-}]" >> "$FAKE_REG"; return "$D1RC"; }
_pilot_mbp_stamped_after() { echo "after:$1:$2" >> "$FAKE_REG"; }
_pilot_sweep_note() { :; }
_pilot_priority_waiter_note() { :; }
_PILOT_WA_MBP_PASS=0; _PMN_APPLY_RC=10; DISPATCH_RESULT=stale; PRIORITY_YIELDED=0; NONQUEUE_FAILS=0; _PCAP_CALL_QUEUED=0; DISPATCHED=0
dn() {
  local pick="{}" pick_id=wa-abc12 lane=small pick_tier=story _mbp_pass="$MP" filled=0 slots=3
'"$DREG"'
}
dn || true
echo "flag_out=$_PILOT_WA_MBP_PASS calls=$(tr "\n" "," < "$FAKE_REG")"' 2>/dev/null | tail -1
}
eq "com a bandeira, dispatch_one OK: a bandeira está 1 lá dentro, o rc e o resultado do apply vêm zerados, depois volta a 0 e o passo contabiliza (rc 0)" "$(drun 1 0)" "flag_out=0 calls=d1:flag=1 apply=[] res=[],after:wa-abc12:0,"
eq "com a bandeira, dispatch_one falhou: contabiliza com rc 1 e a bandeira volta a 0" "$(drun 1 1)" "flag_out=0 calls=d1:flag=1 apply=[] res=[],after:wa-abc12:1,"
eq "sem bandeira, dispatch_one OK: a bandeira é 0 lá dentro, o passo NÃO contabiliza e o resultado antigo não é mexido" "$(drun 0 0)" "flag_out=0 calls=d1:flag=0 apply=[] res=[stale],"
eq "sem bandeira, dispatch_one falhou: o passo NÃO contabiliza" "$(drun 0 1)" "flag_out=0 calls=d1:flag=0 apply=[] res=[stale],"
# a ordem no fonte
p1=$(lnof '_pilot_mbp_stamped_pre "$pick"'); y1=$(lnof '_pilot_priority_pool_bound_pre "$pick" && _pilot_priority_yield_for "$pick"'); c1=$(lnof '_pilot_pool_cap_full_for "$pick"'); u1=$(lnof 'if [ "$_mbp_pass" != 1 ] && [ -n "${_PCAP_COUNT_UNREADABLE:-}" ]; then'); n1=$(lnof '_PILOT_NODE_ONLY:-0}" = "1" ] && ! _pilot_node_only_candidate_pre "$pick"')
{ [ -n "$n1" ] && [ -n "$p1" ] && [ -n "$y1" ] && [ -n "$c1" ] && [ -n "$u1" ] && [ "$n1" -lt "$p1" ] && [ "$p1" -lt "$y1" ] && [ "$y1" -lt "$c1" ] && [ "$c1" -lt "$u1" ]; } && ok "em dispatch_lane o passo vem DEPOIS da guarda só-nó do disk floor e ANTES dos pulos de yield, de teto e da contagem ilegível" || fail "ordem (só-nó $n1, passo $p1, yield $y1, teto $c1, contagem $u1)"
eq "o passo é chamado em UM lugar de dispatch_lane" "$(grep -cF -- '_pilot_mbp_stamped_pre "$pick"' "$DISPATCHER")" "1"
# a passada de WA no nó deixa o motivo da parada
eq "a passada de WA no nó zera o motivo da parada na entrada e o grava antes do resumo" "$(awk '/^_pilot_wa_node_pass\(\)/{f=1} f&&/^  _PWP_LAST_STOP=""$/{a++} f&&/^  _PWP_LAST_STOP="\$\{_pw_stop:-\}"$/{b++} f&&/^}$/{exit} END{print a+0 "," b+0}' "$DISPATCHER")" "1,1"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo; echo "=== F. o caminho inteiro: lane → claim → adoção → apply → sessão ==="
# O trecho REAL de dispatch_lane (pré + pulos + bandeira), um dispatch_one cujo miolo é o trecho REAL do yield e do gancho, e as funções REAIS (pré, adoção, gancho, abertura da sessão, contabilidade) com bd, gc e
# mbp-node-dispatch.sh falsos. Só a claim e o gancho do Hetzner (que recusa a carimbada com 12 e devolve 1) são falsos.
e2e() {   # e2e <candidata> → "res=… target=… taken=… fails=… stop=… flag=…"
  : > "$T/reg"
  BEAD="$1" R '
_pilot_wa_node_decide() { echo wa >> "$FAKE_REG"; return 1; }
_pilot_priority_target_is_pool() { return 1; }
_pilot_priority_yield_for() { echo YIELD >> "$FAKE_REG"; return 0; }
_pilot_priority_node_exempt_pre() { return 1; }
_pilot_priority_pool_bound_pre() { echo BOUND >> "$FAKE_REG"; return 0; }
_pilot_pool_cap_full_for() { echo CAPFULL >> "$FAKE_REG"; return 0; }
_pilot_priority_yield_say() { :; }
_pilot_priority_waiter_note() { :; }
_pilot_note_pool_cap_queued() { return 1; }
_pilot_dispatch_halt() { echo HALT >> "$FAKE_REG"; }
_pilot_node_only_candidate_pre() { return 0; }
_pilot_sweep_note() { echo "note:$3" >> "$FAKE_REG"; }
_pilot_release_pool_cap_queued() { echo "rcq" >> "$FAKE_REG"; }
_pilot_priority_yield_release() { echo "yield-release" >> "$FAKE_REG"; }
unmark_pool_builder() { echo "unmark" >> "$FAKE_REG"; }
_PILOT_WA_NODE_PASS=0; _PILOT_NODE_ONLY=0; _PNY_EXEMPT_THIS=0; _PCAP_COUNT_UNREADABLE=""; _PCAP_CALL_QUEUED=0; PRIORITY_YIELDED=0; NONQUEUE_FAILS=0; DISPATCHED=0; DISPATCH_RESULT=""
dispatch_one() {
  local STORY_ID=wa-abc12 STORY_BEAD_CITY='"$STORE"' BUILDER_TARGET=wa-worker-1 STORY="{}" STORY_LABELS="" _SLING_TARGET=wa-worker _PYS_TARGET=wa-worker _PYS_NATIVE=1
  echo claim >> "$FAKE_REG"
'"$YREG"'
'"$HREG"'
  DISPATCH_RESULT="slung"
  return 0
}
lane() {
  local pick="$BEAD" pick_id=wa-abc12 lane=small pick_tier=story filled=0 slots=3 OUT=skipped ITER=0
  while :; do
    ITER=$((ITER+1)); if [ "$ITER" -ge 2 ]; then break; fi   # o `continue` de um pulo reentra: a lista de candidatas do laço real acaba, aqui acaba na 2ª volta
'"$LREG"'
'"$DREG"'
    OUT=dispatched; break
  done
  echo "out=$OUT res=${DISPATCH_RESULT:-} taken=$_PMS_TAKEN fails=$_PMS_FAILS stop=$_PMS_STOP flag=$_PILOT_WA_MBP_PASS reg=$(tr "\n" "," < "$FAKE_REG")"
}
lane' 2>/dev/null | tail -1
}
LAST_UPD() { grep '|update|' "$T/bdcalls" | tail -1; }
# F1 — o caso do bead: carimbada, mini cheio, oráculo node, check node, apply escreve
reset; r=$(e2e "$BASE")
eq "carimbada + mini cheio + MBP com vaga: dispatch_one é chamado, o yield e o teto NÃO a seguram, o MBP leva" "$r" "out=dispatched res=slung taken=1 fails=0 stop= flag=0 reg=claim,wa,unmark,note:slung,"
eq "a bead ficou com o alias do MBP (dono = marca, in_progress) e SEM carimbo" "$(st4)" "in_progress,wa-worker-remote-mbp-1,wa-worker-remote-mbp-1,-"
grep -qF -- '|new|wa-worker-remote-mbp|--alias|wa-worker-remote-mbp-1|' "$T/gccalls" && ok "a sessão do alias do MBP foi aberta" || fail "sem session new: $(cat "$T/gccalls")"
grep -qF -- 'session|nudge|wa-worker-remote-mbp-1|' "$T/gccalls" && ok "...e avisada" || fail "sem nudge: $(cat "$T/gccalls")"
eq "a ordem das escritas: 1ª retira o carimbo (adoção), depois o apply escreve a bead; nada devolve o carimbo" "$(grep -c -- '--unset-metadata|gc.routed_to' "$T/bdcalls") $(grep -c -- '--set-metadata' "$T/bdcalls") $(cat "$T/calls" | tr '\n' ';')" "1 0 check $ID --store $STORE;apply $ID --store $STORE --basis any;"
# F2 — o MBP encheu entre a sonda e o apply (rc 12): o carimbo volta, a claim solta, o mini NÃO recebe
reset; r=$(FAKE_RC=12 e2e "$BASE")
eq "apply 12: devolve o carimbo, solta a claim como fila de capacidade, NÃO despacha, a varredura para (capacity)" "$r" "out=dispatched res=rig_native_pool_session_cap_queued taken=0 fails=0 stop=capacity flag=0 reg=claim,wa,rcq,note:rig_native_pool_session_cap_queued,"
eq "...a bead voltou ao estado de antes (aberta, sem dono, carimbada)" "$(st4)" "open,-,-,wa-worker"
eq "...nenhuma sessão aberta" "$(ngc)" "0"
# F3 — o apply diz que a bead não é do nó (10): mesma devolução, e a bead é memorizada
reset; r=$(FAKE_RC=10 e2e "$BASE")
eq "apply 10: devolve o carimbo e conta a falha" "$r $(st4)" "out=dispatched res=rig_native_pool_session_cap_queued taken=0 fails=1 stop= flag=0 reg=claim,wa,rcq,note:rig_native_pool_session_cap_queued, open,-,-,wa-worker"
eq "...e memoriza mini com a chave do MBP (o Hetzner não herda) e o updated_at DEPOIS da claim e da soltura" "$(memo_last)" "mbp:$ID|$CUR|mini"
# F4 — a adoção não pega (o bd não mudou nada): o gancho nem é chamado
reset; r=$(FAKE_BD_UPDATE_MODE=noop e2e "$BASE")
eq "adoção que não se confirma: o apply NÃO é chamado, o carimbo segue, a claim solta como fila" "$r $(st4) $(cat "$T/calls" | grep -c apply)" "out=dispatched res=rig_native_pool_session_cap_queued taken=0 fails=1 stop= flag=0 reg=claim,wa,rcq,note:rig_native_pool_session_cap_queued, open,-,-,wa-worker 0"
# F5 — corrida: um dono apareceu entre a sonda e a adoção
reset; cp "$T/b.owned.json" "$T/state.json"; r=$(e2e "$BASE")
eq "dono que apareceu: nenhuma escrita na bead, nenhum apply, a claim solta" "$r $(nupd) $(grep -c apply "$T/calls")" "out=dispatched res=rig_native_pool_session_cap_queued taken=0 fails=1 stop= flag=0 reg=claim,wa,rcq,note:rig_native_pool_session_cap_queued, 0 0"
eq "...e o dono segue com a bead" "$(st4)" "in_progress,mila-wa,-,wa-worker"
# F6 — apply com rc incerto (13) e a escrita pegou: segura, NÃO devolve o carimbo
reset; r=$(FAKE_RC=13 FAKE_APPLY_WRITES=1 e2e "$BASE")
eq "rc 13 do apply: segura (wa_node_unknown), para a varredura, NÃO devolve o carimbo e NÃO solta como fila" "$r" "out=dispatched res=wa_node_unknown taken=0 fails=0 stop=hook-held flag=0 reg=claim,wa,note:wa_node_unknown,"
eq "...o assentamento do gancho desfez a escrita do apply (livre, sem carimbo: estado de primeira vista)" "$(st4)" "open,-,-,-"
eq "...e nenhuma escrita devolveu gc.routed_to" "$(grep -c -- '--set-metadata' "$T/bdcalls")" "0"
# F7 — as saídas do passo antes de qualquer claim
reset; r=$(PILOT_WA_MBP_ROUTE=shadow e2e "$BASE")
eq "shadow: nada de claim nem de escrita; o yield de sempre cede a bead" "$r $(nbd) $(wc -l < "$JSONL" | tr -d ' ')" "out=skipped res= taken=0 fails=0 stop= flag=0 reg=BOUND,YIELD,note:priority_yield, 0 1"
reset; r=$(PILOT_TEST_WA_WORKER_LIVE_COUNT=2 e2e "$BASE")
eq "mini com vaga: o passo não oferece, o yield de sempre decide, nada escrito" "$r $(nbd)" "out=skipped res= taken=0 fails=0 stop= flag=0 reg=BOUND,YIELD,note:priority_yield, 0"
reset; r=$(FAKE_CAP_OUT='{"verdict":"mini","free":0}' e2e "$BASE")
eq "oráculo do MBP fechado: o passo não oferece, o yield de sempre decide, nada escrito" "$r $(nbd) $(ngc)" "out=skipped res= taken=0 fails=0 stop=gate flag=0 reg=BOUND,YIELD,note:priority_yield, 0 0"
reset; r=$(e2e "$(sb $ID "" "" "story:approved")")
eq "bead de primeira vista (sem carimbo): o passo não a toca; segue o caminho de sempre (aqui, o yield)" "$r $(nbd)" "out=skipped res= taken=0 fails=0 stop= flag=0 reg=BOUND,YIELD,note:priority_yield, 0"
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo; echo "=== H. o resumo por varredura: o que o passo fez e por que parou ==="
# A fonte disse: o oráculo que falha, o check que estoura e as paradas (capacity, hook-held, max-fails) eram FECHADO-EM-SILÊNCIO — o passo ligado parecia "sem MBP livre" quando na verdade estava cego.
# Agora cada varredura com o passo ligado deixa UMA linha de log e UM evento em mbp-node-route.jsonl; o aviso do 3º estado sai onde ele acontece (A e B acima).
sum() { R "${PRE:-:}"$'\n''rc=0; _pilot_mbp_stamped_summary || rc=$?; echo "rc=$rc"' | tail -1; }
evl() { tail -1 "$JSONL" | jq -r "$1"; }
nev() { [ -f "$JSONL" ] && wc -l < "$JSONL" | tr -d ' ' || echo 0; }
reset; r=$(sum); eq "varredura sem nada a decidir: o resumo sai (rc 0) com UM evento" "$r $(nev)" "rc=0 1"
eq "...evento mbp-stamped-summary, modo on, oráculo não perguntado, tudo zerado, sem parada" "$(evl '[.event,.mode,.gate,.seen,.probes,.offered,.taken,.fails,.stopped,(.skipped|length),(.checks|length),.dry_run]|join(",")')" "mbp-stamped-summary,on,not-asked,0,0,0,0,0,none,0,0,false"
evl '.ts' | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' && ok "...com ts em UTC" || fail "ts: $(evl .ts)"
grep -qF 'LOG ga-w7qwl1.2.6: passo da carimbada no MBP (modo=on)' "$T/err" && ok "...e UMA linha de log com o modo" || fail "log: $(cat "$T/err")"
eq "...e nenhum aviso" "$(nwarn)" "0"
reset; r=$(PRE='_PMS_SEEN=5; _PMS_OFFERED=2; _PMS_SKIPPED=" has-owner has-owner not-stamped"; _PMS_CHECKED=" node mini timeout"; _PMS_PROBES=3; _PMS_TAKEN=1; _PMS_FAILS=1; _PMS_STOP=capacity; _PMS_GATE=ok' sum)
eq "varredura com histórico: o resumo sai" "$r" "rc=0"
eq "...contadores no evento" "$(evl '[.seen,.probes,.offered,.taken,.fails,.stopped,.gate]|join(",")')" "5,3,2,1,1,capacity,ok"
eq "...as puladas agrupadas por motivo" "$(evl '.skipped|tojson')" '{"has-owner":2,"not-stamped":1}'
eq "...os checks agrupados por veredito" "$(evl '.checks|tojson')" '{"mini":1,"node":1,"timeout":1}'
for f in 'candidatas=5' 'has-owner=2' 'not-stamped=1' 'oráculo=ok' 'sondas=3 (node 1 · mini 1 · unknown 0 · timeout 1 · erro 0 · ausente 0)' 'oferecidas=2' 'levadas=1' 'falhas=1' 'parou: capacity'; do
  grep -qF -- "$f" "$T/err" && ok "...a linha de log traz '$f'" || fail "log sem '$f': $(cat "$T/err")"
done
reset; sum >/dev/null; grep -qF 'parou: fim da lista' "$T/err" && ok "sem parada o log diz 'fim da lista'" || fail "log: $(cat "$T/err")"
reset; sum >/dev/null; grep -qF 'puladas: nenhuma' "$T/err" && ok "sem puladas o log diz 'nenhuma'" || fail "log: $(cat "$T/err")"
# o estado do oráculo, de cada jeito
for spec in '||not-asked' 'ok||ok' 'no|local|local' 'no|unknown|unknown' 'no|timeout|timeout' 'no|error|error' 'no|unreadable|unreadable' 'no|missing|missing' 'no||no'; do
  g="${spec%%|*}"; rest="${spec#*|}"; w="${rest%%|*}"; want="${rest#*|}"
  reset; PRE="_PMS_GATE='$g'; _PMS_GATE_WHY='$w'" sum >/dev/null; eq "oráculo '$g' motivo '$w': o evento diz '$want'" "$(evl .gate)" "$want"
done
reset; PRE='_PMS_GATE=no; _PMS_GATE_WHY=unknown' sum >/dev/null; grep -qF 'oráculo=unknown' "$T/err" && ok "...e o log também" || fail "log: $(cat "$T/err")"
# modo e dry-run
reset; PILOT_WA_MBP_ROUTE=shadow sum >/dev/null; eq "shadow: o evento diz shadow" "$(evl '[.mode,.dry_run]|join(",")')" "shadow,false"
reset; DRY_RUN=1 sum >/dev/null; eq "DRY_RUN: o evento marca dry_run" "$(evl '[.mode,.dry_run]|join(",")')" "on,true"
grep -qF 'modo=on dry-run' "$T/err" && ok "...e o log também" || fail "log: $(cat "$T/err")"
# o resumo nunca derruba a varredura
reset; mkdir -p "$CITYGC/mbp-node-route.jsonl"; r=$(sum); eq "jsonl impossível de gravar (é uma pasta): o resumo sai com rc 0" "$r" "rc=0"
grep -q 'resumo do passo da carimbada NÃO gravado' "$T/err" && ok "...AVISA que perdeu o evento" || fail "sem aviso: $(cat "$T/err")"
grep -qF 'LOG ga-w7qwl1.2.6: passo da carimbada no MBP' "$T/err" && ok "...e a linha de log saiu mesmo assim" || fail "log: $(cat "$T/err")"
rmdir "$CITYGC/mbp-node-route.jsonl"
# os agrupadores
tal() { R '_pilot_mbp_stamped_tally "$1"' _ "$1" 2>/dev/null | tail -1; }
r=$(R 'x=$(_pilot_mbp_stamped_tally " a b a c"); echo "$x"' | tail -1); eq "tally agrupa e conta" "$r" '{"a":2,"b":1,"c":1}'
r=$(R 'x=$(_pilot_mbp_stamped_tally ""); echo "$x"' | tail -1); eq "tally de lista vazia: {}" "$r" '{}'
mkdir -p "$T/failbin"; printf '#!/bin/sh\nexit 5\n' > "$T/failbin/jq"; chmod +x "$T/failbin/jq"
r=$(PATH="$T/failbin:$PATH" R 'x=$(_pilot_mbp_stamped_tally " a b"); echo "$x"' | tail -1); eq "tally com jq que falha: {\"tally-unreadable\":1} — NUNCA {} (falhou não é vazio)" "$r" '{"tally-unreadable":1}'
reset; r=$(PATH="$T/failbin:$PATH" PRE='_PMS_SKIPPED=" a"' sum); eq "resumo com jq que falha: rc 0 mesmo assim (nunca derruba a varredura)" "$r" "rc=0"
grep -qF 'puladas: ilegível' "$T/err" && ok "...a linha de log diz 'ilegível' (não soube contar NÃO é 'nenhuma pulada')" || fail "log: $(cat "$T/err")"
grep -q 'resumo do passo da carimbada NÃO gravado' "$T/err" && ok "...e AVISA que o evento não saiu" || fail "sem aviso: $(cat "$T/err")"
# a ponta a ponta: o oráculo que não soube dizer aparece no resumo, com UM aviso e a parada certa
reset; r=$(FAKE_CAP_RC=2 FAKE_CAP_OUT='{"verdict":"unknown","reason":"config"}' B1="$BASE" B2="$(sb wa-def34 "" wa-worker "story:approved")" B3="$(sb wa-ghi56 mila-wa wa-worker "story:approved")" R '
for b in "$B1" "$B2" "$B3"; do _pilot_mbp_stamped_pre "$b" || _pilot_mbp_stamped_skip; done
_pilot_mbp_stamped_summary; echo done' | tail -1)
eq "3 candidatas com o oráculo em rc 2: o evento diz gate unknown, 3 vistas, parada gate, 0 sondas" "$(evl '[.gate,.seen,.probes,.stopped,(.checks|length)]|join(",")')" "unknown,3,0,gate,0"
eq "...as puladas: a que fechou o oráculo e as que a parada barrou" "$(evl '.skipped|tojson')" '{"gate":1,"stop:gate":2}'
eq "...UM aviso só (o do oráculo), uma ida ao oráculo, nenhum check" "$(nwarn) $(ncap) $(ncalls)" "1 1 0"
reset; r=$(FAKE_CHECK_RC=124 B1="$BASE" B2="$(sb wa-def34 "" wa-worker "story:approved")" R '
for b in "$B1" "$B2"; do _pilot_mbp_stamped_pre "$b" || _pilot_mbp_stamped_skip; done
_pilot_mbp_stamped_summary; echo done' | tail -1)
eq "2 candidatas com o check estourando: 2 sondas, checks {timeout:2}, sem parada, oráculo ok" "$(evl '[.gate,.seen,.probes,(.checks|tojson),.stopped]|join(",")')" 'ok,2,2,{"timeout":2},none'
eq "...um aviso por check que estourou (o orçamento de sondas limita)" "$(nwarn)" "2"
reset; r=$(FAKE_CAP_RC=1 FAKE_CAP_OUT='{"verdict":"local","reason":"sem_vaga"}' B1="$BASE" R '
_pilot_mbp_stamped_pre "$B1" || _pilot_mbp_stamped_skip
_pilot_mbp_stamped_summary; echo done' | tail -1)
eq "oráculo com recusa limpa: o evento diz gate local, parada gate, e NENHUM aviso (é o 'não' normal)" "$(evl '[.gate,.stopped]|join(",")') $(nwarn)" "local,gate 0"
reset; r=$(FAKE_CHECK_RC=10 B1="$BASE" R '
_pilot_mbp_stamped_pre "$B1" || _pilot_mbp_stamped_skip
_pilot_mbp_stamped_summary; echo done' | tail -1)
eq "check mini: checks {mini:1}, puladas {check-mini:1}, nenhum aviso" "$(evl '[(.checks|tojson),(.skipped|tojson)]|join(" ")') $(nwarn)" '{"mini":1} {"check-mini":1} 0'
# a fiação no fluxo principal: UMA chamada, só com o passo ligado, antes do evento agregado da varredura
SUMLINE="$(grep -F -- '_pilot_mbp_stamped_summary; fi' "$DISPATCHER" | head -1)"
[ -n "$SUMLINE" ] || { echo "FATAL: a chamada do resumo no fluxo principal não foi achada em $DISPATCHER" >&2; exit 2; }
srun() { PILOT_WA_MBP_ROUTE="$1" bash -c '_pilot_mbp_stamped_summary() { echo called; }
'"$SUMLINE" 2>/dev/null; }
unset PILOT_WA_MBP_ROUTE; r=$(bash -c '_pilot_mbp_stamped_summary() { echo called; }
'"$SUMLINE" 2>/dev/null); eq "fluxo principal, PILOT_WA_MBP_ROUTE sem valor: o resumo NÃO é chamado" "$r" ""
eq "fluxo principal, off: NÃO é chamado" "$(srun off)" ""
eq "fluxo principal, on: chamado" "$(srun on)" "called"
eq "fluxo principal, shadow: chamado" "$(srun shadow)" "called"
eq "o resumo é chamado em UM lugar" "$(grep -cF -- '_pilot_mbp_stamped_summary; fi' "$DISPATCHER")" "1"
w1=$(awk -v l="$SUMLINE" '$0 == l {print NR; exit}' "$DISPATCHER"); e1=$(awk '$0 == "_pilot_sweep_emit" {print NR; exit}' "$DISPATCHER"); d1=$(awk '$0 ~ /^dispatch_lane\(\)/ {print NR; exit}' "$DISPATCHER")
{ [ -n "$w1" ] && [ -n "$e1" ] && [ -n "$d1" ] && [ "$d1" -lt "$w1" ] && [ "$w1" -lt "$e1" ] && [ $((e1 - w1)) -le 4 ]; } && ok "o resumo vem depois das pistas e logo ANTES do evento agregado da varredura (uma falha adiante não o perde)" || fail "ordem (dispatch_lane $d1, resumo $w1, evento $e1)"
# O carimbo é mesmo o que o `apply` REAL recusa: o despachante do MBP de verdade, com bd, gc, classificador e oráculo falsos.
# Os mutantes mexem no dispatcher do Pilot, não neste script: a seção não roda nas cópias.
if [ -z "${MBP_STAMPED_SELFTEST_FILE:-}" ]; then
  echo; echo "=== F2. o apply real: com o carimbo recusa (12), sem o carimbo aceita ==="
  MBS="$SELF_DIR/../../../scripts/mbp-node-dispatch.sh"
  if [ -x "$MBS" ]; then
    mkdir -p "$T/h/store" "$T/h/city/.gc"
    cat > "$T/h/bd" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -C ] && shift 2
case "${1:-}" in
  show) if [ -n "${FAKE_ROUTE:-}" ]; then printf '[{"id":"wa-hz1","title":"t","status":"open","metadata":{"gc.routed_to":"%s"}}]\n' "$FAKE_ROUTE"; else printf '[{"id":"wa-hz1","title":"t","status":"open","metadata":{}}]\n'; fi ;;
  list) printf '[]\n' ;;
  *) exit 1 ;;
esac
EOF
    cat > "$T/h/gc" <<'EOF'
#!/bin/sh
[ "$1 $2" = "session list" ] && { printf '{"sessions":[]}'; exit 0; }
exit 1
EOF
    printf 'import sys\nsys.stdin.read()\nsys.stdout.write(\x27{"verdict":"node","basis":"text","reasons":[],"paths":[],"tests":[],"info":[]}\x27)\n' > "$T/h/cls.py"
    printf 'import sys\nsys.stdout.write(\x27{"verdict":"node","reason":"free_slot","effective":2,"active":0,"free":2}\x27)\n' > "$T/h/cap.py"
    chmod +x "$T/h/bd" "$T/h/gc"
    mbp() { GC_CITY="$T/h/city" MBP_NODE_BD="$T/h/bd" MBP_NODE_GC="$T/h/gc" MBP_NODE_CLASSIFY="$T/h/cls.py" MBP_NODE_CAPACITY="$T/h/cap.py" MBP_NODE_LOG="$T/h/city/.gc/log.jsonl" bash "$MBS" apply wa-hz1 --store "$T/h/store" --basis any --dry-run >/dev/null 2>&1; echo "rc=$?"; }
    eq "controle: bead livre e sem rota, o apply real do MBP aceita" "$(FAKE_ROUTE= mbp)" "rc=0"
    eq "bead com gc.routed_to=wa-worker (o carimbo do Pilot): o apply real RECUSA (12) — é por isso que o passo adota antes" "$(FAKE_ROUTE=wa-worker mbp)" "rc=12"
  else
    fail "scripts/mbp-node-dispatch.sh não está em $MBS"
  fi
fi
# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
if [ -n "${MBP_STAMPED_SELFTEST_FILE:-}" ]; then
  echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
  [ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
  exit 0
fi
# MBP_STAMPED_ST_NOMUT=1 pula os mutantes (a bateria do gate é a completa)
if [ "${MBP_STAMPED_ST_NOMUT:-}" = 1 ]; then
  echo "(mutantes pulados: MBP_STAMPED_ST_NOMUT=1)"; echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
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
  if MBP_STAMPED_SELFTEST_FILE="$copy" bash "$SELF" >/dev/null 2>&1; then fail "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi
}
PRE_=_pilot_mbp_stamped_pre; GATE_=_pilot_mbp_stamped_gate; CHK_=_pilot_mbp_stamped_check; AFT_=_pilot_mbp_stamped_after; DEC_=_pilot_mbp_node_decide
UPD_=_pilot_mbp_stamped_upd_now; SKP_=_pilot_mbp_stamped_skip; TAL_=_pilot_mbp_stamped_tally; SUM_=_pilot_mbp_stamped_summary
# ── _pilot_mbp_stamped_gate
mut gate-free-0          $GATE_ '(.free >= 1)' '(.free >= 0)'
mut gate-qualquer-veredito $GATE_ '(.verdict == "node") and' '(.verdict != "") and'
mut gate-rc-ignorado     $GATE_ '0:node) _PMS_GATE=ok; return 0 ;;' '*:node) _PMS_GATE=ok; return 0 ;;'
mut gate-sem-cache       $GATE_ 'case "${_PMS_GATE:-}" in ok) return 0 ;; no) return 1 ;; esac' ':'
mut gate-free-texto      $GATE_ '((.free | type) == "number") and' ''
mut gate-rc1-node-abre   $GATE_ '0:node) _PMS_GATE=ok; return 0 ;;' '0:node|1:node) _PMS_GATE=ok; return 0 ;;'
mut gate-sem-aviso-unknown $GATE_ 'warn "mbp-node: o oráculo do MBP não soube dizer' ': "mbp-node: o oráculo do MBP não soube dizer'
mut gate-sem-aviso-prazo $GATE_ 'warn "mbp-node: o oráculo do MBP estourou o prazo' ': "mbp-node: o oráculo do MBP estourou o prazo'
mut gate-sem-aviso-ilegivel $GATE_ 'warn "mbp-node: a resposta do oráculo do MBP é ilegível' ': "mbp-node: a resposta do oráculo do MBP é ilegível'
mut gate-sem-aviso-erro  $GATE_ 'warn "mbp-node: o oráculo do MBP falhou' ': "mbp-node: o oráculo do MBP falhou'
mut gate-sem-aviso-ausente $GATE_ 'warn "mbp-node: o oráculo $_g_cap não existe' ': "mbp-node: o oráculo $_g_cap não existe'
mut gate-local-avisa     $GATE_ '1:local) _PMS_GATE_WHY=local ;;' '1:local) _PMS_GATE_WHY=local; warn "mbp-node: oráculo disse local" ;;'
mut gate-porque-local-some $GATE_ '1:local) _PMS_GATE_WHY=local ;;' '1:local) : ;;'
mut gate-porque-unknown-some $GATE_ '2:unknown) _PMS_GATE_WHY=unknown;' '2:unknown) :;'
mut gate-prazo-vira-erro $GATE_ '124:*|137:*|143:*) _PMS_GATE_WHY=timeout;' '124:*|137:*|143:*) _PMS_GATE_WHY=error;'
mut gate-ilegivel-vira-erro $GATE_ '0:*|1:*|2:*) _PMS_GATE_WHY=unreadable;' '0:*|1:*|2:*) _PMS_GATE_WHY=error;'
mut gate-ausente-sem-porque $GATE_ '_PMS_GATE_WHY=missing; warn' ':; warn'
# ── _pilot_mbp_stamped_check
mut check-rc0-qualquer   $CHK_ 'if [ "${_sc_vb%%|*}" = node ]; then' 'if true; then'
mut check-10-node        $CHK_ '10) _PMS_V=mini ;;' '10) _PMS_V=node ;;'
mut check-erro-node      $CHK_ '_PMS_V="error"; _PMS_BASIS=""' '_PMS_V="node"; _PMS_BASIS=""'
mut check-timeout-erro   $CHK_ '124|137|143) _PMS_V=timeout ;;' '124|137|143) _PMS_V=error ;;'
mut check-sem-loja       $CHK_ 'check "$_sc_id" --store "$_sc_store"' 'check "$_sc_id"'
mut check-sem-aviso-prazo $CHK_ 'timeout) warn "mbp-node: o check de' 'timeout) : "mbp-node: o check de'
mut check-sem-aviso-erro $CHK_ 'warn "mbp-node: o check de $_sc_id falhou ou deu' ': "mbp-node: o check de $_sc_id falhou ou deu'
mut check-sem-aviso-ausente $CHK_ 'warn "mbp-node: $_sc_dir/mbp-node-dispatch.sh não existe' ': "mbp-node: $_sc_dir/mbp-node-dispatch.sh não existe'
mut check-limpo-avisa    $CHK_ '    timeout) warn "mbp-node: o check de' '    node|mini|unknown) warn "mbp-node: check limpo" ;;
    timeout) warn "mbp-node: o check de'
# ── _pilot_mbp_stamped_pre
mut pre-off-roda         $PRE_ 'case "$_sp_mode" in shadow|on) ;; *) _PMS_WHY="off"; return 1 ;; esac' 'case "$_sp_mode" in off|shadow|on) ;; *) _PMS_WHY="off"; return 1 ;; esac'
mut pre-stop-ignorada    $PRE_ '[ -z "${_PMS_STOP:-}" ] || { _PMS_WHY="stop:${_PMS_STOP}"; return 1; }' ':'
mut pre-sem-carimbo      $PRE_ '[ "$_sp_rt" = "wa-worker" ] || { _PMS_WHY="not-stamped"; return 1; }' ':'
mut pre-rota-prefixo     $PRE_ '[ "$_sp_rt" = "wa-worker" ] || { _PMS_WHY="not-stamped"; return 1; }' 'case "$_sp_rt" in wa-worker*) ;; *) _PMS_WHY="not-stamped"; return 1 ;; esac'
mut pre-com-dono         $PRE_ '[ -z "$_sp_as" ] || { _PMS_WHY="has-owner"; return 1; }' ':'
mut pre-id-qualquer      $PRE_ 'case "$_sp_id" in wa-*) ;; *) _PMS_WHY="not-wa"; return 1 ;; esac' ':'
mut pre-id-inseguro      $PRE_ 'case "$_sp_id" in *[!A-Za-z0-9._-]*) _PMS_WHY="unreadable"; return 1 ;; esac' ':'
mut pre-json-ruim-livre  $PRE_ "2>/dev/null) || { _PMS_WHY=\"unreadable\"; return 1; }" '2>/dev/null) || true'
mut pre-sem-veto         $PRE_ '[ -z "$_sp_veto" ] || { _PMS_WHY="veto:$_sp_veto"; return 1; }' ':'
mut pre-sem-node-mini    $PRE_ '*,node:mini,*) _PMS_WHY="node:mini"; return 1 ;;' '*,node:mini-x,*) _PMS_WHY="node:mini"; return 1 ;;'
mut pre-hetzner-nao      $PRE_ 'if [ "${_PWP_MODE:-off}" = on ]; then' 'if false; then'
mut pre-hetzner-sem-capacity $PRE_ 'capacity|keep-limit) ;; *) _PMS_WHY="hetzner-first"; return 1 ;; esac' 'keep-limit) ;; *) _PMS_WHY="hetzner-first"; return 1 ;; esac'
mut pre-hetzner-sem-keep $PRE_ 'capacity|keep-limit) ;; *) _PMS_WHY="hetzner-first"; return 1 ;; esac' 'capacity) ;; *) _PMS_WHY="hetzner-first"; return 1 ;; esac'
mut pre-hetzner-qualquer-parada $PRE_ 'capacity|keep-limit) ;; *) _PMS_WHY="hetzner-first"; return 1 ;; esac' '*) ;; esac'
mut pre-hetzner-auto-nao $PRE_ 'auto) _sp_h=1 ;;' 'auto) ;;'
mut pre-hetzner-label-todos $PRE_ 'label) case ",$_sp_labels," in *,node:ok,*) _sp_h=1 ;; esac ;;' 'label) _sp_h=1 ;;'
mut pre-sem-teto-levadas $PRE_ 'if [ "${_PMS_TAKEN:-0}" -ge "$_sp_max" ]; then' 'if false; then'
mut pre-teto-levadas-gt  $PRE_ 'if [ "${_PMS_TAKEN:-0}" -ge "$_sp_max" ]; then' 'if [ "${_PMS_TAKEN:-0}" -gt "$_sp_max" ]; then'
mut pre-sem-slow         $PRE_ 'if _pilot_slow_spawn_budget_spent; then' 'if false; then'
mut pre-sem-mini-cheio   $PRE_ '_pilot_mbp_mini_full || { _PMS_WHY="mini-not-full"; return 1; }' ':'
mut pre-sem-loja         $PRE_ '[ -n "$_sp_store" ] || { _PMS_WHY="store-unknown"; return 1; }' ':'
mut pre-sem-memoria      $PRE_ 'if _pilot_wa_node_pass_memo_hit "mbp:$_sp_id" "$_PMS_UPD" &&' 'if false &&'
mut pre-memoria-hetzner  $PRE_ 'if _pilot_wa_node_pass_memo_hit "mbp:$_sp_id" "$_PMS_UPD" &&' 'if _pilot_wa_node_pass_memo_hit "$_sp_id" "$_PMS_UPD" &&'
mut pre-memo-put-hetzner $PRE_ '_pilot_wa_node_pass_memo_put "mbp:$_sp_id" "$_PMS_UPD" "$_PMS_V"' '_pilot_wa_node_pass_memo_put "$_sp_id" "$_PMS_UPD" "$_PMS_V"'
mut pre-sem-recusa       $PRE_ '[ -z "$_sp_ref" ] || { _PMS_WHY="refused:$_sp_ref"; return 1; }' ':'
mut pre-recusa-ilegivel  $PRE_ 'if ! _sp_ref=$(_pilot_priority_refusal_of "$_sp_b"); then _PMS_WHY="refusal-unknown"; return 1; fi' ':'
mut pre-sem-oraculo      $PRE_ 'if ! _pilot_mbp_stamped_gate; then' 'if false; then'
mut pre-oraculo-nao-para $PRE_ '_PMS_STOP="gate"; _PMS_WHY="gate"; return 1;' '_PMS_WHY="gate"; return 1;'
mut pre-sem-teto-sondas  $PRE_ 'if [ "${_PMS_PROBES:-0}" -ge "$_sp_cap" ]; then' 'if false; then'
mut pre-sonda-nao-conta  $PRE_ '_PMS_PROBES=$(( ${_PMS_PROBES:-0} + 1 ))' ':'
mut pre-mini-passa       $PRE_ '    node) ;;
    # DRY_RUN' '    node|mini) ;;
    # DRY_RUN'
mut pre-erro-passa       $PRE_ '*) _PMS_WHY="check-$_PMS_V"; return 1 ;;' '*) ;;'
mut pre-missing-nao-para $PRE_ 'missing) _PMS_STOP="check-missing"; _PMS_WHY="check-missing"; return 1 ;;' 'missing) _PMS_WHY="check-missing"; return 1 ;;'
mut pre-shadow-devolve-0 $PRE_ '    _PMS_WHY="shadow"
    return 1' '    _PMS_WHY="shadow"
    return 0'
mut pre-dry-run-oferece  $PRE_ 'if [ "$_sp_mode" = shadow ] || [ "${DRY_RUN:-0}" = "1" ]; then' 'if [ "$_sp_mode" = shadow ]; then'
mut pre-linha-sem-modo   $PRE_ '"$([ "$_sp_mode" = shadow ] && echo shadow || echo on-dry-run)"' 'shadow'
mut pre-linha-sem-aviso  $PRE_ 'warn "mbp-node: linha-sombra de' ': "mbp-node: linha-sombra de'
mut pre-dolt-ignorado    $PRE_ 'if [ "${PILOT_DOLT_SATURATED_AT_START:-0}" = "1" ] || _dolt_saturated; then' 'if false; then'
mut pre-dolt-so-no-inicio $PRE_ '[ "${PILOT_DOLT_SATURATED_AT_START:-0}" = "1" ] || _dolt_saturated' '[ "${PILOT_DOLT_SATURATED_AT_START:-0}" = "1" ]'
mut pre-escreve          $PRE_ '  return 0
}
' '  bd -C "$_sp_store" update "$_sp_id" --unset-metadata gc.routed_to -q
  return 0
}
'
mut pre-dry-run-memoriza $PRE_ 'mini|unknown) [ "${DRY_RUN:-0}" = "1" ] || _pilot_wa_node_pass_memo_put' 'mini|unknown) _pilot_wa_node_pass_memo_put'
mut pre-sampled-vale-no-on $PRE_ ' && { [ "${_PWP_MEMO_V:-}" != sampled ] || [ "$_sp_mode" = shadow ]; }' ''
mut pre-sampled-nunca-vale $PRE_ '|| [ "$_sp_mode" = shadow ]; }' '|| false; }'
mut pre-shadow-sem-sampled $PRE_ 'then _pilot_wa_node_pass_memo_put "mbp:$_sp_id" "$_PMS_UPD" sampled; fi' 'then :; fi'
mut pre-sampled-no-dry-run $PRE_ 'if [ "$_sp_mode" = shadow ] && [ "${DRY_RUN:-0}" != "1" ]; then' 'if [ "$_sp_mode" = shadow ]; then'
mut pre-sampled-sem-linha $PRE_ '>> "$GC_CITY/.gc/mbp-node-route.jsonl"; } 2>/dev/null; then' '>> "$GC_CITY/.gc/mbp-node-route.jsonl"; } 2>/dev/null || true; then'
mut pre-seen-nao-conta   $PRE_ '_PMS_SEEN=$(( ${_PMS_SEEN:-0} + 1 ))' ':'
mut pre-seen-no-off      $PRE_ 'case "$_sp_mode" in shadow|on) ;; *) _PMS_WHY="off"; return 1 ;; esac
  _PMS_SEEN=$(( ${_PMS_SEEN:-0} + 1 ))' '_PMS_SEEN=$(( ${_PMS_SEEN:-0} + 1 ))
  case "$_sp_mode" in shadow|on) ;; *) _PMS_WHY="off"; return 1 ;; esac'
mut pre-oferecida-nao-conta $PRE_ '_PMS_OFFERED=$(( ${_PMS_OFFERED:-0} + 1 ))' ':'
mut pre-check-nao-lista  $PRE_ '_PMS_CHECKED="${_PMS_CHECKED:-} $_PMS_V"' ':'
# ── _pilot_mbp_stamped_after e o rc do apply
mut after-0-nao-conta    $AFT_ 'if [ "$_sa_rc" = 0 ]; then _PMS_TAKEN=$(( ${_PMS_TAKEN:-0} + 1 )); return 0; fi' 'if [ "$_sa_rc" = 0 ]; then return 0; fi'
mut after-10-sem-memo    $AFT_ '10) _PMS_FAILS=$(( ${_PMS_FAILS:-0} + 1 )); _sa_mv=mini ;;' '10) _PMS_FAILS=$(( ${_PMS_FAILS:-0} + 1 )) ;;'
mut after-vazio-sem-falha $AFT_ "'') _PMS_FAILS=\$(( \${_PMS_FAILS:-0} + 1 )); " "'') "
mut after-12-memoriza    $AFT_ '12) _PMS_STOP="capacity" ;;' '12) _PMS_STOP="capacity"; _sa_mv=mini ;;'
mut after-12-nao-para    $AFT_ '12) _PMS_STOP="capacity" ;;' '12) : ;;'
mut after-outro-nao-para $AFT_ '*)  _PMS_STOP="hook-held" ;;' '*)  : ;;'
mut after-hold-nao-para  $AFT_ 'if [ "${DISPATCH_RESULT:-}" = "wa_node_unknown" ]; then' 'if false; then'
mut after-sem-max-fails  $AFT_ 'if [ -z "${_PMS_STOP:-}" ] && [ "${_PMS_FAILS:-0}" -ge "$_sa_mf" ]; then' 'if false; then'
mut after-chave-capturada $AFT_ '"mbp:$_sa_id" "$_sa_cur" "$_sa_mv"' '"mbp:$_sa_id" "${_PMS_UPD:-}" "$_sa_mv"'
mut after-releitura-falha-memoriza $AFT_ 'if [ -n "$_sa_store" ] && _sa_cur=$(_pilot_mbp_stamped_upd_now "$_sa_id" "$_sa_store"); then' 'if [ -n "$_sa_store" ] && { _sa_cur=$(_pilot_mbp_stamped_upd_now "$_sa_id" "$_sa_store") || _sa_cur="${_PMS_UPD:-}"; }; then'
mut after-sem-aviso-releitura $AFT_ 'warn "mbp-node: não consegui ler o updated_at atual' ': "mbp-node: não consegui ler o updated_at atual'
mut after-le-sempre      $AFT_ 'if [ -n "$_sa_mv" ] && [ -n "${_PMS_UPD:-}" ]; then' 'if [ -n "${_PMS_UPD:-}" ]; then'
mut after-sem-upd-memoriza $AFT_ 'if [ -n "$_sa_mv" ] && [ -n "${_PMS_UPD:-}" ]; then' 'if [ -n "$_sa_mv" ]; then'
mut updnow-outro-id      $UPD_ 'select(type == "object" and .id == $id)' 'select(type == "object")'
mut updnow-vazio-ok      $UPD_ "case \"\$_un_u\" in ''|*[!0-9A-Za-z:.+_-]*) return 1 ;; esac" 'case "$_un_u" in *[!0-9A-Za-z:.+_-]*) return 1 ;; esac'
mut updnow-charset       $UPD_ "case \"\$_un_u\" in ''|*[!0-9A-Za-z:.+_-]*) return 1 ;; esac" "case \"\$_un_u\" in '') return 1 ;; esac"
mut updnow-array         $UPD_ 'if type == "array" then .[0] else . end |' ''
mut updnow-sem-id-loja   $UPD_ '{ [ -n "$_un_id" ] && [ -n "$_un_store" ]; } || return 1' ':'
# ── o resumo da varredura (skip · tally · summary) e a fiação em dispatch_lane e no fluxo principal
mut skip-vazio-buraco    $SKP_ '[ -n "$_ss_w" ] || _ss_w="?"' ':'
mut skip-espaco          $SKP_ '${_ss_w// /_}' '${_ss_w}'
mut skip-nao-grava       $SKP_ '_PMS_SKIPPED="${_PMS_SKIPPED:-} ${_ss_w// /_}"' ':'
mut tally-falha-vira-vazio $TAL_ "printf '%s' '{\"tally-unreadable\":1}'" "printf '%s' '{}'"
mut tally-conta-vazio    $TAL_ 'map(select(length > 0))' 'map(.)'
mut tally-sem-contar     $TAL_ 'map({key: .[0], value: length})' 'map({key: .[0], value: 1})'
mut sum-gate-sem-porque  $SUM_ 'no) _ss_gate="${_PMS_GATE_WHY:-no}" ;;' 'no) _ss_gate=no ;;'
mut sum-gate-ok-some     $SUM_ 'ok) _ss_gate=ok ;;' 'ok) ;;'
mut sum-log-sem-parada   $SUM_ 'parou: ${_ss_stop:-fim da lista}' 'parou: fim da lista'
mut sum-evento-sem-parada $SUM_ '--arg stopped "${_ss_stop:-none}"' '--arg stopped "none"'
mut sum-sem-log          $SUM_ '  log "ga-w7qwl1.2.6: passo da carimbada no MBP' '  : "ga-w7qwl1.2.6: passo da carimbada no MBP'
mut sum-nao-grava        $SUM_ '>> "$_ss_f"; }' '>> /dev/null; }'
mut sum-sem-aviso        $SUM_ 'warn "mbp-node: resumo do passo da carimbada NÃO gravado' ': "mbp-node: resumo do passo da carimbada NÃO gravado'
mut sum-evento-vazio-ok  $SUM_ 'if [ -z "$_ss_ev" ] || ! {' 'if ! {'
mut sum-dry-nao-marca    $SUM_ 'if [ "${DRY_RUN:-0}" = "1" ]; then _ss_dry=true;' 'if false; then _ss_dry=true;'
mut sum-dry-sem-texto    $SUM_ '_ss_mt="$_ss_mt dry-run"' ':'
mut sum-conta-node       $SUM_ 'node) _ss_cn=$(( _ss_cn + 1 )) ;;' 'node) ;;'
mut sum-conta-prazo-erro $SUM_ 'timeout) _ss_ct=$(( _ss_ct + 1 )) ;;' 'timeout) _ss_ce=$(( _ss_ce + 1 )) ;;'
mut sum-rc-1             $SUM_ '  return 0
}
' '  return 1
}
'
mut sum-ilegivel-nenhuma $SUM_ '[ -n "$_ss_skl" ] || _ss_skl="ilegível"' '[ -n "$_ss_skl" ] || _ss_skl="nenhuma"'
mut sum-sem-puladas      $SUM_ '--argjson skipped "$_ss_skt"' "--argjson skipped '{}'"
mut sum-sem-checks       $SUM_ '--argjson checks "$_ss_ckt"' "--argjson checks '{}'"
mut sum-candidatas-zero  $SUM_ 'candidatas=${_PMS_SEEN:-0}' 'candidatas=0'
mut apply-rc-nao-grava   $DEC_ 'if [ "$_dry" != 1 ]; then _PMN_APPLY_RC="$_rc"; fi' ':'
mut apply-rc-nao-zera    $DEC_ '  _PMN_APPLY_RC=""
  case "$_mode" in' '  case "$_mode" in'
mut apply-rc-dry-run     $DEC_ 'if [ "$_dry" != 1 ]; then _PMN_APPLY_RC="$_rc"; fi' '_PMN_APPLY_RC="$_rc"'
# ── dispatch_lane
mut lane-sem-chamada     - 'if [ "${PILOT_WA_MBP_ROUTE:-off}" != off ] && _pilot_mbp_stamped_pre "$pick"; then _mbp_pass=1; fi' ':'
mut lane-off-chama       - '[ "${PILOT_WA_MBP_ROUTE:-off}" != off ] && _pilot_mbp_stamped_pre "$pick"' '_pilot_mbp_stamped_pre "$pick"'
mut lane-yield-segura    - 'if [ "$_mbp_pass" != 1 ] && _pilot_priority_pool_bound_pre' 'if _pilot_priority_pool_bound_pre'
mut lane-teto-segura     - 'if [ "$_mbp_pass" != 1 ] && _pilot_pool_cap_full_for "$pick"; then' 'if _pilot_pool_cap_full_for "$pick"; then'
mut lane-contagem-para   - 'if [ "$_mbp_pass" != 1 ] && [ -n "${_PCAP_COUNT_UNREADABLE:-}" ]; then' 'if [ -n "${_PCAP_COUNT_UNREADABLE:-}" ]; then'
mut lane-bandeira-1      - '_PILOT_WA_MBP_PASS="$_mbp_pass"; _PMN_APPLY_RC=""' '_PILOT_WA_MBP_PASS=1; _PMN_APPLY_RC=""'
mut lane-apply-rc-vela   - '_PILOT_WA_MBP_PASS="$_mbp_pass"; _PMN_APPLY_RC=""' '_PILOT_WA_MBP_PASS="$_mbp_pass"'
mut lane-resultado-vela  - 'if [ "$_mbp_pass" = 1 ]; then DISPATCH_RESULT=""; fi' ':'
mut lane-bandeira-fica-ok - '      _PILOT_WA_MBP_PASS=0
      if [ "$_mbp_pass" = 1 ]; then _pilot_mbp_stamped_after "$pick_id" 0; fi' '      if [ "$_mbp_pass" = 1 ]; then _pilot_mbp_stamped_after "$pick_id" 0; fi'
mut lane-bandeira-fica-falha - '      _PILOT_WA_MBP_PASS=0
      if [ "$_mbp_pass" = 1 ]; then _pilot_mbp_stamped_after "$pick_id" 1; fi' '      if [ "$_mbp_pass" = 1 ]; then _pilot_mbp_stamped_after "$pick_id" 1; fi'
mut lane-sem-after-ok    - '_pilot_mbp_stamped_after "$pick_id" 0; fi' ':; fi'
mut lane-sem-after-falha - '_pilot_mbp_stamped_after "$pick_id" 1; fi' ':; fi'
mut lane-after-sempre    - 'if [ "$_mbp_pass" = 1 ]; then _pilot_mbp_stamped_after "$pick_id" 1; fi' '_pilot_mbp_stamped_after "$pick_id" 1'
mut lane-sem-skip        - 'if [ "$_mbp_pass" != 1 ] && [ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_skip; fi' ':'
mut lane-skip-off        - '[ "$_mbp_pass" != 1 ] && [ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_skip' '[ "$_mbp_pass" != 1 ]; then _pilot_mbp_stamped_skip'
mut lane-skip-oferecida  - '[ "$_mbp_pass" != 1 ] && [ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_skip' '[ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_skip'
# ── o fluxo principal: o resumo sai com o passo ligado, antes do evento agregado
mut main-resumo-sempre   - 'if [ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_summary; fi' 'if true; then _pilot_mbp_stamped_summary; fi'
mut main-resumo-so-on    - '!= off ]; then _pilot_mbp_stamped_summary; fi' '= on ]; then _pilot_mbp_stamped_summary; fi'
mut main-resumo-sem-chamada - 'then _pilot_mbp_stamped_summary; fi' 'then :; fi'
mut main-resumo-depois   - 'if [ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_summary; fi

# ga-ov3gow: the sweep'\''s ONE aggregate `pilot_sweep` line (schema: the block above dispatch_lane). After
# _pool_saturated_sweep exists — it is a field — and before Step 5, so a Step 5 failure cannot cost the event.
_pilot_sweep_emit
' '# ga-ov3gow: the sweep'\''s ONE aggregate `pilot_sweep` line (schema: the block above dispatch_lane). After
# _pool_saturated_sweep exists — it is a field — and before Step 5, so a Step 5 failure cannot cost the event.
_pilot_sweep_emit
if [ "${PILOT_WA_MBP_ROUTE:-off}" != off ]; then _pilot_mbp_stamped_summary; fi
'
# ── dispatch_one
mut um-yield-contornado-nao - '  elif [ "${_PILOT_WA_MBP_PASS:-0}" = "1" ]; then
    # ga-w7qwl1.2.6: a carimbada que dispatch_lane entregou ao MBP' '  elif false; then
    # ga-w7qwl1.2.6: a carimbada que dispatch_lane entregou ao MBP'
mut um-yield-qualquer-alvo - 'if [ "$_PYS_NATIVE" = "1" ] && [ "$_PYS_TARGET" = "wa-worker" ]; then
      log "  ga-w7qwl1.2.6:' 'if true; then
      log "  ga-w7qwl1.2.6:'
mut um-sem-adocao        - 'if [ "${_PILOT_WA_MBP_PASS:-0}" = "1" ] && ! _pilot_wa_node_adopt' 'if false && ! _pilot_wa_node_adopt'
mut um-adocao-falha-segue - 'DISPATCH_RESULT="rig_native_pool_session_cap_queued"
            return 1
          fi
          _pilot_mbp_node_decide' 'DISPATCH_RESULT="rig_native_pool_session_cap_queued"
          fi
          _pilot_mbp_node_decide'
mut um-adocao-sem-solta  - 'não consegui deixá-la sem rota para o apply do MBP (ou ela já não está livre); NÃO vai ao mini: claim solta, reavaliada na próxima varredura."
            _pilot_release_pool_cap_queued "$STORY_ID" "$STORY_BEAD_CITY" "$BUILDER_TARGET"' 'não consegui deixá-la sem rota para o apply do MBP (ou ela já não está livre); NÃO vai ao mini: claim solta, reavaliada na próxima varredura."
            :'
mut um-rc0-sem-unmark    - 'if [ "${_PILOT_WA_MBP_PASS:-0}" = "1" ]; then unmark_pool_builder "$BUILDER_TARGET"; fi' ':'
mut um-rc1-sem-devolver  - '            _pilot_wa_node_unadopt "$STORY_ID" "$STORY_BEAD_CITY"
            log "  ga-w7qwl1.2.6: $STORY_ID — o MBP não ficou' '            :
            log "  ga-w7qwl1.2.6: $STORY_ID — o MBP não ficou'
mut um-rc1-sem-solta     - 'sem mini (apply rc=${_PMN_APPLY_RC:-n/d})."
            _pilot_release_pool_cap_queued "$STORY_ID" "$STORY_BEAD_CITY" "$BUILDER_TARGET"' 'sem mini (apply rc=${_PMN_APPLY_RC:-n/d})."
            :'
mut um-rc1-cai-no-mini   - 'elif [ "${_PILOT_WA_MBP_PASS:-0}" = "1" ]; then
            # ga-w7qwl1.2.6: rc 1 = o MBP' 'elif false; then
            # ga-w7qwl1.2.6: rc 1 = o MBP'
mut um-rc2-devolve       - 'elif [ "$_RP_MBP_RC" = 2 ]; then
            bd -C "$STORY_BEAD_CITY" label remove' 'elif [ "$_RP_MBP_RC" = 2 ]; then
            _pilot_wa_node_unadopt "$STORY_ID" "$STORY_BEAD_CITY"
            bd -C "$STORY_BEAD_CITY" label remove'
# ── a passada de WA no nó deixa o motivo da parada
mut parada-nao-zera      - '  _PWP_LAST_STOP=""
' ''
mut parada-nao-grava     - '  _PWP_LAST_STOP="${_pw_stop:-}"' '  :'
echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
[ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
