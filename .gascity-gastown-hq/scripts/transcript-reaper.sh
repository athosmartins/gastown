#!/bin/bash
# transcript-reaper.sh (ga-t1ub9, same family as ga-02pnu/scratchpad-reaper.sh) —
# reaper for DEAD-session Claude Code transcripts under ~/.claude/projects/.
#
# WHY: scratchpad-reaper.sh (ga-02pnu) reaps dead-session scratch under
# /private/tmp, but ~/.claude/projects/<project>/<session-id>.jsonl accumulates
# one transcript per session FOREVER with nothing to reap it — a disjoint leak
# class scratchpad-reaper.sh never touched. By 2026-07-26 this had grown to
# 1.4GB across 1232 files; disk hit 95% and Dolt ENOSPC'd twice that day (see
# ga-t1ub9 comments).
#
# WHAT: scans ~/.claude/projects/<project>/<session-id>.jsonl for every
# project/session pair, and removes the `.jsonl` file — PLUS its same-named
# sibling directory `<project>/<session-id>/` (tool-result blobs etc, when
# present; same session, same liveness proof applies to both) — when BOTH hold:
#   1. DEAD  — <session-id> (matches `gc session list --json`'s
#      `.sessions[].session_key`, NOT `.sessions[].id`) does NOT appear in the
#      default `gc session list` output (active + suspended/asleep + anything
#      not closed). Absence = dead. Identical mechanism to
#      scratchpad-reaper.sh's _fetch_live_keys — same call, same jq, same
#      abort-on-failure discipline.
#   2. STALE — the `.jsonl` file's mtime is older than MIN_AGE_HOURS (default
#      72h = 3 days, matching the established manual-cleanup cadence per
#      ga-t1ub9's own comment: "o Mayor limpa manual >3d entre ciclos").
#
# SAFETY (ga-t1ub9's explicit ask: "CRITICO: NUNCA reapar sessao VIVA nem
# SUSPENSA (sessao suspensa resume e precisa do transcript) — checar contra o
# session list, NAO so mtime") — higher stakes than scratchpad-reaper.sh: a
# transcript is irreplaceable conversation history, not regeneratable scratch;
# deleting a SUSPENDED session's transcript permanently breaks its resume.
#   - A `gc session list` query FAILURE (nonzero exit / unparseable JSON /
#     missing `.sessions` key) aborts the ENTIRE cycle with zero deletions —
#     empty and error must never collapse to the same "safe to reap" value
#     (ga-p5q3 class: error and empty must not produce the same value when the
#     emptiness is load-bearing).
#   - The CALLER's own session (env `CLAUDE_CODE_SESSION_ID`, when set) is
#     EXCLUDED unconditionally, independent of the live-session-list result —
#     belt-and-suspenders in case the current session hasn't propagated into
#     `gc session list` yet.
#   - Only the exact `<session-id>.jsonl` file (+ its same-named sibling dir,
#     when present) is removed — never a differently-named file.
#   - A session list entry with a null/absent `session_key` (observed for a
#     registered-but-never-started slot, and for a non-Claude managed process
#     sharing the same session list) is NOT treated as dead — its work_dir's
#     entire project directory is shielded from reaping instead, since its
#     transcript filename (if any) can't be named directly. See
#     _fetch_live_keys/_shield_unresolved_session (gate:fix-attempt:1 finding).
#
# OUT OF SCOPE: directories under ~/.claude/projects with NO matching `.jsonl`
# (observed to exist on this machine — a distinct leak, not what ga-t1ub9's fix
# text describes; flagged separately rather than folded in here). Does not gate
# on disk pressure itself — the caller (dolt-disk-floor-guard.sh) decides WHEN
# to invoke this; this script always applies the same dead+stale criteria.
#
# Kill switch: TRANSCRIPT_REAPER_ENABLED=0 -> dry-run regardless of
# TRANSCRIPT_REAPER_DRY_RUN (logs candidates, deletes nothing).
#
# PRODUCTION SENTINEL (ga-lfj05, completing ga-h565g's ask for this file — the
# 2026-07-26 incident where THIS script deleted 185 real transcripts because
# its selftest's harness bug left the resolved root at its REAL default
# instead of a tmp fixture): whenever the resolved root exactly equals the
# hardcoded real default AND TRANSCRIPT_REAPER_PROD!=1, main() forces a
# dry-run regardless of TRANSCRIPT_REAPER_DRY_RUN — the same harness mistake
# (forgetting to override the root) can never delete real data again unless
# the caller ALSO explicitly opts in. Set ONLY by the real caller
# (dolt-disk-floor-guard.sh's _reap_dead_transcripts) — never by a test.
#
# TEST (no real ~/.claude/projects data touched, no real deletions against live
# data — the integration test uses a disposable tmp root):
#   bash scripts/transcript-reaper.selftest.sh
# Library mode: `TRANSCRIPT_REAPER_LIB=1 source transcript-reaper.sh` defines
# the pure decision functions WITHOUT running the reap flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
TRANSCRIPT_REAL_DEFAULT_ROOT="/Users/athos/.claude/projects"
TRANSCRIPT_ROOT="${TRANSCRIPT_REAPER_ROOT:-$TRANSCRIPT_REAL_DEFAULT_ROOT}"
LOG="${TRANSCRIPT_REAPER_LOG:-$CITY/.gc/logs/transcript-reaper.log}"
GC="${GC_BIN:-gc}"
ENABLED="${TRANSCRIPT_REAPER_ENABLED:-1}"
DRY_RUN="${TRANSCRIPT_REAPER_DRY_RUN:-0}"
MIN_AGE_HOURS="${TRANSCRIPT_REAPER_MIN_AGE_HOURS:-72}"
SELF_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
PROD="${TRANSCRIPT_REAPER_PROD:-0}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by transcript-reaper.selftest.sh.
# Identical safety contract to scratchpad-reaper.sh's (dead AND stale AND
# not-self); duplicated rather than shared so each guard stays a fully
# standalone, independently-testable script — same no-shared-lib convention
# dolt-disk-floor-guard.sh/scratchpad-reaper.sh already use.
# ════════════════════════════════════════════════════════════════════════════

