#!/usr/bin/env bash
# pilot-dispatcher.e12-doctrine-block.selftest.sh — ga-4q2zo5 (E12 of the P0 ga-ufskhy): the Pilot's side of the write-time-doctrine A/B.
#
# The Pilot appends ONE block to the DOCTRINE section of the builder's dispatch message, and only for a bead in the treated arm. That
# section is built once in dispatch_one() and goes into every builder prompt (pool sling, session submit, nudge to a crew), so this is
# the single point where the experiment reaches pools and crews alike. The promises are about what it must never do to a dispatch that is
# not part of the experiment:
#   1. INERT BY DEFAULT — no conf => the DOCTRINE section is byte-identical to today's, no roster row, nothing logged.
#   2. A CONF THAT CANNOT BE READ => nobody is treated AND it is logged (exit 6, naming the bead). "Unreadable" must never look like
#      "no conf": a typo at turn-on would run the experiment at 0% with no roster row and no trace (the ga-shag3i finding on E9).
#   3. THREE STATES, NEVER TWO — control arm, "could not tell" and treated never print the same thing. Only an exit-0 answer that starts
#      with the block's own header is appended: a failing / garbled / timed-out / missing script must not read as "treated".
#   4. THE CONTROL ARM HAS A DENOMINATOR — it gets no text, but the roster still records it. A DRY RUN records nothing (looking at a
#      bead must not enrol it) but shows the block, so the dry run reports what would be sent.
#   5. NO bd / gc CALL from the hook (the roster is a jq append) and a bounded wait (`timeout 10`) — the Pilot's sweep must not be able
#      to hang on the experiment.
#   6. THE CALL SITE — one, inside dispatch_one, after the beads-repo override (an upstream PR has no gate, so no doctrine A/B) and
#      before the prompt is built; it leaves DOCTRINE_BLOCK byte-identical when the hook says nothing.
# The last section is MUTATION CONTROLS: promises 2-6 are broken on purpose in a copy of the function (or of the call site) and this
# selftest must notice. (Promise 5's "no bd / gc call" half is checked by the call log, not by a mutation; its timeout half is mutated.)
#
# Runs against EXTRACTED function bodies (the same sed idiom as pilot-dispatcher.e9-dispatch-line.selftest.sh) with the real
# e12-arms.sh as the arm rule and a PATH on which the real gc/bd do not exist (selftest-sandbox-path.lib.sh). Safe on a live host:
# E12_STATE_DIR points at a scratch dir; nothing here touches a real store, bead or the live roster.
# Run with:   bash pilot-dispatcher.e12-doctrine-block.selftest.sh        Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
ARMS="$SELF_DIR/e12-arms.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -r "$ARMS" ] || { echo "FATAL: e12-arms.sh not readable in $SELF_DIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing" >&2; exit 0; }

# Without the function there is nothing to test: on a base that predates ga-4q2zo5 this is the honest reason to refuse to start.
FN="$(sed -n '/^_e12_doctrine_block() {/,/^}$/p' "$DISPATCHER")"
if [ -z "$FN" ]; then
  echo "FATAL: _e12_doctrine_block() not found in $DISPATCHER — has ga-4q2zo5 landed?" >&2
  exit 2
fi
# the call site: from its marker comment to the `fi` that closes it (the only 2-space-indented `fi` after the marker)
BLOCK="$(awk '/^  # ga-4q2zo5 \(E12\): / { f = 1 } f { print } f && /^  fi$/ { exit }' "$DISPATCHER")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: the E12 block in dispatch_one() was not found in $DISPATCHER" >&2
  exit 2
fi

REAL_TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$REAL_TIMEOUT" ] || { echo "FATAL: no timeout/gtimeout on this host — the hook's 10s bound cannot be exercised" >&2; exit 2; }

