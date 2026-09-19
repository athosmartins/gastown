#!/usr/bin/env bash
# heavy-selftest-guard.sh — ga-rj7b1a. SOURCE this at the top of a HEAVY selftest:
#
#   . "$SELF_DIR/heavy-selftest-guard.sh"
#   heavy_selftest_guard pilot-dispatcher        # before any real work
#   cleanup() { …; heavy_selftest_release; }     # called from the selftest's own EXIT trap
#
# WHY. 2026-09-19: 23 concurrent test trees — several of them a FULL pilot-dispatcher.selftest.sh
# (~30 min each, ~94 bash subprocesses at a time) — took the load average to 56-64 on 10 cores. Dolt got
# no CPU, the supervisor's demand_snapshot.load read 1795 s (normal ~60 s), the gate reviewer never came
# up. Two independent protections, because either alone still lets the box tip over:
#
#   1. LOW PRIORITY — heavy_selftest_lowprio. Renices this process to >= 15 (ABSOLUTE `renice N -p`,
#      which on macOS can only RAISE niceness: it never lowers one and never compounds the way
#      `renice -n` does). Everything the suite spawns inherits it. This is the belt to the braces of
#      scripts/claude-lowprio.sh (this dir), which does the same for every pool claude session: this one also covers
#      a run started by launchd, a gate runner or a human terminal.
#   2. SINGLE-FLIGHT — heavy_selftest_lock NAME. At most ONE run of NAME on the whole machine at a time.
#      A second run WAITS (bounded, default 4 h — the same patience as heavy-eval-stagger-lock.sh, whose
#      exit-75-when-it-gives-up convention this follows) instead of adding another ~90-process tree. The
#      wait is deliberately long: callers such as prod-tests/gascity/story-ga-5ew.sh and story-ga-rfpm9.sh
#      read ANY nonzero rc as "selftest failed", so a refusal should only ever happen when something is
#      truly wedged. If the wait does run out it exits 75 (EX_TEMPFAIL) with a message that says NOT RUN —
#      "could not run" must never be readable as "ran and failed" (the third-state rule): rc 75 is a SKIP,
#      retry later. A caller with a tight time budget sets SELFTEST_LOCK_WAIT_SECS itself (0 = never wait).
#      EXCEPTION: the quality gate's reviewers never queue (see _hsg_exempt) — their verdict timeout is
#      already sized for their own A/B pair of runs, and a wait behind a builder would blow it. They take
#      the lock when it is free (so builders yield to them) and run anyway, at low priority, when it is not.
#
# LOCK FORMAT. A directory (mkdir is the atomic test-and-set; macOS has no flock) under
#   ${GC_HEAVY_LOCK_ROOT:-/tmp/gc-heavy-locks-<uid>}/<name>.lock/owner
# holding pid= / lstart= (the owner's process START TIME) / since= / cmd=. An owner is ALIVE only if its
# pid exists AND its start time still matches — a recycled pid is not the owner. A lock whose owner is
# dead is reclaimed under a second mutex with a re-check (see _hsg_reclaim: a bare rename is a TOCTOU that
# hands one lock to two processes). Missing owner file on a
# FRESH directory means "the creator is between mkdir and the write": busy, not stale.
#
# FAIL-OPEN, NOT SILENT. The lock protects the machine; it must never block verification on its own
# breakage. If the lock directory cannot be created at all, the suite runs UNGUARDED and says so.
#
# KNOBS
#   SELFTEST_LOCK=0                 skip the lock (escape hatch); priority is still lowered
#   SELFTEST_LOCK_WAIT_SECS=N       how long a second run waits for the first (default 14400 = 4 h;
#                                   0 = do not wait: exit 75 at once if busy — for latency-critical callers)
#   SELFTEST_LOCK_POLL_SECS=N       poll interval (default 5)
#   SELFTEST_LOCK_EXEMPT_TEMPLATES  GC_TEMPLATEs that never queue (default "gate-reviewer refino-gate-reviewer";
#                                   set it EMPTY to make everyone queue)
#   GC_LOWPRIO=0 / $GC_CITY_PATH/.gc/no-lowprio    same kill switches as scripts/claude-lowprio.sh
#   GC_LOWPRIO_NICE=N               target niceness 1-20 (default 15)
#   GC_HEAVY_LOCK_ROOT=DIR          where locks live (tests)

