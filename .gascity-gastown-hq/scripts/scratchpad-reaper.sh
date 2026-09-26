#!/bin/bash
# scratchpad-reaper.sh (ga-hjcxy, fixing ga-02pnu) — reaper for DEAD-session
# scratchpad directories under /private/tmp/claude-<uid>/.
#
# WHY: 2026-07-19 a disk-floor CRITICAL incident (avail=3GB, piso=3GB) traced to
# a single dead session's scratchpad (batista-wa, 1.0GB, last modified ~1.3 days
# earlier) that nothing ever reaped. Manually deleting it freed 3.3GB -> 13GB
# avail (macOS released ~10GB of purgeable space under pressure). The
# worktree-reaper only cleans REGISTERED git worktrees (`git worktree list`) — a
# loose scratchpad dir with zero registered worktrees is invisible to it. And
# dolt-disk-floor-guard.sh's only reclaim lever was `gc dolt-cleanup --force`
# (Dolt orphan DBs) — it never touched /private/tmp. No reaper owned this class
# of file at all.
#
# WHAT: scans /private/tmp/claude-<uid>/<project>/<session-id>/scratchpad for
# every project/session pair, and removes ONLY the `scratchpad` leaf directory
# (never the parent session dir, never a sibling `tasks/`) when BOTH hold:
#   1. DEAD  — <session-id> (the UUID segment, matches `gc session list --json`'s
#      `.sessions[].session_key`) does NOT appear in the default `gc session
#      list` output (active + suspended + anything not closed). Absence = dead.
#   2. STALE — directory mtime is older than MIN_AGE_HOURS (default 24h), OR
#      (ga-rjhfz) the caller signals SCRATCHPAD_REAPER_PRESSURE=CRITICAL and
#      the directory is BOTH at least CRITICAL_MIN_AGE_HOURS old (default 1h)
#      AND at least LARGE_GB large (default 2GB). Either way this is a grace
#      buffer on top of the liveness check, not the primary safety mechanism —
#      it protects against a session that died moments ago and whose
#      disappearance from the live list hasn't propagated yet.
#
# SAFETY (ga-02pnu's explicit ask: "NUNCA reapar sessao ATIVA ... nem o dir da
# sessao corrente"):
#   - A `gc session list` query FAILURE (nonzero exit / unparseable JSON /
#     missing `.sessions` key) aborts the ENTIRE cycle with zero deletions —
#     empty and error must never collapse to the same "safe to reap" value
#     (ga-p5q3 class: error and empty must not produce the same value when the
#     emptiness is load-bearing). A genuinely-empty but well-formed
#     `.sessions: []` (quiet town) is NOT an error and proceeds normally —
#     every candidate is still gated by MIN_AGE_HOURS.
#   - The CALLER's own session (env `CLAUDE_CODE_SESSION_ID`, when set — e.g. a
#     human/dog running this by hand from an interactive session) is EXCLUDED
#     unconditionally, independent of the live-session-list result. This guard
#     is a no-op when invoked from launchd (no Claude session owns that
#     process).
#   - Only the exact `scratchpad` leaf is removed (through safe-clean since
#     ga-hynohs; before that a bare `rm -rf`) — never the parent session
#     directory or any sibling directory (e.g. `tasks/`).
#
# OUT OF SCOPE: does not touch `tasks/` or any other per-session directory;
# does not reap registered git worktrees (worktree-reaper's job); does not
# decide WHEN to run under pressure — the caller (dolt-disk-floor-guard.sh)
# still owns that decision and passes SCRATCHPAD_REAPER_PRESSURE as a signal,
# it is never self-detected here.
#
# SIZE ESCAPE (ga-rjhfz, 2026-08-06): a 2026-08-06 CRITICAL disk incident
# (avail=3GB for 2 cycles) found the standard reclaim levers recovered
# nothing, while a single dead session's scratchpad sat at 10GB and only 3.5h
# old — stuck behind the 24h MIN_AGE_HOURS gate no matter how severe the
# pressure got. Age-only staleness is structurally incapable of releasing the
# single largest recoverable item during a crisis, and the faster a session
# fills disk the MORE certain it is to still be under 24h old when pressure
# hits. Fix: when the caller sets SCRATCHPAD_REAPER_PRESSURE=CRITICAL, a dead
# candidate that is at least LARGE_GB (default 2GB) may reap once it clears
# the much shorter CRITICAL_MIN_AGE_HOURS (default 1h) instead of the full
# MIN_AGE_HOURS — see `_should_reap_size_escape`. This NEVER touches the
# liveness/self-protection gate (`_is_dead`, shared verbatim with the normal
# path) — only how stale a dead-and-large directory needs to be. Outside
# SCRATCHPAD_REAPER_PRESSURE=CRITICAL (unset, or e.g. "WARN"), behavior is
# byte-identical to before ga-rjhfz. A dead candidate that qualifies for
# neither path is logged explicitly as PULADO (skipped) with its size and
# age, and the per-cycle summary distinguishes "nada encontrado" (no dead
# candidates at all) from "nada elegivel" (dead candidates existed, none
# qualified) — the prior generic summary read identically for both, which is
# exactly what made the 10GB survivor invisible in the caller's own report.
#
# ALWAYS-ON SWEEP (ga-hynohs, 2026-09-26): gate reviewers copy the branch under
# review into their scratchpad (tree/, tree_base/, exp/... — 130-830MB per
# session) and nothing collected those copies until the disk was already
# CRITICAL: 27MB -> 3.5GB of /private/tmp/claude-<uid> in 3h, 2.4GB of it in
# sessions that had been dead for 30+ minutes. Neither existing early exit can
# help: the age path waits 24h, and the CRITICAL size-escape needs one dir
# >= 2GB (a reviewer's copies are each far under). The sweep adds a third
# path, `reaped (idle)`: dead AND idle for at least SCRATCHPAD_REAPER_MIN_IDLE_MINUTES
# (default 0 = OFF; only the scratchpad-sweep order sets it, to 30), with NO
# pressure signal needed. What keeps it safe, beyond the liveness/self gate
# every path shares:
#   - LIVENESS is the UNION of `gc session list` and every uuid found on the
#     command line of a running `claude` process (--session-id / --resume / -r,
#     any flag — see _fetch_proc_liveness). A `claude` with no uuid at all
#     (interactive, --continue) protects every scratchpad in the project dir its
#     cwd maps to, since which session id it owns is unknowable from outside.
#   - A process scan that cannot be trusted (ps failed or printed nothing; a
#     session-id-less claude whose cwd is unreadable) aborts the WHOLE cycle:
#     "could not look" must never read as "nobody is running".
#   - Deletion goes through safe-clean (allowlist + symlink resolution, refuses
#     anything it does not recognise) and FAILS CLOSED — a missing safe-clean or
#     a refusal deletes nothing, there is deliberately no rm -rf fallback. Any
#     failed removal makes the cycle exit nonzero, so a sweep that frees nothing
#     cannot look healthy.
#   - A single-instance lock (LOCK_DIR): the reaper is called both by the
#     sweep order and by dolt-disk-floor-guard, and a run under load takes
#     minutes (measured 2026-09-26, load ~60: 12-37s in `gc session list` alone
#     plus ~0.4s per dead candidate). Only a provably dead holder, or a lock
#     older than LOCK_MAX_AGE_SECS (a real run is bounded by its callers'
#     timeouts, so an older lock is a killed run whose pid was reused), is
#     reclaimed. Failing to create the lock at all aborts the cycle.
# Not covered, on purpose: work still running in a child process of a session
# that has died is not detected — the scratchpad it uses goes away under it,
# which only fails work nobody is waiting for anymore.
#
# Kill switch: SCRATCHPAD_REAPER_ENABLED=0 -> dry-run regardless of
# SCRATCHPAD_REAPER_DRY_RUN (logs candidates, deletes nothing).
#
# PRODUCTION SENTINEL (ga-h565g, follow-up to a 2026-07-26 incident where this
# script's sibling, transcript-reaper.sh, deleted 185 real transcripts because
# its selftest's harness bug left the resolved root at its REAL default
# instead of a tmp fixture): whenever the resolved root exactly equals the
# hardcoded real default AND SCRATCHPAD_REAPER_PROD!=1, main() forces a
# dry-run regardless of SCRATCHPAD_REAPER_DRY_RUN — the same harness mistake
# (forgetting to override the root) can never delete real data again unless
# the caller ALSO explicitly opts in. Set ONLY by the two real callers —
# dolt-disk-floor-guard.sh's _reap_dead_scratch and, since ga-hynohs, the
# scratchpad-sweep order's wrapper (packs/town-deltas/assets/scripts/
# scratchpad-sweep.sh) — never by a test.
#
# TEST (no real /private/tmp data touched, no deletions, hermetic fixtures):
#   bash scripts/scratchpad-reaper.selftest.sh
# Library mode: `SCRATCHPAD_REAPER_LIB=1 source scratchpad-reaper.sh` defines
# the pure decision functions WITHOUT running the reap flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
SCRATCH_REAL_DEFAULT_ROOT="/private/tmp/claude-$(id -u)"
SCRATCH_ROOT="${SCRATCHPAD_REAPER_ROOT:-$SCRATCH_REAL_DEFAULT_ROOT}"
LOG="${SCRATCHPAD_REAPER_LOG:-$CITY/.gc/logs/scratchpad-reaper.log}"
GC="${GC_BIN:-gc}"
ENABLED="${SCRATCHPAD_REAPER_ENABLED:-1}"
DRY_RUN="${SCRATCHPAD_REAPER_DRY_RUN:-0}"
MIN_AGE_HOURS="${SCRATCHPAD_REAPER_MIN_AGE_HOURS:-24}"
SELF_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
PROD="${SCRATCHPAD_REAPER_PROD:-0}"
# ga-rjhfz: size-escape config. PRESSURE is a caller-supplied signal (never
# self-detected) — only "CRITICAL" activates the escape; unset/anything else
# (e.g. "WARN") leaves behavior identical to before ga-rjhfz.
LARGE_GB="${SCRATCHPAD_REAPER_LARGE_GB:-2}"
CRITICAL_MIN_AGE_HOURS="${SCRATCHPAD_REAPER_CRITICAL_MIN_AGE_HOURS:-1}"
PRESSURE="${SCRATCHPAD_REAPER_PRESSURE:-}"
# ga-hynohs: always-on sweep. MIN_IDLE_MINUTES 0/unset = the path is OFF and a
# caller that never heard of it (dolt-disk-floor-guard) behaves exactly as
# before; only the scratchpad-sweep order opts in.
MIN_IDLE_MINUTES="${SCRATCHPAD_REAPER_MIN_IDLE_MINUTES:-0}"
SAFE_CLEAN="${SCRATCHPAD_REAPER_SAFE_CLEAN:-$CITY/packs/town-deltas/assets/scripts/safe-clean.py}"
# A fixed path under the city, not $TMPDIR: the sweep order and the disk-floor
# guard may run with different TMPDIRs and must still see the same lock.
LOCK_DIR="${SCRATCHPAD_REAPER_LOCK_DIR:-$CITY/.gc/runtime/scratchpad-reaper.lock.d}"
LOCK_MAX_AGE_SECS="${SCRATCHPAD_REAPER_LOCK_MAX_AGE_SECS:-900}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by scratchpad-reaper.selftest.sh.
# No side effects; bash-3.2-safe (no associative arrays — launchd invokes
# macOS system /bin/bash, same constraint noted in dolt-disk-floor-guard.sh).
# ════════════════════════════════════════════════════════════════════════════

