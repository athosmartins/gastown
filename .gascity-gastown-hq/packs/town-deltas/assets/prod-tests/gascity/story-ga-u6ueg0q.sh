#!/usr/bin/env bash
# prod-tests/gascity/story-ga-u6ueg0q.sh — prod test for ga-u6ueg0q: the surviving mutants of the
# lastro are closed by selftest cases (or documented as equivalent in each selftest header).
#
# The story changes selftests only, no production code. So the prod test checks that the 16
# selftests it touched are deployed, parse, and that the cheapest of them still runs green
# against the deployed code (a case that was added and then broke the file would show here).
#
# Called by run.sh after deploy (STORY_ID=ga-u6ueg0q). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"

log()  { echo "[prod-test:gascity ga-u6ueg0q] $*"; }
fail() { echo "[prod-test:gascity ga-u6ueg0q] FAIL: $*" >&2; exit 1; }

SELFTESTS=(
  packs/town-deltas/assets/daemon-import-smoke.selftest.sh
  packs/town-deltas/assets/delivery-branch-patterns.selftest.sh
  packs/town-deltas/assets/gate-prompt-skill-check.selftest.sh
  packs/town-deltas/assets/pool-ceiling-effective-cap.selftest.sh
  packs/town-deltas/assets/pool-ceiling.selftest.sh
  scripts/dolt-backup-ephemeral-lib.selftest.sh
  scripts/gate-pytest.selftest.sh
  scripts/hetzner-idle-session-reaper.selftest.sh
  scripts/hetzner-nodejs-guard.selftest.sh
  scripts/hetzner-occupancy-watch.selftest.sh
  scripts/mbp-node-dispatch.selftest.sh
  scripts/ps-node-dispatch.selftest.sh
  scripts/ps-node-route-report.selftest.sh
  scripts/wa-node-report.selftest.sh
  scripts/wa-remote-guards.selftest.sh
  scripts/wa-root-main-guard.selftest.sh
)

# ── 1. Structural: every selftest the story touched is deployed and parses ───────────────────────
for rel in "${SELFTESTS[@]}"; do
  f="$CITY/$rel"
  [[ -f "$f" ]] || fail "deployed selftest missing: $f"
  bash -n "$f" 2>/dev/null || fail "deployed selftest does not parse (bash -n): $f"
done
log "${#SELFTESTS[@]} deployed selftests present and parse ✓"

# ── 2. Behavioral: the quickest selftest runs green against the deployed code ────────────────────
# vazio → no "passed" line is found and the test fails; falhou/ilegível → rc != 0 fails the test
# (never read as a pass)
DBP="$CITY/packs/town-deltas/assets/delivery-branch-patterns.selftest.sh"
out="$(timeout 120 bash "$DBP" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "delivery-branch-patterns.selftest.sh exited $rc: $(printf '%s' "$out" | tail -n 3)"
printf '%s\n' "$out" | grep -Eq 'results: [0-9]+ passed, 0 failed' \
  || fail "delivery-branch-patterns.selftest.sh did not report 'N passed, 0 failed'"
log "delivery-branch-patterns.selftest.sh green against the deployed code ✓"

log "PASS"
exit 0
