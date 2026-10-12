#!/usr/bin/env bash
# gate-bk5j8u-midsweep-collect.selftest.sh (ga-bk5j8u.1)
#
# A verdict that lands while a sweep is busy admitting another marker is collected AT THE NEXT SAFE
# POINT of that sweep, not at the top of the next one. Measured before this change (last 50 rounds):
# verdict -> Phase C notices = median 3.0 min / p90 9.2, because Phase C ran only at the top of a sweep
# and an admitting sweep holds the process for a median ~9 min.
#
# What this proves (no live Dolt / gc / launchd; the real functions of the real dispatcher are sourced
# in lib-only mode, the real script is run as a real process in a scratch city for the child-mode checks):
#   1. the event-log hint: only a CLOSED VERDICT bead's gate-run label is a candidate; garbage, a
#      half-written line, other event types and non-verdict beads are not; offsets are in BYTES (a
#      multi-byte title must not shift the next look) and a rotated file is read whole.
#   2. the confirm step: a candidate is collected only if its run is still running, it has no non-closed
#      verdict bead left, it is not the run this sweep is admitting, and it was not collected already.
#   3. A FAKE REVIEWER THAT CLOSES THE VERDICT BEAD MID-SWEEP (a stateful fake bd + a fake child): the run is
#      collected exactly once, a replayed event does not collect it again, a two-reviewer run is collected
#      when the SECOND verdict closes (not lost, not early), a failed confirm read is retried at the next
#      safe point, and the heartbeat is refreshed around the child.
#   4. lock borrowing is proven, not assumed: a child that is not a direct child of the live holder, or whose
#      token is not the heartbeat's, does nothing and leaves the lock alone; a valid borrower finishes without
#      releasing the lock (its parent is still waiting); `_release_gate_lock` is a no-op for a borrower.
#   5. the live wiring is there (safe-point calls at top level, arm before Phase C, admitting run stamped,
#      child exit before Step 0a), and the checks have teeth: each mutation of the lock guards turns a check red.
#
# Exit 0 iff every assertion holds.
# Test seam: QG_BK5J8U_DISPATCHER points the lib-mode checks at another dispatcher file (the old HEAD must fail).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${QG_BK5J8U_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
REPO_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-bk5j8u1.XXXXXX")"
trap '[ -n "${ROOT:-}" ] && rm -rf "$ROOT"' EXIT
# The dispatcher puts its lock dir under $TMPDIR at source time: keep it in the scratch dir, never the real one.
export TMPDIR="$ROOT/tmp"
mkdir -p "$TMPDIR"

# ── Load the REAL helpers (lib-only = no live run) ────────────────────────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" >/dev/null 2>&1 \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
set +e   # the dispatcher turns errexit on; the harness counts failures instead

# This FATAL is both the drift guard and the "fails on the previous HEAD" half: none of these existed before
# ga-bk5j8u.1, so an unpatched dispatcher stops here instead of silently skipping every check below.
for _fn in gate_event_closed_verdict_runs gate_verdict_ready_runs gate_midsweep_arm gate_midsweep_new_runs \
           gate_midsweep_collect _gate_lock_borrow_ok _gate_run_phase_c_child; do
  type "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn not defined by the dispatcher (ga-bk5j8u.1 missing?)"; exit 1; }
done

LOGF="$ROOT/log.txt"
: > "$LOGF"
log()  { printf '%s\n' "$*" >> "$LOGF"; }
warn() { printf 'WARN %s\n' "$*" >> "$LOGF"; }
err()  { printf 'ERR %s\n' "$*" >> "$LOGF"; }

# ── event fixtures (the shape of a real .gc/events.jsonl line) ─────────────────
ev_verdict_closed() {   # $1 = run id, $2 = optional title
  printf '{"seq":1,"type":"bead.closed","ts":"2026-10-12T15:43:12.982313-03:00","actor":"cache-reconcile","subject":"ga-v","payload":{"id":"ga-v","title":"%s","status":"closed","issue_type":"chore","labels":["gate-run:%s","reviewer-index:1","type:quality-gate-verdict","verdict:PASS"]}}\n' "${2:-reviewer-verdict}" "$1"
}
ev_other_closed() {     # a closed bead that is NOT a verdict bead but carries a gate-run label
  printf '{"seq":2,"type":"bead.closed","ts":"2026-10-12T15:43:12-03:00","actor":"x","subject":"ga-r","payload":{"id":"ga-r","status":"closed","labels":["gate-run:%s","type:quality-gate-run"]}}\n' "$1"
}
ev_verdict_created() {
  printf '{"seq":3,"type":"bead.created","ts":"2026-10-12T15:43:12-03:00","actor":"x","subject":"ga-v","payload":{"id":"ga-v","labels":["gate-run:%s","type:quality-gate-verdict"]}}\n' "$1"
}

