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
#     (b) no live git process references this repository path.
#   Files cleaned:
#     .git/index.lock         — always a temp file (git crashes leave this behind)
#     .git/MERGE_HEAD         — in-progress merge, stale after crash
#     .git/CHERRY_PICK_HEAD   — in-progress cherry-pick, stale after crash
#     .git/REVERT_HEAD        — in-progress revert, stale after crash
#     .git/packed-refs.lock   — in-progress pack-refs, stale after crash
#     .git/shallow.lock       — in-progress shallow fetch, stale after crash
#     .git/config.lock        — in-progress config write, stale after crash
#     .git/rebase-merge/      — in-progress rebase (merge strategy), entire dir
#     .git/rebase-apply/      — in-progress rebase (apply strategy) / git-am, entire dir
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
#   GIT_LOCK_DRY_RUN           1 = log what would be removed, don't remove (def 0)
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

# Returns 0 if any live git process references repo_path in its argv.
# Tests may override via GIT_LOCK_PROCESS_CHECK_FN.
_git_repo_has_live_process() {
  local repo="$1"
  if [ -n "${GIT_LOCK_PROCESS_CHECK_FN:-}" ]; then
    "$GIT_LOCK_PROCESS_CHECK_FN" "$repo"; return $?
  fi
  # ps aux covers: `git -C /path/to/repo ...` and any process cd'd into the repo
  # (macOS ps shows the executable path for many tools). False-negative is safe
  # (we'd skip cleaning a stale lock), false-positive would be a bug (skip when stale).
  ps aux 2>/dev/null | grep '[g]it' | grep -F "$repo" >/dev/null
}

# Determine if a lock file or directory is stale:
# age > STALE_AGE AND no live git process for the owning repo.
_is_stale() {
  local path="$1" repo="$2"
  [ -e "$path" ] || return 1          # doesn't exist → not stale
  local age
  age=$(_path_age "$path")
  [ "$age" -lt "$STALE_AGE" ] && return 1   # too young
  _git_repo_has_live_process "$repo" && return 1   # live process → skip
  return 0   # stale
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

# Scan one git repo root for stale lock files.
# Returns the count of files removed/would-remove.
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
    "MERGE_HEAD:in-progress merge" \
    "CHERRY_PICK_HEAD:in-progress cherry-pick" \
    "REVERT_HEAD:in-progress revert" \
    "packed-refs.lock:packed-refs lock" \
    "shallow.lock:shallow lock" \
    "config.lock:config lock"
  do
    f="${git_dir}/${f_label%%:*}"
    label="${f_label#*:}"
    if _is_stale "$f" "$repo"; then
      _remove_stale_lock "$f" "$repo" "$label"
      removed=$(( removed + 1 ))
    fi
  done

  # Directory lock candidates (rebase state dirs)
  local d
  for d_label in \
    "rebase-merge:in-progress rebase (merge strategy)" \
    "rebase-apply:in-progress rebase/am (apply strategy)"
  do
    d="${git_dir}/${d_label%%:*}"
    label="${d_label#*:}"
    if [ -d "$d" ] && _is_stale "$d" "$repo"; then
      _remove_stale_lock "$d" "$repo" "$label"
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
  trap 'rm -rf "$TMP"' EXIT

  # ga-d8zeli: _log_json appends every removed/would_remove event to $LOG, which
  # defaults to the LIVE sweeps log — and the fixture repos below fire those events
  # for real (8 per run; measured 2026-09-20: 746 of the 36791 lines in the live
  # git-lock-hygiene.jsonl were selftest fixtures). Point $LOG at scratch for the
  # whole selftest, unconditionally: an inherited GIT_LOCK_LOG must not be able to
  # aim a selftest back at production. Here rather than in the wrapper because more
  # than one caller runs this block (scripts/git-lock-hygiene.selftest.sh,
  # gate-git-lock-hygiene.selftest.sh, a bare `--selftest`); the wrapper pins it.
  LOG="$TMP/git-lock-hygiene.jsonl"

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

  # T4: stale rebase-merge/ directory → removed
  echo "T4: stale rebase-merge/ dir → removed"
  R4="$TMP/repo4"; make_repo "$R4"
  mkdir -p "$R4/.git/rebase-merge"
  touch -t 200001010000 "$R4/.git/rebase-merge"
  count=$(_scan_repo "$R4")
  [ ! -d "$R4/.git/rebase-merge" ] && ok "T4: stale rebase-merge/ removed" \
    || bad "T4: stale rebase-merge/ NOT removed"

  # T5: stale MERGE_HEAD → removed; ORIG_HEAD → left untouched
  echo "T5: stale MERGE_HEAD removed; ORIG_HEAD untouched"
  R5="$TMP/repo5"; make_repo "$R5"
  touch -t 200001010000 "$R5/.git/MERGE_HEAD"
  touch -t 200001010000 "$R5/.git/ORIG_HEAD"   # valid artifact — must NOT be removed
  count=$(_scan_repo "$R5")
  [ ! -f "$R5/.git/MERGE_HEAD" ] && ok "T5: stale MERGE_HEAD removed" \
    || bad "T5: stale MERGE_HEAD NOT removed"
  [ -f "$R5/.git/ORIG_HEAD" ] && ok "T5: ORIG_HEAD left untouched" \
    || bad "T5: ORIG_HEAD was removed (should NOT be)"

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
total_skipped=0
repos_scanned=0

IFS=':' read -ra ROOTS <<< "$GIT_LOCK_RIG_ROOTS"
for root in "${ROOTS[@]}"; do
  root="${root%/}"
  [ -d "$root" ] || continue
  repos_scanned=$(( repos_scanned + 1 ))
  n=$(_scan_repo "$root")
  total_removed=$(( total_removed + n ))
done

_log_json "{\"ts\":\"$(ts)\",\"event\":\"sweep\",\"repos_scanned\":${repos_scanned},\"removed\":${total_removed},\"dry_run\":\"${DRY_RUN}\",\"stale_age_sec\":${STALE_AGE}}"

# Notify only when locks were actually removed (signals a real heal event)
if [ "$total_removed" -gt 0 ] && [ "$DRY_RUN" = "0" ] && [ -x "$NOTIFY_BIN" ]; then
  "$NOTIFY_BIN" -t "Git-lock hygiene" -p 3 \
    "Removed ${total_removed} stale git lock file(s) across ${repos_scanned} rig(s)" 2>/dev/null || true
fi
