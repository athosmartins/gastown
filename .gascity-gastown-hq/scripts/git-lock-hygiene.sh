#!/usr/bin/env bash
# git-lock-hygiene.sh — imp18: Git-lock hygiene + per-repo mutation mutex
#
# WHY (imp18): Stale .git lock files (index.lock, MERGE_HEAD, rebase-merge/, etc.)
# from crashed/killed git operations halt auto-rebase (and all git mutations) for an
# entire rig forever — the clean-tree guard in the gate dispatcher (imp22) correctly
# detects them but only SKIPs; nothing ever HEALs them. A human must manually `rm`
# them. Stage-5 auto-rebase (gate dispatcher) makes this worse by adding concurrent
# git mutations during live sweeps.
#
# THIS SCRIPT provides two things:
#
# PART 1 — Stale git-lock janitor (daemon)
#   Every GIT_LOCK_SWEEP_SEC seconds, scans each rig's .git directory for lock
#   files/dirs left by interrupted git operations. Declares a lock stale when:
#     (a) it is older than GIT_LOCK_STALE_AGE_SEC (default: 300 s), AND
#     (b) no live git process is working on THIS repository — decided per process by its
#         explicit git dir (--git-dir / GIT_DIR) or else its cwd (with -C applied) / absolute argv
#         paths resolving to this repo as the nearest enclosing .git, not by a substring of the
#         ps line (ga-hl3xlw: crew/* clones nested under a rig root kept its index.lock alive
#         forever) — AND, for *.lock files, nobody has the file open.
#         When ps/lsof cannot answer, the lock is kept. Each skip is logged (skipped_live).
#   Files cleaned (LOCKS — a lock has no "paused for a human" reading, so age + no
#   process is proof enough):
#     .git/index.lock         — always a temp file (git crashes leave this behind)
#     .git/packed-refs.lock   — in-progress pack-refs, stale after crash
#     .git/shallow.lock       — in-progress shallow fetch, stale after crash
#     .git/config.lock        — in-progress config write, stale after crash
#     .git/index.<word>.<pid>.lock — PID-tagged custom index lock (e.g.
#                             index.stash.15909.lock), left behind by a script
#                             that stashes via its own GIT_INDEX_FILE=<path>.$$
#                             and crashes mid-write. Not git's native name (git
#                             itself only ever writes index.lock) — this shape
#                             comes from wrapper tooling. The PID embedded in
#                             the filename is checked directly (kill -0) rather
#                             than the repo-wide live-process grep used above:
#                             a stale lock here is removed even while OTHER git
#                             activity is ongoing in the same repo, but NEVER
#                             while its own owning PID is still alive (ga-2xorq).
#   REPORTED, NOT REMOVED (OPERATION STATE — ga-892qy1; opt-in removal: GIT_LOCK_STATE_REMOVE=1):
#     .git/MERGE_HEAD         — in-progress merge
#     .git/CHERRY_PICK_HEAD   — in-progress cherry-pick
#     .git/REVERT_HEAD        — in-progress revert
#     .git/rebase-merge/      — in-progress rebase (merge strategy)
#     .git/rebase-apply/      — in-progress rebase (apply strategy) / git-am
#   These used to be removed on the same age + no-process rule as the locks. That rule
#   cannot tell a CRASHED operation from one PAUSED FOR A HUMAN (a conflict waiting to be
#   resolved, an editor open, a ten-minute break): both have no git process. Removing the
#   state of a paused operation is silent data loss — without MERGE_HEAD the next commit
#   comes out with ONE parent (the merge becomes an ordinary commit); without rebase-merge/
#   the rebase in flight is gone. It was latent while the liveness check was "always alive"
#   by accident on the roots with nested crew clones (HQ, WA); ga-hl3xlw made the check
#   exact and so made the removal reachable there. Measured 2026-10-02 over the whole log
#   (40k lines): the janitor had removed only index/PID locks on the real roots, never one of
#   these — the hazard was latent, not realised.
#   Now an item past the same two gates is LOGGED (event stale_state_found: label, path, repo,
#   age_sec — every sweep, counted in the sweep summary as stale_state) and NOTIFIED (once per
#   item, again after GIT_LOCK_STATE_RENOTIFY_SEC, again if a new operation replaces it at the
#   same path), with the abort command in the text. A human or crew decides. Only
#   GIT_LOCK_STATE_REMOVE=1 restores the old removal (explicit opt-in; the item is then removed
#   and logged as 'removed', not reported). Cost of the default: a genuinely crashed merge/rebase in a shared root is no
#   longer healed automatically. While MERGE_HEAD / CHERRY_PICK_HEAD / rebase-merge/ /
#   rebase-apply/ sit there, the gate dispatcher's clean-tree guard (quality-gate-dispatcher.sh,
#   "Clean-tree guard") skips its AUTO-REBASE in that repo and records the attempt as a
#   transient out-of-envelope conflict (it does not look at REVERT_HEAD); it does not stop the
#   repo being used any other way. Someone has to abort it, which the notification asks for.
#   NOT touched: ORIG_HEAD, FETCH_HEAD, HEAD — valid post-op artifacts.
#
# PART 2 — Per-repo git mutation mutex (lib, source with GIT_LOCK_HYGIENE_LIB=1)
#   POSIX-atomic mkdir-based locking that serializes git mutations per repository.
#   The gate dispatcher's auto-rebase uses this so concurrent callers never collide.
#   Lock state lives in /tmp/gc-git-repo-mutex/<slug>/
#
#   API:
#     git_mutex_acquire <repo_path>          → 0=locked, 1=held by live owner
#     git_mutex_release <repo_path>          → release our lock
#     git_with_mutex <repo_path> <cmd...>    → run cmd if we hold the lock (skip on fail)
#
# Usage:
#   git-lock-hygiene.sh              — run one janitor sweep
#   git-lock-hygiene.sh --selftest   — run regression tests (exit 0 = pass)
#   GIT_LOCK_HYGIENE_LIB=1 source git-lock-hygiene.sh — load lib, skip sweep. Lib mode is PURE
#     (ga-kimlod): it calls no gc, no notify, writes nothing to stdout or the hygiene log. That
#     also means it does NOT resolve GIT_LOCK_RIG_ROOTS from `gc rig list`: it stays the static
#     default (or the caller's value). Only the sweep reads it, so a sourcer that wants the live
#     rig list must resolve it itself (scripts/lib/rig-stores.sh), not rely on this file.
#
# Env knobs:
#   GIT_LOCK_RIG_ROOTS         colon-separated repo roots to scan (see default below)
#   GIT_LOCK_STALE_AGE_SEC     min age (s) before a lock is considered stale (def 300)
#   GIT_LOCK_ENABLED           0 = skip janitor (kill-switch, def 1)
#   GIT_LOCK_DRY_RUN           1 = log what would be removed, don't remove (def 0).
#                              Operation-state items are reported, not removed (unless
#                              GIT_LOCK_STATE_REMOVE=1); under dry run the report is still LOGGED
#                              (stale_state_found) but not notified.
#   GIT_LOCK_STATE_REMOVE      1 = also remove in-progress-operation state (MERGE_HEAD, rebase-*, ...)
#                              when aged and no live git (def 0: report only, see ga-892qy1)
#   GIT_LOCK_STATE_DIR         where the once-per-item notify markers live (def
#                              $CITY/.gc/state/git-lock-hygiene-state-notified)
#   GIT_LOCK_STATE_RENOTIFY_SEC  re-announce a still-present operation-state item after this
#                              many seconds (def 43200 = 12 h)
#   GIT_REPO_MUTEX_ENABLED     0 = mutex is a no-op (def 1)
#   GIT_REPO_MUTEX_MAX_AGE     age (s) before a held mutex is reclaimed as stale (def 600)
#   GIT_LOCK_PROCESS_CHECK_FN  fn override for process-liveness check (tests only)

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
NOTIFY_BIN="${NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
LOG="${GIT_LOCK_LOG:-${CITY}/.gc/logs/git-lock-hygiene.jsonl}"
ENABLED="${GIT_LOCK_ENABLED:-1}"
DRY_RUN="${GIT_LOCK_DRY_RUN:-0}"
STALE_AGE="${GIT_LOCK_STALE_AGE_SEC:-300}"
GIT_LOCK_STATE_DIR="${GIT_LOCK_STATE_DIR:-${CITY}/.gc/state/git-lock-hygiene-state-notified}"
GIT_LOCK_STATE_RENOTIFY_SEC="${GIT_LOCK_STATE_RENOTIFY_SEC:-43200}"
GIT_REPO_MUTEX_ENABLED="${GIT_REPO_MUTEX_ENABLED:-1}"
GIT_REPO_MUTEX_MAX_AGE="${GIT_REPO_MUTEX_MAX_AGE:-600}"
GIT_REPO_MUTEX_BASE="${GIT_REPO_MUTEX_BASE:-/tmp/gc-git-repo-mutex}"

# Rig roots — colon-separated list of git repo roots to scan.
# The town root /Users/athos/gt covers HQ (.gascity-gastown-hq) and gastown subrepo.
# Captured BEFORE the default-fill: the only point that can tell "caller passed
# GIT_LOCK_RIG_ROOTS" apart from "using the built-in default" (ga-wz03iq test seam,
# same pattern as lifecycle-coherence-janitor.sh/ga-3xfndz).
_GIT_LOCK_ROOTS_CALLER_SET=0
[ -n "${GIT_LOCK_RIG_ROOTS:-}" ] && _GIT_LOCK_ROOTS_CALLER_SET=1
GIT_LOCK_RIG_ROOTS="${GIT_LOCK_RIG_ROOTS:-/Users/athos/gt:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers}"
GIT_LOCK_GC="${GIT_LOCK_GC:-gc}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_log_json() {
  # emit a JSON event to LOG; always succeeds (LOG write failures are non-fatal)
  printf '%s\n' "$*" >> "$LOG" 2>/dev/null || true
}

# ── GIT_LOCK_RIG_ROOTS: derived from the live rig list, not hardcoded (ga-wz03iq) ──
# Same bug CLASS as ga-3xfndz (lifecycle-coherence-janitor.sh): the static 3-root
# default above never followed `gc rig list` past its original HQ/WA/PS shape, so
# a rig added since (lexbh, marketing, gastown, deacon) was silently never scanned
# for stale locks. Widening this is safe even for a rig whose git repo isn't at
# the bare rig-root path — lexbh/gastown are Family-A container rigs
# (rig-repo-topology memory) whose real .git lives in a nested crew/refinery
# clone, not at this root — because _scan_repo()'s own `[ -d "$git_dir" ]` check
# (git_dir="$repo/.git") already no-ops harmlessly when a root isn't a git repo
# directly: an inapplicable rig root costs one skipped iteration, never a false
# action. `marketing` (a genuine self-repo rig, Family B) is real new coverage.
# Skipped under --selftest for the same reason as ga-3xfndz: this script's own
# --selftest exercises _scan_repo()/_is_stale() in-process and must not shell
# out to a real `gc rig list` on every hermetic run.
# ga-kimlod: ALSO skipped in lib mode (GIT_LOCK_HYGIENE_LIB=1). This block used to run BEFORE the
# lib-mode `return` below, so every `source` of this file — quality-gate-dispatcher.sh does it on
# each cycle, StartInterval=60 — paid a `gc rig list` of up to 20 s when Dolt is busiest, and on
# failure called notify, whose STDOUT ("Logged for digest ...") leaked into the sourcer (measured
# 25/09: 50 of 120 runs at load ~50; it turned gate-verdict-timeout-scale.selftest.sh flaky,
# ga-5hw36b). Skipping, not deferring, is safe because nothing outside the sweep reads
# GIT_LOCK_RIG_ROOTS: the only reader is the sweep loop at the bottom of this file, after the lib
# return, and the external sourcers (git-deploy-pull.sh) only PRE-SET it. Verified by grep
# across .sh/.py/.toml/.plist in the repo. The 20 s bound and the notify stay exactly as they were
# for the sweep — this changes who pays for them, not what they do.
if [ "$_GIT_LOCK_ROOTS_CALLER_SET" != "1" ] && [ "${1:-}" != "--selftest" ] && [ "${GIT_LOCK_HYGIENE_LIB:-0}" != "1" ]; then
  _git_lock_rig_stores_lib="${CITY}/scripts/lib/rig-stores.sh"
  if [ -r "$_git_lock_rig_stores_lib" ]; then
    . "$_git_lock_rig_stores_lib"
    if _glh_rig_paths=$(rig_stores_paths "$GIT_LOCK_GC" 20 " "); then
      # rig_stores_paths gives bd-STORE paths, which are NOT the same as git repo
      # roots: HQ's store (.gascity-gastown-hq) has no .git of its own — the real
      # repo root is its parent /Users/athos/gt — and lexbh/gastown are Family-A
      # container rigs (rig-repo-topology memory) with the same kind of gap.
      # Resolving each candidate through git itself (rather than assuming
      # rig-path==repo-root, the exact mistake that memory warns against) fixes
      # this: `rev-parse --show-toplevel` walks up to the real root, returns the
      # path unchanged if it's already one, or fails (2s-bounded) for a path
      # with no work tree. "No work tree" covers two different shapes, handled
      # differently below: a rig with no git reachable at all (deacon has none
      # of its own — nothing to scan there), and a rig whose own .git is a
      # gitlink into a BARE container repo (property_scrapers/lexbh's ".git"
      # -> ".repo.git", both core.bare=true — verified live 2026-09-15,
      # ga-92iqox). The latter is a real, scannable git-dir; show-toplevel
      # fails on it only because a bare repo has no work tree, not because
      # there's nothing there. Confirmed live: before this fix, property_scrapers
      # and lexbh were silently absent from the resolved root list every sweep
      # — the janitor's stale-lock coverage for both had been a no-op since
      # they were added.
      # Deduplicated: gascity/gastown/deacon all resolve to the same
      # /Users/athos/gt when none has its own .git — scanning it 3x would be
      # wasted (not wrong; _scan_repo is idempotent), never scanned twice here.
      #
      # ga-92iqox OUTAGE (2026-09-15 06:09-06:34, revert 8e5b87763): an
      # earlier version of this exact fix dropped the `|| continue` guard
      # below for a bare `_glh_top=$(...)` assignment + separate `[ -z ]`
      # check. quality-gate-dispatcher.sh sources this file under its own
      # `set -euo pipefail` — a bare assignment whose command substitution
      # fails is a live errexit trigger there and killed the dispatcher
      # before it logged a single line (regression test: T23-T25 below,
      # plus the Mayor's own live trace on the ga-92iqox bead). The
      # `|| _glh_top=""` immediately below is NOT cosmetic — it is what
      # keeps this assignment inside bash's unconditional "part of an ||
      # list" exemption from -e, independent of whatever shell options or
      # environment the caller happens to source this file under.
      # SELFTEST-EXTRACT root-resolve-loop: BEGIN
      # (kept extractable+runnable standalone by T23-T25 below, deliberately
      # size-independent of the rest of this file — see those tests' own
      # header comment for why sourcing the WHOLE file is not a reliable way
      # to regression-test this specific errexit behavior.)
      _glh_resolved=""
      for _glh_p in $_glh_rig_paths; do
        _glh_top=$(timeout 2 git -C "$_glh_p" rev-parse --show-toplevel 2>/dev/null) || _glh_top=""
        if [ -z "$_glh_top" ]; then
          # No work-tree toplevel. If this exact path carries its own .git
          # (file or dir), it's the bare-container-gitlink shape above — keep
          # the path itself as the scan root; _scan_repo resolves the gitlink
          # to the real git-dir. Otherwise there's truly no git here — skip.
          [ -e "${_glh_p}/.git" ] || continue
          _glh_top="$_glh_p"
        fi
        case " $_glh_resolved " in
          *" $_glh_top "*) ;;  # already have this root
          *) _glh_resolved="${_glh_resolved:+$_glh_resolved }$_glh_top" ;;
        esac
      done
      # SELFTEST-EXTRACT root-resolve-loop: END
      if [ -n "$_glh_resolved" ]; then
        GIT_LOCK_RIG_ROOTS="$(printf '%s' "$_glh_resolved" | tr ' ' ':')"
      else
        _log_json "{\"ts\":\"$(ts)\",\"event\":\"degraded\",\"reason\":\"gc rig list ok but no rig resolved to a git toplevel - using static rig-root fallback\",\"fallback\":\"$GIT_LOCK_RIG_ROOTS\"}"
      fi
    else
      _log_json "{\"ts\":\"$(ts)\",\"event\":\"degraded\",\"reason\":\"gc rig list failed/timed out/empty - using static rig-root fallback\",\"fallback\":\"$GIT_LOCK_RIG_ROOTS\"}"
      [ -x "$NOTIFY_BIN" ] && "$NOTIFY_BIN" -t "Git-lock hygiene" -p 4 "🚨 gc rig list falhou/vazio — usando lista estatica de fallback, cobertura pode estar incompleta" 2>/dev/null || true
    fi
  fi
