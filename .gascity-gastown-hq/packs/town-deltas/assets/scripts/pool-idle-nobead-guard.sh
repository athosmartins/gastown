#!/usr/bin/env bash
# pool-idle-nobead-guard.sh — ga-7nxfa1 (item 2): release the pool slot held by a worker that has NO bead
# and sits idle at its prompt.
#
# THE INCIDENT (03/10): a wa-worker booted, found nothing to do, offered "look for work / drain" and
# waited at the prompt for ~30 min holding 1 of 2 pool slots => 72 approved beads, 0 in flight. Nothing
# in the city looks at "a pool session with no bead", so nothing noticed:
#   - engine idle_timeout (agents/wa-worker + ps-worker agent.toml) exists but is 2h;
#   - agent-stuck-escalation is keyed on a stale in_progress BEAD — this session had none;
#   - crew-idle-check / crew-hang-detector cover named crews, and crew-hang-detector skips every
#     "adhoc" instance on purpose (the misfired worker was wa-worker-adhoc-...).
#
# THE SIGNAL, and why it is a CONJUNCTION. All of these must hold, each readable, before anything is done:
#   1. session is active, not human-attached, and its template is a pool template (POOL_TEMPLATES);
#   2. `last_active` is older than IDLE_SEC. MEASURED 03/10: last_active is a PANE-ACTIVITY clock — it
#      stayed 0-1 s old for a whole silent 105 s tool call (the spinner timer repaints the pane) — so a
#      long test run is NOT idle by this clock; only a session sitting still at the prompt is;
#   3. the pane is classifiable AND idle (no spinner/elapsed timer; a prompt or a past-tense summary is
#      showing). A frozen mid-turn pane is a HANG, which is crew-hang-detector's job, not this one's;
#   4. NO bead belongs to the session in the city DB or the session's own rig DB: open/in_progress/blocked/
#      hooked/deferred beads and open/in_progress wisps, matched by assignee (session id, name, alias or
#      session_name) or by the gc.session_name in the bead's metadata. A session that holds a bead is never
#      touched (agent-stuck-escalation owns that case). "Idle for N minutes" alone is exactly the weak
#      signal the city refuses to act on. A bead recorded under some OTHER identifier would not be seen —
#      which is why the kill needs a nudge, a grace period and a second idle pane first.
# THREE STATES, never collapsed: for the bead check and the pane check "could not tell" (timeout, bad
# JSON, empty pane, rig not found) is UNKNOWN and means DO NOTHING — it never reads as "no bead".
#
# THE ACTION, with due process: first a NUDGE asking the worker to drain-ack and exit (the graceful
# path the engine already honours: "drain acknowledged by agent"). Only if it is still bead-less and idle
# GRACE_SEC later is the session killed — safe because it holds no work. Caps per pass (nudges, kills)
# bound the damage of any bug in this script; kill can be turned off with POOL_IDLE_KILL=0.
#
# SAFETY VALVES: DRY_RUN=1 (decide + log; sends no nudge, kills nothing, writes/removes no nudge state —
# it still creates the empty state dir and the lock file); kill-switch file
# $STATE_ROOT/pool-idle-nobead-guard.disabled; single instance via flock; every gc/bd call is bounded by
# `timeout`; always exits 0 (an order tick must not page anyone because gc was briefly unavailable).
# Runs as a gc order (see orders/pool-idle-nobead-guard.toml), never a raw plist.
#
# bash 3.2-safe on purpose (no arrays/assoc arrays/mapfile): the gate parses scripts under macOS bash 3.2.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
BD="${BD:-bd}"
STATE_ROOT="${POOL_IDLE_STATE_ROOT:-$CITY/.gc/state}"
SESS_STATE="$STATE_ROOT/pool-idle-nobead"
KILL_SWITCH="$STATE_ROOT/pool-idle-nobead-guard.disabled"
LOG="${POOL_IDLE_LOG:-$CITY/.gc/logs/pool-idle-nobead-guard.log}"
LOCK_FILE="${POOL_IDLE_LOCK:-$CITY/.gc/runtime/pool-idle-nobead-guard.lock}"