# No scratch dir is a hard stop, decided BEFORE the cleanup trap exists. The trap ends in `rm -rf "$WORK"`: with an empty WORK, the
# `cd "$WORK" && pwd` below used to turn it into the CURRENT directory under the macOS system bash (3.2: `cd ""` succeeds and stays put),
# and the trap then deleted the directory the selftest was started from — while the run still printed PASS. "mktemp said yes" and
# "it printed a usable absolute path" are two separate answers, so both are checked.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-e12-selftest.XXXXXX")" || { echo "FATAL: cannot create a scratch directory under ${TMPDIR:-/tmp} — nothing was run" >&2; exit 2; }
case "$WORK" in /?*) ;; *) echo "FATAL: mktemp printed no usable scratch path ('$WORK') — nothing was run" >&2; exit 2 ;; esac
# A selftest that dies half-way must not exit 0 (ga-f31s7p): reaching the last line is part of passing.
REACHED_END=0
cleanup() { local rc=$?; chmod -R u+rw "$WORK" 2>/dev/null; rm -rf "$WORK"; if [ "$REACHED_END" != 1 ] && [ "$rc" = 0 ]; then echo "FAIL: selftest aborted before its last line" >&2; exit 1; fi; }
trap cleanup EXIT
# macOS TMPDIR ends in "/", so the mktemp path carries a "//". The function under test resolves its siblings with `cd … && pwd`,
# which collapses it — compare against the same normal form or a path assertion fails for a reason that is not the hook's. If the
# normalisation itself cannot be read, stop: WORK keeps the mktemp path, which the trap removes.
_WORK_NORM="$(cd "$WORK" && pwd)" && [ -n "$_WORK_NORM" ] || { echo "FATAL: cannot enter the scratch directory $WORK — nothing was run" >&2; exit 2; }
WORK="$_WORK_NORM"

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
PROBE="$WORK/probe"; mkdir -p "$PROBE"; printf 'treated_pct=50\n' > "$PROBE/e12-ab.conf"
ID_T=""; ID_C=""
i=0
while { [ -z "$ID_T" ] || [ -z "$ID_C" ]; } && [ "$i" -lt 60 ]; do
  i=$((i+1)); cand="ga-t$i"
  a="$(PATH="$SANDBOX_PATH" E12_STATE_DIR="$PROBE" bash "$ARMS" arm "$cand" 2>/dev/null)"
  [ "$a" = treated ] && [ -z "$ID_T" ] && ID_T="$cand"
  [ "$a" = control ] && [ -z "$ID_C" ] && ID_C="$cand"
done
if [ -z "$ID_T" ] || [ -z "$ID_C" ]; then
  echo "FATAL: could not find one bead id per arm with the real rule (treated='$ID_T' control='$ID_C')" >&2
  exit 2
fi
echo "fixtures: treated id=$ID_T, control id=$ID_C (from the real e12-arms.sh rule, treated_pct=50)"
REAL_BLOCK="$(PATH="$SANDBOX_PATH" E12_STATE_DIR="$PROBE" bash "$ARMS" block "$ID_T" /store --no-record 2>/dev/null)"
[ -n "$REAL_BLOCK" ] || { echo "FATAL: the real e12-arms.sh printed no block for the treated fixture" >&2; exit 2; }

# ── harness: D=<scenario dir> with the function text in harness.sh, the sibling next to it, a scratch state dir ──
N=0
newdir() {   # sets D, SD; copies the real sibling unless told otherwise (callers overwrite/remove after)
  N=$((N+1)); D="$WORK/d$N"; SD="$D/state"; mkdir -p "$D" "$SD"
  cp "$ARMS" "$D/e12-arms.sh"
  unset SHIM_TIMEOUT_EXPIRE
}
conf_on()  { printf 'treated_pct=50\n' > "$SD/e12-ab.conf"; }
# run <function-text> <bead> <store> → OUT (stdout), RC, WARNS (what the hook logged through warn(); the real one is the dispatcher's)
# DRY_RUN is passed through from the caller's environment, as the Pilot's own variable is.
run() {
  { printf '%s\n' 'warn() { printf "%s\n" "$*" >> "$WARNLOG"; }'; printf '%s\n' "$1"; printf '%s\n' '_e12_doctrine_block "$1" "$2"'; } > "$D/harness.sh"
  : > "$D/warn.log"
  OUT="$(PATH="$SANDBOX_PATH" E12_STATE_DIR="$SD" WARNLOG="$D/warn.log" bash "$D/harness.sh" "$2" "$3" 2>/dev/null)"; RC=$?
  WARNS="$(cat "$D/warn.log" 2>/dev/null)"
}
roster_rows() { if [ -r "$SD/e12-roster.jsonl" ]; then wc -l < "$SD/e12-roster.jsonl" | tr -d ' '; else echo 0; fi; }

