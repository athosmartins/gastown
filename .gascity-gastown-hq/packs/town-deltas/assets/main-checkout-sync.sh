#!/usr/bin/env bash
# main-checkout-sync.sh — keep the worktree that has `main` checked out in step with the
# bare repo's `main` (ga-7wtwvx).
#
# Usage:  main-checkout-sync.sh <bare_git_dir> [<branch>=main]
#   env:  MCS_GRACE_SECS       index younger than this is someone's live work, left alone (600)
#         MCS_WARN_REPEAT_SECS the same attention line is not repeated sooner than this (21600)
#         MCS_SCAN_COMMITS     how far back from HEAD to look for the commit the index still is (50000)
#         MCS_STATE_DIR        where the repeat-throttle stamps live (<city>/.gc/main-checkout-sync-state)
#         MCS_DRY_RUN=1        report what would be healed, touch nothing, never throttle
#   stdout: one line per worktree that is not simply in sync:
#             healed <wt> ...                the index and files were brought to HEAD
#             would-heal <wt> ...            (dry run only; exits 2)
#             attention:<kind> <wt> ...      a human/Mayor needs to look; nothing was touched
#   exit:   0 every worktree is in sync or was healed / waiting out the grace period
#           2 at least one worktree needs attention (the line may be throttled away from stdout)
#           1 could not even list the worktrees (bare dir unreadable, `worktree list` failed)
#
# Why (ga-7wtwvx): a container rig is a bare `.repo.git` with linked worktrees, and
# `refinery/rig` has `main` checked out. The gate keeps the bare `main` tracking origin with
# plumbing — `git update-ref refs/heads/main <sha>` (reconcile_bare_main_to_origin in
# quality-gate-dispatcher.sh, and the ff_heal in gate-merge-survival-sweep.sh). update-ref moves
# the branch a worktree's HEAD points at WITHOUT touching that worktree's index or files, so HEAD
# runs ahead while the index and files stay on the old snapshot. property_scrapers sat 121
# commits behind since 04/09; `git status` there showed 105 staged "reverts", and a `git commit -a`
# (or an agent that "commits what is staged") would have committed all of them.
#
# The fix is a detector, not a patch per writer: every sweep, look at each worktree that has
# <branch> checked out and compare its index tree with HEAD's tree.
#   in sync                         → nothing to say.
#   index == the tree of an earlier commit on HEAD's own history (the stale snapshot), files
#   match the index, no operation in progress, index not touched for MCS_GRACE_SECS
#                                   → `git read-tree -m -u <index-tree> <HEAD-tree>`. A two-way
#                                     merge from exactly that snapshot: nothing is lost, because
#                                     the snapshot is a tree already in history, and git refuses
#                                     (leaving the index alone) if it would overwrite anything else.
#   anything else — staged work that matches no snapshot, unstaged edits on top of a stale index,
#   an operation in progress, a git call that failed
#                                   → attention:<kind>. Never healed: "could not tell" and "has
#                                     local work" both land on doing nothing and saying so.
# We never touch the bare ref and never touch a worktree whose HEAD is not <branch>.

set -uo pipefail   # no -e on purpose: every git call below is classified by its own rc

BARE="${1:-}"
BRANCH="${2:-main}"

# A malformed override falls back to the default rather than turning into arithmetic noise.
GRACE_SECS="${MCS_GRACE_SECS:-600}";            case "$GRACE_SECS"   in ''|*[!0-9]*) GRACE_SECS=600 ;;   esac
REPEAT_SECS="${MCS_WARN_REPEAT_SECS:-21600}";   case "$REPEAT_SECS"  in ''|*[!0-9]*) REPEAT_SECS=21600 ;; esac
SCAN_COMMITS="${MCS_SCAN_COMMITS:-50000}";      case "$SCAN_COMMITS" in ''|*[!0-9]*) SCAN_COMMITS=50000 ;; esac
DRY_RUN="${MCS_DRY_RUN:-0}"
STATE_DIR="${MCS_STATE_DIR:-${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}/.gc/main-checkout-sync-state}"

NL='
'
WT=""          # worktree under inspection (g() runs git inside it)
NEEDS=0        # some worktree needs attention (drives the exit code)

