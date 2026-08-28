#!/usr/bin/env bash
# daemon-refresh.test.sh — unit tests for daemon-refresh.sh (ga-iwv0).
#
# Proves the post-deploy daemon-refresh helper:
#   1. Does nothing when no daemon code changed (no false restarts).
#   2. Auto-restarts an affected SAFE dashboard and verifies it came up
#      fresh (process start AFTER the deploy timestamp) → VERDICT=OK.
#   3. HALTS (VERDICT=VERIFY_FAILED, non-zero exit) when a restarted daemon
#      is still running stale (start time BEFORE deploy) — the dormant-deploy
#      case the bug is about; story:done must be impossible here.
#   4. Never auto-bounces a SENSITIVE hot-path daemon: it is flagged for a
#      guarded restart → VERDICT=NEEDS_GUARDED_RESTART, non-zero exit.
#   5. Resolves import-level changes: a changed routes/*.py module marks the
#      dashboard that imports it as affected (the exact ga-d81 scenario).
#   6. Resolves template-only changes: a changed *.html a dashboard renders via
#      render_template(...) marks it affected even with zero *.py changes (the
#      ga-jkj0 scenario — Jinja templates are cached in-process). An unrelated
#      template change (not referenced by any daemon) stays OK, no restart.
#   7. (ga-vmq1i) Emits a PROOF=verified|not_applicable|not_verified field
#      distinguishing a POSITIVE restart+fresh confirmation from a VERDICT=OK/
#      SKIPPED that never actually confirmed anything live is running the new
#      code — the caller (story-delivery.sh) must never say "verified in prod"
#      on anything but PROOF=verified.
#
# All external effects (launchctl, ps) are injected via LAUNCHCTL_BIN / PS_BIN
# and a mock state dir, so the test touches NO real daemons. The plist scan and
# the lstart→epoch date parse run for real.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ── assertion helpers ─────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# field <name> <stdout>  →  echoes the value of "name=..." line from helper output
field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

# ── fixture builders ──────────────────────────────────────────────────────────
# epoch→lstart string in the exact format `ps -o lstart=` emits on macOS.
lstart_of() { date -r "$1" "+%a %b %e %T %Y"; }

make_plist() {  # make_plist <dir> <label> <prog-arg> [<prog-arg>...]
  local dir="$1" label="$2"; shift 2
  local args="" a
  for a in "$@"; do args="$args      <string>$a</string>
"; done
  cat > "$dir/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
</dict>
</plist>
EOF
}

# build a fresh mock environment for one case; sets globals:
#   RUNTIME, AGENTS, MOCK, BIN, PRE, POST, DEPLOY_EPOCH
new_case() {
  local name="$1"
  CASE_DIR="$TMP_ROOT/$name"
  RUNTIME="$CASE_DIR/runtime"
  AGENTS="$CASE_DIR/agents"
  MOCK="$CASE_DIR/mock"
  BIN="$CASE_DIR/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$MOCK" "$BIN"

  # a git work tree representing the deployed rig
  git -C "$RUNTIME" init -q
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/daemons" "$RUNTIME/routes" "$RUNTIME/launchd"

  # mock launchctl: `list <label>` prints the current PID; `kickstart ... label`
  # logs the call and, if a post-restart pid/lstart is seeded, swaps them in.
  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    [ -n "$label" ] && [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
    ;;
  kickstart)
    last=""; for a in "$@"; do last="$a"; done
    label="${last##*/}"
    echo "$label" >> "$S/kicks.log"
    if [ -f "$S/restart_pid.$label" ]; then
      np="$(cat "$S/restart_pid.$label")"
      echo "$np" > "$S/pid.$label"
      [ -f "$S/restart_lstart.$label" ] && cat "$S/restart_lstart.$label" > "$S/start.$np"
    fi
    ;;
esac
exit 0
LCEOF
  chmod +x "$BIN/launchctl"

  # mock ps: emulate `ps -o lstart= -p <pid>`
  cat > "$BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -n "$pid" ] && [ -f "$S/start.$pid" ] && cat "$S/start.$pid"
exit 0
PSEOF
  chmod +x "$BIN/ps"

  DEPLOY_EPOCH=$(( $(date +%s) - 600 ))   # deploy happened 10 min ago
  STALE_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 3600 )) )"   # before deploy
  FRESH_LSTART="$(lstart_of $(( DEPLOY_EPOCH + 60 )) )"     # after deploy
}

