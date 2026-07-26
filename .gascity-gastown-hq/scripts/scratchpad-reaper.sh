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
#   2. STALE — directory mtime is older than MIN_AGE_HOURS (default 24h). This
#      is a grace buffer on top of the liveness check, not the primary safety
#      mechanism — it protects against a session that died moments ago and
#      whose disappearance from the live list hasn't propagated yet.
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
# gate on disk pressure itself — the caller (dolt-disk-floor-guard.sh) decides
# WHEN to invoke this; this script always applies the same dead+stale criteria.
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

# _should_reap <session_id> <live_keys_file> <mtime_epoch> <now_epoch>
#              <min_age_hours> <self_session_id>
# → 0 (true) iff: not the caller's own session, AND not in the live list, AND
# stale past min_age_hours. This is the SOLE gate for deletion — it composes
# every safety condition so no caller can accidentally skip one of them.
_should_reap() {
  local sid="$1" keyfile="$2" mtime="$3" now="$4" min_hours="$5" self="$6"
  [ -n "$self" ] && [ "$sid" = "$self" ] && return 1
  _session_is_live "$sid" "$keyfile" && return 1
  _is_stale "$mtime" "$now" "$min_hours"
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
  local dir sid proj mtime kb
  for dir in "$SCRATCH_ROOT"/*/*/scratchpad; do
    [ -d "$dir" ] || continue
    sid="$(basename "$(dirname "$dir")")"
    proj="$(basename "$(dirname "$(dirname "$dir")")")"
    mtime="$(stat -f %m "$dir" 2>/dev/null || echo "")"
    if _should_reap "$sid" "$keyfile" "$mtime" "$now" "$MIN_AGE_HOURS" "$SELF_SESSION_ID"; then
      candidates=$((candidates + 1))
      kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
      if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would reap: $proj/$sid/scratchpad (${kb:-?}KB)"
      elif rm -rf "$dir" 2>>"$LOG"; then
        reaped=$((reaped + 1))
        freed_kb=$((freed_kb + ${kb:-0}))
        log "reaped: $proj/$sid/scratchpad (${kb:-?}KB freed)"
      else
        log "FAILED to reap: $proj/$sid/scratchpad"
      fi
    fi
  done

  log "cycle complete: candidates=$candidates reaped=$reaped freed_kb=$freed_kb root=$SCRATCH_ROOT min_age_hours=$MIN_AGE_HOURS enabled=$ENABLED dry_run=$DRY_RUN"
}

# ── run unless sourced as a library (selftest sources with SCRATCHPAD_REAPER_LIB=1) ──
if [ "${SCRATCHPAD_REAPER_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
