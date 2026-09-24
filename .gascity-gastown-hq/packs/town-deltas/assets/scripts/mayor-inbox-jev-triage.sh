#!/usr/bin/env bash
# mayor-inbox-jev-triage.sh (ga-aijm2v.2 -- Jev F1: pre-triagem da caixa do Mayor)
#
# WHY: ga-aijm2v measured 85 Mayor wake-ups/24h (65 e-mails + 20 lembretes),
# ~70 sem acao nenhuma. This is the Mayor-inbox slice of that fix: for each
# NEW automated watchdog e-mail, ask Jev (scripts/jev_experiment.py, same
# harness as wa-dln9g / gate-orphaned-label-watchdog.sh) "does this need
# Mayor action now?" -- A/B experiment "mayor-inbox". Experiment arm: if Jev
# is >=85% confident NO, archive (gc mail archive) + log. Control arm: never
# calls Jev, never archives (that IS control, by construction of
# jev_experiment.py's own assign_arm/evaluate). Third state (Jev down /
# error / unsure): never archive -- suppress defaults to False on any
# jev_ok=False inside evaluate() itself; nothing extra needed here to honor
# "nunca arquivar na duvida".
#
# THE "from" FIELD IS NOT USABLE TO DETECT AUTOMATED SENDERS (verified
# live 2026-09-24, ga-aijm2v.2): gc mail's sender resolution falls back to
# the literal string "human" whenever $GC_SESSION_ID/$GC_ALIAS/$GC_AGENT are
# unset (cmd_mail.go, sender-resolution candidate list) -- true for every
# launchd/gc-order-run watchdog in this city (dolt-disk-floor-guard,
# gate-orphaned-label-watchdog, city-health-sentinel, ...), none of which
# pass --from. Checked against gastown.mayor's real live inbox the day this
# was written: 5/5 unread messages showed from="human" while being
# unmistakably automated (gate-PASS-held x2, disk-floor-critical x2,
# city-health-sentinel). So "never touch human mail" is enforced here NOT by
# checking `from` (uninformative -- it says "human" for real humans AND for
# most automation) but by a POSITIVE allowlist: a message is only ever a
# candidate for Jev+archiving if its SUBJECT matches one of the literal,
# source-verified patterns in WATCHDOG_PATTERNS below (each copied from the
# actual `-s "..."` string in the watchdog script that sends it -- grep-
# verified against this repo's scripts/, not guessed). Anything that doesn't
# match is left completely alone, exactly like the "human" bucket would have
# been -- a stricter, more direct check than trusting an identity field that
# is currently uninformative for this purpose. Growing coverage (adding more
# verified patterns to the registry) is the intended way to increase
# suppression over time; v1 here is deliberately conservative, not
# exhaustive -- see the epic (ga-aijm2v) for the fuller "85 despertares"
# breakdown and why some categories are excluded on purpose (next).
#
# EXPLICITLY EXCLUDED from the registry, on purpose:
#   - "Dolt disk-floor CRITICAL/RECOVERED" -- the epic itself calls this out
#     as MAIS BARATO QUE JEV (a fixed dedup rule, not an AI judgment;
#     separate bead ga-4f4opx). Asking Jev to re-judge an identical
#     repeating alert every cycle would be pure waste.
#   - "Decisao pendente: ..." (next-action-coordinator-alert.sh) and any
#     other explicit decision-request pattern -- those exist SPECIFICALLY to
#     demand Mayor's attention; asking Jev whether to suppress one would
#     undermine the mechanism that produces it.
#
# DEDUP: SEEN_FILE remembers every message id already evaluate()'d (any
# arm/outcome), so a still-unread, non-archived message (control arm, Jev
# said needs-action, Jev errored) is NOT re-asked every tick -- the
# message's text never changes, so re-asking would waste real Jev tokens and
# duplicate JEV_LOG lines with no new information. This is a permanent
# per-id ledger, not a cooldown re-fire (unlike next-action-coordinator-
# alert's, where the underlying condition can still be true later). Pruned
# each run to ids still present in the live inbox, so it stays bounded to
# roughly inbox size.
#
# DEPLOYMENT: registered as a `gc order` (cooldown trigger), not a launchd
# plist -- orders/*.toml are read directly by the city controller each tick,
# with no repo-to-~/Library/LaunchAgents copy/sync step to go stale (a real
# incident class in this city: wa-bq3ng, a plist fix mergeed but dormant for
# 1h until someone copied it by hand). See
# packs/town-deltas/orders/mayor-inbox-jev-triage.toml.
set -euo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC_BIN="${GC_BIN:-gc}"
JEV_BIN="${JEV_BIN:-python3 $CITY/scripts/jev_experiment.py}"
MAYOR_ADDR="${MAYOR_ADDR:-gastown.mayor}"
EXPERIMENT_NAME="mayor-inbox"
CONFIDENCE="${MAYOR_INBOX_TRIAGE_CONFIDENCE:-0.85}"
MAX_PER_RUN="${MAYOR_INBOX_TRIAGE_MAX_PER_RUN:-20}"
STATE_TEXT_MAX_CHARS=3000

STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
SEEN_FILE="${MAYOR_INBOX_TRIAGE_SEEN_FILE:-$STATE_DIR/mayor-inbox-jev-triage-seen.json}"
LOG_FILE="${MAYOR_INBOX_TRIAGE_LOG_FILE:-$CITY/.gc/logs/mayor-inbox-jev-triage.log}"
DISABLE_FILE="$STATE_DIR/mayor-inbox-jev-triage.disabled"

DRY_RUN="${MAYOR_INBOX_TRIAGE_DRY_RUN:-0}"
ENABLED="${MAYOR_INBOX_TRIAGE_ENABLED:-1}"

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true
    echo "$*"
}

if [ "$ENABLED" != "1" ]; then
    echo "mayor-inbox-jev-triage: disabled via MAYOR_INBOX_TRIAGE_ENABLED=$ENABLED -- skipping"
    exit 0
fi
if [ -f "$DISABLE_FILE" ]; then
    echo "mayor-inbox-jev-triage: disabled via $DISABLE_FILE -- skipping"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE" 2>/dev/null || true
SEEN_JSON=$(cat "$SEEN_FILE" 2>/dev/null || echo '{}')
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'

# WATCHDOG_PATTERNS: "tipo<TAB>ERE regex anchored at the subject start".
# Each regex is copied verbatim (prefix only; dynamic suffix dropped) from a
# grep-verified `-s "..."` call site in this repo's scripts/ tree -- see the
# header comment for why subject-matching, not `from`, is the eligibility
# gate. Adding a new watchdog: copy its literal subject prefix here with a
# new tipo name; do not loosen an existing pattern to "catch more".
WATCHDOG_PATTERNS='
gate-pass-held	^Your gate PASS is held for
watchdog-gate-marker-missing	^Watchdog: [0-9]+ gate marker/run\(s\) missing gate-status
watchdog-gate-orphaned-label	^Watchdog: [0-9]+ bead\(s\) com gate:\* label
watchdog-pilot-missing-route	^Watchdog: [0-9]+ armed bead\(s\) missing gc\.routed_to
daemon-presence	^Daemon-presence:
recycler-chronic-leak	^Recycler: chronic leak
city-health-sentinel	^\[city-health-sentinel\] alert
flow-healer	^Flow-healer:
order-exec	^Order-exec:
'

classify_tipo() {
    local subject="$1" tipo pattern
    while IFS="$(printf '\t')" read -r tipo pattern; do
        [ -z "$tipo" ] && continue
        if printf '%s' "$subject" | grep -qE "$pattern"; then
            printf '%s' "$tipo"
            return 0
        fi
    done <<EOF_PAT
$WATCHDOG_PATTERNS
EOF_PAT
    return 1
}

extract_entidade() {
    # First bead-id-looking token (wa-/ga-/ps-/dc-/lexbh-<alnum>) found in
    # the given text, else empty (caller falls back to tipo alone).
    printf '%s' "$1" | grep -oE '\b(wa|ga|ps|dc|lexbh)-[a-z0-9]+\b' | head -1 || true
}

messages_json=$(timeout 30 "$GC_BIN" mail inbox "$MAYOR_ADDR" --json 2>/dev/null) || {
    log "mayor-inbox-jev-triage: gc mail inbox failed -- skipping this run"
    exit 0
}
[ -n "$messages_json" ] || messages_json='{"messages":[]}'

