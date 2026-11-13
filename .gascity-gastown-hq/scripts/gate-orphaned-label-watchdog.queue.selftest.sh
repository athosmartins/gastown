#!/usr/bin/env bash
# gate-orphaned-label-watchdog.queue.selftest.sh — ga-ljcbnms. End-to-end proof, with the REAL gate-orphaned-label-watchdog.sh run as a
# subprocess through its documented env seams, of what the in-file `--selftest` cannot show (it calls run_sweep directly and assigns
# PILOT_TEXT_LOG itself): the Pilot's log is found at its DEFAULT path under GOLW_HQ, GOLW_QUEUE_EVIDENCE_MIN is honoured, and a Pilot
# log that cannot be read (here: `tail` exits 3) leaves the alert exactly as it was before the QUEUED bucket existed.
# ga-xzh0lr0 adds what that block leaves unasserted, or cannot run on a host without BSD `date -j`: the daemon's exit status, the sibling-source
# WARN, the UNVERIFIED total, the active-live suffix, the quiet-hours discount (on a COPY of the script whose quiet-hours-check.sh is a stub) and
# the lock's recovery sentinel. The in-file block itself runs in gate-orphaned-label-watchdog.selftest.sh.
# Stubs only: no bd, gc, notify or Pilot is touched. GOLW_SCRIPT_UNDER_TEST=<other copy> proves the selftest fails on older code.
# Mutants of gate-orphaned-label-watchdog.sh that no run of the family (this file + gate-orphaned-label-watchdog.selftest.sh) can tell from the original,
# each argued from the code (ids are the hq-mutants sweep's, ga-xzh0lr0; statements' status is read by nobody, or an assertion of the in-file block stays true):
# EQUIVALENT 1154788ecb: `return 1` -> `return 0` on the error path of _bead_recheck_status: its only caller reads the word the function prints (`_rstatus="$(...)"` in _golw_resolve_tracked_state) and no `$?` after it, and the script has no `set -e` and no ERR trap
# EQUIVALENT 10bf6114d7: `[ "$_golw_quiet_adj" -gt 0 ]` -> `-gt 1`: a candidate is admitted only when its raw age is at least GOLW_STALE_MINUTES*60+1 s (strict `<` on the cutoff in the jq filter, the same updated_at), so a discount of exactly 1 s leaves an effective age of at least the threshold and the next test is false either way; 0 s and 2 s or more agree
# EQUIVALENT 11c3c8f230: `flagged_ids="$(... jq ...)" || flagged_ids="$flagged_ids"` with `||` -> `&&`: the assignment has already happened when the list is evaluated, so the right side only assigns the variable to itself under either operator; measured with a jq that succeeds, fails, or reads empty or garbage input: the same value, only the statement's status differs and nobody reads it
# EQUIVALENT 068a774d6b: `rmdir "$_reaping" 2>/dev/null || true` -> `&& true` in the back-off branch of _acquire_golw_lock: the next statement is `return 1`, which sets the function's status, so nobody reads the status of the rmdir line (no `set -e`, no ERR trap)
# EQUIVALENT 0aa83d4d59: scenario 53's own assertion inside the in-file block: `A && B && C` -> `A || B && C` is `(A || B) && C`; the original is true only when A, B and C are all true, and then the mutated one is true too, so they differ only on a run where the original already fails (a mutation of the test, not of the sweep)
# EQUIVALENT 4c0b2f7e1a 5fd6197e2f: `return 1` -> `0` on the error path of _gate_artifact_probe and `return 0` -> `1` after the WARN of _golw_active_sessions_json: each has one caller, `x="$(f ...)"`, which takes the printed text and never reads `$?`; no `set -e`, no ERR trap
# EQUIVALENT 2d156c710a 1bdb4b248b: `return 1` -> `0` on the two "pool-queue proof unavailable" paths of _golw_pilot_queue_ids: the caller does read the status (`if qe_out="$(...)"`), but both paths print nothing and have logged their WARN already, so the mutant sets qe_state=ok with a blank id list, and a blank list marks no bead queued: the same is_queued=0 and the same later reads as "unreadable"; measured over a window that cannot be placed and an unreadable log: comments, notify, log and exit status identical
# EQUIVALENT 42107726bc 538ad793cf 5280f9db40 2ed966e472 1ffe599e38 660df541bd 37bfe32625 4ca1ac345d: `cmd || true` -> `cmd && true` on the rm, mkdir -p, printf > file, echo >> file and notify statements of run_sweep: the status of the line is read by nobody (the next statement is another statement, or `return`) and the script has no `set -e` and no ERR trap
# EQUIVALENT 5187aa5c86 64c1e10173 455757bd04 1ec6795f1e: an assertion of the in-file block itself (scenarios 47, 52, 53), one `&&` of its chain -> `||`: the pass needs every operand true, and then the mutated expression is true too, so the two differ only on a run where the original already fails (a mutation of the test, not of the sweep)
# EQUIVALENT 448fe400a7: scenario 48's fixture picker `[ "$kind" = missing ]` -> `!=` hands each of the three iterations another unreadable-log fixture, and all three assert the same thing (alert kept, one WARN): true on every non-root host; only as root would the swapped chmod-000 fixture be readable (the block already skips that case for root)
# EQUIVALENT 6223226df0: the last line of the in-file block, `[ "$FAIL" -eq 0 ] && exit 0 || exit 1` with `||` -> `&&`: with FAIL=0 `exit 0` ends the run before the changed operator is reached, so a green block is identical; it differs only for a FAILING block (the mutant falls through into the live sweep instead of exiting 1), which no run of a green family can show
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${GOLW_SCRIPT_UNDER_TEST:-$HERE/gate-orphaned-label-watchdog.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/failbin" "$T/tmp" "$T/hq/.gc/logs"

# bd: `-C <store> list --json --limit 0` = the candidates (and, with QS_CLOBBER=<file>, a peer taking over that heartbeat file), `list ... -l source-bead:<id>`
# = no gate artifact, `list ... --id <id>` = the re-check (QS_RECHECK, a failing query when the file is absent), `comment <id> --stdin` = logged
cat > "$T/bin/bd" <<'BDSTUB'
#!/usr/bin/env bash
verb="$3"; shift 3
if [ "$verb" = list ]; then
  if [[ "$*" == *"source-bead:"* ]]; then echo '[]'
  elif [[ "$*" == *"--id "* ]]; then [ -f "$QS_RECHECK" ] && cat "$QS_RECHECK" || exit 1
  else [ -n "${QS_CLOBBER:-}" ] && echo "peer:1" > "$QS_CLOBBER"; cat "$QS_CANDIDATES"; fi
elif [ "$verb" = comment ]; then
  cat > /dev/null; echo "comment:$1" >> "$QS_COMMENTS"
else
  echo '[]'
fi
BDSTUB
# gc: `session list` = the live roster (QS_SESSIONS, empty when the file is absent) and exits QS_GC_RC; `mail send` is logged to QS_MAIL
cat > "$T/bin/gc" <<'GCSTUB'
#!/bin/sh
if [ "$1 $2" = "session list" ]; then
  if [ -f "$QS_SESSIONS" ]; then cat "$QS_SESSIONS"; else echo '{"sessions":[]}'; fi
  exit "${QS_GC_RC:-0}"
fi
[ "$1 $2" = "mail send" ] && echo "$*" >> "$QS_MAIL"
exit 0
GCSTUB
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$QS_NOTIFY"' 'exit 0' > "$T/bin/notify"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$T/failbin/tail"
chmod +x "$T/bin/bd" "$T/bin/gc" "$T/bin/notify" "$T/failbin/tail"

# `stat -f %m` (the lock's file age) and `date -j` are BSD forms: on a host without them (the Linux node) a PATH shim answers exactly those with GNU stat/date and passes
# every other call through (twin of the shim in gate-orphaned-label-watchdog.selftest.sh); where `date -j` exists nothing is shimmed. P0 = the PATH every run starts from.
P0="$PATH"
if ! date -j -f '%Y-%m-%d %H:%M:%S' '2000-01-02 00:00:00' +%s > /dev/null 2>&1; then
  mkdir -p "$T/bsd"; real_date="$(command -v date)"; real_stat="$(command -v stat)"
  printf '%s\n' '#!/bin/sh' "real=$real_date" 'num() { case "$1" in ""|*[!0-9]*) return 1 ;; esac; return 0; }' 'case "$1" in' \
    '  -j) if [ "$2" = -f ]; then case "$3" in %s) arg="@$4" ;; *) arg="$4" ;; esac; exec "$real" -d "$arg" ${5:+"$5"}; fi ;;' \
    '  -r) if num "$2"; then exec "$real" -d "@$2" ${3:+"$3"}; fi ;;' '  -u) if [ "$2" = -r ] && num "$3"; then exec "$real" -u -d "@$3" ${4:+"$4"}; fi ;;' \
    'esac' 'exec "$real" "$@"' > "$T/bsd/date"
  printf '%s\n' '#!/bin/sh' 'if [ "$1" = -f ] && [ "$2" = %m ]; then shift 2; exec '"$real_stat"' -c %Y "$@"; fi' 'exec '"$real_stat"' "$@"' > "$T/bsd/stat"
  chmod +x "$T/bsd/date" "$T/bsd/stat"; P0="$T/bsd:$PATH"
fi

# the live wa-a2iz7b.1 shape (open, no assignee, routed, gate:needs-fix) and the Pilot's own line for it 10 min ago (local clock, no zone)
stamp() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
tstamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }   # the argument of `touch -t`
OLD_TS="$(date -u -v-10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date +%s)"
printf '[{"id":"wa-a2iz7b.1","status":"open","updated_at":"%s","metadata":{"gc.routed_to":"wa-worker"},"labels":["gate:needs-fix","gate:fix-attempt:1"]}]\n' "$OLD_TS" > "$T/candidates.json"
printf '[%s] [pilot-dispatcher] ga-5fn5p3: wa-a2iz7b.1 P2 cedida a P0/P1 de whatsapp_automation (P1 wa-p1 waits behind wa-worker 2/2) — not claimed, no writes this sweep\n' "$(stamp $((NOW - 600)))" > "$T/hq/.gc/logs/pilot-dispatcher.log"

