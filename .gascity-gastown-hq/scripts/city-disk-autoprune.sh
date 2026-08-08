#!/usr/bin/env bash
# city-disk-autoprune.sh — cap the CITY's disk footprint so it never tips the
# Dolt data-dir to the crash floor (ga-vs55 class). Athos-approved 2026-07-17.
#
# ⚠️ SAFE BY CONSTRUCTION — written against tonight's destructive-daemon lessons
# (disk-floor-guard ga-eu2x, gatefix-janitor ga-0re8j). Every reclaim here is
# provably non-destructive to live/production/unmerged data:
#   • transcripts: only *.jsonl OLDER than N days (default 7) AND scoped to
#     this city's own tree (Gas Town project dirs only — see
#     TRANSCRIPT_SCOPE_PREFIX below, never another project on the machine) —
#     a live session's transcript is written continuously, so mtime>7d ⇒ dead
#     session.
#   • worktrees: `git worktree remove` WITHOUT --force — git REFUSES if the
#     worktree is dirty or locked. And removing a worktree never deletes the
#     branch ref (the janitor's exact bug). Only worktrees whose HEAD is an
#     ancestor of origin/main (merged) are even considered.
#   • logs: TRUNCATE (`: >`) files above a size cap — never delete (daemons hold
#     open fds; deleting orphans the fd, truncating is fd-safe).
# It NEVER touches: .dolt/, .beads/dolt/, shared/data, any production DB, or any
# path it cannot prove is reclaimable. When in doubt it SKIPS and logs the skip.
#
# KILL-SWITCH: CITY_AUTOPRUNE_ENABLED=0 → no-op. DRY-RUN: CITY_AUTOPRUNE_DRY_RUN=1
# → log what it WOULD do, delete/truncate nothing. Every action → jsonl audit.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG="${CITY_AUTOPRUNE_LOG:-$CITY/.gc/logs/city-disk-autoprune.jsonl}"
ENABLED="${CITY_AUTOPRUNE_ENABLED:-1}"
DRY="${CITY_AUTOPRUNE_DRY_RUN:-0}"
TRANSCRIPT_DAYS="${CITY_AUTOPRUNE_TRANSCRIPT_DAYS:-7}"
LOG_CAP_MB="${CITY_AUTOPRUNE_LOG_CAP_MB:-50}"
TRANSCRIPT_ROOT="${CITY_AUTOPRUNE_TRANSCRIPT_ROOT:-/Users/athos/.claude/projects}"
# ga-qb6yg gate-feedback (gate_run=ga-ruqpq): TRANSCRIPT_ROOT above is the
# user's ENTIRE Claude Code transcript tree, not scoped to this city — without
# a further filter, section 1 below would rm -f any project's transcript on
# the machine, not just Gas Town's. Claude Code encodes a session's cwd into
# its project-dir name by replacing "/" (and other separators) with "-", so
# every Gas Town project dir starts with this prefix (verified empirically
# 2026-08-08: 114/115 live project dirs on this host matched; the one
# exception was a /private/tmp scratchpad path — scratchpad-reaper.sh's job,
# not this one's). Only transcripts under a matching project dir are eligible.
TRANSCRIPT_SCOPE_PREFIX="${CITY_AUTOPRUNE_TRANSCRIPT_SCOPE_PREFIX:--Users-athos-gt}"

