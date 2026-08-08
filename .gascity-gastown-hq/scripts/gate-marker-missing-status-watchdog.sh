#!/usr/bin/env bash
# gate-marker-missing-status-watchdog.sh — detects quality-gate marker/run
# beads (type:quality-gate-marker or type:quality-gate-run) that are OPEN and
# carry ZERO gate-status:* label, for longer than a configurable grace period.
#
# WHY THIS EXISTS (ga-5jyo8): quality-gate-guard.sh and
# quality-gate-dispatcher.sh select markers/runs EXCLUSIVELY by
# `--label-any gate-status:{ready,queued,claimed,dispatching,running,...}` —
# an OR-set enumerated over known status values. A marker/run with NO
# gate-status:* label at all matches none of those OR-sets and is therefore
# UNREACHABLE BY CONSTRUCTION: no sweep, ever, at any age, will pick it up.
# Real incident: ga-wisp-pvi4jek (branch crew/wa-worker/wa-aogpc) sat 2 days
# in exactly this state — type:quality-gate-marker, branch:, source-bead:,
# bead-rig: all present and correct, only gate-status:* missing. It was
# discovered purely by accident: gate-orphaned-label-watchdog.sh happened to
# be watching the SOURCE BEAD (wa-aogpc, carrying gate:queued) from the other
# side, saw its artifact probe come back "unknown", and a human traced it
# back manually. Zero purpose-built detection existed for the marker/run side
# of this blind spot before this script.
#
# SCOPE — TWO artifact types, not just the one named in the bug report:
#   type:quality-gate-marker AND type:quality-gate-run both get created by a
#   single multi-`-l`-flag `bd create` call (gate-done.md Step 3; and
#   quality-gate-guard.sh's two gate-run creation sites) and both are
#   selected downstream exclusively by gate-status:* OR-sets (guard.sh's
#   Vector A/B reconcile queries, dispatcher.sh Step 0b) — same creation
#   mechanism, same read-side blind spot, same root-class
#   (root-class:unreachable-by-construction). ga-5jyo8's own text only
#   describes the quality-gate-marker instance it happened to hit, but names
#   the fix as "the exact complement of the dispatcher's query, inverted" —
#   the dispatcher/guard's queries cover both types, so the complement does
#   too. Covering only one type would leave the other exposed to the
#   identical bug for zero extra detection cost saved.
#
# QUERY (ga-5jyo8's own prescription: "don't replicate the --label-any
# enumeration, invert it" — enumerating known gate-status values is the
# fragile thing that produced this blind spot; a new status value would
# silently create another one):
#   bd -C "$HQ" list --label-any type:quality-gate-marker \
#                     --label-any type:quality-gate-run --status open --json
#   | jq 'keep records with NO label starting "gate-status:"'
# Gate markers/runs are ALWAYS created in the HQ/GC_CITY store (gate-done.md,
# quality-gate-guard.sh) — unlike gate-orphaned-label-watchdog.sh (which
# watches TARGET beads scattered across every rig store), this only ever
# needs to query ONE store. That also means the "some stores fail, some
# succeed in the same sweep" ambiguity that motivated GOLW's per-id
# re-verification-before-prune machinery (ga-tqe4j) cannot arise here: this
# script's single query either succeeds (trust the result fully, prune
# anything no longer in it) or fails (skip the WHOLE sweep, touch nothing) —
# see run_sweep's fail-open branch below. Deliberately simpler than GOLW for
# that reason, not an oversight.
#
# GRACE PERIOD (GMMSW_GRACE_MINUTES, default 5): unlike a bead transitioning
# between gate states over its lifetime (GOLW's 180min default, tuned for
# that longer natural cadence), a marker/run's gate-status label loss (when
# it happens) happens ONCE, atomically, at creation — there is no legitimate
# later "mid-transition" window where zero gate-status:* labels is expected.
# The grace period exists purely as a defensive buffer against reading a
# record a beat before its creation is fully visible, not because a
# longer-lived transient state is expected. Short by design — the bug's own
# acceptance criterion is "detected in minutes, not days."
#
# WHY DETECTION-ONLY, NOT AUTO-REPAIR: ga-5jyo8's FIX section offers repair
# ("alerte (ou repare pra gate-status:ready)") as an option, but its ACEITE
# (acceptance) section only requires DETECTION — "the value is in detection,
# not the repair" (bead's own words). Auto-adding gate-status:ready to any
# zero-status marker/run is tempting (cheap, and would have self-healed the
# real incident instantly) but not obviously safe: this script cannot
# distinguish "label lost at creation" (repair would be correct) from
# "observed mid-transition between two atomic bd update
# --add-label/--remove-label calls elsewhere in the pipeline" (repair could
# reintroduce a record that was legitimately leaving the ready queue back
# into it — the same double-dispatch failure class as the routed-pool
# janitor R3 incident). Same precedent and reasoning as
# gate-orphaned-label-watchdog.sh's own header: "Detection-only is the safer
# starting point; auto-remediation (if ever wanted) should be a separate,
# later decision made with real detector data in hand."
#
# ALERTING: per-marker durable `bd comment` (new-or-cooldown-expired only) +
# aggregate `notify -p 2` (ops/triage finding for the Mayor, not a page — same
# priority precedent as GOLW) + `gc mail send mayor`. Cooldown-gated via a
# local state file, same shape/idiom as gate-orphaned-label-watchdog.sh's.
#
# NEVER TOUCHES CLOSED MARKERS: the query itself filters --status open, PLUS
# an independent `select(.status == "open")` inside the jq filter as
# defense-in-depth (so a closed record slipping through the CLI flag for any
# reason is still excluded by this script's own logic, not just trusted to
# the flag) — this directly satisfies ga-5jyo8's acceptance bullet "o guard
# NAO deve alterar markers fechados." In fact this script never mutates ANY
# bead regardless of status (see WHY DETECTION-ONLY above) — the extra check
# is about which records even get COMMENTED ON / included in an alert, not
# about a mutation this script never performs anyway.
#
# FAIL-OPEN: any bd/jq query error → skip the sweep entirely, log a WARN,
# touch nothing (no comment/notify/mail/state write) — a failed read must
# never be conflated with "confirmed nothing to flag" (ga-p5q3 defense (a)).
#
# KILL-SWITCH: GMMSW_ENABLED=0 → no-op.
# DRY-RUN: GMMSW_DRY_RUN=1 → log findings, skip comment/notify/mail/state-write.
#
# Selftest: bash gate-marker-missing-status-watchdog.sh --selftest
set -uo pipefail

