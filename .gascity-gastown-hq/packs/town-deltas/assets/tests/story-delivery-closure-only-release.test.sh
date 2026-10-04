#!/usr/bin/env bash
# story-delivery-closure-only-release.test.sh — regression test for ga-65o94h
# (extracts the real Step 5b block from story-delivery.sh, no duplication — same
# technique as story-delivery-human-confirmed-release.test.sh, which this file
# mirrors closely).
#
# THE BUG (04/10, three times in ~3h: wa-l3ff6z, wa-hb6h5b, wa-i0e7rd): a
# daemon that started before the merge and merely has a changed file in its
# import CLOSURE held story:done (DELIVERY HALTED, delivery:deploy-pending),
# until the Mayor traced the call graph by hand and released it (~10-20 min
# each). daemon-refresh.sh had ALREADY classified those daemons — OWN /
# CLOSURE_ONLY / SYMBOL_CONFIRMED / SYMBOL_NO_EVIDENCE / SYMBOL_NOT_COMPUTED —
# but story-delivery only PRINTED those fields in the halt body and never used
# them to decide.
#
# THE FIX: a still-stale daemon is excused (the delivery is NOT held for it,
# and the story proceeds to Step 6 with the reason recorded on the bead) when
# the re-probe named it by POSITIVE membership in BOTH GUARDED_CLOSURE_ONLY and
# GUARDED_SYMBOL_NO_EVIDENCE, and in NEITHER GUARDED_OWN nor
# GUARDED_SYMBOL_CONFIRMED nor GUARDED_SYMBOL_NOT_COMPUTED — and the helper
# printed all of those lines (an absent line is "did not say", never "empty").
# It gets its own proof tier (symbol_unreachable_closure_only) and label
# (delivery:daemon-stale-closure-only): it is not notify_only_locked, so it is
# never folded into symbol_unreachable_locked.
#
# POLICY NOTE: this deliberately supersedes the restraint ga-xrn8ni's T4 used
# to assert (an unlocked SENSITIVE daemon with NO_EVIDENCE and no human label
# stayed held). The Mayor's bead asks for exactly that release, with the
# measurements above. Everything that is not positively "closure-only + no
# symbol evidence" still holds, and the human-attested label (ga-xrn8ni) is
# still the way to excuse a daemon the calculator confirmed or could not
# compute.
#
# R1-R3 REPLAY the three 04/10 cases with the REAL re-probe output and the
# real daemon labels (captured from the halt comments on the beads):
#   R1 wa-i0e7rd — 6 daemons, all NO_EVIDENCE        -> released
#   R2 wa-hb6h5b — demand-dashboard is the real executor (blueprint chain
#      radar.py:/api/radar/criar-card -> create_property_deal): it MUST keep
#      the delivery held; ficha360 (NO_EVIDENCE) is excused, and must not be
#      listed under "restart THESE"
#   R3 wa-l3ff6z — 6 daemons the calculator CONFIRMED -> held, nothing excused
#      (the calculator confirms them only because they instantiate a class that
#      gained an additive method — a false positive in the rig's own
#      compute_symbol_reachability.py, outside this script's remit)
# C1-C8 are the fail-closed controls.

# No `pipefail` at file level (ga-uel7sb) — see the locked-cosmetic test for
# why. The block under test still runs WITH pipefail (see run_block).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# has <haystack> <needle> — literal substring test with NO pipe.
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# Real labels, from the 04/10 halts.
VCARD="com.whatsapp.call-vcard-notifier"
SCHED="com.whatsapp.campaign-scheduler"
CMON="com.whatsapp.conversation-monitor"
DEMAND="com.whatsapp.demand-dashboard"
FICHA="com.whatsapp.ficha360"
FOLLOW="com.whatsapp.followup-handler"
REFER="com.whatsapp.referral-outreach"
CAMPAPI="com.whatsapp.campaign-api"

