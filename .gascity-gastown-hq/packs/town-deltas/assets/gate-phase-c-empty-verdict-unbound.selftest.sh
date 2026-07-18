#!/usr/bin/env bash
# gate-phase-c-empty-verdict-unbound.selftest.sh (ga-eqjo, gate-fix-3)
#
# Proves: Phase C's verdict-bead rehydration (quality-gate-dispatcher.sh,
# SELFTEST-EXTRACT sentinel "phase-c-verdict-rehydrate") does not abort the
# dispatcher process when a gate-run bead has ZERO verdict beads — the state
# left behind by a prior dispatcher invocation that died between Step 6
# (run-bead creation) and Step 7 (verdict-bead spawning; OOM/SIGKILL/
# launchd-timeout mid-run are established incident classes for this
# dispatcher, not a contrived scenario).
#
# ROOT CAUSE it guards (found live by the quality gate reviewer against
# gate-fix-2, diff e0c75997..262807fc): the SESSION_IDS-populating loop
# (`for PC_VBID in "${VERDICT_BEAD_IDS[@]}"`) ran BEFORE the emptiness guard
# (`if [ "${#VERDICT_BEAD_IDS[@]}" -eq 0 ]; then ...; continue; fi`). This
# dispatcher runs under `set -euo pipefail` (line ~30, never relaxed —
# `grep -n 'set +u\|set +e'` finds zero hits anywhere in the file) via
# `#!/usr/bin/env bash`, which resolves to bash 3.2.57 on macOS — the ONLY
# bash anywhere in this host's PATH (verified: `which -a bash` returns
# exactly one path, no homebrew bash installed). bash < 4.4 treats
# `"${ARR[@]}"` on a declared-but-empty array as an unset-parameter
# reference under `set -u` and aborts with "unbound variable" — a bug fixed
# upstream in bash 4.4, so this class of bug never surfaces to a developer
# testing on Linux or a homebrew-bash macOS shell, only in production here.
#
# Because the crash fires before Phase C's `continue` can skip the bead,
# and nothing else ever closes/relabels a run bead stuck in this state, the
# SAME bead re-crashes the dispatcher on EVERY subsequent sweep (~2min via
# launchd) — for ALL branches/markers that sweep would otherwise process,
# not just the triggering one. Persistent, total pipeline halt until a
# human intervenes: worse than the serialization bug ga-eqjo set out to fix.
#
# Fix: move the emptiness guard BEFORE the loop that consumes the array.
#
# Strategy (follows this repo's established SELFTEST-EXTRACT convention —
# see gate-dispatcher-rig-resolve-noabort.selftest.sh): extract the live
# "phase-c-verdict-rehydrate" block verbatim and run it under a real
# `set -euo pipefail` on THIS HOST'S ACTUAL /bin/bash (not a hypothetical
# newer bash that would mask the bug — Mayor's explicit re-dispatch
# instruction was "TESTAR em bash 3.2 (/bin/bash --version = 3.2.57), NAO
# no bash do homebrew"), with `bd` stubbed to return an EMPTY verdict-bead
# list (the live crash trigger) and a non-empty list (regression guard: the
# happy path must be unaffected). A MUTATION TEST (section 3) swaps the
# guard back to AFTER the loop in a scratch copy — reproducing the EXACT
# ordering the reviewer found — and proves the SAME empty-list input that
# passes cleanly against the real dispatcher aborts against the mutant, so
# this suite is not vacuous (mutation-test discipline, see bead ga-p5q3).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-phase-c-empty-verdict-unbound.selftest =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi
if [ ! -x "$REAL_BASH" ]; then
  echo "FATAL: $REAL_BASH not found — cannot test against the host's actual bash" >&2
  exit 2
fi

BASH_VERSION_STR="$("$REAL_BASH" -c 'echo "$BASH_VERSION"' 2>/dev/null || echo "unknown")"
case "$BASH_VERSION_STR" in
  3.2.*) ok "host's /bin/bash is 3.2.x ($BASH_VERSION_STR) — the version this bug requires to reproduce" ;;
  *)     echo "    (NOTE: host's /bin/bash is $BASH_VERSION_STR, not 3.2.x — the empty-array/set -u bug this test guards was fixed in bash 4.4; section 3's strict abort assertion may go inconclusive on this host. Not a sign the fix regressed.)" ;;
esac

