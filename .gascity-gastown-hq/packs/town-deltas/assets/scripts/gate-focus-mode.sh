#!/usr/bin/env bash
# gate-focus-mode.sh (ga-kqa08j) — decides whether the city is in GATE FOCUS MODE.
#
# WHY (Athos, 07/10/2026, verbatim): "não faz sentido a gente ter dezenas de beads no
# gate e ainda spawnar workers pra construir beads. Temos que ter algum mecanismo que
# entende que o gargalo virou o gate e focar os recursos de worker genéricos em
# reviewers e não em construtores." Measured that night: 41 real markers queued, 1
# reviewer running against 10 builder sessions, load ~50/10 cores, reviewer spawns
# failing on Dolt i/o timeouts. Every builder that finishes only deepens the queue.
#
# RULE (his choices, AskUserQuestion in the Mayor session, 07/10 ~04:1x):
#   enter  when the gate queue is ABOVE GATE_FOCUS_ENTER (15)
#   leave  when it drops BELOW GATE_FOCUS_EXIT (8)
#   In between the mode keeps whatever it was (hysteresis: no flapping every sweep).
#   One notification when the mode turns on and one when it turns off — never per run.
#   What the mode DOES is up to its readers (Pilot: no new builds, fixes with at most 2
#   builders; eval-window-concurrency-guard.sh: dog cap at most 2). Crews are never
#   touched. This script only decides and records.
#
# THREE STATES for the depth: a number, or "could not read". An unreadable depth keeps
# the previous mode, logs UNREADABLE, notifies nobody and does NOT refresh `at` — so a
# long blind stretch goes stale in gate-focus-lib.sh and every reader falls back to
# "unknown" (= not active, fail-open) instead of trusting a mode nobody re-checked.
#
# DEPTH = markers labelled gate-status:queued (the gate's own queue), counted with
# --limit 0 (bd list truncates at 50 silently otherwise, ga-21kmp) and --include-infra
# (markers are ephemeral and invisible without it, ga-vm20x). It does not subtract the
# few phantom markers gate-queue-composition.sh can find (that script fetches git per
# rig and is too heavy for a 5-min loop); the overcount errs toward focus.
#
# STATE  $GC_CITY/.gc/gate-focus.state   active=0|1 since=<epoch> depth=<n> at=<epoch>
# LOG    $GC_CITY/.gc/logs/gate-focus-mode.log
# OFF    touch $GC_CITY/.gc/gate-focus.off   -> mode forced OFF (exit notified once)
# Single instance (mkdir lock); launchd StartInterval 300.
# Test seams: GATE_FOCUS_DEPTH_OVERRIDE (number or "unreadable"), GATE_FOCUS_NOTIFY_CMD,
# GATE_FOCUS_NOW, DRY_RUN=1 (decide + log, write and notify nothing).

set -u

GC_CITY="${GC_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}"
GATE_FOCUS_ENTER="${GATE_FOCUS_ENTER:-15}"
GATE_FOCUS_EXIT="${GATE_FOCUS_EXIT:-8}"
GATE_FOCUS_MAX_S="${GATE_FOCUS_MAX_S:-86400}"   # one escalation if ON longer than this
GATE_FOCUS_STATE_FILE="${GATE_FOCUS_STATE_FILE:-$GC_CITY/.gc/gate-focus.state}"
GATE_FOCUS_OFF_FILE="${GATE_FOCUS_OFF_FILE:-$GC_CITY/.gc/gate-focus.off}"
GATE_FOCUS_LOG="${GATE_FOCUS_LOG:-$GC_CITY/.gc/logs/gate-focus-mode.log}"
GATE_FOCUS_LOCK="${GATE_FOCUS_LOCK:-$GC_CITY/.gc/gate-focus.lock}"
GATE_FOCUS_NOTIFY_CMD="${GATE_FOCUS_NOTIFY_CMD:-notify}"
BD="${BD:-bd}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '[%s] [gate-focus] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$GATE_FOCUS_LOG" 2>/dev/null \
          || printf '[gate-focus] %s\n' "$*" >&2; }

_field() { [ -r "$GATE_FOCUS_STATE_FILE" ] && sed -n "s/^$1=//p" "$GATE_FOCUS_STATE_FILE" 2>/dev/null | head -n 1; }

# measure_depth — prints a non-negative integer, or "unreadable".
measure_depth() {
  if [ -n "${GATE_FOCUS_DEPTH_OVERRIDE:-}" ]; then printf '%s' "$GATE_FOCUS_DEPTH_OVERRIDE"; return 0; fi
  local raw n
  raw="$(GC_CITY="$GC_CITY" timeout 60 "$BD" -C "$GC_CITY" list --json --include-infra --limit 0 \
           -l type:quality-gate-marker -l gate-status:queued 2>/dev/null)" || { printf 'unreadable'; return 0; }
  n="$(printf '%s' "$raw" | jq 'if type=="array" then length else error("not an array") end' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) printf 'unreadable' ;; *) printf '%s' "$n" ;; esac
}

# decide <prev_active 0|1> <depth> -> prints next active 0|1 (pure; selftest calls it).
decide() {
  local prev="$1" d="$2"
  if [ "$prev" = "1" ]; then
    [ "$d" -lt "$GATE_FOCUS_EXIT" ] && { printf '0'; return; }
    printf '1'
  else
    [ "$d" -gt "$GATE_FOCUS_ENTER" ] && { printf '1'; return; }
    printf '0'
  fi
}