# Scenario inputs (globals, set by each test before run_block). Each is a
# space-separated label list, exactly as daemon-refresh.sh prints it.
SC_VERDICT="NEEDS_GUARDED_RESTART"
SC_GUARDED=""; SC_OWN=""; SC_CLOSURE=""; SC_CONFIRMED=""; SC_NOEVID=""; SC_NOTCOMP=""; SC_LOCKED=""
SC_OMIT=""            # space-separated KEY names whose line must NOT be printed at all
SC_STORY_LABELS=""    # extra STORY_LABELS entries (comma-joined, no leading comma)

reset_scenario() {
  SC_VERDICT="NEEDS_GUARDED_RESTART"
  SC_GUARDED=""; SC_OWN=""; SC_CLOSURE=""; SC_CONFIRMED=""; SC_NOEVID=""; SC_NOTCOMP=""; SC_LOCKED=""
  SC_OMIT=""; SC_STORY_LABELS=""
}

# reprobe_lines — the KEY=value lines the bead-scoped freshness re-probe prints.
reprobe_lines() {
  local key
  echo "VERDICT=$SC_VERDICT"
  echo "AFFECTED=$SC_GUARDED"
  echo "AFFECTED_NOT_RUNNING="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=$SC_GUARDED"
  for key in OWN CLOSURE_ONLY SYMBOL_CONFIRMED SYMBOL_NO_EVIDENCE SYMBOL_NOT_COMPUTED LOCKED_COSMETIC; do
    case " $SC_OMIT " in *" $key "*) continue ;; esac
    case "$key" in
      OWN)                  echo "GUARDED_OWN=$SC_OWN" ;;
      CLOSURE_ONLY)         echo "GUARDED_CLOSURE_ONLY=$SC_CLOSURE" ;;
      SYMBOL_CONFIRMED)     echo "GUARDED_SYMBOL_CONFIRMED=$SC_CONFIRMED" ;;
      SYMBOL_NO_EVIDENCE)   echo "GUARDED_SYMBOL_NO_EVIDENCE=$SC_NOEVID" ;;
      SYMBOL_NOT_COMPUTED)  echo "GUARDED_SYMBOL_NOT_COMPUTED=$SC_NOTCOMP" ;;
      LOCKED_COSMETIC)      echo "GUARDED_LOCKED_COSMETIC=$SC_LOCKED" ;;
    esac
  done
  echo "REASON=freshness re-probe (test scenario)"
  echo "PROOF=not_verified"
  echo "ALL_LABELS="
}

run_block() {
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

  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  reprobe_lines > "$T/reprobe.out"
  local first_label; first_label="$(set -- $SC_GUARDED; echo "${1:-}")"

  # Fake daemon-refresh.sh — same three-call-shape contract as the
  # human-confirmed test:
  #   1. DRY_RUN=1, SENSITIVE_DAEMONS does NOT name a scenario daemon: Path B —
  #      reports what the merge reaches.
  #   2. DRY_RUN=1, SENSITIVE_DAEMONS names one: the freshness re-probe —
  #      prints $T/reprobe.out (the scenario under test).
  #   3. DRY_RUN!=1: the WIDE sweep — off this bead's radar entirely.
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  case " \$SENSITIVE_DAEMONS " in
    *" $first_label "*)
      cat "$T/reprobe.out"
      exit 1
      ;;
    *)
      echo "VERDICT=OK"
      echo "AFFECTED=$SC_GUARDED"
      echo "AFFECTED_NOT_RUNNING="
      echo "RESTARTED="
      echo "FRESH_FAIL="
      echo "GUARDED="
      echo "REASON=dry-run per-bead probe"
      echo "ALL_LABELS="
      exit 0
      ;;
  esac
else
  echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=com.test.old-daemon"
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=com.test.old-daemon"
  echo "GUARDED_OWN=com.test.old-daemon"
  echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
  echo "ALL_LABELS=com.test.old-daemon"
  exit 1
