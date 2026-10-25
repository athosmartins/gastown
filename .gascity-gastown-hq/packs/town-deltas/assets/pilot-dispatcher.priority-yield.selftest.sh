#!/usr/bin/env bash
# pilot-dispatcher.priority-yield.selftest.sh — ga-5fn5p3
#
# Athos, 2026-10-12: "Por que diabos estamos entregando beads p2 e p3 enquanto temos dezenas de p0 e p1 pra trabalharmos?"
# The city-wide order (priority > type > age) only ranked beads INSIDE one pool; nothing compared a PS bead with a WA bead. The rule
# under test: while a P0/P1 bead waits behind a pool that is at its session cap, no P2/P3/P4 bead opens a NEW session in any pool.
#
# The bead's own selftest spec, in the order it wrote it — these are the CONTROLS, and each one is its own scenario below:
#   C1  P0 of WA waiting + P2 of PS ready                  -> the PS bead cedes (no claim, no session)            [part C]
#   C2  no P0/P1 waiting + P2 of PS ready                  -> the PS bead dispatches, exactly as before             [part C]
#   C3  the WA reading FAILS + P2 of PS ready              -> the PS bead dispatches, the sweep says it was blind   [part C]
# Without C2 and C3 a rule that cedes EVERYTHING would pass C1: the controls are what keep it honest.
#
# Functions are extracted verbatim from the dispatcher (the `SELFTEST-EXTRACT pilot-priority-yield` block, plus
# _pilot_priority_project_emit) and driven in a subshell. Only the pool-cap probe (_pilot_pool_cap_full_for: its own selftests
# are pilot-dispatcher.pool-cap-fail-closed / ga-in9ebr) and the rig/builder lookups are stubbed; the priority class comes from
# the REAL work-order library (scripts/work-order.sh), so "what counts as P0/P1/P2+" is the city's definition, not a copy.
#
# ga-qmfm8r (section K): a P0/P1 whose label the TARGET POOL'S OWN PROBE refuses (delivery:pending-restart on wa-worker) is not "waiting" —
# no worker takes it, so ceding to it only starves everything else (13/10: 9h, 157 P2+ ceded to wa-gg9uhf). The refusal list comes from
# scripts/pool-probe-vetoes.sh, the one place that owns it; this selftest sources the REAL library, it carries no list of its own. The
# Mayor is told ONCE per (bead, reasons) through `gc mail send mayor` (stubbed here: the sandbox PATH has no real gc).
#
# Every scenario that asserts the FIX fails on a dispatcher without the block (FATAL: block not found) and on the mutants listed
# at the bottom of the bead comment. Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
WO_LIB="${PILOT_WORK_ORDER_LIB:-$SELF_DIR/scripts/work-order.sh}"
PPV_LIB="${PILOT_POOL_VETOES_LIB:-$SELF_DIR/scripts/pool-probe-vetoes.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$WO_LIB" ]     || { echo "FATAL: work-order library not found at $WO_LIB" >&2; exit 2; }
[ -f "$PPV_LIB" ]    || { echo "FATAL: pool-probe-vetoes library not found at $PPV_LIB" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
# shellcheck disable=SC1090
. "$WO_LIB" || { echo "FATAL: cannot source $WO_LIB" >&2; exit 2; }
[ -n "${WORK_ORDER_JQ_DEFS:-}" ] || { echo "FATAL: $WO_LIB did not define WORK_ORDER_JQ_DEFS" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
BLOCK="$(awk '/SELFTEST-EXTRACT pilot-priority-yield: BEGIN/{f=1;next} /SELFTEST-EXTRACT pilot-priority-yield: END/{f=0} f' "$DISPATCHER")"
[ -n "$BLOCK" ] || { echo "FATAL: no 'SELFTEST-EXTRACT pilot-priority-yield' block in $DISPATCHER (the rule is not there)" >&2; exit 2; }
PROJECT_SRC="$(fn_src _pilot_priority_project_emit)"
[ -n "$PROJECT_SRC" ] || { echo "FATAL: _pilot_priority_project_emit() not found in $DISPATCHER" >&2; exit 2; }
FUNCS="$BLOCK
$PROJECT_SRC"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-priority-yield-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc" "$WORK/store"

# Fake bd (a real executable: `timeout` exec()s it). `show` answers from $W/show.<id>.json; every WRITE is recorded.
cat > "$WORK/bin/bd" <<'BDEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
args="$*"
case "$args" in
  *" show "*)
    id=""; prev=""
    for a in "$@"; do [ "$prev" = "show" ] && id="$a"; prev="$a"; done
    [ -f "$W/show.$id.json" ] && { cat "$W/show.$id.json"; exit 0; }
    exit 1 ;;
  *" list "*)
    [ -e "$W/bd.list.fail" ] && exit 1
    asg=""; prev=""
    for a in "$@"; do [ "$prev" = "--assignee" ] && asg="$a"; case "$a" in --assignee=*) asg="${a#--assignee=}" ;; esac; prev="$a"; done
    [ -f "$W/inprog.$asg.json" ] && { cat "$W/inprog.$asg.json"; exit 0; }
    echo '[]'; exit 0 ;;
  *" label "*|*" update "*) echo "$args" >> "$W/bd.writes"; [ -e "$W/bd.update.fail" ] && exit 1; exit 0 ;;
esac
exit 0
BDEOF
# Fake gc (ga-qmfm8r): records every call on ONE line in $W/gc.calls (newlines of the mail body flattened) and fails iff $W/gc.fail exists.
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
printf 'CALL %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$W/gc.calls"
case "$*" in
  *"session list"*)
    [ -e "$W/sessions.fail" ] && exit 1
    if [ -f "$W/sessions.json" ]; then cat "$W/sessions.json"; else echo '{"ok":true,"schema_version":"1","sessions":[],"summary":{}}'; fi
    exit 0 ;;
esac
[ -e "$W/gc.fail" ] && exit 1
exit 0
GCEOF
cat > "$WORK/bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
shift
exec "$@"
TOEOF
chmod +x "$WORK/bin/bd" "$WORK/bin/gc" "$WORK/bin/timeout"
sandbox_path_init "$WORK" jq || exit 2

reset() { rm -f "$WORK"/cap.* "$WORK"/bd.writes "$WORK"/log.txt "$WORK"/unmark.log "$WORK"/show.*.json "$WORK"/crew.* "$WORK"/builders.* "$WORK/city/.gc/priority-yield.off" "$WORK"/gc.calls "$WORK"/gc.fail "$WORK"/unservable.state "$WORK"/sessions.json "$WORK"/sessions.fail "$WORK"/inprog.*.json "$WORK"/bd.list.fail "$WORK"/bd.update.fail "$WORK"/owner.inactive.* "$WORK"/stall.state "$WORK"/stall.state.tmp.*; }
logged()   { grep -qF -- "$1" "$WORK/log.txt" 2>/dev/null; }
warned()   { grep -qF -- "warn	"  "$WORK/log.txt" 2>/dev/null && grep -F -- "warn	" "$WORK/log.txt" | grep -qF -- "$1"; }
writes()   { [ -f "$WORK/bd.writes" ] && wc -l < "$WORK/bd.writes" | tr -d ' ' || echo 0; }
mails()     { local n; n=$(grep -c 'mail send mayor' "$WORK/gc.calls" 2>/dev/null) || true; echo "${n:-0}"; }
gc_calls()  { [ -f "$WORK/gc.calls" ] && wc -l < "$WORK/gc.calls" | tr -d ' ' || echo 0; }
cap_calls() { [ -f "$WORK/cap.calls" ] && wc -l < "$WORK/cap.calls" | tr -d ' ' || echo 0; }

# bead <id> <priority|-> <routed_to|-> <store> [type] [label,label...] — one bead as the emit's ordered population carries it.
bead() {
  local _p="$2" _r="$3"
  jq -cn --arg id "$1" --arg p "$_p" --arg r "$_r" --arg s "$4" --arg t "${5:-task}" --arg l "${6:-}" '
    {id: $id, issue_type: $t, status: "open", created_at: "2026-10-01T00:00:00Z", _emit_store: $s,
     metadata: (if $r == "-" then {} else {"gc.routed_to": $r} end)}
    + (if $l == "" then {} else {labels: ($l | split(","))} end)
    + (if $p == "-" then {} elif $p == "str" then {priority: "2"} else {priority: ($p | tonumber)} end)'
}
arr() { local _o="" _b; for _b in "$@"; do _o="${_o:+$_o,}$_b"; done; printf '[%s]' "$_o"; }

# cap <pool> <live> <max> — the stubbed pool-cap probe answers "full" iff live >= max. cap <pool> unreadable — the count cannot be read.
cap() { if [ "$2" = "unreadable" ]; then : > "$WORK/cap.$1.unreadable"; else printf '%s %s' "$2" "$3" > "$WORK/cap.$1"; fi; }

