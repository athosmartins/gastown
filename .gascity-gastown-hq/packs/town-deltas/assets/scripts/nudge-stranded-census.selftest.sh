#!/usr/bin/env bash
# nudge-stranded-census.selftest.sh — ga-9uv1xps.3.
#
# Runs nudge-stranded-census.py against SANDBOX state files (never the live .gc/nudges), with a canned `bd` and a fake `notify`:
# no gc, no city, no network, it never pings anyone. Exit 0 iff every assertion holds. NSC_CENSUS_UNDER_TEST points the run at a
# mutated copy (mutation checks): every guard below has a case that dies with its mutant.
# Outcomes are asserted apart, never as "alarm vs not alarm": ALARM (rc 1), CANNOT TELL (rc 2), CLEAN (rc 0), and a notice that
# notify could not deliver (rc 3). A census that is blind, or whose alarm reached nobody, must not look quiet.
set -uo pipefail
ulimit -f 204800 2>/dev/null || true   # a runaway write in a fixture stops at ~200 MB instead of filling the disk

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENSUS="${NSC_CENSUS_UNDER_TEST:-$SELF_DIR/nudge-stranded-census.py}"
WRAP="$SELF_DIR/nudge-stranded-census.sh"
ORDER="$SELF_DIR/../../orders/nudge-stranded-census.toml"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has()   { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: [$2] not found in $3"; fi; }
hasnt() { if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1: [$2] unexpectedly found in $3"; else ok "$1"; fi; }
says()  { case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $OUT" ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }
[ -f "$CENSUS" ] || { echo "FATAL: $CENSUS not found"; exit 1; }
SBX="$(mktemp -d "${TMPDIR:-/tmp}/nudge-stranded-census-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$SBX"' EXIT

NOW="2026-11-01T12:00:00Z"
SOON="2026-11-01T14:00:00.000000Z"     # 2 h after NOW
LATER="2026-11-02T08:00:00.000000Z"    # 20 h after NOW
UNK="please remember to rotate the vendor key before friday"
TAB="$(printf '\t')"

# fake 'bd show <ids...> --json' over $FAKE_BEADS {id: status}; like the real bd, ANY unknown id fails the whole call.
# $FAKE_BD_LOG gets one line per call (how many ids it asked). BD_MODE: ok | fail | slow (hangs) | badrow (a row whose id is a list)
export FAKE_BEADS="$SBX/beads.json" FAKE_BD_LOG="$SBX/bd-calls.log" FAKE_BD="$SBX/fake-bd.sh"
cat > "$FAKE_BD" <<'EOF'
#!/usr/bin/env bash
echo "$(( $# - 2 ))" >> "${FAKE_BD_LOG:-/dev/null}"
case "${BD_MODE:-ok}" in
  fail) echo "bd: boom" >&2; exit 1 ;;
  slow) exec sleep 20 ;;
  badrow) echo '[{"id":["not","a","string"],"status":"closed"}]'; exit 0 ;;
esac
[ "$1" = show ] || exit 2
shift; ids=(); for a in "$@"; do [ "$a" = --json ] || ids+=("$a"); done
out="[" ; first=1
for id in "${ids[@]}"; do
  st=$(jq -r --arg id "$id" '.[$id] // empty' "$FAKE_BEADS")
  [ -n "$st" ] || { echo '{"error":"no issues found matching the provided IDs"}'; exit 1; }
  [ "$st" = "-" ] && st=""   # "-" in beads.json = the bead EXISTS but its row carries no readable status
  [ $first = 1 ] || out="$out,"; first=0
  out="$out{\"id\":\"$id\",\"status\":\"$st\",\"issue_type\":\"session\"}"
done
echo "$out]"
EOF
# fake notify: logs one CALL line (the title) + the body; exits 1 while $NOTIFY_FAIL exists.  argv: -t TITLE -p 3 BODY
NOTIFY="$SBX/notify"
printf '%s\n' '#!/bin/sh' "{ printf 'CALL\\t%s\\n' \"\$2\"; printf '%s\\n' \"\$5\"; } >> \"\$NOTIFY_LOG\"" '[ -e "$NOTIFY_FAIL" ] && exit 1' 'exit 0' > "$NOTIFY"
chmod +x "$FAKE_BD" "$NOTIFY"

