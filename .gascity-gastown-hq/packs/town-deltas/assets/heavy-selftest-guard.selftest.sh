#!/usr/bin/env bash
# heavy-selftest-guard.selftest.sh — ga-rj7b1a: prove the guard that keeps a HEAVY selftest from tipping
# the box over (heavy-selftest-guard.sh) really does — and that it is wired into the suites it exists for.
#
# Every case runs the helper in a FRESH bash process (env -i): heavy_selftest_lowprio renices the process
# it runs in, and the lock is keyed on that process's pid, so a subshell of this test would corrupt both.
# The lock root is a throwaway dir, so nothing here can touch — or wait on — a real machine-wide lock.
#
#   L1  low priority: absolute, inherited, never lowers, never stacks, kill switches, fail-open, set -e safe
#   L2  single-flight lock: mutual exclusion (a real 6-way race), wait-then-acquire, bounded wait -> rc 75
#       "NOT RUN", stale / recycled-pid owners reclaimed, live owners never stolen from, unknown != dead,
#       fail-open when the lock cannot be created, re-entrancy, release only your own lock, SIGTERM release
#   L2b gate callers (reviewers) never queue for the lock — they run the suite twice per review inside a
#       verdict timeout already sized for it — but take it when free, so builders yield to the gate
#   L3  wiring: pilot-dispatcher.selftest.sh and story-delivery.sh actually use it (a helper nobody sources
#       protects nothing)
#   L4  end to end: the REAL pilot selftest refuses (rc 75, no scenario run) while the lock is held, and
#       holds — then releases on a kill — the lock while it runs
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HSG_GUARD:-$SELF_DIR/heavy-selftest-guard.sh}"
PILOT_SELFTEST="${HSG_PILOT_SELFTEST:-$SELF_DIR/pilot-dispatcher.selftest.sh}"
STORY_DELIVERY="${HSG_STORY_DELIVERY:-$SELF_DIR/story-delivery.sh}"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }

[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/hsg-selftest.XXXXXX")"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
ROOT="$W/locks"

ni_now() { ps -o ni= -p "$$" 2>/dev/null | tr -d '[:space:]'; }
AMB="$(ni_now)"
case "$AMB" in ''|*[!0-9-]*) echo "FATAL: cannot read this process's niceness"; exit 1 ;; esac
T=$((AMB + 3)); [ "$T" -gt 20 ] && T=20
HEADROOM=1; [ "$T" -le "$AMB" ] && HEADROOM=0

# child [ENV=…]… -- 'snippet'   (the guard is already sourced; results in CRC / CO / CE)
CRC=0; CO=""; CE=""
child() {
  local envs=() a o="$W/c.$RANDOM$RANDOM"
  while [ "$#" -gt 0 ]; do a="$1"; shift; [ "$a" = "--" ] && break; envs+=("$a"); done
  env -i PATH="${SHIM_PATH:-$PATH}" HOME="$W" TMPDIR="$W" HSG_GUARD="$GUARD" GC_HEAVY_LOCK_ROOT="$ROOT" \
      SELFTEST_LOCK_POLL_SECS=0.1 ${envs[@]+"${envs[@]}"} ${NICE_PREFIX:-} \
      bash -c ". \"\$HSG_GUARD\"; $1" > "$o.out" 2> "$o.err"
  CRC=$?
  CO="$(cat "$o.out")"; CE="$(cat "$o.err")"
}

wait_file() { local f="$1" n="$2" i=0; while [ ! -e "$f" ] && [ "$i" -lt $((n * 10)) ]; do sleep 0.1; i=$((i+1)); done; [ -e "$f" ]; }

