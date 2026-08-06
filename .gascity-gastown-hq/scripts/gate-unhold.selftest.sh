#!/usr/bin/env bash
# gate-unhold.selftest.sh — Prove the ga-6qbgy fix in isolation, no live Dolt.
#
# THE BUG: `bd label remove <id> <label>` only removes an EXACT name, but the
# guards that VETO on these labels (quality-gate-guard.sh Step 5a and others)
# match a whole PREFIX FAMILY (gate:needs-human, gate:needs-human:technical,
# gate:needs-human:refused, ...). An operator who removes the bare label and
# re-verifies by exact name sees a clean list and declares the veto cleared,
# while a sibling variant silently keeps vetoing. Real incident: wa-vcd01,
# 2026-08-06 — ~4h of blocked crew work plus a dead marker.
#
# THE FALSIFIABLE TEST THE BUG REPORT ASKS FOR (verbatim from ga-6qbgy's
# ACEITE): "bead com gate:needs-human E gate:needs-human:technical; apos a
# liberacao, a consulta por PREFIXO volta vazia (um teste que so cheque o
# nome exato passa com o bug intacto)." Section 2 below is exactly this test,
# plus a CONTROL (section 3) that proves it discriminates: an exact-name-only
# removal (the pre-fix manual procedure) leaves the sibling variant behind,
# and this harness's own prefix-based verification catches that — where a
# verification that only checked the exact name removed would not.
#
# This harness sources gate-unhold.sh in lib-only mode (GATE_UNHOLD_LIB_ONLY=1)
# with `bd`/`gc` replaced by file-backed mocks (bash 3.2 has no associative
# arrays — same pattern as gate-marker-dedup-by-branch.selftest.sh's
# BD_LABELS_FILE), so it exercises the REAL removal-loop-then-verify logic
# without ever touching production Dolt.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SELF_DIR/gate-unhold.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

[ -f "$TOOL" ] || { echo "FATAL: $TOOL not found"; exit 1; }

# ── Load the pure functions from the tool (no live bead) ─────────────────────
GATE_UNHOLD_LIB_ONLY=1 source "$TOOL" \
  || { echo "FATAL: could not source gate-unhold.sh in lib-only mode"; exit 1; }

type matching_veto_labels >/dev/null 2>&1 \
  || { echo "FATAL: matching_veto_labels not defined (lib-only sourcing broken?)"; exit 1; }
type gate_unhold_main >/dev/null 2>&1 \
  || { echo "FATAL: gate_unhold_main not defined (lib-only sourcing broken?)"; exit 1; }

# ── 1. matching_veto_labels — same matching-rule unit coverage as the guard's ─
#      copy (kept in sync by inspection; this drift-guards THIS file's copy).
echo "── 1. matching_veto_labels: bare-or-colon-suffixed prefix match ──"
eq "bare + sibling variant both present -> echoes BOTH" \
  "$(matching_veto_labels 'gate:needs-human gate:needs-human:technical lane:small' 'gate:needs-human')" \
  "gate:needs-human gate:needs-human:technical"
eq "no match -> empty" \
  "$(matching_veto_labels 'gate:needs-fix lane:small' 'gate:needs-human')" \
  ""
eq "does not false-match a mere substring" \
  "$(matching_veto_labels 'gate:needs-human-ish' 'gate:needs-human')" \
  ""

# ── Mock bd/gc: file-backed label state, no live Dolt ─────────────────────────
# gc always "fails" so fetch_labels exercises its real fallback to `bd -C`
# (the same fallback order quality-gate-guard.sh's BEAD_RAW lookup uses).
gc() { return 1; }

BD_LABELS_FILE="$(mktemp)"
BD_REMOVE_LOG="$(mktemp)"
BD_REMOVE_IS_NOOP=0   # when 1, `bd label remove` reports success but does NOT mutate state

seed_labels() {
  : > "$BD_LABELS_FILE"
  local lbl
  for lbl in "$@"; do echo "$lbl" >> "$BD_LABELS_FILE"; done
}

labels_now() { paste -sd' ' "$BD_LABELS_FILE" 2>/dev/null || true; }

current_labels_json() {
  jq -R -s -c 'split("\n") | map(select(length > 0))' < "$BD_LABELS_FILE"
}

bd() {
  local -a A=("$@")
  local n=${#A[@]} i verb=""
  for ((i = 0; i < n; i++)); do
    case "${A[i]}" in
      show|label) [ -z "$verb" ] && verb="${A[i]}" ;;
    esac
  done
  case "$verb" in
    show)
      printf '{"labels": %s}\n' "$(current_labels_json)"
      ;;
    label)
      for ((i = 0; i < n; i++)); do
        if [ "${A[i]}" = "remove" ]; then
          local id="${A[i+1]}" lbl="${A[i+2]}"
          echo "$id $lbl" >> "$BD_REMOVE_LOG"
          if [ "$BD_REMOVE_IS_NOOP" = "1" ]; then
            return 0   # reports success but leaves BD_LABELS_FILE untouched
          fi
          grep -vxF "$lbl" "$BD_LABELS_FILE" > "$BD_LABELS_FILE.tmp" 2>/dev/null || true
          mv "$BD_LABELS_FILE.tmp" "$BD_LABELS_FILE"
          break
        fi
      done
      ;;
  esac
  return 0
}

