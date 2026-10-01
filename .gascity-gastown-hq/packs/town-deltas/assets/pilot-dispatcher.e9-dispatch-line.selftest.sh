#!/usr/bin/env bash
# pilot-dispatcher.e9-dispatch-line.selftest.sh — ga-798p6w (E9, the planner A/B): the Pilot's side of the experiment.
#
# The Pilot adds ONE line to the builder's dispatch comment, and only for a bead in the plan arm. The line is what makes the
# experiment reach a builder at all, and it is added in the one script every dispatch goes through — so the promises are about what
# it must never do to a dispatch that is not part of the experiment:
#   1. INERT BY DEFAULT — no conf, a kill switch, or a malformed conf => NO line, NO roster row. The comment is what it was.
#   2. THREE STATES, NEVER TWO — "control arm", "could not tell" and "plan arm" never print the same thing. Only an arm that was
#      assigned (exit 0) AND printed exactly `on` produces the line: a failing/garbled/timed-out `assign` must not read as "on" (it
#      would point a builder at a paid Opus run for a bead that is not in the arm).
#   3. THE CONTROL ARM HAS A DENOMINATOR — the control arm prints nothing, but the roster still records who was assigned.
#   4. NO bd / gc CALL from the hook (the roster is a jq append) and a bounded wait (`timeout 10`) — the Pilot's sweep must not be able
#      to hang on the experiment.
#   5. THE CALL SITE — the block that appends the line is inside dispatch_one, skipped for the beads-repo branch, and leaves the
#      comment byte-identical when the hook says nothing.
# The last section is MUTATION CONTROLS: promise 2 is broken on purpose in a copy of the function and this selftest must notice.
#
# Runs against EXTRACTED function bodies (the same sed idiom as pilot-dispatcher.empty-description-label.selftest.sh) with the real
# e9-arms.sh as the arm rule and a PATH on which the real gc/bd do not exist (selftest-sandbox-path.lib.sh). Safe on a live host:
# E9_STATE_DIR points at a scratch dir, nothing here touches a real store, bead or the live roster.
# Run with:   bash pilot-dispatcher.e9-dispatch-line.selftest.sh        Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
ARMS="$SELF_DIR/e9-arms.sh"
PLAN="$SELF_DIR/e9-plan.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -r "$ARMS" ] && [ -r "$PLAN" ] || { echo "FATAL: e9-arms.sh / e9-plan.sh not readable in $SELF_DIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing" >&2; exit 0; }

# Without the function there is nothing to test: on a base that predates ga-798p6w this is the honest reason to refuse to start.
FN="$(sed -n '/^_e9_dispatch_line() {/,/^}$/p' "$DISPATCHER")"
if [ -z "$FN" ]; then
  echo "FATAL: _e9_dispatch_line() not found in $DISPATCHER — has ga-798p6w landed?" >&2
  exit 2
fi
BLOCK="$(awk '/^    # ga-798p6w \(E9\): empty unless/ { f = 1 } f && /^    bd -C "\$STORY_BEAD_CITY" comment "\$STORY_ID" "\$DISPATCH_COMMENT"/ { exit } f { print }' "$DISPATCHER")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: the E9 block in dispatch_one() was not found in $DISPATCHER" >&2
  exit 2
fi

REAL_TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$REAL_TIMEOUT" ] || { echo "FATAL: no timeout/gtimeout on this host — the hook's 10s bound cannot be exercised" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-e9-dispatch-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
# macOS TMPDIR ends in "/", so the mktemp path carries a "//". The function under test resolves its siblings with `cd … && pwd`,
# which collapses it — compare against the same normal form or the path assertion fails for a reason that is not the hook's.
WORK="$(cd "$WORK" && pwd)"

SHIMBIN="$WORK/bin"; mkdir -p "$SHIMBIN"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK" jq || exit 2   # the arm rule needs jq; bd/gc are the recording shims below, never the real ones
CALLLOG="$WORK/town-calls.log"; : > "$CALLLOG"
TLOG="$WORK/timeout-calls.log"; : > "$TLOG"

for t in bd gc; do
  cat > "$SHIMBIN/$t" <<SHIM
#!/bin/bash
echo "$t \$*" >> "$CALLLOG"
echo '[]'
SHIM
  chmod +x "$SHIMBIN/$t"