write_state() { # active since depth at [escalated]
  [ "$DRY_RUN" = "1" ] && return 0
  local tmp="${GATE_FOCUS_STATE_FILE}.tmp.$$"
  mkdir -p "$(dirname "$GATE_FOCUS_STATE_FILE")" 2>/dev/null
  printf 'active=%s\nsince=%s\ndepth=%s\nat=%s\nescalated=%s\n' "$1" "$2" "$3" "$4" "${5:-0}" >"$tmp" && mv -f "$tmp" "$GATE_FOCUS_STATE_FILE"
}

send_notify() { # title priority message
  [ "$DRY_RUN" = "1" ] && { log "[DRY_RUN] would notify: $1 — $3"; return 0; }
  "$GATE_FOCUS_NOTIFY_CMD" -t "$1" -p "$2" "$3" >/dev/null 2>&1 \
    || log "WARN: notify failed (title='$1') — the mode change itself is recorded in the state file"
}

main() {
  mkdir -p "$(dirname "$GATE_FOCUS_LOG")" 2>/dev/null
  if ! mkdir "$GATE_FOCUS_LOCK" 2>/dev/null; then
    # A lock older than 10 min is a crashed run, not a live one.
    if [ -n "$(find "$GATE_FOCUS_LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$GATE_FOCUS_LOCK" 2>/dev/null; mkdir "$GATE_FOCUS_LOCK" 2>/dev/null || { log "another run holds the lock — skipping"; return 0; }
    else
      log "another run holds the lock — skipping"; return 0
    fi
  fi
  trap 'rmdir "$GATE_FOCUS_LOCK" 2>/dev/null' EXIT

  local now prev since depth next
  now="${GATE_FOCUS_NOW:-$(date +%s)}"
  prev="$(_field active)"; case "$prev" in 0|1) ;; *) prev=0 ;; esac
  since="$(_field since)"; case "$since" in ''|*[!0-9]*) since="$now" ;; esac

  if [ -e "$GATE_FOCUS_OFF_FILE" ]; then
    depth="$(measure_depth)"
    if [ "$prev" = "1" ]; then
      log "kill switch $GATE_FOCUS_OFF_FILE present — focus mode forced OFF (depth=$depth)"
      send_notify "🎯 Modo foco no gate DESLIGADO" 3 "Desligado à mão (arquivo gate-focus.off). Fila do gate: $depth. Workers voltam a construir beads novas."
      since="$now"
    fi
    write_state 0 "$since" "$depth" "$now"
    return 0
  fi

  depth="$(measure_depth)"
  if [ "$depth" = "unreadable" ]; then
    log "depth UNREADABLE (bd list failed or returned non-JSON) — keeping active=$prev, not refreshing 'at' (readers go stale -> fail-open after ${GATE_FOCUS_STALE_S:-7200}s)"
    return 0
  fi

  next="$(decide "$prev" "$depth")"
  if [ "$next" != "$prev" ]; then
    since="$now"
    if [ "$next" = "1" ]; then
      log "ENTER focus mode: depth=$depth > $GATE_FOCUS_ENTER"
      send_notify "🎯 Modo foco no gate LIGADO" 4 "Fila do gate: $depth itens (>$GATE_FOCUS_ENTER). Workers genéricos param de pegar bead nova; consertos de bead reprovada seguem com até 2. Crews não são tocadas. Desliga quando a fila cair abaixo de $GATE_FOCUS_EXIT."
    else
      log "EXIT focus mode: depth=$depth < $GATE_FOCUS_EXIT"
      send_notify "🎯 Modo foco no gate DESLIGADO" 3 "Fila do gate caiu para $depth (<$GATE_FOCUS_EXIT). Workers voltam a construir beads novas."
    fi
  else
    log "active=$next depth=$depth (enter>$GATE_FOCUS_ENTER exit<$GATE_FOCUS_EXIT)"
  fi
  # Starving new builds is the point of the mode, but not forever: one escalation if it
  # stays ON past GATE_FOCUS_MAX_S (24 h). `escalated` is reset on every transition.
  local escalated; escalated="$(_field escalated)"
  [ "$next" != "$prev" ] && escalated=0
  if [ "$next" = "1" ] && [ "${escalated:-0}" != "1" ] && [ $(( now - since )) -gt "$GATE_FOCUS_MAX_S" ]; then
    log "ESCALATE: focus mode ON for $(( (now - since) / 3600 ))h (> $(( GATE_FOCUS_MAX_S / 3600 ))h), depth=$depth"
    send_notify "⚠️ Modo foco no gate há $(( (now - since) / 3600 ))h" 4 "A fila do gate não caiu abaixo de $GATE_FOCUS_EXIT (agora: $depth). Beads novas estão sem construção desde que o modo ligou. O Mayor precisa decidir: mais revisores, ou desligar o modo (touch .gc/gate-focus.off)."
    escalated=1
  fi
  write_state "$next" "$since" "$depth" "$now" "${escalated:-0}"
}

# Library mode for the selftest: `GATE_FOCUS_LIB=1 source gate-focus-mode.sh`.
[ "${GATE_FOCUS_LIB:-0}" = "1" ] || main "$@"