fi
EOF

  EXPECT_C0="$SHA_C0"; EXPECT_C1="$SHA_C1"; EXPECT_C2="$SHA_C2"

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"; VARS_FILE="$T/vars.out"
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
  local STORY_LABELS="ctx:ready"
  [ -n "$SC_STORY_LABELS" ] && STORY_LABELS="ctx:ready,${SC_STORY_LABELS//@SHA@/$SHA_C2}"
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo ""; }

  ( set -o pipefail; for _t in _once; do eval "$BLOCK"; done
    echo "STATE=${BEAD_REPROBE_STATE:-<unset>} PROOF=${REFRESH_PROOF:-<unset>}" > "$VARS_FILE" ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  VARS_OUT="$(cat "$VARS_FILE" 2>/dev/null || echo '<no vars: block aborted>')"
  BASELINE_AFTER="$(cat "$BASELINE_FILE_ABS" 2>/dev/null || echo "<missing>")"
  rm -rf "$T"
}

held()      { has "$BD_CALLS" "delivery:failed" && has "$BD_CALLS" "delivery:deploy-pending"; }
halt_seen() { has "$BD_CALLS" "Delivery HALTED"; }
action_line() { grep 'ACTION: restart THESE' <<<"$BD_CALLS" | head -1; }

# ── R1: wa-i0e7rd, REAL data — six closure-only daemons, none with symbol evidence ──
reset_scenario
SC_GUARDED="$VCARD $SCHED $CMON $FICHA $FOLLOW $REFER"
SC_CLOSURE="$SC_GUARDED"; SC_NOEVID="$SC_GUARDED"
run_block
[ "$RUN_RC" -eq 0 ] && ok "R1 block runs clean" || nok "R1 rc" "rc=$RUN_RC vars=[$VARS_OUT]"
held && nok "R1 wa-i0e7rd WAS held for six closure-only / no-symbol-evidence daemons — the bug" "$BD_CALLS" \
     || ok "R1 wa-i0e7rd is NOT held (no delivery:failed / delivery:deploy-pending)"
halt_seen && nok "R1 a 'Delivery HALTED' comment was posted" "$BD_CALLS" || ok "R1 no HALT comment"
has "$BD_CALLS" "closure-only, não reiniciado:" \
  && ok "R1 the release is a visible comment on the bead: 'closure-only, não reiniciado: <lista>'" \
  || nok "R1 no visible 'closure-only, não reiniciado' comment" "$BD_CALLS"
for _l in $VCARD $SCHED $CMON $FICHA $FOLLOW $REFER; do
  has "$BD_CALLS" "$_l" || nok "R1 the recorded comment omits $_l" "$BD_CALLS"
done
has "$BD_CALLS" "ga-65o94h" && ok "R1 the comment cites ga-65o94h" || nok "R1 comment does not cite ga-65o94h" "$BD_CALLS"
has "$BD_CALLS" "$EXPECT_C1..$EXPECT_C2" \
  && ok "R1 the evidence names the merge range that was examined ($EXPECT_C1..$EXPECT_C2)" \
  || nok "R1 evidence does not name the examined range" "$BD_CALLS"
has "$VARS_OUT" "STATE=closure-cosmetic" && ok "R1 re-probe state is 'closure-cosmetic'" || nok "R1 state" "$VARS_OUT"
has "$VARS_OUT" "PROOF=symbol_unreachable_closure_only" \
  && ok "R1 proof tier is symbol_unreachable_closure_only (own tier — not folded into the locked one)" \
  || nok "R1 proof tier" "$VARS_OUT"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "R1 rig-wide baseline marker did NOT advance (this evidence is about THIS merge only)" \
  || nok "R1 baseline marker changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── R2: wa-hb6h5b, REAL data — demand-dashboard is the real executor: must still HALT ──
reset_scenario
SC_GUARDED="$VCARD $SCHED $CMON $DEMAND $FICHA $FOLLOW $REFER"
SC_CLOSURE="$SC_GUARDED"
SC_CONFIRMED="$VCARD $SCHED $CMON $DEMAND $FOLLOW $REFER"
SC_NOEVID="$FICHA"
run_block
held && ok "R2 wa-hb6h5b is STILL held (demand-dashboard really runs the changed chain)" \
     || nok "R2 wa-hb6h5b was RELEASED though demand-dashboard is the real executor — false negative, the change must not enter" "$BD_CALLS"
