#!/bin/bash
# claude-lowprio — ga-rj7b1a: launch `claude` at LOW CPU priority.
#
# WHY (ga-rj7b1a, 2026-09-19). The heavy suites the pool agents run (pilot-dispatcher.selftest.sh
# ~30 min, pytest -n 6, go test ...) ran at the SAME priority as Dolt and the supervisor. 23 concurrent
# test trees pushed the load average to 56-64 on 10 cores, Dolt got no CPU, the supervisor's
# demand_snapshot.load read 1795 s (normal ~60 s), the gate reviewer never came up and the whole
# pipeline stalled. Everything a session runs inherits the session's niceness, so lowering it ONCE, when
# the session is born, makes every test it ever starts low-priority BY CONSTRUCTION — no per-suite
# discipline, nothing for a builder to remember (or forget).
#
# HOW. This is the `command` of [providers.claude-headless] in city.toml (pool/ephemeral roles: dog,
# wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner). It renices ITSELF, then `exec`s the
# real claude with argv untouched. exec keeps the pid, so the tmux pane still runs `claude` and every
# process-name check is unchanged. The Mayor and human-attached crews stay on the plain `claude`
# provider at normal priority.
#
# macOS semantics (measured 2026-09-19 on this host):
#   * `renice N -p PID` is ABSOLUTE, and an unprivileged process can only RAISE its niceness: asking for
#     a value below the current one fails harmlessly (rc 1) and changes nothing.
#   * `renice -n N` is an INCREMENT and compounds (15 -> 20). Never used here.
#   * children and exec inherit niceness.
# So this only ever raises niceness, and never stacks on one already applied (an operator's `nice`, the
# Mayor's stopgap renice loop, a parent that was itself launched through this wrapper).
#
# KNOWN LIMITATION — anything a wrapped session starts as a BACKGROUND child inherits ni 15, and that
# includes `gc dolt start` (gc-beads-bd.sh: `nohup ... dolt sql-server &`). A Dolt restarted BY HAND from a
# wrapped session (deacon, boot, dog) would itself run at ni 15 — the starvation this wrapper exists to
# prevent, in reverse. The supervisor's own respawn is unaffected (ni 0, launchd child; the running Dolt is
# ni 0 today). Do not restart Dolt from a pool session; check `ps -o ni= -p <dolt pid>` after any manual start.
#
# FAIL-OPEN, NOT SILENT. Priority is a courtesy to Dolt; it must never stop an agent from starting, so
# every failure path still execs claude. But "did it work" is never left unknowable: every launch appends
# one line to $GC_CITY_PATH/.gc/logs/claude-lowprio.log (SET / KEEP / SKIP / WARN, with ni before->after),
# so "is the fleet actually low-priority" is one awk away, and a failed renice is a visible WARN line
# instead of an absence.
#
# KNOBS
#   GC_LOWPRIO=0                  no renice for this launch (environment)
#   $GC_CITY_PATH/.gc/no-lowprio  no renice for EVERY new launch (touch it / rm it — no config reload)
#   GC_LOWPRIO_NICE=N             target niceness, 1-20. Default 15 = the value of the Mayor's 2026-09-19
#                                 stopgap, which measured supervisor demand 1795 s -> 315 s, load 64 -> 34.
#   GC_LOWPRIO_CLAUDE_BIN=PATH    the real claude (test seam). Default: `claude` from PATH, exactly what
#                                 the builtin provider would have run.
#
# EFFORT A/B (ga-5c3msy, E8 of P0 ga-ufskhy) — a second job of this wrapper, INERT unless
# $GC_CITY_PATH/.gc/effort-ab.conf exists. The metric is tokens per APPROVED bead, and the open question is
# whether the builders (dog / wa-worker / ps-worker, all `--effort xhigh`) can run at `high` without the
# gate approving less. Effort is a per-TEMPLATE setting in city.toml, so a per-session arm has to be decided
# where the session is born: here, before exec, from a salted SHA-256.
#
# UNIT OF RANDOMIZATION = the claude SESSION, identified by its OWN uuid: the `--session-id` it is launched
# with (or the `--resume` of that same session). That uuid is the transcript's file name and the token
# ledger's `sid`, so the unit the arm is drawn on is the unit the meter reads. It is deliberately NOT
# GC_SESSION_NAME: the dogs measured on 01/10 get a name unique per launch (alias gastown.dog-4, session name
# dog-gan6flz6), but that is a convention of the pool, not a promise, and the alias that repeats (gastown.dog-N,
# wa-worker-adhoc-*) is what the ledger shows. Hashing a name that repeats would make the SLOT the unit — a few
# clusters, each stuck in one arm for good and confounded with its load regime — and every launch would still
# log a clean arm=treat|control. A launch with no usable uuid is left alone, and the log says so.
# The arm depends on nothing but that random uuid and is fixed BEFORE the session sees any bead, so it is
# independent of WHICH bead the session picks up (the oldest ready one). It is still per SESSION, not per bead:
# a session that builds several beads gives them all one arm (01/10 ledger: 1.12-1.17 beads per builder
# session), which the meter's section 6 prints. The E3 pre-gate A/B hashes the bead id, so its unit is the bead.
# Only sessions launched with exactly `control_effort` are enrolled; a role set to anything else on purpose
# is never touched. The conf is `key=value` lines (# comments):
#     salt=ga-5c3msy-1             changes the split when a new experiment starts
#     enroll=gastown.dog wa-worker ps-worker     GC_TEMPLATE values (or GC_AGENT prefixes) that are enrolled
#     control_effort=xhigh         the effort an enrolled session is launched with today
#     treat_effort=high            what the treated arm gets
#     treat_pct=50                 0-100, share of sessions in the treated arm
# FAIL-OPEN like everything else here: a bad conf, a missing shasum, an odd argv, no usable session uuid ->
# claude starts with its argv untouched and the log says why (EFFORT-AB WARN). The decision is logged per
# launch with the claude session uuid, so "did the arm actually reach the process" is a join against the
# transcript's own `effort`.
# KNOBS: GC_EFFORT_AB=0 (this launch) / touch $GC_CITY_PATH/.gc/no-effort-ab (every new launch, no reload).
set -u

