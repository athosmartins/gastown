#!/usr/bin/env bash
# gate-postmerge.lib.sh — ga-qmymjm: the gate's POST-MERGE TAIL runs outside the sweep, so the next review is admitted sooner.
#
# WHY. Measured over 50 rounds (ga-bk5j8u.1): once the reviewers have judged, finishing the run takes a median 2.1 min (merge 0.8 + what comes
# after the merge 1.3, p90 3.4), all of it inside the sweep that holds the gate lock — the next review is admitted only after it. What comes after
# the merge is the source bead's hand-off or close: label/comment writes, the rig deploy, daemon-refresh, the hold checks, the re-spawn verify, the
# reaper, the mails and notifications. None of it decides whether the NEXT branch may be reviewed.
#
# WHAT. After the merge is confirmed, the integrity check has passed, and the marker and the gate-run are terminal (and sibling runs superseded),
# the dispatcher forks the tail into its own process group (set -m) — launchd kills the job's process group when the sweep exits, so a plain `&`
# would be cut short — and goes on. The tail is the SAME code, in the same order, in a forked copy of the shell; only WHERE it runs changed.
# The tail serialises only the part that needs it: the deploy + daemon-refresh of one runtime dir (gate_pm_deploy_lock_*). Two merges to the same rig
# used to be serial because the sweep was; now they are serial because of that lock.
#
# THE THIRD STATE (a failed tail is never a silent one). Every tail leaves exactly one durable trace:
#   done    postmerge_done   (outcome: closed | handoff | held:partial | held:daemon:<VERDICT> | held:sibling | held:own | held:vm |
#                             unresolved:close-failed | unresolved:respawn-vector | skipped)  — the job file is removed
#   failed  postmerge_failed (the shell exited non-zero, or was TERM/HUP/INT-ed; step + rc) — job file moved to failed/, label gate:postmerge-failed
#                             + a comment on the source bead + a nudge to the Mayor
#   lost    postmerge_lost   (the process vanished without running its exit handler: SIGKILL, reboot, power) — found by the next sweep
#                             (gate_pm_sweep): job file with no live process; moved to lost/, label gate:postmerge-lost + comment + nudge
# Detection only: a lost tail is NOT re-run. It may have half-run (a deploy done, the close not), and a repair that cannot tell "lost" from
# "slow" breaks good work. The bead comment names the last step reached, so a human knows where to look.
#
# KILL SWITCH. GATE_POSTMERGE_ASYNC=0 (env) or the file $GC_CITY/.gc/gate-postmerge.off → the tail runs inline, in the sweep's own shell, exactly
# as before this lib existed; no redeploy needed (read every merge). A lib that does not load does the same.
#
# Source-only: defines functions and runs NOTHING at source time. The dispatcher is `set -euo pipefail` on bash 3.2: no arrays, no ${v,,}, no
# BASHPID, every command that may fail is guarded, every function returns 0 unless its header says otherwise.
# CLI:  bash gate-postmerge.lib.sh stats   →  pending / failed / lost counts and the last 24 h of events.

# ── plumbing ─────────────────────────────────────────────────────────────────
gate_pm_dir() { printf '%s' "${GATE_PM_DIR:-${GC_CITY:-/nonexistent}/.gc/runtime/gate-postmerge}"; }

_gate_pm_say()  { if declare -F log  >/dev/null 2>&1; then log  "$@"; else printf '%s\n' "$*"; fi; }
_gate_pm_warn() { if declare -F warn >/dev/null 2>&1; then warn "$@"; else printf 'WARN: %s\n' "$*" >&2; fi; }

# _gate_pm_key <gate-run-id> [marker-id] — a filename-safe key. A run bead that does not exist ("unknown", empty) must not make every such job share
# one key, so the marker (always there) stands in for it.
_gate_pm_key() {
  case "${1:-}" in
    ''|unknown) printf 'm-%s' "${2:-}" | tr -c 'A-Za-z0-9._-' '_' ;;
    *)          printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' ;;
  esac
}

# gate_pm_enabled — rc 0 iff the async tail is switched on. OFF = GATE_POSTMERGE_ASYNC is a literal 0, or the off-file exists. Anything else
# (unset, 1, a typo) is ON: a switch nobody can read must not silently turn the optimisation off, and the inline path is the safe one anyway.
gate_pm_enabled() {
  case "${GATE_POSTMERGE_ASYNC:-1}" in 0) return 1 ;; esac
  [ -e "${GATE_PM_OFF_FILE:-${GC_CITY:-/nonexistent}/.gc/gate-postmerge.off}" ] && return 1
  return 0
}

