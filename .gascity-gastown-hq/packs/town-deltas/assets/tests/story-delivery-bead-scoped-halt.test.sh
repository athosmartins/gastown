#!/usr/bin/env bash
# story-delivery-bead-scoped-halt.test.sh — regression test for ga-8i2nds
# (extracts the real Step 5b block from story-delivery.sh, no duplication —
# same technique as the other story-delivery-*.test.sh files).
#
# THE BUG (measured live 2026-09-19, whatsapp_automation): every story that
# reached delivery was halted (story:done withheld) and every halt carried the
# SAME 36-daemon headline — including "OWN-FILE-CHANGED (1) ... its own
# entrypoint/template is in THIS diff, the deployer should have restarted
# these and didn't: com.whatsapp.ficha360" on wa-r4ehy.3, whose diff is
# slot_scheduler.py + queue_database.py and never touches ficha360.
#
# TWO defects, one root (the WIDE window's freshness is judged against its TIP
# commit, not against the story's own merge — daemon-refresh.sh's
# already_fresh() compares a process start to POST_DEPLOY_SHA's commit time):
#
#   (a) PRESENTATION. The halt's headline / raw detail / mayor nudge were the
#       wide window's own REASON/stdout: identical for every story while the
#       rig baseline stays put, and worded as a claim about THIS story's diff.
#       The bead-scoped "restart THESE" line existed but listed the merge's
#       whole reach (fresh daemons included), under that wide headline.
#   (b) DECISION. The bead-scoped freshness re-probe (ga-g63ejg: is each
#       daemon THIS merge reaches older than THIS merge's commit?) only ran
#       when the wide guarded set did NOT overlap the merge's reach; an
#       overlap went straight to a hold. wa-catpm (merge 08:08:44) and wa-ben95
#       (04:35:44) were held for com.whatsapp.ficha360, restarted 08:25:07 —
#       AFTER both merges — because the wide check measured it against the
#       10:24:54 tip. A read-only re-probe of wa-catpm's merge against the
#       live processes came back VERDICT=OK, 5 of 5 reached daemons fresh.
#
# THE FIX: the re-probe decides whenever the story has bead-scoped attribution
# (overlap or not); a hold reports ITS stale list (never the wide one) in the
# headline, the raw detail and the nudges; the wide window is reduced to a
# count on a "Context only" line (names stay in story-delivery.log); the dedup
# key follows the list the halt actually shows. A release that rests on the
# re-probe DESPITE a wide overlap does not advance the rig-wide marker (that
# would drop a still-pending sibling's merge out of its own next window).
#
# T1 (acceptance 2 — the wa-r4ehy.3 shape): wide window says ficha360 is
#     OWN-FILE-CHANGED; this story's own reach is {slot-scheduler,
#     campaign-api, call-vcard-notifier} of which only the last two are
#     stale. Held — but NOTHING posted (comment or nudge) may name ficha360
#     or say OWN-FILE-CHANGED, and the restart list names only the two stale
#     daemons (not the fresh slot-scheduler). The wide names stay in the log.
# T2 (the wa-catpm shape — false-positive hold released): this story's reach
#     really includes ficha360 and the wide sweep flags it, but the re-probe
#     says every reached daemon started after the merge. Released; mayor
#     nudged (names the overlap); rig-wide marker NOT advanced.
# T3 (acceptance 3 — the wa-ben95 shape — the true positive is kept): reach
#     {clientes-dashboard, demand-dashboard, ficha360}, wide overlap on
#     ficha360, re-probe: only clientes-dashboard stale. Held, and the halt
#     names clientes-dashboard alone.
# T4 (third state): overlap present, re-probe unparseable. Held (fail closed),
#     worded "NOT confirmed stale", marker untouched.
# T5 (control — honest fallback): no bead-scoped attribution at all (no merge
#     range). The wide list is all there is, and it is shown exactly as before.
# T6 (dedup key): the same story halted twice with the SAME bead-scoped stale
#     list but a DIFFERENT wide guarded list — the second cycle is silent.
# T7 (Path A — the common production path): the T1 shape when this iteration's
#     own pull moved HEAD (PRE != POST). Same guarantees as T1.
# T8 (Path A): the T2 shape (wa-catpm — overlap released on the re-probe) on
#     Path A; the rig-wide marker still does not advance.
# T9 (control): NO overlap + fresh re-probe is still released AND still advances
#     the marker — the pre-existing ga-49fwiw invariant (c) must not regress.

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

