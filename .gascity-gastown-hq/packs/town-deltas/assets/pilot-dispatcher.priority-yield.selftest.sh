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
  *" label "*|*" update "*) echo "$args" >> "$W/bd.writes"; exit 0 ;;
esac
exit 0
BDEOF
# Fake gc (ga-qmfm8r): records every call on ONE line in $W/gc.calls (newlines of the mail body flattened) and fails iff $W/gc.fail exists.
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
printf 'CALL %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$W/gc.calls"
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

reset() { rm -f "$WORK"/cap.* "$WORK"/bd.writes "$WORK"/log.txt "$WORK"/unmark.log "$WORK"/show.*.json "$WORK"/crew.* "$WORK"/builders.* "$WORK/city/.gc/priority-yield.off" "$WORK"/gc.calls "$WORK"/gc.fail "$WORK"/unservable.state; }
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