# _session_is_live <session_id> <live_keys_file> → 0 (true) iff session_id
# appears as an EXACT line in live_keys_file (grep -x — a prefix match must
# never count as live). A missing keyfile is treated as "not live" — the
# caller (main) never proceeds to the reap loop without a keyfile it trusts,
# so this only matters for direct/test invocation and fails toward "dead",
# not toward silently protecting everything.
_session_is_live() {
  local sid="$1" keyfile="$2"
  [ -f "$keyfile" ] || return 1
  grep -qxF "$sid" "$keyfile" 2>/dev/null
}

# _is_stale <mtime_epoch> <now_epoch> <min_age_hours> → 0 (true) iff the
# directory's mtime is at/past min_age_hours old. Non-numeric input (a `stat`
# failure) is NEVER stale — an unreadable mtime must not silently authorize
# deletion (same fail-loud idiom as dolt-disk-floor-guard.sh's _floor_class).
_is_stale() {
  local mtime="$1" now="$2" min_hours="$3"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( (now - mtime) / 3600 )) -ge "$min_hours" ]
}

# _is_idle_minutes <mtime_epoch> <now_epoch> <min_minutes> → 0 (true) iff the
# directory's mtime is at/past min_minutes old (ga-hynohs). min_minutes of
# 0/empty/non-numeric DISABLES the gate (returns false) — unlike _is_stale,
# where 0 hours would mean "always stale"; here 0 is the default for every
# caller that did not opt in, so it has to mean "off". Non-numeric mtime/now is
# never idle, for the same reason as in _is_stale.
_is_idle_minutes() {
  local mtime="$1" now="$2" min_minutes="$3"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$min_minutes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$min_minutes" -gt 0 ] || return 1
  [ $(( now - mtime )) -ge $(( min_minutes * 60 )) ]
}