run() {  # VAR=val args extend the env; one real run (of $QS_SCRIPT when set) from a fresh state or from $T/seed.json; leaves $T/comments (one line per bd comment) and $T/golw.log; returns the daemon's status
  : > "$T/comments"; : > "$T/golw.log"; : > "$T/notify.log"; : > "$T/mail.log"; rm -f "$T/state.json"
  [ -f "$T/seed.json" ] && cp "$T/seed.json" "$T/state.json"
  env PATH="$P0" "$@" TMPDIR="$T/tmp" GOLW_HQ="$T/hq" GOLW_STORES="$T/hq" GOLW_BD_BIN="$T/bin/bd" GOLW_GC_BIN="$T/bin/gc" GOLW_NOTIFY_BIN="$T/bin/notify" \
    GOLW_LOG="$T/golw.log" GOLW_STATE_DIR="$T" GOLW_STATE_FILE="$T/state.json" GOLW_JEV_EXPERIMENT_ENABLED=0 \
    QS_CANDIDATES="$T/candidates.json" QS_COMMENTS="$T/comments" QS_RECHECK="$T/recheck.json" QS_SESSIONS="$T/sessions.json" QS_NOTIFY="$T/notify.log" QS_MAIL="$T/mail.log" bash "${QS_SCRIPT:-$SCRIPT}" > "$T/out" 2>&1
}

