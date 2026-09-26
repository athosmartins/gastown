#!/usr/bin/env bash
# nudge-queue-hygiene.selftest.sh — ga-aijm2v.5 (rule 2).
#
# Runs nudge-queue-hygiene.py against a SANDBOX queue (never the live one) with a
# canned `gc session list` document, so it needs no gc, no city, no network.
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYG="${NQH_SCRIPT_UNDER_TEST:-$SELF_DIR/nudge-queue-hygiene.py}"   # override = mutation checks

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

SBX="$(mktemp -d -t nudge-queue-hygiene-selftest)" || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$SBX"' EXIT

ZERO="0001-01-01T00:00:00Z"
WARN="check for assigned work"
# item <id> <agent> <session_id> <message> <created_at> [claimed-lease]
item() {
  jq -cn --arg id "$1" --arg ag "$2" --arg sid "$3" --arg msg "$4" --arg cr "$5" --arg z "$ZERO" --arg lease "${6:-$ZERO}" \
    '{id:$id, agent:$ag, session_id:$sid, continuation_epoch:"1", source:"session", message:$msg,
      created_at:$cr, deliver_after:$cr, expires_at:"2099-01-01T00:00:00Z",
      last_attempt_at:$z, claimed_at:$z, lease_until:$lease, dead_at:$z}'
}
# sessions doc: names of the LIVE sessions (plus one closed one)
sessions() {
  local first=1 out='{"ok":true,"sessions":['
  for n in "$@"; do
    [ "$first" = 1 ] || out="$out,"; first=0
    out="$out{\"id\":\"id-$n\",\"name\":\"$n\",\"alias\":\"$n\",\"agent_name\":\"$n\",\"session_name\":\"$n\",\"state\":\"active\",\"closed\":false}"
  done
  echo "$out,{\"id\":\"id-closed\",\"name\":\"closed-one\",\"state\":\"closed\",\"closed\":true}]}"
}
# new_case <name> ; then write $Q/state.json and $SBX/<name>.sessions.json
new_case() { Q="$SBX/$1/nudges"; mkdir -p "$Q"; : > "$Q/state.lock"; SF="$SBX/$1.sessions.json"; }
put_state() { # stdin: pending items (json lines) ; $1: extra top-level json object to merge
  local extra="${1:-}"; [ -n "$extra" ] || extra='{}'   # (a ${1:-{}} default keeps a stray backslash in bash 3.2)
  jq -s --argjson extra "$extra" '{pending: .} + $extra' > "$Q/state.json"
}
hyg() { python3 "$HYG" --queue-dir "$Q" --sessions-file "$SF" --city "$SBX" "$@"; }
pids() { jq -r "$1" "$Q/state.json" | sort | tr '\n' ' ' | sed 's/ $//'; }

echo "== 1. dedupe: one pending warning per (agent, session_id); the NEWEST survives"
new_case c1
sessions gastown.dog-1 > "$SF"
{ item w1 gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00.000000Z
  item w2 gastown.dog-1 s1 "$WARN" 2026-09-25T11:00:00.000000Z
  item w3 gastown.dog-1 s1 "$WARN" 2026-09-25T12:00:00.000000Z; } | put_state
hyg --apply >/dev/null
eq "pending keeps only the newest" "$(pids '.pending[].id')" "w3"
eq "the two older ones are dead-lettered" "$(pids '.dead[].id')" "w1 w2"
eq "reason is the engine's terminal classification" "$(jq -r '[.dead[].last_error]|unique|join(",")' "$Q/state.json")" "superseded"
eq "dead_at is stamped" "$(jq -r '[.dead[]|select(.dead_at|startswith("0001")|not)]|length' "$Q/state.json")" "2"

echo "== 2. items for a target that no longer exists are dead-lettered; live and closed sessions are told apart"
new_case c2
sessions gastown.dog-1 > "$SF"
{ item live gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z
  item gone wa-worker-adhoc-dead sX "$WARN" 2026-09-25T10:00:00Z
  item closed closed-one id-closed "$WARN" 2026-09-25T10:00:00Z; } | put_state
hyg --apply >/dev/null
eq "only the live target keeps its reminder (a CLOSED session is gone too)" "$(pids '.pending[].id')" "live"
eq "gone + closed are dead-lettered" "$(pids '.dead[].id')" "closed gone"

echo "== 3. WORK is never touched: reviewer tasks / dispatch / feedback survive duplicates and gone sessions"
new_case c3
sessions gastown.dog-1 > "$SF"
{ item r1 gone-a sA "QUALITY GATE REVIEW — reviewer 1 of 1 for branch x" 2026-09-25T10:00:00Z
  item r2 gone-a sA "QUALITY GATE REVIEW — reviewer 1 of 1 for branch x" 2026-09-25T11:00:00Z
  item d1 gastown.dog-1 s1 "DISPATCH_TASK ga-1" 2026-09-25T10:00:00Z
  item d2 gastown.dog-1 s1 "DISPATCH_TASK ga-1" 2026-09-25T11:00:00Z
  item f1 gone-b sB "Your branch fix/x has passed gate" 2026-09-25T10:00:00Z; } | put_state
