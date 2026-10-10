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

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $1"; }     # a check that did NOT run (host too loaded for a timing fixture, a file not in this tree): counted apart, printed in RESULT — never a PASS

WORK="$(mktemp -d /tmp/jsonl-archive-compact-selftest.XXXXXX)"
trap 'type fg_stop_all >/dev/null 2>&1 && fg_stop_all; chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT      # S35 starts long-lived stand-in processes: stop them first. Fixtures below chmod directories read-only: give them back first, or the cleanup cannot remove them

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
[ -n "\${STUB_SLEEP:-}" ] && sleep "\$STUB_SLEEP"     # a hung gc / Dolt: sleeps in the foreground so \`timeout\` (whole process group) kills it like the real thing
[ "\${STUB_FAIL:-0}" != 0 ] && echo "gc-stub: mail refused (STUB_FAIL=\${STUB_FAIL})" >&2
exit "\${STUB_FAIL:-0}"
EOF
chmod +x "$WORK/gc-stub"
# git-failmaint: every `maintenance run` exits $FM_RC at once and does nothing (FM_RC=1: a batch that FAILED,
# e.g. pack-objects out of space; FM_RC=0: a batch that "succeeded" without packing anything, what git does
# when another maintenance run holds its lock). Everything else is plain git.
cat > "$WORK/git-failmaint" <<'EOF'
#!/bin/bash
case " $* " in *" maintenance run "*) exit "${FM_RC:-1}" ;; esac
exec git "$@"
EOF
chmod +x "$WORK/git-failmaint"
# git-slow: a stand-in for this host's permanent load — a `maintenance run` whose batch size is above
# $SLOW_ABOVE takes 8s (the test caps a batch at 2s), everything else is plain git. It logs every batch size.
cat > "$WORK/git-slow" <<EOF
#!/bin/bash
n=""; for a in "\$@"; do case "\$a" in maintenance.loose-objects.batchSize=*) n="\${a#*=}" ;; esac; done
case " \$* " in *" maintenance run "*) echo "\${n:-none}" >> "$WORK/git-batches"; if [ -n "\$n" ] && [ "\$n" -gt "\${SLOW_ABOVE:-999999}" ]; then sleep "\${SLOW_SLEEP:-8}"; fi ;; esac
exec git "\$@"
EOF
chmod +x "$WORK/git-slow"
# git-fx: fault injection for the steps AFTER a batch, plain git for everything else. Env controls (all optional):
#   FM_RC=<n>      every `maintenance run` exits <n> at once and does nothing (a failed batch)
#   SLOW_GC=1      `gc` sleeps $SLOW_SLEEP seconds (default 8) before running
#   SLOW_PRUNE=1   `prune-packed` sleeps $SLOW_SLEEP seconds before running
#   NOOP_PRUNE=1   `prune-packed` exits 0 and removes nothing (a read-only remount, permissions: it "succeeds" without pruning)
#   INFLOW_N=<n>   after every real `maintenance run`, <n> NEW loose objects land (an exporter commit during a batch)
# It sleeps in the foreground, so `timeout` (which signals its whole process group) kills it like a real slow git.
cat > "$WORK/git-fx" <<'EOF'
#!/bin/bash
gd=""; for a in "$@"; do case "$a" in --git-dir=*) gd="${a#*=}" ;; esac; done
case " $* " in
  *" maintenance run "*) [ -n "${FM_RC:-}" ] && exit "$FM_RC" ;;
  *" gc "*)              [ -n "${SLOW_GC:-}" ] && sleep "${SLOW_SLEEP:-8}" ;;
  *" prune-packed "*)    [ -n "${SLOW_PRUNE:-}" ] && sleep "${SLOW_SLEEP:-8}"; [ -n "${NOOP_PRUNE:-}" ] && exit 0 ;;
esac
git "$@"; rc=$?
case " $* " in
  *" maintenance run "*) if [ -n "${INFLOW_N:-}" ] && [ -n "$gd" ]; then
                           for _i in $(seq 1 "$INFLOW_N"); do head -c 3000 /dev/urandom | git --git-dir="$gd" hash-object -w --stdin >/dev/null; done
                         fi ;;
esac
exit $rc
EOF
chmod +x "$WORK/git-fx"

# run_jac <repo...> [-- --check]: the script under test, sealed off from the real world.
run_jac() {
  local repos="$1"; shift
  JAC_REPOS="$repos" JAC_STATE="${T_STATE:-$WORK/state.json}" JAC_LOG="${T_LOG:-$WORK/log}" JAC_LOCK="${T_LOCK:-$WORK/lock}" JAC_GC="${T_GC:-$WORK/gc-stub}" \
  JAC_LOOSE_LIMIT_KIB="${T_LIMIT:-1024}" JAC_LOOSE_ALARM_KIB="${T_ALARM:-100000}" JAC_BATCH_OBJECTS="${T_BATCH:-25}" \
  JAC_PACKS_LIMIT="${T_PACKS:-8}" JAC_PACKS_ALARM="${T_PACKS_ALARM:-20}" JAC_FREE_KIB="${T_FREE:-90000000}" \
  JAC_ALERT_EVERY_S="${T_ALERT_EVERY:-21600}" JAC_HEADROOM_KIB=0 \
  JAC_GIT="${T_GIT:-git}" JAC_GIT_TIMEOUT_S="${T_GIT_TIMEOUT:-300}" JAC_MAX_BATCHES="${T_MAX_BATCHES:-0}" JAC_DEADLINE_S="${T_DEADLINE:-780}" \
  JAC_MIN_BATCH_S="${T_MIN_BATCH:-}" JAC_GC_TIMEOUT_S="${T_GC_TIMEOUT:-}" JAC_MIN_GC_BUDGET_S="${T_MIN_GC:-}" \
  JAC_PRUNE_TIMEOUT_S="${T_PRUNE_TIMEOUT:-}" JAC_PRUNE_MIN_S="${T_PRUNE_MIN:-}" JAC_MAIL_TIMEOUT_S="${T_MAIL_TIMEOUT:-}" \
  JAC_LSOF="${T_LSOF:-}" JAC_RECLAIM_WAIT_S="${T_RECLAIM_WAIT:-}" JAC_PS="${T_PS:-}" JAC_PS_TIMEOUT_S="${T_PS_TIMEOUT:-}" \
  "$SCRIPT" "$@" 2>&1     # executed, not `bash $SCRIPT`: production runs the shebang (/bin/bash 3.2 on macOS), not whatever bash is first in PATH
}
last_status() { grep -o 'status=[a-z-]*' "$WORK/log" | tail -1 | cut -d= -f2; }
state_field() { jq -r --arg r "$1" ".[\$r].$2" "$WORK/state.json" 2>/dev/null; }
mail_calls()  { [ -f "$WORK/gc-calls" ] && wc -l < "$WORK/gc-calls" | tr -d ' ' || echo 0; }
# alarm_trace <log> — the alarm's LOG PROTOCOL as one word: every announced attempt ("alarm mail: sending now") is followed by exactly one outcome
# line (mailed / TIMED OUT / FAILED), and an outcome never appears without its attempt. Prints
#   closed          every attempt ended in exactly one outcome (or there were none)
#   open            the LAST attempt has no outcome — what a run that died mid-send leaves
#   BROKEN:<why>    an outcome with no attempt, a second outcome, or a new attempt over an unfinished one that no dead run explains
# An unfinished attempt followed by a new attempt is legitimate only when a "stale lock ... reclaiming" line lies between them (the dead run's
# lock was reclaimed). This is the structural half of the header's promise: it runs over the mails of S9 and of S25 A-E (each must end closed), and
# S25 F pins the one case it cannot close — a dead run — so the protocol is checked over many scenarios, not one.
alarm_trace() {
  awk '
    /alarm mail: sending now/ { if (open && !reclaimed) { print "BROKEN:attempt over an unfinished one"; bad = 1; exit } open = 1; reclaimed = 0; next }
    /stale lock \(owner gone/ { reclaimed = 1; next }
    /alarm mailed to mayor|alarm mail TIMED OUT|alarm mail FAILED/ { if (!open) { print "BROKEN:outcome without an attempt"; bad = 1; exit } open = 0; next }
    END { if (!bad) print (open ? "open" : "closed") }
  ' "$1"
}

echo "=== jsonl-archive-compact.selftest.sh ==="
[ -x "$SCRIPT" ] && ok "script exists and is executable" || { bad "script missing or not executable: $SCRIPT"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="; exit 1; }
bash -n "$SCRIPT" && ok "script parses (PATH bash)" || bad "script has a syntax error"
[ "$(head -n 1 "$SCRIPT")" = "#!/bin/bash" ] && ok "shebang is #!/bin/bash — the tests below execute the script through it" || bad "unexpected shebang: $(head -n 1 "$SCRIPT")"
/bin/bash -n "$SCRIPT" && ok "script parses under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION'), the shebang interpreter)" || bad "script does not parse under /bin/bash"

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
out="$(run_jac "$B $WORK/nope2")"; rc=$?
[ "$rc" -eq 0 ] && ok "primary present + the retired archive absent → exit 0 (the retired town-deltas archive may be gone)" || bad "retired-absent handling wrong (rc=$rc): $out"
# ...but the PRIMARY (the first one: the archive the exporter writes and dolt-s3-backup mirrors) may not be: it vanishing while the retired
# one still exists used to read as a healthy run (S29 has the rest)
out="$(run_jac "$WORK/nope1 $B")"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'PRIMARY archive' && ok "PRIMARY absent + the retired one present → exit 1 and the log names the PRIMARY (a vanished archive must not hide behind the leftover)" || bad "absent PRIMARY handling wrong (rc=$rc): $out"

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
grep 'alarm mail FAILED' "$WORK/log" | tail -1 | grep -q 'mail refused' \
  && ok "the log line for a failed alarm mail carries the CAUSE (what gc said), not just 'FAILED'" \
  || bad "failed-mail log line has no cause: $(grep 'alarm mail FAILED' "$WORK/log" | tail -1)"
run_jac "$G" >/dev/null
[ "$(state_field "$G" bad_streak)" = 0 ] && ok "a good run resets bad_streak to 0" || bad "bad_streak=$(state_field "$G" bad_streak) after a good run"
[ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" -ge 4 ] \
  && ok "log protocol: every one of the $(grep -c 'alarm mail: sending now' "$WORK/log") mail attempts above is announced ('sending now') and ends in exactly one outcome line" \
  || bad "alarm log protocol broken over the S9 mails: $(alarm_trace "$WORK/log"), attempts=$(grep -c 'alarm mail: sending now' "$WORK/log")"

echo ""
echo "=== S10: --check is read-only and reports BAD by exit code ==="
H="$WORK/h"; mkrepo "$H" 20; LC="$(loose_count "$H")"; rm -rf "$WORK/state.json" "$WORK/log" "$WORK/lock"
out="$(T_ALARM=1024 run_jac "$H" --check)"; rc=$?
[ "$rc" -eq 3 ] && ok "over the alarm size (measured, no order verdict to excuse it) → exit 3" || bad "--check exit $rc, want 3: $out"
printf '%s' "$out" | grep -q 'OVER THE ALARM SIZE' && ok "...and the LINE says so in words ('OVER THE ALARM SIZE'), so it cannot be read as a healthy one when only the exit code differs" || bad "--check's over-alarm line looks like a healthy one: $out"
[ "$(loose_count "$H")" = "$LC" ] && [ ! -e "$WORK/state.json" ] && [ ! -e "$WORK/log" ] && [ ! -e "$WORK/lock" ] && ok "read-only: no repack, no state, no log, no lock" || bad "--check wrote something"
out="$(run_jac "$H" --check)"; rc=$?
[ "$rc" -eq 0 ] && ok "under the alarm size → exit 0" || bad "--check exit $rc on a healthy repo: $out"
printf '%s' "$out" | grep -q 'OVER THE ALARM SIZE' && bad "a healthy repo's --check line claims to be over the alarm size: $out" || ok "...and a healthy repo's line does not say 'OVER THE ALARM SIZE'"
# the packs alarm is an alarm size too: 5 packs against JAC_PACKS_ALARM=3
HP="$WORK/hp"; mkrepo "$HP" 1; for i in 2 3 4 5; do addpack "$HP" "$i"; done
out="$(T_PACKS_ALARM=3 run_jac "$HP" --check)"; rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'OVER THE ALARM SIZE'; } && ok "packs >= the packs alarm → exit 3 and the line says 'OVER THE ALARM SIZE'" || bad "packs alarm --check wrong (rc=$rc): $out"

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
echo "=== S14: over the alarm size is BAD only when the run did not shrink it (S21: and shrinking is not draining if it refills faster) ==="
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
echo "=== S15: a batch that FAILED or did NOTHING never grows the remembered batch size ==="
# "fast" used to be judged from elapsed time BEFORE the exit code and the progress check, so a batch that
# died at once (pack-objects out of space at the disk floor) or did nothing (another maintenance run holds
# git's lock) was the FASTEST batch there is: the size doubled on runs where nothing succeeded, and the first
# run after the cause cleared started at up to 200 objects (~1GiB loose) that this loaded host cannot pack
# inside a batch timeout. Decided-on != acted-on.
for mode in "1:failed" "0:stalled"; do
  fmrc="${mode%%:*}"; want="${mode##*:}"
  R="$WORK/r-$want"; mkrepo "$R" 20; rm -f "$WORK/state.json"
  sizes=""; rcs=""
  for n in 1 2 3; do
    FM_RC="$fmrc" T_GIT="$WORK/git-failmaint" T_BATCH=20 run_jac "$R" >/dev/null; rcs="$rcs$?"
    sizes="$sizes $(state_field "$R" batch_objects)"
  done
  [ "$(last_status)" = "$want" ] && [ "$rcs" = 111 ] && ok "$want batches: status $want, exit 1 on every run" || bad "$want path not exercised (status=$(last_status) exit codes=$rcs)"
  [ "$sizes" = " 20 20 20" ] && ok "$want batches: the remembered batch size stays 20 across 3 runs" || bad "$want batches: remembered batch size was$sizes (want 20 20 20) — a run where nothing was packed grew it"
done
# the growth rule itself is intact: once the cause clears ($R is the last repo above, still 60 loose objects
# and a remembered 20), the run packs it in fast batches and doubles the size ONCE
T_BATCH=20 run_jac "$R" >/dev/null
[ "$(loose_count "$R")" = 0 ] && [ "$(state_field "$R" batch_objects)" = 40 ] && ok "cause cleared: a fast batch that really packed doubles it once (20 -> 40)" || bad "growth after recovery wrong (loose=$(loose_count "$R") batch_objects=$(state_field "$R" batch_objects), want 0 and 40)"

echo ""
echo "=== S16: a state file that is valid JSON of the wrong SHAPE must not silence the alarm ==="
# state_json accepted anything `jq -e .` accepts, and record()'s `jq '.[\$r] = ...'` errors on [] / 5 / "x" /
# a non-object entry; `|| new=""` then swallowed the error, so the state was never rewritten and bad_streak could
# never reach ALERT_AFTER: the one signal that says compaction is failing was off, with no log line.
G2="$WORK/g2"; mkrepo "$G2" 20
seed_state() {
  case "$1" in
    array) echo '[]' ;; number) echo '5' ;; string) echo '"x"' ;; true) echo 'true' ;; null) echo 'null' ;;
    entry-number) jq -n --arg r "$G2" '{($r): 5}' ;;
    entry-array) jq -n --arg r "$G2" '{($r): [1, 2]}' ;;
  esac
}
for shape in array number string true null entry-number entry-array; do
  rm -f "$WORK/state.json" "$WORK/gc-calls" "$WORK/log"
  seed_state "$shape" > "$WORK/state.json"
  T_FREE=1 run_jac "$G2" >/dev/null; T_FREE=1 run_jac "$G2" >/dev/null; T_FREE=1 run_jac "$G2" >/dev/null
  if [ "$(mail_calls)" = 1 ] && [ "$(state_field "$G2" bad_streak)" = 3 ] && jq -e 'type == "object"' "$WORK/state.json" >/dev/null 2>&1; then
    ok "state=$shape: 3 bad runs still reach the alarm (1 mail, bad_streak 3, state file healed to an object)"
  else
    bad "state=$shape: alarm silenced (mails=$(mail_calls) bad_streak=$(state_field "$G2" bad_streak) state=$(head -c 80 "$WORK/state.json" 2>/dev/null | tr '\n' ' '))"
  fi
  case "$shape" in
    entry-*) grep -q "state entry for $G2 is not an object" "$WORK/log" && ok "state=$shape: the repaired entry is LOGGED" || bad "state=$shape: repaired silently" ;;
    *)       grep -q 'unreadable — starting fresh.*not a JSON object' "$WORK/log" && ok "state=$shape: the reset is LOGGED" || bad "state=$shape: reset silently" ;;
  esac
