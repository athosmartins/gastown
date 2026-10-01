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
# a roster that cannot be written must be LOUD, but must not take the arm away (the bead label is the second record)
newstate; conf planner_pct=100 salt=t1; mkdir "$SD/e9-roster.jsonl"
run assign ga-w1 /s
[ "$OUT" = on ] && case "$ERR" in *"NOT recorded"*) true ;; *) false ;; esac && ok "unwritable roster: the arm is still printed and stderr says the assignment was NOT recorded" || bad "unwritable roster: out='$OUT' err='$ERR'"

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
