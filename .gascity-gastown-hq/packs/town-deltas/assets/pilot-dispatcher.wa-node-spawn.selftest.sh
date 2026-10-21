#!/usr/bin/env bash
# pilot-dispatcher.wa-node-spawn.selftest.sh — testes do MODO PILOT do gancho de WA no nó (ga-2hd02v.3).
#
# O gancho _pilot_wa_node_decide (ga-2hd02v.1.10) tem dois modos de abrir a sessão do wa-worker-remote:
#   pool   (padrão, PILOT_WA_NODE_SPAWN ausente) — o da 1.10 byte a byte: o pool abre a sessão, 1 slot. Provado em pilot-dispatcher.wa-node-route.selftest.sh.
#   pilot  (PILOT_WA_NODE_SPAWN=pilot) — o gancho abre (ou acorda) a sessão do alias wa-worker-remote-<k> que o wa-node-dispatch.sh escolheu, e o N de slots vem
#          de PILOT_WA_NODE_SLOTS (1..9). É a receita que o dog-remote já provou (_pilot_node_first_dispatch). ESTE arquivo prova esse modo.
#
# O que este arquivo prova (as funções são as REAIS, extraídas palavra por palavra do pilot-dispatcher.sh; bd, gc e wa-node-dispatch.sh são falsos, o bd com estado):
#   A. a leitura do modo (_pilot_wa_node_spawn_mode): só "pilot" exato liga; SLOTS é UM dígito de 1 a 9; qualquer outra coisa é o estado inerte (pool, 1 slot).
#   B. _pilot_node_remote_open (genérica por template/alias/chave, a bead de PS pelo nó usa a mesma): sessão nova · sessão dormindo vira wake · alias ocupado, de outro template, lista
#      ilegível = não abre · estados mortos (closed, stopped, archived, drained) não seguram o alias · nudge · qualquer falha desfaz (fecha a sessão SÓ se tocou nela, solta a bead com
#      --if-assignee, confirma lendo) · desfazer não confirmado = 2 (segura) · prazo estourado gasta o orçamento de spawn do sweep.
#   C. _pilot_wa_node_open: só abre para a cara exata do que o apply escreve (dono wa-worker-remote-1..9, marca igual ao dono, in_progress); qualquer outra coisa = 2 sem escrever; o título entra
#      na dica da sessão sem CR, LF e "|".
#   D. o decide inteiro em modo pilot: env passado ao script (dry-run e real), a ordem das chamadas, o orçamento de spawn (só no modo pilot, só na escrita real), dry-run, shadow, off.
#   E. _pilot_wa_node_settle: rc incerto do apply (13, prazo, sinal) → desfaz SÓ o que tem a cara do apply (sem sessão), nunca pisa em bead de outro, e o decide devolve 2 de qualquer jeito.
#   F. a fiação (grep no fonte) e as peças genéricas.
#   G0. o mutador recusa (rc ≠ 0, destino não escrito) origem ausente, origem sem o trecho e nome que não existe.
#   G. mutantes: cada quebra tem de derrubar este selftest. Cada um roda o arquivo inteiro e para no 1º FAIL; rodam em paralelo (WA_NODE_SPAWN_ST_JOBS, padrão 4).
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.wa-node-spawn.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK". Bash 3.2 (macOS) basta.

set -uo pipefail

# --jobs N: quantos mutantes rodam juntos (o mbp-run.sh repassa argumentos, não ambiente; no nó de 16 núcleos: --jobs 12). Padrão 4.
if [ "${1:-}" = "--jobs" ]; then WA_NODE_SPAWN_ST_JOBS="${2:-4}"; fi
case "${WA_NODE_SPAWN_ST_JOBS:-4}" in [1-9]|[1-9][0-9]) ;; *) echo "FATAL: --jobs quer um número de 1 a 99 (veio '${WA_NODE_SPAWN_ST_JOBS}')" >&2; exit 2 ;; esac

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${WA_NODE_SPAWN_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
# Rodando como mutante (WA_NODE_SPAWN_SELFTEST_FILE) o primeiro FAIL já diz "morto": sai na hora.
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); [ -z "${WA_NODE_SPAWN_SELFTEST_FILE:-}" ] || exit 1; }
eq() { # eq <descrição> <obtido> <esperado>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — obtido '$2', esperado '$3'"; fi
}

[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
FNS=""
for _f in _pilot_wa_node_decide _pilot_wa_node_spawn_mode _pilot_wa_node_read _pilot_wa_node_open _pilot_wa_node_settle _pilot_node_remote_open _pilot_node_remote_rollback _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing gc_json_or_unknown; do
  _b="$(fn_of "$_f")"
  [ -n "$_b" ] || { echo "FATAL: $_f() não está em $DISPATCHER" >&2; exit 2; }
  FNS="$FNS"$'\n'"$_b"
done

T="$(mktemp -d "${TMPDIR:-/tmp}/wa-node-spawn.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/city" "$T/bin"
export FAKE_STATE="$T/state.json" FAKE_LOG="$T/calls" FAKE_BD_LOG="$T/bdcalls" FAKE_GC_LOG="$T/gccalls" FAKE_ORDER="$T/order" FAKE_NSHOW="$T/nshow" T_SLOW="$T/slow"

# wa-node-dispatch.sh falso: anota os argumentos e o ambiente que recebeu (WA_NODE_SPAWN/WA_NODE_SLOTS), e — no apply de verdade — "escreve": copia FAKE_BEAD2 para o estado.
# FAKE_APPLY_WRITES: 1 escreve, 0 não (padrão: escreve só se o rc for 0).
cat > "$T/scripts/wa-node-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s | SPAWN=%s SLOTS=%s\n' "$*" "${WA_NODE_SPAWN-unset}" "${WA_NODE_SLOTS-unset}" >> "$FAKE_LOG"
echo "script:${1:-}" >> "$FAKE_ORDER"
if [ "${1:-}" = apply ]; then
  dry=0; for a in "$@"; do [ "$a" = --dry-run ] && dry=1; done
  w="${FAKE_APPLY_WRITES:-}"
  if [ -z "$w" ]; then if [ "${FAKE_RC:-0}" = 0 ]; then w=1; else w=0; fi; fi
  if [ "$dry" = 0 ] && [ "$w" = 1 ]; then cp "$FAKE_BEAD2" "$FAKE_STATE"; fi
fi
echo "${FAKE_OUT:-fake}"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/scripts/wa-node-dispatch.sh"

# bd falso COM ESTADO: entende `bd -C <loja> show <id> --json` e `bd -C <loja> update <id> [--if-assignee X] [--assignee Y] [--status S] [--unset-metadata K] -q`.
# Anota cada chamada (argumentos separados por "|"). Knobs: FAKE_BD_SHOW_FAIL_FROM=N (o N-ésimo show e os seguintes falham), FAKE_BD_UPDATE_RC (o update falha com esse rc),
# FAKE_BD_UPDATE_MODE=noop (sai 0 e não muda nada) | partial (só solta o dono) | keepstatus (solta dono e marca, o status fica) | keepmark (solta dono e status, a marca fica).
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
    printf '['; cat "$FAKE_STATE"; printf ']\n'
    exit 0 ;;
  update)
    [ "${FAKE_BD_UPDATE_RC:-0}" = 0 ] || exit "${FAKE_BD_UPDATE_RC}"
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
    if [ "${FAKE_BD_UPDATE_MODE:-}" != partial ]; then
      [ -n "$st" ] && [ "${FAKE_BD_UPDATE_MODE:-}" != keepstatus ] && f="$f | .status = \$s"
      [ -n "$um" ] && [ "${FAKE_BD_UPDATE_MODE:-}" != keepmark ] && f="$f | del(.metadata[\$m])"
    fi
    jq --arg a "$asg" --arg s "$st" --arg m "$um" "$f" "$FAKE_STATE" > "$FAKE_STATE.new" && mv "$FAKE_STATE.new" "$FAKE_STATE"
    exit 0 ;;
