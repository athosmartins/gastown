#!/usr/bin/env bash
# story-delivery-human-confirmed-release.test.sh — regression test for ga-xrn8ni
# (extracts the real Step 5b block from story-delivery.sh, no duplication — same
# technique as story-delivery-locked-cosmetic-release.test.sh, which this file
# mirrors closely).
#
# THE BUG (wa-8yfoi 24/09): a merge's only new symbols had ZERO callers anywhere
# except a standalone backfill script + its own test — confirmed by a human via
# repo-wide grep, 3 independent times over 90 minutes. The 16 daemons this merge
# reaches are SENSITIVE but NOT notify_only_locked in restart_policy.yaml (they
# are just missing a DRAIN_CMD_<label>), so ga-j3lh6p's locked-cosmetic split
# (which requires GUARDED_LOCKED_COSMETIC — daemon-refresh.sh's own notify_only_
# locked + no-call-graph-path proof) never applies to them: they stay in
# MERGE_OWN_ACTIONABLE_STALE no matter what. Removing delivery:failed by hand did
# not stick either: delivery:deploy-pending re-arms story:approved every sweep
# (ga-iwv0), so the next cycle re-derives the identical HALT from scratch. Held
# forever, no escape — same shape ga-j3lh6p fixed for the locked case, but this
# daemon may not be locked at all.
#
# THE FIX: a human who does the exact verification the hold demands can record
# it as a delivery:symbol-confirmed-unreachable:<merge-sha>:<daemon> label on the
# bead. Step 5b now also excuses a still-stale daemon covered by such a label,
# narrowly: positive membership only, naming BOTH the exact merge commit AND the
# specific daemon — a label for a different sha (a stale confirmation) or a
# different daemon excuses nothing, same fail-closed default as everywhere else
# in this file. This mirrors locked-cosmetic's eligibility discipline on a
# different (human-attested, not automation-attested) evidence source, with its
# own proof tier (symbol_unreachable_human_confirmed) and own label
# (delivery:daemon-stale-human-confirmed) — never folded into
# symbol_unreachable_locked, which specifically claims notify_only_locked status
# this daemon may not have.
#
# T1  (the repro — RED before the fix): the one stale daemon is SENSITIVE, NOT
#     locked (GUARDED_LOCKED_COSMETIC empty), and carries a label naming this
#     exact merge sha -> NOT held, evidence recorded on the bead, rig-wide
#     marker untouched, proof tier says what was actually established.
# T2  (control — RED before the fix would also incorrectly hold; but this checks
#     the fix does NOT over-release): the label names a DIFFERENT (stale) merge
#     sha -> still held. A confirmation the merge has since invalidated excuses
#     nothing.
# T3  (control): the label names a DIFFERENT daemon -> still held. Every stale
#     daemon must be covered BY NAME.
# T4  (control, the most important negative): NO label at all -> still held.
#     This is the fix's own restraint — it must never blanket-release every
#     SENSITIVE-no-drain-path daemon, only ones a human explicitly confirmed.
# T5  (mixed — partial): one human-confirmed daemon AND one ordinary stale
#     daemon with no label -> still held (the ordinary one is real work), but
#     the halt's "restart THESE" list must NOT tell a human to restart the
#     confirmed-unreachable one, and must still name it and why it's excluded.
# T6  (mixed evidence sources — full release): one daemon excused by the
#     existing locked-cosmetic evidence (ga-j3lh6p) AND one by this fix's
#     human-attested label, together covering every still-stale daemon -> NOT
#     held, state is 'human-confirmed' (not 'locked-cosmetic' — at least one
#     daemon here rests on human, not automated, evidence), and the recorded
#     comment names both.

# No `pipefail` at file level (ga-uel7sb) — see the locked-cosmetic test for
# why: `X | grep ...` assertions under `set -o pipefail` can SIGPIPE-race a
# multi-KB variable and misreport a PASS as FAIL. The block under test still
# runs WITH pipefail (see run_block), as in production.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# has <haystack> <needle> — literal substring test with NO pipe (see the
# locked-cosmetic test's own comment for the SIGPIPE-race this avoids).
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"
SENSITIVE="com.test.sensitive-nodrain-daemon"
LOCKED="com.test.locked-daemon"
PLAIN="com.test.plain-daemon"

