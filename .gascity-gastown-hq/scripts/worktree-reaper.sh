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
# ── zombie-lock reaping (wa-8y45): a worktree LOCKED by a stuck/ancient agent ─────
ZOMBIE_LOCK_ENABLED="${WORKTREE_REAPER_ZOMBIE_LOCK_ENABLED:-1}"  # 0 = old behavior (skip ALL locked)
ZOMBIE_HOURS="${WORKTREE_REAPER_ZOMBIE_HOURS:-48}"               # alive holder must EXCEED this AND be idle
case "$ZOMBIE_HOURS" in ''|*[!0-9]*) ZOMBIE_HOURS=48 ;; esac
ZOMBIE_MAX_CPU="${WORKTREE_REAPER_ZOMBIE_MAX_CPU:-5}"            # 'idle' = recent %cpu <= this (percent)
ZOMBIE_MAX_CPU_X10="$(printf '%s' "$ZOMBIE_MAX_CPU" | awk '{gsub(/,/,"."); printf "%d", ($1*10)+0.5}')"
case "$ZOMBIE_MAX_CPU_X10" in ''|*[!0-9]*) ZOMBIE_MAX_CPU_X10=50 ;; esac
KILL_ZOMBIE="${WORKTREE_REAPER_KILL_ZOMBIE:-0}"                  # SIGTERM the confirmed zombie pid (guarded; default OFF)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

free_gb=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
[ -z "$free_gb" ] && free_gb=99
gate_hours="$STALE_HOURS"
mode="normal"
if [ "$free_gb" -lt "$PRESSURE_FREE_GB" ] 2>/dev/null; then gate_hours="$PRESSURE_HOURS"; mode="pressure"; fi

reaped=0; skipped_dirty=0; kept=0; branches_deleted=0; pool_reaped=0; zombie_reaped=0
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

# ── ZOMBIE-LOCK DETECTION (the fix for wa-8y45) ──────────────────────────────────
# A crew/agent worktree is `git worktree lock`ed while its agent session is alive, so the
# reaper rightly SKIPS locked trees (a live agent may be mid-build). But a STUCK agent —
# dead, or alive-but-ancient-and-idle — holds that lock forever, pinning a stale conflicted
# worktree that blocks re-dispatch (wa-8y45: pid 42047 alive 4d7h @ 0.3% CPU pinned a P1 for
# 4 days). These helpers decide whether a lock holder is a ZOMBIE so its worktree can be
# unlock+reaped. CONSERVATIVE by construction: any doubt (can't parse pid, can't probe the
# process, holder is young, or shows recent CPU) → NOT a zombie → the worktree is KEPT.
# Process probes are seam-injectable (WORKTREE_REAPER_FAKE_*) so the selftest is hermetic.

_etime_to_secs() {           # macOS `ps -o etime` "[[DD-]HH:]MM:SS" → seconds
  local e="$1" days=0 hms h m s
  e="${e// /}"; [ -n "$e" ] || { echo 0; return; }
  case "$e" in *-*) days="${e%%-*}"; hms="${e#*-}" ;; *) hms="$e" ;; esac
  local IFS=:; set -- $hms
  if   [ "$#" -eq 3 ]; then h="$1"; m="$2"; s="$3"
  elif [ "$#" -eq 2 ]; then h=0;    m="$1"; s="$2"
  else                      h=0;    m=0;    s="$1"; fi
  echo $(( 10#${days:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}

# _pid_probe <pid> → "alive <elapsed_secs> <cpu_x10>" | "dead 0 0"
# Seam: WORKTREE_REAPER_FAKE_PS=<file>, rows "<pid> <alive|dead> <esecs> <cpu_x10>".
_pid_probe() {
  local pid="$1"
  if [ -n "${WORKTREE_REAPER_FAKE_PS:-}" ]; then
    if [ -f "$WORKTREE_REAPER_FAKE_PS" ]; then
      awk -v p="$pid" '$1==p{print $2, $3, $4; f=1; exit} END{if(!f) print "dead 0 0"}' "$WORKTREE_REAPER_FAKE_PS"
    else echo "dead 0 0"; fi
    return
  fi
  ps -p "$pid" >/dev/null 2>&1 || { echo "dead 0 0"; return; }
  local esecs cpux10
  esecs="$(_etime_to_secs "$(ps -o etime= -p "$pid" 2>/dev/null)")"
  cpux10="$(ps -o %cpu= -p "$pid" 2>/dev/null | awk '{gsub(/,/,"."); gsub(/ /,""); printf "%d", ($1*10)+0.5}')"
  case "$esecs"  in ''|*[!0-9]*) esecs=0 ;; esac
  case "$cpux10" in ''|*[!0-9]*) cpux10=0 ;; esac
  echo "alive $esecs $cpux10"
}

