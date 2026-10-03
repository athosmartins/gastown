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
#   3. the pane shows NO sign of a running turn: no spinner timer (any of "(12s", "(3m 4s", "(1h 31m 47s"),
#      no "esc to interrupt", and no spinner-shaped line whose timer we cannot read (that is UNKNOWN, not
#      idle) — and it is a Claude Code pane we recognise (its prompt box, or a past-tense "<Verb> for <dur>"
#      summary). Be exact about what this leg is: "no activity marker found", NOT "idle proven". The prompt
#      glyph is drawn on busy panes too (measured 03/10 on 3 live panes), so it only says "this is a TUI";
#      the independent evidence of idleness is leg 2 (the pane-activity clock) and leg 4 (no bead). Leg 3
#      is what fails safe (UNKNOWN) when the TUI changes its look. A frozen mid-turn pane is a HANG, and this
#      guard leaves it alone (BUSY => no action). It is NOT covered by crew-hang-detector either: that
#      detector skips every "adhoc" instance, and every session this guard can see is one. The only net
#      under a frozen adhoc pool pane is the engine's 2h idle_timeout (wa-worker/ps-worker agent.toml);
#   4. NO bead belongs to the session in the city DB or the session's own rig DB: open/in_progress/blocked/
#      hooked/deferred beads and open/in_progress wisps, matched by assignee (session id, name, alias or
#      session_name) or by the gc.session_name in the bead's metadata. A session that holds a bead is never
#      touched (agent-stuck-escalation owns that case). "Idle for N minutes" alone is exactly the weak
#      signal the city refuses to act on. A bead recorded under some OTHER identifier would not be seen —
#      which is why the close needs a nudge, a grace period and a second idle pane first.
# THREE STATES, never collapsed: for the bead check and the pane check "could not tell" (timeout, bad
# JSON, empty pane, rig not found) is UNKNOWN and means DO NOTHING — it never reads as "no bead".
#
# THE ACTION, with due process: first a NUDGE asking the worker to drain-ack and exit (the graceful
# path the engine already honours: "drain acknowledged by agent"). A nudge has THREE outcomes, never two:
# `gc session nudge` defaults to --delivery wait-idle, which degrades to a QUEUE when the target is not at
# a safe boundary — still exit 0, and the text is only drained by the target's next prompt. So the guard
# asks for --json and reads `.outcome`: "delivered" => the worker was warned; "queued" (or an outcome we
# cannot read) => it may never have seen it. A queued nudge does NOT arm the close stage and is NOT
# re-enqueued every pass (duplicates would all drain at once): it waits QUEUE_WAIT_SEC, then — after the
# pane and bead legs have just been re-checked — is re-sent once with --delivery immediate. Nothing is
# ever closed on the strength of a warning that was not confirmed delivered.
# Only if it is still bead-less and idle GRACE_SEC after a DELIVERED nudge is the session
# CLOSED (`gc session close`: stops the runtime and closes the session bead
# — the verb the city already uses to free a session: crew-capacity-containment.sh, the gate reviewers) —
# safe because it holds no work. NOT `gc session kill`: per its own help, kill leaves the session marked
# active so the reconciler restarts it, i.e. it frees nothing and the slot stays counted against the pool
# cap. And an exit code is only "asked", never "done": after a close the session list is re-read and the
# outcome is logged as RELEASED / STILL ACTIVE / UNVERIFIED — the log never says "slot released" on faith.
# Caps per pass (nudges, closes) bound the damage of any bug in this script; the close stage can be turned
# off with POOL_IDLE_CLOSE=0.
#
# STATE (one file per nudged session, $SESS_STATE/<name>.nudged) is written BEFORE the nudge is sent and
# the nudge is sent only if that write verifiably landed: an unrecorded nudge would be re-sent every pass
# (an agent turn each time) and the grace period would never start. The file reads "nudging <ts>" while the
# send is unconfirmed, "queued <ts>" when gc queued it instead of delivering it (or gave an unreadable
# answer), and "nudged <ts>" only once gc reported it DELIVERED; only "nudged" can ever lead to a close. A
# state that cannot be written or removed is logged loudly as STATE-ERROR and counted in the pass summary.
#
# SAFETY VALVES: DRY_RUN=1 (decide + log; sends no nudge, closes nothing, writes/removes no nudge state —
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
GRACE_SEC="${POOL_IDLE_GRACE_SEC:-600}"     # still bead-less + idle this long after a DELIVERED nudge => close
QUEUE_WAIT_SEC="${POOL_IDLE_QUEUE_WAIT_SEC:-600}"   # a QUEUED (not delivered) nudge waits this long, then is re-sent --delivery immediate
CLOSE_ENABLED="${POOL_IDLE_CLOSE:-1}"
MAX_NUDGES="${POOL_IDLE_MAX_NUDGES:-3}"
MAX_CLOSES="${POOL_IDLE_MAX_CLOSES:-1}"
PEEK_LINES="${POOL_IDLE_PEEK_LINES:-40}"
CALL_TIMEOUT="${POOL_IDLE_CALL_TIMEOUT:-40}"
PASS_BUDGET_SEC="${POOL_IDLE_PASS_BUDGET_SEC:-240}"   # a wedged bd must not stretch one order tick indefinitely
DRY_RUN="${DRY_RUN:-0}"
NOW="${POOL_IDLE_NOW:-$(date +%s)}"         # overridable so the selftest is deterministic

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK_FILE")" 2>/dev/null || true
mkdir -p "$SESS_STATE" 2>/dev/null || true       # a failure here is NOT swallowed: see the dir check below
if [ "$DRY_RUN" != "1" ]; then exec >> "$LOG" 2>&1; fi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pool-idle] $*"; }

