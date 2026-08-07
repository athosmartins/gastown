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
# changes (a live long-running build's WIP) is REFUSED by the plain path below — but an
# aged, UNLOCKED, dirty pool worktree then falls through to preserve_and_reap_dirty(),
# which snapshots the WIP to a commit object, confirms it landed on origin (own branch
# name, else refs/reclaimed/<label>/<sha>), and ONLY THEN force-removes. If durability
# can't be confirmed, the worktree is left byte-for-byte as it was — still dirty, so the
# next sweep refuses it again too; nothing is ever removed on an unconfirmed guess. Age
# gate protects anything touched recently. Pressure mode lowers the age gate when disk is
# genuinely low. Branch deletion is merged-only. Kill switch: WORKTREE_REAPER_ENABLED=0.
set -uo pipefail
GT="${WORKTREE_REAPER_GT:-/Users/athos/gt}"   # overridable for the selftest (temp repo)
# ga-t14of: .gc-worktrees accumulates under MULTIPLE physical roots in practice — the
# "canonical" $GT/.gc-worktrees AND $GT/.gascity-gastown-hq/.gc-worktrees (most agents'
# cwd is inside .gascity-gastown-hq, so `git worktree add .gc-worktrees/<name> ...` run
# from there lands on the nested path instead). Both are worktrees of the SAME repo as
# $GT — .gascity-gastown-hq has no .git of its own (confirmed: `git -C .../gascity-
# gastown-hq rev-parse --show-toplevel` reports $GT) — so it is invisible to the per-rig
# loop below too, which deliberately skips $GT itself on the assumption "loop 1 already
# covers $GT's worktrees". That assumption held for the flat path but not this nested
# one: measured live, 105 dirs / 2.9G sat here, NEVER once scanned (zero hits in months
# of reaper-log history) while the flat path quietly drained on schedule the whole time.
WT_DIRS="${WORKTREE_REAPER_WT_DIRS:-$GT/.gc-worktrees $GT/.gascity-gastown-hq/.gc-worktrees}"
LOG="${WORKTREE_REAPER_LOG:-$GT/.gascity-gastown-hq/.gc/logs/worktree-reaper.jsonl}"
ENABLED="${WORKTREE_REAPER_ENABLED:-1}"
STALE_HOURS="${WORKTREE_REAPER_STALE_HOURS:-24}"           # normal reap age
PRESSURE_HOURS="${WORKTREE_REAPER_PRESSURE_HOURS:-12}"     # reap age when disk low
PRESSURE_FREE_GB="${WORKTREE_REAPER_PRESSURE_FREE_GB:-8}"  # <this many GiB free = pressure
# ga-t14of: minimum age (minutes) before a MERGED worktree is eligible for the fast-path
# reap below, bypassing STALE_HOURS/PRESSURE_HOURS. Without this, a worktree branched
# from origin/main seconds ago and not yet touched is trivially "merged" too — its HEAD
# already equals main's tip, since nothing has diverged yet — and would be reaped before
# its agent got a chance to start (caught live: this fix's own selftest, "fresh worktree
# wrongly reaped", would have destroyed the in-progress worktree this very fix was built
# in). This is a separate, much smaller grace period than STALE_HOURS — long enough that
# a just-claimed worktree survives the read-context/gc-prime window before first commit,
# short enough to still resolve the reported multi-day pileup on the very next sweep.
MERGED_MIN_AGE_MIN="${WORKTREE_REAPER_MERGED_MIN_AGE_MIN:-30}"
case "$MERGED_MIN_AGE_MIN" in ''|*[!0-9]*) MERGED_MIN_AGE_MIN=30 ;; esac
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

reaped=0; skipped_dirty=0; kept=0; branches_deleted=0; pool_reaped=0; zombie_reaped=0; preserved_dirty=0
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

