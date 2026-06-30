#!/usr/bin/env bash
# worktree-reaper.sh — the missing ROOT fix for .gc-worktrees sprawl.
# Gate-runs + crew builds create per-bead worktrees under /Users/athos/gt/.gc-worktrees/
# but NOTHING removed them → they accumulated (85 dirs / 2.2G / oldest 10 DAYS) and
# re-filled the disk hours after a manual reclaim, risking a Dolt/gate/daemon crash
# (crew flag 2026-06-16, P0 ga-u934d). The gate cycle is MINUTES, so a worktree older
# than STALE_HOURS is a completed/abandoned run that is safe to reap.
#
# ga-pdrij (2026-06-30): the .gc-worktrees scan MISSED the ephemeral POOL worktrees
# (wa-worker/ps-worker) that live under $GT/worker-<bead> and <rig>/crew/worker-<bead>
# — never scanned → 9 orphans lingered, and their orphan LOCAL crew/*/<bead> branches
# caused the Pilot's _filter_built to FALSE-VETO re-dispatch of re-anchored beads
# (bit wa-ys0cy: dispatched only after a manual worktree+branch cleanup). This script
# now ALSO enumerates each rig repo's worktrees via `git worktree list` (catches pool
# worktrees at ANY checkout path) and, on reaping a clean+stale one, deletes its local
# branch IFF that branch is already MERGED into origin/<default> (merged = work is safe;
# unmerged local-only branches are LEFT, never auto-deleted — no data loss).
#
# SAFETY: uses `git worktree remove` WITHOUT --force, so a worktree with UNCOMMITTED
# changes (a live long-running build's WIP) is REFUSED/skipped — only CLEAN stale
# worktrees are reaped. Age gate protects anything touched recently. Pressure mode
# lowers the age gate when disk is genuinely low. Branch deletion is merged-only.
# Kill switch: WORKTREE_REAPER_ENABLED=0.
set -uo pipefail
GT="${WORKTREE_REAPER_GT:-/Users/athos/gt}"   # overridable for the selftest (temp repo)
WT_DIR="$GT/.gc-worktrees"
LOG="${WORKTREE_REAPER_LOG:-$GT/.gascity-gastown-hq/.gc/logs/worktree-reaper.jsonl}"
ENABLED="${WORKTREE_REAPER_ENABLED:-1}"
STALE_HOURS="${WORKTREE_REAPER_STALE_HOURS:-24}"           # normal reap age
PRESSURE_HOURS="${WORKTREE_REAPER_PRESSURE_HOURS:-12}"     # reap age when disk low
PRESSURE_FREE_GB="${WORKTREE_REAPER_PRESSURE_FREE_GB:-8}"  # <this many GiB free = pressure
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

free_gb=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
[ -z "$free_gb" ] && free_gb=99
gate_hours="$STALE_HOURS"
mode="normal"
if [ "$free_gb" -lt "$PRESSURE_FREE_GB" ] 2>/dev/null; then gate_hours="$PRESSURE_HOURS"; mode="pressure"; fi

reaped=0; skipped_dirty=0; kept=0; branches_deleted=0; pool_reaped=0
# ga-pdrij: the rig-worktree backlog is LARGE (704 observed — the legacy loop used
# `git -C $GT` and could never remove rig-owned worktrees, so they piled up). Bound the
# per-sweep pool reaping so a single run is never a massive destructive operation; the
# backlog drains steadily over successive sweeps. Logged when hit (no silent truncation).
REAP_MAX_PER_SWEEP="${WORKTREE_REAPER_MAX_PER_SWEEP:-40}"
case "$REAP_MAX_PER_SWEEP" in ''|*[!0-9]*) REAP_MAX_PER_SWEEP=40 ;; esac
pool_cap_hit=0

# ── delete_merged_local_branch <repo> <branch> — delete a local crew/*/<bead> branch
# ONLY when it is already merged into origin/<default> (so the work is preserved in
# main). ga-pdrij: an orphan local crew branch left after a reaped worktree makes the
# Pilot's _filter_built treat the bead as "built" and silently veto re-dispatch. We
# clean it up — but merged-only, NEVER an unmerged local-only branch (would lose work).
delete_merged_local_branch() {
  local repo="$1" br="$2"
  [ -n "$br" ] || return 0
  case "$br" in crew/*) : ;; *) return 0 ;; esac   # only crew/* build branches
  command -v git >/dev/null 2>&1 || return 0
  local def; def="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -n "$def" ] || def="main"
  # merged check against origin/<default>; any uncertainty → do NOT delete.
  git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$def" >/dev/null 2>&1 || return 0
  if git -C "$repo" branch --merged "refs/remotes/origin/$def" 2>/dev/null | sed 's/^[* ] *//' | grep -qx "$br"; then
    if [ "$ENABLED" = "1" ]; then
      git -C "$repo" branch -D "$br" >/dev/null 2>&1 && {
        branches_deleted=$((branches_deleted+1))
        printf '{"ts":"%s","event":"branch_deleted","repo":"%s","branch":"%s","reason":"merged_orphan"}\n' "$(ts)" "$(basename "$repo")" "$br" >> "$LOG" 2>/dev/null
      }
    else
      printf '{"ts":"%s","event":"would_delete_branch","repo":"%s","branch":"%s"}\n' "$(ts)" "$(basename "$repo")" "$br" >> "$LOG" 2>/dev/null
    fi
  fi
}