# run_block — scenario is driven by exported FAKE_* env vars (read by the fake
# daemon-refresh.sh below, which runs as a subprocess):
#   FAKE_REACH      labels this story's own delta reaches (per-story probe)
#   FAKE_REPROBE    stale | fresh | unparseable — the freshness re-probe result
#   FAKE_STALE      labels the re-probe reports still stale (mode=stale)
#   FAKE_WIDE       labels the WIDE (real, non-dry-run) sweep reports GUARDED
#   FAKE_WIDE_OWN   the OWN-FILE-CHANGED subset of FAKE_WIDE
#   ATTRIBUTED      1 = pass MERGE_SHA/MERGE_PRE_MAIN (bead-scoped), 0 = don't
#   PATH_A          1 = this iteration's own pull moved HEAD (PRE != POST, the
#                   common production case), default 0 = true no-op pull (Path B)
#   RUNS            how many times to evaluate the block for the same story
#                   (persistent city dir, so the halt fingerprint carries over);
#                   FAKE_WIDE_2 replaces FAKE_WIDE from the 2nd run on.
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
  echo ficha > "$REPO/ficha360_app.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo slot > "$REPO/slot_scheduler.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  # The rig baseline is frozen at C0, so the wide window spans C1 (an EARLIER,
  # unrelated delivery that changed ficha360's own file) AND this story's C2.
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  # Fake daemon-refresh.sh, three call shapes (same trick as the ga-g63ejg
  # test): the freshness re-probe is the DRY_RUN=1 call whose SENSITIVE_DAEMONS
  # the caller has forced to include the reached labels; the plain per-story
  # probe is the other DRY_RUN=1 call; the wide sweep is the non-dry-run one.
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
label_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
if [ "${DRY_RUN:-0}" = "1" ]; then
  first_reach="${FAKE_REACH%% *}"
  case " ${SENSITIVE_DAEMONS:-} " in
    *" $first_reach "*)
      # the bead-scoped freshness re-probe
      case "$FAKE_REPROBE" in
        unparseable) exit 1 ;;
        fresh)
          echo "VERDICT=OK"
          echo "AFFECTED=$FAKE_REACH"
          echo "AFFECTED_NOT_RUNNING="
          echo "RESTARTED="
          echo "FRESH_FAIL="
          echo "GUARDED="
          echo "GUARDED_OWN="
          echo "ALREADY_FRESH=$FAKE_REACH"
          echo "REASON=bead-scoped re-probe: every reached daemon started after this merge"
          echo "ALL_LABELS=$FAKE_REACH"
          echo "PROOF=not_verified"
          exit 0 ;;
        stale)
          fresh_list=""
          for l in $FAKE_REACH; do label_in "$l" "$FAKE_STALE" || fresh_list="$fresh_list $l"; done
          echo "VERDICT=NEEDS_GUARDED_RESTART"
          echo "AFFECTED=$FAKE_REACH"
          echo "AFFECTED_NOT_RUNNING="
          echo "RESTARTED="
          echo "FRESH_FAIL="
          echo "GUARDED=$FAKE_STALE"
          echo "GUARDED_OWN="
          echo "ALREADY_FRESH=${fresh_list# }"
          echo "REASON=bead-scoped re-probe: still running code older than this merge"
          echo "ALL_LABELS=$FAKE_REACH"
          echo "PROOF=not_verified"
          exit 1 ;;
      esac ;;
  esac
  # the plain per-story reachability probe
  echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=$FAKE_REACH"
  echo "AFFECTED_NOT_RUNNING="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED="
  echo "REASON=dry-run per-story probe"
  echo "ALL_LABELS="
  exit 1
