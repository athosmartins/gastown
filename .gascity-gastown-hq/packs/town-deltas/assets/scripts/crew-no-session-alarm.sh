#!/usr/bin/env bash
# crew-no-session-alarm.sh — ga-4ytmas (item 3): ALARM the Mayor when a crew the config says must always be up
# (an [[agent]] with min_active_sessions >= 1, not suspended) has NO live session for >= MISSING_SEC (10 min).
# DETECTION ONLY: one mail per episode and nothing else — it never starts, wakes, nudges, closes or kills a
# session (selftest K fails if it ever calls anything but `gc config show|session list|mail send`).
#
# THE INCIDENT (10/10, ~14:06-14:40): the supervisor went BLIND under load — its Darwin `ps` snapshot was
# killed at the 3 s fetch timeout every ~3 s (213 "tmux state cache: refresh failed" lines that day) — and read
# that as "the sessions are gone". oracle-wa (min_active_sessions = 1) lost its session; the replacements the
# supervisor tried were `deferred_by_wake_budget` (max_wakes_per_tick = 2, starts take 1-2.5 min under load)
# and rolled back after 10 min ("lease expired and no live runtime"). The crew was down for ~20 min until the
# Mayor recreated it by hand, and NOTHING said so: the reconciler logs it, but no watcher reads "desired=1,
# live=0" as an event for a human.
#   - crew-hang-detector looks at LIVE crew panes (a frozen spinner), never at a crew with no session;
#   - agent-stuck-escalation is keyed on a stale in_progress BEAD;
#   - pool-stuck-prompt-alarm covers bead-less POOL sessions.
# This is the missing inverse: desired by config, absent in `gc session list`.
#
# WHAT "DESIRED" MEANS HERE. `gc config show` (the resolved city config) lists every [[agent]]; the always-on
# floor is min_active_sessions. A crew is checked when that floor is >= 1, the agent is not `suspended`, and
# its rig (if any) is not suspended. Today that is exactly oracle-wa. [[named_session]] mode = "always" is NOT
# read on purpose: in this town the always-mode witnesses (and the suspended deacon/boot) sit `asleep` by
# design — MEASURED 10/10 in `gc session list --json` — so counting them would be a permanent false alarm.
# A session is LIVE only in state `active`; creating / start-pending / draining / asleep / orphaned ... are
# NOT live (a replacement stuck in start-pending is the 10/10 failure itself). The mail names the best state
# it did find, so "no session at all" and "a session that never got started" read differently.
#
# THREE STATES, never collapsed: "could not tell" is not "missing". If `gc config show` or `gc session list`
# fails, times out, or does not parse (an error envelope, no "sessions" key), the pass is UNKNOWN: it logs,
# touches NO clock and mails nothing. Only a successful read of BOTH can start or advance a clock.
#
# THE CLOCK is this script's own (the engine keeps no "since when" for an absent session): one state file per
# crew, "<first-missing> <last-observed> <alarmed-at|0>". The first pass that finds the crew missing starts it;
# any pass that finds a live session ends the episode (state removed). A gap of more than GAP_SEC between two
# observations restarts the clock — a missing crew we did not watch for 40 min is not "missing for 40 min"
# (it may have been up in between).
#
# THE ALARM, once per episode, ONE mail per pass covering every crew that became due: `gc mail send mayor`
# (durable — if the Mayor restarts the question must still be there). The "alarmed" mark is written BEFORE the
# send and only a verified write lets the mail go (an unrecorded alarm would be re-mailed every pass); a send
# that FAILED (gc exited non-zero) clears the marks so the next pass retries, but one that TIMED OUT (rc 124)
# is UNKNOWN — it may have gone out — so the marks stay (no duplicate Dolt commit) and the line is logged as
# such. A crew STILL missing after REALARM_SEC is mailed again.
#
# COST. MEASURED 10/10 at load 50-80: `gc session list --json` 22-37 s; `gc config show` 5-13 s. Two reads and
# at most one mail per pass, so interval 5m with an order timeout of 600 s (selftest W fails if the timeout
# drops under 2 x CALL_TIMEOUT + the 45 s mail + 60 s). With a 10 min threshold and a 5 min tick an outage is
# mailed 10-15 min after it began.
#
# SAFETY VALVES: kill-switch file $STATE_ROOT/crew-no-session-alarm.disabled; single instance via flock; every
# gc call bounded by `timeout`; always exits 0 (an order tick must not page anyone because gc was briefly
# unavailable); DRY_RUN=1 sends no mail and writes no "alarmed" mark (it keeps its own observation clock, which
# is memory, not an action). Runs as a gc order (orders/crew-no-session-alarm.toml).
#
# bash 3.2-safe on purpose (no arrays/assoc arrays/mapfile): the gate parses scripts under macOS bash 3.2.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
MAYOR_ADDR="${MAYOR_ADDR:-mayor}"
STATE_ROOT="${CREW_ALARM_STATE_ROOT:-$CITY/.gc/state}"
SESS_STATE="$STATE_ROOT/crew-no-session"
KILL_SWITCH="$STATE_ROOT/crew-no-session-alarm.disabled"
LOG="${CREW_ALARM_LOG:-$CITY/.gc/logs/crew-no-session-alarm.log}"
LOCK_FILE="${CREW_ALARM_LOCK:-$CITY/.gc/runtime/crew-no-session-alarm.lock}"

