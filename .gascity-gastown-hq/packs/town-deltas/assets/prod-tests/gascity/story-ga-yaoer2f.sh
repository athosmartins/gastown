#!/usr/bin/env bash
# prod-tests/gascity/story-ga-yaoer2f.sh — verify ga-yaoer2f: node-ghost-release (ga-moq226t) is LIVE, not just merged.
#
# What "live" means here, and why each leg reads the thing that runs instead of the file that was merged (mergeado ≠ vivo, fonte ≠ o que roda):
#   1. launchd holds the job, running THIS city's script, with NODE_GHOST_DRY_RUN=0 and run interval 311 s (the loaded copy is the one that counts).
#   2. the installed plist on disk and the source plist in the repo agree on those two values (a reboot or a re-bootstrap must not bring the dry run back).
#   3. the .out — which is the daemon-presence-watchdog's heartbeat — advanced within the watchdog's own 900 s limit, and the last `start` line says dry_run=False.
#   4. the DPW default carries the label in DPW_CRITICAL and a heartbeat entry on that .out (without them nothing reloads the job if it goes absent and nothing
#      kickstarts it if it wedges; PRESENCE-DRIFT alone only fires for a plist that is not loaded).
#   5. the comment/mail text no longer promises that `hetzner-remote-git.sh status` lists the PENDENTE (it lists only committed branches).
#
# Three-state on purpose, on every read: "launchctl could not tell", "the log is missing" and "the file could not be read" FAIL; they are never read as "loaded",
# "fresh" or "equal". The live legs (1-3) are host-global (one label per host, pointing at the real city), so they only run for the real city; a scratch run
# (GC_CITY=...) says so and still checks the tracked files (2 for the source plist, 4, 5).
set -euo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
REAL_CITY="/Users/athos/gt/.gascity-gastown-hq"
LABEL="com.gascity.node-ghost-release"
SRC_PLIST="$CITY/scripts/$LABEL.plist"
INSTALLED="${NODE_GHOST_INSTALLED_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
OUT="$CITY/.gc/logs/node-ghost-release.out"
HEARTBEAT_MAX=900

log()  { echo "[prod-test:ga-yaoer2f] $*"; }
fail() { echo "[prod-test:ga-yaoer2f] FAIL: $*" >&2; exit 1; }

# plist_val <file> <key> -> the <integer>/<string> value of <key>; empty when the file is unreadable or the key is absent (the caller FAILS on empty, never passes it)
plist_val() {
    awk -v k="$2" '
        index($0, "<key>" k "</key>") { line = $0; sub(".*<key>" k "</key>", "", line)
            if (line !~ /<(integer|string)>/) { getline line }
            gsub(/.*<(integer|string)>|<\/(integer|string)>.*/, "", line); print line; exit }' "$1" 2>/dev/null || true
}

# ── 1-3. The live legs (real city only) ──────────────────────────────────────
if [ "$CITY" = "$REAL_CITY" ]; then
    command -v launchctl >/dev/null 2>&1 || fail "launchctl not found: cannot tell whether $LABEL is loaded"
    PRINT=$(launchctl print "gui/$(id -u)/$LABEL" 2>&1) \
        || fail "$LABEL is NOT loaded in gui/$(id -u) ($(printf '%s' "$PRINT" | head -1)): the daemon is not running, merging the plist did not load it"
    printf '%s\n' "$PRINT" | grep -q "state = " || fail "launchctl print $LABEL returned no 'state =' line: cannot tell whether it is loaded"
    printf '%s\n' "$PRINT" | grep -qF "$CITY/scripts/node-ghost-release.py" \
        || fail "$LABEL is loaded but does not run $CITY/scripts/node-ghost-release.py: $(printf '%s\n' "$PRINT" | grep -A6 'arguments = ' | tr '\n' ' ')"
    printf '%s\n' "$PRINT" | grep -Eq 'NODE_GHOST_DRY_RUN => 0$' \
        || fail "$LABEL is loaded with NODE_GHOST_DRY_RUN != 0 ($(printf '%s\n' "$PRINT" | grep 'NODE_GHOST_DRY_RUN' | tr -s '\t ' ' ')): it only logs WOULD-RELEASE, reload the plist (only an exact \"0\" writes)"
    printf '%s\n' "$PRINT" | grep -Eq 'NODE_GHOST_ENABLED => 1$' || fail "$LABEL is loaded with NODE_GHOST_ENABLED != 1: the kill-switch is on"
    printf '%s\n' "$PRINT" | grep -Eq 'run interval = 311 seconds' \
        || fail "$LABEL run interval is not 311 s ($(printf '%s\n' "$PRINT" | grep 'run interval' | tr -s '\t ' ' ')): it is back on the 300 s step the other daemons share"
    log "launchd: $LABEL loaded, runs $CITY/scripts/node-ghost-release.py, NODE_GHOST_DRY_RUN=0, ENABLED=1, run interval 311 s"

    # vazio (.out ausente) → FALHA; falhou (stat/date sem resposta) → FALHA; nunca "fresco"
    [ -r "$OUT" ] || fail "heartbeat file missing or unreadable: $OUT"
    MTIME=$(stat -f %m "$OUT" 2>/dev/null) || fail "stat failed on $OUT: cannot tell how old the heartbeat is"
    NOW=$(date +%s)
    case "$MTIME" in ''|*[!0-9]*) fail "mtime of $OUT is not a number ([$MTIME])" ;; esac
    AGE=$(( NOW - MTIME ))
    [ "$AGE" -le "$HEARTBEAT_MAX" ] || fail "$OUT has not advanced for ${AGE}s (> ${HEARTBEAT_MAX}s, the watchdog's own limit): the job is not running"
    LAST_START=$(tail -n 60 "$OUT" 2>/dev/null | grep -F '[node-ghost] start enabled=' | tail -n 1 || true)
    [ -n "$LAST_START" ] || fail "no '[node-ghost] start enabled=' line in the last 60 lines of $OUT: cannot tell which mode the last round ran in"
    printf '%s\n' "$LAST_START" | grep -qF 'dry_run=False' || fail "last round did not run live: $LAST_START"
    log "heartbeat: $OUT advanced ${AGE}s ago (<= ${HEARTBEAT_MAX}s); last round: $LAST_START"
