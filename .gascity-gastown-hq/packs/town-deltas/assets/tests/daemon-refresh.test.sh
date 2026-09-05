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
#   8. (ga-j3j6s) Does NOT flag a SENSITIVE daemon for a guarded restart when
#      its live process already started after the deploy via some OTHER
#      restart path (e.g. the rig's own auto-deploy) — false-positive alarms
#      push a human toward an unnecessary hot-path restart. A genuinely-stale
#      SENSITIVE sibling in the SAME deploy still correctly wins the overall
#      verdict (NEEDS_GUARDED_RESTART is never masked).
#   9. (ga-00ptz) Discovers a daemon whose plist entrypoint lives under a
#      SEPARATE, independently-deployed clone of the same repo (e.g. real-world
#      painel-prod vs. whatsapp_automation) when that clone's root is listed in
#      EXTRA_RUNTIME_ROOTS — instead of silently dropping it from discovery and
#      reporting the false "touches no live daemon".
#  10. (ga-omfwe) DRY_RUN=1 never kickstarts, never populates RESTARTED, and
#      never reports PROOF=verified — it reports the preview in WOULD_RESTART
#      instead, so a dry-run preview can never be textually indistinguishable
#      from a real, confirmed restart.
#  11. (ga-y108i) A rig-declared restart_policy.yaml no_restart_paths glob
#      (e.g. daemons/static/**) short-circuits to VERDICT=OK/
#      PROOF=asset_served_per_request — never NEEDS_GUARDED_RESTART, even for
#      a SENSITIVE daemon — when EVERY changed file matches, whether the
#      match is on a *.js asset (T21) or the daemon's own *.py entrypoint
#      (T22, the stronger proof: bypasses the extension-based early-exit
#      entirely). A partially-covered mixed diff does NOT exempt (T23), and
#      an unrelated path (templates/, still genuinely restart-needed per
#      point 6/ga-jkj0) is never accidentally swallowed by an unrelated glob
#      (T24).
#  12. (ga-dk7fw) UNCONDITIONALLY (no restart_policy.yaml needed), tests/**,
#      docs/**, and *.md resolve to PROOF=not_applicable — not the weaker
#      not_verified an isolated, unimported change fell back to pre-fix (T28,
#      T29). The delta matters past daemon-refresh.sh's own output: story-
#      delivery.sh labels a story delivery:daemon-unverified and rewrites its
#      done-notification to "DAEMON LIVENESS NOT VERIFIED" for any PROOF tier
#      other than verified/not_applicable/asset_served_per_request — so a
#      not_verified tier on a tests-only change was live, actionable-looking
#      noise on a bead with zero daemon relevance. Deliberately NOT extended
#      to static/**/templates/** (still point-8/opt-in-only, unchanged — see
#      point 3/ga-jkj0). A co-changed real module in the SAME deploy as a
#      tests/ file is never swallowed by this (T30) — same all-or-nothing
#      shape as point 11.
#  13. (ga-tdzsh) A plist that fails to parse is escalated (ERROR-level log
#      line + the new PARSE_ERROR_LOADED field/JSON key) only when launchd
#      actually has that label loaded (T31) — never when nothing is loaded
#      under it at all (T32, the current real state of the two known-broken
#      plists on the live machine: com.athos.ckan_pbh, com.urblink.inbound-
#      review-3d — a run today must produce zero escalation). The load check
#      is launchd LOAD status, not live-PID presence: a label loaded but
#      currently idle (no PID) still escalates (T33) — daemon_pid() alone
#      cannot tell "not loaded" and "loaded but idle" apart, the exact
#      ambiguity that let com.gastown.dolt-server's broken plist hide.
#  14. (wa-jts45) A *.plist this deploy commits for a brand-new SCHEDULED job
#      has no live PID for points 1-13 to compare staleness against — every
#      check above them answers "is a daemon's live PROCESS stale?", a
#      question that is structurally silent about a process that was never
#      installed at all. VERDICT=JOB_NOT_INSTALLED now fires, BEFORE any
#      other check runs, when a *.plist changed by this deploy is missing
#      from LAUNCH_AGENTS_DIR (T37) or present but not `launchctl list`-loaded
#      (T38) — the exact wa-sas9j incident: merged + gate:passed + "daemon
#      fresh" were all simultaneously true while the job never existed on
#      disk for a month. A plist that IS installed+loaded is untouched by
#      this check and falls through to existing behavior (T39). A plist
#      declaring native `<key>Disabled</key><true/>` is intentionally manual
#      and never flagged (T40). Deliberately does NOT also require "has it
#      produced a successful run yet": a job installed by THIS deploy may
#      legitimately not have reached its next scheduled window yet, so that
#      bar would false-positive on every ordinary nightly-job delivery — left
#      to a human follow-up once installed+loaded is confirmed (see the
#      JOB_NOT_INSTALLED ACTION text at the call sites in
#      quality-gate-dispatcher.sh).
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

  # mock launchctl: `list <label>` prints the current PID (when one is seeded)
  # and, per ga-tdzsh, exits 0 iff the label is known to the mock at all
  # (seed_running OR seed_loaded was called for it — real launchd's own
  # "loaded regardless of live-PID" contract) or 1 ("Could not find service")
  # when it is not — this is what daemon_is_loaded() in the helper under test
  # actually checks. `kickstart ... label` logs the call and, if a
  # post-restart pid/lstart is seeded, swaps them in.
  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    if [ -n "$label" ] && { [ -f "$S/pid.$label" ] || [ -f "$S/loaded.$label" ]; }; then
      [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for port" >&2
    exit 1
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
  # ga-puq8z: the "deploy" commit run_helper creates below is, by default,
  # dated at DEPLOY_EPOCH (not wall-clock "now") — matching this fixture's
  # existing implicit assumption (used by every pre-ga-puq8z test) that the
  # commit and the deploy happen at the same moment. T26/T27 override this to
  # put the commit BEFORE DEPLOY_EPOCH, modeling a gate-queue/backoff delay
  # between when code was actually committed and when this check got around
  # to running.
  POST_COMMIT_EPOCH="$DEPLOY_EPOCH"
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
# seed a daemon that is LOADED in launchd but has NO live PID right now (e.g.
# a KeepAlive=false job between runs) — distinct from seed_running, which
# implies both loaded AND a live PID. Used to prove daemon_is_loaded() (ga-tdzsh)
# checks LOAD status, not PID presence — daemon_pid() alone is empty for both
# this case and "not loaded at all", the exact ambiguity the bug is about.
seed_loaded() {  # seed_loaded <label>
  : > "$MOCK/loaded.$1"
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
    GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
      git commit -q -m deploy --allow-empty
  )
  POST=$(git -C "$RUNTIME" rev-parse HEAD)

  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" \
  SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN="${DRY_RUN:-0}" \
  bash "$HELPER" 2>/dev/null
}

