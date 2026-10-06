#!/bin/bash
# e9-arms.selftest.sh — ga-798p6w (E9): the contract of assets/e9-arms.sh.
#
# Run with the interpreter the launchd jobs use:   /bin/bash e9-arms.selftest.sh     (macOS bash 3.2)
# Every case below exists because of a failure that happened here or that this city's doctrine names; the comment says which.
# The promises held:
#   1. INERT BY DEFAULT — no conf, a kill switch, or a malformed conf => the refiner's prompt gets NOTHING added, no roster row.
#   2. THREE STATES — "no experiment", "off (control)" and "could not tell" never print the same thing.
#   3. THE LEVEL IS COMPUTED — from recorded facts, and a level that disagrees with its own facts is visible.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E9="$HERE/e9-arms.sh"
[ -r "$E9" ] || { echo "FAIL: $E9 not readable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing" >&2; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/e9-arms-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf '  FAIL %s\n' "$1" >&2; }
check() { # check "<name>" <expected-rc> <actual-rc>
  [ "$3" = "$2" ] && ok "$1" || bad "$1 (rc=$3, wanted $2)"
}

# Fresh state dir per case; E9 is always run as a subprocess — the real CLI contract, not a sourced shortcut.
SD=""
newstate() { SD="$W/s$((++N_STATE))"; mkdir -p "$SD"; export E9_STATE_DIR="$SD"; }
N_STATE=0
conf() { printf '%s\n' "$@" > "$SD/e9-ab.conf"; }
e9()   { /bin/bash "$E9" "$@"; }
OUT=""; ERR=""; RC=0
run()  { OUT="$(e9 "$@" 2>"$W/err")"; RC=$?; ERR="$(cat "$W/err")"; }
runin() { local json="$1"; shift; OUT="$(printf '%s' "$json" | /bin/bash "$E9" "$@" 2>"$W/err")"; RC=$?; ERR="$(cat "$W/err")"; }

# a fixture shaped exactly like `bd show <id> --json` (an array of one object; labels array; metadata object) — copied from
# the live output of ga-798p6w on 01/10, not invented.
bead() { # bead "<labels, comma-separated>" '<metadata json object>'
  local labels="$1" meta="$2"
  jq -nc --arg l "$labels" --argjson m "$meta" \
    '[{id:"ga-fix",status:"open",labels:(if $l=="" then [] else ($l|split(",")) end),metadata:$m,comment_count:0}]'
}

# arms for N synthetic ids in ONE process: "<id> <arm>" lines
armsof() { ids "$@" | /bin/bash "$E9" arms planner; }
ids() { local i=0; while [ "$i" -lt "$1" ]; do printf 'ga-%s%04d\n' "${2:-t}" "$i"; i=$((i+1)); done; }

echo "== 1. inert by default (no conf / kill switch / bad conf) =="
newstate
run state;                         [ "$OUT" = absent ] && ok "no conf: state=absent" || bad "no conf: state='$OUT'"
run block ga-abc /store;           [ -z "$OUT" ] && [ "$RC" = 0 ] && ok "no conf: block adds NOTHING to the prompt, exit 0" || bad "no conf: block printed ${#OUT} bytes rc=$RC"
run assign ga-abc /store;          [ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "no conf: assign prints nothing and writes no roster row" || bad "no conf: assign out='$OUT' rc=$RC roster=$([ -e "$SD/e9-roster.jsonl" ] && echo yes || echo no)"
run arm planner ga-abc;            [ -z "$OUT" ] && [ "$RC" = 4 ] && ok "no conf: arm prints nothing, exit 4 — no experiment is NOT 'off'" || bad "no conf: arm out='$OUT' rc=$RC"

conf planner_pct=100 complexity=on salt=k1
touch "$SD/no-e9-ab"
run state;                         [ "$OUT" = killed ] && ok "kill switch beats a 100% conf: state=killed" || bad "kill switch: state='$OUT'"
run block ga-abc /store;           [ -z "$OUT" ] && ok "kill switch: block adds nothing" || bad "kill switch: block printed ${#OUT} bytes"
run assign ga-abc /store;          [ -z "$OUT" ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "kill switch: no roster row" || bad "kill switch: assign out='$OUT'"
run arm planner ga-abc;            [ "$RC" = 0 ] && { [ "$OUT" = on ] || [ "$OUT" = off ]; } && ok "kill switch: arm still RECOMPUTES (the readout needs it after switch-off)" || bad "kill switch: arm out='$OUT' rc=$RC"

# a malformed conf must be its own state, never "absent": a typo'd key silently running at 0% is the failure
for bc in "plannr_pct=50" "planner_pct=101" "planner_pct=abc" "planner_pct=-5" "planner_pct=" "planner_pct=5 0" "complexity=yes" \
          "salt=has space" "salt=" "just-a-line" "planner_pct=0" ; do
  newstate; conf "$bc"
  run state
  case "$OUT" in invalid:*) ok "bad conf '$bc' → $OUT" ;; *) bad "bad conf '$bc' → state='$OUT' (must be invalid:*)" ;; esac
  run block ga-abc /store; [ -z "$OUT" ] && [ ! -e "$SD/e9-roster.jsonl" ] && true || bad "bad conf '$bc': block/roster not inert"
done
newstate; : > "$SD/e9-ab.conf"; run state; case "$OUT" in invalid:*) ok "empty conf → $OUT (not absent, not active)" ;; *) bad "empty conf → '$OUT'" ;; esac
newstate; conf "salt=$(printf 'x%.0s' $(seq 1 40))" "planner_pct=50"; run state; case "$OUT" in invalid:*) ok "40-char salt → invalid" ;; *) bad "40-char salt accepted: '$OUT'" ;; esac
newstate; printf 'planner_pct=50\r\ncomplexity=on\r\n' > "$SD/e9-ab.conf"; run state; case "$OUT" in active*) ok "CRLF conf parses (trailing \\r trimmed)" ;; *) bad "CRLF conf → '$OUT'" ;; esac

# An INVALID conf is not "no conf": the one real caller (the Pilot) drops stderr and logs only a non-zero exit, and assign/peek used to answer
# an invalid conf exactly like an absent one (exit 0, empty stdout, empty stderr) — so a typo'd key at turn-on ran the experiment at 0% with
# no roster row and no log line (gate ga-shag3i, blocking issue 2). Exit 0 stays reserved for the two legitimate "off" states.
for bc in "planner_pct=5O" "plannr_pct=50" "planner_pct=101" "complexity=yes" "salt=" "just-a-line"; do
  newstate; conf "$bc"
  for sub in assign peek block; do
    run "$sub" ga-inv1 /store
    [ -z "$OUT" ] && [ "$RC" = 6 ] && case "$ERR" in *"unusable (invalid:"*"NOT running"*) true ;; *) false ;; esac \
      && ok "invalid conf '$bc': $sub prints nothing, exit 6, and stderr says the experiment is NOT running" || bad "invalid conf '$bc': $sub out='$OUT' rc=$RC err='$ERR'"
  done
  [ ! -e "$SD/e9-roster.jsonl" ] && ok "invalid conf '$bc': no roster row from any of them" || bad "invalid conf '$bc' wrote a roster"
done
newstate; : > "$SD/e9-ab.conf"; run assign ga-inv2 /store
[ "$RC" = 6 ] && ok "an EMPTY conf file is invalid too (exit 6), not absent" || bad "empty conf: assign rc=$RC"
newstate; conf planner_pct=100 salt=k1; touch "$SD/no-e9-ab"
for sub in assign peek block; do run "$sub" ga-inv3 /store; [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$RC" = 0 ] && ok "kill switch: $sub silent, exit 0 (legitimately off)" || bad "kill switch $sub: out='$OUT' rc=$RC err='$ERR'"; done
newstate
for sub in assign peek block; do run "$sub" ga-inv4 /store; [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$RC" = 0 ] && ok "no conf: $sub silent, exit 0 (legitimately off)" || bad "no conf $sub: out='$OUT' rc=$RC err='$ERR'"; done
newstate; conf planner_pct=5O; touch "$SD/no-e9-ab"; run assign ga-inv5 /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "kill switch beats an invalid conf: switching it off on purpose is not an error" || bad "kill switch + invalid conf: out='$OUT' rc=$RC"
# `[ -e ]` follows symlinks, so a symlink whose target is gone answered "there is no conf" (exit 0, silent): the file is THERE and cannot be
# read — the third state, not the second (same family as the roster finding of the gate review of ga-4q2zo5, attempt 1; ga-af5h6b).
newstate; ln -s "$SD/no-such-conf" "$SD/e9-ab.conf"; run state
case "$OUT" in invalid:*) ok "conf that is a dangling symlink → $OUT (it exists and cannot be read; not 'absent')" ;; *) bad "dangling conf symlink → state='$OUT' (must be invalid:*)" ;; esac
for sub in assign peek block; do
  run "$sub" ga-inv6 /store
  [ -z "$OUT" ] && [ "$RC" = 6 ] && ok "dangling conf symlink: $sub prints nothing, exit 6" || bad "dangling conf symlink: $sub out='$OUT' rc=$RC"