# hold NAME SECS — a background process that takes the lock, signals it holds it, sleeps, stamps the time,
# then releases (the stamp comes FIRST so a waiter can never be observed acquiring "before" it).
HOLDER_PID=""
hold() {
  local name="$1" secs="$2"
  rm -f "$W/held.$name" "$W/released.$name"
  env -i PATH="$PATH" HOME="$W" TMPDIR="$W" HSG_GUARD="$GUARD" GC_HEAVY_LOCK_ROOT="$ROOT" SELFTEST_LOCK_POLL_SECS=0.1 \
    bash -c ". \"\$HSG_GUARD\"; heavy_selftest_lock $name; echo \$\$ > \"$W/held.$name\"; sleep $secs; date +%s > \"$W/released.$name\"; heavy_selftest_release" >/dev/null 2>&1 &
  HOLDER_PID=$!
  wait_file "$W/held.$name" 10
}

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "ambient ni=$AMB  raise target T=$T"
echo "── L1. low priority ──"
if [ "$HEADROOM" -eq 1 ]; then
  child GC_LOWPRIO_NICE="$T" -- 'heavy_selftest_lowprio; echo "ni=$(ps -o ni= -p $$ | tr -d " ") child_ni=$(sh -c "ps -o ni= -p \$\$" | tr -d " ")"'
  [ "$CO" = "ni=$T child_ni=$T" ] && ok "raised to the ABSOLUTE target ni=$T and a child inherits it" || bad "got [$CO] (rc=$CRC err=$CE), wanted ni=$T child_ni=$T"
  case "$CE" in *"low priority: ni $AMB -> $T"*) ok "and says so on stderr" ;; *) bad "no visible notice: [$CE]" ;; esac
  child GC_LOWPRIO_NICE="$T" -- 'heavy_selftest_lowprio; heavy_selftest_lowprio; echo "ni=$(ps -o ni= -p $$ | tr -d " ")"'
  [ "$CO" = "ni=$T" ] && ok "calling it twice does not stack (ni stays $T)" || bad "stacked: [$CO]"
else
  skip "ambient ni=$AMB leaves no headroom"
fi
if [ "$AMB" -le 18 ]; then
  NICE_PREFIX="nice -n 2" child GC_LOWPRIO_NICE="$((AMB + 1))" -- 'heavy_selftest_lowprio; echo "ni=$(ps -o ni= -p $$ | tr -d " ")"'
  [ "$CO" = "ni=$((AMB + 2))" ] && ok "already lower than the target: left at ni=$((AMB + 2)), never lowered" || bad "got [$CO], wanted ni=$((AMB + 2)) kept"
  [ -z "$CE" ] && ok "and silent about it (nothing was done)" || bad "noise for a no-op: [$CE]"
else
  skip "ambient ni=$AMB too high for the never-lower case"
fi
child GC_LOWPRIO=0 GC_LOWPRIO_NICE="$T" -- 'heavy_selftest_lowprio; echo "ni=$(ps -o ni= -p $$ | tr -d " ")"'
[ "$CO" = "ni=$AMB" ] && ok "GC_LOWPRIO=0 leaves ni=$AMB" || bad "kill switch ignored: [$CO]"
mkdir -p "$W/city/.gc"; touch "$W/city/.gc/no-lowprio"
child GC_CITY_PATH="$W/city" GC_LOWPRIO_NICE="$T" -- 'heavy_selftest_lowprio; echo "ni=$(ps -o ni= -p $$ | tr -d " ")"'
[ "$CO" = "ni=$AMB" ] && ok "\$GC_CITY_PATH/.gc/no-lowprio leaves ni=$AMB" || bad "kill file ignored: [$CO]"
rm -f "$W/city/.gc/no-lowprio"
mkdir -p "$W/shim-renice"; printf '#!/bin/bash\nexit 1\n' > "$W/shim-renice/renice"; chmod +x "$W/shim-renice/renice"
if [ "$HEADROOM" -eq 1 ]; then
  SHIM_PATH="$W/shim-renice:$PATH" child GC_LOWPRIO_NICE="$T" -- 'set -euo pipefail; heavy_selftest_lowprio; echo alive'
  [ "$CRC" -eq 0 ] && [ "$CO" = "alive" ] && ok "a failing renice does not abort the suite, even under set -euo pipefail" || bad "rc=$CRC out=[$CO] err=[$CE]"
  case "$CE" in *"WARN could not lower priority"*) ok "and is a visible WARN, not an absence" ;; *) bad "no WARN: [$CE]" ;; esac
fi

