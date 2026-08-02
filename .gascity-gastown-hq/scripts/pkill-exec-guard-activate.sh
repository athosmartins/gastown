#!/usr/bin/env bash
# pkill-exec-guard-activate.sh (ga-79ge9) -- idempotently deploys
# pkill-exec-guard.sh as BOTH ~/.local/bin/pkill and ~/.local/bin/killall.
#
# WHY A DEPLOY SCRIPT AT ALL, AND WHY ~/.local/bin: unlike the dangerous-
# command guard (a Claude Code PreToolUse hook registered into gitignored
# settings.json), this guard is a plain PATH-resolved executable -- there
# is no settings.json to edit. ~/.local/bin is already first in PATH for
# every shell on this machine (~/.zshrc), for both Athos's terminal and
# every Gas Town agent session alike -- baseline PATH is NOT session-
# specific. pkill-exec-guard.sh tells the two apart AT RUNTIME instead
# (see its own docstring); this script's only job is getting the file
# onto disk, identically, under both names.
#
# WHY A REAL COPY, NOT A SYMLINK into this git checkout: a symlink into a
# worktree breaks the moment that worktree is cleaned up -- exactly why
# ga-tje7u's equivalent activation was deliberately never run from a
# worktree ("activating from my worktree would point the hook at a path
# that disappears once the worktree is cleaned up"). A plain copy here
# survives regardless of what happens to any checkout; re-running this
# script (e.g. after the source file changes on main) is how it stays in
# sync, same as the dangerous-command-guard-activate.sh convention.
#
# USAGE: pkill-exec-guard-activate.sh
#   No args. Idempotent -- safe to re-run any time (e.g. if ~/.local/bin
#   is ever wiped, or this repo's guard script changes and needs
#   redeploying). Override the destination directory with
#   PKILL_EXEC_GUARD_BIN_DIR (used by the selftest to target a scratch
#   dir instead of the real ~/.local/bin).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/pkill-exec-guard.sh"
DEST_DIR="${PKILL_EXEC_GUARD_BIN_DIR:-$HOME/.local/bin}"

if [ ! -f "$SOURCE" ]; then
  echo "FATAL: guard source not found at $SOURCE" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

for NAME in pkill killall; do
  DEST="$DEST_DIR/$NAME"

  if [ -f "$DEST" ] && cmp -s "$SOURCE" "$DEST"; then
    echo "Already up to date: $DEST"
    continue
  fi

  if [ -e "$DEST" ]; then
    cp "$DEST" "${DEST}.bak.$(date +%s)" 2>/dev/null || true
  fi

  TMP="$(mktemp "$DEST_DIR/.${NAME}.XXXXXX")"
  cp "$SOURCE" "$TMP"
  chmod +x "$TMP"
  mv "$TMP" "$DEST"
  echo "Deployed: $DEST"
done
