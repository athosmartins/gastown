#!/bin/bash
# e12-arms.selftest.sh — ga-4q2zo5 (E12 of the P0 ga-ufskhy): the contract of assets/e12-arms.sh.
#
# Run with the interpreter the launchd jobs use:   /bin/bash e12-arms.selftest.sh     (macOS bash 3.2)
# E12 is an A/B on what the builder is told BEFORE it writes: treated beads get a short "write-time doctrine" (one comment line
# before each new read — 'vazio → …; falhou/ilegível → …' — and a re-read of every comment in the diff); control beads get nothing.
# This file holds the promises of the arm rule and the roster; the Pilot's injection point has its own selftest
# (pilot-dispatcher.e12-doctrine-block.selftest.sh). The promises:
#   1. INERT BY DEFAULT — no conf => nobody is treated, nothing is recorded, nothing is said. The experiment is born OFF.
#   2. THREE STATES, NEVER TWO — "no experiment", "control arm" and "could not tell" never print the same thing. A conf that exists but
#      cannot be read (typo'd key, unreadable, empty — an empty file is what a failed write leaves behind) is its own state and is
#      NOT "no conf": it hands out nothing AND says so by exit code (6), because the one real caller drops stderr.
#   3. THE ARM IS RECOMPUTABLE — first 32 bits of SHA-256("e12-write-3state:<bead-id>") mod 100 < treated_pct, checked here by an
#      independent python hash, and it is not the coin of E3 (pre-gate) — two experiments over the same beads must not be one coin.
#   4. THE CONTROL HAS A DENOMINATOR — every bead that gets an arm gets a roster row, control included; one row per bead; a bead keeps
#      the arm it was first given whatever the conf says later (a pct ramp must not flip a re-dispatched bead).
#   5. NO ROW, NO TREATMENT — if the arm could not be recorded the bead gets no block: a treated bead that is missing from the roster
#      is a bead the readout cannot count.
# Every case below exists because of a failure that happened here or that this city's doctrine names; the comment says which.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E12="$HERE/e12-arms.sh"
[ -r "$E12" ] || { echo "FAIL: $E12 not readable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 missing — the arm recipe is checked by an independent hash" >&2; exit 1; }

# No scratch dir is a hard stop: with W empty every "$W/..." below would point at the filesystem root. The path check is separate from
# mktemp's exit code because "mktemp said yes" and "it printed a usable absolute path" are two different answers.
W="$(mktemp -d "${TMPDIR:-/tmp}/e12-arms-selftest.XXXXXX")" || { echo "FATAL: cannot create a scratch directory under ${TMPDIR:-/tmp} — nothing was run" >&2; exit 2; }
case "$W" in /?*) ;; *) echo "FATAL: mktemp printed no usable scratch path ('$W') — nothing was run" >&2; exit 2 ;; esac
# A selftest that dies half-way must not exit 0 (bash 3.2 does that for several abort shapes — ga-f31s7p): the trap turns "never reached
# the last line" into a failure of its own.
REACHED_END=0
finish() { local rc=$?; chmod -R u+rw "$W" 2>/dev/null; rm -rf "$W"; if [ "$REACHED_END" != 1 ] && [ "$rc" = 0 ]; then echo "FAIL: selftest aborted before its last line" >&2; exit 1; fi; }
trap finish EXIT
PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf '  FAIL %s\n' "$1" >&2; }

N_STATE=0; SD=""
newstate() { N_STATE=$((N_STATE+1)); SD="$W/s$N_STATE"; mkdir -p "$SD"; export E12_STATE_DIR="$SD"; }
conf() { printf '%s\n' "$@" > "$SD/e12-ab.conf"; }
OUT=""; ERR=""; RC=0
# E12 is always run as a subprocess under /bin/bash — the real CLI contract, not a sourced shortcut.
run() { OUT="$(/bin/bash "$E12" "$@" 2>"$W/err")"; RC=$?; ERR="$(cat "$W/err")"; }
rows() { if [ -r "$SD/e12-roster.jsonl" ]; then wc -l < "$SD/e12-roster.jsonl" | tr -d ' '; else echo 0; fi; }
ids() { local i=0; while [ "$i" -lt "$1" ]; do printf 'ga-%s%04d\n' "${2:-t}" "$i"; i=$((i+1)); done; }
# the documented recipe, computed by python's hashlib — never by the script under test
expected() { # expected <pct>  (ids on stdin) → "<id> treated|control"
  python3 -c '
import hashlib, sys
pct = int(sys.argv[1])
for raw in sys.stdin.read().split("\n"):
    if raw:
        d = hashlib.sha256(("e12-write-3state:" + raw).encode()).hexdigest()[:8]
        print(raw, "treated" if int(d, 16) % 100 < pct else "control")' "$1"
}
HEADER='## Write-time doctrine — experiment E12 (ga-4q2zo5)'