esac
exit 64
EOF
chmod +x "$T/bin/bd"

# gc falso: `gc --city C session list --json` devolve $FAKE_SESSIONS; new/wake/close/nudge devolvem o rc do knob. Anota cada chamada (argumentos separados por "|").
cat > "$T/bin/gc" <<'EOF'
#!/usr/bin/env bash
j=""; for x in "$@"; do j="$j|$x"; done
printf '%s\n' "$j" >> "$FAKE_GC_LOG"
[ "${1:-}" = --city ] && [ "${3:-}" = session ] || exit 64
verb="${4:-}"
echo "gc:$verb" >> "$FAKE_ORDER"
case "$verb" in
  list) rc="${FAKE_GC_LIST_RC:-0}"; [ "$rc" = 0 ] || exit "$rc"; cat "$FAKE_SESSIONS"; exit 0 ;;
  new) exit "${FAKE_GC_NEW_RC:-0}" ;;
  wake) exit "${FAKE_GC_WAKE_RC:-0}" ;;
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

# mkb <arquivo> <status> <dono> <marca> [título] [id] [chave da marca] — a bead falsa, no formato de `bd show` (o bd omite dono e marca vazios)
mkb() {
  jq -n --arg id "${6:-$ID}" --arg s "$2" --arg a "$3" --arg m "$4" --arg t "${5-Título X}" --arg k "${7:-pilot.wa_node_alias}" \
    '{id:$id,status:$s,title:$t,metadata:(if $m=="" then {} else {($k):$m} end)} + (if $a=="" then {} else {assignee:$a} end)' > "$1"
}
mkb "$T/b.free.json" open "" ""
k=1; while [ "$k" -le 9 ]; do mkb "$T/b.ap$k.json" in_progress "wa-worker-remote-$k" "wa-worker-remote-$k"; k=$((k+1)); done
mkb "$T/b.foreign.json" in_progress mila-wa ""
sj() { printf '{"sessions":%s}' "$2" > "$1"; }   # sj <arquivo> <array json>
sj "$T/s.empty.json" '[]'

reset() {
  : > "$T/calls"; : > "$T/bdcalls"; : > "$T/gccalls"; : > "$T/err"; : > "$T/order"
  echo 0 > "$T/nshow"; echo 0 > "$T/slow"
  rm -f "$T/city/.gc/wa-node-route.jsonl"
  cp "$T/b.free.json" "$T/state.json"
  unset FAKE_BD_UPDATE_MODE FAKE_BD_UPDATE_RC FAKE_BD_SHOW_FAIL_FROM FAKE_GC_LIST_RC FAKE_GC_NEW_RC FAKE_GC_WAKE_RC FAKE_GC_CLOSE_RC FAKE_GC_NUDGE_RC \
        FAKE_APPLY_WRITES FAKE_RC FAKE_OUT PRE_SLOW PWN_SPAWN PILOT_WA_NODE_SPAWN PILOT_WA_NODE_SLOTS PILOT_WA_NODE_ROUTE DRY_RUN PILOT_SLOW_SPAWN_SECS
  export FAKE_SESSIONS="$T/s.empty.json" FAKE_BEAD2="$T/b.ap2.json"
}
pilot() { export PILOT_WA_NODE_SPAWN=pilot PILOT_WA_NODE_SLOTS="${1:-3}"; }

# H <função> <args…> — roda a função REAL (extraída) num shell novo, com os falsos no PATH; imprime só "rc=N". O que ficou em _PILOT_SLOW_SPAWN_SEEN vai para $T_SLOW.
H() {
  GC_CITY="$T/city" PILOT_WA_NODE_SCRIPTS="$T/scripts" \
    bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_PILOT_SLOW_SPAWN_SEEN="${PRE_SLOW:-0}"; _PWN_SPAWN="${PWN_SPAWN:-pool}"; _PWN_SLOTS=1
"$@"; _hrc=$?; echo "$_PILOT_SLOW_SPAWN_SEEN" > "$T_SLOW"; echo "rc=$_hrc"' _ "$@" 2>>"$T/err" | tail -1
}
D() { # D <modo> <rc do script> [dry] — o decide inteiro, alvo wa-worker
  export PILOT_WA_NODE_ROUTE="$1" FAKE_RC="${2:-0}" DRY_RUN="${3:-0}"
  H _pilot_wa_node_decide "$ID" "$ST" wa-worker
}
O() { H _pilot_node_remote_open wa-worker-remote "$1" "$ID" "$ST" "${2-Título X}" pilot.wa_node_alias; }   # O <alias> [título]
W() { H _pilot_wa_node_open "$ID" "$ST"; }

ord()   { tr '\n' ' ' < "$T/order"; }   # cada chamada + 1 espaço (inclusive a última): quem junta com outra coisa não põe espaço
nupd()  { grep -c '|update|' "$T/bdcalls" || true; }
nshow() { grep -c '|show|' "$T/bdcalls" || true; }
stt()   { jq -r '[.status, (.assignee // "-"), (.metadata["pilot.wa_node_alias"] // "-")] | join(",")' "$T/state.json"; }
slow()  { cat "$T/slow"; }
GL()    { printf '|--city|%s|%s' "$T/city" "$1"; }
UPD()   { printf '|-C|%s|update|%s|--if-assignee|%s|--assignee||--status|open|--unset-metadata|%s|-q' "$ST" "$ID" "$1" "${2:-pilot.wa_node_alias}"; }
hasgc() { grep -qxF -- "$(GL "$1")" "$T/gccalls"; }
hasbd() { grep -qxF -- "$1" "$T/bdcalls"; }
FREE="open,-,-"
AP2="in_progress,wa-worker-remote-2,wa-worker-remote-2"

echo "pilot-dispatcher.wa-node-spawn.selftest — ga-2hd02v.3"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "=== A. o modo (PILOT_WA_NODE_SPAWN / PILOT_WA_NODE_SLOTS) ==="
P() { # P <SPAWN|-> <SLOTS|-> → "spawn slots" (- = variável ausente)
  ( if [ "$1" = "-" ]; then unset PILOT_WA_NODE_SPAWN; else export PILOT_WA_NODE_SPAWN="$1"; fi
    if [ "$2" = "-" ]; then unset PILOT_WA_NODE_SLOTS; else export PILOT_WA_NODE_SLOTS="$2"; fi
    bash -c "$PRELUDE"$'\n'"$FNS"$'\n''_pilot_wa_node_spawn_mode; echo "$_PWN_SPAWN $_PWN_SLOTS"' )
}
eq "SPAWN ausente: pool, 1 slot (o desenho da 1.10)" "$(P - -)" "pool 1"
eq "SPAWN ausente e SLOTS=5: continua pool, 1 slot (o N sozinho não liga nada)" "$(P - 5)" "pool 1"
for v in pool Pilot PILOT " pilot" "pilot " on 1 true yes ""; do
  eq "SPAWN='$v' não é exatamente 'pilot': pool, 1 slot (mesmo com SLOTS=4)" "$(P "$v" 4)" "pool 1"
