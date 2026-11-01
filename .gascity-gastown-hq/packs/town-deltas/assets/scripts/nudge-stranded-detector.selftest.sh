#!/usr/bin/env bash
# nudge-stranded-detector.selftest.sh — ga-gj1jr7x.
#
# Runs nudge-stranded-detector.py against a SANDBOX queue with canned `ps` / tmux / `gc session list` documents and a
# fake `notify`, so it needs no gc, no city, no network and never pings anyone. Exit 0 iff every assertion holds.
#
# The three states the detector must keep apart are asserted separately, never as "alarm vs not alarm":
#   stranded (positive evidence: live session, no poller)  /  fine (poller alive, or session not live, ...)  /
#   cannot tell (a source could not be read) — which must be counted on its own line and must NOT be read as "fine".
#
# NSD_SCRIPT_UNDER_TEST=<path to a mutated copy> runs the whole battery against that copy (mutation checks: a battery
# that passes on a mutant proves nothing). The copy needs nudge-queue-hygiene.py next to it (it loads that by path).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NSD="${NSD_SCRIPT_UNDER_TEST:-$SELF_DIR/nudge-stranded-detector.py}"
WRAP="$SELF_DIR/nudge-stranded-detector.sh"
ORDER="$SELF_DIR/../../orders/nudge-stranded-detector.toml"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has()   { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: [$2] not found in $3"; fi; }
hasnt() { if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1: [$2] unexpectedly found in $3"; else ok "$1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }
[ -f "$NSD" ] || { echo "FATAL: $NSD not found"; exit 1; }

SBX="$(mktemp -d -t nsd-selftest.XXXXXX)" || { echo "FATAL: mktemp"; exit 1; }
HOLD=""
cleanup() { [ -n "$HOLD" ] && kill "$HOLD" 2>/dev/null; rm -rf "$SBX"; }
trap cleanup EXIT

CITY="$SBX/city"; OTHER="$SBX/other-city"; mkdir -p "$CITY" "$OTHER"
NOW="2026-11-01T12:00:00Z"
OLD="2026-11-01T11:30:00.000000Z"      # 30 min before NOW
YOUNG="2026-11-01T11:55:00.000000Z"    # 5 min
FUT="2026-11-01T12:30:00.000000Z"
PAST="2026-11-01T11:00:00.000000Z"
ZERO="0001-01-01T00:00:00Z"
TAB="$(printf '\t')"

# fake notify: logs one CALL line (the title) + the body; exits 1 while $NOTIFY_FAIL exists.  argv: -t TITLE -p 3 BODY
NOTIFY="$SBX/notify"
cat > "$NOTIFY" <<'EOF'
#!/bin/sh
{ printf 'CALL\t%s\n' "$2"; printf '%s\n' "$5"; } >> "$NOTIFY_LOG"
[ -e "$NOTIFY_FAIL" ] && exit 1
exit 0
EOF
chmod +x "$NOTIFY"

# ---- fixtures --------------------------------------------------------------------------------------------------
# item <id> <agent> <session_id> <created> [deliver_after] [lease_until] [expires_at]
item() {
  jq -cn --arg id "$1" --arg ag "$2" --arg sid "$3" --arg cr "$4" --arg da "${5:-$4}" --arg lease "${6:-$ZERO}" \
    --arg ex "${7:-2099-01-01T00:00:00Z}" --arg z "$ZERO" \
    '{id:$id, agent:$ag, session_id:$sid, continuation_epoch:"1", source:"session", message:"hello",
      created_at:$cr, deliver_after:$da, expires_at:$ex, last_attempt_at:$z, claimed_at:$z, lease_until:$lease, dead_at:$z}'
}
put_q() { jq -s '{pending: .}' > "$Q/state.json"; }
# a poller line as `ps -ax -ww -o pid=,stat=,command=` prints it (argv measured on the live city):
#   gc nudge poll --city <city> --session <session NAME> <session ID>
pl() { printf '%s %s /opt/homebrew/bin/gc nudge poll --city %s --session %s-name %s\n' "$1" "${4:-SN}" "${3:-$CITY}" "$2" "$2"; }
tm() { printf '%s-name\t%s\n' "$1" "$1"; }      # tmux seam line: <session_name> TAB <GC_SESSION_ID>
sess() {                                         # sess id:state:closed ...  -> a `gc session list --json` document
  local first=1 out='{"ok":true,"sessions":[' s i st cl
  for s in "$@"; do
    IFS=: read -r i st cl <<<"$s"
    [ "$first" = 1 ] || out="$out,"; first=0
    out="$out{\"id\":\"$i\",\"state\":\"$st\",\"closed\":$cl}"
  done
  echo "$out]}"
}
new_case() {
  CASE="$SBX/$1"; rm -rf "$CASE"; Q="$CASE/nudges"; mkdir -p "$Q"
  ST="$CASE/state"; PS="$CASE/ps.txt"; TM="$CASE/tmux.txt"; SE="$CASE/sessions.json"
  NOTIFY_LOG="$CASE/notify.log"; NOTIFY_FAIL="$CASE/notify.fail"; export NOTIFY_LOG NOTIFY_FAIL
  { echo "  1 Ss /sbin/launchd"; pl 90 s-other; echo " 91 S /usr/bin/ssh host"; } > "$PS"   # no poller for the test sids
  : > "$TM"                                                                              # tmux answers, knows nobody
  # $SE is NOT created: a missing canned file = that source FAILED (the seam's contract)
}
nsd() {
  OUT="$(python3 -B -I "$NSD" --city "$CITY" --queue-dir "$Q" --state-dir "$ST" --now "$NOW" --ps-file "$PS" \
        --tmux-file "$TM" --sessions-file "$SE" --notify-bin "$NOTIFY" "$@" 2>"$CASE/stderr")"; RC=$?
  grep -q Traceback "$CASE/stderr" 2>/dev/null && bad "python traceback: $(tail -1 "$CASE/stderr")"
  return 0
}
j() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
calls() { local n; n="$(grep -c '^CALL' "$NOTIFY_LOG" 2>/dev/null)"; echo "${n:-0}"; }
seen_ids() { jq -r '.alerted | keys | join(",")' "$ST/nudge-stranded-detector-seen.json" 2>/dev/null; }