echo "== 1. inert by default =="
newstate
run state;                      [ "$OUT" = absent ] && [ "$RC" = 0 ] && ok "no conf: state=absent" || bad "no conf: state='$OUT' rc=$RC"
run block ga-abc /store;        [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$RC" = 0 ] && ok "no conf: block adds NOTHING, says nothing, exit 0 (an experiment that is off is not a failure)" || bad "no conf: block out='$OUT' err='$ERR' rc=$RC"
run assign ga-abc /store;       [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$RC" = 0 ] && ok "no conf: assign prints nothing, exit 0" || bad "no conf: assign out='$OUT' rc=$RC"
[ ! -e "$SD/e12-roster.jsonl" ] && ok "no conf: no roster row (an absent experiment records nothing)" || bad "no conf: a roster was written"
run arm ga-abc;                 [ -z "$OUT" ] && [ "$RC" = 4 ] && ok "no conf: arm prints nothing, exit 4 — no experiment is NOT 'control'" || bad "no conf: arm out='$OUT' rc=$RC"
run block ga-abc /store --no-record; [ -z "$OUT" ] && [ "$RC" = 0 ] && ok "no conf: block --no-record is inert too" || bad "no conf: block --no-record out='$OUT' rc=$RC"

echo "== 2. a conf that cannot be read is its own state — never 'no conf' =="
# The Pilot discards stderr and logs only a non-zero exit. If an invalid conf answered like "no conf" (exit 0, empty) a typo at turn-on
# would run the experiment at 0% with no roster row and no log line — the ga-shag3i finding on E9. Not repeated here.
for bc in "treated_pcts=50" "treated_pct=abc" "treated_pct=0" "treated_pct=101" "treated_pct=-5" "treated_pct=" "treated_pct=5 0" "treated_pct=50x" \
          "just-a-line" "salt=x" "treated_pct=50" ; do
  newstate
  if [ "$bc" = "treated_pct=50" ]; then conf "treated_pct=50" "treated_pct=abc"; bc="treated_pct=50 THEN treated_pct=abc"; else conf "$bc"; fi
  run state
  case "$OUT" in invalid:*) ok "bad conf '$bc' → $OUT" ;; *) bad "bad conf '$bc' → state='$OUT' (must be invalid:*)" ;; esac
  run block ga-abc /store
  [ -z "$OUT" ] && [ "$RC" = 6 ] && ok "bad conf '$bc': block prints nothing and exits 6" || bad "bad conf '$bc': block out='$OUT' rc=$RC"
  case "$ERR" in *"NOT running"*) ok "bad conf '$bc': stderr says the experiment is NOT running" ;; *) bad "bad conf '$bc': stderr='$ERR'" ;; esac
  run assign ga-abc /store
  [ -z "$OUT" ] && [ "$RC" = 6 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "bad conf '$bc': assign prints nothing, exit 6, no roster row" || bad "bad conf '$bc': assign out='$OUT' rc=$RC rows=$(rows)"
done
newstate; : > "$SD/e12-ab.conf"; run state
case "$OUT" in invalid:*) ok "empty conf → $OUT (what a failed write leaves behind must not switch the experiment on)" ;; *) bad "empty conf → '$OUT'" ;; esac
newstate; printf '# only a comment\n\n' > "$SD/e12-ab.conf"; run state
case "$OUT" in invalid:*) ok "comment-only conf → $OUT (no treated_pct, no experiment, and not silently absent)" ;; *) bad "comment-only conf → '$OUT'" ;; esac
newstate; mkdir "$SD/e12-ab.conf"; run state
case "$OUT" in invalid:*) ok "conf that is a directory → $OUT" ;; *) bad "conf dir → '$OUT'" ;; esac
# `[ -e ]` follows symlinks, so a symlink whose target is gone answered "there is no conf" (exit 0, silent): the file is THERE and cannot
# be read — the third state, not the second (gate review of ga-4q2zo5, attempt 1).
newstate; ln -s "$SD/no-such-target" "$SD/e12-ab.conf"; run state
case "$OUT" in invalid:*) ok "conf that is a dangling symlink → $OUT (it exists and cannot be read; not 'no conf')" ;; *) bad "dangling conf symlink → state='$OUT' (must be invalid:*)" ;; esac
run block ga-abc /store
[ -z "$OUT" ] && [ "$RC" = 6 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "dangling conf symlink: block prints nothing, exit 6, no roster row" || bad "dangling conf symlink: block out='$OUT' rc=$RC"
if [ "$(id -u)" != 0 ]; then
  newstate; conf treated_pct=50; chmod 000 "$SD/e12-ab.conf"
  run state; case "$OUT" in invalid:*) ok "unreadable conf → $OUT" ;; *) bad "unreadable conf → '$OUT'" ;; esac
  run block ga-abc /store; [ -z "$OUT" ] && [ "$RC" = 6 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "unreadable conf: nothing handed out, exit 6, no roster" || bad "unreadable conf: out='$OUT' rc=$RC"
  chmod 600 "$SD/e12-ab.conf"
fi
newstate; printf '# turn-on 05/10\n\ntreated_pct=50   # half the beads\n' > "$SD/e12-ab.conf"; run state
[ "$OUT" = "active treated_pct=50" ] && ok "comments, blank lines and trailing blanks are fine: '$OUT'" || bad "valid conf with comments: '$OUT'"
newstate; conf treated_pct=007; run state
[ "$OUT" = "active treated_pct=7" ] && ok "leading zeros are decimal (007 → 7), not octal" || bad "treated_pct=007: '$OUT'"
newstate; conf treated_pct=100; run state; [ "$OUT" = "active treated_pct=100" ] && ok "100 is accepted" || bad "treated_pct=100: '$OUT'"
newstate; conf treated_pct=1;   run state; [ "$OUT" = "active treated_pct=1" ]   && ok "1 is accepted"   || bad "treated_pct=1: '$OUT'"

echo "== 3. the arm is a recomputable function of the bead id =="
newstate; conf treated_pct=50
ids 100 a > "$W/ids"
expected 50 < "$W/ids" > "$W/want"
: > "$W/got"; while IFS= read -r id; do run arm "$id"; printf '%s %s\n' "$id" "$OUT" >> "$W/got"; done < "$W/ids"
if cmp -s "$W/want" "$W/got"; then ok "100 beads: every arm equals the independent SHA-256 recipe at treated_pct=50"; else bad "arm differs from the recipe: $(diff "$W/want" "$W/got" | head -3 | tr '\n' ';')"; fi
nt="$(grep -c ' treated$' "$W/got")"
[ "$nt" -ge 30 ] && [ "$nt" -le 70 ] && ok "treated share at pct=50 over 100 beads is $nt% (a coin, not a constant)" || bad "treated share $nt of 100"
# not E3's coin: E3's arm is the parity of SHA-256("pregate:<id>"); agreement between two independent coins is ~50%
agree="$(python3 -c '
import hashlib, sys
same = n = 0
for line in open(sys.argv[1]):
    bead, arm = line.split()
    e3 = int(hashlib.sha256(("pregate:" + bead).encode()).hexdigest()[:8], 16) % 2 == 0
    same += (arm == "treated") == e3; n += 1
print(same * 100 // n)' "$W/got")"
[ "$agree" -ge 25 ] && [ "$agree" -le 75 ] && ok "E12's arm agrees with E3's pre-gate arm on $agree% of beads — two experiments, two coins" || bad "agreement with E3 is $agree% (a shared coin would be ~100% or ~0%)"
newstate; conf treated_pct=100
all="$(while IFS= read -r id; do /bin/bash "$E12" arm "$id"; done < <(head -20 "$W/ids") | sort | uniq -c | tr -s ' ')"
[ "$all" = " 20 treated" ] && ok "treated_pct=100 → every bead treated" || bad "pct=100: '$all'"
newstate; conf treated_pct=1
nt1="$(while IFS= read -r id; do /bin/bash "$E12" arm "$id"; done < "$W/ids" | grep -c '^treated$')"
[ "$nt1" -le 8 ] && ok "treated_pct=1 → $nt1 of 100 treated (a canary, not half)" || bad "pct=1 treated $nt1 of 100"
newstate; conf treated_pct=50
run arm "bad id";  [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "an id with whitespace has no arm (exit 2, nothing printed)" || bad "arm 'bad id': out='$OUT' rc=$RC"
run arm "";        [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "an empty id has no arm (exit 2)" || bad "arm '': out='$OUT' rc=$RC"
E12_SHA_TOOLS=none-such run arm ga-abc
[ -z "$OUT" ] && [ "$RC" = 3 ] && ok "no SHA-256 tool → no arm, exit 3 — 'could not tell' is neither treated nor control" || bad "no sha tool: out='$OUT' rc=$RC"
E12_SHA_TOOLS=none-such run assign ga-abc /store
[ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "no SHA-256 tool: assign prints nothing, exit 3, no row" || bad "no sha tool assign: out='$OUT' rc=$RC"
want0="$(head -1 "$W/want" | cut -d' ' -f2)"
for tool in sha256sum openssl shasum; do
  command -v "$tool" >/dev/null 2>&1 || continue
  a="$(E12_SHA_TOOLS=$tool /bin/bash "$E12" arm ga-a0000 2>/dev/null)"
  [ "$a" = "$want0" ] && ok "the $tool path yields the same arm as the recipe ($a)" || bad "$tool path gave '$a', recipe says '$want0'"
done

echo "== 4. assign and the roster =="
# one bead id per arm, from the REAL rule at pct=50 (never invented)
ID_T=""; ID_C=""
newstate; conf treated_pct=50
while IFS= read -r line; do
  case "$line" in *" treated") [ -z "$ID_T" ] && ID_T="${line%% *}" ;; *" control") [ -z "$ID_C" ] && ID_C="${line%% *}" ;; esac
done < "$W/want"
[ -n "$ID_T" ] && [ -n "$ID_C" ] || { echo "FAIL: no fixture ids (t='$ID_T' c='$ID_C')" >&2; exit 1; }
echo "  fixtures: treated id=$ID_T, control id=$ID_C"
run assign "$ID_T" /store/x pilot-dispatch
[ "$OUT" = treated ] && [ "$RC" = 0 ] && ok "treated bead: assign prints 'treated'" || bad "assign treated: out='$OUT' rc=$RC"
row="$(jq -c 'select(.event=="assign")' "$SD/e12-roster.jsonl" 2>/dev/null | head -1)"
[ "$(rows)" = 1 ] && [ "$(printf '%s' "$row" | jq -r .bead)" = "$ID_T" ] && [ "$(printf '%s' "$row" | jq -r .arm)" = treated ] \
  && [ "$(printf '%s' "$row" | jq -r .salt)" = e12-write-3state ] && [ "$(printf '%s' "$row" | jq -r .treated_pct)" = 50 ] \
  && [ "$(printf '%s' "$row" | jq -r .store)" = /store/x ] && [ "$(printf '%s' "$row" | jq -r .stage)" = pilot-dispatch ] \
  && [ -n "$(printf '%s' "$row" | jq -r .ts)" ] && ok "roster row: bead, arm, salt, treated_pct (a number), store, stage, ts" || bad "roster row: '$row'"
run assign "$ID_C" /store/x
[ "$OUT" = control ] && [ "$RC" = 0 ] && [ "$(rows)" = 2 ] && ok "control bead: assign prints 'control' and ALSO writes a row (a control with no denominator is not a control)" || bad "assign control: out='$OUT' rc=$RC rows=$(rows)"
conf treated_pct=100            # a ramp: the pure arm of $ID_C is now 'treated'
run assign "$ID_C" /store/x
[ "$OUT" = control ] && [ "$(rows)" = 2 ] && ok "a pct ramp (50 → 100) does not flip a bead that already has a row: still 'control', still 2 rows" || bad "ramp flip: out='$OUT' rows=$(rows)"
run assign "$ID_T" /store/x;   [ "$OUT" = treated ] && [ "$(rows)" = 2 ] && ok "re-assign of the treated bead: same arm, no second row" || bad "re-assign: out='$OUT' rows=$(rows)"
# a truncated line (a crashed write) must not make every bead look unassigned
newstate; conf treated_pct=50
printf '{"ts":"x","event":"assign","bea\n' > "$SD/e12-roster.jsonl"
run assign "$ID_C" /store; [ "$OUT" = control ] && [ "$RC" = 0 ] && ok "a truncated roster line is skipped; the next bead is assigned and recorded" || bad "truncated line: out='$OUT' rc=$RC"
run assign "$ID_C" /store; [ "$OUT" = control ] && [ "$(rows)" = 2 ] && ok "…and is found on the next call (still one row for it)" || bad "after truncated line: rows=$(rows)"

# The torn line above ends in a newline, and a torn line from a crashed write NEVER does: the newline is the last byte of a row, so a write
# that stops short never reaches it. The append used to glue the next row onto the fragment — one unparseable line, exit 0, the bead
# treated in the builder's prompt but unreadable in the roster, and after a pct ramp re-dispatched as the other arm (gate review of
# ga-4q2zo5, attempt 1). The checks read the roster with their own jq, never with e12_recorded_arm, so they cannot agree with the code
# by sharing its blind spot. A bead that is treated at 50% and control at 1% (by the independent hash) makes the ramp visible.
rowsfor() { jq -R -c --arg b "$1" 'try fromjson catch empty | select(type=="object" and .event=="assign" and .bead==$b)' "$SD/e12-roster.jsonl" 2>/dev/null | wc -l | tr -d ' '; }
armfor()  { jq -R -r --arg b "$1" 'try fromjson catch empty | select(type=="object" and .event=="assign" and .bead==$b) | .arm' "$SD/e12-roster.jsonl" 2>/dev/null | head -1; }
expected 1 < "$W/ids" > "$W/want1"
ID_RAMP="$(paste -d' ' "$W/want" "$W/want1" | awk '$2=="treated" && $4=="control" {print $1; exit}')"
[ -n "$ID_RAMP" ] || { echo "FAIL: no fixture id that is treated at 50% and control at 1% (ramp='$ID_RAMP')" >&2; exit 1; }
newstate; conf treated_pct=50
printf '{"ts":"x","event":"assign","bea' > "$SD/e12-roster.jsonl"
run assign "$ID_C" /store
[ "$OUT" = control ] && [ "$RC" = 0 ] && [ "$(rowsfor "$ID_C")" = 1 ] && [ "$(armfor "$ID_C")" = control ] \
  && ok "torn tail WITHOUT a newline: the next row lands on its own line and is readable" || bad "torn tail, no newline: out='$OUT' rc=$RC readable-rows=$(rowsfor "$ID_C") roster='$(cat "$SD/e12-roster.jsonl")'"
run assign "$ID_T" /store
[ "$OUT" = treated ] && [ "$(rowsfor "$ID_T")" = 1 ] && [ "$(wc -l < "$SD/e12-roster.jsonl" | tr -d ' ')" = 3 ] \
  && ok "…the one after it too (fragment sealed once: 3 lines = fragment + 2 rows, no blank line, no second seal)" || bad "after the sealed tail: out='$OUT' lines=$(wc -l < "$SD/e12-roster.jsonl" | tr -d ' ') readable-rows=$(rowsfor "$ID_T")"
newstate; conf treated_pct=50
printf '{"ts":"x","event":"assign","bea' > "$SD/e12-roster.jsonl"
run assign "$ID_RAMP" /store; first_arm="$OUT"
conf treated_pct=1
run assign "$ID_RAMP" /store
[ "$first_arm" = treated ] && [ "$OUT" = treated ] && [ "$(rowsfor "$ID_RAMP")" = 1 ] && [ "$(armfor "$ID_RAMP")" = treated ] \
  && ok "torn tail + ramp 50% → 1%: the bead keeps its first arm (treated), one readable row — the prompt and the roster agree" || bad "ramp over a torn tail: first='$first_arm' after='$OUT' readable-rows=$(rowsfor "$ID_RAMP") (the old code printed nothing here and wrote a second row as control)"
run block "$ID_RAMP" /store
[ "$(printf '%s\n' "$OUT" | head -1)" = "$HEADER" ] && [ "$(rowsfor "$ID_RAMP")" = 1 ] && ok "…and block still hands it the doctrine, without a second row" || bad "block after the ramp: rc=$RC head='$(printf '%s\n' "$OUT" | head -1)' rows=$(rowsfor "$ID_RAMP")"
# a COMPLETE row that is only missing its newline (the crash came between the row and the newline) is a real row: counted, not re-assigned
newstate; conf treated_pct=50
jq -nc --arg b "$ID_C" '{ts:"x",event:"assign",bead:$b,store:"/s",salt:"e12-write-3state",arm:"control",treated_pct:50}' | tr -d '\n' > "$SD/e12-roster.jsonl"
run assign "$ID_T" /store; [ "$OUT" = treated ] && [ "$(rowsfor "$ID_T")" = 1 ] && [ "$(rowsfor "$ID_C")" = 1 ] \
  && ok "a whole row missing only its newline stays a row, and the next row does not fuse with it" || bad "whole row without newline: out='$OUT' T=$(rowsfor "$ID_T") C=$(rowsfor "$ID_C")"
conf treated_pct=100
run assign "$ID_C" /store; [ "$OUT" = control ] && [ "$(rowsfor "$ID_C")" = 1 ] && ok "…and it is found afterwards (a ramp to 100% does not flip it)" || bad "whole row without newline, after ramp: out='$OUT' C=$(rowsfor "$ID_C")"
# a tail that ends in a NUL byte (what some filesystems leave after a crash). `$(tail -c1)` cannot see it: bash 5 drops the NUL, so a
# test of "is the last byte empty" would call it a clean line end. The check has to read the byte itself.
newstate; conf treated_pct=50
printf '{"ts":"x","event":"assign"\0' > "$SD/e12-roster.jsonl"
run assign "$ID_C" /store; [ "$OUT" = control ] && [ "$RC" = 0 ] && [ "$(rowsfor "$ID_C")" = 1 ] \
  && ok "a tail ending in a NUL byte counts as torn: the next row is written on its own line" || bad "NUL tail: out='$OUT' rc=$RC readable-rows=$(rowsfor "$ID_C")"
# a roster that is a dangling symlink EXISTS and cannot be read: not "no roster". Appending through it would create the target out of nothing.
newstate; conf treated_pct=50; ln -s "$SD/no-such-roster" "$SD/e12-roster.jsonl"
run assign "$ID_T" /store
[ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/no-such-roster" ] && ok "roster is a dangling symlink → no arm, exit 3, nothing created behind it (it cannot be read; not 'no row')" || bad "dangling roster symlink: out='$OUT' rc=$RC target-created=$([ -e "$SD/no-such-roster" ] && echo yes || echo no)"
# jq missing and no roster yet: "cannot read" (3), said as such — it used to fall through to the append and be reported as an unwritable roster (5)
_nojq="$W/nojq-path"; mkdir -p "$_nojq"
for _t in date mkdir cut tail od tr cat sha256sum openssl shasum perl; do _p="$(command -v "$_t" 2>/dev/null)" && [ -n "$_p" ] && ln -sf "$_p" "$_nojq/$_t"; done
if PATH="$_nojq" command -v jq >/dev/null 2>&1; then
  bad "fixture: jq is still reachable on the stripped PATH — the no-jq case was not exercised"
else
  newstate; conf treated_pct=50
  PATH="$_nojq" run assign "$ID_T" /store
  [ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/e12-roster.jsonl" ] && case "$ERR" in *"cannot be read"*jq*) ok "no jq, no roster file: exit 3 and 'cannot be read … jq' (it is not an unwritable roster)" ;; *) bad "no jq: wrong message '$ERR'" ;; esac || bad "no jq, no roster: out='$OUT' rc=$RC err='$ERR'"
  PATH="$_nojq" run block "$ID_T" /store
  [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "no jq: block hands out nothing, exit 3" || bad "no jq block: out='$OUT' rc=$RC"
fi
newstate; conf treated_pct=50
printf '%s\n' "{\"ts\":\"x\",\"event\":\"assign\",\"bead\":\"$ID_T\",\"salt\":\"e12-write-3state\",\"arm\":\"maybe\"}" > "$SD/e12-roster.jsonl"
run assign "$ID_T" /store; [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "a row whose arm is not treated|control → no arm, exit 3 (not a recompute)" || bad "garbled row: out='$OUT' rc=$RC"
newstate; conf treated_pct=50
printf '%s\n' "{\"ts\":\"x\",\"event\":\"assign\",\"bead\":\"$ID_T\",\"salt\":\"another-salt\",\"arm\":\"control\"}" > "$SD/e12-roster.jsonl"
run assign "$ID_T" /store; [ "$OUT" = treated ] && ok "a row under another salt is not this experiment's (the pure arm is used)" || bad "other salt: out='$OUT'"
if [ "$(id -u)" != 0 ]; then
  newstate; conf treated_pct=50; : > "$SD/e12-roster.jsonl"; chmod 000 "$SD/e12-roster.jsonl"
  run assign "$ID_T" /store; [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "roster exists but cannot be READ → no arm, exit 3 (cannot tell whether the bead was assigned — not a recompute)" || bad "unreadable roster: out='$OUT' rc=$RC"
  chmod 600 "$SD/e12-roster.jsonl"
  newstate; conf treated_pct=50; : > "$SD/e12-roster.jsonl"; chmod 444 "$SD/e12-roster.jsonl"
  run assign "$ID_T" /store; [ -z "$OUT" ] && [ "$RC" = 5 ] && ok "roster cannot be WRITTEN → prints nothing, exit 5 (arm decided, not recorded)" || bad "unwritable roster: out='$OUT' rc=$RC"
  chmod 600 "$SD/e12-roster.jsonl"
  # sealing a torn tail is part of the write: if it cannot be done the row is not appended and the file is left exactly as it was
  newstate; conf treated_pct=50; printf '{"ts":"x","event":"assign","bea' > "$SD/e12-roster.jsonl"; cp "$SD/e12-roster.jsonl" "$W/torn-before"; chmod 444 "$SD/e12-roster.jsonl"
  run assign "$ID_T" /store
  [ -z "$OUT" ] && [ "$RC" = 5 ] && cmp -s "$SD/e12-roster.jsonl" "$W/torn-before" && ok "torn tail + roster cannot be written → exit 5, nothing printed, file untouched" || bad "torn tail, unwritable: out='$OUT' rc=$RC"
  chmod 600 "$SD/e12-roster.jsonl"
fi

echo "== 5. block: the text the builder gets =="
newstate; conf treated_pct=50
run block "$ID_T" /store/x pilot-dispatch
TB="$OUT"
[ "$RC" = 0 ] && [ -n "$TB" ] && ok "treated bead: block prints text, exit 0" || bad "treated block: rc=$RC len=${#TB}"
[ "$(printf '%s\n' "$TB" | head -1)" = "$HEADER" ] && ok "first line is the stable header the Pilot checks" || bad "header: '$(printf '%s\n' "$TB" | head -1)'"
nlines="$(printf '%s\n' "$TB" | grep -c .)"
[ "$nlines" -le 10 ] && ok "short: $nlines lines (the spec says ≤ 10)" || bad "block has $nlines lines"
case "$TB" in *'vazio → <what the code does>; falhou/ilegível → <what the code does>'*) ok "gives the exact comment line to write: 'vazio → …; falhou/ilegível → …'" ;; *) bad "comment-line format missing" ;; esac
case "$TB" in *"Before you write each new read"*"database"*"file"*"API"*"command"*"dict key"*) ok "says WHEN: before each new read, and names the kinds (database, file, API, command, dict key)" ;; *) bad "when/kinds missing" ;; esac
case "$TB" in *"inert"*"never the same result as"*) ok "says 'failed' must be the inert state and not the same result as 'empty'" ;; *) bad "inert-state clause missing" ;; esac
case "$TB" in *"Before /gate-done"*"does the code next to it do exactly this?"*) ok "says to re-read every comment in the diff before /gate-done with the question" ;; *) bad "re-read clause missing" ;; esac
case "$TB" in *"38%"*) ok "gives the why (the measured 38%)" ;; *) bad "no why" ;; esac
printf '%s\n' "$TB" | grep -E -q 'CRITICAL|MUST|NEVER|ALWAYS|NUNCA|SEMPRE|!!' && bad "block shouts (all-caps rule words) — the guide for these models says to give the reason instead" || ok "no shouting: reasons, not capital letters"
case "$TB" in *'$('*|*'${'*) bad "block holds shell expansion syntax" ;; *) ok "no shell expansion syntax in the block" ;; esac
[ "$(rows)" = 1 ] && ok "block recorded the assignment (one row)" || bad "block rows=$(rows)"
first="$TB"; run block "$ID_T" /store/x; [ "$OUT" = "$first" ] && [ "$(rows)" = 1 ] && ok "re-dispatch: same block, still one row" || bad "re-dispatch: rows=$(rows)"
run block "$ID_C" /store/x
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ "$(rows)" = 2 ] && ok "control bead: block prints NOTHING and the bead is recorded as control" || bad "control block: out='$OUT' rc=$RC rows=$(rows)"
row="$(jq -c --arg b "$ID_C" 'select(.bead==$b)' "$SD/e12-roster.jsonl" | head -1)"; [ "$(printf '%s' "$row" | jq -r .arm)" = control ] && ok "…with arm=control" || bad "control row: '$row'"