fi
# the WIDE, real sweep: judged against the window TIP, so it flags everything
# older than the tip whose closure the frozen window touches.
n_own=$(echo "$FAKE_WIDE_OWN" | wc -w | tr -d ' ')
n_all=$(echo "$FAKE_WIDE" | wc -w | tr -d ' ')
echo "VERDICT=NEEDS_GUARDED_RESTART"
echo "AFFECTED=$FAKE_WIDE"
echo "RESTARTED="
echo "FRESH_FAIL="
echo "GUARDED=$FAKE_WIDE"
echo "GUARDED_OWN=$FAKE_WIDE_OWN"
echo "REASON=sensitive hot-path daemon(s) need a guarded restart (import/template-closure match): $FAKE_WIDE || OWN-FILE-CHANGED ($n_own) -- its own entrypoint/template is in THIS diff, the deployer should have restarted these and didn't, restart THESE first:$FAKE_WIDE_OWN || CLOSURE-ONLY ($n_all) -- only imports something that changed"
echo "ALL_LABELS=$FAKE_WIDE"
echo "PROOF=not_verified"
exit 1
EOF

  EXPECT_C0="$SHA_C0"; EXPECT_C2="$SHA_C2"

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true
  export FAKE_REACH FAKE_REPROBE FAKE_STALE FAKE_WIDE FAKE_WIDE_OWN

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # Path B (true no-op pull, the default here): HEAD is already at this story's
  # own tip. PATH_A=1 = Path A instead: THIS iteration's own pull moved HEAD
  # C1 -> C2 — the far more common case in production (ga-ndu4ic), and the one
  # every live halt in the bug report took.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  if [ "${PATH_A:-0}" = "1" ]; then PRE_DEPLOY_SHA="$SHA_C1"; fi
  local MERGE_SHA="" MERGE_REF="origin/main" MERGE_PRE_MAIN=""
  if [ "${ATTRIBUTED:-1}" = "1" ]; then
    MERGE_SHA="$SHA_C2"; MERGE_PRE_MAIN="$SHA_C1"
  fi
  get_runbook_field() { echo ""; }

  local run
  for run in $(seq 1 "${RUNS:-1}"); do
    [ "$run" -ge 2 ] && [ -n "${FAKE_WIDE_2:-}" ] && export FAKE_WIDE="$FAKE_WIDE_2"
    ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
    RUN_RC=$?
  done
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  BASELINE_AFTER="$(cat "$BASELINE_FILE_ABS" 2>/dev/null || echo "<missing>")"
  rm -rf "$T"
}

# The 36-daemon-style wide list every story carries while the baseline is
# frozen: ficha360 (own file changed by the EARLIER delivery C1) plus the
# closure-only crowd, including the two stale daemons this story reaches.
WIDE_COMMON="com.whatsapp.ficha360 com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier com.whatsapp.approval-monitor com.whatsapp.ban-risk-dashboard"

# ── T1: the wa-r4ehy.3 shape ────────────────────────────────────────────────
FAKE_REACH="com.whatsapp.slot-scheduler com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier"
FAKE_REPROBE=stale
FAKE_STALE="com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier"
FAKE_WIDE="$WIDE_COMMON"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0)" || nok "T1 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T1 delivery IS held — two of the merge's reached daemons really run pre-merge code" \
  || nok "T1 delivery wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "Delivery HALTED" \
  && ok "T1 halt comment posted" || nok "T1 no halt comment" "$BD_CALLS"
echo "$BD_CALLS$GC_CALLS" | grep -q "ficha360" \
  && nok "T1 Aceite 2 VIOLATED: a comment/nudge names ficha360, which this story's diff never touches" "$(echo "$BD_CALLS$GC_CALLS" | grep -m3 ficha360 | cut -c1-260)" \
  || ok "T1 Aceite 2: no comment or nudge names ficha360"
echo "$BD_CALLS$GC_CALLS" | grep -q "OWN-FILE-CHANGED" \
  && nok "T1 Aceite 2 VIOLATED: the wide window's OWN-FILE-CHANGED classification leaked into a comment/nudge" "$(echo "$BD_CALLS$GC_CALLS" | grep -m2 OWN-FILE-CHANGED | cut -c1-260)" \
  || ok "T1 Aceite 2: the wide OWN-FILE-CHANGED classification is not shown as this story's"