echo "== 1. inert by default =="
newdir; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ -z "$WARNS" ] && ok "no conf → nothing appended, exit 0, nothing logged (an experiment that is off is not a failure)" || bad "no conf: out='$OUT' rc=$RC warns='$WARNS'"
[ ! -e "$SD/e12-roster.jsonl" ] && ok "no conf → no roster row (an absent experiment records nothing)" || bad "no conf wrote a roster"

echo "== 2. a conf that cannot be read: nobody is treated, and it is LOGGED =="
for bc in 'treated_pct=abc' 'treated_pcts=50' 'treated_pct=0' 'treated_pct=101' 'salt=x' ''; do
  newdir; printf '%s\n' "$bc" > "$SD/e12-ab.conf"; [ -z "$bc" ] && : > "$SD/e12-ab.conf"
  run "$FN" "$ID_T" /store
  [ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e12-roster.jsonl" ] && case "$WARNS" in *"$ID_T"*"exited 6"*"INVALID"*"NOT running"*) true ;; *) false ;; esac \
    && ok "invalid conf '${bc:-<empty file>}' → nothing appended, no roster row, LOGGED (names the bead, exit 6, INVALID, NOT running)" || bad "invalid conf '${bc:-<empty>}': out='$OUT' rc=$RC warns='$WARNS'"
done
if [ "$(id -u)" != 0 ]; then
  newdir; conf_on; chmod 000 "$SD/e12-ab.conf"; run "$FN" "$ID_T" /store; chmod 600 "$SD/e12-ab.conf"
  [ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e12-roster.jsonl" ] && case "$WARNS" in *"$ID_T"*"exited 6"*) true ;; *) false ;; esac \
    && ok "unreadable conf → nothing appended, no roster row, logged (exit 6)" || bad "unreadable conf: out='$OUT' rc=$RC warns='$WARNS'"
fi

echo "== 3. the two arms =="
newdir; conf_on; run "$FN" "$ID_C" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ -z "$WARNS" ] && ok "control arm → nothing appended (today's dispatch, byte for byte), nothing logged" || bad "control arm: out='$OUT' rc=$RC warns='$WARNS'"
row="$(jq -c 'select(.event=="assign")' "$SD/e12-roster.jsonl" 2>/dev/null | head -1)"
[ "$(roster_rows)" = 1 ] && [ "$(printf '%s' "$row" | jq -r .arm)" = control ] && [ "$(printf '%s' "$row" | jq -r .bead)" = "$ID_C" ] \
  && ok "control arm is still RECORDED (assign/control) — a control with no denominator is not a control" || bad "control arm row: '$row' rows=$(roster_rows)"
[ "$(printf '%s' "$row" | jq -r .stage)" = pilot-dispatch ] && ok "the row says the Pilot assigned it (stage=pilot-dispatch)" || bad "stage: '$row'"

newdir; conf_on; run "$FN" "$ID_T" /store
[ "$RC" = 0 ] && [ -z "$WARNS" ] && [ "$(printf '%s\n' "$OUT" | head -1)" = "$(printf '%s\n' "$REAL_BLOCK" | head -1)" ] && ok "treated arm → the block is printed (header is the real block's), nothing logged" || bad "treated arm: rc=$RC warns='$WARNS' out='${OUT:0:80}'"
[ "$OUT" = "$REAL_BLOCK" ] && ok "…and it is exactly the text e12-arms.sh holds — the hook adds and trims nothing" || bad "treated text differs from the arms script's own"
row="$(jq -c 'select(.event=="assign")' "$SD/e12-roster.jsonl" 2>/dev/null | head -1)"
[ "$(printf '%s' "$row" | jq -r .arm)" = treated ] && [ "$(printf '%s' "$row" | jq -r .stage)" = pilot-dispatch ] && ok "treated arm recorded (assign/treated, stage=pilot-dispatch)" || bad "treated row: '$row'"
first="$OUT"; run "$FN" "$ID_T" /store
[ "$OUT" = "$first" ] && [ "$(roster_rows)" = 1 ] && ok "a re-dispatch of the same bead: same block, still ONE roster row (a bead keeps its arm)" || bad "re-dispatch: rows=$(roster_rows)"

echo "== 4. a dry run shows the block but enrols nobody =="
newdir; conf_on; DRY_RUN=1 run "$FN" "$ID_T" /store
[ "$OUT" = "$REAL_BLOCK" ] && ok "DRY_RUN=1, treated bead → the block is shown (the dry run reports what would be sent)" || bad "dry run treated: out='${OUT:0:60}'"
[ ! -e "$SD/e12-roster.jsonl" ] && ok "DRY_RUN=1 → no roster row (looking at a bead must not enrol it)" || bad "dry run wrote a roster"
newdir; conf_on; DRY_RUN=1 run "$FN" "$ID_C" /store
[ -z "$OUT" ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "DRY_RUN=1, control bead → nothing, no row" || bad "dry run control: out='$OUT'"
newdir; conf_on; DRY_RUN=0 run "$FN" "$ID_T" /store
[ "$(roster_rows)" = 1 ] && ok "DRY_RUN=0 → the roster IS written (only an explicit 1 means dry)" || bad "DRY_RUN=0 rows=$(roster_rows)"

echo "== 3b. could-not-tell never reads as 'treated' =="
newdir; conf_on; rm -f "$D/e12-arms.sh"; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "e12-arms.sh missing → nothing appended and nothing assigned" || bad "arms missing: out='$OUT' rc=$RC"
case "$WARNS" in *"$ID_T"*"e12-arms.sh"*"not readable"*) ok "…and it is LOGGED (a deploy that lost the script is not silence)" ;; *) bad "missing script not logged: '$WARNS'" ;; esac