target="${GC_LOWPRIO_NICE:-15}"
claude_bin="${GC_LOWPRIO_CLAUDE_BIN:-claude}"
city="${GC_CITY_PATH:-}"

log=""
if [ -n "$city" ] && [ -d "$city/.gc/logs" ]; then
  log="$city/.gc/logs/claude-lowprio.log"
fi

# One line per launch. Best-effort by design: a logging failure must never touch the launch itself.
note() {
  [ -n "$log" ] || return 0
  printf '%s pid=%s agent=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "${GC_AGENT:-?}" "$*" >> "$log" 2>/dev/null || true
}

# Current niceness of this very process; empty when it cannot be read (never a guessed number).
# One fork (ps) and no pipeline: this runs in the window before claude exists, so it stays lean.
ni_of() { local v; v="$(ps -o ni= -p "$$" 2>/dev/null)" || v=""; printf '%s' "${v//[[:space:]]/}"; }

# A usable integer (a negative niceness is legal): used for every value read back from ps.
is_int() {
  case "$1" in
    ''|-|*[!0-9-]*|?*-*) return 1 ;;
  esac
  return 0
}

# A claude session uuid (8-4-4-4-12 hex): the only shape `claude --session-id` accepts. Used by the effort A/B, which
# refuses to draw an arm from anything else — a prompt that happens to follow a flag must never become a "session id".
is_uuid() {
  case "$1" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  local hex="${1//-/}"          # the 4 dashes are positional above; what is left must be exactly 32 hex digits (36 dashes are not a uuid)
  [ "${#hex}" -eq 32 ] || return 1
  case "$hex" in *[!0-9a-fA-F]*) return 1 ;; esac
  return 0
}

case "$target" in
  ''|*[!0-9]*) note "WARN GC_LOWPRIO_NICE='$target' is not a number - using 15"; target=15 ;;
esac
[ "$target" -gt 20 ] && target=20

off=""
[ "${GC_LOWPRIO:-}" = "0" ] && off="GC_LOWPRIO=0"
if [ -z "$off" ] && [ -n "$city" ] && [ -e "$city/.gc/no-lowprio" ]; then
  off="$city/.gc/no-lowprio"
fi

if [ -n "$off" ]; then
  note "SKIP disabled by $off - ni=$(ni_of)"
elif [ "$target" -eq 0 ]; then
  note "SKIP target 0 - ni=$(ni_of)"
else
  before="$(ni_of)"
  if is_int "$before" && [ "$before" -ge "$target" ]; then
    note "KEEP ni=$before already >= target $target"
  else
    # `before` unreadable is NOT "already low" and NOT "normal": try anyway. The absolute form can only
    # raise, so an already-higher value survives a blind attempt untouched.
    rc=0
    renice "$target" -p "$$" >/dev/null 2>&1 || rc=$?
    after="$(ni_of)"
    if is_int "$after" && [ "$after" -ge "$target" ]; then
      note "SET ni=${before:-?}->$after target=$target"
    else
      note "WARN renice rc=$rc left ni=${after:-?} (wanted >= $target, was ${before:-?}) - this session runs at its inherited priority"
    fi
  fi
fi

