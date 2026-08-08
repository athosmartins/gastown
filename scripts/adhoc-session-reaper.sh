#!/usr/bin/env bash
# adhoc-session-reaper.sh — the missing reaper for EPHEMERAL adhoc agent sessions.
#
# Dispatchers (auto-refiner, gate-reviewer, refino-gate-reviewer, gastown.dog) SPAWN
# ephemeral `*-adhoc-*` sessions to do one unit of work, but NOTHING closes them when
# the work finishes → they leak. Each leaked session is an idle Claude process + a
# lingering tmux session + an open session bead. Observed 2026-06-16: 14 adhoc
# sessions lingering (oldest 11h), regrowing within a day of a manual sweep
# (ga-rl4xl). The crew-hang-detector / crew-session-reset-detector only watch NAMED
# crews, never adhoc — so these slip through. The dispatch cycle is MINUTES, so an
# adhoc session that is DRAINED/asleep and older than MIN_AGE is a finished run that
# is safe to close.
#
# SAFETY (this CLOSES sessions — mirror of the gate's own liveness discipline):
#   * ONLY ephemeral adhoc patterns are eligible (auto-refiner / gastown.dog /
#     gate-reviewer / refino-gate-reviewer + "-adhoc-"). A hard exclude on every
#     NAMED crew / core session (mila/digo/batista/oracle/peter/thies/mayor/deacon/
#     boot/control-dispatcher/gastown__) means a misclassified row can NEVER be reaped.
#   * An asleep/draining/drained session is reaped on the existing path. A session
#     that reports state=active is reaped ONLY if it has ALSO been IDLE (no last_active
#     update) for >= IDLE_MIN minutes — i.e. it finished its turn and is sitting at an
#     empty prompt, NOT mid-work. A session that is genuinely working refreshes
#     last_active continuously, so it can never satisfy the idle floor. (Observed
#     2026-06-16, ga-tads0: headless Claude adhoc reviewers/dogs finish their turn and
#     stay state="active" forever instead of going asleep, so the old active==never-reap
#     rule leaked all of them — 8 sessions, 44 sweeps, 0 reaped.)
#   * Age floor (MIN_AGE, default 30m) so a just-spawned reviewer mid-review is never
#     killed even if it momentarily reads asleep between turns.
#   * The drained/idle signal is REQUIRED together with age — we never reap on age
#     alone, and never reap on the bead alone (bead resolution is best-effort).
#   * Kill switch ADHOC_REAPER_ENABLED=0 → census/log only, no closes.
# The ONLY mutation is `gc session close` on eligible adhoc sessions. No bd writes,
# no rm of data, no Dolt surgery.
set -uo pipefail

GT=/Users/athos/gt
CITY="$GT/.gascity-gastown-hq"
LOG="$CITY/.gc/logs/adhoc-session-reaper.jsonl"
ENABLED="${ADHOC_REAPER_ENABLED:-1}"
MIN_AGE_MIN="${ADHOC_REAPER_MIN_AGE_MIN:-30}"   # don't touch a session younger than this
IDLE_MIN="${ADHOC_REAPER_IDLE_MIN:-20}"         # an "active" session must be idle (no last_active
                                                # update) at least this long before it can be reaped
GC_BIN="${ADHOC_REAPER_GC:-gc}"                 # overridable for selftest stubbing
# ga-879wu gate-feedback: list_sessions() below used to hardcode this path with no
# override, so the selftest's AHR_FIXTURE mechanism (which stubs peek/close via
# GC_BIN just fine) was silently DEAD for the "list" step — every scenario in
# adhoc-session-reaper.selftest.sh actually ran the census against this session's
# REAL, LIVE city data instead of the crafted fixture, discovered when a real
# sweep run showed 58 live sessions instead of the fixture's 1. Kept as a drop-in
# for `gc-session-list-cached.sh` (not routed through GC_BIN directly) because
# production must keep hitting the actual caching shim — that cache exists
# specifically to avoid the Dolt connect-storm this script's own header docstring
# describes; bypassing it in production would reintroduce that exact problem.
SESSION_LIST_SCRIPT="${ADHOC_REAPER_SESSION_LIST_SCRIPT:-$CITY/scripts/gc-session-list-cached.sh}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }
log() { printf '%s\n' "$1" >> "$LOG" 2>/dev/null; }

