#!/usr/bin/env bash
# pilot-dispatcher.pool-slot-inflight.selftest.sh — a sessão do nó Hetzner (wa-worker-remote-*) NÃO conta no teto de in-flight das vagas do mini (ga-ohw13b4).
#
# O BUG. pick_pool_builder() escolhe uma vaga virtual wa-worker-1..4 do pool do mini e pula a que está no teto de in-flight por crew (_crew_at_inflight_cap, PILOT_MAX_INFLIGHT_PER_CREW=3). A contagem
# (_crew_inflight_count) casa o assignee pelo nome curto: para wa-worker-1 o curto é «wa-worker», e index(a, "wa-worker-")==1 casa TAMBÉM wa-worker-remote-N (sessão do nó, que corre no Hetzner) e wa-worker-adhoc-*.
# Com 3 beads em curso no nó, as 4 vagas do mini parecem cheias de uma vez: o pick devolve vazio e o dispatch_one adia a bead («POOL(whatsapp_automation): all crew busy/used this sweep … deferring») ANTES de
# chegar ao gancho do nó. Medido no log do Pilot (02/11): 23 das 50 adiadas «all crew busy» de WA eram de beads que a passada de WA no nó tinha acabado de julgar node — o nó tinha vaga, o mini não era a vaga delas.
#
# O CONSERTO. A contagem ignora assignee de sessão do nó (nome com o segmento «remote»): o teto de in-flight guarda o mini; a capacidade do nó é do nó (_PWN_SLOTS, apply rc 12).
#
# As funções são as REAIS (extraídas palavra por palavra do pilot-dispatcher.sh); só bd e os predicados de tmux/suspensão são falsos. Tudo roda em `set -uo pipefail`.
#   A. a contagem real (awk de _crew_inflight_count) e o teto (_crew_at_inflight_cap): o nó não conta; o mini e os crews persistentes continuam contando.
#   B. o pick real (pick_pool_builder) no cenário do incidente: 3 sessões do nó em curso → uma vaga do mini AINDA é escolhida; 3 do mini → nenhuma (o teto segue valendo).
#   C. mutantes: cada quebra tem de derrubar este selftest. Cada um roda o arquivo inteiro e para no 1º FAIL.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.pool-slot-inflight.selftest.sh
# Exit 0 iff tudo passa. Saída: linhas ok/FAIL, "N/N ok", "SELFTEST OK". Bash 3.2 (macOS) basta.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
DISPATCHER="${POOL_SLOT_INFLIGHT_SELFTEST_FILE:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0
FAIL=0
ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
# Rodando como mutante (POOL_SLOT_INFLIGHT_SELFTEST_FILE) o primeiro FAIL já diz «morto»: sai na hora.
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); [ -z "${POOL_SLOT_INFLIGHT_SELFTEST_FILE:-}" ] || exit 1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — obtido '$2', esperado '$3'"; fi; }   # eq <descrição> <obtido> <esperado>
[ -f "$DISPATCHER" ] || { echo "FATAL: $DISPATCHER não existe" >&2; exit 2; }
fn_of() { awk -v n="$1" '$0 ~ "^"n"\\(\\)"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
# o bloco REAL do teto: a declaração de PILOT_MAX_INFLIGHT_PER_CREW, os globais da memória por varredura, _crew_inflight_count e _crew_at_inflight_cap
CAP_FNS="$(awk '/^PILOT_MAX_INFLIGHT_PER_CREW=/{p=1} p{print} /_crew_at_inflight_cap\(\)/{c=1} c&&/^}$/{exit}' "$DISPATCHER")"
[ -n "$CAP_FNS" ] || { echo "FATAL: o bloco de _crew_at_inflight_cap não está em $DISPATCHER" >&2; exit 2; }
case "$CAP_FNS" in *"_crew_inflight_count()"*) ;; *) echo "FATAL: _crew_inflight_count() não está no bloco extraído de $DISPATCHER" >&2; exit 2 ;; esac
PICK_FN="$(fn_of pick_pool_builder)"
[ -n "$PICK_FN" ] || { echo "FATAL: pick_pool_builder() não está em $DISPATCHER" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pool-slot-inflight.XXXXXX")" || exit 2
trap 'rm -rf "$T" 2>/dev/null || true' EXIT

# in_flight "<assignees…>" — o JSON que o `bd list --json -l story:in-flight` devolveria (um assignee por bead)
in_flight() { local a; for a in $1; do printf '%s\n' "$a"; done | jq -Rsc 'split("\n") | map(select(length > 0)) | map({id: ("wa-x" + (. | length | tostring)), assignee: .})'; }
# count <crew> "<assignees…>" — a contagem REAL (o awk do dispatcher) com o bd falso; a memória por rig é nova a cada chamada (subshell)
count() {
  local crew="$1" json; json="$(in_flight "$2")"
  ( eval "$CAP_FNS"; bd() { printf '%s' "$FAKE_JSON"; }; FAKE_JSON="$json"; _crew_inflight_count "$crew" "/rig/wa" )
}
# capped <crew> "<assignees…>" — capped|free pelo teto REAL (3 por padrão)
capped() {
  local crew="$1" json; json="$(in_flight "$2")"
  ( eval "$CAP_FNS"; bd() { printf '%s' "$FAKE_JSON"; }; FAKE_JSON="$json"; PILOT_INFLIGHT_RIG_OVERRIDE="/rig/wa"
    if _crew_at_inflight_cap "$crew"; then printf capped; else printf free; fi )
}
# pick "<assignees…>" — o pick REAL no cenário do incidente: pool wa-worker-1..4, nada ocupado/usado/suspenso/atendido por humano; devolve a vaga escolhida ou «(nenhuma)»
pick() {
  local json out; json="$(in_flight "$1")"
  out="$( eval "$CAP_FNS"; eval "$PICK_FN"
    bd() { printf '%s' "$FAKE_JSON"; }; FAKE_JSON="$json"; PILOT_INFLIGHT_RIG_OVERRIDE="/rig/wa"
    rig_to_builders() { printf 'wa-worker-1 wa-worker-2 wa-worker-3 wa-worker-4'; }
    _crew_session_human_engaged() { return 1; }
    _crew_is_suspended() { return 1; }
    PILOT_BUSY_BUILDERS="ga-wisp-04ka2 wa-worker-remote-4 wa-worker-remote-gawisp04ka2 ga-wisp-3zozi wa-worker-remote-2 wa-worker-remote-gawisp3zozi"
    PILOT_USED_BUILDERS=""
    pick_pool_builder whatsapp_automation "" "oracle-wa digo-wa thies-wa" )" || out=""
  printf '%s' "${out:-(nenhuma)}"
}

