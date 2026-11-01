#!/usr/bin/env bash
# nudge-stranded-detector.sh — order entrypoint for nudge-stranded-detector.py (ga-gj1jr7x).
# DETECTION ONLY: alarms (via notify) on a PENDING nudge whose live target session has no `gc nudge poll`. It never
# re-arms a poller and never writes the nudge queue. The Python body takes the single-instance lock (macOS ships no
# flock(1)) and keeps the per-nudge-id dedupe file under STATE_DIR.
# -B -I: no bytecode written next to the script, and no cwd/user-site imports (the script loads its one sibling,
# nudge-queue-hygiene.py, by absolute path).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY:-.}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}"
exec python3 -B -I "$HERE/nudge-stranded-detector.py" --alarm --city "$CITY" --state-dir "$STATE_DIR" \
  --log "$STATE_DIR/nudge-stranded-detector.jsonl" "$@"