done
eq "pilot sem SLOTS: 1 slot" "$(P pilot -)" "pilot 1"
for n in 1 2 3 4 5 6 7 8 9; do eq "pilot, SLOTS=$n" "$(P pilot $n)" "pilot $n"; done
for v in 0 10 12 99 "3 " " 3" -1 2.5 abc "" "1;2" 01 "1 2"; do
  eq "pilot, SLOTS='$v' não é UM dígito de 1 a 9: 1 slot (erro de digitação nunca vira mais sessões)" "$(P pilot "$v")" "pilot 1"
done

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "=== B. _pilot_node_remote_open (genérica) ==="

# --- sessão nova ---
reset; cp "$T/b.ap2.json" "$T/state.json"
r=$(O wa-worker-remote-2)
eq "alias livre: devolve 0" "$r" "rc=0"
eq "alias livre: lê as sessões, abre e avisa — nessa ordem, e não mexe na bead" "$(ord)" "gc:list gc:new gc:nudge "
hasgc 'session|list|--json' && ok "lê as sessões com 'session list --json'" || fail "list: $(cat "$T/gccalls")"
hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-2|--no-attach|--title-hint|build wa-abc12: Título X' && ok "abre 'session new wa-worker-remote --alias wa-worker-remote-2 --no-attach --title-hint …' (o template e o alias vêm dos argumentos)" || fail "new: $(cat "$T/gccalls")"
grep -qF -- "|--city|$T/city|session|nudge|wa-worker-remote-2|Bead nova para você: $ID — Título X. Ela já está atribuída ao seu alias (GC_ALIAS=wa-worker-remote-2): ache com " "$T/gccalls" \
  && grep -qF -- '--assignee "$GC_ALIAS" --json --limit 5' "$T/gccalls" && ok "o aviso diz a bead, o título, o alias e como achá-la por GC_ALIAS" || fail "nudge: $(cat "$T/gccalls")"
eq "sessão aberta sem escrever na bead: o estado segue o do apply" "$(stt)" "$AP2"
eq "sessão rápida não gasta o orçamento de spawn" "$(slow)" "0"

# --- sessão dormindo vira wake ---
reset; cp "$T/b.ap2.json" "$T/state.json"
sj "$T/s.asleep.json" '[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"asleep","closed":false}]'; export FAKE_SESSIONS="$T/s.asleep.json"
r=$(O wa-worker-remote-2)
eq "sessão do alias dormindo: devolve 0" "$r" "rc=0"
eq "dormindo: ACORDA (wake) e avisa; nada de session new" "$(ord)" "gc:list gc:wake gc:nudge "
hasgc 'session|wake|wa-worker-remote-2' && ok "o wake leva o alias" || fail "wake: $(cat "$T/gccalls")"
reset; cp "$T/b.ap2.json" "$T/state.json"
sj "$T/s.asleep2.json" '[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"asleep"},{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"asleep","closed":false}]'; export FAKE_SESSIONS="$T/s.asleep2.json"
r=$(O wa-worker-remote-2); eq "duas sessões do alias, as duas dormindo: wake" "$(ord)" "gc:list gc:wake gc:nudge "

# --- outros alias não importam; mortas não seguram o alias ---
reset; cp "$T/b.ap2.json" "$T/state.json"
sj "$T/s.outros.json" '[null,"x",{"alias":"wa-worker-remote-1","template":"wa-worker-remote","state":"active"},{"alias":"dog-remote-2","template":"dog-remote","state":"active"},{"alias":"","template":"x","state":"active"}]'; export FAKE_SESSIONS="$T/s.outros.json"
r=$(O wa-worker-remote-2)
eq "sessões vivas de OUTROS alias (e itens que não são objeto) não seguram o alias: abre" "$r $(ord)" "rc=0 gc:list gc:new gc:nudge "
reset; cp "$T/b.ap2.json" "$T/state.json"
sj "$T/s.closed.json" '[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"active","closed":true}]'; export FAKE_SESSIONS="$T/s.closed.json"
r=$(O wa-worker-remote-2); eq "sessão com closed:true não segura o alias: abre uma nova" "$r $(ord)" "rc=0 gc:list gc:new gc:nudge "
for stt_ in closed stopped archived drained; do
  reset; cp "$T/b.ap2.json" "$T/state.json"
  sj "$T/s.dead.json" "[{\"alias\":\"wa-worker-remote-2\",\"template\":\"wa-worker-remote\",\"state\":\"$stt_\"}]"; export FAKE_SESSIONS="$T/s.dead.json"
  r=$(O wa-worker-remote-2); eq "sessão em estado '$stt_' não segura o alias (o script concorda): abre uma nova" "$r $(ord)" "rc=0 gc:list gc:new gc:nudge "
done

# --- alias ocupado: não abre, desfaz sem fechar sessão alheia ---
for spec in \
  'active|[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"active"}]' \
  'creating|[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"creating"}]' \
  'misto|[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"asleep"},{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"active"}]' \
  'outro-template-dormindo|[{"alias":"wa-worker-remote-2","template":"dog-remote","state":"asleep"}]' \
  'outro-template-ativo|[{"alias":"wa-worker-remote-2","template":"dog-remote","state":"active"}]' \
  'sem-estado|[{"alias":"wa-worker-remote-2","template":"wa-worker-remote"}]'; do
  nm="${spec%%|*}"; arr="${spec#*|}"
  reset; cp "$T/b.ap2.json" "$T/state.json"; sj "$T/s.busy.json" "$arr"; export FAKE_SESSIONS="$T/s.busy.json"
  r=$(O wa-worker-remote-2)
  eq "alias ocupado ($nm): não abre nem acorda nem fecha nada, e desfaz a escrita — devolve 1" "$r $(ord)" "rc=1 gc:list bd:update bd:show "
  eq "alias ocupado ($nm): a bead volta livre e open" "$(stt)" "$FREE"
  grep -q 'alias já tem uma sessão viva' "$T/err" && ok "alias ocupado ($nm): o aviso diz por quê" || fail "alias ocupado ($nm): aviso: $(cat "$T/err")"
done
reset; cp "$T/b.ap2.json" "$T/state.json"; sj "$T/s.busy.json" '[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"active"}]'; export FAKE_SESSIONS="$T/s.busy.json"
r=$(O wa-worker-remote-2); hasbd "$(UPD wa-worker-remote-2)" && ok "o desfazer é UMA escrita guardada: --if-assignee <alias> --assignee '' --status open --unset-metadata <chave> -q" || fail "update: $(cat "$T/bdcalls")"