MISSING_SEC="${CREW_ALARM_MISSING_SEC:-600}"        # no live session this long => the alarm
REALARM_SEC="${CREW_ALARM_REALARM_SEC:-21600}"      # a crew still missing is mailed again after this long
GAP_SEC="${CREW_ALARM_GAP_SEC:-1800}"               # observations further apart than this do not form one episode
CALL_TIMEOUT="${CREW_ALARM_CALL_TIMEOUT:-120}"      # one `gc config show` / `gc session list` call (MEASURED 5-37 s at load 50-80)
DRY_RUN="${DRY_RUN:-0}"
NOW="${CREW_ALARM_NOW:-$(date +%s)}"                # overridable so the selftest is deterministic

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK_FILE")" 2>/dev/null || true
mkdir -p "$SESS_STATE" 2>/dev/null || true       # a failure here is NOT swallowed: see the dir check below
if [ "$DRY_RUN" != "1" ]; then exec >> "$LOG" 2>&1; fi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [crew-no-session] $*"; }

if [ -f "$KILL_SWITCH" ]; then log "kill-switch present ($KILL_SWITCH) — no-op"; exit 0; fi

exec 9>"$LOCK_FILE" || { log "cannot open lock $LOCK_FILE — exiting (no single-instance guarantee)"; exit 0; }
# three states: lock taken / held by someone else / flock itself missing (rc 127 from a PATH without
# /opt/homebrew/bin) — the last must not read as "held", or the alarm would silently never run
command -v flock >/dev/null 2>&1 || { log "ERROR: flock not found on PATH ($PATH) — cannot take the single-instance lock, exiting WITHOUT running (this is not 'another instance holds it')"; exit 0; }
command -v timeout >/dev/null 2>&1 || { log "ERROR: timeout not found on PATH ($PATH) — every gc call must be bounded, exiting WITHOUT running"; exit 0; }
flock -n 9 || { log "another instance holds $LOCK_FILE — exiting"; exit 0; }

log "=== pass start (MISSING_SEC=$MISSING_SEC REALARM_SEC=$REALARM_SEC GAP_SEC=$GAP_SEC DRY_RUN=$DRY_RUN) ==="
if [ ! -d "$SESS_STATE" ] || [ ! -w "$SESS_STATE" ]; then
  log "STATE-ERROR: state dir $SESS_STATE is missing or not writable — no clock can start, so NO alarm can fire this pass"
fi

CFG_FILE="$(mktemp "${TMPDIR:-/tmp}/crew-alarm-cfg.XXXXXX")"
SESS_FILE="$(mktemp "${TMPDIR:-/tmp}/crew-alarm-sess.XXXXXX")"
JOIN_FILE="$(mktemp "${TMPDIR:-/tmp}/crew-alarm-join.XXXXXX")"
SKIP_FILE="$(mktemp "${TMPDIR:-/tmp}/crew-alarm-skip.XXXXXX")"
DUE_FILE="$(mktemp "${TMPDIR:-/tmp}/crew-alarm-due.XXXXXX")"
trap 'rm -f "$CFG_FILE" "$SESS_FILE" "$JOIN_FILE" "$SKIP_FILE" "$DUE_FILE"' EXIT

