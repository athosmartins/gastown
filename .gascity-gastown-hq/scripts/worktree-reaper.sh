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
# gate protects anything touched recently (ga-m5i7e6: a tree's age is its FRESHEST sign of life — index, HEAD commit, any
# file inside — not its root directory's mtime, and a tree a live process has its cwd or an open file in is never removed).
# Pressure mode lowers the age gate when disk is genuinely low, but only MERGED trees go under it: an unmerged tree is kept
# and logged with its size (kept_pressure_unmerged). Branch deletion is merged-only. Kill switch: WORKTREE_REAPER_ENABLED=0.
# The one exception to "WITHOUT --force" is a LOCKED worktree (`remove -f -f`); it is reaped only
# under the LOCK CONTRACT stated at ZOMBIE-LOCK DETECTION below, never because of its age alone.
# A second, narrower exception (ga-he2c1u, town .gc-worktrees roots only): an UNLOCKED tree dirty with nothing but generated
# files (GENERATED_RE: caches, .gc/system, run markers) whose HEAD is already in origin/<default>, with every bead it is
# named for CLOSED long enough and no process in it, is removed with a single --force (_reap_dirty_generated_only).
# Any other dirt — a modified tracked file, an untracked source file — still refuses, as before.
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
# ga-m5i7e6: how old a tree is = its FRESHEST sign of life (see _wt_fresh_epoch), not the mtime of its root directory, which
# only moves when an entry is added or removed at the TOP level (a battery writing under pesquisa/ never touches it: six
# traco-bim work trees, one with an agent inside, were reaped at "13-14 h"). Only 0 = the old rule, the directory mtime alone.
ACTIVITY_SCAN="${WORKTREE_REAPER_ACTIVITY_SCAN:-1}"
# ga-m5i7e6: under disk pressure the age gate used to drop to PRESSURE_HOURS for EVERY tree. Now pressure removes only
# MERGED trees (their work is in main); an unmerged one is kept and logged with its size. Only 1 = the old behavior.
PRESSURE_REAP_UNMERGED="${WORKTREE_REAPER_PRESSURE_REAP_UNMERGED:-0}"
PRESSURE_SIZE_BUDGET=20     # du runs for at most this many pressure keeps per sweep (a huge tree costs seconds); the rest log size_kb null
# vazio/falhou → treated as GNU stat (-c %Y); if that is wrong too, every freshness read fails and every tree is KEPT
case "$(stat -f %m / 2>/dev/null)" in ''|*[!0-9]*) _STAT_BSD=0 ;; *) _STAT_BSD=1 ;; esac
# ── zombie-lock reaping (wa-8y45): a worktree LOCKED by a stuck/ancient agent ─────
ZOMBIE_LOCK_ENABLED="${WORKTREE_REAPER_ZOMBIE_LOCK_ENABLED:-1}"  # 0 = old behavior (skip ALL locked)
ZOMBIE_HOURS="${WORKTREE_REAPER_ZOMBIE_HOURS:-48}"               # alive holder must EXCEED this AND be idle
case "$ZOMBIE_HOURS" in ''|*[!0-9]*) ZOMBIE_HOURS=48 ;; esac
ZOMBIE_MAX_CPU="${WORKTREE_REAPER_ZOMBIE_MAX_CPU:-5}"            # 'idle' = recent %cpu <= this (percent)
ZOMBIE_MAX_CPU_X10="$(printf '%s' "$ZOMBIE_MAX_CPU" | awk '{gsub(/,/,"."); printf "%d", ($1*10)+0.5}')"
case "$ZOMBIE_MAX_CPU_X10" in ''|*[!0-9]*) ZOMBIE_MAX_CPU_X10=50 ;; esac
KILL_ZOMBIE="${WORKTREE_REAPER_KILL_ZOMBIE:-0}"                  # SIGTERM the confirmed zombie pid (guarded; default OFF)
# ga-vs6shu: bound (seconds) on the ONE `gc session list` fetch per sweep. It is fetched once,
# not per lock, so the bound can afford to be generous — a wedged gc/Dolt costs one bounded
# wait per sweep and the locks are KEPT (see _session_list_ensure), never reaped on a guess.
# Measured 25/09 at load ~54: the call took ~10s and timed out 2 of 3 times at a 10s bound.
SESSION_LIST_TIMEOUT="${WORKTREE_REAPER_SESSION_LIST_TIMEOUT:-60}"
case "$SESSION_LIST_TIMEOUT" in ''|*[!0-9]*) SESSION_LIST_TIMEOUT=60 ;; esac
[ "$SESSION_LIST_TIMEOUT" -ge 1 ] || SESSION_LIST_TIMEOUT=60      # timeout(1) treats 0 as "no bound at all"
# ... plus a KILL grace (seconds). `timeout N gc` only sends TERM, so a gc that ignores TERM would hold the
# whole sweep past N for as long as it likes; `timeout -k G N gc` follows with KILL after G more seconds, so the
# real bound is N+G and the call reports 124 (TERM was enough) or 137 (it had to be KILLed).
SESSION_LIST_KILL_GRACE="${WORKTREE_REAPER_SESSION_LIST_KILL_GRACE:-5}"
case "$SESSION_LIST_KILL_GRACE" in ''|*[!0-9]*) SESSION_LIST_KILL_GRACE=5 ;; esac
[ "$SESSION_LIST_KILL_GRACE" -ge 1 ] || SESSION_LIST_KILL_GRACE=5  # `-k 0` means "never KILL" in timeout(1)
# ga-yw18yk: the BEAD-CLOSED proof (see _bead_closed_proof). A bead must have been closed for at least this many
# hours before a tree that names it may be reaped on that alone: the gate-fix rounds of a bead run for hours after
# it first closes, and the worker that built it can still be finishing. 6 is the youngest tree in the measured leak.
BEAD_CLOSED_HOURS="${WORKTREE_REAPER_CLOSED_BEAD_HOURS:-6}"
case "$BEAD_CLOSED_HOURS" in ''|*[!0-9]*) BEAD_CLOSED_HOURS=6 ;; esac
# ... and the bound (seconds) on each `bd list` that proof costs (TERM at N, KILL 5s later). A lookup that times out
# is "could not tell", so the tree is KEPT — never reaped on a guess — and the sweep is held for at most this long.
BEAD_LOOKUP_TIMEOUT="${WORKTREE_REAPER_BEAD_LOOKUP_TIMEOUT:-20}"
case "$BEAD_LOOKUP_TIMEOUT" in ''|*[!0-9]*) BEAD_LOOKUP_TIMEOUT=20 ;; esac
[ "$BEAD_LOOKUP_TIMEOUT" -ge 1 ] || BEAD_LOOKUP_TIMEOUT=20          # timeout(1) treats 0 as "no bound at all"
BEAD_LOOKUP_KILL_GRACE=5
# ga-he2c1u: what a worktree accretes by itself and nobody wrote — bytecode and test caches, macOS litter, the `gc`
# runtime materialisation (.gc/system, .gc/site.toml) and the run markers a selftest leaves at the tree root (.pce-*).
# Matched (ERE) against the path `git status` prints, relative to the repo root. A tree dirty with NOTHING BUT these
# may be removed with --force (see _reap_dirty_generated_only). The city's own untracked pack.toml, which the tree
# carries a copy of, counts only while it is byte-identical to the city's (checked at the call, not matched here).
GENERATED_RE='(^|/)(__pycache__|\.pytest_cache)(/|$)|\.pyc$|(^|/)\.DS_Store$|(^|/)\.gc/(system/|site\.toml$)|^\.pce-[A-Za-z0-9._-]+$'
[ -z "${WORKTREE_REAPER_GENERATED_RE:-}" ] || GENERATED_RE="$WORKTREE_REAPER_GENERATED_RE"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _json_esc <text> — make free text safe to interpolate into a hand-built JSON log line
# (escape \ and ", flatten control bytes). ga-vs6shu (gate ga-wpdmj6): a lock REASON is free
# text, and `git worktree list --porcelain` hands it back C-quoted — a reason holding a quote
# or a backslash arrives as `"fix \"x\" \\ y"`. Interpolated raw, that wrote
# `"reason":""fix \"x\" \\ y""` — invalid JSON that made `jq -s` die on that line. The
# kept_locked_unparseable event fires for EVERY kept lock on EVERY sweep, so one such reason
# poisoned the whole file for every later reader. Byte-wise (LC_ALL=C) so a stray non-UTF-8
# byte cannot make tr/sed themselves fail.
_json_esc() {
  printf '%s' "$1" | LC_ALL=C tr '\000-\037' ' ' | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _log_lock_event <event> <repo> <wt> <br> <age_h> <label> [<verdict> [<reason>]] — one JSON
# line for a locked-worktree outcome. EVERY free-text field goes through _json_esc; add new
# fields here, never as a raw printf, so the escaping cannot be forgotten at one call site.
_log_lock_event() {
  local ev="$1" repo="$2" wt="$3" br="$4" age="$5" label="$6" verdict="${7-}" reason="${8-}" line
  case "$age" in ''|*[!0-9-]*) age=null ;; esac
  line="{\"ts\":\"$(ts)\",\"event\":\"$ev\",\"repo\":\"$(_json_esc "$(basename "$repo")")\",\"wt\":\"$(_json_esc "$(basename "$wt")")\",\"branch\":\"$(_json_esc "$br")\",\"age_h\":$age"
  [ -n "$verdict" ] && line="$line,\"verdict\":\"$(_json_esc "$verdict")\""
  [ -n "$reason" ]  && line="$line,\"reason\":\"$(_json_esc "$reason")\""
  printf '%s,"label":"%s"}\n' "$line" "$(_json_esc "$label")" >> "$LOG" 2>/dev/null
}

