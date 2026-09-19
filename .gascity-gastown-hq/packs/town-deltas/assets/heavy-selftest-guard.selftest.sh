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
#       "NOT RUN", stale / recycled-pid owners reclaimed, live owners never stolen from — not even when owner
#       and waiter run in DIFFERENT locales / timezones (ps renders lstart through the caller's LC_* / TZ),
#       and not when ps PRINTS a good start time but exits non-zero (the value is the evidence, not the
#       status) — unknown != dead, fail-open when the lock cannot be created or a stale one cannot be removed
#       (never announced as reclaimed, never an endless retry, also under a caller's set -euo pipefail),
#       re-entrancy, release only your own lock, SIGTERM release
#   L2b gate callers (reviewers) never queue for the lock — they run the suite twice per review inside a
#       verdict timeout already sized for it — but take it when free, so builders yield to the gate
#   L3  wiring: pilot-dispatcher.selftest.sh and story-delivery.sh actually use it (a helper nobody sources
#       protects nothing)
#   L4  end to end: the REAL pilot selftest refuses (rc 75, no scenario run) while the lock is held, and
#       holds — then releases on a timeout kill — the lock while it runs (timeout's group kill can cut bash's
#       EXIT trap short now and then: a clean release within 3 kills, and no residue that wedges the next run)
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

# hold NAME SECS [ENV=VAL…] — a background process that takes the lock, signals it holds it, sleeps, stamps
# the time, then releases (the stamp comes FIRST so a waiter can never be observed acquiring "before" it).
# The optional assignments give the HOLDER its own locale / timezone (see the L2 locale-and-TZ cases).
HOLDER_PID=""
hold() {
  local name="$1" secs="$2"; shift 2
  rm -f "$W/held.$name" "$W/released.$name"
  env -i PATH="$PATH" HOME="$W" TMPDIR="$W" HSG_GUARD="$GUARD" GC_HEAVY_LOCK_ROOT="$ROOT" SELFTEST_LOCK_POLL_SECS=0.1 ${1+"$@"} \
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

echo "  — ps that PRINTS a good start time but exits non-zero: the value is the evidence, the exit status is not —"
# Measured 2026-09-19 (load ~35): reading a just-born process's start time through `LC_ALL=C TZ=UTC ps` as a bash
# prefix assignment exited NON-ZERO in ~5-8% of runs although ps had printed the right value; the guard's
# `v="$(ps ...)" || v=""` then threw the value away. Read on the OWNER side that empty start time means "cannot
# record who holds the lock" (the suite runs UNGUARDED); read on the WAITER side, from the owner's pid, it means
# "owner is dead" and a LIVE lock is destroyed. The shim runs the real ps, then exits 1 — for every pid
# (SHIM_RC_PID=ALL) or only for one (SHIM_RC_PID=<pid>), so the waiter's own start-time self-check still works and
# only the OWNER's read is affected.
mkdir -p "$W/shim-psrc"
cat > "$W/shim-psrc/ps" <<'SHIM'
#!/bin/bash
/bin/ps "$@"; rc=$?
pid=""; while [ "$#" -gt 0 ]; do case "$1" in -p) pid="${2:-}" ;; esac; shift; done
case "${SHIM_RC_PID:-}" in ALL) exit 1 ;; "") ;; *) [ "$pid" = "$SHIM_RC_PID" ] && exit 1 ;; esac
exit $rc
SHIM
chmod +x "$W/shim-psrc/ps"
SHIM_PATH="$W/shim-psrc:$PATH" child SHIM_RC_PID=ALL -- 'heavy_selftest_lock psrc; L="$GC_HEAVY_LOCK_ROOT/psrc.lock"; grep -q "^pid=$$\$" "$L/owner" && echo HELD; grep -q "^lstart=.\+" "$L/owner" && echo HAS-LSTART; heavy_selftest_release'
[ "$CRC" -eq 0 ] && [ "$CO" = "HELD
HAS-LSTART" ] && ok "a ps that printed the start time but exited 1 still gives a proper owner record (the printed value is used)" || bad "rc=$CRC out=[$CO] err=[$(printf '%s' "$CE" | head -2)]"
case "$CE" in *UNGUARDED*) bad "the good start time was thrown away and the suite ran UNGUARDED: [$(printf '%s' "$CE" | head -1)]" ;; *) ok "…and it never fell open to UNGUARDED over a non-zero exit status" ;; esac
hold psr 6
SHIM_PATH="$W/shim-psrc:$PATH" child SELFTEST_LOCK_WAIT_SECS=0 SHIM_RC_PID="$(cat "$W/held.psr")" -- 'heavy_selftest_lock psr; echo SHOULD-NOT-REACH'
if [ "$CRC" -eq 75 ] && [ -z "$CO" ]; then ok "a LIVE owner whose start time is read through a ps that exits 1 is still alive (busy, rc 75), not stale"; else bad "rc=$CRC out=[$CO] err=[$(printf '%s' "$CE" | head -2)]"; fi
case "$CE" in *"reclaimed"*) bad "a live owner's lock was reclaimed over a non-zero ps exit status: [$(printf '%s' "$CE" | head -1)]" ;; *) ok "…and no reclaim was announced" ;; esac
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null

