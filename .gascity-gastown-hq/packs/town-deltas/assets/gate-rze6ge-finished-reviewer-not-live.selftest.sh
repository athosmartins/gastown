#!/usr/bin/env bash
# gate-rze6ge-finished-reviewer-not-live.selftest.sh (ga-rze6ge, 2026-10-10)
#
# CLASS: a gate-reviewer whose review is OVER kept counting as a live reviewer.
# MEASURED 10/10 13:43-14:08 (Mayor): gate-run ga-8257kf ended superseded and its
# cleanup logged "Reviewer sessions closed", yet `gc session list` still showed
# gate-reviewer-adhoc-12d22287ac as asleep and `gc session peek` on it HUNG.
# The gt-bewtm drained-exclusion only discounts a session when peek CONFIRMS it
# gone, so the ghost counted: LIVE_REVIEWERS=3 = the cap, and the gate DEFERred
# ("dolt-calm-cap-reached") for several sweeps with 2 markers queued and only 2
# real reviewers. Its verdict bead (ga-jyiuk9) was closed the whole time.
#
# The fix judges the ARTIFACT: a listed, non-active, non-attached, non-booting
# session whose verdict bead(s) are ALL closed is finished — excluded from the
# headroom denominator and closed. Three states, never collapsed: a bead that is
# open, a bead that cannot be found, and a bead list that cannot be read all
# keep the session COUNTED (the inert default under doubt).
#
# Strategy (this repo's SELFTEST-EXTRACT convention): the REAL Step 0a-2 janitor
# block and the REAL pure helpers are taken out of the dispatcher and run against
# fake `gc`/`bd` EXECUTABLES on PATH (the block calls them through `timeout`,
# which cannot run a shell function). The fake `gc session peek` HANGS, as it did
# live. A mutation run deletes the artifact branch and proves THIS test then
# reproduces the live symptom (LIVE_REVIEWERS=3) — a test that only passes proves
# nothing.
#
# Usage: bash gate-rze6ge-finished-reviewer-not-live.selftest.sh
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/rze6ge.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT   # a mktemp dir of our own, nothing else is touched

echo "── 0. compile-guard + the real code is present ──"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}
JANITOR_SRC="$(extract_block "$DISPATCHER" reviewer-janitor-0a2)"
[ -n "$JANITOR_SRC" ] && ok "Step 0a-2 janitor block extracted" || { bad "janitor block not found (SELFTEST-EXTRACT reviewer-janitor-0a2)"; echo "FAIL"; exit 1; }
[ -n "$(extract_block "$DISPATCHER" reviewer-verdict-artifact-state-fn)" ] && ok "artifact helpers extracted" || bad "artifact helpers not found"

# Load the REAL helpers (lib-only = no live sweep).
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
# reviewer_session_should_reap sits AFTER the lib-only early return (next to the
# janitor), so take the REAL definition by its own markers rather than a mirror.
REAP_FN_SRC="$(sed -n '/^reviewer_session_should_reap() {/,/^}/p' "$DISPATCHER")"
[ -n "$REAP_FN_SRC" ] && eval "$REAP_FN_SRC"
for _fn in headroom_live_reviewers reviewer_verdict_artifact_state reviewer_session_finished_by_artifact \
           reviewer_verdict_beads_recent reviewer_session_should_reap session_is_booting session_peek_reports_dead gc_json_or_unknown; do
  type "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn not defined"; exit 1; }
done
LOGF="$SCRATCH/log.txt"
log()  { echo "LOG: $*"  >> "$LOGF"; }
warn() { echo "WARN: $*" >> "$LOGF"; }
err()  { echo "ERR: $*"  >> "$LOGF"; }

