#!/usr/bin/env bash
# quality-gate-dispatcher.global-cap-fail-closed.selftest.sh — ga-z4jhda
#
# Twin of ga-oa004t (pilot-dispatcher.pool-cap-fail-closed.selftest.sh), on the GATE side.
#
# The gate decides the global variable-session cap (ga-jezvn: wa-worker + ps-worker +
# gate-reviewer, GC_VARIABLE_SESSION_MAX) right before it claims a marker and spawns
# reviewers. It read the live count as
#     timeout 10 gc session list --json | jq '…length' || echo "0"
# so a probe that failed / timed out / returned junk read as "0 live sessions", the cap read
# as free capacity, and the gate opened reviewers. `gc session list --json` takes 7-10s under
# load 55+ (measured 2026-09-25) against that 10s budget: the guard switched itself OFF
# exactly when the machine was most loaded. `start-pending` (accepted by the controller, not
# yet started — it WILL become a process) was not counted either.
#
# Contract asserted here (mirrors the Pilot's _pilot_live_session_count):
#   - an UNREADABLE count is a third state, never 0: the gate logs it, exits 0 WITHOUT
#     touching any marker (they stay queued, retried next sweep) and does not reach Step 0b-1;
#   - a legitimately EMPTY list is still 0 (control: must not over-block);
#   - start-pending counts as live;
#   - the probe budget is a real bound (GATE_SESSION_LIST_TIMEOUT_SECS).
#
# How it runs: the gate's cap block is extracted VERBATIM from the script under test (the text
# between the ga-jezvn header and the Step 0b-1 header) and evaluated in a `set -euo pipefail`
# subshell — same option set as the gate — against a fake `gc` that is a REAL executable on PATH
# (`timeout` exec()s its argument; a shell function named gc would be invisible to it). A
# sentinel line after the block records whether control FELL THROUGH to Step 0b-1.
#
# Every scenario marked RED-on-base fails against the unmodified gate: run with
# GATE_DISPATCHER_PATH pointing at a pre-fix copy to see it. The controls (C*) must pass on
# both — they only guard against over-blocking.
#
# All scenario state lives in FILES under $WORK: a `$(…)` subshell swallows variable
# assignments and stub logs, which would make every "nothing happened" assertion vacuous.
#
# Exit 0 iff every scenario behaves as expected. Bash 3.2 compatible.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE_DISPATCHER_PATH:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$GATE" ] || { echo "FATAL: gate dispatcher not found at $GATE" >&2; exit 2; }

# fn_src <name> — the function's source verbatim, or nothing if the file does not define it.
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$GATE"; }

FUNCS=""
for _f in gc_json_or_unknown gc_variable_session_count _gate_variable_session_count; do
  FUNCS="$FUNCS
$(fn_src "$_f")"
done
[ -n "$(fn_src gc_json_or_unknown)" ] || { echo "FATAL: gc_json_or_unknown() not found in $GATE" >&2; exit 2; }

# The cap block, verbatim from the script under test.
BLOCK="$(awk '/^# ── ga-jezvn: GLOBAL variable-session cap, shared with pilot-dispatcher\.sh/{f=1} /^# ── Step 0b-1 \(ga-cw4pm\)/{f=0} f' "$GATE")"
[ -n "$BLOCK" ] || { echo "FATAL: could not extract the ga-jezvn cap block from $GATE (header moved?)" >&2; exit 2; }
CAP_HIT_LINES="$(printf '%s\n' "$BLOCK" | grep -c 'GLOBAL variable-session cap hit')"
[ "$CAP_HIT_LINES" = "1" ] || { echo "FATAL: extracted block has $CAP_HIT_LINES cap-hit log lines (expected exactly 1) — extraction is off" >&2; exit 2; }

command -v timeout >/dev/null 2>&1 || { echo "FATAL: no 'timeout' on PATH — the gate itself needs it" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-globalcap-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake gc — behaviour steered by files in $SELFTEST_WORK. `exec sleep`: a plain `sleep` child
# would survive `timeout`'s SIGTERM to this script and hold the pipe open, stalling the caller's
# $(…) for the whole sleep (the very hang the probe budget exists to bound).
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
W="${SELFTEST_WORK:?}"
case "$*" in
  *"session list"*)
    echo x >> "$W/list.calls"
    [ -f "$W/sl.sleep" ] && exec sleep "$(cat "$W/sl.sleep")"
    if [ -f "$W/sl.fail" ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$W/sl.envelope" ]; then printf '{"ok":false,"error":{"code":"native_store_unavailable"}}'; exit 0; fi
    if [ -f "$W/sl.garbage" ]; then printf 'not json at all <<<'; exit 0; fi
    cat "$W/sl.json"; exit 0 ;;
  *)
    # anything else the block might run (a claim, a spawn) is recorded — the cap block must never.
    echo "$*" >> "$W/other.calls"
    exit 0 ;;