# ── 1. gate_event_closed_verdict_runs (pure) ───────────────────────────────────
echo "── 1. the event-log hint: only a closed VERDICT bead's gate-run label is a candidate ──"
_in="$(ev_verdict_closed ga-r1)
$(ev_other_closed ga-r9)
$(ev_verdict_created ga-r8)
not json at all
$(ev_verdict_closed ga-r2)
$(ev_verdict_closed ga-r1)
{\"type\":\"bead.closed\",\"payload\":{\"labels\":[\"type:quality-gate-verdict\"]}}
[1,2,3]
{\"type\":\"bead.closed\",\"payload\":\"text\"}
$(ev_verdict_closed ga-r3 | cut -c1-90)"
eq "closed verdict beads only, each run once, in order; a half-written last line and non-verdict events ignored" \
  "$(gate_event_closed_verdict_runs "$_in" | tr '\n' ' ')" "ga-r1 ga-r2 "
eq "empty input prints nothing" "$(gate_event_closed_verdict_runs "" | wc -l | tr -d ' ')" "0"

# ── 2. gate_verdict_ready_runs (pure) ──────────────────────────────────────────
echo "── 2. the confirm step: running, nothing left open, not skipped ──"
_RUN='[{"id":"r1"},{"id":"r2"},{"id":"r3"},{"id":"r5"}]'
_OPEN='[{"id":"v","labels":["type:quality-gate-verdict","gate-run:r2"]}]'
eq "running + no open verdict + not skipped → ready; r2 still has an open verdict; r3 skipped; r4 not running" \
  "$(gate_verdict_ready_runs "$_RUN" "$_OPEN" "r3" "r1 r2 r3 r4" | tr '\n' ' ')" "r1 "
eq "newline-separated candidates, duplicates collapse to one" \
  "$(gate_verdict_ready_runs "$_RUN" "[]" "" "r1
r5 r1" | tr '\n' ' ')" "r1 r5 "
eq "unparseable running list → nothing is ever 'ready'" "$(gate_verdict_ready_runs "garbage" "[]" "" "r1")" ""
eq "unparseable open list → nothing is ever 'ready'" "$(gate_verdict_ready_runs "$_RUN" "garbage" "" "r1")" ""
eq "empty running list → nothing" "$(gate_verdict_ready_runs "[]" "[]" "" "r1")" ""

# ── 3. gate_midsweep_new_runs: byte offsets, rotation ──────────────────────────
echo "── 3. reading the event log: offset in BYTES, rotation, missing file ──"
# gate_midsweep_new_runs leaves its answer in GATE_MIDSWEEP_NEW and is called WITHOUT $(...): the offset is a global,
# and a look taken in a subshell would advance nothing (every safe point would re-read the same events).
GATE_EVENTS_FILE="$ROOT/events.jsonl"
ev_verdict_closed ga-old > "$GATE_EVENTS_FILE"
gate_midsweep_arm
gate_midsweep_new_runs; eq "an event that was there before the sweep started is not a candidate" "$GATE_MIDSWEEP_NEW" ""
# multi-byte title: a character count used as a byte offset would shift every later look
{ ev_verdict_closed ga-a1 "revisão — ação ✓ 日本語"; ev_other_closed ga-zz; } >> "$GATE_EVENTS_FILE"
gate_midsweep_new_runs; eq "first look after an append (multi-byte title)" "$(printf '%s' "$GATE_MIDSWEEP_NEW" | tr '\n' ' ')" "ga-a1"
eq "the offset is the file size in bytes, in THIS shell" "$GATE_MIDSWEEP_OFF" "$(wc -c < "$GATE_EVENTS_FILE" | tr -d ' ')"
gate_midsweep_new_runs; eq "second look with nothing new → nothing (offset advanced, not repeated)" "$GATE_MIDSWEEP_NEW" ""
ev_verdict_closed ga-a2 >> "$GATE_EVENTS_FILE"
gate_midsweep_new_runs; eq "a later append is read from the right byte (no shift from the multi-byte line)" "$(printf '%s' "$GATE_MIDSWEEP_NEW" | tr '\n' ' ')" "ga-a2"
ev_verdict_closed ga-a3 > "$GATE_EVENTS_FILE"       # rotation: the file is now smaller than the offset
gate_midsweep_new_runs; eq "a rotated (shrunk) file is read whole" "$(printf '%s' "$GATE_MIDSWEEP_NEW" | tr '\n' ' ')" "ga-a3"
GATE_EVENTS_FILE="$ROOT/does-not-exist.jsonl"
gate_midsweep_arm
eq "a missing events file: arm sets no offset" "${GATE_MIDSWEEP_OFF:-unset}" "unset"
gate_midsweep_new_runs; eq "a missing events file: no candidates, rc 0" "$GATE_MIDSWEEP_NEW|$?" "|0"
GATE_EVENTS_FILE="$ROOT/events.jsonl"

# ── 4. the fake-reviewer scenario ───────────────────────────────────────────────
echo "── 4. a fake reviewer closes the verdict bead mid-sweep ──"
GC_CITY="$ROOT/city"                       # gate_midsweep_collect reads $GC_CITY at call time
mkdir -p "$GC_CITY/scripts" "$GATE_LOCK_DIR"
export FAKE_STATE="$ROOT/state"
mkdir -p "$FAKE_STATE"
cat > "$GC_CITY/scripts/bd-list-cached.sh" <<'FAKE'
#!/bin/bash
# stateful fake of the read-cache shim: the two queries gate_midsweep_collect makes
echo x >> "$FAKE_STATE/reads"
[ -f "$FAKE_STATE/fail" ] && exit 1
case "$*" in
  *gate-status:running*) cat "$FAKE_STATE/running.json" ;;
  *type:quality-gate-verdict*) cat "$FAKE_STATE/open.json" ;;
  *) echo "[]" ;;
