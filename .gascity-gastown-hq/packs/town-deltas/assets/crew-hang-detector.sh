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
# ── WHY v1 WAS INERT + UNSAFE (ga-6i82w / ga-yqcdj — THIS rework) ──────────────
# v1 (sha 250baee59) had two premises that ground-truthing against the live
# engine proved FALSE, so it could never have protected crew:
#
#   (1) DISCRIMINATOR — v1 required `name == template`, but live crew sessions
#       also appear in the wisp-instance form `<template>-gawisp<hash>` (observed:
#       digo-wa-gawisp82s0ge with template digo-wa). v1 skipped every gawisp-form
#       crew → detected nothing. (Same naming gap as ga-i67t/crew-session-dedup,
#       which keys off TEMPLATE membership, not name==template.)
#
#   (3) SIGNAL — v1 treated `last_active` as a per-tick ENGINE HEARTBEAT that
#       stays fresh on idle sessions. It is NOT. Two `gc session list` samples
#       25s apart showed every healthy idle crew session frozen at the timestamp
#       of its LAST turn (thies-wa idle-at-prompt for ~13min while its peek showed
#       a clean `❯`). `last_active` is a last-ACTIVITY timestamp; a healthy idle
#       pinned crew session is INDISTINGUISHABLE from a hung one by last_active.
#       v1 would therefore have nudged-then-warrant-killed healthy idle crew.
#
# ── THE SIGNAL THIS VERSION USES ──────────────────────────────────────────────
# A hung session is wedged MID-TURN: its TUI render loop is blocked, so the pane
# freezes on the last-rendered frame — which still shows the active-work spinner
# (`<glyph> <Gerund>… (<elapsed> · …)`). A HEALTHY session is one of:
#   - idle: sitting at the `❯` input prompt, last line a past-tense turn summary
#     (`✻ Cooked for 6s`) — NO active-work spinner; or
#   - busy-and-progressing: the spinner's elapsed timer INCREMENTS every render,
#     so the pane CHANGES across passes.
# So the hang signature is: pane is in the active-work state AND its content is
# BYTE-FROZEN across passes. Idle crew never enter the candidate set (no spinner);
# a healthy long turn de-escalates itself (its timer keeps moving). This removes
# the v1 idle false-positive at the root.
#
# ── WHAT THIS DOES (each StartInterval pass) ──────────────────────────────────
# List active crew sessions (name==template OR name startswith template-gawisp);
# for each, `gc session peek` and classify. For an active-work pane, fingerprint
# it (sha of the captured region) and track freeze duration in state across
# passes. Recover a sustained freeze with DUE PROCESS mirroring the deacon's own
# "nudge first, then warrant":
#   1. frozen > STALE_SEC (default 600s/10min): NUDGE the session (courtesy probe;
#      a live-but-slow session processes it, its pane changes, and it de-escalates
#      next pass).
#   2. frozen > ESCALATE_SEC (default 1200s/20min): file a `warrant` bead routed
#      to the dog pool — but ONLY when WARRANT_ENABLED=1. A dog runs
#      `mol-shutdown-dance` (3 interrogations / 420s) and kills ONLY if the agent
#      never proves ALIVE; the reconciler then restarts the pinned session.
# This is the SAME recovery path witnesses/deacon already use — no new kill logic.
#
# ── WHY THE WARRANT PATH IS GATED OFF BY DEFAULT (WARRANT_ENABLED) ─────────────
# The freeze signal is sound in PRINCIPLE and provably immune to the idle
# false-positive that killed v1, but it has NOT yet been validated against a
# captured real hang (we have healthy-idle and healthy-busy ground truth, not a
# wedged one). Per ga-6i82w ("kill-path premise needs rethink; source problem
# UNSOLVED"), and matching the crew-session-dedup precedent (auto-act only on the
# unambiguous case; alert-only otherwise), the DESTRUCTIVE warrant/kill path
# stays OFF until one validated hang capture. With WARRANT_ENABLED=0 (default),
# escalation NOTIFIES a human (non-destructive) instead of filing a warrant. The
# nudge path runs regardless — it is non-destructive and can itself unstick a
# hang, and it fixes the incident's "only a human peeking ever notices".
# To enable autonomous recovery after validation: set WARRANT_ENABLED=1 (env /
# launchd EnvironmentVariables).
#
# ── SAFETY VALVES ─────────────────────────────────────────────────────────────
#   - Candidate set = active-work pane only; idle/waiting/unclassifiable → NO action.
#   - Freeze measured across passes; a single slow render never triggers.
#   - Destructive warrant path gated behind WARRANT_ENABLED (default off).
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
STALE_SEC="${STALE_SEC:-600}"        # nudge probe after 10min frozen
ESCALATE_SEC="${ESCALATE_SEC:-1200}" # escalate after 20min frozen
DRY_RUN="${DRY_RUN:-0}"
WARRANT_ENABLED="${WARRANT_ENABLED:-0}" # 0 = notify human; 1 = file shutdown-dance warrant
PEEK_LINES="${PEEK_LINES:-40}"       # pane lines captured for the freeze fingerprint
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