# ---- the two reads. Either failing is UNKNOWN: no clock moves, nothing is mailed ---------------------------------
timeout "$CALL_TIMEOUT" "$GC" config show > "$CFG_FILE" 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$CFG_FILE" ]; then log "WARN: gc config show failed or empty (exit $rc) — which crews must be up is UNKNOWN, skipping pass (no clock touched)"; exit 0; fi
timeout "$CALL_TIMEOUT" "$GC" session list --json > "$SESS_FILE" 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$SESS_FILE" ]; then log "WARN: gc session list failed or empty (exit $rc) — which sessions are live is UNKNOWN, skipping pass (no clock touched)"; exit 0; fi

# Join, one line per desired crew:  template|floor|live(0/1)|best-state|sessions
# (non-whitespace delimiter on purpose: `read` would collapse empty tab-separated fields)
python3 - "$CFG_FILE" "$SESS_FILE" > "$JOIN_FILE" 2> "$SKIP_FILE" <<'PY'
import json, re, sys
try:
    import tomllib
except Exception:
    sys.exit(5)                      # python without tomllib: cannot read the config => UNKNOWN
try:
    cfg = tomllib.load(open(sys.argv[1], "rb"))
    agents = cfg["agent"]
    assert isinstance(agents, list) and agents
except Exception:
    sys.exit(3)                      # unparseable config / no [[agent]] list: NOT the same as "nobody must be up"
try:
    doc = json.load(open(sys.argv[2]))
    assert isinstance(doc, dict) and "sessions" in doc      # an error envelope has no "sessions" key
    sessions = doc["sessions"] or []                        # a Go nil slice marshals as null: no sessions at all
    assert isinstance(sessions, list)
except Exception:
    sys.exit(4)                      # unparseable session list: NOT the same as "zero sessions"
susp_rigs = set(r.get("name") for r in (cfg.get("rigs") or []) if isinstance(r, dict) and r.get("suspended"))
RANK = ["active", "creating", "start-pending", "draining", "asleep"]
for a in agents:
    if not isinstance(a, dict):
        continue
    name = a.get("name") or ""
    d = a.get("dir") or ""
    try:
        floor = int(a.get("min_active_sessions") or 0)
    except Exception:
        sys.stderr.write("skip:bad-min_active_sessions:%s\n" % (name or "?")); continue
    if floor < 1 or a.get("suspended") or (d and d in susp_rigs):
        continue
    tmpl = d + "/" + name if d else name
    # a template we cannot safely serialise (or that would escape the state dir) is UNKNOWN => not checked,
    # but COUNTED and named (stderr -> $SKIP_FILE), never dropped silently
    if not name or not re.fullmatch(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?", tmpl):
        sys.stderr.write("skip:unsafe-template:%s\n" % (tmpl or "?")); continue
    mine = [s for s in sessions if isinstance(s, dict) and s.get("template") == tmpl and not s.get("closed")]
    states = [str(s.get("state") or "?") for s in mine]
    live = 1 if "active" in states else 0
    best = "none"
    for r in RANK:
        if r in states:
            best = r; break
    else:
        if states:
            best = states[0]
    print("%s|%d|%d|%s|%d" % (tmpl, floor, live, best, len(mine)))
PY
PY_RC=$?
case "$PY_RC" in
  0) ;;
  3) log "WARN: gc config show output could not be parsed as a config with [[agent]] — which crews must be up is UNKNOWN, skipping pass (no clock touched)"; exit 0 ;;
  4) log "WARN: gc session list --json could not be parsed (not JSON, or no \"sessions\" key) — which sessions are live is UNKNOWN, skipping pass (no clock touched)"; exit 0 ;;
  5) log "WARN: python3 has no tomllib (needs 3.11+) — cannot read the config, skipping pass (no clock touched)"; exit 0 ;;
  *) log "WARN: join failed (python exit $PY_RC) — skipping pass (no clock touched)"; exit 0 ;;