if [ -f "$KILL_SWITCH" ]; then log "kill-switch present ($KILL_SWITCH) — no-op"; exit 0; fi

exec 9>"$LOCK_FILE" || { log "cannot open lock $LOCK_FILE — exiting (no single-instance guarantee)"; exit 0; }
# three states: lock taken / lock held by someone else / flock itself missing (rc 127 from a PATH without
# /opt/homebrew/bin) — the last must not read as "held", or the guard would silently never run
command -v flock >/dev/null 2>&1 || { log "ERROR: flock not found on PATH ($PATH) — cannot take the single-instance lock, exiting WITHOUT running (this is not 'another instance holds it')"; exit 0; }
flock -n 9 || { log "another instance holds $LOCK_FILE — exiting"; exit 0; }

log "=== pass start (IDLE_SEC=$IDLE_SEC GRACE_SEC=$GRACE_SEC CLOSE=$CLOSE_ENABLED DRY_RUN=$DRY_RUN templates=[$POOL_TEMPLATES]) ==="
# Unusable state dir => every nudge would go unrecorded. Say so once up front; the per-session write check
# below is what actually stops the nudge (this line only makes the cause obvious in the log).
if [ "$DRY_RUN" != "1" ] && { [ ! -d "$SESS_STATE" ] || [ ! -w "$SESS_STATE" ]; }; then
  log "STATE-ERROR: state dir $SESS_STATE is missing or not writable — no nudge will be sent this pass"
fi

SESS_JSON="$(timeout "$CALL_TIMEOUT" "$GC" session list --json 2>/dev/null || true)"
if [ -z "$SESS_JSON" ]; then log "WARN: empty/failed session list — skipping pass (UNKNOWN, no action)"; exit 0; fi