# gate_pm_event <event> [name value]... — one jsonl line on the gate log, tagged with the job in GATE_PM_*. rc 1 when it could not be written.
# Names rc / elapsed_s / lock_wait_s / age_s are numbers when the value is digits, strings otherwise (never a made-up 0).
gate_pm_event() {
  local ev="$1" extra='{}' k v out
  shift
  while [ "$#" -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    case "$k" in
      rc|elapsed_s|lock_wait_s|age_s)
        case "$v" in
          ''|*[!0-9]*) extra=$(printf '%s' "$extra" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' 2>/dev/null) || return 1 ;;
          *)           extra=$(printf '%s' "$extra" | jq -c --arg k "$k" --argjson v "$v" '. + {($k): $v}' 2>/dev/null) || return 1 ;;
        esac ;;
      *) extra=$(printf '%s' "$extra" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' 2>/dev/null) || return 1 ;;
    esac
  done
  out="${QG_LOG:-${GC_CITY:-/nonexistent}/.gc/quality-gate.jsonl}"
  jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$ev" \
    --arg gate_run "${GATE_PM_RUN:-}" --arg marker "${GATE_PM_MARKER:-}" --arg bead "${GATE_PM_BEAD:-}" \
    --arg rig "${GATE_PM_RIG:-}" --arg branch "${GATE_PM_BRANCH:-}" --arg merge_sha "${GATE_PM_SHA:-}" --argjson extra "$extra" \
    '{ts:$ts, event:$event, gate_run:$gate_run, marker:$marker, bead:$bead, rig:$rig, branch:$branch, merge_sha:$merge_sha} + $extra' \
    >> "$out" 2>/dev/null || return 1
  return 0
}

# _gate_pm_job_get <job-file> <key> — prints the value of key=value, empty when absent/unreadable.
_gate_pm_job_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true; }

# _gate_pm_load_job <job-file> — fills GATE_PM_* from a job file (the sweep's lost-tail report needs the job's identity, not the sweep's).
_gate_pm_load_job() {
  GATE_PM_RUN=$(_gate_pm_job_get "$1" gate_run);   GATE_PM_MARKER=$(_gate_pm_job_get "$1" marker)
  GATE_PM_BEAD=$(_gate_pm_job_get "$1" bead);       GATE_PM_BEAD_CITY=$(_gate_pm_job_get "$1" bead_city)
  GATE_PM_RIG=$(_gate_pm_job_get "$1" rig);         GATE_PM_BRANCH=$(_gate_pm_job_get "$1" branch)
  GATE_PM_SHA=$(_gate_pm_job_get "$1" merge_sha);   GATE_PM_KEY=$(_gate_pm_key "$GATE_PM_RUN" "$GATE_PM_MARKER")
  return 0
}

# _gate_pm_flag_bead <label> <comment> — the durable, human-visible half of a failed/lost report. Best effort, said out loud when it cannot be done.
_gate_pm_flag_bead() {
  [ -n "${GATE_PM_BEAD:-}" ] || return 0
  local city="${GATE_PM_BEAD_CITY:-${GC_CITY:-}}"
  bd -C "$city" label add "$GATE_PM_BEAD" "$1" -q 2>/dev/null \
    || _gate_pm_warn "ga-qmymjm: could not add label $1 to $GATE_PM_BEAD — the report is in the gate log and in $(gate_pm_dir)"
  bd -C "$city" comment "$GATE_PM_BEAD" "$2" 2>/dev/null \
    || _gate_pm_warn "ga-qmymjm: could not comment on $GATE_PM_BEAD — the report is in the gate log and in $(gate_pm_dir)"
  return 0
}

