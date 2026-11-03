#!/usr/bin/env bash
# pilot-dispatcher.open-children.selftest.sh — ga-vdac4cj.
#
# _filter_open_children (pilot-dispatcher.sh) is the Pilot's wall against dispatching a MOTHER whose work belongs to its children
# (E11 incident of 31/10: ga-hfx1kou, sliced into .1/.2, came back as a plain approved story while its slices sat in the gate; a
# builder was spent on it and refused it). "In hand" has ONE definition, scripts/children-in-hand-lib.sh, shared with the dog pool
# probe. pilot-dispatcher.selftest.sh (scenario 19m) proves the stage inside a real DRY_RUN sweep; this file pins the stage on its
# own, with the Pilot's own shell options (set -euo pipefail), the way pilot-dispatcher.exclusion-trace.selftest.sh does for the
# other stages (the function body is extracted from the real file, log() injected, a fake `bd` on PATH):
#   1. the three states: children in hand -> the mother is held back (WARN + EXCLUÍDO line, the other candidates untouched, order
#      kept); not in hand / no children -> kept, and the candidate array comes back BYTE FOR BYTE; unreadable (bd failed / printed
#      nothing / printed garbage) -> held back too, LOUDLY (inert, the opposite of the fail-open of _filter_unblocked);
#   2. the cost and the read: ONE `bd -C <db> list --json --limit 0` per call however many candidates (never `list --parent`, never a
#      per-candidate read), none when no candidate has an id; the candidate's `dependent_count` is NOT consulted (measured 31/10: bd's
#      list / ready rows do not count parent-child links - the real mother ga-hfx1kou says 0, `bd show` says 2 - so every fixture's mother
#      below carries dependent_count 0, as bd prints it);
#   3. degradation: lib not loaded, stdin empty / not JSON -> pass-through, exit 0; the drop that cannot be applied -> inert `[]` + WARN;
#   4. stdout stays pure JSON (every diagnostic goes to stderr) and the stage never fails the pipeline under `set -e`;
#   5. the lib sourcing block of the real file: loads a good lib, and a missing / corrupt / exiting lib is a WARN, not a dead Pilot;
#   6. structural guards on the real file: EVERY `_filter_explicit_deps "X"` in a chain is followed by `| _filter_open_children "X"` with
#      the same store argument (a new chain that forgets it fails here), and the lib is sourced before the first top-level chain;
#   7. textual MUTANTS of the stage must each be caught;
#   8. (gate round 1) "could not read" is not "found none": the unreadable branch leaves a MARK - a FILE, because the stage runs in a pipeline
#      and a variable dies with its subshell - that the readers of the sweep's sentence ask. Pinned here: when it is written (unreadable, and a drop
#      that cannot be applied; never for "in hand" or "none"), that it crosses the pipeline, the cap on per-bead lines, the helpers (count, damaged
#      lines, a mark that cannot be kept or read, the rig-scan fold) and the wiring of the readers (the tail of Step 2c, the emit, the rig scan,
#      the two resets). The sentences themselves are pinned by pilot-dispatcher.selftest.sh, scenario 19m.
# Needs bash, jq, python3. Exit 0 iff every check holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${OC_DISPATCHER_UNDER_TEST:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="$SELF_DIR/scripts/children-in-hand-lib.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 2; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found: $DISPATCHER"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-open-children.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"' EXIT
FAKE="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$FAKE" "$FIX"

extract_fn() { sed -n "/^$1() {/,/^}\$/p" "$2"; }
LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
FN="$(extract_fn _filter_open_children "$DISPATCHER")"
[ -n "$FN" ] || { echo "FATAL: _filter_open_children() not found in $DISPATCHER — has ga-vdac4cj landed?"; exit 2; }
WARN_FN="warn() { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: \$*\"; }"
MARK="$WORK/mark"
MARK_FNS="$(for f in _cih_mark_reset _cih_mark_unreadable _cih_unreadable_count _cih_fold_into_rig_scan; do extract_fn "$f" "$DISPATCHER"; done)"
[ "$(printf '%s\n' "$MARK_FNS" | grep -c '^_cih_[a-z_]*() {')" = 4 ] || { echo "FATAL: the unreadable-children mark helpers (4) not found in $DISPATCHER"; exit 2; }
MARK_FNS_UT="$MARK_FNS"      # the helpers the harnesses use; a helper MUTANT swaps this

