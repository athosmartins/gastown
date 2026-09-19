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

exec "$claude_bin" "$@"