# ── config (all env-overridable) ────────────────────────────────────────────
GMMSW_ENABLED="${GMMSW_ENABLED:-1}"
GMMSW_DRY_RUN="${GMMSW_DRY_RUN:-0}"
GMMSW_GRACE_MINUTES="${GMMSW_GRACE_MINUTES:-5}"
GMMSW_ALERT_COOLDOWN_S="${GMMSW_ALERT_COOLDOWN_S:-21600}"   # 6h — matches GOLW precedent
GMMSW_NOTIFY_PRIORITY="${GMMSW_NOTIFY_PRIORITY:-2}"

HQ="${GMMSW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"

LOG="${GMMSW_LOG:-$HQ/.gc/logs/gate-marker-missing-status-watchdog.log}"
NOTIFY_BIN="${GMMSW_NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
GC_BIN="${GMMSW_GC_BIN:-gc}"
BD_BIN="${GMMSW_BD_BIN:-bd}"

GMMSW_STATE_DIR="${GMMSW_STATE_DIR:-$HOME/.gastown/state}"
STATE_FILE="${GMMSW_STATE_FILE:-$GMMSW_STATE_DIR/gate-marker-missing-status-watchdog.state.json}"

# ── helpers ──────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [gmmsw] $*" >> "$LOG" 2>/dev/null || true; }