# fake bd: logs argv; `[-C db] list --json --limit 0` answers store.{json,raw,fail,empty}, default `[]`. `list --parent` is NOT served.
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
if [ "$1" = "-C" ]; then shift 2; fi
[ "$1 $2 $3 $4" = "list --json --limit 0" ] || { echo "fake bd: unexpected call: $*" >&2; exit 2; }
[ -f "$FIX/store.fail" ]  && exit 1
[ -f "$FIX/store.empty" ] && exit 0
[ -f "$FIX/store.raw" ]   && { cat "$FIX/store.raw"; exit 0; }
[ -f "$FIX/store.json" ]  && { cat "$FIX/store.json"; exit 0; }
printf '[]'
EOF
chmod +x "$FAKE/bd"
REALJQ="$(command -v jq)"
reset() { rm -f "${FIX:?}"/*; : > "$WORK/bd.log"; }
# a store row for a child: child <id> <parent> <status> [label ...] (.parent AND the parent-child edge, as bd prints a child)
child() { local id="$1" par="$2" st="$3"; shift 3; local l; l="$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length>0))')"; jq -cn --arg id "$id" --arg par "$par" --arg st "$st" --argjson l "$l" '{id:$id,status:$st,parent:$par,labels:$l,dependent_count:0,dependencies:[{issue_id:$id,depends_on_id:$par,type:"parent-child"}]}'; }
arr()   { printf '[%s]' "$(IFS=,; echo "$*")"; }
# a candidate row as bd ready / bd list print it: dependent_count 0 whether or not the bead is a mother; "-" = no such field
cand()  { if [ "${2:-0}" = "-" ]; then jq -cn --arg id "$1" '{id:$id,title:"t",priority:1,status:"open"}'; else jq -cn --arg id "$1" --argjson d "${2:-0}" '{id:$id,title:"t",priority:1,status:"open",dependent_count:$d}'; fi; }
store() { arr "$@" > "$FIX/store.json"; }

# mk_harness <name> <with-lib 1|0> <fn-text>: a script that runs the stage under the Pilot's own shell options
mk_harness() {
  { echo 'set -euo pipefail'; echo "$LOG_FN"; echo "$WARN_FN"
    echo "PILOT_CIH_UNREADABLE_FILE=\"\${PILOT_CIH_UNREADABLE_FILE:-$MARK}\"; _CIH_MARK_BROKEN=\"\"; _CIH_LOG_IDS_MAX=5"
    printf '%s\n' "$MARK_FNS_UT"
    [ "$2" = 1 ] && echo ". \"$LIB\""
    printf '%s\n' "$3"
    echo '_cih_mark_reset'
    echo 'in="$(cat)"; printf "%s" "$in" | _filter_open_children "$1"; echo "<<rc=$?>>" >&2'
  } > "$WORK/$1.sh"
}
mk_harness h "1" "$FN"
mk_harness h-nolib "0" "$FN"
# run <harness> <stdin-json> [db]: OUT / ERRT / RC / READS (bd children reads)
run() {
  : > "$WORK/bd.log"
  OUT="$(printf '%s' "$2" | BD_LOG="$WORK/bd.log" FIX="$FIX" PATH="$FAKE:$PATH" bash "$WORK/$1.sh" "${3:-/db/city}" 2>"$WORK/err")"; RC=$?
  ERRT="$(cat "$WORK/err")"
  READS="$(grep -c . "$WORK/bd.log" || true)"
}
ids_of() { printf '%s' "$1" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null; }
rc_of_stage() { printf '%s' "$ERRT" | grep -o '<<rc=[0-9]*>>' | tail -1; }

echo "== 1. children in hand -> the mother is held back, the rest untouched and in order"
reset; store "$(child M.1 M open gate:queued)" "$(child M.2 M open gate:queued)"
IN="$(arr "$(cand A)" "$(cand M)" "$(cand B -)")"
run h "$IN"
eq "answer (the mother's own row says dependent_count 0)" "$(ids_of "$OUT")" "A,B"; eq "stage rc" "$(rc_of_stage)" "<<rc=0>>"
printf '%s' "$ERRT" | grep -q 'EXCLUÍDO M por _filter_open_children: filhas em mãos' && ok "EXCLUÍDO line names the bead, the filter and the reason" || bad "no EXCLUÍDO line: ${ERRT:0:300}"
printf '%s' "$ERRT" | grep -q 'WARN: holding M back in /db/city - its children are in hand' && ok "WARN line names the bead and the store" || bad "no WARN line: ${ERRT:0:300}"
eq "ONE bd read for the three candidates" "$READS" "1"
eq "…with the store: -C <db> list --json --limit 0" "$(tr '\037' ' ' < "$WORK/bd.log" | sed 's/ *$//')" "-C /db/city list --json --limit 0"
eq "stdout is pure JSON" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && echo yes || echo no)" "yes"

reset; store "$(child M.1 M in_progress)"
run h "$(arr "$(cand M)")"
eq "child in_progress: only the mother -> []" "$OUT" "[]"
reset; store "$(child M1.1 M1 open delivery:merged)" "$(child M2.1 M2 open gate:passed)"
run h "$(arr "$(cand M1)" "$(cand P)" "$(cand M2)")"
eq "two mothers in hand + a plain bead -> the plain bead" "$(ids_of "$OUT")" "P"
reset; store "$(child ga-hfx1kou.1 ga-hfx1kou closed gate:passed)" "$(child ga-hfx1kou.2 ga-hfx1kou open gate:queued)"
run h "$(arr "$(cand ga-hfx1kou)" "$(cand Z)")"
eq "the E11 shape (one slice closed, one in the gate): the mother is held" "$(ids_of "$OUT")" "Z"
reset; store "$(child X.1 X open gate:queued)"
run h "$(arr "$(cand M)")"
eq "another bead's child in the gate does not hold M" "$(ids_of "$OUT")" "M"
reset; arr '{"id":"M.1","status":"open","labels":["gate:queued"],"dependencies":[{"depends_on_id":"M","type":"parent-child"}]}' > "$FIX/store.json"
run h "$(arr "$(cand M)")"
eq "a child known only by its parent-child edge (no .parent) holds M" "$OUT" "[]"

echo "== 2. not in hand -> kept, and the candidate array comes back BYTE FOR BYTE"
reset; store "$(child M.1 M open)" "$(child M.2 M closed gate:queued)"
IN="$(arr "$(cand A)" "$(cand M)")"
run h "$IN"
eq "children merely ready / closed: output identical to input" "$OUT" "$IN"; eq "…and silent on stderr (rc line only)" "$ERRT" "<<rc=0>>"
reset
IN="$(arr "$(cand M)")"
run h "$IN"
eq "no children at all (bd answers []): identical" "$OUT" "$IN"; eq "…one read" "$READS" "1"

echo "== 3. unreadable -> held back too, LOUDLY (inert, not fail-open); the row cannot say which are mothers, so ALL are held"
for how in fail empty; do
  reset; : > "$FIX/store.$how"
  run h "$(arr "$(cand A)" "$(cand M)")"
  eq "bd $how: answer" "$OUT" "[]"; eq "bd $how: stage rc (never fails the pipeline)" "$(rc_of_stage)" "<<rc=0>>"
  printf '%s' "$ERRT" | grep -q 'EXCLUÍDO M por _filter_open_children: filhas ilegíveis' && ok "bd $how: EXCLUÍDO line says unreadable" || bad "bd $how: no EXCLUÍDO/ilegíveis line: ${ERRT:0:300}"
  printf '%s' "$ERRT" | grep -q 'EXCLUÍDO A por _filter_open_children: filhas ilegíveis' && ok "bd $how: …for A too" || bad "bd $how: A is not announced: ${ERRT:0:300}"
  printf '%s' "$ERRT" | grep -q 'WARN: holding M back .* could NOT be read' && ok "bd $how: WARN line says could NOT be read" || bad "bd $how: no WARN line: ${ERRT:0:300}"
done
reset; echo 'Error: dolt unreachable' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "garbage answer: held back" "$OUT" "[]"
reset; echo '{"error":"x"}' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "JSON object instead of the array: held back" "$OUT" "[]"
reset; echo '{"x":{"id":"M.1","status":"open","parent":"M","labels":["gate:queued"]}}' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "an object whose values are rows: held back" "$OUT" "[]"
reset; echo '[{"status":"open","parent":"M","labels":["gate:queued"]}]' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "a store row without an id: held back" "$OUT" "[]"
reset; echo '[7]' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "a store row that is not an object: held back" "$OUT" "[]"

echo "== 3b. unreadable leaves a MARK that crosses the pipeline (gate round 1): the readers of the sweep's sentence ask it"
mark_of() { if [ -s "$MARK" ]; then tr '\t' '~' < "$MARK" | tr '\n' '|'; else printf 'clean'; fi; }
for how in fail empty; do
  reset; : > "$FIX/store.$how"
  run h "$(arr "$(cand A)" "$(cand M)")"
  eq "bd $how: the mark names the store and counts the candidates held unread" "$(mark_of)" "/db/city~2|"
done
reset; echo 'Error: dolt unreachable' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "garbage answer: marked too" "$(mark_of)" "/db/city~1|"
reset; store "$(child M.1 M open gate:queued)"
run h "$(arr "$(cand M)")"
eq "children IN HAND is a verdict, not a doubt: no mark" "$(mark_of)" "clean"
reset; store "$(child M.1 M open)"
run h "$(arr "$(cand M)")"
eq "children read and none in hand: no mark" "$(mark_of)" "clean"
reset
run h "$(arr "$(cand M)")"
eq "no children at all (bd answers []): no mark" "$(mark_of)" "clean"
many=(); for i in $(seq 1 12); do many+=("$(cand "B$i")"); done
reset; : > "$FIX/store.fail"
run h "$(arr "${many[@]}")"
eq "twelve candidates unread: ONE mark line says 12" "$(mark_of)" "/db/city~12|"
eq "…the per-bead WARN lines are capped at 5" "$(printf '%s' "$ERRT" | grep -c 'WARN: holding B[0-9]* back')" "5"
printf '%s' "$ERRT" | grep -q 'WARN: holding 12 candidate(s) back in /db/city - their children could NOT be read' && ok "…and ONE summary line carries the count" || bad "no summary line with the count: ${ERRT:0:300}"
reset; : > "$FIX/store.fail"
{ echo 'set -euo pipefail'; echo "$LOG_FN"; echo "$WARN_FN"; echo "PILOT_CIH_UNREADABLE_FILE=\"$MARK\"; _CIH_MARK_BROKEN=\"\"; _CIH_LOG_IDS_MAX=5"; printf '%s\n' "$MARK_FNS_UT"; echo ". \"$LIB\""; printf '%s\n' "$FN"
  echo '_cih_mark_reset; in="$(cat)"; for d in /db/a /db/b; do printf "%s" "$in" | _filter_open_children "$d" >/dev/null; done; echo "count=$(_cih_unreadable_count)"'; } > "$WORK/h2.sh"
out="$(printf '%s' "$(arr "$(cand A)" "$(cand M)")" | BD_LOG="$WORK/bd.log" FIX="$FIX" PATH="$FAKE:$PATH" bash "$WORK/h2.sh" 2>/dev/null)"
eq "two stores in one sweep: the mark ADDS (2 + 2), and _cih_unreadable_count says so" "$(printf '%s' "$out" | tail -1)" "count=4"
eq "…one line per store" "$(mark_of)" "/db/a~2|/db/b~2|"
echo "   -- a mark that cannot be kept: the stage still holds back (inert), LOUDLY, and the readers say CANNOT TELL"
mkdir -p "$WORK/markdir"
reset; : > "$FIX/store.fail"
OUT="$(printf '%s' "$(arr "$(cand M)")" | PILOT_CIH_UNREADABLE_FILE="$WORK/markdir" BD_LOG="$WORK/bd.log" FIX="$FIX" PATH="$FAKE:$PATH" bash "$WORK/h.sh" /db/city 2>"$WORK/err")"; ERRT="$(cat "$WORK/err")"
eq "mark path is a directory: the answer is still []" "$OUT" "[]"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
printf '%s' "$ERRT" | grep -q 'cannot keep the unreadable-children mark' && ok "…the reset says the mark cannot be kept" || bad "…no 'cannot keep' WARN: ${ERRT:0:300}"
printf '%s' "$ERRT" | grep -q 'could not record the unreadable-children mark for /db/city' && ok "…and the stage says it could not record the unreadable read" || bad "…no 'could not record' WARN: ${ERRT:0:300}"

echo "== 3c. the helpers of the mark"
helper_checks() {  # prints a "  ✗" line per broken property; nothing when all hold. Uses MARK_FNS_UT (a helper mutant swaps it)
  local hc="$WORK/hc.sh" hf="$WORK/hf.sh" hr="$WORK/hr.sh" m="$WORK/hcmark" r
  { echo 'set -euo pipefail'; echo "$WARN_FN"; echo 'PILOT_CIH_UNREADABLE_FILE="$1"; _CIH_MARK_BROKEN="${2:-}"'; printf '%s\n' "$MARK_FNS_UT"
    echo 'if out=$(_cih_unreadable_count); then echo "rc=0 out=$out"; else echo "rc=$? out="; fi'; } > "$hc"
  { echo 'set -euo pipefail'; echo "$WARN_FN"; echo 'PILOT_CIH_UNREADABLE_FILE="$1"; _CIH_MARK_BROKEN=""'; printf '%s\n' "$MARK_FNS_UT"
    echo 'RIG_SCAN_UNREADABLE="${3:-}"; _cih_fold_into_rig_scan "$2"; echo "[$RIG_SCAN_UNREADABLE]"'; } > "$hf"
  { echo 'set -euo pipefail'; echo "$WARN_FN"; echo 'PILOT_CIH_UNREADABLE_FILE="$1"; _CIH_MARK_BROKEN=""'; printf '%s\n' "$MARK_FNS_UT"
    echo '_cih_mark_reset 2>/dev/null; echo "broken=${_CIH_MARK_BROKEN:-0}"; if out=$(_cih_unreadable_count); then echo "rc=0"; else echo "rc=1"; fi'; } > "$hr"
  chk() { [ "$2" = "$3" ] || echo "  ✗ $1: expected [$3], got [$2]"; }
  : > "$m";                                       r="$(bash "$hc" "$m" 2>&1)";  chk "an empty mark counts 0 (the reads were made)" "$r" "rc=0 out=0"
  printf '/db/a\t3\n' > "$m";                      r="$(bash "$hc" "$m" 2>&1)";  chk "one line counts its n" "$r" "rc=0 out=3"
  printf '/db/a\t2\n/db/b\t5\n' > "$m";            r="$(bash "$hc" "$m" 2>&1)";  chk "lines add up" "$r" "rc=0 out=7"
  printf 'garbage\n' > "$m";                       r="$(bash "$hc" "$m" 2>&1)";  chk "a line with no count counts 1 (something was held unread)" "$r" "rc=0 out=1"
  printf '/db/a\t0\n' > "$m";                      r="$(bash "$hc" "$m" 2>&1)";  chk "a zero count counts 1" "$r" "rc=0 out=1"
  printf '/db/a\tx\n' > "$m";                      r="$(bash "$hc" "$m" 2>&1)";  chk "a text count counts 1" "$r" "rc=0 out=1"
  printf '\n' > "$m";                              r="$(bash "$hc" "$m" 2>&1)";  chk "a blank line counts 1" "$r" "rc=0 out=1"
  r="$(bash "$hc" "$WORK/no-such-mark" 2>&1)";     chk "a missing mark is CANNOT TELL (rc 1), not 0" "$r" "rc=1 out="
  r="$(bash "$hc" "$WORK/markdir" 2>&1)";          chk "a directory is CANNOT TELL (rc 1)" "$r" "rc=1 out="
  : > "$m";                                       r="$(bash "$hc" "$m" 1 2>&1)"; chk "a mark flagged broken is CANNOT TELL even if the file is there" "$r" "rc=1 out="
  if [ "$(id -u)" != 0 ]; then : > "$m"; chmod 000 "$m"; r="$(bash "$hc" "$m" 2>&1)"; chmod 644 "$m"; chk "an unreadable mark file is CANNOT TELL" "$r" "rc=1 out="; fi
  printf '/db/a\t3\n' > "$m"
  r="$(bash "$hf" "$m" 0 2>&1)";                   chk "fold: 3 held during the scan -> the scan could not look at everything" "$r" "[the children of 3 candidate(s) could not be read]"
  r="$(bash "$hf" "$m" 1 2>&1)";                   chk "fold: only what was added DURING the scan counts (3 now, 1 before)" "$r" "[the children of 2 candidate(s) could not be read]"
  r="$(bash "$hf" "$m" 3 2>&1)";                   chk "fold: nothing added during the scan -> nothing to say" "$r" "[]"
  r="$(bash "$hf" "$m" 0 'gc rig list failed' 2>&1)"; chk "fold: the scan's own reason stays first" "$r" "[gc rig list failed]"
  r="$(bash "$hf" "$WORK/no-such-mark" 0 2>&1)";   chk "fold: a mark that can no longer be read means the scan could not look" "$r" "[the unreadable-children mark could not be read]"
  r="$(bash "$hr" "$WORK/not-a-dir-file/mark" 2>&1)"; chk "reset: a mark that cannot be kept is remembered and CANNOT TELL follows" "$r" "$(printf 'broken=1\nrc=1')"
  mkdir -p "$WORK/hrdir"; r="$(bash "$hr" "$WORK/hrdir/mark" 2>&1)"; chk "reset: a mark that can be kept is clean (0 counted)" "$r" "$(printf 'broken=0\nrc=0')"
}
: > "$WORK/not-a-dir-file"
hout="$(helper_checks)"
if [ -z "$hout" ]; then ok "the mark helpers: count, damaged lines, cannot-tell cases, rig fold and reset all behave"; else bad "mark helpers broken: $(printf '%s' "$hout" | head -5 | tr '\n' '|')"; fi

echo "== 4. the cost: ONE read per call, and the candidate's own row is not consulted"
reset
IN="$(arr "$(cand A 0)" "$(cand B -)" "$(cand C 7)")"
run h "$IN"
eq "dependent_count 0 / absent / 7: all looked up with ONE read, identical output" "$READS|$([ "$OUT" = "$IN" ] && echo same || echo changed)" "1|same"
eq "…nothing on stderr (rc line only)" "$ERRT" "<<rc=0>>"
reset
run h '[{"id":"A","dependent_count":"x"}]'
eq "non-numeric dependent_count: one read" "$READS" "1"
many=(); for i in $(seq 1 20); do many+=("$(cand "B$i")"); done
reset
run h "$(arr "${many[@]}")"
eq "twenty candidates: still ONE read" "$READS" "1"
reset
run h '[]'
eq "empty array: [] and no bd call" "$OUT|$READS" "[]|0"
reset
run h '[{"title":"no id"}]'
eq "a candidate without an id: untouched and no bd call" "$READS" "0"

echo "== 5. degradation: pass-through, never a dead pipeline"
reset; store "$(child M.1 M open gate:queued)"
IN="$(arr "$(cand M)")"
run h-nolib "$IN"
eq "lib not loaded: identical output (the Pilot as it was)" "$OUT" "$IN"; eq "…no bd call" "$READS" "0"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
run h ''
eq "empty stdin: []" "$OUT" "[]"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
run h 'not json at all'
eq "stdin not JSON: handed back untouched" "$OUT" "not json at all"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
echo "   -- the drop that cannot be applied: inert [] + WARN (never the unfiltered list)"
cat > "$FAKE/jq" <<EOF
#!/bin/sh
case "\$*" in *"--argjson held"*) exit 5 ;; esac
exec "$REALJQ" "\$@"
EOF
chmod +x "$FAKE/jq"
run h "$IN"
rm -f "$FAKE/jq"
eq "drop fails: answer is []" "$OUT" "[]"
printf '%s' "$ERRT" | grep -q 'could not apply its drop' && ok "…and the WARN says so" || bad "…no 'could not apply its drop' WARN: ${ERRT:0:300}"
eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
eq "…and every candidate of the call is MARKED unread (gone without a verdict = unknown, not none)" "$(mark_of)" "/db/city~1|"

echo "== 6. the lib sourcing block of the real file"
BLOCK="$(sed -n '/^_GC_CIH_SIBLING=/,/^unset _GC_CIH_SIBLING/p' "$DISPATCHER")"
[ -n "$BLOCK" ] || bad "sourcing block (_GC_CIH_SIBLING … unset) not found in the dispatcher"
mkdir -p "$WORK/pil/scripts"
{ echo 'set -euo pipefail'; echo 'warn() { echo "WARN: $*"; }'; printf '%s\n' "$BLOCK"
  echo 'if type children_in_hand_states >/dev/null 2>&1 && type children_candidate_ids >/dev/null 2>&1 && type children_state_of >/dev/null 2>&1; then echo "loaded"; else echo "not-loaded"; fi'
  echo 'echo "alive"'; } > "$WORK/pil/block.sh"
LIBDST="$WORK/pil/scripts/children-in-hand-lib.sh"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "lib missing: WARN, not loaded, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"
cp "$LIB" "$LIBDST"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "good lib: loaded, no WARN" "$(printf '%s' "$out" | tr '\n' '|')" "loaded|alive"
printf 'children_in_hand_states() { if then fi\n' > "$LIBDST"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "corrupt lib: WARN, not loaded, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"
printf 'exit 7\n' > "$LIBDST"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "lib that exits at source time: WARN, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"
chmod 000 "$LIBDST" 2>/dev/null
out="$(bash "$WORK/pil/block.sh" 2>&1)"; chmod 644 "$LIBDST" 2>/dev/null
if [ "$(id -u)" = 0 ]; then echo "  ~ SKIP: unreadable-lib case (root reads everything)"; else eq "unreadable lib: WARN, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"; fi

echo "== 7. structural guards on the real file"
# the script goes through a file: the mini's /bin/bash 3.2.57 mis-parses a heredoc with quotes in its body inside $( ) (bash -n: unexpected EOF, so gate-bash32 refuses the file); bash 5 accepts it
cat > "$WORK/guard.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
# code lines only (a comment may quote a chain)
code = [(i + 1, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
sites = []
for i, l in code:
    for m in re.finditer(r'\b_filter_explicit_deps ("[^"]*")(.*)$', l):
        sites.append((i, m.group(1), m.group(2)))
bad = [(i, a) for i, a, rest in sites if not re.match(r'\s*\| _filter_open_children ' + re.escape(a), rest)]
opens = sum(len(re.findall(r'\b_filter_open_children "[^"]*"', l)) for i, l in code)
print("sites=%d opens=%d missing=%s" % (len(sites), opens, ",".join("%d:%s" % x for x in bad) or "-"))
# the lib is sourced before the first TOP-LEVEL line that runs a chain (column 0 assignment of a *_JSON= $(echo ... | _filter_explicit_deps)
src_line = next((i for i, l in code if re.match(r'\s*source "\$_GC_CIH_SIBLING"', l)), 0)
first_top = next((i for i, l in code if re.match(r'^[A-Z_0-9]+=\$\(echo .*_filter_explicit_deps', l)), 0)
print("source=%d first_top_chain=%d" % (src_line, first_top))
PYEOF
GUARD="$(python3 -I "$WORK/guard.py" "$DISPATCHER")"
echo "   $(printf '%s' "$GUARD" | tr '\n' ' ')"
sites="$(printf '%s' "$GUARD" | sed -n 's/^sites=\([0-9]*\) opens=.*/\1/p')"; opens="$(printf '%s' "$GUARD" | sed -n 's/^sites=[0-9]* opens=\([0-9]*\) .*/\1/p')"
missing="$(printf '%s' "$GUARD" | sed -n 's/^.*missing=\(.*\)$/\1/p')"
[ "${sites:-0}" -ge 10 ] 2>/dev/null && ok "found the chains ($sites sites of _filter_explicit_deps)" || bad "found only ${sites:-0} chain sites — the guard's pattern drifted"
eq "every _filter_explicit_deps site is followed by _filter_open_children with the same store argument (missing)" "$missing" "-"
eq "…as many _filter_open_children sites as chains" "$opens" "$sites"
sl="$(printf '%s' "$GUARD" | sed -n 's/^source=\([0-9]*\) first_top_chain=.*/\1/p')"; ft="$(printf '%s' "$GUARD" | sed -n 's/^source=[0-9]* first_top_chain=\([0-9]*\)$/\1/p')"
if [ "${sl:-0}" -gt 0 ] && [ "${ft:-0}" -gt 0 ] && [ "$sl" -lt "$ft" ]; then ok "the lib is sourced (line $sl) before the first top-level chain (line $ft)"; else bad "lib source line ($sl) is not before the first top-level chain ($ft)"; fi
# the stage is defined before the sourcing block and after _filter_explicit_deps (functions are defined before the top-level calls)
fd="$(grep -n '^_filter_explicit_deps() {' "$DISPATCHER" | head -1 | cut -d: -f1)"; od="$(grep -n '^_filter_open_children() {' "$DISPATCHER" | head -1 | cut -d: -f1)"
[ -n "$fd" ] && [ -n "$od" ] && [ "$od" -gt "$fd" ] && ok "_filter_open_children is defined (line $od) after _filter_explicit_deps (line $fd)" || bad "definition order wrong ($fd / $od)"
echo "   -- the readers of the mark (gate round 1): a new reader that forgets it, or a lost reset, fails here"
tailb="$(awk '/^if \[ "\$ALL_CANDIDATES_COUNT" = "0" \]; then/{f=1} f{print} f&&/^  exit 0$/{exit}' "$DISPATCHER")"
if grep -q '_cih_unreadable_count' <<<"$tailb" && grep -q 'Candidates UNKNOWN: the children of' <<<"$tailb"; then ok "the tail of Step 2c asks the mark and has its own UNKNOWN sentence"; else bad "the tail of Step 2c does not ask the mark (an empty pool read as an empty queue)"; fi
[ "$(awk '/No dispatchable candidates/{f=1} f&&/^  fi$/{print "ok"; exit}' <<<"$tailb")" = ok ] && ok "…and the empty-queue sentence is in the branch that follows the UNKNOWN ones" || bad "…the empty-queue sentence is not the last branch of the tail"
emitb="$(extract_fn _pilot_emit_dispatchable "$DISPATCHER")"   # a variable, not a pipe: under pipefail a grep -q that quits early SIGPIPEs the sed and reads as a failure
grep -q '_cih_unreadable_count' <<<"$emitb" && ok "the emit asks the mark (no queue file from a partial read)" || bad "the emit does not ask the mark"
eq "the rig scan folds the mark at BOTH exits (override seam and real scan)" "$(extract_fn _scan_rig_fallback_pool "$DISPATCHER" | grep -c '^ *_cih_fold_into_rig_scan "\$_cih_b"$')" "2"
r1="$(grep -n '^_cih_mark_reset$' "$DISPATCHER" | head -1 | cut -d: -f1)"; r2="$(grep -n '^_cih_mark_reset$' "$DISPATCHER" | sed -n 2p | cut -d: -f1)"
em="$(grep -n '^_pilot_emit_dispatchable$' "$DISPATCHER" | head -1 | cut -d: -f1)"; b1="$(grep -n '^BUGS_JSON=\$(bd -C "\$GC_CITY" list --json' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$r1" ] && [ -n "$r2" ] && [ -n "$em" ] && [ -n "$b1" ] && [ "$r1" -lt "$em" ] && [ "$em" -lt "$r2" ] && [ "$r2" -lt "$b1" ]; then ok "the mark is reset before the emit (line $r1 < $em) and again before the dispatch queries (line $r2 < $b1)"; else bad "resets misplaced: reset1=$r1 emit=$em reset2=$r2 first-query=$b1"; fi
eq "exactly two top-level resets" "$(grep -c '^_cih_mark_reset$' "$DISPATCHER")" "2"