echo "── L2. single-flight lock ──"
child -- 'heavy_selftest_lock t1; L="$GC_HEAVY_LOCK_ROOT/t1.lock"; grep -q "^pid=$$\$" "$L/owner" && echo HELD; grep -q "^lstart=.\+" "$L/owner" && echo HAS-LSTART; heavy_selftest_release; [ ! -d "$L" ] && echo GONE'
[ "$CO" = "HELD
HAS-LSTART
GONE" ] && ok "acquire writes pid + start time; release removes the lock" || bad "got [$CO] err=[$CE]"

hold b 8
S=$(date +%s)
child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock b; echo SHOULD-NOT-REACH'
E=$(( $(date +%s) - S ))
if [ "$CRC" -eq 75 ] && [ -z "$CO" ]; then ok "busy + no wait: exits 75 at once without running (took ${E}s)"; else bad "rc=$CRC out=[$CO] err=[$CE]"; fi
case "$CE" in *"NOT RUN"*"NOT a test failure"*) ok "the refusal says NOT RUN and NOT a test failure (could-not-run must never read as ran-and-failed)" ;; *) bad "ambiguous refusal text: [$CE]" ;; esac
case "$CE" in *"pid=$(cat "$W/held.b")"*) ok "and names the owner pid so a human can act on it" ;; *) bad "owner pid missing from: [$CE]" ;; esac
[ "$E" -le 3 ] && ok "did not wait" || bad "SELFTEST_LOCK_WAIT_SECS=0 still waited ${E}s"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null

hold w 2
child SELFTEST_LOCK_WAIT_SECS=30 -- 'heavy_selftest_lock w; date +%s > "'"$W"'/acq.w"; heavy_selftest_release'
if [ "$CRC" -eq 0 ] && wait_file "$W/released.w" 5; then
  [ "$(cat "$W/acq.w")" -ge "$(cat "$W/released.w")" ] && ok "a second run WAITS for the first, then runs (acquired at/after the release)" || bad "acquired BEFORE the holder released — no mutual exclusion"
else
  bad "waiter rc=$CRC err=[$CE]"
fi
case "$CE" in *"waiting for the 'w' lock held by pid"*"acquired after"*) ok "progress is visible while waiting" ;; *) bad "no waiting/acquired messages: [$CE]" ;; esac
wait "$HOLDER_PID" 2>/dev/null

hold t 6
S=$(date +%s)
child SELFTEST_LOCK_WAIT_SECS=1 -- 'heavy_selftest_lock t; echo SHOULD-NOT-REACH'
E=$(( $(date +%s) - S ))
[ "$CRC" -eq 75 ] && [ "$E" -ge 1 ] && [ "$E" -le 4 ] && ok "a bounded wait that runs out exits 75 after ~1s (took ${E}s)" || bad "rc=$CRC took ${E}s err=[$CE]"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null

echo "  — stale / recycled / unknown owners —"
DEAD_PID="$(bash -c 'echo $$')"          # a pid that existed a moment ago and is gone
mkdir -p "$ROOT/s.lock"
printf 'pid=%s\nlstart=Mon Jan  1 00:00:00 2001\nsince=1\ncmd=x\n' "$DEAD_PID" > "$ROOT/s.lock/owner"
child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock s; echo GOT; heavy_selftest_release'
[ "$CRC" -eq 0 ] && [ "$CO" = "GOT" ] && ok "a lock whose owner process is gone is reclaimed" || bad "rc=$CRC out=[$CO] err=[$CE]"
case "$CE" in *"reclaimed a stale 's' lock"*) ok "and the reclaim is announced" ;; *) bad "silent reclaim: [$CE]" ;; esac

sleep 30 & LIVE_PID=$!
mkdir -p "$ROOT/p.lock"
printf 'pid=%s\nlstart=Mon Jan  1 00:00:00 2001\nsince=1\ncmd=x\n' "$LIVE_PID" > "$ROOT/p.lock/owner"
child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock p; echo GOT; heavy_selftest_release'
[ "$CRC" -eq 0 ] && [ "$CO" = "GOT" ] && ok "a LIVE pid with a different start time (pid recycled) is not the owner: reclaimed" || bad "recycled pid honoured: rc=$CRC out=[$CO]"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

mkdir -p "$ROOT/e.lock"
child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock e; echo SHOULD-NOT-REACH'
[ "$CRC" -eq 75 ] && ok "a FRESH lock dir with no owner record yet is busy (creator is mid-write), not stale" || bad "fresh empty lock taken: rc=$CRC out=[$CO]"
mkdir -p "$ROOT/o.lock"
touch -t "$(date -v-2M +%Y%m%d%H%M)" "$ROOT/o.lock" 2>/dev/null
child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock o; echo GOT; heavy_selftest_release'
[ "$CRC" -eq 0 ] && [ "$CO" = "GOT" ] && ok "an OLD lock dir that never got an owner record (creator died) is reclaimed" || bad "old empty lock not reclaimed: rc=$CRC out=[$CO] err=[$CE]"

