#!/usr/bin/env bash
# gate-push-race-not-fix-attempt.selftest.sh (ga-90pq1k)
#
# BUG. quality-gate-dispatcher.sh: an ALL-PASS run whose merge ended as failed_push_race (main moved under the push, on every one of the
# MAX_MERGE_RETRIES attempts) was degraded to FAIL and fell into the SAME fix-attempt machinery as a genuine review rejection: it bumped
# gate:fix-attempt:N, and the 3rd such failure hit GATE_FIX_CAP and escalated the bead to needs-human — approved code, nobody ever asked
# to change it. ga-39l9z2 fixed exactly this for failed_merge_time_conflict (GATE_NEEDS_REBASE_NOT_FIX); the push race was left out.
# The Mayor's decision on ga-90pq1k: check whether failed_push_race still bumps the counter after ga-mzw9dt; if it does, fix it. It did
# (5 dispatcher_complete events with merge_result=failed_push_race in .gc/quality-gate.jsonl, 07-12/10, each one a fix-attempt bump).
#
# What is decided, and what is NOT: only a race git ITSELF reported (gate_push_reject_class = "race", read from the LAST attempt) lifts
# the cap. failed_push_race is also the end state of (a) a push refused for a reason nobody identified ("unknown": empty/unreadable
# stderr, a fatal:, a remote refusal that is not a hook) and (b) a hook refusal seen ONCE (provisional, ga-x4rbnt). Neither is evidence of
# a race; the cap is what bounds a refusal that never clears, so both keep it. failed_push_hook_rejected (confirmed hook) and
# failed_merge_time_rebase keep the cap too.
#
# What is executed, not described:
#   1. REAL `git push` outputs from a bare remote: a lost race, a local pre-push hook, the live hook's TRANSIENT refusal, an unreachable
#      remote, and an empty capture;
#   2. the dispatcher's LIVE blocks chained under /bin/bash 3.2 with `set -euo pipefail`, attempt by attempt, exactly as the retry loop
#      runs them: SELFTEST-EXTRACT push-reject-class (do_merge_ff's classification, now also exporting the class) →
#      SELFTEST-EXTRACT push-hook-confirm (the retry loop's hook confirmation) → SELFTEST-EXTRACT push-race-not-fix (the finalize
#      decision). The outcome asserted is the flag the fix-attempt cap block reads (GATE_NEEDS_REBASE_NOT_FIX);
#   3. mutants that must go red: the class condition dropped (any failed_push_race lifts the cap) and the whole decision removed;
#   4. drift guards: the class is exported by do_merge_ff and reset per attempt, the decision sits before the remerge stamp, the flag
#      is the one the (a2) arm reads, and that arm is still the FIRST arm of the cap chain and never touches gate:fix-attempt
#      (gate-merge-time-conflict-not-fix-attempt.selftest.sh owns the arm's body).
#
# Point DISPATCHER at the previous copy of the script to see it go red (the fix is what turns it green).
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2)
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/gate-push-race-nofix-XXXXXX") || { echo "FATAL: no temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