done
# timeout: records its arguments, then either "expires" at once (SHIM_TIMEOUT_EXPIRE=1, rc 124 like the real one) or runs the real one.
cat > "$SHIMBIN/timeout" <<SHIM
#!/bin/bash
echo "\$*" >> "$TLOG"
[ -n "\${SHIM_TIMEOUT_EXPIRE:-}" ] && exit 124
exec "$REAL_TIMEOUT" "\$@"
SHIM
chmod +x "$SHIMBIN/timeout"

# ── fixtures: two bead ids whose arms are decided by the REAL rule (never invented here) ──
CONF=$'planner_pct=50\nsalt=e9a\n'
PROBE="$WORK/probe"; mkdir -p "$PROBE"; printf '%s' "$CONF" > "$PROBE/e9-ab.conf"
ID_ON=""; ID_OFF=""
i=0
while { [ -z "$ID_ON" ] || [ -z "$ID_OFF" ]; } && [ "$i" -lt 60 ]; do
  i=$((i+1)); cand="ga-t$i"
  a="$(PATH="$SANDBOX_PATH" E9_STATE_DIR="$PROBE" bash "$ARMS" arm planner "$cand" 2>/dev/null)"
  [ "$a" = on ]  && [ -z "$ID_ON" ]  && ID_ON="$cand"
  [ "$a" = off ] && [ -z "$ID_OFF" ] && ID_OFF="$cand"
done
if [ -z "$ID_ON" ] || [ -z "$ID_OFF" ]; then
  echo "FATAL: could not find one bead id per arm with the real rule (on='$ID_ON' off='$ID_OFF')" >&2
  exit 2
fi
echo "fixtures: plan-arm id=$ID_ON, control-arm id=$ID_OFF (from the real e9-arms.sh rule, planner_pct=50 salt=e9a)"

# ── harness: D=<scenario dir> with the function text in harness.sh, siblings next to it, a scratch state dir ──
N=0
newdir() {   # sets D, SD; copies the real siblings unless told otherwise (callers overwrite/remove after)
  N=$((N+1)); D="$WORK/d$N"; SD="$D/state"; mkdir -p "$D" "$SD"
  cp "$ARMS" "$D/e9-arms.sh"; cp "$PLAN" "$D/e9-plan.sh"
  unset SHIM_TIMEOUT_EXPIRE
}
conf_on()  { printf '%s' "$CONF" > "$SD/e9-ab.conf"; }
# run <function-text> <bead> <store> → OUT (stdout), RC, WARNS (what the hook logged through warn(); the real one is the dispatcher's)
run() {
  { printf '%s\n' 'warn() { printf "%s\n" "$*" >> "$WARNLOG"; }'; printf '%s\n' "$1"; printf '%s\n' '_e9_dispatch_line "$1" "$2"'; } > "$D/harness.sh"
  : > "$D/warn.log"
  OUT="$(PATH="$SANDBOX_PATH" E9_STATE_DIR="$SD" WARNLOG="$D/warn.log" bash "$D/harness.sh" "$2" "$3" 2>/dev/null)"; RC=$?
  WARNS="$(cat "$D/warn.log" 2>/dev/null)"
}
roster_rows() { if [ -r "$SD/e9-roster.jsonl" ]; then wc -l < "$SD/e9-roster.jsonl" | tr -d ' '; else echo 0; fi; }

echo "== 1. inert by default =="
newdir; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ -z "$WARNS" ] && ok "no conf → no line, exit 0, nothing logged (an inactive experiment is not a failure)" || bad "no conf: out='$OUT' rc=$RC warns='$WARNS'"
[ "$(roster_rows)" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "no conf → no roster row (an absent experiment records nothing)" || bad "no conf wrote a roster"

newdir; conf_on; : > "$SD/no-e9-ab"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "kill switch beats an active conf → no line, no roster row" || bad "kill switch: out='$OUT' rc=$RC rows=$(roster_rows)"
[ -z "$WARNS" ] && ok "kill switch → nothing logged (switching the experiment off on purpose is not a failure)" || bad "kill switch logged: '$WARNS'"

newdir; printf 'planner_pct=abc\n' > "$SD/e9-ab.conf"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "malformed conf → no line (a typo'd conf is not an experiment at some default)" || bad "malformed conf: out='$OUT' rc=$RC"
# ...but it must not be SILENT: an invalid conf used to answer exactly like "no conf" (exit 0, empty), so a typo at turn-on ran the experiment
# at 0% with no roster row and no log line (gate ga-shag3i, blocking issue 2). Absent/killed stay silent above; invalid says so, by exit code.
case "$WARNS" in *"$ID_ON"*"exited 6"*"INVALID"*"NOT running"*) ok "malformed conf → LOGGED: names the bead, exit 6, says the config is invalid and the experiment is not running" ;; *) bad "malformed conf not logged (silent fail-open): '$WARNS'" ;; esac
for bc in 'planner_pct=5O' 'plannr_pct=50' 'planner_pct=101' 'salt='; do
  newdir; printf '%s\n' "$bc" > "$SD/e9-ab.conf"; run "$FN" "$ID_ON" /store
  [ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && case "$WARNS" in *"exited 6"*) true ;; *) false ;; esac \
    && ok "invalid conf '$bc' → no line, no roster row, logged (exit 6)" || bad "invalid conf '$bc': out='$OUT' rc=$RC warns='$WARNS'"
