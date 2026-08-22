#!/usr/bin/env bash
# next-action-coordinator-alert.sh (ga-njj5zk)
#
# Proactive safety net for ga-1ygf6o's next-action:<coordinator> convention:
# a crew that pauses waiting on a Mayor/deacon decision is supposed to write
# next-action:mayor (or next-action:deacon) + a "Pergunta:" comment onto the
# bead BEFORE going quiet. bead_state.py already classifies that bead as
# parked (not executing) and painel_visibilidade.py already renders it — but
# nothing PUSHES the coordinator a notification if they never go looking.
# Root incident: wa-u6ak0 sat 76min this way, found only by an unrelated
# alarm passing nearby (ga-1ygf6o).
#
# Scope deliberately narrow: only the two COORDINATOR_MARKERS targets
# (bead_state.py:329 — "mayor", "deacon"), never next-action:athos (already
# covered by the WA painel's own Sua-vez routing) and never
# next-action:<crew>-constroi (a different concept — build routing, already
# covered by approved-state-reconciler.py).
#
# Detection+alert only: mirrors stale-persistent-daemon-guard.sh's shape
# (file-based JSON seen-ledger keyed by store|bead|target, cooldown-gated
# re-fire, notify for immediate paging + gc mail send for durability across
# a coordinator's own session restart — same reasoning agent-stuck-
# escalation.sh already uses mail for real escalations). Never labels,
# never reassigns, never closes anything.
#
# Dedup is FILE-based (SEEN_FILE), not in-process memory — learned from
# wa-khond: an in-memory-only ledger dies on every daemon/order-runner
# restart and produces a re-alert storm on the next tick. Runs as a gc
# order (cooldown trigger, fresh exec each tick), same reasoning as
# stale-persistent-daemon-guard.sh for why this is an order and not a raw
# KeepAlive plist.
set -euo pipefail

CITY_DEFAULT="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
# Same store list as agent-stuck-escalation.sh's ESCALATION_STORES (kept as
# an independent env var so tuning one guard's scan scope never silently
# retunes the other's).
STORES="${NEXT_ACTION_ALERT_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
BD_BIN="${BD_BIN:-bd}"
GC_BIN="${GC_BIN:-gc}"
NOTIFY_BIN="${NOTIFY_BIN:-notify}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY_DEFAULT/.gc/runtime}/packs/maintenance}"
SEEN_FILE="${NEXT_ACTION_ALERT_SEEN_FILE:-$STATE_DIR/next-action-coordinator-alert-seen.json}"
COOLDOWN_SEC="${NEXT_ACTION_ALERT_COOLDOWN_S:-14400}"   # 4h re-fire while still unaddressed
MAYOR_ADDR="${MAYOR_ADDR:-mayor}"
DEACON_ADDR="${DEACON_ADDR:-deacon}"
NOW=$(date +%s)

DISABLE_FILE="$STATE_DIR/next-action-coordinator-alert.disabled"
if [ -f "$DISABLE_FILE" ]; then
    echo "next-action-coordinator-alert: disabled via $DISABLE_FILE — skipping"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE" 2>/dev/null || true
SEEN_JSON=$(cat "$SEEN_FILE" 2>/dev/null || echo '{}')
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'

# due_for_alert: cooldown gate keyed by "<store>|<bead_id>|<target>". True
# (fire) iff never alerted or past COOLDOWN_SEC since the last one — a
# re-fire cadence, not a permanent silence, so a bead nobody ever answers
# doesn't go quiet forever (mirrors stale-persistent-daemon-guard's
# notify_once semantics exactly).
due_for_alert() {
    local key="$1" last
    last=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "$key" '.[$k] // 0' 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ "$last" = "0" ] || [ $(( NOW - last )) -ge "$COOLDOWN_SEC" ]
}

mark_alerted() {
    local key="$1"
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "$key" --argjson n "$NOW" '.[$k] = $n' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
}

