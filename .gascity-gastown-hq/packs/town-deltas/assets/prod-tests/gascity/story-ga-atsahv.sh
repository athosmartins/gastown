#!/usr/bin/env bash
# prod-tests/gascity/story-ga-atsahv.sh — prod test for ga-atsahv: the quality gate's DOC/TEST fast lane
# ("o gate só é necessário quando a gente vai colocar código novo em produção").
#
# A diff whose EVERY file is documentation or tests, whose added lines carry no CPF/phone/credential and whose
# new tests run green, skips the LLM reviewer and merges through the same gate_finalize_run. PROMPT/doctrine
# text and all code stay in the normal gate; anything unreadable or unverified also stays there.
#
# Verifies the DEPLOYED files, not a copy of the claims: that the files exist and parse under /bin/bash 3.2
# (the interpreter the dispatcher runs under — NOT a bare `bash -n`, which is Homebrew 5.x in PATH and accepts
# what 3.2 rejects; ga-6aj348's first attempt was reverted for exactly that), that launchd really runs the
# dispatcher path being deployed (merged != live), that the weekly order is visible to gc, that the tally can
# read the LIVE log, and then runs both selftests end-to-end against the deployed directory.
#
# Called by run.sh after deploy (STORY_ID=ga-atsahv). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISPATCHER="$ASSETS/quality-gate-dispatcher.sh"
LIB="$ASSETS/gate-fastlane.lib.sh"
SCAN="$ASSETS/gate-fastlane-scan.py"
TALLY="$ASSETS/gate-lane-tally.py"
WEEKLY="$ASSETS/scripts/gate-lane-weekly.sh"
ORDER="$CITY/packs/town-deltas/orders/gate-lane-weekly.toml"
ST_LANE="$ASSETS/gate-fastlane.selftest.sh"
ST_TALLY="$ASSETS/gate-lane-tally.selftest.sh"
PLIST="$HOME/Library/LaunchAgents/com.gascity.quality-gate-dispatcher.plist"
BASH32=/bin/bash

log()  { echo "[prod-test:gascity ga-atsahv] $*"; }
fail() { echo "[prod-test:gascity ga-atsahv] FAIL: $*" >&2; exit 1; }

# ── 0. everything the story ships is on disk ───────────────────────────────────────────────────────────────
for f in "$DISPATCHER" "$LIB" "$SCAN" "$TALLY" "$WEEKLY" "$ORDER" "$ST_LANE" "$ST_TALLY"; do
  [[ -f "$f" ]] || fail "missing: $f"
done
[[ -x "$BASH32" ]] || fail "$BASH32 not executable — cannot run the real-interpreter syntax check"
log "Deployed dispatcher + fast-lane lib/scanner + tally + order + selftests found."

# ── 1. syntax, under the daemon's own interpreter ──────────────────────────────────────────────────────────
log "Checking syntax under $BASH32 ($("$BASH32" --version | head -n1 | sed 's/ (.*//'))..."
"$BASH32" -n "$DISPATCHER" || fail "quality-gate-dispatcher.sh does not parse under $BASH32"
"$BASH32" -n "$LIB"        || fail "gate-fastlane.lib.sh does not parse under $BASH32"
"$BASH32" -n "$WEEKLY"     || fail "gate-lane-weekly.sh does not parse under $BASH32"
python3 -m py_compile "$SCAN" "$TALLY" || fail "scanner/tally do not compile"
log "  syntax OK ✓"

# ── 2. the wiring is in the DEPLOYED dispatcher ────────────────────────────────────────────────────────────
log "Checking the dispatcher wiring..."
for s in fastlane-lib-load fastlane-decide fastlane-bypass; do
  grep -q "SELFTEST-EXTRACT $s: BEGIN" "$DISPATCHER" || fail "dispatcher block '$s' missing"
done
grep -q 'fast_lane_mechanical_checks_no_llm_review' "$DISPATCHER" || fail "a fast-lane PASS would still be recorded as a reviewer quorum"
grep -q 'lane: \$lane' "$DISPATCHER" || fail "dispatcher_complete lost its lane field"
log "  wired ✓"

# ── 3. merged != live: launchd must run THIS dispatcher path ───────────────────────────────────────────────
log "Checking that launchd runs the deployed dispatcher path..."
[[ -f "$PLIST" ]] || fail "launchd plist not installed: $PLIST — the gate would not run at all"
grep -qF "$DISPATCHER" "$PLIST" || fail "the launchd plist does not run $DISPATCHER"
# captured, then matched with case — a `launchctl list | grep -q` under pipefail can false-fail on SIGPIPE
# (the pipefail-grepq ratchet forbids that idiom in production scripts)
LL="$(launchctl list 2>/dev/null || true)"
case "$LL" in *com.gascity.quality-gate-dispatcher*) ;; *) fail "com.gascity.quality-gate-dispatcher is not loaded in launchd" ;; esac
log "  launchd runs the deployed path; each sweep is a fresh process, so the lib is live on the next sweep ✓"

# ── 4. the weekly order is visible to gc ───────────────────────────────────────────────────────────────────
log "Checking that gc sees the weekly order..."
SHOW=$(timeout 90 gc --city "$CITY" order show gate-lane-weekly 2>&1) || fail "gc order show gate-lane-weekly failed: $(printf '%s' "$SHOW" | tail -3)"
case "$SHOW" in *gate-lane-weekly.sh*) ;; *) fail "gc order show gate-lane-weekly does not show the wrapper as its exec" ;; esac
log "  order visible ✓"

# ── 5. the tally can read the LIVE log (exit 2 would mean 'could not read', never '0 saved') ───────────────
log "Checking the tally against the live quality-gate.jsonl (read-only)..."
python3 "$TALLY" --days 7 >/dev/null || fail "gate-lane-tally.py could not read the live log (exit $?)"
log "  tally reads the live log ✓"

# ── 6. the selftests, end to end, against the deployed directory ───────────────────────────────────────────
log "Running gate-fastlane.selftest.sh (classification, scan, real-git decisions, dispatcher blocks, mutation checks)..."
"$BASH32" "$ST_LANE" || fail "gate-fastlane.selftest.sh failed"
log "Running gate-lane-tally.selftest.sh..."
"$BASH32" "$ST_TALLY" || fail "gate-lane-tally.selftest.sh failed"

log "PASS"
exit 0