# run_py <script> — ONE sweep's worth of calls in one shell, the dispatcher block loaded verbatim, the lookups stubbed.
# stdout = whatever the script prints; the log lines land in $WORK/log.txt.
run_py() {
  local _script="$1"
  (
    PATH="$SANDBOX_PATH"
    SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    GC_CITY="$WORK/city"; DRY_RUN=0
    unset PILOT_PRIORITY_YIELD PILOT_PRIORITY_YIELD_OFF_FILE
    PILOT_PRIORITY_UNSERVABLE_FILE="$WORK/unservable.state"
    # shellcheck disable=SC1090
    . "$PPV_LIB" || exit 97
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    # The pool-cap probe, stubbed: same contract as the real one (rc 0 = positively full, sets _PCAP_*; rc 1 = not full or cannot tell,
    # with _PCAP_COUNT_UNREADABLE=1 for "cannot tell"). Counts its calls.
    _pilot_pool_cap_full_for() {
      local _routed _live _max
      _PCAP_COUNT_UNREADABLE=""
      _routed=$(printf '%s' "$1" | jq -r '.metadata["gc.routed_to"] // ""' 2>/dev/null)
      echo "$_routed" >> "$WORK/cap.calls"
      [ -e "$WORK/cap.$_routed.unreadable" ] && { _PCAP_COUNT_UNREADABLE=1; return 1; }
      [ -f "$WORK/cap.$_routed" ] || return 1
      read -r _live _max < "$WORK/cap.$_routed"
      [ "$_live" -lt "$_max" ] && return 1
      _PCAP_POOL="$_routed"; _PCAP_LIVE="$_live"; _PCAP_MAX="$_max"
      return 0
    }
    rig_to_builders() { cat "$WORK/builders.$1" 2>/dev/null || true; }
    rig_has_persistent_crew_capability() { [ -e "$WORK/crew.$1" ]; }
    unmark_pool_builder() { echo "$1" >> "$WORK/unmark.log"; }
    _topup_pending_store() { [ -d "$WORK/store" ] && [ -e "$WORK/store.ok" ] && { printf '%s' "$WORK/store"; return 0; }; return 1; }
    # ga-2lca0l: the sweep's active-owner roster, stubbed (live + not asleep + not idle past the threshold); a name is inactive iff its marker exists.
    _session_is_active_owner() { [ -n "${1:-}" ] && [ ! -e "$WORK/owner.inactive.$1" ]; }
    _DEADWORKER_OK=1   # the sweep's roster is trustworthy (the dispatcher sets 0 when it is not); the L3e case overrides it
    PILOT_YIELD_STALL_FILE="$WORK/stall.state"
    eval "$FUNCS"
    eval "$_script"
  )
}

# scan_with <emit-array-json> — project the emit's population, then scan it (the order the dispatcher does it in).
scan_with() { printf '_pilot_priority_project_emit %q; _pilot_priority_waiting_scan; echo "WAIT=${_PY_WAIT_ID:-} BLIND=${_PY_BLIND}"' "$1"; }

echo "pilot-dispatcher.priority-yield.selftest — P2+ cedes to a P0/P1 that waits for capacity, in ANY pool (ga-5fn5p3)"

# ── A: the emit's projection ─────────────────────────────────────────────────────────────────────────────────────────
echo "A. projection of the emit's ordered population"
reset
POP="$(arr "$(bead wa-p0 0 wa-worker wa)" "$(bead ps-p1 1 ps-worker ps)" "$(bead wa-p2 2 wa-worker wa)" "$(bead wa-new0 0 - wa)" \
           "$(bead crew-p0 0 oracle-wa wa)" "$(bead dog-p1 1 gastown.dog hq)" "$(bead nop - wa-worker wa)" "$(bead strp str ps-worker ps)")"
out="$(run_py "_pilot_priority_project_emit '$POP'; echo \"OK=\$_PY_EMIT_OK\"; echo \"\$_PY_P01\" | jq -r '[.[].id] | join(\",\")'; echo \"\$_PY_CLASS_BY_ID\" | jq -c '.'")"
[ "$(echo "$out" | sed -n 1p)" = "OK=1" ] && ok "A1 both projections made → _PY_EMIT_OK=1" || bad "A1 emit not ok: $out"
[ "$(echo "$out" | sed -n 2p)" = "wa-p0,ps-p1" ] \
  && ok "A2 P0/P1 list = only beads ALREADY committed to wa-worker|ps-worker, in the emit's order (first-sight, crew and dog beads are not 'waiting for a pool')" \
  || bad "A2 P0/P1 list wrong: '$(echo "$out" | sed -n 2p)'"
cls="$(echo "$out" | sed -n 3p)"
[ "$cls" = '{"wa-p0":0,"ps-p1":1,"wa-p2":2,"wa-new0":0,"crew-p0":0,"dog-p1":1,"nop":5,"strp":5}' ] \
  && ok "A3 class map covers EVERY bead with the library's class; an unreadable priority is class 5, never 2" || bad "A3 class map wrong: $cls"
out="$(run_py "WORK_ORDER_JQ_DEFS=''; _pilot_priority_project_emit '$POP'; echo \"OK=\$_PY_EMIT_OK P01=[\$_PY_P01] CLS=[\$_PY_CLASS_BY_ID]\"")"
[ "$out" = "OK=0 P01=[] CLS=[]" ] && ok "A4 library definitions not loaded → OK=0 and BOTH empty ('cannot tell', not 'nobody waits')" || bad "A4: $out"
out="$(run_py "_pilot_priority_project_emit 'not json at all'; echo \"OK=\$_PY_EMIT_OK P01=[\$_PY_P01] CLS=[\$_PY_CLASS_BY_ID]\"")"
[ "$out" = "OK=0 P01=[] CLS=[]" ] && ok "A5 unparseable population → OK=0, both empty" || bad "A5: $out"
out="$(run_py "_pilot_priority_project_emit '[]'; echo \"OK=\$_PY_EMIT_OK P01=[\$_PY_P01]\"")"
[ "$out" = "OK=1 P01=[[]]" ] && ok "A6 an EMPTY readable population is OK=1 with no waiter — different from A4/A5" || bad "A6: $out"

# ── B: who waits (the scan) ──────────────────────────────────────────────────────────────────────────────────────────
echo "B. the scan — who is the head waiter"
reset; cap wa-worker 2 2; cap ps-worker 0 1
out="$(run_py "$(scan_with "$POP")")"
[ "$out" = "WAIT=wa-p0 BLIND=0" ] && ok "B1 wa-worker positively full → its P0 is the head waiter" || bad "B1: $out"
logged "wa-p0 (rig wa) waits for capacity" && logged "2/2" && ok "B1b the log says WHO waits, in which rig and at what count" || bad "B1b waiter line missing: $(cat "$WORK/log.txt")"
reset; cap wa-worker 1 2; cap ps-worker 0 1
out="$(run_py "$(scan_with "$POP")")"
[ "$out" = "WAIT= BLIND=0" ] && logged "idle this sweep" && ok "B2 both pools have room → nobody waits, BLIND=0, the log says idle" || bad "B2: $out"
reset; cap wa-worker 1 2; cap ps-worker 1 1
out="$(run_py "$(scan_with "$POP")")"
[ "$out" = "WAIT=ps-p1 BLIND=0" ] && ok "B3 only ps-worker full → the P1 of PS is the waiter (the rule is not WA-specific)" || bad "B3: $out"
reset; cap wa-worker 2 2; cap ps-worker 1 1
out="$(run_py "$(scan_with "$POP")")"
[ "$out" = "WAIT=wa-p0 BLIND=0" ] && ok "B4 both full → the FIRST in work order is the head (wa-p0 before ps-p1)" || bad "B4: $out"
reset; cap wa-worker unreadable; cap ps-worker 1 1
out="$(run_py "$(scan_with "$POP")")"
[ "$out" = "WAIT= BLIND=1" ] && warned "CANNOT TELL whether wa-worker is at its cap" \
  && ok "B5 the WA count cannot be read → BLIND=1 and nobody is declared a waiter (and the scan stops: it does not guess from the next pool)" \
  || bad "B5: $out / $(cat "$WORK/log.txt")"
reset; cap wa-worker 2 2
out="$(run_py "_PY_EMIT_OK=0; _pilot_priority_waiting_scan; echo \"WAIT=\${_PY_WAIT_ID:-} BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT= BLIND=1" ] && ok "B6 the emit never ran → BLIND=1 (cap file says full, and it is still not trusted without a population)" || bad "B6: $out"
reset; cap wa-worker 2 2
out="$(run_py "PILOT_PRIORITY_YIELD=0; $(scan_with "$POP"); echo \"SCANNED=\$_PY_SCANNED\"")"
echo "$out" | grep -qx "WAIT= BLIND=0" && echo "$out" | grep -qx "SCANNED=0" && logged "priority yield is OFF" && [ "$(cap_calls)" = "0" ] \
  && ok "B7 PILOT_PRIORITY_YIELD=0 → no waiter, not blind, the pool is not even probed, and NOT 'scanned' (the sweep event says null, not 'looked and could tell')" || bad "B7: $out calls=$(cap_calls)"
reset; cap wa-worker 2 2; : > "$WORK/city/.gc/priority-yield.off"
out="$(run_py "$(scan_with "$POP")")"
[ "$out" = "WAIT= BLIND=0" ] && ok "B8 the kill file .gc/priority-yield.off switches it off instantly (no reload)" || bad "B8: $out"
reset; cap wa-worker 1 2
POP2="$(arr "$(bead a1 1 wa-worker wa)" "$(bead a2 1 wa-worker wa)" "$(bead a3 1 wa-worker wa)")"
out="$(run_py "$(scan_with "$POP2")")"
[ "$out" = "WAIT= BLIND=0" ] && [ "$(cap_calls)" = "1" ] && ok "B9 three P1 of the same (pool, rig) read 'not full' → the pool is probed ONCE" || bad "B9: $out calls=$(cap_calls)"

# ── C: the three controls from the bead ──────────────────────────────────────────────────────────────────────────────
echo "C. the bead's controls — the decision for a P2 bead of PS"
P2PS="$(bead ps-p2 2 ps-worker ps)"
reset; cap wa-worker 2 2; cap ps-worker 0 1
out="$(run_py "$(scan_with "$POP"); _pilot_priority_yield_for '$P2PS' && echo \"CEDES class=\$_PY_CAND_CLASS\" || echo DISPATCHES")"
echo "$out" | grep -qx "CEDES class=2" && ok "C1 P0 of WA waiting + P2 of PS ready → the PS bead CEDES" || bad "C1: $out"
reset; cap wa-worker 1 2; cap ps-worker 0 1
out="$(run_py "$(scan_with "$POP"); _pilot_priority_yield_for '$P2PS' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "DISPATCHES" && ok "C2 (control) no P0/P1 waiting + P2 of PS ready → the PS bead DISPATCHES as before" || bad "C2: $out"
reset; cap wa-worker unreadable; cap ps-worker 0 1
out="$(run_py "$(scan_with "$POP"); _pilot_priority_yield_for '$P2PS' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "DISPATCHES" && echo "$out" | grep -qx "WAIT= BLIND=1" && warned "no P2+ bead is ceded on a guess" \
  && ok "C3 (control) the WA reading FAILS + P2 of PS ready → the PS bead DISPATCHES, and the sweep is marked BLIND (and says so in the log)" || bad "C3: $out"