# _extract_uuids → reads stdin, prints every uuid-shaped token (lower-cased),
# one per line. Deliberately flag-agnostic: `--session-id X`, `--session-id=X`,
# `--resume X` and `-r X` are all found without this function knowing any of
# them. It can over-match (a uuid in some other argument) — that only ever
# PROTECTS an extra scratchpad, never exposes one.
_extract_uuids() {
  grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' 2>/dev/null | tr 'A-F' 'a-f'
}

# _encode_project_dir <cwd> → the directory name Claude Code uses under
# /private/tmp/claude-<uid>/ for sessions started in <cwd>: every character that
# is not [A-Za-z0-9] becomes '-'  (/Users/athos/gt/.gascity-gastown-hq →
# -Users-athos-gt--gascity-gastown-hq, whatsapp_automation → whatsapp-automation).
_encode_project_dir() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# _project_protected <project_dir_name> <protected_projects_file> → 0 (true) iff
# the name is an EXACT line of the file. Missing/empty file protects nothing.
_project_protected() {
  local proj="$1" file="$2"
  [ -s "$file" ] || return 1
  grep -qxF -- "$proj" "$file" 2>/dev/null
}

# _is_dead <session_id> <live_keys_file> <self_session_id> → 0 (true) iff NOT
# the caller's own session AND NOT in the live list. ga-rjhfz: extracted out
# of _should_reap so the CRITICAL-pressure size escape below can reuse this
# EXACT same absolute gate instead of re-deriving it — pressure must never get
# its own, potentially looser, copy of self/liveness protection.
_is_dead() {
  local sid="$1" keyfile="$2" self="$3"
  [ -n "$self" ] && [ "$sid" = "$self" ] && return 1
  _session_is_live "$sid" "$keyfile" && return 1
  return 0
}

