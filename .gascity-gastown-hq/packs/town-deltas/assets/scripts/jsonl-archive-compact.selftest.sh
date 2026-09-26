#!/bin/bash
# jsonl-archive-compact.selftest.sh (ga-a3ar7h) — the compaction script, its order file, and the
# incident it exists for, against REAL throwaway git repos.
#
# Hermetic: every repo, state file, log, lock and the `gc` (mail) stub live under one temp dir.
# The real archives, the real state/log and the real `gc` are never touched (JAC_* seams).
# The repos hold ~120KB blobs and use tiny limits (KiB), so the same code paths run in seconds
# that run on 41MB blobs in production.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$HERE/../.." && pwd)"                       # .../packs/town-deltas
CITY_ROOT="$(cd "$PACK/../.." && pwd)"                  # .../.gascity-gastown-hq
SCRIPT="$HERE/jsonl-archive-compact.sh"
ORDER="$PACK/orders/jsonl-archive-compact.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d /tmp/jsonl-archive-compact-selftest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # a developer's ~/.gitconfig must not change what is tested
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ── fixtures ────────────────────────────────────────────────────────────────────
# mkrepo <dir> <commits> [seed]: N versions of one ~120KB-compressed file that differ by a line or two,
# the shape of the real hq.jsonl history (many near-identical big blobs, few objects). The commits run
# with auto-maintenance OFF (-c, repo config untouched): git's own post-commit maintenance samples one
# directory and fires at random on a repo this small, which used to pack a fixture mid-build and make
# the tests flaky — the very sampling this whole bead is about.
mkrepo() {
  local d="$1" n="$2" i
  git init -q "$d"
  awk -v seed="${3:-7}" 'BEGIN{srand(seed); for(i=0;i<4000;i++){s=""; for(j=0;j<48;j++) s=s sprintf("%c",97+int(rand()*26)); print s}}' > "$d/hq.jsonl"
  for i in $(seq 1 "$n"); do
    awk -v k="$i" '{ if (NR % 997 == k % 997) print "changed line " k; else print }' "$d/hq.jsonl" > "$d/hq.jsonl.new" && mv "$d/hq.jsonl.new" "$d/hq.jsonl"
    git -C "$d" add hq.jsonl && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "backup $i"
  done
}
# addpack <dir> <i>: commit a new version, then freeze exactly the new loose objects into their OWN pack.
# Two things in current git (2.54) would merge the packs this fixture is building, so neither is used:
# `git repack -d` (merges small packs) and the auto-maintenance `git commit` runs (a geometric repack —
# the very thing that kept these archives compact until 2026-09-25); it is switched off for this commit
# only, via -c, so the repo's own config stays default.
addpack() {
  local d="$1" i="$2"
  awk -v k="$i" '{ if (NR % 997 == k % 997) print "changed line " k; else print }' "$d/hq.jsonl" > "$d/hq.jsonl.new" && mv "$d/hq.jsonl.new" "$d/hq.jsonl"
  git -C "$d" add hq.jsonl && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "backup $i"
  git --git-dir="$d/.git" rev-list --objects --all --unpacked | git --git-dir="$d/.git" pack-objects -q "$d/.git/objects/pack/pack" >/dev/null
  git --git-dir="$d/.git" prune-packed -q
}
# addcommits <dir> <n>: n more versions, committed loose (auto-maintenance off for these commits only)
addcommits() {
  local d="$1" n="$2" i
  for i in $(seq 101 $((100 + n))); do
    awk -v k="$i" '{ if (NR % 997 == k % 997) print "changed line " k; else print }' "$d/hq.jsonl" > "$d/hq.jsonl.new" && mv "$d/hq.jsonl.new" "$d/hq.jsonl"
    git -C "$d" add hq.jsonl && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "backup $i"
  done
}
loose_count() { git --git-dir="$1/.git" count-objects -v 2>/dev/null | awk '/^count:/{print $2}'; }
loose_kib()   { git --git-dir="$1/.git" count-objects -v 2>/dev/null | awk '/^size:/{print $2}'; }
pack_count()  { git --git-dir="$1/.git" count-objects -v 2>/dev/null | awk '/^packs:/{print $2}'; }
commits()     { git --git-dir="$1/.git" rev-list --count HEAD; }
history()     { git --git-dir="$1/.git" log --format='%H %T' HEAD | shasum | cut -d' ' -f1; }   # every commit id + its tree id

