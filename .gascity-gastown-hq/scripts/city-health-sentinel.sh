#!/usr/bin/env bash
# city-health-sentinel.sh (ga-r5sn8) — judgment+action layer over Gas City's 3
# critical subsystems (gate, pilot, dolt).
#
# WHY: Gas City already has 24 shell watchdogs, but they are isolated and purely
# DETERMINISTIC — no judgment (false-positives like gate-throughput-stall-watchdog's
# historical PARKED-marker miscount, ga-4cb2), no CORRELATION (a disk-pressure event,
# a Dolt CPU burst, and a gate slowdown are usually ONE cascade, not three unrelated
# alerts), and mostly no ACTION (they alert; a human/Mayor kickstarts the stalled
# daemon by hand). This sentinel is the thin layer on top: cheap deterministic
# COLLECTION -> a FAST-PATH that costs zero tokens when everything is green (the
# common case) -> a one-shot HAIKU judgment call only when the state is ambiguous ->
# a deterministic, allowlisted, rate-limited EXECUTE step. It does NOT replace any
# existing watchdog — see "non-duplication" below.
#
# NON-DUPLICATION (why this doesn't overlap the existing watchdogs):
#   - daemon-presence-watchdog.sh checks LIVENESS via each daemon's dedicated
#     heartbeat file/log mtime (e.g. quality-gate-dispatcher.heartbeat, threshold
#     600s; pilot-dispatcher.log mtime, threshold 1500s).
#   - gate-throughput-stall-watchdog.sh checks THROUGHPUT via a loose "Gate PASSED"
#     substring grep over a 165min rolling window, plus its own PARKED-marker
#     exclusion logic (ga-4cb2).
#   - THIS script tracks a third, complementary signal — is the dispatcher/pilot
#     even STARTING new sweeps ("=== Dispatcher sweep start ===" / "=== Pilot sweep
#     start ===", the exact strings both scripts already log at the top of every
#     run: quality-gate-dispatcher.sh, pilot-dispatcher.sh) — and adds the judgment
#     + correlation + action layer none of the above provide. If gate/pilot logic
#     ever needs deeper throughput/liveness changes, that belongs in the existing
#     watchdogs, not here.
#
# ARCHITECTURE (shell does ALL deterministic collection + execution; Haiku does
# ONLY judgment on a JSON snapshot it cannot act on directly):
#   1. COLLECT  — gate_sweep_gap_min, pilot_sweep_gap_min, dolt_responds +
#                 dolt_latency_ms (via the shared gc-dolt-probe.sh module — NEVER
#                 hand-rolled, see imp07), disk_gb, open_markers_count.
#   2. FAST-PATH — if gate_gap<8 && pilot_gap<20 && dolt healthy && dolt_ms<3000 &&
#                 disk>5: log "ok", exit. Zero Haiku tokens. This is the ~95% case.
#   3. AMBIGUOUS — invoke a headless one-shot Haiku (claude -p --model
#                 claude-haiku-4-5 --tools "" --disable-slash-commands
#                 --no-session-persistence --json-schema <schema>) with the
#                 collected state + an embedded PLAYBOOK of known false-positives
#                 and allowed remedies. Haiku gets NO tools and cannot act; it only
#                 returns {"assessment","action","mayor_message"}.
#   4. EXECUTE  — validate `action` against a fixed allowlist (unknown -> "none" +
#                 log, fail-safe). A hard guardrail additionally OVERRIDES any
#                 non-nudge/non-none action whenever Dolt is down, regardless of
#                 what Haiku said (see GUARDRAILS). Rate-limited via state files.
#
# GUARDRAILS (critical — this daemon ACTS on its own):
#   - NEVER restarts/touches Dolt. Dolt unreachable -> ONLY nudge_mayor, enforced
#     in TWO places: the PLAYBOOK told to Haiku, AND a hard shell-side override
#     that fires regardless of what Haiku returns (defense in depth — CLAUDE.md:
#     Dolt is the town's sole data plane and fragile; see gc-dolt-probe.sh header).
#   - Kickstart rate-limit: max 1 per job ("gate" or "pilot") per CHS_KICKSTART_COOLDOWN_S
#     (default 180s / 3min).
#   - Nudge rate-limit: max 1 per topic (dolt|disk|gate|pilot|general, derived
#     deterministically from the collected state, never from Haiku's free text)
#     per CHS_NUDGE_COOLDOWN_S (default 1800s / 30min).
#   - Haiku gets ZERO tools/skills (--tools "" --disable-slash-commands) and its
#     structured JSON is the only channel back to this script; anything outside
#     {kickstart_gate, kickstart_pilot, nudge_mayor, none} is discarded as "none".
#   - Fail-safe on Haiku error/timeout: falls back to a minimal deterministic rule
#     (dolt down -> nudge_mayor; else gate_gap>12 -> kickstart_gate; else none) and
#     logs that Haiku was unavailable. Never hangs — every external call is
#     `timeout`-bounded.
#   - Every decision is logged with timestamp + full collected state + action taken.
#
# CALIBRATION (why these numbers, not guesses):
#   - gate_gap fast-path(8min) / critical(12min): as specified for this sentinel.
#   - pilot_gap fast-path(20min): cross-validated against THREE independent
#     existing signals in this codebase — imparavel-check.py's own
#     PILOT_DEAD_MIN default (20min), daemon-presence-watchdog.sh's pilot-log-mtime
#     threshold (1500s = 25min), and live pilot-dispatcher.log data on 2026-07-20
#     showing routine (non-incident) sweep-to-sweep gaps of 7-22min with rare
#     ~49min excursions during Dolt CPU pressure — all converge on ~20-25min as
#     the "still normal" line.
#   - dolt_ms(3000) / disk_gb(5): as specified for this sentinel.
#
# Kill switch: CHS_DRY_RUN=1 → collect + decide + log exactly as normal, but
# skip the real launchctl kickstart / gc session nudge call (log-only). Useful
# for a manual live-data smoke test before trusting a config change. launchd
# never sets this — it is an operator/manual switch only.
#
# TEST (hermetic — no real Dolt query, no real launchctl/gc/claude call):
#   bash scripts/city-health-sentinel.selftest.sh
# Library mode: `CITY_HEALTH_SENTINEL_LIB=1 source city-health-sentinel.sh` defines
# every function below WITHOUT running main() — the selftest sources this way and
# stubs the COLLECT/HAIKU/EXECUTE functions by name-override (bash lets a later
# function definition replace an earlier one), same pattern as
# dolt-disk-floor-guard.selftest.sh and gate-throughput-stall-watchdog.sh's
# GTSW_TEST_KICKSTARTS/GTSW_TEST_MAILED redirection.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$CITY/.gc/logs"
LOG="${CHS_LOG:-$LOG_DIR/city-health-sentinel.log}"
STATE_DIR="${CHS_STATE_DIR:-$LOG_DIR}"
GC="${GC_BIN:-gc}"
CLAUDE_BIN="${CHS_CLAUDE_BIN:-claude}"
UID_NUM="${CHS_UID_OVERRIDE:-$(id -u)}"