esac
FAKE
set_running() { local j="[" r; for r in "$@"; do j="$j{\"id\":\"$r\"},"; done; printf '%s\n' "${j%,}]" > "$FAKE_STATE/running.json"; }
set_open()    { local j="[" r; for r in "$@"; do j="$j{\"id\":\"v-$r\",\"labels\":[\"type:quality-gate-verdict\",\"gate-run:$r\"]},"; done; printf '%s\n' "${j%,}]" > "$FAKE_STATE/open.json"; }
set_running; set_open

CHILD_N=0; CHILD_ALL=""; CHILD_RC=0
# the fake child: records the run ids it was handed and "finalizes" them (they leave the running list)
_gate_run_phase_c_child() {
  CHILD_N=$((CHILD_N+1)); CHILD_ALL="${CHILD_ALL}[$1]"
  if [ "$CHILD_RC" = "0" ]; then
    local keep="" r x
    for r in $(jq -r '.[].id' "$FAKE_STATE/running.json"); do
      case " $1 " in *" $r "*) ;; *) keep="$keep $r" ;; esac
    done
    set_running $keep
  fi
  return "$CHILD_RC"
}
GATE_LOCK_ENABLED=1; GATE_MIDSWEEP_ENABLED=1; GATE_PHASE_C_ONLY=0; GATE_PHASE_C_ENABLED=1
ev_verdict_closed ga-old > "$GATE_EVENTS_FILE"
gate_midsweep_arm                                   # what the sweep does just before Phase C

: > "$FAKE_STATE/reads"
reads() { wc -l < "$FAKE_STATE/reads" | tr -d ' '; }
gate_midsweep_collect "p0"
eq "nothing closed → no child" "$CHILD_N" "0"
eq "nothing closed → not a single bd read (the hint is a local file read)" "$(reads)" "0"

# r1: the fake reviewer closes its verdict bead while the sweep is busy
set_running r1; set_open; ev_verdict_closed r1 >> "$GATE_EVENTS_FILE"
printf 'OLD\n' > "$GATE_LOCK_HB"
gate_midsweep_collect "p1"
eq "the reviewer closed the verdict → the child is started once, for that run" "${CHILD_ALL}" "[r1]"
eq "the heartbeat was refreshed around the child (the lock stays provably live)" "$(head -n1 "$GATE_LOCK_HB")" "$GATE_LOCK_TOKEN"
case "$(cat "$LOGF")" in *"Mid-sweep (p1): verdict(s) closed for run(s) r1"*) ok "the sweep log says what it collected and where" ;; *) bad "no 'Mid-sweep (p1)' log line" ;; esac
_r_before="$(reads)"
gate_midsweep_collect "p2"
eq "the next safe point finds nothing new → not collected twice" "$CHILD_N" "1"
eq "…and makes no bd read at all" "$(reads)" "$_r_before"
eq "…and the offset in the sweep's own shell is the file size" "$GATE_MIDSWEEP_OFF" "$(wc -c < "$GATE_EVENTS_FILE" | tr -d ' ')"

