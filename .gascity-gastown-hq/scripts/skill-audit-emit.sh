#!/usr/bin/env bash
# skill-audit-emit.sh — Periodic emitter of the skill-drift dashboard metric.
#
# Runs skill-audit.sh and writes the latest result to
#   .gc/state/skill-drift.json
# atomically, so a dashboard can read a single fresh file for the story-ga-5lx
# metrics: drift_count (=0), offpath_count ("deploys that bypassed the lock" =0).
#
# READ-ONLY with respect to skills/config: it only writes its own state + log
# files, never touches a skill sink, city.toml, pack.toml, or gc reload. Safe to
# run on a cron/launchd cadence on a live host — it cannot drain crew.
#
# Invoked by launchd (com.gascity.skill-audit, StartInterval ~300s) or by hand.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${SKILL_AUDIT_CITY:-$(cd "$SELF_DIR/.." && pwd)}"
AUDIT="$SELF_DIR/skill-audit.sh"
STATE_DIR="$CITY/.gc/state"
OUT="$STATE_DIR/skill-drift.json"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/skill-audit.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Capture JSON (stdout) regardless of exit code; the auditor prints valid JSON
# even when it finds drift/off-path.
json="$("$AUDIT" --json-only --quiet 2>/dev/null)"
rc=$?

if [[ -z "$json" ]]; then
    echo "[$(ts)] [skill-audit-emit] ERROR: auditor produced no JSON (rc=$rc)" >> "$LOG"
    exit 2
fi

# Atomic write of the dashboard metric file.
tmp="$(mktemp "$STATE_DIR/.skill-drift.XXXXXX")"
printf '%s\n' "$json" > "$tmp" && mv -f "$tmp" "$OUT" || {
    rm -f "$tmp" 2>/dev/null
    echo "[$(ts)] [skill-audit-emit] ERROR: failed to write $OUT" >> "$LOG"
    exit 2
}

# One concise log line per run (drift/offpath counts + ok flag).
summary="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok=%s drift=%s offpath=%s checked=%s" % (d.get("ok"), d.get("drift_count"), d.get("offpath_count"), d.get("skills_checked")))' 2>/dev/null)"
echo "[$(ts)] [skill-audit-emit] $summary -> $OUT" >> "$LOG"

# Mirror the auditor's exit semantics so a launchd consumer / manual caller can
# react: 0 = clean, 1 = drift or off-path detected.
exit "$rc"
