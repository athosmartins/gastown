#!/usr/bin/env bash
# gate-orphaned-label-watchdog.sh — detects beads carrying a gate:* lifecycle
# label with ZERO active quality-gate-marker/-run behind them, for longer than
# a configurable age threshold.
#
# WHY THIS EXISTS (ga-l8yh6, follow-up AC4 of ga-d3eg2):
#   ga-d3eg2 fixed the ownership-guard deadlock (gate:needs-fix stripped but
#   gate:fix-attempt:N survives — pilot-dispatcher.sh's _ownership_guard_should_refuse
#   and _filter_built now carve out on gate:fix-attempt:N alone too). That closed
#   the DEADLOCK, but the underlying VISIBILITY gap it measured remains: a bead
#   can carry a gate:* lifecycle label with no active marker/run behind it for a
#   long time before anyone notices. ga-d3eg2's own one-off measurement found 8
#   such beads, some stuck 10+ days — different root causes per bead (stale
#   label, branch conflicts needing re-anchor, already-merged-but-bead-
#   never-closed, or intentionally parked at gate:needs-human/blocked-by:*).
#   gate-throughput-stall-watchdog.sh answers "is the GATE stalled" (queue-level);
#   this answers "is this ONE BEAD stranded" (bead-level) — a bead can be
#   individually stuck while the gate itself is healthy and processing other work.
#
# LOGIC (runs every ~900s via launchd):
#   1. For each rig store in GOLW_STORES: list non-closed beads (bd's default
#      view already excludes status=closed — no --all/--status needed here,
#      verified live against bd 1.0.5), keep those carrying >=1 label starting
#      with "gate:" (the TARGET bead's lifecycle namespace — distinct from an
#      artifact's gate-status:* namespace, so artifact beads can never leak in
#      as false candidates even if a store listing ever included them).
#   2. Age-gate: skip any candidate whose updated_at (fallback created_at) is
#      younger than GOLW_STALE_MINUTES — avoids flagging a bead mid-transition
#      between gate states.
#   3. For each aged candidate, replicate pilot-dispatcher.sh's signal-(d) check
#      (_beadid_has_active_gate_artifact, ~line 3212) against the HQ store: an
#      OPEN type:quality-gate-marker/-run labeled source-bead:<id> at an ACTIVE
#      gate-status (ready/claimed/queued/dispatching/reviewing/running) means
#      the gate IS holding the branch right now — not orphaned, skip. Otherwise
#      (no artifact at all, OR only parked/terminal ones like needs-rebase/
#      error/passed/failed/superseded/deferred, OR a closed artifact) → FLAG.
#   4. Report only — this daemon NEVER mutates a bead (no label/status/assignee/
#      close calls of any kind). Per-bead: `bd comment` (durable, lives on the
#      bead itself). Aggregate: `notify` (low priority — see note below) +
#      `gc mail send mayor`. Re-alerting on an already-flagged bead is
#      cooldown-gated (GOLW_ALERT_COOLDOWN_S) via a local state file so a
#      persistently-stuck bead doesn't spam a fresh alert every ~15min forever.
#
# WHY DETECTION-ONLY, NO AUTO-CORRECT: lifecycle-coherence-janitor.sh's R4/R5
# history (memory: lifecycle-janitor-R4-R5-false-positive-corrupts-pipeline) —
# automated correctors in this exact problem class ("reclaim can't reliably
# tell live from dead") force-closed an ACTIVELY-FAILING gate:needs-fix bead
# and cleared a live builder's assignee mid-build, causing duplicate work.
# ga-d3eg2 explicitly scoped this follow-up to detection-only for that reason:
# "Detection-only is the safer starting point; auto-remediation (if ever
# wanted) should be a separate, later decision made with real detector data in
# hand." Some flagged beads are EXPECTED to look this way (gate:needs-human,
# blocked-by:*) — this watchdog does not try to distinguish "expected park"
# from "silently stranded"; it surfaces the raw labels so a human/Mayor can.
#
# NOTIFY PRIORITY: low (-p 2), not the -p 4 used by throughput-stall-watchdog.
# That watchdog pages Athos only when auto-recovery of a SYSTEMIC stall fails
# (Athos, 2026-06-30: "só me notifique quando a máquina precisar de mim"). A
# single stranded bead is an ops/triage finding for the Mayor, not something
# that needs Athos's phone — gc mail send mayor is the primary, actionable
# channel here; notify is a low-priority heads-up, not a page.
#
# FAIL-OPEN: any bd/jq/store-read error → skip that store/candidate, log a
# WARN, never let a read failure masquerade as "confirmed orphaned" (ga-p5q3
# defense (a): a failed query is not the same value as zero/confirmed).
#
# KILL-SWITCH: GOLW_ENABLED=0 → no-op.
# DRY-RUN: GOLW_DRY_RUN=1 → log findings, skip comment/notify/mail/state-write.
#
# Selftest: bash gate-orphaned-label-watchdog.sh --selftest
set -uo pipefail

