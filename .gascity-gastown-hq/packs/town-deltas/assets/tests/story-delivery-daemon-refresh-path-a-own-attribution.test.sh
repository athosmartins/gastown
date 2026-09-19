#!/usr/bin/env bash
# story-delivery-daemon-refresh-path-a-own-attribution.test.sh — regression
# test for ga-ndu4ic (extracts the real Step 5b block from story-delivery.sh,
# no duplication — same technique as story-delivery-step5b.test.sh and the
# other story-delivery-daemon-refresh-*.test.sh files).
#
# THE BUG (measured live, 2026-09-18 22:0x, wa-vbsm5.1): story-delivery.sh
# only ran the accurate per-story attribution probe (MERGE_PRE_MAIN..
# MERGE_SHA — exactly this story's own commits, however many, regardless of
# what else got pulled alongside them) as an `elif` off Path B (PRE_DEPLOY_SHA
# ==POST_DEPLOY_SHA, a true no-op pull). On Path A (this iteration's own pull
# actually moved HEAD — the common case, since usually THIS story's own pull
# is what fetches its own merge) that probe never ran at all, so
# MERGE_OWN_AFFECTED stayed empty and the halt fell back to the wide-list-
# only, unattributed wording — blaming the reporting story for every daemon
# ANY delivery had left stuck since the rig-wide baseline last advanced.
#
# Real incident: wa-vbsm5.1's own commits (91bb5453c, d5383b04b) touched only
# demand_dashboard.py/.html and friends. The rig's daemon-refresh baseline had
# been frozen for 18 commits, during which OTHER deliveries changed
# ficha360_app.py and map_viewer_dashboard.py's own template. The halt named
# all THREE as "OWN-FILE-CHANGED... restart THESE first" with nothing
# distinguishing wa-vbsm5.1's real contribution (demand-dashboard alone) from
# the other two deliveries' unresolved staleness — exactly the ambiguity this
# test pins down.
#
# THE FIX: story-delivery.sh now runs the MERGE_PRE_MAIN..MERGE_SHA probe
# unconditionally (an `if`, not an `elif` off the Path-A pattern-check block)
# whenever MERGE_SHA/MERGE_PRE_MAIN resolve validly — on Path A exactly as on
# Path B. This test reproduces wa-vbsm5.1's exact shape via Path A (a single
# pull cycle that picks up both an EARLIER, unrelated story's commit and THIS
# story's own commit in one go — routine in this city).
#
# T1 (the repro + fix proof): baseline is old (C0). An EARLIER, unrelated
#     story's commit (C1) changed ficha360 + map-viewer's own files. THIS
#     story's own commit (C2) changed only demand-dashboard's own file. One
#     pull cycle fetches both (PRE_DEPLOY_SHA=C0 != POST_DEPLOY_SHA=C2 —
#     Path A). The wide (real) call sees the whole C0..C2 window and flags
#     all three as OWN-FILE-CHANGED/GUARDED. The narrow (DRY_RUN=1) probe,
#     scoped to this story's own C1..C2 delta, must see demand-dashboard
#     only. Asserts: delivery IS held (demand-dashboard genuinely still
#     needs a guarded restart — a real, unresolved fact), but the halt's
#     LEADING attribution names demand-dashboard alone, with ficha360 and
#     map-viewer demoted to "Context only — NOT attributed to this merge".
# T2 (control — non-regression, Aceite #2): a story whose own commit changes
#     a daemon's own file while that SAME daemon is still running old code
#     (i.e. this story's own daemon really is stuck) continues to be held
#     for it — unchanged by this fix; T1 already proves this for
#     demand-dashboard, T2 isolates it with no unrelated daemons in the
#     window at all.

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

# run_block <mode>
#   "three_daemon" (T1): baseline=C0. C1 = an EARLIER, unrelated story's own
#     commit (ficha360 + map-viewer's own files). C2 = THIS story's own
#     commit (demand-dashboard's own file only). PRE_DEPLOY_SHA=C0 (this
#     iteration's pull fetches BOTH C1 and C2 in one go) != POST_DEPLOY_SHA=C2
#     — Path A. MERGE_PRE_MAIN=C1, MERGE_SHA=C2 (this story's own range).
#   "own_only" (T2): baseline=C1 (== MERGE_PRE_MAIN). No unrelated commit in
#     the window at all — the wide window IS this story's own delta.
run_block() {
  local mode="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo ficha > "$REPO/ficha360.txt"; echo mapv > "$REPO/map_viewer.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo demand > "$REPO/demand_dashboard.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  case "$mode" in
    three_daemon) BASELINE_SHA="$SHA_C0" ;;
    own_only)     BASELINE_SHA="$SHA_C1" ;;
    *) echo "run_block: unknown mode '$mode'" >&2; exit 1 ;;
  esac
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$BASELINE_SHA" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  # Fake daemon-refresh.sh: classifies whatever [PRE,POST] range it's asked
  # about by actually diffing it, naming a daemon per changed file — so the
  # wide (real, whole baseline..HEAD) and narrow (DRY_RUN=1, this story's own
  # MERGE_PRE_MAIN..MERGE_SHA) calls genuinely disagree the way the real
  # incident did, driven purely by which commits each range spans.
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null)"
NAMES=""
echo "$CHANGED" | grep -q "ficha360\.txt"        && NAMES="$NAMES com.whatsapp.ficha360"
echo "$CHANGED" | grep -q "map_viewer\.txt"       && NAMES="$NAMES com.whatsapp.map-viewer"
echo "$CHANGED" | grep -q "demand_dashboard\.txt" && NAMES="$NAMES com.whatsapp.demand-dashboard"
NAMES="${NAMES# }"
if [ -n "$NAMES" ]; then
  echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=$NAMES"
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=$NAMES"
  echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
  exit 1