done

echo "== 2/3. the two arms =="
newdir; conf_on; run "$FN" "$ID_OFF" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "control arm → no line (today's flow, byte for byte)" || bad "control arm: out='$OUT' rc=$RC"
row="$(jq -c 'select(.event=="assign")' "$SD/e9-roster.jsonl" 2>/dev/null | head -1)"
[ "$(roster_rows)" = 1 ] && [ "$(printf '%s' "$row" | jq -r .planner_arm)" = off ] && [ "$(printf '%s' "$row" | jq -r .bead)" = "$ID_OFF" ] \
  && ok "control arm is still RECORDED (assign/off) — a control with no denominator is not a control" || bad "control arm row: '$row' rows=$(roster_rows)"
[ "$(printf '%s' "$row" | jq -r .stage)" = pilot-dispatch ] && ok "the row says the Pilot assigned it (stage=pilot-dispatch)" || bad "stage: '$row'"

newdir; conf_on; run "$FN" "$ID_ON" /store
nl="$(printf '%s' "$OUT" | wc -l | tr -d ' ')"
[ -n "$OUT" ] && [ "$RC" = 0 ] && [ "$nl" = 0 ] && ok "plan arm → exactly one line (no embedded newline)" || bad "plan arm: lines=$nl rc=$RC out='$OUT'"
[ -z "$WARNS" ] && ok "the normal path logs nothing (a warning is for a FAILED assign only)" || bad "plan arm logged: '$WARNS'"
case "$OUT" in *"bash $D/e9-plan.sh run $ID_ON --store /store"*) ok "the line carries the runnable command: sibling e9-plan.sh, this bead, this store" ;; *) bad "command missing from: $OUT" ;; esac
case "$OUT" in *ga-798p6w*) ok "the line names the experiment (ga-798p6w)" ;; *) bad "experiment id missing: $OUT" ;; esac
case "$OUT" in *"Exit 3"*"build as you always do"*) ok "the line says exit 3 (no plan) is not a verdict on the bead" ;; *) bad "exit-3 guidance missing: $OUT" ;; esac
row="$(jq -c 'select(.event=="assign")' "$SD/e9-roster.jsonl" 2>/dev/null | head -1)"
[ "$(printf '%s' "$row" | jq -r .planner_arm)" = on ] && [ "$(printf '%s' "$row" | jq -r .stage)" = pilot-dispatch ] && ok "plan arm recorded (assign/on, stage=pilot-dispatch)" || bad "plan arm row: '$row'"

first="$OUT"; run "$FN" "$ID_ON" /store
[ "$OUT" = "$first" ] && [ "$(roster_rows)" = 1 ] && ok "a re-dispatch of the same bead: same line, still ONE roster row (a bead keeps its arm)" || bad "re-dispatch: rows=$(roster_rows) same=$([ "$OUT" = "$first" ] && echo y || echo n)"

echo "== 2. could-not-tell never reads as 'on' =="
newdir; conf_on; rm -f "$D/e9-plan.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "e9-plan.sh missing → no line, and nothing assigned (no builder could carry the arm)" || bad "plan missing: out='$OUT' rows=$(roster_rows)"

newdir; conf_on; rm -f "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "e9-arms.sh missing → no line" || bad "arms missing: out='$OUT' rc=$RC"

newdir; conf_on; printf '#!/bin/bash\necho on\nexit 1\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "assign prints 'on' but FAILS (exit 1) → no line (a failed write is not an assignment)" || bad "failing assign: out='$OUT' rc=$RC"