echo "run 1: the Pilot's recent 'cedida' line sits at the DEFAULT path ($T/hq/.gc/logs/pilot-dispatcher.log) -> queued, not alerted"
run
rc=$?
[ ! -s "$T/comments" ] && ok "run 1: no comment on the queued bead" || bad "run 1: the bead the Pilot holds for capacity was commented (default log path or env binding broken)"
grep -q "QUEUED: 1 bead" "$T/golw.log" && ok "run 1: the log counts it as QUEUED" || bad "run 1: no QUEUED line in the watchdog log"
[ "$rc" -eq 0 ] && ok "run 1: the daemon exits 0" || bad "run 1: the daemon exited $rc after a clean sweep"
grep -q "quiet-hours-check.sh failed to source" "$T/out" && bad "run 1: the WARN that the quiet-hours sibling failed to source, though it sits next to the script" || ok "run 1: no sibling-source WARN when quiet-hours-check.sh is there"

echo "run 2: GOLW_QUEUE_EVIDENCE_MIN=5 (the line is 10 min old) -> no proof, alerted as before"
run GOLW_QUEUE_EVIDENCE_MIN=5
rc=$?
grep -q "comment:wa-a2iz7b.1" "$T/comments" && ok "run 2: the bead is commented (the window env is honoured)" || bad "run 2: a 10-min-old line proved a 5-min window"
[ "$rc" -eq 0 ] && ok "run 2: an alert is not a daemon failure (exit 0)" || bad "run 2: the daemon exited $rc after alerting"
grep -q -e "^-t Gate: orphaned label(s) -p 2 GATE ORPHANED LABEL: 1 new/due, 0 resolved, 0 unchanged-already-reported" "$T/notify.log" && ok "run 2: notify is called with the title, the priority and the summary" || bad "run 2: no notify call with title, priority and summary (the in-file block only ever takes the GOLW_TEST_NOTIFIED hook)"
{ grep -q "^mail send mayor -s Watchdog: 1 bead(s) com gate:\* label e zero marker ativo (>=180min) -m " "$T/mail.log" && grep -q "NEW/DUE (1)" "$T/mail.log" && grep -q "wa-a2iz7b.1" "$T/mail.log"; } && ok "run 2: the mayor is mailed with the subject and the NEW/DUE body" || bad "run 2: no gc mail send to the mayor with the subject and the NEW/DUE body"

