#!/usr/bin/env bash
# gate-push-reject-class.selftest.sh (ga-x4rbnt, via ga-mzw9dt)
#
# BUG. quality-gate-dispatcher.sh's FF push (do_merge_ff) called EVERY failed push "main moved during push; will retry" and
# threw the push's stderr away. ga-vhzdh5.3: a pre-push hook (the ga-oj73m scripts/ guard) refused a clean fast-forward, three
# ALL-PASS runs in a row ended in failed_push_race, and each re-submission paid a full review for the same refusal.
#
# What is executed, not described:
#   1. REAL `git push` outputs, captured from a bare remote: a lost race (fetch first), a stale --force-with-lease, a LOCAL
#      pre-push hook that rejects, a SERVER-side pre-receive hook that rejects, an unreachable remote;
#   2. gate_push_reject_class on each of them (hook only on positive evidence of a hook; everything unreadable is "unknown",
#      which keeps today's behavior = retry), and gate_push_reject_detail (the hook's words, no git boilerplate);
#   3. the dispatcher's LIVE classification block (SELFTEST-EXTRACT push-reject-class) run under /bin/bash 3.2 with
#      `set -euo pipefail`: a hook gives failed_push_hook_rejected, a race and an EMPTY capture give failed_push_race;
#   4. drift guards: the retry loop treats failed_push_hook_rejected as non-retryable, the FAIL feedback names the hook, and the
#      push no longer discards its stderr.
#
# Point DISPATCHER at an older copy of the script to see it go red (the fix is what turns it green).
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2)
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/gate-push-reject-XXXXXX") || { echo "FATAL: no temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

echo "── 1. real git push outputs ──"
git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/a" 2>/dev/null
git clone -q "$T/remote.git" "$T/b" 2>/dev/null
( cd "$T/a" && git config user.email t@t && git config user.name t && echo 1 > f && git add f && git commit -qm c1 && git push -q origin HEAD:main ) >/dev/null 2>&1
( cd "$T/b" && git config user.email t@t && git config user.name t && git pull -q origin main && echo 2 >> f && git commit -qam c2 && git push -q origin HEAD:main ) >/dev/null 2>&1
cd "$T/a" || exit 1
echo 3 >> f; git commit -qam c3
git push origin HEAD:refs/heads/main > "$T/out.race" 2>&1
git push --force-with-lease=main:0000000000000000000000000000000000000001 origin HEAD:refs/heads/main > "$T/out.stale" 2>&1
git fetch -q origin; git reset -q --hard origin/main; echo 4 >> f; git commit -qam c4
mkdir -p .git/hooks
printf '#!/bin/sh\necho "BLOCKED: scripts/ guard (ga-oj73m)" >&2\nexit 1\n' > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
git push origin HEAD:refs/heads/main > "$T/out.localhook" 2>&1
rm -f .git/hooks/pre-push
printf '#!/bin/sh\necho "remote says no" >&2\nexit 1\n' > "$T/remote.git/hooks/pre-receive"; chmod +x "$T/remote.git/hooks/pre-receive"
git push origin HEAD:refs/heads/main > "$T/out.serverhook" 2>&1
rm -f "$T/remote.git/hooks/pre-receive"
git push "$T/nonexistent/x.git" HEAD:refs/heads/main > "$T/out.unreachable" 2>&1
for k in race stale localhook serverhook unreachable; do
  if [ -s "$T/out.$k" ]; then ok "captured a real push output: $k"; else bad "no output captured for $k (the experiment itself failed)"; fi