else
    log "scratch city ($CITY): launchd and heartbeat legs not checked (the label belongs to the real city)"
fi

# ── 2. Source plist and installed plist agree on the two values that matter ──
[ -r "$SRC_PLIST" ] || fail "source plist unreadable or missing: $SRC_PLIST"
S_DRY=$(plist_val "$SRC_PLIST" NODE_GHOST_DRY_RUN); S_INT=$(plist_val "$SRC_PLIST" StartInterval)
[ "$S_DRY" = "0" ] || fail "source plist NODE_GHOST_DRY_RUN is [$S_DRY], want 0: a redeploy from source would bring the dry run back"
[ "$S_INT" = "311" ] || fail "source plist StartInterval is [$S_INT], want 311"
if [ "$CITY" = "$REAL_CITY" ]; then
    [ -r "$INSTALLED" ] || fail "installed plist unreadable or missing: $INSTALLED"
    I_DRY=$(plist_val "$INSTALLED" NODE_GHOST_DRY_RUN); I_INT=$(plist_val "$INSTALLED" StartInterval)
    [ "$I_DRY" = "$S_DRY" ] && [ "$I_INT" = "$S_INT" ] \
        || fail "installed plist (DRY_RUN=[$I_DRY] StartInterval=[$I_INT]) differs from the source (DRY_RUN=[$S_DRY] StartInterval=[$S_INT]): the next reboot loads the installed one"
    log "plists: source and installed agree (NODE_GHOST_DRY_RUN=0, StartInterval=311)"
else
    log "plists: source has NODE_GHOST_DRY_RUN=0, StartInterval=311 (installed copy not compared for a scratch city)"
fi

# ── 4. The watchdog default watches it ───────────────────────────────────────
DPW="$CITY/scripts/daemon-presence-watchdog.sh"
[ -r "$DPW" ] || fail "watchdog script unreadable or missing: $DPW"
grep -Eq "^DPW_CRITICAL=\"\\\$\{DPW_CRITICAL:-([^}]* )?com\.gascity\.node-ghost-release[ }]" "$DPW" \
    || fail "$LABEL is not in the DPW_CRITICAL default: if it goes absent the sweep does not reload it, and no heartbeat is read for it"
grep -Eq "^$LABEL[|][^|]*/\.gc/logs/node-ghost-release\.out[|]$HEARTBEAT_MAX" "$DPW" \
    || fail "no '$LABEL|.../node-ghost-release.out|$HEARTBEAT_MAX' heartbeat entry in the DPW default: a wedged job would go unnoticed"
log "DPW: $LABEL is in DPW_CRITICAL and has the heartbeat entry on node-ghost-release.out ($HEARTBEAT_MAX s)"

# ── 5. The text the job posts no longer overpromises ─────────────────────────
NG="$CITY/scripts/node-ghost-release.py"
[ -r "$NG" ] || fail "job script unreadable or missing: $NG"
if grep -q 'lista o PENDENTE' "$NG"; then
    fail "$NG still says status 'lista o PENDENTE': it lists only committed branches (a new/changed uncommitted file in the node worktree does not appear)"
fi
grep -q 'COMMITADO' "$NG" || fail "$NG does not carry the corrected COMMITADO wording: cannot tell what the comment/mail promise"
log "job text: the comment and the mail say status lists only the COMMITTED work"

log "PASS"
exit 0