# --- lista de sessões ilegível: não abre ---
for spec in 'rc1|' 'objeto-vazio|{}' 'sessions-texto|{"sessions":"x"}' 'sessions-objeto|{"sessions":{}}' 'lixo|isto não é json' 'vazio|' 'ok-false|{"ok":false,"sessions":[]}' 'nulo|null'; do
  nm="${spec%%|*}"; body="${spec#*|}"
  reset; cp "$T/b.ap2.json" "$T/state.json"; printf '%s' "$body" > "$T/s.bad.json"; export FAKE_SESSIONS="$T/s.bad.json"
  [ "$nm" = rc1 ] && export FAKE_GC_LIST_RC=1
  r=$(O wa-worker-remote-2)
  eq "lista ilegível ($nm): não abre, desfaz e devolve 1" "$r $(ord)$(stt)" "rc=1 gc:list bd:update bd:show $FREE"
  grep -q 'não consegui ler a lista de sessões' "$T/err" && ok "lista ilegível ($nm): o aviso diz que foi a lista" || fail "lista ($nm): aviso: $(cat "$T/err")"
done
reset; cp "$T/b.ap2.json" "$T/state.json"; sj "$T/s.x.json" '[null,"x"]'; export FAKE_SESSIONS="$T/s.x.json"
r=$(O wa-worker-remote-2); eq "itens que não são objeto na lista: abre (o jq não pode quebrar neles)" "$r" "rc=0"

# --- falha ao abrir / acordar / avisar: desfaz, fecha a sessão (tocou nela) e confirma ---
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1
r=$(O wa-worker-remote-2)
eq "session new falhou: fecha a sessão (pode ter nascido), solta a bead, confirma — devolve 1" "$r $(ord)$(stt)" "rc=1 gc:list gc:new gc:close bd:update bd:show $FREE"
hasgc 'session|close|wa-worker-remote-2' && ok "o close leva o alias" || fail "close: $(cat "$T/gccalls")"
hasbd "$(UPD wa-worker-remote-2)" && ok "e a bead é solta com a escrita guardada" || fail "update: $(cat "$T/bdcalls")"
grep -q 'não abriu (rc=1)' "$T/err" && ok "o aviso diz o rc" || fail "aviso: $(cat "$T/err")"
eq "falha rápida (rc 1) não gasta o orçamento de spawn" "$(slow)" "0"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=124
r=$(O wa-worker-remote-2)
eq "session new estourou o prazo (124): desfaz e devolve 1" "$r $(stt)" "rc=1 $FREE"
eq "o prazo estourado GASTA o orçamento de spawn do sweep (a flag chega ao shell de quem chama)" "$(slow)" "1"
grep -q 'estourou o prazo: ela pode ter nascido' "$T/err" && ok "o aviso diz que a sessão pode ter nascido" || fail "aviso 124: $(cat "$T/err")"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_SESSIONS="$T/s.asleep.json" FAKE_GC_WAKE_RC=1
r=$(O wa-worker-remote-2)
eq "wake falhou: fecha, solta, confirma — devolve 1" "$r $(ord)$(stt)" "rc=1 gc:list gc:wake gc:close bd:update bd:show $FREE"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_SESSIONS="$T/s.asleep.json" FAKE_GC_WAKE_RC=124
r=$(O wa-worker-remote-2); eq "wake estourou o prazo: gasta o orçamento" "$r $(slow)" "rc=1 1"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NUDGE_RC=1
r=$(O wa-worker-remote-2)
eq "o aviso (nudge) falhou: a sessão abriu mas ninguém avisou — fecha, solta, confirma, devolve 1" "$r $(ord)$(stt)" "rc=1 gc:list gc:new gc:nudge gc:close bd:update bd:show $FREE"
grep -q 'o aviso falhou (rc=1)' "$T/err" && ok "o aviso diz que foi o nudge" || fail "aviso nudge: $(cat "$T/err")"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NUDGE_RC=124
r=$(O wa-worker-remote-2); eq "nudge com rc 124: desfaz do mesmo jeito (o nudge não é o spawn lento)" "$r $(stt)" "rc=1 $FREE"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_GC_CLOSE_RC=1
r=$(O wa-worker-remote-2)
eq "o close também falha: avisa alto e solta a bead mesmo assim — devolve 1" "$r $(stt)" "rc=1 $FREE"
grep -q 'não consegui fechar a sessão wa-worker-remote-2' "$T/err" && ok "o aviso do close que falhou existe" || fail "aviso close: $(cat "$T/err")"

# --- desfazer que não se confirma = 2 (segura) ---
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=noop
r=$(O wa-worker-remote-2); eq "o update sai 0 e não muda nada (a bead segue do alias): devolve 2" "$r $(stt)" "rc=2 $AP2"
grep -q 'não se confirmou' "$T/err" && ok "o aviso diz que o desfazer não se confirmou" || fail "aviso: $(cat "$T/err")"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=partial
r=$(O wa-worker-remote-2); eq "o update só soltou o dono (status e marca ficaram): devolve 2" "$r $(stt)" "rc=2 in_progress,-,wa-worker-remote-2"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=keepstatus
r=$(O wa-worker-remote-2); eq "dono e marca soltos mas o status ficou in_progress (bead presa fora da fila): devolve 2" "$r $(stt)" "rc=2 in_progress,-,-"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=keepmark
r=$(O wa-worker-remote-2); eq "dono e status soltos mas a marca ficou (o slot seguiria contado): devolve 2" "$r $(stt)" "rc=2 open,-,wa-worker-remote-2"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_RC=1
r=$(O wa-worker-remote-2); eq "o update falha: devolve 2" "$r $(stt)" "rc=2 $AP2"
reset; cp "$T/b.ap2.json" "$T/state.json"; export FAKE_GC_NEW_RC=1 FAKE_BD_SHOW_FAIL_FROM=1
r=$(O wa-worker-remote-2); eq "a releitura de confirmação falha: NÃO é 'livre' — devolve 2" "$r" "rc=2"
grep -q 'não consegui ler' "$T/err" && ok "o aviso diz que não conseguiu ler" || fail "aviso leitura: $(cat "$T/err")"
reset; cp "$T/b.foreign.json" "$T/state.json"; export FAKE_GC_NEW_RC=1
r=$(O wa-worker-remote-2); eq "a bead passou a ser de OUTRO dono: o update guardado não a pisa e devolve 2" "$r $(stt)" "rc=2 in_progress,mila-wa,-"
reset; mkb "$T/b.other-id.json" in_progress wa-worker-remote-2 wa-worker-remote-2 "Título X" wa-zzzzz; cp "$T/b.other-id.json" "$T/state.json"; export FAKE_GC_NEW_RC=1
r=$(O wa-worker-remote-2); eq "a releitura de confirmação devolve a bead de OUTRO id: não confirma, devolve 2" "$r" "rc=2"