cat > "$WORK/gc-stub" <<EOF
#!/bin/bash
printf 'CALL %s\\n' "\$(printf '%s' "\$*" | tr '\\n' ' ')" >> "$WORK/gc-calls"
exit "\${STUB_FAIL:-0}"
EOF
chmod +x "$WORK/gc-stub"
# git-slow: a stand-in for this host's permanent load — a `maintenance run` whose batch size is above
# $SLOW_ABOVE takes 8s (the test caps a batch at 2s), everything else is plain git. It logs every batch size.
cat > "$WORK/git-slow" <<EOF
#!/bin/bash
n=""; for a in "\$@"; do case "\$a" in maintenance.loose-objects.batchSize=*) n="\${a#*=}" ;; esac; done
case " \$* " in *" maintenance run "*) echo "\${n:-none}" >> "$WORK/git-batches"; if [ -n "\$n" ] && [ "\$n" -gt "\${SLOW_ABOVE:-999999}" ]; then sleep 8; fi ;; esac
exec git "\$@"
EOF
chmod +x "$WORK/git-slow"

# run_jac <repo...> [-- --check]: the script under test, sealed off from the real world.
run_jac() {
  local repos="$1"; shift
  JAC_REPOS="$repos" JAC_STATE="$WORK/state.json" JAC_LOG="$WORK/log" JAC_LOCK="$WORK/lock" JAC_GC="$WORK/gc-stub" \
  JAC_LOOSE_LIMIT_KIB="${T_LIMIT:-1024}" JAC_LOOSE_ALARM_KIB="${T_ALARM:-100000}" JAC_BATCH_OBJECTS="${T_BATCH:-25}" \
  JAC_PACKS_LIMIT="${T_PACKS:-8}" JAC_PACKS_ALARM="${T_PACKS_ALARM:-20}" JAC_FREE_KIB="${T_FREE:-90000000}" \
  JAC_ALERT_EVERY_S="${T_ALERT_EVERY:-21600}" JAC_HEADROOM_KIB=0 \
  JAC_GIT="${T_GIT:-git}" JAC_GIT_TIMEOUT_S="${T_GIT_TIMEOUT:-300}" JAC_MAX_BATCHES="${T_MAX_BATCHES:-0}" JAC_DEADLINE_S="${T_DEADLINE:-780}" \
  bash "$SCRIPT" "$@" 2>&1
}
last_status() { grep -o 'status=[a-z-]*' "$WORK/log" | tail -1 | cut -d= -f2; }
state_field() { jq -r --arg r "$1" ".[\$r].$2" "$WORK/state.json" 2>/dev/null; }
mail_calls()  { [ -f "$WORK/gc-calls" ] && wc -l < "$WORK/gc-calls" | tr -d ' ' || echo 0; }