LEAD_PART="$(echo "$BD_CALLS" | awk '/Context only/{exit} {print}')"
echo "$LEAD_PART" | grep -q "com.whatsapp.campaign-api" && echo "$LEAD_PART" | grep -q "com.whatsapp.call-vcard-notifier" \
  && ok "T1 the halt names both daemons that are really stale for this merge" \
  || nok "T1 stale daemons missing from the halt" "$LEAD_PART"
echo "$LEAD_PART" | grep -q "com.whatsapp.slot-scheduler" \
  && nok "T1 Aceite 1 VIOLATED: the halt lists slot-scheduler, which the re-probe found already fresh" "$LEAD_PART" \
  || ok "T1 Aceite 1: the fresh reached daemon (slot-scheduler) is not on the restart list"
echo "$LEAD_PART" | grep -q "com.whatsapp.approval-monitor" \
  && nok "T1 Aceite 1 VIOLATED: an unrelated wide-window daemon (approval-monitor) is in the halt's lead" "$LEAD_PART" \
  || ok "T1 Aceite 1: no unrelated wide-window daemon in the halt's lead"
CONTEXT_LINE="$(echo "$BD_CALLS" | grep "Context only — NOT attributed to this merge" | head -1)"
[ -n "$CONTEXT_LINE" ] && ok "T1 the wide window is still acknowledged on an explicit 'Context only' line" \
  || nok "T1 missing the Context-only line" "$BD_CALLS"
echo "$CONTEXT_LINE" | grep -qE '[0-9]+ other sensitive daemon' \
  && ok "T1 the context line carries a count of the other flagged daemons" \
  || nok "T1 context line has no count" "$CONTEXT_LINE"
echo "$CONTEXT_LINE" | grep -q "com.whatsapp\." \
  && nok "T1 the context line still lists wide-window daemon names" "$CONTEXT_LINE" \
  || ok "T1 the context line lists no daemon names (only this merge's own are named)"
echo "$LOG_OUT" | grep -q "guarded=\[.*com.whatsapp.ficha360.*com.whatsapp.approval-monitor" \
  && ok "T1 nothing is hidden: the full wide list is still in the log" \
  || nok "T1 the wide list is missing from the log" "$LOG_OUT"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T1 rig-wide marker not advanced (a hold never advances it)" \
  || nok "T1 marker changed" "want=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T2: the wa-catpm shape — overlap, but the re-probe clears it ────────────
FAKE_REACH="com.whatsapp.demand-dashboard com.whatsapp.ficha360 com.whatsapp.map-viewer"
FAKE_REPROBE=fresh; FAKE_STALE=""
FAKE_WIDE="$WIDE_COMMON com.whatsapp.demand-dashboard"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0)" || nok "T2 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && nok "T2 delivery WAS held although every daemon the merge reaches started after it (the wa-catpm false positive)" "$BD_CALLS" \
  || ok "T2 delivery is NOT held — the wide flag was measured against the window tip, not this merge"
echo "$BD_CALLS" | grep -q "Delivery HALTED" \
  && nok "T2 a halt comment was posted" "$BD_CALLS" \
  || ok "T2 no halt comment"
echo "$GC_CALLS" | grep -q "session nudge mayor" \
  && ok "T2 mayor is still nudged — the release must stay visible" \
  || nok "T2 missing mayor nudge" "$GC_CALLS"
echo "$GC_CALLS" | grep "session nudge mayor" | grep -q "com.whatsapp.ficha360" \
  && ok "T2 the nudge names the overlapping daemon (ficha360), so the release is explained" \
  || nok "T2 the nudge does not name the overlap" "$GC_CALLS"
echo "$LOG_OUT" | grep -q "started AFTER its merge commit" \
  && ok "T2 log states why the wide flag does not apply to this merge" \
  || nok "T2 missing explanation in the log" "$LOG_OUT"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T2 rig-wide marker NOT advanced — a release on this story's own evidence must not skip a pending sibling's window" \
  || nok "T2 marker moved" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T3: the wa-ben95 shape — the true positive must survive ─────────────────
