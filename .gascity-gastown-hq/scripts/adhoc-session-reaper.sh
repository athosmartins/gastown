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
#     gate-reviewer / refino-gate-reviewer / wa-worker / ps-worker + "-adhoc-"; the
#     worker classes were added by ga-jn82py — every Pilot dispatch spawns one that
#     sleeps forever, 37 had leaked by 2026-09-19). A hard exclude on every
#     NAMED crew / core session (mila/digo/batista/oracle/peter/thies/mayor/deacon/
#     boot/control-dispatcher/gastown__) means a misclassified row can NEVER be reaped.
#   * An asleep/draining/drained session is reaped on the existing path. A session
#     that reports state=active is reaped if EITHER (a) it has ALSO been IDLE (no
#     last_active update) for >= IDLE_MIN minutes — i.e. it finished its turn and is
#     sitting at an empty prompt, NOT mid-work — OR (b) it never claimed a task at all
#     (title still equals its own session name past the age floor; see
#     title_shows_no_task below): a self-serve session's own poll-for-work loop keeps
#     refreshing last_active forever, so (a) can NEVER fire for it and the idle floor
#     would otherwise be permanently defeated (ga-dd2h0). A session that IS genuinely
#     working a claimed task refreshes last_active continuously and has a task-bearing
#     title, so it can never satisfy either path. (Observed 2026-06-16, ga-tads0:
#     headless Claude adhoc reviewers/dogs finish their turn and stay state="active"
#     forever instead of going asleep, so the old active==never-reap rule leaked all of
#     them — 8 sessions, 44 sweeps, 0 reaped.)
#   * Age floor (MIN_AGE, default 30m) so a just-spawned reviewer mid-review is never
#     killed even if it momentarily reads asleep between turns.
#   * The drained/idle signal is REQUIRED together with age — we never reap on age
#     alone, and never reap on the bead alone (bead resolution is best-effort).
#   * A session with a client ATTACHED (census `attached` = true) is never reaped, in
#     any class (ga-jn82py). A missing / non-boolean `attached` (or `closed`) is "don't
#     know" and keeps the session too — only an explicit false lets it go on.
#   * Worker-class sessions (wa-worker-adhoc-* / ps-worker-adhoc-*) do real, long-running
#     work, so a worker mid-task can look idle. Once every other gate has passed they
#     need ONE more (ga-jn82py): no non-closed bead may be assigned to any of the
#     session's identities (id / name / alias / session_name) in ANY store listed in
#     routes.jsonl. "Bead" is meant broadly: open/in_progress/blocked/deferred, ephemeral
#     wisps and mail messages included (observed live: the auto-handoff "context cycle"
#     note a worker had just sent itself). What holds a session is logged as
#     detail=held <store>:<bead>(<type>). The lookup is fail-CLOSED — only an explicit
#     clean answer from every store that exists (a route whose store directory is
#     definitively absent is skipped) lets the reap proceed; a bd error/timeout, a
#     non-list payload, an unreadable routes file, zero stores checked, or an identity
#     that is not a plain token all KEEP the session. After 2 consecutive failed
#     lookups in one sweep the rest are kept WITHOUT a call (a consistently wedged Dolt
#     costs 2 timeouts per sweep, not one per candidate).
#   * PARKED-BEAD EXCEPTION to the lock above (ga-v4l16y): if EVERY non-closed bead the
#     lock finds, in EVERY store, is parked on an Athos decision (next-action:athos*,
#     story:needs-approval, or metadata athos.acao set) — never just the first one found
#     — the session is not babysitting a task, it is idling on a decision only Athos can
#     make, which can take days. Each such bead is released (assignee cleared, reopened;
#     every other field, including the park label/metadata itself, is left untouched —
#     the decision is still pending, only the pool slot is freed) and the session is
#     reaped instead of held forever. A MIX (some beads parked, some not) still KEEPS,
#     unchanged from the behavior above.
#   * Kill switch ADHOC_REAPER_ENABLED=0 → census/log only, no closes, no bead releases.
# The two mutations are `gc session close` on eligible adhoc sessions, and — ONLY for the
# parked-bead exception above — `bd update` to release a bead parked on an Athos decision.
# No rm of data, no Dolt surgery.
set -uo pipefail

