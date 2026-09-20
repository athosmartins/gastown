#!/usr/bin/env bash
# story-delivery-locked-cosmetic-release.test.sh — regression test for ga-j3lh6p
# (extracts the real Step 5b block from story-delivery.sh, no duplication — same
# technique as story-delivery-guarded-restart-freshness-reprobe.test.sh).
#
# THE BUG (wa-z66jb 20/09, wa-ho1ol same day): a story's merge touched a shared
# lib that com.whatsapp.demand-dashboard imports. That daemon is
# notify_only_locked in restart_policy.yaml ("Trava humana: NUNCA auto" — it
# hosts the outreach_worker in-process, a restart halts outreach), so NO
# automation ever restarts it. The bead-scoped freshness re-probe (ga-8i2nds)
# correctly reported it stale ("VERDICT=NEEDS_GUARDED_RESTART
# still-stale=[com.whatsapp.demand-dashboard]"), and Step 5b held the story as
# delivery:failed + delivery:deploy-pending — FOREVER, because nothing can ever
# make that daemon fresh. The Mayor closed each by hand after ~20min of
# investigation. The helper's own report already said why it was cosmetic: the
# symbol split found NO call-graph path from the daemon's entrypoint to any
# symbol changed in this merge. Nothing read it.
#
# THE FIX: daemon-refresh.sh now names, in GUARDED_LOCKED_COSMETIC, the GUARDED
# subset that is BOTH locked against automation AND cleanly evaluated to "no
# path". Step 5b releases a story ONLY when EVERY still-stale daemon of the
# re-probe is in that set — positive membership evidence, never an emptiness
# inferred from a missing field.
#
# T1  (the repro — RED before the fix): re-probe = the locked demand-dashboard,
#     still stale, GUARDED_LOCKED_COSMETIC names it -> NOT held, evidence
#     recorded on the bead, rig-wide marker untouched, and the proof tier says
#     what was actually established (not "verified", not the alarming
#     "may still be dormant" — see symbol_unreachable_locked).
# T2  (control, acceptance 2): the symbol IS reached (CONFIRMED) -> still held.
#     This bead must NEVER become "ignore notify_only_locked".
# T3  (control, acceptance 3): the calculator never answered (NOT_COMPUTED) ->
#     still held. Not-computed must not read as no-evidence.
# T4  (control): an OLDER helper that predates the field (no GUARDED_LOCKED_
#     COSMETIC line at all) -> still held. Absent != empty.
# T5  (mixed — RED before the fix): one locked+cosmetic daemon AND one ordinary
#     stale daemon -> still held (the ordinary one is real work), but the halt's
#     "restart THESE" list must NOT tell a human to restart the locked daemon
#     (a restart halts outreach and buys nothing here).
# T6  (control): a verdict other than NEEDS_GUARDED_RESTART (JOB_NOT_INSTALLED)
#     carrying a cosmetic line -> still held; the split cannot excuse a job that
#     never ran.
# T7  (control): the cosmetic line names a label that is NOT the stale one ->
#     still held (every stale label must be covered, by name).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# has <haystack> <needle> — literal substring test with NO pipe. Under `pipefail`,
# `echo "$BIG" | grep -q pat` is a SIGPIPE race: grep -q exits on the first match
# while echo is still writing a multi-KB variable (macOS BUFSIZ is 1024), the
# pipeline reports 141, and the whole && chain flips — measured here: `held` read
# false with both labels plainly present, and on an UNTOUCHED origin/main the
# neighbouring proof-honesty test failed 2 of 14 runs the same way. A case
# pattern has no writer process to kill.
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"
LOCKED="com.test.demand-dashboard"
PLAIN="com.test.plain-daemon"

