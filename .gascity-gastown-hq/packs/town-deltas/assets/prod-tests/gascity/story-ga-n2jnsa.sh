#!/usr/bin/env bash
# prod-tests/gascity/story-ga-n2jnsa.sh — prod test for ga-n2jnsa: a daemon
# recorded "stuck" in <rig>.perdaemon (ga-7polxu) no longer silently drops out
# of AFFECTED/GUARDED the moment the rig-wide baseline marker advances past
# its trigger commit (ga-49fwiw's unattributed-release path). daemon-refresh.sh
# now (1) widens AFFECTED back to include any still-"stuck" per-daemon entry
# the wide window no longer covers, and (2) gives already_fresh() a per-daemon
# commit floor (the most recent commit that actually touches THAT daemon's own
# closure) instead of comparing against the tip of whatever window happens to
# be under examination this cycle — so a manual restart performed after the
# real trigger commit correctly clears the daemon within one sweep, even if an
# unrelated later commit has since landed.
#
# Called by run.sh after deploy (STORY_ID=ga-n2jnsa). Exits 0 on pass. Asserts
# against the LIVE deployed tree (gascity's scripts run in place — see
# delivery-runbooks.toml's own gascity rig comment).
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
SCRIPT="$ASSETS/daemon-refresh.sh"

log()  { echo "[prod-test:gascity ga-n2jnsa] $*"; }
fail() { echo "[prod-test:gascity ga-n2jnsa] FAIL: $*" >&2; exit 1; }

# ── The deployed script exists ──────────────────────────────────────────────
[[ -f "$SCRIPT" ]] || fail "deployed daemon-refresh.sh missing: $SCRIPT"

# ── The deployed script actually carries the new mechanism (not just the dev
#    tree) — these symbols do not exist anywhere pre-ga-n2jnsa. ────────────
grep -q "ga0fawwr_daemon_closure_epoch" "$SCRIPT" \
  || fail "deployed daemon-refresh.sh has no ga0fawwr_daemon_closure_epoch — per-daemon freshness floor missing"
grep -q "ga0fawwr_freshness_base_sha" "$SCRIPT" \
  || fail "deployed daemon-refresh.sh has no ga0fawwr_freshness_base_sha — per-daemon freshness floor missing"
grep -q 'awk .\$3=="stuck"' "$SCRIPT" \
  || fail "deployed daemon-refresh.sh does not read the .perdaemon 'stuck' flag — AFFECTED widening missing"
log "deployed script carries the per-daemon freshness floor + AFFECTED widening mechanism"

# ── The full regression suite (incl. T84/T85, ga-n2jnsa) passes against the
#    live deployed tree — this transitively re-verifies the exact repro from
#    the story's own acceptance criteria on every future deploy too. ───────
log "running daemon-refresh's own regression suite (incl. T84/T85, ga-n2jnsa) against the live tree..."
TEST_OUT="$(bash "$ASSETS/tests/daemon-refresh.test.sh" 2>&1)" || {
  echo "$TEST_OUT" >&2
  fail "tests/daemon-refresh.test.sh failed against the live tree"
}
echo "$TEST_OUT" | grep -E '^daemon-refresh tests: [0-9]+ passed, 0 failed$' >/dev/null \
  || fail "tests/daemon-refresh.test.sh did not report a clean 0-failed result:
$TEST_OUT"
echo "$TEST_OUT" | grep -q "^  ok   - T84 " || fail "T84 (the ga-n2jnsa repro) did not run — test suite drifted"
echo "$TEST_OUT" | grep -q "^  ok   - T85 " || fail "T85 (the ga-n2jnsa restart-clears-in-one-sweep control) did not run — test suite drifted"
log "daemon-refresh's full suite passes clean, T84/T85 present and green"

log "PASS — .perdaemon 'stuck' entries widen AFFECTED back, already_fresh() uses a per-daemon commit floor, full regression suite clean"
exit 0