echo "A. a contagem e o teto reais"
REMOTE3="wa-worker-remote-4 wa-worker-remote-2 wa-worker-remote-gawisp04ka2"
MINI3="wa-worker-adhoc-0acdf41fd2 wa-worker-1 wa-worker-3-gawispabc"
eq "3 sessões do nó em curso: wa-worker-2 conta 0 (o nó não é do mini)"           "$(count wa-worker-2 "$REMOTE3")" "0"
for _s in 1 2 3 4; do
  eq "3 sessões do nó em curso: a vaga wa-worker-$_s NÃO está no teto"           "$(capped wa-worker-$_s "$REMOTE3")" "free"
done
eq "sessão do MBP (wa-worker-remote-mbp) também não é vaga do mini"                  "$(count wa-worker-2 "wa-worker-remote-mbp wa-worker-remote-1 wa-worker-remote-2")" "0"
eq "3 sessões do mini em curso: wa-worker-2 conta 3 (o nome curto do pool segue valendo)" "$(count wa-worker-2 "$MINI3")" "3"
eq "3 sessões do mini em curso: wa-worker-2 está no teto"                         "$(capped wa-worker-2 "$MINI3")" "capped"
eq "2 do mini + 3 do nó: conta só as 2 do mini"                                  "$(count wa-worker-2 "wa-worker-1 wa-worker-adhoc-aa $REMOTE3")" "2"
eq "2 do mini + 3 do nó: não está no teto"                                       "$(capped wa-worker-2 "wa-worker-1 wa-worker-adhoc-aa $REMOTE3")" "free"
eq "3 do mini + 3 do nó: continua no teto (as do mini bastam)"                   "$(capped wa-worker-2 "$MINI3 $REMOTE3")" "capped"
eq "ps-worker: 3 sessões do nó (ps-worker-remote-*) não contam para ps-worker-1" "$(count ps-worker-1 "ps-worker-remote-1 ps-worker-remote-2 ps-worker-remote-gawispxx")" "0"
eq "ps-worker: 3 do mini contam e batem no teto"                                  "$(capped ps-worker-1 "ps-worker-1 ps-worker-adhoc-aa ps-worker-2-gawispbb")" "capped"
eq "crew persistente (mila-wa): 3 sessões dela batem no teto"                    "$(capped mila-wa "mila-wa mila-wa-gawispx1 mila-wa-gawispx2")" "capped"
eq "crew persistente (mila-wa): sessões do nó não contam para ela"               "$(count mila-wa "$REMOTE3 wa-worker-remote-9 wa-worker-remote-8")" "0"
eq "o segmento «remote» é palavra inteira: gawispremote1 (sufixo de sessão) conta" "$(count mila-wa "mila-wa-gawispremote1")" "1"
eq "palavra inteira, ponta esquerda: sufixos gawispremote e xremote-2 contam"      "$(count mila-wa "mila-wa-gawispremote mila-wa-gawispxremote-2")" "2"
eq "palavra inteira, ponta direita: o nome nu wa-worker-remote (sem número) é do nó" "$(count wa-worker-2 "wa-worker-remote")" "0"
eq "bd sem resposta legível: contagem 0, fora do teto (abre, como sempre)"        "$( ( eval "$CAP_FNS"; bd() { return 1; }; _crew_inflight_count wa-worker-2 /rig/wa ) )" "0"