new_cen() {   # a fresh case: its own state file, ledger dir and notify log; one closed session bead
  CASE="$SBX/$1"; rm -rf "$CASE"; mkdir -p "$CASE"
  S="$CASE/state.json"; ST="$CASE/ledger"; NOTIFY_LOG="$CASE/notify.log"; NOTIFY_FAIL="$CASE/notify.fail"; export NOTIFY_LOG NOTIFY_FAIL
  echo '{"s-closed":"closed"}' > "$FAKE_BEADS"; : > "$FAKE_BD_LOG"
}
cen() {       # a dry run (no --notify): LINES = all stdout, OUT = its last line (the json summary), RC = exit code
  LINES="$(python3 -B -I "${CENSUS_BIN:-$CENSUS}" --bd-cmd "$FAKE_BD" --city "$SBX" --state "$S" --now "$NOW" "$@" 2>"$SBX/stderr")"; RC=$?
  OUT="$(printf '%s\n' "$LINES" | tail -n 1)"
  grep -q Traceback "$SBX/stderr" 2>/dev/null && bad "python traceback: $(tail -n 1 "$SBX/stderr")"
  return 0
}
cn() { cen --notify --notify-bin "$NOTIFY" --state-dir "$ST" "$@"; }   # the order's mode, with the fake notify
jf() { jq -r "$1" <<<"$OUT"; }
why() { jf '.cannot_tell_reasons | keys | join(",")'; }                # the reasons of a CANNOT TELL (a caught crash is rc 2 too)
matrix() { jf '.matrix|to_entries|map("\(.key)=\(.value)")|sort|join(",")'; }
nitem() { jq -cn --arg id "$1" --arg f "$2" --arg m "$3" --arg e "$4" '{id:$id, agent:"a", session_id:$f, message:$m, expires_at:$e}'; }   # id fence message expires_at
put_pending() { jq -s '{pending: .}' > "$S"; }
calls() { local n; n="$(grep -c '^CALL' "$NOTIFY_LOG" 2>/dev/null)"; echo "${n:-0}"; }
seen_ids() { jq -r '.alerted | keys | join(",")' "$ST/nudge-stranded-census-seen.json" 2>/dev/null; }
ascii_only() { python3 -I -c 'import sys; sys.exit(0 if all(b < 128 for b in open(sys.argv[1], "rb").read()) else 1)' "$1"; }
patched() {   # patched <out> <snippet file>: a copy of the census with the snippet defined just before its __main__ block
  python3 -I - "$CENSUS" "$1" "$2" <<'PY'
import sys
src, out, snippet = sys.argv[1:4]
text = open(src).read()
marker = 'if __name__ == "__main__":'
assert text.count(marker) == 1, "marker not found exactly once"
open(out, "w").write(text.replace(marker, open(snippet).read() + "\n\n" + marker))
PY
}

echo "== A. the message allowlist, alternative by alternative; look-alikes alarm; the 6 h window is strict"
new_cen a
{ nitem k1 s-closed "QUALITY GATE REVIEW — You are reviewer 1 of 2 for branch: fix/ga-x" "$SOON"
  nitem k2 s-closed "[wrapper] text and then QUALITY GATE REVIEW in the middle" "$SOON"
  nitem k3 s-closed "DISK CRITICAL on the mini (1.2 GB free)" "$SOON"
  nitem k4 s-closed "DISK LOW: 4 GB free" "$SOON"
  nitem k5 s-closed "disk usage is above the floor" "$SOON"
  nitem k6 s-closed "Bead nova para você: ga-1 — titulo" "$SOON"
  nitem k7 s-closed "GATE-FEEDBACK (gate_run=ga-fkdjduw branch=fix/ga-9uv1xps.3-x): fix this" "$SOON"
  nitem k8 s-closed "ga-1 has passed gate review" "$SOON"
  nitem k9 s-closed "Gate FAILED for wa-x5zg10 attempt 3/3" "$SOON"
  nitem k10 s-closed "QUALITY GATE FAILED for branch crew/oracle/wa-ofuv9c" "$SOON"
  nitem k11 s-closed "Your branch fix/ga-x PASSED gate review, but it was NOT merged." "$SOON"
  nitem k12 s-closed "blocker ga-1 closed: you can proceed" "$SOON"; } | put_pending