# ── the parent side (runs in the sweep, before the fork) ─────────────────────
# gate_pm_begin <gate-run> <marker> <bead> <bead-city> <rig> <branch> <merge-sha> — registers the job. rc 0 = go async; rc 1 = run the tail inline
# (switched off, jq missing, directory or job file not writable). The registration is what makes a lost tail findable, so no registration = no async.
gate_pm_begin() {
  GATE_PM_RUN="${1:-}"; GATE_PM_MARKER="${2:-}"; GATE_PM_BEAD="${3:-}"; GATE_PM_BEAD_CITY="${4:-}"
  GATE_PM_RIG="${5:-}"; GATE_PM_BRANCH="${6:-}"; GATE_PM_SHA="${7:-}"
  GATE_PM_KEY=$(_gate_pm_key "$GATE_PM_RUN" "$GATE_PM_MARKER")
  gate_pm_enabled || return 1                       # switched off: quiet, that is what the switch is for
  local d tmp why=""
  d="$(gate_pm_dir)"
  # From here on async WAS wanted. Each way it cannot be set up is said once, then the tail runs inline (the old, slower, safe path).
  if ! command -v jq >/dev/null 2>&1; then why="jq not found"
  elif [ -z "$GATE_PM_KEY" ]; then why="no usable job key (gate_run='${GATE_PM_RUN}', marker='${GATE_PM_MARKER}')"
  elif ! mkdir -p "$d/pending" "$d/failed" "$d/lost" "$d/deploy-lock" 2>/dev/null; then why="cannot create $d"
  fi
  if [ -n "$why" ]; then _gate_pm_warn "ga-qmymjm: post-merge tail of ${GATE_PM_RUN:-?} runs INLINE (async not possible: $why)"; return 1; fi
  tmp="$d/pending/.$GATE_PM_KEY.job.$$"
  {
    printf 'gate_run=%s\n'      "$GATE_PM_RUN"
    printf 'marker=%s\n'        "$GATE_PM_MARKER"
    printf 'bead=%s\n'          "$GATE_PM_BEAD"
    printf 'bead_city=%s\n'     "$GATE_PM_BEAD_CITY"
    printf 'rig=%s\n'           "$GATE_PM_RIG"
    printf 'branch=%s\n'        "$GATE_PM_BRANCH"
    printf 'merge_sha=%s\n'     "$GATE_PM_SHA"
    printf 'registered_at=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; _gate_pm_warn "ga-qmymjm: post-merge tail of ${GATE_PM_RUN:-?} runs INLINE (async not possible: cannot write the job file in $d/pending)"; return 1; }
  rm -f "$d/pending/$GATE_PM_KEY.pid" "$d/pending/$GATE_PM_KEY.step" 2>/dev/null || true
  mv -f "$tmp" "$d/pending/$GATE_PM_KEY.job" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; _gate_pm_warn "ga-qmymjm: post-merge tail of ${GATE_PM_RUN:-?} runs INLINE (async not possible: cannot place the job file in $d/pending)"; return 1; }
  gate_pm_event postmerge_deferred || _gate_pm_warn "ga-qmymjm: could not write the postmerge_deferred event for $GATE_PM_RUN (the job file is the record)"
  return 0
}

# gate_pm_after_fork <child-pid> — the sweep's own line saying the tail left.
gate_pm_after_fork() {
  _gate_pm_say "ga-qmymjm: post-merge tail of gate_run=${GATE_PM_RUN:-?} (bead=${GATE_PM_BEAD:-?}, sha=${GATE_PM_SHA:-?}) forked as pid ${1:-?} in its own process group — the sweep goes on without waiting for it."
  return 0
}

# ── the child side (runs in the forked subshell) ─────────────────────────────
# gate_pm_child_init — first line of the subshell: pid file, own heartbeat, exit handler.
gate_pm_child_init() {
  GATE_PM_T0=$(date +%s); GATE_PM_OK=0; GATE_PM_OUTCOME=""; GATE_PM_STEP="start"; GATE_PM_LOCK_WAITED_S=0
  # bash 3.2 has no BASHPID: in a subshell, $$ is still the parent's pid. A child `sh` knows its parent — which is this subshell. The `exec` is
  # not decoration: without it bash 3.2 forks once more for the command substitution and `sh` reports THAT transient process (measured: off by
  # one from $!), which would make the sweep call every live tail lost.
  GATE_PM_CHILD_PID=$(exec sh -c 'echo $PPID' 2>/dev/null) || GATE_PM_CHILD_PID=""
  case "$GATE_PM_CHILD_PID" in ''|*[!0-9]*) GATE_PM_CHILD_PID="$$" ;; esac
  printf '%s\n' "$GATE_PM_CHILD_PID" > "$(gate_pm_dir)/pending/${GATE_PM_KEY:-nokey}.pid" 2>/dev/null || true
  # log() refreshes the DISPATCHER's liveness file; the tail is not the sweep and must not vouch for it.
  _GATE_HB_FILE="${LOG_DIR:-${GC_CITY:-/tmp}/.gc/logs}/quality-gate-postmerge.heartbeat"
  trap 'exit 143' TERM; trap 'exit 129' HUP; trap 'exit 130' INT
  trap 'gate_pm_child_exit $?' EXIT
  _gate_pm_say "ga-qmymjm: post-merge tail START gate_run=${GATE_PM_RUN:-?} bead=${GATE_PM_BEAD:-?} sha=${GATE_PM_SHA:-?} pid=$GATE_PM_CHILD_PID"
  return 0
}