# The dispatcher may export GIT_DIR/GIT_INDEX_FILE for its own repo; they must not leak into ours.
gitenv() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_PREFIX "$@"; }
g()  { gitenv git -C "$WT" "$@"; }
gb() { gitenv git --git-dir="$BARE" "$@"; }

say() { printf '%s\n' "$*"; }

# ── repeat throttle ────────────────────────────────────────────────────────────────────────
# An unresolved attention state (WA's refinery/rig) would otherwise log every 60s sweep.
# should_emit <signature> → 0 = print the line, 1 = same line was printed < REPEAT_SECS ago.
# The throttle may only ever err toward printing.
state_file() {
  local h
  # vazio/falhou → no usable name: the caller prints the line unthrottled
  h=$(printf '%s' "$BARE|$WT" | cksum 2>/dev/null | awk '{print $1}') || h=""
  [ -n "$h" ] || return 1
  printf '%s/%s' "$STATE_DIR" "$h"
}

should_emit() {
  local sig="$1" f now last="" prev=""
  [ "$DRY_RUN" = "1" ] && return 0
  f=$(state_file) || return 0
  # vazio (no clock) → print; falhou → print
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  # vazio (no stamp: never printed) → print; falhou/ilegível (unreadable or garbled stamp) → print
  if [ -r "$f" ]; then { read -r last prev < "$f"; } 2>/dev/null || { last=""; prev=""; }; fi
  case "$last" in ''|*[!0-9]*) last="" ;; esac
  if [ -n "$last" ] && [ "$prev" = "$sig" ] && [ "$now" -ge "$last" ] && [ $((now - last)) -lt "$REPEAT_SECS" ]; then
    return 1
  fi
  # A stamp we cannot write only costs a repeated line next sweep.
  { mkdir -p "$STATE_DIR" && printf '%s %s\n' "$now" "$sig" > "$f"; } 2>/dev/null || :
  return 0
}

clear_state() {
  local f
  f=$(state_file) || return 0
  [ -e "$f" ] && { rm -f "$f" 2>/dev/null || :; }
  return 0
}

# attention <kind> <signature-extra> <detail>
attention() {
  NEEDS=1
  if should_emit "$1:$2"; then say "attention:$1 $WT $3"; fi
}

# ── small reads ────────────────────────────────────────────────────────────────────────────
# file_mtime <path> → epoch seconds, or "" when it cannot be read (GNU stat first, then BSD/macOS).
file_mtime() {
  local out
  # vazio/falhou/ilegível → "" and the caller treats the age as unknown (no heal)
  out=$(stat -c %Y "$1" 2>/dev/null) || out=""
  case "$out" in ''|*[!0-9]*) out=$(stat -f %m "$1" 2>/dev/null) || out="" ;; esac
  case "$out" in ''|*[!0-9]*) out="" ;; esac
  printf '%s' "$out"
}

