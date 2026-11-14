#!/usr/bin/env bash
# idle-crew-suspender.sh (ga-v8p1tx.1.6) — suspends named crews that sit idle
# during the day, to give RAM/swap back to the builders (mission gate-8h,
# ga-v8p1tx.1: the mini runs at swap 2.7-3.2 GB and every idle crew holds
# ~300 MB).
#
# AUTHORIZATION (Regra Nº 4 — citable): Athos, 14/11/2026 14:25, answer
# "Sim, suspende as paradas" to the Mayor's AskUserQuestion, quoted in the
# description of ga-v8p1tx.1.6. Scope widened 14/11 14:37 (Mayor's comment on
# the same bead, quoting Athos): "Se precisar feche workers idle. Nao feche do
# oracle" → oracle-* (the crew AND its workers) is NEVER touched; idle pool
# workers are already reaped by adhoc-session-reaper.sh (ga-jn82py), so this
# job only owns the named crews.
#
# A crew is suspended only when ALL of these hold (any doubt → leave it alone):
#   1. now is inside 06:00–24:00 local time (outside it the capacity-containment
#      night rules own the crews — crew-capacity-containment.sh);
#   2. the crew's template is a Layer-1 named crew (live-derived from
#      agents/*/agent.toml by crew-idle-check.sh) and none of the session's
#      names (template, alias, name, agent_name, session_name) matches oracle*;
#   3. the session is active and NOT attached (Athos is not looking at it);
#   4. its newest transcript (~/.claude/projects/<work_dir slug>/**/*.jsonl) is
#      older than IDLE_MIN (60) minutes — tmux session_activity is NOT usable
#      (it read 14 h for crews that were working);
#   5. zero in_progress beads assigned to it, under ANY of the names the roster
#      gives the session (id, session_name, name, alias, agent_name, template —
#      the set bead_state and config-drift-wake use), in its rig store AND in
#      the HQ store. A crew's live beads can sit under its session_name
#      (<alias>-gawisp<tail>) and not under its alias (gate FAIL 14/11).
# At most MAX_PER_RUN (3) suspensions per run. The session bead persists;
# `gc session wake <crew>` brings it back (and `gc session pin` re-pins it if a
# pin was in place). On the managed path (the mini runs a controller) `gc session
# suspend` only sets the operator hold and pokes the controller; the reconciler
# stops the runtime afterwards (read in the engine source, cmd/gc/cmd_session.go,
# not observed live), so the state read a few seconds later can still say
# "active" (logged SUSPEND_UNCONFIRMED).
#
# Every read has THREE outcomes — has / has-not / could-not-tell — and
# "could not tell" always lands in the inert state (nothing is suspended).
#
# Env: ICS_DRY_RUN=1 (log WOULD_SUSPEND, change nothing), ICS_IDLE_MIN,
# ICS_MAX_PER_RUN, ICS_EXTRA_EXCLUDE ("glob glob", additive — the oracle*
# exclusion cannot be removed), ICS_LOG, ICS_RUN_DIR, ICS_PROJECTS_DIR,
# ICS_NOW_HOUR (tests). ICS_IDLE_MIN and ICS_MAX_PER_RUN must be whole numbers
# (1-6 digits) and ICS_DRY_RUN 0 or 1: anything else logs a WARN and falls back
# to 60 / 3 / dry-run, never to "threshold off" or "cap off".
# Test: bash idle-crew-suspender.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Library mode of crew-idle-check.sh: gives _layer1_crew_names, _agent_work_dir,
# _rig_path_for_work_dir without running its CLI flow. It also defines BD/GC/CITY.
CREW_IDLE_CHECK_LIB=1 source "${HERE}/crew-idle-check.sh"

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
# gc and bd locate the city through these when launchd starts us from "/" (verified:
# `cd / && gc session list` fails without GC_CITY_PATH, works with it).
export GC_CITY_PATH="$CITY" GC_CITY="${GC_CITY:-$CITY}"
LOG="${ICS_LOG:-${CITY}/.gc/logs/idle-crew-suspender.log}"
RUN_DIR="${ICS_RUN_DIR:-${HOME}/.gastown/run}"
LOCK_DIR="${ICS_LOCK_DIR:-${RUN_DIR}/idle-crew-suspender.lock}"
PROJECTS_DIR="${ICS_PROJECTS_DIR:-${HOME}/.claude/projects}"
IDLE_MIN="${ICS_IDLE_MIN:-60}"
MAX_PER_RUN="${ICS_MAX_PER_RUN:-3}"
DRY_RUN="${ICS_DRY_RUN:-0}"
WINDOW_START_HOUR=6     # inclusive
WINDOW_END_HOUR=24      # exclusive (00:00)
# oracle* is a floor, not a default: ICS_EXTRA_EXCLUDE only adds to it.
EXCLUDE_GLOBS="oracle* ${ICS_EXTRA_EXCLUDE:-}"