# gate_pm_step <name> — the last step reached, kept in a file so a lost tail can say where it stopped.
gate_pm_step() {
  GATE_PM_STEP="${1:-?}"
  printf '%s\n' "$GATE_PM_STEP" > "$(gate_pm_dir)/pending/${GATE_PM_KEY:-nokey}.step" 2>/dev/null || true
  return 0
}

# gate_pm_outcome — what the tail did to the source bead, read from the tail's own flags (all optional: unset = 0).
gate_pm_outcome() {
  if [ -z "${BEAD_ID:-}" ] || [ "${DRY_RUN:-0}" = "1" ]; then printf 'skipped'; return 0; fi
  if   [ "${IS_STORY:-0}" = "1" ];        then printf 'handoff'
  elif [ "${IS_PARTIAL:-0}" = "1" ];      then printf 'held:partial'
  elif [ "${IS_DAEMON_HOLD:-0}" = "1" ];  then printf 'held:daemon:%s' "${DAEMON_HOLD_VERDICT:-unknown}"
  elif [ "${IS_SIBLING_HOLD:-0}" = "1" ]; then printf 'held:sibling'
  elif [ "${IS_OWN_HOLD:-0}" = "1" ];     then printf 'held:own'
  elif [ "${IS_VM_HOLD:-0}" = "1" ];      then printf 'held:vm'
  elif [ "${GATE_PM_CLOSE_FAILED:-0}" = "1" ]; then printf 'unresolved:close-failed'
  elif [ -n "${RESPAWN_HITS:-}" ];        then printf 'unresolved:respawn-vector'
  else printf 'closed'; fi
  return 0
}

# gate_pm_child_ok — the last line of the subshell: the tail ran to its end. The exit handler reads this to tell "finished" from "stopped".
gate_pm_child_ok() { GATE_PM_OK=1; GATE_PM_OUTCOME=$(gate_pm_outcome); return 0; }