# A failed assign was SILENT: the hook drops assign's stderr (its stdout is the comment line), so a roster that stopped being writable
# switched the experiment off for every bead with nobody the wiser (gate ga-uu4y5m, non-blocking finding). The exit code is the signal.
newdir; conf_on; printf '#!/bin/bash\necho "e9: WARN: assignment for x NOT recorded" >&2\nexit 5\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "assign exits 5 (arm decided, NOT recorded) → no line, the sweep carries on" || bad "exit 5: out='$OUT' rc=$RC"
case "$WARNS" in *"$ID_ON"*"exited 5"*"not recorded"*) ok "and it is LOGGED, naming the bead and the exit code" ;; *) bad "exit 5 not logged: '$WARNS'" ;; esac
newdir; conf_on; printf '#!/bin/bash\nexit 3\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && case "$WARNS" in *"$ID_ON"*"exited 3"*) true ;; *) false ;; esac && ok "assign exits 3 (no arm could be determined) → no line, logged" || bad "exit 3: out='$OUT' warns='$WARNS'"
if [ "$(id -u)" != 0 ]; then
  newdir; conf_on; : > "$SD/e9-roster.jsonl"; chmod 444 "$SD/e9-roster.jsonl"; run "$FN" "$ID_ON" /store; chmod 600 "$SD/e9-roster.jsonl"
  [ -z "$OUT" ] && [ "$RC" = 0 ] && case "$WARNS" in *"$ID_ON"*"exited 5"*) true ;; *) false ;; esac \
    && ok "the REAL assign on a roster that cannot be written: no line (a bead with no roster row is not sent to the planner) and the failure is logged" || bad "real unwritable roster: out='$OUT' rc=$RC warns='$WARNS'"
fi

newdir; conf_on; printf '#!/bin/bash\necho maybe\nexit 0\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && ok "assign prints something that is not on|off → no line" || bad "garbled assign: out='$OUT'"

newdir; conf_on; printf '#!/bin/bash\nexit 0\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && ok "assign prints NOTHING (exit 0) → no line (empty is not 'on')" || bad "empty assign: out='$OUT'"

newdir; conf_on; printf '#!/bin/bash\necho "on off"\nexit 0\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && ok "assign prints 'on off' → no line (only the exact word 'on' counts)" || bad "two-word assign: out='$OUT'"

newdir; conf_on; : > "$TLOG"; SHIM_TIMEOUT_EXPIRE=1 run "$FN" "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "assign TIMES OUT (rc 124) → no line, the sweep carries on" || bad "timeout: out='$OUT' rc=$RC"
case "$(head -1 "$TLOG")" in "10 bash "*) ok "the wait is bounded: \`timeout 10 bash …\`" ;; *) bad "timeout call was: '$(head -1 "$TLOG")'" ;; esac

newdir; conf_on; run "$FN" "bad id" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "a bead id with whitespace → no arm, no line, no row" || bad "bad id: out='$OUT' rows=$(roster_rows)"

echo "== 4. the hook never reaches into the town =="
[ ! -s "$CALLLOG" ] && ok "zero bd / gc calls across every scenario above" || bad "town calls were made: $(head -3 "$CALLLOG" | tr '\n' ';')"

echo "== 5. the call site in dispatch_one =="
enc="$(awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { fn = $1 } /_e9_dispatch_line "\$STORY_ID" "\$STORY_BEAD_CITY"/ { print fn }' "$DISPATCHER")"
[ "$enc" = "dispatch_one()" ] && ok "the only call site is inside dispatch_one() ('local' there is legal)" || bad "call site(s) in: '$enc'"
ncalls="$(grep -c '_e9_dispatch_line "\$STORY_ID"' "$DISPATCHER")"
[ "$ncalls" = 1 ] && ok "exactly one call site" || bad "$ncalls call sites"