# _state_load — prints the current state JSON (or "{}" on missing/corrupt file, fail-open)
_state_load() {
  if [ -f "$STATE_FILE" ]; then
    jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

run_sweep() {
  if [ "${GMMSW_ENABLED:-1}" != "1" ]; then
    log "disabled (GMMSW_ENABLED=0) — no-op"
    return 0
  fi
  if [ -z "${GMMSW_TEST_MODE:-}" ]; then
    command -v "$BD_BIN" >/dev/null 2>&1 || { log "WARN: bd not on PATH — fail-open, no sweep"; return 0; }
    command -v jq >/dev/null 2>&1 || { log "WARN: jq not on PATH — fail-open, no sweep"; return 0; }
  fi

  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - GMMSW_GRACE_MINUTES * 60 ))

  local state; state="$(_state_load)"

  local cand_json rc
  # --include-infra (ga-vm20x, Mayor 07/08): bd 1.1.0 hides --ephemeral
  # (INFRA) beads from `bd list` by default, and gate markers/runs — this
  # watchdog's entire subject — are born ephemeral. Without this flag the
  # whole candidate set reads as empty and the watchdog can never detect a
  # marker stuck with no gate-status label.
  cand_json=$("$BD_BIN" -C "$HQ" list --include-infra --label-any type:quality-gate-marker \
      --label-any type:quality-gate-run --status open --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "${cand_json:-}" ] || [ "$cand_json" = "null" ]; then
    log "WARN: marker/run query failed (bd/jq exit $rc) — fail-open, sweep skipped, state untouched"
    return 0
  fi

  # Filter: open + zero gate-status:* label + older than the grace cutoff.
  # Emits 7 TSV fields per flagged record: id, artifact-type, full label
  # list, branch, source-bead, bead-rig (label-derived; "?" when the label
  # itself is absent, e.g. a gate-run bead never carries branch:/bead-rig:),
  # age in whole minutes ("?" if the timestamp is unparseable — fail-safe,
  # never blocks the flag on a display-only field).
  local flagged_tsv
  flagged_tsv=$(printf '%s' "$cand_json" | jq -r --argjson cut "$cutoff" '
      [ .[] | select((.status // "") == "open")
            | select((.labels // []) | any(startswith("gate-status:")) | not)
            | select( ((( .created_at // .updated_at // "") | fromdateiso8601?) // 9999999999) < $cut )
      ]
      | .[] | . as $m
      | ($m.labels // []) as $L
      | ( (($m.created_at // $m.updated_at // "") | fromdateiso8601?) // null ) as $epoch
      | [ $m.id,
          ( if ($L | any(. == "type:quality-gate-run")) then "quality-gate-run" else "quality-gate-marker" end ),
          ($L | join(",")),
          ( ($L | map(select(startswith("branch:")))      | .[0] // "branch:?"      | sub("^branch:";"")) ),
          ( ($L | map(select(startswith("source-bead:"))) | .[0] // "source-bead:?" | sub("^source-bead:";"")) ),
          ( ($L | map(select(startswith("bead-rig:")))    | .[0] // "bead-rig:?"    | sub("^bead-rig:";"")) ),
          ( if $epoch then (((now - $epoch) / 60) | floor | tostring) else "?" end )
        ] | @tsv
    ' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARN: filter jq failed — fail-open, sweep skipped, state untouched"
    return 0
  fi

  if [ -z "${flagged_tsv:-}" ]; then
    if [ "$state" = "{}" ]; then
      log "OK: 0 marker/run bead(s) with zero gate-status:* label (>=${GMMSW_GRACE_MINUTES}min old)"
      return 0
    fi
    # Single-store, already-confirmed-successful read (a failed read already
    # returned above) means "absent from this sweep's result" is
    # authoritative here — safe to prune the whole tracked set without
    # GOLW's per-id re-verification-before-prune machinery (see header: that
    # machinery exists specifically for the "some rig stores readable, some
    # not, in the same sweep" ambiguity, which cannot arise with one store).
    local resolved_ids; resolved_ids="$(printf '%s' "$state" | jq -r 'keys[]' 2>/dev/null)"
    printf '%s\n' "${resolved_ids:-}" | while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      log "RESOLVED: $rid no longer has zero gate-status:* label (or no longer open)"
    done
    if [ "${GMMSW_DRY_RUN:-0}" != "1" ] && [ -f "$STATE_FILE" ]; then
      rm -f "$STATE_FILE" 2>/dev/null || true
    fi
    log "OK: 0 marker/run bead(s) with zero gate-status:* label (>=${GMMSW_GRACE_MINUTES}min old)"
    return 0
  fi

  # ── cooldown/state: alert only new-or-cooldown-expired, but always log the
  # FULL current flagged set. Process-substitution (`< <(...)`), NOT a pipe,
  # so `state` mutations inside the loop survive past it (a piped `while`
  # runs in a subshell and would silently lose them). ────────────────────────
  local flagged_ids="[]" to_alert_tsv=""
  local bid atype labels branch source_bead bead_rig age_min last_alert
  while IFS=$'\t' read -r bid atype labels branch source_bead bead_rig age_min; do
    [ -z "${bid:-}" ] && continue
    flagged_ids="$(printf '%s' "$flagged_ids" | jq -c --arg id "$bid" '. + [$id]' 2>/dev/null)" || flagged_ids="$flagged_ids"
    last_alert="$(printf '%s' "$state" | jq -r --arg id "$bid" '.[$id].last_alert // 0' 2>/dev/null)"
    case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
    if [ "$last_alert" -eq 0 ] || [ $(( now - last_alert )) -ge "$GMMSW_ALERT_COOLDOWN_S" ]; then
      to_alert_tsv="${to_alert_tsv}${bid}\t${atype}\t${labels}\t${branch}\t${source_bead}\t${bead_rig}\t${age_min}\n"
      state="$(printf '%s' "$state" | jq -c --arg id "$bid" --argjson now "$now" \
        '.[$id] = {first_seen: (.[$id].first_seen // $now), last_alert: $now}' 2>/dev/null)"
    fi
  done < <(printf '%s\n' "$flagged_tsv")

  # Resolved: tracked in state but not in this sweep's flagged set.
  local resolved_ids_json; resolved_ids_json="$(printf '%s' "$state" | jq -c --argjson keep "$flagged_ids" 'keys - $keep' 2>/dev/null)"
  [ -z "${resolved_ids_json:-}" ] && resolved_ids_json="[]"
  local resolved_ids; resolved_ids="$(printf '%s' "$resolved_ids_json" | jq -r '.[]' 2>/dev/null)"
  if [ -n "${resolved_ids:-}" ]; then
    state="$(printf '%s' "$state" | jq -c --argjson gone "$resolved_ids_json" 'with_entries(select(.key as $k | ($gone | index($k)) == null))' 2>/dev/null)"
    [ -z "${state:-}" ] && state="{}"
  fi

  local total_flagged; total_flagged="$(printf '%s\n' "$flagged_tsv" | grep -c . || true)"
  local new_count; new_count="$(printf '%b' "$to_alert_tsv" | grep -c . || true)"
  local resolved_count; resolved_count="$(printf '%s\n' "${resolved_ids:-}" | grep -c . || true)"

  log "FLAGGED: ${total_flagged} marker/run bead(s) with zero gate-status:* label (>=${GMMSW_GRACE_MINUTES}min old)"
  printf '%s\n' "$flagged_tsv" | while IFS=$'\t' read -r bid atype labels branch source_bead bead_rig age_min; do
    [ -z "${bid:-}" ] && continue
    log "  - $bid (${atype}) age=${age_min}min labels=[${labels}] branch=${branch} source-bead=${source_bead} bead-rig=${bead_rig}"
  done

  if [ "${new_count:-0}" -eq 0 ] && [ "${resolved_count:-0}" -eq 0 ]; then
    log "OK: all ${total_flagged} flagged bead(s) already alerted within cooldown (${GMMSW_ALERT_COOLDOWN_S}s) — no new notification"
    if [ "${GMMSW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$GMMSW_STATE_DIR" 2>/dev/null || true
      printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
    fi
    return 1
  fi

  if [ "${GMMSW_DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would comment on new/due bead(s), notify (-p ${GMMSW_NOTIFY_PRIORITY}), and mail mayor; state not persisted"
    return 1
  fi

  # ── per-bead durable comment (new-or-cooldown-expired only) ───────────────
  local msg
  while IFS=$'\t' read -r bid atype labels branch source_bead bead_rig age_min; do
    [ -z "${bid:-}" ] && continue
    msg="gate-marker-missing-status-watchdog (ga-5jyo8): this ${atype} bead has NO gate-status:* label — labels=[${labels}]. UNREACHABLE BY CONSTRUCTION: both quality-gate-guard.sh and quality-gate-dispatcher.sh select exclusively by gate-status:{ready,queued,claimed,dispatching,running,...} OR-sets, so this record will never be picked up by any sweep at any age until a gate-status:* label is added. branch=${branch} source-bead=${source_bead} bead-rig=${bead_rig} age=${age_min}min. Detection-only report — no label was added by this watchdog. Likely cause: partial label loss during the original multi-label 'bd create' at this record's creation (see ga-5jyo8, ga-hmcs0). A human/Mayor should confirm the intended state from context (commonly gate-status:ready for a freshly-submitted marker) and add the correct gate-status:* label to un-strand this branch."
    if [ -n "${GMMSW_TEST_COMMENTS_LOG:-}" ]; then
      echo "comment:${bid}" >> "$GMMSW_TEST_COMMENTS_LOG" 2>/dev/null || true
    else
      printf '%s' "$msg" | "$BD_BIN" -C "$HQ" comment "$bid" --stdin 2>/dev/null || log "WARN: bd comment failed for $bid"
    fi
  done < <(printf '%b' "$to_alert_tsv")

  # ── aggregate notify + mail ─────────────────────────────────────────────
  local unchanged_count=$(( total_flagged - new_count ))
  local summary="GATE MARKER/RUN MISSING gate-status: ${new_count} new/due, ${resolved_count} resolved, ${unchanged_count} unchanged-already-reported — ${total_flagged} total currently flagged (>=${GMMSW_GRACE_MINUTES}min old)."

  if [ -n "${GMMSW_TEST_NOTIFIED:-}" ]; then
    echo "notify:$summary" >> "$GMMSW_TEST_NOTIFIED" 2>/dev/null || true
  else
    command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
      "${NOTIFY_BIN}" -t "Gate: marker/run missing gate-status" -p "${GMMSW_NOTIFY_PRIORITY}" "$summary" 2>/dev/null || true
  fi

  local mail_body="GATE MARKER/RUN MISSING-STATUS WATCHDOG — detection-only report (ga-5jyo8).

${summary}
"
  if [ "${new_count:-0}" -gt 0 ]; then
    local new_lines; new_lines="$(printf '%b' "$to_alert_tsv" | while IFS=$'\t' read -r bid atype labels branch source_bead bead_rig age_min; do
      [ -z "${bid:-}" ] && continue
      echo "  ${bid}  (${atype})  age=${age_min}min  labels=[${labels}]  branch=${branch}  source-bead=${source_bead}  bead-rig=${bead_rig}"
    done)"
    mail_body="${mail_body}
NEW/DUE (${new_count}) — why this cycle alerted:
${new_lines}
"
  fi
  if [ "${resolved_count:-0}" -gt 0 ]; then
    local resolved_lines; resolved_lines="$(printf '%s\n' "$resolved_ids" | while IFS= read -r rid; do
      [ -z "${rid:-}" ] && continue
      echo "  ${rid}  (no longer zero gate-status:*, or no longer open)"
    done)"
    mail_body="${mail_body}
RESOLVED (${resolved_count}) since last alert:
${resolved_lines}
"
  fi
  if [ "${unchanged_count:-0}" -gt 0 ]; then
    mail_body="${mail_body}
+${unchanged_count} already reported previously, unchanged — see the log for the full current list.
"
  fi
  mail_body="${mail_body}
This is DETECTION-ONLY — no gate-status:* label was added to any bead by
this watchdog (see the script header for why auto-repair was considered and
deferred). Per-bead detail for NEW/DUE beads is also posted as a comment on
each bead. Re-alerts for an already-flagged bead are suppressed for
${GMMSW_ALERT_COOLDOWN_S}s (state: ${STATE_FILE}). Full current list always
in the log: ${LOG}"

  if [ -n "${GMMSW_TEST_MAILED:-}" ]; then
    { echo "mail:gate-marker-missing-status:$summary"; printf '%s\n' "$mail_body"; } >> "$GMMSW_TEST_MAILED" 2>/dev/null || true
  else
    command -v "$GC_BIN" >/dev/null 2>&1 && \
      "$GC_BIN" mail send mayor \
        -s "Watchdog: ${total_flagged} gate marker/run(s) missing gate-status:* label (unreachable by construction)" \
        -m "$mail_body" 2>/dev/null || true
  fi

  mkdir -p "$GMMSW_STATE_DIR" 2>/dev/null || true
  printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true

  return 1
}

# ── selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${GMMSW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  GMMSW_TEST_MODE=1
  LOG="$TMP/gmmsw.log"
  NOTIFY_BIN="$TMP/notify"
  GC_BIN="$TMP/gc"
  BD_BIN="$TMP/bd"
  GMMSW_ENABLED=1
  GMMSW_DRY_RUN=0
  GMMSW_GRACE_MINUTES=5
  GMMSW_ALERT_COOLDOWN_S=21600
  GMMSW_STATE_DIR="$TMP/state"
  STATE_FILE="$TMP/state/gmmsw.state.json"
  HQ="$TMP/hq"

  mkdir -p "$TMP/fixtures" "$GMMSW_STATE_DIR"

  # Fake bd: single store, routes on verb only (this script only ever issues
  # one `list` shape and one `comment` shape against ONE store).
  cat > "$BD_BIN" <<'BDSTUB'
#!/usr/bin/env bash
verb="$3"
case "$verb" in
  list)
    f="$GMMSW_TEST_FIXTURES_DIR/candidates.json"
    if [ -f "$f" ] && grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
      echo "simulated bd failure: connection refused" >&2
      exit 1
    fi
    [ -f "$f" ] && cat "$f" || echo "[]"
    ;;
  comment)
    bid="$4"
    echo "comment:${bid}" >> "${GMMSW_TEST_COMMENTS_LOG:-/dev/null}"
    ;;
  *) echo "[]" ;;
esac
BDSTUB
  chmod +x "$BD_BIN"
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$GMMSW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$NOTIFY_BIN"
  printf '#!/usr/bin/env bash\n[ "$1" = "mail" ] && echo "mail:$*" >> "$GMMSW_TEST_MAILED" 2>/dev/null; exit 0\n' > "$GC_BIN"
  chmod +x "$NOTIFY_BIN" "$GC_BIN"

  export GMMSW_TEST_FIXTURES_DIR="$TMP/fixtures"

  OLD_TS="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  FRESH_TS="$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"

  mk() {  # id status labels_csv created_at
    local id="$1" status="$2" labels="$3" created="$4"
    local labels_json; labels_json="$(printf '%s' "$labels" | tr ',' '\n' | jq -R . | jq -s -c .)"
    printf '{"id":"%s","status":"%s","created_at":"%s","labels":%s}' "$id" "$status" "$created" "$labels_json"
  }

  # ── Scenario 1: marker missing gate-status, aged past grace → FLAGGED ─────
  echo "Scenario 1: marker missing gate-status:*, aged past grace → flagged"
  printf '[%s]' "$(mk mk-a open 'type:quality-gate-marker,branch:crew/wa-worker/wa-x,source-bead:wa-x,bead-rig:whatsapp_automation' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N1="$TMP/notif1"; M1="$TMP/mail1"; C1="$TMP/comm1"; : > "$N1"; : > "$M1"; : > "$C1"
  GMMSW_TEST_NOTIFIED="$N1" GMMSW_TEST_MAILED="$M1" GMMSW_TEST_COMMENTS_LOG="$C1" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 1: flagged (return 1)" || bad "scenario 1: should return 1 (flagged), got $rc"
  grep -q "comment:mk-a" "$C1" 2>/dev/null && ok "scenario 1: bd comment posted on mk-a" || bad "scenario 1: no comment posted"
  grep -q "notify:" "$N1" 2>/dev/null && ok "scenario 1: notify fired" || bad "scenario 1: notify did NOT fire"
  grep -q "mail:" "$M1" 2>/dev/null && ok "scenario 1: mayor mailed" || bad "scenario 1: mayor NOT mailed"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 2 (core ACEITE requirement): fully-labeled marker → NEVER flags ──
  echo "Scenario 2: fully-labeled marker (incl. gate-status:ready) → NOT flagged, even though old"
  printf '[%s]' "$(mk mk-b open 'type:quality-gate-marker,gate-status:ready,branch:crew/x,source-bead:x,bead-rig:gascity' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N2="$TMP/notif2"; M2="$TMP/mail2"; C2="$TMP/comm2"; : > "$N2"; : > "$M2"; : > "$C2"
  GMMSW_TEST_NOTIFIED="$N2" GMMSW_TEST_MAILED="$M2" GMMSW_TEST_COMMENTS_LOG="$C2" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 2: complete marker never flags (return 0)" || bad "scenario 2: a fully-labeled marker must not flag, got $rc"
  [ ! -s "$C2" ] && ok "scenario 2: no comment posted" || bad "scenario 2: comment posted on a fully-labeled marker (false positive)"
  [ ! -s "$N2" ] && ok "scenario 2: no notify" || bad "scenario 2: notify fired on a fully-labeled marker (false positive)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 3: missing gate-status but too FRESH → NOT flagged yet ───────
  echo "Scenario 3: missing gate-status:*, but only 1min old → NOT flagged (below grace)"
  printf '[%s]' "$(mk mk-c open 'type:quality-gate-marker,branch:x,source-bead:x,bead-rig:x' "$FRESH_TS")" > "$TMP/fixtures/candidates.json"
  N3="$TMP/notif3"; M3="$TMP/mail3"; C3="$TMP/comm3"; : > "$N3"; : > "$M3"; : > "$C3"
  GMMSW_TEST_NOTIFIED="$N3" GMMSW_TEST_MAILED="$M3" GMMSW_TEST_COMMENTS_LOG="$C3" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 3: fresh marker not yet flagged (return 0)" || bad "scenario 3: should not flag within grace period, got $rc"
  [ ! -s "$C3" ] && ok "scenario 3: no comment posted (still in grace)" || bad "scenario 3: comment posted before grace elapsed"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 4: a CLOSED record missing gate-status → must NEVER be touched ──
  echo "Scenario 4: closed record missing gate-status:* → never touched (defense-in-depth, independent of the --status open CLI flag)"
  printf '[%s]' "$(mk mk-d closed 'type:quality-gate-marker,branch:x,source-bead:x,bead-rig:x' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N4="$TMP/notif4"; M4="$TMP/mail4"; C4="$TMP/comm4"; : > "$N4"; : > "$M4"; : > "$C4"
  GMMSW_TEST_NOTIFIED="$N4" GMMSW_TEST_MAILED="$M4" GMMSW_TEST_COMMENTS_LOG="$C4" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 4: closed record ignored (return 0)" || bad "scenario 4: closed record must never flag, got $rc"
  [ ! -s "$C4" ] && ok "scenario 4: no comment on closed record" || bad "scenario 4 (ACEITE violation): commented on a CLOSED marker"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5: cooldown suppresses re-alert on second sweep ─────────────
  echo "Scenario 5: same marker flagged twice in a row within cooldown → only the FIRST sweep alerts"
  printf '[%s]' "$(mk mk-e open 'type:quality-gate-marker,branch:x,source-bead:x,bead-rig:x' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N5a="$TMP/notif5a"; M5a="$TMP/mail5a"; C5a="$TMP/comm5a"; : > "$N5a"; : > "$M5a"; : > "$C5a"
  GMMSW_TEST_NOTIFIED="$N5a" GMMSW_TEST_MAILED="$M5a" GMMSW_TEST_COMMENTS_LOG="$C5a" run_sweep >/dev/null
  grep -q "comment:mk-e" "$C5a" 2>/dev/null && ok "scenario 5: first sweep alerts" || bad "scenario 5: first sweep should alert"
  N5b="$TMP/notif5b"; M5b="$TMP/mail5b"; C5b="$TMP/comm5b"; : > "$N5b"; : > "$M5b"; : > "$C5b"
  GMMSW_TEST_NOTIFIED="$N5b" GMMSW_TEST_MAILED="$M5b" GMMSW_TEST_COMMENTS_LOG="$C5b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 5: second sweep still reports flagged (return 1)" || bad "scenario 5: still-broken marker should still return 1, got $rc"
  [ ! -s "$C5b" ] && ok "scenario 5: second sweep does NOT re-comment (cooldown)" || bad "scenario 5: cooldown did not suppress re-comment"
  [ ! -s "$N5b" ] && ok "scenario 5: second sweep does NOT re-notify (cooldown)" || bad "scenario 5: cooldown did not suppress re-notify"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 6: resolution — marker fixed between sweeps → pruned from state ──
  echo "Scenario 6: marker gets gate-status:ready added between sweeps → RESOLVED, pruned from state"
  printf '[%s]' "$(mk mk-f open 'type:quality-gate-marker,branch:x,source-bead:x,bead-rig:x' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  : > "$TMP/notif6a"; : > "$TMP/mail6a"; : > "$TMP/comm6a"
  GMMSW_TEST_NOTIFIED="$TMP/notif6a" GMMSW_TEST_MAILED="$TMP/mail6a" GMMSW_TEST_COMMENTS_LOG="$TMP/comm6a" run_sweep >/dev/null
  grep -q '"mk-f"' "$STATE_FILE" 2>/dev/null && ok "scenario 6: mk-f tracked in state after first sweep" || bad "scenario 6: mk-f should be tracked after first sweep"
  echo '[]' > "$TMP/fixtures/candidates.json"   # simulates: label was fixed, no longer matches the query
  : > "$LOG"
  : > "$TMP/notif6b"; : > "$TMP/mail6b"; : > "$TMP/comm6b"
  GMMSW_TEST_NOTIFIED="$TMP/notif6b" GMMSW_TEST_MAILED="$TMP/mail6b" GMMSW_TEST_COMMENTS_LOG="$TMP/comm6b" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 6: nothing flagged after fix (return 0)" || bad "scenario 6: should be clean after fix, got $rc"
  grep -q '"mk-f"' "$STATE_FILE" 2>/dev/null && bad "scenario 6: mk-f still in state after being resolved" || ok "scenario 6: mk-f pruned from state"
  grep -q "RESOLVED: mk-f" "$LOG" 2>/dev/null && ok "scenario 6: RESOLVED logged for mk-f" || bad "scenario 6: no RESOLVED log line for mk-f"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 7: dry-run → detects but does not mutate/alert/persist ──────
  echo "Scenario 7: GMMSW_DRY_RUN=1 → logs the finding, fires nothing, persists nothing"
  printf '[%s]' "$(mk mk-g open 'type:quality-gate-marker,branch:x,source-bead:x,bead-rig:x' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N7="$TMP/notif7"; M7="$TMP/mail7"; C7="$TMP/comm7"; : > "$N7"; : > "$M7"; : > "$C7"
  GMMSW_DRY_RUN=1 GMMSW_TEST_NOTIFIED="$N7" GMMSW_TEST_MAILED="$M7" GMMSW_TEST_COMMENTS_LOG="$C7" run_sweep
  rc=$?
  GMMSW_DRY_RUN=0
  [ "$rc" -eq 1 ] && ok "scenario 7: dry-run still reports flagged (return 1)" || bad "scenario 7: dry-run should still report flagged, got $rc"
  [ ! -s "$C7" ] && [ ! -s "$N7" ] && [ ! -s "$M7" ] && ok "scenario 7: no comment/notify/mail fired in dry-run" || bad "scenario 7: dry-run must not fire any side effect"
  [ ! -f "$STATE_FILE" ] && ok "scenario 7: no state file written in dry-run" || bad "scenario 7: dry-run must not persist state"

  # ── Scenario 8: kill-switch → complete no-op ──────────────────────────────
  echo "Scenario 8: GMMSW_ENABLED=0 → complete no-op"
  printf '[%s]' "$(mk mk-h open 'type:quality-gate-marker,branch:x,source-bead:x,bead-rig:x' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N8="$TMP/notif8"; M8="$TMP/mail8"; C8="$TMP/comm8"; : > "$N8"; : > "$M8"; : > "$C8"
  GMMSW_ENABLED=0 GMMSW_TEST_NOTIFIED="$N8" GMMSW_TEST_MAILED="$M8" GMMSW_TEST_COMMENTS_LOG="$C8" run_sweep
  rc=$?
  GMMSW_ENABLED=1
  [ "$rc" -eq 0 ] && ok "scenario 8: kill-switch returns 0" || bad "scenario 8: kill-switch should return 0, got $rc"
  [ ! -s "$C8" ] && [ ! -s "$N8" ] && [ ! -s "$M8" ] && ok "scenario 8: no side effect while disabled" || bad "scenario 8: disabled watchdog fired a side effect"

  # ── Scenario 9: bd query failure → fail-open, no false flag ───────────────
  echo "Scenario 9: bd list fails → fail-open, WARN logged, nothing flagged, state untouched"
  printf '{"mk-preexisting":{"first_seen":1,"last_alert":1}}' > "$STATE_FILE"
  echo '__BD_FAIL__' > "$TMP/fixtures/candidates.json"
  : > "$LOG"
  N9="$TMP/notif9"; M9="$TMP/mail9"; C9="$TMP/comm9"; : > "$N9"; : > "$M9"; : > "$C9"
  GMMSW_TEST_NOTIFIED="$N9" GMMSW_TEST_MAILED="$M9" GMMSW_TEST_COMMENTS_LOG="$C9" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 9: query failure returns 0 (fail-open, not an alert)" || bad "scenario 9: query failure should return 0, got $rc"
  grep -q "WARN.*fail-open" "$LOG" 2>/dev/null && ok "scenario 9: WARN logged" || bad "scenario 9: no fail-open WARN logged"
  [ ! -s "$C9" ] && [ ! -s "$N9" ] && [ ! -s "$M9" ] && ok "scenario 9: no false-positive side effect on query failure" || bad "scenario 9: query failure fired a side effect"
  grep -q '"mk-preexisting"' "$STATE_FILE" 2>/dev/null && ok "scenario 9: pre-existing state untouched on query failure" || bad "scenario 9: state was touched despite a failed read (should be fail-safe)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 10: type:quality-gate-run (not -marker) also flags ──────────
  echo "Scenario 10: a quality-gate-run bead (no branch:/bead-rig: labels) missing gate-status:* → also flagged"
  printf '[%s]' "$(mk gr-a open 'type:quality-gate-run,source-bead:wa-y' "$OLD_TS")" > "$TMP/fixtures/candidates.json"
  N10="$TMP/notif10"; M10="$TMP/mail10"; C10="$TMP/comm10"; : > "$N10"; : > "$M10"; : > "$C10"
  GMMSW_TEST_NOTIFIED="$N10" GMMSW_TEST_MAILED="$M10" GMMSW_TEST_COMMENTS_LOG="$C10" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 10: quality-gate-run bead flagged too (return 1)" || bad "scenario 10: a gate-run bead missing gate-status must also flag, got $rc"
  grep -q "comment:gr-a" "$C10" 2>/dev/null && ok "scenario 10: comment posted on gr-a" || bad "scenario 10: no comment posted on gate-run bead"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 11: bash -n syntax check ──────────────────────────────────────
  echo "Scenario 11: bash -n syntax check"
  bash -n "$0" 2>/dev/null && ok "scenario 11: bash -n passes" || bad "scenario 11: bash -n FAILED — syntax error"

  echo ""
  echo "gate-marker-missing-status-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep; exit 0  # daemon health = "ran OK"; findings (if any) already sent via comment+notify+mail