# the dispatcher cannot find its own directory (here: $0 points into a directory that does not exist) → "could not tell", logged, not silent
newdir; conf_on; : > "$D/warn.log"
OUT="$(PATH="$SANDBOX_PATH" E12_STATE_DIR="$SD" WARNLOG="$D/warn.log" bash -c 'warn() { printf "%s\n" "$*" >> "$WARNLOG"; }; '"$FN"'; _e12_doctrine_block "$1" "$2"' /nonexistent-e12-dir/pilot-dispatcher.sh "$ID_T" /store 2>/dev/null)"; RC=$?
WARNS="$(cat "$D/warn.log" 2>/dev/null)"
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e12-roster.jsonl" ] && case "$WARNS" in *"$ID_T"*"could not resolve"*"NOT running"*) true ;; *) false ;; esac \
  && ok "dispatcher's own directory unresolvable → nothing appended, no row, and it is LOGGED (not a silent return)" || bad "unresolvable dir: out='$OUT' rc=$RC warns='$WARNS'"

newdir; conf_on; printf '#!/bin/bash\necho "## Write-time doctrine — experiment E12 (ga-4q2zo5)"\necho text\nexit 1\n' > "$D/e12-arms.sh"; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "script prints a real-looking block but FAILS (exit 1) → nothing appended (a failed write is not an assignment)" || bad "failing script: out='$OUT' rc=$RC"
# the hook drops the script's stderr (its stdout is the text), so the exit code is the only signal a failed assignment gives
newdir; conf_on; printf '#!/bin/bash\necho "e12: WARN: NOT recorded" >&2\nexit 5\n' > "$D/e12-arms.sh"; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "exit 5 (arm decided, NOT recorded) → nothing appended, the sweep carries on" || bad "exit 5: out='$OUT' rc=$RC"
case "$WARNS" in *"$ID_T"*"exited 5"*"not recorded"*) ok "…and it is LOGGED, naming the bead and the exit code" ;; *) bad "exit 5 not logged: '$WARNS'" ;; esac
newdir; conf_on; printf '#!/bin/bash\nexit 3\n' > "$D/e12-arms.sh"; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && case "$WARNS" in *"$ID_T"*"exited 3"*) true ;; *) false ;; esac && ok "exit 3 (no arm could be determined) → nothing appended, logged" || bad "exit 3: out='$OUT' warns='$WARNS'"
if [ "$(id -u)" != 0 ]; then
  newdir; conf_on; : > "$SD/e12-roster.jsonl"; chmod 444 "$SD/e12-roster.jsonl"; run "$FN" "$ID_T" /store; chmod 600 "$SD/e12-roster.jsonl"
  [ -z "$OUT" ] && [ "$RC" = 0 ] && case "$WARNS" in *"$ID_T"*"exited 5"*) true ;; *) false ;; esac \
    && ok "the REAL script on a roster that cannot be written: no block (a treated bead missing from the roster cannot be counted) and it is logged" || bad "real unwritable roster: out='$OUT' rc=$RC warns='$WARNS'"