done
# the entry IS an object but a numeric field in it is not a non-negative whole number: is_uint || 0 read it as 0 with no
# trace, so a corrupted bad_streak restarted the count and a corrupted last_alert_epoch meant "never alerted" (mail again)
for fld in '"bad_streak":"x"' '"bad_streak":-2' '"bad_streak":[3]' '"bad_streak":2.5' '"last_alert_epoch":"soon"' '"batch_objects":"big"' '"loose_kib":"big"' '"loose_kib":-7' '"loose_kib":[1]'; do
  rm -f "$WORK/state.json" "$WORK/gc-calls" "$WORK/log"
  jq -n --arg r "$G2" --argjson f "{$fld}" '{($r): $f}' > "$WORK/state.json"
  T_FREE=1 run_jac "$G2" >/dev/null; T_FREE=1 run_jac "$G2" >/dev/null; T_FREE=1 run_jac "$G2" >/dev/null
  key="${fld%%:*}"; key="${key//\"/}"
  if [ "$(mail_calls)" = 1 ] && [ "$(state_field "$G2" bad_streak)" = 3 ] && grep -q "state entry for $G2: field(s) $key" "$WORK/log" 2>/dev/null; then
    ok "state field $fld: dropped and LOGGED; 3 bad runs still reach the alarm (1 mail, bad_streak 3)"
  else
    bad "state field $fld: mails=$(mail_calls) bad_streak=$(state_field "$G2" bad_streak) log=[$(grep 'state entry' "$WORK/log" 2>/dev/null | head -2 | tr '\n' ' ')]"
  fi
done
# a well-formed entry is left exactly as it is (the sanitising must not eat a healthy state)
rm -f "$WORK/state.json" "$WORK/gc-calls" "$WORK/log"
jq -n --arg r "$G2" '{($r): {bad_streak: 1, last_alert_epoch: 0, batch_objects: 20, loose_kib: null}}' > "$WORK/state.json"
T_FREE=1 run_jac "$G2" >/dev/null
[ "$(state_field "$G2" bad_streak)" = 2 ] && [ "$(state_field "$G2" batch_objects)" = 20 ] && ! grep -q 'state entry' "$WORK/log" \
  && ok "a healthy entry is kept (bad_streak 1 -> 2, batch_objects 20 untouched; loose_kib null — what a run that could not measure records — is legal) and nothing is logged about it" \
  || bad "a healthy entry was disturbed (bad_streak=$(state_field "$G2" bad_streak) batch_objects=$(state_field "$G2" batch_objects))"
# and when the state STILL cannot be rewritten (jq itself fails), that is loud and fails the run — not a quiet skip
mkdir -p "$WORK/jqshim"; REAL_JQ="$(command -v jq)"
cat > "$WORK/jqshim/jq" <<EOF
#!/bin/bash
case "\$*" in *last_run_epoch*) echo "jq: forced failure (selftest)" >&2; exit 5 ;; esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$WORK/jqshim/jq"
rm -f "$WORK/state.json" "$WORK/log"
out="$(PATH="$WORK/jqshim:$PATH" run_jac "$G2")"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'state update FAILED' "$WORK/log" && grep -q 'forced failure' "$WORK/log"; } \
  && ok "jq failing while writing the state → logged with jq's own reason, and the run exits 1 (the alarm is blind, so the order must not look green)" \
  || bad "a failed state update was not loud (rc=$rc): $(tail -n 3 "$WORK/log" 2>/dev/null | tr '\n' ' ')"

echo ""
echo "=== S17: a batch cut by the RUN DEADLINE is deferred — it is not evidence the batch was too big ==="
# The clamp t_left = min(remaining, GIT_TIMEOUT_S) made a kill at the DEADLINE look like a batch timeout: the
# size was halved and remembered (in a big drain every run ends with a cut batch, so it ratcheted down), and at
# the minimum size the same kill was STATUS=timeout — BAD from the budget alone.
V="$WORK/v"; mkrepo "$V" 20; rm -f "$WORK/state.json" "$WORK/git-batches"
out="$(T_GIT="$WORK/git-slow" SLOW_ABOVE=0 SLOW_SLEEP=60 T_GIT_TIMEOUT=300 T_DEADLINE=8 T_MIN_BATCH=1 T_BATCH=25 run_jac "$V")"; rc=$?
if [ ! -s "$WORK/git-batches" ]; then skip "no batch started inside this test's 8s budget (host too loaded): $out"; else
  { [ "$rc" -eq 0 ] && [ "$(last_status)" = "deferred" ]; } && ok "deadline cut at a normal size → status deferred, exit 0" || bad "deadline cut judged wrong (rc=$rc status=$(last_status)): $out"
  [ "$(state_field "$V" batch_objects)" = 25 ] && ok "the remembered batch size is kept (25) — the budget ended, not the batch" || bad "remembered batch size was changed to $(state_field "$V" batch_objects) by a deadline cut"
  printf '%s' "$out" | grep -q 'retrying with' && bad "a deadline cut was logged as 'retrying with a smaller batch': $out" || ok "no 'retrying with' — the size was not halved"
  printf '%s' "$out" | grep -q 'run deadline' && ok "the log says the RUN DEADLINE cut it" || bad "log does not name the deadline: $out"
fi
rm -f "$WORK/state.json" "$WORK/git-batches"
out="$(T_GIT="$WORK/git-slow" SLOW_ABOVE=0 SLOW_SLEEP=60 T_GIT_TIMEOUT=300 T_DEADLINE=8 T_MIN_BATCH=1 T_BATCH=5 run_jac "$V")"; rc=$?
if [ ! -s "$WORK/git-batches" ]; then skip "no batch started at the minimum size inside this test's 8s budget (host too loaded): $out"; else
  { [ "$rc" -eq 0 ] && [ "$(last_status)" = "deferred" ]; } && ok "deadline cut at the MINIMUM size → deferred, exit 0 (not the 'timeout' failure)" || bad "min-size deadline cut judged wrong (rc=$rc status=$(last_status)): $out"
fi

echo ""
echo "=== S18: tier 2 after a failed tier 1 — a gc that repaired the repo clears it, a gc that never ran does not ==="
# Tier 1 (batches) failed and packs are over the limit, so the consolidating gc runs. The alarm judges the END
# state: gc succeeding packs the loose objects too (the failure was transient → clean), but a gc that was
# "busy" (another one running) did nothing — that must not launder a failed tier 1 into a green run.
mkfailrepo() { local d="$1"; mkrepo "$d" 1; for i in 2 3 4 5; do addpack "$d" "$i"; done; addcommits "$d" 20; }
W="$WORK/w"; mkfailrepo "$W"; rm -f "$WORK/state.json"
out="$(FM_RC=1 T_GIT="$WORK/git-failmaint" T_PACKS=3 run_jac "$W")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "consolidated" ] && [ "$(loose_count "$W")" = 0 ]; } \
  && ok "batches failed, gc consolidated and packed the loose objects → status consolidated, exit 0 (judged on the end state)" \
  || bad "failed tier 1 + successful gc judged wrong (rc=$rc status=$(last_status) loose=$(loose_count "$W")): $out"
W2="$WORK/w2"; mkfailrepo "$W2"; rm -f "$WORK/state.json"; echo "$$ $(hostname)" > "$W2/.git/gc.pid"
out="$(FM_RC=1 T_GIT="$WORK/git-failmaint" T_PACKS=3 run_jac "$W2")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(last_status)" = "failed" ] && printf '%s' "$out" | grep -q 'already running'; } \
  && ok "batches failed, gc was busy (did nothing) → status stays failed, exit 1 (busy does not launder a failure)" \
  || bad "failed tier 1 + busy gc judged wrong (rc=$rc status=$(last_status)): $out"
rm -f "$W2/.git/gc.pid"
# no-op-must-not-launder, the skipped-low-disk sibling: tier 1 was skipped for LOW DISK, packs are over the limit, and the
# gc that would have consolidated is busy. `busy` used to replace anything but failed/stalled/timeout/unmeasured, so a
# skipped-low-disk backlog went green. The free space is set BETWEEN the two needs (tier 1 needs loose/4, the gc needs the pack
# size), computed from the fixture rather than guessed.
W3="$WORK/w3"; mkrepo "$W3" 1; for i in 2 3 4 5; do addpack "$W3" "$i"; done; addcommits "$W3" 60
rm -f "$WORK/state.json"; echo "$$ $(hostname)" > "$W3/.git/gc.pid"
need1=$(( $(loose_kib "$W3") / 4 )); need2="$(git --git-dir="$W3/.git" count-objects -v | awk '/^size-pack:/{print $2}')"; free3=$(( (need1 + need2) / 2 ))
if [ "$need2" -lt "$free3" ] && [ "$free3" -lt "$need1" ]; then
  out="$(T_FREE="$free3" T_PACKS=3 run_jac "$W3")"; rc=$?
  { [ "$rc" -eq 1 ] && [ "$(last_status)" = "skipped-low-disk" ] && printf '%s' "$out" | grep -q 'already running'; } \
    && ok "tier 1 skipped for low disk, gc busy (did nothing) → status stays skipped-low-disk, exit 1 (busy does not launder it either)" \
    || bad "skipped-low-disk + busy gc judged wrong (rc=$rc status=$(last_status)): $out"
else
  bad "fixture arithmetic: need tier2=${need2}KiB < free=${free3}KiB < need tier1=${need1}KiB"
fi
rm -f "$W3/.git/gc.pid"

echo ""
echo "=== S19: a consolidating gc cut by the RUN DEADLINE is deferred — only gc's OWN cap running out is a timeout ==="
# Tier 2 clamped t_left = min(remaining, GC_TIMEOUT_S) and reported ANY rc 124 as STATUS=timeout (BAD, exit 1, streak+1, and an alarm
# mail claiming "the repo is too big for one order run"). The run that crosses the pack limit is by construction one whose tier 1 just
# spent part of the budget, so a gc starting with less than its cap left is normal — and a killed gc keeps no work, so the next run
# starts it again from a fresh budget. The batch tier already told the two kills apart; this is its sibling.
mkpacks() { local d="$1"; mkrepo "$d" 1; for i in 2 3 4 5 6; do addpack "$d" "$i"; done; }
X="$WORK/x"; mkpacks "$X"; rm -f "$WORK/state.json" "$WORK/log"
out="$(T_GIT="$WORK/git-fx" SLOW_GC=1 SLOW_SLEEP=60 T_PACKS=4 T_DEADLINE=12 T_MIN_GC=2 run_jac "$X")"; rc=$?
if ! printf '%s' "$out" | grep -q 'gc was cut by the run deadline'; then
  if printf '%s' "$out" | grep -q 'gc deferred to the next run'; then skip "gc never started inside this test's 12s budget (host too loaded)"
  else bad "gc cut by the deadline: no 'cut by the run deadline' line (rc=$rc status=$(last_status)): $out"; fi
else
  { [ "$rc" -eq 0 ] && [ "$(last_status)" = "deferred" ] && [ "$(state_field "$X" bad_streak)" = 0 ]; } \
    && ok "gc killed by the run deadline → status deferred, exit 0, bad_streak 0 (the budget ended; nothing was shown about the repo)" \
    || bad "deadline-cut gc judged wrong (rc=$rc status=$(last_status) streak=$(state_field "$X" bad_streak)): $out"
  printf '%s' "$out" | grep -q 'gc timed out' && bad "a deadline-cut gc was logged as 'gc timed out': $out" || ok "no 'gc timed out' line for a deadline cut"
fi
rm -f "$WORK/state.json" "$WORK/log"
out="$(T_GIT="$WORK/git-fx" SLOW_GC=1 SLOW_SLEEP=20 T_PACKS=4 T_GC_TIMEOUT=2 run_jac "$X")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(last_status)" = "timeout" ] && printf '%s' "$out" | grep -q 'gc timed out after 2s (its own cap)'; } \
  && ok "gc that runs out its OWN cap (2s of a 780s budget) → status timeout, exit 1: the repo really is too big for one gc" \
  || bad "own-cap gc timeout judged wrong (rc=$rc status=$(last_status)): $out"
# a gc that was cut must not turn a FAILED tier 1 green either (the batches fail at once; the gc never finishes)
W4="$WORK/w4"; mkrepo "$W4" 1; for i in 2 3 4 5; do addpack "$W4" "$i"; done; addcommits "$W4" 20; rm -f "$WORK/state.json" "$WORK/log"
out="$(FM_RC=1 SLOW_GC=1 SLOW_SLEEP=60 T_GIT="$WORK/git-fx" T_PACKS=3 T_DEADLINE=12 T_MIN_BATCH=1 T_MIN_GC=2 run_jac "$W4")"; rc=$?
if printf '%s' "$out" | grep -q 'gc deferred to the next run'; then skip "gc never started inside this test's 12s budget (host too loaded)"
else
  { [ "$rc" -eq 1 ] && [ "$(last_status)" = "failed" ] && printf '%s' "$out" | grep -q 'batch 1 failed rc=1' && printf '%s' "$out" | grep -q 'gc was cut by the run deadline'; } \
    && ok "batches failed, gc cut by the deadline (did nothing) → status stays failed, exit 1 (a cut gc does not launder a failure)" \
    || bad "failed tier 1 + deadline-cut gc judged wrong (rc=$rc status=$(last_status)): $out"
fi

echo ""
echo "=== S20: prune-packed obeys the run budget too — cut by the deadline is deferred, its OWN cap running out is a failure ==="
# prune-packed had a fixed 120s cap regardless of what was left of the run: a batch ending at the deadline plus a slow prune could
# run to the order's own 900s kill before the outcome was logged. Clamped to the budget, a kill by the budget must not read as a failure.
Y="$WORK/y"; mkrepo "$Y" 20; rm -f "$WORK/state.json" "$WORK/log"
out="$(T_GIT="$WORK/git-fx" SLOW_PRUNE=1 SLOW_SLEEP=60 T_DEADLINE=10 T_MIN_BATCH=1 T_PRUNE_MIN=1 T_BATCH=25 run_jac "$Y")"; rc=$?
if printf '%s' "$out" | grep -qE 'batch 1 \([0-9]+ objects\) was cut by the run deadline'; then skip "the batch itself was cut before prune-packed inside this test's 10s budget (host too loaded)"
else
  { [ "$rc" -eq 0 ] && [ "$(last_status)" = "deferred" ] && [ "$(state_field "$Y" batch_objects)" = 25 ] && printf '%s' "$out" | grep -q 'prune-packed after batch 1 was cut by the run deadline'; } \
    && ok "prune-packed killed by the run deadline → status deferred, exit 0, remembered batch size kept (25); it was NOT capped at a fixed 120s" \
    || bad "deadline-cut prune judged wrong (rc=$rc status=$(last_status) batch_objects=$(state_field "$Y" batch_objects)): $out"
fi
rm -f "$WORK/state.json" "$WORK/log"
out="$(T_GIT="$WORK/git-fx" SLOW_PRUNE=1 SLOW_SLEEP=20 T_PRUNE_TIMEOUT=2 T_BATCH=25 run_jac "$Y")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(last_status)" = "failed" ] && printf '%s' "$out" | grep -q 'timed out after 2s, its own cap'; } \
  && ok "prune-packed that runs out its OWN cap → status failed, exit 1, and the log says it timed out at its own cap" \
  || bad "own-cap prune timeout judged wrong (rc=$rc status=$(last_status)): $out"

echo ""
echo "=== S21: 'draining' means smaller than where the PREVIOUS run left it — not just smaller than this run's start ==="
# The exemption was judged per run (end < this run's start), so a backlog emptied more slowly than it refills shrank a little every run,
# grew overall, and never paged at any size.
Z="$WORK/z"; mkrepo "$Z" 20; rm -f "$WORK/state.json" "$WORK/log" "$WORK/gc-calls"
T_ALARM=1024 T_MAX_BATCHES=1 T_BATCH=10 run_jac "$Z" >/dev/null; rc=$?
K1="$(state_field "$Z" loose_kib)"
{ [ "$rc" -eq 0 ] && [ "${K1:-0}" -ge 1024 ]; } && ok "run 1 (no earlier state): shrank the backlog, still over the alarm size (${K1}KiB) → exit 0 — a first run is judged on its own before/after" || bad "run 1 judged wrong (rc=$rc loose_kib=$K1)"
addcommits "$Z" 25      # refills by MORE than the next run empties (25 commits = ~75 objects vs a batch of 10)
out="$(T_ALARM=1024 T_MAX_BATCHES=1 T_BATCH=10 run_jac "$Z")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(state_field "$Z" bad_streak)" = 1 ] && printf '%s' "$out" | grep -q 'not draining'; } \
  && ok "run 2: the batch shrank the backlog but it ended ABOVE where run 1 left it (${K1}KiB → $(state_field "$Z" loose_kib)KiB) → BAD, bad_streak 1, and the log says 'not draining'" \
  || bad "refilling backlog judged wrong (rc=$rc streak=$(state_field "$Z" bad_streak) prev=${K1} now=$(state_field "$Z" loose_kib)): $out"