cen
eq "all twelve are known shapes: rc 0, 3 aviso-transit, 7 ponteiro-bead, 2 tarefa-gate" "$RC/$(matrix)" "0/encerrada|aviso-transit=3,encerrada|ponteiro-bead=7,encerrada|tarefa-gate=2"
{ nitem o1 s-closed "$UNK" "$SOON"
  nitem o2 s-closed "QUALITY GATE passed some other way" "$SOON"
  nitem o3 s-closed "Rotate Your key before friday" "$SOON"
  nitem o4 s-closed "blocker closed" "$SOON"
  nitem o5 s-closed "the disk is fine" "$SOON"
  nitem o6 s-closed "nightly backup FAILED on the mini" "$SOON"
  nitem o7 s-closed "update the bead counter before friday" "$SOON"; } | put_pending
cen
eq "seven texts that only resemble a known shape all alarm: rc 1" "$RC/$(jf '.alarms|length')/$(jf .cannot_tell)" "1/7/0"
eq "the STRANDED-INFO line names the item and carries its text" "$(grep -c "^STRANDED-INFO item=o1 .*rotate the vendor key" <<<"$LINES")" "1"
{ nitem w s-closed "$UNK" "2026-11-01T18:00:00Z"; } | put_pending; cen; r1=$RC
{ nitem w s-closed "$UNK" "2026-11-01T17:59:59Z"; } | put_pending; cen; r2=$RC; cen --alarm-hours 1; r3=$RC
eq "exactly 6 h left is no alarm, one second less is, --alarm-hours moves the window" "$r1/$r2/$r3" "0/1/0"
{ nitem z1 s-closed "$UNK" "0001-01-01T00:00:00Z"; nitem z2 s-closed "$UNK" "2026-11-01T11:00:00Z"; } | put_pending; cen
eq "a zero or already-past expires_at counts as no time left: both alarm" "$RC/$(jf '.alarms|length')" "1/2"

echo "== B. every unknown-shape item is decided or named: the legs of the alarm, and what a run that is only partly blind says"
new_cen b; echo '{"s-closed":"closed","s-live":"open"}' > "$FAKE_BEADS"
ANCHOR="$(nitem anchor s-closed "QUALITY GATE REVIEW anchor" "$LATER")"   # its fence resolves, so bd keeps answering (none resolved is the whole-run bd-unusable)
{ echo "$ANCHOR"; nitem far s-closed "$UNK" "$LATER"; nitem live s-live "$UNK" "$SOON"; nitem nofence "" "$UNK" "$SOON"
  nitem known s-missing "QUALITY GATE REVIEW x" "$SOON"; } | put_pending
