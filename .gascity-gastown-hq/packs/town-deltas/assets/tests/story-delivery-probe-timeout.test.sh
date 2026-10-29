#!/usr/bin/env bash
# story-delivery-probe-timeout.test.sh — regression test for ga-hm8i53s
# (extracts the real Step 5b block from story-delivery.sh, no duplication —
# same technique as story-delivery-daemon-refresh-noop-attribution.test.sh).
#
# THE BUG (measured 29/10 on wa-1d97lb.17, .gc/logs/story-delivery.log): the
# per-story attribution probe (daemon-refresh.sh, DRY_RUN=1) logged
# "<unparseable output> affected=[] affected_not_running=[] affected_live=[]",
# attribution fell back to the rig-wide verdict, and a story whose own daemon
# was already fresh was held for two cosmetic daemons it never touched.
#
# ROOT CAUSE, measured over the whole log (not the "garbled stdout" the bead
# guessed): all 35 unreadable per-story probes and all 6 unreadable freshness
# re-probes took 180-187s — exactly `timeout 180` expiring; none failed
# faster. Readable probes run a median of 131s (p90 163s), so 24% of them
# already sat above 150s against a 180s budget. `|| true` plus
# `2>/dev/null` threw away the rc 124, so the log could not say "timed out",
# and the line printed `affected=[]` for "could not tell" — the same thing it
# prints for "reaches nothing".
#
# THE FIX under test:
#   1. the budget is DELIVERY_PROBE_TIMEOUT_S (default 300) at BOTH probe
#      sites; a value that is not a positive integer falls back to 300 — it
#      must never reach `timeout` as 0, which means "no limit at all";
#   2. rc and elapsed seconds are kept and the probe is classified
#      ok | timeout | failed | silent, printed as probe=<state> rc=<n>
#      elapsed=<s>s budget=<s>s; an unreadable probe prints affected=[?],
#      never affected=[];
#   3. when attribution is unavailable the delivery stays HELD (fail closed:
#      unreadable is never "reaches nothing") but the posted comment and the
#      author nudge say so, instead of telling the author to restart the
#      rig-wide list and asserting a dormant deploy nobody measured.
#
# P1 probe times out for real   -> probe=timeout rc=124 budget=1s, affected=[?],
#                                  held, comment says "could not be attributed"
# P2 probe prints nothing, rc=0  -> probe=silent
# P3 probe crashes, rc=3         -> probe=failed rc=3
# P4 budget parsing              -> unset/0/00/abc -> 300; 45 -> 45; a rejected value
#                                  is named in a WARN (unset/empty/valid are not)
# P5 control: probe answers      -> probe=ok, real affected list, old halt text
# P6 re-probe times out          -> "Freshness re-probe" line carries probe=timeout
# P7 two sweeps, same story      -> the halt-fingerprint dedup must not swallow a
#                                  change of attribution state: timeout→answer and
#                                  answer→timeout announce; the same state twice
#                                  stays silent (gate feedback on 4686821a7)
# P8 probe killed by a signal    -> a VERDICT= with no AFFECTED= behind it is a
#                                  cut-off answer, not "reaches nothing": failed
# P9 re-probe killed by a signal -> its "VERDICT=OK + empty GUARDED=" is not an
#                                  answer either: the delivery must NOT release
#                                  on it (control: the same two lines, exit 0,
#                                  do release)

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# -style pipes; the block under test still runs WITH `set -euo pipefail`, as in
# production (story-delivery.sh line 32).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable only so the A/B check ("does this test fail on the pre-fix
# block?") can point the block at the old script.
DELIVERY="${STORY_DELIVERY_BLOCK_SRC:-$SCRIPT_DIR/../story-delivery.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# run_block <stub_mode> [budget]
#   stub_mode: slow         per-story probe never answers inside the budget
#              silent       probe exits 0 and prints nothing
#              crash        probe prints to stderr only and exits 3
#              killed       probe prints "VERDICT=OK" and is then SIGKILLed
#                           (rc 137) before it gets to print AFFECTED=
#              termed       same, SIGTERM (rc 143)
#              ok           probe answers (NEEDS_GUARDED_RESTART + AFFECTED)
#              reprobe_slow per-story probe answers, the freshness re-probe
#                           (the 2nd DRY_RUN=1 call) never does
#              reprobe_clean  per-story probe answers, the re-probe answers
#                           "VERDICT=OK" + an empty "GUARDED=" and exits 0
#              reprobe_killed same two lines, then SIGKILL (rc 137)
#   budget:   value for DELIVERY_PROBE_TIMEOUT_S; "unset" leaves it unset.
#
# Fixture: C0 base -> C1 adds lib/sensitive_daemon_dep.py (the earlier cause of
# a rig-wide staleness) -> C2 is this story's own commit (also "sensitive").
# True no-op pull (PRE==POST==C2) so Path B runs the per-story probe, with the
# baseline marker at C0 so the wide window still sees C1.
# Sets globals: RUN_RC, LOG_OUT, BD_CALLS, GC_CALLS, REACHED, PROBE_CALLS.
#
# Every call builds a fresh $GC_CITY and deletes it, so each call is a FIRST
# sweep: the halt-fingerprint (the dedup state, one file per story) is gone.
# FP_CARRY=<file> makes consecutive calls the 1st, 2nd, ... sweep of the SAME
# story: the fingerprint is copied in before the block runs and back out after
# (a missing file after the run means the block removed it — the carry is
# removed too). Unset (the default) = fresh city every call, as P1–P6 expect.
FP_REL=".gc/runtime/daemon-refresh-baseline/halt-fingerprint/ga-test.txt"
run_block() {
  local stub_mode="$1" budget="${2-unset}"  # no colon: "" means set-but-empty
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/lib"
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo prod > "$REPO/lib/sensitive_daemon_dep.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo prod2 > "$REPO/lib/sensitive_daemon_dep2.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"
  if [ -n "${FP_CARRY:-}" ] && [ -f "$FP_CARRY" ]; then
    mkdir -p "$GC_CITY/$(dirname "$FP_REL")"; cp "$FP_CARRY" "$GC_CITY/$FP_REL"
  fi

  STUB_COUNT="$T/probe-count"; : > "$STUB_COUNT"
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
if [ "$DRY_RUN" = "1" ]; then
  n=$(cat "$STUB_COUNT" 2>/dev/null); n=$((${n:-0} + 1)); echo "$n" > "$STUB_COUNT"
  case "$STUB_MODE" in
    slow)         exec sleep 30 ;;
    silent)       exit 0 ;;
    killed)       echo "VERDICT=OK"; kill -KILL $$ ;;
    termed)       echo "VERDICT=OK"; kill -TERM $$ ;;
    crash)        echo "boom: launchctl list failed" >&2; exit 3 ;;
    reprobe_slow) [ "$n" -ge 2 ] && exec sleep 30 ;;
    reprobe_clean)  [ "$n" -ge 2 ] && { echo "VERDICT=OK"; echo "GUARDED="; exit 0; } ;;
    reprobe_killed) [ "$n" -ge 2 ] && { echo "VERDICT=OK"; echo "GUARDED="; kill -KILL $$; } ;;
  esac