echo "== 8. mutants of the stage"
core() { # the decisions every mutant has to break at least one of; runs the mutant harness h-mut
  local o
  reset; store "$(child M.1 M open gate:queued)"; run h-mut "$(arr "$(cand A 0)" "$(cand M 0)")"
  [ "$(ids_of "$OUT")" = "A" ] || echo "  ✗ in hand is not dropped (mother row dependent_count 0): $(ids_of "$OUT")"
  reset; store "$(child M.1 M open)"; IN="$(arr "$(cand M 0)")"; run h-mut "$IN"
  [ "$OUT" = "$IN" ] || echo "  ✗ not in hand is not kept untouched"
  reset; : > "$FIX/store.fail"; run h-mut "$(arr "$(cand M 0)")"
  [ "$OUT" = "[]" ] || echo "  ✗ unreadable is not held back"
  printf '%s' "$ERRT" | grep -q 'ilegíveis' || echo "  ✗ unreadable is not announced"
  reset; store "$(child X.1 X open gate:queued)"; IN="$(arr "$(cand M 0)")"; run h-mut "$IN"
  [ "$OUT" = "$IN" ] || echo "  ✗ another bead's child holds M"
  reset; IN="$(arr "$(cand A 0)" "$(cand B -)" "$(cand C 7)")"; run h-mut "$IN"
  [ "$READS" = "1" ] || echo "  ✗ not exactly one read for three candidates (reads=$READS)"
  reset; store "$(child M.1 M open gate:queued)"; run h-mut "$(arr "$(cand M 0)")"
  printf '%s' "$ERRT" | grep -q 'EXCLUÍDO M por _filter_open_children: filhas em mãos' || echo "  ✗ the in-hand exclusion is not logged"
  printf '%s' "$ERRT" | grep -q 'WARN: holding M back' || echo "  ✗ the in-hand exclusion has no WARN"
  [ "$(tr '\037' ' ' < "$WORK/bd.log" | sed 's/ *$//')" = "-C /db/city list --json --limit 0" ] || echo "  ✗ the read does not go to the store (-C)"
  # the drop that cannot be applied: inert [], never the unfiltered list
  reset; store "$(child M.1 M open gate:queued)"
  printf '#!/bin/sh\ncase "$*" in *"--argjson held"*) exit 5 ;; esac\nexec "%s" "$@"\n' "$REALJQ" > "$FAKE/jq"; chmod +x "$FAKE/jq"
  run h-mut "$(arr "$(cand M 0)")"; rm -f "$FAKE/jq"
  [ "$OUT" = "[]" ] || echo "  ✗ a drop that cannot be applied hands the list on"
  [ "$(mark_of)" = "/db/city~1|" ] || echo "  ✗ a drop that cannot be applied leaves no mark"
  # the mark (gate round 1): unreadable writes it, "in hand" and "none" do not, and the per-bead lines are capped
  reset; : > "$FIX/store.fail"; run h-mut "$(arr "$(cand A 0)" "$(cand M 0)")"
  [ "$(mark_of)" = "/db/city~2|" ] || echo "  ✗ unreadable leaves no mark counting its candidates ($(mark_of))"
  reset; store "$(child M.1 M open gate:queued)"; run h-mut "$(arr "$(cand M 0)")"
  [ "$(mark_of)" = "clean" ] || echo "  ✗ children in hand marks the sweep unreadable ($(mark_of))"
  reset; : > "$FIX/store.fail"; run h-mut "$(arr "${many[@]}")"
  [ "$(printf '%s' "$ERRT" | grep -c 'WARN: holding B[0-9]* back')" = "5" ] || echo "  ✗ the per-bead WARN lines of an outage are not capped at 5"
}
mutate() { # <out> <literal old> <literal new>: no such literal (or more than one) = not a mutant = loud
  python3 -I -c 'import sys; s=sys.stdin.read(); assert s.count(sys.argv[1])==1, "mutation site not found: "+sys.argv[1][:60]; sys.stdout.write(s.replace(sys.argv[1], sys.argv[2]))' "$2" "$3" <<<"$FN" > "$1"
}
check_mutant() { # <name> <literal old> <literal new>
  local before_fail=$FAIL before_pass=$PASS
  if ! mutate "$WORK/mut-fn.txt" "$2" "$3" 2>"$WORK/mut.err"; then bad "mutant $1 could not be built: $(cat "$WORK/mut.err")"; return; fi
  mk_harness h-mut 1 "$(cat "$WORK/mut-fn.txt")"
  core > "$WORK/mut.out" 2>&1
  FAIL=$before_fail; PASS=$before_pass
  if grep -q '^  ✗' "$WORK/mut.out"; then ok "mutant $1 is caught ($(grep -c '^  ✗' "$WORK/mut.out") check(s) fail)"; else bad "mutant $1 SURVIVED: no decision of core() noticed it"; fi
}
if [ -z "${OC_DISPATCHER_UNDER_TEST:-}" ]; then
  mk_harness h-mut 1 "$FN"; core > "$WORK/base.out" 2>&1
  if grep -q '^  ✗' "$WORK/base.out"; then bad "core() fails on the real stage: $(grep '^  ✗' "$WORK/base.out" | head -3)"; else ok "core() passes on the real stage"; fi
  check_mutant "hand not dropped"                  '      hand)
        held_ids="$held_ids $bid"' '      hand)
        :'
  check_mutant "unreadable kept (fail-open)"       '      *)
        held_ids="$held_ids $bid"' '      *)
        :'
  check_mutant "read goes to the wrong store"      'children_in_hand_states "$db_dir"' 'children_in_hand_states ""'
  check_mutant "dependent_count fast path (first draft)" 'ids=$(printf '"'"'%s'"'"' "$arr" | children_candidate_ids) || ids=""' 'ids=$(printf '"'"'%s'"'"' "$arr" | jq -r '"'"'.[] | select((.dependent_count // 0) > 0) | .id'"'"') || ids=""'
  check_mutant "a missing verdict is kept"          'state=$(printf '"'"'%s\n'"'"' "$verdicts" | children_state_of "$bid") || state="unreadable"' 'state=$(printf '"'"'%s\n'"'"' "$verdicts" | children_state_of "$bid"); [ "$state" = unreadable ] && state=none'
  check_mutant "in-hand exclusion not logged"      'log "[pilot] EXCLUÍDO $bid por _filter_open_children: filhas em mãos (in_progress / gate / delivery) - o trabalho é das filhas" >&2' ':'
  check_mutant "unreadable not announced"          'log "[pilot] EXCLUÍDO $bid por _filter_open_children: filhas ilegíveis (bd falhou) - retido, não dispensado" >&2' ':'
  check_mutant "unreadable not marked"             '    _cih_mark_unreadable "$db_dir" "$unread_n"' '    :'
  check_mutant "in hand also marks the sweep"      '      hand)
        held_ids="$held_ids $bid"' '      hand)
        held_ids="$held_ids $bid"; unread_n=$((unread_n + 1))'
  check_mutant "drop failure not marked"           '    _cih_mark_unreadable "$db_dir" "${ids_n:-1}"' '    :'
  check_mutant "per-bead lines uncapped"           '        if [ "$unread_n" -le "${_CIH_LOG_IDS_MAX:-5}" ]; then' '        if true; then'
  check_mutant "drop failure hands the list on"    "    printf '[]'
    return 0
  fi
  printf '%s' \"\$filtered\"" "    printf '%s' \"\$arr\"
    return 0
  fi
  printf '%s' \"\$filtered\""
  # mutants of the HELPERS of the mark: each has to break at least one property helper_checks() pins
  check_mutant_h() { # <name> <literal old> <literal new>
    local before_fail=$FAIL before_pass=$PASS out
    MARK_FNS_UT="$(python3 -I -c 'import sys; s=sys.stdin.read(); assert s.count(sys.argv[1])==1, "mutation site not found: "+sys.argv[1][:60]; sys.stdout.write(s.replace(sys.argv[1], sys.argv[2]))' "$2" "$3" <<<"$MARK_FNS" 2>"$WORK/mut.err")" || { MARK_FNS_UT="$MARK_FNS"; bad "helper mutant $1 could not be built: $(cat "$WORK/mut.err")"; return; }
    out="$(helper_checks)"; MARK_FNS_UT="$MARK_FNS"
    FAIL=$before_fail; PASS=$before_pass
    if [ -n "$out" ]; then ok "helper mutant $1 is caught ($(printf '%s\n' "$out" | grep -c '^  ✗') check(s) fail)"; else bad "helper mutant $1 SURVIVED: no property of helper_checks() noticed it"; fi
  }
  check_mutant_h "a damaged line counts 0 (lenient)"       "if (\$2 ~ /^[0-9]+\$/ && \$2 + 0 > 0) s += \$2; else s += 1" "if (\$2 ~ /^[0-9]+\$/) s += \$2"
  check_mutant_h "a mark flagged broken counts 0"          '{ [ -z "${_CIH_MARK_BROKEN:-}" ] && [ -f "$PILOT_CIH_UNREADABLE_FILE" ] && [ -r "$PILOT_CIH_UNREADABLE_FILE" ]; } || return 1' '{ [ -f "$PILOT_CIH_UNREADABLE_FILE" ] && [ -r "$PILOT_CIH_UNREADABLE_FILE" ]; } || return 1'
  check_mutant_h "a missing mark counts 0"                 '{ [ -z "${_CIH_MARK_BROKEN:-}" ] && [ -f "$PILOT_CIH_UNREADABLE_FILE" ] && [ -r "$PILOT_CIH_UNREADABLE_FILE" ]; } || return 1' '{ [ -z "${_CIH_MARK_BROKEN:-}" ]; } || return 1; [ -f "$PILOT_CIH_UNREADABLE_FILE" ] || { printf 0; return 0; }'
  check_mutant_h "the fold counts the whole mark"          'RIG_SCAN_UNREADABLE="${RIG_SCAN_UNREADABLE:-the children of $((_a - _b)) candidate(s) could not be read}"' 'RIG_SCAN_UNREADABLE="${RIG_SCAN_UNREADABLE:-the children of ${_a} candidate(s) could not be read}"'
  check_mutant_h "the fold overwrites the scan reason"     'RIG_SCAN_UNREADABLE="${RIG_SCAN_UNREADABLE:-the children of' 'RIG_SCAN_UNREADABLE="${RIG_SCAN_UNREADABLE:+$RIG_SCAN_UNREADABLE; }the children of'
  check_mutant_h "an unreadable mark does not stop the scan" 'RIG_SCAN_UNREADABLE="${RIG_SCAN_UNREADABLE:-the unreadable-children mark could not be read}"' ':'
  check_mutant_h "a mark that cannot be kept is forgotten" '  _CIH_MARK_BROKEN=1
' '  :
'
else
  echo "  ~ SKIP: mutants (OC_DISPATCHER_UNDER_TEST is set)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