# ── 1. pure helper: reviewer_verdict_artifact_state ─────────────────────────
echo "── 1. reviewer_verdict_artifact_state: done / pending / none / unknown ──"
N=gate-reviewer-adhoc-aaaa
st() { reviewer_verdict_artifact_state "$N" "$1"; }
eq "closed bead named by metadata only (the incident's ga-jyiuk9 shape) → done" \
   "$(st '[{"id":"b1","status":"closed","assignee":null,"metadata":{"gc.session_name":"gate-reviewer-adhoc-aaaa"}}]')" done
eq "closed bead named by assignee only → done" \
   "$(st '[{"id":"b1","status":"closed","assignee":"gate-reviewer-adhoc-aaaa","metadata":{}}]')" done
eq "closed bead, no metadata key at all (bd omits it) named by assignee → done" \
   "$(st '[{"id":"b1","status":"closed","assignee":"gate-reviewer-adhoc-aaaa"}]')" done
eq "in_progress bead → pending (the review is open)" \
   "$(st '[{"id":"b1","status":"in_progress","assignee":"gate-reviewer-adhoc-aaaa","metadata":{}}]')" pending
eq "two beads, one closed + one open → pending (ALL must be closed)" \
   "$(st '[{"id":"b1","status":"closed","assignee":"gate-reviewer-adhoc-aaaa"},{"id":"b2","status":"open","metadata":{"gc.session_name":"gate-reviewer-adhoc-aaaa"}}]')" pending
eq "bead with NO status field → pending (unreadable status is not closed)" \
   "$(st '[{"id":"b1","assignee":"gate-reviewer-adhoc-aaaa"}]')" pending
eq "bead with status \"\" → pending" \
   "$(st '[{"id":"b1","status":"","assignee":"gate-reviewer-adhoc-aaaa"}]')" pending
eq "only OTHER reviewers' beads → none (can't tell is not 'finished')" \
   "$(st '[{"id":"b1","status":"closed","assignee":"gate-reviewer-adhoc-zzzz","metadata":{"gc.session_name":"gate-reviewer-adhoc-zzzz"}}]')" none
eq "empty list → none" "$(st '[]')" none
eq "bead whose metadata is not an object doesn't crash → none" \
   "$(st '[{"id":"b1","status":"closed","metadata":"oops"}]')" none
eq "not an array (an error envelope) → unknown" "$(st '{"error":"boom"}')" unknown
eq "garbage → unknown" "$(st 'not json')" unknown
eq "empty/missing list (read failed) → unknown, never done" "$(st '')" unknown
eq "empty session name → unknown" "$(reviewer_verdict_artifact_state '' '[]')" unknown
eq "a name that is a prefix of another is not a match" \
   "$(reviewer_verdict_artifact_state gate-reviewer-adhoc-aa '[{"id":"b1","status":"closed","assignee":"gate-reviewer-adhoc-aaaa"}]')" none

echo "── 2. reviewer_session_finished_by_artifact: only done, never active/attached/booting ──"
fin() { reviewer_session_finished_by_artifact "$@"; }
eq "asleep + done → finished"            "$(fin asleep false done)"   1
eq "start-pending + done → finished (its run is over, it never started)" "$(fin start-pending false done)" 1
eq "active + done → NOT finished (real budget until the cleanup closes it)" "$(fin active false done)" 0
eq "attached + done → NOT finished"      "$(fin asleep true done)"    0
eq "creating (booting) + done → NOT finished" "$(fin creating false done)" 0
eq "asleep + pending → NOT finished"     "$(fin asleep false pending)" 0
eq "asleep + none → NOT finished"        "$(fin asleep false none)"    0
eq "asleep + unknown → NOT finished"     "$(fin asleep false unknown)" 0
eq "asleep + '' → NOT finished"          "$(fin asleep false '')"      0

