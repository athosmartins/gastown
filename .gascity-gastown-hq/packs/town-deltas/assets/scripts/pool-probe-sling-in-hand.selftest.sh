#!/usr/bin/env bash
# pool-probe-sling-in-hand.selftest.sh — ga-b97dgq.
#
# The dog's probe (pool-probe.sh) must not hand out a sling wisp (metadata pilot.sling_for=<story>) whose story is already
# in live hands: on 16/10 an idle dog took the wisp ga-ue9qgi while dog-2 was building its story and spent a whole session
# finding out and closing the duplicate. pool-probe.selftest.sh cannot hold this proof: it compares the probe with the
# engine's text call for call, and the engine's text never asks about the story. This file runs only the script, behind a
# fake `bd` (ready / query / show) and a fake `gc` (session list), and pins the three states of the filter:
#   in hand   (assignee live in the roster, or a lease that has not run out)        -> the wisp is dropped
#   free/dead (no assignee, closed, or an assignee the readable roster does not list) -> the wisp is kept, silently
#   cannot tell (bd show failed, roster unreadable or empty with no live lease)      -> the wisp is kept and stderr says so
# plus: the filter runs before the oldest-pick (a duplicate that is the oldest must not hide the next wisp), it covers
# the ephemeral tier too, the roster is read once per tier answer however many wisps it holds, and a candidate without pilot.sling_for
# costs no bd show and no gc call, and a lib that is missing or corrupt leaves the engine's own answer (log line, silent
# stderr). Three textual MUTANTS (filter not wired in the script; "cannot tell" read as "dead" and a live lease ignored, both
# in pool-probe-sling-lib.sh) must each be caught.
# Needs bash, jq, sh. Exit 0 iff every check holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${PP_PROBE_UNDER_TEST:-$SELF_DIR/pool-probe.sh}"        # override = mutation checks
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
[ -f "$PROBE" ] || { echo "FATAL: probe not found: $PROBE"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-sling.XXXXXX")"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"' EXIT
FAKE="$TMP/bin"; FIX="$TMP/fix"; mkdir -p "$FAKE" "$FIX"

cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*)  key=tier1 ;;
  "ready --metadata-field gc.run_target="*) key=legacy ;;
  "query --json "*)                         key=ephemeral ;;
  "list --parent "*)                        printf '[]'; exit 0 ;;
  "show "*)  [ -f "$FIX/show-$2.json" ] && { cat "$FIX/show-$2.json"; exit 0; }; exit 1 ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
if [ -f "$FIX/$key.json" ]; then cat "$FIX/$key.json"; else printf '[]'; fi
EOF
cat > "$FAKE/gc" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$GC_LOG"
case " $* " in *" session list --json "*) ;; *) echo "fake gc: unexpected call: $*" >&2; exit 2 ;; esac
[ -f "$FIX/roster.fail" ] && exit 1
if [ -f "$FIX/roster.json" ]; then cat "$FIX/roster.json"; else printf '{"sessions":[]}'; fi
EOF
chmod +x "$FAKE/bd" "$FAKE/gc"