# ── _worktree_head_merged <repo> <wt> — ga-t14of: true iff the worktree's current HEAD
# commit is already an ancestor of origin/<default>. Uses the worktree's OWN checked-out
# commit (git -C "$wt" rev-parse HEAD) rather than a branch name, so it works whether the
# worktree is on a branch or DETACHED — what actually matters for safety is "is this
# CONTENT already in main", not branch bookkeeping. <repo> supplies the origin/<default>
# lookup (shared git dir/refs across every worktree of the same repo). Any uncertainty
# (no HEAD, no origin/default, git failure) → NOT merged, never guess — same fail-closed
# philosophy as delete_merged_local_branch above.
_worktree_head_merged() {
  local repo="$1" wt="$2" def head
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ -n "$head" ] || return 1
  def="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -n "$def" ] || def="main"
  git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$def" >/dev/null 2>&1 || return 1
  git -C "$repo" merge-base --is-ancestor "$head" "refs/remotes/origin/$def" 2>/dev/null
}

# ── _worktree_in_use <path> — ga-t14of: true iff a live process's CWD is the worktree
# path itself or a subdirectory of it. Defense-in-depth beyond git's own dirty-check: a
# git-CLEAN worktree can still be someone's live shell/build cwd, and removing it out
# from under that process breaks it even though no file content is lost — the exact
# failure mode ga-t14of's acceptance criteria calls out ("worktree em uso não é
# removido, mesmo que a branch esteja mergeada"). Gates the merged-branch fast path
# below, which otherwise bypasses the age gate that used to be the only thing standing
# between "just created" and "removed". lsof unavailable/failing → fail SAFE (treat as
# in-use; never guess a worktree is free). Seam: WORKTREE_REAPER_FAKE_LSOF=<file>, one
# absolute cwd path per line, for a hermetic selftest.
_worktree_in_use() {
  local path="$1"
  if [ -n "${WORKTREE_REAPER_FAKE_LSOF:-}" ]; then
    [ -f "$WORKTREE_REAPER_FAKE_LSOF" ] || return 1
    awk -v p="$path" '{ if ($0 == p || index($0, p "/") == 1) { found=1; exit } } END { exit(found ? 0 : 1) }' "$WORKTREE_REAPER_FAKE_LSOF"
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -d cwd -Fn 2>/dev/null | awk -v p="$path" '
    /^n/ { d = substr($0, 2); if (d == p || index(d, p "/") == 1) { found=1; exit } }
    END { exit(found ? 0 : 1) }
  '
}