# reprobe_lines <mode> -> the KEY=value lines the bead-scoped freshness re-probe prints
reprobe_lines() {
  local mode="$1"
  case "$mode" in
    single_sensitive)  # T1-T4: one SENSITIVE, NOT-locked daemon still stale
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$SENSITIVE
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$SENSITIVE
GUARDED_OWN=
GUARDED_CLOSURE_ONLY=$SENSITIVE
GUARDED_SYMBOL_CONFIRMED=
GUARDED_SYMBOL_NO_EVIDENCE=$SENSITIVE
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=
REASON=freshness re-probe: still stale, SENSITIVE with no drain path, not locked
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    mixed_human_and_plain)  # T5
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$SENSITIVE $PLAIN
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$SENSITIVE $PLAIN
GUARDED_OWN=$PLAIN
GUARDED_CLOSURE_ONLY=$SENSITIVE
GUARDED_SYMBOL_CONFIRMED=$PLAIN
GUARDED_SYMBOL_NO_EVIDENCE=$SENSITIVE
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=
REASON=freshness re-probe: one human-confirmed, one ordinary stale
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    mixed_locked_and_human)  # T6
      cat <<EOF
VERDICT=NEEDS_GUARDED_RESTART
AFFECTED=$LOCKED $SENSITIVE
AFFECTED_NOT_RUNNING=
RESTARTED=
FRESH_FAIL=
GUARDED=$LOCKED $SENSITIVE
GUARDED_OWN=$SENSITIVE
GUARDED_CLOSURE_ONLY=$LOCKED
GUARDED_SYMBOL_CONFIRMED=
GUARDED_SYMBOL_NO_EVIDENCE=$LOCKED $SENSITIVE
GUARDED_SYMBOL_NOT_COMPUTED=
GUARDED_LOCKED_COSMETIC=$LOCKED
REASON=freshness re-probe: one locked-cosmetic, one human-confirmed
PROOF=not_verified
ALL_LABELS=
EOF
      ;;
    *) echo "reprobe_lines: unknown mode '$mode'" >&2; return 1 ;;
  esac
}

# story_labels_for <mode> <merge_sha> -> the Step-1 STORY_LABELS snapshot (comma-joined)
story_labels_for() {
  local mode="$1" sha="$2"
  case "$mode" in
    human_confirmed|mixed_human_and_plain|mixed_locked_and_human)
      echo "ctx:ready,delivery:symbol-confirmed-unreachable:${sha}:${SENSITIVE}"
      ;;
    human_confirmed_wrong_sha)
      echo "ctx:ready,delivery:symbol-confirmed-unreachable:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef:${SENSITIVE}"
      ;;
    human_confirmed_wrong_daemon)
      echo "ctx:ready,delivery:symbol-confirmed-unreachable:${sha}:com.test.some-other-daemon"
      ;;
    no_label)
      echo "ctx:ready"
      ;;
    *)
      echo ""
      ;;
  esac
}

