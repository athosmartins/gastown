#!/usr/bin/env bash
# pkill-exec-guard.sh (ga-79ge9, successor to ga-tje7u after 7 failed
# shell-text-parsing rounds) -- refuses pkill/killall for Gas Town agent
# sessions. Deployed as BOTH ~/.local/bin/pkill and ~/.local/bin/killall
# (see pkill-exec-guard-activate.sh, which installs this same file under
# both names) -- dispatches on its own invoked name (basename "$0") to
# know which real binary to delegate to when not refusing.
#
# WHY THIS DESIGN, NOT TEXT PARSING: ga-tje7u burned 7 rounds trying to
# decide "is pkill being invoked?" by analyzing the Bash tool's command
# TEXT -- comments, heredocs, $(...), if/while/case block keywords,
# backslash escapes -- every round closed one shell construct and opened
# another (see that bead's comment history for the full account; last
# count was 9+ distinct false-allow holes across 6 gate-FAIL rounds).
# Mayor's decision 2026-08-01 (ga-79ge9): stop parsing shell entirely.
# Intercept at the one point where "mention" and "invocation" are
# physically distinct: process exec. This script IS that interception
# point -- if it runs at all, pkill/killall was actually invoked (the
# shell already resolved the name via PATH lookup and exec'd this file
# in its place), full stop. There is no command text here to misjudge,
# so the entire bypass class this replaces (comments, heredocs, case
# statements, $(...), escapes...) cannot exist by construction, not by
# careful casework -- see pkill-exec-guard.selftest.sh's AC1-4 for the
# bead's own regression cases, all passing because they never reach this
# file at all.
#
# WHY "command position" was ALSO the wrong frame, and why this file
# does not use it either: even ga-tje7u's single-rule redesign (deny
# unconditionally whenever pkill/killall appears in shell "command
# position") still required a shell tokenizer to find command position,
# and every failure was in that tokenizer, not in the original
# pattern-matching. This design has no tokenizer at all -- the shell
# itself performs the equivalent of "command position" resolution when
# it looks up $0 on PATH and execs, and we simply own the destination.
#
# WHO gets refused: only processes whose environment carries GC_AGENT,
# GC_ALIAS, or GC_DIR -- Gas Town's own signal that this is a spawned
# agent session (set by the gascity engine for every dog/crew/witness/
# refinery/deacon/polecat session; confirmed empirically present in a
# live dog session at ga-79ge9 implementation time). Athos's own
# interactive terminal sources the identical ~/.zshrc PATH (so this
# shim is reachable there too) but never has any of these three vars
# set, so it gets a transparent, unmodified passthrough to the real
# binary -- this is a RUNTIME IDENTITY check, not command-text analysis:
# argv is inspected only to log it, never to decide allow/deny.
#
# KNOWN GAP (documented, not a regression -- same class as the old
# design's accepted gaps): invocation by absolute path (/usr/bin/pkill,
# /usr/bin/killall) bypasses PATH resolution entirely and never reaches
# this shim. This is narrower than the heredoc/comment/case-statement
# class it replaces -- it requires deliberately spelling out the real
# binary's path, not an ordinary/natural way to write a command.
set -uo pipefail

SELF="$(basename "$0")"
case "$SELF" in
  pkill)   REAL_BIN="/usr/bin/pkill" ;;
  killall) REAL_BIN="/usr/bin/killall" ;;
  *)
    echo "pkill-exec-guard: installed under unrecognized name '$SELF' -- refusing to guess a real binary to delegate to" >&2
    exit 78
    ;;
esac

LOG_FILE="${PKILL_EXEC_GUARD_LOG:-$HOME/.gastown/logs/pkill-exec-guard.log}"

log() {
  local result="$1"; shift
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s\tagent=%s\tcmd=%s\tresult=%s\targs=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GC_AGENT:-${GC_ALIAS:-${GC_DIR:-none}}}" "$SELF" "$result" "$*" \
    >> "$LOG_FILE" 2>/dev/null || true
}

if [ -n "${GC_AGENT:-}" ] || [ -n "${GC_ALIAS:-}" ] || [ -n "${GC_DIR:-}" ]; then
  log "REFUSED" "$@"
  {
    printf '%s: BLOCKED for Gas Town agent session (%s).\n' "$SELF" "${GC_AGENT:-${GC_ALIAS:-$GC_DIR}}"
    printf 'Agents may not run pkill/killall -- a malformed pattern/flag order has\n'
    printf 'taken down 8 sessions plus a production daemon in one shot before.\n'
    printf 'Instead:\n'
    printf '  1. validate first (read-only):  pgrep -lf '"'"'<pattern>'"'"'\n'
    printf '  2. kill by PID:                 kill <pid>   (or `kill $!` for your own nohup)\n'
    printf '  3. never share a basename with a production process\n'
    printf 'Known gap: invoking the real binary by absolute path (%s) bypasses this guard.\n' "$REAL_BIN"
  } >&2
  exit 77
fi

log "ALLOWED" "$@"
exec "$REAL_BIN" "$@"
