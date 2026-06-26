#!/usr/bin/env bash
# agent-stuck-escalation.sh — Camada 2 da hierarquia de escalação autônoma (ga-qw3p.2).
#
# CONTEXTO (épico ga-qw3p):
#   Camada 1 (ga-qw3p.1): roteamento por tópico → crew certo
#   Camada 2 (ESTA):       sem progresso em 30min → Mayor
#   Camada 3 (ga-qw3p.3): Mayor travado → quórum 2-de-3
#   Camada 4 (ga-qw3p.4): quórum falhou → notify 🚨 humano
#
# SINAL DE "TRAVADO" (Athos aprovou via ga-qw3p.2):
#   1. updated_at do bead in_progress > STUCK_AGENT_SEC (padrão 1800s/30min)
#   2. Sessão do assignee ausente/morta (diagnóstico extra, não bloqueia escalação)
#
# ANTI-SPAM: uma escalação por bead por janela COOLDOWN_SEC (padrão 3h).
#   Per-bead state: .gc/state/agent-stuck-escalation/<bead-id>
#   Quando bead sai do in_progress (fecha ou avança) → GC limpa o estado dele.
#
# Launchd: com.gascity.agent-stuck-escalation (StartInterval 300)
# Log: .gc/logs/agent-stuck-escalation.log
# Kill-switch: .gc/state/agent-stuck-escalation.disabled
# DRY_RUN=1: log/notify apenas, sem mail ao Mayor (selftest/supervised)

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
BD="${BD:-bd}"
NOTIFY="${NOTIFY_BIN:-notify}"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/agent-stuck-escalation.log"
STATE_DIR="$CITY/.gc/state"
ESCDIR="$STATE_DIR/agent-stuck-escalation"

STUCK_AGENT_SEC="${STUCK_AGENT_SEC:-1800}"   # 30min sem update → travado
COOLDOWN_SEC="${COOLDOWN_SEC:-10800}"        # 3h antes de re-escalar o mesmo bead
MAYOR_ADDR="${MAYOR_ADDR:-mayor}"
DRY_RUN="${DRY_RUN:-0}"

# Types to skip — utility/infrastructure beads, not work items
SKIP_TYPES="warrant sling wisp"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$ESCDIR"

if [ "$DRY_RUN" != "1" ]; then
    exec >> "$LOG" 2>&1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [agent-stuck] $*"; }

printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/agent-stuck-escalation.startup"

log "=== pass start (PID $$, STUCK=${STUCK_AGENT_SEC}s, COOLDOWN=${COOLDOWN_SEC}s, DRY_RUN=$DRY_RUN) ==="

if [ -f "$STATE_DIR/agent-stuck-escalation.disabled" ]; then
    log "kill-switch active — no-op"
    exit 0
fi

now="$(date +%s)"

