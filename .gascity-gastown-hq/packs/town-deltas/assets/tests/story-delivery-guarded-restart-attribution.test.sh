#!/usr/bin/env bash
# story-delivery-guarded-restart-attribution.test.sh — regression test for
# ga-49fwiw (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh and the
# other story-delivery-daemon-refresh-*.test.sh files).
#
# THE BUG: ga-xz3ypu taught the gate not to blame a bead for a plist some
# OTHER bead broke (JOB_NOT_INSTALLED). The SAME gap remained for
# NEEDS_GUARDED_RESTART: the retention decision used THIS_PULL_STRUCTURALLY_
# INERT alone, which only answers "does this bead's own merge reach ANY live
# daemon" — not "is any daemon it reaches among the ones CURRENTLY still
# stuck in the wide-window GUARDED list". wa-a7tca reached exactly one live
# daemon (com.whatsapp.demand-dashboard, already restarted+verified 9min
# post-merge) while 52 OTHER sensitive daemons sat stuck in the wide window
# for unrelated reasons (no drain path, nobody restarts them every deploy).
# THIS_PULL_STRUCTURALLY_INERT="0" (it DOES reach a live daemon) held the
# whole delivery for ~6h on their account regardless.
#
# THE FIX: story-delivery.sh now intersects the CURRENT guarded set
# ($REFRESH_GUARDED) with what this bead's own merge actually reaches
# ($MERGE_OWN_AFFECTED, already computed above for the halt-message split
# ga-9lug2k added) — an empty intersection means none of the currently-stuck
# daemons belong to this bead, so the delivery is NOT held. This also
# advances the rig-wide daemon-refresh baseline marker in that case (unlike
# the pre-existing ga-3bdttu inert branch, which deliberately does not) —
# safe because any daemon still genuinely stuck keeps its own per-daemon
# override baseline frozen regardless (ga-0fawwr, unconditional, unaffected
# by this branch) — closing the self-feeding "verdict never OK -> marker
# never advances -> window widens -> more daemons match -> verdict never OK"
# loop this bug's own root-cause section describes.
#
# T1 (the repro + fix proof): this bead's own merge reaches ONE live daemon
#     (new-daemon), which is NOT in the current wide GUARDED set (only an
#     unrelated old-daemon is stuck). Delivery must NOT be held (no
#     delivery:failed, no "Delivery HALTED" comment), the mayor must still be
#     nudged (invariant b: the gap stays visible/charged), and the rig-wide
#     baseline marker must advance to POST_DEPLOY_SHA (invariant c).
# T2 (control — still attributed, unchanged behavior): this bead's own merge
#     reaches a live daemon (new-daemon) that IS in the current wide GUARDED
#     set alongside an unrelated old-daemon. Delivery MUST still be held
#     (delivery:failed + HALT comment), and the rig-wide baseline marker must
#     NOT advance — proves the new branch does not fire when attribution is
#     real, and that the pre-existing hold path is untouched.
# T3 (ga-ndu4ic UPDATE, 2026-09-19 — was "control: no attribution data
#     available, Path A"; that is no longer true, see below) / T4 (new):
#     ga-ndu4ic taught this same probe to run UNCONDITIONALLY (an `if`, not
#     an `elif` off the Path-A pattern-check block) instead of only on Path B
#     (PRE_DEPLOY_SHA==POST_DEPLOY_SHA, a true no-op pull) — real deliveries
#     usually take Path A (this iteration's own pull is what fetches the
#     story's own merge), so gating the accurate probe to Path B alone meant
#     it silently never engaged for the common case. Confirmed live:
#     wa-vbsm5.1 (2026-09-18) reached only demand-dashboard, yet the halt
#     blamed it for two OTHER deliveries' own daemons (ficha360, map-viewer)
#     that merely shared its wide baseline..HEAD window — see
#     story-delivery-daemon-refresh-path-a-own-attribution.test.sh for the
#     dedicated repro of that exact shape. T3 and T4 below now mirror T2 and
#     T1 respectively, just reached via Path A instead of Path B — proving
#     the two paths behave identically now that both run the same probe.
# T3 (mode=path_a, attributed — mirrors T2): this bead's own merge reaches a
#     live daemon (new-daemon) that IS in the current wide GUARDED set. Must
#     still be held (delivery:failed + HALT comment, leading with the
#     per-bead attribution), and the baseline marker must NOT advance.
# T4 (mode=path_a, unattributed — mirrors T1): this bead's own merge reaches
#     ONE live daemon (new-daemon) NOT in the current wide GUARDED set (only
#     an unrelated old-daemon is stuck). Delivery must NOT be held, mayor
#     still nudged, baseline marker must advance.

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
#   "unattributed" (T1): true no-op pull. Narrow probe (DRY_RUN=1) reaches
#     new-daemon only. Wide/real call's GUARDED is old-daemon ONLY — new-
#     daemon is NOT currently stuck (already resolved).
#   "attributed" (T2): same narrow result, but wide/real call's GUARDED
#     names BOTH old-daemon AND new-daemon — new-daemon genuinely still
#     needs a guarded restart.
#   "path_a_attributed" (T3): same as "attributed", but reached via a real
#     pull (PRE_DEPLOY_SHA != POST_DEPLOY_SHA) instead of a no-op — proves
#     the probe now also runs, and still correctly holds, on Path A.
#   "path_a_unattributed" (T4): same as "unattributed", but reached via a
#     real pull instead of a no-op — proves the probe now also runs, and
#     still correctly exonerates, on Path A.
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

  # Fake daemon-refresh.sh: WIDE (real, non-DRY_RUN) and NARROW (DRY_RUN=1,
  # the Step 5b Path-B fallback probe) outputs are independently controlled
  # by env vars, so the two can be made to (dis)agree exactly as needed —
  # this test is about the RETENTION DECISION (a pure function of
  # REFRESH_VERDICT + REFRESH_GUARDED + MERGE_OWN_AFFECTED +
  # THIS_PULL_STRUCTURALLY_INERT), not the import/template-closure detection
  # mechanics (already covered by daemon-refresh.test.sh and friends).
  # ga-8i2nds: the hold/release decision is now the bead-scoped freshness
  # re-probe (a second DRY_RUN=1 call whose SENSITIVE_DAEMONS the caller forces
  # to include the reached labels), not the overlap with the wide guarded set —
  # the overlap alone no longer holds anything. So "genuinely still needs a
  # guarded restart" (the premise of the attributed modes, T2/T3) has to be
  # expressed where the decision now reads it: the re-probe reports new-daemon
  # STILL STALE in those modes, and fresh (the plain default below) otherwise.
  STUB_REPROBE_STALE=""
  case "$mode" in
    attributed|path_a_attributed) STUB_REPROBE_STALE="com.test.new-daemon" ;;
  esac
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  if [ -n "$STUB_REPROBE_STALE" ]; then
    case " \$SENSITIVE_DAEMONS " in
      *" $STUB_REPROBE_STALE "*)
        echo "VERDICT=NEEDS_GUARDED_RESTART"
        echo "AFFECTED=$STUB_NARROW_AFFECTED"
        echo "AFFECTED_NOT_RUNNING="
        echo "RESTARTED="
        echo "FRESH_FAIL="
        echo "GUARDED=$STUB_REPROBE_STALE"
        echo "GUARDED_OWN=$STUB_REPROBE_STALE"
        echo "REASON=freshness re-probe: still stale"
        echo "ALL_LABELS="
        exit 1 ;;
    esac
  fi
  echo "VERDICT=OK"
  echo "AFFECTED=$STUB_NARROW_AFFECTED"
  echo "AFFECTED_NOT_RUNNING="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED="
  echo "REASON=dry-run per-bead probe"
  echo "ALL_LABELS="
  exit 0