cen
eq "far TTL, live fence, no fence and an unresolved fence under a KNOWN shape: rc 0, nothing named" "$RC/$(jf .cannot_tell)" "0/0"
eq "...the unresolved fence is nao-sei (the batch fell back to one-by-one) and the states stay apart" "$(jf .fences_nao_sei)/$(matrix)" "1/encerrada|outro=1,encerrada|tarefa-gate=1,nao-sei|tarefa-gate=1,sem-fence|outro=1,viva|outro=1"
{ echo "$ANCHOR"; nitem unk s-missing "$UNK" "$SOON"; } | put_pending; cen
eq "unknown shape, under 6 h, fence unresolvable: CANNOT TELL, named, no alarm (was a quiet rc 0)" "$RC/$(why)/$(jf '.outro_fence_unreadable|join(",")')/$(jf '.alarms|length')" "2/fence-unreadable/unk/0"
{ echo "$ANCHOR"; nitem unk s-missing "$UNK" "$LATER"; } | put_pending; cen
eq "...with more than 6 h left it is not in the window yet: rc 0" "$RC" "0"
{ echo "$ANCHOR"; nitem unk s-missing "$UNK" "not-a-date"; } | put_pending; cen
eq "...a TTL nobody can read does not clear it: rc 2, named" "$RC/$(jf '.outro_fence_unreadable|join(",")')" "2/unk"
{ nitem a1 s-closed "$UNK" "$SOON"; nitem unk s-missing "$UNK" "$SOON"; } | put_pending; cen
eq "an alarm and an undecided item together: rc 1, both reported" "$RC/$(jf '.alarms|map(.id)|join(",")')/$(jf '.outro_fence_unreadable|join(",")')" "1/a1/unk"
echo '{"p0":"closed"}' > "$FAKE_BEADS"
{ nitem i0 p0 "QUALITY GATE REVIEW 0" "$SOON"; for i in $(seq 1 39); do nitem "i$i" "p$i" "$UNK" "$SOON"; done; } | put_pending; cen
eq "40 fences and only 1 answers: rc 2 (was a quiet 0), all 39 unknown-shape items named" "$RC/$(jf .fences_nao_sei)/$(jf '.outro_fence_unreadable|length')" "2/39/39"
echo '{"s-closed":"closed"}' > "$FAKE_BEADS"
{ nitem t1 s-closed "$UNK" "not-a-date"; nitem t2 s-closed "$UNK" ""; } | put_pending; cen
eq "a closed fence with an unreadable expires_at: ttl-unreadable, both named, no alarm" "$RC/$(why)/$(jf '.outro_ttl_unreadable|sort|join(",")')/$(jf '.alarms|length')" "2/ttl-unreadable/t1,t2/0"
echo '{"s-nostatus":"-","s-live":"open"}' > "$FAKE_BEADS"   # s-live keeps bd answering
{ nitem n1 s-nostatus "$UNK" "$SOON"; nitem n2 s-live "$UNK" "$SOON"; } | put_pending; cen
eq "a bead row with no readable status is nao-sei (never encerrada, never viva): named, not alarmed" "$RC/$(jf .fences_nao_sei)/$(jf '.outro_fence_unreadable|join(",")')/$(jf '.alarms|length')/$(matrix)" "2/1/n1/0/nao-sei|outro=1,viva|outro=1"
echo '{"s-closed":"closed"}' > "$FAKE_BEADS"
{ echo '"just a string"'; echo '42'; echo 'null'; nitem g1 s-closed "QUALITY GATE REVIEW 1" "$LATER"; } | put_pending; cen
eq "pending entries that are not objects: unreadable-items, counted, the rest still classified" "$RC/$(why)/$(jf .unreadable_items)/$(matrix)" "2/unreadable-items/3/encerrada|tarefa-gate=1"

echo "== C. bd: batches of at most 20, a purged id costs only itself, a bd that fails or lies is bd-unusable, a hung bd is cut at the budget"
new_cen c
python3 -I - "$FAKE_BEADS" <<'PY'
import json, sys
json.dump({f"s{i}": "closed" for i in range(45) if i != 7}, open(sys.argv[1], "w"))
PY
for i in $(seq 0 44); do nitem "i$i" "s$i" "QUALITY GATE REVIEW $i" "$LATER"; done | put_pending; cen
eq "45 fences with one purged: 44 closed, 1 nao-sei, rc 0" "$RC/$(jf '[.matrix["encerrada|tarefa-gate"], .matrix["nao-sei|tarefa-gate"]]|join("/")')" "0/44/1"
eq "...batches of at most 20 (20, 20, 5; the failed 5 re-asked one by one)" "$(sort -n "$FAKE_BD_LOG" | tail -n 1)/$(awk '$1 > 1' "$FAKE_BD_LOG" | grep -c '')" "20/3"
echo '{"s-closed":"closed"}' > "$FAKE_BEADS"; { nitem b1 s-closed "$UNK" "$SOON"; } | put_pending
BD_MODE=fail cen
eq "bd fails for every fence: rc 2 bd-unusable" "$RC/$(why)" "2/bd-unusable"
says "...and says why" "bd resolved none of the 1 fences"
BD_MODE=badrow cen
eq "a row whose id is not a string is dropped, not a crash: rc 2 bd-unusable" "$RC/$(why)" "2/bd-unusable"
: > "$FAKE_BD_LOG"; cen --deadline-s 0
eq "budget 0: bd never called, rc 2 bd-unusable, deadline_hit" "$(grep -c '' "$FAKE_BD_LOG")/$RC/$(why)/$(jf .deadline_hit)" "0/2/bd-unusable/true"
says "...and the error says the time budget was spent" "time budget spent"
t0=$SECONDS; BD_MODE=slow cen --deadline-s 2; el=$((SECONDS - t0))
eq "a bd that hangs for 20 s is cut at the budget: under 10 s, rc 2, deadline_hit" "$([ "$el" -lt 10 ] && echo fast || echo "slow ${el}s")/$RC/$(jf .deadline_hit)" "fast/2/true"