# --- genérica de verdade: a bead de PS pelo nó usa as mesmas peças (outro template, outro alias, outra chave) ---
reset; mkb "$T/b.ps.json" in_progress ps-worker-remote-1 ps-worker-remote-1 "Titulo PS" "$ID" pilot.ps_node_alias; cp "$T/b.ps.json" "$T/state.json"
H _pilot_node_remote_open ps-worker-remote ps-worker-remote-1 "$ID" "$ST" "Titulo PS" pilot.ps_node_alias > "$T/r"; r=$(cat "$T/r")
hasgc 'session|new|ps-worker-remote|--alias|ps-worker-remote-1|--no-attach|--title-hint|build wa-abc12: Titulo PS' && eq "outro template e alias: session new ps-worker-remote --alias ps-worker-remote-1" "$r" "rc=0" || fail "ps new: $(cat "$T/gccalls") / $r"
reset; mkb "$T/b.ps.json" in_progress ps-worker-remote-1 ps-worker-remote-1 "Titulo PS" "$ID" pilot.ps_node_alias; cp "$T/b.ps.json" "$T/state.json"; export FAKE_GC_NEW_RC=1
H _pilot_node_remote_open ps-worker-remote ps-worker-remote-1 "$ID" "$ST" "Titulo PS" pilot.ps_node_alias > "$T/r"; r=$(cat "$T/r")
hasbd "$(UPD ps-worker-remote-1 pilot.ps_node_alias)" && eq "o desfazer solta a CHAVE que veio por argumento (pilot.ps_node_alias) e confirma por ela" "$r $(jq -r '[.status, (.assignee // "-"), (.metadata["pilot.ps_node_alias"] // "-")] | join(",")' "$T/state.json")" "rc=1 open,-,-" || fail "ps rollback: $(cat "$T/bdcalls") / $r"
reset; mkb "$T/b.ps.json" in_progress ps-worker-remote-1 ps-worker-remote-1 "Titulo PS" "$ID" pilot.ps_node_alias; cp "$T/b.ps.json" "$T/state.json"
sj "$T/s.ps.json" '[{"alias":"ps-worker-remote-1","template":"ps-worker-remote","state":"asleep"}]'; export FAKE_SESSIONS="$T/s.ps.json"
H _pilot_node_remote_open ps-worker-remote ps-worker-remote-1 "$ID" "$ST" "Titulo PS" pilot.ps_node_alias > "$T/r"; r=$(cat "$T/r")
eq "outro template dormindo: acorda o alias dele" "$r $(ord)" "rc=0 gc:list gc:wake gc:nudge "

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "=== C. _pilot_wa_node_open (só abre para a cara exata do que o apply escreve) ==="
for n in 1 2 3 4 5 6 7 8 9; do
  reset; cp "$T/b.ap$n.json" "$T/state.json"
  r=$(W); eq "apply escolheu wa-worker-remote-$n: abre a sessão DESSE alias (nada de alias fixo)" "$r $(ord)" "rc=0 bd:show gc:list gc:new gc:nudge "
  hasgc "session|new|wa-worker-remote|--alias|wa-worker-remote-$n|--no-attach|--title-hint|build wa-abc12: Título X" || fail "alias $n: $(cat "$T/gccalls")"
done
eq "o gancho relê a bead UMA vez, na loja certa" "$(hasbd "|-C|$ST|show|$ID|--json" && nshow)" "1"
for spec in \
  'livre|open||' \
  'dono-outro|in_progress|mila-wa|mila-wa' \
  'alias-0|in_progress|wa-worker-remote-0|wa-worker-remote-0' \
  'alias-10|in_progress|wa-worker-remote-10|wa-worker-remote-10' \
  'alias-sem-numero|in_progress|wa-worker-remote|wa-worker-remote' \
  'alias-traco|in_progress|wa-worker-remote-|wa-worker-remote-' \
  'alias-2x|in_progress|wa-worker-remote-2x|wa-worker-remote-2x' \
  'alias-wa-worker|in_progress|wa-worker-2|wa-worker-2' \
  'marca-diferente|in_progress|wa-worker-remote-2|wa-worker-remote-3' \
  'marca-vazia|in_progress|wa-worker-remote-2|' \
  'status-open|open|wa-worker-remote-2|wa-worker-remote-2' \
  'status-blocked|blocked|wa-worker-remote-2|wa-worker-remote-2' \
  'status-closed|closed|wa-worker-remote-2|wa-worker-remote-2'; do
  nm="${spec%%|*}"; rest="${spec#*|}"; s_="${rest%%|*}"; rest="${rest#*|}"; a_="${rest%%|*}"; m_="${rest#*|}"
  reset; mkb "$T/state.json" "$s_" "$a_" "$m_"; before="$(stt)"
  r=$(W)
  eq "estado '$nm' não é o que o apply escreve: devolve 2, sem sessão e SEM escrever" "$r $(ord)$(nupd) $(stt)" "rc=2 bd:show 0 $before"
done
reset; export FAKE_BD_SHOW_FAIL_FROM=1; r=$(W)
eq "bd falhou na releitura: 2, sem sessão e sem desfazer" "$r $(ord)" "rc=2 bd:show "
grep -q 'não consegui reler' "$T/err" && ok "bd falhou: o aviso diz que não conseguiu reler" || fail "aviso: $(cat "$T/err")"
for nm in outro-id sem-status lixo nulo; do
  reset
  case "$nm" in
    outro-id) mkb "$T/state.json" in_progress wa-worker-remote-2 wa-worker-remote-2 "Título X" wa-zzzzz ;;
    sem-status) jq -n --arg id "$ID" '{id:$id,assignee:"wa-worker-remote-2",metadata:{"pilot.wa_node_alias":"wa-worker-remote-2"}}' > "$T/state.json" ;;
    lixo) echo 'isto não é json' > "$T/state.json" ;;
    nulo) echo 'null' > "$T/state.json" ;;
  esac
  r=$(W); eq "leitura '$nm' não é a bead pedida: 2 e nada escrito" "$r $(ord)$(nupd)" "rc=2 bd:show 0"
  grep -q 'não consegui reler' "$T/err" && ok "leitura '$nm': o aviso diz que não conseguiu reler" || fail "leitura '$nm': aviso: $(cat "$T/err")"
