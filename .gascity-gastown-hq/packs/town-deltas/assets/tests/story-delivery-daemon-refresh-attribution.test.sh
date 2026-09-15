#!/usr/bin/env bash
# story-delivery-daemon-refresh-attribution.test.sh — regression test for
# ga-3bdttu (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh and
# story-delivery-daemon-refresh-baseline.test.sh).
#
# THE BUG: daemon-refresh.sh's CHANGED set is computed over
# DAEMON_REFRESH_PRE_SHA..POST_DEPLOY_SHA — which ga-gokm6 correctly widens to
# a persisted per-rig baseline marker so no commit goes unexamined. That wide
# range is correct for deciding WHETHER any daemon is stale, but story-
# delivery.sh used to also use a non-OK verdict from it to BLAME/HOLD whichever
# story's delivery happened to close the window — even when that story's own
# merge never touched the flagged files. Confirmed live in story-delivery.log
# 2026-09-12: wa-u09s4 (11:04) and wa-m6v3d (11:17), each a single
# tests/*.py-only merge, were both held with delivery:failed + delivery:deploy-
# pending + an author nudge telling them not to mark done, for a demand-
# dashboard staleness that predated both of their own commits — an innocent
# bead reads as broken while whichever bead actually introduced the dormant
# code can close clean with no delivery label at all.
#
# THE FIX: compute THIS story's own contribution separately — its real
# PRE_DEPLOY_SHA..POST_DEPLOY_SHA, never the widened DAEMON_REFRESH_PRE_SHA —
# and when that delta is itself tests/**+docs/**+*.md-only, exempt only the
# BLAME/HOLD decision (this story proceeds, nothing is withheld). The
# underlying restart requirement is NEVER suppressed: the baseline marker is
# deliberately not advanced in this case (only OK|SKIPPED advances it), and
# the Mayor is still nudged with the (relabeled) real reason.
#
# T1: this story's own delta is tests-only, wide window (widened via a seeded
#     older baseline) still returns NEEDS_GUARDED_RESTART → NOT blamed: no
#     delivery:failed/deploy-pending, no author nudge, Mayor nudged with the
#     "not caused by" framing, block falls through (no `continue`), and the
#     baseline marker is NOT advanced (the real staleness stays visible to the
#     next sweep).
# T2: this story's own delta includes a real production file → blamed exactly
#     as before: delivery:failed + delivery:deploy-pending added, author +
#     Mayor nudged, block halts via `continue`.
# T3: a true this-iteration no-op (PRE_DEPLOY_SHA==POST_DEPLOY_SHA, ga-gokm6's
#     own scenario — a sibling story already advanced HEAD past this story's
#     commit) → THIS_PULL_STRUCTURALLY_INERT cannot be determined from the SHA
#     delta and must stay unknown, falling back to the existing (blame)
#     behavior rather than guessing an exemption.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to the other story-delivery-*.test.sh files.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# run_block <pre-ref> <post-ref> <baseline-seed-ref-or-empty>
# Builds a real 3-commit git fixture (C0 base -> C1 adds a PRODUCTION file
# lib/foo.py -> C2 adds a TESTS-ONLY file tests/test_bar.py) in a fresh
# RUNTIME_DIR, points PRE/POST_DEPLOY_SHA at the requested commits, optionally
# seeds the per-rig baseline marker, stubs daemon-refresh.sh to always return
# NEEDS_GUARDED_RESTART (simulating a real, unresolved staleness somewhere in
# the wide window), and runs the real Step 5b block. Sets globals: RUN_RC,
# LOG_OUT, BD_CALLS, GC_CALLS, MARKER_AFTER, REACHED (1 if the block fell
# through past `eval`, i.e. did NOT `continue`; 0 if it did).
run_block() {
  local pre_ref="$1" post_ref="$2" seed_ref="$3"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/lib" "$REPO/tests"
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo prod > "$REPO/lib/foo.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo test > "$REPO/tests/test_bar.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  local pre_sha post_sha seed_sha
  case "$pre_ref" in C0) pre_sha="$SHA_C0" ;; C1) pre_sha="$SHA_C1" ;; C2) pre_sha="$SHA_C2" ;; esac
  case "$post_ref" in C0) post_sha="$SHA_C0" ;; C1) post_sha="$SHA_C1" ;; C2) post_sha="$SHA_C2" ;; esac
  if [ -n "$seed_ref" ]; then
    case "$seed_ref" in C0) seed_sha="$SHA_C0" ;; C1) seed_sha="$SHA_C1" ;; C2) seed_sha="$SHA_C2" ;; esac
    mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
    printf '%s\n' "$seed_sha" > "$GC_CITY/$MARKER_REL"
  fi

  # Stub always reports NEEDS_GUARDED_RESTART — this test is about WHO gets
  # blamed for a real, persistent verdict, not about daemon-refresh.sh's own
  # (separately, exhaustively tested) verdict logic.
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
echo "VERDICT=NEEDS_GUARDED_RESTART"
echo "AFFECTED=com.test.central-sender"
echo "RESTARTED="
echo "FRESH_FAIL="
echo "GUARDED=com.test.central-sender"
echo "REASON=sensitive hot-path daemon needs a guarded restart"
exit 1
EOF

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local PRE_DEPLOY_SHA="$pre_sha" POST_DEPLOY_SHA="$post_sha" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # ga-6zkhci: Step 5b now falls back to a MERGE_SHA-derived delta when
  # PRE_DEPLOY_SHA==POST_DEPLOY_SHA (see
  # story-delivery-daemon-refresh-noop-attribution.test.sh for that path,
  # including T3 = this file's own "no merge sha info at all" case reproduced
  # with a resolvable MERGE_SHA instead). MERGE_SHA stays empty here so the
  # fallback's `[ -n "$MERGE_SHA" ]` guard evaluates false and T3 keeps
  # testing exactly what it always did: no attribution signal available at
  # all → stays unknown → existing blame behavior. (Declared, not left
  # unset, because the block runs under `set -u` in this harness.)
  local MERGE_SHA=""
  # ga-6zkhci fix-attempt-3: same reasoning as MERGE_SHA above — declared so
  # the shared block's `set -u` never trips on it, though the (already-false)
  # `[ -n "$MERGE_SHA" ]` check short-circuits before it would be read.
  local MERGE_PRE_MAIN=""
  get_runbook_field() { echo "central-sender"; }

  rm -f "$T/reached.marker"
  ( for _t in _once; do eval "$BLOCK"; touch "$T/reached.marker"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  MARKER_AFTER="$(cat "$GC_CITY/$MARKER_REL" 2>/dev/null || true)"
  [ -f "$T/reached.marker" ] && REACHED=1 || REACHED=0
  EXPECT_C0="$SHA_C0"; EXPECT_C1="$SHA_C1"; EXPECT_C2="$SHA_C2"
  rm -rf "$T"
}