esac
GCEOF
chmod +x "$WORK/bin/gc"

reset() { rm -f "$WORK"/list.calls "$WORK"/other.calls "$WORK"/sl.* "$WORK"/log.txt "$WORK"/reached "$WORK"/block.rc; }
# sessions_json <template:state>... -> {"sessions":[…]}
sessions_json() {
  local _first=1 _s _i=0
  printf '{"sessions":['
  for _s in "$@"; do
    [ "$_first" = 1 ] || printf ','
    _first=0; _i=$((_i+1))
    printf '{"id":"s%d","template":"%s","state":"%s"}' "$_i" "${_s%%:*}" "${_s##*:}"
  done
  printf ']}'
}
list_calls() { [ -f "$WORK/list.calls" ] && wc -l < "$WORK/list.calls" | tr -d ' ' || echo 0; }
other_calls() { [ -f "$WORK/other.calls" ] && wc -l < "$WORK/other.calls" | tr -d ' ' || echo 0; }
logged() { grep -qF -- "$1" "$WORK/log.txt" 2>/dev/null; }
reached() { [ -f "$WORK/reached" ]; }

# run_block — evaluate the gate's cap block exactly as the gate does (set -euo pipefail), then a
# sentinel. `exit 0` inside the block ends the subshell, like the real script's early exit.
run_block() {
  (
    PATH="$WORK/bin:$PATH"
    SELFTEST_WORK="$WORK"; export SELFTEST_WORK
    GC_CITY="test-city"; COUNT=3; GC_VARIABLE_SESSION_MAX=6
    unset GC_VARIABLE_SESSION_COUNT_OVERRIDE 2>/dev/null || true
    [ -n "${T_TIMEOUT_SECS:-}" ] && GATE_SESSION_LIST_TIMEOUT_SECS="$T_TIMEOUT_SECS" && export GATE_SESSION_LIST_TIMEOUT_SECS
    [ -n "${T_OVERRIDE:-}" ] && GC_VARIABLE_SESSION_COUNT_OVERRIDE="$T_OVERRIDE"
    set -euo pipefail
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    eval "$FUNCS"
    eval "$BLOCK"
    : > "$WORK/reached"
  )
  echo "$?" > "$WORK/block.rc"
}
block_rc() { cat "$WORK/block.rc" 2>/dev/null || echo "?"; }

echo "quality-gate-dispatcher.global-cap-fail-closed.selftest — unreadable session count fails CLOSED in the gate's global cap (ga-z4jhda)"

# ── Harness sanity: the fake gc is executable and is what the block would call ──
echo "S0: harness — fake gc is a real executable and serves a session list"
reset; sessions_json wa-worker:active > "$WORK/sl.json"
_probe_out="$(PATH="$WORK/bin:$PATH" SELFTEST_WORK="$WORK" gc --city x session list --json 2>&1)"
case "$_probe_out" in
  *wa-worker*) ok "S0: fake gc serves the fixture (stub is executable, would be found on PATH)" ;;
  *) bad "S0: fake gc did not serve the fixture (got: $_probe_out) — every scenario below would be measuring the wrong thing" ;;
esac

# ── C1: control — readable, under the cap → falls through to Step 0b-1 ────────
echo "C1 (control): readable list, 2 live < cap 6 — must proceed to Step 0b-1"
reset; sessions_json wa-worker:active gate-reviewer:active > "$WORK/sl.json"
run_block
if reached && [ "$(block_rc)" = "0" ]; then ok "C1: under cap → fell through"; else bad "C1: did not fall through (rc=$(block_rc))"; fi
[ "$(list_calls)" = "1" ] && ok "C1: the block probed the (fake) session list exactly once" \
  || bad "C1: expected exactly 1 'session list' call, saw $(list_calls) — the block is not using the stub"
logged "cap hit" && bad "C1: 'cap hit' logged although 2 < 6" || ok "C1: no cap-hit line"
logged "cannot read" && bad "C1: 'cannot read' logged for a perfectly readable list (over-blocking)" || ok "C1: no 'cannot read' line for a readable list"