GATE_LOG="${CHS_GATE_LOG:-$CITY/.gc/logs/quality-gate-dispatcher.log}"
PILOT_LOG="${CHS_PILOT_LOG:-$CITY/.gc/logs/pilot-dispatcher.log}"
LOG_TAIL="${CHS_LOG_TAIL:-4000}"   # lines to tail before grep — perf bound (matches GTSW_LOG_TAIL convention)

# ── thresholds (all env-overridable; see CALIBRATION above) ──────────────────
GATE_GAP_FASTPATH_MIN="${CHS_GATE_GAP_FASTPATH_MIN:-8}"
GATE_GAP_CRITICAL_MIN="${CHS_GATE_GAP_CRITICAL_MIN:-12}"
PILOT_GAP_FASTPATH_MIN="${CHS_PILOT_GAP_FASTPATH_MIN:-20}"
DOLT_MS_WARN="${CHS_DOLT_MS_WARN:-3000}"
DISK_GB_WARN="${CHS_DISK_GB_WARN:-5}"

# ── rate limits ────────────────────────────────────────────────────────────
KICKSTART_COOLDOWN_S="${CHS_KICKSTART_COOLDOWN_S:-180}"   # 3min per job
NUDGE_COOLDOWN_S="${CHS_NUDGE_COOLDOWN_S:-1800}"           # 30min per topic