POOL_TEMPLATES="${POOL_IDLE_TEMPLATES:-wa-worker ps-worker}"
IDLE_SEC="${POOL_IDLE_SEC:-600}"            # idle this long (and bead-less) => nudge
GRACE_SEC="${POOL_IDLE_GRACE_SEC:-600}"     # still bead-less + idle this long after the nudge => kill
KILL_ENABLED="${POOL_IDLE_KILL:-1}"
MAX_NUDGES="${POOL_IDLE_MAX_NUDGES:-3}"
MAX_KILLS="${POOL_IDLE_MAX_KILLS:-1}"
PEEK_LINES="${POOL_IDLE_PEEK_LINES:-40}"
CALL_TIMEOUT="${POOL_IDLE_CALL_TIMEOUT:-40}"
PASS_BUDGET_SEC="${POOL_IDLE_PASS_BUDGET_SEC:-240}"   # a wedged bd must not stretch one order tick indefinitely
DRY_RUN="${DRY_RUN:-0}"
NOW="${POOL_IDLE_NOW:-$(date +%s)}"         # overridable so the selftest is deterministic

mkdir -p "$(dirname "$LOG")" "$SESS_STATE" "$(dirname "$LOCK_FILE")" 2>/dev/null || true
if [ "$DRY_RUN" != "1" ]; then exec >> "$LOG" 2>&1; fi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pool-idle] $*"; }

if [ -f "$KILL_SWITCH" ]; then log "kill-switch present ($KILL_SWITCH) — no-op"; exit 0; fi

exec 9>"$LOCK_FILE" || { log "cannot open lock $LOCK_FILE — exiting (no single-instance guarantee)"; exit 0; }
flock -n 9 || { log "another instance holds $LOCK_FILE — exiting"; exit 0; }

log "=== pass start (IDLE_SEC=$IDLE_SEC GRACE_SEC=$GRACE_SEC KILL=$KILL_ENABLED DRY_RUN=$DRY_RUN templates=[$POOL_TEMPLATES]) ==="

SESS_JSON="$(timeout "$CALL_TIMEOUT" "$GC" session list --json 2>/dev/null || true)"
if [ -z "$SESS_JSON" ]; then log "WARN: empty/failed session list — skipping pass (UNKNOWN, no action)"; exit 0; fi

# Candidates, one per line: name|id|alias|session_name|template|work_dir|idle_age_sec
# (non-whitespace delimiter on purpose: `read` would collapse empty tab-separated fields)
CAND_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-idle-cand.XXXXXX")"
RIGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-idle-rigs.XXXXXX")"
trap 'rm -f "$CAND_FILE" "$RIGS_FILE"' EXIT
printf '%s' "$SESS_JSON" | POOL_TEMPLATES="$POOL_TEMPLATES" NOW="$NOW" python3 -c '
import json, sys, os, datetime
pools = os.environ["POOL_TEMPLATES"].split()
now = float(os.environ["NOW"])
def ts(v):
    try:
        t = datetime.datetime.fromisoformat(v).timestamp()
    except Exception:
        return None
    return t if t > 86400 * 365 else None      # "0001-01-01..." = never active
try:
    data = json.load(sys.stdin)
    sessions = data["sessions"]
    assert isinstance(sessions, list)
except Exception:
    sys.exit(3)          # unparseable / no "sessions" list: NOT the same as "zero sessions"
for s in sessions:
    if s.get("state") != "active" or s.get("attached"):
        continue
    if (s.get("template") or "") not in pools:
        continue
    base = ts(s.get("last_active") or "") or ts(s.get("created_at") or "")
    if base is None:
        continue                                 # cannot date it -> UNKNOWN -> not a candidate
    f = [s.get(k) or "" for k in ("name", "id", "alias", "session_name", "template", "work_dir")]
    if not f[0] or any("|" in x for x in f):
        continue
    print("|".join(f + [str(int(now - base))]))
' > "$CAND_FILE" 2>/dev/null
PY_RC=$?
if [ "$PY_RC" -ne 0 ]; then log "WARN: session list could not be parsed (python exit $PY_RC) — skipping pass (UNKNOWN, no action)"; exit 0; fi
NCAND="$(wc -l < "$CAND_FILE" | tr -d ' ')"
log "pool candidates (active, unattached, pool template): $NCAND"

# Same busy test crew-hang-detector uses: a running turn shows "<Gerund>… (<elapsed>s ·" or
# "esc to interrupt"; an idle pane shows a past-tense summary / the prompt instead.
is_active_work() {
  printf '%s' "$1" | grep -E '(…|\.\.\.)[^(]*\(([0-9]+m[[:space:]]+)?[0-9]+s' >/dev/null && return 0
  printf '%s' "$1" | grep 'esc to interrupt' >/dev/null && return 0
  return 1
}