# ── C2: control — readable, at the cap → queued, existing behavior ───────────
echo "C2 (control): readable list, 6 live == cap 6 — must QUEUE (exit 0, not reach Step 0b-1)"
reset; sessions_json wa-worker:active wa-worker:active ps-worker:active ps-worker:creating gate-reviewer:active gate-reviewer:active > "$WORK/sl.json"
run_block
if ! reached && [ "$(block_rc)" = "0" ]; then ok "C2: at cap → exit 0 before Step 0b-1"; else bad "C2: expected exit 0 without reaching Step 0b-1 (rc=$(block_rc), reached=$(reached && echo yes || echo no))"; fi
logged "GLOBAL variable-session cap hit (6/6" && ok "C2: logs the existing cap-hit line" || bad "C2: cap-hit line missing/changed"

# ── C3: control — a legitimately EMPTY list is 0, not 'unreadable' ───────────
echo "C3 (control): readable, EMPTY list — 0 live is a real answer; must proceed (no over-blocking)"
reset; printf '{"sessions":[]}' > "$WORK/sl.json"
run_block
if reached && [ "$(block_rc)" = "0" ]; then ok "C3: empty-but-valid list → 0 live → fell through"; else bad "C3: an EMPTY list blocked the gate (rc=$(block_rc)) — fail-closed over-reached into the legitimate-empty state"; fi
logged "cannot read" && bad "C3: empty list mis-announced as unreadable" || ok "C3: empty list is not announced as unreadable"

# ── C4: control — only the 3 variable templates and only live states count ───
echo "C4 (control): 5 variable + dogs/crew/closed sessions — non-variable templates and dead states must not count"
reset; sessions_json wa-worker:active wa-worker:active ps-worker:active gate-reviewer:active gate-reviewer:creating \
  gastown.dog:active gastown.dog:active mayor:active batista-wa:active wa-worker:closed ps-worker:stopped > "$WORK/sl.json"
run_block
if reached; then ok "C4: 5 live variable sessions < 6 → fell through"; else bad "C4: over-counted (dogs/crew/closed leaked into the total) — blocked at <6"; fi

# ── C5: control — the test seam still short-circuits the probe ───────────────
echo "C5 (control): GC_VARIABLE_SESSION_COUNT_OVERRIDE bypasses 'gc session list' entirely"
reset; : > "$WORK/sl.fail"; T_OVERRIDE=3 run_block
if reached && [ "$(list_calls)" = "0" ]; then ok "C5: override=3 → proceeds, 0 probe calls (even with a broken gc)"; else bad "C5: override not honoured (list_calls=$(list_calls), reached=$(reached && echo yes || echo no))"; fi
reset; T_OVERRIDE=6 run_block
if ! reached && logged "GLOBAL variable-session cap hit (6/6"; then ok "C5: override=6 → cap hit"; else bad "C5: override=6 did not trip the cap"; fi

# ── T1 (RED on base): the probe FAILS → must not fall through ────────────────
echo "T1: 'gc session list' exits non-zero — count is UNREADABLE (was: read as 0, gate opened reviewers)"
reset; : > "$WORK/sl.fail"
run_block
if ! reached && [ "$(block_rc)" = "0" ]; then ok "T1: unreadable → exit 0, Step 0b-1 NOT reached (markers stay queued)"; else bad "T1: gate fell through to Step 0b-1 (reached reviewer admission) on an UNREADABLE count — the cap guard fails OPEN"; fi
logged "cannot read the global variable-session count" && ok "T1: the blind spot is ANNOUNCED (not a silent skip)" \
  || bad "T1: no 'cannot read the global variable-session count' line — a dead probe would look identical to an idle pool"
[ "$(other_calls)" = "0" ] && ok "T1: nothing but 'session list' was invoked (no claim/spawn side effects)" || bad "T1: the cap block invoked $(other_calls) other gc call(s)"

# ── T2 (RED on base): exit 0 + error envelope ────────────────────────────────
echo "T2: exit 0 but {\"ok\":false} envelope — unreadable, not 0"
reset; : > "$WORK/sl.envelope"
run_block
if ! reached && [ "$(block_rc)" = "0" ]; then ok "T2: error envelope → unreadable → queued"; else bad "T2: error envelope read as an empty pool — gate fell through"; fi
logged "cannot read the global variable-session count" && ok "T2: announced" || bad "T2: not announced"

# ── T3 (RED on base): exit 0 + malformed output ──────────────────────────────
echo "T3: exit 0 but non-JSON output — unreadable, not 0"
reset; : > "$WORK/sl.garbage"
run_block
if ! reached && [ "$(block_rc)" = "0" ]; then ok "T3: malformed output → unreadable → queued"; else bad "T3: malformed output read as an empty pool — gate fell through"; fi

