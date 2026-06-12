#!/usr/bin/env bash
# pilot-dispatcher.sh — Autonomous Pilot Dispatcher ("Pilot" / "P").
#
# Runs every ~300s via launchd (com.gascity.pilot.plist).
# PRIORITY DIRECTIVE: "Só depois do sistema perfeito é que a gente faz novas features."
#   Tier 1 (always first): open BUG beads (type:bug) + tech-debt-labeled beads NOT
#     already in-flight/done/assigned. Dispatched as fix tasks to the builder.
#   Tier 2 (only when Tier 1 is EMPTY): story:approved feature stories.
# Picks highest priority within the active tier (P0>P1>P2..., tie-break oldest),
# atomically claims it, dispatches a builder session via gc sling, then transitions
# the bead to story:in-flight.
#
# TWO-LANE DISPATCH (anti-deadlock):
#   SMALL/fast lane (MAX_SMALL, default 5): small items — merge fast, high concurrency.
#   BIG/slow  lane (MAX_BIG,   default 2): big items  — dedicated lane so they can't
#     hog the small lane and starve fast work.
#   Each lane has its OWN cap. A full big lane does NOT block small dispatches.
#   Lane classification (at dispatch time, in priority order):
#     1. Explicit label: lane:big or lane:small on the bead.
#     2. story.size_check metadata == "epic" → big.
#     3. Acceptance-criteria count >= 5 → big.
#     4. Default → small.
#   Tagged on dispatch (lane:big / lane:small) so in-flight counting works.
#   ESCALATION: a worker may relabel lane:small → lane:big mid-flight to correct
#   accounting; Pilot re-counts each sweep from actual bead labels.
#
# Bugs-first tiering is preserved WITHIN each lane.
#
# This is the FRONT HALF of the autonomous delivery loop:
#
#   Pilot (this) → spawns builder → builder implements → /gate-done
#     → G (quality-gate) reviews + merges → ① (story-delivery) deploys + tests
#
# DESIGN INVARIANTS:
#   - Claim is ATOMIC: add pilot:dispatching label + verify before acting.
#     TTL recovery releases stale pilot:dispatching claims after CLAIM_TTL_MINUTES.
#   - Capacity cap: per-lane caps (MAX_SMALL, MAX_BIG). Pilot fills whichever lane
#     has a free slot, up to one dispatch per lane per sweep (or all available slots).
#   - Idempotent: skip beads with story:in-flight, story:done, or already
#     assigned (assignee set). Never dispatch the same bead twice.
#   - Dependency-aware (ga-5ew): skip beads BLOCKED by unresolved (open)
#     dependencies. A story is only dispatchable once every bead it hard-depends
#     on is closed/merged. Uses bd's blocker-aware `bd blocked` set, per-DB,
#     fail-open. See _filter_unblocked.
#   - Explicit-dep-aware (ga-do8jj): ALSO skip beads that declare a still-open
#     dependency via the `story.depends_on_beads` metadata field (space/comma-
#     separated bead IDs). This catches "de-facto" deps documented in prose but
#     never encoded as a formal `bd` edge — the gap that let ga-2e605 dispatch
#     before its base ga-e72kf landed. Auto-clearing, fail-open. See
#     _filter_explicit_deps.
#   - Self-exclusion: never dispatch bead ga-8c1 (the Pilot itself) — it cannot
#     build itself. Excluded by label policy (pilot:self) not hardcode.
#   - Cross-rig aware: reads HQ DB (authoritative for all story beads per
#     convention). Falls back to scanning rig DBs if HQ returns none.
#   - Builder routing: maps story.rig metadata → gc sling target using the
#     RIG_TO_BUILDER table below. Falls back to gastown.dog for unknown rigs.
#   - DRAIN-SAFE: this file + its plist are the ONLY artifacts. Does not touch
#     city.toml, pack.toml, or any crew skill files.
#   - DRY_RUN=1 → shows full pick + would-dispatch, makes zero state changes.
#
# Usage:
#   bash pilot-dispatcher.sh            # normal run
#   DRY_RUN=1 bash pilot-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

# City root. Defaults to the live HQ. PILOT_CITY_OVERRIDE is a TEST-ONLY seam
# (used by pilot-dispatcher.selftest.sh to redirect bd -C / logs / jsonl into a
# throwaway fixture); it is never set in production, where this resolves to the
# hardcoded default. Mirrors the SKILL_AUDIT_* override convention.
GC_CITY="${PILOT_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/pilot-dispatcher.log"
PILOT_LOG="$GC_CITY/.gc/pilot-dispatcher.jsonl"

# ── Two-lane caps ─────────────────────────────────────────────────────────────
# SMALL/fast lane: high concurrency, small items that merge quickly.
MAX_SMALL="${MAX_SMALL:-5}"
# BIG/slow lane: dedicated, prevents big items from blocking small ones.
MAX_BIG="${MAX_BIG:-2}"

# Gate reviewer pool size — observability only (ga-8c1 AC5). The Pilot dispatches
# builders, NOT reviewers; this is read-only so each sweep's log can show the
# whole pipeline's free capacity (builders + gate reviewers) at a glance. Matches
# the gate-reviewer template's max_active_sessions=6.
MAX_REVIEWERS="${MAX_REVIEWERS:-6}"

# Acceptance-criteria count threshold for auto-classifying a story as BIG.
BIG_CRITERIA_THRESHOLD="${BIG_CRITERIA_THRESHOLD:-5}"

# TTL for stuck pilot:dispatching claims (minutes). After this, Pilot recycles them.
CLAIM_TTL_MINUTES="${CLAIM_TTL_MINUTES:-30}"

# ── Dispatch-to-capacity (ga-rk5va) ───────────────────────────────────────────
# When 1 (default), each lane dispatches to fill EVERY free slot in a single sweep
# (looping pick→claim→sling until the lane is full or candidates are exhausted),
# instead of the legacy one-dispatch-per-lane-per-sweep. This is the user's "máxima
# lotação" goal: after a drain, 5 free small slots refill in ONE sweep, not ~5.
# Set 0 to force the legacy single-pick-per-lane behavior.
DISPATCH_TO_CAPACITY="${DISPATCH_TO_CAPACITY:-1}"

# ── Dolt-saturation backoff (ga-rk5va adversarial constraint a) ────────────────
# Dispatch-to-capacity multiplies bd/dolt shellouts per sweep (N× the load that
# drove the fd-leak/CPU incidents). It MUST self-throttle when Dolt is already
# hot, or it widens a wedged pipe. Before filling slots we probe Dolt health once;
# if SATURATED we cap each lane to a single dispatch this sweep (== legacy safe
# behavior, never worse than before). Between dispatches we re-check cheaply and
# bail the moment Dolt crosses the ceiling. Saturation = server response latency
# OR the live dolt-server process CPU% exceeds these ceilings. CPU baseline is
# ~86-90% under normal load (per the gate-falsefail incident); 200 (= ~2 pegged
# cores) is the documented danger zone, latency baseline is sub-second.
PILOT_DOLT_LATENCY_MAX_MS="${PILOT_DOLT_LATENCY_MAX_MS:-2500}"
PILOT_DOLT_CPU_MAX="${PILOT_DOLT_CPU_MAX:-200}"
# TEST-ONLY seams (mirror PILOT_CITY_OVERRIDE): when set, the health probe uses
# these instead of shelling out to `gc dolt health` / `ps`. Never set in prod.
PILOT_DOLT_LATENCY_OVERRIDE_MS="${PILOT_DOLT_LATENCY_OVERRIDE_MS:-}"
PILOT_DOLT_CPU_OVERRIDE="${PILOT_DOLT_CPU_OVERRIDE:-}"

# ── Claude 5h-quota back-off (ga-x3nmz) ───────────────────────────────────────
# A builder dispatched while the Claude 5h window is exhausted dies mid-build
# ("you've hit your session limit") → a wasted lane slot + a phantom in-flight
# bead the dispatcher must later reap. Before filling slots we probe the
# GROUND-TRUTH quota (ga-wjlv9 checker); if LIMITED we PAUSE all dispatch this
# sweep — the candidate stories stay queued and are re-picked automatically once
# the window resets (no marker mutated, nothing lost). FAIL-OPEN: an absent or
# erroring checker never blocks dispatch (the dependency is optional).
# PILOT_QUOTA_OVERRIDE is a TEST-ONLY seam (mirrors PILOT_DOLT_CPU_OVERRIDE):
# "2" = limited, anything else = ok. Never set in prod.
PILOT_QUOTA_OVERRIDE="${PILOT_QUOTA_OVERRIDE:-}"
PILOT_QUOTA_ETA_OVERRIDE="${PILOT_QUOTA_ETA_OVERRIDE:-}"

# ── Stale in-flight slot correction (ga-rk5va adversarial constraint c) ────────
# A story:in-flight bead normally occupies a builder slot. But a session can hang
# (the 16h-stuck-session bug) — zero state-transitions for hours while the bead
# still reads in-flight. Such a bead is a PHANTOM occupant: it pins a slot that no
# one is working, so capacity math is wrong (slots sit empty). We treat a bead
# whose last transition (updated_at) is older than this many hours as NOT a live
# occupant — it stops consuming a slot, freeing it for OTHER pending work. The
# stale bead itself is NOT re-dispatched (it keeps story:in-flight and stays
# excluded from candidate queries), so this can never double-dispatch the same
# story; it only stops an abandoned build from starving the lane forever.
PILOT_STUCK_INFLIGHT_HOURS="${PILOT_STUCK_INFLIGHT_HOURS:-2}"

# ── Dead-worker in-flight correction (ga-e5yw2) ───────────────────────────────
# The age cutoff above only frees a slot after PILOT_STUCK_INFLIGHT_HOURS of
# TOTAL silence on the source row. It misses the dominant phantom: a bead whose
# source row was touched recently (label/dispatch churn) but whose BUILDER
# SESSION has already died — crashed, reaped, or killed — without clearing
# story:in-flight. Those read "live" by age yet hold a slot no worker occupies:
# the raw=7-vs-real-4 over-count that makes the Pilot see a full lane and throttle
# dispatch while real capacity sits idle (bug ga-e5yw2). When set to 1 (default)
# the dispatcher resolves each in-flight bead's sling-task assignee and counts the
# bead as a live occupant ONLY if that assignee is a live session in
# `gc session list`; a bead whose worker session is provably gone stops consuming
# a slot. Fail-safe in every unresolved leg (no sling, no assignee, roster
# unreadable/empty) → KEEP, so the worst case is the harmless pre-fix over-count,
# never an over-dispatch. Set to 0 to disable the cross-check entirely.
PILOT_DEADWORKER_CHECK="${PILOT_DEADWORKER_CHECK:-1}"

# Dry-run mode: show what WOULD happen, make zero changes.
DRY_RUN="${DRY_RUN:-0}"

# Story bead to NEVER dispatch (the Pilot itself — cannot self-build).
SELF_BEAD_ID="ga-8c1"

# ── Rig → Builder routing table ───────────────────────────────────────────────
# Maps story.rig metadata → gc sling target alias.
# Priority: prefer the rig's dedicated builder; fall back to gastown.dog.
#
# Canonical crew-agent naming convention (ga-nkkku): <name>-<sigla>
# Sigla → rig mapping (source of truth):
#   lx = lexbh              (batista-lx)
#   wa = whatsapp_automation (digo-wa, mila-wa, oracle-wa, peter-wa, thies-wa)
#   ps = property_scrapers  (batista-ps)
#   ma = marketing
#   hq = gastown-hq         (system/infra agents)
# rig_to_builders <rig> — print the rig's ORDERED builder POOL (space-separated).
# A rig with >1 interchangeable single-identity crew (e.g. whatsapp_automation:
# digo/mila/oracle/peter/thies-wa) is a POOL: the dispatcher distributes work
# across its members (ga-mtlm6) instead of piling every bead on one. Pool order
# is the dispatch preference (first-eligible wins). Single-member rigs are a pool
# of one — behaviourally identical to the pre-ga-mtlm6 single-target routing.
rig_to_builders() {
  local rig="$1"
  case "$rig" in
    gascity)               echo "gastown.dog"    ;;
    whatsapp_automation|wa) echo "digo-wa mila-wa oracle-wa peter-wa thies-wa" ;;
    property_scrapers|ps)  echo "batista-ps"     ;;
    gastown|gt)            echo "gastown.dog"    ;;
    lexbh|lx)              echo "gastown.dog"    ;;
    marketing|ma)          echo "gastown.dog"    ;;
    *)                     echo "gastown.dog"    ;;
  esac
}