# ── D: who cedes ─────────────────────────────────────────────────────────────────────────────────────────────────────
echo "D. which beads cede (waiter known: wa-p0, WA full)"
SET="$(scan_with "$POP")"
for spec in "P2:2:CEDES" "P3:3:CEDES" "P4:4:CEDES" "P1:1:KEEPS" "P0:0:KEEPS" "unreadable:-:KEEPS" "string-priority:str:KEEPS"; do
  reset; cap wa-worker 2 2; cap ps-worker 0 1
  lbl="${spec%%:*}"; rest="${spec#*:}"; pr="${rest%%:*}"; want="${rest##*:}"
  out="$(run_py "$SET >/dev/null; _pilot_priority_yield_for '$(bead cand "$pr" ps-worker ps)' && echo CEDES || echo KEEPS")"
  [ "$(echo "$out" | tail -1)" = "$want" ] && ok "D $lbl bead → $want" || bad "D $lbl bead: wanted $want, got '$(echo "$out" | tail -1)'"
done
reset; cap wa-worker 2 2
out="$(run_py "$SET >/dev/null; _pilot_priority_yield_for '$(bead wa-p0 0 wa-worker wa)' && echo CEDES || echo KEEPS")"
[ "$(echo "$out" | tail -1)" = "KEEPS" ] && ok "D the waiter itself never cedes to itself" || bad "D waiter: $out"
reset
out="$(run_py "_pilot_priority_yield_for '$P2PS' && echo CEDES || echo KEEPS")"
[ "$out" = "KEEPS" ] && ok "D no head waiter known → nothing cedes (a scan that never ran is not 'someone waits')" || bad "D no waiter: $out"
reset; cap wa-worker 2 2
out="$(run_py "$SET >/dev/null; PILOT_PRIORITY_YIELD=0; _pilot_priority_yield_for '$P2PS' && echo CEDES || echo KEEPS")"
[ "$(echo "$out" | tail -1)" = "KEEPS" ] && ok "D switching the rule off mid-sweep stops ceding at once" || bad "D off: $out"
reset; cap wa-worker 2 2
out="$(run_py "$SET >/dev/null; _pilot_priority_yield_for '$(bead dog-p2 2 gastown.dog hq)' && echo CEDES || echo KEEPS")"
[ "$(echo "$out" | tail -1)" = "CEDES" ] && ok "D a P2 destined to the dog pool cedes too (the rule is for ANY pool)" || bad "D dog: $out"

# ── E: a waiter learned during dispatch ──────────────────────────────────────────────────────────────────────────────
echo "E. a P0/P1 that ends QUEUED during the sweep's own dispatch becomes a waiter"
reset
out="$(run_py "_pilot_priority_waiter_note '$(bead new1 1 - wa)' wa-worker 2 2; echo \"WAIT=\${_PY_WAIT_ID:-} POOL=\${_PY_WAIT_POOL:-}\"; _pilot_priority_yield_for '$P2PS' && echo CEDES || echo KEEPS")"
echo "$out" | grep -qx "WAIT=new1 POOL=wa-worker" && echo "$out" | grep -qx "CEDES" && ok "E1 first-sight P1 queued behind wa-worker → waiter; the P2 of PS cedes from then on" || bad "E1: $out"
reset
out="$(run_py "_pilot_priority_waiter_note '$P2PS' ps-worker 1 1; echo \"WAIT=[\${_PY_WAIT_ID:-}]\"")"
[ "$out" = "WAIT=[]" ] && ok "E2 a P2 that queues is NOT a waiter (only P0/P1 make others cede)" || bad "E2: $out"
reset; cap wa-worker 2 2
out="$(run_py "$SET >/dev/null; _pilot_priority_waiter_note '$(bead later 1 - ps)' ps-worker 1 1; echo \"WAIT=\${_PY_WAIT_ID:-}\"")"
[ "$out" = "WAIT=wa-p0" ] && ok "E3 only the FIRST waiter is kept (the head, best-ordered) — a later one does not displace it" || bad "E3: $out"

# ── F: the pool top-up asks by id ────────────────────────────────────────────────────────────────────────────────────
echo "F. the top-up holds an id, not a bead"
reset; cap wa-worker 2 2
out="$(run_py "$SET >/dev/null; _pilot_priority_project_emit '$(arr "$(bead wa-p0 0 wa-worker wa)" "$(bead ps-p2 2 ps-worker ps)" "$(bead ps-p1 1 ps-worker ps)")'; _PY_WAIT_ID=wa-p0; _pilot_priority_yield_for_id ps-worker ps-p2 && echo CEDES || echo KEEPS")"
[ "$(echo "$out" | tail -1)" = "CEDES" ] && ok "F1 the class comes from the emit's map: ps-p2 cedes" || bad "F1: $out"
out="$(run_py "_pilot_priority_project_emit '$(arr "$(bead wa-p0 0 wa-worker wa)" "$(bead ps-p1 1 ps-worker ps)")'; _PY_WAIT_ID=wa-p0; _pilot_priority_yield_for_id ps-worker ps-p1 && echo CEDES || echo KEEPS")"
[ "$out" = "KEEPS" ] && ok "F2 a P1 in the top-up never cedes" || bad "F2: $out"
reset; touch "$WORK/store.ok"; bead ghost 3 ps-worker ps > "$WORK/show.ghost.json"
out="$(run_py "_PY_WAIT_ID=wa-p0; _PY_WAIT_PRIO=0; _pilot_priority_yield_for_id ps-worker ghost && echo CEDES || echo KEEPS")"
[ "$out" = "CEDES" ] && ok "F3 a bead the emit did not carry is read from its own store (P3 → cedes)" || bad "F3: $out"
reset; rm -f "$WORK/store.ok"
out="$(run_py "_PY_WAIT_ID=wa-p0; _pilot_priority_yield_for_id ps-worker ghost && echo CEDES || echo KEEPS; echo \"BLIND=\$PRIORITY_YIELD_BLIND_TOPUP\"")"
echo "$out" | grep -qx "KEEPS" && echo "$out" | grep -qx "BLIND=1" && warned "CANNOT TELL the priority of ghost" \
  && ok "F4 (control) neither the emit nor the store can tell the priority → the top-up is NOT held back, and it is COUNTED" || bad "F4: $out"

# ── G: the post-claim release ────────────────────────────────────────────────────────────────────────────────────────
echo "G. dispatch_one's release of a ceded, already-claimed bead"
reset
out="$(run_py "_pilot_priority_yield_release ps-p2 '$WORK/city' ps-worker-3 ps-worker; echo done")"
w="$(cat "$WORK/bd.writes" 2>/dev/null)"
echo "$w" | grep -q "label remove ps-p2 pilot:dispatching" && echo "$w" | grep -q "unset-metadata pilot.dispatching_at" && echo "$w" | grep -q "set-metadata gc.routed_to=ps-worker" \
  && ok "G1 ps-worker target: claim label + stamp removed, route stamped (the next sweep takes the zero-write path)" || bad "G1 writes: $w"
[ "$(cat "$WORK/unmark.log" 2>/dev/null)" = "ps-worker-3" ] && ok "G1b the builder slot is given back" || bad "G1b unmark: $(cat "$WORK/unmark.log" 2>/dev/null)"
reset
run_py "_pilot_priority_yield_release dog-p2 '$WORK/city' gastown.dog-1 gastown.dog; echo done" >/dev/null
w="$(cat "$WORK/bd.writes" 2>/dev/null)"
echo "$w" | grep -q "label remove dog-p2" && ! echo "$w" | grep -q "gc.routed_to" \
  && ok "G2 dog target: released but NOT stamped gc.routed_to=gastown.dog (that would put it in front of the dog's own probe)" || bad "G2 writes: $w"
reset
run_py "DRY_RUN=1; _pilot_priority_yield_release ps-p2 '$WORK/city' ps-worker-3 ps-worker; echo done" >/dev/null
[ "$(writes)" = "0" ] && ok "G3 DRY_RUN=1 writes nothing" || bad "G3 wrote $(writes) times"

# ── H: pool targets and the pre-claim pool test ──────────────────────────────────────────────────────────────────────
echo "H. which targets are pools"
for t in wa-worker wa-worker-2 ps-worker ps-worker-1 gastown.dog gastown.dog-2; do
  out="$(run_py "_pilot_priority_target_is_pool $t && echo POOL || echo NOT")"; [ "$out" = "POOL" ] && ok "H $t is a pool" || bad "H $t: $out"
done
for t in oracle-wa mila-wa batista-ps "" gastown.mayor; do
  out="$(run_py "_pilot_priority_target_is_pool '$t' && echo POOL || echo NOT")"; [ "$out" = "NOT" ] && ok "H '${t:-<empty>}' is not a pool (a named crew adds no session → never held back)" || bad "H '$t': $out"
done
reset
out="$(run_py "_pilot_priority_pool_bound_pre '$(bead x 2 ps-worker ps)' && echo BOUND || echo UNKNOWN")"
[ "$out" = "BOUND" ] && ok "H bead already routed to a pool → known pool-bound before the claim" || bad "H routed: $out"
out="$(run_py "_pilot_priority_pool_bound_pre '$(bead x 2 - wa)' && echo BOUND || echo UNKNOWN")"
[ "$out" = "UNKNOWN" ] && ok "H first-sight bead without story.rig → decided later, in dispatch_one (after the claim)" || bad "H first-sight: $out"
reset; echo "gastown.dog" > "$WORK/builders.hq"
out="$(run_py "_pilot_priority_pool_bound_pre '$(bead x 2 - wa | jq -c '.metadata["story.rig"]="hq"')' && echo BOUND || echo UNKNOWN")"
[ "$out" = "BOUND" ] && ok "H story.rig whose only builder is the dog pool and no persistent crew → pool-bound" || bad "H dog rig: $out"
touch "$WORK/crew.hq"
out="$(run_py "_pilot_priority_pool_bound_pre '$(bead x 2 - wa | jq -c '.metadata["story.rig"]="hq"')' && echo BOUND || echo UNKNOWN")"
[ "$out" = "UNKNOWN" ] && ok "H the same rig WITH a persistent crew → unknown (a crew may take it; no guess)" || bad "H crew rig: $out"