done
[ ! -e "$SD/e9-roster.jsonl" ] && ok "dangling conf symlink: no roster row from any of them" || bad "dangling conf symlink wrote a roster"
# the kill switch is a presence test, and the inert state is the default under doubt: a switch that is a dangling symlink is still a switch
newstate; conf planner_pct=100 salt=k1; ln -s "$SD/no-such-switch" "$SD/no-e9-ab"; run state
[ "$OUT" = killed ] && ok "kill switch that is a dangling symlink still counts: state=killed" || bad "dangling kill-switch symlink: state='$OUT' (the experiment kept running)"
run assign ga-inv7 /store
[ -z "$OUT" ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "dangling kill-switch symlink: assign silent, exit 0, no roster row" || bad "dangling kill-switch symlink: assign out='$OUT' rc=$RC"
newstate; printf '# comment\n\nplanner_pct=007  # inline\ncomplexity=off\n' > "$SD/e9-ab.conf"; run state
[ "$OUT" = "active planner_pct=7 complexity=off salt=e9a" ] && ok "comments, blanks, leading zeros (007 is 7, not an octal error), default salt" || bad "lenient-parse conf → '$OUT'"
# the state line must carry the REAL values — the first draft read them back through $(...) and printed empty ones
newstate; conf planner_pct=30 complexity=on salt=zz9; run state
[ "$OUT" = "active planner_pct=30 complexity=on salt=zz9" ] && ok "state carries the parsed values (not lost in a subshell)" || bad "state values: '$OUT'"

echo "== 2. arms =="
newstate; conf planner_pct=50 salt=t1
run arm planner ga-a1; A1="$OUT"; run arm planner ga-a1; A2="$OUT"; run arm planner ga-a1; A3="$OUT"
[ -n "$A1" ] && [ "$A1" = "$A2" ] && [ "$A2" = "$A3" ] && ok "deterministic: same bead+salt → same arm ($A1)" || bad "non-deterministic: $A1/$A2/$A3"
# the documented recipe, computed here independently of the script
recipe() { local d; d="$(printf '%s' "e9-planner:$2:$1" | openssl dgst -sha256 -r | cut -c1-8)"; if [ "$(( 16#$d % 100 ))" -lt "$3" ]; then echo on; else echo off; fi; }
mism=0; for b in ga-a1 ga-b2 wa-c3 ga-d4 ps-e5 ga-f6 wa-g7 ga-h8; do run arm planner "$b"; [ "$OUT" = "$(recipe "$b" t1 50)" ] || mism=$((mism+1)); done
[ "$mism" = 0 ] && ok "the arm equals the documented recipe (SHA-256(\"e9-planner:<salt>:<id>\") mod 100 < pct) — anyone can recompute it" || bad "$mism/8 arms differ from the documented recipe"

newstate; conf planner_pct=0 complexity=on salt=t1
on="$(armsof 60 | awk '$2=="on"{c++} END{print c+0}')"
[ "$on" = 0 ] && ok "pct=0 → nobody is treated" || bad "pct=0 treated $on/60"
newstate; conf planner_pct=100 salt=t1
off="$(armsof 60 | awk '$2=="off"{c++} END{print c+0}')"
[ "$off" = 0 ] && ok "pct=100 → everybody is treated" || bad "pct=100 left $off/60 in control"

newstate; conf planner_pct=50 salt=t1
n=400; on="$(armsof $n | awk '$2=="on"{c++} END{print c+0}')"
[ "$on" -ge 168 ] && [ "$on" -le 232 ] && ok "pct=50 splits ≈ half ($on/$n on; band 168–232 ≈ ±3σ)" || bad "pct=50 gave $on/$n on — not a fair coin"
newstate; conf planner_pct=20 salt=t1
on="$(armsof $n | awk '$2=="on"{c++} END{print c+0}')"
[ "$on" -ge 56 ] && [ "$on" -le 104 ] && ok "pct=20 treats ≈ a fifth ($on/$n; band 56–104)" || bad "pct=20 gave $on/$n"

# a new experiment must not be the old one: a new salt reshuffles
newstate; conf planner_pct=50 salt=t1; armsof 200 r > "$W/arms-t1"
conf planner_pct=50 salt=t2;           armsof 200 r > "$W/arms-t2"
chg="$(paste "$W/arms-t1" "$W/arms-t2" | awk '$2!=$4{c++} END{print c+0}')"
[ "$chg" -ge 60 ] && ok "a new salt reshuffles the split ($chg/200 beads changed arm)" || bad "salt does not reshuffle ($chg/200 changed)"

# INDEPENDENCE from E3's arm. ga-rstae's polynomial hash was measured agreeing with a salted copy of itself 43% of the time:
# salting a hash is not decorrelating it. Two experiments over the same beads must not be the same coin.
newstate; conf planner_pct=50 salt=t1
agree=0; n=400
while read -r b mine; do
  d="$(printf '%s' "pregate:$b" | openssl dgst -sha256 -r | cut -c1-8)"; e3=off; [ $(( 16#$d % 2 )) = 0 ] && e3=on
  [ "$mine" = "$e3" ] && agree=$((agree+1))
done < <(armsof $n i)
[ "$agree" -ge 170 ] && [ "$agree" -le 230 ] && ok "planner arm vs E3's pregate arm agree $agree/$n (independent coins ≈ 200 ± 40)" || bad "planner arm AGREES with E3's arm $agree/$n — the experiments are confounded"

# the batch command must say the same thing as the single one, and must refuse to skip an id
newstate; conf planner_pct=50 salt=t1
one="$(for b in ga-a1 ga-b2 wa-c3; do e9 arm planner "$b" | sed "s/^/$b /"; done)"; many="$(printf 'ga-a1\nga-b2\nwa-c3\n' | e9 arms planner)"
[ "$one" = "$many" ] && ok "arms (batch) == arm (single) for the same ids" || bad "batch/single disagree: [$one] vs [$many]"
OUT="$(printf 'ga-a1\nga bad\nga-b2\n' | e9 arms planner 2>/dev/null)"; RC=$?
[ "$RC" = 3 ] && ok "arms stops (exit 3) at an id with no arm instead of skipping it — a missing row is not 'off'" || bad "arms skipped a bad id: rc=$RC out='$OUT'"
newstate; OUT="$(printf 'ga-a1\n' | e9 arms planner 2>/dev/null)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 4 ] && ok "arms with no conf: nothing, exit 4" || bad "arms no conf: out='$OUT' rc=$RC"

# `arms planner` computes a whole batch in ONE python3 process (the readout recomputes thousands of arms; the shell loop made its selftest take
# 10+ minutes). That makes two implementations of one rule, so they are held together here: against the documented recipe computed
# independently (above), against the shell loop on the same input, and on every way the input can be odd. E9_SHA_TOOLS=openssl forces the loop.
if command -v python3 >/dev/null 2>&1; then
  for cfg in "50 t1" "20 x-y_z" "100 e9a" "1 s9"; do
    set -- $cfg; newstate; conf planner_pct="$1" complexity=on salt="$2"
    mism=0; n_ref=0; while read -r b a; do n_ref=$((n_ref+1)); [ "$a" = "$(recipe "$b" "$2" "$1")" ] || mism=$((mism+1)); done < <(armsof 40 q)
    [ "$mism" = 0 ] && [ "$n_ref" = 40 ] && ok "batch arms (pct=$1 salt=$2): all 40 equal the documented recipe" || bad "batch arms (pct=$1 salt=$2): $mism/$n_ref differ from the recipe"
  done
  newstate; conf planner_pct=50 complexity=on salt=t1
  fast="$(ids 60 z | e9 arms planner)"; loop="$(ids 60 z | E9_SHA_TOOLS=openssl /bin/bash "$E9" arms planner)"
  [ -n "$fast" ] && [ "$fast" = "$loop" ] && ok "batch == the shell loop on 60 ids (byte for byte)" || bad "batch and loop disagree on 60 ids"
  # every odd input: both paths must say the same thing on stdout, stderr and exit code
  odd() {   # odd <name> <printf-format>
    local f_out f_err f_rc l_out l_err l_rc
    f_out="$(printf "$2" | /bin/bash "$E9" arms planner 2>"$W/f.err")"; f_rc=$?; f_err="$(cat "$W/f.err")"
    l_out="$(printf "$2" | E9_SHA_TOOLS=openssl /bin/bash "$E9" arms planner 2>"$W/l.err")"; l_rc=$?; l_err="$(cat "$W/l.err")"
    [ "$f_out" = "$l_out" ] && [ "$f_err" = "$l_err" ] && [ "$f_rc" = "$l_rc" ] && ok "batch == loop for: $1 (rc=$f_rc)" || bad "batch/loop differ for $1: fast rc=$f_rc out=[$f_out] err=[$f_err] vs loop rc=$l_rc out=[$l_out] err=[$l_err]"
  }
  odd "no input at all" ''
  odd "blank lines are skipped" 'ga-a1\n\n\nga-b2\n'
  odd "no trailing newline" 'ga-a1\nga-b2'
  odd "an id with a space refuses at that id" 'ga-a1\nga bad\nga-b2\n'
  odd "an id with a tab refuses" 'ga-a1\nga\tbad\nga-b2\n'
  odd "an id with a trailing CR refuses (CRLF input)" 'ga-a1\r\nga-b2\r\n'
  odd "a non-ASCII id is hashed as its bytes" 'ga-caf\303\251\nga-b2\n'
  odd "a very long id" "$(printf 'ga-%0300d\\n' 7)"
  # the third state reaches the batch command too: no hash tool => no table, exit 3 — never a table of guesses
  OUT="$(ids 3 | E9_SHA_TOOLS=none /bin/bash "$E9" arms planner 2>/dev/null)"; RC=$?
  [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "no sha tool: arms prints nothing, exit 3 (the fast path does not bypass the third state)" || bad "no sha tool: arms out='$OUT' rc=$RC"
  # a python3 that crashes must not turn into a missing or partial table: the shell loop answers
  mkdir -p "$W/badpy"; printf '#!/bin/bash\necho "python3: simulated crash" >&2\nexit 1\n' > "$W/badpy/python3"; chmod +x "$W/badpy/python3"
  OUT="$(ids 20 z | PATH="$W/badpy:$PATH" /bin/bash "$E9" arms planner 2>/dev/null)"; RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = "$(printf '%s\n' "$fast" | head -20)" ] && ok "a crashing python3: the shell loop produces the SAME full table (no partial output, no gap)" || bad "crashing python3: rc=$RC lines=$(printf '%s\n' "$OUT" | grep -c .)"
fi
newstate; conf planner_pct=50 salt=t1

# third state: no sha256 tool at all → NO arm. Not "off" (that silently joins the control), not "on".
newstate; conf planner_pct=50 complexity=on salt=t1
OUT="$(E9_SHA_TOOLS=none /bin/bash "$E9" arm planner ga-a1 2>/dev/null)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 3 ] && ok "no sha tool: arm prints nothing, exit 3" || bad "no sha tool: arm out='$OUT' rc=$RC"
OUT="$(E9_SHA_TOOLS=none /bin/bash "$E9" assign ga-a1 /s 2>/dev/null)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "no sha tool: assign prints nothing, no roster row" || bad "no sha tool: assign out='$OUT' rc=$RC"
OUT="$(E9_SHA_TOOLS=none /bin/bash "$E9" block ga-a1 /s 2>/dev/null)"; RC=$?
[ -z "$OUT" ] && ok "no sha tool: block adds nothing to the prompt (no arm is neither on nor off)" || bad "no sha tool: block printed ${#OUT} bytes"
for tool in openssl shasum sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || continue
  OUT="$(E9_SHA_TOOLS=$tool /bin/bash "$E9" arm planner ga-a1 2>/dev/null)"
  [ "$OUT" = "$A1" ] && ok "tool $tool yields the same arm as the default chain" || bad "tool $tool gave '$OUT', default gave '$A1'"
done
for badid in "" " " "ga a1"; do
  run arm planner "$badid"; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "bead id '$badid' → no arm, exit 2" || bad "bead id '$badid' → out='$OUT' rc=$RC"
done

echo "== 3. roster =="
newstate; conf planner_pct=50 complexity=on salt=t1
run assign ga-r1 /st/a; first="$OUT"; run assign ga-r1 /st/a; run assign ga-r1 /st/a
rows="$(grep -c '"bead":"ga-r1"' "$SD/e9-roster.jsonl")"
[ "$rows" = 1 ] && [ "$OUT" = "$first" ] && ok "assigned 3 times → ONE roster row and the same arm (a re-attempt keeps its arm, the denominator is not inflated)" || bad "rows=$rows out='$OUT' first='$first'"
row="$(head -1 "$SD/e9-roster.jsonl")"
[ "$(printf '%s' "$row" | jq -r '[.event,.bead,.store,.salt,.planner_pct,.complexity,.planner_arm]|join("|")')" = "assign|ga-r1|/st/a|t1|50|on|$first" ] \
  && ok "the row carries salt, pct, complexity and the arm (what the readout needs to recompute and audit it)" || bad "row: $row"
conf planner_pct=50 complexity=on salt=t2; run assign ga-r1 /st/a
[ "$(grep -c '"bead":"ga-r1"' "$SD/e9-roster.jsonl")" = 2 ] && ok "a new salt is a new experiment: the bead is assigned again" || bad "new salt did not add a row"
newstate; conf planner_pct=50 salt=t1
run assign 'ga-"q' $'/st/with "quote"\\and\nnewline'
bl=0; while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null 2>&1 || bl=$((bl+1)); done < "$SD/e9-roster.jsonl"
[ "$bl" = 0 ] && [ "$(wc -l < "$SD/e9-roster.jsonl" | tr -d ' ')" = 1 ] && ok "quotes, backslash and a newline in a store path cannot corrupt the roster (jq builds the line)" || bad "roster corrupted ($bl bad lines)"
# THE ARM A BEAD IS IN IS THE ONE THE ROSTER RECORDED, not whatever the conf says now (gate ga-uu4y5m, blocking issue 2). The pct ramp
# (canary -> 50%) is the expected way to run this experiment; a re-dispatched bead (the normal case after a gate FAIL) must not be told
# to run the paid planner while the roster counts it as control — the readout recomputes from the row's own pct and could not see it.
newstate; conf planner_pct=0 complexity=on salt=r1
run assign ga-flip1 /st/a; [ "$OUT" = off ] || bad "setup: pct=0 must give off, got '$OUT'"
conf planner_pct=100 complexity=on salt=r1
run assign ga-flip1 /st/a
[ "$OUT" = off ] && [ "$RC" = 0 ] && ok "pct ramped 0 -> 100 after the assignment: assign still prints the RECORDED arm (off), not the recomputed one" || bad "recorded off, conf now 100%: assign printed '$OUT' rc=$RC"
run peek ga-flip1;  [ "$OUT" = off ] && ok "peek reads the same recorded arm" || bad "peek after the ramp: '$OUT'"
run block ga-flip1 /st/a
case "$OUT" in *"TECHNICAL PLAN"*) bad "the refiner block hands the plan to a bead recorded as control" ;; *) ok "block follows the recorded arm too: a control bead gets no plan after the ramp" ;; esac
[ "$(grep -c '"bead":"ga-flip1"' "$SD/e9-roster.jsonl")" = 1 ] && ok "still ONE roster row for the bead" || bad "rows: $(grep -c '"bead":"ga-flip1"' "$SD/e9-roster.jsonl")"
newstate; conf planner_pct=100 complexity=on salt=r1
run assign ga-flip2 /st/a; conf planner_pct=0 complexity=on salt=r1; run assign ga-flip2 /st/a
[ "$OUT" = on ] && ok "ramped DOWN 100 -> 0: a bead recorded as treated stays treated" || bad "recorded on, conf now 0%: '$OUT'"

# peek never writes: looking at a bead must not enrol it
newstate; conf planner_pct=100 complexity=on salt=r1
run peek ga-pk1; [ "$OUT" = on ] && [ "$RC" = 0 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "peek of an unassigned bead prints the pure arm and writes NO roster" || bad "peek: out='$OUT' rc=$RC roster=$([ -e "$SD/e9-roster.jsonl" ] && echo written || echo none)"
run assign ga-pk1 /s; conf planner_pct=0 complexity=on salt=r1; run peek ga-pk1
[ "$OUT" = on ] && ok "peek after assign reports the recorded arm, not the new conf's" || bad "peek after assign: '$OUT'"
newstate; run peek ga-pk2; [ -z "$OUT" ] && [ "$RC" = 0 ] && ok "peek with no conf: nothing, exit 0 (inert)" || bad "peek no conf: out='$OUT' rc=$RC"
newstate; conf planner_pct=50 salt=t1; run peek "ga bad"; [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "peek with a bad id: nothing, exit 3" || bad "peek bad id: out='$OUT' rc=$RC"

# a truncated line in the roster must not make every bead look unassigned (the first draft: one bad line => `jq -s` failed => "not
# assigned" => one more assign row per re-dispatch, with the arm recomputed each time)
newstate; conf planner_pct=0 complexity=on salt=r1
run assign ga-tr1 /s; printf '{"ts":"x","event":"assign","bead":"ga-tr' >> "$SD/e9-roster.jsonl"; printf '\n' >> "$SD/e9-roster.jsonl"
conf planner_pct=100 complexity=on salt=r1
run assign ga-tr1 /s; run assign ga-tr1 /s; run assign ga-tr1 /s
[ "$(grep -c '"bead":"ga-tr1"' "$SD/e9-roster.jsonl")" = 1 ] && [ "$OUT" = off ] && ok "a truncated roster line is skipped: still ONE row for the bead and the recorded arm after 3 re-dispatches" || bad "truncated line: rows=$(grep -c '"bead":"ga-tr1"' "$SD/e9-roster.jsonl") out='$OUT'"
printf '7\nnull\n[1]\n"x"\n' >> "$SD/e9-roster.jsonl"; run assign ga-tr1 /s
[ "$OUT" = off ] && [ "$RC" = 0 ] && ok "rows that are valid JSON but not records (7, null, [1], \"x\") are skipped without an error" || bad "non-record rows: out='$OUT' rc=$RC"

# THREE states for "what does the roster say": a row / no row / cannot tell. The last one must not become "no row" (which recomputes).
newstate; conf planner_pct=100 salt=t1; mkdir "$SD/e9-roster.jsonl"
run assign ga-w1 /s
[ -z "$OUT" ] && [ "$RC" = 3 ] && ok "a roster that cannot be READ (here: a directory): no arm, exit 3 — never a recompute" || bad "unreadable roster: out='$OUT' rc=$RC"
run peek ga-w1; [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "peek on an unreadable roster: no arm, exit 3" || bad "peek unreadable: out='$OUT' rc=$RC"
run block ga-w1 /s; [ -z "$OUT" ] && ok "block on an unreadable roster adds nothing to the prompt" || bad "block unreadable: printed ${#OUT} bytes"
if [ "$(id -u)" != 0 ]; then
  newstate; conf planner_pct=100 salt=t1; printf '{"event":"assign","bead":"ga-w2","salt":"t1","planner_arm":"off"}\n' > "$SD/e9-roster.jsonl"; chmod 000 "$SD/e9-roster.jsonl"
  run assign ga-w2 /s; chmod 600 "$SD/e9-roster.jsonl"
  [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "a roster with no read permission: no arm, exit 3 (the recorded 'off' is not replaced by a fresh 'on')" || bad "chmod 000 roster: out='$OUT' rc=$RC"
fi
newstate; conf planner_pct=100 salt=t1; printf '{"event":"assign","bead":"ga-w3","salt":"t1","planner_arm":"maybe"}\n' > "$SD/e9-roster.jsonl"
run assign ga-w3 /s; [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "a row whose arm is not on|off: no arm, exit 3 (a row with no usable arm is not 'no row')" || bad "garbled arm: out='$OUT' rc=$RC"
newstate; conf planner_pct=100 salt=t1; printf '{"event":"assign","bead":"ga-w4","salt":"t1"}\n' > "$SD/e9-roster.jsonl"
run assign ga-w4 /s; [ -z "$OUT" ] && [ "$RC" = 3 ] && ok "a row with no arm at all: no arm, exit 3" || bad "row without arm: out='$OUT' rc=$RC"
newstate; conf planner_pct=100 salt=t1; printf '{"event":"assign","bead":"ga-w5","salt":"OTHER","planner_arm":"off"}\n' > "$SD/e9-roster.jsonl"
run assign ga-w5 /s; [ "$OUT" = on ] && ok "a row under ANOTHER salt is not this experiment's assignment: assigned afresh" || bad "other-salt row: out='$OUT'"

# A roster that can be read but not WRITTEN: the arm was decided but cannot be recorded. It is not handed out — a bead with no row has
# no denominator slot — and the exit code (5) says so, because the one real caller drops stderr (gate ga-uu4y5m, non-blocking finding).
if [ "$(id -u)" != 0 ]; then
  newstate; conf planner_pct=100 salt=t1; : > "$SD/e9-roster.jsonl"; chmod 444 "$SD/e9-roster.jsonl"
  run assign ga-w6 /s; chmod 600 "$SD/e9-roster.jsonl"
  [ -z "$OUT" ] && [ "$RC" = 5 ] && case "$ERR" in *"NOT recorded"*) true ;; *) false ;; esac \
    && ok "roster readable but unwritable: nothing printed, exit 5, stderr says the assignment was NOT recorded" || bad "unwritable roster: out='$OUT' rc=$RC err='$ERR'"
  chmod 444 "$SD/e9-roster.jsonl"; run block ga-w6 /s; chmod 600 "$SD/e9-roster.jsonl"
  [ -z "$OUT" ] && ok "block for a bead that could not be recorded adds nothing (no recorded arm, no treatment)" || bad "block on unwritable roster printed ${#OUT} bytes"
  codes="$(printf '0 3 5 6' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')"; [ "$codes" = 4 ] && ok "assign's exits: 0 (answer), 3 (no arm), 5 (not recorded), 6 (invalid conf) are four different codes" || bad "assign exit codes collide"
fi

# The torn line in the truncated-line case above ends in a newline, and a torn line from a crashed write NEVER does: the newline is the last
# byte of a row, so a write that stops short never reaches it. The append used to glue the next row onto the fragment — one unparseable
# line, exit 0, the bead treated in the builder's prompt but unreadable in the roster (so missing from the denominator the readout counts),
# and after a pct ramp re-dispatched as the other arm (ga-af5h6b; the same defect the gate caught in E12, ga-4q2zo5 attempt 1).
# The checks read the roster with their own jq, never with e9_recorded_arm, so they cannot agree with the code by sharing its blind spot.
rowsfor() { jq -R -c --arg b "$1" 'try fromjson catch empty | select(type=="object" and .event=="assign" and .bead==$b)' "$SD/e9-roster.jsonl" 2>/dev/null | wc -l | tr -d ' '; }
armfor()  { jq -R -r --arg b "$1" 'try fromjson catch empty | select(type=="object" and .event=="assign" and .bead==$b) | .planner_arm' "$SD/e9-roster.jsonl" 2>/dev/null | head -1; }
nlines()  { wc -l < "$SD/e9-roster.jsonl" | tr -d ' '; }
# fixture ids: one that is off at 50%, and two that are on at 50% of which one is OFF at 1% — the ramp 50% → 1% makes a lost row visible
newstate; conf planner_pct=50 salt=torn1; armsof 80 q > "$W/arms50"
conf planner_pct=1 salt=torn1;           armsof 80 q > "$W/arms1"
ID_OFF="$(awk '$2=="off" {print $1; exit}' "$W/arms50")"
ID_RAMP="$(paste -d' ' "$W/arms50" "$W/arms1" | awk '$2=="on" && $4=="off" {print $1; exit}')"
ID_ON="$(awk -v skip="$ID_RAMP" '$2=="on" && $1!=skip {print $1; exit}' "$W/arms50")"
[ -n "$ID_OFF" ] && [ -n "$ID_RAMP" ] && [ -n "$ID_ON" ] || { echo "FAIL: no fixture ids (off='$ID_OFF' ramp='$ID_RAMP' on='$ID_ON')" >&2; exit 1; }

newstate; conf planner_pct=50 salt=torn1
printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"
run assign "$ID_OFF" /store
[ "$OUT" = off ] && [ "$RC" = 0 ] && [ "$(rowsfor "$ID_OFF")" = 1 ] && [ "$(armfor "$ID_OFF")" = off ] \
  && ok "torn tail WITHOUT a newline: the next row lands on its own line and is readable" || bad "torn tail, no newline: out='$OUT' rc=$RC readable-rows=$(rowsfor "$ID_OFF") roster='$(cat "$SD/e9-roster.jsonl")'"
run assign "$ID_ON" /store
[ "$OUT" = on ] && [ "$(rowsfor "$ID_ON")" = 1 ] && [ "$(nlines)" = 3 ] \
  && ok "…the one after it too (fragment sealed once: 3 lines = fragment + 2 rows, no blank line, no second seal)" || bad "after the sealed tail: out='$OUT' lines=$(nlines) readable-rows=$(rowsfor "$ID_ON")"
newstate; conf planner_pct=50 salt=torn1
printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"
run assign "$ID_RAMP" /store; first_arm="$OUT"
conf planner_pct=1 salt=torn1
run assign "$ID_RAMP" /store
[ "$first_arm" = on ] && [ "$OUT" = on ] && [ "$(rowsfor "$ID_RAMP")" = 1 ] && [ "$(armfor "$ID_RAMP")" = on ] \
  && ok "torn tail + ramp 50% → 1%: the bead keeps its first arm (on), one readable row — the prompt and the roster agree" || bad "ramp over a torn tail: first='$first_arm' after='$OUT' readable-rows=$(rowsfor "$ID_RAMP") (the old code answered off here and wrote a second row)"
run block "$ID_RAMP" /store
case "$OUT" in *"TECHNICAL PLAN"*) [ "$(rowsfor "$ID_RAMP")" = 1 ] && ok "…and block still hands it the plan, without a second row" || bad "block after the ramp wrote a row: rows=$(rowsfor "$ID_RAMP")" ;; *) bad "block after the ramp: rc=$RC no plan for a bead recorded as on" ;; esac
# a COMPLETE row that is only missing its newline (the crash came between the row and the newline) is a real row: counted, not re-assigned
newstate; conf planner_pct=50 salt=torn1
jq -nc --arg b "$ID_OFF" '{ts:"x",event:"assign",bead:$b,store:"/s",salt:"torn1",planner_arm:"off",planner_pct:50,complexity:"off"}' | tr -d '\n' > "$SD/e9-roster.jsonl"
run assign "$ID_ON" /store
[ "$OUT" = on ] && [ "$(rowsfor "$ID_ON")" = 1 ] && [ "$(rowsfor "$ID_OFF")" = 1 ] \
  && ok "a whole row missing only its newline stays a row, and the next row does not fuse with it" || bad "whole row without newline: out='$OUT' on=$(rowsfor "$ID_ON") off=$(rowsfor "$ID_OFF")"
conf planner_pct=100 salt=torn1
run assign "$ID_OFF" /store
[ "$OUT" = off ] && [ "$(rowsfor "$ID_OFF")" = 1 ] && ok "…and it is found afterwards (a ramp to 100% does not flip it)" || bad "whole row without newline, after ramp: out='$OUT' rows=$(rowsfor "$ID_OFF")"
# a tail that ends in a NUL byte (what some filesystems leave after a crash). `$(tail -c1)` cannot see it: bash 5 drops the NUL, so a test
# of "is the last byte empty" would call it a clean line end. The check has to read the byte itself.
newstate; conf planner_pct=50 salt=torn1
printf '{"ts":"x","event":"assign"\0' > "$SD/e9-roster.jsonl"
run assign "$ID_OFF" /store
[ "$OUT" = off ] && [ "$RC" = 0 ] && [ "$(rowsfor "$ID_OFF")" = 1 ] \
  && ok "a tail ending in a NUL byte counts as torn: the next row is written on its own line" || bad "NUL tail: out='$OUT' rc=$RC readable-rows=$(rowsfor "$ID_OFF")"
# a roster that is a dangling symlink EXISTS and cannot be read: not "no roster". Appending through it would create the target out of nothing.
newstate; conf planner_pct=50 salt=torn1; ln -s "$SD/no-such-roster" "$SD/e9-roster.jsonl"
run assign "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/no-such-roster" ] \
  && ok "roster is a dangling symlink → no arm, exit 3, nothing created behind it (it cannot be read; not 'no row')" || bad "dangling roster symlink: out='$OUT' rc=$RC target-created=$([ -e "$SD/no-such-roster" ] && echo yes || echo no)"
# an append that cannot happen must leave the file as it was: no seal written on its own, no half of a pair
if [ "$(id -u)" != 0 ]; then
  newstate; conf planner_pct=50 salt=torn1; printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"; chmod 444 "$SD/e9-roster.jsonl"
  before="$(cksum < "$SD/e9-roster.jsonl")"
  run assign "$ID_OFF" /store; chmod 600 "$SD/e9-roster.jsonl"
  [ -z "$OUT" ] && [ "$RC" = 5 ] && [ "$(cksum < "$SD/e9-roster.jsonl")" = "$before" ] \
    && ok "unwritable roster + torn tail: nothing printed, exit 5, the file is byte-for-byte what it was" || bad "unwritable + torn: out='$OUT' rc=$RC changed=$([ "$(cksum < "$SD/e9-roster.jsonl")" = "$before" ] && echo no || echo yes)"
fi
# jq missing and no roster yet: "cannot read" (3), said as such. e9_recorded_arm's own comment promises it; the code used to answer "no row" (1),
# fall through to the append, and report an unwritable roster (5).
_nojq="$W/nojq-path"; mkdir -p "$_nojq"
for _t in date mkdir cut tail od tr cat sed grep awk head wc sort uniq sha256sum openssl shasum perl; do _p="$(command -v "$_t" 2>/dev/null)" && [ -n "$_p" ] && ln -sf "$_p" "$_nojq/$_t"; done
if [ -z "$(PATH="$_nojq" command -v jq 2>/dev/null)" ]; then
  newstate; conf planner_pct=50 salt=torn1
  OUT="$(PATH="$_nojq" /bin/bash "$E9" assign "$ID_OFF" /store 2>"$W/err")"; RC=$?
  [ -z "$OUT" ] && [ "$RC" = 3 ] && [ ! -e "$SD/e9-roster.jsonl" ] && ok "no jq and no roster yet: no arm, exit 3 (cannot read), nothing written" || bad "no jq, no roster: out='$OUT' rc=$RC err='$(cat "$W/err")'"
else
  echo "  skip no-jq case: could not build a PATH without jq" >&2
fi
# e9_record itself — also the writer of the plan_run rows (the PENDING row before a paid run), sourced the way a caller sources it, under
# `set -euo pipefail`: the last-byte read must not trip errexit, and a plan_run row must not fuse with a torn tail either.
newstate; printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"
OUT="$(/bin/bash -c 'set -euo pipefail; . "$1"; e9_record assign bead=ga-j1 store=/s salt=j planner_arm=on; e9_record plan_run bead=ga-j1 run_id=r1 verdict=PENDING; echo done' _ "$E9" 2>"$W/err")"; RC=$?
good="$(jq -R -c 'try fromjson catch empty | select(type=="object")' "$SD/e9-roster.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
[ "$OUT" = done ] && [ "$RC" = 0 ] && [ "$good" = 2 ] && [ "$(nlines)" = 3 ] \
  && ok "e9_record under set -euo pipefail over a torn tail: assign and plan_run rows both land on their own lines" || bad "e9_record sourced: out='$OUT' rc=$RC readable-rows=$good lines=$(nlines) err='$(cat "$W/err")'"
newstate; mkdir "$SD/e9-roster.jsonl"
OUT="$(/bin/bash -c '. "$1"; e9_record assign bead=ga-j2; echo "rc=$?"' _ "$E9" 2>/dev/null)"
[ "$OUT" = "rc=3" ] && ok "e9_record on a roster that is a directory: rc 3" || bad "e9_record on a directory roster: '$OUT'"
newstate; ln -s "$SD/no-such-roster" "$SD/e9-roster.jsonl"
OUT="$(/bin/bash -c '. "$1"; e9_record plan_run bead=ga-j3 run_id=r3 verdict=PENDING; echo "rc=$?"' _ "$E9" 2>/dev/null)"
[ "$OUT" = "rc=3" ] && [ ! -e "$SD/no-such-roster" ] && ok "e9_record on a dangling roster symlink: rc 3 (a PENDING row that cannot be written stops the paid run), no target created" || bad "e9_record on a dangling symlink: '$OUT' target-created=$([ -e "$SD/no-such-roster" ] && echo yes || echo no)"

# The last byte is read from a file other processes append to, and `tail -c1` is not bounded to one byte: it seeks to size-1 and reads to the
# CURRENT end, so a writer that lands a row between its fstat and its read makes it print the old last byte AND the whole new row. Piped into
# od unbounded that is a long hex string, which matches neither "0a" nor "one byte": the record failed (exit 5, "roster unwritable") on a
# roster that was perfectly writable — 4 of 512 concurrent assigns on a clean roster (gate review of ga-af5h6b, attempt 1). The decision is on
# the FIRST byte and nothing else. The shim is that race made deterministic: the real tail, then the row the concurrent writer appended meanwhile.
_race="$W/race-path"; mkdir -p "$_race"
cat > "$_race/tail" <<EOF
#!/bin/sh
"$(command -v tail)" "\$@"
printf '%s\n' '{"ts":"x","event":"assign","bead":"ga-concurrent","salt":"torn1","planner_arm":"on"}'
EOF
chmod +x "$_race/tail"
newstate; conf planner_pct=50 salt=torn1
printf '%s\n' '{"ts":"x","event":"assign","bead":"ga-before","salt":"torn1","planner_arm":"off"}' > "$SD/e9-roster.jsonl"
OUT="$(PATH="$_race:$PATH" /bin/bash "$E9" assign "$ID_OFF" /store 2>"$W/err")"; RC=$?
[ "$OUT" = off ] && [ "$RC" = 0 ] && [ "$(rowsfor "$ID_OFF")" = 1 ] && [ "$(nlines)" = 2 ] \
  && ok "a writer lands a row between tail's size and its read: the clean roster still records (first byte = newline), no blank line" || bad "append race on a clean roster: out='$OUT' rc=$RC lines=$(nlines) err='$(cat "$W/err")' (the unbounded od read took the concurrent row for an unreadable byte → exit 5)"
newstate; conf planner_pct=50 salt=torn1
printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"
OUT="$(PATH="$_race:$PATH" /bin/bash "$E9" assign "$ID_ON" /store 2>"$W/err")"; RC=$?
[ "$OUT" = on ] && [ "$RC" = 0 ] && [ "$(rowsfor "$ID_ON")" = 1 ] && [ "$(nlines)" = 2 ] \
  && ok "…and a torn tail seen through the same race is still sealed (the first byte decides, the extra row does not hide the fragment)" || bad "append race on a torn tail: out='$OUT' rc=$RC lines=$(nlines) readable-rows=$(rowsfor "$ID_ON") err='$(cat "$W/err")'"
# a caller that runs under pipefail (e9-plan.sh does) sees one more thing: when tail's own status is non-zero AFTER it delivered the byte —
# SIGPIPE, once od has its one byte — the status is not the answer, the byte is. A fix that cleared the byte on a failed pipeline would bring
# the race back for exactly those callers, and would trip errexit if it did not shield the assignment.
_sigpipe="$W/sigpipe-path"; mkdir -p "$_sigpipe"
cat > "$_sigpipe/tail" <<EOF
#!/bin/sh
"$(command -v tail)" "\$@"
printf '%s\n' '{"ts":"x","event":"assign","bead":"ga-concurrent"}'
exit 141
EOF
chmod +x "$_sigpipe/tail"
newstate; printf '%s\n' '{"ts":"x","event":"assign","bead":"ga-before"}' > "$SD/e9-roster.jsonl"
OUT="$(PATH="$_sigpipe:$PATH" /bin/bash -c 'set -euo pipefail; . "$1"; e9_record assign bead=ga-k1 store=/s salt=k planner_arm=on; echo "rc=$?"' _ "$E9" 2>"$W/err")"; RC=$?
[ "$OUT" = "rc=0" ] && [ "$RC" = 0 ] && [ "$(nlines)" = 2 ] \
  && ok "set -euo pipefail + a tail that exits 141 after delivering its byte: the byte decides, the row is recorded, errexit does not fire" || bad "pipefail + failed tail status: out='$OUT' rc=$RC lines=$(nlines) err='$(cat "$W/err")'"
# the real thing, not a shim: a burst of concurrent assigns over a roster that already has a row (so every process reads the last byte while the
# others append). Every one must exit 0 and land exactly one readable row; a lost row here is a bead missing from the denominator.
newstate; conf planner_pct=50 salt=torn1
printf '%s\n' '{"ts":"x","event":"assign","bead":"ga-seed","salt":"torn1","planner_arm":"off"}' > "$SD/e9-roster.jsonl"
_burst_fail=0
for _round in 1 2 3 4 5 6; do
  _pids=""
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    /bin/bash "$E9" assign "ga-burst$_round-$_i" /store >/dev/null 2>&1 & _pids="$_pids $!"
  done
  for _p in $_pids; do wait "$_p" || _burst_fail=$((_burst_fail+1)); done
done
_burst_rows="$(jq -R -c 'try fromjson catch empty | select(type=="object" and .event=="assign")' "$SD/e9-roster.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
[ "$_burst_fail" = 0 ] && [ "$_burst_rows" = 97 ] \
  && ok "96 concurrent assigns over a clean roster (6 bursts of 16): every exit 0, 97 readable rows (seed + 96), none lost or glued" || bad "concurrent burst: failed=$_burst_fail readable-rows=$_burst_rows (wanted 0 and 97)"
# the contract in the header, one case per state it names — a comment that promises an exit code the code does not give sends the operator
# triaging a Pilot-logged "exit 3" or "exit 5" to the wrong cause (gate review of ga-af5h6b, attempt 1). assign decides these in two places:
# e9_recorded_arm first (a roster it cannot read is exit 3 — dangling symlink, directory, mode 000, no jq), then e9_record (exit 5: the arm is
# known but the row could not be written, or the last byte could not be read).
newstate; conf planner_pct=50 salt=torn1; mkdir "$SD/e9-roster.jsonl"
run assign "$ID_ON" /store
[ -z "$OUT" ] && [ "$RC" = 3 ] && ok "roster is a directory: assign prints nothing, exit 3 (cannot be read — not 5)" || bad "directory roster: out='$OUT' rc=$RC"
if [ "$(id -u)" != 0 ]; then
  newstate; conf planner_pct=50 salt=torn1; printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"
  before="$(cksum < "$SD/e9-roster.jsonl")"; chmod 000 "$SD/e9-roster.jsonl"
  run assign "$ID_ON" /store; chmod 600 "$SD/e9-roster.jsonl"
  [ -z "$OUT" ] && [ "$RC" = 3 ] && [ "$(cksum < "$SD/e9-roster.jsonl")" = "$before" ] \
    && ok "roster with mode 000: assign prints nothing, exit 3 (cannot be read), the file untouched" || bad "mode-000 roster: out='$OUT' rc=$RC changed=$([ "$(cksum < "$SD/e9-roster.jsonl")" = "$before" ] && echo no || echo yes)"
fi
# exit 5 for a last byte that cannot be read: a PATH with no tail. The roster is readable and writable, the arm is known — the only thing
# missing is the one byte the append decision needs, and guessing it would glue a row onto a fragment or leave a blank line for nothing.
_notail="$W/notail-path"; mkdir -p "$_notail"
for _t in date mkdir cut jq od tr cat sed grep awk head wc sort uniq sha256sum openssl shasum perl; do _p="$(command -v "$_t" 2>/dev/null)" && [ -n "$_p" ] && ln -sf "$_p" "$_notail/$_t"; done
if [ -z "$(PATH="$_notail" command -v tail 2>/dev/null)" ]; then
  newstate; conf planner_pct=50 salt=torn1; printf '{"ts":"x","event":"assign","bea' > "$SD/e9-roster.jsonl"
  before="$(cksum < "$SD/e9-roster.jsonl")"
  OUT="$(PATH="$_notail" /bin/bash "$E9" assign "$ID_OFF" /store 2>"$W/err")"; RC=$?
  [ -z "$OUT" ] && [ "$RC" = 5 ] && [ "$(cksum < "$SD/e9-roster.jsonl")" = "$before" ] \
    && ok "last byte cannot be read (no tail): nothing printed, exit 5, the roster byte-for-byte what it was" || bad "no tail: out='$OUT' rc=$RC err='$(cat "$W/err")' (an unreadable last byte must be a failed record, never 'looks fine')"
else
  echo "  skip no-tail case: could not build a PATH without tail" >&2
fi

echo "== 4. complexity (computed from facts) =="
cx() { run complexity "$@"; }
tbl="1 1 0 0:S|2 1 0 0:S|3 1 0 0:M|2 2 0 0:M|7 2 0 0:M|8 1 0 0:L|1 3 0 0:L|4 5 0 0:L|1 1 1 0:L|1 1 0 1:L|2 2 1 1:L|08 1 0 0:L|007 02 0 0:M"
oldifs="$IFS"; IFS='|'; for row in $tbl; do IFS="$oldifs"; args="${row%%:*}"; want="${row##*:}"
  # shellcheck disable=SC2086
  cx $args; [ "$OUT" = "$want" ] && [ "$RC" = 0 ] && ok "complexity $args → $want" || bad "complexity $args → '$OUT' rc=$RC, wanted $want"; IFS='|'; done; IFS="$oldifs"
# bad input never becomes a level: an unreadable estimate is not "S"
for badargs in "0 1 0 0" "1 0 0 0" "x 1 0 0" "-1 1 0 0" "1.5 1 0 0" "1 1 2 0" "1 1 0 2" "1 1 0" "1 1 0 0 0" "9999999 1 0 0" "1 1 true 0" ; do
  # shellcheck disable=SC2086
  cx $badargs; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "bad args '$badargs' → no level, exit 2" || bad "bad args '$badargs' → out='$OUT' rc=$RC"
done
run complexity; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "no args → exit 2" || bad "no args → out='$OUT' rc=$RC"

echo "== 5. finalize (what the dispatcher writes after the refiner returns) =="
F="arquivos=2 superficies=1 externo=0 migracao=0"
runin "$(bead "" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f}')")" finalize
[ "$OUT" = $'SET story.complexidade=S\nLABEL complexity:S\nSTATUS complexity=ok:S' ] && ok "good facts → SET + LABEL + STATUS ok (the level comes from CODE, not the refiner)" || bad "finalize good: '$OUT'"
runin "$(bead "complexity:L,lane:small" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f}')")" finalize
[ "$OUT" = $'UNLABEL complexity:L\nSET story.complexidade=S\nLABEL complexity:S\nSTATUS complexity=ok:S' ] && ok "a stale level from an earlier attempt is UNLABELed, other labels untouched" || bad "finalize stale: '$OUT'"
runin "$(bead "complexity:S" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f}')")" finalize
case "$OUT" in *UNLABEL*) bad "unchanged level was needlessly unlabeled: '$OUT'" ;; *) ok "an unchanged level is not unlabeled (no window with no label)" ;; esac
runin "$(bead "" '{"story.complexidade_fatos":"externo=0 migracao=0 superficies=1 arquivos=2"}')" finalize
[ "$OUT" = $'SET story.complexidade=S\nLABEL complexity:S\nSTATUS complexity=ok:S' ] && ok "facts in any order are accepted" || bad "reordered facts: '$OUT'"
runin "$(bead "" '{"story.complexidade_fatos":"arquivos=9\nsuperficies=1\nexterno=0\nmigracao=0"}')" finalize
[ "$OUT" = $'SET story.complexidade=L\nLABEL complexity:L\nSTATUS complexity=ok:L' ] && ok "facts one per line are accepted" || bad "multi-line facts: '$OUT'"
runin "$(bead "complexity:M" '{"story.complexidade_fatos":"desconhecido: o modulo X nao esta no repo"}')" finalize
[ "$OUT" = $'UNLABEL complexity:M\nSTATUS complexity=unknown' ] && ok "\"desconhecido\" is its own state — no level, stale level removed, NOT counted as S" || bad "finalize unknown: '$OUT'"
runin "$(bead "" '{}')" finalize
[ "$OUT" = "STATUS complexity=absent" ] && ok "refiner wrote nothing → absent" || bad "finalize absent: '$OUT'"
# THE THIRD STATE (gate ga-shag3i, blocking issue 1): the label was removed but story.complexidade was not, so "could not tell" kept
# rendering as the previous known level wherever the metadata is read. All three non-ok branches unset the recorded level — and only
# when one is recorded, so a bead that never had one gets no pointless write.
runin "$(bead "complexity:S" '{"story.complexidade_fatos":"desconhecido: sem acesso ao modulo","story.complexidade":"S"}')" finalize
[ "$OUT" = $'UNLABEL complexity:S\nUNSET story.complexidade\nSTATUS complexity=unknown' ] && ok "desconhecido + a recorded level S → label AND metadata level removed (the stale S cannot survive)" || bad "finalize unknown+level: '$OUT'"
runin "$(bead "" '{"story.complexidade_fatos":"desconhecido: x","story.complexidade":"M"}')" finalize
[ "$OUT" = $'UNSET story.complexidade\nSTATUS complexity=unknown' ] && ok "desconhecido + a recorded level but no label → the metadata level is still removed" || bad "finalize unknown, metadata only: '$OUT'"
runin "$(bead "complexity:L" '{"story.complexidade":"L"}')" finalize
[ "$OUT" = $'UNLABEL complexity:L\nUNSET story.complexidade\nSTATUS complexity=absent' ] && ok "no facts at all + a recorded level → both removed (a level nobody computed is not kept)" || bad "finalize absent+level: '$OUT'"
runin "$(bead "complexity:S" '{"story.complexidade_fatos":"arquivos=dois superficies=1 externo=0 migracao=0","story.complexidade":"S"}')" finalize
case "$OUT" in *"UNLABEL complexity:S"*"UNSET story.complexidade"*"STATUS complexity=malformed:"*) ok "malformed facts + a recorded level → both removed" ;; *) bad "finalize malformed+level: '$OUT'" ;; esac
runin "$(bead "" '{"story.complexidade_fatos":"desconhecido: x"}')" finalize
[ "$OUT" = "STATUS complexity=unknown" ] && ok "desconhecido and nothing recorded → no UNSET (no write for a key the bead never had)" || bad "finalize unknown, nothing recorded: '$OUT'"
runin "$(bead "complexity:S" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f,"story.complexidade":"S"}')")" finalize
case "$OUT" in *UNSET*) bad "good facts must SET the level, not unset it: '$OUT'" ;; *) ok "good facts: the level is SET (overwritten), never unset" ;; esac
for badf in "arquivos=2 superficies=1 externo=0" "arquivos=2 superficies=1 externo=0 migracao=0 extra=1" "arquivos=2 arquivos=3 superficies=1 externo=0 migracao=0" \
            "arquivos=dois superficies=1 externo=0 migracao=0" "arquivos=0 superficies=1 externo=0 migracao=0" "arquivos=2 superficies=1 externo=talvez migracao=0" \
            "pequena, mexe em um arquivo" "arquivos 2 superficies 1"; do
  runin "$(bead "" "$(jq -nc --arg f "$badf" '{"story.complexidade_fatos":$f}')")" finalize
  case "$OUT" in *"STATUS complexity=malformed:"*) case "$OUT" in *SET*|*LABEL\ *) bad "malformed '$badf' still wrote a level: '$OUT'" ;; *) ok "malformed facts '$badf' → malformed, nothing written" ;; esac ;; *) bad "malformed '$badf' → '$OUT'" ;; esac