done
# título: sem CR, LF e "|" (a linha lida é separada por "|"), e sem comer a barra invertida
reset; mkb "$T/state.json" in_progress wa-worker-remote-2 wa-worker-remote-2 "$(printf 'a|b\nc\rd')"
r=$(W); hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-2|--no-attach|--title-hint|build wa-abc12: a b c d' && eq "título com '|', LF e CR vira espaços na dica da sessão" "$r" "rc=0" || fail "título: $(cat "$T/gccalls")"
reset; mkb "$T/state.json" in_progress wa-worker-remote-2 wa-worker-remote-2 'C:\temp\novo'
r=$(W); hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-2|--no-attach|--title-hint|build wa-abc12: C:\temp\novo' && eq "título com barra invertida chega inteiro (read -r)" "$r" "rc=0" || fail "título barra: $(cat "$T/gccalls")"
reset; mkb "$T/state.json" in_progress wa-worker-remote-2 wa-worker-remote-2 ""
r=$(W); hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-2|--no-attach|--title-hint|build wa-abc12: ' && eq "título vazio: abre do mesmo jeito" "$r" "rc=0" || fail "título vazio: $(cat "$T/gccalls")"
reset; mkb "$T/state.json" in_progress wa-worker-remote-2 wa-worker-remote-2 '*  $(x)  `y`'
r=$(W); hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-2|--no-attach|--title-hint|build wa-abc12: *  $(x)  `y`' && eq "título com glob e substituição de comando chega como texto" "$r" "rc=0" || fail "título glob: $(cat "$T/gccalls")"
# a falha de abrir, pelo gancho do WA, desfaz com a chave do WA
reset; cp "$T/b.ap3.json" "$T/state.json"; export FAKE_GC_NEW_RC=1
r=$(W); hasbd "$(UPD wa-worker-remote-3)" && eq "falha ao abrir: o gancho do WA desfaz com a chave pilot.wa_node_alias" "$r $(stt)" "rc=1 $FREE" || fail "desfaz WA: $(cat "$T/bdcalls") / $r"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "=== D. o decide inteiro em modo pilot ==="
reset; pilot 3; r=$(D label 0)
eq "label + pilot, script rc 0: lê, escreve (script), relê, abre e avisa — devolve 0" "$r $(ord)" "rc=0 bd:show script:apply bd:show gc:list gc:new gc:nudge "
eq "o apply recebe a base e o AMBIENTE: pilot e 3 slots" "$(cat "$T/calls")" "apply $ID --store $ST --basis label | SPAWN=pilot SLOTS=3"
hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-2|--no-attach|--title-hint|build wa-abc12: Título X' && ok "a sessão é a do alias que o script escolheu" || fail "new: $(cat "$T/gccalls")"
eq "o gancho do modo pilot NÃO escreve na bead (só o script escreveu)" "$(nupd) $(stt)" "0 $AP2"
jq -e 'select(.mode=="label" and .rc==0 and .spawn=="pilot" and .slots==3)' "$T/city/.gc/wa-node-route.jsonl" >/dev/null 2>&1 && ok "a linha de sombra diz spawn=pilot e slots=3" || fail "jsonl: $(cat "$T/city/.gc/wa-node-route.jsonl" 2>/dev/null)"
reset; pilot 5; export FAKE_BEAD2="$T/b.ap4.json"; r=$(D auto 0)
eq "auto + pilot: base 'any', 5 slots, alias -4" "$r $(cat "$T/calls")" "rc=0 apply $ID --store $ST --basis any | SPAWN=pilot SLOTS=5"
hasgc 'session|new|wa-worker-remote|--alias|wa-worker-remote-4|--no-attach|--title-hint|build wa-abc12: Título X' && ok "alias -4 aberto" || fail "alias 4: $(cat "$T/gccalls")"
reset; pilot 3; export FAKE_BEAD2="$T/b.ap2.json" FAKE_SESSIONS="$T/s.asleep.json"; r=$(D label 0)
eq "alias dormindo: o gancho ACORDA em vez de abrir outra" "$r $(ord)" "rc=0 bd:show script:apply bd:show gc:list gc:wake gc:nudge "

# o modo é do ambiente: o script sempre recebe a decisão do gancho
reset; export PILOT_WA_NODE_SLOTS=5; r=$(D label 0)
eq "pool (SPAWN ausente) com SLOTS=5: o script recebe pool/1; o gancho não chama o gc" "$r $(cat "$T/calls") $(ord)" "rc=0 apply $ID --store $ST --basis label | SPAWN=pool SLOTS=1 bd:show script:apply "
jq -e 'select(.spawn=="pool" and .slots==1)' "$T/city/.gc/wa-node-route.jsonl" >/dev/null 2>&1 && ok "e a linha de sombra diz pool/1" || fail "jsonl pool: $(cat "$T/city/.gc/wa-node-route.jsonl" 2>/dev/null)"
for v in Pilot on 1 pool; do
  reset; export PILOT_WA_NODE_SPAWN="$v" PILOT_WA_NODE_SLOTS=4; r=$(D label 0)
  eq "SPAWN='$v': pool/1, sem gc" "$r $(cat "$T/calls") $(ord)" "rc=0 apply $ID --store $ST --basis label | SPAWN=pool SLOTS=1 bd:show script:apply "
done
for v in 0 10 abc "3 "; do
  reset; export PILOT_WA_NODE_SPAWN=pilot PILOT_WA_NODE_SLOTS="$v"; r=$(D label 0)
  eq "pilot com SLOTS='$v': o script recebe 1 slot" "$(cat "$T/calls")" "apply $ID --store $ST --basis label | SPAWN=pilot SLOTS=1"
done
reset; export PILOT_WA_NODE_SPAWN=pilot; r=$(D label 0); eq "pilot sem SLOTS: 1 slot" "$(cat "$T/calls")" "apply $ID --store $ST --basis label | SPAWN=pilot SLOTS=1"

# o script não escreveu: nada de sessão, nada de desfazer
for c in 1 2 10 11 12 99 125 126 127; do
  reset; pilot 3; r=$(D label $c)
  eq "pilot, script rc $c (nada escrito): devolve 1, sem sessão e sem escrita" "$r $(ord)$(stt)" "rc=1 bd:show script:apply $FREE"
done
# a sessão não abriu: desfeito e confirmado → 1; não confirmado → 2
reset; pilot 3; export FAKE_GC_NEW_RC=1; r=$(D label 0)
eq "pilot, session new falhou: desfaz, confirma, devolve 1 (a bead segue no mini)" "$r $(ord)$(stt)" "rc=1 bd:show script:apply bd:show gc:list gc:new gc:close bd:update bd:show $FREE"
jq -e 'select(.rc==0 and .spawn=="pilot")' "$T/city/.gc/wa-node-route.jsonl" >/dev/null 2>&1 && ok "a linha de sombra foi gravada (o apply deu 0)" || fail "jsonl: $(cat "$T/city/.gc/wa-node-route.jsonl" 2>/dev/null)"
reset; pilot 3; export FAKE_GC_NUDGE_RC=1; r=$(D label 0)
eq "pilot, o aviso falhou: desfaz e devolve 1" "$r $(stt)" "rc=1 $FREE"
reset; pilot 3; export FAKE_GC_NEW_RC=1 FAKE_BD_UPDATE_MODE=noop; r=$(D label 0)
eq "pilot, desfazer não confirmado: devolve 2 (segura — a bead pode estar com o alias)" "$r $(stt)" "rc=2 $AP2"
reset; pilot 3; export FAKE_GC_NEW_RC=124; r=$(D label 0)
eq "pilot, session new com prazo estourado: desfaz (1) e o orçamento de spawn do sweep fica gasto" "$r $(slow)" "rc=1 1"
reset; pilot 3; sj "$T/s.busy.json" '[{"alias":"wa-worker-remote-2","template":"wa-worker-remote","state":"active"}]'; export FAKE_SESSIONS="$T/s.busy.json"; r=$(D label 0)
eq "pilot, o alias que o script escolheu está ocupado: não abre, desfaz, devolve 1" "$r $(ord)$(stt)" "rc=1 bd:show script:apply bd:show gc:list bd:update bd:show $FREE"
reset; pilot 3; export FAKE_GC_LIST_RC=1; r=$(D label 0)
eq "pilot, lista de sessões ilegível: desfaz e devolve 1" "$r $(stt)" "rc=1 $FREE"
# o apply "deu 0" mas a bead não está com a cara do apply
reset; pilot 3; export FAKE_BEAD2="$T/b.foreign.json"; r=$(D label 0)
eq "pilot, o apply deu 0 mas a bead é de outro dono: devolve 2, sem sessão e SEM escrever" "$r $(ord)$(stt)" "rc=2 bd:show script:apply bd:show in_progress,mila-wa,-"
reset; pilot 3; export FAKE_BEAD2="$T/b.free.json"; r=$(D label 0)
eq "pilot, o apply deu 0 mas a bead continua livre: devolve 2, sem sessão" "$r $(ord)" "rc=2 bd:show script:apply bd:show "
reset; pilot 3; export FAKE_BD_SHOW_FAIL_FROM=2; r=$(D label 0)
eq "pilot, não consegui reler depois do apply: devolve 2, sem sessão e sem desfazer" "$r $(ord)$(nupd)" "rc=2 bd:show script:apply bd:show 0"