# pane_state <session>  -> IDLE | BUSY | UNKNOWN
pane_state() {
  local pane
  pane="$(timeout "$CALL_TIMEOUT" "$GC" session peek "$1" --lines "$PEEK_LINES" 2>/dev/null)" || { echo UNKNOWN; return; }
  [ -z "$pane" ] && { echo UNKNOWN; return; }
  if is_active_work "$pane"; then echo BUSY; return; fi
  # idle must be POSITIVELY recognised: the prompt glyph or a "<Verb>ed for <duration>" summary
  if printf '%s' "$pane" | grep -E '❯|[A-Za-z]+ for ([0-9]+m )?[0-9]+s' >/dev/null; then echo IDLE; else echo UNKNOWN; fi
}

# rig_db_for <work_dir> -> the longest rig path that is a prefix of work_dir; empty if none/unreadable
rig_db_for() {
  if [ ! -s "$RIGS_FILE" ]; then
    timeout "$CALL_TIMEOUT" "$GC" rig list --json 2>/dev/null > "$RIGS_FILE" || { : > "$RIGS_FILE"; return 1; }
  fi
  python3 - "$1" "$RIGS_FILE" <<'PY' 2>/dev/null
import json, sys
wd = sys.argv[1].rstrip("/") + "/"
try:
    rigs = json.load(open(sys.argv[2])).get("rigs", [])
except Exception:
    sys.exit(1)
best = ""
for r in rigs:
    p = (r.get("path") or "").rstrip("/")
    if p and wd.startswith(p + "/") and len(p) > len(best):
        best = p
print(best)
PY
}

# count_assigned <db> <ids>: prints how many beads in <db> belong to the session: open/in_progress/blocked/
# hooked/deferred beads, plus OPEN and IN_PROGRESS wisps (other wisp statuses are not read). A bead belongs
# to it when its assignee, or the gc.session_name the engine stamps in its metadata, is one of <ids>.
# Returns non-zero if ANY read failed (=> UNKNOWN, never "zero").
count_assigned() {
  local db="$1" ids="$2" out n total=0 step
  for step in list wisp_in_progress wisp_open; do
    case "$step" in
      list)           out="$(timeout "$CALL_TIMEOUT" "$BD" -C "$db" list --status open,in_progress,blocked,hooked,deferred --json --limit 0 2>/dev/null)" || return 1 ;;
      wisp_in_progress) out="$(timeout "$CALL_TIMEOUT" "$BD" -C "$db" query --json 'ephemeral=true AND status=in_progress' --limit=0 2>/dev/null)" || return 1 ;;
      wisp_open)      out="$(timeout "$CALL_TIMEOUT" "$BD" -C "$db" query --json 'ephemeral=true AND status=open' --limit=0 2>/dev/null)" || return 1 ;;
    esac
    n="$(printf '%s' "$out" | jq -e --arg ids "$ids" '($ids | split(" ")) as $mine | [.[] | select((((.assignee // "") as $a | $mine | index($a)) != null) or ((((.metadata // {})["gc.session_name"] // "") as $s | $mine | index($s)) != null))] | length' 2>/dev/null)" || return 1
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    total=$((total + n))
  done
  echo "$total"
}

# bead_state <id> <name> <alias> <session_name> <work_dir>  -> NONE | HAS:<n> | UNKNOWN:<why>
bead_state() {
  local ids rig n total=0 db
  ids="$(printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ -z "$ids" ] && { echo "UNKNOWN:no-session-identifier"; return; }
  rig="$(rig_db_for "$5")" || { echo "UNKNOWN:rig-list-unreadable"; return; }
  [ -z "$rig" ] && { echo "UNKNOWN:no-rig-for-work_dir($5)"; return; }
  for db in "$CITY" "$rig"; do
    n="$(count_assigned "$db" "$ids")" || { echo "UNKNOWN:bead-read-failed($db)"; return; }
    total=$((total + n))
    [ "$rig" = "$CITY" ] && break
  done
  if [ "$total" -gt 0 ]; then echo "HAS:$total"; else echo NONE; fi
}

# state is only ever written/removed on a real pass: DRY_RUN must leave the world exactly as it found it
forget() { [ "$DRY_RUN" = "1" ] || rm -f "$1"; }

NUDGES=0; KILLS=0; SEEN=""
NUDGE_MSG="pool-idle-nobead-guard (ga-7nxfa1): no bead is assigned to this session and its pane has been idle for a while. If you have nothing to work on, run gc runtime drain-ack and then exit so the pool slot is released. If you do have work, claim it now (bd update <id> --claim) and continue."