fi

# Age (s) of a path's mtime; 999999999 if missing.
_path_age() {
  local p="$1" mt now
  now=$(date +%s)
  mt=$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo "")
  [ -z "$mt" ] && echo 999999999 && return
  echo $(( now - mt ))
}

# mtime (epoch s) of a path; empty if it cannot be read. Unlike _path_age this never invents a
# value for "missing" — the caller uses it as an identity, not a duration.
_path_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true
}

# Run <cmd...> under `timeout <secs>`: rc 124 = deadline hit. Without `timeout` there is no way to
# enforce the deadline, and running lsof unbounded would let one hung on a stale mount stall the
# whole sweep with no signal — so rc 127, which every caller reads as "cannot tell" (lock kept,
# skip logged with the rc).
_glh_bounded() {
  local secs="$1"; shift
  command -v timeout >/dev/null 2>&1 || return 127
  timeout "$secs" "$@"
}

# Canonical form (symlinks resolved, no `..`) of a directory; fails if it isn't one.
_glh_canon_dir() {
  ( cd -P -- "$1" 2>/dev/null && pwd -P )
}

# The repo an absolute path belongs to: the nearest directory — the path itself or an ancestor —
# that carries its own `.git` (a DIRECTORY for a clone, a FILE for a linked worktree or a
# bare-container gitlink). <root>/crew/x belongs to crew/x, NOT to <root>; <root>/lv8-other is not
# <root>/lv8. Prints it canonical; fails when the path is relative or sits under no repo.
_glh_enclosing_repo() {
  local d="$1"
  case "$d" in /*) ;; *) return 1 ;; esac
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="${d%/*}"; [ -n "$d" ] || d="/"; done
  d=$(_glh_canon_dir "$d") || return 1
  while :; do
    [ -e "$d/.git" ] && { printf '%s' "$d"; return 0; }
    [ "$d" = "/" ] && return 1
    d="${d%/*}"; [ -n "$d" ] || d="/"
  done
}

# Why the last liveness question answered "live / cannot tell" — read by _is_stale to log the skip.
# Plain words and pids only: it is spliced into a JSON line.
_GLH_LIVE_REASON=""
# 1 when the answer "keep it" is a "could not find out" rather than "found a live one". Set by
# _glh_unknown at every could-not-tell site and counted from this flag — never by matching the
# wording of the reason, which drifts (a reason that said "cannot list processes" matched none of
# the phrases a text match looked for, so the broken-ps case, the one that keeps EVERY lock, would
# have read undetermined=0).
_GLH_LIVE_UNKNOWN=0
_glh_unknown() { _GLH_LIVE_REASON="$1"; _GLH_LIVE_UNKNOWN=1; }

# Per-sweep tally. _scan_repo runs inside $(...), so a variable would die with that subshell; the
# sweep points this at a scratch file and reads it back for its summary line. Unset (lib mode,
# selftest) = counting is off, and every caller must work exactly the same.
_GLH_COUNT_FILE=""
_glh_count() {
  if [ -n "${_GLH_COUNT_FILE:-}" ]; then printf '%s\n' "$1" >> "$_GLH_COUNT_FILE" 2>/dev/null || true; fi
  return 0
}

# Returns 0 if a live git process is working on repo_path, OR if we could not find out.
# Returns 1 only when we looked and there is none. Three states, and "cannot tell" must not
# collapse into "none": the caller deletes on 1, so under doubt the answer is 0 (keep the lock).
#
# A process counts when it IS git (executable `git` or a `git-*` helper — macOS ps reports argv[0]
# as comm) AND it resolves to THIS repo, exactly. Git picks its repository in this order, and so
# do we: (1) an explicit git dir — `--git-dir=<p>` in argv or GIT_DIR=<p> in the environment
# (children of `git --git-dir=X` inherit it) — is DECISIVE: the process counts iff <p> is this
# repo's own git dir, wherever its cwd and other args point (a `git --git-dir=<other>/.git gc`
# running from the HQ store dir is not on the HQ repo; <root>/.repo.git is not <root>/.git);
# (2) otherwise its cwd — after applying its `-C <p>` chain, relative ones composed onto the cwd —
# or an absolute path in its argv (a pathspec, ...), lies under repo_path with repo_path as the
# NEAREST enclosing repo (_glh_enclosing_repo).
# Not a substring match on the ps line — that counted crew/* clones nested under the root,
# tmux/claude/zsh lines mentioning the path, a sibling whose path shares a prefix, and the grep's
# own command line (ga-hl3xlw: a 0-byte index.lock sat for ~3h because something always matched).
# Conservative where it cannot be exact, on purpose: a git dir we cannot resolve falls back to
# (2); a `-C` token that is really a verb option (`git commit -C <rev>`) is read as a chdir, which
# adds attribution (it is a path under the cwd) — and can drop a process only in the contrived case
# of ALSO passing a relative --git-dir and naming a revision that is a directory with its own .git.
# Limits, stated so nobody assumes more: ps flattens argv, so a repo path containing spaces is not
# matched from argv (this city has none); GIT_DIR is read with `ps -E`, which macOS hides for
# SIP-protected binaries — measured readable for Homebrew git, NOT measured for other gits, and
# when hidden the process falls back to (2); GIT_INDEX_FILE-only steering is not visible at all —
# for lock FILES the open-file check in _glh_lock_held_open adds a second, independent signal.
# A git that really is working on the root — even a read-only for-each-ref/fetch poll — still
# defers that sweep; the next one retries, and the skip is logged (skipped_live) with its pid.
# The same goes for a PERSISTENT git (an fsmonitor--daemon standing in the root): it would defer
# every sweep, visibly — nothing here enables fsmonitor (measured 2026-10-02), and the log names it.
# Tests may override via GIT_LOCK_PROCESS_CHECK_FN.
_git_repo_has_live_process() {
  local repo="$1" want wantgd gl psout gitpids pidlist cwdmap lrc pid cwd args toks tok cand gd nxt cgd eff
  _GLH_LIVE_REASON=""; _GLH_LIVE_UNKNOWN=0
  if [ -n "${GIT_LOCK_PROCESS_CHECK_FN:-}" ]; then
    "$GIT_LOCK_PROCESS_CHECK_FN" "$repo"; return $?
  fi
  want=$(_glh_canon_dir "$repo") || { _glh_unknown "cannot resolve the repo path"; return 0; }
  # This repo's own git dir: <root>/.git, or what a gitlink .git FILE points at (bare containers).
  wantgd=""
  if [ -d "$want/.git" ]; then
    wantgd=$(_glh_canon_dir "$want/.git") || wantgd=""
  elif [ -f "$want/.git" ]; then
    gl=$(sed -n 's/^gitdir: *//p' "$want/.git" 2>/dev/null | head -1)
    case "$gl" in /*|"") ;; *) gl="$want/$gl" ;; esac
    [ -n "$gl" ] && { wantgd=$(_glh_canon_dir "$gl") || wantgd=""; }
  fi
  psout=$(ps -axo pid=,comm= 2>/dev/null) || { _glh_unknown "ps failed - cannot list processes"; return 0; }
  # A process table with no processes in it (not even this shell) is a broken ps, not an empty machine.
  [ -n "$psout" ] || { _glh_unknown "ps listed no processes at all - cannot tell"; return 0; }
  gitpids=$(printf '%s\n' "$psout" | awk '
    { pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); n = $0; sub(/.*\//, "", n)
      if (n == "git" || n ~ /^git-/) print pid }')
  [ -n "$gitpids" ] || return 1   # no git process anywhere → none on this repo

  pidlist=$(printf '%s\n' "$gitpids" | tr '\n' ',')
  pidlist="${pidlist%,}"
  # rc 1 = some pid vanished / has no readable cwd (sorted out per pid below); anything else
  # (deadline 124, lsof missing 127, ...) = we cannot tell.
  cwdmap=$(_glh_bounded 10 lsof -a -d cwd -Fpn -p "$pidlist" 2>/dev/null) && lrc=0 || lrc=$?
  case "$lrc" in
    0|1) ;;
    *) _glh_unknown "lsof failed or timed out (rc=${lrc}) - cannot read cwds"; return 0 ;;
  esac

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cwd=$(printf '%s\n' "$cwdmap" | awk -v p="p${pid}" '
      $0 == p { f = 1; next }  /^p/ { f = 0 }  f && /^n/ { print substr($0, 2); exit }')
    if [ -z "$cwd" ]; then
      # No cwd reported: the process exited since ps listed it (fine) — or it is alive and its
      # cwd is unreadable (not fine: we cannot tell where it works).
      ps -p "$pid" -o pid= >/dev/null 2>&1 || continue
      _glh_unknown "git pid ${pid} cwd unreadable - cannot tell which repo it works on"; return 0
    fi
    args=$(ps -p "$pid" -o args= 2>/dev/null) || continue   # exited meanwhile
    toks=$(printf '%s' "$args" | tr -s ' \t' '\n')

    # Where git really works: its cwd with the `-C <p>` chain applied (relative ones compose onto
    # the cwd, as git does), and an explicit `--git-dir=<p>` / `--git-dir <p>` from argv (last wins).
    eff="$cwd"; gd=""; nxt=""
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      if [ "$nxt" = C ]; then
        case "$tok" in /*) eff="$tok" ;; *) eff="$eff/$tok" ;; esac; nxt=""
      elif [ "$nxt" = G ]; then
        gd="$tok"; nxt=""
      else
        case "$tok" in -C) nxt=C ;; --git-dir) nxt=G ;; --git-dir=*) gd="${tok#--git-dir=}" ;; esac
      fi
    done <<< "$toks"

    # (1) explicit git dir: decisive. argv first, then GIT_DIR from the environment.
    if [ -z "$gd" ]; then
      # awk reads to EOF on purpose: an early-exit reader (grep -m1 / awk exit) SIGPIPEs ps/tr and
      # turns the pipeline's status into 141 under pipefail (ga-5bxuam).
      gd=$(ps -E -p "$pid" -o args= 2>/dev/null | tr -s ' \t' '\n' \
           | awk '/^GIT_DIR=/ && !s { print substr($0, 9); s = 1 }') || gd=""
    fi
    if [ -n "$gd" ] && [ -n "$wantgd" ]; then
      case "$gd" in /*) ;; *) gd="$eff/$gd" ;; esac   # git applies -C before it reads a relative git dir
      cgd=$(_glh_canon_dir "$gd") || cgd=""
      if [ -n "$cgd" ]; then
        if [ "$cgd" = "$wantgd" ]; then
          _GLH_LIVE_REASON="git pid ${pid} git-dir is this repo"; return 0
        fi
        continue   # explicitly another git dir: wherever its cwd/argv point, not this repo's
      fi
      # a git dir we cannot resolve: fall through to the cwd/argv attribution (keeps, never drops)
    fi

    # (2) no explicit git dir: where does it stand, and which repo does its argv name?
    if [ "$(_glh_enclosing_repo "$cwd")" = "$want" ]; then
      _GLH_LIVE_REASON="git pid ${pid} cwd in repo"; return 0
    fi
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      cand="$tok"; case "$tok" in *=*) cand="${tok#*=}" ;; esac   # --git-dir=<p>, -c core.x=<p>
      case "$cand" in /*) ;; *) continue ;; esac
      if [ "$(_glh_enclosing_repo "$cand")" = "$want" ]; then
        _GLH_LIVE_REASON="git pid ${pid} argv names repo"; return 0
      fi
    done <<< "$toks"
    if [ "$eff" != "$cwd" ] && [ "$(_glh_enclosing_repo "$eff")" = "$want" ]; then
      _GLH_LIVE_REASON="git pid ${pid} -C resolves into repo"; return 0
    fi
  done <<< "$gitpids"
  return 1
}

# For lock FILES (*.lock): is some process holding this exact file open? A second, independent
# signal next to _git_repo_has_live_process, needing no argv/cwd guessing: it sees what that
# cannot (a linked worktree sharing packed-refs.lock/config.lock with the root, a git steered by
# GIT_INDEX_FILE, a libgit2 tool, a git writing the file right now).
# It is NOT sufficient on its own, and no comment may suggest otherwise: measured 2026-10-02 with
# `GIT_EDITOR='sleep 7; :' git commit <path>`, a git parked in its editor leaves .git/index.lock in
# place with NO open fd (lsof empty) — only the process check protects that lock.
# lsof run as this user sees this user's descriptors only: "nobody" means nobody I can see.
# Returns 0 if held OR if we could not tell, 1 only when lsof answered "nobody" (rc 1, no output).
_glh_lock_held_open() {
  local f="$1" out rc
  [ -f "$f" ] || return 1
  case "${f##*/}" in *.lock) ;; *) return 1 ;; esac
  out=$(_glh_bounded 10 lsof -t -- "$f" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    _GLH_LIVE_REASON="lock held open by pid ${out%%$'\n'*}"; return 0
  fi
  [ "$rc" -eq 1 ] && [ -z "$out" ] && return 1
  _glh_unknown "lsof failed or timed out (rc=${rc}) - cannot tell who holds the lock"; return 0
}

# Determine if a lock file or directory is stale:
# age > STALE_AGE AND no live git process on the owning repo AND (for *.lock files) nobody
# holds the file open. Every skip of an aged lock is logged with its reason: before ga-hl3xlw a
# lock kept for a "live process" left no trace, so a false positive looked exactly like health.
_is_stale() {
  local path="$1" repo="$2"
  [ -e "$path" ] || return 1          # doesn't exist → not stale
  local age
  age=$(_path_age "$path")
  [ "$age" -lt "$STALE_AGE" ] && return 1   # too young
  _GLH_LIVE_REASON=""; _GLH_LIVE_UNKNOWN=0
  if _git_repo_has_live_process "$repo" || _glh_lock_held_open "$path"; then
    _log_json "{\"ts\":\"$(ts)\",\"event\":\"skipped_live\",\"path\":\"${path}\",\"repo\":\"${repo}\",\"age_sec\":${age},\"reason\":\"${_GLH_LIVE_REASON:-live git process}\"}"
    _glh_count skipped_live
    [ "$_GLH_LIVE_UNKNOWN" = 1 ] && _glh_count undetermined
    return 1   # live process / lock held / cannot tell → skip
  fi
  # The probe above can take seconds (ps, lsof up to 10 s, per-pid ps): what we measured at the
  # top may have been replaced since — a lock removed and re-created by a NEW git is young again.
  # Re-read before anyone deletes; a path that vanished or got younger is not ours to remove.
  [ -e "$path" ] || return 1
  age=$(_path_age "$path")
  [ "$age" -lt "$STALE_AGE" ] && return 1
  return 0   # stale
}

# Stale item found: remove it — except in-progress-OPERATION state, which is reported (see the
# header: a paused merge/rebase looks exactly like a crashed one) unless GIT_LOCK_STATE_REMOVE=1.
# $4 = the abort command to name in the report's notification (state items only). Returns 0 if
# removed (or would be, under DRY_RUN), 1 if it was left in place on purpose.
_glh_reap() {
  local path="$1" repo="$2" label="$3" hint="${4:-}"
  case "${path##*/}" in
    MERGE_HEAD|CHERRY_PICK_HEAD|REVERT_HEAD|rebase-merge|rebase-apply)
      if [ "${GIT_LOCK_STATE_REMOVE:-0}" != "1" ]; then
        _report_stale_state "$path" "$repo" "$label" "$hint"
        return 1
      fi ;;
  esac
  _remove_stale_lock "$path" "$repo" "$label"
}

# Returns 0 if pid is confirmed dead (kill -0 fails with no-such-process),
# 1 if alive OR if pid couldn't be validated. Unknown must NOT collapse into
# "dead" — that would make an unparseable pid removable, the wrong direction
# for a destructive path. Mirrors _mutex_holder_dead's fail-safe shape below.
_pid_is_dead() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;   # not a valid pid → treat as alive (don't remove)
  esac
  kill -0 "$pid" 2>/dev/null && return 1   # alive
  return 0                                  # confirmed dead
}

