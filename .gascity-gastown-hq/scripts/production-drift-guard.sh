#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# production-drift-guard.sh   (ga-7rvi5 — generalises com.gascity.wa-root-main-guard)
#
# PURPOSE — DETECTION-ONLY drift guard. Scan every PRODUCTION job on the host
# (launchd LaunchAgents, the user crontab, and live launchd-owned processes) and
# ALERT when any of them runs code from a place it must NOT:
#   • a crew clone            (a path containing a `/crew/<name>/` segment)
#   • a build worktree        (a path under `.gc-worktrees/`)
#   • code not in origin/main (the enclosing repo is off `main`, on a detached
#                              HEAD, or the exact running file differs from /
#                              is absent from `origin/main`)
#
# WHY — "production runs from a crew clone / off main" is a RECURRING leak: a
# 2026-06-14 audit found 13+ cases across 4 rigs. Fixing each instance treats
# the symptom; this guard attacks the SOURCE so a merged fix that never reaches
# the live job, or a daemon accidentally pointed at a crew branch, is surfaced
# immediately instead of silently rotting. com.gascity.wa-root-main-guard was the
# NARROW seed (one root, with auto-restore); this GENERALISES the *detection*
# across all launchd/cron/live-proc jobs.
#
# SCOPE / NON-GOALS (deliberate — keeps false-positives at zero):
#   • DETECTION + ALERT ONLY. It NEVER restores, switches branches, or kills a
#     job. Remediation stays with the per-owner beads and the narrow guards
#     (wa-root-main-guard restores the WA root; town-root-reconciler ff-pulls the
#     town root). A guard that yanks live production is explicitly out of scope.
#   • Only paths UNDER $GT_ROOT are considered. Unrelated system/3rd-party jobs
#     are ignored — we never alert on something we do not own.
#   • Only launchd-OWNED live processes (ppid==1) are inspected, so a developer's
#     transient build subprocess (a child of an agent shell) is never mistaken
#     for a production job.
#   • Does not cover config/secret drift — only the CODE PATH of production jobs.
#
# ALERTING:
#   • Clean → SILENT exit 0 (acceptance: no noise / no false-positive when there
#     is no divergence).
#   • Drift → one actionable log line per finding (job · path · kind · owner) +
#     a single throttled ntfy summary, and the run is recorded to a state file.
#   • PRE-PUSH / CI mode: set DRIFT_GUARD_EXIT_ON_DRIFT=1 to make the process exit
#     non-zero when any drift is found, so it can gate a deploy / pre-push hook.
#
# DEPENDENCY: the off-main *file* check compares against the locally-cached
# `origin/main` ref. The town-root-reconciler already fetches origin/main every
# ~25s, so that ref is fresh; this guard does NOT fetch (fetching every sweep is
# slow + noisy). If `origin/main` is missing it degrades to local `main`/HEAD and
# logs that it did so — uncommitted edits are still caught, only the
# unpushed-commit case is then invisible.
#
# Kill switch: DRIFT_GUARD_ENABLED=0 → scan + log only, never ntfy.
#
# TEST SEAM: sourcing this file with PRODUCTION_DRIFT_GUARD_LIB=1 defines the pure
# dg_* helpers and returns WITHOUT running any scan or the daemon loop, so the
# selftest can exercise classification against throwaway git repos / fake plists
# with no network and no touching of the live host.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# All config env-overridable so the selftest can retarget without touching prod.
# NOTE: the override var is DRIFT_GT_ROOT, NOT GT_ROOT — in a live gascity agent
# session the inherited $GT_ROOT is the CITY dir (.gascity-gastown-hq), not the
# town root, so consuming it directly silently mis-scopes the whole scan.
GT_ROOT="${DRIFT_GT_ROOT:-/Users/athos/gt}"
CITY="${CITY:-$GT_ROOT/.gascity-gastown-hq}"
LOG_DIR="${LOG_DIR:-$CITY/.gc/logs}"
LOG="${LOG:-$LOG_DIR/production-drift-guard.log}"
STATE_DIR="${STATE_DIR:-$CITY/.gc/state}"
REMOTE="${DRIFT_REMOTE:-origin}"
MAIN_BRANCH="${DRIFT_MAIN_BRANCH:-main}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
SCAN_INTERVAL="${DRIFT_SCAN_INTERVAL:-900}"          # 15 min between sweeps (daemon mode)
ENABLED="${DRIFT_GUARD_ENABLED:-1}"
EXIT_ON_DRIFT="${DRIFT_GUARD_EXIT_ON_DRIFT:-0}"      # pre-push/CI: exit nonzero on drift
SCAN_LAUNCHD="${DRIFT_SCAN_LAUNCHD:-1}"
SCAN_CRON="${DRIFT_SCAN_CRON:-1}"
SCAN_PROCS="${DRIFT_SCAN_PROCS:-1}"
NTFY_THROTTLE_SECONDS="${DRIFT_NTFY_THROTTLE:-3600}"
# Allowlist of SANCTIONED exceptions (e.g. deliberate on-disk-only stopgap
# daemons). One glob per line, matched against either the code path or the job
# label/identity; '#' comments and blank lines ignored. Absent/empty file →
# literal behaviour (nothing sanctioned). This is the escape hatch that keeps the
# steady-state silent (acceptance #5) without weakening detection of NEW drift.
ALLOWLIST_FILE="${DRIFT_ALLOWLIST_FILE:-$CITY/.gc/config/production-drift-guard.allow}"