echo "== 1. stranded: ONE alarm across sweeps, dedupe per nudge id, delivered ids pruned, the queue is never written"
new_case c1
item n1 a1 s1 "$OLD" | put_q
tm s1 > "$TM"
nsd --alarm
eq "rc" "$RC" 0
eq "pending" "$(j .pending)" 1
eq "stranded" "$(j .stranded)" 1
eq "the stranded id" "$(j '.stranded_items[0].id')" n1
eq "its age is reported from deliver_after" "$(j '.stranded_items[0].age_s')" 1800
eq "alarmed" "$(j '.alarmed|join(",")')" n1
eq "one notify" "$(calls)" 1
has "title carries the count" "CALL${TAB}Nudge preso sem poller (1)" "$NOTIFY_LOG"
has "body names id, agent and session" "n1 -> a1 (s1) ha 30min" "$NOTIFY_LOG"
eq "tmux settled liveness: no Dolt call (gc session list unused)" "$(j '.sources.gc_sessions // "unused"')" unused
nsd --alarm
eq "sweep 2: still stranded" "$(j .stranded)" 1
eq "sweep 2: already alerted" "$(j .already_alerted)" 1
eq "sweep 2: nothing new alarmed" "$(j '.alarmed|length')" 0
eq "sweep 2: still ONE notify in total" "$(calls)" 1
{ item n1 a1 s1 "$OLD"; item n2 a2 s2 "$OLD"; } | put_q
{ tm s1; tm s2; } > "$TM"
nsd --alarm
eq "sweep 3: a second stranded id alarms alone" "$(j '.alarmed|join(",")')" n2
eq "sweep 3: two notifies in total" "$(calls)" 2
hasnt "sweep 3: the body does not repeat n1" "n1 -> a1" <(tail -n 3 "$NOTIFY_LOG")
item n2 a2 s2 "$OLD" | put_q
nsd --alarm
eq "an id that left the queue is pruned from the seen-file" "$(seen_ids)" n2
item n1 a1 s1 "$OLD" | put_q
sum1="$(cksum < "$Q/state.json")"
nsd --alarm
eq "a re-appearing id alarms again (it was pruned)" "$(j '.alarmed|join(",")')" n1
eq "the queue file is byte-identical after the runs that did not rewrite it" "$(cksum < "$Q/state.json")" "$sum1"