# rig_to_builder <rig> — back-compat single target: the first builder of the pool.
rig_to_builder() {
  set -- $(rig_to_builders "$1")
  echo "${1:-gastown.dog}"
}

# ── Pool selection state (ga-mtlm6) ───────────────────────────────────────────
# PILOT_BUSY_BUILDERS — builders currently holding LIVE in-flight work (computed
#   once per sweep from IN_FLIGHT_JSON's sling-task assignees). A busy single-
#   identity crew must NOT receive a second task (the wa-1eos duplicate-session /
#   branch-corruption hazard).
# PILOT_USED_BUILDERS — builders given work earlier in THIS sweep, so consecutive
#   picks rotate across distinct idle crew rather than all landing on the first.
# Both are space-padded membership lists, fail-open (empty = no exclusion).
PILOT_BUSY_BUILDERS=""
PILOT_USED_BUILDERS=""

# pick_pool_builder <rig> — echo an idle crew from the rig's pool, or nothing (and
# return 1) if every member is busy or already used this sweep. Pure read of the
# two sets above; the caller records the winner via mark_pool_builder so the next
# pick in the same sweep advances to a different crew.
pick_pool_builder() {
  local crew
  for crew in $(rig_to_builders "$1"); do
    case " $PILOT_BUSY_BUILDERS " in *" $crew "*) continue ;; esac
    case " $PILOT_USED_BUILDERS " in *" $crew "*) continue ;; esac
    echo "$crew"
    return 0
  done
  return 1
}

# mark_pool_builder <builder> — record a builder as used this sweep (idempotent).
# MUST be called in the main shell (never a subshell) so the global persists.
mark_pool_builder() {
  case " $PILOT_USED_BUILDERS " in
    *" $1 "*) : ;;
    *) PILOT_USED_BUILDERS="${PILOT_USED_BUILDERS:+$PILOT_USED_BUILDERS }$1" ;;
  esac
}