# ── J: a waiter is a bead THIS sweep could dispatch (gate round 1) ───────────────────────────────────────────────────
# The emit's population is the real queue, made BEFORE the gate-focus clamp and without the top-up brake. Under focus a non-fix P0/P1
# is never handed a session, so it must not make a gate-rejected fix (the work focus mode exists to let through) cede.
echo "J. waiters the sweep itself could never dispatch (gate focus ON, respawn brake)"
FIXLBL="gate:needs-fix"
P2FIX="$(bead ps-fix 2 ps-worker ps task "$FIXLBL")"
POPJ="$(arr "$(bead wa-new0 0 wa-worker wa task story:approved)" "$(bead ps-p1fix 1 ps-worker ps task "$FIXLBL")")"
reset; cap wa-worker 2 2; cap ps-worker 0 1
out="$(run_py "PILOT_GATE_FOCUS=1; $(scan_with "$(arr "$(bead wa-new0 0 wa-worker wa task story:approved)")"); _pilot_priority_yield_for '$P2FIX' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT= BLIND=0" && echo "$out" | grep -qx "DISPATCHES" && logged "NOT counted as waiting" && logged "wa-new0 (not-a-fix)" \
  && ok "J1 focus ON + a NON-fix WA P0 behind a full wa-worker + a gate-rejected P2 fix of PS → no waiter, the fix DISPATCHES (the reviewer's repro)" || bad "J1: $out / $(cat "$WORK/log.txt")"
for lbl in gate:needs-fix gate:fix-attempt:2 origem:auto-healer-notify impacto:dano-ao-vivo; do
  reset; cap wa-worker 2 2; cap ps-worker 0 1
  out="$(run_py "PILOT_GATE_FOCUS=1; $(scan_with "$(arr "$(bead wa-fix0 0 wa-worker wa task "story:approved,$lbl")")"); _pilot_priority_yield_for '$P2FIX' && echo CEDES || echo DISPATCHES")"
  echo "$out" | grep -qx "WAIT=wa-fix0 BLIND=0" && echo "$out" | grep -qx "CEDES" \
    && ok "J2 (control) focus ON + a WA P0 that IS a fix ($lbl) behind a full wa-worker → it waits, the P2 cedes (the rule still works under focus)" || bad "J2 $lbl: $out"
done
reset; cap wa-worker 2 2; cap ps-worker 0 1
out="$(run_py "PILOT_GATE_FOCUS=0; $(scan_with "$(arr "$(bead wa-new0 0 wa-worker wa task story:approved)")"); _pilot_priority_yield_for '$P2FIX' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT=wa-new0 BLIND=0" && echo "$out" | grep -qx "CEDES" \
  && ok "J3 (control) focus OFF + the same non-fix P0 → it waits and the P2 cedes, exactly as before" || bad "J3: $out"
reset; cap wa-worker 2 2; cap ps-worker 0 1
out="$(run_py "unset PILOT_GATE_FOCUS; $(scan_with "$(arr "$(bead wa-new0 0 wa-worker wa task story:approved)")")")"
[ "$out" = "WAIT=wa-new0 BLIND=0" ] && ok "J3b (control) focus state unknown/unset (the dispatcher dispatches normally then) → a non-fix P0 waits as before" || bad "J3b: $out"
reset; cap wa-worker 2 2; cap ps-worker 1 1
out="$(run_py "PILOT_GATE_FOCUS=1; $(scan_with "$POPJ")")"
[ "$out" = "WAIT=ps-p1fix BLIND=0" ] && [ "$(cap_calls)" = "1" ] \
  && ok "J4 focus ON, [non-fix WA P0, fix PS P1] → the scan skips the first WITHOUT probing its pool and the PS fix is the head waiter" || bad "J4: $out calls=$(cap_calls)"
reset; cap wa-worker 2 2; cap ps-worker 0 1
out="$(run_py "$(scan_with "$(arr "$(bead wa-brk 0 wa-worker wa task story:approved,pilot:topup-braked)")"); _pilot_priority_yield_for '$(bead ps-p2 2 ps-worker ps)' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT= BLIND=0" && echo "$out" | grep -qx "DISPATCHES" && logged "wa-brk (braked)" \
  && ok "J5 a P0 held by the top-up brake (pilot:topup-braked) is stuck, not waiting for capacity: no waiter, nothing cedes to it" || bad "J5: $out"
reset; cap wa-worker 2 2
out="$(run_py "_PY_EMIT_OK=1; _PY_P01='[{\"id\":\"x\",\"priority\":0,\"rig\":\"wa\",\"routed_to\":\"wa-worker\"}]'; _pilot_priority_waiting_scan; echo \"WAIT=\${_PY_WAIT_ID:-} BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT= BLIND=1" ] && warned "CANNOT TELL whether 1 P0/P1" && [ "$(cap_calls)" = "0" ] \
  && ok "J6 (third state) a row WITHOUT the focus/brake facts → BLIND=1, not a waiter, its pool not probed — unreadable is never 'waiting'" || bad "J6: $out calls=$(cap_calls)"
reset; cap wa-worker 2 2
out="$(run_py "_PY_EMIT_OK=1; _PY_P01='[{\"id\":\"x\",\"priority\":0,\"rig\":\"wa\",\"routed_to\":\"wa-worker\",\"focus_fix\":\"yes\",\"braked\":false},{\"id\":\"y\",\"priority\":1,\"rig\":\"wa\",\"routed_to\":\"wa-worker\",\"focus_fix\":false,\"braked\":false,\"refused\":\"\"}]'; _pilot_priority_waiting_scan; echo \"WAIT=\${_PY_WAIT_ID:-} BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT=y BLIND=0" ] && ok "J6b an unreadable row followed by a real waiter → the waiter is used and the sweep is NOT blind (the doubt changes nothing)" || bad "J6b: $out"
# Drift guard: the projection's focus predicate must be the one _filter_candidates applies under focus (keep-in-sync pair).
pred() { grep -o 'any((\.labels // \[\])\[\]; \. == "gate:needs-fix".*"impacto:dano-ao-vivo")' <<< "$1" | head -1; }
P_PROJ="$(pred "$PROJECT_SRC")"; P_FILT="$(pred "$(fn_src _filter_candidates)")"
{ [ -n "$P_PROJ" ] && [ "$P_PROJ" = "$P_FILT" ]; } && ok "J7 drift guard: the projection's focus predicate is byte-identical to _filter_candidates' focus clause" || bad "J7 predicates differ: proj=[$P_PROJ] filter=[$P_FILT]"

# ── K: a P0/P1 that the pool's OWN probe refuses is not waiting (ga-qmfm8r) ──────────────────────────────────────────
# 13/10: wa-gg9uhf (P0, gate:needs-fix) carried delivery:pending-restart, which the wa-worker probe refuses. No worker would take it, yet it
# counted as "P0 waiting behind wa-worker 2/2" and 157 P2+ beads ceded to it for ~9h until the Mayor removed the label by hand.
echo "K. a P0/P1 the target pool's probe refuses (ga-qmfm8r)"
LBL_PR="delivery:pending-restart"
P0PR="$(bead wa-p0 0 wa-worker wa task "gate:needs-fix,$LBL_PR")"
P2WA="$(bead wa-p2 2 wa-worker wa)"
reset; cap wa-worker 2 2
out="$(run_py "$(scan_with "$(arr "$P0PR")"); _pilot_priority_yield_for '$P2WA' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT= BLIND=0" && echo "$out" | grep -qx "DISPATCHES" \
  && ok "K1 (the incident) P0 with $LBL_PR behind a full wa-worker + a P2 of the same rig → no waiter, the P2 DISPATCHES" || bad "K1: $out / $(cat "$WORK/log.txt")"
[ "$(mails)" = "1" ] && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF "wa-p0" && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF "$LBL_PR" \
  && ok "K1b exactly ONE mail to the Mayor, and it names the bead and the label" || bad "K1b mails=$(mails): $(cat "$WORK/gc.calls" 2>/dev/null)"
grep -F 'mail send mayor' "$WORK/gc.calls" 2>/dev/null | grep -qF "P0 que nenhum worker pode pegar: wa-p0 $LBL_PR" \
  && ok "K1c the subject reads 'P0 que nenhum worker pode pegar: <id> <rótulo>'" || bad "K1c subject: $(cat "$WORK/gc.calls" 2>/dev/null)"
[ "$(cap_calls)" = "0" ] && logged "wa-p0 (refused:label:$LBL_PR)" && ok "K1d the refused row is skipped WITHOUT probing its pool, and the sweep log names the refusal" || bad "K1d calls=$(cap_calls) / $(cat "$WORK/log.txt")"
# the SECOND sweep (same state, same bead): no new mail
out="$(run_py "$(scan_with "$(arr "$P0PR")")")"
[ "$out" = "WAIT= BLIND=0" ] && [ "$(mails)" = "1" ] && ok "K2 the next sweep still refuses it and sends NO second mail (once per bead+reasons, not once per sweep)" || bad "K2: $out mails=$(mails)"
# the label goes away: the P0 waits again (and the state is forgotten)
out="$(run_py "$(scan_with "$(arr "$(bead wa-p0 0 wa-worker wa task gate:needs-fix)")")")"
[ "$out" = "WAIT=wa-p0 BLIND=0" ] && [ "$(mails)" = "1" ] && ok "K3 label cleared → the P0 is a waiter again (the cession is right for a bead a worker CAN take), no mail" || bad "K3: $out mails=$(mails)"
out="$(run_py "$(scan_with "$(arr "$P0PR")")")"
[ "$out" = "WAIT= BLIND=0" ] && [ "$(mails)" = "2" ] && ok "K3b the label comes BACK → a fresh occurrence, a fresh mail (2 in all)" || bad "K3b: $out mails=$(mails)"