else
  if [ -n "$STUB_WIDE_GUARDED" ]; then
    echo "VERDICT=NEEDS_GUARDED_RESTART"
    echo "AFFECTED=$STUB_WIDE_GUARDED"
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED=$STUB_WIDE_GUARDED"
    echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
    echo "ALL_LABELS=$STUB_WIDE_GUARDED"
    exit 1
  else
    echo "VERDICT=OK"
    echo "AFFECTED="
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED="
    echo "REASON=nothing stale"
    echo "ALL_LABELS="
    exit 0
  fi
fi
EOF

  # Not `local` — assertions after run_block returns need these (same
  # pattern the ga-xz3ypu test uses: EXPECT_* survives the function return).
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
  local PRE_DEPLOY_SHA POST_DEPLOY_SHA MERGE_SHA MERGE_REF MERGE_PRE_MAIN
  case "$mode" in
    unattributed|attributed)
      # True no-op pull: something else already advanced HEAD to this
      # story's own tip before PRE_DEPLOY_SHA was captured (ga-gokm6) — the
      # narrow per-bead fallback probe fires.
      PRE_DEPLOY_SHA="$SHA_C2"; POST_DEPLOY_SHA="$SHA_C2"
      MERGE_SHA="$SHA_C2"; MERGE_REF="origin/main"; MERGE_PRE_MAIN="$SHA_C1"
      ;;
    path_a_attributed|path_a_unattributed)
      # A real pull happened this iteration (PRE_DEPLOY_SHA=C0 !=
      # POST_DEPLOY_SHA=C2) — ga-ndu4ic: the probe now runs here too, using
      # the same MERGE_PRE_MAIN=C1..MERGE_SHA=C2 story-own range as the
      # no-op modes above.
      PRE_DEPLOY_SHA="$SHA_C0"; POST_DEPLOY_SHA="$SHA_C2"
      MERGE_SHA="$SHA_C2"; MERGE_REF="origin/main"; MERGE_PRE_MAIN="$SHA_C1"
      ;;
    *)
      echo "run_block: unknown mode '$mode'" >&2; exit 1 ;;
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