GT=/Users/athos/gt
CITY="$GT/.gascity-gastown-hq"
LOG="${ADHOC_REAPER_LOG:-$CITY/.gc/logs/adhoc-session-reaper.jsonl}"
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
# ga-jn82py worker-class assigned-bead lock (see the header). Overridable for selftest
# stubbing; production uses the real `bd` and the city's own prefix→store registry.
BD_BIN="${ADHOC_REAPER_BD:-bd}"
BD_TIMEOUT_SEC="${ADHOC_REAPER_BD_TIMEOUT_SEC:-60}"   # per store: a Dolt-timeout failure was observed
                                                      # taking 33-39s to surface, so 60s leaves room
                                                      # for a slow-but-successful answer
ROUTES_FILE="${ADHOC_REAPER_ROUTES_FILE:-$CITY/.beads/routes.jsonl}"
BEAD_LOOKUP_MAX_FAILURES="${ADHOC_REAPER_BEAD_LOOKUP_MAX_FAILURES:-2}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }
log() { printf '%s\n' "$1" >> "$LOG" 2>/dev/null; }

# Ephemeral adhoc prefixes the dispatchers spawn. A session name must START with one
# of these AND contain "-adhoc-" to be eligible. Discovered via `gc session list`:
#   auto-refiner-adhoc-*, gastown.dog-adhoc-*, gate-reviewer-adhoc-*,
#   refino-gate-reviewer-adhoc-*, wa-worker-adhoc-*, ps-worker-adhoc-*
# The worker prefixes are ALSO the "worker class" (they get the extra assigned-bead lock,
# see the header). Defined once and appended below so the two lists cannot drift apart.
WORKER_ADHOC_PREFIXES='wa-worker-adhoc- ps-worker-adhoc-'
ADHOC_PREFIXES="auto-refiner-adhoc- gastown.dog-adhoc- gate-reviewer-adhoc- refino-gate-reviewer-adhoc- $WORKER_ADHOC_PREFIXES"

# Named crews / core sessions — defense in depth. If a name matches ANY of these it
# is NEVER eligible, regardless of the adhoc check. (A crew would never carry
# "-adhoc-", but this guarantees a single misread row cannot close a live crew.)
NAMED_EXCLUDE_RE='(^|[-_.])(mila|digo|batista|oracle|peter|thies|mayor|deacon|boot|control-dispatcher)([-_.]|$)|gastown__'

# is_adhoc_eligible <session_name> → 0 (eligible) | 1 (not eligible).
# Pure; no I/O. Must be an adhoc prefix AND not a named/core session.
is_adhoc_eligible() {
  local name="$1" p matched=1
  # hard exclude named/core first — this wins over everything
  if printf '%s' "$name" | grep -E "$NAMED_EXCLUDE_RE" >/dev/null; then return 1; fi
  for p in $ADHOC_PREFIXES; do
    case "$name" in "$p"*) matched=0; break ;; esac
  done
  [ "$matched" = "0" ] || return 1
  case "$name" in *-adhoc-*) return 0 ;; *) return 1 ;; esac
}

# is_worker_adhoc <session_name> → 0 (worker class) | 1. Pure; no I/O. Says nothing about
# eligibility — call is_adhoc_eligible first. Only these sessions get the assigned-bead
# lock, because only they do real long-running work that can look idle mid-task.
is_worker_adhoc() {
  local name="$1" p
  for p in $WORKER_ADHOC_PREFIXES; do
    case "$name" in "$p"*) return 0 ;; esac
  done
  return 1
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
#   id<TAB>name<TAB>state<TAB>closed<TAB>created_at<TAB>last_active<TAB>attached<TAB>alias<TAB>session_name<TAB>title
# (title is LAST so the read loop can keep it as the remainder.) Every column BEFORE the
# title is guaranteed non-empty ("-" placeholder): the read loop splits on TAB, which bash
# treats as IFS-whitespace, so an empty column would silently collapse and shift every
# later field — an empty last_active used to do exactly that. `attached` is normalised to
# true | false | unknown (key absent or not a JSON boolean) instead of being left to guess.
#
# Split into two steps (ga-dd2h0 gate-feedback round 1) so a census FAILURE and a
# census that is genuinely empty can never collapse into the same signal: previously
# both the list script failing and the python parser hitting bad/missing JSON were
# swallowed by blanket `2>/dev/null` + `except Exception: sys.exit(0)`, so an empty
# $CENSUS meant three completely different things with zero way to tell them apart —
# exactly the error==empty bug this reaper exists to stop leaking sessions from.