fi
echo "VERDICT=NEEDS_GUARDED_RESTART"
echo "AFFECTED=com.test.central-sender"
echo "AFFECTED_NOT_RUNNING="
echo "RESTARTED="
echo "FRESH_FAIL="
echo "GUARDED=com.test.central-sender"
echo "REASON=sensitive hot-path daemon needs a guarded restart"
exit 1
EOF

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true
  export STUB_MODE="$stub_mode" STUB_COUNT

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local PRE_DEPLOY_SHA="$SHA_C2" POST_DEPLOY_SHA="$SHA_C2" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  local MERGE_SHA="$SHA_C2" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C1"
  get_runbook_field() { echo "central-sender"; }

  rm -f "$T/reached.marker"
  (
    set -euo pipefail
    if [ "$budget" = "unset" ]; then unset DELIVERY_PROBE_TIMEOUT_S; else export DELIVERY_PROBE_TIMEOUT_S="$budget"; fi
    for _t in _once; do eval "$BLOCK"; touch "$T/reached.marker"; done
  ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  PROBE_CALLS="$(cat "$STUB_COUNT" 2>/dev/null || true)"
  [ -f "$T/reached.marker" ] && REACHED=1 || REACHED=0
  if [ -n "${FP_CARRY:-}" ]; then
    if [ -f "$GC_CITY/$FP_REL" ]; then cp "$GC_CITY/$FP_REL" "$FP_CARRY"; else rm -f "$FP_CARRY"; fi
  fi
  rm -rf "$T"
}

probe_line()   { printf '%s\n' "$LOG_OUT" | grep 'Per-story attribution probe' | head -1; }
reprobe_line() { printf '%s\n' "$LOG_OUT" | grep 'Freshness re-probe for' | head -1; }

