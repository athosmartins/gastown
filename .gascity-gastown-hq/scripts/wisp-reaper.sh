#!/usr/bin/env bash
# wisp-reaper.sh — the missing DAEMON fix for ephemeral-bead sprawl.
#
# PROBLEM (audit 2026-06-17): the town accumulates ~hundreds of OPEN ephemeral
# beads — gc:nudge message beads (ga-wisp-* ids, "nudge:nudge-…") created by the
# gate/Pilot/session machinery to inject a wake-up into a target session — that
# are never closed once they become obsolete, because the reaper is a MANUAL
# skill (`/reaper`), not a daemon. The two existing launchd reapers only touch
# the FILESYSTEM (worktree-reaper.sh) and tmux (adhoc-session-reaper.sh); neither
# closes beads. So nudge ephemerals pile up and inflate the Kanban / Dolt store.
#
# A gc:nudge bead is OBSOLETE — and safe to CLOSE — when ANY of:
#   (a) TTL expired       — metadata.expires_at < now. The injection window has
#                           passed; the nudge can no longer be delivered.
#   (b) ORPHAN parent     — metadata.session_id names a session bead that is now
#                           CLOSED. The recipient session is dead, so the nudge
#                           can never be injected (the engine itself records this
#                           as "managed wake failed: session <id> is closed").
#   (c) TERMINAL state    — metadata.state ∈ {expired, failed, injected}. These
#                           are the terminal states observed in CLOSED nudges;
#                           the work the nudge represented is done/dead.
#   (d) UNREACHABLE recipient (ga-clgc2) — metadata.agent is suspended=true in
#                           city.toml, OR the recipient session has been
#                           state=="asleep" for more than WISP_REAPER_HALF_TTL_
#                           MINUTES (default 720 = 12h, half the ~24h nudge
#                           TTL). Neither (a) nor (c) catch this case: TTL
#                           hasn't expired yet and state is still "queued" —
#                           the nudge would otherwise sit for the FULL TTL and
#                           get replenished by every dog run in the meantime
#                           (379 such nudges to a 20-day-asleep, suspended
#                           deacon dominated Dolt poll load — see ga-clgc2).
# Otherwise (queued / accepted_for_injection, future TTL, parent open/unknown) →
# KEEP. When in doubt, KEEP (zero false-close is paramount).
#
# SCOPE BOUNDARY — wisp-reaper handles NUDGE/wisp EPHEMERALS ONLY. It explicitly
# does NOT touch (these are owned by other lifecycles, and closing them here
# would be a false-positive):
#   • gc:session beads          → LIVE agent sessions (engine/supervisor own them)
#   • type:quality-gate-marker  → active gate machinery (gate dispatcher owns it)
#   • type:quality-gate-run     → active gate machinery
#   • type:convoy / dc-* beads  → reconciled by the merged-bead-janitor's
#                                 convoy-reconciler (janitor_convoy_decide), which
#                                 closes them on all-deps-closed. Do NOT duplicate
#                                 convoy/coordination handling here.
#   • order:* / order-run beads → order machinery
#
# bd-ONLY. NEVER rm anything; NEVER touch .dolt/ internals. The only mutation is
# `bd close` (+ a one-line evidence comment) on a verifiably-obsolete nudge bead.
#
# ANTI-DOLT-SPIKE: a cap (WISP_REAPER_MAX_PER_SWEEP, default 60) bounds REAL
# closes per sweep so a large backlog drains over several hourly sweeps instead
# of hundreds of Dolt commits at once. A pre-sweep `gc dolt status` health probe
# bails (KEEP-biased) when Dolt is unhealthy, so the reaper never piles load onto
# a struggling server.
#
# Idempotent (closing a closed bead is a no-op), DRY_RUN-first
# (WISP_REAPER_DRY_RUN=1 or --dry-run), set -uo pipefail safe (every VAR=$(cmd)
# that can fail is `|| true`-guarded — the documented gate-dispatcher crash class;
# NOT set -e).
#
# Lib-only mode: `WISP_REAPER_LIB_ONLY=1 source wisp-reaper.sh` defines the pure
# decision helpers WITHOUT running the sweep, so the selftest exercises the real
# functions (one source of truth, no copy-drift).