# Candidates, one per line: name|id|alias|session_name|template|work_dir|idle_age_sec
# (non-whitespace delimiter on purpose: `read` would collapse empty tab-separated fields)
CAND_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-idle-cand.XXXXXX")"
RIGS_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-idle-rigs.XXXXXX")"
SKIP_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-idle-skip.XXXXXX")"
trap 'rm -f "$CAND_FILE" "$RIGS_FILE" "$SKIP_FILE"' EXIT
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
    f = [s.get(k) or "" for k in ("name", "id", "alias", "session_name", "template", "work_dir")]
    base = ts(s.get("last_active") or "") or ts(s.get("created_at") or "")
    # A session we cannot date or cannot safely serialise is UNKNOWN => not a candidate. It is COUNTED and
    # named (stderr -> $SKIP_FILE), never dropped silently: if gc ever changes its timestamp format every
    # session would vanish here and "0 candidates" would read as "nothing is idle".
    if base is None:
        sys.stderr.write("skip:undatable:%s\n" % (f[0] or "?")); continue
    if not f[0] or any("|" in x for x in f):
        sys.stderr.write("skip:unsafe-field:%s\n" % (f[0] or "?")); continue
    print("|".join(f + [str(int(now - base))]))
' > "$CAND_FILE" 2> "$SKIP_FILE"
PY_RC=$?
if [ "$PY_RC" -ne 0 ]; then log "WARN: session list could not be parsed (python exit $PY_RC) — skipping pass (UNKNOWN, no action)"; exit 0; fi
NCAND="$(wc -l < "$CAND_FILE" | tr -d ' ')"
# grep -c: rc 0 = some, 1 = none, >=2 = could not read the report. The last must not read as "none skipped".
NSKIP="$(grep -c '^skip:' "$SKIP_FILE" 2>/dev/null)"; SKIP_RC=$?
case "$SKIP_RC" in 0|1) ;; *) NSKIP="?"; log "WARN: the skip report $SKIP_FILE could not be read (grep exit $SKIP_RC) — how many sessions were skipped is UNKNOWN" ;; esac
log "pool candidates (active, unattached, pool template): $NCAND"
case "$NSKIP" in ''|*[!0-9]*) ;; *)
  if [ "$NSKIP" -gt 0 ]; then
    log "WARN: $NSKIP pool session(s) skipped as UNKNOWN (cannot be dated or serialised): $(grep '^skip:' "$SKIP_FILE" | tr '\n' ' ')"
  fi ;;
esac

# What a Claude Code pane looks like (MEASURED 03/10 on the live wa-workers):
#   running:  "✢ Kneading… (1h 31m 47s · ↓ 298.6k tokens)"   <- the elapsed timer has an HOURS unit
#   finished: "✻ Cooked for 1h 1m 30s · done 10:22 AM · 3 shells, 1 monitor still running"
#   and the prompt box "❯" is drawn on BOTH — it says "this is a Claude Code pane", not "this pane is idle".
# The first version of this test had no hours unit: a turn past 1 h read as idle (and so did "1h" summaries).
DUR='([0-9]+h[[:space:]]+)?([0-9]+m[[:space:]]+)?[0-9]+s'
SPIN_GLYPH='(✻|✽|✳|✶|✢|✺|✹|·|\*)'
# Same busy test as crew-hang-detector.sh (which carries the same hours unit since ga-lozfor): a running turn
# shows "<Verb>… (<elapsed>" or, on older builds, "esc to interrupt".
is_active_work() {
  printf '%s' "$1" | grep -E "(…|\.\.\.)[^(]*\\(${DUR}" >/dev/null && return 0
  printf '%s' "$1" | grep 'esc to interrupt' >/dev/null && return 0
  return 1
}
# A spinner-shaped line ("<glyph> <Verb>…") whose timer is_active_work could not read: something is probably
# running in a shape we do not know. That is UNKNOWN — it must never fall through to IDLE.
has_unreadable_spinner() {
  printf '%s' "$1" | grep -E "^[[:space:]]*${SPIN_GLYPH}[[:space:]]+[^[:space:]]+(…|\.\.\.)" >/dev/null
}
# A finished turn's summary line: "<glyph> <Verb> for <dur>".
has_turn_summary() {
  printf '%s' "$1" | grep -E "^[[:space:]]*${SPIN_GLYPH}[[:space:]]+[^[:space:]]+ for ${DUR}" >/dev/null
}