# ── P1: the incident — the probe really runs past its budget ────────────────
run_block slow 1
PL="$(probe_line)"
[ "$RUN_RC" -eq 0 ] && ok "P1 block survives a timed-out probe under set -euo pipefail (rc=0)" \
  || nok "P1 rc" "rc=$RUN_RC"
printf '%s' "$PL" | grep -F 'probe=timeout' >/dev/null && printf '%s' "$PL" | grep -F 'rc=124' >/dev/null \
  && ok "P1 log names the cause: probe=timeout rc=124" \
  || nok "P1 probe=timeout rc=124 missing from the probe line" "$PL"
printf '%s' "$PL" | grep -F 'budget=1s' >/dev/null \
  && ok "P1 log shows the budget actually used (budget=1s)" \
  || nok "P1 budget in log" "$PL"
printf '%s' "$PL" | grep -F 'elapsed=' >/dev/null \
  && ok "P1 log shows elapsed seconds (so the next measurement is uncensored)" \
  || nok "P1 elapsed in log" "$PL"
! printf '%s' "$PL" | grep -F '<unparseable output>' >/dev/null \
  && ok "P1 opaque '<unparseable output>' is gone from the probe line" \
  || nok "P1 still opaque" "$PL"
printf '%s' "$PL" | grep -F 'affected=[?]' >/dev/null \
  && ok "P1 unknown reach prints affected=[?] — not the affected=[] of 'reaches nothing'" \
  || nok "P1 affected=[?]" "$PL"
printf '%s\n' "$LOG_OUT" | grep 'this-pull-structurally-inert=unknown' >/dev/null \
  && ok "P1 unreadable probe never becomes 'inert' (still unknown)" \
  || nok "P1 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "P1 delivery is still HELD (fail closed: unreadable is never 'reaches nothing')" \
  || nok "P1 held" "REACHED=$REACHED"
printf '%s\n' "$BD_CALLS" | grep 'label add ga-test delivery:failed' >/dev/null \
  && ok "P1 hold mechanics unchanged (delivery:failed → retried every sweep)" \
  || nok "P1 failed label" "$BD_CALLS"
printf '%s\n' "$BD_CALLS" | grep -F 'could not be attributed' >/dev/null \
  && ok "P1 posted comment says the story could not be attributed" \
  || nok "P1 comment names the real cause" "$BD_CALLS"
! printf '%s\n' "$BD_CALLS" | grep -F 'perform a guarded/graceful restart of the flagged' >/dev/null \
  && ok "P1 comment no longer tells the author to restart the rig-wide list" \
  || nok "P1 still orders a rig-wide restart" "$BD_CALLS"
! printf '%s\n' "$BD_CALLS" | grep -F 'would be DORMANT in production' >/dev/null \
  && ok "P1 comment does not assert a dormant deploy nobody measured" \
  || nok "P1 still asserts DORMANT" "$BD_CALLS"
printf '%s\n' "$GC_CALLS" | grep 'session nudge crew/tester' | grep -F 'attribution' >/dev/null \
  && ok "P1 author nudge says attribution was unavailable" \
  || nok "P1 author nudge" "$GC_CALLS"
! printf '%s\n' "$GC_CALLS" | grep 'session nudge crew/tester' | grep -F 'dormant/unverified' >/dev/null \
  && ok "P1 author nudge no longer claims the story's daemon is dormant" \
  || nok "P1 author nudge still claims dormant" "$GC_CALLS"
printf '%s\n' "$GC_CALLS" | grep 'session nudge mayor' >/dev/null \
  && ok "P1 Mayor still nudged" || nok "P1 mayor nudge" "$GC_CALLS"

# ── P2: probe exits 0 and prints nothing ────────────────────────────────────
run_block silent
PL="$(probe_line)"
[ "$RUN_RC" -eq 0 ] && ok "P2 block survives a silent probe (rc=0)" || nok "P2 rc" "rc=$RUN_RC"
printf '%s' "$PL" | grep -F 'probe=silent' >/dev/null && printf '%s' "$PL" | grep -F 'rc=0' >/dev/null \
  && ok "P2 probe=silent rc=0" || nok "P2 probe=silent" "$PL"
printf '%s\n' "$BD_CALLS" | grep -F 'could not be attributed' >/dev/null \
  && ok "P2 comment says the story could not be attributed" || nok "P2 comment" "$BD_CALLS"