FAKE_REACH="com.whatsapp.clientes-dashboard com.whatsapp.demand-dashboard com.whatsapp.ficha360"
FAKE_REPROBE=stale; FAKE_STALE="com.whatsapp.clientes-dashboard"
FAKE_WIDE="$WIDE_COMMON com.whatsapp.clientes-dashboard"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0)" || nok "T3 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T3 Aceite 3: delivery IS held — clientes-dashboard really runs pre-merge code" \
  || nok "T3 Aceite 3 VIOLATED: a truly stale daemon no longer blocks delivery" "$BD_CALLS"
LEAD_PART="$(echo "$BD_CALLS" | awk '/Context only/{exit} {print}')"
echo "$LEAD_PART" | grep -q "com.whatsapp.clientes-dashboard" \
  && ok "T3 the halt names the one stale daemon (clientes-dashboard)" \
  || nok "T3 clientes-dashboard missing" "$LEAD_PART"
for d in com.whatsapp.ficha360 com.whatsapp.demand-dashboard; do
  echo "$LEAD_PART" | grep -q "$d" \
    && nok "T3 the halt lists $d, which the re-probe found already fresh" "$LEAD_PART" \
    || ok "T3 the halt does not list the fresh reached daemon $d"
done

# ── T4: overlap + unparseable re-probe — fail closed, honestly worded ───────
FAKE_REACH="com.whatsapp.demand-dashboard com.whatsapp.ficha360"
FAKE_REPROBE=unparseable; FAKE_STALE=""
FAKE_WIDE="$WIDE_COMMON com.whatsapp.demand-dashboard"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0)" || nok "T4 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T4 delivery IS held (an unparseable re-probe is never treated as fresh)" \
  || nok "T4 delivery wrongly NOT held on an unparseable re-probe" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "NOT confirmed stale" \
  && ok "T4 the halt says the list is NOT confirmed stale (no false precision)" \
  || nok "T4 halt does not disclose that the re-probe was unavailable" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T4 rig-wide marker unchanged" || nok "T4 marker changed" "want=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T5: control — no bead-scoped attribution: the wide list is all we have ──
FAKE_REACH="com.whatsapp.slot-scheduler com.whatsapp.campaign-api"
FAKE_REPROBE=stale; FAKE_STALE="com.whatsapp.campaign-api"
FAKE_WIDE="$WIDE_COMMON"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
ATTRIBUTED=0 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T5 block runs clean (rc=0)" || nok "T5 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T5 delivery IS held (wide verdict, nothing to exonerate on)" \
  || nok "T5 delivery wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "OWN-FILE-CHANGED" \
  && ok "T5 without a merge range the wide text is shown as before — the honest fallback is unchanged" \
  || nok "T5 the wide fallback text disappeared" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "No per-bead attribution available" \
  && ok "T5 the halt still says no per-bead attribution was available" \
  || nok "T5 missing the no-attribution disclosure" "$BD_CALLS"

# ── T6: the dedup key follows the list the halt shows ───────────────────────
FAKE_REACH="com.whatsapp.slot-scheduler com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier"
FAKE_REPROBE=stale; FAKE_STALE="com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier"
FAKE_WIDE="$WIDE_COMMON"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
# 2nd cycle: unrelated commits changed the WIDE list (an extra daemon), this
# story's own stale set is byte-identical.
FAKE_WIDE_2="$WIDE_COMMON com.whatsapp.lead-scorer com.whatsapp.frota-dashboard"
ATTRIBUTED=1 RUNS=2 run_block
ANNOUNCES="$(echo "$BD_CALLS" | grep -c 'Delivery HALTED (ga-iwv0 daemon refresh)')"
[ "$ANNOUNCES" -eq 1 ] \
  && ok "T6 the second cycle is silent: same bead-scoped stale list, only the unrelated wide list moved" \
  || nok "T6 dedup keyed on the wide list re-announced an unchanged bead-scoped halt" "announce comments=$ANNOUNCES"
unset FAKE_WIDE_2