echo "== 2. dry run (no --alarm): reports, but never notifies and never creates the state dir"
new_case c2
item n1 a1 s1 "$OLD" | put_q
tm s1 > "$TM"
nsd
eq "stranded is still reported" "$(j .stranded)" 1
eq "alarm flag is false" "$(j .alarm)" false
eq "no notify" "$(calls)" 0
[ ! -e "$ST" ] && ok "no state dir created" || bad "dry run created $ST"

echo "== 3. pollers: only a LIVE poller of THIS city that carries the item's session id counts"
new_case c3a; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"; pl 100 s1 >> "$PS"
nsd --alarm
eq "live poller for the session id = fine" "$(j .stranded)" 0
eq "counted as poller_alive" "$(j .fine.poller_alive)" 1
eq "no notify" "$(calls)" 0
new_case c3b; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"; pl 100 s1 "$OTHER" >> "$PS"
nsd; eq "another city's poller does not count" "$(j .stranded)" 1
new_case c3c; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"; pl 100 s1 "$CITY" Z >> "$PS"
nsd; eq "a zombie poller (stat Z) does not count" "$(j .stranded)" 1
new_case c3d; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
echo "103 SN /opt/homebrew/bin/gc nudge poll --city=$CITY --session a1-name s1" >> "$PS"
nsd; eq "--city=<path> form is attributed to the city" "$(j .stranded)" 0
new_case c3e; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
{ echo "104 SN /opt/homebrew/bin/gc nudge status s1"; echo "105 S vim s1"; echo "106 SN /opt/homebrew/bin/gc nudge poll --city $CITY --session a1-name s2"; } >> "$PS"
nsd; eq "a non-poll command or another session's poller that merely mentions the id does not count" "$(j .stranded)" 1
new_case c3f; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
echo "107 SN /opt/homebrew/bin/gc nudge poll --session a1-name s1" >> "$PS"
nsd; eq "a poller whose city cannot be attributed does not count (a false alarm is loud, a hidden nudge is not)" "$(j .stranded)" 1

echo "== 4. session liveness when tmux does not settle it: gc decides, and only an active, non-closed session is live"
new_case c4a
{ item s1i a1 s1 "$OLD"; item s2i a2 s2 "$OLD"; item s3i a3 s3 "$OLD"; item s4i a4 s4 "$OLD"; item s5i a5 s5 "$OLD"; } | put_q
sess s1:active:false s2:asleep:false s3:active:true s5:creating:false > "$SE"
nsd --alarm
eq "only the active, non-closed session is stranded (a remote-node session has no local pane)" "$(j '.stranded_items|map(.id)|join(",")')" s1i
eq "asleep / closed / unknown-to-gc / starting = not live = fine" "$(j .fine.session_not_live)" 4
eq "no cannot-tell" "$(j .cannot_tell)" 0
eq "gc was read" "$(j .sources.gc_sessions)" ok
new_case c4b; item n1 a1 s1 "$OLD" | put_q; rm -f "$TM"; sess s1:active:false > "$SE"
nsd
eq "tmux unreadable + gc says active = stranded (tmux silence is not 'gone')" "$(j .stranded)" 1
eq "the tmux failure is visible in sources" "$(j .sources.tmux)" fail