PASS_START="$(date +%s)"   # real clock on purpose (NOW is overridable): the budget bounds wall time
while IFS='|' read -r name sid alias sname tmpl wdir idle; do
  [ -z "$name" ] && continue
  SEEN="$SEEN $name "
  # a malformed candidate line must not fall through as "idle": `[ "" -lt 600 ]` errors, which tests false
  case "$idle" in ''|-|*[!0-9-]*) log "$name: candidate line has a non-numeric idle age ('$idle') — UNKNOWN, skipping"; continue ;; esac
  if [ $(( $(date +%s) - PASS_START )) -gt "$PASS_BUDGET_SEC" ]; then
    log "pass budget ${PASS_BUDGET_SEC}s spent — leaving $name and the rest for the next pass"; continue
  fi
  stf="$SESS_STATE/$name.nudged"
  nudged_at=""
  if [ -f "$stf" ]; then
    nudged_at="$(cat "$stf" 2>/dev/null)"
    case "$nudged_at" in ''|*[!0-9]*) nudged_at="" ;; esac
    # our own state is stale (the session went on to do other things): start the cycle over
    if [ -n "$nudged_at" ] && [ $((NOW - nudged_at)) -gt $((3 * GRACE_SEC)) ]; then forget "$stf"; nudged_at=""; fi
  fi
  # not idle long enough, and we have not already nudged it => nothing to look at
  if [ -z "$nudged_at" ] && [ "$idle" -lt "$IDLE_SEC" ]; then continue; fi

  pstate="$(pane_state "$name")"
  case "$pstate" in
    IDLE) ;;
    BUSY) log "$name: pane busy (turn running) — leave to crew-hang-detector if it freezes"; continue ;;
    *)    log "$name: pane UNKNOWN (empty/unreadable/unclassifiable) — no action"; continue ;;
  esac
  bs="$(bead_state "$sid" "$name" "$alias" "$sname" "$wdir")"
  case "$bs" in
    NONE) ;;
    HAS:*) log "$name: holds a bead (${bs#HAS:} assigned) — not ours to touch"; forget "$stf"; continue ;;
    *)     log "$name: bead state ${bs} — UNKNOWN, no action"; continue ;;
  esac

  # idle pane + provably no bead
  if [ -z "$nudged_at" ]; then
    if [ "$NUDGES" -ge "$MAX_NUDGES" ]; then log "$name: eligible for nudge but MAX_NUDGES=$MAX_NUDGES reached this pass"; continue; fi
    NUDGES=$((NUDGES + 1))
    if [ "$DRY_RUN" = "1" ]; then log "$name ($tmpl): DRY_RUN would NUDGE — idle ${idle}s, no bead"; continue; fi
    if timeout "$CALL_TIMEOUT" "$GC" session nudge "$name" "$NUDGE_MSG" >/dev/null 2>&1; then
      echo "$NOW" > "$stf"; log "$name ($tmpl): NUDGED — idle ${idle}s, no bead assigned, drain requested"
    else
      log "$name ($tmpl): nudge FAILED — will retry next pass"
    fi
  else
    waited=$((NOW - nudged_at))
    if [ "$waited" -lt "$GRACE_SEC" ] || [ "$idle" -lt $((GRACE_SEC / 2)) ]; then
      log "$name: nudged ${waited}s ago, idle ${idle}s — within grace"; continue
    fi
    if [ "$KILL_ENABLED" != "1" ]; then log "$name: still idle + bead-less ${waited}s after nudge — KILL disabled (POOL_IDLE_KILL=0), no action"; continue; fi
    if [ "$KILLS" -ge "$MAX_KILLS" ]; then log "$name: eligible for kill but MAX_KILLS=$MAX_KILLS reached this pass"; continue; fi
    KILLS=$((KILLS + 1))
    if [ "$DRY_RUN" = "1" ]; then log "$name ($tmpl): DRY_RUN would KILL — ${waited}s after nudge, still idle, no bead"; continue; fi
    if timeout "$CALL_TIMEOUT" "$GC" session kill "$name" >/dev/null 2>&1; then
      forget "$stf"; log "$name ($tmpl): KILLED — ${waited}s after nudge, still idle at the prompt with no bead; pool slot released"
    else
      log "$name ($tmpl): kill FAILED — will retry next pass"
    fi
  fi
done < "$CAND_FILE"

# forget state for sessions that are gone / no longer candidates
for f in "$SESS_STATE"/*.nudged; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .nudged)"
  case "$SEEN" in *" $n "*) ;; *) forget "$f" ;; esac
done

log "=== pass end (nudged=$NUDGES killed=$KILLS) ==="
exit 0