# --no-record is what a dry run uses: looking at a bead must not enrol it
newstate; conf treated_pct=50
run block "$ID_T" /store/x --no-record
[ "$OUT" = "$TB" ] && [ "$RC" = 0 ] && ok "--no-record, treated bead: same text as a real run" || bad "--no-record treated: rc=$RC"
run block "$ID_C" /store/x --no-record; [ -z "$OUT" ] && [ "$RC" = 0 ] && ok "--no-record, control bead: nothing" || bad "--no-record control: out='$OUT'"
[ ! -e "$SD/e12-roster.jsonl" ] && ok "--no-record writes no roster row (the roster is the denominator; a dry run is not a dispatch)" || bad "--no-record wrote a roster"
run assign "$ID_C" /store/x; conf treated_pct=100; run block "$ID_C" /store/x --no-record
[ -z "$OUT" ] && ok "--no-record honours the recorded arm over the current pure arm (the variable decided on is the variable acted on)" || bad "--no-record ignored the recorded arm"

# The flag is an option, not a slot. Read by position it became the STORE whenever the store was left out: `block <id> --no-record` exited 0,
# printed the block and wrote {"bead":"<id>","store":"--no-record"} — a dry run that enrolled the bead for good (the first assignment is
# sticky) under a garbage store field (gate review of ga-4q2zo5, attempt 2). Every case above puts a store in front of the flag, the one
# position the old code got right, which is why they were green. Here the flag stands in every other position; each run must leave NO roster.
# treated_pct=100 so the bead is treated whatever its hash, and the block text is the treated text seen above ($TB).
nr_case() { # nr_case <label> <block args…> — a fresh state per case, so one failure cannot make the next one fail by leaving a roster behind
  local label="$1"; shift
  newstate; conf treated_pct=100
  run block "$@"
  if [ "$RC" = 0 ] && [ "$OUT" = "$TB" ] && [ ! -e "$SD/e12-roster.jsonl" ]; then ok "--no-record $label: the block is shown, exit 0, no roster"
  else bad "--no-record $label: rc=$RC block-shown=$([ "$OUT" = "$TB" ] && echo yes || echo no) roster=$([ -e "$SD/e12-roster.jsonl" ] && tr '\n' ' ' < "$SD/e12-roster.jsonl" || echo none)"; fi
}
nr_case "right after the bead id (no store given)"        ga-p1test --no-record
nr_case "right after the bead id, then a stage"           ga-p1test --no-record pilot-dispatch
nr_case "before the bead id"                              --no-record ga-p1test
nr_case "before every positional"                         --no-record ga-p1test /store pilot-dispatch
nr_case "between store and stage"                         ga-p1test /store --no-record pilot-dispatch
nr_case "after an empty store (the Pilot can pass one)"   ga-p1test "" --no-record
# and the shape the Pilot really uses still records nothing under the flag at the end, AND a real run still records with a store of ""
nr_case "at the end (the Pilot's own shape)"              ga-p1test /store pilot-dispatch --no-record
newstate; conf treated_pct=100
run block ga-p1real "" pilot-dispatch
[ "$RC" = 0 ] && [ "$OUT" = "$TB" ] && [ "$(rows)" = 1 ] && [ "$(jq -r '.store' "$SD/e12-roster.jsonl")" = "" ] && [ "$(jq -r '.stage' "$SD/e12-roster.jsonl")" = pilot-dispatch ] && ok "a real run with an empty store still records one row, the stage in its own slot" || bad "empty-store real run: rc=$RC rows=$(rows) row=$(head -1 "$SD/e12-roster.jsonl" 2>/dev/null)"

