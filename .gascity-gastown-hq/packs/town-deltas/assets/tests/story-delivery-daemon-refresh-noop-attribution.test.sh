#!/usr/bin/env bash
# story-delivery-daemon-refresh-noop-attribution.test.sh — regression test for
# ga-6zkhci (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh and
# story-delivery-daemon-refresh-attribution.test.sh).
#
# THE BUG: ga-3bdttu (story-delivery-daemon-refresh-attribution.test.sh) taught
# Step 5b to stop blaming a story for daemon staleness its own merge did not
# cause — but only when PRE_DEPLOY_SHA != POST_DEPLOY_SHA. In this rig, the
# story-delivery pull is USUALLY a true no-op (something else — a sibling
# story's delivery earlier in the same sweep — already advanced RUNTIME_DIR's
# HEAD past this story's own commit before PRE_DEPLOY_SHA was captured), so
# PRE_DEPLOY_SHA==POST_DEPLOY_SHA and THIS_PULL_STRUCTURALLY_INERT was left
# unset — the ga-3bdttu exemption never even ran. Confirmed live
# (story-delivery.log 2026-09-14): wa-ibaqq (own merge touches only
# docs/mockups/*.html) and wa-mjpjs (own merge touches only scripts/lib files
# no live daemon imports) were both held with delivery:failed +
# delivery:deploy-pending for a demand-dashboard-class staleness neither one
# caused.
#
# THE FIX: when PRE_DEPLOY_SHA==POST_DEPLOY_SHA, derive this story's own delta
# from MERGE_SHA (the gate-verified commit already proven an ancestor of
# MERGE_REF) instead of the pull range, and ask daemon-refresh.sh itself
# (DRY_RUN=1 — never a real kickstart/drain) whether that delta alone reaches
# any live daemon — reusing the same import/template-closure discovery Step 3
# already trusts for the wide window, rather than a second static heuristic
# that could never recognize a case like wa-mjpjs's scripts/*.py.
#
# T1: no-op pull, own merge (MERGE_SHA) touches only docs/*.html → the
#     merge-sha-fallback probe returns OK → NOT blamed (repro wa-ibaqq).
# T2: no-op pull, own merge touches a file matching NEITHER the tests/docs/md
#     pattern NOR any live daemon's import graph (simulated: the fake
#     daemon-refresh.sh only flags paths containing "sensitive") → the probe
#     still returns OK (real reachability, not a path pattern) → NOT blamed
#     (repro wa-mjpjs).
# T3: control — no-op pull, own merge touches a file the fake daemon-refresh.sh
#     DOES treat as reaching a live (simulated sensitive) daemon → the probe
#     returns NEEDS_GUARDED_RESTART → still blamed exactly as before (proves
#     the fallback doesn't blindly exempt every no-op pull).
# T4: no-op pull, but MERGE_SHA has no resolvable parent in RUNTIME_DIR (never
#     fetched) → the fallback condition itself fails closed → inert stays
#     unknown → existing blame behavior (ga-3bdttu's own T3 already covers
#     "no MERGE_SHA at all"; this covers "MERGE_SHA present but unusable").

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

# run_block <own-file-shape> <seed-merge-sha-with-no-parent(0/1)>
# Builds a real 3-commit git fixture in a fresh RUNTIME_DIR:
#   C0 (base) -> C1 (adds lib/sensitive_daemon_dep.py, a PRE-EXISTING file a
#     live daemon imports — simulates the real, earlier cause of staleness)
#   -> C2 (THIS story's own merge; its file depends on own_file_shape:
#     "docs"      -> docs/mockup.html               (T1, wa-ibaqq shape)
#     "harmless"  -> scripts/cron_only.py            (T2, wa-mjpjs shape)
#     "sensitive" -> lib/sensitive_daemon_dep2.py    (T3 control)
# The fake daemon-refresh.sh classifies ANY range it is asked about by
# actually diffing PRE..POST itself and flagging NEEDS_GUARDED_RESTART only
# when a path containing "sensitive" is in that range — so the WIDE call
# (baseline C0 .. POST) always sees C1's sensitive file and returns
# NEEDS_GUARDED_RESTART (a real, persistent staleness exists), while the
# NARROW merge-sha-fallback call (C1..C2) sees only C2's own file, giving a
# DIFFERENT, shape-dependent answer — exactly like a real per-daemon
# reachability check would.
run_block() {
  local own_file_shape="$1" no_parent="${2:-0}"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/lib" "$REPO/docs/mockups" "$REPO/scripts"
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo prod > "$REPO/lib/sensitive_daemon_dep.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  case "$own_file_shape" in
    docs)      echo mock > "$REPO/docs/mockups/foo.html" ;;
    harmless)  echo cron > "$REPO/scripts/cron_only.py" ;;
    sensitive) echo prod2 > "$REPO/lib/sensitive_daemon_dep2.py" ;;
  esac
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  # Widen the wide-window baseline to C0 so it spans C1's sensitive file —
  # simulates a real, unresolved staleness that predates this story.
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"

  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null)"