hyg --apply >/dev/null
eq "non-warning items all still pending" "$(pids '.pending[].id')" "d1 d2 f1 r1 r2"
eq "nothing dead-lettered" "$(jq '(.dead // [])|length' "$Q/state.json")" "0"

echo "== 4. claimed items and the in_flight bucket are left alone"
new_case c4
sessions gastown.dog-1 > "$SF"
{ item a gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z
  item b gastown.dog-1 s1 "$WARN" 2026-09-25T11:00:00Z 2026-09-25T13:00:00Z   # claimed (lease set)
  item c gastown.dog-1 s1 "$WARN" 2026-09-25T12:00:00Z; } | put_state "$(jq -cn --argjson i "$(item inflight gastown.dog-1 s1 "$WARN" 2026-09-25T09:00:00Z)" '{in_flight:[$i], future_key:{x:1}}')"
hyg --apply >/dev/null
eq "the claimed one is neither kept-as-newest nor moved; a is deduped against c" "$(pids '.pending[].id')" "b c"
eq "in_flight untouched" "$(jq -r '.in_flight[0].id' "$Q/state.json")" "inflight"
eq "unknown top-level keys survive the rewrite" "$(jq -r '.future_key.x' "$Q/state.json")" "1"

echo "== 5. 'cannot tell' is not 'gone': unusable session lookup disables ONLY the gone rule"
new_case c5
echo '{"ok":true,"sessions":[]}' > "$SF"      # implausible empty universe => unknown
{ item x1 gone-a sA "$WARN" 2026-09-25T10:00:00Z
  item x2 gone-a sA "$WARN" 2026-09-25T11:00:00Z
  item y1 other  sB "$WARN" 2026-09-25T10:00:00Z; } | put_state
OUT="$(hyg --apply)"
eq "lookup reported unknown" "$(echo "$OUT" | jq -r '.live_lookup')" "unknown"
eq "no item dropped as 'gone'; the duplicate still deduped" "$(pids '.pending[].id')" "x2 y1"
new_case c5b
echo 'not json' > "$SF"
{ item z1 nobody s "$WARN" 2026-09-25T10:00:00Z; } | put_state
hyg --apply >/dev/null
eq "an unparseable lookup keeps everything" "$(pids '.pending[].id')" "z1"

echo "== 6. no-op runs and dry runs do not rewrite the file"
new_case c6
sessions gastown.dog-1 > "$SF"
{ item a gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z; } | put_state
before="$(cksum < "$Q/state.json") $(stat -f '%i %m' "$Q/state.json")"
hyg --apply >/dev/null
eq "nothing to move => file byte-identical, same inode" "$(cksum < "$Q/state.json") $(stat -f '%i %m' "$Q/state.json")" "$before"
new_case c6b
sessions gastown.dog-1 > "$SF"
{ item a gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z; item b gastown.dog-1 s1 "$WARN" 2026-09-25T11:00:00Z; } | put_state
before="$(cksum < "$Q/state.json")"
OUT="$(hyg)"
eq "dry run reports the move" "$(echo "$OUT" | jq -r '.moved_dup')" "1"
eq "dry run leaves the file untouched" "$(cksum < "$Q/state.json")" "$before"

echo "== 7. the winner is chosen by real time, not by string order (fractional digits differ)"
new_case c7
sessions gastown.dog-1 > "$SF"
{ item early gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00.17967Z
  item late  gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00.179671Z; } | put_state
hyg --apply >/dev/null
eq "the .179671 item (later) wins although 'Z' sorts after '1'" "$(pids '.pending[].id')" "late"

echo "== 8. it takes the ENGINE's flock and reads state fresh under it"
new_case c8
sessions gastown.dog-1 > "$SF"
{ item a gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z; item b gastown.dog-1 s1 "$WARN" 2026-09-25T11:00:00Z; } | put_state
# A stand-in for the engine: holds LOCK_EX for 2 s and, while holding it, appends one more duplicate.
python3 - "$Q" <<'PY' &
import fcntl, json, sys, time
q = sys.argv[1]
with open(q + "/state.lock", "a+") as lk:
    fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
    time.sleep(2)
    st = json.load(open(q + "/state.json"))
    it = dict(st["pending"][0]); it["id"] = "c"; it["created_at"] = "2026-09-25T12:00:00Z"
    st["pending"].append(it)
    json.dump(st, open(q + "/state.json", "w"))
    fcntl.flock(lk.fileno(), fcntl.LOCK_UN)
PY
sleep 0.5
t0=$(date +%s)
hyg --apply >/dev/null
t1=$(date +%s)
wait
if [ $((t1 - t0)) -ge 1 ]; then ok "apply waited for the engine's lock ($((t1 - t0))s)"; else bad "apply did not wait for the lock held by the engine (took $((t1 - t0))s)"; fi
eq "it saw the item written UNDER the lock (only the newest of a,b,c left)" "$(pids '.pending[].id')" "c"