# orçamento de spawn: só no modo pilot, só na escrita real
reset; pilot 3; export PRE_SLOW=1; r=$(D label 0)
eq "pilot com o orçamento de spawn já gasto: devolve 1 e NADA é escrito (o script nem roda)" "$r $(ord)" "rc=1 bd:show "
grep -q 'orçamento de spawn' "$T/err" && ok "o log diz que foi o orçamento" || fail "log orçamento: $(cat "$T/err")"
[ ! -e "$T/city/.gc/wa-node-route.jsonl" ] && ok "sem linha de sombra (nada foi tentado)" || fail "jsonl existe: $(cat "$T/city/.gc/wa-node-route.jsonl")"
reset; export PRE_SLOW=1; r=$(D label 0)
eq "pool com o orçamento gasto: o pool segue como sempre (o script roda e devolve 0)" "$r $(ord)" "rc=0 bd:show script:apply "
reset; pilot 3; export PRE_SLOW=1; r=$(D label 0 1)
eq "pilot + orçamento gasto + dry-run: o apply --dry-run roda (não escreve nada)" "$r $(cat "$T/calls")" "rc=1 apply $ID --store $ST --basis label --dry-run | SPAWN=pilot SLOTS=3"

# dry-run
reset; pilot 3; r=$(D label 0 1)
eq "pilot + DRY_RUN=1: 'apply --dry-run' COM o ambiente, sem gc e sem escrita, devolve 1" "$r $(cat "$T/calls") $(ord)$(stt)" "rc=1 apply $ID --store $ST --basis label --dry-run | SPAWN=pilot SLOTS=3 bd:show script:apply $FREE"
reset; pilot 3; r=$(D auto 0 1)
eq "auto + pilot + DRY_RUN=1: base 'any'" "$(cat "$T/calls")" "apply $ID --store $ST --basis any --dry-run | SPAWN=pilot SLOTS=3"
# shadow e off
reset; pilot 4; r=$(D shadow 0)
eq "shadow + pilot: só 'check', nunca abre sessão, devolve 1" "$r $(ord)" "rc=1 script:check "
jq -e 'select(.mode=="shadow" and .spawn=="pilot" and .slots==4)' "$T/city/.gc/wa-node-route.jsonl" >/dev/null 2>&1 && ok "a sombra registra spawn=pilot e slots=4" || fail "jsonl shadow: $(cat "$T/city/.gc/wa-node-route.jsonl" 2>/dev/null)"
reset; pilot 4; r=$(D off 0); eq "off + pilot: nada roda" "$r $(ord)" "rc=1 "
reset; pilot 4; r=$(H _pilot_wa_node_decide "$ID" "$ST" wa-worker); eq "variável de rota ausente + pilot: nada roda" "$r $(ord)" "rc=1 "

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "=== E. _pilot_wa_node_settle (rc incerto do apply) ==="
# uma escrita que pode ter pegado sem ninguém para abrir a sessão: no modo pilot o gancho desfaz o que tem a cara do apply; o decide devolve 2 de qualquer jeito
for c in 13 124 137 143 129 130 131 139 141 255; do
  reset; pilot 3; export FAKE_APPLY_WRITES=1; r=$(D label $c)
  eq "pilot, script rc $c com a escrita feita: desfaz (sem sessão) e devolve 2" "$r $(ord)$(stt)" "rc=2 bd:show script:apply bd:show bd:update bd:show $FREE"
done
hasbd "$(UPD wa-worker-remote-2)" && ok "o desfazer do settle é a escrita guardada pela chave do WA" || fail "settle update: $(cat "$T/bdcalls")"
grep -q 'ficou com o alias wa-worker-remote-2 depois de um apply incerto' "$T/err" && ok "o aviso diz o que foi desfeito" || fail "settle aviso: $(cat "$T/err")"
reset; pilot 3; export FAKE_APPLY_WRITES=1; r=$(D auto 13)
eq "auto: o settle também roda" "$r $(stt)" "rc=2 $FREE"
for c in 13 124 130; do
  reset; pilot 3; export FAKE_APPLY_WRITES=0; r=$(D label $c)
  eq "pilot, rc $c e a escrita NÃO pegou: devolve 2 e não escreve nada" "$r $(ord)$(stt)" "rc=2 bd:show script:apply bd:show $FREE"
done
for spec in \
  'dono-outro|b.foreign' \
  'marca-diferente|b.mark3' \
  'status-open|b.open2' \
  'alias-0|b.a0' \
  'alias-10|b.a10' \
  'alias-sem-numero|b.asn'; do
  nm="${spec%%|*}"; f_="${spec#*|}"
  case "$f_" in
    b.mark3) mkb "$T/b.mark3.json" in_progress wa-worker-remote-2 wa-worker-remote-3 ;;
    b.open2) mkb "$T/b.open2.json" open wa-worker-remote-2 wa-worker-remote-2 ;;
    b.a0)    mkb "$T/b.a0.json" in_progress wa-worker-remote-0 wa-worker-remote-0 ;;
    b.a10)   mkb "$T/b.a10.json" in_progress wa-worker-remote-10 wa-worker-remote-10 ;;
    b.asn)   mkb "$T/b.asn.json" in_progress wa-worker-remote wa-worker-remote ;;
  esac
  reset; pilot 3; export FAKE_APPLY_WRITES=1 FAKE_BEAD2="$T/$f_.json"; r=$(D label 13)
  after="$(jq -r '[.status, (.assignee // "-"), (.metadata["pilot.wa_node_alias"] // "-")] | join(",")' "$T/$f_.json")"
  eq "pilot, rc 13 e a bead está assim: '$nm' (não é a cara do apply) — não toca, devolve 2" "$r $(nupd) $(stt)" "rc=2 0 $after"