# control: without the refused label the SAME bead cedes the P2 and nobody is mailed
reset; cap wa-worker 2 2
out="$(run_py "$(scan_with "$(arr "$(bead wa-p0 0 wa-worker wa task gate:needs-fix)")"); _pilot_priority_yield_for '$P2WA' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT=wa-p0 BLIND=0" && echo "$out" | grep -qx "CEDES" && [ "$(mails)" = "0" ] \
  && ok "K4 (control) the same P0 WITHOUT $LBL_PR → head waiter, the P2 cedes, no mail (the fix does not turn the rule off)" || bad "K4: $out mails=$(mails)"

# a mail that fails is retried the next sweep, and never changes what cedes
reset; cap wa-worker 2 2; : > "$WORK/gc.fail"
out="$(run_py "$(scan_with "$(arr "$P0PR")"); _pilot_priority_yield_for '$P2WA' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "DISPATCHES" && [ "$(mails)" = "1" ] && [ ! -s "$WORK/unservable.state" ] \
  && ok "K5 the mail FAILS → the P2 still dispatches (the doubt is about telling the Mayor, not about the bead) and nothing is remembered" || bad "K5: $out mails=$(mails) state=$(cat "$WORK/unservable.state" 2>/dev/null)"
rm -f "$WORK/gc.fail"
run_py "$(scan_with "$(arr "$P0PR")")" >/dev/null
[ "$(mails)" = "2" ] && [ -s "$WORK/unservable.state" ] && ok "K5b the next sweep retries (2 attempts) and, sent, remembers it" || bad "K5b mails=$(mails)"
run_py "$(scan_with "$(arr "$P0PR")")" >/dev/null
[ "$(mails)" = "2" ] && ok "K5c … and stops there" || bad "K5c mails=$(mails)"
# the state file that cannot be READ while it is being updated is "cannot tell", not "empty": it must not be rewritten from nothing
reset; cap wa-worker 2 2
printf 'other-1\tlabel:needs-human\nother-2\tlabel:on-device\n' > "$WORK/unservable.state"
out="$(run_py "awk() { return 2; }; $(scan_with "$(arr "$P0PR")")")"
[ "$(mails)" = "1" ] && [ "$(cat "$WORK/unservable.state")" = "$(printf 'other-1\tlabel:needs-human\nother-2\tlabel:on-device')" ] && warned "could not record it" \
  && ok "K5d (third state) the old state cannot be read (awk fails) → the file is left as it was (the other beads stay remembered), the failure is a warning" || bad "K5d mails=$(mails) state=$(cat "$WORK/unservable.state" 2>/dev/null | tr '\n\t' '|.')"

# the list of refusals is the POOL's: ps-worker shares wa's list; delivery:partial is a dog-only refusal
reset; cap ps-worker 1 1
out="$(run_py "$(scan_with "$(arr "$(bead ps-p1 1 ps-worker ps task "$LBL_PR")")")")"
[ "$out" = "WAIT= BLIND=0" ] && [ "$(mails)" = "1" ] && grep -qF "P1 que nenhum worker pode pegar: ps-p1 $LBL_PR" "$WORK/gc.calls" \
  && ok "K6 a P1 routed to ps-worker with $LBL_PR is refused too, and the subject says P1" || bad "K6: $out mails=$(mails) $(cat "$WORK/gc.calls" 2>/dev/null)"
reset; cap wa-worker 2 2
out="$(run_py "$(scan_with "$(arr "$(bead wa-part 0 wa-worker wa task delivery:partial)")")")"
[ "$out" = "WAIT=wa-part BLIND=0" ] && [ "$(mails)" = "0" ] \
  && ok "K7 (control) delivery:partial is refused by the DOG probe only → a wa-worker P0 carrying it still waits (the list is per pool, not the union)" || bad "K7: $out mails=$(mails)"

# two refusals on one bead = one mail naming both; a different set of reasons later = a new mail
reset; cap wa-worker 2 2
BOTH="$(bead wa-p0 0 wa-worker wa task "$LBL_PR,pilot:no-auto-dispatch")"
run_py "$(scan_with "$(arr "$BOTH")")" >/dev/null
[ "$(mails)" = "1" ] && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF "$LBL_PR" && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF "pilot:no-auto-dispatch" \
  && ok "K8 two refused labels on one bead → ONE mail that names both" || bad "K8 mails=$(mails): $(cat "$WORK/gc.calls" 2>/dev/null)"
run_py "$(scan_with "$(arr "$(bead wa-p0 0 wa-worker wa task "needs-human")")")" >/dev/null
[ "$(mails)" = "2" ] && ok "K8b the reasons CHANGE (another label refuses it now) → a new mail: the old one no longer tells the truth" || bad "K8b mails=$(mails)"
reset; cap wa-worker 2 2
run_py "$(scan_with "$(arr "$P0PR" "$(bead wa-p0b 1 wa-worker wa task needs-human)")")" >/dev/null
[ "$(mails)" = "2" ] && ok "K8c two different refused beads → two mails (one per bead)" || bad "K8c mails=$(mails)"

# a refused P0 does not hide a real waiter behind it
reset; cap wa-worker 2 2
out="$(run_py "$(scan_with "$(arr "$P0PR" "$(bead wa-p1 1 wa-worker wa task gate:needs-fix)")"); _pilot_priority_yield_for '$P2WA' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT=wa-p1 BLIND=0" && echo "$out" | grep -qx "CEDES" && [ "$(mails)" = "1" ] \
  && ok "K9 [refused P0, real P1] behind a full pool → the P1 is the head waiter (the P2 cedes to IT), and the P0 is still reported" || bad "K9: $out mails=$(mails)"

# first-sight bead that ends QUEUED during the sweep's own dispatch: the same filter at the second entry point
reset
out="$(run_py "_pilot_priority_waiter_note '$(bead new0 0 - wa task "$LBL_PR")' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}]\"; _pilot_priority_yield_for '$P2WA' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT=\[\]" && echo "$out" | grep -qx "DISPATCHES" && [ "$(mails)" = "1" ] && grep -qF "new0 $LBL_PR" "$WORK/gc.calls" \
  && ok "K10 a first-sight P0 with $LBL_PR that queues behind a full pool is NOT recorded as the waiter (the dispatch-time entry point), and is reported once" || bad "K10: $out mails=$(mails)"
reset
out="$(run_py "_pilot_priority_waiter_note '$(bead new0 0 - wa task gate:needs-fix)' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}]\"")"
[ "$out" = "WAIT=[new0]" ] && [ "$(mails)" = "0" ] && ok "K10b (control) the same first-sight P0 without the label IS the waiter, as before" || bad "K10b: $out mails=$(mails)"
reset
out="$(run_py "_pilot_priority_waiter_note '$(bead new0 0 - wa task "$LBL_PR")' wa-worker 2 2; _pilot_priority_waiter_note '$(bead new0 0 - wa task "$LBL_PR")' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}]\"")"
[ "$out" = "WAIT=[]" ] && [ "$(mails)" = "1" ] && ok "K10c the same refused bead noted twice in one sweep → still one mail" || bad "K10c: $out mails=$(mails)"

reset
out="$(run_py "POOL_VETO_JQ_DEFS=''; _pilot_priority_waiter_note '$(bead new0 0 - wa task gate:needs-fix)' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}] BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT=[] BLIND=1" ] && [ "$(mails)" = "0" ] && warned "CANNOT TELL whether the pool's probe refuses new0" \
  && ok "K10d (third state) the veto library not loaded at the dispatch-time entry point → not recorded as the waiter, BLIND=1, no mail" || bad "K10d: $out mails=$(mails)"

# the third state: cannot tell → blind, nothing ceded, nobody mailed
reset; cap wa-worker 2 2
out="$(run_py "POOL_VETO_JQ_DEFS=''; $(scan_with "$(arr "$P0PR")")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(mails)" = "0" ] && warned "CANNOT TELL" \
  && ok "K11 the veto library's jq definitions are not loaded → the sweep is BLIND (nothing ceded, no mail) — missing is 'cannot tell', not 'nothing is refused'" || bad "K11: $out mails=$(mails)"
reset; cap wa-worker 2 2
out="$(run_py "unset -f pool_veto_cfg; $(scan_with "$(arr "$P0PR")")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(mails)" = "0" ] && ok "K11b pool_veto_cfg missing → BLIND, same" || bad "K11b: $out mails=$(mails)"
reset; cap wa-worker 2 2
out="$(run_py "pool_veto_cfg() { return 1; }; $(scan_with "$(arr "$P0PR")")")"
[ "$out" = "WAIT= BLIND=1" ] && ok "K11c pool_veto_cfg fails → BLIND, same" || bad "K11c: $out"
reset; cap wa-worker 2 2
out="$(run_py "_PY_EMIT_OK=1; _PY_P01='[{\"id\":\"x\",\"priority\":0,\"rig\":\"wa\",\"routed_to\":\"wa-worker\",\"focus_fix\":false,\"braked\":false}]'; _pilot_priority_waiting_scan; echo \"WAIT=\${_PY_WAIT_ID:-} BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(cap_calls)" = "0" ] && [ "$(mails)" = "0" ] \
  && ok "K12 (third state) a row WITHOUT the refusal fact → BLIND, not a waiter, its pool not probed, nobody mailed" || bad "K12: $out calls=$(cap_calls) mails=$(mails)"

# DRY_RUN: look, say, do not write
reset; cap wa-worker 2 2
out="$(run_py "DRY_RUN=1; $(scan_with "$(arr "$P0PR")"); _pilot_priority_yield_for '$P2WA' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "DISPATCHES" && [ "$(gc_calls)" = "0" ] && [ ! -e "$WORK/unservable.state" ] && logged "WOULD" \
  && ok "K13 DRY_RUN=1 → the P2 still dispatches, NO mail, NO state written, the log says what it WOULD send" || bad "K13: $out gc=$(gc_calls) / $(cat "$WORK/log.txt")"

