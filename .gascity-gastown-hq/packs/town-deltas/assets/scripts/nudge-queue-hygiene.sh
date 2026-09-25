#!/usr/bin/env bash
# nudge-queue-hygiene.sh — order entrypoint for nudge-queue-hygiene.py (ga-aijm2v.5, rule 2).
# Orders in this pack exec shell scripts; the queue cleanup needs fcntl.flock (macOS ships
# no flock(1)) to take the engine's own queue lock, hence the Python body.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY:-.}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}"
exec python3 "$HERE/nudge-queue-hygiene.py" --apply --city "$CITY" --log "$STATE_DIR/nudge-queue-hygiene.jsonl" "$@"