# Prune SEEN_JSON to ids still present in the live inbox (bounded growth --
# an id that vanished was either archived by us or handled by Mayor/human;
# either way there is nothing left to dedup against).
live_ids_json=$(printf '%s' "$messages_json" | jq -c '[.messages[].id]' 2>/dev/null) || live_ids_json='[]'
SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --argjson live "$live_ids_json" \
    'to_entries | map(select(.key as $k | $live | index($k))) | from_entries' 2>/dev/null) || SEEN_JSON='{}'
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'

total_seen=0
total_eligible=0
total_archived=0
total_would_archive=0
processed_this_run=0

ids_and_fields=$(printf '%s' "$messages_json" | jq -r '.messages[] | [.id, (.from // ""), .subject] | @tsv' 2>/dev/null) || ids_and_fields=""

while IFS="$(printf '\t')" read -r mid mfrom msubject; do
    [ -n "$mid" ] || continue
    total_seen=$((total_seen + 1))

    already=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "$mid" 'has($k)' 2>/dev/null || echo false)
    [ "$already" = "true" ] && continue

    [ "$processed_this_run" -ge "$MAX_PER_RUN" ] && continue

    tipo=$(classify_tipo "$msubject") || continue
    total_eligible=$((total_eligible + 1))

    mbody=$(printf '%s' "$messages_json" | jq -r --arg id "$mid" '.messages[] | select(.id == $id) | .body // ""' 2>/dev/null) || mbody=""
    entidade=$(extract_entidade "$msubject")
    [ -n "$entidade" ] || entidade=$(extract_entidade "$mbody")
    [ -n "$entidade" ] || entidade="$tipo"
    entity_id="${tipo}:${entidade}"

    state_file=$(mktemp)
    printf 'Assunto: %s\n\n%s' "$msubject" "$mbody" | head -c "$STATE_TEXT_MAX_CHARS" > "$state_file"

    jev_result=$($JEV_BIN evaluate \
        --entity-id "$entity_id" \
        --experiment "$EXPERIMENT_NAME" \
        --state-file "$state_file" \
        --question-key "needs_mayor_action" \
        --instructions "Este e-mail chegou na caixa de gastown.mayor (orquestrador de uma cidade de agentes autonomos), enviado por um watchdog/guard automatizado. O Mayor precisa agir AGORA (ler, investigar, decidir algo), ou e seguro deixar pra depois -- por ser alerta rotineiro, estado ja conhecido/documentado, ou algo que o proprio watchdog resolve no proximo ciclo?" \
        --true-desc "Precisa de acao do Mayor agora -- problema real e novo, nao so um estado rotineiro/esperado" \
        --false-desc "Seguro esperar -- alerta rotineiro do watchdog, ja documentado, ou se resolve sozinho" \
        --confidence "$CONFIDENCE" \
        --heuristic-would-escalate 2>/dev/null) || jev_result=""
    rm -f "$state_file" 2>/dev/null || true

    arm=$(printf '%s' "$jev_result" | jq -r '.arm // "unknown"' 2>/dev/null || echo unknown)
    suppress=$(printf '%s' "$jev_result" | jq -r 'if .suppress == true then "1" else "0" end' 2>/dev/null || echo 0)
    jev_error=$(printf '%s' "$jev_result" | jq -r '.jev_error // ""' 2>/dev/null || echo "")

    action="left"
    if [ "$suppress" = "1" ] && [ "$arm" = "experiment" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            action="would_archive"
            total_would_archive=$((total_would_archive + 1))
        elif timeout 30 "$GC_BIN" mail archive "$mid" >/dev/null 2>&1; then
            action="archived"
            total_archived=$((total_archived + 1))
        else
            action="archive_failed"
            log "mayor-inbox-jev-triage: WARN gc mail archive failed for $mid"
        fi
    fi

    log "mayor-inbox-jev-triage: id=$mid from=$mfrom tipo=$tipo entidade=$entidade arm=$arm suppress=$suppress jev_error=${jev_error:-none} action=$action"

    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "$mid" --arg a "$action" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.[$k] = {action: $a, ts: $ts}' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
    processed_this_run=$((processed_this_run + 1))
done <<EOF_MSGS
$ids_and_fields
EOF_MSGS

printf '%s' "$SEEN_JSON" > "$SEEN_FILE" 2>/dev/null || true

echo "mayor-inbox-jev-triage: inbox=$total_seen eligible=$total_eligible processed=$processed_this_run archived=$total_archived would_archive=$total_would_archive"