# Remove a stale lock file (or directory) safely.
# $1 = path, $2 = repo root, $3 = label for logging.
# All human-readable output goes to stderr; callers capture nothing from stdout.
_remove_stale_lock() {
  local path="$1" repo="$2" label="$3" age rc=0
  age=$(_path_age "$path")
  # DRY_RUN: check both the env var (test override) and the script-level variable.
  local _dry="${GIT_LOCK_DRY_RUN:-${DRY_RUN:-0}}"
  if [ "$_dry" = "1" ]; then
    echo "[git-lock-hygiene] DRY_RUN: would remove stale ${label} (age=${age}s): ${path}" >&2
    _log_json "{\"ts\":\"$(ts)\",\"event\":\"would_remove\",\"label\":\"${label}\",\"path\":\"${path}\",\"repo\":\"${repo}\",\"age_sec\":${age}}"
    return 0
  fi
  if [ -d "$path" ]; then
    rm -rf "$path" 2>/dev/null && rc=0 || rc=$?
  else
    rm -f "$path" 2>/dev/null && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    echo "[git-lock-hygiene] REMOVED stale ${label} (age=${age}s): ${path}" >&2
    _log_json "{\"ts\":\"$(ts)\",\"event\":\"removed\",\"label\":\"${label}\",\"path\":\"${path}\",\"repo\":\"${repo}\",\"age_sec\":${age}}"
  else
    echo "[git-lock-hygiene] WARN: could not remove ${label}: ${path} (rc=${rc})" >&2
    _log_json "{\"ts\":\"$(ts)\",\"event\":\"remove_failed\",\"label\":\"${label}\",\"path\":\"${path}\",\"repo\":\"${repo}\",\"age_sec\":${age},\"rc\":${rc}}"
  fi
}

# Report — do not remove — an in-progress operation (merge / cherry-pick / revert / rebase) that
# has passed the same age + no-live-process gates as a stale lock (ga-892qy1; see the header for why
# those gates cannot prove it was abandoned rather than paused for a human). Reached from _glh_reap,
# which removes instead only under GIT_LOCK_STATE_REMOVE=1.
# $1 = path, $2 = repo root, $3 = label, $4 = the abort command to name in the notification.
# Output contract: stderr + $LOG + NOTIFY_BIN only. STDOUT is empty — _scan_repo's caller captures
# it as the removed-count, and the real notify prints "Logged for digest ..." on stdout (ga-kimlod
# measured that leak), so the notify call below discards both streams.
_report_stale_state() {
  local path="$1" repo="$2" label="$3" hint="$4" age mt key marker prev age_json age_txt
  # Three states for the item, never two. Gone (finished or aborted between _is_stale and here):
  # nothing left to report — and, above all, not a report with an invented age (_path_age answers
  # 999999999 for "cannot stat", which would read as a very old stuck operation). Present with a
  # readable mtime: report its age. Present but mtime unreadable: still report it — it is there —
  # with the age stated as UNKNOWN (null in the log), never as a number.
  [ -e "$path" ] || return 0
  _glh_count stale_state     # the sweep summary's tally: items present and left alone (not the vanished)
  mt=$(_path_mtime "$path")
  if [ -n "$mt" ]; then
    age=$(( $(date +%s) - mt )); age_json="$age"; age_txt="${age}s"
  else
    age=""; mt="unknown"; age_json="null"; age_txt="unknown"
  fi
  local _dry="${GIT_LOCK_DRY_RUN:-${DRY_RUN:-0}}"
  echo "[git-lock-hygiene] STALE STATE, NOT removed (may be paused for a human) — ${label} (age=${age_txt}): ${path}" >&2
  # Logged on EVERY sweep, not just the first: the state over time stays reconstructable and
  # the sweep already writes a line per run. Only the notification is deduped.
  _log_json "{\"ts\":\"$(ts)\",\"event\":\"stale_state_found\",\"label\":\"${label}\",\"path\":\"${path}\",\"repo\":\"${repo}\",\"age_sec\":${age_json},\"dry_run\":\"${_dry}\"}"
  [ "$_dry" = "1" ] && return 0            # same rule as the sweep: no notify under dry run
  if [ ! -x "$NOTIFY_BIN" ]; then
    # Without a notifier the detection exists only in the log and this stderr line: say so, so a
    # missing binary is not mistaken for "nobody was told because there was nothing to tell".
    echo "[git-lock-hygiene] NOT announced — NOTIFY_BIN is not executable (${NOTIFY_BIN}); the item above is only in ${LOG}" >&2
    return 0
  fi

  # Dedupe. A paused merge can sit for an afternoon and the sweep runs every ~5.5 min. The marker
  # holds the item's mtime ("unknown" when it could not be read): same value + inside the window =
  # already announced; a different value is a NEW operation at the same path and is announced at
  # once.
  key=$(printf '%s' "$path" | tr '/ :' '___')
  marker="${GIT_LOCK_STATE_DIR}/${key}"
  if [ -f "$marker" ]; then
    prev=$(head -n1 "$marker" 2>/dev/null || true)
    if [ "$prev" = "$mt" ] && [ "$(_path_age "$marker")" -lt "$GIT_LOCK_STATE_RENOTIFY_SEC" ]; then
      return 0
    fi
  fi
  # The marker is written only AFTER a notify that succeeded: a failed notify is retried next sweep
  # rather than recorded as delivered. If the marker cannot be written, the cost is a repeat notice
  # per sweep — loud, never silent.
  if [ -n "$age" ]; then age_txt="ha $(( age / 60 ))min"; else age_txt="ha tempo desconhecido"; fi
  if "$NOTIFY_BIN" -t "Git-lock hygiene" -p 3 \
       "Operacao git parada ${age_txt} em ${repo}: ${label} ($(basename "$path")). NAO removido — pode ser pausa humana ou crash. Se abandonado: git -C ${repo} ${hint}" \
       >/dev/null 2>&1; then
    mkdir -p "$GIT_LOCK_STATE_DIR" 2>/dev/null && printf '%s\n' "$mt" > "$marker" 2>/dev/null || true
  else
    echo "[git-lock-hygiene] notify FAILED for ${path} — not recorded as announced, retried next sweep" >&2
  fi
  return 0
}