done
# the reads that can fail: bd show of an id it cannot find prints [] — "could not read the bead" is NOT "the bead has no complexity"
runin '[]' finalize;                [ "$OUT" = "STATUS complexity=unreadable" ] && ok "bd show → [] is unreadable, not absent" || bad "finalize []: '$OUT'"
runin '' finalize;                  [ "$OUT" = "STATUS complexity=unreadable" ] && ok "empty stdin is unreadable" || bad "finalize empty: '$OUT'"
runin 'not json' finalize;          [ "$OUT" = "STATUS complexity=unreadable" ] && ok "non-JSON is unreadable" || bad "finalize garbage: '$OUT'"
for m in '"a string"' '[1,2]' 'null' '7'; do
  runin "[{\"id\":\"ga-x\",\"labels\":[],\"metadata\":$m}]" finalize
  [ "$OUT" = "STATUS complexity=absent" ] && [ "$RC" = 0 ] && ok "non-object metadata ($m) is read as empty, no crash (a recent commit here was exactly this bug)" || bad "metadata=$m → '$OUT' rc=$RC"
done
runin '[{"id":"ga-x","metadata":{"story.complexidade_fatos":42}}]' finalize
[ "$OUT" = "STATUS complexity=absent" ] && ok "a non-string facts value is not parsed as facts" || bad "numeric facts: '$OUT'"