echo "run 3: tail exits 3 -> the proof cannot be read -> alerted as before, one WARN says why"
run PATH="$T/failbin:$P0"
grep -q "comment:wa-a2iz7b.1" "$T/comments" && ok "run 3: the bead is commented although the Pilot log could not be read" || bad "run 3: an unreadable Pilot log hid the alert"
grep -q "WARN: ga-ljcbnms: reading the Pilot log" "$T/golw.log" && ok "run 3: the WARN names the failed read" || bad "run 3: no WARN about the failed read"
grep -q "QUEUED:" "$T/golw.log" && bad "run 3: QUEUED reported without a readable log" || ok "run 3: no QUEUED bucket without a readable log"

echo "run 4: a copy of the script with no quiet-hours-check.sh beside it says so on stderr (and still sweeps)"
mkdir -p "$T/nosib/scripts"; cp "$SCRIPT" "$T/nosib/scripts/gate-orphaned-label-watchdog.sh"
QS_SCRIPT="$T/nosib/scripts/gate-orphaned-label-watchdog.sh" run
grep -q "quiet-hours-check.sh failed to source" "$T/out" && ok "run 4: the sibling-source WARN is printed" || bad "run 4: a missing quiet-hours-check.sh went unsaid"
grep -q "QUEUED: 1 bead" "$T/golw.log" && ok "run 4: the sweep itself still ran" || bad "run 4: the sweep did not run on the copy"

bead2() {  # id status assignee epoch labels_csv [routed_to]: a stale bead, as the store lists it, with its own labels and optionally a pool route
  local lj meta=""; lj="$(printf '%s' "$5" | tr ',' '\n' | jq -R . | jq -s -c .)"
  [ -n "${6:-}" ] && meta=",\"metadata\":{\"gc.routed_to\":\"$6\"}"
  printf '{"id":"%s","status":"%s","assignee":"%s","updated_at":"%s","labels":%s%s}' "$1" "$2" "$3" "$(iso "$4")" "$lj" "$meta"
}
bead() { bead2 "$1" "$2" "$3" "$4" gate:needs-fix; }   # id status assignee epoch: a stale gate:needs-fix bead
N0="$(date +%s)"