rm -f "$WORK/log"
out="$(T_ALARM=1024 T_MAX_BATCHES=1 T_BATCH=10 run_jac "$Z")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(state_field "$Z" bad_streak)" = 0 ] && ! printf '%s' "$out" | grep -q 'not draining'; } \
  && ok "run 3: emptied faster than it refills (ended below run 2's end) → exit 0, bad_streak back to 0, no 'not draining'" \
  || bad "genuinely draining backlog judged wrong (rc=$rc streak=$(state_field "$Z" bad_streak)): $out"

echo ""
echo "=== S22: an exporter commit landing DURING a batch does not read as 'stalled' when the batch did pack ==="
# 'stalled' was judged on the loose COUNT alone. The exporter adds ~9 loose objects per commit; at the minimum batch (5 objects) a commit
# landing mid-batch leaves the count higher even though the batch packed 5 — false stalled, BAD, and the drain stopped for that run.
Q="$WORK/q"; mkrepo "$Q" 20; rm -f "$WORK/state.json" "$WORK/log"; PQ0="$(pack_count "$Q")"
out="$(INFLOW_N=9 T_GIT="$WORK/git-fx" T_BATCH=5 T_MAX_BATCHES=3 run_jac "$Q")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "deferred" ] && [ "$(pack_count "$Q")" -ge $((PQ0 + 3)) ] && ! printf '%s' "$out" | grep -q 'no progress'; } \
  && ok "5-object batches with 9 new loose objects landing after each: 3 batches ran (packs $PQ0 -> $(pack_count "$Q")), status deferred, exit 0 — a new pack IS progress" \
  || bad "batch masked by inflow judged wrong (rc=$rc status=$(last_status) packs $PQ0->$(pack_count "$Q")): $out"
# ...but "a new pack" alone is not proof: a prune-packed that succeeds while removing NOTHING leaves every packed object's loose copy
# behind (prune-packable > 0), so the next batch would re-pack the same objects — a run that mints packs until the deadline.
Q2="$WORK/q2"; mkrepo "$Q2" 20; rm -f "$WORK/state.json" "$WORK/log"; PQ2="$(pack_count "$Q2")"
out="$(NOOP_PRUNE=1 T_GIT="$WORK/git-fx" T_BATCH=5 T_MAX_BATCHES=5 run_jac "$Q2")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(last_status)" = "stalled" ] && [ "$(pack_count "$Q2")" = $((PQ2 + 1)) ] && printf '%s' "$out" | grep -q 'prune-packable [1-9]'; } \
  && ok "prune-packed that removes nothing: the run stops STALLED after ONE batch (packs $PQ2 -> $(pack_count "$Q2"), prune-packable > 0 in the log) instead of re-packing the same objects" \
  || bad "no-op prune judged wrong (rc=$rc status=$(last_status) packs $PQ2->$(pack_count "$Q2")): $out"

echo ""
echo "=== S23: no timeout/gtimeout on the host → every run says so ==="
NT="$WORK/nt"; mkrepo "$NT" 20; rm -f "$WORK/state.json" "$WORK/log"
out="$(JAC_TIMEOUT_CMDS=no-such-timeout-cmd-xyz run_jac "$NT")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(loose_count "$NT")" = 0 ] && printf '%s' "$out" | grep -q 'WARNING: no timeout/gtimeout on PATH'; } \
  && ok "without a timeout binary the run still drains the repo (unbounded fallback) and logs a WARNING that nothing is time-bounded" \
  || bad "missing-timeout fallback wrong (rc=$rc loose=$(loose_count "$NT")): $out"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f "$WORK/log"; out="$(run_jac "$NT")"
  printf '%s' "$out" | grep -q 'WARNING: no timeout' && bad "the timeout warning fires although this host has a timeout binary" || ok "with a timeout binary present the warning stays quiet"
fi

echo ""
echo "=== S24: an EMPTY state file is a reset that is logged, not a silent 'no state yet' ==="
E0="$WORK/e0"; mkrepo "$E0" 2; : > "$WORK/state.json"; rm -f "$WORK/log"
out="$(run_jac "$E0")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'unreadable — starting fresh: it is empty' && [ -s "$WORK/state.json" ] && jq -e 'type == "object"' "$WORK/state.json" >/dev/null 2>&1; } \
  && ok "0-byte state file → logged as empty, replaced by a valid object" || bad "empty state file handled wrong (rc=$rc): $out"
rm -f "$WORK/state.json"; out="$(run_jac "$E0")"
printf '%s' "$out" | grep -q 'unreadable' && bad "an ABSENT state file (first run) was logged as a problem: $out" || ok "an absent state file (a first run) is not a problem and logs nothing about it"

echo ""
echo "=== S25: the alarm mail is RECORDED before it is sent — a state that cannot be written means no mail, not a mail every run ==="
# record() mailed first and persisted last_alert_epoch (the ONLY thing that rate-limits the mail) in the state write AFTER
# it. When that write failed, the mail that HAD been delivered was forgotten: the next run read the same streak and the same
# stale last_alert_epoch and mailed again, every 30 minutes — each one a permanent bead + Dolt commit, in the disk pressure
# this script exists for — and the log called the alarm "blind" when it was in fact repeating (an action took effect, its
# record was lost, so it is replayed). jq shim: fails only the state-update call (the one that mentions last_run_epoch);
# JQ_FAIL_WRITES lists which of a run's state writes fail by ordinal ("2"), or "all". Write 1 is the record-before-send,
# write 2 is giving the slot back after a failed send.
mkdir -p "$WORK/jqshim2"; REAL_JQ="$(command -v jq)"
cat > "$WORK/jqshim2/jq" <<EOF
#!/bin/bash
case "\$*" in *last_run_epoch*)
  n=\$(cat "$WORK/jq-writes" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$WORK/jq-writes"
  case ",\${JQ_FAIL_WRITES:-}," in *",\$n,"*|*",all,"*) echo "jq: forced failure (selftest)" >&2; exit 5 ;; esac ;;
esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$WORK/jqshim2/jq"
G3="$WORK/g3"; mkrepo "$G3" 20
# a streak already past ALERT_AFTER with no alert on record: every run below is one where the mail is DUE
seed_due() { rm -f "$WORK/state.json" "$WORK/gc-calls" "$WORK/log" "$WORK/jq-writes"; jq -n --arg r "$G3" '{($r): {bad_streak: 5, last_alert_epoch: 0}}' > "$WORK/state.json"; }
run_due() { rm -f "$WORK/jq-writes"; PATH="$WORK/jqshim2:$PATH" T_FREE=1 run_jac "$G3"; }   # T_FREE=1 → skipped-low-disk: a BAD run every time
T25="$(date +%s)"

# (A) the incident: the mail is due and the state cannot be written
seed_due; rcs=""
for n in 1 2 3; do JQ_FAIL_WRITES=all run_due >/dev/null; rcs="$rcs$?"; done
if [ "$(mail_calls)" = 0 ] && [ "$rcs" = 111 ] && [ "$(grep -c 'alarm due but NOT mailed' "$WORK/log")" = 3 ] && [ "$(state_field "$G3" last_alert_epoch)" = 0 ]; then
  ok "(A) state unwritable, mail due, 3 runs → 0 mails (was: 1 per run), exit 1 every run, 'NOT mailed' logged every run, nothing half-recorded"
else
  bad "(A) an unwritable state still mails or is quiet (mails=$(mail_calls) exit codes=$rcs 'NOT mailed' lines=$(grep -c 'alarm due but NOT mailed' "$WORK/log") last_alert_epoch=$(state_field "$G3" last_alert_epoch))"
fi
grep -q 'forced failure' "$WORK/log" && ok "(A) the jq reason is in the log" || bad "(A) the failure has no cause in the log: $(tail -n 3 "$WORK/log" | tr '\n' ' ')"
grep 'state update FAILED' "$WORK/log" | grep -q 'alarm is blind' && bad "(A) the log still claims the alarm is 'blind' although at streak >= threshold the old behaviour was to REPEAT it" || ok "(A) no false 'blind' claim in the failure text"
{ [ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 0 ]; } \
  && ok "(A) log protocol: a mail that could not be recorded is never announced as 'sending now' (0 attempts, 0 outcomes)" \
  || bad "(A) a mail that was never recorded or sent left an attempt line: $(alarm_trace "$WORK/log"), attempts=$(grep -c 'alarm mail: sending now' "$WORK/log")"

# (B) control: a healthy state → exactly one mail, on record, and the rate limit holds
seed_due; run_due >/dev/null; run_due >/dev/null
la="$(state_field "$G3" last_alert_epoch)"
if [ "$(mail_calls)" = 1 ] && [ "$la" -ge "$T25" ] 2>/dev/null; then
  ok "(B) healthy state → one mail, last_alert_epoch on record ($la), the second due-looking run is rate-limited"
else
  bad "(B) healthy path wrong (mails=$(mail_calls) last_alert_epoch=$la)"
fi
{ [ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 1 ] && [ "$(grep -c 'alarm mailed to mayor' "$WORK/log")" = 1 ]; } \
  && ok "(B) log protocol: 1 announced attempt, 1 'alarm mailed' outcome after it" \
  || bad "(B) log protocol broken: $(alarm_trace "$WORK/log"), attempts=$(grep -c 'alarm mail: sending now' "$WORK/log"), mailed=$(grep -c 'alarm mailed to mayor' "$WORK/log")"

# (C) a send that FAILS gives the slot back — attempted != delivered — and the next run retries
seed_due; STUB_FAIL=1 run_due >/dev/null
if [ "$(mail_calls)" = 1 ] && [ "$(state_field "$G3" last_alert_epoch)" = 0 ] && grep -q 'alarm mail FAILED.*mail refused.*will retry next run' "$WORK/log"; then
  ok "(C) failed send → last_alert_epoch back to 0 (not on record), the log carries the cause and says it retries"
else
  bad "(C) failed send left the slot claimed or unexplained (mails=$(mail_calls) last_alert_epoch=$(state_field "$G3" last_alert_epoch)): $(grep 'alarm' "$WORK/log" | tail -n 2 | tr '\n' ' ')"
fi
run_due >/dev/null
[ "$(mail_calls)" = 2 ] && [ "$(state_field "$G3" last_alert_epoch)" -ge "$T25" ] 2>/dev/null && ok "(C) the next run retries and records the mail that really went out" || bad "(C) no retry after a failed send (mails=$(mail_calls))"
{ [ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 2 ]; } \
  && ok "(C) log protocol: the failed attempt and the retry are each announced and each end in exactly one outcome" \
  || bad "(C) log protocol broken: $(alarm_trace "$WORK/log"), attempts=$(grep -c 'alarm mail: sending now' "$WORK/log")"

# (D) double fault: the send failed AND the slot could not be given back. The mail was NOT delivered, but it stays on record,
# so the next attempt waits out the window (bounded: ALERT_EVERY_S) — and both facts are logged and fail the run.
seed_due; STUB_FAIL=1 JQ_FAIL_WRITES=2 run_due >/dev/null; rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'alarm mail FAILED' "$WORK/log" && grep -q 'could not be released' "$WORK/log"; } \
  && ok "(D) send failed + slot not released → both logged, exit 1" \
  || bad "(D) double fault not loud (rc=$rc): $(grep 'alarm' "$WORK/log" | tail -n 3 | tr '\n' ' ')"
run_due >/dev/null
[ "$(mail_calls)" = 1 ] && ok "(D) the slot stays held for the window: no mail storm even then (1 attempt, retried after JAC_ALERT_EVERY_S)" || bad "(D) double fault re-mailed (mails=$(mail_calls))"
{ [ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 1 ]; } \
  && ok "(D) log protocol: 1 announced attempt, closed by its 'FAILED' outcome" \
  || bad "(D) log protocol broken: $(alarm_trace "$WORK/log"), attempts=$(grep -c 'alarm mail: sending now' "$WORK/log")"

# (E) a HUNG send is bounded by its own cap (a hung gc/Dolt must not hold the run until the order's kill). A send cut at
# the cap is delivery UNKNOWN — it may have gone out and only its return hung — so, unlike a send that FAILED (C: gc said
# so), it is NOT given back: retrying an unknown delivery could send it twice, and under doubt the inert state is "do not
# contact again". It says so loudly and fails the run; the next attempt waits out the window.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  seed_due; SECONDS=0; STUB_SLEEP=60 T_MAIL_TIMEOUT=2 run_due >/dev/null; rc=$?; took=$SECONDS
  if [ "$took" -lt 40 ] && [ "$rc" -eq 1 ] && [ "$(state_field "$G3" last_alert_epoch)" -ge "$T25" ] 2>/dev/null \
     && grep -q 'alarm mail TIMED OUT after 2s.*delivery UNKNOWN' "$WORK/log"; then
    ok "(E) a send that hangs is cut at JAC_MAIL_TIMEOUT_S (run took ${took}s, not 60), logged as TIMED OUT / delivery UNKNOWN, exit 1, and stays on record"
  else
    bad "(E) hung send not bounded, or not loud, or released (took=${took}s rc=$rc last_alert_epoch=$(state_field "$G3" last_alert_epoch)): $(grep 'alarm' "$WORK/log" | tail -n 2 | tr '\n' ' ')"
  fi
  run_due >/dev/null
  [ "$(mail_calls)" = 1 ] && ok "(E) no second send while the first one's delivery is unknown (1 attempt in the window)" || bad "(E) an unknown-delivery send was retried at once (mails=$(mail_calls))"
  { [ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 1 ]; } \
    && ok "(E) log protocol: the announced attempt is closed by its 'TIMED OUT' outcome" \
    || bad "(E) log protocol broken: $(alarm_trace "$WORK/log"), attempts=$(grep -c 'alarm mail: sending now' "$WORK/log")"
else
  skip "(E) no timeout/gtimeout on this host — the bounded-send check did NOT run"
fi

# (F) the run DIES between the record and the outcome — SIGKILL by the order's timeout, the OOM killer, a reboot. A dead process can log nothing and
# exit with nothing, so the header may not promise "is logged and exits 1" for it (it did, and the gate caught the claim). What it CAN promise, and
# this pins, is the TRACE: the mail is on record, the log's alarm lines end at "sending now" with no outcome after them, the dead run's lock is left
# behind and later reclaimed, and the slot stays taken (delivery not known: under doubt the inert state is "do not contact again"). The stub is `gc`
# itself: called to send the mail it SIGKILLs the run — the pid the run recorded in its own lock — and never answers. Deterministic, no timing.
cat > "$WORK/gc-suicide" <<EOF
#!/bin/bash
printf 'CALL %s\\n' "\$(printf '%s' "\$*" | tr '\\n' ' ')" >> "$WORK/gc-calls"
kill -9 "\$(cat "$WORK/lock/pid")"
exit 0
EOF
chmod +x "$WORK/gc-suicide"
seed_due; rm -rf "$WORK/lock"
out="$(T_GC="$WORK/gc-suicide" run_due 2>&1)"; rc=$?
[ "$rc" -eq 137 ] && [ "$(mail_calls)" = 1 ] && ok "(F) the run was SIGKILLed inside its own send (exit 137 = killed by signal 9: no exit path, no trap ran; gc was called once)" || bad "(F) the kill did not land mid-send (rc=$rc mails=$(mail_calls)): $out"
{ [ "$(alarm_trace "$WORK/log")" = open ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 1 ] && ! grep -q 'alarm mailed to mayor\|alarm mail TIMED OUT\|alarm mail FAILED' "$WORK/log"; } \
  && ok "(F) the trace: the log holds the announced attempt ('sending now') and NO outcome line after it — delivery not known, and visibly so" \
  || bad "(F) a run killed mid-send left no attempt-without-outcome trace (trace=$(alarm_trace "$WORK/log")): $(grep 'alarm' "$WORK/log" | tail -n 3 | tr '\n' ' ')"
{ [ "$(state_field "$G3" last_alert_epoch)" -ge "$T25" ] && [ "$(state_field "$G3" bad_streak)" = 6 ]; } 2>/dev/null \
  && ok "(F) the state says what the log says: the mail is on record (last_alert_epoch=$(state_field "$G3" last_alert_epoch)) and the streak advanced (6)" \
  || bad "(F) state after the kill: last_alert_epoch=$(state_field "$G3" last_alert_epoch) bad_streak=$(state_field "$G3" bad_streak)"