# _should_reap <session_id> <live_keys_file> <mtime_epoch> <now_epoch>
#              <min_age_hours> <self_session_id>
# → 0 (true) iff: dead (see _is_dead) AND stale past min_age_hours. This is
# the normal-pressure gate for deletion — it composes every safety condition
# so no caller can accidentally skip one of them. Behavior unchanged by
# ga-rjhfz (still just _is_dead + _is_stale); see _should_reap_size_escape
# below for the CRITICAL-pressure-only widening.
_should_reap() {
  local sid="$1" keyfile="$2" mtime="$3" now="$4" min_hours="$5" self="$6"
  _is_dead "$sid" "$keyfile" "$self" || return 1
  _is_stale "$mtime" "$now" "$min_hours"
}

# _should_reap_size_escape <session_id> <live_keys_file> <mtime_epoch>
#     <now_epoch> <critical_min_age_hours> <self_session_id> <size_kb>
#     <large_gb>
# → 0 (true) iff: dead (SAME _is_dead as _should_reap — self/liveness are
# NEVER loosened by pressure) AND at/past critical_min_age_hours old AND
# at/past large_gb in size. ga-rjhfz: under CRITICAL disk pressure, a large
# dead scratchpad shouldn't have to wait out the FULL MIN_AGE_HOURS grace
# window — but it still needs SOME age buffer (protects a session that died
# moments ago, same reasoning as MIN_AGE_HOURS itself) and it still needs to
# actually be large enough to matter. Unreadable/non-numeric size_kb NEVER
# authorizes (fails toward keep, same idiom as _is_stale's mtime handling).
_should_reap_size_escape() {
  local sid="$1" keyfile="$2" mtime="$3" now="$4" critical_min_hours="$5" self="$6" size_kb="$7" large_gb="$8"
  _is_dead "$sid" "$keyfile" "$self" || return 1
  _is_stale "$mtime" "$now" "$critical_min_hours" || return 1
  case "$size_kb" in ''|*[!0-9]*) return 1 ;; esac
  case "$large_gb" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size_kb" -ge $(( large_gb * 1024 * 1024 )) ]
}