echo "run 5: a tracked bead that left the sweep: its re-check unreadable -> UNVERIFIED, counted once; confirmed closed -> RESOLVED, no UNVERIFIED total"
printf '[]\n' > "$T/candidates.json"
printf '{"trk-1":{"first_seen":1,"last_alert":1,"store":"%s"}}\n' "$T/hq" > "$T/seed.json"
run
grep -q "UNVERIFIED total this sweep: 1 bead(s)" "$T/golw.log" && ok "run 5: one unreadable re-check -> the UNVERIFIED total says 1" || bad "run 5: no UNVERIFIED total for one unreadable re-check"
printf '[{"id":"trk-1","status":"closed","labels":[]}]\n' > "$T/recheck.json"
run
{ grep -q "RESOLVED: trk-1" "$T/golw.log" && ! grep -q "UNVERIFIED total" "$T/golw.log"; } && ok "run 5: a confirmed-closed bead is RESOLVED and no UNVERIFIED total is logged" || bad "run 5: UNVERIFIED total logged for a bead that was confirmed closed (or no RESOLVED line)"
rm -f "$T/seed.json" "$T/recheck.json"

echo "run 6: a flagged bead inside its cooldown + a live in_progress bead -> the OK line names the active-live exclusion; with no live bead it does not"
printf '[%s,%s]\n' "$(bead o-1 open '' $((N0 - 864000)))" "$(bead l-1 in_progress worker-x $((N0 - 864000)))" > "$T/candidates.json"
printf '{"sessions":[{"name":"worker-x"}]}\n' > "$T/sessions.json"
printf '{"o-1":{"first_seen":%s,"last_alert":%s,"store":"%s"}}\n' "$((N0 - 3000))" "$((N0 - 100))" "$T/hq" > "$T/seed.json"
run
grep -q "already alerted within cooldown.*(+1 active-live, excluded)" "$T/golw.log" && ok "run 6: the OK line carries (+1 active-live, excluded)" || bad "run 6: the OK line lost the active-live exclusion"
printf '[%s]\n' "$(bead o-1 open '' $((N0 - 864000)))" > "$T/candidates.json"
run
{ grep -q "already alerted within cooldown" "$T/golw.log" && ! grep -q "active-live" "$T/golw.log"; } && ok "run 6: with no live bead the OK line names no active-live exclusion" || bad "run 6: an active-live exclusion was named although no bead is live"
rm -f "$T/seed.json" "$T/sessions.json"

echo "run 6b: gc session list exits 1 but prints a roster naming the assignee, or exits 0 and prints nothing -> not verified alive: the bead is alerted and one WARN says why"
printf '[%s]\n' "$(bead l-1 in_progress worker-x $((N0 - 864000)))" > "$T/candidates.json"
printf '{"sessions":[{"name":"worker-x"}]}\n' > "$T/sessions.json"
run QS_GC_RC=1
{ grep -q "WARN: gc session list failed (exit 1)" "$T/golw.log" && grep -q "comment:l-1" "$T/comments" && ! grep -q "ACTIVE:" "$T/golw.log"; } && ok "run 6b: a failing gc that still printed a live roster is not believed (WARN, alerted, no ACTIVE bucket)" || bad "run 6b: a failing gc's roster was believed, or the failure went unsaid"
: > "$T/sessions.json"
run
{ grep -q "WARN: gc session list failed (exit 0)" "$T/golw.log" && grep -q "comment:l-1" "$T/comments"; } && ok "run 6b: an empty answer from gc is a failed read (WARN, alerted)" || bad "run 6b: an empty gc answer was not reported as a failed read"
rm -f "$T/sessions.json"