[ -d "$WORK/lock" ] && ok "(F) the dead run's lock is left behind (its EXIT trap never ran), as the lock section of the header describes" || bad "(F) no lock left by a SIGKILLed run"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" "$WORK/lock"
run_due >/dev/null; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(mail_calls)" = 1 ] && grep -q 'stale lock (owner gone' "$WORK/log" && [ "$(alarm_trace "$WORK/log")" = open ]; } \
  && ok "(F) the next run reclaims the dead run's lock ('stale lock ... reclaiming' in the log), does NOT mail again inside the window (1 call in total), and the unfinished attempt stays visible" \
  || bad "(F) run after the kill wrong (rc=$rc mails=$(mail_calls) trace=$(alarm_trace "$WORK/log")): $(tail -n 3 "$WORK/log" | tr '\n' ' ')"
T_ALERT_EVERY=0 run_due >/dev/null
{ [ "$(mail_calls)" = 2 ] && [ "$(alarm_trace "$WORK/log")" = closed ] && [ "$(grep -c 'alarm mail: sending now' "$WORK/log")" = 2 ]; } \
  && ok "(F) once the window has passed the alarm goes out again, its attempt closed by an outcome (the unfinished one before it is explained by the reclaimed lock)" \
  || bad "(F) no alarm after the window / protocol broken (mails=$(mail_calls) trace=$(alarm_trace "$WORK/log"))"
[ ! -d "$WORK/lock" ] && ok "(F) no lock left after a normal run" || bad "(F) a lock is left after a normal run"
# the trace check itself bites: each of its three verdicts is reachable
tl="$WORK/trace-fixture.log"
printf '%s\n' 'x alarm mail: sending now' 'x alarm mailed to mayor' > "$tl";                        t1="$(alarm_trace "$tl")"
printf '%s\n' 'x alarm mail: sending now' > "$tl";                                                 t2="$(alarm_trace "$tl")"
printf '%s\n' 'x alarm mail: sending now' 'x alarm mail: sending now' > "$tl";                      t3="$(alarm_trace "$tl")"
printf '%s\n' 'x alarm mailed to mayor' > "$tl";                                                    t4="$(alarm_trace "$tl")"
printf '%s\n' 'x alarm mail: sending now' 'x stale lock (owner gone, x)' 'x alarm mail: sending now' 'x alarm mail FAILED (y)' > "$tl"; t5="$(alarm_trace "$tl")"
{ [ "$t1" = closed ] && [ "$t2" = open ] && [ "${t3%%:*}" = BROKEN ] && [ "${t4%%:*}" = BROKEN ] && [ "$t5" = closed ]; } \
  && ok "(F) the protocol check bites: pair=closed, lone attempt=open, attempt over an unfinished one=BROKEN, outcome without attempt=BROKEN, unfinished + reclaim + new pair=closed" \
  || bad "(F) protocol check verdicts wrong: pair=$t1 lone=$t2 double=$t3 orphan-outcome=$t4 reclaimed=$t5"
# the header names the log lines the alarm path emits — every phrase it quotes must really be one of the script's log lines (a comment that promises a trace
# the code does not write is worse than none: it stops the next reader from looking for the hole)
header="$(sed -n '1,/^set -uo pipefail/p' "$SCRIPT" | sed 's/^#[ ]*//' | tr '\n' ' ' | tr -s ' ')"
missing=""
for m in 'alarm mail: sending now' 'alarm mailed to mayor' 'alarm mail TIMED OUT' 'delivery UNKNOWN' 'alarm mail FAILED' 'slot given back' 'could not be released' 'alarm due but NOT mailed' 'stale lock'; do
  case "$header" in *"$m"*) ;; *) missing="$missing [header lacks: $m]" ;; esac
  grep 'log "' "$SCRIPT" | grep -qF -- "$m" || missing="$missing [no log line has: $m]"
done
[ -z "$missing" ] && ok "(F) the header's alarm vocabulary is the code's: all 9 phrases it quotes are in the header AND on a log line" || bad "(F) header/code drift in the alarm log vocabulary:$missing"

echo ""
echo "=== S26: 'could not take the lock' is NOT 'another run holds it' — the lock has three outcomes and only one may be a quiet exit 0 ==="
# take_lock treated EVERY failed mkdir as "the lock exists": when mkdir failed for another reason (EACCES/EROFS/ENOSPC, the lock path is a
# file) the run logged "another compaction run is in flight" and exited 0 — no compaction, no state, no streak, no mail, an order that looks
# green while the backlog grows ~5GiB/day: the incident, from a different door. The three outcomes:
#   (1) this run holds the lock                                              → compacts
#   (2) another run DEMONSTRABLY holds it (its lock directory exists, not stale) → exit 0, "in flight" — the only quiet no-op
#   (3) anything else (cannot create, cannot remove a stale one, cannot read its age, cannot record our pid) → exit 1, and the log says WHY
lockrepo() { L="$WORK/$1"; mkrepo "$L" 20; LCL="$(loose_count "$L")"; rm -f "$WORK/state.json" "$WORK/gc-calls"; : > "$WORK/log"; }
lock_case() {  # lock_case <label> <want-rc> <want-log-regex> <must-not-log-regex> <repo-must-stay-untouched:1|0>   (the run's output is in $out, its exit in $rc)
  local label="$1" wrc="$2" want="$3" wont="$4" untouched="$5" okk=1
  [ "$rc" -eq "$wrc" ] || okk=0
  printf '%s' "$out" | grep -qE "$want" || okk=0
  { [ -z "$wont" ] || ! printf '%s' "$out" | grep -qE "$wont"; } || okk=0
  if [ "$untouched" = 1 ] && [ "$(loose_count "$L")" != "$LCL" ]; then okk=0; fi
  if [ "$okk" -eq 1 ]; then ok "$label"; else bad "$label (rc=$rc want $wrc; loose $LCL->$(loose_count "$L")): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; fi
}
OLD3H="$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M.%S)"

# (A) the lock's parent directory is not writable: mkdir fails, NO lock directory exists — nobody is in flight
if [ "$(id -u)" -eq 0 ]; then skip "(A)-(D),(F): running as root — directory permissions do not bind it, the unwritable-path fixtures did NOT run"; else
lockrepo l1; mkdir -p "$WORK/ro"; chmod 555 "$WORK/ro"
out="$(T_LOCK="$WORK/ro/lock" run_jac "$L")"; rc=$?; chmod 755 "$WORK/ro"
lock_case "(A) lock parent unwritable → exit 1, 'could not create the lock' with mkdir's own reason, NOT 'in flight', repo untouched" 1 'could not create the lock .*(Permission denied|denied|Read-only)' 'in flight' 1
# (B) the lock path is a regular file (mkdir: File exists — but nothing is running)
lockrepo l2; : > "$WORK/lockfile"
out="$(T_LOCK="$WORK/lockfile" run_jac "$L")"; rc=$?
lock_case "(B) lock path is a regular file → exit 1, 'could not create the lock', NOT 'in flight'" 1 'could not create the lock' 'in flight' 1
# (C) the lock path is a dangling symlink
lockrepo l3; ln -s "$WORK/nowhere-at-all" "$WORK/locklink"
out="$(T_LOCK="$WORK/locklink" run_jac "$L")"; rc=$?
lock_case "(C) lock path is a dangling symlink → exit 1, 'could not create the lock', NOT 'in flight'" 1 'could not create the lock' 'in flight' 1
# (D) a STALE lock that cannot be removed (a directory with something in it): the reclaim's own mkdir then fails with "exists" — that is
# not "another run took it", it is a lock nobody can clear, and exit 0 here would repeat every 30 minutes for good
lockrepo l4; mkdir -p "$WORK/lockd/keep"; touch -t "$OLD3H" "$WORK/lockd"
out="$(T_LOCK="$WORK/lockd" run_jac "$L")"; rc=$?
lock_case "(D) stale lock that cannot be removed → exit 1, 'could not remove the stale lock', NOT 'contended'/'in flight'" 1 'could not remove the stale lock' 'in flight|contended' 1
fi
# (E) the reclaim really is RACED: the stale lock is removed, and another run takes the lock in the gap. Now it IS in flight — exit 0.
# A `mkdir` shim plays the other run: its 2nd plain mkdir of the lock creates the lock itself (owner: this shell, alive) and fails "File exists".
mkdir -p "$WORK/mkshim"
cat > "$WORK/mkshim/mkdir" <<EOF
#!/bin/bash
last="\${@: -1}"
if [ "\$last" = "$WORK/lockrace" ] && [ "\$1" != "-p" ]; then
  n=\$(cat "$WORK/mk-n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$WORK/mk-n"
  if [ "\$n" -ge 2 ]; then /bin/mkdir "\$last" && echo "$$" > "\$last/pid"; echo "mkdir: \$last: File exists" >&2; exit 1; fi
fi
exec /bin/mkdir "\$@"
EOF
chmod +x "$WORK/mkshim/mkdir"
lockrepo l5; rm -f "$WORK/mk-n"; mkdir -p "$WORK/lockrace"; touch -t "$OLD3H" "$WORK/lockrace"
out="$(PATH="$WORK/mkshim:$PATH" T_LOCK="$WORK/lockrace" run_jac "$L")"; rc=$?
lock_case "(E) stale lock removed, then ANOTHER run takes it first → exit 0 (single-flight held), repo untouched, and the log says another run took it" 0 'another run took the lock' 'could not' 1
rm -f "$WORK/lockrace/pid"; rmdir "$WORK/lockrace" 2>/dev/null
# (F) the pid cannot be written into the lock we just made (a `mkdir` shim leaves the new lock directory read-only). A lock with no owner
# pid looks dead after one minute, so a second run would reclaim the lock of a run that is still working: the run must stop, release the
# lock it made, and say so. (Not `umask`: that also breaks bash's own here-document temp files, which is a different failure.)
if [ "$(id -u)" -ne 0 ]; then
mkdir -p "$WORK/mkshim2"
cat > "$WORK/mkshim2/mkdir" <<EOF
#!/bin/bash
last="\${@: -1}"
if [ "\$last" = "$WORK/lockpid" ] && [ "\$1" != "-p" ]; then /bin/mkdir "\$last" && chmod 500 "\$last"; exit \$?; fi
exec /bin/mkdir "\$@"
EOF
chmod +x "$WORK/mkshim2/mkdir"
lockrepo l6
out="$(PATH="$WORK/mkshim2:$PATH" T_LOCK="$WORK/lockpid" run_jac "$L")"; rc=$?
lock_case "(F) cannot record the owner pid → exit 1, 'could not record', repo untouched" 1 'could not record this run.s pid' 'in flight' 1
[ ! -e "$WORK/lockpid" ] && ok "(F) ...and the lock it had made is released (nothing left for the next run to trip over)" || { bad "(F) the half-made lock was left behind"; chmod -R u+rwx "$WORK/lockpid"; rm -rf "$WORK/lockpid"; }
fi
# (G) the lock exists but its AGE cannot be read (find fails): a live run and a stale lock cannot be told apart. Was: "not stale" = "in flight" = exit 0.
mkdir -p "$WORK/findshim"; printf '#!/bin/bash\necho "find: forced failure (selftest)" >&2\nexit 1\n' > "$WORK/findshim/find"; chmod +x "$WORK/findshim/find"
lockrepo l7; mkdir -p "$WORK/lockage"; echo 999999 > "$WORK/lockage/pid"; touch -t "$OLD3H" "$WORK/lockage"
out="$(PATH="$WORK/findshim:$PATH" T_LOCK="$WORK/lockage" run_jac "$L")"; rc=$?
lock_case "(G) lock exists, its age cannot be read → exit 1, 'cannot tell', NOT 'in flight'" 1 'cannot tell whether the lock' 'in flight' 1
rm -f "$WORK/lockage/pid"; rmdir "$WORK/lockage" 2>/dev/null
# controls — the quiet exit 0 that stays: a lock directory that exists and is fresh, or whose owner is alive
lockrepo l8; mkdir -p "$WORK/lockfresh"
out="$(T_LOCK="$WORK/lockfresh" run_jac "$L")"; rc=$?
lock_case "(control) fresh lock directory → exit 0, 'in flight', repo untouched" 0 'in flight' 'could not' 1
rmdir "$WORK/lockfresh" 2>/dev/null
lockrepo l9; mkdir -p "$WORK/lockalive"; echo "$$" > "$WORK/lockalive/pid"; touch -t "$OLD3H" "$WORK/lockalive"
out="$(T_LOCK="$WORK/lockalive" run_jac "$L")"; rc=$?
lock_case "(control) owner alive but the lock is 3h old → hung run, reclaimed: exit 0 and the repo IS compacted" 0 'stale lock' 'could not' 0
[ "$(loose_count "$L")" = 0 ] && ok "(control) ...the stale-by-age lock was reclaimed and the work done" || bad "(control) hung-run lock not reclaimed (loose=$(loose_count "$L"))"
lockrepo l10
out="$(run_jac "$L")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(loose_count "$L")" = 0 ] && [ ! -e "$WORK/lock" ]; } && ok "(control) no lock at all → this run holds it, compacts, and releases it" || bad "(control) plain run wrong (rc=$rc loose=$(loose_count "$L"))"

echo ""
echo "=== S27: --check exit codes, and a backlog the ORDER is draining is not a deploy failure ==="
# --check exits 0 healthy / 1 cannot measure or no archive (a failure) / 2 usage / 3 over the alarm size (measured). It has ONE
# measurement and no run start, so it cannot see a backlog shrinking; the order can, and records its verdict (status, bad_streak,
# loose_kib, last_run_epoch) in the state. Over the alarm size is excused only by a FRESH verdict of a run that ended acceptably, at
# bad_streak 0, with the backlog not grown by more than one trigger since. Anything missing, stale or unreadable excuses nothing.
seed_verdict() {  # seed_verdict <name> — a fresh over-alarm repo $HC and the state of an order run that drained part of it (exit 0, bad_streak 0)
  HC="$WORK/hc-$1"; mkrepo "$HC" 20; rm -f "$WORK/state.json" "$WORK/log"
  T_ALARM=1024 T_MAX_BATCHES=1 T_BATCH=10 run_jac "$HC" >/dev/null
  { [ "$(state_field "$HC" bad_streak)" = 0 ] && [ "$(state_field "$HC" loose_kib)" -ge 1024 ]; } || bad "S27 fixture ($1): the draining run did not leave an over-alarm state (streak=$(state_field "$HC" bad_streak) loose_kib=$(state_field "$HC" loose_kib))"
}
edit_state() { jq --arg r "$HC" "$1" "$WORK/state.json" > "$WORK/state.new" && mv "$WORK/state.new" "$WORK/state.json"; }
check_rc() { out="$(T_ALARM=1024 run_jac "$HC" --check)"; rc=$?; }
seed_verdict base; ST_SUM="$(shasum "$WORK/state.json" | cut -d' ' -f1)"; check_rc
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'draining'; } && ok "over the alarm size, but the order's last run is fresh, ended at bad_streak 0 → --check exit 0 and says it is judged draining" || bad "--check ignored a fresh draining verdict (rc=$rc): $out"
printf '%s' "$out" | grep -q 'OVER THE ALARM SIZE' && bad "an EXCUSED (draining) over-alarm backlog is worded as an unexcused one: $out" || ok "the excused line says 'judged draining', not 'OVER THE ALARM SIZE' (the words are only for a backlog nothing excuses)"
[ "$(shasum "$WORK/state.json" | cut -d' ' -f1)" = "$ST_SUM" ] && ok "--check left the state file byte-identical (still read-only)" || bad "--check rewrote the state file"
seed_verdict stale; edit_state '.[$r].last_run_epoch = (now | floor) - 99999'; check_rc
[ "$rc" -eq 3 ] && ok "a STALE verdict (the order has not run for a day) excuses nothing → exit 3" || bad "stale verdict excused an over-alarm backlog (rc=$rc)"
seed_verdict streak; edit_state '.[$r].bad_streak = 1'; check_rc
[ "$rc" -eq 3 ] && ok "a verdict with bad_streak > 0 excuses nothing → exit 3" || bad "bad_streak 1 verdict excused (rc=$rc)"
seed_verdict failed; edit_state '.[$r].status = "failed"'; check_rc
[ "$rc" -eq 3 ] && ok "a verdict whose run FAILED excuses nothing → exit 3" || bad "failed-run verdict excused (rc=$rc)"
seed_verdict nosize; edit_state '.[$r].loose_kib = null'; check_rc
[ "$rc" -eq 3 ] && ok "a verdict that recorded no size (the run could not measure) excuses nothing → exit 3" || bad "null-size verdict excused (rc=$rc)"
seed_verdict grown; addcommits "$HC" 40; check_rc
[ "$rc" -eq 3 ] && ok "the backlog GREW by more than one trigger since the verdict → exit 3 (draining a while ago is not draining now)" || bad "grown backlog still excused (rc=$rc)"
seed_verdict nostate; rm -f "$WORK/state.json"; check_rc
[ "$rc" -eq 3 ] && ok "no state at all (a fresh deploy) → exit 3, not excused" || bad "no-state check wrong (rc=$rc)"
seed_verdict shape; printf '[]' > "$WORK/state.json"; check_rc
[ "$rc" -eq 3 ] && ok "a state file of the wrong shape excuses nothing → exit 3" || bad "wrong-shape state excused (rc=$rc)"
PB="$WORK/enclosing2"; mkrepo "$PB" 3; mkdir -p "$PB/sub/.git"; rm -f "$WORK/state.json"
out="$(run_jac "$PB/sub" --check)"; rc=$?
[ "$rc" -eq 1 ] && ok "a repo git cannot measure → exit 1 (a failure, not a size question)" || bad "unmeasurable repo: --check exit $rc, want 1: $out"