free_gb=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
[ -z "$free_gb" ] && free_gb=99
gate_hours="$STALE_HOURS"
mode="normal"
if [ "$free_gb" -lt "$PRESSURE_FREE_GB" ] 2>/dev/null; then gate_hours="$PRESSURE_HOURS"; mode="pressure"; fi

reaped=0; skipped_dirty=0; kept=0; branches_deleted=0; pool_reaped=0; zombie_reaped=0; preserved_dirty=0
kept_session_list_unavailable=0   # ga-vs6shu: locks KEPT only because the session list could not be fetched
_ZL_VERDICT=""                    # ga-vs6shu: reap_zombie_locked's verdict, handed to its caller (never recomputed)
bead_lookup_failed=0              # ga-yw18yk: bead lookups that could not be answered (each leaves its tree KEPT)
_BC_FAILED_SEEN=""                # ga-yw18yk: repos whose failed lookup is already logged this sweep (one event per repo)
_BC_PROOF_IDS=""                  # ga-yw18yk: _bead_closed_proof's answer, handed to its caller: the closed bead ids it relied on
_BC_PROOF_FIRST=""                # ... and the first of them (the label of a rescue/ branch)
_BC_ROWS=""; _BC_FOUND_IDS=""; _BC_FOUND_PFX=""   # ga-yw18yk: _bead_ask's working set while one proof is being decided
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
  local repo="$1" br="$2" proof="${3-}" why="merged_orphan"
  [ -n "$br" ] || return 0
  case "$br" in crew/*) : ;; *) return 0 ;; esac   # only crew/* build branches
  command -v git >/dev/null 2>&1 || return 0
  local def; def="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -n "$def" ] || def="main"
  # merged check against origin/<default>; any uncertainty → do NOT delete.
  git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$def" >/dev/null 2>&1 || return 0
  # ga-1md7na: a REBASED branch is never an ancestor of main even when all of it shipped. A caller that
  # reaped the tree on the patch-equivalence proof passes proof=patch_equivalent, and the BRANCH itself (not
  # the removed tree's HEAD) is re-proven the same way here, at the moment it is deleted. No proof arg = the
  # ancestry check only, exactly as before.
  local delivered=0
  if git -C "$repo" branch --merged "refs/remotes/origin/$def" 2>/dev/null | sed 's/^[* ] *//' | grep -x "$br" >/dev/null; then
    delivered=1
  elif [ "$proof" = "patch_equivalent" ] && _ref_patch_equivalent "$repo" "refs/heads/$br"; then
    delivered=1; why="patch_equivalent_orphan"
  fi
  if [ "$delivered" = "1" ]; then
    if [ "$ENABLED" = "1" ]; then
      git -C "$repo" branch -D "$br" >/dev/null 2>&1 && {
        branches_deleted=$((branches_deleted+1))
        printf '{"ts":"%s","event":"branch_deleted","repo":"%s","branch":"%s","reason":"%s"}\n' "$(ts)" "$(basename "$repo")" "$br" "$why" >> "$LOG" 2>/dev/null
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

# ── _ref_patch_equivalent <repo> <ref> — ga-1md7na: the SECOND proof that <ref>'s content is
# already in origin/<default>: <ref> carries no merge commit, and every commit <ref> has that
# origin/<default> lacks is there anyway as an equivalent PATCH (`git cherry`: only '-' lines).
# The gate rebases/re-anchors a branch
# before merging, so a delivered branch's HEAD is never an ancestor of main — the ancestry proof
# in _worktree_head_merged is false for exactly the trees whose work shipped (measured 05/10: 27
# locked worktrees of CLOSED beads, all `git cherry` '-' only, none reapable).
# `git cherry` NEVER reports MERGE commits, so on its own a '-'-only answer says nothing about
# them: a branch whose tip is a merge carrying content of its own reads "all shipped" when only
# its non-merge commits did (gate FAIL ga-jxkpdr). Merge commits are therefore NOT examined here,
# and ANY merge commit in origin/<default>..<ref> blocks the proof — before cherry is consulted.
# That keeps even a clean merge of an older main (a false keep: the tree stays, nothing is lost).
# Three states, and only the first is "yes": proven (the merge check answered AND found none, and
# cherry exited 0 AND every output line is a '- <sha>' line, or there is no output because there
# is nothing ahead) / NOT proven because a merge commit is present or a commit is '+' (real work
# main lacks) / NOT proven because a check could not answer (nonzero exit — even if it printed
# '-' lines before dying — or a line that is not cherry's format). Never a guess, never "empty
# output = fine" without the exit code. A squash-merge is a different patch, so it reads '+' here
# and the tree is KEPT — the conservative direction.
# <ref> is any commit-ish; an empty one (the caller's `rev-parse HEAD` failed) is "cannot tell".
_ref_patch_equivalent() {
  local repo="$1" ref="${2-}" def out rc line merges
  local re='^- [0-9a-f]{40,64}$'
  [ -n "$ref" ] || return 1
  def="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -n "$def" ] || def="main"
  git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$def" >/dev/null 2>&1 || return 1
  # The merge check comes first: its exit code and its output are separate facts (a failed rev-list prints
  # nothing, which must never read as "no merges"). Any output, or any failure, is NOT proven.
  merges="$(git -C "$repo" rev-list --merges "refs/remotes/origin/$def..$ref" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -z "$merges" ] || return 1
  out="$(git -C "$repo" cherry "refs/remotes/origin/$def" "$ref" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" =~ $re ]] || return 1
  done <<< "$out"
  return 0
}

# ── _worktree_in_use <path> — ga-t14of: true iff a live process has its CWD (ga-m5i7e6: or any
# open file) at the worktree path itself or inside it. Defense-in-depth beyond git's own dirty-check: a
# git-CLEAN worktree can still be someone's live shell/build cwd, and removing it out
# from under that process breaks it even though no file content is lost — the exact
# failure mode ga-t14of's acceptance criteria calls out ("worktree em uso não é
# removido, mesmo que a branch esteja mergeada"). ga-m5i7e6: asked before EVERY removal (see _keep_unsafe
# and the lock-contract helpers), where it used to gate the merged-branch fast path only; the age gate
# is not a substitute, a busy tree can look old. lsof unavailable/failing → fail SAFE (treat as
# in-use; never guess a worktree is free). Seam: WORKTREE_REAPER_FAKE_LSOF=<file>, one
# absolute path (a cwd or an open file) per line, for a hermetic selftest.
_worktree_in_use() {
  local path="$1"
  if [ -n "${WORKTREE_REAPER_FAKE_LSOF:-}" ]; then
    [ -f "$WORKTREE_REAPER_FAKE_LSOF" ] || return 1
    awk -v p="$path" '{ if ($0 == p || index($0, p "/") == 1) { found=1; exit } } END { exit(found ? 0 : 1) }' "$WORKTREE_REAPER_FAKE_LSOF"
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  # gate-feedback (fix-attempt 1): piping lsof directly into awk let lsof's OWN exit
  # code silently override awk's correctly-computed found/not-found result — under
  # this script's `set -o pipefail`, the pipeline reports the last NONZERO exit among
  # its stages, and lsof frequently exits nonzero for reasons unrelated to our answer
  # (e.g. permission-denied probing an unrelated process it can't inspect) even while
  # its stdout already contains the match awk needs. Empirically confirmed: a pipeline
  # shaped exactly like this — lsof exiting 1, awk exiting 0 after finding its match —
  # reports the pipeline as failed, inverting a real "found" into a returned "not
  # found". Capture lsof's output via command substitution FIRST (which discards its
  # exit code entirely — deliberately: it is not a trustworthy signal here) and reason
  # only about what it printed:
  #   - no output at all, for ANY reason (missing perms, transient error, version
  #     skew, or genuinely nothing) → fail SAFE (treat as in-use; never conflate
  #     "couldn't tell" with "confirmed free" — they are not the same value);
  #   - output exists → lsof is demonstrably working, so trust awk's match/no-match
  #     verdict on what it actually printed, regardless of lsof's own exit code.
  # ga-m5i7e6: every open file counts, not only a cwd (-Fn lists the cwd, the executable, mapped files and each fd of every
  # process): a battery whose cwd is elsewhere but writes its output inside the tree is just as much "in use".
  # vazio → "cannot tell" = in use (below); falhou → same, its exit code is not consulted at all
  local lsof_out
  lsof_out="$(lsof -Fn 2>/dev/null)"
  [ -n "$lsof_out" ] || return 0
  printf '%s\n' "$lsof_out" | awk -v p="$path" '
    /^n/ { d = substr($0, 2); if (d == p || index(d, p "/") == 1) { found=1; exit } }
    END { exit(found ? 0 : 1) }
  '
}