echo "── 1. real git push outputs ──"
FIX="$T/fix"; mkdir -p "$FIX"
git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/a" 2>/dev/null
git clone -q "$T/remote.git" "$T/b" 2>/dev/null
( cd "$T/a" && git config user.email t@t && git config user.name t && echo 1 > f && git add f && git commit -qm c1 && git push -q origin HEAD:main ) >/dev/null 2>&1
( cd "$T/b" && git config user.email t@t && git config user.name t && git pull -q origin main && echo 2 >> f && git commit -qam c2 && git push -q origin HEAD:main ) >/dev/null 2>&1
cd "$T/a" || exit 1
echo 3 >> f; git commit -qam c3
git push origin HEAD:refs/heads/main > "$FIX/race" 2>&1
git fetch -q origin; git reset -q --hard origin/main; echo 4 >> f; git commit -qam c4
mkdir -p .git/hooks
printf '#!/bin/sh\necho "BLOCKED: scripts/ guard (ga-oj73m)" >&2\nexit 1\n' > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
git push origin HEAD:refs/heads/main > "$FIX/hook" 2>&1
printf '#!/bin/sh\necho "BLOCKED: some other words" >&2\nexit 1\n' > .git/hooks/pre-push
git push origin HEAD:refs/heads/main > "$FIX/hook2" 2>&1
rm -f .git/hooks/pre-push
# the live .githooks/pre-push refusal that is TRANSIENT (its own ls-remote blipped) — copied word for word from that hook
cat > .git/hooks/pre-push <<'HOOK'
#!/bin/sh
echo "WARNING: Cannot verify integration branches (remote unreachable)." >&2
echo "Push to main blocked. Retry when network is available," >&2
echo "or set GT_INTEGRATION_LAND=1 if this is an intentional land operation." >&2
exit 1
HOOK
chmod +x .git/hooks/pre-push
git push origin HEAD:refs/heads/main > "$FIX/transient" 2>&1
rm -f .git/hooks/pre-push
git push "$T/nonexistent/x.git" HEAD:refs/heads/main > "$FIX/unreachable" 2>&1
: > "$FIX/empty"
for k in race hook hook2 transient unreachable; do
  if [ -s "$FIX/$k" ]; then ok "captured a real push output: $k"; else bad "no output captured for $k (the experiment itself failed)"; fi
done
grep -q '\[rejected\]' "$FIX/race" && ok "premise: the race prints a '! [rejected]' status line" || bad "premise broken: no '[rejected]' in the race output"
cd "$SELF_DIR" || exit 1

echo "── 2. the dispatcher's LIVE blocks, chained attempt by attempt under /bin/bash 3.2 ──"
ext() { sed -n "/# SELFTEST-EXTRACT $1: BEGIN/,/# SELFTEST-EXTRACT $1: END/p" "$DISPATCHER" | sed '1d;$d'; }
CLS=$(ext push-reject-class)
CONF=$(ext push-hook-confirm)
DECIDE=$(ext push-race-not-fix)
[ -n "$CLS" ]  && ok "found the classification block (do_merge_ff)"            || bad "no SELFTEST-EXTRACT push-reject-class block"
[ -n "$CONF" ] && ok "found the hook-confirmation block (retry loop)"           || bad "no SELFTEST-EXTRACT push-hook-confirm block"
if [ -n "$DECIDE" ]; then ok "found the finalize decision block (failed_* handling)"; else bad "no SELFTEST-EXTRACT push-race-not-fix block — a push race still spends a gate:fix-attempt slot"; fi

# One scripted run. Each argument is one attempt: a fixture name (a push the remote refused, captured as in the daemon) or
# `merge_time_rebase` (an attempt that never reached the push). The harness mirrors the retry loop: the per-attempt resets, the
# classification, the confirmation, the non-retryable stop; then the finalize decision. Output: MERGE_RESULT|GATE_NEEDS_REBASE_NOT_FIX.
# $1 = classification block, $2 = confirmation block, $3 = decision block (a mutant swaps one of them).
mkrun() {
  cat <<'EOS'
set -euo pipefail
GATE_DISPATCHER_LIB_ONLY=1 source "$D" >/dev/null 2>&1 || true
log(){ :; }; warn(){ :; }; err(){ :; }
MERGE_ATTEMPT=0; MERGE_RESULT=""; GATE_PUSH_HOOK_PREV=""; GATE_PUSH_HOOK_DETAIL=""; GATE_PUSH_REJECT_CLASS=""
GATE_NEEDS_REBASE_NOT_FIX="0"
one() {
  local PUSH_ERR_FILE="$1"
EOS
  printf '%s\n' "$1"
  cat <<'EOS'
  return 1
}
for step in "$@"; do
  MERGE_ATTEMPT=$((MERGE_ATTEMPT+1))
  GATE_PUSH_HOOK_DETAIL=""; GATE_PUSH_REJECT_CLASS=""
  case "$step" in
    merge_time_rebase) MERGE_RESULT=failed_merge_time_rebase ;;
    *) cp "$FIX/$step" "$FIX/cap.copy"; one "$FIX/cap.copy" || true ;;
  esac
