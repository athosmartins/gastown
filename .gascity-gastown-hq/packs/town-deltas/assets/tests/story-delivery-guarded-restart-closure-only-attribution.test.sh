#!/usr/bin/env bash
# story-delivery-guarded-restart-closure-only-attribution.test.sh —
# regression test for ga-87solq (extracts the real Step 5b block from
# story-delivery.sh, no duplication — same technique as
# story-delivery-guarded-restart-attribution.test.sh and friends).
#
# THE BUG: ga-49fwiw's NEEDS_GUARDED_RESTART_UNATTRIBUTED check intersects
# the CURRENT guarded set with what this bead's own merge reaches — but it
# used the full, combined $REFRESH_GUARDED (own-file-changed AND
# closure-only members alike). wa-flysp later split GUARDED into
# GUARDED_OWN/GUARDED_CLOSURE_ONLY and documented CLOSURE_ONLY as "known
# noise" in REFRESH_ACTION's own text — but never wired that split into the
# attribution check, so a bead whose own delta only ever closure-reaches a
# stuck daemon (touches something the daemon transitively imports, not the
# daemon's own file) could never be exonerated: the intersection was never
# empty, so the delivery stayed held AND the rig-wide baseline marker never
# advanced. Measured live 2026-09-18: the whatsapp_automation baseline froze
# at 8cb99239 for 9h+/51 commits; every one of 8 stories delivered in that
# window (wa-46k9n, wa-h140n, wa-6m0ec, wa-ypn1f, wa-r6kc2, wa-mab20,
# wa-a5wlp, ...) reached a wide, closure-contaminated guarded set — commonly
# via daemons/deploy_deps.json regeneration touching dozens of daemons'
# recorded closures in one commit — and needed manual unblocking.
#
# THE FIX: intersect against REFRESH_GUARDED_OWN (parsed from the new
# GUARDED_OWN= field, falling back to the full REFRESH_GUARDED when that
# field is absent — an older daemon-refresh.sh predating it) instead of the
# full REFRESH_GUARDED. MERGE_OWN_AFFECTED (this bead's own reach) is
# deliberately left unnarrowed — conservative on purpose.
#
# T4 (the repro + fix proof): this bead's own merge reaches new-daemon,
#     which IS in the current wide GUARDED set — but only as a
#     CLOSURE-ONLY member (its own file is untouched; old-daemon is the
#     genuine OWN-file-changed member). Delivery must NOT be held, and the
#     rig-wide baseline marker must advance.
# T5 (control — closure-only AND own, still attributed): new-daemon is in
#     the current wide GUARDED set as an OWN-file-changed member (not just
#     closure-only). Delivery MUST still be held, and the marker must NOT
#     advance — proves the fix does not fire when the overlap is genuinely
#     own-file, i.e. it narrows, it does not disable, the check.
# T6 (control — GUARDED_OWN field absent, older helper): the stub's wide
#     call emits no GUARDED_OWN= line at all. Must fall back to the full
#     REFRESH_GUARDED (byte-for-byte the pre-fix, conservative behavior) —
#     delivery held, marker unchanged — proving the fallback never silently
#     treats "the split is unavailable" as "nothing own-file stuck."

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# -style pipes, and under pipefail an early-exiting reader can SIGPIPE the
# writer mid-write, turning a PASSING assertion into a false FAIL under load
# (measured: 1.9% per assertion at load 45; see ga-uel7sb). The block under
# test still runs WITH pipefail (see run_block), as in production.
set -u

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
#   "closure_only" (T4): narrow probe reaches new-daemon. Wide call's
#     GUARDED is old-daemon + new-daemon, but GUARDED_OWN is old-daemon
#     ONLY — new-daemon is closure-only in the wide sweep too.
#   "own" (T5): same, but GUARDED_OWN includes new-daemon as well — the
#     overlap is genuinely own-file.
#   "no_split" (T6): wide call emits no GUARDED_OWN= line at all.
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
  echo mid > "$REPO/mid.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo new > "$REPO/new.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  # Wide-window baseline starts at C0 (spans an earlier, unrelated merge C1).
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  local wide_own_line=""
  case "$mode" in
    closure_only)     wide_own_line='echo "GUARDED_OWN=com.test.old-daemon"' ;;
    own)              wide_own_line='echo "GUARDED_OWN=com.test.old-daemon com.test.new-daemon"' ;;
    no_split)         wide_own_line='' ;;
    # T7: the field IS present but its VALUE is empty — the whole current
    # GUARDED backlog is closure-only, own-file-wise genuinely clean. This is
    # the "present-but-empty vs absent" distinction the fix's fallback logic
    # exists to get right: must NOT be confused with no_split above (which
    # correctly falls back to the full list) — here the split ran and
    # positively found nothing own-file-stuck, which IS trustworthy.
    all_closure_only) wide_own_line='echo "GUARDED_OWN="' ;;
    *) echo "run_block: unknown mode '$mode'" >&2; exit 1 ;;
  esac

  # Fake daemon-refresh.sh: WIDE (real, non-DRY_RUN) and NARROW (DRY_RUN=1,
  # the Step 5b Path-B fallback probe) outputs are independently controlled.
  # Same technique as story-delivery-guarded-restart-attribution.test.sh —
  # this test is about the RETENTION DECISION, not closure-detection
  # mechanics (already covered by daemon-refresh.test.sh and friends).
  # ga-8i2nds: the hold/release decision is now the bead-scoped freshness
  # re-probe (a second DRY_RUN=1 call whose SENSITIVE_DAEMONS the caller forces
  # to include the reached labels); the overlap with the wide guarded set only
  # decides whether a release may advance the rig-wide marker. T5/T6 are the
  # "new-daemon genuinely needs a guarded restart" controls, so in those modes
  # the re-probe reports it STILL STALE — that is what makes them holds now.
  local reprobe_stale=""
  case "$mode" in
    own|no_split) reprobe_stale="com.test.new-daemon" ;;
  esac
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  if [ -n "$reprobe_stale" ]; then
    case " \$SENSITIVE_DAEMONS " in
      *" $reprobe_stale "*)
        echo "VERDICT=NEEDS_GUARDED_RESTART"
        echo "AFFECTED=com.test.new-daemon"
        echo "AFFECTED_NOT_RUNNING="
        echo "RESTARTED="
        echo "FRESH_FAIL="
        echo "GUARDED=$reprobe_stale"
        echo "GUARDED_OWN=$reprobe_stale"
        echo "REASON=freshness re-probe: still stale"
        echo "ALL_LABELS="
        exit 1 ;;
    esac
  fi
  echo "VERDICT=OK"
  echo "AFFECTED=com.test.new-daemon"
  echo "AFFECTED_NOT_RUNNING="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED="
  echo "REASON=dry-run per-bead probe"
  echo "ALL_LABELS="
  exit 0