echo "run 7: the quiet-hours discount, on a copy whose quiet-hours-check.sh is a stub (QS_QUIET_ADJ seconds): explained -> suppressed; still stale after it -> alerted"
mkdir -p "$T/qtree/scripts" "$T/qtree/packs/town-deltas/assets"; cp "$SCRIPT" "$T/qtree/scripts/gate-orphaned-label-watchdog.sh"
printf '%s\n' 'QUIET_HOURS_LEVEL_FILE=/dev/null' '_quiet_elapsed_adjustment() { printf "%s" "${QS_QUIET_ADJ:-0}"; }' > "$T/qtree/packs/town-deltas/assets/quiet-hours-check.sh"
qrun() {  # <discount s> <raw age s>: one sweep, at a fixed "now", of one bead that old
  printf '[%s]\n' "$(bead qb-1 open '' $((N0 - $2)))" > "$T/candidates.json"
  QS_SCRIPT="$T/qtree/scripts/gate-orphaned-label-watchdog.sh" run QS_QUIET_ADJ="$1" GOLW_TEST_NOW="$N0"
}
qrun 3000 12000
{ grep -q "SUPPRESSED (quiet hours): qb-1 raw age=200min, quiet-adjusted=150min (< 180min)" "$T/golw.log" && [ ! -s "$T/comments" ]; } && ok "run 7: 200 min raw - 50 min of quiet = 150 min < 180: suppressed, not commented" || bad "run 7: a bead explained by quiet hours was not suppressed"
qrun 600 12000
{ [ -s "$T/comments" ] && ! grep -q "SUPPRESSED" "$T/golw.log"; } && ok "run 7: 200 min raw - 10 min of quiet = 190 min >= 180: still alerted" || bad "run 7: a discount that leaves the bead stale suppressed it"
qrun 1 10801
{ [ -s "$T/comments" ] && ! grep -q "SUPPRESSED" "$T/golw.log"; } && ok "run 7: 1 s of quiet on a bead 1 s over the threshold leaves it exactly at 180 min: alerted" || bad "run 7: the threshold edge suppressed (an effective age of exactly 180 min is stale)"

echo "run 8: a DEAD holder whose recovery sentinel (.reaping) another reclaimer still holds -> back off, no second sweep"
printf '[{"id":"wa-a2iz7b.1","status":"open","updated_at":"%s","metadata":{"gc.routed_to":"wa-worker"},"labels":["gate:needs-fix","gate:fix-attempt:1"]}]\n' "$OLD_TS" > "$T/candidates.json"
LD="$T/tmp/gate-orphaned-label-watchdog$(printf '%s' "$T/hq" | tr '/ ' '__').lock.d"
sleep 0 & dp=$!; wait "$dp"
mkdir -p "$LD" "$LD.reaping"; printf '%s:tok\n' "$dp" > "$LD/heartbeat"
run GOLW_QUEUE_EVIDENCE_MIN=5
rc=$?
{ grep -q "backing off (single-instance guard" "$T/golw.log" && [ ! -s "$T/comments" ]; } && ok "run 8: the second run backed off and swept nothing" || bad "run 8: a run swept although another reclaimer held the recovery sentinel"
[ "$rc" -eq 0 ] && ok "run 8: backing off exits 0" || bad "run 8: backing off exited $rc"
find "$LD" "$LD.reaping" -depth -delete   # the back-off leaves the planted lock where it was: every later run would back off too

echo "run 8b: a DEAD holder whose recovery sentinel is older than the TTL -> the stale sentinel is cleared, the lock taken over, the sweep runs, and both are released"
mkdir -p "$LD" "$LD.reaping"; printf '%s:tok\n' "$dp" > "$LD/heartbeat"; touch -t "$(tstamp $((N0 - 3600)))" "$LD.reaping"
run GOLW_QUEUE_EVIDENCE_MIN=5
{ grep -q "Recovered STALE/DEAD lock" "$T/golw.log" && grep -q "comment:wa-a2iz7b.1" "$T/comments" && [ ! -e "$LD" ] && [ ! -e "$LD.reaping" ]; } && ok "run 8b: an expired sentinel does not stop the takeover (and nothing is left behind)" || bad "run 8b: the takeover from a dead holder did not happen, or left the lock or the sentinel behind"

