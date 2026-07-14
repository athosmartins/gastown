#!/usr/bin/env bash
# gate-dispatcher-rig-resolve-noabort.selftest.sh (ga-dmox)
#
# Proves: a marker whose rig:/bead_id: fields don't resolve to any registered
# rig (a malformed/hand-rolled marker) must NOT abort the dispatcher process.
# It must be labeled gate-status:error + commented with what's missing, then
# the invocation must exit 0 — not 1 — so daemon-presence-watchdog's per-daemon
# exit-code FAILING counter (scripts/daemon-presence-watchdog.sh) doesn't fire
# over a single bad marker, and the next invocation proceeds to whatever is
# actually gate-status:queued instead of being read as "the dispatcher is down."
#
# ROOT CAUSE it guards: quality-gate-dispatcher.sh's Step 4 (rig-path
# resolution) used to `exit 1` after marking gate-status:error — inconsistent
# with Step 3's OWN established convention 30 lines above it ("cannot derive
# X -> mark terminal, exit 0"). This exact inconsistency, applied at Step 4,
# was the proximate cause of the 2026-07-14 ~17:33-17:47Z outage (ga-dmox):
# daemon-presence-watchdog fired FAILING after 3 consecutive exit=1 sweeps
# (scripts/daemon-presence-watchdog.sh lines ~348-393: `ex -gt 0` increments a
# persisted fail-count; `exit 0` resets it to 0 on the very next sweep).
#
# NOTE ON SCOPE (verified, not assumed — see ga-dmox comment trail): the bug
# report's claimed trigger (crew markers missing a `bead-rig:` LABEL) does NOT
# actually drive this abort. Neither quality-gate-dispatcher.sh nor
# quality-gate-guard.sh read the `bead-rig:` label at all (grep: zero hits in
# both). The live incident's actual marker (ga-wisp-5zki27) was a hand-crafted
# re-submission with a typo'd `bead:` field (not `bead_id:`) and NO `rig:` line
# at all; its `bead-rig:gascity` label was already present and simply unused
# by this code path. This test guards the REAL mechanism (Step 4's exit code
# on a genuinely unresolvable rig path), which is what the bug's own
# acceptance criteria describe in general terms: "um marker malformado nao
# pode derrubar o sweep inteiro" (fix (a) — unifying gate-done's bead-rig
# output — is real and valuable for two OTHER consumers of that label,
# gate-recovery-watchdog.py and gate-marker-rehome-janitor.py, but is a
# distinct defect from this one; see gate-done-crew-rig.selftest.sh).
#
# Strategy: extract the live "rig-path-resolve" block VERBATIM (between its
# SELFTEST-EXTRACT sentinels) and exercise it under the dispatcher's own
# `set -euo pipefail`, stubbing only `bd`/`gc`/`err`/`log` (no real Dolt
# writes). Test 1 reproduces the live incident shape (unresolvable rig AND
# bead_id). Test 2 is a regression guard: a well-formed, resolvable rig must
# still fall through with no error labeling (no behavior change on the happy
# path). Tests 3-7 drift-guard five sibling call sites found during
# investigation — same anti-pattern (mark gate-status:error, then still exit
# 1) in the branch-absent circuit-break, the legacy branch-not-on-remote
# fallback, the main-ref-unresolvable retry path, the merge-tree-undeterminable
# retry path, and the ahead_dead circuit-break. A MUTATION-TEST (assertion 8)
# proves this test is not vacuous: reverting the Step 4 fix in a scratch copy
# must turn assertion 1 red again.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-dispatcher-rig-resolve-noabort.selftest =="