# extract_block <file> <sentinel-name> -> prints the block between BEGIN/END,
# stripped of the sentinel comment lines themselves.
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_rehydrate <dispatcher-file> <vb-json> <bd-log-file>
# Runs the live phase-c-verdict-rehydrate block under a real `set -euo
# pipefail` on the host's actual bash, with bd/warn/log stubbed and
# gate_collect_verdicts stubbed to a marker (this test's job is the
# array-emptiness guard ordering, not gate_collect_verdicts' own internals).
# Wraps the block in `for _dummy in 1; do ... done` so its `continue` (the
# empty-guard's exit path) has a loop to act on, exactly as it does at its
# real call site inside Phase C's per-run loop. Prints combined output and
# returns the block's exit code via $?.
run_rehydrate() {
  local file="$1" vb_json="$2" bd_log="$3"
  local block
  block="$(extract_block "$file" "phase-c-verdict-rehydrate")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"
  "$REAL_BASH" -c '
    set -euo pipefail
    GC_CITY="/fake/city"; GATE_RUN_ID="test-run-1"
    BD_LOG="$1"; VB_JSON_STUB="$2"
    bd() {
      case " $* " in
        *" list "*) echo "$VB_JSON_STUB"; return 0 ;;
        *" show "*) echo "{\"assignee\":\"fake-session-1\"}"; return 0 ;;
      esac
      echo "$*" >> "$BD_LOG"
      return 0
    }
    warn() { echo "WARN: $*" >&2; echo "warn:$*" >> "$BD_LOG"; }
    log()  { echo "LOG: $*" >&2; }
    gate_collect_verdicts() { echo "gate_collect_verdicts_called" >> "$BD_LOG"; }
    for _dummy in 1; do
      '"$block"'
    done
    echo "REACHED_END_OF_LOOP" >> "$BD_LOG"
  ' _ "$bd_log" "$vb_json"
  return $?
}

echo "── 1. Live dispatcher: ZERO verdict beads must NOT abort ──"
BD_LOG_1="$(mktemp)"
OUT_1="$(run_rehydrate "$DISPATCHER" "[]" "$BD_LOG_1" 2>&1)"
RC_1=$?
echo "$OUT_1" | sed 's/^/    [empty] /'
if [ "$RC_1" -eq 0 ]; then
  ok "empty verdict-bead list: dispatcher block exits 0 (does not abort on unbound variable)"
else
  bad "empty verdict-bead list: block exited $RC_1 (expected 0) — bd_log: $(tr '\n' ';' < "$BD_LOG_1")"
fi
if grep -q "^warn:Phase C:.*ZERO verdict beads" "$BD_LOG_1"; then
  ok "empty verdict-bead list: warn() logged the ZERO-verdict-beads diagnosis"
else
  bad "empty verdict-bead list: expected warn() diagnosis not found — bd_log: $(tr '\n' ';' < "$BD_LOG_1")"
fi
if grep -q "gate_collect_verdicts_called" "$BD_LOG_1"; then
  bad "empty verdict-bead list: gate_collect_verdicts was called — the guard should have 'continue'd before reaching it"
else
  ok "empty verdict-bead list: gate_collect_verdicts correctly NOT called (guard's continue fired first)"
fi
rm -f "$BD_LOG_1"

echo "── 2. Regression guard: a NON-empty verdict-bead list still reaches gate_collect_verdicts ──"
NONEMPTY_JSON='[{"id":"vb-1","labels":["reviewer-index:1"]},{"id":"vb-2","labels":["reviewer-index:2"]}]'
BD_LOG_2="$(mktemp)"
OUT_2="$(run_rehydrate "$DISPATCHER" "$NONEMPTY_JSON" "$BD_LOG_2" 2>&1)"
RC_2=$?
echo "$OUT_2" | sed 's/^/    [nonempty] /'
if [ "$RC_2" -eq 0 ]; then
  ok "non-empty verdict-bead list: block exits 0"
else
  bad "non-empty verdict-bead list: block exited $RC_2 (expected 0) — bd_log: $(tr '\n' ';' < "$BD_LOG_2")"
fi
if grep -q "gate_collect_verdicts_called" "$BD_LOG_2"; then
  ok "non-empty verdict-bead list: gate_collect_verdicts correctly reached (happy path unaffected by the fix)"
else
  bad "non-empty verdict-bead list: gate_collect_verdicts NOT called — regression in the happy path"
fi
if grep -q "REACHED_END_OF_LOOP" "$BD_LOG_2"; then
  ok "non-empty verdict-bead list: block ran to completion"
else
  bad "non-empty verdict-bead list: block did not reach its end marker — bd_log: $(tr '\n' ';' < "$BD_LOG_2")"
fi
rm -f "$BD_LOG_2"