halt_seen && ok "R2 HALT comment posted" || nok "R2 missing HALT comment" "$BD_CALLS"
ACTION_LINE="$(action_line)"
if [ -n "$ACTION_LINE" ]; then
  has "$ACTION_LINE" "$DEMAND" && ok "R2 'restart THESE' names demand-dashboard" || nok "R2 list lacks $DEMAND" "$ACTION_LINE"
  has "$ACTION_LINE" "$FICHA" && nok "R2 'restart THESE' tells a human to restart ficha360, which has no symbol evidence" "$ACTION_LINE" \
                              || ok "R2 ficha360 (no symbol evidence) is NOT in 'restart THESE'"
else
  nok "R2 no 'ACTION: restart THESE' line in the halt" "$BD_CALLS"
fi
has "$BD_CALLS" "$FICHA" && has "$BD_CALLS" "closure-only" \
  && ok "R2 the halt still MENTIONS ficha360 and why it was left out (closure-only)" \
  || nok "R2 ficha360 silently vanished from the halt" "$BD_CALLS"
has "$VARS_OUT" "STATE=stale" && ok "R2 state stays 'stale'" || nok "R2 state" "$VARS_OUT"

# ── R3: wa-l3ff6z, REAL data — six daemons the calculator CONFIRMED: held, none excused ──
reset_scenario
SC_GUARDED="$VCARD $CAMPAPI $SCHED $CMON $FOLLOW $REFER"
SC_CLOSURE="$SC_GUARDED"; SC_CONFIRMED="$SC_GUARDED"
run_block
held && ok "R3 wa-l3ff6z stays held: every daemon is SYMBOL_CONFIRMED, nothing is excusable by this rule" \
     || nok "R3 released daemons the calculator confirmed" "$BD_CALLS"
has "$VARS_OUT" "STATE=stale" && ok "R3 state stays 'stale'" || nok "R3 state" "$VARS_OUT"
has "$BD_CALLS" "closure-only, não reiniciado:" \
  && nok "R3 a closure-only release comment was posted for confirmed daemons" "$BD_CALLS" \
  || ok "R3 no closure-only release comment"

# ── C1: closure-only but the calculator did NOT compute it: held (not "no evidence") ──
reset_scenario
SC_GUARDED="$VCARD"; SC_CLOSURE="$VCARD"; SC_NOTCOMP="$VCARD"
run_block
held && ok "C1 NOT_COMPUTED is an unanswered question, not a negative answer — HELD" || nok "C1 released a NOT_COMPUTED daemon" "$BD_CALLS"
has "$VARS_OUT" "STATE=stale" && ok "C1 state stays 'stale'" || nok "C1 state" "$VARS_OUT"

# ── C2: helper printed no GUARDED_SYMBOL_NO_EVIDENCE line at all: held (absent != empty) ──
reset_scenario
SC_GUARDED="$VCARD"; SC_CLOSURE="$VCARD"; SC_NOEVID="$VCARD"
SC_OMIT="SYMBOL_NO_EVIDENCE"
run_block
held && ok "C2 a helper that predates the field gets no split — HELD" || nok "C2 released on a missing GUARDED_SYMBOL_NO_EVIDENCE line" "$BD_CALLS"

# ── C2b: same for a missing GUARDED_CLOSURE_ONLY and a missing GUARDED_OWN line ──
reset_scenario
SC_GUARDED="$VCARD"; SC_CLOSURE="$VCARD"; SC_NOEVID="$VCARD"; SC_OMIT="CLOSURE_ONLY"
run_block
held && ok "C2b no GUARDED_CLOSURE_ONLY line -> HELD" || nok "C2b released with no GUARDED_CLOSURE_ONLY line" "$BD_CALLS"
reset_scenario
SC_GUARDED="$VCARD"; SC_CLOSURE="$VCARD"; SC_NOEVID="$VCARD"; SC_OMIT="OWN"
run_block
held && ok "C2b no GUARDED_OWN line -> HELD (cannot rule out OWN-FILE-CHANGED)" || nok "C2b released with no GUARDED_OWN line" "$BD_CALLS"

# ── C3: its own entrypoint changed (OWN-FILE-CHANGED): held even with NO_EVIDENCE ──
reset_scenario
SC_GUARDED="$VCARD"; SC_OWN="$VCARD"; SC_CLOSURE="$VCARD"; SC_NOEVID="$VCARD"
run_block
held && ok "C3 an OWN-FILE-CHANGED daemon is never excused by symbol analysis — HELD" || nok "C3 released an OWN-FILE-CHANGED daemon" "$BD_CALLS"

