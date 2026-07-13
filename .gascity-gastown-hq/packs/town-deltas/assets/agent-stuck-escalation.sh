#!/usr/bin/env bash
# agent-stuck-escalation.sh — Camada 2 da hierarquia de escalação autônoma (ga-qw3p.2).
#
# CONTEXTO (épico ga-qw3p):
#   Camada 1 (ga-qw3p.1): roteamento por tópico → crew certo
#   Camada 2 (ESTA):       sem progresso em 30min → Mayor
#   Camada 3 (ga-qw3p.3): Mayor travado → quórum 2-de-3
#   Camada 4 (ga-qw3p.4): quórum falhou → notify 🚨 humano
#
# SINAL DE "TRAVADO" (Athos aprovou o gate original via ga-qw3p.2; ga-hehi
# corrigiu o item 2 — sessão viva nunca provou progresso, ver abaixo):
#   1. updated_at do bead in_progress > STUCK_AGENT_SEC (padrão 1800s/30min)
#   2. E transcript da sessão do assignee CONGELADO (sem escrita há
#      TRANSCRIPT_FRESH_SEC, padrão = STUCK_AGENT_SEC) OU sessão ausente/morta.
#      Transcript AVANÇANDO (escrita recente) SUPRIME a escalação — trabalho
#      longo legítimo (tool calls, streaming) não gera falso-positivo.
#      Ver transcript_is_advancing() abaixo.
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
TRANSCRIPT_FRESH_SEC="${TRANSCRIPT_FRESH_SEC:-$STUCK_AGENT_SEC}"  # ga-hehi: transcript escrito há menos disso = avançando
MAYOR_ADDR="${MAYOR_ADDR:-mayor}"
DRY_RUN="${DRY_RUN:-0}"
# Bead stores to scan (space-separated paths; HQ must be .gascity-gastown-hq, NOT the gt root)
ESCALATION_STORES="${ESCALATION_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"

# ── Escalation router (Layer 1, ga-qw3p.1) ───────────────────────────────────
# Source in library mode to get classify/route functions. Fail-open: if the
# router is absent, all escalations fall back to Mayor (zero regression).
_ROUTER="${CITY}/packs/town-deltas/assets/escalation-router.sh"
_ROUTER_AVAILABLE=0
if [ -f "$_ROUTER" ] && [ -r "$_ROUTER" ]; then
    # shellcheck source=/dev/null
    ESCALATION_CITY="$CITY" . "$_ROUTER" --lib 2>/dev/null && _ROUTER_AVAILABLE=1
fi

# Types to skip — utility/infrastructure beads, not work items
SKIP_TYPES="warrant sling wisp"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$ESCDIR"

if [ "$DRY_RUN" != "1" ]; then
    exec >> "$LOG" 2>&1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [agent-stuck] $*"; }

# transcript_is_advancing (ga-hehi): a live session is NOT proof of progress —
# `gc session list` shows "active" whether the agent is busy or genuinely
# wedged (same finding that shaped crew-hang-detector.sh — idle and hung
# sessions are indistinguishable by session state alone). The real progress
# signal is the session's transcript .jsonl file: it grows on every tool call
# / message boundary while real work happens, and stays byte-still when the
# agent is truly hung. Returns 0 ("advancing") only when that file was
# written to within TRANSCRIPT_FRESH_SEC. Any lookup failure (gc error,
# missing path, missing file) returns 1 ("not advancing") — fails CLOSED, so
# an unknown state still escalates, same as today's absent-session path.
transcript_is_advancing() {
    local sess="$1" logs_json tpath mtime age
    logs_json="$(timeout 15 "$GC" session logs "$sess" --tail 1 --json 2>/dev/null || true)"
    [ -z "$logs_json" ] && return 1
    tpath="$(printf '%s' "$logs_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("transcript_path") or "")
except Exception:
    print("")
' 2>/dev/null)"
    [ -z "$tpath" ] && return 1
    [ -f "$tpath" ] || return 1
    mtime="$(stat -f %m "$tpath" 2>/dev/null || stat -c %Y "$tpath" 2>/dev/null || echo "")"
    [ -z "$mtime" ] && return 1
    age=$(( now - mtime ))
    [ "$age" -lt "$TRANSCRIPT_FRESH_SEC" ]
}

printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/agent-stuck-escalation.startup"

log "=== pass start (PID $$, STUCK=${STUCK_AGENT_SEC}s, COOLDOWN=${COOLDOWN_SEC}s, DRY_RUN=$DRY_RUN) ==="

if [ -f "$STATE_DIR/agent-stuck-escalation.disabled" ]; then
    log "kill-switch active — no-op"
    exit 0
fi

now="$(date +%s)"

# ── Fetch in_progress beads (multi-store: HQ + WA + PS) ──────────────────────
# Collect each store's results into a temp file (separator-delimited) then merge
# in Python. Per-store failures are non-fatal (skipped). Dedup by bead id.
_TMP_PARTS="$(mktemp)"
for _store in $ESCALATION_STORES; do
    [ -d "$_store" ] || continue
    _part="$(timeout 30 "$BD" -C "$_store" list --status in_progress --json 2>/dev/null || true)"
    [ -z "$_part" ] || [ "$_part" = "[]" ] && continue
    printf '%s\n###STORESEP###\n' "$_part" >> "$_TMP_PARTS"