# ── Fetch in_progress beads ───────────────────────────────────────────────────
BEADS_RAW="$(timeout 30 "$BD" list --status in_progress --json 2>/dev/null || true)"
if [ -z "$BEADS_RAW" ] || [ "$BEADS_RAW" = "[]" ]; then
    log "no in_progress beads or bd unavailable — healthy, nothing to check"
    # GC state for any leftover state files (all beads closed)
    for sf in "$ESCDIR"/*; do [ -f "$sf" ] && rm -f "$sf"; done
    exit 0
fi

# ── Fetch active session names (for assignee health check) ────────────────────
SESS_RAW="$(timeout 20 "$GC" session list --json 2>/dev/null || true)"
TMP_SESS="$(mktemp)"
printf '%s' "${SESS_RAW:-{\}}" > "$TMP_SESS"
ACTIVE_SESSIONS="$(python3 - "$TMP_SESS" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    for s in (data.get("sessions") or []):
        if s.get("state") == "active":
            n = s.get("name") or s.get("id") or ""
            if n:
                print(n)
except Exception:
    pass
PY
)"
rm -f "$TMP_SESS"

# ── Parse stuck beads ─────────────────────────────────────────────────────────
# Output per line: id|assignee|title|age_secs|updated_at|labels
TMP_BEADS="$(mktemp)"
printf '%s' "$BEADS_RAW" > "$TMP_BEADS"
STUCK_LIST="$(python3 - "$TMP_BEADS" "$now" "$STUCK_AGENT_SEC" "$SKIP_TYPES" <<'PY' || true
import json, sys, time, datetime

with open(sys.argv[1]) as fh:
    raw = fh.read().strip()
now = float(sys.argv[2])
threshold = float(sys.argv[3])
skip = set(sys.argv[4].split())

try:
    beads = json.loads(raw)
except json.JSONDecodeError as e:
    try:
        beads = json.loads(raw[:e.pos])
    except Exception:
        sys.exit(0)
except Exception:
    sys.exit(0)

if not isinstance(beads, list):
    sys.exit(0)

def parse_epoch(s):
    if not s:
        return None
    s = s.strip()
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            return time.mktime(dt.timetuple())
        return dt.timestamp()
    except Exception:
        return None

CURRENT_IDS = set()
for b in beads:
    if not isinstance(b, dict):
        continue
    bead_id = b.get("id") or ""
    if not bead_id:
        continue
    itype = (b.get("issue_type") or b.get("type") or "").lower()
    if itype in skip:
        continue
    updated = (b.get("updated_at") or b.get("updated") or b.get("updatedAt") or "")
    epoch = parse_epoch(updated)
    if epoch is None:
        continue
    age = now - epoch
    if age < threshold:
        print("ok|%s" % bead_id)  # not stuck, but emit ID for GC step
        continue
    assignee = (b.get("assignee") or b.get("owner") or "")
    title = (b.get("title") or b.get("summary") or "?")[:80].replace("|", "_")
    labels = b.get("labels") or []
    labels_str = ",".join(labels) if isinstance(labels, list) else str(labels)
    print("stuck|%s|%s|%d|%s|%s" % (bead_id, assignee, int(age), title, labels_str))
PY
)"
rm -f "$TMP_BEADS"

# Build set of all current in_progress bead IDs (for GC of state files)
ALL_INPROGRESS_IDS=""
STUCK_ITEMS=""
while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%%|*}"
    rest="${line#*|}"
    bead_id="${rest%%|*}"
    [ -z "$bead_id" ] && continue
    ALL_INPROGRESS_IDS="$ALL_INPROGRESS_IDS $bead_id"
    if [ "$kind" = "stuck" ]; then
        STUCK_ITEMS="$STUCK_ITEMS
$rest"
    fi
done <<< "$STUCK_LIST"

# GC: remove state files for beads no longer in in_progress
for sf in "$ESCDIR"/*; do
    [ -f "$sf" ] || continue
    bn="$(basename "$sf")"
    if ! printf '%s' " $ALL_INPROGRESS_IDS " | grep -qF " $bn "; then
        log "$bn: no longer in_progress (closed/advanced) — clearing escalation state"
        rm -f "$sf"
    fi
done

if [ -z "$STUCK_ITEMS" ]; then
    log "no stuck beads (all in_progress beads updated within ${STUCK_AGENT_SEC}s)"
    exit 0
fi

# ── Process each stuck bead ───────────────────────────────────────────────────
while IFS='|' read -r bead_id assignee age_secs title labels; do
    [ -z "$bead_id" ] && continue

    age_min=$(( age_secs / 60 ))
    sf="$ESCDIR/$bead_id"

    # Cooldown: skip if already escalated within COOLDOWN_SEC
    if [ -f "$sf" ]; then
        last_esc="$(head -1 "$sf" 2>/dev/null || echo 0)"
        since_esc=$(( now - last_esc ))
        if [ "$since_esc" -lt "$COOLDOWN_SEC" ]; then
            remaining=$(( (COOLDOWN_SEC - since_esc) / 60 ))
            log "$bead_id: stuck ${age_min}min — already escalated ${since_esc}s ago (cooldown ${remaining}min remaining)"
            continue
        fi
    fi

    # Session health check for assignee
    sess_status="ausente/desconhecida"
    if [ -n "$assignee" ]; then
        if printf '%s\n' "$ACTIVE_SESSIONS" | grep -qx "$assignee"; then
            sess_status="ativa (responde ao session list)"
        else
            # Also try prefix match (gawisp-form)
            base_tmpl="${assignee%%-gawisp*}"
            if printf '%s\n' "$ACTIVE_SESSIONS" | grep -q "^${base_tmpl}"; then
                sess_status="ativa (gawisp-form: $(printf '%s\n' "$ACTIVE_SESSIONS" | grep "^${base_tmpl}" | head -1))"
            else
                sess_status="AUSENTE (nenhuma sessão ativa com nome '$assignee')"
            fi
        fi
    fi

    # Failure markers present?
    failure_markers=""
    if printf '%s' "$labels" | grep -q "gate:needs-human"; then
        failure_markers="${failure_markers}gate:needs-human "
    fi
    if printf '%s' "$labels" | grep -q "story:blocked"; then
        failure_markers="${failure_markers}story:blocked "
    fi
    [ -z "$failure_markers" ] && failure_markers="nenhum"

    log "$bead_id: STUCK ${age_min}min — assignee=$assignee sess=$sess_status labels=$labels"

    # Build diagnostic mail body
    body="$(cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: bead in_progress sem progresso detectado.

Bead:      $bead_id — $title
Assignee:  ${assignee:-'(não atribuído)'}
Sem update há: ${age_min} minutos (limiar: $(( STUCK_AGENT_SEC / 60 )) min)
Sessão:    $sess_status
Marcadores de falha: $failure_markers

AÇÃO SUGERIDA:
1. gc session peek ${assignee:-<assignee>} — confirme se realmente travado ou só lento
2. gc bd show $bead_id — veja estado atual do bead
3. Se travado: shutdown-dance (3 nudges via dog pool) ou kill+re-despache
4. Se misroute: circuit-break (gate:needs-human) e reassinalação ao dono correto
5. Se bead avançou mas updated_at não se moveu: update manual para parar alertas

Limiar configurável via STUCK_AGENT_SEC (atual: ${STUCK_AGENT_SEC}s).
(Daemon: agent-stuck-escalation · ga-qw3p.2)
BODY
)"

    if [ "$DRY_RUN" = "1" ]; then
        log "  [DRY_RUN] would send Mayor mail + notify for $bead_id"
        log "  [DRY_RUN] subject: Agente travado: $bead_id (${age_min}min sem progresso)"
        printf '%s' "$now" > "$sf"
        continue
    fi

    # imp07 invariant: notify FIRST (Dolt-independent), mail SECONDARY (best-effort)
    if command -v "$NOTIFY" >/dev/null 2>&1; then
        "$NOTIFY" -t "Agente travado" -p 4 \
            "$bead_id (${assignee:-?}) sem progresso há ${age_min}min — escalando ao Mayor" \
            >/dev/null 2>&1 || true
    fi

    if timeout 45 "$GC" mail send "$MAYOR_ADDR" \
            -s "Agente travado: $bead_id — ${age_min}min sem progresso (assignee=${assignee:-?})" \
            -m "$body" \
            >/dev/null 2>&1; then
        log "  mail enviado ao Mayor para $bead_id"
        printf '%s\n' "$now" > "$sf"
    else
        log "  WARN: gc mail send falhou para $bead_id — notify já disparado"
        # Record partial escalation (notify fired) so we respect cooldown
        printf '%s\n' "$now" > "$sf"
    fi

done <<< "$STUCK_ITEMS"

log "=== pass complete ==="
exit 0