# Keep git from walking ABOVE the town root into an unrelated parent repo, but
# set the ceiling to the PARENT of the root — a ceiling equal to the root itself
# would block discovery of the town-root repo whose .git lives AT $GT_ROOT (git
# stops before entering a ceiling dir), defeating the off-main check for the most
# important repo on the host.
export GIT_CEILING_DIRECTORIES="$(dirname "$GT_ROOT")"

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] [drift-guard] $*"        | tee -a "$LOG" 2>/dev/null; }
warn() { echo "[$(ts)] [drift-guard] WARN: $*"  | tee -a "$LOG" 2>/dev/null; }
err()  { echo "[$(ts)] [drift-guard] ERROR: $*" | tee -a "$LOG" 2>/dev/null; }

# Throttle ntfy so a persistent drift pings at most once per throttle window.
NTFY_STAMP="$STATE_DIR/.production-drift-guard.last-ntfy"
maybe_ntfy() {
  local msg="$1" now last
  [ "$ENABLED" = "1" ] || { log "ntfy suppressed (DRIFT_GUARD_ENABLED=0): $msg"; return 0; }
  now=$(date +%s)
  last=$(cat "$NTFY_STAMP" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge "$NTFY_THROTTLE_SECONDS" ]; then
    notify -t "Gas City: production drift" -p 4 "$msg" 2>/dev/null || true
    echo "$now" > "$NTFY_STAMP" 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PURE HELPERS (unit-tested via the lib seam). No side effects beyond git reads.
# ─────────────────────────────────────────────────────────────────────────────

# dg_in_scope <path> → 0 if the path is under $GT_ROOT, else 1.
dg_in_scope() {
  case "$1" in
    "$GT_ROOT"/*|"$GT_ROOT") return 0 ;;
    *) return 1 ;;
  esac
}

# dg_base_ref <repo> → the ref to treat as "origin/main" for that repo:
# prefer the cached remote ref, fall back to local main, then HEAD.
dg_base_ref() {
  local repo="$1"
  if git -C "$repo" rev-parse --verify --quiet "$REMOTE/$MAIN_BRANCH" >/dev/null 2>&1; then
    echo "$REMOTE/$MAIN_BRANCH"
  elif git -C "$repo" rev-parse --verify --quiet "$MAIN_BRANCH" >/dev/null 2>&1; then
    echo "$MAIN_BRANCH"
  else
    echo "HEAD"
  fi
}

# dg_classify_path <path> → "KIND|DETAIL"
#   KIND ∈ { clean, crew-clone, worktree, off-main-branch, off-main-file }
# Pure: only reads git + the filesystem; never mutates anything.
dg_classify_path() {
  local p="$1" dir file repo branch base rel
  [ -n "$p" ] || { echo "clean|empty-path"; return 0; }

  # Only judge paths we own.
  dg_in_scope "$p" || { echo "clean|out-of-scope"; return 0; }

  # Path-pattern drift — true regardless of git state, so check these first.
  case "$p" in
    */crew/*)           echo "crew-clone|path under a crew clone"; return 0 ;;
    */.gc-worktrees/*)  echo "worktree|path under a build worktree"; return 0 ;;
  esac

  # Resolve the enclosing repo.
  if [ -d "$p" ]; then dir="$p"; file=""; else dir=$(dirname "$p"); file="$p"; fi
  repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { echo "clean|not-in-git-repo"; return 0; }

  branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$branch" ]; then echo "off-main-branch|detached-HEAD"; return 0; fi
  if [ "$branch" != "$MAIN_BRANCH" ]; then echo "off-main-branch|branch=$branch"; return 0; fi

  # On main. If a concrete file was named, confirm the RUNNING bytes are the ones
  # in origin/main — this catches "merged fix never reached the live file" and
  # "live file edited / committed-but-unpushed" (the core of the recurring leak).
  if [ -n "$file" ]; then
    rel=${file#"$repo"/}
    # gitignored → an expected local/generated artifact, not production code drift.
    if git -C "$repo" check-ignore -q "$rel" 2>/dev/null; then echo "clean|gitignored-artifact"; return 0; fi
    base=$(dg_base_ref "$repo")
    if git -C "$repo" cat-file -e "$base:$rel" 2>/dev/null; then
      if git -C "$repo" show "$base:$rel" 2>/dev/null | cmp -s - "$file"; then
        echo "clean|matches-$base"; return 0
      fi
      echo "off-main-file|differs from $base ($rel)"; return 0
    fi
    # Not present in base. Distinguish committed-locally-not-pushed from untracked.
    if git -C "$repo" cat-file -e "HEAD:$rel" 2>/dev/null; then
      echo "off-main-file|committed locally, not in $base ($rel)"; return 0
    fi
    echo "off-main-file|untracked, not in $base ($rel)"; return 0
  fi

  echo "clean|on-main"
}

# dg_owner_for_path <path> <kind> → a human-actionable owner string.
dg_owner_for_path() {
  local p="$1" kind="$2" repo dir who br
  case "$kind" in
    crew-clone)
      echo "crew:$(printf '%s' "$p" | sed -E 's#.*/crew/([^/]+).*#\1#')" ;;
    worktree)
      echo "worktree:$(printf '%s' "$p" | sed -E 's#.*/\.gc-worktrees/([^/]+).*#\1#')" ;;
    off-main-branch|off-main-file)
      if [ -d "$p" ]; then dir="$p"; else dir=$(dirname "$p"); fi
      repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
      if [ -n "$repo" ]; then
        br=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo "detached")
        who=$(git -C "$repo" log -1 --format='%an' 2>/dev/null || echo "")
        echo "branch=$br last-commit-by=${who:-unknown}"
      else
        echo "unknown"
      fi ;;
    *)
      who=$(stat -f '%Su' "$p" 2>/dev/null || echo "")
      echo "fileowner=${who:-unknown}" ;;
  esac
}