echo "== D. queue state: unreadable or odd is CANNOT TELL state-unreadable; every empty form is a clean rc 0"
new_cen d
for shape in '{"pending": ' '{"pending": "x"}' '[]' '"str"' '42'; do
  printf '%s' "$shape" > "$S"; cen; eq "[$shape]: rc 2 state-unreadable" "$RC/$(why)" "2/state-unreadable"
done
printf '\377\376{' > "$S"; cen; eq "bytes that are not text (UnicodeDecodeError): rc 2 state-unreadable" "$RC/$(why)" "2/state-unreadable"
S="$CASE/no-such-dir/state.json"; cen; eq "queue dir missing (ENOENT): rc 2 state-unreadable" "$RC/$(why)" "2/state-unreadable"
S="$CASE/state.json"; rm -f "$S"; mkdir "$S"; cen; eq "state.json is a directory (IsADirectoryError): rc 2 state-unreadable" "$RC/$(why)" "2/state-unreadable"
rmdir "$S"
if [ "$(id -u)" != 0 ]; then
  echo '{"pending": []}' > "$S"; chmod 000 "$S"; cen
  eq "state.json unreadable (PermissionError, chmod 000): rc 2 state-unreadable" "$RC/$(why)" "2/state-unreadable"; chmod 600 "$S"
fi
for shape in '{"pending": []}' '{"dead": []}' 'null' ''; do printf '%s' "$shape" > "$S"; cen; eq "[$shape] is an empty queue: rc 0" "$RC" "0"; done
rm -f "$S"; cen; eq "a queue dir with no state.json yet is an empty queue: rc 0" "$RC" "0"

echo "== E. a crash is CANNOT TELL (rc 2) or rc 3 and says so, never an uncaught exception whose exit code 1 would read as STRANDED-INFO"
new_cen e; { nitem x1 s-closed "BOOM" "$SOON"; } | put_pending
printf '%s\n' '_real_classify = classify' 'def classify(message):' '    if message == "BOOM":' '        raise RuntimeError("boom")' \
  '    return _real_classify(message)' > "$CASE/patch.py"
patched "$CASE/crash.py" "$CASE/patch.py"
CENSUS_BIN="$CASE/crash.py" cn
eq "classify crashed: rc 2 crashed, and a blind notice went out" "$RC/$(why)/$(calls)" "2/crashed/1"
says "...the summary says what crashed" "census crashed: RuntimeError: boom"
{ nitem x1 s-closed "$UNK" "$SOON"; } | put_pending
printf '%s\n' 'def tell(*a, **k):' '    raise RuntimeError("notify boom")' > "$CASE/patch.py"
patched "$CASE/crash2.py" "$CASE/patch.py"
CENSUS_BIN="$CASE/crash2.py" cn
eq "the delivery code crashed: rc 3" "$RC" "3"
says "...the summary says what crashed" "RuntimeError: notify boom"

echo "== N1. an ALARM reaches a human: one notify per run with the NEW ids, once per nudge id; the ledger forgets an id that leaves, never on a blind run"
new_cen n1; { nitem u1 s-closed "$UNK" "$SOON"; } | put_pending; cn
eq "rc 1, one notify, u1 alarmed and in the ledger" "$RC/$(calls)/$(jf '.alarmed|join(",")')/$(seen_ids)" "1/1/u1/u1"
has "titled with the count" "CALL${TAB}Censo de nudge preso: STRANDED-INFO (1)" "$NOTIFY_LOG"
has "the body names the id, the agent and the fence" "u1 -> a (fence s-closed)" "$NOTIFY_LOG"
hasnt "the body never carries the nudge text (it may hold anything)" "rotate the vendor key" "$NOTIFY_LOG"
if ascii_only "$NOTIFY_LOG"; then ok "the text is ASCII (ntfy sends the title as a header)"; else bad "the text has a non-ASCII byte"; fi
cn
eq "sweep 2: still rc 1, deduped, still ONE notify" "$RC/$(jf .notices.stranded)/$(calls)" "1/deduped/1"
lines1="$(grep -c '' "$NOTIFY_LOG")"
{ nitem u1 s-closed "$UNK" "$SOON"; nitem u2 s-closed "$UNK" "$SOON"; } | put_pending; cn
eq "sweep 3: a second id alarms alone" "$(jf '.alarmed|join(",")')/$(calls)" "u2/2"
hasnt "...its body does not repeat u1" "u1 ->" <(tail -n +"$((lines1 + 1))" "$NOTIFY_LOG")
{ nitem u2 s-closed "$UNK" "$SOON"; } | put_pending; cn
eq "an id that left the queue is pruned from the ledger" "$(seen_ids)" "u2"
echo '{"pending": ' > "$S"; cn
eq "a blind run (rc 2) does not prune it: it saw nothing" "$RC/$(seen_ids)" "2/u2"
{ nitem u2 s-closed "$UNK" "$SOON"; } | put_pending; cn
eq "...so the alarm is still deduped afterwards" "$RC/$(jf .notices.stranded)" "1/deduped"