HSG_LOCK_DIR=""

_hsg_say() { printf '[heavy-selftest] %s\n' "$*" >&2; }

_hsg_ni() { local v; v="$(ps -o ni= -p "$$" 2>/dev/null)" || v=""; printf '%s' "${v//[[:space:]]/}"; }

_hsg_is_int() {
  case "$1" in
    ''|-|*[!0-9-]*|?*-*) return 1 ;;
  esac
  return 0
}

# Start time of a pid as ps prints it; empty when the pid does not exist OR ps itself is unusable.
_hsg_lstart() { local v; v="$(ps -p "$1" -o lstart= 2>/dev/null)" || v=""; printf '%s' "${v//  / }"; }

heavy_selftest_lowprio() {
  local target="${GC_LOWPRIO_NICE:-15}" before after rc=0
  case "$target" in ''|*[!0-9]*) target=15 ;; esac
  [ "$target" -gt 20 ] && target=20
  if [ "${GC_LOWPRIO:-}" = "0" ] || { [ -n "${GC_CITY_PATH:-}" ] && [ -e "${GC_CITY_PATH}/.gc/no-lowprio" ]; }; then
    _hsg_say "low priority disabled by kill switch — running at ni=$(_hsg_ni)"
    return 0
  fi
  before="$(_hsg_ni)"
  if _hsg_is_int "$before" && [ "$before" -ge "$target" ]; then
    return 0   # already at least that low (Mayor stopgap, a niced parent, claude-lowprio) — nothing to do
  fi
  renice "$target" -p "$$" >/dev/null 2>&1 || rc=$?
  after="$(_hsg_ni)"
  if _hsg_is_int "$after" && [ "$after" -ge "$target" ]; then
    _hsg_say "low priority: ni ${before:-?} -> $after (children inherit)"
  else
    _hsg_say "WARN could not lower priority (renice rc=$rc, ni now ${after:-?}, wanted >= $target) — running at inherited priority"
  fi
  return 0
}

# owner state of a lock dir: alive | dead | unknown
_hsg_owner_state() {
  local lock="$1" pid="" ls="" cur age now mt
  if [ -f "$lock/owner" ]; then
    pid="$(sed -n 's/^pid=//p' "$lock/owner" 2>/dev/null | head -1)"
    ls="$(sed -n 's/^lstart=//p' "$lock/owner" 2>/dev/null | head -1)"
  fi
  if ! _hsg_is_int "$pid" || [ -z "$ls" ]; then
    # No usable owner record. Fresh dir = creator mid-write (busy). Old dir = the creator died before writing.
    now="$(date +%s)"; mt="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null)" || mt=""
    _hsg_is_int "$mt" || { echo unknown; return; }
    age=$((now - mt))
    if [ "$age" -gt 30 ]; then echo dead; else echo unknown; fi
    return
  fi
  # ps unusable (cannot even see ourselves) is UNKNOWN, never "dead": do not steal a lock on a blind ps.
  [ -n "$(_hsg_lstart "$$")" ] || { echo unknown; return; }
  cur="$(_hsg_lstart "$pid")"
  if [ -z "$cur" ] || [ "$cur" != "$ls" ]; then echo dead; else echo alive; fi
}

_hsg_owner_field() { sed -n "s/^$2=//p" "$1/owner" 2>/dev/null | head -1; }

# 0 if this caller is a GATE session that must never queue for the lock. The gate's reviewers run the
# pilot selftest twice per review (branch + base, ga-4158gs) inside a verdict timeout the dispatcher
# already sizes for exactly that (gate_heavy_selftest_floor_minutes: cost x2 + margin). Making one wait
# behind a builder's 18-45 min run would spend that budget on a queue and time the review out — so a gate
# caller runs at once when the lock is busy (still at low priority) and takes the lock when it is free,
# which makes BUILDERS yield to the gate. The list is by session template (GC_TEMPLATE); SET-BUT-EMPTY
# disables the exemption (everyone queues).
_hsg_exempt() {
  local t="${GC_TEMPLATE:-}" x
  [ -n "$t" ] || return 1
  for x in ${SELFTEST_LOCK_EXEMPT_TEMPLATES-gate-reviewer refino-gate-reviewer}; do
    [ "$t" = "$x" ] && return 0
  done
  return 1
}