# reprobe_lines <mode> -> the KEY=value lines the bead-scoped freshness re-probe prints
reprobe_lines() {
  local mode="$1"
  case "$mode" in
    locked_cosmetic)   # T1
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED
GUARDED_OWN=
GUARDED_CLOSURE_ONLY=$LOCKED
GUARDED_SYMBOL_CONFIRMED=
GUARDED_SYMBOL_NO_EVIDENCE=$LOCKED
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=$LOCKED
REASON=freshness re-probe: still stale, locked, no symbol evidence
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    locked_confirmed)  # T2
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED
GUARDED_OWN=$LOCKED
GUARDED_CLOSURE_ONLY=
GUARDED_SYMBOL_CONFIRMED=$LOCKED
GUARDED_SYMBOL_NO_EVIDENCE=
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=
REASON=freshness re-probe: still stale, symbol reached
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    locked_not_computed) # T3
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED
GUARDED_OWN=
GUARDED_CLOSURE_ONLY=$LOCKED
GUARDED_SYMBOL_CONFIRMED=
GUARDED_SYMBOL_NO_EVIDENCE=
GUARDED_SYMBOL_NOT_COMPUTED=$LOCKED
GUARDED_LOCKED_COSMETIC=
REASON=freshness re-probe: still stale, calculator gave no answer
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    old_producer)      # T4 — a helper that predates GUARDED_LOCKED_COSMETIC (and the symbol split)
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED
GUARDED_OWN=
GUARDED_CLOSURE_ONLY=$LOCKED
REASON=freshness re-probe: still stale (older helper)
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    mixed)             # T5 — locked+cosmetic AND an ordinary stale daemon
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED $PLAIN
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED $PLAIN
GUARDED_OWN=$PLAIN
GUARDED_CLOSURE_ONLY=$LOCKED
GUARDED_SYMBOL_CONFIRMED=$PLAIN
GUARDED_SYMBOL_NO_EVIDENCE=$LOCKED
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=$LOCKED
REASON=freshness re-probe: one real stale, one cosmetic-locked
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    wrong_verdict)     # T6
      cat <<EOF
VERDICT=JOB_NOT_INSTALLED
AFFECTED=$LOCKED
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED
GUARDED_OWN=
GUARDED_CLOSURE_ONLY=$LOCKED
GUARDED_SYMBOL_CONFIRMED=
GUARDED_SYMBOL_NO_EVIDENCE=$LOCKED
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=$LOCKED
REASON=a scheduled job this merge ships was never installed
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    foreign_label)     # T7 — cosmetic names a label that is not the stale one
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED
GUARDED_OWN=
GUARDED_CLOSURE_ONLY=$LOCKED
GUARDED_SYMBOL_CONFIRMED=
GUARDED_SYMBOL_NO_EVIDENCE=
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=com.test.some-other-daemon
REASON=freshness re-probe: cosmetic line names somebody else
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    *) echo "reprobe_lines: unknown mode '$mode'" >&2; return 1 ;;
  esac
}