echo "== N2. CANNOT TELL reaches a human too: one notify per reason-set per cooldown, never one per run"
new_cen n2; { nitem b1 s-closed "$UNK" "$SOON"; } | put_pending
BD_MODE=fail cn
eq "rc 2, one blind notify" "$RC/$(calls)" "2/1"
has "with its own title" "CALL${TAB}Censo de nudge preso: cego" "$NOTIFY_LOG"
has "naming the reason" "bd-unusable" "$NOTIFY_LOG"
if ascii_only "$NOTIFY_LOG"; then ok "the blind text is ASCII"; else bad "the blind text has a non-ASCII byte"; fi
BD_MODE=fail cn
eq "within the cooldown: rc 2, no second notify" "$RC/$(calls)/$(jf .notices.blind)" "2/1/cooldown"
BD_MODE=fail cn --cannot-tell-cooldown-min 0
eq "after the cooldown it says so again" "$(calls)" "2"
echo '{"pending": ' > "$S"; cn
eq "a DIFFERENT reason-set is not held back by another one's cooldown, and names itself" "$RC/$(calls)" "2/3"
has "...state-unreadable" "state-unreadable" "$NOTIFY_LOG"
{ nitem b1 s-closed "$UNK" "$SOON"; } | put_pending
echo "{\"alerted\":{},\"cannot_tell\":{\"bd-unusable\":$(( $(date +%s) + 86400 ))}}" > "$ST/nudge-stranded-census-seen.json"
BD_MODE=fail cn
eq "a cooldown stamp dated in the future (clock moved back) is no cooldown" "$(calls)" "4"
echo '{"alerted":{},"cannot_tell":{"bd-unusable":"yesterday"}}' > "$ST/nudge-stranded-census-seen.json"
BD_MODE=fail cn
eq "a stamp that is not a number is no cooldown either" "$(calls)" "5"

echo "== N3. a notice that was not delivered is NOT recorded as sent: rc 3, loud, retried by the next run"
new_cen n3; { nitem u1 s-closed "$UNK" "$SOON"; } | put_pending
: > "$NOTIFY_FAIL"; cn
eq "notify exits 1: rc 3 (not 1), failed, nothing recorded" "$RC/$(jf .notices.stranded)/$(seen_ids)" "3/failed/"
has "stderr names the undelivered alarm" "ALARM NOT DELIVERED" "$SBX/stderr"
eq "the STRANDED-INFO line is still printed" "$(grep -c '^STRANDED-INFO item=u1' <<<"$LINES")" "1"
rm -f "$NOTIFY_FAIL"; cn
eq "the next run retries and delivers (rc 1)" "$RC/$(jf '.alarmed|join(",")')/$(calls)" "1/u1/2"
cn
eq "...and then it is quiet" "$(calls)" "2"
new_cen n3b; { nitem b1 s-closed "$UNK" "$SOON"; } | put_pending
: > "$NOTIFY_FAIL"; BD_MODE=fail cn
eq "a blind run whose notify fails: rc 3 (not 2), loud" "$RC/$(jf .notices.blind)" "3/failed"
has "stderr says the census is blind and nobody was told" "the census is blind" "$SBX/stderr"
rm -f "$NOTIFY_FAIL"; BD_MODE=fail cn
eq "the cooldown did not start: the next run tells at once" "$RC/$(jf .notices.blind)/$(calls)" "2/sent/2"
new_cen n3c; { nitem u1 s-closed "$UNK" "$SOON"; } | put_pending; cn --notify-bin "$CASE/does-not-exist"
eq "notify binary missing: rc 3, not recorded" "$RC/$(seen_ids)" "3/"