esac
NDES="$(wc -l < "$JOIN_FILE" | tr -d ' ')"
# grep -c: rc 0 = some, 1 = none, >=2 = could not read the report. The last must not read as "none skipped".
NSKIP="$(grep -c '^skip:' "$SKIP_FILE" 2>/dev/null)"; SKIP_RC=$?
case "$SKIP_RC" in 0|1) ;; *) NSKIP="?"; log "WARN: the skip report $SKIP_FILE could not be read (grep exit $SKIP_RC) — how many crews were skipped is UNKNOWN" ;; esac
log "crews that must be up (min_active_sessions >= 1, not suspended): $NDES"
case "$NSKIP" in ''|*[!0-9]*) ;; *)
  if [ "$NSKIP" -gt 0 ]; then
    log "WARN: $NSKIP crew(s) skipped as UNKNOWN (cannot be checked): $(grep '^skip:' "$SKIP_FILE" | tr '\n' ' ')"
  fi ;;
esac

# ---- state --------------------------------------------------------------------------------------------------
# A write or a removal that did not happen is NEVER swallowed: it is logged as STATE-ERROR and counted in the
# pass summary. A write that did not land makes the caller abstain from the mail (an unrecorded alarm would be
# re-sent every pass, and a clock that cannot be recorded cannot reach MISSING_SEC).
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

# forget <file> -> 0 if the file is gone afterwards, 1 + STATE-ERROR if it is still there
forget() {
  [ "$DRY_RUN" = "1" ] && return 0
  [ -e "$1" ] || return 0
  rm -f "$1" 2>/dev/null
  if [ -e "$1" ]; then state_err "cannot remove $1 — it will keep steering later passes until it is removed by hand"; return 1; fi
  return 0
}

# read_state <file>: sets ST_FIRST ST_LAST ST_ALARMED. Returns 0 = valid, 1 = no file, 2 = unreadable / garbled
# (the caller treats 2 as a NEW episode: a clock we cannot read is not a clock that has run).
ST_FIRST=0; ST_LAST=0; ST_ALARMED=0
read_state() {
  local line extra
  ST_FIRST=0; ST_LAST=0; ST_ALARMED=0
  [ -f "$1" ] || return 1
  line="$(cat "$1" 2>/dev/null)" || return 2
  read -r ST_FIRST ST_LAST ST_ALARMED extra <<EOF
$line
EOF
  case "$ST_FIRST" in ''|*[!0-9]*) return 2 ;; esac
  case "$ST_LAST" in ''|*[!0-9]*) return 2 ;; esac
  case "$ST_ALARMED" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$extra" ] && return 2
  return 0
}

# ---- the alarm ----------------------------------------------------------------------------------------------
state_label() {
  case "$1" in
    none)          echo "nenhuma sessão (nem criada)" ;;
    start-pending) echo "start-pending (criada, nunca chegou a subir)" ;;
    creating)      echo "creating (criação em andamento, não subiu)" ;;
    draining)      echo "draining (sessão sendo encerrada)" ;;
    asleep)        echo "asleep (dormindo — com piso min_active_sessions >= 1 ela deveria estar acordada)" ;;
    *)             echo "$1 (não é 'active')" ;;
  esac
}

# send_alarm <subject> <body> -> exit status of `gc mail send`: 0 = accepted, 124 = timeout killed it (outcome UNKNOWN), else failed
send_alarm() {
  timeout 45 "$GC" mail send "$MAYOR_ADDR" -s "$1" -m "$2" >/dev/null 2>&1
}