else
  echo "VERDICT=OK"
  echo "AFFECTED="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED="
  echo "REASON=no daemon imports the changed files"
  exit 0
fi
EOF

  EXPECT_C0="$SHA_C0"; EXPECT_C1="$SHA_C1"; EXPECT_C2="$SHA_C2"

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  local PRE_DEPLOY_SHA POST_DEPLOY_SHA MERGE_SHA MERGE_REF MERGE_PRE_MAIN
  case "$mode" in
    three_daemon)
      # Path A: this iteration's own pull moved HEAD, fetching BOTH the
      # earlier unrelated commit (C1) and this story's own commit (C2) in
      # one cycle — routine in this city (~90 commits/day).
      PRE_DEPLOY_SHA="$SHA_C0"; POST_DEPLOY_SHA="$SHA_C2"
      MERGE_SHA="$SHA_C2"; MERGE_REF="origin/main"; MERGE_PRE_MAIN="$SHA_C1"
      ;;
    own_only)
      PRE_DEPLOY_SHA="$SHA_C1"; POST_DEPLOY_SHA="$SHA_C2"
      MERGE_SHA="$SHA_C2"; MERGE_REF="origin/main"; MERGE_PRE_MAIN="$SHA_C1"
      ;;
  esac
  get_runbook_field() { echo ""; }

  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  BASELINE_AFTER="$(cat "$BASELINE_FILE_ABS" 2>/dev/null || echo "<missing>")"
  rm -rf "$T"
}

# ── T1 (mode=three_daemon): the wa-vbsm5.1 repro — wide window carries 3
#    daemons, this story's own delta reaches only demand-dashboard ────────
run_block three_daemon
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0)" || nok "T1 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T1 own-merge probe classified NOT inert (demand-dashboard is a real hit)" \
  || nok "T1 inert classification" "$LOG_OUT"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T1 delivery IS held — demand-dashboard genuinely still needs a guarded restart" \
  || nok "T1 delivery was wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "restart THESE for this merge" \
  && ok "T1 halt leads with the per-bead attribution phrase (Aceite: OWN computed from this story's own commits)" \
  || nok "T1 missing lead-with phrase — Path A attribution did not engage" "$BD_CALLS"
LEAD_PART="$(echo "$BD_CALLS" | awk '/Context only/{exit} {print}')"
echo "$LEAD_PART" | grep -q "com.whatsapp.demand-dashboard" \
  && ok "T1 leading action names demand-dashboard (this story's real, own daemon)" \
  || nok "T1 lead missing demand-dashboard" "$LEAD_PART"
echo "$LEAD_PART" | grep -q "com.whatsapp.ficha360" \
  && nok "T1 Aceite VIOLATED: leading action wrongly names ficha360 (not this story's fault)" "$LEAD_PART" \
  || ok "T1 Aceite: leading action does NOT name ficha360"
echo "$LEAD_PART" | grep -q "com.whatsapp.map-viewer" \
  && nok "T1 Aceite VIOLATED: leading action wrongly names map-viewer (not this story's fault)" "$LEAD_PART" \
  || ok "T1 Aceite: leading action does NOT name map-viewer"
echo "$BD_CALLS" | grep -q "Context only — NOT attributed to this merge" \
  && ok "T1 wide list demoted to an explicitly-marked context line" \
  || nok "T1 missing context-demotion marker" "$BD_CALLS"
CONTEXT_LINE="$(echo "$BD_CALLS" | grep "Context only — NOT attributed to this merge")"
echo "$CONTEXT_LINE" | grep -q "com.whatsapp.ficha360" \
  && ok "T1 ficha360 reported as context (pending from another delivery), not blamed on this story" \
  || nok "T1 ficha360 missing entirely from context line" "$CONTEXT_LINE"
echo "$CONTEXT_LINE" | grep -q "com.whatsapp.map-viewer" \
  && ok "T1 map-viewer reported as context (pending from another delivery), not blamed on this story" \
  || nok "T1 map-viewer missing entirely from context line" "$CONTEXT_LINE"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T1 rig-wide baseline marker did NOT advance (demand-dashboard's real hold is unresolved)" \
  || nok "T1 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T2 (mode=own_only): control (Aceite #2, non-regression) — no unrelated
#    daemon in the window at all, this story's own daemon is the whole
#    story → still correctly held for it ──────────────────────────────────
run_block own_only
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0)" || nok "T2 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T2 delivery IS held (own-file-changed daemon still running old code)" \
  || nok "T2 delivery was wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "restart THESE for this merge" \
  && ok "T2 halt leads with the per-bead attribution phrase" \
  || nok "T2 missing lead-with phrase" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "com.whatsapp.demand-dashboard" \
  && ok "T2 halt names demand-dashboard" \
  || nok "T2 halt missing demand-dashboard" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C1" ] \
  && ok "T2 rig-wide baseline marker did NOT advance" \
  || nok "T2 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C1 got=$BASELINE_AFTER"

echo ""
echo "story-delivery Path-A own-attribution (ga-ndu4ic) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
