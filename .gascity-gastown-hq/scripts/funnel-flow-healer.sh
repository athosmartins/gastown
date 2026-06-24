#!/usr/bin/env bash
# funnel-flow-healer.sh — persistent FLOW auto-healer for the Gas Town refino→gate funnel.
#
# WHY (the gap it closes): ~14 launchd watchdogs check LIVENESS (alive/hung/loaded/
# quota), NOT FLOW. On 2026-06-15 the refino funnel sat stalled for DAYS while every
# monitor showed green — daemons were "LOADED, LastExitStatus=0, firing but NO-OP."
# A liveness check is blind to "ran but moved nothing." The manual fix each time was
# mechanical: `launchctl kickstart -k` the stalled daemon. This healer automates that.
#
# WHAT: every ~10min it takes a STAGE CENSUS of the funnel (cross-store, via bd) and
# measures LOG FRESHNESS of each dispatcher. When demand exists but the responsible
# dispatcher's log is frozen, it treats that as a STALL SIGNATURE. It only acts on a
# CONFIRMED stall (>=STALL_CONFIRM_STRIKES consecutive runs), respects a per-component
# COOLDOWN, and is BOUNDED (after MAX_REMEDIATIONS futile kickstarts it STOPS and
# escalates to the Mayor via durable mail — the next auto-heal layer). It pings the
# human (NTFY) ONLY as an absolute last resort (escalated to Mayor AND still stuck >2h).
#
# Athos's requirement: "não quero ser avisado, quero que o sistema se auto-destrave
# sozinho" → priority is AUTO-REMEDIATION; escalate to MAYOR if that fails; NTFY last.
#
# ALLOWED ACTIONS (and ONLY these):
#   - launchctl kickstart -k  of the specific known dispatcher daemons
#   - gc mail send mayor       (durable escalation)
#   - notify -p 5              (last-resort human ping)
# NO data mutations, NO bd writes, NO rm of data, NO destructive ops, NO Dolt internals.
#
# Kill switch: FLOW_HEALER_ENABLED=0 → census + log only, never remediate.
set -uo pipefail

# ------------------------------------------------------------------ config
CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
export GC_CITY="$CITY"
LOGDIR="$CITY/.gc/logs"
JSONL="$LOGDIR/funnel-flow-healer.jsonl"          # observability event stream
STATE_DIR="${FLOW_HEALER_STATE_DIR:-/tmp/funnel-flow-healer.state}"  # per-signature state

UID_NUM="${FLOW_HEALER_UID:-$(id -u)}"
ENABLED="${FLOW_HEALER_ENABLED:-1}"

# Thresholds (env-overridable for selftest + tuning)
STALL_CONFIRM_STRIKES="${STALL_CONFIRM_STRIKES:-2}"     # consecutive runs before any kickstart
REMEDIATION_COOLDOWN="${REMEDIATION_COOLDOWN:-1800}"    # sec between kickstarts of same component
MAX_REMEDIATIONS="${MAX_REMEDIATIONS:-3}"              # futile kickstarts before STOP+escalate
ESCALATION_NTFY_WINDOW="${ESCALATION_NTFY_WINDOW:-7200}" # sec a stall must persist post-escalation before NTFY (2h)

# Log-freshness thresholds (minutes) per signature
AUTO_REFINO_FREEZE_MIN="${AUTO_REFINO_FREEZE_MIN:-15}"
REFINO_GATE_FREEZE_MIN="${REFINO_GATE_FREEZE_MIN:-15}"
GATE_FREEZE_MIN="${GATE_FREEZE_MIN:-10}"
PILOT_FREEZE_MIN="${PILOT_FREEZE_MIN:-15}"

BD_TIMEOUT="${FLOW_HEALER_BD_TIMEOUT:-25}"

# launchd labels (discovered from `launchctl list | grep gascity` on 2026-06-15)
LABEL_AUTO_REFINO="${LABEL_AUTO_REFINO:-com.gascity.auto-refino-dispatcher}"
LABEL_REFINO_GATE="${LABEL_REFINO_GATE:-com.gascity.refino-gate-dispatcher}"
LABEL_GATE="${LABEL_GATE:-com.gascity.quality-gate-dispatcher}"
LABEL_PILOT="${LABEL_PILOT:-com.gascity.pilot}"

