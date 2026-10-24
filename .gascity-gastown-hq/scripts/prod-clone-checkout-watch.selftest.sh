#!/usr/bin/env bash
# prod-clone-checkout-watch.selftest.sh (ga-eei1o4)
#
# ## Contents
#   What it proves · Scenario · Activation · Reviewer prompt · Mutants
#
# WHAT IT PROVES. Against real git (a bare "origin" + a "prod" clone in a temp dir) the REAL hook, installed through the REAL
# activate script, does what the incident needed:
#   - the 24/10 round trip (checkout --detach <unmerged sha>, then back) leaves a log line per move with the actor's
#     GC_SESSION_NAME, state=off-main then state=on-main prev=off-main, and ONE alarm for the detour, none for the return;
#   - a checkout in a linked worktree of the clone is NOT logged; `git checkout -- file` is kind=files and never alarms, even off-main;
#   - both ways of "cannot tell" (origin/main gone; merge-base itself failing) are state=unknown +
#     alarm, never on-main; a second off-main inside the TTL is logged as alarm=suppressed, not hidden;
#   - a log it cannot write is said on stderr, `git checkout` still exits 0 (also with a dead alarm command, which is itself
#     logged as ALARM-FAILED); the kill switch is logged as DISABLED.
# On the commit before this one none of it exists (no hook, no activate script, no rule in the reviewer prompt), so every
# assertion fails there — that is the "test that fails today" the bead asks for. The MUTANTS section proves the
# assertions are not vacuous: each mutation of the hook must make the scenario fail.
# Env: PCCW_UNDER_TEST (hook file), PCCW_PROMPT (reviewer prompt file).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK_SRC="${PCCW_UNDER_TEST:-$HERE/prod-clone-checkout-watch.sh}"
ACT="$HERE/prod-clone-checkout-watch-activate.sh"
PROMPT="${PCCW_PROMPT:-$HERE/../agents/gate-reviewer/prompt.template.md}"
T=$(mktemp -d) || exit 2
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0; FAILN=0; QUIET=0
chk() { # chk "<what>" <command...>
  _d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAILN=$((FAILN + 1)); [ "$QUIET" = 1 ] || echo "FAIL: $_d"; fi
}
nlines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
has() { [ -f "$1" ] && grep -q -- "$2" "$1"; }
last_has() { [ -f "$1" ] && tail -n 1 "$1" | grep -q -- "$2"; }
# await_lines <file> <n>: wait (bounded) until the file has >= n lines.   settle: grace before a NEGATIVE alarm check —
# the hook writes its log line after it started the alarm child, so by then the child only needs a moment.
await_lines() { _i=0; while [ "$(nlines "$1")" -lt "$2" ] && [ "$_i" -lt 60 ]; do sleep 0.15; _i=$((_i + 1)); done; }
settle() { sleep 0.7; }

G() { git -c user.email=t@t -c user.name=t "$@"; }

