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
#      error/passed/failed/superseded/deferred, OR a closed artifact) → a
#      CANDIDATE for flagging.
#   4. Split candidates into orphan-suspect vs. parado-de-proposito (ga-cjk1j):
#      a bead carrying gate:needs-human* / blocked-by:* / status=blocked is a
#      human's self-declared park — it's counted (see the "PARK:" log line and
#      the mail summary) but never enters the age-based alert/cooldown/comment
#      pipeline below. Everything else is an orphan-suspect and flows through
#      step 5 exactly as before this split.
#   5. Report only — this daemon NEVER mutates a bead (no label/status/assignee/
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
# hand."
#
# PARK-VS-ORPHAN SPLIT (ga-cjk1j, fixing a ga-l8yh6 blind spot): the first
# release of this watchdog surfaced every gate:*-labeled bead with no active
# marker alike, whether silently stranded or deliberately parked by a human
# (gate:needs-human*, blocked-by:*, status=blocked). Measured 2026-08-05: 11 of
# 20 (55%) flagged beads were self-declared, intentional parks — a channel
# that re-alerts on the same 11 every cooldown cycle trains readers to ignore
# the whole report, and that's how the 9 real orphan-suspects hid in the
# noise. A park bead is now excluded from the age-based alert/cooldown/comment
# pipeline entirely and only contributes to a count (see the "PARK:" log line
# and the mail summary) — it is still logged every sweep, but it no longer
# competes for attention with a bead nobody decided to leave alone.
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
# Prints "<active:0|1|error>\t<last_artifact_gate_status_or_none|unknown>\t<open_artifact_count>"
# The active bit replicates pilot-dispatcher.sh's _beadid_has_active_gate_artifact
# (ga-wisp signal (d), ~line 3212) EXACTLY — same active-state set, same query
# shape (bd list -l "source-bead:<id>" against the HQ store; empirically
# verified 2026-08-03 that this label-scoped query surfaces
# type:quality-gate-marker/-run beads without needing --all/--include-gates).
# The other two fields are reporting-only extras computed from the same read.
# FAIL-OPEN: a non-zero exit from the bd|jq pipe (pipefail-visible via $?) prints
# "error\tunknown\t0" instead of the confirmed-zero "0\tnone\t0" — a failed read
# must never be indistinguishable from a genuinely-empty result (gate-feedback
# 2026-08-03: the caller posts a durable comment asserting "0 = none ever
# found", which is false when the true state is "the query failed").
# Test seam: routes through $BD_BIN, stubbed in --selftest.
_gate_artifact_probe() {
  local _bid="$1" _arts _out _rc
  _arts=$("$BD_BIN" -C "$HQ" list -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    log "WARN: gate-artifact probe failed for bead '$_bid' (bd/jq exit $_rc) — fail-open, not treating as confirmed-zero"
    printf 'error\tunknown\t0\n'
    return 1
  fi
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
    # is_park (ga-cjk1j): computed per-label via jq's own startswith() (exact
    # prefix semantics on each label individually) rather than a substring
    # match on the joined-labels string later in bash — a joined string like
    # "gate:needs-human,gate:queued" makes "contains gate:needs-human" easy to
    # get right, but a naive bash substring check is the wrong tool once any
    # label could plausibly share a prefix (e.g. a hypothetical
    # "gate:needs-humanoid"); doing it once here on the real label array is
    # unambiguous. status=blocked is the other park signal (ga-cjk1j AC3): 4 of
    # the 11 known intentional parks carry status=blocked with NO
    # gate:needs-human label at all — a labels-only check would miss them.
    ids_labels=$(printf '%s' "$aged_json" | jq -r '
        .[] | . as $b
        | ($b.labels // []) as $L
        | [ $b.id,
            ([$L[] | select(startswith("gate:"))] | join(",")),
            ($b.updated_at // $b.created_at // ""),
            ( if ( ($L | any(startswith("gate:needs-human")))
                   or ($L | any(startswith("blocked-by:")))
                   or (($b.status // "") == "blocked") )
              then "1" else "0" end )
          ] | @tsv
      ' 2>/dev/null)
    [ -z "${ids_labels:-}" ] && continue

    local bid blabels bts is_park age_min probe active lstatus lcount
    while IFS=$'\t' read -r bid blabels bts is_park; do
      [ -z "${bid:-}" ] && continue
      probe="$(_gate_artifact_probe "$bid")"
      active="$(printf '%s' "$probe" | cut -f1)"
      lstatus="$(printf '%s' "$probe" | cut -f2)"
      lcount="$(printf '%s' "$probe" | cut -f3)"
      case "$active" in
        1) continue ;;      # has an ACTIVE marker/run right now — not orphaned, skip
        error) continue ;;  # probe read failed (WARN already logged by _gate_artifact_probe) — fail-open, don't flag on unknown state
      esac
      local bepoch
      bepoch="$(printf '%s' "$bts" | jq -Rr 'fromdateiso8601? // empty' 2>/dev/null)"
      if [ -n "${bepoch:-}" ]; then
        age_min=$(( (now - bepoch) / 60 ))
      else
        age_min="?"
      fi
      flagged_tsv="${flagged_tsv}${bid}\t${store}\t${age_min}\t${blabels}\t${lstatus}\t${lcount}\t${is_park}\n"
    done <<< "$ids_labels"
  done

  # ── ga-cjk1j: split flagged candidates into orphan-suspect (drives the
  # age-based alert below, unchanged) vs. parado-de-proposito (counted only).
  # Splitting here, before ANY state/cooldown/comment/notify/mail logic runs,
  # means every downstream stage operates on orphan_tsv exactly as it did
  # before this fix — an un-parked bead's behavior is byte-for-byte identical
  # (AC2 control: a real orphan must keep alerting exactly as today). ────────
  local orphan_tsv="" park_tsv="" park_count=0
  local bid store2 age_min labels lstatus lcount is_park
  while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount is_park; do
    [ -z "${bid:-}" ] && continue
    if [ "$is_park" = "1" ]; then
      park_tsv="${park_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
      park_count=$((park_count + 1))
    else
      orphan_tsv="${orphan_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
    fi
  done < <(printf '%b' "$flagged_tsv")
  flagged_tsv="$orphan_tsv"

  if [ "$park_count" -gt 0 ]; then
    log "PARK: ${park_count} bead(s) parado(s) de proposito (gate:needs-human*/blocked-by:*/status=blocked) — nao contam para o alerta de orfao"
    printf '%b' "$park_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
      [ -z "${bid:-}" ] && continue
      log "  - PARK $bid ($(_store_name "$store2")) age=${age_min}min labels=[${labels}]"
    done
  fi

  if [ -z "${flagged_tsv:-}" ]; then
    # Nothing currently orphaned — clear any stale state so a future episode
    # starts fresh (mirrors GTSW's cooldown-reset-on-clear convention).
    if [ -f "$STATE_FILE" ] && [ "${GOLW_DRY_RUN:-0}" != "1" ]; then
      rm -f "$STATE_FILE" 2>/dev/null || true
      log "STATE CLEARED: no orphaned gate-labeled beads found — previous episode(s) resolved"
    fi
    local park_suffix=""
    [ "$park_count" -gt 0 ] && park_suffix=" (${park_count} parked, excluded)"
    log "OK: 0 beads with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min) across ${GOLW_STORES}${park_suffix}"
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

  # ga-lnpa7: cooldown is correctly per-bead, but the mail used to report the
  # FULL flagged_tsv every time ANY bead was due — one new bead re-spammed
  # every already-alerted bead still in cooldown. Compute the delta up front
  # so both the "nothing changed" gate and the mail body key off it.
  local new_count; new_count="$(printf '%b' "$to_alert_tsv" | grep -c . || true)"
  local resolved_count; resolved_count="$(printf '%s\n' "${resolved_ids:-}" | grep -c . || true)"

  local total_flagged; total_flagged="$(printf '%b' "$flagged_tsv" | grep -c . || true)"
  log "FLAGGED: ${total_flagged} bead(s) with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min)"
  printf '%b' "$flagged_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    log "  - $bid ($(_store_name "$store2")) age=${age_min}min labels=[${labels}] last_artifact=${lstatus} (${lcount} open)"
  done

  if [ "${new_count:-0}" -eq 0 ] && [ "${resolved_count:-0}" -eq 0 ]; then
    local park_suffix2=""
    [ "$park_count" -gt 0 ] && park_suffix2=" (+${park_count} parked, excluded)"
    log "OK: all ${total_flagged} flagged bead(s) already alerted within cooldown (${GOLW_ALERT_COOLDOWN_S}s) — no new notification${park_suffix2}"
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
    msg="gate-orphaned-label-watchdog (ga-l8yh6): this bead carries gate:* label(s) [${labels}] with no ACTIVE quality-gate-marker/-run for >= ${GOLW_STALE_MINUTES}min (age: ${age_min}min). Last known gate artifact: ${lstatus} (${lcount} open artifact(s) referencing this bead; 0 = none ever found in the HQ store). Detection-only report — no label/status/assignee was touched. Common causes seen historically (ga-d3eg2): stale label after a manual fix, branch conflicts needing re-anchor, or already-merged-but-never-closed (an intentional park via gate:needs-human*/blocked-by:*/status=blocked is excluded from this alert entirely — see ga-cjk1j) — a human/Mayor should triage."
    if [ -n "${GOLW_TEST_COMMENTS_LOG:-}" ]; then
      echo "comment:${store2}:${bid}:${msg}" >> "$GOLW_TEST_COMMENTS_LOG" 2>/dev/null || true
    else
      printf '%s' "$msg" | "$BD_BIN" -C "$store2" comment "$bid" --stdin 2>/dev/null || log "WARN: bd comment failed for $bid"
    fi
  done < <(printf '%b' "$to_alert_tsv")

  # ── aggregate notify + mail — DELTA report (ga-lnpa7): new/due + resolved +
  # a count of what's unchanged, not the full flagged set every cycle. ───────
  local unchanged_count=$(( total_flagged - new_count ))
  local summary="GATE ORPHANED LABEL: ${new_count} new/due, ${resolved_count} resolved, ${unchanged_count} unchanged-already-reported — ${total_flagged} total currently flagged (>=${GOLW_STALE_MINUTES}min)."
  if [ "$park_count" -gt 0 ]; then
    summary="${summary} +${park_count} parado(s) por decisao humana (gate:needs-human*/blocked-by:*/status=blocked) — nao contam para o alerta acima."
  fi

  if [ -n "${GOLW_TEST_NOTIFIED:-}" ]; then
    echo "notify:$summary" >> "$GOLW_TEST_NOTIFIED" 2>/dev/null || true
  else
    command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
      "${NOTIFY_BIN}" -t "Gate: orphaned label(s)" -p "${GOLW_NOTIFY_PRIORITY}" "$summary" 2>/dev/null || true
  fi

  local mail_body="GATE ORPHANED-LABEL WATCHDOG — detection-only report (ga-l8yh6, follow-up of ga-d3eg2 AC4).
"
  mail_body="${mail_body}
${summary}
"

  if [ "${new_count:-0}" -gt 0 ]; then
    local new_lines; new_lines="$(printf '%b' "$to_alert_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
      [ -z "${bid:-}" ] && continue
      echo "  ${bid}  (${store2})  age=${age_min}min  labels=[${labels}]  last_artifact=${lstatus} (${lcount} open)"
    done)"
    mail_body="${mail_body}
NEW/DUE (${new_count}) — why this cycle alerted:
${new_lines}
"
  fi

  if [ "${resolved_count:-0}" -gt 0 ]; then
    local resolved_lines; resolved_lines="$(printf '%s\n' "$resolved_ids" | while IFS= read -r rid; do
      [ -z "${rid:-}" ] && continue
      echo "  ${rid}  (no longer carries an orphaned gate:* label)"
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
This is SURFACE-ONLY — no label/status/assignee was touched on any bead. Common
root causes seen historically (ga-d3eg2's own measurement): a stale label left
after a manual fix, a branch that conflicts with main and needs re-anchor, or
work already merged but the bead never closed. Beads carrying an intentional
park signal (gate:needs-human*, blocked-by:*, status=blocked) are excluded from
this list entirely (ga-cjk1j) — see the parked-count line above.

Per-bead detail for NEW/DUE beads is also posted as a comment on each bead.
Re-alerts for an already-flagged bead are suppressed for ${GOLW_ALERT_COOLDOWN_S}s
(state: ${STATE_FILE}). Full current list always in the log: ${LOG}"

  if [ -n "${GOLW_TEST_MAILED:-}" ]; then
    { echo "mail:gate-orphaned-label:$summary"; printf '%s\n' "$mail_body"; } >> "$GOLW_TEST_MAILED" 2>/dev/null || true
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
    else
      f="$GOLW_TEST_FIXTURES_DIR/candidates-${storename}.json"
    fi
    # __BD_FAIL__ sentinel fixture simulates a genuine bd command failure
    # (non-zero exit, no valid stdout) — distinct from a missing fixture,
    # which simulates a real, successful, empty result ("[]").
    if [ -f "$f" ] && grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
      echo "simulated bd failure: connection refused" >&2
      exit 1
    fi
    [ -f "$f" ] && cat "$f" || echo "[]"
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

  # ── Scenario 10: bd/jq read failure on one store's candidate listing → fail-open (skip that store), other store still swept ──
  echo "Scenario 10 (ga-p5q3): unreadable store (bd exits non-zero) → fail-open (skip it), does not crash or false-flag"
  printf '%s\n' "__BD_FAIL__" > "$TMP/fixtures/candidates-hq.json"   # genuine bd failure (non-zero exit), not just an empty result
  printf '[%s]' "$(mk_candidate cand-i "$TMP/wa" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-i.json"
  NOTIF10="$TMP/notif10"; : > "$NOTIF10"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF10" GOLW_TEST_MAILED="$TMP/mail10" GOLW_TEST_COMMENTS_LOG="$TMP/comm10" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 10: other store's candidate still flagged despite one unreadable store" || bad "scenario 10: should still flag cand-i from the wa store, got $rc"
  grep -q "WARN: could not read store" "$LOG" 2>/dev/null && ok "scenario 10: WARN logged for the unreadable store" || bad "scenario 10: no WARN logged for the unreadable hq store"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 10b (blocking issue 1, gate-feedback 2026-08-03): a bd/jq FAILURE
  # on the per-bead ARTIFACT PROBE (not the store-level candidate listing) must
  # NOT be treated as "confirmed zero artifacts" — regression test for the exact
  # defect the reviewer found, which Scenario 10 (store-level only) never
  # exercised. ──────────────────────────────────────────────────────────────────
  echo "Scenario 10b (blocking issue 1): artifact-probe bd failure on a stale candidate → fail-open, NOT flagged as orphaned"
  printf '[%s]' "$(mk_candidate cand-j "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  printf '%s\n' "__BD_FAIL__" > "$TMP/fixtures/artifacts-cand-j.json"   # the artifact-probe bd call itself fails
  NOTIF10B="$TMP/notif10b"; MAIL10B="$TMP/mail10b"; COMM10B="$TMP/comm10b"
  : > "$NOTIF10B"; : > "$MAIL10B"; : > "$COMM10B"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF10B" GOLW_TEST_MAILED="$MAIL10B" GOLW_TEST_COMMENTS_LOG="$COMM10B" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 10b: probe failure → candidate not flagged (return 0)" || bad "scenario 10b (blocking issue 1 regression): a bd/jq failure on the artifact probe must fail-open, not flag as orphaned — got $rc"
  [ ! -s "$COMM10B" ] && ok "scenario 10b: no comment posted despite probe failure" || bad "scenario 10b: comment posted on a bead whose artifact probe failed to read (false 'confirmed zero' claim)"
  [ ! -s "$NOTIF10B" ] && ok "scenario 10b: no notify despite probe failure" || bad "scenario 10b: notify fired despite probe failure"
  grep -q "WARN.*cand-j" "$LOG" 2>/dev/null && ok "scenario 10b: WARN logged naming the failed candidate" || bad "scenario 10b: no WARN logged for the failed artifact probe"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 12 (ga-lnpa7 AC1): already-alerted beads + 1 new → mail
  # highlights the NEW bead, summarizes the rest as a COUNT, does not re-list
  # their per-bead detail. Also locks AC5: the LOG still gets the full set. ──
  echo "Scenario 12 (ga-lnpa7 AC1): already-alerted beads + 1 new → mail highlights NEW, counts the rest"
  printf '[%s,%s]' "$(mk_candidate cand-k1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" "$(mk_candidate cand-k2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-k1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-k2.json"
  GOLW_TEST_NOTIFIED="$TMP/notif12a" GOLW_TEST_MAILED="$TMP/mail12a" GOLW_TEST_COMMENTS_LOG="$TMP/comm12a" run_sweep >/dev/null
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-k1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-k2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-k3 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-k3.json"
  MAIL12B="$TMP/mail12b"; : > "$MAIL12B"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif12b" GOLW_TEST_MAILED="$MAIL12B" GOLW_TEST_COMMENTS_LOG="$TMP/comm12b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 12: 2nd sweep still flags (return 1)" || bad "scenario 12: 2nd sweep should flag, got $rc"
  grep -q "cand-k3" "$MAIL12B" 2>/dev/null && ok "scenario 12: mail highlights the NEW bead (cand-k3)" || bad "scenario 12: mail does not mention the new bead cand-k3"
  grep -q "cand-k1" "$MAIL12B" 2>/dev/null && bad "scenario 12 (ga-lnpa7 regression): mail re-lists an already-reported bead (cand-k1) individually" || ok "scenario 12: already-reported cand-k1 not individually re-listed"
  grep -q "cand-k2" "$MAIL12B" 2>/dev/null && bad "scenario 12 (ga-lnpa7 regression): mail re-lists an already-reported bead (cand-k2) individually" || ok "scenario 12: already-reported cand-k2 not individually re-listed"
  grep -q "+2 already reported" "$MAIL12B" 2>/dev/null && ok "scenario 12: mail includes a count-only summary for the 2 already-reported beads" || bad "scenario 12: mail missing count-only summary for already-reported beads"
  grep -q "cand-k1" "$LOG" 2>/dev/null && grep -q "cand-k2" "$LOG" 2>/dev/null && grep -q "cand-k3" "$LOG" 2>/dev/null \
    && ok "scenario 12: log still records the FULL flagged list (k1,k2,k3) even though mail summarizes k1/k2" \
    || bad "scenario 12 (ga-lnpa7 AC5 regression): log is missing one or more flagged beads"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 13 (ga-lnpa7 AC2): nothing changed since the last alert (no
  # new/due bead, none resolved) → ZERO mail (not just zero notify). ─────────
  echo "Scenario 13 (ga-lnpa7 AC2): nothing changed since last alert → zero mail"
  printf '[%s]' "$(mk_candidate cand-l "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-l.json"
  GOLW_TEST_NOTIFIED="$TMP/notif13a" GOLW_TEST_MAILED="$TMP/mail13a" GOLW_TEST_COMMENTS_LOG="$TMP/comm13a" run_sweep >/dev/null
  MAIL13B="$TMP/mail13b"; : > "$MAIL13B"
  GOLW_TEST_NOTIFIED="$TMP/notif13b" GOLW_TEST_MAILED="$MAIL13B" GOLW_TEST_COMMENTS_LOG="$TMP/comm13b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 13: 2nd sweep still reports flagged state (return 1)" || bad "scenario 13: 2nd sweep should still return 1 (still orphaned), got $rc"
  [ ! -s "$MAIL13B" ] && ok "scenario 13: no mail sent when nothing changed" || bad "scenario 13 (ga-lnpa7 AC2 regression): mail sent despite nothing changing since last alert"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 14 (ga-lnpa7 AC3): a bead resolves while a SIBLING bead stays
  # flagged (still within its own cooldown, not due) → the resolution alone
  # triggers a mail, and that mail names the resolved bead. ──────────────────
  echo "Scenario 14 (ga-lnpa7 AC3): a resolved bead appears in the next mail even if nothing else is due"
  printf '[%s,%s]' "$(mk_candidate cand-m1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" "$(mk_candidate cand-m2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-m1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-m2.json"
  GOLW_TEST_NOTIFIED="$TMP/notif14a" GOLW_TEST_MAILED="$TMP/mail14a" GOLW_TEST_COMMENTS_LOG="$TMP/comm14a" run_sweep >/dev/null
  printf '[%s]' "$(mk_candidate cand-m2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  MAIL14B="$TMP/mail14b"; : > "$MAIL14B"
  GOLW_TEST_NOTIFIED="$TMP/notif14b" GOLW_TEST_MAILED="$MAIL14B" GOLW_TEST_COMMENTS_LOG="$TMP/comm14b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 14: sweep still returns 1 (cand-m2 still flagged)" || bad "scenario 14: should still return 1, got $rc"
  [ -s "$MAIL14B" ] && ok "scenario 14: a mail fired for the resolution alone (no bead was newly due)" || bad "scenario 14 (ga-lnpa7 AC3 regression): resolved bead did not trigger a mail"
  grep -q "cand-m1" "$MAIL14B" 2>/dev/null && ok "scenario 14: mail names the resolved bead (cand-m1)" || bad "scenario 14 (ga-lnpa7 AC3 regression): mail does not mention the resolved bead cand-m1"
  grep -q "RESOLVED" "$MAIL14B" 2>/dev/null && ok "scenario 14: mail labels it under a RESOLVED section" || bad "scenario 14: mail missing a RESOLVED section header"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 15 (ga-lnpa7 AC4, CONTROL): first-ever sweep (no prior state)
  # → every flagged bead is "new" and gets full per-bead detail in the mail —
  # the fix must not silence or truncate the FIRST report. ───────────────────
  echo "Scenario 15 (ga-lnpa7 AC4 control): first execution (no prior state) → full detail for every bead, nothing suppressed"
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-n1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-n2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-n3 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-n1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-n2.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-n3.json"
  MAIL15="$TMP/mail15"; : > "$MAIL15"
  [ -f "$STATE_FILE" ] && bad "scenario 15: state file should not pre-exist for this control" || ok "scenario 15: no prior state (genuine first run)"
  GOLW_TEST_NOTIFIED="$TMP/notif15" GOLW_TEST_MAILED="$MAIL15" GOLW_TEST_COMMENTS_LOG="$TMP/comm15" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 15: first sweep flags (return 1)" || bad "scenario 15: first sweep should flag, got $rc"
  for id in cand-n1 cand-n2 cand-n3; do
    grep -q "$id" "$MAIL15" 2>/dev/null && ok "scenario 15: first report includes $id" || bad "scenario 15 (ga-lnpa7 AC4 regression): first report is missing $id"
  done
  grep -q "already reported" "$MAIL15" 2>/dev/null && bad "scenario 15: first report should have zero already-reported beads to summarize" || ok "scenario 15: no spurious already-reported summary on a first run"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 16 (ga-cjk1j AC1, FIXTURE): a bead carrying gate:queued +
  # gate:needs-human, stale (>180min) → must NOT enter NEW/DUE at all; appears
  # at most in the parked count. This is the exact bug measured 2026-08-05:
  # 11 of 20 flagged beads were self-declared parks re-alerted every cycle. ──
  echo "Scenario 16 (ga-cjk1j AC1 fixture): gate:queued+gate:needs-human, stale → NOT flagged as orphan, counted as PARK only"
  printf '[%s]' "$(mk_candidate cand-park1 "$TMP/hq" "gate:queued,gate:needs-human" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-park1.json"
  NOTIF16="$TMP/notif16"; MAIL16="$TMP/mail16"; COMM16="$TMP/comm16"
  : > "$NOTIF16"; : > "$MAIL16"; : > "$COMM16"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF16" GOLW_TEST_MAILED="$MAIL16" GOLW_TEST_COMMENTS_LOG="$COMM16" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 16: park-labeled bead does not enter NEW/DUE (return 0)" || bad "scenario 16 (ga-cjk1j AC1 regression): a gate:needs-human bead was treated as an orphan-suspect, got $rc"
  [ ! -s "$COMM16" ] && ok "scenario 16: no comment posted on the parked bead" || bad "scenario 16: comment posted on a bead carrying gate:needs-human (should be excluded)"
  [ ! -s "$NOTIF16" ] && ok "scenario 16: no notify fired for a park-only sweep" || bad "scenario 16: notify fired despite only a parked bead being present"
  [ ! -s "$MAIL16" ] && ok "scenario 16: no mail fired for a park-only sweep" || bad "scenario 16: mail fired despite only a parked bead being present"
  grep -q "PARK: 1 bead" "$LOG" 2>/dev/null && ok "scenario 16: log records the park count" || bad "scenario 16: log missing the PARK count line"
  grep -q "cand-park1" "$LOG" 2>/dev/null && ok "scenario 16: log names the parked bead" || bad "scenario 16: log does not name the parked bead cand-park1"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 17 (ga-cjk1j AC2, CONTROL — the real alert must not disappear):
  # a bead with gate:queued and NO park signal, stale → CONTINUES alerting
  # exactly as before this fix. If this fails, the fix blinded the watchdog,
  # which is worse than the bug it fixes. ──────────────────────────────────
  echo "Scenario 17 (ga-cjk1j AC2 control): gate:queued with NO park signal, stale → still flags exactly as before this fix"
  printf '[%s]' "$(mk_candidate cand-orphan1 "$TMP/hq" "gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-orphan1.json"
  NOTIF17="$TMP/notif17"; MAIL17="$TMP/mail17"; COMM17="$TMP/comm17"
  : > "$NOTIF17"; : > "$MAIL17"; : > "$COMM17"
  GOLW_TEST_NOTIFIED="$NOTIF17" GOLW_TEST_MAILED="$MAIL17" GOLW_TEST_COMMENTS_LOG="$COMM17" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 17: real orphan (no park signal) still flags (return 1)" || bad "scenario 17 (ga-cjk1j AC2 regression): the fix must not blind the watchdog to a genuine orphan, got $rc"
  grep -q "cand-orphan1" "$COMM17" 2>/dev/null && ok "scenario 17: comment posted on the real orphan" || bad "scenario 17 (ga-cjk1j AC2 regression): no comment on cand-orphan1 — the fix silenced a real alert"
  [ -s "$NOTIF17" ] && ok "scenario 17: notify still fires for a real orphan" || bad "scenario 17: notify did not fire for a real orphan"
  [ -s "$MAIL17" ] && ok "scenario 17: mail still fires for a real orphan" || bad "scenario 17: mail did not fire for a real orphan"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 18 (ga-cjk1j AC3, CONTROL2): status=blocked with NO
  # gate:needs-human/blocked-by label → still counts as park. 4 of the 11
  # known intentional parks in production carry status=blocked with no
  # needs-human label at all — a labels-only check would miss exactly these. ──
  echo "Scenario 18 (ga-cjk1j AC3 control2): status=blocked with NO gate:needs-human/blocked-by label → still counted as park, not orphan"
  printf '[{"id":"cand-park2","status":"blocked","updated_at":"%s","labels":["gate:queued"]}]' "$OLD_TS" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-park2.json"
  NOTIF18="$TMP/notif18"; MAIL18="$TMP/mail18"; COMM18="$TMP/comm18"
  : > "$NOTIF18"; : > "$MAIL18"; : > "$COMM18"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF18" GOLW_TEST_MAILED="$MAIL18" GOLW_TEST_COMMENTS_LOG="$COMM18" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 18: status=blocked alone (no needs-human label) is still treated as park (return 0)" || bad "scenario 18 (ga-cjk1j AC3 regression): a status=blocked bead with no needs-human label was misflagged as orphan, got $rc"
  [ ! -s "$COMM18" ] && ok "scenario 18: no comment posted on the status=blocked bead" || bad "scenario 18: comment posted despite status=blocked"
  grep -q "PARK: 1 bead" "$LOG" 2>/dev/null && ok "scenario 18: log records the park count for the status=blocked bead" || bad "scenario 18: log missing PARK count for a status=blocked-only park signal"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 19 (ga-cjk1j, mixed — mirrors the real production shape): 1
  # real orphan + 2 parked beads (one label-based, one status-based) in the
  # SAME sweep. Verifies the split doesn't cross-contaminate: the orphan must
  # still alert on its own merits, and neither park bead may leak into its
  # comment/mail, while both parks are counted together. ───────────────────
  echo "Scenario 19 (ga-cjk1j mixed): 1 real orphan + 2 parked beads (label-based and status-based) in the same sweep"
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-mix-orphan "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-mix-park1 "$TMP/hq" "gate:fix-attempt:1,gate:needs-human:technical" "$OLD_TS")" \
    "$(printf '{"id":"cand-mix-park2","status":"blocked","updated_at":"%s","labels":["gate:fix-attempt:1"]}' "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix-orphan.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix-park1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix-park2.json"
  NOTIF19="$TMP/notif19"; MAIL19="$TMP/mail19"; COMM19="$TMP/comm19"
  : > "$NOTIF19"; : > "$MAIL19"; : > "$COMM19"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF19" GOLW_TEST_MAILED="$MAIL19" GOLW_TEST_COMMENTS_LOG="$COMM19" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 19: mixed sweep still flags the real orphan (return 1)" || bad "scenario 19: mixed sweep should flag cand-mix-orphan, got $rc"
  grep -q "cand-mix-orphan" "$COMM19" 2>/dev/null && ok "scenario 19: comment posted on the real orphan only" || bad "scenario 19: no comment on cand-mix-orphan"
  grep -q "cand-mix-park1" "$COMM19" 2>/dev/null && bad "scenario 19 (ga-cjk1j regression): comment posted on a gate:needs-human-labeled park bead" || ok "scenario 19: no comment on the label-based park bead"
  grep -q "cand-mix-park2" "$COMM19" 2>/dev/null && bad "scenario 19 (ga-cjk1j regression): comment posted on a status=blocked park bead" || ok "scenario 19: no comment on the status-based park bead"
  grep -q "+2 parado" "$MAIL19" 2>/dev/null && ok "scenario 19: mail summary counts both parked beads" || bad "scenario 19: mail summary missing the '+2 parado(s)' count"
  grep -q "cand-mix-park1" "$MAIL19" 2>/dev/null && bad "scenario 19 (ga-cjk1j regression): mail individually names a parked bead" || ok "scenario 19: mail does not individually name cand-mix-park1"
  grep -q "PARK: 2 bead" "$LOG" 2>/dev/null && ok "scenario 19: log records park_count=2" || bad "scenario 19: log missing PARK count of 2"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 11: bash -n syntax check ──────────────────────────────────────
  echo "Scenario 11: bash -n syntax check"
  bash -n "$0" 2>/dev/null && ok "scenario 11: bash -n passes" || bad "scenario 11: bash -n FAILED — syntax error"

  echo ""
  echo "gate-orphaned-label-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep; exit 0  # daemon health = "ran OK"; findings (if any) already sent via comment+notify+mail
