#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# STOPGAP GUARD (gt-bewtm) — gate-reviewer orphan clearer
#
# WHY: the gate dispatcher's headroom LIVE_REVIEWERS count treats every
# present-non-closed reviewer session as alive (asleep = normal between-turns).
# A DRAINED reviewer also presents as asleep and inflates the count until the
# slow 65m age-TTL reap → false "dolt-calm-cap-reached / gate em N runs" → the
# dispatcher DEFERs every sweep even with Dolt calm + queue full = town-wide
# deadlock (2026-06-12). This guard closes genuinely-dead reviewer sessions fast
# so the count stays honest and the gate self-heals.
#
# SAFE: only closes sessions that are past MIN_AGE_SECS, NOT in state=creating,
# NOT in state=active, and whose `gc session peek` reports GONE (exit != 0).
# A live reviewer — active OR asleep-between-turns — peeks exit 0 and is NEVER
# touched.
#
# ga-flfo: a `gc session new --no-attach` deferred start can take ~210s under
# load/Dolt pressure before the tmux runtime actually appears. During that
# window the session is listed with state=creating and `gc session peek`
# answers "session not found" — the IDENTICAL signal a genuinely-drained
# (already-ended) reviewer produces. Pre-fix this script had NO age floor at
# all and read STATE from the wrong column ($4 = REASON, not STATE, in `gc
# session list`'s plain columnar output — the "active) continue" fast-path
# was silently never matching a real active session; only the peek fallback
# protected it). With a 189s StartInterval sweep running INSIDE every
# reviewer's ~210s boot window, freshly-spawned reviewers got closed before
# they ever reviewed anything (observed live: w4x6vg reaped 32s after spawn,
# uraowb at 48s). Switched to `gc session list --json` for accurate
# state/created_at, added MIN_AGE_SECS (default 360s, comfortably above the
# observed worst-case boot) and an explicit state=creating exclusion (belt and
# suspenders — a session can only be "creating" while genuinely booting, never
# while genuinely dead). Mirrors the proven MIN_AGE pattern from the sibling
# adhoc-session-reaper.sh, which already does this correctly.
#
# TEMPORARY: remove this guard + its plist once gt-bewtm (headroom
# drained-reviewer exclusion) is merged and deployed. Tracked: gt-bewtm.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# orphan_clear_decision <state> <age_secs|""> <min_age_secs> → echoes one of:
#   keep_active | keep_creating | keep_young | keep_age_unknown | eligible
# Pure; no I/O. Encodes only the FAST, list-only skip rules — "eligible" means
# the caller should proceed to the peek probe (which needs I/O and so is kept
# out of this function to stay unit-testable without a live gc/tmux).
# ga-flfo: state=creating means the session record exists but the runtime has
# not appeared yet — this is NEVER a signal of death, regardless of age, so it
# is excluded up front. The age floor (min_age) additionally protects any
# session that transitions out of "creating" before its runtime is truly ready
# to answer a peek. Unknown age (created_at missing/unparseable) fails SAFE
# (keep) — never reap on incomplete information.
orphan_clear_decision() {
  local state="$1" age="$2" min_age="$3"
  case "$state" in
    active) echo "keep_active"; return 0 ;;
  esac
  case "$state" in
    creating) echo "keep_creating"; return 0 ;;
  esac
  case "$age" in
    ''|*[!0-9]*) echo "keep_age_unknown"; return 0 ;;
  esac
  case "$min_age" in
    ''|*[!0-9]*) min_age=360 ;;
  esac
  if [ "$age" -lt "$min_age" ]; then
    echo "keep_young"; return 0
  fi
  echo "eligible"
}

# session_age_secs <created_at_rfc3339> <now_epoch> → integer seconds since
# creation | "" on failure (empty/unparseable). Pure; no I/O. Same canonical
# python3 ISO-8601 parser as adhoc-session-reaper.sh's age_minutes() — macOS
# BSD `date` mishandles the ±HH:MM / trailing-Z timestamps `gc session list
# --json` emits.
session_age_secs() {
  local created="$1" now="$2" epoch
  [ -z "$created" ] && { echo ""; return 0; }
  epoch=$(python3 -c 'import sys,datetime
s=sys.argv[1].strip()
try:
    if s.endswith("Z"): s=s[:-1]+"+00:00"
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    sys.exit(1)' "$created" 2>/dev/null)
  [ -z "$epoch" ] && epoch=$(date -d "$created" +%s 2>/dev/null)
  [ -z "$epoch" ] && { echo ""; return 0; }
  echo $(( now - epoch ))
}

# Sourcing guard: a selftest sources this file to unit-test the pure helpers
# above WITHOUT running a sweep. Mirrors adhoc-session-reaper.sh's
# ADHOC_REAPER_SOURCE_ONLY convention.
[ "${GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY:-0}" = "1" ] && return 0 2>/dev/null

cd /Users/athos/gt/.gascity-gastown-hq || exit 0

LOG=/Users/athos/gt/.gascity-gastown-hq/.gc/logs/gate-reviewer-orphan-clear.log
ts() { date '+%Y-%m-%d %H:%M:%S'; }
now_epoch() { date +%s; }

MIN_AGE_SECS="${GATE_REVIEWER_ORPHAN_CLEAR_MIN_AGE_SECS:-360}"
case "$MIN_AGE_SECS" in ''|*[!0-9]*) MIN_AGE_SECS=360 ;; esac

checked=0
cleared=0
kept_young=0
kept_creating=0

NOW_EPOCH=$(now_epoch)

# Snapshot sessions once via --json: id, state, created_at for any session
# whose template contains "gate-reviewer" (substring match preserves the
# original plain-list grep's scope: covers both "gate-reviewer" and
# "refino-gate-reviewer" templates).
while IFS=$'\t' read -r sid state created; do
  [ -z "$sid" ] && continue
  age=$(session_age_secs "$created" "$NOW_EPOCH")
  decision=$(orphan_clear_decision "$state" "$age" "$MIN_AGE_SECS")
  case "$decision" in
    keep_active) continue ;;
    keep_creating) kept_creating=$((kept_creating + 1)); continue ;;
    keep_young) kept_young=$((kept_young + 1)); continue ;;
    keep_age_unknown) continue ;;
  esac
  # decision == "eligible" → proceed to the peek probe.
  checked=$((checked + 1))
  # peek is a pure read probe: exit 0 => alive (keep); non-zero => gone (close).
  if gc session peek "$sid" >/dev/null 2>&1; then
    continue
  fi
  if gc session close "$sid" >/dev/null 2>&1; then
    cleared=$((cleared + 1))
    echo "[$(ts)] closed dead gate-reviewer $sid (state=$state age=${age}s, peek reported gone)" >> "$LOG"
  fi
done < <(gc session list --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sessions = d.get("sessions", d) if isinstance(d, dict) else d
for s in sessions:
    template = str(s.get("template") or "")
    if "gate-reviewer" not in template.lower():
        continue
    print("\t".join([
        str(s.get("id","")),
        str(s.get("state","")),
        str(s.get("created_at","")),
    ]))
' 2>/dev/null)

if [ "$cleared" -gt 0 ] || [ "$kept_young" -gt 0 ] || [ "$kept_creating" -gt 0 ]; then
  echo "[$(ts)] sweep: checked=$checked cleared=$cleared kept_young=$kept_young kept_creating=$kept_creating min_age_secs=$MIN_AGE_SECS" >> "$LOG"
fi
exit 0