fi
newdir; conf_on; printf '#!/bin/bash\necho maybe\nexit 0\n' > "$D/e12-arms.sh"; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && ok "script prints something that is not the block (exit 0) → nothing appended" || bad "garbled script: out='$OUT'"
case "$WARNS" in *"$ID_T"*"not the doctrine block"*) ok "…and it is LOGGED (only a text that starts with the block's own header is appended)" ;; *) bad "garbled output not logged: '$WARNS'" ;; esac
newdir; conf_on; printf '#!/bin/bash\nexit 0\n' > "$D/e12-arms.sh"; run "$FN" "$ID_T" /store
[ -z "$OUT" ] && [ -z "$WARNS" ] && ok "script prints NOTHING (exit 0 = control / off) → nothing appended, not an error" || bad "empty script output: out='$OUT' warns='$WARNS'"
newdir; conf_on; : > "$TLOG"; SHIM_TIMEOUT_EXPIRE=1 run "$FN" "$ID_T" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && case "$WARNS" in *"$ID_T"*"exited 124"*) true ;; *) false ;; esac && ok "script TIMES OUT (rc 124) → nothing appended, logged, the sweep carries on" || bad "timeout: out='$OUT' rc=$RC warns='$WARNS'"
newdir; conf_on; : > "$TLOG"; run "$FN" "$ID_T" /store
case "$(head -1 "$TLOG")" in "10 bash "*) ok "the wait is bounded: \`timeout 10 bash …\`" ;; *) bad "timeout call was: '$(head -1 "$TLOG")'" ;; esac
newdir; conf_on; run "$FN" "bad id" /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "a bead id with whitespace → no arm, nothing appended, no row" || bad "bad id: out='$OUT' rows=$(roster_rows)"

echo "== 5. the hook never reaches into the town =="
[ ! -s "$CALLLOG" ] && ok "zero bd / gc calls across every scenario above" || bad "town calls were made: $(head -3 "$CALLLOG" | tr '\n' ';')"

echo "== 6. the call site in dispatch_one =="
enc="$(awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { fn = $1 } /_e12_doctrine_block "\$STORY_ID" "\$STORY_BEAD_CITY"/ { print fn }' "$DISPATCHER")"
[ "$enc" = "dispatch_one()" ] && ok "the only call site is inside dispatch_one() ('local' there is legal)" || bad "call site(s) in: '$enc'"
ncalls="$(grep -c '_e12_doctrine_block "\$STORY_ID"' "$DISPATCHER")"
[ "$ncalls" = 1 ] && ok "exactly one call site" || bad "$ncalls call sites"