# ── P3: probe crashes ───────────────────────────────────────────────────────
run_block crash
PL="$(probe_line)"
[ "$RUN_RC" -eq 0 ] && ok "P3 block survives a crashing probe (rc=0)" || nok "P3 rc" "rc=$RUN_RC"
printf '%s' "$PL" | grep -F 'probe=failed' >/dev/null && printf '%s' "$PL" | grep -F 'rc=3' >/dev/null \
  && ok "P3 probe=failed rc=3" || nok "P3 probe=failed" "$PL"

# ── P4: budget parsing — never 'no limit', never garbage ────────────────────
run_block silent
printf '%s' "$(probe_line)" | grep -F 'budget=300s' >/dev/null \
  && ok "P4 unset → default budget is 300s (was 180s)" || nok "P4 default" "$(probe_line)"
for bad in 0 00 abc -5 "" 1.5; do
  run_block silent "$bad"
  printf '%s' "$(probe_line)" | grep -F 'budget=300s' >/dev/null \
    && ok "P4 DELIVERY_PROBE_TIMEOUT_S='$bad' falls back to 300s (never reaches timeout as 'no limit')" \
    || nok "P4 bad value '$bad'" "$(probe_line)"
done
run_block silent 45
printf '%s' "$(probe_line)" | grep -F 'budget=45s' >/dev/null \
  && ok "P4 DELIVERY_PROBE_TIMEOUT_S=45 is honoured" || nok "P4 override" "$(probe_line)"

# A rejected value must be NAMED in the log — a typo in the launchd plist must
# not silently leave the operator thinking another budget is in force. Unset,
# empty (= "not configured") and a valid value stay quiet.
budget_warns() { printf '%s\n' "$LOG_OUT" | grep -c 'DELIVERY_PROBE_TIMEOUT_S'; }
for bad in 0 00 abc -5 1.5; do
  run_block silent "$bad"
  printf '%s\n' "$LOG_OUT" | grep 'DELIVERY_PROBE_TIMEOUT_S' | grep -F "'$bad'" >/dev/null \
    && ok "P4 rejected DELIVERY_PROBE_TIMEOUT_S='$bad' is named in a WARN" \
    || nok "P4 no WARN naming '$bad'" "$LOG_OUT"
done
for good in unset "" 45 300 0300; do
  run_block silent "$good"
  [ "$(budget_warns)" -eq 0 ] \
    && ok "P4 DELIVERY_PROBE_TIMEOUT_S='$good' raises no WARN" \
    || nok "P4 spurious WARN for '$good'" "$LOG_OUT"
done

# ── P5: control — a probe that answers keeps the old, fully attributed halt ─
run_block ok
PL="$(probe_line)"
printf '%s' "$PL" | grep -F 'probe=ok' >/dev/null \
  && ok "P5 answering probe → probe=ok" || nok "P5 probe=ok" "$PL"
printf '%s' "$PL" | grep -F 'affected=[com.test.central-sender]' >/dev/null \
  && ok "P5 real affected list is printed as before" || nok "P5 affected list" "$PL"
! printf '%s\n' "$BD_CALLS" | grep -F 'could not be attributed' >/dev/null \
  && ok "P5 no 'could not be attributed' text when attribution worked" \
  || nok "P5 wrongly says unattributed" "$BD_CALLS"
printf '%s\n' "$BD_CALLS" | grep -F 'would be DORMANT in production' >/dev/null \
  && ok "P5 the original halt wording is untouched when the probe answered" \
  || nok "P5 original wording" "$BD_CALLS"

# ── P6: the freshness re-probe has the same exposure ────────────────────────
run_block reprobe_slow 1
RL="$(reprobe_line)"
[ "$RUN_RC" -eq 0 ] && ok "P6 block survives a timed-out re-probe (rc=0)" || nok "P6 rc" "rc=$RUN_RC"
printf '%s' "$RL" | grep -F 'probe=timeout' >/dev/null && printf '%s' "$RL" | grep -F 'rc=124' >/dev/null \
  && ok "P6 re-probe line carries probe=timeout rc=124" || nok "P6 re-probe state" "$RL"
printf '%s' "$RL" | grep -F 'budget=1s' >/dev/null \
  && ok "P6 re-probe uses the same configurable budget" || nok "P6 re-probe budget" "$RL"