set -uo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
GC_CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/wisp-reaper.jsonl"
SOURCE="wisp-reaper"

# The bead stores to sweep. nudge ephemerals are created in the HQ city store by
# the gate/session machinery; the rig stores are swept too for completeness (a
# store with no nudge ephemerals simply yields 0 — cheap).
DEFAULT_STORES="/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers"
STORES="${WISP_REAPER_STORES:-$DEFAULT_STORES}"

ENABLED="${WISP_REAPER_ENABLED:-1}"           # 0 = report-only (would_close), do not mutate
DRY_RUN="${WISP_REAPER_DRY_RUN:-0}"           # 1 = report-only (alias of ENABLED=0 semantics)
MAX_PER_SWEEP="${WISP_REAPER_MAX_PER_SWEEP:-60}"   # anti-Dolt-spike cap (real closes/sweep)
DOLT_HEALTH_GATE="${WISP_REAPER_DOLT_HEALTH_GATE:-1}"  # 1 = bail if `gc dolt status` fails
HALF_TTL_MINUTES="${WISP_REAPER_HALF_TTL_MINUTES:-720}"  # 12h: half the ~24h nudge TTL (ga-clgc2 criterion d)

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done
# ENABLED=0 implies dry-run (report only).
[ "$ENABLED" = "1" ] || DRY_RUN=1

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
NOW="$(ts)"

# ── JSONL logging (best-effort; stdout when interactive) ─────────────────────
emit() {  # emit <json-object-without-ts>  → prepends ts, appends to JSONL log
  local obj="$1"
  local line
  line=$(printf '{"ts":"%s",%s}' "$(ts)" "$obj")
  [ -t 1 ] && echo "$line"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$line" >> "$LOG" 2>/dev/null || true
}
# json-escape a string for embedding in a JSON value.
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }

# ── notify (best-effort) ─────────────────────────────────────────────────────
notify_athos() { command -v notify >/dev/null 2>&1 || return 0; notify "$@" >/dev/null 2>&1 || true; }

# ═════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTION — the heart of the reaper; fully unit-testable.
#
# wisp_reap_decide <is_nudge> <is_protected> <ttl_expired> <parent_closed> <state_terminal> <recipient_unreachable>
#   is_nudge        1 iff bead carries the gc:nudge label
#   is_protected    1 iff bead is a protected class (gc:session / quality-gate-
#                   marker / quality-gate-run / convoy / dc-*) — owned elsewhere
#   ttl_expired     1 iff metadata.expires_at is non-empty AND < now
#   parent_closed   1 iff metadata.session_id names a bead whose status==closed
#                   (0 when parent is open OR unknown/unreadable — KEEP-biased)
#   state_terminal  1 iff metadata.state ∈ {expired, failed, injected}
#   recipient_unreachable  1 iff the recipient agent is suspended, or its
#                   session has been asleep beyond WISP_REAPER_HALF_TTL_MINUTES
#                   (ga-clgc2 criterion d; see recipient_unreachable_too_long())
# Echoes "<verdict>:<reason>", verdict ∈ {close, keep}.
# Guards (keep) are evaluated FIRST and win over the close signals — protected
# class and non-nudge always KEEP, so the reaper can NEVER touch live machinery.
# ═════════════════════════════════════════════════════════════════════════════
wisp_reap_decide() {
  local is_nudge="$1" is_protected="$2" ttl_expired="$3" parent_closed="$4" state_terminal="$5" recipient_unreachable="$6"
  if [ "$is_protected" = "1" ]; then     echo "keep:protected-class-owned-elsewhere"; return 0; fi
  if [ "$is_nudge" != "1" ]; then        echo "keep:not-an-ephemeral-nudge"; return 0; fi
  if [ "$ttl_expired" = "1" ]; then      echo "close:nudge-ttl-expired"; return 0; fi
  if [ "$parent_closed" = "1" ]; then    echo "close:nudge-orphan-parent-session-closed"; return 0; fi
  if [ "$state_terminal" = "1" ]; then   echo "close:nudge-terminal-state"; return 0; fi
  if [ "$recipient_unreachable" = "1" ]; then echo "close:nudge-recipient-suspended-or-long-asleep"; return 0; fi
  echo "keep:nudge-still-pending"
}