else
  echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=com.test.old-daemon com.test.new-daemon"
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=com.test.old-daemon com.test.new-daemon"
  $wide_own_line
  echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
  echo "ALL_LABELS=com.test.old-daemon com.test.new-daemon"
  exit 1
fi
EOF

  # Not `local` — assertions after run_block returns need these.
  EXPECT_C0="$SHA_C0"; EXPECT_C2="$SHA_C2"

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
  # True no-op pull: something else already advanced HEAD to this story's
  # own tip before PRE_DEPLOY_SHA was captured (ga-gokm6) — the narrow
  # per-bead fallback probe fires (Path B), same setup the ga-49fwiw test
  # uses for its own T1/T2.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo ""; }

  ( set -o pipefail; for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  BASELINE_AFTER="$(cat "$BASELINE_FILE_ABS" 2>/dev/null || echo "<missing>")"
  rm -rf "$T"
}

# ── T4 (mode=closure_only): the fix's core repro — this bead's own merge
#    reaches new-daemon, which is guarded but ONLY as closure-only ────────
run_block closure_only
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0)" || nok "T4 rc" "rc=$RUN_RC log=[$LOG_OUT]"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && nok "T4 delivery WAS held for a closure-only-only overlap — the bug this fix closes" "$BD_CALLS" \
  || ok "T4 delivery is NOT held (closure-only overlap correctly exonerated)"
echo "$BD_CALLS" | grep "Delivery HALTED" >/dev/null \
  && nok "T4 a HALT comment was wrongly posted" "$BD_CALLS" \
  || ok "T4 no HALT comment posted"
echo "$GC_CALLS" | grep "session nudge mayor" >/dev/null \
  && ok "T4 mayor is still nudged — invariant (b): the gap stays visible/charged" \
  || nok "T4 missing mayor nudge" "$GC_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T4 rig-wide baseline marker ADVANCED to POST_DEPLOY_SHA" \
  || nok "T4 baseline marker did not advance" "want=$EXPECT_C2 got=$BASELINE_AFTER"

# ── T5 (mode=own): control — new-daemon's overlap IS own-file-changed →
#    must still hold, exactly as before this fix ──────────────────────────
run_block own
[ "$RUN_RC" -eq 0 ] && ok "T5 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T5 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T5 delivery IS held (delivery:failed set) — genuine own-file overlap correctly blocks" \
  || nok "T5 delivery was wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep "Delivery HALTED" >/dev/null \
  && ok "T5 HALT comment posted" \
  || nok "T5 missing HALT comment" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T5 rig-wide baseline marker did NOT advance — fix correctly did not fire" \
  || nok "T5 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T6 (mode=no_split): control — GUARDED_OWN absent (older helper) → must
#    fall back to the full combined list, unchanged conservative behavior ─
run_block no_split
[ "$RUN_RC" -eq 0 ] && ok "T6 block runs clean (rc=0)" || nok "T6 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T6 delivery IS held (no split available — safe fallback to full GUARDED)" \
  || nok "T6 delivery was wrongly NOT held when the split field is absent" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T6 rig-wide baseline marker did NOT advance" \
  || nok "T6 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T7 (mode=all_closure_only): GUARDED_OWN present but EMPTY — the whole
#    current backlog is closure-only, positively confirmed clean of any
#    own-file-changed member. Must exonerate + advance, same as T4, proving
#    "present-but-empty" is trusted and NOT confused with "absent" (T6) ────
run_block all_closure_only
[ "$RUN_RC" -eq 0 ] && ok "T7 block runs clean (rc=0)" || nok "T7 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && nok "T7 delivery WAS held even though GUARDED_OWN was positively empty" "$BD_CALLS" \
  || ok "T7 delivery is NOT held (GUARDED_OWN empty-but-present correctly trusted)"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T7 rig-wide baseline marker ADVANCED to POST_DEPLOY_SHA" \
  || nok "T7 baseline marker did not advance" "want=$EXPECT_C2 got=$BASELINE_AFTER"

echo ""
echo "story-delivery guarded-restart closure-only attribution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