# CHS_DRY_RUN=1 → collect + decide + log exactly as normal, but _do_kickstart /
# _do_nudge become log-only no-ops (no real launchctl/gc call). Rate-limit state
# files are still written on a "would-execute" decision so a dry-run cycle can be
# safely repeated without a following real cycle immediately re-firing on a stale
# window. Operator/manual-verification switch — launchd never sets this.
DRY_RUN="${CHS_DRY_RUN:-0}"

# ── haiku call config ──────────────────────────────────────────────────────
HAIKU_MODEL="${CHS_HAIKU_MODEL:-claude-haiku-4-5}"
HAIKU_TIMEOUT_S="${CHS_HAIKU_TIMEOUT_S:-45}"
HAIKU_JSON_SCHEMA='{"type":"object","properties":{"assessment":{"type":"string"},"action":{"type":"string","enum":["kickstart_gate","kickstart_pilot","nudge_mayor","none"]},"mayor_message":{"type":"string"}},"required":["assessment","action","mayor_message"]}'

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [city-health-sentinel] $*" >> "$LOG" 2>/dev/null || true; }

# optional shared Dolt-health probe (imp07's SHARED, importable module — reuse it
# rather than hand-rolling a bd/dolt timeout check; fail-open if missing, matching
# dolt-disk-floor-guard.sh's own sourcing idiom for the same module)
_PROBE="$CITY/scripts/gc-dolt-probe.sh"
# shellcheck disable=SC1090
[ -f "$_PROBE" ] && . "$_PROBE" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by city-health-sentinel.selftest.sh.
# No side effects; config is read from the vars above so the selftest can override
# them before sourcing.
# ════════════════════════════════════════════════════════════════════════════════

# _is_int <val> → true iff val is a non-empty, non-negative base-10 integer.
# Empty/non-numeric NEVER silently compares as "small" or "zero" (ga-p5q3: error
# and empty must not produce the same value as a real reading).
_is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_lt() { _is_int "$1" && _is_int "$2" && [ "$1" -lt "$2" ]; }
_gt() { _is_int "$1" && _is_int "$2" && [ "$1" -gt "$2" ]; }
_ge() { _is_int "$1" && _is_int "$2" && [ "$1" -ge "$2" ]; }

# _fastpath_ok <gate_gap> <pilot_gap> <dolt_responds:true|false> <dolt_ms> <disk_gb>
# → 0 (true) only when EVERY signal is confirmed green. Any unknown/empty/negative
# reading fails closed (falls through to the Haiku/ambiguous path), never silently
# passes as "fine".
_fastpath_ok() {
  local gate_gap="$1" pilot_gap="$2" dolt_responds="$3" dolt_ms="$4" disk_gb="$5"
  [ "$dolt_responds" = "true" ] || return 1
  _lt "$gate_gap" "$GATE_GAP_FASTPATH_MIN" || return 1
  _lt "$pilot_gap" "$PILOT_GAP_FASTPATH_MIN" || return 1
  _ge "$dolt_ms" 0 && _lt "$dolt_ms" "$DOLT_MS_WARN" || return 1
  _gt "$disk_gb" "$DISK_GB_WARN" || return 1
  return 0
}

# _deterministic_fallback_action <gate_gap> <dolt_responds> → the minimal rule used
# ONLY when the Haiku call itself fails/times out (never when Haiku answers, even
# with an action outside the allowlist — that path is _valid_action, handled
# separately in main). Order matters: Dolt trouble is checked FIRST and always
# wins, matching the guardrail priority (dolt > gate).
_deterministic_fallback_action() {
  local gate_gap="$1" dolt_responds="$2"
  if [ "$dolt_responds" != "true" ]; then
    echo "nudge_mayor"
    return
  fi
  if _gt "$gate_gap" "$GATE_GAP_CRITICAL_MIN"; then
    echo "kickstart_gate"
    return
  fi
  echo "none"
}

# _compute_topic — deterministic nudge rate-limit bucket, derived ONLY from
# collected state (never from Haiku's free-text mayor_message, which could vary
# wording run to run and defeat rate-limiting by never matching a prior topic).
_compute_topic() {
  local gate_gap="$1" pilot_gap="$2" dolt_responds="$3" disk_gb="$4"
  if [ "$dolt_responds" != "true" ]; then echo "dolt"; return; fi
  if _is_int "$disk_gb" && _lt "$disk_gb" "$DISK_GB_WARN"; then echo "disk"; return; fi
  if _is_int "$gate_gap" && _ge "$gate_gap" "$GATE_GAP_FASTPATH_MIN"; then echo "gate"; return; fi
  if _is_int "$pilot_gap" && _ge "$pilot_gap" "$PILOT_GAP_FASTPATH_MIN"; then echo "pilot"; return; fi
  echo "general"
}