echo "run 12: a normal run releases its lock; a run whose heartbeat a peer took over leaves the peer's lock alone"
run
[ ! -e "$LD" ] && ok "run 12: the lock directory is gone after a normal run" || bad "run 12: the lock directory was left behind"
run QS_CLOBBER="$LD/heartbeat"
{ [ -d "$LD" ] && [ "$(head -n 1 "$LD/heartbeat")" = "peer:1" ]; } && ok "run 12: a lock whose heartbeat names another owner is not removed" || bad "run 12: a peer's lock was removed (or its heartbeat lost)"
find "$LD" -depth -delete

OLDN=$((N0 - 864000))
echo "run 9: the exclusions are named in the OK lines and in the alert summary, and only for what is excluded (set P = one parked bead, set AQ = one live in_progress bead + one queued one)"
printf '[%s] [pilot-dispatcher] ga-5fn5p3: q-1 P2 cedida a P0/P1 de whatsapp_automation (P1 wa-p1 waits behind wa-worker 2/2) — not claimed, no writes this sweep\n' "$(stamp $((N0 - 600)))" >> "$T/hq/.gc/logs/pilot-dispatcher.log"
printf '{"sessions":[{"name":"worker-x"}]}\n' > "$T/sessions.json"
xrun() {  # <clean|cool|alert> <P|AQ>: one sweep; clean = only the excluded beads, cool = + an orphan alerted 100 s ago, alert = + a new orphan
  local b=""
  [ "$1" = clean ] || b="$(bead o-1 open '' $OLDN),"
  if [ "$2" = P ]; then b="$b$(bead2 p-1 open '' $OLDN gate:needs-fix,blocked:sem-prioridade)"
  else b="$b$(bead a-1 in_progress worker-x $OLDN),$(bead2 q-1 open '' $OLDN gate:needs-fix wa-worker)"; fi
  printf '[%s]\n' "$b" > "$T/candidates.json"
  rm -f "$T/seed.json"
  [ "$1" = cool ] && printf '{"o-1":{"first_seen":%s,"last_alert":%s,"store":"%s"}}\n' "$((N0 - 3000))" "$((N0 - 100))" "$T/hq" > "$T/seed.json"
  run
}
sfx() { grep -m1 -e "$2" "$T/golw.log" | sed "s/.*$1//"; }   # the text after the marker $1 on the first log line matching $2
xrun clean P
[ "$(sfx 'across ' 'OK: 0 beads')" = "$T/hq (1 parked, excluded)" ] && ok "run 9: nothing flagged, one parked bead -> the OK line says (1 parked, excluded) and nothing else" || bad "run 9: the OK line of a sweep with one parked bead reads '$(sfx 'across ' 'OK: 0 beads')'"
xrun clean AQ
[ "$(sfx 'across ' 'OK: 0 beads')" = "$T/hq (1 active-live, excluded) (1 queued, excluded)" ] && ok "run 9: one live + one queued bead -> (1 active-live, excluded) (1 queued, excluded) and no parked" || bad "run 9: the OK line of a sweep with a live and a queued bead reads '$(sfx 'across ' 'OK: 0 beads')'"
xrun cool P
[ "$(sfx 'notification' 'already alerted within cooldown')" = " (+1 parked, excluded)" ] && ok "run 9: inside the cooldown with one parked bead -> (+1 parked, excluded) only" || bad "run 9: the cooldown OK line with a parked bead reads '$(sfx 'notification' 'already alerted within cooldown')'"
xrun cool AQ
[ "$(sfx 'notification' 'already alerted within cooldown')" = " (+1 active-live, excluded) (+1 queued, excluded)" ] && ok "run 9: inside the cooldown with a live and a queued bead -> both named, no parked" || bad "run 9: the cooldown OK line with a live and a queued bead reads '$(sfx 'notification' 'already alerted within cooldown')'"
xrun alert P
{ grep -q -e "+1 parado(s) por decisao humana" "$T/notify.log" && ! grep -q -e "em andamento com sessao viva" -e "na fila do pool" "$T/notify.log"; } && ok "run 9: the alert summary names the parked bead and nothing else" || bad "run 9: the alert summary of a sweep with one parked bead is wrong: $(head -c 300 "$T/notify.log")"
xrun alert AQ
{ grep -q -e "+1 em andamento com sessao viva" "$T/notify.log" && grep -q -e "+1 na fila do pool" "$T/notify.log" && ! grep -q -e "parado(s)" "$T/notify.log"; } && ok "run 9: the alert summary names the live and the queued bead, not a parked one" || bad "run 9: the alert summary of a sweep with a live and a queued bead is wrong: $(head -c 300 "$T/notify.log")"
rm -f "$T/seed.json" "$T/sessions.json"