# ── T1 (mode=unattributed): the fix's core repro — this bead reaches
#    new-daemon, but the CURRENT guarded set is old-daemon only ────────────
STUB_NARROW_AFFECTED="com.test.new-daemon"
STUB_WIDE_GUARDED="com.test.old-daemon"
run_block unattributed
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0)" || nok "T1 rc" "rc=$RUN_RC log=[$LOG_OUT]"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T1 own-merge probe classified NOT inert (new-daemon is a real hit)" \
  || nok "T1 inert classification" "$LOG_OUT"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && nok "T1 delivery WAS held (delivery:failed set) — the bug this fix closes" "$BD_CALLS" \
  || ok "T1 delivery is NOT held (no delivery:failed) — the fix"
echo "$BD_CALLS" | grep -q "Delivery HALTED" \
  && nok "T1 a HALT comment was wrongly posted for an unattributed daemon" "$BD_CALLS" \
  || ok "T1 no HALT comment posted (nothing to blame this bead for)"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T1 mayor is still nudged — invariant (b): the gap stays visible/charged" \
  || nok "T1 missing mayor nudge (invariant b violated — the unattributed gap went silent)" "$GC_CALLS"
echo "$GC_CALLS" | grep -q "com.test.old-daemon" \
  && ok "T1 mayor nudge names the actually-stuck daemon (old-daemon)" \
  || nok "T1 mayor nudge does not name old-daemon" "$GC_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T1 rig-wide baseline marker ADVANCED to POST_DEPLOY_SHA — invariant (c), closes the self-feeding window-growth loop" \
  || nok "T1 baseline marker did not advance" "want=$EXPECT_C2 got=$BASELINE_AFTER"

# ── T2 (mode=attributed): control — new-daemon IS still in the current
#    guarded set → must still hold, exactly as before this fix ────────────
STUB_NARROW_AFFECTED="com.test.new-daemon"
STUB_WIDE_GUARDED="com.test.old-daemon com.test.new-daemon"
run_block attributed
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T2 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T2 own-merge probe classified NOT inert" \
  || nok "T2 inert classification" "$LOG_OUT"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T2 delivery IS held (delivery:failed set) — still-attributed daemon correctly blocks" \
  || nok "T2 delivery was wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "Delivery HALTED" \
  && ok "T2 HALT comment posted" \
  || nok "T2 missing HALT comment" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "restart THESE for this merge" \
  && ok "T2 halt still leads with the per-bead attribution phrase (ga-9lug2k, untouched by this fix)" \
  || nok "T2 missing lead-with phrase" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T2 rig-wide baseline marker did NOT advance (stayed at pre-existing value) — new branch correctly did not fire" \
  || nok "T2 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T3 (mode=path_a_attributed, ga-ndu4ic) — mirrors T2 via Path A: new-
#    daemon IS still in the current guarded set → must still hold ────────
STUB_NARROW_AFFECTED="com.test.new-daemon"
STUB_WIDE_GUARDED="com.test.old-daemon com.test.new-daemon"
run_block path_a_attributed
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0)" || nok "T3 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T3 own-merge probe classified NOT inert (via the probe, on Path A too)" \
  || nok "T3 inert classification" "$LOG_OUT"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T3 delivery IS held (delivery:failed set) — still-attributed daemon correctly blocks" \
  || nok "T3 delivery was wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "restart THESE for this merge" \
  && ok "T3 halt now leads with the per-bead attribution phrase on Path A too (ga-ndu4ic — this used to be unavailable here)" \
  || nok "T3 missing lead-with phrase — Path A attribution regressed" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T3 rig-wide baseline marker did NOT advance (still-attributed hold correctly does not advance it)" \
  || nok "T3 baseline marker unexpectedly changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T4 (mode=path_a_unattributed, ga-ndu4ic) — mirrors T1 via Path A: new-
#    daemon reaches a live daemon NOT in the current wide GUARDED set (only
#    unrelated old-daemon is stuck) → must NOT be held, baseline advances ──
STUB_NARROW_AFFECTED="com.test.new-daemon"
STUB_WIDE_GUARDED="com.test.old-daemon"
run_block path_a_unattributed
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0)" || nok "T4 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T4 own-merge probe classified NOT inert (new-daemon is a real hit)" \
  || nok "T4 inert classification" "$LOG_OUT"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && nok "T4 delivery WAS held (delivery:failed set) — Path A did not get the same exoneration as Path B (T1)" "$BD_CALLS" \
  || ok "T4 delivery is NOT held (no delivery:failed) — Path A now exonerates exactly like Path B (T1)"
echo "$BD_CALLS" | grep -q "Delivery HALTED" \
  && nok "T4 a HALT comment was wrongly posted for an unattributed daemon" "$BD_CALLS" \
  || ok "T4 no HALT comment posted (nothing to blame this bead for)"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T4 mayor is still nudged — invariant (b): the gap stays visible/charged" \
  || nok "T4 missing mayor nudge (invariant b violated)" "$GC_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T4 rig-wide baseline marker ADVANCED to POST_DEPLOY_SHA on Path A too (ga-ndu4ic, closes the Aceite-3 loop)" \
  || nok "T4 baseline marker did not advance" "want=$EXPECT_C2 got=$BASELINE_AFTER"

echo ""
echo "story-delivery guarded-restart attribution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
