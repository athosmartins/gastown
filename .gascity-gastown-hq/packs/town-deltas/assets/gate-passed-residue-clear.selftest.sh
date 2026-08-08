#!/usr/bin/env bash
# gate-passed-residue-clear.selftest.sh — regression guard for ga-tuk26.
#
# ga-tuk26 AC3: "a NEW gate:passed write (quality-gate-dispatcher.sh) on a
# bead that previously had gate:failed/gate:needs-fix from an earlier cycle
# clears both going forward."
#
# ROOT CAUSE this guards: gate:failed/gate:needs-fix are only ever ADDED on a
# FAIL cycle (~line 3923/3987), never REMOVED on a later PASS. A bead that
# fails once then passes on retry kept BOTH labels forever — the exact
# contradiction story-delivery.sh's ga-266z8 guard (task_reconciler_verdict,
# see gate-delivery-partial-scope.selftest.sh and
# tests/story-delivery-task-reconciler.test.sh for the reader-side half of
# this fix) then refuses to close. Measured live 6x in one night (Mayor,
# 2026-08-08): wa-6cx36, wa-8ok7u, ga-dnc2m, wa-3xd3w, wa-ze2u1, wa-iochp —
# each manually unstuck by hand before this fix shipped.
#
# quality-gate-dispatcher.sh has 3 gate:passed-setting sites (the PASS path,
# ~line 3545; the already-merged/needs-rebase handoff, ~line 5530; and the
# already-merged STORY handoff, ~line 6365). This file is pure bash + grep —
# it never runs gc/bd, never touches the live city or beads — and follows the
# established structural-assertion convention for this file (see
# gate-source-bead-detach.selftest.sh and gate-delivery-partial-scope.selftest.sh
# §4): a full behavioral block-eval is disproportionate here (each site sits
# inside dozens of dispatcher-wide variables — RIG, BRANCH, MERGE_SHA,
# GATE_RUN_ID, TIER, ... — unlike story-delivery.sh's much smaller, already
# block-eval-tested Step 1b), so this proves the SHAPE of the fix: every
# gate:passed write is immediately followed by both residue-clearing removes,
# drift-guarded so a future edit that adds/removes a site or drops a clear
# call fails this test.
#
# Exit 0 iff every assertion passes.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-passed-residue-clear.selftest (ga-tuk26) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "  ✗ dispatcher not found at $DISPATCHER"
  exit 1
fi

# ── 0. Syntax ────────────────────────────────────────────────────────────────
if bash -n "$DISPATCHER" 2>/tmp/gprc-syntax.$$; then
  ok "quality-gate-dispatcher.sh parses (bash -n)"
else
  bad "quality-gate-dispatcher.sh has a syntax error: $(cat /tmp/gprc-syntax.$$)"
fi
rm -f /tmp/gprc-syntax.$$

# ── 1. Exactly 3 gate:passed write sites (drift-guard) ─────────────────────
# If this count ever changes, a new/removed site needs the SAME residue-clear
# treatment and this test's site list below needs updating in lockstep — a
# silent count drift would mean this test is checking the wrong sites,
# vacuously passing at 0 real coverage on a 4th site.
SITE_COUNT=$(grep -c 'label add "\$BEAD_ID" "gate:passed"' "$DISPATCHER")
if [ "$SITE_COUNT" = "3" ]; then
  ok "exactly 3 gate:passed write sites found (matches ga-tuk26's known site list)"
else
  bad "expected 3 gate:passed write sites, found $SITE_COUNT — site list drifted; update this test's coverage to match"
fi

# ── 2. Every gate:passed write is immediately followed by both residue-clears ─
# For each line number where a gate:passed add fires, the next non-comment-only
# scan window (2 lines) must contain BOTH a gate:failed remove and a
# gate:needs-fix remove on the SAME bead id. Using `label remove "$BEAD_ID"`
# (not a bare grep for the label name) so this cannot be satisfied by an
# unrelated remove call elsewhere in the file.
echo "── site-by-site residue-clear check ──"
SITE_LINES=$(grep -n 'label add "\$BEAD_ID" "gate:passed"' "$DISPATCHER" | cut -d: -f1)
SITE_N=0
for LN in $SITE_LINES; do
  SITE_N=$((SITE_N + 1))
  # Window: the add line itself + the next 15 lines. The primary site (#1)
  # carries the full multi-line rationale comment (~10 lines) that sites #2/#3
  # point back to ("see the PASS-path sibling for full rationale"); 15 is
  # generous enough for that longest comment without reaching past the block
  # into unrelated code (the next real statement after every site's clear
  # pair is its own `bd ... comment ...` call, still well inside the window).
  WINDOW=$(sed -n "${LN},$((LN + 15))p" "$DISPATCHER")
  if printf '%s' "$WINDOW" | grep -q 'label remove "\$BEAD_ID" "gate:failed"'; then
    ok "site #$SITE_N (line $LN): gate:failed cleared alongside gate:passed write"
  else
    bad "site #$SITE_N (line $LN): gate:failed NOT cleared within 15 lines of the gate:passed write"
  fi
  if printf '%s' "$WINDOW" | grep -q 'label remove "\$BEAD_ID" "gate:needs-fix"'; then
    ok "site #$SITE_N (line $LN): gate:needs-fix cleared alongside gate:passed write"
  else
    bad "site #$SITE_N (line $LN): gate:needs-fix NOT cleared within 15 lines of the gate:passed write"
  fi
done

# ── 3. ga-tuk26 marker present at every site (traceability) ────────────────
TAG_COUNT=$(grep -c 'ga-tuk26: clear residue' "$DISPATCHER")
if [ "$TAG_COUNT" = "3" ]; then
  ok "ga-tuk26 traceability comment present at all 3 sites"
else
  bad "expected 3 'ga-tuk26: clear residue' comments, found $TAG_COUNT"
fi

# ── 4. Clears are best-effort (never abort the set -euo pipefail sweep) ────
# Every bd call in this file follows the `... -q 2>/dev/null || true` idiom so
# a missing label (the common case — most beads never failed) cannot kill the
# dispatcher under set -euo pipefail. Spot-check the new calls specifically.
NEW_REMOVE_LINES=$(grep -n 'label remove "\$BEAD_ID" "gate:failed"\|label remove "\$BEAD_ID" "gate:needs-fix"' "$DISPATCHER")
BEST_EFFORT_OK=1
while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  case "$LINE" in
    *'2>/dev/null || true'*) : ;;
    *) BEST_EFFORT_OK=0; bad "residue-clear call not best-effort (missing '2>/dev/null || true'): $LINE" ;;
  esac
done <<EOF
$NEW_REMOVE_LINES
EOF
[ "$BEST_EFFORT_OK" = "1" ] && ok "all residue-clear calls are best-effort (2>/dev/null || true)"

echo ""
echo "gate-passed-residue-clear.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