echo "run 10: the cooldown edge: due at exactly one cooldown, held one second short; a first alert is never held by a cooldown longer than the epoch"
printf '[%s]\n' "$(bead o-1 open '' $OLDN)" > "$T/candidates.json"
printf '{"o-1":{"first_seen":1,"last_alert":%s,"store":"%s"}}\n' "$((N0 - 21600))" "$T/hq" > "$T/seed.json"
run GOLW_TEST_NOW="$N0"
grep -q "comment:o-1" "$T/comments" && ok "run 10: a bead alerted exactly one cooldown ago is due again" || bad "run 10: the cooldown held a bead at exactly 21600 s"
printf '{"o-1":{"first_seen":1,"last_alert":%s,"store":"%s"}}\n' "$((N0 - 21599))" "$T/hq" > "$T/seed.json"
run GOLW_TEST_NOW="$N0"
[ ! -s "$T/comments" ] && ok "run 10: one second short of the cooldown it stays quiet" || bad "run 10: a bead alerted 21599 s ago was alerted again"
rm -f "$T/seed.json"
run GOLW_ALERT_COOLDOWN_S=9999999999
grep -q "comment:o-1" "$T/comments" && ok "run 10: a cooldown longer than the epoch does not hold the FIRST alert" || bad "run 10: a never-alerted bead was held by the cooldown"

echo "run 11: GOLW_DRY_RUN=1 logs what it would do and writes nothing; the same sweep without it writes"
run GOLW_DRY_RUN=1
{ grep -q "DRY_RUN: would comment on new/due bead(s)" "$T/golw.log" && [ ! -s "$T/comments" ] && [ ! -s "$T/notify.log" ] && [ ! -s "$T/mail.log" ] && [ ! -e "$T/state.json" ]; } && ok "run 11: a dry run alerts nobody and writes no state" || bad "run 11: a dry run commented, notified, mailed or wrote state"
printf '[]\n' > "$T/candidates.json"; printf '{}\n' > "$T/seed.json"
run
[ ! -e "$T/state.json" ] && ok "run 11: an empty sweep over an empty state file removes it" || bad "run 11: the empty state file stayed"
run GOLW_DRY_RUN=1
[ -e "$T/state.json" ] && ok "run 11: a dry run leaves it" || bad "run 11: a dry run removed the state file"
printf '{ "trk-1": {"first_seen":1,"last_alert":1,"store":"%s"} }\n' "$T/hq" > "$T/seed.json"
printf '[{"id":"trk-1","status":"closed","labels":[]}]\n' > "$T/recheck.json"
run
{ grep -q "STATE CLEARED" "$T/golw.log" && [ ! -e "$T/state.json" ]; } && ok "run 11: every tracked bead resolved -> the state file is cleared and says so" || bad "run 11: resolved state was not cleared"
run GOLW_DRY_RUN=1
{ ! grep -q "STATE CLEARED" "$T/golw.log" && [ -e "$T/state.json" ]; } && ok "run 11: a dry run clears nothing" || bad "run 11: a dry run cleared the state"
rm -f "$T/recheck.json"
run
[ "$(cat "$T/state.json" 2>/dev/null)" = '{"trk-1":{"first_seen":1,"last_alert":1,"store":"'"$T"'/hq"}}' ] && ok "run 11: a tracked bead whose re-check fails is kept and the state is rewritten" || bad "run 11: the state of an unverified bead was lost or not rewritten"
run GOLW_DRY_RUN=1
grep -q '^{ "trk-1"' "$T/state.json" && ok "run 11: a dry run leaves the file as it was" || bad "run 11: a dry run rewrote the state file"
rm -f "$T/seed.json"

echo ""
echo "gate-orphaned-label-watchdog.queue selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