echo "── 3. headroom_live_reviewers: the 4th arg, and 3-arg callers unchanged ──"
eq "3 present, 1 finished → 2 live"                     "$(headroom_live_reviewers 3 0 0 1)" 2
eq "3 present, 0 reaped/drained, no 4th arg → 3 (unchanged)" "$(headroom_live_reviewers 3 0 0)" 3
eq "reaped+drained+finished all subtract"                "$(headroom_live_reviewers 6 1 2 1)" 2
eq "over-subtract floors at 0"                           "$(headroom_live_reviewers 2 0 0 5)" 0
eq "junk finished folds to 0"                            "$(headroom_live_reviewers 4 0 0 x)" 4

# ── 4. the REAL janitor block against fake gc/bd ────────────────────────────
echo "── 4. the real Step 0a-2 block, peek HANGS (the incident) ──"
FAKE="$SCRATCH/bin"; mkdir -p "$FAKE"
cat > "$FAKE/gc" <<'EOF'
#!/usr/bin/env bash
# fake gc: only the subcommands the janitor block uses
args=" $* "
case "$args" in
  *" session list "*) cat "$FAKE_SESSIONS_FILE" ;;
  *" session close "*)
      [ "${FAKE_CLOSE:-ok}" = "hang" ] && sleep 600
      echo "$*" >> "$FAKE_CLOSE_LOG" ;;
  *" session peek "*)
      sid=""; prev=""
      for a in "$@"; do [ "$prev" = peek ] && sid="$a"; prev="$a"; done
      kind=$(sed -n "s/^$sid=//p" "$FAKE_PEEK_FILE" | head -1)
      case "$kind" in
        hang)  sleep 600 ;;
        gone)  echo "gc session peek: session not found: $sid" >&2; exit 1 ;;
        *)     echo "scrollback of $sid" ;;
      esac ;;
esac
EOF
cat > "$FAKE/bd" <<'EOF'
#!/usr/bin/env bash
# fake bd: only the bulk verdict-bead read
case " $* " in
  *" list "*) [ "${FAKE_BD:-ok}" = "fail" ] && exit 1; cat "$FAKE_VB_FILE" ;;
esac
EOF
chmod +x "$FAKE/gc" "$FAKE/bd"

CREATED="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)"
export FAKE_SESSIONS_FILE="$SCRATCH/sessions.json" FAKE_PEEK_FILE="$SCRATCH/peek.txt" \
       FAKE_VB_FILE="$SCRATCH/vb.json" FAKE_CLOSE_LOG="$SCRATCH/closed.txt"

# sess <id> <name> <state> <attached> → one gate-reviewer session row
sess() { printf '{"id":"%s","name":"%s","session_name":"%s","template":"gate-reviewer","state":"%s","attached":%s,"closed":false,"created_at":"%s"}' \
         "$1" "$2" "$2" "$3" "$4" "$CREATED"; }
# vb <id> <status> <assignee|null> <session_name|null>
vb() { local a m; [ "$3" = null ] && a=null || a="\"$3\""; [ "$4" = null ] && m='{}' || m="{\"gc.session_name\":\"$4\"}"
       printf '{"id":"%s","status":"%s","assignee":%s,"metadata":%s,"labels":["type:quality-gate-verdict"]}' "$1" "$2" "$a" "$m"; }

# run_janitor <variant: real|mutant> → prints "LIVE=<n> FINISHED=<n> DRAINED=<n> REAPED=<n> SECS=<n>"; closes → $FAKE_CLOSE_LOG
run_janitor() {
  local variant="$1" src="$JANITOR_SRC" t0 t1 live
  if [ "$variant" = mutant ]; then   # the pre-fix behavior: delete the artifact branch
    src="$(printf '%s\n' "$JANITOR_SRC" | sed '/# ga-rze6ge-artifact-check: BEGIN/,/# ga-rze6ge-artifact-check: END/d')"
  fi
  : > "$FAKE_CLOSE_LOG"; : > "$LOGF"
  t0=$(date +%s)
  (
    export PATH="$FAKE:$PATH" REVIEWER_GC_CALL_TIMEOUT_SECS=1
    GC_CITY="$SCRATCH"; REVIEWER_SESSION_TTL_MINUTES=70; RECONVENE_GRACE_SECS=360
    REVIEWER_SESSION_COUNT=0; REAPED_REVIEWERS=0; DRAINED_REVIEWERS=0; FINISHED_REVIEWERS=0
    set -e
    eval "$src"
    live=$(headroom_live_reviewers "${REVIEWER_SESSION_COUNT:-0}" "${REAPED_REVIEWERS:-0}" "${DRAINED_REVIEWERS:-0}" "${FINISHED_REVIEWERS:-0}")
    echo "LIVE=$live FINISHED=${FINISHED_REVIEWERS:-0} DRAINED=${DRAINED_REVIEWERS:-0} REAPED=${REAPED_REVIEWERS:-0}"
  ) 2>>"$LOGF" | tail -1 | sed "s/\$/ SECS=$(( $(date +%s) - t0 ))/"
}
field() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

