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
#   GIT_LOCK_HYGIENE_LIB=1 source git-lock-hygiene.sh — load lib, skip sweep
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
GIT_LOCK_RIG_ROOTS="${GIT_LOCK_RIG_ROOTS:-/Users/athos/gt:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_log_json() {
  # emit a JSON event to LOG; always succeeds (LOG write failures are non-fatal)
  printf '%s\n' "$*" >> "$LOG" 2>/dev/null || true
}

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
  ps aux 2>/dev/null | grep '[g]it' | grep -qF "$repo"
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
  local repo="$1" git_dir removed=0
  git_dir="${repo}/.git"
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

  # Test helper: create a fake git repo with a given lock file.
  # make_repo <dir>  →  creates <dir>/.git/
  make_repo() {
    mkdir -p "$1/.git"
    # minimal git dir so git commands recognise it
    printf 'ref: refs/heads/main\n' > "$1/.git/HEAD"
    mkdir -p "$1/.git/refs/heads"
    touch "$1/.git/COMMIT_EDITMSG"
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
