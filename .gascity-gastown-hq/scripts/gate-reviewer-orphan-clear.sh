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
# ga-2hd02v.1.23: the ga-flfo floor protected `creating` but NOT `start-pending`,
# and `start-pending` is where a session WAITS for the reconciler to wake it:
# patrol_interval=120s x max_wakes_per_tick=2 (city.toml) makes that a queue of
# 2-10 min (measured 481s on 19/10; the healthy sibling waited 279s). `gc session
# peek` answers "gone" for a runtime that has not been created yet, exactly as for
# a dead one, so at age>=360s the sweep closed a remote gate-reviewer 4s before the
# controller started it. The close (a) made the engine release the verdict bead's
# assignee and (b) left the task nudge in the closed bead's queue; the runtime came
# up anyway, was adopted under a NEW bead with the same name and an empty queue,
# and reviewed nothing for 56 min. So: start-pending has its own, much longer floor
# (it is not a death signal, only a stuck-for-ages one), and the state is re-read
# right before the close because the snapshot can be a minute old under load.
#
# TEMPORARY: remove this guard + its plist once gt-bewtm (headroom
# drained-reviewer exclusion) is merged and deployed. Tracked: gt-bewtm.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# orphan_clear_decision <state> <age_secs|""> <min_age_secs> [<start_pending_min_age_secs>] → echoes one of:
#   keep_active | keep_creating | keep_start_pending | keep_young | keep_age_unknown | eligible
# Pure; no I/O. Encodes only the FAST, list-only skip rules — "eligible" means
# the caller should proceed to the peek probe (which needs I/O and so is kept
# out of this function to stay unit-testable without a live gc/tmux).
# ga-2hd02v.1.23: state=start-pending is a session QUEUED for a wake (the reconciler starts at most
# max_wakes_per_tick per patrol_interval), not a dead one — peek cannot tell them apart because neither
# has a runtime. It is only eligible past start_pending_min_age (default 1500s = ~12 ticks); unset or
# non-numeric → the default, never "no floor".
# ga-flfo: state=creating means the session record exists but the runtime has
# not appeared yet — this is NEVER a signal of death, regardless of age, so it
# is excluded up front. The age floor (min_age) additionally protects any
# session that transitions out of "creating" before its runtime is truly ready
# to answer a peek. Unknown age (created_at missing/unparseable) fails SAFE
# (keep) — never reap on incomplete information.
orphan_clear_decision() {
  local state="$1" age="$2" min_age="$3" sp_min_age="${4:-}"
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
  case "$sp_min_age" in
    ''|*[!0-9]*) sp_min_age=1500 ;;
  esac
  if [ "$state" = "start-pending" ] && [ "$age" -lt "$sp_min_age" ]; then
    echo "keep_start_pending"; return 0
  fi
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

# orphan_clear_recheck_decision <snapshot_state> <current_state> → proceed | keep_moved | keep_unreadable
# Pure. The last gate before `gc session close`: the sweep decides on a snapshot that can be a minute old
# under load (19/10: age computed at 21:26:28, close at 21:27:25, the controller flipped the session to
# creating at 21:27:21). Only a session whose state is STILL the snapshot's may be closed.
# vazio (sessão sumiu da lista, ou a leitura falhou) → keep_unreadable: sem informação não se fecha.
orphan_clear_recheck_decision() {
  local snap="$1" cur="$2"
  [ -z "$cur" ] && { echo "keep_unreadable"; return 0; }
  if [ "$cur" = "$snap" ]; then echo "proceed"; else echo "keep_moved"; fi
}

# orphan_clear_current_state <sid> → the session's state in a FRESH `gc session list --json`.
# vazio → a sessão não está mais na lista, OU o gc falhou, OU o JSON veio ilegível — o chamador trata os
# três como "não fechar" (orphan_clear_recheck_decision); nunca devolve um estado inventado.
orphan_clear_current_state() {
  gc session list --json 2>/dev/null | python3 -c '
import sys, json
sid = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sessions = d.get("sessions", d) if isinstance(d, dict) else d
for s in sessions:
    if str(s.get("id", "")) == sid:
        print(str(s.get("state", "")))
        break
' "$1" 2>/dev/null
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

# ga-2hd02v.1.23: start-pending = waiting for a wake tick, see orphan_clear_decision. Non-numeric → default.
START_PENDING_MIN_AGE_SECS="${GATE_REVIEWER_ORPHAN_CLEAR_START_PENDING_MIN_AGE_SECS:-1500}"
case "$START_PENDING_MIN_AGE_SECS" in ''|*[!0-9]*) START_PENDING_MIN_AGE_SECS=1500 ;; esac

checked=0
cleared=0
kept_young=0
kept_creating=0
kept_start_pending=0
kept_recheck=0

NOW_EPOCH=$(now_epoch)

# Snapshot sessions once via --json: id, state, created_at for any session
# whose template contains "gate-reviewer" (substring match preserves the
# original plain-list grep's scope: covers both "gate-reviewer" and
# "refino-gate-reviewer" templates).
while IFS=$'\t' read -r sid state created; do
  [ -z "$sid" ] && continue
  age=$(session_age_secs "$created" "$NOW_EPOCH")
  decision=$(orphan_clear_decision "$state" "$age" "$MIN_AGE_SECS" "$START_PENDING_MIN_AGE_SECS")
  case "$decision" in
    keep_active) continue ;;
    keep_creating) kept_creating=$((kept_creating + 1)); continue ;;
    keep_start_pending) kept_start_pending=$((kept_start_pending + 1)); continue ;;
    keep_young) kept_young=$((kept_young + 1)); continue ;;
    keep_age_unknown) continue ;;
  esac
  # decision == "eligible" → proceed to the peek probe.
  checked=$((checked + 1))
  # peek is a pure read probe: exit 0 => alive (keep); non-zero => gone (close).
  if gc session peek "$sid" >/dev/null 2>&1; then
    continue
  fi
  # ga-2hd02v.1.23: re-read right before the close — the snapshot above is as old as the slowest peek
  # before this one. Moved on (e.g. start-pending → creating) or unreadable → keep.
  cur_state=$(orphan_clear_current_state "$sid")
  recheck=$(orphan_clear_recheck_decision "$state" "$cur_state")
  if [ "$recheck" != "proceed" ]; then
    kept_recheck=$((kept_recheck + 1))
    echo "[$(ts)] kept gate-reviewer $sid ($recheck: snapshot state=$state, now=${cur_state:-unreadable})" >> "$LOG"
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

if [ "$cleared" -gt 0 ] || [ "$kept_young" -gt 0 ] || [ "$kept_creating" -gt 0 ] || [ "$kept_start_pending" -gt 0 ] || [ "$kept_recheck" -gt 0 ]; then
  echo "[$(ts)] sweep: checked=$checked cleared=$cleared kept_young=$kept_young kept_creating=$kept_creating kept_start_pending=$kept_start_pending kept_recheck=$kept_recheck min_age_secs=$MIN_AGE_SECS start_pending_min_age_secs=$START_PENDING_MIN_AGE_SECS" >> "$LOG"
fi
exit 0