# list_sessions_raw → $SESSION_LIST_SCRIPT's stdout verbatim; returns ITS real exit
# code (stderr still discarded — noisy, not needed for the classification below —
# but the exit code is not, so a broken/missing script is visible to the caller
# instead of silently reading as "no sessions").
list_sessions_raw() {
  bash "$SESSION_LIST_SCRIPT" 2>/dev/null
}

# parse_census <json on stdin> → tab-separated session rows on stdout (zero rows is
# legitimate for a genuinely empty session list — that is NOT a failure). Exit code
# tells the caller WHY there might be no rows:
#   0 = parsed cleanly (rows may legitimately be empty)
#   2 = stdin was not valid JSON
#   3 = valid JSON but no "sessions" list in it (schema drift)
parse_census() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(d, dict) or not isinstance(d.get("sessions"), list):
    sys.exit(3)
def col(v):
    s = "" if v is None else str(v)
    s = s.replace("\t", " ").replace("\n", " ")
    return s if s.strip() else "-"
def attached(v):
    return "true" if v is True else "false" if v is False else "unknown"
for s in d["sessions"]:
    print("\t".join([
        col(s.get("id","")),
        col(s.get("name","")),
        col(s.get("state","")),
        col(s.get("closed","")),
        col(s.get("created_at","")),
        col(s.get("last_active","")),
        attached(s.get("attached")),
        col(s.get("alias","")),
        col(s.get("session_name","")),
        ("" if s.get("title") is None else str(s.get("title"))).replace("\t"," ").replace("\n"," "),
    ]))
' 2>/dev/null
}