done
BEADS_RAW="$(python3 - "$_TMP_PARTS" <<'PY' || true
import json, sys
seen = {}
parts = open(sys.argv[1]).read().split('###STORESEP###')
for p in parts:
    p = p.strip()
    if not p:
        continue
    try:
        for b in json.loads(p) or []:
            bid = b.get('id', '')
            if bid and bid not in seen:
                seen[bid] = b
    except Exception:
        pass
print(json.dumps(list(seen.values())))
PY
)"
rm -f "$_TMP_PARTS"
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
    live_session_name=""
    if [ -n "$assignee" ]; then
        if printf '%s\n' "$ACTIVE_SESSIONS" | grep -qx "$assignee"; then
            sess_status="ativa (responde ao session list)"
            live_session_name="$assignee"
        else
            # Also try prefix match (gawisp-form)
            base_tmpl="${assignee%%-gawisp*}"
            gawisp_match="$(printf '%s\n' "$ACTIVE_SESSIONS" | grep "^${base_tmpl}" | head -1)"
            if [ -n "$gawisp_match" ]; then
                sess_status="ativa (gawisp-form: $gawisp_match)"
                live_session_name="$gawisp_match"
            else
                sess_status="AUSENTE (nenhuma sessão ativa com nome '$assignee')"
            fi
        fi
    fi

    # Transcript-progress gate (ga-hehi): a live session alone never proved
    # progress. If the assignee has a live session AND its transcript was
    # written to recently, this is legitimate long-running work — suppress
    # escalation entirely (log-only; no state file write, so a real freeze on
    # a later pass still escalates normally, undelayed by this suppression).
    if [ -n "$live_session_name" ] && transcript_is_advancing "$live_session_name"; then
        log "$bead_id: bead.updated_at parado ${age_min}min mas transcript de $live_session_name avançando (escrita <${TRANSCRIPT_FRESH_SEC}s) — SUPRIMINDO escalação (trabalho longo legítimo)"
        continue
    fi
    transcript_note="n/d (sem sessão viva)"
    [ -n "$live_session_name" ] && transcript_note="CONGELADO (sem escrita há >=${TRANSCRIPT_FRESH_SEC}s)"

    # Failure markers present?
    failure_markers=""
    if printf '%s' "$labels" | grep -q "gate:needs-human"; then
        failure_markers="${failure_markers}gate:needs-human "
    fi
    if printf '%s' "$labels" | grep -q "story:blocked"; then
        failure_markers="${failure_markers}story:blocked "
    fi
    [ -z "$failure_markers" ] && failure_markers="nenhum"

    log "$bead_id: STUCK ${age_min}min — assignee=$assignee sess=$sess_status transcript=$transcript_note labels=$labels"

    # Build diagnostic mail body
    body="$(cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: bead in_progress sem progresso detectado.

Bead:      $bead_id — $title
Assignee:  ${assignee:-'(não atribuído)'}
Sem update há: ${age_min} minutos (limiar: $(( STUCK_AGENT_SEC / 60 )) min)
Sessão:    $sess_status
Transcript: $transcript_note
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

    # Layer 1 routing (ga-qw3p.1): classify bead title+labels to find domain owner.
    # Falls back to Mayor when router unavailable or topic unrecognised.
    _esc_target="$MAYOR_ADDR"
    _esc_topic=""
    if [ "$_ROUTER_AVAILABLE" = "1" ] && command -v escalation_classify_topic >/dev/null 2>&1; then
        _esc_topic=$(escalation_classify_topic "$title $labels" 2>/dev/null || echo "")
        if [ -n "$_esc_topic" ]; then
            _esc_target=$(escalation_topic_to_crew "$_esc_topic" 2>/dev/null || echo "$MAYOR_ADDR")
        fi
    fi
    log "$bead_id: escalation target=$_esc_target (topic=${_esc_topic:-none})"

    if [ "$DRY_RUN" = "1" ]; then
        log "  [DRY_RUN] would send mail to $_esc_target for $bead_id"
        log "  [DRY_RUN] subject: Agente travado: $bead_id (${age_min}min sem progresso)"
        printf '%s' "$now" > "$sf"
        continue
    fi

    # imp07 invariant: notify FIRST (Dolt-independent), mail SECONDARY (best-effort)
    if command -v "$NOTIFY" >/dev/null 2>&1; then
        "$NOTIFY" -t "Agente travado" -p 4 \
            "$bead_id (${assignee:-?}) sem progresso há ${age_min}min — escalando → ${_esc_target}" \
            >/dev/null 2>&1 || true
    fi

    if timeout 45 "$GC" mail send "$_esc_target" \
            -s "Agente travado: $bead_id — ${age_min}min sem progresso (assignee=${assignee:-?})" \
            -m "$body" \
            >/dev/null 2>&1; then
        log "  mail enviado a $_esc_target (topic=${_esc_topic:-none}) para $bead_id"
        printf '%s\n' "$now" > "$sf"
    else
        log "  WARN: gc mail send falhou para $bead_id — notify já disparado"
        # Record partial escalation (notify fired) so we respect cooldown
        printf '%s\n' "$now" > "$sf"
    fi

done <<< "$STUCK_ITEMS"

log "=== pass complete ==="
exit 0
