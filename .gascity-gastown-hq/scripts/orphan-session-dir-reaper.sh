#!/bin/bash
# orphan-session-dir-reaper.sh (ga-kqbca) — reaper for ORPHAN Claude Code session
# directories under ~/.claude/projects/<project>/<session-id>/ that have NO
# matching <session-id>.jsonl transcript.
#
# WHY: discovered 2026-07-26 during ga-t1ub9's implementation (a reaper for dead
# .jsonl transcripts). Beyond the .jsonl transcripts themselves, each project dir
# also accumulates <session-id>/ directories (containing subfolders like
# tool-results/ — large Bash/tool output saved to disk instead of inline) that
# survive independently of the .jsonl. A single project dir (this dog's own,
# -Users-athos-gt--gascity-gastown-hq--gc-agents-dogs-gastown-dog-1) had 107 such
# orphans out of 225 session dirs at time of writing, ages 3-24+ days — likely a
# byproduct of ad hoc manual .jsonl cleanup (see ga-t1ub9: "o Mayor limpa manual
# >3d entre ciclos") that only ever removed the .jsonl, never its sibling dir, or
# would remain from a transcript-reaper covering .jsonl but not the directory once
# ga-t1ub9 itself ships. Outside ga-t1ub9's own scope by design (that bug's title
# says "*.jsonl" specifically) — filed separately rather than scope-creeping it.
#
# WHAT: scans ~/.claude/projects/<project>/<session-id>/ for every project/session
# pair, and removes the session-id LEAF directory (never the parent project dir)
# when ALL of:
#   1. NO MATCHING JSONL — <project>/<session-id>.jsonl does NOT exist. A session
#      with its transcript still present is never a candidate, regardless of
#      liveness or age — this is the differentiator vs. a plain dead+stale check.
#   2. DEAD — <session-id> does NOT appear in `gc session list --json`'s
#      `.sessions[].session_key` (active + suspended + anything not closed).
#      Absence = dead. Mirrors scratchpad-reaper.sh's (ga-02pnu) liveness check.
#   3. STALE — directory mtime is older than MIN_AGE_HOURS (default 72h = 3 days,
#      matching the disk-floor-guard family's convention). A grace buffer on top
#      of the liveness check, not the primary safety mechanism.
#   4. UUID-SHAPED — the directory basename matches Claude Code's session-id
#      format. Every entry actually written under a project dir is `<uuid>.jsonl`
#      or `<uuid>/`; this keeps anything else from ever becoming a candidate.
#
# SAFETY (same family as scratchpad-reaper.sh / ga-02pnu — "NUNCA reapar sessao
# ATIVA ... nem o dir da sessao corrente"):
#   - A `gc session list` query FAILURE (nonzero exit / unparseable JSON /
#     missing `.sessions` key) aborts the ENTIRE cycle with zero deletions — empty
#     and error must never collapse to the same "safe to reap" value (ga-p5q3
#     class). A genuinely-empty but well-formed `.sessions: []` is NOT an error
#     and proceeds normally — every candidate is still gated by MIN_AGE_HOURS.
#   - The CALLER's own session (env CLAUDE_CODE_SESSION_ID, when set) is EXCLUDED
#     unconditionally, independent of the live-session-list result.
#   - Only the exact `<session-id>` leaf is removed via `rm -rf` — never the
#     parent project directory, never a sibling session dir.
#
# ga-t1ub9 INCIDENT LESSON (2026-07-26, same implementation effort this bug was
# discovered in): a sibling reaper's selftest tried to redirect its root at a tmp
# fixture via an env var override, but used the WRONG var name (a typo'd prefix)
# — the real var silently fell back to its default and main() ran against the
# REAL ~/.claude/projects with a stubbed liveness list, deleting 185 real
# transcripts (62MB) city-wide. This script's selftest NEVER invokes main() at
# all (LIB mode below) — it unit-tests only the pure decision functions with
# synthetic values — so there is no root-path override for a future typo to
# defeat in the first place. See orphan-session-dir-reaper.selftest.sh.
#
# OUT OF SCOPE: does not touch *.jsonl files (transcript-reaper's job, ga-t1ub9);
# does not touch scratchpad dirs under /private/tmp (scratchpad-reaper's job,
# ga-02pnu); does not gate on disk pressure itself — the caller decides WHEN to
# invoke this (dolt-disk-floor-guard.sh's _reap_orphan_session_dirs lever).
#
# Kill switch: ORPHAN_SESSION_DIR_REAPER_ENABLED=0 -> dry-run regardless of
# ORPHAN_SESSION_DIR_REAPER_DRY_RUN (logs candidates, deletes nothing).
#
# TEST (no real ~/.claude/projects data touched, no deletions, hermetic fixtures):
#   bash scripts/orphan-session-dir-reaper.selftest.sh
# Library mode: `ORPHAN_SESSION_DIR_REAPER_LIB=1 source orphan-session-dir-reaper.sh`
# defines the pure decision functions WITHOUT running the reap flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
PROJECTS_ROOT="${ORPHAN_SESSION_DIR_REAPER_ROOT:-$HOME/.claude/projects}"
LOG="${ORPHAN_SESSION_DIR_REAPER_LOG:-$CITY/.gc/logs/orphan-session-dir-reaper.log}"
GC="${GC_BIN:-gc}"
ENABLED="${ORPHAN_SESSION_DIR_REAPER_ENABLED:-1}"
DRY_RUN="${ORPHAN_SESSION_DIR_REAPER_DRY_RUN:-0}"
MIN_AGE_HOURS="${ORPHAN_SESSION_DIR_REAPER_MIN_AGE_HOURS:-72}"
SELF_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by orphan-session-dir-reaper.selftest.sh.
# No side effects; bash-3.2-safe (no associative arrays — launchd invokes macOS
# system /bin/bash, same constraint noted in dolt-disk-floor-guard.sh).
# ════════════════════════════════════════════════════════════════════════════