# ── 2. THE test the bug report asks for: bare + :technical -> prefix query empty ─
echo "── 2. AC1/AC2: bead with gate:needs-human AND gate:needs-human:technical ──"
seed_labels "lane:small" "gate:needs-human" "gate:needs-human:technical" "story:approved"
: > "$BD_REMOVE_LOG"
BD_REMOVE_IS_NOOP=0

RC=0
gate_unhold_main "wa-test" "gate:needs-human" || RC=$?
eq "gate_unhold_main exits 0 (cleared+verified)" "$RC" "0"

eq "BOTH the bare label and the :technical sibling were removed" \
  "$(grep -c . "$BD_REMOVE_LOG")" \
  "2"

REMAINING_MATCH=$(matching_veto_labels "$(labels_now)" "gate:needs-human")
eq "a PREFIX query afterward returns EMPTY (the exact AC1 acceptance check)" \
  "$REMAINING_MATCH" \
  ""

eq "unrelated labels (lane:small, story:approved) are left untouched" \
  "$(labels_now)" \
  "lane:small story:approved"

# ── 3. CONTROL — exact-name-only removal (the pre-fix manual procedure) ──────
#      leaves the sibling variant behind. This proves the test in section 2
#      is falsifiable: it fails if run against the OLD behavior.
echo "── 3. CONTROL: exact-name-only removal reproduces the original incident ──"
seed_labels "gate:needs-human" "gate:needs-human:technical"
: > "$BD_REMOVE_LOG"
BD_REMOVE_IS_NOOP=0
bd -C x label remove "wa-test" "gate:needs-human" -q   # the pre-fix manual step: remove ONLY the bare name
EXACT_NAME_VERIFY=$(labels_now | grep -c '^gate:needs-human$' || true)
PREFIX_VERIFY=$(matching_veto_labels "$(labels_now)" "gate:needs-human")
if [ "$EXACT_NAME_VERIFY" = "0" ] && [ -n "$PREFIX_VERIFY" ]; then
  ok "control: exact-name check says 'clear' while prefix check still sees $PREFIX_VERIFY (the false-positive this bug report describes)"
else
  bad "control: could not reproduce the exact-name-vs-prefix divergence — test may no longer discriminate"
fi

# ── 4. Silent-failure detection: `bd label remove` ACKs but doesn't mutate ───
#      state (e.g. a Dolt hiccup that returns success without committing).
#      gate_unhold_main must catch this via its post-remove verify, not trust
#      the exit code alone (ga-6qbgy's own sibling doctrine: verify the
#      effect, not the return).
echo "── 4. verify-after-remove catches a silently-failed bd label remove ──"
seed_labels "gate:needs-human" "gate:needs-human:technical"
: > "$BD_REMOVE_LOG"
BD_REMOVE_IS_NOOP=1
RC=0
gate_unhold_main "wa-test" "gate:needs-human" >/tmp/gate-unhold-selftest-out.$$ 2>&1 || RC=$?
eq "gate_unhold_main exits non-zero when a matching label survives verification" \
  "$([ "$RC" != "0" ] && echo nonzero || echo zero)" \
  "nonzero"
grep -qi "FAILED" /tmp/gate-unhold-selftest-out.$$ \
  && ok "failure output names the survival explicitly" \
  || bad "failure output does not explain what survived"
rm -f /tmp/gate-unhold-selftest-out.$$
BD_REMOVE_IS_NOOP=0

# ── 5. No match -> no-op, exit 0, no remove calls issued ─────────────────────
echo "── 5. no matching label -> no-op ──"
seed_labels "lane:small" "story:approved"
: > "$BD_REMOVE_LOG"
RC=0
gate_unhold_main "wa-test" "gate:needs-human" || RC=$?
eq "exits 0 when nothing matches" "$RC" "0"
eq "issues zero remove calls when nothing matches" "$(grep -c . "$BD_REMOVE_LOG" || true)" "0"

# ── 6. Multiple prefixes cleared in ONE call (real incident used 4 families) ─
echo "── 6. multiple veto families cleared in a single invocation ──"
seed_labels "gate:needs-human" "gate:needs-human:technical" "pilot:no-auto-dispatch" "lane:small"
: > "$BD_REMOVE_LOG"
RC=0
gate_unhold_main "wa-test" "gate:needs-human" "pilot:no-auto-dispatch" || RC=$?
eq "exits 0" "$RC" "0"
eq "all 3 veto labels removed, lane:small untouched" "$(labels_now)" "lane:small"

rm -f "$BD_LABELS_FILE" "$BD_LABELS_FILE.tmp" "$BD_REMOVE_LOG"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