# ── _mtime_of <path> — ga-m5i7e6: epoch mtime of a path. BSD `stat -f %m`; GNU stat answers `-f` with filesystem info, so
# anything that is not all digits falls back to `stat -c %Y`. Prints nothing and returns 1 when neither reads it: the caller
# decides what "unknown" means.
_mtime_of() {
  local v
  # vazio/falhou → try the GNU form; neither answers → rc 1 and the caller KEEPS the tree
  v="$(stat -f %m "$1" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) v="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

# ── _wt_fresh_epoch <wt> <now_s> — ga-m5i7e6: the newest sign of life of a worktree, as an epoch: its root directory's mtime,
# its INDEX (every add/commit/checkout moves it), its HEAD commit, and any entry inside modified within the gate window
# (`find -mmin`, the .git pointer pruned). Returns 1 when the directory's own mtime or the walk inside cannot be read: the
# caller KEEPS the tree, an unreadable tree is not an old tree (an unreadable index or HEAD only adds no signal; the others
# still count). Only ACTIVITY_SCAN=0 answers with the directory mtime alone (the old rule); any other value scans.
_wt_fresh_epoch() {
  local wt="$1" now_s="$2" best t idx win inside rc
  best="$(_mtime_of "$wt")" || return 1
  [ "$ACTIVITY_SCAN" != "0" ] || { printf '%s' "$best"; return 0; }
  # vazio → no index file adds no signal; falhou → same, the other signals still count
  idx="$(git -C "$wt" rev-parse --git-path index 2>/dev/null)"
  if [ -n "$idx" ]; then
    case "$idx" in /*) : ;; *) idx="$wt/$idx" ;; esac
    t="$(_mtime_of "$idx")" && [ "$t" -gt "$best" ] && best="$t"
  fi
  # vazio/falhou → an unreadable HEAD adds no signal (the index and the files inside still count)
  t="$(git -C "$wt" log -1 --format=%ct HEAD 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) : ;; *) [ "$t" -gt "$best" ] && best="$t" ;; esac
  win=$(( gate_hours * 60 )); [ "$win" -ge "$MERGED_MIN_AGE_MIN" ] || win="$MERGED_MIN_AGE_MIN"; win=$(( win + 1 ))
  # already younger than every threshold: the walk below could not change a decision
  [ $(( now_s - best )) -lt $(( MERGED_MIN_AGE_MIN * 60 )) ] && { printf '%s' "$best"; return 0; }
  # vazio → nothing inside changed within the window; falhou (rc != 0: an unreadable dir, a file that vanished mid-walk) → unknown, the tree is KEPT
  if [ "$_STAT_BSD" = "1" ]; then
    inside="$(find "$wt" -path "$wt/.git" -prune -o -mmin "-$win" -exec stat -f %m {} + 2>/dev/null)"; rc=$?
  else
    inside="$(find "$wt" -path "$wt/.git" -prune -o -mmin "-$win" -exec stat -c %Y {} + 2>/dev/null)"; rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  t="$(printf '%s\n' "$inside" | sort -rn | head -n 1)"
  case "$t" in ''|*[!0-9]*) : ;; *) [ "$t" -gt "$best" ] && best="$t" ;; esac
  printf '%s' "$best"
}

# ── _wt_lock_reason <repo> <wt> — ga-m5i7e6: the lock reason `git worktree list --porcelain` gives <wt> ("(no reason)" for a
# bare lock); empty = not locked, or git itself failed (then the caller treats the tree as unlocked and applies _keep_unsafe).
# That collapse is safe only because the plain `worktree remove` that follows is refused by git for a locked tree (`-f -f` is
# used nowhere outside the lock contract): a wrong "unlocked" costs one extra in-use/pressure check, never a removal.
_wt_lock_reason() {
  # vazio → not locked: _keep_unsafe runs, then the plain remove; falhou → the same, and git still refuses a locked tree there
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v p="$2" '$1=="worktree"{c=$2} $1=="locked"{ if(c==p){ $1=""; sub(/^ /,""); if ($0=="") $0="(no reason)"; print; exit } }'
}

# ── _keep_unsafe <repo> <wt> <br> <age_h> <merged> — ga-m5i7e6: the checks every tree passes before the plain remove and the
# dirty-preserve force-remove (callers skip it for a LOCKED unmerged tree: the lock contract asks _worktree_in_use itself, and
# reap_zombie_locked has its own check). 0 = KEEP it (the event is logged here), 1 = go on.
#   (1) a live process has its cwd, its executable or any open file inside → kept_in_use (kept_merged_in_use when the tree is
#       merged: the name older scenarios and dashboards know), merged or not;
#   (2) disk pressure removes only MERGED trees (PRESSURE_REAP_UNMERGED=1 restores the old rule): an unmerged one is
#       kept_pressure_unmerged with its size, so what pressure no longer takes is visible, not silent. Literal reading of the
#       bead's decision: an unmerged tree idle past STALE_HOURS is kept under pressure too, though normal mode would reap it
#       (its age_h on the event says which); a disk that stays low for days therefore stops reclaiming unmerged trees.
_keep_unsafe() {
  local repo="$1" wt="$2" br="$3" age="$4" merged="$5" ev kb
  if _worktree_in_use "$wt"; then
    ev="kept_in_use"; [ "$merged" = "1" ] && ev="kept_merged_in_use"
    printf '{"ts":"%s","event":"%s","repo":"%s","wt":"%s","branch":"%s","age_h":%s,"mode":"%s"}\n' \
      "$(ts)" "$ev" "$(_json_esc "$(basename "$repo")")" "$(_json_esc "$(basename "$wt")")" "$(_json_esc "$br")" "$age" "$mode" >> "$LOG" 2>/dev/null
    return 0
  fi
  if [ "$mode" = "pressure" ] && [ "$merged" != "1" ] && [ "$PRESSURE_REAP_UNMERGED" != "1" ]; then
    kb=null
    if [ "$PRESSURE_SIZE_BUDGET" -gt 0 ]; then
      PRESSURE_SIZE_BUDGET=$((PRESSURE_SIZE_BUDGET-1))
      # vazio/falhou → size_kb null: a log field only, the tree is kept either way
      kb="$(du -sk "$wt" 2>/dev/null | awk '{print $1}')"; case "$kb" in ''|*[!0-9]*) kb=null ;; esac
    fi
    printf '{"ts":"%s","event":"kept_pressure_unmerged","repo":"%s","wt":"%s","branch":"%s","age_h":%s,"size_kb":%s,"reason":"disk pressure removes only merged trees"}\n' \
      "$(ts)" "$(_json_esc "$(basename "$repo")")" "$(_json_esc "$(basename "$wt")")" "$(_json_esc "$br")" "$age" "$kb" >> "$LOG" 2>/dev/null
    return 0
  fi
  return 1
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
  git -C "$wt" status --porcelain 2>/dev/null | grep . >/dev/null || return 1   # not actually dirty — leave to normal skip
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
# reaper does not take a lock lightly (a live agent may be mid-build). But a STUCK agent —
# dead, or alive-but-ancient-and-idle — holds that lock forever, pinning a stale conflicted
# worktree that blocks re-dispatch (wa-8y45: pid 42047 alive 4d7h @ 0.3% CPU pinned a P1 for
# 4 days). These helpers decide whether a lock holder is a ZOMBIE so its worktree can be
# unlock+reaped. The PID path is CONSERVATIVE by construction: any doubt in it (can't probe the
# process, holder is young, or shows recent CPU) → NOT a zombie, and it never reaps on that doubt.
# A reason with no pid at all skips that path and is looked up by SESSION name instead. What becomes
# of a lock that is not a pid-confirmed zombie is decided in ONE place: the LOCK CONTRACT below.
# Process probes are seam-injectable (WORKTREE_REAPER_FAKE_*) so the selftest is hermetic.
#
# LOCK CONTRACT (ga-vs6shu) — the one statement of it; the comments at each decision point refer here.
# A lock is never a reason to REAP, and it is not, on its own, the protection either:
#   1. a "pid N" in the reason: pid-confirmed ZOMBIE (dead, or alive > ZOMBIE_HOURS and idle) → unlock + reap;
#      pid-confirmed LIVE (young, or busy) → KEPT (kept_locked_live).
#   2. no pid: the holder is looked up by session name (ONE `gc session list` per sweep):
#        list unavailable → KEPT (kept_locked_session_list_unavailable / kept_locked_unknown);
#        a named session is alive AND its work_dir is this tree → KEPT (kept_locked_live);
#        otherwise ("unparseable") → not reaped on the lock's say-so, but reaped when the TREE proves itself safe
#        without the lock's help: its content already in origin/<default> + git status clean (rc 0 AND empty) + no
#        live process has it as cwd + older than the age gate. "Already in origin/<default>" has two proofs
#        (ga-1md7na): HEAD is an ancestor of it (reaped_locked_unparseable_safe), or — a branch the gate rebased,
#        whose HEAD never is one — it carries NO merge commit (`git cherry` cannot see them, so any one blocks the
#        proof) and every commit it carries is there as an equivalent patch: `git cherry` exited 0 and printed only
#        '-' lines (reaped_locked_unparseable_patch_equivalent; its local branch goes under that same proof). A
#        merge check or a `git cherry` that fails or prints anything else proves nothing. A branch that never
#        shipped has a THIRD proof, which says the work is OVER, not that it shipped (ga-yw18yk): every bead the
#        tree's directory/branch is named for is CLOSED, for at least BEAD_CLOSED_HOURS, and no rebase/merge/
#        cherry-pick is under way (reaped_locked_unparseable_bead_closed; see _bead_closed_proof). On that proof the
#        tree goes and the BRANCH STAYS, and a detached HEAD is first parked on rescue/<bead>-<sha9>. A bead that
#        is open, unreadable or not found, or a lookup that fails, proves nothing. Any proof missing →
#        KEPT (kept_locked_unparseable). Ignored files are not part of "clean" and go with the tree.
#   3. any other verdict, or none (empty): KEPT (kept_locked_unrecognized_verdict). Only the exact verdict
#      "unparseable" reaches the independent-proof path.
# So a pid-confirmed live holder is always kept; every other lock is reapable only when the session lookup does
# not confirm the holder AND the tree proves itself safe.
# CAVEAT (measured 25/09 on `gc session list --json --state all`, 26 sessions): every real session's work_dir is an
# agent home, a crew dir or the HQ root — none is a per-bead worktree (.gc-worktrees, worker-*, .claude/worktrees).
# So "a named session is alive in THIS tree" cannot fire for a real pool worker (it does for a session whose work_dir
# IS the tree), and for those the live-holder guard is the independent proofs — above all _worktree_in_use (a live
# process's cwd inside the tree) — not the lock and not the session list. The ga-wpdmj6 fix ("an alive session's
# tree was reaped") is closed for the OUTAGE route (list unavailable → KEPT), not for a live pool session whose tree
# is merged + clean + aged + not any process's cwd.

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

# ── ga-vs6shu: SESSION-NAME lock-reason recognition ─────────────────────────────
# Measured live 25/09: the real lock reasons pool workers write are NOT "pid N" —
# they name a SESSION instead, in either order ("<bead> <desc> (<session>)" or
# "<session> <desc> (<bead>)"), or carry no reason at all ("(no reason)"). None
# of these match classify_lock's pid-only regex, so it always fell through to
# "unparseable" — silently collapsed into the SAME "live" verdict at the call
# site below (kept_locked_live), mislabeling "I don't know" as "confirmed in
# use" (the same error-vs-empty family as every third-state bug in this city).
# 51 worktrees (2.3G) sat locked forever this way, aged 72h to 1384h (57 days),
# ALL already 100% merged, until a human removed them by hand.
#
# THREE states, never two (gate ga-wpdmj6, blocking issues 1+2). "The session list says
# nobody is alive" and "I could not fetch the session list" are DIFFERENT facts, and on a
# destructive path the second must never be read as the first. The first version collapsed
# both — a gc that was missing / failed / timed out / printed nothing became `{}`, i.e. "no
# session is alive" — so at load ~54 (where `gc session list` timed out 2 of 3 times) the
# live-session protection was a coin flip and an alive session's merged+clean worktree was
# reaped. Now: the fetch records ok | unavailable, and unavailable makes classify_lock say
# "unknown", which the reaper answers with KEEP + a distinct, counted log event.
#
# _session_list_ensure — fetch `gc session list` ONCE per sweep, in the MAIN shell, and
# memoize the outcome (ok OR unavailable — a failure is not retried per lock: that is how
# 3 locked worktrees cost 6 calls and how two calls about the SAME worktree could disagree).
# It must run in the main shell: classify_lock is always invoked as `$(classify_lock ...)`,
# a subshell, and an assignment made there dies with it — so the first version's
# "memoized" cache was never shared and every locked worktree paid for TWO fetches
# (reap_zombie_locked, then _reap_or_log_unparseable_lock). reap_zombie_locked calls this
# BEFORE it opens that subshell (and hands its verdict on via $_ZL_VERDICT, so the second
# classification no longer happens at all); _reap_or_log_unparseable_lock calls it too, but
# only when its caller has no verdict to pass. The subshell inherits the populated globals. Seam: WORKTREE_REAPER_FAKE_SESSION_LIST=<path to a
# file> holding the JSON `gc session list --json` would print, for the hermetic selftest.
_WT_REAPER_SESSION_STATE=""        # "" = not fetched yet | ok | unavailable
_WT_REAPER_SESSION_LIST_JSON=""
_session_list_ensure() {
  [ -n "$_WT_REAPER_SESSION_STATE" ] && return 0
  local raw="" rc=0 why=""
  if [ -n "${WORKTREE_REAPER_FAKE_SESSION_LIST:-}" ]; then
    if [ -f "$WORKTREE_REAPER_FAKE_SESSION_LIST" ]; then
      raw="$(cat "$WORKTREE_REAPER_FAKE_SESSION_LIST" 2>/dev/null)"; rc=$?
    else
      rc=66; why="fake_list_missing"
    fi
  elif ! command -v gc >/dev/null 2>&1; then
    rc=127; why="gc_missing"
  elif ! command -v timeout >/dev/null 2>&1; then
    rc=127; why="timeout_missing"
  else
    # Bounded: a wedged gc/Dolt must never hang the whole sweep over one lookup — TERM after
    # SESSION_LIST_TIMEOUT, KILL SESSION_LIST_KILL_GRACE seconds later if gc ignores TERM.
    raw="$(timeout -k "$SESSION_LIST_KILL_GRACE" "$SESSION_LIST_TIMEOUT" gc --city "${WORKTREE_REAPER_GC_CITY:-$GT/.gascity-gastown-hq}" session list --json --state all 2>/dev/null)"; rc=$?
  fi
  if [ "$rc" -eq 0 ] && ! command -v jq >/dev/null 2>&1; then rc=127; why="jq_missing"; fi
  if [ "$rc" -eq 0 ]; then
    # Accept only the documented shape (`.sessions` an array, `.ok` not false): empty
    # output, `{}`, or a half-written blob is "could not fetch", NOT "zero sessions".
    if printf '%s' "$raw" | jq -e '(.sessions | type) == "array" and (.ok != false)' >/dev/null 2>&1; then
      _WT_REAPER_SESSION_STATE="ok"; _WT_REAPER_SESSION_LIST_JSON="$raw"
      return 0
    fi
    why="invalid_output"
  fi
  if [ -z "$why" ]; then
    case "$rc" in 124|137) why="timeout" ;; *) why="gc_failed" ;; esac   # 137 = timeout(1) had to KILL it after the grace
  fi
  _WT_REAPER_SESSION_STATE="unavailable"; _WT_REAPER_SESSION_LIST_JSON=""
  printf '{"ts":"%s","event":"session_list_unavailable","rc":%s,"why":"%s","timeout_s":%s}\n' \
    "$(ts)" "$rc" "$why" "$SESSION_LIST_TIMEOUT" >> "$LOG" 2>/dev/null
}

# _session_is_alive_for_worktree <name> <wt> — is a session named <name> alive AND does its
# OWN reported work_dir equal <wt> or sit under it?  0 = yes | 1 = the list was fetched and
# holds no such session | 2 = the list is unavailable, cannot know (caller must not treat 2
# as 1). Matching the NAME alone is not enough for a persistent POOL-SLOT identity
# (gastown.dog-1, wa-worker-1): the slot name persists across many unrelated bead
# assignments, so "a session named gastown.dog-1 is alive right now" does not prove THIS
# lock's work is still what that slot is doing — it may have long since moved on, leaving
# this old lock stale. Without the work_dir check a busy-but-unrelated pool slot would
# permanently block the safety net below for a worktree that is actually free. Mirrors
# _worktree_in_use's path-containment check, applied to a session's work_dir instead of a
# live process's cwd. jq's own failure (exit >= 2) is "cannot know" too, never "not alive".
# LIMIT (see the LOCK CONTRACT caveat): real sessions report an agent-home work_dir, never a per-bead
# worktree, so for them this returns 1 ("not alive here") and the reap decision rests on the independent
# proofs, `_worktree_in_use` (lsof cwd) being the live-holder guard.
_session_is_alive_for_worktree() {
  local name="$1" wt="$2" rc
  [ -n "$name" ] || return 1
  [ -n "$wt" ] || return 2
  [ "$_WT_REAPER_SESSION_STATE" = "ok" ] || return 2
  printf '%s' "$_WT_REAPER_SESSION_LIST_JSON" | jq -e --arg n "$name" --arg wt "$wt" '
    (.sessions // []) | any(
      (.name == $n or .session_name == $n) and ((.closed // false) | not) and
      ((.work_dir // "") as $d | $d == $wt or ($d | startswith($wt + "/")))
    )
  ' >/dev/null 2>&1; rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# _lock_reason_pid <lock-reason> — the "pid N" number in a lock reason, or empty.
_lock_reason_pid() {
  printf '%s' "$1" | sed -n 's/.*pid[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p'
}

# classify_lock <lock-reason> [<wt>] → "zombie <pid> <why>" | "live <pid> ..." |
# "live_session <name>" | "unparseable" | "unknown <cause>"
# ZOMBIE iff: pid is DEAD, OR pid is alive but elapsed > ZOMBIE_HOURS AND recent %cpu is
# negligible (idle). The elapsed gate alone is already strong — a live agent working one
# worktree continuously for >2 days is implausible here (sessions cycle); wa-8y45 was 4d7h.
# The idle check only makes the rule STRICTER (a busy-but-ancient proc is kept).
#
# ga-vs6shu: when no "pid N" phrase is present (the common case for pool-worker
# locks), try every whitespace/paren/slash-delimited token in the reason as a
# session-name candidate — the slash split matters for a shape like
# "gastown.dog-1/ga-aes6z active fix 34220", where the session name is glued
# to the bead id with no space. _session_is_alive_for_worktree is the actual
# arbiter: a token that merely LOOKS session-shaped but isn't real (or is real
# but working somewhere else now) just fails the check, no harm done — this
# can only ever ADD a "confirmed live" verdict on top of the existing pid path,
# never a new way to declare zombie.
#
# Four non-zombie outcomes, deliberately distinct: "live"/"live_session" (a holder is
# CONFIRMED alive here), "unparseable" (the session list WAS fetched, and no session it
# names is alive in this worktree), and "unknown <cause>" (we COULD NOT find out — the
# session list is unavailable). The last is never folded into "unparseable": that is the
# error-vs-empty collapse that let a gc timeout read as "nobody is alive" (gate
# ga-wpdmj6). Its callers must KEEP. classify_lock never guesses zombie from silence.
classify_lock() {
  local reason="$1" wt="${2:-}" pid probe alive esecs cpu thr tok
  pid="$(_lock_reason_pid "$reason")"
  if [ -n "$pid" ]; then
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
    return
  fi
  # No worktree path → the work_dir cross-check cannot run → cannot know (both real callers
  # pass it; this is the honest answer for a future caller that does not).
  [ -n "$wt" ] || { echo "unknown no_worktree_path"; return; }
  # Normally already fetched by the caller in the main shell (see _session_list_ensure); this
  # call is a no-op then, and a correct — if uncached — fetch for any caller that skipped it.
  _session_list_ensure
  [ "$_WT_REAPER_SESSION_STATE" = "ok" ] || { echo "unknown session_list_unavailable"; return; }
  # `while read` over a process substitution, NOT `for tok in $(...)`: an unquoted expansion
  # glob-expands each word against the reaper's cwd, so a reason token like `*` would turn
  # into a directory listing of whatever cwd the launchd job happens to have.
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    _session_is_alive_for_worktree "$tok" "$wt"
    case $? in
      0) echo "live_session $tok"; return ;;
      1) : ;;
      *) echo "unknown session_list_unavailable"; return ;;
    esac
  done < <(printf '%s' "$reason" | tr '()/"' '    ' | tr -s ' \t' '\n\n')
  echo "unparseable"
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
  if printf '%s' "$cmd" | grep -iE 'pilot|gate|mayor|deacon|witness|reconcil|supervis|dispatch|watchdog|reaper|sheriff|refin|daemon|kickstart|observer' >/dev/null; then
    printf '{"ts":"%s","event":"kill_skipped_protected","pid":%s}\n' "$(ts)" "$pid" >> "$LOG" 2>/dev/null
    return 0                                                     # controller process → NEVER signal
  fi
  if [ -n "${WORKTREE_REAPER_KILL_SINK:-}" ]; then echo "$pid" >> "$WORKTREE_REAPER_KILL_SINK"
  else kill -TERM "$pid" 2>/dev/null; fi
  printf '{"ts":"%s","event":"zombie_pid_killed","pid":%s}\n' "$(ts)" "$pid" >> "$LOG" 2>/dev/null
}

# reap_zombie_locked <repo> <wt> <br> <reason> <age_h> <label>
#   → 0 reaped | 1 dry-run logged | 3 remove failed |
#     2 not a pid-confirmed zombie (verdict left in $_ZL_VERDICT): the caller hands the lock to
#       _reap_or_log_unparseable_lock, which KEEPS it unless the tree independently proves safe
#       (LOCK CONTRACT above) — "2" does not mean "keep".
# unlock + DOUBLE-force remove (single --force is refused on a locked tree) + merged-only
# branch cleanup (never deletes unmerged local work) + optional guarded process kill.
reap_zombie_locked() {
  local repo="$1" wt="$2" br="$3" reason="$4" age="$5" label="$6" verdict pid why
  # ga-vs6shu: a reason with no "pid N" is classified by session lookup — fetch that list
  # HERE, in the main shell, BEFORE the `$(classify_lock ...)` subshell below, so the memo
  # survives (see _session_list_ensure). Then hand the verdict to the caller via
  # $_ZL_VERDICT: on return 2 it goes straight into _reap_or_log_unparseable_lock instead
  # of being recomputed (a second, independent classification of the same lock could
  # disagree with the first).
  [ -n "$(_lock_reason_pid "$reason")" ] || _session_list_ensure
  verdict="$(classify_lock "$reason" "$wt")"
  _ZL_VERDICT="$verdict"
  case "$verdict" in zombie\ *) : ;; *) return 2 ;; esac
  pid="$(printf '%s' "$verdict" | awk '{print $2}')"
  why="$(printf '%s' "$verdict" | cut -d' ' -f3-)"
  # ga-m5i7e6: a pid-confirmed zombie HOLDER says nothing about OTHER processes working in the tree, and the `remove -f -f`
  # below takes their files with it (dirty or not): a process inside → KEPT, logged, no change to the lock.
  if _worktree_in_use "$wt"; then
    printf '{"ts":"%s","event":"kept_zombie_lock_in_use","repo":"%s","wt":"%s","branch":"%s","pid":%s,"age_h":%s,"label":"%s"}\n' "$(ts)" "$(_json_esc "$(basename "$repo")")" "$(_json_esc "$(basename "$wt")")" "$(_json_esc "$br")" "$pid" "$age" "$(_json_esc "$label")" >> "$LOG" 2>/dev/null
    return 1
  fi
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

# ── BEAD-CLOSED PROOF (ga-yw18yk) ─────────────────────────────────────────────────
# Third independent proof that a lock has nothing left to protect, for the tree whose branch was never merged: a
# bead closed without a merge, or squash-merged with local commits, is neither an ancestor of origin/<default> nor
# patch-equivalent to it, and its worker wrote the lock reason as free text ("wa-621dz active build"), so the
# session lookup cannot name a holder either. Measured 14/10: 20 such trees of CLOSED beads, 6h to 15 days old,
# 165-340 MB each, ~3 GB on a 2-6 GB-free disk, kept on every sweep (1,580 kept_locked_unparseable events).
#
# What it proves: the bead(s) the tree is named for are CLOSED, and have been for BEAD_CLOSED_HOURS. What it does NOT
# prove, and so never does: that the work shipped. Hence the tree goes and the BRANCH STAYS (the caller passes no
# delete proof, so only a branch already merged into origin/<default> is ever deleted), and a DETACHED HEAD, which
# no branch holds, is first parked on a rescue/<bead>-<sha9> branch.
#
# The three states of "what does the bead say", never collapsed into one value:
#   closed (and for long enough)          → proven
#   open / in_progress / blocked / ...    → not proven (the worker may be mid-build)
#   the lookup could not be answered (bd missing, failed, timed out, junk output, no closed_at) → not proven, logged
# A name token that is no bead at all ("wa-worker" in crew/wa-worker/<bead>) is simply absent from a SUCCESSFUL
# answer and is ignored; but at least one named bead must exist, and EVERY one that exists must be closed.
# Seam: WORKTREE_REAPER_FAKE_BEADS=<file holding the JSON array `bd list --json` would print>, for the selftest.

# _wt_bead_candidates <wt> <branch> → bead-id-shaped tokens of the directory name and branch, one per line, unique:
# <2-4 letters>-<3-8 of a-z0-9>[.<n>]..., read off hyphen/slash-separated neighbours ("worker-wa-74p0o0" → wa-74p0o0,
# "crew/wa-worker/wa-y0su67.2-x" → wa-worker, wa-y0su67.2). Over-matching is harmless (a non-bead is ignored above);
# the shape only has to be wide enough not to miss a real id. No interval expressions: macOS awk lacks them.
_wt_bead_candidates() {
  printf '%s\n%s\n' "$(basename "$1")" "$2" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C awk '
    {
      nc = split($0, chunk, /[^a-z0-9.-]+/)
      for (c = 1; c <= nc; c++) {
        nt = split(chunk[c], tok, "-")
        for (i = 1; i < nt; i++) {
          p = tok[i]; s = tok[i + 1]
          if (p !~ /^[a-z]+$/ || length(p) < 2 || length(p) > 4) continue
          if (!match(s, /^[a-z0-9]+/)) continue
          blen = RLENGTH; rest = substr(s, blen + 1)
          if (blen < 3 || blen > 8 || rest !~ /^(\.[0-9]+)*$/) continue
          id = p "-" s
          if (!(id in seen)) { seen[id] = 1; print id }
        }
      }
    }'
}

# _nl_has <newline-separated-list> <item> — exact membership, no pipe (nothing for pipefail to invert).
_nl_has() {
  case "
$1
" in *"
$2
"*) return 0 ;; esac
  return 1
}

# _bead_lookup <dir> <csv-ids> — print the JSON array of the beads among <csv-ids> that exist in <dir>'s database
# (`--all`: a closed bead is exactly what we are asking for; `--limit 0`: bd's default cap of 50 is silent in the
# JSON). Non-zero = the question was NOT answered; an empty array is a real answer ("none of these exist here").
_bead_lookup() {
  local dir="$1" ids="$2"
  if [ -n "${WORKTREE_REAPER_FAKE_BEADS:-}" ]; then
    [ -f "$WORKTREE_REAPER_FAKE_BEADS" ] || return 66
    cat "$WORKTREE_REAPER_FAKE_BEADS"; return $?
  fi
  command -v bd >/dev/null 2>&1 || return 127
  command -v timeout >/dev/null 2>&1 || return 127
  timeout -k "$BEAD_LOOKUP_KILL_GRACE" "$BEAD_LOOKUP_TIMEOUT" bd -C "$dir" list --id "$ids" --all --json --limit 0 </dev/null 2>/dev/null
}

# _bead_lookup_failed <repo> <rc> <why> — count it, and log ONE event per repo per sweep (the kept tree is already
# logged every sweep as kept_locked_unparseable; this says WHY the new proof could not even be tried).
_bead_lookup_failed() {
  bead_lookup_failed=$((bead_lookup_failed+1))
  _nl_has "$_BC_FAILED_SEEN" "$1" && return 0
  _BC_FAILED_SEEN="$_BC_FAILED_SEEN${_BC_FAILED_SEEN:+
}$1"
  printf '{"ts":"%s","event":"bead_lookup_failed","repo":"%s","rc":%s,"why":"%s"}\n' \
    "$(ts)" "$(_json_esc "$(basename "$1")")" "$2" "$(_json_esc "$3")" >> "$LOG" 2>/dev/null
}

# _worktree_op_in_progress <wt> — a rebase / merge / cherry-pick / revert / bisect is under way in the tree. Its
# state lives in the tree's git dir, not in `git status`, and a half-done operation is not a finished worktree, so it
# is never reaped on the bead's say-so. Can't read the git dir → treated as in progress.
_worktree_op_in_progress() {
  local p gp
  for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    gp="$(cd "$1" 2>/dev/null && git rev-parse --git-path "$p" 2>/dev/null)" || return 0
    case "$gp" in /*) : ;; *) gp="$1/$gp" ;; esac
    [ -e "$gp" ] && return 0
  done
  return 1
}

# _rescue_detached_head <repo> <wt> <label> — park the tree's detached HEAD on rescue/<label>-<sha9> (the convention
# of the manual rescue, rescue/wa-0ye8hw-a7e50fe20) so the commit is held by a branch before the tree is removed.
# 0 only when that branch exists and points at HEAD afterwards (re-checked, not assumed from git's exit code).
_rescue_detached_head() {
  local repo="$1" wt="$2" label="$3" head name
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ -n "$head" ] && [ -n "$label" ] || return 1
  name="rescue/$label-$(printf '%s' "$head" | cut -c1-9)"
  if [ "$(git -C "$repo" rev-parse --verify -q "refs/heads/$name" 2>/dev/null)" != "$head" ]; then
    git -C "$repo" branch "$name" "$head" >/dev/null 2>&1 || return 1
  fi
  [ "$(git -C "$repo" rev-parse --verify -q "refs/heads/$name" 2>/dev/null)" = "$head" ]
}

# _bead_ask <repo> <dir> <csv-ids> — ask <dir>'s database about <csv-ids> and append what exists to the proof's
# working set ($_BC_ROWS: "id<TAB>status<TAB>closed-epoch-or-->" lines; $_BC_FOUND_IDS / $_BC_FOUND_PFX: the ids and
# the prefixes that answered). Main shell only — it updates counters, so never call it inside $(...). 0 = answered
# (possibly with nothing), 1 = could not be answered (already logged).
_bead_ask() {
  local repo="$1" dir="$2" q="$3" raw rc part bid tab
  raw="$(_bead_lookup "$dir" "$q")"; rc=$?
  if [ "$rc" -ne 0 ]; then _bead_lookup_failed "$repo" "$rc" "bd_failed"; return 1; fi
  # Exit 0 with NOTHING printed is no answer either: jq also exits 0 on empty input, so without this check the
  # extraction below would read the silence as "none of these beads exist" (the array [] is how bd says that).
  if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _bead_lookup_failed "$repo" 0 "unreadable_answer"; return 1
  fi
  part="$(printf '%s' "$raw" | jq -r --arg ids "$q" '
    if type != "array" then error("bd list did not print an array") else . end
    | ($ids | split(",")) as $want
    | .[]
    | select(type == "object" and (.id | type) == "string" and (.id as $i | $want | any(. == $i)))
    | [ .id,
        ((.status // "") | if . == "" then "-" else . end),
        ((.closed_at // "") | if type != "string" or . == "" then "-"
           else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch "-") | tostring) end) ]
    | @tsv' 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then _bead_lookup_failed "$repo" "$rc" "unreadable_answer"; return 1; fi
  [ -n "$part" ] || return 0
  _BC_ROWS="$_BC_ROWS${_BC_ROWS:+
}$part"
  tab="$(printf '\t')"
  while IFS="$tab" read -r bid _ _; do
    [ -n "$bid" ] || continue
    _BC_FOUND_IDS="$_BC_FOUND_IDS${_BC_FOUND_IDS:+
}$bid"
    _BC_FOUND_PFX="$_BC_FOUND_PFX${_BC_FOUND_PFX:+
}${bid%%-*}"
  done <<EOF
$part
EOF
  return 0
}

# _bead_closed_proof <repo> <wt> <br> — 0 iff the proof above holds. On 0, $_BC_PROOF_IDS holds the closed bead ids it
# relied on and $_BC_PROOF_FIRST the first of them. The repo's own database is asked first; a rig repo (not the town
# root) is also asked, in the HQ database, about the named beads the first answer does not account for (a ga-*
# worktree can live in a rig repo). Any lookup that cannot be answered ends it: not proven.
_bead_closed_proof() {
  local repo="$1" wt="$2" br="$3" cur cands q hq c cp rest="" bid st ce now_s need n_found=0 first="" closed_ids="" tab
  _BC_PROOF_IDS=""; _BC_PROOF_FIRST=""; _BC_ROWS=""; _BC_FOUND_IDS=""; _BC_FOUND_PFX=""
  _worktree_op_in_progress "$wt" && return 1
  cur="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)"; [ -n "$cur" ] || cur="$br"
  cands="$(_wt_bead_candidates "$wt" "$cur")"
  [ -n "$cands" ] || return 1
  q="$(printf '%s' "$cands" | tr '\n' ',')"; q="${q%,}"
  _bead_ask "$repo" "$repo" "$q" || return 1
  hq="$GT/.gascity-gastown-hq"
  if [ "$repo" != "$GT" ] && [ "$repo" != "$hq" ]; then
    # only the names the first answer does not account for: an unfound name whose prefix IS that of a bead already
    # found there is just a word (wa-worker next to wa-<bead>), not a bead that lives elsewhere
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      _nl_has "$_BC_FOUND_IDS" "$c" && continue
      cp="${c%%-*}"
      _nl_has "$_BC_FOUND_PFX" "$cp" && continue
      rest="$rest${rest:+,}$c"
    done <<EOF
$cands
EOF
    if [ -n "$rest" ]; then _bead_ask "$repo" "$hq" "$rest" || return 1; fi
  fi
  now_s=$(date +%s); need=$((BEAD_CLOSED_HOURS * 3600)); tab="$(printf '\t')"
  while IFS="$tab" read -r bid st ce; do
    [ -n "$bid" ] || continue
    [ "$st" = "closed" ] || return 1                      # any named bead not closed: the worker may be live
    case "$ce" in ''|*[!0-9]*) return 1 ;; esac           # closed, but when? unknown → not proven
    [ $((now_s - ce)) -ge "$need" ] || return 1           # closed too recently
    _nl_has "$closed_ids" "$bid" && continue
    closed_ids="$closed_ids${closed_ids:+
}$bid"; n_found=$((n_found+1)); [ -n "$first" ] || first="$bid"
  done <<EOF
$_BC_ROWS
EOF
  [ "$n_found" -ge 1 ] || return 1                       # no named bead exists: nothing says the work is over
  _BC_PROOF_IDS="$(printf '%s' "$closed_ids" | tr '\n' ' ')"; _BC_PROOF_IDS="${_BC_PROOF_IDS% }"; _BC_PROOF_FIRST="$first"
  return 0
}

# _reap_or_log_unparseable_lock <repo> <wt> <br> <reason> <age_h> <label> [<verdict>] —
# ga-vs6shu: called when reap_zombie_locked returned 2 (holder is not a
# pid-confirmed zombie). Splits what used to be a SINGLE collapsed
# "kept_locked_live" verdict — covering both "confirmed alive" and "I have no
# idea" under the identical event/counter — into distinct, honestly
# labeled outcomes:
#   0 = reaped: classify_lock could not confirm the holder is alive (no pid,
#       and the session list was FETCHED and names no live session in this
#       worktree), but the worktree independently proves SAFE to remove anyway
#       — content already 100% in main (an ancestor of it, or, for a rebased
#       branch with no merge commit, every commit there as an equivalent patch — ga-1md7na), no
#       uncommitted changes, no live process has it as a cwd, and it is older
#       than the stale-hours gate. There is nothing left for the lock to be protecting, regardless
#       of what its text says or whether it could be parsed at all. This is
#       the actual measured bug: 51 real worktrees (2.3G) sat locked forever
#       this way, ALL already in this exact state.
#       The same reap also happens on the BEAD-CLOSED proof (ga-yw18yk) for a tree whose branch never
#       shipped: its bead(s) closed for BEAD_CLOSED_HOURS, tree clean and unused, no operation under way.
#       That one removes the tree only; the branch is kept (see _bead_closed_proof).
#   1 = kept, CONFIRMED live (verdict live/live_session): a session named in
#       the reason is genuinely alive AND working in this exact worktree.
#   1 = kept, UNKNOWN (verdict "unknown <cause>"): the session list could not
#       be fetched, so whether a live session holds this worktree is not
#       knowable. The safe default on a destructive path is "assume alive":
#       KEEP, log kept_locked_session_list_unavailable, and count it — never
#       fall through to the safety net below on a value we do not have.
#   1 = kept, UNRECOGNISED verdict (empty — classify_lock died inside its `$(...)` —, a stray
#       "zombie ...", or any token no arm here names): "cannot tell", never "unparseable". On a
#       destructive path the default is KEEP, with its own event (kept_locked_unrecognized_verdict).
#       ONLY the exact verdict "unparseable" reaches the independent-proof path below.
#   1 = kept, genuinely unparseable: the list was fetched, could not confirm
#       live, and the worktree did not independently qualify as safe
#       (unmerged, dirty, in-use, or too young) — the correct, conservative
#       "I don't touch it" outcome, logged as what it actually is instead of
#       masquerading as a confirmed-live holder.
# <verdict> is reap_zombie_locked's own classification ($_ZL_VERDICT), passed
# through so the lock is classified ONCE; only a caller that has none makes
# this classify (after fetching in the main shell — see _session_list_ensure).
# Always logs, every branch — the whole point of this fix is a distinct,
# honest event per outcome instead of one collapsed label.
_reap_or_log_unparseable_lock() {
  local repo="$1" wt="$2" br="$3" reason="$4" age="$5" label="$6" verdict="${7-}"
  if [ -z "$verdict" ]; then
    _session_list_ensure
    verdict="$(classify_lock "$reason" "$wt")"
  fi
  case "$verdict" in
    live\ *|live_session\ *)
      _log_lock_event kept_locked_live "$repo" "$wt" "$br" "$age" "$label" "$verdict"
      return 1
      ;;
    unknown\ session_list_unavailable)
      kept_session_list_unavailable=$((kept_session_list_unavailable+1))
      _log_lock_event kept_locked_session_list_unavailable "$repo" "$wt" "$br" "$age" "$label" "$verdict" "$reason"
      return 1
      ;;
    unknown\ *)
      _log_lock_event kept_locked_unknown "$repo" "$wt" "$br" "$age" "$label" "$verdict" "$reason"
      return 1
      ;;
    unparseable) : ;;   # the ONLY verdict that may fall through to the independent-proof path below
    *)
      # An empty string (classify_lock killed inside its `$(...)`), a "zombie ..." the caller should have
      # handled, or any token no arm names is "cannot tell" — never "unparseable". KEEP, distinctly logged.
      _log_lock_event kept_locked_unrecognized_verdict "$repo" "$wt" "$br" "$age" "$label" "${verdict:-<empty>}" "$reason"
      return 1
      ;;
  esac
  # Explicit exit-code + output check (not `status | grep .`) — a bare grep
  # collapses "git status genuinely succeeded and found nothing" and "git
  # status itself FAILED (empty stdout either way)" into the identical
  # "clean" verdict. This is new code on a destructive path, so it earns the
  # stricter form: only a CONFIRMED-successful, CONFIRMED-empty status counts
  # as clean; any command failure falls through to the safe "kept" branch.
  local _status_out _status_rc _proof="" _unused=0
  _status_out="$(git -C "$wt" status --porcelain 2>/dev/null)"; _status_rc=$?
  # "Delivered" has two proofs (ga-1md7na): HEAD is an ancestor of origin/<default>, or — for a branch the
  # gate rebased, whose HEAD can never be one — it carries no merge commit and every commit it carries is in
  # origin/<default> as an equivalent patch. The cheap ancestry one goes first; the merge check and `git cherry`
  # only run when it fails. An unusable answer from any of them is "not proven", so _proof stays empty and the
  # tree is KEPT.
  if [ "$age" -gt "$gate_hours" ] 2>/dev/null; then
    if _worktree_head_merged "$repo" "$wt"; then _proof="ancestor"
    elif _ref_patch_equivalent "$repo" "$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; then _proof="patch_equivalent"
    fi
  fi
  # The THIRD proof (ga-yw18yk), for a tree neither of those can vouch for: every bead it is named for is closed.
  # Last and gated on everything cheap first, because it costs a `bd` call: aged, git-clean and not in use (which
  # is probed here once and remembered in _unused, not asked again below). A positive answer needs
  # _bead_closed_proof to exist and say yes; where it does not (the unit sandbox) the tree is simply not proven.
  if [ -z "$_proof" ] && [ "$age" -gt "$gate_hours" ] 2>/dev/null \
     && [ "$_status_rc" -eq 0 ] && [ -z "$_status_out" ] \
     && ! _worktree_in_use "$wt" \
     && _bead_closed_proof "$repo" "$wt" "$br"; then
    _proof="bead_closed"; _unused=1
  fi
  if [ -n "$_proof" ] \
     && [ "$_status_rc" -eq 0 ] && [ -z "$_status_out" ] \
     && { [ "$_unused" = "1" ] || ! _worktree_in_use "$wt"; }; then
    # The event names which proof reaped it; the ancestry one keeps its ga-vs6shu name.
    local _ev_reaped="reaped_locked_unparseable_safe" _ev_would="would_reap_locked_unparseable_safe" _del_proof="" _ev_verdict=""
    if [ "$_proof" = "patch_equivalent" ]; then
      _ev_reaped="reaped_locked_unparseable_patch_equivalent"
      _ev_would="would_reap_locked_unparseable_patch_equivalent"
      _del_proof="patch_equivalent"
    elif [ "$_proof" = "bead_closed" ]; then
      # No _del_proof: this proof says the work is OVER, not that it SHIPPED, so only a branch already merged
      # into origin/<default> is ever deleted along with the tree. The verdict field carries the beads relied on.
      _ev_reaped="reaped_locked_unparseable_bead_closed"
      _ev_would="would_reap_locked_unparseable_bead_closed"
      _ev_verdict="bead_closed $_BC_PROOF_IDS"
    fi
    if [ "$ENABLED" = "1" ]; then
      # A DETACHED HEAD is held by no branch: park it on rescue/<bead>-<sha9> first, and if that cannot be done the
      # tree stays (its commits would be the only copy). A tree on a branch needs nothing: the branch outlives it.
      if [ "$_proof" = "bead_closed" ] && ! git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1 \
         && ! _rescue_detached_head "$repo" "$wt" "$_BC_PROOF_FIRST"; then
        _log_lock_event bead_closed_rescue_failed "$repo" "$wt" "$br" "$age" "$label" "$_ev_verdict" "$reason"
        return 1
      fi
      # No `worktree unlock` first — `remove -f -f` is git's own way to remove a LOCKED
      # worktree, and skipping the unlock means a remove that fails cannot leave the
      # worktree stripped of a lock whose holder we never identified (there would be
      # nothing to restore it FROM; reap_zombie_locked's unlock is different: there the
      # holder is confirmed dead).
      if git -C "$repo" worktree remove -f -f "$wt" 2>/dev/null; then
        _log_lock_event "$_ev_reaped" "$repo" "$wt" "$br" "$age" "$label" "$_ev_verdict" "$reason"
        delete_merged_local_branch "$repo" "$br" "$_del_proof"
        return 0
      fi
      _log_lock_event unparseable_safe_reap_failed "$repo" "$wt" "$br" "$age" "$label"
      return 1
    fi
    _log_lock_event "$_ev_would" "$repo" "$wt" "$br" "$age" "$label" "$_ev_verdict" "$reason"
    return 1
  fi
  _log_lock_event kept_locked_unparseable "$repo" "$wt" "$br" "$age" "$label" "" "$reason"
  return 1
}

# _worktree_dirty_only_generated <wt> — ga-he2c1u: 0 iff the tree is dirty with NOTHING BUT generated files: every
# `git status` entry is UNTRACKED (`??`) and its path matches GENERATED_RE (or is the city's pack.toml, byte-identical
# to the city's). Everything else is 1: a tracked file modified/staged/deleted/renamed/conflicted (even one whose path
# looks generated — a tracked file is somebody's), an untracked file the list does not name, a status that could not
# be read (its exit code is checked, not its silence), and a tree that is not dirty at all (the plain remove was then
# refused for some other reason — a lock, a permission — and forcing would be a guess).
_worktree_dirty_only_generated() {
  local wt="$1" tmp rc n=0 ent p
  tmp="$(mktemp 2>/dev/null)" || return 1
  git -C "$wt" status --porcelain=v1 -z --untracked-files=all >"$tmp" 2>/dev/null; rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return 1; fi
  while IFS= read -r -d '' ent; do
    case "$ent" in '?? '*) : ;; *) rm -f "$tmp"; return 1 ;; esac
    p="${ent#\?\? }"
    if printf '%s' "$p" | grep -Eq -- "$GENERATED_RE"; then n=$((n+1)); continue; fi
    if [ "$p" = ".gascity-gastown-hq/pack.toml" ] && cmp -s "$wt/$p" "$GT/$p" 2>/dev/null; then n=$((n+1)); continue; fi
    rm -f "$tmp"; return 1
  done <"$tmp"   # third-state-waiver: $tmp was written one line up and its exit code checked; a vanished file reads as no entries, n stays 0 and the tree is NOT dirty-only-generated (inert)
  rm -f "$tmp"
  [ "$n" -ge 1 ]
}

# _reap_dirty_generated_only <repo> <wt> <br> <age_h> <label> — ga-he2c1u: the plain `worktree remove` was refused
# because the tree is dirty. If it is dirty with nothing but generated files (_worktree_dirty_only_generated), its
# content is already in origin/<default> (an ancestor of it, or every commit there as an equivalent patch — the same two
# proofs as the locked path), no live process has it as a cwd, and every bead it is named for is CLOSED for
# BEAD_CLOSED_HOURS (_bead_closed_proof), nothing the tree holds is anyone's work: remove it with a SINGLE --force
# (git's own word for "dirty is fine"; a LOCKED tree still refuses it and never gets `-f -f` here — locks belong to
# the zombie/unparseable paths). Without this such a tree was refused on every sweep and counted as skipped_dirty,
# silently: bead closed + merged + `.gc/system` copy was enough to keep 165 files of a delivered branch on disk forever.
# Returns 0 iff it reaped. Anything short of every proof, and a tree this repo does not list (an engine worktree
# under the town's .gc-worktrees belongs to another repo), is 1 with no event: the caller's skipped_dirty already
# counts it, and an event per refused tree per sweep would drown the log (the same reason the plain path is silent).
# A DETACHED tree needs no rescue branch: the delivery proof already says its HEAD is in origin/<default>.
_reap_dirty_generated_only() {
  local repo="$1" wt="$2" br="$3" age="$4" label="$5" head st proof="" del_proof="" verdict
  st="$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk -v p="$wt" '
    $1=="worktree" { c=$2; if (c==p) listed=1 }
    $1=="locked"   { if (c==p) locked=1 }
    END { printf "%s%s", (listed ? "listed" : "foreign"), (locked ? " locked" : "") }')"
  [ "$st" = "listed" ] || return 1
  [ -n "$br" ] || br="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)"
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; [ -n "$head" ] || return 1   # third-state-waiver: an unreadable HEAD is an empty head and the same line returns 1 before any proof or remove (inert)
  _worktree_op_in_progress "$wt" && return 1
  _worktree_dirty_only_generated "$wt" || return 1
  if _worktree_head_merged "$repo" "$wt"; then proof="ancestor"
  elif _ref_patch_equivalent "$repo" "$head"; then proof="patch_equivalent"; del_proof="patch_equivalent"
  else return 1; fi
  _worktree_in_use "$wt" && return 1
  _bead_closed_proof "$repo" "$wt" "$br" || return 1
  verdict="$proof bead_closed $_BC_PROOF_IDS"
  # Dry-run never gets here (Loop 1 logs would_reap and moves on before any remove is tried); a --force still checks.
  [ "$ENABLED" = "1" ] || return 1
  if git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
    _log_lock_event reaped_dirty_generated_only "$repo" "$wt" "$br" "$age" "$label" "$verdict"
    delete_merged_local_branch "$repo" "$br" "$del_proof"
    return 0
  fi
  _log_lock_event dirty_generated_reap_failed "$repo" "$wt" "$br" "$age" "$label" "$verdict"
  return 1
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
        # ga-m5i7e6: age = the freshest sign of life (_wt_fresh_epoch), not the root directory's mtime; a tree whose signals
        # cannot be read is KEPT and logged, never aged by a guess.
        local mtime_s
        if ! mtime_s="$(_wt_fresh_epoch "$wt" "$now_s")"; then
          kept=$((kept+1))
          printf '{"ts":"%s","event":"kept_activity_unknown","repo":"%s","wt":"%s","branch":"%s"}\n' "$(ts)" "$(_json_esc "$(basename "$repo")")" "$(_json_esc "$(basename "$wt")")" "$(_json_esc "$br")" >> "$LOG" 2>/dev/null
          wt=""; br=""; lock=""; continue
        fi
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
        # ga-m5i7e6: in use / disk-pressure-unmerged is checked for every tree about to be removed (it used to be the merged
        # branch only). A LOCKED unmerged tree is left to the lock contract below: its own proofs (zombie holder, merged +
        # clean + unused, closed bead) are what frees disk under pressure, and each already asks _worktree_in_use.
        if [ "$merged" = "1" ] || [ -z "$lock" ]; then
          if _keep_unsafe "$repo" "$wt" "$br" "$age" "$merged"; then
            kept=$((kept+1))
            wt=""; br=""; lock=""; continue
          fi
        fi
        # ── LOCKED worktree — the LOCK CONTRACT (see ZOMBIE-LOCK DETECTION): a pid-confirmed zombie is
        # reaped; a pid-confirmed live holder is always kept; any other lock goes to
        # _reap_or_log_unparseable_lock, which reaps it only when the session lookup does not confirm the
        # holder AND the tree proves itself merged + clean + not in use + aged, and keeps it otherwise.
        if [ -n "$lock" ]; then
          if [ "$ZOMBIE_LOCK_ENABLED" = "1" ]; then
            local zrc
            reap_zombie_locked "$repo" "$wt" "$br" "$lock" "$age" "pool"; zrc=$?
            case "$zrc" in
              0) pool_reaped=$((pool_reaped+1)); zombie_reaped=$((zombie_reaped+1)) ;;
              1) : ;;                                    # dry-run intent logged
              2)
                 # ga-vs6shu: not a pid-confirmed zombie — split "confirmed
                 # live" from "genuinely unparseable" instead of collapsing
                 # both into the same kept_locked_live verdict, and give the
                 # unparseable case one more independent chance (merged +
                 # clean + not-in-use + aged) before parking it forever.
                 # _reap_or_log_unparseable_lock returns 0 = reaped (its own
                 # safety net fired), 1 = kept (either confirmed-live or
                 # genuinely-unparseable-and-unsafe) — both already logged
                 # distinctly inside it; this only tallies the right counter.
                 if _reap_or_log_unparseable_lock "$repo" "$wt" "$br" "$lock" "$age" "pool" "$_ZL_VERDICT"; then
                   pool_reaped=$((pool_reaped+1))
                 else
                   kept=$((kept+1))
                 fi
                 ;;
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
    # ga-m5i7e6: same freshest-signal age as the pool loop; unreadable → KEPT and logged
    if ! mtime_s="$(_wt_fresh_epoch "$d" "$now_s")"; then
      kept=$((kept+1))
      printf '{"ts":"%s","event":"kept_activity_unknown","wt":"%s"}\n' "$(ts)" "$(_json_esc "$(basename "$d")")" >> "$LOG" 2>/dev/null
      continue
    fi
    age=$(( (now_s - mtime_s) / 3600 ))
    age_min=$(( (now_s - mtime_s) / 60 ))
    merged=0
    # ga-t14of: gated on MERGED_MIN_AGE_MIN — see reap_pool_worktrees for why a bare
    # "merged" check alone would reap a just-created, not-yet-touched worktree too.
    if [ "$age_min" -ge "$MERGED_MIN_AGE_MIN" ] && _worktree_head_merged "$GT" "$d"; then merged=1; fi
    if [ "$age" -le "$gate_hours" ] && [ "$merged" != "1" ]; then kept=$((kept+1)); continue; fi
    # ga-m5i7e6: in use / disk-pressure-unmerged for every tree about to go (was: merged only). A LOCKED unmerged tree is left
    # to the lock contract below instead: its own proofs (zombie holder, closed bead) are what frees disk under pressure.
    lock_reason="$(_wt_lock_reason "$GT" "$d")"
    if [ "$merged" = "1" ] || [ -z "$lock_reason" ]; then
      if _keep_unsafe "$GT" "$d" "" "$age" "$merged"; then
        kept=$((kept+1))
        continue
      fi
    fi
    if [ "$ENABLED" != "1" ]; then
      printf '{"ts":"%s","event":"would_reap","wt":"%s","age_h":%s,"mode":"%s","merged":%s}\n' "$(ts)" "$(basename "$d")" "$age" "$mode" "$merged" >> "$LOG" 2>/dev/null
      continue
    fi
    # no --force: a worktree with uncommitted WIP (a live build) is REFUSED → protected.
    if git -C "$GT" worktree remove "$d" 2>/dev/null; then
      reaped=$((reaped+1))
      printf '{"ts":"%s","event":"reaped","wt":"%s","age_h":%s,"mode":"%s","merged":%s}\n' "$(ts)" "$(basename "$d")" "$age" "$mode" "$merged" >> "$LOG" 2>/dev/null
    elif _reap_dirty_generated_only "$GT" "$d" "" "$age" "town"; then
      # ga-he2c1u: refused only because of generated files, delivered, bead closed — see the function
      reaped=$((reaped+1))
    elif [ "$ZOMBIE_LOCK_ENABLED" = "1" ] && [ -n "$lock_reason" ]; then   # lock_reason: read above (_wt_lock_reason)
      # ga-vs6shu: a BARE lock (`git worktree lock` with no --reason) prints as a lone
      # `locked` line, so the awk above used to yield "" and `[ -n ]` failed — this loop
      # silently skipped it (skipped_dirty, no event) while the pool loop maps the same
      # shape to "(no reason)" and reaps it. Same word here, so both loops agree; an empty
      # lock_reason now means only "not locked" (or git itself failed → stays kept).
      # plain remove was refused by a LOCK — same LOCK CONTRACT as the pool loop above: a pid-confirmed
      # zombie is reaped; any other lock goes to _reap_or_log_unparseable_lock (kept unless the tree
      # independently proves safe).
      reap_zombie_locked "$GT" "$d" "" "$lock_reason" "$age" "town"; zrc1=$?
      case "$zrc1" in
        0) reaped=$((reaped+1)); zombie_reaped=$((zombie_reaped+1)) ;;
        2)
          # ga-vs6shu: same split as the pool-worktree loop above — give an
          # unparseable (not pid-confirmed-zombie) lock one independent
          # safety-net chance before parking it forever; 0=reaped, 1=kept.
          if _reap_or_log_unparseable_lock "$GT" "$d" "" "$lock_reason" "$age" "town" "$_ZL_VERDICT"; then
            reaped=$((reaped+1))
          else
            skipped_dirty=$((skipped_dirty+1))
          fi
          ;;
        *) skipped_dirty=$((skipped_dirty+1)) ;;   # dry-run / fail → leave it
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

printf '{"ts":"%s","event":"sweep","mode":"%s","free_gb":%s,"gate_hours":%s,"reaped":%s,"pool_reaped":%s,"zombie_reaped":%s,"preserved_dirty":%s,"branches_deleted":%s,"skipped_dirty":%s,"kept":%s,"session_list":"%s","kept_session_list_unavailable":%s,"bead_lookup_failed":%s}\n' \
  "$(ts)" "$mode" "$free_gb" "$gate_hours" "$reaped" "$pool_reaped" "$zombie_reaped" "$preserved_dirty" "$branches_deleted" "$skipped_dirty" "$kept" "${_WT_REAPER_SESSION_STATE:-unused}" "$kept_session_list_unavailable" "$bead_lookup_failed" >> "$LOG" 2>/dev/null
exit 0