# _valid_action <action> → 0 iff action is one of the 4 allowlisted values.
# Anything else (typo, hallucinated verb, empty) is rejected here — the ONLY
# place this allowlist is enforced — and main() treats a rejection as "none".
_valid_action() {
  case "$1" in
    kickstart_gate|kickstart_pilot|nudge_mayor|none) return 0 ;;
    *) return 1 ;;
  esac
}

# _cooldown_elapsed <state_file> <cooldown_secs> <now_epoch> → 0 (true) when
# there's no/invalid prior timestamp (fail-open — a corrupt state file must never
# permanently silence real alerts) or the cooldown window has passed.
_cooldown_elapsed() {
  local f="$1" cd="$2" now="$3" last
  [ -f "$f" ] || return 0
  last="$(cat "$f" 2>/dev/null)"
  _is_int "$last" || return 0
  [ $(( now - last )) -ge "$cd" ]
}

_mark_now() {
  local f="$1" now="$2"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  echo "$now" > "$f" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════════
# COLLECTION — deterministic, cheap, individually stubbable by name-override.
# ════════════════════════════════════════════════════════════════════════════════

_now_epoch() { date +%s; }

# _parse_log_ts <line> → epoch seconds parsed from a leading "[YYYY-MM-DD HH:MM:SS]"
# prefix (the exact format every daemon's log() helper in this tree emits), or ""
# if the line doesn't match / date fails to parse it.
_parse_log_ts() {
  local line="$1" ts_str
  ts_str="$(printf '%s' "$line" | sed -n 's/^\[\([0-9][0-9-]* [0-9:]*\)\].*/\1/p')"
  [ -z "$ts_str" ] && { echo ""; return; }
  date -j -f '%Y-%m-%d %H:%M:%S' "$ts_str" '+%s' 2>/dev/null || echo ""
}

# _sweep_gap_min <log_file> <pattern> → integer minutes since the LAST line in the
# tail window containing <pattern> (fixed-string match), or "" (unknown) if the
# log is missing/unreadable or no match is found — never a silent 0.
_sweep_gap_min() {
  local log="$1" pattern="$2" line ts_epoch now
  [ -r "$log" ] || { echo ""; return; }
  line="$(tail -n "$LOG_TAIL" "$log" 2>/dev/null | grep -F -- "$pattern" | tail -1)"
  [ -z "$line" ] && { echo ""; return; }
  ts_epoch="$(_parse_log_ts "$line")"
  [ -z "$ts_epoch" ] && { echo ""; return; }
  now="$(_now_epoch)"
  echo $(( (now - ts_epoch) / 60 ))
}

# The exact strings both dispatchers log via their own log() at the top of every
# run — verified live 2026-07-20 (quality-gate-dispatcher.sh / pilot-dispatcher.sh):
#   [2026-07-20 18:19:30] [quality-gate-dispatcher] === Dispatcher sweep start (DRY_RUN=0) ===
#   [2026-07-20 18:12:45] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===
_collect_gate_gap() { _sweep_gap_min "$GATE_LOG" "Dispatcher sweep start"; }
_collect_pilot_gap() { _sweep_gap_min "$PILOT_LOG" "Pilot sweep start"; }

# _collect_open_markers → last "Found N queued marker(s)" count logged by the gate
# dispatcher, or 0 if no such line is in the tail window (0 is a legitimate,
# common reading — an idle gate with nothing queued — NOT an error state, unlike
# the gap fields above where a missing match signals something is genuinely off).
_collect_open_markers() {
  local line n
  [ -r "$GATE_LOG" ] || { echo "0"; return; }
  line="$(tail -n "$LOG_TAIL" "$GATE_LOG" 2>/dev/null | grep -oE 'Found [0-9]+ queued marker' | tail -1)"
  [ -z "$line" ] && { echo "0"; return; }
  n="$(printf '%s' "$line" | grep -oE '[0-9]+')"
  [ -z "$n" ] && echo "0" || echo "$n"
}

# _collect_disk_gb [path] → integer GB available on the filesystem hosting [path]
# (default $CITY), or "" if df fails/parses oddly. Same `df -k` / 1024/1024 idiom
# as dolt-disk-floor-guard.sh's _avail_gb (macOS/BSD df has no -g).
_collect_disk_gb() {
  local path="${1:-$CITY}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 / 1024 ))
}

# _collect_dolt_json → the gc-dolt-probe.sh shared module's JSON
# {ts,reachable,latency_ms,cpu,state,probe_rc}. Fail-open to an "unknown" shape if
# the module wasn't sourced (missing file) — NEVER hand-roll a bd/dolt timeout
# check here (imp07: that module exists specifically so every daemon shares one
# hardened, already-tested probe instead of N slightly-different reimplementations).
_collect_dolt_json() {
  if declare -f gc_dolt_probe_json >/dev/null 2>&1; then
    gc_dolt_probe_json 2>/dev/null
  else
    printf '{"ts":"","reachable":null,"latency_ms":-1,"cpu":"?","state":"unknown","probe_rc":-1}\n'
  fi
}

# _build_state_json — assemble the collected snapshot (+ the thresholds Haiku is
# judged against) into the JSON blob passed on the Haiku prompt. Unknown/empty
# numeric readings are encoded as JSON null (never coerced to 0), so an absent
# signal is visibly distinct from a confirmed-zero one on the Haiku side too.
_build_state_json() {
  local gate_gap="$1" pilot_gap="$2" dolt_responds="$3" dolt_latency="$4" dolt_state="$5" disk_gb="$6" open_markers="$7"
  jq -n \
    --arg gate_gap "$gate_gap" \
    --arg pilot_gap "$pilot_gap" \
    --argjson dolt_responds "$([ "$dolt_responds" = "true" ] && echo true || echo false)" \
    --arg dolt_latency "$dolt_latency" \
    --arg dolt_state "$dolt_state" \
    --arg disk_gb "$disk_gb" \
    --arg open_markers "$open_markers" \
    --argjson gate_gap_fastpath_min "$GATE_GAP_FASTPATH_MIN" \
    --argjson gate_gap_critical_min "$GATE_GAP_CRITICAL_MIN" \
    --argjson pilot_gap_fastpath_min "$PILOT_GAP_FASTPATH_MIN" \
    --argjson dolt_ms_warn "$DOLT_MS_WARN" \
    --argjson disk_gb_warn "$DISK_GB_WARN" \
    '{
      gate_sweep_gap_min: (if ($gate_gap|test("^[0-9]+$")) then ($gate_gap|tonumber) else null end),
      pilot_sweep_gap_min: (if ($pilot_gap|test("^[0-9]+$")) then ($pilot_gap|tonumber) else null end),
      dolt_responds: $dolt_responds,
      dolt_latency_ms: (if ($dolt_latency|test("^-?[0-9]+$")) then ($dolt_latency|tonumber) else null end),
      dolt_state: $dolt_state,
      disk_gb: (if ($disk_gb|test("^[0-9]+$")) then ($disk_gb|tonumber) else null end),
      open_markers_count: (if ($open_markers|test("^[0-9]+$")) then ($open_markers|tonumber) else 0 end),
      thresholds: {
        gate_gap_fastpath_min: $gate_gap_fastpath_min,
        gate_gap_critical_min: $gate_gap_critical_min,
        pilot_gap_fastpath_min: $pilot_gap_fastpath_min,
        dolt_ms_warn: $dolt_ms_warn,
        disk_gb_warn: $disk_gb_warn
      }
    }' 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
# HAIKU — the judgment call. Haiku receives the state JSON + this playbook and
# returns ONLY {"assessment","action","mayor_message"}; it has zero tools and
# cannot act. See GUARDRAILS at the top of this file for how the return value is
# constrained on the way back out.
# ════════════════════════════════════════════════════════════════════════════════

_haiku_playbook() {
  cat <<'PLAYBOOK'
You are the judgment layer for Gas City's city-health-sentinel. You will be given
a JSON snapshot of 3 subsystems (gate, pilot, dolt) plus disk space and the gate's
queued-marker backlog. You have NO tools and cannot inspect anything beyond this
JSON — reason only from the state given. Decide exactly ONE action.

KNOWN FALSE POSITIVES — do NOT act on these alone, prefer action="none":
- gate_sweep_gap_min is elevated (roughly 10-25min) but open_markers_count is 0:
  the gate is IDLE, not stalled. No work is queued, so an infrequent sweep is
  correct. This is the single most common ambiguous case you will see.
- gate_sweep_gap_min is moderately elevated (roughly 10-25min) while
  dolt_latency_ms is also elevated (roughly 500-3000ms): the dispatcher is very
  likely self-throttling under Dolt load (a sanctioned "headroom DEFER" behavior
  documented in this city's gate dispatcher) — this resolves on its own as Dolt
  load drops. Only lean toward action if open_markers_count is also high (5+)
  AND the pattern looks stuck rather than merely slow.
- pilot_sweep_gap_min up to ~20-25min is NORMAL, observed variance for a healthy
  Pilot — its sweeps are not on a fixed cadence. Do not treat this range as a
  problem on its own.
- A single elevated dolt_latency_ms with dolt_responds=true is one snapshot, not
  a trend. Dolt is UP. Slowness alone is not an outage.

REAL PROBLEMS — act on these:
- dolt_responds=false (Dolt unreachable): the most severe signal — Dolt is Gas
  City's sole data plane, and the gate/pilot will look broken too as a
  consequence, not a separate problem. -> action="nudge_mayor" ALWAYS. NEVER
  choose kickstart_gate or kickstart_pilot when dolt_responds=false: restarting
  those jobs cannot fix Dolt, and adds load to an already-unreachable dependency.
  This is a hard rule with no exception.
- disk_gb is very low (under ~3): likely the ROOT CAUSE of any other symptoms
  (daemons failing to write logs/state; Dolt itself is at risk of a full-disk
  crash). -> action="nudge_mayor", name disk space as the likely root cause in
  your assessment. Restarting a job does not free disk space.
- gate_sweep_gap_min is clearly extreme (over ~25min) AND open_markers_count>0
  (real work is backed up — this is not the idle case above) AND
  dolt_responds=true (Dolt itself is fine, so the dispatcher process is the
  likely culprit): -> action="kickstart_gate".
- pilot_sweep_gap_min is clearly extreme (over ~35min) AND dolt_responds=true:
  the Pilot process itself looks wedged. -> action="kickstart_pilot".

PRIORITY when more than one thing looks wrong: dolt trouble > disk trouble >
gate stall > pilot stall. Pick the single highest-priority action and mention
the others in "assessment" so the Mayor can see them if you chose nudge_mayor.

OUTPUT RULES:
- "action" must be exactly one of: kickstart_gate, kickstart_pilot, nudge_mayor,
  none.
- "mayor_message" is delivered directly into a live nudge to the Mayor's session
  — keep it to 1-3 short, factual, actionable sentences. If action="none",
  mayor_message may be empty.
- "assessment" is your reasoning for the audit log — be specific about which
  signals drove the decision.
- Do not claim to have checked logs, run a command, or verified anything beyond
  the JSON you were given.
- When genuinely torn between "none" and acting: prefer "none". A missed signal
  self-corrects next cycle (this sentinel runs roughly every 4 minutes); an
  unnecessary restart or a false page to the Mayor has real cost.
PLAYBOOK
}

# _invoke_haiku <state_json> → prints the decision JSON on stdout, returns 0 on a
# well-formed response, 1 on any failure (nonzero exit, timeout, empty output,
# unparseable JSON, or missing required fields) — the caller (main) treats a
# nonzero return as "Haiku unavailable" and applies _deterministic_fallback_action.
# The REAL implementation below is what selftest replaces wholesale with a stub
# (matching the GTSW_TEST_KICKSTARTS-style override pattern) — never mocked
# in-place with env branches, so there is no risk of test-only code paths shipping
# live.
_invoke_haiku() {
  local state_json="$1" prompt claude_out rc decision_json
  prompt="$(_haiku_playbook)
STATE:
$state_json

Return your decision now."

  claude_out="$(timeout "$HAIKU_TIMEOUT_S" "$CLAUDE_BIN" -p \
    --model "$HAIKU_MODEL" \
    --output-format json \
    --tools "" \
    --disable-slash-commands \
    --no-session-persistence \
    --json-schema "$HAIKU_JSON_SCHEMA" \
    "$prompt" 2>/dev/null)"
  rc=$?
  [ "$rc" -ne 0 ] && return 1
  [ -z "$claude_out" ] && return 1

  # Prefer the API's own parsed structured_output; fall back to .result with a
  # markdown-fence strip (observed: Haiku sometimes wraps JSON in ```json ... ```
  # even under --json-schema without a fence-stripping instruction).
  decision_json="$(printf '%s' "$claude_out" | jq -c '.structured_output // empty' 2>/dev/null)"
  if [ -z "$decision_json" ] || [ "$decision_json" = "null" ]; then
    local raw_result
    raw_result="$(printf '%s' "$claude_out" | jq -r '.result // empty' 2>/dev/null)"
    raw_result="$(printf '%s' "$raw_result" | sed -e '/^```/d')"
    decision_json="$(printf '%s' "$raw_result" | jq -c '.' 2>/dev/null)"
  fi

  [ -z "$decision_json" ] && return 1
  printf '%s' "$decision_json" | jq -e '.action != null and .mayor_message != null' >/dev/null 2>&1 || return 1
  printf '%s\n' "$decision_json"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTE — side-effecting; stubbable. NEVER called with an action that hasn't
# passed both _valid_action and the dolt-down guardrail override in main().
# ════════════════════════════════════════════════════════════════════════════════

_do_kickstart() {
  local label="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log "  DRY_RUN: would kickstart $label (not executed)"
    return 0
  fi
  if launchctl kickstart -k "gui/$UID_NUM/$label" 2>/dev/null; then
    log "  kickstart OK: $label"
  else
    log "  kickstart FAILED (may not be loaded): $label"
  fi
}

_do_nudge() {
  local msg="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log "  DRY_RUN: would nudge mayor: $msg (not executed)"
    return 0
  fi
  if timeout 15 "$GC" --city "$CITY" session nudge mayor "$msg" 2>/dev/null; then
    log "  nudge OK: mayor"
  else
    log "  nudge FAILED (or timed out): mayor"
  fi
}

# _execute_action — validated dispatch + rate-limiting. `action` here has ALREADY
# been through _valid_action and the dolt-down override in main(); this function
# only adds the per-topic/per-job cooldown gate before actually calling out.
_execute_action() {
  local action="$1" mayor_message="$2" gate_gap="$3" pilot_gap="$4" dolt_responds="$5" disk_gb="$6" now="$7"
  case "$action" in
    kickstart_gate)
      local f="$STATE_DIR/.city-health-sentinel.last-kickstart.gate"
      if _cooldown_elapsed "$f" "$KICKSTART_COOLDOWN_S" "$now"; then
        _do_kickstart "com.gascity.quality-gate-guard"
        _do_kickstart "com.gascity.quality-gate-dispatcher"
        _mark_now "$f" "$now"
        log "EXECUTED kickstart_gate (quality-gate-guard + quality-gate-dispatcher)"
      else
        log "SUPPRESSED kickstart_gate — rate-limited (last kickstart <${KICKSTART_COOLDOWN_S}s ago)"
      fi
      ;;
    kickstart_pilot)
      local f="$STATE_DIR/.city-health-sentinel.last-kickstart.pilot"
      if _cooldown_elapsed "$f" "$KICKSTART_COOLDOWN_S" "$now"; then
        _do_kickstart "com.gascity.pilot"
        _mark_now "$f" "$now"
        log "EXECUTED kickstart_pilot"
      else
        log "SUPPRESSED kickstart_pilot — rate-limited (last kickstart <${KICKSTART_COOLDOWN_S}s ago)"
      fi
      ;;
    nudge_mayor)
      local topic f
      topic="$(_compute_topic "$gate_gap" "$pilot_gap" "$dolt_responds" "$disk_gb")"
      f="$STATE_DIR/.city-health-sentinel.last-nudge.$topic"
      if _cooldown_elapsed "$f" "$NUDGE_COOLDOWN_S" "$now"; then
        [ -z "$mayor_message" ] && mayor_message="city-health-sentinel: state needs attention (topic=$topic) — no message text was provided."
        _do_nudge "[city-health-sentinel] $mayor_message"
        _mark_now "$f" "$now"
        log "EXECUTED nudge_mayor (topic=$topic)"
      else
        log "SUPPRESSED nudge_mayor — rate-limited (topic=$topic, last nudge <${NUDGE_COOLDOWN_S}s ago)"
      fi
      ;;
    none)
      log "decision=none — no action taken"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════════