echo "== 5. age, due time, expiry and lease"
new_case c5
{ item young a1 s1 "$YOUNG"
  item future a2 s2 "$OLD" "$FUT"
  item expired a3 s3 "$OLD" "$OLD" "$ZERO" "$PAST"
  item leased a4 s4 "$OLD" "$OLD" "$FUT"
  item zerodue a5 s5 "$OLD" "$ZERO"
  item duerecent a6 s6 "$PAST" "$YOUNG"
  item edgeok a7 s7 "2026-11-01T11:50:00.000000Z"
  item edgeyoung a8 s8 "2026-11-01T11:50:01.000000Z"; } | put_q
{ for s in s1 s2 s3 s4 s5 s6 s7 s8; do tm $s; done; } > "$TM"
nsd
eq "pending" "$(j .pending)" 8
eq "stranded: zero deliver_after falls back to created_at, and exactly 10 min counts" "$(j '.stranded_items|map(.id)|sort|join(",")')" "edgeok,zerodue"
eq "young: created 5 min ago, due 5 min ago, and 9min59s" "$(j .fine.young)" 3
eq "not_due: deliver_after in the future" "$(j .fine.not_due)" 1
eq "expired: past expires_at" "$(j .fine.expired)" 1
eq "in_delivery: a running lease" "$(j .fine.in_delivery)" 1
eq "nothing cannot-tell" "$(j .cannot_tell)" 0

echo "== 6. CANNOT TELL is its own state: counted, alarmed on its own cooldown, never 'fine' and never 'stranded'"
new_case c6a
echo '{"pending": [ {"id": "x"' > "$Q/state.json"
nsd --alarm
eq "unparseable state.json: rc 2" "$RC" 2
eq "counted as cannot_tell" "$(j .cannot_tell)" 1
has "says why" "not valid JSON" <(printf '%s' "$OUT")
eq "never reported as stranded" "$(j '.stranded // 0')" 0
eq "a BLIND detector tells someone (it must not look like a quiet one)" "$(calls)" 1
has "the blind notify has its own title" "CALL${TAB}Detector de nudge preso: cego" "$NOTIFY_LOG"
nsd --alarm
eq "within the cooldown: no second blind notify" "$(calls)" 1
nsd --alarm --cannot-tell-cooldown-min 0
eq "after the cooldown: it says so again" "$(calls)" 2
new_case c6a2
item n1 a1 s1 "$OLD" | put_q
mkdir -p "$CASE/hygiene"; cp "$NSD" "$CASE/hygiene/nudge-stranded-detector.py"      # sibling nudge-queue-hygiene.py absent
OUT="$(python3 -B -I "$CASE/hygiene/nudge-stranded-detector.py" --city "$CITY" --queue-dir "$Q" --state-dir "$ST" --now "$NOW" \
      --ps-file "$PS" --tmux-file "$TM" --sessions-file "$SE" --notify-bin "$NOTIFY" --alarm 2>"$CASE/stderr")"; RC=$?
eq "no hygiene lib to parse timestamps: rc 2" "$RC" 2
eq "…and it says so out loud" "$(calls)" 1
new_case c6a3      # classify() itself crashes (a lib/item combination nobody foresaw): blind AND loud, never a bare traceback
item n1 a1 s1 "$OLD" "$OLD" BOOM | put_q; tm s1 > "$TM"
mkdir -p "$CASE/crash"; cp "$NSD" "$CASE/crash/nudge-stranded-detector.py"
cp "$(dirname "$NSD")/nudge-queue-hygiene.py" "$CASE/crash/nudge-queue-hygiene.py"
printf '\n_real_parse_ts = parse_ts\ndef parse_ts(value):\n    if value == "BOOM":\n        raise RuntimeError("boom")\n    return _real_parse_ts(value)\n' >> "$CASE/crash/nudge-queue-hygiene.py"
OUT="$(python3 -B -I "$CASE/crash/nudge-stranded-detector.py" --city "$CITY" --queue-dir "$Q" --state-dir "$ST" --now "$NOW" \
      --ps-file "$PS" --tmux-file "$TM" --sessions-file "$SE" --notify-bin "$NOTIFY" --alarm 2>"$CASE/stderr")"; RC=$?
