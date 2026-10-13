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
#      which keeps today's behavior = retry), gate_push_reject_detail (the hook's words, no git boilerplate), and — gate-fix,
#      after the first review — the three things that stop one refusal from being read as a deterministic one: a hook that
#      says its refusal is transient (the live .githooks/pre-push does, on a network blip) is never "hook";
#      gate_push_hook_confirmed (the same words twice in a row); gate_push_hook_feedback (no absolute, echo -e safe);
#   3. the dispatcher's LIVE classification block (SELFTEST-EXTRACT push-reject-class) run under /bin/bash 3.2 with
#      `set -euo pipefail`: a hook gives failed_push_hook_rejected — also a VERBOSE one whose capture is past 8 KB — a race, a
#      transient refusal and an EMPTY capture give failed_push_race, and the log says what git said;
#   3b. the retry loop's LIVE confirmation block (SELFTEST-EXTRACT push-hook-confirm): one refusal is retried, the same words
#      twice in a row end the retries, a race in between or no words at all never do; each with a mutant that must go red;
#   4. drift guards: the retry loop treats failed_push_hook_rejected as non-retryable, the FAIL feedback names the hook, the
#      push no longer discards its stderr, and it runs with LC_ALL=C.
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
# a VERBOSE hook (the real guard prints a park_labels --check diff): the markers that tell a hook from a race are at the END of git's output
cat > .git/hooks/pre-push <<'HOOK'
#!/bin/sh
i=0
while [ $i -lt 400 ]; do echo "BLOCKED verbose line $i padded out so that the whole capture runs far past 8 KB of text" >&2; i=$((i+1)); done
exit 1
HOOK
chmod +x .git/hooks/pre-push
git push origin HEAD:refs/heads/main > "$T/out.bighook" 2>&1
rm -f .git/hooks/pre-push
# the live .githooks/pre-push refusal that is TRANSIENT: its own ls-remote blipped (copied word for word from that hook)
cat > .git/hooks/pre-push <<'HOOK'
#!/bin/sh
echo "WARNING: Cannot verify integration branches (remote unreachable)." >&2
echo "Push to main blocked. Retry when network is available," >&2
echo "or set GT_INTEGRATION_LAND=1 if this is an intentional land operation." >&2
exit 1
HOOK
chmod +x .git/hooks/pre-push
git push origin HEAD:refs/heads/main > "$T/out.transient" 2>&1
rm -f .git/hooks/pre-push
printf '#!/bin/sh\necho "remote says no" >&2\nexit 1\n' > "$T/remote.git/hooks/pre-receive"; chmod +x "$T/remote.git/hooks/pre-receive"
git push origin HEAD:refs/heads/main > "$T/out.serverhook" 2>&1
rm -f "$T/remote.git/hooks/pre-receive"
git push "$T/nonexistent/x.git" HEAD:refs/heads/main > "$T/out.unreachable" 2>&1
for k in race stale localhook bighook transient serverhook unreachable; do
  if [ -s "$T/out.$k" ]; then ok "captured a real push output: $k"; else bad "no output captured for $k (the experiment itself failed)"; fi
