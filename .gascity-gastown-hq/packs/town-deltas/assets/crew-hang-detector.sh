#!/usr/bin/env bash
# crew-hang-detector.sh — detect persistent CREW sessions whose runtime has hung
# and recover them through the EXISTING safe shutdown-dance path (ga-khuz1).
#
# ── THE BUG (ga-khuz1) ────────────────────────────────────────────────────────
# A pinned crew session (thies-wa) froze ~15min when an Explore subagent ran a
# Bash call that blocked on a Google Drive CloudStorage (FUSE/network) path with
# no timeout. The parent loop waited on the subagent forever. Nothing detected or
# recovered the HUNG session:
#   - the controller restarts DEAD agents, not alive-but-wedged ones;
#   - the witness covers POLECATS (transient worktree workers), not crew;
#   - the gate guardian (ga-0wxg) covers the gate + pilot, explicitly NOT crew;
#   - the deacon — which files warrants for stuck coordination/utility agents —
#     is SUSPENDED in this town (city.toml patches: gastown.deacon suspended).
# Pinned persistent crew workers therefore fall through every net: their work
# stalls silently and only a human peeking at the pane ever notices.
#
# ── THE SIGNAL ────────────────────────────────────────────────────────────────
# `gc session list` reports `last_active` as an ENGINE LIVENESS HEARTBEAT: every
# live session (busy OR idle) has it bumped each reconciler tick (observed: all
# healthy sessions share the same fresh timestamp; normal age < ~2min). A session
# whose runtime is wedged stops answering the engine, so its `last_active`
# FREEZES — exactly the incident's "last_active parou". A frozen heartbeat well
# past the tick cadence is thus a clean hang signal, independent of busy/idle
# (so an idle-but-pinned crew session is NOT a false positive — its heartbeat
# stays fresh).
#
# ── WHAT THIS DOES (each StartInterval pass) ──────────────────────────────────
# List active crew sessions; for any whose heartbeat is frozen, recover with DUE
# PROCESS that mirrors the deacon's own "nudge first, then warrant":
#   1. age > STALE_SEC  (default 600s/10min): NUDGE the session (courtesy probe;
#      a live-but-slow session processes it and its heartbeat un-freezes, which
#      drops it below threshold next pass and clears its state).
#   2. age > ESCALATE_SEC (default 1200s/20min): file a `warrant` bead routed to
#      the dog pool. A dog runs `mol-shutdown-dance` (3 interrogations / 420s) and
#      kills ONLY if the agent never proves ALIVE; the reconciler then restarts
#      the pinned session, resuming its task.
# This is the SAME recovery path witnesses/deacon already use — no new kill logic.
# A live-but-quiet session is pardoned at multiple layers (heartbeat un-freeze →
# nudge → 3× dance interrogation), honoring the guardian doctrine's "ZERO action
# on a false positive".
#
# ── SAFETY VALVES ─────────────────────────────────────────────────────────────
#   - Conservative thresholds far above the heartbeat cadence (≈seconds–2min).
#   - Warrant dedup: never pile a second warrant on a target that already has one.
#   - DRY_RUN=1: log decisions, take NO action (used by selftest + supervised run).
#   - Kill-switch: .gc/state/crew-hang-detector.disabled present -> no-op.
#   - Every `gc` call is bounded with `timeout` so the detector can't itself hang.
#
# Deployed as launchd agent com.gascity.crew-hang-detector (StartInterval 300).
# Log: .gc/logs/crew-hang-detector.log
#
# Supervised first-run procedure (DO NOT load unsupervised on first deploy):
#   1. DRY_RUN=1 bash crew-hang-detector.sh   # verify candidate detection only
#   2. bash crew-hang-detector.sh             # single supervised real pass
#   3. launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.crew-hang-detector.plist

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/crew-hang-detector.log"
STATE_DIR="$CITY/.gc/state"
NUDGED_DIR="$STATE_DIR/crew-hang"

# Thresholds (seconds). Override via env / launchd EnvironmentVariables.
STALE_SEC="${STALE_SEC:-600}"        # nudge probe at 10min frozen
ESCALATE_SEC="${ESCALATE_SEC:-1200}" # file warrant at 20min frozen
DRY_RUN="${DRY_RUN:-0}"
DOG_TEMPLATE="${DOG_TEMPLATE:-gastown.dog}"  # gc.routed_to value for the dog pool

mkdir -p "$LOG_DIR" "$STATE_DIR" "$NUDGED_DIR"

# In DRY_RUN keep output on the terminal (selftest/supervised); else append to log.
if [ "$DRY_RUN" != "1" ]; then
    exec >> "$LOG" 2>&1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [crew-hang] $*"; }

# Startup marker for delivery freshness verification (mirrors config-drift-watcher
# / ga-fbjg). The prod-test reads this to confirm the LIVE process ran the new
# code after deploy, not merely that the file changed on disk.
printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/crew-hang-detector.startup"

log "=== pass start (PID $$, STALE_SEC=$STALE_SEC, ESCALATE_SEC=$ESCALATE_SEC, DRY_RUN=$DRY_RUN) ==="

# Kill-switch.
if [ -f "$STATE_DIR/crew-hang-detector.disabled" ]; then
    log "kill-switch present (crew-hang-detector.disabled) — no-op"
    exit 0
fi

# Fetch sessions (bounded so a wedged data plane can't hang the detector).
SESS_JSON="$(timeout 30 "$GC" session list --json 2>/dev/null || true)"
if [ -z "$SESS_JSON" ]; then
    log "WARN: empty/failed session list (gc unavailable?) — skip pass"
    exit 0
fi