# is_protected_labels <space-joined-labels> <bead_id> — rc0 (echo 1) iff the bead
# is a protected class the reaper must never close; echo 0 otherwise. PURE.
is_protected_labels() {
  local labels="$1" id="$2"
  case " $labels " in
    *" gc:session "*|*" type:quality-gate-marker "*|*" type:quality-gate-run "*|*" type:convoy "*|*" gt:convoy "*)
      echo 1; return 0 ;;
  esac
  case "$id" in dc-*) echo 1; return 0 ;; esac
  echo 0
}

# state_is_terminal <state> — rc0 (echo 1) iff a nudge state is terminal. PURE.
state_is_terminal() {
  case "$1" in expired|failed|injected) echo 1 ;; *) echo 0 ;; esac
}

# ttl_is_expired <expires_at> <now_iso> — echo 1 iff expires_at non-empty and
# lexicographically < now (RFC3339 UTC sorts lexically == chronologically). PURE.
ttl_is_expired() {
  local exp="$1" now="$2"
  [ -n "$exp" ] && [ "$exp" != "null" ] || { echo 0; return 0; }
  if [ "$exp" \< "$now" ]; then echo 1; else echo 0; fi
}

# recipient_unreachable_too_long <agent_suspended> <asleep_minutes> <half_ttl_minutes>
# (ga-clgc2 criterion d) — echo 1 iff:
#   agent_suspended==1                              (recipient agent suspended), OR
#   asleep_minutes is a known non-negative integer AND > half_ttl_minutes
# asleep_minutes=="" (not asleep, or lookup failed/unknown) NEVER closes on its
# own — fail-safe KEEP, same contract as the sibling adhoc-session-reaper.sh's
# idle_minutes(): "" means unknown, callers must not treat unknown as a signal
# to act. PURE (given its three scalar args).
recipient_unreachable_too_long() {
  local agent_suspended="$1" asleep_minutes="$2" half_ttl_minutes="$3"
  if [ "$agent_suspended" = "1" ]; then echo 1; return 0; fi
  case "$asleep_minutes" in
    ''|*[!0-9]*) echo 0; return 0 ;;
  esac
  if [ "$asleep_minutes" -gt "$half_ttl_minutes" ]; then echo 1; else echo 0; fi
}

# slept_minutes <slept_at_rfc3339> — integer minutes since slept_at, or "" on
# empty/unparseable/zero-time input (unknown → callers fail SAFE, never close
# on ""). Mirrors adhoc-session-reaper.sh's age_minutes()/idle_minutes(): same
# python3-canonical ISO8601 parser (handles trailing Z and ±HH:MM offsets that
# macOS BSD `date` mishandles), GNU `date -d` as a non-macOS fallback.
slept_minutes() {
  local slept="$1" epoch
  [ -n "$slept" ] && [ "$slept" != "null" ] || { echo ""; return 0; }
  case "$slept" in 0001-01-01*) echo ""; return 0 ;; esac
  epoch=$(python3 -c 'import sys,datetime
s=sys.argv[1].strip()
try:
    if s.endswith("Z"): s=s[:-1]+"+00:00"
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    sys.exit(1)' "$slept" 2>/dev/null)
  [ -z "$epoch" ] && epoch=$(date -d "$slept" +%s 2>/dev/null)
  [ -z "$epoch" ] && { echo ""; return 0; }
  echo $(( ( $(date +%s) - epoch ) / 60 ))
}