# Dispatcher log paths (frozen mtime = NO-OP / stall)
LOG_AUTO_REFINO="${LOG_AUTO_REFINO:-$LOGDIR/auto-refino-dispatcher.log}"
LOG_REFINO_GATE="${LOG_REFINO_GATE:-$LOGDIR/refino-gate-dispatcher.log}"
LOG_GATE="${LOG_GATE:-$LOGDIR/quality-gate-dispatcher.log}"
LOG_PILOT="${LOG_PILOT:-$LOGDIR/pilot-dispatcher.log}"

NOW="${FLOW_HEALER_NOW:-$(date +%s)}"               # injectable clock (selftest)
TS="$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$STATE_DIR" "$LOGDIR" 2>/dev/null || true

SCRIPTS_DIR="${CITY}/scripts"
# shellcheck source=gc-ledger.sh
source "$SCRIPTS_DIR/gc-ledger.sh" 2>/dev/null || gc_ledger_append() { :; }
GC_LEDGER_DIR="$LOGDIR"

# ------------------------------------------------------------------ helpers
# Emit an observability event to the JSONL stream.
emit() {  # emit <event> <json-fields...>
  local event="$1"; shift
  printf '{"ts":"%s","event":"%s"%s}\n' "$TS" "$event" "$*" >> "$JSONL" 2>/dev/null || true
}

# Log-file freshness in MINUTES since last mtime. Missing file → very large (treated
# as frozen). Injectable via FLOW_HEALER_FAKE_MTIME_<basename-uppercased> for selftest.
log_age_min() {  # log_age_min <path>
  local f="$1" mt
  local fake_key="FLOW_HEALER_FAKE_MTIME_$(basename "$f" | tr 'a-z.-' 'A-Z__')"
  mt="${!fake_key:-}"
  if [ -z "$mt" ]; then
    [ -f "$f" ] || { echo 999999; return; }
    mt=$(stat -f %m "$f" 2>/dev/null || echo 0)
  fi
  echo $(( (NOW - mt) / 60 ))
}

# bd count for a label-pattern / type filter. Stubbable in selftest via
# FLOW_HEALER_FAKE_BD (a function that echoes a count) — see selftest.
bd_count() {  # bd_count <bd-list-args...>
  if [ -n "${FLOW_HEALER_FAKE_BD:-}" ]; then
    "$FLOW_HEALER_FAKE_BD" "$@"; return
  fi
  local out
  out=$(cd "$CITY" && timeout "$BD_TIMEOUT" bd -C "$CITY" list "$@" --json 2>/dev/null) || { echo "?"; return; }
  printf '%s' "$out" | jq 'length' 2>/dev/null || echo "?"
}

# launchctl kickstart wrapper (stubbable in selftest via FLOW_HEALER_FAKE_LAUNCHCTL).
do_kickstart() {  # do_kickstart <label>
  local label="$1"
  if [ -n "${FLOW_HEALER_FAKE_LAUNCHCTL:-}" ]; then
    "$FLOW_HEALER_FAKE_LAUNCHCTL" kickstart -k "gui/$UID_NUM/$label"; return $?
  fi
  launchctl kickstart -k "gui/$UID_NUM/$label" >/dev/null 2>&1
}

# gc mail send mayor wrapper (stubbable in selftest via FLOW_HEALER_FAKE_MAIL).
do_mail_mayor() {  # do_mail_mayor <subject> <body>
  local subj="$1" body="$2"
  if [ -n "${FLOW_HEALER_FAKE_MAIL:-}" ]; then
    "$FLOW_HEALER_FAKE_MAIL" "$subj" "$body"; return $?
  fi
  ( cd "$CITY" && GC_CITY="$CITY" gc mail send mayor -s "$subj" -m "$body" >/dev/null 2>&1 ) || true
}