log() {
  mkdir -p "$(dirname "${LOG}")" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') [idle-crew-suspender] $*" >> "${LOG}" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') [idle-crew-suspender] $*" >&2
}

# ════════════════════════════════════════════════════════════════════════════
# PURE / TESTABLE FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════

# _in_window → 0 iff the local hour is in [06, 24). ICS_NOW_HOUR overrides (tests).
# A clock we cannot read counts as "outside" (inert).
_in_window() {
  local h="${ICS_NOW_HOUR:-$(date +%H 2>/dev/null)}"
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  h=$((10#$h))
  [ "$h" -ge "$WINDOW_START_HOUR" ] && [ "$h" -lt "$WINDOW_END_HOUR" ]
}

# _is_excluded <crew> → 0 iff the name matches an exclusion glob.
_is_excluded() {
  local name="$1" g
  local -a globs
  # noglob while splitting: "oracle*" must stay a pattern, not expand to files
  # of whatever directory launchd happens to run us from.
  set -f; globs=($EXCLUDE_GLOBS); set +f
  for g in "${globs[@]}"; do
    # shellcheck disable=SC2254
    case "$name" in $g) return 0 ;; esac
  done
  return 1
}

# _is_uint <s> → 0 iff s is 1-6 plain digits. `[ a -lt b ]` ERRORS (rc 2) on anything else, and an `if`/`&&` reads
# that as "false": a typo in ICS_IDLE_MIN or ICS_MAX_PER_RUN would silently turn the threshold or the cap OFF. The
# 6-digit bound is a design limit (no real minute count or cap needs more), far below where `[` itself starts to error.
_is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}

# _clip <s> → s cut to 40 characters, anything that is not a plain name character turned into "?": an env value goes
# into a WARN line and a newline in it must not forge a log line (roster values are made single-line in
# _list_active_sessions).
_clip() { printf '%.40s' "$1" | tr -c 'A-Za-z0-9_.@:+-' '?'; }

# _mtime <file> → epoch seconds; nothing + rc1 if unreadable. GNU stat FIRST: on a GNU stat `-f` means "filesystem
# status" and prints that whole block on STDOUT before failing on the `%m` operand, so the BSD form first returns
# garbage on Linux; on a BSD stat `-c` is an illegal option (usage on stderr, rc 1, stdout empty) and the BSD form runs.
_mtime() {
  # vazio (stat sem saída) → nada + rc 1; falhou/ilegível (stat falha ou imprime algo que não é época) → o chamador (_transcript_idle_min) descarta o arquivo: sem época válida a crew fica "desconhecida", inerte
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# _transcript_idle_min <work_dir> → prints whole minutes since the newest
# transcript write. rc 0 = known; rc 2 = could not tell (no dir, no jsonl,
# unreadable) — the caller treats that as NOT idle.
_transcript_idle_min() {
  local wd="$1" slug dir newest f m now
  [ -n "$wd" ] || return 2
  slug="$(printf '%s' "$wd" | sed 's#[^A-Za-z0-9]#-#g')"
  dir="${PROJECTS_DIR}/${slug}"
  # vazio (sem jsonl) → rc 2 "unknown", sessão não é suspensa; falhou/ilegível (dir ausente, stat falha) → mesmo rc 2
  [ -d "$dir" ] || return 2
  newest=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m="$(_mtime "$f")" || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -gt "$newest" ] && newest="$m"
  done < <(find "$dir" -maxdepth 3 -name '*.jsonl' -type f 2>/dev/null)
  [ "$newest" -gt 0 ] || return 2
  now="$(date +%s)"
  [ "$now" -ge "$newest" ] || { printf '0'; return 0; }
  printf '%s' $(( (now - newest) / 60 ))
}