# The sibling shapes of the same mistake — a word filed into a roster field it was never meant for. A dash-led word is never a bead, a store
# or a stage; a 4th positional used to be dropped (assign) or silently became the stage (block). All are refused with exit 2 and NOTHING written.
refuse_case() { # refuse_case <label> <command> <args…> — fresh state per case, same reason as nr_case
  local label="$1"; shift
  newstate; conf treated_pct=100
  run "$@"
  if [ "$RC" = 2 ] && [ -z "$OUT" ] && [ ! -e "$SD/e12-roster.jsonl" ] && [ -n "$ERR" ]; then ok "$label: exit 2, nothing printed, no roster, said why"
  else bad "$label: rc=$RC out='$OUT' err-empty=$([ -z "$ERR" ] && echo yes || echo no) roster=$([ -e "$SD/e12-roster.jsonl" ] && tr '\n' ' ' < "$SD/e12-roster.jsonl" || echo none)"; fi
}
refuse_case "assign takes no --no-record (it always writes)"   assign ga-p1test --no-record
refuse_case "assign: --no-record in the store slot"            assign ga-p1test --no-record pilot-dispatch
refuse_case "block: an unknown option"                         block ga-p1test /store --frobnicate
refuse_case "block: a dash-led word where the store goes"      block ga-p1test -x
refuse_case "block: a 4th positional"                          block ga-p1test /store pilot-dispatch extra
refuse_case "assign: a 4th positional"                         assign ga-p1test /store pilot-dispatch extra
# a flag where the BEAD goes: the old code enrolled a bead called "--no-record"
newstate; conf treated_pct=100
run block --no-record
[ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/e12-roster.jsonl" ] && ok "block --no-record with no bead id: exit 3 (cannot assign an arm to ''), no roster — not a row for a bead named '--no-record'" || bad "block --no-record alone: rc=$RC out='$OUT' roster=$([ -e "$SD/e12-roster.jsonl" ] && tr '\n' ' ' < "$SD/e12-roster.jsonl" || echo none)"
# the refusal does not depend on the experiment being on: a caller bug is a caller bug
newstate
run block ga-p1test --frobnicate; [ "$RC" = 2 ] && [ -z "$OUT" ] && ok "no conf: a malformed call is still refused (exit 2), not answered like 'the experiment is off'" || bad "no conf, malformed call: rc=$RC out='$OUT'"

# unrecorded ⇒ untreated
if [ "$(id -u)" != 0 ]; then
  newstate; conf treated_pct=50; : > "$SD/e12-roster.jsonl"; chmod 444 "$SD/e12-roster.jsonl"
  run block "$ID_T" /store/x
  [ -z "$OUT" ] && [ "$RC" = 5 ] && ok "treated bead + unwritable roster → NO block, exit 5 (a treated bead the readout cannot count is not treated)" || bad "unwritable roster block: out='$OUT' rc=$RC"
  chmod 600 "$SD/e12-roster.jsonl"
fi

echo "== 6. usage =="
run;            [ -z "$OUT" ] && [ "$RC" = 2 ] && case "$ERR" in *usage*) true ;; *) false ;; esac && ok "no command → usage on stderr, exit 2" || bad "no command: out='$OUT' rc=$RC err='$ERR'"
run frobnicate; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "unknown command → exit 2" || bad "unknown command: rc=$RC"