# like run_helper, but merges stderr into the captured output — needed for
# T19/T20, which assert on the WARN log() emits (stdout-only capture would
# never see it; every other test's `2>/dev/null` is why this is a separate
# function rather than a change to run_helper itself).
run_helper_stderr() {  # run_helper_stderr <changed-relpaths...>
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
    GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
      git commit -q -m deploy --allow-empty
  )
  POST=$(git -C "$RUNTIME" rev-parse HEAD)

  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" \
  SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN="${DRY_RUN:-0}" \
  bash "$HELPER" 2>&1
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

# ════════════════════════════════════════════════════════════════════════════
# T15 (ga-j3j6s): a SENSITIVE hot-path daemon whose CURRENT process already
# started AFTER the deploy (some OTHER mechanism — e.g. the rig's own
# auto-deploy — already restarted it) must NOT be flagged NEEDS_GUARDED_RESTART.
# Before this fix, the sensitive-with-no-drain-path branch unconditionally
# flagged GUARDED without ever checking whether the live process is already
# running the new code — a false positive that sends a human toward an
# unnecessary hot-path restart (real incident: com.whatsapp.map-viewer,
# auto-deploy had already restarted it before the alarm fired). The freshness
# check reuses DEPLOY_EPOCH/pid-start-epoch — the SAME comparison
# verify_fresh() already uses elsewhere in this file — never a file-mtime
# comparison (the ga-j3j6s bead's own caution: a daemon can serve from a
# different tree than the changed file, which would make an mtime check lie).
# ════════════════════════════════════════════════════════════════════════════
new_case t15
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
# already fresh: the live process started AFTER DEPLOY_EPOCH, exactly like
# verify_fresh() would confirm — but NOTHING in this script triggered that
# restart; some other mechanism (e.g. auto-deploy) did.
seed_running com.test.central-sender 9001 "$FRESH_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T15 verdict OK (already-fresh sensitive daemon not flagged)" || nok "T15 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T15 exit 0" || nok "T15 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.central-sender" && nok "T15 should NOT be GUARDED" "$(field GUARDED "$OUT")" || ok "T15 not flagged GUARDED"
echo "$(field ALREADY_FRESH "$OUT")" | grep -q "com.test.central-sender" && ok "T15 recorded in ALREADY_FRESH" || nok "T15 already_fresh" "$(field ALREADY_FRESH "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T15 NOT kickstarted (already fresh — no restart needed at all)" || nok "T15 no-kickstart" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T15 PROOF=verified (freshness positively confirmed, just via a different restart path)" || nok "T15 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T16 (ga-j3j6s): a MIXED deploy — one SENSITIVE daemon already fresh (skipped,
# no flag) and a DIFFERENT SENSITIVE daemon still genuinely stale (correctly
# flagged) — the overall verdict must still be NEEDS_GUARDED_RESTART (GUARDED
# outranks ALREADY_FRESH), proving the already-fresh short-circuit for one
# daemon can never mask a real guarded-restart need for another daemon in the
# same deploy.
# ════════════════════════════════════════════════════════════════════════════
new_case t16
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/daemons/slot_scheduler.py" <<<'print("sched")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
make_plist "$AGENTS" com.test.slot-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/slot_scheduler.py"
seed_running com.test.central-sender 9101 "$FRESH_LSTART"   # already fresh
seed_running com.test.slot-scheduler 9201 "$STALE_LSTART"   # still stale
OUT=$(run_helper daemons/central_sender.py daemons/slot_scheduler.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T16 verdict NEEDS_GUARDED_RESTART (one stale daemon still wins over an already-fresh sibling)" || nok "T16 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T16 non-zero exit (halts delivery)" || nok "T16 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.slot-scheduler" && ok "T16 stale daemon flagged GUARDED" || nok "T16 guarded (stale)" "$(field GUARDED "$OUT")"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.central-sender" && nok "T16 fresh daemon should NOT be in GUARDED" "$(field GUARDED "$OUT")" || ok "T16 fresh daemon not in GUARDED"
echo "$(field ALREADY_FRESH "$OUT")" | grep -q "com.test.central-sender" && ok "T16 fresh daemon recorded in ALREADY_FRESH" || nok "T16 already_fresh" "$(field ALREADY_FRESH "$OUT")"
! grep -q "com.test.central-sender" "$MOCK/kicks.log" 2>/dev/null && ok "T16 fresh daemon NOT kickstarted" || nok "T16 no-kickstart" "kickstart log: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T17 (ga-00ptz): a daemon's plist entrypoint lives under a SEPARATE,
# independently-deployed clone of the SAME repo (real-world: painel-prod vs.
# whatsapp_automation — two independent `git clone`s of one upstream, kept in
# sync by an unrelated deploy-sync mechanism, not by story-delivery.sh's own
# git-pull). Pre-fix, resolve_relpath() only matched a plist path literal
# under RUNTIME_DIR (or with a $VAR/ prefix to strip) — an absolute path under
# this second clone matched neither, so the daemon was silently dropped in
# Step 2 and never reached Step 3's AFFECTED check, regardless of what
# changed: VERDICT=OK/PROOF=not_verified/"touches no live daemon" for a
# daemon that is, in fact, live and running the changed file. Listing the
# second clone's root in EXTRA_RUNTIME_ROOTS fixes discovery: the SAME
# relpath must also exist under RUNTIME_DIR (the tree actually being diffed),
# so this only ever grants visibility into a file genuinely present in both
# trees — it can never invent an entrypoint out of thin air.
# ════════════════════════════════════════════════════════════════════════════
new_case t17
SECOND_CLONE="$CASE_DIR/second_clone"
mkdir -p "$SECOND_CLONE/daemons"
cat > "$SECOND_CLONE/daemons/painel_visibilidade.py" <<<'print("painel")'
cat > "$RUNTIME/daemons/painel_visibilidade.py" <<<'print("painel")'
make_plist "$AGENTS" com.test.painel-visibilidade "$SECOND_CLONE/venv/bin/python3" "$SECOND_CLONE/daemons/painel_visibilidade.py"
seed_running com.test.painel-visibilidade 9301 "$STALE_LSTART"
seed_restart com.test.painel-visibilidade 9399 "$FRESH_LSTART"
EXTRA_RUNTIME_ROOTS="$SECOND_CLONE"
OUT=$(run_helper daemons/painel_visibilidade.py); RC=$?
unset EXTRA_RUNTIME_ROOTS
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T17 verdict OK" || nok "T17 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T17 exit 0" || nok "T17 exit" "rc=$RC"
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.painel-visibilidade" && ok "T17 daemon under second clone discovered + affected" || nok "T17 affected" "$(field AFFECTED "$OUT")"
echo "$(field RESTARTED "$OUT")" | grep -q "com.test.painel-visibilidade" && ok "T17 daemon restarted" || nok "T17 restarted" "$(field RESTARTED "$OUT")"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T17 PROOF=verified (no longer a false 'touches no live daemon')" || nok "T17 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T18: (ga-omfwe) DRY_RUN=1 on an affected SAFE dashboard → previews via
# WOULD_RESTART, never populates RESTARTED, never kickstarts, never claims
# PROOF=verified. Pre-fix, this case reported RESTARTED and PROOF=verified
# identically to a real restart (T2) even though nothing ran.
# ════════════════════════════════════════════════════════════════════════════
new_case t18
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 4001 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 4099 "$FRESH_LSTART"
DRY_RUN=1
OUT=$(run_helper daemons/ban_risk_dashboard.py); RC=$?
unset DRY_RUN
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T18 verdict OK" || nok "T18 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T18 exit 0" || nok "T18 exit" "rc=$RC"
echo "$(field RESTARTED "$OUT")" | grep -q "com.test.ban-risk-dashboard" && nok "T18 RESTARTED must stay empty under DRY_RUN=1" "$(field RESTARTED "$OUT")" || ok "T18 RESTARTED empty (pre-fix bug: populated even under DRY_RUN=1)"
echo "$(field WOULD_RESTART "$OUT")" | grep -q "com.test.ban-risk-dashboard" && ok "T18 WOULD_RESTART reports the preview" || nok "T18 would_restart" "$(field WOULD_RESTART "$OUT")"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T18 PROOF=not_applicable (never 'verified' when nothing ran)" || nok "T18 proof" "got '$(field PROOF "$OUT")' (pre-fix bug: this was 'verified')"
[ ! -f "$MOCK/kicks.log" ] && ok "T18 no kickstart called under DRY_RUN=1" || nok "T18 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T19 (ga-otn7u): a plist with a literal "--" inside an XML <!-- --> comment
# (expat rejects it; Apple's own launchd parser tolerates it — the exact shape
# of 5 live plists found broken this way, incl. throughput-stall-watchdog.plist
# itself) used to be silently DROPPED from discovery: plist_args() caught ANY
# exception and exited 0, indistinguishable from "this plist genuinely has no
# ProgramArguments". Post-fix, plist_args() exits 1 on a parse failure and the
# caller logs a WARN naming the plist — and a HEALTHY sibling plist in the same
# LAUNCH_AGENTS_DIR is still discovered and processed normally (one broken
# plist must not blind discovery of every other daemon).
# ════════════════════════════════════════════════════════════════════════════
new_case t19
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9501 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9599 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-comment.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-comment</string>
  <!-- a stray double-hyphen -- inside this comment breaks plistlib's expat
       parser even though launchd itself loads this file fine -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T19 verdict OK (healthy daemon still processed normally)" || nok "T19 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T19 exit 0" || nok "T19 exit" "rc=$RC"
echo "$(field RESTARTED "$OUT")" | grep -q "com.test.ban-risk-dashboard" && ok "T19 healthy sibling still restarted+verified" || nok "T19 restarted" "$(field RESTARTED "$OUT")"
echo "$OUT" | grep -q "com.test.broken-comment.plist could not be parsed" && ok "T19 WARN names the broken plist (pre-fix: no warning existed anywhere)" || nok "T19 warn" "no distinguishing WARN in output: [$OUT]"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T19 PROOF=verified (the healthy daemon's own verification is unaffected by its broken sibling)" || nok "T19 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T20 (ga-otn7u): EVERY plist in LAUNCH_AGENTS_DIR is unparseable — pre-fix,
# this collapsed to the exact same "no rig daemons discovered — OK" as a
# directory that genuinely has zero rig daemons in it (both produced
# PROOF=not_applicable, an unearned claim of certainty — the exact
# error-and-empty-must-not-produce-the-same-value defect class). Post-fix this
# must read as not_verified: discovery could not confirm the directory is
# empty of daemons, it only knows it could not read what's there.
# ════════════════════════════════════════════════════════════════════════════
new_case t20
cat > "$RUNTIME/daemons/some_other_thing.py" <<<'print("x")'
cat > "$AGENTS/com.test.broken-only.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-only</string>
  <!-- another stray double-hyphen -- here -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
OUT=$(run_helper_stderr daemons/some_other_thing.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T20 verdict OK" || nok "T20 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T20 exit 0" || nok "T20 exit" "rc=$RC"
echo "$OUT" | grep -q "com.test.broken-only.plist could not be parsed" && ok "T20 WARN names the broken plist" || nok "T20 warn" "no distinguishing WARN in output: [$OUT]"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T20 PROOF=not_verified (discovery incomplete, not confirmed-empty — pre-fix bug: this was not_applicable, indistinguishable from a genuinely empty dir)" || nok "T20 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T21 (ga-y108i): a SENSITIVE hot-path daemon, currently STALE, whose deploy
# touched ONLY a file under a rig-declared no_restart_paths glob (a static
# asset a handler re-reads from disk on every request — never needs a
# restart to serve new bytes). Must emit OK with PROOF=asset_served_per_request
# instead of flagging NEEDS_GUARDED_RESTART — the real incident this closes:
# a commit touching only daemons/static/demand_previsao.js flagged the
# demand-dashboard daemon (policy-unlisted → sensitive) and mailed the Mayor;
# the restart was proven pointless by hand (live-served md5 already matched
# the merged blob, pre-merge PID still running). The changed file here is
# *.js — not *.py/template — so a pre-fix run already reaches VERDICT=OK via
# the unrelated extension-based early-exit; the assertion that actually
# distinguishes pre/post-fix is PROOF (not_applicable pre-fix vs. the more
# specific asset_served_per_request post-fix). T22 below is the stronger
# proof that does not depend on that early-exit at all.
# ════════════════════════════════════════════════════════════════════════════
new_case t21
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("demand")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9601 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper daemons/static/demand_previsao.js); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T21 verdict OK (static asset under no_restart_paths)" || nok "T21 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T21 exit 0" || nok "T21 exit" "rc=$RC"
[ "$(field PROOF "$OUT")" = "asset_served_per_request" ] && ok "T21 PROOF=asset_served_per_request" || nok "T21 proof" "got '$(field PROOF "$OUT")'"
[ ! -f "$MOCK/kicks.log" ] && ok "T21 no kickstart called" || nok "T21 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T22 (ga-y108i): stronger proof than T21 — the changed file IS the daemon's
# own *.py entrypoint (so pre-fix this reaches AFFECTED/SENSITIVE/GUARDED via
# the normal direct-match *.py path, NOT the extension-based early-exit T21
# also passes through), but that entrypoint lives under a declared
# no_restart_paths glob (a static-file server that only ever proxies bytes
# from disk). The declaration is deliberately PATH-based, not
# extension-based, per the bug's own caution: a *.py helper can be just as
# exemptable as a *.js file. Must be OK/asset_served_per_request, never
# NEEDS_GUARDED_RESTART.
# ════════════════════════════════════════════════════════════════════════════
new_case t22
mkdir -p "$RUNTIME/daemons/static"
cat > "$RUNTIME/daemons/static/serve_static.py" <<<'print("serve")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/static/serve_static.py"
seed_running com.test.demand-dashboard 9701 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper daemons/static/serve_static.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T22 verdict OK (entrypoint *.py under no_restart_paths, not flagged)" || nok "T22 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T22 exit 0" || nok "T22 exit" "rc=$RC"
[ "$(field PROOF "$OUT")" = "asset_served_per_request" ] && ok "T22 PROOF=asset_served_per_request" || nok "T22 proof" "got '$(field PROOF "$OUT")'"
[ ! -f "$MOCK/kicks.log" ] && ok "T22 no kickstart called" || nok "T22 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T23 (ga-y108i): partial coverage must NOT exempt — a MIXED deploy where one
# changed file matches no_restart_paths (a static asset) and a SEPARATE
# changed file does not (the daemon's own *.py entrypoint, elsewhere in the
# tree). The whole changed set must be covered, not just one file in it —
# otherwise an innocuous static-asset tweak riding along in the same commit
# as a real logic change would wrongly suppress a needed guarded-restart flag.
# ════════════════════════════════════════════════════════════════════════════
new_case t23
mkdir -p "$RUNTIME/daemons/static"
cat > "$RUNTIME/daemons/frota_dashboard.py" <<<'print("frota")'
make_plist "$AGENTS" com.test.frota-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/frota_dashboard.py"
seed_running com.test.frota-dashboard 9801 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper daemons/static/some_asset.js daemons/frota_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T23 verdict NEEDS_GUARDED_RESTART (mixed diff, entrypoint change NOT covered by no_restart_paths)" || nok "T23 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T23 non-zero exit" || nok "T23 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.frota-dashboard" && ok "T23 flagged GUARDED despite one covered file in the same diff" || nok "T23 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T24 (ga-y108i): a declared no_restart_paths glob must be PRECISE — it must
# NOT accidentally cover an unrelated path. This same rig's Jinja templates
# ARE compiled/cached at import (ga-jkj0) and still genuinely need a restart
# even though daemons/static/** is separately declared no-restart. A changed
# template (rendered by an explicitly-SAFE daemon) must still restart
# normally when it does not match the declared glob.
# ════════════════════════════════════════════════════════════════════════════
new_case t24
cat > "$RUNTIME/daemons/map_viewer_dashboard.py" <<'PYEOF'
from flask import render_template
def index():
    return render_template("map_viewer.html")
PYEOF
mkdir -p "$RUNTIME/templates"
cat > "$RUNTIME/templates/map_viewer.html" <<<'<html>old</html>'
make_plist "$AGENTS" com.test.map-viewer "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/map_viewer_dashboard.py"
seed_running com.test.map-viewer 9901 "$STALE_LSTART"
seed_restart com.test.map-viewer 9999 "$FRESH_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
auto:
  - map_viewer_dashboard.py
no_restart_paths:
  - daemons/static/**
EOF
OUT=$(run_helper templates/map_viewer.html); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T24 verdict OK after real restart (no_restart_paths glob correctly does not cover templates/)" || nok "T24 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.map-viewer" "$MOCK/kicks.log" 2>/dev/null && ok "T24 kickstart invoked (template change still triggers real restart)" || nok "T24 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T24 PROOF=verified (real restart, not asset_served_per_request)" || nok "T24 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T25 (ga-y108i gate-fix): the no_restart_paths short-circuit must be
# CWD-independent. POLICY_NO_RESTART_PATHS holds glob-pattern TEXT (e.g.
# "daemons/static/**"); a bare `for pat in $POLICY_NO_RESTART_PATHS` performs
# bash pathname expansion on each split word, so a CWD that merely happens to
# contain a matching subtree (unrelated to RUNTIME_DIR — e.g. an adjacent
# worktree checkout, or an agent session that cd'd into a rig directory to
# debug) silently substitutes real filenames for the pattern string, the
# short-circuit fails to fire, and the deploy falls through to
# NEEDS_GUARDED_RESTART even though every changed file matches the declared
# glob. Same fixture as T22 (a *.py entrypoint under the glob, bypassing the
# unrelated extension-based early-exit so this assertion depends entirely on
# the short-circuit), but run from a CWD seeded with a colliding
# daemons/static/ subtree instead of the test runner's own CWD.
# ════════════════════════════════════════════════════════════════════════════
new_case t25
mkdir -p "$RUNTIME/daemons/static"
cat > "$RUNTIME/daemons/static/serve_static.py" <<<'print("serve")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/static/serve_static.py"
seed_running com.test.demand-dashboard 9702 "$STALE_LSTART"
cat > "$RUNTIME/daemons/restart_policy.yaml" <<'EOF'
no_restart_paths:
  - daemons/static/**
EOF
COLLIDE_CWD="$CASE_DIR/unrelated_cwd"
mkdir -p "$COLLIDE_CWD/daemons/static"
: > "$COLLIDE_CWD/daemons/static/unrelated_file.py"
OUT=$(cd "$COLLIDE_CWD" && run_helper daemons/static/serve_static.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T25 verdict OK from a CWD with a colliding daemons/static/ subtree (no_restart_paths glob not corrupted by CWD pathname expansion)" || nok "T25 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T25 exit 0" || nok "T25 exit" "rc=$RC"
[ "$(field PROOF "$OUT")" = "asset_served_per_request" ] && ok "T25 PROOF=asset_served_per_request" || nok "T25 proof" "got '$(field PROOF "$OUT")'"
[ ! -f "$MOCK/kicks.log" ] && ok "T25 no kickstart called" || nok "T25 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T26 (ga-puq8z): a SENSITIVE daemon whose live process restarted (some OTHER
# path — e.g. a sibling bead's own guarded restart) AFTER the commit under
# review was made, but BEFORE DEPLOY_EPOCH (this check's own start time), must
# NOT be flagged NEEDS_GUARDED_RESTART. Pre-fix, already_fresh() compared the
# pid's start time against DEPLOY_EPOCH alone — captured by the CALLER right
# before ITS OWN deploy step, which can be minutes-to-hours after the commit
# itself (gate-queue wait, deploy retry/backoff, a slow sweep cycle). A daemon
# already refreshed in that gap has a pid-start strictly AFTER the commit but
# strictly BEFORE DEPLOY_EPOCH — genuinely fresh, but the old DEPLOY_EPOCH-only
# comparison called it stale and flagged an unnecessary hot-path restart.
# Real incident (measured 2026-09-01): com.whatsapp.demand-dashboard flagged
# twice within 15 minutes, both times already running code newer than the
# commit each check was verifying — this is that exact shape, reproduced
# deterministically via POST_COMMIT_EPOCH (see new_case()/run_helper()).
# gate-fix-2 (gate_run=ga-9a45d, Reviewer-1 FAIL): the first gate-fix reported
# this case as PROOF=verified — the same confidence tag verify_fresh() earns
# by confirming a restart THIS script itself performed. That overclaims: a
# launchd KeepAlive respawn of a crashed SENSITIVE daemon landing between the
# commit and DEPLOY_EPOCH would pass the identical pid-start-vs-COMMIT_EPOCH
# test while still running pre-deploy code. This is a correlation, not proof
# — VERDICT stays OK (still no unneeded guarded restart) but PROOF must be
# not_verified, matching every other case in this script that cannot
# positively confirm live freshness.
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="central-sender conversation-monitor slot-scheduler webhook demand-dashboard"
new_case t26
POST_COMMIT_EPOCH=$(( DEPLOY_EPOCH - 3000 ))            # commit made 50 min before this check started
ALREADY_FRESH_MID_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 300 )) )"  # daemon restarted 5 min before this check — AFTER the commit, BEFORE DEPLOY_EPOCH
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("demand")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9301 "$ALREADY_FRESH_MID_LSTART"
OUT=$(run_helper daemons/demand_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T26 verdict OK (daemon already fresher than the commit under review, despite predating DEPLOY_EPOCH)" || nok "T26 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T26 exit 0" || nok "T26 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.demand-dashboard" && nok "T26 should NOT be GUARDED" "$(field GUARDED "$OUT")" || ok "T26 not flagged GUARDED"
echo "$(field ALREADY_FRESH "$OUT")" | grep -q "com.test.demand-dashboard" && ok "T26 recorded in ALREADY_FRESH" || nok "T26 already_fresh" "$(field ALREADY_FRESH "$OUT")"
! grep -q "com.test.demand-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T26 NOT kickstarted" || nok "T26 no-kickstart" "kickstart was called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T26 PROOF=not_verified (pid-start-vs-commit is a plausibility check, not proof — gate-fix-2)" || nok "T26 proof" "got '$(field PROOF "$OUT")', want not_verified"

# ════════════════════════════════════════════════════════════════════════════
# T27 (ga-puq8z): companion to T26 — a SENSITIVE daemon whose live process
# predates the COMMIT itself (genuinely stale, not merely "before
# DEPLOY_EPOCH") must still be flagged NEEDS_GUARDED_RESTART. Proves the
# COMMIT_EPOCH-based comparison introduced for T26 does not widen the
# already-fresh window enough to swallow a real stale daemon — the class of
# regression T16 already guards for DEPLOY_EPOCH, mirrored here for
# COMMIT_EPOCH.
# ════════════════════════════════════════════════════════════════════════════
new_case t27
POST_COMMIT_EPOCH=$(( DEPLOY_EPOCH - 3000 ))            # commit made 50 min before this check started
STILL_STALE_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 4000 )) )"  # daemon started BEFORE the commit itself
cat > "$RUNTIME/daemons/demand_dashboard.py" <<<'print("demand")'
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9401 "$STILL_STALE_LSTART"
OUT=$(run_helper daemons/demand_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T27 verdict NEEDS_GUARDED_RESTART (process predates the commit itself — genuinely stale)" || nok "T27 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T27 non-zero exit" || nok "T27 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.demand-dashboard" && ok "T27 flagged GUARDED" || nok "T27 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T28 (ga-dk7fw, header point 9): an ISOLATED tests/*.py change — a single
# test file, entrypoints unrelated to it — must resolve with the CLEAN,
# structurally-certain PROOF=not_applicable, not the weaker not_verified.
#
# IMPORTANT (measured directly against the pre-fix script before writing this
# test, so this assertion is not guesswork): VERDICT was already OK for this
# exact fixture pre-fix too — Step 3's "changed code touches no live daemon"
# fallback already resolves an isolated, unimported test file to OK, via
# PROOF=not_verified. So the observable delta here is NOT the verdict/exit
# code (both are OK) — it is PROOF/REASON. That distinction is NOT cosmetic:
# story-delivery.sh (Delivery COMPLETE branch) special-cases PROOF via a
# `case "$REFRESH_PROOF" in verified|not_applicable|asset_served_per_request)
# : ;; *) ...esac` — anything OTHER than those three tiers (not_verified
# included) adds a delivery:daemon-unverified label to the STORY bead and
# rewrites its done-notification to "DAEMON LIVENESS NOT VERIFIED — merged
# code may still be dormant". Pre-fix, a story whose branch touched ONLY a
# test file got that exact label and scary wording despite zero daemon
# relevance — the real, evidenced noise class this fix removes, one hop
# downstream of daemon-refresh.sh itself (see the wa-zmmyd citation on
# ga-dk7fw for the full incident this traces back to — the ACTUAL alert
# there was legitimate, driven by real production files in the same deploy;
# T30 below reproduces that mixed-commit shape and proves it still flags).
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender"
new_case t28
cat > "$RUNTIME/daemons/campaign_scheduler.py" <<<'def run(): pass'
cat > "$RUNTIME/daemons/central_sender.py" <<<'def send(): pass'
make_plist "$AGENTS" com.test.campaign-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/campaign_scheduler.py"
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.campaign-scheduler 9801 "$STALE_LSTART"
seed_running com.test.central-sender 9802 "$STALE_LSTART"
# deploy changed ONLY an isolated test file — the exact wa-zmmyd shape
OUT=$(run_helper tests/test_campaign_alltime_dedup_wa_zmmyd.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T28 verdict OK (tests/-only change)" || nok "T28 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T28 exit 0" || nok "T28 exit" "rc=$RC"
[ -z "$(field AFFECTED "$OUT")" ] && ok "T28 no daemon marked AFFECTED" || nok "T28 affected" "$(field AFFECTED "$OUT")"
[ ! -f "$MOCK/kicks.log" ] && ok "T28 no kickstart called" || nok "T28 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T28 PROOF=not_applicable (structurally certain, not merely undetected — the delta from pre-fix not_verified that clears story-delivery.sh's delivery:daemon-unverified case)" || nok "T28 proof" "got '$(field PROOF "$OUT")', want not_applicable"
echo "$(field REASON "$OUT")" | grep -qi "structurally inert" && ok "T28 REASON names the structurally-inert path class" || nok "T28 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T29 (ga-dk7fw): docs/**, *.md-only changes — the other two path classes
# ACEITE item 1 names — resolve the same way as T28 (same mechanism, both
# default patterns exercised together: a nested docs/ file and a root *.md
# file NOT under docs/, matching the "*.md" pattern independently of "docs/**").
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender"
new_case t29
cat > "$RUNTIME/daemons/campaign_scheduler.py" <<<'def run(): pass'
make_plist "$AGENTS" com.test.campaign-scheduler "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/campaign_scheduler.py"
seed_running com.test.campaign-scheduler 9803 "$STALE_LSTART"
OUT=$(run_helper docs/architecture/campaign_scheduler.md CONTRIBUTING.md); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T29 verdict OK (docs/ + root *.md change)" || nok "T29 verdict" "got '$V' out=[$OUT]"
[ -z "$(field AFFECTED "$OUT")" ] && ok "T29 no daemon marked AFFECTED" || nok "T29 affected" "$(field AFFECTED "$OUT")"
[ "$(field PROOF "$OUT")" = "not_applicable" ] && ok "T29 PROOF=not_applicable" || nok "T29 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T30 (ga-dk7fw ACEITE item 2 — no escape hatch): a MIXED deploy where a
# changed shared module IS genuinely imported by a daemon, alongside an
# unrelated tests/*.py file in the SAME deploy, must still flag normally —
# the tests/ file must never exempt real, co-changed production code. This is
# the actual shape of the wa-zmmyd incident (verified against its own posted
# daemon-refresh log: the real CHANGED set was 4 production .py files plus 2
# tests/*.py files, all in one deploy — the alert was correct because of the
# 4 real files, not caused by the 2 test files).
# ════════════════════════════════════════════════════════════════════════════
SENSITIVE_DAEMONS="campaign central-sender"
new_case t30
mkdir -p "$RUNTIME/lib"
cat > "$RUNTIME/lib/dedup_check.py" <<<'def is_duplicate(): pass'
cat > "$RUNTIME/daemons/central_sender.py" <<'PYEOF'
from lib.dedup_check import is_duplicate
is_duplicate()
PYEOF
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 9804 "$STALE_LSTART"
OUT=$(run_helper lib/dedup_check.py tests/test_dedup_check_wa_zmmyd.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T30 verdict NEEDS_GUARDED_RESTART (mixed lib/+tests/ deploy still flags the real lib/ change)" || nok "T30 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T30 non-zero exit" || nok "T30 exit" "rc=$RC"
echo "$(field GUARDED "$OUT")" | grep -q "com.test.central-sender" && ok "T30 sensitive daemon flagged GUARDED despite co-changed tests/ file" || nok "T30 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T31 (ga-tdzsh): a plist that fails to parse, but launchd DOES have that
# label loaded (with a live PID) — the real coverage gap this bug is about: a
# live daemon invisible to discovery because its own plist is unparseable
# (real incident: com.gastown.dolt-server, the city's data plane, hidden this
# way until 2026-09-02/ga-dgrzf). Must escalate distinctly from a merely
# unparseable-and-UNLOADED plist (T19/T20 above, unchanged): an ERROR-level
# log line naming the daemon, and the label present in the new
# PARSE_ERROR_LOADED structured field. A healthy sibling daemon in the same
# scan is still processed normally either way (same point T19 already proves).
# ════════════════════════════════════════════════════════════════════════════
new_case t31
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9901 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9999 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-loaded.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-loaded</string>
  <!-- a stray double-hyphen -- inside this comment breaks plistlib's expat
       parser even though launchd itself loads this file fine -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
seed_running com.test.broken-loaded 9911 "$STALE_LSTART"   # loaded + live PID; the plist itself still never parses
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T31 verdict OK (healthy sibling daemon still processed normally)" || nok "T31 verdict" "got '$V' out=[$OUT]"
echo "$OUT" | grep -q "ERROR:.*com.test.broken-loaded.plist could not be parsed" && ok "T31 ERROR-level line names the LOADED broken daemon (pre-fix: this line did not exist — only an unescalated WARN)" || nok "T31 error-line" "no escalated ERROR line in output: [$OUT]"
echo "$(field PARSE_ERROR_LOADED "$OUT")" | grep -qx "com.test.broken-loaded" && ok "T31 PARSE_ERROR_LOADED carries the loaded label (pre-fix: field did not exist at all)" || nok "T31 parse_error_loaded" "got '$(field PARSE_ERROR_LOADED "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T32 (ga-tdzsh): a plist that fails to parse, and launchd has NO record of
# that label at all (dead symlink / stale file — the current, real state of
# com.athos.ckan_pbh and com.urblink.inbound-review-3d on the live machine,
# per ga-dgrzf). Must NOT escalate — this is the ACEITE bar: a run today, with
# both known-broken plists unloaded, must not produce an escalatable alarm.
# No ERROR-level line, PARSE_ERROR_LOADED stays empty. The plist is still
# named in PARSE_ERROR_UNLOADED and a low-priority note — visible for cleanup,
# just never confused for a live gap.
# ════════════════════════════════════════════════════════════════════════════
new_case t32
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9921 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9929 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-unloaded.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-unloaded</string>
  <!-- a stray double-hyphen -- here, and nothing loaded under this label -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
# deliberately NOT seeded as running or loaded — mirrors a dead symlink/stale file
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T32 verdict OK" || nok "T32 verdict" "got '$V' out=[$OUT]"
! echo "$OUT" | grep -q "ERROR:.*com.test.broken-unloaded" && ok "T32 no ERROR-level line for an unloaded broken plist (THE ACEITE bar)" || nok "T32 no-error" "escalated when it should not have: [$OUT]"
[ -z "$(field PARSE_ERROR_LOADED "$OUT")" ] && ok "T32 PARSE_ERROR_LOADED stays empty" || nok "T32 parse_error_loaded" "got '$(field PARSE_ERROR_LOADED "$OUT")'"
echo "$(field PARSE_ERROR_UNLOADED "$OUT")" | grep -qx "com.test.broken-unloaded" && ok "T32 PARSE_ERROR_UNLOADED still records it (visible, just not escalated)" || nok "T32 parse_error_unloaded" "got '$(field PARSE_ERROR_UNLOADED "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T33 (ga-tdzsh): the escalation check is launchd LOAD status, not live-PID
# presence — a label loaded but with NO current PID (e.g. a KeepAlive=false
# job between runs) must still escalate. Proves daemon_is_loaded() cannot be
# satisfied by reusing daemon_pid(), which is empty for BOTH "not loaded" and
# "loaded but idle" — the exact ambiguity ga-tdzsh is about.
# ════════════════════════════════════════════════════════════════════════════
new_case t33
cat > "$RUNTIME/daemons/ban_risk_dashboard.py" <<<'print("dash")'
make_plist "$AGENTS" com.test.ban-risk-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/ban_risk_dashboard.py"
seed_running com.test.ban-risk-dashboard 9941 "$STALE_LSTART"
seed_restart com.test.ban-risk-dashboard 9949 "$FRESH_LSTART"
cat > "$AGENTS/com.test.broken-idle.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.broken-idle</string>
  <!-- a stray double-hyphen -- here; loaded but between runs, no live PID -->
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
seed_loaded com.test.broken-idle   # loaded, but NO live PID
OUT=$(run_helper_stderr daemons/ban_risk_dashboard.py); RC=$?
echo "$OUT" | grep -q "ERROR:.*com.test.broken-idle.plist could not be parsed" && ok "T33 ERROR line fires for a loaded-but-idle daemon (load status, not PID presence)" || nok "T33 error-line" "no escalated ERROR line: [$OUT]"
echo "$(field PARSE_ERROR_LOADED "$OUT")" | grep -qx "com.test.broken-idle" && ok "T33 PARSE_ERROR_LOADED carries the idle-but-loaded label" || nok "T33 parse_error_loaded" "got '$(field PARSE_ERROR_LOADED "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T34 (ga-q617u): route-blueprint hop — a changed lib/*.py module whose ONLY
# caller is a daemons/routes/*.py blueprint file (never imported directly by
# the entrypoint that mounts it) must still mark that entrypoint's daemon
# affected. Real incident: lib/assertiva_cache.py's read_pessoas_ref_items
# changed; its only caller was daemons/routes/pregao.py, mounted by
# classification_dashboard.py via `from routes import ..., pregao, ...` —
# classification_dashboard.py itself never imports assertiva_cache, so the
# single-hop entrypoint-only scan (pre-fix) never flagged it, while two
# UNRELATED daemons that import assertiva_cache directly (for a different
# function) got flagged instead — a false negative on the one daemon that
# actually mattered, hidden behind two false positives on daemons that
# didn't. THIS test proves the false-negative half: the routes-mounted
# daemon must appear in AFFECTED (fails pre-fix: AFFECTED is empty and
# VERDICT/PROOF land on the ga-vmq1i "touches no live daemon"/not_verified
# branch instead of restarting + verifying fresh).
# ════════════════════════════════════════════════════════════════════════════
new_case t34
mkdir -p "$RUNTIME/daemons/routes" "$RUNTIME/lib"
cat > "$RUNTIME/lib/assertiva_cache.py" <<<'def read_pessoas_ref_items(cpf): return []'
cat > "$RUNTIME/daemons/routes/pregao.py" <<'PYEOF'
from lib import assertiva_cache as _ac

def handler():
    return _ac.read_pessoas_ref_items("00000000000")
PYEOF
cat > "$RUNTIME/daemons/classification_dashboard.py" <<'PYEOF'
from routes import pregao

def index():
    return pregao.handler()
PYEOF
make_plist "$AGENTS" com.test.classification-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/classification_dashboard.py"
seed_running com.test.classification-dashboard 9501 "$STALE_LSTART"
seed_restart com.test.classification-dashboard 9599 "$FRESH_LSTART"
# deploy changes ONLY the shared lib module — not the routes file, not the entrypoint
OUT=$(run_helper lib/assertiva_cache.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.classification-dashboard" && ok "T34 route-mounted dashboard marked affected via routes/*.py hop" || nok "T34 affected" "$(field AFFECTED "$OUT")"
[ "$V" = "OK" ] && ok "T34 verdict OK after fresh restart" || nok "T34 verdict" "got '$V' out=[$OUT]"
grep -q "com.test.classification-dashboard" "$MOCK/kicks.log" 2>/dev/null && ok "T34 kickstart invoked" || nok "T34 kickstart" "log: $(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field PROOF "$OUT")" = "verified" ] && ok "T34 PROOF=verified" || nok "T34 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T35 (ga-q617u): precision guard — a daemon with a routes/ sibling directory
# must NOT be marked affected via an UNRELATED routes/*.py file it never
# mounts (no cross-dashboard cascade: daemons/routes/ is shared by multiple
# dashboards in the real rig, and each one only mounts a subset of it). Proves
# daemon_imports_stem_via_routes()'s own-mount gate is load-bearing, not just
# "does a routes/ dir exist next to me".
# ════════════════════════════════════════════════════════════════════════════
new_case t35
mkdir -p "$RUNTIME/daemons/routes" "$RUNTIME/lib"
cat > "$RUNTIME/lib/assertiva_cache.py" <<<'def read_pessoas_ref_items(cpf): return []'
cat > "$RUNTIME/daemons/routes/pregao.py" <<'PYEOF'
from lib import assertiva_cache as _ac

def handler():
    return _ac.read_pessoas_ref_items("00000000000")
PYEOF
cat > "$RUNTIME/daemons/routes/cls_shared.py" <<<'def other(): pass'
# demand_dashboard mounts ONLY cls_shared — never pregao
cat > "$RUNTIME/daemons/demand_dashboard.py" <<'PYEOF'
from routes import cls_shared

def index():
    return cls_shared.other()
PYEOF
make_plist "$AGENTS" com.test.demand-dashboard "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/demand_dashboard.py"
seed_running com.test.demand-dashboard 9601 "$STALE_LSTART"
OUT=$(run_helper lib/assertiva_cache.py); RC=$?
V=$(field VERDICT "$OUT")
echo "$(field AFFECTED "$OUT")" | grep -q "com.test.demand-dashboard" && nok "T35 should not be affected (never mounts pregao)" "$(field AFFECTED "$OUT")" || ok "T35 demand-dashboard not marked affected (no cross-dashboard cascade)"
[ "$V" = "OK" ] && ok "T35 verdict OK" || nok "T35 verdict" "got '$V' out=[$OUT]"
[ ! -f "$MOCK/kicks.log" ] && ok "T35 no kickstart called" || nok "T35 kickstart" "called: $(cat "$MOCK/kicks.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# T36 (ga-q617u): the NEEDS_GUARDED_RESTART REASON text must warn the GUARDED
# list itself can be INCOMPLETE (a daemon reached only through a deeper import
# chain than this scan follows can be silently missing), not just that a
# LISTED daemon might be a false positive — pre-fix the message covered only
# the false-positive half ("may be a false positive"), which is what let a
# real incident's daemon list be read as complete when it was not (ga-q617u:
# "o aviso do detector ate diz 'may be a false positive' — mas ele nao avisa
# que pode ter um falso NEGATIVO").
# ════════════════════════════════════════════════════════════════════════════
new_case t36
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
make_plist "$AGENTS" com.test.central-sender "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/central_sender.py"
seed_running com.test.central-sender 9701 "$STALE_LSTART"
OUT=$(run_helper daemons/central_sender.py); RC=$?
V=$(field VERDICT "$OUT")
REASON="$(field REASON "$OUT")"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T36 verdict NEEDS_GUARDED_RESTART" || nok "T36 verdict" "got '$V' out=[$OUT]"
echo "$REASON" | grep -qi "false positive" && ok "T36 REASON still warns a listed daemon may be a false positive" || nok "T36 false-positive wording" "$REASON"
echo "$REASON" | grep -qiE "incomplete|missing|false negative" && ok "T36 REASON now warns the list itself may be INCOMPLETE (false negative)" || nok "T36 incompleteness wording" "$REASON"

# ════════════════════════════════════════════════════════════════════════════
# T37 (wa-jts45): a brand-new scheduled-job *.plist committed by this deploy,
#     never installed under LAUNCH_AGENTS_DIR at all → VERDICT=JOB_NOT_INSTALLED,
#     non-zero exit, BEFORE Step 1's own "no .py/template changed" short-circuit
#     ever gets a chance to emit OK (this deploy touches ZERO *.py/template
#     files — if Step 1b did not run first, pre-fix behavior would emit
#     VERDICT=OK here). This is the exact wa-sas9j incident: merged +
#     gate:passed + "daemon fresh" were all simultaneously true while the job
#     never existed on disk for a month.
#
# Deliberately does NOT use run_helper() here: that helper's per-file loop
# APPENDS a "# changed ..." marker line to each listed path, which is fine for
# a .py/.html fixture but would corrupt a *.plist's XML (trailing garbage
# after </plist>) and end up testing the "unparseable plist" skip path
# instead of a well-formed one that simply isn't installed.
# ════════════════════════════════════════════════════════════════════════════
new_case t37
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.newjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/newjob.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# deliberately do NOT copy the plist into $AGENTS (LAUNCH_AGENTS_DIR) — that
# omission IS the bug this test proves gets caught.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T37 verdict JOB_NOT_INSTALLED (plist committed, never installed)" || nok "T37 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T37 non-zero exit" || nok "T37 exit" "rc=$RC"
echo "$(field REASON "$OUT")" | grep -q "com.test.newjob" && ok "T37 REASON names the missing label" || nok "T37 reason" "$(field REASON "$OUT")"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "T37 PROOF=not_verified" || nok "T37 proof" "got '$(field PROOF "$OUT")'"

# ════════════════════════════════════════════════════════════════════════════
# T38 (wa-jts45): the plist IS present under LAUNCH_AGENTS_DIR (someone copied
#     the file) but launchd never loaded it (no `launchctl load`/bootstrap run)
#     → VERDICT=JOB_NOT_INSTALLED — file-presence alone is not proof the job
#     will ever fire; launchd has to know about the label too.
# ════════════════════════════════════════════════════════════════════════════
new_case t38
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.copiedonly "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/copiedonly.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.copiedonly "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/copiedonly.py"
# deliberately do NOT seed_loaded/seed_running → the mock launchctl's `list`
# reports "not found", matching a real machine where the file was copied by
# hand but never loaded.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T38 verdict JOB_NOT_INSTALLED (plist present, not loaded)" || nok "T38 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T38 non-zero exit" || nok "T38 exit" "rc=$RC"
echo "$(field REASON "$OUT")" | grep -q "com.test.copiedonly" && ok "T38 REASON names the unloaded label" || nok "T38 reason" "$(field REASON "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T39 (wa-jts45): the plist IS installed AND loaded — Step 1b must NOT flag it,
#     and must let the deploy fall through to whatever Step 1+ would otherwise
#     conclude (here: no *.py/template changed → OK/not_applicable, proving
#     Step 1b adds no false positive on a correctly-delivered scheduled job).
# ════════════════════════════════════════════════════════════════════════════
new_case t39
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$RUNTIME/launchd" com.test.goodjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/goodjob.py"
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
make_plist "$AGENTS" com.test.goodjob "$RUNTIME/venv/bin/python3" "$RUNTIME/daemons/goodjob.py"
seed_loaded com.test.goodjob
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T39 verdict OK (installed+loaded scheduled job is not flagged)" || nok "T39 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T39 exit 0" || nok "T39 exit" "rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# T40 (wa-jts45): a plist declaring native <key>Disabled</key><true/> is
#     intentionally manual — changing it must never be flagged even though it
#     is neither installed nor loaded (that is the point of Disabled=true).
# ════════════════════════════════════════════════════════════════════════════
new_case t40
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && git commit -q -m base --allow-empty )
PRE=$(git -C "$RUNTIME" rev-parse HEAD)
mkdir -p "$RUNTIME/launchd"
cat > "$RUNTIME/launchd/com.test.manualjob.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.test.manualjob</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
  <key>Disabled</key><true/>
</dict>
</plist>
PLIST
( cd "$RUNTIME" && git add -A >/dev/null 2>&1 && \
  GIT_AUTHOR_DATE="@$POST_COMMIT_EPOCH" GIT_COMMITTER_DATE="@$POST_COMMIT_EPOCH" \
  git commit -q -m deploy )
POST=$(git -C "$RUNTIME" rev-parse HEAD)
# deliberately NOT installed anywhere — Disabled=true must skip it regardless.
OUT=$(MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
  EXTRA_RUNTIME_ROOTS="${EXTRA_RUNTIME_ROOTS:-}" LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" = "OK" ] && ok "T40 verdict OK (Disabled=true job never flagged)" || nok "T40 verdict" "got '$V' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T40 exit 0" || nok "T40 exit" "rc=$RC"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "daemon-refresh tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
