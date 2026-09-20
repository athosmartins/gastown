#!/usr/bin/env bash
# story-delivery-bead-reprobe-arrival-floor.test.sh — regression test for ga-c3oyk6
# (extracts the real Step 5b block + the real runtime_arrival_epoch helper from
# story-delivery.sh, no duplication — same technique as
# story-delivery-guarded-restart-freshness-reprobe.test.sh).
#
# THE BUG (measured live, wa-0n0bj, 2026-09-20): a story released on its
# bead-scoped freshness re-probe ("VERDICT=OK still-stale=[]", 00:48:49) was
# closed 11s later with delivery:daemon-unverified + "DAEMON LIVENESS NOT
# VERIFIED — merged code may still be dormant". Two defects stacked:
#   1. Step 8 keys the label off REFRESH_PROOF, which is the WIDE window's proof
#      (always not_verified under NEEDS_GUARDED_RESTART) — the release path never
#      let the bead-scoped probe's own answer replace it.
#   2. Even the probe's own proof could not be "verified" on a retry: daemon-
#      refresh.sh's already_fresh() calls a pid-start "verified" only past
#      DEPLOY_EPOCH (this iteration's start). The normal hold -> operator
#      restarts the daemon -> next sweep flow puts the restart BEFORE that, so it
#      only ever scored the weaker commit-time correlation tier.
#
# THE FIX: floor the re-probe at when the merge ARRIVED in the runtime checkout
# (runtime_arrival_epoch, read from HEAD's reflog; only ever lowers the floor),
# and let a clean re-probe with proof=verified set REFRESH_PROOF for that story.
# Anything weaker keeps the wide window's fail-closed not_verified.
#
# Timeline used below (unix epochs, all controlled via GIT_COMMITTER_DATE):
#   3000  C2 (the story's merge) is committed        — its "commit time"
#   3500  C2 arrives in the runtime checkout (ff)    — its "arrival"
#   5000  this sweep iteration's DEPLOY_EPOCH        — the retry's start
# and the daemon's pid-start S is what each case varies.
#
# U1-U6  runtime_arrival_epoch itself (real reflog, real timestamps).
# T1 (the fix)          S=4000: after arrival, before DEPLOY_EPOCH -> the probe is
#                       floored at 3500, scores verified, REFRESH_PROOF=verified.
# T2 (guard, no false-verified) S=3200: after the commit but BEFORE arrival (a
#                       respawn while the checkout was still old code) -> stays
#                       not_verified, no override.
# T3 (fail closed)      arrival unprovable -> floor stays DEPLOY_EPOCH, no override.
# T4 (never raises)     arrival LATER than DEPLOY_EPOCH -> floor stays DEPLOY_EPOCH.
# T5 (control)          S=2500: older than the commit -> still stale, held.
# T6 (wiring)           Step 8 still keys the label off REFRESH_PROOF.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable only so the A/B check ("does this test fail on the pre-fix block?")
# can point the block at the old script while keeping the helper from the new one.
DELIVERY="${STORY_DELIVERY_BLOCK_SRC:-$SCRIPT_DIR/../story-delivery.sh}"
HELPER_SRC="${STORY_DELIVERY_HELPER_SRC:-$SCRIPT_DIR/../story-delivery.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }
HELPER_FN="$(sed -n '/^runtime_arrival_epoch() {/,/^}/p' "$HELPER_SRC")"
[ -n "$HELPER_FN" ] || { echo "FAIL: could not extract runtime_arrival_epoch from $HELPER_SRC"; exit 1; }
eval "$HELPER_FN"

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# gitc <epoch> <git args...> — run git in $REPO with every date pinned, so the
# reflog timestamps (not just the commit dates) are exact. The "@" is required:
# git rejects a bare small epoch ("1000 +0000") as an ambiguous date.
gitc() { local e="$1"; shift; GIT_COMMITTER_DATE="@$e +0000" GIT_AUTHOR_DATE="@$e +0000" git -C "$REPO" "$@"; }