echo "== 6. check (audit of a finalized bead) =="
chk() { runin "$1" check; }
chk "$(bead "complexity:S" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f,"story.complexidade":"S"}')")"
[ "$OUT" = "ok level=S" ] && [ "$RC" = 0 ] && ok "consistent → ok level=S, exit 0" || bad "check ok: '$OUT' rc=$RC"
chk "$(bead "complexity:L" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f,"story.complexidade":"L"}')")"
[ "$RC" = 12 ] && case "$OUT" in "mismatch recorded=L recomputed=S") true ;; *) false ;; esac && ok "a level that disagrees with its own facts is a MISMATCH (exit 12)" || bad "check mismatch: '$OUT' rc=$RC"
chk "$(bead "complexity:L" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f}')")"
[ "$RC" = 12 ] && ok "label alone disagreeing with the facts is a mismatch too" || bad "label mismatch: '$OUT' rc=$RC"
chk "$(bead "complexity:S,complexity:M" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f,"story.complexidade":"S"}')")"
[ "$RC" = 11 ] && ok "two complexity labels → malformed (exit 11)" || bad "two labels: '$OUT' rc=$RC"
chk "$(bead "complexity:S" '{"story.complexidade":"S"}')"
[ "$RC" = 11 ] && ok "a level with no facts behind it → malformed (it was asserted, not computed)" || bad "level without facts: '$OUT' rc=$RC"
chk "$(bead "" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f}')")"
[ "$RC" = 11 ] && ok "facts that were never turned into a level → malformed (the finalize step did not run)" || bad "facts without level: '$OUT' rc=$RC"
chk "$(bead "" "$(jq -nc --arg f "$F" '{"story.complexidade_fatos":$f,"story.complexidade":"XL"}')")"
[ "$RC" = 11 ] && ok "level outside S/M/L → malformed" || bad "level XL: '$OUT' rc=$RC"
chk "$(bead "" '{}')";              [ "$RC" = 10 ] && [ "$OUT" = absent ] && ok "nothing recorded → absent (exit 10)" || bad "check absent: '$OUT' rc=$RC"
chk '[]';                           [ "$RC" = 13 ] && [ "$OUT" = unreadable ] && ok "bd show → [] → unreadable (exit 13), distinct from absent" || bad "check []: '$OUT' rc=$RC"
chk "$(bead "" '{"story.complexidade_fatos":"desconhecido: sem acesso"}')"
[ "$RC" = 14 ] && [ "$OUT" = unknown ] && ok "desconhecido → unknown (exit 14), distinct from absent and from ok" || bad "check unknown: '$OUT' rc=$RC"
chk "$(bead "complexity:S" '{"story.complexidade_fatos":"desconhecido: sem acesso","story.complexidade":"S"}')"
[ "$RC" = 12 ] && [ "$OUT" = "mismatch recorded=S recomputed=unknown" ] && ok "desconhecido next to a recorded level S → MISMATCH (12): the leftover is visible, not read as 'unknown'" || bad "check unknown+level: '$OUT' rc=$RC"
chk "$(bead "complexity:M" '{"story.complexidade_fatos":"desconhecido: sem acesso"}')"
[ "$RC" = 12 ] && ok "desconhecido next to a leftover LABEL alone is a mismatch too" || bad "check unknown+label: '$OUT' rc=$RC"
chk "$(bead "" '{"story.complexidade_fatos":"desconhecido: sem acesso","story.complexidade":"L"}')"
[ "$RC" = 12 ] && ok "desconhecido next to a leftover metadata level alone is a mismatch too" || bad "check unknown+meta: '$OUT' rc=$RC"
codes="$(printf '0 10 11 12 13 14' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')"; [ "$codes" = 6 ] && ok "the six outcomes have six different exit codes" || bad "exit codes collide"