done
grep -q '\[rejected\]' "$T/out.race"            && ok "premise: the race prints a '! [rejected]' status line"            || bad "premise broken: no '[rejected]' in the race output — the classifier's evidence changed with this git"
grep -q 'BLOCKED' "$T/out.localhook" && ! grep -q '! \[' "$T/out.localhook" && ok "premise: a local pre-push hook prints its words and NO '! [' status line" || bad "premise broken: local-hook output has a status line, or lost the hook's words"
grep -q 'hook declined' "$T/out.serverhook"      && ok "premise: a server hook is '[remote rejected] … hook declined'"   || bad "premise broken: no 'hook declined' in the server-hook output"
grep -q 'fatal:' "$T/out.unreachable"            && ok "premise: an unreachable remote is a 'fatal:'"                    || bad "premise broken: no 'fatal:' in the unreachable output"
cd "$SELF_DIR" || exit 1

echo "── 2. gate_push_reject_class / gate_push_reject_detail (the REAL functions, lib-only) ──"
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" || { echo "FATAL: could not source $DISPATCHER in lib-only mode"; exit 1; }
log() { :; }; warn() { :; }; err() { :; }
if ! declare -F gate_push_reject_class >/dev/null 2>&1; then
  bad "gate_push_reject_class is not defined by $DISPATCHER — this is the state BEFORE ga-x4rbnt (every failed push was a 'race')"
  echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
cls() { gate_push_reject_class "$(cat "$T/out.$1")"; }
eq "lost race (fetch first)                → race"    "$(cls race)"        race
eq "stale --force-with-lease (stale info)  → race"    "$(cls stale)"       race
eq "LOCAL pre-push hook rejects            → hook"    "$(cls localhook)"   hook
eq "SERVER-side pre-receive hook declines  → hook"    "$(cls serverhook)"  hook
eq "unreachable remote (fatal:)            → unknown" "$(cls unreachable)" unknown
eq "empty capture                          → unknown" "$(gate_push_reject_class '')" unknown
eq "garbage                                → unknown" "$(gate_push_reject_class 'something odd happened')" unknown
eq "remote rejected, NOT a hook (lock)     → unknown" "$(gate_push_reject_class $' ! [remote rejected] HEAD -> main (failed to update ref)\nerror: failed to push some refs to x')" unknown
eq "refspec error (deterministic, not a hook) → unknown" "$(gate_push_reject_class $'error: src refspec main does not match any\nerror: failed to push some refs to x')" unknown
eq "hook words + a race status line (mixed) → race, never hook" "$(gate_push_reject_class $'BLOCKED: x\n ! [rejected] HEAD -> main (fetch first)\nerror: failed to push some refs to x')" race
eq "a hook that prints 'fatal:' itself      → unknown (conservative: keeps retrying)" "$(gate_push_reject_class $'fatal: my guard says no\nerror: failed to push some refs to x')" unknown
d=$(gate_push_reject_detail "$(cat "$T/out.localhook")")
case "$d" in *"BLOCKED: scripts/ guard (ga-oj73m)"*) ok "detail keeps the hook's own words" ;; *) bad "detail lost the hook's words: [$d]" ;; esac
case "$d" in *"failed to push some refs"*|*hint:*|*"To "*) bad "detail still carries git boilerplate: [$d]" ;; *) ok "detail drops git's boilerplate (To/hint/error: failed to push)" ;; esac
d=$(gate_push_reject_detail "$(cat "$T/out.serverhook")")
case "$d" in *"remote says no"*"hook declined"*) ok "server-hook detail names the remote's words and the decline" ;; *) bad "server-hook detail incomplete: [$d]" ;; esac
big=$(awk 'BEGIN{for(i=0;i<200;i++) printf "BLOCKED line %d with some padding to make it long enough to be cut off\n", i}')
n=$(gate_push_reject_detail "$big" | wc -c | tr -d ' ')
if [ "$n" -le 800 ]; then ok "detail is capped (<=800 bytes, got $n)"; else bad "detail is not capped: $n bytes"; fi

echo "── 3. the dispatcher's LIVE classification block, under /bin/bash 3.2 with set -euo pipefail ──"
BLK=$(sed -n '/# SELFTEST-EXTRACT push-reject-class: BEGIN/,/# SELFTEST-EXTRACT push-reject-class: END/p' "$DISPATCHER" | sed '1d;$d')
if [ -z "$BLK" ]; then
  bad "no SELFTEST-EXTRACT push-reject-class block in the dispatcher — do_merge_ff still discards the push's stderr"