# ---- EFFORT A/B (see header). Everything below only ever rewrites the VALUE after --effort, and only for an
# enrolled session still on control_effort; any doubt leaves argv exactly as received.
argv=("$@")
ab_conf=""
[ -n "$city" ] && ab_conf="$city/.gc/effort-ab.conf"
if [ -n "$ab_conf" ] && [ -f "$ab_conf" ] && [ "${GC_EFFORT_AB:-}" != "0" ] && [ ! -e "$city/.gc/no-effort-ab" ]; then
  ab_salt=""; ab_enroll=""; ab_ctl=""; ab_trt=""; ab_pct=""; ab_bad=""
  while IFS='=' read -r ab_k ab_v || [ -n "$ab_k" ]; do
    ab_k="${ab_k//[[:space:]]/}"
    case "$ab_k" in ''|'#'*) continue ;; esac
    ab_v="${ab_v%%#*}"; ab_v="${ab_v#"${ab_v%%[![:space:]]*}"}"; ab_v="${ab_v%"${ab_v##*[![:space:]]}"}"
    case "$ab_v" in *[!A-Za-z0-9._\ -]*) ab_bad="$ab_k has characters outside [A-Za-z0-9._ -]"; break ;; esac
    case "$ab_k" in
      salt) ab_salt="$ab_v" ;; enroll) ab_enroll="$ab_v" ;; control_effort) ab_ctl="$ab_v" ;;
      treat_effort) ab_trt="$ab_v" ;; treat_pct) ab_pct="$ab_v" ;;
      *) ab_bad="unknown key '$ab_k'"; break ;;
    esac
  done < "$ab_conf"
  case "$ab_ctl" in low|medium|high|xhigh|max) ;; *) ab_bad="${ab_bad:-control_effort '$ab_ctl' invalid}" ;; esac
  case "$ab_trt" in low|medium|high|xhigh|max) ;; *) ab_bad="${ab_bad:-treat_effort '$ab_trt' invalid}" ;; esac
  case "$ab_pct" in ''|*[!0-9]*) ab_bad="${ab_bad:-treat_pct '$ab_pct' is not 0-100}" ;; *) [ "$ab_pct" -gt 100 ] && ab_bad="${ab_bad:-treat_pct '$ab_pct' is not 0-100}" ;; esac
  [ -n "$ab_salt" ] && [ -n "$ab_enroll" ] || ab_bad="${ab_bad:-salt/enroll missing}"
  if [ -n "$ab_bad" ]; then
    note "EFFORT-AB WARN conf $ab_conf ignored: $ab_bad"
  else
    ab_tpl="${GC_TEMPLATE:-}"; ab_in=""
    for ab_t in $ab_enroll; do
      if [ "$ab_tpl" = "$ab_t" ]; then ab_in=1; break; fi
      case "${GC_AGENT:-}" in "$ab_t"|"$ab_t"-*) ab_in=1; break ;; esac
    done
    if [ -n "$ab_in" ]; then
      ab_sn="${GC_SESSION_NAME:-?}"          # logged only: it is NOT an input of the draw (see the header)
      ab_idx=-1; ab_uuid=""
      for ((ab_i = 0; ab_i < ${#argv[@]}; ab_i++)); do
        case "${argv[$ab_i]}" in
          --effort) ab_idx=$ab_i ;;
          --effort=*) ab_idx=$ab_i ;;
          --session-id|--resume) ab_uuid="${argv[$((ab_i + 1))]:-}" ;;
          --session-id=*) ab_uuid="${argv[$ab_i]#--session-id=}" ;;
          --resume=*) ab_uuid="${argv[$ab_i]#--resume=}" ;;
        esac
      done
      ab_h=""
      if [ "$ab_idx" -lt 0 ]; then
        note "EFFORT-AB WARN template=$ab_tpl session=$ab_sn launched without --effort - left alone"
      elif ! is_uuid "$ab_uuid"; then
        # never echo the value: when a flag is the last argv element before the prompt, "its value" is the prompt text
        note "EFFORT-AB WARN template=$ab_tpl session=$ab_sn has no usable --session-id/--resume uuid (value of ${#ab_uuid} chars) - left alone: the arm is drawn per claude session, and a session NAME can repeat"
      elif ! ab_out="$(printf '%s' "effort-ab:$ab_salt:$ab_uuid" | shasum -a 256 2>/dev/null)" || [ -z "$ab_out" ]; then
        note "EFFORT-AB WARN template=$ab_tpl session=$ab_sn uuid=$ab_uuid shasum failed - left alone"
      else
        ab_h="${ab_out%% *}"
        ab_n=$(( 16#${ab_h:0:8} % 100 ))
        case "${argv[$ab_idx]}" in
          --effort=*) ab_cur="${argv[$ab_idx]#--effort=}" ;;
          *)          ab_cur="${argv[$((ab_idx + 1))]:-}" ;;
        esac
        if [ "$ab_cur" != "$ab_ctl" ]; then
          note "EFFORT-AB SKIP template=$ab_tpl session=$ab_sn uuid=$ab_uuid launched with effort=$ab_cur, not control $ab_ctl - left alone"
        elif [ "$ab_n" -lt "$ab_pct" ]; then
          case "${argv[$ab_idx]}" in
            --effort=*) argv[$ab_idx]="--effort=$ab_trt" ;;
            *)          argv[$((ab_idx + 1))]="$ab_trt" ;;
          esac
          note "EFFORT-AB arm=treat template=$ab_tpl session=$ab_sn uuid=$ab_uuid effort=$ab_ctl->$ab_trt n=$ab_n pct=$ab_pct salt=$ab_salt"
        else
          note "EFFORT-AB arm=control template=$ab_tpl session=$ab_sn uuid=$ab_uuid effort=$ab_ctl n=$ab_n pct=$ab_pct salt=$ab_salt"
        fi
      fi
    fi
  fi
fi

exec "$claude_bin" ${argv[@]+"${argv[@]}"}