echo ""
echo "=== S28: the prod test tells 'cannot measure' from 'over the alarm', and does not fail a backlog the order is draining ==="
# story-ga-a3ar7h.sh treated every non-zero --check exit as "BAD archive", and ran --check BEFORE asking whether the order had ever fired: a fresh
# deploy onto an over-alarm backlog FAILED although the first tick would drain it, and so did a backlog the order was legitimately draining.
PROD="$PACK/assets/prod-tests/gascity/story-ga-a3ar7h.sh"
FC="$WORK/fakecity"; mkdir -p "$FC/packs/town-deltas/assets/scripts" "$FC/packs/town-deltas/orders" "$FC/.gc/logs" "$WORK/gcsb/bin"
cp "$SCRIPT" "$FC/packs/town-deltas/assets/scripts/jsonl-archive-compact.sh"; cp "$ORDER" "$FC/packs/town-deltas/orders/jsonl-archive-compact.toml"
cat > "$WORK/gcsb/bin/gc" <<EOF
#!/bin/bash
case " \$* " in
  *" order list "*) printf '{"orders":[{"name":"jsonl-archive-compact","source":"$FC/packs/town-deltas/orders/jsonl-archive-compact.toml"}]}' ;;
  *" order history "*)
     [ -n "\${HIST_FAIL:-}" ] && exit 1
     printf '{"ok":true,"entries":['; i=0; while [ "\$i" -lt "\${HIST_N:-0}" ]; do [ "\$i" -gt 0 ] && printf ','; printf '{"order":"jsonl-archive-compact","executed":"2026-09-26T00:00:0%sZ"}' "\$((i % 10))"; i=\$((i + 1)); done; printf ']}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/gcsb/bin/gc"
# ga-ck3sz7: the prod test resolves `gc` through PATH (unlike run_jac, which is handed JAC_GC=<absolute stub>), so it
# runs on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh). The stub above is the only `gc` it can find; if
# $WORK vanished under a running prod test, the real `gc` further down $PATH would answer `order list` / `order
# history` with the real town's orders. Here "command not found" is the only outcome.
. "$HERE/../selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $HERE/../selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK/gcsb" git jq timeout || exit 2   # git: the archives; jq: state; timeout: bounds git (the script warns without it); gc is the stub above
prod_run() {  # prod_run <repos> [alarm-KiB] — the prod test against the fake city; HIST_N / HIST_FAIL steer the fake gc
  out="$(PATH="$SANDBOX_PATH" CITY="$FC" JAC_REPOS="$1" JAC_STATE="$WORK/state.json" JAC_LOOSE_ALARM_KIB="${2:-100000}" JAC_LOOSE_LIMIT_KIB=1024 JAC_LOG="$WORK/log" bash "$PROD" 2>&1)"; rc=$?
}
PH="$WORK/ph"; mkrepo "$PH" 20; rm -f "$WORK/state.json"
HIST_N=2 prod_run "$PH"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PASS' && ! printf '%s' "$out" | grep -q 'unproven'; } && ok "healthy archive, order fired → PASS with nothing unproven" || bad "healthy prod run wrong (rc=$rc): $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ')"
rm -f "$WORK/state.json"; HIST_N=0 prod_run "$PH" 1024
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PASS (2 unproven' && printf '%s' "$out" | grep -qi 'over the alarm'; } && ok "fresh deploy onto an over-alarm backlog, order not fired yet → PASS naming BOTH unproven items (the controller never fired, the archive size — the first tick drains it) and counting them as 2, not FAIL" || bad "fresh-deploy prod run wrong (rc=$rc): $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ')"
rm -f "$WORK/state.json"; T_ALARM=1024 T_MAX_BATCHES=1 T_BATCH=10 JAC_REPOS="$PH" run_jac "$PH" >/dev/null; HIST_N=3 prod_run "$PH" 1024
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'draining'; } && ok "over the alarm size but the order (fired 3x) is draining it → PASS" || bad "draining backlog failed the prod test (rc=$rc): $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ')"
rm -f "$WORK/state.json"; HIST_N=3 prod_run "$PH" 1024
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'over the alarm'; } && ok "over the alarm size, order fired 3x, NO fresh verdict excusing it → FAIL naming the size" || bad "stuck backlog did not fail the prod test (rc=$rc): $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ')"
HIST_FAIL=1 prod_run "$PH" 1024
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'over the alarm'; } && ok "over the alarm size and whether the order ever fired is UNKNOWN (history unreadable) → FAIL, not a quiet pass" || bad "unknown history + over-alarm did not fail (rc=$rc): $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ')"
mkdir -p "$WORK/enclosing3"; mkrepo "$WORK/enclosing3" 2; mkdir -p "$WORK/enclosing3/sub/.git"; rm -f "$WORK/state.json"
HIST_N=0 prod_run "$WORK/enclosing3/sub"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'cannot measure'; } && ok "an archive git cannot measure → FAIL saying 'cannot measure' (even though the order has not fired: it is not a size question)" || bad "unmeasurable archive not told apart (rc=$rc): $(printf '%s' "$out" | tail -n 4 | tr '\n' ' ')"

echo ""
echo "=== S29: the PRIMARY archive is required; the retired one may be gone ==="
out="$(run_jac "$WORK/nope1 $B" --check)"; rc=$?
[ "$rc" -eq 1 ] && ok "--check: PRIMARY absent while the retired archive exists → exit 1" || bad "--check hid an absent PRIMARY (rc=$rc): $out"
out="$(run_jac "$B $WORK/nope2" --check)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check: PRIMARY present, retired absent → exit 0" || bad "--check failed on an absent retired archive (rc=$rc): $out"

echo ""
echo "=== S30: STRUCTURE — every place that DISCARDS a failure is named, justified and pinned ==="
# Four gate rounds in a row found one more place where a failure looked like a benign no-op, each after "the class was swept". The class is
# mechanical to list: the constructs that throw a failure away (`|| true`, `|| :`, `|| return 0`, `|| exit 0`, `exit 0`, `mkdir -p`, a bare
# `rm`/`rmdir` with its errors silenced). Each must carry `# benign[<key>]: <why a failure here cannot hide one that matters>` on its line or the
# line above, and the set of keys is PINNED below: adding one — or removing one — fails this test until a person has read the site and
# updated the pin. The scenarios that reach the exit-0 keys are S26 (lock-inflight, lock-lost-race) and S11 (print-config); the script has no literal
# success exit at the end of a run — its exit code is computed from the run's own results.
lint_sites() {  # lint_sites <file> — one line per discard site: "<line>|<key or MISSING>|<code>"
  awk '
    function annotation(s,   p, rest, q) {           # -> key when s carries "# benign[key]: <reason of 15+ chars>", else ""
      p = index(s, "# benign["); if (!p) return ""
      rest = substr(s, p + 9); q = index(rest, "]: "); if (q < 2) return ""
      if (length(substr(rest, q + 3)) < 15) return ""
      return substr(rest, 1, q - 1)
    }
    { L[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        s = L[n]
        if (s ~ /^[ \t]*#/ || s ~ /^[ \t]*$/) continue
        code = s; sub(/[ \t]+# benign\[.*$/, "", code)
        if (code ~ /\|\| *true([^a-z_]|$)/ || code ~ /\|\| *:([ ;]|$)/ || code ~ /\|\| *return 0/ || code ~ /\|\| *exit 0/ \
            || code ~ /(^|[ ;{])exit 0([ ;}]|$)/ || code ~ /(^|[ ;{])mkdir -p / || (code ~ /(^|[ ;{])(rm|rmdir) / && code ~ /2>\/dev\/null/)) {
          k = annotation(s); if (k == "" && n > 1 && L[n-1] ~ /^[ \t]*# benign\[/) k = annotation(L[n-1])
          printf "%d|%s|%s\n", n, (k == "" ? "MISSING" : k), code
        }
      }
    }' "$1"
}
SITES="$(lint_sites "$SCRIPT")"
MISSING="$(printf '%s\n' "$SITES" | grep '|MISSING|' || true)"
[ -n "$SITES" ] && ok "the lint sees the discard sites ($(printf '%s\n' "$SITES" | wc -l | tr -d ' ') of them)" || bad "the lint found no discard sites at all — it is not looking"
[ -z "$MISSING" ] && ok "every discard site carries '# benign[key]: <reason>'" || bad "discard site(s) with no justification: $(printf '%s' "$MISSING" | cut -c1-110 | tr '\n' ';')"
# the pin: keys and how many sites each names. Update it ONLY after reading the site.
EXPECTED_BENIGN="log-mkdir log-write log-trim lock-parent-mkdir lock-release lock-inflight lock-lost-race print-config state-mkdir state-tmp-cleanup"
got="$(printf '%s\n' "$SITES" | cut -d'|' -f2 | sort | tr '\n' ' ')"; want="$(printf '%s\n' $EXPECTED_BENIGN | sort | tr '\n' ' ')"
[ "$got" = "$want" ] && ok "the set of discard sites is exactly the pinned one" || bad "discard sites differ from the pin — got [$got] want [$want]: read the new/removed site, then update EXPECTED_BENIGN"
# the lint itself bites: a new unjustified discard is reported, a justified one is not
cp "$SCRIPT" "$WORK/lint-mutant.sh"
printf '%s\n' 'cleanup_thing || true' 'other_thing || true   # benign[x]: a short one' 'ok_thing || true   # benign[some-key]: this is a sufficiently long reason' 'mkdir -p /x' 'rm -f /y 2>/dev/null' >> "$WORK/lint-mutant.sh"
mm="$(lint_sites "$WORK/lint-mutant.sh" | grep -c '|MISSING|')"; mb="$(lint_sites "$SCRIPT" | grep -c '|MISSING|')"
[ "$((mm - mb))" -eq 4 ] && ok "the lint bites: 4 unjustified discards appended (bare || true, a 1-word reason, mkdir -p, silenced rm) are all reported; the justified one is not" || bad "lint did not catch the mutant (reported $((mm - mb)) of 4)"

echo ""
echo "=== S31: the remembered batch size is judged by FULL batches — a REMAINDER batch, or one that only pruned, is no evidence about the size ==="
# The last batch of a drain is a remainder (fewer loose objects left than the batch size): it finishes at once whatever the size is. "fast" used to be
# taken from the LAST batch, so two full batches that were each nearly too slow (took*4 just under the cap: not fast) followed by an instant remainder
# doubled the remembered size, and the next big drain wasted a whole batch cap finding out it was too big. Decided-on (the speed of a partial batch) !=
# acted-on (the size of full ones). git-slowfull slows ONLY a maintenance run that has at least a full batch of unpacked loose objects to pack.
cat > "$WORK/git-slowfull" <<'EOF'
#!/bin/bash
gd=""; n=""; for a in "$@"; do case "$a" in --git-dir=*) gd="${a#--git-dir=}" ;; maintenance.loose-objects.batchSize=*) n="${a#*=}" ;; esac; done
case " $* " in *" maintenance run "*)
  c="$(git --git-dir="$gd" count-objects -v | awk '/^count:/{print $2}')"; p="$(git --git-dir="$gd" count-objects -v | awk '/^prune-packable:/{print $2}')"
  s="$(date +%s)"
  if [ -n "$n" ] && [ $((c - p)) -ge "$n" ]; then sleep "${SLOWFULL_S:-0}"; fi
  git "$@"; rc=$?
  echo "$((c - p)) $(( $(date +%s) - s ))" >> "$SLOWFULL_LOG"      # <unpacked loose objects when it started> <seconds it took>
  exit $rc ;;
esac
exec git "$@"
EOF
chmod +x "$WORK/git-slowfull"
run_full() { SLOWFULL_S="$1" SLOWFULL_LOG="$WORK/git-fullbatches" T_GIT="$WORK/git-slowfull" T_GIT_TIMEOUT=20 T_BATCH="${3:-25}" run_jac "$2"; }   # run_full <sleep-s of a full batch> <repo> [batch size]
# (a) the reviewer's repro: 60 loose objects, batch 25 → full (60), full (35), remainder (10). The two full batches take ~6s of a 20s cap (6*4 >= 20: not fast).
RM="$WORK/rem"; mkrepo "$RM" 20; rm -f "$WORK/state.json" "$WORK/git-fullbatches"
out="$(run_full 6 "$RM")"; rc=$?
rem_took="$(tail -n 1 "$WORK/git-fullbatches" 2>/dev/null | awk '{print $2}')"; rem_n="$(tail -n 1 "$WORK/git-fullbatches" 2>/dev/null | awk '{print $1}')"
if [ "$(wc -l < "$WORK/git-fullbatches" | tr -d ' ')" != 3 ] || [ "${rem_n:-99}" -ge 25 ]; then
  if printf '%s' "$out" | grep -q 'timed out'; then
    skip "S31 (a) host too loaded: a full batch hit the 20s cap, so the fixture (2 full batches + a remainder) did not form — the remainder check did NOT run"
  else
    bad "S31 (a) fixture: expected 3 batches (full, full, remainder), got: $(tr '\n' ';' < "$WORK/git-fullbatches") rc=$rc: $out"
  fi
elif [ "${rem_took:-99}" -ge 5 ]; then
  skip "S31 (a) host too loaded: the remainder batch took ${rem_took}s (it must be under 5s to look fast) — the remainder check did NOT run"
else
  [ "$rc" -eq 0 ] && [ "$(loose_count "$RM")" = 0 ] && [ "$(last_status)" = "packed-loose" ] && ok "(a) drained by 2 slow full batches + 1 instant remainder (batches: $(tr '\n' ';' < "$WORK/git-fullbatches"))" || bad "(a) drain wrong (rc=$rc loose=$(loose_count "$RM") status=$(last_status))"
  [ "$(state_field "$RM" batch_objects)" = 25 ] && ok "(a) the remembered size stays 25: an instant REMAINDER after two slow full batches is no evidence that 25 is too small" || bad "(a) remembered batch_objects=$(state_field "$RM" batch_objects), want 25 — the remainder batch was credited as fast"
fi
# (b) control: growth itself is intact — full batches that ARE fast (and a remainder after them) still double the size once
RF="$WORK/remfast"; mkrepo "$RF" 20; rm -f "$WORK/state.json" "$WORK/git-fullbatches"
out="$(run_full 0 "$RF")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(state_field "$RF" batch_objects)" = 50 ] && ok "(b) control: full batches that were fast (then a remainder) still double the remembered size once (25 -> 50)" || bad "(b) growth broken (rc=$rc batch_objects=$(state_field "$RF" batch_objects), want 50): $out"
# (c) a batch that only PRUNED: every loose object is already in a pack, so there is nothing left to pack (the pack count stays put) and the loose copies
# are just removed. It is the fastest batch there is and proves nothing about packing 25 objects. prune-packable (60) is subtracted from the loose
# count (60): 0 to pack, not full.
RP="$WORK/rempr"; mkrepo "$RP" 20; rm -f "$WORK/state.json" "$WORK/git-fullbatches"
git --git-dir="$RP/.git" rev-list --objects --all | git --git-dir="$RP/.git" pack-objects -q "$RP/.git/objects/pack/pack" >/dev/null
pk0="$(git --git-dir="$RP/.git" count-objects -v | awk '/^prune-packable:/{print $2}')"; lc0="$(loose_count "$RP")"
out="$(run_full 0 "$RP")"; rc=$?
{ [ "$pk0" = "$lc0" ] && [ "$lc0" -ge 25 ]; } || bad "S31 (c) fixture: want every loose object already packed (prune-packable=$pk0 loose=$lc0)"
{ [ "$rc" -eq 0 ] && [ "$(loose_count "$RP")" = 0 ] && [ "$(state_field "$RP" batch_objects)" = 25 ]; } \
  && ok "(c) a batch that only pruned copies of already-packed objects ($lc0 of $lc0 loose were packed) does not grow the size (stays 25)" \
  || bad "(c) prune-only batch handled wrong (rc=$rc loose=$(loose_count "$RP") batch_objects=$(state_field "$RP" batch_objects), want 0 and 25): $out"
# (d) the boundary: a batch that had EXACTLY a full batch of objects to pack (60 loose, batch 60) packed a full-size batch — if it was fast, it counts
RE="$WORK/remexact"; mkrepo "$RE" 20; rm -f "$WORK/state.json" "$WORK/git-fullbatches"
out="$(run_full 0 "$RE" 60)"; rc=$?
{ [ "$(loose_count "$RE")" = 0 ] && [ "$(wc -l < "$WORK/git-fullbatches" | tr -d ' ')" = 1 ] && [ "$(awk '{print $1}' "$WORK/git-fullbatches")" = 60 ]; } || bad "S31 (d) fixture: want ONE batch that started with exactly 60 unpacked objects (batches: $(tr '\n' ';' < "$WORK/git-fullbatches") loose=$(loose_count "$RE"))"
[ "$rc" -eq 0 ] && [ "$(state_field "$RE" batch_objects)" = 120 ] && ok "(d) a batch of exactly the batch size (60 of 60) is a full batch: fast → the size doubles once (60 -> 120)" || bad "(d) boundary wrong (rc=$rc batch_objects=$(state_field "$RE" batch_objects), want 120): $out"

echo ""
echo "=== S32: a step killed mid-WRITE leaves a temp file — the run reclaims it, and a cut with a leak is not a clean cut ==="
# Gate ga-obhsaf: a batch cut by the run deadline (or by its own cap) left a partial objects/pack/tmp_pack_* on disk while the run reported a green
# `deferred` — +153MiB on a repo this script exists to shrink, on a filesystem at its floor, with exit 0 and streak 0. measure() read size-garbage and
# only printed it. Every timeout test before this one killed a `sleep` in front of git (git-slow, git-fx: the sleep runs BEFORE git), and a killed sleep
# leaves nothing. This section kills the REAL pack-objects: git-killwrite runs the real git and, once its pack-objects has written >= 1MB into its
# tmp_pack_*, SIGTERMs the whole git process tree (what `timeout` does) and exits 124 like `timeout`. Measured on this host's git: a killed `maintenance
# run` AND a killed `gc` both leave the tmp_pack_* (read-only, partial). If a git of another vintage cleans up after itself, or the write never gets
# that far, the test SKIPs — it never passes without having exercised the leak.
cat > "$WORK/git-killwrite" <<'EOF'
#!/bin/bash
# git-killwrite: plain git, except the FIRST invocation of the step named by $KW_STEP (maintenance | gc | prune-packed) is killed the way `timeout` kills a step
# — SIGTERM to the whole git process tree — once the REAL pack-objects has written >= $KW_MIN_BYTES into its tmp_pack_*; then it exits $KW_EXIT (124 = what
# `timeout` returns). $KW_MARK (created at the kill) makes every later call plain git, so a retry runs normally. $KW_LOG gets one line per decision.
gd=""; for a in "$@"; do case "$a" in --git-dir=*) gd="${a#--git-dir=}" ;; esac; done
case "${KW_STEP:-maintenance}" in
  maintenance)  pat=" maintenance run " ;;
  gc)           pat=" gc " ;;
  prune-packed) pat=" prune-packed " ;;
