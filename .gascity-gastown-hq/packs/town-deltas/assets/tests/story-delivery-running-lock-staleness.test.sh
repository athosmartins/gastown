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
# Extracts the REAL edited regions from story-delivery.sh (no duplication):
#   CHECK block            — the top-of-loop "skip if already in delivery"
#     gate, now staleness-aware.
#   CLAIM block             — where delivery:running is set, now also
#     persisting delivery.running_since so a LATER sweep can compute the
#     lock's age.
#   FULL_FALLTHROUGH block  — CHECK, PLUS everything between it and CLAIM
#     (the delivery:no-deploy-cmd-exhausted check and the ga-0m6tgc
#     OPEN_SIBLINGS hold) — see D1/D2 below.
# and drives each with a stubbed `bd` (real jq/date are used — no need to
# stub pure computation) to prove:
#   C1 NO-LOCK       — no delivery:running label at all → block falls through
#                      cleanly, zero bd mutations (baseline, unaffected).
#   C2 FRESH         — delivery:running set ~60s ago → skip (continue), zero
#                      bd mutations (the label stays exactly as it was).
#   C3 STALE         — delivery:running set past the ceiling → RENEWED in
#                      place (delivery.running_since refreshed to now, label
#                      itself never removed) + a comment citing ga-015qqe
#                      posted, and NOT skipped (falls through so the same
#                      sweep re-processes the story instead of waiting a
#                      full extra interval).
#   C4 NO-TIMESTAMP  — delivery:running set, but no delivery.running_since
#                      metadata (e.g. a lock from before this fix shipped) →
#                      fail-closed: treated as FRESH (skip), never as stale.
#                      Never clobber a possibly-still-live delivery just
#                      because we can't prove its age.
#   C5 GARBAGE-TS    — delivery.running_since present but unparseable →
#                      same fail-closed skip as C4.
#   CLAIM            — claiming the lock persists BOTH the delivery:running
#                      label AND a delivery.running_since metadata value.
#   D1 STALE+SIBLING — gate-fix regression (gate_run=ga-epuc97, reviewer 1
#                      FAIL): a STALE lock whose CHECK-block renewal is
#                      immediately followed, in the SAME iteration, by the
#                      OPEN_SIBLINGS hold (`continue`). Proves the lock is
#                      NEVER actually removed (only renewed) — so the story
#                      is never left lock-free while a genuinely still-open
#                      sibling marker holds it, which would otherwise let a
#                      second, concurrent delivery run start once the
#                      sibling clears while the first (merely slow, not
#                      dead) run might still be mid-flight. Fails against
#                      the pre-gate-fix version of this file's CHECK block
#                      (it called `label remove` unconditionally — verified
#                      by running this test against that revision) and
#                      passes against the renew-in-place fix.
#   D2 STALE+NOSIB   — sanity companion to D1: same STALE lock, but with NO
#                      open sibling, so the fall-through reaches the
#                      "clear stale hold label" line past OPEN_SIBLINGS —
#                      confirms D1's harness genuinely exercises the
#                      sibling-hold branch rather than short-circuiting
#                      somewhere earlier.
#   D3 STALE+EXHSTD  — the review's lower-confidence secondary note: a STALE
#                      lock where delivery:no-deploy-cmd-exhausted is ALSO
#                      already present sits in the same fall-through window.
#                      Locks in that the renewal survives that `continue`
#                      too, whatever the actual reachability of this exact
#                      label combination in production (see the inline
#                      comment at the test site).
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

# CHECK, plus the no-deploy-cmd-exhausted check and the OPEN_SIBLINGS hold
# that sit between it and CLAIM — the exact fall-through window the
# gate-fix (ga-epuc97 reviewer 1) flagged. Ends right before "# Mark as
# running (claim)", same as CLAIM_BLOCK's own start boundary above.
FULL_FALLTHROUGH_BLOCK="$(sed -n '/^# Skip if already in delivery/,/^# Mark as running (claim)/p' "$DELIVERY" | sed '$d')"
[ -n "$FULL_FALLTHROUGH_BLOCK" ] || { echo "FAIL: could not extract the FULL_FALLTHROUGH block"; exit 1; }

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

# ── C3: stale lock (3600s old, past the 1800s ceiling) → renewed + commented ─
run_check "$(ago 3600)" 1
echo "$LAST_BD" | grep "update ga-test --set-metadata delivery.running_since=" >/dev/null \
  && ok "C3 stale (3600s old): delivery.running_since RENEWED" \
  || nok "C3 stale-renewed" "$LAST_BD"
echo "$LAST_BD" | grep "label remove ga-test delivery:running" >/dev/null \
  && nok "C3 stale: label must NOT be removed (renew-in-place, gate-fix ga-epuc97)" "$LAST_BD" \
  || ok "C3 stale: delivery:running label never removed (renewed, not dropped)"
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