# the rule off: nothing is scanned, so nothing is reported
reset; cap wa-worker 2 2
run_py "PILOT_PRIORITY_YIELD=0; $(scan_with "$(arr "$P0PR")")" >/dev/null
[ "$(mails)" = "0" ] && ok "K14 PILOT_PRIORITY_YIELD=0 → the scan does not run, so no mail either" || bad "K14 mails=$(mails)"

# one source for the list: the yield adds NO label list of its own — it reads the refusal through the library. (The pool TOP-UP keeps its own
# older array, _TOPUP_WORKER_EXCLUDE_LABELS, which feeds `bd --exclude-label` flags; that copy predates this bead and is outside it, so its lines
# are the one thing this guard lets through.)
code_lines() { grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -v -- '^[[:space:]]*--exclude-label "'; }
n_copy="$(code_lines | grep -c "$LBL_PR" || true)"
[ "$n_copy" = "0" ] && ok "K15 drift guard: '$LBL_PR' appears in NO code line of the dispatcher outside the top-up's bd flag array (the yield's list lives in pool-probe-vetoes.sh only)" || bad "K15: $n_copy code line(s) of the dispatcher carry the label"
echo "$PROJECT_SRC" | grep -q 'pool_veto_reasons' && echo "$PROJECT_SRC" | grep -q 'pool_veto_cfg wa' \
  && ok "K16 the projection asks the library (pool_veto_reasons with pool_veto_cfg wa)" || bad "K16 the projection does not call the veto library"

# ── L: ga-2lca0l — a P0/P1 with a LIVE top-up session opened for it is being built, not waiting ────────────────────────
# 14/10: wa-hut4l5.4 (P1) was the head waiter for ~4h with the pool full because of the very session the Pilot opened for it
# ("pool top-up: wa-hut4l5.4"). That session never saw its target: it ran the generic pool probe, claimed wa-470co3 and built that.
# The bead stayed `open`, unassigned; the yield kept ceding ~150 P2+ beads per sweep to a P1 nobody was building (dispatched=0).
# The fixture below is that shape: the session list carries the real title the Pilot gives the session.
echo "L. a P0/P1 with a live top-up session opened for it is not 'waiting'; the claim is written/repaired (ga-2lca0l)"
sess() {
  jq -cn --arg n "$1" --arg t "$2" --arg s "${3:-active}" --arg c "${4:-false}" --arg ca "${5:-2026-10-14T08:47:19Z}" \
    '{id: ("ga-wisp-" + $n), name: $n, session_name: $n, alias: $n, agent_name: $n, template: "wa-worker", title: $t, state: $s,
      work_dir: "/rig/crew/worker", created_at: $ca, last_active: "0001-01-01T00:00:00Z", closed: ($c == "true")}'
}
sessions() { local _o="" _s; for _s in "$@"; do _o="${_o:+$_o,}$_s"; done; printf '{"ok":true,"schema_version":"1","sessions":[%s],"summary":{}}' "$_o" > "$WORK/sessions.json"; }
claim_state() { jq -cn --arg id "$1" --arg st "$2" --arg a "$3" '{id: $id, status: $st, assignee: $a, metadata: {"gc.routed_to": "wa-worker"}}' > "$WORK/show.$1.json"; }
holds() { printf '[{"id":"%s","status":"in_progress"}]' "$2" > "$WORK/inprog.$1.json"; }
SESS_A="wa-worker-adhoc-aaa"
POPL="$(arr "$(bead wa-p1 1 wa-worker wa)")"
want_write() { [ "$(writes)" = "1" ] && grep -qF -- "-C $WORK/store update wa-p1" "$WORK/bd.writes" && grep -qF -- "--status in_progress" "$WORK/bd.writes" && grep -qF -- "--assignee $1" "$WORK/bd.writes"; }

# L1/L2 — the bead's own Aceite: with a session, no cession and a repaired claim; without one, it cedes exactly as before.
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "$(scan_with "$POPL"); _pilot_priority_yield_for '$P2PS' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT= BLIND=0" && echo "$out" | grep -qx "DISPATCHES" \
  && ok "L1a P1 with NO assignee + a live 'pool top-up: wa-p1' session + pool at cap → NOT a waiter, the P2 does not cede" || bad "L1a: $out"
want_write "$SESS_A" && ok "L1b ...and the claim is REPAIRED: one write, status in_progress + assignee = that session, in the store holding the bead" || bad "L1b writes=$(writes): $(cat "$WORK/bd.writes" 2>/dev/null)"
grep -qF -- "--set-metadata gc.session_name=$SESS_A" "$WORK/bd.writes" && grep -qF -- "--set-metadata gc.work_dir=/rig/crew/worker" "$WORK/bd.writes" \
  && ok "L1c ...with the same gc.session_name / gc.work_dir a real claim writes (the reclaim guard heals from them)" || bad "L1c: $(cat "$WORK/bd.writes" 2>/dev/null)"
logged "wa-p1" && logged "$SESS_A" && logged "NOT counted as waiting" && ok "L1d the log says which bead, which session, and that it is not counted as waiting" || bad "L1d: $(cat "$WORK/log.txt")"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess wa-worker-adhoc-zzz 'pool top-up: wa-other')"
out="$(run_py "$(scan_with "$POPL"); _pilot_priority_yield_for '$P2PS' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT=wa-p1 BLIND=0" && echo "$out" | grep -qx "CEDES" && [ "$(writes)" = "0" ] \
  && ok "L2 (control) the same P1 with NO session on it (only one for another bead) → still the head waiter, the P2 cedes, nothing is written — as today" || bad "L2: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess wa-worker-adhoc-wa-p1x 'pool top-up: wa-p1.2')"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && [ "$(writes)" = "0" ] && ok "L2b a session for 'wa-p1.2' is not a session for 'wa-p1' (the title is matched whole, never by prefix)" || bad "L2b: $out"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1' active true)"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && [ "$(writes)" = "0" ] && ok "L3 a CLOSED top-up session is not building anything → waiter, no write" || bad "L3: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1' asleep)"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && [ "$(writes)" = "0" ] && ok "L3b an ASLEEP one is not building it either (and does not take a cap slot) → waiter, no write" || bad "L3b: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"; : > "$WORK/owner.inactive.$SESS_A"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && [ "$(writes)" = "0" ] && ok "L3c a session that is not an ACTIVE owner (idle past the threshold) → waiter, no write (ga-46wq5 would take the claim back: no flapping)" || bad "L3c: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""
sessions "$(sess wa-worker-adhoc-old 'pool top-up: wa-p1' active false 2026-10-14T05:00:00Z)" "$(sess "$SESS_A" 'pool top-up: wa-p1' active false 2026-10-14T08:47:19Z)"
run_py "$(scan_with "$POPL")" >/dev/null
want_write "$SESS_A" && ok "L3d two live sessions titled for the bead → the NEWEST one gets the claim" || bad "L3d: $(cat "$WORK/bd.writes" 2>/dev/null)"
# L3e — "is it an active owner?" is only as good as the roster behind it: with an untrustworthy one the answer is "cannot tell", not "no".
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "_DEADWORKER_OK=0; $(scan_with "$POPL"); _pilot_priority_yield_for '$P2PS' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT= BLIND=1" && echo "$out" | grep -qx "DISPATCHES" && [ "$(writes)" = "0" ] && warned "CANNOT TELL" \
  && ok "L3e the sweep's dead-worker roster is untrustworthy (_DEADWORKER_OK!=1) → BLIND=1: not 'inactive' (a verdict from nothing), not 'building', no write, no cession on a guess" || bad "L3e: $out writes=$(writes) / $(cat "$WORK/log.txt")"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "unset -f _session_is_active_owner; $(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(writes)" = "0" ] && ok "L3f the owner check is not even loaded → BLIND=1, no write (a missing check never lets a claim through)" || bad "L3f: $out writes=$(writes)"

# L4 — three states: the roster that cannot be read is "cannot tell", never "no session" (and never "building").
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; : > "$WORK/sessions.fail"
out="$(run_py "$(scan_with "$POPL"); _pilot_priority_yield_for '$P2PS' && echo CEDES || echo DISPATCHES")"
echo "$out" | grep -qx "WAIT= BLIND=1" && echo "$out" | grep -qx "DISPATCHES" && [ "$(writes)" = "0" ] && warned "CANNOT TELL" \
  && ok "L4a session list FAILS → BLIND=1, nobody is declared a waiter, the P2 is not ceded on a guess, nothing written, said in the log" || bad "L4a: $out / $(cat "$WORK/log.txt")"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; echo 'not json' > "$WORK/sessions.json"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(writes)" = "0" ] && ok "L4b a roster that is not JSON → the same BLIND=1" || bad "L4b: $out"
reset; cap wa-worker 2 2; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(writes)" = "0" ] && ok "L4c the bead's store cannot be found → BLIND=1, no write (no guess about whose claim it is)" || bad "L4c: $out"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"; : > "$WORK/bd.list.fail"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(writes)" = "0" ] && ok "L4d cannot tell whether the session already holds other work → BLIND=1, no write (never double-book on a guess)" || bad "L4d: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=1" ] && [ "$(writes)" = "0" ] && ok "L4e the bead itself cannot be read → BLIND=1, no write" || bad "L4e: $out writes=$(writes)"

# L5..L9 — the claim state decides what is written.
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 in_progress "$SESS_A"; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=0" ] && [ "$(writes)" = "0" ] && ok "L5 already claimed by that session → not a waiter and NOTHING is written (the claim is there)" || bad "L5: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 in_progress someone-else; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && [ "$(writes)" = "0" ] && ok "L6 claimed by SOMEONE ELSE → the Pilot never takes a claim: waiter as today, no write" || bad "L6: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"; holds "$SESS_A" wa-470co3
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && [ "$(writes)" = "0" ] && logged "wa-470co3" \
  && ok "L7 DRIFT (the 14/10 shape): the session already holds wa-470co3 → it is NOT building wa-p1: still the waiter, no write (a second bead would double-book it), the log names what it holds" || bad "L7: $out writes=$(writes) / $(cat "$WORK/log.txt")"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"; : > "$WORK/bd.update.fail"