# _session_is_live <session_id> <live_keys_file> → 0 (true) iff session_id
# appears as an EXACT line in live_keys_file (grep -x — a prefix match must
# never count as live).
_session_is_live() {
  local sid="$1" keyfile="$2"
  [ -f "$keyfile" ] || return 1
  grep -qxF "$sid" "$keyfile" 2>/dev/null
}

# _is_stale <mtime_epoch> <now_epoch> <min_age_hours> → 0 (true) iff the
# file's mtime is at/past min_age_hours old. Non-numeric input (a `stat`
# failure) is NEVER stale — an unreadable mtime must not silently authorize
# deletion.
_is_stale() {
  local mtime="$1" now="$2" min_hours="$3"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( (now - mtime) / 3600 )) -ge "$min_hours" ]
}

# _should_reap <session_id> <live_keys_file> <mtime_epoch> <now_epoch>
#              <min_age_hours> <self_session_id>
# → 0 (true) iff: not the caller's own session, AND not in the live list, AND
# stale past min_age_hours. This is the SOLE gate for deletion.
_should_reap() {
  local sid="$1" keyfile="$2" mtime="$3" now="$4" min_hours="$5" self="$6"
  [ -n "$self" ] && [ "$sid" = "$self" ] && return 1
  _session_is_live "$sid" "$keyfile" && return 1
  _is_stale "$mtime" "$now" "$min_hours"
}

# _workdir_to_project_slug <work_dir> → the Claude Code project-directory
# name derived from a working directory: every '/' and '.' becomes '-'.
# Verified against this machine's live ~/.claude/projects/ entries, e.g.
# /Users/athos/gt/.gascity-gastown-hq -> -Users-athos-gt--gascity-gastown-hq.
_workdir_to_project_slug() {
  printf '%s' "$1" | tr '/.' '-'
}