# r4: the child fails (rc 1) and leaves the run running; the same close is replayed
CHILD_RC=1; set_running r4; ev_verdict_closed r4 >> "$GATE_EVENTS_FILE"
gate_midsweep_collect "p3"
eq "second run collected" "${CHILD_ALL}" "[r1][r4]"
case "$(cat "$LOGF")" in *"WARN Mid-sweep (p3): Phase-C-only pass exited rc=1"*) ok "a failing child is warned about, the sweep goes on" ;; *) bad "no warning for a failing child" ;; esac
ev_verdict_closed r4 >> "$GATE_EVENTS_FILE"        # the same close shows up again (replay) and r4 is STILL running
gate_midsweep_collect "p4"
eq "a replayed close of a run already handed to a child is not handed again (done-list)" "$CHILD_N" "2"
CHILD_RC=0

# r5: two reviewers — the first close is not enough, the second is
set_running r5; set_open r5; ev_verdict_closed r5 >> "$GATE_EVENTS_FILE"
gate_midsweep_collect "p5"
eq "first of two verdicts closed (the other still open) → not collected yet" "$CHILD_N" "2"
set_open; ev_verdict_closed r5 >> "$GATE_EVENTS_FILE"
gate_midsweep_collect "p6"
eq "second verdict closes → collected, once (nothing lost)" "${CHILD_ALL}" "[r1][r4][r5]"

# r6: the run this very sweep is admitting is never touched
GATE_ADMITTING_RUN="r6"; set_running r6; ev_verdict_closed r6 >> "$GATE_EVENTS_FILE"
gate_midsweep_collect "p7"
eq "the admitting run is excluded" "$CHILD_N" "3"
GATE_ADMITTING_RUN=""

# r7: the confirming reads fail once — the candidate is kept and retried at the next safe point
set_running r7; ev_verdict_closed r7 >> "$GATE_EVENTS_FILE"; : > "$FAKE_STATE/fail"
gate_midsweep_collect "p8"
eq "confirm read failed → no child (fail closed)" "$CHILD_N" "3"
rm -f "$FAKE_STATE/fail"
gate_midsweep_collect "p9"
eq "the next safe point retries the kept candidate (no new event needed)" "${CHILD_ALL}" "[r1][r4][r5][r7]"

# r8 + r9 closed in the same stretch → ONE child for both
set_running r8 r9; { ev_verdict_closed r8; ev_verdict_closed r9; } >> "$GATE_EVENTS_FILE"
gate_midsweep_collect "p10"
eq "two runs ready at once → a single child handed both" "${CHILD_ALL}" "[r1][r4][r5][r7][r8 r9]"

# a closed non-verdict bead and a bead.created never trigger anything
set_running r10; { ev_other_closed r10; ev_verdict_created r10; } >> "$GATE_EVENTS_FILE"
gate_midsweep_collect "p11"
eq "a closed run bead / a created verdict bead are not hints" "$CHILD_N" "5"

# kill switches: each one alone turns the whole thing into the old behaviour
for _sw in GATE_MIDSWEEP_ENABLED GATE_LOCK_ENABLED GATE_PHASE_C_ENABLED GATE_PHASE_C_ONLY; do
  gate_midsweep_arm
  set_running r11; ev_verdict_closed r11 >> "$GATE_EVENTS_FILE"
  _save="${!_sw}"
  case "$_sw" in GATE_PHASE_C_ONLY) printf -v "$_sw" '%s' 1 ;; *) printf -v "$_sw" '%s' 0 ;; esac
  gate_midsweep_collect "off-$_sw"
  printf -v "$_sw" '%s' "$_save"
  eq "$_sw flipped → no child" "$CHILD_N" "5"
done

# ── 5. the Phase-C-only child's own filter (the jq program in the live Phase C) ─
echo "── 5. the child touches ONLY the runs its parent confirmed ──"
_FILTER='($ids | split(" ")) as $w | [ .[] | select(.id as $i | $w | index($i)) ]'
if grep -qF "$_FILTER" "$DISPATCHER"; then
  ok "the live Phase C carries exactly this include-filter"
else
  bad "the live Phase C does not carry the include-filter this test runs — update the test with the code"
fi
_PC='[{"id":"a"},{"id":"b"},{"id":"c"}]'
eq "ids 'b c' → only b and c" "$(printf '%s' "$_PC" | jq -c -r --arg ids "b c" "$_FILTER | map(.id) | join(\",\")")" "b,c"
eq "no ids → nothing (never 'everything')" "$(printf '%s' "$_PC" | jq -c --arg ids "" "$_FILTER")" "[]"
eq "an id that is not running → nothing" "$(printf '%s' "$_PC" | jq -c --arg ids "zz" "$_FILTER")" "[]"