# extract_block <file> <sentinel-name> -> prints the block between BEGIN/END,
# stripped of the sentinel comment lines themselves.
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_rig_resolve <dispatcher-file> <RIG> <BEAD_ID> <bd-log-file>
# Runs the live rig-path-resolve block from the given dispatcher file under a
# real `set -euo pipefail`, with gc/bd/err/log stubbed. Every `bd` invocation's
# arguments are appended to <bd-log-file> (one call per line) so callers can
# assert on exactly what labels/comments were applied. Prints the block's
# stdout/stderr and returns its exit code via $? (propagated from the subshell).
run_rig_resolve() {
  local file="$1" rig="$2" bead_id="$3" bd_log="$4"
  local block
  block="$(extract_block "$file" "rig-path-resolve")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"
  bash -c '
    set -euo pipefail
    RIG="$1"; BEAD_ID="$2"; MARKER_ID="test-marker-1"; GC_CITY="/fake/city"
    BD_LOG="$3"; FAKE_RIG_PATH="$4"
    gc() {
      # Only "rig list --json" is called by this block; return a small fixed
      # roster. Rig paths must be REAL directories, since the block checks
      # [ ! -d "$RIG_PATH" ] — point them at FAKE_RIG_PATH (a real dir, passed
      # in from the enclosing scope; a shell function sees its OWN $1.. on
      # invocation, not the outer scripts, so this must be a plain variable).
      printf "{\"rigs\":[{\"name\":\"whatsapp_automation\",\"prefix\":\"wa\",\"path\":\"%s\"},{\"name\":\"gascity\",\"prefix\":\"ga\",\"path\":\"%s\"}]}" "$FAKE_RIG_PATH" "$FAKE_RIG_PATH"
    }
    bd() { echo "$*" >> "$BD_LOG"; return 0; }
    err() { echo "ERR: $*" >&2; }
    log() { echo "LOG: $*" >&2; }
    '"$block"'
    echo "REACHED_END|RIG_PATH=${RIG_PATH:-<empty>}"
  ' _ "$rig" "$bead_id" "$bd_log" "$SELF_DIR"
  return $?
}

# ── Test 1: live incident shape — rig AND bead_id both unresolvable ─────────
BD_LOG_1="$(mktemp)"
OUT_1="$(run_rig_resolve "$DISPATCHER" "" "" "$BD_LOG_1" 2>&1)"
RC_1=$?
echo "$OUT_1" | sed 's/^/    [test1] /'

if [ "$RC_1" -eq 0 ]; then
  ok "unresolvable-rig marker: dispatcher exits 0 (does not abort the daemon)"
else
  bad "unresolvable-rig marker: dispatcher exited $RC_1 (expected 0 — a single malformed marker must not poison the daemon-level exit-code counter)"
fi
if grep -q "gate-status:error" "$BD_LOG_1"; then
  ok "unresolvable-rig marker: labeled gate-status:error"
else
  bad "unresolvable-rig marker: NOT labeled gate-status:error — got: $(cat "$BD_LOG_1")"
fi
if grep -qE '(^| )comment ' "$BD_LOG_1"; then
  ok "unresolvable-rig marker: a bd comment was left explaining what's missing"
else
  bad "unresolvable-rig marker: no bd comment left — a human/watchdog reading the bead won't know what's wrong"
fi
rm -f "$BD_LOG_1"

# ── Test 2: regression guard — a well-formed, resolvable rig must still pass
#    through with no error labeling (happy path unaffected by this fix). ────
BD_LOG_2="$(mktemp)"
OUT_2="$(run_rig_resolve "$DISPATCHER" "whatsapp_automation" "wa-abc12" "$BD_LOG_2" 2>&1)"
RC_2=$?
echo "$OUT_2" | sed 's/^/    [test2] /'

if [ "$RC_2" -eq 0 ]; then
  ok "well-formed marker: reaches end of block normally (rc=0)"
else
  bad "well-formed marker: unexpectedly aborted (rc=$RC_2) — regression in the happy path"
fi
case "$OUT_2" in
  *"REACHED_END|RIG_PATH=$SELF_DIR"*) ok "well-formed marker: RIG_PATH resolved correctly, no regression";;
  *)                                  bad "well-formed marker: RIG_PATH did not resolve as expected; got: $OUT_2";;
esac
if [ -s "$BD_LOG_2" ]; then
  bad "well-formed marker: unexpected bd call(s) on the happy path: $(cat "$BD_LOG_2")"
else
  ok "well-formed marker: no error labeling on the happy path"
fi
rm -f "$BD_LOG_2"