# pane_state <session>  -> IDLE | BUSY | UNKNOWN
#   BUSY    a timer / "esc to interrupt" is showing
#   UNKNOWN empty or unreadable pane; a spinner-shaped line we cannot read; or nothing we recognise as a
#           Claude Code pane (neither its prompt box nor a turn summary)
#   IDLE    a recognised pane with NO activity marker in view. That is "nothing found", not "idle proven" —
#           see leg 3 in the header for what carries the rest.
pane_state() {
  local pane
  pane="$(timeout "$CALL_TIMEOUT" "$GC" session peek "$1" --lines "$PEEK_LINES" 2>/dev/null)" || { echo UNKNOWN; return; }
  [ -z "$pane" ] && { echo UNKNOWN; return; }
  if is_active_work "$pane"; then echo BUSY; return; fi
  if has_unreadable_spinner "$pane"; then echo UNKNOWN; return; fi
  if printf '%s' "$pane" | grep '❯' >/dev/null || has_turn_summary "$pane"; then echo IDLE; else echo UNKNOWN; fi
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

# ---- state ------------------------------------------------------------------------------------------------
# State is only ever written/removed on a real pass: DRY_RUN must leave the world exactly as it found it.
# A write or a removal that did not happen is NEVER swallowed: it is logged as STATE-ERROR and counted in the
# pass summary. A write that did not land makes the caller abstain from the nudge (a nudge whose record is
# lost would repeat every pass). A removal that did not happen leaves the old record in place; every close
# decision still re-checks pane and beads first, so the worst a stale "nudged" record can do is skip the
# second warning for a session that is idle and provably bead-less right now.
STATE_ERRORS=0
state_err() { STATE_ERRORS=$((STATE_ERRORS + 1)); log "STATE-ERROR: $*"; }

# write_state <file> <content> -> 0 only if <content> is verifiably on disk (temp file + mv, then read back).
# The braces keep bash's own redirection error ("Permission denied") out of the log.
write_state() {
  local f="$1" want="$2" tmp="$1.tmp.$$"
  { printf '%s\n' "$want" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null && [ "$(cat "$f" 2>/dev/null)" = "$want" ] && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# forget <file> -> 0 if the file is gone afterwards (or DRY_RUN), 1 + STATE-ERROR if it is still there
forget() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ -e "$1" ] || return 0
  rm -f "$1" 2>/dev/null
  if [ -e "$1" ]; then state_err "cannot remove $1 — it will keep steering later passes until it is removed by hand"; return 1; fi
  return 0
}

# ---- outcome of a close ------------------------------------------------------------------------------------
# slot_state <session-name> -> RELEASED | HELD | UNKNOWN. Re-reads the session list (default view = active and
# suspended sessions; a closed one drops out). "active" and "creating" are what the pool cap counts
# (pilot: "pool at session cap (N active/creating >= max)"), so those two mean the slot is still HELD.
# An unreadable list is UNKNOWN: it must not turn into either answer.
slot_state() {
  local json out
  json="$(timeout "$CALL_TIMEOUT" "$GC" session list --json 2>/dev/null)" || { echo UNKNOWN; return; }
  [ -z "$json" ] && { echo UNKNOWN; return; }
  out="$(printf '%s' "$json" | WHO="$1" python3 -c '
import json, os, sys
try:
    sessions = json.load(sys.stdin)["sessions"]
    assert isinstance(sessions, list)
except Exception:
    print("UNKNOWN"); sys.exit(0)
mine = [s for s in sessions if s.get("name") == os.environ["WHO"]]
print("HELD" if any(s.get("state") in ("active", "creating") for s in mine) else "RELEASED")
' 2>/dev/null)" || out=UNKNOWN
  case "$out" in HELD|RELEASED) echo "$out" ;; *) echo UNKNOWN ;; esac
}