# ---- main loop ----------------------------------------------------------------------------------------------
N_LIVE=0; N_YOUNG=0; N_DONE=0; N_DUE=0; N_RESTART=0; N_MAILED=0; N_MAILFAIL=0; N_MAILUNK=0; SEEN=""
while IFS='|' read -r tmpl floor live best nsess; do
  [ -z "$tmpl" ] && continue
  key="$(printf '%s' "$tmpl" | tr '/' '@')"       # '@' cannot occur in a template (the join rejects it): the mapping is injective
  SEEN="$SEEN $key "
  stf="$SESS_STATE/$key.state"

  if [ "$live" = "1" ]; then
    N_LIVE=$((N_LIVE + 1))
    if [ -f "$stf" ]; then log "$tmpl: live session is back — episode over, clock cleared"; fi
    forget "$stf"
    continue
  fi

  read_state "$stf"; rs=$?
  if [ "$rs" -ne 0 ]; then
    # first sighting of the absence, or a state file we cannot trust => a NEW episode; its clock starts now
    [ "$rs" -eq 2 ] && log "$tmpl: state file $stf is unreadable or garbled — starting a new episode"
    if write_state "$stf" "$NOW $NOW 0"; then N_YOUNG=$((N_YOUNG + 1)); log "$tmpl: no live session (best state: $best, sessions: $nsess) — clock started"
    else state_err "$tmpl: cannot record the absence clock in $SESS_STATE — it cannot reach ${MISSING_SEC}s, so no alarm for this crew"; fi
    continue
  fi
  if [ $((NOW - ST_LAST)) -gt "$GAP_SEC" ]; then
    N_RESTART=$((N_RESTART + 1))
    log "$tmpl: last observed $((NOW - ST_LAST))s ago (> GAP_SEC=$GAP_SEC) — the absence between is not proven, clock restarted"
    write_state "$stf" "$NOW $NOW 0" || state_err "$tmpl: cannot restart the absence clock in $SESS_STATE"
    continue
  fi

  missing=$((NOW - ST_FIRST))
  if [ "$missing" -lt "$MISSING_SEC" ]; then
    N_YOUNG=$((N_YOUNG + 1))
    write_state "$stf" "$ST_FIRST $NOW $ST_ALARMED" || state_err "$tmpl: cannot record the observation — the next pass may restart the clock"
    continue
  fi
  write_state "$stf" "$ST_FIRST $NOW $ST_ALARMED" || state_err "$tmpl: cannot record the observation — the next pass may restart the clock"
  if [ "$ST_ALARMED" -gt 0 ] && [ $((NOW - ST_ALARMED)) -lt "$REALARM_SEC" ]; then N_DONE=$((N_DONE + 1)); continue; fi
  printf '%s|%s|%s|%s|%s|%s\n' "$tmpl" "$best" "$nsess" "$missing" "$ST_FIRST" "$floor" >> "$DUE_FILE"
  N_DUE=$((N_DUE + 1))
done < "$JOIN_FILE"

# ---- one mail for every crew that became due this pass ---------------------------------------------------------
if [ "$N_DUE" -gt 0 ]; then
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would MAIL $MAYOR_ADDR — $N_DUE crew(s) without a live session: $(cut -d'|' -f1,2,4 "$DUE_FILE" | tr '\n' ' ')"
  else
    # record FIRST, send only for the crews whose record verifiably landed (an unrecorded alarm repeats every pass)
    SEND_FILE="$DUE_FILE.send"; : > "$SEND_FILE"
    while IFS='|' read -r tmpl best nsess missing first floor; do
      key="$(printf '%s' "$tmpl" | tr '/' '@')"; stf="$SESS_STATE/$key.state"
      if write_state "$stf" "$first $NOW $NOW"; then printf '%s|%s|%s|%s|%s|%s\n' "$tmpl" "$best" "$nsess" "$missing" "$first" "$floor" >> "$SEND_FILE"
      else state_err "$tmpl: cannot record the alarm mark in $SESS_STATE — NOT mailing it (an unrecorded alarm would repeat every pass)"; fi
    done < "$DUE_FILE"
    NSEND="$(wc -l < "$SEND_FILE" | tr -d ' ')"
    if [ "$NSEND" -gt 0 ]; then
      NAMES=""; LIST=""; MAXMIN=0
      while IFS='|' read -r tmpl best nsess missing first floor; do
        mins=$((missing / 60)); [ "$mins" -gt "$MAXMIN" ] && MAXMIN="$mins"
        since="$(date -r "$first" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "epoch $first")"
        NAMES="${NAMES:+$NAMES, }$tmpl"
        LIST="$LIST
  crew:           $tmpl  (min_active_sessions = $floor)
  sem sessão viva há: ~${mins}min  (desde $since)
  melhor estado:  $(state_label "$best")  — sessões deste template: $nsess