case "$CHANGED" in
  *sensitive*)
    echo "VERDICT=NEEDS_GUARDED_RESTART"
    echo "AFFECTED=com.test.central-sender"
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED=com.test.central-sender"
    echo "REASON=sensitive hot-path daemon needs a guarded restart"
    exit 1
    ;;
  *)
    echo "VERDICT=OK"
    echo "AFFECTED="
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED="
    echo "REASON=no daemon imports the changed files"
    exit 0
    ;;
esac
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
  # True no-op pull (ga-gokm6's own scenario): PRE==POST==C2, exactly like a
  # sibling story's delivery already advancing HEAD before this iteration's
  # own PRE_DEPLOY_SHA capture.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # MERGE_SHA is what Step 3 (pre-deploy merge verification, earlier in the
  # real script) would have set from the gate's merge comment — always C2
  # (this story's own commit) unless this run is testing the "no resolvable
  # parent" fallback-of-the-fallback (T4).
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main"
  if [ "$no_parent" = "1" ]; then
    # Simulate MERGE_SHA pointing somewhere this RUNTIME_DIR cannot resolve a
    # parent for (never fetched) — 40 hex chars, syntactically a sha, but not
    # an object this repo has.
    MERGE_SHA="0000000000000000000000000000000000000000"
  fi
  get_runbook_field() { echo "central-sender"; }

  rm -f "$T/reached.marker"
  ( for _t in _once; do eval "$BLOCK"; touch "$T/reached.marker"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  [ -f "$T/reached.marker" ] && REACHED=1 || REACHED=0
  rm -rf "$T"
}

# ── T1: no-op pull, own merge is docs-only → NOT blamed (repro wa-ibaqq) ─────
run_block docs
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0)" || nok "T1 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=1" \
  && ok "T1 own-merge-only probe classified inert (docs-only)" \
  || nok "T1 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 1 ] && ok "T1 block falls through past the verdict (no continue) — delivery proceeds" \
  || nok "T1 fell through" "REACHED=$REACHED"
! echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T1 delivery:failed NOT added — innocent story not blamed" \
  || nok "T1 no failed-label" "$BD_CALLS"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T1 Mayor still nudged — real staleness (C1) not silenced" \
  || nok "T1 mayor nudged" "$GC_CALLS"

# ── T2: no-op pull, own merge touches a file no live daemon reaches (not a
#        tests/docs/md path either) → NOT blamed (repro wa-mjpjs) ───────────
run_block harmless
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0)" || nok "T2 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=1" \
  && ok "T2 own-merge-only probe classified inert (harmless script, real reachability not a path pattern)" \
  || nok "T2 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 1 ] && ok "T2 block falls through past the verdict — delivery proceeds" \
  || nok "T2 fell through" "REACHED=$REACHED"
! echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T2 delivery:failed NOT added — innocent story not blamed" \
  || nok "T2 no failed-label" "$BD_CALLS"

# ── T3: control — no-op pull, own merge DOES reach a (simulated) live
#        sensitive daemon → still blamed ────────────────────────────────────
run_block sensitive
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T3 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T3 own-merge-only probe classified NOT inert (control)" \
  || nok "T3 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T3 block halts via continue (does not fall through)" \
  || nok "T3 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep -q "label add ga-test delivery:failed" \
  && ok "T3 delivery:failed added — this story's own merge IS the cause" \
  || nok "T3 failed-label" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "label add ga-test delivery:deploy-pending" \
  && ok "T3 delivery:deploy-pending added" \
  || nok "T3 deploy-pending" "$BD_CALLS"

# ── T4: MERGE_SHA present but its parent is not resolvable in RUNTIME_DIR
#        (never fetched) → fallback condition itself fails closed → unknown
#        → existing blame behavior, never a guessed exemption ─────────────
run_block docs 1
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0)" || nok "T4 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=unknown" \
  && ok "T4 unresolvable MERGE_SHA → inert stays unknown (never guessed)" \
  || nok "T4 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T4 block halts via continue (falls back to existing blame behavior)" \
  || nok "T4 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep -q "label add ga-test delivery:failed" \
  && ok "T4 delivery:failed added — unknown attribution defaults to blame, not exemption" \
  || nok "T4 failed-label" "$BD_CALLS"

echo ""
echo "story-delivery daemon-refresh no-op attribution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