mkdir -p "$W/shim-ps"; printf '#!/bin/bash\nexit 1\n' > "$W/shim-ps/ps"; chmod +x "$W/shim-ps/ps"
hold u 6
SHIM_PATH="$W/shim-ps:$PATH" child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock u; echo SHOULD-NOT-REACH'
[ "$CRC" -eq 75 ] && ok "with ps unusable the owner state is UNKNOWN, treated as busy — never stolen on a blind ps" || bad "lock stolen while ps was broken: rc=$CRC out=[$CO]"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null

echo "  — fail-open, re-entrancy, ownership, signals —"
child GC_HEAVY_LOCK_ROOT=/dev/null/nope -- 'heavy_selftest_lock f; echo CONTINUED'
[ "$CRC" -eq 0 ] && [ "$CO" = "CONTINUED" ] && ok "a lock that cannot be created does not block the suite" || bad "rc=$CRC out=[$CO]"
case "$CE" in *"UNGUARDED"*) ok "…and says it is running UNGUARDED" ;; *) bad "silent fail-open: [$CE]" ;; esac
SHIM_PATH="$W/shim-ps:$PATH" child -- 'heavy_selftest_lock blind; echo CONTINUED; [ ! -d "$GC_HEAVY_LOCK_ROOT/blind.lock" ] && echo NO-UNATTRIBUTABLE-LOCK'
[ "$CRC" -eq 0 ] && [ "$CO" = "CONTINUED
NO-UNATTRIBUTABLE-LOCK" ] && ok "if it cannot read its OWN start time it runs unguarded and leaves no lock a peer would call dead after 30s" || bad "rc=$CRC out=[$CO] err=[$CE]"
case "$CE" in *"UNGUARDED"*) ok "…and says UNGUARDED" ;; *) bad "silent: [$CE]" ;; esac
child SELFTEST_LOCK=0 -- 'heavy_selftest_lock k; [ ! -d "$GC_HEAVY_LOCK_ROOT/k.lock" ] && echo NO-LOCK'
[ "$CO" = "NO-LOCK" ] && ok "SELFTEST_LOCK=0 skips the lock" || bad "kill switch ignored: [$CO]"
child -- 'heavy_selftest_lock "bad/name"; echo CONTINUED'
[ "$CRC" -eq 0 ] && [ "$CO" = "CONTINUED" ] && ok "a malformed lock name warns and runs unguarded (never a path escape)" || bad "rc=$CRC out=[$CO]"

child -- 'heavy_selftest_lock r; SELFTEST_LOCK_WAIT_SECS=0 bash -c ". \"\$HSG_GUARD\"; heavy_selftest_lock r; echo CHILD-OK"; echo "child-rc=$?"; heavy_selftest_release'
[ "$CO" = "CHILD-OK
child-rc=0" ] && ok "a suite launched BY the holder does not deadlock on its parent's lock (re-entrancy)" || bad "got [$CO] err=[$CE]"

child -- 'heavy_selftest_lock x2; L="$GC_HEAVY_LOCK_ROOT/x2.lock"; rm -rf "$L"; mkdir "$L"; printf "pid=1\nlstart=other\nsince=1\ncmd=o\n" > "$L/owner"; heavy_selftest_release; [ -f "$L/owner" ] && echo KEPT'
[ "$CO" = "KEPT" ] && ok "release never removes a lock that was handed to someone else" || bad "released a foreign lock: [$CO]"

cat > "$W/sigterm.sh" <<EOF
#!/bin/bash
. "$GUARD"
trap 'heavy_selftest_release' EXIT
heavy_selftest_lock sg
echo \$\$ > "$W/sg.pid"
sleep 30
EOF
env -i PATH="$PATH" HOME="$W" GC_HEAVY_LOCK_ROOT="$ROOT" bash "$W/sigterm.sh" >/dev/null 2>&1 &
SGP=$!
wait_file "$W/sg.pid" 10
[ -d "$ROOT/sg.lock" ] && kill -TERM "$SGP" 2>/dev/null; wait "$SGP" 2>/dev/null
[ ! -d "$ROOT/sg.lock" ] && ok "a suite killed by SIGTERM (a timeout, a reaper) releases the lock through its EXIT trap" || bad "lock left behind after SIGTERM"

echo "  — a lock released between our failed mkdir and our look at it is FREE, not unusable —"
# A holder that releases in the window between a waiter's failed `mkdir` and its `[ -d ]` test used to make
# the waiter conclude "the lock cannot be created" and run UNGUARDED beside whoever took it next (measured:
# 5 of 70 six-way races on a loaded host). The shim loses exactly that race once: the first plain mkdir of a
# *.lock path fails and creates nothing, as if the holder had just gone; every later mkdir is the real one.
mkdir -p "$W/shim-mkdir"
cat > "$W/shim-mkdir/mkdir" <<'SHIM'
#!/bin/bash
for a in "$@"; do last="$a"; done
case "$last" in
  *.lock)
    if [ -n "${SHIM_MKDIR_ALWAYS:-}" ]; then exit 1; fi
    if [ -n "${SHIM_MKDIR_STATE:-}" ] && [ ! -e "$SHIM_MKDIR_STATE" ]; then : > "$SHIM_MKDIR_STATE"; exit 1; fi ;;