done
grep -q '\[rejected\]' "$T/out.race"            && ok "premise: the race prints a '! [rejected]' status line"            || bad "premise broken: no '[rejected]' in the race output — the classifier's evidence changed with this git"
grep -q 'BLOCKED' "$T/out.localhook" && ! grep -q '! \[' "$T/out.localhook" && ok "premise: a local pre-push hook prints its words and NO '! [' status line" || bad "premise broken: local-hook output has a status line, or lost the hook's words"
[ "$(wc -c < "$T/out.bighook" | tr -d ' ')" -gt 8192 ] && tail -n 1 "$T/out.bighook" | grep -q 'failed to push some refs' && ok "premise: the verbose hook's capture is past 8 KB and git's closing line is at the END" || bad "premise broken: the verbose capture is not past 8 KB, or its closing line moved"
grep -q 'remote unreachable' "$T/out.transient" && ! grep -q '! \[' "$T/out.transient" && ok "premise: the transient refusal reaches git as a plain local-hook failure (the shape that reads as 'hook')" || bad "premise broken: transient-refusal output changed shape"
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
eq "VERBOSE hook (capture past 8 KB)       → hook (read from the whole capture)" "$(cls bighook)" hook
# ga-mzw9dt.1 gate-fix: a hook refusal is a CLAIM that needs more than one observation. The live hook refuses on a network blip.
eq "the live pre-push hook's TRANSIENT refusal (remote unreachable / Retry when network…) → unknown, never hook" "$(cls transient)" unknown
eq "policy wording that merely says 'retry' stays hook (only transient causes are excluded)" "$(gate_push_reject_class $'BLOCKED: fix the scripts/ change, then retry the push\nerror: failed to push some refs to x')" hook
eq "server hook whose own words say 'timed out' → unknown" "$(gate_push_reject_class $'remote: upstream check timed out\nTo x\n ! [remote rejected] main -> main (pre-receive hook declined)\nerror: failed to push some refs to x')" unknown
eq "git's own 'To <url>' line is not the hook's words (a URL naming 'network' stays hook)" "$(gate_push_reject_class $'BLOCKED: x\nTo ssh://network.example/x.git\nerror: failed to push some refs to ssh://network.example/x.git')" hook
eq "transient wording is judged case-insensitively" "$(gate_push_hook_transient 'Remote UNREACHABLE')" yes
eq "a deterministic refusal is not transient"        "$(gate_push_hook_transient 'BLOCKED: scripts/ guard (ga-oj73m)')" no
eq "empty words are not transient (no claim either way)" "$(gate_push_hook_transient '')" no
# gate_push_hook_confirmed: the retries stop only on the SAME non-empty words twice in a row
eq "same words twice                → confirmed" "$(gate_push_hook_confirmed 'BLOCKED: x' 'BLOCKED: x')" confirmed
eq "first sighting (no previous)    → once"      "$(gate_push_hook_confirmed '' 'BLOCKED: x')" once
eq "different words (cause moving)  → once"      "$(gate_push_hook_confirmed 'BLOCKED: x' 'BLOCKED: y')" once
eq "words, then none                → once"      "$(gate_push_hook_confirmed 'BLOCKED: x' '')" once
eq "no words twice (two unknowns)   → once, never 'the same words'" "$(gate_push_hook_confirmed '' '')" once
# gate_push_hook_feedback: what the author reads. FAIL_REASONS goes through `echo -e` downstream.
fb=$(gate_push_hook_feedback fix/x main 'path C:\new\tab and \n kept')
shown=$(echo -e "$fb")
case "$shown" in *'C:\new\tab and \n kept'*) ok "feedback: a backslash sequence in the hook's words survives echo -e as written" ;; *) bad "feedback: echo -e rewrote the hook's words: [$shown]" ;; esac
case "$fb" in *"REFUSED BY A HOOK"*"two consecutive attempts"*) ok "feedback names the hook and says the refusal was seen twice" ;; *) bad "feedback lost the hook / two-attempt wording" ;; esac
case "$fb" in *"will be refused the same way"*) bad "feedback still asserts an absolute ('will be refused the same way')" ;; *) ok "feedback does not promise more than was observed" ;; esac
case "$(gate_push_hook_feedback fix/x main '')" in *"<no hook output was captured>"*) ok "feedback with no words says so (does not print an empty quote)" ;; *) bad "feedback with no words prints nothing where the hook's words go" ;; esac
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
  # The live block DELETES its capture file once read (rm -f "$PUSH_ERR_FILE"), exactly as in the daemon. Every case therefore runs on
  # a fresh COPY of its fixture: running two cases on one fixture would give the second an empty capture and let a mutant "pass" on
  # a file that is simply gone. A fixture that does not exist is passed through as-is (the "capture file gone" case).
  runc() { # $1 = the script, $2 = the fixture
    local f="$T/cap.copy"
    rm -f "$f"; cp "$2" "$f" 2>/dev/null || f="$2"
    D="$DISPATCHER" $B32 -c "$1" _ "$DISPATCHER" "$f" 2>&1
  }
  r=$(runc "$RUN" "$T/out.localhook") || true
  eq "local pre-push hook  → failed_push_hook_rejected, with the hook's words" "$r" "failed_push_hook_rejected|BLOCKED: scripts/ guard (ga-oj73m)"
  r=$(runc "$RUN" "$T/out.serverhook" | head -1) || true
  eq "server hook → failed_push_hook_rejected (the result field, compared exactly)" "${r%%|*}" failed_push_hook_rejected
  case "$r" in *"remote says no"*) ok "server hook → the remote's own words are in the detail" ;; *) bad "server-hook detail lost the remote's words: [$r]" ;; esac
  r=$(runc "$RUN" "$T/out.bighook") || true
  eq "VERBOSE hook (>8 KB capture) → failed_push_hook_rejected (markers read from the END of the capture)" "${r%%|*}" failed_push_hook_rejected
  case "$r" in *"BLOCKED verbose line 0 "*) ok "verbose hook → the detail quotes the START (the hook's first words)" ;; *) bad "verbose-hook detail is not the hook's first words: [$r]" ;; esac
  # mutant: classify from the FRONT 8 KB (the shape this fix replaced) — the verbose hook must then be missed, or the case proves nothing
  MBLK=$(printf '%s\n' "$BLK" | sed 's/tail -c 65536/head -c 8192/')
  MRUN=${RUN/"$BLK"/"$MBLK"}
  r=$(runc "$MRUN" "$T/out.bighook") || true
  if [ "$MRUN" != "$RUN" ] && [ "${r%%|*}" = "failed_push_race" ]; then ok "mutant (classify from the first 8 KB): the verbose hook is missed → that case is load-bearing"; else bad "mutant did not change the verbose-hook outcome (mutated=$([ "$MRUN" != "$RUN" ] && echo yes || echo no), got [${r%%|*}])"; fi
  r=$(runc "$RUN" "$T/out.transient") || true
  eq "live pre-push TRANSIENT refusal → failed_push_race (retried like a race, never a hook verdict)" "$r" "failed_push_race|"
  r=$(runc "$RUN" "$T/out.race") || true
  eq "lost race            → failed_push_race (retry, as before)" "$r" "failed_push_race|"
  r=$(runc "$RUN" "$T/out.unreachable") || true
  eq "unreachable remote   → failed_push_race (unknown keeps today's behavior)" "$r" "failed_push_race|"
  : > "$T/out.empty"
  r=$(runc "$RUN" "$T/out.empty") || true
  eq "EMPTY capture        → failed_push_race (third state = today's behavior)" "$r" "failed_push_race|"
  r=$(runc "$RUN" "$T/does-not-exist") || true
  eq "capture file gone    → failed_push_race" "$r" "failed_push_race|"
  # the warn line must say what was (not) learned: class=unknown + what git said, not "main moved" for a cause nobody established
  RUNW=${RUN/'warn(){ :; }'/'warn(){ WARNED="$*"; }'}
  RUNW=${RUNW/'printf "%s|%s" "$MERGE_RESULT"'/'printf "%s|%s" "${WARNED:-}"'}
  r=$(runc "$RUNW" "$T/out.unreachable") || true
  case "$r" in *"class=unknown"*"git said: fatal:"*) ok "unknown → the log names class=unknown and quotes git's first line" ;; *) bad "unknown → the log does not say what git said: [$r]" ;; esac
  case "$r" in *"main moved"*) bad "unknown → the log still claims 'main moved' (a cause nobody established): [$r]" ;; *) ok "unknown → the log does not claim 'main moved'" ;; esac
  r=$(runc "$RUNW" "$T/out.race") || true
  case "$r" in *"main moved during push"*) ok "a real race still says 'main moved during push'" ;; *) bad "race lost its wording: [$r]" ;; esac
