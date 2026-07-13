#!/usr/bin/env bash
# pilot-dispatcher.title-truncation.selftest.sh — Prove the ga-k803 fix for
# byte-vs-codepoint truncation of STORY_TITLE / STORY_ESTRELA in dispatch_one().
#
# Bug ga-k803: STORY_TITLE was built with `jq -r '...' | head -c 100`. head -c
# counts BYTES, not characters. When byte offset 100 lands mid multi-byte UTF-8
# char (common in pt-BR titles — em-dash, accents), the output is a truncated
# INVALID UTF-8 sequence. `gc sling` then tries to write it to Dolt, which
# REJECTS the insert (Error 1105 Incorrect string value), the Pilot releases
# the claim, and retries forever — the bead never dispatches (real case:
# ga-7omv, 2026-07-13, em-dash bytes E2 80 94 cut to E2 80 at the boundary).
#
# Fix: move the truncation INSIDE jq as a codepoint-aware slice (`.[0:100]`,
# `.[0:200]`), removing the byte-oriented `head -c` entirely. jq slices
# operate on Unicode codepoints, so a slice can never split a character.
#
# No LIB_ONLY sourcing mode exists for pilot-dispatcher.sh (unlike the gate
# dispatcher), so this harness drift-guards the exact live jq filters at both
# call sites and exercises the same technique standalone against the precise
# boundary case that broke ga-7omv. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

is_valid_utf8() {
  python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null
}

# ── 1. drift-guard: the byte-truncation bug pattern must be GONE ────────────
echo "── 1. drift-guard: no byte-oriented head -c on title/estrela extraction ──"
if grep -qE 'STORY_TITLE=.*head -c' "$DISPATCHER"; then
  bad "STORY_TITLE extraction still pipes through head -c (byte truncation regressed)"
else
  ok "STORY_TITLE extraction no longer uses head -c"
fi
if grep -qE 'STORY_ESTRELA=.*head -c' "$DISPATCHER"; then
  bad "STORY_ESTRELA extraction still pipes through head -c (byte truncation regressed)"
else
  ok "STORY_ESTRELA extraction no longer uses head -c"
fi

# ── 2. drift-guard: the codepoint-safe jq slice must be PRESENT ─────────────
echo "── 2. drift-guard: codepoint-safe jq slice wired at both call sites ──"
STORY_TITLE_LINE=$(grep -E '^\s*STORY_TITLE=' "$DISPATCHER" | head -1)
STORY_ESTRELA_LINE=$(grep -E '^\s*STORY_ESTRELA=' "$DISPATCHER" | head -1)
if echo "$STORY_TITLE_LINE" | grep -qE '\.\[0:100\]'; then
  ok "STORY_TITLE uses jq .[0:100] codepoint slice"
else
  bad "STORY_TITLE does not use a jq .[0:100] slice: $STORY_TITLE_LINE"
fi
if echo "$STORY_ESTRELA_LINE" | grep -qE '\.\[0:200\]'; then
  ok "STORY_ESTRELA uses jq .[0:200] codepoint slice"
else
  bad "STORY_ESTRELA does not use a jq .[0:200] slice: $STORY_ESTRELA_LINE"
fi

# ── 3. functional: reproduce the ga-7omv boundary case end-to-end ───────────
echo "── 3. functional: em-dash straddling the byte-100 boundary ──"
# 98 ASCII bytes + a 3-byte em-dash (occupying bytes 99-101) + tail -> byte
# 100 falls INSIDE the em-dash (its 2nd byte) under the old head -c 100 path.
TITLE_BOUNDARY=$(python3 -c "print('a' * 98 + '—' + 'b' * 20)")
STORY_JSON=$(jq -n --arg t "$TITLE_BOUNDARY" '{title: $t}')

OLD_RESULT=$(echo "$STORY_JSON" | jq -r '.title // .description // "untitled"' | head -c 100)
if printf '%s' "$OLD_RESULT" | is_valid_utf8; then
  bad "sanity check failed: old head -c 100 pattern should produce INVALID utf-8 on this fixture"
else
  ok "sanity: confirmed the OLD head -c 100 pattern breaks on this fixture (pins the bug)"
fi

NEW_RESULT=$(echo "$STORY_JSON" | jq -r '(.title // .description // "untitled") | .[0:100]')
if printf '%s' "$NEW_RESULT" | is_valid_utf8; then
  ok "NEW jq .[0:100] slice produces valid UTF-8 across the boundary"
else
  bad "NEW jq .[0:100] slice produced INVALID UTF-8 — fix is broken"
fi

# ── 4. regression: long ASCII-only titles still truncate to ~100 chars ──────
echo "── 4. regression: ASCII-only long titles still truncate ──"
ASCII_TITLE=$(python3 -c "print('x' * 150)")
ASCII_JSON=$(jq -n --arg t "$ASCII_TITLE" '{title: $t}')
ASCII_RESULT=$(echo "$ASCII_JSON" | jq -r '(.title // .description // "untitled") | .[0:100]')
ASCII_LEN=$(printf '%s' "$ASCII_RESULT" | wc -c | tr -d ' ')
if [ "$ASCII_LEN" -eq 100 ]; then
  ok "ASCII title truncated to exactly 100 chars"
else
  bad "ASCII title truncation length: expected 100, got $ASCII_LEN"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