echo "== N4. without --notify nothing is delivered or written (the queue stays byte-identical); a clean run with --notify says nothing"
new_cen n4; { nitem r1 s-closed "$UNK" "$SOON"; } | put_pending
before="$(shasum -a 256 "$S")"; cen
eq "alarm, dry run: rc 1, no notify, no ledger dir, queue untouched" "$RC/$(calls)/$([ -e "$ST" ] && echo yes || echo no)/$([ "$(shasum -a 256 "$S")" = "$before" ] && echo same || echo changed)" "1/0/no/same"
BD_MODE=fail cen
eq "blind, dry run: rc 2, no notify" "$RC/$(calls)" "2/0"
cn
eq "with --notify the queue is still byte-identical" "$RC/$(shasum -a 256 "$S")" "1/$before"
new_cen n4b; echo '{"pending": []}' > "$S"; cn
eq "clean run with --notify: rc 0, no notify, no ledger dir" "$RC/$(calls)/$([ -e "$ST" ] && echo yes || echo no)" "0/0/no"

echo "== N5. a ledger that cannot be written is loud (rc 3), a corrupt one is healed; every run is logged, an unwritable log is reported, not fatal"
new_cen n5; { nitem u1 s-closed "$UNK" "$SOON"; } | put_pending
: > "$CASE/afile"; cn --state-dir "$CASE/afile/sub"
eq "state dir under a regular file: rc 3 although the notice went out" "$RC/$(calls)" "3/1"
says "the summary says why" "ledger_write"
has "stderr says it" "could not write the ledger" "$SBX/stderr"
mkdir -p "$ST"; echo 'garbage {' > "$ST/nudge-stranded-census-seen.json"; cn
eq "a corrupt ledger costs one repeated notice and is healed" "$RC/$(calls)/$(seen_ids)" "1/2/u1"
cn --log "$CASE/run.jsonl"; cn --log "$CASE/run.jsonl"
eq "two runs, two json lines, each with rc and duration_s (the live cost is read there)" "$(grep -c '' "$CASE/run.jsonl")/$(jq -r '[.rc, (.duration_s|type)]|map(tostring)|join(",")' "$CASE/run.jsonl" | sort -u)" "2/1,number"
cen --log "$CASE/afile/sub/run.jsonl"
eq "an unwritable log dir does not change the rc (1)" "$RC" "1"
has "...and is reported on stderr" "could not append to log" "$SBX/stderr"

echo "== N6. an ALARM and a CANNOT TELL in one run: rc 1, two notices; a long list is cut at 8 ids and a count, every id recorded"
new_cen n6; { nitem a1 s-closed "$UNK" "$SOON"; nitem unk s-missing "$UNK" "$SOON"; } | put_pending; cn
eq "rc 1, two notifies" "$RC/$(calls)" "1/2"
has "the alarm" "CALL${TAB}Censo de nudge preso: STRANDED-INFO (1)" "$NOTIFY_LOG"
has "the blind one names the item" "fence-unreadable (1): unk" "$NOTIFY_LOG"
new_cen n6b; for i in $(seq 1 10); do nitem "v$i" s-closed "$UNK" "$SOON"; done | put_pending; cn
eq "ten alarms: one notify, all ten recorded" "$RC/$(calls)/$(jq -r '.alerted|length' "$ST/nudge-stranded-census-seen.json")" "1/1/10"
has "...titled with the full count" "STRANDED-INFO (10)" "$NOTIFY_LOG"
has "...the rest is a count" "... e mais 2" "$NOTIFY_LOG"