fi

echo "── 3b. the retry loop's LIVE confirmation block: one refusal never ends the retries ──"
CBLK=$(sed -n '/# SELFTEST-EXTRACT push-hook-confirm: BEGIN/,/# SELFTEST-EXTRACT push-hook-confirm: END/p' "$DISPATCHER" | sed '1d;$d')
if [ -z "$CBLK" ]; then
  bad "no SELFTEST-EXTRACT push-hook-confirm block in the dispatcher — a single hook refusal still ends the retries"
else
  ok "the confirmation block is in the retry loop"
  # each step is one do_merge_ff outcome: hook:<words> | race ; the block runs after every failed attempt, as in the loop
  mkrun() { # $1 = the block to run after each step
    cat <<'EOS'
set -euo pipefail
GATE_DISPATCHER_LIB_ONLY=1 source "$D" >/dev/null 2>&1 || true
log(){ :; }; warn(){ :; }; err(){ :; }
MERGE_ATTEMPT=0; GATE_PUSH_HOOK_PREV=""; GATE_PUSH_HOOK_DETAIL=""; MERGE_RESULT=""; out=""
for step in "$@"; do
  MERGE_ATTEMPT=$((MERGE_ATTEMPT+1)); GATE_PUSH_HOOK_DETAIL=""
  case "$step" in
    hook:*) MERGE_RESULT=failed_push_hook_rejected; GATE_PUSH_HOOK_DETAIL="${step#hook:}" ;;
    *)      MERGE_RESULT=failed_push_race ;;
  esac