blk() {   # blk <IS_BEADS_REPO_FIX> <hook-output> → DISPATCH_COMMENT after the block ; BLK_CALLS = times the hook ran
  : > "$WORK/blk-calls"
  ( eval "_e9_dispatch_line() { echo called >> \"$WORK/blk-calls\"; printf '%s' \"\$STUB_LINE\"; }"
    eval "f() { local IS_BEADS_REPO_FIX=\"\$1\" STORY_ID=ga-x STORY_BEAD_CITY=/city DISPATCH_COMMENT=BASE
$BLOCK
      printf '%s' \"\$DISPATCH_COMMENT\"; }"
    STUB_LINE="$2" f "$1" )
  BLK_CALLS="$(wc -l < "$WORK/blk-calls" | tr -d ' ')"
}
BLK_OUT="$(blk "" "")"; blk "" "" >/dev/null; calls_empty="$BLK_CALLS"
[ "$BLK_OUT" = "BASE" ] && ok "hook says nothing → the dispatch comment is byte-identical" || bad "comment changed by an empty hook: '$BLK_OUT'"
BLK_OUT="$(blk "" "THE-LINE")"
[ "$BLK_OUT" = "$(printf 'BASE\nTHE-LINE')" ] && ok "hook says a line → it is appended on its own line, nothing else moves" || bad "appended comment: '$BLK_OUT'"
BLK_OUT="$(blk "1" "THE-LINE")"; blk "1" "THE-LINE" >/dev/null
[ "$BLK_OUT" = "BASE" ] && [ "$BLK_CALLS" = 0 ] && ok "beads-repo branch (IS_BEADS_REPO_FIX set) → the hook is not even asked (an upstream PR has no builder doctrine for a plan)" || bad "beads-repo branch: out='$BLK_OUT' calls=$BLK_CALLS"
[ "$calls_empty" = 1 ] && ok "normal branch → the hook is asked exactly once per dispatch" || bad "hook calls on a normal dispatch: $calls_empty"
l_block="$(grep -n '^    # ga-798p6w (E9): empty unless' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_post="$(grep -n '^    bd -C "\$STORY_BEAD_CITY" comment "\$STORY_ID" "\$DISPATCH_COMMENT"' "$DISPATCHER" | head -1 | cut -d: -f1)"
[ -n "$l_block" ] && [ -n "$l_post" ] && [ "$l_block" -lt "$l_post" ] && ok "the block runs BEFORE the comment is posted (line $l_block < $l_post)" || bad "order: block=$l_block post=$l_post"

echo "== MUTATION CONTROLS: break the promises on purpose; this selftest must notice =="
mutant_emits() {   # <name> <function-text> <arms-script-body> → 0 iff the mutated function emits a line for a failing/garbled assign
  newdir; conf_on; printf '%s' "$3" > "$D/e9-arms.sh"; run "$2" "$ID_ON" /store
  [ -n "$OUT" ]
}
M1="$(printf '%s\n' "$FN" | grep -v '^  \[ "\$_e9_arm" = "on" \] || return 0$')"
[ "$M1" != "$FN" ] || { bad "mutation 1 did not change the function — the control is void (the 'only exact on counts' line moved?)"; }
mutant_emits m1 "$M1" $'#!/bin/bash\necho maybe\nexit 0\n' && ok "mutation 1 (drop the exact-'on' check) is CAUGHT: a garbled arm now yields a line" || bad "mutation 1 NOT caught — the 'garbled arm' scenario cannot tell"
M2="$(printf '%s\n' "$FN" | sed 's/\[ "\$_e9_rc" -ne 0 \]/false/')"
[ "$M2" != "$FN" ] || { bad "mutation 2 did not change the function — the control is void (the exit-code test moved?)"; }
mutant_emits m2 "$M2" $'#!/bin/bash\necho on\nexit 1\n' && ok "mutation 2 (ignore the assign exit code) is CAUGHT: a failed assign now yields a line" || bad "mutation 2 NOT caught — the 'failing assign' scenario cannot tell"
M4="$(printf '%s\n' "$FN" | grep -v '^    warn "E9: no plan hint')"
[ "$M4" != "$FN" ] || { bad "mutation 4 did not change the function — the control is void (the warn line moved?)"; }
newdir; conf_on; printf '#!/bin/bash\nexit 5\n' > "$D/e9-arms.sh"; run "$M4" "$ID_ON" /store
[ -z "$WARNS" ] && [ -z "$OUT" ] && ok "mutation 4 (drop the log line) is CAUGHT: a failed assign leaves no trace, which the exit-5 scenario above detects" || bad "mutation 4 NOT caught — warns='$WARNS'"
newdir; conf_on; printf '#!/bin/bash\nexit 5\n' > "$D/e9-arms.sh"; run "$FN" "$ID_ON" /store
[ -n "$WARNS" ] && ok "(control for mutation 4: the unmutated hook does log that same failure)" || bad "the unmutated hook logged nothing for exit 5"
M3="$(printf '%s\n' "$FN" | sed 's/timeout 10 bash/bash/')"
[ "$M3" != "$FN" ] || { bad "mutation 3 did not change the function — the control is void"; }
newdir; conf_on; : > "$TLOG"; run "$M3" "$ID_ON" /store
case "$(head -1 "$TLOG" 2>/dev/null)" in "10 bash "*) bad "mutation 3 NOT caught — still bounded?" ;; *) ok "mutation 3 (drop the timeout) is CAUGHT: no bounded call is recorded" ;; esac

echo
echo "pilot-dispatcher.e9-dispatch-line.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
