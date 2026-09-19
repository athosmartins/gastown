#!/bin/bash
# jsonl-export.selftest.sh — unit tests for ensure_archive_pack_config(), the
# ga-gtrc8n fix that makes the git-maintenance pack.threads/windowMemory/
# deltaCacheSize bound durable across archive-repo deletion+recreation.
#
# Hermetic: sources jsonl-export.sh in library mode (JSONL_EXPORT_LIB=1),
# which returns before dolt-target.sh is sourced — no live Dolt server, port
# resolution, or GC_CITY_PATH is ever required. Real dolt/git-push/mail/nudge
# are NEVER called; only throwaway repos under a temp directory are touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/jsonl-export.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Runs "$@" as a command after sourcing jsonl-export.sh in library mode, in a
# subshell — so the sourced script's `set -euo pipefail` never leaks into
# this selftest's own shell, and each call starts from a clean function/var
# state.
lib_call() {
  (
    export JSONL_EXPORT_LIB=1
    . "$SCRIPT" >/dev/null 2>&1
    "$@"
  )
}

echo "=== jsonl-export.selftest.sh ==="

if lib_call type ensure_archive_pack_config >/dev/null 2>&1; then
  ok "ensure_archive_pack_config defined by lib-mode source"
else
  bad "ensure_archive_pack_config NOT defined — lib mode broken, or fix not yet implemented"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── AC1: a freshly created repo (the real "git init" + call path) is born ────
# ── with all three keys ───────────────────────────────────────────────────────
FRESH_REPO="$WORK/fresh-repo"
mkdir -p "$FRESH_REPO"
git -C "$FRESH_REPO" init -q
lib_call ensure_archive_pack_config "$FRESH_REPO"

threads=$(git -C "$FRESH_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")
window=$(git -C "$FRESH_REPO" config --get pack.windowMemory 2>/dev/null || echo "MISSING")
deltacache=$(git -C "$FRESH_REPO" config --get pack.deltaCacheSize 2>/dev/null || echo "MISSING")

[ "$threads" = "2" ] \
  && ok "fresh repo: pack.threads = 2" \
  || bad "fresh repo: pack.threads = '$threads', want '2'"
[ "$window" = "256m" ] \
  && ok "fresh repo: pack.windowMemory = 256m" \
  || bad "fresh repo: pack.windowMemory = '$window', want '256m'"
[ "$deltacache" = "64m" ] \
  && ok "fresh repo: pack.deltaCacheSize = 64m" \
  || bad "fresh repo: pack.deltaCacheSize = '$deltacache', want '64m'"

# ── AC2: a pre-existing repo WITHOUT the keys (simulates a repo created ──────
# ── before this fix shipped) gains them on its next execution ────────────────
EXISTING_REPO="$WORK/existing-repo"
mkdir -p "$EXISTING_REPO"
git -C "$EXISTING_REPO" init -q
if git -C "$EXISTING_REPO" config --get pack.threads >/dev/null 2>&1; then
  bad "test setup invalid: existing-repo already has pack.threads before the fix runs"
else
  ok "test setup: existing-repo has no pack.threads before the fix runs (sanity check)"
fi

lib_call ensure_archive_pack_config "$EXISTING_REPO"
threads2=$(git -C "$EXISTING_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")
[ "$threads2" = "2" ] \
  && ok "pre-existing repo without keys: gains pack.threads = 2 on next execution" \
  || bad "pre-existing repo without keys: pack.threads = '$threads2', want '2'"

# ── AC3: idempotent — calling it again does not duplicate or change values ──
lib_call ensure_archive_pack_config "$EXISTING_REPO"
lib_call ensure_archive_pack_config "$EXISTING_REPO"

value_count=$(git -C "$EXISTING_REPO" config --get-all pack.threads | wc -l | tr -d ' ')
threads3=$(git -C "$EXISTING_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")

[ "$value_count" = "1" ] \
  && ok "idempotent: pack.threads has exactly one value after repeated calls (no duplication)" \
  || bad "idempotent: pack.threads has $value_count values after repeated calls, want 1"
[ "$threads3" = "2" ] \
  && ok "idempotent: pack.threads still = 2 after repeated calls" \
  || bad "idempotent: pack.threads = '$threads3' after repeated calls, want '2'"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