[ "$REACHED" -eq 0 ] && ok "P6 still held when the re-probe cannot confirm fresh" || nok "P6 held" "REACHED=$REACHED"
[ "$PROBE_CALLS" = "2" ] && ok "P6 exactly two DRY_RUN=1 helper calls (probe + re-probe)" \
  || nok "P6 call count" "PROBE_CALLS=$PROBE_CALLS"

# ── P7: the dedup must see a change of attribution state (gate feedback) ────
# Sweep N: the per-story probe times out → the author is told "none needed,
# do NOT restart the rig-wide list". Sweep N+1: it answers, and the merge's own
# stale list is the SAME list the wide sweep flagged → same verdict, same list,
# same freshfail. A key of verdict|list|freshfail alone calls that "unchanged"
# and stays silent: the real "restart THESE" is never posted, and the author
# keeps the wrong "do NOT restart" until the 24h reminder.
comments_posted() { printf '%s\n' "$BD_CALLS" | grep -c 'comment ga-test '; }
author_nudges()   { printf '%s\n' "$GC_CALLS" | grep -c 'session nudge crew/tester'; }
mayor_nudges()    { printf '%s\n' "$GC_CALLS" | grep -c 'session nudge mayor'; }
FP_CARRY="$(mktemp -u)"; export FP_CARRY

# P7a timeout, then the probe answers
rm -f "$FP_CARRY"
run_block slow 1
[ "$(comments_posted)" -ge 1 ] && [ -f "$FP_CARRY" ] \
  && ok "P7a sweep 1 (probe timed out) announced and left a fingerprint to carry" \
  || nok "P7a sweep 1 sanity" "comments=$(comments_posted) carry=$([ -f "$FP_CARRY" ] && echo yes || echo no)"
run_block ok
[ "$RUN_RC" -eq 0 ] && ok "P7a sweep 2 block survives (rc=0)" || nok "P7a sweep 2 rc" "rc=$RUN_RC"
printf '%s' "$(probe_line)" | grep -F 'probe=ok' >/dev/null \
  && ok "P7a sweep 2: the probe answered (probe=ok) — the state really changed" \
  || nok "P7a sweep 2 probe=ok" "$(probe_line)"
! printf '%s\n' "$LOG_OUT" | grep -F 'suppressing duplicate' >/dev/null \
  && ok "P7a sweep 2 is NOT suppressed as a duplicate of the timed-out sweep" \
  || nok "P7a sweep 2 swallowed by the dedup" "$LOG_OUT"
[ "$(comments_posted)" -ge 1 ] && printf '%s\n' "$BD_CALLS" | grep -F 'would be DORMANT in production' >/dev/null \
  && ok "P7a sweep 2 posts the real finding on the bead" \
  || nok "P7a sweep 2 posted no comment" "comments=$(comments_posted)"
! printf '%s\n' "$BD_CALLS" | grep -F 'none needed from the author yet' >/dev/null \
  && ok "P7a sweep 2 no longer says 'none needed'" || nok "P7a still 'none needed'" "$BD_CALLS"
[ "$(author_nudges)" -ge 1 ] && printf '%s\n' "$GC_CALLS" | grep 'session nudge crew/tester' | grep -F 'dormant/unverified' >/dev/null \
  && ok "P7a sweep 2 corrects the author (the 'attribution unavailable' nudge is replaced)" \
  || nok "P7a sweep 2 author not told" "author_nudges=$(author_nudges)"
[ "$(mayor_nudges)" -ge 1 ] && ok "P7a sweep 2 nudges the Mayor" || nok "P7a sweep 2 mayor not told" "$GC_CALLS"

# P7b the opposite transition: it answered, then stops answering
rm -f "$FP_CARRY"
run_block ok
run_block slow 1
! printf '%s\n' "$LOG_OUT" | grep -F 'suppressing duplicate' >/dev/null \
  && ok "P7b answer→timeout: the new text is NOT suppressed as a duplicate" \
  || nok "P7b swallowed by the dedup" "$LOG_OUT"
printf '%s\n' "$BD_CALLS" | grep -F 'could not be attributed' >/dev/null \
  && ok "P7b answer→timeout: the bead is told the story could not be attributed" \
  || nok "P7b comment" "$BD_CALLS"

# P7c control: the SAME unavailable state twice is still one announcement.
# (elapsed seconds differ between the two runs — they must not reach the key.)
rm -f "$FP_CARRY"
run_block slow 1
run_block slow 1
printf '%s\n' "$LOG_OUT" | grep -F 'suppressing duplicate' >/dev/null \
  && ok "P7c timeout→timeout is still deduped (ga-vv5ngy / wa-xokje behaviour kept)" \
  || nok "P7c dedup lost" "$LOG_OUT"