FUT="2100-01-01T00:00:00Z"; PAST="2001-09-09T01:46:40Z"
reset() { rm -f "$FIX"/*; }
wisp()  { jq -cn --arg id "$1" --arg st "$2" --arg u "$3" '{id:$id,title:("sling for "+$st),status:"open",updated_at:$u,labels:[],issue_type:"task",dependencies:[],metadata:{"gc.routed_to":"gastown.dog","pilot.sling_for":$st}}'; }
plain() { jq -cn --arg id "$1" --arg u "$2" '{id:$id,title:"plain bead",status:"open",updated_at:$u,labels:[],issue_type:"task",dependencies:[],metadata:{"gc.routed_to":"gastown.dog"}}'; }
# what `bd show --json` prints for a story: an array of one; no assignee key when there is none (bd omits empty keys)
story() { jq -cn --arg id "$1" --arg a "$2" --arg s "$3" --arg l "$4" '[{id:$id,status:$s} + (if $a=="" then {} else {assignee:$a} end) + (if $l=="" then {} else {lease_expires_at:$l} end)]'; }
roster() { printf '%s\n' "$@" | jq -R -s -c '{sessions: (split("\n")|map(select(length>0))|map({session_name:., name:., closed:false, state:"active"}))}'; }
tier1()  { printf '[%s]' "$(IFS=,; echo "$*")" > "$FIX/tier1.json"; }

# run — OUT / RC / ERR / IDS (ids of the answer, "-" for []) / SHOWS (bd show calls) / GCS (gc calls)
run() {
  : > "$TMP/bd.log"; : > "$TMP/gc.log"
  OUT="$(BD_LOG="$TMP/bd.log" GC_LOG="$TMP/gc.log" FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN=ephemeral \
         DISK_FREE_OVERRIDE_MB=100000 POOL_PROBE_LOG="$TMP/pp.log" GC_CITY_PATH="$TMP/city" sh "$PROBE" gastown.dog 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  IDS="$(printf '%s' "$OUT" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
  [ -z "$IDS" ] && IDS="-"
  SHOWS="$(grep -c '^show' "$TMP/bd.log" || true)"; GCS="$(wc -l < "$TMP/gc.log" | tr -d ' ')"
}
silent() { if [ -z "$ERR" ]; then ok "$1: nothing on stderr"; else bad "$1: unexpected stderr: ${ERR:0:200}"; fi; }
tells()  { if printf '%s' "$ERR" | grep -Eq "could not tell whether story $2 of sling $3 is in hand"; then ok "$1: stderr says it could not tell"; else bad "$1: stderr lacks the could-not-tell line — got: ${ERR:0:200}"; fi; }

# core <label> — the four decisions every mutant has to break at least one of; prints the failures it adds
core() {
  reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
  eq "$1 in hand (live session) -> dropped" "$IDS" "-"
  reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-9 in_progress "$FUT" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
  eq "$1 in hand (live lease, session not listed) -> dropped" "$IDS" "-"
  reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; : > "$FIX/roster.fail"; run
  eq "$1 roster unreadable, no lease -> kept (cannot tell)" "$IDS" "W1"
  [ -n "$ERR" ] && ok "$1 …and says so on stderr" || bad "$1 …but stderr is empty"
  reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 "" open "" > "$FIX/show-S1.json"; run
  eq "$1 story without assignee -> kept" "$IDS" "W1"
}

echo "== 1. the pair of the bead: story assigned to a live session + its wisp -> the wisp is not a candidate"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; roster dog-2 dog-5 > "$FIX/roster.json"; run
eq "answer" "$IDS" "-"; eq "exit code (a real 'nothing for you')" "$RC" "0"; silent "dropped wisp"
eq "bd show asked about the story" "$SHOWS" "1"

echo "== 2. control: the same wisp, story without assignee -> it enters"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 "" open "" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
eq "answer" "$IDS" "W1"; eq "exit code" "$RC" "0"; silent "free story"

echo "== 3. assignee provably dead (roster read, not listed, no lease) -> kept: the wisp re-dispatches the story"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-9 in_progress "" > "$FIX/show-S1.json"; roster dog-2 dog-5 > "$FIX/roster.json"; run
eq "answer" "$IDS" "W1"; silent "dead assignee"
echo "== 3b. …and with an EXPIRED lease it is the same"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-9 in_progress "$PAST" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
eq "answer" "$IDS" "W1"; silent "expired lease"

echo "== 4. a live lease is proof by itself (session not in the roster) -> dropped"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-9 in_progress "$FUT" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
eq "answer" "$IDS" "-"; silent "live lease"
echo "== 4b. …also when the roster cannot be read"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-9 in_progress "$FUT" > "$FIX/show-S1.json"; : > "$FIX/roster.fail"; run
eq "answer" "$IDS" "-"; silent "live lease, roster down"

echo "== 5. cannot tell -> kept, and stderr says so (the fail-open must be visible)"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; run                       # no show-S1.json: bd show fails
eq "bd show failed: answer" "$IDS" "W1"; eq "exit code" "$RC" "0"; tells "bd show failed" S1 W1
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; echo 'not json at all' > "$FIX/show-S1.json"; run
eq "bd show answered garbage: answer" "$IDS" "W1"; tells "garbage" S1 W1
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; : > "$FIX/roster.fail"; run
eq "roster unreadable, no lease: answer" "$IDS" "W1"; tells "roster down" S1 W1
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; run     # {"sessions":[]}: nobody alive is not an answer
eq "roster EMPTY, no lease: answer" "$IDS" "W1"; tells "empty roster" S1 W1
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-9 in_progress "tomorrow-ish" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
eq "lease that cannot be parsed + assignee not listed: answer" "$IDS" "W1"; tells "bad lease" S1 W1

echo "== 6. a closed story is not 'in hand' even with an assignee left on it"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 closed "" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"; run
eq "answer" "$IDS" "W1"; silent "closed story"

echo "== 7. a drained -adhoc- worker (asleep) is not a live builder; an asleep named crew still owns its build"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-adhoc-7 in_progress "" > "$FIX/show-S1.json"
echo '{"sessions":[{"session_name":"dog-adhoc-7","closed":false,"state":"asleep"},{"session_name":"dog-2","closed":false,"state":"active"}]}' > "$FIX/roster.json"; run
eq "asleep adhoc assignee: answer" "$IDS" "W1"; silent "asleep adhoc"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 mila-wa in_progress "" > "$FIX/show-S1.json"
echo '{"sessions":[{"session_name":"mila-wa","name":"mila-wa","closed":false,"state":"asleep"},{"session_name":"dog-2","closed":false,"state":"active"}]}' > "$FIX/roster.json"; run
eq "asleep named crew assignee: answer" "$IDS" "-"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"
echo '{"sessions":[{"session_name":"dog-2","closed":true,"state":"closed"},{"session_name":"dog-5","closed":false,"state":"active"}]}' > "$FIX/roster.json"; run
eq "closed session assignee: answer" "$IDS" "W1"

echo "== 8. the filter runs BEFORE the oldest-pick: the oldest wisp is the duplicate, the next one is real work"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)" "$(wisp W2 S2 2026-01-02T00:00:00Z)"
story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; story S2 "" open "" > "$FIX/show-S2.json"; roster dog-2 > "$FIX/roster.json"; run
eq "answer" "$IDS" "W2"; eq "bd show calls (one per wisp)" "$SHOWS" "2"; eq "gc session list calls (the roster is read once)" "$GCS" "1"
grep -q -- '--city' "$TMP/gc.log" && ok "gc is asked about the city (GC_CITY_PATH)" || bad "gc was not given --city"

echo "== 9. a candidate without pilot.sling_for costs no bd show and no gc call"
reset; tier1 "$(plain P1 2026-01-01T00:00:00Z)"; run
eq "answer" "$IDS" "P1"; eq "bd show calls" "$SHOWS" "0"; eq "gc calls" "$GCS" "0"; silent "plain bead"

echo "== 10. the ephemeral tier (3) is filtered too"
reset; jq -c -n --argjson w "$(wisp W3 S3 2026-01-01T00:00:00Z)" '[$w]' > "$FIX/ephemeral.json"
story S3 dog-2 in_progress "" > "$FIX/show-S3.json"; roster dog-2 > "$FIX/roster.json"; run
eq "answer" "$IDS" "-"; eq "bd show asked about the story" "$SHOWS" "1"
reset; jq -c -n --argjson w "$(wisp W3 S3 2026-01-01T00:00:00Z)" '[$w]' > "$FIX/ephemeral.json"; story S3 "" open "" > "$FIX/show-S3.json"; run
eq "control (free story): answer" "$IDS" "W3"

echo "== 10b. the lib missing or corrupt: the engine's own answer, a line in the pool-probe log, nothing on stderr"
reset; tier1 "$(wisp W1 S1 2026-01-01T00:00:00Z)"; story S1 dog-2 in_progress "" > "$FIX/show-S1.json"; roster dog-2 > "$FIX/roster.json"
: > "$TMP/pp.log"; export POOL_PROBE_SLING_LIB="$TMP/no-such-lib.sh"; run
eq "lib missing: answer (unfiltered, as the engine's probe)" "$IDS" "W1"; silent "lib missing"; eq "lib missing: bd show calls" "$SHOWS" "0"
grep -q 'sling filter lib missing or corrupt' "$TMP/pp.log" && ok "lib missing: the pool-probe log says the filter is off" || bad "lib missing: no line in the pool-probe log"
printf 'drop_slings_for_taken_stories() { if then fi\n' > "$TMP/corrupt-lib.sh"; export POOL_PROBE_SLING_LIB="$TMP/corrupt-lib.sh"; : > "$TMP/pp.log"; run
eq "lib corrupt: answer (unfiltered, the probe did not die)" "$IDS" "W1"; eq "lib corrupt: exit code" "$RC" "0"
grep -q 'sling filter lib missing or corrupt' "$TMP/pp.log" && ok "lib corrupt: the pool-probe log says the filter is off" || bad "lib corrupt: no line in the pool-probe log"
unset POOL_PROBE_SLING_LIB

# ---- mutants: the script (or its lib) with ONE literal replaced; each must break at least one decision of core() ----------------
echo "== 11. mutants of the script"
mutate() { # <source> <out> <literal old> <literal new>: no such literal (or more than one) = not a mutant = loud
  python3 -I -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[3])==1, "mutation site not found: "+sys.argv[3][:60]; open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))' "$1" "$2" "$3" "$4"
}
check_mutant() { # <name> <probe|lib> <literal old> <literal new>: ONE literal of the script, or of its lib, replaced
  local before_fail=$FAIL before_pass=$PASS saved="$PROBE" src
  if [ "$2" = lib ]; then src="$SELF_DIR/pool-probe-sling-lib.sh"; else src="$SELF_DIR/pool-probe.sh"; fi
  if ! mutate "$src" "$TMP/mut.sh" "$3" "$4" 2>"$TMP/mut.err"; then bad "mutant $1 could not be built: $(cat "$TMP/mut.err")"; return; fi
  if [ "$2" = lib ]; then export POOL_PROBE_SLING_LIB="$TMP/mut.sh"; else PROBE="$TMP/mut.sh"; export POOL_PROBE_SLING_LIB="$SELF_DIR/pool-probe-sling-lib.sh"; fi
  core "[$1]" > "$TMP/mut.out" 2>&1
  PROBE="$saved"; unset POOL_PROBE_SLING_LIB; FAIL=$before_fail; PASS=$before_pass
  if grep -q '^  ✗' "$TMP/mut.out"; then ok "mutant $1 is caught ($(grep -c '^  ✗' "$TMP/mut.out") check(s) fail)"; else bad "mutant $1 SURVIVED: no decision of core() noticed it"; fi
}
if [ -z "${PP_PROBE_UNDER_TEST:-}" ]; then
  check_mutant "filter not wired in tier 1" probe 't1_kept=$(printf "%s" "$t1_kept" | drop_slings_for_taken_stories)' 't1_kept=$(printf "%s" "$t1_kept")'
  check_mutant "cannot-tell read as dead"   lib   'elif $roster == null then "unreadable"' 'elif $roster == null then "dead"'
  check_mutant "live lease ignored"         lib   'if $lease == "live" then "hand"' 'if false then "hand"'
else
  echo "  ~ SKIP: mutants (PP_PROBE_UNDER_TEST is set)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