# dg_paths_from_plist <plist> → absolute code paths referenced by a LaunchAgent
# (ProgramArguments entries + WorkingDirectory). Handles binary + XML plists.
dg_paths_from_plist() {
  local plist="$1"
  plutil -convert json -o - "$plist" 2>/dev/null | jq -r '
    [ (.ProgramArguments // [])[]?, (.WorkingDirectory // empty) ]
    | .[]? | select(type == "string") | select(startswith("/"))
  ' 2>/dev/null
}

# dg_label_from_plist <plist> → the LaunchAgent Label (job identity).
dg_label_from_plist() {
  plutil -convert json -o - "$1" 2>/dev/null | jq -r '.Label // empty' 2>/dev/null
}

# dg_is_allowlisted <path> <label> → 0 if a sanctioned exception, else 1.
dg_is_allowlisted() {
  local path="$1" label="$2" pat file
  file="${DRIFT_ALLOWLIST_FILE:-$ALLOWLIST_FILE}"
  [ -f "$file" ] || return 1
  while IFS= read -r pat; do
    case "$pat" in ''|\#*) continue ;; esac
    # shellcheck disable=SC2254  # intentional glob match from the allowlist
    case "$path"  in $pat) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$label" in $pat) return 0 ;; esac
  done < "$file"
  return 1
}

# dg_emit_if_drift <source> <job> <path>
# Classify a path and, if it is drift, print one tab-separated finding record.
DRIFT_FOUND=0
dg_emit_if_drift() {
  local source="$1" job="$2" path="$3" kind detail owner res
  res=$(dg_classify_path "$path")
  kind=${res%%|*}; detail=${res#*|}
  case "$kind" in
    clean|"") return 0 ;;
  esac
  dg_is_allowlisted "$path" "$job" && return 0
  owner=$(dg_owner_for_path "$path" "$kind")
  DRIFT_FOUND=$((DRIFT_FOUND + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$source" "$job" "$path" "$kind" "$detail" "$owner"
}

# ─────────────────────────────────────────────────────────────────────────────
# SCANNERS — each prints tab-separated drift records (source\tjob\tpath\tkind\tdetail\towner)
# ─────────────────────────────────────────────────────────────────────────────

scan_launchd() {
  [ "$SCAN_LAUNCHD" = "1" ] || return 0
  [ -d "$LAUNCH_AGENTS_DIR" ] || { log "launchd: $LAUNCH_AGENTS_DIR absent — skip"; return 0; }
  local plist label p
  for plist in "$LAUNCH_AGENTS_DIR"/*.plist; do
    [ -e "$plist" ] || continue
    label=$(dg_label_from_plist "$plist"); [ -n "$label" ] || label=$(basename "$plist" .plist)
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      dg_emit_if_drift "launchd" "$label" "$p"
    done < <(dg_paths_from_plist "$plist")
  done
}

scan_cron() {
  [ "$SCAN_CRON" = "1" ] || return 0
  command -v crontab >/dev/null 2>&1 || return 0
  local line tok
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    for tok in $line; do
      case "$tok" in
        "$GT_ROOT"/*) dg_emit_if_drift "cron" "crontab:${USER:-$(id -un)}" "$tok" ;;
      esac
    done
  done < <(crontab -l 2>/dev/null)
}

scan_procs() {
  [ "$SCAN_PROCS" = "1" ] || return 0
  local pid ppid rest tok
  # Only launchd-owned daemons (ppid==1): a transient build subprocess is a child
  # of an agent shell, never of launchd, so this excludes build noise by design.
  while read -r pid ppid rest; do
    [ "$ppid" = "1" ] || continue
    for tok in $rest; do
      case "$tok" in
        "$GT_ROOT"/*) dg_emit_if_drift "proc" "pid:$pid" "$tok" ;;
      esac
    done
  done < <(ps -axo pid=,ppid=,command= 2>/dev/null)
}

# ─────────────────────────────────────────────────────────────────────────────
# ORCHESTRATION
# ─────────────────────────────────────────────────────────────────────────────

run_scan() {
  DRIFT_FOUND=0
  local findings count
  # NOTE: the scanners run inside this command-substitution subshell, so their
  # dg_emit_if_drift increments to DRIFT_FOUND do NOT reach this scope. Derive
  # DRIFT_FOUND authoritatively from the finding count below so run_one's
  # EXIT_ON_DRIFT (pre-push/CI gate) sees the real result.
  findings=$( { scan_launchd; scan_cron; scan_procs; } | sort -u )

  if [ -z "$findings" ]; then
    # Silent on clean (acceptance: no noise). Refresh the state file for observability.
    printf 'last_clean %s\n' "$(date +%s)" > "$STATE_DIR/production-drift-guard.last" 2>/dev/null || true
    return 0
  fi

  count=$(printf '%s\n' "$findings" | grep -c . )
  DRIFT_FOUND="$count"
  err "PRODUCTION DRIFT — $count job(s) running from a crew clone / worktree / off-main code:"
  printf '%s\n' "$findings" | while IFS=$'\t' read -r source job path kind detail owner; do
    err "  • [$source] job='$job' path='$path' kind=$kind ($detail) owner=$owner"
  done

  # Persist the findings for the painel / audit trail.
  {
    printf 'last_drift %s count=%s\n' "$(date +%s)" "$count"
    printf '%s\n' "$findings"
  } > "$STATE_DIR/production-drift-guard.last" 2>/dev/null || true

  # One throttled, actionable ntfy summary.
  local first
  first=$(printf '%s\n' "$findings" | head -1 | awk -F'\t' '{printf "%s: %s (%s) owner=%s", $2, $3, $4, $6}')
  maybe_ntfy "Production drift: $count job(s) off-main/crew/worktree. e.g. $first — see $LOG"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Library-source guard — selftest sources with PRODUCTION_DRIFT_GUARD_LIB=1 to
# get the pure dg_* helpers WITHOUT running a scan or the daemon loop.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${PRODUCTION_DRIFT_GUARD_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# Startup marker for delivery-freshness verification (mirrors town-root-reconciler).
printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/production-drift-guard.startup" 2>/dev/null || true

run_one() {
  run_scan
  if [ "$EXIT_ON_DRIFT" = "1" ] && [ "$DRIFT_FOUND" -gt 0 ]; then
    return 1
  fi
  return 0
}

# Single-shot mode for tests / pre-push / manual runs: DRIFT_GUARD_ONCE=1
if [ "${DRIFT_GUARD_ONCE:-0}" = "1" ]; then
  run_one
  exit $?
fi

log "production-drift-guard started (root=$GT_ROOT remote=$REMOTE branch=$MAIN_BRANCH interval=${SCAN_INTERVAL}s enabled=$ENABLED)"
while true; do
  run_one || true
  sleep "$SCAN_INTERVAL"
done