EOS
    printf '%s\n' "$1"
    printf '%s\n' '  out="$out$MERGE_RESULT,"' 'done' 'printf "%s" "$out"'
  }
  RC=$(mkrun "$CBLK")
  H=failed_push_hook_rejected; R=failed_push_race
  seq_() { D="$DISPATCHER" $B32 -c "$RC" _ "$@" 2>&1 || true; }
  eq "ONE hook refusal              → retried (race), not a hook verdict" "$(seq_ 'hook:BLOCKED: x')" "$R,"
  eq "same words twice in a row      → confirmed on the 2nd attempt"      "$(seq_ 'hook:BLOCKED: x' 'hook:BLOCKED: x')" "$R,$H,"
  eq "different words, then the same → confirmed only on the 3rd"         "$(seq_ 'hook:BLOCKED: a' 'hook:BLOCKED: b' 'hook:BLOCKED: b')" "$R,$R,$H,"
  eq "hook, a race, the same hook    → NOT consecutive, never confirmed"  "$(seq_ 'hook:BLOCKED: x' race 'hook:BLOCKED: x')" "$R,$R,$R,"
  eq "no words twice (two unknowns)  → never confirmed"                   "$(seq_ 'hook:' 'hook:')" "$R,$R,"
  eq "a race stays a race (untouched)"                                    "$(seq_ race race)" "$R,$R,"
  # mutant: the block removed (the first refusal stands) — the one-refusal case must go RED, or the case proves nothing
  RM=$(mkrun ":")
  rm_out=$(D="$DISPATCHER" $B32 -c "$RM" _ 'hook:BLOCKED: x' 2>&1 || true)
  if [ "$rm_out" = "$H," ]; then ok "mutant (no confirmation: the first refusal stands): the one-refusal case ends the retries → that case is load-bearing"; else bad "mutant behaved unexpectedly: [$rm_out]"; fi
fi

echo "── 4. drift guards ──"
if grep -q '\[ "\$MERGE_RESULT" = "failed_push_hook_rejected" \] || \\' "$DISPATCHER"; then ok "retry loop: failed_push_hook_rejected is in the NON-retryable list"; else bad "retry loop does not list failed_push_hook_rejected as non-retryable"; fi
if grep -q 'git_rig push origin "\${CUR_BRANCH}:refs/heads/\$DEFAULT_BRANCH" 2>/dev/null' "$DISPATCHER"; then bad "the FF push still discards its stderr (2>/dev/null)"; else ok "the FF push no longer discards its stderr"; fi
if grep -q 'REFUSED BY A HOOK' "$DISPATCHER" && grep -q 'GATE_PUSH_HOOK_DETAIL:-' "$DISPATCHER"; then ok "the FAIL feedback names the hook and carries its words"; else bad "the FAIL feedback does not carry the hook's words"; fi
if grep -q 'LC_ALL=C git_rig push origin' "$DISPATCHER"; then ok "the FF push is made with LC_ALL=C (the classifier reads git's closing line in English)"; else bad "the FF push does not force LC_ALL=C"; fi
if grep -q 'tail -c 65536 "\$PUSH_ERR_FILE"' "$DISPATCHER" && grep -q 'head -c 8192 "\$PUSH_ERR_FILE"' "$DISPATCHER"; then ok "the capture is classified from its tail and quoted from its head"; else bad "the capture is not read from both ends"; fi
if grep -q 'GATE_PUSH_HOOK_DETAIL=""  # nothing from an earlier attempt' "$DISPATCHER"; then ok "retry loop: the hook's words are reset before every attempt (no stale words read as this attempt's)"; else bad "retry loop does not reset the hook's words per attempt"; fi
if grep -q 'failed_push_hook_rejected' "$DISPATCHER" && ! sed -n '/failed_merge_time_conflict" \]; then$/,/^      fi$/p' "$DISPATCHER" | grep -q 'failed_push_hook_rejected'; then ok "a hook refusal does not borrow the needs-rebase hand-off (a rebase does not change what a hook reads)"; else bad "a hook refusal is wired into the needs-rebase hand-off"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