# ── config (all env-overridable) ──────────────────────────────────────────────
GOLW_ENABLED="${GOLW_ENABLED:-1}"
GOLW_DRY_RUN="${GOLW_DRY_RUN:-0}"
GOLW_STALE_MINUTES="${GOLW_STALE_MINUTES:-180}"          # 3h — generous vs. normal gate-review latency (p99 ~240min per GTSW)
GOLW_ALERT_COOLDOWN_S="${GOLW_ALERT_COOLDOWN_S:-21600}"   # 6h — per-bead re-alert dedup window
GOLW_NOTIFY_PRIORITY="${GOLW_NOTIFY_PRIORITY:-2}"

HQ="${GOLW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
# Default sweep set = all rigs registered live at authoring time (`gc rig list`,
# 2026-08-03). Static + env-overridable (matches LCJ_STORES precedent in
# lifecycle-coherence-janitor.sh) rather than calling `gc rig list` every sweep
# — that call runs 8-17s under Dolt load, not worth paying every ~900s cycle
# for a set that changes rarely. If a new rig is added, update this default or
# override GOLW_STORES.
GOLW_STORES="${GOLW_STORES:-$HQ /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers /Users/athos/gt/marketing /Users/athos/gt/lexbh /Users/athos/gt/gastown /Users/athos/gt/deacon}"

# Label prefixes that start with "gate:" but are NOT part of the automated
# code-review gate lifecycle this watchdog audits, so they never carry (and
# were never meant to carry) a type:quality-gate-marker/-run artifact — a
# perpetual, meaningless flag rather than a real finding. Confirmed live
# (2026-08-03) via wa-kty2h/wa-5u2cv/wa-kty2h-class beads: gate:prod-deploy:*
# is a hand-applied "shipped, needs Athos's manual prod test" marker stamped
# AFTER the code-review gate already passed (see memory:
# auto-refino-raw-ingestion-4th-occurrence-timing-race-hypothesis) — grep of
# scripts/ + packs/town-deltas/assets/ found zero write-sites for it in any
# quality-gate-*/pilot-dispatcher code, confirming it's outside that pipeline
# entirely. Space-separated, env-overridable if another such family turns up.
GOLW_EXCLUDE_LABEL_PREFIXES="${GOLW_EXCLUDE_LABEL_PREFIXES:-gate:prod-deploy:}"

LOG="${GOLW_LOG:-$HQ/.gc/logs/gate-orphaned-label-watchdog.log}"
NOTIFY_BIN="${GOLW_NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
GC_BIN="${GOLW_GC_BIN:-gc}"
BD_BIN="${GOLW_BD_BIN:-bd}"

GOLW_STATE_DIR="${GOLW_STATE_DIR:-$HOME/.gastown/state}"
STATE_FILE="${GOLW_STATE_FILE:-$GOLW_STATE_DIR/gate-orphaned-label-watchdog.state.json}"

# ── helpers ───────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [golw] $*" >> "$LOG" 2>/dev/null || true; }

_store_name() { basename "$1"; }