# _inprogress_state <identity> <store_path> → prints "0" (none), "N" (N>0) or
# "?" (could not tell: bd failed / timed out / answered something that is not a
# JSON list). Only "0" lets a suspension proceed.
_inprogress_state() {
  local ident="$1" store="$2" out n
  [ -n "$ident" ] && [ -n "$store" ] || { printf '?'; return 0; }
  # vazio ([]) → "0" (nada atribuído); falhou/ilegível (bd erro, timeout, JSON inválido) → "?" (inerte, não suspende)
  # </dev/null: the caller sits inside `while read … <<< "$rows"`; a bd that reads stdin (the node's ssh shim does, measured 13/11) would eat the rest of the roster
  out="$(timeout 30 "$BD" -C "$store" list --status in_progress --assignee "$ident" --json --limit 0 2>/dev/null </dev/null)" \
    || { printf '?'; return 0; }
  n="$(printf '%s' "$out" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
print(len(d) if isinstance(d, list) else "?")
' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$n" ;; esac
}

# _acquire_lock / _release_lock — one instance at a time (launchd StartInterval
# does not wait for the previous run).
_acquire_lock() {
  mkdir -p "$RUN_DIR" 2>/dev/null || return 1
  if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; return 0; fi
  local p c
  p="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    # pid vivo: só é trava velha se o ps LEU outro comando (pid reaproveitado, ex. depois de um reboot: o lock mora em ~/.gastown/run e sobrevive). vazio (ps sem saída) → dúvida → a outra instância é a dona; falhou/ilegível → idem
    c="$(ps -p "$p" -o command= 2>/dev/null)"
    case "$c" in ''|*idle-crew-suspender*) return 1 ;; esac
  fi
  # stale lock (owner gone, or pid file unreadable AND dir older than 10 min)
  if [ -z "$p" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then return 1; fi
  rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null
  mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_DIR/pid"
}
_release_lock() { rm -f "$LOCK_DIR/pid" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null; return 0; }

# _list_active_sessions → one line per state=active session, the fields joined by the unit separator (0x1f; `read`
# collapses runs of a tab or a space, so a tab-joined row with an EMPTY field would shift every field after it):
#   id name alias template attached session_name agent_name
# Control characters in a value become spaces, so one session is always exactly one line. rc 3 = the answer was not a
# JSON object with a `sessions` list (could not tell).
_list_active_sessions() {
  local raw rc
  # vazio (sessions: []) → saída vazia rc 0; falhou/ilegível (gc erro, timeout, JSON sem "sessions") → rc 3, nada é suspenso
  raw="$(timeout 60 "$GC" session list --json 2>/dev/null </dev/null)"; rc=$?
  [ $rc -eq 0 ] && [ -n "$raw" ] || return 3
  printf '%s' "$raw" | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
    rows = d["sessions"]
    assert isinstance(rows, list)
except Exception:
    sys.exit(3)
f = lambda s, k: re.sub(r"[\x00-\x1f\x7f]", " ", str(s.get(k) or ""))
for s in rows:
    if not isinstance(s, dict) or s.get("state") != "active" or s.get("closed") is True:
        continue
    att = s.get("attached")
    att = "false" if att is False else ("true" if att is True else "unknown")
    print("\x1f".join([f(s, "id"), f(s, "name"), f(s, "alias"), f(s, "template"), att, f(s, "session_name"), f(s, "agent_name")]))
'
}

# _session_state <id> → prints the session's current state, or "?" if unreadable.
_session_state() {
  local id="$1" raw st
  # vazio (id sumiu da lista) → "gone"; falhou/ilegível → "?"
  raw="$(timeout 60 "$GC" session list --json --state all 2>/dev/null </dev/null)" || { printf '?'; return 0; }
  st="$(printf '%s' "$raw" | ID="$id" python3 -I -c '
import json, os, sys
try:
    rows = json.load(sys.stdin)["sessions"]
except Exception:
    print("?"); sys.exit(0)
for s in rows:
    if isinstance(s, dict) and s.get("id") == os.environ["ID"]:
        print(s.get("state") or "?"); sys.exit(0)
print("gone")
' 2>/dev/null)"
  printf '%s' "${st:-?}"
}