GHOST=gate-reviewer-adhoc-12d22287ac; R1=gate-reviewer-adhoc-1111111111; R2=gate-reviewer-adhoc-2222222222

# S1 — the incident: 1 ghost (asleep, verdict closed, peek hangs) + 2 real reviewers
printf '{"sessions":[%s,%s,%s]}' "$(sess ga-w3l0un $GHOST asleep false)" "$(sess ga-r1 $R1 active false)" "$(sess ga-r2 $R2 active false)" > "$FAKE_SESSIONS_FILE"
printf '%s=hang\n%s=alive\n%s=alive\n' ga-w3l0un ga-r1 ga-r2 > "$FAKE_PEEK_FILE"
printf '[%s,%s,%s]' "$(vb ga-jyiuk9 closed null $GHOST)" "$(vb ga-v1 in_progress $R1 null)" "$(vb ga-v2 in_progress $R2 null)" > "$FAKE_VB_FILE"
export FAKE_BD=ok FAKE_CLOSE=ok
OUT=$(run_janitor real)
eq "S1 incident: LIVE_REVIEWERS = 2 (ghost not counted)" "$(field "$OUT" LIVE)" 2
eq "S1 incident: FINISHED = 1"                           "$(field "$OUT" FINISHED)" 1
eq "S1 incident: DRAINED = 0 (it was the artifact, not the peek)" "$(field "$OUT" DRAINED)" 0
eq "S1 incident: the ghost session is CLOSED"            "$(grep -c "session close ga-w3l0un" "$FAKE_CLOSE_LOG")" 1
eq "S1 incident: the real reviewers are NOT closed"      "$(grep -c "ga-r[12]" "$FAKE_CLOSE_LOG")" 0
grep -q "Finished gate-reviewer session ga-w3l0un" "$LOGF" && ok "S1 incident: the exclusion is logged with the reason" || bad "S1 incident: no log line for the exclusion"
grep -q "Finished gate-reviewer session ga-w3l0un.*session closed (ga-rze6ge)" "$LOGF" && ok "S1 incident: the log says the close LANDED" || bad "S1 incident: the log does not report the close"
[ "$(field "$OUT" SECS)" -le 15 ] && ok "S1 incident: sweep stays bounded ($(field "$OUT" SECS)s) with a hanging peek" || bad "S1 incident: sweep took $(field "$OUT" SECS)s"

# S1m — MUTATION: without the artifact branch the same fixture reproduces the live symptom
OUT=$(run_janitor mutant)
eq "S1 MUTANT (pre-fix): LIVE_REVIEWERS = 3 — the live symptom (test would FAIL at HEAD)" "$(field "$OUT" LIVE)" 3
eq "S1 MUTANT (pre-fix): nothing closed" "$(grep -c . "$FAKE_CLOSE_LOG")" 0