# gate_pm_child_exit <rc> — the EXIT trap. Releases the deploy lock, then writes the ONE durable trace (see THE THIRD STATE). The job file goes
# first and the pid file second, so a sweep that sees a job with no pid can trust it is not a tail caught mid-cleanup (it re-checks the job too).
gate_pm_child_exit() {
  local rc="${1:-0}" d el key
  trap - EXIT TERM HUP INT
  d="$(gate_pm_dir)"; key="${GATE_PM_KEY:-nokey}"
  el=$(( $(date +%s) - ${GATE_PM_T0:-$(date +%s)} ))
  gate_pm_deploy_lock_release || true
  if [ "${GATE_PM_OK:-0}" = "1" ] && [ "$rc" = "0" ]; then
    gate_pm_event postmerge_done outcome "${GATE_PM_OUTCOME:-closed}" rc 0 elapsed_s "$el" lock_wait_s "${GATE_PM_LOCK_WAITED_S:-0}" \
      || _gate_pm_warn "ga-qmymjm: could not write the postmerge_done event for ${GATE_PM_RUN:-?}"
    _gate_pm_say "ga-qmymjm: post-merge tail DONE gate_run=${GATE_PM_RUN:-?} bead=${GATE_PM_BEAD:-?} outcome=${GATE_PM_OUTCOME:-closed} elapsed=${el}s"
    rm -f "$d/pending/$key.job" "$d/pending/$key.pid" "$d/pending/$key.step" 2>/dev/null || true
    return 0
  fi
  _gate_pm_warn "ga-qmymjm: post-merge tail FAILED gate_run=${GATE_PM_RUN:-?} bead=${GATE_PM_BEAD:-?} step=${GATE_PM_STEP:-?} rc=$rc elapsed=${el}s — the source bead may be half-transitioned"
  gate_pm_event postmerge_failed step "${GATE_PM_STEP:-?}" rc "$rc" elapsed_s "$el" \
    || _gate_pm_warn "ga-qmymjm: could not write the postmerge_failed event for ${GATE_PM_RUN:-?} (the failed/ job file, the bead label and the log line are the record)"
  { printf 'step=%s\n' "${GATE_PM_STEP:-?}"; printf 'rc=%s\n' "$rc"; printf 'failed_at=%s\n' "$(date +%s)"; } >> "$d/pending/$key.job" 2>/dev/null || true
  mv -f "$d/pending/$key.job" "$d/failed/$key.job" 2>/dev/null || true
  rm -f "$d/pending/$key.pid" "$d/pending/$key.step" 2>/dev/null || true
  _gate_pm_flag_bead "gate:postmerge-failed" "GATE POST-MERGE TAIL FAILED (ga-qmymjm). The merge of $GATE_PM_BRANCH (sha=$GATE_PM_SHA, gate_run=$GATE_PM_RUN) is IN main and its marker and gate-run are terminal, but the work that follows the merge stopped at step '${GATE_PM_STEP:-?}' (rc=$rc, after ${el}s). This bead may be half-transitioned: some of {gate:passed label, assignee cleared, rig deploy, daemon check, hold or close, re-spawn verify} may not have happened. Nothing re-runs it. ACTION: read $(gate_pm_dir)/failed/$key.job and the dispatcher log around 'post-merge tail' for gate_run=$GATE_PM_RUN, finish the transition by hand (or re-submit if nothing happened), then remove this label."
  gc --city "${GC_CITY:-}" session nudge mayor "Gate post-merge tail FAILED for ${GATE_PM_BEAD:-?} (gate_run=${GATE_PM_RUN:-?}) at step ${GATE_PM_STEP:-?}, rc=$rc — see the bead comment (ga-qmymjm)." 2>/dev/null || true
  return 0
}

# ── the deploy mutex (the one thing the old sweep lock serialised that still has to be serial) ──
# gate_pm_deploy_lock_acquire <runtime-dir> — rc 0 acquired (or nothing to lock); rc 75 waited GATE_PM_DEPLOY_LOCK_WAIT_S (900) and the lock is
# still held by a LIVE tail — the caller must HOLD the bead (a deploy it could not run is not a deploy that was clean); any other rc = the lock
# itself is unusable (directory not writable): the caller carries on, because that is what it did before this lock existed.
# A lock whose owner pid is dead, or older than GATE_PM_DEPLOY_LOCK_MAX_AGE_S (1800), is taken over (one winner, by an atomic rename).
gate_pm_deploy_lock_acquire() {
  local rt="${1:-}" d lk h wait_max max_age t0 now owner opid oat omt dead grave
  [ -n "$rt" ] || return 0
  d="$(gate_pm_dir)/deploy-lock"
  mkdir -p "$d" 2>/dev/null || return 2
  h=$(printf '%s' "$rt" | cksum | cut -d' ' -f1)
  lk="$d/$h.d"
  wait_max="${GATE_PM_DEPLOY_LOCK_WAIT_S:-900}"; max_age="${GATE_PM_DEPLOY_LOCK_MAX_AGE_S:-1800}"
  case "$wait_max" in ''|*[!0-9]*) wait_max=900 ;; esac
  case "$max_age" in ''|*[!0-9]*) max_age=1800 ;; esac
  t0=$(date +%s)
  while :; do
    if mkdir "$lk" 2>/dev/null; then
      printf '%s:%s:%s\n' "${GATE_PM_CHILD_PID:-$$}" "$(date +%s)" "${GATE_PM_KEY:-nokey}" > "$lk/owner" 2>/dev/null || true
      GATE_PM_LOCK_DIR="$lk"; GATE_PM_LOCK_WAITED_S=$(( $(date +%s) - t0 ))
      return 0
    fi
    now=$(date +%s)
    owner=$(head -n1 "$lk/owner" 2>/dev/null || true)
    opid="${owner%%:*}"; oat="${owner#*:}"; oat="${oat%%:*}"
    dead=0
    case "$opid" in
      ''|*[!0-9]*)
        # No readable owner: the holder died between mkdir and writing it, or never wrote it. Give it a minute before calling it dead.
        omt=$(stat -f %m "$lk" 2>/dev/null || echo "$now")
        if [ $(( now - omt )) -ge 60 ]; then dead=1; fi ;;
      *)
        if ! kill -0 "$opid" 2>/dev/null; then dead=1; fi
        case "$oat" in
          ''|*[!0-9]*) : ;;
          *) if [ $(( now - oat )) -ge "$max_age" ]; then dead=1; fi ;;
        esac ;;
    esac
    if [ "$dead" = "1" ]; then
      # The rename is the election: one taker wins, the rest see mv fail and just loop to mkdir.
      grave="$lk.dead.$$.$RANDOM"
      if mv "$lk" "$grave" 2>/dev/null; then
        _gate_pm_warn "ga-qmymjm: deploy lock for $rt was held by a dead or over-age owner (${owner:-no owner file}) — taken over."
        rm -f "$grave/owner" 2>/dev/null || true
        rmdir "$grave" 2>/dev/null || true
      fi
      continue
    fi
    if [ $(( now - t0 )) -ge "$wait_max" ]; then
      GATE_PM_LOCK_WAITED_S=$(( now - t0 ))
      _gate_pm_warn "ga-qmymjm: deploy lock for $rt still held by a live tail (${owner:-?}) after ${GATE_PM_LOCK_WAITED_S}s — giving up; the bead will be HELD, not closed."
      return 75
    fi
    sleep "${GATE_PM_DEPLOY_LOCK_POLL_S:-2}"
  done
}

