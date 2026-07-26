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
# TEST (no real ~/.claude/projects data touched, no real deletions against live
# data — the integration test uses a disposable tmp root):
#   bash scripts/transcript-reaper.selftest.sh
# Library mode: `TRANSCRIPT_REAPER_LIB=1 source transcript-reaper.sh` defines
# the pure decision functions WITHOUT running the reap flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
TRANSCRIPT_ROOT="${TRANSCRIPT_REAPER_ROOT:-/Users/athos/.claude/projects}"
LOG="${TRANSCRIPT_REAPER_LOG:-$CITY/.gc/logs/transcript-reaper.log}"
GC="${GC_BIN:-gc}"
ENABLED="${TRANSCRIPT_REAPER_ENABLED:-1}"
DRY_RUN="${TRANSCRIPT_REAPER_DRY_RUN:-0}"
MIN_AGE_HOURS="${TRANSCRIPT_REAPER_MIN_AGE_HOURS:-72}"
SELF_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

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

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting). transcript-reaper.selftest.sh unit-tests the
# pure functions above AND integration-tests main() end-to-end against a
# disposable tmp root (scratchpad-reaper.sh's precedent only unit-tests its
# pure functions — this goes one step further given a transcript is
# irreplaceable data, not regeneratable scratch).
# ════════════════════════════════════════════════════════════════════════════

# _fetch_live_keys <out_file> → writes one session_key per line to out_file.
# Returns nonzero on ANY failure to positively confirm liveness data (nonzero
# exit, empty stdout, or JSON with no `.sessions` key) — a failure here must
# abort the whole cycle upstream, never be read as "nobody's alive, reap
# everything" (ga-p5q3 class). Deliberately no --state flag: the default
# listing (active + suspended/asleep + anything not closed) is exactly
# ga-t1ub9's stated dead-session criterion.
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
  if [ ! -d "$TRANSCRIPT_ROOT" ]; then
    log "TRANSCRIPT_ROOT $TRANSCRIPT_ROOT does not exist — nothing to do"
    return 0
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