# ── 6. lock borrowing (unit) ────────────────────────────────────────────────────
echo "── 6. lock borrowing: provably a direct child of the live holder, holding that holder's heartbeat ──"
# probe_borrow <dispatcher> <variant>: runs _gate_lock_borrow_ok in a subshell that sourced <dispatcher> and prints ok|refused
probe_borrow() {
  ( export TMPDIR="$ROOT/pb.$RANDOM"; mkdir -p "$TMPDIR"
    GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo srcfail; exit 0; }
    set +e
    mkdir -p "$GATE_LOCK_DIR"
    _tok="$$:tok"                       # this subshell's own pid is the "holder"
    printf '%s\n' "$_tok" > "$GATE_LOCK_HB"
    GATE_PHASE_C_ONLY=1; GATE_LOCK_ENABLED=1; GATE_LOCK_BORROW_TOKEN="$_tok"; _ppid="$$"
    case "$2" in
      valid) ;;
      wrong-ppid) _ppid="1" ;;
      hb-mismatch) printf 'other:holder\n' > "$GATE_LOCK_HB" ;;
      no-lock-dir) rm -f "$GATE_LOCK_HB"; rmdir "$GATE_LOCK_DIR" ;;
      not-child-mode) GATE_PHASE_C_ONLY=0 ;;
      lock-disabled) GATE_LOCK_ENABLED=0 ;;
      empty-token) GATE_LOCK_BORROW_TOKEN="" ;;
      junk-pid) GATE_LOCK_BORROW_TOKEN="abc:tok"; _ppid="abc" ;;
      dead-holder) sleep 0 & _dp=$!; wait "$_dp" 2>/dev/null; GATE_LOCK_BORROW_TOKEN="$_dp:tok"; printf '%s\n' "$_dp:tok" > "$GATE_LOCK_HB"; _ppid="$_dp" ;;
    esac
    if _gate_lock_borrow_ok "$_ppid"; then echo ok; else echo refused; fi )
}
eq "a direct child of the live holder with the holder's heartbeat → may borrow" "$(probe_borrow "$DISPATCHER" valid)" "ok"
for _v in wrong-ppid hb-mismatch no-lock-dir not-child-mode lock-disabled empty-token junk-pid dead-holder; do
  eq "refused: $_v" "$(probe_borrow "$DISPATCHER" "$_v")" "refused"
done

# probe_release <dispatcher>: a BORROWER's _release_gate_lock must leave the lock; a holder's must remove it
probe_release() {
  ( export TMPDIR="$ROOT/pr.$RANDOM"; mkdir -p "$TMPDIR"
    GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo srcfail; exit 0; }
    set +e
    mkdir -p "$GATE_LOCK_DIR"; printf '%s\n' "$GATE_LOCK_TOKEN" > "$GATE_LOCK_HB"
    GATE_LOCK_BORROWED="$2"
    _release_gate_lock
    if [ -d "$GATE_LOCK_DIR" ]; then echo kept; else echo removed; fi )
}
eq "a borrower's _release_gate_lock leaves the lock to its parent" "$(probe_release "$DISPATCHER" 1)" "kept"
eq "control: the same call from the holder removes it (the probe can see a release)" "$(probe_release "$DISPATCHER" 0)" "removed"

# ── 7. mutation proofs: the checks above have teeth ─────────────────────────────
echo "── 7. mutation proofs ──"
mutant() {   # mutant <name> <fixed-string-to-delete-lines-containing>  → path of the mutated copy (exactly 1 line removed)
  local out="$ROOT/mutant-$1.sh"
  grep -vF -- "$2" "$DISPATCHER" > "$out"
  local n=$(( $(wc -l < "$DISPATCHER") - $(wc -l < "$out") ))
  [ "$n" = "1" ] || { echo "MUTANT-ERROR:$n"; return 1; }
  echo "$out"
}
M="$(mutant release '[ "${GATE_LOCK_BORROWED:-0}" = "1" ] && return 0')"
eq "mutant (borrower may release): the 'kept' check goes red" "$(probe_release "$M" 1)" "removed"
M="$(mutant ppid '[ "$_pid" = "$_ppid" ] || return 1')"
eq "mutant (no direct-child check): 'wrong-ppid' is no longer refused" "$(probe_borrow "$M" wrong-ppid)" "ok"
M="$(mutant hb '[ "$_hb" = "$_tok" ] || return 1')"
eq "mutant (no heartbeat match): 'hb-mismatch' is no longer refused" "$(probe_borrow "$M" hb-mismatch)" "ok"
M="$(mutant alive 'kill -0 "$_pid" 2>/dev/null || return 1')"
eq "mutant (no liveness check): 'dead-holder' is no longer refused" "$(probe_borrow "$M" dead-holder)" "ok"