# scenario <hook-file> <label>  -> returns the number of failed assertions
scenario() {
  _hook="$1"; D="$T/$2"; mkdir -p "$D"; _before=$FAILN
  ( cd "$D" || exit 1
    G init -q --bare -b main origin.git
    G clone -q origin.git prod 2>/dev/null
    cd prod || exit 1
    echo one > f; G add f; G commit -qm c1; G push -q origin main 2>/dev/null
    C1=$(git rev-parse HEAD)
    G checkout -q -b feature; echo two > f; G commit -qam c2; G push -q origin feature 2>/dev/null
    C2=$(git rev-parse HEAD)
    G checkout -q --detach "$C1"
    printf '%s %s\n' "$C1" "$C2" > "$D/shas" ) >/dev/null 2>&1
  read -r C1 C2 < "$D/shas" 2>/dev/null || { FAILN=$((FAILN + 1)); echo "FAIL: scenario setup ($2)"; return 1; }
  cp "$_hook" "$D/hook.sh"; chmod +x "$D/hook.sh"
  printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s/alarm.out"\n' "$D" > "$D/alarm"; chmod +x "$D/alarm"
  export PCCW_ROOT="$D/prod" PCCW_LOG="$D/log" PCCW_ALARM_CMD="$D/alarm" PCCW_SCRIPT="$D/hook.sh"
  unset PROD_CLONE_WATCH PCCW_ALARM_TTL_MIN
  P="$D/prod"; L="$D/log"; A="$D/alarm.out"; M="$L.alarm"; tag="[$2]"
  chk "$tag activate installs an ACTIVE hook" bash "$ACT"
  chk "$tag --check says ACTIVE" bash "$ACT" --check

  # 1) the 24/10 detour: off-main, one alarm
  GC_SESSION_NAME=sess-A git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1; rc=$?
  chk "$tag checkout exits 0 with the hook installed" test "$rc" = 0
  await_lines "$A" 1
  chk "$tag 1 log line after the detour" test "$(nlines "$L")" = 1
  chk "$tag detour is kind=branch state=off-main prev=on-main" bash -c "grep -q 'kind=branch' '$L' && grep -q 'state=off-main' '$L' && grep -q 'prev=on-main' '$L'"
  chk "$tag detour names the actor (session=sess-A)" has "$L" "session=sess-A"
  chk "$tag detour carries the new short sha" has "$L" "new=${C2:0:9}"
  chk "$tag detour records the process chain" has "$L" "chain=\[[0-9]"
  chk "$tag detour raised exactly 1 alarm naming the sha" bash -c "[ \"\$(wc -l < '$A' | tr -d ' ')\" = 1 ] && grep -q '${C2:0:9}' '$A'"

  # 2) the return: on-main, and NO alarm — the dedup mark is removed first so a wrongful alarm could not hide behind it
  rm -f "$M"
  GC_SESSION_NAME=sess-A git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1; rc=$?
  chk "$tag return checkout exits 0" test "$rc" = 0
  settle
  chk "$tag return is state=on-main prev=off-main" bash -c "tail -n 1 '$L' | grep -q 'state=on-main' && tail -n 1 '$L' | grep -q 'prev=off-main'"
  chk "$tag return does not alarm" test "$(nlines "$A")" = 1

  # 3) a linked worktree of the clone is not the live tree
  git -C "$P" worktree add -q --detach "$D/wt" "$C2" >/dev/null 2>&1
  git -C "$D/wt" checkout -q --detach "$C1" >/dev/null 2>&1
  chk "$tag linked-worktree checkouts are not logged" test "$(nlines "$L")" = 2

  # 4) (file checkouts are covered in step 9, where HEAD is off-main and no dedup mark can hide a wrongful alarm)

  # 5) a fresh off-main alarms (mark absent); 6) the next one inside the TTL is counted as suppressed
  git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1; await_lines "$A" 2
  chk "$tag 2nd detour: alarm=requested and 2 alarms" bash -c "tail -n 1 '$L' | grep -q 'alarm=requested' && [ \"\$(wc -l < '$A' | tr -d ' ')\" = 2 ]"
  git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1
  git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1; settle
  chk "$tag 3rd detour inside the TTL: alarm=suppressed, still 2 alarms" bash -c "tail -n 1 '$L' | grep -q 'alarm=suppressed' && [ \"\$(wc -l < '$A' | tr -d ' ')\" = 2 ]"
  git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1

  # 7) cannot tell (a): origin/main gone -> unknown + alarm, never on-main
  rm -f "$M"; git -C "$P" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
  git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1; await_lines "$A" 3
  chk "$tag origin/main missing -> state=unknown" last_has "$L" "state=unknown"
  chk "$tag ... and it alarmed (3 alarms)" test "$(nlines "$A")" = 3
  git -C "$P" fetch -q origin >/dev/null 2>&1; git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1

  # 8) cannot tell (b): merge-base itself fails (exit 128) -> unknown + alarm, never on-main. A real corrupt history makes git
  #    answer 128 on some versions and 1 on others (seen: macOS git 2.54 vs the Linux node), so the failure is injected
  #    through the PCCW_GIT seam, which is the same on every git.
  printf '#!/bin/sh\ncase " $* " in *" merge-base "*) [ -e "%s/break-mb" ] && exit 128;; esac\nexec git "$@"\n' "$D" > "$D/gitwrap"; chmod +x "$D/gitwrap"
  : > "$D/break-mb"; rm -f "$M"
  PCCW_GIT="$D/gitwrap" git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1; await_lines "$A" 4
  chk "$tag merge-base failing -> state=unknown (not on-main)" last_has "$L" "state=unknown"
  chk "$tag ... and it alarmed (4 alarms)" test "$(nlines "$A")" = 4
  rm -f "$D/break-mb"; git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1

  # 9) the kill switch is logged, not silent — and it lets us stand off-main with no alarm and no dedup mark, so that
  #    `git checkout -- file` (kind=files) can prove it never alarms even when HEAD is off-main
  PROD_CLONE_WATCH=off git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1
  chk "$tag kill switch logs result=DISABLED" last_has "$L" "result=DISABLED"
  rm -f "$M"; _a=$(nlines "$A")
  echo dirty >> "$P/f"; git -C "$P" checkout -q -- f >/dev/null 2>&1; settle
  chk "$tag file checkout while off-main is logged as kind=files, state=off-main" bash -c "tail -n 1 '$L' | grep -q 'kind=files' && tail -n 1 '$L' | grep -q 'state=off-main'"
  chk "$tag ... and a file checkout never alarms" test "$(nlines "$A")" = "$_a"
  git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1

  # 10) an unwritable log is said on stderr and checkout still exits 0
  mkdir -p "$D/ro"; chmod 500 "$D/ro"
  err=$(PCCW_LOG="$D/ro/sub/log" git -C "$P" checkout --detach "$C2" 2>&1 >/dev/null); rc=$?
  chk "$tag unwritable log: checkout still exits 0" test "$rc" = 0
  chk "$tag unwritable log is reported on stderr" bash -c "printf '%s' \"\$1\" | grep -q 'cannot write'" _ "$err"
  git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1

  # 11) a dead alarm command is logged as ALARM-FAILED and does not break checkout
  rm -f "$M"
  PCCW_ALARM_CMD="$D/does-not-exist" git -C "$P" checkout -q --detach "$C2" >/dev/null 2>&1; rc=$?
  chk "$tag dead alarm command: checkout exits 0" test "$rc" = 0
  _i=0; while ! has "$L" "result=ALARM-FAILED" && [ "$_i" -lt 60 ]; do sleep 0.15; _i=$((_i + 1)); done
  chk "$tag dead alarm command is logged as ALARM-FAILED" has "$L" "result=ALARM-FAILED"
  git -C "$P" checkout -q --detach "$C1" >/dev/null 2>&1
  return $((FAILN - _before))
}