# run_block <mode> [<reprobe_mode>] — <reprobe_mode> defaults to <mode> except for
# the T2-T4 controls, which all reuse the single_sensitive reprobe shape and vary
# only STORY_LABELS.
run_block() {
  local mode="$1"
  local reprobe_mode="${2:-$mode}"
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
  reprobe_lines "$reprobe_mode" > "$T/reprobe.out" || { rm -rf "$T"; return 1; }
  local narrow_affected="$SENSITIVE"
  case "$reprobe_mode" in
    mixed_human_and_plain)   narrow_affected="$SENSITIVE $PLAIN" ;;
    mixed_locked_and_human)  narrow_affected="$LOCKED $SENSITIVE" ;;
  esac

  # Fake daemon-refresh.sh — same three-call-shape contract as the
  # locked-cosmetic test (see its own comment for the full rationale):
  #   1. DRY_RUN=1, SENSITIVE_DAEMONS does NOT name any test daemon: Path B —
  #      reports what the merge reaches.
  #   2. DRY_RUN=1, SENSITIVE_DAEMONS DOES name one: the freshness re-probe —
  #      prints $T/reprobe.out (the mode under test).
  #   3. DRY_RUN!=1: the WIDE sweep — off this bead's radar entirely.
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
if [ "\$DRY_RUN" = "1" ]; then
  case " \$SENSITIVE_DAEMONS " in
    *" $LOCKED "*|*" $SENSITIVE "*|*" $PLAIN "*)
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
  local STORY_LABELS; STORY_LABELS="$(story_labels_for "$mode" "$SHA_C2")"
  # True no-op pull — the per-bead probe (Path B) fires, exactly like the real
  # wa-8yfoi run.
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo ""; }

  # Read the block's own conclusions out of the subshell — the state the story
  # leaves this block in is what Step 6/8 then act on.
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

# ── T1: THE REPRO — SENSITIVE, not locked, human-confirmed for this exact sha ──
run_block human_confirmed single_sensitive
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean" || nok "T1 rc" "rc=$RUN_RC vars=[$VARS_OUT]"
held && nok "T1 story WAS held (delivery:failed + delivery:deploy-pending) for a daemon a human confirmed unreachable for this exact merge — the bug" "$BD_CALLS" \
     || ok "T1 story is NOT held (no delivery:failed / delivery:deploy-pending)"
halt_seen && nok "T1 a 'Delivery HALTED' comment was posted" "$BD_CALLS" || ok "T1 no HALT comment"
has "$BD_CALLS" "comment ga-test" && has "$BD_CALLS" "$SENSITIVE" && has "$BD_CALLS" "ga-xrn8ni" \
  && ok "T1 the release is RECORDED on the bead: names the daemon and cites ga-xrn8ni" \
  || nok "T1 no evidence comment naming the daemon + ga-xrn8ni" "$BD_CALLS"
has "$BD_CALLS" "$EXPECT_C1..$EXPECT_C2" \
  && ok "T1 the evidence names the merge range that was examined ($EXPECT_C1..$EXPECT_C2)" \
  || nok "T1 evidence does not name the examined range" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] \
  && ok "T1 rig-wide baseline marker did NOT advance (this evidence is about THIS merge only)" \
  || nok "T1 baseline marker changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"
has "$VARS_OUT" "STATE=human-confirmed" && ok "T1 re-probe state is 'human-confirmed'" || nok "T1 state" "$VARS_OUT"
has "$VARS_OUT" "PROOF=symbol_unreachable_human_confirmed" \
  && ok "T1 proof tier is symbol_unreachable_human_confirmed (own tier — not folded into symbol_unreachable_locked)" \
  || nok "T1 proof tier" "$VARS_OUT"
has "$(printf %s "$LOG_OUT" | tr "[:upper:]" "[:lower:]")" "not holding" && ok "T1 log says the delivery is not held" || nok "T1 log" "$LOG_OUT"

# ── T2: CONTROL — label names a DIFFERENT (stale) merge sha: still held ───────
run_block human_confirmed_wrong_sha single_sensitive
held && ok "T2 a label for a DIFFERENT merge sha does not excuse this merge's staleness — still HELD" \
     || nok "T2 story was released on a stale (wrong-sha) confirmation" "$BD_CALLS"
halt_seen && ok "T2 HALT comment posted" || nok "T2 missing HALT comment" "$BD_CALLS"
has "$VARS_OUT" "STATE=stale" && ok "T2 state stays 'stale'" || nok "T2 state" "$VARS_OUT"

# ── T3: CONTROL — label names a DIFFERENT daemon: still held ──────────────────
run_block human_confirmed_wrong_daemon single_sensitive
held && ok "T3 a label naming a DIFFERENT daemon does not cover the stale one — still HELD" \
     || nok "T3 story was released though the confirmed daemon is not the stale one" "$BD_CALLS"