# S2 — verdict bead still OPEN: the review is running, count it
printf '{"sessions":[%s]}' "$(sess ga-w3l0un $GHOST asleep false)" > "$FAKE_SESSIONS_FILE"
printf '[%s]' "$(vb ga-jyiuk9 in_progress $GHOST null)" > "$FAKE_VB_FILE"
OUT=$(run_janitor real)
eq "S2 open verdict bead: still counted live" "$(field "$OUT" LIVE)" 1
eq "S2 open verdict bead: NOT closed" "$(grep -c . "$FAKE_CLOSE_LOG")" 0

# S3 — no verdict bead names it: can't tell → counted (falls to the peek path)
printf '[%s]' "$(vb ga-other closed null gate-reviewer-adhoc-zzzz)" > "$FAKE_VB_FILE"
OUT=$(run_janitor real)
eq "S3 no matching bead + peek hangs: counted live" "$(field "$OUT" LIVE)" 1
eq "S3 no matching bead: NOT closed" "$(grep -c . "$FAKE_CLOSE_LOG")" 0
printf '%s=gone\n' ga-w3l0un > "$FAKE_PEEK_FILE"
OUT=$(run_janitor real)
eq "S3b no matching bead + peek says gone: the old gt-bewtm drained path still works (LIVE=0)" "$(field "$OUT" LIVE)" 0
eq "S3b ... via DRAINED, not FINISHED" "$(field "$OUT" DRAINED)/$(field "$OUT" FINISHED)" "1/0"
printf '%s=hang\n' ga-w3l0un > "$FAKE_PEEK_FILE"

# S4 — the verdict-bead list is UNREADABLE: error ≠ empty, so the ghost stays counted, and it says why
printf '[%s]' "$(vb ga-jyiuk9 closed null $GHOST)" > "$FAKE_VB_FILE"
OUT=$(FAKE_BD=fail run_janitor real)
eq "S4 bead list unreadable: counted live (inert default), no crash" "$(field "$OUT" LIVE)" 1
eq "S4 bead list unreadable: NOT closed" "$(grep -c . "$FAKE_CLOSE_LOG")" 0
grep -q "verdict beads unreadable" "$LOGF" && ok "S4 bead list unreadable: warned" || bad "S4 bead list unreadable: silent"
printf 'this is not json' > "$FAKE_VB_FILE"
OUT=$(run_janitor real)
eq "S4b bead list is garbage: counted live" "$(field "$OUT" LIVE)" 1
printf '[%s]' "$(vb ga-jyiuk9 closed null $GHOST)" > "$FAKE_VB_FILE"

# S5 — closed bead but the session is ACTIVE / ATTACHED / BOOTING: not the artifact path
for combo in "active false" "asleep true" "creating false"; do
  set -- $combo
  printf '{"sessions":[%s]}' "$(sess ga-w3l0un $GHOST "$1" "$2")" > "$FAKE_SESSIONS_FILE"
  printf '%s=alive\n' ga-w3l0un > "$FAKE_PEEK_FILE"
  OUT=$(run_janitor real)
  eq "S5 closed bead but state=$1 attached=$2: counted live" "$(field "$OUT" LIVE)" 1
  eq "S5 closed bead but state=$1 attached=$2: NOT closed" "$(grep -c . "$FAKE_CLOSE_LOG")" 0
done
printf '%s=hang\n' ga-w3l0un > "$FAKE_PEEK_FILE"

# S6 — assignee-only match (bd keeps .assignee on ~90% of closed beads)
printf '{"sessions":[%s]}' "$(sess ga-w3l0un $GHOST asleep false)" > "$FAKE_SESSIONS_FILE"
printf '[%s]' "$(vb ga-jyiuk9 closed $GHOST null)" > "$FAKE_VB_FILE"
OUT=$(run_janitor real)
eq "S6 closed bead matched by assignee only: excluded (LIVE=0)" "$(field "$OUT" LIVE)" 0