# Ephemeral adhoc prefixes the dispatchers spawn. A session name must START with one
# of these AND contain "-adhoc-" to be eligible. Discovered via `gc session list`:
#   auto-refiner-adhoc-*, gastown.dog-adhoc-*, gate-reviewer-adhoc-*,
#   refino-gate-reviewer-adhoc-*
ADHOC_PREFIXES='auto-refiner-adhoc- gastown.dog-adhoc- gate-reviewer-adhoc- refino-gate-reviewer-adhoc-'

# Named crews / core sessions — defense in depth. If a name matches ANY of these it
# is NEVER eligible, regardless of the adhoc check. (A crew would never carry
# "-adhoc-", but this guarantees a single misread row cannot close a live crew.)
NAMED_EXCLUDE_RE='(^|[-_.])(mila|digo|batista|oracle|peter|thies|mayor|deacon|boot|control-dispatcher)([-_.]|$)|gastown__'

# is_adhoc_eligible <session_name> → 0 (eligible) | 1 (not eligible).
# Pure; no I/O. Must be an adhoc prefix AND not a named/core session.
is_adhoc_eligible() {
  local name="$1" p matched=1
  # hard exclude named/core first — this wins over everything
  if printf '%s' "$name" | grep -Eq "$NAMED_EXCLUDE_RE"; then return 1; fi
  for p in $ADHOC_PREFIXES; do
    case "$name" in "$p"*) matched=0; break ;; esac
  done
  [ "$matched" = "0" ] || return 1
  case "$name" in *-adhoc-*) return 0 ;; *) return 1 ;; esac
}

# session_state_is_drained <state> → 1 (drained/idle — finished its turn) | 0.
# Pure; no I/O. The gate treats asleep as the NORMAL post-work state of a reviewer
# (session_is_dead reads asleep as ALIVE for re-spawn purposes), but for REAPING a
# FINISHED ephemeral session, asleep/draining/drained IS the done signal — combined
# with the age floor and the never-reap-active rule. "active" is the one state that
# means working RIGHT NOW → never drained.
session_state_is_drained() {
  case "$1" in
    asleep|draining|drained|dormant|suspended) echo 1 ;;
    *) echo 0 ;;   # active, or anything unknown → not the asleep-family; handled separately
  esac
}

# session_state_is_idle_candidate <state> → 1 (a "live at the prompt" state that MIGHT
# be a finished-but-not-asleep session) | 0. Pure; no I/O. These states never go through
# the drained path; they are reaped ONLY when the idle floor (last_active age) also
# passes — so a session truly working RIGHT NOW (which keeps refreshing last_active) is
# never touched. "active" is the state headless Claude adhoc sessions sit in after they
# finish their turn (they do NOT transition to asleep). idle/waiting/ready are defensive
# synonyms in case the runtime reports one of those for the same condition. Anything
# else (e.g. "running"/unknown) is NOT a candidate → kept.
session_state_is_idle_candidate() {
  case "$1" in
    active|idle|waiting|ready) echo 1 ;;
    *) echo 0 ;;
  esac
}