echo "B. o pick real no cenário do incidente (02/11 04:48)"
eq "3 sessões do nó em curso: o pick ainda acha vaga (wa-worker-1)"              "$(pick "$REMOTE3")" "wa-worker-1"
eq "3 sessões do nó em curso + adhoc/1 do mini: ainda acha vaga"                 "$(pick "$REMOTE3 wa-worker-adhoc-aa wa-worker-1")" "wa-worker-1"
eq "3 sessões do mini em curso: o pick devolve nenhuma (o teto do mini segue)"   "$(pick "$MINI3")" "(nenhuma)"

if [ -z "${POOL_SLOT_INFLIGHT_SELFTEST_FILE:-}" ]; then
  echo "C. mutantes"
  mut() {
    local name="$1" old="$2" new="$3" copy="$T/mut.sh"
    python3 -I - "$DISPATCHER" "$copy" "$old" "$new" <<'PYEOF' || { fail "mutante $name: o trecho original não existe (o fonte mudou? atualize o mutante)"; return; }
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[3], sys.argv[4]
m = re.search(r"^_crew_inflight_count\(\) \{\n.*?^\}\n", src, re.S | re.M)
if not m: sys.exit(1)
i = src.find(old, m.start(), m.end())
if i < 0: sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(src[:i] + new + src[i + len(old):])
PYEOF
    if POOL_SLOT_INFLIGHT_SELFTEST_FILE="$copy" bash "$SELF" >/dev/null 2>&1; then fail "mutante $name SOBREVIVEU"; else ok "mutante $name morreu"; fi
  }
  F='if (a ~ /(^|-)remote(-|$)/) next; '
  mut sem-filtro-do-no        "$F" ''
  mut filtro-casa-tudo        "$F" 'if (a ~ /./) next; '
  mut filtro-so-wa-worker     "$F" 'if (a ~ /wa-worker-remote/) next; '
  mut filtro-sem-ancora-fim   "$F" 'if (a ~ /(^|-)remote-/) next; '
  mut filtro-sobre-a-coluna-1 "$F" 'if ($1 ~ /(^|-)remote(-|$)/) next; '
  mut filtro-sem-ancora-ini   "$F" 'if (a ~ /remote(-|$)/) next; '
  mut filtro-so-depois-de-contar "{ a=\$2; $F" '{ a=$2; n++; '
fi

echo "---"; echo "$PASS/$((PASS+FAIL)) ok"
[ $FAIL -eq 0 ] && echo "SELFTEST OK" || { echo "SELFTEST FALHOU ($FAIL)"; exit 1; }