# _prod_sentinel_active <resolved_root> <real_default_root> <prod_flag> → 0
# (true) iff resolved_root exactly equals real_default_root AND prod_flag is
# not "1". This is the ga-h565g guard (completed for this file by ga-lfj05): a
# caller (test or otherwise) that fails to override the root — leaving it at
# its real-default value — must never be able to trigger deletion just
# because it ALSO forgot to opt in; both conditions are required to authorize
# touching the real default root. Identical to scratchpad-reaper.sh's
# function of the same name.
_prod_sentinel_active() {
  local root="$1" real_default="$2" prod="$3"
  [ "$root" = "$real_default" ] && [ "$prod" != "1" ]
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting). transcript-reaper.selftest.sh unit-tests the
# pure functions above AND integration-tests main() end-to-end against a
# disposable tmp root (scratchpad-reaper.sh's precedent only unit-tests its
# pure functions — this goes one step further given a transcript is
# irreplaceable data, not regeneratable scratch).
# ════════════════════════════════════════════════════════════════════════════

# _shield_unresolved_session <out_file> <work_dir> <transcript_root> —
# appends every session-id found under <work_dir>'s project directory to
# <out_file> (the same live-keys file _session_is_live reads). Used for a
# `gc session list` entry that has NO session_key: we can't name its
# transcript file directly (no UUID on record), but any .jsonl already
# sitting in its project directory could be it, so all of them get the same
# protection a genuinely-live session_key would grant. No-op when work_dir
# is empty or its project directory doesn't exist — nothing to shield.
_shield_unresolved_session() {
  local out="$1" work_dir="$2" root="$3" dir f sid
  [ -n "$work_dir" ] || return 0
  dir="$root/$(_workdir_to_project_slug "$work_dir")"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    sid="$(basename "$f" .jsonl)"
    printf '%s\n' "$sid" >> "$out"
  done
}