# worker_bead_lock <id> <name> <alias> <session_name> → ONE line on stdout (ga-jn82py),
# except the held_parked verdict below which is one line PER bead:
#   clear <n>/<m>              every store that exists answered and NONE holds a non-closed
#                              bead assigned to any identity of this session (n = stores
#                              queried, m = routes; a route whose .beads is DEFINITIVELY
#                              absent — ENOENT — is skipped, any other stat error is
#                              unknown) → the reap may go on
#   held <store>:<bead>(<type>)[,...][,+N]
#                              a non-closed bead is assigned to it, and at least one such
#                              bead is NOT parked on an Athos decision → KEEP (first store
#                              that has one; at most 5 beads listed, +N = how many more)
#   held_parked <n>
#   <store_abs_path>\t<bead_id>\t<bead_assignee>   (repeated n times)
#                              (ga-v4l16y) EVERY non-closed bead held by this session, in
#                              EVERY store, is parked on an Athos decision — next-action:athos
#                              (exact, or a next-action:athos-/next-action:athos: variant),
#                              story:needs-approval, or metadata athos.acao set (non-empty).
#                              The caller may release each listed bead (clear assignee,
#                              reopen) and then reap the session. Full, untruncated list —
#                              the caller needs exact ids here, unlike "held" above which is
#                              log-only. Reaching this verdict costs MORE than "held": every
#                              remaining store must be checked (an "all parked" claim is only
#                              good once every store has answered) — but that extra cost is
#                              paid ONLY when every store seen so far was fully parked; the
#                              first NOT-parked held bead in any store still exits
#                              immediately as plain "held", at the same cost as before this
#                              exception existed.
#   unknown <reason>           anything else → KEEP
# The caller reaps on "clear " directly, or on "held_parked " after releasing every listed
# bead — "held " or anything else never reaps on its own.
# One query per store: bd -C <store> query "(assignee=A OR assignee=B ...) AND NOT status=closed".
# Equality on assignee is fast on every store, while a status-only scan of HQ's wisps table
# times out under load (measured 2026-09-19), and `bd query` — unlike a plain `bd list` —
# also returns ephemeral wisps. A failing `bd query` exits 1 AND prints a JSON error OBJECT
# on stdout, so the exit code and the payload shape are BOTH checked. stdin is /dev/null:
# this runs inside the census read loop and must not consume its input. Each identity must
# be a plain token, because it is spliced into the query expression.
worker_bead_lock() {
  python3 -c '
import json, os, re, subprocess, sys
bd, tmo_s, routes, city = sys.argv[1:5]
raw = sys.argv[5:]

def out(line):
    print(line)
    sys.exit(0)

def is_human_parked(b):
    # ga-v4l16y: a bead deliberately parked on a decision only Athos can make.
    # Deliberately narrower than bead_state.is_athos_page (no blocked-reason:decision,
    # no refino:policy-gap) to match the acceptance criteria for this fix exactly:
    # next-action:athos*, story:needs-approval, or metadata athos.acao set.
    for l in (b.get("labels") or []):
        if not isinstance(l, str):
            continue
        if l == "next-action:athos" or l.startswith("next-action:athos-") or l.startswith("next-action:athos:"):
            return True
        if l == "story:needs-approval":
            return True
    meta = b.get("metadata")
    if isinstance(meta, dict):
        v = meta.get("athos.acao")
        if isinstance(v, str) and v.strip():
            return True
    return False

ids = []
for i in raw:
    if i and i != "-" and i not in ids:
        ids.append(i)
if not ids:
    out("unknown no_identity")
for i in ids:
    if not re.fullmatch(r"[A-Za-z0-9._/@:+-]+", i):
        out("unknown identity_unsafe")
try:
    tmo = float(tmo_s)
    if tmo <= 0:
        raise ValueError
except ValueError:
    out("unknown bad_timeout")
stores = []
try:
    with open(routes) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            p = os.path.realpath(os.path.join(city, json.loads(line)["path"]))
            if p not in stores:
                stores.append(p)
except Exception:
    out("unknown routes_unreadable")
if not stores:
    out("unknown routes_empty")
expr = "(" + " OR ".join("assignee=" + i for i in ids) + ") AND NOT status=closed"
checked = 0
held_accum = []   # (store_abs_path, bead) pairs — ONLY ever populated with beads already
                   # confirmed human-parked; a not-parked held bead exits immediately below
                   # instead of accumulating, same as pre-existing behavior.
for st in stores:
    tag = os.path.basename(st)
    try:
        os.stat(os.path.join(st, ".beads"))
    except FileNotFoundError:
        continue
    except OSError:
        out("unknown store_unreadable:" + tag)
    try:
        r = subprocess.run([bd, "-C", st, "query", expr, "--json", "--limit", "0"],
                           capture_output=True, text=True, timeout=tmo,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        out("unknown timeout:" + tag)
    except Exception:
        out("unknown bd_exec_failed:" + tag)
    if r.returncode != 0:
        out("unknown rc%d:%s" % (r.returncode, tag))
    try:
        d = json.loads(r.stdout)
    except Exception:
        out("unknown unparseable:" + tag)
    if not isinstance(d, list):
        out("unknown not_a_list:" + tag)
    if any(not isinstance(b, dict) or not b.get("id") for b in d):
        out("unknown malformed_element:" + tag)
    checked += 1
    if d:
        not_parked = [b for b in d if not is_human_parked(b)]
        if not_parked:
            # same verdict, same cost as before this fix: exit at the first store that
            # proves NOT every held bead is parked on an Athos decision.
            shown = ["%s(%s)" % (b["id"], b.get("issue_type") or "?") for b in d[:5]]
            if len(d) > 5:
                shown.append("+%d" % (len(d) - 5))
            out("held " + tag + ":" + ",".join(shown))
        held_accum.extend((st, b) for b in d)
if checked == 0:
    out("unknown no_store_checked")
if held_accum:
    # every non-empty store seen was fully parked — ALL of it, not just the first hit.
    lines = ["held_parked %d" % len(held_accum)]
    for hst, hb in held_accum:
        lines.append("%s\t%s\t%s" % (hst, hb["id"], hb.get("assignee") or ""))
    out("\n".join(lines))
out("clear %d/%d" % (checked, len(stores)))
' "$BD_BIN" "$BD_TIMEOUT_SEC" "$ROUTES_FILE" "$CITY" "$@" </dev/null 2>/dev/null
}

# release_parked_beads <held_parked payload> → 0 if every listed bead was released, 1 if
# any failed (ga-v4l16y). payload is worker_bead_lock's "held_parked <n>\n<path>\t<id>\t
# <assignee>\n..." output. Clears assignee and reopens each bead — --if-assignee guards
# against a bead that changed hands between the lock check and here (someone else already
# claimed it), which is left untouched rather than clobbered; a stale guard, like any other
# failure here, fails the WHOLE release (fail safe — the caller must not close the session
# on a partial release). Every other field — labels (next-action:/story:needs-approval),
# metadata (athos.acao), history — is left exactly as it was: only assignee/status move, so
# the parked decision stays fully visible to whoever looks at the bead next.
release_parked_beads() {
  local payload="$1" store bead_id bead_assignee overall_rc=0 body
  body="$(printf '%s\n' "$payload" | tail -n +2)"
  while IFS=$'\t' read -r store bead_id bead_assignee; do
    [ -z "$store" ] && continue
    if [ -z "$bead_id" ] || [ -z "$bead_assignee" ]; then
      overall_rc=1
      continue
    fi
    if ! "$BD_BIN" -C "$store" update "$bead_id" -a "" -s open --if-assignee "$bead_assignee" -q; then
      overall_rc=1
    fi
  done <<< "$body"
  return "$overall_rc"
}

# Sourcing guard: the selftest sources this file to unit-test the pure helpers
# above WITHOUT running a sweep. ADHOC_REAPER_SOURCE_ONLY=1 returns here.
[ "${ADHOC_REAPER_SOURCE_ONLY:-0}" = "1" ] && return 0 2>/dev/null

reaped=0; kept_young=0; kept_active=0; kept_alive_peek=0; kept_peek_inconclusive=0; skipped_other=0; would_reap=0; eligible=0
kept_attached=0; kept_has_bead=0; kept_bead_lookup_failed=0   # ga-jn82py
bead_lookup_failures=0                                        # consecutive failed worker-lock lookups (circuit breaker)
released_parked_beads=0; kept_parked_release_failed=0         # ga-v4l16y

RAW_JSON="$(list_sessions_raw)"; raw_status=$?
if [ "$raw_status" -ne 0 ]; then
  log "$(printf '{"ts":"%s","event":"noop","reason":"list_command_failed","exit_code":%s}' "$(ts)" "$raw_status")"
  exit 0
fi

CENSUS="$(printf '%s' "$RAW_JSON" | parse_census)"; parse_status=$?
case "$parse_status" in
  2) log "$(printf '{"ts":"%s","event":"noop","reason":"unparseable_json"}' "$(ts)")"; exit 0 ;;
  3) log "$(printf '{"ts":"%s","event":"noop","reason":"missing_sessions_key"}' "$(ts)")"; exit 0 ;;
  0) : ;;
  *) log "$(printf '{"ts":"%s","event":"noop","reason":"census_parse_failed","exit_code":%s}' "$(ts)" "$parse_status")"; exit 0 ;;