else
  ok "the classification block is in do_merge_ff"
  # shellcheck disable=SC2016
  RUN='set -euo pipefail
GATE_DISPATCHER_LIB_ONLY=1 source "$D" >/dev/null 2>&1 || true
log(){ :; }; warn(){ :; }; err(){ :; }
MERGE_ATTEMPT=0
one() {
  local PUSH_ERR_FILE="$1"
  MERGE_RESULT=""; GATE_PUSH_HOOK_DETAIL=""
  '"$BLK"'
  return 1
}
one "$2" || true
printf "%s|%s" "$MERGE_RESULT" "$(printf %s "$GATE_PUSH_HOOK_DETAIL" | head -1)"'
  r=$(D="$DISPATCHER" $B32 -c "$RUN" _ "$DISPATCHER" "$T/out.localhook" 2>&1) || true
  eq "local pre-push hook  → failed_push_hook_rejected, with the hook's words" "$r" "failed_push_hook_rejected|BLOCKED: scripts/ guard (ga-oj73m)"
  r=$(D="$DISPATCHER" $B32 -c "$RUN" _ "$DISPATCHER" "$T/out.serverhook" 2>&1 | head -1) || true
  case "$r" in failed_push_hook_rejected\|*) ok "server hook → failed_push_hook_rejected" ;; *) bad "server hook gave [$r]" ;; esac
  r=$(D="$DISPATCHER" $B32 -c "$RUN" _ "$DISPATCHER" "$T/out.race" 2>&1) || true
  eq "lost race            → failed_push_race (retry, as before)" "$r" "failed_push_race|"
  r=$(D="$DISPATCHER" $B32 -c "$RUN" _ "$DISPATCHER" "$T/out.unreachable" 2>&1) || true
  eq "unreachable remote   → failed_push_race (unknown keeps today's behavior)" "$r" "failed_push_race|"
  : > "$T/out.empty"
  r=$(D="$DISPATCHER" $B32 -c "$RUN" _ "$DISPATCHER" "$T/out.empty" 2>&1) || true
  eq "EMPTY capture        → failed_push_race (third state = today's behavior)" "$r" "failed_push_race|"
  r=$(D="$DISPATCHER" $B32 -c "$RUN" _ "$DISPATCHER" "$T/does-not-exist" 2>&1) || true
  eq "capture file gone    → failed_push_race" "$r" "failed_push_race|"
fi

echo "── 4. drift guards ──"
if grep -q '\[ "\$MERGE_RESULT" = "failed_push_hook_rejected" \] || \\' "$DISPATCHER"; then ok "retry loop: failed_push_hook_rejected is in the NON-retryable list"; else bad "retry loop does not list failed_push_hook_rejected as non-retryable"; fi
if grep -q 'git_rig push origin "\${CUR_BRANCH}:refs/heads/\$DEFAULT_BRANCH" 2>/dev/null' "$DISPATCHER"; then bad "the FF push still discards its stderr (2>/dev/null)"; else ok "the FF push no longer discards its stderr"; fi
if grep -q 'REFUSED BY A HOOK' "$DISPATCHER" && grep -q 'GATE_PUSH_HOOK_DETAIL:-' "$DISPATCHER"; then ok "the FAIL feedback names the hook and carries its words"; else bad "the FAIL feedback does not carry the hook's words"; fi
if grep -q 'failed_push_hook_rejected' "$DISPATCHER" && ! sed -n '/failed_merge_time_conflict" \]; then$/,/^      fi$/p' "$DISPATCHER" | grep -q 'failed_push_hook_rejected'; then ok "a hook refusal does not borrow the needs-rebase hand-off (a rebase does not change what a hook reads)"; else bad "a hook refusal is wired into the needs-rebase hand-off"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
