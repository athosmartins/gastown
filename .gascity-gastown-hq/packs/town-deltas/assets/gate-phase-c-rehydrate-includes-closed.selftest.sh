#!/usr/bin/env bash
# gate-phase-c-rehydrate-includes-closed.selftest.sh (ga-*, 2026-07-15)
#
# Proves: Phase C's verdict-bead rehydration query (quality-gate-dispatcher.sh,
# SELFTEST-EXTRACT sentinel "phase-c-verdict-rehydrate") passes `--all` to
# `bd list`, so a DELIVERED verdict — which is a CLOSED bead — is STILL FOUND.
#
# ROOT CAUSE it guards (found live 2026-07-15, gate 5h / 0 merges):
#   `bd list` EXCLUDES closed beads by default (bd list --help: "--all  Show all
#   issues including closed (overrides default filter)"). A reviewer DELIVERS a
#   verdict by CLOSING the verdict bead with a verdict:PASS / verdict:FAIL label.
#   The ga-eqjo async split made Phase C RE-QUERY (rehydrate) the verdict beads
#   from scratch every sweep. Without `--all`, the rehydration returns ZERO the
#   instant any reviewer delivers → Phase C mis-reads a COMPLETED run as "died
#   before Step 7", strands it, and never finalizes. Nothing merges, ever.
#   Live proof: wa-k971r's verdict bead ga-dlzl was closed verdict:PASS at
#   10:38, yet Phase C logged "0/1 verdicts" then "ZERO verdict beads".
#
# Strategy: extract the live "phase-c-verdict-rehydrate" block verbatim and run
# it under real `set -euo pipefail` on the host's actual /bin/bash, with a `bd`
# stub that EMULATES bd's real default-excludes-closed behavior: the stub returns
# the closed verdict bead ONLY when the `list` call includes `--all` (or an
# explicit closed status). Assert the rehydration finds the delivered (closed)
# bead and reaches gate_collect_verdicts with it — i.e. a completed run is seen
# as completed, not as "ZERO verdict beads". A MUTATION check strips `--all` from
# a scratch copy and proves the SAME closed-bead input then vanishes (0 beads →
# the empty-guard's continue), so this suite is not vacuous.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-phase-c-rehydrate-includes-closed.selftest =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi
if [ ! -x "$REAL_BASH" ]; then
  echo "FATAL: $REAL_BASH not found" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_rehydrate <dispatcher-file> <bd_log>
# `bd` stub emulates bd's real filter: `list` returns the CLOSED verdict bead
# ONLY when the args contain `--all` (or `--status closed`); otherwise it returns
# `[]` — exactly as the production `bd list` hides closed beads by default. This
# makes the presence/absence of `--all` in the extracted block the ONLY variable
# under test.
run_rehydrate() {
  local file="$1" bd_log="$2"
  local block
  block="$(extract_block "$file" "phase-c-verdict-rehydrate")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"
  "$REAL_BASH" -c '
    set -euo pipefail
    GC_CITY="/fake/city"; GATE_RUN_ID="test-run-closed"
    BD_LOG="$1"
    CLOSED_VB='"'"'[{"id":"vb-closed-1","status":"closed","labels":["reviewer-index:1","type:quality-gate-verdict","gate-run:test-run-closed","verdict:PASS"]}]'"'"'
    bd() {
      case " $* " in
        *" list "*)
          # Emulate bd default filter: closed beads only visible with --all / --status closed
          case " $* " in
            *" --all "*|*"--status closed"*|*"--status"*"closed"*) echo "$CLOSED_VB"; return 0 ;;
            *) echo "[]"; return 0 ;;   # default hides the closed verdict bead
          esac ;;
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
  ' _ "$bd_log"
  return $?
}