echo "== W. the order entrypoint runs the census with --notify, in the state dir, with the pack's log"
mkdir -p "$SBX/bin"; printf '%s\n' '#!/bin/sh' '[ "$1" = bd ] || exit 2' 'shift' 'exec "$FAKE_BD" "$@"' > "$SBX/bin/gc"; chmod +x "$SBX/bin/gc"
bash -n "$WRAP" && ok "wrapper parses" || bad "wrapper has a syntax error"
new_cen w; CITY="$CASE/city"; mkdir -p "$CITY/.gc/nudges"; S="$CITY/.gc/nudges/state.json"
IN="$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) + d.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
{ nitem w1 s-closed "$UNK" "$IN"; } | put_pending
PS="$CASE/pack-state"
(cd "$CASE" && env GC_CITY="$CITY" GC_PACK_STATE_DIR="$PS" NOTIFY_BIN="$NOTIFY" PATH="$SBX/bin:$PATH" bash "$WRAP" >/dev/null 2>"$CASE/wrap.err"); wrc=$?
eq "wrapper rc 1; the alarm went out through the notify binary; ledger and log are in GC_PACK_STATE_DIR" "$wrc/$(calls)/$(jq -r '.alerted|keys|join(",")' "$PS/nudge-stranded-census-seen.json" 2>/dev/null)/$(jq -r '[.deliver,.rc]|map(tostring)|join(",")' "$PS/nudge-stranded-census.jsonl" 2>/dev/null)" "1/1/w1/true,1"
echo '{"pending": []}' > "$S"
(cd "$CASE" && env -u GC_PACK_STATE_DIR GC_CITY="$CITY" GC_CITY_RUNTIME_DIR="$CASE/rt" NOTIFY_BIN="$NOTIFY" PATH="$SBX/bin:$PATH" bash "$WRAP" >/dev/null 2>&1)
(cd "$CASE" && env -u GC_PACK_STATE_DIR -u GC_CITY_RUNTIME_DIR GC_CITY="$CITY" NOTIFY_BIN="$NOTIFY" PATH="$SBX/bin:$PATH" bash "$WRAP" >/dev/null 2>&1)
eq "state dir: GC_CITY_RUNTIME_DIR/packs/town-deltas, else <city>/.gc/runtime/packs/town-deltas" "$([ -s "$CASE/rt/packs/town-deltas/nudge-stranded-census.jsonl" ] && echo yes || echo no)/$([ -s "$CITY/.gc/runtime/packs/town-deltas/nudge-stranded-census.jsonl" ] && echo yes || echo no)" "yes/yes"

echo "== O. the order: 3 h cadence, a declared timeout that fits the budget, a cooldown between one and two runs, exec exists"
python3 -I - "$ORDER" "$SELF_DIR" "$CENSUS" <<'PY'
import os, re, sys
try:
    import tomllib
except ImportError:
    print("  - SKIP: tomllib unavailable (python < 3.11), order file not parsed")
    sys.exit(3)
path, scripts, census = sys.argv[1:4]
o = tomllib.load(open(path, "rb"))["order"]
secs = lambda t: int(re.fullmatch(r"(\d+)[smh]", t).group(1)) * {"s": 1, "m": 60, "h": 3600}[t[-1]]
src = open(census, encoding="utf-8").read()
const = lambda n: float(re.search(r"^%s = ([0-9.]+)" % n, src, re.M).group(1))
interval, timeout = secs(o["interval"]), secs(o["timeout"])   # KeyError when undeclared: the engine default (300 s) would SIGKILL a wedged run without a word
assert o["trigger"] == "cooldown" and interval == 3 * 3600, "the 3 h cadence lets two runs see every item inside its last 6 h of TTL"
need = const("DEADLINE_S_DEFAULT") + 2 * const("NOTIFY_TIMEOUT_S")
assert need <= timeout < interval, "timeout %ds must cover the budget %ds and stay under the interval" % (timeout, need)
cool = const("CANNOT_TELL_COOLDOWN_MIN_DEFAULT") * 60
assert interval < cool < 2 * interval, "cooldown %ds must let every second run say it again, whatever the jitter" % cool
assert o["exec"] == "$PACK_DIR/assets/scripts/nudge-stranded-census.sh", o["exec"]
assert os.access(os.path.join(scripts, "nudge-stranded-census.sh"), os.X_OK), "exec target is not executable"
PY
case $? in 0) ok "order file is consistent" ;; 3) ;; *) bad "order file check failed (see above)" ;; esac

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