# probe_reads <dispatcher>: one verdict close, three safe points → how many bd reads did the sweep pay for?
probe_reads() {
  ( export TMPDIR="$ROOT/prd.$RANDOM"; mkdir -p "$TMPDIR"
    GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo srcfail; exit 0; }
    set +e
    log() { :; }; warn() { :; }
    GC_CITY="$TMPDIR/city"; mkdir -p "$GC_CITY/scripts" "$GATE_LOCK_DIR"
    cp "$ROOT/city/scripts/bd-list-cached.sh" "$GC_CITY/scripts/"
    export FAKE_STATE="$TMPDIR/st"; mkdir -p "$FAKE_STATE"; : > "$FAKE_STATE/reads"
    printf '[{"id":"r1"}]\n' > "$FAKE_STATE/running.json"; printf '[]\n' > "$FAKE_STATE/open.json"
    _gate_run_phase_c_child() { return 0; }          # leaves r1 "running": only the done-list stands between it and a re-collect
    GATE_EVENTS_FILE="$TMPDIR/ev.jsonl"; : > "$GATE_EVENTS_FILE"
    GATE_LOCK_ENABLED=1; GATE_MIDSWEEP_ENABLED=1; GATE_PHASE_C_ONLY=0; GATE_PHASE_C_ENABLED=1
    gate_midsweep_arm
    ev_verdict_closed r1 >> "$GATE_EVENTS_FILE"
    gate_midsweep_collect a; gate_midsweep_collect b; gate_midsweep_collect c
    wc -l < "$FAKE_STATE/reads" | tr -d ' ' )
}
eq "a verdict close costs the sweep exactly ONE pair of confirming reads, however many safe points follow" "$(probe_reads "$DISPATCHER")" "2"
M="$(mutant offset '  GATE_MIDSWEEP_OFF=$_size')"
eq "mutant (the offset never advances): every safe point re-reads and re-confirms — the load check goes red" "$(probe_reads "$M")" "6"