# This selftest ends in `rm -rf "$W"`. If mktemp fails (the disk has been near full here) the old code went on with W empty and wrote to
# "/s1", "/want"…; the sibling selftest, worse, turned its empty path into the CURRENT directory and deleted it while printing PASS.
# Each child below runs from a directory holding a sentinel, with a TMPDIR that cannot hold a scratch dir, under the current bash AND the
# macOS system bash (3.2, where `cd ""` succeeds and stays put — the shape that made the deletion possible). It must stop with exit 2
# and a FATAL line, and the sentinel must still be there.
echo "== 7. no scratch directory → stop, never guess =="
if [ -z "${E12_SELFTEST_SCRATCH_CHILD:-}" ]; then
  _prev=""; _n=0
  for _sh in "${BASH:-/bin/bash}" /bin/bash; do
    [ -x "$_sh" ] && [ "$_sh" != "$_prev" ] || continue
    _prev="$_sh"; _n=$((_n+1))
    _probe="$W/nowork-$_n"; mkdir -p "$_probe"; : > "$_probe/sentinel"
    _crc=0; _cout="$(cd "$_probe" && E12_SELFTEST_SCRATCH_CHILD=1 TMPDIR="$W/no-such-dir" "$_sh" "$HERE/e12-arms.selftest.sh" 2>&1)" || _crc=$?
    if [ "$_crc" = 2 ] && [ -e "$_probe/sentinel" ]; then
      case "$_cout" in *FATAL*"scratch"*) ok "mktemp failure under $_sh → FATAL, exit 2, the working directory untouched" ;; *) bad "$_sh: exit 2 but no FATAL line naming the scratch dir: '${_cout:0:120}'" ;; esac
    else
      bad "$_sh with an unusable TMPDIR: exit=$_crc, sentinel $([ -e "$_probe/sentinel" ] && echo kept || echo DELETED) — a failed mktemp must stop the run with exit 2"
    fi
  done