# ── Tests 3-7: drift-guard 5 sibling same-class sites found during
#    investigation — each already marks gate-status:error (or an equivalent
#    terminal/parked state) via its own bd label+comment, but used to still
#    `exit 1` right after, which is the SAME anti-pattern this bug reports in
#    general terms. Anchor on the exact preceding log line (tighter and more
#    drift-resistant than an absolute line number, which shifts as this file
#    is edited elsewhere). ─────────────────────────────────────────────────
# Anchor must be verified UNIQUE in the file (grep -c == 1) before use — a
# non-unique anchor silently checks the wrong occurrence's exit code (caught
# during development: "Dispatcher sweep complete: branch=...verdict=..." turned
# out to appear twice, and a naive "line right after the match" approach with
# multiple matches picked up the LAST match instead of the intended one).
# Search FORWARD from the anchor for the NEXT bare "exit N" line within a
# bounded window (some sites have several lines of jsonl logging between the
# anchor and their exit statement) — first match in the window, not last.
assert_exit0_after() {
  local anchor="$1" label="$2" window="${3:-3}"
  local hits nextline
  hits="$(grep -cF -- "$anchor" "$DISPATCHER")"
  if [ "$hits" != "1" ]; then
    bad "$label: anchor is not unique in $DISPATCHER (found $hits times) — test needs a more specific anchor"
    return
  fi
  nextline="$(grep -A"$window" -F -- "$anchor" "$DISPATCHER" | tail -n +2 | grep -m1 -E '^\s*exit [01]\s*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$nextline" in
    "exit 0") ok "$label: exits 0 (does not poison the daemon-level exit-code counter)";;
    "exit 1") bad "$label: still exits 1 after '$anchor'";;
    *)        bad "$label: no exit 0/1 found within $window lines after '$anchor' (anchor drifted?)";;
  esac
}

assert_exit0_after \
  'log "ga-acb circuit-break: branch $BRANCH absent from origin — marker $MARKER_ID parked, bead $BEAD_ID needs-human."' \
  "no_branch circuit-break (ga-acb)" \
  6
assert_exit0_after \
  'log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH not found on remote — gate-status:error."' \
  "no_branch legacy retriable fallback"
assert_exit0_after \
  'log "SUPPRESSED PUSH (wa-uthi non-terminal): origin/$DEFAULT_BRANCH unresolvable — gate-status:error (retriable)."' \
  "main-ref unresolvable (racing fetch)"
assert_exit0_after \
  'log "SUPPRESSED PUSH (wa-uthi non-terminal): merge-tree undeterminable for $BRANCH — gate-status:error (retriable)."' \
  "merge-tree conflict pre-check undeterminable"
assert_exit0_after \
  'REBASE_EVENT="dispatcher_circuit_break_ahead_dead"' \
  "ahead_dead circuit-break (ga-acb)" \
  20

# ── Test 8: MUTATION-TEST — this test must not be vacuous. Revert the Step 4
#    fix in a scratch copy (exit 0 -> exit 1) and confirm assertion 1 goes RED
#    again. Proves the test is actually exercising the fix, not a tautology. ─
MUT="$(mktemp)"
cp "$DISPATCHER" "$MUT"
# Flip ONLY the rig-path-resolve block's terminal exit (the one immediately
# preceded by the "Aborting."/"skipping" err() line) back to exit 1.
python3 - "$MUT" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
begin = "# SELFTEST-EXTRACT rig-path-resolve: BEGIN"
end = "# SELFTEST-EXTRACT rig-path-resolve: END"
i, j = text.index(begin), text.index(end)
block = text[i:j]
mutated = re.sub(r'\n(\s*)exit 0\n(\s*)fi\n' + re.escape(end), r'\n\1exit 1\n\2fi\n' + end, block + end, count=1)
if mutated == block + end:
    print("MUTATION_NOT_APPLIED", file=sys.stderr)
    sys.exit(1)
text = text[:i] + mutated + text[j+len(end):]
open(path, 'w').write(text)
PYEOF
if [ $? -ne 0 ]; then
  bad "mutation-test: could not construct a mutated scratch copy (script bug in the test itself)"
else
  BD_LOG_MUT="$(mktemp)"
  run_rig_resolve "$MUT" "" "" "$BD_LOG_MUT" >/dev/null 2>&1
  RC_MUT=$?
  if [ "$RC_MUT" -eq 1 ]; then
    ok "mutation-test: reverting the fix (exit 0 -> exit 1) turns assertion 1 red again (rc=$RC_MUT) — test is not vacuous"
  else
    bad "mutation-test: reverting the fix did NOT change the outcome (rc=$RC_MUT, expected 1) — this test may not actually be exercising the fix"
  fi
  rm -f "$BD_LOG_MUT"
fi
rm -f "$MUT"

echo "== rig-resolve-noabort: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
