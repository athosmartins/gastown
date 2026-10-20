#!/usr/bin/env bash
# prod-tests/gascity/story-ga-2hd02v.3.sh — prod test da história ga-2hd02v.3 (Hetzner 100%: WhatsApp no nó de verdade — N slots, rota auto, docs/ no espelho).
#
# Contents
#   O que verifica · O que não verifica · Por que é seguro rodar · O que é aviso e não falha
#
# O QUE VERIFICA (nos arquivos IMPLANTADOS, não numa cópia): o modo `pilot` de N slots existe no gancho do Pilot e no despachante e o selftest dele (casos, sem os mutantes) termina com "N/N ok";
#   o teto de sessões do template wa-worker-remote (max_active_sessions) é um dígito ≥ 1 e o plist VERSIONADO e o plist VIVO do Pilot não ligam mais slots do que ele nem do que o `cap` do host
#   (.gc/session-ssh.json) deixam abrir — PILOT_WA_NODE_SLOTS acima do teto faria o Pilot atribuir a um alias que o engine não abre; PILOT_WA_NODE_SLOTS > 1 sem PILOT_WA_NODE_SPAWN=pilot não vale nada
#   (o modo pool tem 1 slot); PILOT_WA_NODE_SPAWN que não seja pool|pilot vale pool em silêncio; o runbook descreve o modo.
# O QUE NÃO VERIFICA — e não diz que verifica: que o nó rodou UMA bead de WhatsApp (o WA nunca rodou no nó), que a rota `auto` não mandou ao nó nenhuma bead com dado de lead (isso é a medida da sombra,
#   `.gc/wa-node-route.jsonl` mais os comentários `nó (...)` das beads), nem que o `pool` abre a sessão de uma bead da loja do WA (nunca provado; é por isso que mais de 1 slot usa o modo `pilot`).
#   Este teste PASSAR não diz que o nó está ocupado: quem diz é o uso de CPU do nó por hora.
# POR QUE É SEGURO RODAR: só lê arquivos (plist, toml, json, fonte) e roda o selftest do modo `pilot`, que usa bd/gc/despachante FALSOS numa pasta temporária. Não fala com o nó, não chama `gc` nem `bd`
#   reais, não toca em .gc/ vivo. Não roda os mutantes (são a evidência do gate): só a bateria de casos.
# O QUE É AVISO E NÃO FALHA: o plist vivo ou o config do host que não existem nesta máquina (não há o que conferir).
#
# Chamado por run.sh depois do deploy (STORY_ID=ga-2hd02v.3). Sai 0 se passar.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
BASH32=/bin/bash
log()  { echo "[prod-test:gascity ga-2hd02v.3] $*"; }
warn() { echo "[prod-test:gascity ga-2hd02v.3] AVISO: $*"; }
fail() { echo "[prod-test:gascity ga-2hd02v.3] FAIL: $*" >&2; exit 1; }
[[ -x "$BASH32" ]] || fail "$BASH32 não executa — não dá para checar a sintaxe no interpretador de verdade"

PIL="$ASSETS/pilot-dispatcher.sh"; SPAWN_ST="$ASSETS/pilot-dispatcher.wa-node-spawn.selftest.sh"; SPAWN_MUT="$ASSETS/pilot-dispatcher.wa-node-spawn.mutants.py"
DSP="$CITY/scripts/wa-node-dispatch.sh"
AGENT="$CITY/agents/wa-worker-remote/agent.toml"
RUNBOOK="$CITY/docs/runbooks/hetzner-wa-node.md"
PLIST_REPO="$CITY/scripts/com.gascity.pilot.plist"
PLIST_LIVE="${PILOT_LIVE_PLIST:-$HOME/Library/LaunchAgents/com.gascity.pilot.plist}"
HOSTCFG="$CITY/.gc/session-ssh.json"

for f in "$PIL" "$SPAWN_ST" "$SPAWN_MUT" "$DSP" "$AGENT" "$RUNBOOK" "$PLIST_REPO"; do [[ -f "$f" ]] || fail "arquivo implantado ausente: $f"; done
for f in "$PIL" "$SPAWN_ST" "$DSP"; do "$BASH32" -n "$f" || fail "$f não parseia sob $BASH32"; done
[[ -x "$SPAWN_ST" ]] || fail "$SPAWN_ST sem permissão de execução"
log "arquivos implantados presentes; sintaxe ok ✓"

# ── o modo `pilot` existe, e o padrão segue sendo o pool ─────────────────────
grep -q '^_pilot_wa_node_spawn_mode() {' "$PIL" || fail "o gancho não tem _pilot_wa_node_spawn_mode ($PIL)"
grep -q '^_pilot_node_remote_open() {' "$PIL" || fail "o gancho não tem _pilot_node_remote_open ($PIL)"
grep -q '^_pilot_wa_node_open() {' "$PIL" || fail "o gancho não tem _pilot_wa_node_open ($PIL)"
grep -q 'WA_NODE_SPAWN' "$DSP" && grep -q 'WA_NODE_SLOTS' "$DSP" && grep -q 'WA_NODE_SELF' "$DSP" || fail "o despachante não lê WA_NODE_SPAWN/WA_NODE_SLOTS/WA_NODE_SELF ($DSP)"
grep -q '^## N slots: o modo `pilot`' "$RUNBOOK" || fail "o runbook não descreve o modo pilot ($RUNBOOK)"
log "modo pilot presente no gancho, no despachante e no runbook ✓"