echo "=== jsonl-archive-compact.selftest.sh ==="
[ -x "$SCRIPT" ] && ok "script exists and is executable" || { bad "script missing or not executable: $SCRIPT"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
bash -n "$SCRIPT" && ok "script parses" || bad "script has a syntax error"

echo ""
echo "=== S0: the incident — git's own auto-gc is blind to big blobs, this script is not ==="
# The real archive's condition, built on purpose rather than hoped for: many big loose objects while the
# ONE directory git samples (objects/17) holds at most one. Which seed lands that way is arbitrary, so
# try seeds until it does (each has a ~98% chance).
A="$WORK/a"
for seed in 7 8 9 10 11 12 13 14 15 16; do
  rm -rf "$A"; mkrepo "$A" 20 "$seed"
  [ "$(ls "$A/.git/objects/17" 2>/dev/null | wc -l | tr -d ' ')" -le 1 ] && break
done
LC0="$(loose_count "$A")"; LK0="$(loose_kib "$A")"; H0="$(history "$A")"; N0="$(commits "$A")"
[ "$(ls "$A/.git/objects/17" 2>/dev/null | wc -l | tr -d ' ')" -le 1 ] && ok "fixture reproduces the incident: $LC0 loose objects ($((LK0/1024))MiB), objects/17 holds $(ls "$A/.git/objects/17" 2>/dev/null | wc -l | tr -d ' ')" || bad "could not build the blind-spot fixture"
git --git-dir="$A/.git" gc --auto --quiet 2>/dev/null
git --git-dir="$A/.git" maintenance run --auto --quiet 2>/dev/null
[ "$(loose_count "$A")" = "$LC0" ] && [ "$LK0" -ge 1024 ] \
  && ok "git gc --auto AND git maintenance run --auto (what git commit runs) leave all $LC0 loose objects alone — they count objects in one directory, not bytes (the 5GiB/day leak)" \
  || bad "expected git's own auto-maintenance to be blind here (loose $LC0 -> $(loose_count "$A"), ${LK0}KiB)"

echo ""
echo "=== S1: loose bytes over the limit → bounded batches drain them, history untouched ==="
out="$(run_jac "$A")"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"
[ "$(loose_count "$A")" = 0 ] && ok "no loose objects left (was $LC0, $((LK0/1024))MiB)" || bad "loose objects left: $(loose_count "$A")"
printf '%s' "$out" | grep -qE 'batches=([2-9]|[1-9][0-9])' && ok "drained in several bounded batches (batch=25 < $LC0 objects)" || bad "expected >=2 batches: $out"
[ "$(pack_count "$A")" -ge 2 ] && ok "one pack per batch ($(pack_count "$A") packs)" || bad "expected one pack per batch, got $(pack_count "$A")"
[ "$(commits "$A")" = "$N0" ] && [ "$(history "$A")" = "$H0" ] && ok "history byte-identical: $N0 commits, same commit+tree ids" || bad "history changed"
git --git-dir="$A/.git" fsck --strict >/dev/null 2>&1 && ok "git fsck --strict clean" || bad "fsck failed after compaction"
[ "$(last_status)" = "packed-loose" ] && ok "status packed-loose" || bad "status was '$(last_status)'"
[ "$(state_field "$A" bad_streak)" = 0 ] && ok "state: bad_streak 0" || bad "state bad_streak=$(state_field "$A" bad_streak)"

echo ""
echo "=== S2: under the limit and few packs → a no-op that touches nothing ==="
B="$WORK/b"; mkrepo "$B" 2
LC="$(loose_count "$B")"; PC="$(pack_count "$B")"
out="$(run_jac "$B")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$B")" = "$LC" ] && [ "$(pack_count "$B")" = "$PC" ] && [ "$(last_status)" = "ok" ] \
  && ok "no-op: exit 0, status ok, loose and packs unchanged" || bad "no-op broken (rc=$rc status=$(last_status) loose $LC->$(loose_count "$B") packs $PC->$(pack_count "$B"))"

echo ""
echo "=== S3: too many packs → one consolidating gc; history untouched ==="
C="$WORK/c"; mkrepo "$C" 1
for i in 2 3 4 5 6; do addpack "$C" "$i"; done
PC0="$(pack_count "$C")"; H3="$(history "$C")"; N3="$(commits "$C")"
out="$(T_PACKS=4 run_jac "$C")"; rc=$?
[ "$PC0" -ge 5 ] && [ "$rc" -eq 0 ] && [ "$(pack_count "$C")" -le 2 ] && [ "$(last_status)" = "consolidated" ] \
  && ok "packs $PC0 -> $(pack_count "$C"), status consolidated" || bad "consolidation failed (packs $PC0 -> $(pack_count "$C"), rc=$rc, status=$(last_status)): $out"
[ "$(history "$C")" = "$H3" ] && [ "$(commits "$C")" = "$N3" ] && git --git-dir="$C/.git" fsck --strict >/dev/null 2>&1 \
  && ok "history identical and fsck clean after gc" || bad "gc changed or damaged history"

echo ""
echo "=== S4: low disk → skipped LOUDLY (failure), not silently, and nothing is written ==="
D="$WORK/d"; mkrepo "$D" 20; LC="$(loose_count "$D")"; rm -f "$WORK/state.json" "$WORK/gc-calls"
out="$(T_FREE=1 run_jac "$D")"; rc=$?
[ "$rc" -eq 1 ] && [ "$(last_status)" = "skipped-low-disk" ] && [ "$(loose_count "$D")" = "$LC" ] \
  && ok "exit 1, status skipped-low-disk, $LC loose objects untouched" || bad "low-disk handling wrong (rc=$rc status=$(last_status) loose=$(loose_count "$D"))"