# latest_pergunta: the most recent comment whose text starts with
# "Pergunta:" (the convention documented in town-deltas.template.md), or
# empty if the bead has none / is unreadable. Never fabricates content —
# an absent or unreadable comment must surface as an explicit fallback
# string at the call site, never as silence indistinguishable from "read
# fine, no question written" (error and empty must not produce the same
# value).
latest_pergunta() {
    local store="$1" id="$2" json
    json=$("$BD_BIN" -C "$store" show "$id" --json --include-comments 2>/dev/null) || return 1
    [ -n "$json" ] || return 1
    printf '%s' "$json" | jq -r '
        (if type=="array" then .[0] else . end) as $b
        | [$b.comments[]? | select(.text // "" | startswith("Pergunta:"))]
        | last // empty
        | .text // empty' 2>/dev/null
}

total_found=0
total_alerted=0

for store in $STORES; do
    [ -d "$store" ] || continue
    # ga-njj5zk gate-fix: ONE call per store for both statuses via the
    # comma-separated form, not two separate --status invocations — bd
    # list's own --help warns that repeating -s/--status silently
    # overwrites the previous value, so two calls also halves Dolt round-
    # trips per store per tick (this order runs every 15m across 3 stores).
    beads_json=$("$BD_BIN" -C "$store" list --status open,in_progress --json --limit 0 2>/dev/null) || continue
    [ -n "$beads_json" ] || continue

    for target in mayor deacon; do
        label="next-action:$target"
        ids=$(printf '%s' "$beads_json" | jq -r --arg l "$label" \
            '.[] | select((.labels // []) | index($l)) | .id' 2>/dev/null) || continue
        [ -n "$ids" ] || continue

        while IFS= read -r id; do
            [ -n "$id" ] || continue
            total_found=$((total_found + 1))
            key="$store|$id|$target"
            due_for_alert "$key" || continue

            addr="$MAYOR_ADDR"
            [ "$target" = "deacon" ] && addr="$DEACON_ADDR"

            question=$(latest_pergunta "$store" "$id") || question=""
            if [ -z "$question" ]; then
                question="(nenhum comentário 'Pergunta:' encontrado — abra a bead pra ver o contexto)"
            fi

            subject="Decisão pendente: $id (next-action:$target)"
            body="Bead $id está parada esperando sua decisão (next-action:$target).

$question

Store: $store
(next-action-coordinator-alert, ga-njj5zk — rede de segurança; a convenção
pede que quem pausou já tenha gravado a pergunta na bead. Re-alerta a cada
$((COOLDOWN_SEC / 3600))h enquanto o label continuar presente.)"

            if command -v "$NOTIFY_BIN" >/dev/null 2>&1; then
                "$NOTIFY_BIN" -t "Decisão pendente" -p 3 \
                    "$id aguarda decisão de $target (próx: $target) — ver mail" \
                    >/dev/null 2>&1 || true
            fi

            # Ledger is marked regardless of mail outcome — notify already
            # fired as the primary immediate channel; mail is best-effort
            # durability on top (same reasoning as agent-stuck-
            # escalation.sh's send_escalation, which does not retry a
            # failed mail send every tick either).
            if timeout 45 "$GC_BIN" mail send "$addr" -s "$subject" -m "$body" >/dev/null 2>&1; then
                echo "next-action-coordinator-alert: alertado $addr para $id ($target)"
                "$BD_BIN" -C "$store" comment "$id" \
                    "next-action-coordinator-alert (ga-njj5zk): alerta proativo enviado a $addr — ver mail." \
                    >/dev/null 2>&1 || true
            else
                echo "next-action-coordinator-alert: WARN — mail send falhou para $id ($target), notify já disparado"
            fi
            mark_alerted "$key"
            total_alerted=$((total_alerted + 1))
        done <<EOF_IDS
$ids
EOF_IDS
    done
done

echo "$SEEN_JSON" > "$SEEN_FILE" 2>/dev/null || true

if [ "$total_found" -gt 0 ]; then
    echo "next-action-coordinator-alert: $total_alerted/$total_found next-action:mayor|deacon bead(s) alerted this pass"
fi