blk() {   # blk <IS_BEADS_REPO_FIX> <hook-output> <base> → DOCTRINE_BLOCK after the block ; BLK_CALLS = times the hook ran
  : > "$WORK/blk-calls"
  ( eval "_e12_doctrine_block() { echo called >> \"$WORK/blk-calls\"; printf '%s' \"\$STUB_TEXT\"; }"
    eval "f() { local IS_BEADS_REPO_FIX=\"\$1\" STORY_ID=ga-x STORY_BEAD_CITY=/city DOCTRINE_BLOCK=\"\$2\"
$BLOCK
      printf '%s' \"\$DOCTRINE_BLOCK\"; }"
    STUB_TEXT="$2" f "$1" "$3" )
  BLK_CALLS="$(wc -l < "$WORK/blk-calls" | tr -d ' ')"
}
BASE_F=$'## DOCTRINE — read carefully\n- You are the BUILDER.\n- If /gate-done fails validation (no commits, no branch), fix the issue and retry.'
BASE_B=$'## DOCTRINE — read carefully\n- You are the BUILDER.\n- The autonomous loop: /gate-done → G reviews → merges → ① deploys → bead closed.'
BLK_OUT="$(blk "" "" "$BASE_F")"
[ "$BLK_OUT" = "$BASE_F" ] && ok "hook says nothing → DOCTRINE_BLOCK is byte-identical" || bad "doctrine changed by an empty hook: '$BLK_OUT'"
BLK_OUT="$(blk "" "THE-BLOCK" "$BASE_F")"
[ "$BLK_OUT" = "$BASE_F"$'\n'"THE-BLOCK" ] && ok "hook says a block → appended on its own line, the feature-tier doctrine above it untouched" || bad "appended (feature): '$BLK_OUT'"
BLK_OUT="$(blk "" "THE-BLOCK" "$BASE_B")"
[ "$BLK_OUT" = "$BASE_B"$'\n'"THE-BLOCK" ] && ok "same for the bug/tech-debt tier (the call site is tier-independent)" || bad "appended (bug): '$BLK_OUT'"
BLK_OUT="$(blk "1" "THE-BLOCK" "$BASE_F")"; blk "1" "THE-BLOCK" "$BASE_F" >/dev/null
[ "$BLK_OUT" = "$BASE_F" ] && [ "$BLK_CALLS" = 0 ] && ok "beads-repo branch (IS_BEADS_REPO_FIX set) → the hook is not even asked (an upstream PR has no gate to measure)" || bad "beads-repo branch: out='$BLK_OUT' calls=$BLK_CALLS"
blk "" "THE-BLOCK" "$BASE_F" >/dev/null
[ "$BLK_CALLS" = 1 ] && ok "normal branch → the hook is asked exactly once per dispatch" || bad "hook calls on a normal dispatch: $BLK_CALLS"
l_beads="$(grep -n '^  if \[ -n "\$IS_BEADS_REPO_FIX" \]; then$' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_block="$(grep -n '^  # ga-4q2zo5 (E12): ' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_task="$(grep -n '^  local DISPATCH_TASK$' "$DISPATCHER" | head -1 | cut -d: -f1)"
[ -n "$l_beads" ] && [ -n "$l_block" ] && [ -n "$l_task" ] && [ "$l_beads" -lt "$l_block" ] && [ "$l_block" -lt "$l_task" ] \
  && ok "the block runs AFTER the beads-repo override (line $l_beads < $l_block) and BEFORE the prompt is built (< $l_task)" || bad "order: beads=$l_beads block=$l_block task=$l_task"

# end to end on the extracted call site with the REAL hook and the REAL arms script: the text the builder would get
e2e() {   # e2e <bead> → DOCTRINE_BLOCK after the real hook+call site ran on BASE_F, in scenario dir $D
  { printf '%s\n' 'warn() { printf "%s\n" "$*" >> "$WARNLOG"; }'; printf '%s\n' "$FN"
    printf '%s\n' "f() { local IS_BEADS_REPO_FIX=\"\" STORY_ID=\"\$1\" STORY_BEAD_CITY=/city DOCTRINE_BLOCK=\"\$2\""; printf '%s\n' "$BLOCK"
    printf '%s\n' '  printf "%s" "$DOCTRINE_BLOCK"; }'; printf '%s\n' 'f "$1" "$2"'; } > "$D/e2e.sh"
  : > "$D/warn.log"
  OUT="$(PATH="$SANDBOX_PATH" E12_STATE_DIR="$SD" WARNLOG="$D/warn.log" bash "$D/e2e.sh" "$1" "$BASE_F" 2>/dev/null)"; RC=$?
}
newdir; e2e "$ID_T"
[ "$OUT" = "$BASE_F" ] && ok "end to end, NO conf: the builder's DOCTRINE section is exactly today's" || bad "e2e no conf: '${OUT:0:80}'"
newdir; conf_on; e2e "$ID_C"
[ "$OUT" = "$BASE_F" ] && ok "end to end, control bead: exactly today's" || bad "e2e control: '${OUT:0:80}'"
newdir; conf_on; e2e "$ID_T"
[ "$OUT" = "$BASE_F"$'\n'"$REAL_BLOCK" ] && ok "end to end, treated bead: today's doctrine, then the E12 block" || bad "e2e treated: '${OUT:0:120}'"
newdir; printf 'treated_pct=abc\n' > "$SD/e12-ab.conf"; e2e "$ID_T"
[ "$OUT" = "$BASE_F" ] && [ -s "$D/warn.log" ] && ok "end to end, unreadable conf: today's doctrine AND a log line" || bad "e2e invalid: out='${OUT:0:60}' warn=$(wc -c < "$D/warn.log")"

echo "== MUTATION CONTROLS: break the promises on purpose; this selftest must notice =="
mutant_emits() {   # <function-text> <arms-script-body> → 0 iff the mutated function emits text for that script
  newdir; conf_on; printf '%s' "$2" > "$D/e12-arms.sh"; run "$1" "$ID_T" /store
  [ -n "$OUT" ]
}
M1="$(printf '%s\n' "$FN" | sed 's/"## Write-time doctrine"\*) printf/*) printf/')"
[ "$M1" != "$FN" ] || bad "mutation 1 did not change the function — the control is void (the header check moved?)"
mutant_emits "$M1" $'#!/bin/bash\necho maybe\nexit 0\n' && ok "mutation 1 (drop the header check) is CAUGHT: a garbled answer is now appended" || bad "mutation 1 NOT caught — the 'garbled answer' scenario cannot tell"
M2="$(printf '%s\n' "$FN" | sed 's/\[ "\$_e12_rc" -ne 0 \]/false/')"
[ "$M2" != "$FN" ] || bad "mutation 2 did not change the function — the control is void (the exit-code test moved?)"
mutant_emits "$M2" $'#!/bin/bash\necho "## Write-time doctrine — experiment E12 (ga-4q2zo5)"\nexit 1\n' && ok "mutation 2 (ignore the exit code) is CAUGHT: a failed script's text is now appended" || bad "mutation 2 NOT caught — the 'failing script' scenario cannot tell"
M3="$(printf '%s\n' "$FN" | sed 's/--no-record/--ignored-flag/')"
[ "$M3" != "$FN" ] || bad "mutation 3 did not change the function — the control is void (the dry-run flag moved?)"
newdir; conf_on; DRY_RUN=1 run "$M3" "$ID_T" /store
[ -e "$SD/e12-roster.jsonl" ] || [ -z "$OUT" ] && ok "mutation 3 (dry run no longer passes --no-record) is CAUGHT: a dry run writes the roster or loses the block" || bad "mutation 3 NOT caught — the dry-run scenarios cannot tell"
M4="$(printf '%s\n' "$FN" | grep -v '^    warn "E12: no write-time doctrine for \$_e12_bid — e12-arms.sh block exited')"
[ "$M4" != "$FN" ] || bad "mutation 4 did not change the function — the control is void (the warn line moved?)"
newdir; printf 'treated_pct=abc\n' > "$SD/e12-ab.conf"; run "$M4" "$ID_T" /store
[ -z "$WARNS" ] && ok "mutation 4 (drop the log line) is CAUGHT: an invalid conf leaves no trace, which the section-2 scenarios detect" || bad "mutation 4 NOT caught — warns='$WARNS'"
newdir; printf 'treated_pct=abc\n' > "$SD/e12-ab.conf"; run "$FN" "$ID_T" /store
[ -n "$WARNS" ] && ok "(control for mutation 4: the unmutated hook does log that same failure)" || bad "the unmutated hook logged nothing for an invalid conf"
M5="$(printf '%s\n' "$FN" | sed 's/timeout 10 bash/bash/')"
[ "$M5" != "$FN" ] || bad "mutation 5 did not change the function — the control is void"
newdir; conf_on; : > "$TLOG"; run "$M5" "$ID_T" /store
case "$(head -1 "$TLOG" 2>/dev/null)" in "10 bash "*) bad "mutation 5 NOT caught — still bounded?" ;; *) ok "mutation 5 (drop the timeout) is CAUGHT: no bounded call is recorded" ;; esac
# the call-site guard: without it an upstream-PR dispatch would be enrolled in an experiment about the gate
M6="$(printf '%s\n' "$BLOCK" | sed 's/if \[ -z "\$IS_BEADS_REPO_FIX" \]; then/if true; then/')"
[ "$M6" != "$BLOCK" ] || bad "mutation 6 did not change the call site — the control is void (the guard moved?)"
M6_OUT="$( : > "$WORK/blk-calls"
  ( eval "_e12_doctrine_block() { echo called >> \"$WORK/blk-calls\"; printf 'X'; }"
    eval "f() { local IS_BEADS_REPO_FIX=1 STORY_ID=ga-x STORY_BEAD_CITY=/c DOCTRINE_BLOCK=B
$M6
      printf '%s' \"\$DOCTRINE_BLOCK\"; }"
    f ) )"