# _pid_cmdline <pid> → process command line. Seam: WORKTREE_REAPER_FAKE_CMDLINE=<file>.
_pid_cmdline() {
  local pid="$1"
  if [ -n "${WORKTREE_REAPER_FAKE_CMDLINE:-}" ] && [ -f "$WORKTREE_REAPER_FAKE_CMDLINE" ]; then
    awk -v p="$pid" '$1==p{ $1=""; sub(/^ /,""); print; exit }' "$WORKTREE_REAPER_FAKE_CMDLINE"; return
  fi
  ps -o command= -p "$pid" 2>/dev/null
}

# classify_lock <lock-reason> → "zombie <pid> <why>" | "live <pid> ..." | "unparseable"
# ZOMBIE iff: pid is DEAD, OR pid is alive but elapsed > ZOMBIE_HOURS AND recent %cpu is
# negligible (idle). The elapsed gate alone is already strong — a live agent working one
# worktree continuously for >2 days is implausible here (sessions cycle); wa-8y45 was 4d7h.
# The idle check only makes the rule STRICTER (a busy-but-ancient proc is kept). Fail-safe:
# no parseable pid → "unparseable" (KEEP), never guess.
classify_lock() {
  local reason="$1" pid probe alive esecs cpu thr
  pid="$(printf '%s' "$reason" | sed -n 's/.*pid[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p')"
  [ -n "$pid" ] || { echo "unparseable"; return; }
  probe="$(_pid_probe "$pid")"
  alive="$(printf '%s\n' "$probe" | awk '{print $1}')"
  esecs="$(printf '%s\n' "$probe" | awk '{print $2}')"
  cpu="$(printf   '%s\n' "$probe" | awk '{print $3}')"
  if [ "$alive" = "dead" ]; then echo "zombie $pid dead"; return; fi
  thr=$(( ZOMBIE_HOURS * 3600 ))
  if [ "${esecs:-0}" -gt "$thr" ] 2>/dev/null && [ "${cpu:-99999}" -le "$ZOMBIE_MAX_CPU_X10" ] 2>/dev/null; then
    echo "zombie $pid ancient_idle(esecs=$esecs,cpu_x10=$cpu)"
  else
    echo "live $pid esecs=$esecs cpu_x10=$cpu"
  fi
}

# _maybe_kill_zombie <pid> — SIGTERM a confirmed zombie's process, but ONLY when explicitly
# enabled AND the cmdline is a plain claude agent — NEVER a supervisor/pilot/gate/reconciler/
# daemon. Default OFF: freeing the worktree is the fix; an idle process is harmless. Seam:
# WORKTREE_REAPER_KILL_SINK=<file> records the pid instead of signaling (hermetic test).
_maybe_kill_zombie() {
  local pid="$1" cmd
  [ "$KILL_ZOMBIE" = "1" ] || return 0
  [ -n "$pid" ] || return 0
  cmd="$(_pid_cmdline "$pid")"
  [ -n "$cmd" ] || return 0                                      # dead/unknown → nothing to kill
  case "$cmd" in *[Cc]laude*) : ;; *) return 0 ;; esac          # must be a claude process
  if printf '%s' "$cmd" | grep -qiE 'pilot|gate|mayor|deacon|witness|reconcil|supervis|dispatch|watchdog|reaper|sheriff|refin|daemon|kickstart|observer'; then
    printf '{"ts":"%s","event":"kill_skipped_protected","pid":%s}\n' "$(ts)" "$pid" >> "$LOG" 2>/dev/null
    return 0                                                     # controller process → NEVER signal
  fi
  if [ -n "${WORKTREE_REAPER_KILL_SINK:-}" ]; then echo "$pid" >> "$WORKTREE_REAPER_KILL_SINK"
  else kill -TERM "$pid" 2>/dev/null; fi
  printf '{"ts":"%s","event":"zombie_pid_killed","pid":%s}\n' "$(ts)" "$pid" >> "$LOG" 2>/dev/null
}