esac
case " $* " in *"$pat"*) ;; *) exec git "$@" ;; esac
[ -e "${KW_MARK:?}" ] && exec git "$@"
descendants() {  # the pid and every descendant, read from ps — never a pkill by name: this host runs other people's git all day
  ps -axo pid=,ppid= | awk -v root="$1" '{ p[$1] = $2 } END { print root; for (again = 1; again;) { again = 0; for (c in p) if (!(c in seen) && (p[c] == root || (p[c] in seen))) { seen[c] = 1; print c; again = 1 } } }'
}
git "$@" &
top=$!
while kill -0 "$top" 2>/dev/null; do
  big="$(find "$gd/objects/pack" -maxdepth 1 -name 'tmp_pack_*' -size +"${KW_MIN_BYTES:-1000000}"c 2>/dev/null | head -n 1)"
  if [ -n "$big" ]; then
    : > "$KW_MARK"
    sz="$(wc -c < "$big" | tr -d ' ')"
    for p in $(descendants "$top"); do kill -TERM "$p" 2>/dev/null; done
    wait "$top" 2>/dev/null
    sleep 0.3
    echo "killed ${KW_STEP:-maintenance} at $sz bytes of ${big##*/}; on disk after the kill: $(ls "$gd/objects/pack" | grep -c '^tmp_pack_') tmp_pack file(s)" >> "${KW_LOG:?}"
    exit "${KW_EXIT:-124}"
  fi
  sleep 0.01
done
wait "$top"; rc=$?
echo "finished-before-kill (${KW_STEP:-maintenance}, rc=$rc): the write never reached ${KW_MIN_BYTES:-1000000} bytes while git ran" >> "${KW_LOG:?}"
exit "$rc"
EOF
chmod +x "$WORK/git-killwrite"
# mkbig <dir> <commits> <MB>: N commits of one INCOMPRESSIBLE file — pack-objects needs a while to write it, so a step can be killed while it writes
mkbig() {
  local d="$1" n="$2" mb="$3" i
  git init -q "$d"
  for i in $(seq 1 "$n"); do
    head -c $(( mb * 1000000 )) /dev/urandom > "$d/hq.jsonl"
    git -C "$d" add hq.jsonl && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "big $i"
  done
}
# mkbigpacked <dir>: 4 big commits frozen into ONE pack + 1 loose big commit on top — what a gc has something to rewrite for
mkbigpacked() {
  local d="$1"; mkbig "$d" 4 12
  git --git-dir="$d/.git" rev-list --objects --all | git --git-dir="$d/.git" pack-objects -q "$d/.git/objects/pack/pack" >/dev/null; git --git-dir="$d/.git" prune-packed -q
  head -c 12000000 /dev/urandom > "$d/hq.jsonl"; git -C "$d" add hq.jsonl && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "big loose"
}
tmp_files()  { find "$1/.git/objects" -maxdepth 2 -type f -name 'tmp_*' 2>/dev/null | wc -l | tr -d ' '; }
garbage_of() { git --git-dir="$1/.git" count-objects -v 2>/dev/null | awk '/^garbage:/{print $2}'; }
have_lsof()  { command -v lsof >/dev/null 2>&1 || [ -x /usr/sbin/lsof ]; }
# kw <step> <exit> <repo> — one run of the script over the real-kill wrapper (tuning: T_* prefix assignments on the call); fresh mark/log/state each time.
# Sets KW_OUT and KW_RC.
kw() {
  local step="$1" ex="$2" repo="$3"
  rm -f "$WORK/state.json" "$WORK/log" "$WORK/kw.mark" "$WORK/kw.log"
  KW_OUT="$(KW_STEP="$step" KW_EXIT="$ex" KW_MARK="$WORK/kw.mark" KW_LOG="$WORK/kw.log" T_GIT="$WORK/git-killwrite" run_jac "$repo")"; KW_RC=$?
}
# kw_leaked — 0 when the wrapper really killed a step mid-write AND the kill left a tmp_pack (the precondition of every check below); else prints why not
kw_leaked() {
  grep -q '^killed ' "$WORK/kw.log" 2>/dev/null || { echo "the real write never reached 1MB while git ran: $(cat "$WORK/kw.log" 2>/dev/null)"; return 1; }
  grep -q 'after the kill: [1-9]' "$WORK/kw.log" || { echo "this git removed its own tmp_pack on SIGTERM — nothing to reclaim: $(cat "$WORK/kw.log")"; return 1; }
  return 0
}
if ! have_lsof; then
  skip "S32: no lsof on this host — the script cannot prove a temp file is unused, so it keeps it (S33 covers that); the real-kill reclaim checks did NOT run"
else
  # (a) a batch cut by the RUN DEADLINE while pack-objects writes (the reviewer's repro shape: it was exit 0 / deferred / streak 0 with +66% .git)
  KB="$WORK/kb"; mkbig "$KB" 5 12; LKB="$(loose_count "$KB")"; HKB="$(history "$KB")"
  T_DEADLINE=100 T_MIN_BATCH=1 T_GIT_TIMEOUT=300 T_BATCH=25 kw maintenance 124 "$KB"
  if ! why="$(kw_leaked)"; then skip "S32 (a) $why"; else
    { [ "$KW_RC" -eq 0 ] && [ "$(last_status)" = "deferred" ] && printf '%s' "$KW_OUT" | grep -q 'cut by the run deadline'; } \
      && ok "(a) batch killed mid-write by the run deadline → status deferred, exit 0 (the budget ended)" || bad "(a) deadline cut judged wrong (rc=$KW_RC status=$(last_status)): $KW_OUT"
    { [ "$(tmp_files "$KB")" = 0 ] && [ "$(garbage_of "$KB")" = 0 ]; } \
      && ok "(a) ...and the tmp_pack it left is GONE (0 temp files, count-objects garbage 0): the leak was reclaimed, not left for git's 2-week prune" \
      || bad "(a) leak left on disk: $(tmp_files "$KB") temp file(s), garbage=$(garbage_of "$KB")"
    printf '%s' "$KW_OUT" | grep -q 'left 1 temp file' && printf '%s' "$KW_OUT" | grep -q 'removed' && ok "(a) the log says what the step left and that it was removed" || bad "(a) no reclaim line in the log: $KW_OUT"
    [ "$(state_field "$KB" garbage_files)" = 0 ] && [ "$(state_field "$KB" garbage_kib)" = 0 ] && ok "(a) the state records the end garbage (0 files, 0KiB)" || bad "(a) state garbage_files=$(state_field "$KB" garbage_files) garbage_kib=$(state_field "$KB" garbage_kib)"
    { [ "$(loose_count "$KB")" = "$LKB" ] && [ "$(history "$KB")" = "$HKB" ] && git --git-dir="$KB/.git" fsck --strict >/dev/null 2>&1; } && ok "(a) nothing that is history was touched: loose objects unchanged, same commit+tree ids, fsck clean" || bad "(a) the repo changed or is damaged"
  fi
  # (b) the batch's OWN cap (rc 124, not the deadline): halved and retried — the leak must be gone BEFORE the retry and after the drain
  KB2="$WORK/kb2"; mkbig "$KB2" 5 12
  T_DEADLINE=780 T_GIT_TIMEOUT=100 T_BATCH=25 kw maintenance 124 "$KB2"
  if ! why="$(kw_leaked)"; then skip "S32 (b) $why"; else
    { [ "$KW_RC" -eq 0 ] && [ "$(last_status)" = "packed-loose" ] && [ "$(loose_count "$KB2")" = 0 ]; } \
      && ok "(b) batch killed mid-write at its OWN cap → halved, retried, drained (exit 0, packed-loose, no loose objects)" || bad "(b) drain after an own-cap kill wrong (rc=$KW_RC status=$(last_status) loose=$(loose_count "$KB2")): $KW_OUT"
    { [ "$(tmp_files "$KB2")" = 0 ] && [ "$(garbage_of "$KB2")" = 0 ]; } && ok "(b) no temp file and garbage 0 after the drain" || bad "(b) leak left: $(tmp_files "$KB2") temp file(s), garbage=$(garbage_of "$KB2")"
    rl="$(printf '%s' "$KW_OUT" | grep -n 'left 1 temp file' | head -n 1 | cut -d: -f1)"; rt="$(printf '%s' "$KW_OUT" | grep -n 'retrying with' | head -n 1 | cut -d: -f1)"
    { [ -n "$rl" ] && [ -n "$rt" ] && [ "$rl" -lt "$rt" ]; } && ok "(b) the reclaim is logged BEFORE the retry starts (a retry never runs on top of the killed step's leak)" || bad "(b) reclaim/retry order wrong (reclaim line $rl, retry line $rt): $KW_OUT"
    git --git-dir="$KB2/.git" fsck --strict >/dev/null 2>&1 && ok "(b) fsck clean" || bad "(b) fsck failed"
  fi
  # (c) a step that FAILED (pack-objects dying — out of space at the disk floor is the incident): the same leak, another exit code
  KB3="$WORK/kb3"; mkbig "$KB3" 5 12
  T_DEADLINE=780 T_GIT_TIMEOUT=300 T_BATCH=25 kw maintenance 1 "$KB3"
  if ! why="$(kw_leaked)"; then skip "S32 (c) $why"; else
    { [ "$KW_RC" -eq 1 ] && [ "$(last_status)" = "failed" ]; } && ok "(c) a batch that died mid-write (rc 1) → status failed, exit 1" || bad "(c) failed batch judged wrong (rc=$KW_RC status=$(last_status)): $KW_OUT"
    { [ "$(tmp_files "$KB3")" = 0 ] && [ "$(garbage_of "$KB3")" = 0 ]; } && ok "(c) its temp file is reclaimed too — the rule is 'a step that did not end 0', not 'a step that timed out'" || bad "(c) leak left: $(tmp_files "$KB3") temp file(s), garbage=$(garbage_of "$KB3")"
  fi
  # (d) tier 2: a consolidating gc cut by the run deadline — the reviewer had not reproduced a leak from a killed gc; on this git it does leak
  KG="$WORK/kg"; mkbigpacked "$KG"
  T_LIMIT=100000000 T_PACKS=1 T_MIN_GC=1 T_DEADLINE=300 T_GC_TIMEOUT=600 kw gc 124 "$KG"
  if ! why="$(kw_leaked)"; then skip "S32 (d) $why"; else
    { [ "$KW_RC" -eq 0 ] && [ "$(last_status)" = "deferred" ] && printf '%s' "$KW_OUT" | grep -q 'gc was cut by the run deadline'; } \
      && ok "(d) gc killed mid-write by the run deadline → deferred, exit 0" || bad "(d) deadline-cut gc judged wrong (rc=$KW_RC status=$(last_status)): $KW_OUT"
    { [ "$(tmp_files "$KG")" = 0 ] && [ "$(garbage_of "$KG")" = 0 ]; } && ok "(d) the killed gc's tmp_pack is reclaimed (a killed gc DOES leak on this git — the 'a killed gc keeps no work' comment was only half true)" || bad "(d) gc leak left: $(tmp_files "$KG") temp file(s), garbage=$(garbage_of "$KG")"
    git --git-dir="$KG/.git" fsck --strict >/dev/null 2>&1 && ok "(d) fsck clean" || bad "(d) fsck failed"
  fi
  # (e) tier 2 at gc's OWN cap: timeout (BAD) — and still no leak
  KG2="$WORK/kg2"; mkbigpacked "$KG2"
  T_LIMIT=100000000 T_PACKS=1 T_MIN_GC=1 T_DEADLINE=780 T_GC_TIMEOUT=100 kw gc 124 "$KG2"
  if ! why="$(kw_leaked)"; then skip "S32 (e) $why"; else
    { [ "$KW_RC" -eq 1 ] && [ "$(last_status)" = "timeout" ]; } && ok "(e) gc killed at its OWN cap → status timeout, exit 1" || bad "(e) own-cap gc judged wrong (rc=$KW_RC status=$(last_status)): $KW_OUT"
    { [ "$(tmp_files "$KG2")" = 0 ] && [ "$(garbage_of "$KG2")" = 0 ]; } && ok "(e) its temp file is reclaimed" || bad "(e) gc leak left: $(tmp_files "$KG2") temp file(s), garbage=$(garbage_of "$KG2")"
  fi
fi

echo ""
echo "=== S33: only what THIS step left, only what nobody has open — and a leak that stays is BAD, not green ==="
# A stand-in for the step (git-leak) drops a temp file of a chosen size and exits like a cut step; lsof is stubbed to say what it can and cannot tell. What the
# script may delete is the narrowest thing that is provably not history and provably not in use: a tmp_* file that APPEARED during a step that did not end 0,
# with lsof printing nothing at all. Every other answer keeps the file, and the run then ends with more garbage than it started with: BAD.
cat > "$WORK/git-leak" <<'EOF'
#!/bin/bash
# git-leak: the first `maintenance run` leaves $LK_KIB KiB in objects/pack/tmp_pack_LEAK<pid> and exits $LK_EXIT (default 124: cut). LK_AFTER=1 runs the real
# step first and leaves the file behind AFTER it (a step that "succeeded" and still left a temp file). LK_CHMOD=1 makes objects/pack unreadable afterwards.
# LK_GROW_OLD=1 leaves no new file: it appends $LK_KIB KiB to the EXISTING tmp_pack_OLD (a live writer of somebody else's, growing while the step runs).
# LK_RODIR=1 makes objects/pack read-only afterwards (listable, but a file in it cannot be removed).
gd=""; for a in "$@"; do case "$a" in --git-dir=*) gd="${a#--git-dir=}" ;; esac; done
case " $* " in *" maintenance run "*)
  if [ ! -e "${LK_MARK:?}" ]; then
    : > "$LK_MARK"
    if [ -n "${LK_GROW_OLD:-}" ]; then
      chmod 644 "$gd/objects/pack/tmp_pack_OLD"; head -c $(( ${LK_KIB:-64} * 1024 )) /dev/urandom >> "$gd/objects/pack/tmp_pack_OLD"; chmod 444 "$gd/objects/pack/tmp_pack_OLD"
      exit "${LK_EXIT:-124}"
    fi
    rc=0; [ -n "${LK_AFTER:-}" ] && { git "$@"; rc=$?; }
    head -c $(( ${LK_KIB:-64} * 1024 )) /dev/urandom > "$gd/objects/pack/tmp_pack_LEAK$$"; chmod 444 "$gd/objects/pack/tmp_pack_LEAK$$"
    [ -n "${LK_CHMOD:-}" ] && chmod 000 "$gd/objects/pack"
    [ -n "${LK_RODIR:-}" ] && chmod 555 "$gd/objects/pack"
    [ -n "${LK_AFTER:-}" ] && exit "$rc"
    exit "${LK_EXIT:-124}"
  fi ;;