# mk_runtime <dir> <mode>   mode: landed (C2 arrives at 3500, then C3@3600 and
# C4@3700 on top) | late (arrives at 6000) | never (the runtime never gets C2).
# Sets SHA_C1 SHA_C2. HEAD reflog, newest first, for `landed`:
#   3700 C4 | 3600 C3 | 3500 merge C2 | 3100 checkout main(C1) | 3000 commit C2 (on side) ...
mk_runtime() {
  REPO="$1"; local mode="$2"
  {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main
    git -C "$REPO" config user.email t@t.local
    git -C "$REPO" config user.name t
    echo base > "$REPO/base.txt"; git -C "$REPO" add -A; gitc 1000 commit -q -m C0
    echo mid  > "$REPO/mid.txt";  git -C "$REPO" add -A; gitc 2000 commit -q -m C1
    SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
    gitc 2100 checkout -q -b side
    echo new  > "$REPO/new.txt";  git -C "$REPO" add -A; gitc 3000 commit -q -m C2
    SHA_C2="$(git -C "$REPO" rev-parse HEAD)"
    gitc 3100 checkout -q main
    case "$mode" in
      landed)
        gitc 3500 merge -q --ff-only side
        echo c3 > "$REPO/c3.txt"; git -C "$REPO" add -A; gitc 3600 commit -q -m C3
        echo c4 > "$REPO/c4.txt"; git -C "$REPO" add -A; gitc 3700 commit -q -m C4
        ;;
      late)  gitc 6000 merge -q --ff-only side ;;
      never) : ;;
      *) echo "mk_runtime: unknown mode '$mode'" >&2; exit 1 ;;
    esac
  } >/dev/null 2>&1
  # A broken fixture must be a loud harness failure, never a quiet "product" one.
  [ -n "${SHA_C1:-}" ] && [ -n "${SHA_C2:-}" ] && [ "$(git -C "$REPO" show -s --format=%ct "$SHA_C2" 2>/dev/null)" = "3000" ] \
    || { echo "FATAL: fixture build failed for mode '$mode' (git rejected the pinned dates?)" >&2; exit 1; }
}

# ── U1-U6: runtime_arrival_epoch on real reflogs ─────────────────────────────
UT="$(mktemp -d)"
mk_runtime "$UT/rt-landed" landed
got="$(runtime_arrival_epoch "$UT/rt-landed" "$SHA_C2")"
[ "$got" = "3500" ] && ok "U1 arrival = the OLDEST entry of the run that contains the sha (3500), not the newest (3700) nor the commit time (3000)" \
  || nok "U1 arrival" "want=3500 got=[$got]"
got="$(runtime_arrival_epoch "$UT/rt-landed" "$SHA_C2" 2)"
[ "$got" = "3600" ] && ok "U2 the walk bound errs LATER (3600 >= true 3500): never a looser floor" \
  || nok "U2 cap" "want=3600 got=[$got]"
mk_runtime "$UT/rt-never" never
got="$(runtime_arrival_epoch "$UT/rt-never" "$SHA_C2")"
[ -z "$got" ] && ok "U3 a merge that never reached the runtime -> empty (unknown), not a guessed time" \
  || nok "U3 never-landed" "want=<empty> got=[$got]"
got="$(runtime_arrival_epoch "$UT/rt-landed" "0000000000000000000000000000000000000000")"
[ -z "$got" ] && ok "U4 unknown sha -> empty" || nok "U4 unknown sha" "got=[$got]"
got="$(runtime_arrival_epoch "$UT" "$SHA_C2")"
[ -z "$got" ] && ok "U5 not a git checkout -> empty" || nok "U5 non-git dir" "got=[$got]"
REPO="$UT/rt-single"; git init -q "$REPO"; git -C "$REPO" config user.email t@t.local; git -C "$REPO" config user.name t
echo x > "$REPO/x"; git -C "$REPO" add -A; gitc 1234 commit -q -m only
got="$(runtime_arrival_epoch "$REPO" "$(git -C "$REPO" rev-parse HEAD)")"
[ "$got" = "1234" ] && ok "U6 reflog exhausted with every entry containing the sha -> the oldest entry (>= true arrival)" \
  || nok "U6 exhausted reflog" "want=1234 got=[$got]"
rm -rf "$UT"