# reap_zombie_locked <repo> <wt> <br> <reason> <age_h> <label>
#   → 0 reaped | 1 dry-run logged | 2 NOT-a-zombie (caller KEEPS) | 3 remove failed
# unlock + DOUBLE-force remove (single --force is refused on a locked tree) + merged-only
# branch cleanup (never deletes unmerged local work) + optional guarded process kill.
reap_zombie_locked() {
  local repo="$1" wt="$2" br="$3" reason="$4" age="$5" label="$6" verdict pid why
  verdict="$(classify_lock "$reason")"
  case "$verdict" in zombie\ *) : ;; *) return 2 ;; esac
  pid="$(printf '%s' "$verdict" | awk '{print $2}')"
  why="$(printf '%s' "$verdict" | cut -d' ' -f3-)"
  if [ "$ENABLED" != "1" ]; then
    printf '{"ts":"%s","event":"would_reap_zombie_lock","repo":"%s","wt":"%s","branch":"%s","pid":%s,"why":"%s","age_h":%s,"label":"%s"}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$pid" "$why" "$age" "$label" >> "$LOG" 2>/dev/null
    return 1
  fi
  git -C "$repo" worktree unlock "$wt" 2>/dev/null || true
  if git -C "$repo" worktree remove -f -f "$wt" 2>/dev/null; then
    printf '{"ts":"%s","event":"reaped_zombie_lock","repo":"%s","wt":"%s","branch":"%s","pid":%s,"why":"%s","age_h":%s,"label":"%s","mode":"%s"}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$pid" "$why" "$age" "$label" "$mode" >> "$LOG" 2>/dev/null
    delete_merged_local_branch "$repo" "$br"
    _maybe_kill_zombie "$pid"
    return 0
  fi
  printf '{"ts":"%s","event":"zombie_reap_failed","repo":"%s","wt":"%s","pid":%s}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$pid" >> "$LOG" 2>/dev/null
  return 3
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
      "worktree "*) wt="${line#worktree }"; br=""; lock="" ;;
      "branch "*)   br="${line#branch refs/heads/}" ;;
      "locked "*)   lock="${line#locked }" ;;
      "locked")     lock="(no reason)" ;;
      "")  # end of a block — process it
        [ -n "$wt" ] || continue
        [ "$wt" = "$main_wt" ] && { wt=""; br=""; lock=""; continue; }   # never the repo root
        # ephemeral FRAMEWORK worktrees ONLY — never durable feature trees (.wt-*, clones):
        #   basename worker-*  OR  crew/* branch  OR  under .claude/worktrees/  OR  under .gc-worktrees/
        # (.claude/worktrees = native agent trees like wa-8y45; .gc-worktrees = gate-review trees)
        case "$(basename "$wt")" in
          *worker-*) : ;;
          *) case "$br" in
               crew/*) : ;;
               *) case "$wt" in
                    */.claude/worktrees/*|*/.gc-worktrees/*) : ;;
                    *) wt=""; br=""; lock=""; continue ;;
                  esac ;;
             esac ;;
        esac
        [ -d "$wt" ] || { wt=""; br=""; lock=""; continue; }
        # per-sweep cap: stop reaping once hit (the backlog drains over the next sweeps)
        if [ "$ENABLED" = "1" ] && [ "$pool_reaped" -ge "$REAP_MAX_PER_SWEEP" ] 2>/dev/null; then
          [ "$pool_cap_hit" = "0" ] && { pool_cap_hit=1; printf '{"ts":"%s","event":"pool_cap_hit","cap":%s,"note":"backlog drains over next sweeps"}\n' "$(ts)" "$REAP_MAX_PER_SWEEP" >> "$LOG" 2>/dev/null; }
          wt=""; continue
        fi
        local age=$(( ( $(date +%s) - $(stat -f %m "$wt" 2>/dev/null || echo 0) ) / 3600 ))
        if [ "$age" -le "$gate_hours" ] 2>/dev/null; then kept=$((kept+1)); wt=""; br=""; lock=""; continue; fi
        # ── LOCKED worktree: reap ONLY if the lock holder is a ZOMBIE (dead / ancient+idle).
        # A live agent's lock (young, or recent CPU) is ALWAYS kept — never reap active work.
        if [ -n "$lock" ]; then
          if [ "$ZOMBIE_LOCK_ENABLED" = "1" ]; then
            local zrc
            reap_zombie_locked "$repo" "$wt" "$br" "$lock" "$age" "pool"; zrc=$?
            case "$zrc" in
              0) pool_reaped=$((pool_reaped+1)); zombie_reaped=$((zombie_reaped+1)) ;;
              1) : ;;                                    # dry-run intent logged
              2) kept=$((kept+1))                        # live/unparseable holder → KEEP
                 printf '{"ts":"%s","event":"kept_locked_live","repo":"%s","wt":"%s","branch":"%s","age_h":%s}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$age" >> "$LOG" 2>/dev/null ;;
              *) skipped_dirty=$((skipped_dirty+1)) ;;   # zombie confirmed but remove failed
            esac
          else
            kept=$((kept+1))                             # zombie handling disabled → old behavior (skip locked)
          fi
          wt=""; br=""; lock=""; continue
        fi
        # ── UNLOCKED path (existing, proven): no --force protects live/dirty WIP ─────────
        if [ "$ENABLED" != "1" ]; then
          printf '{"ts":"%s","event":"would_reap_pool","repo":"%s","wt":"%s","branch":"%s","age_h":%s}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$age" >> "$LOG" 2>/dev/null
          wt=""; br=""; lock=""; continue
        fi
        if git -C "$repo" worktree remove "$wt" 2>/dev/null; then
          pool_reaped=$((pool_reaped+1))
          printf '{"ts":"%s","event":"reaped_pool","repo":"%s","wt":"%s","branch":"%s","age_h":%s,"mode":"%s"}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$age" "$mode" >> "$LOG" 2>/dev/null
          delete_merged_local_branch "$repo" "$br"
        else
          skipped_dirty=$((skipped_dirty+1))   # dirty/locked/live WIP → leave it
        fi
        wt=""; br=""; lock=""
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
    elif [ "$ZOMBIE_LOCK_ENABLED" = "1" ] && \
         lock_reason="$(git -C "$GT" worktree list --porcelain 2>/dev/null | awk -v p="$d" '$1=="worktree"{c=$2} $1=="locked"{ if(c==p){ $1=""; sub(/^ /,""); print; exit } }')" && \
         [ -n "$lock_reason" ]; then
      # plain remove was refused by a LOCK — reap ONLY if the holder is a zombie, else keep.
      reap_zombie_locked "$GT" "$d" "" "$lock_reason" "$age" "town"; zrc1=$?
      case "$zrc1" in
        0) reaped=$((reaped+1)); zombie_reaped=$((zombie_reaped+1)) ;;
        *) skipped_dirty=$((skipped_dirty+1)) ;;   # not-zombie / dry-run / fail → leave it
      esac
    else
      skipped_dirty=$((skipped_dirty+1))   # dirty/locked (live) → has live WIP, leave it
    fi
  done
  [ "$ENABLED" = "1" ] && git -C "$GT" worktree prune 2>/dev/null
fi

# ── 2. ga-pdrij: per-RIG scan for POOL worktrees ──────────────────────────────────
# ONLY the rig repos (whatsapp_automation, property_scrapers, …) — NOT the town repo
# $GT, whose worktrees (.gc-worktrees gate-runs) are already handled by loop 1; running
# the pool scan on $GT would re-enumerate all ~700 town worktrees (overlap + noise, seen
# in the ga-pdrij dry-run). A rig's `git worktree list` catches its pool worktrees at ANY
# checkout path — <rig>/crew/worker-*, $GT/worker-<bead> (owned by the rig), <rig>/.claude/
# worktrees/agent-* (native agent trees, e.g. wa-8y45), AND <rig>/.gc-worktrees/<bead>-*
# (gate-review trees). The pattern filter (basename *worker-*, OR crew/* branch, OR a path
# under .claude/worktrees / .gc-worktrees) keeps it to ephemeral FRAMEWORK worktrees and
# never touches durable feature trees. Best-effort; a missing/garbage repo is skipped.
for _repo in "$GT"/*/; do
  _repo="${_repo%/}"
  [ -d "$_repo/.git" ] || [ -f "$_repo/.git" ] || continue
  case "$(basename "$_repo")" in .gc-worktrees|.git|.claude|.worktrees) continue ;; esac
  reap_pool_worktrees "$_repo"
done

printf '{"ts":"%s","event":"sweep","mode":"%s","free_gb":%s,"gate_hours":%s,"reaped":%s,"pool_reaped":%s,"zombie_reaped":%s,"branches_deleted":%s,"skipped_dirty":%s,"kept":%s}\n' \
  "$(ts)" "$mode" "$free_gb" "$gate_hours" "$reaped" "$pool_reaped" "$zombie_reaped" "$branches_deleted" "$skipped_dirty" "$kept" >> "$LOG" 2>/dev/null
exit 0
