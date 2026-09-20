#!/usr/bin/env bash
# gate-author-adhoc-normalize.selftest.sh (ga-po5x43, 2026-09-20)
#
# Proves the adhoc-session-id normalization blocks in quality-gate-guard.sh
# (sentinel "adhoc-author-normalize-guard") and quality-gate-dispatcher.sh
# (sentinel "adhoc-author-normalize-dispatcher") actually strip the "-adhoc-<hex>"
# suffix, e.g. "digo-wa-adhoc-e2510107f6" -> "digo-wa".
#
# Root cause this guards against: the original guard was
#   echo "$AUTHOR" | grep -E "-adhoc-[0-9a-f]+" 2>/dev/null >/dev/null
# — a pattern that STARTS WITH A DASH, which grep parses as an option bundle
# instead of a pattern. BSD grep (/usr/bin/grep, the one launchd uses) exits 2
# ("unknown --directories option"); the 2>/dev/null hides the message and the
# `if` reads rc=2 the same as "no match" (rc=1), so the normalization branch
# NEVER ran, for ANY author. Confirmed live on this machine (2026-09-20):
#   echo "digo-wa-adhoc-e2510107f6" | /usr/bin/grep -E "-adhoc-[0-9a-f]+"
#   -> "grep: unknown --directories option", rc=2
#
# Strategy mirrors gate-author-priority.selftest.sh: extract the LIVE block via
# its sentinels (never a hand-copied re-implementation) and run it under a
# clean `bash -c` (no interactive-shell grep shadowing) with AUTHOR set.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-author-adhoc-normalize.selftest =="

[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD" >&2; exit 2; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract() {
  # args: $1=file $2=sentinel-name
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1"
}

GUARD_BLOCK="$(extract "$GUARD" "adhoc-author-normalize-guard")"
[ -z "$GUARD_BLOCK" ] && { echo "FATAL: could not extract guard block (sentinels missing?)" >&2; exit 2; }
ok "located live guard normalization block via sentinel extraction"

DISPATCH_BLOCK="$(extract "$DISPATCHER" "adhoc-author-normalize-dispatcher")"
[ -z "$DISPATCH_BLOCK" ] && { echo "FATAL: could not extract dispatcher block (sentinels missing?)" >&2; exit 2; }
ok "located live dispatcher normalization block via sentinel extraction"

# normalize <block> <author-in> -> prints resulting $AUTHOR.
# Runs in a plain `bash -c`, which resolves `grep` to the real /usr/bin/grep
# (not any interactive-shell shadowing) — the same resolution launchd gets.
# `log` is intentionally left undefined: the real scripts define it elsewhere,
# and a "command not found" on stderr (discarded here) does not stop the
# block, matching how the existing gate-author-*.selftest.sh files extract
# fragments that call `log`.
normalize() {
  local block="$1" author_in="$2"
  AUTHOR="$author_in" bash -c "$block"$'\necho "$AUTHOR"' 2>/dev/null
}

echo "── (1) guard: real adhoc author normalizes (the bug's own repro case) ──"
GOT=$(normalize "$GUARD_BLOCK" "digo-wa-adhoc-e2510107f6")
[ "$GOT" = "digo-wa" ] && ok "digo-wa-adhoc-e2510107f6 -> digo-wa" \
  || bad "expected digo-wa, got '$GOT' — normalization did not run"

echo "── (2) guard: second doc example normalizes ──"
GOT=$(normalize "$GUARD_BLOCK" "batista-lx-adhoc-abc123")
[ "$GOT" = "batista-lx" ] && ok "batista-lx-adhoc-abc123 -> batista-lx" \
  || bad "expected batista-lx, got '$GOT' — normalization did not run"

echo "── (3) guard: non-adhoc author passes through unchanged ──"
GOT=$(normalize "$GUARD_BLOCK" "mila")
[ "$GOT" = "mila" ] && ok "mila -> mila (no false-positive normalization)" \
  || bad "expected mila unchanged, got '$GOT'"

echo "── (4) dispatcher: real adhoc author normalizes ──"
GOT=$(normalize "$DISPATCH_BLOCK" "digo-wa-adhoc-e2510107f6")
[ "$GOT" = "digo-wa" ] && ok "digo-wa-adhoc-e2510107f6 -> digo-wa" \
  || bad "expected digo-wa, got '$GOT' — normalization did not run"

echo "── (5) dispatcher: second doc example normalizes ──"
GOT=$(normalize "$DISPATCH_BLOCK" "batista-lx-adhoc-abc123")
[ "$GOT" = "batista-lx" ] && ok "batista-lx-adhoc-abc123 -> batista-lx" \
  || bad "expected batista-lx, got '$GOT' — normalization did not run"

echo "── (6) dispatcher: non-adhoc author passes through unchanged ──"
GOT=$(normalize "$DISPATCH_BLOCK" "mila")
[ "$GOT" = "mila" ] && ok "mila -> mila (no false-positive normalization)" \
  || bad "expected mila unchanged, got '$GOT'"

echo ""
echo "== gate-author-adhoc-normalize: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