"
      done < "$SEND_FILE"
      subject="Crew SEM sessão viva há ${MAXMIN}min (desired >= 1): $NAMES"
      body="$(cat <<EOF
Crew que o config manda manter sempre de pé (min_active_sessions >= 1, não suspenso) está SEM sessão 'active' há >= $((MISSING_SEC / 60))min.
$LIST
Por que isto chegou até você: em 10/10 (~14:06-14:40) o supervisor ficou cego sob carga (snapshot de processos do tmux
morto a cada ~3 s) e o oracle-wa ficou ~20min fora; as sessões de reposição foram 'deferred_by_wake_budget' e depois
revertidas ('lease expired and no live runtime'). O reconciler loga isso, mas nenhum watcher transformava
'desired=1, live=0' em aviso (ga-4ytmas, item 3). crew-hang-detector só olha crew VIVO; pool-stuck-prompt-alarm só pool.

Nada foi feito pela detecção (detection-only). Para agir:
  1. gc session list --json | jq '.sessions[] | select(.template=="<crew>")'     # o que existe de fato
  2. /usr/bin/grep -E 'deferred_by_wake_budget|refresh failed|rolling back pending create|runtime-missing' ~/.gc/supervisor.log | tail -40
     'refresh failed' repetido = supervisor cego (não é o crew que caiu); 'deferred_by_wake_budget' = fila de wake cheia
  3. recriar a sessão do crew (foi o que o Mayor fez com o oracle-wa em 10/10) — e, se o supervisor estiver cego,
     tratar a causa antes: a janela de motor (docs/pending-engine-window/ga-4ytmas-*.patch) corrige a cegueira.
Este alarme repete a cada $((REALARM_SEC / 3600))h enquanto o crew continuar sem sessão; sessão 'active' de volta encerra o episódio.
EOF
)"
      send_alarm "$subject" "$body"; src=$?
      case "$src" in
        0)
          N_MAILED=$((N_MAILED + NSEND))
          log "ALARM mailed to $MAYOR_ADDR — $NSEND crew(s) without a live session: $NAMES" ;;
        124)
          # timeout killed gc mail send: whether the mail was written is UNKNOWN. Every mail is a permanent Dolt
          # commit, so the inert answer is to keep the marks (no resend); REALARM_SEC is the safety net if it was lost.
          N_MAILUNK=$((N_MAILUNK + NSEND))
          log "WARN gc mail send to $MAYOR_ADDR TIMED OUT — UNKNOWN whether the alarm for [$NAMES] was delivered; NOT re-sending this episode (check the Mayor's inbox); a crew still missing is mailed again after REALARM_SEC (${REALARM_SEC}s)" ;;
        *)
          N_MAILFAIL=$((N_MAILFAIL + NSEND))
          log "WARN gc mail send to $MAYOR_ADDR FAILED (exit $src) — clearing the alarm marks so the next pass retries [$NAMES]"
          while IFS='|' read -r tmpl best nsess missing first floor; do
            key="$(printf '%s' "$tmpl" | tr '/' '@')"
            write_state "$SESS_STATE/$key.state" "$first $NOW 0" || state_err "$tmpl: could not clear the alarm mark — the retry is held until REALARM_SEC (${REALARM_SEC}s)"
          done < "$SEND_FILE" ;;
      esac
    fi
    rm -f "$SEND_FILE"
  fi
fi

# forget state for crews that are no longer desired (suspended, floor lowered, removed from the config)
for f in "$SESS_STATE"/*.state; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .state)"
  case "$SEEN" in *" $n "*) ;; *) forget "$f" ;; esac
done

log "=== pass end (desired=$NDES live=$N_LIVE young=$N_YOUNG due=$N_DUE already_alarmed=$N_DONE clock_restarts=$N_RESTART mails_sent=$N_MAILED mails_failed=$N_MAILFAIL mails_unknown=$N_MAILUNK state_errors=$STATE_ERRORS skipped_unknown=$NSKIP) ==="
exit 0