# ── C4: in NO_EVIDENCE but not named CLOSURE_ONLY: positive membership in BOTH or held ──
reset_scenario
SC_GUARDED="$VCARD"; SC_NOEVID="$VCARD"
run_block
held && ok "C4 NO_EVIDENCE without CLOSURE_ONLY membership -> HELD" || nok "C4 released without CLOSURE_ONLY membership" "$BD_CALLS"

# ── C5: closure-only excused + one CONFIRMED: held, the excused one stays out of 'restart THESE' ──
reset_scenario
SC_GUARDED="$FICHA $DEMAND"; SC_CLOSURE="$SC_GUARDED"; SC_NOEVID="$FICHA"; SC_CONFIRMED="$DEMAND"
run_block
held && ok "C5 held (the confirmed daemon is real work)" || nok "C5 released though a confirmed daemon is stale" "$BD_CALLS"
ACTION_LINE="$(action_line)"
if [ -n "$ACTION_LINE" ]; then
  has "$ACTION_LINE" "$DEMAND" && ok "C5 'restart THESE' names the confirmed daemon" || nok "C5 list lacks $DEMAND" "$ACTION_LINE"
  has "$ACTION_LINE" "$FICHA" && nok "C5 'restart THESE' lists the closure-only daemon" "$ACTION_LINE" || ok "C5 closure-only daemon is NOT in 'restart THESE'"
else
  nok "C5 no 'ACTION: restart THESE' line" "$BD_CALLS"
fi

# ── C6: locked-cosmetic + closure-cosmetic together cover every stale daemon: released ──
reset_scenario
SC_GUARDED="$VCARD $FICHA"; SC_CLOSURE="$FICHA"; SC_NOEVID="$VCARD $FICHA"; SC_LOCKED="$VCARD"
run_block
held && nok "C6 held though one daemon is locked-cosmetic and the other closure-only" "$BD_CALLS" || ok "C6 released (locked-cosmetic + closure-only cover every stale daemon)"
has "$VARS_OUT" "STATE=closure-cosmetic" && ok "C6 state is 'closure-cosmetic'" || nok "C6 state" "$VARS_OUT"
has "$BD_CALLS" "$VCARD" && has "$BD_CALLS" "$FICHA" && ok "C6 the recorded comment names both daemons" || nok "C6 comment misses a daemon" "$BD_CALLS"

# ── C7: closure-only + a human-attested label for a NOT_COMPUTED one: released, 'human-confirmed' ──
reset_scenario
SC_GUARDED="$FICHA $SCHED"; SC_CLOSURE="$FICHA"; SC_NOEVID="$FICHA"; SC_NOTCOMP="$SCHED"
SC_STORY_LABELS="delivery:symbol-confirmed-unreachable:@SHA@:$SCHED"
run_block
held && nok "C7 held though both stale daemons are excused (one closure-only, one human-confirmed)" "$BD_CALLS" || ok "C7 released"
has "$VARS_OUT" "STATE=human-confirmed" \
  && ok "C7 state is 'human-confirmed' (one daemon rests on human evidence — the weaker one governs the tier)" \
  || nok "C7 state" "$VARS_OUT"
has "$BD_CALLS" "$FICHA" && has "$BD_CALLS" "$SCHED" && ok "C7 the recorded comment names both" || nok "C7 comment misses a daemon" "$BD_CALLS"

# ── C8: a verdict other than NEEDS_GUARDED_RESTART never reaches the split ──
reset_scenario
SC_VERDICT="JOB_NOT_INSTALLED"
SC_GUARDED="$VCARD"; SC_CLOSURE="$VCARD"; SC_NOEVID="$VCARD"
run_block
held && ok "C8 JOB_NOT_INSTALLED over a closure-only label is HELD (a job that never ran is not cosmetic)" \
     || nok "C8 released on JOB_NOT_INSTALLED" "$BD_CALLS"

echo ""
echo "story-delivery closure-only release tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