# ── reap_pool_worktrees <repo> — enumerate a repo's worktrees via `git worktree list`
# (catches the pool worktrees at $GT/worker-* and <rig>/crew/worker-* that the path-glob
# loop below MISSES) and reap stale + CLEAN ones, deleting their merged orphan branch.
# Skips the main worktree (the repo root). no --force → dirty/live WIP is protected.
reap_pool_worktrees() {
  local repo="$1"
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || return 0
  local main_wt; main_wt="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || return 0
  local wt="" br=""
  # --porcelain emits blocks: "worktree <path>" / "HEAD <sha>" / "branch refs/heads/<b>"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; br="" ;;
      "branch "*)   br="${line#branch refs/heads/}" ;;
      "")  # end of a block — process it
        [ -n "$wt" ] || continue
        [ "$wt" = "$main_wt" ] && { wt=""; continue; }      # never the repo root
        # only the ephemeral pool worktrees: path basename contains "worker-" OR a crew/* branch
        case "$(basename "$wt")" in *worker-*) : ;; *) case "$br" in crew/*) : ;; *) wt=""; continue ;; esac ;; esac
        [ -d "$wt" ] || { wt=""; continue; }
        # per-sweep cap: stop reaping once hit (the backlog drains over the next sweeps)
        if [ "$ENABLED" = "1" ] && [ "$pool_reaped" -ge "$REAP_MAX_PER_SWEEP" ] 2>/dev/null; then
          [ "$pool_cap_hit" = "0" ] && { pool_cap_hit=1; printf '{"ts":"%s","event":"pool_cap_hit","cap":%s,"note":"backlog drains over next sweeps"}\n' "$(ts)" "$REAP_MAX_PER_SWEEP" >> "$LOG" 2>/dev/null; }
          wt=""; continue
        fi
        local age=$(( ( $(date +%s) - $(stat -f %m "$wt" 2>/dev/null || echo 0) ) / 3600 ))
        if [ "$age" -le "$gate_hours" ] 2>/dev/null; then kept=$((kept+1)); wt=""; continue; fi
        if [ "$ENABLED" != "1" ]; then
          printf '{"ts":"%s","event":"would_reap_pool","repo":"%s","wt":"%s","branch":"%s","age_h":%s}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$age" >> "$LOG" 2>/dev/null
          wt=""; continue
        fi
        if git -C "$repo" worktree remove "$wt" 2>/dev/null; then
          pool_reaped=$((pool_reaped+1))
          printf '{"ts":"%s","event":"reaped_pool","repo":"%s","wt":"%s","branch":"%s","age_h":%s,"mode":"%s"}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$age" "$mode" >> "$LOG" 2>/dev/null
          delete_merged_local_branch "$repo" "$br"
        else
          skipped_dirty=$((skipped_dirty+1))   # dirty/locked/live WIP → leave it
        fi
        wt=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  [ "$ENABLED" = "1" ] && git -C "$repo" worktree prune 2>/dev/null
}

# ── 1. legacy path-glob scan of .gc-worktrees (town repo) — UNCHANGED, proven ─────
if [ -d "$WT_DIR" ]; then
  for d in "$WT_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    age=$(( ( $(date +%s) - $(stat -f %m "$d") ) / 3600 ))
    if [ "$age" -le "$gate_hours" ]; then kept=$((kept+1)); continue; fi
    if [ "$ENABLED" != "1" ]; then
      printf '{"ts":"%s","event":"would_reap","wt":"%s","age_h":%s,"mode":"%s"}\n' "$(ts)" "$(basename "$d")" "$age" "$mode" >> "$LOG" 2>/dev/null
      continue
    fi
    # no --force: a worktree with uncommitted WIP (a live build) is REFUSED → protected.
    if git -C "$GT" worktree remove "$d" 2>/dev/null; then
      reaped=$((reaped+1))
      printf '{"ts":"%s","event":"reaped","wt":"%s","age_h":%s,"mode":"%s"}\n' "$(ts)" "$(basename "$d")" "$age" "$mode" >> "$LOG" 2>/dev/null
    else
      skipped_dirty=$((skipped_dirty+1))   # dirty/locked → has live WIP, leave it
    fi
  done
  [ "$ENABLED" = "1" ] && git -C "$GT" worktree prune 2>/dev/null
fi

# ── 2. ga-pdrij: per-RIG scan for POOL worktrees ──────────────────────────────────
# ONLY the rig repos (whatsapp_automation, property_scrapers, …) — NOT the town repo
# $GT, whose worktrees (.gc-worktrees gate-runs) are already handled by loop 1; running
# the pool scan on $GT would re-enumerate all ~700 town worktrees (overlap + noise, seen
# in the ga-pdrij dry-run). A rig's `git worktree list` catches its pool worktrees at ANY
# checkout path — both <rig>/crew/worker-* AND $GT/worker-<bead> (owned by the rig). The
# pattern filter (basename *worker-* OR a crew/* branch) keeps it to ephemeral pool builds.
# Best-effort; a missing/garbage repo is skipped.
for _repo in "$GT"/*/; do
  _repo="${_repo%/}"
  [ -d "$_repo/.git" ] || [ -f "$_repo/.git" ] || continue
  case "$(basename "$_repo")" in .gc-worktrees|.git|.claude|.worktrees) continue ;; esac
  reap_pool_worktrees "$_repo"
done

printf '{"ts":"%s","event":"sweep","mode":"%s","free_gb":%s,"gate_hours":%s,"reaped":%s,"pool_reaped":%s,"branches_deleted":%s,"skipped_dirty":%s,"kept":%s}\n' \
  "$(ts)" "$mode" "$free_gb" "$gate_hours" "$reaped" "$pool_reaped" "$branches_deleted" "$skipped_dirty" "$kept" >> "$LOG" 2>/dev/null
exit 0
