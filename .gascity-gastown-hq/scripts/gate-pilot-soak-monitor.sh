#!/usr/bin/env bash
# gate-pilot-soak-monitor.sh (ga-spd2n) — 24h PASSIVE soak observer for the
# "Gate + Pilot imparáveis e auto-curáveis por 24h" acceptance criteria.
#
# WHY: the self-healing fixes (anti-flap heartbeat, headroom drained-reviewer
# exclusion, Pilot reuse-session/domain-map, reaper crew-exclusion, gate set-e
# abort fix, …) are ALREADY DEPLOYED. ga-spd2n's "story" is a 24h SOAK proving
# they hold: 24h continuous, ZERO manual interventions, gate queue never >30min
# without a merge WHILE there are ready markers, and no balancing regression.
# This script OBSERVES and records — it NEVER closes sessions, re-queues markers,
# restarts anything, or touches the gate/pilot. Pure read + log + (at end) verdict.
#
# WHAT (each run, every 10min):
#   1. Soak window: read start epoch + bead id from /tmp/spd2n-soak-start
#      ("<epoch> <bead-id>"). Absent → not armed → exit 0.
#   2. Gate merge cadence: last "Gate PASSED" ts vs ready-marker count.
#      HARD VIOLATION iff ready markers exist AND mins-since-last-merge > 30.
#   3. Reviewer false-kill: count self-healer reviewer reaps (WARN/observational);
#      HARD VIOLATION only on an explicit false-kill sentinel/signature.
#   4. Manual intervention: sentinel /tmp/spd2n-manual-intervention (Mayor touches
#      it if a human had to intervene). Present+nonempty → HARD VIOLATION.
#   5. Dolt load guard: sample dolt-server %cpu → running avg/peak.
#   6. Crew stability: count RESET/CLOSED events from the reset-detector log.
#   7. Accumulate running totals in /tmp/spd2n-soak-state so the verdict is
#      cumulative over the whole window, not just the last sample.
#
# AT SOAK END (elapsed >= 24h): compute verdict (SIM iff zero hard violations),
# notify -p 4 Athos, post a full report as a `gc bd comment` on the bead, then
# disarm (rename start file) so it stops re-arming.
#
# Kill switch: SPD2N_SOAK_ENABLED=0 → log "disabled" and exit (no sampling).
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="$CITY/.gc/logs/gate-pilot-soak-monitor.log"
METRICS="$CITY/.gc/logs/gate-pilot-soak-metrics.log"
DISP_LOG="$CITY/.gc/logs/quality-gate-dispatcher.log"
GUARD_LOG="$CITY/.gc/logs/quality-gate-guard.log"
CREW_LOG="$CITY/.gc/logs/crew-session-reset-detector.log"

START_FILE="/tmp/spd2n-soak-start"             # Mayor-written: "<epoch> <bead-id>"
STATE="/tmp/spd2n-soak-state"                  # script-owned cumulative state
MANUAL_SENTINEL="/tmp/spd2n-manual-intervention"  # Mayor touches on human intervention
FALSEKILL_SENTINEL="/tmp/spd2n-falsekill"      # operator touches on a confirmed false-kill

WINDOW_SECS="${SPD2N_SOAK_WINDOW_SECS:-86400}" # 24h (overridable for self-test)
STALL_MAX_MIN="${SPD2N_SOAK_STALL_MAX_MIN:-30}"
ENABLED="${SPD2N_SOAK_ENABLED:-1}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