echo "== 7. plancheck =="
plan() { jq -nc --arg p "$1" '[{id:"ga-p",labels:[],metadata:{"story.plano_tecnico":$p}}]'; }
FULL=$'ARQUIVOS: a.py — f()\nABORDAGEM:\n 1. muda f\nCASOS-LIMITE: leitura vazia vs falha\nTESTE QUE REPROVA: t_f falha no HEAD\nNAO VERIFIQUEI: nada'
runin "$(plan "$FULL")" plancheck;                      [ "$OUT" = ok ] && ok "a complete plan → ok" || bad "plancheck full: '$OUT'"
runin "$(bead "" '{}')" plancheck;                     [ "$OUT" = absent ] && ok "no plan → absent" || bad "plancheck none: '$OUT'"
runin "$(plan "   ")" plancheck;                         [ "$OUT" = absent ] && ok "a whitespace-only plan → absent (an empty shell is not a plan)" || bad "plancheck blank: '$OUT'"
runin "$(plan $'ARQUIVOS: a.py\nABORDAGEM: x')" plancheck
[ "$OUT" = "incomplete:CASOS-LIMITE(ausente),TESTE QUE REPROVA(ausente),NAO VERIFIQUEI(ausente)" ] && ok "missing sections are NAMED" || bad "plancheck missing: '$OUT'"
runin "$(plan $'ARQUIVOS: a.py\nABORDAGEM:\nCASOS-LIMITE: y\nTESTE QUE REPROVA: z\nNAO VERIFIQUEI: nada')" plancheck
[ "$OUT" = "incomplete:ABORDAGEM(vazia)" ] && ok "a heading with no text under it is 'vazia' — the check does what its comment says" || bad "plancheck empty section: '$OUT'"
runin "$(plan $'  ARQUIVOS: a\n  ABORDAGEM: b\n  CASOS-LIMITE: c\n  TESTE QUE REPROVA: d\n  NAO VERIFIQUEI: e')" plancheck
[ "$OUT" = ok ] && ok "indented headings are accepted" || bad "plancheck indented: '$OUT'"
runin "$(plan $'Veja ARQUIVOS: a, ABORDAGEM: b, CASOS-LIMITE: c, TESTE QUE REPROVA: d, NAO VERIFIQUEI: e (tudo numa linha)')" plancheck
case "$OUT" in incomplete:*) ok "headings buried in a sentence do not count (they must start a line)" ;; *) bad "plancheck inline mention accepted: '$OUT'" ;; esac