_hsg_write_owner() {
  local lock="$1" tmp="$1/owner.tmp.$$" ls
  ls="$(_hsg_lstart "$$")"
  # A record without our start time proves nothing about who we are, and a lock nobody can attribute is
  # judged dead after 30 s while we are still running: refuse, so the caller runs unguarded and SAYS so.
  [ -n "$ls" ] || return 1
  {
    echo "pid=$$"
    echo "lstart=$ls"
    echo "since=$(date +%s)"
    echo "cmd=${0##*/}"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$lock/owner" 2>/dev/null
}

# 0 if an ANCESTOR of ours (its pid is in GC_HEAVY_LOCK_HOLDERS and is still the live owner) holds this lock.
_hsg_reentrant() {
  local name="$1" lock="$2" owner_pid
  owner_pid="$(_hsg_owner_field "$lock" pid)"
  _hsg_is_int "$owner_pid" || return 1
  case " ${GC_HEAVY_LOCK_HOLDERS:-} " in *" $name:$owner_pid "*) ;; *) return 1 ;; esac
  [ "$(_hsg_owner_state "$lock")" = "alive" ]
}

# Reclaim a lock whose owner was judged dead. NEVER a bare `mv/rm` of the path: "judged dead" (reading the
# owner) and "removed it" are two steps, and in between the dead owner's dir can be released and a FRESH,
# LIVE lock created at the very same path — removing THAT hands the lock to two processes at once (found
# by this suite's 6-way race, not by reading). So reclaimers serialise through a second, tiny mkdir mutex
# (<lock>.reaping) and RE-VERIFY under it: only a reclaimer can remove a dead owner's dir (a dead owner
# cannot release it, a live one is never judged dead), so once we hold the mutex the record we re-read
# is still the one we are about to remove. Returns 0 if we held the mutex (whether or not anything was
# left to remove), 1 if another process is reclaiming right now (caller waits a poll and retries).
_hsg_reclaim() {
  local lock="$1" name="$2" reap="$1.reaping" now mt old_pid
  if ! mkdir "$reap" 2>/dev/null; then
    # A reaper that died mid-reclaim leaves its mutex behind; its critical section is milliseconds long.
    now="$(date +%s)"; mt="$(stat -f %m "$reap" 2>/dev/null || stat -c %Y "$reap" 2>/dev/null)" || mt=""
    if _hsg_is_int "$mt" && [ $((now - mt)) -gt 30 ]; then rm -rf "$reap" 2>/dev/null || true; fi
    return 1
  fi
  if [ "$(_hsg_owner_state "$lock")" = "dead" ]; then
    old_pid="$(_hsg_owner_field "$lock" pid)"
    rm -rf "$lock" 2>/dev/null || true
    _hsg_say "reclaimed a stale '$name' lock (owner pid ${old_pid:-?} is gone)"
  fi
  rmdir "$reap" 2>/dev/null || rm -rf "$reap" 2>/dev/null || true
  return 0
}