# ── preserve_and_reap_dirty <repo> <wt> <br> <age> — ga-xv78c: an UNLOCKED pool
# worktree that plain `worktree remove` refused is DIRTY (uncommitted/untracked
# WIP) — the old behavior counted it as skipped_dirty and left it forever, since
# dirty state never self-clears. 94 subagent trees leaked this way across 5 crews
# (5.9G), and disk hit 95%, breaking the ITBI pipeline's SQLite. Snapshot the WIP
# into a commit object via a SCRATCH index (GIT_INDEX_FILE) — the real working tree
# and index are never touched — push it durable to origin (own branch name if free,
# else refs/reclaimed/<label>/<sha> — same convention as inflight-reclaim-guard.py's
# preserve_unpushed_branch), and ONLY THEN force-remove.
#
# gate-feedback (fix-attempt 1): the first version did a real `git commit` BEFORE
# either push was attempted. When both pushes failed, the function correctly
# returned "kept" — but the worktree was now git-CLEAN (the commit already
# happened locally), so the very next sweep's plain, non-force `worktree remove`
# (the branch above this one, in reap_pool_worktrees) silently succeeded and
# deleted it, logging a routine reaped_pool event indistinguishable from an
# ordinary clean reap. The WIP was never actually durable anywhere but a local
# branch ref in the rig's own object DB — exactly the state this feature exists
# to prevent. Snapshotting into a scratch index instead means a failed push
# leaves the worktree in its EXACT original state (git status --porcelain
# byte-for-byte unchanged) — dirty stays dirty, so the plain non-force remove
# refuses again next sweep too, and preserve is retried rather than silently
# skipped. (A plain `git stash create` was considered first — it shares the
# no-mutation property but was verified empirically to silently drop untracked
# files from the snapshot, which would lose newly-created WIP files even on a
# successful preserve; the scratch-index approach captures modified, untracked,
# and deleted paths alike.)
# Returns 0 (reaped) or 1 (kept/refused — always logged, never silent).
preserve_and_reap_dirty() {
  local repo="$1" wt="$2" br="$3" age="$4" label sha tag_ref preserved_to parent tmp_index tree ignored_path
  git -C "$wt" status --porcelain 2>/dev/null | grep -q . || return 1   # not actually dirty — leave to normal skip
  parent="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  tmp_index="$(mktemp)" || return 1
  # Stage the full current state (modified + untracked + deleted) into a SCRATCH
  # index via GIT_INDEX_FILE — the real index and working tree are never touched,
  # so a failed push below leaves nothing to undo.
  GIT_INDEX_FILE="$tmp_index" git -C "$wt" read-tree HEAD >/dev/null 2>&1
  GIT_INDEX_FILE="$tmp_index" git -C "$wt" add -A >/dev/null 2>&1
  # ga-0j2zc: `add -A` only skips .gitignore for NEW/untracked paths — a path that was
  # tracked BEFORE it became gitignored (e.g. a vendorized/materialized dir like
  # whatsapp_automation's .gc/) still has its on-disk drift (or deletion) swept in as a
  # "modification", because gitignore never un-tracks an already-tracked file. Reported
  # live: a preserve commit carried 166 FILES / 24,021 lines of incidental .gc/ drift
  # into a crew branch — none of it the crew's own work. Pin every currently-ignored
  # tracked path back to its HEAD blob in the scratch index (index-only — the real
  # index/working tree are untouched) so only genuine crew changes — new files, and
  # modifications/deletions of paths NOT matching the current .gitignore — survive
  # into the preserve commit.
  while IFS= read -r ignored_path; do
    [ -n "$ignored_path" ] || continue
    GIT_INDEX_FILE="$tmp_index" git -C "$wt" reset -q HEAD -- "$ignored_path" 2>/dev/null
  done < <(git -C "$wt" ls-files -ci --exclude-standard 2>/dev/null)
  tree="$(GIT_INDEX_FILE="$tmp_index" git -C "$wt" write-tree 2>/dev/null)"
  rm -f "$tmp_index"
  [ -n "$tree" ] || return 1
  sha="$(git -C "$wt" commit-tree "$tree" -p "$parent" -m "worktree-reaper: preserve before reap (aged+dirty, age=${age}h)" 2>/dev/null)"
  [ -n "$sha" ] || return 1
  label="$(basename "$wt")"
  if [ -n "$br" ] && git -C "$repo" push origin "${sha}:refs/heads/${br}" >/dev/null 2>&1; then
    preserved_to="refs/heads/${br}"
  else
    tag_ref="refs/reclaimed/${label}/${sha}"
    if git -C "$repo" push origin "${sha}:${tag_ref}" >/dev/null 2>&1; then
      preserved_to="$tag_ref"
    else
      printf '{"ts":"%s","event":"preserve_failed_dirty_kept","repo":"%s","wt":"%s","branch":"%s","age_h":%s}\n' \
        "$(ts)" "$(basename "$repo")" "$label" "$br" "$age" >> "$LOG" 2>/dev/null
      return 1
    fi
  fi
  if git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
    # The worktree is gone, so $br is no longer checked out anywhere — safe to
    # force it to the confirmed-durable snapshot now (git refuses this while a
    # worktree still has the branch checked out). Keeps the local branch in
    # sync with what was actually pushed, so delete_merged_local_branch's
    # merged-into-origin/main check below sees the true (unmerged) state
    # instead of a branch that never moved past its pre-WIP start point.
    [ -n "$br" ] && git -C "$repo" branch -f "$br" "$sha" >/dev/null 2>&1
    printf '{"ts":"%s","event":"reaped_dirty_preserved","repo":"%s","wt":"%s","branch":"%s","age_h":%s,"preserved_to":"%s","mode":"%s"}\n' \
      "$(ts)" "$(basename "$repo")" "$label" "$br" "$age" "$preserved_to" "$mode" >> "$LOG" 2>/dev/null
    delete_merged_local_branch "$repo" "$br"
    return 0
  fi
  printf '{"ts":"%s","event":"preserve_ok_reap_failed","repo":"%s","wt":"%s","branch":"%s","age_h":%s,"preserved_to":"%s"}\n' \
    "$(ts)" "$(basename "$repo")" "$label" "$br" "$age" "$preserved_to" >> "$LOG" 2>/dev/null
  return 1
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
        local now_s; now_s=$(date +%s)
        local mtime_s; mtime_s=$(stat -f %m "$wt" 2>/dev/null || echo 0)
        local age=$(( (now_s - mtime_s) / 3600 ))
        local age_min=$(( (now_s - mtime_s) / 60 ))
        # ga-t14of: a branch already merged into origin/<default> bypasses the age gate —
        # the work is durably in main, so waiting out STALE_HOURS just for the worktree to
        # catch up buys nothing but disk. Gated on MERGED_MIN_AGE_MIN (not just "merged")
        # so a worktree that hasn't diverged from main YET — trivially "merged" because
        # nothing has happened there — isn't reaped out from under an agent that hasn't
        # started. Still must clear _worktree_in_use below either way.
        local merged=0
        if [ "$age_min" -ge "$MERGED_MIN_AGE_MIN" ] && _worktree_head_merged "$repo" "$wt"; then merged=1; fi
        if [ "$age" -le "$gate_hours" ] 2>/dev/null && [ "$merged" != "1" ]; then kept=$((kept+1)); wt=""; br=""; lock=""; continue; fi
        if [ "$merged" = "1" ] && _worktree_in_use "$wt"; then
          kept=$((kept+1))
          printf '{"ts":"%s","event":"kept_merged_in_use","repo":"%s","wt":"%s","branch":"%s","age_h":%s}\n' "$(ts)" "$(basename "$repo")" "$(basename "$wt")" "$br" "$age" >> "$LOG" 2>/dev/null
          wt=""; br=""; lock=""; continue
        fi
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
        elif preserve_and_reap_dirty "$repo" "$wt" "$br" "$age"; then
          pool_reaped=$((pool_reaped+1)); preserved_dirty=$((preserved_dirty+1))
        else
          skipped_dirty=$((skipped_dirty+1))   # dirty/locked/live WIP, or preserve failed → leave it
        fi
        wt=""; br=""; lock=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  [ "$ENABLED" = "1" ] && git -C "$repo" worktree prune 2>/dev/null
}