# ── T4 (RED on base): valid JSON without a .sessions array ───────────────────
echo "T4: valid JSON but no .sessions array (e.g. {}) — unreadable, not '0 sessions'"
reset; printf '{"error":"store unavailable"}' > "$WORK/sl.json"
run_block
if ! reached && [ "$(block_rc)" = "0" ]; then ok "T4: no .sessions array → unreadable → queued"; else bad "T4: a JSON without .sessions read as an empty pool — gate fell through"; fi
logged "cannot read the global variable-session count" && ok "T4: announced" || bad "T4: not announced"

# ── T5 (RED on base): the probe budget is a real, configurable bound ─────────
echo "T5: probe slower than GATE_SESSION_LIST_TIMEOUT_SECS (1s; fake gc sleeps 4s) — timed out = unreadable"
reset; echo 4 > "$WORK/sl.sleep"
_t0=$(date +%s); T_TIMEOUT_SECS=1 run_block; _t1=$(date +%s)
if ! reached && [ "$(block_rc)" = "0" ]; then ok "T5: timed-out probe → unreadable → queued"; else bad "T5: a probe that blew its budget read as an empty pool — gate fell through"; fi
[ $(( _t1 - _t0 )) -lt 4 ] && ok "T5: the block returned in $(( _t1 - _t0 ))s — the budget is enforced, not just declared" \
  || bad "T5: the block took $(( _t1 - _t0 ))s (>= the 4s sleep) — the probe budget was NOT honoured"

# ── T6 (RED on base): start-pending is live ─────────────────────────────────
echo "T6: 5 active + 1 start-pending == 6 == cap — start-pending WILL become a process, so it counts"
reset; sessions_json wa-worker:active wa-worker:active ps-worker:active gate-reviewer:active gate-reviewer:active gate-reviewer:start-pending > "$WORK/sl.json"
run_block
if ! reached && logged "GLOBAL variable-session cap hit (6/6"; then ok "T6: start-pending counted → cap hit at 6/6"; else bad "T6: start-pending was not counted — 5 read as under the cap and the gate admitted another reviewer"; fi

# ── D1 (RED on base): drift guard — no fail-open read left in the spawn gate ─
echo "D1: drift guard — the gate's cap block must not read the count through the fail-open gc_variable_session_count"
_failopen="$(printf '%s\n' "$BLOCK" | grep -c '\$(gc_variable_session_count)')"
[ "$_failopen" = "0" ] && ok "D1: the cap block does not call the fail-open \$(gc_variable_session_count)" \
  || bad "D1: the cap block still reads the global count through the fail-open gc_variable_session_count ($_failopen call site(s))"
_failopen_all="$(grep -c '=\$(gc_variable_session_count)\|="\$(gc_variable_session_count)"' "$GATE")"
[ "$_failopen_all" = "0" ] && ok "D1: no assignment anywhere in the gate reads through it" \
  || bad "D1: $_failopen_all assignment(s) in the gate still read through the fail-open function"

# ── D2: the unreadable branch sits BEFORE the headroom gate / claim ──────────
echo "D2: drift guard — the unreadable branch is positioned before Step 0b-1 (so before the atomic claim)"
_unread_line="$(grep -n 'cannot read the global variable-session count' "$GATE" | sed -n '1p' | cut -d: -f1)"
_headroom_line="$(grep -n 'Step 0b-1 (ga-cw4pm): dynamic-concurrency headroom gate' "$GATE" | sed -n '1p' | cut -d: -f1)"
_claim_line="$(grep -n '^# ── Step 1: Atomic claim' "$GATE" | sed -n '1p' | cut -d: -f1)"
if [ -n "${_unread_line:-}" ] && [ -n "${_headroom_line:-}" ] && [ "$_unread_line" -lt "$_headroom_line" ]; then
  ok "D2: unreadable branch (L$_unread_line) precedes Step 0b-1 (L$_headroom_line)"
else
  bad "D2: unreadable branch missing or not before Step 0b-1 (unread=${_unread_line:-none}, headroom=${_headroom_line:-none})"
fi
if [ -n "${_unread_line:-}" ] && [ -n "${_claim_line:-}" ] && [ "$_unread_line" -lt "$_claim_line" ]; then
  ok "D2: …and precedes 'Step 1: Atomic claim' (L$_claim_line) — no marker is claimed on an unreadable count"
else
  bad "D2: unreadable branch is not before 'Step 1: Atomic claim' (unread=${_unread_line:-none}, claim=${_claim_line:-none}) — a marker could be stranded"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