# ---- state helpers (KEY=VALUE lines; we own every key) ----------------------
get_state() { # get_state KEY DEFAULT
  local v; v=$(grep -E "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
set_state() { # set_state KEY VALUE  (rewrites the key in place)
  local k="$1" val="$2" tmp
  tmp=$(mktemp "/tmp/spd2n-state.XXXXXX") || return 1
  grep -vE "^$k=" "$STATE" 2>/dev/null > "$tmp" || true
  echo "$k=$val" >> "$tmp"
  mv "$tmp" "$STATE"
}

# epoch from a "[YYYY-MM-DD HH:MM:SS]" bracketed dispatcher line (echo "" if none)
bracket_to_epoch() {
  local s; s=$(printf '%s' "$1" | sed -nE 's/^\[([0-9-]+ [0-9:]+)\].*/\1/p')
  [ -z "$s" ] && { printf ''; return; }
  date -j -f '%Y-%m-%d %H:%M:%S' "$s" '+%s' 2>/dev/null || printf ''
}

# count signature hits in the *new* bytes of a log since a stored offset, and
# advance the offset. Handles truncation/rotation (cur<saved → restart at 0).
# Usage: scan_new <logpath> <offset_key> <egrep_pattern>  → prints match count.
scan_new() {
  local lf="$1" okey="$2" pat="$3" off cur cnt
  [ -f "$lf" ] || { printf '0'; return; }
  off=$(get_state "$okey" 0)
  cur=$(wc -c < "$lf" 2>/dev/null | tr -d ' '); cur=${cur:-0}
  [ "$cur" -lt "$off" ] && off=0          # rotated/truncated
  if [ "$cur" -gt "$off" ]; then
    # grep -c always prints a number on stdout (even "0" with exit 1 on no match),
    # so capture stdout and sanitize — never chain `|| echo 0` (that doubles to "0\n0").
    cnt=$(tail -c +"$((off+1))" "$lf" 2>/dev/null | grep -cE "$pat" 2>/dev/null)
    cnt=$(printf '%s' "$cnt" | tr -dc '0-9')
  else
    cnt=0
  fi
  set_state "$okey" "$cur"
  printf '%s' "${cnt:-0}"
}

# float helpers via awk (bash has no floats)
fadd() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a+b}'; }
fmax() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", (a>b)?a:b}'; }
favg() { awk -v s="$1" -v n="$2" 'BEGIN{printf "%.1f", (n>0)?s/n:0}'; }

# ---------------------------------------------------------------------------
[ "$ENABLED" != "1" ] && { log "SPD2N_SOAK_ENABLED=0 — soak monitor disabled, skipping."; exit 0; }

# (1) Armed?
[ -f "$START_FILE" ] || { log "not armed (no $START_FILE) — exit."; exit 0; }
read -r SOAK_START BEAD_ID _rest < "$START_FILE"
case "$SOAK_START" in ''|*[!0-9]*) log "WARN: $START_FILE has no valid epoch ('$SOAK_START') — treating as not armed."; exit 0;; esac
BEAD_ID="${BEAD_ID:-ga-spd2n}"