# S7 — the close itself hangs: exclusion does not depend on the close landing, and the sweep stays bounded
printf '[%s]' "$(vb ga-jyiuk9 closed null $GHOST)" > "$FAKE_VB_FILE"
OUT=$(FAKE_CLOSE=hang run_janitor real)
eq "S7 close hangs: still excluded (LIVE=0)" "$(field "$OUT" LIVE)" 0
grep -q "Finished gate-reviewer session ga-w3l0un.*session close FAILED or timed out" "$LOGF" \
  && ok "S7 close hangs: the log does NOT claim the close landed" || bad "S7 close hangs: the log hides the failed close"
grep -q "session closed (ga-rze6ge)" "$LOGF" && bad "S7 close hangs: log wrongly reports 'session closed'" || ok "S7 close hangs: no false 'session closed'"
[ "$(field "$OUT" SECS)" -le 15 ] && ok "S7 close hangs: sweep bounded ($(field "$OUT" SECS)s)" || bad "S7 close hangs: sweep took $(field "$OUT" SECS)s"

# S8 — no sessions at all: the lazy read never happens
printf '{"sessions":[]}' > "$FAKE_SESSIONS_FILE"
OUT=$(FAKE_BD=fail run_janitor real)
eq "S8 no reviewer sessions: LIVE=0, no read, no warn" "$(field "$OUT" LIVE)/$(grep -c 'verdict beads unreadable' "$LOGF")" "0/0"

# ── 5. the bulk read itself ─────────────────────────────────────────────────
echo "── 5. reviewer_verdict_beads_recent: window, bounded, validated ──"
(
  export PATH="$FAKE:$PATH"; GC_CITY="$SCRATCH"; REVIEWER_SESSION_TTL_MINUTES=70
  printf '[%s]' "$(vb ga-jyiuk9 closed null $GHOST)" > "$FAKE_VB_FILE"
  out=$(FAKE_BD=ok reviewer_verdict_beads_recent) && echo "RC=0 N=$(printf '%s' "$out" | jq length)" || echo "RC=1"
  FAKE_BD=fail reviewer_verdict_beads_recent >/dev/null && echo "RC=0" || echo "RC=1"
  printf '{"error":"x"}' > "$FAKE_VB_FILE"
  FAKE_BD=ok reviewer_verdict_beads_recent >/dev/null && echo "RC=0" || echo "RC=1"
) > "$SCRATCH/bulk.out"
eq "valid array → rc 0 with the beads"      "$(sed -n 1p "$SCRATCH/bulk.out")" "RC=0 N=1"
eq "bd failure → rc 1 (no output)"          "$(sed -n 2p "$SCRATCH/bulk.out")" "RC=1"
eq "non-array answer → rc 1"                "$(sed -n 3p "$SCRATCH/bulk.out")" "RC=1"
grep -q 'created-after' "$DISPATCHER" && ok "the read is time-windowed (--created-after), not the whole history" || bad "the read is not windowed"
grep -q 'timeout -k 5 30 bd' "$DISPATCHER" && ok "the bulk read is bounded by timeout" || bad "the bulk read is unbounded"

# ── 6. wiring ───────────────────────────────────────────────────────────────
echo "── 6. drift-guard: the headroom denominator is fed FINISHED_REVIEWERS ──"
grep -qF '"${FINISHED_REVIEWERS:-0}")' "$DISPATCHER" && ok "LIVE_REVIEWERS is computed with FINISHED_REVIEWERS" || bad "LIVE_REVIEWERS ignores FINISHED_REVIEWERS"
grep -qF 'session peek "$R_ID" --lines 1 2>&1 >/dev/null' "$DISPATCHER" && ok "peek still captures stderr-only (ga-h9o17 unchanged)" || bad "peek stderr-only capture lost"
grep -qF 'timeout -k 5 "$_R_GC_TMO" gc --city "$GC_CITY" session peek' "$DISPATCHER" && ok "peek is bounded" || bad "peek is unbounded"

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  SELFTEST FAILED"; exit 1; fi
echo "  SELFTEST OK"
exit 0