esac
exec /bin/mkdir "$@"
SHIM
chmod +x "$W/shim-mkdir/mkdir"
SHIM_PATH="$W/shim-mkdir:$PATH" child SHIM_MKDIR_STATE="$W/mk.state" -- 'heavy_selftest_lock mv; L="$GC_HEAVY_LOCK_ROOT/mv.lock"; grep -q "^pid=$$\$" "$L/owner" && echo HELD; heavy_selftest_release'
if [ "$CO" = "HELD" ]; then ok "a mkdir that lost a race with a releasing holder is retried and TAKES the lock (not run unguarded)"; else bad "got [$CO] err=[$CE]"; fi
case "$CE" in *UNGUARDED*) bad "a released lock was read as unusable (ran UNGUARDED): [$CE]" ;; *) ok "…and it never says UNGUARDED for a lock that was merely free" ;; esac
S=$(date +%s)
SHIM_PATH="$W/shim-mkdir:$PATH" child SHIM_MKDIR_ALWAYS=1 -- 'heavy_selftest_lock nv; echo CONTINUED'
E=$(( $(date +%s) - S ))
if [ "$CRC" -eq 0 ] && [ "$CO" = "CONTINUED" ] && [ "$E" -le 5 ]; then ok "a lock that can NEVER be created still fails open after a few tries (took ${E}s), no endless loop"; else bad "rc=$CRC out=[$CO] took ${E}s err=[$CE]"; fi
case "$CE" in *"keeps failing"*"UNGUARDED"*) ok "…and says UNGUARDED, loudly" ;; *) bad "silent fail-open: [$CE]" ;; esac

echo "  — a real 6-way race —"
printf '0' > "$W/counter"; : > "$W/violations"
RACERS=""
for i in 1 2 3 4 5 6; do
  env -i PATH="$PATH" HOME="$W" HSG_GUARD="$GUARD" GC_HEAVY_LOCK_ROOT="$ROOT" SELFTEST_LOCK_POLL_SECS=0.05 SELFTEST_LOCK_WAIT_SECS=120 \
    bash -c '. "$HSG_GUARD"; heavy_selftest_lock race
             mkdir "'"$W"'/inside" 2>/dev/null || echo "two inside at once (racer '"$i"')" >> "'"$W"'/violations"
             n=$(cat "'"$W"'/counter"); sleep 0.05; echo $((n+1)) > "'"$W"'/counter"
             rmdir "'"$W"'/inside" 2>/dev/null
             heavy_selftest_release' >/dev/null 2>&1 &
  RACERS="$RACERS $!"