# notify wrapper (stubbable in selftest via FLOW_HEALER_FAKE_NOTIFY).
do_notify() {  # do_notify <title> <message>
  local title="$1" msg="$2"
  if [ -n "${FLOW_HEALER_FAKE_NOTIFY:-}" ]; then
    "$FLOW_HEALER_FAKE_NOTIFY" "$title" "$msg"; return $?
  fi
  command -v notify >/dev/null 2>&1 && notify -p 5 -t "$title" "$msg" >/dev/null 2>&1 || true
}

# state file accessors (keyed per signature) -----------------------------
sf() { echo "$STATE_DIR/$1"; }                       # state-file path for key
get() { cat "$(sf "$1")" 2>/dev/null || echo "$2"; } # get <key> <default>
put() { echo "$2" > "$(sf "$1")" 2>/dev/null || true; }

# ------------------------------------------------------------------ DECISION CORE
# decide_action: PURE decision logic for one signature. Reads state, returns the
# action to take on stdout (one of: NONE | KICKSTART | ESCALATE | NTFY) and updates
# the persisted strike/remediation/escalation state. Takes NO real-world action — the
# caller dispatches the returned verb. This is the unit the selftest drives directly.
#
# Args: <sig> <stalled:0|1>
#   sig     : signature key (e.g. auto-refino)
#   stalled : 1 if (demand present AND log frozen) this run, else 0
decide_action() {
  local sig="$1" stalled="$2"
  local strikes; strikes=$(get "$sig.strikes" 0)
  local remediations; remediations=$(get "$sig.remediations" 0)
  local last_kick; last_kick=$(get "$sig.last_kick" 0)
  local escalated_at; escalated_at=$(get "$sig.escalated_at" 0)
  local ntfyd; ntfyd=$(get "$sig.ntfyd" 0)

  # Not stalled this run → clear strikes + transient state. (Recovery resets the
  # bound/cooldown so a future, unrelated stall starts fresh.)
  if [ "$stalled" != "1" ]; then
    if [ "$strikes" != "0" ] || [ "$remediations" != "0" ] || [ "$escalated_at" != "0" ]; then
      put "$sig.strikes" 0; put "$sig.remediations" 0
      put "$sig.last_kick" 0; put "$sig.escalated_at" 0; put "$sig.ntfyd" 0
    fi
    echo "NONE"; return
  fi

  # Stalled → accumulate strike.
  strikes=$((strikes + 1)); put "$sig.strikes" "$strikes"

  # Kill switch / disabled → census-only, no remediation verbs.
  if [ "$ENABLED" != "1" ]; then echo "NONE"; return; fi

  # Not yet confirmed (transient blip) → wait.
  if [ "$strikes" -lt "$STALL_CONFIRM_STRIKES" ]; then echo "NONE"; return; fi

  # Already escalated to Mayor → the Mayor layer owns it. Only verb left is the
  # absolute-last-resort human NTFY, and only if it has persisted beyond the window
  # AND we have not already pinged once.
  if [ "$escalated_at" != "0" ]; then
    if [ "$ntfyd" = "0" ] && [ $((NOW - escalated_at)) -ge "$ESCALATION_NTFY_WINDOW" ]; then
      put "$sig.ntfyd" 1
      echo "NTFY"; return
    fi
    echo "NONE"; return
  fi

  # Bound reached → STOP kickstarting, escalate to Mayor (durable, the next layer).
  if [ "$remediations" -ge "$MAX_REMEDIATIONS" ]; then
    put "$sig.escalated_at" "$NOW"
    echo "ESCALATE"; return
  fi

  # Cooldown → confirmed + under-bound, but too soon since last kickstart. Hold.
  if [ "$last_kick" != "0" ] && [ $((NOW - last_kick)) -lt "$REMEDIATION_COOLDOWN" ]; then
    echo "NONE"; return
  fi

  # All gates passed → kickstart now. Record it.
  remediations=$((remediations + 1))
  put "$sig.remediations" "$remediations"
  put "$sig.last_kick" "$NOW"
  echo "KICKSTART"
}

