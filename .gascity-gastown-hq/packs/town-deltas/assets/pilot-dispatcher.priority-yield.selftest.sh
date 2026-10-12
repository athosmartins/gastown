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
# Every scenario that asserts the FIX fails on a dispatcher without the block (FATAL: block not found) and on the mutants listed
# at the bottom of the bead comment. Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
WO_LIB="${PILOT_WORK_ORDER_LIB:-$SELF_DIR/scripts/work-order.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$WO_LIB" ]     || { echo "FATAL: work-order library not found at $WO_LIB" >&2; exit 2; }
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
  *" label "*|*" update "*) echo "$args" >> "$W/bd.writes"; exit 0 ;;
esac
exit 0
BDEOF
cat > "$WORK/bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
shift
exec "$@"
TOEOF
chmod +x "$WORK/bin/bd" "$WORK/bin/timeout"
sandbox_path_init "$WORK" jq || exit 2

reset() { rm -f "$WORK"/cap.* "$WORK"/bd.writes "$WORK"/log.txt "$WORK"/unmark.log "$WORK"/show.*.json "$WORK"/crew.* "$WORK"/builders.* "$WORK/city/.gc/priority-yield.off"; }
logged()   { grep -qF -- "$1" "$WORK/log.txt" 2>/dev/null; }
warned()   { grep -qF -- "warn	"  "$WORK/log.txt" 2>/dev/null && grep -F -- "warn	" "$WORK/log.txt" | grep -qF -- "$1"; }
writes()   { [ -f "$WORK/bd.writes" ] && wc -l < "$WORK/bd.writes" | tr -d ' ' || echo 0; }
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
out="$(run_py "_PY_EMIT_OK=1; _PY_P01='[{\"id\":\"x\",\"priority\":0,\"rig\":\"wa\",\"routed_to\":\"wa-worker\",\"focus_fix\":\"yes\",\"braked\":false},{\"id\":\"y\",\"priority\":1,\"rig\":\"wa\",\"routed_to\":\"wa-worker\",\"focus_fix\":false,\"braked\":false}]'; _pilot_priority_waiting_scan; echo \"WAIT=\${_PY_WAIT_ID:-} BLIND=\${_PY_BLIND}\"")"
[ "$out" = "WAIT=y BLIND=0" ] && ok "J6b an unreadable row followed by a real waiter → the waiter is used and the sweep is NOT blind (the doubt changes nothing)" || bad "J6b: $out"
# Drift guard: the projection's focus predicate must be the one _filter_candidates applies under focus (keep-in-sync pair).
pred() { grep -o 'any((\.labels // \[\])\[\]; \. == "gate:needs-fix".*"impacto:dano-ao-vivo")' <<< "$1" | head -1; }
P_PROJ="$(pred "$PROJECT_SRC")"; P_FILT="$(pred "$(fn_src _filter_candidates)")"
{ [ -n "$P_PROJ" ] && [ "$P_PROJ" = "$P_FILT" ]; } && ok "J7 drift guard: the projection's focus predicate is byte-identical to _filter_candidates' focus clause" || bad "J7 predicates differ: proj=[$P_PROJ] filter=[$P_FILT]"

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
L_CAPLANE="$(grep -n -m1 'if _pilot_pool_cap_full_for "\$pick"; then' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_YLANE" ] && [ -n "$L_CAPLANE" ] && [ "$L_YLANE" -lt "$L_CAPLANE" ]; } && ok "I4 dispatch_lane asks the yield BEFORE the pre-claim cap skip (a ceded P2 in a full pool reads 'cedida', not 'QUEUED')" || bad "I4 yield=$L_YLANE cap=$L_CAPLANE"
L_YONE="$(grep -n -m1 '_pilot_priority_target_is_pool "\$_PYS_TARGET" && _pilot_priority_yield_for "\$STORY"' "$DISPATCHER" | cut -d: -f1)"
L_PROMPT="$(grep -n -m1 'WORKTREE_DIRECTIVE=\$(worktree_directive_for' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_YONE" ] && [ -n "$L_PROMPT" ] && [ "$L_YONE" -lt "$L_PROMPT" ]; } && ok "I5 dispatch_one cedes BEFORE the prompt is assembled (the ~1 min per candidate of ga-5je3zv)" || bad "I5 yield=$L_YONE prompt=$L_PROMPT"
L_FOCUS="$(grep -n -m1 '^export PILOT_GATE_FOCUS$' "$DISPATCHER" | cut -d: -f1)"
{ [ -n "$L_FOCUS" ] && [ -n "$L_SCAN" ] && [ "$L_FOCUS" -lt "$L_SCAN" ]; } && ok "I7 PILOT_GATE_FOCUS is decided BEFORE the scan reads it (the emit runs earlier and cannot know it; the scan can)" || bad "I7 focus=$L_FOCUS scan=$L_SCAN"
grep -q 'priority_yield_blind: num(\$blind)' "$DISPATCHER" && grep -q '"yielded_priority"' "$DISPATCHER" && ok "I6 the sweep event carries priority_yield_blind and the yielded_priority outcome" || bad "I6 sweep event fields missing"

echo
echo "pilot-dispatcher.priority-yield.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