[ "$(state_field "$D" bad_streak)" = 1 ] && ok "state: bad_streak 1" || bad "state bad_streak=$(state_field "$D" bad_streak)"

# unknown free space is not "enough": it proceeds (a failed df must not stop compaction) but SAYS so
D2="$WORK/d2"; mkrepo "$D2" 20; rm -f "$WORK/state.json"
out="$(T_FREE=notanumber run_jac "$D2")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$D2")" = 0 ] && printf '%s' "$out" | grep -q 'free space unknown' && ok "df gave no number → compacts anyway and logs 'free space unknown' (visible, not a silent 'enough')" || bad "unknown free space handled wrong (rc=$rc loose=$(loose_count "$D2")): $out"
# a corrupt state file resets streaks/batch sizes — visibly
D3="$WORK/d3"; mkrepo "$D3" 2; printf '{not json' > "$WORK/state.json"
out="$(run_jac "$D3")"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'unreadable — starting fresh' && jq -e . "$WORK/state.json" >/dev/null 2>&1 && ok "corrupt state file → logged, replaced by a valid one, run still succeeds" || bad "corrupt state handled wrong (rc=$rc): $out"

echo ""
echo "=== S5: a broken .git INSIDE another repo is 'unmeasured' — never the enclosing repo's numbers ==="
P="$WORK/enclosing"; mkrepo "$P" 3; mkdir -p "$P/sub/.git"
COUNT_BEFORE="$(git --git-dir="$P/.git" count-objects -v | tr '\n' ' ')"; rm -f "$WORK/state.json"
out="$(run_jac "$P/sub")"; rc=$?
[ "$rc" -eq 1 ] && [ "$(last_status)" = "unmeasured" ] && ok "exit 1, status unmeasured" || bad "unmeasured handling wrong (rc=$rc status=$(last_status)): $out"
[ "$(git --git-dir="$P/.git" count-objects -v | tr '\n' ' ')" = "$COUNT_BEFORE" ] && ok "the enclosing repo was not touched (--git-dir stops git walking up)" || bad "the enclosing repo changed"
[ "$(state_field "$P/sub" loose_kib)" = "null" ] && ok "state records unknown sizes as null, not 0" || bad "state loose_kib=$(state_field "$P/sub" loose_kib) (want null)"

echo ""
echo "=== S6: absent repos ==="
out="$(run_jac "$WORK/nope1 $WORK/nope2")"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'nothing was compacted' && ok "every configured repo absent → exit 1 (a wrong path must not look healthy)" || bad "all-absent handling wrong (rc=$rc): $out"
out="$(run_jac "$WORK/nope1 $B")"; rc=$?
[ "$rc" -eq 0 ] && ok "one absent + one present → exit 0 (the retired town-deltas archive may be gone)" || bad "one-absent handling wrong (rc=$rc): $out"

echo ""
echo "=== S7: single-flight lock ==="
E="$WORK/e"; mkrepo "$E" 20; LC="$(loose_count "$E")"
mkdir -p "$WORK/lock"
out="$(run_jac "$E")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$E")" = "$LC" ] && printf '%s' "$out" | grep -q 'in flight' && ok "a fresh lock → exits 0 without touching the repo" || bad "ran while locked (rc=$rc loose=$(loose_count "$E"))"
touch -t "$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M.%S)" "$WORK/lock"
out="$(run_jac "$E")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$E")" = 0 ] && ok "a 3h-old lock is stale → reclaimed, work done" || bad "stale lock not reclaimed (rc=$rc loose=$(loose_count "$E")): $out"
[ ! -d "$WORK/lock" ] && ok "lock released on exit" || bad "lock left behind"
# owner pid: a run SIGKILLed by the order timeout leaves its lock behind — a dead owner must not cost 90 quiet minutes
E2="$WORK/e2"; mkrepo "$E2" 20; LC="$(loose_count "$E2")"
mkdir -p "$WORK/lock"; echo 999999 > "$WORK/lock/pid"; touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" "$WORK/lock"
out="$(run_jac "$E2")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$E2")" = 0 ] && ok "5-minute-old lock whose owner pid is dead → reclaimed at once (no 90-minute gap)" || bad "dead-owner lock not reclaimed (rc=$rc loose=$(loose_count "$E2")): $out"
E3="$WORK/e3"; mkrepo "$E3" 20; LC="$(loose_count "$E3")"
mkdir -p "$WORK/lock"; echo "$$" > "$WORK/lock/pid"; touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" "$WORK/lock"
out="$(run_jac "$E3")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$E3")" = "$LC" ] && printf '%s' "$out" | grep -q 'in flight' && ok "5-minute-old lock whose owner is alive → still in flight, repo untouched" || bad "live-owner lock was taken (rc=$rc loose=$(loose_count "$E3")): $out"
rm -f "$WORK/lock/pid"; rmdir "$WORK/lock" 2>/dev/null