esac
exec git "$@"
EOF
chmod +x "$WORK/git-leak"
# lsof stubs. Real lsof exits 1 both when nothing is open and when only SOME of the named files are, so the script must read the OUTPUT, not the status.
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 1\n' "$WORK/lsof-calls" > "$WORK/lsof-none"                                                   # nothing open: no output, exit 1
printf '#!/bin/bash\necho "$*" >> "%s"\nfor last; do :; done\nprintf "p4242\\nf9\\nn%%s\\n" "$last"\nexit 0\n' "$WORK/lsof-calls" > "$WORK/lsof-open"   # every file open by pid 4242
printf '#!/bin/bash\necho "$*" >> "%s"\necho "lsof: WARNING: could not read the process table"\nexit 1\n' "$WORK/lsof-calls" > "$WORK/lsof-msg"             # a message is not an answer
printf '#!/bin/bash\necho "$*" >> "%s"\nn="$(wc -l < "%s" | tr -d " ")"\n[ "$n" -le 1 ] && { for last; do :; done; printf "p4242\\nf9\\nn%%s\\n" "$last"; exit 0; }\nexit 1\n' "$WORK/lsof-calls" "$WORK/lsof-calls" > "$WORK/lsof-flaky"   # open on the first look, gone on the second
printf '#!/bin/bash\necho "$*" >> "%s"\nprintf "p4242\\nf9\\n"\nexit 0\n' "$WORK/lsof-calls" > "$WORK/lsof-frame"                                                # field lines with no n-line: not a hit, not a clean "none"
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' "$WORK/lsof-calls" > "$WORK/lsof-zero"                                                                                   # exit 0 and nothing printed: lsof never does that
chmod +x "$WORK/lsof-none" "$WORK/lsof-open" "$WORK/lsof-msg" "$WORK/lsof-flaky" "$WORK/lsof-frame" "$WORK/lsof-zero"
# lk <lsof-stub> — a fresh 60-loose-object repo in $LK, one run over git-leak with that lsof; sets LK_OUT / LK_RC
lk() {
  local stub="$1"
  LK="$WORK/lk$((++LKN))"; mkrepo "$LK" 20
  rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark" "$WORK/lsof-calls" "$WORK/gc-calls"
  LK_OUT="$(LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$stub" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 run_jac "$LK")"; LK_RC=$?
}
LKN=0
# (a) nothing open, and an OLDER temp file that this step did not leave: the new one goes, the old one stays (it is not this step's to remove) and is not growth
LKA="$WORK/lka"; mkrepo "$LKA" 20; head -c 32768 /dev/urandom > "$LKA/.git/objects/pack/tmp_pack_OLD"; chmod 444 "$LKA/.git/objects/pack/tmp_pack_OLD"
rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark" "$WORK/lsof-calls"
LK_OUT="$(LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-none" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 run_jac "$LKA")"; LK_RC=$?
[ "$(ls "$LKA"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok "(a) nothing open: the temp file this step left is removed" || bad "(a) the step's own temp file is still there: $(ls "$LKA"/.git/objects/pack | tr '\n' ' ')"
[ -e "$LKA/.git/objects/pack/tmp_pack_OLD" ] && ok "(a) an OLDER temp file (present before the step) is left alone — it is not this step's to remove" || bad "(a) a temp file that predates the step was deleted"
{ [ "$LK_RC" -eq 0 ] && [ "$(last_status)" = "packed-loose" ]; } && ok "(a) exit 0, packed-loose: garbage did not grow (1 file before, 1 after), so it is not BAD" || bad "(a) judged wrong (rc=$LK_RC status=$(last_status)): $LK_OUT"
printf '%s' "$LK_OUT" | grep -q 'garbage=1f/0MiB->1f/0MiB' && ok "(a) the status line carries garbage before->after (1 file, 0MiB -> 1 file, 0MiB)" || bad "(a) no garbage=… in the status line: $LK_OUT"
[ "$(state_field "$LKA" garbage_files)" = 1 ] && ok "(a) state: garbage_files 1" || bad "(a) state garbage_files=$(state_field "$LKA" garbage_files)"
# (a2) a leak of ZERO bytes (a tmp_pack killed before it wrote anything) that is kept still counts: garbage is judged by FILES
LK="$WORK/lk$((++LKN))"; mkrepo "$LK" 20; rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark" "$WORK/lsof-calls"
LK_OUT="$(LK_KIB=0 LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-open" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 run_jac "$LK")"; LK_RC=$?
{ [ "$LK_RC" -eq 1 ] && [ "$(state_field "$LK" garbage_files)" = 1 ] && [ "$(state_field "$LK" garbage_kib)" = 0 ]; } \
  && ok "(a2) a kept 0KiB leak: garbage_kib 0 but garbage_files 1 → the run is BAD (exit 1): the count, not the size, is what says a step leaked" || bad "(a2) a kept zero-size leak judged wrong (rc=$LK_RC files=$(state_field "$LK" garbage_files) kib=$(state_field "$LK" garbage_kib)): $LK_OUT"
# (a3) the opposite: a garbage file that was ALREADY there and merely grows during the step is somebody else's live writer — no new file, not this run's leak, not BAD
LKG="$WORK/lkg"; mkrepo "$LKG" 20; head -c 32768 /dev/urandom > "$LKG/.git/objects/pack/tmp_pack_OLD"; chmod 444 "$LKG/.git/objects/pack/tmp_pack_OLD"
rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark" "$WORK/lsof-calls"
LK_OUT="$(LK_GROW_OLD=1 LK_KIB=256 LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-open" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 run_jac "$LKG")"; LK_RC=$?
{ [ "$LK_RC" -eq 0 ] && [ -e "$LKG/.git/objects/pack/tmp_pack_OLD" ] && [ "$(state_field "$LKG" garbage_files)" = 1 ] && [ "$(state_field "$LKG" garbage_kib)" -ge 256 ]; } \
  && ok "(a3) an OLD garbage file that grew from 32KiB to $(state_field "$LKG" garbage_kib)KiB during the step: no new file → not this run's leak → exit 0, and it was not touched" || bad "(a3) a growing pre-existing garbage file judged wrong (rc=$LK_RC files=$(state_field "$LKG" garbage_files) kib=$(state_field "$LKG" garbage_kib)): $LK_OUT"
# (b) lsof says the file is OPEN: kept (not ours to remove), and the run is BAD — it ends with more garbage than it started with
lk "$WORK/lsof-open"
{ [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 1 ]; } && ok "(b) lsof says it is open → the file is kept" || bad "(b) an OPEN temp file was removed"
{ [ "$LK_RC" -eq 1 ] && [ "$(state_field "$LK" bad_streak)" = 1 ]; } && ok "(b) the run is BAD (exit 1, bad_streak 1): garbage grew and nothing reclaimed it" || bad "(b) leaked-and-kept run judged wrong (rc=$LK_RC streak=$(state_field "$LK" bad_streak)): $LK_OUT"
printf '%s' "$LK_OUT" | grep -q 'open by a process' && printf '%s' "$LK_OUT" | grep -q 'garbage grew' && ok "(b) the log names both: 'open by a process' and 'garbage grew'" || bad "(b) log does not explain the kept file / the growth: $LK_OUT"
[ "$(wc -l < "$WORK/lsof-calls" | tr -d ' ')" = 2 ] && ok "(b) it looked twice (a dying writer needs a moment) and then gave up — bounded, not a wait loop" || bad "(b) lsof was called $(wc -l < "$WORK/lsof-calls" | tr -d ' ') times, want 2"
# (c) lsof answers with a MESSAGE: that is not 'none open'
lk "$WORK/lsof-msg"
{ [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ "$LK_RC" -eq 1 ]; } && printf '%s' "$LK_OUT" | grep -q 'cannot tell whether' \
  && ok "(c) lsof printed a message, not an answer → kept, BAD, and the log says 'cannot tell whether'" || bad "(c) an lsof message was read as 'nothing open' (rc=$LK_RC): $LK_OUT"
for odd in frame zero; do
  lk "$WORK/lsof-$odd"
  { [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ "$LK_RC" -eq 1 ]; } && printf '%s' "$LK_OUT" | grep -q 'cannot tell whether' \
    && ok "(c) lsof-$odd ($([ "$odd" = frame ] && echo 'field lines but no file name' || echo 'exit 0 and no output')) is not a clean 'none open' → kept, BAD, 'cannot tell whether' (a clean none is exactly: exit 1 and NO output)" \
    || bad "(c) lsof-$odd was read as 'nothing open' (rc=$LK_RC): $LK_OUT"
done
# (d) no lsof at all
lk "$WORK/no-such-lsof"
{ [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ "$LK_RC" -eq 1 ]; } && printf '%s' "$LK_OUT" | grep -q 'cannot tell whether' \
  && ok "(d) no lsof to ask → kept, BAD, 'cannot tell whether' (under doubt the inert state is: do not delete)" || bad "(d) a missing lsof was read as 'nothing open' (rc=$LK_RC): $LK_OUT"
# (e) open on the first look, gone on the second (a dying writer): reclaimed after ONE more look
lk "$WORK/lsof-flaky"
{ [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && [ "$LK_RC" -eq 0 ] && [ "$(wc -l < "$WORK/lsof-calls" | tr -d ' ')" = 2 ]; } \
  && ok "(e) open at the first look, gone at the second → removed (2 lsof calls), exit 0" || bad "(e) dying-writer case wrong (rc=$LK_RC lsof calls=$(wc -l < "$WORK/lsof-calls" | tr -d ' ')): $LK_OUT"
# (f) the step "SUCCEEDED" (rc 0) and still left a temp file: nothing reclaims it (only a step that did not end 0 is suspected), but it is MEASURED, so it is BAD
LK="$WORK/lk$((++LKN))"; mkrepo "$LK" 20; rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark"
LK_OUT="$(LK_AFTER=1 LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-none" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 run_jac "$LK")"; LK_RC=$?
{ [ "$(last_status)" = "packed-loose" ] && [ "$LK_RC" -eq 1 ] && [ "$(state_field "$LK" bad_streak)" = 1 ]; } \
  && ok "(f) a step that ended 0 but left a temp file: status packed-loose yet the RUN is BAD (exit 1) — garbage is judged on the measured end state, not on the step's exit code" \
  || bad "(f) success-with-leak judged wrong (status=$(last_status) rc=$LK_RC streak=$(state_field "$LK" bad_streak)): $LK_OUT"
# (g) the list of temp files cannot be read AFTER the step: the leak is UNKNOWN — said out loud, nothing deleted, lsof never asked, and the run is BAD (not knowing is not "nothing
# left"). A deadline cut ends the run after this one step, so no retry step (whose own BEFORE-list would fail the same way) can stand in for the check.
if [ "$(id -u)" -eq 0 ]; then skip "(g) running as root: chmod 000 does not make a directory unreadable for root, so the unreadable-object-store fixture did NOT run"
else
  LK="$WORK/lk$((++LKN))"; mkrepo "$LK" 20; rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark" "$WORK/lsof-calls"
  LK_OUT="$(LK_CHMOD=1 LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-none" T_RECLAIM_WAIT=0 T_DEADLINE=100 T_MIN_BATCH=1 T_GIT_TIMEOUT=300 T_BATCH=25 run_jac "$LK")"; LK_RC=$?
  chmod 755 "$LK/.git/objects/pack" 2>/dev/null
  { printf '%s' "$LK_OUT" | grep -q 'could not be listed' && [ ! -s "$WORK/lsof-calls" ] && [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 1 ]; } \
    && ok "(g) the temp-file list could not be read after the step → 'could not be listed' in the log, lsof never asked, nothing deleted" || bad "(g) an unreadable object store was handled wrong (rc=$LK_RC): $LK_OUT"
  { [ "$LK_RC" -eq 1 ] && [ "$(state_field "$LK" bad_streak)" = 1 ] && [ "$(last_status)" = "deferred" ]; } && ok "(g) ...and the run is BAD (exit 1, bad_streak 1) although its status is only 'deferred' (a deadline cut, and the store still measurable): an unknown leak is not a clean cut" || bad "(g) an unknown leak ended exit $LK_RC, status=$(last_status), bad_streak=$(state_field "$LK" bad_streak): $LK_OUT"