done
reset; pilot 3; export FAKE_APPLY_WRITES=1 FAKE_BD_SHOW_FAIL_FROM=2; r=$(D label 13)
eq "pilot, rc 13 e a releitura do settle falha: não escreve, devolve 2" "$r $(nupd)" "rc=2 0"
reset; pilot 3; export FAKE_APPLY_WRITES=1 FAKE_BD_UPDATE_MODE=noop; r=$(D label 13)
eq "pilot, rc 13 e o desfazer não se confirma: só avisa, devolve 2 do mesmo jeito" "$r $(stt)" "rc=2 $AP2"
grep -q 'não se confirmou' "$T/err" && ok "e o aviso diz que não se confirmou" || fail "settle noop aviso: $(cat "$T/err")"
reset; pilot 3; export FAKE_APPLY_WRITES=1 FAKE_BEAD2="$T/b.ap1.json"; r=$(D label 13)
hasbd "$(UPD wa-worker-remote-1)" && ok "o alias vem da bead, não de uma constante (-1)" || fail "settle alias: $(cat "$T/bdcalls")"
# modo pool: o settle não faz nada (a rota é do pool)
for sp in "" pool; do
  reset; export FAKE_APPLY_WRITES=1 FAKE_BEAD2="$T/b.ap1.json"; [ -z "$sp" ] || export PILOT_WA_NODE_SPAWN="$sp"; r=$(D label 13)
  eq "modo pool (SPAWN='${sp:-ausente}'), rc 13 com a escrita feita: devolve 2 e NÃO desfaz (a rota é do pool)" "$r $(ord)$(stt)" "rc=2 bd:show script:apply in_progress,wa-worker-remote-1,wa-worker-remote-1"
done
# rc que significam "nada rodou/nada escrito" não chamam o settle
for c in 1 2 10 11 12 125 126 127; do
  reset; pilot 3; export FAKE_APPLY_WRITES=1; r=$(D label $c)
  eq "pilot, rc $c: devolve 1 e não chama o settle" "$r $(ord)" "rc=1 bd:show script:apply "
done

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "=== F. a fiação e as peças genéricas ==="
[ "$(grep -c '_pilot_wa_node_open "\$_id" "\$_store"' "$DISPATCHER")" = 1 ] && ok "_pilot_wa_node_open é chamada em um lugar só (o decide)" || fail "chamadas de _pilot_wa_node_open: $(grep -c '_pilot_wa_node_open "\$_id"' "$DISPATCHER")"
[ "$(grep -c '_pilot_node_remote_open wa-worker-remote ' "$DISPATCHER")" = 1 ] && ok "o gancho do WA chama a peça genérica uma vez, com o template" || fail "chamadas da peça genérica"
for f in _pilot_node_remote_open _pilot_node_remote_rollback; do
  body="$(fn_of "$f" | grep -v '^ *#')"
  printf '%s' "$body" | grep -qE 'wa-|wa_node|PILOT_WA' && fail "$f cita WA no código (a peça tem de ser genérica: template, alias e chave entram por argumento)" || ok "$f não cita WA no código (genérica)"
done
bash -n "$DISPATCHER" && ok "bash -n do pilot-dispatcher.sh" || fail "bash -n do pilot-dispatcher.sh"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
MUTATOR="$SELF_DIR/pilot-dispatcher.wa-node-spawn.mutants.py"
if [ -z "${WA_NODE_SPAWN_SELFTEST_FILE:-}" ]; then
  echo
  echo "=== G0. o mutador não inventa mutante ==="
  # origem ausente, origem sem o trecho que o mutante quebra, nome que não existe → rc ≠ 0 e NADA escrito no destino: um destino vazio ou igual ao original passaria por "morto" ou por "sobreviveu" à toa
  mut_recusa() { # mut_recusa <descrição> <origem> <nome>
    rm -f "$T/mut.recusa.sh"
    if python3 -I "$MUTATOR" "$2" "$T/mut.recusa.sh" "$3" > /dev/null 2>&1; then fail "mutador, $1: saiu 0, tinha de recusar"
    elif [ -e "$T/mut.recusa.sh" ]; then fail "mutador, $1: recusou mas deixou o destino escrito"
    else ok "mutador, $1: recusa (rc ≠ 0) e não escreve o destino"; fi
  }
  : > "$T/fonte-vazia.sh"
  MUT_UM="$(python3 -I "$MUTATOR" --list 2>/dev/null | head -n 1)"
  if [ -z "$MUT_UM" ]; then fail "o mutador não listou nome nenhum: sem ele não há como provar a recusa"
  else
    mut_recusa "origem ausente" "$T/nao-existe.sh" "$MUT_UM"
    mut_recusa "origem sem o trecho a quebrar" "$T/fonte-vazia.sh" "$MUT_UM"
    mut_recusa "nome que não existe" "$DISPATCHER" "nao-existe-esse-mutante"
  fi
fi

if [ -z "${WA_NODE_SPAWN_SELFTEST_FILE:-}" ] && [ -z "${WA_NODE_SPAWN_ST_NOMUT:-}" ]; then
  echo
  echo "=== G. mutantes (cada um tem de derrubar o selftest) ==="
  # o mutador mora em arquivo próprio. ausente/ilegível (python falha) → `fail`; vazio (lista sem nomes) ou com menos que o piso de hoje (72) → `fail` também: tirar um mutante tem de ser decisão visível, nunca "todos mortos" por lista curta
  MUT_LIST="$(python3 -I "$MUTATOR" --list)" || { fail "o mutador não carregou"; MUT_LIST=""; }
  [ "$(echo "$MUT_LIST" | wc -w | tr -d ' ')" -ge 72 ] || fail "o mutador listou menos de 72 mutantes ($(echo "$MUT_LIST" | wc -w | tr -d ' '))"
  run_mut() { # run_mut <nome> — escreve $T/res.<nome>: morto | SOBREVIVEU | ERRO
    local n="$1"
    if ! python3 -I "$MUTATOR" "$DISPATCHER" "$T/mut.$n.sh" "$n" > "$T/res.$n.apply" 2>&1; then echo ERRO > "$T/res.$n"; return; fi
    if ! bash -n "$T/mut.$n.sh" 2>>"$T/res.$n.apply"; then echo ERRO > "$T/res.$n"; return; fi
    if WA_NODE_SPAWN_SELFTEST_FILE="$T/mut.$n.sh" bash "$SELF" > "$T/res.$n.out" 2>&1; then echo SOBREVIVEU > "$T/res.$n"; else echo morto > "$T/res.$n"; fi
  }
  JOBS="${WA_NODE_SPAWN_ST_JOBS:-4}"
  i=0
  for n in $MUT_LIST; do
    run_mut "$n" &
    i=$((i+1))
    if [ $((i % JOBS)) -eq 0 ]; then wait; fi
  done
  wait
  for n in $MUT_LIST; do
    case "$(cat "$T/res.$n" 2>/dev/null)" in
      morto) ok "mutante $n morto" ;;
      ERRO) fail "mutante $n: não consegui aplicar ou o resultado não é bash válido ($(tr '\n' ' ' < "$T/res.$n.apply"))" ;;
      *) fail "mutante $n SOBREVIVEU" ;;
    esac
  done
  echo "  ($(echo "$MUT_LIST" | wc -w | tr -d ' ') mutantes)"
fi

echo
TOTAL=$((PASS+FAIL))
echo "$PASS/$TOTAL ok"
if [ "$FAIL" = 0 ]; then echo "SELFTEST OK"; exit 0; fi
echo "SELFTEST FAIL ($FAIL)"
exit 1