echo ""
echo "=== S8: another gc already running → busy, not failure ==="
F="$WORK/f"; mkrepo "$F" 1
for i in 2 3 4 5; do addpack "$F" "$i"; done
echo "$$ $(hostname)" > "$F/.git/gc.pid"
out="$(T_PACKS=3 run_jac "$F")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(last_status)" = "busy" ] && ok "live gc.pid → status busy, exit 0 (left to finish, retried next cycle)" || bad "busy handling wrong (rc=$rc status=$(last_status)): $out"
rm -f "$F/.git/gc.pid"

echo ""
echo "=== S9: the alarm — one mail per streak per window, and an undelivered mail is retried ==="
G="$WORK/g"; mkrepo "$G" 20; rm -f "$WORK/state.json" "$WORK/gc-calls"
T_FREE=1 run_jac "$G" >/dev/null; T_FREE=1 run_jac "$G" >/dev/null
[ "$(mail_calls)" = 0 ] && ok "2 bad runs → no mail yet (needs 3 in a row)" || bad "mailed too early ($(mail_calls))"
T_FREE=1 run_jac "$G" >/dev/null
[ "$(mail_calls)" = 1 ] && grep -q 'mail send mayor/' "$WORK/gc-calls" && ok "3rd bad run → exactly one mail to mayor/" || bad "expected 1 mail, got $(mail_calls)"
T_FREE=1 run_jac "$G" >/dev/null
[ "$(mail_calls)" = 1 ] && ok "4th bad run inside the window → no second mail (rate limit)" || bad "flooded: $(mail_calls) mails"
T_ALERT_EVERY=0 T_FREE=1 run_jac "$G" >/dev/null
[ "$(mail_calls)" = 2 ] && ok "window elapsed → mails again" || bad "expected 2 mails, got $(mail_calls)"
rm -f "$WORK/state.json" "$WORK/gc-calls"
for i in 1 2 3; do STUB_FAIL=1 T_FREE=1 run_jac "$G" >/dev/null; done
STUB_FAIL=1 T_FREE=1 run_jac "$G" >/dev/null
[ "$(mail_calls)" = 2 ] && ok "a mail that failed to send is retried next run (attempted != delivered)" || bad "failed mail not retried (calls=$(mail_calls))"
run_jac "$G" >/dev/null
[ "$(state_field "$G" bad_streak)" = 0 ] && ok "a good run resets bad_streak to 0" || bad "bad_streak=$(state_field "$G" bad_streak) after a good run"

echo ""
echo "=== S10: --check is read-only and reports BAD by exit code ==="
H="$WORK/h"; mkrepo "$H" 20; LC="$(loose_count "$H")"; rm -rf "$WORK/state.json" "$WORK/log" "$WORK/lock"
out="$(T_ALARM=1024 run_jac "$H" --check)"; rc=$?
[ "$rc" -eq 1 ] && ok "over the alarm size → exit 1" || bad "--check exit $rc, want 1: $out"
[ "$(loose_count "$H")" = "$LC" ] && [ ! -e "$WORK/state.json" ] && [ ! -e "$WORK/log" ] && [ ! -e "$WORK/lock" ] && ok "read-only: no repack, no state, no log, no lock" || bad "--check wrote something"
out="$(run_jac "$H" --check)"; rc=$?
[ "$rc" -eq 0 ] && ok "under the alarm size → exit 0" || bad "--check exit $rc on a healthy repo: $out"