done
for p in $RACERS; do wait "$p" 2>/dev/null; done
[ "$(cat "$W/counter")" = "6" ] && ok "6 racers, 6 increments: no lost update, every one eventually ran" || bad "counter=$(cat "$W/counter") (expected 6)"
[ ! -s "$W/violations" ] && ok "never two inside the critical section at once (real mutual exclusion)" || bad "$(cat "$W/violations")"
[ ! -d "$ROOT/race.lock" ] && ok "the lock is free again afterwards" || bad "race lock leaked"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "── L2b. gate callers never queue (a reviewer runs the suite twice per review inside a sized timeout) ──"
hold g 15
S=$(date +%s)
child GC_TEMPLATE=gate-reviewer -- 'heavy_selftest_lock g; echo RAN'
E=$(( $(date +%s) - S ))
if [ "$CRC" -eq 0 ] && [ "$CO" = "RAN" ] && [ "$E" -le 3 ]; then ok "a gate-reviewer session does not queue behind a held lock: it runs at once (took ${E}s)"; else bad "rc=$CRC out=[$CO] err=[$CE] took ${E}s"; fi
case "$CE" in *"a gate caller (gate-reviewer) does not queue"*) ok "and says so on stderr (a bypass must be visible)" ;; *) bad "silent bypass: [$CE]" ;; esac
child GC_TEMPLATE=gastown.dog SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock g; echo SHOULD-NOT-REACH'
if [ "$CRC" -eq 75 ] && [ -z "$CO" ]; then ok "a builder (gastown.dog) under the SAME held lock still gets rc 75 NOT RUN"; else bad "builder was not held back: rc=$CRC out=[$CO]"; fi
child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock g; echo SHOULD-NOT-REACH'
[ "$CRC" -eq 75 ] && ok "no template at all (a launchd job, a human terminal) queues too" || bad "an unset GC_TEMPLATE was exempt: rc=$CRC out=[$CO]"
child GC_TEMPLATE=gate-reviewer SELFTEST_LOCK_EXEMPT_TEMPLATES= SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock g; echo SHOULD-NOT-REACH'
[ "$CRC" -eq 75 ] && ok "SELFTEST_LOCK_EXEMPT_TEMPLATES set EMPTY turns the exemption off (the reviewer queues like everyone)" || bad "an empty exemption list was ignored: rc=$CRC out=[$CO]"
child GC_TEMPLATE=my-tpl SELFTEST_LOCK_EXEMPT_TEMPLATES="other my-tpl" -- 'heavy_selftest_lock g; echo RAN'
[ "$CRC" -eq 0 ] && [ "$CO" = "RAN" ] && ok "the exempt list is configurable (a custom template is exempt)" || bad "a custom exemption was ignored: rc=$CRC out=[$CO]"
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
# lock FREE: the gate caller TAKES it, so builders yield to the gate instead of the other way round
child GC_TEMPLATE=gate-reviewer -- 'heavy_selftest_lock g2; L="$GC_HEAVY_LOCK_ROOT/g2.lock"; grep -q "^pid=$$\$" "$L/owner" && echo HELD; heavy_selftest_release; [ ! -d "$L" ] && echo GONE'
[ "$CO" = "HELD
GONE" ] && ok "with the lock FREE a gate caller takes it (and releases it): builders yield to the gate" || bad "got [$CO] err=[$CE]"

echo "── L3. wiring ──"
[ -f "$PILOT_SELFTEST" ] || { bad "pilot selftest not found at $PILOT_SELFTEST"; }
gl="$(grep -n 'heavy_selftest_guard pilot-dispatcher' "$PILOT_SELFTEST" | head -1 | cut -d: -f1)"
wl="$(grep -n '^WORK="\$(mktemp' "$PILOT_SELFTEST" | head -1 | cut -d: -f1)"
if [ -n "$gl" ] && [ -n "$wl" ] && [ "$gl" -lt "$wl" ]; then ok "pilot-dispatcher.selftest.sh takes the guard (line $gl) before it creates any fixture (line $wl)"; else bad "guard call missing or after the fixture setup (guard line='${gl:-none}', mktemp line='${wl:-none}')"; fi
grep -q 'heavy-selftest-guard.sh' "$PILOT_SELFTEST" && ok "…by sourcing heavy-selftest-guard.sh" || bad "pilot selftest does not source the guard"
awk '/^cleanup\(\)/{print; exit}' "$PILOT_SELFTEST" | grep -q 'heavy_selftest_release' \
  && ok "its cleanup() (EXIT trap) releases the lock" || bad "cleanup() does not call heavy_selftest_release — the lock would only clear via stale-owner reclaim"
hdr="$(sed -n '1,30p' "$PILOT_SELFTEST")"
case "$hdr" in *"machine-wide"*) ok "the header documents the lock and the real runtime" ;; *) bad "header still describes the old ~140s run and says nothing about the lock" ;; esac
case "$hdr" in *"timeout 180"*) bad "header still advises 'timeout 180', which would kill a ~20-30 min run mid-flight" ;; *) ok "header no longer advises a 180s bound" ;; esac