fi
# (g2) the removal itself FAILS (the pack directory is not writable): the reason is logged, the file stays, "removed" is never said for a file that is still there, and the run is BAD
if [ "$(id -u)" -eq 0 ]; then skip "(g2) running as root: a read-only directory does not stop root from removing a file, so the failing-removal fixture did NOT run"
else
  LK="$WORK/lk$((++LKN))"; mkrepo "$LK" 20; rm -f "$WORK/state.json" "$WORK/log" "$WORK/lk.mark" "$WORK/lsof-calls"
  LK_OUT="$(LK_RODIR=1 LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-none" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 run_jac "$LK")"; LK_RC=$?
  chmod 755 "$LK/.git/objects/pack" 2>/dev/null
  { printf '%s' "$LK_OUT" | grep -q 'could not remove' && printf '%s' "$LK_OUT" | grep -q 'removed 0 of 1' && [ "$(ls "$LK"/.git/objects/pack/tmp_pack_LEAK* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ "$LK_RC" -eq 1 ]; } \
    && ok "(g2) rm failed → 'could not remove <file>: <reason>' and 'removed 0 of 1' in the log, the file is still there, exit 1 (never 'removed' for a file that is not gone)" || bad "(g2) a failed removal was handled wrong (rc=$LK_RC): $LK_OUT"
fi
# (h) three BAD runs page the mayor, and the mail says why: the garbage
LK="$WORK/lk$((++LKN))"; mkrepo "$LK" 20; rm -f "$WORK/state.json" "$WORK/log" "$WORK/gc-calls"
addmore() { local d="$1" n="$2" base="$3" i; for i in $(seq $((base + 1)) $((base + n))); do awk -v k="$i" '{ if (NR % 997 == k % 997) print "changed line " k; else print }' "$d/hq.jsonl" > "$d/hq.jsonl.new" && mv "$d/hq.jsonl.new" "$d/hq.jsonl"; git -C "$d" add hq.jsonl && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "more $i"; done; }
for n in 1 2 3; do
  rm -f "$WORK/lk.mark"; addmore "$LK" 4 $((n * 100))
  LK_MARK="$WORK/lk.mark" T_GIT="$WORK/git-leak" T_LSOF="$WORK/lsof-open" T_RECLAIM_WAIT=0 T_GIT_TIMEOUT=100 T_BATCH=25 T_LIMIT=64 run_jac "$LK" >/dev/null
done
{ [ "$(mail_calls)" = 1 ] && grep -q 'garbage' "$WORK/gc-calls"; } && ok "(h) 3 runs that each leaked a kept temp file → ONE mail to the mayor, and it names the garbage" || bad "(h) alarm wrong (mails=$(mail_calls)): $(cat "$WORK/gc-calls" 2>/dev/null | cut -c1-300)"
# (i) --check: the garbage is printed (files and size) — read-only, as ever
out="$(run_jac "$LK" --check)"; printf '%s' "$out" | grep -q 'garbage=3f/' && ok "(i) --check prints the garbage (files/size) it sees" || bad "(i) --check does not print garbage=…: $out"

echo ""
echo "=== S34: STRUCTURE — a git step only runs through run_step, so no step can skip the leak accounting ==="
# S30 pins the places that DISCARD a failure; this pins the places that RUN a git step. The gate reported the leak for the batch, and on this host's git the gc
# leaks the same way: three call sites, one rule, and nothing stopped a fourth from being added without it. The rule lives in ONE function (run_step: snapshot the temp
# files, run the step, and after a step that did not end 0 reclaim what it left). git_arch may be called from there and nowhere else; the git seam ($GITBIN) may be used
# nowhere but in git_arch (a step could otherwise bypass both); the only git run BARE on the repo is the read-only `count-objects`; and the set of steps that go through
# run_step is PINNED below.
lint_steps() {  # lint_steps <file> — "OUTSIDE|<line>|<code>": a git_arch call outside run_step, or $GITBIN used outside git_arch; "BARE|<sub>": a git run bare on the repo; "STEP|<what>": a run_step call site
  awk '
    /^run_step\(\) *\{/ { in_rs = 1; next }
    in_rs && /^\}/ { in_rs = 0; next }
    /^git_arch\(\) *\{/ { in_ga = 1; next }
    in_ga && /^\}/ { in_ga = 0; next }
    /^[ \t]*#/ { next }
    /^GITBIN=/ { next }
    (!in_rs && !in_ga) && (/(^|[^a-z_])git_arch / || /\$\{?GITBIN/) { printf "OUTSIDE|%d|%s\n", NR, $0 }
    !in_ga && match($0, /git --git-dir="\$R_GITDIR" [a-z-]+/) { b = substr($0, RSTART, RLENGTH); sub(/.* /, "", b); printf "BARE|%s\n", b }
    /(^|[ \t;])run_step "\$[a-z_]+" / { st = $0; sub(/.*run_step "\$[a-z_]+" /, "", st); sub(/;.*$/, "", st); printf "STEP|%s\n", st }
  ' "$1"
}
LS="$(lint_steps "$SCRIPT")"
[ -n "$(printf '%s\n' "$LS" | grep '^STEP|')" ] && ok "the lint sees the run_step call sites ($(printf '%s\n' "$LS" | grep -c '^STEP|') of them)" || bad "the lint found no run_step call sites — it is not looking"
[ -z "$(printf '%s\n' "$LS" | grep '^OUTSIDE|')" ] && ok "git_arch is called from run_step only, and the \$GITBIN seam is used in git_arch only" || bad "a git step outside run_step/git_arch (it would skip the leak accounting): $(printf '%s\n' "$LS" | grep '^OUTSIDE|' | cut -c1-120 | tr '\n' ';')"
got_bare="$(printf '%s\n' "$LS" | grep '^BARE|' | cut -d'|' -f2 | sort -u | tr '\n' ',')"
[ "$got_bare" = "count-objects," ] && ok "the only git run bare on the repo is the read-only count-objects (measure)" || bad "bare git subcommand(s) [$got_bare] — want only count-objects: a git that WRITES must go through run_step"
got_steps="$(printf '%s\n' "$LS" | grep '^STEP|' | cut -d'|' -f2 | sed 's/ *--quiet.*$//' | tr '\n' ',')"
want_steps="maintenance run --task=loose-objects,prune-packed,-c gc.autoDetach=false gc,"
[ "$got_steps" = "$want_steps" ] && ok "the steps that go through run_step are exactly the pinned three (batch, prune-packed, gc)" || bad "steps differ from the pin — got [$got_steps] want [$want_steps]: read the new/removed step (does it write objects? then it can leak), then update the pin"
cp "$SCRIPT" "$WORK/steps-mutant.sh"
printf '%s\n' 'x="$(git_arch 5 repack 2>&1)"' 'run_step "$t_left" repack --quiet' 'y="$("$GITBIN" gc)"' 'git --git-dir="$R_GITDIR" repack -d' >> "$WORK/steps-mutant.sh"
MS="$(lint_steps "$WORK/steps-mutant.sh")"
mo="$(printf '%s\n' "$MS" | grep -c '^OUTSIDE|')"; ms="$(printf '%s\n' "$MS" | grep -c '^STEP|')"; bs="$(printf '%s\n' "$LS" | grep -c '^STEP|')"; mb="$(printf '%s\n' "$MS" | grep '^BARE|' | cut -d'|' -f2 | sort -u | tr '\n' ',')"
{ [ "$mo" -eq 2 ] && [ "$ms" -eq $((bs + 1)) ] && [ "$mb" = "count-objects,repack," ]; } \
  && ok "the lint bites: an appended direct git_arch call and a direct \$GITBIN call are reported as OUTSIDE, an appended 4th run_step shows up as a new step, an appended bare repack shows up as a new bare subcommand (each breaks a pin)" \
  || bad "lint did not catch the mutant (outside=$mo want 2; steps=$ms want $((bs + 1)); bare=[$mb] want [count-objects,repack,])"

echo ""
echo "=== S35: ONE REPACKER AT A TIME — the consolidating gc is not started while another git process is repacking the repo (ga-8z0hy7) ==="
# The incident: two gc runs (08/10 13:32Z, 09/10 22:11Z) died with "fatal: could not find pack 'loose-<sha>.pack'" / "failed to run repack", rc=128. Reproduced on a scratch
# repo: a gc names the packs it will consume, spends minutes on the main pack, and its cruft pass then asks for them by name — while the background repack that every `git commit`
# spawns (`git maintenance run --auto --detach` -> `repack -d -l --geometric=2 --write-midx`, 19+ minutes on this host, with no lock file) has merged and deleted the loose-*.pack
# batch packs. So before the gc, other_repacker looks for such a process: ps for git processes of a repacking kind, then lsof for the working directory of each.
# The stand-in below is a script NAMED `git` whose command line reads `.../git repack ...` and whose working directory is the repo — real ps and real lsof see a real process, no fake
# listing. Its sleeping child is stopped with it.
FGBIN="$WORK/fg-bin"; mkdir -p "$FGBIN"
printf '#!/bin/bash\nsleep 120\n' > "$FGBIN/git"; chmod +x "$FGBIN/git"
FG_PIDS=""; FG_PID=""
fg_start() {  # fg_start <cwd> <git args...> — sets FG_PID once ps shows the stand-in under its final command line
  local d="$1" i; shift
  ( cd "$d" && exec "$FGBIN/git" "$@" ) >/dev/null 2>&1 &
  FG_PID=$!; FG_PIDS="$FG_PIDS $FG_PID"
  for i in $(seq 1 50); do ps -p "$FG_PID" -o command= 2>/dev/null | grep -q 'fg-bin/git' && return 0; sleep 0.1; done
  return 1
}
fg_stop_all() { local p; for p in $FG_PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; FG_PIDS=""; FG_PID=""; return 0; }
mkpacks() { mkrepo "$1" 1; local i; for i in 2 3 4 5 6; do addpack "$1" "$i"; done; }

# A. another repacker whose working directory is this repo → the gc is not started: busy, nothing consolidated, nothing touched, the log names the process
A="$WORK/fg-a"; mkpacks "$A"; PCA="$(pack_count "$A")"; HA="$(history "$A")"; rm -f "$WORK/state.json"
fg_start "$A" repack -d -l --geometric=2 --quiet --write-midx || bad "test setup: the stand-in repacker did not show up in ps"
out="$(T_PACKS=4 run_jac "$A")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "busy" ] && [ "$(pack_count "$A")" = "$PCA" ]; } \
  && ok "a repacker with its cwd in the repo → gc NOT started: status busy, exit 0, packs unchanged ($PCA)" \
  || bad "foreign repacker in the repo: rc=$rc status=$(last_status) packs $PCA -> $(pack_count "$A"): $out"
printf '%s' "$out" | grep -q "gc not started: pid $FG_PID: .*git repack" && printf '%s' "$out" | grep -q 'ga-8z0hy7' \
  && ok "the log names the process (pid, command line) and the bead" || bad "log does not name the foreign repacker (pid $FG_PID): $out"
{ [ "$(history "$A")" = "$HA" ] && git --git-dir="$A/.git" fsck --strict >/dev/null 2>&1; } && ok "history identical and fsck clean — nothing was written" || bad "the repo changed although the gc was not started"
fg_stop_all
out="$(T_PACKS=4 run_jac "$A")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "consolidated" ] && [ "$(pack_count "$A")" -le 2 ]; } \
  && ok "the next run, with that process gone, consolidates (deferred is retried, never abandoned): packs $PCA -> $(pack_count "$A")" \
  || bad "after the repacker ended the gc did not run: rc=$rc status=$(last_status) packs=$(pack_count "$A"): $out"

# B. the same repack in ANOTHER repo (its cwd is not this one) → no reason to wait
B="$WORK/fg-b"; mkpacks "$B"; rm -f "$WORK/state.json"
fg_start "$WORK" repack -d -l --geometric=2 || bad "test setup: the stand-in did not show up in ps"
out="$(T_PACKS=4 run_jac "$B")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "consolidated" ]; } \
  && ok "a repacker working in another directory does not hold this repo's gc back" || bad "a repacker elsewhere blocked the gc: rc=$rc status=$(last_status): $out"
fg_stop_all

# C. a git process in the repo that does not repack (an exporter's own commit) is not a reason to wait either
C="$WORK/fg-c"; mkpacks "$C"; rm -f "$WORK/state.json"
fg_start "$C" commit -q -m exporter || bad "test setup: the stand-in did not show up in ps"
out="$(T_PACKS=4 run_jac "$C")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "consolidated" ]; } \
  && ok "a git commit in the repo is not a repacker: the gc runs" || bad "a git commit in the repo blocked the gc: rc=$rc status=$(last_status): $out"
fg_stop_all

# D. a failed tier 1 stays failed: a gc that was not started did NOTHING, so it cannot turn it into a green busy
D="$WORK/fg-d"; mkfailrepo "$D"; rm -f "$WORK/state.json"
fg_start "$D" maintenance run --auto --quiet --detach || bad "test setup: the stand-in did not show up in ps"
out="$(FM_RC=1 T_GIT="$WORK/git-failmaint" T_PACKS=3 run_jac "$D")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(last_status)" = "failed" ] && printf '%s' "$out" | grep -q 'gc not started'; } \
  && ok "batches failed + a foreign repacker (gc not started) → status stays failed, exit 1 (it does not launder a failure)" \
  || bad "failed tier 1 + foreign repacker judged wrong: rc=$rc status=$(last_status): $out"
fg_stop_all

# E. the repo reached through a symlink: lsof prints the resolved directory, the comparison uses the repo's physical path
E="$WORK/fg-e"; mkpacks "$E"; ln -s "$E" "$WORK/fg-e-link"; rm -f "$WORK/state.json"
fg_start "$E" gc --auto || bad "test setup: the stand-in did not show up in ps"
out="$(T_PACKS=4 run_jac "$WORK/fg-e-link")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "busy" ] && printf '%s' "$out" | grep -q "gc not started: pid $FG_PID"; } \
  && ok "repo given as a symlink path: the process is still found (physical path compared)" || bad "symlinked repo path missed the foreign repacker: rc=$rc status=$(last_status): $out"
fg_stop_all

# F. CANNOT TELL is not "none": every way the look can fail leaves the gc unstarted, says so, and is never green over a failed tier 1
printf '#!/bin/bash\nexit 1\n' > "$WORK/ps-fail"; printf '#!/bin/bash\nexit 0\n' > "$WORK/ps-empty"; chmod +x "$WORK/ps-fail" "$WORK/ps-empty"
cantell() {  # cantell <label> <repo> <env assignments...> — run with an unanswerable look; busy + "cannot tell" + packs untouched
  local label="$1" repo="$2" pc o r; shift 2
  pc="$(pack_count "$repo")"; rm -f "$WORK/state.json"
  o="$( export "$@"; T_PACKS=4 run_jac "$repo" )"; r=$?      # a subshell with the look's faults exported (run_jac is a function: env cannot run it)
  { [ "$r" -eq 0 ] && [ "$(last_status)" = "busy" ] && [ "$(pack_count "$repo")" = "$pc" ] && printf '%s' "$o" | grep -q 'cannot tell whether another git process is repacking'; } \
    && ok "$label → gc not started, status busy, log says it cannot tell" || bad "$label: rc=$r status=$(last_status) packs $pc -> $(pack_count "$repo"): $o"
}
F1="$WORK/fg-f1"; mkpacks "$F1"; cantell "ps fails" "$F1" T_PS="$WORK/ps-fail"
F2="$WORK/fg-f2"; mkpacks "$F2"; cantell "ps prints nothing (it always lists itself — an empty list is a ps that did not work)" "$F2" T_PS="$WORK/ps-empty"
F3="$WORK/fg-f3"; mkpacks "$F3"; fg_start "$F3" repack -d || bad "test setup: the stand-in did not show up in ps"
cantell "lsof is missing while a candidate repacker is alive" "$F3" T_LSOF="$WORK/no-such-lsof"
F4="$WORK/fg-f4"; mkpacks "$F4"
cantell "lsof answers nothing for a candidate that is alive (not readable)" "$F4" T_LSOF="$WORK/lsof-none"
fg_stop_all
printf '#!/bin/bash\nsleep 30\n' > "$WORK/lsof-slow"; chmod +x "$WORK/lsof-slow"
F5="$WORK/fg-f5"; mkpacks "$F5"; fg_start "$F5" repack -d || bad "test setup: the stand-in did not show up in ps"
cantell "lsof cut at its cap (2s) while a candidate is alive" "$F5" T_LSOF="$WORK/lsof-slow" JAC_LSOF_TIMEOUT_S=2
fg_stop_all
# an lsof answer that is not a directory: its own words for one it could not read are not "somewhere else", and a pid line with no directory line under it answers nothing.
# Each stub answers EVERY pid it is asked about, in the same unusable way — so no candidate is left unanswered for another reason, and only the handling of that answer decides.
cat > "$WORK/lsof-notpath" <<'EOF'
#!/bin/bash
for last; do :; done
for p in $(printf '%s' "$last" | tr ',' ' '); do printf 'p%s\nfcwd\nn(cannot read: permission denied)\n' "$p"; done
EOF
cat > "$WORK/lsof-nodir" <<'EOF'
#!/bin/bash
for last; do :; done
for p in $(printf '%s' "$last" | tr ',' ' '); do printf 'p%s\nfcwd\n' "$p"; done
EOF
chmod +x "$WORK/lsof-notpath" "$WORK/lsof-nodir"
F7="$WORK/fg-f7"; mkpacks "$F7"; fg_start "$F7" repack -d || bad "test setup: the stand-in did not show up in ps"
cantell "lsof's directory line is not a path (a directory it could not read)" "$F7" T_LSOF="$WORK/lsof-notpath"
F8="$WORK/fg-f8"; mkpacks "$F8"
cantell "lsof prints a pid line with no directory line under it" "$F8" T_LSOF="$WORK/lsof-nodir"
fg_stop_all
F6="$WORK/fg-f6"; mkfailrepo "$F6"; rm -f "$WORK/state.json"
out="$(FM_RC=1 T_GIT="$WORK/git-failmaint" T_PS="$WORK/ps-fail" T_PACKS=3 run_jac "$F6")"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(last_status)" = "failed" ]; } \
  && ok "batches failed + a look that cannot tell → status stays failed, exit 1" || bad "failed tier 1 + unanswerable look judged wrong: rc=$rc status=$(last_status): $out"

# G. a candidate that is already gone by the time lsof looks (it exited since ps) is not a repacker and is not "cannot tell"
G="$WORK/fg-g"; mkpacks "$G"; rm -f "$WORK/state.json"
DEADG="$(sh -c 'echo $$')"; kill -0 "$DEADG" 2>/dev/null && DEADG=999999
printf '#!/bin/bash\necho "  1 /sbin/launchd"\necho "%s /usr/bin/git repack -d -l --geometric=2"\n' "$DEADG" > "$WORK/ps-dead"; chmod +x "$WORK/ps-dead"
out="$(T_PS="$WORK/ps-dead" T_PACKS=4 run_jac "$G")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(last_status)" = "consolidated" ]; } \
  && ok "a listed repacker that has exited since ps ran is neither found nor 'cannot tell': the gc runs" || bad "a vanished candidate blocked the gc: rc=$rc status=$(last_status): $out"

echo ""

echo "=== S11: what actually runs in production ==="
cfg="$("$SCRIPT" --print-config)"
printf '%s' "$cfg" | grep -q 'packs/maintenance/jsonl-archive' && printf '%s' "$cfg" | grep -q 'packs/town-deltas/jsonl-archive' \
  && ok "default repos: BOTH archives (maintenance + town-deltas)" || bad "default repos wrong: $cfg"
S3SCRIPT="$CITY_ROOT/scripts/dolt-s3-backup.sh"
if [ -f "$S3SCRIPT" ]; then
  grep -q '^JSONL_ARCHIVE_DIR=.*packs/maintenance/jsonl-archive' "$S3SCRIPT" && ok "the archive dolt-s3-backup.sh mirrors is one of the compacted repos" || bad "dolt-s3-backup.sh mirrors a different archive path"
  grep -A2 -- 's3 sync "\$JSONL_ARCHIVE_DIR/"' "$S3SCRIPT" | grep -q -- '--exclude ".git/\*"' && ok "S3 sync excludes .git — history has no offsite copy, so compaction must never shorten it" || bad "S3 sync no longer excludes .git — re-read the header of jsonl-archive-compact.sh"
else
  skip "dolt-s3-backup.sh not in this tree — the two S3-sync cross-checks did NOT run (they are not counted as passes)"
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
echo "=== RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
[ "$SKIP" -eq 0 ] || echo "    ($SKIP check(s) did not run — see the SKIP lines above; FAIL=0 does not cover them)"
[ "$FAIL" -eq 0 ]