NUDGES=0; CLOSES=0; RELEASED=0; HELD=0; UNVERIFIED=0; QUEUED=0; QWAIT=0; SEEN=""
NUDGE_MSG="pool-idle-nobead-guard (ga-7nxfa1): no bead is assigned to this session and its pane has been idle for a while. If you have nothing to work on, run gc runtime drain-ack and then exit so the pool slot is released. If you do have work, claim it now (bd update <id> --claim) and continue."

# send_nudge <session> <delivery-mode> -> DELIVERED | QUEUED | UNREADABLE | FAILED:<rc>
# rc 0 only means "gc accepted the request": under wait-idle it also exits 0 when it merely QUEUED the text
# (measured: {"ok":true,"delivery":"wait-idle","queued":true,"outcome":"queued"}, same rc 0 without --json).
# `gc session nudge --json-schema=result` => outcome in {delivered, queued}. Anything else (rc 0 with output we
# cannot parse, ok != true, an outcome outside the enum) is UNREADABLE and is treated like QUEUED by the
# caller — "I cannot tell that the worker saw it" is not "the worker was warned".
send_nudge() {
  local out rc oc
  out="$(timeout "$CALL_TIMEOUT" "$GC" session nudge "$1" "$NUDGE_MSG" --delivery "$2" --json 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && { echo "FAILED:$rc"; return; }
  oc="$(printf '%s' "$out" | jq -er 'select(.ok == true) | .outcome' 2>/dev/null)" || oc=""
  case "$oc" in delivered) echo DELIVERED ;; queued) echo QUEUED ;; *) echo UNREADABLE ;; esac
}