EOS
  printf '%s\n' "$2"
  cat <<'EOS'
  case "$MERGE_RESULT" in failed_push_hook_rejected|failed_merge_time_rebase) break ;; esac
done
EOS
  printf '%s\n' "$3"
  printf '%s\n' 'printf "%s|%s" "$MERGE_RESULT" "$GATE_NEEDS_REBASE_NOT_FIX"'
}
run() { D="$DISPATCHER" FIX="$FIX" $B32 -c "$RC" _ "$@" 2>&1 || true; }
# The decision block sits inside `if [[ failed* ]]` in the dispatcher: here the harness only reaches it after a failed attempt.
RC=$(mkrun "$CLS" "$CONF" "$DECIDE")

R=failed_push_race; H=failed_push_hook_rejected
eq "3 lost races (git said 'fetch first' each time)  → not a fix attempt"   "$(run race race race)"        "$R|1"
eq "hook seen once, then races                       → not a fix attempt (the last attempt was a race)" "$(run hook race race)" "$R|1"
eq "races, then ONE unreadable refusal (last = unknown) → keeps the cap"     "$(run race race unreachable)" "$R|0"
eq "3 unreachable remotes (unknown, never 'race')    → keeps the cap"        "$(run unreachable unreachable unreachable)" "$R|0"
eq "3 EMPTY captures (nothing to read)               → keeps the cap"        "$(run empty empty empty)"     "$R|0"
eq "the live hook's TRANSIENT refusal x3 (unknown)   → keeps the cap"        "$(run transient transient transient)" "$R|0"
eq "races, then a hook seen ONCE at the end (provisional) → keeps the cap"   "$(run race race hook)"        "$R|0"
eq "different hook words each time (never confirmed) → keeps the cap"        "$(run hook hook2 hook)"       "$R|0"
eq "the same hook words twice in a row → failed_push_hook_rejected, keeps the cap" "$(run hook hook)"       "$H|0"
eq "a race, then failed_merge_time_rebase (not a push result) → keeps the cap (the scope boundary of ga-39l9z2 stays)" "$(run race merge_time_rebase)" "failed_merge_time_rebase|0"

echo "── 3. mutants: the cases above must go red when the fix is weakened ──"
# (a) drop the class condition: every failed_push_race lifts the cap — the unknown/empty/provisional cases must flip to 1
MDEC_ANY=$(printf '%s\n' "$DECIDE" | sed 's/ && \[ "${GATE_PUSH_REJECT_CLASS:-}" = "race" \]//')
if [ -n "$DECIDE" ] && [ "$MDEC_ANY" != "$DECIDE" ]; then
  RC=$(mkrun "$CLS" "$CONF" "$MDEC_ANY")
  eq "mutant (class condition dropped): an UNKNOWN refusal wrongly lifts the cap → that case is load-bearing" "$(run unreachable unreachable unreachable)" "$R|1"
  eq "mutant (class condition dropped): a once-seen hook at the end wrongly lifts the cap"                  "$(run race race hook)"   "$R|1"
else
  bad "mutant (class condition dropped) could not be built — the decision block changed shape"
fi
# (b) the decision removed (the state before ga-90pq1k): the race case must be 0 — i.e. spending a fix-attempt slot
RC=$(mkrun "$CLS" "$CONF" ":")
eq "mutant (no decision = the pre-fix state): 3 lost races leave the flag 0 → the fix-attempt counter is bumped" "$(run race race race)" "$R|0"
# (c) the class not exported by do_merge_ff: the decision never sees "race"
MCLS=$(printf '%s\n' "$CLS" | grep -v '^[[:space:]]*GATE_PUSH_REJECT_CLASS=')
if [ -n "$CLS" ] && [ "$MCLS" != "$CLS" ]; then
  RC=$(mkrun "$MCLS" "$CONF" "$DECIDE")
  eq "mutant (do_merge_ff does not export the class): a real race stays on the cap" "$(run race race race)" "$R|0"