# ── o teto: agent.toml, host e os dois plists ────────────────────────────────
# vazio (sem a linha) → falha: não há como saber o teto; ilegível (não é um dígito) → o mesmo
grep -qE '^min_active_sessions *= *0$' "$AGENT" || fail "wa-worker-remote não nasce com min_active_sessions = 0 ($AGENT)"
MAXS=$(sed -n 's/^max_active_sessions *= *\([0-9][0-9]*\) *$/\1/p' "$AGENT" | head -n 1)
[[ "$MAXS" =~ ^[1-9]$ ]] || fail "max_active_sessions do wa-worker-remote não é um dígito de 1 a 9 (lido: '${MAXS:-vazio}') em $AGENT"
# config do host ausente → só aviso e sem teto de host (CAP vazio); presente e ilegível, ou sem cap numérico → falha: não adivinha
CAP=""
if [[ -f "$HOSTCFG" ]]; then
  CAP=$(jq -r '.hosts.hetzner.cap | select(type == "number" and . >= 1 and . == floor) | tostring' "$HOSTCFG" 2>/dev/null) || fail "$HOSTCFG não parseia: não dá para conferir o cap do host"
  [[ -n "$CAP" ]] || fail "$HOSTCFG sem .hosts.hetzner.cap inteiro ≥ 1: não dá para conferir o cap do host"
else
  warn "$HOSTCFG não existe nesta máquina: o cap do host não foi conferido"
fi

# plist_env <arquivo> <chave>: o valor (texto) da chave em EnvironmentVariables. Chave ausente → nada, rc 0 (vale o padrão do gancho); arquivo que não parseia → rc 3 (quem chama FALHA: não se sabe o que liga)
plist_env() {
  python3 -I -c '
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
except Exception:
    sys.exit(3)
v = (d.get("EnvironmentVariables") or {}).get(sys.argv[2], "")
print(v if isinstance(v, str) else "")
' "$1" "$2"
}
# check_plist <rótulo> <arquivo>: SLOTS e SPAWN coerentes com o teto do engine e o do host
check_plist() {
  local label="$1" f="$2" slots spawn
  slots=$(plist_env "$f" PILOT_WA_NODE_SLOTS) || fail "$label ($f) não parseia: não dá para dizer quantos slots liga"
  spawn=$(plist_env "$f" PILOT_WA_NODE_SPAWN) || fail "$label ($f) não parseia: não dá para dizer o modo de abrir"
  if [[ -n "$spawn" && "$spawn" != pool && "$spawn" != pilot ]]; then
    fail "$label: PILOT_WA_NODE_SPAWN='$spawn' — só 'pool' e 'pilot' valem; qualquer outro vira pool em silêncio"
  fi
  if [[ -z "$slots" ]]; then log "$label: sem PILOT_WA_NODE_SLOTS (vale 1; modo ${spawn:-pool}) ✓"; return 0; fi
  [[ "$slots" =~ ^[1-9]$ ]] || fail "$label: PILOT_WA_NODE_SLOTS='$slots' — tem de ser UM dígito de 1 a 9 (outro valor vale 1 em silêncio)"
  (( slots <= MAXS )) || fail "$label: PILOT_WA_NODE_SLOTS=$slots passa o teto do engine (max_active_sessions = $MAXS em $AGENT)"
  if [[ -n "$CAP" ]]; then (( slots <= CAP )) || fail "$label: PILOT_WA_NODE_SLOTS=$slots passa o cap do host ($CAP em $HOSTCFG, dividido com dog-remote e gate-reviewer)"; fi
  if (( slots > 1 )) && [[ "$spawn" != pilot ]]; then
    fail "$label: PILOT_WA_NODE_SLOTS=$slots sem PILOT_WA_NODE_SPAWN=pilot — o modo pool tem 1 slot e o N seria ignorado"
  fi
  log "$label: PILOT_WA_NODE_SLOTS=$slots (modo ${spawn:-pool}) cabe no teto $MAXS${CAP:+ e no cap $CAP} ✓"
}
check_plist "plist versionado" "$PLIST_REPO"
if [[ -f "$PLIST_LIVE" ]]; then check_plist "plist vivo" "$PLIST_LIVE"; else warn "$PLIST_LIVE não existe nesta máquina: o plist vivo não foi conferido"; fi

# ── o selftest do modo pilot, contra a árvore viva (os casos; os mutantes são a evidência do gate) ──
out="$(WA_NODE_SPAWN_ST_NOMUT=1 timeout 600 "$BASH32" "$SPAWN_ST" 2>&1)" || { echo "$out" | tail -25 >&2; fail "selftest do modo pilot falhou (ou estourou o tempo) contra a árvore viva"; }
line=$(printf '%s\n' "$out" | grep -E '^[0-9]+/[0-9]+ ok$' | tail -1)
[[ -n "$line" ]] || fail "selftest do modo pilot sem a linha de resultado 'N/N ok':
$out"
pass=${line%%/*}; rest=${line#*/}; total=${rest%% *}
[[ "$pass" == "$total" && "$total" -ge 240 ]] || fail "selftest do modo pilot reportou '$line' (esperado todos ok e pelo menos 240 casos)"
printf '%s\n' "$out" | grep -q 'SELFTEST OK' || fail "selftest do modo pilot sem a linha final de sucesso"
log "selftest do modo pilot: $line ✓"

log "OK — modo pilot de N slots pronto e dentro do teto. Rota auto, N slots vivos e a prova do dia seguinte (wa-node-route.jsonl + CPU do nó por hora) são passos de ligar (docs/runbooks/hetzner-wa-node.md)."