log "=== pass start (PID $$, STALE_SEC=$STALE_SEC, ESCALATE_SEC=$ESCALATE_SEC, WARRANT_ENABLED=$WARRANT_ENABLED, DRY_RUN=$DRY_RUN) ==="

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

# Filter to persistent-crew candidate NAMES. Emits one session name per line.
# Crew discriminator: active, not human-attached, template not a gastown.* system
# pool, not a polecat (template has '/'), not an adhoc instance, and the name is
# the persistent worker (name == template) OR its wisp-instance form
# (name startswith "<template>-gawisp"). The latter is the ga-6i82w fix: v1's
# `name == template` skipped every gawisp-form live crew session.
# The session JSON is passed as a temp-file argv (NOT piped) because a `<<'PY'`
# heredoc supplies python's program on stdin and would shadow any piped data.
TMP_SESS="$(mktemp)"
printf '%s' "$SESS_JSON" > "$TMP_SESS"
CREW_NAMES="$(python3 - "$TMP_SESS" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
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
    if "adhoc" in name:               # ephemeral / cap-exempt pool instances
        continue
    if name == tmpl or name.startswith(tmpl + "-gawisp"):
        print(name)
PY
)"
rm -f "$TMP_SESS"

# Is this pane in the active-work state (a turn is running)? The signature is the
# spinner line: a present-continuous gerund + ellipsis + a parenthesized elapsed
# timer, e.g. "✳ Gitifying… (15m 49s · ↓ 61.3k tokens)". Idle panes show a
# past-tense summary ("✻ Cooked for 6s") with no ellipsis/elapsed. "esc to
# interrupt" is accepted as a belt-and-suspenders active marker. Anything else
# (idle, waiting-for-input, unclassifiable, empty) returns non-zero -> NOT a
# candidate -> no action (fail-safe toward inaction).
is_active_work() {
    printf '%s' "$1" | grep -Eq '(…|\.\.\.)[^(]*\(([0-9]+m[[:space:]]+)?[0-9]+s' && return 0
    printf '%s' "$1" | grep -q 'esc to interrupt' && return 0
    return 1
}

# Fingerprint a captured pane: strip trailing whitespace per line (cursor/render
# jitter), hash the rest. A wedged process re-renders nothing -> identical hash
# across passes; a live turn's elapsed timer moves -> hash changes.
fingerprint() {
    printf '%s' "$1" | sed 's/[[:space:]]*$//' | shasum 2>/dev/null | awk '{print $1}'
}

# Build the set of active-work candidate names this pass (peek each crew session).
# Stored as a newline list for the state GC step below.
ACTIVE_WORK_NAMES=""
declare -a CAND_NAME CAND_FP
while IFS= read -r name; do
    [ -z "$name" ] && continue
    pane="$(timeout 20 "$GC" session peek "$name" --lines "$PEEK_LINES" 2>/dev/null || true)"
    [ -z "$pane" ] && continue           # empty pane -> unclassifiable -> skip
    if ! is_active_work "$pane"; then
        continue                          # idle / waiting / unclassifiable -> skip
    fi
    fp="$(fingerprint "$pane")"
    [ -z "$fp" ] && continue
    CAND_NAME+=("$name")
    CAND_FP+=("$fp")
    ACTIVE_WORK_NAMES="$ACTIVE_WORK_NAMES$name"$'\n'
done <<< "$CREW_NAMES"