# session_peek_reports_dead <peek_stderr_text> → 1 (peek CONFIRMS gone) | 0.
# Verbatim mirror of the gate dispatcher's discriminator (quality-gate-dispatcher.sh):
# a drained/ended session makes `gc session peek` print "session not found: <id>" on
# STDERR. Match ONLY that explicit signal — never peek STDOUT scrollback, never a
# bare transient connection error. Any non-not-found → ALIVE, so a transient
# peek/Dolt glitch can NEVER reap a live session. Pure; no I/O.
session_peek_reports_dead() {
  case "$1" in
    *"session not found"*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# title_shows_no_task <title> <name> → 1 (CONFIRMED: session never claimed a task) | 0
# (has a task-bearing title, OR we don't have positive evidence it doesn't — fail
# SAFE, same as every other unknown in this script). Pure; no I/O. ga-dd2h0: a
# self-serve adhoc session that only ever polls for work and finds none stays
# state="active" and keeps refreshing last_active with each poll —
# idle_minutes(last_active) can therefore NEVER clear IDLE_MIN for it, so the
# idle-floor check below is permanently defeated for exactly this session class.
# title is not vulnerable to that: empirically confirmed against ga-qfewi's actual
# record (the session that triggered this bead) that a self-serve session's title
# starts out EQUAL to its own session name and is only overwritten once it claims a
# task (e.g. "gate-reviewer-1: crew/oracle/wa-54egz"). Deliberately NOT extended to
# "title is empty" — that pattern is never confirmed against a real no-task session
# (only title==name is), and treating an unconfirmed shape as equivalent to a
# confirmed one is exactly the collapsed-third-state bug this script exists to avoid
# elsewhere (idle_minutes, session_peek_reports_dead). An empty title falls through
# to the existing idle-based check below, same as before this fix.
title_shows_no_task() {
  local title="$1" name="$2"
  [ "$title" = "$name" ] && { echo 1; return 0; }
  echo 0
}

# age_minutes <created_at_rfc3339> → integer minutes since created | "" on failure.
# asleep sessions report last_active as the zero time (0001-01-01), so created_at is
# the only reliable age anchor. Mirrors the gate's _ts_to_epoch (python3 canonical,
# handles trailing Z and ±HH:MM offsets; macOS BSD date mishandles them).
age_minutes() {
  local created="$1" epoch
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
  echo $(( ( $(now_epoch) - epoch ) / 60 ))
}

# idle_minutes <last_active_rfc3339> → integer minutes since last activity | "" when it
# cannot be established (empty, unparseable, or the zero/sentinel time 0001-01-01 that
# asleep sessions report). "" means "unknown" → callers MUST fail SAFE (keep). A session
# that is actively working refreshes last_active continuously, so a large idle value is
# strong evidence the turn finished. Same python3 canonical parser as age_minutes.
idle_minutes() {
  local la="$1" epoch
  [ -z "$la" ] && { echo ""; return 0; }
  case "$la" in 0001-01-01*) echo ""; return 0 ;; esac   # zero time → unknown, fail safe
  epoch=$(python3 -c 'import sys,datetime
s=sys.argv[1].strip()
try:
    if s.endswith("Z"): s=s[:-1]+"+00:00"
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    sys.exit(1)' "$la" 2>/dev/null)
  [ -z "$epoch" ] && epoch=$(date -d "$la" +%s 2>/dev/null)
  [ -z "$epoch" ] && { echo ""; return 0; }
  echo $(( ( $(now_epoch) - epoch ) / 60 ))
}

# ---- census ---------------------------------------------------------------------
# One structured read of every session. Each line:
#   id<TAB>name<TAB>state<TAB>closed<TAB>created_at<TAB>last_active<TAB>title
# (title is LAST so the read loop can keep it as the remainder; last_active is sanitized
# of tabs defensively too.)
list_sessions() {
  bash "$SESSION_LIST_SCRIPT" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in d.get("sessions", []):
    print("\t".join([
        str(s.get("id","")),
        str(s.get("name","")),
        str(s.get("state","")),
        str(s.get("closed","")),
        str(s.get("created_at","")),
        str(s.get("last_active","")).replace("\t"," "),
        str(s.get("title","")).replace("\t"," "),
    ]))
' 2>/dev/null
}

# Sourcing guard: the selftest sources this file to unit-test the pure helpers
# above WITHOUT running a sweep. ADHOC_REAPER_SOURCE_ONLY=1 returns here.
[ "${ADHOC_REAPER_SOURCE_ONLY:-0}" = "1" ] && return 0 2>/dev/null

reaped=0; kept_young=0; kept_active=0; kept_alive_peek=0; kept_peek_inconclusive=0; skipped_other=0; would_reap=0; eligible=0

CENSUS="$(list_sessions)"
if [ -z "$CENSUS" ]; then
  log "$(printf '{"ts":"%s","event":"noop","reason":"no_sessions_or_list_failed"}' "$(ts)")"
  exit 0
fi

while IFS=$'\t' read -r id name state closed created last_active title; do
  [ -n "$name" ] || continue
  # eligibility: ephemeral adhoc + not a named/core crew
  if ! is_adhoc_eligible "$name"; then
    skipped_other=$((skipped_other+1)); continue
  fi
  eligible=$((eligible+1))

  # already closed → nothing to do
  case "$closed" in true|True|TRUE|1) skipped_other=$((skipped_other+1)); continue ;; esac

  # Classify the state. Two reapable buckets, everything else kept:
  #   drained-family (asleep/draining/drained/dormant/suspended) → existing peek-veto path
  #   idle-candidate (active/idle/waiting/ready) → reap ONLY if also idle >= IDLE_MIN
  # An unknown/other state (e.g. "running") is never reaped.
  is_drained="$(session_state_is_drained "$state")"
  is_idle_cand="$(session_state_is_idle_candidate "$state")"
  if [ "$is_drained" != "1" ] && [ "$is_idle_cand" != "1" ]; then
    kept_active=$((kept_active+1))
    log "$(printf '{"ts":"%s","event":"keep","reason":"state_not_reapable","id":"%s","name":"%s","state":"%s"}' "$(ts)" "$id" "$name" "$state")"
    continue
  fi

  # age floor — never kill a fresh one mid-review (applies to BOTH buckets)
  age=$(age_minutes "$created")
  if [ -z "$age" ]; then
    # can't establish age → fail SAFE, keep it
    skipped_other=$((skipped_other+1))
    log "$(printf '{"ts":"%s","event":"keep","reason":"age_unknown","id":"%s","name":"%s"}' "$(ts)" "$id" "$name")"
    continue
  fi
  if [ "$age" -lt "$MIN_AGE_MIN" ]; then
    kept_young=$((kept_young+1))
    log "$(printf '{"ts":"%s","event":"keep","reason":"too_young","id":"%s","name":"%s","age_min":%s,"min_age":%s}' "$(ts)" "$id" "$name" "$age" "$MIN_AGE_MIN")"
    continue
  fi

  # IDLE FLOOR for the active-but-not-asleep bucket. A finished headless adhoc session
  # sits at state="active" forever (it never goes asleep), so state alone can't tell
  # "finished" from "working". last_active is the discriminator: a session doing real
  # work refreshes it constantly, so a large idle gap means the turn ended and it is
  # parked at an empty prompt. Reap only when idle >= IDLE_MIN; unknown idle → fail SAFE.
  if [ "$is_drained" != "1" ]; then   # idle-candidate (active/idle/waiting/ready)
    if [ "$(title_shows_no_task "$title" "$name")" = "1" ]; then
      # ga-dd2h0: never claimed a task, so the idle floor below is defeated by its own
      # poll-for-work loop (see title_shows_no_task's comment) — the age floor already
      # passed above, and that's the only signal left that still means anything here.
      log "$(printf '{"ts":"%s","event":"reap_no_task","id":"%s","name":"%s","state":"%s","age_min":%s}' "$(ts)" "$id" "$name" "$state" "$age")"
      # fall through to the close block
    else
      idle=$(idle_minutes "$last_active")
      if [ -z "$idle" ]; then
        # can't establish idle (no/zero/unparseable last_active) → fail SAFE, keep it.
        # A truly working session would have a fresh last_active; absence is treated as
        # "might be live" rather than "finished".
        kept_active=$((kept_active+1))
        log "$(printf '{"ts":"%s","event":"keep","reason":"idle_unknown","id":"%s","name":"%s","state":"%s","age_min":%s}' "$(ts)" "$id" "$name" "$state" "$age")"
        continue
      fi
      if [ "$idle" -lt "$IDLE_MIN" ]; then
        # recently active → still working (or between rapid turns) → KEEP
        kept_active=$((kept_active+1))
        log "$(printf '{"ts":"%s","event":"keep","reason":"recently_active","id":"%s","name":"%s","state":"%s","age_min":%s,"idle_min":%s,"min_idle":%s}' "$(ts)" "$id" "$name" "$state" "$age" "$idle" "$IDLE_MIN")"
        continue
      fi
      # idle past the floor → finished-but-not-asleep. A peek that reports "session not
      # found" only confirms it; scrollback is just the leftover transcript of the
      # finished turn, so (unlike the drained path) it does NOT veto the reap here — the
      # idle floor already established the turn is over. Inconclusive/glitch is fine.
      peek_err="$("$GC_BIN" --city "$CITY" session peek "$id" --lines 1 2>&1 >/dev/null || true)"
      log "$(printf '{"ts":"%s","event":"reap_active_idle","id":"%s","name":"%s","state":"%s","age_min":%s,"idle_min":%s}' "$(ts)" "$id" "$name" "$state" "$age" "$idle")"
      # fall through to the close block
    fi
  else
    # drained-family path (UNCHANGED): peek is a VETO-only guard.
    # Confirmatory liveness probe (ga-h9o17 discriminator): a peek that errors
    # "session not found" CONFIRMS gone. A peek that SUCCEEDS (scrollback) means a
    # slow-but-alive session → KEEP it even though listed asleep. Inconclusive/glitch
    # → treat as alive → keep. The drained-state + age already justify reaping; peek
    # is an extra guard that can only ever VETO a reap, never force one.
    peek_err="$("$GC_BIN" --city "$CITY" session peek "$id" --lines 1 2>&1 >/dev/null || true)"
    if [ "$(session_peek_reports_dead "$peek_err")" = "1" ]; then
      : # confirmed gone → proceed to reap
    else
      # peek did NOT confirm dead. Either it succeeded (scrollback → definitely
      # alive) or it was inconclusive (a transient gc/Dolt/tmux glitch, timeout,
      # config error, etc. — peek_err holds some OTHER text, or none at all).
      # ga-879wu gate-feedback: this block's own comment above says BOTH cases
      # must KEEP — only an explicit "session not found" may ever justify a
      # reap here. The previous code only branched on peek_out non-empty and
      # let an inconclusive peek (empty peek_out, non-matching peek_err) fall
      # through past this whole if/else into the reap logic below, silently
      # contradicting the comment two lines up: a transient peek glitch against
      # a real, asleep-but-alive session (a slow reviewer, this exact session's
      # own class of process) would close it with no recovery path.
      peek_out="$("$GC_BIN" --city "$CITY" session peek "$id" --lines 1 2>/dev/null || true)"
      if [ -n "$peek_out" ]; then
        kept_alive_peek=$((kept_alive_peek+1))
        log "$(printf '{"ts":"%s","event":"keep","reason":"peek_alive","id":"%s","name":"%s","state":"%s","age_min":%s}' "$(ts)" "$id" "$name" "$state" "$age")"
      else
        kept_peek_inconclusive=$((kept_peek_inconclusive+1))
        log "$(printf '{"ts":"%s","event":"keep","reason":"peek_inconclusive","id":"%s","name":"%s","state":"%s","age_min":%s}' "$(ts)" "$id" "$name" "$state" "$age")"
      fi
      continue
    fi
  fi

  # bead hint (best-effort, advisory only — not a gate). Title carries the source
  # bead like "auto-refiner: ga-sf661 (attempt 1)".
  bead="$(printf '%s' "$title" | grep -oE 'ga-[a-z0-9]{5,7}|gt-[a-z0-9]{5,7}|wa-[a-z0-9]{4,7}' | head -1)"

  if [ "$ENABLED" != "1" ]; then
    would_reap=$((would_reap+1))
    log "$(printf '{"ts":"%s","event":"would_reap","id":"%s","name":"%s","state":"%s","age_min":%s,"bead":"%s"}' "$(ts)" "$id" "$name" "$state" "$age" "$bead")"
    continue
  fi

  # Canonical close: stops the runtime AND closes the session bead AND tears down the
  # tmux session — preferred over a raw `tmux kill-session` (which would orphan the
  # bead). Falls back to tmux kill only if close fails and the tmux session lingers.
  if "$GC_BIN" --city "$CITY" session close "$id" >/dev/null 2>&1; then
    reaped=$((reaped+1))
    log "$(printf '{"ts":"%s","event":"reaped","method":"gc_close","id":"%s","name":"%s","state":"%s","age_min":%s,"bead":"%s"}' "$(ts)" "$id" "$name" "$state" "$age" "$bead")"
  elif tmux kill-session -t "$name" 2>/dev/null; then
    reaped=$((reaped+1))
    log "$(printf '{"ts":"%s","event":"reaped","method":"tmux_kill_fallback","id":"%s","name":"%s","state":"%s","age_min":%s,"bead":"%s"}' "$(ts)" "$id" "$name" "$state" "$age" "$bead")"
  else
    skipped_other=$((skipped_other+1))
    log "$(printf '{"ts":"%s","event":"reap_failed","id":"%s","name":"%s"}' "$(ts)" "$id" "$name")"
  fi
done <<EOF
$CENSUS
EOF

log "$(printf '{"ts":"%s","event":"sweep","enabled":"%s","min_age_min":%s,"idle_min":%s,"eligible":%s,"reaped":%s,"would_reap":%s,"kept_young":%s,"kept_active":%s,"kept_alive_peek":%s,"kept_peek_inconclusive":%s,"skipped_other":%s}' \
  "$(ts)" "$ENABLED" "$MIN_AGE_MIN" "$IDLE_MIN" "$eligible" "$reaped" "$would_reap" "$kept_young" "$kept_active" "$kept_alive_peek" "$kept_peek_inconclusive" "$skipped_other")"
exit 0