echo "== 9. fail-closed on an unrecognised shape / oversized plan"
new_case c9
sessions gastown.dog-1 > "$SF"
echo '{"pending":{"not":"a list"}}' > "$Q/state.json"
hyg --apply >/dev/null; rc=$?
eq "unrecognised shape exits 2" "$rc" "2"
eq "and leaves the file as it was" "$(jq -c . "$Q/state.json")" '{"pending":{"not":"a list"}}'
new_case c9b
sessions gastown.dog-1 > "$SF"
{ item a gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z; item b gastown.dog-1 s1 "$WARN" 2026-09-25T11:00:00Z; item c gastown.dog-1 s1 "$WARN" 2026-09-25T12:00:00Z; } | put_state
hyg --apply --max-moves 1 >/dev/null; rc=$?
eq "--max-moves guard exits 2" "$rc" "2"
eq "and moved nothing" "$(pids '.pending[].id')" "a b c"

echo "== 10. the sessions snapshot is read BEFORE the lock: only a warning OLDER than the snapshot can be 'gone'"
# A session created — and warned — while the (up to 90 s) lookup was running is absent from the snapshot although
# it is alive. created_at 2099 stands for "created after the snapshot began".
new_case c10
sessions gastown.dog-1 > "$SF"
{ item fresh brand-new-session sN "$WARN" 2099-01-01T00:00:00Z
  item old   wa-worker-adhoc-dead sX "$WARN" 2026-09-25T10:00:00Z; } | put_state
OUT="$(hyg --apply)"
eq "the orphan that predates the snapshot is dead-lettered, as before" "$(pids '.dead[].id')" "old"
eq "the warning newer than the snapshot is left pending" "$(pids '.pending[].id')" "fresh"
eq "and is reported as undecided, not silently kept" "$(echo "$OUT" | jq -r '.kept_undecided')" "1"
new_case c10b
sessions gastown.dog-1 > "$SF"
{ item nostamp ghost sG "$WARN" "not-a-date"
  item empty   ghost2 sH "$WARN" ""; } | put_state
OUT="$(hyg --apply)"
eq "a warning whose created_at cannot be read is never judged gone" "$(pids '.pending[].id')" "empty nostamp"
eq "both counted as undecided" "$(echo "$OUT" | jq -r '.kept_undecided')" "2"

echo "== 11. an unreadable created_at is never ranked in the dedupe (it used to sort as the epoch = always the OLDEST)"
new_case c11
sessions gastown.dog-1 > "$SF"
{ item a   gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z
  item bad gastown.dog-1 s1 "$WARN" "not-a-date"
  item b   gastown.dog-1 s1 "$WARN" 2026-09-25T11:00:00Z; } | put_state
hyg --apply >/dev/null
eq "the readable pair is deduped (b wins); the unreadable one is neither survivor nor casualty" "$(pids '.pending[].id')" "b bad"
new_case c11b
sessions gastown.dog-1 > "$SF"
{ item a   gastown.dog-1 s1 "$WARN" 2026-09-25T10:00:00Z
  item bad gastown.dog-1 s1 "$WARN" "not-a-date"; } | put_state
hyg --apply >/dev/null
eq "one readable + one unreadable: nothing can be ranked, nothing moves" "$(pids '.pending[].id')" "a bad"

echo "== 12. a state.json whose top level is not an object is 'unrecognised shape' (rc 2), not a traceback (rc 1)"
new_case c12
sessions gastown.dog-1 > "$SF"
echo '[1,2,3]' > "$Q/state.json"
OUT="$(hyg --apply 2>"$SBX/c12.err")"; rc=$?
eq "exit code 2" "$rc" "2"
eq "no Python traceback on stderr" "$(grep -c Traceback "$SBX/c12.err")" "0"
case "$(echo "$OUT" | jq -r '.error')" in *"top level is not an object"*) ok "the summary names the shape problem" ;; *) bad "summary does not name it: [$OUT]" ;; esac
eq "and the file is untouched" "$(jq -c . "$Q/state.json")" "[1,2,3]"

echo "== 13. an existing queue dir with NO state.json is an empty queue (said out loud); a missing DIR is a wrong path"
new_case c13
sessions gastown.dog-1 > "$SF"
OUT="$(hyg --apply)"; rc=$?
eq "apply: rc 0" "$rc" "0"
eq "apply: reported as an absent queue" "$(echo "$OUT" | jq -r '.queue // "-"')" "absent"
eq "apply: no state.json is invented" "$([ -e "$Q/state.json" ] && echo yes || echo no)" "no"
OUT="$(hyg)"; rc=$?
eq "dry run: rc 0 and reported the same way" "$rc:$(echo "$OUT" | jq -r '.queue // "-"')" "0:absent"
python3 "$HYG" --queue-dir "$SBX/no-such-dir/nudges" --sessions-file "$SF" --city "$SBX" --apply >/dev/null; rc=$?
eq "a MISSING queue dir (wrong --city) is an error, rc 2, in apply mode" "$rc" "2"
eq "and this script never creates the engine's directory" "$([ -e "$SBX/no-such-dir" ] && echo yes || echo no)" "no"
python3 "$HYG" --queue-dir "$SBX/no-such-dir/nudges" --sessions-file "$SF" --city "$SBX" >/dev/null; rc=$?
eq "and in dry-run mode" "$rc" "2"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
