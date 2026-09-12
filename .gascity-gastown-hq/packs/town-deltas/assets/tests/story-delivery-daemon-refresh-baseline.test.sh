#!/usr/bin/env bash
# story-delivery-daemon-refresh-baseline.test.sh — regression test for ga-gokm6
# (extracts the real Step 5b block from story-delivery.sh, no duplication —
# same technique as story-delivery-step5b.test.sh).
#
# THE BUG: for a self-repo rig (runtime_dir == git_repo, e.g.
# whatsapp_automation), something OTHER than story-delivery.sh's own sweep
# iteration — a crew session's post-merge fast-forward, or a sibling story's
# delivery earlier in the same sweep cycle — can advance RUNTIME_DIR's HEAD
# past a story's merge commit BEFORE this iteration captures PRE_DEPLOY_SHA.
# The subsequent `git pull` is then a true no-op ("Already up to date"), so
# PRE_DEPLOY_SHA == POST_DEPLOY_SHA. daemon-refresh.sh reads "no SHA delta"
# as "deploy changed nothing" and short-circuits to VERDICT=SKIPPED/
# PROOF=not_applicable WITHOUT ever running daemon discovery or sensitivity
# classification — even though real daemon-relevant code landed on disk
# since the last time any daemon was actually checked. Confirmed live twice
# in story-delivery.log (wa-gqdtk 2026-09-11T18:05:55Z, wa-fuveb
# 2026-09-11T15:47:35Z): com.whatsapp.pipedrive-sync ran ~2h of pre-merge
# code, unflagged, both times.
#
# THE FIX: story-delivery.sh now persists, per rig, the last sha
# daemon-refresh.sh actually got a chance to examine (advanced only after a
# non-halting OK/SKIPPED verdict), and feeds the helper the delta since THAT
# marker instead of since this iteration's own (possibly already-caught-up)
# pre-pull HEAD — falling back to today's behavior when no usable marker
# exists.
#
# T1: no marker yet (first run for this rig) → falls back to this
#     iteration's own PRE_DEPLOY_SHA (today's behavior, unchanged), and a
#     successful run creates the marker at POST_DEPLOY_SHA.
# T2: (the actual regression) marker seeded at an ancestor of
#     POST_DEPLOY_SHA, this iteration's own PRE_DEPLOY_SHA already equals
#     POST_DEPLOY_SHA (the exact race) → the helper is fed the marker as
#     PRE, not the collapsed this-iteration pre==post, and a successful run
#     advances the marker to POST_DEPLOY_SHA.
# T3: marker file contains unparseable garbage → safe fallback to this
#     iteration's own PRE_DEPLOY_SHA, no crash.
# T4: marker resolves to a real commit but is NOT an ancestor of
#     POST_DEPLOY_SHA (diverged/rewritten history) → safe fallback, no crash.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to story-delivery-step5b.test.sh.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# run_block <baseline-seed-or-empty-or-"GARBAGE"|"DIVERGED">
# Builds a real 3-commit git fixture in a fresh RUNTIME_DIR (C0 -> C1 -> C2),
# optionally seeds the per-rig marker, then runs the real Step 5b block with
# PRE_DEPLOY_SHA=POST_DEPLOY_SHA=C2 — reproducing the exact race (this
# iteration's own pre-pull HEAD already at the merge tip). Sets globals:
# RUN_RC, LOG_OUT (captured log() lines), MARKER_AFTER (marker content post-run).
run_block() {
  local seed="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  echo base > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo mid  > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  echo tip  > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  case "$seed" in
    "") : ;;  # T1: no marker file at all
    GARBAGE)
      mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
      printf 'not-a-sha\n' > "$GC_CITY/$MARKER_REL"
      ;;
    DIVERGED)
      # A real commit, but on a branch never merged into the C0->C1->C2 line —
      # resolves fine, is NOT an ancestor of SHA_C2.
      git -C "$REPO" checkout -q --orphan side-branch
      echo side > "$REPO/side.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m SIDE
      local SHA_SIDE; SHA_SIDE="$(git -C "$REPO" rev-parse HEAD)"
      git -C "$REPO" checkout -q main 2>/dev/null || git -C "$REPO" checkout -q master
      mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
      printf '%s\n' "$SHA_SIDE" > "$GC_CITY/$MARKER_REL"
      ;;
    C0)
      mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
      printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
      ;;
  esac

  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
echo "VERDICT=OK"
echo "RESTARTED="
echo "REASON=stub"
exit 0
EOF

  LOG_FILE="$T/log.log"
  bd()   { :; }
  gc()   { :; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  # The race: this iteration's OWN pre-pull HEAD is already C2 (something
  # else already fast-forwarded RUNTIME_DIR), and the pull itself is a
  # true no-op, so POST_DEPLOY_SHA is also C2 — exactly the "Already up to
  # date" signature logged for both wa-gqdtk and wa-fuveb.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  get_runbook_field() { echo "central-sender"; }

  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  MARKER_AFTER="$(cat "$GC_CITY/$MARKER_REL" 2>/dev/null || true)"
  EXPECT_C0="$SHA_C0"
  EXPECT_C2="$SHA_C2"
  rm -rf "$T"
}

# ── T1: no marker yet → fall back to this iteration's own PRE_DEPLOY_SHA ──────
run_block ""
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0) with no marker file" || nok "T1 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "pre=$EXPECT_C2 post=$EXPECT_C2" \
  && ok "T1 no marker → helper fed this-iteration pre==post (today's behavior, unchanged)" \
  || nok "T1 fallback pre" "$LOG_OUT"
[ "$MARKER_AFTER" = "$EXPECT_C2" ] \
  && ok "T1 marker created at POST_DEPLOY_SHA after a clean run" \
  || nok "T1 marker written" "got '$MARKER_AFTER' want '$EXPECT_C2'"

# ── T2: THE REGRESSION — marker at C0, this-iteration pre==post==C2 ───────────
run_block "C0"
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0) with marker seeded at C0" || nok "T2 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "pre=$EXPECT_C0 post=$EXPECT_C2" \
  && ok "T2 helper fed the MARKER (C0) as pre, not the collapsed this-iteration pre==post (C2) — the actual fix" \
  || nok "T2 baseline override" "$LOG_OUT"
[ "$MARKER_AFTER" = "$EXPECT_C2" ] \
  && ok "T2 marker advances from C0 to POST_DEPLOY_SHA (C2) after a clean run" \
  || nok "T2 marker advanced" "got '$MARKER_AFTER' want '$EXPECT_C2'"

# ── T3: marker file has unparseable garbage → safe fallback, no crash ────────
run_block "GARBAGE"
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0) with a garbage marker file" || nok "T3 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "pre=$EXPECT_C2 post=$EXPECT_C2" \
  && ok "T3 unparseable marker → safe fallback to this-iteration PRE_DEPLOY_SHA" \
  || nok "T3 fallback" "$LOG_OUT"

# ── T4: marker resolves but is NOT an ancestor of POST_DEPLOY_SHA ────────────
run_block "DIVERGED"
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0) with a diverged marker" || nok "T4 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "pre=$EXPECT_C2 post=$EXPECT_C2" \
  && ok "T4 non-ancestor marker → safe fallback to this-iteration PRE_DEPLOY_SHA" \
  || nok "T4 fallback" "$LOG_OUT"

echo ""
echo "story-delivery daemon-refresh baseline tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