# inprogress_op <gitdir> → name of the first operation/lock found, or "".
inprogress_op() {
  local gd="$1" f
  # vazio → "" = nothing in progress; falhou (gitdir not traversable) → the caller already refused
  # a gitdir it could not read, so "" here is a real "nothing there"
  for f in index.lock MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply sequencer; do
    if [ -e "$gd/$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 0
}

# index_tree <gitdir> → the tree the worktree's index would commit, or "" when it cannot be told.
# Computed on a COPY of the index: `git write-tree` on the real one persists the cache-tree, i.e.
# rewrites the file and resets its mtime to now — and that mtime is the evidence for "has anyone
# touched this lately", so looking must never move it.
index_tree() {
  local gd="$1" tmp out=""
  # vazio/falhou (no temp file, copy failed, write-tree failed: corrupt or unmerged index) → ""; the
  # caller reports unknown:write-tree-failed and touches nothing — never "in sync"
  tmp=$(mktemp "${TMPDIR:-/tmp}/mcs-index.XXXXXX" 2>/dev/null) || return 0
  if cp "$gd/index" "$tmp" 2>/dev/null; then
    out=$(gitenv GIT_INDEX_FILE="$tmp" git -C "$WT" write-tree 2>/dev/null) || out=""
  fi
  rm -f "$tmp" 2>/dev/null || :
  printf '%s' "$out"
}

# ── one worktree ───────────────────────────────────────────────────────────────────────────
check_worktree() {
  local gd op idx_tree head_tree head_sha idx_mtime now age log_out hit dirty_rc
  local staged unstaged err new_idx verify_rc diff_rc

  # vazio/falhou → we cannot find the worktree's git dir: attention, nothing touched
  gd=$(g rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  if [ -z "$gd" ] || [ ! -d "$gd" ] || [ ! -r "$gd" ] || [ ! -x "$gd" ]; then
    attention "unknown:gitdir-unreadable" "-" "could not locate this worktree's git dir"; return 0
  fi

  # Index age first, before any git call that might look at (or rewrite) the index.
  # vazio/falhou/ilegível → "" and the age is unknown: attention below, no heal (a worktree whose
  # index age we cannot tell may be someone's live work)
  idx_mtime=$(file_mtime "$gd/index")

  # vazio → no tree for HEAD (unborn branch): attention; falhou → same, nothing touched
  head_tree=$(g rev-parse --verify -q 'HEAD^{tree}' 2>/dev/null) || head_tree=""
  if [ -z "$head_tree" ]; then
    attention "unknown:head-unreadable" "-" "could not read HEAD's tree"; return 0
  fi

  op=$(inprogress_op "$gd")

  # Read-only in-sync test. `git diff-index --cached --quiet HEAD`: 0 → index == HEAD (silent);
  # 1 → they differ (classified below); anything else (git failed: corrupt/unreadable index) →
  # busy or unknown, never "in sync"
  g diff-index --cached --quiet HEAD -- >/dev/null 2>&1; diff_rc=$?
  case "$diff_rc" in
    0) clear_state; return 0 ;;
    1) : ;;
    *) if [ -n "$op" ]; then attention "busy:$op" "-" "operation in progress ($op) and index vs HEAD cannot be compared — left alone"
       else attention "unknown:index-unreadable" "-" "index vs HEAD cannot be compared (corrupt or unmerged index?) — left alone"
       fi
       return 0 ;;
  esac

  # From here: index != HEAD. Only the sections below decide what that means.
  if [ -n "$op" ]; then
    attention "busy:$op" "-" "index != HEAD while $op is present — left alone"; return 0
  fi

  # vazio/falhou → "" = the index cannot be written as a tree: attention, nothing touched
  idx_tree=$(index_tree "$gd")
  if [ -z "$idx_tree" ]; then
    attention "unknown:write-tree-failed" "-" "index != HEAD and the index cannot be written as a tree (corrupt or unmerged?) — left alone"; return 0
  fi

  # vazio/falhou → "" and the age is unknown: attention, no heal
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in ''|*[!0-9]*) now="" ;; esac
  if [ -z "$idx_mtime" ] || [ -z "$now" ]; then
    attention "unknown:index-age" "$idx_tree" "index != HEAD and the index's age cannot be read — left alone"; return 0
  fi
  age=$((now - idx_mtime))
  if [ "$age" -lt 0 ]; then
    attention "unknown:index-age" "$idx_tree" "index != HEAD and the index's mtime is in the future — left alone"; return 0
  fi
  # Touched within the grace period → someone is working here right now; the next sweep looks again.
  if [ "$age" -lt "$GRACE_SECS" ]; then return 0; fi

  # vazio → "" = no HEAD sha (display only); falhou → same, only the log line is poorer
  head_sha=$(g rev-parse --verify -q HEAD 2>/dev/null) || head_sha=""

  # vazio (index tree matches no commit in the window) → `diverged`, not healed;
  # falhou/ilegível (git log failed) → `unknown:log-failed`, not healed
  log_out=$(g log -n "$SCAN_COMMITS" --format='%T %H' HEAD 2>/dev/null) || log_out="__FAILED__"
  if [ "$log_out" = "__FAILED__" ]; then
    attention "unknown:log-failed" "$idx_tree" "index != HEAD and HEAD's history cannot be read — left alone"; return 0
  fi
  hit=$(printf '%s\n' "$log_out" | awk -v t="$idx_tree" '$1 == t && !f { print $2; f = 1 }')

  if [ -z "$hit" ]; then
    # vazio/falhou → "?" in the message only; the decision (do nothing) does not depend on it.
    # Plumbing, not `git diff --cached`: that one runs rename detection, 4.7s on WA's 6.5k staged paths
    staged=$(g diff-index --cached --name-only HEAD -- 2>/dev/null | wc -l | tr -d ' ') || staged="?"
    unstaged=$(g diff --name-only 2>/dev/null | wc -l | tr -d ' ') || unstaged="?"
    attention "diverged" "$idx_tree" "index tree ${idx_tree:0:12} is no commit of ${BRANCH}'s history (last ${SCAN_COMMITS}); staged=${staged:-?} unstaged=${unstaged:-?} — NOT healed, needs a human"
    return 0
  fi

  # `git diff --quiet`: 0 → files match the index (heal ok); 1 → unstaged edits (attention,
  # no heal); anything else (git failed) → attention, no heal
  g diff --quiet >/dev/null 2>&1; dirty_rc=$?
  if [ "$dirty_rc" = "1" ]; then
    attention "stale-dirty" "$idx_tree" "index is the stale snapshot of ${hit:0:12} but there are unstaged edits on top — NOT healed, needs a human"; return 0
  fi
  if [ "$dirty_rc" != "0" ]; then
    attention "unknown:diff-failed" "$idx_tree" "index is the stale snapshot of ${hit:0:12} but the working tree could not be compared — left alone"; return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    say "would-heal $WT (index is the tree of ${hit:0:12}; HEAD ${head_sha:0:12})"; NEEDS=1; return 0
  fi

  # falhou (refused: untracked file in the way, lock, ...) → heal-failed; git leaves the index alone
  err=$(g read-tree -m -u "$idx_tree" "$head_tree" 2>&1) && verify_rc=0 || verify_rc=$?
  if [ "$verify_rc" != "0" ]; then
    attention "heal-failed" "$idx_tree" "read-tree refused: $(printf '%s' "$err" | head -n 1) — left as it was, needs a human"; return 0
  fi

  # vazio/falhou → "" ≠ head_tree: reported as heal-unverified, never as healed
  new_idx=$(g write-tree 2>/dev/null) || new_idx=""
  # `git diff --quiet`: 0 → files match the new index; anything else → heal-unverified
  g diff --quiet >/dev/null 2>&1; verify_rc=$?
  if [ "$new_idx" != "$head_tree" ] || [ "$verify_rc" != "0" ]; then
    attention "heal-unverified" "$idx_tree" "read-tree ran but index/files do not match HEAD's tree afterwards — needs a human"; return 0
  fi
  clear_state
  say "healed $WT (index was the stale snapshot of ${hit:0:12}; now HEAD ${head_sha:0:12})"
}