echo "  — a LIVE owner is alive to every participant, whatever locale / timezone each one runs in —"
# `ps -o lstart=` renders through the CALLER's locale (LC_ALL / LC_TIME / LANG) and TZ, so ONE live process has a
# different start-time string in every environment ("Sat Sep 19 17:02:46 2026", "sáb 19 set 17:02:46 2026",
# "Sat Sep 19 20:02:46 2026" under TZ=UTC). The lock records the owner's string and a DIFFERENT process compares
# it later: read in two environments, a live owner is judged dead, its lock is destroyed and the waiter runs
# beside it — single-flight silently stops being single (the gate's finding on ga-rj7b1a). Every other case in
# this file runs under env -i (no LC_* / TZ), so both sides always shared one representation and the suite was
# blind to exactly this input. Here the owner and the waiter deliberately DIFFER.
LSPROBE_PT="$(env -i PATH="$PATH" LC_ALL=pt_BR.UTF-8 ps -p $$ -o lstart= 2>/dev/null)"
LSPROBE_C="$(env -i PATH="$PATH" LC_ALL=C ps -p $$ -o lstart= 2>/dev/null)"
LZ=0
# "OWNER-ENV|WAITER-ENV" (space-separated assignments; empty = the bare env -i default). A TZ pair always bites
# (UTC and Tokyo are 9 h apart); a locale pair only bites where pt_BR.UTF-8 really renders differently.
for pair in "TZ=UTC|TZ=Asia/Tokyo" "TZ=Asia/Tokyo|TZ=UTC" "LC_ALL=pt_BR.UTF-8|LC_ALL=C" "LC_ALL=C|LC_ALL=pt_BR.UTF-8" "|LC_ALL=pt_BR.UTF-8 TZ=Asia/Tokyo"; do
  LZ=$((LZ + 1)); oenv="${pair%%|*}"; wenv="${pair#*|}"; nm="lz$LZ"
  case "$pair" in
    LC_ALL=*) if [ -z "$LSPROBE_PT" ] || [ "$LSPROBE_PT" = "$LSPROBE_C" ]; then skip "pt_BR.UTF-8 renders lstart like C on this host — the locale pair [$pair] cannot bite"; continue; fi ;;
  esac
  hold "$nm" 8 $oenv
  if [ ! -s "$W/held.$nm" ]; then bad "[$pair] the holder never took the lock"; kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; continue; fi
  hpid="$(cat "$W/held.$nm")"
  child SELFTEST_LOCK_WAIT_SECS=0 $wenv -- "heavy_selftest_lock $nm; echo SHOULD-NOT-REACH"
  if [ "$CRC" -eq 75 ] && [ -z "$CO" ]; then ok "owner [${oenv:-default}] vs waiter [${wenv:-default}]: the LIVE owner is busy (rc 75), not stale"; else bad "owner [${oenv:-default}] vs waiter [${wenv:-default}]: rc=$CRC out=[$CO] err=[$(printf '%s' "$CE" | head -2)]"; fi
  case "$CE" in *"reclaimed"*) bad "[$pair] announced a reclaim of a LIVE owner's lock: [$(printf '%s' "$CE" | head -1)]" ;; *) ok "…and never claims to have reclaimed a live owner's lock" ;; esac
  if kill -0 "$hpid" 2>/dev/null && [ -f "$ROOT/$nm.lock/owner" ]; then ok "…and the owner is still alive with its lock intact"; else bad "[$pair] the live owner lost its lock (or died)"; fi
  rec="$(sed -n 's/^lstart=//p' "$ROOT/$nm.lock/owner" 2>/dev/null | head -1)"
  raw="$(env -i PATH="$PATH" LC_ALL=C TZ=UTC ps -p "$hpid" -o lstart= 2>/dev/null)"
  if [ -n "$rec" ] && [ "$rec" = "${raw//  / }" ]; then ok "…and the start time on record is the canonical (C / UTC) reading, whatever the owner's own environment"; else bad "[$pair] recorded start time [$rec] is not the canonical [${raw//  / }]"; fi
  kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