out="$(run_py "$(scan_with "$POPL")")"
[ "$out" = "WAIT=wa-p1 BLIND=0" ] && warned "could not" && ok "L8 the repair write FAILS → falls back to today's behaviour (waiter) and says so; never 'building' on a claim that did not land" || bad "L8: $out / $(cat "$WORK/log.txt")"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "DRY_RUN=1; $(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=0" ] && [ "$(writes)" = "0" ] && logged "WOULD" && ok "L9 DRY_RUN=1 → the same decision, no write, the log says WOULD" || bad "L9: $out writes=$(writes)"

# L10 — the scan walks PAST a building row to the next one, and reads the sweep's roster when it has one.
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; cap ps-worker 1 1; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
POP2L="$(arr "$(bead wa-p1 1 wa-worker wa)" "$(bead ps-p1 1 ps-worker ps)")"
out="$(run_py "$(scan_with "$POP2L")")"
[ "$out" = "WAIT=ps-p1 BLIND=0" ] && ok "L10a the head row is being built → the NEXT P0/P1 behind a full pool is the waiter (one built P1 does not hide another that waits)" || bad "L10a: $out"
reset; : > "$WORK/store.ok"; cap wa-worker 2 2; claim_state wa-p1 open ""; : > "$WORK/sessions.fail"
out="$(run_py "_SESSIONS_JSON='$(sessions_json_inline=$(jq -cn --arg n "$SESS_A" '{ok:true,sessions:[{name:$n,session_name:$n,alias:$n,agent_name:$n,id:"ga-wisp-x",template:"wa-worker",title:"pool top-up: wa-p1",state:"active",work_dir:"/rig/crew/worker",created_at:"2026-10-14T08:47:19Z",closed:false}]}'); echo "$sessions_json_inline")'; $(scan_with "$POPL")")"
[ "$out" = "WAIT= BLIND=0" ] && ! grep -q 'session list' "$WORK/gc.calls" 2>/dev/null && ok "L10b the sweep's own roster (_SESSIONS_JSON) is used when it is readable — no second 'gc session list'" || bad "L10b: $out calls=$(cat "$WORK/gc.calls" 2>/dev/null)"

# L11 — the second entry point: a P0/P1 that ends QUEUED during the sweep's own dispatch.
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "_pilot_priority_waiter_note '$(bead wa-p1 1 wa-worker wa)' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}] BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT=[] BLIND=0" ] && want_write "$SESS_A" && ok "L11a a P1 that queued behind the full pool but has a live top-up session → not recorded as the waiter, claim repaired" || bad "L11a: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""
out="$(run_py "_pilot_priority_waiter_note '$(bead wa-p1 1 wa-worker wa)' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}]\"")"
[ "$out" = "WAIT=[wa-p1]" ] && [ "$(writes)" = "0" ] && ok "L11b (control) the same without a session → recorded as the waiter, as today" || bad "L11b: $out"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; : > "$WORK/sessions.fail"
out="$(run_py "_pilot_priority_waiter_note '$(bead wa-p1 1 wa-worker wa)' wa-worker 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}] BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT=[] BLIND=1" ] && ok "L11c the roster cannot be read → not recorded, BLIND=1" || bad "L11c: $out"
reset; : > "$WORK/store.ok"; claim_state new1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: new1')"
out="$(run_py "_pilot_priority_waiter_note '$(bead new1 1 - wa)' '' 2 2; echo \"WAIT=[\${_PY_WAIT_ID:-}]\"")"
[ "$out" = "WAIT=[new1]" ] && ok "L11d a bead with no route and no pool argument (first sight) keeps the old behaviour: no pool, no top-up session to look for" || bad "L11d: $out"

# L12 — the claim is written AT SPAWN, before the worker boots (the cause, not just the repair): the session then resumes it in Step 1a.
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "_topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && want_write "$SESS_A" && grep -qF -- "--set-metadata gc.session_name=$SESS_A" "$WORK/bd.writes" \
  && ok "L12a right after the spawn the session is BOUND to its bead: status in_progress + assignee = the new session (+ gc.session_name / gc.work_dir)" || bad "L12a: $out writes=$(writes): $(cat "$WORK/bd.writes" 2>/dev/null)"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "_SESSIONS_JSON='{\"ok\":true,\"sessions\":[]}'; _topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && want_write "$SESS_A" && ok "L12b the bind reads a FRESH roster (the sweep-start one cannot contain a session born this sweep)" || bad "L12b: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; claim_state wa-p1 in_progress someone-else; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "_topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && [ "$(writes)" = "0" ] && ok "L12c the bead got a claim in the meantime → nothing is written over it" || bad "L12c: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""
out="$(run_py "_topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && [ "$(writes)" = "0" ] && warned "no live top-up session" && ok "L12d the session cannot be found → no write, a warn, rc 0 (the spawn already happened; the sweep-level repair is the net)" || bad "L12d: $out"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; : > "$WORK/sessions.fail"
out="$(run_py "_topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && [ "$(writes)" = "0" ] && warned "CANNOT TELL" && ok "L12e the roster cannot be read → no write, a warn, rc 0" || bad "L12e: $out"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"; : > "$WORK/bd.update.fail"
out="$(run_py "_topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && warned "could not" && ok "L12f the write fails → warn, rc 0 (never stops the sweep)" || bad "L12f: $out"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "DRY_RUN=1; _topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && [ "$(writes)" = "0" ] && ok "L12g DRY_RUN=1 → no write" || bad "L12g: $out writes=$(writes)"
reset; : > "$WORK/store.ok"; claim_state wa-p1 open ""; sessions "$(sess "$SESS_A" 'pool top-up: wa-p1')"
out="$(run_py "PILOT_TOPUP_BIND=0; _topup_bind_after_spawn wa-worker wa-p1; echo rc=\$?")"
[ "$out" = "rc=0" ] && [ "$(writes)" = "0" ] && ok "L12h PILOT_TOPUP_BIND=0 → the spawn binds nothing (kill switch)" || bad "L12h: $out writes=$(writes)"

# L13 — the alarm: N consecutive sweeps with dispatched=0, free slots and cessions > 0 → the Mayor is mailed ONCE, naming the P0/P1 and the pool sessions.
stall_sweep() {  # stall_sweep <dispatched> <yielded> <small_slots> [extra shell]  — one sweep's Step 5 in a fresh process, sharing the state file
  run_py "PILOT_YIELD_STALL_SWEEPS=3; DISPATCHED=$1; PRIORITY_YIELDED=$2; SMALL_SLOTS=$3; BIG_SLOTS=0; _PY_WAIT_ID=wa-p1; _PY_WAIT_PRIO=1; _PY_WAIT_RIG=wa; _PY_WAIT_POOL=wa-worker; _PY_WAIT_LIVE=2; _PY_WAIT_MAX=2; ${4:+$4; }_pilot_yield_stall_check; echo rc=\$?"
}
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')" "$(sess wa-worker-adhoc-bbb 'pool top-up: wa-cng2n8')"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "0" ] && ok "L13a two sweeps of the pattern (N=3) → no mail yet" || bad "L13a mails=$(mails)"
out="$(stall_sweep 0 150 2)"
[ "$(mails)" = "1" ] && echo "$out" | grep -qx "rc=0" && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF 'wa-p1' && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF "$SESS_A" \
  && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF 'wa-worker-adhoc-bbb' && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF 'pool top-up: wa-470co3' \
  && ok "L13b the 3rd sweep → ONE mail to the Mayor naming the P1 and every pool session (name + what it was opened for)" || bad "L13b mails=$(mails): $(cat "$WORK/gc.calls" 2>/dev/null)"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "1" ] && ok "L13c the streak goes on → NOT mailed again (once per streak and waiter)" || bad "L13c mails=$(mails)"