# ── main ───────────────────────────────────────────────────────────────────────────────────
if [ -z "$BARE" ] || [ ! -d "$BARE" ]; then
  say "attention:unknown:bare-unreadable ${BARE:-<none>} the bare git dir is missing or unreadable"; exit 1
fi

# vazio → no worktree has <branch> checked out: nothing to sync, exit 0; falhou/ilegível (git
# could not list) → attention + exit 1, never "no worktrees"
LIST_RC=0
LIST=$(gb worktree list --porcelain 2>/dev/null) || LIST_RC=$?
if [ "$LIST_RC" != "0" ]; then
  say "attention:unknown:worktree-list-failed $BARE git worktree list failed (rc=$LIST_RC)"; exit 1
fi

TARGETS=""
CUR=""
while IFS= read -r LINE; do
  case "$LINE" in
    "worktree "*) CUR="${LINE#worktree }" ;;
    "branch refs/heads/$BRANCH") [ -n "$CUR" ] && TARGETS="${TARGETS}${CUR}${NL}" ;;
  esac
done <<< "$LIST"

while IFS= read -r WT; do
  [ -n "$WT" ] || continue
  # vazio/falhou (the registered directory is gone or cannot be looked at) → attention, never
  # "nothing to check": a main worktree that vanished is something to know about (`git worktree prune`)
  if [ ! -d "$WT" ]; then attention "unknown:worktree-dir-missing" "-" "registered as having $BRANCH checked out but the directory is missing or unreadable"; continue; fi
  check_worktree
done <<< "$TARGETS"

[ "$NEEDS" = "1" ] && exit 2
exit 0