main() {
  local now gate_gap pilot_gap open_markers disk_gb
  local dolt_json dolt_responds_raw dolt_responds dolt_latency dolt_state
  now="$(_now_epoch)"

  gate_gap="$(_collect_gate_gap)"
  pilot_gap="$(_collect_pilot_gap)"
  open_markers="$(_collect_open_markers)"
  disk_gb="$(_collect_disk_gb)"

  dolt_json="$(_collect_dolt_json)"
  dolt_responds_raw="$(printf '%s' "$dolt_json" | jq -r '.reachable' 2>/dev/null)"
  if [ "$dolt_responds_raw" = "true" ]; then dolt_responds="true"; else dolt_responds="false"; fi
  dolt_latency="$(printf '%s' "$dolt_json" | jq -r '.latency_ms' 2>/dev/null)"
  _is_int "$dolt_latency" || dolt_latency="-1"
  dolt_state="$(printf '%s' "$dolt_json" | jq -r '.state // "unknown"' 2>/dev/null)"

  local state_json
  state_json="$(_build_state_json "$gate_gap" "$pilot_gap" "$dolt_responds" "$dolt_latency" "$dolt_state" "$disk_gb" "$open_markers")"

  log "collected: gate_gap=${gate_gap:-unknown}min pilot_gap=${pilot_gap:-unknown}min dolt=${dolt_state}(responds=${dolt_responds} ${dolt_latency}ms) disk=${disk_gb:-unknown}GB open_markers=${open_markers}"

  if _fastpath_ok "$gate_gap" "$pilot_gap" "$dolt_responds" "$dolt_latency" "$disk_gb"; then
    log "FAST-PATH ok — all signals green, Haiku NOT invoked."
    return 0
  fi

  log "AMBIGUOUS — invoking Haiku ($HAIKU_MODEL). state=$state_json"

  local decision_json action assessment mayor_message
  if decision_json="$(_invoke_haiku "$state_json")" && [ -n "$decision_json" ]; then
    action="$(printf '%s' "$decision_json" | jq -r '.action // empty')"
    assessment="$(printf '%s' "$decision_json" | jq -r '.assessment // empty')"
    mayor_message="$(printf '%s' "$decision_json" | jq -r '.mayor_message // empty')"
    log "Haiku decision: action=${action:-<empty>} assessment=\"$assessment\""
  else
    action="$(_deterministic_fallback_action "$gate_gap" "$dolt_responds")"
    assessment="Haiku call failed, timed out, or returned an unparseable response — deterministic fallback rule applied (dolt down -> nudge_mayor; else gate_gap>${GATE_GAP_CRITICAL_MIN} -> kickstart_gate; else none)."
    mayor_message="city-health-sentinel: Haiku judgment was unavailable this cycle; deterministic fallback chose '$action'. gate_gap=${gate_gap:-unknown}min dolt_responds=$dolt_responds."
    log "WARN: Haiku unavailable — deterministic fallback: action=$action"
  fi

  if ! _valid_action "$action"; then
    log "WARN: action '${action:-<empty>}' is not in the allowlist — treating as none (fail-safe)"
    action="none"
  fi

  # HARD GUARDRAIL (defense in depth — also stated in the playbook above): never
  # let ANY path, including a misbehaving Haiku response, choose to touch Dolt
  # while it is unreachable. This check re-derives the decision from the
  # deterministically-collected dolt_responds, never from Haiku's text.
  if [ "$dolt_responds" != "true" ] && [ "$action" != "nudge_mayor" ] && [ "$action" != "none" ]; then
    log "GUARDRAIL OVERRIDE: dolt_responds=false but action was '$action' — forcing nudge_mayor (this sentinel never restarts/touches Dolt)"
    action="nudge_mayor"
    if [ -z "$mayor_message" ]; then
      mayor_message="city-health-sentinel: Dolt is unreachable (dolt_responds=false). Needs human attention — this sentinel never restarts or touches Dolt."
    fi
  fi

  _execute_action "$action" "$mayor_message" "$gate_gap" "$pilot_gap" "$dolt_responds" "$disk_gb" "$now"
  log "=== cycle complete: action=$action ==="
}

# ── run unless sourced as a library (selftest sources with CITY_HEALTH_SENTINEL_LIB=1) ──
if [ "${CITY_HEALTH_SENTINEL_LIB:-0}" != "1" ]; then
  main
  exit 0
fi