eq "classify crashed: rc 2 (no traceback exit)" "$RC" 2
has "…the summary says what crashed" "classify crashed: RuntimeError: boom" <(printf '%s' "$OUT")
eq "…the whole queue is counted as undecided" "$(j .cannot_tell)" 1
eq "…and it says so out loud (one blind notify)" "$(calls)" 1
has "…with the blind title" "CALL${TAB}Detector de nudge preso: cego" "$NOTIFY_LOG"
eq "…and nothing was reported stranded" "$(j '.stranded // 0')" 0

echo "== 6b. queue shapes: empty is empty, unreadable is unreadable"
for shape in 'ABSENT' 'ZERO' '{"pending":null}' '{}' 'null' '{"pending":[]}'; do
  new_case c6b
  case "$shape" in ABSENT) ;; ZERO) : > "$Q/state.json" ;; *) printf '%s' "$shape" > "$Q/state.json" ;; esac
  nsd --alarm
  eq "empty queue [$shape]: rc 0, pending 0, no notify" "$RC/$(j .pending)/$(calls)" "0/0/0"
done
for shape in '[]' '{"pending":"x"}' '{"pending":{"a":1}}' '"str"' '42'; do
  new_case c6b
  printf '%s' "$shape" > "$Q/state.json"
  nsd --alarm
  eq "unrecognised shape [$shape]: rc 2, cannot_tell, blind notify" "$RC/$(j .cannot_tell)/$(calls)" "2/1/1"
done
new_case c6b; rm -rf "$Q"
nsd --alarm
eq "queue dir missing: rc 2 and a blind notify" "$RC/$(j .cannot_tell)/$(calls)" "2/1/1"

echo "== 6c. ps unreadable: not 'no poller' (that would be a false alarm), not 'poller alive' (that would hide one)"
new_case c6c; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"; rm -f "$PS"
nsd --alarm
eq "rc 2" "$RC" 2
eq "reason ps-unreadable" "$(j '.cannot_tell_reasons["ps-unreadable"]')" 1
eq "not stranded" "$(j .stranded)" 0
eq "not fine" "$(j '.fine|length')" 0
eq "one blind notify, none for a stranded nudge" "$(calls)" 1
new_case c6c2; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"; : > "$PS"
nsd; eq "ps that prints nothing (it always lists itself) is unreadable" "$(j '.cannot_tell_reasons["ps-unreadable"]')" 1

echo "== 6d. liveness unreadable: not 'session gone'"
new_case c6d1; item n1 a1 s1 "$OLD" | put_q
nsd --alarm
eq "tmux silent + gc unreadable: cannot tell" "$RC/$(j '.cannot_tell_reasons["liveness-unreadable"]')/$(j .stranded)/$(j '.fine|length')" "2/1/0/0"
new_case c6d2; item n1 a1 s1 "$OLD" | put_q; echo '{"ok":true,"sessions":[]}' > "$SE"
nsd; eq "an empty universe of sessions is not 'every session is gone'" "$(j '.cannot_tell_reasons["liveness-unreadable"]')" 1
new_case c6d3; item n1 a1 s1 "$OLD" | put_q; echo 'not json' > "$SE"
nsd; eq "gc output that is not JSON is unreadable" "$(j '.cannot_tell_reasons["liveness-unreadable"]')" 1

echo "== 6e. malformed items are counted, not dropped"
new_case c6e
{ echo '{"agent":"noid","session_id":"s1","created_at":"'"$OLD"'"}'
  echo '"just a string"'
  item nosid a2 "" "$OLD"
  item nots a3 s3 "$ZERO" "$ZERO"; } | put_q