# seed a daemon that is currently running a STALE process (pre-deploy start)
seed_running() {  # seed_running <label> <pid> <lstart>
  echo "$2" > "$MOCK/pid.$1"
  echo "$3" > "$MOCK/start.$2"
}
# seed what a kickstart of <label> will produce
seed_restart() {  # seed_restart <label> <newpid> <lstart>
  echo "$2" > "$MOCK/restart_pid.$1"
  echo "$3" > "$MOCK/restart_lstart.$1"
}

run_helper() {  # run_helper <changed-relpaths...>  (commits a deploy diff first)
  # PRE = current HEAD; mutate the listed files; POST = new HEAD.
  ( cd "$RUNTIME"
    git add -A >/dev/null 2>&1
    git commit -q -m base --allow-empty
  )
  PRE=$(git -C "$RUNTIME" rev-parse HEAD)
  local f
  for f in "$@"; do
    mkdir -p "$RUNTIME/$(dirname "$f")"
    echo "# changed $(date +%s%N)" >> "$RUNTIME/$f"
  done
  ( cd "$RUNTIME"
    git add -A >/dev/null 2>&1
    git commit -q -m deploy --allow-empty
  )
  POST=$(git -C "$RUNTIME" rev-parse HEAD)

  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" \
  SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 \
  bash "$HELPER" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# T1: no daemon code changed → OK, nothing restarted
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="central-sender conversation-monitor slot-scheduler webhook"
new_case t1
# a daemon exists, but the deploy only touched a README
cat > "$RUNTIME/daemons/foo_dashboard.py" <<<'print("foo")'
make_plist "$AGENTS" com.test.foo-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/foo_dashboard.py"
seed_running com.test.foo-dashboard 1001 "$STALE_LSTART"
OUT=$(run_helper README.md); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T1 verdict OK on no daemon change" || nok "T1 verdict" "got '$V' rc=$RC out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T1 exit 0" || nok "T1 exit" "rc=$RC"
[ ! -f "$MOCK/kicks.log" ] && ok "T1 no kickstart called" || nok "T1 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
# ga-vmq1i: nothing daemon-relevant changed — a structurally-certain non-issue,
# not a positive verification. Must NOT claim "verified".
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T1 PROOF=not_applicable (nothing daemon-relevant changed)" || nok "T1 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T2: affected SAFE dashboard → restarted + fresh → OK
# ════════════════════════════════════════════════════════════════════════════
new_case t2
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 2001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 2099 "$FRESH_LSTART"
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T2 verdict OK" || nok "T2 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T2 exit 0" || nok "T2 exit" "rc=$RC"
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.ban-risk-dashboard" && ok "T2 dashboard affected" || nok "T2 affected" "$(field AFFECTED "$OUT")"
echo "$(field RESTARTED "$OUT")" | grep -q "com.test.ban-risk-dashboard" && ok "T2 dashboard restarted" || nok "T2 restarted" "$(field RESTARTED "$OUT")"
grep -q "com.test.ban-risk-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T2 kickstart invoked" || nok "T2 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
# ga-vmq1i: a live daemon was actually restarted AND confirmed fresh — the one
# case that earns the word "verified".
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T2 PROOF=verified (real restart+fresh confirmed)" || nok "T2 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T3: affected SAFE dashboard, but stays stale after restart → VERIFY_FAILED
# ════════════════════════════════════════════════════════════════════════════
new_case t3
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 3001 "$STALE_LSTART"
# no seed_restart → kickstart does not refresh the process; still stale start
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "VERIFY_FAILED" ] && ok "T3 verdict VERIFY_FAILED" || nok "T3 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T3 non-zero exit (halts delivery)" || nok "T3 exit" "rc=$RC (must be non-zero)"
echo "$(field FRESH_FAIL "$OUT")" | grep -q "com.test.ban-risk-dashboard" && ok "T3 dashboard in FRESH_FAIL" || nok "T3 fresh_fail" "$(field FRESH_FAIL "$OUT")"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T3 PROOF=not_verified" || nok "T3 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T4: affected SENSITIVE hot-path daemon → flagged, NOT bounced → NEEDS_GUARDED_RESTART
# ════════════════════════════════════════════════════════════════════════════
new_case t4
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
# wrapper-style plist: program runs a wrapper .sh that execs the .py
cat > "$RUNTIME/launchd/central-sender-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/central_sender.py"
EOF
make_plist "$AGENTS" com.test.central-sender /bin/bash "$RUNTIME/launchd/central-sender-wrapper.sh"
seed_running com.test.central-sender 4001 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T4 verdict NEEDS_GUARDED_RESTART" || nok "T4 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T4 non-zero exit (halts delivery)" || nok "T4 exit" "rc=$RC (must be non-zero)"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.central-sender" && ok "T4 sensitive daemon flagged GUARDED" || nok "T4 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T4 sensitive daemon NOT auto-bounced" || nok "T4 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T4 PROOF=not_verified" || nok "T4 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T5: import-level — changed routes/*.py marks the dashboard that imports it
# ════════════════════════════════════════════════════════════════════════════
new_case t5
cat > "$RUNTIME/routes/channel_admin_api.py" <<<'def register(app): pass'
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<'PYEOF'
from routes.channel_admin_api import register
register(None)
PYEOF
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 5001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 5099 "$FRESH_LSTART"
# deploy changed ONLY the route file, not the dashboard entrypoint
OUT=$(run_helper routes/channel_admin_api.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.ban-risk-dashboard" && ok "T5 importing dashboard marked affected" || nok "T5 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T5 verdict OK after fresh restart" || nok "T5 verdict" "got '$V' out=[$OUT]"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T5 PROOF=verified" || nok "T5 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T6: affected daemon is NOT currently running (no PID — e.g. a scheduled job) →
#     do not kickstart it (would wrongly TRIGGER a one-shot job); verdict OK.
# ════════════════════════════════════════════════════════════════════════════
new_case t6
cat > "$RUNTIME/daemons/daily_scraper.py" <<<'print("scrape")'
make_plist "$AGENTS" com.test.daily-scraper "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/daily_scraper.py"
# deliberately DO NOT seed_running → daemon has no live PID
OUT=$(run_helper daemons/daily_scraper.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T6 verdict OK (not-running affected daemon is skipped)" || nok "T6 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T6 exit 0" || nok "T6 exit" "rc=$RC"
[ ! -f "$MOCK/kicks.log" ] && ok "T6 scheduled/down job NOT kickstarted" || nok "T6 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
echo "$(field RESTARTED "$OUT")" | grep -q "daily-scraper" && nok "T6 should not restart" "restarted=$(field RESTARTED "$OUT")" || ok "T6 not in RESTARTED"
# ga-vmq1i (THE BUG THIS FIX IS ABOUT): AFFECTED is non-empty here but RESTARTED
# is empty (the daemon was never running to restart). Before this fix, the
# fall-through branch unconditionally emitted "all affected daemons restarted
# + verified fresh:" with a literally EMPTY restarted list — VERDICT=OK with
# zero daemons actually confirmed fresh, which is exactly the false-positive
# "verified in prod" claim ga-vmq1i reports. Must be not_applicable (nothing
# LIVE to verify), never "verified".
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T6 PROOF=not_applicable (affected daemon not live — nothing to verify, must NOT claim verified)" || nok "T6 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T7: template-only change — a changed *.html a dashboard renders via
#     render_template(...) marks it affected with ZERO *.py changes (ga-jkj0:
#     com.whatsapp.map-viewer served a stale layout — Jinja compiles+caches
#     templates in-process, so a disk-only edit was invisible pre-fix).
# ════════════════════════════════════════════════════════════════════════════
new_case t7
cat > "$RUNTIME/daemons/map_viewer_dashboard.py" <<'PYEOF'
from flask import render_template
def index():
    return render_template("map_viewer.html")
PYEOF
mkdir -p "$RUNTIME/templates"
cat > "$RUNTIME/templates/map_viewer.html" <<<'<html>old</html>'
make_plist "$AGENTS" com.test.map-viewer "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/map_viewer_dashboard.py"
seed_running com.test.map-viewer 6001 "$STALE_LSTART"
seed_restart com.test.map-viewer 6099 "$FRESH_LSTART"
# deploy changed ONLY the template, not the .py entrypoint
OUT=$(run_helper templates/map_viewer.html); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.map-viewer" && ok "T7 template-rendering dashboard marked affected" || nok "T7 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T7 verdict OK after fresh restart" || nok "T7 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.map-viewer" "$MOCK/kicks.log" 2>/dev/null && ok "T7 kickstart invoked" || nok "T7 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T7 PROOF=verified" || nok "T7 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T8: unrelated template change — a changed *.html NOT referenced by any
#     daemon's render_template(...) call must NOT trigger a restart (precision
#     / no-cascade: template matching must not over-fire on every template
#     edit in the runtime tree).
# ════════════════════════════════════════════════════════════════════════════
new_case t8
cat > "$RUNTIME/daemons/map_viewer_dashboard.py" <<'PYEOF'
from flask import render_template
def index():
    return render_template("map_viewer.html")
PYEOF
mkdir -p "$RUNTIME/templates"
cat > "$RUNTIME/templates/map_viewer.html" <<<'<html>old</html>'
cat > "$RUNTIME/templates/unrelated.html" <<<'<html>other</html>'
make_plist "$AGENTS" com.test.map-viewer "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/map_viewer_dashboard.py"
seed_running com.test.map-viewer 7001 "$STALE_LSTART"
# deploy changes a template nobody renders
OUT=$(run_helper templates/unrelated.html); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T8 verdict OK on unrelated template change" || nok "T8 verdict" "got '$V' out=[$OUT]"
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.map-viewer" && nok "T8 should not be affected" "$(field AFFECTED "$OUT")" || ok "T8 map-viewer not marked affected"
[ ! -f "$MOCK/kicks.log" ] && ok "T8 no kickstart called (no cascade)" || nok "T8 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
# ga-vmq1i: a template DID change (CHANGED_TEMPLATES non-empty) but detection
# tied it to no live daemon. Unlike T1 (structurally certain nothing relevant
# changed), this is the single-hop-detection blind spot the script's own
# comments acknowledge (render_template only checked one hop deep) — we
# cannot be CONFIDENT this is a true negative, so it must read as
# not_verified, not a confident not_applicable/verified.
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T8 PROOF=not_verified (py/template changed but tied to no live daemon — can't confidently call it N/A)" || nok "T8 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T9 (ga-ylr2m): a daemon whose .py is NOT in restart_policy.yaml's 'auto'/
# 'deploy_restart' (simply unlisted here) is treated SENSITIVE by the POLICY
# alone — even though its launchd label matches NO SENSITIVE_DAEMONS
# substring. This is the exact registry-drift gap ga-ylr2m closes:
# daemon-refresh.sh used to auto-kickstart anything not in the small
# hand-copied SENSITIVE_DAEMONS list, bypassing WA's own stricter
# "unlisted = manual" default (the real incident: frota_dashboard/
# demand_dashboard/campaign_dashboard auto-kickstarted despite being
# notify_only_locked/vetoed in restart_policy.yaml).
# ════════════════════════════════════════════════════════════════════════════
new_case t9
cat > "$RUNTIME/daemons/frota_dashboard.py" <<<'print("frota")'
make_plist "$AGENTS" com.test.frota-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/frota_dashboard.py"
seed_running com.test.frota-dashboard 8001 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - chip_kpi_dashboard.py
deploy_restart:
  - central_sender.py
notify_only_locked:
  - frota_dashboard.py
EOF
OUT=$(run_helper daemons/frota_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T9 verdict NEEDS_GUARDED_RESTART (policy-sensitive, no SENSITIVE_DAEMONS match)" || nok "T9 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T9 non-zero exit (halts delivery)" || nok "T9 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.frota-dashboard" && ok "T9 flagged GUARDED by restart_policy.yaml alone" || nok "T9 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.frota-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T9 NOT auto-bounced" || nok "T9 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T10 (ga-ylr2m): a daemon EXPLICITLY listed in restart_policy.yaml's 'auto'
# still auto-restarts normally — the policy consultation only ADDS scrutiny
# for unlisted daemons, never blocks one the policy explicitly clears (no
# regression for the already-reviewed-safe majority).
# ════════════════════════════════════════════════════════════════════════════
new_case t10
cat > "$RUNTIME/daemons/chip_kpi_dashboard.py" <<<'print("kpi")'
make_plist "$AGENTS" com.test.chip-kpi "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/chip_kpi_dashboard.py"
seed_running com.test.chip-kpi 8101 "$STALE_LSTART"
seed_restart com.test.chip-kpi 8199 "$FRESH_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - chip_kpi_dashboard.py
notify_only_locked:
  - frota_dashboard.py
EOF
OUT=$(run_helper daemons/chip_kpi_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T10 verdict OK (policy-cleared daemon still auto-restarts)" || nok "T10 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T10 exit 0" || nok "T10 exit" "rc=$RC"
grep -q "com.test.chip-kpi" "$MOCK/kicks.log" 2>/dev/null && ok "T10 kickstart invoked" || nok "T10 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T10 PROOF=verified" || nok "T10 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T11 (ga-ylr2m): a daemon in 'auto' (policy-cleared, and NOT matching
# SENSITIVE_DAEMONS either) but with a restart_guard_scripts: entry whose
# guard script exits 1 (something in flight) — the guard BLOCKS the
# auto-kickstart. Closes the classification_dashboard send-in-flight gap:
# daemon-refresh.sh was a previously-unguarded 4th restart trigger alongside
# WA's own three.
# ════════════════════════════════════════════════════════════════════════════
new_case t11
cat > "$RUNTIME/daemons/classification_dashboard.py" <<<'print("cls")'
make_plist "$AGENTS" com.test.classification-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/classification_dashboard.py"
seed_running com.test.classification-dashboard 8201 "$STALE_LSTART"
mkdir -p "$RUNTIME/scripts"
cat > "$RUNTIME/scripts/cls_guard.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("1 send in flight", file=sys.stderr)
sys.exit(1)
EOF
chmod +x "$RUNTIME/scripts/cls_guard.py"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - classification_dashboard.py
restart_guard_scripts:
  classification_dashboard.py: scripts/cls_guard.py
EOF
OUT=$(run_helper daemons/classification_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T11 verdict NEEDS_GUARDED_RESTART (guard refused)" || nok "T11 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T11 non-zero exit (halts delivery)" || nok "T11 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.classification-dashboard" && ok "T11 flagged GUARDED by guard script refusal" || nok "T11 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.classification-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T11 NOT auto-bounced (guard blocked kickstart)" || nok "T11 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T12 (ga-ylr2m): same daemon+guard as T11, but the guard script exits 0
# (nothing in flight) — kickstart proceeds normally.
# ════════════════════════════════════════════════════════════════════════════
new_case t12
cat > "$RUNTIME/daemons/classification_dashboard.py" <<<'print("cls")'
make_plist "$AGENTS" com.test.classification-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/classification_dashboard.py"
seed_running com.test.classification-dashboard 8301 "$STALE_LSTART"
seed_restart com.test.classification-dashboard 8399 "$FRESH_LSTART"
mkdir -p "$RUNTIME/scripts"
cat > "$RUNTIME/scripts/cls_guard.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("nothing in flight", file=sys.stderr)
sys.exit(0)
EOF
chmod +x "$RUNTIME/scripts/cls_guard.py"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - classification_dashboard.py
restart_guard_scripts:
  classification_dashboard.py: scripts/cls_guard.py
EOF
OUT=$(run_helper daemons/classification_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T12 verdict OK (guard allowed)" || nok "T12 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T12 exit 0" || nok "T12 exit" "rc=$RC"
grep -q "com.test.classification-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T12 kickstart invoked (guard allowed)" || nok "T12 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T12 PROOF=verified" || nok "T12 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T13 (ga-ylr2m, self-audit finding): restart_policy.yaml EXISTS but fails to
# parse (invalid UTF-8 — a stand-in for "this rig's file broke the subset
# parser's assumptions"). This is a DIFFERENT state from "no policy file" and
# must NOT collapse to the same value: since we cannot verify what the file
# says, the daemon must be treated as sensitive (not silently safe) — the
# exact third-state defect class the mandatory pre-gate self-audit exists to
# catch. Locks in policy_says_sensitive()'s documented parse-failure contract
# directly. NOTE, verified by hand: for THIS specific daemon shape (no
# SENSITIVE_DAEMONS match, no DRAIN_CMD), the pre-fix code reaches the same
# NEEDS_GUARDED_RESTART verdict BY COINCIDENCE — an unparsed file silently
# left POLICY_AUTO/POLICY_DEPLOY_RESTART empty, and an empty allowlist never
# contains any daemon either way, sensitive-by-omission regardless of WHY it's
# empty. This test does not by itself prove the fix (it passes before and
# after); it pins the intended behavior against a future regression. T14
# below isolates the one path (guard_allows_restart, reached via
# SENSITIVE_DAEMONS + DRAIN_CMD, bypassing policy_says_sensitive entirely)
# where the pre-fix silent-empty behavior was a real, provable gap.
# ════════════════════════════════════════════════════════════════════════════
new_case t13
cat > "$RUNTIME/daemons/unremarkable_dashboard.py" <<<'print("plain")'
make_plist "$AGENTS" com.test.unremarkable "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/unremarkable_dashboard.py"
seed_running com.test.unremarkable 8401 "$STALE_LSTART"
printf '\xff\xfeauto:\n  - unremarkable_dashboard.py\n' > "$RUNTIME/daemons/restart_policy.yaml"
OUT=$(run_helper daemons/unremarkable_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T13 verdict NEEDS_GUARDED_RESTART (unparseable policy fails closed)" || nok "T13 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T13 non-zero exit (halts delivery)" || nok "T13 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.unremarkable" && ok "T13 flagged GUARDED despite being in the (unreadable) 'auto' list" || nok "T13 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.unremarkable" "$MOCK/kicks.log" 2>/dev/null && ok "T13 NOT auto-bounced" || nok "T13 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T14 (ga-ylr2m, self-audit finding — the one path T13 alone does not reach):
# a SENSITIVE_DAEMONS-matched daemon WITH a configured DRAIN_CMD, on a rig
# whose restart_policy.yaml exists but fails to parse. is_sensitive() already
# routes this into the SENSITIVE+DRAIN branch regardless of what the policy
# file says, so policy_says_sensitive()'s own fail-closed behavior is never
# even consulted here — this isolates guard_allows_restart()'s OWN fail-closed
# check. Pre-fix, an unparseable file silently produced an empty POLICY_GUARDS
# — indistinguishable from "no guard configured" — so the drain+kickstart
# would proceed even though the (unreadable) file might have named a guard
# that would have refused it.
# ════════════════════════════════════════════════════════════════════════════
new_case t14
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 8501 "$STALE_LSTART"
printf '\xff\xfeauto:\n  - central_sender.py\n' > "$RUNTIME/daemons/restart_policy.yaml"
export DRAIN_CMD_com_test_central_sender="true"
OUT=$(run_helper daemons/central_sender.py); RC=$?
unset DRAIN_CMD_com_test_central_sender
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T14 verdict NEEDS_GUARDED_RESTART (unparseable policy blocks even the DRAIN_CMD path)" || nok "T14 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T14 non-zero exit (halts delivery)" || nok "T14 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.central-sender" && ok "T14 flagged GUARDED" || nok "T14 guarded" "$(field GUARDED "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T14 NOT drained/bounced" || nok "T14 no-bounce" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "daemon-refresh tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