# Filter to STALE persistent-crew candidates. Emits TSV: name<TAB>age<TAB>last_active.
# Crew discriminator: active, not human-attached, template not a gastown.* system
# pool, not a polecat (template has '/'), not an adhoc instance, and name==template
# (persistent named worker). last_active is parsed as the engine heartbeat.
# The session JSON is passed as a temp-file argv (NOT piped) because a `<<'PY'`
# heredoc supplies python's program on stdin and would shadow any piped data.
TMP_SESS="$(mktemp)"
printf '%s' "$SESS_JSON" > "$TMP_SESS"
CAND="$(STALE_SEC="$STALE_SEC" python3 - "$TMP_SESS" <<'PY' || true
import json, os, sys, datetime
stale = int(os.environ.get("STALE_SEC", "600"))
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
for s in data.get("sessions", []):
    if s.get("state") != "active":
        continue
    if s.get("attached"):
        continue
    tmpl = s.get("template", "") or ""
    name = s.get("name", "") or ""
    if not name or not tmpl:
        continue
    if tmpl.startswith("gastown."):   # mayor / deacon / dog pool / boot
        continue
    if "/" in tmpl:                   # polecat worktrees — witness covers these
        continue
    if "adhoc" in name:               # ephemeral pool instances
        continue
    if name != tmpl:                  # persistent crew: name == template
        continue
    la = s.get("last_active", "") or ""
    iso = la[:-1] + "+00:00" if la.endswith("Z") else la
    try:
        dt = datetime.datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
    except Exception:
        continue                      # unparseable / zero-value -> skip
    age = int((now - dt).total_seconds())
    if age < 0:
        age = 0
    if age <= stale:
        continue
    print(f"{name}\t{age}\t{la}")
PY
)"
rm -f "$TMP_SESS"

# Garbage-collect stale-state for sessions that recovered (no longer candidates),
# so a recover-then-rehang session still gets the gentle nudge pass first.
STALE_NAMES="$(printf '%s\n' "$CAND" | cut -f1)"
if [ -d "$NUDGED_DIR" ]; then
    for f in "$NUDGED_DIR"/*; do
        [ -e "$f" ] || continue
        bn="$(basename "$f")"
        if ! printf '%s\n' "$STALE_NAMES" | grep -qx "$bn"; then
            log "$bn: heartbeat recovered (no longer stale) -> clear nudge state"
            rm -f "$f"
        fi
    done
fi

if [ -z "$CAND" ]; then
    log "no stale crew sessions"
    exit 0
fi

# Preload targets of already-open warrants for dedup (bounded).
WARRANT_TARGETS="$(timeout 25 "$GC" bd list --label warrant --status open --json --limit 0 2>/dev/null \
    | jq -r '.[]? | .metadata.target // empty' 2>/dev/null || true)"

while IFS=$'\t' read -r name age la; do
    [ -z "$name" ] && continue
    sf="$NUDGED_DIR/$name"

    # Dedup: a dog is already handling this target.
    if [ -n "$WARRANT_TARGETS" ] && printf '%s\n' "$WARRANT_TARGETS" | grep -qx "$name"; then
        log "$name: open warrant already exists — skip (dog handling)"
        rm -f "$sf"
        continue
    fi

    if [ "$age" -ge "$ESCALATE_SEC" ]; then
        # Frozen past escalation threshold -> file a shutdown-dance warrant.
        log "$name: heartbeat frozen ${age}s (>=${ESCALATE_SEC}s) -> FILE WARRANT (shutdown-dance)"
        if [ "$DRY_RUN" = "1" ]; then
            log "  [DRY_RUN] would file warrant for $name"
            continue
        fi
        meta="$(printf '{"target":"%s","reason":"crew-hang-detector: engine heartbeat frozen %ss (>=%ss), unresponsive to nudge probe","requester":"crew-hang-detector","gc.routed_to":"%s"}' \
            "$name" "$age" "$ESCALATE_SEC" "$DOG_TEMPLATE")"
        if timeout 30 "$GC" bd create --type=task --label=warrant \
                --title="Stuck crew: $name (hung ${age}s)" \
                --metadata "$meta" >/dev/null 2>&1; then
            log "  warrant filed for $name (routed to $DOG_TEMPLATE pool)"
            rm -f "$sf"
            if command -v notify >/dev/null 2>&1; then
                notify -t "Crew hang auto-recovery" \
                    "crew-hang-detector filed a shutdown-dance warrant for $name (heartbeat frozen ${age}s). A dog will interrogate (420s) and restart it if unresponsive." \
                    >/dev/null 2>&1 || true
            fi
        else
            log "  ERROR: warrant create failed for $name (will retry next pass)"
        fi
        continue
    fi

    # Between STALE_SEC and ESCALATE_SEC: courtesy nudge probe, once.
    if [ ! -f "$sf" ]; then
        log "$name: heartbeat frozen ${age}s (>${STALE_SEC}s) -> NUDGE probe"
        if [ "$DRY_RUN" = "1" ]; then
            log "  [DRY_RUN] would nudge $name"
        else
            timeout 20 "$GC" session nudge "$name" \
                "[crew-hang-detector] No engine heartbeat for ${age}s. If alive, act now — a stuck-session warrant will be filed if you stay frozen." \
                >/dev/null 2>&1 || log "  nudge failed (session may be wedged)"
        fi
        printf '%s\n' "$la" > "$sf"
    else
        log "$name: heartbeat frozen ${age}s — already nudged, waiting for escalation threshold (${ESCALATE_SEC}s)"
    fi
done <<< "$CAND"

log "=== pass complete ==="
exit 0