tm s3 > "$TM"
nsd
eq "reasons" "$(j '.cannot_tell_reasons|to_entries|map("\(.key)=\(.value)")|join(",")')" "malformed-item=2,no-session-id=1,no-timestamp=1"
eq "rc 2, nothing stranded, nothing fine" "$RC/$(j .stranded)/$(j '.fine|length')" "2/0/0"

echo "== 6f. mixed queue: the stranded one alarms, the blind part is reported separately"
new_case c6f
{ item n1 a1 s1 "$OLD"; item nosid a2 "" "$OLD"; } | put_q
tm s1 > "$TM"
nsd --alarm
eq "rc 2 (something undecided), one stranded, one cannot-tell" "$RC/$(j .stranded)/$(j .cannot_tell)" "2/1/1"
eq "two notifies: the stranded one and the blind one" "$(calls)" 2
has "stranded alarm" "CALL${TAB}Nudge preso sem poller (1)" "$NOTIFY_LOG"
has "blind alarm" "CALL${TAB}Detector de nudge preso: cego" "$NOTIFY_LOG"

echo "== 7. an alarm that was not delivered is not recorded as sent"
new_case c7
item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
: > "$NOTIFY_FAIL"
nsd --alarm
eq "notify exits 1: rc 3" "$RC" 3
eq "summary says the notify failed" "$(j .notify)" failed
eq "nothing alarmed" "$(j '.alarmed|length')" 0
eq "not recorded in the seen-file" "$(seen_ids)" ""
rm -f "$NOTIFY_FAIL"
nsd --alarm
eq "next sweep retries and succeeds" "$RC/$(j '.alarmed|join(",")')" "0/n1"
eq "two attempts in total" "$(calls)" 2
nsd --alarm
eq "and then it is quiet" "$(calls)" 2
new_case c7b; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
nsd --alarm --notify-bin "$SBX/does-not-exist"
eq "notify binary missing: rc 3, not recorded" "$RC/$(j '.alarmed|length')/$(seen_ids)" "3/0/"
new_case c7c; item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
mkdir -p "$ST"; echo 'garbage {' > "$ST/nudge-stranded-detector-seen.json"
nsd --alarm
eq "a corrupt seen-file costs at most one repeated alarm, and is healed" "$(j '.alarmed|join(",")')/$(seen_ids)" "n1/n1"

echo "== 8. an item delivered between the first read and the ps/tmux reads is dropped; an unreadable re-read is cannot-tell"
mkdir -p "$SBX/bin"
cat > "$SBX/bin/tmux" <<'EOF'
#!/bin/sh
# fake tmux: while answering `list-sessions` it changes the queue file ($FAKE_QFILE <- $FAKE_QCONTENT), i.e. the
# poller delivered the nudge and exited right after the detector's first read.
case "$*" in
  *list-sessions*) printf '%s' "$FAKE_QCONTENT" > "$FAKE_QFILE"; echo fake-session ;;
  *show-environment*) echo "GC_SESSION_ID=s1" ;;
esac
EOF
chmod +x "$SBX/bin/tmux"
new_case c8a; item n1 a1 s1 "$OLD" | put_q
export FAKE_QFILE="$Q/state.json" FAKE_QCONTENT='{"pending":[]}'
OUT="$(PATH="$SBX/bin:$PATH" python3 -B -I "$NSD" --city "$CITY" --queue-dir "$Q" --state-dir "$ST" --now "$NOW" \
      --ps-file "$PS" --sessions-file "$SE" --notify-bin "$NOTIFY" --alarm 2>"$CASE/stderr")"; RC=$?