echo ""
echo "=== S12: a loaded host — a batch that times out is halved and retried, and the size is remembered ==="
K="$WORK/k"; mkrepo "$K" 20; rm -f "$WORK/state.json" "$WORK/git-batches"
out="$(T_GIT="$WORK/git-slow" SLOW_ABOVE=20 T_GIT_TIMEOUT=2 T_BATCH=50 run_jac "$K")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(loose_count "$K")" = 0 ] && [ "$(last_status)" = "packed-loose" ] && ok "drained anyway (exit 0, no loose objects, status packed-loose)" || bad "did not drain under load (rc=$rc loose=$(loose_count "$K") status=$(last_status)): $out"
[ "$(head -n 3 "$WORK/git-batches" | tr '\n' ' ')" = "50 25 12 " ] && ok "batch sizes tried: 50 (timed out) -> 25 (timed out) -> 12 (fit)" || bad "batch sizes were: $(tr '\n' ' ' < "$WORK/git-batches")"
printf '%s' "$out" | grep -q 'retrying with 25' && printf '%s' "$out" | grep -q 'retrying with 12' && ok "each timeout is logged with the size it retries at" || bad "timeouts not logged: $out"
[ "$(state_field "$K" batch_objects)" = 12 ] && ok "state remembers batch_objects=12 (a run that timed out does not grow it)" || bad "state batch_objects=$(state_field "$K" batch_objects)"
addcommits "$K" 20; rm -f "$WORK/git-batches"
# 60s cap here, not 2s: "fast" is judged in whole seconds against the cap (took*4 < cap), and 12 objects never sleep
out="$(T_GIT="$WORK/git-slow" SLOW_ABOVE=20 T_GIT_TIMEOUT=60 T_BATCH=50 run_jac "$K")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(head -n 1 "$WORK/git-batches")" = "12" ] && ok "next run starts at the remembered 12 — no timeout wasted rediscovering it" || bad "next run started at '$(head -n 1 "$WORK/git-batches")' (rc=$rc)"
[ "$(state_field "$K" batch_objects)" = 24 ] && ok "a clean run with a fast batch doubles the remembered size once (12 -> 24)" || bad "state batch_objects=$(state_field "$K" batch_objects), want 24"
git --git-dir="$K/.git" fsck --strict >/dev/null 2>&1 && ok "fsck clean after timeouts and retries" || bad "fsck failed"

echo ""
echo "=== S13: a batch that times out even at the minimum size is a FAILURE, never a quiet skip ==="
M="$WORK/m"; mkrepo "$M" 20; LC="$(loose_count "$M")"; rm -f "$WORK/state.json" "$WORK/git-batches"
out="$(T_GIT="$WORK/git-slow" SLOW_ABOVE=0 T_GIT_TIMEOUT=2 T_BATCH=8 run_jac "$M")"; rc=$?
[ "$rc" -eq 1 ] && [ "$(last_status)" = "timeout" ] && [ "$(loose_count "$M")" = "$LC" ] && ok "exit 1, status timeout, nothing lost ($LC loose objects intact)" || bad "min-size timeout handled wrong (rc=$rc status=$(last_status) loose=$(loose_count "$M"))"
[ "$(state_field "$M" bad_streak)" = 1 ] && ok "state: bad_streak 1" || bad "bad_streak=$(state_field "$M" bad_streak)"

echo ""
echo "=== S14: over the alarm size is BAD only when the run did not shrink it ==="
N="$WORK/n"; mkrepo "$N" 20; rm -f "$WORK/state.json"
out="$(T_ALARM=1024 T_MAX_BATCHES=1 T_BATCH=10 run_jac "$N")"; rc=$?
if [ "$(loose_kib "$N")" -ge 1024 ] && [ "$(loose_count "$N")" -lt 60 ] && [ "$rc" -eq 0 ] && [ "$(last_status)" = "deferred" ] && [ "$(state_field "$N" bad_streak)" = 0 ]; then
  ok "still over the alarm size but shrinking (60 -> $(loose_count "$N") objects) → exit 0, bad_streak 0: a draining backlog does not page"