else
  bad "mutant (class not exported) could not be built — do_merge_ff does not export GATE_PUSH_REJECT_CLASS"
fi

echo "── 4. drift guards ──"
if grep -q '^    GATE_PUSH_REJECT_CLASS="" ' "$DISPATCHER"; then ok "retry loop: the class is initialised before the loop"; else bad "retry loop does not initialise GATE_PUSH_REJECT_CLASS"; fi
if grep -q '^      GATE_PUSH_REJECT_CLASS="" ' "$DISPATCHER"; then ok "retry loop: the class is reset before every attempt (an attempt that never reached the push cannot inherit an earlier 'race')"; else bad "retry loop does not reset GATE_PUSH_REJECT_CLASS per attempt"; fi
L_RESET=$(grep -n '^      GATE_PUSH_REJECT_CLASS="" ' "$DISPATCHER" | head -1 | cut -d: -f1)
L_DO=$(grep -n '^      if do_merge_ff; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_RESET" ] && [ -n "$L_DO" ] && [ "$L_RESET" -lt "$L_DO" ]; then ok "the reset (line $L_RESET) precedes the do_merge_ff call (line $L_DO)"; else bad "the reset does not precede the do_merge_ff call (reset=$L_RESET call=$L_DO)"; fi
L_DEC=$(grep -n 'SELFTEST-EXTRACT push-race-not-fix: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_CAP=$(grep -n 'GATE_FIX_CAP=3$' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_DEC" ] && [ -n "$L_CAP" ] && [ "$L_DEC" -lt "$L_CAP" ]; then ok "the decision (line $L_DEC) is made before the fix-attempt cap block (line $L_CAP) reads the flag"; else bad "the decision is not before the cap block (decision=$L_DEC cap=$L_CAP)"; fi
if printf '%s\n' "$DECIDE" | grep -q '^[[:space:]]*GATE_NEEDS_REBASE_NOT_FIX=1$'; then ok "the decision sets GATE_NEEDS_REBASE_NOT_FIX — the flag the (a2) arm reads (ga-39l9z2), not a new one"; else bad "the decision block does not set GATE_NEEDS_REBASE_NOT_FIX"; fi
NR_LN=$(grep -n 'if \[ "\$GATE_NEEDS_REBASE_NOT_FIX" = "1" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
CAP_LN=$(grep -n 'elif \[ "\$PREV_ATTEMPT" -ge "\$GATE_FIX_CAP" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$NR_LN" ] && [ -n "$CAP_LN" ] && [ "$NR_LN" -lt "$CAP_LN" ]; then ok "the flag's arm (line $NR_LN) is checked before the fix-attempt cap (line $CAP_LN)"; else bad "the needs-rebase arm is not ahead of the cap (nr=$NR_LN cap=$CAP_LN)"; fi
NR_BODY=$(awk '
  /if \[ "\$GATE_NEEDS_REBASE_NOT_FIX" = "1" \]; then/ { flag=1 }
  flag { print }
  /elif \[ "\$PREV_ATTEMPT" -ge "\$GATE_FIX_CAP" \]; then/ { if (flag) exit }
' "$DISPATCHER")
if [ -n "$NR_BODY" ] && ! printf '%s\n' "$NR_BODY" | grep -E '^[[:space:]]*[^#[:space:]].*(label (add|remove)|--add-label|--remove-label).*gate:fix-attempt' >/dev/null; then ok "the flag's arm never mutates gate:fix-attempt:* (the counter is not bumped)"; else bad "the flag's arm touches gate:fix-attempt (or could not be extracted)"; fi
# the other two non-race results keep the cap: the decision names failed_push_race and nothing else
if printf '%s\n' "$DECIDE" | grep -q 'failed_push_race' && ! printf '%s\n' "$DECIDE" | grep -E 'failed_push_hook_rejected|failed_merge_time_rebase|failed_landing' >/dev/null; then ok "the decision is scoped to failed_push_race only"; else bad "the decision is not scoped to failed_push_race"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