halt_seen && ok "T3 HALT comment posted" || nok "T3 missing HALT comment" "$BD_CALLS"

# ── T4: CONTROL (most important negative) — NO label at all: still held ───────
run_block no_label single_sensitive
held && ok "T4 a SENSITIVE not-locked daemon with NO confirmation label is still HELD (the fix never blanket-releases — only an explicit per-merge, per-daemon label does)" \
     || nok "T4 story was released with no human confirmation at all" "$BD_CALLS"
halt_seen && ok "T4 HALT comment posted" || nok "T4 missing HALT comment" "$BD_CALLS"
has "$VARS_OUT" "STATE=stale" && ok "T4 state stays 'stale'" || nok "T4 state" "$VARS_OUT"

# ── T5: MIXED (partial) — one human-confirmed, one ordinary stale: still HELD,
#    but the halt must not tell a human to restart the confirmed one ──────────
run_block mixed_human_and_plain
held && ok "T5 story is still HELD (the ordinary stale daemon is real work)" \
     || nok "T5 story was released though an ordinary daemon is still stale" "$BD_CALLS"
ACTION_LINE="$(grep 'ACTION: restart THESE' <<<"$BD_CALLS" | head -1)"
if [ -n "$ACTION_LINE" ]; then
  has "$ACTION_LINE" "$PLAIN" && ok "T5 the 'restart THESE' list names the ordinary stale daemon" || nok "T5 list lacks $PLAIN" "$ACTION_LINE"
  has "$ACTION_LINE" "$SENSITIVE" && nok "T5 the 'restart THESE' list tells a human to restart the human-confirmed-unreachable daemon" "$ACTION_LINE" \
                                  || ok "T5 the human-confirmed daemon is NOT in the 'restart THESE' list"
else
  nok "T5 no 'ACTION: restart THESE' line in the halt" "$BD_CALLS"
fi
has "$BD_CALLS" "$SENSITIVE" && has "$BD_CALLS" "ga-xrn8ni" \
  && ok "T5 the halt still MENTIONS the human-confirmed daemon it left out, and why (ga-xrn8ni)" \
  || nok "T5 the human-confirmed daemon silently vanished from the halt" "$BD_CALLS"

# ── T6: MIXED EVIDENCE SOURCES — locked-cosmetic + human-confirmed together
#    cover every stale daemon: full release, state names the WEAKER evidence ──
run_block mixed_locked_and_human
held && nok "T6 story WAS held though every stale daemon is excused (one locked-cosmetic, one human-confirmed)" "$BD_CALLS" \
     || ok "T6 story is NOT held (both daemons excused between the two evidence sources)"
has "$VARS_OUT" "STATE=human-confirmed" \
  && ok "T6 state is 'human-confirmed' (at least one daemon here rests on human, not automated, evidence — must not read as pure locked-cosmetic)" \
  || nok "T6 state" "$VARS_OUT"
has "$VARS_OUT" "PROOF=symbol_unreachable_human_confirmed" && ok "T6 proof tier reflects the human-attested component" || nok "T6 proof tier" "$VARS_OUT"
has "$BD_CALLS" "$LOCKED" && ok "T6 the recorded comment names the locked-cosmetic daemon" || nok "T6 comment missing locked daemon $LOCKED" "$BD_CALLS"
has "$BD_CALLS" "$SENSITIVE" && ok "T6 the recorded comment names the human-confirmed daemon" || nok "T6 comment missing confirmed daemon $SENSITIVE" "$BD_CALLS"
[ "$BASELINE_AFTER" = "$EXPECT_C0" ] && ok "T6 rig-wide baseline marker did NOT advance" || nok "T6 baseline marker changed" "want(unchanged)=$EXPECT_C0 got=$BASELINE_AFTER"

echo ""
echo "story-delivery human-confirmed release tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