done

echo "  — a stale lock that cannot be removed: never announced as reclaimed, never an endless loop —"
# _hsg_reclaim used to `rm -rf "$lock" || true`, then announce "reclaimed" and return success whether or not
# the directory was still there; the caller retried at once — no sleep, no wait bound — so a lock that could
# not be removed spun forever printing a claim that was false on every turn. The shim fails every rm of a
# *.lock path (a persistent permission / filesystem failure); a timeout stops the OLD code's spin from
# hanging this suite, and would show up as rc 124.
mkdir -p "$W/shim-rm"
cat > "$W/shim-rm/rm" <<'SHIM'
#!/bin/bash
for a in "$@"; do last="$a"; done
case "$last" in *.lock) exit 1 ;; esac
exec /bin/rm "$@"
SHIM
chmod +x "$W/shim-rm/rm"
DEAD_RF="$(bash -c 'echo $$')"
mkdir -p "$ROOT/rf.lock"
printf 'pid=%s\nlstart=Mon Jan  1 00:00:00 2001\nsince=1\ncmd=x\n' "$DEAD_RF" > "$ROOT/rf.lock/owner"
S=$(date +%s)
SHIM_PATH="$W/shim-rm:$PATH" NICE_PREFIX="timeout 15" child SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock rf; echo CONTINUED'
E=$(( $(date +%s) - S ))
if [ "$CRC" -eq 0 ] && [ "$CO" = "CONTINUED" ] && [ "$E" -le 5 ]; then ok "a stale lock that cannot be removed fails OPEN after one try (took ${E}s), no endless retry loop"; else bad "rc=$CRC out=[$CO] took ${E}s err=[$(printf '%s' "$CE" | head -2)]"; fi
case "$CE" in *"could not remove"*"UNGUARDED"*) ok "…and says so, UNGUARDED, loudly" ;; *) bad "silent or wrong fail-open: [$(printf '%s' "$CE" | head -2)]" ;; esac
case "$CE" in *"reclaimed"*) bad "it CLAIMED to have reclaimed a lock it could not remove: [$(printf '%s' "$CE" | head -1)]" ;; *) ok "…and never claims a reclaim that did not happen" ;; esac
# The same two paths under a caller's `set -euo pipefail` (the pilot selftest and story-delivery are sourced by
# scripts that use it): a non-zero status inside the guard — _hsg_reclaim now returns 2 — must never abort them.
mkdir -p "$ROOT/se1.lock" "$ROOT/se2.lock"
for l in se1 se2; do printf 'pid=%s\nlstart=Mon Jan  1 00:00:00 2001\nsince=1\ncmd=x\n' "$DEAD_RF" > "$ROOT/$l.lock/owner"; done
child SELFTEST_LOCK_WAIT_SECS=0 -- 'set -euo pipefail; heavy_selftest_lock se1; echo LOCKED; heavy_selftest_release; echo RELEASED'
[ "$CRC" -eq 0 ] && [ "$CO" = "LOCKED
RELEASED" ] && ok "reclaiming a stale lock, then acquiring and releasing, survives the caller's set -euo pipefail" || bad "rc=$CRC out=[$CO] err=[$(printf '%s' "$CE" | head -2)]"
SHIM_PATH="$W/shim-rm:$PATH" NICE_PREFIX="timeout 15" child SELFTEST_LOCK_WAIT_SECS=0 -- 'set -euo pipefail; heavy_selftest_lock se2; echo CONTINUED'
[ "$CRC" -eq 0 ] && [ "$CO" = "CONTINUED" ] && ok "…and so does the cannot-remove path (status 2): it fails open instead of aborting the caller" || bad "rc=$CRC out=[$CO] err=[$(printf '%s' "$CE" | head -2)]"

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

  # `timeout` signals the child AND its whole process group, so bash can be handed SIGTERM twice and — by its own
  # rule for a repeated terminating signal — die AT ONCE, without finishing its EXIT trap. Measured 2026-09-19 at
  # load ~35: a script whose only content is `trap 'sleep .3; echo done > f' EXIT; sleep 30` left f unwritten in
  # 2 of 60 `timeout` kills, with no guard code anywhere near it — and a strict one-shot "the lock must be gone"
  # here flaked once in ~8 full runs. So the trap is NOT guaranteed to finish, and a residual lock is not by
  # itself a wiring defect. What must hold is (a) the EXIT-trap wiring really releases the lock: at least one of
  # up to 3 kills ends clean (a wiring that never releases leaks all 3), and (b) whatever a killed run does leave
  # behind never WEDGES the next one: its owner is dead, so the next run reclaims it at once.
  KILL_CLEAN=0; KILL_TRY=0; KILL_WEDGED=0; KILL_NOTAKEN=0
  while [ "$KILL_CLEAN" -eq 0 ] && [ "$KILL_TRY" -lt 3 ]; do
    KILL_TRY=$((KILL_TRY + 1))
    rm -rf "$ROOT4"; mkdir -p "$ROOT4"
    env -i PATH="$PATH" HOME="$W" TMPDIR="$W" GC_HEAVY_LOCK_ROOT="$ROOT4" timeout 12 bash "$PILOT_SELFTEST" > "$W/p5.out" 2> "$W/p5.err" &
    P5=$!
    if wait_file "$ROOT4/pilot-dispatcher.lock/owner" 10; then
      owner="$(sed -n 's/^pid=//p' "$ROOT4/pilot-dispatcher.lock/owner")"
      if [ "$KILL_TRY" -eq 1 ]; then kill -0 "$owner" 2>/dev/null && ok "a free lock is taken by the running suite (owner pid $owner is the suite)" || bad "owner pid $owner is not alive"; fi
    else
      # never let "no lock because the suite never got that far" pass as "no lock because it released it"
      bad "the running suite never took the lock (try $KILL_TRY)"; KILL_NOTAKEN=1; wait "$P5" 2>/dev/null; break
    fi
    wait "$P5" 2>/dev/null
    if [ ! -d "$ROOT4/pilot-dispatcher.lock" ]; then
      KILL_CLEAN=1
    else
      child GC_HEAVY_LOCK_ROOT="$ROOT4" SELFTEST_LOCK_WAIT_SECS=0 -- 'heavy_selftest_lock pilot-dispatcher; echo GOT; heavy_selftest_release'
      { [ "$CRC" -eq 0 ] && [ "$CO" = "GOT" ]; } || KILL_WEDGED=1
    fi
  done
  if [ "$KILL_NOTAKEN" -eq 1 ]; then
    :   # already reported above
  elif [ "$KILL_CLEAN" -eq 1 ] && [ "$KILL_WEDGED" -eq 0 ]; then
    if [ "$KILL_TRY" -eq 1 ]; then ok "killed by timeout mid-run, it releases the lock (EXIT trap) — nothing left to reclaim"
    else ok "killed by timeout mid-run, it releases the lock (EXIT trap) — clean on try $KILL_TRY; timeout's group kill had cut the earlier trap short and that residue was reclaimed at once"; fi
  else
    bad "lock leaked after a timeout kill (clean release: $KILL_CLEAN after $KILL_TRY tries; a residue wedged the next run: $KILL_WEDGED)"
  fi
else
  bad "pilot-dispatcher.selftest.sh is not wired to the guard yet — the end-to-end cases were NOT run (they would launch the whole 20-30 min suite unguarded)"
fi

echo
echo "== $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