echo "== 8. the prompt block =="
newstate; conf planner_pct=100 complexity=on salt=t1
run block ga-b1 /store/x
B_BOTH="$OUT"
case "$B_BOTH" in *'bd -C "/store/x" update "ga-b1" --set-metadata "story.complexidade_fatos='*) ok "block names the real store and bead in the write-back command" ;; *) bad "block lacks the facts command" ;; esac
case "$B_BOTH" in *'story.plano_tecnico='*"ARQUIVOS:"*"NAO VERIFIQUEI:"*) ok "treated bead: block carries the plan instructions and the five headings" ;; *) bad "block lacks plan instructions" ;; esac
case "$B_BOTH" in *'--set-metadata "story.complexidade='*) bad "block tells the refiner to write a LEVEL (it must write facts only)" ;; *) ok "block never asks the refiner for a level — facts only" ;; esac
case "$B_BOTH" in *"never change your REFINE-vs-ESCALATE"*) ok "block says it does not change the REFINE/ESCALATE decision" ;; *) bad "block lacks the no-decision-change clause" ;; esac
case "$B_BOTH" in *"READ-ONLY"*"external API"*"do not edit any file"*) ok "block forbids running the code / calling external APIs (the research-only trap: ga-1udgm)" ;; *) bad "block lacks the read-only clause" ;; esac
case "$B_BOTH" in *'$('*|*'`'*) bad "block contains shell metacharacters that could expand in the heredoc" ;; *) ok "block has no \$( or backtick" ;; esac
newstate; conf planner_pct=0 complexity=on salt=t1
run block ga-b2 /store/x
case "$OUT" in *"story.complexidade_fatos"*) case "$OUT" in *"TECHNICAL PLAN"*) bad "control bead got the plan" ;; *) ok "control arm: complexity facts only, NO plan (the control is the refiner as it is today + the measurement field)" ;; esac ;; *) bad "control block lacks the facts instructions: '${OUT:0:80}'" ;; esac
newstate; conf planner_pct=100 complexity=off salt=t1
run block ga-b3 /store/x
case "$OUT" in *"TECHNICAL PLAN"*) case "$OUT" in *"COMPLEXITY FACTS"*) bad "complexity=off but facts asked" ;; *) ok "complexity=off: plan only" ;; esac ;; *) bad "plan-only block missing the plan" ;; esac
run block "" /store/x; [ -z "$OUT" ] && [ "$RC" = 2 ] && ok "block with no bead id → nothing, exit 2" || bad "block empty id: out=${#OUT} rc=$RC"

echo
echo "e9-arms selftest: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