# _gate_artifact_probe <bead_id>
# Prints "<active:0|1>\t<last_artifact_gate_status_or_none>\t<open_artifact_count>"
# The active bit replicates pilot-dispatcher.sh's _beadid_has_active_gate_artifact
# (ga-wisp signal (d), ~line 3212) EXACTLY — same active-state set, same query
# shape (bd list -l "source-bead:<id>" against the HQ store; empirically
# verified 2026-08-03 that this label-scoped query surfaces
# type:quality-gate-marker/-run beads without needing --all/--include-gates).
# The other two fields are reporting-only extras computed from the same read.
# Test seam: routes through $BD_BIN, stubbed in --selftest.
_gate_artifact_probe() {
  local _bid="$1" _arts _out
  _arts=$("$BD_BIN" -C "$HQ" list -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  if [ -z "${_arts:-}" ] || [ "$_arts" = "null" ]; then
    printf '0\tnone\t0\n'
    return 0
  fi
  _out=$(printf '%s' "$_arts" | jq -r '
      [ .[] | select(.status == "open")
            | select( ((.labels // []) | index("type:quality-gate-marker"))
                      or ((.labels // []) | index("type:quality-gate-run")) )
      ] as $open
      | ($open | length) as $n
      | ( [ $open[] | select(
              ((.labels // []) | index("gate-status:ready"))       or
              ((.labels // []) | index("gate-status:claimed"))     or
              ((.labels // []) | index("gate-status:queued"))      or
              ((.labels // []) | index("gate-status:dispatching")) or
              ((.labels // []) | index("gate-status:reviewing"))   or
              ((.labels // []) | index("gate-status:running"))
            ) ] | length ) as $active
      | ( if $n == 0 then "none"
          else ( [ $open[] | (.labels // []) | map(select(startswith("gate-status:"))) | .[0] // empty ]
                 | .[0] // "gate-status:unknown" | sub("^gate-status:"; "") )
          end ) as $laststatus
      | "\(if $active > 0 then 1 else 0 end)\t\($laststatus)\t\($n)"
    ' 2>/dev/null)
  if [ -z "${_out:-}" ]; then
    printf '0\tnone\t0\n'
  else
    printf '%s\n' "$_out"
  fi
}

# _state_load — prints the current state JSON (or "{}" on missing/corrupt file, fail-open)
_state_load() {
  if [ -f "$STATE_FILE" ]; then
    jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

run_sweep() {
  if [ "${GOLW_ENABLED:-1}" != "1" ]; then
    log "disabled (GOLW_ENABLED=0) — no-op"
    return 0
  fi
  if [ -z "${GOLW_TEST_MODE:-}" ]; then
    command -v "$BD_BIN" >/dev/null 2>&1 || { log "WARN: bd not on PATH — fail-open, no sweep"; return 0; }
    command -v jq >/dev/null 2>&1 || { log "WARN: jq not on PATH — fail-open, no sweep"; return 0; }
  fi

  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - GOLW_STALE_MINUTES * 60 ))

  local exclude_prefixes_json
  exclude_prefixes_json="$(printf '%s\n' $GOLW_EXCLUDE_LABEL_PREFIXES | jq -R . | jq -s -c '[.[] | select(length > 0)]' 2>/dev/null)"
  [ -z "${exclude_prefixes_json:-}" ] && exclude_prefixes_json="[]"

  # Accumulate flagged candidates as TSV lines: id\tstore\tage_min\tlabels\tartifact_status\tartifact_count
  local flagged_tsv=""
  local store cand_json aged_json
  for store in $GOLW_STORES; do
    cand_json=$("$BD_BIN" -C "$store" list --json --limit 0 2>/dev/null \
      | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
    if [ -z "${cand_json:-}" ] || [ "$cand_json" = "null" ]; then
      log "WARN: could not read store '$store' (bd query or jq parse failed) — skipping (fail-open)"
      continue
    fi

    # Keep only beads carrying >=1 label in the gate:* TARGET namespace, EXCLUDING:
    #  (a) the gate artifacts (type:quality-gate-marker/-run) themselves —
    #      verified live 2026-08-03 (ga-wisp-fpyxxhp) that a marker bead can
    #      carry its OWN literal gate:* labels (e.g. gate:exiled-tier5:2,
    #      gate:rebase-fail-count:2) alongside its gate-status:* label, so
    #      "different namespace" alone does NOT separate target beads from
    #      artifact beads — the type:* label must be excluded explicitly or a
    #      marker misreads as a stranded target.
    #  (b) GOLW_EXCLUDE_LABEL_PREFIXES (default gate:prod-deploy:) — confirmed
    #      non-pipeline gate:*-prefixed families that will never carry a
    #      quality-gate-marker by design (see config comment above). Only
    #      excludes a bead when ALL of its gate:*-prefixed labels fall in this
    #      family — a bead mixing e.g. gate:prod-deploy:* with a real pipeline
    #      label like gate:queued still gets evaluated, since the pipeline
    #      label means it genuinely may be gate-tracked.
    # Then age-gate via the proven lifecycle-coherence-janitor.sh R3 idiom:
    # unparseable/missing timestamp falls back to a far-future epoch so it
    # NEVER wrongly ages a candidate whose timestamp we can't parse (fail-safe,
    # not fail-alert).
    aged_json=$(printf '%s' "$cand_json" | jq -c --argjson cut "$cutoff" --argjson excl "$exclude_prefixes_json" '
        [ .[] | select((.labels // []) | any(startswith("gate:")))
              | select((.labels // []) | (index("type:quality-gate-marker") or index("type:quality-gate-run")) | not)
              | select( ( (.labels // []) | map(select(startswith("gate:"))) ) as $gl
                        | ( $gl | all(. as $x | $excl | any(. as $p | $x | startswith($p)) ) ) | not )
              | select( ((( .updated_at // .created_at // "") | fromdateiso8601?) // 9999999999) < $cut )
        ]
      ' 2>/dev/null)
    if [ -z "${aged_json:-}" ]; then
      log "WARN: age-filter jq failed for store '$store' — skipping (fail-open)"
      continue
    fi

    local ids_labels
    ids_labels=$(printf '%s' "$aged_json" | jq -r '.[] | [.id, ((.labels//[]) | map(select(startswith("gate:"))) | join(",")), (.updated_at // .created_at // "")] | @tsv' 2>/dev/null)
    [ -z "${ids_labels:-}" ] && continue

    local bid blabels bts age_min probe active lstatus lcount
    while IFS=$'\t' read -r bid blabels bts; do
      [ -z "${bid:-}" ] && continue
      probe="$(_gate_artifact_probe "$bid")"
      active="$(printf '%s' "$probe" | cut -f1)"
      lstatus="$(printf '%s' "$probe" | cut -f2)"
      lcount="$(printf '%s' "$probe" | cut -f3)"
      case "$active" in
        1) continue ;;  # has an ACTIVE marker/run right now — not orphaned, skip
      esac
      local bepoch
      bepoch="$(printf '%s' "$bts" | jq -Rr 'fromdateiso8601? // empty' 2>/dev/null)"
      if [ -n "${bepoch:-}" ]; then
        age_min=$(( (now - bepoch) / 60 ))
      else
        age_min="?"
      fi
      flagged_tsv="${flagged_tsv}${bid}\t${store}\t${age_min}\t${blabels}\t${lstatus}\t${lcount}\n"
    done <<< "$ids_labels"
  done

  if [ -z "${flagged_tsv:-}" ]; then
    # Nothing currently orphaned — clear any stale state so a future episode
    # starts fresh (mirrors GTSW's cooldown-reset-on-clear convention).
    if [ -f "$STATE_FILE" ] && [ "${GOLW_DRY_RUN:-0}" != "1" ]; then
      rm -f "$STATE_FILE" 2>/dev/null || true
      log "STATE CLEARED: no orphaned gate-labeled beads found — previous episode(s) resolved"
    fi
    log "OK: 0 beads with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min) across ${GOLW_STORES}"
    return 0
  fi

  # ── cooldown/state handling: only ALERT on new-or-cooldown-expired beads,
  # but the aggregate report always lists the FULL current flagged set so a
  # human sees the whole picture, not just what's new this cycle. ──
  local state; state="$(_state_load)"
  local flagged_ids="[]"
  local to_alert_tsv=""
  local bid store2 age_min labels lstatus lcount last_alert
  while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    flagged_ids="$(printf '%s' "$flagged_ids" | jq -c --arg id "$bid" '. + [$id]' 2>/dev/null)" || flagged_ids="$flagged_ids"
    last_alert="$(printf '%s' "$state" | jq -r --arg id "$bid" '.[$id].last_alert // 0' 2>/dev/null)"
    case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
    if [ "$last_alert" -eq 0 ] || [ $(( now - last_alert )) -ge "$GOLW_ALERT_COOLDOWN_S" ]; then
      to_alert_tsv="${to_alert_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
      state="$(printf '%s' "$state" | jq -c --arg id "$bid" --argjson now "$now" \
        '.[$id] = {first_seen: (.[$id].first_seen // $now), last_alert: $now, store: (.[$id].store // "")}' 2>/dev/null)"
    fi
  done < <(printf '%b' "$flagged_tsv")

  # Prune resolved beads (no longer in the flagged set) from state.
  local resolved_ids
  resolved_ids="$(printf '%s' "$state" | jq -r --argjson keep "$flagged_ids" 'keys - $keep | .[]' 2>/dev/null)"
  if [ -n "${resolved_ids:-}" ]; then
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      log "RESOLVED: $rid no longer carries an orphaned gate:* label — cleared from state"
    done <<< "$resolved_ids"
    state="$(printf '%s' "$state" | jq -c --argjson keep "$flagged_ids" 'with_entries(select(.key as $k | $keep | index($k) != null))' 2>/dev/null)"
  fi

  local total_flagged; total_flagged="$(printf '%b' "$flagged_tsv" | grep -c . || true)"
  log "FLAGGED: ${total_flagged} bead(s) with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min)"
  printf '%b' "$flagged_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    log "  - $bid ($(_store_name "$store2")) age=${age_min}min labels=[${labels}] last_artifact=${lstatus} (${lcount} open)"
  done

  if [ -z "${to_alert_tsv:-}" ]; then
    log "OK: all ${total_flagged} flagged bead(s) already alerted within cooldown (${GOLW_ALERT_COOLDOWN_S}s) — no new notification"
    if [ "${GOLW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$GOLW_STATE_DIR" 2>/dev/null || true
      printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
    fi
    return 1
  fi

  if [ "${GOLW_DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would comment on new/due bead(s), notify (-p ${GOLW_NOTIFY_PRIORITY}), and mail mayor; state not persisted"
    return 1
  fi

  # ── per-bead durable comment (new-or-cooldown-expired only) ──────────────
  local msg
  while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    msg="gate-orphaned-label-watchdog (ga-l8yh6): this bead carries gate:* label(s) [${labels}] with no ACTIVE quality-gate-marker/-run for >= ${GOLW_STALE_MINUTES}min (age: ${age_min}min). Last known gate artifact: ${lstatus} (${lcount} open artifact(s) referencing this bead; 0 = none ever found in the HQ store). Detection-only report — no label/status/assignee was touched. Common causes seen historically (ga-d3eg2): stale label after a manual fix, branch conflicts needing re-anchor, already-merged-but-never-closed, or an intentional park (gate:needs-human, blocked-by:*) — a human/Mayor should triage."
    if [ -n "${GOLW_TEST_COMMENTS_LOG:-}" ]; then
      echo "comment:${store2}:${bid}:${msg}" >> "$GOLW_TEST_COMMENTS_LOG" 2>/dev/null || true
    else
      printf '%s' "$msg" | "$BD_BIN" -C "$store2" comment "$bid" --stdin 2>/dev/null || log "WARN: bd comment failed for $bid"
    fi
  done < <(printf '%b' "$to_alert_tsv")

  # ── aggregate notify + mail ────────────────────────────────────────────────
  local new_count; new_count="$(printf '%b' "$to_alert_tsv" | grep -c . || true)"
  local summary="GATE ORPHANED LABEL: ${total_flagged} bead(s) carry a gate:* label with zero active marker (>=${GOLW_STALE_MINUTES}min); ${new_count} new/due this cycle."

  if [ -n "${GOLW_TEST_NOTIFIED:-}" ]; then
    echo "notify:$summary" >> "$GOLW_TEST_NOTIFIED" 2>/dev/null || true
  else
    command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
      "${NOTIFY_BIN}" -t "Gate: orphaned label(s)" -p "${GOLW_NOTIFY_PRIORITY}" "$summary" 2>/dev/null || true
  fi

  local mail_body="GATE ORPHANED-LABEL WATCHDOG — detection-only report (ga-l8yh6, follow-up of ga-d3eg2 AC4).
"
  mail_body="${mail_body}
${total_flagged} bead(s) currently carry a gate:* lifecycle label with no active quality-gate-marker/-run (threshold: ${GOLW_STALE_MINUTES}min):
"
  local detail_lines; detail_lines="$(printf '%b' "$flagged_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    echo "  ${bid}  (${store2})  age=${age_min}min  labels=[${labels}]  last_artifact=${lstatus} (${lcount} open)"
  done)"
  mail_body="${mail_body}
${detail_lines}

This is SURFACE-ONLY — no label/status/assignee was touched on any bead. Common
root causes seen historically (ga-d3eg2's own measurement): a stale label left
after a manual fix, a branch that conflicts with main and needs re-anchor, work
already merged but the bead never closed, or an intentional park (gate:needs-human,
blocked-by:*) that just isn't obvious from gate-idleness alone.

Per-bead detail is also posted as a comment on each new/due bead. Re-alerts for
an already-flagged bead are suppressed for ${GOLW_ALERT_COOLDOWN_S}s (state:
${STATE_FILE}). Log: ${LOG}"

  if [ -n "${GOLW_TEST_MAILED:-}" ]; then
    echo "mail:gate-orphaned-label:$summary" >> "$GOLW_TEST_MAILED" 2>/dev/null || true
  else
    command -v "$GC_BIN" >/dev/null 2>&1 && \
      "$GC_BIN" mail send mayor \
        -s "Watchdog: ${total_flagged} bead(s) com gate:* label e zero marker ativo (>=${GOLW_STALE_MINUTES}min)" \
        -m "$mail_body" 2>/dev/null || true
  fi

  mkdir -p "$GOLW_STATE_DIR" 2>/dev/null || true
  printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true

  return 1
}

# ── selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${GOLW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  GOLW_TEST_MODE=1
  LOG="$TMP/golw.log"
  NOTIFY_BIN="$TMP/notify"
  GC_BIN="$TMP/gc"
  BD_BIN="$TMP/bd"
  GOLW_ENABLED=1
  GOLW_DRY_RUN=0
  GOLW_STALE_MINUTES=180
  GOLW_ALERT_COOLDOWN_S=21600
  GOLW_STATE_DIR="$TMP/state"
  STATE_FILE="$TMP/state/golw.state.json"
  HQ="$TMP/hq"
  GOLW_STORES="$TMP/hq $TMP/wa"

  mkdir -p "$TMP/fixtures" "$GOLW_STATE_DIR"

  # Fake bd: routes on the verb + args. Candidate sweep = `list --json --limit 0`
  # with NO `-l` flag; artifact probe = `list -l source-bead:<id> --json`;
  # per-bead alert = `comment <id> --stdin`.
  cat > "$BD_BIN" <<'BDSTUB'
#!/usr/bin/env bash
store="$2"; verb="$3"; shift 3 2>/dev/null || true
storename="$(basename "$store")"
case "$verb" in
  list)
    args="$*"
    if [[ "$args" == *"-l source-bead:"* ]]; then
      id="$(printf '%s' "$args" | grep -oE 'source-bead:[A-Za-z0-9_.-]+' | head -1 | cut -d: -f2)"
      f="$GOLW_TEST_FIXTURES_DIR/artifacts-${id}.json"
      [ -f "$f" ] && cat "$f" || echo "[]"
    else
      f="$GOLW_TEST_FIXTURES_DIR/candidates-${storename}.json"
      [ -f "$f" ] && cat "$f" || echo "[]"
    fi
    ;;
  comment)
    bid="$1"
    echo "comment:${storename}:${bid}" >> "${GOLW_TEST_COMMENTS_LOG:-/dev/null}"
    ;;
  *) echo "[]" ;;
esac
BDSTUB
  chmod +x "$BD_BIN"
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$GOLW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$NOTIFY_BIN"
  printf '#!/usr/bin/env bash\n[ "$1" = "mail" ] && echo "mail:$*" >> "$GOLW_TEST_MAILED" 2>/dev/null; exit 0\n' > "$GC_BIN"
  chmod +x "$NOTIFY_BIN" "$GC_BIN"

  export GOLW_TEST_FIXTURES_DIR="$TMP/fixtures"

  # ── fixture builders ──────────────────────────────────────────────────────
  # Real shapes verified live against ga-d3eg2's own measured beads (2026-08-03):
  # a stale bead with fix-attempt:N and NO artifact at all (ga-hn3kh shape), and
  # a stale bead with a PARKED (needs-rebase) artifact (wa-vcd01 shape) both
  # correctly flag; an ACTIVE marker (gate-status:dispatching, live wa-vlhki
  # shape) correctly suppresses.
  OLD_TS="$(date -u -v-10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  FRESH_TS="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

  mk_candidate() {  # id store labels_csv updated_at
    local id="$1" labels="$3" upd="$4"
    local labels_json; labels_json="$(printf '%s' "$labels" | tr ',' '\n' | jq -R . | jq -s -c .)"
    printf '{"id":"%s","status":"open","updated_at":"%s","labels":%s}' "$id" "$upd" "$labels_json"
  }

  # ── Scenario 1: no artifact at all + stale → FLAG (ga-hn3kh shape) ────────
  echo "Scenario 1: stale bead, zero gate artifacts ever → flagged"
  printf '[%s]' "$(mk_candidate cand-a "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-a.json"
  NOTIF1="$TMP/notif1"; MAIL1="$TMP/mail1"; COMM1="$TMP/comm1"
  : > "$NOTIF1"; : > "$MAIL1"; : > "$COMM1"
  GOLW_TEST_NOTIFIED="$NOTIF1" GOLW_TEST_MAILED="$MAIL1" GOLW_TEST_COMMENTS_LOG="$COMM1" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 1: flagged (return 1)" || bad "scenario 1: should return 1 (flagged), got $rc"
  grep -q "comment:.*:cand-a" "$COMM1" 2>/dev/null && ok "scenario 1: bd comment posted on cand-a" || bad "scenario 1: no comment posted"
  grep -q "notify:" "$NOTIF1" 2>/dev/null && ok "scenario 1: notify fired" || bad "scenario 1: notify did NOT fire"
  grep -q "mail:" "$MAIL1" 2>/dev/null && ok "scenario 1: mayor mailed" || bad "scenario 1: mayor NOT mailed"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 2: PARKED artifact (needs-rebase) + stale → still FLAG (wa-vcd01 shape) ──
  echo "Scenario 2: stale bead with a parked (needs-rebase) artifact → still flagged"
  printf '[%s]' "$(mk_candidate cand-b "$TMP/wa" "gate:needs-fix,gate:needs-rebase,gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  printf '[{"id":"art-b","status":"open","labels":["type:quality-gate-marker","gate-status:needs-rebase","source-bead:cand-b"]}]' > "$TMP/fixtures/artifacts-cand-b.json"
  NOTIF2="$TMP/notif2"; MAIL2="$TMP/mail2"; COMM2="$TMP/comm2"
  : > "$NOTIF2"; : > "$MAIL2"; : > "$COMM2"
  GOLW_TEST_NOTIFIED="$NOTIF2" GOLW_TEST_MAILED="$MAIL2" GOLW_TEST_COMMENTS_LOG="$COMM2" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 2: parked artifact still flagged (return 1)" || bad "scenario 2: should still flag a parked-only artifact, got $rc"
  grep -q "cand-b" "$COMM2" 2>/dev/null && ok "scenario 2: comment posted on cand-b" || bad "scenario 2: no comment on cand-b"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 3: ACTIVE artifact (dispatching) → NOT flagged (wa-vlhki shape) ──
  echo "Scenario 3: bead with an ACTIVE (dispatching) artifact → NOT flagged"
  printf '[%s]' "$(mk_candidate cand-c "$TMP/hq" "gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  printf '[{"id":"art-c","status":"open","labels":["type:quality-gate-marker","gate-status:dispatching","source-bead:cand-c"]}]' > "$TMP/fixtures/artifacts-cand-c.json"
  NOTIF3="$TMP/notif3"; MAIL3="$TMP/mail3"; COMM3="$TMP/comm3"
  : > "$NOTIF3"; : > "$MAIL3"; : > "$COMM3"
  GOLW_TEST_NOTIFIED="$NOTIF3" GOLW_TEST_MAILED="$MAIL3" GOLW_TEST_COMMENTS_LOG="$COMM3" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 3: active artifact suppresses (return 0)" || bad "scenario 3: active artifact should suppress, got $rc"
  [ ! -s "$NOTIF3" ] && ok "scenario 3: no notify when artifact is active" || bad "scenario 3: notify fired despite active artifact (false positive)"
  [ ! -s "$COMM3" ] && ok "scenario 3: no comment when artifact is active" || bad "scenario 3: comment posted despite active artifact"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 4: too FRESH → NOT flagged (age-gate) ────────────────────────
  echo "Scenario 4: bead orphaned but only 5min old → NOT flagged (below threshold)"
  printf '[%s]' "$(mk_candidate cand-d "$TMP/hq" "gate:queued" "$FRESH_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-d.json"
  NOTIF4="$TMP/notif4"; : > "$NOTIF4"
  GOLW_TEST_NOTIFIED="$NOTIF4" GOLW_TEST_MAILED="$TMP/mail4" GOLW_TEST_COMMENTS_LOG="$TMP/comm4" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 4: fresh orphan not flagged yet (return 0)" || bad "scenario 4: should NOT flag a 5min-old candidate (threshold 180min), got $rc"
  [ ! -s "$NOTIF4" ] && ok "scenario 4: no notify for a fresh candidate" || bad "scenario 4: notify fired for a fresh candidate (false positive)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5: no gate:* label at all → never a candidate ────────────────
  echo "Scenario 5: bead has other labels but no gate:* label → never a candidate"
  printf '[%s]' "$(mk_candidate cand-e "$TMP/hq" "ctx:ready,exec:auto" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  NOTIF5="$TMP/notif5"; : > "$NOTIF5"
  GOLW_TEST_NOTIFIED="$NOTIF5" GOLW_TEST_MAILED="$TMP/mail5" GOLW_TEST_COMMENTS_LOG="$TMP/comm5" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5: no gate:* label → not flagged (return 0)" || bad "scenario 5: bead with no gate:* label should never be a candidate, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5b (live-verified 2026-08-03, ga-wisp-fpyxxhp): a MARKER bead
  # carrying its own literal gate:* labels must never be misread as a stranded
  # TARGET bead — "different namespace" alone does not separate them; the
  # type:quality-gate-marker/-run label must be excluded explicitly. ─────────
  echo "Scenario 5b: a gate-marker bead with its own gate:* labels is excluded, not misflagged as a target"
  printf '[%s]' "$(mk_candidate cand-marker "$TMP/hq" "gate:exiled-tier5:2,gate:rebase-fail-count:2,type:quality-gate-marker,gate-status:needs-rebase,source-bead:cand-other" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  NOTIF5B="$TMP/notif5b"; : > "$NOTIF5B"
  GOLW_TEST_NOTIFIED="$NOTIF5B" GOLW_TEST_MAILED="$TMP/mail5b" GOLW_TEST_COMMENTS_LOG="$TMP/comm5b" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5b: marker bead with own gate:* labels excluded (return 0)" || bad "scenario 5b (ga-wisp-fpyxxhp regression): a type:quality-gate-marker bead was misflagged as a stranded target, got $rc"
  [ ! -s "$NOTIF5B" ] && ok "scenario 5b: no notify for a marker bead" || bad "scenario 5b: notify fired for a marker bead (false positive)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5c (live-verified 2026-08-03, wa-5u2cv/wa-kty2h class): a bead
  # whose ONLY gate:* label is gate:prod-deploy:* (a hand-applied "shipped,
  # needs Athos's manual prod test" marker stamped AFTER the code-review gate
  # already passed — never backed by a quality-gate-marker) must NOT be
  # flagged as orphaned. ──────────────────────────────────────────────────────
  echo "Scenario 5c: bead with ONLY a gate:prod-deploy:* label is excluded (not a code-review-gate orphan)"
  printf '[%s]' "$(mk_candidate cand-prod "$TMP/hq" "gate:prod-deploy:needs-athos-test,blocked-on:cand-other" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  NOTIF5C="$TMP/notif5c"; : > "$NOTIF5C"
  GOLW_TEST_NOTIFIED="$NOTIF5C" GOLW_TEST_MAILED="$TMP/mail5c" GOLW_TEST_COMMENTS_LOG="$TMP/comm5c" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5c: prod-deploy-only bead excluded (return 0)" || bad "scenario 5c (wa-5u2cv/wa-kty2h regression): a gate:prod-deploy:*-only bead was misflagged as a code-review-gate orphan, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5d: a bead MIXING gate:prod-deploy:* with a REAL pipeline label
  # (gate:queued) must still be evaluated — the exclusion is per-bead only when
  # ALL its gate:* labels fall in the excluded family, not on partial match. ──
  echo "Scenario 5d: bead mixing gate:prod-deploy:* with a real pipeline label (gate:queued) is still evaluated"
  printf '[%s]' "$(mk_candidate cand-mixed "$TMP/hq" "gate:prod-deploy:needs-athos-test,gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mixed.json"
  NOTIF5D="$TMP/notif5d"; : > "$NOTIF5D"
  GOLW_TEST_NOTIFIED="$NOTIF5D" GOLW_TEST_MAILED="$TMP/mail5d" GOLW_TEST_COMMENTS_LOG="$TMP/comm5d" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 5d: mixed-label bead with a real pipeline label still flagged (return 1)" || bad "scenario 5d: a bead with gate:queued alongside gate:prod-deploy:* should still be evaluated on its own merits, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 6: COOLDOWN — same bead flagged twice, 2nd run within cooldown suppresses re-alert ──
  echo "Scenario 6: cooldown suppresses re-alert on the SAME still-orphaned bead"
  printf '[%s]' "$(mk_candidate cand-f "$TMP/hq" "gate:fix-attempt:2" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-f.json"
  NOTIF6A="$TMP/notif6a"; : > "$NOTIF6A"
  GOLW_TEST_NOTIFIED="$NOTIF6A" GOLW_TEST_MAILED="$TMP/mail6a" GOLW_TEST_COMMENTS_LOG="$TMP/comm6a" run_sweep
  rc1=$?
  NOTIF6B="$TMP/notif6b"; : > "$NOTIF6B"
  GOLW_TEST_NOTIFIED="$NOTIF6B" GOLW_TEST_MAILED="$TMP/mail6b" GOLW_TEST_COMMENTS_LOG="$TMP/comm6b" run_sweep
  rc2=$?
  [ "$rc1" -eq 1 ] && ok "scenario 6: 1st sweep flags (return 1)" || bad "scenario 6: 1st sweep should flag, got $rc1"
  [ -s "$NOTIF6A" ] && ok "scenario 6: 1st sweep notified" || bad "scenario 6: 1st sweep should notify"
  [ "$rc2" -eq 1 ] && ok "scenario 6: 2nd sweep still returns 1 (still orphaned)" || bad "scenario 6: 2nd sweep should still report flagged state, got $rc2"
  [ ! -s "$NOTIF6B" ] && ok "scenario 6: 2nd sweep within cooldown does NOT re-notify" || bad "scenario 6: cooldown did not suppress duplicate notify"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 7: RESOLVED — bead no longer a candidate → state cleared, no re-alert ──
  echo "Scenario 7: previously-flagged bead resolves (no longer orphaned) → state clears"
  printf '[%s]' "$(mk_candidate cand-g "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-g.json"
  GOLW_TEST_NOTIFIED="$TMP/notif7a" GOLW_TEST_MAILED="$TMP/mail7a" GOLW_TEST_COMMENTS_LOG="$TMP/comm7a" run_sweep >/dev/null
  [ -s "$STATE_FILE" ] && ok "scenario 7: state file written after 1st flag" || bad "scenario 7: state file missing after 1st flag"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"   # bead resolved (e.g. merged+closed, or gate picked it up)
  run_sweep >/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 7: resolved sweep returns 0" || bad "scenario 7: resolved sweep should return 0, got $rc"
  grep -q "cand-g" "$STATE_FILE" 2>/dev/null && bad "scenario 7: resolved bead still lingers in state" || ok "scenario 7: resolved bead pruned from state"

  # ── Scenario 8: DRY-RUN — flags but no side effects, no state write ───────
  echo "Scenario 8: GOLW_DRY_RUN=1 → detects but no comment/notify/mail/state"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate cand-h "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-h.json"
  NOTIF8="$TMP/notif8"; COMM8="$TMP/comm8"; : > "$NOTIF8"; : > "$COMM8"
  GOLW_DRY_RUN=1
  GOLW_TEST_NOTIFIED="$NOTIF8" GOLW_TEST_MAILED="$TMP/mail8" GOLW_TEST_COMMENTS_LOG="$COMM8" run_sweep
  rc=$?
  GOLW_DRY_RUN=0
  [ "$rc" -eq 1 ] && ok "scenario 8: DRY_RUN still reports flagged (return 1)" || bad "scenario 8: DRY_RUN should still return 1, got $rc"
  [ ! -s "$NOTIF8" ] && ok "scenario 8: no notify in DRY_RUN" || bad "scenario 8: notify fired in DRY_RUN"
  [ ! -s "$COMM8" ] && ok "scenario 8: no comment in DRY_RUN" || bad "scenario 8: comment posted in DRY_RUN"
  [ ! -f "$STATE_FILE" ] && ok "scenario 8: no state written in DRY_RUN" || bad "scenario 8: state written despite DRY_RUN"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 9: KILL-SWITCH ────────────────────────────────────────────────
  echo "Scenario 9: GOLW_ENABLED=0 → no-op"
  GOLW_ENABLED=0
  NOTIF9="$TMP/notif9"; : > "$NOTIF9"
  GOLW_TEST_NOTIFIED="$NOTIF9" GOLW_TEST_MAILED="$TMP/mail9" GOLW_TEST_COMMENTS_LOG="$TMP/comm9" run_sweep
  rc=$?
  GOLW_ENABLED=1
  [ "$rc" -eq 0 ] && ok "scenario 9: disabled returns 0" || bad "scenario 9: disabled should return 0, got $rc"
  [ ! -s "$NOTIF9" ] && ok "scenario 9: no notify when disabled" || bad "scenario 9: notify fired despite disabled"

  # ── Scenario 10: bd/jq read failure on one store → fail-open, other store still swept ──
  echo "Scenario 10 (ga-p5q3): unreadable store → fail-open (skip it), does not crash or false-flag"
  rm -f "$TMP/fixtures/candidates-hq.json"   # missing fixture → stub prints "[]" (simulates empty/failed read, not a crash)
  printf '[%s]' "$(mk_candidate cand-i "$TMP/wa" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-i.json"
  NOTIF10="$TMP/notif10"; : > "$NOTIF10"
  GOLW_TEST_NOTIFIED="$NOTIF10" GOLW_TEST_MAILED="$TMP/mail10" GOLW_TEST_COMMENTS_LOG="$TMP/comm10" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 10: other store's candidate still flagged despite one empty store" || bad "scenario 10: should still flag cand-i from the wa store, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 11: bash -n syntax check ──────────────────────────────────────
  echo "Scenario 11: bash -n syntax check"
  bash -n "$0" 2>/dev/null && ok "scenario 11: bash -n passes" || bad "scenario 11: bash -n FAILED — syntax error"

  echo ""
  echo "gate-orphaned-label-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep; exit 0  # daemon health = "ran OK"; findings (if any) already sent via comment+notify+mail