# _fetch_live_keys <out_file> → writes one session_key per line to out_file,
# PLUS shielded ids for sessions we can't positively name (see below).
# Returns nonzero on ANY failure to positively confirm liveness data (nonzero
# exit, empty stdout, or `.sessions` missing/null/non-array) — a failure here
# must abort the whole cycle upstream, never be read as "nobody's alive, reap
# everything" (ga-p5q3 class). NOTE: `has("sessions")` alone is NOT this check
# — has() returns true for `{"sessions": null}` too (key presence, not value
# shape), which is precisely the gate:fix-attempt:2 finding: null collapsed to
# the same outcome as `[]`, jq's `.sessions[]` then errored (exit 5) on the
# null, got swallowed by `2>/dev/null`, and _fetch_live_keys returned 0 with an
# empty keyfile — every session read as dead. `(.sessions | type) == "array"`
# rejects null/missing/non-array roots alike (verified empirically) and
# subsumes the old has() check. Deliberately no --state flag: the default
# listing (active + suspended/asleep + anything not closed) is exactly
# ga-t1ub9's stated dead-session criterion.
#
# session_key can be null/absent on a live entry — observed on this system
# for a registered-but-never-started session slot (last_active is the zero
# value) and for a non-Claude managed process tracked by the same session
# list. The original implementation dropped these via `// empty`, giving
# them ZERO reap protection: _session_is_live can only match an id it was
# told about, so if such an entry ever turns out to own a real .jsonl,
# nothing would stop it being reaped once stale — the exact third-state
# collapse (unknown treated as the wrong-direction default) this reaper's
# own safety contract forbids. We can't name their transcript file (no
# session_key), so instead of excluding them we shield by work_dir: every
# .jsonl already in that project directory is added to the SAME live-keys
# file real session_keys go into. Over-protecting a directory is the safe
# direction for an irreversible delete; under-protecting one is not.
_fetch_live_keys() {
  local out="$1" raw rc
  raw="$("$GC" session list --json 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    log "ABORT: 'gc session list --json' failed (rc=$rc) or returned empty — cannot verify liveness"
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e '(.sessions | type) == "array"' >/dev/null 2>&1; then
    log "ABORT: 'gc session list --json' .sessions is missing, null, or non-array — cannot verify liveness"
    return 1
  fi

  : > "$out"
  printf '%s' "$raw" | jq -r '.sessions[] | select((.session_key // "") != "") | .session_key' >> "$out" 2>/dev/null

  local unresolved entry name id state wd
  unresolved="$(printf '%s' "$raw" | jq -c '.sessions[] | select((.session_key // "") == "")' 2>/dev/null)"
  if [ -n "$unresolved" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      name="$(printf '%s' "$entry" | jq -r '.session_name // .name // "?"' 2>/dev/null)"
      id="$(printf '%s' "$entry" | jq -r '.id // "?"' 2>/dev/null)"
      state="$(printf '%s' "$entry" | jq -r '.state // "?"' 2>/dev/null)"
      wd="$(printf '%s' "$entry" | jq -r '.work_dir // empty' 2>/dev/null)"
      if [ -n "$wd" ]; then
        log "session $name ($id, state=$state) has no session_key — shielding its project dir ($wd) instead of treating it as dead"
        _shield_unresolved_session "$out" "$wd" "$TRANSCRIPT_ROOT"
      else
        log "WARNING: session $name ($id, state=$state) has no session_key AND no work_dir — cannot shield; a transcript of its would have no reap protection"
      fi
    done <<< "$unresolved"
  fi
  return 0
}

main() {
  if [ ! -d "$TRANSCRIPT_ROOT" ]; then
    log "TRANSCRIPT_ROOT $TRANSCRIPT_ROOT does not exist — nothing to do"
    return 0
  fi

  if _prod_sentinel_active "$TRANSCRIPT_ROOT" "$TRANSCRIPT_REAL_DEFAULT_ROOT" "$PROD"; then
    log "SENTINEL: resolved root ($TRANSCRIPT_ROOT) equals the real default and no production opt-in is set (TRANSCRIPT_REAPER_PROD=1) — forcing dry-run this cycle (ga-h565g production sentinel)"
    DRY_RUN=1
  fi

  local keyfile now reaped=0 freed_kb=0 candidates=0
  keyfile="$(mktemp "${TMPDIR:-/tmp}/transcript-reaper-live.XXXXXX" 2>/dev/null || echo "/tmp/transcript-reaper-live.$$")"
  trap 'rm -f "$keyfile"' RETURN

  if ! _fetch_live_keys "$keyfile"; then
    log "ABORT: skipping reap cycle entirely — could not establish a trustworthy live-session set"
    return 1
  fi

  now=$(date +%s)
  shopt -s nullglob
  local file sid proj mtime kb sib_dir sib_kb total_kb ok
  for file in "$TRANSCRIPT_ROOT"/*/*.jsonl; do
    [ -f "$file" ] || continue
    proj="$(basename "$(dirname "$file")")"
    sid="$(basename "$file" .jsonl)"
    mtime="$(stat -f %m "$file" 2>/dev/null || echo "")"
    if _should_reap "$sid" "$keyfile" "$mtime" "$now" "$MIN_AGE_HOURS" "$SELF_SESSION_ID"; then
      candidates=$((candidates + 1))
      sib_dir="$(dirname "$file")/$sid"
      kb="$(du -sk "$file" 2>/dev/null | awk '{print $1}')"
      sib_kb=0
      [ -d "$sib_dir" ] && sib_kb="$(du -sk "$sib_dir" 2>/dev/null | awk '{print $1}')"
      total_kb=$(( ${kb:-0} + ${sib_kb:-0} ))
      if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would reap: $proj/$sid.jsonl (${total_kb}KB, sibling_dir=$([ -d "$sib_dir" ] && echo yes || echo no))"
      else
        ok=1
        rm -f "$file" 2>>"$LOG" || ok=0
        if [ -d "$sib_dir" ]; then
          rm -rf "$sib_dir" 2>>"$LOG" || ok=0
        fi
        if [ "$ok" = "1" ]; then
          reaped=$((reaped + 1))
          freed_kb=$((freed_kb + total_kb))
          log "reaped: $proj/$sid.jsonl (${total_kb}KB freed)"
        else
          log "FAILED to reap: $proj/$sid.jsonl (partial deletion possible — check manually)"
        fi
      fi
    fi
  done

  log "cycle complete: candidates=$candidates reaped=$reaped freed_kb=$freed_kb root=$TRANSCRIPT_ROOT min_age_hours=$MIN_AGE_HOURS enabled=$ENABLED dry_run=$DRY_RUN"
}

# ── run unless sourced as a library (selftest sources with TRANSCRIPT_REAPER_LIB=1) ──
if [ "${TRANSCRIPT_REAPER_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