else
  bad "draining backlog judged wrong (rc=$rc status=$(last_status) loose=$(loose_count "$N") $(loose_kib "$N")KiB streak=$(state_field "$N" bad_streak))"
fi
out="$(T_ALARM=1024 T_DEADLINE=29 run_jac "$N")"; rc=$?
[ "$rc" -eq 1 ] && [ "$(state_field "$N" bad_streak)" = 1 ] && ok "over the alarm size and NO progress (no time left to pack anything) → BAD, bad_streak 1" || bad "no-progress over-alarm judged wrong (rc=$rc streak=$(state_field "$N" bad_streak)): $out"

echo ""
echo "=== S11: what actually runs in production ==="
cfg="$(bash "$SCRIPT" --print-config)"
printf '%s' "$cfg" | grep -q 'packs/maintenance/jsonl-archive' && printf '%s' "$cfg" | grep -q 'packs/town-deltas/jsonl-archive' \
  && ok "default repos: BOTH archives (maintenance + town-deltas)" || bad "default repos wrong: $cfg"
S3SCRIPT="$CITY_ROOT/scripts/dolt-s3-backup.sh"
if [ -f "$S3SCRIPT" ]; then
  grep -q '^JSONL_ARCHIVE_DIR=.*packs/maintenance/jsonl-archive' "$S3SCRIPT" && ok "the archive dolt-s3-backup.sh mirrors is one of the compacted repos" || bad "dolt-s3-backup.sh mirrors a different archive path"
  grep -A2 -- 's3 sync "\$JSONL_ARCHIVE_DIR/"' "$S3SCRIPT" | grep -q -- '--exclude ".git/\*"' && ok "S3 sync excludes .git — history has no offsite copy, so compaction must never shorten it" || bad "S3 sync no longer excludes .git — re-read the header of jsonl-archive-compact.sh"
else
  ok "dolt-s3-backup.sh not in this tree — cross-checks skipped"
fi
[ -f "$ORDER" ] && ok "order file exists: $ORDER" || bad "order file missing: $ORDER"
trigger="$(sed -n 's/^trigger *= *"\(.*\)"/\1/p' "$ORDER")"; interval="$(sed -n 's/^interval *= *"\(.*\)"/\1/p' "$ORDER")"
timeout_s="$(sed -n 's/^timeout *= *"\(.*\)"/\1/p' "$ORDER")"; exec_line="$(sed -n 's/^exec *= *"\(.*\)"/\1/p' "$ORDER")"
case "$interval" in *m) isecs=$(( ${interval%m} * 60 )) ;; *h) isecs=$(( ${interval%h} * 3600 )) ;; *s) isecs=${interval%s} ;; *) isecs=0 ;; esac
case "$timeout_s" in *s) tsecs=${timeout_s%s} ;; *m) tsecs=$(( ${timeout_s%m} * 60 )) ;; *) tsecs=0 ;; esac
deadline="$(sed -n 's/^DEADLINE_S="\${JAC_DEADLINE_S:-\([0-9]*\)}".*/\1/p' "$SCRIPT")"
[ "$trigger" = "cooldown" ] && ok "order: trigger cooldown" || bad "order trigger '$trigger'"
{ [ "$isecs" -gt 0 ] && [ "$isecs" -le 3600 ]; } && ok "order: interval $interval <= 1h — at ~243MiB/h of new loose blobs compaction cannot silently lag by more than about an hour" || bad "order interval '$interval' is missing or over 1h"
{ [ "${deadline:-0}" -gt 0 ] && [ "$tsecs" -gt "${deadline:-0}" ] && [ "$isecs" -gt "$tsecs" ]; } && ok "order: timeout ${timeout_s} > script deadline ${deadline}s (it logs its own outcome) and interval > timeout (runs cannot overlap)" || bad "order timeout/interval inconsistent (interval=$isecs timeout=$tsecs deadline=${deadline:-?})"
[ "$exec_line" = '$PACK_DIR/assets/scripts/jsonl-archive-compact.sh' ] && ok "order: exec points at the script" || bad "order exec is '$exec_line'"

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