# ── 1. legacy path-glob scan of known .gc-worktrees roots (town repo) ─────────────
# ga-t14of: a branch already merged into origin/main bypasses the age gate below (the
# work is durably in main — waiting out STALE_HOURS buys nothing) but must still clear
# _worktree_in_use before being reaped. Loops over WT_DIRS (plural — see its definition
# above for why one root was never enough).
for WT_DIR in $WT_DIRS; do
  [ -d "$WT_DIR" ] || continue
  for d in "$WT_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    # ga-t14of: realpath-normalize — unlike section 2's $wt (already resolved by git's
    # own porcelain output), $d here comes straight from a filesystem glob. lsof (and
    # git) report the OS-resolved path, so an un-normalized $d would silently mismatch
    # against _worktree_in_use on any symlinked $GT, false-negativing "in use" into
    # "free". No-op on this town's actual path (/Users/athos/gt has no symlink hop); only
    # matters for symlinked deployments and the selftest's mktemp (/var → /private/var).
    d="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    now_s=$(date +%s)
    mtime_s=$(stat -f %m "$d")
    age=$(( (now_s - mtime_s) / 3600 ))
    age_min=$(( (now_s - mtime_s) / 60 ))
    merged=0
    # ga-t14of: gated on MERGED_MIN_AGE_MIN — see reap_pool_worktrees for why a bare
    # "merged" check alone would reap a just-created, not-yet-touched worktree too.
    if [ "$age_min" -ge "$MERGED_MIN_AGE_MIN" ] && _worktree_head_merged "$GT" "$d"; then merged=1; fi
    if [ "$age" -le "$gate_hours" ] && [ "$merged" != "1" ]; then kept=$((kept+1)); continue; fi
    if [ "$merged" = "1" ] && _worktree_in_use "$d"; then
      kept=$((kept+1))
      printf '{"ts":"%s","event":"kept_merged_in_use","wt":"%s","age_h":%s}\n' "$(ts)" "$(basename "$d")" "$age" >> "$LOG" 2>/dev/null
      continue
    fi
    if [ "$ENABLED" != "1" ]; then
      printf '{"ts":"%s","event":"would_reap","wt":"%s","age_h":%s,"mode":"%s","merged":%s}\n' "$(ts)" "$(basename "$d")" "$age" "$mode" "$merged" >> "$LOG" 2>/dev/null
      continue
    fi
    # no --force: a worktree with uncommitted WIP (a live build) is REFUSED → protected.
    if git -C "$GT" worktree remove "$d" 2>/dev/null; then
      reaped=$((reaped+1))
      printf '{"ts":"%s","event":"reaped","wt":"%s","age_h":%s,"mode":"%s","merged":%s}\n' "$(ts)" "$(basename "$d")" "$age" "$mode" "$merged" >> "$LOG" 2>/dev/null
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
done
[ "$ENABLED" = "1" ] && git -C "$GT" worktree prune 2>/dev/null