NOW=$(date +%s)
ELAPSED=$(( NOW - SOAK_START ))
SOAK_END=$(( SOAK_START + WINDOW_SECS ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
if [ ! -f "$STATE" ]; then
  : > "$STATE"
  # Baseline every log cursor to current EOF so the FIRST sample counts only
  # events that happen DURING the soak window — not all prior history.
  for kv in "disp_offset:$DISP_LOG" "dispreap_offset:$DISP_LOG" "guard_offset:$GUARD_LOG" "crew_offset:$CREW_LOG"; do
    key="${kv%%:*}"; lf="${kv#*:}"
    sz=0; [ -f "$lf" ] && sz=$(wc -c < "$lf" 2>/dev/null | tr -d ' ')
    set_state "$key" "${sz:-0}"
  done
  log "soak armed: start=$SOAK_START bead=$BEAD_ID window=${WINDOW_SECS}s — state initialized, log cursors baselined to EOF."
fi

# (2) Gate merge cadence ------------------------------------------------------
LAST_PASS_LINE=$(grep -aE "\] \[quality-gate-dispatcher\] Gate PASSED:" "$DISP_LOG" 2>/dev/null | tail -1)
LAST_MERGE_EPOCH=$(bracket_to_epoch "$LAST_PASS_LINE")
# ga-qb6yg self-review before resubmission: same blind spot the MARKER_QUERY_FAILED
# fix below already addresses for READY_MARKERS, but left unaddressed here — an
# unknown last-merge-time (no "Gate PASSED" line found, e.g. DISP_LOG was just
# truncated by city-disk-autoprune.sh, also new in this branch) used to set
# MINS_SINCE_MERGE=-1, which trivially fails `-gt "$STALL_MAX_MIN"` forever, so
# "we don't know when the last merge was" silently read as "definitely not
# stalled" instead of "can't rule out a stall." Track it explicitly and let it
# feed the same violation checks MARKER_QUERY_FAILED already feeds.
if [ -n "$LAST_MERGE_EPOCH" ]; then
  MINS_SINCE_MERGE=$(( (NOW - LAST_MERGE_EPOCH) / 60 ))
  MERGE_TIME_UNKNOWN=0
else
  MINS_SINCE_MERGE=-1   # unknown
  MERGE_TIME_UNKNOWN=1
  log "WARN: no 'Gate PASSED' line found in $DISP_LOG — last-merge time unknown, treating as unverified for the stall check."
fi

# ga-sdkrl gate-feedback: the old `|| true` on the subshell masked the query's OWN
# exit code, so a timeout/failure (25s exceeded, Dolt unreachable, etc.) and a
# genuine "queried fine, zero queued markers" result both sanitized down to
# READY_MARKERS=0 — indistinguishable, and STALL_VIOLATION only fires when
# READY_MARKERS -gt 0, so a query failure could NEVER trigger the one check this
# script exists to make. The failure mode most likely to cause this exact timeout
# — Dolt under CPU load — is the SAME condition that would also be causing a real
# stall, so silently reading "0 ready markers" here is optimistic in exactly the
# case it should be most suspicious. Capture the query's real exit code BEFORE any
# masking; on failure, treat it as equivalent to "markers may be waiting" for the
# stall check (never silently equivalent to "confirmed clean").
MARKER_OUT=$(cd "$CITY" && GC_CITY="$CITY" timeout 25 gc bd list --all \
  -l type:quality-gate-marker -l gate-status:queued 2>/dev/null)
MARKER_QUERY_RC=$?
MARKER_QUERY_FAILED=0
if [ "$MARKER_QUERY_RC" -ne 0 ]; then
  MARKER_QUERY_FAILED=1
  READY_MARKERS=0
  log "WARN: ready-marker query failed/timed out (rc=$MARKER_QUERY_RC) — cannot confirm zero, treating as unverified for the stall check."
else
  READY_MARKERS=$(printf '%s\n' "$MARKER_OUT" | grep -cE '^[○●◐] ' || true)
  READY_MARKERS=$(printf '%s' "$READY_MARKERS" | tr -dc '0-9'); READY_MARKERS=${READY_MARKERS:-0}
fi

STALL_VIOLATION=0
if { [ "$READY_MARKERS" -gt 0 ] || [ "$MARKER_QUERY_FAILED" -eq 1 ]; } \
   && { [ "$MERGE_TIME_UNKNOWN" -eq 1 ] || [ "$MINS_SINCE_MERGE" -gt "$STALL_MAX_MIN" ]; }; then
  STALL_VIOLATION=1
fi

# new merges since last sample (offset scan)
NEW_MERGES=$(scan_new "$DISP_LOG" disp_offset "\] \[quality-gate-dispatcher\] Gate PASSED:")

# (3) Reviewer reaps (observational WARN) + explicit false-kill (HARD) --------
# Self-healer reaping a peek-dead reviewer is BY DESIGN, not a false-kill → WARN.
# NOTE: we deliberately do NOT grep the dispatcher/guard logs for "false-FAIL"
# etc — reviewer comment bodies (full diffs/docs) are logged verbatim and contain
# that text, so a log grep yields false positives. A genuine false-kill of a
# HEALTHY reviewer is not reliably distinguishable from a normal stale reap in
# the logs, so the HARD signal is the operator sentinel only (low confidence —
# see report). Reaps are recorded as observational WARN counts.
NEW_REVIEWER_REAPS=$(scan_new "$GUARD_LOG" guard_offset "Drained reviewer detected|Re-convening dead reviewer|no live reviewer")
NEW_REVIEWER_REAPS_D=$(scan_new "$DISP_LOG" dispreap_offset "Drained reviewer detected|Re-convening dead reviewer|no live reviewer")
NEW_REVIEWER_REAPS=$(( NEW_REVIEWER_REAPS + NEW_REVIEWER_REAPS_D ))
NEW_FALSEKILL=0
FALSEKILL_VIOLATION=0
if [ -f "$FALSEKILL_SENTINEL" ]; then FALSEKILL_VIOLATION=1; NEW_FALSEKILL=1; fi

# (4) Manual intervention (sentinel; best-effort) ----------------------------
MANUAL_VIOLATION=0
if [ -f "$MANUAL_SENTINEL" ]; then MANUAL_VIOLATION=1; fi

# (5) Dolt load sample --------------------------------------------------------
DOLT_PID=$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)
if [ -n "$DOLT_PID" ]; then
  DOLT_CPU=$(ps -o %cpu= -p "$DOLT_PID" 2>/dev/null | tr -d ' '); DOLT_CPU=${DOLT_CPU:-0}
else
  DOLT_CPU=0
fi

# (6) Crew stability ----------------------------------------------------------
NEW_CREW_EVENTS=$(scan_new "$CREW_LOG" crew_offset "^\[.*\] (RESET|CLOSED): ")

# (7) Accumulate cumulative totals -------------------------------------------
T_MERGES=$(( $(get_state merges 0) + NEW_MERGES ))
T_REAPS=$(( $(get_state reviewer_reaps 0) + NEW_REVIEWER_REAPS ))
T_CREW=$(( $(get_state crew_events 0) + NEW_CREW_EVENTS ))
T_FALSEKILL=$(( $(get_state falsekill_events 0) + NEW_FALSEKILL ))
# ga-qb6yg self-review before resubmission: MARKER_QUERY_FAILED/MERGE_TIME_UNKNOWN
# were computed per-sample and logged per-line (SAMPLE below), but never
# accumulated or surfaced in the final 24h REPORT — so the report's own
# "CONFIANÇA DO VEREDITO: ALTA" claim for the stall signal could stand
# unqualified even if some fraction of samples were actually unverified.
T_MARKER_QUERY_FAILED=$(( $(get_state marker_query_failed_count 0) + MARKER_QUERY_FAILED ))
T_MERGE_TIME_UNKNOWN=$(( $(get_state merge_time_unknown_count 0) + MERGE_TIME_UNKNOWN ))
SAMPLES=$(( $(get_state samples 0) + 1 ))
CPU_SUM=$(fadd "$(get_state cpu_sum 0)" "$DOLT_CPU")
CPU_PEAK=$(fmax "$(get_state cpu_peak 0)" "$DOLT_CPU")
CPU_AVG=$(favg "$CPU_SUM" "$SAMPLES")

# max stall observed (only meaningful when there was queued work) — same
# query-failure blind spot as STALL_VIOLATION above, same fix: an unverified
# ready-marker count must not silently behave like a confirmed-zero one here
# either, or a stall during a marker-query outage would be under-reported.
MAXSTALL=$(get_state max_stall_min 0)
if { [ "$READY_MARKERS" -gt 0 ] || [ "$MARKER_QUERY_FAILED" -eq 1 ]; } && [ "$MINS_SINCE_MERGE" -gt "$MAXSTALL" ]; then
  MAXSTALL="$MINS_SINCE_MERGE"
fi

# latched hard-violation flags (sticky once tripped over the window)
L_STALL=$(get_state latch_stall 0);       [ "$STALL_VIOLATION" -eq 1 ] && L_STALL=1
L_MANUAL=$(get_state latch_manual 0);     [ "$MANUAL_VIOLATION" -eq 1 ] && L_MANUAL=1
L_FALSEKILL=$(get_state latch_falsekill 0); [ "$FALSEKILL_VIOLATION" -eq 1 ] && L_FALSEKILL=1
HARD_VIOLATIONS=$(( L_STALL + L_MANUAL + L_FALSEKILL ))

set_state merges "$T_MERGES"
set_state reviewer_reaps "$T_REAPS"
set_state crew_events "$T_CREW"
set_state falsekill_events "$T_FALSEKILL"
set_state marker_query_failed_count "$T_MARKER_QUERY_FAILED"
set_state merge_time_unknown_count "$T_MERGE_TIME_UNKNOWN"
set_state samples "$SAMPLES"
set_state cpu_sum "$CPU_SUM"
set_state cpu_peak "$CPU_PEAK"
set_state max_stall_min "$MAXSTALL"
set_state latch_stall "$L_STALL"
set_state latch_manual "$L_MANUAL"
set_state latch_falsekill "$L_FALSEKILL"

# per-sample metrics line (machine-readable). marker_query_failed: ga-sdkrl
# gate-feedback — visible+counted, not silently folded into ready_markers=0,
# so a human reading this trail can tell "confirmed zero" from "unverified".
SAMPLE="t=$(ts) elapsed_min=$ELAPSED_MIN ready_markers=$READY_MARKERS mins_since_merge=$MINS_SINCE_MERGE \
new_merges=$NEW_MERGES stall_viol=$STALL_VIOLATION dolt_cpu=$DOLT_CPU cpu_avg=$CPU_AVG cpu_peak=$CPU_PEAK \
new_reviewer_reaps=$NEW_REVIEWER_REAPS new_falsekill=$NEW_FALSEKILL manual_viol=$MANUAL_VIOLATION \
new_crew_events=$NEW_CREW_EVENTS max_stall_min=$MAXSTALL hard_violations=$HARD_VIOLATIONS \
marker_query_failed=$MARKER_QUERY_FAILED"
echo "$SAMPLE" >> "$METRICS" 2>/dev/null
log "sample: $SAMPLE"

# ---- finalize at soak end ---------------------------------------------------
if [ "$NOW" -lt "$SOAK_END" ]; then
  REMAIN_MIN=$(( (SOAK_END - NOW) / 60 ))
  log "soak in progress: ${ELAPSED_MIN}min elapsed, ${REMAIN_MIN}min remaining, hard_violations=${HARD_VIOLATIONS}."
  exit 0
fi

# Already finalized? (disarm renames the start file, so this is belt-and-suspenders)
if [ "$(get_state finalized 0)" = "1" ]; then
  log "already finalized — disarming (renaming start file)."
  mv "$START_FILE" "${START_FILE}.done" 2>/dev/null || true
  exit 0
fi

# Build verdict
if [ "$HARD_VIOLATIONS" -eq 0 ]; then VERDICT="SIM (PASS)"; else VERDICT="NÃO (FAIL)"; fi
VIOL_DETAIL=""
[ "$L_STALL" -eq 1 ]     && VIOL_DETAIL="${VIOL_DETAIL}  - gate queue >${STALL_MAX_MIN}min sem merge COM markers prontos (max observado: ${MAXSTALL}min)\n"
[ "$L_MANUAL" -eq 1 ]    && VIOL_DETAIL="${VIOL_DETAIL}  - intervenção MANUAL detectada (sentinel $MANUAL_SENTINEL)\n"
[ "$L_FALSEKILL" -eq 1 ] && VIOL_DETAIL="${VIOL_DETAIL}  - false-kill de reviewer saudável (${T_FALSEKILL} sinais / sentinel)\n"
[ -z "$VIOL_DETAIL" ] && VIOL_DETAIL="  (nenhuma violação dura)\n"

ATTENTION_DETAIL=""
[ "$T_MARKER_QUERY_FAILED" -gt 0 ] && ATTENTION_DETAIL="${ATTENTION_DETAIL}  - ATENÇÃO: ${T_MARKER_QUERY_FAILED}/${SAMPLES} amostra(s) com marker-query falhou/timeout — tratadas como 'pode estar esperando' (nunca como zero confirmado), mas o sinal real ficou sem confirmar nessas janelas.\n"
[ "$T_MERGE_TIME_UNKNOWN" -gt 0 ] && ATTENTION_DETAIL="${ATTENTION_DETAIL}  - ATENÇÃO: ${T_MERGE_TIME_UNKNOWN}/${SAMPLES} amostra(s) sem 'Gate PASSED' localizável no log (possível truncamento) — tratadas como possível-stall, não como recém-mergeado.\n"

REPORT=$(printf '%s' "\
SOAK 24h ga-spd2n — VEREDITO: ${VERDICT}

Janela: $(date -r "$SOAK_START" '+%Y-%m-%d %H:%M:%S') → $(date -r "$SOAK_END" '+%Y-%m-%d %H:%M:%S') (${WINDOW_SECS}s)
Amostras coletadas: ${SAMPLES} (a cada ~10min)

ESTRELA-GUIA (hard violations = ${HARD_VIOLATIONS}):
$(printf '%b' "$VIOL_DETAIL")
MÉTRICAS DA JANELA:
  - Merges (Gate PASSED) observados: ${T_MERGES}
  - Maior stall com markers prontos: ${MAXSTALL}min (limite ${STALL_MAX_MIN}min)
  - Dolt %cpu: avg=${CPU_AVG}% peak=${CPU_PEAK}%
  - Reviewer reaps do self-healer (observacional/WARN): ${T_REAPS}
  - Sinais explícitos de false-kill (hard): ${T_FALSEKILL}
  - Eventos crew RESET/CLOSED: ${T_CREW}
  - Amostras com marker-query falhou/inconclusivo: ${T_MARKER_QUERY_FAILED}/${SAMPLES}
  - Amostras com último-merge desconhecido (sem 'Gate PASSED' no log): ${T_MERGE_TIME_UNKNOWN}/${SAMPLES}

CONFIANÇA DO VEREDITO (honesto):
$(printf '%b' "$ATTENTION_DETAIL")  - ALTA: cadência de merge / stall (#2), carga Dolt (#5), estabilidade crew (#6),
    merges (#7) — medidos diretamente de logs/ps. Ver ressalvas acima se alguma
    amostra ficou inconclusiva.
  - APROX/BAIXA: false-kill de reviewer (#3) e intervenção manual (#4) — detecção
    best-effort via sentinel + assinaturas de log. Self-healer reaping de reviewer
    peek-morto é POR DESIGN e contado só como WARN. Mis-routing de domínio do Pilot
    e '3 reviewers por run CODE' NÃO são checados como violação dura (não há
    assinatura confiável); avaliar manualmente se necessário.
  - Carga Dolt é registrada como avg/peak observacional (sem limiar absoluto) para
    confirmar que os guards não pioraram a carga.")

log "SOAK COMPLETE — verdict=${VERDICT} hard_violations=${HARD_VIOLATIONS} merges=${T_MERGES} max_stall=${MAXSTALL}min cpu_avg=${CPU_AVG}% cpu_peak=${CPU_PEAK}%"
printf '%s\n' "$REPORT" >> "$LOG" 2>/dev/null

# notify Athos
if command -v notify >/dev/null 2>&1; then
  notify -p 4 -t 'SOAK ga-spd2n' "Soak 24h concluído — veredito: ${VERDICT} (${HARD_VIOLATIONS} violações duras, ${T_MERGES} merges, max-stall ${MAXSTALL}min)" >/dev/null 2>&1 || true
fi

# post report as a bead comment
( cd "$CITY" && printf '%s\n' "$REPORT" | GC_CITY="$CITY" timeout 40 gc bd comment "$BEAD_ID" --stdin ) >> "$LOG" 2>&1 \
  && log "report posted to $BEAD_ID" \
  || log "WARN: failed to post report to $BEAD_ID (will not retry; report is above + in $LOG)"

# disarm: stop re-arming
set_state finalized 1
mv "$START_FILE" "${START_FILE}.done" 2>/dev/null || true
log "soak complete — disarmed (start file renamed to ${START_FILE}.done)."
exit 0