# ------------------------------------------------------------------ effecting one signature
# handle_signature: compute stall, call decide_action, dispatch the returned verb on
# the REAL world (kickstart/mail/notify), and emit observability events.
# Args: <sig> <label> <log> <freeze_min> <demand_expr_result:0|1> <census_blob>
handle_signature() {
  local sig="$1" label="$2" logf="$3" freeze="$4" demand="$5" census="$6"
  local age; age=$(log_age_min "$logf")
  local frozen=0; [ "$age" -gt "$freeze" ] && frozen=1
  local stalled=0; { [ "$demand" = "1" ] && [ "$frozen" = "1" ]; } && stalled=1

  local action; action=$(decide_action "$sig" "$stalled")
  local strikes; strikes=$(get "$sig.strikes" 0)
  local remediations; remediations=$(get "$sig.remediations" 0)

  emit "signature" ",\"sig\":\"$sig\",\"demand\":$demand,\"log_age_min\":$age,\"frozen\":$frozen,\"stalled\":$stalled,\"strikes\":$strikes,\"remediations\":$remediations,\"decision\":\"$action\""

  case "$action" in
    KICKSTART)
      if do_kickstart "$label"; then
        emit "remediation" ",\"sig\":\"$sig\",\"label\":\"$label\",\"attempt\":$remediations,\"result\":\"kickstarted\""
      else
        emit "remediation" ",\"sig\":\"$sig\",\"label\":\"$label\",\"attempt\":$remediations,\"result\":\"kickstart_failed\""
      fi
      ;;
    ESCALATE)
      local subj="Flow-healer: $sig NOT self-healing after $MAX_REMEDIATIONS kickstarts"
      local body="Funnel signature '$sig' (daemon $label) remained stalled (demand present + log frozen >${freeze}min) through $MAX_REMEDIATIONS kickstarts without clearing. Auto-remediation exhausted; STOPPING kickstarts for this component and handing to you (the next auto-heal layer).
CENSUS at $TS: $census
Log: $logf (age=${age}min). Please diagnose + fix root cause. NTFY to Athos will fire ONLY if this persists >$((ESCALATION_NTFY_WINDOW/3600))h beyond now. (auto-sent by funnel-flow-healer)"
      # imp07 Dolt-INDEPENDENT invariant: notify PRIMARY (unconditional), mail SECONDARY.
      do_notify "Flow-healer escalou" "Funnel '$sig' não auto-sana após $MAX_REMEDIATIONS kickstarts — escalado pro Mayor."
      do_mail_mayor "$subj" "$body"
      gc_ledger_append human-touch "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source_daemon\":\"funnel-flow-healer\",\"stage\":\"refina\",\"kind\":\"technical\",\"bead_id\":\"\",\"reason\":\"ESCALATE after $MAX_REMEDIATIONS kickstarts: $sig\"}" 2>/dev/null || true
      emit "escalation" ",\"sig\":\"$sig\",\"label\":\"$label\",\"to\":\"mayor\",\"after_kickstarts\":$MAX_REMEDIATIONS"
      ;;
    NTFY)
      do_notify "Flow-healer LAST RESORT" "Funnel '$sig' still stalled >$((ESCALATION_NTFY_WINDOW/3600))h after Mayor escalation — neither auto-heal nor Mayor recovered it. NEEDS HUMAN."
      gc_ledger_append human-touch "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source_daemon\":\"funnel-flow-healer\",\"stage\":\"refina\",\"kind\":\"technical\",\"bead_id\":\"\",\"reason\":\"NTFY last-resort: $sig persisted past escalation window\"}" 2>/dev/null || true
      emit "ntfy" ",\"sig\":\"$sig\",\"reason\":\"persisted_past_escalation_window\""
      ;;
    NONE) : ;;
  esac
}

