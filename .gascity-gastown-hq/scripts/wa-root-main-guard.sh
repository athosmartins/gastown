#!/usr/bin/env bash
# wa-root-main-guard.sh — STOPGAP: keep the whatsapp_automation PRODUCTION root on `main`.
#
# WHY: /Users/athos/gt/whatsapp_automation is the production root — the live daemons
# run FROM it, so it MUST stay on `main`. A recurring bug (crews slung wa- beads build
# IN the rig root and `/crew-commit` branches it in-place) keeps checking it out onto
# crew branches (twice on 2026-06-14: crew/...claude-5/wa-tnl5, crew/...claude-1/wa-tdx5).
# Until the real fix lands (crew-commit / Pilot worktree isolation — separate work) the
# Mayor hand-restores it each time. This guard automates that restore + alerts.
#
# WHAT: every interval, read the root's current branch. If it's `main` → silent exit 0.
# If it's a crew branch → back up the divergent HEAD to a tag (so in-progress crew work
# is NEVER lost — recoverable), then run the EXACT restore recipe the Mayor uses by hand
# (stash daemon syncs, switch main, fetch, ff-only merge, drop stash), then log + notify.
# Daemons likely need a RESTART afterwards — this guard does NOT restart them (oracle's job).
#
# SAFETY: conservative. Never `git checkout -f` / `reset --hard`. If the root is in a
# genuine merge-conflict / dirty-unswitchable state or the switch fails, do NOT force —
# log + notify "needs human" and LEAVE it untouched.
#
# STOPGAP: this masks the bug, it does not fix it. Remove once crew-commit / Pilot
# worktree isolation lands. On-disk only (not pack-committed) — same as the other guards.
#
# Kill switch: WA_ROOT_GUARD_ENABLED=0 → check + log only, never restore.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
ROOT="/Users/athos/gt/whatsapp_automation"
LOG="$CITY/.gc/logs/wa-root-main-guard.log"
ENABLED="${WA_ROOT_GUARD_ENABLED:-1}"
HOOKS="/tmp/empty-hooks"   # bypass any in-root hooks that could block the switch/merge

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
note() { command -v notify >/dev/null 2>&1 && notify "$@" >/dev/null 2>&1 || true; }

# git wrapper for the root, with hooks neutralised (mirrors the Mayor's manual recipe).
g() { git -C "$ROOT" -c core.hooksPath="$HOOKS" "$@"; }

mkdir -p "$HOOKS" 2>/dev/null || true

# Root must be a git repo.
if [ ! -d "$ROOT/.git" ] && ! g rev-parse --git-dir >/dev/null 2>&1; then
  log "skip: $ROOT is not a git repo (or unreadable)."
  exit 0
fi

BRANCH="$(g branch --show-current 2>/dev/null || true)"

# Detached HEAD or unreadable branch — unusual; alert but do NOT force.
if [ -z "$BRANCH" ]; then
  log "WARN: $ROOT has empty/detached branch — leaving untouched (needs human)."
  note -p 4 -t 'wa-root-guard' "WA root in detached/empty-branch state — NEEDS HUMAN (guard left it untouched)"
  exit 0
fi

# Clean: already on main → silent success.
if [ "$BRANCH" = "main" ]; then
  exit 0
fi

# Off-main: a crew branch is checked out in the production root.
SHA="$(g rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "OFF-MAIN: production root is on '$BRANCH' (HEAD $SHA) — restore required."

if [ "$ENABLED" != "1" ]; then
  log "WA_ROOT_GUARD_ENABLED=0 — check-only, NOT restoring (branch=$BRANCH HEAD=$SHA)."
  note -p 4 -t 'wa-root-guard' "WA root OFF-MAIN on '$BRANCH' but guard DISABLED — restore skipped, NEEDS HUMAN"
  exit 0
fi

# 1. Back up the divergent HEAD first so a crew's in-progress commit is never lost.
BACKUP_TAG="wa-root-guard-backup-${SHA}"
if g tag -f "$BACKUP_TAG" HEAD >/dev/null 2>&1; then
  log "backed up divergent HEAD ($BRANCH @ $SHA) to tag $BACKUP_TAG (recover: git -C $ROOT checkout $BACKUP_TAG)."
else
  log "WARN: could not create backup tag $BACKUP_TAG — ABORTING restore to avoid data loss (needs human)."
  note -p 5 -t 'wa-root-guard' "WA root OFF-MAIN on '$BRANCH' but backup tag FAILED — restore aborted, NEEDS HUMAN"
  exit 0
fi

# 2. Restore to main — the exact recipe the Mayor uses by hand. Conservative, no force.
g stash push -- daemons/ >/dev/null 2>&1 || true   # redundant staged daemon syncs, if any

if ! g switch main >/dev/null 2>&1; then
  log "WARN: 'git switch main' FAILED (dirty/conflict?) — NOT forcing. Left on '$BRANCH'. Backup tag=$BACKUP_TAG. NEEDS HUMAN."
  note -p 5 -t 'wa-root-guard' "WA root switch to main FAILED on '$BRANCH' (conflict?) — NOT forced, NEEDS HUMAN (backup $BACKUP_TAG)"
  exit 0
fi

g fetch origin main >/dev/null 2>&1 || log "WARN: 'git fetch origin main' returned nonzero (offline?) — continuing with local main."

if ! g merge --ff-only origin/main >/dev/null 2>&1; then
  log "WARN: 'git merge --ff-only origin/main' FAILED — root is on main but may be behind origin. Not forcing. NEEDS HUMAN."
  note -p 4 -t 'wa-root-guard' "WA root back on main but ff-only merge from origin FAILED — may be behind, NEEDS HUMAN"
  # We are on main now (the dangerous off-main state is resolved), so do not exit nonzero.
fi

g stash drop >/dev/null 2>&1 || true

NOW="$(g branch --show-current 2>/dev/null || echo '?')"
if [ "$NOW" = "main" ]; then
  log "RESTORED: production root back on main (was '$BRANCH' @ $SHA, backed up to tag $BACKUP_TAG). Daemon RESTART likely needed (oracle's job — guard does NOT restart)."
  note -p 4 -t 'wa-root-guard' "WA root was OFF-MAIN on '$BRANCH' (@ $SHA) — RESTORED to main. Backup tag $BACKUP_TAG. Daemons likely need RESTART (oracle)."
else
  log "WARN: after restore attempt root is on '$NOW' (expected main) — NEEDS HUMAN. Backup tag=$BACKUP_TAG."
  note -p 5 -t 'wa-root-guard' "WA root restore did NOT land on main (now '$NOW') — NEEDS HUMAN (backup $BACKUP_TAG)"
fi
exit 0