# ═════════════════════════════════════════════════════════════════════════════
# Guard: when sourced for tests, stop here (no live sweep).
# ═════════════════════════════════════════════════════════════════════════════
[ "${WISP_REAPER_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# SWEEP
# ═════════════════════════════════════════════════════════════════════════════
emit "$(printf '"event":"sweep_start","dry_run":%s,"enabled":%s,"max_per_sweep":%s,"now":"%s"' "$DRY_RUN" "$ENABLED" "$MAX_PER_SWEEP" "$NOW")"

# Anti-Dolt-spike: bail (KEEP everything) if Dolt is unhealthy — never pile load
# onto a struggling server. Fail-safe: only bails on a clear nonzero rc.
if [ "$DOLT_HEALTH_GATE" = "1" ]; then
  if ! gc --city "$GC_CITY" dolt status >/dev/null 2>&1; then
    emit '"event":"sweep_skip","reason":"dolt_unhealthy_or_unreachable"'
    notify_athos -t "wisp-reaper" "skipped sweep: gc dolt status unhealthy"
    exit 0
  fi
fi

# Cache of session_id lookups to avoid re-querying shared parents within a sweep.
# bash 3.2 (macOS /bin/bash, the launchd interpreter) has NO associative arrays,
# so the cache is a newline-delimited "<sid> <result>" string — same pattern the
# sibling reapers use (indexed arrays / plain strings only).
SESSION_CLOSED_CACHE=""

# parent_session_closed <session_id> — echo 1 iff the session bead is closed,
# 0 if it is open OR unknown/unreadable (KEEP-biased). Cached per sweep.
parent_session_closed() {
  local sid="$1"
  [ -n "$sid" ] && [ "$sid" != "null" ] || { echo 0; return 0; }
  local cached
  cached=$(printf '%s\n' "$SESSION_CLOSED_CACHE" | awk -v s="$sid" '$1==s{print $2; exit}')
  if [ -n "$cached" ]; then echo "$cached"; return 0; fi
  local st res
  st=$(bd -C "$GC_CITY" show "$sid" --json 2>/dev/null | jq -r '(if type=="array" then .[0] else . end).status // "unknown"' 2>/dev/null || echo "unknown")
  if [ "$st" = "closed" ]; then res=1; else res=0; fi   # open OR unknown → KEEP-biased 0
  SESSION_CLOSED_CACHE="$SESSION_CLOSED_CACHE
$sid $res"
  echo "$res"
}

# Agent-suspended snapshot (ga-clgc2 criterion d), fetched ONCE per sweep and
# reused across every store/bead: `gc agent list --json` is a static city.toml
# read (no Dolt round-trip) — cheap, but there's no reason to re-fetch it per
# bead when it cannot change mid-sweep. Empty/unreadable on failure;
# agent_is_suspended() below treats not-found the same as "not suspended"
# (KEEP-biased — mirrors parent_session_closed()'s bias on lookup failure).
AGENTS_JSON=$(gc --city "$GC_CITY" agent list --json 2>/dev/null || echo '{}')

# agent_is_suspended <qualified_agent_name> — echo 1 iff that agent has
# suspended=true in the sweep's AGENTS_JSON snapshot, 0 otherwise (including
# empty name, not-found, or a lookup that failed — KEEP-biased).
agent_is_suspended() {
  local qname="$1" flag
  [ -n "$qname" ] || { echo 0; return 0; }
  flag=$(printf '%s' "$AGENTS_JSON" | jq -r --arg q "$qname" \
    '[.agents[]? | select(.qualified_name==$q) | .suspended][0] // false' 2>/dev/null)
  [ "$flag" = "true" ] && echo 1 || echo 0
}

# Cache of session asleep-duration lookups, same pattern/rationale as
# SESSION_CLOSED_CACHE. Kept as a SEPARATE cache/bd-show call rather than
# folded into parent_session_closed() — a second lookup per unique session_id
# is an acceptable tradeoff at this bead volume (a handful of distinct
# recipients) to avoid touching parent_session_closed()'s proven logic.
# Internal-only "NA" sentinel distinguishes "cached as unknown" from "not yet
# cached" (unlike SESSION_CLOSED_CACHE's 0/1, this cache's real values can
# legitimately be the empty string).
SESSION_ASLEEP_CACHE=""

# session_asleep_minutes <session_id> — minutes the session has been
# state=="asleep", or "" if not asleep / unknown/unreadable. Cached per sweep.
session_asleep_minutes() {
  local sid="$1"
  [ -n "$sid" ] && [ "$sid" != "null" ] || { echo ""; return 0; }
  local cached
  cached=$(printf '%s\n' "$SESSION_ASLEEP_CACHE" | awk -v s="$sid" '$1==s{print $2; exit}')
  if [ -n "$cached" ]; then
    [ "$cached" = "NA" ] && echo "" || echo "$cached"
    return 0
  fi
  local j state slept mins cache_val
  j=$(bd -C "$GC_CITY" show "$sid" --json 2>/dev/null)
  state=$(printf '%s' "$j" | jq -r '(if type=="array" then .[0] else . end).metadata.state // ""' 2>/dev/null || true)
  if [ "$state" = "asleep" ]; then
    slept=$(printf '%s' "$j" | jq -r '(if type=="array" then .[0] else . end).metadata.slept_at // ""' 2>/dev/null || true)
    mins=$(slept_minutes "$slept")
  else
    mins=""
  fi
  cache_val="$mins"; [ -z "$cache_val" ] && cache_val="NA"
  SESSION_ASLEEP_CACHE="$SESSION_ASLEEP_CACHE
$sid $cache_val"
  echo "$mins"
}

TOTAL_CLOSED=0
TOTAL_WOULD=0
TOTAL_KEPT=0
CAP_HIT=0
declare -a CLOSED_SUMMARY=()

for STORE in $STORES; do
  [ -d "$STORE" ] || { emit "$(printf '"event":"store_skip","store":"%s","reason":"missing"' "$(jesc "$STORE")")"; continue; }
  [ -d "$STORE/.beads" ] || { emit "$(printf '"event":"store_skip","store":"%s","reason":"no_beads_dir"' "$(jesc "$STORE")")"; continue; }

  # Pull OPEN gc:nudge ephemerals in this store. (We scope the bd query to the
  # gc:nudge label so we never even enumerate live sessions / gate machinery.)
  NUDGES=$(bd -C "$STORE" list --status open --all --limit 0 --json -l gc:nudge 2>/dev/null || echo '[]')
  [ -z "$NUDGES" ] && NUDGES='[]'
  N=$(printf '%s' "$NUDGES" | jq 'length' 2>/dev/null || echo 0)
  emit "$(printf '"event":"store_scan","store":"%s","open_nudges":%s' "$(jesc "$STORE")" "$N")"
  [ "$N" = "0" ] && continue

  while IFS= read -r b; do
    [ -z "$b" ] && continue
    BID=$(printf '%s' "$b" | jq -r '.id // ""' 2>/dev/null || true)
    [ -z "$BID" ] && continue
    BLABELS=$(printf '%s' "$b" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || true)
    BSTATE=$(printf '%s' "$b" | jq -r '.metadata.state // ""' 2>/dev/null || true)
    BEXP=$(printf '%s' "$b" | jq -r '.metadata.expires_at // ""' 2>/dev/null || true)
    BSESS=$(printf '%s' "$b" | jq -r '.metadata.session_id // ""' 2>/dev/null || true)
    BAGENT=$(printf '%s' "$b" | jq -r '.metadata.agent // ""' 2>/dev/null || true)
    BTITLE=$(printf '%s' "$b" | jq -r '(.title // "")[0:50]' 2>/dev/null || true)

    IS_NUDGE=0; case " $BLABELS " in *" gc:nudge "*) IS_NUDGE=1 ;; esac
    IS_PROT=$(is_protected_labels "$BLABELS" "$BID")
    TTL_EXP=$(ttl_is_expired "$BEXP" "$NOW")
    ST_TERM=$(state_is_terminal "$BSTATE")
    # Only pay for the parent/recipient lookups when no cheaper close signal
    # already fired and the bead is an unprotected nudge (avoids needless
    # Dolt queries). recipient_unreachable (criterion d, ga-clgc2) is checked
    # last and only when (a)/(b)/(c) all left the bead as "would keep" —
    # it's strictly additive, never overrides an existing close reason.
    PAR_CLOSED=0
    RECIP_UNREACH=0
    if [ "$IS_PROT" = "0" ] && [ "$IS_NUDGE" = "1" ] && [ "$TTL_EXP" = "0" ]; then
      PAR_CLOSED=$(parent_session_closed "$BSESS")
      if [ "$PAR_CLOSED" = "0" ] && [ "$ST_TERM" = "0" ]; then
        AGENT_SUSP=$(agent_is_suspended "$BAGENT")
        ASLEEP_MIN=$(session_asleep_minutes "$BSESS")
        RECIP_UNREACH=$(recipient_unreachable_too_long "$AGENT_SUSP" "$ASLEEP_MIN" "$HALF_TTL_MINUTES")
      fi
    fi

    VERDICT_LINE=$(wisp_reap_decide "$IS_NUDGE" "$IS_PROT" "$TTL_EXP" "$PAR_CLOSED" "$ST_TERM" "$RECIP_UNREACH")
    VERDICT="${VERDICT_LINE%%:*}"; REASON="${VERDICT_LINE#*:}"

    if [ "$VERDICT" = "close" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        TOTAL_WOULD=$((TOTAL_WOULD+1))
        emit "$(printf '"event":"would_close","store":"%s","id":"%s","reason":"%s","state":"%s","title":"%s"' \
          "$(jesc "$STORE")" "$BID" "$REASON" "$(jesc "$BSTATE")" "$(jesc "$BTITLE")")"
      else
        if [ "$TOTAL_CLOSED" -ge "$MAX_PER_SWEEP" ]; then
          CAP_HIT=1
          emit "$(printf '"event":"cap_reached","store":"%s","max_per_sweep":%s,"note":"deferring remaining nudges to next sweep"' "$(jesc "$STORE")" "$MAX_PER_SWEEP")"
          break
        fi
        RMSG="wisp-reaper: obsolete ephemeral nudge — $REASON. Auto-closed."
        if bd -C "$STORE" close "$BID" -r "$RMSG" 2>/dev/null; then
          TOTAL_CLOSED=$((TOTAL_CLOSED+1))
          CLOSED_SUMMARY+=("$BID:$REASON")
          emit "$(printf '"event":"closed","store":"%s","id":"%s","reason":"%s"' "$(jesc "$STORE")" "$BID" "$REASON")"
        else
          emit "$(printf '"event":"close_failed","store":"%s","id":"%s","reason":"%s"' "$(jesc "$STORE")" "$BID" "$REASON")"
        fi
      fi
    else
      TOTAL_KEPT=$((TOTAL_KEPT+1))
    fi
  done <<EOF
$(printf '%s' "$NUDGES" | jq -rc '.[]?')
EOF
  [ "$CAP_HIT" = "1" ] && break
done

emit "$(printf '"event":"sweep_complete","closed":%s,"would_close":%s,"kept":%s,"cap_hit":%s,"dry_run":%s' \
  "$TOTAL_CLOSED" "$TOTAL_WOULD" "$TOTAL_KEPT" "$CAP_HIT" "$DRY_RUN")"

if [ "$DRY_RUN" = "0" ] && [ "$TOTAL_CLOSED" -gt 0 ]; then
  SAMPLE=$(printf '%s; ' "${CLOSED_SUMMARY[@]:0:8}")
  [ "$TOTAL_CLOSED" -gt 8 ] && SAMPLE="$SAMPLE…(+$((TOTAL_CLOSED-8)) more)"
  notify_athos -t "wisp-reaper" "Closed $TOTAL_CLOSED obsolete ephemeral nudge bead(s): $SAMPLE"
fi
exit 0