echo "== scenario (real hook)"
scenario "$HOOK_SRC" real; _rc=$?; echo "   failed assertions: $_rc"
[ "$_rc" -gt 0 ] && { echo "   --- log written by the hook (for diagnosis) ---"; cut -c1-230 "$T/real/log" 2>/dev/null | sed 's/^/   | /'; }

echo "== activation states"
AD="$T/act"; mkdir -p "$AD"; ( cd "$AD" && G init -q -b main r ) >/dev/null 2>&1
unset PCCW_LOG PCCW_ALARM_CMD; export PCCW_ROOT="$AD/r"
export PCCW_SCRIPT="$AD/missing.sh"
chk "ABSENT: --check exits 1" bash -c "bash '$ACT' --check; [ \$? = 1 ]"
chk "install before the script exists lands INERT (exit 0)" bash -c "bash '$ACT' | grep -q '^INERT'"
chk "INERT: --check exits 1 (registered is not live)" bash -c "bash '$ACT' --check; [ \$? = 1 ]"
printf '#!/bin/sh\nexit 0\n' > "$AD/missing.sh"; chmod +x "$AD/missing.sh"
chk "same link becomes ACTIVE once the script exists" bash -c "bash '$ACT' --check | grep -q '^ACTIVE'"
chk "re-install is idempotent" bash "$ACT"
bash "$ACT" --remove >/dev/null 2>&1
echo '#!/bin/sh' > "$AD/r/.git/hooks/post-checkout"
chk "FOREIGN hook: install exits 3" bash -c "bash '$ACT'; [ \$? = 3 ]"
chk "FOREIGN hook: --remove exits 3" bash -c "bash '$ACT' --remove; [ \$? = 3 ]"
chk "FOREIGN hook is left untouched" bash -c "[ ! -L '$AD/r/.git/hooks/post-checkout' ] && grep -q '#!/bin/sh' '$AD/r/.git/hooks/post-checkout'"
chk "a path under .gc-worktrees is refused (exit 2)" bash -c "PCCW_SCRIPT=/x/.gc-worktrees/y/s.sh bash '$ACT'; [ \$? = 2 ]"
chk "not a git clone -> cannot tell (exit 2)" bash -c "PCCW_ROOT='$AD' bash '$ACT' --check; [ \$? = 2 ]"
unset PCCW_ROOT PCCW_SCRIPT

echo "== reviewer prompt contract"
SEC=$(awk '/^## Read-Only Enforcement/{f=1;next} /^## /{f=0} f' "$PROMPT" 2>/dev/null)
chk "Read-Only section exists" test -n "$SEC"
chk "names the forbidden HEAD-moving git verbs" bash -c "printf '%s' \"\$1\" | grep -q 'git checkout' && printf '%s' \"\$1\" | grep -q 'git switch' && printf '%s' \"\$1\" | grep -q 'git reset'" _ "$SEC"
chk "names the live clone path" bash -c "printf '%s' \"\$1\" | grep -q '/Users/athos/gt/'" _ "$SEC"
chk "gives the read-only idioms (git -C <rig-path> show / grep on a sha)" bash -c "printf '%s' \"\$1\" | grep -q 'git -C <rig-path> show' && printf '%s' \"\$1\" | grep -q 'git -C <rig-path> grep'" _ "$SEC"
chk "gives the own-worktree idiom" bash -c "printf '%s' \"\$1\" | grep -q 'worktree add --detach'" _ "$SEC"
chk "baseline captures HEAD, not only status" bash -c "printf '%s' \"\$1\" | grep -q 'rev-parse HEAD'" _ "$SEC"