stall_sweep 1 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "1" ] && ok "L13d a sweep that DISPATCHED ends the streak (the count restarts: 2 more sweeps are not enough)" || bad "L13d mails=$(mails)"
stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "2" ] && ok "L13e ...and a NEW streak of 3 mails again" || bad "L13e mails=$(mails)"
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"
stall_sweep 0 0 2 >/dev/null; stall_sweep 0 0 2 >/dev/null; stall_sweep 0 0 2 >/dev/null; stall_sweep 0 0 2 >/dev/null
[ "$(mails)" = "0" ] && ok "L13f (control) dispatched=0 with NO cession is not this alarm (that is Step 5's own stall counter)" || bad "L13f mails=$(mails)"
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"
stall_sweep 0 150 0 >/dev/null; stall_sweep 0 150 0 >/dev/null; stall_sweep 0 150 0 >/dev/null; stall_sweep 0 150 0 >/dev/null
[ "$(mails)" = "0" ] && ok "L13g (control) cessions but NO free slot → no mail (the lanes are simply full)" || bad "L13g mails=$(mails)"
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 "_PY_WAIT_ID=ps-p1" >/dev/null
[ "$(mails)" = "0" ] && ok "L13h the head waiter CHANGED mid-streak → the streak restarts (it is not the same P1 being starved)" || bad "L13h mails=$(mails)"
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null; before="$(cat "$WORK/stall.state" 2>/dev/null)"
stall_sweep 0 150 2 "DRY_RUN=1" >/dev/null
[ "$(mails)" = "0" ] && [ -n "$before" ] && [ "$(cat "$WORK/stall.state")" = "$before" ] && logged "WOULD" \
  && ok "L13i DRY_RUN=1 → reads the streak, says what it would send on the 3rd sweep, mails nothing and leaves the state file as it was" || bad "L13i mails=$(mails) state=$(cat "$WORK/stall.state" 2>/dev/null) before=$before"
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"; : > "$WORK/gc.fail"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null
rm -f "$WORK/gc.fail"; stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "2" ] && ok "L13j a mail that FAILED is retried on the next sweep (recorded as sent only after gc accepted it)" || bad "L13j mails=$(mails): $(cat "$WORK/gc.calls" 2>/dev/null)"
reset; : > "$WORK/sessions.fail"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "1" ] && grep -F 'mail send mayor' "$WORK/gc.calls" | grep -qF 'wa-p1' && ok "L13k the pool sessions cannot be listed → the mail still goes (naming the P1) and says the list was unreadable" || bad "L13k mails=$(mails)"
reset
out="$(run_py "PILOT_YIELD_STALL_SWEEPS=3; DISPATCHED=0; PRIORITY_YIELDED=150; SMALL_SLOTS=2; BIG_SLOTS=0; _PY_WAIT_ID=''; _pilot_yield_stall_check; _pilot_yield_stall_check; _pilot_yield_stall_check; echo rc=\$?")"
[ "$out" = "rc=0" ] && [ "$(mails)" = "0" ] && ok "L13l no head waiter known → nothing to name, no streak, no mail" || bad "L13l: $out mails=$(mails)"
# L13m — a counter the sweep cannot read is "cannot tell": the streak ENDS (not extended) and the log says so — it never counts as dispatched=0.
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"
stall_sweep 0 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null; stall_sweep abc 150 2 >/dev/null; stall_sweep 0 150 2 >/dev/null
[ "$(mails)" = "0" ] && [ "$(cut -f1 "$WORK/stall.state" 2>/dev/null)" = "1" ] && warned "CANNOT READ" \
  && ok "L13m dispatched='abc' in the middle of a streak → no mail, the count restarts at 1 afterwards, said in the log" || bad "L13m mails=$(mails) state=$(cat "$WORK/stall.state" 2>/dev/null)"
reset; sessions "$(sess "$SESS_A" 'pool top-up: wa-470co3')"
stall_sweep 0 '' 2 >/dev/null; stall_sweep 0 150 '' >/dev/null; stall_sweep 0 150 2 "BIG_SLOTS=x" >/dev/null
[ "$(mails)" = "0" ] && [ ! -e "$WORK/stall.state" ] && warned "CANNOT READ" && ok "L13n an empty yield count, an empty slot count and a non-numeric big-slot count all end the streak too (no state kept)" || bad "L13n mails=$(mails) state=$(cat "$WORK/stall.state" 2>/dev/null)"

# ── I: the wiring in the dispatcher (order assertions — the functions above are inert unless these hold) ─────────────────
echo "I. wiring order in the dispatcher"
ln() { grep -n -m1 -- "$1" "$DISPATCHER" | cut -d: -f1; }
L_PROJ="$(grep -n -m1 '^[[:space:]]*_pilot_priority_project_emit "\$_ordered"' "$DISPATCHER" | cut -d: -f1)"
L_ORDCHK="$(ln 'if \[ "\$_wo_ok" != "1" \]')"
{ [ -n "$L_PROJ" ] && [ -n "$L_ORDCHK" ] && [ "$L_PROJ" -gt "$L_ORDCHK" ]; } && ok "I1 the emit hands over its projections AFTER the work-order check (an unorderable population is 'cannot tell' for the yield too)" || bad "I1 proj=$L_PROJ ordchk=$L_ORDCHK"
L_SCAN="$(grep -n -m1 '^_pilot_priority_waiting_scan$' "$DISPATCHER" | cut -d: -f1)"
L_TOPWA="$(grep -n -m1 '^_pilot_pool_topup "wa-worker"' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_SCAN" ] && [ -n "$L_TOPWA" ] && [ "$L_SCAN" -lt "$L_TOPWA" ]; } && ok "I2 the scan runs once per sweep BEFORE the first pool top-up" || bad "I2 scan=$L_SCAN topup=$L_TOPWA"
L_YTOP="$(grep -n -m1 '_pilot_priority_yield_for_id "\$_pool" "\$_pending"' "$DISPATCHER" | cut -d: -f1)"
L_SPAWN="$(grep -n -m1 '_pilot_topup_spawn "\$_pool" "\$_pending"' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_YTOP" ] && [ -n "$L_SPAWN" ] && [ "$L_YTOP" -lt "$L_SPAWN" ]; } && ok "I3 the top-up asks the yield BEFORE it spawns" || bad "I3 yield=$L_YTOP spawn=$L_SPAWN"
L_YLANE="$(grep -n -m1 '_pilot_priority_pool_bound_pre "\$pick" && _pilot_priority_yield_for "\$pick"' "$DISPATCHER" | cut -d: -f1)"
L_CAPLANE="$(grep -n -m1 '_pilot_pool_cap_full_for "\$pick"; then' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_YLANE" ] && [ -n "$L_CAPLANE" ] && [ "$L_YLANE" -lt "$L_CAPLANE" ]; } && ok "I4 dispatch_lane asks the yield BEFORE the pre-claim cap skip (a ceded P2 in a full pool reads 'cedida', not 'QUEUED')" || bad "I4 yield=$L_YLANE cap=$L_CAPLANE"
L_YONE="$(grep -n -m1 '_pilot_priority_target_is_pool "\$_PYS_TARGET" && _pilot_priority_yield_for "\$STORY"' "$DISPATCHER" | cut -d: -f1)"
L_PROMPT="$(grep -n -m1 'WORKTREE_DIRECTIVE=\$(worktree_directive_for' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_YONE" ] && [ -n "$L_PROMPT" ] && [ "$L_YONE" -lt "$L_PROMPT" ]; } && ok "I5 dispatch_one cedes BEFORE the prompt is assembled (the ~1 min per candidate of ga-5je3zv)" || bad "I5 yield=$L_YONE prompt=$L_PROMPT"
L_FOCUS="$(grep -n -m1 '^export PILOT_GATE_FOCUS$' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_FOCUS" ] && [ -n "$L_SCAN" ] && [ "$L_FOCUS" -lt "$L_SCAN" ]; } && ok "I7 PILOT_GATE_FOCUS is decided BEFORE the scan reads it (the emit runs earlier and cannot know it; the scan can)" || bad "I7 focus=$L_FOCUS scan=$L_SCAN"
grep -q 'priority_yield_blind: num(\$blind)' "$DISPATCHER" && grep -q '"yielded_priority"' "$DISPATCHER" && ok "I6 the sweep event carries priority_yield_blind and the yielded_priority outcome" || bad "I6 sweep event fields missing"
# ga-2lca0l: the claim is written at spawn, the scan and the queued-note ask whether a top-up session is already on the bead, the alarm runs.
L_NOTE="$(grep -n -m1 '0) _topup_note_spawn "\$_pool" "\$_pending"' "$DISPATCHER" | cut -d: -f1)"
L_BIND="$(grep -n -m1 '^[[:space:]]*_topup_bind_after_spawn "\$_pool" "\$_pending"' "$DISPATCHER" | cut -d: -f1)"
L_GLOB="$(grep -n -m1 '^[[:space:]]*_global=\$((_global + 1))' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_SPAWN" ] && [ -n "$L_NOTE" ] && [ -n "$L_BIND" ] && [ -n "$L_GLOB" ] && [ "$L_SPAWN" -lt "$L_NOTE" ] && [ "$L_NOTE" -lt "$L_BIND" ] && [ "$L_BIND" -lt "$L_GLOB" ]; } \
  && ok "I8 the top-up binds the new session to its bead right after a SUCCESSFUL spawn (after the brake's note, before the live count moves)" || bad "I8 spawn=$L_SPAWN note=$L_NOTE bind=$L_BIND glob=$L_GLOB"
L_TBN="$(grep -c '_pilot_priority_topup_building "\$' "$DISPATCHER")"
[ "${L_TBN:-0}" -ge 2 ] && ok "I9 _pilot_priority_topup_building is called from BOTH entry points (the scan and the queued-note), not only defined" || bad "I9 call sites=$L_TBN"
L_SCANCAP="$(grep -n -m1 'if _pilot_pool_cap_full_for "\$_story"; then' "$DISPATCHER" | cut -d: -f1)"
L_SCANTB="$(grep -n -m1 '_tb=0; _pilot_priority_topup_building "\$_id" "\$_PCAP_POOL"' "$DISPATCHER" | cut -d: -f1)"
L_SCANWAIT="$(grep -n -m1 '^      _PY_WAIT_ID="\$_id"; _PY_WAIT_PRIO="\$_prio"' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_SCANCAP" ] && [ -n "$L_SCANTB" ] && [ -n "$L_SCANWAIT" ] && [ "$L_SCANCAP" -lt "$L_SCANTB" ] && [ "$L_SCANTB" -lt "$L_SCANWAIT" ]; } \
  && ok "I10 in the scan the building check sits between 'the pool is full' and 'so this bead is the waiter'" || bad "I10 cap=$L_SCANCAP tb=$L_SCANTB wait=$L_SCANWAIT"
L_STALL="$(grep -n -m1 '^_pilot_yield_stall_check || true$' "$DISPATCHER" | cut -d: -f1)"
L_Y1M="$(grep -n -m1 'ga-y1m40: dispatched=0 with free slots' "$DISPATCHER" | cut -d: -f1)"
L_DONE="$(grep -n 'log "=== Pilot sweep complete: dispatched=' "$DISPATCHER" | tail -1 | cut -d: -f1)"   # the last one: the end of the sweep
{ [ -n "$L_STALL" ] && [ -n "$L_Y1M" ] && [ -n "$L_DONE" ] && [ "$L_Y1M" -lt "$L_STALL" ] && [ "$L_STALL" -lt "$L_DONE" ]; } \
  && ok "I11 the yield-stall alarm runs once per sweep, after Step 5's own streak and before the sweep-complete line" || bad "I11 y1m40=$L_Y1M stall=$L_STALL done=$L_DONE"

echo
echo "pilot-dispatcher.priority-yield.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