[ "$M6_OUT" != "B" ] && ok "mutation 6 (drop the beads-repo guard) is CAUGHT: the beads-repo dispatch would be enrolled" || bad "mutation 6 NOT caught"

# The scratch-dir guard at the top of this file. Each child runs from a directory holding a sentinel, with a TMPDIR that cannot hold a
# scratch dir, under the current bash AND the macOS system bash (3.2 — the one where the old code deleted its own working directory and
# still printed PASS). It must stop with exit 2 and a FATAL line, and the sentinel must still be there.
echo "== 7. no scratch directory → stop, never guess =="
if [ -z "${E12_SELFTEST_SCRATCH_CHILD:-}" ]; then
  _prev=""; _n=0
  for _sh in "${BASH:-/bin/bash}" /bin/bash; do
    [ -x "$_sh" ] && [ "$_sh" != "$_prev" ] || continue
    _prev="$_sh"; _n=$((_n+1))
    _probe="$WORK/nowork-$_n"; mkdir -p "$_probe"; : > "$_probe/sentinel"
    _crc=0; _cout="$(cd "$_probe" && E12_SELFTEST_SCRATCH_CHILD=1 TMPDIR="$WORK/no-such-dir" "$_sh" "$SELF_DIR/pilot-dispatcher.e12-doctrine-block.selftest.sh" 2>&1)" || _crc=$?
    if [ "$_crc" = 2 ] && [ -e "$_probe/sentinel" ]; then
      case "$_cout" in *FATAL*"scratch"*) ok "mktemp failure under $_sh → FATAL, exit 2, the working directory untouched" ;; *) bad "$_sh: exit 2 but no FATAL line naming the scratch dir: '${_cout:0:120}'" ;; esac
    else
      bad "$_sh with an unusable TMPDIR: exit=$_crc, sentinel $([ -e "$_probe/sentinel" ] && echo kept || echo DELETED) — a failed mktemp must stop the run with exit 2"
    fi
  done
else
  ok "(child run: the scratch-dir section is skipped to avoid recursing)"
fi

echo
echo "pilot-dispatcher.e12-doctrine-block.selftest: PASS=$PASS FAIL=$FAIL"
REACHED_END=1
[ "$FAIL" -eq 0 ]