# nudge_session <session> <template> <delivery-mode> <idle-sec> <state-file>
# Records the attempt FIRST ("nudging <ts>") and sends only if that write verifiably landed. Then, by outcome:
#   DELIVERED            => "nudged <ts>"   (the only state that arms the close stage)
#   QUEUED / UNREADABLE  => "queued <ts>"   (worker may not have seen it: no close, no re-enqueue for QUEUE_WAIT_SEC)
#   FAILED:<rc>          => stays "nudging" (not nudged; retried next pass; rc 124 = may still have gone out)
nudge_session() {
  local name="$1" tmpl="$2" mode="$3" idle="$4" f="$5" res why
  if ! write_state "$f" "nudging $NOW"; then
    state_err "$name ($tmpl): cannot record state in $SESS_STATE — NOT nudging (an unrecorded nudge would repeat every pass)"
    return
  fi
  res="$(send_nudge "$name" "$mode")"
  case "$res" in
    DELIVERED)
      if write_state "$f" "nudged $NOW"; then
        log "$name ($tmpl): NUDGED (delivered, --delivery $mode) — idle ${idle}s, no bead assigned, drain requested"
      else
        state_err "$name ($tmpl): nudge was DELIVERED but its confirmation could not be recorded — it will be nudged again next pass"
      fi ;;
    QUEUED|UNREADABLE)
      QUEUED=$((QUEUED + 1))
      if [ "$res" = QUEUED ]; then
        why="gc QUEUED the nudge instead of delivering it (target not at a safe boundary; it drains at the worker's next prompt)"
      else
        why="gc returned 0 but no readable delivery outcome (cannot tell it was delivered)"
      fi
      if write_state "$f" "queued $NOW"; then
        log "$name ($tmpl): QUEUED, not delivered (--delivery $mode) — $why. The worker may never have seen the warning, so the close stage is NOT armed; waiting ${QUEUE_WAIT_SEC}s before one --delivery immediate re-send"
      else
        state_err "$name ($tmpl): nudge was QUEUED but that could not be recorded — it stays 'nudging' and will be re-sent next pass"
      fi ;;
    *)
      # rc 124 = our timeout cut the call: the nudge may still have been delivered. We do not know, so it
      # stays "nudging" (= not nudged) and is retried; the worst case is one duplicate nudge.
      log "$name ($tmpl): nudge NOT CONFIRMED (rc=${res#FAILED:}; 124 = timed out, may still have been delivered or queued) — will retry next pass" ;;
  esac
}

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
  kind=""; rec_at=""
  if [ -f "$stf" ]; then
    # Only "nudged <ts>" (gc reported the nudge DELIVERED) can ever lead to a close. "queued <ts>" (gc queued
    # it / answered unreadably), "nudging <ts>" (sent, not confirmed) and anything unreadable/garbled count
    # as "not warned yet": the cycle goes on with a nudge, never with a close the worker was not warned about.
    st="$(cat "$stf" 2>/dev/null)"
    case "$st" in
      "nudged "*) kind=nudged; rec_at="${st#nudged }" ;;
      "queued "*) kind=queued; rec_at="${st#queued }" ;;
      "nudging "*) ;;
      *) log "$name: state file $stf is unreadable or garbled ('$st') — treated as not nudged" ;;
    esac
    if [ -n "$kind" ]; then
      case "$rec_at" in
        ''|*[!0-9]*) log "$name: state file $stf has an unreadable timestamp ('$st') — treated as not nudged"; kind=""; rec_at="" ;;
      esac
    fi
    # our own state is stale (the session went on to do other things): start the cycle over
    if [ -n "$kind" ] && [ $((NOW - rec_at)) -gt $((3 * GRACE_SEC)) ]; then forget "$stf"; kind=""; rec_at=""; fi
  fi
  # not idle long enough, and we have not already nudged it => nothing to look at
  if [ -z "$kind" ] && [ "$idle" -lt "$IDLE_SEC" ]; then continue; fi

  pstate="$(pane_state "$name")"
  case "$pstate" in
    IDLE) ;;
    BUSY) log "$name: pane busy (turn running) — no action; if it is frozen NO watchdog covers it (crew-hang-detector skips adhoc), only the engine idle_timeout (2h)"; continue ;;
    *)    log "$name: pane UNKNOWN (empty/unreadable/unclassifiable) — no action"; continue ;;
  esac
  bs="$(bead_state "$sid" "$name" "$alias" "$sname" "$wdir")"
  case "$bs" in
    NONE) ;;
    HAS:*) log "$name: holds a bead (${bs#HAS:} assigned) — not ours to touch"; forget "$stf"; continue ;;
    *)     log "$name: bead state ${bs} — UNKNOWN, no action"; continue ;;
  esac

  # idle pane + provably no bead
  if [ "$kind" = "queued" ]; then
    # A nudge gc only QUEUED. Do not close (the worker was never confirmed warned) and do not enqueue another
    # one every pass (they would all drain at once). Wait QUEUE_WAIT_SEC; then, because the pane and bead legs
    # above were JUST re-checked (idle pane, provably no bead), send one --delivery immediate. If gc still does
    # not report it delivered the record is renewed as "queued" — the slot stays held, nothing is ever closed.
    qwaited=$((NOW - rec_at))
    if [ "$qwaited" -lt "$QUEUE_WAIT_SEC" ] || [ "$idle" -lt "$IDLE_SEC" ]; then
      QWAIT=$((QWAIT + 1))
      log "$name: nudge was QUEUED ${qwaited}s ago and never confirmed delivered; idle ${idle}s — waiting (not re-enqueuing, close stage NOT armed)"; continue
    fi
    if [ "$NUDGES" -ge "$MAX_NUDGES" ]; then log "$name: eligible for an immediate re-nudge but MAX_NUDGES=$MAX_NUDGES reached this pass"; continue; fi
    NUDGES=$((NUDGES + 1))
    if [ "$DRY_RUN" = "1" ]; then log "$name ($tmpl): DRY_RUN would re-NUDGE --delivery immediate — queued ${qwaited}s ago, idle ${idle}s, no bead"; continue; fi
    nudge_session "$name" "$tmpl" immediate "$idle" "$stf"
  elif [ -z "$kind" ]; then
    if [ "$NUDGES" -ge "$MAX_NUDGES" ]; then log "$name: eligible for nudge but MAX_NUDGES=$MAX_NUDGES reached this pass"; continue; fi
    NUDGES=$((NUDGES + 1))
    if [ "$DRY_RUN" = "1" ]; then log "$name ($tmpl): DRY_RUN would NUDGE — idle ${idle}s, no bead"; continue; fi
    # nudge_session records the attempt FIRST and sends only if that write verifiably landed. The other order
    # (nudge, then `echo > state`) re-sent the same nudge every pass when the state dir was unwritable — one
    # agent turn per pass — while the log kept saying NUDGED, and stage 2 could never start.
    nudge_session "$name" "$tmpl" wait-idle "$idle" "$stf"
  else
    waited=$((NOW - rec_at))
    if [ "$waited" -lt "$GRACE_SEC" ] || [ "$idle" -lt $((GRACE_SEC / 2)) ]; then
      log "$name: nudged ${waited}s ago, idle ${idle}s — within grace"; continue
    fi
    if [ "$CLOSE_ENABLED" != "1" ]; then log "$name: still idle + bead-less ${waited}s after nudge — close stage disabled (POOL_IDLE_CLOSE=0), no action"; continue; fi
    if [ "$CLOSES" -ge "$MAX_CLOSES" ]; then log "$name: eligible for close but MAX_CLOSES=$MAX_CLOSES reached this pass"; continue; fi
    CLOSES=$((CLOSES + 1))
    if [ "$DRY_RUN" = "1" ]; then log "$name ($tmpl): DRY_RUN would CLOSE — ${waited}s after nudge, still idle, no bead"; continue; fi
    timeout "$CALL_TIMEOUT" "$GC" session close "$name" >/dev/null 2>&1; crc=$?
    if [ "$crc" -ne 0 ]; then
      # rc 124 = timed out, the close may have taken effect. State is kept, so the next pass looks again
      # (and the bead/pane legs are re-checked before anything else is done).
      log "$name ($tmpl): close NOT CONFIRMED (rc=$crc; 124 = timed out, may still have taken effect) — will look again next pass"
      continue
    fi
    # rc 0 only means gc accepted the request. What matters is whether the slot is free, so look.
    case "$(slot_state "$name")" in
      RELEASED)
        RELEASED=$((RELEASED + 1)); forget "$stf"
        log "$name ($tmpl): CLOSED — ${waited}s after nudge, still idle with no bead; slot RELEASED (verified: no longer active in the session list)" ;;
      HELD)
        HELD=$((HELD + 1))
        log "$name ($tmpl): CLOSE-INEFFECTIVE — gc session close returned 0 but the session is STILL ACTIVE; the pool slot is NOT released. State kept: it will be retried next pass, and this line repeats until something else frees the slot" ;;
      *)
        UNVERIFIED=$((UNVERIFIED + 1))
        log "$name ($tmpl): CLOSE-UNVERIFIED — gc session close returned 0 but the session list could not be re-read; slot release NOT confirmed. State kept; next pass will look again" ;;
    esac
  fi
done < "$CAND_FILE"

# forget state for sessions that are gone / no longer candidates
for f in "$SESS_STATE"/*.nudged; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .nudged)"
  case "$SEEN" in *" $n "*) ;; *) forget "$f" ;; esac
done

log "=== pass end (nudge_attempts=$NUDGES queued_not_delivered=$QUEUED still_queued_waiting=$QWAIT closes_attempted=$CLOSES released=$RELEASED still_active=$HELD unverified=$UNVERIFIED state_errors=$STATE_ERRORS skipped_unknown=$NSKIP) ==="
exit 0