# run_block <daemon_start_epoch S> <runtime mode> <deploy_epoch D>
run_block() {
  local S="$1" mode="$2" D="$3"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"
  mk_runtime "$T/runtime" "$mode"
  local REPO_RT="$T/runtime"

  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C1" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  # Fake daemon-refresh.sh — three call shapes, as in the sibling freshness test:
  #   narrow per-bead reachability probe (DRY_RUN=1, new-daemon NOT forced sensitive)
  #   bead-scoped FRESHNESS re-probe    (DRY_RUN=1, new-daemon forced sensitive) —
  #     emulates the REAL already_fresh() tiers: pid-start S vs the commit time of
  #     POST_DEPLOY_SHA (stale below it), then vs the DEPLOY_EPOCH it was GIVEN
  #     (verified above it, correlation-only not_verified between the two)
  #   the WIDE sweep (DRY_RUN=0)        — red for an unrelated daemon, PROOF=not_verified
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  case " \$SENSITIVE_DAEMONS " in
    *" com.test.new-daemon "*)
      echo "\$DEPLOY_EPOCH" > "$T/reprobe.epoch"
      CE="\$(git -C "\$RUNTIME_DIR" show -s --format=%ct "\$POST_DEPLOY_SHA")"
      echo "AFFECTED=com.test.new-daemon"
      echo "AFFECTED_NOT_RUNNING="
      echo "RESTARTED="
      echo "FRESH_FAIL="
      echo "ALL_LABELS="
      if [ $S -le "\$CE" ]; then
        echo "VERDICT=NEEDS_GUARDED_RESTART"; echo "GUARDED=com.test.new-daemon"
        echo "GUARDED_OWN=com.test.new-daemon"; echo "REASON=still stale"
        echo "PROOF=not_verified"; exit 1
      fi
      if [ $S -gt "\$DEPLOY_EPOCH" ]; then P=verified; else P=not_verified; fi
      echo "VERDICT=OK"; echo "GUARDED="; echo "REASON=already fresh"; echo "PROOF=\$P"
      exit 0
      ;;
    *)
      echo "VERDICT=OK"; echo "AFFECTED=com.test.new-daemon"; echo "AFFECTED_NOT_RUNNING="
      echo "RESTARTED="; echo "FRESH_FAIL="; echo "GUARDED="
      echo "REASON=dry-run per-bead probe"; echo "ALL_LABELS="; echo "PROOF=not_applicable"
      exit 0
      ;;
  esac
else
  echo "VERDICT=NEEDS_GUARDED_RESTART"; echo "AFFECTED=com.test.old-daemon"
  echo "RESTARTED="; echo "FRESH_FAIL="; echo "GUARDED=com.test.old-daemon"
  echo "GUARDED_OWN=com.test.old-daemon"
  echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
  echo "ALL_LABELS=com.test.old-daemon"; echo "PROOF=not_verified"
  exit 1
fi
EOF

  EXPECT_C2="$SHA_C2"; EXPECT_C1="$SHA_C1"
  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"; PROOF_OUT="$T/proof.out"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO_RT"
  local DEPLOY_EPOCH="$D"
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # True no-op pull (Path B, like the sibling test): the narrow per-bead probe
  # fires, and MERGE_SHA is the story's own tip.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo ""; }

  # The echo after the loop runs on the halt path too (`continue` only ends the
  # once-loop), so REFRESH_PROOF is captured whichever way the block exits.
  ( for _t in _once; do eval "$BLOCK"; done; echo "${REFRESH_PROOF:-<unset>}" > "$PROOF_OUT" ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  PROOF_AFTER="$(cat "$PROOF_OUT" 2>/dev/null || echo "<missing>")"
  REPROBE_EPOCH="$(cat "$T/reprobe.epoch" 2>/dev/null || echo "<probe-not-run>")"
  BASELINE_AFTER="$(cat "$BASELINE_FILE_ABS" 2>/dev/null || echo "<missing>")"
  rm -rf "$T"
}

# ── T1: the fix — daemon restarted AFTER the merge landed (3500) but BEFORE
#    this retry's DEPLOY_EPOCH (5000) ─────────────────────────────────────────
run_block 4000 landed 5000
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean" || nok "T1 rc" "rc=$RUN_RC"
[ "$REPROBE_EPOCH" = "3500" ] \
  && ok "T1 the re-probe was floored at the merge's ARRIVAL (3500), not this iteration's DEPLOY_EPOCH (5000)" \
  || nok "T1 re-probe floor" "want=3500 got=$REPROBE_EPOCH"