# _prod_sentinel_active <resolved_root> <real_default_root> <prod_flag> → 0
# (true) iff resolved_root exactly equals real_default_root AND prod_flag is
# not "1". This is the ga-h565g guard: a caller (test or otherwise) that
# fails to override the root — leaving it at its real-default value — must
# never be able to trigger deletion just because it ALSO forgot to opt in;
# both conditions are required to authorize touching the real default root.
_prod_sentinel_active() {
  local root="$1" real_default="$2" prod="$3"
  [ "$root" = "$real_default" ] && [ "$prod" != "1" ]
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest)
# ════════════════════════════════════════════════════════════════════════════

# _fetch_live_keys <out_file> → writes one session_key per line to out_file.
# Returns nonzero on ANY failure to positively confirm liveness data (nonzero
# exit, empty stdout, or JSON with no `.sessions` key) — a failure here must
# abort the whole cycle upstream, never be read as "nobody's alive, reap
# everything" (ga-p5q3 class again). Deliberately no --state flag: the default
# listing (active + suspended + anything not closed) is exactly ga-02pnu's
# stated dead-session criterion ("session-id NAO aparece em 'gc session
# list'").
_fetch_live_keys() {
  local out="$1" raw rc
  raw="$("$GC" session list --json 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    log "ABORT: 'gc session list --json' failed (rc=$rc) or returned empty — cannot verify liveness"
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e 'has("sessions")' >/dev/null 2>&1; then
    log "ABORT: 'gc session list --json' output has no .sessions key — cannot verify liveness"
    return 1
  fi
  printf '%s' "$raw" | jq -r '.sessions[]?.session_key // empty' > "$out" 2>/dev/null
}

# _dir_size_kb <dir> → prints size in KB (via `du -sk`), empty on failure.
# ga-rjhfz: thin wrapper so main()'s size-escape decision and skip-logging
# are stubbable in tests without creating real multi-GB fixture directories —
# same reasoning as _fetch_live_keys being its own function instead of an
# inline `gc session list` call.
_dir_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

# _ps_claude_lines → prints "<pid> <command line>" for every process whose
# EXECUTABLE is `claude` (basename of the first token — a zsh/bash/grep that
# merely mentions claude does not count). Returns nonzero when ps itself failed
# or printed nothing: a live machine always has processes, so an empty listing
# means ps is broken, and that must never be confused with "no claude running"
# (which is a successful, empty output).
_ps_claude_lines() {
  local raw rc
  raw="$(ps -axo pid=,command= 2>/dev/null)"
  rc=$?
  { [ "$rc" -eq 0 ] && [ -n "$raw" ]; } || return 1
  printf '%s\n' "$raw" | awk '{ n = split($2, p, "/"); if (p[n] == "claude") print }'
}