echo "── 1. Live dispatcher: a DELIVERED (closed) verdict bead must be FOUND, not seen as ZERO ──"
BD_LOG_1="$(mktemp)"
OUT_1="$(run_rehydrate "$DISPATCHER" "$BD_LOG_1" 2>&1)"
RC_1=$?
echo "$OUT_1" | sed 's/^/    [closed] /'
if [ "$RC_1" -eq 0 ]; then
  ok "closed verdict bead: block exits 0"
else
  bad "closed verdict bead: block exited $RC_1 — bd_log: $(tr '\n' ';' < "$BD_LOG_1")"
fi
if grep -q "gate_collect_verdicts_called" "$BD_LOG_1"; then
  ok "closed verdict bead: rehydration FOUND it (reached gate_collect_verdicts) — a completed run is seen as completed"
else
  bad "closed verdict bead: gate_collect_verdicts NOT reached — the delivered verdict is invisible (this is the bug)"
fi
if grep -q "^warn:Phase C:.*ZERO verdict beads" "$BD_LOG_1"; then
  bad "closed verdict bead: WRONGLY diagnosed as 'ZERO verdict beads' — the --all fix is missing"
else
  ok "closed verdict bead: NOT mis-diagnosed as 'ZERO verdict beads'"
fi
rm -f "$BD_LOG_1"

echo "── 2. MUTATION TEST: stripping --all must make the SAME closed bead vanish (proves non-vacuous) ──"
MUT="$(mktemp "${TMPDIR:-/tmp}/gate-rehydrate-allmutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-rehydrate-allmutant-$$.sh")"
trap 'rm -f "$MUT"' EXIT
cp "$DISPATCHER" "$MUT"
MUTATE_OK=0
python3 - "$MUT" <<'PYEOF' && MUTATE_OK=1
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
# The exact production rehydration query WITH --all. A later, unrelated fix
# inserted --include-infra right after --all (so infra-type verdict beads
# aren't dropped either) — the anchor tracks that addition too, since this
# mutation test cares only about --all specifically, not about being the
# single byte-for-byte string that has ever existed on this line.
anchor = 'bd -C "$GC_CITY" list --json --all --include-infra -l type:quality-gate-verdict -l "gate-run:$GATE_RUN_ID"'
n = c.count(anchor)
if n != 1:
    print("ANCHOR_NOT_UNIQUE count=%d" % n, file=sys.stderr)
    sys.exit(1)
# Strip --all ONLY to reproduce the pre-fix (broken) query — --include-infra
# stays, since that flag is not what this test is proving.
mutant = 'bd -C "$GC_CITY" list --json --include-infra -l type:quality-gate-verdict -l "gate-run:$GATE_RUN_ID"'
c2 = c.replace(anchor, mutant, 1)
if c2 == c:
    print("SWAP_NO_OP", file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.write(c2)
PYEOF
if [ "$MUTATE_OK" != "1" ]; then
  bad "mutation-test: could not construct the mutant (anchor '--all' query not found exactly once — dispatcher shape changed?) — INCONCLUSIVE, treat as FAIL"
else
  BD_LOG_MUT="$(mktemp)"
  OUT_MUT="$(run_rehydrate "$MUT" "$BD_LOG_MUT" 2>&1)"
  RC_MUT=$?
  echo "$OUT_MUT" | sed 's/^/    [mutant] /'
  if grep -q "^warn:Phase C:.*ZERO verdict beads" "$BD_LOG_MUT" && ! grep -q "gate_collect_verdicts_called" "$BD_LOG_MUT"; then
    ok "mutant (no --all): the SAME closed verdict bead vanishes → 'ZERO verdict beads', gate_collect_verdicts never reached — proves --all is what fixes it"
  else
    bad "mutant (no --all) did NOT reproduce the vanish — test may be vacuous. bd_log: $(tr '\n' ';' < "$BD_LOG_MUT")"
  fi
  rm -f "$BD_LOG_MUT"
fi

echo ""
echo "== gate-phase-c-rehydrate-includes-closed: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