# _looks_like_session_id <name> → 0 (true) iff name matches Claude Code's
# session-id (UUID) shape. Pure; no I/O.
_looks_like_session_id() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# _session_is_live <session_id> <live_keys_file> → 0 (true) iff session_id
# appears as an EXACT line in live_keys_file (grep -x — a prefix match must
# never count as live). A missing keyfile is treated as "not live" — the caller
# (main) never proceeds to the reap loop without a keyfile it trusts, so this
# only matters for direct/test invocation and fails toward "dead", not toward
# silently protecting everything.
_session_is_live() {
  local sid="$1" keyfile="$2"
  [ -f "$keyfile" ] || return 1
  grep -qxF "$sid" "$keyfile" 2>/dev/null
}

# _is_stale <mtime_epoch> <now_epoch> <min_age_hours> → 0 (true) iff the
# directory's mtime is at/past min_age_hours old. Non-numeric input (a `stat`
# failure) is NEVER stale — an unreadable mtime must not silently authorize
# deletion (same fail-loud idiom as scratchpad-reaper.sh's _is_stale).
_is_stale() {
  local mtime="$1" now="$2" min_hours="$3"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( (now - mtime) / 3600 )) -ge "$min_hours" ]
}

# _should_reap <session_id> <live_keys_file> <has_jsonl 0|1> <mtime_epoch>
#              <now_epoch> <min_age_hours> <self_session_id>
# → 0 (true) iff: not the caller's own session, AND not in the live list, AND
# has NO matching .jsonl, AND stale past min_age_hours. This is the SOLE gate
# for deletion — it composes every safety condition so no caller can
# accidentally skip one of them.
_should_reap() {
  local sid="$1" keyfile="$2" has_jsonl="$3" mtime="$4" now="$5" min_hours="$6" self="$7"
  [ -n "$self" ] && [ "$sid" = "$self" ] && return 1
  _session_is_live "$sid" "$keyfile" && return 1
  [ "$has_jsonl" = "1" ] && return 1
  _is_stale "$mtime" "$now" "$min_hours"
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest)
# ════════════════════════════════════════════════════════════════════════════

# _fetch_live_keys <out_file> → writes one session_key per line to out_file.
# Returns nonzero on ANY failure to positively confirm liveness data (nonzero
# exit, empty stdout, or JSON with no `.sessions` key) — a failure here must
# abort the whole cycle upstream, never be read as "nobody's alive, reap
# everything" (ga-p5q3 class). Deliberately no --state flag: the default
# listing (active + suspended + anything not closed) is exactly the dead-session
# criterion this reaper needs, same as scratchpad-reaper.sh.
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
  if [ ! -d "$PROJECTS_ROOT" ]; then
    log "PROJECTS_ROOT $PROJECTS_ROOT does not exist — nothing to do"
    return 0
  fi

  local keyfile now reaped=0 freed_kb=0 candidates=0
  keyfile="$(mktemp "${TMPDIR:-/tmp}/orphan-session-dir-reaper-live.XXXXXX" 2>/dev/null || echo "/tmp/orphan-session-dir-reaper-live.$$")"
  trap 'rm -f "$keyfile"' RETURN

  if ! _fetch_live_keys "$keyfile"; then
    log "ABORT: skipping reap cycle entirely — could not establish a trustworthy live-session set"
    return 1
  fi

  now=$(date +%s)
  shopt -s nullglob
  local dir sid proj mtime kb jsonl has_jsonl
  for dir in "$PROJECTS_ROOT"/*/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    sid="$(basename "$dir")"
    proj="$(basename "$(dirname "$dir")")"
    _looks_like_session_id "$sid" || continue
    jsonl="$PROJECTS_ROOT/$proj/$sid.jsonl"
    has_jsonl=0
    [ -f "$jsonl" ] && has_jsonl=1
    mtime="$(stat -f %m "$dir" 2>/dev/null || echo "")"
    if _should_reap "$sid" "$keyfile" "$has_jsonl" "$mtime" "$now" "$MIN_AGE_HOURS" "$SELF_SESSION_ID"; then
      candidates=$((candidates + 1))
      kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
      if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would reap: $proj/$sid (${kb:-?}KB)"
      elif rm -rf "$dir" 2>>"$LOG"; then
        reaped=$((reaped + 1))
        freed_kb=$((freed_kb + ${kb:-0}))
        log "reaped: $proj/$sid (${kb:-?}KB freed)"
      else
        log "FAILED to reap: $proj/$sid"
      fi
    fi
  done

  log "cycle complete: candidates=$candidates reaped=$reaped freed_kb=$freed_kb root=$PROJECTS_ROOT min_age_hours=$MIN_AGE_HOURS enabled=$ENABLED dry_run=$DRY_RUN"
}

# ── run unless sourced as a library (selftest sources with ORPHAN_SESSION_DIR_REAPER_LIB=1) ──
if [ "${ORPHAN_SESSION_DIR_REAPER_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