# ── Lane classification ───────────────────────────────────────────────────────
# classify_lane <bead_json>
# Prints "big" or "small".
classify_lane() {
  local bead="$1"

  # 1. Explicit label wins.
  local labels
  labels=$(echo "$bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
  if echo "$labels" | grep -q "lane:big";   then echo "big";   return; fi
  if echo "$labels" | grep -q "lane:small"; then echo "small"; return; fi

  # 2. story.size_check metadata == "epic" → big.
  local size_check
  size_check=$(echo "$bead" | jq -r '.metadata["story.size_check"] // ""' 2>/dev/null || echo "")
  if [ "$size_check" = "epic" ]; then echo "big"; return; fi

  # 3. Count acceptance criteria lines (newline-separated) — if ≥ threshold → big.
  local criteria crit_count
  criteria=$(echo "$bead" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""' 2>/dev/null || echo "")
  crit_count=$(printf '%s' "$criteria" | grep -c '^.' 2>/dev/null || echo "0")
  # Strip any whitespace/newlines from count (defensive).
  crit_count=$(printf '%s' "$crit_count" | tr -d '[:space:]')
  crit_count=${crit_count:-0}
  if [ "$crit_count" -ge "$BIG_CRITERIA_THRESHOLD" ] 2>/dev/null; then echo "big"; return; fi

  # 4. Default → small.
  echo "small"
}

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: $*"; }

# ── Single-instance guard (ga-2azzj fix 2; ga-7s0or fd-leak rewrite) ──────────
# Two concurrent sweeps (launchd StartInterval overlap, or a manual run racing
# the timer) can BOTH pass the so-called "atomic claim" — `bd label add` is
# idempotent and the post-claim verify only rejects in-flight/done — and then
# sling the SAME story to two builders (the ga-8nu8x double-build). A whole-run
# lock closes that window: only one sweep proceeds; a second exits cleanly.
#
# PRIOR DESIGN (ga-2azzj): `exec 9>$LOCK; flock -n 9` held an exclusive flock on
# fd 9 for the whole sweep. DEFECT (ga-7s0or, P0): fd 9 had NO close-on-exec, so
# every gc/bd/sling child — and any long-lived daemon they (re)spawned, notably a
# dolt sql-server or the slung builder session — INHERITED fd 9 and held the
# flock for its ENTIRE life (5h+ observed: a dolt pid held the lock inode). Every
# later sweep then logged "backing off" and dispatched ZERO: a silent, unbounded,
# total dispatch deadlock independent of Dolt load (it would deadlock at 0% CPU).
#
# bash 3.2 (the launchd interpreter, /bin/bash) cannot set close-on-exec on a
# numbered fd (`exec {var}>` auto-CLOEXEC is bash 4.1+), and closing fd 9 before
# the sling would drop the guard mid-sweep. So we abandon the inheritable-fd
# flock entirely for an fd-LESS lock that no child can ever hold open:
#   • an atomic `mkdir` mutex for mutual exclusion (POSIX-atomic; no fd, no
#     inheritance — a leaked fd cannot keep a directory "locked"), and
#   • a heartbeat file whose MTIME, written at acquire, marks liveness.
# A held lock whose heartbeat mtime is older than PILOT_LOCK_MAX_AGE is a
# dead/zombie holder (a crashed sweep leaves the dir but stops refreshing it) and
# is recovered automatically WITHOUT rm of any flock inode. PID-liveness is
# deliberately NOT used (PID recycling = TOCTOU false-"alive", per ga-7s0or AC).
# Recovery uses an atomic rename (`mv` of the stale dir aside) so two concurrent
# recoverers can never BOTH proceed — only one rename of a given path can win;
# the loser gets ENOENT and backs off (ga-7s0or AC3, no double-dispatch).
PILOT_LOCK_DIR="${TMPDIR:-/tmp}/pilot-dispatcher$(printf '%s' "$GC_CITY" | tr '/ ' '__').lock.d"
PILOT_LOCK_HB="$PILOT_LOCK_DIR/heartbeat"
# A real sweep finishes in seconds; 600s (10 min) is a vast margin that still
# reclaims a wedged holder within two launchd intervals.
PILOT_LOCK_MAX_AGE="${PILOT_LOCK_MAX_AGE:-600}"
PILOT_LOCK_TOKEN="$$:${RANDOM}${RANDOM}"

# Age (seconds) of the heartbeat file; a huge number if it is missing.
_lock_hb_age() {
  local _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$PILOT_LOCK_HB" 2>/dev/null || stat -c %Y "$PILOT_LOCK_HB" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}

_lock_write_hb() { printf '%s\n' "$PILOT_LOCK_TOKEN" > "$PILOT_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a
# peer that recovered our lock after we were (wrongly) judged stale.
_release_pilot_lock() {
  local _own
  _own=$(head -n1 "$PILOT_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$PILOT_LOCK_TOKEN" ] && rm -rf "$PILOT_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE sweep holds it (back off).
_acquire_pilot_lock() {
  if mkdir "$PILOT_LOCK_DIR" 2>/dev/null; then
    _lock_write_hb
    return 0
  fi
  local _age
  _age=$(_lock_hb_age)
  if [ "$_age" -lt "$PILOT_LOCK_MAX_AGE" ]; then
    return 1   # fresh heartbeat → a live sweep is running.
  fi
  # Stale holder. Atomically claim the recovery by renaming the dir aside; only
  # one concurrent recoverer can win this rename (the rest get ENOENT).
  local _reaped="${PILOT_LOCK_DIR}.reaping.${PILOT_LOCK_TOKEN}"
  if mv "$PILOT_LOCK_DIR" "$_reaped" 2>/dev/null; then
    rm -rf "$_reaped" 2>/dev/null || true
    if mkdir "$PILOT_LOCK_DIR" 2>/dev/null; then
      _lock_write_hb
      log "Recovered STALE Pilot lock (heartbeat age ${_age}s ≥ ${PILOT_LOCK_MAX_AGE}s) — taking over (ga-7s0or)."
      return 0
    fi
  fi
  return 1   # lost the recovery race to a peer, or a fresh sweep beat us.
}

if _acquire_pilot_lock; then
  trap '_release_pilot_lock' EXIT
else
  log "Another Pilot sweep holds $PILOT_LOCK_DIR — backing off (single-instance guard)."
  exit 0
fi

echo ""
log "=== Pilot sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Dolt-saturation probe (ga-rk5va constraint a) ─────────────────────────────
# One health probe per sweep seeds DOLT_PID + DOLT_LATENCY_MS; the cheap CPU
# recheck used inside the dispatch loop reuses DOLT_PID via `ps` (sub-second, no
# extra Dolt round-trips). All probes FAIL-SAFE: if Dolt health can't be read we
# treat it as SATURATED (back off), because adding dispatch load to an unknown /
# wedged data plane is exactly the incident this constraint guards against.
DOLT_PID=""
DOLT_LATENCY_MS=""

# ── ga-x3nmz: Claude 5h-quota probe (mirrors gate's gate_quota_limited) ───────
# _pilot_quota_limited → "1" iff the Claude 5h window is exhausted right now, else
# "0". Uses the ga-wjlv9 ground-truth checker (claude-quota-check.sh --quiet,
# exit 2 = LIMITED) when deployed; FAIL-OPEN ("0") when the checker is absent or
# errors, so an unmerged/flaky dependency never wedges dispatch. Honors the
# PILOT_QUOTA_OVERRIDE test seam ("2"=limited). Bounded by `timeout`. No mutation.
_pilot_quota_limited() {
  if [ -n "$PILOT_QUOTA_OVERRIDE" ]; then
    [ "$PILOT_QUOTA_OVERRIDE" = "2" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf '0'; return 0; }
  local _rc=0
  timeout 15 bash "$_qc" --quiet >/dev/null 2>&1 || _rc=$?
  [ "$_rc" = "2" ] && { printf '1'; return 0; }
  printf '0'; return 0
}

# _pilot_quota_eta → short human ETA ("resets 4:50pm (in 37min)") or "" if
# unknown. Reads the checker JSON (reset_time_text + reset_in_minutes). Honors
# PILOT_QUOTA_ETA_OVERRIDE (test seam). Bounded; fail-soft to "".
_pilot_quota_eta() {
  if [ -n "$PILOT_QUOTA_ETA_OVERRIDE" ]; then printf '%s' "$PILOT_QUOTA_ETA_OVERRIDE"; return 0; fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf ''; return 0; }
  local _j; _j=$(timeout 15 bash "$_qc" --json 2>/dev/null || echo "")
  [ -n "$_j" ] || { printf ''; return 0; }
  printf '%s' "$_j" | jq -r '
    if (.reset_time_text // "") == "" then ""
    else "resets " + .reset_time_text
         + ( if (.reset_in_minutes // null) != null then " (in \(.reset_in_minutes)min)" else "" end )
    end' 2>/dev/null || printf ''
}

# _dolt_probe — populate DOLT_PID + DOLT_LATENCY_MS once. Honors the test seams.
_dolt_probe() {
  if [ -n "$PILOT_DOLT_LATENCY_OVERRIDE_MS" ]; then
    DOLT_LATENCY_MS="$PILOT_DOLT_LATENCY_OVERRIDE_MS"
    DOLT_PID="TEST"
    return 0
  fi
  local _h
  # `gc dolt health` bounds each per-db probe internally; cap total wall time so a
  # wedged server can't stall the sweep. A timeout IS evidence of saturation.
  # NOTE: `gc dolt health` does NOT accept the global `--city` flag (unlike
  # `rig list` / `session list`) — passing it errors with "unknown flag: --city"
  # and the probe returns empty → fail-safe saturated → the feature would be
  # permanently throttled off. Scope the city via the GC_CITY env var instead
  # (the leaf walks up from cwd / honors GC_CITY); this is the form that works.
  _h=$(GC_CITY="$GC_CITY" timeout 15 gc dolt health --json 2>/dev/null || echo "")
  DOLT_LATENCY_MS=$(printf '%s' "$_h" | jq -r '.server.latency_ms // empty' 2>/dev/null || echo "")
  DOLT_PID=$(printf '%s' "$_h" | jq -r '.server.pid // empty' 2>/dev/null || echo "")
}

# _dolt_cpu — echo integer CPU% of the live dolt-server pid (cheap). Honors seam.
# Always returns 0 (an empty echo means "no signal") so a missing pid / dead ps
# can never trip `set -e` in the caller's command substitution.
_dolt_cpu() {
  if [ -n "$PILOT_DOLT_CPU_OVERRIDE" ]; then printf '%s' "$PILOT_DOLT_CPU_OVERRIDE"; return 0; fi
  if [ -z "$DOLT_PID" ] || [ "$DOLT_PID" = "TEST" ]; then printf ''; return 0; fi
  # ps %cpu can exceed 100 (per-core); strip the fraction to an int for -gt tests.
  ps -o %cpu= -p "$DOLT_PID" 2>/dev/null | tr -d ' ' | cut -d. -f1 || true
  return 0
}

# _dolt_saturated — return 0 (saturated → back off) / 1 (healthy). FAIL-SAFE:
# missing latency AND missing cpu (probe failed) → saturated.
_dolt_saturated() {
  local _lat _cpu _have=0
  _lat="$DOLT_LATENCY_MS"
  _cpu="$(_dolt_cpu)"
  if [ -n "$_lat" ] && [ "$_lat" -ge 0 ] 2>/dev/null; then
    _have=1
    [ "$_lat" -gt "$PILOT_DOLT_LATENCY_MAX_MS" ] 2>/dev/null && return 0
  fi
  if [ -n "$_cpu" ] && [ "$_cpu" -ge 0 ] 2>/dev/null; then
    _have=1
    [ "$_cpu" -gt "$PILOT_DOLT_CPU_MAX" ] 2>/dev/null && return 0
  fi
  # No usable signal at all → fail-safe to saturated (conservative backoff).
  [ "$_have" -eq 0 ] && return 0
  return 1
}

_dolt_probe
if _dolt_saturated; then
  PILOT_DOLT_SATURATED_AT_START=1
  warn "Dolt SATURATED at sweep start (latency=${DOLT_LATENCY_MS:-?}ms pid=${DOLT_PID:-?} cpu=$(_dolt_cpu)% thresholds: lat>${PILOT_DOLT_LATENCY_MAX_MS} cpu>${PILOT_DOLT_CPU_MAX}). Throttling to 1 dispatch/lane this sweep (ga-rk5va backoff)."
else
  PILOT_DOLT_SATURATED_AT_START=0
  log "Dolt health OK (latency=${DOLT_LATENCY_MS:-?}ms cpu=$(_dolt_cpu)%) — dispatch-to-capacity armed."
fi

# ── ga-x3nmz: Claude 5h-quota back-off — PAUSE dispatch when the window is dry ─
# Probe once per sweep, AFTER the Dolt gate (cheap when quota is fine: one bounded
# checker call). If the 5h window is exhausted, a builder dispatched now would die
# mid-build, so PAUSE the whole sweep: dispatch nothing, mutate no marker, and let
# the candidate stories be re-picked automatically once the window resets. This is
# a full pause (not a throttle): under exhaustion every new builder dies, so there
# is no safe non-zero dispatch level. FAIL-OPEN via _pilot_quota_limited.
if [ "$(_pilot_quota_limited)" = "1" ]; then
  _q_eta=$(_pilot_quota_eta)
  warn "Claude 5h quota LIMITED — PAUSING all dispatch this sweep (builders would die mid-build). Stories stay queued; auto-resumes when the window resets${_q_eta:+ ($_q_eta)} (ga-x3nmz)."
  notify -t "⏸️ Pilot pausado: cota 5h" -p 3 "Pilot pausado — cota 5h do Claude esgotada; nenhum builder despachado, retoma quando resetar${_q_eta:+ ($_q_eta)} (ga-x3nmz)." 2>/dev/null || true
  log "=== Pilot sweep complete: dispatched=0 (paused: cota 5h limitada${_q_eta:+, $_q_eta}) ==="
  exit 0
fi

# ── Step 0: TTL recovery — release stale pilot:dispatching claims (ga-2azzj) ───
# A pilot:dispatching label means a dispatch is (or was) in progress. We may only
# RECYCLE it when it is genuinely STALE — i.e. the dispatcher crashed mid-run.
#
# DEFECT A (ga-2azzj, the bug this rewrite fixes): the previous code measured
# staleness from the bead's updated_at. `bd label add` does NOT bump updated_at
# to claim time, so an OLD bead's FRESH claim read as age >> TTL (observed
# 47433s ≈ 13h for a 5-min-old claim) and got released on the very next sweep →
# the story became re-dispatchable while a builder was already building it →
# the same story went to two dogs (ga-8nu8x double-build, one wasted cycle).
#
# FIX: age is measured from a dedicated metadata stamp `pilot.dispatching_at`,
# written at claim time (see dispatch_one) BEFORE the label, so the label can
# never exist without its stamp. Decision rules:
#   - stamp missing (legacy claim) → DO NOT release; stamp NOW so the clock
#       starts from this sweep. Never fall back to updated_at (that IS Defect A).
#   - stamp present, age <= TTL    → keep (the claim is fresh, build in flight).
#   - stamp present, age >  TTL, but a recorded sling task (pilot.sling_bead) is
#       still OPEN → a builder is actively working a long build; refuse release.
#   - stamp present, age >  TTL, no live sling task → release (truly stale).
#
# gt-pm55p: Also scan rig DBs. After the cross-rig fix, pilot:dispatching labels
# for wa-*/ps-*/etc. beads live in their rig DB, not in GC_CITY. Without rig
# scanning, stale cross-rig claims would never be cleaned up by TTL recovery.

# Helper: scan one DB for stale pilot:dispatching claims and release them.
# Usage: _ttl_recover_db <db_path> <now_epoch> <ttl_secs>
_ttl_recover_db() {
  local _db="$1" _now="$2" _ttl="$3"
  local _stale_json _stale_count
  _stale_json=$(bd -C "$_db" list --json --all \
    -l "story:approved" \
    -l "pilot:dispatching" \
    2>/dev/null || echo "[]")
  _stale_count=$(echo "$_stale_json" | jq 'length' 2>/dev/null || echo "0")
  [ "$_stale_count" -le "0" ] && return 0

  echo "$_stale_json" | jq -c '.[]' | while IFS= read -r bead; do
    local _bid _stamp _sling
    _bid=$(echo "$bead" | jq -r '.id' 2>/dev/null || echo "")
    [ -z "$_bid" ] && continue
    _stamp=$(echo "$bead" | jq -r '.metadata["pilot.dispatching_at"] // ""' 2>/dev/null || echo "")
    _sling=$(echo "$bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")

    if [ -z "$_stamp" ] || ! [ "$_stamp" -ge 0 ] 2>/dev/null; then
      warn "TTL: $_bid has pilot:dispatching but no pilot.dispatching_at stamp (legacy) — stamping now, NOT releasing (Defect A guard)."
      bd -C "$_db" update "$_bid" --set-metadata "pilot.dispatching_at=$_now" -q 2>/dev/null || true
      continue
    fi

    local _age=$((_now - _stamp))
    if [ "$_age" -le "$_ttl" ]; then
      log "TTL: $_bid claim is fresh (age=${_age}s <= TTL=${_ttl}s, stamp-based) — keeping."
      continue
    fi

    if [ -n "$_sling" ]; then
      local _sling_status
      # Sling task beads always live in GC_CITY (created by gc sling in HQ).
      _sling_status=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.status // "")' 2>/dev/null || echo "")
      if [ -n "$_sling_status" ] && [ "$_sling_status" != "closed" ] && [ "$_sling_status" != "done" ]; then
        warn "TTL: $_bid age=${_age}s > TTL but sling task $_sling is still '$_sling_status' — builder active, refusing to release."
        continue
      fi
    fi

    warn "Releasing stale pilot:dispatching claim on $_bid (age=${_age}s > TTL=${_ttl}s, stamp-based, db=$_db)."
    bd -C "$_db" label remove "$_bid" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$_db" update "$_bid" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true
  done
}

TTL_NOW_EPOCH=$(date +%s)
TTL_SECS=$((CLAIM_TTL_MINUTES * 60))

_ttl_recover_db "$GC_CITY" "$TTL_NOW_EPOCH" "$TTL_SECS"

_ttl_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
  | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
while IFS= read -r _ttl_rig; do
  [ -z "$_ttl_rig" ] || [ ! -d "$_ttl_rig" ] && continue
  _ttl_recover_db "$_ttl_rig" "$TTL_NOW_EPOCH" "$TTL_SECS"
done <<< "$_ttl_rig_paths"

# ── Step 1: Per-lane capacity check ──────────────────────────────────────────
# Count in-flight beads per lane by reading their lane:big / lane:small labels.
# Beads without a lane label (manually dispatched) count as small (conservative).

IN_FLIGHT_RAW_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l "story:in-flight" \
  2>/dev/null || echo "[]")

IN_FLIGHT_RAW_TOTAL=$(echo "$IN_FLIGHT_RAW_JSON" | jq 'length' 2>/dev/null || echo "0")

# ── Stale in-flight slot correction (ga-rk5va constraint c) ───────────────────
# Drop PHANTOM occupants — beads whose last state-transition (updated_at) is older
# than PILOT_STUCK_INFLIGHT_HOURS — from the slot count. A hung builder (the
# 16h-stuck-session bug) leaves a bead reading in-flight while no work happens; if
# it kept consuming a slot the lane would starve forever (slots sit empty = the
# exact "sub-max throughput" complaint). FAIL-SAFE: a bead with a missing or
# unparseable updated_at is KEPT as a live occupant (never free a slot we cannot
# evaluate → never over-dispatch). The stale bead is NOT re-dispatched here — it
# keeps story:in-flight and stays out of every candidate query — so freeing its
# slot only lets OTHER pending work flow; it can never double-dispatch that story.
# ── Live-session roster (ga-e5yw2) ────────────────────────────────────────────
# Fetch the session roster ONCE per sweep; reused below for the dead-worker
# in-flight correction AND the gate-reviewer readout (one gc call, not two).
_SESSIONS_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo '{}')
# Newline-delimited identifiers of every session that is NOT closed. A sling
# bead's assignee is a session_name, but index every name field so any form of
# the id resolves. `unique` keeps the membership grep cheap.
_LIVE_SESSION_IDS=$(echo "$_SESSIONS_JSON" \
  | jq -r '[.sessions[]? | select(.closed != true)
           | (.session_name, .name, .alias, .id, .agent_name)]
          | map(select(. != null and . != "")) | unique | .[]' 2>/dev/null || echo "")
# Gate the dead-worker check OFF unless the roster is a readable, NON-EMPTY array.
# An unreadable or empty live set is almost always a failed/racy `session list`
# read, not a town with genuinely zero sessions — disabling the check then is the
# fail-safe (keep every occupant = the harmless pre-fix over-count, never an
# over-dispatch). A healthy town always has ≥1 live session.
_DEADWORKER_OK=1
echo "$_SESSIONS_JSON" | jq -e '.sessions | type=="array"' >/dev/null 2>&1 || _DEADWORKER_OK=0
[ -n "$_LIVE_SESSION_IDS" ] || _DEADWORKER_OK=0

# _session_is_live <identifier> — exit 0 iff <identifier> is a non-closed session.
_session_is_live() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$_LIVE_SESSION_IDS" | grep -Fxq -- "$1"
}

# _inflight_drop_dead_workers — read a JSON array of in-flight beads on stdin and
# emit it with CONFIRMED dead-worker phantoms removed. A bead is a confirmed
# phantom iff it carries metadata pilot.sling_bead, that sling task has a
# non-empty assignee, and that assignee is NOT a live session. EVERY unresolved
# leg (no sling, no assignee, roster gated off) → KEEP — the same fail-safe the
# age filter uses: never free a slot we cannot positively evaluate. The dropped
# bead keeps story:in-flight and stays out of every candidate query, so freeing
# its slot can only admit OTHER pending work, never re-run the phantom. Falls
# back to the input on any jq error, so the worst case is the pre-fix count.
_inflight_drop_dead_workers() {
  local _arr _n _i _bead _sling _asg _kept
  _arr=$(cat)
  { [ "${PILOT_DEADWORKER_CHECK:-1}" = "1" ] && [ "${_DEADWORKER_OK:-0}" = "1" ]; } \
    || { printf '%s' "$_arr"; return 0; }
  _n=$(echo "$_arr" | jq 'length' 2>/dev/null || echo "0")
  [ "$_n" -gt 0 ] 2>/dev/null || { printf '%s' "$_arr"; return 0; }
  _kept=""
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _bead=$(echo "$_arr" | jq -c ".[$_i]" 2>/dev/null)
    _i=$((_i + 1))
    [ -n "$_bead" ] || continue
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    if [ -n "$_sling" ]; then
      _asg=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
      if [ -n "$_asg" ] && ! _session_is_live "$_asg"; then
        continue   # confirmed dead worker → free this slot
      fi
    fi
    _kept="${_kept}${_bead}"$'\n'
  done
  printf '%s' "$_kept" | jq -s '.' 2>/dev/null || printf '%s' "$_arr"
}

_NOW_EPOCH=$(date +%s)
_STUCK_CUTOFF=$(( _NOW_EPOCH - PILOT_STUCK_INFLIGHT_HOURS * 3600 ))
# Stage 1 — drop age-stale occupants (ga-rk5va constraint c).
IN_FLIGHT_AGE_JSON=$(echo "$IN_FLIGHT_RAW_JSON" | jq --argjson cutoff "$_STUCK_CUTOFF" '
  [ .[]
    | ( ((.updated_at // "") | if . == "" then null else (try fromdateiso8601 catch null) end) ) as $e
    | select($e == null or $e > $cutoff) ]' 2>/dev/null || echo "$IN_FLIGHT_RAW_JSON")
# Defensive: if the filter produced nothing usable, fall back to the raw set.
[ -z "$IN_FLIGHT_AGE_JSON" ] && IN_FLIGHT_AGE_JSON="$IN_FLIGHT_RAW_JSON"
_AGE_TOTAL=$(echo "$IN_FLIGHT_AGE_JSON" | jq 'length' 2>/dev/null || echo "0")
STALE_AGE=$(( IN_FLIGHT_RAW_TOTAL - _AGE_TOTAL ))
[ "$STALE_AGE" -lt 0 ] 2>/dev/null && STALE_AGE=0

# Stage 2 — drop dead-worker phantoms (ga-e5yw2).
IN_FLIGHT_JSON=$(echo "$IN_FLIGHT_AGE_JSON" | _inflight_drop_dead_workers)
[ -z "$IN_FLIGHT_JSON" ] && IN_FLIGHT_JSON="$IN_FLIGHT_AGE_JSON"

IN_FLIGHT_TOTAL=$(echo "$IN_FLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")
DEAD_WORKER=$(( _AGE_TOTAL - IN_FLIGHT_TOTAL ))
[ "$DEAD_WORKER" -lt 0 ] 2>/dev/null && DEAD_WORKER=0
STALE_INFLIGHT=$(( IN_FLIGHT_RAW_TOTAL - IN_FLIGHT_TOTAL ))
[ "$STALE_INFLIGHT" -lt 0 ] 2>/dev/null && STALE_INFLIGHT=0

if [ "$STALE_AGE" -gt 0 ] 2>/dev/null; then
  warn "Stale in-flight: ${STALE_AGE} bead(s) untouched > ${PILOT_STUCK_INFLIGHT_HOURS}h (hung builder?) — NOT counted as live occupants, freeing their slot(s) for pending work (ga-rk5va constraint c). Stale ids: $(echo "$IN_FLIGHT_RAW_JSON" | jq -r --argjson cutoff "$_STUCK_CUTOFF" '[.[] | ((.updated_at // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $e | select($e != null and $e <= $cutoff) | .id] | join(",")' 2>/dev/null || echo "?")"
fi

if [ "$DEAD_WORKER" -gt 0 ] 2>/dev/null; then
  warn "Dead-worker in-flight: ${DEAD_WORKER} bead(s) whose builder session is gone — NOT counted as live occupants, freeing their slot(s) for pending work (ga-e5yw2). Dead ids: $(jq -rn --argjson a "$IN_FLIGHT_AGE_JSON" --argjson b "$IN_FLIGHT_JSON" '(($a|map(.id)) - ($b|map(.id))) | join(",")' 2>/dev/null || echo "?")"
fi

IN_FLIGHT_BIG=$(echo "$IN_FLIGHT_JSON" | jq '[.[] | select((.labels // []) | contains(["lane:big"]))] | length' 2>/dev/null || echo "0")
IN_FLIGHT_SMALL=$((IN_FLIGHT_TOTAL - IN_FLIGHT_BIG))

log "In-flight: live=$IN_FLIGHT_TOTAL (raw=$IN_FLIGHT_RAW_TOTAL stale=$STALE_INFLIGHT age=$STALE_AGE dead=$DEAD_WORKER)  small=$IN_FLIGHT_SMALL/${MAX_SMALL}  big=$IN_FLIGHT_BIG/${MAX_BIG}"

# ── Per-builder busy set (ga-mtlm6) ───────────────────────────────────────────
# For a POOLED rig (multiple interchangeable crew), a builder is BUSY iff it
# currently holds a LIVE in-flight task — so it must be excluded from this sweep's
# selection (a second task to a busy single-identity crew is the wa-1eos branch-
# corruption hazard). Resolve each live in-flight bead's sling-task assignee (the
# builder identity the crew recorded via `bd assign`) from the SAME, already
# dead-worker-filtered IN_FLIGHT_JSON the slot math trusts. Best-effort + fail-
# open per leg: an in-flight bead with no sling task or no resolvable assignee
# simply omits that builder (the USED-this-sweep set + global lane cap still bound
# dispatch), mirroring the dead-worker check's never-over-free philosophy.
_compute_busy_builders() {
  local _n _i _bead _sling _asg _forms _f
  _n=$(echo "$IN_FLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")
  [ "${_n:-0}" -gt 0 ] 2>/dev/null || return 0
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _bead=$(echo "$IN_FLIGHT_JSON" | jq -c ".[$_i]" 2>/dev/null)
    _i=$((_i + 1))
    [ -n "$_bead" ] || continue
    _sling=$(echo "$_bead" | jq -r '.metadata["pilot.sling_bead"] // ""' 2>/dev/null || echo "")
    [ -n "$_sling" ] || continue
    _asg=$(bd -C "$GC_CITY" show "$_sling" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.assignee // "")' 2>/dev/null || echo "")
    [ -n "$_asg" ] || continue
    # Normalize to ALL of that session's identifiers (session_name/name/alias/id/
    # agent_name). A crew claims its sling task with its GC_SESSION_NAME (verified
    # live: 'digo-wa-gawispcze4o4'), but the pool lists the alias ('digo-wa'); add
    # every form so pick_pool_builder's alias match still excludes the busy crew.
    # Fall back to the raw assignee when the roster can't resolve it (still
    # excludes by that exact string — never worse than the un-normalized set).
    _forms=$(echo "$_SESSIONS_JSON" | jq -r --arg a "$_asg" '
      [ .sessions[]?
        | select((.session_name==$a) or (.name==$a) or (.alias==$a) or (.id==$a) or (.agent_name==$a))
        | (.session_name,.name,.alias,.id,.agent_name) ]
      | map(select(. != null and . != "")) | unique | .[]' 2>/dev/null)
    [ -n "$_forms" ] || _forms="$_asg"
    for _f in $_forms; do
      case " $PILOT_BUSY_BUILDERS " in
        *" $_f "*) : ;;
        *) PILOT_BUSY_BUILDERS="${PILOT_BUSY_BUILDERS:+$PILOT_BUSY_BUILDERS }$_f" ;;
      esac
    done
  done
}
_compute_busy_builders
[ -n "$PILOT_BUSY_BUILDERS" ] && log "Busy builders (live in-flight): $PILOT_BUSY_BUILDERS"

SMALL_SLOTS=$((MAX_SMALL - IN_FLIGHT_SMALL))
BIG_SLOTS=$((MAX_BIG - IN_FLIGHT_BIG))

[ "$SMALL_SLOTS" -lt "0" ] && SMALL_SLOTS=0
[ "$BIG_SLOTS"   -lt "0" ] && BIG_SLOTS=0

log "Available slots: small=$SMALL_SLOTS  big=$BIG_SLOTS"

# ── ga-8c1 AC5: gate reviewer slot readout (observability) ───────────────────
# Surface free gate-reviewer slots every sweep so the log shows the WHOLE
# pipeline's capacity (builders + reviewers), not just the builder lanes. Read
# only — counts live gate-reviewer sessions exactly as quality-gate-dispatcher
# does (.template=="gate-reviewer"). Reuses the roster fetched once above for the
# dead-worker correction (ga-e5yw2) — no second `session list` call. Guarded for
# set -euo pipefail.
REVIEWERS_ACTIVE=$(echo "$_SESSIONS_JSON" \
  | jq '[.sessions[]? | select(.template=="gate-reviewer")] | length' 2>/dev/null || echo "0")
[ -z "$REVIEWERS_ACTIVE" ] && REVIEWERS_ACTIVE=0
REVIEWER_SLOTS=$((MAX_REVIEWERS - REVIEWERS_ACTIVE))
[ "$REVIEWER_SLOTS" -lt "0" ] && REVIEWER_SLOTS=0
log "Gate reviewers: active=${REVIEWERS_ACTIVE}/${MAX_REVIEWERS}  free=${REVIEWER_SLOTS}"

if [ "$SMALL_SLOTS" -eq "0" ] && [ "$BIG_SLOTS" -eq "0" ]; then
  # ga-8c1 AC5: even when backing off, surface the dispatch-queue depth so every
  # sweep's log reports what's waiting (cheap count — no full tier scan).
  WAITING_APPROVED=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    --exclude-label "story:in-flight" \
    --exclude-label "story:done" \
    --exclude-label "pilot:dispatched" \
    -n 0 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
  log "Dispatch queue: ${WAITING_APPROVED} story:approved waiting (HQ; both lanes full — none can dispatch this sweep)."
  log "Both lanes full (small=${IN_FLIGHT_SMALL}/${MAX_SMALL}, big=${IN_FLIGHT_BIG}/${MAX_BIG}). Pilot backing off."
  exit 0
fi

# ── Step 2: Tier 1 — Find open bugs + tech-debt beads in HQ DB ───────────────
# Tier 1 = type:bug OR label:tech-debt, NOT in-flight/done/dispatching, no assignee.
# Bugs do NOT require story:approved — they are always dispatchable when open.
# tech-debt label: use "tech-debt" as canonical label for debt items.
#
# Helper: filter out self-bead + already-assigned from a JSON array.
_filter_candidates() {
  jq --arg self "$SELF_BEAD_ID" \
    '[.[] | select(.id != $self and (.assignee == null or .assignee == ""))]' \
    2>/dev/null || echo "[]"
}

# _filter_unblocked <db_dir>   (reads candidate JSON array from stdin)
# Drops candidates that are currently BLOCKED by unresolved (open) dependencies
# in <db_dir>, using bd's blocker-aware `bd blocked` set. This is the fix for
# bug ga-5ew: the Pilot must NOT dispatch a story whose hard dependency is not
# yet merged/closed (it did — dispatched ga-30v while dep ga-d81 was unmerged).
# A bead is "blocked" iff it has a dependency that is not yet closed; a dep that
# is already closed does NOT block (so we cannot simply filter on dependency_count).
#
# FAIL-OPEN: if `bd blocked` errors, returns nothing, or the jq filter fails,
# candidates pass through UNCHANGED — never worse than the pre-fix behavior.
# Diagnostics go to stderr (which the top-level `exec ... 2>&1` routes to the
# log) so stdout stays pure JSON for the caller's command-substitution capture.
_filter_unblocked() {
  local db_dir="$1"
  local arr blocked_ids blocked_json before after filtered
  arr=$(cat)

  blocked_ids=$(bd -C "$db_dir" blocked --json 2>/dev/null \
    | jq -r '(.[]?.id) // empty' 2>/dev/null || echo "")
  # Nothing blocked in this DB (or probe failed) → pass through unchanged.
  if [ -z "$blocked_ids" ]; then
    printf '%s' "$arr"
    return 0
  fi

  blocked_json=$(printf '%s\n' "$blocked_ids" \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")

  before=$(printf '%s' "$arr" | jq 'length' 2>/dev/null || echo "0")
  filtered=$(printf '%s' "$arr" | jq --argjson blk "$blocked_json" \
    '[.[] | select((.id as $i | $blk | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  after=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo "0")

  if [ "$before" != "$after" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: excluded $((before - after)) blocked candidate(s) in $db_dir (unresolved deps — ga-5ew fix)" >&2
  fi
  printf '%s' "$filtered"
}

# _filter_explicit_deps <db_dir>   (reads candidate JSON array from stdin)
# Drops candidates that declare an EXPLICIT, still-open dependency via the
# `story.depends_on_beads` metadata field — a space/comma/newline-separated list
# of bead IDs that this bead must be built ON TOP OF.
#
# This is the fix for bug ga-do8jj: the Pilot dispatched ga-2e605 BEFORE its
# real dependency ga-e72kf (the canonical painel base) had landed. The
# dependency was real, but it lived only in PROSE ("Construir SOBRE a base
# canônica ga-e72kf …" in story.dependencias) and was never encoded as a formal
# `bd` blocks-edge — so `bd blocked` (and thus _filter_unblocked above) could
# not see it, and the dependent story slipped through. This filter is the
# structured, zero-false-positive realization of the bug's fix-option (b),
# "convenção de dep explícita": a dedicated field the dispatcher enforces.
#
# CONTRACT — deliberately narrow to avoid false-positive deadlocks:
#   * ONLY bead IDs in the dedicated `story.depends_on_beads` field are honored.
#     We do NOT parse the free-form `story.dependencias` prose, which mixes hard
#     deps with coordination/negative references ("coordenar com ga-gzf5a",
#     "NÃO da wa-rlzo") that must NOT block dispatch.
#   * A referenced dep is SATISFIED iff it is closed. Any non-closed dep holds
#     the candidate back for THIS sweep only — AUTO-CLEARING: once the dep
#     closes, the next sweep dispatches. No manual un-hold, no stale state.
#   * Self-references are ignored (a bead never blocks itself).
#
# FAIL-OPEN: any bd error / unresolvable dep status passes the candidate through
# UNCHANGED — never stricter than the pre-fix behavior, so a transient Dolt
# hiccup or a typo'd dep id can never wedge the pipeline. Diagnostics → stderr
# (routed to the log by the top-level `exec … 2>&1`) so stdout stays pure JSON.
_filter_explicit_deps() {
  local db_dir="$1"
  local arr
  arr=$(cat)
  [ -z "$arr" ] && { printf '[]'; return 0; }

  # Fast path: no candidate declares explicit deps → pass through untouched
  # (zero extra bd calls on the common case — Scenarios 1/2 and normal sweeps).
  if ! printf '%s' "$arr" \
      | jq -e 'any(.[]?; (.metadata["story.depends_on_beads"] // "") != "")' \
        >/dev/null 2>&1; then
    printf '%s' "$arr"
    return 0
  fi

  local held_ids="" bead bid deps dep dep_status
  while IFS= read -r bead; do
    [ -z "$bead" ] && continue
    bid=$(printf '%s' "$bead" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$bid" ] && continue
    deps=$(printf '%s' "$bead" \
      | jq -r '.metadata["story.depends_on_beads"] // ""' 2>/dev/null || echo "")
    deps=$(printf '%s' "$deps" | tr ',\n' '  ')
    for dep in $deps; do
      dep=$(printf '%s' "$dep" | tr -d '[:space:]')
      [ -z "$dep" ] && continue
      [ "$dep" = "$bid" ] && continue
      dep_status=$(bd -C "$db_dir" show "$dep" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | .status // ""' \
          2>/dev/null || echo "")
      # Non-closed, resolvable dep → HOLD. Empty status (lookup failed) →
      # fail-open: do not hold on a dep we cannot resolve.
      if [ -n "$dep_status" ] && [ "$dep_status" != "closed" ]; then
        held_ids="$held_ids $bid"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: holding $bid — explicit dep $dep is '$dep_status' (not closed) [story.depends_on_beads — ga-do8jj fix]" >&2
        break
      fi
    done
  done < <(printf '%s' "$arr" | jq -c '.[]?' 2>/dev/null)

  if [ -z "$held_ids" ]; then
    printf '%s' "$arr"
    return 0
  fi

  local held_json filtered
  held_json=$(printf '%s\n' $held_ids \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")
  filtered=$(printf '%s' "$arr" | jq --argjson held "$held_json" \
    '[.[] | select((.id as $i | $held | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  printf '%s' "$filtered"
}

BUGS_JSON=$(bd -C "$GC_CITY" list --json \
  -t bug \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "gate:passed" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  --exclude-label "needs:engine-window" \
  --exclude-label "pilot:dispatched" \
  -n 0 \
  2>/dev/null || echo "[]")
BUGS_JSON=$(echo "$BUGS_JSON" | _filter_candidates)

DEBT_JSON=$(bd -C "$GC_CITY" list --json \
  -l "tech-debt" \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "gate:passed" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  --exclude-label "needs:engine-window" \
  --exclude-label "pilot:dispatched" \
  -n 0 \
  2>/dev/null || echo "[]")
DEBT_JSON=$(echo "$DEBT_JSON" | _filter_candidates)

# Merge bugs + debt, deduplicate by id
TIER1_JSON=$(echo "$BUGS_JSON $DEBT_JSON" \
  | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

# Drop candidates blocked by unresolved deps (ga-5ew). Filtering BEFORE the count
# means an all-blocked Tier 1 correctly falls through to Tier 2 features.
TIER1_JSON=$(echo "$TIER1_JSON" | _filter_unblocked "$GC_CITY")
# Also drop candidates with an open EXPLICIT dep (ga-do8jj). Same fall-through
# semantics: an all-held Tier 1 correctly cascades to Tier 2.
TIER1_JSON=$(echo "$TIER1_JSON" | _filter_explicit_deps "$GC_CITY")

TIER1_COUNT=$(echo "$TIER1_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Tier 1 (bugs + tech-debt): $TIER1_COUNT open candidate(s) in HQ DB"

ALL_CANDIDATES_JSON="[]"
ALL_CANDIDATES_TIER=""

if [ "$TIER1_COUNT" -gt "0" ]; then
  ALL_CANDIDATES_JSON="$TIER1_JSON"
  ALL_CANDIDATES_TIER="bug"
  log "Tier 1 has candidates — dispatching bugs/debt FIRST (features suppressed)."
fi

# ── Step 2b: Tier 2 — story:approved feature stories (only if Tier 1 empty) ──
# Dispatchable = story:approved AND NOT story:in-flight AND NOT story:done
#                AND NOT gate:passed (merged, delivery in progress — ga-3h8l)
#                AND NOT pilot:dispatching (claim in progress)

if [ "$TIER1_COUNT" -eq "0" ]; then
  log "Tier 1 empty — falling back to Tier 2 (story:approved features) ..."

  TIER2_JSON=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    --exclude-label "story:in-flight" \
    --exclude-label "story:done" \
    --exclude-label "gate:passed" \
    --exclude-label "pilot:dispatching" \
    --exclude-label "gate:needs-human" \
    --exclude-label "needs:engine-window" \
    --exclude-label "pilot:dispatched" \
    -n 0 \
    2>/dev/null || echo "[]")
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_candidates)
  # Drop features blocked by unresolved deps (ga-5ew) or an open explicit dep (ga-do8jj).
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_unblocked "$GC_CITY")
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_explicit_deps "$GC_CITY")

  TIER2_COUNT=$(echo "$TIER2_JSON" | jq 'length' 2>/dev/null || echo "0")
  log "Tier 2 (story:approved features): $TIER2_COUNT candidate(s) in HQ DB"

  if [ "$TIER2_COUNT" -gt "0" ]; then
    ALL_CANDIDATES_JSON="$TIER2_JSON"
    ALL_CANDIDATES_TIER="feature"
  fi
fi

# ── Step 2c: Fallback — scan rig DBs if HQ returned nothing ──────────────────
# Per convention all story beads live in HQ, but check rig DBs as a fallback.
# Only reached when BOTH tiers returned empty from HQ.

if [ -z "$ALL_CANDIDATES_TIER" ]; then
  log "HQ returned no candidates (both tiers) — scanning rig DBs as fallback ..."
  RIG_PATHS=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")

  ALL_RIG_TIER1="[]"
  ALL_RIG_TIER2="[]"
  while IFS= read -r rig_path; do
    [ -z "$rig_path" ] || [ ! -d "$rig_path" ] && continue

    # Tier 1: bugs from rig DB
    RIG_BUGS=$(bd -C "$rig_path" list --json -t bug \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      -n 0 2>/dev/null || echo "[]")
    RIG_BUGS=$(echo "$RIG_BUGS" | _filter_candidates | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_BUGS" | jq -s 'add // []' 2>/dev/null || echo "[]")

    # Tier 1: tech-debt from rig DB
    RIG_DEBT=$(bd -C "$rig_path" list --json -l "tech-debt" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      -n 0 2>/dev/null || echo "[]")
    RIG_DEBT=$(echo "$RIG_DEBT" | _filter_candidates | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_DEBT" | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

    # Tier 2: story:approved features from rig DB
    RIG_FEATURES=$(bd -C "$rig_path" list --json -l "story:approved" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      --exclude-label "needs:engine-window" \
      --exclude-label "pilot:dispatched" \
      -n 0 2>/dev/null || echo "[]")
    RIG_FEATURES=$(echo "$RIG_FEATURES" | _filter_candidates | _filter_unblocked "$rig_path" | _filter_explicit_deps "$rig_path")
    ALL_RIG_TIER2=$(echo "$ALL_RIG_TIER2 $RIG_FEATURES" | jq -s 'add // []' 2>/dev/null || echo "[]")
  done <<< "$RIG_PATHS"

  RIG_TIER1_COUNT=$(echo "$ALL_RIG_TIER1" | jq 'length' 2>/dev/null || echo "0")
  RIG_TIER2_COUNT=$(echo "$ALL_RIG_TIER2" | jq 'length' 2>/dev/null || echo "0")

  if [ "$RIG_TIER1_COUNT" -gt "0" ]; then
    log "Rig DBs: $RIG_TIER1_COUNT Tier 1 (bug/tech-debt) candidate(s) — using Tier 1."
    ALL_CANDIDATES_JSON="$ALL_RIG_TIER1"
    ALL_CANDIDATES_TIER="bug"
  elif [ "$RIG_TIER2_COUNT" -gt "0" ]; then
    log "Rig DBs: $RIG_TIER2_COUNT Tier 2 (feature) candidate(s) — using Tier 2."
    ALL_CANDIDATES_JSON="$ALL_RIG_TIER2"
    ALL_CANDIDATES_TIER="feature"
  fi
fi

ALL_CANDIDATES_COUNT=$(echo "$ALL_CANDIDATES_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$ALL_CANDIDATES_COUNT" = "0" ]; then
  log "No dispatchable candidates (Tier 1 or Tier 2). Exiting."
  exit 0
fi

log "Dispatch tier: $ALL_CANDIDATES_TIER (${ALL_CANDIDATES_COUNT} candidate(s))"

# ── Step 3: Split candidates by lane, pick one per available lane ─────────────
# For each candidate classify its lane. Build two sorted candidate lists.
# Pick highest priority (P0>P1>P2..., tie-break oldest) from each.
# Only dispatch into a lane if it has a free slot.

SMALL_CANDIDATES="[]"
BIG_CANDIDATES="[]"

while IFS= read -r bead; do
  lane=$(classify_lane "$bead")
  if [ "$lane" = "big" ]; then
    BIG_CANDIDATES=$(echo "$BIG_CANDIDATES" | jq --argjson b "$bead" '. + [$b]' 2>/dev/null || echo "$BIG_CANDIDATES")
  else
    SMALL_CANDIDATES=$(echo "$SMALL_CANDIDATES" | jq --argjson b "$bead" '. + [$b]' 2>/dev/null || echo "$SMALL_CANDIDATES")
  fi
done < <(echo "$ALL_CANDIDATES_JSON" | jq -c '.[]')

SMALL_COUNT=$(echo "$SMALL_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
BIG_COUNT=$(echo "$BIG_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
log "Candidates split: small=${SMALL_COUNT}  big=${BIG_COUNT}"

# Sort each lane by priority asc, then created_at asc.
_top_candidate() {
  local arr="$1"
  echo "$arr" | jq 'sort_by([(.priority // 99), .created_at]) | .[0]' 2>/dev/null
}

SMALL_PICK="null"
BIG_PICK="null"

[ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ] && \
  SMALL_PICK=$(_top_candidate "$SMALL_CANDIDATES")
[ "$BIG_SLOTS"   -gt "0" ] && [ "$BIG_COUNT"   -gt "0" ] && \
  BIG_PICK=$(_top_candidate "$BIG_CANDIDATES")

log "Lane picks — small: $(echo "$SMALL_PICK" | jq -r '.id // "none"')  big: $(echo "$BIG_PICK" | jq -r '.id // "none"')"

# ── ga-8c1 AC5: dispatch-queue preview ───────────────────────────────────────
# Log the next stories queued for dispatch (priority order, top 3 per lane) so
# every sweep makes the backlog visible — not just the single bead picked now.
# Read-only formatting of already-gathered candidates. Guarded for pipefail.
_queue_preview() {
  echo "$1" | jq -r --arg lane "$2" \
    'sort_by([(.priority // 99), (.created_at // "")]) | .[:3][]
       | "  [\($lane)] \(.id) P\(.priority // "?") — \(.title)"' 2>/dev/null || true
}
_QUEUE_LINES=$( { _queue_preview "$SMALL_CANDIDATES" small; _queue_preview "$BIG_CANDIDATES" big; } )
if [ -n "$_QUEUE_LINES" ]; then
  log "Dispatch queue (next up, priority order):"
  while IFS= read -r _q; do [ -n "$_q" ] && log "$_q"; done <<< "$_QUEUE_LINES"
fi

# ── Dispatch helper ───────────────────────────────────────────────────────────
# dispatch_one <story_json> <lane> <dispatch_tier>
# Handles: claim, verify, builder routing, sling, bead transitions, logging, ntfy.
dispatch_one() {
  local STORY="$1"
  local LANE="$2"
  local DISPATCH_TIER="$3"

  local STORY_ID STORY_TITLE STORY_PRIORITY STORY_LABELS STORY_RIG STORY_BEAD_CITY
  local STORY_ESTRELA STORY_CRITERIA STORY_EQUILIBRIOS
  STORY_ID=$(echo "$STORY" | jq -r '.id')
  STORY_TITLE=$(echo "$STORY" | jq -r '.title // .description // "untitled"' | head -c 100)
  STORY_PRIORITY=$(echo "$STORY" | jq -r '.priority // 99')
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')
  STORY_RIG=$(echo "$STORY" | jq -r '.metadata["story.rig"] // ""')
  STORY_ESTRELA=$(echo "$STORY" | jq -r '.metadata["story.estrela_guia"] // ""' | head -c 200)
  STORY_CRITERIA=$(echo "$STORY" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""')
  STORY_EQUILIBRIOS=$(echo "$STORY" | jq -r '.metadata["story.equilibrios"] // ""')

  # ── gt-pm55p: Early rig resolution + STORY_BEAD_CITY ────────────────────────
  # Infer rig from bead ID prefix if not set in metadata, then derive
  # STORY_BEAD_CITY — the rig's Dolt DB directory for ALL bd ops on $STORY_ID.
  #
  # WHY: bd -C "$GC_CITY" silently no-ops for cross-rig beads (wa-*, ps-*, etc.)
  # because those beads live in their rig's own Dolt DB, not in HQ. When all
  # label/metadata writes use GC_CITY, story:in-flight and pilot:dispatched are
  # NEVER written on cross-rig beads — so the bead stays re-dispatchable on
  # every sweep → dispatcher keeps re-assigning it in a loop (the dc-io31
  # incident: deacon/builder kept receiving the same slung work over and over).
  #
  # Must happen BEFORE the atomic claim so all claim/verify/transition ops route
  # to the correct DB. STORY_BEAD_CITY == GC_CITY for ga-* (HQ) beads; only
  # cross-rig beads (wa-*, ps-*, etc.) get a different path.
  if [ -z "$STORY_RIG" ] || [ "$STORY_RIG" = "null" ]; then
    local _early_prefix
    _early_prefix=$(echo "$STORY_ID" | cut -d'-' -f1)
    case "$_early_prefix" in
      ga) STORY_RIG="gascity" ;;
      ps) STORY_RIG="property_scrapers" ;;
      wa) STORY_RIG="whatsapp_automation" ;;
      gt) STORY_RIG="gastown" ;;
      lx) STORY_RIG="lexbh" ;;
      ma) STORY_RIG="marketing" ;;
      *)  STORY_RIG="gascity" ;;
    esac
    log "  story.rig inferred from bead prefix '$_early_prefix': $STORY_RIG"
  fi
  STORY_BEAD_CITY=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r --arg name "$STORY_RIG" '.rigs[] | select(.name == $name) | .path' \
    2>/dev/null | head -1 || echo "")
  if [ -z "$STORY_BEAD_CITY" ] || [ ! -d "$STORY_BEAD_CITY" ]; then
    STORY_BEAD_CITY="$GC_CITY"
  fi
  log "  rig=$STORY_RIG  bead_city=$STORY_BEAD_CITY"

  # ── ga-jb4l: gate re-dispatch — surface reviewer feedback for needs-fix beads ──
  # A bead labeled gate:needs-fix previously FAILED the quality gate. The gate
  # attached the FAILing reviewers' reasons to it as a "GATE-FEEDBACK" comment.
  # Pull the latest such comment and the attempt counter so the builder prompt
  # tells the re-dispatched builder to fix THE SPECIFIC issues (not redo the work).
  local STORY_GATE_FEEDBACK="" STORY_FIX_ATTEMPT="" GATE_FIX_SECTION=""
  if echo "$STORY_LABELS" | grep -q "gate:needs-fix"; then
    STORY_FIX_ATTEMPT=$(echo "$STORY_LABELS" | tr ',' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
    STORY_GATE_FEEDBACK=$(bd -C "$STORY_BEAD_CITY" comments "$STORY_ID" --json 2>/dev/null \
      | jq -r '[ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""' \
      2>/dev/null || echo "")
    log "  $STORY_ID is gate:needs-fix (attempt=${STORY_FIX_ATTEMPT:-?}) — injecting reviewer feedback (${#STORY_GATE_FEEDBACK} chars)."
    if [ -n "$STORY_GATE_FEEDBACK" ]; then
      GATE_FIX_SECTION=$(cat <<FIXSEC

## ⚠️ GATE RE-DISPATCH — fix THESE specific issues (fix attempt ${STORY_FIX_ATTEMPT:-?}/3)
This bead previously FAILED the autonomous quality gate. You are being re-dispatched
to fix the EXACT blocking issues the reviewers found below — do NOT redo unrelated
work. After fixing, run /gate-done to re-gate. If you genuinely cannot resolve these,
explain why in a bead comment; after 3 failed attempts the machine escalates to a human.

$STORY_GATE_FEEDBACK
FIXSEC
)
    fi
  fi

  log "Selected $DISPATCH_TIER [$LANE] $STORY_ID (priority=$STORY_PRIORITY): $STORY_TITLE"
  log "  labels=$STORY_LABELS  lane=$LANE  tier=$DISPATCH_TIER"

  # ── Atomic claim ────────────────────────────────────────────────────────────
  log "Attempting atomic claim on $STORY_ID (lane=$LANE tier=$DISPATCH_TIER) ..."

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD: stamp pilot.dispatching_at then bd label add $STORY_ID pilot:dispatching"
  else
    # ga-2azzj fix 3: write the claim-time stamp BEFORE the label, so a
    # pilot:dispatching label can never exist without a pilot.dispatching_at
    # stamp for TTL recovery to measure age from (Defect A). updated_at is NOT a
    # reliable claim clock — bd label add does not bump it.
    local CLAIM_EPOCH
    CLAIM_EPOCH=$(date +%s)
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.dispatching_at=$CLAIM_EPOCH" -q 2>/dev/null || true
    bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || {
      warn "Could not add pilot:dispatching to $STORY_ID (race condition or bd error). Skipping."
      return 1
    }
  fi

  # Verify we won the race — and apply ga-zzrts eligibility guards.
  if [ "$DRY_RUN" != "1" ]; then
    local VERIFY_JSON VERIFY_LABELS VERIFY_STATUS VERIFY_SOURCEBEAD
    VERIFY_JSON=$(bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null || echo "[]")
    VERIFY_LABELS=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' \
      2>/dev/null || echo "")
    VERIFY_STATUS=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.status // "")' \
      2>/dev/null || echo "")
    VERIFY_SOURCEBEAD=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.metadata["source-bead"] // .metadata["source_bead"] // "")' \
      2>/dev/null || echo "")

    if echo "$VERIFY_LABELS" | grep -q "story:in-flight"; then
      log "Story $STORY_ID is already in-flight (race condition). Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    if echo "$VERIFY_LABELS" | grep -q "story:done"; then
      log "Story $STORY_ID is already done. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix b) gate:needs-human — bead deliberately parked for human/engine path.
    # The bd list queries already exclude this label; this guard catches the race where
    # gate:needs-human is added BETWEEN the query-time snapshot and claim acquisition.
    if echo "$VERIFY_LABELS" | grep -q "gate:needs-human"; then
      warn "ga-zzrts(b): $STORY_ID has gate:needs-human at dispatch time — race or stale query. Releasing claim and skipping."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix c) Duplicate-in-flight guard: already dispatched in a prior sweep.
    # bd list excludes pilot:dispatched; this is the last-resort guard for the case where
    # story:in-flight was stripped (crash/race) but pilot:dispatched survived — without
    # this check the Pilot would emit a second sling for the same source bead (ga-2aigc).
    if echo "$VERIFY_LABELS" | grep -q "pilot:dispatched"; then
      warn "ga-zzrts(c): $STORY_ID already has pilot:dispatched — prior-sweep duplicate guard. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix a) Closed-bead guard: STATUS is closed but story:done label absent.
    # Delivery inconsistency can leave a bead closed without the label; never dispatch it.
    if [ "$VERIFY_STATUS" = "closed" ]; then
      warn "ga-zzrts(a): $STORY_ID is STATUS:closed without story:done label. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    # (ga-zzrts fix a) Orphan-sling guard: if this bead carries a source-bead metadata
    # reference (i.e. it is a sling/task bead, not a source story), and the referenced
    # source bead is already closed, skip — the underlying work is done. This is the
    # "closed-source sling" class of flood: dogs re-claim sling beads whose source was
    # closed without the sling being retired.
    if [ -n "$VERIFY_SOURCEBEAD" ] && [ "$VERIFY_SOURCEBEAD" != "null" ]; then
      local SOURCE_BEAD_STATUS
      SOURCE_BEAD_STATUS=$(bd -C "$STORY_BEAD_CITY" show "$VERIFY_SOURCEBEAD" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.status // "")' \
        2>/dev/null || echo "")
      if [ "$SOURCE_BEAD_STATUS" = "closed" ]; then
        warn "ga-zzrts(a): $STORY_ID is a sling/task whose source $VERIFY_SOURCEBEAD is STATUS:closed — orphan sling. Releasing claim."
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
        return 1
      fi
    fi
  fi

  log "Claim acquired on $STORY_ID."

  # ── Determine builder target ─────────────────────────────────────────────────
  # STORY_RIG and STORY_BEAD_CITY already resolved above (gt-pm55p early rig fix).
  local BUILDER_TARGET _POOL _POOL_N
  _POOL=$(rig_to_builders "$STORY_RIG")
  _POOL_N=$(echo "$_POOL" | wc -w | tr -d ' ')

  if [ "${_POOL_N:-1}" -gt 1 ]; then
    # ── ga-mtlm6: pooled rig — distribute across idle crew, deliver to existing ──
    # A rig with several interchangeable single-identity crew (WA: digo/mila/
    # oracle/peter/thies-wa). Pick a crew that is NEITHER busy with live in-flight
    # work (PILOT_BUSY_BUILDERS) NOR already loaded this sweep (PILOT_USED_BUILDERS),
    # so M bugs fan out to M crew instead of all piling on digo-wa. An idle crew
    # that already has a live session RECEIVES the task — `gc sling` routes the
    # task bead to it and `--nudge`/session nudge wakes the existing session — it
    # is NOT deferred. (The pre-ga-mtlm6 path routed every WA bug to one pinned
    # builder, then the wa-1eos "active session → defer" mutex deferred it forever
    # while 4 idle crew sat starved.) When every crew is busy/used → defer (release
    # the claim, retry next sweep): correct backpressure, never a duplicate spawn.
    BUILDER_TARGET=$(pick_pool_builder "$STORY_RIG" || echo "")
    if [ -z "$BUILDER_TARGET" ]; then
      log "POOL($STORY_RIG): all crew busy/used this sweep (pool=[$_POOL] busy=[${PILOT_BUSY_BUILDERS:-none}] used=[${PILOT_USED_BUILDERS:-none}]) — deferring $STORY_ID to next sweep. Releasing claim."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    mark_pool_builder "$BUILDER_TARGET"
    log "  Builder target: $BUILDER_TARGET (rig=$STORY_RIG bead_city=$STORY_BEAD_CITY lane=$LANE) [pool: $_POOL]"
  else
    # ── Single-member rig (gastown.dog pool, or a lone single-identity crew) ─────
    BUILDER_TARGET="$_POOL"
    log "  Builder target: $BUILDER_TARGET (rig=$STORY_RIG bead_city=$STORY_BEAD_CITY lane=$LANE)"

    # ── wa-1eos: per-builder mutex (single-identity, single-member rigs only) ────
    # A lone single-identity builder (e.g. batista-ps) must have AT MOST ONE live
    # session. Dispatching a 2nd bead to a busy one makes `gc sling` spawn a
    # duplicate (batista-ps → batista-ps-1) that works the SAME crew branch —
    # branch corruption. If already live, defer (release the claim so it stays
    # dispatchable). gastown.dog is a shared pool (multiple instances by design) —
    # exempt. Pooled rigs (WA) are handled above by the busy-set, not this mutex.
    # Fail-safe: any error → count 0 → dispatch proceeds (never halts on a `gc` hiccup).
    if [ "$DRY_RUN" != "1" ] && [ "$BUILDER_TARGET" != "gastown.dog" ]; then
      local LIVE_BUILDER_SESSIONS
      LIVE_BUILDER_SESSIONS=$(gc --city "$GC_CITY" session list 2>/dev/null \
        | awk -v t="$BUILDER_TARGET" '$2==t && $3=="active"' | wc -l | tr -d ' ')
      if [ "${LIVE_BUILDER_SESSIONS:-0}" -ge 1 ] 2>/dev/null; then
        log "MUTEX(wa-1eos): builder $BUILDER_TARGET already has ${LIVE_BUILDER_SESSIONS} live session(s) — deferring $STORY_ID to next sweep (no duplicate spawn). Releasing claim."
        bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
        return 1
      fi
    fi
  fi

  # ── Build task prompt ────────────────────────────────────────────────────────
  local DISPATCH_TASK
  if [ "$DISPATCH_TIER" = "bug" ]; then
    DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — Bug/tech-debt assigned for autonomous fix

Bead ID: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: BUG / TECH-DEBT (Tier 1 — dispatched BEFORE new features)
Lane: $LANE
Rig: $STORY_RIG
City: $GC_CITY
Bead DB: $STORY_BEAD_CITY

## Your job
Fix this bug or tech-debt item completely. Do NOT wait for a human.
"Só depois do sistema perfeito é que a gente faz novas features." — system quality first.
$GATE_FIX_SECTION

## Description / Acceptance Criteria
$STORY_CRITERIA

## Additional Context
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your fix is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just fix, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → bead closed.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.

## Steps
1. Read the full bead: bd -C "$STORY_BEAD_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Diagnose root cause, implement fix on a branch (name: fix/$STORY_ID).
4. Add a regression test if applicable.
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$STORY_BEAD_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$STORY_BEAD_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  else
    DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — Story assigned for autonomous build

Story ID: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: FEATURE (Tier 2 — dispatched only because no open bugs/tech-debt)
Lane: $LANE
Rig: $STORY_RIG
City: $GC_CITY
Bead DB: $STORY_BEAD_CITY

## Your job
Build this story from acceptance criteria to /gate-done. Do NOT wait for a human.
$GATE_FIX_SECTION

## Acceptance Criteria
$STORY_CRITERIA

## Estrela Guia (north star)
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your implementation is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just build, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → story:done.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.

## Steps
1. Read the full story bead: bd -C "$STORY_BEAD_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Implement the story on a feature branch (name: feat/$STORY_ID or story/$STORY_ID).
4. Add a story-specific prod test at the required path (see delivery-runbooks.toml).
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$STORY_BEAD_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$STORY_BEAD_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  fi

  log "  Task prompt built (${#DISPATCH_TASK} chars)"

  # ── Dispatch via gc sling ────────────────────────────────────────────────────
  local DISPATCH_EPOCH DISPATCH_RESULT SLING_BEAD_ID NOW
  DISPATCH_EPOCH=$(date +%s)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$DRY_RUN" = "1" ]; then
    local SLING_TITLE_DRY
    SLING_TITLE_DRY="$([ "$DISPATCH_TIER" = "bug" ] && echo "fix bug" || echo "build story") $STORY_ID: $STORY_TITLE"
    log "DRY_RUN=1 — WOULD DISPATCH (tier=$DISPATCH_TIER lane=$LANE):"
    log "  gc --city $GC_CITY sling $BUILDER_TARGET <task_bead> --nudge"
    log "  Task title: '$SLING_TITLE_DRY'"
    log "  Rig: $STORY_RIG → builder: $BUILDER_TARGET"
    log "  WOULD: bd label add $STORY_ID lane:${LANE}"
    log "  WOULD: bd label add $STORY_ID story:in-flight (verify durable BEFORE releasing claim)"
    log "  WOULD: bd label remove $STORY_ID pilot:dispatching"
    log "  WOULD: bd label add $STORY_ID pilot:dispatched"
    log "  WOULD: bd comment $STORY_ID 'Pilot dispatched builder $BUILDER_TARGET at $NOW'"
    SLING_BEAD_ID="DRY_RUN_NO_SLING"
    DISPATCH_RESULT="dry_run"
  else
    local SLING_TITLE SLING_OUT
    if [ "$DISPATCH_TIER" = "bug" ]; then
      SLING_TITLE="fix bug $STORY_ID: $STORY_TITLE"
    else
      SLING_TITLE="build story $STORY_ID: $STORY_TITLE"
    fi

    # ── ga-eu8vr: resilient sling with correct failure attribution ──────────────
    # The live gc binary (gc-patched-connfix) emits a CONSTANT benign warning on
    # stderr for EVERY invocation:
    #   WARN native_store_unavailable gate=version_compat reason="bd/beads version
    #        compatibility could not be confirmed"
    # It is present on success AND failure alike (verified 20/20), so it is NOT a
    # failure signal — the real sling error, when one occurs, is the structured
    # JSON on STDOUT. The prior code made a SINGLE attempt and, on an empty
    # bead_id, logged only STDERR (the benign warning), misattributing
    # intermittent, fast-failing sling-write blips to the warning and permanently
    # aborting the sweep. A sole-candidate P1 then stalled the whole backlog for
    # ~2.5h while the SAME sling op succeeded moments/sweeps later. Fix:
    #   (1) RETRY the sling — a transient empty bead_id is no longer fatal;
    #   (2) attribute failures to the REAL stdout error, probing store
    #       reachability so the benign version_compat warning is non-blocking.
    local _sling_err_file _sling_err _sling_attempt _sling_max _sling_sleep
    _sling_err_file="/tmp/pilot-sling-err.$$"
    _sling_max="${PILOT_SLING_RETRIES:-3}"
    _sling_sleep="${PILOT_SLING_SLEEP:-2}"
    SLING_OUT=""
    SLING_BEAD_ID=""
    _sling_attempt=0
    while [ "$_sling_attempt" -lt "$_sling_max" ]; do
      _sling_attempt=$((_sling_attempt + 1))
      SLING_OUT=$(gc --city "$GC_CITY" sling "$BUILDER_TARGET" \
        "$SLING_TITLE" \
        --json \
        2>"$_sling_err_file" || echo "{}")
      SLING_BEAD_ID=$(echo "$SLING_OUT" | jq -r '.bead_id // .id // empty' 2>/dev/null || echo "")
      [ -n "$SLING_BEAD_ID" ] && break
      if [ "$_sling_attempt" -lt "$_sling_max" ]; then
        log "  gc sling returned no bead_id for $STORY_ID (attempt ${_sling_attempt}/${_sling_max}) — retrying in ${_sling_sleep}s (version_compat warning is benign)"
        [ "${_sling_sleep:-0}" -gt 0 ] 2>/dev/null && sleep "$_sling_sleep"
      fi
    done
    # Keep only REAL stderr warnings — strip the constant benign version_compat line.
    _sling_err=$(grep -v 'native_store_unavailable gate=version_compat' "$_sling_err_file" 2>/dev/null | head -c 300 || echo "")
    rm -f "$_sling_err_file"

    DISPATCH_RESULT="sling_ok"

    # gt-q0hon: fail-hard if sling returned no bead ID — do NOT continue with
    # phantom state. ga-eu8vr: distinguish a transient sling-write failure (store
    # reachable → retry next sweep) from a genuine store outage, and report the
    # REAL stdout error — never the benign version_compat warning.
    if [ -z "$SLING_BEAD_ID" ]; then
      local _sling_real_err _store_ok
      _sling_real_err=$(echo "$SLING_OUT" | jq -r '.error.message // empty' 2>/dev/null | head -c 200 || echo "")
      [ -z "$_sling_real_err" ] && _sling_real_err="${_sling_err:-no stdout error}"
      _store_ok=0
      bd -C "$GC_CITY" list --limit 1 >/dev/null 2>&1 && _store_ok=1
      if [ "$_store_ok" = "1" ]; then
        warn "gc sling returned no bead_id for $STORY_ID after ${_sling_max} attempts — store ACCESSIBLE, transient sling-write failure; releasing claim, will retry next sweep (real-err: ${_sling_real_err}) [version_compat warning is benign, not the cause]"
      else
        warn "gc sling failed for $STORY_ID after ${_sling_max} attempts — store UNREACHABLE (real-err: ${_sling_real_err})"
      fi
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      DISPATCH_RESULT="sling_no_bead_id"
      return 1
    fi

    # gt-q0hon: post-sling Dolt verify — guard against phantom bead (hook set but bead
    # never committed to Dolt). Retry up to 3x with 2s gap for propagation lag.
    # SLING_BEAD_ID lives in GC_CITY (sling always creates task beads in HQ).
    local _verify_ok=0 _verify_i
    for _verify_i in 1 2 3; do
      if bd -C "$GC_CITY" show "$SLING_BEAD_ID" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0].id else .id end' >/dev/null 2>&1; then
        _verify_ok=1; break
      fi
      [ "$_verify_i" -lt 3 ] && sleep 2
    done

    if [ "$_verify_ok" = "0" ]; then
      warn "PHANTOM BEAD: gc sling returned $SLING_BEAD_ID but not found in Dolt after 3 attempts. Aborting dispatch for $STORY_ID (gt-q0hon)."
      bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      DISPATCH_RESULT="sling_phantom_bead"
      return 1
    fi

    # ga-2azzj fix 3: record the slung builder task so TTL recovery can tell a
    # genuinely-stuck claim (sling task closed/gone) from an active long build
    # (sling task still open) and refuse to recycle the latter. Set now — before
    # finalization — so it survives even the degraded in-flight-unconfirmed path.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --set-metadata "pilot.sling_bead=$SLING_BEAD_ID" -q 2>/dev/null || true

    timeout 15 gc --city "$GC_CITY" session nudge "$BUILDER_TARGET" "$DISPATCH_TASK" \
      2>/dev/null \
      || warn "Could not nudge $BUILDER_TARGET — builder will see the task bead on next hook cycle"

    log "Dispatch complete: sling_bead=$SLING_BEAD_ID target=$BUILDER_TARGET"
  fi

  # ── Transition bead: lane tag + DURABLE story:in-flight (ga-2azzj fix 1) ──────
  # ORDER IS LOAD-BEARING. The candidate queries EXCLUDE story:in-flight; that
  # label is the ONLY thing that makes a slung bead non-re-dispatchable. So:
  #   1. lane tag (cosmetic accounting — non-fatal).
  #   2. add story:in-flight and VERIFY it stuck (read-after-write retry). This
  #      write is NOT swallowed — a slung-but-unmarked bead is the dangerous
  #      state that caused the ga-8nu8x double-dispatch.
  #   3. ONLY after in-flight is confirmed durable, remove the pilot:dispatching
  #      claim. (The old code removed the claim FIRST, then added in-flight with
  #      `|| true` — a transient Dolt blip or a set -e exit between the two left
  #      NEITHER marker, so the bead stayed re-dispatchable.)
  #   4. pilot:dispatched tag (cosmetic — non-fatal).
  # If in-flight cannot be confirmed (Dolt down): abort HARD and WARN, leaving
  # pilot:dispatching ON so TTL recovery — not a fresh sweep — owns the claim.
  # The builder is already slung; an unmarked re-dispatchable bead is worse than
  # a claim that TTL recovery cleans up once the sling task is closed.
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "lane:${LANE}" -q 2>/dev/null || true

    local _inflight_ok=0 _inflight_i=1
    local _inflight_retries="${PILOT_INFLIGHT_RETRIES:-5}"
    local _inflight_sleep="${PILOT_INFLIGHT_SLEEP:-2}"
    while [ "$_inflight_i" -le "$_inflight_retries" ]; do
      bd -C "$STORY_BEAD_CITY" label add "$STORY_ID" "story:in-flight" -q 2>/dev/null || true
      if bd -C "$STORY_BEAD_CITY" show "$STORY_ID" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0] else . end | (.labels // []) | any(. == "story:in-flight")' \
          >/dev/null 2>&1; then
        _inflight_ok=1; break
      fi
      [ "$_inflight_i" -lt "$_inflight_retries" ] && sleep "$_inflight_sleep"
      _inflight_i=$((_inflight_i + 1))
    done

    if [ "$_inflight_ok" = "0" ]; then
      err "DURABLE-INFLIGHT FAILED on $STORY_ID after ${_inflight_retries} attempts (Dolt down?). Builder '$BUILDER_TARGET' was ALREADY slung (bead=$SLING_BEAD_ID). Leaving pilot:dispatching ON so TTL recovery owns this claim; NOT releasing it (prevents 2nd-builder dispatch, ga-2azzj)."
      DISPATCH_RESULT="inflight_unconfirmed"
      mkdir -p "$(dirname "$PILOT_LOG")" 2>/dev/null || true
      jq -c -n \
        --arg ts "$NOW" --arg story_id "$STORY_ID" --arg builder "$BUILDER_TARGET" \
        --arg sling_bead "$SLING_BEAD_ID" --arg lane "$LANE" --arg tier "$DISPATCH_TIER" \
        '{ts:$ts, event:"pilot_dispatch_degraded", story_id:$story_id, builder:$builder,
          sling_bead:$sling_bead, lane:$lane, tier:$tier, result:"inflight_unconfirmed",
          note:"slung but story:in-flight unconfirmed; pilot:dispatching left on for TTL recovery"}' \
        >> "$PILOT_LOG" 2>/dev/null || true
      notify -t "⚠️ Pilot dispatch degraded" -p 4 \
        "$STORY_ID slung to $BUILDER_TARGET but story:in-flight unconfirmed (Dolt?). Claim left for TTL recovery — check pilot-dispatcher.log" \
        2>/dev/null || true
      return 1
    fi

    # in-flight is durable — NOW safe to release the claim and tag dispatched.
    bd -C "$STORY_BEAD_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$STORY_BEAD_CITY" label add    "$STORY_ID" "pilot:dispatched"  -q 2>/dev/null || true
    # Claim stamps are now moot (bead is in-flight, excluded from TTL query). Clear
    # them so a later re-dispatch (gate:needs-fix) starts from a clean slate.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata "pilot.dispatching_at" -q 2>/dev/null || true

    # ga-ms1jm: a SOURCE bead must NEVER carry gc.routed_to. The builder is
    # dispatched via the separate sling TASK bead created above — this source
    # bead is selected only by the Pilot's own tier/label queries, never by
    # routing. If any path (legacy sling-by-id, manual edit, future regression)
    # leaves gc.routed_to=<dog-pool> on this now-in-flight source bead, the dog
    # pool's engine ready-query (`bd ready --metadata-field gc.routed_to=...
    # --unassigned`, which does NOT exclude story:in-flight) would re-claim it →
    # double-dispatch, spawning a duplicate builder and pinning dog slots on
    # already-fixed work. The ga-zzrts guards above stop the PILOT re-dispatching;
    # this stops the DOG engine query re-claiming. Idempotent (no-op when absent);
    # || true keeps set -euo pipefail safe.
    bd -C "$STORY_BEAD_CITY" update "$STORY_ID" --unset-metadata gc.routed_to -q >/dev/null 2>&1 || true

    local DISPATCH_COMMENT
    if [ "$DISPATCH_TIER" = "bug" ]; then
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=bug/tech-debt, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: fix bug → /gate-done → autonomous gate+delivery → bead closed.
No human review required. SYSTEM QUALITY FIRST."
    else
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=feature, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: implement → /gate-done → autonomous gate+delivery → story:done.
No human review required."
    fi

    bd -C "$STORY_BEAD_CITY" comment "$STORY_ID" "$DISPATCH_COMMENT" \
      2>/dev/null || warn "Could not post dispatch comment to $STORY_ID"
  fi

  local DISPATCH_END_EPOCH ELAPSED_S
  DISPATCH_END_EPOCH=$(date +%s)
  ELAPSED_S=$((DISPATCH_END_EPOCH - DISPATCH_EPOCH))

  log "$DISPATCH_TIER [$LANE] $STORY_ID → story:in-flight (builder=$BUILDER_TARGET elapsed=${ELAPSED_S}s)"

  # ── Log to pilot-dispatcher.jsonl ───────────────────────────────────────────
  mkdir -p "$(dirname "$PILOT_LOG")"
  jq -c -n \
    --arg ts "$NOW" \
    --arg story_id "$STORY_ID" \
    --arg story_title "$STORY_TITLE" \
    --arg tier "$DISPATCH_TIER" \
    --arg lane "$LANE" \
    --arg rig "$STORY_RIG" \
    --arg builder "$BUILDER_TARGET" \
    --arg sling_bead "$SLING_BEAD_ID" \
    --arg result "$DISPATCH_RESULT" \
    --argjson priority "$STORY_PRIORITY" \
    --argjson elapsed_s "$ELAPSED_S" \
    --arg dry_run "$DRY_RUN" \
    '{ts: $ts, event: "pilot_dispatch", story_id: $story_id, story_title: $story_title,
      tier: $tier, lane: $lane, rig: $rig, builder: $builder, sling_bead: $sling_bead,
      result: $result, priority: $priority, elapsed_s: $elapsed_s, dry_run: $dry_run}' \
    >> "$PILOT_LOG" 2>/dev/null || true

  # ── Notify ───────────────────────────────────────────────────────────────────
  if [ "$DRY_RUN" = "1" ]; then
    local TIER_LABEL
    TIER_LABEL="$([ "$DISPATCH_TIER" = "bug" ] && echo "BUG/DEBT" || echo "feature")"
    notify -t "Pilot DRY-RUN" -p 1 \
      "Would dispatch $STORY_ID [$TIER_LABEL/$LANE] (P${STORY_PRIORITY}) → $BUILDER_TARGET [DRY_RUN]" \
      2>/dev/null || true
  else
    notify -t "✨ Pilot pegou uma história" -p 3 \
      "✨ $STORY_TITLE ($STORY_ID, P${STORY_PRIORITY}, lane=$LANE → $BUILDER_TARGET)" \
      2>/dev/null || true
  fi
}

# ── Step 4: Dispatch-to-capacity per lane (ga-rk5va) ──────────────────────────
# Fill EVERY free slot in each lane this sweep — not one pick per lane. After a
# drain this refills all 5 small slots in ONE sweep (~the user's "máxima lotação")
# instead of ~5 sweeps. Each lane is independent: a full big lane never blocks
# small dispatches. Caps (MAX_SMALL/MAX_BIG), dedup, and the per-bead atomic claim
# inside dispatch_one are all preserved, so a lane can never exceed its cap.
#
# Throttle (constraint a): when Dolt was SATURATED at sweep start, or the operator
# disabled the feature, each lane caps at a single dispatch (== legacy behavior —
# never adds load beyond the old code). Between dispatches we re-check Dolt CPU
# cheaply and bail the instant it crosses the ceiling, so dispatch-to-capacity
# can never WIDEN a wedged pipe (the fd-leak/CPU-incident class this guards).

DISPATCHED=0

# dispatch_lane <lane> <candidates_json> <free_slots>
# Loops pick→dispatch→remove until the lane is full or candidates are exhausted.
# Mutates the global DISPATCHED (NOT via command-substitution — the script's
# top-level `exec >> LOG 2>&1` means $(...) would swallow dispatch_one's log lines).
dispatch_lane() {
  local lane="$1" pool="$2" slots="$3"
  local cap="$slots"
  # Constraint a: saturated-at-start OR feature disabled → throttle to 1 (legacy).
  if [ "$DISPATCH_TO_CAPACITY" != "1" ] || [ "${PILOT_DOLT_SATURATED_AT_START:-0}" = "1" ]; then
    cap=1
  fi

  # Hard iteration ceiling: at most one attempt per candidate plus a small margin.
  # Defense-in-depth so a (near-impossible) jq pool-removal failure — which would
  # otherwise let a perpetually-skipping pick be re-tried forever — can never spin.
  local _iter=0 _iter_max
  _iter_max=$(( $(echo "$pool" | jq 'length' 2>/dev/null || echo "0") + 2 ))

  local filled=0
  while [ "$filled" -lt "$cap" ] && [ "$slots" -gt 0 ]; do
    _iter=$((_iter + 1))
    if [ "$_iter" -gt "$_iter_max" ]; then
      warn "Lane $lane: iteration guard hit (${_iter}>${_iter_max}) — stopping loop (pool-removal anomaly?)."
      break
    fi
    local n
    n=$(echo "$pool" | jq 'length' 2>/dev/null || echo "0")
    [ "${n:-0}" -le 0 ] 2>/dev/null && break

    local pick pick_id
    pick=$(_top_candidate "$pool")
    { [ -z "$pick" ] || [ "$pick" = "null" ]; } && break
    pick_id=$(echo "$pick" | jq -r '.id // ""' 2>/dev/null || echo "")
    [ -z "$pick_id" ] && break

    # Remove from the IN-MEMORY pool BEFORE dispatch: a skipped pick (lost claim,
    # builder-mutex defer, race) must not be re-picked (no infinite loop), and
    # DRY_RUN — which makes zero state changes — still advances through the pool.
    pool=$(echo "$pool" | jq --arg id "$pick_id" '[.[] | select(.id != $id)]' 2>/dev/null || echo "$pool")

    # Only a SUCCESSFUL dispatch consumes a slot; a skip leaves the slot free and
    # simply moves to the next candidate. dispatch_one is the atomic-claim owner.
    if dispatch_one "$pick" "$lane" "$ALL_CANDIDATES_TIER"; then
      filled=$((filled + 1))
      slots=$((slots - 1))
      DISPATCHED=$((DISPATCHED + 1))
    fi

    # Mid-loop Dolt backoff (constraint a): if work remains, re-check the cheap CPU
    # signal and stop the moment Dolt is hot, so we never drive a saturated server.
    if [ "$filled" -lt "$cap" ] && [ "$slots" -gt 0 ]; then
      local _more
      _more=$(echo "$pool" | jq 'length' 2>/dev/null || echo "0")
      if [ "${_more:-0}" -gt 0 ] 2>/dev/null && _dolt_saturated; then
        warn "Dolt saturated mid-sweep (cpu=$(_dolt_cpu)% lat=${DOLT_LATENCY_MS:-?}ms) — stopping $lane loop after ${filled} dispatch(es) (ga-rk5va backoff)."
        break
      fi
    fi
  done

  log "Lane $lane: dispatched ${filled} this sweep (cap=${cap}, slots_left=${slots})."
}

# Small + big lanes are independent. Dispatch the full pool for each (the loop is
# a no-op when a lane has no slots or no candidates).
if [ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ]; then
  dispatch_lane "small" "$SMALL_CANDIDATES" "$SMALL_SLOTS"
fi

if [ "$BIG_SLOTS" -gt "0" ] && [ "$BIG_COUNT" -gt "0" ]; then
  dispatch_lane "big" "$BIG_CANDIDATES" "$BIG_SLOTS"
fi

if [ "$DISPATCHED" -eq "0" ]; then
  log "No dispatches this sweep (lane slots may have been won by a concurrent process, or all picks skipped)."
fi

log "=== Pilot sweep complete: dispatched=$DISPATCHED (small_slots=$SMALL_SLOTS big_slots=$BIG_SLOTS dolt_saturated_at_start=${PILOT_DOLT_SATURATED_AT_START:-0}) ==="