# ════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════
main() {
  local t0=$SECONDS crews rows rc suspended=0 evaluated=0 skipped=0 drift=0
  local id name alias template attached session_name agent_name wd rig idle ident store st nm tried blocked src excluded
  local US=$'\x1f' NL=$'\n'

  _acquire_lock || { log "SKIP another run holds the lock ($LOCK_DIR)"; return 0; }
  trap _release_lock EXIT

  # An env value we cannot use must land in the inert state: `[ -lt ]` on text is an error that reads as "false" (the
  # threshold or the cap silently off), and any ICS_DRY_RUN other than 1 used to mean a real run.
  _is_uint "$IDLE_MIN" || { log "WARN ICS_IDLE_MIN='$(_clip "$IDLE_MIN")' is not a whole number of 1-6 digits — using the default 60"; IDLE_MIN=60; }
  _is_uint "$MAX_PER_RUN" || { log "WARN ICS_MAX_PER_RUN='$(_clip "$MAX_PER_RUN")' is not a whole number of 1-6 digits — using the default 3"; MAX_PER_RUN=3; }
  case "$DRY_RUN" in 0|1) ;; *) log "WARN ICS_DRY_RUN='$(_clip "$DRY_RUN")' is neither 0 nor 1 — running as a dry-run (nothing is suspended)"; DRY_RUN=1 ;; esac

  if ! _in_window; then
    log "OUTSIDE_WINDOW (06:00-24:00 only) — nothing evaluated"
    return 0
  fi

  # vazio (nenhuma crew Layer-1) → WARN e nada a fazer; falhou (agents dir ilegível) → mesmo resultado vazio, inerte
  crews="$(_layer1_crew_names 2>/dev/null)"
  if [ -z "$crews" ]; then log "WARN no Layer-1 crews derived from agents/*/agent.toml — nothing evaluated"; return 0; fi

  rows="$(_list_active_sessions)"; rc=$?
  if [ $rc -ne 0 ]; then log "ERR session list unreadable (rc=$rc) — nothing suspended"; return 1; fi

  while IFS="$US" read -r id name alias template attached session_name agent_name; do
    [ -n "$id" ] || continue
    if ! printf '%s\n' "$crews" | grep -Fxq -- "$template"; then      # not a named crew by template
      # …but a session whose alias, name or agent_name IS a crew name while its template is not means the template key drifted: that crew is never evaluated, so count it for the WARN below
      for nm in "$alias" "$name" "$agent_name"; do
        if [ -n "$nm" ] && printf '%s\n' "$crews" | grep -Fxq -- "$nm"; then drift=$((drift + 1)); break; fi
      done
      continue
    fi
    evaluated=$((evaluated + 1))

    # the oracle* floor is a "never": it reads every name that can spell a crew (template, alias, name, agent_name, session_name; the id is ga-wisp-<tail>), so an oracle session stays out however its row is spelled
    excluded=""
    for nm in "$template" "$alias" "$name" "$agent_name" "$session_name"; do
      if [ -n "$nm" ] && _is_excluded "$nm"; then excluded="$nm"; break; fi
    done
    if [ -n "$excluded" ]; then
      log "KEEP crew=$template id=$id reason=excluded(oracle*) matched=$excluded"; skipped=$((skipped + 1)); continue
    fi
    if [ "$attached" != "false" ]; then
      log "KEEP crew=$template id=$id reason=attached=$attached"; skipped=$((skipped + 1)); continue
    fi
    wd="$(_agent_work_dir "$template")" && rig="$(_rig_path_for_work_dir "$wd")" || {
      log "KEEP crew=$template id=$id reason=work_dir/rig-unknown"; skipped=$((skipped + 1)); continue; }
    idle="$(_transcript_idle_min "$wd")" || {
      log "KEEP crew=$template id=$id reason=transcript-unknown"; skipped=$((skipped + 1)); continue; }
    if [ "$idle" -lt "$IDLE_MIN" ]; then
      log "KEEP crew=$template id=$id reason=transcript-recent idle_min=$idle"; skipped=$((skipped + 1)); continue
    fi

    # A bead's assignee may name this session by any of its names, and the roster gives six (id, session_name, name,
    # alias, agent_name, template — the set bead_state and config-drift-wake use). A crew's live beads can sit under
    # its session_name (<alias>-gawisp<tail>) and not under its alias (gate FAIL 14/11: wa-zmxywv.51 was assigned
    # to thies-wa-gawisp3j5vr6, a name the old four-name list never asked). Every distinct name is asked, in the crew's
    # rig store AND the HQ store; a crew's alias, name, agent_name and template are usually one string, asked once.
    blocked=""; tried="$NL"
    for ident in "$alias" "$session_name" "$id" "$name" "$agent_name" "$template"; do
      [ -n "$ident" ] || continue
      case "$tried" in *"${NL}${ident}${NL}"*) continue ;; esac
      tried="${tried}${ident}${NL}"
      for store in "$rig" "$CITY"; do
        st="$(_inprogress_state "$ident" "$store")"
        if [ "$st" != "0" ]; then blocked="in_progress=${st} as=${ident} store=${store##*/}"; break 2; fi
      done
    done
    if [ -n "$blocked" ]; then
      log "KEEP crew=$template id=$id reason=bead($blocked) idle_min=$idle"; skipped=$((skipped + 1)); continue
    fi

    if [ "$suspended" -ge "$MAX_PER_RUN" ]; then
      log "KEEP crew=$template id=$id reason=per-run-cap($MAX_PER_RUN) idle_min=$idle"; skipped=$((skipped + 1)); continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
      log "WOULD_SUSPEND crew=$template id=$id idle_min=$idle (dry-run)"; suspended=$((suspended + 1)); continue
    fi

    # </dev/null: this sits inside `while read … <<< "$rows"`; a gc that reads stdin would eat the crews still to come
    timeout 90 "$GC" session suspend "$id" >/dev/null 2>&1 </dev/null; src=$?
    sleep "${ICS_VERIFY_SLEEP:-3}"
    # on the managed path `gc session suspend` only sets the operator hold and pokes the controller (the reconciler stops the runtime later), and a gc killed by our timeout may have set the hold already: the exit code alone says nothing, so the state is read either way
    st="$(_session_state "$id")"
    if [ "$src" -eq 0 ]; then
      case "$st" in
        active|"?"|gone|start-pending|creating) log "SUSPEND_UNCONFIRMED crew=$template id=$id idle_min=$idle state_after=$st" ;;
        *) log "SUSPENDED crew=$template id=$id idle_min=$idle state_after=$st" ;;
      esac
      suspended=$((suspended + 1))
    else
      case "$st" in
        # still running: nothing changed, so it is not counted and the next crew is still tried
        active|start-pending|creating) log "SUSPEND_FAILED crew=$template id=$id idle_min=$idle (gc session suspend rc=$src, session still $st)" ;;
        # state unreadable or session gone from the list: it may have landed, so it counts toward the cap
        "?"|gone) log "SUSPEND_UNKNOWN crew=$template id=$id idle_min=$idle rc=$src state_after=$st (the suspend may have landed)"; suspended=$((suspended + 1)) ;;
        *) log "SUSPENDED crew=$template id=$id idle_min=$idle state_after=$st (gc exited rc=$src, the state shows it suspended)"; suspended=$((suspended + 1)) ;;
      esac
    fi
  done <<< "$rows"

  [ "$drift" -eq 0 ] || log "WARN ${drift} active session(s) answer to a Layer-1 crew name by alias/name/agent_name but not by template — the template key drifted? They were NOT evaluated"
  log "RUN done evaluated=$evaluated suspended=$suspended kept=$skipped dry_run=$DRY_RUN dur=$((SECONDS - t0))s"
  return 0
}

if [ "${ICS_LIB:-0}" != "1" ]; then
  main "$@"
fi