# Garbage-collect state for sessions that are no longer active-work candidates
# (went idle, progressed away, slept, or vanished). A recover-then-rehang session
# thus starts fresh and gets the gentle nudge pass first.
if [ -d "$NUDGED_DIR" ]; then
    for f in "$NUDGED_DIR"/*; do
        [ -e "$f" ] || continue
        bn="$(basename "$f")"
        if ! printf '%s' "$ACTIVE_WORK_NAMES" | grep -qx "$bn"; then
            log "$bn: no longer active-work (recovered/idle) -> clear freeze state"
            rm -f "$f"
        fi
    done
fi

if [ "${#CAND_NAME[@]}" -eq 0 ]; then
    log "no active-work crew sessions to track"
    exit 0
fi

# Preload targets of already-open warrants for dedup (bounded).
WARRANT_TARGETS="$(timeout 25 "$GC" bd list --label warrant --status open --json --limit 0 2>/dev/null \
    | jq -r '.[]? | .metadata.target // empty' 2>/dev/null || true)"

now="$(date +%s)"

# State file format ($NUDGED_DIR/$name), 4 lines:
#   <fingerprint>
#   <first_seen_epoch_for_this_fingerprint>
#   <nudged 0|1>
#   <escalated 0|1>
idx=0
while [ "$idx" -lt "${#CAND_NAME[@]}" ]; do
    name="${CAND_NAME[$idx]}"
    fp="${CAND_FP[$idx]}"
    idx=$((idx + 1))
    sf="$NUDGED_DIR/$name"

    # Dedup: a dog is already handling this target.
    if [ -n "$WARRANT_TARGETS" ] && printf '%s\n' "$WARRANT_TARGETS" | grep -qx "$name"; then
        log "$name: open warrant already exists — skip (dog handling)"
        rm -f "$sf"
        continue
    fi

    # Load prior state (if any).
    prev_fp=""; since="$now"; nudged=0; escalated=0
    if [ -f "$sf" ]; then
        { IFS= read -r prev_fp; IFS= read -r since; IFS= read -r nudged; IFS= read -r escalated; } < "$sf"
        [ -z "$since" ] && since="$now"
        [ -z "$nudged" ] && nudged=0
        [ -z "$escalated" ] && escalated=0
    fi

    if [ "$fp" != "$prev_fp" ]; then
        # Pane changed since last pass (progressing) OR first observation -> reset.
        printf '%s\n%s\n0\n0\n' "$fp" "$now" > "$sf"
        log "$name: active-work, pane advancing (or first seen) -> reset freeze clock"
        continue
    fi

    # Frozen: same active-work fingerprint as last pass.
    age=$((now - since))
    [ "$age" -lt 0 ] && age=0

    if [ "$age" -ge "$ESCALATE_SEC" ]; then
        if [ "$escalated" = "1" ]; then
            log "$name: frozen ${age}s — already escalated, awaiting dog/human"
            continue
        fi
        if [ "$WARRANT_ENABLED" = "1" ]; then
            log "$name: pane FROZEN ${age}s (>=${ESCALATE_SEC}s) -> FILE WARRANT (shutdown-dance)"
            if [ "$DRY_RUN" = "1" ]; then
                log "  [DRY_RUN] would file warrant for $name"
                continue
            fi
            meta="$(printf '{"target":"%s","reason":"crew-hang-detector: active-work pane byte-frozen %ss (>=%ss), unresponsive to nudge probe","requester":"crew-hang-detector","gc.routed_to":"%s"}' \
                "$name" "$age" "$ESCALATE_SEC" "$DOG_TEMPLATE")"
            if timeout 30 "$GC" bd create --type=task --label=warrant \
                    --title="Stuck crew: $name (hung ${age}s)" \
                    --metadata "$meta" >/dev/null 2>&1; then
                log "  warrant filed for $name (routed to $DOG_TEMPLATE pool)"
                printf '%s\n%s\n%s\n1\n' "$fp" "$since" "$nudged" > "$sf"
                if command -v notify >/dev/null 2>&1; then
                    notify -t "Crew hang auto-recovery" \
                        "crew-hang-detector filed a shutdown-dance warrant for $name (pane frozen ${age}s). A dog will interrogate (420s) and restart it if unresponsive." \
                        >/dev/null 2>&1 || true
                fi
            else
                log "  ERROR: warrant create failed for $name (will retry next pass)"
            fi
        else
            # WARRANT_ENABLED=0: destructive path gated off pending hang validation.
            log "$name: pane FROZEN ${age}s (>=${ESCALATE_SEC}s) -> NOTIFY human (warrant path disabled; set WARRANT_ENABLED=1 after validation)"
            if [ "$DRY_RUN" = "1" ]; then
                log "  [DRY_RUN] would notify human about $name"
                continue
            fi
            if command -v notify >/dev/null 2>&1; then
                notify -t "Crew hang suspected" -p 4 \
                    "crew-hang-detector: $name pane byte-frozen ${age}s in an active turn and unresponsive to nudge. Autonomous recovery is OFF (WARRANT_ENABLED=0) — peek/restart it manually, or enable the warrant path after validating the signal." \
                    >/dev/null 2>&1 || true
            fi
            printf '%s\n%s\n%s\n1\n' "$fp" "$since" "$nudged" > "$sf"
        fi
        continue
    fi

    if [ "$age" -ge "$STALE_SEC" ]; then
        # Between STALE and ESCALATE: courtesy nudge probe, once.
        if [ "$nudged" = "1" ]; then
            log "$name: frozen ${age}s — already nudged, waiting for escalation threshold (${ESCALATE_SEC}s)"
            continue
        fi
        log "$name: pane FROZEN ${age}s (>${STALE_SEC}s) -> NUDGE probe"
        if [ "$DRY_RUN" = "1" ]; then
            log "  [DRY_RUN] would nudge $name"
        else
            timeout 20 "$GC" session nudge "$name" \
                "[crew-hang-detector] Your pane has shown no progress for ${age}s in an active turn. If alive, act now — a stuck-session escalation will follow if you stay frozen." \
                >/dev/null 2>&1 || log "  nudge failed (session may be wedged)"
        fi
        printf '%s\n%s\n1\n0\n' "$fp" "$since" > "$sf"
        continue
    fi

    # Frozen but below the nudge threshold — keep watching.
    log "$name: pane frozen ${age}s (<${STALE_SEC}s) — watching"
    printf '%s\n%s\n%s\n%s\n' "$fp" "$since" "$nudged" "$escalated" > "$sf"
done

log "=== pass complete ==="
exit 0