# gate_pm_deploy_lock_release — idempotent; removes the lock only if this process still owns it.
gate_pm_deploy_lock_release() {
  local lk="${GATE_PM_LOCK_DIR:-}" owner
  [ -n "$lk" ] || return 0
  owner=$(head -n1 "$lk/owner" 2>/dev/null || true)
  case "$owner" in
    "${GATE_PM_CHILD_PID:-$$}":*) rm -f "$lk/owner" 2>/dev/null || true; rmdir "$lk" 2>/dev/null || true ;;
  esac
  GATE_PM_LOCK_DIR=""
  return 0
}

# ── the sweep's side: find the tails that vanished ───────────────────────────
# gate_pm_sweep — call once per sweep, under the gate lock (so there is ONE reporter). For every pending job: alive → leave it (and say so when it
# has run for over GATE_PM_STUCK_AFTER_S, 3600 — never killed, only said); no live process → LOST: report once, move to lost/. A job with no pid
# file yet gets GATE_PM_START_GRACE_S (120) — the fork happened, the child has not written its pid.
gate_pm_sweep() {
  local d f key reg now age pid cmd alive pending=0 oldest=0 lost=0 step
  d="$(gate_pm_dir)"
  [ -d "$d/pending" ] || return 0
  now=$(date +%s)
  for f in "$d"/pending/*.job; do
    [ -e "$f" ] || continue
    key=$(basename "$f" .job)
    pending=$((pending + 1))
    reg=$(_gate_pm_job_get "$f" registered_at)
    case "$reg" in ''|*[!0-9]*) reg=$(stat -f %m "$f" 2>/dev/null || echo "$now") ;; esac     # damaged job file: its mtime, never "just now"
    age=$(( now - reg ))
    if [ "$age" -gt "$oldest" ]; then oldest="$age"; fi
    alive=0
    pid=$(head -n1 "$d/pending/$key.pid" 2>/dev/null || true); case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    if [ -n "$pid" ]; then
      if kill -0 "$pid" 2>/dev/null; then
        cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
        case "$cmd" in
          '') alive=1 ;;      # the process exists but ps would not say what it is: "lost" is a claim, and we cannot back it — stay quiet
          *"${GATE_PM_PROC_PATTERN:-quality-gate-dispatcher}"*) alive=1 ;;
        esac                  # a readable command line that is NOT the dispatcher = the pid was reused by something else: the tail is gone
      fi
    elif [ "$age" -lt "${GATE_PM_START_GRACE_S:-120}" ]; then
      alive=1
    fi
    if [ "$alive" = "1" ]; then
      if [ "$age" -gt "${GATE_PM_STUCK_AFTER_S:-3600}" ]; then
        _gate_pm_warn "ga-qmymjm: post-merge tail $key has been running for ${age}s (pid ${pid:-none}) — still alive, not touched"
      fi
      continue
    fi
    if [ ! -e "$f" ]; then continue; fi   # finished between the scan and now (it removes the job first)
    step=$(head -n1 "$d/pending/$key.step" 2>/dev/null || true)
    if ! mv "$f" "$d/lost/$key.job" 2>/dev/null; then continue; fi   # lost the race to another reporter: it reports, not us
    printf 'step=%s\nlost_reported_at=%s\nlast_pid=%s\n' "${step:-none}" "$now" "${pid:-none}" >> "$d/lost/$key.job" 2>/dev/null || true
    rm -f "$d/pending/$key.pid" "$d/pending/$key.step" 2>/dev/null || true
    _gate_pm_load_job "$d/lost/$key.job"
    lost=$((lost + 1)); pending=$((pending - 1))
    _gate_pm_warn "ga-qmymjm: post-merge tail LOST gate_run=${GATE_PM_RUN:-?} bead=${GATE_PM_BEAD:-?} — no live process (pid ${pid:-none}), last step '${step:-none}', registered ${age}s ago"
    gate_pm_event postmerge_lost step "${step:-none}" age_s "$age" \
      || _gate_pm_warn "ga-qmymjm: could not write the postmerge_lost event for ${GATE_PM_RUN:-?} (the lost/ job file, the bead label and the log line are the record)"
    _gate_pm_flag_bead "gate:postmerge-lost" "GATE POST-MERGE TAIL LOST (ga-qmymjm). The merge of $GATE_PM_BRANCH (sha=$GATE_PM_SHA, gate_run=$GATE_PM_RUN) is IN main and its marker and gate-run are terminal, but the process that was finishing the work after the merge vanished without a trace (killed hard, or the machine restarted) at step '${step:-none}', ${age}s after the merge. This bead may be half-transitioned: some of {gate:passed label, assignee cleared, rig deploy, daemon check, hold or close, re-spawn verify} may not have happened. Nothing re-runs it (it may have half-run). ACTION: read $d/lost/$key.job and the dispatcher log around 'post-merge tail' for gate_run=$GATE_PM_RUN, finish the transition by hand (or re-submit if nothing happened), then remove this label."
    gc --city "${GC_CITY:-}" session nudge mayor "Gate post-merge tail LOST for ${GATE_PM_BEAD:-?} (gate_run=${GATE_PM_RUN:-?}) at step ${step:-none} — see the bead comment (ga-qmymjm)." 2>/dev/null || true
  done
  if [ "$pending" -gt 0 ]; then _gate_pm_say "ga-qmymjm: post-merge tails in flight: ${pending} (oldest ${oldest}s)"; fi
  return 0
}

# gate_pm_stats [hours] — one line: what is waiting, what failed, what was lost (the files), and the event counts of the window (the log).
gate_pm_stats() {
  local d hours="${1:-24}" log nf nl np ev=""
  d="$(gate_pm_dir)"; log="${QG_LOG:-${GC_CITY:-/nonexistent}/.gc/quality-gate.jsonl}"
  np=$(ls "$d"/pending/*.job 2>/dev/null | wc -l | tr -d ' ' || true)
  nf=$(ls "$d"/failed/*.job  2>/dev/null | wc -l | tr -d ' ' || true)
  nl=$(ls "$d"/lost/*.job    2>/dev/null | wc -l | tr -d ' ' || true)
  if [ -r "$log" ] && command -v jq >/dev/null 2>&1; then
    ev=$(tail -n 20000 "$log" 2>/dev/null | jq -R -s -r --argjson h "$hours" '
      split("\n") | map(fromjson? // empty) | map(select((.event // "") | startswith("postmerge_")))
      | map(select(.ts != null and ((.ts | fromdateiso8601? // 0) > (now - $h * 3600))))
      | group_by(.event) | map("\(.[0].event)=\(length)") | join(" ")' 2>/dev/null || true)
  fi
  printf 'pending=%s failed_files=%s lost_files=%s last_%sh: %s\n' "$np" "$nf" "$nl" "$hours" "${ev:-none}"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    stats) gate_pm_stats "${2:-24}" ;;
    *) echo "usage: gate-postmerge.lib.sh stats [hours]" >&2; exit 2 ;;
  esac
fi