eq "delivered meanwhile: not stranded, resolved_during_run 1, no notify" "$RC/$(j .stranded)/$(j .resolved_during_run)/$(calls)" "0/0/1/0"
new_case c8b; item n1 a1 s1 "$OLD" | put_q
export FAKE_QFILE="$Q/state.json" FAKE_QCONTENT='{"pending": [ {'
OUT="$(PATH="$SBX/bin:$PATH" python3 -B -I "$NSD" --city "$CITY" --queue-dir "$Q" --state-dir "$ST" --now "$NOW" \
      --ps-file "$PS" --sessions-file "$SE" --notify-bin "$NOTIFY" --alarm 2>"$CASE/stderr")"; RC=$?
eq "re-read fails: cannot tell (reread-failed), not stranded" "$RC/$(j .stranded)/$(j '.cannot_tell_reasons["reread-failed"]')" "2/0/1"
has "and the blind notify went out" "CALL${TAB}Detector de nudge preso: cego" "$NOTIFY_LOG"
unset FAKE_QFILE FAKE_QCONTENT

echo "== 9. single instance (ga-y0g5x): a second run while one holds the lock exits at once and does nothing"
new_case c9
item n1 a1 s1 "$OLD" | put_q; tm s1 > "$TM"
LOCK="$CASE/held.lock"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a+"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").write("held"); time.sleep(30)' \
  "$LOCK" "$CASE/held" &
HOLD=$!
i=0; while [ ! -e "$CASE/held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -e "$CASE/held" ] || bad "lock holder did not start"
nsd --alarm --lock-file "$LOCK"
eq "skipped, rc 0, no notify" "$RC/$(j .skipped)/$(calls)" "0/another instance is running/0"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""
nsd --alarm --lock-file "$LOCK"
eq "lock released: the next run works" "$RC/$(j .stranded)/$(calls)" "0/1/1"

echo "== 10. the order entrypoint runs the detector in alarm mode, in the state dir, with the pack's log"
new_case c10
mkdir -p "$CITY/.gc/nudges"; echo '{"pending":[]}' > "$CITY/.gc/nudges/state.json"
bash -n "$WRAP" && ok "wrapper parses" || bad "wrapper has a syntax error"
GC_CITY="$CITY" GC_PACK_STATE_DIR="$ST" NOTIFY_BIN="$NOTIFY" bash "$WRAP" > "$CASE/wrap.out" 2>"$CASE/wrap.err"; wrc=$?
eq "wrapper rc" "$wrc" 0
eq "it ran with --alarm (the lock file only exists in alarm mode)" "$([ -e "$ST/nudge-stranded-detector.lock" ] && echo yes || echo no)" yes
eq "it appended its summary to the pack log" "$(jq -r '[.alarm,.pending,.rc]|map(tostring)|join(",")' "$ST/nudge-stranded-detector.jsonl" 2>/dev/null)" "true,0,0"

echo "== 11. the order: cooldown well above the measured cost of one run (~8-9 s), exec exists"
python3 -I - "$ORDER" "$SELF_DIR" <<'EOF'
import os, re, sys
try:
    import tomllib
except ImportError:
    print("  - SKIP: tomllib unavailable (python < 3.11), order file not parsed")
    sys.exit(3)
path, scripts = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    o = tomllib.load(fh)["order"]
assert o["trigger"] == "cooldown", o["trigger"]
m = re.fullmatch(r"(\d+)([smh])", o["interval"])
assert m, "interval %r" % o["interval"]
secs = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)]
assert secs >= 120, "interval %ds is not comfortably above one run (8-9 s measured)" % secs
exe = o["exec"].replace("$PACK_DIR/assets/scripts/", "")
assert exe == "nudge-stranded-detector.sh", exe
assert os.access(os.path.join(scripts, exe), os.X_OK), "exec target is not executable"
EOF
case $? in 0) ok "order file is consistent" ;; 3) ;; *) bad "order file check failed (see above)" ;; esac

echo "== 12. detection-only: no bd call, no engine command that mutates"
hasnt "no bd call in the detector" '"bd"' "$NSD"
hasnt "never nudges or re-arms (no gc session nudge call)" '"session", "nudge"' "$NSD"

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
