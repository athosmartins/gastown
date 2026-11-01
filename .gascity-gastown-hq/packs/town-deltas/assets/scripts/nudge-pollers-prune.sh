#!/usr/bin/env bash
# nudge-pollers-prune.sh — order entrypoint for nudge-pollers-prune.py (ga-9uv1xps.2).
# Orders in this pack exec shell scripts; the prune needs fcntl.flock (macOS ships no flock(1)), hence the Python body.
# The exit code of the Python body is the order's exit code (0 ok, 1 some unlink failed, 2 cannot tell / refused).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY="${GC_CITY:-.}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}"
exec python3 "$HERE/nudge-pollers-prune.py" --apply --city "$CITY" --log "$STATE_DIR/nudge-pollers-prune.jsonl" "$@"