# ── D1/D2: the FULL fall-through window (CHECK -> no-deploy-cmd-exhausted ──
# check -> OPEN_SIBLINGS hold), reproducing the gate-fix regression
# (gate_run=ga-epuc97, reviewer 1 FAIL) end-to-end instead of only in
# isolation. gate_bead_sibling_status_lines is sourced from elsewhere in
# story-delivery.sh (quality-gate-guard.sh) -- stub it here so this block
# stays self-contained, same spirit as stubbing bd/log/warn/err above.
#
# run_full_fallthrough <running_since> <has_lock=1|0> <sibling_lines-or-empty> [extra_label]
run_full_fallthrough() {
  local running_since="$1" has_lock="$2" sibling_lines="$3" extra_label="${4:-}"
  local T; T="$(mktemp -d)"
  BD_LOG="$T/bd.log"

  local labels_json="[]"
  [ "$has_lock" = "1" ] && labels_json='["delivery:running"]'
  if [ -n "$extra_label" ]; then
    labels_json=$(printf '%s' "$labels_json" | jq -c --arg l "$extra_label" '. + [$l]')
  fi
  local meta_json="{}"
  [ -n "$running_since" ] && meta_json="{\"delivery.running_since\":\"$running_since\"}"

  bd() { echo "bd $*" >> "$BD_LOG"; }
  log() { :; }; warn() { echo "WARN $*" >> "$BD_LOG"; }; err() { :; }
  # shellcheck disable=SC2317  # invoked indirectly via eval "$FULL_FALLTHROUGH_BLOCK"
  gate_bead_sibling_status_lines() { printf '%s' "$FFT_SIBLING_LINES"; }

  local STORY_ID="ga-test"
  local STORY_STORE="fake-city"
  local GC_CITY="fake-city"
  local STORY_LABELS; STORY_LABELS=$(printf '%s' "$labels_json" | jq -r 'join(",")')
  local STORY; STORY=$(jq -cn --argjson labels "$labels_json" --argjson meta "$meta_json" \
    '{id:"ga-test",labels:$labels,metadata:$meta}')
  local DRY_RUN=0
  local DELIVERY_RUNNING_STALE_CEILING_S=1800
  FFT_SIBLING_LINES="$sibling_lines"

  ( set -o pipefail; for _t in _once; do eval "$FULL_FALLTHROUGH_BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  unset -f bd log warn err gate_bead_sibling_status_lines
  rm -rf "$T"
}

# ── D1: STALE lock + an OPEN sibling → renew survives the sibling `continue` ─
run_full_fallthrough "$(ago 3600)" 1 "$(printf 'fix/other-branch\treviewing\tsome_rig')"
echo "$LAST_BD" | grep "update ga-test --set-metadata delivery.running_since=" >/dev/null \
  && ok "D1 stale+sibling: delivery.running_since RENEWED before the sibling hold" \
  || nok "D1 stale+sibling: renewal" "$LAST_BD"
echo "$LAST_BD" | grep "label remove ga-test delivery:running" >/dev/null \
  && nok "D1 stale+sibling: delivery:running must NEVER be removed here (this was the reported gap — the story would sit lock-free for as long as the sibling stays open, then risk a second concurrent run once it clears)" "$LAST_BD" \
  || ok "D1 stale+sibling: delivery:running never removed -- lock survives the sibling continue"
echo "$LAST_BD" | grep "label add ga-test delivery:blocked-sibling" >/dev/null \
  && ok "D1 stale+sibling: sibling-hold branch genuinely reached (harness sanity)" \
  || nok "D1 stale+sibling: sibling-hold branch not reached -- test would be vacuous" "$LAST_BD"

# ── D2: STALE lock + NO sibling → sanity companion, reaches past the hold ────
run_full_fallthrough "$(ago 3600)" 1 ""
echo "$LAST_BD" | grep "update ga-test --set-metadata delivery.running_since=" >/dev/null \
  && ok "D2 stale+no-sibling: delivery.running_since RENEWED" \
  || nok "D2 stale+no-sibling: renewal" "$LAST_BD"
echo "$LAST_BD" | grep "label remove ga-test delivery:running" >/dev/null \
  && nok "D2 stale+no-sibling: delivery:running must NEVER be removed" "$LAST_BD" \
  || ok "D2 stale+no-sibling: delivery:running never removed"
echo "$LAST_BD" | grep "label remove ga-test delivery:blocked-sibling" >/dev/null \
  && ok "D2 stale+no-sibling: fell through past OPEN_SIBLINGS to the clear-stale-hold line (harness sanity, contrasts with D1)" \
  || nok "D2 stale+no-sibling: did not reach past OPEN_SIBLINGS -- test would not contrast with D1" "$LAST_BD"

# ── D3: STALE lock + delivery:no-deploy-cmd-exhausted also present ──────────
# The gate-fix review flagged this second `continue` (same fall-through
# window, lower confidence) as "worth checking for the same shape". Reading
# story-delivery.sh's Step-3 halt logic shows the no-deploy-cmd-exhausted
# label is only ever set together with removing delivery:running in the
# SAME halt block (label-remove immediately precedes label-add there), so
# in ordinary operation a story's labels can't carry both at once -- this
# combination is only reachable via a prior best-effort bd write silently
# failing. The fix doesn't special-case that: renewal happens before ANY
# downstream check that can `continue`, so it's covered either way. Lock
# that in explicitly rather than leaving it as an argument.
run_full_fallthrough "$(ago 3600)" 1 "" "delivery:no-deploy-cmd-exhausted"
echo "$LAST_BD" | grep "update ga-test --set-metadata delivery.running_since=" >/dev/null \
  && ok "D3 stale+exhausted: delivery.running_since RENEWED before the exhausted-check continue" \
  || nok "D3 stale+exhausted: renewal" "$LAST_BD"
echo "$LAST_BD" | grep "label remove ga-test delivery:running" >/dev/null \
  && nok "D3 stale+exhausted: delivery:running must NEVER be removed here" "$LAST_BD" \
  || ok "D3 stale+exhausted: delivery:running never removed -- lock survives the exhausted-check continue"
echo "$LAST_BD" | grep -E "label (add|remove) ga-test delivery:blocked-sibling" >/dev/null \
  && nok "D3 stale+exhausted: must continue BEFORE reaching OPEN_SIBLINGS (harness sanity)" "$LAST_BD" \
  || ok "D3 stale+exhausted: exhausted-check continue fired before OPEN_SIBLINGS was reached (harness sanity)"

echo ""
echo "story-delivery delivery:running staleness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
