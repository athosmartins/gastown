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
#   - Only the exact `scratchpad` leaf is removed via `rm -rf` — never the
#     parent session directory or any sibling directory (e.g. `tasks/`).
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
# the caller ALSO explicitly opts in. Set ONLY by the real caller
# (dolt-disk-floor-guard.sh's _reap_dead_scratch) — never by a test.
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

main() {
  if [ ! -d "$SCRATCH_ROOT" ]; then
    log "SCRATCH_ROOT $SCRATCH_ROOT does not exist — nothing to do"
    return 0
  fi

  if _prod_sentinel_active "$SCRATCH_ROOT" "$SCRATCH_REAL_DEFAULT_ROOT" "$PROD"; then
    log "SENTINEL: resolved root ($SCRATCH_ROOT) equals the real default and no production opt-in is set (SCRATCHPAD_REAPER_PROD=1) — forcing dry-run this cycle (ga-h565g production sentinel)"
    DRY_RUN=1
  fi

  local keyfile now reaped=0 freed_kb=0 candidates=0
  keyfile="$(mktemp "${TMPDIR:-/tmp}/scratchpad-reaper-live.XXXXXX" 2>/dev/null || echo "/tmp/scratchpad-reaper-live.$$")"
  trap 'rm -f "$keyfile"' RETURN

  if ! _fetch_live_keys "$keyfile"; then
    log "ABORT: skipping reap cycle entirely — could not establish a trustworthy live-session set"
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

    # Self/liveness is ABSOLUTE and identical for both paths below — pressure
    # never gets a say in it. A live or self dir isn't even a "candidate";
    # skip silently, exactly as before ga-rjhfz.
    _is_dead "$sid" "$keyfile" "$SELF_SESSION_ID" || continue

    if _is_stale "$mtime" "$now" "$MIN_AGE_HOURS"; then
      reap_reason="age"
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
      [ -n "$kb" ] || kb="$(_dir_size_kb "$dir")"
      if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would reap ($reap_reason): $proj/$sid/scratchpad (${kb:-?}KB)"
      elif rm -rf "$dir" 2>>"$LOG"; then
        reaped=$((reaped + 1))
        freed_kb=$((freed_kb + ${kb:-0}))
        log "reaped ($reap_reason): $proj/$sid/scratchpad (${kb:-?}KB freed)"
      else
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
      log "scratch-reap: candidato morto PULADO: $proj/$sid/scratchpad (${kb:-?}KB, idade=${age_h}h, min_age_hours=${MIN_AGE_HOURS}h, pressure=${PRESSURE:-none}, critical_min_age_hours=${CRITICAL_MIN_AGE_HOURS}h, large_gb=${LARGE_GB}GB)"
    fi
  done

  # ga-rjhfz: distinguish "nada encontrado" (no dead candidates at all — the
  # town is quiet) from "nada elegivel" (dead candidates existed, none
  # qualified) — the prior single generic line read identically for both,
  # which is exactly what let a real 10GB survivor hide behind "cleanup was
  # already attempted" in the caller's own incident mail.
  if [ "$candidates" -eq 0 ]; then
    log "cycle complete: nada encontrado (scanned=$scanned dead_candidates=0) root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS pressure=${PRESSURE:-none}"
  elif [ "$reaped" -eq 0 ]; then
    log "cycle complete: nada elegivel ($candidates candidato(s) morto(s), 0 elegivel — ver PULADO acima) scanned=$scanned root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS pressure=${PRESSURE:-none} critical_min_age_hours=$CRITICAL_MIN_AGE_HOURS large_gb=$LARGE_GB"
  else
    log "cycle complete: candidates=$candidates reaped=$reaped skipped=$skipped freed_kb=$freed_kb scanned=$scanned root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS pressure=${PRESSURE:-none} enabled=$ENABLED dry_run=$DRY_RUN"
  fi
}

# ── run unless sourced as a library (selftest sources with SCRATCHPAD_REAPER_LIB=1) ──
if [ "${SCRATCHPAD_REAPER_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