# ── 8. the child as a REAL process (scratch city; nothing of the real city is touched) ──
echo "── 8. the Phase-C-only child as a real process ──"
CITY2="$ROOT/city2"; A2="$CITY2/packs/town-deltas/assets"
mkdir -p "$A2" "$CITY2/.gc/logs" "$ROOT/fakebin" "$ROOT/tmp8"
ln -s "$REPO_ROOT/scripts" "$CITY2/scripts"
ln -s "$REPO_ROOT/agents" "$CITY2/agents"
for _f in "$SELF_DIR"/*; do
  _b="$(basename "$_f")"
  case "$_b" in
    quality-gate-dispatcher.sh) continue ;;
  esac
  if [ -f "$_f" ] && grep -q '^GC_CITY="/Users/athos/gt/.gascity-gastown-hq"' "$_f" 2>/dev/null; then
    sed "s|^GC_CITY=\"/Users/athos/gt/.gascity-gastown-hq\"|GC_CITY=\"$CITY2\"|" "$_f" > "$A2/$_b"
  else
    ln -s "$_f" "$A2/$_b"
  fi
done
sed "s|^GC_CITY=.*|GC_CITY=\"$CITY2\"|" "$SELF_DIR/quality-gate-dispatcher.sh" > "$A2/quality-gate-dispatcher.sh"
# fakes: no bd/gc call may reach the real city
printf '#!/bin/bash\ncase "$*" in *"--json"*) echo "[]" ;; esac\nexit 0\n' > "$ROOT/fakebin/bd"
printf '#!/bin/bash\nexit 0\n' > "$ROOT/fakebin/gc"
chmod +x "$ROOT/fakebin/bd" "$ROOT/fakebin/gc"
LOCK2="$ROOT/tmp8/quality-gate-dispatcher$(printf '%s' "$CITY2" | tr '/ ' '__').lock.d"
LOG2="$CITY2/.gc/logs/quality-gate-dispatcher.log"
run_child() {   # run_child <token> [via-shell]: starts the real dispatcher as a Phase-C-only child of THIS shell
  # BD_CACHE_* keep the read-cache shim out of the real city's cache (a fake `[]` there would be read by a real sweep).
  # DRAIN_WINDOW_OVERRIDE: ga-a2v0bz — a run of a dispatcher must not depend on the time of day (selftest-drain-pin-class).
  local p n=0
  if [ "${2:-}" = "via-shell" ]; then
    PATH="$ROOT/fakebin:$PATH" TMPDIR="$ROOT/tmp8" GC_CITY="$CITY2" BD_CACHE_OFF=1 BD_CACHE_DIR="$ROOT/cache8" \
      DRAIN_WINDOW_OVERRIDE="OPEN" \
      GATE_PHASE_C_ONLY=1 GATE_PHASE_C_ONLY_RUNS="none" GATE_LOCK_BORROW_TOKEN="$1" \
      bash -c 'bash "$1"; rc=$?; exit $rc' _ "$A2/quality-gate-dispatcher.sh" >/dev/null 2>&1 &
  else
    PATH="$ROOT/fakebin:$PATH" TMPDIR="$ROOT/tmp8" GC_CITY="$CITY2" BD_CACHE_OFF=1 BD_CACHE_DIR="$ROOT/cache8" \
      DRAIN_WINDOW_OVERRIDE="OPEN" \
      GATE_PHASE_C_ONLY=1 GATE_PHASE_C_ONLY_RUNS="none" GATE_LOCK_BORROW_TOKEN="$1" \
      bash "$A2/quality-gate-dispatcher.sh" >/dev/null 2>&1 &
  fi
  p=$!
  # a watchdog instead of `timeout`: a wrapper process would BE the child's parent and the borrow would rightly be refused
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n+1)); done
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
  wait "$p"
}
: > "$LOG2"
run_child "99999:nolock"; _rc=$?
eq "no lock at all: a child with a made-up token exits 0" "$_rc" "0"
[ ! -e "$LOCK2" ] && ok "…and did not create a lock" || bad "a refused child created the lock dir"
case "$(cat "$LOG2")" in *"Phase-C-only pass refused"*) ok "…and says it refused" ;; *) bad "no 'refused' line in the log" ;; esac
case "$(cat "$LOG2")" in *"=== Dispatcher sweep start"*) bad "a refused child logged a sweep-start banner (watchdogs count it)" ;; *) ok "…and logged no sweep-start banner" ;; esac

mkdir -p "$LOCK2"; printf 'other:holder\n' > "$LOCK2/heartbeat"
run_child "$$:tok"; _rc=$?
eq "someone else's lock: the child exits 0" "$_rc" "0"
eq "…and leaves that lock's heartbeat alone" "$(head -n1 "$LOCK2/heartbeat")" "other:holder"

printf '%s\n' "$$:tok" > "$LOCK2/heartbeat"
run_child "$$:tok" via-shell; _rc=$?
eq "not a DIRECT child of the holder (a shell in between), even with the right token: exit 0" "$_rc" "0"
case "$(tail -n 5 "$LOG2")" in *"Phase-C-only pass refused"*) ok "…and it refused" ;; *) bad "the indirect child was not refused" ;; esac

: > "$LOG2"
run_child "$$:tok"; _rc=$?
eq "a valid borrower (direct child, holder's token and heartbeat) finishes with exit 0" "$_rc" "0"
[ -d "$LOCK2" ] && ok "…and the lock is STILL there (its parent is still waiting)" || bad "the borrower released the parent's lock"
eq "…with the holder's heartbeat" "$(head -n1 "$LOCK2/heartbeat" 2>/dev/null)" "$$:tok"
case "$(cat "$LOG2")" in *"Phase-C-only pass (mid-sweep, borrowed lock)"*) ok "…logged the child banner" ;; *) bad "no child banner" ;; esac
case "$(cat "$LOG2")" in *"Phase-C-only pass done; back to the admitting sweep"*) ok "…and left before Step 0a (the admission is the parent's)" ;; *) bad "the child did not reach its early exit" ;; esac
case "$(cat "$LOG2")" in *"=== Dispatcher sweep start"*) bad "the child logged a sweep-start banner" ;; *) ok "…and logged no sweep-start banner" ;; esac
case "$(cat "$LOG2")" in *"Step 0b"*|*"Attempting to claim marker"*|*"Spawning "*) bad "the child went on to admit work" ;; *) ok "…and admitted nothing" ;; esac

# ── 9. the wiring is in the live script ─────────────────────────────────────────
echo "── 9. the live wiring ──"
D="$SELF_DIR/quality-gate-dispatcher.sh"
_calls="$(grep -c '^gate_midsweep_collect "step-' "$D")"
if [ "$_calls" -ge 10 ]; then ok "safe-point calls at top level (column 0) before the admission steps: $_calls"; else bad "expected >= 10 top-level safe-point calls, found $_calls"; fi
_ack_line="$(grep -n '^  gate_midsweep_collect "step-7b-ack"' "$D" | cut -d: -f1)"
_sleep_line="$(grep -n '^  sleep "\$ACK_WAIT_SECS" || true' "$D" | cut -d: -f1)"
if [ -n "$_ack_line" ] && [ -n "$_sleep_line" ] && [ "$_ack_line" -lt "$_sleep_line" ] && [ $((_sleep_line - _ack_line)) -le 2 ]; then
  ok "the ACK loop collects right before it sleeps"
else bad "the ACK-loop safe point is missing or not next to the sleep (call=$_ack_line sleep=$_sleep_line)"; fi
_indented="$(grep -n '^[[:space:]]\+gate_midsweep_collect ' "$D" | grep -v 'step-7b-ack' | grep -v '^[0-9]*:[[:space:]]*#' | wc -l | tr -d ' ')"
eq "no other safe-point call is nested inside a block/function/pipe" "$_indented" "0"
_arm="$(grep -n 'gate_midsweep_arm; fi' "$D" | head -1 | cut -d: -f1)"
_pcq="$(grep -n 'PHASE_C_RUNNING_JSON=\$(bash' "$D" | head -1 | cut -d: -f1)"
if [ -n "$_arm" ] && [ -n "$_pcq" ] && [ "$_arm" -lt "$_pcq" ]; then ok "the event offset is armed before Phase C reads the running runs"; else bad "arm is not before Phase C (arm=$_arm phase-c-read=$_pcq)"; fi
_adm="$(grep -n '^GATE_ADMITTING_RUN="\$GATE_RUN_ID"' "$D" | cut -d: -f1)"
_gr="$(grep -n '^log "Gate-run bead: \$GATE_RUN_ID"' "$D" | cut -d: -f1)"
if [ -n "$_adm" ] && [ -n "$_gr" ] && [ "$_adm" -gt "$_gr" ] && [ $((_adm - _gr)) -le 4 ]; then ok "the run being admitted is stamped right after its bead is created"; else bad "GATE_ADMITTING_RUN is not set after the gate-run bead is created"; fi
_exit="$(grep -n 'Phase-C-only pass done; back to the admitting sweep' "$D" | head -1 | cut -d: -f1)"
_s0a="$(grep -n '^# ── Step 0a: TTL recovery' "$D" | head -1 | cut -d: -f1)"
if [ -n "$_exit" ] && [ -n "$_s0a" ] && [ "$_exit" -lt "$_s0a" ]; then ok "the child exits before Step 0a"; else bad "the child's early exit is not before Step 0a"; fi
grep -q '^GATE_MIDSWEEP_ENABLED="${GATE_MIDSWEEP_ENABLED:-1}"' "$D" && ok "kill switch GATE_MIDSWEEP_ENABLED exists and defaults to on" || bad "kill switch missing"

# ── 10. fewer bd round-trips on the spawn path: assign_verdict_bead_verified reads the bead ONCE per try ──
echo "── 10. assign_verdict_bead_verified: one bd show per try ──"
# probe_assign <dispatcher> <mode> → "rc show-count"
#   meta-only : the assignee never lands, metadata.gc.session_name does   (the ga-qqtoo case)
#   assignee  : the assignee lands on the first read
probe_assign() {
  ( export TMPDIR="$ROOT/pa.$RANDOM"; mkdir -p "$TMPDIR"
    GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo srcfail; exit 0; }
    set +e
    log() { :; }; warn() { :; }
    SHOWS="$TMPDIR/shows"; : > "$SHOWS"; PA_MODE="$2"
    bd() {
      case "$*" in
        *" show "*) echo x >> "$SHOWS"
          if [ "$PA_MODE" = "meta-only" ]; then echo '[{"id":"v1","assignee":"","metadata":{"gc.session_name":"sess-1"}}]'
          else echo '[{"id":"v1","assignee":"sess-1","metadata":{}}]'; fi ;;
        *) return 0 ;;
      esac
    }
    sleep() { :; }
    assign_verdict_bead_verified v1 sess-1 probe; _rc=$?
    echo "$_rc $(wc -l < "$SHOWS" | tr -d ' ')" )
}
eq "assignee lands: rc 0 after exactly one read" "$(probe_assign "$DISPATCHER" assignee)" "0 1"
eq "only the metadata link lands: rc 0 after exactly one read (it used to be two reads of the same bead)" "$(probe_assign "$DISPATCHER" meta-only)" "0 1"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "── results: $PASS passed, 0 failed ──"
  exit 0
fi
echo "── results: $PASS passed, $FAIL failed ──"
exit 1