echo "── 3. MUTATION TEST: swapping the guard back to AFTER the loop must abort on the SAME empty input ──"
MUT="$(mktemp "${TMPDIR:-/tmp}/gate-eqjo-phasec-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-eqjo-phasec-mutant-$$.sh")"
cleanup_mutant() { rm -f "$MUT"; }
trap cleanup_mutant EXIT
cp "$DISPATCHER" "$MUT"
MUTATE_OK=0
python3 - "$MUT" <<'PYEOF' && MUTATE_OK=1
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()

# The exact fixed ordering: guard, then the loop it protects. Anchored on the
# real production text (not a hand-copied duplicate), so this stays byte-
# accurate to whatever the fix actually shipped as.
guard = '''      if [ "${#VERDICT_BEAD_IDS[@]}" -eq 0 ]; then
        warn "Phase C: gate-run $GATE_RUN_ID has ZERO verdict beads — likely died before Step 7 finished spawning. Leaving for gate-recovery-watchdog's hung-run backstop."
        continue
      fi

'''
loop = '''      SESSION_IDS=()
      for PC_VBID in "${VERDICT_BEAD_IDS[@]}"; do
        # ga-i5s5: `|| echo ""` used to mask a failed `bd show` (assignee
        # read) as a blank session id. A blank PC_SID matches no live
        # session below (root-class:error-vs-empty) -> the dead-reviewer
        # classifier (phase-c-dead-reviewer-classify-fn) reads "not present"
        # -> confirmed DEAD, so a transient Dolt hiccup on THIS read could
        # manufacture a false dead-reviewer verdict for a reviewer that is
        # actually still alive. Use the same __UNKNOWN__ sentinel
        # vb_status_action already establishes for this file's status reads
        # so the classifier can distinguish "confirmed absent" from
        # "couldn't check" instead of conflating them.
        if PC_SID_JSON=$(bd -C "$GC_CITY" show "$PC_VBID" --json 2>/dev/null); then
          PC_SID=$(printf '%s' "$PC_SID_JSON" | jq -r 'if type=="array" then .[0] else . end | .assignee // ""' 2>/dev/null || true)
        else
          PC_SID="__UNKNOWN__"
        fi
        SESSION_IDS+=("$PC_SID")
      done

'''

combo = guard + loop
n = c.count(combo)
if n != 1:
    print("ANCHOR_NOT_UNIQUE count=%d" % n, file=sys.stderr)
    sys.exit(1)

# Reproduce the EXACT pre-gate-fix-3 ordering the reviewer found live: loop
# first, guard after — swap the two blocks in place.
mutant_combo = loop + guard
c2 = c.replace(combo, mutant_combo, 1)
if c2 == c:
    print("SWAP_NO_OP", file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.write(c2)
PYEOF
if [ "$MUTATE_OK" != "1" ]; then
  bad "mutation-test: could not construct the mutant (anchor text not found exactly once — dispatcher shape changed since this test was written?) — MUTATION TEST INCONCLUSIVE, treat as FAIL"
else
  if bash -n "$MUT" 2>/dev/null; then
    ok "mutant remains syntactically valid bash (the guard catches BEHAVIOR, not a parse error)"
  else
    bad "mutant is not valid bash — the mutation itself is malformed, weakening this proof"
  fi
  BD_LOG_MUT="$(mktemp)"
  OUT_MUT="$(run_rehydrate "$MUT" "[]" "$BD_LOG_MUT" 2>&1)"
  RC_MUT=$?
  echo "$OUT_MUT" | sed 's/^/    [mutant] /'
  case "$BASH_VERSION_STR" in
    3.2.*)
      if [ "$RC_MUT" -ne 0 ] && printf '%s' "$OUT_MUT" | grep -qi "unbound variable"; then
        ok "mutant (guard-after-loop, the pre-fix ordering) aborts with 'unbound variable' on the SAME empty input (rc=$RC_MUT) — proves this suite is not vacuous"
      else
        bad "mutant did NOT abort with 'unbound variable' on empty input (rc=$RC_MUT) — output: $OUT_MUT — this test may not actually be exercising the fix"
      fi
      ;;
    *)
      if [ "$RC_MUT" -ne 0 ]; then
        ok "mutant aborts on empty input on this non-3.2 host too (rc=$RC_MUT) — bonus signal, though not the specific bash-3.2 mechanism"
      else
        echo "    (skipping strict mutant-must-abort assertion — host bash is $BASH_VERSION_STR, not 3.2.x, so this specific crash may not reproduce; see NOTE above)"
      fi
      ;;
  esac
  rm -f "$BD_LOG_MUT"
fi

echo ""
echo "== gate-phase-c-empty-verdict-unbound: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
