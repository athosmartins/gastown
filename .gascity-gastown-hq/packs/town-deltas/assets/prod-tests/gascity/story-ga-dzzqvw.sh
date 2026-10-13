#!/usr/bin/env bash
# prod-tests/gascity/story-ga-dzzqvw.sh — prod test for ga-dzzqvw (the gate's "task-rapida" lane). The lane ships DARK: it grants only while
# .gc/gate-task-rapida.on exists, created at go-live (ga-dzzqvw.1). So: the deployed files parse under /bin/bash 3.2, the dispatcher is wired
# and launchd runs THIS dispatcher (merged != live), the lane's on/dark state is said out loud (ON without a readable risk list fails: it
# would refuse every task silently), and the lane's selftest runs against the deployed directory. Called by run.sh; exits 0 on pass.
set -uo pipefail
CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"; A="$CITY/packs/town-deltas/assets"; D="$A/quality-gate-dispatcher.sh"; B32=/bin/bash
log()  { echo "[prod-test:gascity ga-dzzqvw] $*"; }
fail() { echo "[prod-test:gascity ga-dzzqvw] FAIL: $*" >&2; exit 1; }
for f in quality-gate-dispatcher.sh gate-taskrapida.lib.sh gate-review-task.lib.sh gate-fastlane.lib.sh gate-task-rapida-risco.default.txt gate-taskrapida.selftest.sh; do
  [[ -f "$A/$f" ]] || fail "missing: $A/$f"
  case "$f" in *.sh) "$B32" -n "$A/$f" || fail "$f does not parse under $B32 (a bare bash -n is 5.x and accepts what 3.2 rejects)" ;; esac
done
for s in taskrapida-lib-load taskrapida-decide; do grep -q "SELFTEST-EXTRACT $s: BEGIN" "$D" || fail "dispatcher block '$s' missing"; done
grep -q 'GATE_REVIEW_PROMPT_MODE="task-rapida"' "$D" || fail "the dispatcher never asks for the short prompt on a grant"
grep -q '^_gate_review_task_pick_body() {' "$A/gate-review-task.lib.sh" || fail "no body picker in the deployed prompt lib: a grant would show the full prompt"
grep -q 'gate.tr_code=' "$A/gate-fastlane.lib.sh" || fail "the deployed recorder does not write the lane's code: a refusal would leave no trace"
grep -qF "$D" "$HOME/Library/LaunchAgents/com.gascity.quality-gate-dispatcher.plist" 2>/dev/null || fail "the launchd plist is missing or does not run $D: merged is not live"
LL="$(launchctl list 2>/dev/null || true)"   # captured, then matched: `| grep -q` can false-fail on SIGPIPE under pipefail
case "$LL" in *com.gascity.quality-gate-dispatcher*) ;; *) fail "com.gascity.quality-gate-dispatcher is not loaded in launchd" ;; esac
SW="$CITY/.gc/gate-task-rapida.on"; RISK="$CITY/.gc/gate-task-rapida-risco.txt"
if [[ -f "$SW" ]]; then
  { [[ -r "$RISK" ]] && grep -qv -E '^[[:space:]]*(#|$)' "$RISK"; } || fail "lane is ON but $RISK is absent, unreadable or empty: every task would be refused; copy $A/gate-task-rapida-risco.default.txt there"
  log "lane is ON"
else
  log "lane is DARK (no $SW): every task takes the normal gate; go-live is ga-dzzqvw.1"
fi
OUT=$(timeout 600 "$B32" "$A/gate-taskrapida.selftest.sh" 2>&1) || fail "gate-taskrapida.selftest.sh failed: $(printf '%s' "$OUT" | grep '✗' | head -5 | tr '\n' ' ')"
log "PASS"