# _pid_cwd <pid> → prints the process's current directory, nothing when it
# cannot be read (process gone, lsof refused). Thin wrapper so tests can stub it.
_pid_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# _fetch_proc_liveness <keys_file_to_append> <protected_projects_file> → the
# second liveness source (ga-hynohs). Appends every session id found on the
# command line of a running claude to the keys file, so a session that is
# running but absent from `gc session list` (registration lag, a claude started
# outside gc) is still live. A claude whose command line carries NO id
# (interactive, --continue) cannot be tied to one scratchpad, so the project dir
# of its cwd is written to the protected-projects file instead and every
# scratchpad under it is kept. Returns nonzero — and the caller aborts the whole
# cycle — whenever the answer cannot be trusted: ps failed, or an id-less
# claude's cwd could not be read (it may own anything).
_fetch_proc_liveness() {
  local keys_out="$1" projs_out="$2" lines line pid cmd ids cwd
  if ! lines="$(_ps_claude_lines)"; then
    log "ABORT: could not list processes (ps failed or printed nothing) — cannot cross-check liveness against running claude sessions"
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r pid cmd <<< "$line"
    ids="$(printf '%s' "$cmd" | _extract_uuids)"
    if [ -n "$ids" ]; then
      printf '%s\n' "$ids" >> "$keys_out"
    else
      cwd="$(_pid_cwd "$pid")"
      if [ -z "$cwd" ]; then
        log "ABORT: claude pid=$pid carries no session id and its cwd is unreadable — cannot tell which scratchpad it owns"
        return 1
      fi
      printf '%s\n' "$(_encode_project_dir "$cwd")" >> "$projs_out"
    fi
  done <<< "$lines"
  return 0
}

# _remove_scratchpad <dir> → removes the scratchpad leaf through safe-clean
# (ga-hynohs; before it this was a bare rm -rf). safe-clean resolves symlinks,
# allows only a recognised disposable tree and refuses everything else — a second,
# independent check on top of the liveness gates here. FAILS CLOSED: a missing
# safe-clean is a refusal, never a reason to fall back to rm -rf, and its nonzero
# exit (refused / partial failure) is returned to the caller as-is.
_remove_scratchpad() {
  local dir="$1"
  if [ ! -x "$SAFE_CLEAN" ]; then
    log "safe-clean not executable at $SAFE_CLEAN — refusing to delete $dir (fail-closed, no rm -rf fallback)"
    return 1
  fi
  "$SAFE_CLEAN" "$dir" >> "$LOG" 2>&1
}

# ── single-instance lock (ga-hynohs). mkdir is atomic. See the header for why a
# lock exists and when one is reclaimed. A double run is harmless (removing the
# same dirs twice is idempotent) — the lock is there so runs cannot stack up
# under load, not for correctness, so the residual reclaim race (two peers both
# judging the same lock stale) is accepted rather than engineered away.
_lock_holder_dead() {
  local pid
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac   # no/garbled pid: holder may be mid-birth → NOT dead
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

_lock_stale_by_age() {
  local mt now
  mt="$(stat -f %m "$LOCK_DIR" 2>/dev/null)" || return 1
  case "$mt" in ''|*[!0-9]*) return 1 ;; esac    # unreadable mtime → keep the lock
  now=$(date +%s)
  [ $(( now - mt )) -gt "$LOCK_MAX_AGE_SECS" ]
}

# _acquire_lock → 0 = we hold it, 1 = a live run holds it (back off, not an
# error), 2 = the lock could not even be created (unknowable → caller stays inert).
_acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
    return 0
  fi
  [ -d "$LOCK_DIR" ] || return 2
  if _lock_holder_dead || _lock_stale_by_age; then
    rm -rf "$LOCK_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