[ "$(comments_posted)" -eq 0 ] && [ "$(author_nudges)" -eq 0 ] && [ "$(mayor_nudges)" -eq 0 ] \
  && ok "P7c no comment, no author nudge, no Mayor nudge on the repeat" \
  || nok "P7c repeat was not silent" "comments=$(comments_posted) author=$(author_nudges) mayor=$(mayor_nudges)"

# P7d control: answered twice, unchanged → deduped as before
rm -f "$FP_CARRY"
run_block ok
run_block ok
printf '%s\n' "$LOG_OUT" | grep -F 'suppressing duplicate' >/dev/null \
  && [ "$(comments_posted)" -eq 0 ] \
  && ok "P7d ok→ok is still deduped (the key of an answered probe is unchanged)" \
  || nok "P7d dedup lost" "comments=$(comments_posted) $LOG_OUT"

rm -f "$FP_CARRY"; unset FP_CARRY

# ── P8: killed by a signal (not by the budget) after a partial answer ───────
# rc 124 is decided first, but a helper that is SIGKILLed / SIGTERMed from the
# outside (OOM, an operator, launchd) after printing VERDICT= and before
# AFFECTED= used to be classed ok with an EMPTY reach — i.e. inert, released.
for mode_rc in "killed 137" "termed 143"; do
  set -- $mode_rc; mode="$1"; want_rc="$2"
  run_block "$mode"
  PL="$(probe_line)"
  printf '%s' "$PL" | grep -F 'probe=failed' >/dev/null && printf '%s' "$PL" | grep -F "rc=$want_rc" >/dev/null \
    && ok "P8 $mode: a partial VERDICT= from a signalled helper is probe=failed rc=$want_rc, not probe=ok" \
    || nok "P8 $mode classification" "$PL"
  printf '%s' "$PL" | grep -F 'affected=[?]' >/dev/null \
    && ok "P8 $mode: reach is unknown (affected=[?]), never the empty reach of 'inert'" \
    || nok "P8 $mode affected" "$PL"
  [ "$REACHED" -eq 0 ] && ok "P8 $mode: delivery stays HELD" || nok "P8 $mode held" "REACHED=$REACHED"
done

# ── P9: the freshness re-probe killed by a signal after a "clean" answer ────
# The release test is "VERDICT=OK over an empty GUARDED=". A re-probe that
# prints exactly that and is then SIGKILLed has not finished: whatever else it
# would have printed (PROOF=, the GUARDED_* splits) never arrived, so the two
# lines are a partial answer, not a verdict. Same rule as the per-story probe
# (P8) and as rc 124 (P6): nothing from a probe that did not answer is trusted.
# The control runs first: the SAME two lines with a normal exit must release,
# or "held" below would be a pass for some other reason.
run_block reprobe_clean
RL="$(reprobe_line)"
printf '%s' "$RL" | grep -F 'probe=ok' >/dev/null \
  && ok "P9 control: a re-probe that answers VERDICT=OK + empty GUARDED= is probe=ok" \
  || nok "P9 control classification" "$RL"
[ "$REACHED" -eq 1 ] && ok "P9 control: ...and the delivery releases on it (so 'held' below is the kill's doing)" \
  || nok "P9 control release" "REACHED=$REACHED log: $LOG_OUT"

run_block reprobe_killed
RL="$(reprobe_line)"
printf '%s' "$RL" | grep -F 'probe=failed' >/dev/null && printf '%s' "$RL" | grep -F 'rc=137' >/dev/null \
  && ok "P9 a signalled re-probe is probe=failed rc=137" || nok "P9 re-probe state" "$RL"
printf '%s' "$RL" | grep -F 'still-stale=[?]' >/dev/null \
  && ok "P9 still-stale is unknown ([?]), not the empty 'nothing is stale'" || nok "P9 still-stale" "$RL"
printf '%s' "$RL" | grep -F 'no answer' >/dev/null \
  && ok "P9 the line says 'no answer' instead of echoing the cut-off VERDICT=OK" || nok "P9 no answer" "$RL"
[ "$REACHED" -eq 0 ] && ok "P9 delivery stays HELD (a cut-off 'clean' never releases)" \
  || nok "P9 held" "REACHED=$REACHED"

echo ""
echo "story-delivery probe-timeout tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