else
  ok "(child run: the scratch-dir section is skipped to avoid recursing)"
fi

# The header of e12-arms.sh promises the file is safe to source under `set -e` / `set -u`. It was not: `rec="$(e12_recorded_arm …)"; rrc=$?`
# hands the shell a non-zero status on the NORMAL first-sight case (rc 1 = no roster row), so a sourcing caller under `set -e` died
# silently with exit 1 — and the same shape stood around the jq call. Nothing sources the file today (the Pilot runs it as a child, and so
# does everything above), but the readout this experiment is waiting for is the obvious second caller. Each child sources the file under
# `set -eu` and calls e12_resolve as a PLAIN statement: `f || …` would switch errexit off inside f and hide exactly what is tested here.
echo "== 8. sourced under set -eu: an answer is not an abort =="
_prev=""
for _sh in "${BASH:-/bin/bash}" /bin/bash; do
  [ -x "$_sh" ] && [ "$_sh" != "$_prev" ] || continue
  _prev="$_sh"
  newstate; conf "treated_pct=100"
  _o="$("$_sh" -c 'set -eu; . "$1"; e12_resolve ga-s8-first store stage 0; echo "arm=$E12_ARM"' _ "$E12" 2>&1)"; _rc=$?
  [ "$_rc" = 0 ] && [ "$_o" = "arm=treated" ] && ok "$_sh: first-sight bead (no roster row = rc 1) survives set -e and gets its arm" || bad "$_sh: first-sight bead under set -eu: exit=$_rc out='${_o:0:120}'"
  newstate; conf "treated_pct=100"; : > "$SD/e12-roster.jsonl"
  _shim="$W/shimjq$N_STATE"; mkdir -p "$_shim"; printf '#!/bin/sh\nexit 5\n' > "$_shim/jq"; chmod +x "$_shim/jq"
  _o="$(PATH="$_shim:$PATH" "$_sh" -c 'set -eu; . "$1"; e12_resolve ga-s8-jq store stage 0; echo "reached-after-resolve"' _ "$E12" 2>&1)"; _rc=$?
  case "$_o" in
    *"roster cannot be read"*) [ "$_rc" = 3 ] && ok "$_sh: a failing jq is 'cannot tell' (exit 3, said so), not an abort with jq's own status" || bad "$_sh: jq failure said 'cannot be read' but exit=$_rc (want 3)" ;;
    *) bad "$_sh: a failing jq under set -eu: exit=$_rc and no 'roster cannot be read' message: '${_o:0:120}'" ;;
  esac
  # The two cases above never record (stage 0). The record path has its own pipeline (tail | od | tr) and its own branch (a newline in
  # front of the row after a torn tail), so it is run here too — as a plain statement, with pipefail on, over a roster that needs the
  # newline and over one that does not.
  newstate; conf "treated_pct=100"; printf '{"ts":"x","event":"assign","bea' > "$SD/e12-roster.jsonl"
  _o="$("$_sh" -c 'set -euo pipefail; . "$1"; e12_resolve ga-s8-rec store stage 1; echo "arm=$E12_ARM"' _ "$E12" 2>&1)"; _rc=$?
  [ "$_rc" = 0 ] && [ "$_o" = "arm=treated" ] && [ "$(rowsfor ga-s8-rec)" = 1 ] && ok "$_sh: recording after a torn tail under set -euo pipefail: exit 0, arm handed out, row readable" || bad "$_sh: record over a torn tail under set -euo pipefail: exit=$_rc out='${_o:0:120}' readable-rows=$(rowsfor ga-s8-rec)"
  _o="$("$_sh" -c 'set -euo pipefail; . "$1"; e12_resolve ga-s8-rec2 store stage 1; echo "arm=$E12_ARM"' _ "$E12" 2>&1)"; _rc=$?
  [ "$_rc" = 0 ] && [ "$_o" = "arm=treated" ] && [ "$(rowsfor ga-s8-rec2)" = 1 ] && [ "$(wc -l < "$SD/e12-roster.jsonl" | tr -d ' ')" = 3 ] && ok "$_sh: …and the next record over the now-clean tail adds no extra newline (3 lines)" || bad "$_sh: record over a clean tail under set -euo pipefail: exit=$_rc out='${_o:0:120}' lines=$(wc -l < "$SD/e12-roster.jsonl" | tr -d ' ')"
done

echo
echo "e12-arms selftest: $PASS passed, $FAILN failed"
REACHED_END=1
[ "$FAILN" = 0 ]