# Scan one git repo root for stale lock files.
# Returns the count of files REMOVED/would-remove: the locks, plus operation-state items only under
# GIT_LOCK_STATE_REMOVE=1. By default those are reported through _report_stale_state (via _glh_reap)
# and are not counted here — a detection is not a removal.
_scan_repo() {
  local repo="$1" git_dir removed=0 git_link
  git_dir="${repo}/.git"
  if [ -f "$git_dir" ]; then
    # Gitlink file, not a directory — worktree/submodule/bare-container
    # redirect (e.g. property_scrapers/lexbh's ".git" -> ".repo.git",
    # ga-92iqox). Resolve the real git-dir from the "gitdir: <path>" line
    # instead of assuming $repo/.git is itself the scannable directory.
    git_link=$(sed -n 's/^gitdir: *//p' "$git_dir" 2>/dev/null | head -1)
    case "$git_link" in
      /*) git_dir="$git_link" ;;             # absolute — git's usual form
      "") echo 0; return 0 ;;                # unreadable/malformed -> not a git repo
      *)  git_dir="${repo}/${git_link}" ;;    # relative -> resolve against $repo
    esac
  fi
  if [ ! -d "$git_dir" ]; then echo 0; return 0; fi   # not a git repo

  # Single-file lock candidates
  local f label
  for f_label in \
    "index.lock:index lock" \
    "packed-refs.lock:packed-refs lock" \
    "shallow.lock:shallow lock" \
    "config.lock:config lock"
  do
    f="${git_dir}/${f_label%%:*}"
    label="${f_label#*:}"
    if _is_stale "$f" "$repo" && _glh_reap "$f" "$repo" "$label"; then
      removed=$(( removed + 1 ))
    fi
  done

  # Operation state — DETECT-ONLY by default (ga-892qy1). The state of a merge / cherry-pick /
  # revert / rebase that may be paused for a human is not a lock and is not removed here, whatever
  # its age: "no git process" does not distinguish paused from crashed. The same two gates as a lock
  # (age, no live process) decide whether it is worth REPORTING; _glh_reap reports it, or removes it
  # only when GIT_LOCK_STATE_REMOVE=1. Fields: name | label | the abort command to put in the
  # notification. rebase-merge/rebase-apply are directories, the rest files.
  local s_entry s_name s_label s_hint s_path
  for s_entry in \
    "MERGE_HEAD|in-progress merge|merge --abort" \
    "CHERRY_PICK_HEAD|in-progress cherry-pick|cherry-pick --abort" \
    "REVERT_HEAD|in-progress revert|revert --abort" \
    "rebase-merge|in-progress rebase (merge strategy)|rebase --abort" \
    "rebase-apply|in-progress rebase/am (apply strategy)|rebase --abort (ou am --abort)"
  do
    IFS='|' read -r s_name s_label s_hint <<< "$s_entry"
    s_path="${git_dir}/${s_name}"
    if _is_stale "$s_path" "$repo" && _glh_reap "$s_path" "$repo" "$s_label" "$s_hint"; then
      removed=$(( removed + 1 ))
    fi
  done

  # PID-tagged custom index locks: index.<word>.<pid>.lock (e.g.
  # index.stash.15909.lock, and siblings such as index.rebase.<pid>.lock) —
  # not a git-native name, left behind by wrapper tooling that stashes via
  # its own GIT_INDEX_FILE=<path>.$$ and crashes mid-write (ga-2xorq). Still
  # gated on STALE_AGE like every other lock class, but liveness is decided
  # by the PID embedded in the filename, not the repo-wide grep _is_stale()
  # uses — that PID is a stronger, per-lock signal, and the file must be kept
  # while its own owning PID lives even if the repo has no other git activity.
  local pf pbn pid page
  for pf in "$git_dir"/index.*.lock; do
    [ -e "$pf" ] || continue   # glob didn't match anything
    pbn="$(basename "$pf")"
    [[ "$pbn" =~ ^index\.[A-Za-z0-9_-]+\.([0-9]+)\.lock$ ]] || continue
    pid="${BASH_REMATCH[1]}"
    page=$(_path_age "$pf")
    if [ "$page" -ge "$STALE_AGE" ] && _pid_is_dead "$pid"; then
      _remove_stale_lock "$pf" "$repo" "PID lock (owning pid ${pid} dead): ${pbn}"
      removed=$(( removed + 1 ))
    fi
  done

  echo "$removed"
}

# ── PART 2: Per-repo git mutation mutex ───────────────────────────────────────
# Lock directory: $GIT_REPO_MUTEX_BASE/<slug>/
# Heartbeat file: $GIT_REPO_MUTEX_BASE/<slug>/heartbeat (contains $$:RANDOM token)
# Staleness: heartbeat mtime > GIT_REPO_MUTEX_MAX_AGE OR holder PID dead.

_mutex_slug() {
  # Stable per-repo lock dir name — sanitize path to a filename-safe slug.
  printf '%s' "$1" | tr '/ :' '___'
}

_mutex_dir() { printf '%s/%s' "$GIT_REPO_MUTEX_BASE" "$(_mutex_slug "$1")"; }
_mutex_hb()  { printf '%s/%s/heartbeat' "$GIT_REPO_MUTEX_BASE" "$(_mutex_slug "$1")"; }

_mutex_hb_age() {
  local hb="$(_mutex_hb "$1")"
  _path_age "$hb"
}

_mutex_holder_dead() {
  local hb pid
  hb="$(_mutex_hb "$1")"
  pid=$(head -n1 "$hb" 2>/dev/null | cut -d: -f1 || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;   # unknown → treat as alive
  esac
  kill -0 "$pid" 2>/dev/null && return 1   # alive
  return 0                                  # dead
}

# git_mutex_acquire <repo_path>
# Returns 0 if we acquired the lock, 1 if a live holder has it.
# Kill-switch: GIT_REPO_MUTEX_ENABLED=0 → always returns 0 (unlocked pass-through).
git_mutex_acquire() {
  [ "${GIT_REPO_MUTEX_ENABLED:-1}" = "0" ] && return 0
  local repo="$1"
  local lock_dir token hb
  lock_dir="$(_mutex_dir "$repo")"
  hb="${lock_dir}/heartbeat"
  token="$$:${RANDOM}${RANDOM}"
  mkdir -p "$GIT_REPO_MUTEX_BASE" 2>/dev/null || true

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$token" > "$hb" 2>/dev/null || true
    # Verify the write succeeded (same guard as gate lock ga-T1 #6)
    if [ ! -s "$hb" ]; then
      rm -rf "$lock_dir" 2>/dev/null || true
      return 1
    fi
    export _GIT_MUTEX_TOKEN="$token"
    export _GIT_MUTEX_DIR="$lock_dir"
    return 0
  fi

  # mkdir failed: check if current holder is stale.
  local age
  age=$(_mutex_hb_age "$repo")
  if [ "$age" -lt "$GIT_REPO_MUTEX_MAX_AGE" ] && ! _mutex_holder_dead "$repo"; then
    return 1   # live holder
  fi

  # Stale holder: reclaim atomically via a .reaping sentinel.
  local reaping="${lock_dir}.reaping"
  if mkdir "$reaping" 2>/dev/null; then
    rm -rf "$lock_dir" 2>/dev/null || true
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$token" > "$hb" 2>/dev/null || true
      rm -rf "$reaping" 2>/dev/null || true
      if [ ! -s "$hb" ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
        return 1
      fi
      export _GIT_MUTEX_TOKEN="$token"
      export _GIT_MUTEX_DIR="$lock_dir"
      return 0
    fi
    rm -rf "$reaping" 2>/dev/null || true
  fi

  return 1   # lost the reclaim race; another acquirer took it
}

# git_mutex_release <repo_path>
# Releases our lock (noop if we don't own it or mutex is disabled).
git_mutex_release() {
  [ "${GIT_REPO_MUTEX_ENABLED:-1}" = "0" ] && return 0
  local repo="$1"
  local hb own
  hb="$(_mutex_hb "$repo")"
  own=$(head -n1 "$hb" 2>/dev/null || true)
  if [ -n "${_GIT_MUTEX_TOKEN:-}" ] && [ "$own" = "$_GIT_MUTEX_TOKEN" ]; then
    rm -rf "$(_mutex_dir "$repo")" 2>/dev/null || true
  fi
  unset _GIT_MUTEX_TOKEN _GIT_MUTEX_DIR 2>/dev/null || true
  return 0
}

# git_with_mutex <repo_path> <cmd...>
# Runs <cmd> while holding the per-repo mutex, then releases.
# If the lock is held by a live owner, skips (returns 2) without running cmd.
# cmd exit code is propagated; release always happens.
git_with_mutex() {
  local repo="$1"; shift
  if ! git_mutex_acquire "$repo"; then
    echo "[git-lock-hygiene] git_with_mutex: lock held for $repo — skipping: $*" >&2
    return 2
  fi
  local rc=0
  "$@" || rc=$?
  git_mutex_release "$repo"
  return "$rc"
}

# ── Lib-only mode (sourced by callers) ────────────────────────────────────────
[ "${GIT_LOCK_HYGIENE_LIB:-0}" = "1" ] && return 0

# ── Selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  set +u   # temp dir paths may be unset in subscopes
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $*"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-lock-hygiene-selftest.XXXXXX")"
  trap 'rm -rf "$TMP" "${T55_BASE:-}"' EXIT

  # ga-d8zeli: _log_json appends every removed/would_remove/stale_state_found event to $LOG, which
  # defaults to the LIVE sweeps log — and the fixture repos below fire those events
  # for real (8 per run; measured 2026-09-20: 746 of the 36791 lines in the live
  # git-lock-hygiene.jsonl were selftest fixtures). Point $LOG at scratch for the
  # whole selftest, unconditionally: an inherited GIT_LOCK_LOG must not be able to
  # aim a selftest back at production. Here rather than in the wrapper because more
  # than one caller runs this block (scripts/git-lock-hygiene.selftest.sh,
  # gate-git-lock-hygiene.selftest.sh, a bare `--selftest`); the wrapper pins it.
  LOG="$TMP/git-lock-hygiene.jsonl"

  # ga-892qy1: the same hermeticity for the two new side channels. A stale MERGE_HEAD /
  # rebase-* fixture now fires a REAL notify (ntfy to the Athos topic) and writes a dedupe
  # marker under $CITY/.gc/state — so NOTIFY_BIN and the marker dir are pinned to scratch here,
  # unconditionally, for the same reason as $LOG above: an inherited value must not be able to
  # aim a selftest at production. The fake notify counts its calls and prints to STDOUT like the
  # real one does ("Logged for digest ..."), which is what makes a leak into the
  # `count=$(_scan_repo ...)` capture observable.
  NOTIFY_CALLS="$TMP/notify.calls"
  export NOTIFY_CALLS
  NOTIFY_BIN="$TMP/fake-notify"
  cat > "$NOTIFY_BIN" <<'FAKE'
#!/bin/sh
echo "$*" >> "$NOTIFY_CALLS"
echo "Logged for digest (selftest fake): $*"
exit 0
FAKE
  chmod +x "$NOTIFY_BIN"
  GIT_LOCK_STATE_DIR="$TMP/state-notified"
  # Lines in a file, 0 when it does not exist (grep -c exits 1 on zero matches).
  _lines() { local n; n="$(grep -c . "$1" 2>/dev/null || true)"; echo "${n:-0}"; }
  _events() { local n; n="$(grep -c "\"event\":\"$1\"" "$LOG" 2>/dev/null || true)"; echo "${n:-0}"; }

  # Absolute path to this script itself — needed by T23-T25 below, which
  # extract the SELFTEST-EXTRACT root-resolve-loop block from this exact
  # file (see those tests' own header comment for why they extract rather
  # than source the whole file).
  _GLH_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

  # Test helper: create a fake git repo with a given lock file.
  # make_repo <dir>  →  creates <dir>/.git/
  make_repo() {
    mkdir -p "$1/.git"
    # minimal git dir so git commands recognise it
    printf 'ref: refs/heads/main\n' > "$1/.git/HEAD"
    mkdir -p "$1/.git/refs/heads"
    touch "$1/.git/COMMIT_EDITMSG"
  }

  # Test helper: reproduce the gitlink-redirect shape property_scrapers/lexbh
  # actually have on disk (ga-92iqox): <dir>/.git is a regular FILE containing
  # "gitdir: <path>", and the real scannable git-dir lives at <dir>/.repo.git
  # instead of <dir>/.git itself.
  # make_gitlink_repo <dir> [abs|rel]  →  creates <dir>/.repo.git (real git
  #   dir) + <dir>/.git (gitlink file). form defaults to abs, matching what's
  #   observed live; "rel" writes a gitdir: line relative to <dir>.
  make_gitlink_repo() {
    local dir="$1" form="${2:-abs}" real="$1/.repo.git"
    mkdir -p "$dir" "$real"
    printf 'ref: refs/heads/main\n' > "$real/HEAD"
    mkdir -p "$real/refs/heads"
    touch "$real/COMMIT_EDITMSG"
    if [ "$form" = "rel" ]; then
      printf 'gitdir: .repo.git\n' > "$dir/.git"
    else
      printf 'gitdir: %s\n' "$real" > "$dir/.git"
    fi
  }

  # Stub: no live git process (always says dead).
  _no_git_process() { return 1; }
  # Stub: live git process (always says alive).
  _yes_git_process() { return 0; }

  echo ""
  echo "[git-lock-hygiene selftest] running ..."
  echo ""

  # T1: fresh index.lock (age < STALE_AGE) → NOT removed
  echo "T1: fresh index.lock (<STALE_AGE) is left alone"
  R1="$TMP/repo1"; make_repo "$R1"
  touch "$R1/.git/index.lock"   # just created → age ~0s
  export GIT_LOCK_PROCESS_CHECK_FN="_no_git_process"
  export GIT_LOCK_STALE_AGE_SEC=300
  count=$(_scan_repo "$R1")
  [ -f "$R1/.git/index.lock" ] && ok "T1: fresh index.lock untouched" \
    || bad "T1: fresh index.lock was removed (should not be)"
  [ "$count" -eq 0 ] && ok "T1: removed count=0" || bad "T1: removed count=$count (expected 0)"

  # T2: stale index.lock (aged) + no live process → removed
  echo "T2: stale index.lock (aged) → removed"
  R2="$TMP/repo2"; make_repo "$R2"
  touch -t 200001010000 "$R2/.git/index.lock"   # Jan 1 2000 = very old
  export GIT_LOCK_STALE_AGE_SEC=300
  count=$(_scan_repo "$R2")
  [ ! -f "$R2/.git/index.lock" ] && ok "T2: stale index.lock removed" \
    || bad "T2: stale index.lock NOT removed"
  [ "$count" -ge 1 ] && ok "T2: removed count>=1" || bad "T2: removed count=$count (expected >=1)"

  # T3: stale index.lock + live git process → NOT removed
  echo "T3: stale index.lock + live git process → left alone"
  R3="$TMP/repo3"; make_repo "$R3"
  touch -t 200001010000 "$R3/.git/index.lock"
  export GIT_LOCK_PROCESS_CHECK_FN="_yes_git_process"
  count=$(_scan_repo "$R3")
  [ -f "$R3/.git/index.lock" ] && ok "T3: lock untouched (live process detected)" \
    || bad "T3: lock removed despite live process (should NOT be)"
  export GIT_LOCK_PROCESS_CHECK_FN="_no_git_process"

  # In-progress-OPERATION state (MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD, rebase-merge/,
  # rebase-apply/) is REPORTED, not removed (ga-hl3xlw / ga-892qy1): an operation paused on a
  # conflict for a human has no process either, so age + "no git process" cannot tell it from a
  # crashed one, and deleting it turns a merge into a one-parent commit / loses a rebase. Only
  # GIT_LOCK_STATE_REMOVE=1 restores the old removal. *.lock files are unaffected.
  # _state_logged <path> — was a stale_state_found event written for exactly that path?
  _state_logged() {
    awk -v p="$1" 'index($0, "\"path\":\"" p "\"") && /"event":"stale_state_found"/ { f = 1 } END { exit !f }' "$LOG" 2>/dev/null
  }

  # T4: stale rebase-merge/ directory → reported and kept; removed only on opt-in
  echo "T4: stale rebase-merge/ dir → reported, NOT removed (a paused rebase looks like a crashed one)"
  R4="$TMP/repo4"; make_repo "$R4"
  mkdir -p "$R4/.git/rebase-merge"
  touch -t 200001010000 "$R4/.git/rebase-merge"
  : > "$LOG"
  count=$(_scan_repo "$R4" 2>/dev/null)
  [ -d "$R4/.git/rebase-merge" ] && ok "T4: stale rebase-merge/ kept" \
    || bad "T4: stale rebase-merge/ was REMOVED (a paused rebase would be lost)"
  [ "$count" = "0" ] && ok "T4: removed count=0 (nothing was removed, so none is claimed)" \
    || bad "T4: removed count=$count (expected 0)"
  _state_logged "$R4/.git/rebase-merge" && ok "T4: the kept state is logged as stale_state_found" \
    || bad "T4: no stale_state_found event for $R4/.git/rebase-merge — a skipped item left no trace"
  [ "$(_events stale_state_found)" = "1" ] && ok "T4: one stale_state_found event logged" \
    || bad "T4: expected 1 stale_state_found event, got $(_events stale_state_found)"
  grep -q "\"event\":\"stale_state_found\".*\"path\":\"$R4/.git/rebase-merge\".*\"repo\":\"$R4\".*\"age_sec\":[0-9]" "$LOG" \
    && ok "T4: event carries path, repo and age_sec" \
    || bad "T4: event missing path/repo/age_sec — log: $(head -c 300 "$LOG")"
  [ "$(_events removed)" = "0" ] && ok "T4: no 'removed' event" || bad "T4: a 'removed' event was logged for a state item"
  count=$(GIT_LOCK_STATE_REMOVE=1 _scan_repo "$R4" 2>/dev/null)
  [ ! -d "$R4/.git/rebase-merge" ] && ok "T4: GIT_LOCK_STATE_REMOVE=1 removes it (the opt-in still works)" \
    || bad "T4: GIT_LOCK_STATE_REMOVE=1 did not remove the stale rebase-merge/"

  # T5: stale MERGE_HEAD → reported and kept, while an aged index.lock beside it IS removed (the
  # actual ga-hl3xlw bug must not be held hostage by the state items); ORIG_HEAD → untouched
  echo "T5: stale MERGE_HEAD reported+kept, index.lock beside it removed; ORIG_HEAD untouched"
  R5="$TMP/repo5"; make_repo "$R5"
  touch -t 200001010000 "$R5/.git/MERGE_HEAD"
  touch -t 200001010000 "$R5/.git/index.lock"
  touch -t 200001010000 "$R5/.git/ORIG_HEAD"   # valid artifact — must NOT be removed
  : > "$LOG"
  count=$(_scan_repo "$R5" 2>/dev/null)
  [ -f "$R5/.git/MERGE_HEAD" ] && ok "T5: stale MERGE_HEAD kept" \
    || bad "T5: stale MERGE_HEAD was REMOVED (a paused merge would become a one-parent commit)"
  [ ! -f "$R5/.git/index.lock" ] && ok "T5: the aged index.lock beside it was still removed" \
    || bad "T5: index.lock kept — the state-item guard must not shield lock files"
  [ "$count" = "1" ] && ok "T5: removed count=1 (the lock only)" || bad "T5: removed count=$count (expected 1)"
  _state_logged "$R5/.git/MERGE_HEAD" && ok "T5: MERGE_HEAD logged as stale_state_found" \
    || bad "T5: no stale_state_found event for $R5/.git/MERGE_HEAD"
  [ -f "$R5/.git/ORIG_HEAD" ] && ok "T5: ORIG_HEAD left untouched" \
    || bad "T5: ORIG_HEAD was removed (should NOT be)"
  [ "$(_events stale_state_found)" = "1" ] && ok "T5: one stale_state_found event for MERGE_HEAD" \
    || bad "T5: expected 1 stale_state_found event, got $(_events stale_state_found)"
  count=$(GIT_LOCK_STATE_REMOVE=1 _scan_repo "$R5" 2>/dev/null)
  [ ! -f "$R5/.git/MERGE_HEAD" ] && ok "T5: GIT_LOCK_STATE_REMOVE=1 removes MERGE_HEAD (opt-in)" \
    || bad "T5: GIT_LOCK_STATE_REMOVE=1 did not remove MERGE_HEAD"
  [ -f "$R5/.git/ORIG_HEAD" ] && ok "T5: ORIG_HEAD still untouched under the opt-in" \
    || bad "T5: ORIG_HEAD removed under GIT_LOCK_STATE_REMOVE=1"

  # T5b: the whole class, not the two names T4/T5 happened to use — every state item `_scan_repo`
  # knows is kept by default and removed only under the opt-in.
  echo "T5b: every in-progress-operation item is kept by default, removed only on opt-in"
  for _st in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    R5B="$TMP/repo5b-$_st"; make_repo "$R5B"
    case "$_st" in rebase-*) mkdir -p "$R5B/.git/$_st" ;; *) : > "$R5B/.git/$_st" ;; esac
    touch -t 200001010000 "$R5B/.git/$_st"
    : > "$LOG"
    count=$(_scan_repo "$R5B" 2>/dev/null)
    if [ -e "$R5B/.git/$_st" ] && [ "$count" = "0" ] && _state_logged "$R5B/.git/$_st"; then
      ok "T5b: $_st kept, counted as 0 removed, logged"
    else
      bad "T5b: $_st — removed, miscounted (count=$count) or not logged"
    fi
    count=$(GIT_LOCK_STATE_REMOVE=1 _scan_repo "$R5B" 2>/dev/null)
    [ ! -e "$R5B/.git/$_st" ] && ok "T5b: $_st removed under GIT_LOCK_STATE_REMOVE=1" \
      || bad "T5b: $_st survived GIT_LOCK_STATE_REMOVE=1"
  done

  # T6: DRY_RUN=1 → stale lock logged but not removed
  echo "T6: DRY_RUN=1 → stale lock NOT removed"
  R6="$TMP/repo6"; make_repo "$R6"
  touch -t 200001010000 "$R6/.git/index.lock"
  DRY_RUN=1 _scan_repo "$R6" > /dev/null
  DRY_RUN=0
  [ -f "$R6/.git/index.lock" ] && ok "T6: DRY_RUN=1: stale lock not removed" \
    || bad "T6: DRY_RUN=1: lock removed (should NOT be)"

  # T7: no .git dir → _scan_repo returns 0, no error
  echo "T7: non-repo dir → scan is a no-op"
  R7="$TMP/notarepo"; mkdir -p "$R7"
  count=$(_scan_repo "$R7")
  [ "$count" = "0" ] && ok "T7: non-repo returns 0" || bad "T7: returned $count (expected 0)"

  # ── PID-tagged custom index lock tests (ga-2xorq) ──────────────────────────
  DEAD_PID=999999999   # almost certainly no such process (mirrors T12's convention)

  # T15: stale index.stash.<dead-pid>.lock → removed
  echo "T15: stale index.stash.<dead-pid>.lock → removed"
  R8="$TMP/repo8"; make_repo "$R8"
  touch -t 200001010000 "$R8/.git/index.stash.${DEAD_PID}.lock"
  export GIT_LOCK_STALE_AGE_SEC=300
  count=$(_scan_repo "$R8")
  [ ! -f "$R8/.git/index.stash.${DEAD_PID}.lock" ] && ok "T15: dead-pid stash lock removed" \
    || bad "T15: dead-pid stash lock NOT removed"
  [ "$count" -ge 1 ] && ok "T15: removed count>=1" || bad "T15: removed count=$count (expected >=1)"

  # T16: stale index.stash.<live-pid>.lock → left alone, even though old
  # (bead ga-2xorq scope point 2: "NAO remover lock cujo PID dono ainda esta
  # vivo, mesmo que velho" — age alone must never override a live owning PID)
  echo "T16: stale index.stash.<live-pid>.lock (old) → left alone (owning PID alive)"
  R9="$TMP/repo9"; make_repo "$R9"
  LIVE_PID=$$   # this selftest's own shell — guaranteed alive for the test's duration
  touch -t 200001010000 "$R9/.git/index.stash.${LIVE_PID}.lock"
  count=$(_scan_repo "$R9")
  [ -f "$R9/.git/index.stash.${LIVE_PID}.lock" ] && ok "T16: live-pid stash lock untouched despite old age" \
    || bad "T16: live-pid stash lock removed (should NOT be — owning PID is alive)"
  [ "$count" -eq 0 ] && ok "T16: removed count=0" || bad "T16: removed count=$count (expected 0)"

  # T17: sibling pattern (not literally "stash") → also removed — proves the
  # fix covers the index.<word>.<pid>.lock CLASS, not just the cited instance.
  echo "T17: stale index.rebase.<dead-pid>.lock (sibling pattern) → removed"
  R10="$TMP/repo10"; make_repo "$R10"
  touch -t 200001010000 "$R10/.git/index.rebase.${DEAD_PID}.lock"
  count=$(_scan_repo "$R10")
  [ ! -f "$R10/.git/index.rebase.${DEAD_PID}.lock" ] && ok "T17: sibling dead-pid lock removed" \
    || bad "T17: sibling dead-pid lock NOT removed"

  # T18: FRESH index.stash.<dead-pid>.lock (age<STALE_AGE) → left alone —
  # the STALE_AGE guard must still apply even when the owning PID is dead
  # (bead ga-2xorq scope point 1: "reusando a mesma guarda de idade").
  echo "T18: fresh index.stash.<dead-pid>.lock (<STALE_AGE) → left alone (age gate still applies)"
  R11="$TMP/repo11"; make_repo "$R11"
  touch "$R11/.git/index.stash.${DEAD_PID}.lock"   # just created → age ~0s
  count=$(_scan_repo "$R11")
  [ -f "$R11/.git/index.stash.${DEAD_PID}.lock" ] && ok "T18: fresh PID-lock untouched (age gate applies even to dead pid)" \
    || bad "T18: fresh PID-lock removed (age gate should still block this)"

  # ── Gitlink (.git as a regular FILE) tests — ga-92iqox ──────────────────────
  # Reproduces property_scrapers/lexbh's actual on-disk shape: ".git" is a
  # plain file containing "gitdir: <path>", not a directory. Before this fix,
  # _scan_repo's own `[ ! -d "$git_dir" ]` check treated every such repo as
  # "not a git repo" and skipped it unconditionally — silent zero coverage,
  # regardless of what locks sat inside the real git-dir.
  export GIT_LOCK_PROCESS_CHECK_FN="_no_git_process"
  export GIT_LOCK_STALE_AGE_SEC=300

  # T19: stale index.lock behind an ABSOLUTE gitlink → removed
  echo "T19: stale index.lock behind an absolute gitlink (.git -> .repo.git) → removed"
  R12="$TMP/repo12"; make_gitlink_repo "$R12" abs
  touch -t 200001010000 "$R12/.repo.git/index.lock"
  count=$(_scan_repo "$R12")
  [ ! -f "$R12/.repo.git/index.lock" ] && ok "T19: stale lock behind gitlink removed" \
    || bad "T19: stale lock behind gitlink NOT removed"
  [ "$count" -ge 1 ] && ok "T19: removed count>=1" || bad "T19: removed count=$count (expected >=1)"

  # T20: FRESH index.lock behind the same gitlink → left alone — the
  # STALE_AGE gate must still apply after resolving through the redirect,
  # not just for the direct-directory .git case.
  echo "T20: fresh index.lock behind a gitlink (<STALE_AGE) → left alone"
  R13="$TMP/repo13"; make_gitlink_repo "$R13" abs
  touch "$R13/.repo.git/index.lock"   # just created → age ~0s
  count=$(_scan_repo "$R13")
  [ -f "$R13/.repo.git/index.lock" ] && ok "T20: fresh lock behind gitlink untouched" \
    || bad "T20: fresh lock behind gitlink removed (age gate should still block this)"
  [ "$count" -eq 0 ] && ok "T20: removed count=0" || bad "T20: removed count=$count (expected 0)"

  # T21: stale index.lock behind a RELATIVE gitlink ("gitdir: .repo.git") →
  # removed. git supports both absolute and relative gitdir: lines; only the
  # absolute form is observed live today, but the resolution code branches on
  # it, so both paths need coverage.
  echo "T21: stale index.lock behind a relative gitlink (gitdir: .repo.git) → removed"
  R14="$TMP/repo14"; make_gitlink_repo "$R14" rel
  touch -t 200001010000 "$R14/.repo.git/index.lock"
  count=$(_scan_repo "$R14")
  [ ! -f "$R14/.repo.git/index.lock" ] && ok "T21: stale lock behind relative gitlink removed" \
    || bad "T21: stale lock behind relative gitlink NOT removed"

  # T22: .git file with no parseable "gitdir:" line → treated as "not a git
  # repo" (count=0), never an error — mirrors the non-repo no-op in T7.
  echo "T22: malformed .git file (no gitdir: line) → scan is a no-op, no error"
  R15="$TMP/repo15"; mkdir -p "$R15"
  printf 'not a real gitlink\n' > "$R15/.git"
  count=$(_scan_repo "$R15")
  [ "$count" = "0" ] && ok "T22: malformed gitlink returns 0" || bad "T22: returned $count (expected 0)"

  # ── Lib-mode load survival under set -e — ga-92iqox OUTAGE regression ──────
  # 2026-09-15 06:09-06:34: an earlier fix for T19-22 above (a2575edb5) also
  # dropped the `|| continue` guard on the root-resolution loop's
  # `_glh_top=$(... rev-parse ...)` assignment. quality-gate-dispatcher.sh
  # sources this file with GIT_LOCK_HYGIENE_LIB=1 under its own
  # `set -euo pipefail`, cwd=/ (the plist sets no WorkingDirectory) — a BARE
  # assignment whose command substitution fails (exactly what happens for
  # property_scrapers: a bare-via-gitlink repo has no worktree, so `git
  # rev-parse --show-toplevel` exits 128) is a live errexit trigger there,
  # confirmed to kill the dispatcher before it logged a single line under the
  # plist's actual environment. Revert: 8e5b87763. Root-cause + required
  # tests: Mayor comment on ga-92iqox, 2026-09-15 09:35.
  #
  # WHY THIS EXTRACTS THE LOOP INSTEAD OF SOURCING THIS WHOLE FILE: measured
  # empirically while writing this test — whether the UNGUARDED (a2575edb5)
  # shape of this exact code actually crashes under `set -euo pipefail`
  # depends on the TOTAL SIZE of the file it's sourced from. It crashes
  # reliably sourced from a ~725-800 line file (confirmed against the real
  # a2575edb5 commit content), but stops crashing once the surrounding file
  # grows past that (this file already exceeds it, and only grows as more
  # tests are added here — the exact mechanism wasn't fully root-caused, but
  # the size-dependence itself was verified directly, repeatedly). A test
  # that sources this whole file would therefore silently stop discriminating
  # fixed-from-broken over time, passing either way. Extracting just the
  # vulnerable block via the SELFTEST-EXTRACT sentinels above and running it
  # in a minimal ~20-line harness is size-independent of the rest of this
  # file and stays a real test no matter how large this file grows.
  extract_block() {
    local file="$1" name="$2"
    sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
      | sed '1d;$d'
  }
  T23_BLOCK="$TMP/root-resolve-loop-block.sh"
  extract_block "$_GLH_SELF" "root-resolve-loop" > "$T23_BLOCK"
  T23_HARNESS="$TMP/root-resolve-loop-harness.sh"
  cat > "$T23_HARNESS" <<'HARNESSEOF'
#!/usr/bin/env bash
set -euo pipefail
_glh_rig_paths="$1"
. "$2"
printf 'RESOLVED=%s' "$_glh_resolved"
HARNESSEOF

  echo "T23: extracted root-resolve loop survives set -euo pipefail with a bare/gitlink rig"
  R16="$TMP/repo16-gitlink-rig"; make_gitlink_repo "$R16" abs
  _t23_out=$(env -i HOME="$HOME" PATH="$PATH" bash "$T23_HARNESS" "$R16" "$T23_BLOCK" 2>&1)
  _t23_rc=$?
  case "$_t23_out" in
    RESOLVED=*) ok "T23: root-resolve loop survived a bare/gitlink rig under set -e" ;;
    *) bad "T23: root-resolve loop DIED on a bare/gitlink rig under set -e (rc=$_t23_rc) — output: $_t23_out" ;;
  esac

  # T24: the survival in T23 isn't just "skip and move on" — the gitlink rig
  # must actually resolve to itself (same fixture). A fix that merely
  # swallowed the failure without resolving the gitlink path would pass T23
  # but silently reintroduce the ORIGINAL ga-92iqox bug (property_scrapers/
  # lexbh never scanned) — this closes that gap.
  echo "T24: root-resolve loop actually resolves the gitlink rig, not just survives"
  case "$_t23_out" in
    "RESOLVED=$R16") ok "T24: gitlink rig resolved correctly" ;;
    *) bad "T24: gitlink rig NOT correctly resolved — got: $_t23_out" ;;
  esac

  # T25: MUTATION-TEST — proves T23 is not vacuous. Strip the `|| _glh_top=""`
  # guard from the SAME extracted block (reproducing the exact a2575edb5
  # shape: a bare, unguarded assignment) and confirm it DOES crash under the
  # same conditions T23 just proved survive. If this ever stops crashing,
  # T23 has stopped testing anything.
  echo "T25: mutation-test — the unguarded-assignment shape (a2575edb5) DOES crash the extracted loop"
  T25_BLOCK_MUT="$TMP/root-resolve-loop-block-mutated.sh"
  _t25_needle=' || _glh_top=""'
  _t25_hits=$(python3 -c '
import sys
path, needle, outpath = sys.argv[1:4]
src = open(path).read()
n = src.count(needle)
open(outpath, "w").write(src.replace(needle, "", 1))
print(n)
' "$T23_BLOCK" "$_t25_needle" "$T25_BLOCK_MUT")
  if [ "$_t25_hits" != "1" ]; then
    bad "T25: mutation needle matched $_t25_hits times in the extracted block (expected exactly 1) — pattern drifted, fix the needle string"
  else
    _t25_out=$(env -i HOME="$HOME" PATH="$PATH" bash "$T23_HARNESS" "$R16" "$T25_BLOCK_MUT" 2>&1)
    _t25_rc=$?
    if [ "$_t25_rc" -eq 0 ]; then
      bad "T25: mutated (unguarded, a2575edb5-shaped) block survived (rc=0) — mutation test is vacuous"
    else
      ok "T25: mutated (unguarded, a2575edb5-shaped) block crashes as expected (rc=$_t25_rc) — proves T23 is not vacuous"
    fi
  fi

  # ── Real liveness check, NO stub (ga-hl3xlw) ────────────────────────────────
  # Every test above stubs GIT_LOCK_PROCESS_CHECK_FN, so the real
  # _git_repo_has_live_process never ran under test. It shipped as
  #   ps aux | grep '[g]it' | grep -F "$repo"
  # i.e. ANY process whose command line holds the repo path as a substring counted as "a live
  # git on this repo": crew/* clones nested under the root, a sibling repo that shares a prefix,
  # tmux/claude/zsh lines that merely mention both words. On a root with live crews something
  # always matched, so a 0-byte index.lock stayed forever (wa-8y271z deploy rc=75 for ~3h,
  # 2026-10-02). It was blind the other way too: a git whose cwd IS the root but whose argv
  # names no path never matched.
  # These tests run the REAL function against REAL processes. lv_proc starts a long-lived process
  # whose argv[0] is <name> (macOS ps reports argv[0] as comm) and whose cwd/remaining argv we
  # choose, so attribution is exercised end to end through ps + lsof.
  unset GIT_LOCK_PROCESS_CHECK_FN
  export GIT_LOCK_STALE_AGE_SEC=300
  # The fixtures live under $LVR, NOT $TMP, and the name must not contain "git": $TMP is called
  # git-lock-hygiene-selftest.*, so with the old pipeline the `grep -F <repo>` process matched
  # ITSELF (its own command line holds "git" and the repo path) and every "→ removed" test failed
  # for that accident rather than for the bug class the test names.
  LVR="$(mktemp -d "${TMPDIR:-/tmp}/glh-lv.XXXXXX")"
  LV_PIDS=""
  lv_cleanup() {
    local p
    for p in $LV_PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
    LV_PIDS=""
  }
  trap 'lv_cleanup; rm -rf "$TMP" "$LVR"' EXIT
  # lv_proc <argv0> <cwd> [args...] — returns only once ps sees the process under that name.
  lv_proc() {
    local name="$1" cwd="$2" pid i; shift 2
    ( cd "$cwd" && exec -a "$name" /usr/bin/perl -e 'sleep 120' -- "$@" ) >/dev/null 2>&1 &
    pid=$!
    LV_PIDS="$LV_PIDS $pid"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
      [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "$name" ] && return 0
      sleep 0.2
    done
    bad "lv_proc: process '$name' never appeared in ps"
  }
  # lv_hold <file> — a NON-git process holding <file> open for writing, the way git holds index.lock.
  lv_hold() {
    local f="$1" i
    ( exec 7>>"$f"; exec /bin/sleep 120 ) >/dev/null 2>&1 &
    LV_PIDS="$LV_PIDS $!"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -n "$(lsof -t -- "$f" 2>/dev/null)" ] && return 0
      sleep 0.2
    done
    bad "lv_hold: nothing ever opened $f"
  }
  lv_old() { touch -t 200001010000 "$1"; }
  # lv_logged <lock path> <reason regex> — is there a skipped_live event for that path whose reason matches?
  # A kept lock proves nothing about WHY it was kept; the reason is what names the branch that decided.
  lv_logged() {
    awk -v p="$1" -v r="$2" 'index($0, p) && /"event":"skipped_live"/ && $0 ~ r { f = 1 } END { exit !f }' "$LOG" 2>/dev/null
  }

  echo "T26: stale index.lock + a git in a NESTED clone (<root>/crew/x) → removed (a different repo)"
  L1="$LVR/lv1"; make_repo "$L1"; make_repo "$L1/crew/x"
  lv_old "$L1/.git/index.lock"
  lv_proc git / -C "$L1/crew/x" status
  count=$(_scan_repo "$L1"); lv_cleanup
  [ ! -f "$L1/.git/index.lock" ] && ok "T26: lock removed — a git in crew/x does not hold the root's index" \
    || bad "T26: lock kept because a git runs in a NESTED clone (the ga-hl3xlw false positive)"

  echo "T27: stale index.lock + non-git processes that merely mention the path and the word git → removed"
  L2="$LVR/lv2"; make_repo "$L2"
  lv_old "$L2/.git/index.lock"
  lv_proc tmux / new-session -c "$L2" -e "BEADS_NOTE=git-lock"
  lv_proc claude / -p "fix git in $L2"
  count=$(_scan_repo "$L2"); lv_cleanup
  [ ! -f "$L2/.git/index.lock" ] && ok "T27: lock removed — only a git process can hold a git lock" \
    || bad "T27: lock kept because tmux/claude command lines mention the repo path"

  echo "T28: stale index.lock + a git whose CWD is the root and whose argv names no path → kept"
  L3="$LVR/lv3"; make_repo "$L3"
  lv_old "$L3/.git/index.lock"
  lv_proc git "$L3" status
  count=$(_scan_repo "$L3"); lv_cleanup
  [ -f "$L3/.git/index.lock" ] && ok "T28: lock kept — live git in the root (cwd)" \
    || bad "T28: lock REMOVED under a live git whose cwd is the root (old check was blind to cwd)"
  lv_logged "$L3/.git/index.lock" 'git pid [0-9]+ cwd in repo' \
    && ok "T28: the skip is logged with ITS reason (cwd in repo — not 'cwd unreadable')" \
    || bad "T28: no skipped_live event with reason 'cwd in repo' for $L3/.git/index.lock"

  echo "T29: stale index.lock + 'git -C <root> ...' started from elsewhere → kept"
  L4="$LVR/lv4"; make_repo "$L4"
  lv_old "$L4/.git/index.lock"
  lv_proc git / -C "$L4" status
  count=$(_scan_repo "$L4"); lv_cleanup
  [ -f "$L4/.git/index.lock" ] && ok "T29: lock kept — live git -C <root>" \
    || bad "T29: lock REMOVED under a live 'git -C <root>'"
  lv_logged "$L4/.git/index.lock" 'git pid [0-9]+ argv names repo' \
    && ok "T29: kept by ITS branch (the argv names the repo — cwd is '/', so no other branch can explain it)" \
    || bad "T29: no skipped_live event with reason 'argv names repo' for $L4/.git/index.lock"

  echo "T30: stale index.lock + 'git --git-dir=<root>/.git --work-tree=<root>' → kept"
  L5="$LVR/lv5"; make_repo "$L5"
  lv_old "$L5/.git/index.lock"
  lv_proc git / "--git-dir=$L5/.git" "--work-tree=$L5" status
  count=$(_scan_repo "$L5"); lv_cleanup
  [ -f "$L5/.git/index.lock" ] && ok "T30: lock kept — live git --git-dir=<root>/.git" \
    || bad "T30: lock REMOVED under a live 'git --git-dir=<root>/.git'"
  lv_logged "$L5/.git/index.lock" 'git pid [0-9]+ git-dir is this repo' \
    && ok "T30: kept by ITS branch (the explicit git dir)" \
    || bad "T30: no skipped_live event with reason 'git-dir is this repo' for $L5/.git/index.lock"

  echo "T31: stale index.lock + a git whose cwd is a SUBDIRECTORY of the root (no own .git) → kept"
  L6="$LVR/lv6"; make_repo "$L6"; mkdir -p "$L6/sub/deep"
  lv_old "$L6/.git/index.lock"
  lv_proc git "$L6/sub/deep" status
  count=$(_scan_repo "$L6"); lv_cleanup
  [ -f "$L6/.git/index.lock" ] && ok "T31: lock kept — git in a subdirectory still works on the root's index" \
    || bad "T31: lock REMOVED under a live git running in a subdirectory of the root"
  lv_logged "$L6/.git/index.lock" 'git pid [0-9]+ cwd in repo' \
    && ok "T31: kept by ITS branch (cwd resolves to the enclosing repo)" \
    || bad "T31: no skipped_live event with reason 'cwd in repo' for $L6/.git/index.lock"

  echo "T32: stale index.lock + a git in a linked worktree (<root>/.wt-feat, .git is a FILE) → removed"
  L7="$LVR/lv7"; make_repo "$L7"; mkdir -p "$L7/.wt-feat"
  printf 'gitdir: %s/.git/worktrees/feat\n' "$L7" > "$L7/.wt-feat/.git"
  lv_old "$L7/.git/index.lock"
  lv_proc git "$L7/.wt-feat" status            # attributed through its cwd
  lv_proc git / -C "$L7/.wt-feat" status       # attributed through its argv (the substring the old check matched)
  count=$(_scan_repo "$L7"); lv_cleanup
  [ ! -f "$L7/.git/index.lock" ] && ok "T32: lock removed — a linked worktree has its own index" \
    || bad "T32: lock kept because a git runs in a linked worktree under the root"

  echo "T33: stale index.lock + a git in a SIBLING whose path merely starts with the root's (lv8 vs lv8-other) → removed"
  L8="$LVR/lv8"; make_repo "$L8"; make_repo "$LVR/lv8-other"
  lv_old "$L8/.git/index.lock"
  lv_proc git / -C "$LVR/lv8-other" status
  count=$(_scan_repo "$L8"); lv_cleanup
  [ ! -f "$L8/.git/index.lock" ] && ok "T33: lock removed — path match respects the directory boundary" \
    || bad "T33: lock kept because a sibling repo's path starts with this repo's path"

  echo "T34: stale lock file HELD OPEN by a live process, no git process in sight → kept; once the holder is gone → removed"
  for _lk in index.lock packed-refs.lock; do
    L9="$LVR/lv9-${_lk%.lock}"; make_repo "$L9"; : > "$L9/.git/$_lk"
    lv_hold "$L9/.git/$_lk"
    lv_old "$L9/.git/$_lk"
    count=$(_scan_repo "$L9")
    [ -f "$L9/.git/$_lk" ] && ok "T34: $_lk kept while another process has it open" \
      || bad "T34: $_lk REMOVED while a live process holds it open"
    lv_logged "$L9/.git/$_lk" 'lock held open by pid' \
      && ok "T34: $_lk kept by ITS signal (the open fd), not by a git-process guess" \
      || bad "T34: no skipped_live event with reason 'lock held open by pid' for $L9/.git/$_lk"
    lv_cleanup
    count=$(_scan_repo "$L9")
    [ ! -f "$L9/.git/$_lk" ] && ok "T34: $_lk removed once nobody holds it (proves the fd, not something else, protected it)" \
      || bad "T34: $_lk still there after the holder exited"
  done

  echo "T35: quiet system, stale index.lock, real check → removed"
  L10="$LVR/lv10"; make_repo "$L10"
  lv_old "$L10/.git/index.lock"
  count=$(_scan_repo "$L10")
  [ ! -f "$L10/.git/index.lock" ] && ok "T35: lock removed when nothing is running on the repo" \
    || bad "T35: lock kept although nothing runs on the repo"

  # T36: three states, not two. When the janitor CANNOT find out (ps/lsof broken, empty, timing out
  # or unboundable), that is not "no live process" — the destructive path defaults to inert: keep
  # the lock, and log WHY. Every case asserts the logged reason as well as the surviving file, and
  # runs where the branch it names is the only one that can decide: with a real git process about
  # (the city always has some) a broken lsof is caught by the cwd lookup first and the holder
  # check never runs, so the holder check's own fallback is driven under the _no_git_process stub.
  echo "T36: ps / lsof failing, empty or unboundable → 'cannot tell' keeps the lock, and says why"
  _mk_shim() { mkdir -p "$LVR/shim-$1"; printf '#!/bin/sh\n%s\n' "$3" > "$LVR/shim-$1/$2"; chmod +x "$LVR/shim-$1/$2"; }
  _mk_shim ps-fail ps 'exit 1'
  _mk_shim ps-empty ps 'exit 0'
  _mk_shim lsof-124 lsof 'exit 124'
  _mk_shim lsof-1 lsof 'exit 1'
  L11="$LVR/lv11"; make_repo "$L11"; lv_old "$L11/.git/index.lock"
  # t36 <label> <reason regex> — judge the state the caller just produced
  t36() {
    if [ -f "$L11/.git/index.lock" ] && lv_logged "$L11/.git/index.lock" "$2"; then ok "T36: $1 → kept, reason logged"
    else bad "T36: $1 — lock gone, or reason /$2/ not logged"; fi
  }
  : > "$LOG"; count=$(PATH="$LVR/shim-ps-fail:$PATH" _scan_repo "$L11")
  t36 "ps fails" 'ps failed'
  : > "$LOG"; count=$(PATH="$LVR/shim-ps-empty:$PATH" _scan_repo "$L11")
  t36 "ps answers with no processes at all (a broken ps, not an empty machine)" 'ps listed no processes'
  lv_proc git / -C "$LVR/somewhere-else" status
  : > "$LOG"; count=$(PATH="$LVR/shim-lsof-124:$PATH" _scan_repo "$L11")
  t36 "a git is alive and lsof times out reading cwds" 'rc=124.*cannot read cwds'
  # lsof answering rc 1 with NO output for a live git pid = its cwd is unreadable (the per-process guard)
  : > "$LOG"; count=$(PATH="$LVR/shim-lsof-1:$PATH" _scan_repo "$L11"); lv_cleanup
  t36 "a live git whose cwd lsof cannot report (rc 1, no output)" 'git pid [0-9]+ cwd unreadable'
  # the HOLDER check on its own: the stub says "no git process", so only lsof-on-the-lock can decide
  : > "$LOG"; count=$(GIT_LOCK_PROCESS_CHECK_FN=_no_git_process PATH="$LVR/shim-lsof-124:$PATH" _scan_repo "$L11")
  t36 "no git process, lsof times out asking who holds the lock" 'cannot tell who holds the lock'
  if PATH="/usr/bin:/bin:/usr/sbin:/sbin" command -v timeout >/dev/null 2>&1; then
    echo "  skip T36 (no timeout): this host has timeout in the base PATH"
  else
    : > "$LOG"; count=$(GIT_LOCK_PROCESS_CHECK_FN=_no_git_process PATH="/usr/bin:/bin:/usr/sbin:/sbin" _scan_repo "$L11")
    t36 "no timeout binary (a deadline cannot be enforced, so lsof is not run unbounded)" 'rc=127.*cannot tell who holds the lock'
  fi
  : > "$LOG"; count=$(_scan_repo "$L11")
  [ ! -f "$L11/.git/index.lock" ] && ok "T36: control — same lock, healthy ps/lsof → removed" \
    || bad "T36: control failed — lock still there with healthy ps/lsof"

  # T37-T40: an EXPLICIT git dir decides, not the cwd. Measured live 2026-10-02: a maintenance
  # `git --git-dir=<store>/.gc/runtime/packs/maintenance/jsonl-archive/.git gc` (and its
  # pack-objects child) stands in the HQ store dir, whose nearest enclosing repo is the HQ root —
  # cwd attribution kept the HQ root "live" for ~70% of samples although it never touched that repo.
  echo "T37: stale index.lock + 'git --git-dir=<OTHER>/.git' standing in the root → removed"
  L12="$LVR/lv12"; make_repo "$L12"; make_repo "$LVR/lv12-other"
  lv_old "$L12/.git/index.lock"
  lv_proc git "$L12" "--git-dir=$LVR/lv12-other/.git" gc
  count=$(_scan_repo "$L12"); lv_cleanup
  [ ! -f "$L12/.git/index.lock" ] && ok "T37: lock removed — an explicit foreign git dir beats the cwd" \
    || bad "T37: lock kept because a git on ANOTHER git dir stands in this repo's directory"
  # The separate-argument form. Standing in the root, a git whose '--git-dir <p>' is not parsed would
  # be attributed by its cwd and KEEP the lock — so a removal here is only possible if the space
  # form is read as the explicit git dir it is.
  lv_old "$L12/.git/index.lock"   # touch re-creates the lock T37 just removed, aged
  lv_proc git "$L12" --git-dir "$LVR/lv12-other/.git" gc
  count=$(_scan_repo "$L12"); lv_cleanup
  [ ! -f "$L12/.git/index.lock" ] && ok "T37: lock removed — '--git-dir <OTHER>/.git' in the separate-argument form too" \
    || bad "T37: lock kept under 'git --git-dir <OTHER>/.git' (space form) standing in the root — the form is not parsed"

  echo "T38: stale index.lock + 'git --git-dir=<root>/.repo.git' (a separate bare repo beside .git) → removed"
  L13="$LVR/lv13"; make_repo "$L13"; mkdir -p "$L13/.repo.git"
  lv_old "$L13/.git/index.lock"
  lv_proc git / "--git-dir=$L13/.repo.git" rev-list --count HEAD
  lv_proc git "$L13" "--git-dir=$L13/.repo.git" rev-list --count HEAD
  count=$(_scan_repo "$L13"); lv_cleanup
  [ ! -f "$L13/.git/index.lock" ] && ok "T38: lock removed — <root>/.repo.git is not <root>/.git" \
    || bad "T38: lock kept because of a git on the sibling bare repo <root>/.repo.git"

  # GIT_DIR in the ENVIRONMENT (what children of `git --git-dir=X` and git hooks carry) is read
  # with `ps -E`, which macOS hides for SIP-protected binaries (/bin/bash, /usr/bin/perl): these
  # need a non-SIP interpreter, and say so when the host has none instead of passing vacuously.
  _lv_bash=""
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$_c" ] && { _lv_bash="$_c"; break; }; done
  # lv_env_proc <GIT_DIR value> <cwd> — a process named git, GIT_DIR in its env, parked on a fifo.
  lv_env_proc() {
    local gd="$1" cwd="$2" pid i fifo="$LVR/fifo.$RANDOM"
    mkfifo "$fifo"
    ( cd "$cwd" && GIT_DIR="$gd" exec -a git "$_lv_bash" -c 'read _ < "$1"' _ "$fifo" ) >/dev/null 2>&1 &
    pid=$!; LV_PIDS="$LV_PIDS $pid"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
      [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "git" ] && break; sleep 0.2
    done
    LV_ENV_VISIBLE=0
    ps -E -p "$pid" -o args= 2>/dev/null | tr -s ' \t' '\n' | awk '/^GIT_DIR=/ { f = 1 } END { exit !f }' && LV_ENV_VISIBLE=1
  }
  if [ -z "$_lv_bash" ]; then
    echo "T39/T40: SKIPPED — no non-SIP bash on this host (ps -E cannot show GIT_DIR of SIP binaries)"
  else
    echo "T39: stale index.lock + a git with GIT_DIR=<OTHER>/.git in its ENV, standing in the root → removed"
    L14="$LVR/lv14"; make_repo "$L14"; make_repo "$LVR/lv14-other"
    lv_old "$L14/.git/index.lock"
    lv_env_proc "$LVR/lv14-other/.git" "$L14"
    if [ "$LV_ENV_VISIBLE" != 1 ]; then
      echo "  skip T39: ps -E does not show the env of $_lv_bash here"; lv_cleanup
    else
      count=$(_scan_repo "$L14"); lv_cleanup
      [ ! -f "$L14/.git/index.lock" ] && ok "T39: lock removed — GIT_DIR from the environment names another repo" \
        || bad "T39: lock kept because of a git whose env GIT_DIR names another repo"
    fi
    echo "T40: stale index.lock + a git with the hook-style RELATIVE GIT_DIR=.git, standing in the root → kept"
    L15="$LVR/lv15"; make_repo "$L15"
    lv_old "$L15/.git/index.lock"
    lv_env_proc ".git" "$L15"
    if [ "$LV_ENV_VISIBLE" != 1 ]; then
      echo "  skip T40: ps -E does not show the env of $_lv_bash here"; lv_cleanup
    else
      count=$(_scan_repo "$L15"); lv_cleanup
      if [ -f "$L15/.git/index.lock" ] && lv_logged "$L15/.git/index.lock" 'git-dir is this repo'; then
        ok "T40: lock kept BY the git-dir rule — relative GIT_DIR resolved to this repo (not the cwd fallback)"
      else
        bad "T40: lock gone, or kept by something other than the relative-GIT_DIR resolution"
      fi
    fi
  fi

  # T41: the case the open-file check CANNOT cover, with a REAL git. A partial commit parked in its
  # editor leaves index.lock in place with no open fd (measured 2026-10-02) — only the process
  # check keeps it. If a future "simplification" made lsof the sole owner test, this goes red.
  echo "T41: real 'git commit <path>' parked in an editor holds index.lock with no open fd → kept"
  L16="$LVR/lv16"; mkdir -p "$L16"
  ( cd "$L16" && git init -q . && git config user.email t@t && git config user.name t \
      && echo a > f1 && echo b > f2 && git add f1 f2 && git commit -qm init && echo a2 >> f1 ) >/dev/null 2>&1
  # The editor outlives the whole test (15 s): on a loaded host a short sleep let git finish and
  # remove its OWN lock before the scan, which reads exactly like the janitor removing it.
  ( cd "$L16" && GIT_EDITOR='sleep 15; :' git commit f1 >/dev/null 2>&1 ) &
  LV_PIDS="$LV_PIDS $!"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    [ -e "$L16/.git/index.lock" ] && break; sleep 0.2
  done
  if [ ! -e "$L16/.git/index.lock" ]; then
    bad "T41: premise failed — the parked commit never took index.lock"
  else
    lv_old "$L16/.git/index.lock"
    count=$(_scan_repo "$L16")      # straight after the lock appears; the slow premise probe comes after
    _t41_alive=0; ps -axo pid=,comm=,args= | awk '$2 == "git" && /commit f1/ { f = 1 } END { exit !f }' && _t41_alive=1
    if [ -f "$L16/.git/index.lock" ]; then
      ok "T41: lock kept — live 'git commit f1' in the repo"
      lv_logged "$L16/.git/index.lock" 'git pid [0-9]+ cwd in repo' \
        && ok "T41: kept by the process check (cwd in repo), the only signal that covers a parked editor" \
        || bad "T41: kept, but not by 'git pid N cwd in repo' — the process check did not own this lock"
    elif [ "$_t41_alive" = 1 ]; then
      bad "T41: lock REMOVED under a live parked 'git commit <path>'"
    else
      bad "T41: inconclusive — git exited before the scan finished (host too slow for the 15 s editor)"
    fi
    [ -z "$(lsof -t -- "$L16/.git/index.lock" 2>/dev/null)" ] \
      && echo "  (premise holds: nobody has index.lock open while git waits in the editor)" \
      || echo "  (note: this git keeps the fd open while parked — the process check is then belt-and-braces)"
  fi
  lv_cleanup

  # T42: a RELATIVE `-C` from outside the repo — `cd <parent>; git -C lv17 commit` — names no
  # absolute path and its cwd is not the repo, so cwd/argv-token attribution alone misses it and
  # the janitor would delete the lock under a live writer (the dangerous direction).
  echo "T42: stale index.lock + 'git -C <relative>' started from the repo's PARENT directory → kept"
  L17="$LVR/lv17"; make_repo "$L17"; mkdir -p "$L17/sub"
  lv_old "$L17/.git/index.lock"
  lv_proc git "$LVR" -C lv17 status
  count=$(_scan_repo "$L17"); lv_cleanup
  [ -f "$L17/.git/index.lock" ] && ok "T42: lock kept — relative -C resolved against the cwd lands in the repo" \
    || bad "T42: lock REMOVED under a live 'git -C <relative>' that works in the repo"
  lv_logged "$L17/.git/index.lock" 'git pid [0-9]+ -C resolves into repo' \
    && ok "T42: kept by ITS branch (-C resolves into the repo; cwd and argv name nothing)" \
    || bad "T42: no skipped_live event with reason '-C resolves into repo' for $L17/.git/index.lock"
  : > "$LOG"
  lv_proc git "$LVR" -C lv17 -C sub status
  count=$(_scan_repo "$L17"); lv_cleanup
  [ -f "$L17/.git/index.lock" ] && ok "T42: lock kept — chained relative -C (-C lv17 -C sub) composes" \
    || bad "T42: lock REMOVED under a live 'git -C lv17 -C sub'"
  lv_logged "$L17/.git/index.lock" 'git pid [0-9]+ -C resolves into repo' \
    && ok "T42: chained form kept by ITS branch too" \
    || bad "T42: chained -C kept, but not by '-C resolves into repo'"

  # T43: git applies -C BEFORE it reads a relative git dir, so `git -C <root> --git-dir=.git ...`
  # started from ANOTHER repo works on <root>/.git. Resolving the relative path against the process
  # cwd instead reads it as the other repo's git dir and drops the lock under a live git.
  echo "T43: stale index.lock + 'git -C <root> --git-dir=.git' started from ANOTHER repo → kept"
  L18="$LVR/lv18"; make_repo "$L18"; make_repo "$LVR/lv18-other"
  lv_old "$L18/.git/index.lock"
  lv_proc git "$LVR/lv18-other" -C "$L18" --git-dir=.git status
  count=$(_scan_repo "$L18"); lv_cleanup
  if [ -f "$L18/.git/index.lock" ] && lv_logged "$L18/.git/index.lock" 'git-dir is this repo'; then
    ok "T43: lock kept — relative --git-dir resolved against the -C directory"
  else
    bad "T43: lock removed (or kept for another reason) under a live 'git -C <root> --git-dir=.git' run from another repo"
  fi
  # The space form must be kept BY THE git-dir BRANCH. Without the `--git-dir <p>` parse the lock is
  # still kept (-C <root> is an absolute argv token → "argv names repo"), so keeping alone proves
  # nothing about the form — the reason is what shows the parse ran.
  : > "$LOG"
  lv_proc git "$LVR/lv18-other" -C "$L18" --git-dir .git status
  count=$(_scan_repo "$L18"); lv_cleanup
  if [ -f "$L18/.git/index.lock" ] && lv_logged "$L18/.git/index.lock" 'git-dir is this repo'; then
    ok "T43: lock kept by the git-dir branch — separate-argument form '--git-dir .git' too"
  else
    bad "T43: lock removed (or kept by another branch) under a live 'git -C <root> --git-dir .git' run from another repo"
  fi

  # T44: _is_stale reads the age, THEN probes (ps, lsof up to 10 s, per-pid ps), THEN the caller
  # deletes. A lock removed and re-created by a new git while the probe ran is young again, and a
  # lock that vanished is not ours to remove or to count. The probe stubs below do exactly that:
  # they change the lock mid-probe and answer "no live process".
  echo "T44: the lock is replaced (fresh) or gone by the time the probe finishes → not removed, not counted"
  T44_LOCK=""
  _t44_replace() { : > "$T44_LOCK"; return 1; }                  # a NEW git took the lock: age ~0
  _t44_vanish()  { rm -f "$T44_LOCK"; return 1; }                # its owner finished and removed it
  R44="$LVR/lv44"; make_repo "$R44"; T44_LOCK="$R44/.git/index.lock"
  lv_old "$T44_LOCK"; : > "$LOG"
  count=$(GIT_LOCK_PROCESS_CHECK_FN=_t44_replace _scan_repo "$R44" 2>/dev/null)
  [ -f "$T44_LOCK" ] && ok "T44: the replaced (now fresh) lock was kept" \
    || bad "T44: a lock that became FRESH during the probe was removed on the strength of the old age"
  [ "$count" = "0" ] && ok "T44: removed count=0" || bad "T44: removed count=$count (expected 0)"
  ! grep -qF '"event":"removed"' "$LOG" && ok "T44: no 'removed' event was written for it" \
    || bad "T44: a 'removed' event was logged for a lock that was not stale any more"
  lv_old "$T44_LOCK"; : > "$LOG"
  count=$(GIT_LOCK_PROCESS_CHECK_FN=_t44_vanish _scan_repo "$R44" 2>/dev/null)
  [ "$count" = "0" ] && ok "T44: a lock that vanished during the probe is not counted as removed" \
    || bad "T44: removed count=$count for a lock that vanished during the probe (expected 0)"
  ! grep -qF '"event":"removed"' "$LOG" && ok "T44: no 'removed' event for the vanished lock" \
    || bad "T44: a 'removed' event was logged for a lock that vanished on its own"

  # T45: what a sweep leaves alone is COUNTED, by its cause — the review's "fail-open must be visible
  # AND counted". skipped_live = every aged item left alone; undetermined = the could-not-tell subset
  # (a broken ps/lsof/timeout keeps EVERY aged lock, so it is the number to watch); stale_state =
  # operation state reported but not removed. Counted from a flag, not from the reason's wording.
  echo "T45: items left alone are tallied by cause (skipped_live / undetermined / stale_state)"
  CF="$LVR/tally.txt"
  _tally() { awk -v k="$1" '$0 == k { n++ } END { print n + 0 }' "$CF"; }
  _t45() {   # _t45 <label> <skipped_live> <undetermined> <stale_state>
    if [ "$(_tally skipped_live)" = "$2" ] && [ "$(_tally undetermined)" = "$3" ] && [ "$(_tally stale_state)" = "$4" ]; then
      ok "T45: $1 → skipped_live=$2 undetermined=$3 stale_state=$4"
    else
      bad "T45: $1 → got skipped_live=$(_tally skipped_live) undetermined=$(_tally undetermined) stale_state=$(_tally stale_state); expected $2/$3/$4"
    fi
  }
  R45="$LVR/lv45"; make_repo "$R45"; lv_old "$R45/.git/index.lock"
  _GLH_COUNT_FILE="$CF"
  : > "$CF"; count=$(GIT_LOCK_PROCESS_CHECK_FN=_yes_git_process _scan_repo "$R45" 2>/dev/null)
  _t45 "a KNOWN live git (not a guess)" 1 0 0
  : > "$CF"; count=$(PATH="$LVR/shim-ps-fail:$PATH" _scan_repo "$R45" 2>/dev/null)
  _t45 "ps fails — the broken-ps case that keeps every lock" 1 1 0
  : > "$CF"; count=$(GIT_LOCK_PROCESS_CHECK_FN=_no_git_process PATH="$LVR/shim-lsof-124:$PATH" _scan_repo "$R45" 2>/dev/null)
  _t45 "lsof times out asking who holds the lock" 1 1 0
  lv_proc git / -C "$LVR/somewhere-else" status
  : > "$CF"; count=$(PATH="$LVR/shim-lsof-124:$PATH" _scan_repo "$R45" 2>/dev/null); lv_cleanup
  _t45 "a git is alive and lsof times out reading cwds" 1 1 0
  R45S="$LVR/lv45s"; make_repo "$R45S"; lv_old "$R45S/.git/MERGE_HEAD"
  : > "$CF"; count=$(GIT_LOCK_PROCESS_CHECK_FN=_no_git_process _scan_repo "$R45S" 2>/dev/null)
  _t45 "an aged MERGE_HEAD on a quiet repo" 0 0 1
  : > "$CF"; count=$(_scan_repo "$R45" 2>/dev/null)
  _t45 "control — healthy ps/lsof, the lock is removed, nothing tallied" 0 0 0
  _GLH_COUNT_FILE=""

  # T46: the sweep's own summary line carries the tallies — the one place an operator or a watchdog
  # looks. Run the real script as a sweep over scratch roots (caller-set GIT_LOCK_RIG_ROOTS: no gc).
  echo "T46: the sweep summary event reports removed / skipped_live / undetermined / stale_state"
  SW_LOG="$LVR/sweep.jsonl"
  _sweep_line() {   # _sweep_line <root> [PATH prefix] — the last sweep event the script wrote
    : > "$SW_LOG"
    env -u GIT_LOCK_PROCESS_CHECK_FN GIT_LOCK_LOG="$SW_LOG" GIT_LOCK_RIG_ROOTS="$1" GIT_LOCK_ENABLED=1 \
        GIT_LOCK_DRY_RUN=0 NOTIFY_BIN=/nonexistent PATH="${2:+$2:}$PATH" bash "$_GLH_SELF" >/dev/null 2>&1
    grep -F '"event":"sweep"' "$SW_LOG" | tail -1
  }
  R46="$LVR/lv46"; make_repo "$R46"; lv_old "$R46/.git/index.lock"
  line=$(_sweep_line "$R46" "$LVR/shim-ps-fail")
  case "$line" in
    *'"removed":0,"skipped_live":1,"undetermined":1,"stale_state":0,'*) ok "T46: broken ps → removed=0 skipped_live=1 undetermined=1 (the lock was kept, and the sweep says why)" ;;
    *) bad "T46: broken-ps sweep summary lacks the tallies: ${line:-<no sweep event>}" ;;
  esac
  [ -f "$R46/.git/index.lock" ] && ok "T46: the lock survived the blind sweep" || bad "T46: the lock was removed by a sweep that could not tell"
  R46B="$LVR/lv46b"; make_repo "$R46B"; lv_old "$R46B/.git/index.lock"; lv_old "$R46B/.git/MERGE_HEAD"
  line=$(_sweep_line "$R46B")
  case "$line" in
    *'"removed":1,"skipped_live":0,"undetermined":0,"stale_state":1,'*) ok "T46: healthy sweep → removed=1 (the lock) stale_state=1 (the MERGE_HEAD, reported)" ;;
    *) bad "T46: healthy sweep summary wrong: ${line:-<no sweep event>}" ;;
  esac
  [ ! -f "$R46B/.git/index.lock" ] && [ -f "$R46B/.git/MERGE_HEAD" ] \
    && ok "T46: lock removed, MERGE_HEAD left in place" || bad "T46: wrong files survived the healthy sweep"
  export GIT_LOCK_PROCESS_CHECK_FN="_no_git_process"   # restore the stub the mutex tests below expect

  # ── In-progress OPERATION state is detect-only (ga-892qy1) ──────────────────
  # MERGE_HEAD / CHERRY_PICK_HEAD / REVERT_HEAD / rebase-merge/ / rebase-apply/ are the state of
  # an operation that may be PAUSED FOR A HUMAN (conflict, editor, a 10-minute break) — and a
  # paused operation has no git process, exactly like a crashed one. Age + no-process cannot tell
  # them apart, so those five are reported, never removed. The *.lock files and the PID-tagged
  # index locks keep their removal: a lock has no "paused for a human" reading.
  export GIT_LOCK_PROCESS_CHECK_FN="_no_git_process"
  export GIT_LOCK_STALE_AGE_SEC=300
  GIT_LOCK_STATE_RENOTIFY_SEC=43200

  # T47: the whole class — every one of the five items survives and is reported once, not just the
  # two T4/T5 happen to cite (the story's own bead named MERGE_HEAD and rebase-merge in the title
  # but the code carries five).
  echo "T47: CHERRY_PICK_HEAD, REVERT_HEAD, rebase-apply/ — the rest of the class — survive and are reported"
  R17="$TMP/repo17"; make_repo "$R17"
  touch -t 200001010000 "$R17/.git/CHERRY_PICK_HEAD" "$R17/.git/REVERT_HEAD"
  mkdir -p "$R17/.git/rebase-apply"; touch -t 200001010000 "$R17/.git/rebase-apply"
  : > "$LOG"; rm -rf "$GIT_LOCK_STATE_DIR"
  count=$(_scan_repo "$R17")
  [ -f "$R17/.git/CHERRY_PICK_HEAD" ] && ok "T47: CHERRY_PICK_HEAD kept" || bad "T47: CHERRY_PICK_HEAD removed"
  [ -f "$R17/.git/REVERT_HEAD" ] && ok "T47: REVERT_HEAD kept" || bad "T47: REVERT_HEAD removed"
  [ -d "$R17/.git/rebase-apply" ] && ok "T47: rebase-apply/ kept" || bad "T47: rebase-apply/ removed"
  [ "$(_events stale_state_found)" = "3" ] && ok "T47: 3 stale_state_found events (one per item)" \
    || bad "T47: expected 3 stale_state_found events, got $(_events stale_state_found)"
  [ "$count" = "0" ] && ok "T47: removed count=0" || bad "T47: removed count='$count' (expected 0)"

  # T48: a FRESH state item (< STALE_AGE) is a live operation by definition — no event, no notify.
  echo "T48: fresh MERGE_HEAD (<STALE_AGE) → silent"
  R18="$TMP/repo18"; make_repo "$R18"
  touch "$R18/.git/MERGE_HEAD"   # just created
  : > "$LOG"; : > "$NOTIFY_CALLS"
  count=$(_scan_repo "$R18")
  [ -f "$R18/.git/MERGE_HEAD" ] && ok "T48: fresh MERGE_HEAD untouched" || bad "T48: fresh MERGE_HEAD removed"
  [ "$(_events stale_state_found)" = "0" ] && [ "$(_lines "$NOTIFY_CALLS")" = "0" ] \
    && ok "T48: no event, no notify for a fresh item" \
    || bad "T48: fresh item reported (events=$(_events stale_state_found) notify=$(_lines "$NOTIFY_CALLS"))"

  # T49: old state item BUT a live git process in the repo → the operation is running, say nothing.
  echo "T49: old MERGE_HEAD + live git process → silent"
  R19="$TMP/repo19"; make_repo "$R19"
  touch -t 200001010000 "$R19/.git/MERGE_HEAD"
  export GIT_LOCK_PROCESS_CHECK_FN="_yes_git_process"
  : > "$LOG"; : > "$NOTIFY_CALLS"
  count=$(_scan_repo "$R19")
  export GIT_LOCK_PROCESS_CHECK_FN="_no_git_process"
  [ -f "$R19/.git/MERGE_HEAD" ] && [ "$(_events stale_state_found)" = "0" ] && [ "$(_lines "$NOTIFY_CALLS")" = "0" ] \
    && ok "T49: live process → kept, no event, no notify" \
    || bad "T49: live-process repo reported or touched (events=$(_events stale_state_found) notify=$(_lines "$NOTIFY_CALLS"))"

  # T50: notify dedupe. The janitor sweeps every ~5.5 min; a merge left paused for an afternoon
  # must NOT page 40 times. Event is logged EVERY sweep (state over time stays reconstructable,
  # and the existing log already carries a `sweep` line per run); notify only on first sight.
  echo "T50: same paused item across sweeps → event every sweep, notify once"
  R20="$TMP/repo20"; make_repo "$R20"
  touch -t 200001010000 "$R20/.git/MERGE_HEAD"
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  count=$(_scan_repo "$R20"); count2=$(_scan_repo "$R20"); count3=$(_scan_repo "$R20")
  [ "$(_events stale_state_found)" = "3" ] && ok "T50: event logged on each of 3 sweeps" \
    || bad "T50: expected 3 events, got $(_events stale_state_found)"
  [ "$(_lines "$NOTIFY_CALLS")" = "1" ] && ok "T50: notified exactly once across 3 sweeps" \
    || bad "T50: notify called $(_lines "$NOTIFY_CALLS") times across 3 sweeps (expected 1)"
  # The fake notify prints to STDOUT like the real one. If that reaches the capture, the sweep's
  # `total_removed + n` arithmetic dies on "Logged for digest ...".
  [ "$count" = "0" ] && [ "$count2" = "0" ] && [ "$count3" = "0" ] \
    && ok "T50: notify stdout does not leak into the captured count" \
    || bad "T50: notify stdout leaked into the count capture: '$count' '$count2' '$count3'"
  grep -qE 'MERGE_HEAD|merge' "$NOTIFY_CALLS" && ok "T50: notify text names the item" \
    || bad "T50: notify text does not name the item: $(cat "$NOTIFY_CALLS")"

  # T51: a NEW operation at the same path (different mtime) is a new thing — notify again, even
  # inside the renotify window. Otherwise finishing a merge and starting another within 12 h
  # would be silent.
  echo "T51: same path, new operation (mtime changed) → notified again"
  touch -t 200002020000 "$R20/.git/MERGE_HEAD"
  count=$(_scan_repo "$R20")
  [ "$(_lines "$NOTIFY_CALLS")" = "2" ] && ok "T51: second operation notified" \
    || bad "T51: notify count $(_lines "$NOTIFY_CALLS") after a new operation (expected 2)"

  # T52: and the SAME item is re-announced after the renotify window, so a forgotten paused
  # operation does not stay silent forever.
  echo "T52: same item after the renotify window → notified again"
  GIT_LOCK_STATE_RENOTIFY_SEC=0
  count=$(_scan_repo "$R20")
  [ "$(_lines "$NOTIFY_CALLS")" = "3" ] && ok "T52: re-announced once the window elapsed" \
    || bad "T52: notify count $(_lines "$NOTIFY_CALLS") with RENOTIFY=0 (expected 3)"
  GIT_LOCK_STATE_RENOTIFY_SEC=43200

  # T53: DRY_RUN=1 — the event is still logged (detection is the whole point), nothing is
  # notified, nothing is touched. Matches the sweep's own "no notify under dry run".
  echo "T53: DRY_RUN=1 → event logged, no notify"
  R21="$TMP/repo21"; make_repo "$R21"
  touch -t 200001010000 "$R21/.git/MERGE_HEAD"
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  DRY_RUN=1 _scan_repo "$R21" > /dev/null
  DRY_RUN=0
  [ "$(_events stale_state_found)" = "1" ] && [ "$(_lines "$NOTIFY_CALLS")" = "0" ] && [ -f "$R21/.git/MERGE_HEAD" ] \
    && ok "T53: dry-run logs the detection, does not notify, keeps the file" \
    || bad "T53: dry-run misbehaved (events=$(_events stale_state_found) notify=$(_lines "$NOTIFY_CALLS"))"

  # T54: the lock half of the contract is UNCHANGED — in the same repo a stale index.lock is still
  # removed (and counted) while the stale MERGE_HEAD beside it is kept (and not counted).
  echo "T54: stale index.lock removed, stale MERGE_HEAD beside it kept"
  R22="$TMP/repo22"; make_repo "$R22"
  touch -t 200001010000 "$R22/.git/index.lock" "$R22/.git/MERGE_HEAD"
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  count=$(_scan_repo "$R22")
  [ ! -f "$R22/.git/index.lock" ] && ok "T54: stale index.lock still removed" || bad "T54: stale index.lock NOT removed"
  [ -f "$R22/.git/MERGE_HEAD" ] && ok "T54: MERGE_HEAD beside it kept" || bad "T54: MERGE_HEAD removed"
  [ "$count" = "1" ] && ok "T54: removed count=1 (the lock only)" || bad "T54: removed count='$count' (expected 1)"

  # T55: END-TO-END through the real sweep entrypoint, not just _scan_repo. The sweep does
  # `total_removed + n` on the captured count and notifies on removals; this is the path that
  # breaks if a state notice ever leaks onto stdout. `env -u GIT_LOCK_PROCESS_CHECK_FN`: the
  # parent exported a FUNCTION NAME that does not exist in the child shell.
  #
  # The fixture lives under a dir whose name has no "git" in it, on purpose. This is the one test
  # that runs the REAL _git_repo_has_live_process (`ps aux | grep '[g]it' | grep -F "$repo"`), and
  # that pipeline's last grep appears in the ps listing carrying the repo path in its own argv: if
  # the path itself contains "git" (this selftest's $TMP is git-lock-hygiene-selftest.*), the line
  # survives the first grep and the check matches ITSELF — a permanent false "live process", so
  # nothing is ever judged stale. No real rig root has "git" in its path, which is why production is
  # unaffected; the stubbed tests above never reach that code.
  echo "T55: real sweep — lock removed, state kept + reported, summary line sane"
  T55_BASE="$(mktemp -d "${TMPDIR:-/tmp}/glh-e2e.XXXXXX")"
  R23="$T55_BASE/repo23"; make_repo "$R23"
  touch -t 200001010000 "$R23/.git/index.lock" "$R23/.git/MERGE_HEAD"
  mkdir -p "$R23/.git/rebase-merge"; touch -t 200001010000 "$R23/.git/rebase-merge"
  T55_LOG="$TMP/t55.jsonl"; : > "$T55_LOG"; : > "$NOTIFY_CALLS"
  env -u GIT_LOCK_PROCESS_CHECK_FN GIT_LOCK_RIG_ROOTS="$R23" GIT_LOCK_LOG="$T55_LOG" \
      NOTIFY_BIN="$NOTIFY_BIN" GIT_LOCK_STATE_DIR="$TMP/t55-state" GC_CITY_PATH="$TMP/t55-city" \
      bash "$_GLH_SELF" >/dev/null 2>"$TMP/t55.err"
  _t55_rc=$?
  [ "$_t55_rc" -eq 0 ] && ok "T55: sweep exited 0" || bad "T55: sweep exited $_t55_rc — stderr: $(head -c 400 "$TMP/t55.err")"
  [ ! -f "$R23/.git/index.lock" ] && [ -f "$R23/.git/MERGE_HEAD" ] && [ -d "$R23/.git/rebase-merge" ] \
    && ok "T55: lock gone, MERGE_HEAD and rebase-merge/ intact" \
    || bad "T55: wrong survivors after the sweep"
  [ "$(grep -c '"event":"stale_state_found"' "$T55_LOG")" = "2" ] \
    && ok "T55: 2 stale_state_found events (MERGE_HEAD, rebase-merge)" \
    || bad "T55: expected 2 stale_state_found events: $(cat "$T55_LOG" | cut -c1-200)"
  grep -q '"event":"sweep".*"removed":1,' "$T55_LOG" && ok "T55: sweep summary says removed=1" \
    || bad "T55: sweep summary wrong: $(grep '"event":"sweep"' "$T55_LOG")"
  [ "$(_lines "$NOTIFY_CALLS")" = "3" ] && ok "T55: 3 notifications (2 state items + 1 removal summary)" \
    || bad "T55: notify calls $(_lines "$NOTIFY_CALLS") (expected 3): $(cat "$NOTIFY_CALLS")"

  # T56-T59: the three-state contract of _report_stale_state — what it does when it CANNOT know.
  # T56: the item is gone by the time it is reported. _path_age answers 999999999 for "cannot stat";
  # logging that as an age would record a very old stuck operation that does not exist.
  echo "T56: item vanished before the report → nothing logged, nothing notified"
  R24="$TMP/repo24"; make_repo "$R24"
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  _report_stale_state "$R24/.git/MERGE_HEAD" "$R24" "in-progress merge" "merge --abort" 2>"$TMP/t56.err" >/dev/null
  { [ "$(_events stale_state_found)" = "0" ] && [ "$(_lines "$NOTIFY_CALLS")" = "0" ] \
      && ! grep -q 999999999 "$LOG" "$TMP/t56.err"; } \
    && ok "T56: a vanished item is not reported (no event, no notify, no sentinel age)" \
    || bad "T56: vanished item was reported — events=$(_events stale_state_found) notify=$(_lines "$NOTIFY_CALLS") log: $(head -c 240 "$LOG")"
  # Same, through the real call site: _glh_reap is what the sweep calls, and the sentinel-age hole
  # (an event with age_sec=999999999 for an item that is not there) lived in ITS inline log block.
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  _glh_reap "$R24/.git/MERGE_HEAD" "$R24" "in-progress merge" "merge --abort" 2>"$TMP/t56b.err" >/dev/null
  _t56_rc=$?
  { [ "$_t56_rc" = "1" ] && [ "$(_events stale_state_found)" = "0" ] && [ "$(_lines "$NOTIFY_CALLS")" = "0" ] \
      && ! grep -q 999999999 "$LOG" "$TMP/t56b.err"; } \
    && ok "T56: through _glh_reap too — vanished item: not reported, not counted removed, no sentinel age" \
    || bad "T56: _glh_reap on a vanished item — rc=$_t56_rc events=$(_events stale_state_found) notify=$(_lines "$NOTIFY_CALLS") log: $(head -c 240 "$LOG")"

  # T57: the item exists but its mtime cannot be read. It is still reported — it is there — with
  # the age as null, never as a number; and it is announced once (the marker identity is "unknown").
  echo "T57: mtime unreadable → reported with age_sec=null, notified once"
  R25="$TMP/repo25"; make_repo "$R25"
  touch -t 200001010000 "$R25/.git/MERGE_HEAD"
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  _T57_SAVED_MTIME="$(declare -f _path_mtime)"
  _path_mtime() { :; }
  _report_stale_state "$R25/.git/MERGE_HEAD" "$R25" "in-progress merge" "merge --abort" 2>"$TMP/t57.err" >/dev/null
  _report_stale_state "$R25/.git/MERGE_HEAD" "$R25" "in-progress merge" "merge --abort" 2>>"$TMP/t57.err" >/dev/null
  eval "$_T57_SAVED_MTIME"
  { [ "$(_events stale_state_found)" = "2" ] && grep -q '"age_sec":null' "$LOG" && ! grep -q '"age_sec":[0-9]' "$LOG"; } \
    && ok "T57: event logged with age_sec=null on each sweep" \
    || bad "T57: expected 2 events with age_sec=null — log: $(head -c 300 "$LOG")"
  [ "$(_lines "$NOTIFY_CALLS")" = "1" ] && grep -q 'tempo desconhecido' "$NOTIFY_CALLS" \
    && ok "T57: announced once, the text says the time is unknown" \
    || bad "T57: notify calls=$(_lines "$NOTIFY_CALLS") text: $(cat "$NOTIFY_CALLS")"

  # T58: the notifier FAILS. The failure must be visible on stderr and must NOT be recorded as
  # delivered (no marker), so the next sweep tries again; once it works, the marker is written.
  echo "T58: notify fails → visible, not recorded as announced, retried next sweep"
  R26="$TMP/repo26"; make_repo "$R26"
  touch -t 200001010000 "$R26/.git/MERGE_HEAD"
  : > "$LOG"; : > "$NOTIFY_CALLS"; rm -rf "$GIT_LOCK_STATE_DIR"
  _T58_REAL_NOTIFY="$NOTIFY_BIN"
  NOTIFY_BIN="$TMP/failing-notify"
  printf '#!/bin/sh\necho "$*" >> "$NOTIFY_CALLS"\nexit 1\n' > "$NOTIFY_BIN"; chmod +x "$NOTIFY_BIN"
  count=$(_scan_repo "$R26" 2>"$TMP/t58.err")
  grep -q 'notify FAILED' "$TMP/t58.err" && ok "T58: the failed notify is visible on stderr" \
    || bad "T58: a failed notify was silent — stderr: $(head -c 300 "$TMP/t58.err")"
  [ -z "$(ls -A "$GIT_LOCK_STATE_DIR" 2>/dev/null)" ] && ok "T58: nothing recorded as announced" \
    || bad "T58: a marker was written for a notify that failed: $(ls "$GIT_LOCK_STATE_DIR")"
  count=$(_scan_repo "$R26" 2>/dev/null)
  [ "$(_lines "$NOTIFY_CALLS")" = "2" ] && ok "T58: retried on the next sweep" \
    || bad "T58: notify attempts=$(_lines "$NOTIFY_CALLS") after 2 sweeps (expected 2)"
  NOTIFY_BIN="$_T58_REAL_NOTIFY"

  # T59: there is NO notifier. The detection stays in the log, and stderr says it was not announced
  # — a missing binary must not look like "nothing to tell anyone".
  echo "T59: NOTIFY_BIN not executable → event logged, stderr says not announced"
  R27="$TMP/repo27"; make_repo "$R27"
  touch -t 200001010000 "$R27/.git/MERGE_HEAD"
  : > "$LOG"; rm -rf "$GIT_LOCK_STATE_DIR"
  NOTIFY_BIN="$TMP/no-such-notify"
  count=$(_scan_repo "$R27" 2>"$TMP/t59.err")
  NOTIFY_BIN="$_T58_REAL_NOTIFY"
  [ "$(_events stale_state_found)" = "1" ] && ok "T59: the event is logged without a notifier" \
    || bad "T59: expected 1 event, got $(_events stale_state_found)"
  grep -q 'NOT announced' "$TMP/t59.err" && ok "T59: stderr says the item was not announced" \
    || bad "T59: missing notifier was silent — stderr: $(head -c 300 "$TMP/t59.err")"

  # ── Mutex tests ─────────────────────────────────────────────────────────────
  echo ""
  export GIT_REPO_MUTEX_BASE="$TMP/mutexes"
  export GIT_REPO_MUTEX_ENABLED=1

  # T8: acquire succeeds on fresh lock dir
  echo "T8: mutex acquire on clean repo"
  M_REPO="$TMP/mrepo"
  git_mutex_acquire "$M_REPO" && ok "T8: acquired" || bad "T8: acquire failed"
  [ -d "$(_mutex_dir "$M_REPO")" ] && ok "T8: lock dir created" || bad "T8: lock dir missing"

  # T9: second acquire (same session, held) → fails
  echo "T9: double-acquire while held → fails"
  # We have _GIT_MUTEX_TOKEN set from T8. Use a subshell so it has different vars.
  git_mutex_acquire "$M_REPO" 2>/dev/null && bad "T9: second acquire succeeded (should fail)" \
    || ok "T9: second acquire correctly rejected"

  # T10: release → lock dir gone
  echo "T10: release clears lock dir"
  git_mutex_release "$M_REPO"
  [ ! -d "$(_mutex_dir "$M_REPO")" ] && ok "T10: lock dir removed after release" \
    || bad "T10: lock dir still exists after release"

  # T11: acquire after release succeeds
  echo "T11: re-acquire after release"
  git_mutex_acquire "$M_REPO" && ok "T11: re-acquire succeeded" || bad "T11: re-acquire failed"
  git_mutex_release "$M_REPO"

  # T12: stale mutex (dead holder PID) → reclaimed and re-acquired
  echo "T12: stale mutex (dead PID) → reclaimed"
  M_REPO2="$TMP/mrepo2"
  lock2="$(_mutex_dir "$M_REPO2")"
  mkdir -p "$lock2"
  # Write a dead PID (use sleep in background then kill it to get a recycled-safe dead PID)
  printf '999999999:fakepid\n' > "${lock2}/heartbeat"   # PID 999999999 almost certainly dead
  touch -t 200001010000 "${lock2}/heartbeat"             # aged out mtime
  export GIT_REPO_MUTEX_MAX_AGE=300
  git_mutex_acquire "$M_REPO2" && ok "T12: stale mutex reclaimed + acquired" \
    || bad "T12: could not reclaim stale mutex"
  git_mutex_release "$M_REPO2"

  # T13: mutex disabled (GIT_REPO_MUTEX_ENABLED=0) → acquire always passes
  echo "T13: mutex disabled → acquire always returns 0"
  export GIT_REPO_MUTEX_ENABLED=0
  git_mutex_acquire "$TMP/anyrpo" && ok "T13: disabled mutex returns 0" \
    || bad "T13: disabled mutex unexpectedly returned 1"
  export GIT_REPO_MUTEX_ENABLED=1

  # T14: git_with_mutex runs cmd and releases
  echo "T14: git_with_mutex runs cmd + releases"
  M_REPO3="$TMP/mrepo3"
  CMD_RAN=0
  git_with_mutex "$M_REPO3" bash -c 'echo ran' > /dev/null 2>&1 && CMD_RAN=1 || true
  [ "$CMD_RAN" -eq 1 ] && ok "T14: cmd ran via git_with_mutex" \
    || bad "T14: cmd did not run via git_with_mutex"
  [ ! -d "$(_mutex_dir "$M_REPO3")" ] && ok "T14: lock released after cmd" \
    || bad "T14: lock still held after cmd (should be released)"

  echo ""
  echo "────────────────────────────────────────────"
  echo "PASS=$PASS  FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# ── Main janitor sweep ────────────────────────────────────────────────────────
if [ "$ENABLED" != "1" ]; then
  _log_json "{\"ts\":\"$(ts)\",\"event\":\"disabled\",\"reason\":\"GIT_LOCK_ENABLED=${ENABLED}\"}"
  exit 0
fi

total_removed=0
repos_scanned=0
_GLH_COUNT_FILE="$(mktemp "${TMPDIR:-/tmp}/glh-sweep-counts.XXXXXX" 2>/dev/null)" || _GLH_COUNT_FILE=""

IFS=':' read -ra ROOTS <<< "$GIT_LOCK_RIG_ROOTS"
for root in "${ROOTS[@]}"; do
  root="${root%/}"
  [ -d "$root" ] || continue
  repos_scanned=$(( repos_scanned + 1 ))
  n=$(_scan_repo "$root")
  total_removed=$(( total_removed + n ))
done

# How many aged items were left alone, and why: "skipped_live" = a live git / held lock / could not
# tell; "undetermined" = the could-not-tell subset (a broken ps/lsof/timeout keeps EVERY aged lock, so
# this is the number to watch); "stale_state" = operation state reported but not removed. null =
# the tally file could not be made, i.e. unknown — never 0.
_glh_tally() {
  if [ -n "$_GLH_COUNT_FILE" ] && [ -e "$_GLH_COUNT_FILE" ]; then
    awk -v k="$1" '$0 == k { n++ } END { print n + 0 }' "$_GLH_COUNT_FILE" 2>/dev/null || echo null
  else
    echo null
  fi
}
_log_json "{\"ts\":\"$(ts)\",\"event\":\"sweep\",\"repos_scanned\":${repos_scanned},\"removed\":${total_removed},\"skipped_live\":$(_glh_tally skipped_live),\"undetermined\":$(_glh_tally undetermined),\"stale_state\":$(_glh_tally stale_state),\"dry_run\":\"${DRY_RUN}\",\"stale_age_sec\":${STALE_AGE}}"
[ -n "$_GLH_COUNT_FILE" ] && rm -f "$_GLH_COUNT_FILE"

# Notify only when locks were actually removed (signals a real heal event)
if [ "$total_removed" -gt 0 ] && [ "$DRY_RUN" = "0" ] && [ -x "$NOTIFY_BIN" ]; then
  "$NOTIFY_BIN" -t "Git-lock hygiene" -p 3 \
    "Removed ${total_removed} stale git lock file(s) across ${repos_scanned} rig(s)" 2>/dev/null || true
fi