# ------------------------------------------------------------------ census + run
run() {
  # Stage census (cross-store via bd). "?" means bd was unreachable (do NOT treat an
  # unknown count as demand — fail SAFE toward no-action).
  local feat_open feat_storied raw_triagem unrefined refining refino_review needs_appr q_queued q_running
  feat_open=$(bd_count -t feature -s open)
  feat_storied=$(bd_count -t feature -s open --label-pattern 'story:*')
  unrefined=$(bd_count -l story:unrefined)
  refining=$(bd_count -l story:refinement-in-progress)
  refino_review=$(bd_count -l story:refino-review)
  needs_appr=$(bd_count -l story:needs-approval)
  q_queued=$(bd_count -l gate-status:queued)
  q_running=$(bd_count -l gate-status:running)

  # raw-Triagem = open features with NO story:* label. Only computable when both
  # counts are numeric; otherwise "?" (unknown → no demand).
  if [[ "$feat_open" =~ ^[0-9]+$ ]] && [[ "$feat_storied" =~ ^[0-9]+$ ]]; then
    raw_triagem=$(( feat_open - feat_storied )); [ "$raw_triagem" -lt 0 ] && raw_triagem=0
  else
    raw_triagem="?"
  fi

  # Log freshness (minutes)
  local age_ar age_rg age_pilot age_gate
  age_ar=$(log_age_min "$LOG_AUTO_REFINO")
  age_rg=$(log_age_min "$LOG_REFINO_GATE")
  age_pilot=$(log_age_min "$LOG_PILOT")
  age_gate=$(log_age_min "$LOG_GATE")

  local census="raw-Triagem=$raw_triagem unrefined=$unrefined refining=$refining refino-review=$refino_review needs-approval=$needs_appr gate-queued=$q_queued gate-running=$q_running | logage(min) auto-refino=$age_ar refino-gate=$age_rg pilot=$age_pilot gate=$age_gate"

  emit "census" ",\"raw_triagem\":\"$raw_triagem\",\"unrefined\":\"$unrefined\",\"refining\":\"$refining\",\"refino_review\":\"$refino_review\",\"needs_approval\":\"$needs_appr\",\"gate_queued\":\"$q_queued\",\"gate_running\":\"$q_running\",\"log_age\":{\"auto_refino\":$age_ar,\"refino_gate\":$age_rg,\"pilot\":$age_pilot,\"gate\":$age_gate},\"enabled\":$ENABLED"

  # gt()/num helper: a count "is positive" only if numeric AND > 0 (so "?" = no demand).
  pos() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }

  # --- Signature 1: AUTO-REFINO stalled ---------------------------------
  # demand = raw-Triagem>0 OR story:unrefined>0 ; freeze = auto-refino log frozen.
  local d1=0; { pos "$raw_triagem" || pos "$unrefined"; } && d1=1
  handle_signature "auto-refino" "$LABEL_AUTO_REFINO" "$LOG_AUTO_REFINO" "$AUTO_REFINO_FREEZE_MIN" "$d1" "$census"

  # --- Signature 2: REFINO-GATE stalled ---------------------------------
  # demand = something stuck in story:refino-review ; freeze = refino-gate log frozen.
  local d2=0; pos "$refino_review" && d2=1
  handle_signature "refino-gate" "$LABEL_REFINO_GATE" "$LOG_REFINO_GATE" "$REFINO_GATE_FREEZE_MIN" "$d2" "$census"

  # --- Signature 3: GATE stalled ----------------------------------------
  # demand = gate-status:queued>0 (queue not draining) ; freeze = gate log frozen.
  local d3=0; pos "$q_queued" && d3=1
  handle_signature "gate" "$LABEL_GATE" "$LOG_GATE" "$GATE_FREEZE_MIN" "$d3" "$census"

  # --- Signature 4: PILOT stalled ---------------------------------------
  # demand = dispatchable approved work waiting (story:needs-approval is the post-
  # approval queue the pilot dispatches from) ; freeze = pilot log frozen.
  local d4=0; pos "$needs_appr" && d4=1
  handle_signature "pilot" "$LABEL_PILOT" "$LOG_PILOT" "$PILOT_FREEZE_MIN" "$d4" "$census"
}

# Allow the selftest to source this file (decision core) without executing run().
if [ "${FLOW_HEALER_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

run
exit 0