ts() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
emit() { printf '%s\n' "$1" >> "$LOG" 2>/dev/null || true; }
avail_gb() { df -g "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

[ "$ENABLED" != "1" ] && { emit "{\"ts\":\"$(ts)\",\"event\":\"skip\",\"reason\":\"CITY_AUTOPRUNE_ENABLED=0\"}"; exit 0; }

before="$(avail_gb "$CITY")"
emit "{\"ts\":\"$(ts)\",\"event\":\"start\",\"dry_run\":$DRY,\"avail_gb\":${before:-null}}"

# ── 1. TRANSCRIPTS older than N days (dead sessions) ─────────────────────────
if [ -d "$TRANSCRIPT_ROOT" ]; then
  # -mtime +N: strictly older than N*24h. A live session rewrites its jsonl, so
  # this can only match sessions dead >N days.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Scope guard (ga-qb6yg gate-feedback): only ever touch a transcript whose
    # Claude Code project dir is this city's own tree. projdir is the path
    # component immediately under TRANSCRIPT_ROOT; require an exact match or a
    # "-"-separated continuation so a lookalike like "-Users-athos-gtown" can
    # never pass as a prefix collision.
    projdir="${f#"$TRANSCRIPT_ROOT"/}"; projdir="${projdir%%/*}"
    case "$projdir" in
      "$TRANSCRIPT_SCOPE_PREFIX"|"$TRANSCRIPT_SCOPE_PREFIX"-*) : ;;
      *) continue ;;
    esac
    if [ "$DRY" = "1" ]; then
      emit "{\"ts\":\"$(ts)\",\"event\":\"would_delete_transcript\",\"file\":\"$f\"}"
    else
      rm -f "$f" 2>/dev/null && emit "{\"ts\":\"$(ts)\",\"event\":\"deleted_transcript\",\"file\":\"$f\"}"
    fi
  done < <(find "$TRANSCRIPT_ROOT" -name '*.jsonl' -mtime +"$TRANSCRIPT_DAYS" 2>/dev/null)
fi

# ── 2. MERGED + CLEAN worktrees across all rigs ──────────────────────────────
# `git worktree remove` (no --force) refuses on dirty/locked. Only consider
# worktrees whose HEAD is an ancestor of origin/main (work already landed).
prune_worktrees() {
  repo="$1"
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || return 0
  git -C "$repo" worktree prune 2>/dev/null || true
  git -C "$repo" fetch origin --quiet 2>/dev/null || true
  git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while IFS= read -r wt; do
    [ "$wt" = "$repo" ] && continue                      # never the main checkout
    case "$wt" in "$repo"/.git/*) continue;; esac
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; [ -n "$sha" ] || continue
    # merged only
    git -C "$repo" merge-base --is-ancestor "$sha" origin/main 2>/dev/null || continue
    if [ "$DRY" = "1" ]; then
      emit "{\"ts\":\"$(ts)\",\"event\":\"would_remove_worktree\",\"repo\":\"$(basename "$repo")\",\"wt\":\"$wt\"}"
    else
      # no --force: git refuses if dirty. Branch ref survives regardless.
      git -C "$repo" worktree remove "$wt" 2>/dev/null \
        && emit "{\"ts\":\"$(ts)\",\"event\":\"removed_worktree\",\"repo\":\"$(basename "$repo")\",\"wt\":\"$wt\"}" \
        || emit "{\"ts\":\"$(ts)\",\"event\":\"skip_worktree_dirty_or_locked\",\"wt\":\"$wt\"}"
    fi
  done
}
if command -v gc >/dev/null 2>&1; then
  gc rig list --json 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for r in (d if isinstance(d,list) else d.get("rigs") or []):
    if isinstance(r,dict) and r.get("path"): print(r["path"])
' 2>/dev/null | while IFS= read -r rig; do [ -d "$rig" ] && prune_worktrees "$rig"; done
fi
prune_worktrees "/Users/athos/gt"

# ── 3. TRUNCATE oversized daemon logs (fd-safe, never delete) ────────────────
cap_bytes=$(( LOG_CAP_MB * 1024 * 1024 ))
for d in "$CITY/.gc/logs" "/Users/athos/gt/.gc/logs"; do
  [ -d "$d" ] || continue
  find "$d" -type f \( -name '*.log' -o -name '*.out' -o -name '*.err' \) 2>/dev/null | while IFS= read -r lf; do
    sz=$(stat -f%z "$lf" 2>/dev/null || echo 0)
    [ "$sz" -gt "$cap_bytes" ] || continue
    if [ "$DRY" = "1" ]; then
      emit "{\"ts\":\"$(ts)\",\"event\":\"would_truncate_log\",\"file\":\"$lf\",\"bytes\":$sz}"
    else
      : > "$lf" 2>/dev/null && emit "{\"ts\":\"$(ts)\",\"event\":\"truncated_log\",\"file\":\"$lf\",\"was_bytes\":$sz}"
    fi
  done
done

after="$(avail_gb "$CITY")"
emit "{\"ts\":\"$(ts)\",\"event\":\"done\",\"avail_gb_before\":${before:-null},\"avail_gb_after\":${after:-null}}"
