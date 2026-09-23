#!/usr/bin/env bash
# story-delivery-running-lock-staleness.test.sh — regression test for the
# delivery:running staleness fix (ga-015qqe) in story-delivery.sh.
#
# wa-r4ehy.2 (P0) sat wedged ~3.5h: the delivery:running lock had NO
# staleness/timeout check at all (unlike every other lock in this file), so
# once the run that set it died (crash/kill, e.g. resource pressure) before
# reaching any of its own cleanup points, every later sweep just logged
# "already has delivery:running — skipping" forever, with no self-heal.
#
# Extracts the REAL two edited blocks from story-delivery.sh (no duplication):
#   CHECK block — the top-of-loop "skip if already in delivery" gate, now
#     staleness-aware.
#   CLAIM block — where delivery:running is set, now also persisting
#     delivery.running_since so a LATER sweep can compute the lock's age.
# and drives each with a stubbed `bd` (real jq/date are used — no need to
# stub pure computation) to prove:
#   C1 NO-LOCK       — no delivery:running label at all → block falls through
#                      cleanly, zero bd mutations (baseline, unaffected).
#   C2 FRESH         — delivery:running set ~60s ago → skip (continue), zero
#                      bd mutations (the label stays exactly as it was).
#   C3 STALE         — delivery:running set past the ceiling → CLEARED
#                      (label removed) + a comment citing ga-015qqe posted,
#                      and NOT skipped (falls through so the same sweep
#                      re-processes the story instead of waiting a full
#                      extra interval).
#   C4 NO-TIMESTAMP  — delivery:running set, but no delivery.running_since
#                      metadata (e.g. a lock from before this fix shipped) →
#                      fail-closed: treated as FRESH (skip), never as stale.
#                      Never clobber a possibly-still-live delivery just
#                      because we can't prove its age.
#   C5 GARBAGE-TS    — delivery.running_since present but unparseable →
#                      same fail-closed skip as C4.
#   CLAIM            — claiming the lock persists BOTH the delivery:running
#                      label AND a delivery.running_since metadata value.
#
# set -u only (no pipefail at file level — see story-delivery-staleness.test.sh's
# own header for why: `X | grep` pipes under load can false-FAIL from a SIGPIPE
# race, ga-uel7sb). The extracted blocks run WITH pipefail (matches production).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

CHECK_BLOCK="$(sed -n '/^# Skip if already in delivery/,/^# ga-aqqj0: skip if the no-deploy-cmd/p' "$DELIVERY" | sed '$d')"
[ -n "$CHECK_BLOCK" ] || { echo "FAIL: could not extract the delivery:running CHECK block"; exit 1; }

CLAIM_BLOCK="$(sed -n '/^# Mark as running (claim)/,/^DELIVERY_START=/p' "$DELIVERY" | sed '$d')"
[ -n "$CLAIM_BLOCK" ] || { echo "FAIL: could not extract the delivery:running CLAIM block"; exit 1; }

# ago <seconds> — an ISO8601 UTC timestamp that many seconds in the past.
# BSD date (macOS, -v) first, GNU date (-d) fallback.
ago() {
  date -u -v-"${1}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${1} seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# run_check <running_since-or-empty> <has_lock=1|0>
# Sets RUN_RC, LAST_BD (bd invocation log) as globals for the caller to assert on.
run_check() {
  local running_since="$1" has_lock="$2"
  local T; T="$(mktemp -d)"
  BD_LOG="$T/bd.log"

  local labels_json="[]"
  [ "$has_lock" = "1" ] && labels_json='["delivery:running"]'
  local meta_json="{}"
  [ -n "$running_since" ] && meta_json="{\"delivery.running_since\":\"$running_since\"}"

  bd() { echo "bd $*" >> "$BD_LOG"; }
  log() { :; }; warn() { echo "WARN $*" >> "$BD_LOG"; }; err() { :; }

  local STORY_ID="ga-test"
  local STORY_STORE="fake-city"
  local STORY_LABELS; STORY_LABELS=$(printf '%s' "$labels_json" | jq -r 'join(",")')
  local STORY; STORY=$(jq -cn --argjson labels "$labels_json" --argjson meta "$meta_json" \
    '{id:"ga-test",labels:$labels,metadata:$meta}')
  local DRY_RUN=0
  local DELIVERY_RUNNING_STALE_CEILING_S=1800

  ( set -o pipefail; for _t in _once; do eval "$CHECK_BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  unset -f bd log warn err
  rm -rf "$T"
}

# ── C1: no lock at all → falls through, zero bd mutations ───────────────────
run_check "" 0
[ -z "$LAST_BD" ] && ok "C1 no-lock: zero bd calls (nothing to check, block is a no-op)" \
  || nok "C1 no-lock" "$LAST_BD"

# ── C2: fresh lock (60s old) → skip, zero bd mutations ───────────────────────
run_check "$(ago 60)" 1
[ -z "$LAST_BD" ] && ok "C2 fresh (60s old): skipped cleanly, no label mutation" \
  || nok "C2 fresh" "$LAST_BD"

# ── C3: stale lock (3600s old, past the 1800s ceiling) → cleared + commented ─
run_check "$(ago 3600)" 1
echo "$LAST_BD" | grep "label remove ga-test delivery:running" >/dev/null \
  && ok "C3 stale (3600s old): delivery:running REMOVED" \
  || nok "C3 stale-removed" "$LAST_BD"
echo "$LAST_BD" | grep -i "ga-015qqe" >/dev/null \
  && ok "C3 stale: comment cites ga-015qqe (traceable to this fix)" \
  || nok "C3 stale-comment" "$LAST_BD"

# ── C4: lock present, NO delivery.running_since metadata → fail-closed skip ──
run_check "" 1
[ -z "$LAST_BD" ] && ok "C4 no-timestamp (pre-fix-shaped lock): fail-closed, treated as fresh, NOT cleared" \
  || nok "C4 no-timestamp-failclosed" "$LAST_BD"

# ── C5: lock present, UNPARSEABLE delivery.running_since → fail-closed skip ──
run_check "not-a-real-timestamp" 1
[ -z "$LAST_BD" ] && ok "C5 garbage-timestamp: fail-closed, treated as fresh, NOT cleared" \
  || nok "C5 garbage-timestamp-failclosed" "$LAST_BD"

# ── CLAIM: claiming persists both the label AND the timestamp metadata ──────
run_claim() {
  local T; T="$(mktemp -d)"
  BD_LOG="$T/bd.log"
  bd() { echo "bd $*" >> "$BD_LOG"; }
  local STORY_ID="ga-test"
  local STORY_STORE="fake-city"
  local DRY_RUN=0
  ( eval "$CLAIM_BLOCK" ) >/dev/null 2>&1
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  unset -f bd
  rm -rf "$T"
}
run_claim
echo "$LAST_BD" | grep "label add ga-test delivery:running" >/dev/null \
  && ok "CLAIM: delivery:running label added" \
  || nok "CLAIM label" "$LAST_BD"
echo "$LAST_BD" | grep "update ga-test --set-metadata delivery.running_since=" >/dev/null \
  && ok "CLAIM: delivery.running_since metadata persisted (the fix this test locks in)" \
  || nok "CLAIM metadata" "$LAST_BD"

echo ""
echo "story-delivery delivery:running staleness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