# ── T7: Path A (PRE != POST — the common production path): the wa-r4ehy.3 shape
# Same scenario as T1, but this iteration's own pull moved HEAD. The bead-scoped
# probe runs on Path A too (ga-ndu4ic), so the fix must hold there as well —
# every live halt in the bug report took this path.
FAKE_REACH="com.whatsapp.slot-scheduler com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier"
FAKE_REPROBE=stale; FAKE_STALE="com.whatsapp.campaign-api com.whatsapp.call-vcard-notifier"
FAKE_WIDE="$WIDE_COMMON"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
PATH_A=1 ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T7 (Path A) block runs clean (rc=0)" || nok "T7 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T7 (Path A) delivery IS held — two reached daemons really run pre-merge code" \
  || nok "T7 (Path A) delivery wrongly NOT held" "$BD_CALLS"
echo "$BD_CALLS$GC_CALLS" | grep -qE "ficha360|OWN-FILE-CHANGED" \
  && nok "T7 (Path A) Aceite 2 VIOLATED: ficha360 / the wide OWN-FILE-CHANGED text leaked into a comment/nudge" "$(echo "$BD_CALLS$GC_CALLS" | grep -m2 -E 'ficha360|OWN-FILE-CHANGED' | cut -c1-260)" \
  || ok "T7 (Path A) Aceite 2: neither ficha360 nor OWN-FILE-CHANGED appears in any comment/nudge"
LEAD_PART="$(echo "$BD_CALLS" | awk '/Context only/{exit} {print}')"
echo "$LEAD_PART" | grep -q "com.whatsapp.campaign-api" && echo "$LEAD_PART" | grep -q "com.whatsapp.call-vcard-notifier" \
  && ok "T7 (Path A) the halt names both really-stale daemons" \
  || nok "T7 (Path A) stale daemons missing from the halt" "$LEAD_PART"
echo "$LEAD_PART" | grep -qE "com.whatsapp.(slot-scheduler|approval-monitor|ban-risk-dashboard)" \
  && nok "T7 (Path A) Aceite 1 VIOLATED: the halt lists a fresh or unrelated daemon" "$LEAD_PART" \
  || ok "T7 (Path A) Aceite 1: only this merge's own stale daemons are listed"

# ── T8: Path A — the wa-catpm shape: overlap, re-probe clears it ────────────
FAKE_REACH="com.whatsapp.demand-dashboard com.whatsapp.ficha360 com.whatsapp.map-viewer"
FAKE_REPROBE=fresh; FAKE_STALE=""
FAKE_WIDE="$WIDE_COMMON com.whatsapp.demand-dashboard"; FAKE_WIDE_OWN="com.whatsapp.ficha360"
PATH_A=1 ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T8 (Path A) block runs clean (rc=0)" || nok "T8 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && nok "T8 (Path A) delivery WAS held although every reached daemon started after the merge" "$BD_CALLS" \
  || ok "T8 (Path A) delivery is NOT held (the wide flag is judged against the window tip)"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T8 (Path A) rig-wide marker NOT advanced on an overlap-release" \
  || nok "T8 (Path A) marker moved" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

# ── T9: control — NO overlap + fresh re-probe still advances the marker ─────
# The pre-existing ga-49fwiw invariant (c) this change must not disturb: only
# the overlap-release is exempted from advancing the rig-wide marker.
FAKE_REACH="com.whatsapp.slot-scheduler com.whatsapp.campaign-api"
FAKE_REPROBE=fresh; FAKE_STALE=""
FAKE_WIDE="$WIDE_COMMON"; FAKE_WIDE_OWN="com.whatsapp.ficha360"   # ficha360 is NOT in this reach
ATTRIBUTED=1 RUNS=1 run_block
[ "$RUN_RC" -eq 0 ] && ok "T9 block runs clean (rc=0)" || nok "T9 rc" "rc=$RUN_RC"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && nok "T9 delivery WAS held although the re-probe cleared every reached daemon" "$BD_CALLS" \
  || ok "T9 delivery is NOT held (re-probe fresh, no wide overlap)"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T9 rig-wide marker advanced to the window tip (ga-49fwiw invariant c preserved for the no-overlap release)" \
  || nok "T9 marker did not advance on a no-overlap release" "want=$EXPECT_C2 got=$BASELINE_AFTER"

echo ""
echo "story-delivery bead-scoped halt (ga-8i2nds) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