esac

if [ -z "$CENSUS" ]; then
  log "$(printf '{"ts":"%s","event":"noop","reason":"no_eligible_sessions"}' "$(ts)")"
  exit 0
fi

while IFS=$'\t' read -r id name state closed created last_active attached alias session_name title; do
  [ -n "$name" ] || continue
  decision_log=""   # a reap decision is announced only once the worker lock (below) has passed
  pending_bead_release=""   # ga-v4l16y: set below when the worker lock says held_parked
  # eligibility: ephemeral adhoc + not a named/core crew
  if ! is_adhoc_eligible "$name"; then
    skipped_other=$((skipped_other+1)); continue
  fi
  eligible=$((eligible+1))

  # A row with no id is malformed. The census turns an absent/blank id into the "-" placeholder
  # (col() above), which would otherwise be handed to `gc session close` as if it were a real
  # session id — what that call does with it is unverified — so reject it here, loudly, before any
  # decision can reach the close. (ga-al3rfs: reproduced against main before this guard — an
  # id-less, drained, old row was REAPED via `gc session close -`.)
  if [ -z "$id" ] || [ "$id" = "-" ]; then
    skipped_other=$((skipped_other+1))
    log "$(printf '{"ts":"%s","event":"keep","reason":"malformed_row_no_id","name":"%s","state":"%s"}' "$(ts)" "$name" "$state")"
    continue
  fi

  # already closed → nothing to do. Only an explicit "false" lets a session go on: a missing
  # or unrecognised `closed` is "don't know", not "open" — skipped, never acted on.
  case "$closed" in
    true|True|TRUE|1) skipped_other=$((skipped_other+1)); continue ;;
    false|False|FALSE|0) : ;;
    *)
      skipped_other=$((skipped_other+1))
      log "$(printf '{"ts":"%s","event":"keep","reason":"closed_unknown","id":"%s","name":"%s"}' "$(ts)" "$id" "$name")"
      continue ;;
  esac

  # ga-jn82py: NEVER reap a session a client is attached to — someone is looking at it,
  # whatever its state / idle / age say. Every class. Only an explicit `false` lets a
  # session go on: a missing or non-boolean `attached` is "don't know", and closing a
  # session a human may be looking at cannot be undone, so it is KEPT
  # (reason=attached_unknown). Both outcomes are counted in kept_attached.
  case "$attached" in
    false) : ;;
    true)
      kept_attached=$((kept_attached+1))
      log "$(printf '{"ts":"%s","event":"keep","reason":"attached","id":"%s","name":"%s","state":"%s"}' "$(ts)" "$id" "$name" "$state")"
      continue ;;
    *)
      kept_attached=$((kept_attached+1))
      log "$(printf '{"ts":"%s","event":"keep","reason":"attached_unknown","id":"%s","name":"%s","state":"%s"}' "$(ts)" "$id" "$name" "$state")"
      continue ;;
  esac

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
      decision_log="$(printf '{"ts":"%s","event":"reap_no_task","id":"%s","name":"%s","state":"%s","age_min":%s}' "$(ts)" "$id" "$name" "$state" "$age")"
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
      decision_log="$(printf '{"ts":"%s","event":"reap_active_idle","id":"%s","name":"%s","state":"%s","age_min":%s,"idle_min":%s}' "$(ts)" "$id" "$name" "$state" "$age" "$idle")"
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

  # ga-jn82py: ASSIGNED-BEAD LOCK — the last gate, worker class only (see the header). It
  # sits AFTER every cheaper gate on purpose: a session that is young / recently active /
  # attached / peek-alive never costs a lookup (each one is up to one bd query per store,
  # against the Dolt that is already the city's weak point). Only an explicit
  # "clear <n>/<m>" lets the reap proceed; held, error, timeout, junk or empty all KEEP.
  if is_worker_adhoc "$name"; then
    if [ "$bead_lookup_failures" -ge "$BEAD_LOOKUP_MAX_FAILURES" ]; then
      lock_verdict="unknown circuit_open"
    else
      lock_verdict="$(worker_bead_lock "$id" "$name" "$alias" "$session_name")"
      case "$lock_verdict" in
        "clear "*|"held "*|"held_parked "*) bead_lookup_failures=0 ;;
        *) bead_lookup_failures=$((bead_lookup_failures+1)) ;;
      esac
    fi
    lock_detail="$(printf '%s' "${lock_verdict:-empty_output}" | tr -c 'A-Za-z0-9._:,/=()+ -' '_')"
    case "$lock_verdict" in
      "clear "*) : ;;
      "held_parked "*)
        # ga-v4l16y: every bead this session holds, in every store, is parked on an
        # Athos decision — release each one below (assignee cleared, reopened; the
        # park label/metadata stays untouched) and let the reap proceed, instead of
        # keeping the slot wedged on a decision that can take days.
        pending_bead_release="$lock_verdict"
        decision_log="$(printf '{"ts":"%s","event":"reap_parked_bead","id":"%s","name":"%s","state":"%s","age_min":%s}' "$(ts)" "$id" "$name" "$state" "$age")"
        ;;
      "held "*)
        kept_has_bead=$((kept_has_bead+1))
        log "$(printf '{"ts":"%s","event":"keep","reason":"has_assigned_bead","id":"%s","name":"%s","state":"%s","detail":"%s"}' "$(ts)" "$id" "$name" "$state" "$lock_detail")"
        continue ;;
      *)
        kept_bead_lookup_failed=$((kept_bead_lookup_failed+1))
        log "$(printf '{"ts":"%s","event":"keep","reason":"bead_lookup_failed","id":"%s","name":"%s","state":"%s","detail":"%s"}' "$(ts)" "$id" "$name" "$state" "$lock_detail")"
        continue ;;
    esac
  fi
  if [ -n "$decision_log" ]; then log "$decision_log"; fi

  # bead hint (best-effort, advisory only — not a gate). Title carries the source
  # bead like "auto-refiner: ga-sf661 (attempt 1)".
  bead="$(printf '%s' "$title" | grep -oE 'ga-[a-z0-9]{5,7}|gt-[a-z0-9]{5,7}|wa-[a-z0-9]{4,7}' | head -1)"

  if [ "$ENABLED" != "1" ]; then
    would_reap=$((would_reap+1))
    log "$(printf '{"ts":"%s","event":"would_reap","id":"%s","name":"%s","state":"%s","age_min":%s,"bead":"%s"}' "$(ts)" "$id" "$name" "$state" "$age" "$bead")"
    continue
  fi

  # ga-v4l16y: release every bead the held_parked verdict listed BEFORE closing the
  # session — if any release fails (race: someone else claimed it since the lock check;
  # a bd error), do NOT close the session this sweep. Fail safe, same posture as every
  # other failure mode in this script: retry next sweep rather than close a session that
  # may still be legitimately holding a bead we could not confirm was released.
  if [ -n "$pending_bead_release" ]; then
    if release_parked_beads "$pending_bead_release"; then
      released_parked_beads=$((released_parked_beads + $(printf '%s\n' "$pending_bead_release" | head -1 | awk '{print $2}')))
    else
      kept_parked_release_failed=$((kept_parked_release_failed+1))
      log "$(printf '{"ts":"%s","event":"keep","reason":"parked_release_failed","id":"%s","name":"%s","state":"%s"}' "$(ts)" "$id" "$name" "$state")"
      continue
    fi
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

log "$(printf '{"ts":"%s","event":"sweep","enabled":"%s","min_age_min":%s,"idle_min":%s,"eligible":%s,"reaped":%s,"would_reap":%s,"kept_young":%s,"kept_active":%s,"kept_alive_peek":%s,"kept_peek_inconclusive":%s,"skipped_other":%s,"kept_attached":%s,"kept_has_bead":%s,"kept_bead_lookup_failed":%s,"released_parked_beads":%s,"kept_parked_release_failed":%s}' \
  "$(ts)" "$ENABLED" "$MIN_AGE_MIN" "$IDLE_MIN" "$eligible" "$reaped" "$would_reap" "$kept_young" "$kept_active" "$kept_alive_peek" "$kept_peek_inconclusive" "$skipped_other" "$kept_attached" "$kept_has_bead" "$kept_bead_lookup_failed" "$released_parked_beads" "$kept_parked_release_failed")"
exit 0
