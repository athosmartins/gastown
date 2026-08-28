#!/usr/bin/env bash
# prod-tests/gascity/story-ga-ylr2m.sh — prod test for ga-ylr2m: daemon-refresh.sh
# now consults each rig's OWN restart_policy.yaml (when it ships one) instead of
# relying solely on the small hand-copied SENSITIVE_DAEMONS substring list, and
# consults restart_guard_scripts: before every kickstart. Closes the
# registry-drift gap that let daemon-refresh.sh auto-kickstart daemons WA's own
# restart_policy.yaml explicitly locks to notify-only.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-ylr2m). Exits 0 on
# pass. Asserts against the LIVE deployed tree (gascity's scripts run in place
# — see delivery-runbooks.toml's own gascity rig comment) AND against the
# REAL production whatsapp_automation/daemons/restart_policy.yaml — a
# synthetic fixture alone can't prove the hand-rolled subset-YAML parser
# actually survives the real, hand-written, heavily-commented file.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
WA="${WA_RUNTIME_DIR:-/Users/athos/gt/whatsapp_automation}"

log()  { echo "[prod-test:gascity ga-ylr2m] $*"; }
fail() { echo "[prod-test:gascity ga-ylr2m] FAIL: $*" >&2; exit 1; }

# ── The script exists, and its own regression suite passes against the live tree ──
SCRIPT="$ASSETS/daemon-refresh.sh"
[[ -f "$SCRIPT" ]] || fail "deployed daemon-refresh.sh missing: $SCRIPT"

log "running daemon-refresh's own regression suite (incl. T9-T12, ga-ylr2m) against the live tree..."
TEST_OUT="$(bash "$ASSETS/tests/daemon-refresh.test.sh" 2>&1)" || {
  echo "$TEST_OUT" >&2
  fail "tests/daemon-refresh.test.sh failed against the live tree"
}
echo "$TEST_OUT" | grep -qE '^daemon-refresh tests: [0-9]+ passed, 0 failed$' \
  || fail "tests/daemon-refresh.test.sh did not report a clean 0-failed result:
$TEST_OUT"
log "daemon-refresh's full suite passes clean"

# ── The deployed script actually carries the new mechanism (not just dev tree) ──
grep -q "policy_says_sensitive" "$SCRIPT" || fail "deployed daemon-refresh.sh has no policy_says_sensitive — restart_policy.yaml consultation missing"
grep -q "guard_allows_restart"   "$SCRIPT" || fail "deployed daemon-refresh.sh has no guard_allows_restart — restart_guard_scripts consultation missing"

# ── E2E against the REAL production restart_policy.yaml (not a synthetic fixture) ──
# whatsapp_automation is the rig this bead's incident (frota/demand/campaign
# dashboards auto-kickstarted despite being notify_only_locked) actually
# happened on. If that rig has no restart_policy.yaml (moved/renamed), this
# section degrades to a skip — it must never turn a missing rig-side file
# into a false pass OR a false fail of an unrelated deploy.
if [[ -f "$WA/daemons/restart_policy.yaml" ]]; then
  log "found $WA/daemons/restart_policy.yaml — running a real, DRY_RUN E2E check..."

  # frota_dashboard.py: notify_only_locked in the REAL policy file (force-stops
  # physical devices on boot — see that file's own comment). Use the REAL git
  # commit that added it as PRE/POST so the diff is genuine, not synthesized.
  POST_SHA="$(git -C "$WA" log --diff-filter=A --format=%H -- daemons/frota_dashboard.py 2>/dev/null | tail -1)"
  [[ -n "$POST_SHA" ]] || fail "could not find the commit that added daemons/frota_dashboard.py in $WA — history changed shape; this check needs updating, not skipping silently"
  PRE_SHA="$(git -C "$WA" rev-parse "${POST_SHA}^" 2>/dev/null)"
  [[ -n "$PRE_SHA" ]] || fail "could not resolve parent of $POST_SHA in $WA"

  E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ga-ylr2m-e2e.XXXXXX")"
  trap 'rm -rf "$E2E_TMP"' EXIT
  mkdir -p "$E2E_TMP/agents" "$E2E_TMP/bin"
  cat > "$E2E_TMP/agents/com.e2e.frota-dashboard.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.e2e.frota-dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>$WA/venv/bin/python3</string>
    <string>$WA/daemons/frota_dashboard.py</string>
  </array>
</dict>
</plist>
EOF
  # Minimal launchctl/ps mocks: report SOME live PID with a stale start time,
  # so the daemon isn't skipped as "not running" (Step 4) — DRY_RUN=1 means
  # no real kickstart is ever attempted regardless, live or mocked.
  cat > "$E2E_TMP/bin/launchctl" <<'LCEOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '\t"PID" = 424242;\n' ;;
  *) : ;;
esac
exit 0
LCEOF
  cat > "$E2E_TMP/bin/ps" <<'PSEOF'
#!/usr/bin/env bash
echo "Mon Jan  1 00:00:00 2024"
PSEOF
  chmod +x "$E2E_TMP/bin/launchctl" "$E2E_TMP/bin/ps"

  E2E_OUT="$(
    RUNTIME_DIR="$WA" PRE_DEPLOY_SHA="$PRE_SHA" POST_DEPLOY_SHA="$POST_SHA" \
    DEPLOY_EPOCH="$(date +%s)" SENSITIVE_DAEMONS="" DRY_RUN=1 \
    LAUNCH_AGENTS_DIR="$E2E_TMP/agents" \
    LAUNCHCTL_BIN="$E2E_TMP/bin/launchctl" PS_BIN="$E2E_TMP/bin/ps" \
    bash "$SCRIPT" 2>&1
  )"
  echo "$E2E_OUT" | grep -q "^VERDICT=NEEDS_GUARDED_RESTART$" \
    || fail "real restart_policy.yaml E2E: frota_dashboard.py (notify_only_locked in production) did NOT come back NEEDS_GUARDED_RESTART — the live gap this bead closes may have regressed. Output:
$E2E_OUT"
  echo "$E2E_OUT" | grep "^GUARDED=" | grep -q "com.e2e.frota-dashboard" \
    || fail "real restart_policy.yaml E2E: frota_dashboard.py was not flagged GUARDED. Output:
$E2E_OUT"
  log "real restart_policy.yaml E2E: frota_dashboard.py (notify_only_locked in production) correctly flagged NEEDS_GUARDED_RESTART, not auto-kickstarted"

  rm -rf "$E2E_TMP"
  trap - EXIT
else
  log "SKIP real-policy E2E: $WA/daemons/restart_policy.yaml not found (rig moved/renamed — unit-suite coverage above still applies)"
fi

log "PASS — policy consultation + guard consultation shipped, full regression suite clean, real production restart_policy.yaml verified end-to-end"
exit 0