# ── T1: own delta (C1..C2) is tests-only; wide window (baseline @ C0) still
#        NEEDS_GUARDED_RESTART → must NOT be blamed ─────────────────────────
run_block C1 C2 C0
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0)" || nok "T1 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=1" \
  && ok "T1 own-merge correctly classified structurally inert" \
  || nok "T1 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 1 ] && ok "T1 block falls through past the verdict (no continue) — delivery proceeds" \
  || nok "T1 fell through" "REACHED=$REACHED"
! echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T1 delivery:failed NOT added — innocent story not blamed" \
  || nok "T1 no failed-label" "$BD_CALLS"
! echo "$BD_CALLS" | grep -q "delivery:deploy-pending" \
  && ok "T1 delivery:deploy-pending NOT added" \
  || nok "T1 no deploy-pending" "$BD_CALLS"
! echo "$GC_CALLS" | grep -q "session nudge crew/tester" \
  && ok "T1 author NOT nudged — did nothing wrong" \
  || nok "T1 no author nudge" "$GC_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T1 Mayor still nudged — real staleness not silenced" \
  || nok "T1 mayor nudged" "$GC_CALLS"
echo "$GC_CALLS" | grep -q "NOT caused by ga-test" \
  && ok "T1 Mayor nudge explicitly clears this story of blame" \
  || nok "T1 mayor nudge wording" "$GC_CALLS"
[ "$MARKER_AFTER" = "$EXPECT_C0" ] \
  && ok "T1 baseline marker NOT advanced — real staleness stays visible to next sweep" \
  || nok "T1 marker untouched" "got '$MARKER_AFTER' want '$EXPECT_C0'"

# ── T2: own delta (C0..C1) includes the real production file → blamed as
#        before ─────────────────────────────────────────────────────────────
run_block C0 C1 ""
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T2 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T2 own-merge correctly classified NOT structurally inert" \
  || nok "T2 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T2 block halts via continue (does not fall through)" \
  || nok "T2 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep -q "label add ga-test delivery:failed" \
  && ok "T2 delivery:failed added — this story's own merge IS the cause" \
  || nok "T2 failed-label" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "label add ga-test delivery:deploy-pending" \
  && ok "T2 delivery:deploy-pending added" \
  || nok "T2 deploy-pending" "$BD_CALLS"
echo "$GC_CALLS" | grep -q "session nudge crew/tester" \
  && ok "T2 author nudged" \
  || nok "T2 author nudge" "$GC_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T2 Mayor nudged" \
  || nok "T2 mayor nudge" "$GC_CALLS"

# ── T3: true this-iteration no-op (PRE==POST==C2), baseline widened to C0 →
#        cannot determine this story's own delta; must fall back to blame,
#        never guess an exemption ───────────────────────────────────────────
run_block C2 C2 C0
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0)" || nok "T3 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=unknown" \
  && ok "T3 no-op range → inert stays unknown (never guessed)" \
  || nok "T3 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T3 block halts via continue (falls back to existing behavior)" \
  || nok "T3 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep -q "label add ga-test delivery:failed" \
  && ok "T3 delivery:failed added — unknown attribution defaults to blame, not exemption" \
  || nok "T3 failed-label" "$BD_CALLS"
[ "$MARKER_AFTER" = "$EXPECT_C0" ] \
  && ok "T3 baseline marker NOT advanced (unchanged pre-existing behavior on non-OK verdict)" \
  || nok "T3 marker untouched" "got '$MARKER_AFTER' want '$EXPECT_C0'"

echo ""
echo "story-delivery daemon-refresh attribution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