# run_block <mode>
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

  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
  BASELINE_FILE_ABS="$GC_CITY/$MARKER_REL"

  # The re-probe's stdout, verbatim, in a file the fake helper cats.
  reprobe_lines "$mode" > "$T/reprobe.out" || { rm -rf "$T"; return 1; }
  local narrow_affected="$LOCKED"
  [ "$mode" = "mixed" ] && narrow_affected="$LOCKED $PLAIN"

  # Fake daemon-refresh.sh — three call shapes share this one script:
  #   1. DRY_RUN=1, SENSITIVE_DAEMONS does NOT name the locked daemon: the
  #      per-bead reachability probe (Path B) — reports what the merge reaches.
  #   2. DRY_RUN=1, SENSITIVE_DAEMONS DOES name it: the freshness re-probe —
  #      prints $T/reprobe.out (the mode under test).
  #   3. DRY_RUN!=1: the WIDE sweep — GUARDED is an unrelated old-daemon only,
  #      the story's own daemon is off its radar (the real wa-z66jb shape:
  #      "wide-window overlap: [none]").
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  case " \$SENSITIVE_DAEMONS " in
    *" $LOCKED "*)
      cat "$T/reprobe.out"
      exit 1
      ;;
    *)
      echo "VERDICT=OK"
      echo "AFFECTED=$narrow_affected"
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
  # True no-op pull — the per-bead probe (Path B) fires, exactly like the real
  # wa-z66jb run ("this-iteration-pull pre=72e1b4a post=72e1b4a").
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo ""; }

  # Read the block's own conclusions out of the subshell — the state the story
  # leaves this block in is what Step 6/8 then act on.
  ( for _t in _once; do eval "$BLOCK"; done
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

# ── T1: THE REPRO — locked + no symbol evidence: must NOT be held ─────────────
run_block locked_cosmetic
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean" || nok "T1 rc" "rc=$RUN_RC vars=[$VARS_OUT]"
held && nok "T1 story WAS held (delivery:failed + delivery:deploy-pending) for a locked daemon the symbol split proves cosmetic — the bug" "$BD_CALLS" \
     || ok "T1 story is NOT held (no delivery:failed / delivery:deploy-pending)"
halt_seen && nok "T1 a 'Delivery HALTED' comment was posted" "$BD_CALLS" || ok "T1 no HALT comment"
has "$BD_CALLS" "comment ga-test" && has "$BD_CALLS" "$LOCKED" && has "$BD_CALLS" "notify_only_locked" \
  && ok "T1 the release is RECORDED on the bead: names the daemon and the reason (notify_only_locked)" \
  || nok "T1 no evidence comment naming the daemon + notify_only_locked" "$BD_CALLS"
has "$BD_CALLS" "$EXPECT_C1..$EXPECT_C2" \
  && ok "T1 the evidence names the merge range that was examined ($EXPECT_C1..$EXPECT_C2)" \
  || nok "T1 evidence does not name the examined range" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T1 rig-wide baseline marker did NOT advance (this evidence is about THIS merge only — a sibling's window must not be skipped)" \
  || nok "T1 baseline marker changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"
has "$VARS_OUT" "STATE=locked-cosmetic" && ok "T1 re-probe state is 'locked-cosmetic'" || nok "T1 state" "$VARS_OUT"
has "$VARS_OUT" "PROOF=symbol_unreachable_locked" \
  && ok "T1 proof tier is symbol_unreachable_locked (what was actually established — not 'verified', not 'not_verified')" \
  || nok "T1 proof tier" "$VARS_OUT"
has "$(printf %s "$LOG_OUT" | tr "[:upper:]" "[:lower:]")" "not holding" && ok "T1 log says the delivery is not held" || nok "T1 log" "$LOG_OUT"

# ── T2: CONTROL — the symbol IS reached: still held (acceptance 2) ────────────
run_block locked_confirmed
held && ok "T2 a locked daemon whose symbol IS reached is still HELD (never 'ignore notify_only_locked')" \
     || nok "T2 story was released though the symbol split says CONFIRMED" "$BD_CALLS"
halt_seen && ok "T2 HALT comment posted" || nok "T2 missing HALT comment" "$BD_CALLS"
has "$VARS_OUT" "STATE=stale" && ok "T2 state stays 'stale'" || nok "T2 state" "$VARS_OUT"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] && ok "T2 marker unchanged" || nok "T2 marker" "$BASELINE_AFTER"

# ── T3: CONTROL — the calculator never answered: still held (acceptance 3) ────
run_block locked_not_computed
held && ok "T3 NOT_COMPUTED is still HELD (not-computed must never read as no-evidence)" \
     || nok "T3 story was released on a NOT_COMPUTED label" "$BD_CALLS"

# ── T4: CONTROL — an older helper without the field: still held ───────────────
run_block old_producer
held && ok "T4 a helper that predates GUARDED_LOCKED_COSMETIC is still HELD (absent != empty)" \
     || nok "T4 story was released though the helper never said anything about cosmetic" "$BD_CALLS"

# ── T5: MIXED — one ordinary stale daemon keeps the hold, but the halt must not
#    tell a human to restart the locked one ────────────────────────────────────
run_block mixed
held && ok "T5 story is still HELD (the ordinary stale daemon is real work)" \
     || nok "T5 story was released though an ordinary daemon is still stale" "$BD_CALLS"
ACTION_LINE="$(grep 'ACTION: restart THESE' <<<"$BD_CALLS" | head -1)"
if [ -n "$ACTION_LINE" ]; then
  has "$ACTION_LINE" "$PLAIN" && ok "T5 the 'restart THESE' list names the ordinary stale daemon" || nok "T5 list lacks $PLAIN" "$ACTION_LINE"
  has "$ACTION_LINE" "$LOCKED" && nok "T5 the 'restart THESE' list tells a human to restart the LOCKED daemon (a restart halts outreach and buys nothing here)" "$ACTION_LINE" \
                               || ok "T5 the locked cosmetic daemon is NOT in the 'restart THESE' list"
else
  nok "T5 no 'ACTION: restart THESE' line in the halt" "$BD_CALLS"
fi
has "$BD_CALLS" "notify_only_locked" \
  && ok "T5 the halt still MENTIONS the locked daemon it left out, and why" \
  || nok "T5 the locked daemon silently vanished from the halt (say why it was left out)" "$BD_CALLS"

# ── T6: CONTROL — a verdict other than NEEDS_GUARDED_RESTART: still held ──────
run_block wrong_verdict
held && ok "T6 JOB_NOT_INSTALLED carrying a cosmetic line is still HELD (the split cannot excuse a job that never ran)" \
     || nok "T6 story was released on a non-NEEDS_GUARDED_RESTART verdict" "$BD_CALLS"

# ── T7: CONTROL — the cosmetic line names a label that is not the stale one ───
run_block foreign_label
held && ok "T7 a cosmetic line naming a DIFFERENT label does not cover the stale one — still HELD" \
     || nok "T7 story was released though the stale label is not in the cosmetic set" "$BD_CALLS"

echo ""
echo "story-delivery locked-cosmetic release tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