heavy_selftest_lock() {
  local name="$1" root lock max poll t0 waited=0 last_say=0 owner_pid since now state vanished=0
  case "$name" in ''|*[!A-Za-z0-9._-]*) _hsg_say "WARN bad lock name '$name' — running without single-flight"; return 0 ;; esac
  if [ "${SELFTEST_LOCK:-}" = "0" ]; then _hsg_say "single-flight lock disabled (SELFTEST_LOCK=0)"; return 0; fi
  max="${SELFTEST_LOCK_WAIT_SECS:-14400}"; case "$max" in ''|*[!0-9]*) max=14400 ;; esac
  poll="${SELFTEST_LOCK_POLL_SECS:-5}";   case "$poll" in ''|*[!0-9.]*) poll=5 ;; esac
  root="${GC_HEAVY_LOCK_ROOT:-/tmp/gc-heavy-locks-$(id -u)}"
  lock="$root/$name.lock"
  if ! mkdir -p "$root" 2>/dev/null; then
    _hsg_say "WARN cannot create $root — running UNGUARDED (no single-flight for '$name')"
    return 0
  fi
  _hsg_reentrant "$name" "$lock" && return 0
  t0="$(date +%s)"
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      if _hsg_write_owner "$lock"; then
        HSG_LOCK_DIR="$lock"
        export GC_HEAVY_LOCK_HOLDERS="${GC_HEAVY_LOCK_HOLDERS:-} $name:$$"
        if [ "$waited" -gt 0 ]; then _hsg_say "lock '$name' acquired after ${waited}s"; fi
        return 0
      fi
      # Created the dir but could not record ownership: give it back and run unguarded — a lock nobody
      # can attribute would only wedge the next run.
      rm -rf "$lock" 2>/dev/null || true
      _hsg_say "WARN cannot record who holds the lock (owner file / process start time unreadable) — running UNGUARDED (no single-flight for '$name')"
      return 0
    fi
    if [ ! -d "$lock" ]; then
      # The mkdir failed and the dir is not there: two very different causes. (a) The holder RELEASED it
      # between our mkdir and this test — the lock is FREE, so try again. Reading that as "cannot be created"
      # ran the suite UNGUARDED beside the process that had just taken the lock: measured 5 of 70 six-way
      # races on a loaded host, every one with this WARN (a short critical section makes the window wide).
      # (b) The lock genuinely cannot be created here (permissions, disk full): the mkdir then fails EVERY
      # time. Tell them apart by retrying — only a mkdir that keeps failing with nothing there is (b).
      vanished=$((vanished + 1))
      if [ "$vanished" -ge 3 ]; then
        _hsg_say "WARN mkdir $lock keeps failing and the lock never exists — running UNGUARDED (no single-flight for '$name')"
        return 0
      fi
      continue
    fi
    vanished=0
    state="$(_hsg_owner_state "$lock")"
    if [ "$state" = "dead" ] && _hsg_reclaim "$lock" "$name"; then
      continue   # reclaimed (or it was already replaced): retry the mkdir at once
    fi
    # alive, unknown, or another process is mid-reclaim => busy
    owner_pid="$(_hsg_owner_field "$lock" pid)"; since="$(_hsg_owner_field "$lock" since)"; now="$(date +%s)"
    _hsg_is_int "$since" || since="$now"
    if _hsg_exempt; then
      _hsg_say "'$name' lock is held by pid ${owner_pid:-?} — a gate caller (${GC_TEMPLATE}) does not queue behind it (its review timeout budgets for its own runs); running now, still at low priority"
      return 0
    fi
    if [ "$waited" -ge "$max" ]; then
      echo "[heavy-selftest] NOT RUN — this is NOT a test failure. Another full '$name' run holds the machine-wide lock." >&2
      echo "[heavy-selftest]   owner pid=${owner_pid:-?} for $(( (now - since) / 60 )) min ($lock); waited ${waited}s (SELFTEST_LOCK_WAIT_SECS=$max)." >&2
      echo "[heavy-selftest]   Retry later, wait longer (SELFTEST_LOCK_WAIT_SECS=N), or iterate on ONE scenario instead of the whole file." >&2
      exit 75
    fi
    if [ "$waited" -eq 0 ] || [ $((waited - last_say)) -ge 60 ]; then
      _hsg_say "waiting for the '$name' lock held by pid ${owner_pid:-?} ($(( (now - since) / 60 )) min so far); waited ${waited}s of ${max}s"
      last_say=$waited
    fi
    sleep "$poll"
    waited=$(( $(date +%s) - t0 ))   # real elapsed seconds: right for whole and fractional polls alike
  done
}

heavy_selftest_release() {
  local lock="$HSG_LOCK_DIR"
  [ -n "$lock" ] || return 0
  HSG_LOCK_DIR=""
  # Only ever remove OUR lock: a stale-reclaim may have handed it to someone else while we were wedged.
  [ "$(_hsg_owner_field "$lock" pid)" = "$$" ] || return 0
  rm -rf "$lock" 2>/dev/null || true
  return 0
}

heavy_selftest_guard() {
  heavy_selftest_lowprio
  heavy_selftest_lock "$1"
}