[ "$PROOF_AFTER" = "verified" ] \
  && ok "T1 REFRESH_PROOF=verified — the bead-scoped probe's answer replaced the window's not_verified (no delivery:daemon-unverified at Step 8)" \
  || nok "T1 REFRESH_PROOF" "want=verified got=$PROOF_AFTER"
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && nok "T1 story was wrongly held" "$BD_CALLS" || ok "T1 story is released (not held)"
echo "$LOG_OUT" | grep -q "proof is bead-scoped" \
  && ok "T1 the override is logged, naming the window proof it replaced" \
  || nok "T1 override not logged" "$LOG_OUT"
echo "$LOG_OUT" | grep -q "freshness floor 3500: merge arrived in the runtime at 3500, this deploy started 5000" \
  && ok "T1 the re-probe log line records floor / arrival / deploy epoch" \
  || nok "T1 re-probe log line" "$LOG_OUT"
[ "$BASELINE_AFTER" = "$EXPECT_C2" ] \
  && ok "T1 the release semantics are unchanged: rig-wide baseline marker advanced" \
  || nok "T1 baseline marker" "want=$EXPECT_C2 got=$BASELINE_AFTER"

# ── T2: respawn in the (commit 3000, arrival 3500] gap — the checkout still held
#    the OLD code. Must NOT read as verified (the reason the tier exists). ─────
run_block 3200 landed 5000
[ "$REPROBE_EPOCH" = "3500" ] && ok "T2 floor is the arrival (3500)" || nok "T2 floor" "got=$REPROBE_EPOCH"
[ "$PROOF_AFTER" = "not_verified" ] \
  && ok "T2 a daemon that started after the COMMIT but BEFORE the code arrived stays not_verified — the floor never reaches back before the code was in the checkout" \
  || nok "T2 false verified" "want=not_verified got=$PROOF_AFTER"
echo "$LOG_OUT" | grep -q "proof is bead-scoped" \
  && nok "T2 override wrongly fired" "$LOG_OUT" || ok "T2 no override logged"

# ── T3: arrival cannot be proven (the runtime never received the merge) ─────────
run_block 4000 never 5000
[ "$REPROBE_EPOCH" = "5000" ] \
  && ok "T3 unprovable arrival -> the floor stays DEPLOY_EPOCH (5000), never a guessed value" \
  || nok "T3 floor" "want=5000 got=$REPROBE_EPOCH"
[ "$PROOF_AFTER" = "not_verified" ] \
  && ok "T3 no override: the window's fail-closed not_verified stands" \
  || nok "T3 REFRESH_PROOF" "want=not_verified got=$PROOF_AFTER"
echo "$LOG_OUT" | grep -q "merge arrived in the runtime at unknown" \
  && ok "T3 the log says the arrival is unknown" || nok "T3 log" "$LOG_OUT"

# ── T4: arrival LATER than this iteration's DEPLOY_EPOCH -> never raised ───────
run_block 5500 late 5000
[ "$REPROBE_EPOCH" = "5000" ] \
  && ok "T4 the floor is only ever LOWERED: a later arrival (6000) leaves DEPLOY_EPOCH (5000)" \
  || nok "T4 floor" "want=5000 got=$REPROBE_EPOCH"

# ── T5: control — the daemon is older than the merge's commit: still stale ─────
run_block 2500 landed 5000
echo "$BD_CALLS" | grep -q "delivery:failed" \
  && ok "T5 a confirmed-stale daemon still holds the delivery" \
  || nok "T5 stale daemon was not held" "$BD_CALLS"
[ "$PROOF_AFTER" = "not_verified" ] \
  && ok "T5 no proof override on a hold" || nok "T5 REFRESH_PROOF" "got=$PROOF_AFTER"
[ "$BASELINE_AFTER" = "$EXPECT_C1" ] \
  && ok "T5 baseline marker did not advance" || nok "T5 baseline" "want=$EXPECT_C1 got=$BASELINE_AFTER"

# ── T6: wiring — Step 8 still keys the label off REFRESH_PROOF ─────────────────
n="$(grep -c 'verified|not_applicable|asset_served_per_request) : ;;' "$DELIVERY")"
[ "$n" -ge 2 ] \
  && ok "T6 Step 8 (label + done-wording) still branches on REFRESH_PROOF, so a bead-scoped verified means no delivery:daemon-unverified" \
  || nok "T6 Step 8 wiring" "found $n case arms"

echo ""
echo "story-delivery bead re-probe arrival-floor (ga-c3oyk6) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