# Removes the lock only if THIS process still owns it — never a peer's.
_release_lock() {
  [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null
  return 0
}

main() {
  if [ ! -d "$SCRATCH_ROOT" ]; then
    log "SCRATCH_ROOT $SCRATCH_ROOT does not exist — nothing to do"
    return 0
  fi

  if _prod_sentinel_active "$SCRATCH_ROOT" "$SCRATCH_REAL_DEFAULT_ROOT" "$PROD"; then
    log "SENTINEL: resolved root ($SCRATCH_ROOT) equals the real default and no production opt-in is set (SCRATCHPAD_REAPER_PROD=1) — forcing dry-run this cycle (ga-h565g production sentinel)"
    DRY_RUN=1
  fi

  local lrc rc
  _acquire_lock
  lrc=$?
  case "$lrc" in
    0) ;;
    1) log "another scratchpad-reaper run holds $LOCK_DIR (pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')) — skipping this cycle"
       return 0 ;;
    *) log "ABORT: could not create the lock $LOCK_DIR — cannot rule out a concurrent run, skipping this cycle"
       return 1 ;;
  esac
  _reap_cycle
  rc=$?
  _release_lock
  return $rc
}

# One reap pass over SCRATCH_ROOT. Was the body of main() before ga-hynohs; the
# temp files are removed explicitly at each exit instead of by a RETURN trap
# (that trap leaks past its function when the file is sourced — see the note in
# the selftest — and main() now has a lock to release as well).
_reap_cycle() {
  local keyfile projfile now t0 reaped=0 freed_kb=0 candidates=0 eligible=0 failed=0
  t0=$(date +%s)
  keyfile="$(mktemp "${TMPDIR:-/tmp}/scratchpad-reaper-live.XXXXXX" 2>/dev/null || echo "/tmp/scratchpad-reaper-live.$$")"
  projfile="$(mktemp "${TMPDIR:-/tmp}/scratchpad-reaper-projs.XXXXXX" 2>/dev/null || echo "/tmp/scratchpad-reaper-projs.$$")"
  : > "$projfile"

  if ! _fetch_live_keys "$keyfile" || ! _fetch_proc_liveness "$keyfile" "$projfile"; then
    log "ABORT: skipping reap cycle entirely — could not establish a trustworthy live-session set"
    rm -f "$keyfile" "$projfile"
    return 1
  fi

  now=$(date +%s)
  shopt -s nullglob
  local dir sid proj mtime kb reap_reason age_h
  local scanned=0 skipped=0
  for dir in "$SCRATCH_ROOT"/*/*/scratchpad; do
    [ -d "$dir" ] || continue
    scanned=$((scanned + 1))
    sid="$(basename "$(dirname "$dir")")"
    proj="$(basename "$(dirname "$(dirname "$dir")")")"
    mtime="$(stat -f %m "$dir" 2>/dev/null || echo "")"
    kb=""
    reap_reason=""

    # Self/liveness is ABSOLUTE and identical for every path below — pressure
    # and idleness never get a say in it. A live or self dir isn't even a
    # "candidate"; skip silently, exactly as before ga-rjhfz. Same for a project
    # owned by a running claude that carries no session id (ga-hynohs).
    _is_dead "$sid" "$keyfile" "$SELF_SESSION_ID" || continue
    _project_protected "$proj" "$projfile" && continue

    if _is_stale "$mtime" "$now" "$MIN_AGE_HOURS"; then
      reap_reason="age"
    elif _is_idle_minutes "$mtime" "$now" "$MIN_IDLE_MINUTES"; then
      reap_reason="idle"
    elif [ "$PRESSURE" = "CRITICAL" ]; then
      # Only pay the du(1) cost for the size-escape check when pressure
      # actually makes it relevant — a dir already reaping via the normal
      # age path, or with no CRITICAL signal at all, never needs it here.
      kb="$(_dir_size_kb "$dir")"
      if _should_reap_size_escape "$sid" "$keyfile" "$mtime" "$now" "$CRITICAL_MIN_AGE_HOURS" "$SELF_SESSION_ID" "${kb:-0}" "$LARGE_GB"; then
        reap_reason="size-escape"
      fi
    fi

    candidates=$((candidates + 1))

    if [ -n "$reap_reason" ]; then
      eligible=$((eligible + 1))
      [ -n "$kb" ] || kb="$(_dir_size_kb "$dir")"
      if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would reap ($reap_reason): $proj/$sid/scratchpad (${kb:-?}KB)"
      elif _remove_scratchpad "$dir"; then
        reaped=$((reaped + 1))
        freed_kb=$((freed_kb + ${kb:-0}))
        log "reaped ($reap_reason): $proj/$sid/scratchpad (${kb:-?}KB freed)"
      else
        failed=$((failed + 1))
        log "FAILED to reap: $proj/$sid/scratchpad"
      fi
    else
      # ga-rjhfz: a dead-but-ineligible candidate is NEWS, not noise — the
      # real incident's mail read "cleanup attempted" as "nothing was there"
      # when 10GB of dead data sat right here, silently skipped. Cite size +
      # age + every threshold so a human never has to re-derive this by hand.
      skipped=$((skipped + 1))
      [ -n "$kb" ] || kb="$(_dir_size_kb "$dir")"
      case "$mtime" in
        ''|*[!0-9]*) age_h="?" ;;
        *) age_h=$(( (now - mtime) / 3600 )) ;;
      esac
      log "scratch-reap: candidato morto PULADO: $proj/$sid/scratchpad (${kb:-?}KB, idade=${age_h}h, min_age_hours=${MIN_AGE_HOURS}h, min_idle_minutes=${MIN_IDLE_MINUTES}, pressure=${PRESSURE:-none}, critical_min_age_hours=${CRITICAL_MIN_AGE_HOURS}h, large_gb=${LARGE_GB}GB)"
    fi
  done

  # ga-rjhfz: distinguish "nada encontrado" (no dead candidates at all — the
  # town is quiet) from "nada elegivel" (dead candidates existed, none
  # qualified) — the prior single generic line read identically for both,
  # which is exactly what let a real 10GB survivor hide behind "cleanup was
  # already attempted" in the caller's own incident mail.
  # ga-hynohs: "nada elegivel" now keys on `eligible`, not on `reaped` — a cycle
  # whose eligible candidates ALL failed to delete (or all only dry-ran) used to
  # read "0 elegivel", erasing the failure the same way ga-rjhfz erased the 10GB
  # survivor. elapsed= makes the run duration readable from the log alone.
  # live_ids / protected_projects: how big the liveness set was. A sweep that
  # suddenly finds nothing because an id-less claude is protecting a whole project
  # shows up here instead of looking like a quiet town.
  local elapsed=$(( $(date +%s) - t0 )) live_n proj_n
  live_n="$(grep -c . "$keyfile" 2>/dev/null || true)"
  proj_n="$(grep -c . "$projfile" 2>/dev/null || true)"
  local ctx="live_ids=${live_n:-?} protected_projects=${proj_n:-?} elapsed=${elapsed}s"
  if [ "$candidates" -eq 0 ]; then
    log "cycle complete: nada encontrado (scanned=$scanned dead_candidates=0) root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS min_idle_minutes=$MIN_IDLE_MINUTES pressure=${PRESSURE:-none} $ctx"
  elif [ "$eligible" -eq 0 ]; then
    log "cycle complete: nada elegivel ($candidates candidato(s) morto(s), 0 elegivel — ver PULADO acima) scanned=$scanned root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS min_idle_minutes=$MIN_IDLE_MINUTES pressure=${PRESSURE:-none} critical_min_age_hours=$CRITICAL_MIN_AGE_HOURS large_gb=$LARGE_GB $ctx"
  else
    log "cycle complete: candidates=$candidates eligible=$eligible reaped=$reaped failed=$failed skipped=$skipped freed_kb=$freed_kb scanned=$scanned root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS min_idle_minutes=$MIN_IDLE_MINUTES pressure=${PRESSURE:-none} enabled=$ENABLED dry_run=$DRY_RUN $ctx"
  fi
  rm -f "$keyfile" "$projfile"
  # A cycle in which a deletion failed must not look like a healthy one.
  [ "$failed" -eq 0 ]
}

# ── run unless sourced as a library (selftest sources with SCRATCHPAD_REAPER_LIB=1) ──
if [ "${SCRATCHPAD_REAPER_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