echo "== a hook that crashes still exits 0 (and the same hook without the EXIT trap does not)"
crash_rc() { # crash_rc <label> <keep|replacement-for-the-trap-line>  -> echoes the exit status of `git checkout` with a hook that aborts under set -u
  _cd="$T/crash-$1"; mkdir -p "$_cd"
  ( cd "$_cd" && G init -q -b main r && cd r && echo 1 > f && G add f && G commit -qm c ) >/dev/null 2>&1
  python3 -I -c 'import sys
src, dst, trap = sys.argv[1:4]
s = open(src).read()
t = "trap \x27exit 0\x27 EXIT"
assert "main() {\n" in s and t in s
s = s.replace("main() {\n", "main() {\n  : \"$PCCW_NO_SUCH_VARIABLE\"\n", 1)
if trap != "keep": s = s.replace(t, trap, 1)
open(dst, "w").write(s)' "$HOOK_SRC" "$_cd/crash.sh" "$2" >/dev/null 2>&1 || { echo "setup-failed"; return; }
  chmod +x "$_cd/crash.sh"
  ( export PCCW_ROOT="$_cd/r" PCCW_SCRIPT="$_cd/crash.sh" PCCW_LOG="$_cd/log"; bash "$ACT" >/dev/null 2>&1
    git -C "$_cd/r" checkout -q -b other >/dev/null 2>&1; echo $? )
}
rc_with=$(crash_rc with keep); rc_without=$(crash_rc without ':')
chk "a hook aborted by set -u still lets git checkout exit 0 (EXIT trap)" test "$rc_with" = 0
chk "negative control: without the EXIT trap the same crash breaks checkout" test "$rc_without" != 0 -a "$rc_without" != setup-failed

echo "== mutants (each must make the scenario fail)"
MUT=""
mutate() { # mutate <label> <old> <new>
  cp "$HOOK_SRC" "$T/mut-$1.sh"
  python3 -I -c 'import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
assert a in s, "mutation target not found: " + a
open(p, "w").write(s.replace(a, b, 1))' "$T/mut-$1.sh" "$2" "$3" 2>/dev/null
}
launch() { # launch <label> <old> <new>   (runs the scenario in the background, 4 at a time)
  if ! mutate "$1" "$2" "$3"; then FAILN=$((FAILN + 1)); echo "FAIL: mutant $1 did not apply (target text moved?)"; return; fi
  MUT="$MUT $1"
  ( QUIET=1; scenario "$T/mut-$1.sh" "m-$1" >/dev/null 2>&1; echo $? > "$T/res-$1" ) &
  [ "$(jobs -r | wc -l | tr -d ' ')" -ge 4 ] && wait
}
launch off-main-as-healthy    '1) echo off-main' '1) echo on-main'
launch cannot-tell-as-healthy '*) echo unknown ;; esac' '*) echo on-main ;; esac'
launch missing-origin-healthy '"$GIT" rev-parse --verify -q "origin/main^{commit}" >/dev/null 2>&1 || { echo unknown; return; }' '"$GIT" rev-parse --verify -q "origin/main^{commit}" >/dev/null 2>&1 || { echo on-main; return; }'
launch no-worktree-filter     '[ "$top_real" = "$root_real" ] || return 0' 'true'
launch no-actor               'who="session=${GC_SESSION_NAME:-} ' 'who="session= '
launch breaks-checkout        "trap 'exit 0' EXIT" "trap 'exit 1' EXIT"

launch alarm-on-healthy       '[ "$kind" != files ] && [ "$state" != on-main ]' '[ "$kind" != files ]'
launch alarm-on-files         '[ "$kind" != files ] && [ "$state" != on-main ]' '[ "$state" != on-main ]'
launch no-dedup               'if [ -n "$(find "$mark" -mmin -"$ALARM_TTL_MIN" 2>/dev/null)" ]; then' 'if false; then'
launch swallow-log-failure    '|| echo "prod-clone-checkout-watch: cannot write $LOG ($*)" >&2' '|| true'
launch swallow-alarm-failure  '|| emit "result=ALARM-FAILED state=$state new=${head:0:9}"' '|| true'
launch ignore-kill-switch     '[ "${PROD_CLONE_WATCH:-on}" = off ]' 'false'
wait
for m in $MUT; do
  r=$(cat "$T/res-$m" 2>/dev/null || echo "")
  if [ -z "$r" ]; then FAILN=$((FAILN + 1)); echo "FAIL: mutant $m produced no result"
  elif [ "$r" -gt 0 ]; then PASS=$((PASS + 1)); echo "   killed: $m ($r assertions failed)"
  else FAILN=$((FAILN + 1)); echo "FAIL: mutant survived: $m"; fi
done

echo
echo "prod-clone-checkout-watch.selftest: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