sl="$(grep -n 'heavy_selftest_lowprio' "$STORY_DELIVERY" | head -1 | cut -d: -f1)"
s6="$(grep -n 'Step 6: Run prod test' "$STORY_DELIVERY" | head -1 | cut -d: -f1)"
if [ -n "$sl" ] && [ -n "$s6" ] && [ "$sl" -lt "$s6" ]; then ok "story-delivery.sh lowers its own priority (line $sl) long before Step 6 runs the prod tests (line $s6)"; else bad "story-delivery.sh does not renice itself before the prod tests (lowprio line='${sl:-none}', Step 6 line='${s6:-none}')"; fi
grep -q 'heavy-selftest-guard.sh' "$STORY_DELIVERY" && ok "…via the shared helper" || bad "story-delivery.sh does not source the helper"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "── L4. the REAL pilot selftest, end to end ──"
if [ -f "$PILOT_SELFTEST" ] && grep -q 'heavy_selftest_guard pilot-dispatcher' "$PILOT_SELFTEST"; then
  ROOT4="$W/locks4"; mkdir -p "$ROOT4"
  env -i PATH="$PATH" HOME="$W" TMPDIR="$W" HSG_GUARD="$GUARD" GC_HEAVY_LOCK_ROOT="$ROOT4" \
    bash -c '. "$HSG_GUARD"; heavy_selftest_lock pilot-dispatcher; echo $$ > "'"$W"'/held4"; sleep 20' >/dev/null 2>&1 &
  H4=$!
  wait_file "$W/held4" 10
  S=$(date +%s)
  env -i PATH="$PATH" HOME="$W" TMPDIR="$W" GC_HEAVY_LOCK_ROOT="$ROOT4" SELFTEST_LOCK_WAIT_SECS=0 \
    timeout 60 bash "$PILOT_SELFTEST" > "$W/p4.out" 2> "$W/p4.err"; RC4=$?
  E=$(( $(date +%s) - S ))
  [ "$RC4" -eq 75 ] && ok "while another full run holds the lock, the real selftest exits 75 (took ${E}s)" || bad "rc=$RC4 (want 75); err: $(head -3 "$W/p4.err")"
  grep -q 'NOT RUN' "$W/p4.err" && ok "and says NOT RUN" || bad "no NOT RUN message"
  ! grep -qE '✓|✗|Scenario|passed' "$W/p4.out" && ok "and ran no scenario at all (stdout has no assertions)" || bad "it ran scenarios despite the lock: $(head -3 "$W/p4.out")"
  kill "$H4" 2>/dev/null; wait "$H4" 2>/dev/null

  rm -rf "$ROOT4"; mkdir -p "$ROOT4"
  env -i PATH="$PATH" HOME="$W" TMPDIR="$W" GC_HEAVY_LOCK_ROOT="$ROOT4" timeout 12 bash "$PILOT_SELFTEST" > "$W/p5.out" 2> "$W/p5.err" &
  P5=$!
  if wait_file "$ROOT4/pilot-dispatcher.lock/owner" 10; then
    owner="$(sed -n 's/^pid=//p' "$ROOT4/pilot-dispatcher.lock/owner")"
    kill -0 "$owner" 2>/dev/null && ok "a free lock is taken by the running suite (owner pid $owner is the suite)" || bad "owner pid $owner is not alive"
  else
    bad "the running suite never took the lock"
  fi
  wait "$P5" 2>/dev/null
  [ ! -d "$ROOT4/pilot-dispatcher.lock" ] && ok "killed by timeout mid-run, it releases the lock (EXIT trap) — nothing left to reclaim" || bad "lock leaked after a timeout kill"
else
  bad "pilot-dispatcher.selftest.sh is not wired to the guard yet — the end-to-end cases were NOT run (they would launch the whole 20-30 min suite unguarded)"
fi

echo
echo "== $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