# ── 2. ga-pdrij: per-RIG scan for POOL worktrees ──────────────────────────────────
# ONLY the rig repos (whatsapp_automation, property_scrapers, …) — NOT the town repo
# $GT (nor its no-.git-of-its-own subdirectory .gascity-gastown-hq — see WT_DIRS above),
# whose worktrees (.gc-worktrees gate-runs) are already handled by loop 1; running
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
  # wa-bptki (2026-08-02): a named crew member's clone (<rig>/crew/oracle, crew/mila, …)
  # is its OWN independent repo — a real `git clone` with its own .git DIRECTORY and its
  # own `origin` remote — not a linked worktree of $_repo. `git -C $_repo worktree list`
  # therefore CANNOT see worktrees registered under crew/<name>/.claude/worktrees/: they
  # live in crew/<name>'s OWN worktree registry, invisible from $_repo. Confirmed: zero
  # such entries in weeks of sweep logs while $_repo's own worker-wa-* worktrees reaped
  # normally — 94 agent worktrees / 5.9G accumulated over 3-7 weeks across 5 crew clones
  # in whatsapp_automation alone before this was caught. Recurse into each rig's crew/*/
  # subdirs and run the SAME reap on any that are a repo root in their own right — a
  # linked worktree's .git is always a FILE (pointer), only a real clone/init has a .git
  # DIRECTORY, so this also naturally skips crew/worker, which has no .git of its own at
  # all (shares the rig's) and is never mistaken for an independent repo.
  if [ -d "$_repo/crew" ]; then
    for _crew in "$_repo/crew"/*/; do
      _crew="${_crew%/}"
      [ -d "$_crew/.git" ] || continue
      reap_pool_worktrees "$_crew"
    done
  fi
done

printf '{"ts":"%s","event":"sweep","mode":"%s","free_gb":%s,"gate_hours":%s,"reaped":%s,"pool_reaped":%s,"zombie_reaped":%s,"preserved_dirty":%s,"branches_deleted":%s,"skipped_dirty":%s,"kept":%s}\n' \
  "$(ts)" "$mode" "$free_gb" "$gate_hours" "$reaped" "$pool_reaped" "$zombie_reaped" "$preserved_dirty" "$branches_deleted" "$skipped_dirty" "$kept" >> "$LOG" 2>/dev/null
exit 0
